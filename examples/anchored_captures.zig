//! # Capture with explicit anchor modes
//!
//! `capturesIn` combines RE2-style unanchored or start-anchored matching with
//! capture extraction. `fullCapturesIn` instead requires the expression to cover
//! the complete requested range. Returned offsets remain absolute.
//!
//! Expected output:
//!
//! ```text
//! unanchored matched text: key=42
//! input-start anchored match: none
//! range-start anchored matched text: key=42
//! full-range matched text: key=42
//! ```

const std = @import("std");
const regex = @import("regex");

fn wholeText(input: []const u8, view: regex.CaptureView) ![]const u8 {
    const whole = view.group(0) orelse return error.MissingWholeMatch;
    return whole.slice(input) orelse error.InvalidMatchBounds;
}

pub fn main() !void {
    const input = "prefix key=42 suffix";
    const field = regex.SearchRange{ .start = 7, .end = 13 };
    var expression = try regex.Regex.init(
        std.heap.page_allocator,
        "([a-z]+)=([0-9]+)",
    );
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Unanchored search skips the prefix, while start anchoring at byte zero
    // refuses to do so.
    const unanchored = (try matcher.capturesIn(input, .{}, .unanchored)) orelse
        return error.ExpectedUnanchoredMatch;
    const unanchored_text = try wholeText(input, unanchored);
    if (try matcher.capturesIn(input, .{}, .start) != null)
        return error.UnexpectedInputStartMatch;

    // Moving the range start changes `.start` anchoring without changing the
    // absolute offsets or pretending that the range is a separate input.
    const anchored = (try matcher.capturesIn(input, field, .start)) orelse
        return error.ExpectedRangeStartMatch;
    const anchored_text = try wholeText(input, anchored);
    const full = (try matcher.fullCapturesIn(input, field)) orelse
        return error.ExpectedFullRangeMatch;
    const full_text = try wholeText(input, full);

    std.debug.print(
        \\unanchored matched text: {s}
        \\input-start anchored match: none
        \\range-start anchored matched text: {s}
        \\full-range matched text: {s}
        \\
    , .{ unanchored_text, anchored_text, full_text });
}
