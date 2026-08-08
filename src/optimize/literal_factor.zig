//! Radix-style factoring of ordered captureless literal alternatives.
//!
//! Each `Branch` is a literal node plus the number of already consumed runes.
//! `factorBranches` first emits any prefix common to the whole adjacent slice.
//! Otherwise it partitions only consecutive branches with the same next rune,
//! recursively factors each partition, and appends partitions in original order.
//! This shares dictionary structure without sorting or changing alternation
//! priority.
//!
//! A group whose remaining alternatives are distinct single runes can become a
//! character class because all alternatives consume equal width and have no
//! captures. Empty suffixes are represented explicitly so prefix relationships
//! such as `a|ab` retain acceptance priority.
//!
//! Recursion is used only inside this bounded transformation and has a fixed
//! depth cap independent of user pattern depth. At the cap, branches are
//! materialized as an equivalent flat alternation. All produced nodes obey the
//! caller's output-node limit.

const std = @import("std");
const regexp = @import("../syntax/regexp.zig");
const rune_range = @import("../syntax/rune_range.zig");

pub const Error = error{ OutOfMemory, ProgramTooLarge, InvalidSyntax };

const maximum_factor_depth: u8 = 128;

/// One source literal and the rune offset already emitted by ancestor prefixes.
const Branch = struct {
    id: regexp.NodeId,
    offset: usize = 0,
};

/// Attempts to replace an ordered literal-alternative slice with shared-prefix
/// syntax. Returns null when children are not uniformly folded literals.
pub fn factor(
    allocator: std.mem.Allocator,
    tree: *regexp.Regexp,
    ids: []const regexp.NodeId,
    max_nodes: u32,
) Error!?regexp.NodeId {
    if (ids.len < 2) return null;
    var fold: ?bool = null;
    const branches = try allocator.alloc(Branch, ids.len);
    defer allocator.free(branches);
    for (ids, branches) |id, *branch| {
        const node = tree.node(id).*;
        if (node != .literal) return null;
        if (fold == null) {
            fold = node.literal.fold;
        } else if (fold.? != node.literal.fold) {
            return null;
        }
        branch.* = .{ .id = id };
    }
    var worker = Worker{
        .allocator = allocator,
        .tree = tree,
        .max_nodes = max_nodes,
        .fold = fold.?,
    };
    return try worker.factorBranches(branches, 0);
}

/// Recursive factoring context writing directly into the destination syntax
/// arena under its node limit. Branch offsets track already emitted prefixes;
/// temporary branch/list owners are scoped to each recursion level, while every
/// accepted node is immediately published in source priority order.
const Worker = struct {
    allocator: std.mem.Allocator,
    tree: *regexp.Regexp,
    max_nodes: u32,
    fold: bool,

    /// Factors one nonempty adjacent branch interval without reordering it.
    /// A whole-slice prefix is emitted once; otherwise equal-next-rune runs are
    /// recursively partitioned, with equal-width singleton suffixes collapsed
    /// to a class. The fixed depth ceiling materializes a flat equivalent.
    fn factorBranches(
        self: *@This(),
        branches: []const Branch,
        depth: u8,
    ) Error!regexp.NodeId {
        std.debug.assert(branches.len != 0);
        if (branches.len == 1) return self.materialize(branches[0]);
        if (depth == maximum_factor_depth) return self.flat(branches);

        const shared = self.sharedPrefix(branches);
        if (shared != 0) {
            const prefix = try self.literal(branches[0], shared);
            const advanced = try self.allocator.alloc(Branch, branches.len);
            defer self.allocator.free(advanced);
            for (branches, advanced) |branch, *next|
                next.* = .{ .id = branch.id, .offset = branch.offset + shared };
            const suffix = try self.factorBranches(advanced, depth + 1);
            if (self.tree.node(suffix).* == .empty) return prefix;
            return self.concat(prefix, suffix);
        }

        if (try self.singletonClass(branches)) |class| return class;

        var children: std.ArrayList(regexp.NodeId) = .empty;
        defer children.deinit(self.allocator);
        var index: usize = 0;
        while (index < branches.len) {
            const current = self.runes(branches[index]);
            if (current.len == 0) {
                try children.append(self.allocator, try self.addNode(.empty));
                index += 1;
                while (index < branches.len and self.runes(branches[index]).len == 0)
                    index += 1;
                continue;
            }
            var end = index + 1;
            while (end < branches.len) : (end += 1) {
                const next = self.runes(branches[end]);
                if (next.len == 0 or next[0] != current[0]) break;
            }
            try children.append(
                self.allocator,
                try self.factorBranches(branches[index..end], depth + 1),
            );
            index = end;
        }
        if (children.items.len == 1) return children.items[0];
        const span = try self.tree.addChildren(self.allocator, children.items);
        return self.addNode(.{ .alternate = span });
    }

    fn sharedPrefix(self: *const @This(), branches: []const Branch) usize {
        var limit: usize = std.math.maxInt(usize);
        for (branches) |branch| limit = @min(limit, self.runes(branch).len);
        var shared: usize = 0;
        while (shared < limit) : (shared += 1) {
            const first = self.runes(branches[0])[shared];
            for (branches[1..]) |branch| {
                if (self.runes(branch)[shared] != first) return shared;
            }
        }
        return shared;
    }

    /// Converts distinct one-rune suffixes to a normalized class when folding is
    /// off; priority is unobservable because every branch has equal width.
    fn singletonClass(
        self: *@This(),
        branches: []const Branch,
    ) Error!?regexp.NodeId {
        if (self.fold) return null;
        var ranges: std.ArrayList(rune_range.Range) = .empty;
        defer ranges.deinit(self.allocator);
        try ranges.ensureTotalCapacity(self.allocator, branches.len);
        for (branches) |branch| {
            const remaining = self.runes(branch);
            if (remaining.len != 1) return null;
            ranges.appendAssumeCapacity(.{ .lo = remaining[0], .hi = remaining[0] });
        }
        const count = rune_range.normalize(ranges.items) catch return error.InvalidSyntax;
        const span = try self.tree.addRanges(self.allocator, ranges.items[0..count]);
        return try self.addNode(.{ .char_class = span });
    }

    fn flat(self: *@This(), branches: []const Branch) Error!regexp.NodeId {
        var children: std.ArrayList(regexp.NodeId) = .empty;
        defer children.deinit(self.allocator);
        try children.ensureTotalCapacity(self.allocator, branches.len);
        for (branches) |branch| children.appendAssumeCapacity(try self.materialize(branch));
        const span = try self.tree.addChildren(self.allocator, children.items);
        return self.addNode(.{ .alternate = span });
    }

    fn concat(
        self: *@This(),
        prefix: regexp.NodeId,
        suffix: regexp.NodeId,
    ) Error!regexp.NodeId {
        const span = try self.tree.addChildren(self.allocator, &.{ prefix, suffix });
        return self.addNode(.{ .concat = span });
    }

    fn materialize(self: *@This(), branch: Branch) Error!regexp.NodeId {
        const remaining_len = self.runes(branch).len;
        if (remaining_len == 0) return self.addNode(.empty);
        if (branch.offset == 0) return branch.id;
        return self.literal(branch, remaining_len);
    }

    fn literal(self: *@This(), branch: Branch, len: usize) Error!regexp.NodeId {
        if (len == 0) return self.addNode(.empty);
        const source = self.tree.node(branch.id).literal.runes;
        const span = self.tree.copyRunes(self.allocator, source, branch.offset, len) catch |err| switch (err) {
            error.InvalidSpan => return error.InvalidSyntax,
            else => |other| return other,
        };
        return self.addNode(.{ .literal = .{ .runes = span, .fold = self.fold } });
    }

    fn runes(self: *const @This(), branch: Branch) []const rune_range.Rune {
        const literal_node = self.tree.node(branch.id).literal;
        return self.tree.literalRunes(literal_node.runes)[branch.offset..];
    }

    fn addNode(self: *@This(), node: regexp.Node) Error!regexp.NodeId {
        if (self.tree.nodes.items.len >= self.max_nodes) return error.ProgramTooLarge;
        return self.tree.addNode(self.allocator, node);
    }
};
