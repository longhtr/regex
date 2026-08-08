//! # Replace every match under explicit limits
//!
//! `replaceAllWithOptions` preserves unmatched input and expands the compiled
//! template for each non-overlapping match. Both output bytes and replacement
//! count are hard limits; exceeding either returns an error, never partial text.
//!
//! `Replacement` owns its output and reports the exact replacement count.
//!
//! Expected output:
//!
//! ```text
//! replacement result: x:[1] y:[22]
//! replacement count: 2
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
    // Compile and validate the reusable template before processing input.
    var template = try regex.Rewrite.compile(
        allocator,
        &expression,
        "\\g<key>:[\\g<value>]",
    );
    defer template.deinit();

    // Both ceilings are checked before output is published; errors never return
    // a partial replacement.
    var output = try template.replaceAllWithOptions(
        &matcher,
        allocator,
        "x=1 y=22",
        .{ .max_output_bytes = 64, .max_replacements = 4 },
    );
    defer output.deinit();
    std.debug.print(
        \\replacement result: {s}
        \\replacement count: {d}
        \\
    , .{ output.bytes, output.replacement_count });
}
