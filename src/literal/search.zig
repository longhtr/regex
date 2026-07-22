//! Allocation-free exact and folded-ASCII literal search primitives.
//!
//! All functions search candidate start offsets in `[start,end)` without reading
//! beyond the supplied bound. One-byte needles use scalar search. Longer sparse
//! needles find the first byte and verify candidates. Dense first-byte cases use
//! a first/last pair filter so repeated prefixes do not trigger full comparison
//! at every position. Long non-ASCII needles use the standard library's
//! Boyer-Moore-Horspool byte search because UTF-8 leading bytes are naturally
//! dense. Vector paths compare 16 candidate bytes at once and fall back to scalar
//! tails with identical semantics.
//!
//! Folded search is deliberately ASCII-only and lowercases comparisons in
//! registers; publication emits such a prefix only when Unicode/encoding analysis
//! proved that this is conservative. Search returns candidate offsets, not regex
//! acceptance, except when Matcher has a proof that the literal/one-byte-tail is
//! the complete language.
//!
//! The implementation allocates nothing and is shared by NFA startup, DFA
//! startup, Set prefix skipping, direct count plans, and qualification tests.

const std = @import("std");

/// Returns the first candidate whose bytes equal the lowercase ASCII needle under
/// ASCII case folding, restricted to legal starts in `[start,end)`.
pub fn findFoldedAscii(
    input: []const u8,
    start: usize,
    end: usize,
    needle_lower: []const u8,
) ?usize {
    std.debug.assert(start <= end and end <= input.len and needle_lower.len != 0);
    var position = start;
    var use_pair = false;
    const first = needle_lower[0];
    while (position < end) {
        if (needle_lower.len > end - position) return null;
        const candidate_end = end - needle_lower.len + 1;
        const found = (if (use_pair and needle_lower.len >= 2)
            findFoldedPair(
                input,
                position,
                candidate_end,
                first,
                needle_lower[needle_lower.len - 1],
                needle_lower.len - 1,
            )
        else
            findFoldedByte(input, position, candidate_end, first)) orelse return null;
        var matches = true;
        for (needle_lower, input[found..][0..needle_lower.len]) |wanted, actual| {
            if (std.ascii.toLower(actual) != wanted) {
                matches = false;
                break;
            }
        }
        if (matches) return found;
        use_pair = true;
        position = found + 1;
    }
    return null;
}

/// Returns the first exact needle occurrence whose start lies in `[start,end)`;
/// empty needles resolve to `start` after bounds normalization.
pub fn find(
    input: []const u8,
    start: usize,
    end: usize,
    needle: []const u8,
) ?usize {
    std.debug.assert(start <= end and end <= input.len and needle.len != 0);
    if (needle.len > 4 and needle[0] >= 0x80 and end - start >= 52)
        return std.mem.indexOfPos(u8, input[0..end], start, needle);
    var position = start;
    var use_pair = false;
    while (position < end) {
        if (needle.len > end - position) return null;
        const candidate_end = end - needle.len + 1;
        const candidate = if (use_pair and needle.len >= 2)
            findPair(
                input,
                position,
                candidate_end,
                needle[0],
                needle[needle.len - 1],
                needle.len - 1,
            )
        else
            findByte(input, position, candidate_end, needle[0]);
        const found = candidate orelse return null;
        if (std.mem.eql(u8, input[found..][0..needle.len], needle)) return found;
        use_pair = true;
        position = found + 1;
    }
    return null;
}

/// Finds a complete literal for boolean search. Sparse first-byte candidates
/// use one input stream; dense rejection switches to the first/last-byte pair
/// filter so verification cost remains bounded.
pub fn findExact(
    input: []const u8,
    start: usize,
    end: usize,
    needle: []const u8,
) ?usize {
    std.debug.assert(start <= end and end <= input.len and needle.len != 0);
    if (needle.len == 1) return findByte(input, start, end, needle[0]);
    if (needle.len > end - start) return null;
    if (needle.len > 4 and needle[0] >= 0x80 and end - start >= 52)
        return std.mem.indexOfPos(u8, input[0..end], start, needle);

    const candidate_end = end - needle.len + 1;
    const first = needle[0];
    const wanted: SearchVector = @splat(first);
    var position = start;
    while (position + 128 <= candidate_end) : (position += 128) {
        const candidates = byteMask128(input, position, wanted);
        if (!@reduce(.Or, candidates)) continue;

        var rejected: usize = 0;
        for (position..position + 128) |candidate| {
            if (input[candidate] != first) continue;
            if (std.mem.eql(u8, input[candidate..][0..needle.len], needle)) return candidate;
            rejected += 1;
        }
        // A dense first byte makes scalar verification expensive. The pair
        // filter adds the last byte only after density proves the extra load is
        // worthwhile; sparse rejection remains a single-stream scan.
        if (rejected >= dense_candidates_per_block) return findVerifiedPair(
            input,
            position + 128,
            candidate_end,
            needle,
        );
    }
    while (position < candidate_end) : (position += 1) {
        if (input[position] == first and
            std.mem.eql(u8, input[position..][0..needle.len], needle)) return position;
    }
    return null;
}

// The 16-byte portable vector is one source algorithm on every target. It is
// not selected from local CPU identity and has a scalar tail for all targets.
const SearchVector = @Vector(16, u8);
const SearchMask = @Vector(16, bool);
const dense_candidates_per_block = 8;

inline fn byteBlockMask(
    input: []const u8,
    start: usize,
    wanted: SearchVector,
) SearchMask {
    return input[start..][0..16].* == wanted;
}

inline fn byteMask64(
    input: []const u8,
    start: usize,
    wanted: SearchVector,
) SearchMask {
    return (byteBlockMask(input, start, wanted) |
        byteBlockMask(input, start + 16, wanted)) |
        (byteBlockMask(input, start + 32, wanted) |
            byteBlockMask(input, start + 48, wanted));
}

inline fn byteMask128(
    input: []const u8,
    start: usize,
    wanted: SearchVector,
) SearchMask {
    return byteMask64(input, start, wanted) |
        byteMask64(input, start + 64, wanted);
}

inline fn pairBlockMask(
    input: []const u8,
    start: usize,
    offset: usize,
    first: SearchVector,
    second: SearchVector,
) SearchMask {
    const a: SearchVector = input[start..][0..16].*;
    const b: SearchVector = input[start + offset ..][0..16].*;
    return (a == first) & (b == second);
}

inline fn pairMask64(
    input: []const u8,
    start: usize,
    offset: usize,
    first: SearchVector,
    second: SearchVector,
) SearchMask {
    return (pairBlockMask(input, start, offset, first, second) |
        pairBlockMask(input, start + 16, offset, first, second)) |
        (pairBlockMask(input, start + 32, offset, first, second) |
            pairBlockMask(input, start + 48, offset, first, second));
}

inline fn pairMask128(
    input: []const u8,
    start: usize,
    offset: usize,
    first: SearchVector,
    second: SearchVector,
) SearchMask {
    return pairMask64(input, start, offset, first, second) |
        pairMask64(input, start + 64, offset, first, second);
}

inline fn foldedByteBlockMask(
    input: []const u8,
    start: usize,
    lower: SearchVector,
    upper: SearchVector,
) SearchMask {
    const bytes: SearchVector = input[start..][0..16].*;
    return (bytes == lower) | (bytes == upper);
}

inline fn foldedByteMask64(
    input: []const u8,
    start: usize,
    lower: SearchVector,
    upper: SearchVector,
) SearchMask {
    return (foldedByteBlockMask(input, start, lower, upper) |
        foldedByteBlockMask(input, start + 16, lower, upper)) |
        (foldedByteBlockMask(input, start + 32, lower, upper) |
            foldedByteBlockMask(input, start + 48, lower, upper));
}

/// Broadcast lowercase/uppercase values for vectorized folded first/last pair
/// candidate filtering.
const FoldedPairVectors = struct {
    first_lower: SearchVector,
    first_upper: SearchVector,
    second_lower: SearchVector,
    second_upper: SearchVector,
};

inline fn foldedPairBlockMask(
    input: []const u8,
    start: usize,
    offset: usize,
    vectors: FoldedPairVectors,
) SearchMask {
    const first: SearchVector = input[start..][0..16].*;
    const second: SearchVector = input[start + offset ..][0..16].*;
    return ((first == vectors.first_lower) | (first == vectors.first_upper)) &
        ((second == vectors.second_lower) | (second == vectors.second_upper));
}

inline fn foldedPairMask64(
    input: []const u8,
    start: usize,
    offset: usize,
    vectors: FoldedPairVectors,
) SearchMask {
    return (foldedPairBlockMask(input, start, offset, vectors) |
        foldedPairBlockMask(input, start + 16, offset, vectors)) |
        (foldedPairBlockMask(input, start + 32, offset, vectors) |
            foldedPairBlockMask(input, start + 48, offset, vectors));
}

/// Finds the first candidate whose two offset bytes equal either ASCII case.
/// Sixty-four candidate starts are rejected in parallel, but a positive block is
/// rescanned in order so vectorization cannot change the returned leftmost index.
fn findFoldedPair(
    input: []const u8,
    start: usize,
    end: usize,
    first_lower: u8,
    second_lower: u8,
    offset: usize,
) ?usize {
    const first_upper = std.ascii.toUpper(first_lower);
    const second_upper = std.ascii.toUpper(second_lower);
    const vectors = FoldedPairVectors{
        .first_lower = @splat(first_lower),
        .first_upper = @splat(first_upper),
        .second_lower = @splat(second_lower),
        .second_upper = @splat(second_upper),
    };
    var index = start;
    while (index + 64 <= end) : (index += 64) {
        const matches = foldedPairMask64(input, index, offset, vectors);
        if (@reduce(.Or, matches)) {
            for (index..index + 64) |candidate| {
                const a = input[candidate];
                const b = input[candidate + offset];
                if ((a == first_lower or a == first_upper) and
                    (b == second_lower or b == second_upper)) return candidate;
            }
        }
    }
    while (index < end) : (index += 1) {
        const a = input[index];
        const b = input[index + offset];
        if ((a == first_lower or a == first_upper) and
            (b == second_lower or b == second_upper)) return index;
    }
    return null;
}

/// Uses a sparse pair filter to find candidates, then verifies the complete
/// needle before returning an offset.
fn findVerifiedPair(
    input: []const u8,
    start: usize,
    end: usize,
    needle: []const u8,
) ?usize {
    var position = start;
    while (position < end) {
        const candidate = findPair(
            input,
            position,
            end,
            needle[0],
            needle[needle.len - 1],
            needle.len - 1,
        ) orelse return null;
        if (std.mem.eql(u8, input[candidate..][0..needle.len], needle)) return candidate;
        position = candidate + 1;
    }
    return null;
}

/// Vector/scalar first-and-offset-byte candidate filter without full-needle
/// verification; callers use it for two-byte needles or verify longer needles.
fn findPair(
    input: []const u8,
    start: usize,
    end: usize,
    first: u8,
    second: u8,
    offset: usize,
) ?usize {
    const first_vector: SearchVector = @splat(first);
    const second_vector: SearchVector = @splat(second);
    var index = start;
    while (index + 128 <= end) : (index += 128) {
        if (@reduce(.Or, pairMask128(
            input,
            index,
            offset,
            first_vector,
            second_vector,
        ))) {
            for (index..index + 128) |candidate|
                if (input[candidate] == first and input[candidate + offset] == second)
                    return candidate;
        }
    }
    while (index + 64 <= end) : (index += 64) {
        if (@reduce(.Or, pairMask64(
            input,
            index,
            offset,
            first_vector,
            second_vector,
        ))) {
            for (index..index + 64) |candidate|
                if (input[candidate] == first and input[candidate + offset] == second)
                    return candidate;
        }
    }
    while (index < end) : (index += 1)
        if (input[index] == first and input[index + offset] == second) return index;
    return null;
}

fn findFoldedByte(input: []const u8, start: usize, end: usize, lower: u8) ?usize {
    const upper = std.ascii.toUpper(lower);
    const lower_vector: SearchVector = @splat(lower);
    const upper_vector: SearchVector = @splat(upper);
    var index = start;
    while (index + 64 <= end) : (index += 64) {
        if (@reduce(.Or, foldedByteMask64(input, index, lower_vector, upper_vector))) {
            var scalar = index;
            while (scalar < index + 64) : (scalar += 1)
                if (input[scalar] == lower or input[scalar] == upper) return scalar;
        }
    }
    while (index < end) : (index += 1)
        if (input[index] == lower or input[index] == upper) return index;
    return null;
}

fn findByte(input: []const u8, start: usize, end: usize, byte: u8) ?usize {
    const wanted: SearchVector = @splat(byte);
    var index = start;
    while (index + 64 <= end) : (index += 64) {
        if (@reduce(.Or, byteMask64(input, index, wanted))) {
            return std.mem.findScalarPos(u8, input[0 .. index + 64], index, byte);
        }
    }
    return std.mem.findScalarPos(u8, input[0..end], index, byte);
}

const testing = std.testing;

test "Prefix finder observes search bounds" {
    try testing.expectEqual(@as(?usize, 2), find("xxneedleyy", 0, 10, "needle"));
    try testing.expectEqual(@as(?usize, null), find("xxneedleyy", 3, 10, "needle"));
    try testing.expectEqual(@as(?usize, null), find("xxneedleyy", 0, 7, "needle"));
    try testing.expectEqual(@as(?usize, 2), findFoldedAscii("xxNeEdLEyy", 0, 10, "needle"));
    try testing.expectEqual(@as(?usize, null), findFoldedAscii("xxneedlex", 3, 9, "needle"));
    try testing.expectEqual(@as(?usize, 8), findExact("nxxxxxxxneedle", 0, 14, "needle"));
    try testing.expectEqual(@as(?usize, null), findExact("nxxxxxxxneedle", 0, 13, "needle"));
    try testing.expectEqual(@as(?usize, 3), findExact("aaab", 0, 4, "b"));
}

test "Exact finder verifies dense pair candidates" {
    var input: [387]u8 = undefined;
    for (0..129) |index| @memcpy(input[index * 3 ..][0..3], "axc");
    try testing.expectEqual(@as(?usize, null), findExact(&input, 0, input.len, "abc"));
    @memcpy(input[input.len - 3 ..], "abc");
    try testing.expectEqual(@as(?usize, input.len - 3), findExact(&input, 0, input.len, "abc"));
}

test "Exact finder agrees with standard search across generated ranges" {
    var input: [521]u8 = undefined;
    var needle: [17]u8 = undefined;
    for (0..512) |case_index| {
        var state: u64 = 0x9e3779b97f4a7c15 ^ case_index;
        const input_len = 128 + case_index % (input.len - 127);
        const needle_len = 1 + case_index % needle.len;
        for (input[0..input_len]) |*byte| {
            state = state *% 0xd1342543de82ef95 +% 0x94d049bb133111eb;
            byte.* = if (case_index & 1 == 0)
                'a' + @as(u8, @truncate(state)) % 4
            else
                @truncate(state >> 24);
        }
        for (needle[0..needle_len]) |*byte| {
            state = state *% 0xd1342543de82ef95 +% 0x94d049bb133111eb;
            byte.* = if (case_index & 2 == 0)
                'a' + @as(u8, @truncate(state)) % 4
            else
                @truncate(state >> 32);
        }

        const start = case_index % 17;
        const end = input_len - case_index % 13;
        if (case_index % 3 == 0 and needle_len <= end - start) {
            const insertion = start + (end - start - needle_len) / 2;
            @memcpy(input[insertion..][0..needle_len], needle[0..needle_len]);
        }
        const relative = std.mem.indexOf(u8, input[start..end], needle[0..needle_len]);
        const expected = if (relative) |position| start + position else null;
        try testing.expectEqual(expected, findExact(
            &input,
            start,
            end,
            needle[0..needle_len],
        ));
    }
}
