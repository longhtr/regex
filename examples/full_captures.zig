//! # Capture only a complete-input match
//!
//! `fullCaptures` combines `fullMatch` semantics with capture extraction. It
//! returns `null` if the expression matches only a substring. This is useful for
//! validating and parsing one complete field in a single operation.
//!
//! Expected output:
//!
//! ```text
//! key capture: item
//! value capture: 42
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "item=42";
    var expression = try regex.Regex.init(std.heap.page_allocator, "([a-z]+)=([0-9]+)");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // One operation first proves complete coverage, then extracts its groups.
    const view = (try matcher.fullCaptures(input)) orelse return error.ExpectedFullMatch;
    // The view is borrowed, so extract and consume its groups before Matcher reuse.
    const key = view.group(1) orelse return error.MissingKey;
    const value = view.group(2) orelse return error.MissingValue;
    std.debug.print(
        \\key capture: {s}
        \\value capture: {s}
        \\
    , .{
        key.slice(input) orelse return error.InvalidMatchBounds,
        value.slice(input) orelse return error.InvalidMatchBounds,
    });
}
