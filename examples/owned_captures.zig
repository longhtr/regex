//! # Keep captures after Matcher reuse
//!
//! Use `copyCaptures` when capture offsets must survive the next Matcher
//! operation or cross a function boundary. The returned `Captures` owns its slot
//! copy and requires `deinit`.
//!
//! The input bytes are not copied. Keep the original input alive while slicing
//! the saved offsets.
//!
//! Expected output:
//!
//! ```text
//! saved value capture: 42
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = "name=42";
    var expression = try regex.Regex.init(allocator, "([a-z]+)=([0-9]+)");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();

    // Allocate an independent copy of the capture slots.
    var saved = (try matcher.copyCaptures(allocator, input)) orelse
        return error.ExpectedMatch;
    defer saved.deinit();

    // This operation invalidates borrowed views, but not `saved`.
    _ = matcher.find("another=7");
    const value = saved.group(2) orelse return error.MissingValue;
    std.debug.print("saved value capture: {s}\n", .{
        value.slice(input) orelse return error.InvalidMatchBounds,
    });
}
