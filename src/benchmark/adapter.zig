//! ReleaseFast benchmark materialization, qualification, timing, and metrics.
//!
//! The adapter is a line-oriented subprocess protocol used by `benchmark.py`.
//! `--list` emits operation/name/exact-pattern rows for the full catalog;
//! `--run index iterations` materializes exactly one workload and prints one
//! machine-readable measurement.
//!
//! Materialization expands compact pattern/input generators outside timing. Each
//! task builds the required public owners, computes the expected observation once,
//! performs an untimed warm-up batch, times an equal operation batch, and verifies
//! an observation digest afterward. Compile tasks intentionally construct and
//! destroy inside each iteration; matching tasks reuse warmed Regex/Matcher state.
//!
//! Private `internal.zig` access supplies route and requested-resource snapshots
//! without making engine selection public. Route, checksum, and exact expected
//! result disagreement abort the sample. Process isolation, calibration, median,
//! MAD, memory ceilings, and `benchmark.log` formatting remain in Python.

const std = @import("std");
const regex = @import("regex_internal");
const workload_data = @import("workloads.zig");
const campaign = @import("campaign.zig");

const Workload = workload_data.Workload;
const Route = workload_data.RouteSummary;

/// Materialized byte view with optional ownership. Authored literals borrow
/// static source bytes; generated forms record the allocator used for teardown.
const Bytes = struct {
    allocator: ?std.mem.Allocator = null,
    value: []const u8,

    fn deinit(self: *Bytes) void {
        if (self.allocator) |allocator| allocator.free(@constCast(self.value));
        self.* = undefined;
    }
};

fn mix(hash: u64, value: u64) u64 {
    return hash ^ (value +% 0x9e3779b97f4a7c15 +% (hash << 6) +% (hash >> 2));
}

fn hashSpan(hash: *u64, value: anytype) void {
    hash.* = mix(hash.*, value.start + 1);
    hash.* = mix(hash.*, value.end + 1);
}

fn writeHex(writer: anytype, bytes: []const u8) !void {
    const digits = "0123456789abcdef";
    var encoded: [2]u8 = undefined;
    for (bytes) |byte| {
        encoded[0] = digits[byte >> 4];
        encoded[1] = digits[byte & 0x0f];
        try writer.writeAll(&encoded);
    }
}

fn writePatternItem(writer: anytype, pattern: []const u8, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writeHex(writer, pattern);
}

/// Materializes one fixed-width numbered token into caller storage, rejecting an
/// index or composite source that cannot fit instead of truncating catalog data.
fn numberedWord(
    buffer: []u8,
    prefix: []const u8,
    index: usize,
    width: usize,
    suffix: []const u8,
) ![]const u8 {
    var digits_buffer: [32]u8 = undefined;
    const digits = try std.fmt.bufPrint(&digits_buffer, "{d}", .{index});
    if (digits.len > width or prefix.len + width + suffix.len > buffer.len)
        return error.InvalidNumberedSource;
    @memcpy(buffer[0..prefix.len], prefix);
    @memset(buffer[prefix.len .. prefix.len + width - digits.len], '0');
    @memcpy(buffer[prefix.len + width - digits.len .. prefix.len + width], digits);
    @memcpy(buffer[prefix.len + width .. prefix.len + width + suffix.len], suffix);
    return buffer[0 .. prefix.len + width + suffix.len];
}

/// Writes the exact materialized regex, or every insertion-order regex for a
/// collection workload, in a whitespace-safe catalog encoding.
fn writePatterns(
    writer: anytype,
    workload: Workload,
    materialized_pattern: []const u8,
) !void {
    const source = switch (workload.task) {
        .set => |task| task.patterns,
        .filtered => |task| task.patterns,
        else => {
            try writer.writeAll("s:");
            return writeHex(writer, materialized_pattern);
        },
    };
    try writer.writeAll("l:");
    var first = true;
    switch (source) {
        .list => |patterns| for (patterns) |pattern|
            try writePatternItem(writer, pattern, &first),
        .numbered => |value| for (0..value.count) |index| {
            var buffer: [128]u8 = undefined;
            const pattern = try numberedWord(
                &buffer,
                value.prefix,
                index,
                value.width,
                value.suffix,
            );
            try writePatternItem(writer, pattern, &first);
        },
    }
}

const dictionary_prefixes = [_][]const u8{
    "amber", "ambition", "amble", "azure", "binary", "birch", "catalog", "cater",
};
const dictionary_tails = [_][]const u8{ "", "ing", "ment", "stone" };

/// Emits the deterministic heterogeneous dictionary used by compile/find scale
/// series. Grouping shares some prefixes while varying local suffix topology.
fn appendMixedDictionary(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    count: usize,
) !void {
    const group_size = (count + dictionary_prefixes.len - 1) / dictionary_prefixes.len;
    for (0..count) |index| {
        if (index != 0) try output.append(allocator, '|');
        const group = @min(index / group_size, dictionary_prefixes.len - 1);
        const local = index % group_size;
        var buffer: [48]u8 = undefined;
        const word = try std.fmt.bufPrint(&buffer, "{s}{d:0>4}{s}", .{
            dictionary_prefixes[group],
            local,
            dictionary_tails[local % dictionary_tails.len],
        });
        try output.appendSlice(allocator, word);
    }
}

/// Expands a declarative pattern source outside the timed region. Literal forms
/// borrow static bytes; every generated form returns one `Bytes` owner only after
/// checked sizing and transactional list construction succeed.
fn materializePattern(allocator: std.mem.Allocator, source: workload_data.PatternSource) !Bytes {
    return switch (source) {
        .literal => |value| .{ .value = value },
        .generated => |generated| switch (generated) {
            .ambiguous_suffix => .{ .value = "(a|aa)*b" },
            .nullable_suffix => .{ .value = "(a*)*b" },
            .bounded_optional => |repetitions| blk: {
                const bytes = try std.fmt.allocPrint(
                    allocator,
                    "(?:a?){{{d}}}a{{{d}}}",
                    .{ repetitions, repetitions },
                );
                break :blk .{ .allocator = allocator, .value = bytes };
            },
            .shared_alternation => |value| blk: {
                var output: std.ArrayList(u8) = .empty;
                errdefer output.deinit(allocator);
                try output.appendSlice(allocator, "(?:");
                for (0..value.count) |index| {
                    if (index != 0) try output.append(allocator, '|');
                    var buffer: [64]u8 = undefined;
                    const word = try numberedWord(&buffer, "word", index, value.width, "");
                    try output.appendSlice(allocator, word);
                }
                try output.append(allocator, ')');
                break :blk .{ .allocator = allocator, .value = try output.toOwnedSlice(allocator) };
            },
            .mixed_dictionary => |count| blk: {
                var output: std.ArrayList(u8) = .empty;
                errdefer output.deinit(allocator);
                try output.appendSlice(allocator, "(?:");
                try appendMixedDictionary(allocator, &output, count);
                try output.append(allocator, ')');
                break :blk .{ .allocator = allocator, .value = try output.toOwnedSlice(allocator) };
            },
            .deep_groups => |depth| blk: {
                const bytes = try allocator.alloc(u8, depth * 4 + 1);
                for (0..depth) |index| @memcpy(bytes[index * 3 ..][0..3], "(?:");
                bytes[depth * 3] = 'a';
                @memset(bytes[depth * 3 + 1 ..], ')');
                break :blk .{ .allocator = allocator, .value = bytes };
            },
            .many_captures => |count| blk: {
                const bytes = try allocator.alloc(u8, count * 3);
                for (0..count) |index| @memcpy(bytes[index * 3 ..][0..3], "(a)");
                break :blk .{ .allocator = allocator, .value = bytes };
            },
        },
    };
}

/// Small deterministic generator used only to materialize stable identifier input.
const SplitMix64 = struct {
    state: u64,
    fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }
};

/// Expands a deterministic input source outside qualification/timing batches.
/// Literal forms borrow their source; generated forms check composite lengths,
/// fill exactly one allocation, and publish its allocator through `Bytes`.
fn materializeInput(allocator: std.mem.Allocator, source: workload_data.InputSource) !Bytes {
    return switch (source) {
        .literal => |value| .{ .value = value },
        .fill => |value| blk: {
            const bytes = try allocator.alloc(u8, value.count);
            @memset(bytes, value.byte);
            break :blk .{ .allocator = allocator, .value = bytes };
        },
        .fill_suffix => |value| blk: {
            if (value.suffix.len > value.count) return error.InvalidInputSource;
            const bytes = try allocator.alloc(u8, value.count);
            @memset(bytes, value.byte);
            @memcpy(bytes[value.count - value.suffix.len ..], value.suffix);
            break :blk .{ .allocator = allocator, .value = bytes };
        },
        .repeat => |value| blk: {
            const length = try std.math.mul(usize, value.unit.len, value.count);
            const bytes = try allocator.alloc(u8, length);
            for (0..value.count) |index|
                @memcpy(bytes[index * value.unit.len ..][0..value.unit.len], value.unit);
            break :blk .{ .allocator = allocator, .value = bytes };
        },
        .repeat_suffix => |value| blk: {
            const repeated = try std.math.mul(usize, value.unit.len, value.count);
            const length = try std.math.add(usize, repeated, value.suffix.len);
            const bytes = try allocator.alloc(u8, length);
            for (0..value.count) |index|
                @memcpy(bytes[index * value.unit.len ..][0..value.unit.len], value.unit);
            @memcpy(bytes[repeated..], value.suffix);
            break :blk .{ .allocator = allocator, .value = bytes };
        },
        .fill_between => |value| blk: {
            const body_end = try std.math.add(usize, value.prefix.len, value.count);
            const length = try std.math.add(usize, body_end, value.suffix.len);
            const bytes = try allocator.alloc(u8, length);
            @memcpy(bytes[0..value.prefix.len], value.prefix);
            @memset(bytes[value.prefix.len..body_end], value.byte);
            @memcpy(bytes[body_end..], value.suffix);
            break :blk .{ .allocator = allocator, .value = bytes };
        },
        .stable_identifier => |value| blk: {
            const first = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_";
            const rest = first ++ "0123456789";
            const bytes = try allocator.alloc(u8, value.bytes);
            var random = SplitMix64{ .state = value.seed };
            if (bytes.len != 0) {
                bytes[0] = first[random.next() % first.len];
                for (bytes[1..]) |*byte| byte.* = rest[random.next() % rest.len];
            }
            break :blk .{ .allocator = allocator, .value = bytes };
        },
    };
}

/// Compiles one workload pattern and turns an unexpected diagnostic into a
/// harness failure rather than silently timing rejection.
fn compileExpression(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    options: regex.CompileOptions,
) !regex.Regex {
    return switch (try regex.Regex.compile(allocator, pattern, options)) {
        .success => |value| value,
        .diagnostic => |diagnostic| {
            std.debug.print("unexpected diagnostic={s} span={d}..{d}\n", .{
                @tagName(diagnostic.code), diagnostic.start, diagnostic.end,
            });
            return error.UnexpectedDiagnostic;
        },
    };
}

fn matcherRoute(matcher: *const regex.Matcher) Route {
    return regex.benchmarkRoute(matcher);
}

fn retainedBytes(expression: *const regex.Regex, matcher: *const regex.Matcher) usize {
    var total = expression.compileMetrics().requested_retained_bytes +| matcher.metrics().requested_live_bytes;
    if (regex.tryLazyMetrics(expression)) |lazy| {
        if (lazy.reverse_program) |reverse| total +|= reverse.requested_retained_bytes;
        if (lazy.one_pass_plan) |plan| total +|= plan.requested_retained_bytes;
    }
    if (regex.tryCacheMetrics(expression)) |caches| total +|= caches.total_requested_live_bytes;
    return total;
}

fn peakBytes(expression: *const regex.Regex, matcher: *const regex.Matcher) usize {
    var total = expression.compileMetrics().requested_peak_bytes +| matcher.metrics().requested_peak_bytes;
    if (regex.tryLazyMetrics(expression)) |lazy| {
        if (lazy.reverse_program) |reverse| total +|= reverse.requested_peak_bytes;
        if (lazy.one_pass_plan) |plan| total +|= plan.requested_peak_bytes;
    }
    if (regex.tryCacheMetrics(expression)) |caches| total +|= caches.total_requested_peak_bytes;
    return total;
}

/// Aggregates all currently published private DFA roles into one sample. A busy
/// shared state yields an empty optional snapshot rather than perturbing timing.
fn dfaMeasurement(expression: *const regex.Regex) workload_data.DfaMeasurement {
    const physical = regex.tryPhysicalCacheMetrics(expression) orelse return .{};
    var result: workload_data.DfaMeasurement = .{};
    for ([_]@TypeOf(physical.forward){
        physical.forward,
        physical.reverse,
        physical.full,
    }) |optional| {
        const value = optional orelse continue;
        result.states +|= value.state_count;
        result.cache_live_bytes +|= value.requested_live_bytes;
        result.cache_peak_bytes +|= value.requested_peak_bytes;
        result.instruction_ids +|= value.instruction_ids;
        result.transition_slots +|= value.transition_slots;
        result.hash_bytes +|= value.hash_bytes;
        result.exhausted = result.exhausted or value.exhausted;
    }
    return result;
}

/// Implements ReBar's `grep-captures` model without allocating line or result
/// collections. Newline and an immediately preceding carriage return are not
/// presented to the regex. Every participating group, including group zero, is
/// counted for every non-overlapping match on each line.
fn grepCaptureCount(
    matcher: *regex.Matcher,
    input: []const u8,
    capture_count: u32,
) !usize {
    var total: usize = 0;
    var line_start: usize = 0;
    while (line_start < input.len) {
        const newline = std.mem.indexOfScalarPos(u8, input, line_start, '\n');
        const physical_end = newline orelse input.len;
        var line_end = physical_end;
        if (line_end > line_start and input[line_end - 1] == '\r') line_end -= 1;
        var matches = matcher.captureIterator(input[line_start..line_end]);
        while (try matches.next()) |view| {
            for (0..@as(usize, capture_count) + 1) |group|
                total +|= @intFromBool(view.group(group) != null);
        }
        line_start = if (newline != null) physical_end + 1 else input.len;
    }
    return total;
}

/// Directly compares one public observation with the readable workload
/// expectation before any digest-based timing. Tag-specific checks cover exact
/// and absent captures, complete iterator exhaustion, compact repeated-span
/// expansion, empty-match progress, and ReBar-style line capture counts.
fn qualifyMatch(matcher: *regex.Matcher, workload: Workload, input: []const u8) !void {
    switch (workload.task) {
        .find => |task| {
            const actual = matcher.find(input);
            switch (task.expected) {
                .none => if (actual != null) return error.ObservationMismatch,
                .some => |expected| {
                    const found = actual orelse return error.ObservationMismatch;
                    if (found.start != expected.start or found.end != expected.end)
                        return error.ObservationMismatch;
                },
            }
        },
        .captures => |task| {
            const actual = try matcher.captures(input);
            if (task.expected) |expected| {
                const view = actual orelse return error.ObservationMismatch;
                const whole = view.group(0) orelse return error.ObservationMismatch;
                if (whole.start != expected.whole.start or whole.end != expected.whole.end)
                    return error.ObservationMismatch;
                for (expected.groups, 1..) |wanted, group| {
                    const found = view.group(group);
                    if (wanted) |span| {
                        const value = found orelse return error.ObservationMismatch;
                        if (value.start != span.start or value.end != span.end)
                            return error.ObservationMismatch;
                    } else if (found != null) return error.ObservationMismatch;
                }
            } else if (actual != null) return error.ObservationMismatch;
        },
        .full => |task| if (matcher.fullMatch(input) != task.expected) return error.ObservationMismatch,
        .count => |task| if (matcher.count(input) != task.expected) return error.ObservationMismatch,
        .iterate => |task| {
            var iterator = matcher.iterator(input);
            switch (task.expected) {
                .exact => |expected| {
                    for (expected) |span| {
                        const found = iterator.next() orelse return error.ObservationMismatch;
                        if (found.start != span.start or found.end != span.end)
                            return error.ObservationMismatch;
                    }
                    if (iterator.next() != null) return error.ObservationMismatch;
                },
                .repeated => |expected| {
                    if (expected.unit_bytes == 0 or
                        expected.count > input.len / expected.unit_bytes or
                        expected.count * expected.unit_bytes != input.len)
                        return error.InvalidRepeatedSpanExpectation;
                    for (0..expected.count) |repetition| {
                        const base = repetition * expected.unit_bytes;
                        for (expected.unit_spans) |span| {
                            if (span.start > span.end or span.end > expected.unit_bytes)
                                return error.InvalidRepeatedSpanExpectation;
                            const found = iterator.next() orelse return error.ObservationMismatch;
                            if (found.start != base + span.start or found.end != base + span.end)
                                return error.ObservationMismatch;
                        }
                    }
                    if (iterator.next() != null) return error.ObservationMismatch;
                },
                .empty_every_byte => |input_len| {
                    var position: usize = 0;
                    while (position <= input_len) : (position += 1) {
                        const found = iterator.next() orelse return error.ObservationMismatch;
                        if (found.start != position or found.end != position)
                            return error.ObservationMismatch;
                    }
                    if (iterator.next() != null) return error.ObservationMismatch;
                },
            }
        },
        .grep_captures => |task| {
            if (try grepCaptureCount(matcher, input, task.capture_count) !=
                task.expected_participating)
                return error.ObservationMismatch;
        },
        else => unreachable,
    }
}

/// Executes one task and folds all result fields into a deterministic digest;
/// owned result traversal and teardown are included in this operation.
fn observeMatch(matcher: *regex.Matcher, task: workload_data.Task, input: []const u8) !u64 {
    var checksum: u64 = 0;
    switch (task) {
        .find => {
            if (matcher.find(input)) |found|
                hashSpan(&checksum, found)
            else
                checksum = mix(checksum, std.math.maxInt(u64));
        },
        .captures => |capture_task| {
            if (try matcher.captures(input)) |view| {
                hashSpan(&checksum, view.group(0).?);
                const group_count = if (capture_task.expected) |expected| expected.groups.len else 0;
                for (1..group_count + 1) |group| {
                    if (view.group(group)) |found|
                        hashSpan(&checksum, found)
                    else
                        checksum = mix(checksum, std.math.maxInt(u64) - group);
                }
            } else checksum = mix(checksum, std.math.maxInt(u64));
        },
        .full => checksum = mix(checksum, @intFromBool(matcher.fullMatch(input))),
        .count => checksum = mix(checksum, matcher.count(input)),
        .iterate => {
            var iterator = matcher.iterator(input);
            while (iterator.next()) |found| hashSpan(&checksum, found);
        },
        .grep_captures => |value| checksum = mix(
            checksum,
            try grepCaptureCount(matcher, input, value.capture_count),
        ),
        else => unreachable,
    }
    return checksum;
}

/// Qualifies, warms, times, and rechecks one ordinary Regex/Matcher operation;
/// compilation and materialization remain outside the measured interval.
fn runMatch(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    workload: Workload,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
) !workload_data.Measurement {
    var expression = try compileExpression(allocator, pattern, workload.options);
    defer expression.deinit();
    switch (workload.task) {
        .captures => |task| if (task.expected != null and
            task.expected.?.groups.len != expression.captureCount())
            return error.CaptureExpectationLengthMismatch,
        .grep_captures => |task| if (task.capture_count != expression.captureCount())
            return error.CaptureExpectationLengthMismatch,
        else => {},
    }
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();
    try qualifyMatch(&matcher, workload, input);

    var warm_checksum: u64 = 0;
    for (0..iterations) |_| warm_checksum = mix(warm_checksum, try observeMatch(&matcher, workload.task, input));
    std.mem.doNotOptimizeAway(warm_checksum);

    var checksum: u64 = 0;
    const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
    for (0..iterations) |_| checksum = mix(checksum, try observeMatch(&matcher, workload.task, input));
    const elapsed = begin.untilNow(init.io).raw.toNanoseconds();

    var expected_checksum: u64 = 0;
    const one = try observeExpected(workload.task);
    for (0..iterations) |_| expected_checksum = mix(expected_checksum, one);
    if (checksum != expected_checksum) return error.TimedObservationMismatch;

    const compile_metrics = expression.compileMetrics();
    const matcher_metrics = matcher.metrics();
    return .{
        .elapsed_ns = elapsed,
        .checksum = checksum,
        .pattern_bytes = pattern.len,
        .input_bytes = input.len,
        .retained_bytes = retainedBytes(&expression, &matcher),
        .peak_bytes = peakBytes(&expression, &matcher),
        .allocations = compile_metrics.allocation_count +| matcher_metrics.allocation_count,
        .route = matcherRoute(&matcher),
        .dfa = dfaMeasurement(&expression),
    };
}

/// Computes the digest implied by reviewed expected data, independently of the
/// observed operation, so post-timing comparison detects result drift.
fn observeExpected(task: workload_data.Task) !u64 {
    var checksum: u64 = 0;
    switch (task) {
        .find => |value| switch (value.expected) {
            .none => checksum = mix(checksum, std.math.maxInt(u64)),
            .some => |span| hashSpan(&checksum, .{ .start = span.start, .end = span.end }),
        },
        .captures => |value| {
            if (value.expected) |expected| {
                hashSpan(&checksum, .{ .start = expected.whole.start, .end = expected.whole.end });
                for (expected.groups, 1..) |group, index| {
                    if (group) |span|
                        hashSpan(&checksum, .{ .start = span.start, .end = span.end })
                    else
                        checksum = mix(checksum, std.math.maxInt(u64) - index);
                }
            } else checksum = mix(checksum, std.math.maxInt(u64));
        },
        .full => |value| checksum = mix(checksum, @intFromBool(value.expected)),
        .count => |value| checksum = mix(checksum, value.expected),
        .iterate => |value| switch (value.expected) {
            .exact => |spans| for (spans) |span| hashSpan(&checksum, .{ .start = span.start, .end = span.end }),
            .repeated => |expected| for (0..expected.count) |repetition| {
                const base = repetition * expected.unit_bytes;
                for (expected.unit_spans) |span| hashSpan(&checksum, .{
                    .start = base + span.start,
                    .end = base + span.end,
                });
            },
            .empty_every_byte => |input_len| for (0..input_len + 1) |position| hashSpan(&checksum, .{ .start = position, .end = position }),
        },
        .grep_captures => |value| checksum = mix(checksum, value.expected_participating),
        else => return error.InvalidTask,
    }
    return checksum;
}

/// Times complete compile/deinit lifecycles and validates capture count for every
/// iteration; unlike match workloads, owner construction is the measured work.
fn runCompile(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    workload: Workload,
    pattern: []const u8,
    iterations: usize,
) !workload_data.Measurement {
    const expected = workload.task.compile.capture_count;
    var qualified = try compileExpression(allocator, pattern, workload.options);
    if (qualified.captureCount() != expected) return error.ObservationMismatch;
    qualified.deinit();

    for (0..iterations) |_| {
        var expression = try compileExpression(allocator, pattern, workload.options);
        std.mem.doNotOptimizeAway(expression.captureCount());
        expression.deinit();
    }
    var checksum: u64 = 0;
    var retained: usize = 0;
    var peak: usize = 0;
    var allocations: usize = 0;
    const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
    for (0..iterations) |_| {
        var expression = try compileExpression(allocator, pattern, workload.options);
        checksum = mix(checksum, expression.captureCount() + 1);
        const metrics = expression.compileMetrics();
        retained = @max(retained, metrics.requested_retained_bytes);
        peak = @max(peak, metrics.requested_peak_bytes);
        allocations = @max(allocations, metrics.allocation_count);
        expression.deinit();
    }
    var expected_checksum: u64 = 0;
    for (0..iterations) |_| expected_checksum = mix(expected_checksum, expected + 1);
    if (checksum != expected_checksum) return error.TimedObservationMismatch;
    return .{
        .elapsed_ns = begin.untilNow(init.io).raw.toNanoseconds(),
        .checksum = checksum,
        .pattern_bytes = pattern.len,
        .input_bytes = 0,
        .retained_bytes = retained,
        .peak_bytes = peak,
        .allocations = allocations,
        .route = .{},
    };
}

/// Materializes collection sources directly into either Set or Filtered Builder,
/// asserting that every generated pattern compiles successfully.
fn addPatterns(builder: anytype, source: workload_data.PatternSetSource) !usize {
    var count: usize = 0;
    switch (source) {
        .list => |patterns| for (patterns) |pattern| {
            const added = try builder.add(pattern);
            if (added != .success) return error.UnexpectedDiagnostic;
            count += 1;
        },
        .numbered => |value| for (0..value.count) |index| {
            var buffer: [128]u8 = undefined;
            const pattern = try numberedWord(&buffer, value.prefix, index, value.width, value.suffix);
            const added = try builder.add(pattern);
            if (added != .success) return error.UnexpectedDiagnostic;
            count += 1;
        },
    }
    return count;
}

/// Builds and warms one Set, then times result collection and verifies the exact
/// insertion-order ID digest after the batch.
fn runSet(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    workload: Workload,
    input: []const u8,
    iterations: usize,
) !workload_data.Measurement {
    const task = workload.task.set;
    var builder = regex.Set.Builder.init(allocator, workload.options, .unanchored);
    defer builder.deinit();
    const count = try addPatterns(&builder, task.patterns);
    var set = try builder.compile();
    defer set.deinit();
    var matcher = try set.matcher(allocator);
    defer matcher.deinit();

    var qualified = try matcher.allMatches(allocator, input, count);
    defer qualified.deinit();
    if (!std.mem.eql(u32, qualified.values(), task.expected_pattern_ids)) return error.ObservationMismatch;

    for (0..iterations) |_| {
        var ids = try matcher.allMatches(allocator, input, count);
        for (ids.values()) |id| std.mem.doNotOptimizeAway(id);
        ids.deinit();
    }
    var checksum: u64 = 0;
    const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
    for (0..iterations) |_| {
        var ids = try matcher.allMatches(allocator, input, count);
        var observed: u64 = 0;
        observed = mix(observed, ids.values().len);
        for (ids.values()) |id| observed = mix(observed, id + 1);
        checksum = mix(checksum, observed);
        ids.deinit();
    }
    var one: u64 = 0;
    one = mix(one, task.expected_pattern_ids.len);
    for (task.expected_pattern_ids) |id| one = mix(one, id + 1);
    var expected: u64 = 0;
    for (0..iterations) |_| expected = mix(expected, one);
    if (checksum != expected) return error.TimedObservationMismatch;
    const collection_metrics = set.collectionMetrics();
    const matcher_metrics = matcher.metrics();
    return .{
        .elapsed_ns = begin.untilNow(init.io).raw.toNanoseconds(),
        .checksum = checksum,
        .pattern_bytes = 0,
        .input_bytes = input.len,
        .retained_bytes = regex.setRetainedBytes(&set, &matcher),
        .peak_bytes = collection_metrics.requested_peak_bytes +| matcher_metrics.requested_peak_bytes,
        .allocations = collection_metrics.allocation_count +| matcher_metrics.allocation_count,
        .route = .{},
    };
}

/// Builds and warms one Filtered collection, then times integrated scanning plus
/// exact first-candidate verification.
fn runFiltered(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    workload: Workload,
    input: []const u8,
    iterations: usize,
) !workload_data.Measurement {
    const task = workload.task.filtered;
    var builder = regex.Filtered.Builder.init(allocator, workload.options, 3);
    defer builder.deinit();
    _ = try addPatterns(&builder, task.patterns);
    var filtered = try builder.compile();
    defer filtered.deinit();
    var matcher = try filtered.matcher(allocator);
    defer matcher.deinit();
    if ((try matcher.firstMatchScanned(input)) != task.expected_pattern_id) return error.ObservationMismatch;

    for (0..iterations) |_| std.mem.doNotOptimizeAway(try matcher.firstMatchScanned(input));
    var checksum: u64 = 0;
    const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
    for (0..iterations) |_| {
        const id = try matcher.firstMatchScanned(input);
        checksum = mix(checksum, if (id) |value| value + 1 else std.math.maxInt(u64));
    }
    const one: u64 = if (task.expected_pattern_id) |value| @as(u64, value) + 1 else std.math.maxInt(u64);
    var expected: u64 = 0;
    for (0..iterations) |_| expected = mix(expected, one);
    if (checksum != expected) return error.TimedObservationMismatch;
    const collection_metrics = filtered.collectionMetrics();
    const matcher_metrics = matcher.metrics();
    return .{
        .elapsed_ns = begin.untilNow(init.io).raw.toNanoseconds(),
        .checksum = checksum,
        .pattern_bytes = 0,
        .input_bytes = input.len,
        .retained_bytes = regex.filteredRetainedBytes(&filtered, &matcher),
        .peak_bytes = collection_metrics.requested_peak_bytes +| matcher_metrics.requested_peak_bytes,
        .allocations = collection_metrics.allocation_count +| matcher_metrics.allocation_count,
        .route = .{},
    };
}

const workload_count = workload_data.workloads.len + campaign.count;

/// Resolves the flattened stable/generated catalog index.
fn workloadAt(index: usize) !Workload {
    if (index < workload_data.workloads.len) return workload_data.workloads[index];
    const campaign_index = index - workload_data.workloads.len;
    if (campaign_index >= campaign.count) return error.UnknownWorkload;
    return campaign.workload(campaign_index);
}

/// Rejects duplicate/invalid authored and generated definitions before listing or
/// running any benchmark.
fn validateDefinitions() !void {
    try campaign.validate();
    for (workload_data.workloads) |workload|
        if (workload.name.len == 0) return error.InvalidWorkload;
}

/// Serializes cumulative route bits in stable field order for the Python parser.
fn routeText(route: Route, buffer: []u8) ![]const u8 {
    var length: usize = 0;
    inline for (@typeInfo(Route).@"struct".fields) |field| {
        if (@field(route, field.name)) {
            const needed = field.name.len + @intFromBool(length != 0);
            if (needed > buffer.len - length) return error.RouteBufferTooSmall;
            if (length != 0) {
                buffer[length] = ',';
                length += 1;
            }
            @memcpy(buffer[length .. length + field.name.len], field.name);
            length += field.name.len;
        }
    }
    if (length == 0) {
        @memcpy(buffer[0..4], "none");
        length = 4;
    }
    return buffer[0..length];
}

/// Emits one stable tab-separated catalog row, materializing generated pattern
/// bytes only for exact identity output and releasing them before the next row.
fn printWorkload(
    init: std.process.Init,
    index: usize,
    workload: Workload,
    detail: ?[]const u8,
) !void {
    const allocator = std.heap.c_allocator;
    var pattern = try materializePattern(allocator, workload.pattern);
    defer pattern.deinit();

    var buffer: [512]u8 = undefined;
    var writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try writer.interface.print("{d}\t{s}\t{s}", .{
        index, @tagName(workload.task), workload.name,
    });
    if (detail) |value| try writer.interface.print(" ({s})", .{value});
    try writer.interface.writeByte('\t');
    try writePatterns(&writer.interface, workload, pattern.value);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

/// Materializes one catalog entry, dispatches its task-specific timing harness,
/// and optionally emits the single machine-readable process result.
fn runWorkload(
    init: std.process.Init,
    index: usize,
    workload: Workload,
    iterations: usize,
    emit: bool,
) !void {
    const allocator = std.heap.c_allocator;
    var pattern = try materializePattern(allocator, workload.pattern);
    defer pattern.deinit();
    var input = try materializeInput(allocator, workload.input);
    defer input.deinit();
    const result = switch (workload.task) {
        .compile => try runCompile(init, allocator, workload, pattern.value, iterations),
        .set => try runSet(init, allocator, workload, input.value, iterations),
        .filtered => try runFiltered(init, allocator, workload, input.value, iterations),
        else => try runMatch(init, allocator, workload, pattern.value, input.value, iterations),
    };
    if (emit) {
        var route_buffer: [256]u8 = undefined;
        const route = try routeText(result.route, &route_buffer);
        var output_buffer: [1024]u8 = undefined;
        var writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
        try writer.interface.print(
            "case={d} elapsed_ns={d} iterations={d} checksum={d} pattern_bytes={d} " ++
                "input_bytes={d} retained_bytes={d} peak_bytes={d} allocations={d} route={s} " ++
                "dfa_states={d} dfa_cache_live_bytes={d} dfa_cache_peak_bytes={d} " ++
                "dfa_instruction_ids={d} dfa_transition_slots={d} dfa_hash_bytes={d} dfa_exhausted={d}\n",
            .{
                index,                              result.elapsed_ns,          iterations,                  result.checksum,
                result.pattern_bytes,               result.input_bytes,         result.retained_bytes,       result.peak_bytes,
                result.allocations,                 route,                      result.dfa.states,           result.dfa.cache_live_bytes,
                result.dfa.cache_peak_bytes,        result.dfa.instruction_ids, result.dfa.transition_slots, result.dfa.hash_bytes,
                @intFromBool(result.dfa.exhausted),
            },
        );
        try writer.interface.flush();
    }
}

/// Implements the strict adapter protocol consumed by `benchmark.py`. Every
/// command validates the catalog first; list renders stable identities and exact
/// materialized patterns, validate qualifies each workload once without output,
/// and run emits exactly one row.
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const command = args.next() orelse return error.MissingCommand;
    try validateDefinitions();
    if (std.mem.eql(u8, command, "--list")) {
        if (args.next() != null) return error.ExcessArgument;
        for (workload_data.workloads, 0..) |workload, index|
            try printWorkload(init, index, workload, null);
        var detail_buffer: [96]u8 = undefined;
        for (0..campaign.count) |campaign_index|
            try printWorkload(
                init,
                workload_data.workloads.len + campaign_index,
                try campaign.workload(campaign_index),
                try campaign.detail(campaign_index, &detail_buffer),
            );
        return;
    }
    if (std.mem.eql(u8, command, "--validate")) {
        if (args.next() != null) return error.ExcessArgument;
        for (0..workload_count) |index|
            try runWorkload(init, index, try workloadAt(index), 1, false);
        return;
    }
    if (!std.mem.eql(u8, command, "--run")) return error.InvalidCommand;
    const index = try std.fmt.parseInt(usize, args.next() orelse return error.MissingWorkload, 10);
    const iterations = try std.fmt.parseInt(usize, args.next() orelse return error.MissingIterations, 10);
    if (iterations == 0 or args.next() != null) return error.InvalidIterations;
    try runWorkload(init, index, try workloadAt(index), iterations, true);
}
