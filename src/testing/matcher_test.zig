//! Cross-cutting Matcher qualification for dispatch, resources, and ownership.
//!
//! Public results are paired with private route/accounting snapshots only where
//! physical behavior is itself under qualification: DFA partitioning and decline,
//! lazy reverse/OnePass publication, direct/alias/BitState/capture-NFA routes,
//! exact scratch ceilings, and warmed reuse. Every route assertion also checks the
//! semantic answer.
//!
//! Allocation-failure schedules prove transactional teardown. Concurrency cases
//! share Regex state only, creating independent Matchers. Additional sections
//! qualify ranged context, end anchoring, capture-name lifetime, stored results,
//! work admission, count specialization, and encoding-aware empty iteration.

const std = @import("std");
const match_types = @import("../match.zig");
const budget_allocator = @import("../support/budget_allocator.zig");
const regex_module = @import("../regex.zig");
const dispatch = @import("../execute/request.zig");
const dfa_search = @import("../execute/search.zig");
const program = @import("../program/program.zig");
const parser = @import("../syntax/parser.zig");
const matcher_module = @import("../matcher.zig");

const CompileOptions = regex_module.CompileOptions;
const Regex = regex_module.Regex;
const Matcher = matcher_module.Matcher;

fn testOptions() CompileOptions {
    return .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
        .max_instructions = 100_000,
    };
}

const testing = std.testing;

fn allocationCompile(allocator: std.mem.Allocator) !void {
    const result = try Regex.compile(allocator, "(ab|a)+c", testOptions());
    var expression = switch (result) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer expression.deinit();
}

fn allocationLazyReverse(allocator: std.mem.Allocator) !void {
    const result = try Regex.compile(allocator, "[a-z]+z", testOptions());
    var expression = switch (result) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer expression.deinit();
    _ = try expression.state.ensureReverse();
}

fn allocationSharedDfa(allocator: std.mem.Allocator) !void {
    const result = try Regex.compile(allocator, "(ab|a)+c", testOptions());
    var expression = switch (result) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer expression.deinit();
    _ = try expression.state.shared.caches.ensureForward(
        expression.state.allocator,
        &expression.state.program,
    );
}

fn allocationCapture(allocator: std.mem.Allocator, expression: *const Regex) !void {
    var matcher = try Matcher.init(allocator, expression);
    defer matcher.deinit();
    _ = try matcher.captures("ababac");
}

fn allocationCompilePattern(allocator: std.mem.Allocator, pattern: []const u8) !void {
    const result = try Regex.compile(allocator, pattern, testOptions());
    var expression = switch (result) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    expression.deinit();
}

fn allocationCopiedCaptures(allocator: std.mem.Allocator, expression: *const Regex) !void {
    var matcher = try Matcher.init(allocator, expression);
    defer matcher.deinit();
    if (try matcher.copyCaptures(allocator, "ababac")) |value| {
        var captures = value;
        captures.deinit();
    }
}

fn allocationMatches(allocator: std.mem.Allocator, expression: *const Regex) !void {
    var matcher = try Matcher.init(testing.allocator, expression);
    defer matcher.deinit();
    var matches = try matcher.findAll(allocator, "ababa", 3);
    matches.deinit();
}

test "Public range and captures preserve nested nullable priority" {
    const compiled = try Regex.compile(
        testing.allocator,
        "(?m:(?:(?:(?:\\s\\S*)?)*?)*$)",
        testOptions(),
    );
    var expression = compiled.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, matcher.find("\r\n").?);
    const captured = (try matcher.captures("\r\n")).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, captured.group(0).?);

    const line_compiled = try Regex.compile(
        testing.allocator,
        "(?m:^(?:(?:(?:\\s\\S*)?)*?)*$)",
        testOptions(),
    );
    var line_expression = line_compiled.success;
    defer line_expression.deinit();
    var line_matcher = try Matcher.init(testing.allocator, &line_expression);
    defer line_matcher.deinit();
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 2 }, line_matcher.find("\r\n").?);
}

test "Compile memory budget rejects before exceeding requested bytes" {
    const result = try Regex.compile(testing.allocator, "a", .{
        .compile_memory = .{ .bytes = 0 },
    });
    try testing.expect(result == .diagnostic);
    try testing.expectEqual(parser.ErrorCode.resource_limit, result.diagnostic.code);
}

test "Matcher scratch budget is a hard allocation ceiling" {
    const result = try Regex.compile(testing.allocator, "a", testOptions());
    var expression = result.success;
    defer expression.deinit();
    try testing.expectError(
        error.ScratchLimitExceeded,
        Matcher.initWithOptions(testing.allocator, &expression, .{
            .scratch_memory = .{ .bytes = 0 },
        }),
    );

    var measured = try Matcher.initWithOptions(testing.allocator, &expression, .{
        .scratch_memory = .unlimited,
    });
    const required = measured.budget.peak + @sizeOf(budget_allocator.BudgetAllocator);
    measured.deinit();
    try testing.expect(required > @sizeOf(budget_allocator.BudgetAllocator));
    try testing.expectError(
        error.ScratchLimitExceeded,
        Matcher.initWithOptions(testing.allocator, &expression, .{
            .scratch_memory = .{ .bytes = required - 1 },
        }),
    );
    var exact = try Matcher.initWithOptions(testing.allocator, &expression, .{
        .scratch_memory = .{ .bytes = required },
    });
    exact.deinit();
}

test "Matcher metrics account for scratch and monotonic growth" {
    const result = try Regex.compile(testing.allocator, "(a+)(b+)", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    const initial = matcher.metrics();
    try testing.expect(initial.requested_live_bytes > @sizeOf(budget_allocator.BudgetAllocator));
    try testing.expect(initial.requested_peak_bytes >= initial.requested_live_bytes);
    try testing.expect(initial.allocation_count > 1);

    _ = (try matcher.captures("aaabbb")).?;
    const captured = matcher.metrics();
    try testing.expect(captured.requested_live_bytes > initial.requested_live_bytes);
    try testing.expect(captured.requested_peak_bytes >= captured.requested_live_bytes);
    try testing.expect(captured.allocation_count > initial.allocation_count);

    _ = (try matcher.captures("ab")).?;
    const reused = matcher.metrics();
    try testing.expectEqual(captured.requested_live_bytes, reused.requested_live_bytes);
    try testing.expectEqual(captured.requested_peak_bytes, reused.requested_peak_bytes);
    try testing.expectEqual(captured.allocation_count, reused.allocation_count);
}

test "Matcher metrics expose cumulative DFA fallback outcomes" {
    var options = testOptions();
    options.dfa_memory = .disabled;
    const result = try Regex.compile(testing.allocator, "(a|b)+c", options);
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expectEqual(@as(?match_types.Match, .{ .start = 0, .end = 3 }), matcher.find("abc"));
    try testing.expect(matcher.fullMatch("abc"));
    const metrics = matcher_module.debugMetrics(&matcher);
    try testing.expectEqual(@as(usize, 2), metrics.dfa_attempts);
    try testing.expectEqual(metrics.dfa_attempts, metrics.dfa_declines);
    try testing.expectEqual(@as(usize, 1), metrics.dfa_range_attempts);
    try testing.expectEqual(@as(usize, 1), metrics.dfa_full_attempts);
    try testing.expectEqual(@as(usize, 0), metrics.dfa_boolean_attempts);
    try testing.expectEqual(metrics.dfa_declines, metrics.dfa_disabled_declines);
    try testing.expectEqual(@as(usize, 0), metrics.dfa_cache_busy_declines);
}

test "Bounded optional full matching retains the complete DFA through default repeat limits" {
    const repetitions = 1000;
    const pattern = try std.fmt.allocPrint(
        testing.allocator,
        "(?:a?){{{d}}}a{{{d}}}",
        .{ repetitions, repetitions },
    );
    defer testing.allocator.free(pattern);
    const input = try testing.allocator.alloc(u8, repetitions);
    defer testing.allocator.free(input);
    @memset(input, 'a');

    const result = try Regex.compile(testing.allocator, pattern, testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expect(matcher.fullMatch(input));
    const metrics = matcher_module.debugMetrics(&matcher);
    try testing.expectEqual(@as(usize, 1), metrics.dfa_full_attempts);
    try testing.expectEqual(@as(usize, 0), metrics.dfa_declines);
    try testing.expect(!matcher.fullMatch(input[0 .. input.len - 1]));
}

test "Bounded optional full matching falls back exactly under a small DFA budget" {
    const repetitions = 256;
    const pattern = try std.fmt.allocPrint(
        testing.allocator,
        "(?:a?){{{d}}}a{{{d}}}",
        .{ repetitions, repetitions },
    );
    defer testing.allocator.free(pattern);
    const input = try testing.allocator.alloc(u8, repetitions);
    defer testing.allocator.free(input);
    @memset(input, 'a');

    var options = testOptions();
    options.dfa_memory = .{ .bytes = 64 * 1024 };
    const result = try Regex.compile(testing.allocator, pattern, options);
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expect(matcher.fullMatch(input));
    const metrics = matcher_module.debugMetrics(&matcher);
    try testing.expectEqual(@as(usize, 1), metrics.dfa_full_attempts);
    try testing.expectEqual(@as(usize, 1), metrics.dfa_allocation_declines);
    try testing.expect(!matcher.fullMatch(input[0 .. input.len - 1]));
}

test "Runtime matcher budget denial reports scratch limit and remains reusable" {
    const result = try Regex.compile(testing.allocator, "(a)(b)", .{
        .match_kind = .longest,
    });
    var expression = result.success;
    defer expression.deinit();

    var probe = try Matcher.initWithOptions(testing.allocator, &expression, .{
        .scratch_memory = .unlimited,
    });
    const base = probe.budget.live + @sizeOf(budget_allocator.BudgetAllocator);
    _ = try probe.captures("ab");
    try testing.expect(probe.budget.peak + @sizeOf(budget_allocator.BudgetAllocator) > base);
    probe.deinit();

    var limited = try Matcher.initWithOptions(testing.allocator, &expression, .{
        .scratch_memory = .{ .bytes = base },
    });
    defer limited.deinit();
    try testing.expectError(error.ScratchLimitExceeded, limited.captures("ab"));
    try testing.expect(limited.isMatch("ab"));

    var iterator_limited = try Matcher.initWithOptions(testing.allocator, &expression, .{
        .scratch_memory = .{ .bytes = base },
    });
    defer iterator_limited.deinit();
    var captures = iterator_limited.captureIterator("ab");
    try testing.expectError(error.ScratchLimitExceeded, captures.next());
    try testing.expect((try captures.next()) == null);
    try testing.expect(iterator_limited.isMatch("ab"));
}

test "Compile and capture owners survive every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationCompile, .{});
    try testing.checkAllAllocationFailures(testing.allocator, allocationLazyReverse, .{});
    try testing.checkAllAllocationFailures(testing.allocator, allocationSharedDfa, .{});

    const result = try Regex.compile(testing.allocator, "(ab|a)+c", testOptions());
    var expression = result.success;
    defer expression.deinit();
    for ([_][]const u8{
        "[[:alpha:]]+",
        "\\Q[a-z]+\\E",
        "a*a*[a-c]{2}[a-c]{3,4}",
    }) |pattern|
        try testing.checkAllAllocationFailures(
            testing.allocator,
            allocationCompilePattern,
            .{pattern},
        );
    inline for (.{ allocationCapture, allocationCopiedCaptures }) |operation| {
        testing.checkAllAllocationFailures(
            testing.allocator,
            operation,
            .{&expression},
        ) catch |err| switch (err) {
            // Optional BitState/OnePass allocation may fail and correctly fall
            // through to already-admitted scratch without surfacing OOM.
            error.SwallowedOutOfMemoryError => {},
            else => return err,
        };
    }
}

test "Exhausted zero-byte DFA budget falls back without retained cache" {
    const result = try Regex.compile(testing.allocator, "(a|aa)*b", .{
        .dfa_memory = .{ .bytes = 0 },
    });
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 5 }, matcher.find("xaaab").?);
    try testing.expect(matcher.fullMatch("aaab"));
    try testing.expect(expression.state.shared.caches.forward() == null);
    try testing.expect(expression.state.shared.caches.reverse() == null);
    try testing.expect(expression.state.shared.caches.full() == null);
}

test "Public compile metrics report immutable structure and exact accounting" {
    const pattern = "(?P<name>a|b)+";
    const result = try Regex.compile(testing.allocator, pattern, .{});
    var expression = result.success;
    defer expression.deinit();

    const metrics = expression.compileMetrics();
    try testing.expectEqual(pattern.len, metrics.pattern_bytes);
    try testing.expect(metrics.program_requested_bytes > 0);
    try testing.expect(metrics.requested_retained_bytes >= metrics.program_requested_bytes);
    try testing.expect(metrics.requested_peak_bytes >= metrics.requested_retained_bytes);
    try testing.expect(metrics.allocation_count > 0);
}

test "Initial and lazy compile artifacts share one finite Regex allowance" {
    const limit = 64 * 1024 * 1024;
    const result = try Regex.compile(testing.allocator, "(a+)(b+)", .{
        .compile_memory = .{ .bytes = limit },
    });
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expect((try matcher.fullCaptures("aaabbb")) != null);
    try testing.expect(matcher.find("xxaaabbb") != null);
    const initial = expression.compileMetrics();
    const lazy = expression.state.tryLazyMetrics().?;
    const reverse = lazy.reverse_program.?;
    const one_pass = lazy.one_pass_plan.?;
    try testing.expect(
        initial.requested_retained_bytes +
            reverse.requested_retained_bytes +
            one_pass.requested_retained_bytes <= limit,
    );
}

test "Cache metrics expose aggregate resources without physical layout" {
    const result = try Regex.compile(testing.allocator, "(a|aa)*b", .{
        .dfa_memory = .{ .bytes = 96 * 1024 },
    });
    var expression = result.success;
    defer expression.deinit();
    const empty = expression.state.shared.caches.tryMetrics().?;
    try testing.expectEqual(@as(usize, 0), empty.total_requested_live_bytes);
    try testing.expectEqual(@as(usize, 0), empty.total_requested_peak_bytes);
    try testing.expect(!empty.any_exhausted);
    try testing.expect(expression.state.tryLazyMetrics().?.reverse_program == null);
    try testing.expect(expression.state.shared.caches.tryLock());
    try testing.expect(expression.state.shared.caches.tryMetrics() == null);
    try testing.expect(expression.state.tryLazyMetrics() == null);
    expression.state.shared.caches.unlock();

    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    try testing.expect(matcher.isMatch("xaaab"));
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 5 }, matcher.find("xaaab").?);
    try testing.expect(matcher.fullMatch("aaab"));

    // An outer shared lock prevents exclusive fallback. Both attempts must
    // therefore complete entirely through already published transitions.
    try testing.expect(expression.state.shared.caches.tryLockShared());
    const known_exists = dfa_search.isMatch(matcher.state, "xaaab", .unanchored);
    const known_full = try dfa_search.fullMatch(matcher.state, "aaab", 0, 4);
    expression.state.shared.caches.unlockShared();
    try testing.expect(known_exists.complete);
    try testing.expect(known_full.complete);

    const metrics = expression.state.shared.caches.tryMetrics().?;
    const physical = expression.state.shared.caches.tryPhysicalMetrics().?;
    try testing.expect(expression.state.tryLazyMetrics().?.reverse_program != null);
    var expected_live: usize = physical.shared_overhead_bytes;
    for ([_]?@TypeOf(physical.forward.?){ physical.forward, physical.reverse, physical.full }) |entry| {
        const cache = entry.?;
        try testing.expect(cache.state_count > 0);
        try testing.expect(cache.hash_buckets > 0);
        try testing.expect(cache.requested_live_bytes > 0);
        try testing.expect(cache.requested_peak_bytes >= cache.requested_live_bytes);
        expected_live += cache.requested_live_bytes;
    }
    try testing.expectEqual(expected_live, metrics.total_requested_live_bytes);
    try testing.expect(metrics.total_requested_peak_bytes >= metrics.total_requested_live_bytes);
    try testing.expect(metrics.total_requested_live_bytes <= 96 * 1024);
}

test "DFA cache partitions prevent operation-order starvation" {
    const limit = 96 * 1024;
    const slot_limit = limit / 3;
    const input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab";
    const result = try Regex.compile(testing.allocator, "[ab]{41}b", .{
        .dfa_memory = .{ .bytes = limit },
    });
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expect(matcher.isMatch(input));
    const after_forward = expression.state.shared.caches.tryPhysicalMetrics().?;
    try testing.expect(after_forward.forward != null);
    try testing.expect(after_forward.forward.?.requested_live_bytes <= slot_limit + 1);
    try testing.expect(after_forward.reverse == null);
    try testing.expect(after_forward.full == null);

    try testing.expectEqual(
        match_types.Match{ .start = 0, .end = 42 },
        matcher.find(input).?,
    );
    try testing.expect(matcher.fullMatch(input));
    const all = expression.state.shared.caches.tryPhysicalMetrics().?;
    for ([_]?@TypeOf(all.forward.?){ all.forward, all.reverse, all.full }) |entry| {
        const cache = entry.?;
        try testing.expect(cache.requested_live_bytes <= slot_limit + 1);
    }
    const metrics = expression.state.shared.caches.tryMetrics().?;
    try testing.expect(metrics.total_requested_live_bytes <= limit);
    try testing.expect(!metrics.any_exhausted);
}

test "Ranged boolean DFA does not perform reverse range recovery" {
    const result = try Regex.compile(testing.allocator, "[ab](a|aa)", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expect(try matcher.isMatchIn(
        "xaa!",
        .{ .start = 1, .end = 3 },
        .unanchored,
    ));
    try testing.expect(expression.state.shared.caches.forward() != null);
    try testing.expect(expression.state.shared.caches.reverse() == null);
    const metrics = matcher_module.debugMetrics(&matcher);
    try testing.expectEqual(@as(usize, 1), metrics.dfa_boolean_attempts);
    try testing.expectEqual(@as(usize, 0), metrics.dfa_range_attempts);
}

test "Full match treats DFA exhaustion as fallback, not rejection" {
    const result = try Regex.compile(testing.allocator, "(a|aa)*b", .{
        .dfa_memory = .unlimited,
    });
    var expression = result.success;
    defer expression.deinit();
    expression.state.shared.caches.max_states = 1;
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    const exhausted = try dfa_search.fullMatch(matcher.state, "aaab", 0, 4);
    try testing.expectEqual(dispatch.OptimizerDecline.state_limit, exhausted.decline);
    try testing.expect(expression.state.shared.caches.full() == null);
    try testing.expect(expression.state.shared.caches.tryLock());
    const busy = dfa_search.isMatch(matcher.state, "aaab", .unanchored);
    expression.state.shared.caches.unlock();
    try testing.expectEqual(dispatch.OptimizerDecline.cache_busy, busy.decline);

    // Exhaustion falls back completely and drops the unusable cache.
    try testing.expect(matcher.fullMatch("aaab"));
    try testing.expect(expression.state.shared.caches.full() == null);

    // A later policy allowance rebuilds from empty state rather than inheriting
    // permanent exhaustion from the earlier operation.
    expression.state.shared.caches.max_states = 1000;
    try testing.expect(matcher.fullMatch("aaab"));
    try testing.expect(!matcher.fullMatch("aaaa"));
    try testing.expect(expression.state.shared.caches.full() != null);
    try testing.expect(expression.state.shared.caches.full().?.stateCount() > 1);
}

test "Disabled DFA retains no cache and preserves fallback semantics" {
    const result = try Regex.compile(testing.allocator, "(a|aa)*b", .{
        .dfa_memory = .disabled,
    });
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const disabled = try dfa_search.find(matcher.state, "xaaab", 0, 5, .unanchored);
    try testing.expectEqual(dispatch.OptimizerDecline.disabled, disabled.decline);
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 5 }, matcher.find("xaaab").?);
    try testing.expect(matcher.fullMatch("aaab"));
    const captures = (try matcher.captures("xaaab")).?;
    try testing.expectEqual(match_types.Match{ .start = 1, .end = 5 }, captures.group(0).?);
    try testing.expect(expression.state.shared.caches.forward() == null);
    try testing.expect(expression.state.shared.caches.reverse() == null);
    try testing.expect(expression.state.shared.caches.full() == null);
}

test "Negated Unicode repetition with full anchors agrees across DFA and fallback" {
    for ([_][]const u8{
        "^(?:\\p{^Nd}+)$",
        "^(?:\\P{Nd}+)$",
    }) |pattern| {
        var dfa_options = testOptions();
        dfa_options.dfa_memory = .unlimited;
        const dfa_result = try Regex.compile(testing.allocator, pattern, dfa_options);
        var dfa_expression = dfa_result.success;
        defer dfa_expression.deinit();
        var dfa_matcher = try Matcher.init(testing.allocator, &dfa_expression);
        defer dfa_matcher.deinit();

        try testing.expect(dfa_matcher.find("a1") == null);
        try testing.expectEqual(
            match_types.Match{ .start = 0, .end = 3 },
            dfa_matcher.find("abc").?,
        );
        try testing.expect(!dfa_matcher.fullMatch("a1"));
        try testing.expect(dfa_matcher.fullMatch("abc"));
        const forward = dfa_expression.state.shared.caches.forward().?;
        try testing.expect(forward.metrics().transition_slots > 256);
        try testing.expect(forward.metrics().sparse_transition_entries > 0);
        try testing.expect(dfa_expression.state.shared.caches.full() != null);

        var fallback_options = testOptions();
        fallback_options.dfa_memory = .disabled;
        const fallback_result = try Regex.compile(testing.allocator, pattern, fallback_options);
        var fallback_expression = fallback_result.success;
        defer fallback_expression.deinit();
        var fallback_matcher = try Matcher.init(testing.allocator, &fallback_expression);
        defer fallback_matcher.deinit();

        try testing.expect(fallback_matcher.find("a1") == null);
        try testing.expectEqual(
            match_types.Match{ .start = 0, .end = 3 },
            fallback_matcher.find("abc").?,
        );
        try testing.expect(!fallback_matcher.fullMatch("a1"));
        try testing.expect(fallback_matcher.fullMatch("abc"));
        try testing.expect(fallback_expression.state.shared.caches.forward() == null);
        try testing.expect(fallback_expression.state.shared.caches.reverse() == null);
        try testing.expect(fallback_expression.state.shared.caches.full() == null);
    }
}

test "Mandatory absolute end searches directly through reverse DFA" {
    const result = try Regex.compile(testing.allocator, "0[01]{12}$", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expect(matcher.isMatch("10000000000000"));
    try testing.expect(expression.state.shared.caches.forward() == null);
    try testing.expect(expression.state.shared.caches.reverse() != null);
    try testing.expectEqual(
        match_types.Match{ .start = 1, .end = 14 },
        matcher.find("10000000000000").?,
    );
    try testing.expect(expression.state.shared.caches.forward() == null);
    try testing.expect(expression.state.shared.caches.reverse() != null);
    try testing.expect(matcher.find("11111111111111") == null);
    try testing.expect(expression.state.shared.caches.forward() == null);
}

test "Long end-anchored suffixes use the sole legal endpoint" {
    const pattern = "ABCDEFGHIJKLMNOPQRSTUVWXYZ$";
    const result = try Regex.compile(testing.allocator, pattern, testOptions());
    var expression = result.success;
    defer expression.deinit();
    try testing.expect(expression.state.program.anchor_end);
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    var input: [64 * 1024]u8 = @splat('x');
    try testing.expect(!matcher.isMatch(&input));
    try testing.expect(matcher.find(&input) == null);
    // Exact suffix qualification rejects without constructing any automaton.
    try testing.expect(expression.state.shared.caches.forward() == null);
    try testing.expect(expression.state.shared.caches.reverse() == null);

    @memcpy(input[input.len - pattern.len + 1 ..], pattern[0 .. pattern.len - 1]);
    const wanted = match_types.Match{
        .start = input.len - pattern.len + 1,
        .end = input.len,
    };
    try testing.expect(matcher.isMatch(&input));
    try testing.expectEqual(wanted, matcher.find(&input).?);
    try testing.expect(expression.state.shared.caches.forward() == null);
    try testing.expect(expression.state.shared.caches.reverse() != null);

    const interior = matcher.findIn(
        &input,
        .{ .start = 0, .end = input.len - 1 },
        .unanchored,
    );
    try testing.expect((try interior) == null);
    try testing.expect(!try matcher.isMatchIn(
        &input,
        .{ .start = 0, .end = input.len - 1 },
        .unanchored,
    ));
}

test "Mixed end-anchored branches never publish a global endpoint" {
    const result = try Regex.compile(
        testing.allocator,
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ$|x",
        testOptions(),
    );
    var expression = result.success;
    defer expression.deinit();
    try testing.expect(!expression.state.program.anchor_end);
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    try testing.expectEqual(
        match_types.Match{ .start = 1, .end = 2 },
        matcher.find("qxq").?,
    );
}

test "Reverse recipe and shared caches materialize only on demand" {
    const result = try Regex.compile(testing.allocator, "[a-z]+z", testOptions());
    var expression = result.success;
    defer expression.deinit();
    try testing.expect(expression.state.shared.reverse_program == null);
    try testing.expect(expression.state.shared.reverse_state == .recipe);
    try testing.expect(expression.state.tryLazyMetrics().?.reverse_program == null);

    var first = try Matcher.init(testing.allocator, &expression);
    defer first.deinit();
    try testing.expect(first.isMatch("xxxxz"));
    try testing.expect(expression.state.shared.caches.forward() != null);
    try testing.expect(expression.state.shared.caches.reverse() == null);
    try testing.expectEqual(
        match_types.Match{ .start = 0, .end = 5 },
        (try first.findIn("xxxxz", .{}, .start)).?,
    );
    try testing.expect(expression.state.shared.caches.reverse() == null);
    const state_count = expression.state.shared.caches.forward().?.stateCount();

    var second = try Matcher.init(testing.allocator, &expression);
    defer second.deinit();
    try testing.expect(second.isMatch("xxxxz"));
    try testing.expectEqual(state_count, expression.state.shared.caches.forward().?.stateCount());
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 5 }, second.find("xxxxz").?);
    try testing.expect(expression.state.shared.reverse_program != null);
    try testing.expect(expression.state.shared.reverse_state == .compiled);
    try testing.expect(expression.state.shared.caches.reverse() != null);
    const lazy = expression.state.tryLazyMetrics().?.reverse_program.?;
    try testing.expectEqual(
        expression.state.shared.reverse_program.?.requestedBytes(),
        lazy.program_requested_bytes,
    );
    try testing.expectEqual(lazy.program_requested_bytes, lazy.requested_retained_bytes);
    try testing.expect(lazy.requested_peak_bytes >= lazy.requested_retained_bytes);
    try testing.expect(lazy.allocation_count > 0);
}

test "Named capture lookup survives lazy reverse compilation" {
    const result = try Regex.compile(testing.allocator, "(?P<word>[a-z]+)-(?<digits>[0-9]+)", testOptions());
    var expression = result.success;
    defer expression.deinit();
    try testing.expectEqual(@as(u32, 2), expression.captureCount());
    try testing.expectEqual(@as(?u32, 1), expression.captureIndex("word"));
    try testing.expectEqual(@as(?u32, 2), expression.captureIndex("digits"));
    try testing.expect(expression.captureIndex("missing") == null);

    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const view = (try matcher.captures("abc-42")).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 3 }, expression.namedCapture(view, "word").?);
    try testing.expectEqual(match_types.Match{ .start = 4, .end = 6 }, expression.namedCapture(view, "digits").?);
    var captures = (try matcher.copyCaptures(testing.allocator, "abc-42")).?;
    defer captures.deinit();
    try testing.expectEqual(
        match_types.Match{ .start = 0, .end = 3 },
        expression.namedCapture(captures.view(), "word").?,
    );
    try testing.expect(expression.namedCapture(captures.view(), "missing") == null);
    _ = matcher.find("abc-42");
    try testing.expect(expression.state.shared.reverse_state == .compiled);
    try testing.expectEqual(@as(?u32, 1), expression.captureIndex("word"));
}

test "Capture name remains valid after Regex relocation" {
    const result = try Regex.compile(testing.allocator, "(?P<word>[a-z]+)", testOptions());
    const original = result.success;
    const name = original.captureName(1).?;
    var moved = original;
    defer moved.deinit();
    try testing.expectEqualStrings("word", name);
    try testing.expectEqualStrings("word", moved.captureName(1).?);
}

test "Duplicate capture names resolve to the leftmost group" {
    const result = try Regex.compile(testing.allocator, "(?P<x>a(?P<x>b))", testOptions());
    var expression = result.success;
    defer expression.deinit();
    try testing.expectEqual(@as(?u32, 1), expression.captureIndex("x"));
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const captured = (try matcher.captures("ab")).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 2 }, expression.namedCapture(captured, "x").?);
}

test "Stable State survives Regex relocation" {
    const result = try Regex.compile(testing.allocator, "(ab|a)+c", testOptions());
    var original = result.success;
    var matcher = try Matcher.init(testing.allocator, &original);
    var moved = original;
    original = undefined;
    defer {
        matcher.deinit();
        moved.deinit();
    }

    try testing.expectEqual(match_types.Match{ .start = 2, .end = 7 }, matcher.find("xxababc").?);
}

test "Forward and reverse DFA preserve first-match ranges" {
    for ([_]struct { pattern: []const u8, input: []const u8, expected: match_types.Match }{
        .{ .pattern = "[a]|[a][a]", .input = "xaa", .expected = .{ .start = 1, .end = 2 } },
        .{ .pattern = "[a]+", .input = "xxaa", .expected = .{ .start = 2, .end = 4 } },
        .{ .pattern = "[a]+?", .input = "xxaa", .expected = .{ .start = 2, .end = 3 } },
        .{ .pattern = "[a]|b[a]", .input = "ba", .expected = .{ .start = 0, .end = 2 } },
        .{ .pattern = "^[a]", .input = "a", .expected = .{ .start = 0, .end = 1 } },
        .{ .pattern = "[a]$", .input = "ba", .expected = .{ .start = 1, .end = 2 } },
        .{ .pattern = "^.*|\\w\\s{0,3}", .input = "aaab_\nxx", .expected = .{ .start = 0, .end = 5 } },
    }) |case| {
        const result = try Regex.compile(testing.allocator, case.pattern, testOptions());
        var expression = result.success;
        defer expression.deinit();
        var matcher = try Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();
        try testing.expectEqual(case.expected, matcher.find(case.input).?);
    }
}

test "Copied captures remain valid after matcher and regex teardown" {
    const result = try Regex.compile(testing.allocator, "(a+)(b+)", testOptions());
    var expression = result.success;
    var matcher = try Matcher.init(testing.allocator, &expression);
    var captures = (try matcher.copyCaptures(testing.allocator, "aaabbb")).?;
    defer captures.deinit();
    matcher.deinit();
    expression.deinit();
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 3 }, captures.group(1).?);
    try testing.expectEqual(match_types.Match{ .start = 3, .end = 6 }, captures.group(2).?);
}

test "Independent matchers share one regex concurrently" {
    const result = try Regex.compile(std.heap.page_allocator, "([a-z]+)-([0-9]+)$", testOptions());
    var expression = result.success;
    defer expression.deinit();

    const Context = struct {
        regex: *const Regex,
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(context_value: *@This()) void {
            var matcher = Matcher.init(std.heap.page_allocator, context_value.regex) catch {
                context_value.failed.store(true, .release);
                return;
            };
            defer matcher.deinit();
            for (0..200) |_| {
                if (!matcher.isMatch("word-123") or
                    !std.meta.eql(matcher.find("word-123"), match_types.Match{ .start = 0, .end = 8 }))
                {
                    context_value.failed.store(true, .release);
                    return;
                }
                const captured = matcher.captures("word-123") catch {
                    context_value.failed.store(true, .release);
                    return;
                };
                if (captured == null or
                    !std.meta.eql(captured.?.group(2), match_types.Match{ .start = 5, .end = 8 }))
                {
                    context_value.failed.store(true, .release);
                    return;
                }
                const full = matcher.fullCaptures("word-123") catch {
                    context_value.failed.store(true, .release);
                    return;
                };
                if (full == null or
                    !std.meta.eql(full.?.group(1), match_types.Match{ .start = 0, .end = 4 }))
                {
                    context_value.failed.store(true, .release);
                    return;
                }
            }
        }
    };

    var context_value = Context{ .regex = &expression };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Context.run, .{&context_value});
    for (threads) |thread| thread.join();
    try testing.expect(!context_value.failed.load(.acquire));
    const lazy = expression.state.tryLazyMetrics().?;
    try testing.expect(lazy.one_pass_plan != null);
    try testing.expect(lazy.one_pass_plan.?.state_count > 0);
}

test "Denied OnePass budget falls through to preadmitted BitState" {
    const result = try Regex.compile(testing.allocator, "(a+)(b)", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.initWithOptions(testing.allocator, &expression, .{
        .scratch_memory = .unlimited,
    });
    defer matcher.deinit();

    const warmed = (try matcher.captures("aaab")).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 4 }, warmed.group(0).?);
    try testing.expect(matcher.capture_scratch.bit_state_engine != null);
    try testing.expect(matcher.capture_scratch.one_pass_engine == null);
    matcher.budget.limit = matcher.budget.live;

    const captured = (try matcher.fullCaptures("aaab")).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 4 }, captured.group(0).?);
    try testing.expect(matcher.capture_scratch.one_pass_engine == null);
    try testing.expect(matcher.capture_scratch.bit_state_engine != null);
}

test "Whole-capture alias keeps common storage inline and grows rare overflow" {
    const result = try Regex.compile(testing.allocator, "((((a))))", .{
        .match_kind = .longest,
    });
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    const captured = (try matcher.captures("a")).?;
    for (0..5) |group|
        try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, captured.group(group).?);
    try testing.expectEqual(@as(usize, 1), matcher_module.debugMetrics(&matcher).capture_alias_completions);
    try testing.expectEqual(
        @as(usize, expression.state.program.capture_slots),
        matcher.capture_scratch.overflow_whole_result.len,
    );
    try testing.expect(matcher.capture_scratch.one_pass_engine == null);
    try testing.expect(matcher.capture_scratch.bit_state_engine == null);
    try testing.expect(matcher.capture_scratch.capture_engine == null);
}

test "Long capture dispatch narrows ranges and reuses bounded engines" {
    const prefix_len = 1 << 16;
    const late = try testing.allocator.alloc(u8, prefix_len + 4);
    defer testing.allocator.free(late);
    @memset(late[0..prefix_len], 'q');
    @memcpy(late[prefix_len..], "aaab");

    const ambiguous_result = try Regex.compile(testing.allocator, "(([ab]|[ab][ab])*)b", testOptions());
    var ambiguous = ambiguous_result.success;
    defer ambiguous.deinit();
    var ambiguous_matcher = try Matcher.init(testing.allocator, &ambiguous);
    defer ambiguous_matcher.deinit();
    const captured = (try ambiguous_matcher.captures(late)).?;
    try testing.expectEqual(
        match_types.Match{ .start = prefix_len, .end = prefix_len + 4 },
        captured.group(0).?,
    );
    try testing.expect(ambiguous.state.shared.caches.forward() != null);
    try testing.expect(ambiguous.state.shared.caches.reverse() != null);
    try testing.expect(ambiguous_matcher.capture_scratch.bit_state_engine != null);
    try testing.expect(ambiguous_matcher.capture_scratch.capture_engine == null);
    const bitmap_capacity = ambiguous_matcher.capture_scratch.bit_state_engine.?.bitmap.capacity;
    _ = try ambiguous_matcher.captures(late);
    try testing.expectEqual(bitmap_capacity, ambiguous_matcher.capture_scratch.bit_state_engine.?.bitmap.capacity);
    const ambiguous_dispatch = matcher_module.debugMetrics(&ambiguous_matcher);
    try testing.expectEqual(@as(usize, 2), ambiguous_dispatch.capture_direct_bit_state_attempts);
    try testing.expectEqual(@as(usize, 0), ambiguous_dispatch.capture_direct_bit_state_completions);
    try testing.expectEqual(@as(usize, 2), ambiguous_dispatch.capture_exact_bit_state_completions);
    try testing.expectEqual(@as(usize, 0), ambiguous_dispatch.capture_nfa_attempts);

    const deterministic_result = try Regex.compile(testing.allocator, "([ac]+)(b)", testOptions());
    var deterministic = deterministic_result.success;
    defer deterministic.deinit();
    var deterministic_matcher = try Matcher.init(testing.allocator, &deterministic);
    defer deterministic_matcher.deinit();
    try testing.expect(deterministic.state.tryLazyMetrics().?.one_pass_plan == null);
    const one_pass_captures = (try deterministic_matcher.captures(late)).?;
    try testing.expectEqual(
        match_types.Match{ .start = prefix_len, .end = prefix_len + 4 },
        one_pass_captures.group(0).?,
    );
    try testing.expect(deterministic.state.shared.caches.forward() != null);
    try testing.expect(deterministic.state.shared.caches.reverse() != null);
    try testing.expect(deterministic_matcher.capture_scratch.one_pass_engine != null);
    try testing.expect(deterministic_matcher.capture_scratch.bit_state_engine == null);
    const plan_metrics = deterministic.state.tryLazyMetrics().?.one_pass_plan.?;
    try testing.expect(plan_metrics.state_count > 0);
    try testing.expect(plan_metrics.requested_retained_bytes > 0);
    try testing.expect(plan_metrics.requested_peak_bytes >= plan_metrics.requested_retained_bytes);
    try testing.expect(deterministic_matcher.capture_scratch.capture_engine == null);
    const deterministic_dispatch = matcher_module.debugMetrics(&deterministic_matcher);
    try testing.expectEqual(@as(usize, 1), deterministic_dispatch.capture_one_pass_attempts);
    try testing.expectEqual(@as(usize, 1), deterministic_dispatch.capture_one_pass_completions);
    try testing.expectEqual(@as(usize, 0), deterministic_dispatch.capture_nfa_attempts);
}

test "Long assertion-free capture replay uses bounded exact BitState" {
    const input_len = (1 << 16) + 1;
    const input = try testing.allocator.alloc(u8, input_len);
    defer testing.allocator.free(input);
    @memset(input[0 .. input.len - 1], 'q');
    input[input.len - 1] = 'z';

    const result = try Regex.compile(
        testing.allocator,
        "((q|qq|qqq|qqqq|qqqqq|qqqqqq|qqqqqqq|qqqqqqqq)*)z",
        .{ .dfa_memory = .disabled },
    );
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const captured = (try matcher.captures(input)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = input.len }, captured.group(0).?);
    try testing.expect(expression.state.shared.caches.forward() == null);
    try testing.expect(matcher.capture_scratch.capture_engine == null);
    try testing.expectEqual(false, expression.state.program.uses_empty_width);
    const replay_dispatch = matcher_module.debugMetrics(&matcher);
    try testing.expect(replay_dispatch.capture_exact_bit_state_required_bytes_max > 0);
    try testing.expect(replay_dispatch.capture_exact_bit_state_required_bytes_max <= 256 * 1024);
    try testing.expectEqual(@as(usize, 1), replay_dispatch.capture_exact_bit_state_attempts);
    try testing.expectEqual(@as(usize, 1), replay_dispatch.capture_exact_bit_state_completions);
    try testing.expectEqual(@as(usize, 0), replay_dispatch.capture_nfa_attempts);
}

test "Full captures choose a path that reaches the required end" {
    const result = try Regex.compile(testing.allocator, "(fo|foo)", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    const captured = (try matcher.fullCaptures("foo")).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 3 }, captured.group(0).?);
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 3 }, captured.group(1).?);
    try testing.expect((try matcher.fullCaptures("food")) == null);
}

test "Conservative work admission rejects before execution and preserves reuse" {
    const result = try Regex.compile(testing.allocator, "(a|aa)*b", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.isMatchWithWorkLimit("aaaaaaaaab", 0),
    );
    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.findWithWorkLimit("aaaaaaaaab", 1),
    );
    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.countWithWorkLimit("aaaaaaaaab", 1),
    );
    const count_input = "aaaaaaaaab";
    const suffix_positions = (count_input.len + 1) * (count_input.len + 2) / 2;
    const count_work = suffix_positions *
        (expression.state.program.priority_lists.items.len + 1);
    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.countWithWorkLimit(count_input, count_work - 1),
    );
    try testing.expectEqual(
        @as(usize, 1),
        try matcher.countWithWorkLimit(count_input, count_work),
    );
    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.capturesWithWorkLimit("aaaaaaaaab", 1),
    );
    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.fullCapturesWithWorkLimit("aaaaaaaaab", 1),
    );
    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.fullCapturesInWithWorkLimit(
            "xaaaaaaaaab",
            .{ .start = 1 },
            1,
        ),
    );
    try testing.expect(try matcher.isMatchWithWorkLimit(
        "aaaaaaaaab",
        std.math.maxInt(usize),
    ));
    try testing.expect(matcher.isMatch("aaaaaaaaab"));
    try testing.expectError(
        error.WorkLimitExceeded,
        matcher.isMatchInWithWorkLimit(
            "xaaaaaaaaab",
            .{ .start = 1 },
            .unanchored,
            0,
        ),
    );
    try testing.expect((try matcher.findInWithWorkLimit(
        "xaaaaaaaaab",
        .{ .start = 1 },
        .unanchored,
        std.math.maxInt(usize),
    )) != null);
    try testing.expectError(
        error.InvalidRange,
        matcher.fullMatchInWithWorkLimit("a", .{ .start = 2 }, 100),
    );
}

test "Match collections enforce limits and release allocations" {
    const result = try Regex.compile(testing.allocator, "a", testOptions());
    var expression = result.success;
    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var matcher = try Matcher.init(counting.allocator(), &expression);
    const allocation_high_water = counting.alloc_index;
    var iterator = matcher.iterator("ababa");
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, iterator.next().?);
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 3 }, iterator.next().?);
    try testing.expectEqual(match_types.Match{ .start = 4, .end = 5 }, iterator.next().?);
    try testing.expect(iterator.next() == null);
    try testing.expectEqual(allocation_high_water, counting.alloc_index);
    try testing.expectError(
        error.ResultLimitExceeded,
        matcher.findAll(testing.allocator, "ababa", 2),
    );
    var matches = try matcher.findAll(testing.allocator, "ababa", 3);
    matcher.deinit();
    expression.deinit();
    defer matches.deinit();
    try testing.expectEqual(@as(usize, 3), matches.values().len);
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, matches.values()[0]);
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 3 }, matches.values()[1]);
    try testing.expectEqual(match_types.Match{ .start = 4, .end = 5 }, matches.values()[2]);

    const allocation_result = try Regex.compile(testing.allocator, "a", testOptions());
    var allocation_expression = allocation_result.success;
    defer allocation_expression.deinit();
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationMatches,
        .{&allocation_expression},
    );
}

test "Count handles closed literal alternatives through general iteration" {
    const compiled = try Regex.compile(testing.allocator, "hello|world|test", testOptions());
    var expression = compiled.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    try testing.expectEqual(@as(usize, 3), matcher.count("hello x testworld"));
}

test "Specialized count agrees with range iteration" {
    const patterns = [_][]const u8{
        "[0-9]+",
        "[A-Za-z]+",
        "[0-9]{1,3}",
        "foo[0-9]+",
        "hello|world|test",
        "[A-Za-z_][A-Za-z0-9_]{3,}",
        "\\b(?:TODO|FIXME|XXX)\\b",
        "\\b[0-9]{1,2}:[0-9]{2}\\b",
        "\\b[0-9a-f]{2}(?:-[0-9a-f]{2}){2}\\b",
        "\\b(?:Error|Deadline|status=[45][0-9]{2})\\b",
        "(?m)^[0-9A-F]+;[^;]+;Lu;",
        ".+",
    };
    var state: u64 = 0xd1b54a32d192ed03;
    var input_buffer: [96]u8 = undefined;
    const alphabet = "afheltoswrd019:_-;ELuTFIXMO \n\xff\xc3\x80";
    for (patterns) |pattern| {
        const compiled = try Regex.compile(testing.allocator, pattern, testOptions());
        var expression = compiled.success;
        defer expression.deinit();
        var matcher = try Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();
        for (0..200) |_| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            const len: usize = @intCast(state % (input_buffer.len + 1));
            for (input_buffer[0..len]) |*byte| {
                state = state *% 6364136223846793005 +% 1442695040888963407;
                byte.* = alphabet[state % alphabet.len];
            }
            const input = input_buffer[0..len];
            var iterator = matcher.iterator(input);
            var expected: usize = 0;
            while (iterator.next() != null) expected += 1;
            try testing.expectEqual(expected, matcher.count(input));
        }
    }
}

test "Specialized existence agrees with range search" {
    const patterns = [_][]const u8{
        "[0-9]+",
        "[A-Za-z]+",
        "[0-9]{1,3}",
        "foo[0-9]+",
        "hello|world|test",
        "[A-Za-z_][A-Za-z0-9_]{3,}",
        "\\b(?:TODO|FIXME|XXX)\\b",
        "\\b[0-9]{1,2}:[0-9]{2}\\b",
        "(?m)^[0-9A-F]+;[^;]+;Lu;",
    };
    var state: u64 = 0xa0761d6478bd642f;
    var input_buffer: [128]u8 = undefined;
    const alphabet = "afheltoswrd019:_-;ELuTFIXMO \n";
    for (patterns) |pattern| {
        const compiled = try Regex.compile(testing.allocator, pattern, testOptions());
        var expression = compiled.success;
        defer expression.deinit();
        var matcher = try Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();
        for (0..200) |_| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            const len: usize = @intCast(state % (input_buffer.len + 1));
            for (input_buffer[0..len]) |*byte| {
                state = state *% 6364136223846793005 +% 1442695040888963407;
                byte.* = alphabet[state % alphabet.len];
            }
            const input = input_buffer[0..len];
            try testing.expectEqual(matcher.find(input) != null, matcher.isMatch(input));
        }
    }

    const compiled = try Regex.compile(testing.allocator, "[A-Za-z]+", testOptions());
    var expression = compiled.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    var dense: [64 * 1024]u8 = @splat('a');
    try testing.expect(matcher.isMatch(&dense));
    try testing.expectEqual(@as(usize, 1), matcher.count(&dense));
}

test "Count specializes greedy repeated ASCII byte classes" {
    for ([_]struct { pattern: []const u8, input: []const u8, expected: usize }{
        .{ .pattern = "[0-9]+", .input = "12 ab 345", .expected = 2 },
        .{ .pattern = "[A-Za-z]+", .input = "ab 12 CDE", .expected = 2 },
        .{ .pattern = "[0-9]{1,3}", .input = "12345 6", .expected = 3 },
        .{ .pattern = "([a-z]+)", .input = "abc 12 de", .expected = 2 },
        .{ .pattern = "foo[0-9]+", .input = "foo12 x foo345", .expected = 2 },
    }) |case| {
        const compiled = try Regex.compile(testing.allocator, case.pattern, testOptions());
        var expression = compiled.success;
        defer expression.deinit();
        var matcher = try Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();
        try testing.expect(expression.state.program.plans.repeat_byte_range_count != 0);
        try testing.expectEqual(case.expected, matcher.count(case.input));
        var iterator = matcher.iterator(case.input);
        var reference: usize = 0;
        while (iterator.next() != null) reference += 1;
        try testing.expectEqual(reference, matcher.count(case.input));
    }
}

test "Count preserves UTF-8 dot semantics on malformed input" {
    const compiled = try Regex.compile(testing.allocator, ".+", testOptions());
    var expression = compiled.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();
    for ([_][]const u8{
        &.{0xff},
        &.{ 0xff, 0xff },
        &.{ 'a', 0xff, 'b' },
        &.{ 0xff, '\n', 'a' },
        &.{ 0xc3, 0xa9 },
    }) |input| {
        var ranges = matcher.iterator(input);
        var expected: usize = 0;
        while (ranges.next() != null) expected += 1;
        try testing.expectEqual(expected, matcher.count(input));
    }
}

test "Specialized capture plans preserve groups and greedy priority" {
    const cases = [_]struct {
        pattern: []const u8,
        input: []const u8,
        groups: []const match_types.Match,
    }{
        .{
            .pattern = "(?:(a+)|(b+))",
            .input = "!!aaa",
            .groups = &.{
                .{ .start = 2, .end = 5 },
                .{ .start = 2, .end = 5 },
            },
        },
        .{
            .pattern = "(?m)^([0-9A-F]+);([^;]+);([A-Za-z]+);",
            .input = "0041;LATIN A;Lu;\n",
            .groups = &.{
                .{ .start = 0, .end = 16 },
                .{ .start = 0, .end = 4 },
                .{ .start = 5, .end = 12 },
                .{ .start = 13, .end = 15 },
            },
        },
        .{
            .pattern = "(?m)^([0-9]{2}) ([A-Z]):.*\\(([a-f]{2})\\):",
            .input = "12 E: (bb): x(aa): tail\n",
            .groups = &.{
                .{ .start = 0, .end = 18 },
                .{ .start = 0, .end = 2 },
                .{ .start = 3, .end = 4 },
                .{ .start = 14, .end = 16 },
            },
        },
    };
    for (cases) |case| {
        const compiled = try Regex.compile(testing.allocator, case.pattern, testOptions());
        var expression = compiled.success;
        defer expression.deinit();
        var matcher = try Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();
        var captures = matcher.captureIterator(case.input);
        const view = (try captures.next()).?;
        for (case.groups, 0..) |expected, group|
            try testing.expectEqual(expected, view.group(group).?);
        try testing.expect((try captures.next()) == null);
    }
}

test "Iterator makes scalar-aware progress and suppresses adjacent empty matches" {
    const result = try Regex.compile(testing.allocator, "", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    var iterator = matcher.iterator("é\xff");
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 0 }, iterator.next().?);
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 2 }, iterator.next().?);
    try testing.expectEqual(match_types.Match{ .start = 3, .end = 3 }, iterator.next().?);
    try testing.expect(iterator.next() == null);

    const repeated_result = try Regex.compile(testing.allocator, "a*", testOptions());
    var repeated = repeated_result.success;
    defer repeated.deinit();
    var repeated_matcher = try Matcher.init(testing.allocator, &repeated);
    defer repeated_matcher.deinit();
    var repeated_iterator = repeated_matcher.iterator("aa");
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 2 }, repeated_iterator.next().?);
    try testing.expect(repeated_iterator.next() == null);
}

test "Capture iterator returns non-overlapping named groups" {
    const result = try Regex.compile(testing.allocator, "(?P<word>[a-z]+)", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    const input = "ab cd";
    var iterator = matcher.captureIterator(input);
    const first = (try iterator.next()).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 2 }, first.group(0).?);
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 2 }, expression.namedCapture(first, "word").?);
    const second = (try iterator.next()).?;
    try testing.expectEqual(match_types.Match{ .start = 3, .end = 5 }, second.group(0).?);
    try testing.expectEqual(match_types.Match{ .start = 3, .end = 5 }, expression.namedCapture(second, "word").?);
    try testing.expect((try iterator.next()) == null);
    try testing.expect((try iterator.next()) == null);
}

test "Capture iterator makes scalar-aware empty progress" {
    const result = try Regex.compile(testing.allocator, "()", testOptions());
    var expression = result.success;
    defer expression.deinit();
    var matcher = try Matcher.init(testing.allocator, &expression);
    defer matcher.deinit();

    var iterator = matcher.captureIterator("é\xff");
    for ([_]usize{ 0, 2, 3 }) |offset| {
        const captured = (try iterator.next()).?;
        try testing.expectEqual(match_types.Match{ .start = offset, .end = offset }, captured.group(0).?);
        try testing.expectEqual(match_types.Match{ .start = offset, .end = offset }, captured.group(1).?);
    }
    try testing.expect((try iterator.next()) == null);
}

test "Minimal orchestration exposes range full and captures" {
    const result = try Regex.compile(testing.allocator, "(a+)(b)?", testOptions());
    var regex = result.success;
    defer regex.deinit();
    var matcher = try Matcher.init(testing.allocator, &regex);
    defer matcher.deinit();

    try testing.expect(matcher.isMatch("xxaa"));
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 4 }, matcher.find("xxaa").?);
    try testing.expect(!matcher.fullMatch("xxaa"));
    const view = (try matcher.captures("xxaa")).?;
    try testing.expectEqual(match_types.Match{ .start = 2, .end = 4 }, view.group(1).?);
    try testing.expect(view.group(2) == null);

    const anchored_result = try Regex.compile(testing.allocator, "^a|(?m:^a)", testOptions());
    var anchored = anchored_result.success;
    defer anchored.deinit();
    var anchored_matcher = try Matcher.init(testing.allocator, &anchored);
    defer anchored_matcher.deinit();
    try testing.expect((try anchored_matcher.findIn(
        "ba",
        .{ .start = 1, .end = 2 },
        .unanchored,
    )) == null);
    try testing.expectEqual(
        match_types.Match{ .start = 2, .end = 3 },
        (try anchored_matcher.findIn(
            "x\na",
            .{ .start = 2, .end = 3 },
            .unanchored,
        )).?,
    );
}
