//! Focused forced-engine and optimizer-equivalence qualification.
//!
//! Helpers parse and compile one canonical Program, then invoke physical engines
//! directly—something the public API intentionally cannot request. Tests compare
//! unsimplified/simplified syntax, exhaustive UTF-8 boundaries, ordered NFA/DFA
//! ranges, OnePass/BitState/capture-NFA slots, forward/reverse composition, cache
//! collision/exhaustion, and unproductive-construction decline.
//!
//! Generated bounded grammars and byte inputs make optimizer agreement observable
//! even when normal dispatch would choose only one route.

const std = @import("std");
const match_types = @import("../match.zig");
const bit_state = @import("accelerate/bit_state.zig");
const capture_nfa = @import("capture_nfa.zig");
const dfa = @import("accelerate/dfa.zig");
const equivalence_campaign = @import("equivalence_campaign.zig");
const nfa = @import("nfa.zig");
const one_pass = @import("accelerate/one_pass.zig");
const compiler = @import("../program/compiler.zig");
const program = @import("../program/program.zig");
const parser = @import("../syntax/parser.zig");
const simplify = @import("../optimize/optimize.zig");
const regexp = @import("../syntax/regexp.zig");
const testing = std.testing;

/// Parsed syntax and forward/reverse Programs owned together for direct
/// physical-engine tests.
const Bundle = struct {
    tree: regexp.Regexp,
    forward: program.Program,
    reverse: program.Program,

    fn deinit(self: *@This()) void {
        self.reverse.deinit(testing.allocator);
        self.forward.deinit(testing.allocator);
        self.tree.deinit(testing.allocator);
    }
};

fn compilePattern(pattern: []const u8) !Bundle {
    const parsed = try parser.parse(testing.allocator, pattern, .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = switch (parsed) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    errdefer tree.deinit(testing.allocator);
    var forward = try compiler.compile(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
    });
    errdefer forward.deinit(testing.allocator);
    const reverse = try compiler.compile(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
        .reverse = true,
    });
    return .{ .tree = tree, .forward = forward, .reverse = reverse };
}

/// Independent canonical UTF-8 encoder used to construct boundary inputs without
/// calling production byte lowering.
fn encodeRune(value: u32, buffer: *[4]u8) []const u8 {
    if (value <= 0x7f) {
        buffer[0] = @intCast(value);
        return buffer[0..1];
    }
    if (value <= 0x7ff) {
        buffer[0] = @intCast(0xc0 | (value >> 6));
        buffer[1] = @intCast(0x80 | (value & 0x3f));
        return buffer[0..2];
    }
    if (value <= 0xffff) {
        buffer[0] = @intCast(0xe0 | (value >> 12));
        buffer[1] = @intCast(0x80 | ((value >> 6) & 0x3f));
        buffer[2] = @intCast(0x80 | (value & 0x3f));
        return buffer[0..3];
    }
    buffer[0] = @intCast(0xf0 | (value >> 18));
    buffer[1] = @intCast(0x80 | ((value >> 12) & 0x3f));
    buffer[2] = @intCast(0x80 | ((value >> 6) & 0x3f));
    buffer[3] = @intCast(0x80 | (value & 0x3f));
    return buffer;
}

/// Compares every whole/explicit group slot while both borrowed views are valid.
fn expectSameCaptures(
    expected: match_types.CaptureView,
    actual: match_types.CaptureView,
    group_count: usize,
) !void {
    for (0..group_count + 1) |group|
        try testing.expectEqual(expected.group(group), actual.group(group));
}

/// Binary De Bruijn construction for deterministic transition pressure.
fn deBruijnBinary(allocator: std.mem.Allocator, order: u5) ![]u8 {
    std.debug.assert(order >= 1);
    const size = @as(usize, 1) << order;
    const mask = size - 1;
    const visited = try allocator.alloc(bool, size);
    defer allocator.free(visited);
    @memset(visited, false);
    const output = try allocator.alloc(u8, size + order - 1);
    @memset(output[0 .. order - 1], '0');
    var bits: usize = 0;
    for (0..size) |index| {
        bits = (bits << 1) & mask;
        if (!visited[bits | 1]) {
            bits |= 1;
            output[order - 1 + index] = '1';
        } else {
            output[order - 1 + index] = '0';
        }
        std.debug.assert(!visited[bits]);
        visited[bits] = true;
    }
    return output;
}

test "Simplified and parser syntax preserve ranges captures and priority" {
    for ([_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "a|b", .input = "b" },
        .{ .pattern = "abc|abd", .input = "xxabd" },
        .{ .pattern = "a*a*", .input = "aaaa" },
        .{ .pattern = "a+a+", .input = "aaaa" },
        .{ .pattern = "a?a?", .input = "a" },
        .{ .pattern = "a*?a*", .input = "aaaa" },
        .{ .pattern = "(a*)a*", .input = "aaaa" },
        .{ .pattern = "(abc|abd)(a*a*)", .input = "abdaaa" },
        .{ .pattern = "(?:|a)*", .input = "aa" },
        .{ .pattern = "[W-ZP-XE-R]+", .input = "PREFIX" },
        .{ .pattern = "a{0}", .input = "x" },
        .{ .pattern = "a{2,4}", .input = "aaaaa" },
    }) |case| {
        const parsed = try parser.parse(testing.allocator, case.pattern, .{
            .max_pattern_bytes = 1 << 20,
            .max_nodes = 100_000,
            .max_captures = 1000,
        });
        var original_tree = switch (parsed) {
            .success => |tree| tree,
            .diagnostic => return error.UnexpectedDiagnostic,
        };
        defer original_tree.deinit(testing.allocator);
        var simplified_tree = try simplify.simplify(
            testing.allocator,
            &original_tree,
            100_000,
        );
        defer simplified_tree.deinit(testing.allocator);
        var original = try compiler.compile(testing.allocator, &original_tree, .{
            .encoding = .utf8,
            .max_instructions = 100_000,
        });
        defer original.deinit(testing.allocator);
        var reduced = try compiler.compile(testing.allocator, &simplified_tree, .{
            .encoding = .utf8,
            .max_instructions = 100_000,
        });
        defer reduced.deinit(testing.allocator);

        var original_matcher = try capture_nfa.Matcher.init(testing.allocator, &original);
        defer original_matcher.deinit();
        var reduced_matcher = try capture_nfa.Matcher.init(testing.allocator, &reduced);
        defer reduced_matcher.deinit();
        const expected = try original_matcher.captures(
            case.input,
            0,
            case.input.len,
            .unanchored,
            .first,
        );
        const actual = try reduced_matcher.captures(
            case.input,
            0,
            case.input.len,
            .unanchored,
            .first,
        );
        try testing.expectEqual(expected == null, actual == null);
        if (expected) |expected_view| {
            const actual_view = actual.?;
            try expectSameCaptures(
                expected_view,
                actual_view,
                original.capture_slots / 2 - 1,
            );
        }
    }
}

test "Generated simplification preserves bounded ranges captures and priority" {
    const atoms = [_][]const u8{ "a", "b", "[ab]", "(?:)", "(a)", "." };
    const repeats = [_][]const u8{ "", "?", "*", "+", "{0,2}" };
    const alphabet = [_]u8{ 'a', 'b' };
    var pattern_buffer: [128]u8 = undefined;
    var input_buffer: [3]u8 = undefined;

    for (0..128) |ordinal| {
        var selector = ordinal;
        const left = atoms[selector % atoms.len];
        selector /= atoms.len;
        const right = atoms[selector % atoms.len];
        selector /= atoms.len;
        const repeat = repeats[selector % repeats.len];
        selector /= repeats.len;
        const pattern = switch (selector % 4) {
            0 => try std.fmt.bufPrint(&pattern_buffer, "{s}{s}{s}", .{ left, repeat, right }),
            1 => try std.fmt.bufPrint(&pattern_buffer, "(?:{s}|{s}){s}", .{ left, right, repeat }),
            2 => try std.fmt.bufPrint(&pattern_buffer, "(?:{s}{s}){s}", .{ left, right, repeat }),
            3 => try std.fmt.bufPrint(&pattern_buffer, "{s}(?:{s}|a){s}", .{ left, right, repeat }),
            else => unreachable,
        };
        const parsed = try parser.parse(testing.allocator, pattern, .{
            .dot_nl = true,
            .perl_classes = true,
            .word_boundary = true,
            .max_pattern_bytes = 1 << 20,
            .max_nodes = 100_000,
            .max_captures = 1000,
        });
        var original_tree = switch (parsed) {
            .success => |tree| tree,
            .diagnostic => return error.UnexpectedDiagnostic,
        };
        defer original_tree.deinit(testing.allocator);
        var simplified_tree = try simplify.simplify(testing.allocator, &original_tree, 100_000);
        defer simplified_tree.deinit(testing.allocator);
        var original = try compiler.compile(testing.allocator, &original_tree, .{
            .encoding = .utf8,
            .max_instructions = 100_000,
        });
        defer original.deinit(testing.allocator);
        var reduced = try compiler.compile(testing.allocator, &simplified_tree, .{
            .encoding = .utf8,
            .max_instructions = 100_000,
        });
        defer reduced.deinit(testing.allocator);
        var original_matcher = try capture_nfa.Matcher.init(testing.allocator, &original);
        defer original_matcher.deinit();
        var reduced_matcher = try capture_nfa.Matcher.init(testing.allocator, &reduced);
        defer reduced_matcher.deinit();

        for (0..input_buffer.len + 1) |length| {
            const input_count = std.math.pow(usize, alphabet.len, length);
            for (0..input_count) |input_ordinal| {
                var value = input_ordinal;
                var index = length;
                while (index != 0) {
                    index -= 1;
                    input_buffer[index] = alphabet[value % alphabet.len];
                    value /= alphabet.len;
                }
                const input = input_buffer[0..length];
                for ([_]match_types.MatchKind{ .first, .longest }) |kind| {
                    for ([_]match_types.Anchor{ .unanchored, .start }) |anchor| {
                        const expected = try original_matcher.captures(
                            input,
                            0,
                            input.len,
                            anchor,
                            kind,
                        );
                        const actual = try reduced_matcher.captures(
                            input,
                            0,
                            input.len,
                            anchor,
                            kind,
                        );
                        try testing.expectEqual(expected == null, actual == null);
                        if (expected) |expected_view| try expectSameCaptures(
                            expected_view,
                            actual.?,
                            original.capture_slots / 2 - 1,
                        );
                    }
                }
            }
        }
    }
}

test "UTF-8 range lowering is exact across every scalar boundary" {
    var bundle = try compilePattern("[\\x{7E}-\\x{10001}]");
    defer bundle.deinit();
    var matcher = try nfa.Matcher.init(testing.allocator, &bundle.forward);
    defer matcher.deinit();
    var encoded: [4]u8 = undefined;
    for (0..0x110000) |raw| {
        const rune: u32 = @intCast(raw);
        const bytes = encodeRune(rune, &encoded);
        try testing.expectEqual(
            rune >= 0x7e and rune <= 0x10001 and !(rune >= 0xd800 and rune <= 0xdfff),
            try matcher.isMatch(bytes, 0, bytes.len, .start),
        );
    }
}

test "Forced BitState and OnePass captures agree with direct capture NFA" {
    for ([_]struct {
        pattern: []const u8,
        input: []const u8,
        start: usize,
        end: usize,
        one_pass: bool,
    }{
        .{ .pattern = "(a+)(b*)", .input = "aaabb", .start = 0, .end = 5, .one_pass = true },
        .{ .pattern = "(a)?b", .input = "b", .start = 0, .end = 1, .one_pass = true },
        .{ .pattern = "^(a)$", .input = "a", .start = 0, .end = 1, .one_pass = true },
        .{ .pattern = "((a|aa)*)b", .input = "aaab", .start = 0, .end = 4, .one_pass = false },
        .{ .pattern = "(a+?)(a*)", .input = "aaa", .start = 0, .end = 3, .one_pass = false },
        .{ .pattern = "\\b(a)\\b", .input = " a!", .start = 1, .end = 2, .one_pass = false },
    }) |case| {
        var bundle = try compilePattern(case.pattern);
        defer bundle.deinit();
        var reference = try capture_nfa.Matcher.init(testing.allocator, &bundle.forward);
        defer reference.deinit();
        const expected = (try reference.capturesExact(
            case.input,
            case.start,
            case.end,
        )).?;

        var bit = try bit_state.Matcher.init(testing.allocator, &bundle.forward);
        defer bit.deinit();
        const bit_result = (try bit.capturesExact(case.input, case.start, case.end)).?;
        try expectSameCaptures(expected, bit_result, bundle.forward.capture_slots / 2 - 1);

        var deterministic = try one_pass.Matcher.init(testing.allocator, &bundle.forward);
        defer deterministic.deinit();
        if (case.one_pass) {
            const one_result = (try deterministic.capturesExact(
                case.input,
                case.start,
                case.end,
            )).?;
            try expectSameCaptures(expected, one_result, bundle.forward.capture_slots / 2 - 1);
        } else {
            try testing.expectError(
                error.Ineligible,
                deterministic.capturesExact(case.input, case.start, case.end),
            );
        }
    }

    var anchored_bundle = try compilePattern("(a+)");
    defer anchored_bundle.deinit();
    var anchored_reference = try capture_nfa.Matcher.init(
        testing.allocator,
        &anchored_bundle.forward,
    );
    defer anchored_reference.deinit();
    var anchored_bit = try bit_state.Matcher.init(testing.allocator, &anchored_bundle.forward);
    defer anchored_bit.deinit();
    const expected_prefix = (try anchored_reference.captures(
        "aaX",
        0,
        3,
        .start,
        .first,
    )).?;
    const actual_prefix = (try anchored_bit.capturesSearch(
        "aaX",
        0,
        3,
        .start,
    )).?;
    try expectSameCaptures(expected_prefix, actual_prefix, 1);
    try testing.expect((try anchored_reference.captures(
        "xaa",
        0,
        3,
        .start,
        .first,
    )) == null);
    try testing.expect((try anchored_bit.capturesSearch(
        "xaa",
        0,
        3,
        .start,
    )) == null);
}

test "Forced forward and reverse DFA ranges agree with ordered NFA" {
    for ([_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "[a]|[a][a]", .input = "xaa" },
        .{ .pattern = "[a]+?", .input = "xxaa" },
        .{ .pattern = "(ab|a)+c", .input = "xxababc" },
        .{ .pattern = "^.*|\\w\\s{0,3}", .input = "aaab_\nxx" },
        .{ .pattern = "\\b[a-z]+\\b", .input = "  word!" },
    }) |case| {
        var bundle = try compilePattern(case.pattern);
        defer bundle.deinit();
        var reference = try nfa.Matcher.init(testing.allocator, &bundle.forward);
        defer reference.deinit();
        const expected = (try reference.find(
            case.input,
            0,
            case.input.len,
            .unanchored,
        )).?;

        var forward = try dfa.Matcher.init(testing.allocator, &bundle.forward, 2048, .first);
        defer forward.deinit();
        const end = (try forward.findEnd(case.input, 0, case.input.len, .unanchored)).?;
        var reverse = try dfa.Matcher.init(testing.allocator, &bundle.reverse, 2048, .longest);
        defer reverse.deinit();
        const start = (try reverse.findStartReverse(case.input, 0, end)).?;
        try testing.expectEqual(expected, match_types.Match{ .start = start, .end = end });
    }
}

test "De Bruijn pressure reports bounded DFA exhaustion for clean fallback" {
    const order: u5 = 10;
    const input = try deBruijnBinary(testing.allocator, order);
    defer testing.allocator.free(input);
    var bundle = try compilePattern("0[01]{10}2");
    defer bundle.deinit();

    var reference = try nfa.Matcher.init(testing.allocator, &bundle.forward);
    defer reference.deinit();
    try testing.expect((try reference.find(input, 0, input.len, .unanchored)) == null);

    var bounded = try dfa.Matcher.init(testing.allocator, &bundle.forward, 128, .first);
    defer bounded.deinit();
    try testing.expectError(
        error.StateLimit,
        bounded.findEnd(input, 0, input.len, .unanchored),
    );
    try testing.expectEqual(@as(usize, 128), bounded.stateCount());
    try testing.expect((try bounded.findEnd("", 0, 0, .unanchored)) == null);
    try testing.expectEqual(@as(usize, 128), bounded.stateCount());
}

test "DFA abandons state construction that consumes too few bytes" {
    const order: u5 = 12;
    const input = try deBruijnBinary(testing.allocator, order);
    defer testing.allocator.free(input);
    var bundle = try compilePattern("0[01]{12}2");
    defer bundle.deinit();

    var matcher = try dfa.Matcher.init(testing.allocator, &bundle.forward, 5000, .first);
    defer matcher.deinit();
    try testing.expectError(
        error.Unproductive,
        matcher.findEnd(input, 0, input.len, .unanchored),
    );
    try testing.expect(matcher.stateCount() >= 256);
    try testing.expect(matcher.stateCount() < 5000);
}

test "Generated forced engines agree across bounded grammar and byte inputs" {
    const stats = try equivalence_campaign.run(testing.allocator, .fixed);
    try testing.expectEqual(@as(usize, 96), stats.range_patterns);
    try testing.expectEqual(@as(usize, 74_976), stats.range_cases);
    try testing.expectEqual(@as(usize, 80), stats.capture_patterns);
    try testing.expectEqual(@as(usize, 6_800), stats.capture_cases);
    try testing.expect(stats.capture_matches > 0);
    try testing.expect(stats.one_pass_eligible >= 20);
    try testing.expect(stats.one_pass_ineligible >= 20);
}

test "Forced DFA range feeds exact OnePass and direct Pike captures" {
    var bundle = try compilePattern("(a+)(b*)");
    defer bundle.deinit();
    const input = "xxaaabb";

    var forward = try dfa.Matcher.init(testing.allocator, &bundle.forward, 2048, .first);
    defer forward.deinit();
    const end = (try forward.findEnd(input, 0, input.len, .unanchored)).?;
    var reverse = try dfa.Matcher.init(testing.allocator, &bundle.reverse, 2048, .longest);
    defer reverse.deinit();
    const start = (try reverse.findStartReverse(input, 0, end)).?;
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 7 }, match_types.Match{
        .start = start,
        .end = end,
    });

    var reference = try capture_nfa.Matcher.init(testing.allocator, &bundle.forward);
    defer reference.deinit();
    const expected = (try reference.capturesExact(input, start, end)).?;
    var deterministic = try one_pass.Matcher.init(testing.allocator, &bundle.forward);
    defer deterministic.deinit();
    const actual = (try deterministic.capturesExact(input, start, end)).?;
    try expectSameCaptures(expected, actual, bundle.forward.capture_slots / 2 - 1);
}
