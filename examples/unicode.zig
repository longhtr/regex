//! # Match Unicode text
//!
//! UTF-8 is the default encoding. Unicode groups such as `\\p{Greek}` operate on
//! scalars, while every public offset remains a byte offset into the original
//! input. Here `Δ` occupies two bytes.
//!
//! Invalid UTF-8 is rejected under UTF-8 semantics; use Latin-1 mode when input
//! is an arbitrary byte string.
//!
//! Expected output:
//!
//! ```text
//! matched text: Δelta
//! start byte offset: 5
//! end byte offset (exclusive): 11
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "name=Δelta";

    // Require one Greek scalar followed by one or more Unicode letters.
    var expression = try regex.Regex.init(std.heap.page_allocator, "\\p{Greek}\\pL+");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Match offsets count encoded bytes, not Unicode scalars.
    const found = matcher.find(input) orelse return error.ExpectedMatch;
    const text = found.slice(input) orelse return error.InvalidMatchBounds;
    std.debug.print(
        \\matched text: {s}
        \\start byte offset: {d}
        \\end byte offset (exclusive): {d}
        \\
    , .{ text, found.start, found.end });
}
