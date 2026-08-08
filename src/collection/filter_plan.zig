//! Immutable execution plan published from mutable required-atom analysis.
//!
//! The builder's formula graph may contain repeated atoms, nested same-operator
//! nodes, and intermediates unreachable from final regex roots. Publication walks
//! only reachable roots, extracts atom candidates, normalizes/deduplicates bytes
//! in first-occurrence order, and remaps formulas to compact postorder PlanNodes.
//!
//! AND/OR nodes are flattened where associativity permits and exact equivalent
//! children are interned. AND atoms are ordered by a static selectivity heuristic
//! (longer/more distinctive first) to improve candidate rejection, while formula
//! truth remains unchanged. Identity nodes are removed during remapping.
//!
//! The final plan contains normalized atom slices, a Teddy scanner, one formula
//! root per Regex, and a node order in which every child precedes its parent.
//! `evaluateAll` can therefore compute each node exactly once in a linear pass;
//! candidate queries become O(1) root reads.

const std = @import("std");
const teddy = @import("../literal/teddy.zig");
const parser = @import("../syntax/parser.zig");
const regexp = @import("../syntax/regexp.zig");
const required_atoms = @import("required_atoms.zig");

pub const FormulaId = required_atoms.FormulaId;
pub const RequirementAnalyzer = required_atoms.RequirementAnalyzer;
const Span = required_atoms.FormulaSpan;

/// Immutable postorder formula node. Composite spans index `children`, and atom
/// IDs index the published atom table/scanner. Analyzer all/none identities are
/// represented by absent roots/children and do not survive publication.
const PlanNode = union(enum) {
    atom: u32,
    and_node: Span,
    or_node: Span,
};

/// Owned normalized atoms, scanner, compact formula graph, and one optional root
/// per insertion-order Regex.
pub const FilterPlan = struct {
    allocator: std.mem.Allocator,
    nodes: []PlanNode,
    children: []FormulaId,
    atom_bytes: []u8,
    atoms: [][]const u8,
    roots: []?FormulaId,
    scanner: teddy.Scanner,
    encoding: parser.Encoding,

    pub fn deinit(self: *FilterPlan) void {
        self.scanner.deinit();
        if (self.roots.len != 0) self.allocator.free(self.roots);
        if (self.atoms.len != 0) self.allocator.free(self.atoms);
        if (self.atom_bytes.len != 0) self.allocator.free(self.atom_bytes);
        if (self.children.len != 0) self.allocator.free(self.children);
        if (self.nodes.len != 0) self.allocator.free(self.nodes);
        self.* = undefined;
    }

    /// Evaluates every formula node exactly once for one matched-atom set.
    /// Candidate root reads are O(1) after this pass.
    pub fn evaluateAll(self: *const FilterPlan, values: []bool, matched: []const bool) void {
        std.debug.assert(values.len == self.nodes.len);
        for (self.nodes, 0..) |node, index| values[index] = switch (node) {
            .atom => |atom| matched[atom],
            .and_node => |span| blk: {
                const start: usize = span.start;
                for (self.children[start .. start + span.len]) |child|
                    if (!values[@intFromEnum(child)]) break :blk false;
                break :blk true;
            },
            .or_node => |span| blk: {
                const start: usize = span.start;
                for (self.children[start .. start + span.len]) |child|
                    if (values[@intFromEnum(child)]) break :blk true;
                break :blk false;
            },
        };
    }

    /// Reads one Regex root after `evaluateAll`; an absent root means analysis
    /// proved no usable atom requirement, so the Regex is always a candidate.
    pub fn candidate(_: *const FilterPlan, root: ?FormulaId, values: []const bool) bool {
        const root_id = root orelse return true;
        return values[@intFromEnum(root_id)];
    }
};

/// Analyzer atom occurrence with source order retained for deterministic
/// deduplication.
const AtomCandidate = struct {
    source_index: u32,
    span: regexp.ByteSpan,
};

/// One lexical atom representative plus its first source occurrence and temporary
/// lexicographic ID.
const UniqueAtom = struct {
    span: regexp.ByteSpan,
    first_source: u32,
    lexical_id: u32,
};

fn atomLessThan(analyzer: *const RequirementAnalyzer, left: AtomCandidate, right: AtomCandidate) bool {
    return switch (std.mem.order(
        u8,
        analyzer.spanBytes(left.span),
        analyzer.spanBytes(right.span),
    )) {
        .lt => true,
        .gt => false,
        .eq => left.source_index < right.source_index,
    };
}

fn uniqueAtomLessThan(_: void, left: UniqueAtom, right: UniqueAtom) bool {
    return left.first_source < right.first_source;
}

/// Publishes all analyzer roots transactionally. Atom and formula remapping is
/// deterministic, and no analyzer slice is retained.
pub fn build(
    allocator: std.mem.Allocator,
    analyzer: *const RequirementAnalyzer,
    roots: []const FormulaId,
    min_atom_len: usize,
) !FilterPlan {
    var nodes: std.ArrayList(PlanNode) = .empty;
    errdefer nodes.deinit(allocator);
    var children: std.ArrayList(FormulaId) = .empty;
    errdefer children.deinit(allocator);
    var composites: std.AutoHashMapUnmanaged(u64, FormulaId) = .empty;
    defer composites.deinit(allocator);
    var atom_bytes: std.ArrayList(u8) = .empty;
    errdefer atom_bytes.deinit(allocator);
    var atom_spans: std.ArrayList(Span) = .empty;
    defer atom_spans.deinit(allocator);
    var candidates: std.ArrayList(AtomCandidate) = .empty;
    defer candidates.deinit(allocator);
    var unique_atoms: std.ArrayList(UniqueAtom) = .empty;
    defer unique_atoms.deinit(allocator);
    const atom_ids = try allocator.alloc(?u32, analyzer.nodes.items.len);
    defer allocator.free(atom_ids);
    @memset(atom_ids, null);

    for (analyzer.nodes.items, 0..) |node, index| switch (node) {
        .atom => |span| if (analyzer.spanBytes(span).len >= min_atom_len)
            try candidates.append(allocator, .{
                .source_index = @intCast(index),
                .span = span,
            }),
        else => {},
    };
    std.mem.sort(AtomCandidate, candidates.items, analyzer, atomLessThan);
    var previous: ?[]const u8 = null;
    var lexical_id: u32 = undefined;
    for (candidates.items) |candidate| {
        const bytes = analyzer.spanBytes(candidate.span);
        if (previous == null or !std.mem.eql(u8, previous.?, bytes)) {
            lexical_id = std.math.cast(u32, unique_atoms.items.len) orelse
                return error.OutOfMemory;
            try unique_atoms.append(allocator, .{
                .span = candidate.span,
                .first_source = candidate.source_index,
                .lexical_id = lexical_id,
            });
            previous = bytes;
        }
        atom_ids[candidate.source_index] = lexical_id;
    }

    // Keep the public atom-ID order at first formula occurrence while using the
    // lexical sort only to deduplicate in O(A log A).
    std.mem.sort(UniqueAtom, unique_atoms.items, {}, uniqueAtomLessThan);
    const lexical_to_public = try allocator.alloc(u32, unique_atoms.items.len);
    defer allocator.free(lexical_to_public);
    for (unique_atoms.items, 0..) |unique, public_id| {
        lexical_to_public[unique.lexical_id] = std.math.cast(u32, public_id) orelse
            return error.OutOfMemory;
        const bytes = analyzer.spanBytes(unique.span);
        const start = std.math.cast(u32, atom_bytes.items.len) orelse
            return error.OutOfMemory;
        try atom_bytes.appendSlice(allocator, bytes);
        try atom_spans.append(allocator, .{
            .start = start,
            .len = std.math.cast(u32, bytes.len) orelse return error.OutOfMemory,
        });
    }
    for (atom_ids) |*id| {
        if (id.*) |value| id.* = lexical_to_public[value];
    }

    const published_atom_nodes = try allocator.alloc(?FormulaId, unique_atoms.items.len);
    defer allocator.free(published_atom_nodes);
    @memset(published_atom_nodes, null);
    var mapped = try allocator.alloc(?FormulaId, analyzer.nodes.items.len);
    defer allocator.free(mapped);
    @memset(mapped, null);
    for (analyzer.nodes.items, 0..) |node, index| mapped[index] = switch (node) {
        .all, .none => null,
        .atom => blk: {
            const published_atom = atom_ids[index] orelse break :blk null;
            if (published_atom_nodes[published_atom]) |existing| break :blk existing;
            const id: FormulaId = @enumFromInt(nodes.items.len);
            try nodes.append(allocator, .{ .atom = published_atom });
            published_atom_nodes[published_atom] = id;
            break :blk id;
        },
        .and_node => |span| try mapComposite(
            allocator,
            .and_node,
            span,
            analyzer.children.items,
            mapped,
            &nodes,
            &children,
            &composites,
        ),
        .or_node => |span| blk: {
            const start: usize = span.start;
            var missing = false;
            for (analyzer.children.items[start .. start + span.len]) |child|
                if (mapped[@intFromEnum(child)] == null) {
                    missing = true;
                    break;
                };
            if (missing) break :blk null;
            break :blk try mapComposite(
                allocator,
                .or_node,
                span,
                analyzer.children.items,
                mapped,
                &nodes,
                &children,
                &composites,
            );
        },
    };

    const mapped_roots: []?FormulaId = if (roots.len == 0) @constCast(&.{}) else try allocator.alloc(?FormulaId, roots.len);
    errdefer if (mapped_roots.len != 0) allocator.free(mapped_roots);
    for (roots, mapped_roots) |root, *mapped_root| mapped_root.* = mapped[@intFromEnum(root)];
    try compactPlan(allocator, &nodes, &children, mapped_roots);
    try orderPlanChildren(allocator, nodes.items, children.items, atom_spans.items);
    const published_nodes = try nodes.toOwnedSlice(allocator);
    errdefer if (published_nodes.len != 0) allocator.free(published_nodes);
    const published_children = try children.toOwnedSlice(allocator);
    errdefer if (published_children.len != 0) allocator.free(published_children);
    const published_bytes = try atom_bytes.toOwnedSlice(allocator);
    errdefer if (published_bytes.len != 0) allocator.free(published_bytes);
    const published_atoms: [][]const u8 = if (atom_spans.items.len == 0)
        @constCast(&.{})
    else
        try allocator.alloc([]const u8, atom_spans.items.len);
    errdefer if (published_atoms.len != 0) allocator.free(published_atoms);
    for (published_atoms, atom_spans.items) |*atom, span| {
        const start: usize = span.start;
        atom.* = published_bytes[start .. start + span.len];
    }
    var scanner = try teddy.Scanner.init(allocator, published_atoms);
    errdefer scanner.deinit();
    return .{
        .allocator = allocator,
        .nodes = published_nodes,
        .children = published_children,
        .atom_bytes = published_bytes,
        .atoms = published_atoms,
        .roots = mapped_roots,
        .scanner = scanner,
        .encoding = analyzer.encoding,
    };
}

/// Removes nodes unreachable after identity simplification and rewrites every
/// node/child/root ID in-place to a dense postorder domain.
fn compactPlan(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(PlanNode),
    children: *std.ArrayList(FormulaId),
    roots: []?FormulaId,
) !void {
    const reachable = try allocator.alloc(bool, nodes.items.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    var work: std.ArrayList(FormulaId) = .empty;
    defer work.deinit(allocator);
    for (roots) |root| if (root) |id| try work.append(allocator, id);
    while (work.pop()) |id| {
        const index = @intFromEnum(id);
        if (reachable[index]) continue;
        reachable[index] = true;
        const span: ?Span = switch (nodes.items[index]) {
            .and_node => |value| value,
            .or_node => |value| value,
            .atom => null,
        };
        if (span) |value| {
            const start: usize = value.start;
            try work.appendSlice(allocator, children.items[start..][0..value.len]);
        }
    }

    const unmapped = std.math.maxInt(u32);
    const remap = try allocator.alloc(u32, nodes.items.len);
    defer allocator.free(remap);
    @memset(remap, unmapped);
    var node_write: usize = 0;
    var child_write: usize = 0;
    for (nodes.items, 0..) |node, old_index| {
        if (!reachable[old_index]) continue;
        const new_id = std.math.cast(u32, node_write) orelse return error.OutOfMemory;
        remap[old_index] = new_id;
        const rewritten: PlanNode = switch (node) {
            .atom => |atom| .{ .atom = atom },
            .and_node, .or_node => |span| blk: {
                const child_start = std.math.cast(u32, child_write) orelse
                    return error.OutOfMemory;
                const start: usize = span.start;
                for (children.items[start..][0..span.len]) |child| {
                    const mapped_child = remap[@intFromEnum(child)];
                    std.debug.assert(mapped_child != unmapped);
                    children.items[child_write] = @enumFromInt(mapped_child);
                    child_write += 1;
                }
                const rewritten_span = Span{ .start = child_start, .len = span.len };
                break :blk switch (node) {
                    .and_node => .{ .and_node = rewritten_span },
                    .or_node => .{ .or_node = rewritten_span },
                    .atom => unreachable,
                };
            },
        };
        nodes.items[node_write] = rewritten;
        node_write += 1;
    }
    nodes.shrinkRetainingCapacity(node_write);
    children.shrinkRetainingCapacity(child_write);
    for (roots) |*root| if (root.*) |old| {
        const mapped_root = remap[@intFromEnum(old)];
        std.debug.assert(mapped_root != unmapped);
        root.* = @enumFromInt(mapped_root);
    };
}

/// Computes bottom-up selectivity scores, evaluating stronger AND children first
/// and cheaper/likely OR children first without changing Boolean truth.
fn orderPlanChildren(
    allocator: std.mem.Allocator,
    nodes: []const PlanNode,
    children: []FormulaId,
    atoms: []const Span,
) error{OutOfMemory}!void {
    const scores = try allocator.alloc(u32, nodes.len);
    defer allocator.free(scores);
    for (nodes, 0..) |node, node_id| scores[node_id] = switch (node) {
        .atom => |atom| atoms[atom].len,
        .and_node => |span| blk: {
            var score: u32 = 0;
            const start: usize = span.start;
            for (children[start..][0..span.len]) |child|
                score +|= scores[@intFromEnum(child)];
            break :blk score;
        },
        .or_node => |span| blk: {
            var score: u32 = std.math.maxInt(u32);
            const start: usize = span.start;
            for (children[start..][0..span.len]) |child|
                score = @min(score, scores[@intFromEnum(child)]);
            break :blk score;
        },
    };
    for (nodes) |node| {
        const span, const descending = switch (node) {
            .and_node => |value| .{ value, true },
            .or_node => |value| .{ value, false },
            .atom => continue,
        };
        const start: usize = span.start;
        const values = children[start..][0..span.len];
        for (1..values.len) |index| {
            const selected = values[index];
            const selected_score = scores[@intFromEnum(selected)];
            var insertion = index;
            while (insertion > 0) {
                const previous = values[insertion - 1];
                const previous_score = scores[@intFromEnum(previous)];
                const before = if (descending)
                    selected_score > previous_score
                else
                    selected_score < previous_score;
                if (!before) break;
                values[insertion] = previous;
                insertion -= 1;
            }
            values[insertion] = selected;
        }
    }
}

/// Maps children, flattens a nested identical operator, removes duplicates and
/// identity-null children, then interns the exact composite sequence.
fn mapComposite(
    allocator: std.mem.Allocator,
    tag: std.meta.Tag(PlanNode),
    span: Span,
    source_children: []const FormulaId,
    mapped: []const ?FormulaId,
    nodes: *std.ArrayList(PlanNode),
    children: *std.ArrayList(FormulaId),
    composites: *std.AutoHashMapUnmanaged(u64, FormulaId),
) !?FormulaId {
    const old_len = children.items.len;
    const start: usize = span.start;
    for (source_children[start .. start + span.len]) |child| {
        const value = mapped[@intFromEnum(child)] orelse continue;
        const node = nodes.items[@intFromEnum(value)];
        const nested: ?Span = switch (node) {
            .and_node => |value_span| if (tag == .and_node) value_span else null,
            .or_node => |value_span| if (tag == .or_node) value_span else null,
            .atom => null,
        };
        if (nested) |nested_span| {
            try children.ensureUnusedCapacity(allocator, nested_span.len);
            const nested_start: usize = nested_span.start;
            for (children.items[nested_start..][0..nested_span.len]) |nested_child|
                if (std.mem.indexOfScalar(
                    FormulaId,
                    children.items[old_len..],
                    nested_child,
                ) == null) try children.append(allocator, nested_child);
        } else if (std.mem.indexOfScalar(FormulaId, children.items[old_len..], value) == null) {
            try children.append(allocator, value);
        }
    }
    const count = children.items.len - old_len;
    if (count == 0) return null;
    if (count == 1) {
        const result = children.pop().?;
        return result;
    }
    const published_children = children.items[old_len..];
    const hash = std.hash.Wyhash.hash(
        @intFromEnum(tag),
        std.mem.sliceAsBytes(published_children),
    );
    if (composites.get(hash)) |existing| {
        const existing_node = nodes.items[@intFromEnum(existing)];
        const existing_span: ?Span = switch (existing_node) {
            .and_node => |value| if (tag == .and_node) value else null,
            .or_node => |value| if (tag == .or_node) value else null,
            .atom => null,
        };
        if (existing_span) |value| {
            const existing_start: usize = value.start;
            if (std.mem.eql(
                FormulaId,
                children.items[existing_start..][0..value.len],
                published_children,
            )) {
                children.shrinkRetainingCapacity(old_len);
                return existing;
            }
        }
    }
    const id_value = std.math.cast(u32, nodes.items.len) orelse return error.OutOfMemory;
    const child_start = std.math.cast(u32, old_len) orelse return error.OutOfMemory;
    const child_count = std.math.cast(u32, count) orelse return error.OutOfMemory;
    const id: FormulaId = @enumFromInt(id_value);
    try nodes.append(allocator, switch (tag) {
        .and_node => .{ .and_node = .{ .start = child_start, .len = child_count } },
        .or_node => .{ .or_node = .{ .start = child_start, .len = child_count } },
        else => unreachable,
    });
    try composites.put(allocator, hash, id);
    return id;
}
