//! Reference-counted copy-on-write capture-slot rows for NFA threads.
//!
//! Each logical row occupies a fixed slice of one contiguous slot array and has
//! metadata containing either a live reference count or free-list linkage. A
//! split retains the same RowId for both branches. Before a capture instruction
//! writes a shared row, `makeUnique` allocates/reuses a row, copies all slots, and
//! releases the old reference.
//!
//! Released zero-reference rows enter a free list and are recycled, so repeated
//! searches allocate only when they exceed the previous live-row high-water.
//! Growth preserves RowIds by extending metadata and slot backing in lockstep.
//! `maxInt(usize)` is an impossible input position used as the internal unmatched
//! sentinel, keeping one machine word per slot; public output converts it to
//! `null`.
//!
//! Pool owns storage but not thread scheduling. Its counters expose row creation,
//! reuse, and copy cost for qualification without affecting behavior.

const std = @import("std");

/// Stable index into row metadata and fixed-width slot backing.
pub const RowId = enum(u32) { _ };
const no_position = std.math.maxInt(usize);
const live_flag: u32 = 1 << 31;
const metadata_value_mask = live_flag - 1;
const no_row = metadata_value_mask;

/// Owner of row metadata, contiguous slot backing, and a recycled-row free list.
/// Live metadata stores `live_flag | reference_count`; free metadata stores the
/// next free RowId.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    slot_count: u32,
    values: std.ArrayList(usize) = .empty,
    metadata: std.ArrayList(u32) = .empty,
    free_head: u32 = no_row,
    copy_count: usize = 0,
    copy_bytes: usize = 0,
    created_count: usize = 0,
    reused_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, slot_count: u32) Pool {
        return .{
            .allocator = allocator,
            .slot_count = slot_count,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.metadata.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    /// Changes row width only when no row is live, retaining compatible capacity
    /// where possible for Matcher rebinding/tests.
    pub fn reconfigure(self: *Pool, slot_count: u32) void {
        if (self.slot_count == slot_count) return;
        std.debug.assert(self.liveRows() == 0);
        self.metadata.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.metadata = .empty;
        self.values = .empty;
        self.free_head = no_row;
        self.slot_count = slot_count;
    }

    /// Allocates/reuses a unique row initialized to the unmatched sentinel.
    pub fn allocEmpty(self: *Pool) !RowId {
        const id = try self.allocRow();
        @memset(self.row(id), no_position);
        return id;
    }

    /// Allocates a unique copy without changing the source reference count.
    pub fn allocCopy(self: *Pool, source: RowId) !RowId {
        const id = try self.allocRow();
        self.recordCopy();
        @memcpy(self.row(id), self.rowConst(source));
        return id;
    }

    /// Copy-on-write helper used when a shared row receives one capture update.
    pub fn allocCopySet(self: *Pool, source: RowId, slot: usize, value: usize) !RowId {
        std.debug.assert(value != no_position);
        const id = try self.allocRow();
        self.recordCopy();
        const destination = self.row(id);
        @memcpy(destination, self.rowConst(source));
        destination[slot] = value;
        return id;
    }

    fn recordCopy(self: *Pool) void {
        self.copy_count +|= 1;
        self.copy_bytes +|= @as(usize, self.slot_count) *| @sizeOf(usize);
    }

    pub fn isUnique(self: *const Pool, id: RowId) bool {
        return self.metadata.items[@intFromEnum(id)] == live_flag | 1;
    }

    /// Adds one thread reference; overflow would imply an impossible queue/domain
    /// violation and is asserted.
    pub fn retain(self: *Pool, id: RowId) void {
        const metadata = &self.metadata.items[@intFromEnum(id)];
        std.debug.assert(metadata.* & live_flag != 0);
        std.debug.assert(metadata.* & metadata_value_mask < metadata_value_mask);
        metadata.* += 1;
    }

    /// Removes one thread reference and links a zero-reference row into the free
    /// list in O(1).
    pub fn release(self: *Pool, id: RowId) void {
        const index = @intFromEnum(id);
        const metadata = &self.metadata.items[index];
        std.debug.assert(metadata.* & live_flag != 0);
        std.debug.assert(metadata.* & metadata_value_mask > 0);
        metadata.* -= 1;
        if (metadata.* == live_flag) {
            metadata.* = self.free_head;
            self.free_head = index;
        }
    }

    fn row(self: *Pool, id: RowId) []usize {
        const start = @as(usize, @intFromEnum(id)) * self.slot_count;
        return self.values.items[start .. start + self.slot_count];
    }

    fn rowConst(self: *const Pool, id: RowId) []const usize {
        const start = @as(usize, @intFromEnum(id)) * self.slot_count;
        return self.values.items[start .. start + self.slot_count];
    }

    pub fn get(self: *const Pool, id: RowId, slot: usize) ?usize {
        const value = self.rowConst(id)[slot];
        return if (value == no_position) null else value;
    }

    pub fn set(self: *Pool, id: RowId, slot: usize, value: usize) void {
        std.debug.assert(value != no_position);
        self.row(id)[slot] = value;
    }

    /// Publishes an internal row as optional offsets, translating the unmatched
    /// sentinel and requiring exact destination width.
    pub fn copyOptional(self: *const Pool, destination: []?usize, id: RowId) void {
        std.debug.assert(destination.len == self.slot_count);
        const values = self.rowConst(id);
        for (destination, values) |*output, value|
            output.* = if (value == no_position) null else value;
    }

    pub fn requestedCapacityBytes(self: *const Pool) usize {
        return self.values.capacity *| @sizeOf(usize) +|
            self.metadata.capacity *| @sizeOf(u32);
    }

    pub fn liveRows(self: *const Pool) usize {
        var count: usize = 0;
        for (self.metadata.items) |metadata|
            count += @intFromBool(metadata & live_flag != 0);
        return count;
    }

    /// Pops a free row or grows metadata/backing transactionally by one row.
    fn allocRow(self: *Pool) !RowId {
        if (self.free_head != no_row) {
            const id: RowId = @enumFromInt(self.free_head);
            self.reused_count +|= 1;
            const metadata = &self.metadata.items[@intFromEnum(id)];
            std.debug.assert(metadata.* & live_flag == 0);
            self.free_head = metadata.*;
            metadata.* = live_flag | 1;
            return id;
        }

        if (self.metadata.items.len >= no_row) return error.OutOfMemory;
        const id: RowId = @enumFromInt(self.metadata.items.len);
        try self.metadata.ensureUnusedCapacity(self.allocator, 1);
        const old_length = self.values.items.len;
        const new_length = std.math.add(
            usize,
            old_length,
            self.slot_count,
        ) catch return error.OutOfMemory;
        try self.values.resize(self.allocator, new_length);
        self.metadata.appendAssumeCapacity(live_flag | 1);
        self.created_count +|= 1;
        return id;
    }
};

const testing = std.testing;

test "Rows share, copy on write, and recycle" {
    var pool = Pool.init(testing.allocator, 4);
    defer pool.deinit();
    const first = try pool.allocEmpty();
    try testing.expect(
        @as(usize, pool.slot_count) * @sizeOf(usize) <
            @as(usize, pool.slot_count) * @sizeOf(?usize),
    );
    try testing.expect(pool.requestedCapacityBytes() > 0);
    pool.set(first, 0, 7);
    pool.retain(first);
    const copy = try pool.allocCopy(first);
    pool.set(copy, 0, 9);
    try testing.expectEqual(@as(?usize, 7), pool.get(first, 0));
    try testing.expectEqual(@as(?usize, 9), pool.get(copy, 0));
    pool.release(first);
    pool.release(first);
    pool.release(copy);
    try testing.expectEqual(@as(usize, 0), pool.liveRows());
    const recycled = try pool.allocEmpty();
    try testing.expect(recycled == copy or recycled == first);
    pool.release(recycled);
    const reused_a = try pool.allocEmpty();
    const reused_b = try pool.allocEmpty();
    try testing.expect(reused_a != reused_b);
    try testing.expectEqual(@as(usize, 2), pool.created_count);
    pool.release(reused_a);
    pool.release(reused_b);
}
