//! # Report a bad runtime pattern
//!
//! `Regex.init` is concise for trusted pattern constants. Use `Regex.compile`
//! for user input or configuration: syntax and policy failures are returned as a
//! diagnostic value with a stable category and exact source-byte span.
//!
//! Allocation failure is still an error. The `.success` branch owns a Regex.
//!
//! Expected output begins with:
//!
//! ```text
//! diagnostic: missing_paren
//! start byte offset: 0
//! end byte offset (exclusive): 1
//! source text: (
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const pattern = "(unfinished";

    // `try` handles allocation failure. Pattern rejection remains in the union
    // so an application can report it without losing source information.
    const compiled = try regex.Regex.compile(std.heap.page_allocator, pattern, .{});

    switch (compiled) {
        .diagnostic => |diagnostic| std.debug.print(
            \\diagnostic: {s}
            \\start byte offset: {d}
            \\end byte offset (exclusive): {d}
            \\source text: {s}
            \\
        ,
            .{
                @tagName(diagnostic.code),
                diagnostic.start,
                diagnostic.end,
                pattern[diagnostic.start..diagnostic.end],
            },
        ),
        .success => |value| {
            // A success payload is an owner even on an unexpected branch.
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedDiagnostic;
        },
    }
}
