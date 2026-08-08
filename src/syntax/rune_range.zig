//! Allocation-free set algebra over inclusive rune intervals.
//!
//! A normalized range set is sorted by lower endpoint, contains only valid
//! `lo <= hi <= U+10FFFF` intervals, and has neither overlap nor adjacency.
//! Merging adjacency gives each set a unique compact representation, enabling
//! binary search and linear two-set algorithms.
//!
//! `normalize` validates the complete input before sorting, so invalid data does
//! not partially mutate its caller. Complement, union, and intersection write to
//! caller-provided storage and reject insufficient capacity; they allocate
//! nothing and forbid aliasing where an output write could destroy unread input.
//!
//! The domain is Unicode code-point metadata, not only scalar values. Surrogate
//! category ranges from embedded Unicode data remain representable here and are
//! removed when UTF-8 byte programs are lowered. Cardinality uses checked `u64`
//! arithmetic over normalized inputs.

const std = @import("std");

pub const Rune = u32;
pub const max_rune: Rune = 0x10ffff;

/// Inclusive interval in the engine code-point metadata domain.
pub const Range = struct {
    lo: Rune,
    hi: Rune,

    pub fn init(lo: Rune, hi: Rune) error{InvalidRuneRange}!Range {
        const result = Range{ .lo = lo, .hi = hi };
        if (!result.isValid()) return error.InvalidRuneRange;
        return result;
    }

    pub fn isValid(self: Range) bool {
        return self.lo <= self.hi and self.hi <= max_rune;
    }
};

pub const rune_universe = Range{ .lo = 0, .hi = max_rune };

/// Sorts and merges ranges in place, returning the normalized prefix length.
/// Invalid input is reported before the slice is modified.
pub fn normalize(ranges: []Range) error{InvalidRuneRange}!usize {
    for (ranges) |item| {
        if (!item.isValid()) return error.InvalidRuneRange;
    }
    if (ranges.len < 2) return ranges.len;

    std.mem.sort(Range, ranges, {}, lessThan);
    var output: usize = 0;
    for (ranges[1..]) |next| {
        const current = &ranges[output];
        if (next.lo <= current.hi + 1) {
            current.hi = @max(current.hi, next.hi);
        } else {
            output += 1;
            ranges[output] = next;
        }
    }
    return output + 1;
}

pub fn isNormalized(ranges: []const Range) bool {
    for (ranges, 0..) |item, index| {
        if (!item.isValid()) return false;
        if (index > 0 and item.lo <= ranges[index - 1].hi + 1) return false;
    }
    return true;
}

/// Binary-searches a normalized set in O(log ranges).
pub fn contains(ranges: []const Range, rune: Rune) bool {
    var lo: usize = 0;
    var hi = ranges.len;
    while (lo < hi) {
        const middle = lo + (hi - lo) / 2;
        const item = ranges[middle];
        if (rune < item.lo) {
            hi = middle;
        } else if (rune > item.hi) {
            lo = middle + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Writes the engine Rune-domain complement of a normalized input.
/// `output` may alias neither `input` nor its backing allocation.
pub fn complement(
    input: []const Range,
    output: []Range,
) error{ InvalidInput, NoSpace }!usize {
    if (!isNormalized(input)) return error.InvalidInput;

    var written: usize = 0;
    var cursor = rune_universe.lo;
    for (input) |item| {
        if (cursor < item.lo) {
            try emit(output, &written, .{ .lo = cursor, .hi = item.lo - 1 });
        }
        cursor = item.hi + 1;
    }
    if (cursor <= rune_universe.hi) {
        try emit(output, &written, .{ .lo = cursor, .hi = rune_universe.hi });
    }
    return written;
}

/// Writes the union of two normalized inputs without allocating.
/// `output` may alias neither input nor their backing allocations.
pub fn setUnion(
    left: []const Range,
    right: []const Range,
    output: []Range,
) error{ InvalidInput, NoSpace }!usize {
    if (!isNormalized(left) or !isNormalized(right)) return error.InvalidInput;

    var left_index: usize = 0;
    var right_index: usize = 0;
    var written: usize = 0;
    while (left_index < left.len or right_index < right.len) {
        const take_left = right_index == right.len or
            (left_index < left.len and lessThan({}, left[left_index], right[right_index]));
        const next = if (take_left) left[left_index] else right[right_index];
        if (take_left) {
            left_index += 1;
        } else {
            right_index += 1;
        }

        if (written > 0 and next.lo <= output[written - 1].hi + 1) {
            output[written - 1].hi = @max(output[written - 1].hi, next.hi);
        } else {
            try emit(output, &written, next);
        }
    }
    return written;
}

/// Writes the intersection of two normalized inputs.
/// `output` may alias neither input nor their backing allocations.
pub fn intersect(
    left: []const Range,
    right: []const Range,
    output: []Range,
) error{ InvalidInput, NoSpace }!usize {
    if (!isNormalized(left) or !isNormalized(right)) return error.InvalidInput;

    var left_index: usize = 0;
    var right_index: usize = 0;
    var written: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        const a = left[left_index];
        const b = right[right_index];
        const overlap_lo = @max(a.lo, b.lo);
        const overlap_hi = @min(a.hi, b.hi);
        if (overlap_lo <= overlap_hi) {
            try emit(output, &written, .{ .lo = overlap_lo, .hi = overlap_hi });
        }
        if (a.hi < b.hi) {
            left_index += 1;
        } else {
            right_index += 1;
        }
    }
    return written;
}

/// Sums inclusive widths of a normalized set with checked arithmetic.
pub fn cardinality(ranges: []const Range) error{InvalidInput}!u64 {
    if (!isNormalized(ranges)) return error.InvalidInput;
    var result: u64 = 0;
    for (ranges) |item| {
        result += @as(u64, item.hi) - @as(u64, item.lo) + 1;
    }
    return result;
}

fn lessThan(_: void, left: Range, right: Range) bool {
    return left.lo < right.lo or (left.lo == right.lo and left.hi < right.hi);
}

fn emit(output: []Range, written: *usize, item: Range) error{NoSpace}!void {
    if (written.* == output.len) return error.NoSpace;
    output[written.*] = item;
    written.* += 1;
}

const testing = std.testing;

test "Range rejects reversal and values above engine Runemax" {
    try testing.expectError(error.InvalidRuneRange, Range.init(2, 1));
    try testing.expectError(error.InvalidRuneRange, Range.init(0x110000, 0x110000));
    try testing.expect((try Range.init(0xd800, 0xdfff)).isValid());
    try testing.expect((try Range.init(0xd7ff, 0xe000)).isValid());
}

test "Normalize sorts and merges overlap and adjacency" {
    var ranges = [_]Range{
        .{ .lo = 20, .hi = 30 },
        .{ .lo = 1, .hi = 2 },
        .{ .lo = 9, .hi = 19 },
        .{ .lo = 2, .hi = 8 },
        .{ .lo = 40, .hi = 40 },
    };
    const length = try normalize(&ranges);
    try testing.expectEqual(@as(usize, 2), length);
    try testing.expectEqualSlices(Range, &.{
        .{ .lo = 1, .hi = 30 },
        .{ .lo = 40, .hi = 40 },
    }, ranges[0..length]);
}

test "Normalize validates before mutating" {
    var ranges = [_]Range{
        .{ .lo = 10, .hi = 20 },
        .{ .lo = max_rune + 1, .hi = max_rune + 1 },
        .{ .lo = 1, .hi = 2 },
    };
    const original = ranges;
    try testing.expectError(error.InvalidRuneRange, normalize(&ranges));
    try testing.expectEqualSlices(Range, &original, &ranges);
}

test "Contains checks normalized boundaries" {
    const ranges = [_]Range{
        .{ .lo = 3, .hi = 5 },
        .{ .lo = 10, .hi = 20 },
    };
    try testing.expect(!contains(&ranges, 2));
    try testing.expect(contains(&ranges, 3));
    try testing.expect(contains(&ranges, 20));
    try testing.expect(!contains(&ranges, 21));
}

test "Code-point complement preserves source surrogate metadata" {
    var output: [1]Range = undefined;
    const length = try complement(&.{}, &output);
    try testing.expectEqualSlices(Range, &.{rune_universe}, output[0..length]);
    try testing.expectEqual(@as(u64, 0x110000), try cardinality(output[0..length]));
    try testing.expect(contains(output[0..length], 0xd800));
}

test "Union merges across both normalized inputs" {
    const left = [_]Range{
        .{ .lo = 1, .hi = 5 },
        .{ .lo = 20, .hi = 30 },
    };
    const right = [_]Range{
        .{ .lo = 6, .hi = 10 },
        .{ .lo = 25, .hi = 40 },
    };
    var output: [4]Range = undefined;
    const length = try setUnion(&left, &right, &output);
    try testing.expectEqualSlices(Range, &.{
        .{ .lo = 1, .hi = 10 },
        .{ .lo = 20, .hi = 40 },
    }, output[0..length]);
}

test "Complement and intersection preserve normalization" {
    const input = [_]Range{
        .{ .lo = 0, .hi = 9 },
        .{ .lo = 20, .hi = max_rune },
    };
    var inverse: [4]Range = undefined;
    const inverse_length = try complement(&input, &inverse);
    try testing.expectEqualSlices(Range, &.{.{ .lo = 10, .hi = 19 }}, inverse[0..inverse_length]);

    const right = [_]Range{.{ .lo = 5, .hi = 15 }};
    var overlap: [2]Range = undefined;
    const overlap_length = try intersect(&input, &right, &overlap);
    try testing.expectEqualSlices(Range, &.{.{ .lo = 5, .hi = 9 }}, overlap[0..overlap_length]);
}

test "Output capacity failures are explicit" {
    var too_small: [1]Range = undefined;
    try testing.expectError(
        error.NoSpace,
        complement(&.{.{ .lo = 10, .hi = 20 }}, &too_small),
    );
}
