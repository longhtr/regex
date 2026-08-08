//! Qualification of syntax-mode boundaries and source-span diagnostics.
//!
//! Reviewed tables cross Perl/POSIX availability, escapes, named captures,
//! look-around rejection, and rune-aligned error positions. Success tests inspect
//! semantic arena properties where needed; failure tests preserve stable public
//! code and exact byte span. No textual AST rendering is made a contract.

const std = @import("std");
const parser = @import("parser.zig");
const testing = std.testing;

fn options(semantics: parser.Semantics) parser.Options {
    return .{
        .semantics = semantics,
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    };
}

fn expectAccepted(pattern: []const u8, semantics: parser.Semantics) !void {
    const result = try parser.parse(testing.allocator, pattern, options(semantics));
    switch (result) {
        .success => |value| {
            var tree = value;
            tree.deinit(testing.allocator);
        },
        .diagnostic => |diagnostic| {
            std.debug.print("unexpected {s} diagnostic for {s}: {any}\n", .{ @tagName(semantics), pattern, diagnostic });
            return error.UnexpectedDiagnostic;
        },
    }
}

fn expectRejected(pattern: []const u8, semantics: parser.Semantics) !void {
    const result = try parser.parse(testing.allocator, pattern, options(semantics));
    switch (result) {
        .success => |value| {
            var tree = value;
            tree.deinit(testing.allocator);
            return error.ExpectedDiagnostic;
        },
        .diagnostic => {},
    }
}

test "Qualification parser keeps Perl and POSIX syntax boundaries distinct" {
    for ([_][]const u8{
        "[a-b-c]",
        "\\Qabc\\E",
        "\\Q*+?{[\\E",
        "(?:a)",
        "(?P<name>a)",
        "(?<name>a)",
    }) |pattern| {
        try expectAccepted(pattern, .perl);
        try expectRejected(pattern, .posix);
    }

    for ([_][]const u8{ "a++", "a**", "a?*", "a+*", "a{1}*" }) |pattern| {
        try expectRejected(pattern, .perl);
        try expectAccepted(pattern, .posix);
    }
}

test "Qualification parser named-capture diagnostics retain offending spans" {
    for ([_]struct { pattern: []const u8, code: parser.ErrorCode, offending: []const u8 }{
        .{ .pattern = "test(?P<name", .code = .bad_named_capture, .offending = "(?P<name" },
        .{ .pattern = "test(?P<space bar>z)", .code = .bad_named_capture, .offending = "(?P<space bar>" },
        .{ .pattern = "test(?<name", .code = .bad_named_capture, .offending = "(?<name" },
        .{ .pattern = "test(?<space bar>z)", .code = .bad_named_capture, .offending = "(?<space bar>" },
    }) |case| {
        const result = try parser.parse(testing.allocator, case.pattern, options(.perl));
        const diagnostic = result.diagnostic;
        try testing.expectEqual(case.code, diagnostic.code);
        try testing.expectEqualStrings(case.offending, case.pattern[diagnostic.start..diagnostic.end]);
    }
}

test "Qualification error codes retain Rune-aligned offending spans" {
    // whole unmatched expressions and an empty invalid-UTF8 argument; the Zig
    // diagnostic reports the precise operator or invalid byte instead.
    for ([_]struct { pattern: []const u8, code: parser.ErrorCode, offending: []const u8 }{
        .{ .pattern = "ab\\αcd", .code = .bad_escape, .offending = "\\α" },
        .{ .pattern = "ef\\x☺01", .code = .bad_escape, .offending = "\\x☺0" },
        .{ .pattern = "gh\\x1☺01", .code = .bad_escape, .offending = "\\x1☺" },
        .{ .pattern = "ij\\x1", .code = .bad_escape, .offending = "\\x1" },
        .{ .pattern = "kl\\x", .code = .bad_escape, .offending = "\\x" },
        .{ .pattern = "uv\\x{0000☺}", .code = .bad_escape, .offending = "\\x{0000☺" },
        .{ .pattern = "wx\\p{ABC", .code = .bad_char_range, .offending = "\\p{ABC" },
        .{ .pattern = "yz(?smiUX:abc)", .code = .bad_perl_operator, .offending = "(?smiUX" },
        .{ .pattern = "aa(?sm☺i", .code = .bad_perl_operator, .offending = "(?sm☺" },
        .{ .pattern = "bb[abc", .code = .missing_bracket, .offending = "[abc" },
        .{ .pattern = "abc(def", .code = .missing_paren, .offending = "(" },
        .{ .pattern = "abc)def", .code = .unexpected_paren, .offending = ")" },
        .{ .pattern = "mn\\x1\xff", .code = .bad_utf8, .offending = "\xff" },
        .{ .pattern = "op\xffqr", .code = .bad_utf8, .offending = "\xff" },
        .{ .pattern = "st\\x{00000\xff", .code = .bad_utf8, .offending = "\xff" },
        .{ .pattern = "zz\\p{\xff}", .code = .bad_utf8, .offending = "\xff" },
        .{ .pattern = "zz\\x{00\xff}", .code = .bad_utf8, .offending = "\xff" },
        .{ .pattern = "zz(?P<name\xff>abc)", .code = .bad_utf8, .offending = "\xff" },
    }) |case| {
        const result = try parser.parse(testing.allocator, case.pattern, options(.perl));
        const diagnostic = result.diagnostic;
        try testing.expectEqual(case.code, diagnostic.code);
        try testing.expectEqualStrings(
            case.offending,
            case.pattern[diagnostic.start..diagnostic.end],
        );
    }
}

test "Qualification parser look-around diagnostics retain operator spans" {
    for ([_]struct { pattern: []const u8, offending: []const u8 }{
        .{ .pattern = "(?=foo).*", .offending = "(?=" },
        .{ .pattern = "(?!foo).*", .offending = "(?!" },
        .{ .pattern = "(?<=foo).*", .offending = "(?<=" },
        .{ .pattern = "(?<!foo).*", .offending = "(?<!" },
    }) |case| {
        const result = try parser.parse(testing.allocator, case.pattern, options(.perl));
        const diagnostic = result.diagnostic;
        try testing.expectEqual(parser.ErrorCode.bad_perl_operator, diagnostic.code);
        try testing.expectEqualStrings(case.offending, case.pattern[diagnostic.start..diagnostic.end]);
    }
}
