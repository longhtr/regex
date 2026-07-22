//! Qualification of required-prefix publication and bounded literal search.
//!
//! Patterns are compiled to inspect only conservative prefix facts, then scanner
//! outputs are compared against exhaustive candidate offsets across exact,
//! folded, encoding-dependent, and bounded-range cases. AST string form and
//! physical vector route are deliberately not contracts.

const std = @import("std");
const compiler = @import("../program/compiler.zig");
const parser = @import("../syntax/parser.zig");
const prefix = @import("search.zig");
const program = @import("../program/program.zig");
const regexp = @import("../syntax/regexp.zig");
const testing = std.testing;

/// Syntax and Program owners retained together while prefix facts are inspected.
const Compiled = struct {
    tree: regexp.Regexp,
    prog: program.Program,

    fn deinit(self: *Compiled) void {
        self.prog.deinit(testing.allocator);
        self.tree.deinit(testing.allocator);
    }
};

fn compilePattern(pattern: []const u8, encoding: parser.Encoding) !Compiled {
    const parsed = try parser.parse(testing.allocator, pattern, .{
        .encoding = encoding,
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = switch (parsed) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    errdefer tree.deinit(testing.allocator);
    const prog = try compiler.compile(testing.allocator, &tree, .{
        .encoding = if (encoding == .utf8) .utf8 else .latin1,
        .max_instructions = 100_000,
    });
    return .{ .tree = tree, .prog = prog };
}

test "Qualification required acceleration prefixes are conservative" {
    for ([_]struct {
        pattern: []const u8,
        expected: []const u8,
        folded: bool = false,
    }{
        .{ .pattern = "", .expected = "" },
        .{ .pattern = "(?m)^", .expected = "" },
        .{ .pattern = "(?-m)^", .expected = "" },
        .{ .pattern = "a*", .expected = "" },
        .{ .pattern = "(a?)def", .expected = "" },
        .{ .pattern = "(ab?)def", .expected = "a" },
        .{ .pattern = "(abc?)def", .expected = "ab" },
        .{ .pattern = "abc$", .expected = "abc" },
        .{ .pattern = "^abc", .expected = "abc" },
        .{ .pattern = "(?i)abc", .expected = "abc", .folded = true },
        .{ .pattern = "abcd*", .expected = "abc" },
        .{ .pattern = "[Aa][Bb]cd*", .expected = "ab", .folded = true },
        .{ .pattern = "ab[Cc]d*", .expected = "ab" },
        .{ .pattern = "☺abc", .expected = "☺abc" },
    }) |case| {
        var compiled = try compilePattern(case.pattern, .utf8);
        defer compiled.deinit();
        try testing.expectEqualStrings(case.expected, compiled.prog.prefix);
        if (case.expected.len != 0)
            try testing.expectEqual(case.folded, compiled.prog.prefix_fold_ascii);
    }
}

test "Qualification folded K and S prefixes depend on encoding" {
    for ([_][]const u8{ "(?i)KLM", "(?i)STU" }) |pattern| {
        var latin1 = try compilePattern(pattern, .latin1);
        defer latin1.deinit();
        try testing.expectEqualStrings(if (pattern[4] == 'K') "klm" else "stu", latin1.prog.prefix);
        try testing.expect(latin1.prog.prefix_fold_ascii);

        var utf8 = try compilePattern(pattern, .utf8);
        defer utf8.deinit();
        try testing.expectEqual(@as(usize, 0), utf8.prog.prefix.len);
    }
}

test "Qualification prefix acceleration returns every exact and folded offset" {
    for (0..100) |leading| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try text.appendNTimes(testing.allocator, 'a', leading);
        try text.appendSlice(testing.allocator, "aababc");
        for (0..100) |trailing| {
            const original_len = text.items.len;
            try text.appendNTimes(testing.allocator, 'a', trailing);
            try testing.expectEqual(leading, prefix.find(text.items, 0, text.items.len, "aababc").?);
            try testing.expectEqual(leading, prefix.findFoldedAscii(text.items, 0, text.items.len, "aababc").?);
            text.shrinkRetainingCapacity(original_len);
        }

        var folded = try testing.allocator.dupe(u8, text.items);
        defer testing.allocator.free(folded);
        @memcpy(folded[leading..][0..6], "AABABC");
        try testing.expectEqual(leading, prefix.findFoldedAscii(folded, 0, folded.len, "aababc").?);
    }
}
