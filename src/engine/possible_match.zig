//! Static bytewise lexical bounds for finite anchored full-match languages.
//!
//! `Analyzer` carries an unordered set of reachable Program roots for the prefix
//! constructed so far. Closure follows roots, captures, and satisfiable assertion
//! context into consuming leaves. For each next position, `buildBound` tests bytes
//! in ascending (minimum) or descending (maximum) order and greedily selects the
//! first byte with a productive successor. This is valid for lexicographic order:
//! the earliest differing byte dominates every suffix.
//!
//! Exact-end acceptance is checked at every prefix. Repeated logical automaton
//! states reveal productive cycles. Minimum may stop at the first accepted
//! prefix; maximum retains the extra accepting repetition needed to round to an
//! exclusive lexical successor. If the bounded analysis cannot represent a
//! finite maximum, the public result reports `no_finite_max`; no reachable match
//! reports `empty_language`.
//!
//! This is conservative static analysis, not matching. Results describe anchored
//! full matches in unsigned bytewise order and own independent output slices.
//! Assertion context is summarized from begin/end, previous byte, and next byte;
//! all scratch and remembered state sequences are released on failure.

const std = @import("std");
const match_types = @import("../match.zig");
const program = @import("../program/program.zig");

/// Synthetic assertion context for a candidate prefix rather than a real input.
const Context = struct {
    at_begin: bool,
    at_end: bool,
    previous: ?u8,
    next: ?u8,
};

/// Explicit `(root,next item index)` closure continuation.
const Work = struct { root: u32, index: u32 };

/// Reusable closure/transition scratch over roots reachable after the currently
/// selected lexical prefix. Fixed backing partitions raw/next/consuming work;
/// generation maps deduplicate items and successor roots without clearing on
/// every byte trial.
const Analyzer = struct {
    allocator: std.mem.Allocator,
    prog: *const program.Program,
    backing: []u32,
    raw: std.ArrayList(u32) = .empty,
    next_raw: std.ArrayList(u32) = .empty,
    consuming: std.ArrayList(u32) = .empty,
    work: std.ArrayList(Work) = .empty,
    seen: []u32,
    destination_seen: []u32,
    generation: u32 = 1,
    destination_generation: u32 = 1,

    /// Derives fixed root/item capacities, obtains one checked `u32` backing
    /// allocation, and partitions it into generation maps plus raw, consuming,
    /// and closure-work storage. Seeding the published start root makes every
    /// later lexical step allocation-free.
    fn init(allocator: std.mem.Allocator, prog: *const program.Program) !Analyzer {
        const item_count = prog.priority_lists.items.len;
        const root_count = prog.priority_lists.lists.len;
        const item_words = std.math.mul(usize, item_count, 6) catch
            return error.OutOfMemory;
        const root_words = std.math.mul(usize, root_count, 3) catch
            return error.OutOfMemory;
        const backing_len = std.math.add(usize, item_words, root_words) catch
            return error.OutOfMemory;
        const backing = try allocator.alloc(u32, backing_len);
        var offset: usize = 0;
        const seen = backing[offset .. offset + item_count];
        offset += item_count;
        const destination_seen = backing[offset .. offset + root_count];
        offset += root_count;
        const raw_storage = backing[offset .. offset + root_count];
        offset += root_count;
        const next_raw_storage = backing[offset .. offset + root_count];
        offset += root_count;
        const consuming_storage = backing[offset .. offset + item_count];
        offset += item_count;
        const work_storage = std.mem.bytesAsSlice(
            Work,
            std.mem.sliceAsBytes(backing[offset..]),
        );
        std.debug.assert(work_storage.len == item_count * 2);
        @memset(seen, 0);
        @memset(destination_seen, 0);
        var result = Analyzer{
            .allocator = allocator,
            .prog = prog,
            .backing = backing,
            .raw = .{ .items = raw_storage[0..0], .capacity = raw_storage.len },
            .next_raw = .{ .items = next_raw_storage[0..0], .capacity = next_raw_storage.len },
            .consuming = .{ .items = consuming_storage[0..0], .capacity = consuming_storage.len },
            .work = .{ .items = work_storage[0..0], .capacity = work_storage.len },
            .seen = seen,
            .destination_seen = destination_seen,
        };
        result.raw.appendAssumeCapacity(prog.priority_lists.start_root);
        return result;
    }

    fn deinit(self: *Analyzer) void {
        if (self.backing.len != 0) self.allocator.free(self.backing);
        self.* = undefined;
    }

    fn advanceGeneration(values: []u32, generation: *u32) void {
        generation.* +%= 1;
        if (generation.* == 0) {
            @memset(values, 0);
            generation.* = 1;
        }
    }

    /// Expands current raw roots through epsilon leaves under synthetic context,
    /// records unique consuming item occurrences, and reports end acceptance.
    fn closure(self: *Analyzer, context: Context) bool {
        self.consuming.clearRetainingCapacity();
        self.work.clearRetainingCapacity();
        advanceGeneration(self.seen, &self.generation);
        for (self.raw.items) |root| self.work.appendAssumeCapacity(.{ .root = root, .index = 0 });
        var accepts = false;
        while (self.work.pop()) |work| {
            const list = self.prog.priority_lists.lists[work.root];
            var index = work.index;
            while (index < list.len) : (index += 1) {
                const item_id = list.offset + index;
                if (self.seen[item_id] == self.generation) break;
                self.seen[item_id] = self.generation;
                const item = self.prog.priority_lists.items[item_id];
                if (item.isRoot()) {
                    if (!item.isLast()) self.work.appendAssumeCapacity(.{
                        .root = work.root,
                        .index = index + 1,
                    });
                    self.work.appendAssumeCapacity(.{ .root = item.root(), .index = 0 });
                    break;
                }
                const instruction = self.prog.runtimeInstruction(item);
                switch (instruction.opcode()) {
                    .fail => {},
                    .capture => {
                        if (!item.isLast()) self.work.appendAssumeCapacity(.{
                            .root = work.root,
                            .index = index + 1,
                        });
                        self.work.appendAssumeCapacity(.{
                            .root = self.prog.instructionSuccessor(instruction),
                            .index = 0,
                        });
                        break;
                    },
                    .empty_width => if (assertionsHold(instruction.emptyMask(), context)) {
                        if (!item.isLast()) self.work.appendAssumeCapacity(.{
                            .root = work.root,
                            .index = index + 1,
                        });
                        self.work.appendAssumeCapacity(.{
                            .root = self.prog.instructionSuccessor(instruction),
                            .index = 0,
                        });
                        break;
                    },
                    .byte_range => self.consuming.appendAssumeCapacity(item_id),
                    .match => accepts = true,
                    .jump, .split => unreachable,
                }
            }
        }
        return accepts;
    }

    /// Advances the active root set through one candidate byte, deduplicating
    /// successor roots. False means the prefix is not productive.
    fn step(self: *Analyzer, byte: u8, context: Context) bool {
        _ = self.closure(context);
        self.next_raw.clearRetainingCapacity();
        advanceGeneration(self.destination_seen, &self.destination_generation);
        for (self.consuming.items) |item_id| {
            const item = self.prog.priority_lists.items[item_id];
            const instruction = self.prog.runtimeInstruction(item);
            if (!instruction.matchesByte(byte)) continue;
            const destination = self.prog.instructionSuccessor(instruction);
            if (self.destination_seen[destination] == self.destination_generation) continue;
            self.destination_seen[destination] = self.destination_generation;
            self.next_raw.appendAssumeCapacity(destination);
        }
        if (self.next_raw.items.len == 0) return false;
        std.mem.swap(std.ArrayList(u32), &self.raw, &self.next_raw);
        return true;
    }

    fn acceptsEnd(self: *Analyzer, at_begin: bool, previous: ?u8) bool {
        return self.closure(.{
            .at_begin = at_begin,
            .at_end = true,
            .previous = previous,
            .next = null,
        });
    }

    /// Produces the assertion-context bits and consuming closure needed to compare
    /// the current logical state with previously visited prefixes.
    fn prepareIdentity(self: *Analyzer, at_begin: bool, previous: ?u8) struct {
        accepts_without_end: bool,
        context_bits: u8,
    } {
        const accepts_without_end = self.closure(.{
            .at_begin = at_begin,
            .at_end = false,
            .previous = previous,
            .next = null,
        });
        const mask = self.prog.empty_mask_union;
        var context_bits: u8 = 0;
        if (mask.begin_line or mask.end_line)
            context_bits |= @intFromBool(previous == '\n');
        if (mask.word_boundary or mask.not_word_boundary)
            context_bits |= @as(u8, @intFromBool(isWord(previous))) << 1;
        return .{
            .accepts_without_end = accepts_without_end,
            .context_bits = context_bits,
        };
    }
};

/// Evaluates Program assertions against a synthetic prefix boundary. This
/// mirrors runtime conjunction semantics but uses analyzer-supplied neighbors
/// rather than pretending a partial prefix is a complete input.
fn assertionsHold(mask: program.EmptyMask, current: Context) bool {
    if (mask.begin_text and !current.at_begin) return false;
    if (mask.end_text and !current.at_end) return false;
    if (mask.begin_line and !current.at_begin and current.previous != '\n') return false;
    if (mask.end_line and !current.at_end and current.next != '\n') return false;
    if (mask.word_boundary or mask.not_word_boundary) {
        const boundary = isWord(current.previous) != isWord(current.next);
        if (mask.word_boundary and !boundary) return false;
        if (mask.not_word_boundary and boundary) return false;
    }
    return true;
}

fn isWord(byte: ?u8) bool {
    const value = byte orelse return false;
    return std.ascii.isAlphanumeric(value) or value == '_';
}

/// Rounds a finite explored maximum prefix upward to an exclusive lexical upper
/// bound, carrying through trailing `0xff` bytes.
fn prefixSuccessor(value: *std.ArrayList(u8)) void {
    var index = value.items.len;
    while (index != 0) {
        index -= 1;
        if (value.items[index] != 0xff) {
            value.items[index] += 1;
            value.shrinkRetainingCapacity(index + 1);
            return;
        }
    }
    value.clearRetainingCapacity();
}

/// Greedily constructs a lexical extremum and detects repeated automaton/context
/// identities. Maximum rounding yields a conservative finite upper bound when
/// exact continuation cannot be represented within `max_len`.
fn buildBound(
    analyzer: *Analyzer,
    output: *std.ArrayList(u8),
    max_len: usize,
    comptime minimum: bool,
) !enum { exact, rounded, empty } {
    // Remembered logical automaton/context identity used to detect productive
    // cycles while extending one bound. `visits` permits the one extra accepting
    // maximum repetition needed for exclusive-successor rounding.
    const Visited = struct {
        instructions: []u32,
        accepts_without_end: bool,
        context_bits: u8,
        matched_prefix: bool,
        visits: u8,
    };
    var visited: std.ArrayList(Visited) = .empty;
    defer {
        for (visited.items) |state| analyzer.allocator.free(state.instructions);
        visited.deinit(analyzer.allocator);
    }
    var previous: ?u8 = null;
    var at_begin = true;
    var matched_prefix = false;

    while (output.items.len < max_len) {
        const accepts_end = analyzer.acceptsEnd(at_begin, previous);
        matched_prefix = matched_prefix or accepts_end;
        const identity = analyzer.prepareIdentity(at_begin, previous);
        var prior: ?*Visited = null;
        for (visited.items) |*state| {
            if (state.accepts_without_end == identity.accepts_without_end and
                state.context_bits == identity.context_bits and
                state.matched_prefix == matched_prefix and
                std.mem.eql(u32, state.instructions, analyzer.consuming.items))
            {
                prior = state;
                break;
            }
        }
        const visits = if (prior) |state| state.visits else 0;
        // the engine's longest DFA retains one extra accepting repetition state for
        // maxima (for example, a* rounds from aa to ab), while nonaccepting
        // loops stop after the first element.
        const repeat_limit: u8 = if (!minimum and accepts_end) 1 else 0;
        if (visits > repeat_limit) break;
        if (prior) |state| {
            state.visits += 1;
        } else {
            const instructions = try analyzer.allocator.dupe(
                u32,
                analyzer.consuming.items,
            );
            errdefer analyzer.allocator.free(instructions);
            try visited.append(analyzer.allocator, .{
                .instructions = instructions,
                .accepts_without_end = identity.accepts_without_end,
                .context_bits = identity.context_bits,
                .matched_prefix = matched_prefix,
                .visits = 1,
            });
        }

        if (minimum and accepts_end) return .exact;

        const saved = try analyzer.allocator.dupe(u32, analyzer.raw.items);
        defer analyzer.allocator.free(saved);
        var found = false;
        var selected: u8 = if (minimum) 0 else 255;
        var attempt: u16 = 0;
        while (attempt < 256) : (attempt += 1) {
            const byte: u8 = if (minimum) @intCast(attempt) else @intCast(255 - attempt);
            analyzer.raw.clearRetainingCapacity();
            analyzer.raw.appendSliceAssumeCapacity(saved);
            if (analyzer.step(byte, .{
                .at_begin = at_begin,
                .at_end = false,
                .previous = previous,
                .next = byte,
            })) {
                selected = byte;
                found = true;
                break;
            }
        }
        if (!found) {
            analyzer.raw.clearRetainingCapacity();
            analyzer.raw.appendSliceAssumeCapacity(saved);
            return if (output.items.len == 0 and !analyzer.acceptsEnd(at_begin, previous)) .empty else .exact;
        }
        try output.append(analyzer.allocator, selected);
        previous = selected;
        at_begin = false;
    }

    if (minimum) return .exact;
    prefixSuccessor(output);
    return if (output.items.len == 0) .empty else .rounded;
}

/// Computes independent minimum and maximum analyses. `max_len` bounds analysis
/// and output; zero is invalid because it cannot distinguish useful prefixes.
pub fn possibleMatchRange(
    allocator: std.mem.Allocator,
    prog: *const program.Program,
    max_len: usize,
) error{ OutOfMemory, InvalidLength }!match_types.PossibleMatchResult {
    if (max_len == 0) return error.InvalidLength;
    var minimum_analyzer = try Analyzer.init(allocator, prog);
    defer minimum_analyzer.deinit();
    var maximum_analyzer = try Analyzer.init(allocator, prog);
    defer maximum_analyzer.deinit();
    var minimum: std.ArrayList(u8) = .empty;
    defer minimum.deinit(allocator);
    var maximum: std.ArrayList(u8) = .empty;
    defer maximum.deinit(allocator);

    const min_status = try buildBound(&minimum_analyzer, &minimum, max_len, true);
    const max_status = try buildBound(&maximum_analyzer, &maximum, max_len, false);
    if (min_status == .empty and max_status == .empty) return .empty_language;
    if (max_status == .empty) return .no_finite_max;

    const minimum_bytes = try minimum.toOwnedSlice(allocator);
    errdefer allocator.free(minimum_bytes);
    const maximum_bytes = try maximum.toOwnedSlice(allocator);
    return .{ .range = .{
        .allocator = allocator,
        .minimum = minimum_bytes,
        .maximum = maximum_bytes,
    } };
}

const parser = @import("../syntax/parser.zig");
const compiler = @import("../program/compiler.zig");
const testing = std.testing;

fn compilePattern(pattern: []const u8, encoding: parser.Encoding) !struct { @import("../syntax/regexp.zig").Regexp, program.Program } {
    const parsed = try parser.parse(testing.allocator, pattern, .{
        .encoding = encoding,
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    });
    var tree = switch (parsed) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    errdefer tree.deinit(testing.allocator);
    const prog = try compiler.compile(testing.allocator, &tree, .{
        .encoding = if (encoding == .utf8) .utf8 else .latin1,
        .max_instructions = 100_000,
    });
    return .{ tree, prog };
}

fn expectRange(pattern: []const u8, max_len: usize, expected_min: []const u8, expected_max: []const u8) !void {
    var values = try compilePattern(pattern, .utf8);
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var result = try possibleMatchRange(testing.allocator, &values[1], max_len);
    defer if (result == .range) result.range.deinit();
    try testing.expect(result == .range);
    try testing.expectEqualSlices(u8, expected_min, result.range.minimum);
    try testing.expectEqualSlices(u8, expected_max, result.range.maximum);
}

test "Bytewise lexical ordering is unsigned" {
    try testing.expect(std.mem.order(u8, "\x70", "\xa0") == .lt);
}

test "Possible match range handwritten fundamentals" {
    try expectRange("", 10, "", "");
    try expectRange("abc(def|ghi)", 10, "abcdef", "abcghi");
    try expectRange("a+hello", 10, "aa", "ahello");
    try expectRange("a*hello", 10, "a", "hello");
    try expectRange("def|abc", 10, "abc", "def");
    try expectRange("(abc)+", 2, "ab", "ac");
    try expectRange("(?i)Abcdef", 10, "ABCDEF", "abcdef");
    try expectRange("[aá]", 4, "a", "á");
    try expectRange("a*", 10, "", "ab");
}

test "Generated finite literal languages have exact lexical bounds" {
    const alphabet = [_]u8{ 'a', 'b' };
    var left_buffer: [3]u8 = undefined;
    var right_buffer: [3]u8 = undefined;
    var pattern_buffer: [16]u8 = undefined;
    for (1..15) |left_ordinal| {
        for (1..15) |right_ordinal| {
            const words = [_]struct { ordinal: usize, buffer: *[3]u8 }{
                .{ .ordinal = left_ordinal, .buffer = &left_buffer },
                .{ .ordinal = right_ordinal, .buffer = &right_buffer },
            };
            var rendered: [2][]const u8 = undefined;
            for (words, 0..) |word, word_index| {
                var relative = word.ordinal - 1;
                var width: usize = alphabet.len;
                var length: usize = 1;
                while (relative >= width) : (length += 1) {
                    relative -= width;
                    width *= alphabet.len;
                }
                var value = relative;
                var index = length;
                while (index != 0) {
                    index -= 1;
                    word.buffer[index] = alphabet[value % alphabet.len];
                    value /= alphabet.len;
                }
                rendered[word_index] = word.buffer[0..length];
            }
            const pattern = try std.fmt.bufPrint(
                &pattern_buffer,
                "(?:{s}|{s})",
                .{ rendered[0], rendered[1] },
            );
            const order = std.mem.order(u8, rendered[0], rendered[1]);
            try expectRange(
                pattern,
                10,
                if (order == .gt) rendered[1] else rendered[0],
                if (order == .gt) rendered[0] else rendered[1],
            );
        }
    }
}

test "Possible match range distinguishes invalid length empty and no finite maximum" {
    var empty_values = try compilePattern("[^\\s\\S]", .utf8);
    defer empty_values[0].deinit(testing.allocator);
    defer empty_values[1].deinit(testing.allocator);
    try testing.expect((try possibleMatchRange(testing.allocator, &empty_values[1], 10)) == .empty_language);
    try testing.expectError(error.InvalidLength, possibleMatchRange(testing.allocator, &empty_values[1], 0));

    for ([_]struct { pattern: []const u8, encoding: parser.Encoding }{
        .{ .pattern = "[\\s\\S]+", .encoding = .latin1 },
        .{ .pattern = "[\\0-\\xff]+", .encoding = .latin1 },
        .{ .pattern = ".+hello", .encoding = .latin1 },
        .{ .pattern = ".*hello", .encoding = .latin1 },
        .{ .pattern = ".*", .encoding = .latin1 },
        .{ .pattern = "\\C*", .encoding = .utf8 },
    }) |case| {
        var values = try compilePattern(case.pattern, case.encoding);
        defer values[0].deinit(testing.allocator);
        defer values[1].deinit(testing.allocator);
        try testing.expect(
            (try possibleMatchRange(testing.allocator, &values[1], 10)) == .no_finite_max,
        );
    }
}

fn allocationAnalysis(allocator: std.mem.Allocator, prog: *const program.Program) !void {
    var result = try possibleMatchRange(allocator, prog, 10);
    if (result == .range) result.range.deinit();
}

test "Possible match analysis owns every allocation failure" {
    var values = try compilePattern("abc(def|ghi)+", .utf8);
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationAnalysis,
        .{&values[1]},
    );
}
