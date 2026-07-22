//! # Give compilation and matching separate memory budgets
//!
//! `compile_memory` bounds initial compilation. `dfa_memory` bounds shared,
//! optional acceleration; exhaustion still falls back exactly. `scratch_memory`
//! independently bounds one Matcher's mutable engines and capture storage.
//!
//! Defaults are already finite. Set explicit values when application policy must
//! be visible at construction.
//!
//! Expected output:
//!
//! ```text
//! entire input matched: true
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Compile and shared-cache budgets belong to the long-lived Regex.
    var expression = try regex.Regex.initWithOptions(allocator, "[a-z]+[0-9]+", .{
        .compile_memory = .{ .bytes = 8 * 1024 * 1024 },
        .dfa_memory = .{ .bytes = 2 * 1024 * 1024 },
    });
    defer expression.deinit();
    // Scratch is private to this Matcher and can use a separate policy.
    var matcher = try regex.Matcher.initWithOptions(allocator, &expression, .{
        .scratch_memory = .{ .bytes = 4 * 1024 * 1024 },
    });
    defer matcher.deinit();

    std.debug.print("entire input matched: {}\n", .{matcher.fullMatch("item42")});
}
