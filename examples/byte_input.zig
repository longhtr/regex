//! # Match arbitrary bytes
//!
//! Latin-1 semantics map every pattern and input byte to one scalar. Combined
//! with literal mode, this matches bytes that are invalid UTF-8, NUL, and regex
//! metacharacters without interpretation.
//!
//! Use this mode for byte-oriented protocols and storage, not ordinary UTF-8
//! text.
//!
//! Expected output:
//!
//! ```text
//! entire byte sequence matched: true
//! ```

const std = @import("std");
const regex = @import("regex");

pub fn main() !void {
    const bytes = [_]u8{ 0xff, '+', 0x00 };

    // Latin-1 accepts every byte; literal mode prevents '+' from becoming
    // repetition syntax and treats NUL as ordinary data.
    var expression = try regex.Regex.initWithOptions(std.heap.page_allocator, &bytes, .{
        .encoding = .latin1,
        .literal = true,
    });
    defer expression.deinit();
    var matcher = try regex.Matcher.init(std.heap.page_allocator, &expression);
    defer matcher.deinit();

    std.debug.print(
        "entire byte sequence matched: {}\n",
        .{matcher.fullMatch(&bytes)},
    );
}
