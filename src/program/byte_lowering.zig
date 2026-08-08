//! Lower rune literals and normalized rune ranges to Thompson byte automata.
//!
//! Latin-1 lowering clips to `0xff` and emits one byte-range leaf. UTF-8 lowering
//! must accept every canonical encoding in a rune interval while rejecting gaps,
//! surrogates, overlong forms, and malformed bytes. It proceeds in three steps:
//!
//! 1. an explicit `RuneWork` stack partitions the interval at UTF-8 length and
//!    canonical envelope boundaries;
//! 2. each partition becomes a `ByteSequence` of per-position intervals;
//! 3. sequences are assembled into Thompson fragments with shared structure.
//!
//! Disjoint next-byte intervals can share a prefix trie. Where envelopes overlap,
//! suffix interning keyed by `(successor, lo, hi)` prevents exponential duplicate
//! tails. Reverse compilation reverses byte positions before graph assembly, so
//! the reverse Program consumes bytes from an endpoint toward a start.
//!
//! Folded literals expand their Unicode simple-fold cycle before lowering. Work
//! stacks, trie nodes, and intern tables are all allocator-owned and bounded by
//! instruction/allocation errors. This module knows nothing about syntax-tree
//! scheduling, capture priority, or final Program publication.

const std = @import("std");
const rune_range = @import("../syntax/rune_range.zig");
const unicode = @import("../unicode/data.zig");
const byte_encoding = @import("byte_encoding.zig");
const builder_module = @import("builder.zig");
const program = @import("program.zig");
const thompson = @import("thompson.zig");

pub const Error = error{ OutOfMemory, InstructionLimit, InvalidSyntax };
pub const Fragment = thompson.Fragment;

const ByteSequence = byte_encoding.ByteSequence;
/// Inclusive rune interval awaiting canonical UTF-8 partitioning.
const RuneWork = struct { lo: u32, hi: u32 };
const no_sequence_node: u32 = std.math.maxInt(u32);
/// Interning key for a suffix node: accepted byte interval followed by `next`.
const SequenceNodeKey = packed struct { next: u32, lo: u8, hi: u8 };
/// Disjoint byte interval leading to another temporary sequence-trie node.
const TrieEdge = struct { lo: u8, hi: u8, child: u32 };

/// Temporary trie node; `terminal` means a complete byte sequence ends here.
const TrieNode = struct {
    edges: std.ArrayList(TrieEdge) = .empty,
    terminal: bool = false,
};

/// Reusable temporary storage for all rune predicates in one compilation.
/// Arrays retain capacity between calls and are released with the Compiler.
pub const Lowering = struct {
    allocator: std.mem.Allocator,
    encoding: byte_encoding.Encoding,
    reverse: bool,
    rune_work: std.ArrayList(RuneWork) = .empty,

    pub fn deinit(self: *Lowering) void {
        self.rune_work.deinit(self.allocator);
        self.* = undefined;
    }

    /// Lowers every member of one Unicode simple-fold cycle as ordered
    /// alternatives. ASCII cycles may use one folded byte instruction.
    pub fn foldedRune(
        self: *Lowering,
        builder: *builder_module.Builder,
        rune: u32,
    ) Error!Fragment {
        if (self.encoding == .latin1) {
            if (rune >= 'A' and rune <= 'Z') return self.runeClass(builder, &.{
                .{ .lo = rune, .hi = rune },
                .{ .lo = rune + ('a' - 'A'), .hi = rune + ('a' - 'A') },
            });
            if (rune >= 'a' and rune <= 'z') return self.runeClass(builder, &.{
                .{ .lo = rune - ('a' - 'A'), .hi = rune - ('a' - 'A') },
                .{ .lo = rune, .hi = rune },
            });
            return self.compileRune(builder, rune);
        }

        var values: [4]rune_range.Range = undefined;
        var count: usize = 0;
        var current = rune;
        while (true) {
            values[count] = .{ .lo = current, .hi = current };
            count += 1;
            current = unicode.foldNext(current);
            if (current == rune) break;
            if (count == values.len) return error.InvalidSyntax;
        }
        return self.runeClass(builder, values[0..count]);
    }

    /// Lowers one rune to its exact byte-consuming Fragment. Latin-1 values
    /// outside the byte domain become no-match; UTF-8 emits canonical bytes in
    /// forward or reverse execution order.
    pub fn compileRune(
        self: *Lowering,
        builder: *builder_module.Builder,
        value: u32,
    ) Error!Fragment {
        if (self.encoding == .latin1) {
            if (value > 0xff) return thompson.noMatch();
            return thompson.byteRange(builder, @intCast(value), @intCast(value));
        }
        return self.byteSequence(builder, byte_encoding.encodeRune(value));
    }

    /// Lowers the union of normalized ranges. Empty input produces no-match;
    /// source range order is already canonical and does not imply priority.
    pub fn runeClass(
        self: *Lowering,
        builder: *builder_module.Builder,
        ranges: []const rune_range.Range,
    ) Error!Fragment {
        var result: ?Fragment = null;
        if (self.encoding == .latin1) {
            for (ranges) |range| {
                if (range.lo > 0xff) continue;
                const hi: u8 = @intCast(@min(range.hi, 0xff));
                const fragment = try thompson.byteRange(builder, @intCast(range.lo), hi);
                result = if (result) |current|
                    try thompson.alternate(builder, current, fragment)
                else
                    fragment;
            }
            return result orelse thompson.noMatch();
        }

        var sequences: std.ArrayList(ByteSequence) = .empty;
        defer sequences.deinit(self.allocator);
        for (ranges) |range| try self.appendUtf8Range(&sequences, range.lo, range.hi);
        if (sequences.items.len == 0) return thompson.noMatch();
        return self.sharedByteSequences(builder, sequences.items);
    }

    /// Splits one scalar interval until each piece can be represented by a
    /// rectangular per-byte envelope, appending those sequences to scratch.
    fn appendUtf8Range(
        self: *Lowering,
        output: *std.ArrayList(ByteSequence),
        lo: u32,
        hi: u32,
    ) Error!void {
        if (lo > hi or lo > rune_range.max_rune) return;
        const bounded_hi = @min(hi, rune_range.max_rune);
        if (lo == 0x80 and bounded_hi == rune_range.max_rune) {
            try output.appendSlice(self.allocator, &byte_encoding.broadUtf8Sequences());
            return;
        }
        self.rune_work.clearRetainingCapacity();
        if (lo <= 0xdfff and bounded_hi >= 0xd800) {
            if (lo < 0xd800)
                try self.rune_work.append(self.allocator, .{ .lo = lo, .hi = 0xd7ff });
            if (bounded_hi > 0xdfff)
                try self.rune_work.append(self.allocator, .{ .lo = 0xe000, .hi = bounded_hi });
        } else {
            try self.rune_work.append(self.allocator, .{ .lo = lo, .hi = bounded_hi });
        }
        while (self.rune_work.pop()) |work| {
            const lo_len = byte_encoding.utf8Length(work.lo);
            const hi_len = byte_encoding.utf8Length(work.hi);
            if (lo_len != hi_len) {
                const boundary = byte_encoding.maxRuneForLength(lo_len);
                try self.rune_work.append(self.allocator, .{ .lo = boundary + 1, .hi = work.hi });
                try self.rune_work.append(self.allocator, .{ .lo = work.lo, .hi = boundary });
                continue;
            }

            var split = false;
            var trailing: u3 = 1;
            while (trailing < lo_len) : (trailing += 1) {
                const bits: u5 = 6 * @as(u5, trailing);
                const mask: u32 = (@as(u32, 1) << bits) - 1;
                if ((work.lo & ~mask) != (work.hi & ~mask)) {
                    if (work.lo & mask != 0) {
                        const end = work.lo | mask;
                        try self.rune_work.append(self.allocator, .{ .lo = end + 1, .hi = work.hi });
                        try self.rune_work.append(self.allocator, .{ .lo = work.lo, .hi = end });
                    } else if (work.hi & mask != mask) {
                        const begin = work.hi & ~mask;
                        try self.rune_work.append(self.allocator, .{ .lo = begin, .hi = work.hi });
                        try self.rune_work.append(self.allocator, .{ .lo = work.lo, .hi = begin - 1 });
                    } else {
                        continue;
                    }
                    split = true;
                    break;
                }
            }
            if (split) continue;

            const lower = byte_encoding.encodeRune(work.lo);
            const upper = byte_encoding.encodeRune(work.hi);
            var sequence = lower;
            for (0..sequence.len) |index| sequence.ranges[index].hi = upper.ranges[index].lo;
            try output.append(self.allocator, sequence);
        }
    }

    /// Builds a prefix trie when sibling byte intervals are disjoint, maximizing
    /// shared leading structure and preserving a deterministic edge order.
    fn sharedByteSequences(
        self: *Lowering,
        builder: *builder_module.Builder,
        sequences: []const ByteSequence,
    ) Error!Fragment {
        var nodes: std.ArrayList(TrieNode) = .empty;
        defer {
            for (nodes.items) |*node| node.edges.deinit(self.allocator);
            nodes.deinit(self.allocator);
        }
        try nodes.append(self.allocator, .{});

        for (sequences) |sequence| {
            var node_index: u32 = 0;
            for (0..sequence.len) |offset| {
                const index = if (self.reverse) sequence.len - 1 - offset else offset;
                const range = sequence.ranges[index];
                var child: ?u32 = null;
                for (nodes.items[node_index].edges.items) |edge| {
                    if (edge.lo == range.lo and edge.hi == range.hi) {
                        child = edge.child;
                        break;
                    }
                    if (edge.lo <= range.hi and range.lo <= edge.hi)
                        return self.suffixByteSequences(builder, sequences);
                }
                if (child == null) {
                    if (nodes.items.len >= std.math.maxInt(u32)) return error.InstructionLimit;
                    const new_child: u32 = @intCast(nodes.items.len);
                    try nodes.append(self.allocator, .{});
                    try nodes.items[node_index].edges.append(self.allocator, .{
                        .lo = range.lo,
                        .hi = range.hi,
                        .child = new_child,
                    });
                    child = new_child;
                }
                node_index = child.?;
            }
            nodes.items[node_index].terminal = true;
        }

        const fragments = try self.allocator.alloc(?Fragment, nodes.items.len);
        defer self.allocator.free(fragments);
        @memset(fragments, null);
        var node_index = nodes.items.len;
        while (node_index > 0) {
            node_index -= 1;
            const node = &nodes.items[node_index];
            if (node.terminal) {
                if (node.edges.items.len != 0) return error.InvalidSyntax;
                continue;
            }
            var combined: ?Fragment = null;
            for (node.edges.items) |edge| {
                var fragment = try thompson.byteRange(builder, edge.lo, edge.hi);
                if (!nodes.items[edge.child].terminal) {
                    const child = fragments[edge.child] orelse return error.InvalidSyntax;
                    builder.patch(fragment.outs, child.start);
                    fragment.outs = child.outs;
                }
                combined = if (combined) |current|
                    try thompson.alternate(builder, current, fragment)
                else
                    fragment;
            }
            fragments[node_index] = combined orelse return error.InvalidSyntax;
        }
        return fragments[0] orelse error.InvalidSyntax;
    }

    /// General construction for overlapping envelopes. Compiles right-to-left
    /// and interns equivalent `(next, byte interval)` suffix nodes.
    fn suffixByteSequences(
        self: *Lowering,
        builder: *builder_module.Builder,
        sequences: []const ByteSequence,
    ) Error!Fragment {
        var nodes: std.ArrayList(SequenceNodeKey) = .empty;
        defer nodes.deinit(self.allocator);
        var roots: std.ArrayList(u32) = .empty;
        defer roots.deinit(self.allocator);
        var intern: std.AutoHashMapUnmanaged(SequenceNodeKey, u32) = .empty;
        defer intern.deinit(self.allocator);

        for (sequences) |sequence| {
            var next = no_sequence_node;
            for (0..sequence.len) |offset| {
                const index = if (self.reverse) offset else sequence.len - 1 - offset;
                const range = sequence.ranges[index];
                const key = SequenceNodeKey{ .next = next, .lo = range.lo, .hi = range.hi };
                const entry = try intern.getOrPut(self.allocator, key);
                if (!entry.found_existing) {
                    if (nodes.items.len >= std.math.maxInt(u32)) return error.InstructionLimit;
                    entry.value_ptr.* = @intCast(nodes.items.len);
                    try nodes.append(self.allocator, key);
                }
                next = entry.value_ptr.*;
            }
            if (std.mem.indexOfScalar(u32, roots.items, next) == null)
                try roots.append(self.allocator, next);
        }

        var starts: std.ArrayList(program.InstId) = .empty;
        defer starts.deinit(self.allocator);
        try starts.ensureTotalCapacityPrecise(self.allocator, nodes.items.len);
        var outs: builder_module.PatchList = .{};
        for (nodes.items) |node| {
            const byte = try builder.addByteRange(node.lo, node.hi, false);
            if (node.next == no_sequence_node) {
                outs = builder.appendPatches(outs, byte[1]);
            } else {
                builder.patch(byte[1], starts.items[node.next]);
            }
            starts.appendAssumeCapacity(byte[0]);
        }
        var root = Fragment{ .start = starts.items[roots.items[0]], .outs = .{}, .nullable = false };
        for (roots.items[1..]) |node| {
            root = try thompson.alternate(builder, root, .{
                .start = starts.items[node],
                .outs = .{},
                .nullable = false,
            });
        }
        root.outs = outs;
        return root;
    }

    /// Composes one sequence into a linear Thompson fragment in execution order.
    fn byteSequence(
        self: *Lowering,
        builder: *builder_module.Builder,
        sequence: ByteSequence,
    ) Error!Fragment {
        var result: ?Fragment = null;
        var offset: usize = 0;
        while (offset < sequence.len) : (offset += 1) {
            const index = if (self.reverse) sequence.len - 1 - offset else offset;
            const range = sequence.ranges[index];
            const fragment = try thompson.byteRange(builder, range.lo, range.hi);
            result = if (result) |current|
                thompson.concatenate(builder, current, fragment)
            else
                fragment;
        }
        return result orelse error.InvalidSyntax;
    }
};

const testing = std.testing;

test "Byte lowering reverses encoded bytes without syntax traversal" {
    var builder = try builder_module.Builder.init(testing.allocator, 20);
    defer builder.deinit();
    var lowering = Lowering{
        .allocator = testing.allocator,
        .encoding = .utf8,
        .reverse = true,
    };
    defer lowering.deinit();

    const fragment = try lowering.compileRune(&builder, 0x00e9);
    const accepting = try builder.addMatch(@enumFromInt(0));
    builder.patch(fragment.outs, accepting);
    var graph = try builder.finish(fragment.start, fragment.start, 0);
    defer graph.deinit(testing.allocator);

    const first = graph.inst(graph.start);
    try testing.expectEqual(@as(u8, 0xa9), first.byteLo());
    const second = graph.inst(first.out());
    try testing.expectEqual(@as(u8, 0xc3), second.byteLo());
    try testing.expect(graph.inst(second.out()).opcode() == .match);
}
