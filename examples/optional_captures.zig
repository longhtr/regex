//! # Handle an optional capture
//!
//! A successful overall match does not imply that every group participated.
//! Test the optional returned by `group` instead of force-unwrapping it.
//!
//! Expected output:
//!
//! ```text
//! host capture: example.com
//! port capture: absent; using default
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "example.com";
    var expression = try regex.Regex.init(
        std.heap.page_allocator,
        "([a-z.]+)(?::([0-9]+))?",
    );
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // First handle absence of the entire match.
    const view = (try matcher.captures(input)) orelse return error.ExpectedMatch;
    const host = view.group(1) orelse return error.MissingHost;

    // Group 2 exists in the pattern but did not participate in this match.
    const host_text = host.slice(input) orelse return error.InvalidMatchBounds;
    if (view.group(2)) |found| {
        const port = found.slice(input) orelse return error.InvalidMatchBounds;
        std.debug.print(
            \\host capture: {s}
            \\port capture: {s}
            \\
        , .{ host_text, port });
    } else {
        std.debug.print(
            \\host capture: {s}
            \\port capture: absent; using default
            \\
        , .{host_text});
    }
}
