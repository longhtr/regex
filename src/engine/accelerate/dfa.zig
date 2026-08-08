//! Lazy DFA subset construction over exact ordered-NFA closures.
//!
//! A DFA state is not an unordered mathematical set: it stores the canonical
//! Program items in priority order, because match cutoff and accepting priority
//! depend on that order. Closure traversal follows nested roots, evaluates
//! assertions using encoded context dimensions, and deduplicates first arrivals
//! before interning the exact sequence in `dfa_state_cache.zig`.
//!
//! Input bytes are mapped through Program equivalence classes. Each transition
//! advances matching byte leaves, closes their successor roots at the next
//! position/context, and records match flags. Known self-loops skip equal-byte
//! runs in portable vector blocks instead of redispatching every byte. Unknown
//! transitions are built only while the caller
//! holds exclusive cache access.
//!
//! The matcher supports several products over the same state machinery:
//! existence, endpoint/range discovery, exact full matching, count endpoints,
//! and many-match ID collection. Forward range discovery naturally yields an
//! endpoint; start recovery is composed by `execute/search.zig` with a reverse
//! Program rather than stored in every DFA thread.
//!
//! Construction is optional and bounded. Disabled memory, budget exhaustion,
//! state limits, or poor input-bytes-per-new-state productivity return typed
//! errors that dispatch converts to decline. Interned complete states and known
//! transitions remain reusable. No complete NFA is imported or invoked here.

const std = @import("std");
const match_types = @import("../../match.zig");
const budget_allocator = @import("../../support/budget_allocator.zig");
const checked_math = @import("../../support/checked_math.zig");
const context = @import("../context.zig");
const closure_cursor = @import("../closure_cursor.zig");
const state_cache = @import("dfa_state_cache.zig");
const program = @import("../../program/program.zig");

const no_transition = state_cache.no_transition;
const accepting_bit = state_cache.accepting_bit;
pub const encoding_state_limit = state_cache.encoding_state_limit;
const productivity_min_new_states: usize = 256;
const productive_bytes_per_state: usize = 10;

/// Private snapshot combining exact BudgetAllocator use, cache layout, closure
/// activity, interning effectiveness, and exhaustion.
pub const Metrics = struct {
    requested_live_bytes: usize,
    requested_peak_bytes: usize,
    state_count: usize,
    state_capacity: usize,
    instruction_ids: usize,
    transition_slots: usize,
    populated_transition_slots: usize,
    dense_transition_slots: usize,
    sparse_transition_entries: usize,
    hash_buckets: usize,
    hash_bytes: usize,
    closure_builds: usize,
    intern_calls: usize,
    intern_hits: usize,
    exhausted: bool,
};

/// Explicit priority-list closure traversal job.
const ClosureWork = struct { cursor: closure_cursor.Cursor };

/// One role-specific lazy DFA cache and its reusable closure-construction scratch.
/// SharedState supplies synchronization; this type itself does not lock.
pub const Matcher = struct {
    allocator: std.mem.Allocator,
    budget: *budget_allocator.BudgetAllocator,
    prog: *const program.Program,
    kind: match_types.MatchKind,
    context_count: usize,
    cache: state_cache.Cache,
    closure_backing: []u32,
    visited: closure_cursor.Visited,
    work: std.ArrayList(ClosureWork) = .empty,
    scratch: std.ArrayList(u32) = .empty,
    scratch_accepting: bool = false,
    start_no_context: [2]?u32 = .{ null, null },
    start_context: []u32 = &.{},

    // Lifecycle and bounded storage.

    pub fn init(
        allocator: std.mem.Allocator,
        prog: *const program.Program,
        max_states: u32,
        kind: match_types.MatchKind,
    ) !Matcher {
        return initWithBudget(allocator, prog, max_states, kind, .unlimited);
    }

    /// Allocates fixed closure scratch and a BudgetAllocator owner; DFA states and
    /// transitions are then admitted lazily under `memory` and `max_states`.
    pub fn initWithBudget(
        allocator: std.mem.Allocator,
        prog: *const program.Program,
        max_states: u32,
        kind: match_types.MatchKind,
        memory: budget_allocator.Budget,
    ) !Matcher {
        const payload_budget = budget_allocator.subtractOverhead(
            memory,
            @sizeOf(budget_allocator.BudgetAllocator),
        ) orelse return error.OutOfMemory;
        const budget = try allocator.create(budget_allocator.BudgetAllocator);
        budget.* = budget_allocator.BudgetAllocator.init(allocator, payload_budget);
        errdefer {
            std.debug.assert(budget.live == 0);
            allocator.destroy(budget);
        }
        const cache_allocator = budget.allocator();
        const item_count = prog.priority_lists.items.len;
        const backing_len = checked_math.mul(item_count, 6) catch
            return error.OutOfMemory;
        const closure_backing = try cache_allocator.alloc(u32, backing_len);
        const marks = closure_backing[0..item_count];
        const scratch_storage = closure_backing[item_count .. item_count * 2];
        const work_storage = std.mem.bytesAsSlice(
            ClosureWork,
            std.mem.sliceAsBytes(closure_backing[item_count * 2 ..]),
        );
        std.debug.assert(work_storage.len == item_count * 2);
        @memset(marks, 0);
        var result = Matcher{
            .allocator = cache_allocator,
            .budget = budget,
            .prog = prog,
            .kind = kind,
            .context_count = contextCount(prog.empty_mask_union),
            .cache = state_cache.Cache.init(cache_allocator, max_states, item_count),
            .closure_backing = closure_backing,
            .visited = .{ .marks = marks },
            .work = .{ .items = work_storage[0..0], .capacity = work_storage.len },
            .scratch = .{ .items = scratch_storage[0..0], .capacity = scratch_storage.len },
        };
        errdefer result.deinitLists();
        if (prog.uses_empty_width) {
            result.start_context = try cache_allocator.alloc(u32, result.context_count * 2);
            @memset(result.start_context, no_transition);
        }
        return result;
    }

    pub fn deinit(self: *Matcher) void {
        self.deinitLists();
        std.debug.assert(self.budget.live == 0);
        const backing_allocator = self.budget.child;
        backing_allocator.destroy(self.budget);
        self.* = undefined;
    }

    // Boolean and many-match traversal.

    /// Collects every accepting match ID reached by one many-match traversal.
    /// Use a longest-kind matcher so closure never prunes lower-priority IDs.
    pub fn collectMatchIds(
        self: *Matcher,
        input: []const u8,
        matched: []bool,
        matched_ids: *std.ArrayList(u32),
        unanchored: bool,
    ) (error{ OutOfMemory, StateLimit, ResultTooSmall })!bool {
        return self.collectMatchIdsFrom(
            input,
            0,
            matched,
            matched_ids,
            unanchored,
        );
    }

    /// Traverses from an absolute start and sets every accepting pattern ID once;
    /// caller supplies dense/sparse result storage.
    pub fn collectMatchIdsFrom(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        matched: []bool,
        matched_ids: *std.ArrayList(u32),
        unanchored: bool,
    ) (error{ OutOfMemory, StateLimit, ResultTooSmall })!bool {
        std.debug.assert(range_start <= input.len);
        std.debug.assert(self.kind == .longest);
        std.debug.assert(matched_ids.capacity >= matched.len);
        var state = try self.startState(
            input,
            range_start,
            if (unanchored) .unanchored else .start,
        );
        var any = try self.markMatchIds(state, matched, matched_ids);
        for (input[range_start..], range_start..) |byte, position| {
            state = try self.transition(state, byte, input, position + 1);
            any = (try self.markMatchIds(state, matched, matched_ids)) or any;
        }
        return any;
    }

    /// Constructing boolean traversal; may return resource/productivity errors for
    /// dispatch to treat as accelerator decline.
    pub fn isMatch(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
    ) (error{ InvalidRange, OutOfMemory, StateLimit, Unproductive })!bool {
        return self.isMatchMode(input, range_start, range_end, anchor, true, null);
    }

    /// Read-only boolean traversal using only interned states/transitions;
    /// `Unknown` means exclusive construction would be required.
    pub fn isMatchKnown(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
    ) (error{ InvalidRange, StateLimit })!bool {
        return self.isMatchMode(input, range_start, range_end, anchor, false, null) catch |err| switch (err) {
            error.InvalidRange => error.InvalidRange,
            error.StateLimit, error.OutOfMemory, error.Unproductive => error.StateLimit,
        };
    }

    /// Shared boolean traversal for known-only and constructing modes. Known-only
    /// returns `Unknown` at the first absent state/transition without mutation.
    fn isMatchMode(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
        comptime construct: bool,
        examined_bytes: ?*usize,
    ) (error{ InvalidRange, OutOfMemory, StateLimit, Unproductive })!bool {
        if (range_start > range_end or range_end > input.len) return error.InvalidRange;
        const initial_state_count = self.cache.count();
        var state = try self.startStateMode(input, range_start, anchor, construct);
        var position = range_start;
        defer {
            if (examined_bytes) |examined| examined.* = position - range_start;
        }
        if (!self.prog.uses_empty_width) {
            while (position < range_end) {
                if (state & accepting_bit != 0) return true;
                if (self.stateIsEmpty(state)) return false;
                const row = self.cache.transitionRow(state);
                const byte = input[position];
                const key = self.byteClass(byte);
                const cached = row[key];
                if (cached == state) {
                    position += 1;
                    while (position < range_end and row[self.byteClass(input[position])] == state)
                        position += 1;
                    continue;
                }
                if (cached != no_transition and cached & accepting_bit == 0 and position + 1 < range_end and
                    self.cache.transitionRow(cached)[self.byteClass(input[position + 1])] == state)
                {
                    position += 2;
                    while (position + 1 < range_end) {
                        const middle = row[self.byteClass(input[position])];
                        if (middle == no_transition or middle & accepting_bit != 0 or
                            self.cache.transitionRow(middle)[self.byteClass(input[position + 1])] != state) break;
                        position += 2;
                    }
                    continue;
                }
                state = if (cached != no_transition)
                    cached
                else
                    try self.transitionMode(
                        state,
                        byte,
                        input,
                        position + 1,
                        key,
                        construct,
                        initial_state_count,
                        position + 1 - range_start,
                        true,
                    );
                position += 1;
            }
            return state & accepting_bit != 0;
        }

        while (true) {
            if (state & accepting_bit != 0) return true;
            if (position == range_end) return false;
            const byte = input[position];
            const key = self.transitionKey(contextKey(
                self.prog.empty_mask_union,
                input,
                position + 1,
            ), byte);
            const cached = self.cache.getTransition(state, key);
            state = if (cached != no_transition)
                cached
            else
                try self.transitionMode(
                    state,
                    byte,
                    input,
                    position + 1,
                    key,
                    construct,
                    initial_state_count,
                    position + 1 - range_start,
                    true,
                );
            if (self.stateIsEmpty(state)) return false;
            position += 1;
        }
    }

    // Forward endpoint discovery.

    /// Constructs exact lazy states as needed and returns the endpoint selected
    /// by this Matcher's first/longest policy. `null` is a completed no-match;
    /// resource or productivity errors require the caller's complete fallback.
    pub fn findEnd(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
    ) (error{ InvalidRange, OutOfMemory, StateLimit, Unproductive })!?usize {
        return self.findEndMode(input, range_start, range_end, anchor, true, true);
    }

    /// Constructs as needed and returns an endpoint only when it equals the exact
    /// requested range end.
    pub fn findEndForFullMatch(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
    ) (error{ InvalidRange, OutOfMemory, StateLimit })!?usize {
        return self.findEndMode(input, range_start, range_end, .start, true, false) catch |err| switch (err) {
            error.InvalidRange => error.InvalidRange,
            error.OutOfMemory => error.OutOfMemory,
            error.StateLimit => error.StateLimit,
            error.Unproductive => unreachable,
        };
    }

    /// Read-only endpoint discovery; `Unknown` distinguishes a missing cache edge
    /// from semantic no-match.
    pub fn findEndKnown(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
    ) (error{ InvalidRange, StateLimit })!?usize {
        return self.findEndMode(input, range_start, range_end, anchor, false, false) catch |err| switch (err) {
            error.InvalidRange => error.InvalidRange,
            error.StateLimit, error.OutOfMemory, error.Unproductive => error.StateLimit,
        };
    }

    /// Scans forward for the selected endpoint while preserving ordered match
    /// cutoff. Construction mode tracks productivity of newly created states.
    fn findEndMode(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
        comptime construct: bool,
        comptime decline_unproductive: bool,
    ) (error{ InvalidRange, OutOfMemory, StateLimit, Unproductive })!?usize {
        if (range_start > range_end or range_end > input.len) return error.InvalidRange;
        const initial_state_count = self.cache.count();
        var state = try self.startStateMode(input, range_start, anchor, construct);
        var position = range_start;
        var candidate: ?usize = null;
        if (!self.prog.uses_empty_width) {
            while (true) {
                if (state & accepting_bit != 0) {
                    candidate = position;
                    if (self.firstMatchIsCommitted(state)) return candidate;
                }
                if (position == range_end or self.stateIsEmpty(state)) return candidate;
                const row = self.cache.transitionRow(state);
                const byte = input[position];
                const key = self.byteClass(byte);
                const cached = row[key];
                if (cached == state) {
                    position = skipEqualByteRun(input, position, range_end, byte);
                    while (position < range_end and row[self.byteClass(input[position])] == state)
                        position += 1;
                    if (state & accepting_bit != 0) candidate = position;
                    continue;
                }
                if (state & accepting_bit == 0 and cached != no_transition and
                    cached & accepting_bit == 0 and position + 1 < range_end and
                    self.cache.transitionRow(cached)[self.byteClass(input[position + 1])] == state)
                {
                    position += 2;
                    while (position + 1 < range_end) {
                        const middle = row[self.byteClass(input[position])];
                        if (middle == no_transition or middle & accepting_bit != 0 or
                            self.cache.transitionRow(middle)[self.byteClass(input[position + 1])] != state) break;
                        position += 2;
                    }
                    continue;
                }
                state = if (cached != no_transition)
                    cached
                else
                    try self.transitionMode(
                        state,
                        byte,
                        input,
                        position + 1,
                        key,
                        construct,
                        initial_state_count,
                        position + 1 - range_start,
                        decline_unproductive,
                    );
                position += 1;
            }
        }
        const mask = self.prog.empty_mask_union;
        if (!mask.begin_line and !mask.end_line and
            !mask.word_boundary and !mask.not_word_boundary)
        {
            // Text-only assertions differ only on the transition into absolute
            // end. Run the interior through the same cycle accelerator as the
            // context-free DFA, then handle the final contextual byte below.
            // Assertion dimensions can make transition storage sparse, so every
            // interior lookup must remain representation-independent.
            const fast_end = @min(range_end, if (input.len == 0) 0 else input.len - 1);
            while (position < fast_end) {
                if (state & accepting_bit != 0) {
                    candidate = position;
                    if (self.firstMatchIsCommitted(state)) return candidate;
                }
                if (self.stateIsEmpty(state)) return candidate;
                const byte = input[position];
                const key = self.byteClass(byte);
                const cached = self.cache.getTransition(state, key);
                if (cached == state) {
                    position = skipEqualByteRun(input, position, fast_end, byte);
                    while (position < fast_end and
                        self.cache.getTransition(state, self.byteClass(input[position])) == state)
                        position += 1;
                    if (state & accepting_bit != 0) candidate = position;
                    continue;
                }
                if (state & accepting_bit == 0 and cached != no_transition and
                    cached & accepting_bit == 0 and position + 1 < fast_end and
                    self.cache.getTransition(cached, self.byteClass(input[position + 1])) == state)
                {
                    position += 2;
                    while (position + 1 < fast_end) {
                        const middle = self.cache.getTransition(
                            state,
                            self.byteClass(input[position]),
                        );
                        if (middle == no_transition or middle & accepting_bit != 0 or
                            self.cache.getTransition(
                                middle,
                                self.byteClass(input[position + 1]),
                            ) != state) break;
                        position += 2;
                    }
                    continue;
                }
                state = if (cached != no_transition)
                    cached
                else
                    try self.transitionMode(
                        state,
                        byte,
                        input,
                        position + 1,
                        key,
                        construct,
                        initial_state_count,
                        position + 1 - range_start,
                        decline_unproductive,
                    );
                position += 1;
            }
        }
        while (true) {
            if (state & accepting_bit != 0) {
                candidate = position;
                if (self.firstMatchIsCommitted(state)) return candidate;
            }
            if (position == range_end or self.stateIsEmpty(state)) return candidate;
            const byte = input[position];
            const key = self.transitionKey(contextKey(
                self.prog.empty_mask_union,
                input,
                position + 1,
            ), byte);
            const cached = self.cache.getTransition(state, key);
            state = if (cached != no_transition)
                cached
            else
                try self.transitionMode(
                    state,
                    byte,
                    input,
                    position + 1,
                    key,
                    construct,
                    initial_state_count,
                    position + 1 - range_start,
                    decline_unproductive,
                );
            position += 1;
        }
    }

    // Reverse start recovery.

    /// Runs a constructing reverse-longest traversal from a known forward end
    /// and returns the earliest compatible absolute start. This second pass is
    /// how endpoint-only DFA state becomes a leftmost forward range.
    pub fn findStartReverse(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        match_end: usize,
    ) (error{ InvalidRange, OutOfMemory, StateLimit, Unproductive })!?usize {
        return self.findStartReverseMode(input, range_start, match_end, true);
    }

    /// Read-only reverse traversal from a known forward endpoint, returning the
    /// earliest compatible absolute start or Unknown on missing cache state.
    pub fn findStartReverseKnown(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        match_end: usize,
    ) (error{ InvalidRange, StateLimit })!?usize {
        return self.findStartReverseMode(input, range_start, match_end, false) catch |err| switch (err) {
            error.InvalidRange => error.InvalidRange,
            error.StateLimit, error.OutOfMemory, error.Unproductive => error.StateLimit,
        };
    }

    /// Runs a reverse Program from a known endpoint; returned progress is
    /// converted back to an absolute forward start.
    fn findStartReverseMode(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        match_end: usize,
        comptime construct: bool,
    ) (error{ InvalidRange, OutOfMemory, StateLimit, Unproductive })!?usize {
        std.debug.assert(self.kind == .longest);
        if (range_start > match_end or match_end > input.len) return error.InvalidRange;
        const initial_state_count = self.cache.count();
        var state = try self.startStateMode(input, match_end, .start, construct);
        var position = match_end;
        var candidate: ?usize = if (state & accepting_bit != 0) position else null;
        if (!self.prog.uses_empty_width) {
            while (position > range_start and !self.stateIsEmpty(state)) {
                position -= 1;
                const row = self.cache.transitionRow(state);
                const byte = input[position];
                const key = self.byteClass(byte);
                const cached = row[key];
                if (cached == state) {
                    position = skipEqualByteRunReverse(input, range_start, position, byte);
                    while (position > range_start and row[self.byteClass(input[position - 1])] == state)
                        position -= 1;
                    if (state & accepting_bit != 0) candidate = position;
                    continue;
                }
                if (cached != no_transition and cached & accepting_bit == 0 and
                    position > range_start and
                    self.cache.transitionRow(cached)[self.byteClass(input[position - 1])] == state)
                {
                    position -= 1;
                    while (position > range_start) {
                        const middle = row[self.byteClass(input[position - 1])];
                        if (middle == no_transition or middle & accepting_bit != 0 or
                            position - 1 == range_start or
                            self.cache.transitionRow(middle)[self.byteClass(input[position - 2])] != state) break;
                        position -= 2;
                    }
                    if (state & accepting_bit != 0) candidate = position;
                    continue;
                }
                state = if (cached != no_transition)
                    cached
                else
                    try self.transitionMode(
                        state,
                        byte,
                        input,
                        position,
                        key,
                        construct,
                        initial_state_count,
                        match_end - position,
                        true,
                    );
                if (state & accepting_bit != 0) candidate = position;
            }
            return candidate;
        }
        const mask = self.prog.empty_mask_union;
        if (!mask.begin_text and !mask.begin_line and !mask.end_line and
            !mask.word_boundary and !mask.not_word_boundary)
        {
            // End-text context can make these rows sparse even though every
            // interior transition uses the context-zero key.
            while (position > range_start and !self.stateIsEmpty(state)) {
                position -= 1;
                const byte = input[position];
                const key = self.byteClass(byte);
                const cached = self.cache.getTransition(state, key);
                if (cached == state) {
                    position = skipEqualByteRunReverse(input, range_start, position, byte);
                    while (position > range_start and
                        self.cache.getTransition(state, self.byteClass(input[position - 1])) == state)
                        position -= 1;
                    if (state & accepting_bit != 0) candidate = position;
                    continue;
                }
                if (cached != no_transition and cached & accepting_bit == 0 and
                    position > range_start and
                    self.cache.getTransition(cached, self.byteClass(input[position - 1])) == state)
                {
                    position -= 1;
                    while (position >= range_start + 2) {
                        const middle = self.cache.getTransition(
                            state,
                            self.byteClass(input[position - 1]),
                        );
                        if (middle == no_transition or middle & accepting_bit != 0 or
                            self.cache.getTransition(
                                middle,
                                self.byteClass(input[position - 2]),
                            ) != state) break;
                        position -= 2;
                    }
                    if (state & accepting_bit != 0) candidate = position;
                    continue;
                }
                state = if (cached != no_transition)
                    cached
                else
                    try self.transitionMode(
                        state,
                        byte,
                        input,
                        position,
                        key,
                        construct,
                        initial_state_count,
                        match_end - position,
                        true,
                    );
                if (state & accepting_bit != 0) candidate = position;
            }
            return candidate;
        }
        while (position > range_start and !self.stateIsEmpty(state)) {
            position -= 1;
            const byte = input[position];
            const key = self.transitionKey(contextKey(
                self.prog.empty_mask_union,
                input,
                position,
            ), byte);
            const cached = self.cache.getTransition(state, key);
            state = if (cached != no_transition)
                cached
            else
                try self.transitionMode(
                    state,
                    byte,
                    input,
                    position,
                    key,
                    construct,
                    initial_state_count,
                    match_end - position,
                    true,
                );
            if (state & accepting_bit != 0) candidate = position;
        }
        return candidate;
    }

    // Metrics and state construction.

    pub fn stateCount(self: *const Matcher) usize {
        return self.cache.count();
    }

    /// Snapshots requested cache bytes and logical storage. The caller
    /// must provide the same synchronization used for matching.
    pub fn metrics(self: *const Matcher) Metrics {
        const storage = self.cache.metrics();
        var populated_starts: usize = 0;
        if (self.prog.uses_empty_width) {
            for (self.start_context) |state|
                populated_starts += @intFromBool(state != no_transition);
        } else {
            for (self.start_no_context) |state|
                populated_starts += @intFromBool(state != null);
        }
        const closure_builds = storage.populated_transition_slots +| populated_starts;
        return .{
            .requested_live_bytes = self.budget.live +| @sizeOf(budget_allocator.BudgetAllocator),
            .requested_peak_bytes = self.budget.peak +| @sizeOf(budget_allocator.BudgetAllocator),
            .state_count = storage.state_count,
            .state_capacity = storage.state_capacity,
            .instruction_ids = storage.instruction_ids,
            .transition_slots = storage.transition_slots,
            .populated_transition_slots = storage.populated_transition_slots,
            .dense_transition_slots = storage.dense_transition_slots,
            .sparse_transition_entries = storage.sparse_transition_entries,
            .hash_buckets = storage.hash_buckets,
            .hash_bytes = storage.hash_bytes,
            .closure_builds = closure_builds,
            .intern_calls = closure_builds,
            .intern_hits = closure_builds -| storage.state_count,
            .exhausted = self.budget.exhausted,
        };
    }

    fn byteClass(self: *const Matcher, byte: u8) usize {
        return self.prog.byteClasses()[byte];
    }

    fn transitionKey(self: *const Matcher, context_key: u6, byte: u8) usize {
        return @as(usize, context_key) * self.prog.byte_class_count + self.byteClass(byte);
    }

    /// Retrieves a context-specific start state or constructs it when mode
    /// permits. Anchored/unanchored roots have independent entries.
    fn startStateMode(
        self: *Matcher,
        input: []const u8,
        position: usize,
        anchor: match_types.Anchor,
        comptime construct: bool,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        if (construct) return self.startState(input, position, anchor);
        const cache_index: usize = if (anchor == .start) 1 else 0;
        if (self.prog.uses_empty_width) {
            const key = contextKey(self.prog.empty_mask_union, input, position);
            const cached = self.start_context[cache_index * self.context_count + key];
            return if (cached == no_transition) error.StateLimit else cached;
        }
        return self.start_no_context[cache_index] orelse error.StateLimit;
    }

    /// Constructs and memoizes a missing anchored/unanchored start closure for the
    /// current assertion context.
    fn startState(
        self: *Matcher,
        input: []const u8,
        position: usize,
        anchor: match_types.Anchor,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        const cache_index: usize = if (anchor == .start) 1 else 0;
        var contextual_index: usize = 0;
        if (self.prog.uses_empty_width) {
            const key = contextKey(self.prog.empty_mask_union, input, position);
            contextual_index = cache_index * self.context_count + key;
            const cached = self.start_context[contextual_index];
            if (cached != no_transition) return cached;
        } else if (self.start_no_context[cache_index]) |cached| return cached;
        self.beginClosure();
        const start_root = if (anchor == .start)
            self.prog.priority_lists.start_root
        else
            self.prog.priority_lists.start_unanchored_root;
        _ = self.addClosure(start_root, input, position);
        const state = try self.internScratch();
        if (self.prog.uses_empty_width)
            self.start_context[contextual_index] = state
        else
            self.start_no_context[cache_index] = state;
        return state;
    }

    /// Looks up a `(state, context, byte-class)` edge and optionally constructs
    /// the exact successor closure.
    fn transitionMode(
        self: *Matcher,
        state_id: u32,
        byte: u8,
        input: []const u8,
        next_position: usize,
        key: usize,
        comptime construct: bool,
        initial_state_count: usize,
        examined_bytes: usize,
        comptime decline_unproductive: bool,
    ) (error{ OutOfMemory, StateLimit, Unproductive })!u32 {
        if (!construct) return error.StateLimit;
        const destination = try self.constructTransition(
            state_id,
            byte,
            input,
            next_position,
            key,
        );
        const new_states = self.cache.count() -| initial_state_count;
        if (decline_unproductive and new_states >= productivity_min_new_states and
            examined_bytes < new_states *| productive_bytes_per_state)
            return error.Unproductive;
        return destination;
    }

    /// Returns a cached transition or constructs and publishes its successor.
    fn transition(
        self: *Matcher,
        state_id: u32,
        byte: u8,
        input: []const u8,
        next_position: usize,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        const context_key = if (self.prog.uses_empty_width)
            contextKey(self.prog.empty_mask_union, input, next_position)
        else
            0;
        const key = self.transitionKey(context_key, byte);
        const cached = self.cache.getTransition(state_id, key);
        if (cached != no_transition) return cached;
        return self.constructTransition(state_id, byte, input, next_position, key);
    }

    /// Advances every ordered item through a representative class byte, closes
    /// unique successors at the next context, interns the sequence, then publishes
    /// the cache edge.
    fn constructTransition(
        self: *Matcher,
        state_id: u32,
        byte: u8,
        input: []const u8,
        next_position: usize,
        key: usize,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        std.debug.assert(self.cache.getTransition(state_id, key) == no_transition);
        self.beginClosure();
        var source = self.cache.instructions(state_id).iterator();
        while (source.next()) |item_id| {
            const item = self.prog.priority_lists.items[item_id];
            const instruction = self.prog.runtimeInstruction(item);
            if (instruction.opcode() == .match) {
                if (self.kind == .first) break;
                continue;
            }
            std.debug.assert(instruction.opcode() == .byte_range);
            if (instruction.matchesByte(byte) and
                self.addClosure(self.prog.instructionSuccessor(instruction), input, next_position)) break;
        }
        const destination = try self.internScratch();
        try self.cache.setTransition(state_id, key, destination);
        return destination;
    }

    /// Resets closure scratch and advances first-arrival generation without
    /// releasing retained capacity.
    fn beginClosure(self: *Matcher) void {
        self.scratch.clearRetainingCapacity();
        self.scratch_accepting = false;
        self.work.clearRetainingCapacity();
        self.visited.clear();
    }

    /// Expands one root through ordered priority lists into consuming/match
    /// scratch. Explicit continuation jobs preserve depth-first branch order and
    /// generation marks keep only first arrivals; under first-match policy an
    /// accepting leaf clears lower-priority work and returns true to its caller.
    fn addClosure(
        self: *Matcher,
        initial_root: u32,
        input: []const u8,
        position: usize,
    ) bool {
        self.work.appendAssumeCapacity(.{ .cursor = .{ .root = initial_root } });
        while (self.work.pop()) |work| {
            var cursor = work.cursor;
            while (cursor.next(&self.prog.priority_lists)) |entry| {
                if (!self.visited.mark(entry.id)) break;
                if (entry.item.isRoot()) {
                    if (entry.continuation) |next|
                        self.work.appendAssumeCapacity(.{ .cursor = next });
                    self.work.appendAssumeCapacity(.{
                        .cursor = .{ .root = entry.item.root() },
                    });
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
                    .byte_range => self.scratch.appendAssumeCapacity(entry.id),
                    .match => {
                        self.scratch.appendAssumeCapacity(entry.id);
                        self.scratch_accepting = true;
                        if (self.kind == .first) {
                            self.work.clearRetainingCapacity();
                            return true;
                        }
                    },
                    .jump, .split => unreachable,
                }
            }
        }
        return false;
    }

    /// Interns the current ordered closure and updates hit/build diagnostics.
    fn internScratch(self: *Matcher) (error{ OutOfMemory, StateLimit })!u32 {
        return self.cache.internKnown(
            self.scratch.items,
            self.scratch_accepting,
            self.context_count * @as(usize, self.prog.byte_class_count),
        );
    }

    /// Test seam for interning the current closure under an explicit hash.
    /// Cache equality still compares the full ordered sequence, proving a hash
    /// collision cannot change priority or state identity.
    fn internScratchHashed(
        self: *Matcher,
        hash: u64,
    ) (error{ OutOfMemory, StateLimit })!u32 {
        return self.cache.internHashed(
            self.scratch.items,
            hash,
            self.prog,
            self.context_count * @as(usize, self.prog.byte_class_count),
        );
    }

    fn stateIsEmpty(self: *const Matcher, state: u32) bool {
        return self.cache.isEmpty(state);
    }

    /// In first-match mode, a match at the head of the ordered DFA state has
    /// no higher-priority consuming path left. Its endpoint is final now;
    /// continuing the search can only scan irrelevant suffix bytes.
    fn firstMatchIsCommitted(self: *const Matcher, state: u32) bool {
        if (self.kind != .first or state & accepting_bit == 0) return false;
        const item_id = self.cache.instructions(state).first() orelse return false;
        const item = self.prog.priority_lists.items[item_id];
        return self.prog.runtimeInstruction(item).opcode() == .match;
    }

    /// Extracts accepting IDs from one ordered DFA state into caller-owned result
    /// bits/list, preserving each ID once.
    fn markMatchIds(
        self: *const Matcher,
        state: u32,
        matched: []bool,
        matched_ids: *std.ArrayList(u32),
    ) error{ResultTooSmall}!bool {
        if (state & accepting_bit == 0) return false;
        var any = false;
        var instructions = self.cache.instructions(state).iterator();
        while (instructions.next()) |item_id| {
            const item = self.prog.priority_lists.items[item_id];
            const instruction = self.prog.runtimeInstruction(item);
            if (instruction.opcode() != .match) continue;
            const id = @intFromEnum(instruction.matchId());
            if (id >= matched.len) return error.ResultTooSmall;
            if (!matched[id]) {
                matched[id] = true;
                matched_ids.appendAssumeCapacity(@intCast(id));
            }
            any = true;
        }
        return any;
    }

    fn deinitLists(self: *Matcher) void {
        if (self.start_context.len != 0) self.allocator.free(self.start_context);
        self.cache.deinit();
        if (self.closure_backing.len != 0) self.allocator.free(self.closure_backing);
    }
};

// Empty-width context encoding.

/// Number of distinct assertion-context keys needed by this Program. Dimensions
/// absent from the reachable mask are omitted rather than multiplying states.
fn contextCount(mask: program.EmptyMask) usize {
    const word = mask.word_boundary or mask.not_word_boundary;
    var bits: u4 = 0;
    bits += @intFromBool(mask.begin_text);
    bits += @intFromBool(mask.end_text);
    bits += @as(u4, @intFromBool(mask.begin_line)) * 2;
    bits += @as(u4, @intFromBool(mask.end_line)) * 2;
    bits += @as(u4, @intFromBool(word)) * 2;
    return @as(usize, 1) << bits;
}

/// Encodes only assertion dimensions reachable in this Program: begin/end,
/// previous newline/word, and next newline/word. Irrelevant dimensions collapse
/// to one key and avoid duplicate DFA states.
fn contextKey(mask: program.EmptyMask, input: []const u8, position: usize) u6 {
    const word = mask.word_boundary or mask.not_word_boundary;
    const previous: ?u8 = if (mask.begin_line or word)
        if (position > 0) input[position - 1] else null
    else
        null;
    const next: ?u8 = if (mask.end_line or word)
        if (position < input.len) input[position] else null
    else
        null;
    var key: u6 = 0;
    var shift: u3 = 0;
    if (mask.begin_text) {
        key |= @as(u6, @intFromBool(position == 0)) << shift;
        shift += 1;
    }
    if (mask.end_text) {
        key |= @as(u6, @intFromBool(position == input.len)) << shift;
        shift += 1;
    }
    if (mask.begin_line) {
        key |= @as(u6, @intFromBool(position == 0)) << shift;
        shift += 1;
        key |= @as(u6, @intFromBool(previous == '\n')) << shift;
        shift += 1;
    }
    if (mask.end_line) {
        key |= @as(u6, @intFromBool(position == input.len)) << shift;
        shift += 1;
        key |= @as(u6, @intFromBool(next == '\n')) << shift;
        shift += 1;
    }
    if (word) {
        key |= @as(u6, @intFromBool(isWord(previous))) << shift;
        shift += 1;
        key |= @as(u6, @intFromBool(isWord(next))) << shift;
    }
    return key;
}

const word_bytes: [256]bool = blk: {
    var values: [256]bool = @splat(false);
    for ('0'..'9' + 1) |byte| values[byte] = true;
    for ('A'..'Z' + 1) |byte| values[byte] = true;
    for ('a'..'z' + 1) |byte| values[byte] = true;
    values['_'] = true;
    break :blk values;
};

fn isWord(byte: ?u8) bool {
    return if (byte) |value| word_bytes[value] else false;
}

// Module-local qualification tests.

const parser = @import("../../syntax/parser.zig");
const compiler = @import("../../program/compiler.zig");
/// Advances over the nonempty run beginning at `position`. The caller has
/// already proven `byte` self-loops in the current state; stopping at a different
/// byte merely returns to ordinary class dispatch and cannot skip acceptance.
fn skipEqualByteRun(input: []const u8, position: usize, end: usize, byte: u8) usize {
    std.debug.assert(position < end and input[position] == byte);
    const Vector = @Vector(16, u8);
    const wanted: Vector = @splat(byte);
    var cursor = position + 1;
    while (cursor + @sizeOf(Vector) <= end) : (cursor += @sizeOf(Vector)) {
        const block: Vector = input[cursor..][0..@sizeOf(Vector)].*;
        if (!@reduce(.And, block == wanted)) break;
    }
    while (cursor < end and input[cursor] == byte) cursor += 1;
    return cursor;
}

/// Reverse counterpart of `skipEqualByteRun`. `position` is the byte just
/// consumed; the function scans the still-unconsumed prefix `[start, position)`.
fn skipEqualByteRunReverse(input: []const u8, start: usize, position: usize, byte: u8) usize {
    const Vector = @Vector(16, u8);
    const wanted: Vector = @splat(byte);
    var cursor = position;
    while (cursor - start >= @sizeOf(Vector)) {
        const block: Vector = input[cursor - @sizeOf(Vector) ..][0..@sizeOf(Vector)].*;
        if (!@reduce(.And, block == wanted)) break;
        cursor -= @sizeOf(Vector);
    }
    while (cursor > start and input[cursor - 1] == byte) cursor -= 1;
    return cursor;
}

const testing = std.testing;

fn compilePattern(pattern: []const u8) !struct { @import("../../syntax/regexp.zig").Regexp, program.Program } {
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

test "DFA context dimensions include only reachable assertion kinds" {
    try testing.expectEqual(@as(usize, 1), contextCount(.{}));
    try testing.expectEqual(@as(usize, 2), contextCount(.{ .begin_text = true }));
    try testing.expectEqual(@as(usize, 4), contextCount(.{ .word_boundary = true }));
    try testing.expectEqual(@as(usize, 4), contextCount(.{ .begin_line = true }));
    try testing.expectEqual(@as(usize, 16), contextCount(.{
        .end_line = true,
        .not_word_boundary = true,
    }));

    var values = try compilePattern("^a$");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1], 1000, .first);
    defer matcher.deinit();
    try testing.expectEqual(@as(usize, 4), matcher.context_count);
    try testing.expect(try matcher.isMatch("a", 0, 1, .start));
    const metrics = matcher.metrics();
    try testing.expect(metrics.transition_slots > 0);
    try testing.expectEqual(metrics.hash_buckets * @sizeOf(u32), metrics.hash_bytes);
    try testing.expectEqual(
        @as(usize, 0),
        metrics.transition_slots % (matcher.context_count * values[1].byte_class_count),
    );
}

test "Known traversal reuses contextual start states" {
    var values = try compilePattern("\\b[a-z]+\\b");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1], 1000, .first);
    defer matcher.deinit();

    const input = " word ";
    try testing.expectEqual(
        @as(?usize, 5),
        try matcher.findEnd(input, 1, input.len, .unanchored),
    );
    try testing.expectEqual(
        @as(?usize, 5),
        try matcher.findEndKnown(input, 1, input.len, .unanchored),
    );
}

test "Text assertion acceleration supports sparse Unicode transition rows" {
    for ([_][]const u8{
        "^(?:\\p{^Nd}+)$",
        "^(?:\\P{Nd}+)$",
    }) |pattern| {
        var values = try compilePattern(pattern);
        defer values[0].deinit(testing.allocator);
        defer values[1].deinit(testing.allocator);
        var matcher = try Matcher.init(testing.allocator, &values[1], 1000, .first);
        defer matcher.deinit();

        try testing.expectEqual(
            @as(?usize, null),
            try matcher.findEnd("a1", 0, 2, .unanchored),
        );
        try testing.expectEqual(
            @as(?usize, 3),
            try matcher.findEnd("abc", 0, 3, .unanchored),
        );
        try testing.expect(matcher.cache.sparse_rows);
        try testing.expectEqual(
            @as(?usize, null),
            try matcher.findEndKnown("a1", 0, 2, .unanchored),
        );
        try testing.expectEqual(
            @as(?usize, 3),
            try matcher.findEndKnown("abc", 0, 3, .unanchored),
        );
    }
}

test "Known-transition DFA readers are concurrent and physically read-only" {
    var values = try compilePattern("(ab|a)+c");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1], 1000, .first);
    defer matcher.deinit();

    const matching = "xxababc";
    const rejecting = "xxababd";
    try testing.expect(try matcher.isMatch(matching, 0, matching.len, .unanchored));
    try testing.expect(!try matcher.isMatch(rejecting, 0, rejecting.len, .unanchored));
    try testing.expect((try matcher.findEnd(matching, 0, matching.len, .unanchored)) != null);
    try testing.expect((try matcher.findEnd(rejecting, 0, rejecting.len, .unanchored)) == null);
    const before = matcher.metrics();

    const Reader = struct {
        engine: *Matcher,
        matching: []const u8,
        rejecting: []const u8,
        failed: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            for (0..2000) |_| {
                const found = self.engine.isMatchKnown(
                    self.matching,
                    0,
                    self.matching.len,
                    .unanchored,
                ) catch {
                    self.failed.store(true, .release);
                    return;
                };
                const absent = self.engine.isMatchKnown(
                    self.rejecting,
                    0,
                    self.rejecting.len,
                    .unanchored,
                ) catch {
                    self.failed.store(true, .release);
                    return;
                };
                const endpoint = self.engine.findEndKnown(
                    self.matching,
                    0,
                    self.matching.len,
                    .unanchored,
                ) catch {
                    self.failed.store(true, .release);
                    return;
                };
                if (!found or absent or endpoint != @as(?usize, self.matching.len)) {
                    self.failed.store(true, .release);
                    return;
                }
            }
        }
    };

    var failed = std.atomic.Value(bool).init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Reader.run, .{Reader{
        .engine = &matcher,
        .matching = matching,
        .rejecting = rejecting,
        .failed = &failed,
    }});
    for (threads) |thread| thread.join();

    try testing.expect(!failed.load(.acquire));
    try testing.expectEqualDeep(before, matcher.metrics());
}

test "DFA existence agrees on priority loops assertions and malformed bytes" {
    for ([_]struct { pattern: []const u8, input: []const u8, expected: bool }{
        .{ .pattern = "[a-z]+z", .input = "xxxxz", .expected = true },
        .{ .pattern = "(ab|a)+c", .input = "xxababc", .expected = true },
        .{ .pattern = "^a", .input = "ba", .expected = false },
        .{ .pattern = ".", .input = "\xff", .expected = false },
        .{ .pattern = "a*", .input = "", .expected = true },
    }) |case| {
        var values = try compilePattern(case.pattern);
        defer values[0].deinit(testing.allocator);
        defer values[1].deinit(testing.allocator);
        var matcher = try Matcher.init(testing.allocator, &values[1], 1000, .first);
        defer matcher.deinit();
        try testing.expectEqual(case.expected, try matcher.isMatch(case.input, 0, case.input.len, .unanchored));
    }
}

test "Start-anchored DFA existence stops after the first rejecting byte" {
    var values = try compilePattern("^a[bc]+");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1], 1000, .first);
    defer matcher.deinit();

    var input: [64 * 1024]u8 = @splat('x');
    var examined: usize = input.len;
    try testing.expect(!try matcher.isMatchMode(
        &input,
        0,
        input.len,
        .start,
        true,
        &examined,
    ));
    try testing.expect(examined <= 1);
}

test "Forward endpoint plus longest reverse recovers leftmost start" {
    var forward_values = try compilePattern("a|ba");
    defer forward_values[0].deinit(testing.allocator);
    defer forward_values[1].deinit(testing.allocator);
    var forward = try Matcher.init(testing.allocator, &forward_values[1], 1000, .first);
    defer forward.deinit();
    const end = (try forward.findEnd("ba", 0, 2, .unanchored)).?;
    try testing.expectEqual(@as(usize, 2), end);

    var reverse = try compiler.compile(testing.allocator, &forward_values[0], .{
        .encoding = .utf8,
        .max_instructions = 100_000,
        .reverse = true,
    });
    defer reverse.deinit(testing.allocator);
    var backward = try Matcher.init(testing.allocator, &reverse, 1000, .longest);
    defer backward.deinit();
    try testing.expectEqual(@as(?usize, 0), try backward.findStartReverse("ba", 0, end));
}

fn allocationSearch(
    allocator: std.mem.Allocator,
    prog: *const program.Program,
    input: []const u8,
) !void {
    var matcher = try Matcher.init(allocator, prog, 1000, .first);
    defer matcher.deinit();
    _ = try matcher.isMatch(input, 0, input.len, .unanchored);
}

test "DFA construction and state growth own every allocation failure" {
    var values = try compilePattern("a[ab]{20}b");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationSearch,
        .{ &values[1], "aaaaaaaaaaaaaaaaaaaaab" },
    );

    var probe = try Matcher.init(testing.allocator, &values[1], 1000, .first);
    defer probe.deinit();
    try testing.expect(try probe.isMatch("aaaaaaaaaaaaaaaaaaaaab", 0, 22, .unanchored));
    try testing.expect(probe.cache.bucketCount() > state_cache.initial_bucket_count);
}

test "DFA known-transition readers never construct cache state" {
    var values = try compilePattern("(ab|a)+c");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var forward = try Matcher.init(testing.allocator, &values[1], 1000, .first);
    defer forward.deinit();
    try testing.expectError(
        error.StateLimit,
        forward.findEndKnown("abababc", 0, 7, .unanchored),
    );
    const end = (try forward.findEnd("abababc", 0, 7, .unanchored)).?;
    const state_count = forward.stateCount();
    const forward_constructed = forward.metrics();
    try testing.expect(forward_constructed.closure_builds > 0);
    try testing.expectEqual(forward_constructed.closure_builds, forward_constructed.intern_calls);
    try testing.expectEqual(end, (try forward.findEndKnown("abababc", 0, 7, .unanchored)).?);
    try testing.expectEqual(state_count, forward.stateCount());
    try testing.expectEqualDeep(forward_constructed, forward.metrics());

    var reverse_prog = try compiler.compile(testing.allocator, &values[0], .{
        .encoding = .utf8,
        .max_instructions = 100_000,
        .reverse = true,
    });
    defer reverse_prog.deinit(testing.allocator);
    var reverse = try Matcher.init(testing.allocator, &reverse_prog, 1000, .longest);
    defer reverse.deinit();
    try testing.expectError(
        error.StateLimit,
        reverse.findStartReverseKnown("abababc", 0, end),
    );
    const start = (try reverse.findStartReverse("abababc", 0, end)).?;
    const reverse_count = reverse.stateCount();
    const reverse_constructed = reverse.metrics();
    try testing.expect(reverse_constructed.closure_builds > 0);
    try testing.expectEqual(
        start,
        (try reverse.findStartReverseKnown("abababc", 0, end)).?,
    );
    try testing.expectEqual(reverse_count, reverse.stateCount());
    try testing.expectEqualDeep(reverse_constructed, reverse.metrics());
}

test "DFA state-limit exhaustion leaves smaller searches reusable" {
    var values = try compilePattern("(a|aa)*b");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1], 1, .first);
    defer matcher.deinit();
    try testing.expectError(
        error.StateLimit,
        matcher.isMatch("aaaaaaaaab", 0, 10, .unanchored),
    );
    try testing.expectEqual(@as(usize, 1), matcher.stateCount());
    try testing.expect(!try matcher.isMatch("", 0, 0, .unanchored));
    try testing.expectEqual(@as(usize, 1), matcher.stateCount());
}

test "DFA hash collisions retain exact ordered state identity" {
    var values = try compilePattern("a|b");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1], 1000, .first);
    defer matcher.deinit();

    matcher.scratch.appendAssumeCapacity(0);
    const first = try matcher.internScratchHashed(7);
    matcher.scratch.clearRetainingCapacity();
    matcher.scratch.appendAssumeCapacity(@intCast(values[1].priority_lists.items.len - 1));
    const second = try matcher.internScratchHashed(7);
    try testing.expect(state_cache.stateIndex(first) != state_cache.stateIndex(second));
    try testing.expectEqual(@as(usize, 2), matcher.stateCount());

    matcher.scratch.clearRetainingCapacity();
    matcher.scratch.appendAssumeCapacity(0);
    try testing.expectEqual(first, try matcher.internScratchHashed(7));
}

test "DFA requested-byte budget rejects below measured high-water" {
    var values = try compilePattern("(ab|a)+c");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);

    var probe = try Matcher.initWithBudget(
        testing.allocator,
        &values[1],
        1000,
        .first,
        .unlimited,
    );
    try testing.expect(try probe.isMatch("abababc", 0, 7, .unanchored));
    const required = probe.budget.peak + @sizeOf(budget_allocator.BudgetAllocator);
    probe.deinit();

    var limited = try Matcher.initWithBudget(
        testing.allocator,
        &values[1],
        1000,
        .first,
        .{ .bytes = required - 1 },
    );
    defer limited.deinit();
    try testing.expectError(
        error.OutOfMemory,
        limited.isMatch("abababc", 0, 7, .unanchored),
    );

    var exact = try Matcher.initWithBudget(
        testing.allocator,
        &values[1],
        1000,
        .first,
        .{ .bytes = required },
    );
    defer exact.deinit();
    try testing.expect(try exact.isMatch("abababc", 0, 7, .unanchored));
}

test "DFA cache reaches a stable state high-water" {
    var values = try compilePattern("(ab|a)+c");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1], 1000, .first);
    defer matcher.deinit();
    try testing.expect(try matcher.isMatch("abababc", 0, 7, .unanchored));
    const count = matcher.stateCount();
    try testing.expect(try matcher.isMatch("abababc", 0, 7, .unanchored));
    try testing.expectEqual(count, matcher.stateCount());
}
