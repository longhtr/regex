//! Independent path model for ordered capture participation and slot values.
//!
//! A local capture AST evaluates complete candidate paths directly. Entering a
//! capture records the start; successful child return records the end; failed or
//! bypassed branches leave the group unmatched. Candidate ordering implements
//! alternation and greedy/lazy repetition independently of production queues or
//! copy-on-write rows.
//!
//! Generated trees with one through four groups cross nesting, optional/unmatched
//! groups, empty participation, alternation, repetition, every short binary input
//! and subrange, both anchors, first/longest selection, ordinary captures, and
//! full captures through the public API. Context assertions and Unicode are kept
//! out so capture priority remains a transparent oracle.

const std = @import("std");
const api = @import("../root.zig");
const testing = std.testing;

const Inputs = [_][]const u8{
    "",    "a",   "b",   "aa",  "ab",  "ba",  "bb",
    "aaa", "aab", "aba", "abb", "baa", "bab", "bba",
    "bbb",
};
const NodeId = u16;
const Pair = struct { left: NodeId, right: NodeId };
const Unary = struct { child: NodeId, greedy: bool };

const CaptureGroups = [4]?api.Match;
/// One successful local path endpoint and the group ranges accumulated on it.
const CaptureCandidate = struct { end: usize, groups: CaptureGroups };
/// Ordered candidate set deduplicated by endpoint so first path retains capture
/// priority for that end.
const CaptureResults = struct {
    items: [Inputs[Inputs.len - 1].len + 1]CaptureCandidate = undefined,
    len: usize = 0,

    fn append(self: *CaptureResults, candidate: CaptureCandidate) void {
        for (self.items[0..self.len]) |existing| if (existing.end == candidate.end) return;
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = candidate;
        self.len += 1;
    }
};

/// Local capture grammar independent of production syntax representation.
const CaptureNode = union(enum) {
    empty,
    literal: u8,
    concat: Pair,
    alternate: Pair,
    optional: Unary,
    star: Unary,
    capture: struct { child: NodeId, group: usize },
};

/// Arena and rendering/evaluation helpers for generated bounded capture trees.
const CaptureModel = struct {
    nodes: std.ArrayList(CaptureNode) = .empty,

    fn deinit(self: *CaptureModel) void {
        self.nodes.deinit(testing.allocator);
    }

    fn add(self: *CaptureModel, node: CaptureNode) !NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(testing.allocator, node);
        return id;
    }

    /// Renders the independent model tree as equivalent public regex syntax.
    /// Rendering shares no production parser or syntax-node representation.
    fn render(
        self: *const CaptureModel,
        allocator: std.mem.Allocator,
        id: NodeId,
    ) error{OutOfMemory}![]u8 {
        return switch (self.nodes.items[id]) {
            .empty => allocator.dupe(u8, "(?:)"),
            .literal => |literal| std.fmt.allocPrint(allocator, "{c}", .{literal}),
            .concat => |pair| self.renderPair(allocator, pair, "(?:{s})(?:{s})"),
            .alternate => |pair| self.renderPair(allocator, pair, "(?:{s}|{s})"),
            .optional => |unary| self.renderUnary(allocator, unary, if (unary.greedy) "?" else "??"),
            .star => |unary| self.renderUnary(allocator, unary, if (unary.greedy) "*" else "*?"),
            .capture => |capture| blk: {
                const child = try self.render(allocator, capture.child);
                defer allocator.free(child);
                break :blk try std.fmt.allocPrint(allocator, "({s})", .{child});
            },
        };
    }

    /// Owns both recursively rendered operands until one parent spelling has
    /// copied them, keeping generated-test ownership explicit.
    fn renderPair(
        self: *const CaptureModel,
        allocator: std.mem.Allocator,
        pair: Pair,
        comptime format: []const u8,
    ) error{OutOfMemory}![]u8 {
        const left = try self.render(allocator, pair.left);
        defer allocator.free(left);
        const right = try self.render(allocator, pair.right);
        defer allocator.free(right);
        return std.fmt.allocPrint(allocator, format, .{ left, right });
    }

    /// Wraps a rendered child before adding a postfix operator so the model's
    /// atom boundary is preserved in public syntax.
    fn renderUnary(
        self: *const CaptureModel,
        allocator: std.mem.Allocator,
        unary: Unary,
        operator: []const u8,
    ) error{OutOfMemory}![]u8 {
        const child = try self.render(allocator, unary.child);
        defer allocator.free(child);
        return std.fmt.allocPrint(allocator, "(?:{s}){s}", .{ child, operator });
    }
};

/// Enumerates bounded repetition paths in greedy/lazy order and rejects
/// zero-progress recursion, independently modeling empty-loop termination.
fn evaluateCaptureStar(
    nodes: []const CaptureNode,
    child: NodeId,
    greedy: bool,
    input: []const u8,
    position: usize,
    groups: CaptureGroups,
    output: *CaptureResults,
) void {
    if (!greedy) output.append(.{ .end = position, .groups = groups });
    var child_results: CaptureResults = .{};
    evaluateCaptures(nodes, child, input, position, groups, &child_results);
    for (child_results.items[0..child_results.len]) |child_result| {
        if (child_result.end == position) {
            output.append(child_result);
            continue;
        }
        var repeated: CaptureResults = .{};
        evaluateCaptureStar(
            nodes,
            child,
            greedy,
            input,
            child_result.end,
            child_result.groups,
            &repeated,
        );
        for (repeated.items[0..repeated.len]) |result| output.append(result);
    }
    if (greedy) output.append(.{ .end = position, .groups = groups });
}

/// Evaluates one local node with path-local group state, returning successful
/// endpoints in semantic priority order.
fn evaluateCaptures(
    nodes: []const CaptureNode,
    node_id: NodeId,
    input: []const u8,
    position: usize,
    groups: CaptureGroups,
    output: *CaptureResults,
) void {
    switch (nodes[node_id]) {
        .empty => output.append(.{ .end = position, .groups = groups }),
        .literal => |literal| {
            if (position < input.len and input[position] == literal)
                output.append(.{ .end = position + 1, .groups = groups });
        },
        .concat => |pair| {
            var left: CaptureResults = .{};
            evaluateCaptures(nodes, pair.left, input, position, groups, &left);
            for (left.items[0..left.len]) |left_result| {
                var right: CaptureResults = .{};
                evaluateCaptures(
                    nodes,
                    pair.right,
                    input,
                    left_result.end,
                    left_result.groups,
                    &right,
                );
                for (right.items[0..right.len]) |result| output.append(result);
            }
        },
        .alternate => |pair| {
            evaluateCaptures(nodes, pair.left, input, position, groups, output);
            evaluateCaptures(nodes, pair.right, input, position, groups, output);
        },
        .optional => |unary| {
            if (unary.greedy) {
                evaluateCaptures(nodes, unary.child, input, position, groups, output);
                output.append(.{ .end = position, .groups = groups });
            } else {
                output.append(.{ .end = position, .groups = groups });
                evaluateCaptures(nodes, unary.child, input, position, groups, output);
            }
        },
        .star => |unary| evaluateCaptureStar(
            nodes,
            unary.child,
            unary.greedy,
            input,
            position,
            groups,
            output,
        ),
        .capture => |capture| {
            var inner: CaptureResults = .{};
            evaluateCaptures(nodes, capture.child, input, position, groups, &inner);
            for (inner.items[0..inner.len]) |inner_result| {
                var captured = inner_result;
                captured.groups[capture.group] = .{ .start = position, .end = inner_result.end };
                output.append(captured);
            }
        },
    }
}

/// Winning whole range and final group participation selected from local paths.
const ModeledCaptures = struct { whole: api.Match, groups: CaptureGroups };

/// Selects the leftmost first/longest candidate over an absolute range; longest
/// changes endpoint choice but retains first-path captures for equal endpoints.
fn captureRange(
    nodes: []const CaptureNode,
    root: NodeId,
    input: []const u8,
    range_start: usize,
    range_end: usize,
    anchored: bool,
    longest: bool,
) ?ModeledCaptures {
    var start = range_start;
    while (start <= range_end) : (start += 1) {
        var results: CaptureResults = .{};
        evaluateCaptures(nodes, root, input[0..range_end], start, .{ null, null, null, null }, &results);
        if (results.len != 0) {
            var selected = results.items[0];
            if (longest) for (results.items[1..results.len]) |candidate|
                if (candidate.end > selected.end) {
                    selected = candidate;
                };
            return .{
                .whole = .{ .start = start, .end = selected.end },
                .groups = selected.groups,
            };
        }
        if (anchored) break;
    }
    return null;
}

/// Compares the complete optional public view with local whole/group ranges before
/// any matcher operation can invalidate borrowed storage.
fn checkView(
    expected: ?ModeledCaptures,
    actual: ?api.CaptureView,
    group_count: usize,
) !void {
    if (expected) |modeled| {
        const captured = actual orelse return error.MissingCaptureMatch;
        try testing.expectEqual(modeled.whole, captured.group(0).?);
        for (modeled.groups[0..group_count], 1..) |group, index|
            try testing.expectEqual(group, captured.group(index));
    } else try testing.expect(actual == null);
}

/// Renders one independent model tree, compiles it for both match policies, and
/// compares public capture views against modeled paths over every short input,
/// subrange, and anchor. Full-capture checks additionally require the modeled
/// anchored winner to end exactly at the requested boundary.
fn checkCaptureModel(model: *const CaptureModel, root: NodeId, group_count: usize) !void {
    const pattern = try model.render(testing.allocator, root);
    defer testing.allocator.free(pattern);

    for ([_]api.MatchKind{ .first, .longest }) |kind| {
        const compiled = try api.Regex.compile(testing.allocator, pattern, .{ .match_kind = kind });
        var expression = switch (compiled) {
            .success => |value| value,
            .diagnostic => return error.UnexpectedDiagnostic,
        };
        defer expression.deinit();
        var matcher = try api.Matcher.init(testing.allocator, &expression);
        defer matcher.deinit();

        for (Inputs) |input| {
            for (0..input.len + 1) |start| {
                for (start..input.len + 1) |end| {
                    const range = api.SearchRange{ .start = start, .end = end };
                    for ([_]api.Anchor{ .unanchored, .start }) |anchor| {
                        const expected = captureRange(
                            model.nodes.items,
                            root,
                            input,
                            start,
                            end,
                            anchor == .start,
                            kind == .longest,
                        );
                        try checkView(expected, try matcher.capturesIn(input, range, anchor), group_count);
                    }
                    const expected_full = captureRange(
                        model.nodes.items,
                        root,
                        input,
                        start,
                        end,
                        true,
                        true,
                    );
                    const exact = if (expected_full) |value|
                        if (value.whole.end == end) value else null
                    else
                        null;
                    try checkView(exact, try matcher.fullCapturesIn(input, range), group_count);
                }
            }
        }
    }
}

test "Ordered capture model agrees through public captures" {
    var model: CaptureModel = .{};
    defer model.deinit();
    const empty = try model.add(.empty);
    const a = try model.add(.{ .literal = 'a' });
    const b = try model.add(.{ .literal = 'b' });

    const capture_a = try model.add(.{ .capture = .{ .child = a, .group = 0 } });
    try checkCaptureModel(&model, capture_a, 1);

    const capture_b = try model.add(.{ .capture = .{ .child = b, .group = 1 } });
    const alternate_captures = try model.add(.{ .alternate = .{ .left = capture_a, .right = capture_b } });
    try checkCaptureModel(&model, alternate_captures, 2);

    // Source-order numbering makes the outer capture group zero and its inner
    // capture group one in the rendered `((a))` expression.
    const nested_inner = try model.add(.{ .capture = .{ .child = a, .group = 1 } });
    const nested_outer = try model.add(.{ .capture = .{ .child = nested_inner, .group = 0 } });
    try checkCaptureModel(&model, nested_outer, 2);

    const optional_a = try model.add(.{ .optional = .{ .child = a, .greedy = true } });
    const first = try model.add(.{ .capture = .{ .child = optional_a, .group = 0 } });
    const star_a = try model.add(.{ .star = .{ .child = a, .greedy = true } });
    const second = try model.add(.{ .capture = .{ .child = star_a, .group = 1 } });
    const split_greed = try model.add(.{ .concat = .{ .left = first, .right = second } });
    try checkCaptureModel(&model, split_greed, 2);

    const a_or_b = try model.add(.{ .alternate = .{ .left = a, .right = b } });
    const repeated_capture = try model.add(.{ .capture = .{ .child = a_or_b, .group = 0 } });
    const repeated = try model.add(.{ .star = .{ .child = repeated_capture, .greedy = true } });
    try checkCaptureModel(&model, repeated, 1);

    const empty_or_a = try model.add(.{ .alternate = .{ .left = empty, .right = a } });
    const nullable_first = try model.add(.{ .capture = .{ .child = empty_or_a, .group = 0 } });
    const lazy_b = try model.add(.{ .optional = .{ .child = b, .greedy = false } });
    const nullable_second = try model.add(.{ .capture = .{ .child = lazy_b, .group = 1 } });
    const nullable_pair = try model.add(.{ .concat = .{ .left = nullable_first, .right = nullable_second } });
    try checkCaptureModel(&model, nullable_pair, 2);

    const capture_empty = try model.add(.{ .capture = .{ .child = empty, .group = 2 } });
    const capture_final_a = try model.add(.{ .capture = .{ .child = a, .group = 3 } });
    const first_pair = try model.add(.{ .concat = .{ .left = capture_a, .right = capture_b } });
    const second_pair = try model.add(.{ .concat = .{ .left = capture_empty, .right = capture_final_a } });
    const four_groups = try model.add(.{ .concat = .{ .left = first_pair, .right = second_pair } });
    try checkCaptureModel(&model, four_groups, 4);

    // Deterministically cross simple atoms through the capture shapes that are
    // most sensitive to priority, participation, and repetition.
    const bases = [_]NodeId{ empty, a, b };
    for (bases) |left_base| {
        for (bases) |right_base| {
            const left_capture = try model.add(.{ .capture = .{ .child = left_base, .group = 0 } });
            const right_capture = try model.add(.{ .capture = .{ .child = right_base, .group = 1 } });
            const concatenated = try model.add(.{ .concat = .{ .left = left_capture, .right = right_capture } });
            try checkCaptureModel(&model, concatenated, 2);

            const alternated = try model.add(.{ .alternate = .{ .left = left_capture, .right = right_capture } });
            try checkCaptureModel(&model, alternated, 2);

            const optional_left = try model.add(.{ .optional = .{ .child = left_capture, .greedy = true } });
            const optional_pair = try model.add(.{ .concat = .{ .left = optional_left, .right = right_capture } });
            try checkCaptureModel(&model, optional_pair, 2);

            const repeated_left = try model.add(.{ .star = .{ .child = left_capture, .greedy = false } });
            const repeated_pair = try model.add(.{ .concat = .{ .left = repeated_left, .right = right_capture } });
            try checkCaptureModel(&model, repeated_pair, 2);
        }
    }
}
