//! # Replace only the first match
//!
//! `replaceFirst` is the counterpart to RE2's `Replace`: it preserves unmatched
//! input, expands one compiled capture template, and returns owned output.
//!
//! A no-match operation still returns an owned copy with replacement count zero.
//!
//! Expected output:
//!
//! ```text
//! first replacement text: item <12> costs 34
//! first replacement count: 1
//! no-match replacement text: no digits
//! no-match replacement count: 0
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var expression = try regex.Regex.init(allocator, "([0-9]+)");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();

    // Template compilation validates the capture reference once.
    var template = try regex.Rewrite.compile(allocator, &expression, "<\\1>");
    defer template.deinit();

    var replaced = try template.replaceFirst(
        &matcher,
        allocator,
        "item 12 costs 34",
    );
    defer replaced.deinit();

    // No match is a successful replacement result, not an optional or error.
    var unchanged = try template.replaceFirst(&matcher, allocator, "no digits");
    defer unchanged.deinit();
    std.debug.print(
        \\first replacement text: {s}
        \\first replacement count: {d}
        \\no-match replacement text: {s}
        \\no-match replacement count: {d}
        \\
    , .{
        replaced.bytes,
        replaced.replacement_count,
        unchanged.bytes,
        unchanged.replacement_count,
    });
}
