//! Typed access to embedded Unicode group and simple-fold data.
//!
//! `generated.bin` contains a versioned little-endian header followed by sorted
//! group records, names, normalized rune ranges, and fold pairs. Comptime layout
//! checks and bounds-aware readers turn those byte regions into typed values
//! without asking Zig's type checker to instantiate thousands of source literals.
//!
//! Group names are sorted and looked up by exact binary search; the returned
//! range slice is normalized engine rune metadata. Fold pairs are sorted by
//! source rune. `foldLowerBound` and `foldNext` expose simple-fold cycles used by
//! class construction, while `toLower` chooses a stable canonical member used by
//! conservative prefilter normalization.
//!
//! The data includes Unicode category metadata for surrogate code points because
//! range algebra operates on code points. UTF-8 lowering separately excludes
//! non-scalars. This module allocates nothing and its returned slices borrow the
//! embedded blob for the process lifetime.

const std = @import("std");
const rune_range = @import("../syntax/rune_range.zig");

pub const version = "17.0.0";
pub const Rune = rune_range.Rune;
pub const Range = rune_range.Range;
/// One directed edge in a Unicode simple-fold cycle.
pub const FoldPair = struct { from: Rune, to: Rune };

const bytes = @embedFile("generated.bin");
const header_size = 24;
const group_entry_size = 16;
const range_entry_size = 8;
const fold_entry_size = 8;
const any_index = std.math.maxInt(u32);

const group_count = readU32(8);
const range_count = readU32(12);
const fold_count = readU32(16);
const names_size = readU32(20);
const groups_offset = header_size;
const ranges_offset = groups_offset + group_count * group_entry_size;
const folds_offset = ranges_offset + range_count * range_entry_size;
const names_offset = folds_offset + fold_count * fold_entry_size;
const fold_page_total = (rune_range.max_rune >> 8) + 1;
const fold_pages_offset = names_offset + names_size;
const fold_targets_offset = fold_pages_offset + fold_page_total;
const fold_target_page_count = blk: {
    @setEvalBranchQuota(20_000);
    var count: usize = 0;
    for (bytes[fold_pages_offset..fold_targets_offset]) |page| {
        if (page != std.math.maxInt(u8)) count = @max(count, @as(usize, page) + 1);
    }
    break :blk count;
};
const lowercase_count_offset = fold_targets_offset + fold_target_page_count * 256 * 4;
const lowercase_pairs_offset = lowercase_count_offset + 4;
const lowercase_count = readU32(lowercase_count_offset);

comptime {
    if (!std.mem.eql(u8, bytes[0..8], "REGXUCD1")) @compileError("bad Unicode table magic");
    if (lowercase_pairs_offset + lowercase_count * 8 != bytes.len)
        @compileError("bad Unicode table size");
}

/// Lightweight borrowed handle to one group record in the embedded blob.
pub const Group = struct {
    index: u32,

    pub fn name(self: Group) []const u8 {
        if (self.index == any_index) return "Any";
        const offset = groupOffset(self.index);
        const first = names_offset + readU32(offset);
        const len = readU16(offset + 4);
        return bytes[first .. first + len];
    }

    pub fn rangeCount(self: Group) u32 {
        if (self.index == any_index) return 1;
        return readU32(groupOffset(self.index) + 12);
    }

    pub fn rangeAt(self: Group, index: u32) Range {
        std.debug.assert(index < self.rangeCount());
        if (self.index == any_index) return rune_range.rune_universe;
        const first = readU32(groupOffset(self.index) + 8);
        return readRange(first + index);
    }

    pub fn contains(self: Group, rune: Rune) bool {
        var lo: u32 = 0;
        var hi = self.rangeCount();
        while (lo < hi) {
            const middle = lo + (hi - lo) / 2;
            const range = self.rangeAt(middle);
            if (rune < range.lo) {
                hi = middle;
            } else if (rune > range.hi) {
                lo = middle + 1;
            } else {
                return true;
            }
        }
        return false;
    }
};

/// Binary-searches exact case-sensitive group names; no alias normalization is
/// performed.
pub fn findGroup(name: []const u8) ?Group {
    if (std.mem.eql(u8, name, "Any")) return .{ .index = any_index };

    var lo: u32 = 0;
    var hi = group_count;
    while (lo < hi) {
        const middle = lo + (hi - lo) / 2;
        const group = Group{ .index = middle };
        switch (std.mem.order(u8, name, group.name())) {
            .lt => hi = middle,
            .gt => lo = middle + 1,
            .eq => return group,
        }
    }
    return null;
}

pub fn foldPair(index: u32) FoldPair {
    std.debug.assert(index < fold_count);
    const offset = folds_offset + index * fold_entry_size;
    return .{ .from = readU32(offset), .to = readU32(offset + 4) };
}

pub fn foldCount() u32 {
    return fold_count;
}

/// Lower-bound search into sorted fold pairs, used to begin exact source lookup.
pub fn foldLowerBound(rune: Rune) u32 {
    var lo: u32 = 0;
    var hi = fold_count;
    while (lo < hi) {
        const middle = lo + (hi - lo) / 2;
        if (foldPair(middle).from < rune) {
            lo = middle + 1;
        } else {
            hi = middle;
        }
    }
    return lo;
}

/// Returns the next member of a simple-fold cycle, or the rune itself when no
/// mapping exists.
pub fn foldNext(rune: Rune) Rune {
    if (rune > rune_range.max_rune) return rune;
    const page = bytes[fold_pages_offset + (rune >> 8)];
    if (page == std.math.maxInt(u8)) return rune;
    const target_index = @as(usize, page) * 256 + @as(u8, @truncate(rune));
    const target = readU32(fold_targets_offset + target_index * 4);
    return if (target == 0) rune else target;
}

/// Canonical simple case-fold mapping used by conservative prefilters.
pub fn toLower(rune: Rune) Rune {
    var lo: u32 = 0;
    var hi = lowercase_count;
    while (lo < hi) {
        const middle = lo + (hi - lo) / 2;
        const offset = lowercase_pairs_offset + @as(usize, middle) * 8;
        const source = readU32(offset);
        if (source < rune) {
            lo = middle + 1;
        } else if (source > rune) {
            hi = middle;
        } else {
            return readU32(offset + 4);
        }
    }
    return rune;
}

fn groupOffset(index: u32) usize {
    std.debug.assert(index < group_count);
    return groups_offset + @as(usize, index) * group_entry_size;
}

fn readRange(index: u32) Range {
    std.debug.assert(index < range_count);
    const offset = ranges_offset + @as(usize, index) * range_entry_size;
    return .{ .lo = readU32(offset), .hi = readU32(offset + 4) };
}

fn readU16(offset: usize) u16 {
    const pointer: *align(1) const u16 = @ptrCast(bytes.ptr + offset);
    return std.mem.littleToNative(u16, pointer.*);
}

fn readU32(offset: usize) u32 {
    const pointer: *align(1) const u32 = @ptrCast(bytes.ptr + offset);
    return std.mem.littleToNative(u32, pointer.*);
}

const testing = std.testing;

test "Group names and ranges are sorted and normalized" {
    var group_index: u32 = 0;
    while (group_index < group_count) : (group_index += 1) {
        const group = Group{ .index = group_index };
        if (group_index > 0) {
            try testing.expect(std.mem.order(
                u8,
                (Group{ .index = group_index - 1 }).name(),
                group.name(),
            ) == .lt);
        }
        var previous: ?Range = null;
        var range_index: u32 = 0;
        while (range_index < group.rangeCount()) : (range_index += 1) {
            const range = group.rangeAt(range_index);
            try testing.expect(range.isValid());
            if (previous) |prior| try testing.expect(prior.hi + 1 < range.lo);
            previous = range;
        }
    }
}

test "Lookup accepts exact project names and rejects UCD aliases" {
    const letters = findGroup("L").?;
    try testing.expect(letters.contains('A'));
    try testing.expect(letters.contains(0x212a));
    try testing.expect(findGroup("Latin") != null);
    try testing.expect(findGroup("Any").?.contains(rune_range.max_rune));

    try testing.expect(findGroup("Letter") == null);
    try testing.expect(findGroup("Latn") == null);
    try testing.expect(findGroup("sc=Latin") == null);
    try testing.expect(findGroup("latin") == null);
}

test "Surrogate category remains available as Unicode source metadata" {
    const surrogates = findGroup("Cs").?;
    try testing.expect(surrogates.contains(0xd800));
    try testing.expect(surrogates.contains(0xdfff));
    try testing.expect(!surrogates.contains(0xe000));
    try testing.expect(findGroup("C").?.contains(0xd800));
}

test "Unicode version exposes current scripts and folds" {
    try testing.expectEqualStrings("17.0.0", version);
    const beria = findGroup("Beria_Erfe").?;
    try testing.expect(beria.contains(0x16ea0));
    try testing.expect(beria.contains(0x16ebb));
    try testing.expectEqual(@as(Rune, 0x16ebb), toLower(0x16ea0));
}

test "Simple fold cycles match Kelvin sign and long s groups" {
    try testing.expectEqual(@as(Rune, 'k'), foldNext('K'));
    try testing.expectEqual(@as(Rune, 0x212a), foldNext('k'));
    try testing.expectEqual(@as(Rune, 'K'), foldNext(0x212a));
    try testing.expectEqual(@as(Rune, 's'), foldNext('S'));
    try testing.expectEqual(@as(Rune, 0x17f), foldNext('s'));
    try testing.expectEqual(@as(Rune, 'S'), foldNext(0x17f));
    try testing.expectEqual(@as(Rune, '!'), foldNext('!'));
}

test "Prefilter lowercase maps every simple fold member canonically" {
    try testing.expectEqual(@as(Rune, 'k'), toLower('K'));
    try testing.expectEqual(@as(Rune, 'k'), toLower(0x212a));
    try testing.expectEqual(@as(Rune, 0x3c0), toLower(0x3a0));
    try testing.expectEqual(@as(Rune, 0x3c0), toLower(0x3d6));
    try testing.expectEqual(@as(Rune, 0x3c3), toLower(0x3a3));
    try testing.expectEqual(@as(Rune, 0x3c3), toLower(0x3c2));
    try testing.expectEqual(@as(Rune, '!'), toLower('!'));
}

test "Fold mapping is sorted unique and closed in four steps" {
    var index: u32 = 0;
    while (index < fold_count) : (index += 1) {
        const pair = foldPair(index);
        if (index > 0) try testing.expect(foldPair(index - 1).from < pair.from);
        var current = pair.from;
        var steps: usize = 0;
        while (true) {
            current = foldNext(current);
            steps += 1;
            if (current == pair.from) break;
            try testing.expect(steps < 5);
        }
    }
}
