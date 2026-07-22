//! Comptime expansion and execution of handwritten public contracts.
//!
//! Conversion functions map the independent case vocabulary to public options,
//! compile interfaces, and operations. Every row becomes a separate Zig test so
//! one failure does not hide later cases. Failure output includes pattern, input,
//! operation, and readable expected/actual observation.
//!
//! A validation test rejects empty/duplicate names, malformed expectation shapes,
//! incompatible operation/expected tags, and structural duplicate rows. Expected
//! answers remain the reviewed constants in `test_cases.zig`, never values first
//! obtained from the production engine.

const std = @import("std");
const api = @import("../root.zig");
const test_cases = @import("test_cases.zig");
const testing = std.testing;

fn span(value: test_cases.Span) api.Match {
    return .{ .start = value.start, .end = value.end };
}

fn expectedCompatible(operation: test_cases.Operation, expected: test_cases.Expected) bool {
    return switch (operation) {
        .compile => expected == .compile_ok or expected == .compile_error,
        .exists => expected == .exists or expected == .no_match,
        .find, .captures, .full_match, .full_captures => expected == .match or expected == .no_match,
    };
}

fn validSpan(value: test_cases.Span, limit: usize) bool {
    return value.start <= value.end and value.end <= limit;
}

fn sameSpecification(left: test_cases.TestCases, right: test_cases.TestCases) bool {
    var left_specification = left;
    var right_specification = right;
    left_specification.name = "";
    right_specification.name = "";
    return std.meta.eql(left_specification, right_specification);
}

fn validTestName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return false;
    for (name, 0..) |byte, index| {
        if (byte < ' ' or byte > '~' or byte == '"' or byte == '\\' or
            (index != 0 and std.ascii.isUpper(byte))) return false;
    }
    return true;
}

/// Audits the authored table itself: unique readable names/specifications, valid
/// spans, and operation/expectation compatibility. It also proves every mirrored
/// diagnostic and option/operation dimension remains represented before comptime
/// generation can turn the rows into executable tests.
fn validateTestCases() !void {
    const PublicDiagnostic = @TypeOf(@as(api.Diagnostic, undefined).code);
    if (std.meta.fields(test_cases.Diagnostic).len != std.meta.fields(PublicDiagnostic).len)
        return error.DiagnosticContractDrift;
    inline for (std.meta.fields(test_cases.Diagnostic)) |field|
        if (std.meta.stringToEnum(PublicDiagnostic, field.name) == null)
            return error.DiagnosticContractDrift;

    var operations = std.EnumSet(test_cases.Operation).initEmpty();
    var has_latin1 = false;
    var has_longest = false;
    var has_posix = false;
    var has_start_anchor = false;
    var has_range = false;
    var has_case_fold = false;
    var has_dot_newline = false;
    var has_exclude_newline = false;
    var has_text_anchors = false;
    var has_literal = false;
    var has_capture_suppression = false;
    var has_perl_classes = false;
    var has_word_boundary = false;
    var has_compile_memory = false;
    for (test_cases.test_cases, 0..) |test_case, index| {
        if (!validTestName(test_case.name) or
            !expectedCompatible(test_case.operation, test_case.expected))
            return error.InvalidTestCase;
        for (test_cases.test_cases[0..index], 0..) |previous, previous_index| {
            if (std.mem.eql(u8, previous.name, test_case.name))
                return error.DuplicateTestCaseName;
            if (sameSpecification(previous, test_case)) {
                std.debug.print(
                    "duplicate test cases at indices {d} and {d}\n",
                    .{ previous_index, index },
                );
                return error.DuplicateTestCase;
            }
        }
        operations.insert(test_case.operation);
        const option = test_case.options;
        has_latin1 = has_latin1 or option.encoding == .latin1;
        has_longest = has_longest or option.match_kind == .longest;
        has_posix = has_posix or option.semantics == .posix;
        has_start_anchor = has_start_anchor or test_case.anchor == .start;
        has_range = has_range or test_case.range != null;
        has_case_fold = has_case_fold or !option.case_sensitive;
        has_dot_newline = has_dot_newline or option.dot_matches_newline;
        has_exclude_newline = has_exclude_newline or option.exclude_newline;
        has_text_anchors = has_text_anchors or option.text_anchors;
        has_literal = has_literal or option.literal;
        has_capture_suppression = has_capture_suppression or !option.capture_groups;
        has_perl_classes = has_perl_classes or option.perl_classes;
        has_word_boundary = has_word_boundary or option.word_boundary;
        has_compile_memory = has_compile_memory or option.compile_memory != null;

        const requested = test_case.range orelse test_cases.Span{
            .start = 0,
            .end = test_case.input.len,
        };
        if (!validSpan(requested, test_case.input.len))
            return error.InvalidTestCaseRange;

        switch (test_case.expected) {
            .compile_ok, .compile_error, .no_match, .exists => {},
            .match => |expected| {
                if (!validSpan(expected.whole, test_case.input.len) or
                    expected.whole.start < requested.start or
                    expected.whole.end > requested.end)
                    return error.InvalidExpectedMatch;
                const capture_operation = test_case.operation == .captures or
                    test_case.operation == .full_captures;
                if ((capture_operation and expected.captures.len != test_case.capture_count) or
                    (!capture_operation and expected.captures.len != 0))
                    return error.InvalidExpectedCaptures;
                for (expected.captures) |capture| if (capture) |value| {
                    if (!validSpan(value, test_case.input.len) or
                        value.start < expected.whole.start or
                        value.end > expected.whole.end)
                        return error.InvalidExpectedCapture;
                };
                if ((test_case.operation == .full_match or
                    test_case.operation == .full_captures) and
                    !std.meta.eql(expected.whole, requested))
                    return error.InvalidExpectedFullMatch;
            },
        }
    }
    if (operations.count() != std.meta.fields(test_cases.Operation).len)
        return error.MissingTestCaseOperation;
    if (!has_latin1 or !has_longest or !has_posix or !has_start_anchor or
        !has_range or !has_case_fold or !has_dot_newline or
        !has_exclude_newline or !has_text_anchors or !has_literal or
        !has_capture_suppression or !has_perl_classes or !has_word_boundary or
        !has_compile_memory)
        return error.MissingTestCaseDimension;
}

/// Converts the deliberately independent case vocabulary to public options in
/// one visible place, preventing the data table from importing implementation
/// types or silently inheriting defaults.
fn options(test_case: test_cases.TestCases) api.CompileOptions {
    const value = test_case.options;
    return .{
        .encoding = switch (value.encoding) {
            .utf8 => .utf8,
            .latin1 => .latin1,
        },
        .semantics = switch (value.semantics) {
            .perl => .perl,
            .posix => .posix,
        },
        .match_kind = switch (value.match_kind) {
            .first => .first,
            .longest => .longest,
        },
        .case_sensitive = value.case_sensitive,
        .dot_matches_newline = value.dot_matches_newline,
        .exclude_newline = value.exclude_newline,
        .text_anchors = value.text_anchors,
        .literal = value.literal,
        .capture_groups = value.capture_groups,
        .perl_classes = value.perl_classes,
        .word_boundary = value.word_boundary,
        .compile_memory = if (value.compile_memory) |bytes|
            .{ .bytes = bytes }
        else
            .{ .bytes = 64 * 1024 * 1024 },
    };
}

fn fail(
    test_case: test_cases.TestCases,
    comptime message: []const u8,
    arguments: anytype,
) error{TestUnexpectedResult} {
    std.debug.print(
        "name={s} operation={s} pattern={any} input={any}: " ++ message ++ "\n",
        .{ test_case.name, @tagName(test_case.operation), test_case.pattern, test_case.input } ++ arguments,
    );
    return error.TestUnexpectedResult;
}

/// Checks explicit groups while the borrowed view is still valid, distinguishing
/// an unmatched group from a participating empty range.
fn checkCaptures(
    test_case: test_cases.TestCases,
    view: api.CaptureView,
    expected: test_cases.MatchExpected,
) !void {
    for (expected.captures, 1..) |wanted, group| {
        const actual = view.group(group);
        if (wanted) |value| {
            const wanted_span = span(value);
            if (actual == null or !std.meta.eql(wanted_span, actual.?))
                return fail(test_case, "group {d} expected {any}, found {any}", .{
                    group,
                    wanted_span,
                    actual,
                });
        } else if (actual != null) {
            return fail(test_case, "group {d} expected null, found {any}", .{ group, actual });
        }
    }
}

/// Runs exactly one authored row through only public owners and operations,
/// preserving compile diagnostics as ordinary expected observations. Successful
/// compilation dispatches the selected ranged/full/capture operation and checks
/// borrowed capture groups before teardown or another call can invalidate them.
fn execute(test_case: test_cases.TestCases) !void {
    const compiled = try api.Regex.compile(
        testing.allocator,
        test_case.pattern,
        options(test_case),
    );
    switch (compiled) {
        .diagnostic => |diagnostic| switch (test_case.expected) {
            .compile_error => |code| {
                if (!std.mem.eql(u8, @tagName(code), @tagName(diagnostic.code)))
                    return fail(test_case, "expected diagnostic {s}, found {s}", .{
                        @tagName(code),
                        @tagName(diagnostic.code),
                    });
                return;
            },
            else => return fail(test_case, "unexpected diagnostic {s}", .{
                @tagName(diagnostic.code),
            }),
        },
        .success => |value| {
            var expression = value;
            defer expression.deinit();
            if (test_case.expected == .compile_error)
                return fail(test_case, "expected compilation failure", .{});
            if (expression.captureCount() != test_case.capture_count)
                return fail(test_case, "expected {d} groups, found {d}", .{
                    test_case.capture_count,
                    expression.captureCount(),
                });
            if (test_case.operation == .compile) return;

            var matcher = try api.Matcher.init(testing.allocator, &expression);
            defer matcher.deinit();
            const requested_value = test_case.range orelse test_cases.Span{
                .start = 0,
                .end = test_case.input.len,
            };
            const requested = api.SearchRange{
                .start = requested_value.start,
                .end = requested_value.end,
            };
            const anchor: api.Anchor = switch (test_case.anchor) {
                .unanchored => .unanchored,
                .start => .start,
            };
            var matched = false;
            var found: ?api.Match = null;
            switch (test_case.operation) {
                .compile => unreachable,
                .exists => matched = try matcher.isMatchIn(
                    test_case.input,
                    requested,
                    anchor,
                ),
                .find => {
                    found = try matcher.findIn(test_case.input, requested, anchor);
                    matched = found != null;
                },
                .captures => {
                    const captured = try matcher.capturesIn(
                        test_case.input,
                        requested,
                        anchor,
                    );
                    if (captured) |view| {
                        found = view.group(0);
                        matched = found != null;
                        if (test_case.expected == .match)
                            try checkCaptures(
                                test_case,
                                view,
                                test_case.expected.match,
                            );
                    }
                },
                .full_match => {
                    matched = try matcher.fullMatchIn(test_case.input, requested);
                    if (matched) found = .{
                        .start = requested_value.start,
                        .end = requested_value.end,
                    };
                },
                .full_captures => {
                    const captured = try matcher.fullCapturesIn(
                        test_case.input,
                        requested,
                    );
                    if (captured) |view| {
                        found = view.group(0);
                        matched = found != null;
                        if (test_case.expected == .match)
                            try checkCaptures(
                                test_case,
                                view,
                                test_case.expected.match,
                            );
                    }
                },
            }

            const expects_match = test_case.expected == .match or
                test_case.expected == .exists;
            if (matched != expects_match)
                return fail(test_case, "match status expected {any}, found {any}", .{
                    expects_match,
                    matched,
                });
            if (test_case.expected == .match) {
                const wanted = span(test_case.expected.match.whole);
                if (found == null or !std.meta.eql(wanted, found.?))
                    return fail(test_case, "expected range {any}, found {any}", .{
                        wanted,
                        found,
                    });
            }
        },
    }
}

test "Validate handwritten public semantic test cases" {
    try validateTestCases();
}

/// Creates an independently reported Zig test declaration for each `TestCase`.
/// The `name` argument is embedded in the generated type's qualified name,
/// allowing the custom test runner to extract and display it.
fn TestCase(comptime index: usize, comptime name: []const u8) type {
    if (!std.mem.eql(u8, name, test_cases.test_cases[index].name))
        @compileError("generated test name does not match its TestCases entry");
    return struct {
        test "Execute" {
            try execute(test_cases.test_cases[index]);
        }
    };
}

comptime {
    for (test_cases.test_cases, 0..) |test_case, index| {
        _ = TestCase(index, test_case.name);
    }
}
