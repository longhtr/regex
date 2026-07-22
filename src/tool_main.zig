//! Build-selected entry point for private qualification executables.
//!
//! `build.zig` injects one `tool_campaign` name for each executable. Comptime
//! dispatch imports only that campaign's main module, keeping fuzzing,
//! forced-engine equivalence, concurrency stress, and possible-range generation
//! as separate finite processes with independent arguments and failure reports.
//!
//! This file contains no campaign policy; follow the selected `tools/*.zig`
//! module for its oracle and bounds. None of these entry points is reachable from
//! the public `root.zig` package.

const std = @import("std");
const campaign = @import("tool_campaign").name;

pub fn main(init: std.process.Init) !void {
    if (comptime std.mem.eql(u8, campaign, "fuzz"))
        return @import("tools/fuzz_campaign.zig").main(init);
    if (comptime std.mem.eql(u8, campaign, "equivalence"))
        return @import("tools/equivalence_batch.zig").main(init);
    if (comptime std.mem.eql(u8, campaign, "concurrency"))
        return @import("tools/concurrency_stress.zig").main(init);
    if (comptime std.mem.eql(u8, campaign, "possible-match"))
        return @import("tools/possible_match_campaign.zig").main(init);
    @compileError("unknown engineering campaign");
}
