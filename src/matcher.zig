//! Reusable request scratch and top-level execution orchestration.
//!
//! Matcher is where public operation semantics are composed from physical
//! engines. It owns a preallocated complete ordered-NFA matcher, lazily created
//! capture scratch, direct-count byte flags, route diagnostics, and one hard
//! scratch budget. It borrows `compiled.State`; shared DFA caches and immutable
//! OnePass plans remain there for use by independent Matchers.
//!
//! Dispatch is intentionally organized by result family:
//!
//! - existence can use a closed prefix shape, direct byte plan, DFA, then NFA;
//! - range search may use a closed shape or forward/reverse DFA, then NFA;
//! - full match uses its dedicated DFA cache, then exact NFA execution;
//! - captures may search directly or locate a range before exact replay;
//! - count uses a proven byte loop, endpoint DFA, or ordinary iteration.
//!
//! Optional attempts report either a complete answer or a typed decline. A
//! decline is never interpreted as “no match”; this module visibly restarts the
//! complete fallback with clean state. Required prefixes, suffixes, interior
//! literals, and anchoring facts reject work only after conservative publication.
//!
//! Iterators repeatedly call the same range/capture operations. To guarantee
//! progress after an empty result they advance one scalar in the Regex encoding,
//! or one byte when UTF-8 is malformed, and suppress the duplicate empty match at
//! the adjacent restart position.
//!
//! Ordinary methods keep the hot path free of work counters. `*WithWorkLimit`
//! methods instead perform a conservative pre-execution estimate large enough to
//! cover complete fallback. Matcher itself is single-threaded and non-reentrant.

const std = @import("std");
const matcher_module = @This();
const match_types = @import("match.zig");
const budget_allocator = @import("support/budget_allocator.zig");
const count_engine = @import("engine/accelerate/count.zig");
const compiled_module = @import("compiled.zig");
const regex_module = @import("regex.zig");
const capture_search = @import("execute/capture.zig");
const capture_nfa = @import("engine/capture_nfa.zig");
const dispatch = @import("execute/request.zig");
const dfa_search = @import("execute/search.zig");
const nfa = @import("engine/nfa.zig");
const prefix_search = @import("literal/search.zig");
const program = @import("program/program.zig");
const parser = @import("syntax/parser.zig");

const MemoryBudget = regex_module.MemoryBudget;
const Regex = regex_module.Regex;

pub const MatchError = error{ OutOfMemory, InvalidRange, ScratchLimitExceeded };
pub const MatchCollectionError = match_types.CollectionError;
pub const WorkError = error{WorkLimitExceeded};
const CaptureError = capture_search.Error;

/// Per-matcher mutable scratch policy.
pub const MatcherOptions = struct {
    scratch_memory: MemoryBudget = .{ .bytes = 64 * 1024 * 1024 },
};

/// Stable requested-byte accounting for matcher scratch.
pub const MatcherMetrics = struct {
    requested_live_bytes: usize,
    requested_peak_bytes: usize,
    allocation_count: usize,
};

/// Saturating private route counters. They qualify dispatch and benchmark route
/// stability but never influence a later request.
const DfaDiagnostics = struct {
    attempts: usize = 0,
    declines: usize = 0,
    boolean_attempts: usize = 0,
    range_attempts: usize = 0,
    full_attempts: usize = 0,
    disabled_declines: usize = 0,
    cache_busy_declines: usize = 0,
    allocation_declines: usize = 0,
    state_limit_declines: usize = 0,
    unproductive_declines: usize = 0,

    fn recordDecline(self: *DfaDiagnostics, reason: dispatch.OptimizerDecline) void {
        self.declines +|= 1;
        switch (reason) {
            .disabled => self.disabled_declines +|= 1,
            .cache_busy => self.cache_busy_declines +|= 1,
            .allocation_failure => self.allocation_declines +|= 1,
            .state_limit => self.state_limit_declines +|= 1,
            .unproductive => self.unproductive_declines +|= 1,
        }
    }
};

/// Bounded range-only scratch that may verify multiple compatible
/// Regex states. Initialize it from the largest priority program before binding.
pub const BooleanVerifier = struct {
    budget: *budget_allocator.BudgetAllocator,
    state: *compiled_module.State,
    range_nfa: nfa.MatchIdMatcher,

    /// Sizes reusable ID-only queues from this Regex, which must be the largest
    /// Program the verifier will later bind. A stable budget owner lets all later
    /// verification run without allocation errors.
    pub fn init(
        allocator: std.mem.Allocator,
        regex: *const Regex,
        options: MatcherOptions,
    ) error{ OutOfMemory, ScratchLimitExceeded }!BooleanVerifier {
        const payload_budget = budget_allocator.subtractOverhead(
            options.scratch_memory,
            @sizeOf(budget_allocator.BudgetAllocator),
        ) orelse return error.ScratchLimitExceeded;
        const budget = try allocator.create(budget_allocator.BudgetAllocator);
        budget.* = budget_allocator.BudgetAllocator.init(allocator, payload_budget);
        const range_nfa = nfa.MatchIdMatcher.init(budget.allocator(), &regex.state.program) catch |err| {
            const exhausted = budget.exhausted;
            std.debug.assert(budget.live == 0);
            allocator.destroy(budget);
            if (exhausted) return error.ScratchLimitExceeded;
            return err;
        };
        return .{
            .budget = budget,
            .state = regex.state,
            .range_nfa = range_nfa,
        };
    }

    pub fn deinit(self: *BooleanVerifier) void {
        self.range_nfa.deinit();
        std.debug.assert(self.budget.live == 0);
        const backing_allocator = self.budget.child;
        backing_allocator.destroy(self.budget);
        self.* = undefined;
    }

    /// Reuses storage for another Program no larger than the one selected at
    /// initialization. Filtered initializes from its largest entry before binds.
    pub fn bind(self: *BooleanVerifier, regex: *const Regex) void {
        self.range_nfa.rebind(&regex.state.program);
        self.state = regex.state;
    }

    /// Applies required-suffix/anchor facts, tries shared DFA state, then runs the
    /// complete ID-only NFA. The verifier returns no resource error after init.
    pub fn isMatch(self: *BooleanVerifier, input: []const u8) bool {
        if (!requiredSuffixPresent(&self.state.program, input, 0, input.len)) return false;
        const anchor: match_types.Anchor = if (self.state.program.anchor_start) .start else .unanchored;
        return switch (dfa_search.isMatch(self.state, input, anchor)) {
            .complete => |result| result,
            .decline => self.range_nfa.isMatchAnyId(input, anchor == .unanchored),
        };
    }

    pub fn metrics(self: *const BooleanVerifier) MatcherMetrics {
        const overhead = @sizeOf(budget_allocator.BudgetAllocator);
        return .{
            .requested_live_bytes = self.budget.live +| overhead,
            .requested_peak_bytes = self.budget.peak +| overhead,
            .allocation_count = self.budget.allocation_count +| 1,
        };
    }
};

pub const SearchRange = match_types.SearchRange;
pub const Matches = match_types.Matches;

/// Non-overlapping range iterator referring to a Matcher and input.
///
/// Calling another matcher operation while this value is active is unsupported.
/// Empty matches advance by one valid UTF-8 scalar, or one byte when malformed.
pub const MatchIterator = struct {
    matcher: *Matcher,
    input: []const u8,
    next_start: usize = 0,
    last_end: ?usize = null,
    done: bool = false,

    /// Returns the next range, or null permanently after exhaustion.
    pub fn next(self: *MatchIterator) ?match_types.Match {
        while (!self.done) {
            const found = self.matcher.findIn(
                self.input,
                .{ .start = self.next_start, .end = self.input.len },
                .unanchored,
            ) catch unreachable orelse {
                self.done = true;
                return null;
            };
            if (found.start == found.end and self.last_end == found.end) {
                if (found.end == self.input.len) {
                    self.done = true;
                    return null;
                }
                self.next_start = advanceInput(
                    self.input,
                    found.end,
                    self.matcher.state.encoding,
                );
                continue;
            }
            self.last_end = found.end;
            self.next_start = found.end;
            return found;
        }
        return null;
    }
};

/// Non-overlapping capture iterator referring to a Matcher and input.
///
/// `next` may allocate capture-engine scratch on first use. Each successful call
/// invalidates the prior CaptureView. Empty matches use the same scalar-aware
/// progress and adjacent-empty suppression as MatchIterator. Calling another
/// matcher operation while this value is active is unsupported.
pub const CaptureIterator = struct {
    matcher: *Matcher,
    input: []const u8,
    next_start: usize = 0,
    last_end: ?usize = null,
    done: bool = false,

    /// Returns the next capture view, or null permanently after
    /// exhaustion. Resource errors leave the iterator valid for teardown only.
    pub fn next(self: *CaptureIterator) CaptureError!?match_types.CaptureView {
        while (!self.done) {
            const captured = self.matcher.capturesIn(
                self.input,
                .{ .start = self.next_start, .end = self.input.len },
                .unanchored,
            ) catch |err| switch (err) {
                error.InvalidRange => unreachable,
                error.OutOfMemory => {
                    self.done = true;
                    return error.OutOfMemory;
                },
                error.ScratchLimitExceeded => {
                    self.done = true;
                    return error.ScratchLimitExceeded;
                },
            } orelse {
                self.done = true;
                return null;
            };
            const whole = captured.group(0).?;
            if (whole.start == whole.end and self.last_end == whole.end) {
                if (whole.end == self.input.len) {
                    self.done = true;
                    return null;
                }
                self.next_start = advanceInput(
                    self.input,
                    whole.end,
                    self.matcher.state.encoding,
                );
                continue;
            }
            self.last_end = whole.end;
            self.next_start = whole.end;
            return captured;
        }
        return null;
    }
};

/// Reusable single-threaded matching state for one Regex.
///
/// The Regex must remain valid until this Matcher is destroyed. Every operation
/// may invalidate a previous CaptureView; copied Captures remain valid.
pub const Matcher = struct {
    pub const Options = matcher_module.MatcherOptions;
    pub const Metrics = matcher_module.MatcherMetrics;
    pub const Error = matcher_module.MatchError;
    pub const CollectionError = matcher_module.MatchCollectionError;
    pub const WorkLimitError = matcher_module.WorkError;
    pub const Iterator = matcher_module.MatchIterator;
    pub const CaptureIterator = matcher_module.CaptureIterator;
    pub const Matches = matcher_module.Matches;

    budget: *budget_allocator.BudgetAllocator,
    state: *compiled_module.State,
    range_nfa: nfa.Matcher,
    capture_scratch: capture_search.Scratch,
    count_byte_flags: [256]u8,
    dfa_diagnostics: DfaDiagnostics = .{},

    // Lifecycle and resource accounting.

    /// Creates matcher scratch with the finite default policy.
    pub fn init(
        allocator: std.mem.Allocator,
        regex: *const Regex,
    ) error{ OutOfMemory, ScratchLimitExceeded }!Matcher {
        return initWithOptions(allocator, regex, .{});
    }

    /// Creates matcher scratch under an explicit hard requested-byte ceiling.
    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        regex: *const Regex,
        options: MatcherOptions,
    ) error{ OutOfMemory, ScratchLimitExceeded }!Matcher {
        const payload_budget = budget_allocator.subtractOverhead(
            options.scratch_memory,
            @sizeOf(budget_allocator.BudgetAllocator),
        ) orelse return error.ScratchLimitExceeded;
        const budget = try allocator.create(budget_allocator.BudgetAllocator);
        budget.* = budget_allocator.BudgetAllocator.init(allocator, payload_budget);
        const scratch_allocator = budget.allocator();
        const range_nfa = nfa.Matcher.init(scratch_allocator, &regex.state.program) catch |err| {
            const exhausted = budget.exhausted;
            std.debug.assert(budget.live == 0);
            allocator.destroy(budget);
            if (exhausted) return error.ScratchLimitExceeded;
            return err;
        };
        const count_byte_flags = count_engine.buildByteFlags(&regex.state.program);
        return .{
            .budget = budget,
            .state = regex.state,
            .range_nfa = range_nfa,
            .capture_scratch = .{
                .allocator = scratch_allocator,
                .budget = budget,
                .prog = &regex.state.program,
                .state = regex.state,
            },
            .count_byte_flags = count_byte_flags,
        };
    }

    /// Returns stable requested-byte accounting for this Matcher.
    pub fn metrics(self: *const Matcher) MatcherMetrics {
        const overhead = @sizeOf(budget_allocator.BudgetAllocator);
        return .{
            .requested_live_bytes = self.budget.live +| overhead,
            .requested_peak_bytes = self.budget.peak +| overhead,
            .allocation_count = self.budget.allocation_count +| 1,
        };
    }

    /// Combines public scratch accounting with private cumulative route counters.
    fn debugMetrics(self: *const Matcher) DebugMetrics {
        const resource_metrics = self.metrics();
        return .{
            .requested_live_bytes = resource_metrics.requested_live_bytes,
            .requested_peak_bytes = resource_metrics.requested_peak_bytes,
            .allocation_count = resource_metrics.allocation_count,
            .dfa_attempts = self.dfa_diagnostics.attempts,
            .dfa_declines = self.dfa_diagnostics.declines,
            .dfa_boolean_attempts = self.dfa_diagnostics.boolean_attempts,
            .dfa_range_attempts = self.dfa_diagnostics.range_attempts,
            .dfa_full_attempts = self.dfa_diagnostics.full_attempts,
            .dfa_disabled_declines = self.dfa_diagnostics.disabled_declines,
            .dfa_cache_busy_declines = self.dfa_diagnostics.cache_busy_declines,
            .dfa_allocation_declines = self.dfa_diagnostics.allocation_declines,
            .dfa_state_limit_declines = self.dfa_diagnostics.state_limit_declines,
            .dfa_unproductive_declines = self.dfa_diagnostics.unproductive_declines,
            .capture_direct_bit_state_attempts = self.capture_scratch.diagnostics.direct_bit_state_attempts,
            .capture_direct_bit_state_completions = self.capture_scratch.diagnostics.direct_bit_state_completions,
            .capture_direct_bit_state_required_bytes_max = self.capture_scratch.diagnostics.direct_bit_state_required_bytes_max,
            .capture_alias_completions = self.capture_scratch.diagnostics.alias_completions,
            .capture_one_pass_attempts = self.capture_scratch.diagnostics.one_pass_attempts,
            .capture_one_pass_completions = self.capture_scratch.diagnostics.one_pass_completions,
            .capture_exact_bit_state_attempts = self.capture_scratch.diagnostics.exact_bit_state_attempts,
            .capture_exact_bit_state_completions = self.capture_scratch.diagnostics.exact_bit_state_completions,
            .capture_exact_bit_state_required_bytes_max = self.capture_scratch.diagnostics.exact_bit_state_required_bytes_max,
            .capture_nfa_attempts = self.capture_scratch.diagnostics.capture_nfa_attempts,
            .capture_nfa_completions = self.capture_scratch.diagnostics.capture_nfa_completions,
            .capture_nfa_row_copies = if (self.capture_scratch.capture_engine) |*engine|
                engine.metrics().row_copies
            else
                0,
            .capture_nfa_row_copy_bytes = if (self.capture_scratch.capture_engine) |*engine|
                engine.metrics().row_copy_bytes
            else
                0,
            .capture_nfa_rows_created = if (self.capture_scratch.capture_engine) |*engine|
                engine.metrics().rows_created
            else
                0,
            .capture_nfa_rows_reused = if (self.capture_scratch.capture_engine) |*engine|
                engine.metrics().rows_reused
            else
                0,
        };
    }

    /// Releases all matcher-local engines and scratch.
    pub fn deinit(self: *Matcher) void {
        self.capture_scratch.deinit();
        self.range_nfa.deinit();
        std.debug.assert(self.budget.live == 0);
        const backing_allocator = self.budget.child;
        backing_allocator.destroy(self.budget);
        self.* = undefined;
    }

    // Iteration, counting, and stored results.

    /// Creates an allocation-free non-overlapping range iterator.
    pub fn iterator(self: *Matcher, input: []const u8) MatchIterator {
        return .{ .matcher = self, .input = input };
    }

    /// Counts non-overlapping matches. Compiler-proven byte languages use a
    /// direct loop. Other non-empty languages count endpoints with one forward
    /// DFA pass, avoiding reverse range reconstruction for every match.
    pub fn count(self: *Matcher, input: []const u8) usize {
        if (!requiredSuffixPresent(&self.state.program, input, 0, input.len) or
            !requiredLiteralPresent(&self.state.program, input, 0, input.len)) return 0;
        if (count_engine.exact(&self.state.program, &self.count_byte_flags, input)) |total|
            return total;
        if (!self.state.program.can_match_empty and self.state.match_kind == .first) {
            self.dfa_diagnostics.attempts +|= 1;
            switch (dfa_search.countNonEmpty(self.state, input)) {
                .complete => |total| return total,
                .decline => |reason| self.dfa_diagnostics.recordDecline(reason),
            }
        }
        var matches = self.iterator(input);
        var total: usize = 0;
        while (matches.next() != null) total += 1;
        return total;
    }

    /// Counts only after a conservative repeated-search work admission.
    /// Ordinary methods remain branch-free with respect to work policy.
    pub fn countWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        max_work: usize,
    ) WorkError!usize {
        try self.admitRepeatedSearchWork(input.len, false, max_work);
        return self.count(input);
    }

    /// Creates a non-overlapping capture iterator. Construction is
    /// allocation-free; the first `next` may initialize capture scratch.
    pub fn captureIterator(self: *Matcher, input: []const u8) matcher_module.CaptureIterator {
        return .{ .matcher = self, .input = input };
    }

    /// Collects non-overlapping ranges through `allocator` with a hard count
    /// ceiling. The returned offsets contain no input bytes and remain valid
    /// after this Matcher and its Regex are destroyed.
    pub fn findAll(
        self: *Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        max_matches: usize,
    ) MatchCollectionError!matcher_module.Matches {
        var values: std.ArrayList(match_types.Match) = .empty;
        errdefer values.deinit(allocator);
        var ranges = self.iterator(input);
        while (ranges.next()) |found| {
            if (values.items.len == max_matches) return error.ResultLimitExceeded;
            try values.append(allocator, found);
        }
        return .{
            .allocator = allocator,
            .items = try values.toOwnedSlice(allocator),
        };
    }

    // Boolean and range search.

    /// Reports whether any unanchored match exists.
    ///
    /// Shared-DFA failure falls back to the preallocated ordered NFA, so this
    /// whole-input convenience operation has no resource error.
    pub fn isMatch(self: *Matcher, input: []const u8) bool {
        return self.executeExistence(input, .{
            .range_start = 0,
            .range_end = input.len,
            .requested_anchor = .unanchored,
            .program_anchor_start = self.state.program.anchor_start,
            .program_anchor_end = self.state.program.anchor_end,
            .has_closed_prefix_shape = self.state.program.prefix_complete or
                self.state.program.prefix_has_tail_range,
            .whole_input = true,
        }) catch unreachable;
    }

    /// Admits complete fallback work before running ordinary existence search.
    pub fn isMatchWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        max_work: usize,
    ) WorkError!bool {
        try self.admitWork(input.len, false, max_work);
        return self.isMatch(input);
    }

    /// Reports whether a match exists in an absolute range after validating its
    /// half-open bounds. Compiler anchoring/facts may reject first; every optional
    /// DFA decline restarts the preallocated complete NFA.
    pub fn isMatchIn(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
        anchor: match_types.Anchor,
    ) error{InvalidRange}!bool {
        const end = try validatedRangeEnd(input.len, range);
        return self.executeExistence(input, .{
            .range_start = range.start,
            .range_end = end,
            .requested_anchor = anchor,
            .program_anchor_start = self.state.program.anchor_start,
            .program_anchor_end = self.state.program.anchor_end,
            .has_closed_prefix_shape = self.state.program.prefix_complete or
                self.state.program.prefix_has_tail_range,
            .whole_input = false,
        });
    }

    /// Work-admitted absolute-range existence search.
    pub fn isMatchInWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
        anchor: match_types.Anchor,
        max_work: usize,
    ) (error{InvalidRange} || WorkError)!bool {
        const end = try validatedRangeEnd(input.len, range);
        try self.admitWork(end - range.start, false, max_work);
        return self.isMatchIn(input, range, anchor);
    }

    /// Executes one normalized existence request. Every accelerator branch either
    /// returns a complete boolean or explicitly restarts the preallocated NFA.
    fn executeExistence(
        self: *Matcher,
        input: []const u8,
        request: dispatch.ExistenceRequest,
    ) error{InvalidRange}!bool {
        if (self.state.program.anchor_end and request.range_end != input.len)
            return false;
        if (!requiredSuffixPresent(
            &self.state.program,
            input,
            request.range_start,
            request.range_end,
        ) or !requiredLiteralPresent(
            &self.state.program,
            input,
            request.range_start,
            request.range_end,
        )) return false;
        if (request.whole_input) {
            if (count_engine.existsExact(
                &self.state.program,
                &self.count_byte_flags,
                input,
            )) |matched| return matched;
        }

        const effective_anchor = request.effectiveAnchor();
        const accelerated_start = requiredPrefixStart(
            &self.state.program,
            input,
            request.range_start,
            request.range_end,
            effective_anchor,
        ) orelse return false;
        return switch (request.plan()) {
            .closed_prefix_shape => (try self.findPrefixShape(
                input,
                accelerated_start,
                request.range_end,
                effective_anchor,
            )) != null,
            .dfa => {
                self.dfa_diagnostics.attempts +|= 1;
                self.dfa_diagnostics.boolean_attempts +|= 1;
                const attempted = if (request.whole_input and accelerated_start == 0)
                    dfa_search.isMatch(self.state, input, effective_anchor)
                else
                    try dfa_search.isMatchIn(
                        self.state,
                        input,
                        accelerated_start,
                        request.range_end,
                        effective_anchor,
                    );
                return switch (attempted) {
                    .complete => |result| result,
                    .decline => |reason| {
                        self.dfa_diagnostics.recordDecline(reason);
                        return self.range_nfa.isMatch(
                            input,
                            accelerated_start,
                            request.range_end,
                            effective_anchor,
                        ) catch unreachable;
                    },
                };
            },
        };
    }

    /// Returns the first configured-kind unanchored whole-input range.
    pub fn find(self: *Matcher, input: []const u8) ?match_types.Match {
        return self.findIn(input, .{}, .unanchored) catch unreachable;
    }

    /// Work-admitted whole-input range discovery.
    pub fn findWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        max_work: usize,
    ) WorkError!?match_types.Match {
        try self.admitWork(input.len, false, max_work);
        return self.find(input);
    }

    /// Returns the configured leftmost-first/longest range inside validated
    /// absolute bounds while assertions still inspect complete input. Dispatch
    /// uses an exact closed shape, forward/reverse DFA, or ordered NFA according
    /// to proved facts; DFA decline always falls back exactly.
    pub fn findIn(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
        anchor: match_types.Anchor,
    ) error{InvalidRange}!?match_types.Match {
        const end = try validatedRangeEnd(input.len, range);
        if (self.state.program.anchor_end and end != input.len) return null;
        if (!requiredSuffixPresent(&self.state.program, input, range.start, end) or
            !requiredLiteralPresent(&self.state.program, input, range.start, end)) return null;
        const effective_anchor: match_types.Anchor = if (self.state.program.anchor_start) .start else anchor;
        const request = dispatch.RangeRequest{
            .purpose = .return_range,
            .match_kind = self.state.match_kind,
            .program_anchor_end = self.state.program.anchor_end,
            .prefix_len = self.state.program.prefix.len,
            .has_closed_prefix_shape = self.state.program.prefix_complete or
                self.state.program.prefix_has_tail_range,
        };
        return switch (request.plan()) {
            .closed_prefix_shape => self.findPrefixShape(
                input,
                range.start,
                end,
                effective_anchor,
            ),
            .dfa => self.findWithDfaFallback(
                input,
                range.start,
                end,
                effective_anchor,
                self.state.match_kind,
            ),
            .ordered_nfa => self.range_nfa.findKind(
                input,
                range.start,
                end,
                effective_anchor,
                self.state.match_kind,
            ),
        };
    }

    /// Work-admitted absolute-range discovery under explicit anchoring.
    pub fn findInWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
        anchor: match_types.Anchor,
        max_work: usize,
    ) (error{InvalidRange} || WorkError)!?match_types.Match {
        const end = try validatedRangeEnd(input.len, range);
        try self.admitWork(end - range.start, false, max_work);
        return self.findIn(input, range, anchor);
    }

    /// Executes languages proven to be exactly a literal prefix, optionally
    /// followed by one closed byte range. Exact shape proof makes verification
    /// unnecessary; anchoring still constrains candidate position.
    fn findPrefixShape(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
    ) error{InvalidRange}!?match_types.Match {
        if (range_start > range_end or range_end > input.len) return error.InvalidRange;
        const prog = &self.state.program;
        const search_end = if (prog.prefix_has_tail_range) range_end -| 1 else range_end;
        var position = range_start;
        while (position <= search_end) {
            const candidate = (if (prog.prefix_fold_ascii)
                prefix_search.findFoldedAscii(input, position, search_end, prog.prefix)
            else
                prefix_search.find(input, position, search_end, prog.prefix)) orelse return null;
            if (anchor == .start and candidate != range_start) return null;
            if (prog.prefix_complete) return .{
                .start = candidate,
                .end = candidate + prog.prefix.len,
            };
            const tail_position = candidate + prog.prefix.len;
            const tail = input[tail_position];
            if (tail >= prog.prefix_tail_lo and tail <= prog.prefix_tail_hi) return .{
                .start = candidate,
                .end = tail_position + 1,
            };
            if (anchor == .start) return null;
            position = candidate + 1;
        }
        return null;
    }

    /// Applies required-prefix skipping, attempts forward/reverse DFA discovery,
    /// and reruns ordered NFA range search after any typed decline.
    fn findWithDfaFallback(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
        kind: match_types.MatchKind,
    ) error{InvalidRange}!?match_types.Match {
        const accelerated_start = requiredPrefixStart(
            &self.state.program,
            input,
            range_start,
            range_end,
            anchor,
        ) orelse return null;
        self.dfa_diagnostics.attempts +|= 1;
        self.dfa_diagnostics.range_attempts +|= 1;
        return switch (try dfa_search.find(
            self.state,
            input,
            accelerated_start,
            range_end,
            anchor,
        )) {
            .complete => |result| result,
            .decline => |reason| {
                self.dfa_diagnostics.recordDecline(reason);
                return try self.range_nfa.findKind(
                    input,
                    accelerated_start,
                    range_end,
                    anchor,
                    kind,
                );
            },
        };
    }

    // Exact-range matching.

    /// Reports whether the expression matches the complete input.
    pub fn fullMatch(self: *Matcher, input: []const u8) bool {
        return self.fullMatchIn(input, .{}) catch unreachable;
    }

    /// Work-admitted whole-input exact match.
    pub fn fullMatchWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        max_work: usize,
    ) WorkError!bool {
        try self.admitWork(input.len, false, max_work);
        return self.fullMatch(input);
    }

    /// Reports whether the expression consumes exactly the requested absolute
    /// range. A dedicated full-DFA cache may answer; on decline, anchored-longest
    /// ordered NFA must return both the requested start and endpoint.
    pub fn fullMatchIn(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
    ) error{InvalidRange}!bool {
        const range_end = try validatedRangeEnd(input.len, range);
        if (self.state.program.anchor_end and range_end != input.len) return false;
        if (!requiredSuffixPresent(&self.state.program, input, range.start, range_end) or
            !requiredLiteralPresent(&self.state.program, input, range.start, range_end)) return false;
        self.dfa_diagnostics.attempts +|= 1;
        self.dfa_diagnostics.full_attempts +|= 1;
        return switch (try dfa_search.fullMatch(
            self.state,
            input,
            range.start,
            range_end,
        )) {
            .complete => |result| result,
            .decline => |reason| {
                self.dfa_diagnostics.recordDecline(reason);
                return self.fullMatchNfa(input, range.start, range_end);
            },
        };
    }

    /// Work-admitted exact match over one absolute range.
    pub fn fullMatchInWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
        max_work: usize,
    ) (error{InvalidRange} || WorkError)!bool {
        const end = try validatedRangeEnd(input.len, range);
        try self.admitWork(end - range.start, false, max_work);
        return self.fullMatchIn(input, range);
    }

    /// Complete exact-range fallback expressed through anchored ordered-NFA
    /// search and an endpoint equality check.
    fn fullMatchNfa(self: *Matcher, input: []const u8, start: usize, end: usize) bool {
        const found = self.range_nfa.findKind(input, start, end, .start, .longest) catch unreachable;
        return if (found) |value| value.start == start and value.end == end else false;
    }

    // Capture extraction.

    /// Returns a capture view only when the complete input matches.
    pub fn fullCaptures(
        self: *Matcher,
        input: []const u8,
    ) CaptureError!?match_types.CaptureView {
        return self.fullCapturesIn(input, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScratchLimitExceeded => error.ScratchLimitExceeded,
            error.InvalidRange => unreachable,
        };
    }

    /// Work-admitted whole-input exact capture replay.
    pub fn fullCapturesWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        max_work: usize,
    ) (CaptureError || WorkError)!?match_types.CaptureView {
        try self.admitWork(input.len, true, max_work);
        return self.fullCaptures(input);
    }

    /// Returns captures only after exact full-range acceptance is proved, then
    /// replays that range through alias, OnePass, BitState, or complete capture
    /// NFA. The borrowed view is invalidated by the next Matcher operation.
    pub fn fullCapturesIn(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
    ) MatchError!?match_types.CaptureView {
        const range_end = try validatedRangeEnd(input.len, range);
        if (!try self.fullMatchIn(input, range)) return null;

        return self.capture_scratch.exact(
            input,
            range.start,
            range_end,
            .full_exact,
        );
    }

    /// Work-admitted exact capture replay over one absolute range.
    pub fn fullCapturesInWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
        max_work: usize,
    ) (MatchError || WorkError)!?match_types.CaptureView {
        const end = try validatedRangeEnd(input.len, range);
        try self.admitWork(end - range.start, true, max_work);
        return self.fullCapturesIn(input, range);
    }

    /// Returns a capture view for the first unanchored whole-input match.
    pub fn captures(self: *Matcher, input: []const u8) CaptureError!?match_types.CaptureView {
        return self.capturesIn(input, .{}, .unanchored) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ScratchLimitExceeded => error.ScratchLimitExceeded,
            error.InvalidRange => unreachable,
        };
    }

    /// Work-admitted whole-input capture search.
    pub fn capturesWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        max_work: usize,
    ) (CaptureError || WorkError)!?match_types.CaptureView {
        try self.admitWork(input.len, true, max_work);
        return self.captures(input);
    }

    /// Copies captures through `allocator`; the result remains valid independently.
    pub fn copyCaptures(
        self: *Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) CaptureError!?match_types.Captures {
        const view = (try self.captures(input)) orelse return null;
        return try view.copy(allocator);
    }

    /// Returns captures for the selected match in an absolute search range.
    ///
    /// First-match requests may complete through direct BitState search. On
    /// decline (and for longest matching), a captureless engine locates the
    /// semantic range; capture scratch then replays that exact range through
    /// alias, OnePass, BitState, or complete capture NFA.
    pub fn capturesIn(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
        anchor: match_types.Anchor,
    ) MatchError!?match_types.CaptureView {
        const range_end = try validatedRangeEnd(input.len, range);
        if (self.state.program.anchor_end and range_end != input.len) return null;
        if (!requiredSuffixPresent(&self.state.program, input, range.start, range_end) or
            !requiredLiteralPresent(&self.state.program, input, range.start, range_end)) return null;

        const kind = self.state.match_kind;
        const effective_anchor: match_types.Anchor = if (self.state.program.anchor_start) .start else anchor;
        if (kind == .first) switch (self.capture_scratch.directFirst(
            input,
            range.start,
            range_end,
            effective_anchor,
        )) {
            .complete => |captured| return captured,
            .decline => {},
        };

        const location_request = dispatch.RangeRequest{
            .purpose = .locate_captures,
            .match_kind = kind,
            .program_anchor_end = self.state.program.anchor_end,
            .prefix_len = self.state.program.prefix.len,
            .has_closed_prefix_shape = false,
        };
        const located = switch (location_request.plan()) {
            .dfa => try self.findWithDfaFallback(
                input,
                range.start,
                range_end,
                effective_anchor,
                kind,
            ),
            .ordered_nfa => try self.range_nfa.findKind(
                input,
                range.start,
                range_end,
                effective_anchor,
                kind,
            ),
            .closed_prefix_shape => unreachable,
        } orelse return null;
        return self.capture_scratch.exact(
            input,
            located.start,
            located.end,
            .located_exact,
        );
    }

    /// Work-admitted capture search over one absolute range.
    pub fn capturesInWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        range: SearchRange,
        anchor: match_types.Anchor,
        max_work: usize,
    ) (MatchError || WorkError)!?match_types.CaptureView {
        const end = try validatedRangeEnd(input.len, range);
        try self.admitWork(end - range.start, true, max_work);
        return self.capturesIn(input, range, anchor);
    }

    /// Bounds one search by `(positions × weighted priority items)`. Captures
    /// weight each item by slot work; saturating/checked arithmetic rejects on
    /// any unrepresentable estimate.
    fn admitWork(
        self: *const Matcher,
        input_bytes: usize,
        captures_requested: bool,
        max_work: usize,
    ) WorkError!void {
        const positions = std.math.add(usize, input_bytes, 1) catch
            return error.WorkLimitExceeded;
        return self.admitPositionWork(positions, captures_requested, max_work);
    }

    /// A sequence of suffix searches can examine `(n+1) + n + ... + 1`
    /// positions. Optional accelerators may decline, so admission must cover
    /// the complete repeated-NFA fallback rather than assume a one-pass route.
    fn admitRepeatedSearchWork(
        self: *const Matcher,
        input_bytes: usize,
        captures_requested: bool,
        max_work: usize,
    ) WorkError!void {
        var left = std.math.add(usize, input_bytes, 1) catch
            return error.WorkLimitExceeded;
        var right = std.math.add(usize, left, 1) catch
            return error.WorkLimitExceeded;
        if (left & 1 == 0)
            left /= 2
        else
            right /= 2;
        const positions = std.math.mul(usize, left, right) catch
            return error.WorkLimitExceeded;
        return self.admitPositionWork(positions, captures_requested, max_work);
    }

    /// Shared arithmetic for one or many searches after the caller has computed
    /// the conservative number of positions examined.
    fn admitPositionWork(
        self: *const Matcher,
        positions: usize,
        captures_requested: bool,
        max_work: usize,
    ) WorkError!void {
        var per_position = std.math.add(
            usize,
            self.state.program.priority_lists.items.len,
            1,
        ) catch return error.WorkLimitExceeded;
        if (captures_requested) {
            per_position = std.math.mul(
                usize,
                per_position,
                @max(@as(usize, 1), self.state.program.capture_slots),
            ) catch return error.WorkLimitExceeded;
        }
        const required = std.math.mul(usize, positions, per_position) catch
            return error.WorkLimitExceeded;
        if (required > max_work) return error.WorkLimitExceeded;
    }
};

/// Private dispatch observations used by qualification and benchmarks.
pub const DebugMetrics = struct {
    requested_live_bytes: usize,
    requested_peak_bytes: usize,
    allocation_count: usize,
    dfa_attempts: usize = 0,
    dfa_declines: usize = 0,
    dfa_boolean_attempts: usize = 0,
    dfa_range_attempts: usize = 0,
    dfa_full_attempts: usize = 0,
    dfa_disabled_declines: usize = 0,
    dfa_cache_busy_declines: usize = 0,
    dfa_allocation_declines: usize = 0,
    dfa_state_limit_declines: usize = 0,
    dfa_unproductive_declines: usize = 0,
    capture_direct_bit_state_attempts: usize = 0,
    capture_direct_bit_state_completions: usize = 0,
    capture_direct_bit_state_required_bytes_max: usize = 0,
    capture_alias_completions: usize = 0,
    capture_one_pass_attempts: usize = 0,
    capture_one_pass_completions: usize = 0,
    capture_exact_bit_state_attempts: usize = 0,
    capture_exact_bit_state_completions: usize = 0,
    capture_exact_bit_state_required_bytes_max: usize = 0,
    capture_nfa_attempts: usize = 0,
    capture_nfa_completions: usize = 0,
    capture_nfa_row_copies: usize = 0,
    capture_nfa_row_copy_bytes: usize = 0,
    capture_nfa_rows_created: usize = 0,
    capture_nfa_rows_reused: usize = 0,
};

pub fn debugMetrics(matcher: *const Matcher) DebugMetrics {
    return matcher.debugMetrics();
}

/// Normalizes a nullable range end and rejects reversed or out-of-input bounds
/// before any engine sees unchecked absolute offsets.
fn validatedRangeEnd(input_len: usize, range: SearchRange) error{InvalidRange}!usize {
    const end = range.end orelse input_len;
    if (range.start > end or end > input_len) return error.InvalidRange;
    return end;
}

/// Returns the first start not excluded by a proven required prefix. Start
/// anchoring permits only the requested start; an unanchored search may skip to
/// the next literal occurrence.
fn requiredPrefixStart(
    prog: *const program.Program,
    input: []const u8,
    start: usize,
    end: usize,
    anchor: match_types.Anchor,
) ?usize {
    if (prog.prefix.len == 0) return start;
    if (anchor == .start) {
        if (prog.prefix.len > end - start) return null;
        const actual = input[start .. start + prog.prefix.len];
        const present = if (prog.prefix_fold_ascii)
            std.ascii.eqlIgnoreCase(actual, prog.prefix)
        else
            std.mem.eql(u8, actual, prog.prefix);
        return if (present) start else null;
    }
    const candidate = (if (prog.prefix_fold_ascii)
        prefix_search.findFoldedAscii(input, start, end, prog.prefix)
    else
        prefix_search.find(input, start, end, prog.prefix)) orelse return null;
    return candidate;
}

/// Conservatively rejects ranges that cannot contain the Program's exact
/// required suffix. Folding is ASCII-only because publication emits this fact
/// only when that comparison is sound.
fn requiredSuffixPresent(
    prog: *const program.Program,
    input: []const u8,
    start: usize,
    end: usize,
) bool {
    const suffix = prog.required_suffix.bytes[0..prog.required_suffix.len];
    if (suffix.len == 0) return true;
    if (suffix.len > end - start) return false;
    if (prog.anchor_end) {
        const actual = input[end - suffix.len .. end];
        return if (prog.required_suffix.fold_ascii)
            std.ascii.eqlIgnoreCase(actual, suffix)
        else
            std.mem.eql(u8, actual, suffix);
    }
    return (if (prog.required_suffix.fold_ascii)
        prefix_search.findFoldedAscii(input, start, end, suffix)
    else
        prefix_search.find(input, start, end, suffix)) != null;
}

/// Conservatively rejects ranges missing a compiler-proven literal whose
/// match-relative offset is unknown. Unlike prefix acceleration, this predicate
/// never changes execution start; leading nullable syntax and leftmost-first
/// range selection therefore remain observable exactly as authored.
fn requiredLiteralPresent(
    prog: *const program.Program,
    input: []const u8,
    start: usize,
    end: usize,
) bool {
    const literal = prog.required_literal.bytes[0..prog.required_literal.len];
    if (literal.len == 0) return true;
    if (literal.len > end - start) return false;
    return (if (prog.required_literal.fold_ascii)
        prefix_search.findFoldedAscii(input, start, end, literal)
    else
        prefix_search.find(input, start, end, literal)) != null;
}

/// Advances empty-match iteration by one encoding unit. Malformed UTF-8 consumes
/// one byte, guaranteeing progress over arbitrary input.
fn advanceInput(input: []const u8, position: usize, encoding: parser.Encoding) usize {
    std.debug.assert(position < input.len);
    if (encoding == .utf8) {
        const width = std.unicode.utf8ByteSequenceLength(input[position]) catch return position + 1;
        if (width <= input.len - position) {
            _ = std.unicode.utf8Decode(input[position..][0..width]) catch return position + 1;
            return position + width;
        }
    }
    return position + 1;
}
