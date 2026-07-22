//! Private observability boundary for qualification and benchmarks.
//!
//! Production users import `root.zig`, whose API deliberately does not expose or
//! select a physical engine. This sibling root re-exports the same product owners
//! and adds read-only adapters for cumulative Matcher routes, requested-byte
//! accounting, and lazy/DFA cache snapshots. Tests use those observations only
//! when the route itself is under qualification; every such check also verifies
//! the public semantic result.
//!
//! Shared-state snapshots are nonblocking and may be absent under contention.
//! Nothing here can force a route, acquire ownership of a cache, or turn a private
//! layout/threshold into public policy. Keeping the seam in one import root lets
//! engineering tools observe implementation behavior without leaking it through
//! normal package documentation or compatibility promises.

const api = @import("root.zig");
const compiled_module = @import("compiled.zig");
const matcher_module = @import("matcher.zig");
const filtered_module = @import("collection/filtered.zig");

pub const Regex = api.Regex;
pub const Matcher = api.Matcher;
pub const Rewrite = api.Rewrite;
pub const Set = api.Set;
pub const Filtered = api.Filtered;
pub const MatchKind = api.MatchKind;
pub const CompileOptions = api.CompileOptions;

/// Cumulative route summary derived from one Matcher's private counters. Bits say
/// a route occurred at least once; they do not identify a specific request.
pub const BenchmarkRoute = packed struct {
    capture_direct: bool = false,
    capture_alias: bool = false,
    capture_one_pass: bool = false,
    capture_bit_state: bool = false,
    capture_nfa: bool = false,
    dfa: bool = false,
    dfa_decline: bool = false,
    dfa_decline_disabled: bool = false,
    dfa_decline_cache_busy: bool = false,
    dfa_decline_allocation: bool = false,
    dfa_decline_state_limit: bool = false,
    dfa_decline_unproductive: bool = false,
    dfa_range: bool = false,
    dfa_full: bool = false,
};

/// Collapses detailed cumulative diagnostics to a stable benchmark record.
pub fn benchmarkRoute(matcher: *const Matcher) BenchmarkRoute {
    const metrics = matcher_module.debugMetrics(matcher);
    return .{
        .capture_direct = metrics.capture_direct_bit_state_completions != 0,
        .capture_alias = metrics.capture_alias_completions != 0,
        .capture_one_pass = metrics.capture_one_pass_completions != 0,
        .capture_bit_state = metrics.capture_exact_bit_state_completions != 0,
        .capture_nfa = metrics.capture_nfa_completions != 0,
        .dfa = metrics.dfa_attempts != 0,
        .dfa_decline = metrics.dfa_declines != 0,
        .dfa_decline_disabled = metrics.dfa_disabled_declines != 0,
        .dfa_decline_cache_busy = metrics.dfa_cache_busy_declines != 0,
        .dfa_decline_allocation = metrics.dfa_allocation_declines != 0,
        .dfa_decline_state_limit = metrics.dfa_state_limit_declines != 0,
        .dfa_decline_unproductive = metrics.dfa_unproductive_declines != 0,
        .dfa_range = metrics.dfa_range_attempts != 0,
        .dfa_full = metrics.dfa_full_attempts != 0,
    };
}

pub fn setRetainedBytes(
    collection: *const Set,
    matcher: *const Set.Matcher,
) usize {
    return collection.collectionMetrics().requested_live_bytes +|
        matcher.metrics().requested_live_bytes;
}

pub fn filteredRetainedBytes(
    collection: *const Filtered,
    matcher: *const Filtered.Matcher,
) usize {
    return collection.collectionMetrics().requested_live_bytes +|
        filtered_module.debugMatcherBytes(matcher);
}

/// Nonblocking snapshots return null under shared-state contention.
pub fn tryLazyMetrics(expression: *const Regex) ?compiled_module.LazyMetrics {
    return expression.state.tryLazyMetrics();
}

pub fn tryCacheMetrics(expression: *const Regex) ?@import("engine/accelerate/shared_dfa.zig").Metrics {
    return expression.state.shared.caches.tryMetrics();
}

pub fn tryPhysicalCacheMetrics(expression: *const Regex) ?@import("engine/accelerate/shared_dfa.zig").PhysicalMetrics {
    return expression.state.shared.caches.tryPhysicalMetrics();
}
