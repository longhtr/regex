//! # Insert user text as a literal pattern fragment
//!
//! `quoteMeta` escapes metacharacters so the returned bytes describe the input
//! literally. The caller owns the allocated result and frees it with the same
//! allocator. Compile it under an encoding compatible with the original bytes.
//!
//! Use literal compile mode instead when the entire pattern is literal.
//!
//! Expected output:
//!
//! ```text
//! input text: a+b?
//! escaped literal pattern: a\+b\?
//! entire input matched: true
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = "a+b?";

    // The returned pattern is allocated; it is not a view into `input`.
    const pattern = try regex.quoteMeta(allocator, input);
    defer allocator.free(pattern);

    // '+' and '?' now compile as literal characters.
    var expression = try regex.Regex.init(allocator, pattern);
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();

    std.debug.print(
        \\input text: {s}
        \\escaped literal pattern: {s}
        \\entire input matched: {}
        \\
    , .{ input, pattern, matcher.fullMatch(input) });
}
