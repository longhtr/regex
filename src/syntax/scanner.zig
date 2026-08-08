//! Stateless decoding primitives for pattern runes and numeric escapes.
//!
//! `decodeRune` is the lexical boundary between pattern bytes and engine runes.
//! Latin-1 maps exactly one byte. UTF-8 delegates structural decoding to Zig but
//! additionally rejects surrogate values, so successful output is always a
//! canonical Unicode scalar with its original byte width.
//!
//! `decodeEscape` parses the escape forms that denote one literal rune: control,
//! two-digit/braced hexadecimal, and bounded octal. It does not interpret regex
//! classes or assertions; the parser decides those forms before asking for a
//! literal escape. Numeric accumulation is checked and every failure records the
//! exact source-byte interval consumed or found invalid.
//!
//! Decimal repeat scanning, UTF-8 prevalidation, and scalar-aware cursor advance
//! are kept here because they share byte-decoding rules but no parser state.
//! Functions allocate nothing and never read beyond the supplied slice.

const std = @import("std");
const rune_range = @import("rune_range.zig");

/// Scanner byte interpretation and its two lexical failure categories.
pub const Encoding = enum { utf8, latin1 };
pub const FailureCode = enum { bad_escape, bad_utf8 };
/// Lexical failure with absolute half-open pattern byte bounds.
pub const Failure = struct { code: FailureCode, start: usize, end: usize };
/// Successful raw decode reports consumed width; successful escape decode reports
/// the absolute first unconsumed byte.
pub const Decoded = struct { rune: rune_range.Rune, width: usize };
pub const Escaped = struct { rune: rune_range.Rune, next: usize };

/// Value-or-lexical-failure union used instead of errors so exact spans survive.
pub fn RuneResult(comptime Value: type) type {
    return union(enum) { success: Value, failure: Failure };
}

/// Decodes one rune at `position` in the selected encoding. Success reports its
/// source width; failure never advances caller state.
pub fn decodeRune(
    pattern: []const u8,
    encoding: Encoding,
    position: usize,
) RuneResult(Decoded) {
    std.debug.assert(position < pattern.len);
    if (encoding == .latin1) return .{ .success = .{
        .rune = pattern[position],
        .width = 1,
    } };
    const width = std.unicode.utf8ByteSequenceLength(pattern[position]) catch
        return .{ .failure = .{ .code = .bad_utf8, .start = position, .end = position + 1 } };
    const end = position + width;
    if (end > pattern.len) return .{ .failure = .{
        .code = .bad_utf8,
        .start = position,
        .end = pattern.len,
    } };
    const rune = std.unicode.utf8Decode(pattern[position..end]) catch
        return .{ .failure = .{ .code = .bad_utf8, .start = position, .end = end } };
    return .{ .success = .{ .rune = rune, .width = width } };
}

/// Decodes one literal escape whose backslash is at `backslash`. The returned
/// `next` is the first unconsumed byte.
pub fn decodeEscape(
    pattern: []const u8,
    encoding: Encoding,
    start: usize,
    position: usize,
) RuneResult(Escaped) {
    std.debug.assert(position < pattern.len);
    const first = pattern[position];
    if (first >= 0x80) return switch (decodeRune(pattern, encoding, position)) {
        .success => |decoded| .{ .failure = .{
            .code = .bad_escape,
            .start = start,
            .end = position + decoded.width,
        } },
        .failure => |failure| .{ .failure = failure },
    };

    switch (first) {
        'n', 'r', 't', 'f', 'v', 'a' => return .{ .success = .{
            .rune = switch (first) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'f' => 0x0c,
                'v' => 0x0b,
                'a' => 0x07,
                else => unreachable,
            },
            .next = position + 1,
        } },
        '0'...'7' => {
            var value: u32 = first - '0';
            var next = position + 1;
            var digits: usize = 1;
            while (digits < 3 and next < pattern.len and
                pattern[next] >= '0' and pattern[next] <= '7')
            {
                value = value * 8 + pattern[next] - '0';
                next += 1;
                digits += 1;
            }
            if ((first != '0' and digits == 1) or value > maxRune(encoding))
                return makeFailure(.bad_escape, start, next);
            return .{ .success = .{ .rune = value, .next = next } };
        },
        'x' => return decodeHexEscape(pattern, encoding, start, position + 1),
        else => {
            if (std.ascii.isAlphanumeric(first))
                return makeFailure(.bad_escape, start, position + 1);
            return .{ .success = .{ .rune = first, .next = position + 1 } };
        },
    }
}

/// Returns the first invalid canonical UTF-8 scalar offset, including encoded
/// surrogate values that generic structural validation may accept.
pub fn invalidUtf8Offset(pattern: []const u8) ?usize {
    var offset: usize = 0;
    while (offset < pattern.len) {
        switch (decodeRune(pattern, .utf8, offset)) {
            .success => |decoded| offset += decoded.width,
            .failure => return offset,
        }
    }
    return null;
}

/// Parses consecutive decimal digits with checked u32 accumulation. On overflow
/// returns null after consuming the digit run.
pub fn parseDecimal(pattern: []const u8, cursor: *usize) ?u32 {
    const start = cursor.*;
    if (start + 1 < pattern.len and pattern[start] == '0' and
        std.ascii.isDigit(pattern[start + 1])) return null;
    var value: u64 = 0;
    while (cursor.* < pattern.len and std.ascii.isDigit(pattern[cursor.*])) : (cursor.* += 1) {
        value = value * 10 + (pattern[cursor.*] - '0');
        if (value > std.math.maxInt(u32)) return null;
    }
    if (cursor.* == start) return null;
    return @intCast(value);
}

/// Parses fixed `\\xNN` or braced `\\x{...}` syntax with checked accumulation,
/// validates the result against the selected encoding's scalar domain, and
/// returns diagnostic spans that include the malformed escape extent.
fn decodeHexEscape(
    pattern: []const u8,
    encoding: Encoding,
    start: usize,
    initial: usize,
) RuneResult(Escaped) {
    var position = initial;
    var value: u32 = 0;
    if (position < pattern.len and pattern[position] == '{') {
        position += 1;
        if (position == pattern.len) return makeFailure(.bad_utf8, start, position);
        const digits_start = position;
        while (position < pattern.len and isHex(pattern[position])) : (position += 1) {
            value = std.math.mul(u32, value, 16) catch
                return makeFailure(.bad_escape, start, position + 1);
            value = std.math.add(u32, value, hexValue(pattern[position])) catch
                return makeFailure(.bad_escape, start, position + 1);
        }
        if (position == digits_start or position == pattern.len or pattern[position] != '}')
            return makeFailure(.bad_escape, start, advanceRunes(pattern, encoding, position, 1));
        position += 1;
    } else {
        if (position + 2 > pattern.len or !isHex(pattern[position]) or
            !isHex(pattern[position + 1]))
            return makeFailure(.bad_escape, start, advanceRunes(pattern, encoding, position, 2));
        value = hexValue(pattern[position]) * 16 + hexValue(pattern[position + 1]);
        position += 2;
    }
    if (!validRune(value, encoding)) return makeFailure(.bad_escape, start, position);
    return .{ .success = .{ .rune = value, .next = position } };
}

/// Advances by at most `count` encoding units; malformed UTF-8 advances one byte
/// so diagnostics/iteration always make progress.
pub fn advanceRunes(pattern: []const u8, encoding: Encoding, start: usize, count: usize) usize {
    var position = start;
    var remaining = count;
    while (remaining != 0 and position < pattern.len) : (remaining -= 1) {
        if (encoding == .latin1 or pattern[position] < 0x80) {
            position += 1;
        } else {
            position += std.unicode.utf8ByteSequenceLength(pattern[position]) catch 1;
        }
    }
    return @min(position, pattern.len);
}

fn validRune(value: u32, encoding: Encoding) bool {
    return if (encoding == .latin1)
        value <= 0xff
    else
        value <= rune_range.max_rune and !(value >= 0xd800 and value <= 0xdfff);
}

fn maxRune(encoding: Encoding) u32 {
    return if (encoding == .latin1) 0xff else rune_range.max_rune;
}

fn makeFailure(code: FailureCode, start: usize, end: usize) RuneResult(Escaped) {
    return .{ .failure = .{ .code = code, .start = start, .end = end } };
}

fn isHex(byte: u8) bool {
    return std.ascii.isDigit(byte) or
        (byte >= 'a' and byte <= 'f') or
        (byte >= 'A' and byte <= 'F');
}

fn hexValue(byte: u8) u32 {
    if (std.ascii.isDigit(byte)) return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return byte - 'A' + 10;
}

const testing = std.testing;

test "Scanner preserves escape values and rejects non-scalar UTF-8" {
    try testing.expectEqual(
        Escaped{ .rune = 0xff, .next = 4 },
        decodeEscape("\\xFF", .utf8, 0, 1).success,
    );
    const bad = decodeEscape("x{", .utf8, 0, 0).failure;
    try testing.expectEqual(FailureCode.bad_utf8, bad.code);
    try testing.expectEqual(@as(usize, 2), bad.end);
    try testing.expect(decodeRune("\xed\xa0\x80", .utf8, 0) == .failure);
    try testing.expect(decodeEscape("x{D800}", .utf8, 0, 0) == .failure);
    try testing.expectEqual(@as(?usize, 0), invalidUtf8Offset("\xff"));
}
