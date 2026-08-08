//! # Keep a collection of match offsets
//!
//! Use `findAll` instead of an iterator when the offset array must be retained or
//! passed elsewhere. The returned `Matches` owns copied offsets and requires one
//! `deinit`; it does not copy the input bytes.
//!
//! The final argument is a hard result-count limit, not an initial capacity.
//!
//! Expected output:
//!
//! ```text
//! stored match count: 3
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = "red, green, blue";

    var expression = try regex.Regex.init(allocator, "[a-z]+");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();

    // This request is allowed to publish at most three ranges. The returned
    // owner is independent of Matcher scratch, but its offsets still index input.
    var matches = try matcher.findAll(allocator, input, 3);
    defer matches.deinit();
    std.debug.print("stored match count: {d}\n", .{matches.values().len});
}
