//! # Set matching policy at compilation
//!
//! Compile options define semantics, not engine selection. Both match kinds
//! choose the leftmost start; `.longest` chooses the farthest valid end.
//! `case_sensitive = false` enables Unicode simple folding.
//!
//! Expected output (`a|aa` would select `a` under the default `.first` policy):
//!
//! ```text
//! matched text: AA
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const input = "AA";

    // Options are fixed in the compiled Regex and apply to every Matcher.
    var expression = try regex.Regex.initWithOptions(std.heap.page_allocator, "a|aa", .{
        .case_sensitive = false,
        .match_kind = .longest,
    });
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    // Folding permits uppercase input; `.longest` selects both input bytes.
    const found = matcher.find(input) orelse return error.ExpectedMatch;
    std.debug.print("matched text: {s}\n", .{
        found.slice(input) orelse return error.InvalidMatchBounds,
    });
}
