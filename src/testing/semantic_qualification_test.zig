//! Broad public semantic qualification across syntax options and operations.
//!
//! These tests are direct reviewed examples outside the compact handwritten table
//! where a larger matrix or regression narrative is clearer. They cover full and
//! partial matching, anchor/consume distinctions, first/longest priority, named
//! captures, UTF-8/Latin-1, malformed input, never-newline precedence, folding,
//! empty progress, large/deep patterns, and known historical regressions.
//!
//! Expectations are stated directly from language semantics. Foreign-language
//! argument conversion and string wrappers are deliberately absent.

const std = @import("std");
const api = @import("../root.zig");
const testing = std.testing;

fn compile(pattern: []const u8, options: api.CompileOptions) !api.Regex {
    const result = try api.Regex.compile(testing.allocator, pattern, options);
    return switch (result) {
        .success => |expression| expression,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

fn expectFull(expected: bool, pattern: []const u8, input: []const u8, options: api.CompileOptions) !void {
    var expression = try compile(pattern, options);
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    try testing.expectEqual(expected, matcher.fullMatch(input));
}

fn expectFind(expected: bool, pattern: []const u8, input: []const u8, options: api.CompileOptions) !void {
    var expression = try compile(pattern, options);
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    try testing.expectEqual(expected, matcher.find(input) != null);
}

fn expectThreeCaptures(
    pattern: []const u8,
    input: []const u8,
    expected: [3][]const u8,
) !void {
    var expression = try compile(pattern, .{});
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const captured = (try matcher.captures(input)).?;
    for (expected, 1..) |value, group_index| {
        const group = captured.group(group_index).?;
        try testing.expectEqualStrings(value, input[group.start..group.end]);
    }
}

fn expectRejected(pattern: []const u8) !void {
    return expectRejectedWithOptions(pattern, .{});
}

fn expectRejectedWithOptions(pattern: []const u8, options: api.CompileOptions) !void {
    const result = try api.Regex.compile(testing.allocator, pattern, options);
    switch (result) {
        .diagnostic => {},
        .success => |value| {
            var expression = value;
            expression.deinit();
            return error.ExpectedDiagnostic;
        },
    }
}

test "Qualification full-match anchoring braces alternatives and end" {
    // and FullMatchEnd.
    for ([_]struct { input: []const u8, pattern: []const u8, expected: bool }{
        .{ .input = "x1001", .pattern = "(\\d+)", .expected = false },
        .{ .input = "1001x", .pattern = "(\\d+)", .expected = false },
        .{ .input = "x1001", .pattern = "x(\\d+)", .expected = true },
        .{ .input = "1001x", .pattern = "(\\d+)x", .expected = true },
        .{ .input = "0abcd", .pattern = "[0-9a-f+.-]{5,}", .expected = true },
        .{ .input = "0abcde", .pattern = "[0-9a-f+.-]{5,}", .expected = true },
        .{ .input = "0abc", .pattern = "[0-9a-f+.-]{5,}", .expected = false },
        .{ .input = "foo", .pattern = "foo|bar|[A-Z]", .expected = true },
        .{ .input = "bar", .pattern = "foo|bar|[A-Z]", .expected = true },
        .{ .input = "X", .pattern = "foo|bar|[A-Z]", .expected = true },
        .{ .input = "XY", .pattern = "foo|bar|[A-Z]", .expected = false },
        .{ .input = "fo", .pattern = "fo|foo", .expected = true },
        .{ .input = "foo", .pattern = "fo|foo", .expected = true },
        .{ .input = "fo", .pattern = "fo|foo$", .expected = true },
        .{ .input = "foo", .pattern = "fo|foo$", .expected = true },
        .{ .input = "foo", .pattern = "foo$", .expected = true },
        .{ .input = "foo$bar", .pattern = "foo\\$", .expected = false },
        .{ .input = "fox", .pattern = "fo|bar", .expected = false },
    }) |case| try expectFull(case.expected, case.pattern, case.input, .{ .perl_classes = true });
}

test "Qualification full and partial match basics" {
    for ([_]struct { pattern: []const u8, input: []const u8, expected: bool }{
        .{ .pattern = "h", .input = "h", .expected = true },
        .{ .pattern = "hello", .input = "hello", .expected = true },
        .{ .pattern = "h.*o", .input = "hello", .expected = true },
        .{ .pattern = "h.*o", .input = "othello", .expected = false },
        .{ .pattern = "h.*o", .input = "hello!", .expected = false },
    }) |case| try expectFull(case.expected, case.pattern, case.input, .{});

    for ([_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "x", .input = "x" },
        .{ .pattern = "h.*o", .input = "hello" },
        .{ .pattern = "h.*o", .input = "othello" },
        .{ .pattern = "h.*o", .input = "hello!" },
        .{ .pattern = "((((((((((((((((((((x))))))))))))))))))))", .input = "x" },
    }) |case| try expectFind(true, case.pattern, case.input, .{});
}

test "Qualification anchored and searching consume semantics" {
    const input = "   aaa b!@#$@#$cccc";
    var consume = try compile("\\s*(\\w+)", .{ .perl_classes = true });
    defer consume.deinit();
    var consume_matcher = try api.Matcher.init(testing.allocator, &consume);
    defer consume_matcher.deinit();
    var offset: usize = 0;
    for ([_][]const u8{ "aaa", "b" }) |expected| {
        const captured = (try consume_matcher.capturesIn(input, .{ .start = offset }, .start)).?;
        const word = captured.group(1).?;
        try testing.expectEqualStrings(expected, input[word.start..word.end]);
        offset = captured.group(0).?.end;
    }
    try testing.expect((try consume_matcher.capturesIn(input, .{ .start = offset }, .start)) == null);

    var find_consume = try compile("(\\w+)", .{ .perl_classes = true });
    defer find_consume.deinit();
    var find_matcher = try api.Matcher.init(testing.allocator, &find_consume);
    defer find_matcher.deinit();
    offset = 0;
    for ([_][]const u8{ "aaa", "b", "cccc" }) |expected| {
        const captured = (try find_matcher.capturesIn(input, .{ .start = offset }, .unanchored)).?;
        const word = captured.group(1).?;
        try testing.expectEqualStrings(expected, input[word.start..word.end]);
        offset = captured.group(0).?.end;
    }
    try testing.expect((try find_matcher.capturesIn(input, .{ .start = offset }, .unanchored)) == null);
}

test "Qualification alternation and structured capture slots" {
    var alternation = try compile("(foo)|(bar)|(baz)", .{});
    defer alternation.deinit();
    var alternation_matcher = try api.Matcher.init(testing.allocator, &alternation);
    defer alternation_matcher.deinit();
    for ([_]struct { input: []const u8, selected: usize }{
        .{ .input = "foo", .selected = 1 },
        .{ .input = "bar", .selected = 2 },
        .{ .input = "baz", .selected = 3 },
    }) |case| {
        const captured = (try alternation_matcher.captures(case.input)).?;
        for (1..4) |index| {
            if (index == case.selected)
                try testing.expectEqualStrings(case.input, case.input[captured.group(index).?.start..captured.group(index).?.end])
            else
                try testing.expect(captured.group(index) == null);
        }
    }
    try testing.expect((try alternation_matcher.captures("f")) == null);

    const input = "a chrisr:9000 here";
    var structured = try compile("((\\w+):([0-9]+))", .{ .perl_classes = true });
    defer structured.deinit();
    var structured_matcher = try api.Matcher.init(testing.allocator, &structured);
    defer structured_matcher.deinit();
    const captured = (try structured_matcher.captures(input)).?;
    for ([_]struct { index: usize, expected: []const u8 }{
        .{ .index = 0, .expected = "chrisr:9000" },
        .{ .index = 1, .expected = "chrisr:9000" },
        .{ .index = 2, .expected = "chrisr" },
        .{ .index = 3, .expected = "9000" },
    }) |case| {
        const group = captured.group(case.index).?;
        try testing.expectEqualStrings(case.expected, input[group.start..group.end]);
    }
}

test "Qualification named capture metadata and values" {
    var plain = try compile("(hello world)", .{});
    defer plain.deinit();
    try testing.expectEqual(@as(u32, 1), plain.captureCount());
    try testing.expect(plain.captureIndex("missing") == null);

    var nested = try compile("(?P<A>expr(?P<B>expr)(?P<C>expr))((expr)(?P<D>expr))", .{});
    defer nested.deinit();
    try testing.expectEqual(@as(u32, 6), nested.captureCount());
    try testing.expectEqual(@as(?u32, 1), nested.captureIndex("A"));
    try testing.expectEqual(@as(?u32, 2), nested.captureIndex("B"));
    try testing.expectEqual(@as(?u32, 3), nested.captureIndex("C"));
    try testing.expectEqual(@as(?u32, 6), nested.captureIndex("D"));

    const input = "directions from mountain view to san jose";
    var directions = try compile("directions from (?P<S>.*) to (?P<D>.*)", .{});
    defer directions.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &directions);
    defer matcher.deinit();
    const captured = (try matcher.fullCaptures(input)).?;
    const source = directions.namedCapture(captured, "S").?;
    const destination = directions.namedCapture(captured, "D").?;
    try testing.expectEqualStrings("mountain view", input[source.start..source.end]);
    try testing.expectEqualStrings("san jose", input[destination.start..destination.end]);
}

test "Qualification UTF8 and Latin1 consume Rune or byte units" {
    const input = "日本語";
    const middle_pattern = ".本.";
    try expectFull(true, ".........", input, .{ .encoding = .latin1 });
    try expectFull(true, "...", input, .{});

    var latin = try compile("(.)", .{ .encoding = .latin1 });
    defer latin.deinit();
    var latin_matcher = try api.Matcher.init(testing.allocator, &latin);
    defer latin_matcher.deinit();
    const latin_capture = (try latin_matcher.captures(input)).?;
    try testing.expectEqualSlices(u8, input[0..1], input[latin_capture.group(1).?.start..latin_capture.group(1).?.end]);

    var utf8 = try compile("(.)", .{});
    defer utf8.deinit();
    var utf8_matcher = try api.Matcher.init(testing.allocator, &utf8);
    defer utf8_matcher.deinit();
    const utf8_capture = (try utf8_matcher.captures(input)).?;
    try testing.expectEqualStrings("日", input[utf8_capture.group(1).?.start..utf8_capture.group(1).?.end]);

    try expectFull(true, input, input, .{ .encoding = .latin1 });
    try expectFull(true, input, input, .{});
    try expectFull(false, middle_pattern, input, .{ .encoding = .latin1 });
    try expectFull(true, middle_pattern, input, .{});
}

test "Qualification ungreedy UTF8 does not invent a full match" {
    for ([_][]const u8{ "\\w+X", "(?U)\\w+X" }) |pattern| {
        try expectFull(false, pattern, "a aX", .{
            .encoding = .latin1,
            .perl_classes = true,
        });
        try expectFull(false, pattern, "a aX", .{ .perl_classes = true });
    }
}

test "Qualification rejects unsupported and malformed syntax" {
    for ([_][]const u8{
        "a\\1",
        "a[x",
        "a[z-a]",
        "a[[:foobar:]]",
        "a(b",
        "a\\",
    }) |pattern| try expectRejected(pattern);
}

test "Qualification invalid and large patterns fail or run without crashing" {
    try expectRejected("a\\");
    try expectRejected("(((.{100}){100}){100}){100}");
    var input: [516]u8 = @splat('c');
    input[input.len - 1] = 'x';
    try expectFind(true, ".{512}x", &input, .{});
}

test "Qualification recursion stress remains iterative" {
    var expression = try compile("([a-zA-Z0-9]|-)+(\\.([a-zA-Z0-9]|-)+)*(\\.)?", .{});
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const domain = try testing.allocator.alloc(u8, 15 * 1024);
    defer testing.allocator.free(domain);
    for ([_][]const u8{ ".", "a", "a.", "ab.", "abc." }) |piece| {
        for (domain, 0..) |*byte, index| byte.* = piece[index % piece.len];
        _ = matcher.fullMatch(domain);
    }

    var comment: std.ArrayList(u8) = .empty;
    defer comment.deinit(testing.allocator);
    try comment.appendSlice(testing.allocator, "x*");
    try comment.appendNTimes(testing.allocator, 'a', 131_072);
    try comment.appendSlice(testing.allocator, "*x");
    try expectFull(true, "((?:\\s|xx.*\n|x[*](?:\n|.)*?[*]x)*)", comment.items, .{ .perl_classes = true });
}

test "Qualification rejects oversized Latin1 octal escapes" {
    try expectRejectedWithOptions("\\140\\440\\174\\271\\150\\656\\106\\201\\004\\332", .{
        .encoding = .latin1,
    });
}

test "Qualification never-newline option excludes newline from every predicate" {
    const Case = struct { pattern: []const u8, input: []const u8, expected: ?[]const u8 };
    for ([_]Case{
        .{ .pattern = "(.*)", .input = "abc\ndef\nghi\n", .expected = "abc" },
        .{ .pattern = "(?s)(abc.*def)", .input = "abc\ndef\n", .expected = null },
        .{ .pattern = "(abc(.|\n)*def)", .input = "abc\ndef\n", .expected = null },
        .{ .pattern = "(abc[^x]*def)", .input = "abc\ndef\n", .expected = null },
        .{ .pattern = "(abc[^x]*def)", .input = "abczzzdef\ndef\n", .expected = "abczzzdef" },
    }) |case| {
        var expression = try compile(case.pattern, .{ .exclude_newline = true });
        defer expression.deinit();
        var matcher = try api.Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();
        const captured = try matcher.captures(case.input);
        if (case.expected) |expected| {
            const group = captured.?.group(1).?;
            try testing.expectEqualStrings(expected, case.input[group.start..group.end]);
        } else try testing.expect(captured == null);
    }
}

test "Qualification dot-newline and never-newline precedence" {
    try expectFind(true, ".", "\n", .{ .dot_matches_newline = true });
    try expectFind(false, "(?-s).", "\n", .{ .dot_matches_newline = true });
    try expectFind(false, ".", "\n", .{ .dot_matches_newline = true, .exclude_newline = true });
}

test "Qualification never-capture removes explicit groups" {
    var expression = try compile("(r)(e)", .{ .capture_groups = false });
    defer expression.deinit();
    try testing.expectEqual(@as(u32, 0), expression.captureCount());
}

test "Qualification BitState captureless fallback regression" {
    try expectFind(false, "(_________$)", "xxxxxxxxxxxxxxxxxxxxxxxxxx_________x", .{
        .dfa_memory = .{ .bytes = 20_000 },
    });
}

test "Qualification empty character sets compile away safely" {
    for ([_][]const u8{
        "[^\\S\\s]",
        "[^\\S[:space:]]",
        "[^\\D\\d]",
        "[^\\D[:digit:]]",
    }) |pattern| try expectFind(false, pattern, "abc", .{ .perl_classes = true });

    for ([_][]const u8{
        "((((()))))[^\\S\\s]?",
        "((((()))))([^\\S\\s])?",
        "((((()))))([^\\S\\s]|[^\\S\\s])?",
        "((((()))))(([^\\S\\s]|[^\\S\\s])|)",
    }) |pattern| try expectFind(true, pattern, "", .{ .perl_classes = true });
}

test "Qualification duplicate capturing group names retain every index" {
    var expression = try compile("((abc)(?P<G2>)|((e+)(?P<G2>.*)(?P<G1>u+)))", .{});
    defer expression.deinit();
    try testing.expectEqual(@as(u32, 7), expression.captureCount());
    try testing.expect(expression.captureName(0) == null);
    try testing.expect(expression.captureName(1) == null);
    try testing.expect(expression.captureName(2) == null);
    try testing.expectEqualStrings("G2", expression.captureName(3).?);
    try testing.expect(expression.captureName(4) == null);
    try testing.expect(expression.captureName(5) == null);
    try testing.expectEqualStrings("G2", expression.captureName(6).?);
    try testing.expectEqualStrings("G1", expression.captureName(7).?);
    try testing.expect(expression.captureName(8) == null);
    try testing.expectEqual(@as(?u32, 3), expression.captureIndex("G2"));
    try testing.expectEqual(@as(?u32, 7), expression.captureIndex("G1"));
}

test "Qualification case-insensitive match and consume" {
    const input = "A fish named *Wanda*";
    var expression = try compile("(?i)([wand]{5})", .{});
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const captured = (try matcher.captures(input)).?;
    const group = captured.group(1).?;
    try testing.expectEqualStrings("Wanda", input[group.start..group.end]);

    const consumed = (try matcher.capturesIn(input, .{}, .unanchored)).?;
    const consumed_group = consumed.group(1).?;
    try testing.expectEqualStrings("Wanda", input[consumed_group.start..consumed_group.end]);
    try testing.expectEqual(consumed.group(0).?.end, consumed_group.end);
}

test "Qualification capture and case-fold regressions" {
    try expectFull(true, "([^\\\\])", "D", .{});

    const input = "bar:1,0x2F,030,4,5;baz:true;fooby:false,true";
    var expression = try compile("(\\w+)(?::((?:[^;\\\\]|\\\\.)*))?;?", .{ .perl_classes = true });
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const captured = (try matcher.captures(input)).?;
    try testing.expectEqualStrings("bar", input[captured.group(1).?.start..captured.group(1).?.end]);
    try testing.expectEqualStrings("1,0x2F,030,4,5", input[captured.group(2).?.start..captured.group(2).?.end]);

    try expectFull(true, "(((((llx((-3)|(4)))(;(llx((-3)|(4))))*))))", "llx-3;llx4", .{});
    for ([_][]const u8{ "x", "k", "s" }) |value|
        try expectFind(false, "(?i)\\W", value, .{ .perl_classes = true });
}

test "Qualification parser and matcher fuzz regressions" {
    const fuzz = [_]u8{
        0x28, 0x28, 0xfc, 0xfc, 0x08, 0x08, 0x26, 0x26, 0x28, 0xc2,
        0x9b, 0xc5, 0xc5, 0xd4, 0x8f, 0x8f, 0x69, 0x69, 0xe7, 0x29,
        0x7b, 0x37, 0x31, 0x31, 0x7d, 0xae, 0x7c, 0x7c, 0xf3, 0x29,
        0xae, 0xae, 0x2e, 0x2a, 0x29,
    };
    _ = try expectFind(true, &fuzz, &fuzz, .{
        .encoding = .latin1,
        .match_kind = .longest,
        .dot_matches_newline = true,
        .case_sensitive = false,
    });

    const bad_rune = [_]u8{
        0x28, 0x05, 0x05, 0x41, 0x41, 0x28, 0x24, 0x5b, 0x5e,
        0xf5, 0x87, 0x87, 0x90, 0x29, 0x5d, 0x29, 0x29,
    };
    try expectRejected(&bad_rune);

    try expectFind(true, "(\n**)", "))$", .{
        .encoding = .latin1,
        .semantics = .posix,
        .match_kind = .longest,
        .exclude_newline = true,
    });

    // Unicode groups are literals/classes accepted by the engine's Latin-1 parser;
    // this historical shape must compile without an internal compiler failure.
    var latin = try compile("g\\p{Zl}]", .{ .encoding = .latin1 });
    latin.deinit();
}

test "Qualification raw-byte factoring and nullable-repeat regressions" {
    var expression = try compile("a\\C*?c|a\\C*?b", .{});
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const found = matcher.find("abc").?;
    try testing.expectEqual(@as(usize, 0), found.start);
    try testing.expectEqual(@as(usize, 3), found.end);
    try testing.expect(matcher.fullMatch("abc"));

    for ([_][]const u8{ "(?:|a)*", "(?:|a)+" }) |pattern| {
        var nullable = try compile(pattern, .{});
        defer nullable.deinit();
        var nullable_matcher = try api.Matcher.init(testing.allocator, &nullable);
        defer nullable_matcher.deinit();
        const empty = nullable_matcher.find("aaa").?;
        try testing.expectEqual(empty.start, empty.end);
        try testing.expectEqual(@as(usize, 0), empty.start);
    }
}

test "Qualification empty iteration advances by scalar and preserves capture participation" {
    // NullVsEmptyStringSubmatches, and Issue104. Zig slices intentionally do
    // not distinguish null-backed and non-null-backed empty strings, but empty
    // capture participation and UTF-8-aware iteration are semantic.
    var empty_expression = try compile("()|(foo)", .{});
    defer empty_expression.deinit();
    var empty_matcher = try api.Matcher.init(testing.allocator, &empty_expression);
    defer empty_matcher.deinit();
    const captured = (try empty_matcher.captures("")).?;
    try testing.expectEqual(api.Match{ .start = 0, .end = 0 }, captured.group(0).?);
    try testing.expectEqual(api.Match{ .start = 0, .end = 0 }, captured.group(1).?);
    try testing.expect(captured.group(2) == null);
    try testing.expect(captured.group(3) == null);

    for ([_]struct { pattern: []const u8, input: []const u8, offsets: []const usize }{
        .{ .pattern = "a*", .input = "bc", .offsets = &.{ 0, 1, 2 } },
        .{ .pattern = "Ć*", .input = "ąć", .offsets = &.{ 0, "ą".len, "ąć".len } },
        .{ .pattern = "大*", .input = "人类", .offsets = &.{ 0, "人".len, "人类".len } },
    }) |case| {
        var expression = try compile(case.pattern, .{});
        defer expression.deinit();
        var matcher = try api.Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();
        var iterator = matcher.iterator(case.input);
        for (case.offsets) |offset| {
            const found = iterator.next().?;
            try testing.expectEqual(api.Match{ .start = offset, .end = offset }, found);
        }
        try testing.expect(iterator.next() == null);
    }
}

test "Qualification Latin1 factored prefix keeps byte encoding" {
    // the engine-relevant defect is the required prefix and three match ranges.
    const input = [_]u8{ 0xa5, 0xd1, 0xa5, 0xd1, 0x61, 0x63, 0xa5, 0x64 };
    var expression = try compile("\xa5\xd1|\xa5\x64", .{ .encoding = .latin1 });
    defer expression.deinit();
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    var iterator = matcher.iterator(&input);
    for ([_]api.Match{
        .{ .start = 0, .end = 2 },
        .{ .start = 2, .end = 4 },
        .{ .start = 6, .end = 8 },
    }) |expected| try testing.expectEqual(expected, iterator.next().?);
    try testing.expect(iterator.next() == null);
}

test "Qualification Unicode classes and captures" {
    for ([_]struct { input: []const u8, pattern: []const u8, expected: bool }{
        .{ .input = "A", .pattern = "\\p{L}", .expected = true },
        .{ .input = "A", .pattern = "\\p{Lu}", .expected = true },
        .{ .input = "A", .pattern = "\\p{Ll}", .expected = false },
        .{ .input = "A", .pattern = "\\P{L}", .expected = false },
        .{ .input = "A", .pattern = "\\P{Lu}", .expected = false },
        .{ .input = "A", .pattern = "\\P{Ll}", .expected = true },
    }) |case| try expectFull(case.expected, case.pattern, case.input, .{});
    for ([_][]const u8{ "譚", "永", "鋒" }) |value| {
        for ([_]struct { pattern: []const u8, expected: bool }{
            .{ .pattern = "\\p{L}", .expected = true },
            .{ .pattern = "\\p{Lu}", .expected = false },
            .{ .pattern = "\\p{Ll}", .expected = false },
            .{ .pattern = "\\P{L}", .expected = false },
            .{ .pattern = "\\P{Lu}", .expected = true },
            .{ .pattern = "\\P{Ll}", .expected = true },
        }) |case| try expectFull(case.expected, case.pattern, value, .{});
    }

    const input = "ABCDEFGHI譚永鋒";
    try expectThreeCaptures("(.).*?(.).*?(.)", input, .{ "A", "B", "C" });
    try expectThreeCaptures("(.).*?([\\p{L}]).*?(.)", input, .{ "A", "B", "C" });
    try expectFind(false, "\\P{L}", input, .{});
    try expectThreeCaptures("(.).*?([\\p{Lu}]).*?(.)", input, .{ "A", "B", "C" });
    try expectFind(false, "[^\\p{Lu}\\p{Lo}]", input, .{});
    try expectThreeCaptures(
        ".*(.).*?([\\p{Lu}\\p{Lo}]).*?(.)",
        input,
        .{ "譚", "永", "鋒" },
    );
}
