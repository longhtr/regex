//! Reusable replacement-template compiler and bounded output construction.
//!
//! Template compilation copies the source and reduces it to a compact operation
//! stream: source spans, one literal backslash byte, or a capture-group index.
//! Numbered and named references are validated against the supplied Regex once,
//! so execution never reparses template syntax.
//!
//! Rewrite is deliberately layered above Matcher. It does not inspect Program or
//! select an engine. If the operation stream references only group zero, range
//! iteration avoids capture execution; otherwise capture iteration supplies each
//! expansion. Unmatched groups contribute zero bytes.
//!
//! `extract` emits only one template expansion. `replaceFirst` and `replaceAll`
//! preserve unmatched input bytes around expansions. Empty-match behavior is
//! inherited from Matcher iterators, ensuring the same encoding-aware progress.
//!
//! Output length arithmetic is checked before or during append. Byte and
//! replacement ceilings are hard policies, and every successful operation
//! returns an independently owned result. Partial arrays are released on every
//! error path.

const std = @import("std");
const rewrite_module = @This();
const matcher_module = @import("matcher.zig");
const regex_module = @import("regex.zig");
const match_types = @import("match.zig");

pub const CompileError = error{ OutOfMemory, TemplateTooLarge, InvalidEscape, InvalidCaptureGroup };
pub const OperationError = error{
    OutOfMemory,
    ScratchLimitExceeded,
    ReplacementLimitExceeded,
    OutputLimitExceeded,
};

/// Finite rewrite output/work policy. Larger limits must be selected explicitly.
pub const OperationOptions = struct {
    max_output_bytes: usize = 16 * 1024 * 1024,
    max_replacements: usize = 1_000_000,
};

/// Slice of copied template source; 32-bit storage is safe after compile rejects
/// source lengths above that domain.
const Span = struct { start: u32, len: u32 };

/// Predecoded expansion operation. `byte` represents the escaped backslash,
/// while ordinary literal runs remain source spans.
const Op = union(enum) {
    bytes: Span,
    byte: u8,
    group: u32,
};

/// Parsed replacement template owning copied source plus predecoded expansion
/// operations. Literal operations borrow spans in that owned source; group
/// operations contain validated capture indices, so repeated expansion needs no
/// reparsing and remains independent of Matcher scratch between calls.
pub const Rewrite = struct {
    pub const CompileError = rewrite_module.CompileError;
    pub const OperationError = rewrite_module.OperationError;
    pub const Options = rewrite_module.OperationOptions;
    pub const Text = rewrite_module.Text;
    pub const Replacement = rewrite_module.Replacement;

    allocator: std.mem.Allocator,
    source: []u8,
    ops: []Op,

    /// Validates and copies one replacement template. A single pass coalesces
    /// literal spans and resolves numeric or named group escapes against the
    /// Regex; only after the operation list succeeds are source and operations
    /// transferred into an independently reusable owner.
    pub fn compile(
        allocator: std.mem.Allocator,
        regex: *const regex_module.Regex,
        source: []const u8,
    ) rewrite_module.CompileError!Rewrite {
        if (source.len > std.math.maxInt(u32)) return error.TemplateTooLarge;
        var ops: std.ArrayList(Op) = .empty;
        defer ops.deinit(allocator);

        var position: usize = 0;
        while (position < source.len) {
            const literal_start = position;
            while (position < source.len and source[position] != '\\') position += 1;
            if (position > literal_start) try ops.append(allocator, .{ .bytes = .{
                .start = @intCast(literal_start),
                .len = @intCast(position - literal_start),
            } });
            if (position == source.len) break;
            position += 1;
            if (position == source.len) return error.InvalidEscape;
            const escaped = source[position];
            position += 1;
            if (escaped == '\\') {
                try ops.append(allocator, .{ .byte = '\\' });
            } else if (escaped >= '0' and escaped <= '9') {
                const group: u32 = escaped - '0';
                if (group > regex.captureCount()) return error.InvalidCaptureGroup;
                try ops.append(allocator, .{ .group = group });
            } else if (escaped == 'g') {
                if (position == source.len or source[position] != '<')
                    return error.InvalidEscape;
                const reference_start = position + 1;
                const close = std.mem.indexOfScalarPos(u8, source, reference_start, '>') orelse
                    return error.InvalidEscape;
                const reference = source[reference_start..close];
                if (reference.len == 0) return error.InvalidEscape;
                const group = std.fmt.parseInt(u32, reference, 10) catch
                    regex.captureIndex(reference) orelse return error.InvalidCaptureGroup;
                if (group > regex.captureCount()) return error.InvalidCaptureGroup;
                try ops.append(allocator, .{ .group = group });
                position = close + 1;
            } else {
                return error.InvalidEscape;
            }
        }

        const source_copy = try allocator.dupe(u8, source);
        errdefer allocator.free(source_copy);
        return .{
            .allocator = allocator,
            .source = source_copy,
            .ops = try ops.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Rewrite) void {
        if (self.ops.len != 0) self.allocator.free(self.ops);
        if (self.source.len != 0) self.allocator.free(self.source);
        self.* = undefined;
    }

    /// Expands the first match only, without copying unmatched input bytes.
    pub fn extract(
        self: *const Rewrite,
        matcher: *matcher_module.Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) rewrite_module.OperationError!?rewrite_module.Text {
        return self.extractWithOptions(matcher, allocator, input, .{});
    }

    /// Option-bearing extraction. The expansion length is checked before one
    /// exact-capacity allocation, then the predecoded operations are appended.
    pub fn extractWithOptions(
        self: *const Rewrite,
        matcher: *matcher_module.Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        options: OperationOptions,
    ) rewrite_module.OperationError!?rewrite_module.Text {
        var whole_slots: [2]?usize = undefined;
        const captures = if (self.needsSubmatches())
            (try matcher.captures(input)) orelse return null
        else blk: {
            const whole = matcher.find(input) orelse return null;
            whole_slots = .{ whole.start, whole.end };
            break :blk match_types.CaptureView{ .slots = &whole_slots };
        };
        const output_len = try self.expansionLength(
            captures,
            options.max_output_bytes,
        );
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacityPrecise(allocator, output_len);
        try self.appendExpansion(
            &output,
            allocator,
            input,
            captures,
            options.max_output_bytes,
        );
        std.debug.assert(output.items.len == output_len);
        return .{ .allocator = allocator, .bytes = try output.toOwnedSlice(allocator) };
    }

    /// Replaces the first match and always returns independent output.
    pub fn replaceFirst(
        self: *const Rewrite,
        matcher: *matcher_module.Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) rewrite_module.OperationError!rewrite_module.Replacement {
        return self.replaceFirstWithOptions(matcher, allocator, input, .{});
    }

    /// Option-bearing first replacement. A no-match result is still an owned
    /// copy of input with replacement count zero.
    pub fn replaceFirstWithOptions(
        self: *const Rewrite,
        matcher: *matcher_module.Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        options: OperationOptions,
    ) rewrite_module.OperationError!rewrite_module.Replacement {
        var whole_slots: [2]?usize = undefined;
        const captures = if (self.needsSubmatches())
            (try matcher.captures(input)) orelse {
                if (input.len > options.max_output_bytes) return error.OutputLimitExceeded;
                return .{
                    .allocator = allocator,
                    .bytes = try allocator.dupe(u8, input),
                    .replacement_count = 0,
                };
            }
        else blk: {
            const whole = matcher.find(input) orelse {
                if (input.len > options.max_output_bytes) return error.OutputLimitExceeded;
                return .{
                    .allocator = allocator,
                    .bytes = try allocator.dupe(u8, input),
                    .replacement_count = 0,
                };
            };
            whole_slots = .{ whole.start, whole.end };
            break :blk match_types.CaptureView{ .slots = &whole_slots };
        };
        const whole = captures.group(0).?;
        const expansion_len = try self.expansionLength(
            captures,
            options.max_output_bytes,
        );
        const unmatched_len = input.len - (whole.end - whole.start);
        const output_len = std.math.add(usize, unmatched_len, expansion_len) catch
            return error.OutputLimitExceeded;
        if (output_len > options.max_output_bytes) return error.OutputLimitExceeded;
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacityPrecise(allocator, output_len);
        try appendBounded(&output, allocator, input[0..whole.start], options.max_output_bytes);
        try self.appendExpansion(
            &output,
            allocator,
            input,
            captures,
            options.max_output_bytes,
        );
        try appendBounded(&output, allocator, input[whole.end..], options.max_output_bytes);
        std.debug.assert(output.items.len == output_len);
        return .{
            .allocator = allocator,
            .bytes = try output.toOwnedSlice(allocator),
            .replacement_count = 1,
        };
    }

    /// Replaces non-overlapping matches under an explicit result-count bound.
    /// Empty-match progression is shared with the public capture iterator.
    pub fn replaceAll(
        self: *const Rewrite,
        matcher: *matcher_module.Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        max_replacements: usize,
    ) rewrite_module.OperationError!rewrite_module.Replacement {
        return self.replaceAllWithOptions(matcher, allocator, input, .{
            .max_replacements = max_replacements,
        });
    }

    /// Replaces all non-overlapping matches while checking both output bytes and
    /// replacement count before each append/expansion.
    pub fn replaceAllWithOptions(
        self: *const Rewrite,
        matcher: *matcher_module.Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        options: OperationOptions,
    ) rewrite_module.OperationError!rewrite_module.Replacement {
        if (!self.needsSubmatches())
            return self.replaceAllWhole(matcher, allocator, input, options);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var iterator = matcher.captureIterator(input);
        var cursor: usize = 0;
        var count: usize = 0;
        while (try iterator.next()) |captures| {
            if (count == options.max_replacements) return error.ReplacementLimitExceeded;
            const whole = captures.group(0).?;
            try appendBounded(
                &output,
                allocator,
                input[cursor..whole.start],
                options.max_output_bytes,
            );
            try self.appendExpansion(
                &output,
                allocator,
                input,
                captures,
                options.max_output_bytes,
            );
            cursor = whole.end;
            count += 1;
        }
        try appendBounded(
            &output,
            allocator,
            input[cursor..],
            options.max_output_bytes,
        );
        return .{
            .allocator = allocator,
            .bytes = try output.toOwnedSlice(allocator),
            .replacement_count = count,
        };
    }

    /// Group-zero-only specialization: ordinary range iteration avoids capture
    /// engine setup while presenting a synthetic two-slot CaptureView.
    fn replaceAllWhole(
        self: *const Rewrite,
        matcher: *matcher_module.Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        options: OperationOptions,
    ) rewrite_module.OperationError!rewrite_module.Replacement {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var iterator = matcher.iterator(input);
        var cursor: usize = 0;
        var count: usize = 0;
        var slots: [2]?usize = undefined;
        while (iterator.next()) |whole| {
            if (count == options.max_replacements) return error.ReplacementLimitExceeded;
            try appendBounded(
                &output,
                allocator,
                input[cursor..whole.start],
                options.max_output_bytes,
            );
            slots = .{ whole.start, whole.end };
            try self.appendExpansion(
                &output,
                allocator,
                input,
                .{ .slots = &slots },
                options.max_output_bytes,
            );
            cursor = whole.end;
            count += 1;
        }
        try appendBounded(
            &output,
            allocator,
            input[cursor..],
            options.max_output_bytes,
        );
        return .{
            .allocator = allocator,
            .bytes = try output.toOwnedSlice(allocator),
            .replacement_count = count,
        };
    }

    /// Returns whether any operation needs slots beyond whole-match group zero.
    fn needsSubmatches(self: *const Rewrite) bool {
        for (self.ops) |op| switch (op) {
            .group => |group| if (group != 0) return true,
            .bytes, .byte => {},
        };
        return false;
    }

    /// Computes one expansion's exact byte length under checked output policy;
    /// unmatched groups contribute zero.
    fn expansionLength(
        self: *const Rewrite,
        captures: match_types.CaptureView,
        max_output_bytes: usize,
    ) error{OutputLimitExceeded}!usize {
        var total: usize = 0;
        for (self.ops) |op| {
            const additional: usize = switch (op) {
                .bytes => |span| span.len,
                .byte => 1,
                .group => |group| if (captures.group(@intCast(group))) |range|
                    range.end - range.start
                else
                    0,
            };
            if (total > max_output_bytes or
                additional > max_output_bytes - total)
                return error.OutputLimitExceeded;
            total += additional;
        }
        return total;
    }

    /// Interprets the compact operation stream against one CaptureView.
    fn appendExpansion(
        self: *const Rewrite,
        output: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        input: []const u8,
        captures: match_types.CaptureView,
        max_output_bytes: usize,
    ) error{ OutOfMemory, OutputLimitExceeded }!void {
        for (self.ops) |op| switch (op) {
            .bytes => |span| {
                const start: usize = span.start;
                try appendBounded(
                    output,
                    allocator,
                    self.source[start .. start + span.len],
                    max_output_bytes,
                );
            },
            .byte => |byte| {
                const value = [_]u8{byte};
                try appendBounded(output, allocator, &value, max_output_bytes);
            },
            .group => |group| if (captures.group(@intCast(group))) |range|
                try appendBounded(
                    output,
                    allocator,
                    input[range.start..range.end],
                    max_output_bytes,
                ),
        };
    }
};

/// Appends only when the resulting length remains representable and within the
/// hard output ceiling.
fn appendBounded(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_output_bytes: usize,
) error{ OutOfMemory, OutputLimitExceeded }!void {
    if (output.items.len > max_output_bytes or
        bytes.len > max_output_bytes - output.items.len)
        return error.OutputLimitExceeded;
    try output.appendSlice(allocator, bytes);
}

/// Extracted bytes returned by a rewrite operation.
pub const Text = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *Text) void {
        if (self.bytes.len != 0) self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Rewritten bytes and exact replacement count.
pub const Replacement = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    replacement_count: usize,

    pub fn deinit(self: *Replacement) void {
        if (self.bytes.len != 0) self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Quotes arbitrary bytes as one literal pattern under the finite default.
pub fn quoteMeta(
    allocator: std.mem.Allocator,
    input: []const u8,
) error{ OutOfMemory, OutputLimitExceeded }![]u8 {
    return quoteMetaWithLimit(allocator, input, (OperationOptions{}).max_output_bytes);
}

/// Quotes non-alphanumeric bytes with backslashes, spelling NUL as `\\x00` so
/// the produced pattern remains unambiguous, under an explicit output ceiling.
pub fn quoteMetaWithLimit(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_output_bytes: usize,
) error{ OutOfMemory, OutputLimitExceeded }![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (input) |byte| {
        const plain = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or byte == '_' or byte >= 0x80;
        if (plain) {
            const value = [_]u8{byte};
            try appendBounded(&output, allocator, &value, max_output_bytes);
        } else if (byte == 0) {
            try appendBounded(&output, allocator, "\\x00", max_output_bytes);
        } else {
            const escaped = [_]u8{ '\\', byte };
            try appendBounded(&output, allocator, &escaped, max_output_bytes);
        }
    }
    return output.toOwnedSlice(allocator);
}

const testing = std.testing;

fn compileRegex(pattern: []const u8, options: regex_module.CompileOptions) !regex_module.Regex {
    const result = try regex_module.Regex.compile(testing.allocator, pattern, options);
    return switch (result) {
        .success => |regex| regex,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

test "Rewrite validation supports concise numbered and extended references" {
    var regex = try compileRegex("a(?P<left>b)(c)", .{});
    defer regex.deinit();
    for ([_][]const u8{
        "foo",         "foo\\0bar", "foo\\1bar", "foo\\12",   "f\\2o\\1o",
        "f\\\\2o\\1o", "\\g<0>",    "\\g<2>",    "\\g<left>",
    }) |source| {
        var rewrite = try Rewrite.compile(testing.allocator, &regex, source);
        rewrite.deinit();
    }
    try testing.expectError(error.InvalidEscape, Rewrite.compile(testing.allocator, &regex, "foo\\"));
    try testing.expectError(error.InvalidEscape, Rewrite.compile(testing.allocator, &regex, "f\\oo"));
    try testing.expectError(error.InvalidCaptureGroup, Rewrite.compile(testing.allocator, &regex, "foo\\3"));
    try testing.expectError(error.InvalidCaptureGroup, Rewrite.compile(testing.allocator, &regex, "\\g<missing>"));
    try testing.expectError(error.InvalidCaptureGroup, Rewrite.compile(testing.allocator, &regex, "\\g<12>"));
    try testing.expectError(error.InvalidEscape, Rewrite.compile(testing.allocator, &regex, "\\g<>"));
}

test "Extended rewrite references address groups above nine and names" {
    var regex = try compileRegex(
        "(?P<first>.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)",
        .{},
    );
    defer regex.deinit();
    var matcher = try matcher_module.Matcher.init(testing.allocator, &regex);
    defer matcher.deinit();
    var rewrite = try Rewrite.compile(
        testing.allocator,
        &regex,
        "\\g<12>-\\g<10>-\\g<first>",
    );
    defer rewrite.deinit();
    var extracted = (try rewrite.extract(&matcher, testing.allocator, "abcdefghijkl")).?;
    defer extracted.deinit();
    try testing.expectEqualStrings("l-j-a", extracted.bytes);
}

test "Rewrite extract first and global operations match qualification tables" {
    var regex = try compileRegex("(.*)@([^.]*)", .{});
    defer regex.deinit();
    var matcher = try matcher_module.Matcher.init(testing.allocator, &regex);
    defer matcher.deinit();
    var rewrite = try Rewrite.compile(testing.allocator, &regex, "\\2!\\1");
    defer rewrite.deinit();
    var extracted = (try rewrite.extract(&matcher, testing.allocator, "boris@kremvax.ru")).?;
    defer extracted.deinit();
    try testing.expectEqualStrings("kremvax!boris", extracted.bytes);

    var whole_regex = try compileRegex(".*", .{});
    defer whole_regex.deinit();
    var whole_matcher = try matcher_module.Matcher.init(testing.allocator, &whole_regex);
    defer whole_matcher.deinit();
    var whole_rewrite = try Rewrite.compile(testing.allocator, &whole_regex, "'\\0'");
    defer whole_rewrite.deinit();
    var whole = (try whole_rewrite.extract(&whole_matcher, testing.allocator, "foo")).?;
    defer whole.deinit();
    try testing.expectEqualStrings("'foo'", whole.bytes);
    try testing.expect((try rewrite.extract(&matcher, testing.allocator, "no-address")) == null);

    const Case = struct {
        pattern: []const u8,
        rewrite: []const u8,
        input: []const u8,
        first: []const u8,
        all: []const u8,
        count: usize,
    };
    for ([_]Case{
        .{ .pattern = "(qu|[b-df-hj-np-tv-z]*)([a-z]+)", .rewrite = "\\2\\1ay", .input = "the quick brown fox jumps over the lazy dogs.", .first = "ethay quick brown fox jumps over the lazy dogs.", .all = "ethay ickquay ownbray oxfay umpsjay overay ethay azylay ogsday.", .count = 9 },
        .{ .pattern = "\\w+", .rewrite = "\\0-NOSPAM", .input = "abcd.efghi@google.com", .first = "abcd-NOSPAM.efghi@google.com", .all = "abcd-NOSPAM.efghi-NOSPAM@google-NOSPAM.com-NOSPAM", .count = 4 },
        .{ .pattern = "^", .rewrite = "(START)", .input = "foo", .first = "(START)foo", .all = "(START)foo", .count = 1 },
        .{ .pattern = "^", .rewrite = "(START)", .input = "", .first = "(START)", .all = "(START)", .count = 1 },
        .{ .pattern = "$", .rewrite = "(END)", .input = "", .first = "(END)", .all = "(END)", .count = 1 },
        .{ .pattern = "b", .rewrite = "bb", .input = "ababababab", .first = "abbabababab", .all = "abbabbabbabbabb", .count = 5 },
        .{ .pattern = "b", .rewrite = "bb", .input = "bbbbbb", .first = "bbbbbbb", .all = "bbbbbbbbbbbb", .count = 6 },
        .{ .pattern = "b+", .rewrite = "bb", .input = "bbbbbb", .first = "bb", .all = "bb", .count = 1 },
        .{ .pattern = "b*", .rewrite = "bb", .input = "bbbbbb", .first = "bb", .all = "bb", .count = 1 },
        .{ .pattern = "b*", .rewrite = "bb", .input = "aaaaa", .first = "bbaaaaa", .all = "bbabbabbabbabbabb", .count = 6 },
        .{ .pattern = "a.*a", .rewrite = "(\\0)", .input = "aba\naba", .first = "(aba)\naba", .all = "(aba)\n(aba)", .count = 2 },
    }) |case| {
        var case_regex = try compileRegex(case.pattern, .{ .perl_classes = true });
        defer case_regex.deinit();
        var case_matcher = try matcher_module.Matcher.init(testing.allocator, &case_regex);
        defer case_matcher.deinit();
        var case_rewrite = try Rewrite.compile(testing.allocator, &case_regex, case.rewrite);
        defer case_rewrite.deinit();
        var first = try case_rewrite.replaceFirst(&case_matcher, testing.allocator, case.input);
        defer first.deinit();
        try testing.expectEqualStrings(case.first, first.bytes);
        var all = try case_rewrite.replaceAll(&case_matcher, testing.allocator, case.input, 100);
        defer all.deinit();
        try testing.expectEqual(case.count, all.replacement_count);
        try testing.expectEqualStrings(case.all, all.bytes);
    }
}

test "Rewrite operations enforce finite output-byte limits" {
    var regex = try compileRegex("(a)", .{});
    defer regex.deinit();
    var matcher = try matcher_module.Matcher.init(testing.allocator, &regex);
    defer matcher.deinit();
    var rewrite = try Rewrite.compile(testing.allocator, &regex, "x\\1x");
    defer rewrite.deinit();

    try testing.expectError(
        error.OutputLimitExceeded,
        rewrite.extractWithOptions(
            &matcher,
            testing.allocator,
            "a",
            .{ .max_output_bytes = 2 },
        ),
    );
    try testing.expectError(
        error.OutputLimitExceeded,
        rewrite.replaceFirstWithOptions(
            &matcher,
            testing.allocator,
            "bbb",
            .{ .max_output_bytes = 2 },
        ),
    );
    try testing.expectError(
        error.OutputLimitExceeded,
        rewrite.replaceAllWithOptions(
            &matcher,
            testing.allocator,
            "aa",
            .{ .max_output_bytes = 5, .max_replacements = 2 },
        ),
    );
    try testing.expectError(
        error.OutputLimitExceeded,
        quoteMetaWithLimit(testing.allocator, ".", 1),
    );
}

fn allocationCompile(allocator: std.mem.Allocator, regex: *const regex_module.Regex) !void {
    var rewrite = try Rewrite.compile(allocator, regex, "prefix-\\2-\\1-suffix");
    rewrite.deinit();
}

fn allocationReplace(
    allocator: std.mem.Allocator,
    matcher: *matcher_module.Matcher,
    rewrite: *const Rewrite,
) !void {
    var replaced = try rewrite.replaceAll(matcher, allocator, "aaaaa", 16);
    replaced.deinit();
}

test "Rewrite owners clean up every allocation failure and enforce count limits" {
    var regex = try compileRegex("(a)(a*)", .{});
    defer regex.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, allocationCompile, .{&regex});

    var matcher = try matcher_module.Matcher.init(testing.allocator, &regex);
    defer matcher.deinit();
    var rewrite = try Rewrite.compile(testing.allocator, &regex, "\\2\\1");
    defer rewrite.deinit();
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationReplace,
        .{ &matcher, &rewrite },
    );
    try testing.expectError(
        error.ReplacementLimitExceeded,
        rewrite.replaceAll(&matcher, testing.allocator, "aaaaa", 0),
    );
}

test "QuoteMeta preserves arbitrary literal bytes" {
    for ([_]struct { input: []const u8, options: regex_module.CompileOptions }{
        .{ .input = "foo", .options = .{} },
        .{ .input = "foo.bar", .options = .{} },
        .{ .input = "foo\\.bar", .options = .{} },
        .{ .input = "[1-9]", .options = .{} },
        .{ .input = "1.5-2.0?", .options = .{} },
        .{ .input = "\\d", .options = .{} },
        .{ .input = "Who doesn't like ice cream?", .options = .{} },
        .{ .input = "((a|b)c?d*e+[f-h]i)", .options = .{} },
        .{ .input = "((?!)xxx).*yyy", .options = .{} },
        .{ .input = "([", .options = .{} },
        .{ .input = "Plácido Domingo", .options = .{} },
        .{ .input = "27° degrees", .options = .{} },
        .{ .input = "𝅘𝅥", .options = .{} },
        .{ .input = "3\xb2 = 9", .options = .{ .encoding = .latin1 } },
        .{ .input = "\x00", .options = .{ .encoding = .latin1 } },
        .{ .input = "\x001", .options = .{ .encoding = .latin1 } },
    }) |case| {
        const quoted = try quoteMeta(testing.allocator, case.input);
        defer if (quoted.len != 0) testing.allocator.free(quoted);
        var regex = try compileRegex(quoted, case.options);
        defer regex.deinit();
        var matcher = try matcher_module.Matcher.init(testing.allocator, &regex);
        defer matcher.deinit();
        try testing.expect(matcher.fullMatch(case.input));
    }

    for ([_]struct { input: []const u8, rejected: []const u8 }{
        .{ .input = "foo", .rejected = "bar" },
        .{ .input = "...", .rejected = "bar" },
        .{ .input = "\\.", .rejected = "." },
        .{ .input = "(a)", .rejected = "a" },
        .{ .input = "(a|b)", .rejected = "a|b" },
        .{ .input = "[0-9]", .rejected = "0-9" },
        .{ .input = "((?!)xxx)", .rejected = "xxx" },
    }) |case| {
        const quoted = try quoteMeta(testing.allocator, case.input);
        defer if (quoted.len != 0) testing.allocator.free(quoted);
        var regex = try compileRegex(quoted, .{});
        defer regex.deinit();
        var matcher = try matcher_module.Matcher.init(testing.allocator, &regex);
        defer matcher.deinit();
        try testing.expect(!matcher.fullMatch(case.rejected));
    }
}
