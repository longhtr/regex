//! Public-result qualification under concurrent DFA construction pressure.
//!
//! Binary De Bruijn data exposes many fixed-width transition contexts with a
//! compact deterministic generator. Several workers share one Regex but own
//! independent Matchers, repeatedly searching pressure inputs while DFA state is
//! built, read, exhausted, or bypassed under lock contention. Every result is
//! compared with the reviewed expected range; no test requires a particular
//! thread to obtain cache ownership.

const std = @import("std");
const api = @import("../root.zig");
const testing = std.testing;

/// Generates every binary context of `order` once to pressure lazy transition
/// construction with compact deterministic input.
fn deBruijnBinary(allocator: std.mem.Allocator, order: u5) ![]u8 {
    const size = @as(usize, 1) << order;
    const mask = size - 1;
    const visited = try allocator.alloc(bool, size);
    defer allocator.free(visited);
    @memset(visited, false);
    const output = try allocator.alloc(u8, size + order - 1);
    @memset(output[0 .. order - 1], '0');
    var bits: usize = 0;
    for (0..size) |index| {
        bits = (bits << 1) & mask;
        if (!visited[bits | 1]) {
            bits |= 1;
            output[order - 1 + index] = '1';
        } else {
            output[order - 1 + index] = '0';
        }
        std.debug.assert(!visited[bits]);
        visited[bits] = true;
    }
    return output;
}

/// Independent Matcher task sharing only immutable/lazy Regex State; `failed` is
/// the sole cross-thread mutable output.
const SearchWorker = struct {
    expression: *const api.Regex,
    match: []const u8,
    no_match: []const u8,
    failed: *std.atomic.Value(bool),

    fn run(self: SearchWorker) void {
        var matcher = api.Matcher.init(std.heap.smp_allocator, self.expression) catch {
            self.failed.store(true, .release);
            return;
        };
        defer matcher.deinit();
        for (0..2) |_| {
            if (matcher.find(self.match) == null or matcher.find(self.no_match) != null) {
                self.failed.store(true, .release);
                return;
            }
        }
    }
};

test "Qualification DFA concurrent De Bruijn pressure preserves search results" {
    const order: u5 = 18;
    const no_match = try deBruijnBinary(testing.allocator, order);
    defer testing.allocator.free(no_match);
    const match = try testing.allocator.alloc(u8, no_match.len + 1);
    defer testing.allocator.free(match);
    @memcpy(match[0..no_match.len], no_match);
    match[match.len - 1] = '0';

    const compiled = try api.Regex.compile(std.heap.smp_allocator, "0[01]{18}$", .{
        // Regex divides retained DFA bytes among forward, reverse, and full
        // caches. Give the forward cache the qualification budget.
        .dfa_memory = .{ .bytes = 3 * (@as(usize, 1) << order) },
    });
    var expression = switch (compiled) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer expression.deinit();

    var initial = try api.Matcher.init(std.heap.smp_allocator, &expression);
    defer initial.deinit();
    try testing.expect(initial.find(match) != null);
    try testing.expect(initial.find(no_match) == null);

    var failed = std.atomic.Value(bool).init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, SearchWorker.run, .{SearchWorker{
            .expression = &expression,
            .match = match,
            .no_match = no_match,
            .failed = &failed,
        }});
    }
    for (threads) |thread| thread.join();
    try testing.expect(!failed.load(.acquire));
}
