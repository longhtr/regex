//! Expansion of named Perl, POSIX, and Unicode class terms.
//!
//! This module is intentionally a table/lookup layer, not a bracket-expression
//! parser. Given a recognized name, it contributes the exact positive ranges to
//! `char_class.Builder`; the caller controls term negation and whole-class
//! negation independently.
//!
//! Perl `d/s/w` and POSIX named classes have project-defined ASCII ranges.
//! Unicode names are exact, case-sensitive lookups in `unicode/data.zig`; aliases
//! and property-assignment syntax are not inferred. Folding is delegated to the
//! class builder so all term kinds receive the same closure semantics.
//!
//! Cursor movement, encoding clipping, syntax-mode availability, and conversion
//! of `UnknownClass` into a source-span diagnostic remain in `parser.zig`.

const std = @import("std");
const char_class = @import("char_class.zig");
const rune_range = @import("rune_range.zig");
const unicode = @import("../unicode/data.zig");

pub const Error = error{ OutOfMemory, UnknownClass };

/// Expands the lowercase identity of one supported Perl shorthand into its base
/// ASCII ranges; caller handles uppercase negation.
pub fn addPerl(
    allocator: std.mem.Allocator,
    builder: *char_class.Builder,
    code: u8,
    fold: bool,
) error{OutOfMemory}!void {
    switch (std.ascii.toLower(code)) {
        'd' => try addRange(allocator, builder, .{ .lo = '0', .hi = '9' }, false, fold),
        's' => {
            try addRange(allocator, builder, .{ .lo = 0x09, .hi = 0x0a }, false, fold);
            try addRange(allocator, builder, .{ .lo = 0x0c, .hi = 0x0d }, false, fold);
            try addRange(allocator, builder, .{ .lo = 0x20, .hi = 0x20 }, false, fold);
        },
        'w' => {
            try addRange(allocator, builder, .{ .lo = '0', .hi = '9' }, false, fold);
            try addRange(allocator, builder, .{ .lo = 'A', .hi = 'Z' }, true, fold);
            try addRange(allocator, builder, .{ .lo = '_', .hi = '_' }, false, fold);
            try addRange(allocator, builder, .{ .lo = 'a', .hi = 'z' }, true, fold);
        },
        else => unreachable,
    }
}

/// Looks up one exact generated Unicode group and unions its ranges with optional
/// simple-fold closure.
pub fn addUnicode(
    allocator: std.mem.Allocator,
    builder: *char_class.Builder,
    name: []const u8,
    fold: bool,
) Error!void {
    const group = unicode.findGroup(name) orelse return error.UnknownClass;
    builder.addGroup(allocator, group, fold) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRuneRange => unreachable,
    };
}

/// Expands one exact POSIX class name to its ASCII definition, returning
/// `UnknownClass` for unsupported names.
pub fn addPosix(
    allocator: std.mem.Allocator,
    builder: *char_class.Builder,
    name: []const u8,
    fold: bool,
) Error!void {
    if (std.mem.eql(u8, name, "alnum")) {
        try addRange(allocator, builder, .{ .lo = '0', .hi = '9' }, false, fold);
        try addAsciiLetters(allocator, builder, fold);
    } else if (std.mem.eql(u8, name, "alpha")) {
        try addAsciiLetters(allocator, builder, fold);
    } else if (std.mem.eql(u8, name, "ascii")) {
        try addRange(allocator, builder, .{ .lo = 0, .hi = 0x7f }, false, fold);
    } else if (std.mem.eql(u8, name, "blank")) {
        try addRange(allocator, builder, .{ .lo = '\t', .hi = '\t' }, false, fold);
        try addRange(allocator, builder, .{ .lo = ' ', .hi = ' ' }, false, fold);
    } else if (std.mem.eql(u8, name, "cntrl")) {
        try addRange(allocator, builder, .{ .lo = 0, .hi = 0x1f }, false, fold);
        try addRange(allocator, builder, .{ .lo = 0x7f, .hi = 0x7f }, false, fold);
    } else if (std.mem.eql(u8, name, "digit")) {
        try addRange(allocator, builder, .{ .lo = '0', .hi = '9' }, false, fold);
    } else if (std.mem.eql(u8, name, "graph")) {
        try addRange(allocator, builder, .{ .lo = 0x21, .hi = 0x7e }, false, fold);
    } else if (std.mem.eql(u8, name, "lower")) {
        try addRange(allocator, builder, .{ .lo = 'a', .hi = 'z' }, true, fold);
    } else if (std.mem.eql(u8, name, "print")) {
        try addRange(allocator, builder, .{ .lo = 0x20, .hi = 0x7e }, false, fold);
    } else if (std.mem.eql(u8, name, "punct")) {
        for ([_]rune_range.Range{
            .{ .lo = 0x21, .hi = 0x2f }, .{ .lo = 0x3a, .hi = 0x40 },
            .{ .lo = 0x5b, .hi = 0x60 }, .{ .lo = 0x7b, .hi = 0x7e },
        }) |range| try addRange(allocator, builder, range, false, fold);
    } else if (std.mem.eql(u8, name, "space")) {
        try addRange(allocator, builder, .{ .lo = 0x09, .hi = 0x0d }, false, fold);
        try addRange(allocator, builder, .{ .lo = 0x20, .hi = 0x20 }, false, fold);
    } else if (std.mem.eql(u8, name, "upper")) {
        try addRange(allocator, builder, .{ .lo = 'A', .hi = 'Z' }, true, fold);
    } else if (std.mem.eql(u8, name, "word")) {
        try addPerl(allocator, builder, 'w', fold);
    } else if (std.mem.eql(u8, name, "xdigit")) {
        try addRange(allocator, builder, .{ .lo = '0', .hi = '9' }, false, fold);
        try addRange(allocator, builder, .{ .lo = 'A', .hi = 'F' }, true, fold);
        try addRange(allocator, builder, .{ .lo = 'a', .hi = 'f' }, true, fold);
    } else {
        return error.UnknownClass;
    }
}

fn addAsciiLetters(
    allocator: std.mem.Allocator,
    builder: *char_class.Builder,
    fold: bool,
) error{OutOfMemory}!void {
    try addRange(allocator, builder, .{ .lo = 'A', .hi = 'Z' }, true, fold);
    try addRange(allocator, builder, .{ .lo = 'a', .hi = 'z' }, true, fold);
}

fn addRange(
    allocator: std.mem.Allocator,
    builder: *char_class.Builder,
    range: rune_range.Range,
    foldable: bool,
    fold: bool,
) error{OutOfMemory}!void {
    if (foldable and fold) {
        builder.addFoldedRange(allocator, range) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRuneRange => unreachable,
        };
    } else {
        builder.addRange(allocator, range) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRuneRange => unreachable,
        };
    }
}

const testing = std.testing;

test "Named class terms own exact positive definitions" {
    var word: char_class.Builder = .{};
    defer word.deinit(testing.allocator);
    try addPosix(testing.allocator, &word, "word", false);
    try word.normalize();
    try testing.expect(rune_range.contains(word.ranges.items, '0'));
    try testing.expect(rune_range.contains(word.ranges.items, 'A'));
    try testing.expect(rune_range.contains(word.ranges.items, '_'));
    try testing.expect(!rune_range.contains(word.ranges.items, '-'));
    try testing.expectError(error.UnknownClass, addPosix(
        testing.allocator,
        &word,
        "not-a-class",
        false,
    ));
}
