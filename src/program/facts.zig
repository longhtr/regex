//! Conservative syntax/graph facts attached to an immutable Program.
//!
//! Every function follows the same soundness rule: returning less information is
//! safe, while claiming a fact that is not true on every successful path could
//! change matching. Analyses therefore stop at ambiguity, variable repetition,
//! folding they cannot encode, or unsupported structure.
//!
//! Syntax analyses derive:
//!
//! - exact required prefix/suffix bytes and a bounded mandatory interior literal;
//! - mandatory line-start and absolute-end assertions on every branch;
//! - whether all explicit captures always equal the whole match;
//! - exact literal byte lengths and encodings for eligible subtrees.
//!
//! Directional absolute anchoring is graph-based because reverse compilation
//! changes which assertion constrains the execution start. That traversal uses
//! explicit work/visited storage and examines only reachable control flow.
//!
//! Prefix/suffix extraction is encoding-aware: Latin-1 emits one byte, UTF-8
//! emits canonical bytes, and folded output is retained only when a supported
//! ASCII comparison is sound. Required suffixes are bounded and may be shortened
//! at the first variable node. All potentially deep walks use explicit stacks or
//! conservative fixed-capacity termination rather than recursion.

const std = @import("std");
const byte_encoding = @import("byte_encoding.zig");
const program = @import("program.zig");
const syntax = @import("../syntax/regexp.zig");

pub const Encoding = byte_encoding.Encoding;

const required_suffix_stack_capacity: usize = 128;
const inline_graph_analysis_capacity: usize = 256;

/// Stronger classification layered on the separately extracted required prefix.
/// `complete` means the prefix is the entire language; `tail` means exactly one
/// additional byte from that closed interval.
pub const PrefixShape = struct {
    complete: bool = false,
    tail: ?struct { lo: u8, hi: u8 } = null,
};

fn unwrapCaptures(tree: *const syntax.Regexp, initial: syntax.NodeId) syntax.NodeId {
    var current = initial;
    while (tree.node(current).* == .capture) current = tree.node(current).capture.child;
    return current;
}

/// Recognizes exact literal and literal-plus-single-byte languages after
/// transparent captures/empty wrappers. Any folding or encoding ambiguity
/// returns the conservative empty classification.
pub fn classifyPrefix(
    tree: *const syntax.Regexp,
    root: syntax.NodeId,
    prefix: []const u8,
    fold_ascii: bool,
    encoding: Encoding,
) PrefixShape {
    if (prefix.len == 0) return .{};
    var current = root;
    while (tree.node(current).* == .capture)
        current = tree.node(current).capture.child;

    switch (tree.node(current).*) {
        .literal => |literal| {
            if (literal.fold != fold_ascii) return .{};
            if (literalByteLength(tree, literal, encoding) == prefix.len)
                return .{ .complete = true };
        },
        .alternate => |span| {
            if (fold_ascii) return .{};
            var tails: [256]bool = @splat(false);
            var lo: u8 = std.math.maxInt(u8);
            var hi: u8 = 0;
            var count: usize = 0;
            for (tree.nodeChildren(span)) |child_id| {
                const child = tree.node(child_id).*;
                if (child != .literal or child.literal.fold) return .{};
                const tail = literalTail(tree, child.literal, prefix.len, encoding) orelse
                    return .{};
                if (tails[tail]) return .{};
                tails[tail] = true;
                lo = @min(lo, tail);
                hi = @max(hi, tail);
                count += 1;
            }
            if (@as(usize, hi) - lo + 1 == count) return .{
                .tail = .{ .lo = lo, .hi = hi },
            };
        },
        else => {},
    }
    return .{};
}

/// Returns true only when every top-level branch begins with a begin-line
/// assertion before any consuming expression. Kept deliberately strict: a
/// nullable consumer before the assertion would let the match begin earlier.
pub fn requiresLineStart(tree: *const syntax.Regexp, root: syntax.NodeId) bool {
    const current = unwrapCaptures(tree, root);
    return switch (tree.node(current).*) {
        .begin_line => true,
        .concat => |span| blk: {
            for (tree.nodeChildren(span)) |child| {
                const node = tree.node(unwrapCaptures(tree, child)).*;
                switch (node) {
                    .empty, .begin_text, .end_text, .end_line, .word_boundary, .not_word_boundary => continue,
                    .begin_line => break :blk true,
                    else => break :blk false,
                }
            }
            break :blk false;
        },
        // Alternations are left conservative; recognizing nested branches
        // requires the same explicit-work traversal used by other analyses.
        .alternate => false,
        else => false,
    };
}

/// Returns true only when every successful path must pass an absolute
/// end-text assertion after its final consumer. Alternation is recursive so a
/// mixed anchored/unanchored branch can never publish this fact.
pub fn requiresTextEnd(tree: *const syntax.Regexp, root: syntax.NodeId) bool {
    const current = unwrapCaptures(tree, root);
    return switch (tree.node(current).*) {
        .end_text => true,
        .concat => |span| blk: {
            const children = tree.nodeChildren(span);
            var index = children.len;
            while (index != 0) {
                index -= 1;
                const child = unwrapCaptures(tree, children[index]);
                switch (tree.node(child).*) {
                    .empty,
                    .begin_text,
                    .begin_line,
                    .end_line,
                    .word_boundary,
                    .not_word_boundary,
                    => continue,
                    .end_text => break :blk true,
                    .alternate => break :blk requiresTextEnd(tree, child),
                    .repeat => |repeat| break :blk repeat.min != 0 and
                        requiresTextEnd(tree, repeat.child),
                    else => break :blk false,
                }
            }
            break :blk false;
        },
        .alternate => |span| blk: {
            const children = tree.nodeChildren(span);
            if (children.len == 0) break :blk false;
            for (children) |child|
                if (!requiresTextEnd(tree, child)) break :blk false;
            break :blk true;
        },
        .repeat => |repeat| repeat.min != 0 and requiresTextEnd(tree, repeat.child),
        else => false,
    };
}

/// Proves that every explicit capture wraps the same effective subtree as the
/// whole expression, allowing all slots to alias one located range.
pub fn allCapturesWhole(tree: *const syntax.Regexp, root: syntax.NodeId) bool {
    if (tree.capture_count == 0) return true;
    var current = root;
    var wrappers: u32 = 0;
    while (true) switch (tree.node(current).*) {
        .capture => |capture| {
            wrappers += 1;
            current = capture.child;
        },
        .concat => |span| {
            var consuming: ?syntax.NodeId = null;
            for (tree.nodeChildren(span)) |child| {
                if (isTransparentEmpty(tree.node(child).*)) continue;
                if (consuming != null) return false;
                consuming = child;
            }
            current = consuming orelse return false;
        },
        else => return wrappers == tree.capture_count,
    };
}

/// Extracts the longest initial byte string present on every successful path.
/// Alternation intersects branch prefixes; variable nodes stop extension. The
/// caller owns the returned bytes.
pub fn requiredPrefix(
    allocator: std.mem.Allocator,
    tree: *const syntax.Regexp,
    root: syntax.NodeId,
    encoding: Encoding,
    fold_ascii: *bool,
) error{OutOfMemory}![]const u8 {
    var nodes: std.ArrayList(syntax.NodeId) = .empty;
    defer nodes.deinit(allocator);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try nodes.append(allocator, root);

    prefix: while (nodes.pop()) |id| {
        switch (tree.node(id).*) {
            .empty,
            .begin_line,
            .end_line,
            .begin_text,
            .end_text,
            .word_boundary,
            .not_word_boundary,
            => {},
            .capture => |capture| try nodes.append(allocator, capture.child),
            .concat => |span| {
                const children = tree.nodeChildren(span);
                var index = children.len;
                while (index > 0) {
                    index -= 1;
                    try nodes.append(allocator, children[index]);
                }
            },
            .literal => |literal| {
                if (literal.fold) {
                    if (bytes.items.len != 0 and !fold_ascii.*) break :prefix;
                    fold_ascii.* = true;
                    for (tree.literalRunes(literal.runes)) |rune| {
                        if (rune > 0x7f or (encoding == .utf8 and
                            (rune == 'k' or rune == 'K' or rune == 's' or rune == 'S'))) break :prefix;
                        try bytes.append(allocator, std.ascii.toLower(@intCast(rune)));
                    }
                } else {
                    if (fold_ascii.*) break :prefix;
                    try appendLiteralBytes(allocator, tree, &bytes, literal, encoding);
                }
            },
            .char_class => |span| {
                const lower = asciiFoldClass(tree, span) orelse break :prefix;
                if (bytes.items.len != 0 and !fold_ascii.*) break :prefix;
                fold_ascii.* = true;
                try bytes.append(allocator, lower);
            },
            .repeat => |repeat| {
                if (repeat.min != 0)
                    _ = try appendNodePrefix(allocator, tree, repeat.child, &bytes, encoding);
                break :prefix;
            },
            .alternate => |span| {
                const children = tree.nodeChildren(span);
                var common: std.ArrayList(u8) = .empty;
                defer common.deinit(allocator);
                _ = try appendNodePrefix(allocator, tree, children[0], &common, encoding);
                for (children[1..]) |child| {
                    var candidate: std.ArrayList(u8) = .empty;
                    defer candidate.deinit(allocator);
                    _ = try appendNodePrefix(allocator, tree, child, &candidate, encoding);
                    const limit = @min(common.items.len, candidate.items.len);
                    var shared: usize = 0;
                    while (shared < limit and common.items[shared] == candidate.items[shared])
                        shared += 1;
                    common.shrinkRetainingCapacity(shared);
                    if (shared == 0) break;
                }
                try bytes.appendSlice(allocator, common.items);
                break :prefix;
            },
            else => break :prefix,
        }
    }
    if (bytes.items.len == 0) {
        fold_ascii.* = false;
        bytes.deinit(allocator);
        return &.{};
    }
    return bytes.toOwnedSlice(allocator);
}

/// Per-node proof used by `requiredLiteral`. `fixed` is valid only when the
/// node consumes exactly those bytes on every success; `required` may occur at
/// any node-relative offset. Both representations are bounded, so an oversized
/// fixed string becomes a valid required prefix but cannot be concatenated as
/// though it were complete.
const LiteralSummary = struct {
    possible: bool = true,
    fixed_valid: bool = false,
    fixed: program.RequiredLiteral = .{},
    required: program.RequiredLiteral = .{},
};

const LiteralTask = struct { id: syntax.NodeId, finish: bool };

/// Proves one bounded byte string occurs in every successful match. The
/// postorder analysis is iterative, handles captures transparently, joins
/// adjacent fixed children inside concatenation, and intersects alternation
/// only when every live branch publishes the same proof. It deliberately does
/// not infer a match-relative offset: consumers may reject a range when the
/// literal is absent but may not begin execution at its occurrence.
pub fn requiredLiteral(
    allocator: std.mem.Allocator,
    tree: *const syntax.Regexp,
    root: syntax.NodeId,
    encoding: Encoding,
) error{OutOfMemory}!program.RequiredLiteral {
    const summaries = try allocator.alloc(LiteralSummary, tree.nodes.items.len);
    defer allocator.free(summaries);
    const done = try allocator.alloc(bool, tree.nodes.items.len);
    defer allocator.free(done);
    @memset(done, false);
    var tasks: std.ArrayList(LiteralTask) = .empty;
    defer tasks.deinit(allocator);
    try tasks.append(allocator, .{ .id = root, .finish = false });
    while (tasks.pop()) |task| {
        const index = @intFromEnum(task.id);
        if (done[index]) continue;
        const node = tree.node(task.id).*;
        if (!task.finish) {
            try tasks.append(allocator, .{ .id = task.id, .finish = true });
            switch (node) {
                .capture => |capture| try tasks.append(allocator, .{ .id = capture.child, .finish = false }),
                .repeat => |repeat| try tasks.append(allocator, .{ .id = repeat.child, .finish = false }),
                .concat, .alternate => |span| {
                    const children = tree.nodeChildren(span);
                    var child_index = children.len;
                    while (child_index != 0) {
                        child_index -= 1;
                        if (!done[@intFromEnum(children[child_index])])
                            try tasks.append(allocator, .{ .id = children[child_index], .finish = false });
                    }
                },
                else => {},
            }
            continue;
        }
        summaries[index] = summarizeLiteralNode(tree, summaries, node, encoding);
        done[index] = true;
    }
    return summaries[@intFromEnum(root)].required;
}

/// Reduces one postorder syntax node to fixed-string and mandatory-substring
/// proofs. Every syntax tag is explicit so a future tag cannot accidentally
/// inherit a positive, potentially unsound fact.
fn summarizeLiteralNode(
    tree: *const syntax.Regexp,
    summaries: []const LiteralSummary,
    node: syntax.Node,
    encoding: Encoding,
) LiteralSummary {
    return switch (node) {
        .no_match => .{ .possible = false },
        .empty, .begin_line, .end_line, .begin_text, .end_text, .word_boundary, .not_word_boundary => .{
            .fixed_valid = true,
        },
        .literal => |literal| summarizeLiteral(tree, literal, encoding),
        .char_class => |span| summarizeLiteralClass(tree, span, encoding),
        .capture => |capture| summaries[@intFromEnum(capture.child)],
        .repeat => |repeat| summarizeLiteralRepeat(summaries[@intFromEnum(repeat.child)], repeat),
        .concat => |span| summarizeLiteralConcat(tree.nodeChildren(span), summaries),
        .alternate => |span| summarizeLiteralAlternate(tree.nodeChildren(span), summaries),
        .any_char, .any_byte => .{},
    };
}

/// Converts one syntax literal into a bounded byte proof. Exact scalars encode
/// directly; folded literals are admitted only when ASCII bytes represent every
/// fold peer. Truncation or a non-ASCII fold peer keeps the collected prefix as
/// required but clears `fixed_valid` so parents cannot treat it as complete.
fn summarizeLiteral(
    tree: *const syntax.Regexp,
    literal: syntax.Literal,
    encoding: Encoding,
) LiteralSummary {
    var value = program.RequiredLiteral{ .fold_ascii = literal.fold };
    var complete = true;
    for (tree.literalRunes(literal.runes)) |rune| {
        if (literal.fold) {
            if (rune > 0x7f or (encoding == .utf8 and
                (rune == 'k' or rune == 'K' or rune == 's' or rune == 'S')))
            {
                complete = false;
                break;
            }
            if (!appendLiteralByte(&value, std.ascii.toLower(@intCast(rune)))) {
                complete = false;
                break;
            }
        } else if (encoding == .latin1) {
            if (rune > 0xff or !appendLiteralByte(&value, @intCast(rune))) {
                complete = false;
                break;
            }
        } else {
            const encoded = byte_encoding.encodeRune(rune);
            for (encoded.ranges[0..encoded.len]) |range| {
                std.debug.assert(range.lo == range.hi);
                if (!appendLiteralByte(&value, range.lo)) {
                    complete = false;
                    break;
                }
            }
            if (!complete) break;
        }
    }
    if (value.len == 0) value.fold_ascii = false;
    return .{
        .fixed_valid = complete,
        .fixed = value,
        .required = value,
    };
}

/// Publishes a fixed literal only for one exact encoded scalar or a supported
/// ASCII simple-fold pair; broader classes deliberately contribute no claim.
fn summarizeLiteralClass(
    tree: *const syntax.Regexp,
    span: syntax.RangeSpan,
    encoding: Encoding,
) LiteralSummary {
    if (asciiFoldClass(tree, span)) |byte| {
        const value = requiredLiteralByte(byte, true);
        return .{ .fixed_valid = true, .fixed = value, .required = value };
    }
    const ranges = tree.classRanges(span);
    if (ranges.len != 1 or ranges[0].lo != ranges[0].hi) return .{};
    const rune = ranges[0].lo;
    var value = program.RequiredLiteral{};
    if (encoding == .latin1) {
        if (rune > 0xff) return .{ .possible = false };
        _ = appendLiteralByte(&value, @intCast(rune));
    } else {
        const encoded = byte_encoding.encodeRune(rune);
        for (encoded.ranges[0..encoded.len]) |range| {
            std.debug.assert(range.lo == range.hi);
            _ = appendLiteralByte(&value, range.lo);
        }
    }
    return .{ .fixed_valid = true, .fixed = value, .required = value };
}

/// Propagates necessity through repetition. Optional copies erase a mandatory
/// claim; an exact count becomes fixed only when every copied byte fits the
/// bounded summary.
fn summarizeLiteralRepeat(child: LiteralSummary, repeat: syntax.Repeat) LiteralSummary {
    if (repeat.max != null and repeat.max.? == 0) return .{ .fixed_valid = true };
    if (!child.possible) return if (repeat.min == 0)
        .{ .fixed_valid = true }
    else
        .{ .possible = false };
    var result = LiteralSummary{
        .required = if (repeat.min != 0) child.required else .{},
    };
    if (repeat.max == null or repeat.max.? != repeat.min or !child.fixed_valid)
        return result;
    result.fixed_valid = true;
    // Repeating an assertion-only fixed child remains empty regardless of a
    // potentially very large admitted bound; avoid work proportional to it.
    if (child.fixed.len == 0) return result;
    for (0..repeat.min) |_| {
        if (!appendLiteral(&result.fixed, child.fixed)) {
            result.fixed_valid = false;
            break;
        }
    }
    chooseLonger(&result.required, result.fixed);
    return result;
}

/// Joins adjacent fixed children into longer mandatory runs while retaining the
/// strongest child-local proof on either side of variable syntax.
fn summarizeLiteralConcat(
    children: []const syntax.NodeId,
    summaries: []const LiteralSummary,
) LiteralSummary {
    var result = LiteralSummary{ .fixed_valid = true };
    var run = program.RequiredLiteral{};
    for (children) |child_id| {
        const child = summaries[@intFromEnum(child_id)];
        if (!child.possible) return .{ .possible = false };
        chooseLonger(&result.required, child.required);
        if (child.fixed_valid) {
            if (!appendLiteral(&run, child.fixed)) {
                chooseLonger(&result.required, run);
                run = child.fixed;
            }
            if (result.fixed_valid and !appendLiteral(&result.fixed, child.fixed))
                result.fixed_valid = false;
        } else {
            chooseLonger(&result.required, run);
            run = .{};
            result.fixed_valid = false;
        }
    }
    chooseLonger(&result.required, run);
    if (result.fixed_valid) chooseLonger(&result.required, result.fixed);
    return result;
}

/// Intersects possible branches: every live alternative must publish identical
/// bytes before the parent can claim them as fixed or mandatory.
fn summarizeLiteralAlternate(
    children: []const syntax.NodeId,
    summaries: []const LiteralSummary,
) LiteralSummary {
    var result = LiteralSummary{ .possible = false, .fixed_valid = true };
    var first = true;
    for (children) |child_id| {
        const child = summaries[@intFromEnum(child_id)];
        if (!child.possible) continue;
        if (first) {
            result = child;
            first = false;
            continue;
        }
        result.fixed_valid = result.fixed_valid and child.fixed_valid and
            literalEqual(result.fixed, child.fixed);
        if (!result.fixed_valid) result.fixed = .{};
        if (!literalEqual(result.required, child.required)) result.required = .{};
    }
    return result;
}

fn requiredLiteralByte(byte: u8, fold_ascii: bool) program.RequiredLiteral {
    var value = program.RequiredLiteral{ .fold_ascii = fold_ascii };
    _ = appendLiteralByte(&value, byte);
    return value;
}

fn appendLiteralByte(value: *program.RequiredLiteral, byte: u8) bool {
    if (value.len == value.bytes.len) return false;
    value.bytes[value.len] = byte;
    value.len += 1;
    return true;
}

/// Appends a complete fixed byte string when one comparison mode can represent
/// both operands. Exact ASCII punctuation may join folded text because folding
/// leaves it unchanged; exact letters may not be widened to folded matching.
fn appendLiteral(target: *program.RequiredLiteral, suffix: program.RequiredLiteral) bool {
    if (suffix.len == 0) return true;
    if (target.len == 0) {
        target.* = suffix;
        return true;
    }
    if (target.fold_ascii != suffix.fold_ascii) {
        if (suffix.fold_ascii) {
            if (containsAsciiLetter(target.bytes[0..target.len])) return false;
            target.fold_ascii = true;
        } else if (containsAsciiLetter(suffix.bytes[0..suffix.len])) {
            return false;
        }
    }
    if (suffix.len > target.bytes.len - target.len) return false;
    @memcpy(target.bytes[target.len..][0..suffix.len], suffix.bytes[0..suffix.len]);
    target.len += suffix.len;
    return true;
}

fn containsAsciiLetter(bytes: []const u8) bool {
    for (bytes) |byte| if (std.ascii.isAlphabetic(byte)) return true;
    return false;
}

fn literalEqual(left: program.RequiredLiteral, right: program.RequiredLiteral) bool {
    return left.len == right.len and left.fold_ascii == right.fold_ascii and
        std.mem.eql(u8, left.bytes[0..left.len], right.bytes[0..right.len]);
}

fn chooseLonger(target: *program.RequiredLiteral, candidate: program.RequiredLiteral) void {
    if (candidate.len > target.len or (candidate.len == target.len and
        target.fold_ascii and !candidate.fold_ascii))
        target.* = candidate;
}

/// Returns up to `program.max_required_suffix_bytes` exact trailing bytes that
/// every match must contain. The walk proceeds from the right edge and stops at
/// the first variable node, so
/// optional or ambiguous syntax can only shorten the result, never make it
/// unsound.
pub fn requiredSuffix(
    tree: *const syntax.Regexp,
    root: syntax.NodeId,
    encoding: Encoding,
) program.RequiredSuffix {
    var result = program.RequiredSuffix{};
    var fold_mode: ?bool = null;
    var stack: [required_suffix_stack_capacity]syntax.NodeId = undefined;
    var stack_len: usize = 1;
    stack[0] = root;

    suffix: while (stack_len != 0 and result.len < result.bytes.len) {
        stack_len -= 1;
        const id = stack[stack_len];
        switch (tree.node(id).*) {
            .empty,
            .begin_line,
            .end_line,
            .begin_text,
            .end_text,
            .word_boundary,
            .not_word_boundary,
            => {},
            .capture => |capture| {
                if (stack_len == stack.len) break :suffix;
                stack[stack_len] = capture.child;
                stack_len += 1;
            },
            .concat => |span| {
                const children = tree.nodeChildren(span);
                if (children.len > stack.len - stack_len) break :suffix;
                // LIFO traversal visits the rightmost child first.
                for (children) |child| {
                    stack[stack_len] = child;
                    stack_len += 1;
                }
            },
            .literal => |literal| {
                if (fold_mode) |fold| {
                    if (fold != literal.fold) break :suffix;
                } else fold_mode = literal.fold;
                const runes = tree.literalRunes(literal.runes);
                var rune_index = runes.len;
                while (rune_index > 0 and result.len < result.bytes.len) {
                    rune_index -= 1;
                    const rune = runes[rune_index];
                    if (literal.fold) {
                        if (rune > 0x7f or (encoding == .utf8 and
                            (rune == 'k' or rune == 'K' or rune == 's' or rune == 'S')))
                            break :suffix;
                        result.bytes[result.len] = std.ascii.toLower(@intCast(rune));
                        result.len += 1;
                    } else if (encoding == .latin1) {
                        if (rune > 0xff) break :suffix;
                        result.bytes[result.len] = @intCast(rune);
                        result.len += 1;
                    } else {
                        const encoded = byte_encoding.encodeRune(rune);
                        var byte_index: usize = encoded.len;
                        while (byte_index > 0 and result.len < result.bytes.len) {
                            byte_index -= 1;
                            const range = encoded.ranges[byte_index];
                            std.debug.assert(range.lo == range.hi);
                            result.bytes[result.len] = range.lo;
                            result.len += 1;
                        }
                    }
                }
            },
            .char_class => |span| {
                if (fold_mode) |fold| {
                    if (fold) break :suffix;
                } else fold_mode = false;
                const ranges = tree.classRanges(span);
                if (ranges.len != 1 or ranges[0].lo != ranges[0].hi) break :suffix;
                const rune = ranges[0].lo;
                if (encoding == .latin1) {
                    if (rune > 0xff) break :suffix;
                    result.bytes[result.len] = @intCast(rune);
                    result.len += 1;
                } else {
                    const encoded = byte_encoding.encodeRune(rune);
                    var byte_index: usize = encoded.len;
                    while (byte_index > 0 and result.len < result.bytes.len) {
                        byte_index -= 1;
                        const range = encoded.ranges[byte_index];
                        std.debug.assert(range.lo == range.hi);
                        result.bytes[result.len] = range.lo;
                        result.len += 1;
                    }
                }
            },
            else => break :suffix,
        }
    }
    std.mem.reverse(u8, result.bytes[0..result.len]);
    result.fold_ascii = result.len != 0 and (fold_mode orelse false);
    return result;
}

/// Proves that every execution path begins with the direction-appropriate
/// absolute-text assertion before consuming a byte. Graph traversal represents
/// epsilon control and reverse compilation exactly.
pub fn hasDirectionalTextAnchor(
    allocator: std.mem.Allocator,
    graph: *const program.Graph,
    reverse: bool,
) error{OutOfMemory}!bool {
    var local_seen: [inline_graph_analysis_capacity]bool = undefined;
    var local_work: [inline_graph_analysis_capacity]program.InstId = undefined;
    const seen = if (graph.instructions.len <= local_seen.len)
        local_seen[0..graph.instructions.len]
    else
        try allocator.alloc(bool, graph.instructions.len);
    defer if (seen.ptr != local_seen[0..].ptr) allocator.free(seen);
    const work = if (graph.instructions.len <= local_work.len)
        local_work[0..graph.instructions.len]
    else
        try allocator.alloc(program.InstId, graph.instructions.len);
    defer if (work.ptr != local_work[0..].ptr) allocator.free(work);
    @memset(seen, false);
    var work_len: usize = 1;
    work[0] = graph.start;
    seen[@intFromEnum(graph.start)] = true;
    var found_anchor = false;
    while (work_len != 0) {
        work_len -= 1;
        const instruction = graph.inst(work[work_len]);
        var successors: [2]program.InstId = undefined;
        const successor_count: usize = switch (instruction.opcode()) {
            .fail => 0,
            .jump, .capture => blk: {
                successors[0] = instruction.out();
                break :blk 1;
            },
            .split => blk: {
                successors = .{ instruction.out(), instruction.alternate() };
                break :blk 2;
            },
            .empty_width => blk: {
                const mask = instruction.emptyMask();
                if ((!reverse and mask.begin_text) or (reverse and mask.end_text)) {
                    found_anchor = true;
                    break :blk 0;
                }
                successors[0] = instruction.out();
                break :blk 1;
            },
            .byte_range, .match => return false,
        };
        for (successors[0..successor_count]) |successor| {
            const index = @intFromEnum(successor);
            if (seen[index]) continue;
            seen[index] = true;
            work[work_len] = successor;
            work_len += 1;
        }
    }
    return found_anchor;
}

/// Returns the encoded length of one non-folded literal. Latin-1 values outside
/// its byte domain return `maxInt(usize)` as a non-length sentinel.
pub fn literalByteLength(
    tree: *const syntax.Regexp,
    literal: syntax.Literal,
    encoding: Encoding,
) usize {
    var length: usize = 0;
    for (tree.literalRunes(literal.runes)) |rune| {
        if (encoding == .latin1) {
            if (rune > 0xff) return std.math.maxInt(usize);
            length += 1;
        } else {
            length += byte_encoding.utf8Length(rune);
        }
    }
    return length;
}

fn literalTail(
    tree: *const syntax.Regexp,
    literal: syntax.Literal,
    prefix_len: usize,
    encoding: Encoding,
) ?u8 {
    if (literalByteLength(tree, literal, encoding) != prefix_len + 1) return null;
    const runes = tree.literalRunes(literal.runes);
    const rune = runes[runes.len - 1];
    if (encoding == .latin1) return @intCast(rune);
    const encoded = byte_encoding.encodeRune(rune);
    return encoded.ranges[encoded.len - 1].lo;
}

fn asciiFoldClass(tree: *const syntax.Regexp, span: syntax.RangeSpan) ?u8 {
    const ranges = tree.classRanges(span);
    if (ranges.len != 2 or ranges[0].lo != ranges[0].hi or
        ranges[1].lo != ranges[1].hi or ranges[0].lo < 'A' or
        ranges[0].lo > 'Z' or ranges[1].lo != ranges[0].lo + ('a' - 'A')) return null;
    return @intCast(ranges[1].lo);
}

/// Iteratively appends bytes from a subtree containing only exact literals and
/// transparent epsilon/capture/concat structure. False means prefix extension
/// must stop conservatively.
fn appendNodePrefix(
    allocator: std.mem.Allocator,
    tree: *const syntax.Regexp,
    root: syntax.NodeId,
    output: *std.ArrayList(u8),
    encoding: Encoding,
) error{OutOfMemory}!bool {
    var nodes: std.ArrayList(syntax.NodeId) = .empty;
    defer nodes.deinit(allocator);
    try nodes.append(allocator, root);
    while (nodes.pop()) |id| switch (tree.node(id).*) {
        .empty,
        .begin_line,
        .end_line,
        .begin_text,
        .end_text,
        .word_boundary,
        .not_word_boundary,
        => {},
        .capture => |capture| try nodes.append(allocator, capture.child),
        .concat => |span| {
            const children = tree.nodeChildren(span);
            var index = children.len;
            while (index > 0) {
                index -= 1;
                try nodes.append(allocator, children[index]);
            }
        },
        .literal => |literal| {
            if (literal.fold) return false;
            try appendLiteralBytes(allocator, tree, output, literal, encoding);
        },
        else => return false,
    };
    return true;
}

/// Appends one literal's exact encoding. Callers establish non-folding and
/// encoding eligibility before invoking this low-level helper.
pub fn appendLiteralBytes(
    allocator: std.mem.Allocator,
    tree: *const syntax.Regexp,
    output: *std.ArrayList(u8),
    literal: syntax.Literal,
    encoding: Encoding,
) error{OutOfMemory}!void {
    for (tree.literalRunes(literal.runes)) |value| {
        if (encoding == .latin1) {
            if (value > 0xff) return;
            try output.append(allocator, @intCast(value));
        } else {
            const encoded = byte_encoding.encodeRune(value);
            for (encoded.ranges[0..encoded.len]) |range| {
                std.debug.assert(range.lo == range.hi);
                try output.append(allocator, range.lo);
            }
        }
    }
}

fn isTransparentEmpty(node: syntax.Node) bool {
    return switch (node) {
        .empty,
        .begin_line,
        .end_line,
        .begin_text,
        .end_text,
        .word_boundary,
        .not_word_boundary,
        => true,
        else => false,
    };
}

const parser_module = @import("../syntax/parser.zig");
const testing = std.testing;

fn parseFactPattern(pattern: []const u8) !syntax.Regexp {
    const parsed = try parser_module.parse(testing.allocator, pattern, .{
        .perl_classes = true,
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    return switch (parsed) {
        .success => |tree| tree,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

test "Required interior literal joins fixed runs without crossing optional syntax" {
    const cases = [_]struct {
        pattern: []const u8,
        expected: []const u8,
        folded: bool = false,
    }{
        .{ .pattern = "a*(needle)[0-9]?", .expected = "needle" },
        .{ .pattern = "(?:xx|yy)needle", .expected = "needle" },
        .{ .pattern = "foo|bar", .expected = "" },
        .{ .pattern = "(?:mandatory)?", .expected = "" },
        .{
            .pattern = "(\\s*)((?:# [Nn][Oo][Qq][Aa])(?::\\s?(([A-Z]+[0-9]+(?:[,\\s]+)?)+))?)",
            .expected = "# noqa",
            .folded = true,
        },
    };
    for (cases) |case| {
        var tree = try parseFactPattern(case.pattern);
        defer tree.deinit(testing.allocator);
        const literal = try requiredLiteral(
            testing.allocator,
            &tree,
            tree.root.?,
            .utf8,
        );
        try testing.expectEqualStrings(case.expected, literal.bytes[0..literal.len]);
        try testing.expectEqual(case.folded, literal.fold_ascii);
    }
}
