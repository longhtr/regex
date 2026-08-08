//! Checked arithmetic for user-influenced allocation and admission sizes.
//!
//! Regex structure and input lengths are repeatedly multiplied into queue,
//! bitmap, cache, and work estimates. Ordinary wrapping arithmetic could turn an
//! oversized request into a small allocation or admit work beyond policy. These
//! helpers make overflow an explicit `Overflow` result; `fits` folds overflow into
//! “does not fit” without ever comparing a wrapped sum.
//!
//! `alignForward` requires a power-of-two alignment and checks the pre-alignment
//! addition. The module intentionally stays outside matching hot loops: callers
//! use it while planning storage or admitting a request, then execute with already
//! validated dimensions.

const std = @import("std");

pub const Error = error{Overflow};

pub fn add(left: usize, right: usize) Error!usize {
    return std.math.add(usize, left, right) catch error.Overflow;
}

pub fn mul(left: usize, right: usize) Error!usize {
    return std.math.mul(usize, left, right) catch error.Overflow;
}

pub fn alignForward(value: usize, alignment: usize) Error!usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = alignment - 1;
    return (try add(value, mask)) & ~mask;
}

pub fn fits(limit: usize, current: usize, addition: usize) bool {
    const next = add(current, addition) catch return false;
    return next <= limit;
}

const testing = std.testing;

test "Checked size arithmetic rejects every maximum boundary overflow" {
    const maximum = std.math.maxInt(usize);
    try testing.expectEqual(maximum, try add(maximum - 1, 1));
    try testing.expectError(error.Overflow, add(maximum, 1));
    try testing.expectEqual(maximum - 1, try mul(maximum / 2, 2));
    try testing.expectError(error.Overflow, mul(maximum / 2 + 1, 2));
    try testing.expectEqual(@as(usize, 16), try alignForward(9, 8));
    try testing.expectError(error.Overflow, alignForward(maximum, 8));
    try testing.expect(fits(maximum, maximum - 1, 1));
    try testing.expect(!fits(maximum, maximum, 1));
}
