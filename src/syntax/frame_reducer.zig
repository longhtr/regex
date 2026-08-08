//! Explicit-stack reduction for grouping, concatenation, and alternation.
//!
//! The parser emits completed atoms into `pieces`. A frame records where its
//! current concatenation begins; `|` reduces those pieces to one concat and
//! appends it to the frame's alternatives; closing the frame reduces alternatives
//! to one n-ary alternate. This directly implements precedence:
//!
//! ```text
//! atom/repeat > concatenation > alternation
//! ```
//!
//! A parallel frame stack replaces recursive calls for nested groups. Each frame
//! also stores parser-defined restore state (currently flags), allowing scoped
//! syntax state to be restored without this generic reducer knowing its meaning.
//! Group closing can wrap the reduced child in a capture while preserving one
//! atom boundary for a following repeat operator.
//!
//! Empty concatenations become the explicit `empty` node; empty alternatives are
//! therefore ordinary syntax rather than special executor cases. Adjacent
//! literals are coalesced when fold policy agrees. Every arena/list growth checks
//! configured limits and returns typed failures; parser supplies source spans.

const std = @import("std");
const regexp = @import("regexp.zig");
const rune_range = @import("rune_range.zig");

pub const ReduceError = error{ OutOfMemory, NodeLimit, FrameLimit };

/// Produces a reducer whose frames carry parser-defined state restored at group
/// close. The generic type keeps precedence machinery independent of flag policy.
pub fn Reduction(comptime RestoreState: type) type {
    return struct {
        const Self = @This();

        /// Capture wrapper to apply after reducing a group's inner expression.
        pub const Capture = struct {
            index: regexp.CaptureIndex,
            name: ?regexp.ByteSpan,
        };

        /// Checkpoints delimiting this group's pieces/alternatives, parser restore
        /// state, capture metadata, and opening byte for diagnostics.
        pub const Frame = struct {
            piece_start: usize,
            alternative_start: usize,
            restore: RestoreState,
            capture: ?Capture,
            opening: usize,
        };

        /// Closed group node plus its saved frame state returned to Parser.
        pub const Closed = struct {
            node: regexp.NodeId,
            frame: Frame,
        };

        pieces: std.ArrayList(regexp.NodeId) = .empty,
        alternatives: std.ArrayList(regexp.NodeId) = .empty,
        frames: std.ArrayList(Frame) = .empty,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.frames.deinit(allocator);
            self.alternatives.deinit(allocator);
            self.pieces.deinit(allocator);
            self.* = undefined;
        }

        /// Pushes a group checkpoint without emitting syntax. Saved stack
        /// lengths isolate nested reduction and make depth consume heap storage
        /// rather than the process call stack.
        pub fn openFrame(
            self: *Self,
            allocator: std.mem.Allocator,
            restore: RestoreState,
            capture: ?Capture,
            opening: usize,
        ) error{OutOfMemory}!void {
            try self.frames.append(allocator, .{
                .piece_start = self.pieces.items.len,
                .alternative_start = self.alternatives.items.len,
                .restore = restore,
                .capture = capture,
                .opening = opening,
            });
        }

        pub fn appendPiece(
            self: *Self,
            allocator: std.mem.Allocator,
            node: regexp.NodeId,
        ) error{OutOfMemory}!void {
            try self.pieces.append(allocator, node);
        }

        pub fn hasCurrentPiece(self: *const Self) bool {
            return self.pieces.items.len > self.currentFrame().piece_start;
        }

        pub fn lastPiece(self: *const Self) regexp.NodeId {
            std.debug.assert(self.hasCurrentPiece());
            return self.pieces.items[self.pieces.items.len - 1];
        }

        pub fn popPiece(self: *Self) regexp.NodeId {
            std.debug.assert(self.hasCurrentPiece());
            return self.pieces.pop().?;
        }

        pub fn currentFrame(self: *const Self) *const Frame {
            std.debug.assert(self.frames.items.len != 0);
            return &self.frames.items[self.frames.items.len - 1];
        }

        pub fn frameCount(self: *const Self) usize {
            return self.frames.items.len;
        }

        /// Collapses the current concatenation (empty/single/n-ary) and appends it
        /// as one branch of the current frame.
        pub fn finishAlternative(
            self: *Self,
            allocator: std.mem.Allocator,
            syntax: *regexp.Regexp,
            max_nodes: u32,
        ) ReduceError!void {
            const piece_start = self.currentFrame().piece_start;
            const branch = try self.collapsePieces(allocator, syntax, max_nodes, piece_start);
            try self.alternatives.append(allocator, branch);
            self.pieces.shrinkRetainingCapacity(piece_start);
        }

        /// Reduces and removes the synthetic outer frame to produce the parser
        /// root; unlike nested close, it wraps no capture and has no parent atom.
        pub fn finishTop(
            self: *Self,
            allocator: std.mem.Allocator,
            syntax: *regexp.Regexp,
            max_nodes: u32,
        ) ReduceError!regexp.NodeId {
            std.debug.assert(self.frames.items.len == 1);
            const node = try self.finishFrame(allocator, syntax, max_nodes);
            _ = self.frames.pop();
            return node;
        }

        /// Reduces and pops a nested group, applies capture or a transparent
        /// singleton wrapper, and appends the result as one parent-frame atom.
        pub fn closeFrame(
            self: *Self,
            allocator: std.mem.Allocator,
            syntax: *regexp.Regexp,
            max_nodes: u32,
        ) ReduceError!Closed {
            std.debug.assert(self.frames.items.len > 1);
            const frame = self.currentFrame().*;
            var node = try self.finishFrame(allocator, syntax, max_nodes);
            _ = self.frames.pop();

            if (frame.capture) |capture| {
                node = self.newNode(allocator, syntax, max_nodes, .{ .capture = .{
                    .child = node,
                    .index = capture.index,
                    .name = capture.name,
                } }) catch |err| return promoteFrameError(err);
            } else {
                // A transparent singleton preserves the group's postfix atom
                // boundary after adjacent literals have been coalesced.
                const span = syntax.addChildren(allocator, &.{node}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ProgramTooLarge => return error.FrameLimit,
                };
                node = self.newNode(allocator, syntax, max_nodes, .{ .concat = span }) catch |err|
                    return promoteFrameError(err);
            }
            try self.pieces.append(allocator, node);
            return .{ .node = node, .frame = frame };
        }

        /// Replaces the current final atom with repetition. Coalesced literal runs
        /// are split so postfix binding affects only their final rune; selected
        /// identical simple nested repeats are normalized without changing
        /// greediness.
        pub fn applyRepeat(
            self: *Self,
            allocator: std.mem.Allocator,
            syntax: *regexp.Regexp,
            max_nodes: u32,
            min: u32,
            max: ?u32,
            greedy: bool,
        ) (error{ OutOfMemory, NodeLimit })!void {
            var child = self.popPiece();
            if (syntax.node(child).* == .literal) {
                const literal = syntax.node(child).literal;
                if (literal.runes.len > 1) {
                    // Coalescing is an arena optimization. Postfix operators
                    // bind only the final Rune, so split the run in place.
                    syntax.nodes.items[@intFromEnum(child)].literal.runes.len -= 1;
                    try self.pieces.append(allocator, child);
                    child = try self.newNode(allocator, syntax, max_nodes, .{ .literal = .{
                        .runes = .{
                            .start = literal.runes.start + literal.runes.len - 1,
                            .len = 1,
                        },
                        .fold = literal.fold,
                    } });
                }
            }

            // project squashes parenthesized combinations of *, +, and ? when
            // both levels have identical greediness. Look through only the
            // transparent singleton created when a group closes.
            var nested_id = child;
            const child_node = syntax.node(child).*;
            if (child_node == .concat) {
                const children = syntax.nodeChildren(child_node.concat);
                if (children.len == 1) nested_id = children[0];
            }
            const nested = syntax.node(nested_id).*;
            if (nested == .repeat and nested.repeat.greedy == greedy and
                isSimpleRepeat(min, max) and
                isSimpleRepeat(nested.repeat.min, nested.repeat.max))
            {
                if (min == nested.repeat.min and max == nested.repeat.max or
                    nested.repeat.min == 0 and nested.repeat.max == null)
                {
                    try self.pieces.append(allocator, nested_id);
                    return;
                }
                const squashed = try self.newNode(allocator, syntax, max_nodes, .{ .repeat = .{
                    .child = nested.repeat.child,
                    .min = 0,
                    .max = null,
                    .greedy = greedy,
                } });
                try self.pieces.append(allocator, squashed);
                return;
            }
            if (self.tryCoalesceRepeat(syntax, child, min, max, greedy)) return;
            const repeated = try self.newNode(allocator, syntax, max_nodes, .{ .repeat = .{
                .child = child,
                .min = min,
                .max = max,
                .greedy = greedy,
            } });
            try self.pieces.append(allocator, repeated);
        }

        /// Centralizes parser node admission and translates the arena's 32-bit
        /// domain overflow into the configured node-limit error.
        pub fn newNode(
            self: *Self,
            allocator: std.mem.Allocator,
            syntax: *regexp.Regexp,
            max_nodes: u32,
            value: regexp.Node,
        ) (error{ OutOfMemory, NodeLimit })!regexp.NodeId {
            _ = self;
            if (syntax.nodes.items.len == max_nodes) return error.NodeLimit;
            return syntax.addNode(allocator, value) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ProgramTooLarge => error.NodeLimit,
            };
        }

        /// Finalizes the pending concatenation, then collapses this frame's
        /// alternatives to empty/single/n-ary syntax.
        fn finishFrame(
            self: *Self,
            allocator: std.mem.Allocator,
            syntax: *regexp.Regexp,
            max_nodes: u32,
        ) ReduceError!regexp.NodeId {
            const frame = self.currentFrame().*;
            const last = try self.collapsePieces(allocator, syntax, max_nodes, frame.piece_start);
            self.pieces.shrinkRetainingCapacity(frame.piece_start);

            if (self.alternatives.items.len == frame.alternative_start) return last;
            try self.alternatives.append(allocator, last);
            defer self.alternatives.shrinkRetainingCapacity(frame.alternative_start);
            const branches = self.alternatives.items[frame.alternative_start..];
            const span = syntax.addChildren(allocator, branches) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ProgramTooLarge => return error.FrameLimit,
            };
            return self.newNode(allocator, syntax, max_nodes, .{ .alternate = span }) catch |err|
                return promoteFrameError(err);
        }

        /// Converts a suffix of the piece stack to explicit empty, its singleton,
        /// or one n-ary concat node.
        fn collapsePieces(
            self: *Self,
            allocator: std.mem.Allocator,
            syntax: *regexp.Regexp,
            max_nodes: u32,
            start: usize,
        ) (error{ OutOfMemory, NodeLimit })!regexp.NodeId {
            const values = self.pieces.items[start..];
            if (values.len == 0) return self.newNode(allocator, syntax, max_nodes, .empty);
            if (values.len == 1) return values[0];
            const span = syntax.addChildren(allocator, values) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ProgramTooLarge => return error.NodeLimit,
            };
            return self.newNode(allocator, syntax, max_nodes, .{ .concat = span });
        }

        /// Attempts parser-local addition of adjacent compatible simple repeats,
        /// requiring identical atom syntax and greediness and checked bounds.
        fn tryCoalesceRepeat(
            self: *Self,
            syntax: *regexp.Regexp,
            child: regexp.NodeId,
            min: u32,
            max: ?u32,
            greedy: bool,
        ) bool {
            if (!self.hasCurrentPiece()) return false;
            const previous_id = self.lastPiece();
            const previous_node = syntax.node(previous_id).*;
            if (previous_node != .repeat or previous_node.repeat.greedy != greedy or
                !sameSimpleAtom(syntax, previous_node.repeat.child, child)) return false;
            const combined_min = std.math.add(u32, previous_node.repeat.min, min) catch return false;
            const combined_max: ?u32 = if (previous_node.repeat.max == null or max == null)
                null
            else
                std.math.add(u32, previous_node.repeat.max.?, max.?) catch return false;
            syntax.nodes.items[@intFromEnum(previous_id)].repeat.min = combined_min;
            syntax.nodes.items[@intFromEnum(previous_id)].repeat.max = combined_max;
            return true;
        }

        fn promoteFrameError(err: error{ OutOfMemory, NodeLimit }) ReduceError {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.NodeLimit => error.FrameLimit,
            };
        }
    };
}

fn isSimpleRepeat(min: u32, max: ?u32) bool {
    return (min == 0 and max == null) or
        (min == 1 and max == null) or
        (min == 0 and max == 1);
}

fn sameSimpleAtom(syntax: *const regexp.Regexp, left_id: regexp.NodeId, right_id: regexp.NodeId) bool {
    const left = syntax.node(left_id).*;
    const right = syntax.node(right_id).*;
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .literal => |literal| literal.fold == right.literal.fold and std.mem.eql(
            rune_range.Rune,
            syntax.literalRunes(literal.runes),
            syntax.literalRunes(right.literal.runes),
        ),
        .char_class => |span| rangesEqual(
            syntax.classRanges(span),
            syntax.classRanges(right.char_class),
        ),
        .any_char => |any| any.match_newline == right.any_char.match_newline,
        .any_byte => true,
        else => false,
    };
}

fn rangesEqual(left: []const rune_range.Range, right: []const rune_range.Range) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.lo != b.lo or a.hi != b.hi) return false;
    }
    return true;
}

const testing = std.testing;

test "Reducer builds n-ary precedence and preserves a group atom boundary" {
    const State = enum { outer, inner };
    const R = Reduction(State);
    var reduction: R = .{};
    defer reduction.deinit(testing.allocator);
    var syntax: regexp.Regexp = .{};
    defer syntax.deinit(testing.allocator);

    try reduction.openFrame(testing.allocator, .outer, null, 0);
    const a = try reduction.newNode(testing.allocator, &syntax, 20, .empty);
    try reduction.appendPiece(testing.allocator, a);
    try reduction.finishAlternative(testing.allocator, &syntax, 20);
    try reduction.openFrame(testing.allocator, .inner, null, 2);
    const b = try reduction.newNode(testing.allocator, &syntax, 20, .empty);
    try reduction.appendPiece(testing.allocator, b);
    const closed = try reduction.closeFrame(testing.allocator, &syntax, 20);
    try testing.expectEqual(State.inner, closed.frame.restore);
    try testing.expect(syntax.node(closed.node).* == .concat);
    try reduction.applyRepeat(testing.allocator, &syntax, 20, 1, null, true);
    const root = try reduction.finishTop(testing.allocator, &syntax, 20);
    try testing.expect(syntax.node(root).* == .alternate);
    const branches = syntax.nodeChildren(syntax.node(root).alternate);
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expect(syntax.node(branches[1]).* == .repeat);
    try testing.expectEqual(closed.node, syntax.node(branches[1]).repeat.child);
}
