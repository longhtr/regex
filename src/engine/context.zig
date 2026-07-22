//! Complete-input evaluation of zero-width assertion conjunctions.
//!
//! `assertionsHold` derives the byte immediately before and after an absolute
//! position, then evaluates all bits in `EmptyMask` as a conjunction. Text
//! assertions compare with `0`/`input.len`; line assertions compare neighboring
//! newline bytes; word boundaries compare ASCII `[0-9A-Za-z_]` membership on
//! either side.
//!
//! Executors always pass absolute positions in the complete input, even while
//! searching a subrange. A requested range edge therefore never masquerades as
//! text start/end or changes boundary context. The function allocates nothing
//! and is shared by every NFA/DFA/capture path.

const std = @import("std");
const program = @import("../program/program.zig");

/// Evaluates every enabled assertion at one absolute byte boundary. Callers
/// guarantee `position <= input.len`.
pub fn assertionsHold(mask: program.EmptyMask, input: []const u8, position: usize) bool {
    if (mask.begin_text and position != 0) return false;
    if (mask.end_text and position != input.len) return false;

    const needs_word = mask.word_boundary or mask.not_word_boundary;
    const previous: ?u8 = if (mask.begin_line or needs_word)
        if (position > 0) input[position - 1] else null
    else
        null;
    const next: ?u8 = if (mask.end_line or needs_word)
        if (position < input.len) input[position] else null
    else
        null;

    if (mask.begin_line and position != 0 and previous != '\n') return false;
    if (mask.end_line and position != input.len and next != '\n') return false;
    if (needs_word) {
        const boundary = isWord(previous) != isWord(next);
        if (mask.word_boundary and !boundary) return false;
        if (mask.not_word_boundary and boundary) return false;
    }
    return true;
}

fn isWord(byte: ?u8) bool {
    const value = byte orelse return false;
    return std.ascii.isAlphanumeric(value) or value == '_';
}

const testing = std.testing;

test "Word and line assertions use complete byte context" {
    try testing.expect(assertionsHold(.{ .begin_text = true }, "a", 0));
    try testing.expect(!assertionsHold(.{ .begin_text = true }, "ba", 1));
    try testing.expect(assertionsHold(.{ .begin_line = true }, "\na", 1));
    try testing.expect(assertionsHold(.{ .word_boundary = true }, "a!", 1));
    try testing.expect(assertionsHold(.{ .not_word_boundary = true }, "ab", 1));
}
