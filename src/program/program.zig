//! Validated immutable representation consumed by every execution engine.
//!
//! Control flow is represented by `PriorityLists`: each root names an ordered
//! slice of `PriorityItem`s, and an item is either another root or a compact
//! semantic leaf. The 32-bit item reserves one bit for root identity and one for
//! list termination; the remaining 30 bits index roots/leaves. A
//! `RuntimeInstruction` packs opcode, successor root, and payload into 64 bits.
//!
//! Semantic leaves are byte ranges, empty-width assertions, capture writes,
//! match IDs, or fail. Split and jump never survive publication. This lets NFA,
//! DFA, OnePass, and BitState share one instruction meaning while retaining
//! execution-specific state representations.
//!
//! Program also stores compile-time facts that can only remove work: byte
//! equivalence classes, required prefix/suffix/interior literal, anchoring,
//! empty-language shape, whole-capture shape, and exact repeated-byte descriptors.
//! The canonical lists remain complete if every optional fact and plan is ignored;
//! summaries can remove work but cannot replace unproved Program semantics.
//!
//! Storage unions distinguish externally shared static arrays from allocated
//! arrays, making teardown follow representation rather than parallel ownership
//! flags. `validate` checks all spans, roots, leaves, successors, payload domains,
//! byte-class monotonicity, capture slots, and consistency among summary facts.
//! Engines may rely on these invariants without defensive checks in hot loops.

const std = @import("std");
const graph = @import("graph.zig");
const plan_types = @import("../optimize/plans.zig");

pub const InstId = graph.InstId;
pub const CaptureSlot = graph.CaptureSlot;
pub const MatchId = graph.MatchId;
pub const Opcode = graph.Opcode;
pub const EmptyMask = graph.EmptyMask;
pub const GraphInstruction = graph.Instruction;
pub const Graph = graph.Graph;
pub const RuntimeInstructionId = enum(u32) { _ };

/// Compact runtime leaf. Control-flow roots and payloads fit the domains already
/// imposed by 30-bit priority IDs and reachable compile-graph instructions.
pub const RuntimeInstruction = packed struct(u64) {
    bits: u64,

    const value_mask: u64 = (@as(u64, 1) << 30) - 1;
    const opcode_shift = 30;
    const payload_shift = 33;
    const payload_mask: u64 = (@as(u64, 1) << 31) - 1;

    /// Packs one semantic Graph instruction and its published successor root;
    /// epsilon split/jump instructions are invalid at this boundary.
    pub fn fromInst(instruction: GraphInstruction, successor_root: u32) error{InstructionLimit}!RuntimeInstruction {
        const kind = instruction.opcode();
        var value: u32 = 0;
        var payload: u64 = 0;
        switch (kind) {
            .fail => {},
            .byte_range => {
                value = successor_root;
                payload = instruction.byteLo() |
                    (@as(u64, instruction.byteHi()) << 8) |
                    (@as(u64, @intFromBool(instruction.foldsAscii())) << 16);
            },
            .empty_width => {
                value = successor_root;
                payload = @as(u32, @bitCast(instruction.emptyMask()));
            },
            .capture => {
                value = successor_root;
                payload = @intFromEnum(instruction.captureSlot());
            },
            .match => value = @intFromEnum(instruction.matchId()),
            .split, .jump => unreachable,
        }
        if (value > value_mask or payload > payload_mask) return error.InstructionLimit;
        return .{ .bits = value |
            (@as(u64, @intFromEnum(kind)) << opcode_shift) |
            (payload << payload_shift) };
    }

    pub fn opcode(self: RuntimeInstruction) Opcode {
        return @enumFromInt((self.bits >> opcode_shift) & 0x7);
    }

    pub fn successorRoot(self: RuntimeInstruction) u32 {
        return @intCast(self.bits & value_mask);
    }

    pub fn byteLo(self: RuntimeInstruction) u8 {
        std.debug.assert(self.opcode() == .byte_range);
        return @truncate(self.bits >> payload_shift);
    }

    pub fn byteHi(self: RuntimeInstruction) u8 {
        std.debug.assert(self.opcode() == .byte_range);
        return @truncate(self.bits >> (payload_shift + 8));
    }

    pub fn foldsAscii(self: RuntimeInstruction) bool {
        std.debug.assert(self.opcode() == .byte_range);
        return self.bits & (@as(u64, 1) << (payload_shift + 16)) != 0;
    }

    pub fn matchesByte(self: RuntimeInstruction, byte: u8) bool {
        var compared = byte;
        if (self.foldsAscii() and compared >= 'A' and compared <= 'Z') compared += 'a' - 'A';
        return compared >= self.byteLo() and compared <= self.byteHi();
    }

    pub fn emptyMask(self: RuntimeInstruction) EmptyMask {
        std.debug.assert(self.opcode() == .empty_width);
        return @bitCast(@as(u32, @truncate(self.bits >> payload_shift)));
    }

    pub fn captureSlot(self: RuntimeInstruction) CaptureSlot {
        std.debug.assert(self.opcode() == .capture);
        return @enumFromInt(@as(u32, @truncate(self.bits >> payload_shift)));
    }

    pub fn matchId(self: RuntimeInstruction) MatchId {
        std.debug.assert(self.opcode() == .match);
        return @enumFromInt(self.successorRoot());
    }
};

comptime {
    if (@sizeOf(RuntimeInstruction) != 8 or @alignOf(RuntimeInstruction) != @alignOf(u64)) {
        @compileError("8-byte runtime leaf layout changed");
    }
}
pub const no_priority_root = std.math.maxInt(u32);
pub const max_required_suffix_bytes: usize = 32;
pub const max_required_literal_bytes: usize = 32;
pub const empty_byte_map: [256]u8 = @splat(0);

/// Packed member of a canonical priority list. `root_bit` selects nested-root
/// versus leaf identity; `last_bit` terminates a list without a separate sentinel
/// item. The remaining 30-bit value indexes the selected table.
pub const PriorityItem = enum(u32) {
    _,

    const root_bit: u32 = 1 << 31;
    const last_bit: u32 = 1 << 30;
    const value_mask: u32 = last_bit - 1;

    pub fn fromRoot(root_id: u32) PriorityItem {
        std.debug.assert(root_id <= value_mask);
        return @enumFromInt(root_bit | root_id);
    }

    pub fn fromGraphInstruction(id: InstId) PriorityItem {
        std.debug.assert(@intFromEnum(id) <= value_mask);
        return @enumFromInt(@intFromEnum(id));
    }

    pub fn fromRuntimeInstruction(id: RuntimeInstructionId) PriorityItem {
        std.debug.assert(@intFromEnum(id) <= value_mask);
        return @enumFromInt(@intFromEnum(id));
    }

    pub fn markLast(self: PriorityItem) PriorityItem {
        return @enumFromInt(@intFromEnum(self) | last_bit);
    }

    pub fn isRoot(self: PriorityItem) bool {
        return @intFromEnum(self) & root_bit != 0;
    }

    pub fn isLast(self: PriorityItem) bool {
        return @intFromEnum(self) & last_bit != 0;
    }

    pub fn root(self: PriorityItem) u32 {
        std.debug.assert(self.isRoot());
        return @intFromEnum(self) & value_mask;
    }

    pub fn graphInstruction(self: PriorityItem) InstId {
        std.debug.assert(!self.isRoot());
        return @enumFromInt(@intFromEnum(self) & value_mask);
    }

    pub fn runtimeInstruction(self: PriorityItem) RuntimeInstructionId {
        std.debug.assert(!self.isRoot());
        return @enumFromInt(@intFromEnum(self) & value_mask);
    }
};

/// Span into `PriorityLists.items`; `len` includes the item carrying `last_bit`.
pub const PriorityList = struct {
    offset: u32,
    len: u32,
};

/// Engineering layout counts and exact retained requested bytes. Execution does
/// not consult these values.
pub const Metrics = struct {
    list_count: usize,
    item_count: usize,
    root_item_count: usize,
    leaf_item_count: usize,
    leaf_count: usize,
    list_bytes: usize,
    item_bytes: usize,
    leaf_bytes: usize,
    byte_map_bytes: usize,
    prefix_bytes: usize,
    total_requested_bytes: usize,
};

/// Canonical roots, flattened list items, and interned semantic leaves.
pub const PriorityLists = struct {
    /// Ownership representation for list/item storage. Contiguous publication
    /// packs both tables into one u32 allocation; leaves remain separately typed.
    pub const Layout = union(enum) {
        external,
        separate,
        contiguous: []u32,
    };

    layout: Layout = .external,
    lists: []PriorityList = &.{},
    items: []PriorityItem = &.{},
    leaves: []RuntimeInstruction = &.{},
    start_root: u32 = 0,
    start_unanchored_root: u32 = 0,

    pub fn deinit(self: *PriorityLists, allocator: std.mem.Allocator) void {
        switch (self.layout) {
            .external => {},
            .separate => {
                if (self.leaves.len != 0) allocator.free(self.leaves);
                if (self.items.len != 0) allocator.free(self.items);
                if (self.lists.len != 0) allocator.free(self.lists);
            },
            .contiguous => |storage| {
                if (self.leaves.len != 0) allocator.free(self.leaves);
                if (storage.len != 0) allocator.free(storage);
            },
        }
        self.* = undefined;
    }

    pub fn listItems(self: *const PriorityLists, root_id: u32) []const PriorityItem {
        const list = self.lists[root_id];
        return self.items[list.offset..][0..list.len];
    }
};

/// Bounded exact suffix shared by every successful match.
pub const RequiredSuffix = struct {
    bytes: [max_required_suffix_bytes]u8 = @splat(0),
    len: u8 = 0,
    fold_ascii: bool = false,
};

/// Bounded byte string proven to occur somewhere in every successful match.
/// Unlike `prefix` and `required_suffix`, its offset is unknown; executors use
/// it only for whole-range rejection, never to choose a semantic match start.
pub const RequiredLiteral = struct {
    bytes: [max_required_literal_bytes]u8 = @splat(0),
    len: u8 = 0,
    fold_ascii: bool = false,
};

/// Ownership-tagged 256-byte equivalence map. The empty program may borrow the
/// static all-zero map; all other Programs own publication output.
pub const ByteClasses = union(enum) {
    external: []u8,
    allocated: []u8,

    pub fn values(self: *const ByteClasses) []const u8 {
        return switch (self.*) {
            inline else => |bytes| bytes,
        };
    }

    pub fn mutable(self: *ByteClasses) []u8 {
        return switch (self.*) {
            inline else => |bytes| bytes,
        };
    }

    fn deinit(self: *ByteClasses, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .external => {},
            .allocated => |bytes| if (bytes.len != 0) allocator.free(bytes),
        }
        self.* = undefined;
    }

    fn requestedBytes(self: *const ByteClasses) usize {
        return switch (self.*) {
            .external => 0,
            .allocated => |bytes| bytes.len,
        };
    }
};

/// Immutable canonical execution graph plus conservative accelerator facts.
/// PriorityLists own ordered roots/leaves, ByteClasses maps all input bytes to
/// dense transition classes, and prefix/suffix/anchor/shape fields may only
/// reject or select routes proved equivalent to that graph. Publication creates
/// all owned storage together; matchers borrow it until `deinit`.
pub const Program = struct {
    capture_slots: u32,
    priority_lists: PriorityLists = .{},
    byte_classes: ByteClasses = .{ .external = &.{} },
    byte_class_count: u16 = 0,
    prefix: []const u8 = &.{},
    /// Exact or folded-ASCII bytes required at the end of every match.
    required_suffix: RequiredSuffix = .{},
    /// Exact or folded-ASCII bytes required at an unknown match-relative offset.
    required_literal: RequiredLiteral = .{},
    prefix_fold_ascii: bool = false,
    prefix_complete: bool = false,
    prefix_has_tail_range: bool = false,
    prefix_tail_lo: u8 = 0,
    prefix_tail_hi: u8 = 0,
    uses_empty_width: bool = false,
    empty_mask_union: EmptyMask = .{},
    anchor_start: bool = false,
    /// Every successful match ends at absolute text end.
    anchor_end: bool = false,
    /// Every successful match starts at absolute text start or immediately
    /// after a newline. This is stronger than merely using a line assertion.
    anchor_line_start: bool = false,
    /// True when the language contains an empty match. Conservative by default
    /// so manually published programs never enter non-empty-only accelerators.
    can_match_empty: bool = true,
    all_captures_whole: bool = false,
    plans: plan_types.Plans = .{},

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        if (self.prefix.len != 0) allocator.free(self.prefix);
        self.byte_classes.deinit(allocator);
        self.priority_lists.deinit(allocator);
        self.* = undefined;
    }

    /// Writes dense BitState bitmap rows, using maxInt(u32) for roots that need
    /// no visited row, and returns the number of rows. The output first serves
    /// as a saturating predecessor-count array, keeping setup linear.
    pub fn fillBitStateRootMap(self: *const Program, output: []u32) u32 {
        std.debug.assert(output.len == self.priority_lists.lists.len);
        @memset(output, 0);
        for (self.priority_lists.items) |item| {
            const target: ?u32 = if (item.isRoot())
                item.root()
            else blk: {
                const leaf = self.runtimeInstruction(item);
                break :blk switch (leaf.opcode()) {
                    .byte_range, .empty_width, .capture => leaf.successorRoot(),
                    .fail, .match => null,
                    .split, .jump => unreachable,
                };
            };
            if (target) |root| output[root] = @min(output[root] +| 1, 2);
        }
        var dense: u32 = 0;
        for (output, 0..) |*mapped, root| {
            if (root == self.priority_lists.start_root or mapped.* != 1) {
                mapped.* = dense;
                dense += 1;
            } else {
                mapped.* = std.math.maxInt(u32);
            }
        }
        return dense;
    }

    /// Returns exact bytes requested for allocations owned by this Program.
    pub fn requestedBytes(self: *const Program) usize {
        const published = self.priority_lists.layout != .external;
        const list_bytes = if (published)
            self.priority_lists.lists.len * @sizeOf(PriorityList)
        else
            0;
        const item_bytes = if (published)
            self.priority_lists.items.len * @sizeOf(PriorityItem)
        else
            0;
        const leaf_bytes = if (published)
            self.priority_lists.leaves.len * @sizeOf(RuntimeInstruction)
        else
            0;
        return list_bytes + item_bytes + leaf_bytes +
            self.byte_classes.requestedBytes() + self.prefix.len;
    }

    /// Computes detailed engineering layout metrics. Unlike `requestedBytes`,
    /// this scans items to distinguish nested-root and leaf occurrences.
    pub fn metrics(self: *const Program) Metrics {
        var root_item_count: usize = 0;
        for (self.priority_lists.items) |item| {
            if (item.isRoot()) root_item_count += 1;
        }
        const published = self.priority_lists.layout != .external;
        const list_bytes = if (published)
            self.priority_lists.lists.len * @sizeOf(PriorityList)
        else
            0;
        const item_bytes = if (published)
            self.priority_lists.items.len * @sizeOf(PriorityItem)
        else
            0;
        const leaf_bytes = if (published)
            self.priority_lists.leaves.len * @sizeOf(RuntimeInstruction)
        else
            0;
        const byte_map_bytes = self.byte_classes.requestedBytes();
        const prefix_bytes = self.prefix.len;
        return .{
            .list_count = self.priority_lists.lists.len,
            .item_count = self.priority_lists.items.len,
            .root_item_count = root_item_count,
            .leaf_item_count = self.priority_lists.items.len - root_item_count,
            .leaf_count = self.priority_lists.leaves.len,
            .list_bytes = list_bytes,
            .item_bytes = item_bytes,
            .leaf_bytes = leaf_bytes,
            .byte_map_bytes = byte_map_bytes,
            .prefix_bytes = prefix_bytes,
            .total_requested_bytes = list_bytes + item_bytes + leaf_bytes +
                byte_map_bytes + prefix_bytes,
        };
    }

    pub fn byteClasses(self: *const Program) []const u8 {
        return self.byte_classes.values();
    }

    pub fn mutableByteClasses(self: *Program) []u8 {
        return self.byte_classes.mutable();
    }

    /// Returns leaf semantics for one canonical ordered-list item. Runtime
    /// engines use this boundary instead of depending on graph instruction
    /// storage directly; root-reference items have no leaf instruction.
    pub fn runtimeInstruction(self: *const Program, item: PriorityItem) RuntimeInstruction {
        std.debug.assert(!item.isRoot());
        return self.priority_lists.leaves[@intFromEnum(item.runtimeInstruction())];
    }

    /// Returns the canonical list successor stored directly in a runtime leaf.
    pub fn instructionSuccessor(_: *const Program, instruction: RuntimeInstruction) u32 {
        return instruction.successorRoot();
    }

    /// Establishes every invariant assumed by hot executors: storage ownership,
    /// nonempty/in-bounds lists, marked termination, valid leaf payloads and
    /// successors, dense byte classes, even capture slots, and consistent facts.
    pub fn validate(self: *const Program) error{InvalidProgram}!void {
        const priority = &self.priority_lists;
        const byte_classes = self.byteClasses();
        if (self.capture_slots < 2 or self.capture_slots & 1 != 0 or
            byte_classes.len != 256 or self.byte_class_count == 0 or
            self.byte_class_count > 256 or priority.layout == .external or
            priority.lists.len == 0 or priority.items.len == 0 or
            priority.leaves.len == 0 or
            priority.start_root >= priority.lists.len or
            priority.start_unanchored_root >= priority.lists.len or
            self.empty_mask_union.reserved != 0 or
            (self.anchor_end and !self.empty_mask_union.end_text) or
            (self.required_suffix.fold_ascii and self.required_suffix.len == 0) or
            (self.required_literal.fold_ascii and self.required_literal.len == 0) or
            self.required_literal.len > self.required_literal.bytes.len or
            (self.prefix_complete and self.prefix_has_tail_range) or
            ((self.prefix_complete or self.prefix_has_tail_range or self.prefix_fold_ascii) and
                self.prefix.len == 0) or
            (self.prefix_has_tail_range and self.prefix_tail_lo > self.prefix_tail_hi))
            return error.InvalidProgram;

        try self.plans.validate(self.prefix, self.prefix_fold_ascii);
        if (byte_classes[0] != 0) return error.InvalidProgram;
        var previous_class: u8 = 0;
        for (byte_classes[1..]) |class| {
            if (class != previous_class and
                @as(u16, class) != @as(u16, previous_class) + 1)
                return error.InvalidProgram;
            previous_class = class;
        }
        if (@as(u16, previous_class) + 1 != self.byte_class_count)
            return error.InvalidProgram;
        for (priority.lists) |list| {
            const offset: usize = list.offset;
            const len: usize = list.len;
            if (len == 0 or offset > priority.items.len or
                len > priority.items.len - offset)
                return error.InvalidProgram;
            const values = priority.items[offset..][0..len];
            for (values[0 .. values.len - 1]) |item|
                if (item.isLast()) return error.InvalidProgram;
            if (!values[values.len - 1].isLast()) return error.InvalidProgram;
        }
        for (priority.items) |item| {
            if (item.isRoot()) {
                if (item.root() >= priority.lists.len) return error.InvalidProgram;
            } else if (@intFromEnum(item.runtimeInstruction()) >= priority.leaves.len) {
                return error.InvalidProgram;
            }
        }
        var has_empty_width = false;
        var actual_empty_bits: u32 = 0;
        for (priority.leaves) |leaf| switch (leaf.opcode()) {
            .fail => if (leaf.bits != 0) return error.InvalidProgram,
            .byte_range => {
                if (leaf.successorRoot() >= priority.lists.len or
                    leaf.byteLo() > leaf.byteHi()) return error.InvalidProgram;
                if (!byteRangePartitionValid(leaf, byte_classes))
                    return error.InvalidProgram;
            },
            .empty_width => {
                if (leaf.successorRoot() >= priority.lists.len or
                    leaf.emptyMask().reserved != 0) return error.InvalidProgram;
                has_empty_width = true;
                actual_empty_bits |= @bitCast(leaf.emptyMask());
            },
            .capture => {
                if (leaf.successorRoot() >= priority.lists.len or
                    @intFromEnum(leaf.captureSlot()) >= self.capture_slots)
                    return error.InvalidProgram;
            },
            .match => {},
            .split, .jump => return error.InvalidProgram,
        };
        if (has_empty_width != self.uses_empty_width or
            actual_empty_bits != @as(u32, @bitCast(self.empty_mask_union)))
            return error.InvalidProgram;
    }
};

/// Verifies that a byte predicate is a union of complete equivalence classes by
/// checking each predicate/map boundary interval for constant membership and ID.
fn byteRangePartitionValid(leaf: RuntimeInstruction, byte_map: []const u8) bool {
    var boundaries: [4]u16 = undefined;
    var boundary_count: usize = 0;
    boundaries[boundary_count] = leaf.byteLo();
    boundary_count += 1;
    boundaries[boundary_count] = @as(u16, leaf.byteHi()) + 1;
    boundary_count += 1;

    if (leaf.foldsAscii()) {
        const lower_lo = @max(leaf.byteLo(), 'a');
        const lower_hi = @min(leaf.byteHi(), 'z');
        if (lower_lo <= lower_hi) {
            boundaries[boundary_count] = lower_lo - ('a' - 'A');
            boundary_count += 1;
            boundaries[boundary_count] = @as(u16, lower_hi - ('a' - 'A')) + 1;
            boundary_count += 1;
        }
    }

    for (boundaries[0..boundary_count]) |boundary| {
        if (boundary == 0 or boundary == 256) continue;
        const left: u8 = @intCast(boundary - 1);
        const right: u8 = @intCast(boundary);
        if (leaf.matchesByte(left) != leaf.matchesByte(right) and
            byte_map[left] == byte_map[right]) return false;
    }
    return true;
}
