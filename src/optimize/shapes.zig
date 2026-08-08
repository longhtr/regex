//! Exact syntax classifiers for optional direct byte execution.
//!
//! These functions inspect parser syntax after transparent captures/empty
//! wrappers are removed. They recognize only languages whose maximal
//! non-overlapping matching can be implemented by simple byte loops: repeated
//! ASCII byte classes, optionally after a fixed literal prefix, and a leading
//! ASCII class followed by another repeated class.
//!
//! A returned shape contains all semantics the direct executor needs: inclusive
//! byte intervals, finite/unbounded repetition limits, prefix placement, optional
//! initial class, and surrounding ASCII word-boundary requirements. Classification
//! rejects folding or encoding cases whose scalar behavior a byte loop could not
//! reproduce.
//!
//! Returning null is the normal outcome and delegates to the canonical Program.
//! A classifier must prove the complete language; it may never return a partial
//! hint that direct count/existence could mistake for authority.

const std = @import("std");
const plan_types = @import("plans.zig");
const byte_encoding = @import("../program/byte_encoding.zig");
const facts = @import("../program/facts.zig");
const syntax = @import("../syntax/regexp.zig");

pub const Encoding = byte_encoding.Encoding;

// Direct byte-run plans.

/// Exact repeated ASCII class plus bounds, placement, and boundary assertions.
pub const RepeatedByteShape = struct {
    ranges: [plan_types.max_repeat_byte_ranges]u16 = @splat(0),
    range_count: u8 = 0,
    min: u32,
    max: u32,
    after_prefix: bool = false,
    left_word_boundary: bool = false,
    right_word_boundary: bool = false,
};

/// Recognizes a complete repeated-byte language, optionally after an exact
/// prefix or surrounded by ASCII word-boundary assertions.
pub fn classifyRepeatedByte(
    tree: *const syntax.Regexp,
    root: syntax.NodeId,
    prefix: []const u8,
    encoding: Encoding,
) ?RepeatedByteShape {
    var current = unwrapCaptures(tree, root);
    var after_prefix = false;
    var left_word_boundary = false;
    var right_word_boundary = false;
    if (tree.node(current).* == .concat) {
        const children = tree.nodeChildren(tree.node(current).concat);
        if (children.len == 3 and
            tree.node(unwrapCaptures(tree, children[0])).* == .word_boundary and
            tree.node(unwrapCaptures(tree, children[2])).* == .word_boundary)
        {
            left_word_boundary = true;
            right_word_boundary = true;
            current = unwrapCaptures(tree, children[1]);
        } else {
            if (children.len != 2 or prefix.len == 0) return null;
            const first = tree.node(unwrapCaptures(tree, children[0])).*;
            if (first != .literal or first.literal.fold or
                facts.literalByteLength(tree, first.literal, encoding) != prefix.len)
                return null;
            current = unwrapCaptures(tree, children[1]);
            after_prefix = true;
        }
    }
    const repeat = switch (tree.node(current).*) {
        .repeat => |value| value,
        else => return null,
    };
    if (!repeat.greedy or repeat.min == 0) return null;
    var result = RepeatedByteShape{
        .min = repeat.min,
        .max = repeat.max orelse 0,
        .after_prefix = after_prefix,
        .left_word_boundary = left_word_boundary,
        .right_word_boundary = right_word_boundary,
    };
    const child = tree.node(repeat.child).*;
    switch (child) {
        .literal => |literal| {
            if (literal.fold) return null;
            const runes = tree.literalRunes(literal.runes);
            if (runes.len != 1 or runes[0] > 0x7f) return null;
            const byte: u8 = @intCast(runes[0]);
            result.ranges[0] = byte | (@as(u16, byte) << 8);
            result.range_count = 1;
        },
        .char_class => |span| {
            const ranges = tree.classRanges(span);
            if (ranges.len == 0 or ranges.len > result.ranges.len) return null;
            for (ranges, 0..) |range, index| {
                if (range.hi > 0x7f) return null;
                result.ranges[index] = @as(u8, @intCast(range.lo)) |
                    (@as(u16, @intCast(range.hi)) << 8);
            }
            result.range_count = @intCast(ranges.len);
        },
        // Dot is a scalar language in UTF-8 mode, not a byte class. Keeping
        // it on the ordinary iterator also preserves malformed-input behavior.
        .any_char => return null,
        else => return null,
    }
    return result;
}

/// Exact `initial-class repeated-class{m,n}` descriptor for direct scanning.
pub const LeadingByteRepeatShape = struct {
    initial_ranges: [plan_types.max_repeat_byte_ranges]u16 = @splat(0),
    initial_range_count: u8 = 0,
    repeated: RepeatedByteShape,
};

/// Recognizes `A B{m,n}` where both atoms are ASCII byte classes. This common
/// identifier/token shape admits one direct maximal-run count loop.
pub fn classifyLeadingByteRepeat(
    tree: *const syntax.Regexp,
    root: syntax.NodeId,
) ?LeadingByteRepeatShape {
    const current = unwrapCaptures(tree, root);
    const span = switch (tree.node(current).*) {
        .concat => |value| value,
        else => return null,
    };
    const children = tree.nodeChildren(span);
    if (children.len != 2) return null;
    const repeat = switch (tree.node(unwrapCaptures(tree, children[1])).*) {
        .repeat => |value| value,
        else => return null,
    };
    if (!repeat.greedy or repeat.min == 0) return null;
    var result = LeadingByteRepeatShape{ .repeated = .{
        .min = repeat.min,
        .max = repeat.max orelse 0,
    } };
    result.initial_range_count = fillAsciiAtomRanges(
        tree,
        unwrapCaptures(tree, children[0]),
        &result.initial_ranges,
    ) orelse return null;
    result.repeated.range_count = fillAsciiAtomRanges(
        tree,
        unwrapCaptures(tree, repeat.child),
        &result.repeated.ranges,
    ) orelse return null;
    return result;
}

/// Recognizes `\b A{m,n} x B{p,q} \b` with finite ASCII byte classes and a
/// one-byte separator. Candidate separators can then be verified directly.

// Shared byte-atom helpers.

/// Encodes one exact ASCII literal or normalized ASCII class as packed inclusive
/// byte ranges. Folded literals, non-ASCII ranges, empty classes, and classes
/// exceeding the fixed plan capacity decline the shape without partial output.
fn fillAsciiAtomRanges(
    tree: *const syntax.Regexp,
    id: syntax.NodeId,
    output: *[plan_types.max_repeat_byte_ranges]u16,
) ?u8 {
    switch (tree.node(id).*) {
        .literal => |literal| {
            if (literal.fold) return null;
            const runes = tree.literalRunes(literal.runes);
            if (runes.len != 1 or runes[0] > 0x7f) return null;
            const byte: u8 = @intCast(runes[0]);
            output[0] = byte | (@as(u16, byte) << 8);
            return 1;
        },
        .char_class => |span| {
            const ranges = tree.classRanges(span);
            if (ranges.len == 0 or ranges.len > output.len) return null;
            for (ranges, 0..) |range, index| {
                if (range.hi > 0x7f) return null;
                output[index] = @as(u8, @intCast(range.lo)) |
                    (@as(u16, @intCast(range.hi)) << 8);
            }
            return @intCast(ranges.len);
        },
        else => return null,
    }
}

fn unwrapCaptures(tree: *const syntax.Regexp, initial: syntax.NodeId) syntax.NodeId {
    var current = initial;
    while (true) switch (tree.node(current).*) {
        .capture => |capture| current = capture.child,
        .concat => |span| {
            const children = tree.nodeChildren(span);
            if (children.len != 1) return current;
            current = children[0];
        },
        else => return current,
    };
}
