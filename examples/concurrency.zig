//! # Share a Regex across threads
//!
//! Regex is immutable public state and may be shared by independent Matchers.
//! Matcher is mutable, single-threaded scratch: create one per worker.
//!
//! The Regex allocator must be usable from every matching thread because shared
//! accelerator artifacts may be initialized lazily. Join workers and destroy all
//! Matchers before destroying the Regex.
//!
//! Thread completion order does not affect the output order.
//!
//! Expected output:
//!
//! ```text
//! input: job-1; entire input matched: true
//! input: bad; entire input matched: false
//! input: task-42; entire input matched: true
//! input: also_bad; entire input matched: false
//! ```

const std = @import("std");
const regex = @import("regex");

const Outcome = struct {
    matched: bool = false,
    failed: bool = false,
};

const Job = struct {
    expression: *const regex.Regex,
    input: []const u8,
    outcome: *Outcome,

    fn run(job: Job) void {
        // Mutable scratch is worker-local; only compiled Regex state is shared.
        var matcher = regex.Matcher.init(std.heap.page_allocator, job.expression) catch {
            job.outcome.failed = true;
            return;
        };
        defer matcher.deinit();
        job.outcome.matched = matcher.fullMatch(job.input);
    }
};

pub fn main() !void {
    // page_allocator is usable from every worker that may initialize a shared
    // lazy cache in this Regex.
    var expression = try regex.Regex.init(std.heap.page_allocator, "[a-z]+-[0-9]+");
    defer expression.deinit();

    const inputs = [_][]const u8{ "job-1", "bad", "task-42", "also_bad" };
    var outcomes = [_]Outcome{.{}} ** inputs.len;
    var threads: [inputs.len]std.Thread = undefined;

    // Each thread writes a distinct outcome slot, so no result lock is required.
    for (&threads, inputs, &outcomes) |*thread, input, *outcome| {
        thread.* = try std.Thread.spawn(.{}, Job.run, .{Job{
            .expression = &expression,
            .input = input,
            .outcome = outcome,
        }});
    }
    // Joining guarantees every child Matcher is gone before Regex teardown.
    for (threads) |thread| thread.join();

    for (inputs, outcomes) |input, outcome| {
        if (outcome.failed) return error.MatcherInitializationFailed;
        std.debug.print(
            "input: {s}; entire input matched: {}\n",
            .{ input, outcome.matched },
        );
    }
}
