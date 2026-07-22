//! # Expand captures without preserving surrounding input
//!
//! `Rewrite.compile` validates template references once against a Regex.
//! `extract` finds the first match and emits only the template expansion. It
//! returns `null` when there is no match.
//!
//! The returned `Text` owns its bytes and requires `deinit`.
//!
//! Expected output:
//!
//! ```text
//! extracted text: x:[1]
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var expression = try regex.Regex.init(
        allocator,
        "(?P<key>[a-z])=(?P<value>[0-9]+)",
    );
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();
    // Template compilation resolves both names to capture indices once.
    var template = try regex.Rewrite.compile(
        allocator,
        &expression,
        "\\g<key>:[\\g<value>]",
    );
    defer template.deinit();

    // `extract` ignores text around the first match; it emits only expansion.
    var output = (try template.extract(&matcher, allocator, "x=1 y=22")) orelse
        return error.ExpectedMatch;
    defer output.deinit();
    std.debug.print("extracted text: {s}\n", .{output.bytes});
}
