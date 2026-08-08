//! Owning compiled expression and representation-independent observations.
//!
//! `Regex` is a pointer-sized owner of one stable `compiled.State`. Stability is
//! important: callers may relocate the handle by assignment without invalidating
//! Matchers, while bitwise copies are still not independent owners. The Regex
//! must outlive every Matcher that refers to its State.
//!
//! Compilation has two interfaces over the same transaction:
//!
//! - `init`/`initWithOptions` map detailed diagnostics to concise stable errors;
//! - `compile` preserves the diagnostic code and exact pattern-byte span.
//!
//! Allocation failure remains an error in both interfaces. Invalid syntax and
//! configured admission limits are diagnostic values because they describe the
//! supplied pattern/policy, not allocator failure.
//!
//! Besides capture-name metadata, Regex exposes `possibleMatchRange`: a bounded
//! static analysis of the immutable Program. It computes bytewise lexical limits
//! for anchored full matches and does not run any matching engine.
//!
//! Mutable queues, capture slots, and dispatch belong to `matcher.zig`; shared
//! lazy reverse/OnePass/DFA state belongs to `compiled.State`.

const std = @import("std");
const regex_module = @This();
const match_types = @import("match.zig");
const compiled_module = @import("compiled.zig");
const possible_match = @import("engine/possible_match.zig");

pub const MatchKind = match_types.MatchKind;
pub const Match = match_types.Match;
pub const Anchor = match_types.Anchor;
pub const CaptureView = match_types.CaptureView;
pub const Captures = match_types.Captures;
pub const MemoryBudget = compiled_module.MemoryBudget;
pub const OptionalMemoryBudget = compiled_module.OptionalMemoryBudget;
pub const PossibleMatchRange = match_types.PossibleMatchRange;
pub const PossibleMatchResult = match_types.PossibleMatchResult;
pub const PossibleMatchError = error{ OutOfMemory, InvalidMaxLength };

pub const CompileOptions = compiled_module.CompileOptions;
pub const Encoding = compiled_module.Encoding;
pub const Semantics = compiled_module.Semantics;
pub const DiagnosticCode = compiled_module.DiagnosticCode;
pub const CompileError = error{ OutOfMemory, InvalidPattern, ResourceLimit };

/// Compilation either transfers one owning Regex or returns a value diagnostic.
pub const CompileResult = union(enum) {
    success: Regex,
    diagnostic: compiled_module.Diagnostic,
};

pub const CompileMetrics = compiled_module.CompileMetrics;

/// Compiled expression reusable by independent matchers.
///
/// Its allocator must be usable from every thread that can initialize shared
/// caches. The Regex must remain valid until all of its Matchers are destroyed.
pub const Regex = struct {
    pub const Options = regex_module.CompileOptions;
    pub const CompileError = regex_module.CompileError;
    pub const CompileResult = regex_module.CompileResult;
    pub const DiagnosticCode = regex_module.DiagnosticCode;
    pub const Metrics = regex_module.CompileMetrics;
    pub const PossibleRange = regex_module.PossibleMatchRange;
    pub const PossibleResult = regex_module.PossibleMatchResult;
    pub const PossibleError = regex_module.PossibleMatchError;

    state: *compiled_module.State,

    /// Concise compilation with finite defaults. Use `compile` when source-span
    /// diagnostics are required.
    pub fn init(
        allocator: std.mem.Allocator,
        pattern: []const u8,
    ) regex_module.CompileError!Regex {
        return initWithOptions(allocator, pattern, .{});
    }

    /// Concise compilation with explicit options. Diagnostics are mapped to
    /// stable errors; `compile` preserves their source spans.
    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        options: CompileOptions,
    ) regex_module.CompileError!Regex {
        return switch (try compile(allocator, pattern, options)) {
            .success => |value| value,
            .diagnostic => |diagnostic| switch (diagnostic.code) {
                .resource_limit => error.ResourceLimit,
                else => error.InvalidPattern,
            },
        };
    }

    /// Compiles with explicit semantics and budgets.
    pub fn compile(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        options: CompileOptions,
    ) error{OutOfMemory}!regex_module.CompileResult {
        return switch (try compiled_module.build(allocator, pattern, options)) {
            .success => |state| .{ .success = .{ .state = state } },
            .diagnostic => |diagnostic| .{ .diagnostic = diagnostic },
        };
    }

    /// Computes bounded bytewise lexical limits for anchored full matches.
    pub fn possibleMatchRange(
        self: *const Regex,
        allocator: std.mem.Allocator,
        max_len: usize,
    ) PossibleMatchError!PossibleMatchResult {
        return possible_match.possibleMatchRange(
            allocator,
            &self.state.program,
            max_len,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidLength => error.InvalidMaxLength,
        };
    }

    /// Returns immutable initial-compilation structure and requested-byte metrics.
    pub fn compileMetrics(self: *const Regex) CompileMetrics {
        return self.state.compile_metrics;
    }

    /// Returns the number of explicit groups, excluding whole-match group zero.
    pub fn captureCount(self: *const Regex) u32 {
        return self.state.program.capture_slots / 2 - 1;
    }

    /// Returns the index of the leftmost group carrying `name`.
    pub fn captureIndex(self: *const Regex, name: []const u8) ?u32 {
        return self.state.captureIndex(name);
    }

    /// Returns a name valid until Regex teardown; invalid or anonymous
    /// groups have no name and duplicate names remain visible by index.
    pub fn captureName(self: *const Regex, index: u32) ?[]const u8 {
        return self.state.captureName(index);
    }

    /// Looks up a named group in a CaptureView.
    pub fn namedCapture(
        self: *const Regex,
        captures: match_types.CaptureView,
        name: []const u8,
    ) ?match_types.Match {
        const index = self.captureIndex(name) orelse return null;
        return captures.group(index);
    }

    /// Releases the expression after all Matchers have been destroyed.
    pub fn deinit(self: *Regex) void {
        self.state.destroy();
        self.* = undefined;
    }
};

test "Concise compilation maps diagnostics to stable errors" {
    const testing = std.testing;
    var expression = try Regex.init(testing.allocator, "a+");
    expression.deinit();
    try testing.expectError(
        error.InvalidPattern,
        Regex.init(testing.allocator, "("),
    );
    try testing.expectError(
        error.ResourceLimit,
        Regex.initWithOptions(testing.allocator, "abc", .{ .max_pattern_bytes = 2 }),
    );
}

// The public API translates internal analysis terminology at its boundary.
test "Possible-match maximum length has a specific public error" {
    const testing = std.testing;
    const compiled = try Regex.compile(testing.allocator, "a", .{});
    var expression = switch (compiled) {
        .success => |value| value,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    defer expression.deinit();
    try testing.expectError(
        error.InvalidMaxLength,
        expression.possibleMatchRange(testing.allocator, 0),
    );
}
