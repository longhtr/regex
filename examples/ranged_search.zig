//! # Search one region of a larger input
//!
//! Range methods accept absolute, half-open byte bounds and return absolute
//! offsets. Unlike matching an input slice, they preserve the complete input for
//! assertions and context-sensitive syntax.
//!
//! `.unanchored` scans inside the range. `.start` requires the match to begin at
//! `range.start`; it does not turn that byte into the start of the text.
//!
//! Expected output:
//!
//! ```text
//! unanchored matched text: two
//! unanchored match start byte offset: 11
//! unanchored match end byte offset (exclusive): 14
//! start-anchored match: none
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "prefix one two suffix";
    // Keep the complete input and describe the searchable region separately.
    const words = regex.SearchRange{ .start = 7, .end = 14 }; // "one two"

    var expression = try regex.Regex.init(std.heap.page_allocator, "two");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Unanchored search may skip "one " inside the requested range.
    const found = (try matcher.findIn(input, words, .unanchored)) orelse
        return error.ExpectedMatch;
    const text = found.slice(input) orelse return error.InvalidMatchBounds;
    std.debug.print(
        \\unanchored matched text: {s}
        \\unanchored match start byte offset: {d}
        \\unanchored match end byte offset (exclusive): {d}
        \\
    , .{ text, found.start, found.end });
    // Start anchoring fails because "two" does not begin at byte 7.
    if (try matcher.findIn(input, words, .start)) |anchored| {
        const anchored_text = anchored.slice(input) orelse return error.InvalidMatchBounds;
        std.debug.print(
            \\start-anchored matched text: {s}
            \\start-anchored match start byte offset: {d}
            \\start-anchored match end byte offset (exclusive): {d}
            \\
        , .{ anchored_text, anchored.start, anchored.end });
    } else {
        std.debug.print("start-anchored match: none\n", .{});
    }
}
