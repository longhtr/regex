//! Compile Thompson epsilon control flow into canonical ordered priority lists.
//!
//! Runtime executors should process semantic leaves, not repeatedly interpret
//! split/jump closure. Starting from selected graph roots, this module traverses
//! epsilon instructions in preferred order and emits lists whose items are
//! either semantic graph instructions or references to another list root.
//! Publication later remaps semantic instructions to compact runtime leaves.
//!
//! A simple successor-root policy creates a root at each semantic successor and
//! is sufficient for ordinary acyclic priority flow. Nullable repetition is more
//! subtle: if a preferred empty path commits, traversing back through the loop
//! must not revive a lower-priority alternative. The dominator policy computes
//! nullable predecessor/dominator information and chooses additional roots that
//! preserve this commitment after list deduplication.
//!
//! Construction is iterative. `Stack` stores traversal continuations, per-root
//! generation marks prevent cycles, and `WorkBudget` bounds graph-dependent
//! expansion before arithmetic or memory can grow without limit. Lists are
//! flattened in deterministic priority order, marked with an end bit, and
//! interned by exact item equality. Semantic leaves are interned separately.
//!
//! The output uses contiguous list/item storage where practical and contains no
//! split or jump opcode. Queue order in every engine is therefore the same order
//! established here; reordering lists is a semantic change, not formatting.

const std = @import("std");
const checked_math = @import("../support/checked_math.zig");
const program = @import("program.zig");

const none = program.no_priority_root;
const dominator_work_per_instruction: usize = 256;
const dominator_items_per_instruction: usize = 1024;
const inline_successor_scratch_words: usize = 1024;
const inline_leaf_mapping_instructions: usize = 256;
const linear_leaf_intern_instruction_threshold: usize = 128;

/// Reverse epsilon/control-flow edge stored in adjacency-list form. `next`
/// indexes the next Edge for the same target instruction.
const Edge = struct { predecessor: u32, next: u32 };

/// Deterministic cap on dominator-analysis operations, independent of allocator
/// success, so adversarial graphs fail as an instruction limit.
const WorkBudget = struct {
    remaining: usize,

    fn spend(self: *WorkBudget) error{InstructionLimit}!void {
        if (self.remaining == 0) return error.InstructionLimit;
        self.remaining -= 1;
    }
};

/// Non-owning fixed-capacity LIFO view carved from one scratch allocation.
const Stack = struct {
    storage: []u32,
    len: usize = 0,

    fn clear(self: *Stack) void {
        self.len = 0;
    }

    fn push(self: *Stack, value: u32) void {
        std.debug.assert(self.len < self.storage.len);
        self.storage[self.len] = value;
        self.len += 1;
    }

    fn pop(self: *Stack) ?u32 {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.storage[self.len];
    }
};

/// Selects ordinary semantic-successor roots or the stronger nullable-loop
/// dominator construction requested by the compiler.
pub const RootPolicy = enum {
    successor_roots,
    nullable_dominators,
};

/// Publishes graph closure under the selected priority policy, enforcing the
/// 30-bit item domain and graph-scaled work/item limits.
pub fn build(
    allocator: std.mem.Allocator,
    graph: *const program.Graph,
    root_policy: RootPolicy,
) error{ OutOfMemory, InstructionLimit }!program.PriorityLists {
    const count = graph.instructions.len;
    if (count >= (@as(usize, 1) << 30)) return error.InstructionLimit;
    if (root_policy == .successor_roots) return buildWithoutDominators(allocator, graph);
    const work_limit = try scaledLimit(count, dominator_work_per_instruction);
    const max_items = try scaledLimit(count, dominator_items_per_instruction);
    return buildWithDominatorLimits(allocator, graph, work_limit, max_items);
}

fn scaledLimit(count: usize, factor: usize) error{InstructionLimit}!usize {
    return std.math.mul(usize, count, factor) catch error.InstructionLimit;
}

/// Computes reverse epsilon predecessors, identifies roots needed to dominate
/// nullable cycles, then materializes and interns ordered closures. Explicit
/// limits are parameters so boundary tests can qualify admission arithmetic.
fn buildWithDominatorLimits(
    allocator: std.mem.Allocator,
    graph: *const program.Graph,
    work_limit: usize,
    max_items: usize,
) error{ OutOfMemory, InstructionLimit }!program.PriorityLists {
    const count = graph.instructions.len;
    var budget = WorkBudget{ .remaining = work_limit };
    const scratch_len = std.math.mul(usize, count, 3) catch
        return error.InstructionLimit;
    const scratch = try allocator.alloc(u32, scratch_len);
    defer allocator.free(scratch);
    const roots = scratch[0..count];
    const pred_heads = scratch[count .. count * 2];
    const marks = scratch[count * 2 ..];
    @memset(roots, none);
    var root_count: u32 = 0;
    addRoot(roots, &root_count, 0);
    addRoot(roots, &root_count, @intFromEnum(graph.start_unanchored));
    addRoot(roots, &root_count, @intFromEnum(graph.start));

    const no_edge = std.math.maxInt(u32);
    @memset(pred_heads, no_edge);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    try edges.ensureTotalCapacityPrecise(allocator, count * 2);

    @memset(marks, 0);
    var generation: u32 = 1;
    const pair_count = std.math.mul(usize, count, 2) catch
        return error.InstructionLimit;
    const traversal_len = std.math.add(usize, pair_count, pair_count + 1) catch
        return error.InstructionLimit;
    const traversal = try allocator.alloc(u32, traversal_len);
    defer allocator.free(traversal);
    var work = std.ArrayList(u32){
        .items = traversal[0..0],
        .capacity = pair_count + 1,
    };

    try work.append(allocator, @intFromEnum(graph.start_unanchored));
    while (work.pop()) |initial| {
        var id = initial;
        while (true) {
            try budget.spend();
            if (marks[id] == generation) break;
            marks[id] = generation;
            const instruction = graph.instructions[id];
            switch (instruction.opcode()) {
                .split => {
                    const alternate = @intFromEnum(instruction.alternate());
                    const preferred = @intFromEnum(instruction.out());
                    for ([_]u32{ preferred, alternate }) |out| {
                        edges.appendAssumeCapacity(.{
                            .predecessor = id,
                            .next = pred_heads[out],
                        });
                        pred_heads[out] = @intCast(edges.items.len - 1);
                    }
                    work.appendAssumeCapacity(alternate);
                    id = preferred;
                },
                .byte_range, .capture, .empty_width => {
                    id = @intFromEnum(instruction.out());
                    addRoot(roots, &root_count, id);
                },
                .jump => id = @intFromEnum(instruction.out()),
                .fail, .match => break,
            }
        }
    }

    // Match the engine's successor-root snapshot. Newly discovered dominators become
    // final emission boundaries and are not examined recursively.
    const root_storage = traversal[pair_count + 1 ..][0..count];
    const reachable_storage = traversal[pair_count + 1 + count ..];
    var root_work = std.ArrayList(u32){
        .items = root_storage[0..0],
        .capacity = root_storage.len,
    };
    var reachable = std.ArrayList(u32){
        .items = reachable_storage[0..0],
        .capacity = reachable_storage.len,
    };
    for (0..count) |id| if (roots[id] != none)
        root_work.appendAssumeCapacity(@intCast(id));

    while (root_work.pop()) |root_id| {
        if (root_id == @intFromEnum(graph.start) or
            root_id == @intFromEnum(graph.start_unanchored)) continue;
        generation +%= 1;
        if (generation == 0) {
            @memset(marks, 0);
            generation = 1;
        }
        reachable.clearRetainingCapacity();
        work.clearRetainingCapacity();
        work.appendAssumeCapacity(root_id);
        while (work.pop()) |initial| {
            var id = initial;
            while (true) {
                try budget.spend();
                if (marks[id] == generation) break;
                marks[id] = generation;
                reachable.appendAssumeCapacity(id);
                if (id != root_id and roots[id] != none) break;
                const instruction = graph.instructions[id];
                switch (instruction.opcode()) {
                    .split => {
                        work.appendAssumeCapacity(@intFromEnum(instruction.alternate()));
                        id = @intFromEnum(instruction.out());
                    },
                    .jump => id = @intFromEnum(instruction.out()),
                    .byte_range, .capture, .empty_width, .fail, .match => break,
                }
            }
        }
        for (reachable.items) |id| {
            try budget.spend();
            var edge = pred_heads[id];
            while (edge != no_edge) : (edge = edges.items[edge].next) {
                try budget.spend();
                if (marks[edges.items[edge].predecessor] != generation) {
                    addRoot(roots, &root_count, id);
                    break;
                }
            }
        }
    }

    var lists = try allocator.alloc(program.PriorityList, root_count);
    errdefer allocator.free(lists);
    var item_count: usize = 0;
    for (0..count) |root_instruction| {
        const list_id = roots[root_instruction];
        if (list_id == none) continue;
        const offset = item_count;
        generation +%= 1;
        if (generation == 0) {
            @memset(marks, 0);
            generation = 1;
        }
        work.clearRetainingCapacity();
        work.appendAssumeCapacity(@intCast(root_instruction));
        while (work.pop()) |initial| {
            var id = initial;
            while (true) {
                try budget.spend();
                if (marks[id] == generation) break;
                marks[id] = generation;
                if (id != root_instruction and roots[id] != none) {
                    if (item_count == max_items) return error.InstructionLimit;
                    item_count += 1;
                    break;
                }
                const instruction = graph.instructions[id];
                switch (instruction.opcode()) {
                    .split => {
                        work.appendAssumeCapacity(@intFromEnum(instruction.alternate()));
                        id = @intFromEnum(instruction.out());
                    },
                    .jump => id = @intFromEnum(instruction.out()),
                    .byte_range, .capture, .empty_width, .fail, .match => {
                        if (item_count == max_items) return error.InstructionLimit;
                        item_count += 1;
                        break;
                    },
                }
            }
        }
        lists[list_id] = .{
            .offset = @intCast(offset),
            .len = @intCast(item_count - offset),
        };
    }

    const items = try allocator.alloc(program.PriorityItem, item_count);
    errdefer allocator.free(items);
    var write_index: usize = 0;
    for (0..count) |root_instruction| {
        if (roots[root_instruction] == none) continue;
        generation +%= 1;
        if (generation == 0) {
            @memset(marks, 0);
            generation = 1;
        }
        work.clearRetainingCapacity();
        work.appendAssumeCapacity(@intCast(root_instruction));
        while (work.pop()) |initial| {
            var id = initial;
            while (true) {
                try budget.spend();
                if (marks[id] == generation) break;
                marks[id] = generation;
                if (id != root_instruction and roots[id] != none) {
                    items[write_index] = program.PriorityItem.fromRoot(roots[id]);
                    write_index += 1;
                    break;
                }
                const instruction = graph.instructions[id];
                switch (instruction.opcode()) {
                    .split => {
                        work.appendAssumeCapacity(@intFromEnum(instruction.alternate()));
                        id = @intFromEnum(instruction.out());
                    },
                    .jump => id = @intFromEnum(instruction.out()),
                    .byte_range, .capture, .empty_width, .fail, .match => {
                        items[write_index] = program.PriorityItem.fromGraphInstruction(@enumFromInt(id));
                        write_index += 1;
                        break;
                    },
                }
            }
        }
        const emitted = lists[roots[root_instruction]];
        items[emitted.offset + emitted.len - 1] =
            items[emitted.offset + emitted.len - 1].markLast();
    }
    std.debug.assert(write_index == items.len);

    const leaves = try compactLeaves(allocator, graph, roots, items);
    errdefer allocator.free(leaves);
    return .{
        .layout = .separate,
        .lists = lists,
        .items = items,
        .leaves = leaves,
        .start_root = roots[@intFromEnum(graph.start)],
        .start_unanchored_root = roots[@intFromEnum(graph.start_unanchored)],
    };
}

/// Faster publication for graphs where semantic successors alone preserve
/// priority. Each consuming/assertion/capture successor becomes a reusable root.
fn buildWithoutDominators(
    allocator: std.mem.Allocator,
    graph: *const program.Graph,
) error{ OutOfMemory, InstructionLimit }!program.PriorityLists {
    const count = graph.instructions.len;
    const scratch_base = checked_math.mul(count, 4) catch
        return error.InstructionLimit;
    const scratch_len = checked_math.add(scratch_base, 1) catch
        return error.InstructionLimit;
    var local_scratch: [inline_successor_scratch_words]u32 = undefined;
    const scratch = if (scratch_len <= local_scratch.len)
        local_scratch[0..scratch_len]
    else
        try allocator.alloc(u32, scratch_len);
    defer if (scratch.ptr != local_scratch[0..].ptr) allocator.free(scratch);
    const roots = scratch[0..count];
    const marks = scratch[count .. count * 2];
    var work = Stack{ .storage = scratch[count * 2 ..] };
    @memset(roots, none);
    @memset(marks, 0);

    var root_count: u32 = 0;
    addRoot(roots, &root_count, 0);
    addRoot(roots, &root_count, @intFromEnum(graph.start_unanchored));
    addRoot(roots, &root_count, @intFromEnum(graph.start));

    work.push(@intFromEnum(graph.start_unanchored));
    while (work.pop()) |initial| {
        var id = initial;
        while (true) {
            if (marks[id] != 0) break;
            marks[id] = 1;
            const instruction = graph.instructions[id];
            switch (instruction.opcode()) {
                .split => {
                    work.push(@intFromEnum(instruction.alternate()));
                    id = @intFromEnum(instruction.out());
                },
                .byte_range, .capture, .empty_width => {
                    id = @intFromEnum(instruction.out());
                    addRoot(roots, &root_count, id);
                },
                .jump => id = @intFromEnum(instruction.out()),
                .fail, .match => break,
            }
        }
    }

    var generation: u32 = 1;
    var item_capacity_len: usize = 0;
    for (0..count) |root_instruction| {
        if (roots[root_instruction] == none) continue;
        generation +%= 1;
        if (generation == 0) {
            @memset(marks, 0);
            generation = 1;
        }
        work.clear();
        work.push(@intCast(root_instruction));
        while (work.pop()) |initial| {
            var id = initial;
            while (true) {
                if (marks[id] == generation) break;
                marks[id] = generation;
                if (id != root_instruction and roots[id] != none) {
                    item_capacity_len = checked_math.add(
                        item_capacity_len,
                        1,
                    ) catch return error.InstructionLimit;
                    break;
                }
                const instruction = graph.instructions[id];
                switch (instruction.opcode()) {
                    .split => {
                        work.push(@intFromEnum(instruction.alternate()));
                        id = @intFromEnum(instruction.out());
                    },
                    .jump => id = @intFromEnum(instruction.out()),
                    .byte_range, .capture, .empty_width, .fail, .match => {
                        item_capacity_len = checked_math.add(
                            item_capacity_len,
                            1,
                        ) catch return error.InstructionLimit;
                        break;
                    },
                }
            }
        }
    }
    const list_words = checked_math.mul(root_count, 2) catch
        return error.InstructionLimit;
    const storage_len = checked_math.add(list_words, item_capacity_len) catch
        return error.InstructionLimit;
    const storage = try allocator.alloc(u32, storage_len);
    errdefer allocator.free(storage);
    const list_storage = storage[0..list_words];
    const lists = @as([*]program.PriorityList, @ptrCast(list_storage.ptr))[0..root_count];
    const item_storage = storage[list_words..];
    const item_capacity = @as([*]program.PriorityItem, @ptrCast(item_storage.ptr))[0..item_capacity_len];

    var write_index: usize = 0;
    for (0..count) |root_instruction| {
        const list_id = roots[root_instruction];
        if (list_id == none) continue;
        const offset = write_index;
        generation +%= 1;
        if (generation == 0) {
            @memset(marks, 0);
            generation = 1;
        }
        work.clear();
        work.push(@intCast(root_instruction));
        while (work.pop()) |initial| {
            var id = initial;
            while (true) {
                if (marks[id] == generation) break;
                marks[id] = generation;
                if (id != root_instruction and roots[id] != none) {
                    if (write_index == item_capacity.len) return error.InstructionLimit;
                    item_capacity[write_index] = program.PriorityItem.fromRoot(roots[id]);
                    write_index += 1;
                    break;
                }
                const instruction = graph.instructions[id];
                switch (instruction.opcode()) {
                    .split => {
                        work.push(@intFromEnum(instruction.alternate()));
                        id = @intFromEnum(instruction.out());
                    },
                    .jump => id = @intFromEnum(instruction.out()),
                    .byte_range, .capture, .empty_width, .fail, .match => {
                        if (write_index == item_capacity.len) return error.InstructionLimit;
                        item_capacity[write_index] = program.PriorityItem.fromGraphInstruction(@enumFromInt(id));
                        write_index += 1;
                        break;
                    },
                }
            }
        }
        std.debug.assert(write_index > offset);
        item_capacity[write_index - 1] = item_capacity[write_index - 1].markLast();
        lists[list_id] = .{
            .offset = @intCast(offset),
            .len = @intCast(write_index - offset),
        };
    }
    std.debug.assert(write_index <= item_capacity.len);
    const used_items = item_capacity[0..write_index];
    const leaves = try compactLeaves(allocator, graph, roots, used_items);
    errdefer allocator.free(leaves);
    return .{
        .layout = .{ .contiguous = storage },
        .lists = lists,
        .items = used_items,
        .leaves = leaves,
        .start_root = roots[@intFromEnum(graph.start)],
        .start_unanchored_root = roots[@intFromEnum(graph.start_unanchored)],
    };
}

/// Replaces graph-instruction items with interned compact RuntimeInstructions.
/// Small programs use linear equality search; larger ones use a hash map while
/// still confirming exact leaf identity.
fn compactLeaves(
    allocator: std.mem.Allocator,
    graph: *const program.Graph,
    roots: []const u32,
    items: []program.PriorityItem,
) error{ OutOfMemory, InstructionLimit }![]program.RuntimeInstruction {
    const unmapped = std.math.maxInt(u32);
    var local_mapping: [inline_leaf_mapping_instructions]u32 = undefined;
    const mapping = if (graph.instructions.len <= local_mapping.len)
        local_mapping[0..graph.instructions.len]
    else
        try allocator.alloc(u32, graph.instructions.len);
    defer if (mapping.ptr != local_mapping[0..].ptr) allocator.free(mapping);
    @memset(mapping, unmapped);

    var leaves: std.ArrayList(program.RuntimeInstruction) = .empty;
    errdefer leaves.deinit(allocator);
    try leaves.ensureTotalCapacityPrecise(allocator, @min(items.len, graph.instructions.len));
    const linear_intern = graph.instructions.len <= linear_leaf_intern_instruction_threshold;
    var interned: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer interned.deinit(allocator);
    for (items) |*item| {
        if (item.isRoot()) continue;
        const original = @intFromEnum(item.graphInstruction());
        var dense = mapping[original];
        if (dense == unmapped) {
            const instruction = graph.instructions[original];
            const successor = switch (instruction.opcode()) {
                .byte_range, .empty_width, .capture => roots[@intFromEnum(instruction.out())],
                .fail, .match => 0,
                .split, .jump => unreachable,
            };
            const leaf = try program.RuntimeInstruction.fromInst(instruction, successor);
            const published: ?u32 = if (linear_intern) blk: {
                for (leaves.items, 0..) |candidate, index|
                    if (candidate.bits == leaf.bits) break :blk @intCast(index);
                break :blk null;
            } else interned.get(leaf.bits);
            if (published) |existing| {
                dense = existing;
            } else {
                dense = std.math.cast(u32, leaves.items.len) orelse
                    return error.InstructionLimit;
                leaves.appendAssumeCapacity(leaf);
                if (!linear_intern) try interned.put(allocator, leaf.bits, dense);
            }
            mapping[original] = dense;
        }
        var rewritten = program.PriorityItem.fromRuntimeInstruction(@enumFromInt(dense));
        if (item.isLast()) rewritten = rewritten.markLast();
        item.* = rewritten;
    }
    return leaves.toOwnedSlice(allocator);
}

fn addRoot(roots: []u32, count: *u32, instruction: u32) void {
    if (roots[instruction] != none) return;
    roots[instruction] = count.*;
    count.* += 1;
}

test "Priority publication interns identical leaves" {
    var instructions = [_]program.GraphInstruction{
        program.GraphInstruction.fail(),
        program.GraphInstruction.split(@enumFromInt(2), @enumFromInt(3)),
        program.GraphInstruction.byteRange(@enumFromInt(4), 'a', 'a', false),
        program.GraphInstruction.byteRange(@enumFromInt(4), 'a', 'a', false),
        program.GraphInstruction.accepting(@enumFromInt(0)),
    };
    const graph = program.Graph{
        .instructions = &instructions,
        .start = @enumFromInt(1),
        .start_unanchored = @enumFromInt(1),
        .capture_slots = 2,
    };
    var lists = try build(std.testing.allocator, &graph, .successor_roots);
    defer lists.deinit(std.testing.allocator);
    for (lists.leaves, 0..) |leaf, left|
        for (lists.leaves[left + 1 ..]) |other|
            try std.testing.expect(leaf.bits != other.bits);
}

test "Priority admission scaling rejects arithmetic overflow" {
    try std.testing.expectError(error.InstructionLimit, scaledLimit(std.math.maxInt(usize), 2));
    try std.testing.expectEqual(@as(usize, 1024), try scaledLimit(4, 256));
}

test "Nullable dominator admission limits fail cleanly" {
    var instructions = [_]program.GraphInstruction{
        program.GraphInstruction.fail(),
        program.GraphInstruction.split(@enumFromInt(2), @enumFromInt(3)),
        program.GraphInstruction.jump(@enumFromInt(3)),
        program.GraphInstruction.accepting(@enumFromInt(0)),
    };
    const graph = program.Graph{
        .instructions = &instructions,
        .start = @enumFromInt(1),
        .start_unanchored = @enumFromInt(1),
        .capture_slots = 0,
    };
    try std.testing.expectError(
        error.InstructionLimit,
        buildWithDominatorLimits(std.testing.allocator, &graph, 0, 16),
    );
    try std.testing.expectError(
        error.InstructionLimit,
        buildWithDominatorLimits(std.testing.allocator, &graph, 64, 0),
    );
}
