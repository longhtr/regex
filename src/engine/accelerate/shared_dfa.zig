//! Shared ownership and synchronization for forward, reverse, and full DFA caches.
//!
//! `Caches` contains one nonblocking reader/writer lock and three lazy slots.
//! Forward search, reverse start recovery, and full matching receive stable thirds
//! of the configured Regex-level memory budget (with deterministic remainder
//! assignment), so whichever operation runs first cannot starve another role.
//!
//! Under a shared lock, callers may use only already known transitions; physical
//! state is immutable. Missing-state construction requires the exclusive lock.
//! Lock acquisition never waits: contention returns false/null so public dispatch
//! can run matcher-local complete fallback instead of coupling request latency to
//! another thread.
//!
//! A cache that cannot complete because it exhausted construction resources may
//! be dropped under the exclusive lock. Later operations can rebuild an empty
//! partition rather than inherit permanent exhaustion. Aggregate metrics are
//! representation-stable; physical layout metrics remain private engineering
//! data. Disabled caches allocate nothing.

const std = @import("std");
const match_types = @import("../../match.zig");
const budget_allocator = @import("../../support/budget_allocator.zig");
const try_rw_lock = @import("../../support/try_rw_lock.zig");
const dfa = @import("dfa.zig");
const program = @import("../../program/program.zig");

/// Representation-stable aggregate shared-cache resource state.
pub const Metrics = struct {
    total_requested_live_bytes: usize,
    total_requested_peak_bytes: usize,
    any_exhausted: bool,
};

/// Engineering-only physical snapshot; never re-exported by the public root.
pub const PhysicalMetrics = struct {
    shared_overhead_bytes: usize,
    forward: ?dfa.Metrics,
    reverse: ?dfa.Metrics,
    full: ?dfa.Metrics,
};

/// Role index used to derive stable memory shares and select owned cache fields.
const Slot = enum { forward, reverse, full };

/// Synchronized lazy owner for forward, reverse, and full-match DFA roles.
/// One try-RW lock permits concurrent known-transition reads and exclusive role
/// construction; each role draws lazily from its stable share of the configured
/// total budget and can be discarded independently after hard failure.
pub const Caches = struct {
    max_states: u32,
    memory: budget_allocator.OptionalBudget,
    mutex: try_rw_lock.TryRwLock = .{},
    forward_cache: ?*dfa.Matcher = null,
    reverse_cache: ?*dfa.Matcher = null,
    full_cache: ?*dfa.Matcher = null,

    pub fn init(memory: budget_allocator.OptionalBudget) Caches {
        return .{
            .max_states = dfa.encoding_state_limit,
            .memory = memory,
        };
    }

    pub fn deinit(self: *Caches, allocator: std.mem.Allocator) void {
        if (self.full_cache) |engine| destroy(allocator, engine);
        if (self.reverse_cache) |engine| destroy(allocator, engine);
        if (self.forward_cache) |engine| destroy(allocator, engine);
        self.* = undefined;
    }

    pub fn enabled(self: *const Caches) bool {
        return self.max_states != 0 and self.memory != .disabled;
    }

    pub fn tryLock(self: *Caches) bool {
        return self.mutex.tryLock();
    }

    pub fn unlock(self: *Caches) void {
        self.mutex.unlock();
    }

    pub fn tryLockSharedLimited(self: *Caches, limit: u32) bool {
        return self.mutex.tryLockSharedLimited(limit);
    }

    pub fn tryLockShared(self: *Caches) bool {
        return self.mutex.tryLockShared();
    }

    pub fn unlockShared(self: *Caches) void {
        self.mutex.unlockShared();
    }

    pub fn forward(self: *const Caches) ?*dfa.Matcher {
        return self.forward_cache;
    }

    pub fn reverse(self: *const Caches) ?*dfa.Matcher {
        return self.reverse_cache;
    }

    pub fn full(self: *const Caches) ?*dfa.Matcher {
        return self.full_cache;
    }

    /// Ensures a forward leftmost-first cache while caller holds exclusive lock.
    pub fn ensureForward(
        self: *Caches,
        allocator: std.mem.Allocator,
        prog: *const program.Program,
    ) error{OutOfMemory}!*dfa.Matcher {
        return self.ensure(allocator, .forward, prog, .first);
    }

    /// Ensures a reverse longest cache used to recover the earliest forward start.
    pub fn ensureReverse(
        self: *Caches,
        allocator: std.mem.Allocator,
        prog: *const program.Program,
    ) error{OutOfMemory}!*dfa.Matcher {
        return self.ensure(allocator, .reverse, prog, .longest);
    }

    /// Ensures the independent longest cache used for exact full matching.
    pub fn ensureFull(
        self: *Caches,
        allocator: std.mem.Allocator,
        prog: *const program.Program,
    ) error{OutOfMemory}!*dfa.Matcher {
        return self.ensure(allocator, .full, prog, .longest);
    }

    /// Drops a cache that could not complete while the caller holds the
    /// exclusive cache lock. Future operations may rebuild from an empty
    /// partition instead of inheriting permanent exhaustion.
    pub fn discardForward(self: *Caches, allocator: std.mem.Allocator) void {
        self.discard(allocator, &self.forward_cache);
    }

    pub fn discardReverse(self: *Caches, allocator: std.mem.Allocator) void {
        self.discard(allocator, &self.reverse_cache);
    }

    pub fn discardFull(self: *Caches, allocator: std.mem.Allocator) void {
        self.discard(allocator, &self.full_cache);
    }

    /// Returns null instead of delaying a thread that owns the cache lock.
    pub fn tryMetrics(self: *Caches) ?Metrics {
        if (!self.tryLock()) return null;
        defer self.unlock();
        var result = Metrics{
            .total_requested_live_bytes = 0,
            .total_requested_peak_bytes = 0,
            .any_exhausted = false,
        };
        for ([_]?*dfa.Matcher{ self.forward_cache, self.reverse_cache, self.full_cache }) |cache| {
            const engine = cache orelse continue;
            const snapshot = physicalMetrics(engine);
            result.total_requested_live_bytes +|= snapshot.requested_live_bytes;
            result.total_requested_peak_bytes +|= snapshot.requested_peak_bytes;
            result.any_exhausted = result.any_exhausted or snapshot.exhausted;
        }
        return result;
    }

    /// Physical cache details for internal diagnostics only.
    pub fn tryPhysicalMetrics(self: *Caches) ?PhysicalMetrics {
        if (!self.tryLock()) return null;
        defer self.unlock();
        return .{
            .shared_overhead_bytes = 0,
            .forward = if (self.forward_cache) |cache| physicalMetrics(cache) else null,
            .reverse = if (self.reverse_cache) |cache| physicalMetrics(cache) else null,
            .full = if (self.full_cache) |cache| physicalMetrics(cache) else null,
        };
    }

    /// Allocates the role's DFA owner outside its budget wrapper, subtracts that
    /// overhead from the fixed share, initializes transactionally, and publishes
    /// the pointer only on success.
    fn ensure(
        self: *Caches,
        allocator: std.mem.Allocator,
        slot: Slot,
        prog: *const program.Program,
        kind: match_types.MatchKind,
    ) error{OutOfMemory}!*dfa.Matcher {
        const location = switch (slot) {
            .forward => &self.forward_cache,
            .reverse => &self.reverse_cache,
            .full => &self.full_cache,
        };
        if (location.*) |engine| return engine;
        if (self.max_states == 0) return error.OutOfMemory;
        const slot_memory = try self.slotMemory(slot);
        const engine = try allocator.create(dfa.Matcher);
        errdefer allocator.destroy(engine);
        engine.* = try dfa.Matcher.initWithBudget(
            allocator,
            prog,
            self.max_states,
            kind,
            slot_memory,
        );
        location.* = engine;
        return engine;
    }

    /// Each cache owns a stable third of the configured total. Remainder bytes
    /// are assigned in forward/reverse/full order. One operation can no longer
    /// consume another operation's retained-state allowance.
    fn slotMemory(self: *const Caches, slot: Slot) error{OutOfMemory}!budget_allocator.Budget {
        return switch (self.memory) {
            .disabled => error.OutOfMemory,
            .unlimited => .unlimited,
            .bytes => |total| blk: {
                const index: usize = switch (slot) {
                    .forward => 0,
                    .reverse => 1,
                    .full => 2,
                };
                const bytes = total / 3 + @intFromBool(index < total % 3);
                break :blk budget_allocator.subtractOverhead(
                    .{ .bytes = bytes },
                    @sizeOf(dfa.Matcher),
                ) orelse return error.OutOfMemory;
            },
        };
    }

    /// Unpublishes and destroys one role cache under exclusive ownership.
    fn discard(
        _: *Caches,
        allocator: std.mem.Allocator,
        location: *?*dfa.Matcher,
    ) void {
        const engine = location.* orelse return;
        location.* = null;
        destroy(allocator, engine);
    }

    fn destroy(allocator: std.mem.Allocator, engine: *dfa.Matcher) void {
        engine.deinit();
        allocator.destroy(engine);
    }

    fn physicalMetrics(cache: *const dfa.Matcher) dfa.Metrics {
        var result = cache.metrics();
        result.requested_live_bytes +|= @sizeOf(dfa.Matcher);
        result.requested_peak_bytes +|= @sizeOf(dfa.Matcher);
        return result;
    }
};
