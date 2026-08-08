//! # Handle a result limit
//!
//! Bounded collection methods return `ResultLimitExceeded` rather than a silent
//! partial result. Choose a limit from application policy and handle rejection as
//! a distinct outcome from allocation failure.
//!
//! Expected output:
//!
//! ```text
//! result limit exceeded: input contains more than 2 matches
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var expression = try regex.Regex.init(allocator, "[a-z]+");
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();

    // Three matches cannot fit under the application policy of two. Check the
    // error union explicitly so limit rejection is not confused with OOM.
    if (matcher.findAll(allocator, "one two three", 2)) |value| {
        // A successful result would still be an owner and must be released.
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedResultLimit;
    } else |err| switch (err) {
        error.ResultLimitExceeded => std.debug.print(
            "result limit exceeded: input contains more than 2 matches\n",
            .{},
        ),
        error.OutOfMemory => return error.OutOfMemory,
    }
}
