//! Matcher-local capture scratch and exact-engine fallback chain.
//!
//! `Scratch` owns optional instances of all capture executors and one result-slot
//! area under the parent Matcher's BudgetAllocator. Engines are initialized on
//! first eligible use and retained for later requests; allocation failure in an
//! optional engine causes decline unless/until the complete capture NFA itself
//! needs resources.
//!
//! Direct first-match BitState search is attempted only for assertion-free
//! requests whose full `(roots × positions)` bitmap fits the direct ceiling. If
//! it declines, Matcher locates the semantic range with captureless machinery.
//! Exact replay then proceeds:
//!
//! 1. alias every group to the range when publication proved that shape;
//! 2. use a lazily shared immutable OnePass plan when deterministic;
//! 3. use compressed-row BitState below the exact bitmap ceiling;
//! 4. run complete capture NFA.
//!
//! Optional execution errors are discarded only because the next path is exact.
//! The final NFA distinguishes backing allocator failure from configured scratch
//! exhaustion. Returned CaptureViews borrow Scratch result/engine storage and are
//! invalidated by the next Matcher operation.

const std = @import("std");
const match_types = @import("../match.zig");
const budget_allocator = @import("../support/budget_allocator.zig");
const compiled_module = @import("../compiled.zig");
const capture_nfa = @import("../engine/capture_nfa.zig");
const dispatch = @import("request.zig");
const bit_state = @import("../engine/accelerate/bit_state.zig");
const one_pass = @import("../engine/accelerate/one_pass.zig");
const program = @import("../program/program.zig");

pub const Error = error{ OutOfMemory, ScratchLimitExceeded };
const inline_whole_result_slots: usize = 4;

/// Direct search can answer with either match/no-match or decline before semantic
/// range discovery.
pub const DirectAttempt = union(enum) {
    complete: ?match_types.CaptureView,
    decline,
};

/// Saturating route/admission observations used only by qualification and
/// benchmarks.
pub const Diagnostics = struct {
    direct_bit_state_attempts: usize = 0,
    direct_bit_state_completions: usize = 0,
    direct_bit_state_required_bytes_max: usize = 0,
    alias_completions: usize = 0,
    one_pass_attempts: usize = 0,
    one_pass_completions: usize = 0,
    exact_bit_state_attempts: usize = 0,
    exact_bit_state_completions: usize = 0,
    exact_bit_state_required_bytes_max: usize = 0,
    capture_nfa_attempts: usize = 0,
    capture_nfa_completions: usize = 0,
};

/// Lazy matcher-local owner for mutually selected capture engines and borrowed
/// result storage. OnePass plans may be shared from Regex state, while BitState
/// and complete capture-NFA executors are initialized on first admissible use;
/// every request may overwrite the result slice returned by an earlier view.
pub const Scratch = struct {
    allocator: std.mem.Allocator,
    budget: *budget_allocator.BudgetAllocator,
    prog: *const program.Program,
    state: *compiled_module.State,
    capture_engine: ?capture_nfa.Matcher = null,
    bit_state_engine: ?bit_state.Matcher = null,
    one_pass_engine: ?one_pass.Executor = null,
    inline_whole_result: [inline_whole_result_slots]?usize = @splat(null),
    overflow_whole_result: []?usize = &.{},
    diagnostics: Diagnostics = .{},

    pub fn deinit(self: *Scratch) void {
        if (self.overflow_whole_result.len != 0)
            self.allocator.free(self.overflow_whole_result);
        if (self.one_pass_engine) |*engine| engine.deinit();
        if (self.bit_state_engine) |*engine| engine.deinit();
        if (self.capture_engine) |*engine| engine.deinit();
        self.* = undefined;
    }

    /// Tries direct first-match BitState capture search. Any optimizer setup,
    /// admission, or execution failure is a clean decline to range location.
    pub fn directFirst(
        self: *Scratch,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        anchor: match_types.Anchor,
    ) DirectAttempt {
        self.diagnostics.direct_bit_state_attempts +|= 1;
        const request = dispatch.CaptureRequest{
            .phase = .direct_search,
            .range_bytes = range_end - range_start,
            .uses_empty_width = self.prog.uses_empty_width,
        };
        // Direct-search admission intentionally uses the full-root product.
        // Compact exact-replay rows can otherwise admit DFS search shapes that
        // are slower than locating a range and replaying it.
        const required = bit_state.requiredFullBitmapBytesForProg(
            self.prog,
            request.range_bytes,
        ) catch null;
        if (required) |bytes|
            self.diagnostics.direct_bit_state_required_bytes_max = @max(
                self.diagnostics.direct_bit_state_required_bytes_max,
                bytes,
            );
        if (request.admission(required) != .admit) return .decline;
        if (!self.ensureBitState()) return .decline;
        const engine = &self.bit_state_engine.?;
        const captured = engine.capturesSearch(
            input,
            range_start,
            range_end,
            anchor,
        ) catch return .decline;
        self.diagnostics.direct_bit_state_completions +|= 1;
        return .{ .complete = captured };
    }

    /// Replays captures over a range already proven to match. Optional engines
    /// may decline; capture NFA is the complete bounded fallback.
    pub fn exact(
        self: *Scratch,
        input: []const u8,
        range_start: usize,
        range_end: usize,
        phase: dispatch.CapturePhase,
    ) Error!?match_types.CaptureView {
        std.debug.assert(phase == .located_exact or phase == .full_exact);
        if (self.prog.all_captures_whole and
            dispatch.aliasesWholeCaptures(self.prog.capture_slots))
        {
            const captured = try self.aliasWhole(range_start, range_end);
            self.diagnostics.alias_completions +|= 1;
            return captured;
        }

        self.ensureOnePass();
        if (self.one_pass_engine) |*engine| {
            self.diagnostics.one_pass_attempts +|= 1;
            if (engine.capturesExact(input, range_start, range_end)) |captured| {
                if (captured != null) {
                    self.diagnostics.one_pass_completions +|= 1;
                    return captured;
                }
            } else |_| {}
        }

        const bit_state_request = dispatch.CaptureRequest{
            .phase = phase,
            .range_bytes = range_end - range_start,
            .uses_empty_width = self.prog.uses_empty_width,
        };
        const required = bit_state.requiredBitmapBytesForProg(
            self.prog,
            bit_state_request.range_bytes,
        ) catch null;
        if (required) |bytes|
            self.diagnostics.exact_bit_state_required_bytes_max = @max(
                self.diagnostics.exact_bit_state_required_bytes_max,
                bytes,
            );
        if (bit_state_request.admission(required) == .admit and self.ensureBitState()) {
            self.diagnostics.exact_bit_state_attempts +|= 1;
            const engine = &self.bit_state_engine.?;
            if (engine.capturesExact(input, range_start, range_end)) |captured| {
                if (captured != null) {
                    self.diagnostics.exact_bit_state_completions +|= 1;
                    return captured;
                }
            } else |_| {}
        }

        try self.ensureCaptureNfa();
        self.budget.exhausted = false;
        self.diagnostics.capture_nfa_attempts +|= 1;
        const captured = self.capture_engine.?.capturesExact(
            input,
            range_start,
            range_end,
        ) catch |err| switch (err) {
            error.InvalidRange => unreachable,
            error.OutOfMemory => return self.resourceError(error.OutOfMemory),
        };
        self.diagnostics.capture_nfa_completions +|= 1;
        return captured;
    }

    /// Materializes every slot pair as the same whole range after publication's
    /// all-captures-whole proof.
    fn aliasWhole(
        self: *Scratch,
        range_start: usize,
        range_end: usize,
    ) Error!match_types.CaptureView {
        const slots = try self.resultSlots();
        var group: usize = 0;
        while (group < slots.len) : (group += 2) {
            slots[group] = range_start;
            slots[group + 1] = range_end;
        }
        return .{ .slots = slots };
    }

    /// Uses inline storage for group zero plus one explicit group, allocating an
    /// overflow array only for larger proven-alias Programs.
    fn resultSlots(self: *Scratch) Error![]?usize {
        const slot_count = self.prog.capture_slots;
        if (slot_count <= self.inline_whole_result.len)
            return self.inline_whole_result[0..slot_count];
        if (self.overflow_whole_result.len == 0) {
            self.budget.exhausted = false;
            self.overflow_whole_result = self.allocator.alloc(
                ?usize,
                slot_count,
            ) catch |err| return self.resourceError(err);
        }
        return self.overflow_whole_result;
    }

    /// Attempts nonblocking shared Plan publication and allocates an Executor.
    /// Ineligibility, contention, or optional allocation failure leaves this
    /// route absent so exact replay continues.
    fn ensureOnePass(self: *Scratch) void {
        if (self.one_pass_engine != null or
            self.prog.capture_slots > one_pass.capture_slot_limit) return;
        const plan = self.state.tryEnsureOnePass() orelse return;
        if (one_pass.Executor.init(self.allocator, self.prog, plan)) |engine| {
            self.one_pass_engine = engine;
        } else |_| {}
    }

    /// Lazily creates matcher-local BitState and reports whether it is available;
    /// failure is an optimizer decline because complete capture NFA follows.
    fn ensureBitState(self: *Scratch) bool {
        if (self.bit_state_engine != null) return true;
        if (bit_state.Matcher.init(self.allocator, self.prog)) |engine| {
            self.bit_state_engine = engine;
            return true;
        } else |_| return false;
    }

    /// Creates the final complete capture executor. Unlike optional routes, its
    /// failure is surfaced and classified as backing OOM or scratch exhaustion.
    fn ensureCaptureNfa(self: *Scratch) Error!void {
        if (self.capture_engine != null) return;
        self.budget.exhausted = false;
        self.capture_engine = capture_nfa.Matcher.init(self.allocator, self.prog) catch |err|
            return self.resourceError(err);
    }

    /// Translates only BudgetAllocator denial to the public scratch-limit error;
    /// backing allocator failure remains OutOfMemory.
    fn resourceError(self: *const Scratch, err: error{OutOfMemory}) Error {
        return if (self.budget.exhausted) error.ScratchLimitExceeded else err;
    }
};
