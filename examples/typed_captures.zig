//! # Convert captures to application types
//!
//! Unlike RE2's typed output arguments, capture extraction returns byte ranges.
//! Slice strings from the original input, then parse numeric or domain-specific
//! values with the application's preferred conversion rules.
//!
//! Sliced strings borrow the input. Parsed integers are independent values.
//!
//! Expected output:
//!
//! ```text
//! borrowed item string: widget
//! quantity capture text: 42
//! parsed quantity integer: 42
//! ```

const std = @import("std");
const regex = @import("regex");

fn captureText(input: []const u8, found: ?regex.Match) ![]const u8 {
    const value = found orelse return error.MissingCapture;
    return value.slice(input) orelse error.InvalidMatchBounds;
}

pub fn main() !void {
    const input = "widget:42";
    var expression = try regex.Regex.init(
        std.heap.page_allocator,
        "(?P<item>[a-z]+):(?P<quantity>[0-9]+)",
    );
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Full capture matching validates the complete field before conversion.
    const view = (try matcher.fullCaptures(input)) orelse return error.ExpectedMatch;
    const item: []const u8 = try captureText(
        input,
        expression.namedCapture(view, "item"),
    );
    const quantity_text = try captureText(
        input,
        expression.namedCapture(view, "quantity"),
    );

    // Conversion policy stays explicit; malformed or overflowing values remain
    // ordinary parse errors instead of regex failures.
    const quantity: u32 = try std.fmt.parseInt(u32, quantity_text, 10);
    std.debug.print(
        \\borrowed item string: {s}
        \\quantity capture text: {s}
        \\parsed quantity integer: {d}
        \\
    , .{ item, quantity_text, quantity });
}
