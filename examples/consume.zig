//! # Consume structured input from a cursor
//!
//! RE2's `Consume` anchors a match at the current input cursor and advances it.
//! Compose the same workflow with `capturesIn`, `.start` anchoring, and the
//! absolute end offset of group zero.
//!
//! Expected output:
//!
//! ```text
//! consumed integer: 10
//! consumed integer: 20
//! consumed integer: 300
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "10,20,300";
    var expression = try regex.Regex.init(
        std.heap.page_allocator,
        "([0-9]+)(,|$)",
    );
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    var cursor: usize = 0;
    while (cursor < input.len) {
        // `.start` prevents malformed bytes at the cursor from being skipped.
        const view = (try matcher.capturesIn(
            input,
            .{ .start = cursor },
            .start,
        )) orelse return error.ExpectedToken;
        const whole = view.group(0) orelse return error.MissingWholeMatch;
        const digits = view.group(1) orelse return error.MissingInteger;
        const text = digits.slice(input) orelse return error.InvalidMatchBounds;

        // Parse and consume every borrowed capture before the next Matcher call.
        const value = try std.fmt.parseInt(u32, text, 10);
        if (whole.end <= cursor) return error.NoForwardProgress;
        cursor = whole.end;
        std.debug.print("consumed integer: {d}\n", .{value});
    }
}
