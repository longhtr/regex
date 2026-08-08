//! Canonical rune-to-byte sequence primitives used by lowering and analysis.
//!
//! `ByteSequence` describes up to four byte intervals, not merely one encoded
//! literal. Exact encoding produces singleton intervals; `broadUtf8Sequences`
//! describes the valid leading/continuation envelopes partitioned at surrogate
//! and maximum-scalar boundaries.
//!
//! Helpers expose UTF-8 length and maximum rune per length so range lowering can
//! split by structural boundaries before deriving byte intervals. Latin-1 does
//! not need a separate encoder: a valid rune is one singleton byte.
//!
//! This module performs no allocation and builds no graph. It is intentionally
//! shared by compiler lowering, prefix/suffix facts, Filtered normalization, and
//! tests so all byte representations agree.

const std = @import("std");
const rune_range = @import("../syntax/rune_range.zig");

pub const Encoding = enum { utf8, latin1 };

/// Inclusive interval accepted at one byte position.
pub const ByteRange = struct { lo: u8, hi: u8 };

/// One canonical UTF-8 envelope. Only `ranges[0..len]` are meaningful.
pub const ByteSequence = struct {
    ranges: [4]ByteRange = undefined,
    len: u3,
};

/// Returns the canonical UTF-8 width of a valid engine rune. Structural range
/// splitting uses this before any bytes are emitted.
pub fn utf8Length(rune: u32) u3 {
    if (rune <= 0x7f) return 1;
    if (rune <= 0x7ff) return 2;
    if (rune <= 0xffff) return 3;
    return 4;
}

/// Returns the final scalar in one UTF-8 width band, letting range lowering
/// split an interval before deriving rectangular byte envelopes.
pub fn maxRuneForLength(length: u3) u32 {
    return switch (length) {
        1 => 0x7f,
        2 => 0x7ff,
        3 => 0xffff,
        4 => rune_range.max_rune,
        else => unreachable,
    };
}

/// Encodes one rune as singleton byte intervals. This low-level helper assumes
/// the caller has excluded surrogates when scalar validity matters.
pub fn encodeRune(rune: u32) ByteSequence {
    std.debug.assert(rune <= rune_range.max_rune);
    var result = ByteSequence{ .len = utf8Length(rune) };
    switch (result.len) {
        1 => result.ranges[0] = singleton(@intCast(rune)),
        2 => {
            result.ranges[0] = singleton(@intCast(0xc0 | (rune >> 6)));
            result.ranges[1] = singleton(@intCast(0x80 | (rune & 0x3f)));
        },
        3 => {
            result.ranges[0] = singleton(@intCast(0xe0 | (rune >> 12)));
            result.ranges[1] = singleton(@intCast(0x80 | ((rune >> 6) & 0x3f)));
            result.ranges[2] = singleton(@intCast(0x80 | (rune & 0x3f)));
        },
        4 => {
            result.ranges[0] = singleton(@intCast(0xf0 | (rune >> 18)));
            result.ranges[1] = singleton(@intCast(0x80 | ((rune >> 12) & 0x3f)));
            result.ranges[2] = singleton(@intCast(0x80 | ((rune >> 6) & 0x3f)));
            result.ranges[3] = singleton(@intCast(0x80 | (rune & 0x3f)));
        },
        else => unreachable,
    }
    return result;
}

/// Lifts one exact byte into the interval representation shared with broad
/// UTF-8 envelopes.
pub fn singleton(byte: u8) ByteRange {
    return .{ .lo = byte, .hi = byte };
}

/// Returns a disjoint cover of all canonical UTF-8 scalar encodings. Separate
/// envelopes encode special second-byte limits for E0, ED, F0, and F4.
pub fn broadUtf8Sequences() [8]ByteSequence {
    return .{
        .{ .len = 2, .ranges = .{
            .{ .lo = 0xc2, .hi = 0xdf }, .{ .lo = 0x80, .hi = 0xbf },
            undefined,                   undefined,
        } },
        .{ .len = 3, .ranges = .{
            .{ .lo = 0xe0, .hi = 0xe0 }, .{ .lo = 0xa0, .hi = 0xbf },
            .{ .lo = 0x80, .hi = 0xbf }, undefined,
        } },
        .{ .len = 3, .ranges = .{
            .{ .lo = 0xe1, .hi = 0xec }, .{ .lo = 0x80, .hi = 0xbf },
            .{ .lo = 0x80, .hi = 0xbf }, undefined,
        } },
        .{ .len = 3, .ranges = .{
            .{ .lo = 0xed, .hi = 0xed }, .{ .lo = 0x80, .hi = 0x9f },
            .{ .lo = 0x80, .hi = 0xbf }, undefined,
        } },
        .{ .len = 3, .ranges = .{
            .{ .lo = 0xee, .hi = 0xef }, .{ .lo = 0x80, .hi = 0xbf },
            .{ .lo = 0x80, .hi = 0xbf }, undefined,
        } },
        .{ .len = 4, .ranges = .{
            .{ .lo = 0xf0, .hi = 0xf0 }, .{ .lo = 0x90, .hi = 0xbf },
            .{ .lo = 0x80, .hi = 0xbf }, .{ .lo = 0x80, .hi = 0xbf },
        } },
        .{ .len = 4, .ranges = .{
            .{ .lo = 0xf1, .hi = 0xf3 }, .{ .lo = 0x80, .hi = 0xbf },
            .{ .lo = 0x80, .hi = 0xbf }, .{ .lo = 0x80, .hi = 0xbf },
        } },
        .{ .len = 4, .ranges = .{
            .{ .lo = 0xf4, .hi = 0xf4 }, .{ .lo = 0x80, .hi = 0x8f },
            .{ .lo = 0x80, .hi = 0xbf }, .{ .lo = 0x80, .hi = 0xbf },
        } },
    };
}
