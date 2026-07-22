//! Thompson-fragment algebra shared by syntax compilation and byte lowering.
//!
//! A `Fragment` summarizes a partial automaton by one entry instruction, a list
//! of unresolved successful exits, and whether an empty path exists. Composition
//! needs no graph traversal:
//!
//! - concatenation patches every first exit to the second entry and combines
//!   nullability with logical AND;
//! - alternation emits one ordered split, appends both exit lists, and combines
//!   nullability with logical OR;
//! - `noMatch` uses the reserved fail entry with no exits.
//!
//! The order of arguments to alternation is semantic: the first fragment becomes
//! the preferred split arm. Keeping this algebra small makes priority decisions
//! in compiler/lowering code explicit rather than hidden in a generic graph API.

const builder_module = @import("builder.zig");
const program = @import("program.zig");

pub const Error = error{ OutOfMemory, InstructionLimit };

/// Partial automaton entry, unresolved successful exits, and empty-path fact.
pub const Fragment = struct {
    start: program.InstId,
    outs: builder_module.PatchList,
    nullable: bool,
};

pub fn noMatch() Fragment {
    return .{ .start = @enumFromInt(0), .outs = .{}, .nullable = false };
}

pub fn byteRange(
    builder: *builder_module.Builder,
    lo: u8,
    hi: u8,
) Error!Fragment {
    const value = try builder.addByteRange(lo, hi, false);
    return .{ .start = value[0], .outs = value[1], .nullable = false };
}

/// Patches first exits into second; an elidable dangling jump may make second's
/// entry the combined entry without invalidating graph references.
pub fn concatenate(builder: *builder_module.Builder, first: Fragment, second: Fragment) Fragment {
    if (builder.patchElidableJump(first.start, first.outs, second.start)) return second;
    builder.patch(first.outs, second.start);
    return .{
        .start = first.start,
        .outs = second.outs,
        .nullable = first.nullable and second.nullable,
    };
}

/// Emits a split preferring `first` and appends both dangling-exit lists.
pub fn alternate(builder: *builder_module.Builder, first: Fragment, second: Fragment) Error!Fragment {
    const split = try builder.addSplit(first.start, second.start);
    return .{
        .start = split[0],
        .outs = builder.appendPatches(first.outs, second.outs),
        .nullable = first.nullable or second.nullable,
    };
}
