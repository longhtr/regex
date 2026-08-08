//! # Find the first match
//!
//! Use `Matcher.find` when the application needs the location of the first
//! selected match. A Regex owns compiled state; a Matcher borrows that Regex and
//! owns reusable scratch. Destroy the Matcher first.
//!
//! `find` returns `null` when nothing matches. A `Match` contains absolute,
//! half-open byte offsets and does not own the input.
//!
//! Expected output:
//!
//! ```text
//! matched text: order #42
//! start byte offset: 9
//! end byte offset (exclusive): 18
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "received order #42";

    // Compile once and retain the Regex for every input using this pattern.
    var expression = try regex.Regex.init(std.heap.page_allocator, "order #[0-9]+");
    defer expression.deinit();

    // Matcher borrows `expression`. Registering this defer second guarantees
    // that Matcher scratch is released before the compiled Regex.
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Absence is a normal result, not an error.
    if (matcher.find(input)) |found| {
        const text = found.slice(input) orelse return error.InvalidMatchBounds;
        std.debug.print(
            \\matched text: {s}
            \\start byte offset: {d}
            \\end byte offset (exclusive): {d}
            \\
        , .{ text, found.start, found.end });
    } else {
        std.debug.print("no match found\n", .{});
    }
}
