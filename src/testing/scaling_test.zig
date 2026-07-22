//! Public qualification at explicit large-pattern and large-input boundaries.
//!
//! Deterministic generators construct diverse literal-prefix dictionaries,
//! repeated Unicode classes, bounded optional Programs, and million-byte valid or
//! malformed inputs without committed fixtures. Tests check exact first/middle/
//! last/rejecting observations and both sides of documented node/instruction
//! admission thresholds.
//!
//! Scale is used to expose arithmetic, topology, stack, and ownership defects—not
//! to assert elapsed time. Performance measurement remains in the benchmark
//! catalog.

const std = @import("std");
const api = @import("../root.zig");

const testing = std.testing;

fn compile(pattern: []const u8, options: api.CompileOptions) !api.Regex {
    return switch (try api.Regex.compile(testing.allocator, pattern, options)) {
        .success => |expression| expression,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

const dictionary_prefixes = [_][]const u8{
    "amber", "ambition", "amble", "azure", "binary", "birch", "catalog", "cater",
};
const dictionary_tails = [_][]const u8{ "", "ing", "ment", "stone" };

fn dictionaryWord(buffer: []u8, index: usize, count: usize) ![]const u8 {
    const group_size = (count + dictionary_prefixes.len - 1) / dictionary_prefixes.len;
    const group = @min(index / group_size, dictionary_prefixes.len - 1);
    const local = index % group_size;
    return std.fmt.bufPrint(buffer, "{s}{d:0>4}{s}", .{
        dictionary_prefixes[group],
        local,
        dictionary_tails[local % dictionary_tails.len],
    });
}

/// Branch layouts with equal language size but different shared-prefix topology.
const DictionaryOrder = enum { grouped, reversed, interleaved };

/// Renders deterministic equal-width dictionary alternatives in the requested
/// topology, returning the exact final branch bytes for result checks.
fn appendDictionaryPattern(
    allocator: std.mem.Allocator,
    pattern: *std.ArrayList(u8),
    count: usize,
    order: DictionaryOrder,
) !void {
    for (0..count) |position| {
        if (position != 0) try pattern.append(allocator, '|');
        const index = switch (order) {
            .grouped => position,
            .reversed => count - 1 - position,
            .interleaved => if (position % 2 == 0)
                position / 2
            else
                count - 1 - position / 2,
        };
        var buffer: [48]u8 = undefined;
        try pattern.appendSlice(allocator, try dictionaryWord(&buffer, index, count));
    }
}

test "Diverse dictionary factoring preserves public matching beyond prior campaign bounds" {
    const count = 3072;
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(testing.allocator);
    try appendDictionaryPattern(testing.allocator, &pattern, count, .grouped);

    var expression = try compile(pattern.items, .{ .capture_groups = false });
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    for ([_]usize{ 0, count / 2, count - 1 }) |index| {
        var buffer: [48]u8 = undefined;
        const word = try dictionaryWord(&buffer, index, count);
        try testing.expect(matcher.fullMatch(word));
    }
    try testing.expect(!matcher.fullMatch("cater-not-in-the-dictionary"));
}

test "Dictionary branch order preserves first middle last and rejecting results" {
    const count = 512;
    for (std.enums.values(DictionaryOrder)) |order| {
        var pattern: std.ArrayList(u8) = .empty;
        defer pattern.deinit(testing.allocator);
        try appendDictionaryPattern(testing.allocator, &pattern, count, order);

        var expression = try compile(pattern.items, .{ .capture_groups = false });
        defer expression.deinit();
        var matcher = try api.Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();
        for ([_]usize{ 0, count / 2, count - 1 }) |index| {
            var buffer: [48]u8 = undefined;
            try testing.expect(matcher.fullMatch(try dictionaryWord(&buffer, index, count)));
        }
        try testing.expect(!matcher.fullMatch("not-a-generated-dictionary-word"));
    }
}

fn expectResourceLimit(pattern: []const u8, options: api.CompileOptions) !void {
    const result = try api.Regex.compile(testing.allocator, pattern, options);
    switch (result) {
        .diagnostic => |diagnostic| try testing.expectEqual(.resource_limit, diagnostic.code),
        .success => |value| {
            var expression = value;
            expression.deinit();
            return error.ExpectedResourceLimit;
        },
    }
}

fn expectCompileSuccess(pattern: []const u8, options: api.CompileOptions) !void {
    var expression = try compile(pattern, options);
    expression.deinit();
}

test "Large Unicode repetitions have explicit finite admission policies" {
    const cases = [_]struct {
        pattern: []const u8,
        minimum_instructions: u32,
    }{
        .{ .pattern = "\\pL{50}", .minimum_instructions = 103_954 },
        .{ .pattern = "\\p{L}{100}", .minimum_instructions = 207_904 },
        .{ .pattern = "\\p{L}{256}", .minimum_instructions = 532_228 },
    };
    for (cases) |case| {
        try expectResourceLimit(case.pattern, .{});
        try expectResourceLimit(case.pattern, .{
            .max_instructions = case.minimum_instructions - 1,
        });
        try expectCompileSuccess(case.pattern, .{
            .max_instructions = case.minimum_instructions,
        });
    }
}

test "Large literal dictionaries require an explicit node budget" {
    const count = 80_000;
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(testing.allocator);
    try pattern.appendSlice(testing.allocator, "(?:");
    for (0..count) |index| {
        if (index != 0) try pattern.append(testing.allocator, '|');
        var buffer: [16]u8 = undefined;
        try pattern.appendSlice(
            testing.allocator,
            try std.fmt.bufPrint(&buffer, "word{d:0>5}", .{index}),
        );
    }
    try pattern.append(testing.allocator, ')');

    const minimum_nodes = 106_668;
    try expectResourceLimit(pattern.items, .{});
    try expectResourceLimit(pattern.items, .{ .max_nodes = minimum_nodes - 1 });
    try expectCompileSuccess(pattern.items, .{ .max_nodes = minimum_nodes });
}

test "Million-byte adversarial existence remains complete and reusable" {
    const input = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(input);
    @memset(input, 'a');

    var expression = try compile("(?:a|aa)*b", .{ .capture_groups = false });
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expect(!matcher.isMatch(input));
    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.isMatchWithWorkLimit(input, 0),
    );
    input[input.len - 1] = 'b';
    try testing.expect(matcher.isMatch(input));
    try testing.expect(matcher.isMatch("ab"));
}

test "Million-byte anchored rejection count and malformed scalar semantics" {
    const input = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(input);
    @memset(input, 'x');

    var anchored_expression = try compile("^needle", .{ .capture_groups = false });
    defer anchored_expression.deinit();
    var anchored = try api.Matcher.init(testing.allocator, &anchored_expression);
    defer anchored.deinit();
    try testing.expect(!anchored.isMatch(input));

    @memset(input, 'a');
    var count_expression = try compile("[ab]", .{ .capture_groups = false });
    defer count_expression.deinit();
    var counter = try api.Matcher.init(testing.allocator, &count_expression);
    defer counter.deinit();
    try testing.expectEqual(input.len, counter.count(input));

    @memset(input, 0xff);
    var scalar_expression = try compile(".", .{ .capture_groups = false });
    defer scalar_expression.deinit();
    var scalar = try api.Matcher.init(testing.allocator, &scalar_expression);
    defer scalar.deinit();
    try testing.expect(!scalar.isMatch(input));
}
