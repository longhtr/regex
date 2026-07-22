//! Mutable character-class construction over normalized rune intervals.
//!
//! Parser terms arrive as literals, ranges, or named-class range sets. Builder
//! maintains one normalized union, using reusable temporary arrays for range
//! algebra. The semantic finishing order matters:
//!
//! 1. union all positive source terms;
//! 2. close the set under Unicode simple-fold cycles when case-insensitive;
//! 3. complement over the engine rune universe when the class is negated;
//! 4. remove newline when the never-newline option is active;
//! 5. transfer one normalized owned slice into the syntax arena.
//!
//! Folding before negation ensures a negated folded class excludes every member
//! of an equivalence cycle. The builder uses Unicode metadata ranges, including
//! surrogate categories; encoding-specific clipping/scalar removal happens at
//! the parser/lowering boundary. All intermediate ownership remains explicit.

const std = @import("std");
const unicode = @import("../unicode/data.zig");
const rune_range = @import("rune_range.zig");

pub const Rune = rune_range.Rune;
pub const Range = rune_range.Range;

/// Owned normalized class range slice transferred out of Builder.
pub const Class = struct {
    ranges: []Range,

    pub fn contains(self: *const Class, rune: Rune) bool {
        return rune_range.contains(self.ranges, rune);
    }

    pub fn deinit(self: *Class, allocator: std.mem.Allocator) void {
        allocator.free(self.ranges);
        self.* = undefined;
    }
};

/// Mutable range union whose additions may remain unnormalized until algebra or
/// publication requires canonical order. Fold, complement, and subtraction
/// replace storage transactionally; `finish` normalizes and transfers exactly
/// one Class owner.
pub const Builder = struct {
    ranges: std.ArrayList(Range) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
        self.* = undefined;
    }

    pub fn addRange(
        self: *Builder,
        allocator: std.mem.Allocator,
        range: Range,
    ) (error{InvalidRuneRange} || std.mem.Allocator.Error)!void {
        if (!range.isValid()) return error.InvalidRuneRange;
        try self.ranges.append(allocator, range);
    }

    /// Adds a source interval and every rune reachable through simple-fold
    /// cycles from its members.
    pub fn addFoldedRange(
        self: *Builder,
        allocator: std.mem.Allocator,
        range: Range,
    ) (error{InvalidRuneRange} || std.mem.Allocator.Error)!void {
        try self.addRange(allocator, range);

        var index = unicode.foldLowerBound(range.lo);
        while (index < unicode.foldCount() and unicode.foldPair(index).from <= range.hi) : (index += 1) {
            const start = unicode.foldPair(index).from;
            var current = unicode.foldNext(start);
            var steps: usize = 0;
            while (current != start) : (current = unicode.foldNext(current)) {
                try self.addRange(allocator, .{ .lo = current, .hi = current });
                steps += 1;
                std.debug.assert(steps < 5);
            }
        }
    }

    /// Adds all ranges in a Unicode group, optionally through fold closure.
    pub fn addGroup(
        self: *Builder,
        allocator: std.mem.Allocator,
        group: unicode.Group,
        fold: bool,
    ) (error{InvalidRuneRange} || std.mem.Allocator.Error)!void {
        var index: u32 = 0;
        while (index < group.rangeCount()) : (index += 1) {
            const range = group.rangeAt(index);
            if (fold) {
                try self.addFoldedRange(allocator, range);
            } else {
                try self.addRange(allocator, range);
            }
        }
    }

    /// Canonicalizes the accumulated union in place and discards merged suffix
    /// capacity from the logical slice.
    pub fn normalize(self: *Builder) error{InvalidRuneRange}!void {
        const length = try rune_range.normalize(self.ranges.items);
        self.ranges.items.len = length;
    }

    /// Subtracts one inclusive interval by intersecting with its complement.
    /// The source is normalized first; at most two inverse intervals feed a
    /// separately owned result, which replaces current storage only after the
    /// complete intersection succeeds.
    pub fn removeRange(
        self: *Builder,
        allocator: std.mem.Allocator,
        removed: Range,
    ) (error{ InvalidRuneRange, InvalidInput } || std.mem.Allocator.Error)!void {
        if (!removed.isValid()) return error.InvalidRuneRange;
        try self.normalize();

        var inverse_storage: [2]Range = undefined;
        const inverse_length = rune_range.complement(&.{removed}, &inverse_storage) catch |err| switch (err) {
            error.InvalidInput => unreachable,
            error.NoSpace => unreachable,
        };
        var result: std.ArrayList(Range) = .empty;
        errdefer result.deinit(allocator);
        try result.resize(allocator, self.ranges.items.len + inverse_length);
        const length = rune_range.intersect(
            self.ranges.items,
            inverse_storage[0..inverse_length],
            result.items,
        ) catch |err| switch (err) {
            error.InvalidInput => return error.InvalidInput,
            error.NoSpace => unreachable,
        };
        result.items.len = length;

        self.ranges.deinit(allocator);
        self.ranges = result;
    }

    /// Complements the current class over U+0000..U+10FFFF, including
    /// surrogate category metadata; UTF-8 lowering excludes non-scalars.
    pub fn negate(
        self: *Builder,
        allocator: std.mem.Allocator,
    ) (error{ InvalidRuneRange, InvalidInput } || std.mem.Allocator.Error)!void {
        try self.normalize();

        var result: std.ArrayList(Range) = .empty;
        errdefer result.deinit(allocator);
        try result.resize(allocator, self.ranges.items.len + 1);
        const length = rune_range.complement(self.ranges.items, result.items) catch |err| switch (err) {
            error.InvalidInput => return error.InvalidInput,
            error.NoSpace => unreachable,
        };
        result.items.len = length;

        self.ranges.deinit(allocator);
        self.ranges = result;
    }

    /// Normalizes and transfers the owned range slice, leaving Builder empty and
    /// reusable/deinitializable.
    pub fn finish(
        self: *Builder,
        allocator: std.mem.Allocator,
    ) (error{InvalidRuneRange} || std.mem.Allocator.Error)!Class {
        try self.normalize();
        const ranges = try self.ranges.toOwnedSlice(allocator);
        self.* = .{};
        return .{ .ranges = ranges };
    }
};

const testing = std.testing;

test "The engine CharClassBuilder Adds table" {
    const M = rune_range.max_rune;
    const Case = struct { adds: []const Range, remove_above: ?u32 = null, expected: []const Range };
    const cases = [_]Case{
        .{ .adds = &.{.{ .lo = 10, .hi = 20 }}, .expected = &.{.{ .lo = 10, .hi = 20 }} },
        .{ .adds = &.{ .{ .lo = 10, .hi = 20 }, .{ .lo = 20, .hi = 30 } }, .expected = &.{.{ .lo = 10, .hi = 30 }} },
        .{ .adds = &.{ .{ .lo = 10, .hi = 20 }, .{ .lo = 30, .hi = 40 }, .{ .lo = 20, .hi = 30 } }, .expected = &.{.{ .lo = 10, .hi = 40 }} },
        .{ .adds = &.{ .{ .lo = 0, .hi = 50 }, .{ .lo = 20, .hi = 30 } }, .expected = &.{.{ .lo = 0, .hi = 50 }} },
        .{ .adds = &.{ .{ .lo = 10, .hi = 11 }, .{ .lo = 13, .hi = 14 }, .{ .lo = 16, .hi = 17 }, .{ .lo = 19, .hi = 20 }, .{ .lo = 22, .hi = 23 } }, .expected = &.{ .{ .lo = 10, .hi = 11 }, .{ .lo = 13, .hi = 14 }, .{ .lo = 16, .hi = 17 }, .{ .lo = 19, .hi = 20 }, .{ .lo = 22, .hi = 23 } } },
        .{ .adds = &.{ .{ .lo = 13, .hi = 14 }, .{ .lo = 10, .hi = 11 }, .{ .lo = 22, .hi = 23 }, .{ .lo = 19, .hi = 20 }, .{ .lo = 16, .hi = 17 }, .{ .lo = 5, .hi = 25 } }, .expected = &.{.{ .lo = 5, .hi = 25 }} },
        .{ .adds = &.{ .{ .lo = 13, .hi = 14 }, .{ .lo = 10, .hi = 11 }, .{ .lo = 22, .hi = 23 }, .{ .lo = 19, .hi = 20 }, .{ .lo = 16, .hi = 17 }, .{ .lo = 12, .hi = 21 } }, .expected = &.{.{ .lo = 10, .hi = 23 }} },
        .{ .adds = &.{.{ .lo = 0, .hi = M }}, .expected = &.{.{ .lo = 0, .hi = M }} },
        .{ .adds = &.{.{ .lo = 0, .hi = 50 }}, .expected = &.{.{ .lo = 0, .hi = 50 }} },
        .{ .adds = &.{.{ .lo = 50, .hi = M }}, .expected = &.{.{ .lo = 50, .hi = M }} },
        .{ .adds = &.{.{ .lo = 50, .hi = M }}, .remove_above = 255, .expected = &.{.{ .lo = 50, .hi = 255 }} },
        .{ .adds = &.{.{ .lo = 50, .hi = M }}, .remove_above = 65535, .expected = &.{.{ .lo = 50, .hi = 65535 }} },
        .{ .adds = &.{.{ .lo = 50, .hi = M }}, .remove_above = M, .expected = &.{.{ .lo = 50, .hi = M }} },
        .{ .adds = &.{ .{ .lo = 50, .hi = 60 }, .{ .lo = 250, .hi = 260 }, .{ .lo = 350, .hi = 360 } }, .remove_above = 255, .expected = &.{ .{ .lo = 50, .hi = 60 }, .{ .lo = 250, .hi = 255 } } },
        .{ .adds = &.{.{ .lo = 50, .hi = 60 }}, .remove_above = 255, .expected = &.{.{ .lo = 50, .hi = 60 }} },
        .{ .adds = &.{.{ .lo = 350, .hi = 360 }}, .remove_above = 255, .expected = &.{} },
        .{ .adds = &.{}, .remove_above = 255, .expected = &.{} },
    };
    for (cases) |case| {
        var builder: Builder = .{};
        defer builder.deinit(testing.allocator);
        for (case.adds) |range| try builder.addRange(testing.allocator, range);
        if (case.remove_above) |limit| {
            if (limit < M) try builder.removeRange(testing.allocator, .{ .lo = limit + 1, .hi = M });
        }
        try builder.normalize();
        try testing.expectEqualSlices(Range, case.expected, builder.ranges.items);
        try builder.negate(testing.allocator);
        var negated = try builder.finish(testing.allocator);
        defer negated.deinit(testing.allocator);
        for ([_]u32{ 0, 10, 50, 100, M }) |rune|
            try testing.expect(rune_range.contains(case.expected, rune) != negated.contains(rune));
    }
}

test "Builder finish publishes normalized ranges" {
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addRange(testing.allocator, .{ .lo = 20, .hi = 30 });
    try builder.addRange(testing.allocator, .{ .lo = 1, .hi = 19 });

    var class = try builder.finish(testing.allocator);
    defer class.deinit(testing.allocator);
    try testing.expectEqualSlices(Range, &.{.{ .lo = 1, .hi = 30 }}, class.ranges);
}

test "Fold closure includes all members of multi-rune groups" {
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addFoldedRange(testing.allocator, .{ .lo = 'K', .hi = 'K' });
    try builder.normalize();
    try testing.expect(rune_range.contains(builder.ranges.items, 'K'));
    try testing.expect(rune_range.contains(builder.ranges.items, 'k'));
    try testing.expect(rune_range.contains(builder.ranges.items, 0x212a));
}

test "ASCII folded range includes Kelvin sign and long s" {
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addFoldedRange(testing.allocator, .{ .lo = 'A', .hi = 'Z' });
    try builder.normalize();
    const class = Class{ .ranges = builder.ranges.items };
    try testing.expect(class.contains('a'));
    try testing.expect(class.contains(0x212a));
    try testing.expect(class.contains(0x17f));
}

test "Fold before negation excludes complete equivalence group" {
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addFoldedRange(testing.allocator, .{ .lo = 'K', .hi = 'K' });
    try builder.negate(testing.allocator);
    const class = Class{ .ranges = builder.ranges.items };
    try testing.expect(!class.contains('K'));
    try testing.expect(!class.contains('k'));
    try testing.expect(!class.contains(0x212a));
    try testing.expect(class.contains('x'));
    try testing.expect(class.contains(0xd800));
}

test "RemoveRange applies NeverNL-style exclusion" {
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addRange(testing.allocator, rune_range.rune_universe);
    try builder.removeRange(testing.allocator, .{ .lo = '\n', .hi = '\n' });
    const class = Class{ .ranges = builder.ranges.items };
    try testing.expect(!class.contains('\n'));
    try testing.expect(class.contains('\r'));
    try testing.expect(class.contains(0xd800));
}

test "Unicode Cs source group retains surrogate metadata" {
    var builder: Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.addGroup(testing.allocator, unicode.findGroup("Cs").?, false);
    try builder.normalize();
    const class = Class{ .ranges = builder.ranges.items };
    try testing.expect(class.contains(0xd800));
    try testing.expect(class.contains(0xdfff));
}
