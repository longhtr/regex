//! Independent membership model for Set and Filtered collections.
//!
//! Six local readable predicates—not Regex values—define expected insertion IDs
//! for a fixed input catalog under unanchored and full-input policies. Public Set
//! results must equal those IDs in insertion order for every result limit.
//!
//! Filtered tests independently model atom occurrences, compare external atom-ID
//! input with integrated scanning, and require both candidate APIs to be supersets
//! of all true IDs. Verified APIs must equal the exact predicate model. The oracle
//! deliberately does not reproduce production atom extraction or formula layout.

const std = @import("std");
const api = @import("../root.zig");
const testing = std.testing;

const PatternId = enum(u32) {
    alpha_beta,
    cat_or_dog,
    prefix,
    a_then_b,
    foo_or_bar_baz,
    empty,
};

const patterns = [_][]const u8{
    "alpha.*beta",
    "cat|dog",
    "prefix",
    "a.*b",
    "(?:foo|bar)baz",
    "(?:)",
};

const inputs = [_][]const u8{
    "",            "alpha",     "beta",       "alphabeta",
    "alpha--beta", "betaalpha", "cat",        "dog",
    "catdog",      "prefix",    "xxprefixyy", "foobaz",
    "barbaz",      "foo-baz",   "baz",        "a___b",
    "b___a",       "unrelated",
};

fn contains(input: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, input, needle) != null;
}

fn modeledMatch(id: PatternId, input: []const u8) bool {
    return switch (id) {
        .alpha_beta => if (std.mem.indexOf(u8, input, "alpha")) |start|
            std.mem.indexOfPos(u8, input, start + "alpha".len, "beta") != null
        else
            false,
        .cat_or_dog => contains(input, "cat") or contains(input, "dog"),
        .prefix => contains(input, "prefix"),
        .a_then_b => if (std.mem.indexOfScalar(u8, input, 'a')) |start|
            std.mem.indexOfScalarPos(u8, input, start + 1, 'b') != null
        else
            false,
        .foo_or_bar_baz => contains(input, "foobaz") or contains(input, "barbaz"),
        .empty => true,
    };
}

fn modeledFull(id: PatternId, input: []const u8) bool {
    return switch (id) {
        .alpha_beta => std.mem.startsWith(u8, input, "alpha") and
            std.mem.endsWith(u8, input, "beta"),
        .cat_or_dog => std.mem.eql(u8, input, "cat") or std.mem.eql(u8, input, "dog"),
        .prefix => std.mem.eql(u8, input, "prefix"),
        .a_then_b => input.len >= 2 and input[0] == 'a' and input[input.len - 1] == 'b',
        .foo_or_bar_baz => std.mem.eql(u8, input, "foobaz") or std.mem.eql(u8, input, "barbaz"),
        .empty => input.len == 0,
    };
}

fn expectedIds(input: []const u8, full: bool, storage: *[patterns.len]u32) []const u32 {
    var len: usize = 0;
    for (0..patterns.len) |index| {
        const id: PatternId = @enumFromInt(index);
        if (if (full) modeledFull(id, input) else modeledMatch(id, input)) {
            storage[len] = @intCast(index);
            len += 1;
        }
    }
    return storage[0..len];
}

fn addSetPatterns(builder: *api.Set.Builder) !void {
    for (patterns, 0..) |pattern, index| {
        const added = try builder.add(pattern);
        try testing.expect(added == .success);
        try testing.expectEqual(@as(u32, @intCast(index)), added.success);
    }
}

/// Builds one public Set for the selected anchor policy and compares boolean and
/// ordered-ID results with the independent predicate table for every input. It
/// also sweeps every result ceiling to distinguish exact publication from the
/// required `ResultLimitExceeded` precondition failure.
fn checkSet(anchor: api.Set.Anchor, full: bool) !void {
    var builder = api.Set.Builder.init(testing.allocator, .{}, anchor);
    defer builder.deinit();
    try addSetPatterns(&builder);
    var set = try builder.compile();
    defer set.deinit();
    var matcher = try set.matcher(testing.allocator);
    defer matcher.deinit();

    for (inputs) |input| {
        var storage: [patterns.len]u32 = undefined;
        const expected = expectedIds(input, full, &storage);
        try testing.expectEqual(expected.len != 0, matcher.isMatch(input));
        var actual = try matcher.allMatches(testing.allocator, input, patterns.len);
        defer actual.deinit();
        try testing.expectEqualSlices(u32, expected, actual.values());
        for (0..patterns.len + 1) |limit| {
            if (expected.len > limit) {
                try testing.expectError(
                    error.ResultLimitExceeded,
                    matcher.allMatches(testing.allocator, input, limit),
                );
            } else {
                var limited = try matcher.allMatches(testing.allocator, input, limit);
                defer limited.deinit();
                try testing.expectEqualSlices(u32, expected, limited.values());
            }
        }
    }
}

fn atomHits(filtered: *const api.Filtered, input: []const u8, allocator: std.mem.Allocator) ![]u32 {
    var hits: std.ArrayList(u32) = .empty;
    errdefer hits.deinit(allocator);
    for (filtered.atoms(), 0..) |atom, index|
        if (contains(input, atom)) try hits.append(allocator, @intCast(index));
    return hits.toOwnedSlice(allocator);
}

fn includes(values: []const u32, wanted: u32) bool {
    for (values) |value| if (value == wanted) return true;
    return false;
}

test "Set model preserves dense insertion IDs and anchor policy" {
    try checkSet(.unanchored, false);
    try checkSet(.both, true);
}

test "Filtered model preserves matches and candidate supersets from partial hits" {
    var builder = api.Filtered.Builder.init(testing.allocator, .{}, 2);
    defer builder.deinit();
    for (patterns, 0..) |pattern, index| {
        const added = try builder.add(pattern);
        try testing.expect(added == .success);
        try testing.expectEqual(@as(u32, @intCast(index)), added.success);
    }
    var filtered = try builder.compile();
    defer filtered.deinit();
    var matcher = try filtered.matcher(testing.allocator);
    defer matcher.deinit();

    for (inputs) |input| {
        const hits = try atomHits(&filtered, input, testing.allocator);
        defer testing.allocator.free(hits);
        var storage: [patterns.len]u32 = undefined;
        const expected = expectedIds(input, false, &storage);

        const expected_first: ?u32 = if (expected.len == 0) null else expected[0];
        const first = try matcher.firstMatch(input, hits);
        try testing.expectEqual(expected_first, first);
        try testing.expectEqual(expected_first, try matcher.firstMatchScanned(input));
        var actual = try matcher.allMatches(testing.allocator, input, hits, patterns.len);
        defer actual.deinit();
        try testing.expectEqualSlices(u32, expected, actual.values());
        var scanned = try matcher.allMatchesScanned(testing.allocator, input, patterns.len);
        defer scanned.deinit();
        try testing.expectEqualSlices(u32, expected, scanned.values());

        for (0..patterns.len + 1) |limit| {
            if (expected.len > limit) {
                try testing.expectError(
                    error.ResultLimitExceeded,
                    matcher.allMatches(testing.allocator, input, hits, limit),
                );
                try testing.expectError(
                    error.ResultLimitExceeded,
                    matcher.allMatchesScanned(testing.allocator, input, limit),
                );
            } else {
                var limited = try matcher.allMatches(testing.allocator, input, hits, limit);
                defer limited.deinit();
                try testing.expectEqualSlices(u32, expected, limited.values());
            }
        }

        var candidates = try matcher.allCandidates(testing.allocator, hits, patterns.len);
        defer candidates.deinit();
        for (expected) |id| try testing.expect(includes(candidates.values(), id));
        var scanned_candidates = try matcher.allCandidatesScanned(testing.allocator, input, patterns.len);
        defer scanned_candidates.deinit();
        for (expected) |id| try testing.expect(includes(scanned_candidates.values(), id));
    }
}
