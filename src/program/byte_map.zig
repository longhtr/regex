//! Compile-time partition of input bytes by predicate equivalence.
//!
//! Two bytes may share a DFA class when every reachable `byte_range` instruction
//! gives the same yes/no answer for both. Each range changes truth only at `lo`
//! and immediately after `hi`; marking those boundaries and prefix-numbering the
//! 256-byte domain therefore constructs a sound contiguous partition in
//! `O(instructions + 256)` time.
//!
//! ASCII-folding ranges contribute the corresponding uppercase boundaries as
//! well as their stored lowercase interval. Non-consuming instructions do not
//! affect the partition. The result is a 256-entry byte-to-class map plus a class
//! count, and it is the only allocation retained from this analysis.
//!
//! Classes are conservative rather than globally minimal: disjoint intervals
//! with coincidentally equal future behavior are not merged. Soundness is what
//! matters—the DFA can evaluate one representative per class and cache the same
//! transition for every member.

const std = @import("std");
const program = @import("program.zig");

/// Published mapping for all 256 bytes and the number of dense class IDs.
pub const Partition = struct {
    map: []u8,
    count: u16,
};

/// Temporary inclusive intervals used while marking predicate truth boundaries.
const ByteRange = struct { lo: u8, hi: u8 };
/// One ordinary interval or lowercase plus uppercase intervals for ASCII folding.
const PredicateRanges = struct { values: [2]ByteRange, len: u2 };

/// Marks every predicate truth boundary, prefix-numbers resulting intervals,
/// and returns an allocated 256-byte map. Empty/non-consuming graphs form one
/// class.
pub fn build(
    allocator: std.mem.Allocator,
    instructions: []const program.GraphInstruction,
) std.mem.Allocator.Error!Partition {
    var boundaries: [257]bool = @splat(false);
    boundaries[0] = true;
    for (instructions) |instruction|
        if (instruction.opcode() == .byte_range)
            markPredicateBoundaries(&boundaries, instruction);

    const map = try allocator.alloc(u8, 256);
    var class: u16 = 0;
    for (0..256) |byte| {
        if (byte != 0 and boundaries[byte]) class += 1;
        map[byte] = @intCast(class);
    }
    return .{ .map = map, .count = class + 1 };
}

fn markPredicateBoundaries(boundaries: *[257]bool, instruction: program.GraphInstruction) void {
    const ranges = predicateRanges(instruction);
    for (ranges.values[0..ranges.len]) |range| {
        boundaries[range.lo] = true;
        boundaries[@as(u16, range.hi) + 1] = true;
    }
}

/// Expands a byte predicate into one or two accepted intervals; the second is
/// the uppercase counterpart of an ASCII-folding lowercase range.
fn predicateRanges(instruction: program.GraphInstruction) PredicateRanges {
    var result: PredicateRanges = .{
        .values = .{
            .{ .lo = instruction.byteLo(), .hi = instruction.byteHi() },
            undefined,
        },
        .len = 1,
    };
    if (!instruction.foldsAscii()) return result;

    const lower_lo = @max(instruction.byteLo(), 'a');
    const lower_hi = @min(instruction.byteHi(), 'z');
    if (lower_lo > lower_hi) return result;
    const folded = ByteRange{
        .lo = lower_lo - ('a' - 'A'),
        .hi = lower_hi - ('a' - 'A'),
    };
    const first = &result.values[0];
    if (@as(u16, folded.hi) + 1 >= first.lo and @as(u16, first.hi) + 1 >= folded.lo) {
        first.lo = @min(first.lo, folded.lo);
        first.hi = @max(first.hi, folded.hi);
    } else {
        result.values[1] = folded;
        result.len = 2;
    }
    return result;
}

const testing = std.testing;

test "Byte map partitions exact, folded, and absent intervals" {
    const instructions = [_]program.GraphInstruction{
        program.GraphInstruction.fail(),
        program.GraphInstruction.byteRange(@enumFromInt(0), '0', '9', false),
        program.GraphInstruction.byteRange(@enumFromInt(0), 'a', 'f', true),
    };
    const partition = try build(testing.allocator, &instructions);
    defer testing.allocator.free(partition.map);
    try testing.expectEqual(@as(u16, 7), partition.count);
    try testing.expect(partition.map['/'] != partition.map['0']);
    try testing.expect(partition.map['9'] != partition.map[':']);
    try testing.expect(partition.map['A'] != partition.map['G']);
    try testing.expect(partition.map['A'] != partition.map['a']);
    try testing.expect(instructions[2].matchesByte('A'));
    try testing.expect(instructions[2].matchesByte('a'));
    try testing.expect(instructions[2].matchesByte('F'));
    try testing.expect(instructions[2].matchesByte('f'));
}
