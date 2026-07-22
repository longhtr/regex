//! Transactional conversion from temporary Graph to immutable Program.
//!
//! Publication is the ownership and representation boundary between compilation
//! and execution. It first validates the explicit Graph, then constructs one
//! `ProgramBuild` whose optional Program owns every allocation made in this
//! phase. Deferred teardown rolls back partial lists, leaves, byte maps, and
//! prefixes; `finish` validates and transfers the complete Program.
//!
//! The phase performs independent, ordered tasks:
//!
//! 1. derive required forward prefix and interior-literal facts from syntax;
//! 2. derive directional anchoring from graph reachability;
//! 3. remove epsilon control by building canonical priority lists;
//! 4. partition the byte domain for DFA transitions;
//! 5. summarize reachable assertions from published leaves;
//! 6. derive suffix, line, empty, capture, and closed-prefix facts;
//! 7. classify exact repeated-byte plans;
//! 8. compute the compressed BitState root-row count;
//! 9. validate the complete result.
//!
//! Reverse Programs intentionally omit forward-only prefix/suffix and direct
//! shape plans. Facts are conservative and never substitute for Program
//! semantics unless the classifier proves a complete closed language.

const std = @import("std");
const syntax = @import("../syntax/regexp.zig");
const shapes = @import("../optimize/shapes.zig");
const facts = @import("facts.zig");
const byte_encoding = @import("byte_encoding.zig");
const byte_map = @import("byte_map.zig");
const priority_lists = @import("priority_lists.zig");
const program = @import("program.zig");

pub const Error = error{ OutOfMemory, InstructionLimit, InvalidSyntax };

const inline_bit_state_root_map_capacity: usize = 256;

/// Facts and roots depend on byte encoding, execution direction, and the
/// compiler-selected nullable priority policy.
pub const Options = struct {
    encoding: byte_encoding.Encoding,
    reverse: bool,
    root_policy: priority_lists.RootPolicy,
};

/// Single-owner publication transaction. `value == null` means ownership was
/// transferred successfully; otherwise deferred teardown releases all fields.
const ProgramBuild = struct {
    allocator: std.mem.Allocator,
    value: ?program.Program,

    fn init(allocator: std.mem.Allocator, capture_slots: u32) ProgramBuild {
        return .{
            .allocator = allocator,
            .value = .{ .capture_slots = capture_slots },
        };
    }

    fn deinit(self: *ProgramBuild) void {
        if (self.value) |*value| value.deinit(self.allocator);
        self.* = undefined;
    }

    /// Validates the fully populated Program, then clears transaction ownership and
    /// returns the value by move.
    fn finish(self: *ProgramBuild) Error!program.Program {
        const value = &self.value.?;
        value.validate() catch return error.InvalidSyntax;
        const published = value.*;
        self.value = null;
        return published;
    }
};

/// Converts one validated graph and its source syntax into complete runtime
/// storage. No Graph slice or syntax node is retained in the returned Program.
pub fn publish(
    allocator: std.mem.Allocator,
    tree: *const syntax.Regexp,
    root: syntax.NodeId,
    graph: *const program.Graph,
    capture_slots: u32,
    options: Options,
) Error!program.Program {
    graph.validate() catch return error.InvalidSyntax;

    var build = ProgramBuild.init(allocator, capture_slots);
    defer build.deinit();
    const result = &build.value.?;

    var prefix_fold_ascii = false;
    result.prefix = if (options.reverse)
        &.{}
    else
        try facts.requiredPrefix(allocator, tree, root, options.encoding, &prefix_fold_ascii);

    result.anchor_start = try facts.hasDirectionalTextAnchor(allocator, graph, options.reverse);
    result.priority_lists = try priority_lists.build(allocator, graph, options.root_policy);

    if (tree.node(root).* == .empty) {
        result.byte_classes = .{ .external = @constCast(&program.empty_byte_map) };
        result.byte_class_count = 1;
    } else {
        const partition = try byte_map.build(allocator, graph.instructions);
        result.byte_classes = .{ .allocated = partition.map };
        result.byte_class_count = partition.count;
    }

    var empty_bits: u32 = 0;
    var uses_empty_width = false;
    // Derive assertion metadata from reachable runtime leaves, never from
    // compile-graph instructions discarded by priority-list construction.
    for (result.priority_lists.leaves) |leaf| {
        if (leaf.opcode() == .empty_width) {
            uses_empty_width = true;
            empty_bits |= @bitCast(leaf.emptyMask());
        }
    }
    const empty_mask: program.EmptyMask = @bitCast(empty_bits);
    const anchor_line_start = !options.reverse and facts.requiresLineStart(tree, root);
    const prefix_shape = facts.classifyPrefix(
        tree,
        root,
        result.prefix,
        prefix_fold_ascii,
        options.encoding,
    );

    result.required_suffix = if (options.reverse or prefix_shape.complete)
        .{}
    else
        facts.requiredSuffix(tree, root, options.encoding);
    // Omit only an exact duplicate of `prefix`. A longer interior run is still
    // valuable: it rejects sparse haystacks before a short prefix creates many
    // candidates, while rare positive ranges pay one additional bounded scan.
    const interior = if (options.reverse)
        program.RequiredLiteral{}
    else
        try facts.requiredLiteral(allocator, tree, root, options.encoding);
    result.required_literal = if (interior.len == result.prefix.len and
        interior.fold_ascii == prefix_fold_ascii and
        std.mem.eql(u8, interior.bytes[0..interior.len], result.prefix))
        .{}
    else
        interior;

    result.prefix_fold_ascii = prefix_fold_ascii;
    result.prefix_complete = prefix_shape.complete;
    result.uses_empty_width = uses_empty_width;
    result.anchor_end = !options.reverse and facts.requiresTextEnd(tree, root);
    result.empty_mask_union = empty_mask;
    result.anchor_line_start = anchor_line_start;
    result.all_captures_whole = facts.allCapturesWhole(tree, root);
    if (prefix_shape.tail) |tail| {
        result.prefix_has_tail_range = true;
        result.prefix_tail_lo = tail.lo;
        result.prefix_tail_hi = tail.hi;
    }

    if (!options.reverse) {
        if (shapes.classifyRepeatedByte(tree, root, result.prefix, options.encoding)) |shape| {
            result.plans.repeat_byte_ranges = shape.ranges;
            result.plans.repeat_byte_range_count = shape.range_count;
            result.plans.repeat_byte_min = shape.min;
            result.plans.repeat_byte_max = shape.max;
            result.plans.repeat_byte_after_prefix = shape.after_prefix;
            result.plans.repeat_byte_left_word_boundary = shape.left_word_boundary;
            result.plans.repeat_byte_right_word_boundary = shape.right_word_boundary;
        } else if (shapes.classifyLeadingByteRepeat(tree, root)) |shape| {
            result.plans.repeat_byte_ranges = shape.repeated.ranges;
            result.plans.repeat_byte_range_count = shape.repeated.range_count;
            result.plans.repeat_byte_min = shape.repeated.min;
            result.plans.repeat_byte_max = shape.repeated.max;
            result.plans.repeat_byte_initial_ranges = shape.initial_ranges;
            result.plans.repeat_byte_initial_range_count = shape.initial_range_count;
        }
    }

    var local_bit_state_map: [inline_bit_state_root_map_capacity]u32 = undefined;
    const bit_state_map = if (result.priority_lists.lists.len <= local_bit_state_map.len)
        local_bit_state_map[0..result.priority_lists.lists.len]
    else
        try allocator.alloc(u32, result.priority_lists.lists.len);
    defer if (bit_state_map.ptr != local_bit_state_map[0..].ptr)
        allocator.free(bit_state_map);
    result.plans.bit_state_root_count = result.fillBitStateRootMap(bit_state_map);

    return build.finish();
}

const builder_module = @import("builder.zig");
const testing = std.testing;

test "Publication owns and validates all runtime allocations" {
    var tree: syntax.Regexp = .{};
    defer tree.deinit(testing.allocator);
    const root = try tree.addNode(testing.allocator, .empty);
    tree.root = root;

    var builder = try builder_module.Builder.init(testing.allocator, 10);
    defer builder.deinit();
    const accepting = try builder.addMatch(@enumFromInt(0));
    const scan = try builder.addByteRange(0, 0xff, false);
    const unanchored = try builder.addSplit(accepting, scan[0]);
    builder.patch(scan[1], unanchored[0]);
    var graph = try builder.finish(accepting, unanchored[0], 2);
    defer graph.deinit(testing.allocator);

    var result = try publish(testing.allocator, &tree, root, &graph, 2, .{
        .encoding = .utf8,
        .reverse = false,
        .root_policy = .successor_roots,
    });
    defer result.deinit(testing.allocator);
    try result.validate();
    try testing.expect(result.byte_classes == .external);
    try testing.expectEqual(@as(u16, 1), result.byte_class_count);
    try testing.expectEqual(@as(usize, 0), result.prefix.len);
}
