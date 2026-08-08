//! # Choose the cheapest query
//!
//! Use `isMatch` for yes/no, `fullMatch` when the expression must cover every
//! input byte, and `count` for the number of non-overlapping matches. These
//! methods avoid constructing ranges or captures the caller does not need.
//!
//! One Matcher can serve many sequential requests for the same Regex.
//!
//! Expected output:
//!
//! ```text
//! contains a match: true
//! entire input matched: false
//! non-overlapping match count: 2
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "cat and cat";

    // Compilation is shared by all three questions.
    var expression = try regex.Regex.init(std.heap.page_allocator, "cat");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Reusing one Matcher avoids rebuilding mutable execution scratch.
    std.debug.print(
        \\contains a match: {}
        \\entire input matched: {}
        \\non-overlapping match count: {d}
        \\
    ,
        .{
            matcher.isMatch(input),
            matcher.fullMatch(input),
            matcher.count(input),
        },
    );
}
