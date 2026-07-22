//! Bounded physical storage for lazy DFA state identity and transitions.
//!
//! A logical DFA state is an ordered sequence of Program item IDs plus flags
//! encoded by the DFA. `Cache` appends immutable state records and their item
//! sequences, interns them through hash buckets, and confirms exact ordered
//! equality after every hash match. This preserves priority even under deliberate
//! hash collision.
//!
//! Item sequences use 16-bit storage when the Program domain permits and 32-bit
//! storage otherwise; the `Instructions` union exposes one logical iterator and
//! equality operation. State handles pack the state-table offset with DFA flags,
//! so helpers separate physical index from semantic bits.
//!
//! Transition rows begin sparse: populated `(state,key)->next` triples are hashed
//! globally without allocating a full row. Repeatedly busy rows may promote to a
//! dense bounded lookup array. Publication of either sparse entries or promoted
//! rows is transactional under allocation failure.
//!
//! All arrays allocate through one BudgetAllocator. Metrics report states, item
//! IDs, transition slots, hash storage, and exhaustion without exposing layout to
//! public API. Closure construction and matching policy remain in `dfa.zig`.

const std = @import("std");
const checked_math = @import("../../support/checked_math.zig");
const builder_program = @import("../../program/program.zig");

pub const no_transition = std.math.maxInt(u32);
pub const accepting_bit: u32 = 1 << 31;
const state_link_mask = accepting_bit - 1;
const no_state = state_link_mask;
const state_offset_mask: u32 = accepting_bit - 256;
pub const initial_bucket_count = 8;
pub const encoding_state_limit: u32 = 1 << 23;

/// Interned logical state metadata. Instruction IDs occupy a shared append-only
/// array; hash links form a bucket chain; transition_head selects sparse/promoted
/// storage when rows are not globally dense.
const State = struct {
    hash: u64,
    instruction_offset: u32,
    instruction_len: u32,
    hash_next: u32,
    transition_head: u32 = no_transition,
};

/// Linked transition entry for one populated key in a sparse state row.
const SparseTransition = struct {
    key: u32,
    destination: u32,
    next: u32,
};

const dense_transition_limit = 256;
const sparse_promotion_count = 32;
const promoted_flag: u32 = 1 << 31;
const promoted_index_mask = promoted_flag - 1;

/// Logical counts and physical capacities used by private cache diagnostics.
pub const StorageMetrics = struct {
    state_count: usize,
    state_capacity: usize,
    instruction_ids: usize,
    transition_slots: usize,
    populated_transition_slots: usize,
    dense_transition_slots: usize,
    sparse_transition_entries: usize,
    hash_buckets: usize,
    hash_bytes: usize,
};

/// Borrowed logical instruction-ID sequence independent of compact/wide storage.
pub const Instructions = union(enum) {
    compact: []const u16,
    wide: []const u32,

    pub fn len(self: Instructions) usize {
        return switch (self) {
            inline else => |values| values.len,
        };
    }

    pub fn first(self: Instructions) ?u32 {
        return switch (self) {
            inline else => |values| if (values.len == 0) null else values[0],
        };
    }

    pub fn iterator(self: Instructions) Iterator {
        return switch (self) {
            .compact => |values| .{ .compact = values },
            .wide => |values| .{ .wide = values },
        };
    }

    /// Destructive borrowed-slice iterator yielding logical u32 IDs.
    pub const Iterator = union(enum) {
        compact: []const u16,
        wide: []const u32,

        pub fn next(self: *Iterator) ?u32 {
            return switch (self.*) {
                inline else => |*values| {
                    if (values.len == 0) return null;
                    const value: u32 = values.*[0];
                    values.* = values.*[1..];
                    return value;
                },
            };
        }
    };
};

/// Append-only intern table plus adaptive transition storage for one DFA role.
/// All mutation occurs under the owning Caches exclusive lock.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    max_states: u32,
    compact_instructions: bool,
    states: std.ArrayList(State) = .empty,
    instruction_ids16: std.ArrayList(u16) = .empty,
    instruction_ids32: std.ArrayList(u32) = .empty,
    transitions: std.ArrayList(u32) = .empty,
    sparse_transitions: std.ArrayList(SparseTransition) = .empty,
    free_sparse_head: u32 = no_transition,
    promoted_transitions: std.ArrayList(u32) = .empty,
    transition_count: usize = 0,
    sparse_rows: bool = false,
    populated_transition_slots: usize = 0,
    buckets: []u32 = &.{},

    pub fn init(allocator: std.mem.Allocator, max_states: u32, instruction_count: usize) Cache {
        return .{
            .allocator = allocator,
            .max_states = max_states,
            .compact_instructions = instruction_count <= @as(usize, std.math.maxInt(u16)) + 1,
        };
    }

    pub fn deinit(self: *Cache) void {
        if (self.buckets.len != 0) self.allocator.free(self.buckets);
        self.transitions.deinit(self.allocator);
        self.sparse_transitions.deinit(self.allocator);
        self.promoted_transitions.deinit(self.allocator);
        self.instruction_ids32.deinit(self.allocator);
        self.instruction_ids16.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Cache) usize {
        return self.states.items.len;
    }

    pub fn bucketCount(self: *const Cache) usize {
        return self.buckets.len;
    }

    /// Returns a dense row for caches configured with globally dense storage.
    pub fn transitionRow(self: *const Cache, encoded: u32) []u32 {
        std.debug.assert(!self.sparse_rows);
        const start = stateIndex(encoded) * self.transition_count;
        return self.transitions.items[start..][0..self.transition_count];
    }

    /// Borrows one state's exact ordered logical item sequence.
    pub fn instructions(self: *const Cache, encoded: u32) Instructions {
        return self.instructionsForId(@intCast(stateIndex(encoded)));
    }

    fn instructionsForId(self: *const Cache, id: u32) Instructions {
        const state = self.states.items[id];
        const start: usize = state.instruction_offset;
        return if (self.compact_instructions)
            .{ .compact = self.instruction_ids16.items[start..][0..state.instruction_len] }
        else
            .{ .wide = self.instruction_ids32.items[start..][0..state.instruction_len] };
    }

    fn instructionsEqual(self: *const Cache, id: u32, values: []const u32) bool {
        const stored = self.instructionsForId(id);
        if (stored.len() != values.len) return false;
        var iterator = stored.iterator();
        for (values) |value| if (iterator.next().? != value) return false;
        return true;
    }

    /// Reads dense, promoted, or linked sparse storage and returns
    /// `no_transition` for an unknown edge.
    pub fn getTransition(self: *const Cache, source: u32, key: usize) u32 {
        if (!self.sparse_rows) return self.transitionRow(source)[key];
        var entry = self.states.items[stateIndex(source)].transition_head;
        if (entry != no_transition and entry & promoted_flag != 0) {
            const start = @as(usize, entry & promoted_index_mask) * self.transition_count;
            return self.promoted_transitions.items[start + key];
        }
        while (entry != no_transition) {
            const transition = self.sparse_transitions.items[entry];
            if (transition.key == key) return transition.destination;
            entry = transition.next;
        }
        return no_transition;
    }

    /// Publishes one previously unknown edge. A sparse row promotes atomically
    /// after its threshold, recycling old linked entries only after dense storage
    /// has been allocated successfully.
    pub fn setTransition(
        self: *Cache,
        source: u32,
        key: usize,
        destination: u32,
    ) error{OutOfMemory}!void {
        std.debug.assert(self.getTransition(source, key) == no_transition);
        if (self.sparse_rows) {
            const state = &self.states.items[stateIndex(source)];
            if (state.transition_head != no_transition and
                state.transition_head & promoted_flag != 0)
            {
                const start = @as(usize, state.transition_head & promoted_index_mask) *
                    self.transition_count;
                self.promoted_transitions.items[start + key] = destination;
            } else {
                var entry_count: usize = 0;
                var entry = state.transition_head;
                while (entry != no_transition) : (entry_count += 1)
                    entry = self.sparse_transitions.items[entry].next;
                if (entry_count == sparse_promotion_count) {
                    try self.promoteRow(state, key, destination);
                } else {
                    std.debug.assert(entry_count < sparse_promotion_count);
                    const published = SparseTransition{
                        .key = @intCast(key),
                        .destination = destination,
                        .next = state.transition_head,
                    };
                    if (self.free_sparse_head != no_transition) {
                        const reused = self.free_sparse_head;
                        self.free_sparse_head = self.sparse_transitions.items[reused].next;
                        self.sparse_transitions.items[reused] = published;
                        state.transition_head = reused;
                    } else {
                        std.debug.assert(self.sparse_transitions.items.len < promoted_flag);
                        try self.sparse_transitions.append(self.allocator, published);
                        state.transition_head = @intCast(self.sparse_transitions.items.len - 1);
                    }
                }
            }
        } else {
            self.transitionRow(source)[key] = destination;
        }
        self.populated_transition_slots +|= 1;
    }

    /// Transactionally copies one linked sparse row to dense storage, recycles its
    /// entries, and publishes the promoted row handle.
    fn promoteRow(
        self: *Cache,
        state: *State,
        key: usize,
        destination: u32,
    ) error{OutOfMemory}!void {
        const row_count = self.promoted_transitions.items.len / self.transition_count;
        if (row_count >= promoted_index_mask) return error.OutOfMemory;
        const start = self.promoted_transitions.items.len;
        try self.promoted_transitions.appendNTimes(
            self.allocator,
            no_transition,
            self.transition_count,
        );
        const row = self.promoted_transitions.items[start..][0..self.transition_count];
        var entry = state.transition_head;
        while (entry != no_transition) {
            const transition = self.sparse_transitions.items[entry];
            row[transition.key] = transition.destination;
            const released = entry;
            entry = transition.next;
            self.sparse_transitions.items[released].next = self.free_sparse_head;
            self.free_sparse_head = released;
        }
        row[key] = destination;
        state.transition_head = promoted_flag | @as(u32, @intCast(row_count));
    }

    pub fn isEmpty(self: *const Cache, encoded: u32) bool {
        return self.states.items[stateIndex(encoded)].instruction_len == 0;
    }

    /// Interns an ordered instruction sequence and derives acceptance from its
    /// Program leaves.
    pub fn intern(
        self: *Cache,
        instructions_value: []const u32,
        prog: *const builder_program.Program,
        transition_count: usize,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(instructions_value));
        return self.internHashedKnown(
            instructions_value,
            hash,
            containsMatch(instructions_value, prog),
            transition_count,
        );
    }

    /// Interns when the closure builder already knows the acceptance flag,
    /// avoiding a second Program scan.
    pub fn internKnown(
        self: *Cache,
        instructions_value: []const u32,
        accepting: bool,
        transition_count: usize,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(instructions_value));
        return self.internHashedKnown(
            instructions_value,
            hash,
            accepting,
            transition_count,
        );
    }

    /// Explicit hash input exists for collision evidence; production uses `intern`.
    pub fn internHashed(
        self: *Cache,
        instructions_value: []const u32,
        hash: u64,
        prog: *const builder_program.Program,
        transition_count: usize,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        return self.internHashedKnown(
            instructions_value,
            hash,
            containsMatch(instructions_value, prog),
            transition_count,
        );
    }

    /// Exact interning transaction: search hash chain, reserve all state/item/
    /// transition storage, append immutable data, then link into the bucket.
    fn internHashedKnown(
        self: *Cache,
        instructions_value: []const u32,
        hash: u64,
        accepting: bool,
        transition_count: usize,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        if (self.buckets.len == 0) {
            if (self.max_states == 0) return error.StateLimit;
            self.buckets = try self.allocator.alloc(u32, initial_bucket_count);
            @memset(self.buckets, no_state);
        }

        var bucket = stateBucket(hash, self.buckets.len);
        var current = self.buckets[bucket];
        while (current != no_state) {
            const state = self.states.items[current];
            if (state.hash == hash and self.instructionsEqual(current, instructions_value))
                return self.encodedState(current);
            current = state.hash_next & state_link_mask;
        }
        if (self.states.items.len >= self.max_states or
            self.states.items.len >= encoding_state_limit) return error.StateLimit;

        try self.growBuckets();
        bucket = stateBucket(hash, self.buckets.len);
        if (self.transition_count == 0) {
            self.transition_count = transition_count;
            self.sparse_rows = transition_count > dense_transition_limit;
        } else {
            std.debug.assert(self.transition_count == transition_count);
        }
        const stored_len = if (self.compact_instructions)
            self.instruction_ids16.items.len
        else
            self.instruction_ids32.items.len;
        if (instructions_value.len > std.math.maxInt(u32) or
            stored_len > std.math.maxInt(u32) - instructions_value.len)
            return error.StateLimit;
        const instruction_offset: u32 = @intCast(stored_len);
        const old_instruction_len16 = self.instruction_ids16.items.len;
        const old_instruction_len32 = self.instruction_ids32.items.len;
        if (self.compact_instructions) {
            try self.instruction_ids16.ensureUnusedCapacity(self.allocator, instructions_value.len);
            for (instructions_value) |value|
                self.instruction_ids16.appendAssumeCapacity(@intCast(value));
        } else {
            try self.instruction_ids32.appendSlice(self.allocator, instructions_value);
        }
        errdefer if (self.compact_instructions)
            self.instruction_ids16.shrinkRetainingCapacity(old_instruction_len16)
        else
            self.instruction_ids32.shrinkRetainingCapacity(old_instruction_len32);
        const id: u32 = @intCast(self.states.items.len);
        try self.states.append(self.allocator, .{
            .hash = hash,
            .instruction_offset = instruction_offset,
            .instruction_len = @intCast(instructions_value.len),
            .hash_next = self.buckets[bucket] |
                (if (accepting) accepting_bit else 0),
        });
        errdefer _ = self.states.pop();
        if (!self.sparse_rows)
            try self.transitions.appendNTimes(self.allocator, no_transition, transition_count);
        self.buckets[bucket] = id;
        return self.encodedState(id);
    }

    /// Reports logical state/item counts and physical transition/hash storage
    /// without exposing either representation to matching policy.
    pub fn metrics(self: *const Cache) StorageMetrics {
        var instruction_ids: usize = 0;
        for (self.states.items) |state| instruction_ids +|= state.instruction_len;
        return .{
            .state_count = self.states.items.len,
            .state_capacity = self.states.capacity,
            .instruction_ids = instruction_ids,
            .transition_slots = self.states.items.len *| self.transition_count,
            .populated_transition_slots = self.populated_transition_slots,
            .dense_transition_slots = self.transitions.items.len +|
                self.promoted_transitions.items.len,
            .sparse_transition_entries = self.sparse_transitions.items.len,
            .hash_buckets = self.buckets.len,
            .hash_bytes = self.buckets.len * @sizeOf(u32),
        };
    }

    /// Doubles and rebuilds hash chains from stored hashes; state IDs and encoded
    /// handles remain stable.
    fn growBuckets(self: *Cache) error{OutOfMemory}!void {
        const grown_count = checked_math.mul(self.buckets.len, 2) catch
            return error.OutOfMemory;
        if (self.states.items.len < grown_count) return;
        const grown = try self.allocator.alloc(u32, grown_count);
        @memset(grown, no_state);
        for (self.states.items, 0..) |*state, index| {
            const bucket = stateBucket(state.hash, grown.len);
            state.hash_next = (state.hash_next & accepting_bit) | grown[bucket];
            grown[bucket] = @intCast(index);
        }
        self.allocator.free(self.buckets);
        self.buckets = grown;
    }

    /// Combines stable physical state offset with the cached accepting flag.
    fn encodedState(self: *const Cache, id: u32) u32 {
        const offset = id << 8;
        return offset | (self.states.items[id].hash_next & accepting_bit);
    }
};

fn containsMatch(instructions: []const u32, prog: *const builder_program.Program) bool {
    for (instructions) |item_id| {
        const item = prog.priority_lists.items[item_id];
        if (prog.runtimeInstruction(item).opcode() == .match) return true;
    }
    return false;
}

fn stateBucket(hash: u64, bucket_count: usize) usize {
    std.debug.assert(std.math.isPowerOfTwo(bucket_count));
    return @as(usize, @truncate(hash)) & (bucket_count - 1);
}

/// Removes accepting/flag bits and recovers the physical state-table index.
pub fn stateIndex(state: u32) usize {
    return @intCast((state & state_offset_mask) >> 8);
}

fn expectInstructions(expected: []const u32, actual: Instructions) !void {
    try std.testing.expectEqual(expected.len, actual.len());
    var iterator = actual.iterator();
    for (expected) |value| try std.testing.expectEqual(value, iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "Instruction identity uses compact and wide storage without semantic drift" {
    var compact = Cache.init(std.testing.allocator, 4, @as(usize, std.math.maxInt(u16)) + 1);
    defer compact.deinit();
    const compact_values = [_]u32{ 0, std.math.maxInt(u16) };
    const compact_state = try compact.internKnown(&compact_values, false, 1);
    try expectInstructions(&compact_values, compact.instructions(compact_state));
    try std.testing.expectEqual(compact_state, try compact.internKnown(&compact_values, false, 1));

    var wide = Cache.init(std.testing.allocator, 4, @as(usize, std.math.maxInt(u16)) + 2);
    defer wide.deinit();
    const wide_values = [_]u32{ 0, @as(u32, std.math.maxInt(u16)) + 1 };
    const wide_state = try wide.internKnown(&wide_values, true, 1);
    try expectInstructions(&wide_values, wide.instructions(wide_state));
    try std.testing.expectEqual(wide_state, try wide.internKnown(&wide_values, true, 1));
}

fn allocationInstructionStorage(allocator: std.mem.Allocator, instruction_count: usize) !void {
    var cache = Cache.init(allocator, 4, instruction_count);
    defer cache.deinit();
    _ = try cache.internKnown(&.{ 1, 2, 3 }, false, 1);
}

test "Compact and wide instruction storage own every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationInstructionStorage,
        .{@as(usize, 16)},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationInstructionStorage,
        .{@as(usize, std.math.maxInt(u16)) + 2},
    );
}

fn allocationSparseTransition(allocator: std.mem.Allocator) !void {
    var cache = Cache.init(allocator, 4, 0);
    defer cache.deinit();
    const prog = builder_program.Program{ .capture_slots = 2 };
    const state = try cache.intern(&.{}, &prog, dense_transition_limit + 1);
    for (0..sparse_promotion_count + 1) |key|
        try cache.setTransition(state, key, state);
}

test "Sparse transition publication survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationSparseTransition,
        .{},
    );
}

test "Busy sparse rows promote to bounded direct lookup" {
    var cache = Cache.init(std.testing.allocator, 4, 0);
    defer cache.deinit();
    const prog = builder_program.Program{ .capture_slots = 2 };
    const state = try cache.intern(&.{}, &prog, dense_transition_limit + 1);
    for (0..sparse_promotion_count + 1) |key| try cache.setTransition(state, key, state);
    for (0..sparse_promotion_count + 1) |key|
        try std.testing.expectEqual(state, cache.getTransition(state, key));
    const snapshot = cache.metrics();
    try std.testing.expectEqual(dense_transition_limit + 1, snapshot.dense_transition_slots);
    try std.testing.expectEqual(sparse_promotion_count, snapshot.sparse_transition_entries);
}

test "Promoted sparse entries are reused by later rows" {
    var cache = Cache.init(std.testing.allocator, 4, 0);
    defer cache.deinit();
    const prog = builder_program.Program{ .capture_slots = 2 };
    const first = try cache.internHashed(&.{}, 1, &prog, dense_transition_limit + 1);
    const second = try cache.internHashed(&.{}, 2, &prog, dense_transition_limit + 1);
    for (0..sparse_promotion_count + 1) |key|
        try cache.setTransition(first, key, first);
    const high_water = cache.sparse_transitions.items.len;
    try cache.setTransition(second, 0, second);
    try std.testing.expectEqual(high_water, cache.sparse_transitions.items.len);
    try std.testing.expectEqual(second, cache.getTransition(second, 0));
}

test "Large contextual rows store only populated sparse transitions" {
    var cache = Cache.init(std.testing.allocator, 4, 0);
    defer cache.deinit();
    const prog = builder_program.Program{ .capture_slots = 2 };
    const state = try cache.intern(&.{}, &prog, dense_transition_limit + 1);
    try std.testing.expectEqual(no_transition, cache.getTransition(state, 256));
    try cache.setTransition(state, 256, state);
    try std.testing.expectEqual(state, cache.getTransition(state, 256));
    const snapshot = cache.metrics();
    try std.testing.expectEqual(@as(usize, 0), snapshot.dense_transition_slots);
    try std.testing.expectEqual(@as(usize, 1), snapshot.sparse_transition_entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.populated_transition_slots);
}
