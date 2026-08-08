//! Pattern grammar, option semantics, and byte-accurate diagnostics.
//!
//! Parser is a single forward scan over pattern bytes plus the explicit stacks in
//! `frame_reducer.zig`. The current `Flags` value determines folding, dot/newline,
//! anchor, and greediness behavior. Opening a scoped group stores restoration
//! state in its frame; no syntax nesting consumes the process stack.
//!
//! At each position the parser distinguishes structural operators from atoms,
//! asks `scanner.zig` for literal rune/escape decoding, and delegates bracket
//! terms to `char_class.zig`. Completed atoms are inserted into the reducer;
//! postfix repetition replaces the most recent atom while preserving greediness
//! and capture/group boundaries. Counted-repeat parsing uses a temporary cursor
//! so an incomplete brace form can remain literal without partial consumption.
//!
//! Syntax modes initialize flags and gate operators rather than selecting an
//! executor. Perl mode enables scoped flags, lazy suffixes, named/noncapturing
//! groups, Unicode classes, raw bytes, and absolute escapes. POSIX mode starts
//! with line anchors and permits its named bracket classes; explicit options can
//! opt in Perl classes or word boundaries.
//!
//! Character classes are normalized before entering the arena. UTF-8 patterns
//! are prevalidated and every scanner/reducer failure is translated to one
//! `Diagnostic` with absolute half-open byte offsets. Node, capture, repeat, and
//! pattern-byte limits are checked during construction. On success the parser
//! returns one owning `Regexp`; on any diagnostic or allocation error every
//! temporary builder and partial arena is released.

const std = @import("std");
const char_class = @import("char_class.zig");
const class_terms = @import("class_terms.zig");
const frame_reducer = @import("frame_reducer.zig");
const regexp_module = @import("regexp.zig");
const rune_range = @import("rune_range.zig");
const scanner = @import("scanner.zig");
const unicode = @import("../unicode/data.zig");

pub const Encoding = scanner.Encoding;
/// Grammar/anchor-default mode; execution remains the same published Program
/// model after parsing.
pub const Semantics = enum { perl, posix };

/// Syntax flags and finite front-end limits. Match selection and execution
/// budgets are intentionally absent from parser policy.
pub const Options = struct {
    encoding: Encoding = .utf8,
    semantics: Semantics = .perl,
    case_sensitive: bool = true,
    dot_nl: bool = false,
    never_nl: bool = false,
    one_line: bool = false,
    literal: bool = false,
    never_capture: bool = false,
    perl_classes: bool = false,
    word_boundary: bool = false,
    max_pattern_bytes: usize,
    max_nodes: u32,
    max_captures: u32,
    max_repeat: u32 = 1000,
};

/// Stable diagnostic categories; precise spelling details remain represented by
/// the accompanying source span.
pub const ErrorCode = enum {
    bad_escape,
    bad_char_range,
    missing_bracket,
    missing_paren,
    unexpected_paren,
    trailing_backslash,
    repeat_argument,
    repeat_size,
    repeat_operator,
    bad_perl_operator,
    bad_utf8,
    bad_named_capture,
    resource_limit,
};

/// One parser/policy failure over absolute half-open pattern byte offsets.
pub const Diagnostic = struct {
    code: ErrorCode,
    start: usize,
    end: usize,
};

/// Parse transaction outcome. Success transfers the arena; diagnostic transfers
/// no allocation ownership.
pub const Result = union(enum) {
    success: regexp_module.Regexp,
    diagnostic: Diagnostic,
};

/// Lexically scoped semantic state derived from options and inline flag edits.
const Flags = struct {
    fold: bool,
    one_line: bool,
    dot_nl: bool,
    non_greedy: bool,
    perl_x: bool,
    perl_classes: bool,
    word_boundary: bool,
    unicode_groups: bool,
};

const Reduction = frame_reducer.Reduction(Flags);

/// Successfully recognized complete brace-repeat form and its ending cursor.
const CountedRepeat = struct {
    min: u32,
    max: ?u32,
    end: usize,
};

/// Mutable state for one forward parse transaction. Reducer owns precedence
/// stacks; class Builder values are scoped to individual bracket expressions.
const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    options: Options,
    flags: Flags,
    position: usize = 0,
    syntax: regexp_module.Regexp = .{},
    reduction: Reduction = .{},
    diagnostic: ?Diagnostic = null,

    // Lifecycle and top-level token loop.

    fn deinit(self: *Parser) void {
        self.reduction.deinit(self.allocator);
        self.syntax.deinit(self.allocator);
        self.* = undefined;
    }

    /// Opens the synthetic outer frame, consumes tokens to EOF, and publishes one
    /// reduced root after unmatched-group checks.
    fn run(self: *Parser) (error{ OutOfMemory, ParseFailed })!void {
        try self.reduction.openFrame(self.allocator, self.flags, null, 0);

        if (self.options.literal) {
            while (self.position < self.pattern.len) {
                const decoded = try self.decodeRune(self.position);
                try self.appendLiteral(decoded.rune, decoded.width);
            }
        } else {
            while (self.position < self.pattern.len) try self.parseToken();
        }

        if (self.reduction.frameCount() != 1) {
            const frame = self.reduction.currentFrame();
            return self.fail(.missing_paren, frame.opening, frame.opening + 1);
        }
        self.syntax.root = self.reduction.finishTop(
            self.allocator,
            &self.syntax,
            self.options.max_nodes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NodeLimit => return self.fail(.resource_limit, self.position, self.position),
            error.FrameLimit => return self.fail(.resource_limit, 0, self.pattern.len),
        };
    }

    /// Dispatches the token at `position`, consuming exactly one grammatical unit
    /// or recording a diagnostic via `fail`.
    fn parseToken(self: *Parser) (error{ OutOfMemory, ParseFailed })!void {
        const byte = self.pattern[self.position];
        switch (byte) {
            '|' => {
                self.position += 1;
                try self.finishAlternative();
            },
            '(' => try self.openGroup(),
            ')' => try self.closeGroup(),
            '*', '+', '?' => try self.applySimpleRepeat(byte),
            '{' => {
                if (try self.parseCountedRepeat()) |repeat| {
                    try self.applyRepeat(repeat.min, repeat.max, self.position, repeat.end);
                } else {
                    try self.appendLiteral('{', 1);
                }
            },
            '^' => {
                const kind: regexp_module.Node = if (self.flags.one_line) .begin_text else .begin_line;
                try self.appendNode(kind, self.position, self.position + 1);
                self.position += 1;
            },
            '$' => {
                const kind: regexp_module.Node = if (self.flags.one_line) .end_text else .end_line;
                try self.appendNode(kind, self.position, self.position + 1);
                self.position += 1;
            },
            '.' => {
                try self.appendNode(.{ .any_char = .{
                    .match_newline = self.flags.dot_nl and !self.options.never_nl,
                } }, self.position, self.position + 1);
                self.position += 1;
            },
            '[' => try self.parseClass(),
            '\\' => try self.parseEscape(),
            else => {
                const decoded = try self.decodeRune(self.position);
                try self.appendLiteral(decoded.rune, decoded.width);
            },
        }
    }

    // Groups, flags, and precedence reduction.

    /// Classifies one opening delimiter as a plain/named capture, noncapturing
    /// group, scoped flag edit, or rejected lookaround. It snapshots outer flags
    /// in the reducer frame; a completed unscoped flag edit consumes `)` and
    /// deliberately opens no frame.
    fn openGroup(self: *Parser) (error{ OutOfMemory, ParseFailed })!void {
        const opening = self.position;
        self.position += 1;
        const outer_flags = self.flags;
        var capture: ?Reduction.Capture = null;

        if (self.position < self.pattern.len and self.pattern[self.position] == '?') {
            self.position += 1;
            if (!self.flags.perl_x)
                return self.fail(.repeat_argument, opening, self.position);
            if (self.position < self.pattern.len and self.pattern[self.position] == ':') {
                self.position += 1;
            } else if (self.namedCapturePrefix()) |name_start| {
                var name_end = name_start;
                while (name_end < self.pattern.len and self.pattern[name_end] != '>') : (name_end += 1) {}
                if (name_end == self.pattern.len or !self.validCaptureName(self.pattern[name_start..name_end])) {
                    return self.fail(.bad_named_capture, opening, @min(name_end + 1, self.pattern.len));
                }
                const name = self.syntax.addName(self.allocator, self.pattern[name_start..name_end]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ProgramTooLarge => return self.fail(.resource_limit, opening, name_end + 1),
                };
                self.position = name_end + 1;
                capture = try self.newCapture(name, opening);
            } else if ((self.position < self.pattern.len and
                (self.pattern[self.position] == '=' or self.pattern[self.position] == '!')) or
                (self.position + 1 < self.pattern.len and self.pattern[self.position] == '<' and
                    (self.pattern[self.position + 1] == '=' or self.pattern[self.position + 1] == '!')))
            {
                const end = @min(self.position + (if (self.pattern[self.position] == '<') @as(usize, 2) else 1), self.pattern.len);
                return self.fail(.bad_perl_operator, opening, end);
            } else {
                const scoped = try self.parseFlagEdit(opening);
                if (!scoped) return;
            }
        } else if (!self.options.never_capture) {
            capture = try self.newCapture(null, opening);
        }

        try self.reduction.openFrame(self.allocator, outer_flags, capture, opening);
    }

    fn namedCapturePrefix(self: *const Parser) ?usize {
        if (self.position + 1 < self.pattern.len and self.pattern[self.position] == 'P' and
            self.pattern[self.position + 1] == '<') return self.position + 2;
        if (self.position < self.pattern.len and self.pattern[self.position] == '<' and
            !(self.position + 1 < self.pattern.len and
                (self.pattern[self.position + 1] == '=' or self.pattern[self.position + 1] == '!')))
            return self.position + 1;
        return null;
    }

    /// Allocates the next one-based capture index and optional copied name before
    /// opening its reducer frame; named groups remain captures under never-capture.
    fn newCapture(
        self: *Parser,
        name: ?regexp_module.ByteSpan,
        opening: usize,
    ) error{ParseFailed}!Reduction.Capture {
        if (self.syntax.capture_count == self.options.max_captures) {
            return self.fail(.resource_limit, opening, self.position);
        }
        self.syntax.capture_count += 1;
        return .{ .index = @enumFromInt(self.syntax.capture_count), .name = name };
    }

    /// Accepts nonempty names whose every scalar belongs to the project's
    /// letter/number/mark/connector category set; digits are valid initially.
    fn validCaptureName(self: *Parser, name: []const u8) bool {
        if (name.len == 0) return false;
        var position: usize = 0;
        while (position < name.len) {
            const rune: rune_range.Rune = if (self.options.encoding == .latin1) blk: {
                const value = name[position];
                position += 1;
                break :blk value;
            } else blk: {
                const width = std.unicode.utf8ByteSequenceLength(name[position]) catch return false;
                if (position + width > name.len) return false;
                const value = std.unicode.utf8Decode(name[position .. position + width]) catch return false;
                position += width;
                break :blk value;
            };
            var accepted = false;
            for ([_][]const u8{ "Lu", "Ll", "Lt", "Lm", "Lo", "Nl", "Mn", "Mc", "Nd", "Pc" }) |group_name| {
                if (unicode.findGroup(group_name).?.contains(rune)) {
                    accepted = true;
                    break;
                }
            }
            if (!accepted) return false;
        }
        return true;
    }

    /// Parses an inline flag edit after `(?`. Returns true for `:` scoped edits
    /// and false for a completed `)` edit that opens no frame.
    fn parseFlagEdit(self: *Parser, opening: usize) (error{ParseFailed})!bool {
        var enable = true;
        var saw_flag = false;
        while (self.position < self.pattern.len) : (self.position += 1) {
            switch (self.pattern[self.position]) {
                'i' => self.flags.fold = enable,
                'm' => self.flags.one_line = !enable,
                's' => self.flags.dot_nl = enable,
                'U' => self.flags.non_greedy = enable,
                '-' => {
                    if (!enable) return self.fail(.bad_perl_operator, opening, self.position + 1);
                    enable = false;
                    continue;
                },
                ':' => {
                    if (!saw_flag) return self.fail(.bad_perl_operator, opening, self.position + 1);
                    self.position += 1;
                    return true;
                },
                ')' => {
                    if (!saw_flag) return self.fail(.bad_perl_operator, opening, self.position + 1);
                    self.position += 1;
                    return false;
                },
                else => return self.fail(
                    .bad_perl_operator,
                    opening,
                    scanner.advanceRunes(self.pattern, self.options.encoding, self.position, 1),
                ),
            }
            saw_flag = true;
        }
        return self.fail(.bad_perl_operator, opening, self.pattern.len);
    }

    /// Finalizes the current branch/group, restores its saved lexical flags, and
    /// diagnoses an unmatched closing delimiter at the outer frame.
    fn closeGroup(self: *Parser) (error{ OutOfMemory, ParseFailed })!void {
        if (self.reduction.frameCount() == 1) {
            return self.fail(.unexpected_paren, self.position, self.position + 1);
        }
        self.position += 1;
        const opening = self.reduction.currentFrame().opening;
        const closed = self.reduction.closeFrame(
            self.allocator,
            &self.syntax,
            self.options.max_nodes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NodeLimit => return self.fail(.resource_limit, self.position, self.position),
            error.FrameLimit => return self.fail(.resource_limit, opening, self.position),
        };
        self.flags = closed.frame.restore;
    }

    /// Commits the current concatenation as one branch without closing its group.
    fn finishAlternative(self: *Parser) (error{ OutOfMemory, ParseFailed })!void {
        self.reduction.finishAlternative(
            self.allocator,
            &self.syntax,
            self.options.max_nodes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NodeLimit => return self.fail(.resource_limit, self.position, self.position),
            error.FrameLimit => unreachable,
        };
    }

    // Syntax-arena publication.

    fn appendLiteral(self: *Parser, rune: rune_range.Rune, width: usize) (error{ OutOfMemory, ParseFailed })!void {
        const start = self.position;
        self.position += width;
        try self.appendLiteralConsumed(rune, start);
    }

    /// Applies newline exclusion and current fold policy, appends rune storage,
    /// and lets the reducer coalesce compatible adjacent literal nodes.
    fn appendLiteralConsumed(self: *Parser, rune: rune_range.Rune, start: usize) (error{ OutOfMemory, ParseFailed })!void {
        if (self.options.never_nl and rune == '\n') {
            try self.appendNode(.no_match, start, self.position);
            return;
        }
        if (self.reduction.hasCurrentPiece()) {
            const last_id = self.reduction.lastPiece();
            const last_node = &self.syntax.nodes.items[@intFromEnum(last_id)];
            if (last_node.* == .literal and last_node.literal.fold == self.flags.fold) {
                const span = &last_node.literal.runes;
                if (@as(usize, span.start) + span.len == self.syntax.runes.items.len) {
                    try self.syntax.runes.append(self.allocator, rune);
                    span.len += 1;
                    return;
                }
            }
        }

        const span = self.syntax.addRunes(self.allocator, &.{rune}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ProgramTooLarge => return self.fail(.resource_limit, start, self.position),
        };
        try self.appendNode(.{ .literal = .{ .runes = span, .fold = self.flags.fold } }, start, self.position);
    }

    fn appendNode(
        self: *Parser,
        value: regexp_module.Node,
        start: usize,
        end: usize,
    ) (error{ OutOfMemory, ParseFailed })!void {
        const id = try self.newNode(value, start, end);
        try self.reduction.appendPiece(self.allocator, id);
    }

    /// Routes every parser node through the shared reducer admission check and
    /// attaches the current source span to any resource-limit diagnostic.
    fn newNode(
        self: *Parser,
        value: regexp_module.Node,
        start: usize,
        end: usize,
    ) (error{ OutOfMemory, ParseFailed })!regexp_module.NodeId {
        return self.reduction.newNode(
            self.allocator,
            &self.syntax,
            self.options.max_nodes,
            value,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NodeLimit => self.fail(.resource_limit, start, end),
        };
    }

    // Repetition operators.

    /// Normalizes `*`, `+`, and `?` to counted bounds before the common postfix
    /// validator handles greediness and nested-repeat restrictions.
    fn applySimpleRepeat(self: *Parser, operator: u8) (error{ OutOfMemory, ParseFailed })!void {
        const start = self.position;
        self.position += 1;
        const bounds: struct { u32, ?u32 } = switch (operator) {
            '*' => .{ 0, null },
            '+' => .{ 1, null },
            '?' => .{ 0, 1 },
            else => unreachable,
        };
        try self.applyRepeat(bounds[0], bounds[1], start, self.position);
        if (self.position == start + 1) self.position = start + 1;
    }

    /// Validates postfix placement/nesting and delegates normalized bounds plus
    /// greediness to the reducer.
    fn applyRepeat(
        self: *Parser,
        min: u32,
        max: ?u32,
        start: usize,
        end: usize,
    ) (error{ OutOfMemory, ParseFailed })!void {
        if (!self.reduction.hasCurrentPiece()) {
            return self.fail(.repeat_argument, start, end);
        }
        var greedy = !self.flags.non_greedy;
        self.position = end;
        if (self.flags.perl_x and self.position < self.pattern.len and self.pattern[self.position] == '?') {
            greedy = !greedy;
            self.position += 1;
        }
        const candidate = self.reduction.lastPiece();
        if (self.flags.perl_x and self.syntax.node(candidate).* == .repeat)
            return self.fail(.repeat_operator, self.position - 1, self.position);
        self.reduction.applyRepeat(
            self.allocator,
            &self.syntax,
            self.options.max_nodes,
            min,
            max,
            greedy,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NodeLimit => return self.fail(.resource_limit, self.position, self.position),
        };
    }

    /// Speculatively parses `{n}`, `{n,}`, or `{n,m}`. Incomplete non-forms return
    /// null without consuming Parser position; complete invalid forms diagnose.
    fn parseCountedRepeat(self: *Parser) (error{ParseFailed})!?CountedRepeat {
        const start = self.position;
        var cursor = start + 1;
        const min = scanner.parseDecimal(self.pattern, &cursor) orelse return null;
        var max: ?u32 = min;
        if (cursor < self.pattern.len and self.pattern[cursor] == ',') {
            cursor += 1;
            max = scanner.parseDecimal(self.pattern, &cursor);
        }
        if (cursor >= self.pattern.len or self.pattern[cursor] != '}') return null;
        cursor += 1;
        if (min > self.options.max_repeat or (max != null and max.? > self.options.max_repeat) or
            (max != null and max.? < min))
        {
            return self.fail(.repeat_size, start, cursor);
        }
        return .{ .min = min, .max = max, .end = cursor };
    }

    // Escapes and character classes.

    /// Dispatches non-class Perl assertions, quoted spans, byte consumers, and
    /// named classes before falling back to one scanner-decoded escaped rune.
    /// Bracket expressions use `parseClassAtom` instead, keeping class-term
    /// negation and union in the class builder.
    fn parseEscape(self: *Parser) (error{ OutOfMemory, ParseFailed })!void {
        const start = self.position;
        self.position += 1;
        if (self.position == self.pattern.len) return self.fail(.trailing_backslash, start, self.position);
        const byte = self.pattern[self.position];
        switch (byte) {
            'A' => {
                if (!self.flags.perl_x) return self.fail(.bad_escape, start, self.position + 1);
                try self.appendNode(.begin_text, start, self.position + 1);
                self.position += 1;
                return;
            },
            'z' => {
                if (!self.flags.perl_x) return self.fail(.bad_escape, start, self.position + 1);
                try self.appendNode(.end_text, start, self.position + 1);
                self.position += 1;
                return;
            },
            'b', 'B' => {
                if (!self.flags.word_boundary) return self.fail(.bad_escape, start, self.position + 1);
                try self.appendNode(if (byte == 'b') .word_boundary else .not_word_boundary, start, self.position + 1);
                self.position += 1;
                return;
            },
            'C' => {
                if (!self.flags.perl_x) return self.fail(.bad_escape, start, self.position + 1);
                try self.appendNode(.any_byte, start, self.position + 1);
                self.position += 1;
                return;
            },
            'Q' => {
                if (!self.flags.perl_x) return self.fail(.bad_escape, start, self.position + 1);
                self.position += 1;
                while (self.position < self.pattern.len) {
                    if (self.position + 1 < self.pattern.len and self.pattern[self.position] == '\\' and
                        self.pattern[self.position + 1] == 'E')
                    {
                        self.position += 2;
                        break;
                    }
                    const decoded = try self.decodeRune(self.position);
                    try self.appendLiteral(decoded.rune, decoded.width);
                }
                return;
            },
            'd', 'D', 's', 'S', 'w', 'W' => {
                if (!self.flags.perl_classes) return self.fail(.bad_escape, start, self.position + 1);
                self.position += 1;
                try self.appendPerlClass(byte, start);
                return;
            },
            'p', 'P' => {
                if (!self.flags.unicode_groups) return self.fail(.bad_escape, start, self.position + 1);
                try self.appendUnicodeClass(byte == 'P', start);
                return;
            },
            else => {},
        }

        const rune = try self.decodeEscapedRune(start);
        try self.appendLiteralConsumed(rune, start);
    }

    fn appendPerlClass(self: *Parser, code: u8, start: usize) (error{ OutOfMemory, ParseFailed })!void {
        var builder: char_class.Builder = .{};
        defer builder.deinit(self.allocator);
        try self.addPerlClassToBuilder(&builder, code);
        try self.appendClassBuilder(&builder, start);
    }

    fn addPerlClassToBuilder(
        self: *Parser,
        builder: *char_class.Builder,
        code: u8,
    ) error{OutOfMemory}!void {
        var term: char_class.Builder = .{};
        defer term.deinit(self.allocator);
        try class_terms.addPerl(self.allocator, &term, code, self.flags.fold);
        try self.mergeClassTerm(builder, &term, std.ascii.isUpper(code));
    }

    /// Borrowed exact group-name spelling plus effective class-term negation.
    const UnicodeGroupSpec = struct { name: []const u8, negated: bool };

    /// Parses braced or one-letter exact group names and folds `^` into the
    /// caller's initial negation without performing alias normalization.
    fn parseUnicodeGroupSpec(
        self: *Parser,
        initial_negated: bool,
        start: usize,
    ) error{ParseFailed}!UnicodeGroupSpec {
        self.position += 1; // p or P
        var negated = initial_negated;
        var name: []const u8 = undefined;
        if (self.position < self.pattern.len and self.pattern[self.position] == '{') {
            self.position += 1;
            const name_start = self.position;
            while (self.position < self.pattern.len and self.pattern[self.position] != '}') : (self.position += 1) {}
            if (self.position == self.pattern.len) return self.fail(.bad_char_range, start, self.position);
            name = self.pattern[name_start..self.position];
            self.position += 1;
        } else {
            if (self.position == self.pattern.len)
                return self.fail(.bad_char_range, start, self.position);
            const decoded = try self.decodeRune(self.position);
            name = self.pattern[self.position .. self.position + decoded.width];
            self.position += decoded.width;
        }
        if (name.len > 0 and name[0] == '^') {
            negated = !negated;
            name = name[1..];
        }
        return .{ .name = name, .negated = negated };
    }

    fn appendUnicodeClass(self: *Parser, initial_negated: bool, start: usize) (error{ OutOfMemory, ParseFailed })!void {
        const spec = try self.parseUnicodeGroupSpec(initial_negated, start);
        var builder: char_class.Builder = .{};
        defer builder.deinit(self.allocator);
        try self.addUnicodeGroupToBuilder(&builder, spec.name, spec.negated, start);
        try self.appendClassBuilder(&builder, start);
    }

    /// Resolves one exact Unicode group into a temporary normalized term, maps an
    /// unknown name to its source diagnostic, then applies term-local negation.
    fn addUnicodeGroupToBuilder(
        self: *Parser,
        builder: *char_class.Builder,
        name: []const u8,
        negated: bool,
        start: usize,
    ) (error{ OutOfMemory, ParseFailed })!void {
        var term: char_class.Builder = .{};
        defer term.deinit(self.allocator);
        class_terms.addUnicode(
            self.allocator,
            &term,
            name,
            self.flags.fold,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownClass => return self.fail(.bad_char_range, start, self.position),
        };
        try self.mergeClassTerm(builder, &term, negated);
    }

    /// Parses one bracket expression into a normalized Class Builder, respecting
    /// first-position `]`, edge `-`, per-term classes, negation, folding, newline
    /// exclusion, and encoding clipping.
    fn parseClass(self: *Parser) (error{ OutOfMemory, ParseFailed })!void {
        const start = self.position;
        self.position += 1;
        var negated = false;
        if (self.position < self.pattern.len and self.pattern[self.position] == '^') {
            negated = true;
            self.position += 1;
        }
        var builder: char_class.Builder = .{};
        defer builder.deinit(self.allocator);
        var first = true;

        while (self.position < self.pattern.len) {
            if (self.pattern[self.position] == ']' and !first) {
                self.position += 1;
                if (negated) try self.negateClass(&builder);
                if (self.options.never_nl) try self.removeNewline(&builder);
                return self.appendClassBuilder(&builder, start);
            }
            if (!self.flags.perl_x and !first and self.pattern[self.position] == '-' and
                self.position + 1 < self.pattern.len and self.pattern[self.position + 1] != ']')
                return self.fail(.bad_char_range, start, self.position + 1);

            const atom = try self.parseClassAtom(&builder, start);
            first = false;
            const lo = atom orelse continue;
            if (self.position < self.pattern.len and self.pattern[self.position] == '-' and
                self.position + 1 < self.pattern.len and self.pattern[self.position + 1] != ']')
            {
                self.position += 1;
                const hi = try self.parseClassRune(start);
                if (hi < lo) return self.fail(.bad_char_range, start, self.position);
                try self.addClassRange(&builder, .{ .lo = lo, .hi = hi }, true);
            } else {
                try self.addClassRange(&builder, .{ .lo = lo, .hi = lo }, true);
            }
        }
        return self.fail(.missing_bracket, start, self.pattern.len);
    }

    /// Parses one bracket-expression term as a literal rune or a completed
    /// Perl/Unicode/POSIX class contribution.
    fn parseClassAtom(
        self: *Parser,
        builder: *char_class.Builder,
        class_start: usize,
    ) (error{ OutOfMemory, ParseFailed })!?rune_range.Rune {
        if (self.position + 1 < self.pattern.len and self.pattern[self.position] == '[' and
            self.pattern[self.position + 1] == ':')
        {
            const term_start = self.position;
            var end = self.position + 2;
            while (end + 1 < self.pattern.len and
                !(self.pattern[end] == ':' and self.pattern[end + 1] == ']')) : (end += 1)
            {}
            if (end + 1 >= self.pattern.len) return try self.parseClassRune(class_start);
            var name = self.pattern[self.position + 2 .. end];
            var negated = false;
            if (name.len > 0 and name[0] == '^') {
                negated = true;
                name = name[1..];
            }
            self.position = end + 2;
            try self.addPosixClassToBuilder(builder, name, negated, term_start);
            return null;
        }
        if (self.position + 1 < self.pattern.len and self.pattern[self.position] == '\\') {
            const code = self.pattern[self.position + 1];
            switch (code) {
                'd', 'D', 's', 'S', 'w', 'W' => {
                    if (!self.flags.perl_classes) return self.fail(.bad_escape, self.position, self.position + 2);
                    self.position += 2;
                    try self.addPerlClassToBuilder(builder, code);
                    return null;
                },
                'p', 'P' => {
                    if (!self.flags.unicode_groups) return self.fail(.bad_escape, self.position, self.position + 2);
                    const start = self.position;
                    self.position += 1;
                    const spec = try self.parseUnicodeGroupSpec(code == 'P', start);
                    try self.addUnicodeGroupToBuilder(builder, spec.name, spec.negated, start);
                    return null;
                },
                else => {},
            }
        }
        return try self.parseClassRune(class_start);
    }

    /// Resolves one POSIX name into a temporary term so negation/newline policy
    /// can be applied before union with the enclosing bracket expression.
    fn addPosixClassToBuilder(
        self: *Parser,
        builder: *char_class.Builder,
        name: []const u8,
        negated: bool,
        start: usize,
    ) (error{ OutOfMemory, ParseFailed })!void {
        var term: char_class.Builder = .{};
        defer term.deinit(self.allocator);
        class_terms.addPosix(
            self.allocator,
            &term,
            name,
            self.flags.fold,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownClass => return self.fail(.bad_char_range, start, self.position),
        };
        try self.mergeClassTerm(builder, &term, negated);
    }

    /// Unions a completed term builder into the enclosing class builder without
    /// losing normalization or ownership on allocation failure.
    fn mergeClassTerm(
        self: *Parser,
        builder: *char_class.Builder,
        term: *char_class.Builder,
        negated: bool,
    ) error{OutOfMemory}!void {
        if (negated) try self.negateClass(term);
        if (self.options.never_nl) try self.removeNewline(term);
        term.normalize() catch unreachable;
        for (term.ranges.items) |range| try self.addClassRange(builder, range, false);
    }

    /// Consumes one literal or escaped rune inside brackets, preserving the
    /// opening bracket as context for an unterminated-class diagnostic.
    fn parseClassRune(self: *Parser, class_start: usize) (error{ OutOfMemory, ParseFailed })!rune_range.Rune {
        if (self.position == self.pattern.len) return self.fail(.missing_bracket, class_start, self.position);
        if (self.pattern[self.position] == '\\') {
            const slash = self.position;
            self.position += 1;
            if (self.position == self.pattern.len) return self.fail(.trailing_backslash, slash, self.position);
            return self.decodeEscapedRune(slash);
        }
        const decoded = try self.decodeRune(self.position);
        self.position += decoded.width;
        return decoded.rune;
    }

    /// Adds one interval through fold closure only when both the caller and
    /// active flags request it; builder invariant failures are impossible here.
    fn addClassRange(
        self: *Parser,
        builder: *char_class.Builder,
        range: rune_range.Range,
        fold: bool,
    ) error{OutOfMemory}!void {
        if (fold and self.flags.fold) {
            builder.addFoldedRange(self.allocator, range) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidRuneRange => unreachable,
            };
        } else {
            builder.addRange(self.allocator, range) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidRuneRange => unreachable,
            };
        }
    }

    fn negateClass(self: *Parser, builder: *char_class.Builder) error{OutOfMemory}!void {
        builder.negate(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRuneRange, error.InvalidInput => unreachable,
        };
    }

    fn removeNewline(self: *Parser, builder: *char_class.Builder) error{OutOfMemory}!void {
        builder.removeRange(self.allocator, .{ .lo = '\n', .hi = '\n' }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRuneRange, error.InvalidInput => unreachable,
        };
    }

    /// Finalizes normalized class storage, clips to the selected encoding, and
    /// publishes either no-match or one class node into the reducer.
    fn appendClassBuilder(self: *Parser, builder: *char_class.Builder, start: usize) (error{ OutOfMemory, ParseFailed })!void {
        if (self.options.encoding == .latin1) {
            builder.removeRange(self.allocator, .{ .lo = 0x100, .hi = rune_range.max_rune }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidRuneRange, error.InvalidInput => unreachable,
            };
        }
        var class = builder.finish(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidRuneRange => return self.fail(.bad_char_range, start, self.position),
        };
        defer class.deinit(self.allocator);
        const span = self.syntax.addRanges(self.allocator, class.ranges) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ProgramTooLarge => return self.fail(.resource_limit, start, self.position),
        };
        try self.appendNode(.{ .char_class = span }, start, self.position);
    }

    // Rune decoding and diagnostics.

    /// Delegates escape decoding to the scanner, commits its next cursor only on
    /// success, and translates scanner failures to stable parser diagnostics.
    fn decodeEscapedRune(self: *Parser, start: usize) error{ParseFailed}!rune_range.Rune {
        return switch (scanner.decodeEscape(
            self.pattern,
            self.options.encoding,
            start,
            self.position,
        )) {
            .success => |decoded| value: {
                self.position = decoded.next;
                break :value decoded.rune;
            },
            .failure => |failure| self.fail(
                switch (failure.code) {
                    .bad_escape => .bad_escape,
                    .bad_utf8 => .bad_utf8,
                },
                failure.start,
                failure.end,
            ),
        };
    }

    fn decodeRune(self: *Parser, position: usize) error{ParseFailed}!scanner.Decoded {
        return switch (scanner.decodeRune(self.pattern, self.options.encoding, position)) {
            .success => |decoded| decoded,
            .failure => |failure| self.fail(.bad_utf8, failure.start, failure.end),
        };
    }

    /// Stores the first terminal diagnostic and returns the private control-flow
    /// error used to unwind parser helpers.
    fn fail(self: *Parser, code: ErrorCode, start: usize, end: usize) error{ParseFailed} {
        self.diagnostic = .{ .code = code, .start = start, .end = end };
        return error.ParseFailed;
    }
};

// Public construction boundary.

/// Validates source-size and canonical UTF-8 constraints before beginning one
/// parser transaction. Syntax ownership transfers out only after complete frame
/// reduction; grammatical failures return the Parser's first stored diagnostic
/// while allocation failure remains an error.
pub fn parse(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    options: Options,
) error{OutOfMemory}!Result {
    if (pattern.len > options.max_pattern_bytes or pattern.len > std.math.maxInt(u32)) {
        return .{ .diagnostic = .{ .code = .resource_limit, .start = 0, .end = pattern.len } };
    }
    if (options.encoding == .utf8) {
        if (scanner.invalidUtf8Offset(pattern)) |offset| return .{ .diagnostic = .{
            .code = .bad_utf8,
            .start = offset,
            .end = offset + 1,
        } };
    }
    var parser = Parser{
        .allocator = allocator,
        .pattern = pattern,
        .options = options,
        .flags = initialFlags(options),
    };
    defer parser.deinit();
    parser.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return .{ .diagnostic = parser.diagnostic.? },
    };
    const syntax = parser.syntax;
    parser.syntax = .{};
    return .{ .success = syntax };
}

/// Maps syntax mode and public options to the outer lexical flag state. Perl
/// starts with text anchors; POSIX starts with line anchors unless overridden.
fn initialFlags(options: Options) Flags {
    const like_perl = options.semantics == .perl;
    return .{
        .fold = !options.case_sensitive,
        .one_line = like_perl or options.one_line,
        .dot_nl = options.dot_nl,
        .non_greedy = false,
        .perl_x = like_perl,
        .perl_classes = like_perl or options.perl_classes,
        .word_boundary = like_perl or options.word_boundary,
        .unicode_groups = like_perl,
    };
}

fn testOptions() Options {
    return .{
        .max_pattern_bytes = 1 << 20,
        .max_nodes = 100_000,
        .max_captures = 1000,
    };
}

fn expectSuccess(pattern: []const u8, options: Options) !regexp_module.Regexp {
    const result = try parse(std.testing.allocator, pattern, options);
    return switch (result) {
        .success => |syntax| syntax,
        .diagnostic => |diagnostic| {
            std.debug.print("unexpected parse diagnostic: {any}\n", .{diagnostic});
            return error.UnexpectedDiagnostic;
        },
    };
}

// Module-local qualification tests.

const testing = std.testing;

test "Empty construction avoids bare concatenation identities" {
    var syntax = try expectSuccess("", testOptions());
    defer syntax.deinit(testing.allocator);
    try testing.expect(syntax.node(syntax.root.?).* == .empty);
}

test "Precedence creates n-ary concatenation inside alternation" {
    var syntax = try expectSuccess("ab|cd", testOptions());
    defer syntax.deinit(testing.allocator);
    const root = syntax.node(syntax.root.?).*;
    try testing.expect(root == .alternate);
    const branches = syntax.nodeChildren(root.alternate);
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expect(syntax.node(branches[0]).* == .literal);
    try testing.expect(syntax.node(branches[1]).* == .literal);
}

test "Groups are iterative and captures are numbered" {
    var syntax = try expectSuccess("((a)|b)", testOptions());
    defer syntax.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), syntax.capture_count);
    try testing.expect(syntax.node(syntax.root.?).* == .capture);
}

test "Named captures accept the engine Unicode name categories" {
    var syntax = try expectSuccess("(?P<name>a)(?<中文>b)", testOptions());
    defer syntax.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), syntax.capture_count);
    const root = syntax.node(syntax.root.?).concat;
    const children = syntax.nodeChildren(root);
    const first = syntax.node(children[0]).capture;
    const second = syntax.node(children[1]).capture;
    try testing.expectEqualStrings("name", syntax.captureName(first.name.?));
    try testing.expectEqualStrings("中文", syntax.captureName(second.name.?));

    const invalid = try parse(testing.allocator, "(?<->a)", testOptions());
    try testing.expectEqual(ErrorCode.bad_named_capture, invalid.diagnostic.code);
    const lookbehind = try parse(testing.allocator, "(?<=a)", testOptions());
    try testing.expectEqual(ErrorCode.bad_perl_operator, lookbehind.diagnostic.code);
}

test "Greedy lazy and counted repetitions" {
    var syntax = try expectSuccess("a+?b{2,3}", testOptions());
    defer syntax.deinit(testing.allocator);
    const root = syntax.node(syntax.root.?).*;
    try testing.expect(root == .concat);
    const children = syntax.nodeChildren(root.concat);
    const first = syntax.node(children[0]).repeat;
    const second = syntax.node(children[1]).repeat;
    try testing.expect(!first.greedy);
    try testing.expectEqual(@as(u32, 1), first.min);
    try testing.expectEqual(@as(?u32, null), first.max);
    try testing.expectEqual(@as(u32, 2), second.min);
    try testing.expectEqual(@as(?u32, 3), second.max);
}

test "Compatible adjacent repeats coalesce without crossing priority or captures" {
    for ([_]struct { pattern: []const u8, min: u32, max: ?u32, greedy: bool }{
        .{ .pattern = "a*a*", .min = 0, .max = null, .greedy = true },
        .{ .pattern = "a+a+", .min = 2, .max = null, .greedy = true },
        .{ .pattern = "a?a?", .min = 0, .max = 2, .greedy = true },
        .{ .pattern = "a*?a*?", .min = 0, .max = null, .greedy = false },
        .{ .pattern = "[a-c]{2}[a-c]{3,4}", .min = 5, .max = 6, .greedy = true },
    }) |case| {
        var syntax = try expectSuccess(case.pattern, testOptions());
        defer syntax.deinit(testing.allocator);
        const repeat = syntax.node(syntax.root.?).repeat;
        try testing.expectEqual(case.min, repeat.min);
        try testing.expectEqual(case.max, repeat.max);
        try testing.expectEqual(case.greedy, repeat.greedy);
    }

    for ([_][]const u8{ "a*?a*", "(a*)a*", "(?:a*)a*" }) |pattern| {
        var syntax = try expectSuccess(pattern, testOptions());
        defer syntax.deinit(testing.allocator);
        try testing.expect(syntax.node(syntax.root.?).* == .concat);
    }
}

test "Postfix repeat preserves a non-capturing group atom" {
    var syntax = switch (try parse(testing.allocator, "(?:ab)*", testOptions())) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer syntax.deinit(testing.allocator);
    const repeat = syntax.node(syntax.root.?).repeat;
    try testing.expectEqual(@as(u32, 0), repeat.min);
    const group = syntax.node(repeat.child).concat;
    const literal = syntax.node(syntax.nodeChildren(group)[0]).literal;
    try testing.expectEqualSlices(rune_range.Rune, &.{ 'a', 'b' }, syntax.literalRunes(literal.runes));
}

test "Postfix repeat splits the final Rune from a coalesced literal" {
    var syntax = try expectSuccess("ab?c{2}", testOptions());
    defer syntax.deinit(testing.allocator);
    const children = syntax.nodeChildren(syntax.node(syntax.root.?).concat);
    try testing.expectEqualSlices(rune_range.Rune, &.{'a'}, syntax.literalRunes(syntax.node(children[0]).literal.runes));
    try testing.expectEqualSlices(rune_range.Rune, &.{'b'}, syntax.literalRunes(syntax.node(syntax.node(children[1]).repeat.child).literal.runes));
    try testing.expectEqualSlices(rune_range.Rune, &.{'c'}, syntax.literalRunes(syntax.node(syntax.node(children[2]).repeat.child).literal.runes));
}

test "Inline flags are scoped by groups" {
    var syntax = try expectSuccess("(?i:a)b", testOptions());
    defer syntax.deinit(testing.allocator);
    const root = syntax.node(syntax.root.?).*;
    const children = syntax.nodeChildren(root.concat);
    const scoped = syntax.nodeChildren(syntax.node(children[0]).concat);
    try testing.expect(syntax.node(scoped[0]).literal.fold);
    try testing.expect(!syntax.node(children[1]).literal.fold);
}

test "POSIX mode rejects Perl operators and escapes with engine categories" {
    var options = testOptions();
    options.semantics = .posix;
    for ([_][]const u8{ "(?:a)", "(?i:a)", "(?P<x>a)" }) |pattern| {
        const result = try parse(testing.allocator, pattern, options);
        try testing.expectEqual(ErrorCode.repeat_argument, result.diagnostic.code);
    }
    for ([_][]const u8{ "\\A", "\\z", "\\C" }) |pattern| {
        const result = try parse(testing.allocator, pattern, options);
        try testing.expectEqual(ErrorCode.bad_escape, result.diagnostic.code);
    }
}

test "Inline flags reject a repeated disabling separator" {
    for ([_][]const u8{ "(?--i:a)", "(?i--m:a)", "(?-i-m:a)" }) |pattern| {
        const result = try parse(testing.allocator, pattern, testOptions());
        try testing.expectEqual(ErrorCode.bad_perl_operator, result.diagnostic.code);
    }
}

test "POSIX classes use exact ASCII definitions and fold before negation" {
    var syntax = try expectSuccess("(?i)[[:lower:]]", testOptions());
    defer syntax.deinit(testing.allocator);
    const ranges = syntax.classRanges(syntax.node(syntax.root.?).char_class);
    try testing.expect(rune_range.contains(ranges, 'A'));
    try testing.expect(rune_range.contains(ranges, 'z'));
    try testing.expect(rune_range.contains(ranges, 0x17f));
    try testing.expect(rune_range.contains(ranges, 0x212a));

    var negated = try expectSuccess("[[:^digit:]]", testOptions());
    defer negated.deinit(testing.allocator);
    const inverse = negated.classRanges(negated.node(negated.root.?).char_class);
    try testing.expect(!rune_range.contains(inverse, '5'));
    try testing.expect(rune_range.contains(inverse, 'A'));

    var alpha = try expectSuccess("[[:alpha:]]", testOptions());
    defer alpha.deinit(testing.allocator);
    const letters = alpha.classRanges(alpha.node(alpha.root.?).char_class);
    try testing.expect(rune_range.contains(letters, 'A'));
    try testing.expect(rune_range.contains(letters, 'z'));

    var incomplete = try expectSuccess("[[:]]", testOptions());
    defer incomplete.deinit(testing.allocator);
    try testing.expect(incomplete.node(incomplete.root.?).* == .concat);
}

test "UTF-8 patterns reject encoded surrogate literals" {
    const result = try parse(testing.allocator, "\xed\xa0\x80", testOptions());
    try testing.expectEqual(ErrorCode.bad_utf8, result.diagnostic.code);
    try testing.expectEqual(@as(usize, 0), result.diagnostic.start);
}

test "Descending disjoint class terms normalize into one ordered range" {
    var syntax = try expectSuccess("[W-ZP-XE-R]", testOptions());
    defer syntax.deinit(testing.allocator);
    const ranges = syntax.classRanges(syntax.node(syntax.root.?).char_class);
    try testing.expectEqualSlices(
        rune_range.Range,
        &.{.{ .lo = 'E', .hi = 'Z' }},
        ranges,
    );
}

test "Perl and Unicode class terms union without negating prior terms" {
    var syntax = try expectSuccess("[A\\d]", testOptions());
    defer syntax.deinit(testing.allocator);
    const ranges = syntax.classRanges(syntax.node(syntax.root.?).char_class);
    try testing.expect(rune_range.contains(ranges, 'A'));
    try testing.expect(rune_range.contains(ranges, '5'));

    var word = try expectSuccess("\\w", testOptions());
    defer word.deinit(testing.allocator);
    const word_ranges = word.classRanges(word.node(word.root.?).char_class);
    try testing.expect(rune_range.contains(word_ranges, 'A'));
    try testing.expect(rune_range.contains(word_ranges, 'z'));
    try testing.expect(!rune_range.contains(ranges, 'z'));

    var full = try expectSuccess("[5\\D]", testOptions());
    defer full.deinit(testing.allocator);
    const full_ranges = full.classRanges(full.node(full.root.?).char_class);
    try testing.expect(rune_range.contains(full_ranges, '5'));
    try testing.expect(rune_range.contains(full_ranges, 'A'));
}

test "Unicode source groups retain category metadata before scalar lowering" {
    var syntax = try expectSuccess("\\p{Cs}", testOptions());
    defer syntax.deinit(testing.allocator);
    const node = syntax.node(syntax.root.?).*;
    try testing.expect(node == .char_class);
    try testing.expect(rune_range.contains(syntax.classRanges(node.char_class), 0xd800));
}

test "Hex octal and escaped Unicode literals follow scalar rules" {
    var syntax = try expectSuccess("\\x41\\141", testOptions());
    defer syntax.deinit(testing.allocator);
    const literal = syntax.node(syntax.root.?).literal;
    try testing.expectEqualSlices(rune_range.Rune, &.{ 'A', 'a' }, syntax.literalRunes(literal.runes));

    const surrogate_escape = try parse(testing.allocator, "\\x{d800}", testOptions());
    try testing.expectEqual(ErrorCode.bad_escape, surrogate_escape.diagnostic.code);

    const escaped_unicode = try parse(testing.allocator, "\\☺", testOptions());
    try testing.expectEqual(ErrorCode.bad_escape, escaped_unicode.diagnostic.code);
    try testing.expectEqualStrings("\\☺", "\\☺"[escaped_unicode.diagnostic.start..escaped_unicode.diagnostic.end]);

    const backreference = try parse(testing.allocator, "\\1", testOptions());
    try testing.expectEqual(ErrorCode.bad_escape, backreference.diagnostic.code);
    const class_backspace = try parse(testing.allocator, "[\\b]", testOptions());
    try testing.expectEqual(ErrorCode.bad_escape, class_backspace.diagnostic.code);
}

test "NeverNL excludes literals and Latin-1 clips class universe" {
    var never_options = testOptions();
    never_options.never_nl = true;
    var no_match = try expectSuccess("\\n", never_options);
    defer no_match.deinit(testing.allocator);
    try testing.expect(no_match.node(no_match.root.?).* == .no_match);

    var latin_options = testOptions();
    latin_options.encoding = .latin1;
    var latin = try expectSuccess("\\P{Latin}", latin_options);
    defer latin.deinit(testing.allocator);
    const ranges = latin.classRanges(latin.node(latin.root.?).char_class);
    try testing.expect(rune_range.contains(ranges, 0x00));
    try testing.expect(!rune_range.contains(ranges, 0x100));
}

test "Truncated braced hex follows engine invalid UTF-8 category" {
    const result = try parse(testing.allocator, "\\x{", testOptions());
    try testing.expectEqual(ErrorCode.bad_utf8, result.diagnostic.code);
    try testing.expectEqual(@as(usize, 0), result.diagnostic.start);
    try testing.expectEqual(@as(usize, 3), result.diagnostic.end);
}

test "Truncated Unicode class escape is diagnosed without decoding past input" {
    for ([_][]const u8{ "\\p", "\\P" }) |pattern| {
        const result = try parse(testing.allocator, pattern, testOptions());
        try testing.expectEqual(ErrorCode.bad_char_range, result.diagnostic.code);
        try testing.expectEqual(@as(usize, 0), result.diagnostic.start);
        try testing.expectEqual(pattern.len, result.diagnostic.end);
    }
}

test "Invalid UTF-8 and repeat errors have byte spans" {
    const invalid = try parse(testing.allocator, "\xff", testOptions());
    try testing.expectEqual(ErrorCode.bad_utf8, invalid.diagnostic.code);
    try testing.expectEqual(@as(usize, 0), invalid.diagnostic.start);

    const repeat = try parse(testing.allocator, "*", testOptions());
    try testing.expectEqual(ErrorCode.repeat_argument, repeat.diagnostic.code);
    try testing.expectEqual(@as(usize, 0), repeat.diagnostic.start);
    try testing.expectEqual(@as(usize, 1), repeat.diagnostic.end);
}

test "Deep grouping does not recurse on process stack" {
    const depth = 10_000;
    var pattern = try testing.allocator.alloc(u8, depth * 2 + 1);
    defer testing.allocator.free(pattern);
    @memset(pattern[0..depth], '(');
    pattern[depth] = 'a';
    @memset(pattern[depth + 1 ..], ')');

    var options = testOptions();
    options.max_captures = depth;
    options.max_nodes = depth + 10;
    var syntax = try expectSuccess(pattern, options);
    defer syntax.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, depth), syntax.capture_count);
}
