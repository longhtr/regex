//! # Reuse compiled state across a batch
//!
//! Compile one Regex and reuse one Matcher for sequential requests. This is the
//! ordinary equivalent of keeping one compiled RE2 object and applying
//! `PartialMatch` repeatedly.
//!
//! Expected output:
//!
//! ```text
//! input: ticket-7; contains a match: true
//! input: prefix ticket-42 suffix; contains a match: true
//! input: no identifier; contains a match: false
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    var expression = try regex.Regex.init(std.heap.page_allocator, "ticket-[0-9]+");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    const inputs = [_][]const u8{
        "ticket-7",
        "prefix ticket-42 suffix",
        "no identifier",
    };

    // Matcher reuses its mutable execution scratch after each call completes.
    // Create separate Matchers only for concurrent or overlapping requests.
    for (inputs) |input| {
        std.debug.print(
            "input: {s}; contains a match: {}\n",
            .{ input, matcher.isMatch(input) },
        );
    }
}
