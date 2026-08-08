//! Combined captureless Program for many insertion-order pattern IDs.
//!
//! Builder parses each pattern with captures disabled, then transactionally
//! remaps its typed arena spans/NodeIds into one combined Regexp. A failed add
//! rolls every destination array back and consumes no ID. On compile, roots are
//! alternated in insertion order and each accepting leaf receives its dense ID.
//! `.both` collections add exact start/end anchoring; `.unanchored` uses the
//! ordinary scan loop.
//!
//! Published Set owns one Program, one optional shared many-match DFA, its hard
//! collection BudgetAllocator, and a stable heap state borrowed by Matchers.
//! Unlike Filtered, it does not retain independent Regex values.
//!
//! Matcher owns an ID-only ordered-NFA engine, a dense matched bitmap, and a
//! sparse list of IDs set during the current request. Clearing touches only the
//! sparse list. Result publication chooses between sorting sparse IDs and scanning
//! the dense bitmap according to estimated work, always returning insertion
//! order under a hard count limit.
//!
//! Known DFA transitions can be read under a shared lock; construction/ID
//! collection uses exclusive access. Contention or DFA exhaustion restarts the
//! complete ID-only NFA with a cleared result set. Boolean search can stop at the
//! first ID. Set and each Matcher have distinct finite requested-byte budgets.

const std = @import("std");
const set_module = @This();
const match_types = @import("../match.zig");
const budget_allocator = @import("../support/budget_allocator.zig");
const try_rw_lock = @import("../support/try_rw_lock.zig");
const compiled_module = @import("../compiled.zig");
const dfa = @import("../engine/accelerate/dfa.zig");
const nfa = @import("../engine/nfa.zig");
const prefix_search = @import("../literal/search.zig");
const compiler = @import("../program/compiler.zig");
const program = @import("../program/program.zig");
const parser = @import("../syntax/parser.zig");
const regexp = @import("../syntax/regexp.zig");

/// Collection-wide policy: search each pattern anywhere or require full-input
/// coverage at both text boundaries.
pub const Anchor = enum { unanchored, both };
/// Successful insertion returns its dense ID; source rejection leaves Builder
/// unchanged and returns the parser diagnostic.
pub const AddResult = union(enum) { success: u32, diagnostic: parser.Diagnostic };
pub const BuilderError = error{ OutOfMemory, CollectionMemoryLimit, BuilderFinished };
pub const CompileError = error{ OutOfMemory, CollectionMemoryLimit, CompileMemoryLimit, InstructionLimit, ProgramLimit, BuilderFinished };
pub const MatchError = error{ OutOfMemory, ResultLimitExceeded };
pub const WorkError = error{WorkLimitExceeded};
pub const CollectionMemory = budget_allocator.Budget;
pub const default_collection_memory: CollectionMemory = .{ .bytes = 256 * 1024 * 1024 };
/// Aggregate requested-byte accounting for builder/published Set ownership.
pub const CollectionMetrics = struct {
    requested_live_bytes: usize,
    requested_peak_bytes: usize,
    allocation_count: usize,
};
/// Per-Matcher complete-engine and result scratch allowance.
pub const MatcherOptions = struct {
    scratch_memory: CollectionMemory = .{ .bytes = 64 * 1024 * 1024 },
};
/// Exact matcher-local requested-byte accounting; shared Set state is excluded.
pub const MatcherMetrics = struct {
    requested_live_bytes: usize,
    requested_peak_bytes: usize,
    allocation_count: usize,
};

/// Transactional syntax-arena builder for dense insertion-order IDs. Successful
/// additions append one rebased root under a lazily installed collection budget;
/// compile temporarily joins those roots, publishes one Program, and transfers a
/// separate stable budget owner without consuming state on failure.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    options: compiled_module.CompileOptions,
    anchor: Anchor,
    collection_memory: CollectionMemory,
    tree: regexp.Regexp = .{},
    roots: std.ArrayList(regexp.NodeId) = .empty,
    budget: ?*budget_allocator.BudgetAllocator = null,
    finished: bool = false,

    /// Creates an allocation-free builder with the default collection budget.
    /// Persistent syntax storage is allocated lazily on the first successful add.
    pub fn init(
        allocator: std.mem.Allocator,
        options: compiled_module.CompileOptions,
        anchor: Anchor,
    ) Builder {
        return initWithCollectionMemory(
            allocator,
            options,
            anchor,
            default_collection_memory,
        );
    }

    /// Creates a lazy builder under an explicit hard budget covering combined
    /// syntax and the eventual published Set state.
    pub fn initWithCollectionMemory(
        allocator: std.mem.Allocator,
        options: compiled_module.CompileOptions,
        anchor: Anchor,
        collection_memory: CollectionMemory,
    ) Builder {
        return .{
            .allocator = allocator,
            .options = options,
            .anchor = anchor,
            .collection_memory = collection_memory,
        };
    }

    pub fn deinit(self: *Builder) void {
        if (self.budget) |budget| {
            const collection_allocator = budget.allocator();
            self.roots.deinit(collection_allocator);
            self.tree.deinit(collection_allocator);
            std.debug.assert(budget.live == 0);
            self.allocator.destroy(budget);
        } else {
            self.roots.deinit(self.allocator);
            self.tree.deinit(self.allocator);
        }
        self.* = undefined;
    }

    /// Adds one captureless pattern transactionally. Parsing uses suppressed
    /// captures, then `appendTree` checkpoints and rebases the temporary arena;
    /// only the final root append consumes the next dense insertion ID.
    /// Diagnostics and resource failures leave all prior roots unchanged.
    pub fn add(self: *Builder, pattern: []const u8) BuilderError!AddResult {
        if (self.finished) return error.BuilderFinished;
        const budget = try self.ensureBudget();
        const collection_allocator = budget.allocator();
        const parsed = parser.parse(collection_allocator, pattern, .{
            .encoding = self.options.encoding,
            .semantics = self.options.semantics,
            .case_sensitive = self.options.case_sensitive,
            .dot_nl = self.options.dot_matches_newline,
            .never_nl = self.options.exclude_newline,
            .one_line = self.options.text_anchors,
            .literal = self.options.literal,
            .never_capture = true,
            .perl_classes = self.options.perl_classes,
            .word_boundary = self.options.word_boundary,
            .max_pattern_bytes = self.options.max_pattern_bytes,
            .max_nodes = self.options.max_nodes,
            .max_captures = 0,
            .max_repeat = self.options.max_repeat,
        }) catch return self.resourceError();
        var parsed_tree = switch (parsed) {
            .success => |value| value,
            .diagnostic => |diagnostic| return .{ .diagnostic = diagnostic },
        };
        defer parsed_tree.deinit(collection_allocator);

        const id = std.math.cast(u32, self.roots.items.len) orelse
            return .{ .diagnostic = .{ .code = .resource_limit, .start = 0, .end = pattern.len } };
        self.roots.ensureUnusedCapacity(collection_allocator, 1) catch
            return self.resourceError();
        const root = appendTree(&self.tree, collection_allocator, &parsed_tree) catch |err| switch (err) {
            error.OutOfMemory => return self.resourceError(),
            error.ProgramLimit => return .{ .diagnostic = .{
                .code = .resource_limit,
                .start = 0,
                .end = pattern.len,
            } },
        };
        self.roots.appendAssumeCapacity(root);
        return .{ .success = id };
    }

    /// Publishes one stable Set state and consumes further builder use. A
    /// temporary alternation joins authored roots, then construction separates
    /// still-live Builder bytes from the Set's configured budget. Program and
    /// optional DFA ownership commit only after SharedState is complete; every
    /// earlier failure restores the syntax arena and releases reserved owners.
    pub fn compile(self: *Builder) CompileError!Set {
        if (self.finished) return error.BuilderFinished;
        const builder_budget = try self.ensureBudget();
        const builder_allocator = builder_budget.allocator();
        const old_root = self.tree.root;
        const old_node_len = self.tree.nodes.items.len;
        const old_child_len = self.tree.children.items.len;
        defer {
            self.tree.root = old_root;
            self.tree.nodes.shrinkRetainingCapacity(old_node_len);
            self.tree.children.shrinkRetainingCapacity(old_child_len);
        }
        if (self.roots.items.len != 0) self.tree.root = if (self.roots.items.len == 1)
            self.roots.items[0]
        else blk: {
            const children = self.tree.addChildren(builder_allocator, self.roots.items) catch |err| switch (err) {
                error.OutOfMemory => return self.resourceError(),
                error.ProgramTooLarge => return error.ProgramLimit,
            };
            break :blk self.tree.addNode(builder_allocator, .{ .alternate = children }) catch |err| switch (err) {
                error.OutOfMemory => return self.resourceError(),
                error.ProgramTooLarge => return error.ProgramLimit,
            };
        };

        const set_budget = try self.allocator.create(budget_allocator.BudgetAllocator);
        errdefer self.allocator.destroy(set_budget);
        const full_payload = budget_allocator.subtractOverhead(
            self.collection_memory,
            @sizeOf(budget_allocator.BudgetAllocator),
        ) orelse return error.CollectionMemoryLimit;
        set_budget.* = budget_allocator.BudgetAllocator.init(self.allocator, full_payload);
        const full_limit = set_budget.limit;
        if (self.collection_memory == .bytes) {
            const builder_bytes = std.math.add(
                usize,
                builder_budget.live,
                @sizeOf(budget_allocator.BudgetAllocator),
            ) catch return error.CollectionMemoryLimit;
            const available_total = if (self.collection_memory.bytes > builder_bytes)
                self.collection_memory.bytes - builder_bytes
            else
                return error.CollectionMemoryLimit;
            if (available_total < @sizeOf(budget_allocator.BudgetAllocator))
                return error.CollectionMemoryLimit;
            set_budget.limit = available_total - @sizeOf(budget_allocator.BudgetAllocator);
        }
        defer set_budget.limit = full_limit;
        if (!set_budget.reserve(@sizeOf(SharedState))) return error.CollectionMemoryLimit;
        errdefer set_budget.release(@sizeOf(SharedState));
        const state = try self.allocator.create(SharedState);
        errdefer self.allocator.destroy(state);
        const set_allocator = set_budget.allocator();

        var prog: ?program.Program = null;
        errdefer if (prog) |*value| value.deinit(set_allocator);
        if (self.roots.items.len != 0) {
            var compile_budget = budget_allocator.BudgetAllocator.init(
                set_allocator,
                self.options.compile_memory,
            );
            prog = compiler.compileSet(
                compile_budget.allocator(),
                &self.tree,
                self.roots.items,
                .{
                    .encoding = switch (self.options.encoding) {
                        .utf8 => .utf8,
                        .latin1 => .latin1,
                    },
                    .max_instructions = self.options.max_instructions,
                },
                self.anchor == .both,
            ) catch |err| switch (err) {
                error.OutOfMemory => return if (set_budget.exhausted)
                    error.CollectionMemoryLimit
                else if (compile_budget.exhausted)
                    error.CompileMemoryLimit
                else
                    error.OutOfMemory,
                error.InstructionLimit => return error.InstructionLimit,
                error.InvalidSyntax => return error.ProgramLimit,
            };
        }
        state.* = .{
            .allocator = set_allocator,
            .budget = set_budget,
            .program = prog,
            .count = @intCast(self.roots.items.len),
            .anchor = self.anchor,
            .dfa_engine = null,
        };
        prog = null;
        if (state.program != null) state.dfa_engine = switch (self.options.dfa_memory) {
            .disabled => null,
            .bytes => |bytes| dfa.Matcher.initWithBudget(
                set_allocator,
                &state.program.?,
                dfa.encoding_state_limit,
                .longest,
                .{ .bytes = bytes },
            ) catch null,
            .unlimited => dfa.Matcher.initWithBudget(
                set_allocator,
                &state.program.?,
                dfa.encoding_state_limit,
                .longest,
                .unlimited,
            ) catch null,
        };
        self.finished = true;
        return .{ .state = state };
    }

    /// Lazily creates the stable budget context so an unused builder allocates
    /// nothing. All subsequent arena additions must use its allocator handle.
    fn ensureBudget(self: *Builder) BuilderError!*budget_allocator.BudgetAllocator {
        if (self.budget) |budget| return budget;
        const budget = try self.allocator.create(budget_allocator.BudgetAllocator);
        errdefer self.allocator.destroy(budget);
        const payload = budget_allocator.subtractOverhead(
            self.collection_memory,
            @sizeOf(budget_allocator.BudgetAllocator),
        ) orelse return error.CollectionMemoryLimit;
        budget.* = budget_allocator.BudgetAllocator.init(self.allocator, payload);
        self.budget = budget;
        return budget;
    }

    /// Classifies allocation failure by whether the collection wrapper, rather
    /// than the backing allocator, denied the request.
    fn resourceError(self: *const Builder) BuilderError {
        if (self.budget) |budget| if (budget.exhausted) return error.CollectionMemoryLimit;
        return error.OutOfMemory;
    }
};

/// Stable published owner borrowed by all Set.Matchers. DFA mutation is guarded
/// by `dfa_lock`; Program and count/anchor policy are immutable.
const SharedState = struct {
    allocator: std.mem.Allocator,
    budget: *budget_allocator.BudgetAllocator,
    program: ?program.Program,
    count: u32,
    anchor: Anchor,
    dfa_engine: ?dfa.Matcher,
    dfa_lock: try_rw_lock.TryRwLock = .{},

    fn destroy(self: *SharedState) void {
        const backing_allocator = self.budget.child;
        if (self.dfa_engine) |*engine| engine.deinit();
        if (self.program) |*prog| prog.deinit(self.allocator);
        self.budget.release(@sizeOf(SharedState));
        std.debug.assert(self.budget.live == 0);
        backing_allocator.destroy(self.budget);
        backing_allocator.destroy(self);
    }
};

/// Published combined Program and optional shared DFA owner. Independent
/// Matchers borrow this state and return ascending insertion IDs, so the Set must
/// outlive all of them; `deinit` releases both the program and collection budget.
pub const Set = struct {
    pub const Builder = set_module.Builder;
    pub const Matcher = set_module.Matcher;
    pub const Ids = set_module.Ids;
    pub const Anchor = set_module.Anchor;
    pub const AddResult = set_module.AddResult;
    pub const BuilderError = set_module.BuilderError;
    pub const CompileError = set_module.CompileError;
    pub const MatchError = set_module.MatchError;
    pub const Metrics = set_module.CollectionMetrics;
    pub const MatcherOptions = set_module.MatcherOptions;

    state: *SharedState,

    /// Returns the number of insertion-order pattern IDs.
    pub fn count(self: *const Set) u32 {
        return self.state.count;
    }

    /// Exact aggregate requested bytes for the published program and shared DFA.
    pub fn collectionMetrics(self: *const Set) CollectionMetrics {
        const owner_allocations: usize = 2; // BudgetAllocator and SharedState.
        return .{
            .requested_live_bytes = self.state.budget.live +| @sizeOf(budget_allocator.BudgetAllocator),
            .requested_peak_bytes = self.state.budget.peak +| @sizeOf(budget_allocator.BudgetAllocator),
            .allocation_count = self.state.budget.allocation_count +| owner_allocations,
        };
    }

    /// Creates single-threaded reusable matching scratch for this Set.
    pub fn matcher(
        self: *const Set,
        allocator: std.mem.Allocator,
    ) error{ OutOfMemory, ScratchLimitExceeded }!set_module.Matcher {
        return self.matcherWithOptions(allocator, .{});
    }

    /// Creates Set scratch under an explicit requested-byte ceiling. One backing
    /// allocation is partitioned into dense matched flags and ordered ID storage;
    /// a complete MatchId NFA is added when the Set has a Program. Budget denial
    /// is translated to `ScratchLimitExceeded` without publishing partial state.
    pub fn matcherWithOptions(
        self: *const Set,
        allocator: std.mem.Allocator,
        options: set_module.MatcherOptions,
    ) error{ OutOfMemory, ScratchLimitExceeded }!set_module.Matcher {
        const payload = budget_allocator.subtractOverhead(
            options.scratch_memory,
            @sizeOf(budget_allocator.BudgetAllocator),
        ) orelse return error.ScratchLimitExceeded;
        const budget = try allocator.create(budget_allocator.BudgetAllocator);
        budget.* = budget_allocator.BudgetAllocator.init(allocator, payload);
        errdefer {
            std.debug.assert(budget.live == 0);
            allocator.destroy(budget);
        }
        const scratch_allocator = budget.allocator();
        const pattern_count: usize = self.state.count;
        const booleans_per_word = @sizeOf(u32) / @sizeOf(bool);
        const matched_words = pattern_count / booleans_per_word +
            @intFromBool(pattern_count % booleans_per_word != 0);
        const backing_len = std.math.add(usize, matched_words, pattern_count) catch
            return error.OutOfMemory;
        const backing = scratch_allocator.alloc(u32, backing_len) catch |err| {
            if (budget.exhausted) return error.ScratchLimitExceeded;
            return err;
        };
        errdefer if (backing.len != 0) scratch_allocator.free(backing);
        const matched = std.mem.bytesAsSlice(
            bool,
            std.mem.sliceAsBytes(backing[0..matched_words]),
        )[0..pattern_count];
        @memset(matched, false);
        const id_storage = backing[matched_words..];
        const matched_ids = std.ArrayList(u32){
            .items = id_storage[0..0],
            .capacity = id_storage.len,
        };
        const engine: ?nfa.MatchIdMatcher = if (self.state.program) |*prog|
            nfa.MatchIdMatcher.init(scratch_allocator, prog) catch |err| {
                if (budget.exhausted) return error.ScratchLimitExceeded;
                return err;
            }
        else
            null;
        return .{
            .budget = budget,
            .state = self.state,
            .engine = engine,
            .backing = backing,
            .matched = matched,
            .matched_ids = matched_ids,
        };
    }

    /// Releases the Set after all of its Matchers are destroyed.
    pub fn deinit(self: *Set) void {
        self.state.destroy();
        self.* = undefined;
    }
};

/// Private cumulative route/reset observations; never affect result selection.
const MatcherDiagnostics = struct {
    boolean_requests: usize = 0,
    known_dfa_boolean_completions: usize = 0,
    collection_requests: usize = 0,
    cleared_ids: usize = 0,
};

/// Single-threaded reusable scratch for one Set. Dense flags deduplicate IDs
/// across DFA/NFA traversal, `matched_ids` preserves ascending publication, and
/// the optional complete engine provides semantic fallback when shared DFA work
/// is unavailable.
pub const Matcher = struct {
    pub const Options = set_module.MatcherOptions;
    pub const Metrics = set_module.MatcherMetrics;
    pub const WorkLimitError = set_module.WorkError;

    budget: *budget_allocator.BudgetAllocator,
    state: *SharedState,
    engine: ?nfa.MatchIdMatcher,
    backing: []u32,
    matched: []bool,
    matched_ids: std.ArrayList(u32),
    diagnostics: MatcherDiagnostics = .{},

    pub fn deinit(self: *Matcher) void {
        if (self.engine) |*engine| engine.deinit();
        if (self.backing.len != 0) self.budget.allocator().free(self.backing);
        std.debug.assert(self.budget.live == 0);
        const allocator = self.budget.child;
        allocator.destroy(self.budget);
        self.* = undefined;
    }

    pub fn metrics(self: *const Matcher) MatcherMetrics {
        const overhead = @sizeOf(budget_allocator.BudgetAllocator);
        return .{
            .requested_live_bytes = self.budget.live +| overhead,
            .requested_peak_bytes = self.budget.peak +| overhead,
            .allocation_count = self.budget.allocation_count +| 1,
        };
    }

    /// Reports whether at least one pattern matches without materializing IDs.
    /// A proven combined prefix may reject/advance first; known shared DFA edges
    /// are preferred, exclusive construction is attempted without waiting, and
    /// contention or construction failure restarts the complete ID-only NFA.
    pub fn isMatch(self: *Matcher, input: []const u8) bool {
        self.diagnostics.boolean_requests +|= 1;
        if (self.engine == null) return false;
        const range_start = self.requiredPrefixStart(input) orelse return false;
        const anchor: match_types.Anchor = if (self.state.anchor == .unanchored) .unanchored else .start;
        if (self.state.dfa_engine != null and self.state.dfa_lock.tryLockShared()) {
            const known = self.state.dfa_engine.?.isMatchKnown(
                input,
                range_start,
                input.len,
                anchor,
            );
            self.state.dfa_lock.unlockShared();
            if (known) |found| {
                self.diagnostics.known_dfa_boolean_completions +|= 1;
                return found;
            } else |_| {}
        }
        if (self.state.dfa_engine != null and self.state.dfa_lock.tryLock()) {
            defer self.state.dfa_lock.unlock();
            if (self.state.dfa_engine.?.isMatch(
                input,
                range_start,
                input.len,
                anchor,
            )) |found| return found else |_| {}
        }
        return self.engine.?.isMatchAnyIdFrom(
            input,
            range_start,
            self.state.anchor == .unanchored,
        );
    }

    /// Admits complete ID-only fallback work before running ordinary boolean
    /// collection search.
    pub fn isMatchWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        max_work: usize,
    ) WorkError!bool {
        try self.admitWork(input.len, max_work);
        return self.isMatch(input);
    }

    /// Returns all matching insertion IDs in ascending order under a hard
    /// result-count ceiling.
    pub fn allMatches(
        self: *Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        max_results: usize,
    ) MatchError!Ids {
        if (self.engine == null) return .{ .allocator = allocator, .items = &.{} };
        _ = self.collect(input);
        if (self.matched_ids.items.len > max_results) return error.ResultLimitExceeded;
        const count = self.matched_ids.items.len;
        const items = try allocator.alloc(u32, count);
        if (scansDenseResults(count, self.matched.len)) {
            var write_index: usize = 0;
            for (self.matched, 0..) |found, id| if (found) {
                items[write_index] = @intCast(id);
                write_index += 1;
            };
            std.debug.assert(write_index == items.len);
        } else {
            @memcpy(items, self.matched_ids.items);
            std.mem.sort(u32, items, {}, std.sort.asc(u32));
        }
        return .{ .allocator = allocator, .items = items };
    }

    /// Clears prior sparse result state, attempts one exclusive many-match DFA
    /// traversal, then restarts complete ID-only NFA after any DFA error.
    fn collect(self: *Matcher, input: []const u8) bool {
        self.diagnostics.collection_requests +|= 1;
        self.clearMatched();
        const range_start = self.requiredPrefixStart(input) orelse return false;
        if (self.state.dfa_engine != null and self.state.dfa_lock.tryLock()) {
            defer self.state.dfa_lock.unlock();
            if (self.state.dfa_engine.?.collectMatchIdsFrom(
                input,
                range_start,
                self.matched,
                &self.matched_ids,
                self.state.anchor == .unanchored,
            )) |found| return found else |_| self.clearMatched();
        }
        return self.engine.?.collectMatchIdsFrom(
            input,
            range_start,
            self.matched,
            &self.matched_ids,
            self.state.anchor == .unanchored,
        ) catch unreachable;
    }

    /// Applies the combined Program's conservative prefix before either physical
    /// engine. Fully anchored Set accepts only a prefix at byte zero.
    fn requiredPrefixStart(self: *const Matcher, input: []const u8) ?usize {
        const prog = &self.state.program.?;
        if (prog.prefix.len == 0) return 0;
        const candidate = (if (prog.prefix_fold_ascii)
            prefix_search.findFoldedAscii(input, 0, input.len, prog.prefix)
        else
            prefix_search.find(input, 0, input.len, prog.prefix)) orelse return null;
        if (self.state.anchor == .both and candidate != 0) return null;
        return candidate;
    }

    /// Clears only IDs recorded in the sparse current-request list rather than
    /// scanning the full dense bitmap.
    fn clearMatched(self: *Matcher) void {
        self.diagnostics.cleared_ids +|= self.matched_ids.items.len;
        for (self.matched_ids.items) |id| self.matched[id] = false;
        self.matched_ids.clearRetainingCapacity();
    }

    /// Bounds all positions times published priority items with checked arithmetic;
    /// any overflow is a conservative rejection.
    fn admitWork(self: *const Matcher, input_bytes: usize, max_work: usize) WorkError!void {
        const item_count = if (self.state.program) |*prog|
            prog.priority_lists.items.len
        else
            0;
        const positions = std.math.add(usize, input_bytes, 1) catch
            return error.WorkLimitExceeded;
        const per_position = std.math.add(usize, item_count, 1) catch
            return error.WorkLimitExceeded;
        const required = std.math.mul(usize, positions, per_position) catch
            return error.WorkLimitExceeded;
        if (required > max_work) return error.WorkLimitExceeded;
    }
};

/// Chooses dense ascending scan when its O(patterns) work is cheaper than sorting
/// the sparse matched-ID list by an approximate O(matches log matches) cost.
fn scansDenseResults(match_count: usize, pattern_count: usize) bool {
    var levels: usize = 0;
    var width = match_count -| 1;
    while (width != 0) : (width >>= 1) levels += 1;
    return match_count *| levels > pattern_count;
}

/// Independently stored insertion-order IDs.
pub const Ids = struct {
    allocator: std.mem.Allocator,
    items: []u32,

    pub fn values(self: *const Ids) []const u32 {
        return self.items;
    }

    pub fn deinit(self: *Ids) void {
        if (self.items.len != 0) self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Destination arena checkpoint used to roll back a failed tree append.
const Lengths = struct { nodes: usize, children: usize, runes: usize, ranges: usize, names: usize };

/// Transactionally copies one syntax arena into another, rebasing every NodeId
/// and typed span. Source slices are independent, and all destination arrays
/// return to their checkpoint on failure.
fn appendTree(
    destination: *regexp.Regexp,
    allocator: std.mem.Allocator,
    source: *const regexp.Regexp,
) error{ OutOfMemory, ProgramLimit }!regexp.NodeId {
    const source_root = source.root orelse return error.ProgramLimit;
    const old = Lengths{
        .nodes = destination.nodes.items.len,
        .children = destination.children.items.len,
        .runes = destination.runes.items.len,
        .ranges = destination.ranges.items.len,
        .names = destination.names.items.len,
    };
    errdefer {
        destination.nodes.shrinkRetainingCapacity(old.nodes);
        destination.children.shrinkRetainingCapacity(old.children);
        destination.runes.shrinkRetainingCapacity(old.runes);
        destination.ranges.shrinkRetainingCapacity(old.ranges);
        destination.names.shrinkRetainingCapacity(old.names);
    }
    const node_base = std.math.cast(u32, old.nodes) orelse return error.ProgramLimit;
    const child_base = std.math.cast(u32, old.children) orelse return error.ProgramLimit;
    const rune_base = std.math.cast(u32, old.runes) orelse return error.ProgramLimit;
    const range_base = std.math.cast(u32, old.ranges) orelse return error.ProgramLimit;
    const name_base = std.math.cast(u32, old.names) orelse return error.ProgramLimit;

    try destination.runes.appendSlice(allocator, source.runes.items);
    try destination.ranges.appendSlice(allocator, source.ranges.items);
    try destination.names.appendSlice(allocator, source.names.items);
    for (source.children.items) |child| try destination.children.append(
        allocator,
        @enumFromInt(std.math.add(u32, node_base, @intFromEnum(child)) catch return error.ProgramLimit),
    );
    for (source.nodes.items) |node| try destination.nodes.append(allocator, switch (node) {
        .literal => |value| .{ .literal = .{
            .runes = .{
                .start = std.math.add(u32, rune_base, value.runes.start) catch return error.ProgramLimit,
                .len = value.runes.len,
            },
            .fold = value.fold,
        } },
        .char_class => |span| .{ .char_class = .{
            .start = std.math.add(u32, range_base, span.start) catch return error.ProgramLimit,
            .len = span.len,
        } },
        .concat => |span| .{ .concat = .{
            .start = std.math.add(u32, child_base, span.start) catch return error.ProgramLimit,
            .len = span.len,
        } },
        .alternate => |span| .{ .alternate = .{
            .start = std.math.add(u32, child_base, span.start) catch return error.ProgramLimit,
            .len = span.len,
        } },
        .repeat => |value| .{ .repeat = .{
            .child = @enumFromInt(std.math.add(u32, node_base, @intFromEnum(value.child)) catch return error.ProgramLimit),
            .min = value.min,
            .max = value.max,
            .greedy = value.greedy,
        } },
        .capture => |value| .{ .capture = .{
            .child = @enumFromInt(std.math.add(u32, node_base, @intFromEnum(value.child)) catch return error.ProgramLimit),
            .index = value.index,
            .name = if (value.name) |span| .{
                .start = std.math.add(u32, name_base, span.start) catch return error.ProgramLimit,
                .len = span.len,
            } else null,
        } },
        else => node,
    });
    return @enumFromInt(std.math.add(u32, node_base, @intFromEnum(source_root)) catch
        return error.ProgramLimit);
}

// Module-local qualification tests.

const testing = std.testing;

fn addOk(builder: *Builder, pattern: []const u8) !u32 {
    return switch (try builder.add(pattern)) {
        .success => |id| id,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

test "Set result publication selects sparse sort or dense scan by work" {
    try testing.expect(!scansDenseResults(0, 1024));
    try testing.expect(!scansDenseResults(2, 1024));
    try testing.expect(scansDenseResults(512, 1024));
    try testing.expect(scansDenseResults(1024, 1024));
}

test "Combined Set preserves unanchored insertion IDs and invalid-add transaction" {
    var builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer builder.deinit();
    try testing.expectEqual(@as(u32, 0), try addOk(&builder, "foo"));
    try testing.expect((try builder.add("(")) == .diagnostic);
    try testing.expectEqual(@as(u32, 1), try addOk(&builder, "bar"));
    var set = try builder.compile();
    defer set.deinit();
    try testing.expectEqual(@as(u32, 2), set.count());
    var matcher = try set.matcher(testing.allocator);
    defer matcher.deinit();
    try testing.expect(matcher.state.dfa_engine != null);
    var ids = try matcher.allMatches(testing.allocator, "foobar", 2);
    defer ids.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, ids.values());
    try testing.expect(matcher.isMatch("fooba"));
    var bar = try matcher.allMatches(testing.allocator, "oobar", 2);
    defer bar.deinit();
    try testing.expectEqualSlices(u32, &.{1}, bar.values());
}

test "Set shared state survives handle relocation" {
    var builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer builder.deinit();
    _ = try addOk(&builder, "foo");
    var original = try builder.compile();
    var matcher = try original.matcher(testing.allocator);
    var moved = original;
    original = undefined;
    defer {
        matcher.deinit();
        moved.deinit();
    }

    try testing.expect(matcher.isMatch("--foo--"));
}

test "Set collection budget covers builder compile and shared DFA" {
    const limit = 2 * 1024 * 1024;
    var builder = Builder.initWithCollectionMemory(
        testing.allocator,
        .{ .dfa_memory = .{ .bytes = 256 * 1024 } },
        .unanchored,
        .{ .bytes = limit },
    );
    defer builder.deinit();
    _ = try addOk(&builder, "alpha.*omega");
    _ = try addOk(&builder, "(foo|bar)+baz");
    var set = try builder.compile();
    defer set.deinit();
    const published = set.collectionMetrics();
    try testing.expect(published.requested_live_bytes <= limit);
    try testing.expect(published.requested_peak_bytes <= limit);
    var matcher = try set.matcher(testing.allocator);
    defer matcher.deinit();
    try testing.expect(matcher.isMatch("alpha---omega"));
    const after_match = set.collectionMetrics();
    try testing.expect(after_match.requested_live_bytes <= limit);
    try testing.expect(after_match.requested_peak_bytes <= limit);

    var tiny = Builder.initWithCollectionMemory(
        testing.allocator,
        .{},
        .unanchored,
        .{ .bytes = @sizeOf(budget_allocator.BudgetAllocator) - 1 },
    );
    defer tiny.deinit();
    try testing.expectError(error.CollectionMemoryLimit, tiny.add("foo"));
}

test "Set boolean search exits without collection and result reset is sparse" {
    var builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer builder.deinit();
    var pattern_buffer: [8]u8 = undefined;
    for (0..32) |id| {
        const pattern = try std.fmt.bufPrint(&pattern_buffer, "p{d:0>2}", .{id});
        _ = try addOk(&builder, pattern);
    }
    var set = try builder.compile();
    defer set.deinit();
    var matcher = try set.matcher(testing.allocator);
    defer matcher.deinit();

    var first = try matcher.allMatches(testing.allocator, "p17", 32);
    defer first.deinit();
    try testing.expectEqualSlices(u32, &.{17}, first.values());
    try testing.expectEqual(@as(usize, 1), matcher.diagnostics.collection_requests);
    try testing.expectEqual(@as(usize, 0), matcher.diagnostics.cleared_ids);

    try testing.expect(matcher.isMatch("p31"));
    try testing.expectEqual(@as(usize, 1), matcher.diagnostics.boolean_requests);
    try testing.expectEqual(@as(usize, 1), matcher.matched_ids.items.len);
    try testing.expectEqual(@as(usize, 0), matcher.diagnostics.cleared_ids);

    var none = try matcher.allMatches(testing.allocator, "absent", 32);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.items.len);
    try testing.expectEqual(@as(usize, 2), matcher.diagnostics.collection_requests);
    try testing.expectEqual(@as(usize, 1), matcher.diagnostics.cleared_ids);
}

fn allocationSetLifecycle(allocator: std.mem.Allocator) !void {
    var builder = Builder.init(allocator, .{ .compile_memory = .unlimited }, .unanchored);
    defer builder.deinit();
    _ = try addOk(&builder, "foo");
    _ = try addOk(&builder, "bar$");
    var set = try builder.compile();
    defer set.deinit();
    var matcher = try set.matcher(allocator);
    defer matcher.deinit();
    var ids = try matcher.allMatches(allocator, "foobar", 2);
    ids.deinit();
}

test "Set boolean uses known DFA transitions under concurrent readers" {
    var builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer builder.deinit();
    _ = try addOk(&builder, "foo[0-9]+");
    _ = try addOk(&builder, "bar[0-9]+");
    var set = try builder.compile();
    defer set.deinit();
    var matcher = try set.matcher(testing.allocator);
    defer matcher.deinit();

    try testing.expect(matcher.isMatch("xfoo12"));
    const before = matcher.diagnostics.known_dfa_boolean_completions;
    try testing.expect(set.state.dfa_lock.tryLockShared());
    defer set.state.dfa_lock.unlockShared();
    try testing.expect(matcher.isMatch("xfoo12"));
    try testing.expectEqual(before + 1, matcher.diagnostics.known_dfa_boolean_completions);
}

test "Independent Set matchers share cache and fall back under contention" {
    var builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer builder.deinit();
    _ = try addOk(&builder, "foo[0-9]+");
    _ = try addOk(&builder, "bar[0-9]+");
    var set = try builder.compile();
    defer set.deinit();

    const Context = struct {
        set: *const Set,
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(context: *@This()) void {
            var matcher = context.set.matcher(testing.allocator) catch {
                context.failed.store(true, .release);
                return;
            };
            defer matcher.deinit();
            for (0..500) |_| {
                var ids = matcher.allMatches(testing.allocator, "xfoo12 ybar7", 2) catch {
                    context.failed.store(true, .release);
                    return;
                };
                defer ids.deinit();
                if (!std.mem.eql(u32, ids.values(), &.{ 0, 1 })) {
                    context.failed.store(true, .release);
                    return;
                }
            }
        }
    };
    var context = Context{ .set = &set };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Context.run, .{&context});
    for (threads) |thread| thread.join();
    try testing.expect(!context.failed.load(.acquire));
}

test "Many-match DFA exhaustion restarts through the complete NFA" {
    var builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer builder.deinit();
    _ = try addOk(&builder, "(a|aa)*b");
    _ = try addOk(&builder, "a[ab]{20}c");
    var set = try builder.compile();
    defer set.deinit();
    var matcher = try set.matcher(testing.allocator);
    defer matcher.deinit();
    try testing.expect(matcher.state.dfa_engine != null);
    matcher.state.dfa_engine.?.cache.max_states = 1;
    var ids = try matcher.allMatches(testing.allocator, "xaaaaaaaaab", 2);
    defer ids.deinit();
    try testing.expectEqualSlices(u32, &.{0}, ids.values());
    try testing.expect(matcher.state.dfa_engine.?.budget.exhausted or
        matcher.state.dfa_engine.?.stateCount() == 1);
}

test "Combined Set lifecycle owns every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationSetLifecycle, .{});

    var builder = Builder.init(testing.allocator, .{ .compile_memory = .{ .bytes = 0 } }, .unanchored);
    defer builder.deinit();
    _ = try addOk(&builder, "foo");
    try testing.expectError(error.CompileMemoryLimit, builder.compile());
}

test "Set matcher scratch budget is exact and observable" {
    var builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer builder.deinit();
    _ = try addOk(&builder, "foo");
    _ = try addOk(&builder, "bar[0-9]+");
    var set = try builder.compile();
    defer set.deinit();

    try testing.expectError(
        error.ScratchLimitExceeded,
        set.matcherWithOptions(testing.allocator, .{ .scratch_memory = .{ .bytes = 0 } }),
    );
    var probe = try set.matcherWithOptions(
        testing.allocator,
        .{ .scratch_memory = .unlimited },
    );
    const required = probe.metrics().requested_peak_bytes;
    probe.deinit();
    try testing.expect(required > @sizeOf(budget_allocator.BudgetAllocator));
    try testing.expectError(
        error.ScratchLimitExceeded,
        set.matcherWithOptions(
            testing.allocator,
            .{ .scratch_memory = .{ .bytes = required - 1 } },
        ),
    );
    var exact = try set.matcherWithOptions(
        testing.allocator,
        .{ .scratch_memory = .{ .bytes = required } },
    );
    try testing.expectEqual(required, exact.metrics().requested_live_bytes);
    try testing.expectError(
        error.WorkLimitExceeded,
        exact.isMatchWithWorkLimit("foo", 0),
    );
    try testing.expect(try exact.isMatchWithWorkLimit("foo", std.math.maxInt(usize)));
    exact.deinit();
}

test "Combined Set factors shared patterns and survives relocation" {
    var builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer builder.deinit();
    _ = try addOk(&builder, "foo");
    _ = try addOk(&builder, "foobar");
    var original = try builder.compile();
    try testing.expectError(error.BuilderFinished, builder.add("bar"));
    try testing.expectError(error.BuilderFinished, builder.compile());
    var moved = original;
    original = undefined;
    defer moved.deinit();
    var matcher = try moved.matcher(testing.allocator);
    defer matcher.deinit();
    var both = try matcher.allMatches(testing.allocator, "obarfoobaroo", 2);
    defer both.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, both.values());
    try testing.expect(matcher.isMatch("fooba"));
    try testing.expect(!matcher.isMatch("oobar"));
    try testing.expectError(
        error.ResultLimitExceeded,
        matcher.allMatches(testing.allocator, "foobar", 1),
    );
}

test "Combined Set handles assertions full anchoring prefix and empty sets" {
    var anchored_builder = Builder.init(testing.allocator, .{ .perl_classes = true }, .both);
    defer anchored_builder.deinit();
    _ = try addOk(&anchored_builder, "foo");
    _ = try addOk(&anchored_builder, "/prefix/\\d*");
    var anchored = try anchored_builder.compile();
    defer anchored.deinit();
    var anchored_matcher = try anchored.matcher(testing.allocator);
    defer anchored_matcher.deinit();
    try testing.expect(!anchored_matcher.isMatch("foobar"));
    try testing.expect(anchored_matcher.isMatch("foo"));
    try testing.expect(anchored_matcher.isMatch("/prefix/42"));

    var boundary_builder = Builder.init(testing.allocator, .{ .word_boundary = true }, .unanchored);
    defer boundary_builder.deinit();
    _ = try addOk(&boundary_builder, "foo\\b");
    _ = try addOk(&boundary_builder, "foo$");
    var boundary = try boundary_builder.compile();
    defer boundary.deinit();
    var boundary_matcher = try boundary.matcher(testing.allocator);
    defer boundary_matcher.deinit();
    try testing.expect(!boundary_matcher.isMatch("foobar"));
    try testing.expect(boundary_matcher.isMatch("foo bar"));
    var both = try boundary_matcher.allMatches(testing.allocator, "foo", 2);
    defer both.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, both.values());

    var empty_builder = Builder.init(testing.allocator, .{}, .unanchored);
    defer empty_builder.deinit();
    var empty = try empty_builder.compile();
    defer empty.deinit();
    var empty_matcher = try empty.matcher(testing.allocator);
    defer empty_matcher.deinit();
    try testing.expect(!empty_matcher.isMatch("anything"));

    var empty_anchored_builder = Builder.init(testing.allocator, .{}, .both);
    defer empty_anchored_builder.deinit();
    var empty_anchored = try empty_anchored_builder.compile();
    defer empty_anchored.deinit();
    var empty_anchored_matcher = try empty_anchored.matcher(testing.allocator);
    defer empty_anchored_matcher.deinit();
    try testing.expect(!empty_anchored_matcher.isMatch(""));
}
