//! Conservative required-literal analysis over one parsed syntax tree.
//!
//! A `Requirement` is either a small exact list of possible required byte strings
//! or a FormulaId in an append-only Boolean arena. Iterative postorder analysis
//! assigns one Requirement to every visited syntax node.
//!
//! Concatenation means both child requirements must hold (AND), while alternation
//! means either branch may match (OR). Exact lists are combined directly only
//! below fixed product/alternative limits; larger combinations are promoted to
//! formulas to bound compile cost. Literals contribute normalized encoding-aware
//! bytes when long enough; classes, repetition, emptiness, folding, and unsupported
//! syntax weaken toward `all` candidates whenever no atom is universally safe.
//!
//! Formula `all` means the regex must always be considered; `none` represents an
//! impossible language. Simplifying identities during construction keeps the
//! graph small. The analysis can add false-positive candidates but must never
//! omit a real match.
//!
//! The arena remains mutable across Filtered.Builder additions so common bytes
//! and formula structure can later be deduplicated during plan publication.

const std = @import("std");
const byte_encoding = @import("../program/byte_encoding.zig");
const parser = @import("../syntax/parser.zig");
const regexp = @import("../syntax/regexp.zig");
const unicode_data = @import("../unicode/data.zig");

const max_exact_concatenation_product: usize = 16;
const max_exact_alternatives: usize = 256;
const max_exact_class_runes: usize = 10;

/// Typed index and child-span domains for the mutable Boolean formula arena.
pub const FormulaId = enum(u32) { _ };
pub const FormulaSpan = struct { start: u32, len: u32 };
/// Mutable analysis formula. Composite spans index `RequirementAnalyzer.children`;
/// atom spans index normalized byte storage.
pub const FormulaNode = union(enum) {
    all,
    none,
    atom: regexp.ByteSpan,
    and_node: FormulaSpan,
    or_node: FormulaSpan,
};

/// Intermediate small exact string alternatives or an already generalized
/// formula root. Exact lists are owned until consumed/promoted.
const Requirement = union(enum) {
    exact: std.ArrayList(regexp.ByteSpan),
    formula: FormulaId,

    fn deinit(self: *Requirement, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exact => |*values| values.deinit(allocator),
            .formula => {},
        }
        self.* = undefined;
    }
};

/// Explicit postorder traversal: visit schedules children; apply combines their
/// stack Requirements.
const AnalyzeTask = union(enum) { visit: regexp.NodeId, apply: regexp.NodeId };

/// Append-only formula/byte arena plus reusable traversal and value stacks for
/// all patterns added to one Filtered.Builder. Iterative postorder reduction
/// leaves existing atom/formula IDs stable across analyses, allowing compile to
/// remap every published root in one deterministic plan transaction.
pub const RequirementAnalyzer = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(FormulaNode) = .empty,
    children: std.ArrayList(FormulaId) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    tasks: std.ArrayList(AnalyzeTask) = .empty,
    requirements: std.ArrayList(Requirement) = .empty,
    encoding: parser.Encoding = .utf8,

    pub fn deinit(self: *RequirementAnalyzer) void {
        for (self.requirements.items) |*info| info.deinit(self.allocator);
        self.requirements.deinit(self.allocator);
        self.tasks.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Analyzes one complete tree and returns its formula root. Exactly one
    /// Requirement must remain after iterative reduction.
    pub fn analyze(
        self: *RequirementAnalyzer,
        tree: *const regexp.Regexp,
        encoding: parser.Encoding,
    ) error{OutOfMemory}!FormulaId {
        const root = tree.root orelse return self.addNode(.none);
        const old_nodes = self.nodes.items.len;
        const old_children = self.children.items.len;
        const old_bytes = self.bytes.items.len;
        errdefer {
            for (self.requirements.items) |*info| info.deinit(self.allocator);
            self.requirements.clearRetainingCapacity();
            self.tasks.clearRetainingCapacity();
            self.nodes.shrinkRetainingCapacity(old_nodes);
            self.children.shrinkRetainingCapacity(old_children);
            self.bytes.shrinkRetainingCapacity(old_bytes);
        }
        self.encoding = encoding;
        self.tasks.clearRetainingCapacity();
        self.requirements.clearRetainingCapacity();
        try self.tasks.append(self.allocator, .{ .visit = root });
        while (self.tasks.pop()) |task| switch (task) {
            .visit => |id| try self.schedule(tree, id),
            .apply => |id| try self.apply(tree, id),
        };
        std.debug.assert(self.requirements.items.len == 1);
        var info = self.requirements.pop().?;
        return self.takeFormula(&info) catch |err| {
            info.deinit(self.allocator);
            return err;
        };
    }

    /// Pushes an apply marker followed by children in reverse order, producing an
    /// iterative postorder walk.
    fn schedule(self: *RequirementAnalyzer, tree: *const regexp.Regexp, id: regexp.NodeId) !void {
        try self.tasks.append(self.allocator, .{ .apply = id });
        switch (tree.node(id).*) {
            .concat, .alternate => |span| {
                const children = tree.nodeChildren(span);
                var index = children.len;
                while (index > 0) {
                    index -= 1;
                    try self.tasks.append(self.allocator, .{ .visit = children[index] });
                }
            },
            .repeat => |value| try self.tasks.append(self.allocator, .{ .visit = value.child }),
            .capture => |value| try self.tasks.append(self.allocator, .{ .visit = value.child }),
            else => {},
        }
    }

    /// Reduces one syntax node from already computed child Requirements and pushes
    /// exactly one parent Requirement.
    fn apply(self: *RequirementAnalyzer, tree: *const regexp.Regexp, id: regexp.NodeId) !void {
        const node = tree.node(id).*;
        var info: Requirement = switch (node) {
            .no_match => .{ .formula = try self.addNode(.none) },
            .empty, .begin_line, .end_line, .begin_text, .end_text, .word_boundary, .not_word_boundary => try self.emptyExact(),
            .literal => |literal| try self.literalExact(tree.literalRunes(literal.runes), literal.fold),
            .char_class => |span| try self.classExact(tree.classRanges(span)),
            .any_char, .any_byte => .{ .formula = try self.addNode(.all) },
            .capture => self.requirements.pop().?,
            .repeat => |repeat| blk: {
                var child = self.requirements.pop().?;
                errdefer child.deinit(self.allocator);
                if (repeat.min == 0) {
                    const all = try self.addNode(.all);
                    child.deinit(self.allocator);
                    break :blk .{ .formula = all };
                }
                break :blk .{ .formula = try self.takeFormula(&child) };
            },
            .concat => |span| try self.combineMany(tree.nodeChildren(span).len, true),
            .alternate => |span| try self.combineMany(tree.nodeChildren(span).len, false),
        };
        errdefer info.deinit(self.allocator);
        try self.requirements.append(self.allocator, info);
    }

    /// Folds the final `count` value-stack entries as conjunction for concat or
    /// disjunction for alternation, preserving child order.
    fn combineMany(self: *RequirementAnalyzer, count: usize, concat: bool) !Requirement {
        std.debug.assert(count > 0 and self.requirements.items.len >= count);
        const start = self.requirements.items.len - count;
        // Combination mutates nodes/children/bytes but never `requirements`, so this
        // suffix stays stable until the alternatives collapse back to one value.
        const values = self.requirements.items[start..];
        var result = values[0];
        var index: usize = 1;
        while (index < values.len) : (index += 1) {
            result = (if (concat)
                self.concatRequirements(result, values[index])
            else
                self.alternateRequirements(result, values[index])) catch |err| {
                for (values[index + 1 ..]) |*remaining| remaining.deinit(self.allocator);
                self.requirements.shrinkRetainingCapacity(start);
                return err;
            };
        }
        self.requirements.shrinkRetainingCapacity(start);
        return result;
    }

    /// Computes conjunction. Small exact lists form a bounded Cartesian product
    /// by byte concatenation; larger values promote to an AND formula.
    fn concatRequirements(
        self: *RequirementAnalyzer,
        left_value: Requirement,
        right_value: Requirement,
    ) !Requirement {
        var left_requirement = left_value;
        var right_requirement = right_value;
        errdefer left_requirement.deinit(self.allocator);
        errdefer right_requirement.deinit(self.allocator);
        if (left_requirement == .exact and right_requirement == .exact and
            right_requirement.exact.items.len != 0 and
            left_requirement.exact.items.len <=
                max_exact_concatenation_product / right_requirement.exact.items.len)
        {
            var values: std.ArrayList(regexp.ByteSpan) = .empty;
            errdefer values.deinit(self.allocator);
            for (left_requirement.exact.items) |left| for (right_requirement.exact.items) |right| {
                const start = std.math.cast(u32, self.bytes.items.len) orelse return error.OutOfMemory;
                try self.bytes.appendSlice(self.allocator, self.spanBytes(left));
                try self.bytes.appendSlice(self.allocator, self.spanBytes(right));
                const combined_len = std.math.add(
                    u32,
                    left.len,
                    right.len,
                ) catch return error.OutOfMemory;
                try values.append(self.allocator, .{
                    .start = start,
                    .len = combined_len,
                });
            };
            left_requirement.deinit(self.allocator);
            right_requirement.deinit(self.allocator);
            return .{ .exact = values };
        }
        const left = try self.takeFormula(&left_requirement);
        const right = try self.takeFormula(&right_requirement);
        return .{ .formula = try self.combineNode(.and_node, left, right) };
    }

    /// Computes disjunction. Small exact alternatives append directly; larger
    /// values promote to an OR formula.
    fn alternateRequirements(
        self: *RequirementAnalyzer,
        left_value: Requirement,
        right_value: Requirement,
    ) !Requirement {
        var left_requirement = left_value;
        var right_requirement = right_value;
        errdefer left_requirement.deinit(self.allocator);
        errdefer right_requirement.deinit(self.allocator);
        if (left_requirement == .exact and right_requirement == .exact and
            right_requirement.exact.items.len <= max_exact_alternatives and
            left_requirement.exact.items.len <=
                max_exact_alternatives - right_requirement.exact.items.len)
        {
            try left_requirement.exact.appendSlice(
                self.allocator,
                right_requirement.exact.items,
            );
            right_requirement.deinit(self.allocator);
            return left_requirement;
        }
        const left = try self.takeFormula(&left_requirement);
        const right = try self.takeFormula(&right_requirement);
        return .{ .formula = try self.combineNode(.or_node, left, right) };
    }

    /// Consumes an intermediate Requirement, converting exact strings to atom
    /// OR nodes and releasing its list storage.
    fn takeFormula(self: *RequirementAnalyzer, info: *Requirement) !FormulaId {
        return switch (info.*) {
            .formula => |id| id,
            .exact => |*values| blk: {
                const id = try self.orStrings(values.items);
                values.deinit(self.allocator);
                info.* = .{ .formula = id };
                break :blk id;
            },
        };
    }

    /// Converts exact byte alternatives into atom leaves joined by OR, applying
    /// minimum atom length and Boolean identities.
    fn orStrings(self: *RequirementAnalyzer, strings: []const regexp.ByteSpan) !FormulaId {
        var atoms: std.ArrayList(FormulaId) = .empty;
        defer atoms.deinit(self.allocator);
        for (strings, 0..) |candidate, index| {
            var redundant = false;
            for (strings, 0..) |other, other_index| {
                if (index == other_index) continue;
                const a = self.spanBytes(candidate);
                const b = self.spanBytes(other);
                if (std.mem.eql(u8, a, b) and other_index < index) {
                    redundant = true;
                    break;
                }
                if (b.len != 0 and b.len < a.len and std.mem.indexOf(u8, a, b) != null) {
                    redundant = true;
                    break;
                }
            }
            if (!redundant) try atoms.append(self.allocator, try self.addNode(.{ .atom = candidate }));
        }
        if (atoms.items.len == 0) return self.addNode(.none);
        if (atoms.items.len == 1) return atoms.items[0];
        return self.addChildrenNode(.or_node, atoms.items);
    }

    /// Applies Boolean identities for all/none before creating a binary
    /// composite node.
    fn combineNode(
        self: *RequirementAnalyzer,
        tag: std.meta.Tag(FormulaNode),
        left: FormulaId,
        right: FormulaId,
    ) !FormulaId {
        const left_node = self.nodes.items[@intFromEnum(left)];
        const right_node = self.nodes.items[@intFromEnum(right)];
        if (tag == .and_node) {
            if (left_node == .all) return right;
            if (right_node == .all) return left;
            if (left_node == .none or right_node == .none) return self.addNode(.none);
        } else {
            if (left_node == .all or right_node == .all) return self.addNode(.all);
            if (left_node == .none) return right;
            if (right_node == .none) return left;
        }
        return self.addChildrenNode(tag, &.{ left, right });
    }

    /// Appends a child-ID span and one composite node after 32-bit domain checks.
    fn addChildrenNode(self: *RequirementAnalyzer, tag: std.meta.Tag(FormulaNode), values: []const FormulaId) !FormulaId {
        const start = std.math.cast(u32, self.children.items.len) orelse return error.OutOfMemory;
        try self.children.appendSlice(self.allocator, values);
        return self.addNode(switch (tag) {
            .and_node => .{ .and_node = .{
                .start = start,
                .len = std.math.cast(u32, values.len) orelse return error.OutOfMemory,
            } },
            .or_node => .{ .or_node = .{
                .start = start,
                .len = std.math.cast(u32, values.len) orelse return error.OutOfMemory,
            } },
            else => unreachable,
        });
    }

    fn addNode(self: *RequirementAnalyzer, node: FormulaNode) !FormulaId {
        const id = std.math.cast(u32, self.nodes.items.len) orelse return error.OutOfMemory;
        try self.nodes.append(self.allocator, node);
        return @enumFromInt(id);
    }

    /// Represents the exact empty string as a zero-length ByteSpan; later
    /// concatenation can extend it, while atom publication will discard it.
    fn emptyExact(self: *RequirementAnalyzer) !Requirement {
        var values: std.ArrayList(regexp.ByteSpan) = .empty;
        errdefer values.deinit(self.allocator);
        const start = std.math.cast(u32, self.bytes.items.len) orelse
            return error.OutOfMemory;
        try values.append(self.allocator, .{ .start = start, .len = 0 });
        return .{ .exact = values };
    }

    /// Encodes and lowercases one literal into normalized atom bytes. Folded
    /// literals use canonical Unicode lowercase so scanning can normalize input
    /// identically.
    fn literalExact(self: *RequirementAnalyzer, runes: []const u32, fold: bool) !Requirement {
        _ = fold;
        const start = std.math.cast(u32, self.bytes.items.len) orelse return error.OutOfMemory;
        for (runes) |rune| try self.appendRune(self.lowerRune(rune));
        var values: std.ArrayList(regexp.ByteSpan) = .empty;
        errdefer values.deinit(self.allocator);
        try values.append(self.allocator, .{
            .start = start,
            .len = std.math.cast(u32, self.bytes.items.len - start) orelse
                return error.OutOfMemory,
        });
        return .{ .exact = values };
    }

    /// Enumerates a character class only when its cardinality is small enough for
    /// exact one-rune atom alternatives; larger classes provide no useful required
    /// literal and become an always-candidate formula.
    fn classExact(self: *RequirementAnalyzer, ranges: []const @import("../syntax/rune_range.zig").Range) !Requirement {
        var count: usize = 0;
        for (ranges) |range| {
            count = std.math.add(usize, count, range.hi - range.lo + 1) catch
                return .{ .formula = try self.addNode(.all) };
            if (count > max_exact_class_runes)
                return .{ .formula = try self.addNode(.all) };
        }
        var values: std.ArrayList(regexp.ByteSpan) = .empty;
        errdefer values.deinit(self.allocator);
        for (ranges) |range| {
            var rune = range.lo;
            while (rune <= range.hi) : (rune += 1) {
                const start = std.math.cast(u32, self.bytes.items.len) orelse return error.OutOfMemory;
                try self.appendRune(self.lowerRune(rune));
                try values.append(self.allocator, .{
                    .start = start,
                    .len = std.math.cast(u32, self.bytes.items.len - start) orelse
                        return error.OutOfMemory,
                });
            }
        }
        return .{ .exact = values };
    }

    fn lowerRune(self: *const RequirementAnalyzer, rune: u32) u32 {
        if (self.encoding == .latin1)
            return if (rune >= 'A' and rune <= 'Z') rune + ('a' - 'A') else rune;
        return unicode_data.toLower(rune);
    }

    fn appendRune(self: *RequirementAnalyzer, rune: u32) !void {
        if (self.encoding == .latin1) {
            try self.bytes.append(self.allocator, @truncate(rune));
            return;
        }
        const encoded = byte_encoding.encodeRune(rune);
        for (encoded.ranges[0..encoded.len]) |range| {
            std.debug.assert(range.lo == range.hi);
            try self.bytes.append(self.allocator, range.lo);
        }
    }

    /// Borrows normalized analyzer byte storage for publication sorting/copying.
    pub fn spanBytes(self: *const RequirementAnalyzer, span: regexp.ByteSpan) []const u8 {
        const start: usize = span.start;
        return self.bytes.items[start .. start + span.len];
    }
};
