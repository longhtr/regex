//! Allocator wrapper enforcing and measuring requested live bytes.
//!
//! BudgetAllocator implements Zig's Allocator vtable over a child allocator. It
//! tracks the sizes requested through alloc/resize/remap/free, not allocator
//! usable size or process RSS. Before growth it checks `live + additional` against
//! an optional hard limit with overflow-safe arithmetic; successful operations
//! update live, peak, and allocation count.
//!
//! No per-allocation header is added. Zig's allocator callbacks provide old/new
//! lengths, so storage can later be released through the child allocator after
//! publication as long as the owner accounts for any retained reservation. This
//! property is used by compile and collection transactions.
//!
//! `exhausted` records that the wrapper rejected a request, allowing a surrounding
//! catch to distinguish configured-budget exhaustion from child
//! `OutOfMemory`. Owners reset it at operation boundaries when later attempts
//! need fresh classification. Budget `.unlimited` still measures resources.
//!
//! `reserve/release` accounts for owner objects allocated directly through the
//! child but charged to the same product policy. The wrapper state must outlive
//! every allocator callback using its vtable.

const std = @import("std");

/// Hard requested-byte allowance for essential product storage.
pub const Budget = union(enum) {
    bytes: usize,
    unlimited,
};

/// Optional accelerator allowance; disabled is distinct from a zero-byte cache
/// for clearer policy/metrics.
pub const OptionalBudget = union(enum) {
    disabled,
    bytes: usize,
    unlimited,
};

pub fn subtractOverhead(budget: Budget, overhead: usize) ?Budget {
    return switch (budget) {
        .bytes => |bytes| if (bytes < overhead) null else .{ .bytes = bytes - overhead },
        .unlimited => .unlimited,
    };
}

/// Stateful Allocator-vtable context. Do not move this value while an Allocator
/// handle returned by `allocator()` may still be used.
pub const BudgetAllocator = struct {
    child: std.mem.Allocator,
    limit: ?usize,
    live: usize = 0,
    peak: usize = 0,
    allocation_count: usize = 0,
    exhausted: bool = false,

    pub fn init(child: std.mem.Allocator, budget: Budget) BudgetAllocator {
        return .{
            .child = child,
            .limit = switch (budget) {
                .bytes => |bytes| bytes,
                .unlimited => null,
            },
        };
    }

    pub fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Remaining requested bytes, or null for an unlimited budget.
    pub fn remaining(self: *const BudgetAllocator) ?usize {
        return if (self.limit) |limit| limit - self.live else null;
    }

    /// Accounts for retained bytes allocated outside this wrapper.
    pub fn reserve(self: *BudgetAllocator, len: usize) bool {
        if (!self.admits(0, len)) return false;
        self.recordResize(0, len);
        return true;
    }

    pub fn release(self: *BudgetAllocator, len: usize) void {
        std.debug.assert(self.live >= len);
        self.live -= len;
    }

    /// Checks only positive growth against the limit and marks policy exhaustion
    /// on denial/overflow.
    fn admits(self: *BudgetAllocator, old_len: usize, new_len: usize) bool {
        if (new_len <= old_len) return true;
        const addition = new_len - old_len;
        const next = std.math.add(usize, self.live, addition) catch {
            self.exhausted = true;
            return false;
        };
        if (self.limit) |limit| {
            if (next > limit) {
                self.exhausted = true;
                return false;
            }
        }
        return true;
    }

    /// Updates exact live bytes after a successful child operation and raises the
    /// retained high-water.
    fn recordResize(self: *BudgetAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.live += new_len - old_len;
            self.peak = @max(self.peak, self.live);
        } else {
            self.live -= old_len - new_len;
        }
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (!self.admits(0, len)) return null;
        const memory = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.allocation_count +|= 1;
        self.recordResize(0, len);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (!self.admits(memory.len, new_len)) return false;
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len > memory.len) self.allocation_count +|= 1;
        self.recordResize(memory.len, new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (!self.admits(memory.len, new_len)) return null;
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        if (new_len > memory.len) self.allocation_count +|= 1;
        self.recordResize(memory.len, new_len);
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
        std.debug.assert(self.live >= memory.len);
        self.live -= memory.len;
    }
};

const testing = std.testing;

test "Budget rejects excess allocation and tracks frees exactly" {
    var budget = BudgetAllocator.init(testing.allocator, .{ .bytes = 16 });
    const allocator = budget.allocator();
    const memory = try allocator.alloc(u8, 8);
    var release_memory = true;
    defer if (release_memory) allocator.free(memory);
    try testing.expectEqual(@as(usize, 8), budget.live);
    const second = try allocator.alloc(u8, 8);
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try testing.expect(budget.exhausted);
    allocator.free(second);
    try testing.expectEqual(@as(usize, 8), budget.live);
    const third = try allocator.alloc(u8, 8);
    allocator.free(third);
    allocator.free(memory);
    release_memory = false;
    try testing.expectEqual(@as(usize, 0), budget.live);
    try testing.expect(budget.reserve(12));
    try testing.expectEqual(@as(?usize, 4), budget.remaining());
    try testing.expect(!budget.reserve(5));
    budget.release(12);
    try testing.expectEqual(@as(usize, 16), budget.peak);
    try testing.expectEqual(@as(usize, 3), budget.allocation_count);
}
