//! Allocation-free Program descriptors for proven repeated-byte fast paths.
//!
//! `Plans` is a compact optional record rather than a tagged executor choice.
//! A zero range count means no direct plan. Otherwise ranges, bounds, prefix
//! placement, optional leading ranges, and word-boundary flags jointly describe
//! one language proved by `shapes.zig` and consumed by
//! `../engine/accelerate/count.zig`.
//!
//! Validation checks internal field consistency and agreement with the Program's
//! required prefix. Plans own no memory and require no teardown. They are hints
//! only: canonical priority lists still encode the complete expression.

const std = @import("std");

pub const max_repeat_byte_ranges = 4;

/// Optional execution facts embedded by value in Program. Byte ranges encode
/// inclusive endpoints as `lo | hi << 8`; only entries below each count are
/// active. `bit_state_root_count` is independent capture-bitmap metadata.
pub const Plans = struct {
    bit_state_root_count: u32 = 0,
    repeat_byte_ranges: [max_repeat_byte_ranges]u16 = @splat(0),
    repeat_byte_range_count: u8 = 0,
    repeat_byte_initial_ranges: [max_repeat_byte_ranges]u16 = @splat(0),
    repeat_byte_initial_range_count: u8 = 0,
    repeat_byte_min: u32 = 0,
    repeat_byte_max: u32 = 0,
    repeat_byte_after_prefix: bool = false,
    repeat_byte_left_word_boundary: bool = false,
    repeat_byte_right_word_boundary: bool = false,

    /// Rejects partial descriptors, inverted ranges/bounds, and an
    /// `after_prefix` plan without an exact case-sensitive prefix.
    pub fn validate(
        self: *const Plans,
        prefix: []const u8,
        prefix_fold_ascii: bool,
    ) error{InvalidProgram}!void {
        if (self.repeat_byte_range_count > self.repeat_byte_ranges.len or
            self.repeat_byte_initial_range_count > self.repeat_byte_initial_ranges.len or
            (self.repeat_byte_range_count == 0 and
                (self.repeat_byte_min != 0 or self.repeat_byte_max != 0 or
                    self.repeat_byte_after_prefix)) or
            (self.repeat_byte_range_count != 0 and
                (self.repeat_byte_min == 0 or
                    (self.repeat_byte_max != 0 and
                        self.repeat_byte_max < self.repeat_byte_min) or
                    (self.repeat_byte_after_prefix and
                        (prefix.len == 0 or prefix_fold_ascii)))))
            return error.InvalidProgram;

        for (self.repeat_byte_ranges[0..self.repeat_byte_range_count]) |encoded| {
            if (@as(u8, @truncate(encoded)) > @as(u8, @truncate(encoded >> 8)))
                return error.InvalidProgram;
        }
        for (self.repeat_byte_initial_ranges[0..self.repeat_byte_initial_range_count]) |encoded| {
            if (@as(u8, @truncate(encoded)) > @as(u8, @truncate(encoded >> 8)))
                return error.InvalidProgram;
        }
    }
};
