//! Deterministic public-API stress for shared Regex state and independent Matchers.
//!
//! The main thread compiles reviewed cases and computes single-thread reference
//! checksums. Worker threads then create their own Matchers, choose deterministic
//! operation mixes, and repeatedly compare results while sharing only Regex
//! State. This drives concurrent known-DFA reads, exclusive cache construction,
//! reverse/OnePass lazy publication, and complete fallback under contention.
//!
//! Epochs vary worker count and seed. Atomics coordinate start/failure reporting;
//! mutable matcher scratch and borrowed CaptureViews never cross threads. The
//! test is about exact public results and race-safe ownership, not requiring any
//! particular accelerator to win the lock.

const std = @import("std");
const regex = @import("../root.zig");

const case_count = 6;

/// Public operation mix assigned to one immutable shared Regex case.
const Operation = enum { range, captures, full, exists, mixed };

/// Reviewed pattern/input pair and the operation used to exercise its shared lazy
/// state.
const Case = struct {
    pattern: []const u8,
    input: []const u8,
    operation: Operation,
};

fn mix(hash: u64, value: u64) u64 {
    return hash ^ (value +% 0x9e3779b97f4a7c15 +% (hash << 6) +% (hash >> 2));
}

fn random(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var value = state.*;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return value ^ (value >> 31);
}

/// Builds a binary De Bruijn sequence so every fixed-width context appears,
/// driving many distinct DFA transitions with deterministic compact input.
fn deBruijnBinary(allocator: std.mem.Allocator, order: u5) ![]u8 {
    const size = @as(usize, 1) << order;
    const mask = size - 1;
    const visited = try allocator.alloc(bool, size);
    defer allocator.free(visited);
    @memset(visited, false);
    const output = try allocator.alloc(u8, size + order - 1);
    @memset(output[0 .. order - 1], '0');
    var bits: usize = 0;
    for (0..size) |index| {
        bits = (bits << 1) & mask;
        if (!visited[bits | 1]) {
            bits |= 1;
            output[order - 1 + index] = '1';
        } else {
            output[order - 1 + index] = '0';
        }
        std.debug.assert(!visited[bits]);
        visited[bits] = true;
    }
    return output;
}

/// Compiles the complete reviewed case array transactionally; partial Regex
/// owners are destroyed in forward-initialization order on any failure.
fn compileExpressions(
    allocator: std.mem.Allocator,
    cases: *const [case_count]Case,
) ![case_count]regex.Regex {
    var expressions: [case_count]regex.Regex = undefined;
    var initialized: usize = 0;
    errdefer for (expressions[0..initialized]) |*expression| expression.deinit();
    for (&expressions, cases) |*expression, case| {
        const compiled = try regex.Regex.compile(allocator, case.pattern, .{});
        expression.* = switch (compiled) {
            .success => |value| value,
            .diagnostic => return error.UnexpectedDiagnostic,
        };
        initialized += 1;
    }
    return expressions;
}

fn deinitExpressions(expressions: *[case_count]regex.Regex) void {
    for (expressions) |*expression| expression.deinit();
}

/// Executes one public operation and folds every observable result field into a
/// stable checksum; captures are read before the next matcher operation.
fn execute(
    matcher: *regex.Matcher,
    expression: *const regex.Regex,
    case: Case,
    checksum: u64,
) !u64 {
    var result = checksum;
    switch (case.operation) {
        .range => {
            if (matcher.find(case.input)) |found| {
                result = mix(result, found.start + 1);
                result = mix(result, found.end + 1);
            } else result = mix(result, std.math.maxInt(u64));
        },
        .captures => {
            const captures = try matcher.captures(case.input);
            if (captures) |view| {
                const groups = @min(@as(usize, expression.captureCount()) + 1, 4);
                for (0..groups) |group| {
                    if (view.group(group)) |found| {
                        result = mix(result, found.start + 1);
                        result = mix(result, found.end + 1);
                    } else result = mix(result, std.math.maxInt(u64) - group);
                }
            } else result = mix(result, std.math.maxInt(u64));
        },
        .full => result = mix(result, @intFromBool(matcher.fullMatch(case.input))),
        .exists => result = mix(result, @intFromBool(matcher.isMatch(case.input))),
        .mixed => {
            if (matcher.find(case.input)) |found| {
                result = mix(result, found.start + 1);
                result = mix(result, found.end + 1);
            } else result = mix(result, std.math.maxInt(u64));
            result = mix(result, @intFromBool(matcher.fullMatch(case.input)));
            if (try matcher.captures(case.input)) |view| {
                for (0..@min(@as(usize, expression.captureCount()) + 1, 4)) |group| {
                    if (view.group(group)) |found| {
                        result = mix(result, found.start + 1);
                        result = mix(result, found.end + 1);
                    } else result = mix(result, std.math.maxInt(u64) - group);
                }
            } else result = mix(result, std.math.maxInt(u64));
            result = mix(result, @intFromBool(matcher.isMatch(case.input)));
        },
    }
    return result;
}

/// Computes the single-thread reference for one worker's exact seeded operation
/// schedule using independent Matchers.
fn workerChecksum(
    allocator: std.mem.Allocator,
    expressions: *const [case_count]regex.Regex,
    cases: *const [case_count]Case,
    worker_id: usize,
    iterations: usize,
    seed: u64,
) !u64 {
    var matchers: [case_count]regex.Matcher = undefined;
    var initialized: usize = 0;
    defer for (matchers[0..initialized]) |*matcher| matcher.deinit();
    for (&matchers, expressions) |*matcher, *expression| {
        matcher.* = try regex.Matcher.init(allocator, expression);
        initialized += 1;
    }
    var state = seed ^ (@as(u64, @intCast(worker_id)) *% 0xd1342543de82ef95);
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        const index: usize = @intCast(random(&state) % case_count);
        checksum = try execute(&matchers[index], &expressions[index], cases[index], checksum);
    }
    return checksum;
}

/// Immutable campaign inputs plus atomic epoch barrier/failure state shared by
/// all worker threads.
const Shared = struct {
    allocator: std.mem.Allocator,
    expressions: *const [case_count]regex.Regex,
    cases: *const [case_count]Case,
    iterations: usize,
    seed: u64,
    ready: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    start: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Per-thread schedule identity, expected checksum, and independently written
/// actual result.
const Worker = struct {
    shared: *Shared,
    id: usize,
    expected: u64,
    actual: u64 = 0,

    /// Initializes private Matcher scratch, joins the start barrier, replays the
    /// reference schedule, and publishes any mismatch through the shared flag.
    fn run(self: *@This()) void {
        var matchers: [case_count]regex.Matcher = undefined;
        var initialized: usize = 0;
        defer for (matchers[0..initialized]) |*matcher| matcher.deinit();
        for (&matchers, self.shared.expressions) |*matcher, *expression| {
            matcher.* = regex.Matcher.init(self.shared.allocator, expression) catch {
                self.shared.failed.store(true, .release);
                return;
            };
            initialized += 1;
        }
        _ = self.shared.ready.fetchAdd(1, .acq_rel);
        while (!self.shared.start.load(.acquire)) std.atomic.spinLoopHint();

        var state = self.shared.seed ^ (@as(u64, @intCast(self.id)) *% 0xd1342543de82ef95);
        var checksum: u64 = 0;
        for (0..self.shared.iterations) |_| {
            const index: usize = @intCast(random(&state) % case_count);
            checksum = execute(
                &matchers[index],
                &self.shared.expressions[index],
                self.shared.cases[index],
                checksum,
            ) catch {
                self.shared.failed.store(true, .release);
                return;
            };
        }
        self.actual = checksum;
        if (checksum != self.expected) self.shared.failed.store(true, .release);
    }
};

fn parsePositive(comptime T: type, value: []const u8) !T {
    const parsed = try std.fmt.parseInt(T, value, 10);
    if (parsed == 0) return error.InvalidStressArgument;
    return parsed;
}

/// Parses bounded campaign controls, computes each seeded worker's serial
/// checksum once, then runs fresh shared Regex states through synchronized
/// multithreaded epochs. Every worker owns its Matcher scratch; atomics publish
/// barrier readiness and any result mismatch before aggregate reporting.
pub fn main(init: std.process.Init) !void {
    var workers_count: usize = 8;
    var iterations: usize = 5_000;
    var epochs: usize = 20;
    var seed: u64 = 0xc011ab1e5eed;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |argument| {
        const value = args.next() orelse return error.MissingStressArgument;
        if (std.mem.eql(u8, argument, "--workers"))
            workers_count = try parsePositive(usize, value)
        else if (std.mem.eql(u8, argument, "--iterations"))
            iterations = try parsePositive(usize, value)
        else if (std.mem.eql(u8, argument, "--epochs"))
            epochs = try parsePositive(usize, value)
        else if (std.mem.eql(u8, argument, "--seed"))
            seed = try std.fmt.parseInt(u64, value, 0)
        else
            return error.InvalidStressArgument;
    }
    if (workers_count > 64) return error.InvalidStressArgument;

    const allocator = std.heap.c_allocator;
    const pressure = try deBruijnBinary(allocator, 10);
    defer allocator.free(pressure);
    const cases = [case_count]Case{
        .{ .pattern = "(ab|a)+c", .input = "xxababc", .operation = .range },
        .{ .pattern = "([a-z]+)-([0-9]+)$", .input = "word-123", .operation = .captures },
        .{ .pattern = "(?:a|aa)*b", .input = "aaaaab", .operation = .full },
        .{ .pattern = "(?m)^foo$", .input = "x\nfoo\ny", .operation = .range },
        .{ .pattern = "0[01]{10}2", .input = pressure, .operation = .exists },
        .{ .pattern = "([a-z]+)([0-9]*)$", .input = "alpha42", .operation = .mixed },
    };

    var reference = try compileExpressions(allocator, &cases);
    defer deinitExpressions(&reference);
    const expected = try allocator.alloc(u64, workers_count);
    defer allocator.free(expected);
    for (expected, 0..) |*value, worker_id|
        value.* = try workerChecksum(allocator, &reference, &cases, worker_id, iterations, seed);

    const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
    var combined: u64 = 0;
    for (0..epochs) |epoch| {
        var expressions = try compileExpressions(allocator, &cases);
        defer deinitExpressions(&expressions);
        var shared = Shared{
            .allocator = allocator,
            .expressions = &expressions,
            .cases = &cases,
            .iterations = iterations,
            .seed = seed,
        };
        const workers = try allocator.alloc(Worker, workers_count);
        defer allocator.free(workers);
        const threads = try allocator.alloc(std.Thread, workers_count);
        defer allocator.free(threads);
        for (workers, expected, 0..) |*worker, expected_checksum, worker_id| {
            worker.* = .{
                .shared = &shared,
                .id = worker_id,
                .expected = expected_checksum,
            };
            threads[worker_id] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        }
        while (shared.ready.load(.acquire) != workers_count) std.atomic.spinLoopHint();
        shared.start.store(true, .release);
        for (threads) |thread| thread.join();
        if (shared.failed.load(.acquire)) return error.ConcurrentMismatch;
        for (workers) |worker| combined = mix(combined, worker.actual ^ epoch);
    }
    const elapsed_ns = begin.untilNow(init.io).raw.toNanoseconds();
    std.mem.doNotOptimizeAway(combined);
    var output_buffer: [512]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    try file_writer.interface.print(
        "Concurrency stress...OK\n" ++
            "  Workers: {d}\n" ++
            "  Epochs: {d}\n" ++
            "  Iterations per worker: {d}\n" ++
            "  Operations: {d}\n" ++
            "  Elapsed: {d} ns\n",
        .{
            workers_count,
            epochs,
            iterations,
            epochs * workers_count * iterations,
            elapsed_ns,
        },
    );
    try file_writer.interface.flush();
}
