//! Bounded depth-first capture execution with `(root, position)` visitation bits.
//!
//! BitState explores preferred paths depth-first rather than carrying a capture
//! row per NFA thread. One mutable slot array holds the current path. Capture
//! writes append `Undo` records; an alternative `Job` stores the undo checkpoint
//! needed to restore that path before exploring the branch.
//!
//! A bitmap admits a Program root at an input position only once. Publication
//! maps roots with a unique predecessor to no row because revisiting them cannot
//! introduce an independent path; `fillBitStateRootMap` assigns dense rows only
//! where needed. Direct unanchored search uses the full root product, while exact
//! replay can use the compressed map.
//!
//! Job and undo records have compact/narrow/wide physical layouts selected from
//! Program/input domains, but expose the same logical values. Explicit stacks
//! avoid recursion and preserve published preferred order. Assertions make direct
//! search admission conservative because range context complicates one-visit
//! pruning; exact replay over a known range remains eligible.
//!
//! Bitmap size is computed with checked arithmetic before engine use and policy
//! limits are enforced by `execute/request.zig`. Allocation/setup/execution
//! failure is an optional decline; capture NFA remains complete fallback.

const std = @import("std");
const match_types = @import("../../match.zig");
const context = @import("../context.zig");
const prefix_search = @import("../../literal/search.zig");
const program = @import("../../program/program.zig");

const no_position = std.math.maxInt(usize);
const max_retained_path_bytes = 4 * 1024;

// These records can reach one per input byte on an ambiguous path. Keep them
// at 16 bytes on 64-bit targets: Optional(usize) alone is 16 bytes in Zig, and
// the former field order made both records 24 bytes.
/// Logical inverse of one capture write; physical arrays below may pack this
/// pair more tightly for the active input/slot domains.
const Undo = struct { previous: usize, slot: u32 };
const no_position32 = std.math.maxInt(u32);
/// Physical undo encoding selected from input-position and capture-slot domains.
const UndoMode = enum { compact24, compact32, narrow, wide };
/// Logical deferred alternative: resume cursor at position after restoring the
/// undo log to `undo_len`.
const Job = struct {
    position: usize,
    cursor: u32,
    undo_len: u32,
};
/// Narrow physical Job when absolute positions fit 32 bits.
const Job32 = struct {
    position: u32,
    cursor: u32,
    undo_len: u32,
};
/// Physical deferred-job encoding selected once per request.
const JobMode = enum { compact, narrow, wide };

const entering_bit: u32 = 1 << 31;
const cursor_mask: u32 = entering_bit - 1;
const no_bitmap_root = std.math.maxInt(u32);

/// Reusable BitState slots, bitmap mapping, and alternative/undo stacks.
/// Exactly one physical job and undo representation is active per request.
pub const Matcher = struct {
    allocator: std.mem.Allocator,
    prog: *const program.Program,
    bitmap: std.ArrayList(u8) = .empty,
    jobs: std.ArrayList(Job) = .empty,
    jobs_narrow: std.ArrayList(Job32) = .empty,
    jobs_compact: std.ArrayList(u64) = .empty,
    undo: std.ArrayList(Undo) = .empty,
    undo_narrow: std.ArrayList(u64) = .empty,
    undo_compact: std.ArrayList(u32) = .empty,
    undo_compact24: std.ArrayList(u8) = .empty,
    slots: []?usize,
    root_bitmap_indices: []u32,

    /// Allocates reusable public capture slots and the Program's compressed
    /// root-to-bitmap-row map. Request-sized bitmap and path histories remain
    /// lazy because their dimensions depend on the input range.
    pub fn init(allocator: std.mem.Allocator, prog: *const program.Program) !Matcher {
        const slots = try allocator.alloc(?usize, prog.capture_slots);
        errdefer allocator.free(slots);
        const root_bitmap_indices = try allocator.alloc(u32, prog.priority_lists.lists.len);
        const dense = prog.fillBitStateRootMap(root_bitmap_indices);
        std.debug.assert(prog.plans.bit_state_root_count == 0 or
            dense == prog.plans.bit_state_root_count);
        return .{
            .allocator = allocator,
            .prog = prog,
            .slots = slots,
            .root_bitmap_indices = root_bitmap_indices,
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.allocator.free(self.root_bitmap_indices);
        self.allocator.free(self.slots);
        self.undo_compact24.deinit(self.allocator);
        self.undo_compact.deinit(self.allocator);
        self.undo_narrow.deinit(self.allocator);
        self.undo.deinit(self.allocator);
        self.jobs_compact.deinit(self.allocator);
        self.jobs_narrow.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
        self.bitmap.deinit(self.allocator);
        self.* = undefined;
    }

    /// Replays an anchored range and accepts only at `range_end`.
    pub fn capturesExact(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
    ) (error{ InvalidRange, OutOfMemory })!?match_types.CaptureView {
        return self.run(input, range_start, range_end, true, false);
    }

    /// Searches a range directly in preferred DFS order, injecting successive
    /// starts only for unanchored requests. `null` is a completed no-match;
    /// allocation errors let dispatch decline to range location and exact replay.
    pub fn capturesSearch(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
    ) (error{ InvalidRange, OutOfMemory })!?match_types.CaptureView {
        return self.run(
            input,
            range_start,
            range_end,
            false,
            anchor == .unanchored,
        );
    }

    /// Initializes the admitted bitmap and compact path representation, then
    /// performs ordered DFS with reversible capture writes. `entering_bit`
    /// distinguishes entering a root from resuming a flattened list cursor.
    fn run(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        require_end: bool,
        search_unanchored: bool,
    ) (error{ InvalidRange, OutOfMemory })!?match_types.CaptureView {
        defer self.trimPathScratch();
        if (range_start > range_end or range_end > input.len) return error.InvalidRange;
        const positions = std.math.add(usize, range_end - range_start, 1) catch
            return error.OutOfMemory;
        const bitmap_roots = if (self.prog.plans.bit_state_root_count != 0)
            self.prog.plans.bit_state_root_count
        else
            self.prog.priority_lists.lists.len;
        const bits = std.math.mul(usize, bitmap_roots, positions) catch
            return error.OutOfMemory;
        const bytes = std.math.add(usize, bits, 7) catch return error.OutOfMemory;
        const bitmap_len = bytes / 8;
        try self.bitmap.resize(self.allocator, bitmap_len);
        @memset(self.bitmap.items, 0);
        self.jobs.clearRetainingCapacity();
        self.jobs_narrow.clearRetainingCapacity();
        self.jobs_compact.clearRetainingCapacity();
        self.undo.clearRetainingCapacity();
        self.undo_narrow.clearRetainingCapacity();
        self.undo_compact.clearRetainingCapacity();
        self.undo_compact24.clearRetainingCapacity();
        // Large path histories are released after each search to keep warmed
        // retained memory bounded. Reserve their likely high-water in one
        // allocation here instead of repeatedly growing and copying them.
        const narrow_positions = range_end < no_position32;
        const compact_jobs = positions <= 0x00ff_ffff and
            self.prog.priority_lists.items.len <= 0x7fff;
        const job_mode: JobMode = if (compact_jobs)
            .compact
        else if (narrow_positions)
            .narrow
        else
            .wide;
        const compact_span = std.math.add(usize, positions, 1) catch
            return error.OutOfMemory;
        const compact_values = std.math.mul(
            usize,
            compact_span,
            self.prog.capture_slots,
        ) catch std.math.maxInt(usize);
        const undo_mode: UndoMode = if (compact_values <= 0x00ff_ffff)
            .compact24
        else if (compact_values <= no_position32)
            .compact32
        else if (narrow_positions)
            .narrow
        else
            .wide;
        if (positions > max_retained_path_bytes / @sizeOf(Job)) {
            switch (job_mode) {
                .compact => try self.jobs_compact.ensureTotalCapacityPrecise(
                    self.allocator,
                    positions,
                ),
                .narrow => try self.jobs_narrow.ensureTotalCapacityPrecise(
                    self.allocator,
                    positions,
                ),
                .wide => try self.jobs.ensureTotalCapacityPrecise(
                    self.allocator,
                    positions,
                ),
            }
            const undo_hint = std.math.mul(
                usize,
                positions,
                @min(@as(usize, self.prog.capture_slots), 4),
            ) catch return error.OutOfMemory;
            switch (undo_mode) {
                .compact24 => {
                    const byte_hint = std.math.mul(usize, undo_hint, 3) catch
                        return error.OutOfMemory;
                    try self.undo_compact24.ensureTotalCapacityPrecise(
                        self.allocator,
                        byte_hint,
                    );
                },
                .compact32 => try self.undo_compact.ensureTotalCapacityPrecise(
                    self.allocator,
                    undo_hint,
                ),
                .narrow => try self.undo_narrow.ensureTotalCapacityPrecise(
                    self.allocator,
                    undo_hint,
                ),
                .wide => try self.undo.ensureTotalCapacityPrecise(
                    self.allocator,
                    undo_hint,
                ),
            }
        }
        var attempt_start = range_start;
        while (attempt_start <= range_end) : (attempt_start += 1) {
            if (search_unanchored and self.prog.prefix.len != 0) {
                const prefix_here = self.prog.prefix.len <= range_end - attempt_start and
                    (if (self.prog.prefix_fold_ascii)
                        foldedEqual(
                            input[attempt_start..][0..self.prog.prefix.len],
                            self.prog.prefix,
                        )
                    else
                        std.mem.eql(
                            u8,
                            input[attempt_start..][0..self.prog.prefix.len],
                            self.prog.prefix,
                        ));
                if (!prefix_here) {
                    if (attempt_start == range_end) break;
                    attempt_start = (if (self.prog.prefix_fold_ascii)
                        prefix_search.findFoldedAscii(
                            input,
                            attempt_start + 1,
                            range_end,
                            self.prog.prefix,
                        )
                    else
                        prefix_search.find(
                            input,
                            attempt_start + 1,
                            range_end,
                            self.prog.prefix,
                        )) orelse break;
                }
            }
            self.jobs.clearRetainingCapacity();
            self.jobs_narrow.clearRetainingCapacity();
            self.jobs_compact.clearRetainingCapacity();
            self.undo.clearRetainingCapacity();
            self.undo_narrow.clearRetainingCapacity();
            self.undo_compact.clearRetainingCapacity();
            self.undo_compact24.clearRetainingCapacity();
            @memset(self.slots, null);
            self.slots[0] = attempt_start;
            try self.appendJob(job_mode, range_start, .{
                .position = attempt_start,
                .cursor = entering_bit | self.listStart(
                    self.prog.priority_lists.start_root,
                ),
                .undo_len = 0,
            });

            while (self.popJob(job_mode, range_start)) |job| {
                self.restore(job.undo_len, undo_mode, range_start);
                var cursor = job.cursor & cursor_mask;
                var entering_root: ?u32 = if (job.cursor & entering_bit != 0)
                    self.prog.priority_lists.start_root
                else
                    null;
                var position = job.position;

                branch: while (true) {
                    if (entering_root) |entered| {
                        const bitmap_root = self.root_bitmap_indices[entered];
                        if (bitmap_root != no_bitmap_root) {
                            const bit_index = @as(usize, bitmap_root) * positions +
                                (position - range_start);
                            if (testAndSet(self.bitmap.items, bit_index)) break :branch;
                        }
                        entering_root = null;
                    }
                    const item = self.prog.priority_lists.items[cursor];
                    const checkpoint: u32 = @intCast(self.undoLength(undo_mode));
                    const has_next = !item.isLast();

                    if (item.isRoot()) {
                        if (has_next) try self.appendJob(job_mode, range_start, .{
                            .position = position,
                            .cursor = cursor + 1,
                            .undo_len = @intCast(checkpoint),
                        });
                        const target = item.root();
                        cursor = self.listStart(target);
                        entering_root = target;
                        continue :branch;
                    }
                    const instruction = self.prog.runtimeInstruction(item);
                    switch (instruction.opcode()) {
                        .fail => if (has_next) {
                            cursor += 1;
                        } else break :branch,
                        .empty_width => {
                            if (!context.assertionsHold(
                                instruction.emptyMask(),
                                input,
                                position,
                            )) {
                                if (!has_next) break :branch;
                                cursor += 1;
                                continue :branch;
                            }
                            if (has_next) try self.appendJob(job_mode, range_start, .{
                                .position = position,
                                .cursor = cursor + 1,
                                .undo_len = @intCast(checkpoint),
                            });
                            const target = self.prog.instructionSuccessor(instruction);
                            cursor = self.listStart(target);
                            entering_root = target;
                        },
                        .capture => {
                            if (has_next) try self.appendJob(job_mode, range_start, .{
                                .position = position,
                                .cursor = cursor + 1,
                                .undo_len = @intCast(checkpoint),
                            });
                            const slot = @intFromEnum(instruction.captureSlot());
                            if (self.slots[slot] != position) {
                                if (self.undoLength(undo_mode) == std.math.maxInt(u32))
                                    return error.OutOfMemory;
                                try self.appendUndo(undo_mode, slot, range_start);
                                self.slots[slot] = position;
                            }
                            const target = self.prog.instructionSuccessor(instruction);
                            cursor = self.listStart(target);
                            entering_root = target;
                        },
                        .byte_range => {
                            if (position == range_end or
                                !instruction.matchesByte(input[position]))
                            {
                                if (!has_next) break :branch;
                                cursor += 1;
                                continue :branch;
                            }
                            if (has_next) try self.appendJob(job_mode, range_start, .{
                                .position = position,
                                .cursor = cursor + 1,
                                .undo_len = @intCast(checkpoint),
                            });
                            position += 1;
                            const target = self.prog.instructionSuccessor(instruction);
                            cursor = self.listStart(target);
                            entering_root = target;
                        },
                        .match => {
                            if (require_end and position != range_end) {
                                if (!has_next) break :branch;
                                cursor += 1;
                                continue :branch;
                            }
                            self.jobs.clearRetainingCapacity();
                            self.jobs_narrow.clearRetainingCapacity();
                            self.jobs_compact.clearRetainingCapacity();
                            self.undo.clearRetainingCapacity();
                            self.undo_narrow.clearRetainingCapacity();
                            self.undo_compact.clearRetainingCapacity();
                            self.undo_compact24.clearRetainingCapacity();
                            self.slots[1] = position;
                            return .{ .slots = self.slots };
                        },
                        .jump, .split => unreachable,
                    }
                }
            }
            self.restore(0, undo_mode, range_start);
            if (!search_unanchored) break;
        }
        return null;
    }

    /// Encodes one deferred alternative into the request-selected physical job
    /// array, preserving logical position/cursor/undo checkpoint.
    fn appendJob(
        self: *Matcher,
        mode: JobMode,
        range_start: usize,
        job: Job,
    ) error{OutOfMemory}!void {
        switch (mode) {
            .compact => {
                const relative = job.position - range_start;
                const cursor_value = job.cursor & cursor_mask;
                if (relative > 0x00ff_ffff or cursor_value > 0x7fff or
                    job.undo_len > 0x00ff_ffff) return error.OutOfMemory;
                const cursor_code = cursor_value |
                    @as(u32, if (job.cursor & entering_bit != 0) 0x8000 else 0);
                try self.jobs_compact.append(
                    self.allocator,
                    relative | (@as(u64, cursor_code) << 24) |
                        (@as(u64, job.undo_len) << 40),
                );
            },
            .narrow => try self.jobs_narrow.append(self.allocator, .{
                .position = @intCast(job.position),
                .cursor = job.cursor,
                .undo_len = job.undo_len,
            }),
            .wide => try self.jobs.append(self.allocator, job),
        }
    }

    /// Pops from the active physical job array and widens/rebases it to one logical
    /// Job value.
    fn popJob(self: *Matcher, mode: JobMode, range_start: usize) ?Job {
        return switch (mode) {
            .compact => blk: {
                const encoded = self.jobs_compact.pop() orelse break :blk null;
                const cursor_code: u32 = @truncate((encoded >> 24) & 0xffff);
                break :blk .{
                    .position = range_start + @as(usize, @intCast(encoded & 0x00ff_ffff)),
                    .cursor = (cursor_code & 0x7fff) |
                        (if (cursor_code & 0x8000 != 0) entering_bit else 0),
                    .undo_len = @truncate(encoded >> 40),
                };
            },
            .narrow => if (self.jobs_narrow.pop()) |job| .{
                .position = job.position,
                .cursor = job.cursor,
                .undo_len = job.undo_len,
            } else null,
            .wide => self.jobs.pop(),
        };
    }

    /// Encodes the first flattened item cursor for a Program root.
    fn listStart(self: *const Matcher, root: u32) u32 {
        return self.prog.priority_lists.lists[root].offset;
    }

    /// Returns logical undo-record count independent of compact physical storage.
    fn undoLength(self: *const Matcher, mode: UndoMode) usize {
        return switch (mode) {
            .compact24 => self.undo_compact24.items.len / 3,
            .compact32 => self.undo_compact.items.len,
            .narrow => self.undo_narrow.items.len,
            .wide => self.undo.items.len,
        };
    }

    /// Encodes the overwritten slot value in the narrowest active undo format;
    /// `no_position` is preserved through each format's sentinel.
    fn appendUndo(
        self: *Matcher,
        mode: UndoMode,
        slot: u32,
        range_start: usize,
    ) error{OutOfMemory}!void {
        const previous_code: usize = if (self.slots[slot]) |previous|
            previous - range_start + 1
        else
            0;
        const compact_value = previous_code * self.prog.capture_slots + slot;
        switch (mode) {
            .compact24 => {
                std.debug.assert(compact_value <= 0x00ff_ffff);
                try self.undo_compact24.ensureUnusedCapacity(self.allocator, 3);
                self.undo_compact24.appendAssumeCapacity(@truncate(compact_value));
                self.undo_compact24.appendAssumeCapacity(@truncate(compact_value >> 8));
                self.undo_compact24.appendAssumeCapacity(@truncate(compact_value >> 16));
            },
            .compact32 => {
                std.debug.assert(compact_value <= std.math.maxInt(u32));
                try self.undo_compact.append(self.allocator, @intCast(compact_value));
            },
            .narrow => {
                const previous: u32 = if (self.slots[slot]) |value|
                    @intCast(value)
                else
                    no_position32;
                try self.undo_narrow.append(
                    self.allocator,
                    (@as(u64, slot) << 32) | previous,
                );
            },
            .wide => try self.undo.append(self.allocator, .{
                .previous = self.slots[slot] orelse no_position,
                .slot = slot,
            }),
        }
    }

    /// Replays undo entries backward until `target_len`, restoring the capture
    /// path before a deferred branch resumes.
    fn restore(
        self: *Matcher,
        target: usize,
        mode: UndoMode,
        range_start: usize,
    ) void {
        switch (mode) {
            .compact24 => while (self.undo_compact24.items.len / 3 > target) {
                const high = self.undo_compact24.pop().?;
                const middle = self.undo_compact24.pop().?;
                const low = self.undo_compact24.pop().?;
                const encoded: u32 = low | (@as(u32, middle) << 8) |
                    (@as(u32, high) << 16);
                self.restoreCompact(encoded, range_start);
            },
            .compact32 => while (self.undo_compact.items.len > target) {
                self.restoreCompact(self.undo_compact.pop().?, range_start);
            },
            .narrow => while (self.undo_narrow.items.len > target) {
                const encoded = self.undo_narrow.pop().?;
                const slot: u32 = @intCast(encoded >> 32);
                const previous: u32 = @truncate(encoded);
                self.slots[slot] = if (previous == no_position32) null else previous;
            },
            .wide => while (self.undo.items.len > target) {
                const entry = self.undo.pop().?;
                self.slots[entry.slot] = if (entry.previous == no_position)
                    null
                else
                    entry.previous;
            },
        }
    }

    /// Decodes one compact slot/relative-position undo record and restores the
    /// nullable public slot value.
    fn restoreCompact(self: *Matcher, encoded: u32, range_start: usize) void {
        const slot = encoded % self.prog.capture_slots;
        const previous_code = encoded / self.prog.capture_slots;
        self.slots[slot] = if (previous_code == 0)
            null
        else
            range_start + previous_code - 1;
    }

    /// Releases unusually large path histories after a request so one adversarial
    /// search does not permanently inflate warmed Matcher retention.
    fn trimPathScratch(self: *Matcher) void {
        // A long ambiguous match can leave O(input) backtracking checkpoints
        // retained even though the next input may be tiny. Keep the bitmap: it
        // is the bounded linearity mechanism and is reused cheaply. Release
        // only oversized path history, matching the engine's per-search BitState
        // request while preserving allocation-free reuse for ordinary jobs.
        const oversized_path =
            self.jobs.capacity * @sizeOf(Job) > max_retained_path_bytes or
            self.jobs_narrow.capacity * @sizeOf(Job32) > max_retained_path_bytes or
            self.jobs_compact.capacity * @sizeOf(u64) > max_retained_path_bytes or
            self.undo.capacity * @sizeOf(Undo) > max_retained_path_bytes or
            self.undo_narrow.capacity * @sizeOf(u64) > max_retained_path_bytes or
            self.undo_compact.capacity * @sizeOf(u32) > max_retained_path_bytes or
            self.undo_compact24.capacity > max_retained_path_bytes;
        if (self.jobs.capacity * @sizeOf(Job) > max_retained_path_bytes) {
            self.jobs.deinit(self.allocator);
            self.jobs = .empty;
        }
        if (self.jobs_narrow.capacity * @sizeOf(Job32) > max_retained_path_bytes) {
            self.jobs_narrow.deinit(self.allocator);
            self.jobs_narrow = .empty;
        }
        if (self.jobs_compact.capacity * @sizeOf(u64) > max_retained_path_bytes) {
            self.jobs_compact.deinit(self.allocator);
            self.jobs_compact = .empty;
        }
        if (self.undo.capacity * @sizeOf(Undo) > max_retained_path_bytes) {
            self.undo.deinit(self.allocator);
            self.undo = .empty;
        }
        if (self.undo_narrow.capacity * @sizeOf(u64) > max_retained_path_bytes) {
            self.undo_narrow.deinit(self.allocator);
            self.undo_narrow = .empty;
        }
        if (self.undo_compact.capacity * @sizeOf(u32) > max_retained_path_bytes) {
            self.undo_compact.deinit(self.allocator);
            self.undo_compact = .empty;
        }
        if (self.undo_compact24.capacity > max_retained_path_bytes) {
            self.undo_compact24.deinit(self.allocator);
            self.undo_compact24 = .empty;
        }
        if (oversized_path and self.bitmap.capacity > max_retained_path_bytes) {
            self.bitmap.deinit(self.allocator);
            self.bitmap = .empty;
        }
    }
};

/// Checked exact-replay bitmap bytes using publication's compressed root rows.
pub fn requiredBitmapBytesForProg(
    prog: *const program.Program,
    range_bytes: usize,
) error{Overflow}!usize {
    const bitmap_roots = if (prog.plans.bit_state_root_count != 0)
        prog.plans.bit_state_root_count
    else
        prog.priority_lists.lists.len;
    return requiredBitmapBytes(bitmap_roots, range_bytes);
}

/// Checked direct-search bitmap bytes using every Program root.
pub fn requiredFullBitmapBytesForProg(
    prog: *const program.Program,
    range_bytes: usize,
) error{Overflow}!usize {
    return requiredBitmapBytes(prog.priority_lists.lists.len, range_bytes);
}

fn requiredBitmapBytes(root_count: usize, range_bytes: usize) error{Overflow}!usize {
    const positions = std.math.add(usize, range_bytes, 1) catch return error.Overflow;
    const bits = std.math.mul(usize, root_count, positions) catch return error.Overflow;
    const rounded = std.math.add(usize, bits, 7) catch return error.Overflow;
    return rounded / 8;
}

fn foldedEqual(actual: []const u8, lower: []const u8) bool {
    for (actual, lower) |byte, wanted|
        if (std.ascii.toLower(byte) != wanted) return false;
    return true;
}

/// Returns true when the bit was already set; otherwise marks first visitation.
fn testAndSet(bitmap: []u8, index: usize) bool {
    const byte_index = index / 8;
    const mask = @as(u8, 1) << @intCast(index % 8);
    if (bitmap[byte_index] & mask != 0) return true;
    bitmap[byte_index] |= mask;
    return false;
}

const parser = @import("../../syntax/parser.zig");
const compiler = @import("../../program/compiler.zig");
const regexp = @import("../../syntax/regexp.zig");
const testing = std.testing;

fn compilePattern(pattern: []const u8) !struct { regexp.Regexp, program.Program } {
    const parsed = try parser.parse(testing.allocator, pattern, .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = switch (parsed) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    errdefer tree.deinit(testing.allocator);
    const prog = try compiler.compile(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
    });
    return .{ tree, prog };
}

test "Exact BitState preserves ordered capture semantics" {
    for ([_]struct {
        pattern: []const u8,
        input: []const u8,
        expected_group: usize,
        expected: match_types.Match,
    }{
        .{ .pattern = "(a)+", .input = "aa", .expected_group = 1, .expected = .{ .start = 1, .end = 2 } },
        .{ .pattern = "(a+?)(a*)", .input = "aaa", .expected_group = 1, .expected = .{ .start = 0, .end = 1 } },
        .{ .pattern = "((a|aa)*)b", .input = "aaab", .expected_group = 1, .expected = .{ .start = 0, .end = 3 } },
        .{ .pattern = "(())*", .input = "", .expected_group = 2, .expected = .{ .start = 0, .end = 0 } },
    }) |case| {
        var values = try compilePattern(case.pattern);
        defer values[0].deinit(testing.allocator);
        defer values[1].deinit(testing.allocator);
        var matcher = try Matcher.init(testing.allocator, &values[1]);
        defer matcher.deinit();
        const view = (try matcher.capturesExact(case.input, 0, case.input.len)).?;
        try testing.expectEqual(case.expected, view.group(case.expected_group).?);
    }

    var nullable = try compilePattern("(?U:((?:(b)?)*\\C*)*)");
    defer nullable[0].deinit(testing.allocator);
    defer nullable[1].deinit(testing.allocator);
    var nullable_matcher = try Matcher.init(testing.allocator, &nullable[1]);
    defer nullable_matcher.deinit();
    const nullable_view = (try nullable_matcher.capturesExact("\x00bb", 0, 3)).?;
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 3 }, nullable_view.group(1).?);
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 2 }, nullable_view.group(2).?);

    var contextual = try compilePattern("\\b(a)\\b");
    defer contextual[0].deinit(testing.allocator);
    defer contextual[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &contextual[1]);
    defer matcher.deinit();
    const bounded = (try matcher.capturesExact(" a!", 1, 2)).?;
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 2 }, bounded.group(1).?);
    try testing.expect((try matcher.capturesExact("xa!", 1, 2)) == null);
}

test "Unanchored BitState finds captures without range discovery" {
    var values = try compilePattern("((a|aa)*)b");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.capturesSearch("xxaaab", 0, 6, .unanchored)).?;
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 6 }, view.group(0).?);
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 5 }, view.group(1).?);
}

test "Narrow path records preserve full job values" {
    try testing.expectEqual(@as(usize, 12), @sizeOf(Job32));
    try testing.expect(@sizeOf(Job32) < @sizeOf(Job));
    var values = try compilePattern("(a)b");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const expected = Job{ .position = 123, .cursor = 456, .undo_len = 789 };
    try matcher.appendJob(.compact, 0, expected);
    try testing.expectEqualDeep(expected, matcher.popJob(.compact, 0).?);
    try matcher.appendJob(.narrow, 0, expected);
    try testing.expectEqualDeep(expected, matcher.popJob(.narrow, 0).?);
    try matcher.appendJob(.wide, 0, expected);
    try testing.expectEqualDeep(expected, matcher.popJob(.wide, 0).?);
}

test "Bitmap accounting and warmed allocation are exact" {
    var values = try compilePattern("((a|aa)*)b");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    try testing.expect(values[1].plans.bit_state_root_count <
        values[1].priority_lists.lists.len);
    try testing.expectEqual(
        (values[1].plans.bit_state_root_count * 5 + 7) / 8,
        try requiredBitmapBytesForProg(&values[1], 4),
    );
    _ = try matcher.capturesExact("aaab", 0, 4);
    const bitmap_capacity = matcher.bitmap.capacity;
    const jobs_capacity = matcher.jobs.capacity;
    const undo_capacity = matcher.undo.capacity;
    _ = try matcher.capturesExact("aaab", 0, 4);
    try testing.expectEqual(bitmap_capacity, matcher.bitmap.capacity);
    try testing.expectEqual(jobs_capacity, matcher.jobs.capacity);
    try testing.expectEqual(undo_capacity, matcher.undo.capacity);
}
