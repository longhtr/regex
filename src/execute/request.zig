//! Typed request classification and optional-engine admission policy.
//!
//! Dispatch decisions are represented as small value types so policy crossovers
//! can be unit-tested independently of executor calls. Existence and range plans
//! combine requested result kind, anchoring facts, match priority, prefix length,
//! and complete closed-shape proof. Capture admission combines phase, assertion
//! use, checked bitmap size, and separate direct/exact bitmap ceilings.
//!
//! `OptimizerAttempt(T)` makes the critical semantic distinction explicit:
//! `complete` contains an answer (including false/null), while `decline` says the
//! accelerator did not answer and names why. A decline can never be collapsed to
//! a negative match.
//!
//! This module imports no engine and calls no executor. `matcher.zig`,
//! `search.zig`, and `capture.zig` perform concrete attempts and visibly own
//! fallback. Central constants document performance/resource policy rather than
//! hiding it in hot loops.

const std = @import("std");
const match_types = @import("../match.zig");

/// A one-byte prefix filters only one byte value and can remain dense; two-byte
/// prefixes admit first/last pair filtering before ordered-NFA startup.
pub const dfa_prefix_threshold_bytes: usize = 2;
/// The engine's direct-search BitState ceiling is 256 Ki bits.
pub const direct_bit_state_bitmap_bytes: usize = (256 * 1024) / 8;
/// Exact replay may use a bounded 4 MiB bitmap; larger products preserve
/// complete capture-NFA fallback while leaving most default scratch for paths.
pub const exact_bit_state_bitmap_bytes: usize = 4 * 1024 * 1024;
/// Small whole-range capture aliases avoid materializing a capture engine.
pub const max_whole_capture_alias_slots: usize = 16;

/// Complete physical routes available to a normalized existence request.
pub const ExistencePlan = enum {
    closed_prefix_shape,
    dfa,
};

/// Fully normalized captureless existence request. Callers validate bounds
/// before construction; `effectiveAnchor` applies compiler-proven text start.
pub const ExistenceRequest = struct {
    range_start: usize,
    range_end: usize,
    requested_anchor: match_types.Anchor,
    program_anchor_start: bool,
    program_anchor_end: bool,
    has_closed_prefix_shape: bool,
    whole_input: bool,

    /// Applies a compile-time proof that every match starts at absolute text
    /// start. A request may strengthen anchoring, but it cannot weaken a
    /// requirement shared by every successful Program path.
    pub fn effectiveAnchor(self: ExistenceRequest) match_types.Anchor {
        return if (self.program_anchor_start) .start else self.requested_anchor;
    }

    /// Selects a route that can answer the complete boolean request. Text-end
    /// anchoring stays on DFA/NFA machinery because range-end context is not
    /// represented by the otherwise closed prefix shape.
    pub fn plan(self: ExistenceRequest) ExistencePlan {
        if (self.program_anchor_end) return .dfa;
        if (self.has_closed_prefix_shape) return .closed_prefix_shape;
        return .dfa;
    }
};

/// Range discovery either is the public result or only narrows later capture
/// replay; the latter need not prefer a closed captureless shape.
pub const RangePurpose = enum {
    return_range,
    locate_captures,
};

/// Complete physical routes available to semantic range discovery.
pub const RangePlan = enum {
    closed_prefix_shape,
    dfa,
    ordered_nfa,
};

/// Inputs to range-route policy after bounds and effective anchoring are known.
pub const RangeRequest = struct {
    purpose: RangePurpose,
    match_kind: match_types.MatchKind,
    program_anchor_end: bool,
    prefix_len: usize,
    has_closed_prefix_shape: bool,

    /// Chooses range discovery without running an engine. Closed syntax shapes
    /// can directly answer public ranges; capture location and non-shape cases
    /// use DFA or ordered NFA so later replay starts from the semantic winner.
    pub fn plan(self: RangeRequest) RangePlan {
        if (self.program_anchor_end) return .dfa;
        if (self.purpose == .return_range and self.has_closed_prefix_shape)
            return .closed_prefix_shape;
        if (self.match_kind == .first and self.prefix_len < dfa_prefix_threshold_bytes)
            return .dfa;
        return .ordered_nfa;
    }
};

/// Capture exploration context. Direct search uses stricter admission than exact
/// replay of an already proven range.
pub const CapturePhase = enum {
    direct_search,
    located_exact,
    full_exact,
};

/// Static reason BitState was not attempted; no variant is a match answer.
pub const DeclineReason = enum {
    bitmap_size_overflow,
    bitmap_limit,
    assertion_range,
};

/// Bitmap admission result separated from execution success/failure.
pub const Admission = union(enum) {
    admit,
    decline: DeclineReason,
};

/// Optional accelerators never report semantic rejection through this channel.
pub const OptimizerDecline = enum {
    disabled,
    cache_busy,
    allocation_failure,
    state_limit,
    unproductive,
};

/// Builds the result-or-decline type shared by optional engines. `.complete`
/// includes legitimate negative answers; `.decline` says no answer was produced.
pub fn OptimizerAttempt(comptime Result: type) type {
    return union(enum) {
        complete: Result,
        decline: OptimizerDecline,
    };
}

/// Values relevant to BitState policy; callers separately compute the exact
/// checked bitmap-byte requirement from Program shape.
pub const CaptureRequest = struct {
    phase: CapturePhase,
    range_bytes: usize,
    uses_empty_width: bool,

    /// Applies phase-specific bitmap ceilings and direct-search assertion
    /// restrictions. Admission authorizes an attempt only; it says nothing about
    /// whether the regex matches.
    pub fn admission(self: CaptureRequest, required_bitmap_bytes: ?usize) Admission {
        const required = required_bitmap_bytes orelse
            return .{ .decline = .bitmap_size_overflow };
        return switch (self.phase) {
            .direct_search => if (required > direct_bit_state_bitmap_bytes)
                .{ .decline = .bitmap_limit }
            else if (self.uses_empty_width)
                .{ .decline = .assertion_range }
            else
                .admit,
            .located_exact => if (required > exact_bit_state_bitmap_bytes)
                .{ .decline = .bitmap_limit }
            else
                .admit,
            .full_exact => if (required > exact_bit_state_bitmap_bytes)
                .{ .decline = .bitmap_limit }
            else
                .admit,
        };
    }
};

/// Admits the cheap whole-range alias only while its result slots remain within
/// the deliberately small materialization policy.
pub fn aliasesWholeCaptures(capture_slots: u32) bool {
    return capture_slots <= max_whole_capture_alias_slots;
}

const testing = std.testing;

test "Dispatch plans and admission reasons make every crossover explicit" {
    const existence = ExistenceRequest{
        .range_start = 0,
        .range_end = 32,
        .requested_anchor = .unanchored,
        .program_anchor_start = true,
        .program_anchor_end = false,
        .has_closed_prefix_shape = false,
        .whole_input = true,
    };
    try testing.expectEqual(match_types.Anchor.start, existence.effectiveAnchor());
    try testing.expectEqual(ExistencePlan.dfa, existence.plan());

    try testing.expectEqual(RangePlan.closed_prefix_shape, (RangeRequest{
        .purpose = .return_range,
        .match_kind = .longest,
        .program_anchor_end = false,
        .prefix_len = 8,
        .has_closed_prefix_shape = true,
    }).plan());
    try testing.expectEqual(RangePlan.dfa, (RangeRequest{
        .purpose = .locate_captures,
        .match_kind = .first,
        .program_anchor_end = false,
        .prefix_len = 0,
        .has_closed_prefix_shape = false,
    }).plan());
    try testing.expectEqual(RangePlan.ordered_nfa, (RangeRequest{
        .purpose = .locate_captures,
        .match_kind = .first,
        .program_anchor_end = false,
        .prefix_len = dfa_prefix_threshold_bytes,
        .has_closed_prefix_shape = false,
    }).plan());

    try testing.expectEqual(Admission.admit, (CaptureRequest{
        .phase = .direct_search,
        .range_bytes = 4096,
        .uses_empty_width = false,
    }).admission(direct_bit_state_bitmap_bytes));
    try testing.expectEqual(
        Admission{ .decline = .assertion_range },
        (CaptureRequest{
            .phase = .direct_search,
            .range_bytes = 0,
            .uses_empty_width = true,
        }).admission(direct_bit_state_bitmap_bytes),
    );
    try testing.expectEqual(Admission.admit, (CaptureRequest{
        .phase = .located_exact,
        .range_bytes = 4096,
        .uses_empty_width = false,
    }).admission(exact_bit_state_bitmap_bytes));
    try testing.expectEqual(Admission.admit, (CaptureRequest{
        .phase = .located_exact,
        .range_bytes = 4096,
        .uses_empty_width = true,
    }).admission(exact_bit_state_bitmap_bytes));
    try testing.expectEqual(
        Admission{ .decline = .bitmap_size_overflow },
        (CaptureRequest{
            .phase = .full_exact,
            .range_bytes = 0,
            .uses_empty_width = false,
        }).admission(null),
    );
    const declined = OptimizerAttempt(bool){ .decline = .cache_busy };
    try testing.expectEqual(OptimizerDecline.cache_busy, declined.decline);
    try testing.expect(aliasesWholeCaptures(max_whole_capture_alias_slots));
    try testing.expect(!aliasesWholeCaptures(max_whole_capture_alias_slots + 2));
}
