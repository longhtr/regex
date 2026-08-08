//! Independent model of assertions, scalar consumption, and ranged context.
//!
//! Readable atom tables are interpreted by a local assertion evaluator and a
//! local canonical UTF-8 decoder. The model explicitly distinguishes complete
//! input boundaries from requested range boundaries and treats malformed UTF-8
//! as one-byte progress that scalar atoms cannot consume.
//!
//! Generated crosses cover both encodings, semantic option switches, text/line/
//! word assertions, raw bytes, ranges, anchors, first/longest, captures, full
//! matching, and empty-match iteration. Production parser/context/engine helpers
//! are not used to derive answers. Repetition priority and multi-group capture
//! state remain in their smaller dedicated models.

const std = @import("std");
const api = @import("../root.zig");
const testing = std.testing;

const Encoding = enum { utf8, latin1 };
/// Assertion vocabulary evaluated by local complete-input predicates.
const Assertion = enum {
    begin_text,
    end_text,
    begin_line,
    end_line,
    word_boundary,
    not_word_boundary,
};
/// One-unit consuming atoms modeled independently in UTF-8 and Latin-1.
const Consumer = enum {
    a_or_b,
    not_c,
    digit,
    word,
    dot,
    greek,
    not_greek,
    latin,
    surrogate,
    fold_a_c,
};
const Atom = union(enum) { assertion: Assertion, consumer: Consumer };
/// Public source paired with its independent linear atom interpretation.
const Pattern = struct { source: []const u8, atoms: []const Atom };

const patterns = [_]Pattern{
    .{ .source = "\\A", .atoms = &.{.{ .assertion = .begin_text }} },
    .{ .source = "\\z", .atoms = &.{.{ .assertion = .end_text }} },
    .{ .source = "(?m:^)", .atoms = &.{.{ .assertion = .begin_line }} },
    .{ .source = "(?m:$)", .atoms = &.{.{ .assertion = .end_line }} },
    .{ .source = "\\b", .atoms = &.{.{ .assertion = .word_boundary }} },
    .{ .source = "\\B", .atoms = &.{.{ .assertion = .not_word_boundary }} },
    .{ .source = "[ab]", .atoms = &.{.{ .consumer = .a_or_b }} },
    .{ .source = "[^c]", .atoms = &.{.{ .consumer = .not_c }} },
    .{ .source = "\\d", .atoms = &.{.{ .consumer = .digit }} },
    .{ .source = "\\w", .atoms = &.{.{ .consumer = .word }} },
    .{ .source = ".", .atoms = &.{.{ .consumer = .dot }} },
    .{ .source = "\\A[ab]", .atoms = &.{ .{ .assertion = .begin_text }, .{ .consumer = .a_or_b } } },
    .{ .source = "[ab]\\z", .atoms = &.{ .{ .consumer = .a_or_b }, .{ .assertion = .end_text } } },
    .{ .source = "(?m:^)[ab]", .atoms = &.{ .{ .assertion = .begin_line }, .{ .consumer = .a_or_b } } },
    .{ .source = "[ab](?m:$)", .atoms = &.{ .{ .consumer = .a_or_b }, .{ .assertion = .end_line } } },
    .{ .source = "\\b[ab]", .atoms = &.{ .{ .assertion = .word_boundary }, .{ .consumer = .a_or_b } } },
    .{ .source = "[ab]\\b", .atoms = &.{ .{ .consumer = .a_or_b }, .{ .assertion = .word_boundary } } },
    .{ .source = "[ab][^c]", .atoms = &.{ .{ .consumer = .a_or_b }, .{ .consumer = .not_c } } },
    .{ .source = "\\d\\w", .atoms = &.{ .{ .consumer = .digit }, .{ .consumer = .word } } },
    .{ .source = "\\p{Greek}", .atoms = &.{.{ .consumer = .greek }} },
    .{ .source = "\\P{Greek}", .atoms = &.{.{ .consumer = .not_greek }} },
    .{ .source = "\\p{Latin}", .atoms = &.{.{ .consumer = .latin }} },
    .{ .source = "\\p{Cs}", .atoms = &.{.{ .consumer = .surrogate }} },
    .{ .source = "(?i)[a-c]", .atoms = &.{.{ .consumer = .fold_a_c }} },
};

const inputs = [_][]const u8{
    "",    "a",   "b",  "c",    "0",        "_",            "!",            "ab",               "ac",               " a", "a!",
    "\na", "a\n", "ba", "\xff", "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "A",  "B",
    "C",
    "é",
    "α",
    "Ω",
    "Ж",
};

fn isWord(byte: ?u8) bool {
    const value = byte orelse return false;
    return std.ascii.isAlphanumeric(value) or value == '_';
}

/// Independently evaluates one assertion from complete-input neighbors at an
/// absolute byte position; requested range edges never enter this predicate.
fn assertionHolds(assertion: Assertion, input: []const u8, position: usize) bool {
    const previous: ?u8 = if (position == 0) null else input[position - 1];
    const next: ?u8 = if (position == input.len) null else input[position];
    return switch (assertion) {
        .begin_text => position == 0,
        .end_text => position == input.len,
        .begin_line => position == 0 or previous == '\n',
        .end_line => position == input.len or next == '\n',
        .word_boundary => isWord(previous) != isWord(next),
        .not_word_boundary => isWord(previous) == isWord(next),
    };
}

fn continuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

/// Returns the width of one independently validated canonical scalar. It rejects
/// invalid leaders/continuations, overlong forms, surrogate encodings, and values
/// above U+10FFFF; Latin-1 accepts every byte as one scalar.
fn matchingRuneWidth(input: []const u8, position: usize, encoding: Encoding) ?usize {
    if (position >= input.len) return null;
    if (encoding == .latin1) return 1;
    const first = input[position];
    if (first <= 0x7f) return 1;
    const width: usize = if (first >= 0xc2 and first <= 0xdf)
        2
    else if (first >= 0xe0 and first <= 0xef)
        3
    else if (first >= 0xf0 and first <= 0xf4)
        4
    else
        return null;
    if (width > input.len - position) return null;
    for (input[position + 1 .. position + width]) |byte|
        if (!continuation(byte)) return null;
    if (width == 3) {
        const second = input[position + 1];
        if ((first == 0xe0 and second < 0xa0) or
            (first == 0xed and second > 0x9f)) return null;
    } else if (width == 4) {
        const second = input[position + 1];
        if ((first == 0xf0 and second < 0x90) or
            (first == 0xf4 and second > 0x8f)) return null;
    }
    return width;
}

/// Decodes bytes whose canonical structure was already established by the local
/// model, deliberately avoiding production scanner helpers.
fn decodeRune(input: []const u8, position: usize, width: usize) u32 {
    const first: u32 = input[position];
    return switch (width) {
        1 => first,
        2 => ((first & 0x1f) << 6) | (input[position + 1] & 0x3f),
        3 => ((first & 0x0f) << 12) |
            ((@as(u32, input[position + 1]) & 0x3f) << 6) |
            (input[position + 2] & 0x3f),
        4 => ((first & 0x07) << 18) |
            ((@as(u32, input[position + 1]) & 0x3f) << 12) |
            ((@as(u32, input[position + 2]) & 0x3f) << 6) |
            (input[position + 3] & 0x3f),
        else => unreachable,
    };
}

fn isGreek(rune: u32) bool {
    return (rune >= 0x0370 and rune <= 0x03ff) or
        (rune >= 0x1f00 and rune <= 0x1fff);
}

fn isLatin(rune: u32) bool {
    return (rune >= 'A' and rune <= 'Z') or (rune >= 'a' and rune <= 'z') or
        (rune >= 0x00c0 and rune <= 0x024f) or
        (rune >= 0x1e00 and rune <= 0x1eff);
}

/// Applies the additional second-byte bounds relevant to modeled Unicode
/// property consumers after generic continuation/width checks.
fn propertyEncodingValid(
    input: []const u8,
    position: usize,
    width: usize,
    encoding: Encoding,
) bool {
    if (encoding == .latin1 or width <= 2) return true;
    const first = input[position];
    const second = input[position + 1];
    if (width == 3) return first != 0xe0 or second >= 0xa0;
    return (first != 0xf0 or second >= 0x90) and
        (first != 0xf4 or second <= 0x8f);
}

/// Returns the absolute next byte position when one modeled consumer accepts;
/// malformed UTF-8 fails scalar consumers but raw-byte advances one byte.
fn consume(consumer: Consumer, input: []const u8, position: usize, encoding: Encoding) ?usize {
    const width = matchingRuneWidth(input, position, encoding) orelse return null;
    const rune = decodeRune(input, position, width);
    const property_valid = propertyEncodingValid(input, position, width, encoding);
    const accepted = switch (consumer) {
        .a_or_b => rune == 'a' or rune == 'b',
        .not_c => rune != 'c',
        .digit => rune >= '0' and rune <= '9',
        .word => rune <= 0xff and isWord(@intCast(rune)),
        .dot => rune != '\n',
        .greek => property_valid and isGreek(rune),
        .not_greek => property_valid and !isGreek(rune),
        .latin => property_valid and isLatin(rune),
        .surrogate => property_valid and rune >= 0xd800 and rune <= 0xdfff,
        .fold_a_c => (rune >= 'a' and rune <= 'c') or (rune >= 'A' and rune <= 'C'),
    };
    return if (accepted) position + width else null;
}

/// Interprets one linear atom sequence from an absolute start, consulting full
/// input for assertions while refusing consumption past `range_end`.
fn matchAt(
    pattern: Pattern,
    input: []const u8,
    start: usize,
    range_end: usize,
    encoding: Encoding,
) ?usize {
    var position = start;
    for (pattern.atoms) |atom| switch (atom) {
        .assertion => |assertion| {
            if (!assertionHolds(assertion, input, position)) return null;
        },
        .consumer => |consumer| {
            position = consume(consumer, input, position, encoding) orelse return null;
            if (position > range_end) return null;
        },
    };
    return position;
}

/// Enumerates legal starts in range order and returns the first modeled linear
/// match under requested anchoring.
fn findModel(
    pattern: Pattern,
    input: []const u8,
    range_start: usize,
    range_end: usize,
    anchor: api.Anchor,
    encoding: Encoding,
) ?api.Match {
    var start = range_start;
    while (start <= range_end) : (start += 1) {
        if (matchAt(pattern, input, start, range_end, encoding)) |end|
            return .{ .start = start, .end = end };
        if (anchor == .start) break;
    }
    return null;
}

/// Requires a modeled match to consume exactly the supplied absolute range.
fn exactModel(
    pattern: Pattern,
    input: []const u8,
    start: usize,
    end: usize,
    encoding: Encoding,
) bool {
    return (matchAt(pattern, input, start, end, encoding) orelse return false) == end;
}

/// Implements public empty-match progress independently: advance one strict
/// UTF-8 scalar, but one byte for malformed input or Latin-1. This is purposely
/// stricter than merely recognizing a structural leading-byte width.
fn strictScalarWidth(input: []const u8, position: usize, encoding: Encoding) usize {
    if (encoding == .latin1) return 1;
    const first = input[position];
    if (first <= 0x7f) return 1;
    if (first >= 0xc2 and first <= 0xdf and position + 2 <= input.len and
        continuation(input[position + 1])) return 2;
    if (first >= 0xe0 and first <= 0xef and position + 3 <= input.len and
        continuation(input[position + 1]) and continuation(input[position + 2]))
    {
        const second = input[position + 1];
        if ((first != 0xe0 or second >= 0xa0) and
            (first != 0xed or second <= 0x9f)) return 3;
    }
    if (first >= 0xf0 and first <= 0xf4 and position + 4 <= input.len and
        continuation(input[position + 1]) and continuation(input[position + 2]) and
        continuation(input[position + 3]))
    {
        const second = input[position + 1];
        if ((first != 0xf0 or second >= 0x90) and
            (first != 0xf4 or second <= 0x8f)) return 4;
    }
    return 1;
}

/// Fixed bounded sequence of modeled non-overlapping matches.
const Iteration = struct {
    values: [max_iteration_results]api.Match = undefined,
    len: usize = 0,
};
const max_iteration_results = 32;

/// Repeats modeled unanchored search with encoding-aware progress after duplicate
/// empty matches.
fn iterateModel(pattern: Pattern, input: []const u8, encoding: Encoding) Iteration {
    var result: Iteration = .{};
    var next_start: usize = 0;
    var last_end: ?usize = null;
    while (true) {
        const found = findModel(pattern, input, next_start, input.len, .unanchored, encoding) orelse break;
        if (found.start == found.end and last_end == found.end) {
            if (found.end == input.len) break;
            next_start = found.end + strictScalarWidth(input, found.end, encoding);
            continue;
        }
        result.values[result.len] = found;
        result.len += 1;
        last_end = found.end;
        next_start = found.end;
    }
    return result;
}

fn compilePattern(pattern: Pattern, encoding: Encoding, kind: api.MatchKind) !api.Regex {
    const compiled = try api.Regex.compile(testing.allocator, pattern.source, .{
        .encoding = if (encoding == .utf8) .utf8 else .latin1,
        .match_kind = kind,
        .perl_classes = true,
        .word_boundary = true,
    });
    return switch (compiled) {
        .success => |value| value,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

fn checkIteration(matcher: *api.Matcher, pattern: Pattern, input: []const u8, encoding: Encoding) !void {
    const expected = iterateModel(pattern, input, encoding);
    var actual = matcher.iterator(input);
    for (expected.values[0..expected.len]) |wanted|
        try testing.expectEqual(wanted, actual.next().?);
    try testing.expect(actual.next() == null);
}

/// Compiles one option-focused public case and checks both capture suppression
/// metadata and the resulting range under ordinary Matcher ownership.
fn checkOptionMatch(
    source: []const u8,
    input: []const u8,
    options: api.CompileOptions,
    expected: ?api.Match,
    expected_groups: u32,
) !void {
    const compiled = try api.Regex.compile(testing.allocator, source, options);
    var expression = switch (compiled) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer expression.deinit();
    try testing.expectEqual(expected_groups, expression.captureCount());
    var matcher = try api.Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    try testing.expectEqual(expected, matcher.find(input));
}

test "Context option crosses agree with direct independent predicates" {
    for ([_]bool{ false, true }) |case_sensitive| {
        for ([_][]const u8{ "a", "A", "b" }) |input| {
            const accepted = input[0] == 'a' or (!case_sensitive and input[0] == 'A');
            try checkOptionMatch(
                "a",
                input,
                .{ .case_sensitive = case_sensitive },
                if (accepted) .{ .start = 0, .end = 1 } else null,
                0,
            );
        }
    }

    for ([_]bool{ false, true }) |dot_matches_newline|
        try checkOptionMatch(
            ".",
            "\n",
            .{ .dot_matches_newline = dot_matches_newline },
            if (dot_matches_newline) .{ .start = 0, .end = 1 } else null,
            0,
        );

    for ([_]bool{ false, true }) |exclude_newline| {
        for ([_][]const u8{ "\n", "a" }) |input| {
            const accepted = input[0] == 'a' or !exclude_newline;
            try checkOptionMatch(
                "[\na]",
                input,
                .{ .exclude_newline = exclude_newline },
                if (accepted) .{ .start = 0, .end = 1 } else null,
                0,
            );
        }
    }

    for ([_]bool{ false, true }) |text_anchors|
        try checkOptionMatch(
            "^a",
            "\na",
            .{ .semantics = .posix, .text_anchors = text_anchors },
            if (text_anchors) null else .{ .start = 1, .end = 2 },
            0,
        );

    for ([_]bool{ false, true }) |literal|
        try checkOptionMatch(
            "a+",
            "xaa+aay",
            .{ .literal = literal },
            if (literal) .{ .start = 2, .end = 4 } else .{ .start = 1, .end = 3 },
            0,
        );

    for ([_]bool{ false, true }) |capture_groups|
        try checkOptionMatch(
            "(a)",
            "a",
            .{ .capture_groups = capture_groups },
            .{ .start = 0, .end = 1 },
            if (capture_groups) 1 else 0,
        );

    for ([_]struct {
        source: []const u8,
        enabling_field: enum { perl_classes, word_boundary },
    }{
        .{ .source = "\\d", .enabling_field = .perl_classes },
        .{ .source = "\\ba", .enabling_field = .word_boundary },
    }) |syntax| {
        const disabled = try api.Regex.compile(testing.allocator, syntax.source, .{
            .semantics = .posix,
        });
        try testing.expect(disabled == .diagnostic);
        try testing.expectEqual(
            @TypeOf(@as(api.Diagnostic, undefined).code).bad_escape,
            disabled.diagnostic.code,
        );
        var enabled_options = api.CompileOptions{ .semantics = .posix };
        switch (syntax.enabling_field) {
            .perl_classes => enabled_options.perl_classes = true,
            .word_boundary => enabled_options.word_boundary = true,
        }
        try checkOptionMatch(
            syntax.source,
            if (syntax.enabling_field == .perl_classes) "5" else "a",
            enabled_options,
            .{ .start = 0, .end = 1 },
            0,
        );
    }
}

test "Context model agrees on assertions classes malformed bytes ranges and iteration" {
    for (patterns) |pattern| {
        for ([_]Encoding{ .utf8, .latin1 }) |encoding| {
            for ([_]api.MatchKind{ .first, .longest }) |kind| {
                var expression = try compilePattern(pattern, encoding, kind);
                defer expression.deinit();
                var matcher = try api.Matcher.init(testing.allocator, &expression);
                defer matcher.deinit();

                for (inputs) |input| {
                    const whole = findModel(pattern, input, 0, input.len, .unanchored, encoding);
                    const actual_whole = matcher.find(input);
                    if (!std.meta.eql(whole, actual_whole)) {
                        std.debug.print(
                            "context model mismatch pattern={s} input={x} encoding={s} expected={any} actual={any}\n",
                            .{ pattern.source, input, @tagName(encoding), whole, actual_whole },
                        );
                        return error.ContextModelMismatch;
                    }
                    try testing.expectEqual(
                        exactModel(pattern, input, 0, input.len, encoding),
                        matcher.fullMatch(input),
                    );
                    try checkIteration(&matcher, pattern, input, encoding);

                    for (0..input.len + 1) |start| {
                        for (start..input.len + 1) |end| {
                            const range = api.SearchRange{ .start = start, .end = end };
                            for ([_]api.Anchor{ .unanchored, .start }) |anchor| {
                                const expected = findModel(pattern, input, start, end, anchor, encoding);
                                const actual = try matcher.findIn(input, range, anchor);
                                try testing.expectEqual(expected, actual);
                                const captured = try matcher.capturesIn(input, range, anchor);
                                try testing.expectEqual(expected != null, captured != null);
                                if (captured) |view| try testing.expectEqual(expected.?, view.group(0).?);
                            }
                            try testing.expectEqual(
                                exactModel(pattern, input, start, end, encoding),
                                try matcher.fullMatchIn(input, range),
                            );
                        }
                    }
                }
            }
        }
    }
}
