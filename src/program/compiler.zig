//! Iterative syntax-to-Thompson compilation and Program publication entry points.
//!
//! `Compiler` maintains parallel task and fragment stacks. Visiting an n-ary
//! syntax node first schedules a reduction task, then schedules children in the
//! reverse order needed for LIFO execution. Leaf visits immediately push a
//! Thompson fragment. Reduction pops the completed child fragments and composes
//! them without recursion, so pattern depth consumes heap budget rather than the
//! process stack.
//!
//! Split arm order encodes alternation priority and greedy/lazy repetition.
//! Captures emit begin/end slot instructions whose ordering reverses in a reverse
//! Program. Counted repeats are expanded from parser-normalized syntax under the
//! instruction limit. Byte predicates are delegated to `byte_lowering.zig`.
//!
//! The compiler also performs one graph-level optimization for adjacent ASCII
//! literal alternatives that differ only by a contiguous final byte. It does not
//! cross fold, capture, or priority boundaries.
//!
//! After the expression fragment is patched to its accepting leaf, ordinary
//! compilation adds a lower-priority consume-one-byte/retry loop as the
//! unanchored root. Set compilation instead attaches insertion IDs to several
//! roots and may require absolute full anchoring.
//!
//! `run` transfers both the temporary Graph and the immutable Program from
//! publication; production entry points immediately destroy the Graph. Root
//! policy records whether nullable constructions require dominator lists to
//! preserve priority.

const std = @import("std");
const syntax = @import("../syntax/regexp.zig");
const rune_range = @import("../syntax/rune_range.zig");
const byte_encoding = @import("byte_encoding.zig");
const builder_module = @import("builder.zig");
const byte_lowering = @import("byte_lowering.zig");
const priority_lists = @import("priority_lists.zig");
const program = @import("program.zig");
const publication = @import("publication.zig");
const thompson = @import("thompson.zig");

/// Direction and admission policy for graph construction. Reverse mode changes
/// traversal/capture-slot order but not the source syntax arena.
pub const Options = struct {
    encoding: byte_encoding.Encoding,
    max_instructions: u32,
    reverse: bool = false,
};

pub const CompileError = error{ OutOfMemory, InstructionLimit, InvalidSyntax };

const Frag = thompson.Fragment;

/// Explicit postorder traversal frame. `visit` descends; every other variant
/// reduces already completed child fragments.
const Task = union(enum) {
    visit: syntax.NodeId,
    concat: usize,
    alternate: usize,
    capture: syntax.Capture,
    repeat: struct { count: usize, min: u32, max: ?u32, greedy: bool },
};

fn selectRootPolicy(needs_dominators: bool) priority_lists.RootPolicy {
    return if (needs_dominators) .nullable_dominators else .successor_roots;
}

/// Test/inspection result retaining both representations. Production `compile`
/// returns only Program and destroys the temporary Graph immediately.
pub const Compilation = struct {
    prog: program.Program,
    graph: program.Graph,

    pub fn deinit(self: *Compilation, allocator: std.mem.Allocator) void {
        self.graph.deinit(allocator);
        self.prog.deinit(allocator);
        self.* = undefined;
    }
};

/// Mutable state for one iterative compile transaction. `tasks` and `fragments`
/// form a postorder evaluator; Builder and Lowering own graph scratch.
const Compiler = struct {
    allocator: std.mem.Allocator,
    syntax_tree: *const syntax.Regexp,
    options: Options,
    builder: builder_module.Builder,
    tasks: std.ArrayList(Task) = .empty,
    fragments: std.ArrayList(Frag) = .empty,
    lowering: byte_lowering.Lowering,
    needs_priority_dominators: bool = false,

    // Lifecycle and publication.

    /// Starts one compilation transaction and reserves node-scaled postorder
    /// stacks plus a conservative two-instruction-per-node graph hint. Checked
    /// hint overflow falls back to the configured instruction ceiling, while
    /// any failed reservation tears down Builder and Lowering state together.
    fn init(
        allocator: std.mem.Allocator,
        syntax_tree: *const syntax.Regexp,
        options: Options,
    ) CompileError!Compiler {
        var result = Compiler{
            .allocator = allocator,
            .syntax_tree = syntax_tree,
            .options = options,
            .builder = builder_module.Builder.init(allocator, options.max_instructions) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InstructionLimit => return error.InstructionLimit,
            },
            .lowering = .{
                .allocator = allocator,
                .encoding = options.encoding,
                .reverse = options.reverse,
            },
        };
        errdefer result.deinit();
        const node_count = syntax_tree.nodes.items.len;
        const graph_hint = std.math.mul(usize, node_count, 2) catch
            @as(usize, options.max_instructions);
        try result.builder.reserve(graph_hint);
        try result.tasks.ensureTotalCapacityPrecise(allocator, node_count);
        try result.fragments.ensureTotalCapacityPrecise(allocator, node_count);
        return result;
    }

    fn deinit(self: *Compiler) void {
        self.lowering.deinit();
        self.fragments.deinit(self.allocator);
        self.tasks.deinit(self.allocator);
        self.builder.deinit();
        self.* = undefined;
    }

    /// Compiles one expression, appends match ID zero, and constructs the
    /// lower-priority unanchored byte-scan loop before publication.
    fn run(self: *Compiler) CompileError!Compilation {
        const root = self.syntax_tree.root orelse return error.InvalidSyntax;
        try self.tasks.append(self.allocator, .{ .visit = root });
        try self.drainTasks();
        if (self.fragments.items.len != 1) return error.InvalidSyntax;
        var root_frag = self.fragments.pop().?;
        const can_match_empty = root_frag.nullable;

        const accepting = try self.builder.addMatch(@enumFromInt(0));
        root_frag = self.cat(root_frag, .{ .start = accepting, .outs = .{}, .nullable = false });

        // Lower-priority byte scan makes unanchored search a finite automaton:
        // try the expression here first, otherwise consume one byte and retry.
        const scan = try self.builder.addByteRange(0, 0xff, false);
        const unanchored = try self.builder.addSplit(root_frag.start, scan[0]);
        self.builder.patch(scan[1], unanchored[0]);

        const groups = std.math.add(u32, self.syntax_tree.capture_count, 1) catch return error.InstructionLimit;
        const capture_slots = std.math.mul(u32, groups, 2) catch return error.InstructionLimit;
        var graph = self.builder.finish(root_frag.start, unanchored[0], capture_slots) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.IncompleteProgram => return error.InvalidSyntax,
        };
        errdefer graph.deinit(self.allocator);

        var prog = try publication.publish(
            self.allocator,
            self.syntax_tree,
            root,
            &graph,
            capture_slots,
            .{
                .encoding = self.options.encoding,
                .reverse = self.options.reverse,
                .root_policy = selectRootPolicy(self.needs_priority_dominators),
            },
        );
        prog.can_match_empty = can_match_empty;
        return .{ .prog = prog, .graph = graph };
    }

    /// Compiles several roots with accepting IDs in insertion order, combines
    /// them by ordered alternation, and optionally enforces both text anchors.
    fn runSet(self: *Compiler, roots: []const syntax.NodeId, anchored_both: bool) CompileError!Compilation {
        if (roots.len == 0 or roots.len > std.math.maxInt(u32))
            return error.InvalidSyntax;
        for (roots, 0..) |root, match_id| {
            if (self.tasks.items.len != 0 or self.fragments.items.len != match_id)
                return error.InvalidSyntax;
            try self.tasks.append(self.allocator, .{ .visit = root });
            try self.drainTasks();
            if (self.fragments.items.len != match_id + 1) return error.InvalidSyntax;
            var fragment = self.fragments.pop().?;
            if (anchored_both)
                fragment = self.cat(fragment, try self.assertion(.{ .end_text = true }));
            const accepting = try self.builder.addMatch(@enumFromInt(match_id));
            fragment = self.cat(fragment, .{
                .start = accepting,
                .outs = .{},
                .nullable = false,
            });
            try self.fragments.append(self.allocator, fragment);
        }
        try self.finishAlternate(roots.len);
        const root_frag = self.fragments.pop().?;
        const unanchored_start = if (anchored_both)
            root_frag.start
        else blk: {
            const scan = try self.builder.addByteRange(0, 0xff, false);
            const unanchored = try self.builder.addSplit(root_frag.start, scan[0]);
            self.builder.patch(scan[1], unanchored[0]);
            break :blk unanchored[0];
        };

        var graph = self.builder.finish(root_frag.start, unanchored_start, 2) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.IncompleteProgram => return error.InvalidSyntax,
        };
        errdefer graph.deinit(self.allocator);
        const syntax_root = self.syntax_tree.root orelse return error.InvalidSyntax;
        const prog = try publication.publish(
            self.allocator,
            self.syntax_tree,
            syntax_root,
            &graph,
            2,
            .{
                .encoding = self.options.encoding,
                .reverse = false,
                .root_policy = selectRootPolicy(self.needs_priority_dominators),
            },
        );
        return .{ .prog = prog, .graph = graph };
    }

    // Iterative syntax scheduling.

    /// Runs the explicit postorder evaluator to exhaustion. Each reduction sees
    /// only Fragments already emitted for its children, replacing recursive
    /// compiler calls with allocator-bounded work stacks.
    fn drainTasks(self: *Compiler) CompileError!void {
        while (self.tasks.pop()) |task| switch (task) {
            .visit => |id| try self.visit(id),
            .concat => |count| try self.finishConcat(count),
            .alternate => |count| try self.finishAlternate(count),
            .capture => |capture| try self.finishCapture(capture),
            .repeat => |repeat| try self.finishRepeat(repeat.count, repeat.min, repeat.max, repeat.greedy),
        };
    }

    /// Schedules or emits one syntax node. Children are pushed in reverse
    /// execution order so later reduction sees fragments in source priority.
    fn visit(self: *Compiler, id: syntax.NodeId) CompileError!void {
        switch (self.syntax_tree.node(id).*) {
            .no_match => try self.fragments.append(self.allocator, .{
                .start = @enumFromInt(0),
                .outs = .{},
                .nullable = false,
            }),
            .empty => try self.fragments.append(self.allocator, try self.jumpFrag()),
            .literal => |literal| {
                var result: ?Frag = null;
                const runes = self.syntax_tree.literalRunes(literal.runes);
                var offset: usize = 0;
                while (offset < runes.len) : (offset += 1) {
                    const index = if (self.options.reverse) runes.len - 1 - offset else offset;
                    const next = if (literal.fold)
                        try self.foldedRune(runes[index])
                    else
                        try self.compileRune(runes[index]);
                    result = if (result) |current| self.cat(current, next) else next;
                }
                try self.fragments.append(self.allocator, result orelse try self.jumpFrag());
            },
            .char_class => |span| {
                const result = try self.runeClass(self.syntax_tree.classRanges(span));
                try self.fragments.append(self.allocator, result);
            },
            .concat => |span| {
                const children = self.syntax_tree.nodeChildren(span);
                try self.tasks.append(self.allocator, .{ .concat = children.len });
                if (self.options.reverse) {
                    for (children) |child| try self.tasks.append(self.allocator, .{ .visit = child });
                } else {
                    var index = children.len;
                    while (index > 0) {
                        index -= 1;
                        try self.tasks.append(self.allocator, .{ .visit = children[index] });
                    }
                }
            },
            .alternate => |span| {
                if (try self.literalTailAlternation(span)) |combined| {
                    try self.fragments.append(self.allocator, combined);
                } else {
                    const children = self.syntax_tree.nodeChildren(span);
                    try self.tasks.append(self.allocator, .{ .alternate = children.len });
                    var index = children.len;
                    while (index > 0) {
                        index -= 1;
                        try self.tasks.append(self.allocator, .{ .visit = children[index] });
                    }
                }
            },
            .capture => |capture| {
                try self.tasks.append(self.allocator, .{ .capture = capture });
                try self.tasks.append(self.allocator, .{ .visit = capture.child });
            },
            .repeat => |repeat| {
                const count: u32 = repeat.max orelse @max(repeat.min, 1);
                if (count == 0) {
                    try self.fragments.append(self.allocator, try self.jumpFrag());
                    return;
                }
                try self.tasks.append(self.allocator, .{ .repeat = .{
                    .count = count,
                    .min = repeat.min,
                    .max = repeat.max,
                    .greedy = repeat.greedy,
                } });
                var remaining = count;
                while (remaining > 0) : (remaining -= 1) {
                    try self.tasks.append(self.allocator, .{ .visit = repeat.child });
                }
            },
            .begin_line => try self.fragments.append(self.allocator, try self.assertion(.{ .begin_line = true })),
            .end_line => try self.fragments.append(self.allocator, try self.assertion(.{ .end_line = true })),
            .begin_text => try self.fragments.append(self.allocator, try self.assertion(.{ .begin_text = true })),
            .end_text => try self.fragments.append(self.allocator, try self.assertion(.{ .end_text = true })),
            .word_boundary => try self.fragments.append(self.allocator, try self.assertion(.{ .word_boundary = true })),
            .not_word_boundary => try self.fragments.append(self.allocator, try self.assertion(.{ .not_word_boundary = true })),
            .any_char => |any| {
                const ranges = if (any.match_newline)
                    &[_]rune_range.Range{rune_range.rune_universe}
                else
                    &[_]rune_range.Range{
                        .{ .lo = 0, .hi = '\n' - 1 },
                        .{ .lo = '\n' + 1, .hi = rune_range.max_rune },
                    };
                try self.fragments.append(self.allocator, try self.runeClass(ranges));
            },
            .any_byte => {
                const value = try self.builder.addByteRange(0, 0xff, false);
                try self.fragments.append(self.allocator, .{ .start = value[0], .outs = value[1], .nullable = false });
            },
        }
    }

    // Proven graph-level simplifications.

    /// Recognizes equal-length case-sensitive ASCII literal branches with a
    /// common prefix and distinct contiguous final bytes, replacing their ordered
    /// split fanout with one byte range. Equal width/capturelessness makes branch
    /// priority unobservable after the shared prefix.
    fn literalTailAlternation(self: *Compiler, span: syntax.NodeSpan) CompileError!?Frag {
        const children = self.syntax_tree.nodeChildren(span);
        if (children.len < 2) return null;
        const first_node = self.syntax_tree.node(children[0]).*;
        if (first_node != .literal or first_node.literal.fold) return null;
        const first = self.syntax_tree.literalRunes(first_node.literal.runes);
        if (first.len == 0) return null;

        var tails: [256]bool = @splat(false);
        var tail_lo: u8 = std.math.maxInt(u8);
        var tail_hi: u8 = 0;
        for (children) |child_id| {
            const node = self.syntax_tree.node(child_id).*;
            if (node != .literal or node.literal.fold) return null;
            const runes = self.syntax_tree.literalRunes(node.literal.runes);
            if (runes.len != first.len or
                !std.mem.eql(u32, runes[0 .. runes.len - 1], first[0 .. first.len - 1]) or
                runes[runes.len - 1] > 0x7f) return null;
            const tail: u8 = @intCast(runes[runes.len - 1]);
            if (tails[tail]) return null;
            tails[tail] = true;
            tail_lo = @min(tail_lo, tail);
            tail_hi = @max(tail_hi, tail);
        }
        if (@as(usize, tail_hi) - tail_lo + 1 != children.len) return null;

        var result: ?Frag = null;
        if (self.options.reverse) {
            result = try self.runeClass(&.{.{ .lo = tail_lo, .hi = tail_hi }});
            var index = first.len - 1;
            while (index > 0) {
                index -= 1;
                result = self.cat(result.?, try self.compileRune(first[index]));
            }
        } else {
            for (first[0 .. first.len - 1]) |rune| {
                const fragment = try self.compileRune(rune);
                result = if (result) |current| self.cat(current, fragment) else fragment;
            }
            const tail = try self.runeClass(&.{.{ .lo = tail_lo, .hi = tail_hi }});
            result = if (result) |current| self.cat(current, tail) else tail;
        }
        return result;
    }

    // Task reductions.

    /// Folds the most recent child Fragments left-to-right, patching every
    /// successful exit into the next child while retaining authored order.
    fn finishConcat(self: *Compiler, count: usize) CompileError!void {
        if (count == 0 or self.fragments.items.len < count) return error.InvalidSyntax;
        const start = self.fragments.items.len - count;
        var result = self.fragments.items[start];
        for (self.fragments.items[start + 1 ..]) |next| result = self.cat(result, next);
        self.fragments.shrinkRetainingCapacity(start);
        try self.fragments.append(self.allocator, result);
    }

    /// Pops `count` completed branches and folds them right-to-left so source
    /// order remains split preference.
    fn finishAlternate(self: *Compiler, count: usize) CompileError!void {
        if (count == 0 or self.fragments.items.len < count) return error.InvalidSyntax;
        const start = self.fragments.items.len - count;
        var result = self.fragments.items[start];
        for (self.fragments.items[start + 1 ..]) |next|
            result = try thompson.alternate(&self.builder, result, next);
        self.fragments.shrinkRetainingCapacity(start);
        try self.fragments.append(self.allocator, result);
    }

    /// Wraps one completed child with begin/end slot writes; reverse compilation
    /// swaps slot order consistently with traversal direction.
    fn finishCapture(self: *Compiler, capture: syntax.Capture) CompileError!void {
        if (self.fragments.items.len == 0) return error.InvalidSyntax;
        var child = self.fragments.pop().?;
        const index = @intFromEnum(capture.index);
        const begin = try self.captureInst(@enumFromInt(index * 2 + @intFromBool(self.options.reverse)));
        const end = try self.captureInst(@enumFromInt(index * 2 + @intFromBool(!self.options.reverse)));
        self.builder.patch(begin.outs, child.start);
        self.builder.patch(child.outs, end.start);
        child.start = begin.start;
        child.outs = end.outs;
        try self.fragments.append(self.allocator, child);
    }

    /// Reduces parser-requested copies into required concatenation, a nested
    /// optional suffix for finite bounds, or a star/plus tail for infinity.
    /// Nesting optionals from the right preserves greedy/lazy path order.
    fn finishRepeat(
        self: *Compiler,
        count: usize,
        min: u32,
        max: ?u32,
        greedy: bool,
    ) CompileError!void {
        if (count == 0 or self.fragments.items.len < count) return error.InvalidSyntax;
        const start = self.fragments.items.len - count;
        const copies = self.fragments.items[start..];
        var result: ?Frag = null;

        if (max == null) {
            var index: usize = 0;
            while (index + 1 < copies.len) : (index += 1) {
                result = if (result) |current| self.cat(current, copies[index]) else copies[index];
            }
            const tail = if (min == 0)
                try self.star(copies[copies.len - 1], greedy)
            else
                try self.plus(copies[copies.len - 1], greedy);
            result = if (result) |current| self.cat(current, tail) else tail;
        } else {
            var required: usize = 0;
            while (required < min) : (required += 1) {
                result = if (result) |current| self.cat(current, copies[required]) else copies[required];
            }
            if (copies.len > min) {
                var suffix = try self.question(copies[copies.len - 1], greedy);
                var index = copies.len - 1;
                while (index > min) {
                    index -= 1;
                    suffix = try self.question(self.cat(copies[index], suffix), greedy);
                }
                result = if (result) |current| self.cat(current, suffix) else suffix;
            }
            if (result == null) result = try self.jumpFrag();
        }

        self.fragments.shrinkRetainingCapacity(start);
        try self.fragments.append(self.allocator, result.?);
    }

    // Thompson fragment composition and byte lowering.

    fn cat(self: *Compiler, first: Frag, second: Frag) Frag {
        return thompson.concatenate(&self.builder, first, second);
    }

    /// Builds Kleene star. Nullable children use `(child+)?` and request
    /// dominator roots so an empty preferred path cannot be revived through the
    /// loop.
    fn star(self: *Compiler, child: Frag, greedy: bool) CompileError!Frag {
        // One split cannot preserve priority through the transitive closure
        // when the child is nullable. The compiler lowers that case as
        // (child+)? so an empty iteration commits before lower-priority paths.
        if (child.nullable) {
            self.needs_priority_dominators = true;
            return self.question(try self.plus(child, greedy), greedy);
        }

        const split = if (greedy)
            try self.builder.addSplit(child.start, null)
        else
            try self.builder.addSplit(null, child.start);
        self.builder.patch(child.outs, split[0]);
        return .{
            .start = split[0],
            .outs = if (greedy) split[2] else split[1],
            .nullable = true,
        };
    }

    /// Builds one-required-then-loop repetition. Split arm order records
    /// greediness; nullable children request stronger publication roots so loop
    /// re-entry cannot revive a discarded lower-priority path.
    fn plus(self: *Compiler, child: Frag, greedy: bool) CompileError!Frag {
        if (child.nullable) self.needs_priority_dominators = true;
        const split = if (greedy)
            try self.builder.addSplit(child.start, null)
        else
            try self.builder.addSplit(null, child.start);
        self.builder.patch(child.outs, split[0]);
        return .{
            .start = child.start,
            .outs = if (greedy) split[2] else split[1],
            .nullable = child.nullable,
        };
    }

    /// Builds optional execution as an ordered child/bypass split and joins both
    /// successful exits into one dangling patch list.
    fn question(self: *Compiler, child: Frag, greedy: bool) CompileError!Frag {
        const split = if (greedy)
            try self.builder.addSplit(child.start, null)
        else
            try self.builder.addSplit(null, child.start);
        return .{
            .start = split[0],
            .outs = self.builder.appendPatches(child.outs, if (greedy) split[2] else split[1]),
            .nullable = true,
        };
    }

    fn jumpFrag(self: *Compiler) CompileError!Frag {
        const value = try self.builder.addJump();
        return .{ .start = value[0], .outs = value[1], .nullable = true };
    }

    fn assertion(self: *Compiler, mask: program.EmptyMask) CompileError!Frag {
        const value = try self.builder.addEmptyWidth(mask);
        return .{ .start = value[0], .outs = value[1], .nullable = true };
    }

    fn captureInst(self: *Compiler, slot: program.CaptureSlot) CompileError!Frag {
        const value = try self.builder.addCapture(slot);
        return .{ .start = value[0], .outs = value[1], .nullable = true };
    }

    fn foldedRune(self: *Compiler, rune: u32) CompileError!Frag {
        return self.lowering.foldedRune(&self.builder, rune);
    }

    fn compileRune(self: *Compiler, rune: u32) CompileError!Frag {
        return self.lowering.compileRune(&self.builder, rune);
    }

    fn runeClass(self: *Compiler, ranges: []const rune_range.Range) CompileError!Frag {
        return self.lowering.runeClass(&self.builder, ranges);
    }
};

// Public compilation boundaries.

/// Compiles and publishes one syntax tree, then destroys the temporary explicit
/// Graph before returning the immutable runtime Program.
pub fn compile(
    allocator: std.mem.Allocator,
    syntax_tree: *const syntax.Regexp,
    options: Options,
) CompileError!program.Program {
    var compiler = try Compiler.init(allocator, syntax_tree, options);
    defer compiler.deinit();
    var compilation = try compiler.run();
    compilation.graph.deinit(allocator);
    return compilation.prog;
}

/// Compiles match-ID-bearing roots into one captureless many-match program.
pub fn compileSet(
    allocator: std.mem.Allocator,
    syntax_tree: *const syntax.Regexp,
    roots: []const syntax.NodeId,
    options: Options,
    anchored_both: bool,
) CompileError!program.Program {
    var compiler = try Compiler.init(allocator, syntax_tree, options);
    defer compiler.deinit();
    var compilation = try compiler.runSet(roots, anchored_both);
    compilation.graph.deinit(allocator);
    return compilation.prog;
}

/// Structural test boundary; production callers use `compile` and never own a graph.
pub fn compileWithGraph(
    allocator: std.mem.Allocator,
    syntax_tree: *const syntax.Regexp,
    options: Options,
) CompileError!Compilation {
    var compiler = try Compiler.init(allocator, syntax_tree, options);
    defer compiler.deinit();
    return compiler.run();
}

// Module-local structural tests.

const parser = @import("../syntax/parser.zig");
const testing = std.testing;

const TestCompilation = struct {
    tree: syntax.Regexp,
    prog: program.Program,
    graph: program.Graph,
};

fn compilePattern(pattern: []const u8) !TestCompilation {
    const parsed = try parser.parse(testing.allocator, pattern, .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = switch (parsed) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    errdefer tree.deinit(testing.allocator);
    const compilation = try compileWithGraph(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
    });
    return .{
        .tree = tree,
        .prog = compilation.prog,
        .graph = compilation.graph,
    };
}

test "Runtime validation is independent of the deleted compile graph" {
    var values = try compilePattern("(a)|b");
    defer values.tree.deinit(testing.allocator);
    defer values.prog.deinit(testing.allocator);
    values.graph.deinit(testing.allocator);
    try values.prog.validate();

    var byte_leaf: ?*program.RuntimeInstruction = null;
    var capture_leaf: ?*program.RuntimeInstruction = null;
    for (values.prog.priority_lists.leaves) |*leaf| switch (leaf.opcode()) {
        .byte_range => if (byte_leaf == null) {
            byte_leaf = leaf;
        },
        .capture => if (capture_leaf == null) {
            capture_leaf = leaf;
        },
        else => {},
    };

    const saved_byte_bits = byte_leaf.?.bits;
    const value_mask = (@as(u64, 1) << 30) - 1;
    byte_leaf.?.bits = (saved_byte_bits & ~value_mask) |
        values.prog.priority_lists.lists.len;
    try testing.expectError(error.InvalidProgram, values.prog.validate());
    byte_leaf.?.bits = saved_byte_bits;

    const byte_classes = values.prog.mutableByteClasses();
    const saved_class = byte_classes['a'];
    byte_classes['a'] = byte_classes['b'];
    try testing.expectError(error.InvalidProgram, values.prog.validate());
    byte_classes['a'] = saved_class;

    const saved_capture_bits = capture_leaf.?.bits;
    const payload_mask = ((@as(u64, 1) << 31) - 1) << 33;
    capture_leaf.?.bits = (saved_capture_bits & ~payload_mask) |
        (@as(u64, values.prog.capture_slots) << 33);
    try testing.expectError(error.InvalidProgram, values.prog.validate());
    capture_leaf.?.bits = saved_capture_bits;

    byte_leaf.?.bits = (saved_byte_bits & ~(@as(u64, 0x7) << 30)) |
        (@as(u64, @intFromEnum(program.Opcode.split)) << 30);
    try testing.expectError(error.InvalidProgram, values.prog.validate());
    byte_leaf.?.bits = saved_byte_bits;
    try values.prog.validate();

    // A Latin-1 Unicode branch can collapse to fail while leaving assertions
    // in the temporary graph. Runtime metadata must describe final leaves only.
    const parsed = try parser.parse(testing.allocator, "a|\\p{Greek}$", .{
        .encoding = .latin1,
        .perl_classes = true,
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var latin_tree = parsed.success;
    defer latin_tree.deinit(testing.allocator);
    var latin_prog = try compile(testing.allocator, &latin_tree, .{
        .encoding = .latin1,
        .max_instructions = 100_000,
    });
    defer latin_prog.deinit(testing.allocator);
    try testing.expect(!latin_prog.uses_empty_width);
    try latin_prog.validate();
}

test "Nullable syntax selects dominator roots" {
    try testing.expectEqual(
        priority_lists.RootPolicy.successor_roots,
        selectRootPolicy(false),
    );
    try testing.expectEqual(
        priority_lists.RootPolicy.nullable_dominators,
        selectRootPolicy(true),
    );
}

test "Compiler preserves preferred alternation order" {
    var values = try compilePattern("a|c");
    defer values.tree.deinit(testing.allocator);
    defer values.prog.deinit(testing.allocator);
    defer values.graph.deinit(testing.allocator);
    const split = values.graph.inst(values.graph.start);
    try testing.expectEqualSlices(u8, "", values.prog.prefix);
    try testing.expectEqual(program.Opcode.split, split.opcode());
    try testing.expectEqual(@as(u8, 'a'), values.graph.inst(split.out()).byteLo());
    try testing.expectEqual(@as(u8, 'c'), values.graph.inst(split.alternate()).byteLo());
}

test "ASCII singleton alternatives merge without crossing captures" {
    var merged = try compilePattern("a|b");
    defer merged.tree.deinit(testing.allocator);
    defer merged.prog.deinit(testing.allocator);
    defer merged.graph.deinit(testing.allocator);
    var merged_ranges: usize = 0;
    var merged_splits: usize = 0;
    for (merged.graph.instructions) |instruction| switch (instruction.opcode()) {
        .byte_range => merged_ranges += @intFromBool(
            instruction.byteLo() == 'a' and instruction.byteHi() == 'b',
        ),
        .split => merged_splits += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), merged_ranges);

    var captured = try compilePattern("(a)|(b)");
    defer captured.tree.deinit(testing.allocator);
    defer captured.prog.deinit(testing.allocator);
    defer captured.graph.deinit(testing.allocator);
    var captured_splits: usize = 0;
    for (captured.graph.instructions) |instruction|
        captured_splits += @intFromBool(instruction.opcode() == .split);
    try testing.expect(captured_splits > merged_splits);
}

test "Byte map partitions every consuming predicate boundary" {
    var values = try compilePattern("[0-9A-Fa-f]+");
    defer values.tree.deinit(testing.allocator);
    defer values.prog.deinit(testing.allocator);
    defer values.graph.deinit(testing.allocator);
    const map = values.prog.byteClasses();
    try testing.expectEqual(@as(u16, 7), values.prog.byte_class_count);
    try testing.expect(map[0] != map['0']);
    try testing.expect(map['0'] != map[':']);
    try testing.expect(map[':'] != map['A']);
    try testing.expect(map['A'] != map['G']);
    try testing.expect(map['G'] != map['a']);
    try testing.expect(map['a'] != map['g']);
}

test "Literal prefix shapes identify complete and one-byte-tail languages" {
    var literal = try compilePattern("needle");
    defer literal.tree.deinit(testing.allocator);
    defer literal.prog.deinit(testing.allocator);
    defer literal.graph.deinit(testing.allocator);
    try testing.expect(literal.prog.prefix_complete);

    var repeated = try compilePattern("(a+)(b)?");
    defer repeated.tree.deinit(testing.allocator);
    defer repeated.prog.deinit(testing.allocator);
    defer repeated.graph.deinit(testing.allocator);
    try testing.expectEqualStrings("a", repeated.prog.prefix);

    var alternatives = try compilePattern("needle-a|needle-b");
    defer alternatives.tree.deinit(testing.allocator);
    defer alternatives.prog.deinit(testing.allocator);
    defer alternatives.graph.deinit(testing.allocator);
    try testing.expect(alternatives.prog.prefix_has_tail_range);
    try testing.expectEqual(@as(u8, 'a'), alternatives.prog.prefix_tail_lo);
    try testing.expectEqual(@as(u8, 'b'), alternatives.prog.prefix_tail_hi);

    var captured = try compilePattern("(needle-a)|(needle-b)");
    defer captured.tree.deinit(testing.allocator);
    defer captured.prog.deinit(testing.allocator);
    defer captured.graph.deinit(testing.allocator);
    var plain_splits: usize = 0;
    for (alternatives.graph.instructions) |instruction|
        plain_splits += @intFromBool(instruction.opcode() == .split);
    var captured_splits: usize = 0;
    for (captured.graph.instructions) |instruction|
        captured_splits += @intFromBool(instruction.opcode() == .split);
    try testing.expect(captured_splits > plain_splits);
}

test "Required exact prefix is published without retaining syntax" {
    var values = try compilePattern("^needle[0-9]");
    defer values.tree.deinit(testing.allocator);
    defer values.prog.deinit(testing.allocator);
    defer values.graph.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "needle", values.prog.prefix);

    var alternate = try compilePattern("needle-a|needle-b");
    defer alternate.tree.deinit(testing.allocator);
    defer alternate.prog.deinit(testing.allocator);
    defer alternate.graph.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "needle-", alternate.prog.prefix);

    var folded = try compilePattern("(?i)needle");
    defer folded.tree.deinit(testing.allocator);
    defer folded.prog.deinit(testing.allocator);
    defer folded.graph.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, "needle", folded.prog.prefix);
    try testing.expect(folded.prog.prefix_fold_ascii);
}

test "Reverse compilation reverses Rune and UTF-8 byte order" {
    const parsed = try parser.parse(testing.allocator, "aé", .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = parsed.success;
    defer tree.deinit(testing.allocator);
    var compilation = try compileWithGraph(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
        .reverse = true,
    });
    defer compilation.deinit(testing.allocator);
    var id = compilation.graph.start;
    try testing.expectEqual(@as(u8, 0xa9), compilation.graph.inst(id).byteLo());
    id = compilation.graph.inst(id).out();
    try testing.expectEqual(@as(u8, 0xc3), compilation.graph.inst(id).byteLo());
    id = compilation.graph.inst(id).out();
    try testing.expectEqual(@as(u8, 'a'), compilation.graph.inst(id).byteLo());
}

test "Whole-range capture analysis sees wrappers across assertions" {
    var aliased = try compilePattern("(([a]+))$");
    defer aliased.tree.deinit(testing.allocator);
    defer aliased.prog.deinit(testing.allocator);
    defer aliased.graph.deinit(testing.allocator);
    try testing.expect(aliased.prog.all_captures_whole);

    var partial = try compilePattern("([a]+)b");
    defer partial.tree.deinit(testing.allocator);
    defer partial.prog.deinit(testing.allocator);
    defer partial.graph.deinit(testing.allocator);
    try testing.expect(!partial.prog.all_captures_whole);
}

test "Directional anchor analysis recognizes reverse absolute end" {
    const parsed = try parser.parse(testing.allocator, "0[01]{12}$", .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = parsed.success;
    defer tree.deinit(testing.allocator);
    var forward = try compile(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
    });
    defer forward.deinit(testing.allocator);
    var reverse = try compile(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
        .reverse = true,
    });
    defer reverse.deinit(testing.allocator);
    try testing.expect(!forward.anchor_start);
    try testing.expect(forward.anchor_end);
    try testing.expect(reverse.anchor_start);

    var branches = try compilePattern("(?:a$|b$)");
    defer branches.tree.deinit(testing.allocator);
    defer branches.prog.deinit(testing.allocator);
    defer branches.graph.deinit(testing.allocator);
    try testing.expect(branches.prog.anchor_end);

    var mixed_values = try compilePattern("a$|b");
    defer mixed_values.tree.deinit(testing.allocator);
    defer mixed_values.prog.deinit(testing.allocator);
    defer mixed_values.graph.deinit(testing.allocator);
    var mixed_reverse = try compile(testing.allocator, &mixed_values.tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
        .reverse = true,
    });
    defer mixed_reverse.deinit(testing.allocator);
    try testing.expect(!mixed_values.prog.anchor_end);
    try testing.expect(!mixed_reverse.anchor_start);

    var folded = try compilePattern("(?i)ABC$");
    defer folded.tree.deinit(testing.allocator);
    defer folded.prog.deinit(testing.allocator);
    defer folded.graph.deinit(testing.allocator);
    try testing.expect(folded.prog.anchor_end);
    try testing.expect(folded.prog.required_suffix.fold_ascii);
    try testing.expectEqualStrings(
        "abc",
        folded.prog.required_suffix.bytes[0..folded.prog.required_suffix.len],
    );
}

test "Begin-text analysis distinguishes fully anchored programs" {
    var anchored = try compilePattern("^(a|aa)*b");
    defer anchored.tree.deinit(testing.allocator);
    defer anchored.prog.deinit(testing.allocator);
    defer anchored.graph.deinit(testing.allocator);
    try testing.expect(anchored.prog.anchor_start);

    var mixed = try compilePattern("^a|b");
    defer mixed.tree.deinit(testing.allocator);
    defer mixed.prog.deinit(testing.allocator);
    defer mixed.graph.deinit(testing.allocator);
    try testing.expect(!mixed.prog.anchor_start);
}

test "UTF-8 broad range publishes a validated scalar program" {
    var values = try compilePattern(".");
    defer values.tree.deinit(testing.allocator);
    defer values.prog.deinit(testing.allocator);
    defer values.graph.deinit(testing.allocator);
    try values.prog.validate();
    try testing.expect(values.graph.instructions.len > 1);
}

test "Parser-local repeat coalescing reduces canonical program size" {
    for ([_]struct { combined: []const u8, canonical: []const u8 }{
        .{ .combined = "a*a*", .canonical = "a*" },
        .{ .combined = "a+a+", .canonical = "a{2,}" },
        .{ .combined = "a?a?", .canonical = "a{0,2}" },
        .{ .combined = "[a-c]{2}[a-c]{3,4}", .canonical = "[a-c]{5,6}" },
    }) |case| {
        var combined = try compilePattern(case.combined);
        defer combined.tree.deinit(testing.allocator);
        defer combined.prog.deinit(testing.allocator);
        defer combined.graph.deinit(testing.allocator);
        var canonical = try compilePattern(case.canonical);
        defer canonical.tree.deinit(testing.allocator);
        defer canonical.prog.deinit(testing.allocator);
        defer canonical.graph.deinit(testing.allocator);
        try testing.expectEqual(canonical.graph.instructions.len, combined.graph.instructions.len);
    }
}

test "Counted repeat remains bounded and valid" {
    var values = try compilePattern("a{2,4}");
    defer values.tree.deinit(testing.allocator);
    defer values.prog.deinit(testing.allocator);
    defer values.graph.deinit(testing.allocator);
    try values.prog.validate();
}
