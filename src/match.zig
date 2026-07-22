//! Engine-independent matching vocabulary and result ownership.
//!
//! All positions are absolute byte offsets into the complete input. This remains
//! true in UTF-8 mode: decoding determines which byte sequences may be consumed,
//! but it never changes the coordinate system. Ranges are half-open `[start,end)`
//! so empty matches have `start == end` and adjacent matches compose naturally.
//!
//! The module distinguishes borrowed and owned observations:
//!
//! - `Match` and `SearchRange` are plain values;
//! - `CaptureView` borrows Matcher slot storage and is invalidated by reuse;
//! - `Captures`, `Matches`, and `PossibleMatchRange` own copied allocations.
//!
//! Capture slots use two optional offsets per group: begin then end. Group zero
//! is the whole match. A group that did not participate has absent offsets rather
//! than an empty range; an empty participating group has equal present offsets.
//!
//! These types do not import a project module. That dependency rule prevents a
//! public semantic concept from becoming coupled to NFA, DFA, or capture-engine
//! representation.

const std = @import("std");

/// Unanchored search or search anchored at the requested range start.
pub const Anchor = enum { unanchored, start };

/// Leftmost-first or leftmost-longest result selection.
pub const MatchKind = enum { first, longest };

/// Half-open absolute byte offsets into the complete input.
pub const Match = struct {
    start: usize,
    end: usize,

    /// Returns the represented bytes, or null for invalid bounds.
    pub fn slice(self: Match, input: []const u8) ?[]const u8 {
        if (self.start > self.end or self.end > input.len) return null;
        return input[self.start..self.end];
    }
};

/// Slot view invalidated by the next operation on its Matcher or Matcher teardown.
pub const CaptureView = struct {
    slots: []const ?usize,

    /// Returns group zero (whole match) or an explicit group; null means
    /// unmatched, out of range, or an invalid manually constructed slot pair.
    pub fn group(self: CaptureView, index: usize) ?Match {
        const slot = std.math.mul(usize, index, 2) catch return null;
        if (slot + 1 >= self.slots.len) return null;
        const start = self.slots[slot] orelse return null;
        const end = self.slots[slot + 1] orelse return null;
        if (end < start) return null;
        return .{ .start = start, .end = end };
    }

    /// Copies all slots into an independent result.
    pub fn copy(self: CaptureView, allocator: std.mem.Allocator) !Captures {
        return .{
            .allocator = allocator,
            .slots = try allocator.dupe(?usize, self.slots),
        };
    }
};

/// Capture slots copied from matcher scratch and valid independently of Matcher
/// and Regex teardown.
pub const Captures = struct {
    allocator: std.mem.Allocator,
    slots: []?usize,

    pub fn view(self: *const Captures) CaptureView {
        return .{ .slots = self.slots };
    }

    /// Uses the same group-zero convention as CaptureView.
    pub fn group(self: *const Captures, index: usize) ?Match {
        return self.view().group(index);
    }

    /// Releases the slot copy.
    pub fn deinit(self: *Captures) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }
};

pub const CollectionError = error{ OutOfMemory, ResultLimitExceeded };

/// Half-open absolute search range. A null end means `input.len`.
pub const SearchRange = struct {
    start: usize = 0,
    end: ?usize = null,
};

/// Owned lexical limits for anchored full matches.
pub const PossibleMatchRange = struct {
    allocator: std.mem.Allocator,
    minimum: []u8,
    maximum: []u8,

    pub fn deinit(self: *PossibleMatchRange) void {
        self.allocator.free(self.minimum);
        self.allocator.free(self.maximum);
        self.* = undefined;
    }
};

/// Static-analysis outcome: an owned finite bound, a proven empty language, or
/// a language whose maximum cannot be represented by any finite byte string.
pub const PossibleMatchResult = union(enum) {
    range: PossibleMatchRange,
    empty_language,
    no_finite_max,
};

/// Stored non-overlapping ranges independent of engine and input bytes.
pub const Matches = struct {
    allocator: std.mem.Allocator,
    items: []Match,

    pub fn values(self: *const Matches) []const Match {
        return self.items;
    }

    pub fn deinit(self: *Matches) void {
        if (self.items.len != 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};
