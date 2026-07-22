//! # Compute a lexical index window
//!
//! `possibleMatchRange` analyzes anchored full matches without executing against
//! an input. A finite result owns bytewise minimum and maximum bounds that can
//! conservatively prune ordered storage.
//!
//! The other outcomes prove an empty language or report that no finite maximum
//! can represent the language. `max_len` bounds analysis and output.
//!
//! Expected output:
//!
//! ```text
//! minimum possible match: invoice-2024
//! maximum possible match: invoice-2025
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var expression = try regex.Regex.init(allocator, "invoice-(2024|2025)");
    defer expression.deinit();

    // Analyze at most 32 output bytes; this does not run a match request.
    var result = try expression.possibleMatchRange(allocator, 32);
    switch (result) {
        .range => |*bounds| {
            // Only this union branch owns allocated minimum/maximum slices.
            defer bounds.deinit();
            std.debug.print(
                \\minimum possible match: {s}
                \\maximum possible match: {s}
                \\
            , .{ bounds.minimum, bounds.maximum });
        },
        .empty_language => std.debug.print(
            "possible match range: empty language\n",
            .{},
        ),
        .no_finite_max => std.debug.print(
            "possible match range: no finite maximum\n",
            .{},
        ),
    }
}
