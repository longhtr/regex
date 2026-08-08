//! # Compile with POSIX syntax and anchor policy
//!
//! `.semantics = .posix` enables POSIX spelling and makes `^` and `$`
//! line-oriented initially. Set `text_anchors = true` when those anchors must
//! refer only to the beginning and end of the complete input.
//!
//! Expected output:
//!
//! ```text
//! POSIX line-anchored matched text: alpha
//! absolute text-anchored match found: false
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "123\nalpha\n456";
    const pattern = "^[[:alpha:]]+$";

    // Default POSIX anchors select the alphabetic line inside the input.
    var line_expression = try regex.Regex.initWithOptions(
        std.heap.page_allocator,
        pattern,
        .{ .semantics = .posix },
    );
    defer line_expression.deinit();
    var line_matcher = try regex.Matcher.init(std.heap.page_allocator, &line_expression);
    defer line_matcher.deinit();
    const found = line_matcher.find(input) orelse return error.ExpectedLineMatch;
    const text = found.slice(input) orelse return error.InvalidMatchBounds;

    // Absolute text anchors reject the same pattern because the complete input
    // begins and ends with digits rather than alphabetic bytes.
    var text_expression = try regex.Regex.initWithOptions(
        std.heap.page_allocator,
        pattern,
        .{ .semantics = .posix, .text_anchors = true },
    );
    defer text_expression.deinit();
    var text_matcher = try regex.Matcher.init(std.heap.page_allocator, &text_expression);
    defer text_matcher.deinit();

    std.debug.print(
        \\POSIX line-anchored matched text: {s}
        \\absolute text-anchored match found: {}
        \\
    , .{ text, text_matcher.isMatch(input) });
}
