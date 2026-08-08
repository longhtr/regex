//! # Read capture groups
//!
//! `captures` returns the first selected match plus its groups. Group zero is the
//! whole match; explicit groups begin at one. `CaptureView` borrows Matcher
//! scratch and is invalidated by the next operation on that Matcher.
//!
//! `group` returns `null` for an invalid index or an optional group that did not
//! participate.
//!
//! Expected output:
//!
//! ```text
//! whole match: name=42
//! key capture: name
//! value capture: 42
//! ```

const std = @import("std");
const regex = @import("regex");

// Keep optional-group handling visible at one boundary instead of force-unwrapping
// every group in the formatting call.
fn text(input: []const u8, found: ?regex.Match) ![]const u8 {
    const value = found orelse return error.MissingCapture;
    return value.slice(input) orelse error.InvalidMatchBounds;
}

pub fn main() !void {
    const input = "name=42";
    var expression = try regex.Regex.init(std.heap.page_allocator, "([a-z]+)=([0-9]+)");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Consume every borrowed group before making another call on `matcher`.
    const view = (try matcher.captures(input)) orelse return error.ExpectedMatch;
    std.debug.print(
        \\whole match: {s}
        \\key capture: {s}
        \\value capture: {s}
        \\
    ,
        .{
            try text(input, view.group(0)),
            try text(input, view.group(1)),
            try text(input, view.group(2)),
        },
    );
}
