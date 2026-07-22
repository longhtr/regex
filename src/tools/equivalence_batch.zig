//! Command-line wrapper for private generated engine-equivalence qualification.
//!
//! Arguments select a named finite profile and optional reproduction controls,
//! then delegate all pattern generation, compilation, forced-engine execution,
//! and statistics to `engine/equivalence_campaign.zig`. Keeping this wrapper thin
//! lets unit tests invoke the same campaign logic in process.

const std = @import("std");
const campaign = @import("../engine/equivalence_campaign.zig");

fn parsePositive(comptime T: type, value: []const u8) !T {
    const parsed = try std.fmt.parseInt(T, value, 10);
    if (parsed == 0) return error.InvalidCampaignArgument;
    return parsed;
}

/// Applies strict positive CLI overrides to one named campaign profile, delegates
/// all generation and engine comparison to `campaign.run`, and reports only the
/// resulting coverage counters after a completely successful run.
pub fn main(init: std.process.Init) !void {
    var config = campaign.Config.full;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |argument| {
        const value = args.next() orelse return error.MissingCampaignArgument;
        if (std.mem.eql(u8, argument, "--profile")) {
            if (std.mem.eql(u8, value, "fixed"))
                config = .fixed
            else if (std.mem.eql(u8, value, "full"))
                config = .full
            else
                return error.InvalidCampaignArgument;
        } else if (std.mem.eql(u8, argument, "--range-patterns")) {
            config.range_patterns = try parsePositive(usize, value);
        } else if (std.mem.eql(u8, argument, "--capture-patterns")) {
            config.capture_patterns = try parsePositive(usize, value);
        } else if (std.mem.eql(u8, argument, "--range-input-max")) {
            config.range_input_max = try parsePositive(usize, value);
        } else if (std.mem.eql(u8, argument, "--capture-input-max")) {
            config.capture_input_max = try parsePositive(usize, value);
        } else if (std.mem.eql(u8, argument, "--max-dfa-states")) {
            config.max_dfa_states = try parsePositive(u32, value);
        } else {
            return error.InvalidCampaignArgument;
        }
    }

    const begin = std.Io.Clock.Timestamp.now(init.io, .awake);
    const stats = try campaign.run(std.heap.c_allocator, config);
    const elapsed_ns = begin.untilNow(init.io).raw.toNanoseconds();
    var output_buffer: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
    const output = &file_writer.interface;
    try output.print(
        "Forced-engine campaign...OK\n" ++
            "  Range patterns: {d}\n" ++
            "  Range cases: {d}\n" ++
            "  Capture patterns: {d}\n" ++
            "  Capture cases: {d}\n" ++
            "  Capture matches: {d}\n" ++
            "  OnePass eligible: {d}\n" ++
            "  OnePass ineligible: {d}\n" ++
            "  Elapsed: {d} ns\n",
        .{
            stats.range_patterns,
            stats.range_cases,
            stats.capture_patterns,
            stats.capture_cases,
            stats.capture_matches,
            stats.one_pass_eligible,
            stats.one_pass_ineligible,
            elapsed_ns,
        },
    );
    try output.flush();
}
