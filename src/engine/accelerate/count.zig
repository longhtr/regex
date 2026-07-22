//! Direct existence and non-overlapping count for proven byte-repeat languages.
//!
//! Publication may describe one of two exact forms: a fixed required prefix
//! followed by a bounded/unbounded ASCII byte-class run, or an initial ASCII
//! class followed by another run. Encoded inclusive ranges are expanded once to
//! a 256-byte flag table stored in Matcher.
//!
//! The scanner uses literal search for prefixes, then consumes maximal class runs
//! and checks min/max bounds plus optional ASCII word boundaries. Count advances
//! to the end of each accepted match, reproducing ordinary non-overlapping
//! iteration. Existence stops at the first accepted candidate.
//!
//! Every entry point validates that the complete plan shape is present. Returning
//! null means “not this language,” not “no match,” and Matcher delegates to
//! general execution. Plans contain ASCII byte predicates only; this module never
//! approximates UTF-8 scalar, folding, assertion, or capture semantics.

const std = @import("std");
const program = @import("../../program/program.zig");
const prefix = @import("../../literal/search.zig");

const repeated_bit: u8 = 1 << 0;
const repeat_initial_bit: u8 = 1 << 1;

/// Shared loop output policy: early boolean completion or full non-overlapping
/// count accumulation.
const ScanMode = enum { exists, count };

/// Expands all active repeated/initial encoded ranges into two bit flags per byte
/// once at Matcher initialization.
pub fn buildByteFlags(compiled: *const program.Program) [256]u8 {
    var flags = [_]u8{0} ** 256;
    for (compiled.plans.repeat_byte_ranges[0..compiled.plans.repeat_byte_range_count]) |encoded| {
        const lo: u8 = @truncate(encoded);
        const hi: u8 = @truncate(encoded >> 8);
        var byte: u16 = lo;
        while (byte <= hi) : (byte += 1) flags[byte] |= repeated_bit;
    }
    for (compiled.plans.repeat_byte_initial_ranges[0..compiled.plans.repeat_byte_initial_range_count]) |encoded| {
        const lo: u8 = @truncate(encoded);
        const hi: u8 = @truncate(encoded >> 8);
        var byte: u16 = lo;
        while (byte <= hi) : (byte += 1) flags[byte] |= repeat_initial_bit;
    }
    return flags;
}

/// Returns an exact specialized count, or null when ordinary iteration owns
/// this language.
pub fn existsExact(
    compiled: *const program.Program,
    byte_flags: *const [256]u8,
    input: []const u8,
) ?bool {
    if (compiled.prefix_complete and !compiled.prefix_fold_ascii)
        return prefix.findExact(input, 0, input.len, compiled.prefix) != null;
    if (compiled.prefix_complete) return scanLiteral(.exists, compiled, input) != 0;
    if (compiled.plans.repeat_byte_range_count == 0) return null;
    if (compiled.plans.repeat_byte_initial_range_count != 0)
        return scanLeadingByteRepeat(.exists, compiled, byte_flags, input) != 0;
    if (compiled.plans.repeat_byte_after_prefix)
        return scanPrefixRepeat(.exists, compiled, byte_flags, input) != 0;
    return scanRepeatedBytes(.exists, compiled, byte_flags, input) != 0;
}

/// Returns an exact non-overlapping count for a complete admitted shape, or null
/// when ordinary Matcher iteration owns the language.
pub fn exact(
    compiled: *const program.Program,
    byte_flags: *const [256]u8,
    input: []const u8,
) ?usize {
    if (compiled.prefix_complete) return scanLiteral(.count, compiled, input);
    if (compiled.plans.repeat_byte_range_count == 0) return null;
    if (compiled.plans.repeat_byte_initial_range_count != 0)
        return scanLeadingByteRepeat(.count, compiled, byte_flags, input);
    if (compiled.plans.repeat_byte_after_prefix)
        return scanPrefixRepeat(.count, compiled, byte_flags, input);
    return scanRepeatedBytes(.count, compiled, byte_flags, input);
}

/// Counts non-overlapping occurrences of a language proved to be exactly one
/// nonempty literal. Advancing by literal width reproduces iterator progress
/// without constructing automaton state.
fn scanLiteral(
    comptime mode: ScanMode,
    compiled: *const program.Program,
    input: []const u8,
) usize {
    var total: usize = 0;
    var position: usize = 0;
    while (position < input.len) {
        const found = (if (compiled.prefix_fold_ascii)
            prefix.findFoldedAscii(input, position, input.len, compiled.prefix)
        else
            prefix.find(input, position, input.len, compiled.prefix)) orelse break;
        total += 1;
        if (mode == .exists) return total;
        position = found + compiled.prefix.len;
    }
    return total;
}

fn isWord(byte: ?u8) bool {
    const value = byte orelse return false;
    return std.ascii.isAlphanumeric(value) or value == '_';
}

/// Searches initial-class bytes, consumes the adjacent repeated class under
/// bounds, and counts accepted maximal matches.
fn scanLeadingByteRepeat(
    comptime mode: ScanMode,
    compiled: *const program.Program,
    byte_flags: *const [256]u8,
    input: []const u8,
) usize {
    const minimum: usize = compiled.plans.repeat_byte_min;
    const maximum: usize = compiled.plans.repeat_byte_max;
    var total: usize = 0;
    var position: usize = 0;
    while (position < input.len) {
        while (position < input.len and byte_flags[input[position]] & repeat_initial_bit == 0)
            position += 1;
        if (position == input.len) break;
        position += 1;
        var repeated: usize = 0;
        while (position < input.len and byte_flags[input[position]] & repeated_bit != 0 and
            (maximum == 0 or repeated < maximum))
        {
            position += 1;
            repeated += 1;
            if (mode == .exists and repeated >= minimum) return 1;
        }
        if (repeated >= minimum) {
            total += 1;
            if (mode == .exists) return total;
        }
    }
    return total;
}

/// Scans maximal repeated-class runs, applies bounds/boundaries, and advances
/// accepted finite chunks according to ordinary non-overlap semantics.
fn scanRepeatedBytes(
    comptime mode: ScanMode,
    compiled: *const program.Program,
    byte_flags: *const [256]u8,
    input: []const u8,
) usize {
    const minimum: usize = compiled.plans.repeat_byte_min;
    const maximum: usize = compiled.plans.repeat_byte_max;
    var total: usize = 0;
    var position: usize = 0;
    while (position < input.len) {
        while (position < input.len and byte_flags[input[position]] & repeated_bit == 0)
            position += 1;
        const start = position;
        if (mode == .exists and !compiled.plans.repeat_byte_right_word_boundary) {
            var candidate_end = start;
            while (candidate_end - start < minimum and candidate_end < input.len and
                byte_flags[input[candidate_end]] & repeated_bit != 0)
                candidate_end += 1;
            if (candidate_end - start >= minimum and
                (!compiled.plans.repeat_byte_left_word_boundary or
                    isWord(if (start == 0) null else input[start - 1]) != isWord(input[start])))
                return 1;
        }
        while (position < input.len and byte_flags[input[position]] & repeated_bit != 0)
            position += 1;
        const run_len = position - start;
        if (run_len < minimum) continue;
        if (maximum == 0) {
            if (repeatBoundariesHold(compiled, input, start, position)) {
                total += 1;
                if (mode == .exists) return total;
            }
        } else {
            var match_start = start;
            while (position - match_start >= minimum) {
                const match_end = match_start + @min(maximum, position - match_start);
                if (repeatBoundariesHold(compiled, input, match_start, match_end)) {
                    total += 1;
                    if (mode == .exists) return total;
                }
                match_start = match_end;
            }
        }
    }
    return total;
}

/// Checks optional ASCII word boundaries around an already validated nonempty
/// repeat candidate using complete-input neighbors.
fn repeatBoundariesHold(
    compiled: *const program.Program,
    input: []const u8,
    start: usize,
    end: usize,
) bool {
    if (compiled.plans.repeat_byte_left_word_boundary and
        isWord(if (start == 0) null else input[start - 1]) == isWord(input[start])) return false;
    if (compiled.plans.repeat_byte_right_word_boundary and
        isWord(input[end - 1]) == isWord(if (end == input.len) null else input[end])) return false;
    return true;
}

/// Finds exact required-prefix candidates, then validates the adjacent repeated
/// run described by the complete plan.
fn scanPrefixRepeat(
    comptime mode: ScanMode,
    compiled: *const program.Program,
    byte_flags: *const [256]u8,
    input: []const u8,
) usize {
    const minimum: usize = compiled.plans.repeat_byte_min;
    const maximum: usize = compiled.plans.repeat_byte_max;
    var total: usize = 0;
    var position: usize = 0;
    while (position < input.len) {
        const found = prefix.find(input, position, input.len, compiled.prefix) orelse break;
        const repeat_start = found + compiled.prefix.len;
        var repeat_end = repeat_start;
        if (mode == .exists) {
            while (repeat_end - repeat_start < minimum and repeat_end < input.len and
                byte_flags[input[repeat_end]] & repeated_bit != 0)
                repeat_end += 1;
            if (repeat_end - repeat_start >= minimum) return 1;
        }
        while (repeat_end < input.len and byte_flags[input[repeat_end]] & repeated_bit != 0)
            repeat_end += 1;
        const run_len = repeat_end - repeat_start;
        if (run_len < minimum) {
            position = found + 1;
            continue;
        }
        total += 1;
        if (mode == .exists) return total;
        position = repeat_start + if (maximum == 0) run_len else @min(run_len, maximum);
    }
    return total;
}
