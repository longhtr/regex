//! # Prefilter independent Regexes, then verify them
//!
//! Filtered keeps independent Regexes behind conservative required-atom
//! formulas. Candidate methods may return false positives. Match methods verify
//! every candidate exactly and therefore return only real matches.
//!
//! The `*Scanned` methods run the built-in atom scanner. `min_atom_len` controls
//! which proved literals are worth publishing.
//!
//! Expected output demonstrates one false-positive candidate:
//!
//! ```text
//! candidate pattern name: error
//! candidate pattern name: timeout
//! verified pattern name: timeout
//! ```

const std = @import("std");
const regex = @import("regex");

const names = [_][]const u8{ "error", "timeout" };
const patterns = [_][]const u8{ "error:[0-9]+", "timeout" };

fn add(builder: *regex.Filtered.Builder, pattern: []const u8) !void {
    switch (try builder.add(pattern)) {
        .success => {},
        .diagnostic => |diagnostic| {
            std.debug.print(
                "pattern diagnostic: {s}; start byte offset: {d}; " ++
                    "end byte offset (exclusive): {d}\n",
                .{ @tagName(diagnostic.code), diagnostic.start, diagnostic.end },
            );
            return error.InvalidPattern;
        },
    }
}

// Translate insertion IDs at the presentation boundary.
fn printIds(label: []const u8, ids: []const u32) void {
    for (ids) |id| {
        std.debug.print("{s}: {s}\n", .{ label, names[@intCast(id)] });
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // Ignore proved atoms shorter than three bytes: they are usually too common
    // to repay the cost of publishing and scanning them.
    var builder = regex.Filtered.Builder.init(allocator, .{}, 3);
    defer builder.deinit();
    for (patterns) |pattern| try add(&builder, pattern);

    var filtered = try builder.compile();
    defer filtered.deinit();
    var matcher = try filtered.matcher(allocator);
    defer matcher.deinit();

    const input = "error:none timeout=30";

    // The literal "error:" makes rule 0 a candidate even though its required
    // digits are absent. Candidate APIs intentionally expose that approximation.
    var candidates = try matcher.allCandidatesScanned(allocator, input, names.len);
    defer candidates.deinit();
    printIds("candidate pattern name", candidates.values());

    // Match APIs run exact Regex verification and remove the false positive.
    var matches = try matcher.allMatchesScanned(allocator, input, names.len);
    defer matches.deinit();
    printIds("verified pattern name", matches.values());
}
