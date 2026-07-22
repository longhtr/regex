//! Transactional compilation and stable state shared by Matchers.
//!
//! The initial pipeline is:
//!
//! ```text
//! pattern bytes -> parser Regexp -> optional simplification -> Program
//!               -> capture-name table -> stable State publication
//! ```
//!
//! `BuildState` is the transaction ledger. Optional fields own each intermediate
//! until `finish` moves it into State and clears the corresponding field. One
//! deferred `deinit` can therefore roll back every failure path without a set of
//! fragile ownership booleans. `buildAnalyzed` lets Filtered inspect the already
//! parsed tree as the final fallible step, guaranteeing that analysis and Regex
//! publication commit together.
//!
//! State separates immutable initial data from synchronized lazy data. It owns:
//!
//! - the forward immutable Program and match semantics;
//! - a retained syntax recipe until reverse compilation is first required;
//! - an optional reverse Program for DFA start recovery;
//! - an optional immutable OnePass capture plan;
//! - forward, reverse, and full-match DFA caches;
//! - copied capture-name bytes and index metadata.
//!
//! The State allocation itself is stable because Matchers keep its pointer.
//! Remaining compile memory is divided deterministically between reverse and
//! OnePass construction, while DFA caches use a distinct role-partitioned
//! allowance. Lazy publication uses the cache lock and never changes semantics:
//! inability to build an artifact causes the caller to use another exact path.
//!
//! All accounting is in allocator-requested bytes. Teardown reverses ownership:
//! caches, OnePass, reverse Program/recipe, forward Program, names, then State.

const std = @import("std");
const match_types = @import("match.zig");
const budget_allocator = @import("support/budget_allocator.zig");
const shared_dfa = @import("engine/accelerate/shared_dfa.zig");
const one_pass = @import("engine/accelerate/one_pass.zig");
const compiler = @import("program/compiler.zig");
const parser = @import("syntax/parser.zig");
const regexp = @import("syntax/regexp.zig");
const simplify = @import("optimize/optimize.zig");
const program = @import("program/program.zig");

const simplification_node_threshold: usize = 32;

pub const MemoryBudget = budget_allocator.Budget;
pub const OptionalMemoryBudget = budget_allocator.OptionalBudget;
pub const Encoding = parser.Encoding;
pub const Semantics = parser.Semantics;
pub const DiagnosticCode = parser.ErrorCode;
pub const Diagnostic = parser.Diagnostic;

/// Engine-defined semantics and hard compile/retained-cache policies.
/// Defaults are finite; unlimited behavior must be selected explicitly.
pub const CompileOptions = struct {
    encoding: parser.Encoding = .utf8,
    semantics: parser.Semantics = .perl,
    match_kind: match_types.MatchKind = .first,
    case_sensitive: bool = true,
    dot_matches_newline: bool = false,
    exclude_newline: bool = false,
    text_anchors: bool = false,
    literal: bool = false,
    capture_groups: bool = true,
    perl_classes: bool = false,
    word_boundary: bool = false,
    max_pattern_bytes: usize = 1 << 20,
    max_nodes: u32 = 100_000,
    max_captures: u32 = 1000,
    max_repeat: u32 = 1000,
    max_instructions: u32 = 100_000,
    /// Shared upper bound for three lazily allocated role caches. The 64 MiB
    /// default gives each deterministic partition enough room for large literal
    /// dictionaries while allocating only the states actually observed.
    dfa_memory: OptionalMemoryBudget = .{ .bytes = 64 * 1024 * 1024 },
    compile_memory: MemoryBudget = .{ .bytes = 64 * 1024 * 1024 },
};

/// Immutable, representation-stable resource snapshot of initial compilation.
pub const CompileMetrics = struct {
    pattern_bytes: usize,
    program_requested_bytes: usize,
    requested_retained_bytes: usize,
    requested_peak_bytes: usize,
    allocation_count: usize,
};

/// One completed lazy program-compilation transaction.
pub const ReverseProgramMetrics = struct {
    program_requested_bytes: usize,
    requested_retained_bytes: usize,
    requested_peak_bytes: usize,
    allocation_count: usize,
};

/// Nonblocking snapshot of lazily compiled shared programs.
pub const OnePassPlanMetrics = struct {
    requested_retained_bytes: usize,
    requested_peak_bytes: usize,
    allocation_count: usize,
    state_count: usize,
};

/// Nonblocking snapshot of lazily published reverse and OnePass artifacts.
pub const LazyMetrics = struct {
    reverse_program: ?ReverseProgramMetrics,
    one_pass_plan: ?OnePassPlanMetrics,
};

/// Stable name-table entry. Bytes live in `State.capture_name_bytes`; sorting by
/// capture index makes indexed metadata deterministic while name lookup retains
/// leftmost declaration order.
const CaptureName = struct {
    start: u32,
    len: u32,
    index: u32,
};

/// Peak/allocation counters retained after a temporary lazy budget allocator is
/// gone. Live bytes are recovered from the published artifact itself.
const LazyCompileAccounting = struct {
    requested_peak_bytes: usize,
    allocation_count: usize,
};

/// Before first reverse use, owns the forward syntax recipe; afterward, keeps
/// only accounting because the recipe has been replaced by `reverse_program`.
pub const ReverseState = union(enum) {
    recipe: regexp.Regexp,
    compiled: LazyCompileAccounting,
};

/// State mutated lazily under `caches` synchronization and shared by all
/// Matchers borrowing the parent State.
pub const SharedState = struct {
    reverse_state: ReverseState,
    reverse_program: ?program.Program = null,
    one_pass_plan: ?one_pass.Plan = null,
    one_pass_accounting: ?LazyCompileAccounting = null,
    one_pass_attempted: bool = false,
    caches: shared_dfa.Caches,
};

/// Stable owning allocation behind the public Regex handle.
///
/// Fields above `shared` are immutable after publication. Methods that publish a
/// lazy artifact synchronize through `shared.caches`; callers must keep this
/// object alive until every Matcher has been destroyed.
pub const State = struct {
    allocator: std.mem.Allocator,
    program: program.Program,
    encoding: parser.Encoding,
    max_instructions: u32,
    reverse_compile_memory: MemoryBudget,
    one_pass_compile_memory: MemoryBudget,
    match_kind: match_types.MatchKind,
    compile_metrics: CompileMetrics,
    capture_name_bytes: std.ArrayList(u8),
    capture_names: []CaptureName,
    shared: SharedState,

    /// Compiles the retained syntax recipe in reverse direction exactly once.
    /// The caller holds the exclusive shared-cache lock. Compiler-limit failures
    /// are unreachable because the same syntax was admitted forward.
    pub fn ensureReverse(self: *State) error{OutOfMemory}!*program.Program {
        if (self.shared.reverse_program == null) {
            var budget = budget_allocator.BudgetAllocator.init(
                self.allocator,
                self.reverse_compile_memory,
            );
            const compiled = compiler.compile(budget.allocator(), &self.shared.reverse_state.recipe, .{
                .encoding = switch (self.encoding) {
                    .utf8 => .utf8,
                    .latin1 => .latin1,
                },
                .max_instructions = self.max_instructions,
                .reverse = true,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InstructionLimit, error.InvalidSyntax => unreachable,
            };
            self.shared.reverse_program = compiled;
            std.debug.assert(compiled.requestedBytes() == budget.live);
            self.shared.reverse_state.recipe.deinit(self.allocator);
            self.shared.reverse_state = .{ .compiled = .{
                .requested_peak_bytes = budget.peak,
                .allocation_count = budget.allocation_count,
            } };
        }
        return &self.shared.reverse_program.?;
    }

    /// Nonblocking lazy publication of an immutable shared OnePass Plan. It
    /// declines on lock contention, prior failure, trivial/oversized capture
    /// shape, ineligibility, or optional budget failure; every case leaves exact
    /// matcher-local capture engines available.
    pub fn tryEnsureOnePass(self: *State) ?*const one_pass.Plan {
        if (!self.shared.caches.tryLock()) return null;
        defer self.shared.caches.unlock();
        if (self.shared.one_pass_plan) |*plan| return plan;
        if (self.shared.one_pass_attempted or self.program.capture_slots <= 2 or
            self.program.capture_slots > one_pass.capture_slot_limit or
            self.program.all_captures_whole)
            return null;
        self.shared.one_pass_attempted = true;
        var budget = budget_allocator.BudgetAllocator.init(
            self.allocator,
            self.one_pass_compile_memory,
        );
        self.shared.one_pass_plan = one_pass.Plan.initWithBackingAllocator(
            budget.allocator(),
            self.allocator,
            &self.program,
        ) catch return null;
        std.debug.assert(self.shared.one_pass_plan.?.requestedBytes() == budget.live);
        self.shared.one_pass_accounting = .{
            .requested_peak_bytes = budget.peak,
            .allocation_count = budget.allocation_count,
        };
        return &self.shared.one_pass_plan.?;
    }

    /// Destroys lazy shared artifacts before immutable initial state, then frees
    /// the stable allocation itself.
    pub fn destroy(self: *State) void {
        const allocator = self.allocator;
        self.shared.caches.deinit(allocator);
        if (self.shared.one_pass_plan) |*plan| plan.deinit();
        if (self.shared.reverse_program) |*reverse| reverse.deinit(allocator);
        switch (self.shared.reverse_state) {
            .recipe => |*recipe| recipe.deinit(allocator),
            .compiled => {},
        }
        self.program.deinit(allocator);
        if (self.capture_names.len != 0) allocator.free(self.capture_names);
        self.capture_name_bytes.deinit(allocator);
        allocator.destroy(self);
    }

    /// Takes a nonblocking lock and snapshots lazy owners; null means the state
    /// was busy, not that no artifact exists.
    pub fn tryLazyMetrics(self: *State) ?LazyMetrics {
        if (!self.shared.caches.tryLock()) return null;
        defer self.shared.caches.unlock();
        const reverse_program: ?ReverseProgramMetrics = if (self.shared.reverse_program) |*program_value| blk: {
            const accounting = self.shared.reverse_state.compiled;
            const retained = program_value.requestedBytes();
            break :blk .{
                .program_requested_bytes = retained,
                .requested_retained_bytes = retained,
                .requested_peak_bytes = accounting.requested_peak_bytes,
                .allocation_count = accounting.allocation_count,
            };
        } else null;
        const one_pass_plan: ?OnePassPlanMetrics = if (self.shared.one_pass_plan) |*plan| blk: {
            const accounting = self.shared.one_pass_accounting.?;
            break :blk .{
                .requested_retained_bytes = plan.requestedBytes(),
                .requested_peak_bytes = accounting.requested_peak_bytes,
                .allocation_count = accounting.allocation_count,
                .state_count = plan.stateCount(),
            };
        } else null;
        return .{ .reverse_program = reverse_program, .one_pass_plan = one_pass_plan };
    }

    /// Linear name lookup returns the first declaration carrying equal bytes.
    /// Named captures are normally few, avoiding a retained hash table.
    pub fn captureIndex(self: *const State, name: []const u8) ?u32 {
        for (self.capture_names) |entry| {
            const start: usize = entry.start;
            if (std.mem.eql(u8, name, self.capture_name_bytes.items[start .. start + entry.len]))
                return entry.index;
        }
        return null;
    }

    pub fn captureName(self: *const State, index: u32) ?[]const u8 {
        for (self.capture_names) |entry| {
            if (entry.index == index) {
                const start: usize = entry.start;
                return self.capture_name_bytes.items[start .. start + entry.len];
            }
        }
        return null;
    }
};

// Transactional parsing, compilation, analysis, and publication.

pub const BuildResult = union(enum) {
    success: *State,
    diagnostic: Diagnostic,
};

const NoAnalysis = struct {
    fn analyze(_: *NoAnalysis, _: *const regexp.Regexp, _: parser.Encoding) error{OutOfMemory}!void {}
};

/// Compile transaction ledger. Every non-null field is owned here until
/// `finish` transfers it into a fully initialized State.
const BuildState = struct {
    allocator: std.mem.Allocator,
    tree: ?regexp.Regexp = null,
    program: ?program.Program = null,
    capture_names: ?[]CaptureName = null,

    fn deinit(self: *BuildState) void {
        if (self.capture_names) |names| if (names.len != 0) self.allocator.free(names);
        if (self.program) |*compiled| compiled.deinit(self.allocator);
        if (self.tree) |*tree| tree.deinit(self.allocator);
        self.* = undefined;
    }

    /// Infallibly publishes all retained values after the final analysis step.
    /// Clearing each optional field prevents deferred rollback from freeing moved
    /// ownership.
    fn finish(
        self: *BuildState,
        state: *State,
        backing_allocator: std.mem.Allocator,
        options: CompileOptions,
        pattern_bytes: usize,
    ) void {
        var tree = self.tree.?;
        const compiled = self.program.?;
        const names = self.capture_names.?;
        const name_bytes = tree.names;
        tree.names = .empty;

        state.* = .{
            .allocator = backing_allocator,
            .program = compiled,
            .encoding = options.encoding,
            .max_instructions = options.max_instructions,
            .reverse_compile_memory = .{ .bytes = 0 },
            .one_pass_compile_memory = .{ .bytes = 0 },
            .match_kind = options.match_kind,
            .compile_metrics = .{
                .pattern_bytes = pattern_bytes,
                .program_requested_bytes = compiled.requestedBytes(),
                .requested_retained_bytes = 0,
                .requested_peak_bytes = 0,
                .allocation_count = 0,
            },
            .capture_name_bytes = name_bytes,
            .capture_names = names,
            .shared = .{
                .reverse_state = .{ .recipe = tree },
                .caches = shared_dfa.Caches.init(options.dfa_memory),
            },
        };
        self.tree = null;
        self.program = null;
        self.capture_names = null;
    }
};

/// Builds one stable State under the exact compile budget.
pub fn build(
    backing_allocator: std.mem.Allocator,
    pattern: []const u8,
    options: CompileOptions,
) error{OutOfMemory}!BuildResult {
    var no_analysis: NoAnalysis = .{};
    return buildAnalyzed(backing_allocator, pattern, options, &no_analysis);
}

/// Internal construction hook for collection analysis of the already parsed
/// tree. Analysis is the final fallible transaction step, so success publishes
/// both the completed State and the analysis result exactly once.
pub fn buildAnalyzed(
    backing_allocator: std.mem.Allocator,
    pattern: []const u8,
    options: CompileOptions,
    analysis: anytype,
) error{OutOfMemory}!BuildResult {
    var budget = budget_allocator.BudgetAllocator.init(backing_allocator, options.compile_memory);
    const result = buildBudgeted(
        backing_allocator,
        budget.allocator(),
        pattern,
        options,
        analysis,
    ) catch |err| {
        if (budget.exhausted) return .{ .diagnostic = .{
            .code = .resource_limit,
            .start = 0,
            .end = pattern.len,
        } };
        return err;
    };
    if (result == .success) {
        result.success.compile_metrics.requested_retained_bytes = budget.live;
        result.success.compile_metrics.requested_peak_bytes = budget.peak;
        result.success.compile_metrics.allocation_count = budget.allocation_count;
        switch (options.compile_memory) {
            .unlimited => {
                result.success.reverse_compile_memory = .unlimited;
                result.success.one_pass_compile_memory = .unlimited;
            },
            .bytes => |total| {
                const remaining = total -| budget.live;
                result.success.reverse_compile_memory = .{
                    .bytes = remaining / 2 + remaining % 2,
                };
                result.success.one_pass_compile_memory = .{
                    .bytes = remaining / 2,
                };
            },
        }
    }
    return result;
}

/// Performs the complete transaction through a limiting allocator while storing
/// the backing allocator in the eventual State. Resource-shaped compiler errors
/// become source-wide diagnostics; allocator failure remains an error.
fn buildBudgeted(
    backing_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    pattern: []const u8,
    options: CompileOptions,
    analysis: anytype,
) error{OutOfMemory}!BuildResult {
    var build_state = BuildState{ .allocator = allocator };
    defer build_state.deinit();

    const parsed = try parser.parse(allocator, pattern, .{
        .encoding = options.encoding,
        .semantics = options.semantics,
        .case_sensitive = options.case_sensitive,
        .dot_nl = options.dot_matches_newline,
        .never_nl = options.exclude_newline,
        .one_line = options.text_anchors,
        .literal = options.literal,
        .never_capture = !options.capture_groups,
        .perl_classes = options.perl_classes,
        .word_boundary = options.word_boundary,
        .max_pattern_bytes = options.max_pattern_bytes,
        .max_nodes = options.max_nodes,
        .max_captures = options.max_captures,
        .max_repeat = options.max_repeat,
    });
    build_state.tree = switch (parsed) {
        .success => |value| value,
        .diagnostic => |diagnostic| return .{ .diagnostic = diagnostic },
    };

    // Large captureless syntax benefits from canonicalization and literal-prefix
    // factoring. Small expressions avoid a second AST pass; captured expressions
    // retain their original indices and priority layout.
    if (build_state.tree.?.capture_count == 0 and
        build_state.tree.?.nodes.items.len >= simplification_node_threshold)
    {
        const reduced = simplify.simplify(
            allocator,
            &build_state.tree.?,
            options.max_nodes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ProgramTooLarge => return .{ .diagnostic = .{
                .code = .resource_limit,
                .start = 0,
                .end = pattern.len,
            } },
            error.InvalidSyntax => unreachable,
        };
        build_state.tree.?.deinit(allocator);
        build_state.tree = reduced;
    }

    build_state.program = compiler.compile(allocator, &build_state.tree.?, .{
        .encoding = switch (options.encoding) {
            .utf8 => .utf8,
            .latin1 => .latin1,
        },
        .max_instructions = options.max_instructions,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InstructionLimit, error.InvalidSyntax => return .{ .diagnostic = .{
            .code = .resource_limit,
            .start = 0,
            .end = pattern.len,
        } },
    };

    var named_count: usize = 0;
    for (build_state.tree.?.nodes.items) |node| {
        if (node == .capture and node.capture.name != null) named_count += 1;
    }
    build_state.capture_names = if (named_count == 0)
        &.{}
    else
        try allocator.alloc(CaptureName, named_count);
    const capture_names = build_state.capture_names.?;
    var named_index: usize = 0;
    for (build_state.tree.?.nodes.items) |node| {
        if (node == .capture) {
            if (node.capture.name) |name| {
                capture_names[named_index] = .{
                    .start = name.start,
                    .len = name.len,
                    .index = @intFromEnum(node.capture.index),
                };
                named_index += 1;
            }
        }
    }
    std.mem.sort(CaptureName, capture_names, {}, struct {
        fn lessThan(_: void, left: CaptureName, right: CaptureName) bool {
            return left.index < right.index;
        }
    }.lessThan);

    // Allocate all retained state before analysis. Once analysis succeeds, no
    // fallible work remains between it and publication.
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    try analysis.analyze(&build_state.tree.?, options.encoding);
    build_state.finish(state, backing_allocator, options, pattern.len);
    return .{ .success = state };
}
