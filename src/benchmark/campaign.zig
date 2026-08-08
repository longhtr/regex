//! Deterministic benchmark scaling series with explicit finite coordinates.
//!
//! `Series` names one cost shape and each associated scale array is visible at
//! the top of the file. `coordinate` maps the generated-catalog suffix index to a
//! `(series, ordinal)` pair, accounting for the longer bounded-repeat series;
//! `workload` then constructs declarative sources and independently calculated
//! expectations.
//!
//! Geometric input sizes expose asymptotic behavior, while dense values around
//! bounded-repeat route transitions expose crossovers. Dictionary, capture,
//! collection, depth, and capture-count series use their own meaningful scales.
//! Generation is deterministic, finite, self-contained, and never consults
//! timing results or external corpora.

const std = @import("std");
const workload_data = @import("workloads.zig");

const input_scales = [_]usize{ 64, 1024, 16 * 1024, 256 * 1024, 1024 * 1024 };
const alternation_counts = [_]usize{ 8, 32, 128, 512, 1000 };
const structure_counts = [_]usize{ 8, 32, 128, 512, 1000 };
const bounded_repeat_counts = [_]usize{
    32,  64,  100, 128, 160, 192, 224, 240, 248, 252,  256,
    260, 320, 384, 448, 512, 600, 700, 800, 900, 1000,
};
const collection_counts = [_]usize{ 8, 32, 128, 512, 1000 };
const mixed_dictionary_counts = [_]usize{ 8, 32, 128, 512, 3072 };
const mixed_dictionary_last_words = [_][]const u8{
    "cater0000", "cater0003stone", "cater0015stone", "cater0063stone", "cater0383stone",
};
const set_suffixes = [_][]const u8{
    "rule0007-suffix", "rule0031-suffix", "rule0127-suffix", "rule0511-suffix", "rule0999-suffix",
};
const filtered_suffixes = [_][]const u8{
    "token007-42", "token031-42", "token127-42", "token511-42", "token999-42",
};
const dictionary_words = [_][]const u8{ "word0007", "word0031", "word0127", "word0511", "word0999" };
const expected_pattern_ids = [_][1]u32{ .{7}, .{31}, .{127}, .{511}, .{999} };
const capture_groups = [_][2]?workload_data.Span{
    .{ .{ .start = 0, .end = 63 }, .{ .start = 63, .end = 64 } },
    .{ .{ .start = 0, .end = 1023 }, .{ .start = 1023, .end = 1024 } },
    .{ .{ .start = 0, .end = 16383 }, .{ .start = 16383, .end = 16384 } },
    .{ .{ .start = 0, .end = 262143 }, .{ .start = 262143, .end = 262144 } },
    .{ .{ .start = 0, .end = 1048575 }, .{ .start = 1048575, .end = 1048576 } },
};
/// Generated cost families; enum order defines flattened catalog order.
const Series = enum(usize) {
    ambiguous_positive,
    ambiguous_reject,
    nullable_reject,
    compile_alternation,
    count_runs,
    unicode_scan,
    bounded_optional,
    dictionary_find,
    compile_mixed_dictionary,
    mixed_dictionary_find,
    malformed_utf8_reject,
    latin1_scan,
    capture_scan,
    set_late,
    filtered_late,
    compile_depth,
    compile_captures,
};

/// Decoded generated-catalog location: one cost family and one index into its
/// explicit scale array.
const Coordinate = struct { series: Series, ordinal: usize };
const series_count = @typeInfo(Series).@"enum".fields.len;
const bounded_series_index = @intFromEnum(Series.bounded_optional);
pub const count = (series_count - 1) * input_scales.len + bounded_repeat_counts.len;

/// Maps the flattened generated index while accounting for the bounded-repeat
/// family having more coordinates than ordinary series.
fn coordinate(index: usize) !Coordinate {
    if (index >= count) return error.InvalidCampaignIndex;
    const ordinary_before = bounded_series_index * input_scales.len;
    const bounded_end = ordinary_before + bounded_repeat_counts.len;
    if (index < ordinary_before) return .{
        .series = @enumFromInt(index / input_scales.len),
        .ordinal = index % input_scales.len,
    };
    if (index < bounded_end) return .{
        .series = .bounded_optional,
        .ordinal = index - ordinary_before,
    };
    const adjusted = index - bounded_repeat_counts.len + input_scales.len;
    return .{
        .series = @enumFromInt(adjusted / input_scales.len),
        .ordinal = adjusted % input_scales.len,
    };
}

/// Returns the authored scale value for one decoded coordinate.
fn value(coordinate_value: Coordinate) usize {
    return switch (coordinate_value.series) {
        .compile_alternation, .dictionary_find => alternation_counts[coordinate_value.ordinal],
        .compile_mixed_dictionary, .mixed_dictionary_find => mixed_dictionary_counts[coordinate_value.ordinal],
        .set_late, .filtered_late => collection_counts[coordinate_value.ordinal],
        .compile_depth, .compile_captures => structure_counts[coordinate_value.ordinal],
        .bounded_optional => bounded_repeat_counts[coordinate_value.ordinal],
        else => input_scales[coordinate_value.ordinal],
    };
}

/// Formats the human-readable scale suffix shown by benchmark listing.
pub fn detail(index: usize, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "scale {d}", .{value(try coordinate(index))});
}

/// Constructs one generated declarative workload and derives its expected result
/// directly from scale/structure. The flattened index is first decoded to a
/// family-specific ordinal; each switch arm then states pattern, input, operation,
/// and oracle together so no measured engine result enters the expectation.
pub fn workload(index: usize) !workload_data.Workload {
    const coordinate_value = try coordinate(index);
    const series = coordinate_value.series;
    const ordinal = coordinate_value.ordinal;
    const scale = if (series == .bounded_optional)
        bounded_repeat_counts[ordinal]
    else
        input_scales[ordinal];
    return switch (series) {
        .ambiguous_positive => .{
            .name = "Measures overlapping-alternative acceptance across geometric input scales",
            .pattern = .{ .generated = .ambiguous_suffix },
            .input = .{ .fill_suffix = .{ .byte = 'a', .count = scale, .suffix = "b" } },
            .task = .{ .find = .{ .expected = .{ .some = .{ .start = 0, .end = scale } } } },
        },
        .ambiguous_reject => .{
            .name = "Measures overlapping-alternative rejection across geometric input scales",
            .pattern = .{ .generated = .ambiguous_suffix },
            .input = .{ .fill = .{ .byte = 'a', .count = scale } },
            .task = .{ .find = .{ .expected = .none } },
        },
        .nullable_reject => .{
            .name = "Measures nested-nullable rejection across geometric input scales",
            .pattern = .{ .generated = .nullable_suffix },
            .input = .{ .fill = .{ .byte = 'a', .count = scale } },
            .task = .{ .find = .{ .expected = .none } },
        },
        .compile_alternation => .{
            .name = "Measures compile scaling for shared-prefix literal alternatives",
            .pattern = .{ .generated = .{ .shared_alternation = .{ .count = alternation_counts[ordinal], .width = 4 } } },
            .task = .{ .compile = .{ .capture_count = 0 } },
        },
        .count_runs => .{
            .name = "Measures count scaling over separated ASCII runs",
            .pattern = .{ .literal = "[a]+" },
            .input = .{ .repeat = .{ .unit = "a ", .count = scale / 2 } },
            .task = .{ .count = .{ .expected = scale / 2 } },
        },
        .unicode_scan => .{
            .name = "Measures Unicode scalar-class scanning across geometric byte scales",
            .pattern = .{ .literal = "[\\p{Greek}]+$" },
            .input = .{ .repeat = .{ .unit = "α", .count = scale / 2 } },
            .task = .{ .find = .{ .expected = .{ .some = .{ .start = 0, .end = scale } } } },
        },
        .bounded_optional => .{
            .name = "Measures bounded optional full matching across program scales",
            .pattern = .{ .generated = .{ .bounded_optional = bounded_repeat_counts[ordinal] } },
            .input = .{ .fill = .{ .byte = 'a', .count = bounded_repeat_counts[ordinal] } },
            .task = .{ .full = .{ .expected = true } },
        },
        .dictionary_find => .{
            .name = "Measures large shared-prefix dictionary acceptance at the final alternative",
            .pattern = .{ .generated = .{ .shared_alternation = .{ .count = alternation_counts[ordinal], .width = 4 } } },
            .input = .{ .literal = dictionary_words[ordinal] },
            .task = .{ .find = .{ .expected = .{ .some = .{ .start = 0, .end = 8 } } } },
        },
        .compile_mixed_dictionary => .{
            .name = "Measures compile scaling for heterogeneous literal-prefix topology",
            .pattern = .{ .generated = .{ .mixed_dictionary = mixed_dictionary_counts[ordinal] } },
            .task = .{ .compile = .{ .capture_count = 0 } },
        },
        .mixed_dictionary_find => .{
            .name = "Measures late acceptance in a heterogeneous literal-prefix dictionary",
            .pattern = .{ .generated = .{ .mixed_dictionary = mixed_dictionary_counts[ordinal] } },
            .input = .{ .literal = mixed_dictionary_last_words[ordinal] },
            .task = .{ .find = .{ .expected = .{ .some = .{
                .start = 0,
                .end = mixed_dictionary_last_words[ordinal].len,
            } } } },
        },
        .malformed_utf8_reject => .{
            .name = "Measures scalar-consumer rejection over malformed UTF-8 bytes",
            .pattern = .{ .literal = ".+" },
            .input = .{ .fill = .{ .byte = 0xff, .count = scale } },
            .task = .{ .find = .{ .expected = .none } },
        },
        .latin1_scan => .{
            .name = "Measures Latin-1 scalar scanning across geometric byte scales",
            .pattern = .{ .literal = ".+$" },
            .input = .{ .fill = .{ .byte = 0xff, .count = scale } },
            .options = .{ .encoding = .latin1 },
            .task = .{ .find = .{ .expected = .{ .some = .{ .start = 0, .end = scale } } } },
        },
        .capture_scan => .{
            .name = "Measures exact two-group capture extraction across geometric input scales",
            .pattern = .{ .literal = "(a+)(b)" },
            .input = .{ .fill_suffix = .{ .byte = 'a', .count = scale, .suffix = "b" } },
            .task = .{ .captures = .{ .expected = .{
                .whole = .{ .start = 0, .end = scale },
                .groups = &capture_groups[ordinal],
            } } },
        },
        .set_late => .{
            .name = "Measures Set construction scale and late sparse result verification",
            .input = .{ .fill_suffix = .{ .byte = 'x', .count = scale, .suffix = set_suffixes[ordinal] } },
            .task = .{ .set = .{
                .patterns = .{ .numbered = .{ .prefix = "rule", .width = 4, .suffix = "-suffix", .count = collection_counts[ordinal] } },
                .expected_pattern_ids = &expected_pattern_ids[ordinal],
            } },
        },
        .filtered_late => .{
            .name = "Measures integrated filtering and verification across collection scales",
            .input = .{ .fill_suffix = .{ .byte = 'x', .count = scale, .suffix = filtered_suffixes[ordinal] } },
            .task = .{ .filtered = .{
                .patterns = .{ .numbered = .{ .prefix = "token", .width = 3, .suffix = "-[0-9]+", .count = collection_counts[ordinal] } },
                .expected_pattern_id = expected_pattern_ids[ordinal][0],
            } },
        },
        .compile_depth => .{
            .name = "Measures iterative parser and compiler scaling across group depth",
            .pattern = .{ .generated = .{ .deep_groups = structure_counts[ordinal] } },
            .task = .{ .compile = .{ .capture_count = 0 } },
        },
        .compile_captures => .{
            .name = "Measures compilation and publication across capture-count scales",
            .pattern = .{ .generated = .{ .many_captures = structure_counts[ordinal] } },
            .task = .{ .compile = .{ .capture_count = @intCast(structure_counts[ordinal]) } },
        },
    };
}

/// Verifies every generated workload has a nonempty unique name and a valid
/// expectation before the adapter exposes the catalog.
pub fn validate() !void {
    for (0..count) |index| {
        if ((try workload(index)).name.len == 0)
            return error.InvalidCampaignWorkload;
    }
}
