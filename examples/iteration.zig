//! # Stream non-overlapping matches
//!
//! `Matcher.iterator` is the simplest way to process every match immediately. It
//! allocates no result collection and borrows both the Matcher and input for the
//! loop. Each yielded `Match` is only a pair of absolute byte offsets.
//!
//! Empty matches use encoding-aware forward progress, so iteration terminates.
//!
//! Expected output:
//!
//! ```text
//! matched text: red
//! matched text: green
//! matched text: blue
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "red, green, blue";

    // Keep compiled and mutable state alive for the complete streaming pass.
    var expression = try regex.Regex.init(std.heap.page_allocator, "[a-z]+");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // The iterator borrows Matcher and input; consume each range in the loop.
    var matches = matcher.iterator(input);
    while (matches.next()) |found| {
        std.debug.print("matched text: {s}\n", .{
            found.slice(input) orelse return error.InvalidMatchBounds,
        });
    }
}
