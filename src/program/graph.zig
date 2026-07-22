//! Typed, compile-only Thompson control-flow graph.
//!
//! `Instruction` is a fixed-layout tagged record with two control-flow words and
//! two payload words. Typed `InstId`, `CaptureSlot`, and `MatchId` domains keep
//! graph edges, capture metadata, and accepting IDs distinct despite sharing
//! 32-bit storage. Constructors and opcode-specific accessors centralize layout
//! checks.
//!
//! The instruction set separates epsilon control (`split`, `jump`) from semantic
//! leaves (`byte_range`, `empty_width`, `capture`, `match`, `fail`). Preferred
//! versus alternate split order is observable matching priority. A Graph stores
//! both an anchored root and an unanchored root; the latter includes the compiler
//! scan loop.
//!
//! Validation checks opcode payloads, target bounds, capture-slot bounds, both
//! roots, and the reserved fail instruction before any graph is published. The
//! graph remains easy to inspect and mutate during compilation, but no runtime
//! executor retains it: publication removes split/jump closure and emits compact
//! Program leaves plus priority lists.

const std = @import("std");

/// Distinct 32-bit domains prevent mixing graph instructions, capture slots, and
/// accepting pattern IDs at compile time.
pub const InstId = enum(u32) { _ };
pub const CaptureSlot = enum(u32) { _ };
pub const MatchId = enum(u32) { _ };

/// Compile instruction categories. `split` and `jump` are epsilon control and
/// must not appear in a published runtime leaf table.
pub const Opcode = enum(u8) {
    fail,
    byte_range,
    empty_width,
    capture,
    split,
    jump,
    match,
};

/// Conjunction of zero-width assertions evaluated at one absolute input
/// position. Reserved bits must remain zero for representation validation.
pub const EmptyMask = packed struct(u32) {
    begin_line: bool = false,
    end_line: bool = false,
    begin_text: bool = false,
    end_text: bool = false,
    word_boundary: bool = false,
    not_word_boundary: bool = false,
    reserved: u26 = 0,
};

/// Twelve-byte fixed graph instruction. Payload interpretation is opcode-specific
/// and exposed only by asserted accessors below.
pub const Instruction = extern struct {
    out_value: u32,
    arg: u32,
    aux: u16,
    opcode_value: Opcode,
    flags: u8,

    const fold_ascii: u8 = 1 << 0;

    pub fn fail() Instruction {
        return init(.fail, 0, 0, 0, 0);
    }

    pub fn byteRange(next: InstId, lo: u8, hi: u8, fold: bool) Instruction {
        std.debug.assert(lo <= hi);
        return init(
            .byte_range,
            @intFromEnum(next),
            0,
            @as(u16, lo) | (@as(u16, hi) << 8),
            if (fold) fold_ascii else 0,
        );
    }

    pub fn emptyWidth(next: InstId, mask: EmptyMask) Instruction {
        return init(.empty_width, @intFromEnum(next), @bitCast(mask), 0, 0);
    }

    pub fn capture(next: InstId, slot: CaptureSlot) Instruction {
        return init(.capture, @intFromEnum(next), @intFromEnum(slot), 0, 0);
    }

    pub fn split(preferred: InstId, alternate_id: InstId) Instruction {
        return init(.split, @intFromEnum(preferred), @intFromEnum(alternate_id), 0, 0);
    }

    pub fn jump(next: InstId) Instruction {
        return init(.jump, @intFromEnum(next), 0, 0, 0);
    }

    pub fn accepting(id: MatchId) Instruction {
        return init(.match, 0, @intFromEnum(id), 0, 0);
    }

    pub fn opcode(self: Instruction) Opcode {
        return self.opcode_value;
    }

    pub fn out(self: Instruction) InstId {
        std.debug.assert(switch (self.opcode()) {
            .byte_range, .empty_width, .capture, .split, .jump => true,
            else => false,
        });
        return @enumFromInt(self.out_value);
    }

    pub fn alternate(self: Instruction) InstId {
        std.debug.assert(self.opcode() == .split);
        return @enumFromInt(self.arg);
    }

    pub fn byteLo(self: Instruction) u8 {
        std.debug.assert(self.opcode() == .byte_range);
        return @truncate(self.aux);
    }

    pub fn byteHi(self: Instruction) u8 {
        std.debug.assert(self.opcode() == .byte_range);
        return @truncate(self.aux >> 8);
    }

    pub fn foldsAscii(self: Instruction) bool {
        std.debug.assert(self.opcode() == .byte_range);
        return self.flags & fold_ascii != 0;
    }

    pub fn matchesByte(self: Instruction, byte: u8) bool {
        std.debug.assert(self.opcode() == .byte_range);
        var compared = byte;
        if (self.foldsAscii() and compared >= 'A' and compared <= 'Z') {
            compared += 'a' - 'A';
        }
        return compared >= self.byteLo() and compared <= self.byteHi();
    }

    pub fn emptyMask(self: Instruction) EmptyMask {
        std.debug.assert(self.opcode() == .empty_width);
        return @bitCast(self.arg);
    }

    pub fn captureSlot(self: Instruction) CaptureSlot {
        std.debug.assert(self.opcode() == .capture);
        return @enumFromInt(self.arg);
    }

    pub fn matchId(self: Instruction) MatchId {
        std.debug.assert(self.opcode() == .match);
        return @enumFromInt(self.arg);
    }

    fn init(op: Opcode, next: u32, arg: u32, aux: u16, flags: u8) Instruction {
        return .{
            .out_value = next,
            .arg = arg,
            .aux = aux,
            .opcode_value = op,
            .flags = flags,
        };
    }
};

comptime {
    if (@sizeOf(Instruction) != 12 or @alignOf(Instruction) != 4) {
        @compileError("12-byte compile instruction layout changed");
    }
}

/// Temporary explicit-control graph used only during compilation.
pub const Graph = struct {
    instructions: []Instruction,
    start: InstId,
    start_unanchored: InstId,
    capture_slots: u32,

    pub fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        allocator.free(self.instructions);
        self.* = undefined;
    }

    pub fn inst(self: *const Graph, id: InstId) Instruction {
        return self.instructions[@intFromEnum(id)];
    }

    /// Checks complete initialization and every opcode-specific edge/payload
    /// domain before publication traverses the graph.
    pub fn validate(self: *const Graph) error{InvalidProgram}!void {
        if (self.instructions.len == 0 or
            self.instructions[0].opcode() != .fail or
            @intFromEnum(self.start) >= self.instructions.len or
            @intFromEnum(self.start_unanchored) >= self.instructions.len or
            self.capture_slots < 2 or self.capture_slots & 1 != 0)
            return error.InvalidProgram;
        for (self.instructions) |instruction| switch (instruction.opcode()) {
            .fail => if (instruction.out_value != 0 or instruction.arg != 0 or
                instruction.aux != 0 or instruction.flags != 0) return error.InvalidProgram,
            .byte_range => {
                if (@intFromEnum(instruction.out()) >= self.instructions.len or
                    instruction.arg != 0 or instruction.byteLo() > instruction.byteHi() or
                    instruction.flags & ~Instruction.fold_ascii != 0) return error.InvalidProgram;
            },
            .empty_width => {
                if (@intFromEnum(instruction.out()) >= self.instructions.len or
                    instruction.aux != 0 or instruction.flags != 0 or
                    instruction.emptyMask().reserved != 0) return error.InvalidProgram;
            },
            .capture => {
                if (@intFromEnum(instruction.out()) >= self.instructions.len or
                    @intFromEnum(instruction.captureSlot()) >= self.capture_slots or
                    instruction.aux != 0 or instruction.flags != 0) return error.InvalidProgram;
            },
            .split => {
                if (@intFromEnum(instruction.out()) >= self.instructions.len or
                    @intFromEnum(instruction.alternate()) >= self.instructions.len or
                    instruction.aux != 0 or instruction.flags != 0) return error.InvalidProgram;
            },
            .jump => {
                if (@intFromEnum(instruction.out()) >= self.instructions.len or
                    instruction.arg != 0 or instruction.aux != 0 or
                    instruction.flags != 0) return error.InvalidProgram;
            },
            .match => {
                if (instruction.out_value != 0 or instruction.aux != 0 or
                    instruction.flags != 0) return error.InvalidProgram;
            },
        };
    }
};

const testing = std.testing;

test "Compile instruction has typed round trips" {
    const first: InstId = @enumFromInt(7);
    const second: InstId = @enumFromInt(9);
    const split = Instruction.split(first, second);
    try testing.expectEqual(Opcode.split, split.opcode());
    try testing.expectEqual(first, split.out());
    try testing.expectEqual(second, split.alternate());
    const range = Instruction.byteRange(first, 'a', 'z', true);
    try testing.expectEqual(@as(u8, 'a'), range.byteLo());
    try testing.expectEqual(@as(u8, 'z'), range.byteHi());
    try testing.expect(range.foldsAscii());
}
