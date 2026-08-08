//! Structural traversal of nested Program priority-list closures.
//!
//! Publication may place a root reference inside another root's ordered list.
//! `Cursor` iterates one root without recursion. Each returned `Entry` identifies
//! the canonical item and, when more siblings remain, carries a continuation
//! Cursor for the parent list. Executors put child cursors and continuations on
//! their own explicit work stack, preserving depth-first priority.
//!
//! `Visited` stores a generation number per canonical item. Beginning a closure
//! increments the generation, and `mark` accepts only the first arrival in that
//! generation. Rollover clears marks once rather than clearing on every input
//! byte. First arrival is priority-sensitive, so executors must traverse cursors
//! and enqueue work in published order.
//!
//! This module knows only list structure and identity. Assertion evaluation,
//! consuming leaves, captures, and accepting behavior remain in each executor.

const std = @import("std");
const program = @import("../program/program.zig");

/// One flattened list occurrence, its packed item, and where the enclosing list
/// should resume after a nested root is explored.
pub const Entry = struct {
    id: u32,
    item: program.PriorityItem,
    continuation: ?Cursor,
};

/// Position within one canonical priority-list root.
pub const Cursor = struct {
    root: u32,
    index: u32 = 0,

    /// Returns the next flattened item occurrence and advances this cursor.
    pub fn next(
        self: *Cursor,
        priority: *const program.PriorityLists,
    ) ?Entry {
        const list = priority.lists[self.root];
        if (self.index >= list.len) return null;
        const index = self.index;
        self.index += 1;
        const id = list.offset + index;
        return .{
            .id = id,
            .item = priority.items[id],
            .continuation = if (self.index < list.len) .{
                .root = self.root,
                .index = self.index,
            } else null,
        };
    }
};

/// Generation-mark table indexed by flattened PriorityItem occurrence.
pub const Visited = struct {
    marks: []u32,
    generation: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, item_count: usize) !Visited {
        const marks = try allocator.alloc(u32, item_count);
        @memset(marks, 0);
        return .{ .marks = marks };
    }

    pub fn deinit(self: *Visited, allocator: std.mem.Allocator) void {
        allocator.free(self.marks);
        self.* = undefined;
    }

    pub fn clear(self: *Visited) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.marks, 0);
            self.generation = 1;
        }
    }

    /// Returns true only for the first arrival in the current generation.
    pub fn mark(self: *Visited, item: u32) bool {
        if (self.marks[item] == self.generation) return false;
        self.marks[item] = self.generation;
        return true;
    }
};

const testing = std.testing;

test "Closure cursor exposes exact continuation and generations roll safely" {
    const items = [_]program.PriorityItem{
        program.PriorityItem.fromRuntimeInstruction(@enumFromInt(2)),
        program.PriorityItem.fromRoot(1).markLast(),
        program.PriorityItem.fromRuntimeInstruction(@enumFromInt(3)).markLast(),
    };
    const lists = [_]program.PriorityList{
        .{ .offset = 0, .len = 2 },
        .{ .offset = 2, .len = 1 },
    };
    const priority = program.PriorityLists{ .lists = @constCast(&lists), .items = @constCast(&items) };
    var cursor = Cursor{ .root = 0 };
    const first = cursor.next(&priority).?;
    try testing.expectEqual(@as(u32, 0), first.id);
    try testing.expectEqual(Cursor{ .root = 0, .index = 1 }, first.continuation.?);
    const second = cursor.next(&priority).?;
    try testing.expect(second.item.isRoot());
    try testing.expect(second.continuation == null);

    var visited = try Visited.init(testing.allocator, items.len);
    defer visited.deinit(testing.allocator);
    try testing.expect(visited.mark(1));
    try testing.expect(!visited.mark(1));
    visited.generation = std.math.maxInt(u32);
    visited.clear();
    try testing.expectEqual(@as(u32, 1), visited.generation);
    try testing.expect(visited.mark(1));
}
