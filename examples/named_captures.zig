//! # Look up captures by name
//!
//! Name lookup belongs to Regex because names are compile-time metadata.
//! `namedCapture` combines the leftmost name-to-index lookup with one
//! `CaptureView`. Metadata can also be inspected without executing a match.
//!
//! `captureCount` excludes whole-match group zero. `captureName` returns `null`
//! for anonymous or invalid groups.
//!
//! Expected output:
//!
//! ```text
//! host capture: ziglang.org
//! host capture index: 2
//! capture count: 2
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "https://ziglang.org";
    var expression = try regex.Regex.init(
        std.heap.page_allocator,
        "(?P<scheme>https?)://(?P<host>[a-z.]+)",
    );
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    const view = (try matcher.captures(input)) orelse return error.ExpectedMatch;

    // Regex resolves "host" to its compiled group index, then reads that slot
    // from this borrowed view.
    const host = expression.namedCapture(view, "host") orelse return error.MissingHost;
    // Metadata lookup needs only Regex; it does not execute another match.
    std.debug.print(
        \\host capture: {s}
        \\host capture index: {d}
        \\capture count: {d}
        \\
    ,
        .{
            host.slice(input) orelse return error.InvalidMatchBounds,
            expression.captureIndex("host") orelse return error.MissingHostMetadata,
            expression.captureCount(),
        },
    );
}
