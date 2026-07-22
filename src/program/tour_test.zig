//! Executable compiler tour for `(ab|a)+c`.
//!
//! This is the bridge between the architecture narrative and the general-purpose
//! compiler. Read the test from top to bottom after `program/thompson.zig`: it
//! parses one small expression, keeps the temporary Graph returned by
//! `compileWithGraph`, and identifies literal leaves, capture writes, preferred
//! alternation, greedy repetition, acceptance, and the lower-priority unanchored
//! scan loop.
//!
//! The assertions are intentionally structural where ordinary qualification is
//! semantic. Their purpose is not to freeze every instruction layout, but to keep
//! one concrete Thompson construction available for newcomers following
//! `docs/architecture.md`. Broader language and representation tests live in
//! `compiler_qualification_test.zig`.

const std = @import("std");
const compiler = @import("compiler.zig");
const parser = @import("../syntax/parser.zig");
const program = @import("program.zig");
const testing = std.testing;

test "Source tour Thompson program for (ab|a)+c" {
    const parsed = try parser.parse(testing.allocator, "(ab|a)+c", .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = parsed.success;
    defer tree.deinit(testing.allocator);
    var compilation = try compiler.compileWithGraph(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
    });
    defer compilation.deinit(testing.allocator);
    const graph = &compilation.graph;
    try compilation.prog.validate();

    try testing.expectEqual(@as(usize, 12), graph.instructions.len);
    try testing.expectEqual(@as(program.InstId, @enumFromInt(5)), graph.start);
    try testing.expectEqual(@as(program.InstId, @enumFromInt(11)), graph.start_unanchored);
    const expected = [_]program.Opcode{
        .fail,
        .byte_range,
        .byte_range,
        .byte_range,
        .split,
        .capture,
        .capture,
        .split,
        .byte_range,
        .match,
        .byte_range,
        .split,
    };
    for (graph.instructions, expected) |instruction, opcode|
        try testing.expectEqual(opcode, instruction.opcode());

    try testing.expectEqual(@as(u8, 'a'), graph.instructions[1].byteLo());
    try testing.expectEqual(@as(u8, 'b'), graph.instructions[2].byteLo());
    try testing.expectEqual(@as(u8, 'a'), graph.instructions[3].byteLo());
    try testing.expectEqual(@as(program.CaptureSlot, @enumFromInt(2)), graph.instructions[5].captureSlot());
    try testing.expectEqual(@as(program.CaptureSlot, @enumFromInt(3)), graph.instructions[6].captureSlot());
    try testing.expectEqual(@as(program.InstId, @enumFromInt(1)), graph.instructions[4].out());
    try testing.expectEqual(@as(program.InstId, @enumFromInt(3)), graph.instructions[4].alternate());
    try testing.expectEqual(@as(program.InstId, @enumFromInt(5)), graph.instructions[7].out());
    try testing.expectEqual(@as(program.InstId, @enumFromInt(8)), graph.instructions[7].alternate());
    try testing.expectEqual(@as(u8, 'c'), graph.instructions[8].byteLo());
}
