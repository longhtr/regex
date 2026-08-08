//! Deterministic generated cross-engine comparison shared by tests and tooling.
//!
//! A bounded grammar generates pattern bundles, while finite byte alphabets and
//! lengths generate inputs/ranges. Each bundle compiles one canonical Program and
//! executes complete ordered NFA/capture NFA plus eligible DFA, BitState, and
//! OnePass routes directly. Every optional completion must equal the corresponding
//! complete answer; decline is counted rather than treated as failure.
//!
//! Config exposes finite profile bounds, and Stats summarize coverage. Failure
//! reports enough pattern/input/range state for reproduction. This is a physical
//! equivalence oracle, not an independent definition of regex language: all
//! routes consume the same compiled Program, while independent public models in
//! `testing/` establish syntax and matching semantics. Physical selection remains
//! private and never becomes public execution policy.

const std = @import("std");
const match_types = @import("../match.zig");
const bit_state = @import("accelerate/bit_state.zig");
const capture_nfa = @import("capture_nfa.zig");
const dfa = @import("accelerate/dfa.zig");
const nfa = @import("nfa.zig");
const one_pass = @import("accelerate/one_pass.zig");
const compiler = @import("../program/compiler.zig");
const parser = @import("../syntax/parser.zig");
const program = @import("../program/program.zig");
const regexp = @import("../syntax/regexp.zig");

/// Explicit finite grammar/input bounds and DFA-state admission for one profile.
pub const Config = struct {
    range_patterns: usize = 96,
    capture_patterns: usize = 80,
    range_input_max: usize = 4,
    capture_input_max: usize = 3,
    max_dfa_states: u32 = 4096,

    pub const fixed = Config{};
    pub const full = Config{
        .range_patterns = 1008,
        .capture_patterns = 400,
    };

    fn validate(self: Config) !void {
        if (self.range_patterns == 0 or self.range_patterns > 1008 or
            self.capture_patterns == 0 or self.capture_patterns > 400 or
            self.range_input_max > 8 or self.capture_input_max > 8 or
            self.max_dfa_states == 0) return error.InvalidCampaignConfig;
    }
};

/// Completed semantic crosses and OnePass eligibility counts.
pub const Stats = struct {
    range_patterns: usize = 0,
    range_cases: usize = 0,
    capture_patterns: usize = 0,
    capture_cases: usize = 0,
    capture_matches: usize = 0,
    one_pass_eligible: usize = 0,
    one_pass_ineligible: usize = 0,

    pub fn totalCases(self: Stats) usize {
        return self.range_cases + self.capture_cases;
    }
};

/// One parsed tree and its forward/reverse Programs for direct physical-engine
/// comparison.
const Bundle = struct {
    allocator: std.mem.Allocator,
    tree: regexp.Regexp,
    forward: program.Program,
    reverse: program.Program,

    fn deinit(self: *@This()) void {
        self.reverse.deinit(self.allocator);
        self.forward.deinit(self.allocator);
        self.tree.deinit(self.allocator);
    }
};

/// Builds one shared syntax tree plus independently published forward/reverse
/// Programs so forced engines compare the same authored semantics.
fn compilePattern(allocator: std.mem.Allocator, pattern: []const u8) !Bundle {
    const parsed = try parser.parse(allocator, pattern, .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = switch (parsed) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    errdefer tree.deinit(allocator);
    var forward = try compiler.compile(allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
    });
    errdefer forward.deinit(allocator);
    const reverse = try compiler.compile(allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
        .reverse = true,
    });
    return .{
        .allocator = allocator,
        .tree = tree,
        .forward = forward,
        .reverse = reverse,
    };
}

/// Counts the empty string and every word through `max_len` over the finite
/// alphabet used by the campaign.
fn generatedInputCount(alphabet_len: usize, max_len: usize) usize {
    var total: usize = 1;
    var width: usize = 1;
    for (0..max_len) |_| {
        width *= alphabet_len;
        total += width;
    }
    return total;
}

/// Maps a dense ordinal to shortlex input bytes: length first, then base-alphabet
/// digits. This enumerates the finite domain exactly once without allocations.
fn generatedInput(
    ordinal: usize,
    alphabet: []const u8,
    max_len: usize,
    buffer: []u8,
) []const u8 {
    var relative = ordinal;
    var width: usize = 1;
    var length: usize = 0;
    while (length <= max_len) : (length += 1) {
        if (relative < width) break;
        relative -= width;
        width *= alphabet.len;
    }
    var value = relative;
    for (0..length) |offset| {
        const index = length - 1 - offset;
        buffer[index] = alphabet[value % alphabet.len];
        value /= alphabet.len;
    }
    return buffer[0..length];
}

fn reportMismatch(kind: []const u8, pattern: []const u8, input: []const u8) void {
    std.debug.print(
        "forced {s} mismatch pattern={s} input={x}\n",
        .{ kind, pattern, input },
    );
}

fn capturesEqual(expected: []const ?match_types.Match, actual: match_types.CaptureView) bool {
    for (expected, 0..) |group, index| {
        if (!std.meta.eql(group, actual.group(index))) return false;
    }
    return true;
}

/// Generates captureless cases and compares ordered NFA with forward/reverse DFA
/// over bounded input/range/anchor combinations.
fn runRanges(allocator: std.mem.Allocator, config: Config, stats: *Stats) !void {
    const atoms = [_][]const u8{ "a", "b", "[ab]", "[^a]", ".", "\\w" };
    const repeats = [_][]const u8{ "", "?", "*", "+", "??", "*?", "+?" };
    const alphabet = [_]u8{ 'a', 'b', ' ', '\n', 0x80 };
    const input_count = generatedInputCount(alphabet.len, config.range_input_max);

    for (0..config.range_patterns) |pattern_index| {
        var selector = pattern_index;
        const left = atoms[selector % atoms.len];
        selector /= atoms.len;
        const right = atoms[selector % atoms.len];
        selector /= atoms.len;
        const repeat = repeats[selector % repeats.len];
        selector /= repeats.len;
        const mode = selector % 4;
        var pattern_buffer: [96]u8 = undefined;
        const pattern = switch (mode) {
            0 => try std.fmt.bufPrint(&pattern_buffer, "{s}{s}{s}", .{ left, repeat, right }),
            1 => try std.fmt.bufPrint(&pattern_buffer, "(?:{s}|{s}){s}{s}", .{
                left,
                right,
                repeat,
                left,
            }),
            2 => try std.fmt.bufPrint(&pattern_buffer, "\\b{s}{s}{s}\\b", .{
                left,
                repeat,
                right,
            }),
            3 => try std.fmt.bufPrint(&pattern_buffer, "^{s}{s}|{s}$", .{
                left,
                repeat,
                right,
            }),
            else => unreachable,
        };
        var bundle = try compilePattern(allocator, pattern);
        defer bundle.deinit();
        var reference = try nfa.Matcher.init(allocator, &bundle.forward);
        defer reference.deinit();
        var forward = try dfa.Matcher.init(
            allocator,
            &bundle.forward,
            config.max_dfa_states,
            .first,
        );
        defer forward.deinit();
        var reverse = try dfa.Matcher.init(
            allocator,
            &bundle.reverse,
            config.max_dfa_states,
            .longest,
        );
        defer reverse.deinit();

        var input_buffer: [8]u8 = undefined;
        for (0..input_count) |input_index| {
            const input = generatedInput(
                input_index,
                &alphabet,
                config.range_input_max,
                &input_buffer,
            );
            const expected = try reference.find(input, 0, input.len, .unanchored);
            const actual_end = try forward.findEnd(input, 0, input.len, .unanchored);
            if ((expected == null) != (actual_end == null)) {
                reportMismatch("DFA status", pattern, input);
                return error.EngineMismatch;
            }
            if (expected) |expected_range| {
                const actual_start = (try reverse.findStartReverse(
                    input,
                    0,
                    actual_end.?,
                )) orelse {
                    reportMismatch("reverse DFA status", pattern, input);
                    return error.EngineMismatch;
                };
                const actual = match_types.Match{ .start = actual_start, .end = actual_end.? };
                if (!std.meta.eql(expected_range, actual)) {
                    reportMismatch("DFA range", pattern, input);
                    return error.EngineMismatch;
                }
            }
            stats.range_cases += 1;
        }
        stats.range_patterns += 1;
    }
}

/// Generates captured cases and compares complete capture NFA with eligible
/// BitState and OnePass exact replay.
fn runCaptures(allocator: std.mem.Allocator, config: Config, stats: *Stats) !void {
    const atoms = [_][]const u8{ "a", "b", "[ab]", "." };
    const repeats = [_][]const u8{ "", "?", "*", "+", "*?" };
    const alphabet = [_]u8{ 'a', 'b', ' ', 0x80 };
    const input_count = generatedInputCount(alphabet.len, config.capture_input_max);

    for (0..config.capture_patterns) |pattern_index| {
        var selector = pattern_index;
        const left = atoms[selector % atoms.len];
        selector /= atoms.len;
        const right = atoms[selector % atoms.len];
        selector /= atoms.len;
        const left_repeat = repeats[selector % repeats.len];
        selector /= repeats.len;
        const right_repeat = repeats[selector % repeats.len];
        var pattern_buffer: [64]u8 = undefined;
        const pattern = try std.fmt.bufPrint(&pattern_buffer, "({s}{s})({s}{s})", .{
            left,
            left_repeat,
            right,
            right_repeat,
        });
        var bundle = try compilePattern(allocator, pattern);
        defer bundle.deinit();
        var reference = try capture_nfa.Matcher.init(allocator, &bundle.forward);
        defer reference.deinit();
        var bit = try bit_state.Matcher.init(allocator, &bundle.forward);
        defer bit.deinit();
        var deterministic = try one_pass.Matcher.init(allocator, &bundle.forward);
        defer deterministic.deinit();
        var deterministic_eligible: ?bool = null;

        var input_buffer: [8]u8 = undefined;
        for (0..input_count) |input_index| {
            const input = generatedInput(
                input_index,
                &alphabet,
                config.capture_input_max,
                &input_buffer,
            );
            stats.capture_cases += 1;
            const found = try reference.captures(
                input,
                0,
                input.len,
                .unanchored,
                .first,
            );
            if (found) |expected_view| {
                stats.capture_matches += 1;
                var expected: [3]?match_types.Match = undefined;
                for (&expected, 0..) |*group, group_index|
                    group.* = expected_view.group(group_index);
                const whole = expected[0].?;
                const bit_view = (try bit.capturesExact(
                    input,
                    whole.start,
                    whole.end,
                )) orelse {
                    reportMismatch("BitState status", pattern, input);
                    return error.EngineMismatch;
                };
                if (!capturesEqual(&expected, bit_view)) {
                    reportMismatch("BitState captures", pattern, input);
                    return error.EngineMismatch;
                }

                if (deterministic_eligible != false) {
                    const one_view = deterministic.capturesExact(
                        input,
                        whole.start,
                        whole.end,
                    ) catch |err| switch (err) {
                        error.Ineligible => {
                            deterministic_eligible = false;
                            continue;
                        },
                        else => return err,
                    };
                    deterministic_eligible = true;
                    if (one_view == null or !capturesEqual(&expected, one_view.?)) {
                        reportMismatch("OnePass captures", pattern, input);
                        return error.EngineMismatch;
                    }
                }
            }
        }
        if (deterministic_eligible == null) {
            reportMismatch("capture grammar coverage", pattern, "");
            return error.NoMatchingGeneratedInput;
        }
        if (deterministic_eligible.?)
            stats.one_pass_eligible += 1
        else
            stats.one_pass_ineligible += 1;
        stats.capture_patterns += 1;
    }
}

/// Validates bounds, runs captureless and capture crosses, and returns explicit
/// coverage counts for gate/reporting assertions.
pub fn run(allocator: std.mem.Allocator, config: Config) !Stats {
    try config.validate();
    var stats: Stats = .{};
    try runRanges(allocator, config, &stats);
    try runCaptures(allocator, config, &stats);
    return stats;
}
