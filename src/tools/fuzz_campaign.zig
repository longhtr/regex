//! Deterministic public-API fuzzing with bounded failure reduction.
//!
//! SplitMix64 drives three generation modes: structured valid patterns,
//! deliberately malformed variants, and arbitrary pattern/input bytes. Valid
//! generation also tracks a small independent semantic family, allowing exact
//! checks beyond panic-freedom. Each case crosses encoding, match kind, anchor,
//! compile interface, matching operations, and ownership lifecycle.
//!
//! Failures are classified by a typed mismatch rather than a generic assertion.
//! Reduction deletes pattern/input byte intervals while preserving the same
//! mismatch, producing a small reproduction. Output includes seed, iteration,
//! options, minimized bytes, and expected/actual values.
//!
//! Fixed seeds and finite iteration bounds make the campaign repeatable in the
//! full gate. Allocation-schedule tests reuse the same generated public lifecycle
//! to qualify teardown under every injected failure.

const std = @import("std");
const regex = @import("../root.zig");

const max_pattern_bytes = 256;
const max_input_bytes = 4096;

const Encoding = enum { utf8, latin1 };
const Kind = enum { first, longest };
const CaseAnchor = enum { unanchored, start };
const GenerationMode = enum { structured_valid, deliberately_invalid, arbitrary_bytes };
const SemanticModel = enum { empty, literal_a, literal_b, a_or_b, ab, optional_a };

/// Fully reproducible bounded fuzz input, public compile policy, search range, and
/// optional independent semantic/diagnostic oracle.
const Case = struct {
    generation_mode: GenerationMode = .structured_valid,
    semantic_model: ?SemanticModel = null,
    expected_diagnostic: ?[]const u8 = null,
    pattern: [max_pattern_bytes]u8 = undefined,
    pattern_len: usize = 0,
    input: [max_input_bytes]u8 = undefined,
    input_len: usize = 0,
    encoding: Encoding = .utf8,
    kind: Kind = .first,
    anchor: CaseAnchor = .unanchored,
    range_start: usize = 0,
    range_end: usize = 0,
    flags: u8 = 0,

    fn patternBytes(self: *const Case) []const u8 {
        return self.pattern[0..self.pattern_len];
    }

    fn inputBytes(self: *const Case) []const u8 {
        return self.input[0..self.input_len];
    }

    fn options(self: *const Case) regex.CompileOptions {
        return .{
            .encoding = if (self.encoding == .utf8) .utf8 else .latin1,
            .match_kind = if (self.kind == .first) .first else .longest,
            .case_sensitive = self.flags & 1 == 0,
            .dot_matches_newline = self.flags & 2 != 0,
            .exclude_newline = self.flags & 4 != 0,
            .text_anchors = self.flags & 8 != 0,
            .literal = self.flags & 16 != 0,
            .perl_classes = self.flags & 32 != 0,
            .word_boundary = self.flags & 64 != 0,
        };
    }
};

/// Stable failure identity used to ensure reduction preserves the original
/// violated contract rather than finding an unrelated later failure.
const Mismatch = enum {
    diagnostic_bounds,
    diagnostic_category,
    semantic_find,
    semantic_range,
    semantic_full,
    find_status,
    find_bounds,
    capture_status,
    capture_whole,
    copied_capture_status,
    copied_capture_whole,
    full_capture_status,
    full_capture_whole,
    range_status,
    range_capture_status,
    range_capture_whole,
    iterator_first,
    iterator_bounds,
    iterator_progress,
    count,
    stored_matches,
    stored_matches_reuse,
    set_add,
    set_boolean,
    set_ids,
    filtered_add,
    filtered_first,
    filtered_ids,
    filtered_candidates,
};

/// Deterministic generator whose complete state is the reported campaign seed and
/// iteration progression.
const SplitMix64 = struct {
    state: u64,

    fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }

    fn below(self: *SplitMix64, limit: usize) usize {
        std.debug.assert(limit != 0);
        return @intCast(self.next() % limit);
    }
};

/// Fixed-capacity pattern construction buffer; grammar bounds prove appends fit.
const Bytes = struct {
    items: [max_pattern_bytes]u8 = undefined,
    len: usize = 0,

    fn append(self: *Bytes, bytes: []const u8) void {
        std.debug.assert(self.len + bytes.len <= self.items.len);
        @memcpy(self.items[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }
};

fn generateAtom(random: *SplitMix64, output: *Bytes) void {
    const atoms = [_][]const u8{
        "a",   "b", ".", "[ab]", "[^a]", "[a-c]", "\\w", "\\s",
        "\\b", "^", "$", "(?:)",
        "é",
        "[α-γ]",
    };
    output.append(atoms[random.below(atoms.len)]);
}

/// Recursively renders a bounded valid grammar. Depth is campaign-controlled and
/// small, so this generator recursion cannot reflect untrusted pattern depth.
fn generateExpression(random: *SplitMix64, output: *Bytes, depth: usize) void {
    if (depth == 0) return generateAtom(random, output);
    switch (random.below(6)) {
        0 => {
            generateExpression(random, output, depth - 1);
            generateExpression(random, output, depth - 1);
        },
        1 => {
            output.append("(?:");
            generateExpression(random, output, depth - 1);
            output.append("|");
            generateExpression(random, output, depth - 1);
            output.append(")");
        },
        2 => {
            output.append("(?:");
            generateExpression(random, output, depth - 1);
            const repeats = [_][]const u8{ ")?", ")*", ")+", ")??", ")*?", ")+?" };
            output.append(repeats[random.below(repeats.len)]);
        },
        3 => {
            output.append("(");
            generateExpression(random, output, depth - 1);
            output.append(")");
        },
        4 => {
            output.append("(?:");
            generateExpression(random, output, depth - 1);
            output.append("){0,3}");
        },
        else => generateAtom(random, output),
    }
}

/// Chooses generation mode, bytes, options, range, and any available independent
/// oracle from one deterministic random stream.
fn generateCase(random: *SplitMix64) Case {
    var result: Case = .{};
    switch (random.below(8)) {
        0 => {
            result.generation_mode = .arbitrary_bytes;
            const syntax = "ab()[]{}?*+|.^$\\0123456789P<>=!-:\xff\x80";
            result.pattern_len = random.below(64);
            for (result.pattern[0..result.pattern_len]) |*byte|
                byte.* = syntax[random.below(syntax.len)];
        },
        1 => {
            result.generation_mode = .deliberately_invalid;
            const malformed = [_]struct { pattern: []const u8, diagnostic: []const u8 }{
                .{ .pattern = "(", .diagnostic = "missing_paren" },
                .{ .pattern = ")", .diagnostic = "unexpected_paren" },
                .{ .pattern = "\\", .diagnostic = "trailing_backslash" },
                .{ .pattern = "\\1", .diagnostic = "bad_escape" },
                .{ .pattern = "\\x{", .diagnostic = "bad_utf8" },
                .{ .pattern = "\\p", .diagnostic = "bad_char_range" },
                .{ .pattern = "*", .diagnostic = "repeat_argument" },
                .{ .pattern = "a**", .diagnostic = "repeat_operator" },
                .{ .pattern = "[abc", .diagnostic = "missing_bracket" },
                .{ .pattern = "(?=a)", .diagnostic = "bad_perl_operator" },
                .{ .pattern = "a{1001}", .diagnostic = "repeat_size" },
                .{ .pattern = "(?P<name", .diagnostic = "bad_named_capture" },
            };
            const selected = malformed[random.below(malformed.len)];
            result.pattern_len = selected.pattern.len;
            @memcpy(result.pattern[0..selected.pattern.len], selected.pattern);
            result.expected_diagnostic = selected.diagnostic;
        },
        2 => {
            result.generation_mode = .structured_valid;
            const modeled = [_]struct { source: []const u8, model: SemanticModel }{
                .{ .source = "(?:)", .model = .empty },
                .{ .source = "a", .model = .literal_a },
                .{ .source = "b", .model = .literal_b },
                .{ .source = "a|b", .model = .a_or_b },
                .{ .source = "ab", .model = .ab },
                .{ .source = "a?", .model = .optional_a },
            };
            const selected = modeled[random.below(modeled.len)];
            result.pattern_len = selected.source.len;
            @memcpy(result.pattern[0..selected.source.len], selected.source);
            result.semantic_model = selected.model;
        },
        else => {
            result.generation_mode = .structured_valid;
            var generated: Bytes = .{};
            generateExpression(random, &generated, 1 + random.below(3));
            result.pattern_len = generated.len;
            @memcpy(result.pattern[0..generated.len], generated.items[0..generated.len]);
        },
    }

    const alphabet = [_]u8{ 'a', 'b', 'c', ' ', '\n', 0, 0x80, 0xbf, 0xc2, 0xe2, 0xff };
    result.input_len = if (random.below(128) == 0)
        1024 + random.below(max_input_bytes - 1023)
    else
        random.below(49);
    for (result.input[0..result.input_len]) |*byte|
        byte.* = alphabet[random.below(alphabet.len)];
    result.encoding = if (random.below(4) == 0) .latin1 else .utf8;
    result.kind = if (random.below(2) == 0) .first else .longest;
    result.anchor = if (random.below(3) == 0) .start else .unanchored;
    result.flags = @as(u8, @truncate(random.next())) & 0x7f;
    switch (result.generation_mode) {
        .structured_valid => {
            result.flags |= 0x20 | 0x40;
            if (result.semantic_model != null) {
                result.flags |= 0x01;
                result.flags &= ~@as(u8, 0x10);
            }
        },
        .deliberately_invalid => {
            result.flags &= ~@as(u8, 0x10);
            result.flags |= 0x20 | 0x40;
        },
        .arbitrary_bytes => {},
    }
    if (random.below(32) == 0) {
        result.flags &= ~@as(u8, 0x10);
        result.flags |= 0x80;
    }
    result.range_start = random.below(result.input_len + 1);
    result.range_end = result.range_start + random.below(result.input_len - result.range_start + 1);
    return result;
}

fn modelAt(model: SemanticModel, input: []const u8, start: usize, end: usize) ?usize {
    return switch (model) {
        .empty => start,
        .literal_a => if (start < end and input[start] == 'a') start + 1 else null,
        .literal_b => if (start < end and input[start] == 'b') start + 1 else null,
        .a_or_b => if (start < end and (input[start] == 'a' or input[start] == 'b')) start + 1 else null,
        .ab => if (start + 2 <= end and std.mem.eql(u8, input[start .. start + 2], "ab")) start + 2 else null,
        .optional_a => if (start < end and input[start] == 'a') start + 1 else start,
    };
}

/// Computes leftmost range for the tiny reviewed model vocabulary without using
/// the production parser or matcher.
fn modelFind(
    model: SemanticModel,
    input: []const u8,
    start: usize,
    end: usize,
    anchor: CaseAnchor,
) ?regex.Match {
    var position = start;
    while (position <= end) : (position += 1) {
        if (modelAt(model, input, position, end)) |match_end|
            return .{ .start = position, .end = match_end };
        if (anchor == .start) break;
    }
    return null;
}

fn containsId(values: []const u32, wanted: u32) bool {
    for (values) |value| if (value == wanted) return true;
    return false;
}

/// Independent one-scalar dot model, including canonical UTF-8 validation and
/// malformed-byte rejection.
fn dotWidth(input: []const u8, position: usize, encoding: Encoding, dot_nl: bool) ?usize {
    if (position >= input.len or (input[position] == '\n' and !dot_nl)) return null;
    if (encoding == .latin1 or input[position] <= 0x7f) return 1;
    const first = input[position];
    const width: usize = if (first >= 0xc2 and first <= 0xdf)
        2
    else if (first >= 0xe0 and first <= 0xef)
        3
    else if (first >= 0xf0 and first <= 0xf4)
        4
    else
        return null;
    if (width > input.len - position) return null;
    for (input[position + 1 .. position + width]) |byte|
        if (byte < 0x80 or byte > 0xbf) return null;
    return width;
}

fn aThenB(input: []const u8, encoding: Encoding, dot_nl: bool) bool {
    for (input, 0..) |byte, start| {
        if (byte != 'a') continue;
        var position = start + 1;
        while (position < input.len) {
            if (input[position] == 'b') return true;
            position += dotWidth(input, position, encoding, dot_nl) orelse break;
        }
    }
    return false;
}

/// Exercises Set and Filtered lifecycle/results around the same case, checking
/// exact verification and conservative candidate-superset contracts.
fn checkCollections(
    allocator: std.mem.Allocator,
    case: *const Case,
    expected_first: bool,
) !?Mismatch {
    const input = case.inputBytes();
    const collection_patterns = [_][]const u8{
        case.patternBytes(), "a", "b", "a.*b", "(?:)", "[ab]+",
    };
    const expected_matches = [_]bool{
        expected_first,
        std.mem.indexOfScalar(u8, input, 'a') != null,
        std.mem.indexOfScalar(u8, input, 'b') != null,
        aThenB(
            input,
            case.encoding,
            case.flags & 0x02 != 0 and case.flags & 0x04 == 0,
        ),
        true,
        std.mem.indexOfAny(u8, input, "ab") != null,
    };
    var expected_storage: [collection_patterns.len]u32 = undefined;
    var expected_len: usize = 0;
    for (expected_matches, 0..) |matched, id| if (matched) {
        expected_storage[expected_len] = @intCast(id);
        expected_len += 1;
    };
    const expected = expected_storage[0..expected_len];

    var set_builder = regex.Set.Builder.init(allocator, case.options(), .unanchored);
    defer set_builder.deinit();
    for (collection_patterns, 0..) |pattern, id| {
        const added = try set_builder.add(pattern);
        if (added != .success or added.success != id) return .set_add;
    }
    var set = try set_builder.compile();
    defer set.deinit();
    var set_matcher = try set.matcher(allocator);
    defer set_matcher.deinit();
    if (set_matcher.isMatch(input) != (expected.len != 0)) return .set_boolean;
    var set_ids = try set_matcher.allMatches(allocator, input, collection_patterns.len);
    defer set_ids.deinit();
    if (!std.mem.eql(u32, set_ids.values(), expected)) return .set_ids;

    var filtered_builder = regex.Filtered.Builder.init(allocator, case.options(), 2);
    defer filtered_builder.deinit();
    for (collection_patterns, 0..) |pattern, id| {
        const added = try filtered_builder.add(pattern);
        if (added != .success or added.success != id) return .filtered_add;
    }
    var filtered = try filtered_builder.compile();
    defer filtered.deinit();
    var filtered_matcher = try filtered.matcher(allocator);
    defer filtered_matcher.deinit();
    var atom_ids: std.ArrayList(u32) = .empty;
    defer atom_ids.deinit(allocator);
    for (filtered.atoms(), 0..) |atom, id|
        if (std.mem.indexOf(u8, input, atom) != null)
            try atom_ids.append(allocator, @intCast(id));

    const first_id = try filtered_matcher.firstMatch(input, atom_ids.items);
    const expected_first_id: ?u32 = if (expected.len == 0) null else expected[0];
    if (first_id != expected_first_id) return .filtered_first;
    var filtered_ids = try filtered_matcher.allMatches(
        allocator,
        input,
        atom_ids.items,
        collection_patterns.len,
    );
    defer filtered_ids.deinit();
    if (!std.mem.eql(u32, filtered_ids.values(), expected)) return .filtered_ids;
    var candidates = try filtered_matcher.allCandidates(
        allocator,
        atom_ids.items,
        collection_patterns.len,
    );
    defer candidates.deinit();
    for (expected) |id|
        if (!containsId(candidates.values(), id)) return .filtered_candidates;
    return null;
}

/// Runs one complete public lifecycle and returns the first stable mismatch tag;
/// null means every applicable invariant and independent oracle passed.
fn checkCase(allocator: std.mem.Allocator, case: *const Case) !?Mismatch {
    const compiled = try regex.Regex.compile(allocator, case.patternBytes(), case.options());
    var expression = switch (compiled) {
        .diagnostic => |diagnostic| {
            if (diagnostic.start > diagnostic.end or diagnostic.end > case.pattern_len)
                return .diagnostic_bounds;
            if (case.expected_diagnostic) |expected|
                if (!std.mem.eql(u8, expected, @tagName(diagnostic.code)))
                    return .diagnostic_category;
            return null;
        },
        .success => |value| success: {
            if (case.expected_diagnostic != null) {
                var unexpected = value;
                unexpected.deinit();
                return .diagnostic_category;
            }
            break :success value;
        },
    };
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();
    const input = case.inputBytes();

    const found = matcher.find(input);
    if (case.semantic_model) |model|
        if (!std.meta.eql(modelFind(model, input, 0, input.len, .unanchored), found))
            return .semantic_find;
    if (matcher.isMatch(input) != (found != null)) return .find_status;
    if (found) |value| if (value.slice(input) == null) return .find_bounds;

    const captured = try matcher.captures(input);
    if ((captured != null) != (found != null)) return .capture_status;
    if (captured) |view| if (!std.meta.eql(view.group(0), found)) return .capture_whole;

    var captures = try matcher.copyCaptures(allocator, input);
    defer if (captures) |*value| value.deinit();
    if ((captures != null) != (found != null)) return .copied_capture_status;
    if (captures) |*value| if (!std.meta.eql(value.group(0), found)) return .copied_capture_whole;

    const full = matcher.fullMatch(input);
    if (case.semantic_model) |model|
        if ((modelAt(model, input, 0, input.len) == input.len) != full)
            return .semantic_full;
    const full_captured = try matcher.fullCaptures(input);
    if ((full_captured != null) != full) return .full_capture_status;
    if (full_captured) |view| {
        const expected = regex.Match{ .start = 0, .end = input.len };
        if (!std.meta.eql(view.group(0), expected)) return .full_capture_whole;
    }

    const range = regex.SearchRange{ .start = case.range_start, .end = case.range_end };
    const anchor: regex.Anchor = if (case.anchor == .unanchored) .unanchored else .start;
    const range_found = try matcher.findIn(input, range, anchor);
    if (case.semantic_model) |model|
        if (!std.meta.eql(modelFind(model, input, case.range_start, case.range_end, case.anchor), range_found))
            return .semantic_range;
    if ((try matcher.isMatchIn(input, range, anchor)) != (range_found != null))
        return .range_status;
    const range_captured = try matcher.capturesIn(input, range, anchor);
    if ((range_captured != null) != (range_found != null)) return .range_capture_status;
    if (range_captured) |view|
        if (!std.meta.eql(view.group(0), range_found)) return .range_capture_whole;

    var iterator = matcher.iterator(input);
    var prior: ?regex.Match = null;
    var count: usize = 0;
    while (iterator.next()) |value| {
        if (count == 0 and !std.meta.eql(found, value)) return .iterator_first;
        if (value.slice(input) == null) return .iterator_bounds;
        if (prior) |previous| {
            if (value.start < previous.end) return .iterator_progress;
            if (value.start == value.end and previous.start == previous.end and
                value.start == previous.start) return .iterator_progress;
        }
        prior = value;
        count += 1;
        if (count > input.len + 2) return .iterator_progress;
    }
    if ((count != 0) != (found != null)) return .iterator_first;
    if (matcher.count(input) != count) return .count;

    var stored = try matcher.findAll(allocator, input, input.len + 1);
    defer stored.deinit();
    if (stored.values().len != count) return .stored_matches;
    var stored_iterator = matcher.iterator(input);
    for (stored.values()) |value|
        if (!std.meta.eql(value, stored_iterator.next() orelse return .stored_matches))
            return .stored_matches;
    if (stored_iterator.next() != null) return .stored_matches;
    var saved: [max_input_bytes + 1]regex.Match = undefined;
    @memcpy(saved[0..stored.values().len], stored.values());
    _ = matcher.find("matcher reuse must not mutate owned matches");
    for (saved[0..stored.values().len], stored.values()) |before, after|
        if (!std.meta.eql(before, after)) return .stored_matches_reuse;

    if (case.flags & 0x80 != 0)
        if (try checkCollections(allocator, case, found != null)) |mismatch| return mismatch;
    return null;
}

fn removeByte(bytes: []u8, length: *usize, index: usize) void {
    std.mem.copyForwards(u8, bytes[index .. length.* - 1], bytes[index + 1 .. length.*]);
    length.* -= 1;
}

fn stillFails(allocator: std.mem.Allocator, case: *const Case, target: Mismatch) bool {
    const mismatch = checkCase(allocator, case) catch return false;
    return mismatch == target;
}

/// Greedily deletes pattern then input bytes while the exact target mismatch
/// remains reproducible; options/range are retained for faithful reporting.
fn reduceCase(allocator: std.mem.Allocator, case: *Case, target: Mismatch) void {
    var index: usize = 0;
    while (index < case.pattern_len) {
        var candidate = case.*;
        removeByte(&candidate.pattern, &candidate.pattern_len, index);
        if (stillFails(allocator, &candidate, target)) {
            case.* = candidate;
            continue;
        }
        index += 1;
    }
    index = 0;
    while (index < case.input_len) {
        var candidate = case.*;
        removeByte(&candidate.input, &candidate.input_len, index);
        candidate.range_start = @min(candidate.range_start, candidate.input_len);
        candidate.range_end = @min(@max(candidate.range_start, candidate.range_end), candidate.input_len);
        if (stillFails(allocator, &candidate, target)) {
            case.* = candidate;
            continue;
        }
        index += 1;
    }
    var bit: u8 = 1;
    while (bit != 0) {
        if (case.flags & bit != 0) {
            var candidate = case.*;
            candidate.flags &= ~bit;
            if (stillFails(allocator, &candidate, target)) case.* = candidate;
        }
        bit = if (bit == 128) 0 else bit << 1;
    }
}

fn reportFailure(case: *const Case, mismatch: Mismatch, seed: u64, iteration: usize) void {
    std.debug.print(
        "fuzz mismatch kind={s} mode={s} model={s} expected_diagnostic={s} " ++
            "seed={d} iteration={d}\n" ++
            "case={x}|{x}|{s}|{s}|{s}|{d}|{d}|{x}\n",
        .{
            @tagName(mismatch),
            @tagName(case.generation_mode),
            if (case.semantic_model) |model| @tagName(model) else "none",
            case.expected_diagnostic orelse "none",
            seed,
            iteration,
            case.patternBytes(),
            case.inputBytes(),
            @tagName(case.encoding),
            @tagName(case.kind),
            @tagName(case.anchor),
            case.range_start,
            case.range_end,
            case.flags,
        },
    );
}

/// Deterministic campaign seed, replay offset, and finite case count.
pub const Config = struct {
    seed: u64 = 0x72656765785f667a,
    start: usize = 0,
    iterations: usize = 10_000,
};

/// Generates and checks the configured cases, reducing/reporting the first
/// mismatch with enough state for exact replay.
pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    var random = SplitMix64{ .state = config.seed };
    for (0..config.start) |_| _ = generateCase(&random);
    for (0..config.iterations) |offset| {
        const iteration = config.start + offset;
        var case = generateCase(&random);
        if (try checkCase(allocator, &case)) |mismatch| {
            reduceCase(allocator, &case, mismatch);
            reportFailure(&case, mismatch, config.seed, iteration);
            return error.FuzzMismatch;
        }
    }
    std.debug.print(
        "Fuzz campaign...OK\n" ++
            "  Seed: {d}\n" ++
            "  Starting iteration: {d}\n" ++
            "  Iterations: {d}\n",
        .{ config.seed, config.start, config.iterations },
    );
}

pub fn main(init: std.process.Init) !void {
    var config: Config = .{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |argument| {
        const value = args.next() orelse return error.MissingCampaignArgument;
        if (std.mem.eql(u8, argument, "--seed")) {
            config.seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, argument, "--start")) {
            config.start = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, argument, "--iterations")) {
            config.iterations = try std.fmt.parseInt(usize, value, 10);
        } else return error.InvalidCampaignArgument;
    }
    if (config.iterations == 0) return error.InvalidCampaignArgument;
    try run(std.heap.c_allocator, config);
}

test "Fuzz generation is reproducible from its local seed" {
    var left = SplitMix64{ .state = 0x5eed2025 };
    var right = SplitMix64{ .state = 0x5eed2025 };
    for (0..64) |_| {
        const a = generateCase(&left);
        const b = generateCase(&right);
        try std.testing.expectEqual(a.generation_mode, b.generation_mode);
        try std.testing.expectEqual(a.semantic_model, b.semantic_model);
        try std.testing.expectEqualStrings(a.expected_diagnostic orelse "", b.expected_diagnostic orelse "");
        try std.testing.expectEqualSlices(u8, a.patternBytes(), b.patternBytes());
        try std.testing.expectEqualSlices(u8, a.inputBytes(), b.inputBytes());
        try std.testing.expectEqual(a.encoding, b.encoding);
        try std.testing.expectEqual(a.kind, b.kind);
        try std.testing.expectEqual(a.anchor, b.anchor);
        try std.testing.expectEqual(a.range_start, b.range_start);
        try std.testing.expectEqual(a.range_end, b.range_end);
        try std.testing.expectEqual(a.flags, b.flags);
    }
}

test "Fixed campaign seed covers every generated mode and semantic family" {
    var random = SplitMix64{ .state = 0x72656765785f667a };
    var modes = std.EnumSet(GenerationMode).initEmpty();
    var models = std.EnumSet(SemanticModel).initEmpty();
    const diagnostics = [_][]const u8{
        "missing_paren",
        "unexpected_paren",
        "trailing_backslash",
        "bad_escape",
        "bad_utf8",
        "bad_char_range",
        "repeat_argument",
        "repeat_operator",
        "missing_bracket",
        "bad_perl_operator",
        "repeat_size",
        "bad_named_capture",
    };
    var seen_diagnostics = std.StaticBitSet(diagnostics.len).initEmpty();
    for (0..4096) |_| {
        const case = generateCase(&random);
        modes.insert(case.generation_mode);
        if (case.semantic_model) |model| models.insert(model);
        if (case.expected_diagnostic) |expected|
            for (diagnostics, 0..) |diagnostic, index|
                if (std.mem.eql(u8, expected, diagnostic)) seen_diagnostics.set(index);
    }
    try std.testing.expectEqual(std.meta.fields(GenerationMode).len, modes.count());
    try std.testing.expectEqual(std.meta.fields(SemanticModel).len, models.count());
    try std.testing.expectEqual(diagnostics.len, seen_diagnostics.count());
}

test "Fuzz byte deletion preserves order" {
    var bytes = [_]u8{ 'a', 'b', 'c', 'd' };
    var len: usize = bytes.len;
    removeByte(&bytes, &len, 1);
    try std.testing.expectEqualSlices(u8, "acd", bytes[0..len]);
}

/// Drives every allocation-owning public artifact reachable from one accepted
/// pattern so failure injection exercises nested teardown as well as success.
/// Compile diagnostics are ordinary terminal outcomes; successful compilation
/// proceeds through matching, copied results, iteration, and lexical analysis.
fn allocationLifecycle(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    input: []const u8,
) !void {
    const compiled = try regex.Regex.compile(allocator, pattern, .{});
    var expression = switch (compiled) {
        .diagnostic => return,
        .success => |value| value,
    };
    defer expression.deinit();
    var matcher = try regex.Matcher.init(allocator, &expression);
    defer matcher.deinit();
    _ = matcher.find(input);
    _ = try matcher.captures(input);
    var captures = try matcher.copyCaptures(allocator, input);
    defer if (captures) |*value| value.deinit();
    var matches = try matcher.findAll(allocator, input, input.len + 1);
    defer matches.deinit();
    var possible = try expression.possibleMatchRange(allocator, 16);
    switch (possible) {
        .range => |*range| range.deinit(),
        .empty_language, .no_finite_max => {},
    }
}

fn fuzzPublicCase(_: void, smith: *std.testing.Smith) !void {
    var case: Case = .{};
    case.pattern_len = smith.slice(&case.pattern);
    case.input_len = smith.slice(&case.input);
    case.encoding = if (smith.value(bool)) .utf8 else .latin1;
    case.kind = if (smith.value(bool)) .first else .longest;
    case.anchor = if (smith.value(bool)) .unanchored else .start;
    case.flags = smith.value(u8) & 0x7f;
    case.range_start = smith.valueRangeAtMost(u32, 0, @intCast(case.input_len));
    case.range_end = smith.valueRangeAtMost(
        u32,
        @intCast(case.range_start),
        @intCast(case.input_len),
    );
    try std.testing.expect((try checkCase(std.testing.allocator, &case)) == null);
}

test "Fuzz public parser compiler executor and API invariants" {
    try std.testing.fuzz({}, fuzzPublicCase, .{});
}

test "Generated public lifecycles survive every allocation schedule" {
    for ([_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "((?:a|b)+)([ab]?)", .input = "xxabba" },
        .{ .pattern = "(?m:^)([a-z]+)|([0-9]+)$", .input = "x\nalpha42" },
        .{ .pattern = "(?:é|[α-γ]|[^a]){0,3}", .input = "éβ!" },
    }) |case| try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationLifecycle,
        .{ case.pattern, case.input },
    );
}
