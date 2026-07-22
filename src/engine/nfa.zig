//! Complete ordered-NFA execution for boolean, range, and pattern-ID queries.
//!
//! The executor is a Pike/Thompson simulation over Program priority items. Two
//! queues represent states before and after consuming the next byte. Adding a
//! root traverses its nested closure in published order, evaluates assertions at
//! the current absolute position, and enqueues consuming leaves. Generation
//! marks retain only the first arrival at a canonical item and position.
//!
//! A `Thread` additionally carries the candidate match start. Queue order is the
//! backtracking priority encoded by split order, so first arrival wins. For
//! unanchored search, the Program's scan loop injects starts in left-to-right
//! order. Leftmost-first may stop when an accepting path has no preferred work;
//! leftmost-longest retains the earliest start while considering later endpoints.
//!
//! `MatchIdMatcher` is a separate compact path for Set/Filtered boolean work. It
//! carries item IDs only and records every accepting pattern ID, avoiding start
//! offsets and captureless range bookkeeping.
//!
//! Complexity is bounded by `O(input positions × priority items)` because one
//! item is admitted once per generation. Scratch is allocated at initialization
//! and reused; warmed searches allocate nothing. This module imports no
//! accelerator and is the semantic fallback after every optional decline.

const std = @import("std");
const match_types = @import("../match.zig");
const checked_math = @import("../support/checked_math.zig");
const program = @import("../program/program.zig");
const closure_cursor = @import("closure_cursor.zig");
const context = @import("context.zig");
const prefix_search = @import("../literal/search.zig");

const Anchor = match_types.Anchor;
const MatchKind = match_types.MatchKind;
const Match = match_types.Match;

/// One consuming or accepting canonical item plus the candidate's absolute start.
const Thread = struct {
    item: u32,
    start: usize,
};

/// Explicit closure traversal job; `start` follows the candidate through epsilon
/// roots until a consuming thread is enqueued.
const Work = struct {
    cursor: closure_cursor.Cursor,
    start: usize,
};

const MatchIdWork = struct { cursor: closure_cursor.Cursor };

/// Preallocated ordered item queue and per-position first-arrival marks for the
/// ID-only executor.
const MatchIdQueue = struct {
    items: std.ArrayList(u32) = .empty,
    visited: closure_cursor.Visited,

    fn init(allocator: std.mem.Allocator, instruction_count: usize) !MatchIdQueue {
        var result = MatchIdQueue{ .visited = try closure_cursor.Visited.init(allocator, instruction_count) };
        errdefer result.visited.deinit(allocator);
        try result.items.ensureTotalCapacityPrecise(allocator, instruction_count);
        return result;
    }

    fn deinit(self: *MatchIdQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.visited.deinit(allocator);
        self.* = undefined;
    }

    fn clear(self: *MatchIdQueue) void {
        self.items.clearRetainingCapacity();
        self.visited.clear();
    }
};

/// Preallocated ordered range-search queue. Clearing advances the visited
/// generation while retaining all capacity.
const Queue = struct {
    threads: std.ArrayList(Thread) = .empty,
    visited: closure_cursor.Visited,

    fn init(allocator: std.mem.Allocator, instruction_count: usize) !Queue {
        var result = Queue{ .visited = try closure_cursor.Visited.init(allocator, instruction_count) };
        errdefer result.visited.deinit(allocator);
        try result.threads.ensureTotalCapacityPrecise(allocator, instruction_count);
        return result;
    }

    fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.threads.deinit(allocator);
        self.visited.deinit(allocator);
        self.* = undefined;
    }

    fn clear(self: *Queue) void {
        self.threads.clearRetainingCapacity();
        self.visited.clear();
    }

    fn mark(self: *Queue, item: u32) bool {
        return self.visited.mark(item);
    }
};

/// Captureless many-match NFA scratch. Match IDs do not need start offsets, so
/// queues and closure work carry only canonical item IDs.
pub const MatchIdMatcher = struct {
    allocator: std.mem.Allocator,
    prog: *const program.Program,
    priority: *const program.PriorityLists,
    current: MatchIdQueue,
    next: MatchIdQueue,
    work: std.ArrayList(MatchIdWork) = .empty,

    /// Preallocates both ID queues, visitation marks, and worst-case explicit
    /// closure work for this Program. After initialization, collection traversal
    /// itself cannot fail for lack of scratch.
    pub fn init(allocator: std.mem.Allocator, prog: *const program.Program) !MatchIdMatcher {
        const priority = &prog.priority_lists;
        var current = try MatchIdQueue.init(allocator, priority.items.len);
        errdefer current.deinit(allocator);
        var next = try MatchIdQueue.init(allocator, priority.items.len);
        errdefer next.deinit(allocator);
        var result = MatchIdMatcher{
            .allocator = allocator,
            .prog = prog,
            .priority = priority,
            .current = current,
            .next = next,
        };
        errdefer result.work.deinit(allocator);
        const work_capacity = checked_math.mul(priority.items.len, 2) catch
            return error.OutOfMemory;
        try result.work.ensureTotalCapacityPrecise(allocator, work_capacity);
        return result;
    }

    pub fn deinit(self: *MatchIdMatcher) void {
        self.work.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.current.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reuses storage for a Program whose item domain fits initialization
    /// capacities; no allocation or ownership transfer occurs.
    pub fn rebind(self: *MatchIdMatcher, prog: *const program.Program) void {
        const item_count = prog.priority_lists.items.len;
        std.debug.assert(item_count <= self.current.visited.marks.len);
        std.debug.assert(item_count <= self.next.visited.marks.len);
        std.debug.assert(item_count <= self.current.items.capacity);
        std.debug.assert(item_count <= self.next.items.capacity);
        std.debug.assert(item_count * 2 <= self.work.capacity);
        self.prog = prog;
        self.priority = &prog.priority_lists;
    }

    /// Whole-input convenience wrapper for ID collection from byte zero.
    pub fn collectMatchIds(
        self: *MatchIdMatcher,
        input: []const u8,
        matched: []bool,
        matched_ids: *std.ArrayList(u32),
        unanchored: bool,
    ) error{ResultTooSmall}!bool {
        return self.collectMatchIdsFrom(
            input,
            0,
            matched,
            matched_ids,
            unanchored,
        );
    }

    /// Scans from `range_start`, setting each accepting ID once. Caller-provided
    /// sparse/dense output storage avoids result allocation in the engine.
    pub fn collectMatchIdsFrom(
        self: *MatchIdMatcher,
        input: []const u8,
        range_start: usize,
        matched: []bool,
        matched_ids: *std.ArrayList(u32),
        unanchored: bool,
    ) error{ResultTooSmall}!bool {
        std.debug.assert(range_start <= input.len);
        std.debug.assert(matched_ids.capacity >= matched.len);
        self.current.clear();
        self.next.clear();
        self.addThread(
            &self.current,
            if (unanchored)
                self.priority.start_unanchored_root
            else
                self.priority.start_root,
            input,
            range_start,
            input.len,
        );

        var any = false;
        var position: usize = range_start;
        while (position <= input.len) : (position += 1) {
            self.next.clear();
            for (self.current.items.items) |item_id| {
                const item = self.priority.items[item_id];
                const instruction = self.prog.runtimeInstruction(item);
                switch (instruction.opcode()) {
                    .byte_range => {
                        std.debug.assert(position < input.len);
                        self.addThread(
                            &self.next,
                            self.prog.instructionSuccessor(instruction),
                            input,
                            position + 1,
                            input.len,
                        );
                    },
                    .match => {
                        const id = @intFromEnum(instruction.matchId());
                        if (id >= matched.len) return error.ResultTooSmall;
                        if (!matched[id]) {
                            matched[id] = true;
                            matched_ids.appendAssumeCapacity(@intCast(id));
                        }
                        any = true;
                    },
                    else => unreachable,
                }
            }
            std.mem.swap(MatchIdQueue, &self.current, &self.next);
        }
        return any;
    }

    pub fn isMatchAnyId(self: *MatchIdMatcher, input: []const u8, unanchored: bool) bool {
        return self.isMatchAnyIdFrom(input, 0, unanchored);
    }

    /// Boolean ID-only traversal from an absolute input start; stops at the first
    /// accepting leaf.
    pub fn isMatchAnyIdFrom(
        self: *MatchIdMatcher,
        input: []const u8,
        range_start: usize,
        unanchored: bool,
    ) bool {
        std.debug.assert(range_start <= input.len);
        self.current.clear();
        self.next.clear();
        self.addThread(
            &self.current,
            if (unanchored)
                self.priority.start_unanchored_root
            else
                self.priority.start_root,
            input,
            range_start,
            input.len,
        );

        var position: usize = range_start;
        while (position <= input.len) : (position += 1) {
            self.next.clear();
            for (self.current.items.items) |item_id| {
                const item = self.priority.items[item_id];
                const instruction = self.prog.runtimeInstruction(item);
                switch (instruction.opcode()) {
                    .byte_range => {
                        std.debug.assert(position < input.len);
                        self.addThread(
                            &self.next,
                            self.prog.instructionSuccessor(instruction),
                            input,
                            position + 1,
                            input.len,
                        );
                    },
                    .match => return true,
                    else => unreachable,
                }
            }
            std.mem.swap(MatchIdQueue, &self.current, &self.next);
        }
        return false;
    }

    /// Expands one root closure depth-first in priority order, enqueuing only
    /// matching byte leaves and accepting leaves for this position.
    fn addThread(
        self: *MatchIdMatcher,
        queue: *MatchIdQueue,
        initial_root: u32,
        input: []const u8,
        position: usize,
        range_end: usize,
    ) void {
        self.work.clearRetainingCapacity();
        self.work.appendAssumeCapacity(.{ .cursor = .{ .root = initial_root } });
        while (self.work.pop()) |work| {
            var cursor = work.cursor;
            while (cursor.next(self.priority)) |entry| {
                if (!queue.visited.mark(entry.id)) break;
                if (entry.item.isRoot()) {
                    if (entry.continuation) |next|
                        self.work.appendAssumeCapacity(.{ .cursor = next });
                    self.work.appendAssumeCapacity(.{ .cursor = .{ .root = entry.item.root() } });
                    break;
                }
                const instruction = self.prog.runtimeInstruction(entry.item);
                switch (instruction.opcode()) {
                    .fail => {},
                    .capture => {
                        if (entry.continuation) |next|
                            self.work.appendAssumeCapacity(.{ .cursor = next });
                        self.work.appendAssumeCapacity(.{ .cursor = .{
                            .root = self.prog.instructionSuccessor(instruction),
                        } });
                        break;
                    },
                    .empty_width => if (context.assertionsHold(
                        instruction.emptyMask(),
                        input,
                        position,
                    )) {
                        if (entry.continuation) |next|
                            self.work.appendAssumeCapacity(.{ .cursor = next });
                        self.work.appendAssumeCapacity(.{ .cursor = .{
                            .root = self.prog.instructionSuccessor(instruction),
                        } });
                        break;
                    },
                    .byte_range => if (position < range_end and
                        instruction.matchesByte(input[position]))
                    {
                        queue.items.appendAssumeCapacity(entry.id);
                    },
                    .match => queue.items.appendAssumeCapacity(entry.id),
                    .jump, .split => unreachable,
                }
            }
        }
    }
};

/// Reusable complete range-search scratch for one Program. Ordered current/next
/// queues carry candidate starts, generation marks preserve first arrival to each
/// canonical item, and explicit closure work avoids recursion while retaining
/// leftmost-first/longest semantics.
pub const Matcher = struct {
    allocator: std.mem.Allocator,
    prog: *const program.Program,
    priority: *const program.PriorityLists,
    current: Queue,
    next: Queue,
    work: std.ArrayList(Work) = .empty,

    /// Preallocates both ordered range queues, generation marks, and worst-case
    /// closure continuations for this Program, making warmed complete fallback
    /// allocation-free.
    pub fn init(allocator: std.mem.Allocator, prog: *const program.Program) !Matcher {
        const priority = &prog.priority_lists;
        var current = try Queue.init(allocator, priority.items.len);
        errdefer current.deinit(allocator);
        var next = try Queue.init(allocator, priority.items.len);
        errdefer next.deinit(allocator);
        var result = Matcher{
            .allocator = allocator,
            .prog = prog,
            .priority = priority,
            .current = current,
            .next = next,
        };
        errdefer result.work.deinit(allocator);
        const work_capacity = checked_math.mul(priority.items.len, 2) catch
            return error.OutOfMemory;
        try result.work.ensureTotalCapacityPrecise(allocator, work_capacity);
        return result;
    }

    pub fn deinit(self: *Matcher) void {
        self.work.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.current.deinit(self.allocator);
        self.* = undefined;
    }

    /// Rebinds scratch initialized for an equal or larger priority program.
    /// Queues are cleared by every operation before their next use.
    pub fn rebind(self: *Matcher, prog: *const program.Program) void {
        const item_count = prog.priority_lists.items.len;
        std.debug.assert(item_count <= self.current.visited.marks.len);
        std.debug.assert(item_count <= self.next.visited.marks.len);
        std.debug.assert(item_count <= self.current.threads.capacity);
        std.debug.assert(item_count <= self.next.threads.capacity);
        std.debug.assert(item_count * 2 <= self.work.capacity);
        self.prog = prog;
        self.priority = &prog.priority_lists;
    }

    /// Leftmost-first convenience wrapper over `findKind`.
    pub fn find(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: Anchor,
    ) error{InvalidRange}!?Match {
        return self.findKind(input, range_start, range_end, anchor, .first);
    }

    /// Executes leftmost-first or leftmost-longest search inside absolute bounds.
    /// Assertions still inspect complete input context.
    pub fn findKind(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: Anchor,
        kind: MatchKind,
    ) error{InvalidRange}!?Match {
        if (range_start > range_end or range_end > input.len) return error.InvalidRange;
        self.current.clear();
        self.next.clear();

        var position = range_start;
        var candidate: ?Match = null;
        while (position <= range_end) : (position += 1) {
            if (candidate == null and anchor == .unanchored and
                self.current.threads.items.len == 0 and self.prog.prefix.len != 0)
            {
                position = (if (self.prog.prefix_fold_ascii)
                    prefix_search.findFoldedAscii(input, position, range_end, self.prog.prefix)
                else
                    prefix_search.find(input, position, range_end, self.prog.prefix)) orelse return null;
            }
            if (candidate == null and (anchor == .unanchored or position == range_start)) {
                // A closure that produced no consuming thread can still have
                // marks in this queue. They describe the old input position
                // and must not suppress a fresh unanchored start.
                if (self.current.threads.items.len == 0) self.current.clear();
                self.addThread(
                    &self.current,
                    self.priority.start_root,
                    position,
                    input,
                    position,
                    range_end,
                );
            }

            self.next.clear();
            for (self.current.threads.items) |thread| {
                if (candidate) |found| {
                    if (kind == .longest and thread.start > found.start) break;
                }
                const item = self.priority.items[thread.item];
                const instruction = self.prog.runtimeInstruction(item);
                switch (instruction.opcode()) {
                    .byte_range => {
                        std.debug.assert(position < range_end);
                        self.addThread(
                            &self.next,
                            self.prog.instructionSuccessor(instruction),
                            thread.start,
                            input,
                            position + 1,
                            range_end,
                        );
                    },
                    .match => {
                        if (kind == .first or candidate == null or
                            thread.start < candidate.?.start or
                            (thread.start == candidate.?.start and position > candidate.?.end))
                        {
                            candidate = .{ .start = thread.start, .end = position };
                        }
                        if (kind == .first) {
                            // Remaining threads are lower priority.
                            // Higher-priority continuations are already in `next`.
                            break;
                        }
                    },
                    else => unreachable,
                }
            }

            if (candidate != null and self.next.threads.items.len == 0) return candidate;
            std.mem.swap(Queue, &self.current, &self.next);
        }
        return candidate;
    }

    /// Complete existence traversal over absolute bounds and anchor policy.
    pub fn isMatch(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: Anchor,
    ) error{InvalidRange}!bool {
        return (try self.find(input, range_start, range_end, anchor)) != null;
    }

    /// Closes one candidate root at an absolute position, preserving its start
    /// and published priority until a matching byte/match leaf enters `queue`.
    fn addThread(
        self: *Matcher,
        queue: *Queue,
        initial_root: u32,
        match_start: usize,
        input: []const u8,
        position: usize,
        range_end: usize,
    ) void {
        self.work.clearRetainingCapacity();
        self.push(.{ .root = initial_root }, match_start);
        while (self.work.pop()) |work| {
            var cursor = work.cursor;
            while (cursor.next(self.priority)) |entry| {
                if (!queue.mark(entry.id)) break;
                if (entry.item.isRoot()) {
                    if (entry.continuation) |next| self.push(next, work.start);
                    self.push(.{ .root = entry.item.root() }, work.start);
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
                        if (entry.continuation) |next| self.push(next, work.start);
                        self.push(.{ .root = self.prog.instructionSuccessor(instruction) }, work.start);
                        break;
                    },
                    .capture => {
                        if (entry.continuation) |next| self.push(next, work.start);
                        self.push(.{ .root = self.prog.instructionSuccessor(instruction) }, work.start);
                        break;
                    },
                    .byte_range => if (position < range_end and
                        instruction.matchesByte(input[position]))
                    {
                        queue.threads.appendAssumeCapacity(.{
                            .item = entry.id,
                            .start = work.start,
                        });
                    },
                    .match => queue.threads.appendAssumeCapacity(.{
                        .item = entry.id,
                        .start = work.start,
                    }),
                    .jump, .split => unreachable,
                }
            }
        }
    }

    fn push(self: *Matcher, cursor: closure_cursor.Cursor, start: usize) void {
        std.debug.assert(self.work.items.len < self.work.capacity);
        self.work.appendAssumeCapacity(.{ .cursor = cursor, .start = start });
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

test "Match slice validates manually constructed ranges" {
    try testing.expectEqualStrings("bc", (Match{ .start = 1, .end = 3 }).slice("abcd").?);
    try testing.expect((Match{ .start = 3, .end = 2 }).slice("abcd") == null);
    try testing.expect((Match{ .start = 0, .end = 5 }).slice("abcd") == null);
}

test "ID-only NFA removes start offsets from many-match scratch" {
    var values = try compilePattern("(ab|a)+c");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var ids = try MatchIdMatcher.init(testing.allocator, &values[1]);
    defer ids.deinit();
    var ranges = try Matcher.init(testing.allocator, &values[1]);
    defer ranges.deinit();

    const id_bytes = ids.current.items.capacity * @sizeOf(u32) +
        ids.next.items.capacity * @sizeOf(u32) +
        ids.work.capacity * @sizeOf(MatchIdWork) +
        (ids.current.visited.marks.len + ids.next.visited.marks.len) * @sizeOf(u32);
    const range_bytes = ranges.current.threads.capacity * @sizeOf(Thread) +
        ranges.next.threads.capacity * @sizeOf(Thread) +
        ranges.work.capacity * @sizeOf(Work) +
        (ranges.current.visited.marks.len + ranges.next.visited.marks.len) * @sizeOf(u32);
    try testing.expect(id_bytes < range_bytes);
    try testing.expect(ids.isMatchAnyId("xxabac", true));
    try testing.expect(!ids.isMatchAnyId("xxxx", true));

    var matched = [_]bool{false};
    var matched_ids: std.ArrayList(u32) = .empty;
    defer matched_ids.deinit(testing.allocator);
    try matched_ids.ensureTotalCapacityPrecise(testing.allocator, 1);
    try testing.expect(try ids.collectMatchIds("xxabac", &matched, &matched_ids, true));
    try testing.expectEqualSlices(u32, &.{0}, matched_ids.items);
}

test "Ordered priority distinguishes greedy lazy and alternation" {
    for ([_]struct { pattern: []const u8, expected: Match }{
        .{ .pattern = "a|aa", .expected = .{ .start = 0, .end = 1 } },
        .{ .pattern = "a+", .expected = .{ .start = 0, .end = 2 } },
        .{ .pattern = "a+?", .expected = .{ .start = 0, .end = 1 } },
    }) |case| {
        var values = try compilePattern(case.pattern);
        defer values[0].deinit(testing.allocator);
        defer values[1].deinit(testing.allocator);
        var matcher = try Matcher.init(testing.allocator, &values[1]);
        defer matcher.deinit();
        try testing.expectEqual(case.expected, (try matcher.find("aa", 0, 2, .unanchored)).?);
    }
}

test "Leftmost-longest keeps earliest start and furthest endpoint" {
    var values = try compilePattern("a|aa");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    try testing.expectEqual(
        Match{ .start = 1, .end = 3 },
        (try matcher.findKind("xaa", 0, 3, .unanchored, .longest)).?,
    );
}

test "Leftmost-longest retains earlier start across repeated line-end assertions" {
    var values = try compilePattern("(?m:(?:$\\n)+$)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    try testing.expectEqual(
        Match{ .start = 2, .end = 4 },
        (try matcher.findKind("\n\x00\n\n", 0, 4, .unanchored, .longest)).?,
    );
}

test "First match stops before lower-priority nullable continuation" {
    var values = try compilePattern("(?m:(?:(?:(?:\\s\\S*)?)*?)*$)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    try testing.expectEqual(
        Match{ .start = 0, .end = 1 },
        (try matcher.find("\r\n", 0, 2, .unanchored)).?,
    );
}

test "Unanchored search injects starts in leftmost order" {
    var values = try compilePattern("a+");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    try testing.expectEqual(Match{ .start = 2, .end = 4 }, (try matcher.find("xxaa", 0, 4, .unanchored)).?);
    try testing.expect((try matcher.find("xxaa", 0, 4, .start)) == null);
}

test "Assertions use complete input context outside search range" {
    var values = try compilePattern("^a");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    try testing.expect((try matcher.find("ba", 1, 2, .unanchored)) == null);
}

test "Unicode scalar matching rejects malformed byte sequences" {
    var values = try compilePattern(".");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    try testing.expect((try matcher.find("\xe0\x80\x80", 0, 3, .unanchored)) == null);
    try testing.expect((try matcher.find("\xed\xa0\x80", 0, 3, .unanchored)) == null);
    try testing.expect((try matcher.find("\xf4\x90\x80\x80", 0, 4, .unanchored)) == null);
    try testing.expect((try matcher.find("\xff", 0, 1, .unanchored)) == null);
}

test "Visited generations clear safely after rollover" {
    var values = try compilePattern("(ab|a)+c");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    matcher.current.visited.generation = std.math.maxInt(u32);
    matcher.next.visited.generation = std.math.maxInt(u32);
    @memset(matcher.current.visited.marks, std.math.maxInt(u32));
    @memset(matcher.next.visited.marks, std.math.maxInt(u32));
    try testing.expectEqual(
        Match{ .start = 2, .end = 7 },
        (try matcher.find("xxababc", 0, 7, .unanchored)).?,
    );
    try testing.expect(matcher.current.visited.generation != 0);
    try testing.expect(matcher.next.visited.generation != 0);
}

test "Iterative epsilon closure handles deep optional programs" {
    var values = try compilePattern("(?:a?){1000}");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    try testing.expectEqual(
        Match{ .start = 0, .end = 0 },
        (try matcher.find("", 0, 0, .start)).?,
    );
}

test "Warmed search performs no allocation" {
    var values = try compilePattern("(ab|a)+c");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);

    var counting = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var matcher = try Matcher.init(counting.allocator(), &values[1]);
    defer matcher.deinit();
    _ = try matcher.find("ababac", 0, 6, .unanchored);
    const allocations = counting.alloc_index;
    _ = try matcher.find("ababac", 0, 6, .unanchored);
    try testing.expectEqual(allocations, counting.alloc_index);
}
