//! Independent malformed-pattern diagnostic specification.
//!
//! Each readable case hand-states malformed source bytes, expected public code,
//! and exact half-open byte span without importing parser internals. Coverage is
//! checked against the complete diagnostic enum so adding a code requires an
//! explicit contract. Resource-limit behavior is constructed separately from
//! syntax failures.
//!
//! This is a category/span oracle, not an exhaustive malformed grammar. Mutation
//! breadth, truncation combinations, and arbitrary-byte panic safety belong to
//! the deterministic fuzz campaign.

const std = @import("std");
const api = @import("../root.zig");
const testing = std.testing;

/// Independently authored malformed source and exact expected public diagnostic.
const Case = struct {
    pattern: []const u8,
    code: []const u8,
    start: usize,
    end: usize,
};

const cases = [_]Case{
    .{ .pattern = "(", .code = "missing_paren", .start = 0, .end = 1 },
    .{ .pattern = "a(b", .code = "missing_paren", .start = 1, .end = 2 },
    .{ .pattern = ")", .code = "unexpected_paren", .start = 0, .end = 1 },
    .{ .pattern = "a)", .code = "unexpected_paren", .start = 1, .end = 2 },
    .{ .pattern = "\\", .code = "trailing_backslash", .start = 0, .end = 1 },
    .{ .pattern = "abc\\", .code = "trailing_backslash", .start = 3, .end = 4 },
    .{ .pattern = "*", .code = "repeat_argument", .start = 0, .end = 1 },
    .{ .pattern = "a**", .code = "repeat_operator", .start = 2, .end = 3 },
    .{ .pattern = "\\1", .code = "bad_escape", .start = 0, .end = 2 },
    .{ .pattern = "x\\1", .code = "bad_escape", .start = 1, .end = 3 },
    .{ .pattern = "\\☺", .code = "bad_escape", .start = 0, .end = 4 },
    .{ .pattern = "\\x{", .code = "bad_utf8", .start = 0, .end = 3 },
    .{ .pattern = "\\p", .code = "bad_char_range", .start = 0, .end = 2 },
    .{ .pattern = "\\P", .code = "bad_char_range", .start = 0, .end = 2 },
    .{ .pattern = "[abc", .code = "missing_bracket", .start = 0, .end = 4 },
    .{ .pattern = "a{1001}", .code = "repeat_size", .start = 1, .end = 7 },
    .{ .pattern = "(?=a)", .code = "bad_perl_operator", .start = 0, .end = 3 },
    .{ .pattern = "(?P<name", .code = "bad_named_capture", .start = 0, .end = 8 },
    .{ .pattern = "\xff", .code = "bad_utf8", .start = 0, .end = 1 },
};

test "Diagnostic model preserves categories and exact byte spans" {
    const Code = @TypeOf(@as(api.Diagnostic, undefined).code);
    var covered = std.EnumSet(Code).initEmpty();
    for (cases) |case| {
        covered.insert(std.meta.stringToEnum(Code, case.code).?);
        const compiled = try api.Regex.compile(testing.allocator, case.pattern, .{});
        switch (compiled) {
            .success => |*unexpected| {
                var diagnostic = unexpected.*;
                diagnostic.deinit();
                return error.ExpectedDiagnostic;
            },
            .diagnostic => |diagnostic| {
                if (!std.mem.eql(u8, @tagName(diagnostic.code), case.code)) {
                    std.debug.print(
                        "diagnostic category mismatch pattern={x} expected={s} actual={s}\n",
                        .{ case.pattern, case.code, @tagName(diagnostic.code) },
                    );
                    return error.DiagnosticCategoryMismatch;
                }
                if (case.start != diagnostic.start or case.end != diagnostic.end) {
                    std.debug.print(
                        "diagnostic span mismatch pattern={x} expected={d}..{d} actual={d}..{d}\n",
                        .{ case.pattern, case.start, case.end, diagnostic.start, diagnostic.end },
                    );
                    return error.DiagnosticSpanMismatch;
                }
                try testing.expect(diagnostic.start <= diagnostic.end);
                try testing.expect(diagnostic.end <= case.pattern.len);
            },
        }
    }

    const limited = try api.Regex.compile(testing.allocator, "a", .{
        .compile_memory = .{ .bytes = 0 },
    });
    try testing.expect(limited == .diagnostic);
    try testing.expectEqual(Code.resource_limit, limited.diagnostic.code);
    covered.insert(.resource_limit);
    try testing.expectEqual(std.meta.fields(Code).len, covered.count());
}
