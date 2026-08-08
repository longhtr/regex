//! Complete ordered-NFA execution carrying capture-row identities.
//!
//! This is the capture analogue of `nfa.zig`. Each queued `Thread` contains a
//! Program item and a RowId from the copy-on-write pool. Closure traversal writes
//! the current absolute position at capture leaves, evaluates assertions, and
//! preserves preferred ordering through splits/list roots. Consuming transitions
//! retain or transfer row references into the next queue.
//!
//! Competing arrivals at one canonical item keep the first row because queue
//! order is backtracking priority. Losing rows are released immediately. In
//! leftmost-longest mode, queue generations are reset carefully when an empty
//! queue would otherwise leave stale priority marks. Exact replay additionally
//! requires acceptance at the caller-proven endpoint.
//!
//! Search initialization creates group-zero begin state and result publication
//! closes group zero at the winning endpoint. Internal sentinel slots are
//! converted to optional public slots only for the winner; the returned view
//! borrows matcher-owned result storage.
//!
//! Row sharing makes branches cheaper than copying every capture slot, but the
//! complete path remains bounded and potentially slot-heavy. It is intentionally
//! separate from the shorter captureless hot loop and is the final capture
//! fallback after OnePass/BitState decline.

const std = @import("std");
const match_types = @import("../match.zig");
const checked_math = @import("../support/checked_math.zig");
const capture_pool = @import("capture_pool.zig");
const closure_cursor = @import("closure_cursor.zig");
const context = @import("context.zig");
const prefix_search = @import("../literal/search.zig");
const program = @import("../program/program.zig");

/// Canonical consuming/accepting item paired with one owned pool reference.
const Thread = struct {
    item: u32,
    row: capture_pool.RowId,
};

/// Explicit closure job. Each queued job owns one RowId reference until it is
/// transferred, retained for a branch, or released.
const Work = struct {
    cursor: closure_cursor.Cursor,
    row: capture_pool.RowId,
};

/// Fixed-capacity ordered threads plus generation marks. Queue methods release
/// all row references they discard.
const Queue = struct {
    threads: std.ArrayList(Thread),
    visited: closure_cursor.Visited,

    fn init(thread_storage: []Thread, marks: []u32) Queue {
        std.debug.assert(thread_storage.len == marks.len);
        @memset(marks, 0);
        return .{
            .threads = .{ .items = thread_storage[0..0], .capacity = thread_storage.len },
            .visited = .{ .marks = marks },
        };
    }

    fn deinit(self: *Queue, pool: *capture_pool.Pool) void {
        self.clear(pool);
        self.* = undefined;
    }

    fn clear(self: *Queue, pool: *capture_pool.Pool) void {
        for (self.threads.items) |thread| pool.release(thread.row);
        self.threads.clearRetainingCapacity();
        self.visited.clear();
    }

    fn mark(self: *Queue, item: u32) bool {
        return self.visited.mark(item);
    }
};

/// Cumulative copy-on-write activity from the matcher-local row pool.
pub const Metrics = struct {
    row_copies: usize,
    row_copy_bytes: usize,
    rows_created: usize,
    rows_reused: usize,
};

/// Reusable complete capture-NFA state for one immutable Program. Current/next
/// queues preserve thread priority while a copy-on-write row pool carries capture
/// slots across branches; one fixed closure stack and result slice are reused by
/// both range search and exact replay.
pub const Matcher = struct {
    allocator: std.mem.Allocator,
    backing: []Thread,
    prog: *const program.Program,
    priority: *const program.PriorityLists,
    current: Queue,
    next: Queue,
    work: std.ArrayList(Work) = .empty,
    pool: capture_pool.Pool,
    result: []?usize,

    /// Allocates all fixed-capacity traversal scratch in one aligned backing
    /// block, then partitions it into current/next threads, generation marks,
    /// and closure jobs. The separate pool owns capture rows; any later failure
    /// unwinds both owners before a Matcher is published.
    pub fn init(allocator: std.mem.Allocator, prog: *const program.Program) !Matcher {
        var pool = capture_pool.Pool.init(allocator, prog.capture_slots - 2);
        errdefer pool.deinit();
        const priority = &prog.priority_lists;
        const item_count = priority.items.len;
        const pair_count = checked_math.mul(item_count, 2) catch
            return error.OutOfMemory;
        const bytes_per_item = @sizeOf(Thread) * 2 + @sizeOf(u32) * 2 + @sizeOf(Work) * 2;
        const total_bytes = checked_math.mul(item_count, bytes_per_item) catch
            return error.OutOfMemory;
        const backing_count = total_bytes / @sizeOf(Thread) +
            @intFromBool(total_bytes % @sizeOf(Thread) != 0);
        const backing = try allocator.alloc(Thread, backing_count);
        errdefer if (backing.len != 0) allocator.free(backing);
        const bytes = std.mem.sliceAsBytes(backing);
        var offset: usize = 0;

        const thread_bytes = pair_count * @sizeOf(Thread);
        const thread_storage: []Thread = @alignCast(
            std.mem.bytesAsSlice(Thread, bytes[offset .. offset + thread_bytes]),
        );
        offset += thread_bytes;
        const mark_bytes = pair_count * @sizeOf(u32);
        const mark_storage: []u32 = @alignCast(
            std.mem.bytesAsSlice(u32, bytes[offset .. offset + mark_bytes]),
        );
        offset += mark_bytes;
        const work_bytes = pair_count * @sizeOf(Work);
        const work_storage: []Work = @alignCast(
            std.mem.bytesAsSlice(Work, bytes[offset .. offset + work_bytes]),
        );
        offset += work_bytes;
        std.debug.assert(offset == total_bytes);

        const result = try allocator.alloc(?usize, prog.capture_slots);
        return .{
            .allocator = allocator,
            .backing = backing,
            .prog = prog,
            .priority = priority,
            .current = Queue.init(thread_storage[0..item_count], mark_storage[0..item_count]),
            .next = Queue.init(thread_storage[item_count..], mark_storage[item_count..]),
            .work = .{ .items = work_storage[0..0], .capacity = work_storage.len },
            .pool = pool,
            .result = result,
        };
    }

    pub fn metrics(self: *const Matcher) Metrics {
        return .{
            .row_copies = self.pool.copy_count,
            .row_copy_bytes = self.pool.copy_bytes,
            .rows_created = self.pool.created_count,
            .rows_reused = self.pool.reused_count,
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.next.deinit(&self.pool);
        self.current.deinit(&self.pool);
        if (self.backing.len != 0) self.allocator.free(self.backing);
        self.allocator.free(self.result);
        self.pool.deinit();
        self.* = undefined;
    }

    /// Complete capture search in absolute bounds under anchor and match-kind
    /// policy.
    pub fn captures(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
        kind: match_types.MatchKind,
    ) (error{ InvalidRange, OutOfMemory })!?match_types.CaptureView {
        return self.run(input, range_start, range_end, anchor, kind, false);
    }

    /// Complete anchored replay accepting only at the caller-supplied endpoint.
    pub fn capturesExact(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
    ) (error{ InvalidRange, OutOfMemory })!?match_types.CaptureView {
        return self.run(input, range_start, range_end, .start, .first, true);
    }

    /// Shared search/exact loop. `required_end` selects exact replay; otherwise
    /// the Program root and match-kind policy select range search behavior.
    fn run(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
        kind: match_types.MatchKind,
        comptime require_end: bool,
    ) (error{ InvalidRange, OutOfMemory })!?match_types.CaptureView {
        if (range_start > range_end or range_end > input.len) return error.InvalidRange;
        self.current.clear(&self.pool);
        self.next.clear(&self.pool);
        const capture_slot_base: u32 = if (require_end) 2 else 0;
        self.pool.reconfigure(self.prog.capture_slots - capture_slot_base);

        var position = range_start;
        var candidate: ?match_types.Match = null;
        while (position <= range_end) : (position += 1) {
            if (candidate == null and anchor == .unanchored and
                self.current.threads.items.len == 0 and self.prog.prefix.len != 0)
            {
                position = (if (self.prog.prefix_fold_ascii)
                    prefix_search.findFoldedAscii(input, position, range_end, self.prog.prefix)
                else
                    prefix_search.find(input, position, range_end, self.prog.prefix)) orelse {
                    self.current.clear(&self.pool);
                    self.next.clear(&self.pool);
                    return null;
                };
            }
            if (candidate == null and (anchor == .unanchored or position == range_start)) {
                // Failed closures leave position-specific marks even when no
                // consuming thread survives. Reset those marks before a fresh
                // unanchored start at a later position.
                if (self.current.threads.items.len == 0) self.current.clear(&self.pool);
                const row = try self.pool.allocEmpty();
                if (capture_slot_base == 0) self.pool.set(row, 0, position);
                try self.addThread(
                    &self.current,
                    self.priority.start_root,
                    row,
                    input,
                    position,
                    range_end,
                    capture_slot_base,
                );
            }

            self.next.clear(&self.pool);
            for (self.current.threads.items) |thread| {
                if (!require_end) if (candidate) |found| {
                    const start = self.pool.get(thread.row, 0) orelse range_start;
                    if (kind == .longest and start > found.start) break;
                };
                const item = self.priority.items[thread.item];
                const instruction = self.prog.runtimeInstruction(item);
                switch (instruction.opcode()) {
                    .byte_range => {
                        std.debug.assert(position < range_end);
                        self.pool.retain(thread.row);
                        try self.addThread(
                            &self.next,
                            self.prog.instructionSuccessor(instruction),
                            thread.row,
                            input,
                            position + 1,
                            range_end,
                            capture_slot_base,
                        );
                    },
                    .match => {
                        if (require_end) {
                            if (position != range_end) continue;
                            candidate = .{ .start = range_start, .end = position };
                            self.pool.copyOptional(self.result[2..], thread.row);
                            self.result[0] = range_start;
                            self.result[1] = position;
                            break;
                        } else {
                            const start = self.pool.get(thread.row, 0) orelse range_start;
                            const end = self.pool.get(thread.row, 1) orelse position;
                            if (kind == .first or candidate == null or start < candidate.?.start or
                                (start == candidate.?.start and end > candidate.?.end))
                            {
                                candidate = .{ .start = start, .end = end };
                                self.pool.copyOptional(self.result, thread.row);
                                self.result[0] = start;
                                self.result[1] = end;
                            }
                            if (kind == .first) break;
                        }
                    },
                    else => unreachable,
                }
            }

            if (candidate != null and self.next.threads.items.len == 0) {
                self.current.clear(&self.pool);
                return .{ .slots = self.result };
            }
            std.mem.swap(Queue, &self.current, &self.next);
        }
        self.current.clear(&self.pool);
        self.next.clear(&self.pool);
        return if (candidate != null) .{ .slots = self.result } else null;
    }

    /// Expands epsilon/list closure with explicit row ownership. Capture leaves
    /// mutate unique rows or copy shared rows; only first-arrival byte/match leaves
    /// survive in the destination queue.
    fn addThread(
        self: *Matcher,
        queue: *Queue,
        initial_root: u32,
        initial_row: capture_pool.RowId,
        input: []const u8,
        position: usize,
        range_end: usize,
        comptime capture_slot_base: u32,
    ) error{OutOfMemory}!void {
        self.work.clearRetainingCapacity();
        errdefer while (self.work.pop()) |pending| self.pool.release(pending.row);
        self.push(.{ .root = initial_root }, initial_row);
        while (self.work.pop()) |work| {
            var release_row = true;
            var cursor = work.cursor;
            while (cursor.next(self.priority)) |entry| {
                if (!queue.mark(entry.id)) break;
                if (entry.item.isRoot()) {
                    if (entry.continuation) |next| {
                        self.pool.retain(work.row);
                        self.push(next, work.row);
                    }
                    self.push(.{ .root = entry.item.root() }, work.row);
                    release_row = false;
                    break;
                }
                const instruction = self.prog.runtimeInstruction(entry.item);
                switch (instruction.opcode()) {
                    .fail => {},
                    .empty_width => if (context.assertionsHold(
                        instruction.emptyMask(),
                        input,
                        position,
                    )) {
                        if (entry.continuation) |next| {
                            self.pool.retain(work.row);
                            self.push(next, work.row);
                        }
                        self.push(.{ .root = self.prog.instructionSuccessor(instruction) }, work.row);
                        release_row = false;
                        break;
                    },
                    .capture => {
                        const raw_slot = @intFromEnum(instruction.captureSlot());
                        std.debug.assert(raw_slot >= capture_slot_base);
                        const slot = raw_slot - capture_slot_base;
                        if (self.pool.get(work.row, slot) == position) {
                            if (entry.continuation) |next| {
                                self.pool.retain(work.row);
                                self.push(next, work.row);
                            }
                            self.push(.{ .root = self.prog.instructionSuccessor(instruction) }, work.row);
                        } else if (entry.continuation) |next| {
                            const copy = self.pool.allocCopySet(
                                work.row,
                                slot,
                                position,
                            ) catch |err| {
                                self.pool.release(work.row);
                                return err;
                            };
                            self.push(next, work.row);
                            self.push(.{ .root = self.prog.instructionSuccessor(instruction) }, copy);
                        } else if (self.pool.isUnique(work.row)) {
                            self.pool.set(work.row, slot, position);
                            self.push(.{ .root = self.prog.instructionSuccessor(instruction) }, work.row);
                        } else {
                            const copy = self.pool.allocCopySet(
                                work.row,
                                slot,
                                position,
                            ) catch |err| {
                                self.pool.release(work.row);
                                return err;
                            };
                            self.pool.release(work.row);
                            self.push(.{ .root = self.prog.instructionSuccessor(instruction) }, copy);
                        }
                        release_row = false;
                        break;
                    },
                    .byte_range => if (position < range_end and
                        instruction.matchesByte(input[position]))
                    {
                        self.pool.retain(work.row);
                        queue.threads.appendAssumeCapacity(.{
                            .item = entry.id,
                            .row = work.row,
                        });
                    },
                    .match => {
                        self.pool.retain(work.row);
                        queue.threads.appendAssumeCapacity(.{
                            .item = entry.id,
                            .row = work.row,
                        });
                    },
                    .jump, .split => unreachable,
                }
            }
            if (release_row) self.pool.release(work.row);
        }
    }

    fn push(self: *Matcher, cursor: closure_cursor.Cursor, row: capture_pool.RowId) void {
        std.debug.assert(self.work.items.len < self.work.capacity);
        self.work.appendAssumeCapacity(.{ .cursor = cursor, .row = row });
    }
};

const parser = @import("../syntax/parser.zig");
const compiler = @import("../program/compiler.zig");
const testing = std.testing;

fn compilePattern(pattern: []const u8) !struct { @import("../syntax/regexp.zig").Regexp, program.Program } {
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

fn allocationCaptureSearch(allocator: std.mem.Allocator, prog: *const program.Program) !void {
    var matcher = try Matcher.init(allocator, prog);
    defer matcher.deinit();
    _ = try matcher.captures("abababc", 0, 7, .unanchored, .first);
}

test "Direct capture NFA owns every construction and growth failure" {
    var values = try compilePattern("((ab|a)+)(c)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationCaptureSearch,
        .{&values[1]},
    );
}

test "Captures include whole unmatched and excess groups safely" {
    var values = try compilePattern("(a+)(b)?");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();

    const view = (try matcher.captures("xxaa", 0, 4, .unanchored, .first)).?;
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 4 }, view.group(0).?);
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 4 }, view.group(1).?);
    try testing.expect(view.group(2) == null);
    try testing.expect(view.group(3) == null);
}

test "Leftmost-longest captures reset stale empty-queue marks" {
    var values = try compilePattern("(?m:(?:$\\n)+$)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.captures("\n\x00\n\n", 0, 4, .unanchored, .longest)).?;
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 4 }, view.group(0).?);
}

test "Nullable non-greedy repetition preserves winning capture priority" {
    var values = try compilePattern("(?U:((?:(b)?)*\\C*)*)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.capturesExact("\x00bb", 0, 3)).?;
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 3 }, view.group(1).?);
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 2 }, view.group(2).?);
}

test "Exact capture replay reaches the required located endpoint" {
    var values = try compilePattern("(a|aa)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();

    const first = (try matcher.captures("aa", 0, 2, .start, .first)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, first.group(0).?);
    const exact = (try matcher.capturesExact("aa", 0, 2)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 2 }, exact.group(0).?);
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 2 }, exact.group(1).?);
}

test "Repeated capture records the winning final iteration" {
    var values = try compilePattern("(a)+");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.captures("aa", 0, 2, .unanchored, .first)).?;
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 2 }, view.group(1).?);
}

test "Nested nullable repetition preserves first-match endpoint priority" {
    var values = try compilePattern("(?m:(?:(?:(?:\\s\\S*)?)*?)*$)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();

    const captured = (try matcher.captures("\r\n", 0, 2, .unanchored, .first)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, captured.group(0).?);
}

test "Nullable repetition commits empty priority and preserves captures" {
    var values = try compilePattern("(())*");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.captures("aaa", 0, 3, .unanchored, .first)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 0 }, view.group(0).?);
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 0 }, view.group(1).?);
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 0 }, view.group(2).?);
}

test "Iterative capture closure handles deep save chains" {
    const depth = 500;
    const pattern = try testing.allocator.alloc(u8, depth * 2 + 1);
    defer testing.allocator.free(pattern);
    @memset(pattern[0..depth], '(');
    pattern[depth] = 'a';
    @memset(pattern[depth + 1 ..], ')');

    var values = try compilePattern(pattern);
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.captures("a", 0, 1, .start, .first)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, view.group(depth).?);
}

test "Capture rows return to pool after each search" {
    var values = try compilePattern("(a|b)+c");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    _ = try matcher.captures("ababc", 0, 5, .unanchored, .first);
    try testing.expectEqual(@as(usize, 0), matcher.pool.liveRows());
}
