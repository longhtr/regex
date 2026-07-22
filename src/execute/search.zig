//! Shared-DFA attempt protocol for boolean, range, count, and full requests.
//!
//! Each operation follows the same lock discipline:
//!
//! 1. if DFA is disabled, return `.decline(.disabled)`;
//! 2. try a shared lock and complete using known transitions only;
//! 3. if a transition is missing, release shared access and try the exclusive
//!    lock without waiting;
//! 4. ensure the role-specific cache and construct missing states;
//! 5. translate allocation/state/productivity errors to typed decline;
//! 6. retain exact partial state after policy-only productivity declines, while
//!    discarding caches after hard allocation/state-limit failures.
//!
//! Boolean and count need only the forward Program. Exact full matching uses its
//! separate full cache. Unanchored range discovery runs forward to obtain an end,
//! then may lazily compile the reverse Program and run reverse from that endpoint
//! to recover the leftmost start. Prefix and absolute-end facts can narrow this
//! composition without changing assertion context.
//!
//! This layer never runs complete fallback and never chooses whether a request
//! should prefer DFA. It returns `OptimizerAttempt` to Matcher, which restarts
//! NFA execution from clean state after decline.

const std = @import("std");
const match_types = @import("../match.zig");
const compiled_module = @import("../compiled.zig");
const dispatch = @import("request.zig");
const dfa = @import("../engine/accelerate/dfa.zig");

pub const RangeAttempt = dispatch.OptimizerAttempt(?match_types.Match);
pub const BooleanAttempt = dispatch.OptimizerAttempt(bool);
pub const CountAttempt = dispatch.OptimizerAttempt(usize);

/// Counts a language proven unable to match empty without reverse range
/// reconstruction. Match endpoints alone define non-overlapping progress, so
/// one forward DFA and one cache lock serve the entire input.
pub fn countNonEmpty(state: *compiled_module.State, input: []const u8) CountAttempt {
    std.debug.assert(!state.program.can_match_empty);
    const caches = &state.shared.caches;
    if (!caches.enabled()) return .{ .decline = .disabled };
    if (tryLockKnown(state)) {
        const known = countNonEmptyKnown(state, input);
        caches.unlockShared();
        if (known) |result| return .{ .complete = result } else |_| {}
    }
    if (!caches.tryLock()) return .{ .decline = .cache_busy };
    defer caches.unlock();

    const forward = caches.ensureForward(
        state.allocator,
        &state.program,
    ) catch return .{ .decline = .allocation_failure };
    const result = (if (state.program.anchor_line_start)
        countLineAnchoredWithForward(forward, input, true)
    else
        countWithForward(forward, input, true)) catch |err| {
        discardForwardOnHardFailure(caches, state.allocator, err);
        return .{ .decline = optimizerDecline(err) };
    };
    return .{ .complete = result };
}

/// Counts known-DFA nonempty endpoints, intentionally excluding empty matches
/// whose iteration progress requires Matcher-level handling.
fn countNonEmptyKnown(state: *compiled_module.State, input: []const u8) error{StateLimit}!usize {
    const forward = state.shared.caches.forward() orelse return error.StateLimit;
    return if (state.program.anchor_line_start)
        countLineAnchoredWithForward(forward, input, false) catch error.StateLimit
    else
        countWithForward(forward, input, false) catch error.StateLimit;
}

/// Counts only legal line starts for Programs proven begin-line anchored;
/// `construct` selects mutating versus known-transition-only DFA access.
fn countLineAnchoredWithForward(
    forward: anytype,
    input: []const u8,
    comptime construct: bool,
) error{ StateLimit, Unproductive }!usize {
    var total: usize = 0;
    var line_start: usize = 0;
    while (line_start < input.len) {
        const endpoint = (if (construct)
            forward.findEnd(input, line_start, input.len, .start) catch |err| switch (err) {
                error.Unproductive => return error.Unproductive,
                else => return error.StateLimit,
            }
        else
            forward.findEndKnown(input, line_start, input.len, .start) catch return error.StateLimit);
        if (endpoint) |end| {
            if (end <= line_start) return error.StateLimit;
            total += 1;
            // A match may end exactly at the next line start after consuming a
            // newline. Preserve that legal adjacent start; otherwise skip to
            // the next newline in one vectorized search.
            if (end < input.len and input[end - 1] == '\n') {
                line_start = end;
                continue;
            }
            const newline = std.mem.indexOfScalarPos(u8, input, end, '\n') orelse break;
            line_start = newline + 1;
        } else {
            const newline = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse break;
            line_start = newline + 1;
        }
    }
    return total;
}

/// Repeatedly finds nonempty endpoints and advances by whole matches;
/// `construct` selects mutating versus known-transition-only DFA access.
fn countWithForward(
    forward: anytype,
    input: []const u8,
    comptime construct: bool,
) error{ StateLimit, Unproductive }!usize {
    var total: usize = 0;
    var position: usize = 0;
    while (position < input.len) {
        const endpoint = (if (construct)
            forward.findEnd(input, position, input.len, .unanchored) catch |err| switch (err) {
                error.Unproductive => return error.Unproductive,
                else => return error.StateLimit,
            }
        else
            forward.findEndKnown(input, position, input.len, .unanchored) catch return error.StateLimit) orelse break;
        // A non-empty language must advance from every requested search start.
        if (endpoint <= position) return error.StateLimit;
        total += 1;
        position = endpoint;
    }
    return total;
}

/// Attempts whole-input existence through the shared forward cache, using known
/// transitions under shared access before exclusive construction.
pub fn isMatch(
    state: *compiled_module.State,
    input: []const u8,
    anchor: match_types.Anchor,
) BooleanAttempt {
    const caches = &state.shared.caches;
    if (!caches.enabled()) return .{ .decline = .disabled };
    if (tryLockKnown(state)) {
        const known = isMatchKnown(state, input, anchor);
        caches.unlockShared();
        if (known) |result| return .{ .complete = result } else |_| {}
    }
    if (!caches.tryLock()) return .{ .decline = .cache_busy };
    defer caches.unlock();

    if (anchor == .unanchored and state.program.anchor_end) {
        if (state.ensureReverse()) |reverse_prog| {
            if (reverse_prog.anchor_start) {
                const reverse = caches.ensureReverse(
                    state.allocator,
                    reverse_prog,
                ) catch return .{ .decline = .allocation_failure };
                const start = reverse.findStartReverse(
                    input,
                    0,
                    input.len,
                ) catch |err| {
                    discardReverseOnHardFailure(caches, state.allocator, err);
                    return .{ .decline = optimizerDecline(err) };
                };
                return .{ .complete = start != null };
            }
        } else |_| {}
    }
    const forward = caches.ensureForward(
        state.allocator,
        &state.program,
    ) catch return .{ .decline = .allocation_failure };
    const result = forward.isMatch(
        input,
        0,
        input.len,
        anchor,
    ) catch |err| {
        discardForwardOnHardFailure(caches, state.allocator, err);
        return .{ .decline = optimizerDecline(err) };
    };
    return .{ .complete = result };
}

/// DFA existence over absolute bounds. Assertions receive the complete input;
/// the range only limits legal consumption and start injection.
pub fn isMatchIn(
    state: *compiled_module.State,
    input: []const u8,
    range_start: usize,
    range_end: usize,
    anchor: match_types.Anchor,
) error{InvalidRange}!BooleanAttempt {
    const caches = &state.shared.caches;
    if (!caches.enabled()) return .{ .decline = .disabled };
    if (tryLockKnown(state)) {
        const known = if (caches.forward()) |forward|
            forward.isMatchKnown(input, range_start, range_end, anchor)
        else
            error.StateLimit;
        caches.unlockShared();
        if (known) |result| return .{ .complete = result } else |err| switch (err) {
            error.InvalidRange => return error.InvalidRange,
            error.StateLimit => {},
        }
    }
    if (!caches.tryLock()) return .{ .decline = .cache_busy };
    defer caches.unlock();

    if (anchor == .unanchored and state.program.anchor_end) {
        const reverse_prog = state.ensureReverse() catch
            return .{ .decline = .allocation_failure };
        if (reverse_prog.anchor_start) {
            const reverse = caches.ensureReverse(
                state.allocator,
                reverse_prog,
            ) catch return .{ .decline = .allocation_failure };
            const start = reverse.findStartReverse(
                input,
                range_start,
                range_end,
            ) catch |err| switch (err) {
                error.InvalidRange => return error.InvalidRange,
                error.OutOfMemory, error.StateLimit, error.Unproductive => {
                    discardReverseOnHardFailure(caches, state.allocator, err);
                    return .{ .decline = optimizerDecline(err) };
                },
            };
            return .{ .complete = start != null };
        }
    }

    const forward = caches.ensureForward(
        state.allocator,
        &state.program,
    ) catch return .{ .decline = .allocation_failure };
    const result = forward.isMatch(
        input,
        range_start,
        range_end,
        anchor,
    ) catch |err| switch (err) {
        error.InvalidRange => return error.InvalidRange,
        error.OutOfMemory, error.StateLimit, error.Unproductive => {
            discardForwardOnHardFailure(caches, state.allocator, err);
            return .{ .decline = optimizerDecline(err) };
        },
    };
    return .{ .complete = result };
}

/// Attempts range discovery. Forward DFA finds the selected endpoint; unanchored
/// recovery may ensure a reverse Program/cache and search backward for the start.
pub fn find(
    state: *compiled_module.State,
    input: []const u8,
    range_start: usize,
    range_end: usize,
    anchor: match_types.Anchor,
) error{InvalidRange}!RangeAttempt {
    const caches = &state.shared.caches;
    if (!caches.enabled()) return .{ .decline = .disabled };
    if (tryLockKnown(state)) {
        const known = findKnown(state, input, range_start, range_end, anchor);
        caches.unlockShared();
        if (known) |result| return .{ .complete = result } else |err| switch (err) {
            error.InvalidRange => return error.InvalidRange,
            error.StateLimit => {},
        }
    }
    if (!caches.tryLock()) return .{ .decline = .cache_busy };
    defer caches.unlock();

    // When every match ends at original end-text, search directly from the
    // only possible endpoint instead of filling the forward cache.
    if (anchor == .unanchored and state.program.anchor_end) {
        const reverse_prog = state.ensureReverse() catch
            return .{ .decline = .allocation_failure };
        if (reverse_prog.anchor_start) {
            const reverse = caches.ensureReverse(
                state.allocator,
                reverse_prog,
            ) catch return .{ .decline = .allocation_failure };
            const match_start = reverse.findStartReverse(
                input,
                range_start,
                range_end,
            ) catch |err| switch (err) {
                error.InvalidRange => return error.InvalidRange,
                error.OutOfMemory, error.StateLimit, error.Unproductive => {
                    discardReverseOnHardFailure(caches, state.allocator, err);
                    return .{ .decline = optimizerDecline(err) };
                },
            } orelse return .{ .complete = null };
            return .{ .complete = .{ .start = match_start, .end = range_end } };
        }
    }

    const forward = caches.ensureForward(
        state.allocator,
        &state.program,
    ) catch return .{ .decline = .allocation_failure };
    if (anchor == .unanchored and state.program.anchor_line_start) {
        const found = findLineAnchored(
            forward,
            input,
            range_start,
            range_end,
        ) catch |err| {
            discardForwardOnHardFailure(caches, state.allocator, err);
            return .{ .decline = optimizerDecline(err) };
        };
        return .{ .complete = found };
    }
    const match_end = forward.findEnd(
        input,
        range_start,
        range_end,
        anchor,
    ) catch |err| switch (err) {
        error.InvalidRange => return error.InvalidRange,
        error.OutOfMemory, error.StateLimit, error.Unproductive => {
            discardForwardOnHardFailure(caches, state.allocator, err);
            return .{ .decline = optimizerDecline(err) };
        },
    } orelse return .{ .complete = null };
    if (anchor == .start) return .{
        .complete = .{ .start = range_start, .end = match_end },
    };

    const reverse_prog = state.ensureReverse() catch
        return .{ .decline = .allocation_failure };
    const reverse = caches.ensureReverse(
        state.allocator,
        reverse_prog,
    ) catch return .{ .decline = .allocation_failure };
    const match_start = reverse.findStartReverse(
        input,
        range_start,
        match_end,
    ) catch |err| switch (err) {
        error.InvalidRange => return error.InvalidRange,
        error.OutOfMemory, error.StateLimit, error.Unproductive => {
            discardReverseOnHardFailure(caches, state.allocator, err);
            return .{ .decline = optimizerDecline(err) };
        },
    } orelse {
        caches.discardReverse(state.allocator);
        return .{ .decline = .state_limit };
    };
    return .{ .complete = .{ .start = match_start, .end = match_end } };
}

/// Tries legal line starts in order for a Program whose begin-line requirement
/// was proven during publication.
fn findLineAnchored(
    forward: *dfa.Matcher,
    input: []const u8,
    range_start: usize,
    range_end: usize,
) error{ InvalidRange, OutOfMemory, StateLimit, Unproductive }!?match_types.Match {
    var line_start = range_start;
    if (line_start != 0 and input[line_start - 1] != '\n') {
        const newline = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse
            return null;
        if (newline >= range_end) return null;
        line_start = newline + 1;
    }
    while (line_start <= range_end) {
        const endpoint = try forward.findEnd(
            input,
            line_start,
            range_end,
            .start,
        );
        if (endpoint) |end| return .{ .start = line_start, .end = end };
        if (line_start == range_end) return null;
        const newline = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse
            return null;
        if (newline >= range_end) return null;
        line_start = newline + 1;
    }
    return null;
}

/// Attempts exact-range acceptance through the independent full-match cache.
/// It first probes immutable known transitions under a shared lock, then obtains
/// exclusive ownership to create or extend the role. Hard construction failures
/// discard that role; a reached endpoint answers true only at `range_end`.
pub fn fullMatch(
    state: *compiled_module.State,
    input: []const u8,
    range_start: usize,
    range_end: usize,
) error{InvalidRange}!BooleanAttempt {
    const caches = &state.shared.caches;
    if (!caches.enabled()) return .{ .decline = .disabled };
    if (tryLockKnown(state)) {
        const known = if (caches.full()) |engine|
            engine.findEndKnown(input, range_start, range_end, .start)
        else
            error.StateLimit;
        caches.unlockShared();
        if (known) |endpoint| {
            return .{ .complete = if (endpoint) |value| value == range_end else false };
        } else |err| switch (err) {
            error.InvalidRange => return error.InvalidRange,
            error.StateLimit => {},
        }
    }
    if (!caches.tryLock()) return .{ .decline = .cache_busy };
    defer caches.unlock();

    const engine = caches.ensureFull(
        state.allocator,
        &state.program,
    ) catch return .{ .decline = .allocation_failure };
    const endpoint = engine.findEndForFullMatch(
        input,
        range_start,
        range_end,
    ) catch |err| switch (err) {
        error.InvalidRange => return error.InvalidRange,
        error.OutOfMemory, error.StateLimit => {
            caches.discardFull(state.allocator);
            return .{ .decline = optimizerDecline(err) };
        },
    };
    return .{ .complete = if (endpoint) |value| value == range_end else false };
}

fn tryLockKnown(state: *compiled_module.State) bool {
    return if (state.program.uses_empty_width)
        state.shared.caches.tryLockSharedLimited(1)
    else
        state.shared.caches.tryLockShared();
}

/// Answers whole-input existence using only already published transitions. An
/// end-anchored/start-anchored reverse Program can answer in one reverse pass;
/// all other requests use the forward role. Missing roles or edges become
/// `StateLimit`, the caller's unknown signal rather than semantic rejection.
fn isMatchKnown(
    state: *compiled_module.State,
    input: []const u8,
    anchor: match_types.Anchor,
) error{StateLimit}!bool {
    if (anchor == .unanchored and state.program.anchor_end) {
        if (state.shared.reverse_program) |reverse_prog| {
            if (reverse_prog.anchor_start) {
                const reverse = state.shared.caches.reverse() orelse return error.StateLimit;
                const start = reverse.findStartReverseKnown(
                    input,
                    0,
                    input.len,
                ) catch return error.StateLimit;
                return start != null;
            }
        }
    }
    const forward = state.shared.caches.forward() orelse return error.StateLimit;
    const endpoint = forward.findEndKnown(
        input,
        0,
        input.len,
        anchor,
    ) catch return error.StateLimit;
    return endpoint != null;
}

/// Known-transition-only forward/reverse composition used while holding a shared
/// lock. Any missing transition returns Unknown and triggers a later exclusive
/// attempt or complete fallback.
fn findKnown(
    state: *compiled_module.State,
    input: []const u8,
    range_start: usize,
    range_end: usize,
    anchor: match_types.Anchor,
) error{ InvalidRange, StateLimit }!?match_types.Match {
    if (anchor == .unanchored and state.program.anchor_end) {
        const reverse_prog = state.shared.reverse_program orelse return error.StateLimit;
        if (reverse_prog.anchor_start) {
            const reverse = state.shared.caches.reverse() orelse return error.StateLimit;
            const match_start = (try reverse.findStartReverseKnown(
                input,
                range_start,
                range_end,
            )) orelse return null;
            return .{ .start = match_start, .end = range_end };
        }
    }

    const forward = state.shared.caches.forward() orelse return error.StateLimit;
    const match_end = (try forward.findEndKnown(
        input,
        range_start,
        range_end,
        anchor,
    )) orelse return null;
    if (anchor == .start) return .{ .start = range_start, .end = match_end };
    const reverse = state.shared.caches.reverse() orelse return error.StateLimit;
    const match_start = (try reverse.findStartReverseKnown(
        input,
        range_start,
        match_end,
    )) orelse return error.StateLimit;
    return .{ .start = match_start, .end = match_end };
}

/// Productivity is a policy decline, not cache corruption: every state and edge
/// published before it remains exact and useful to later warmed operations.
/// Allocation/state-limit failures may leave a cache unable to make progress and
/// therefore retain the established discard-and-restart behavior.
fn discardForwardOnHardFailure(caches: anytype, allocator: std.mem.Allocator, err: anytype) void {
    if (err != error.Unproductive) caches.discardForward(allocator);
}

/// Applies the same retain-on-productivity-decline policy to the reverse role.
fn discardReverseOnHardFailure(caches: anytype, allocator: std.mem.Allocator, err: anytype) void {
    if (err != error.Unproductive) caches.discardReverse(allocator);
}

/// Maps physical DFA errors to the architecture-visible decline vocabulary
/// without conflating them with a negative answer.
fn optimizerDecline(
    err: error{ InvalidRange, OutOfMemory, StateLimit, Unproductive },
) dispatch.OptimizerDecline {
    return switch (err) {
        error.OutOfMemory => .allocation_failure,
        error.StateLimit => .state_limit,
        error.Unproductive => .unproductive,
        error.InvalidRange => unreachable,
    };
}
