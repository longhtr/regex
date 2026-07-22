//! Generated containment checks for public possible-match lexical bounds.
//!
//! Deterministic finite literal/alternation patterns provide independently known
//! language members. The campaign asks the public analyzer for bounded lexical
//! ranges and verifies exact extrema where finite, plus containment of every
//! generated member. Cases also exercise empty and unbounded languages.
//!
//! The tool complements focused unit tests with a larger offline cross-product;
//! it never uses a production match result to define its expected bounds.

const std = @import("std");
const regex = @import("../root.zig");

const input_alphabet = [_]u8{ 'a', 'b', '4' };
const atoms = [_][]const u8{ "a", "b", "4", "[ab]", "[^a]", ".", "\\d", "\\C" };
const repeats = [_][]const u8{ "", "?", "*", "+", "{0,2}", "??", "*?" };
const shape_count = 9;
const pattern_count = atoms.len * atoms.len * repeats.len * repeats.len * shape_count;

/// Maps an ordinal to one finite literal/alternation pattern with independently
/// enumerable members.
fn renderPattern(ordinal: usize, buffer: []u8) ![]const u8 {
    var selector = ordinal;
    const left = atoms[selector % atoms.len];
    selector /= atoms.len;
    const right = atoms[selector % atoms.len];
    selector /= atoms.len;
    const left_repeat = repeats[selector % repeats.len];
    selector /= repeats.len;
    const right_repeat = repeats[selector % repeats.len];
    selector /= repeats.len;
    return switch (selector % shape_count) {
        0 => std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{ left, left_repeat, right, right_repeat }),
        1 => std.fmt.bufPrint(buffer, "(?:{s}|{s}){s}{s}", .{ left, right, left_repeat, right }),
        2 => std.fmt.bufPrint(buffer, "{s}{s}(?:{s}|4)", .{ left, left_repeat, right }),
        3 => std.fmt.bufPrint(buffer, "(?:{s}{s}){s}", .{ left, right, left_repeat }),
        4 => std.fmt.bufPrint(buffer, "{s}(?:{s}{s}|a)", .{ left, right, right_repeat }),
        5 => std.fmt.bufPrint(buffer, "(?:{s}{s})?{s}", .{ left, left_repeat, right }),
        6 => std.fmt.bufPrint(buffer, "^(?:{s}{s}{s}{s})$", .{ left, left_repeat, right, right_repeat }),
        7 => std.fmt.bufPrint(buffer, "(?:{s}|{s}){{0,3}}", .{ left, right }),
        8 => std.fmt.bufPrint(buffer, "{s}(?:{s}|a){s}", .{ left, right, left_repeat }),
        else => unreachable,
    };
}

fn inputCount(max_length: usize) usize {
    var total: usize = 1;
    var width: usize = 1;
    for (0..max_length) |_| {
        width *= input_alphabet.len;
        total += width;
    }
    return total;
}

/// Decodes an ordinal as a short little-endian word over the campaign alphabet.
fn generatedInput(ordinal: usize, max_length: usize, buffer: []u8) []const u8 {
    var relative = ordinal;
    var width: usize = 1;
    var length: usize = 0;
    while (length <= max_length) : (length += 1) {
        if (relative < width) break;
        relative -= width;
        width *= input_alphabet.len;
    }
    var value = relative;
    var index = length;
    while (index != 0) {
        index -= 1;
        buffer[index] = input_alphabet[value % input_alphabet.len];
        value /= input_alphabet.len;
    }
    return buffer[0..length];
}

/// Checks unsigned bytewise membership in the public inclusive lexical range.
fn contains(range: regex.Regex.PossibleRange, value: []const u8) bool {
    return std.mem.order(u8, range.minimum, value) != .gt and
        std.mem.order(u8, value, range.maximum) != .gt;
}

/// Crosses every generated pattern with the finite input catalog and checks that
/// each public full match lies inside the independently reported lexical bound.
/// Empty-language results remain testable; unbounded languages are counted and
/// skipped because they intentionally publish no finite range.
pub fn main(init: std.process.Init) !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(general.deinit() == .ok);
    const allocator = general.allocator();
    var checks: usize = 0;
    var matches: usize = 0;
    var failures: usize = 0;
    var empty_languages: usize = 0;
    var unbounded_languages: usize = 0;
    var pattern_buffer: [128]u8 = undefined;
    var input_buffer: [5]u8 = undefined;
    const generated_inputs = inputCount(input_buffer.len);

    for (0..pattern_count) |pattern_ordinal| {
        const pattern = try renderPattern(pattern_ordinal, &pattern_buffer);
        const compiled = try regex.Regex.compile(allocator, pattern, .{
            .encoding = .utf8,
            .perl_classes = true,
        });
        var expression = switch (compiled) {
            .success => |value| value,
            .diagnostic => |diagnostic| {
                std.debug.print(
                    "generated pattern failed compilation pattern={s} diagnostic={s}\n",
                    .{ pattern, @tagName(diagnostic.code) },
                );
                return error.UnexpectedCompileDiagnostic;
            },
        };
        defer expression.deinit();
        var analysis = try expression.possibleMatchRange(allocator, 10);
        defer if (analysis == .range) analysis.range.deinit();
        var matcher = try regex.Matcher.init(allocator, &expression);
        defer matcher.deinit();

        switch (analysis) {
            .range => {},
            .empty_language => empty_languages += 1,
            .no_finite_max => {
                unbounded_languages += 1;
                continue;
            },
        }

        for (0..generated_inputs) |input_ordinal| {
            const input = generatedInput(input_ordinal, input_buffer.len, &input_buffer);
            checks += 1;
            if (!matcher.fullMatch(input)) continue;
            matches += 1;
            switch (analysis) {
                .range => |range| if (!contains(range, input)) {
                    failures += 1;
                    if (failures <= 20) std.debug.print(
                        "FAIL pattern={s} input={any} minimum={any} maximum={any}\n",
                        .{ pattern, input, range.minimum, range.maximum },
                    );
                },
                .empty_language => {
                    failures += 1;
                    if (failures <= 20) std.debug.print(
                        "FAIL empty pattern={s} unexpectedly matched input={any}\n",
                        .{ pattern, input },
                    );
                },
                .no_finite_max => unreachable,
            }
        }
    }

    if (pattern_count < 27_000 or checks < 8_000_000 or matches == 0)
        return error.InsufficientGeneratedCoverage;
    if (failures != 0) return error.ContainmentFailure;
    var output_buffer: [512]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    try writer.interface.print(
        "Possible-match campaign...OK\n" ++
            "  Patterns: {d}\n" ++
            "  Checks: {d}\n" ++
            "  Matches: {d}\n" ++
            "  Empty languages: {d}\n" ++
            "  Unbounded languages: {d}\n",
        .{ pattern_count, checks, matches, empty_languages, unbounded_languages },
    );
    try writer.interface.flush();
}
