//! Independent finite-language model of ordered range selection.
//!
//! A local AST describes empty, literal, concat, alternate, optional, star, and
//! plus expressions. One evaluator computes the ordered list of possible ends at
//! each start without importing production syntax or engines; a separate language
//! bitset provides membership checks. Greedy/lazy operators reorder candidates,
//! making leftmost-first and leftmost-longest expectations explicit.
//!
//! Deterministically rendered expressions are crossed with every short binary
//! input, absolute subrange, anchor, match kind, iterator, and count operation
//! through the public API. Metamorphic rewrites are checked only when the model
//! proves language/order preservation. Assertions, Unicode, and captures are
//! isolated in dedicated models so this oracle stays small enough to inspect.

const std = @import("std");
const api = @import("../root.zig");
const testing = std.testing;

const max_expressions = 128;
const Inputs = [_][]const u8{
    "",    "a",   "b",   "aa",  "ab",  "ba",  "bb",
    "aaa", "aab", "aba", "abb", "baa", "bab", "bba",
    "bbb",
};
const Language = std.StaticBitSet(Inputs.len);
const NodeId = u16;

const Pair = struct { left: NodeId, right: NodeId };
const Unary = struct { child: NodeId, greedy: bool };
/// Local ordered regex grammar used only by the independent evaluator.
const Node = union(enum) {
    empty,
    literal: u8,
    concat: Pair,
    alternate: Pair,
    optional: Unary,
    star: Unary,
    plus: Unary,
};

/// Generated rendered pattern, its finite language, and local AST root.
const Expression = struct {
    pattern: []u8,
    language: Language,
    node: NodeId,
};

/// Small ordered endpoint set; append deduplicates without changing first-path
/// priority.
const Ends = struct {
    items: [Inputs[Inputs.len - 1].len + 1]usize = undefined,
    len: usize = 0,

    fn append(self: *Ends, value: usize) void {
        for (self.items[0..self.len]) |existing| if (existing == value) return;
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = value;
        self.len += 1;
    }
};

fn singleton(value: []const u8) Language {
    var result = Language.initEmpty();
    for (Inputs, 0..) |input, index| {
        if (std.mem.eql(u8, value, input)) {
            result.set(index);
            return result;
        }
    }
    unreachable;
}

fn languageUnion(left: Language, right: Language) Language {
    var result = left;
    result.setUnion(right);
    return result;
}

/// Computes bounded-language concatenation independently of ordered path
/// evaluation, mapping each representable joined byte string back to the finite
/// input catalog.
fn languageConcat(left: Language, right: Language) Language {
    var result = Language.initEmpty();
    for (Inputs, 0..) |left_value, left_index| {
        if (!left.isSet(left_index)) continue;
        for (Inputs, 0..) |right_value, right_index| {
            if (!right.isSet(right_index) or left_value.len + right_value.len > 3) continue;
            var combined: [6]u8 = undefined;
            @memcpy(combined[0..left_value.len], left_value);
            @memcpy(combined[left_value.len .. left_value.len + right_value.len], right_value);
            const value = combined[0 .. left_value.len + right_value.len];
            for (Inputs, 0..) |candidate, candidate_index| {
                if (std.mem.eql(u8, value, candidate)) {
                    result.set(candidate_index);
                    break;
                }
            }
        }
    }
    return result;
}

/// Computes finite-domain Kleene closure to a fixed point over the explicit input
/// catalog; this language oracle ignores path order by design.
fn languageStar(inner: Language) Language {
    var result = singleton("");
    while (true) {
        const next = languageUnion(result, languageConcat(result, inner));
        if (next.eql(result)) return result;
        result = next;
    }
}

/// Enumerates repetition endpoints in greedy/lazy path order while suppressing
/// recursive zero-progress loops.
fn evaluateStar(
    nodes: []const Node,
    child: NodeId,
    greedy: bool,
    input: []const u8,
    position: usize,
    output: *Ends,
) void {
    if (!greedy) output.append(position);
    var child_ends: Ends = .{};
    evaluate(nodes, child, input, position, &child_ends);
    for (child_ends.items[0..child_ends.len]) |end| {
        if (end == position) {
            // A nullable iteration exits at its own priority position; allowing
            // a lower-priority consuming alternative to jump ahead would not
            // model ordered Thompson empty-loop suppression.
            output.append(position);
            continue;
        }
        var repeated: Ends = .{};
        evaluateStar(nodes, child, greedy, input, end, &repeated);
        for (repeated.items[0..repeated.len]) |repeated_end| output.append(repeated_end);
    }
    if (greedy) output.append(position);
}

/// Evaluates one bounded local AST at a start position, returning endpoints in
/// alternation/greediness order. Model recursion depth is generation-bounded.
fn evaluate(
    nodes: []const Node,
    node_id: NodeId,
    input: []const u8,
    position: usize,
    output: *Ends,
) void {
    switch (nodes[node_id]) {
        .empty => output.append(position),
        .literal => |literal| {
            if (position < input.len and input[position] == literal) output.append(position + 1);
        },
        .concat => |pair| {
            var left: Ends = .{};
            evaluate(nodes, pair.left, input, position, &left);
            for (left.items[0..left.len]) |middle| {
                var right: Ends = .{};
                evaluate(nodes, pair.right, input, middle, &right);
                for (right.items[0..right.len]) |end| output.append(end);
            }
        },
        .alternate => |pair| {
            evaluate(nodes, pair.left, input, position, output);
            evaluate(nodes, pair.right, input, position, output);
        },
        .optional => |unary| {
            if (unary.greedy) {
                evaluate(nodes, unary.child, input, position, output);
                output.append(position);
            } else {
                output.append(position);
                evaluate(nodes, unary.child, input, position, output);
            }
        },
        .star => |unary| evaluateStar(nodes, unary.child, unary.greedy, input, position, output),
        .plus => |unary| {
            var first: Ends = .{};
            evaluate(nodes, unary.child, input, position, &first);
            for (first.items[0..first.len]) |end| {
                if (end == position) {
                    output.append(position);
                    continue;
                }
                var repeated: Ends = .{};
                evaluateStar(nodes, unary.child, unary.greedy, input, end, &repeated);
                for (repeated.items[0..repeated.len]) |repeated_end| output.append(repeated_end);
            }
        },
    }
}

/// Chooses the earliest legal start and first path-ordered endpoint from the local
/// evaluator.
fn orderedFirstRange(
    nodes: []const Node,
    root: NodeId,
    input: []const u8,
    range_start: usize,
    range_end: usize,
    anchored: bool,
) ?api.Match {
    var start = range_start;
    while (start <= range_end) : (start += 1) {
        var ends: Ends = .{};
        evaluate(nodes, root, input[0..range_end], start, &ends);
        if (ends.len != 0) return .{ .start = start, .end = ends.items[0] };
        if (anchored) break;
    }
    return null;
}

fn orderedFirst(nodes: []const Node, root: NodeId, input: []const u8) ?api.Match {
    return orderedFirstRange(nodes, root, input, 0, input.len, false);
}

fn languageContains(language: Language, value: []const u8) bool {
    for (Inputs, 0..) |input, index|
        if (std.mem.eql(u8, value, input)) return language.isSet(index);
    unreachable;
}

/// Independently chooses earliest start and greatest accepted endpoint using only
/// finite-language membership, not ordered path evaluation.
fn languageLongestRange(
    language: Language,
    input: []const u8,
    range_start: usize,
    range_end: usize,
    anchored: bool,
) ?api.Match {
    var start = range_start;
    while (start <= range_end) : (start += 1) {
        var best: ?usize = null;
        for (start..range_end + 1) |end| {
            if (languageContains(language, input[start..end])) best = end;
        }
        if (best) |end| return .{ .start = start, .end = end };
        if (anchored) break;
    }
    return null;
}

fn languageLongest(language: Language, input: []const u8) ?api.Match {
    return languageLongestRange(language, input, 0, input.len, false);
}

/// Bounded modeled non-overlapping match sequence for one short input.
const Iteration = struct {
    values: [Inputs[Inputs.len - 1].len + 1]api.Match = undefined,
    len: usize = 0,
};

/// Applies the public empty-match progress rule over repeated ordered-first
/// searches.
fn modeledIteration(nodes: []const Node, root: NodeId, input: []const u8) Iteration {
    var result: Iteration = .{};
    var next_start: usize = 0;
    var last_end: ?usize = null;
    while (true) {
        const found = orderedFirstRange(nodes, root, input, next_start, input.len, false) orelse break;
        if (found.start == found.end and last_end == found.end) {
            if (found.end == input.len) break;
            next_start = found.end + 1;
            continue;
        }
        result.values[result.len] = found;
        result.len += 1;
        last_end = found.end;
        next_start = found.end;
    }
    return result;
}

/// Commits one generated expression and model node only when its public pattern
/// spelling is new and the fixed campaign bound has room; rejected spellings
/// release their owned bytes immediately.
fn appendUnique(
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(Expression),
    nodes: *std.ArrayList(Node),
    pattern: []u8,
    language: Language,
    node: Node,
) !void {
    if (expressions.items.len == max_expressions) {
        allocator.free(pattern);
        return;
    }
    for (expressions.items) |existing| {
        if (std.mem.eql(u8, existing.pattern, pattern)) {
            allocator.free(pattern);
            return;
        }
    }
    const node_id: NodeId = @intCast(nodes.items.len);
    try nodes.append(allocator, node);
    try expressions.append(allocator, .{
        .pattern = pattern,
        .language = language,
        .node = node_id,
    });
}

/// Renders one unary public pattern and delegates deduplicated ownership
/// publication to `appendUnique`.
fn appendUnary(
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(Expression),
    nodes: *std.ArrayList(Node),
    inner: Expression,
    operator: []const u8,
    language: Language,
    node: Node,
) !void {
    try appendUnique(
        allocator,
        expressions,
        nodes,
        try std.fmt.allocPrint(allocator, "(?:{s}){s}", .{ inner.pattern, operator }),
        language,
        node,
    );
}

/// Deterministically grows the model grammar while deduplicating rendered
/// expressions and respecting the fixed case bound.
fn expand(
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(Expression),
    nodes: *std.ArrayList(Node),
) !void {
    const source_count = expressions.items.len;
    for (0..source_count) |index| {
        if (expressions.items.len == max_expressions) return;
        const inner = expressions.items[index];
        const optional = languageUnion(singleton(""), inner.language);
        const star = languageStar(inner.language);
        try appendUnary(allocator, expressions, nodes, inner, "?", optional, .{ .optional = .{ .child = inner.node, .greedy = true } });
        try appendUnary(allocator, expressions, nodes, inner, "??", optional, .{ .optional = .{ .child = inner.node, .greedy = false } });
        const plus = languageConcat(inner.language, star);
        const repeated_twice = languageUnion(optional, languageConcat(inner.language, inner.language));
        const tail_id: NodeId = @intCast(nodes.items.len);
        try nodes.append(allocator, .{ .optional = .{ .child = inner.node, .greedy = true } });
        const pair_id: NodeId = @intCast(nodes.items.len);
        try nodes.append(allocator, .{ .concat = .{ .left = inner.node, .right = tail_id } });
        try appendUnary(allocator, expressions, nodes, inner, "{0,2}", repeated_twice, .{
            .optional = .{ .child = pair_id, .greedy = true },
        });
        try appendUnary(allocator, expressions, nodes, inner, "*", star, .{ .star = .{ .child = inner.node, .greedy = true } });
        try appendUnary(allocator, expressions, nodes, inner, "*?", star, .{ .star = .{ .child = inner.node, .greedy = false } });
        try appendUnary(allocator, expressions, nodes, inner, "+", plus, .{ .plus = .{ .child = inner.node, .greedy = true } });
        try appendUnary(allocator, expressions, nodes, inner, "+?", plus, .{ .plus = .{ .child = inner.node, .greedy = false } });
    }
    for (0..source_count) |left_index| {
        for (0..source_count) |right_index| {
            if (expressions.items.len == max_expressions) return;
            const left = expressions.items[left_index];
            const right = expressions.items[right_index];
            try appendUnique(
                allocator,
                expressions,
                nodes,
                try std.fmt.allocPrint(allocator, "(?:{s})(?:{s})", .{ left.pattern, right.pattern }),
                languageConcat(left.language, right.language),
                .{ .concat = .{ .left = left.node, .right = right.node } },
            );
            try appendUnique(
                allocator,
                expressions,
                nodes,
                try std.fmt.allocPrint(allocator, "(?:{s}|{s})", .{ left.pattern, right.pattern }),
                languageUnion(left.language, right.language),
                .{ .alternate = .{ .left = left.node, .right = right.node } },
            );
        }
    }
}

/// Copies one authored base spelling into the same ownership/deduplication path
/// used by generated expressions.
fn appendBase(
    allocator: std.mem.Allocator,
    expressions: *std.ArrayList(Expression),
    nodes: *std.ArrayList(Node),
    pattern: []const u8,
    language: Language,
    node: Node,
) !void {
    try appendUnique(
        allocator,
        expressions,
        nodes,
        try allocator.dupe(u8, pattern),
        language,
        node,
    );
}

test "Finite and ordered models agree through public matching" {
    var expressions: std.ArrayList(Expression) = .empty;
    var nodes: std.ArrayList(Node) = .empty;
    defer {
        for (expressions.items) |expression| testing.allocator.free(expression.pattern);
        expressions.deinit(testing.allocator);
        nodes.deinit(testing.allocator);
    }
    try appendBase(testing.allocator, &expressions, &nodes, "(?:)", singleton(""), .empty);
    try appendBase(testing.allocator, &expressions, &nodes, "a", singleton("a"), .{ .literal = 'a' });
    try appendBase(testing.allocator, &expressions, &nodes, "b", singleton("b"), .{ .literal = 'b' });
    try expand(testing.allocator, &expressions, &nodes);
    try expand(testing.allocator, &expressions, &nodes);
    try testing.expectEqual(@as(usize, max_expressions), expressions.items.len);

    for (expressions.items) |modeled| {
        const first_compiled = try api.Regex.compile(testing.allocator, modeled.pattern, .{});
        var first_expression = switch (first_compiled) {
            .success => |value| value,
            .diagnostic => return error.UnexpectedDiagnostic,
        };
        defer first_expression.deinit();
        var first = try api.Matcher.init(testing.allocator, &first_expression);
        defer first.deinit();

        const longest_compiled = try api.Regex.compile(testing.allocator, modeled.pattern, .{
            .match_kind = .longest,
        });
        var longest_expression = switch (longest_compiled) {
            .success => |value| value,
            .diagnostic => return error.UnexpectedDiagnostic,
        };
        defer longest_expression.deinit();
        var longest = try api.Matcher.init(testing.allocator, &longest_expression);
        defer longest.deinit();

        for (Inputs, 0..) |input, input_index| {
            var complete: Ends = .{};
            evaluate(nodes.items, modeled.node, input, 0, &complete);
            var ordered_full = false;
            for (complete.items[0..complete.len]) |end| ordered_full = ordered_full or end == input.len;
            try testing.expectEqual(modeled.language.isSet(input_index), ordered_full);
            try testing.expectEqual(modeled.language.isSet(input_index), first.fullMatch(input));
            const expected_first = orderedFirst(nodes.items, modeled.node, input);
            const actual_first = first.find(input);
            if (!std.meta.eql(expected_first, actual_first)) {
                std.debug.print(
                    "ordered model mismatch pattern={s} input={s} expected={any} actual={any}\n",
                    .{ modeled.pattern, input, expected_first, actual_first },
                );
                return error.OrderedModelMismatch;
            }
            const expected_longest = languageLongest(modeled.language, input);
            const actual_longest = longest.find(input);
            if (!std.meta.eql(expected_longest, actual_longest)) {
                std.debug.print(
                    "longest model mismatch pattern={s} input={s} expected={any} actual={any}\n",
                    .{ modeled.pattern, input, expected_longest, actual_longest },
                );
                return error.LongestModelMismatch;
            }

            for (0..input.len + 1) |start| {
                for (start..input.len + 1) |end| {
                    const range = api.SearchRange{ .start = start, .end = end };
                    for ([_]api.Anchor{ .unanchored, .start }) |anchor| {
                        const anchored = anchor == .start;
                        try testing.expectEqual(
                            orderedFirstRange(nodes.items, modeled.node, input, start, end, anchored),
                            try first.findIn(input, range, anchor),
                        );
                        try testing.expectEqual(
                            languageLongestRange(modeled.language, input, start, end, anchored),
                            try longest.findIn(input, range, anchor),
                        );
                    }
                }
            }

            const expected_iteration = modeledIteration(nodes.items, modeled.node, input);
            var iterator = first.iterator(input);
            for (expected_iteration.values[0..expected_iteration.len]) |wanted|
                try testing.expectEqual(wanted, iterator.next().?);
            try testing.expect(iterator.next() == null);
            try testing.expectEqual(expected_iteration.len, first.count(input));
        }
    }
}

test "Metamorphic rewrites preserve public match results" {
    var expressions: std.ArrayList(Expression) = .empty;
    var nodes: std.ArrayList(Node) = .empty;
    defer {
        for (expressions.items) |expression| testing.allocator.free(expression.pattern);
        expressions.deinit(testing.allocator);
        nodes.deinit(testing.allocator);
    }
    try appendBase(testing.allocator, &expressions, &nodes, "(?:)", singleton(""), .empty);
    try appendBase(testing.allocator, &expressions, &nodes, "a", singleton("a"), .{ .literal = 'a' });
    try appendBase(testing.allocator, &expressions, &nodes, "b", singleton("b"), .{ .literal = 'b' });
    try expand(testing.allocator, &expressions, &nodes);
    try expand(testing.allocator, &expressions, &nodes);

    for (expressions.items) |modeled| {
        for ([_]api.MatchKind{ .first, .longest }) |kind| {
            const baseline_compiled = try api.Regex.compile(testing.allocator, modeled.pattern, .{
                .match_kind = kind,
            });
            var baseline_expression = switch (baseline_compiled) {
                .success => |value| value,
                .diagnostic => return error.UnexpectedDiagnostic,
            };
            defer baseline_expression.deinit();
            var baseline = try api.Matcher.init(testing.allocator, &baseline_expression);
            defer baseline.deinit();

            const rewrites = [_][]u8{
                try std.fmt.allocPrint(testing.allocator, "(?:{s})", .{modeled.pattern}),
                try std.fmt.allocPrint(testing.allocator, "(?:{s}){{1}}", .{modeled.pattern}),
                try std.fmt.allocPrint(
                    testing.allocator,
                    "(?:{s})|(?:{s})",
                    .{ modeled.pattern, modeled.pattern },
                ),
            };
            defer for (rewrites) |rewrite| testing.allocator.free(rewrite);

            for (rewrites) |rewrite| {
                const transformed_compiled = try api.Regex.compile(testing.allocator, rewrite, .{
                    .match_kind = kind,
                });
                var transformed_expression = switch (transformed_compiled) {
                    .success => |value| value,
                    .diagnostic => return error.UnexpectedDiagnostic,
                };
                defer transformed_expression.deinit();
                var transformed = try api.Matcher.init(testing.allocator, &transformed_expression);
                defer transformed.deinit();

                for (Inputs) |input| {
                    try testing.expectEqual(baseline.isMatch(input), transformed.isMatch(input));
                    try testing.expectEqual(baseline.fullMatch(input), transformed.fullMatch(input));
                    try testing.expectEqual(baseline.find(input), transformed.find(input));
                }
            }
        }
    }
}
