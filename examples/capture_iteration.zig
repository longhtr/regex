//! # Iterate matches with captures
//!
//! `captureIterator` yields one borrowed `CaptureView` per non-overlapping match.
//! Consume or copy the current groups before calling `next` again, because
//! advancing invalidates the previous view.
//!
//! Expected output:
//!
//! ```text
//! key capture: x; value capture: 1
//! key capture: y; value capture: 22
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "x=1 y=22";
    var expression = try regex.Regex.init(std.heap.page_allocator, "([a-z])=([0-9]+)");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // The iterator owns no result array; it repeatedly reuses Matcher scratch.
    var captures = matcher.captureIterator(input);
    while (try captures.next()) |view| {
        // Slice both groups now; the next `next` call reuses their backing slots.
        const key = view.group(1) orelse return error.MissingKey;
        const value = view.group(2) orelse return error.MissingValue;
        std.debug.print("key capture: {s}; value capture: {s}\n", .{
            key.slice(input) orelse return error.InvalidMatchBounds,
            value.slice(input) orelse return error.InvalidMatchBounds,
        });
    }
}
