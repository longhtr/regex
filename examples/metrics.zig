//! # Observe requested memory
//!
//! Regex compile metrics describe immutable initial compilation. Matcher metrics
//! describe matcher-local live and peak scratch after requests. Values are
//! allocator-requested bytes, not process RSS or allocator usable size.
//!
//! Metrics are observations. They do not reveal or select the physical engine.
//!
//! Expected output shape (the byte counts depend on the pattern):
//!
//! ```text
//! compile retained bytes: <number>
//! compile peak bytes: <number>
//! matcher live bytes: <number>
//! matcher peak bytes: <number>
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var expression = try regex.Regex.init(allocator, "[a-z]+[0-9]+");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();
    // Run a request first so lazily created Matcher scratch is reflected.
    _ = matcher.find("item42");

    // The snapshots borrow no storage and remain simple observation values.
    const compiled = expression.compileMetrics();
    const scratch = matcher.metrics();
    std.debug.print(
        \\compile retained bytes: {d}
        \\compile peak bytes: {d}
        \\matcher live bytes: {d}
        \\matcher peak bytes: {d}
        \\
    , .{
        compiled.requested_retained_bytes,
        compiled.requested_peak_bytes,
        scratch.requested_live_bytes,
        scratch.requested_peak_bytes,
    });
}
