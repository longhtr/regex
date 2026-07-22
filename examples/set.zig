//! # Match many captureless patterns with one Set
//!
//! Set combines patterns into one automaton. Successful additions receive dense
//! insertion-order IDs; keep application metadata in that same order. Set does
//! not provide captures.
//!
//! `.unanchored` searches each pattern anywhere. `.both` instead requires each
//! pattern to cover the complete input. `allMatches` returns ascending IDs under
//! a hard result-count limit.
//!
//! Expected output:
//!
//! ```text
//! matched pattern name: user
//! matched pattern name: timeout
//! ```

const std = @import("std");
const regex = @import("regex");

const names = [_][]const u8{ "error", "user", "timeout" };
const patterns = [_][]const u8{ "error:[0-9]+", "user=[A-Za-z]+", "timeout" };

// Preserve the insertion ID and report a builder diagnostic instead of mapping
// every rejected source to one opaque error.
fn add(builder: *regex.Set.Builder, pattern: []const u8) !u32 {
    return switch (try builder.add(pattern)) {
        .success => |id| id,
        .diagnostic => |diagnostic| {
            std.debug.print(
                "pattern diagnostic: {s}; start byte offset: {d}; " ++
                    "end byte offset (exclusive): {d}\n",
                .{ @tagName(diagnostic.code), diagnostic.start, diagnostic.end },
            );
            return error.InvalidPattern;
        },
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // The builder owns temporary syntax until compile publishes the Set.
    var builder = regex.Set.Builder.init(allocator, .{}, .unanchored);
    defer builder.deinit();
    for (patterns, 0..) |pattern, expected_id| {
        if (try add(&builder, pattern) != expected_id) return error.UnexpectedId;
    }

    // Set must outlive the Matcher that borrows its combined Program.
    var set = try builder.compile();
    defer set.deinit();
    var matcher = try set.matcher(allocator);
    defer matcher.deinit();

    // IDs map directly into `names` because both arrays used insertion order.
    var ids = try matcher.allMatches(allocator, "user=alice timeout=30", names.len);
    defer ids.deinit();
    for (ids.values()) |id| {
        std.debug.print("matched pattern name: {s}\n", .{names[@intCast(id)]});
    }
}
