//! # Reject excessive work before execution
//!
//! Every `*WithWorkLimit` method performs conservative admission before running.
//! The bound includes complete exact fallback, so rejection is independent of
//! whether an optional accelerator happens to be warm.
//!
//! Ordinary methods have no work-policy branch. Use a work-limited form at an
//! untrusted request boundary.
//!
//! Expected output:
//!
//! ```text
//! match request rejected before execution: work limit exceeded
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    var expression = try regex.Regex.init(std.heap.page_allocator, "(a|aa)*b");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Eight work units are intentionally below the conservative complete-search
    // estimate for this request.
    const input = "aaaaaaaa";
    if (matcher.findWithWorkLimit(input, 8)) |result| {
        if (result) |found| {
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
    } else |err| switch (err) {
        error.WorkLimitExceeded => std.debug.print(
            "match request rejected before execution: work limit exceeded\n",
            .{},
        ),
    }
}
