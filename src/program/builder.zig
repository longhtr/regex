//! Mutable Thompson graph construction with explicit dangling-edge patch lists.
//!
//! Thompson construction does not know every successor when an instruction is
//! emitted. Builder stores each unresolved edge as a typed `Patch` naming an
//! instruction and one of its output fields. `PatchList` is a linked list through
//! a separate patch arena; concatenating two lists changes only links, and
//! `patch` resolves each edge exactly once.
//!
//! Builder instructions use a readable tagged union with optional targets. This
//! avoids pointer tagging and magic instruction IDs while the graph is partial.
//! Helpers add semantic instructions, split/jump control, and accepting IDs under
//! the configured instruction limit.
//!
//! Concatenation may elide an unshared dangling jump by redirecting its patch,
//! but existing graph references remain valid. `finish` requires every reachable
//! edge to be resolved, lowers the mutable union to fixed Graph instructions,
//! validates both anchored/unanchored roots and capture slots, and transfers one
//! immutable Graph. All partial lists remain builder-owned on failure.

const std = @import("std");
const program = @import("program.zig");

pub const InstId = program.InstId;
/// Singly linked set of unresolved graph edges. Empty is the identity for list
/// concatenation; ownership remains with Builder until every patch is resolved.
pub const PatchList = struct {
    head: ?PatchId = null,
    tail: ?PatchId = null,
};

const PatchId = enum(u32) { _ };
const PatchField = enum { out, alternate };
/// One unresolved output field plus the next patch in the same logical list.
const Patch = struct {
    instruction: InstId,
    field: PatchField,
    next: ?PatchId = null,
};

/// Opcode-specific mutable payloads. Optional edges remain null until patching.
const ByteRange = struct { out: ?InstId, lo: u8, hi: u8, fold: bool };
const EmptyWidth = struct { out: ?InstId, mask: program.EmptyMask };
const Capture = struct { out: ?InstId, slot: program.CaptureSlot };
const Split = struct { preferred: ?InstId, alternate: ?InstId };

/// Mutable instruction form. Optional targets distinguish a genuinely dangling
/// edge from graph instruction zero, which is the reserved fail instruction.
const BuilderInst = union(enum) {
    fail,
    byte_range: ByteRange,
    empty_width: EmptyWidth,
    capture: Capture,
    split: Split,
    jump: ?InstId,
    match: program.MatchId,
};

/// Owner of mutable instructions and unresolved-edge patch records for one
/// compile transaction. Fragment composition appends graph nodes and linked patch
/// chains; `finish` rejects any unresolved edge before transferring immutable
/// instruction storage into Graph.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    max_instructions: u32,
    instructions: std.ArrayList(BuilderInst) = .empty,
    patches: std.ArrayList(Patch) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        max_instructions: u32,
    ) (error{InstructionLimit} || std.mem.Allocator.Error)!Builder {
        var result = Builder{ .allocator = allocator, .max_instructions = max_instructions };
        errdefer result.deinit();
        _ = try result.add(.fail);
        return result;
    }

    /// Reserves compile-only graph storage from the syntax-size estimate. This
    /// avoids geometric realloc/copy churn without changing instruction limits.
    pub fn reserve(self: *Builder, hint: usize) std.mem.Allocator.Error!void {
        const bounded = @min(hint, @as(usize, self.max_instructions));
        try self.instructions.ensureTotalCapacityPrecise(self.allocator, bounded);
        try self.patches.ensureTotalCapacityPrecise(self.allocator, bounded);
    }

    pub fn deinit(self: *Builder) void {
        self.patches.deinit(self.allocator);
        self.instructions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addByteRange(
        self: *Builder,
        lo: u8,
        hi: u8,
        fold: bool,
    ) (error{InstructionLimit} || std.mem.Allocator.Error)!struct { InstId, PatchList } {
        std.debug.assert(lo <= hi);
        const id = try self.add(.{ .byte_range = .{ .out = null, .lo = lo, .hi = hi, .fold = fold } });
        return .{ id, try self.dangling(id, .out) };
    }

    pub fn addEmptyWidth(
        self: *Builder,
        mask: program.EmptyMask,
    ) (error{InstructionLimit} || std.mem.Allocator.Error)!struct { InstId, PatchList } {
        const id = try self.add(.{ .empty_width = .{ .out = null, .mask = mask } });
        return .{ id, try self.dangling(id, .out) };
    }

    pub fn addCapture(
        self: *Builder,
        slot: program.CaptureSlot,
    ) (error{InstructionLimit} || std.mem.Allocator.Error)!struct { InstId, PatchList } {
        const id = try self.add(.{ .capture = .{ .out = null, .slot = slot } });
        return .{ id, try self.dangling(id, .out) };
    }

    pub fn addJump(self: *Builder) (error{InstructionLimit} || std.mem.Allocator.Error)!struct { InstId, PatchList } {
        const id = try self.add(.{ .jump = null });
        return .{ id, try self.dangling(id, .out) };
    }

    pub fn addSplit(
        self: *Builder,
        preferred: ?InstId,
        alternate: ?InstId,
    ) (error{InstructionLimit} || std.mem.Allocator.Error)!struct { InstId, PatchList, PatchList } {
        const id = try self.add(.{ .split = .{ .preferred = preferred, .alternate = alternate } });
        const preferred_patch = if (preferred == null) try self.dangling(id, .out) else PatchList{};
        const alternate_patch = if (alternate == null) try self.dangling(id, .alternate) else PatchList{};
        return .{ id, preferred_patch, alternate_patch };
    }

    pub fn addMatch(
        self: *Builder,
        id: program.MatchId,
    ) (error{InstructionLimit} || std.mem.Allocator.Error)!InstId {
        return self.add(.{ .match = id });
    }

    /// Concatenates linked patch lists without allocating. Both inputs are
    /// consumed as logical handles; their records remain Builder-owned.
    pub fn appendPatches(self: *Builder, first: PatchList, second: PatchList) PatchList {
        if (first.head == null) return second;
        if (second.head == null) return first;
        self.patches.items[@intFromEnum(first.tail.?)].next = second.head;
        return .{ .head = first.head, .tail = second.tail };
    }

    /// Patches an unshared, dangling jump and reports that concatenation may
    /// use the target directly. Existing references to the jump remain valid.
    pub fn patchElidableJump(
        self: *Builder,
        start: InstId,
        list: PatchList,
        target: InstId,
    ) bool {
        const head = list.head orelse return false;
        if (list.tail != head) return false;
        const entry = self.patches.items[@intFromEnum(head)];
        if (entry.instruction != start or entry.field != .out or entry.next != null)
            return false;
        switch (self.instructions.items[@intFromEnum(start)]) {
            .jump => |out| if (out != null) return false,
            else => return false,
        }
        self.patch(list, target);
        return true;
    }

    /// Resolves every edge in `list` to one target. Double-patching is a compiler
    /// bug and is guarded by assertions on the optional fields.
    pub fn patch(self: *Builder, list: PatchList, target: InstId) void {
        var current = list.head;
        while (current) |id| {
            const entry = self.patches.items[@intFromEnum(id)];
            const instruction = &self.instructions.items[@intFromEnum(entry.instruction)];
            switch (instruction.*) {
                .byte_range => |*value| {
                    std.debug.assert(entry.field == .out and value.out == null);
                    value.out = target;
                },
                .empty_width => |*value| {
                    std.debug.assert(entry.field == .out and value.out == null);
                    value.out = target;
                },
                .capture => |*value| {
                    std.debug.assert(entry.field == .out and value.out == null);
                    value.out = target;
                },
                .jump => |*value| {
                    std.debug.assert(entry.field == .out and value.* == null);
                    value.* = target;
                },
                .split => |*value| switch (entry.field) {
                    .out => {
                        std.debug.assert(value.preferred == null);
                        value.preferred = target;
                    },
                    .alternate => {
                        std.debug.assert(value.alternate == null);
                        value.alternate = target;
                    },
                },
                .fail, .match => unreachable,
            }
            current = entry.next;
        }
    }

    /// Converts every resolved mutable instruction to fixed Graph storage. Any
    /// remaining null edge reports `IncompleteProgram`; success transfers only
    /// the Graph allocation and leaves temporary patch storage in Builder.
    pub fn finish(
        self: *Builder,
        start: InstId,
        start_unanchored: InstId,
        capture_slots: u32,
    ) (error{IncompleteProgram} || std.mem.Allocator.Error)!program.Graph {
        var output = try self.allocator.alloc(program.GraphInstruction, self.instructions.items.len);
        errdefer self.allocator.free(output);
        for (self.instructions.items, 0..) |instruction, index| {
            output[index] = switch (instruction) {
                .fail => program.GraphInstruction.fail(),
                .byte_range => |value| program.GraphInstruction.byteRange(
                    value.out orelse return error.IncompleteProgram,
                    value.lo,
                    value.hi,
                    value.fold,
                ),
                .empty_width => |value| program.GraphInstruction.emptyWidth(
                    value.out orelse return error.IncompleteProgram,
                    value.mask,
                ),
                .capture => |value| program.GraphInstruction.capture(
                    value.out orelse return error.IncompleteProgram,
                    value.slot,
                ),
                .split => |value| program.GraphInstruction.split(
                    value.preferred orelse return error.IncompleteProgram,
                    value.alternate orelse return error.IncompleteProgram,
                ),
                .jump => |target| program.GraphInstruction.jump(target orelse return error.IncompleteProgram),
                .match => |id| program.GraphInstruction.accepting(id),
            };
        }
        return .{
            .instructions = output,
            .start = start,
            .start_unanchored = start_unanchored,
            .capture_slots = capture_slots,
        };
    }

    fn add(
        self: *Builder,
        instruction: BuilderInst,
    ) (error{InstructionLimit} || std.mem.Allocator.Error)!InstId {
        if (self.instructions.items.len >= self.max_instructions) return error.InstructionLimit;
        const index: u32 = @intCast(self.instructions.items.len);
        try self.instructions.append(self.allocator, instruction);
        return @enumFromInt(index);
    }

    /// Allocates one patch record for a currently null output field.
    fn dangling(
        self: *Builder,
        instruction: InstId,
        field: PatchField,
    ) (error{InstructionLimit} || std.mem.Allocator.Error)!PatchList {
        if (self.patches.items.len >= std.math.maxInt(u32)) return error.InstructionLimit;
        const id: PatchId = @enumFromInt(self.patches.items.len);
        try self.patches.append(self.allocator, .{ .instruction = instruction, .field = field });
        return .{ .head = id, .tail = id };
    }
};

const testing = std.testing;
test "Concatenation elides a dangling jump without invalidating references" {
    var builder = try Builder.init(testing.allocator, 16);
    defer builder.deinit();

    const jump = try builder.addJump();
    const byte = try builder.addByteRange('a', 'a', false);
    const split = try builder.addSplit(jump[0], byte[0]);
    try testing.expect(builder.patchElidableJump(jump[0], jump[1], byte[0]));
    try testing.expect(!builder.patchElidableJump(jump[0], jump[1], byte[0]));
    const accepting = try builder.addMatch(@enumFromInt(0));
    builder.patch(byte[1], accepting);

    var graph = try builder.finish(split[0], split[0], 2);
    defer graph.deinit(testing.allocator);
    try graph.validate();
    try testing.expectEqual(jump[0], graph.inst(split[0]).out());
    try testing.expectEqual(byte[0], graph.inst(jump[0]).out());
}

test "Patch lists concatenate and publish once" {
    var builder = try Builder.init(testing.allocator, 16);
    defer builder.deinit();

    const a = try builder.addByteRange('a', 'a', false);
    const b = try builder.addByteRange('b', 'b', false);
    const split = try builder.addSplit(a[0], b[0]);
    const accepting = try builder.addMatch(@enumFromInt(0));
    builder.patch(builder.appendPatches(a[1], b[1]), accepting);

    var graph = try builder.finish(split[0], split[0], 2);
    defer graph.deinit(testing.allocator);
    try graph.validate();
    try testing.expectEqual(program.Opcode.split, graph.inst(split[0]).opcode());
    try testing.expectEqual(accepting, graph.inst(a[0]).out());
    try testing.expectEqual(accepting, graph.inst(b[0]).out());
}
