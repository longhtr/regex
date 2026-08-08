//! Priority-preserving syntax simplification into a fresh arena.
//!
//! The optimizer never mutates parser output. An explicit postorder task stack
//! copies leaves and rebuilds parent nodes after children have mapped into the
//! output arena. `mapped[input_id]` therefore records exactly one output node for
//! every visited source node and also detects malformed internal syntax.
//!
//! Rewrites are intentionally narrow and locally provable:
//!
//! - remove `{0}` and `{1,1}` identities;
//! - merge adjacent literal runs with equal folding policy;
//! - coalesce adjacent repeats of the same simple atom only when greediness and
//!   bounds compose without overflow;
//! - turn eligible single-rune literal alternatives into one class;
//! - factor adjacent captureless literal prefixes without reordering branches.
//!
//! Alternation order and greedy/lazy split order are observable in leftmost-first
//! matching. Captures also make path structure observable. Any case outside the
//! proof conditions is copied unchanged. Node limits apply to the output arena,
//! and every partial allocation is transactionally released on failure.

const std = @import("std");
const literal_factor = @import("literal_factor.zig");
const regexp = @import("../syntax/regexp.zig");
const rune_range = @import("../syntax/rune_range.zig");

pub const Error = std.mem.Allocator.Error || error{ ProgramTooLarge, InvalidSyntax };

/// Postorder traversal marker: first encounter schedules children, second
/// encounter rebuilds the node from mapped children.
const Task = struct { id: regexp.NodeId, finish: bool };

/// Rebuilds the reachable input tree into a separate optimized arena. The input
/// remains untouched and the caller owns the returned Regexp.
pub fn simplify(
    allocator: std.mem.Allocator,
    input: *const regexp.Regexp,
    max_nodes: u32,
) Error!regexp.Regexp {
    const root = input.root orelse return error.InvalidSyntax;
    var worker = Worker{
        .allocator = allocator,
        .input = input,
        .max_nodes = max_nodes,
        .mapped = try allocator.alloc(?regexp.NodeId, input.nodes.items.len),
    };
    defer allocator.free(worker.mapped);
    @memset(worker.mapped, null);
    errdefer worker.output.deinit(allocator);
    try worker.run(root);
    worker.output.root = worker.mapped[@intFromEnum(root)];
    worker.output.capture_count = input.capture_count;

    // Rewrites can orphan already-built children. Compact once so the retained
    // reverse recipe contains only nodes reachable from the simplified root.
    var compacted = try cloneReachable(allocator, &worker.output, max_nodes);
    worker.output.deinit(allocator);
    compacted.capture_count = input.capture_count;
    return compacted;
}

/// One iterative simplification transaction. Visit/reduce tasks build output in
/// postorder while `mapped` records each source NodeId's replacement; temporary
/// factored nodes may be created during reduction, then only the reachable root
/// is compacted into the published syntax arena.
const Worker = struct {
    allocator: std.mem.Allocator,
    input: *const regexp.Regexp,
    max_nodes: u32,
    output: regexp.Regexp = .{},
    mapped: []?regexp.NodeId,
    tasks: std.ArrayList(Task) = .empty,
    ids: std.ArrayList(regexp.NodeId) = .empty,
    scratch_ids: std.ArrayList(regexp.NodeId) = .empty,
    scratch_runes: std.ArrayList(rune_range.Rune) = .empty,

    /// Evaluates the reachable input tree in explicit postorder. A source node
    /// is transformed exactly once after all of its child replacement IDs exist.
    fn run(self: *@This(), root: regexp.NodeId) Error!void {
        defer self.scratch_runes.deinit(self.allocator);
        defer self.scratch_ids.deinit(self.allocator);
        defer self.ids.deinit(self.allocator);
        defer self.tasks.deinit(self.allocator);
        try self.tasks.append(self.allocator, .{ .id = root, .finish = false });
        while (self.tasks.pop()) |task| {
            const index = @intFromEnum(task.id);
            if (self.mapped[index] != null) continue;
            if (!task.finish) {
                try self.tasks.append(self.allocator, .{ .id = task.id, .finish = true });
                try self.scheduleChildren(self.input.node(task.id).*);
                continue;
            }
            self.mapped[index] = try self.transform(self.input.node(task.id).*);
        }
    }

    /// Pushes child visits in reverse source order so the LIFO worklist rebuilds
    /// n-ary parents deterministically without recursive descent.
    fn scheduleChildren(self: *@This(), node: regexp.Node) Error!void {
        switch (node) {
            .capture => |capture| try self.pushChild(capture.child),
            .repeat => |repeat| try self.pushChild(repeat.child),
            .concat, .alternate => |span| {
                const children = self.input.nodeChildren(span);
                var index = children.len;
                while (index > 0) {
                    index -= 1;
                    try self.pushChild(children[index]);
                }
            },
            else => {},
        }
    }

    fn pushChild(self: *@This(), id: regexp.NodeId) Error!void {
        if (self.mapped[@intFromEnum(id)] == null)
            try self.tasks.append(self.allocator, .{ .id = id, .finish = false });
    }

    fn mappedId(self: *const @This(), id: regexp.NodeId) Error!regexp.NodeId {
        return self.mapped[@intFromEnum(id)] orelse error.InvalidSyntax;
    }

    fn addNode(self: *@This(), node: regexp.Node) Error!regexp.NodeId {
        if (self.output.nodes.items.len >= self.max_nodes) return error.ProgramTooLarge;
        return self.output.addNode(self.allocator, node);
    }

    /// Rebuilds one node after all child mappings exist, dispatching only the
    /// rewrite family appropriate to its active tag.
    fn transform(self: *@This(), node: regexp.Node) Error!regexp.NodeId {
        return switch (node) {
            .no_match => self.addNode(.no_match),
            .empty => self.addNode(.empty),
            .literal => |literal| self.copyLiteral(literal),
            .char_class => |span| self.copyClass(span),
            .concat => |span| self.makeConcat(span),
            .alternate => |span| self.makeAlternate(span),
            .repeat => |repeat| self.makeRepeat(repeat),
            .capture => |capture| self.copyCapture(capture),
            .begin_line => self.addNode(.begin_line),
            .end_line => self.addNode(.end_line),
            .begin_text => self.addNode(.begin_text),
            .end_text => self.addNode(.end_text),
            .word_boundary => self.addNode(.word_boundary),
            .not_word_boundary => self.addNode(.not_word_boundary),
            .any_char => |any| self.addNode(.{ .any_char = any }),
            .any_byte => self.addNode(.any_byte),
        };
    }

    fn copyLiteral(self: *@This(), literal: regexp.Literal) Error!regexp.NodeId {
        return self.literalNode(self.input.literalRunes(literal.runes), literal.fold);
    }

    fn literalNode(
        self: *@This(),
        runes: []const rune_range.Rune,
        fold: bool,
    ) Error!regexp.NodeId {
        if (runes.len == 0) return self.addNode(.empty);
        const span = try self.output.addRunes(self.allocator, runes);
        return self.addNode(.{ .literal = .{ .runes = span, .fold = fold } });
    }

    fn copyClass(self: *@This(), span: regexp.RangeSpan) Error!regexp.NodeId {
        const copied = try self.output.addRanges(self.allocator, self.input.classRanges(span));
        return self.addNode(.{ .char_class = copied });
    }

    fn copyCapture(self: *@This(), capture: regexp.Capture) Error!regexp.NodeId {
        const name = if (capture.name) |span|
            try self.output.addName(self.allocator, self.input.captureName(span))
        else
            null;
        return self.addNode(.{ .capture = .{
            .child = try self.mappedId(capture.child),
            .index = capture.index,
            .name = name,
        } });
    }

    /// Applies only language- and priority-neutral repeat identities, leaving
    /// all other bounds and greediness attached to the mapped child unchanged.
    fn makeRepeat(self: *@This(), repeat: regexp.Repeat) Error!regexp.NodeId {
        if (repeat.max != null and repeat.max.? == 0) return self.addNode(.empty);
        const child = try self.mappedId(repeat.child);
        if (repeat.min == 1 and repeat.max == 1) return child;
        if (self.output.node(child).* == .no_match) {
            return if (repeat.min == 0) self.addNode(.empty) else child;
        }
        return self.addNode(.{ .repeat = .{
            .child = child,
            .min = repeat.min,
            .max = repeat.max,
            .greedy = repeat.greedy,
        } });
    }

    /// Rebuilds concat after child mapping, removing empty identities and merging
    /// compatible adjacent literals/repeats without crossing capture boundaries.
    fn makeConcat(self: *@This(), span: regexp.NodeSpan) Error!regexp.NodeId {
        self.ids.clearRetainingCapacity();
        for (self.input.nodeChildren(span)) |old_child| {
            const child = try self.mappedId(old_child);
            const node = self.output.node(child).*;
            if (node == .no_match) return child;
            if (node == .empty) continue;
            if (node == .concat) {
                try self.ids.appendSlice(self.allocator, self.output.nodeChildren(node.concat));
            } else {
                try self.ids.append(self.allocator, child);
            }
        }
        if (self.ids.items.len == 0) return self.addNode(.empty);

        self.scratch_ids.clearRetainingCapacity();
        for (self.ids.items) |child| {
            if (self.scratch_ids.getLastOrNull()) |previous| {
                if (try self.mergeLiterals(previous, child)) |merged| {
                    self.scratch_ids.items[self.scratch_ids.items.len - 1] = merged;
                    continue;
                }
                if (try self.mergeRepeats(previous, child)) |merged| {
                    self.scratch_ids.items[self.scratch_ids.items.len - 1] = merged;
                    continue;
                }
            }
            try self.scratch_ids.append(self.allocator, child);
        }
        if (self.scratch_ids.items.len == 1) return self.scratch_ids.items[0];
        const children = try self.output.addChildren(self.allocator, self.scratch_ids.items);
        return self.addNode(.{ .concat = children });
    }

    /// Concatenates adjacent literal rune runs only when their fold policy agrees;
    /// arena-copy helpers preserve source slices across destination growth.
    fn mergeLiterals(
        self: *@This(),
        left_id: regexp.NodeId,
        right_id: regexp.NodeId,
    ) Error!?regexp.NodeId {
        const left = self.output.node(left_id).*;
        const right = self.output.node(right_id).*;
        if (left != .literal or right != .literal or left.literal.fold != right.literal.fold)
            return null;
        self.scratch_runes.clearRetainingCapacity();
        try self.scratch_runes.appendSlice(self.allocator, self.output.literalRunes(left.literal.runes));
        try self.scratch_runes.appendSlice(self.allocator, self.output.literalRunes(right.literal.runes));
        return try self.literalNode(self.scratch_runes.items, left.literal.fold);
    }

    /// Adds adjacent repeat bounds for an identical simple atom and identical
    /// greediness. Checked bound arithmetic declines the rewrite on overflow.
    fn mergeRepeats(
        self: *@This(),
        left_id: regexp.NodeId,
        right_id: regexp.NodeId,
    ) Error!?regexp.NodeId {
        const left_node = self.output.node(left_id).*;
        const right_node = self.output.node(right_id).*;
        if (left_node != .repeat or right_node != .repeat) return null;
        const left = left_node.repeat;
        const right = right_node.repeat;
        if (left.greedy != right.greedy or !self.sameSimpleAtom(left.child, right.child)) return null;
        const minimum = std.math.add(u32, left.min, right.min) catch return null;
        const maximum: ?u32 = if (left.max == null or right.max == null)
            null
        else
            std.math.add(u32, left.max.?, right.max.?) catch return null;
        return try self.addNode(.{ .repeat = .{
            .child = left.child,
            .min = minimum,
            .max = maximum,
            .greedy = left.greedy,
        } });
    }

    /// Compares only atom forms whose repeated concatenation can be merged
    /// without exposing captures, assertions, or path structure.
    fn sameSimpleAtom(self: *const @This(), left_id: regexp.NodeId, right_id: regexp.NodeId) bool {
        const left = self.output.node(left_id).*;
        const right = self.output.node(right_id).*;
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .literal => |literal| blk: {
                const other = right.literal;
                break :blk literal.fold == other.fold and
                    std.mem.eql(rune_range.Rune, self.output.literalRunes(literal.runes), self.output.literalRunes(other.runes));
            },
            .char_class => |span| rangesEqual(
                self.output.classRanges(span),
                self.output.classRanges(right.char_class),
            ),
            .any_char => |any| any.match_newline == right.any_char.match_newline,
            .any_byte => true,
            else => false,
        };
    }

    /// Rebuilds ordered alternation, trying only priority-safe literal class/radix
    /// factoring before falling back to unchanged mapped branches.
    fn makeAlternate(self: *@This(), span: regexp.NodeSpan) Error!regexp.NodeId {
        self.ids.clearRetainingCapacity();
        for (self.input.nodeChildren(span)) |old_child| {
            const child = try self.mappedId(old_child);
            const node = self.output.node(child).*;
            if (node == .no_match) continue;
            if (node == .alternate) {
                try self.ids.appendSlice(self.allocator, self.output.nodeChildren(node.alternate));
            } else {
                try self.ids.append(self.allocator, child);
            }
        }
        if (self.ids.items.len == 0) return self.addNode(.no_match);
        if (self.ids.items.len == 1) return self.ids.items[0];
        if (try self.factorLiteralAlternatives()) |factored| return factored;
        const children = try self.output.addChildren(self.allocator, self.ids.items);
        return self.addNode(.{ .alternate = children });
    }

    /// Runs the bounded radix factorer on current mapped child IDs, then clones
    /// only its reachable result into the final output arena.
    fn factorLiteralAlternatives(self: *@This()) Error!?regexp.NodeId {
        return literal_factor.factor(
            self.allocator,
            &self.output,
            self.ids.items,
            self.max_nodes,
        );
    }
};

fn rangesEqual(left: []const rune_range.Range, right: []const rune_range.Range) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.lo != b.lo or a.hi != b.hi) return false;
    }
    return true;
}

/// Copies the temporary factored arena's reachable subtree into a compact arena;
/// unreachable construction nodes are intentionally discarded.
fn cloneReachable(
    allocator: std.mem.Allocator,
    input: *const regexp.Regexp,
    max_nodes: u32,
) Error!regexp.Regexp {
    const root = input.root orelse return error.InvalidSyntax;
    var output: regexp.Regexp = .{};
    errdefer output.deinit(allocator);
    const mapped = try allocator.alloc(?regexp.NodeId, input.nodes.items.len);
    defer allocator.free(mapped);
    @memset(mapped, null);
    var tasks: std.ArrayList(Task) = .empty;
    defer tasks.deinit(allocator);
    try tasks.append(allocator, .{ .id = root, .finish = false });
    while (tasks.pop()) |task| {
        const index = @intFromEnum(task.id);
        if (mapped[index] != null) continue;
        const node = input.node(task.id).*;
        if (!task.finish) {
            try tasks.append(allocator, .{ .id = task.id, .finish = true });
            switch (node) {
                .capture => |capture| try tasks.append(allocator, .{ .id = capture.child, .finish = false }),
                .repeat => |repeat| try tasks.append(allocator, .{ .id = repeat.child, .finish = false }),
                .concat, .alternate => |span| {
                    const children = input.nodeChildren(span);
                    var child_index = children.len;
                    while (child_index > 0) {
                        child_index -= 1;
                        if (mapped[@intFromEnum(children[child_index])] == null)
                            try tasks.append(allocator, .{ .id = children[child_index], .finish = false });
                    }
                },
                else => {},
            }
            continue;
        }
        if (output.nodes.items.len >= max_nodes) return error.ProgramTooLarge;
        mapped[index] = try cloneNode(allocator, input, &output, mapped, node);
    }
    output.root = mapped[@intFromEnum(root)];
    output.capture_count = input.capture_count;
    return output;
}

/// Rewrites one temporary factored node after all of its children have final
/// NodeIds, copying typed side-arena payloads as needed.
fn cloneNode(
    allocator: std.mem.Allocator,
    input: *const regexp.Regexp,
    output: *regexp.Regexp,
    mapped: []const ?regexp.NodeId,
    node: regexp.Node,
) Error!regexp.NodeId {
    const cloned: regexp.Node = switch (node) {
        .literal => |literal| .{ .literal = .{
            .runes = try output.addRunes(allocator, input.literalRunes(literal.runes)),
            .fold = literal.fold,
        } },
        .char_class => |span| .{ .char_class = try output.addRanges(allocator, input.classRanges(span)) },
        .concat, .alternate => |span| blk: {
            const children = try allocator.alloc(regexp.NodeId, span.len);
            defer allocator.free(children);
            for (input.nodeChildren(span), children) |child, *destination|
                destination.* = mapped[@intFromEnum(child)] orelse return error.InvalidSyntax;
            const copied = try output.addChildren(allocator, children);
            break :blk if (node == .concat) .{ .concat = copied } else .{ .alternate = copied };
        },
        .repeat => |repeat| .{ .repeat = .{
            .child = mapped[@intFromEnum(repeat.child)] orelse return error.InvalidSyntax,
            .min = repeat.min,
            .max = repeat.max,
            .greedy = repeat.greedy,
        } },
        .capture => |capture| .{ .capture = .{
            .child = mapped[@intFromEnum(capture.child)] orelse return error.InvalidSyntax,
            .index = capture.index,
            .name = if (capture.name) |name| try output.addName(allocator, input.captureName(name)) else null,
        } },
        else => node,
    };
    return output.addNode(allocator, cloned);
}

const parser = @import("../syntax/parser.zig");
const testing = std.testing;

fn parse(pattern: []const u8) !regexp.Regexp {
    const result = try parser.parse(testing.allocator, pattern, .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    return switch (result) {
        .success => |tree| tree,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

test "Simplifier applies only capture-free priority-safe rewrites" {
    for ([_]struct { pattern: []const u8, root_tag: std.meta.Tag(regexp.Node) }{
        .{ .pattern = "a|b", .root_tag = .char_class },
        .{ .pattern = "abc|abd", .root_tag = .concat },
        .{ .pattern = "a*a*", .root_tag = .repeat },
        .{ .pattern = "a*?a*", .root_tag = .concat },
        .{ .pattern = "(a*)a*", .root_tag = .concat },
    }) |case| {
        var input = try parse(case.pattern);
        defer input.deinit(testing.allocator);
        var output = try simplify(testing.allocator, &input, 100_000);
        defer output.deinit(testing.allocator);
        try testing.expectEqual(case.root_tag, std.meta.activeTag(output.node(output.root.?).*));
    }
}

fn appendDiverseDictionary(
    allocator: std.mem.Allocator,
    pattern: *std.ArrayList(u8),
    count: usize,
) !void {
    const prefixes = [_][]const u8{
        "amber", "ambition", "amble", "azure", "binary", "birch", "catalog", "cater",
    };
    const tails = [_][]const u8{ "", "ing", "ment", "stone" };
    const group_size = (count + prefixes.len - 1) / prefixes.len;
    for (0..count) |index| {
        if (index != 0) try pattern.append(allocator, '|');
        const group = @min(index / group_size, prefixes.len - 1);
        const local = index % group_size;
        var buffer: [48]u8 = undefined;
        const word = try std.fmt.bufPrint(&buffer, "{s}{d:0>4}{s}", .{
            prefixes[group], local, tails[local % tails.len],
        });
        try pattern.appendSlice(allocator, word);
    }
}

test "Literal radix factoring shares nested dictionary prefixes" {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(testing.allocator);
    for (0..100) |index| {
        if (index != 0) try pattern.append(testing.allocator, '|');
        var buffer: [16]u8 = undefined;
        const word = try std.fmt.bufPrint(&buffer, "route{d:0>3}", .{index});
        try pattern.appendSlice(testing.allocator, word);
    }

    var input = try parse(pattern.items);
    defer input.deinit(testing.allocator);
    var output = try simplify(testing.allocator, &input, 100_000);
    defer output.deinit(testing.allocator);

    try testing.expect(output.runes.items.len * 2 < input.runes.items.len);
    try testing.expectEqual(
        std.meta.Tag(regexp.Node).concat,
        std.meta.activeTag(output.node(output.root.?).*),
    );
}

fn allocationSimplify(allocator: std.mem.Allocator, input: *const regexp.Regexp) !void {
    var output = try simplify(allocator, input, 100_000);
    output.deinit(allocator);
}

test "Literal factoring owns diverse prefix topology beyond prior campaign bounds" {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(testing.allocator);
    try appendDiverseDictionary(testing.allocator, &pattern, 3072);

    var input = try parse(pattern.items);
    defer input.deinit(testing.allocator);
    var output = try simplify(testing.allocator, &input, 100_000);
    defer output.deinit(testing.allocator);

    try testing.expect(output.runes.items.len < input.runes.items.len);
}

test "Simplifier owns every allocation failure" {
    var input = try parse("amber|ambition|amble|azure|binary|birch|catalog|cater|cattle|delta|delve|z");
    defer input.deinit(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, allocationSimplify, .{&input});
}
