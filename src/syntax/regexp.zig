//! Compact arena representation of parsed regular-expression syntax.
//!
//! The tree is stored as five append-only arrays rather than separately allocated
//! nodes. `nodes` contains tagged values; `children` backs n-ary concat and
//! alternate spans; `runes`, `ranges`, and `names` back literal/class/metadata
//! spans. Typed IDs and span types prevent accidental index-domain mixing.
//!
//! Nodes refer only backward or sideways by stable integer index, so ArrayList
//! relocation never invalidates the tree. Callers must not retain raw slices
//! across an append. `copyRunes` demonstrates the safe same-arena pattern: check
//! the typed source span, reserve capacity first, then reacquire the source from
//! the possibly moved list before appending.
//!
//! N-ary concat/alternate nodes keep parser reduction and compiler traversal
//! linear and avoid deep binary chains. Literal runs similarly coalesce adjacent
//! scalars. `Regexp` stores no allocator; compile transactions choose and own the
//! allocator, can transfer the name buffer separately, and tear down explicitly.
//!
//! All persistent indices are 32-bit. Append helpers check casts and end offsets
//! before mutation and report `ProgramTooLarge` instead of wrapping.

const std = @import("std");
const rune_range = @import("rune_range.zig");

/// Distinct arena-node and one-based explicit-capture index domains.
pub const NodeId = enum(u32) { _ };
pub const CaptureIndex = enum(u32) { _ };

/// Typed spans prevent indexing one arena array with another array's offset.
pub const NodeSpan = struct { start: u32, len: u32 };
pub const RuneSpan = struct { start: u32, len: u32 };
pub const RangeSpan = struct { start: u32, len: u32 };
pub const ByteSpan = struct { start: u32, len: u32 };

/// Coalesced rune run plus its case-fold policy.
pub const Literal = struct {
    runes: RuneSpan,
    fold: bool,
};

/// Scalar wildcard policy captured when the token is parsed; later flag changes
/// do not affect this node.
pub const AnyChar = struct {
    match_newline: bool,
};

/// Repetition bounds; `max == null` means unbounded and `greedy` records path
/// priority rather than accepted-language membership.
pub const Repeat = struct {
    child: NodeId,
    min: u32,
    max: ?u32,
    greedy: bool,
};

/// Explicit capture declaration. Name bytes are optional; index starts at one
/// because group zero is synthesized by execution.
pub const Capture = struct {
    child: NodeId,
    index: CaptureIndex,
    name: ?ByteSpan,
};

/// Normalized syntax node categories. Epsilon assertions are separate tags;
/// concat/alternate children and literal/class payloads live in side arenas.
pub const Node = union(enum) {
    no_match,
    empty,
    literal: Literal,
    char_class: RangeSpan,
    concat: NodeSpan,
    alternate: NodeSpan,
    repeat: Repeat,
    capture: Capture,
    begin_line,
    end_line,
    begin_text,
    end_text,
    word_boundary,
    not_word_boundary,
    any_char: AnyChar,
    any_byte,
};

/// Owning syntax arena. `root == null` denotes an unpublished/empty arena, not
/// the regex empty language (which has an explicit `.empty` root node).
pub const Regexp = struct {
    nodes: std.ArrayList(Node) = .empty,
    children: std.ArrayList(NodeId) = .empty,
    runes: std.ArrayList(rune_range.Rune) = .empty,
    ranges: std.ArrayList(rune_range.Range) = .empty,
    names: std.ArrayList(u8) = .empty,
    root: ?NodeId = null,
    capture_count: u32 = 0,

    pub fn deinit(self: *Regexp, allocator: std.mem.Allocator) void {
        self.names.deinit(allocator);
        self.ranges.deinit(allocator);
        self.runes.deinit(allocator);
        self.children.deinit(allocator);
        self.nodes.deinit(allocator);
        self.* = undefined;
    }

    pub fn addNode(
        self: *Regexp,
        allocator: std.mem.Allocator,
        value: Node,
    ) (error{ProgramTooLarge} || std.mem.Allocator.Error)!NodeId {
        const index = std.math.cast(u32, self.nodes.items.len) orelse
            return error.ProgramTooLarge;
        try self.nodes.append(allocator, value);
        return @enumFromInt(index);
    }

    pub fn addChildren(
        self: *Regexp,
        allocator: std.mem.Allocator,
        values: []const NodeId,
    ) (error{ProgramTooLarge} || std.mem.Allocator.Error)!NodeSpan {
        return appendSpan(NodeSpan, NodeId, &self.children, allocator, values);
    }

    pub fn addRunes(
        self: *Regexp,
        allocator: std.mem.Allocator,
        values: []const rune_range.Rune,
    ) (error{ProgramTooLarge} || std.mem.Allocator.Error)!RuneSpan {
        return appendSpan(RuneSpan, rune_range.Rune, &self.runes, allocator, values);
    }

    /// Safely copies a subspan from this same potentially moving rune ArrayList:
    /// validate and reserve first, then reacquire the source before append.
    pub fn copyRunes(
        self: *Regexp,
        allocator: std.mem.Allocator,
        source: RuneSpan,
        offset: usize,
        len_value: usize,
    ) (error{ InvalidSpan, ProgramTooLarge } || std.mem.Allocator.Error)!RuneSpan {
        const source_start: usize = source.start;
        const source_len: usize = source.len;
        if (source_start > self.runes.items.len or
            source_len > self.runes.items.len - source_start or
            offset > source_len or len_value > source_len - offset)
            return error.InvalidSpan;

        const start = std.math.cast(u32, self.runes.items.len) orelse
            return error.ProgramTooLarge;
        const len = std.math.cast(u32, len_value) orelse return error.ProgramTooLarge;
        if (@as(u64, start) + len > std.math.maxInt(u32)) return error.ProgramTooLarge;

        try self.runes.ensureUnusedCapacity(allocator, len_value);
        const first = source_start + offset;
        self.runes.appendSliceAssumeCapacity(self.runes.items[first .. first + len_value]);
        return .{ .start = start, .len = len };
    }

    pub fn addRanges(
        self: *Regexp,
        allocator: std.mem.Allocator,
        values: []const rune_range.Range,
    ) (error{ProgramTooLarge} || std.mem.Allocator.Error)!RangeSpan {
        return appendSpan(RangeSpan, rune_range.Range, &self.ranges, allocator, values);
    }

    pub fn addName(
        self: *Regexp,
        allocator: std.mem.Allocator,
        value: []const u8,
    ) (error{ProgramTooLarge} || std.mem.Allocator.Error)!ByteSpan {
        return appendSpan(ByteSpan, u8, &self.names, allocator, value);
    }

    pub fn node(self: *const Regexp, id: NodeId) *const Node {
        return &self.nodes.items[@intFromEnum(id)];
    }

    pub fn nodeChildren(self: *const Regexp, span: NodeSpan) []const NodeId {
        return slice(NodeId, self.children.items, span.start, span.len);
    }

    pub fn literalRunes(self: *const Regexp, span: RuneSpan) []const rune_range.Rune {
        return slice(rune_range.Rune, self.runes.items, span.start, span.len);
    }

    pub fn classRanges(self: *const Regexp, span: RangeSpan) []const rune_range.Range {
        return slice(rune_range.Range, self.ranges.items, span.start, span.len);
    }

    pub fn captureName(self: *const Regexp, span: ByteSpan) []const u8 {
        return slice(u8, self.names.items, span.start, span.len);
    }
};

/// Shared checked append for typed side-arena spans; all 32-bit domain checks
/// happen before list mutation.
fn appendSpan(
    comptime Span: type,
    comptime T: type,
    list: *std.ArrayList(T),
    allocator: std.mem.Allocator,
    values: []const T,
) (error{ProgramTooLarge} || std.mem.Allocator.Error)!Span {
    const start = std.math.cast(u32, list.items.len) orelse return error.ProgramTooLarge;
    const len = std.math.cast(u32, values.len) orelse return error.ProgramTooLarge;
    const end = @as(u64, start) + len;
    if (end > std.math.maxInt(u32)) return error.ProgramTooLarge;
    try list.appendSlice(allocator, values);
    return .{ .start = start, .len = len };
}

fn slice(comptime T: type, values: []const T, start: u32, len: u32) []const T {
    const first: usize = start;
    return values[first .. first + len];
}

const testing = std.testing;

/// Test allocator that always remaps growth, proving same-arena copy helpers do
/// not retain source slices across capacity changes.
const MovingAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false;
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

test "Arena copies rune subspans after moving growth" {
    var moving = MovingAllocator{ .child = testing.allocator };
    const allocator = moving.allocator();
    var regexp: Regexp = .{};
    defer regexp.deinit(allocator);

    const source = try regexp.addRunes(allocator, &.{ 'a', 'b', 'c', 'd' });
    while (regexp.runes.items.len < regexp.runes.capacity)
        try regexp.runes.append(allocator, 'x');

    const cases = [_]struct { offset: usize, len: usize, expected: []const rune_range.Rune }{
        .{ .offset = 0, .len = 0, .expected = &.{} },
        .{ .offset = 0, .len = 4, .expected = &.{ 'a', 'b', 'c', 'd' } },
        .{ .offset = 0, .len = 2, .expected = &.{ 'a', 'b' } },
        .{ .offset = 2, .len = 2, .expected = &.{ 'c', 'd' } },
        .{ .offset = 1, .len = 2, .expected = &.{ 'b', 'c' } },
    };
    for (cases) |case| {
        const copied = try regexp.copyRunes(allocator, source, case.offset, case.len);
        try testing.expectEqualSlices(rune_range.Rune, case.expected, regexp.literalRunes(copied));
    }
    try testing.expectEqualSlices(rune_range.Rune, &.{ 'a', 'b', 'c', 'd' }, regexp.literalRunes(source));
    try testing.expectError(error.InvalidSpan, regexp.copyRunes(allocator, source, 4, 1));
    try testing.expectError(error.InvalidSpan, regexp.copyRunes(allocator, .{
        .start = @intCast(regexp.runes.items.len),
        .len = 1,
    }, 0, 1));
}

test "Arena stores typed n-ary and literal spans" {
    var regexp: Regexp = .{};
    defer regexp.deinit(testing.allocator);

    const literal_span = try regexp.addRunes(testing.allocator, &.{ 'a', 'b' });
    const literal = try regexp.addNode(testing.allocator, .{
        .literal = .{ .runes = literal_span, .fold = false },
    });
    const empty = try regexp.addNode(testing.allocator, .empty);
    const children = try regexp.addChildren(testing.allocator, &.{ literal, empty });
    const concat = try regexp.addNode(testing.allocator, .{ .concat = children });
    regexp.root = concat;

    try testing.expectEqualSlices(rune_range.Rune, &.{ 'a', 'b' }, regexp.literalRunes(literal_span));
    try testing.expectEqualSlices(NodeId, &.{ literal, empty }, regexp.nodeChildren(children));
    try testing.expect(regexp.node(concat).* == .concat);
}
