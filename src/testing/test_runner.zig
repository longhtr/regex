//! Human-readable execution of the test graph assembled by `test_root.zig`.
//!
//! Zig supplies a flat compiled test-function table whose qualified names expose
//! source modules but make comptime-generated conformance cases difficult to
//! recognize. This runner groups entries by source, extracts the sentence stored
//! in each generated `TestCase` type, and otherwise preserves the ordinary test
//! name. It scans rather than sorts so output follows compiler/source order and
//! needs no allocation policy of its own.
//!
//! Tests run sequentially with per-test skip, leak, logged-error, and failure
//! accounting; the final process status reflects any failed or leaking case. This
//! is presentation and lifecycle plumbing only: expected answers remain in their
//! test modules, and the runner imports no production regex code.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const TestFn = @TypeOf(builtin.test_functions[0]);

pub const std_options: std.Options = .{ .logFn = log };

var logged_errors: usize = 0;

/// Parsed source-module heading and user-facing test description.
const Name = struct {
    module: []const u8,
    test_name: []const u8,
};

/// Aggregate outcomes used for final process status and summary.
const Counts = struct {
    passed: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    leaked: usize = 0,
};

/// Groups Zig's flat test table by each module's first appearance, then executes
/// every member under one heading and derives process status from failures and
/// leaks. The nested scans preserve compiler-provided source order without a
/// separate allocation or sorting policy.
pub fn main(init: std.process.Init.Minimal) void {
    const tests = builtin.test_functions;
    var counts: Counts = .{};

    // Preserve module order by first appearance while placing every test from
    // the same source module under one heading.
    for (tests, 0..) |test_function, index| {
        const current = displayName(test_function.name);
        var appeared = false;
        for (tests[0..index]) |previous| {
            if (std.mem.eql(u8, displayName(previous.name).module, current.module)) {
                appeared = true;
                break;
            }
        }
        if (appeared) continue;

        std.debug.print("\n[{s}]\n", .{current.module});
        for (tests) |candidate| {
            const candidate_name = displayName(candidate.name);
            if (!std.mem.eql(u8, candidate_name.module, current.module)) continue;
            runTest(init, candidate, candidate_name.test_name, &counts);
        }
    }

    std.debug.print("\n", .{});
    if (counts.failed == 0 and counts.skipped == 0) {
        std.debug.print("All {d} tests passed.\n", .{counts.passed});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{
            counts.passed,
            counts.skipped,
            counts.failed,
        });
    }
    if (counts.leaked != 0)
        std.debug.print("{d} tests leaked memory.\n", .{counts.leaked});
    if (counts.failed != 0 or counts.leaked != 0) std.process.exit(1);
}

/// Reinitializes testing allocator/I/O state for one function, invokes it, then
/// combines returned errors, allocation leaks, and error-level logs into one
/// displayed outcome. Borrowed error traces are printed before the next test
/// resets global testing state.
fn runTest(
    init: std.process.Init.Minimal,
    test_function: TestFn,
    name: []const u8,
    counts: *Counts,
) void {
    testing.allocator_instance = .{};
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    testing.environ = init.environ;
    testing.log_level = .warn;
    logged_errors = 0;

    std.debug.print("  {s}...", .{name});
    var outcome: enum { passed, skipped, failed } = .passed;
    var failure: ?anyerror = null;
    if (test_function.func()) |_| {
        outcome = .passed;
    } else |err| {
        if (err == error.SkipZigTest) {
            outcome = .skipped;
        } else {
            outcome = .failed;
            failure = err;
        }
    }

    testing.io_instance.deinit();
    if (testing.allocator_instance.deinit() == .leak) {
        counts.leaked += 1;
        outcome = .failed;
    }
    if (logged_errors != 0) outcome = .failed;

    switch (outcome) {
        .passed => {
            counts.passed += 1;
            std.debug.print("OK\n", .{});
        },
        .skipped => {
            counts.skipped += 1;
            std.debug.print("SKIP\n", .{});
        },
        .failed => {
            counts.failed += 1;
            if (failure) |err|
                std.debug.print("FAIL ({t})\n", .{err})
            else
                std.debug.print("FAIL\n", .{});
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        },
    }
}

/// Extracts the sentence embedded in a generated `TestCase` qualified name,
/// falling back unchanged when compiler formatting does not match the marker.
fn displayName(raw_name: []const u8) Name {
    const generated_marker = ".TestCase(";
    if (std.mem.indexOf(u8, raw_name, generated_marker)) |marker_start| {
        const arguments = raw_name[marker_start + generated_marker.len ..];
        const quote_relative = std.mem.indexOfScalar(u8, arguments, '"') orelse
            return ordinaryName(raw_name);
        const name_start = quote_relative + 1;
        const name_length = std.mem.indexOfScalar(u8, arguments[name_start..], '"') orelse
            return ordinaryName(raw_name);
        return .{
            .module = raw_name[0..marker_start],
            .test_name = arguments[name_start .. name_start + name_length],
        };
    }
    return ordinaryName(raw_name);
}

/// Splits an ordinary compiler-qualified test name into source grouping and
/// readable leaf name, with a stable fallback for unexpected formatting.
fn ordinaryName(raw_name: []const u8) Name {
    const marker = ".test.";
    if (std.mem.indexOf(u8, raw_name, marker)) |position| return .{
        .module = raw_name[0..position],
        .test_name = raw_name[position + marker.len ..],
    };
    const separator = std.mem.lastIndexOfScalar(u8, raw_name, '.') orelse return .{
        .module = "root",
        .test_name = raw_name,
    };
    return .{
        .module = raw_name[0..separator],
        .test_name = raw_name[separator + 1 ..],
    };
}

/// Project test-log sink: counts error-level messages for failure accounting and
/// forwards only messages admitted by the configured test log level.
fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    arguments: anytype,
) void {
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err)) logged_errors +|= 1;
    if (@intFromEnum(level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n",
            arguments,
        );
    }
}
