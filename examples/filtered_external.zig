//! # Supply atom hits from an external scanner
//!
//! `Filtered.atoms` publishes normalized literal bytes and assigns each one an
//! ID. Non-Scanned match methods accept the atom IDs observed in the input, then
//! perform exact Regex verification.
//!
//! Correctness requires the external scanner to report every occurring atom.
//! Extra hits only cost work; missed hits can hide a real match. The simple scan
//! below is suitable only for these default case-sensitive ASCII options.
//!
//! Expected output:
//!
//! ```text
//! matched pattern name: user
//! matched pattern ID: 1
//! ```

const std = @import("std");
const regex = @import("regex");

const names = [_][]const u8{ "error", "user" };

fn add(builder: *regex.Filtered.Builder, pattern: []const u8) !void {
    switch (try builder.add(pattern)) {
        .success => {},
        .diagnostic => |diagnostic| {
            std.debug.print(
                "pattern diagnostic: {s}; start byte offset: {d}; " ++
                    "end byte offset (exclusive): {d}\n",
                .{ @tagName(diagnostic.code), diagnostic.start, diagnostic.end },
            );
            return error.InvalidPattern;
        },
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = "user=alice";
    var builder = regex.Filtered.Builder.init(allocator, .{}, 3);
    defer builder.deinit();
    try add(&builder, "error:[0-9]+"); // pattern ID 0
    try add(&builder, "user=[A-Za-z]+"); // pattern ID 1

    var filtered = try builder.compile();
    defer filtered.deinit();

    // A real integration would use a multi-literal scanner. This loop emphasizes
    // the contract: report the ID of every published atom found in the input.
    var observed: std.ArrayList(u32) = .empty;
    defer observed.deinit(allocator);
    for (filtered.atoms(), 0..) |atom, atom_id| {
        if (std.mem.indexOf(u8, input, atom) != null)
            try observed.append(allocator, @intCast(atom_id));
    }

    // `firstMatch` evaluates formulas from external hits, then verifies the
    // lowest candidate Regex exactly.
    var matcher = try filtered.matcher(allocator);
    defer matcher.deinit();
    const pattern_id = (try matcher.firstMatch(input, observed.items)) orelse
        return error.ExpectedMatch;
    std.debug.print(
        \\matched pattern name: {s}
        \\matched pattern ID: {d}
        \\
    , .{ names[@intCast(pattern_id)], pattern_id });
}
