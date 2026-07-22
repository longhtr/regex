//! Qualification of compiler language, byte partitions, scale, and compactness.
//!
//! Small patterns are enumerated against temporary Graph acceptance to establish
//! lowering semantics independently of runtime list execution. Byte-map tests
//! verify every predicate boundary and malformed UTF-8 envelope. Deep nullable
//! generators qualify iterative scheduling and explicit admission bounds.
//!
//! Exact complete instruction dumps are avoided except where representation is
//! the subject; most assertions use semantic Graph/Program properties so benign
//! layout changes do not erase useful evidence.

const std = @import("std");
const compiler = @import("compiler.zig");
const parser = @import("../syntax/parser.zig");
const program = @import("program.zig");
const regexp = @import("../syntax/regexp.zig");
const testing = std.testing;

/// Parsed syntax, temporary Graph, and published Program owned as one inspection
/// fixture.
const Compiled = struct {
    tree: regexp.Regexp,
    prog: program.Program,
    graph: program.Graph,

    fn deinit(self: *Compiled) void {
        self.graph.deinit(testing.allocator);
        self.prog.deinit(testing.allocator);
        self.tree.deinit(testing.allocator);
    }
};

fn compilePattern(pattern: []const u8, encoding: parser.Encoding, reverse: bool) !Compiled {
    return compilePatternSemantics(pattern, encoding, .perl, reverse);
}

fn compilePatternSemantics(
    pattern: []const u8,
    encoding: parser.Encoding,
    semantics: parser.Semantics,
    reverse: bool,
) !Compiled {
    const parsed = try parser.parse(testing.allocator, pattern, .{
        .encoding = encoding,
        .semantics = semantics,
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = switch (parsed) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    errdefer tree.deinit(testing.allocator);
    const compiled = try compiler.compileWithGraph(testing.allocator, &tree, .{
        .encoding = if (encoding == .utf8) .utf8 else .latin1,
        .max_instructions = 100_000,
        .reverse = reverse,
    });
    return .{ .tree = tree, .prog = compiled.prog, .graph = compiled.graph };
}

/// Compiles both directions, verifies semantic byte acceptance symmetry, and
/// returns the forward fixture for additional structural assertions.
fn expectForwardReverseMap(pattern: []const u8, encoding: parser.Encoding) !Compiled {
    var forward = try compilePattern(pattern, encoding, false);
    errdefer forward.deinit();
    var reverse = try compilePattern(pattern, encoding, true);
    defer reverse.deinit();
    try testing.expectEqual(forward.prog.byte_class_count, reverse.prog.byte_class_count);
    try testing.expectEqualSlices(u8, forward.prog.byteClasses(), reverse.prog.byteClasses());
    return forward;
}

test "Qualification compile simple languages validate and obey instruction limit" {
    for ([_][]const u8{
        "a",     "ab",   "a|c",  "a|b",  "[ab]", "a+",    "a+?",     "a*",
        "a*?",   "a?",   "a??",  "a{4}", "(a)",  "(?:a)", "",        ".",
        "[^ab]", "[Aa]", "\\C+", "\\C*", "\\C?", "[[-`]", "(?:|a)*", "(?:|a)+",
    }) |pattern| {
        var compiled = try compilePattern(pattern, .latin1, false);
        defer compiled.deinit();
        try compiled.prog.validate();
        try testing.expect(compiled.graph.instructions.len > 0);

        try testing.expectError(error.InstructionLimit, compiler.compile(
            testing.allocator,
            &compiled.tree,
            .{ .encoding = .latin1, .max_instructions = 1 },
        ));
    }
}

test "Qualification compile byte maps preserve every semantic boundary" {
    var dot = try expectForwardReverseMap(".", .latin1);
    defer dot.deinit();
    const dot_map = dot.prog.byteClasses();
    try testing.expectEqual(dot_map[0x00], dot_map[0x09]);
    try testing.expect(dot_map[0x09] != dot_map[0x0a]);
    try testing.expect(dot_map[0x0a] != dot_map[0x0b]);
    try testing.expectEqual(dot_map[0x0b], dot_map[0xff]);

    var hex = try expectForwardReverseMap("[0-9A-Fa-f]+", .latin1);
    defer hex.deinit();
    const hex_map = hex.prog.byteClasses();
    try testing.expectEqual(hex_map[0x00], hex_map['/']);
    try testing.expect(hex_map[0x00] != hex_map['0']);
    try testing.expect(hex_map['0'] != hex_map[':']);
    try testing.expect(hex_map[':'] != hex_map['A']);
    try testing.expect(hex_map['A'] != hex_map['G']);
    try testing.expect(hex_map['G'] != hex_map['a']);
    try testing.expect(hex_map['a'] != hex_map['g']);

    var boundary = try expectForwardReverseMap("\\b", .latin1);
    defer boundary.deinit();
    // This Program carries word status in DFA context rather than in byte-map
    // classes, so an assertion-only program needs one byte class.
    try testing.expectEqual(@as(u16, 1), boundary.prog.byte_class_count);
    try testing.expect(boundary.prog.empty_mask_union.word_boundary);

    var nonunderscore = try expectForwardReverseMap("[^_]", .latin1);
    defer nonunderscore.deinit();
    const underscore_map = nonunderscore.prog.byteClasses();
    try testing.expectEqual(underscore_map[0], underscore_map['^']);
    try testing.expect(underscore_map[0] != underscore_map['_']);
    try testing.expect(underscore_map['`'] != underscore_map['_']);
}

test "Qualification compile UTF-8 dot partitions malformed envelope" {
    var dot = try expectForwardReverseMap(".", .utf8);
    defer dot.deinit();
    const map = dot.prog.byteClasses();
    try testing.expectEqual(map[0xc0], map[0xc1]);
    try testing.expectEqual(map[0xf5], map[0xff]);
    try testing.expect(map[0x00] != map[0x0a]);
    try testing.expect(map[0xc0] != map[0xc2]);
    try testing.expect(map[0xf5] != map[0xf4]);
    try testing.expect(map[0x80] != map[0xc2]);
    try testing.expect(map[0xc2] != map[0xe0]);
    try testing.expect(map[0xe0] != map[0xf0]);
}

test "Qualification compile Unicode ranges retain shared byte structure" {
    for ([_]struct { pattern: []const u8, maximum: usize }{
        .{ .pattern = "[\\x{10000}\\x{10010}]", .maximum = 20 },
        .{ .pattern = "[\\x{8000}-\\x{10FFF}]", .maximum = 48 },
        .{ .pattern = "[\\x{80}-\\x{10FFFF}]", .maximum = 64 },
    }) |case| {
        var forward = try compilePattern(case.pattern, .utf8, false);
        defer forward.deinit();
        var reverse = try compilePattern(case.pattern, .utf8, true);
        defer reverse.deinit();
        try testing.expect(forward.graph.instructions.len <= case.maximum);
        try testing.expect(reverse.graph.instructions.len <= case.maximum);
        try forward.prog.validate();
        try reverse.prog.validate();
    }
}

test "Qualification compile nested nullable expressions remain bounded" {
    for ([_][]const u8{
        "a**{3,}",
        "(a*|b*)*{3,}",
        "((|S.+)+|(|S.+)+|){2}",
    }) |pattern| {
        var compiled = try compilePatternSemantics(pattern, .latin1, .posix, false);
        defer compiled.deinit();
        try compiled.prog.validate();
        try testing.expect(compiled.graph.instructions.len < 200);
    }
}

test "Qualification random deep nullable lists stay within admission budget" {
    // Deterministic deep nullable case. This exposed the
    // former two-items-per-instruction allocation estimate.
    const pattern = "^(?:(?:(?:\\n{0,2})(?:(?:(?:(?:(?:(?:(?:(?:(?:\\b)+){0,1}){2})+?){4,5})??){0,})|\\a)))$";
    var compiled = try compilePattern(pattern, .utf8, false);
    defer compiled.deinit();
    try compiled.prog.validate();
    try testing.expect(compiled.prog.priority_lists.items.len <=
        compiled.graph.instructions.len * 1024);
}
