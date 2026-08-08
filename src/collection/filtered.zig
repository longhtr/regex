//! Required-atom prefilter over independently compiled Regex entries.
//!
//! Builder compiles each pattern as a normal Regex while `buildAnalyzed` runs
//! required-atom analysis on the already parsed tree in the same transaction. A
//! successful add commits both Regex and formula root under one collection
//! budget; a diagnostic consumes no insertion-order ID. Compile publishes the
//! compact FilterPlan and transfers every independent Regex into stable shared
//! state.
//!
//! A Matcher prepares atom truth values in one of two ways: accept IDs from an
//! external scanner, or run the integrated Teddy scanner. Non-ASCII input is
//! normalized with encoding-aware lowercase only when the fast ASCII scan cannot
//! complete. One linear postorder formula pass computes candidate truth for all
//! Regex roots.
//!
//! Candidate methods expose that conservative superset without verification.
//! Match methods bind one reusable `BooleanVerifier` to each candidate Regex and
//! execute exact matching, returning insertion-order IDs. The verifier is sized
//! initially for the largest Program so rebinding needs no queue reallocation.
//! False atom/formula positives cost work but cannot authorize a final result.
//!
//! Collection memory covers retained Regexes, formulas, scanner, and their lazy
//! shared artifacts. Matcher scratch separately covers formula bits, normalized
//! input, and verifier queues. Work-limited first-match methods admit a bound that
//! includes formula evaluation plus complete verification of every Regex.

const std = @import("std");
const filtered_module = @This();
const budget_allocator = @import("../support/budget_allocator.zig");
const byte_encoding = @import("../program/byte_encoding.zig");
const compiled_module = @import("../compiled.zig");
const filter_plan = @import("filter_plan.zig");
const matcher_module = @import("../matcher.zig");
const regex_module = @import("../regex.zig");
const parser = @import("../syntax/parser.zig");
const regexp = @import("../syntax/regexp.zig");
const unicode_data = @import("../unicode/data.zig");

const RequirementAnalyzer = filter_plan.RequirementAnalyzer;
const FormulaId = filter_plan.FormulaId;
const FilterPlan = filter_plan.FilterPlan;
const buildFilterPlan = filter_plan.build;

/// Successful insertion returns its dense ID; source rejection commits neither
/// Regex nor required-atom formula.
pub const AddResult = union(enum) { success: u32, diagnostic: parser.Diagnostic };
pub const MatchError = error{ OutOfMemory, ScratchLimitExceeded, InvalidAtomId, ResultLimitExceeded };
pub const WorkError = error{WorkLimitExceeded};
pub const BuilderError = error{ OutOfMemory, CollectionMemoryLimit, BuilderFinished };
pub const CollectionMemory = budget_allocator.Budget;
pub const default_collection_memory: CollectionMemory = .{ .bytes = 256 * 1024 * 1024 };
/// Aggregate requested-byte accounting across retained Regexes, formulas,
/// scanner, shared caches, and owner overhead.
pub const CollectionMetrics = struct {
    requested_live_bytes: usize,
    requested_peak_bytes: usize,
    allocation_count: usize,
};

/// One insertion-order independently compiled Regex owner.
const RegexEntry = struct { regex: regex_module.Regex };

/// Transactional builder for independently compiled Regex entries and their
/// required-atom formulas. A lazily installed collection budget owns analyzer,
/// entries, and roots together; successful compile compacts them into one plan
/// and transfers that budget to immutable SharedState.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    options: compiled_module.CompileOptions,
    min_atom_len: usize,
    collection_memory: CollectionMemory,
    analyzer: RequirementAnalyzer,
    entries: std.ArrayList(RegexEntry) = .empty,
    roots: std.ArrayList(FormulaId) = .empty,
    budget: ?*budget_allocator.BudgetAllocator = null,
    analysis_passes: usize = 0,
    finished: bool = false,
    owns_build_state: bool = true,

    /// Creates an allocation-free builder with the default collection budget.
    /// Regex and formula storage begin lazily with the first successful add.
    pub fn init(
        allocator: std.mem.Allocator,
        options: compiled_module.CompileOptions,
        min_atom_len: usize,
    ) Builder {
        return initWithCollectionMemory(
            allocator,
            options,
            min_atom_len,
            default_collection_memory,
        );
    }

    /// Creates a lazy builder under a hard budget shared by retained Regexes,
    /// analysis formulas, the scanner, and eventual shared state.
    pub fn initWithCollectionMemory(
        allocator: std.mem.Allocator,
        options: compiled_module.CompileOptions,
        min_atom_len: usize,
        collection_memory: CollectionMemory,
    ) Builder {
        return .{
            .allocator = allocator,
            .options = options,
            .min_atom_len = min_atom_len,
            .collection_memory = collection_memory,
            .analyzer = .{ .allocator = allocator },
        };
    }

    fn collectionMetrics(self: *const Builder) CollectionMetrics {
        const budget = self.budget orelse return .{
            .requested_live_bytes = 0,
            .requested_peak_bytes = 0,
            .allocation_count = 0,
        };
        return budgetMetrics(budget, .builder);
    }

    pub fn deinit(self: *Builder) void {
        if (!self.owns_build_state) {
            self.* = undefined;
            return;
        }
        if (self.budget) |budget| {
            const collection_allocator = budget.allocator();
            for (self.entries.items) |*entry| entry.regex.deinit();
            self.roots.deinit(collection_allocator);
            self.entries.deinit(collection_allocator);
            self.analyzer.deinit();
            std.debug.assert(budget.live == 0);
            self.allocator.destroy(budget);
        } else {
            self.roots.deinit(self.allocator);
            self.entries.deinit(self.allocator);
            self.analyzer.deinit();
        }
        self.* = undefined;
    }

    /// Compiles and analyzes one pattern transactionally. The analyzer callback
    /// reserves entry/root publication before deriving its formula; only a
    /// successful Regex build commits both arrays. Diagnostics and allocation
    /// failures therefore consume neither ownership nor an insertion-order ID.
    pub fn add(self: *Builder, pattern: []const u8) BuilderError!AddResult {
        if (self.finished) return error.BuilderFinished;
        const id = std.math.cast(u32, self.entries.items.len) orelse return error.OutOfMemory;
        const budget = try self.ensureBudget();
        const collection_allocator = budget.allocator();
        var compile_options = self.options;
        if (budget.remaining()) |remaining| compile_options.compile_memory = switch (compile_options.compile_memory) {
            .bytes => |bytes| .{ .bytes = @min(bytes, remaining) },
            .unlimited => .{ .bytes = remaining },
        };
        // Adapter passed into `compiled.buildAnalyzed`. It reserves entry/root
        // publication before committing one analyzer formula, making Regex and
        // filter analysis one transaction.
        // Adapter that makes required-atom analysis the last fallible step of
        // Regex compilation, so formula root and Regex ownership commit together.
        const Analysis = struct {
            allocator: std.mem.Allocator,
            analyzer: *RequirementAnalyzer,
            entries: *std.ArrayList(RegexEntry),
            roots: *std.ArrayList(FormulaId),
            completed: *usize,
            root: ?FormulaId = null,

            /// Reserves both publication arrays and derives one formula. The
            /// caller appends Regex and root only after State construction also
            /// succeeds, leaving diagnostics and OOM transaction-neutral.
            pub fn analyze(
                context: *@This(),
                tree: *const regexp.Regexp,
                encoding: parser.Encoding,
            ) error{OutOfMemory}!void {
                // Reserve publication before committing persistent analysis.
                try context.entries.ensureUnusedCapacity(context.allocator, 1);
                try context.roots.ensureUnusedCapacity(context.allocator, 1);
                context.root = try context.analyzer.analyze(tree, encoding);
                context.completed.* +|= 1;
            }
        };
        var analysis: Analysis = .{
            .allocator = collection_allocator,
            .analyzer = &self.analyzer,
            .entries = &self.entries,
            .roots = &self.roots,
            .completed = &self.analysis_passes,
        };
        const compiled = compiled_module.buildAnalyzed(
            collection_allocator,
            pattern,
            compile_options,
            &analysis,
        ) catch |err| return self.resourceError(err);
        const regex_state = switch (compiled) {
            .success => |value| value,
            .diagnostic => |diagnostic| return .{ .diagnostic = diagnostic },
        };
        self.entries.appendAssumeCapacity(.{ .regex = .{ .state = regex_state } });
        self.roots.appendAssumeCapacity(analysis.root.?);
        return .{ .success = id };
    }

    /// Publishes atoms and formulas and consumes further builder use. Plan
    /// construction first maps and compacts all analyzer roots; only then are
    /// Regex entries transferred and Builder scratch released. SharedState and
    /// its reserved accounting become visible together, preserving retry-safe
    /// ownership on every preceding failure.
    pub fn compile(self: *Builder) BuilderError!Filtered {
        if (self.finished) return error.BuilderFinished;
        const budget = try self.ensureBudget();
        const collection_allocator = budget.allocator();
        if (!budget.reserve(@sizeOf(SharedState))) return error.CollectionMemoryLimit;
        errdefer budget.release(@sizeOf(SharedState));
        const state = try self.allocator.create(SharedState);
        errdefer self.allocator.destroy(state);
        var plan = buildFilterPlan(
            collection_allocator,
            &self.analyzer,
            self.roots.items,
            self.min_atom_len,
        ) catch |err| return self.resourceError(err);
        errdefer plan.deinit();
        const entries = self.entries.toOwnedSlice(collection_allocator) catch |err|
            return self.resourceError(err);

        self.roots.deinit(collection_allocator);
        self.analyzer.deinit();
        state.* = .{
            .budget = budget,
            .entries = entries,
            .plan = plan,
        };
        self.budget = null;
        self.finished = true;
        self.owns_build_state = false;
        return .{ .state = state };
    }

    /// Lazily installs the collection budget and redirects the persistent
    /// analyzer to its allocator before the first pattern is added.
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
        self.analyzer.allocator = budget.allocator();
        return budget;
    }

    /// Distinguishes configured collection exhaustion from backing allocator
    /// failure after a fallible compile/analysis/publication step.
    fn resourceError(self: *const Builder, err: error{OutOfMemory}) BuilderError {
        if (self.budget) |budget| if (budget.exhausted) return error.CollectionMemoryLimit;
        return err;
    }
};

/// Stable published owner borrowed by Filtered.Matchers. Entry Regex States may
/// lazily mutate their own synchronized caches.
const SharedState = struct {
    budget: *budget_allocator.BudgetAllocator,
    entries: []RegexEntry,
    plan: FilterPlan,

    fn destroy(self: *SharedState) void {
        const allocator = self.budget.child;
        const collection_allocator = self.budget.allocator();
        self.plan.deinit();
        for (self.entries) |*entry| entry.regex.deinit();
        if (self.entries.len != 0) collection_allocator.free(self.entries);
        self.budget.release(@sizeOf(SharedState));
        std.debug.assert(self.budget.live == 0);
        allocator.destroy(self.budget);
        allocator.destroy(self);
    }
};

/// Published formula/atom plan plus independently compiled Regex entries.
/// Matchers borrow normalized atoms and verify conservative candidates against
/// those Regex states, so the collection must outlive all Matcher values.
pub const Filtered = struct {
    pub const Builder = filtered_module.Builder;
    pub const Matcher = filtered_module.Matcher;
    pub const Ids = filtered_module.Ids;
    pub const AddResult = filtered_module.AddResult;
    pub const MatchError = filtered_module.MatchError;
    pub const BuilderError = filtered_module.BuilderError;
    pub const Metrics = filtered_module.CollectionMetrics;

    state: *SharedState,

    /// Returns normalized atom bytes valid until Filtered teardown.
    pub fn atoms(self: *const Filtered) []const []const u8 {
        return self.state.plan.atoms;
    }

    /// Returns the number of insertion-order pattern IDs.
    pub fn count(self: *const Filtered) u32 {
        return @intCast(self.state.entries.len);
    }

    /// Exact aggregate requested bytes for construction, retained regexes,
    /// published formulas, and lazily created shared caches.
    pub fn collectionMetrics(self: *const Filtered) CollectionMetrics {
        return budgetMetrics(self.state.budget, .published);
    }

    /// Creates single-threaded bounded verification scratch for this Filtered.
    pub fn matcher(
        self: *const Filtered,
        allocator: std.mem.Allocator,
    ) error{ OutOfMemory, ScratchLimitExceeded }!filtered_module.Matcher {
        return self.matcherWithOptions(allocator, .{});
    }

    /// Creates verification scratch under an explicit requested-byte ceiling.
    /// The largest entry sizes one reusable BooleanVerifier that later binds to
    /// every candidate; one Boolean allocation is split into atom and formula
    /// values. Budget denial leaves no verifier or scratch owner published.
    pub fn matcherWithOptions(
        self: *const Filtered,
        allocator: std.mem.Allocator,
        options: matcher_module.MatcherOptions,
    ) error{ OutOfMemory, ScratchLimitExceeded }!filtered_module.Matcher {
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
        var verifier: ?matcher_module.BooleanVerifier = null;
        errdefer if (verifier) |*engine| engine.deinit();
        if (self.state.entries.len != 0) {
            var largest = &self.state.entries[0].regex;
            for (self.state.entries[1..]) |*entry| {
                if (entry.regex.state.program.priority_lists.items.len >
                    largest.state.program.priority_lists.items.len)
                    largest = &entry.regex;
            }
            verifier = matcher_module.BooleanVerifier.init(
                scratch_allocator,
                largest,
                .{ .scratch_memory = .unlimited },
            ) catch |err| {
                if (budget.exhausted) return error.ScratchLimitExceeded;
                return err;
            };
        }
        const scratch_len = std.math.add(
            usize,
            self.state.plan.atoms.len,
            self.state.plan.nodes.len,
        ) catch return error.OutOfMemory;
        const scratch = scratch_allocator.alloc(bool, scratch_len) catch |err| {
            if (budget.exhausted) return error.ScratchLimitExceeded;
            return err;
        };
        const atom_count = self.state.plan.atoms.len;
        return .{
            .allocator = scratch_allocator,
            .budget = budget,
            .state = self.state,
            .verifier = verifier,
            .scratch = scratch,
            .matched_atoms = scratch[0..atom_count],
            .node_values = scratch[atom_count..],
            .normalized = .empty,
        };
    }

    /// Releases the collection after all of its Matchers are destroyed.
    pub fn deinit(self: *Filtered) void {
        self.state.destroy();
        self.* = undefined;
    }
};

/// Private cumulative formula/verification work observations.
const MatcherDiagnostics = struct {
    evaluation_passes: usize = 0,
    evaluated_nodes: usize = 0,
    verification_binds: usize = 0,
};

/// Single-threaded candidate and verification scratch for one Filtered. Atom
/// hits evaluate the immutable formula plan into conservative candidate decisions;
/// candidates are then checked exactly through one rebindable BooleanVerifier.
/// Integrated scans additionally retain reusable normalized-input storage.
pub const Matcher = struct {
    pub const Options = matcher_module.MatcherOptions;
    pub const Metrics = matcher_module.MatcherMetrics;
    pub const WorkLimitError = filtered_module.WorkError;

    allocator: std.mem.Allocator,
    budget: *budget_allocator.BudgetAllocator,
    state: *SharedState,
    verifier: ?matcher_module.BooleanVerifier,
    scratch: []bool,
    matched_atoms: []bool,
    node_values: []bool,
    normalized: std.ArrayList(u8),
    diagnostics: MatcherDiagnostics = .{},

    pub fn deinit(self: *Matcher) void {
        self.normalized.deinit(self.allocator);
        if (self.scratch.len != 0) self.allocator.free(self.scratch);
        if (self.verifier) |*engine| engine.deinit();
        std.debug.assert(self.budget.live == 0);
        const backing_allocator = self.budget.child;
        backing_allocator.destroy(self.budget);
        self.* = undefined;
    }

    pub fn metrics(self: *const Matcher) matcher_module.MatcherMetrics {
        const overhead = @sizeOf(budget_allocator.BudgetAllocator);
        return .{
            .requested_live_bytes = self.budget.live +| overhead,
            .requested_peak_bytes = self.budget.peak +| overhead,
            .allocation_count = self.budget.allocation_count +| 1,
        };
    }

    /// Verifies candidates and returns the lowest matching insertion ID.
    pub fn firstMatch(
        self: *Matcher,
        input: []const u8,
        matched_atom_ids: []const u32,
    ) MatchError!?u32 {
        try self.prepareCandidates(matched_atom_ids);
        return self.firstVerifiedCandidate(input);
    }

    /// Admits the conservative formula-plus-all-verifiers work bound before using
    /// externally supplied atom IDs and returning the first exact ID.
    pub fn firstMatchWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        matched_atom_ids: []const u32,
        max_work: usize,
    ) (MatchError || WorkError)!?u32 {
        try self.admitWork(input.len, max_work);
        return self.firstMatch(input, matched_atom_ids);
    }

    /// Scans normalized atoms internally, verifies candidates, and returns the
    /// lowest matching insertion ID.
    pub fn firstMatchScanned(self: *Matcher, input: []const u8) MatchError!?u32 {
        try self.prepareScannedCandidates(input);
        return self.firstVerifiedCandidate(input);
    }

    /// Work-limited integrated scan/formula/verification path.
    pub fn firstMatchScannedWithWorkLimit(
        self: *Matcher,
        input: []const u8,
        max_work: usize,
    ) (MatchError || WorkError)!?u32 {
        try self.admitWork(input.len, max_work);
        return self.firstMatchScanned(input);
    }

    /// Verifies candidates and returns all matching insertion IDs under a hard
    /// result-count ceiling.
    pub fn allMatches(
        self: *Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        matched_atom_ids: []const u32,
        max_results: usize,
    ) MatchError!Ids {
        try self.prepareCandidates(matched_atom_ids);
        return self.collectVerifiedCandidates(allocator, input, max_results);
    }

    /// Scans atoms internally and returns verified insertion IDs under a hard
    /// result-count ceiling.
    pub fn allMatchesScanned(
        self: *Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        max_results: usize,
    ) MatchError!Ids {
        try self.prepareScannedCandidates(input);
        return self.collectVerifiedCandidates(allocator, input, max_results);
    }

    /// Returns the conservative insertion-ID superset without verification.
    pub fn allCandidates(
        self: *Matcher,
        allocator: std.mem.Allocator,
        matched_atom_ids: []const u32,
        max_results: usize,
    ) MatchError!Ids {
        try self.prepareCandidates(matched_atom_ids);
        return self.collectCandidates(allocator, max_results);
    }

    /// Scans atoms internally and returns the conservative insertion-ID
    /// superset without regex verification.
    pub fn allCandidatesScanned(
        self: *Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        max_results: usize,
    ) MatchError!Ids {
        try self.prepareScannedCandidates(input);
        return self.collectCandidates(allocator, max_results);
    }

    /// Scans Regex roots in insertion order, preserving lowest-ID semantics while
    /// avoiding verification for false formula roots.
    fn firstVerifiedCandidate(self: *Matcher, input: []const u8) ?u32 {
        for (self.state.entries, 0..) |_, id| {
            if (self.isCandidate(id) and self.verify(id, input)) return @intCast(id);
        }
        return null;
    }

    /// Verifies true formula roots in insertion order and appends exact IDs up to
    /// the caller's hard result limit.
    fn collectVerifiedCandidates(
        self: *Matcher,
        allocator: std.mem.Allocator,
        input: []const u8,
        max_results: usize,
    ) error{ OutOfMemory, ResultLimitExceeded }!Ids {
        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(allocator);
        for (self.state.entries, 0..) |_, id| {
            if (!self.isCandidate(id) or !self.verify(id, input)) continue;
            if (ids.items.len == max_results) return error.ResultLimitExceeded;
            try ids.append(allocator, @intCast(id));
        }
        return .{ .allocator = allocator, .items = try ids.toOwnedSlice(allocator) };
    }

    /// Publishes the conservative formula-root superset without running Regex
    /// verification.
    fn collectCandidates(
        self: *const Matcher,
        allocator: std.mem.Allocator,
        max_results: usize,
    ) error{ OutOfMemory, ResultLimitExceeded }!Ids {
        var ids: std.ArrayList(u32) = .empty;
        errdefer ids.deinit(allocator);
        for (self.state.entries, 0..) |_, id| if (self.isCandidate(id)) {
            if (ids.items.len == max_results) return error.ResultLimitExceeded;
            try ids.append(allocator, @intCast(id));
        };
        return .{ .allocator = allocator, .items = try ids.toOwnedSlice(allocator) };
    }

    /// One O(F) formula pass prepares O(1) root reads for all R regexes.
    fn prepareCandidates(self: *Matcher, ids: []const u32) error{InvalidAtomId}!void {
        @memset(self.matched_atoms, false);
        for (ids) |id| {
            if (id >= self.matched_atoms.len) return error.InvalidAtomId;
            self.matched_atoms[id] = true;
        }
        self.evaluateCandidates();
    }

    /// Uses register-folded ASCII scanning when possible; any non-ASCII byte
    /// triggers full encoding-aware normalization and exact atom rescan.
    fn prepareScannedCandidates(
        self: *Matcher,
        input: []const u8,
    ) error{ OutOfMemory, ScratchLimitExceeded }!void {
        if (self.state.plan.scanner.scanAsciiFolded(
            self.state.plan.atoms,
            input,
            self.matched_atoms,
        )) {
            self.evaluateCandidates();
            return;
        }
        try self.normalizeInput(input);
        self.state.plan.scanner.scan(
            self.state.plan.atoms,
            self.normalized.items,
            self.matched_atoms,
        );
        self.evaluateCandidates();
    }

    /// Produces the same canonical lowercase byte representation used by atom
    /// analysis. Malformed UTF-8 bytes are preserved/lowercased individually so
    /// normalization remains total over arbitrary input.
    fn normalizeInput(
        self: *Matcher,
        input: []const u8,
    ) error{ OutOfMemory, ScratchLimitExceeded }!void {
        self.normalized.clearRetainingCapacity();
        self.normalized.ensureTotalCapacity(self.allocator, input.len) catch |err| {
            if (self.budget.exhausted) return error.ScratchLimitExceeded;
            return err;
        };
        if (self.state.plan.encoding == .latin1) {
            for (input) |byte| self.normalized.appendAssumeCapacity(std.ascii.toLower(byte));
            return;
        }
        var position: usize = 0;
        while (position < input.len) {
            if (input[position] < 0x80) {
                self.normalized.appendAssumeCapacity(std.ascii.toLower(input[position]));
                position += 1;
                continue;
            }
            const width = std.unicode.utf8ByteSequenceLength(input[position]) catch {
                self.normalized.appendAssumeCapacity(std.ascii.toLower(input[position]));
                position += 1;
                continue;
            };
            if (width > input.len - position) {
                self.normalized.appendAssumeCapacity(std.ascii.toLower(input[position]));
                position += 1;
                continue;
            }
            const rune = std.unicode.utf8Decode(input[position..][0..width]) catch {
                self.normalized.appendAssumeCapacity(std.ascii.toLower(input[position]));
                position += 1;
                continue;
            };
            const encoded = byte_encoding.encodeRune(unicode_data.toLower(rune));
            self.normalized.ensureUnusedCapacity(self.allocator, encoded.len) catch |err| {
                if (self.budget.exhausted) return error.ScratchLimitExceeded;
                return err;
            };
            for (encoded.ranges[0..encoded.len]) |range| {
                std.debug.assert(range.lo == range.hi);
                self.normalized.appendAssumeCapacity(range.lo);
            }
            position += width;
        }
    }

    /// Evaluates the compact postorder formula graph once for current atom bits.
    fn evaluateCandidates(self: *Matcher) void {
        self.state.plan.evaluateAll(self.node_values, self.matched_atoms);
        self.diagnostics.evaluation_passes +|= 1;
        self.diagnostics.evaluated_nodes +|= self.state.plan.nodes.len;
    }

    fn isCandidate(self: *const Matcher, id: usize) bool {
        return self.state.plan.candidate(
            self.state.plan.roots[id],
            self.node_values,
        );
    }

    /// Rebinds the largest-sized reusable complete verifier to one candidate
    /// Regex and returns exact existence.
    fn verify(self: *Matcher, id: usize, input: []const u8) bool {
        const engine = &self.verifier.?;
        engine.bind(&self.state.entries[id].regex);
        self.diagnostics.verification_binds +|= 1;
        return engine.isMatch(input);
    }

    /// Conservatively admits formula work plus complete NFA verification for
    /// every retained Regex at every input position.
    fn admitWork(self: *const Matcher, input_bytes: usize, max_work: usize) WorkError!void {
        var per_position: usize = self.state.plan.nodes.len +| 1;
        for (self.state.entries) |*entry| {
            per_position = std.math.add(
                usize,
                per_position,
                entry.regex.state.program.priority_lists.items.len +| 1,
            ) catch return error.WorkLimitExceeded;
        }
        const positions = std.math.add(usize, input_bytes, 1) catch
            return error.WorkLimitExceeded;
        const required = std.math.mul(usize, positions, per_position) catch
            return error.WorkLimitExceeded;
        if (required > max_work) return error.WorkLimitExceeded;
    }
};

pub fn debugMatcherBytes(matcher: *const Matcher) usize {
    return matcher.metrics().requested_live_bytes;
}

/// Owner-overhead adjustment differs before and after SharedState publication.
const MetricScope = enum { builder, published };

/// Combines wrapper counters with owner allocations charged directly to its child,
/// accounting differently before and after SharedState transfer.
fn budgetMetrics(
    budget: *const budget_allocator.BudgetAllocator,
    scope: MetricScope,
) CollectionMetrics {
    const fixed_allocations: usize = switch (scope) {
        .builder => 1,
        .published => 2,
    };
    return .{
        .requested_live_bytes = budget.live +| @sizeOf(budget_allocator.BudgetAllocator),
        .requested_peak_bytes = budget.peak +| @sizeOf(budget_allocator.BudgetAllocator),
        .allocation_count = budget.allocation_count +| fixed_allocations,
    };
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

// Module-local qualification tests.

const testing = std.testing;

fn addOk(builder: *Builder, pattern: []const u8) !u32 {
    return switch (try builder.add(pattern)) {
        .success => |id| id,
        .diagnostic => error.UnexpectedDiagnostic,
    };
}

fn atomIndex(filtered: *const Filtered, atom: []const u8) ?u32 {
    for (filtered.atoms(), 0..) |value, index|
        if (std.mem.eql(u8, value, atom)) return @intCast(index);
    return null;
}

test "Filtered required atoms match qualification tables" {
    const Case = struct { patterns: []const []const u8, atoms: []const []const u8 };
    const cases = [_]Case{
        .{ .patterns = &.{""}, .atoms = &.{} },
        .{ .patterns = &.{ "(abc123|def456|ghi789).*mnop[x-z]+", "abc..yyy..zz", "mnmnpp[a-z]+PPP" }, .atoms = &.{ "abc123", "def456", "ghi789", "mnop", "abc", "yyy", "mnmnpp", "ppp" } },
        .{ .patterns = &.{ "(abc123|abc|defxyz|ghi789|abc1234|xyz).*[x-z]+", "abcd..yyy..yyyzzz", "mnmnpp[a-z]+PPP" }, .atoms = &.{ "abc", "ghi789", "xyz", "abcd", "yyy", "yyyzzz", "mnmnpp", "ppp" } },
        .{ .patterns = &.{ "m[a-c][d-f]n.*[x-z]+", "[x-y]bcde[ab]" }, .atoms = &.{ "madn", "maen", "mafn", "mbdn", "mben", "mbfn", "mcdn", "mcen", "mcfn", "xbcdea", "xbcdeb", "ybcdea", "ybcdeb" } },
        .{ .patterns = &.{ "(?i)ΔδΠϖπΣςσ", "ΛΜΝΟΠ", "ψρστυ" }, .atoms = &.{ "δδπππσσσ", "λμνοπ", "ψρστυ" } },
    };
    for (cases) |case| {
        var builder = Builder.init(testing.allocator, .{}, 3);
        defer builder.deinit();
        for (case.patterns) |pattern| _ = try addOk(&builder, pattern);
        var filtered = try builder.compile();
        defer filtered.deinit();
        try testing.expectEqual(case.atoms.len, filtered.atoms().len);
        for (case.atoms) |atom| {
            if (atomIndex(&filtered, atom) == null) {
                std.debug.print("missing atom {s}; have={any}\n", .{ atom, filtered.atoms() });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "Filtered shared state survives handle relocation" {
    var builder = Builder.init(testing.allocator, .{}, 3);
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

    try testing.expectEqual(@as(?u32, 0), try matcher.firstMatchScanned("--foo--"));
}

test "Filtered collection budget covers retained regexes formulas and caches" {
    const limit = 2 * 1024 * 1024;
    var builder = Builder.initWithCollectionMemory(
        testing.allocator,
        .{ .dfa_memory = .{ .bytes = 256 * 1024 } },
        3,
        .{ .bytes = limit },
    );
    defer builder.deinit();
    _ = try addOk(&builder, "alpha.*omega");
    _ = try addOk(&builder, "(foo|bar)+baz");
    const build_metrics = builder.collectionMetrics();
    try testing.expect(build_metrics.requested_live_bytes > 0);
    try testing.expect(build_metrics.requested_peak_bytes <= limit);

    var filtered = try builder.compile();
    defer filtered.deinit();
    const published = filtered.collectionMetrics();
    try testing.expect(published.requested_live_bytes <= limit);
    try testing.expect(published.requested_peak_bytes <= limit);
    var matcher = try filtered.matcher(testing.allocator);
    defer matcher.deinit();
    _ = try matcher.firstMatch("alpha---omega", &.{
        atomIndex(&filtered, "alpha").?,
        atomIndex(&filtered, "omega").?,
    });
    const after_cache = filtered.collectionMetrics();
    try testing.expect(after_cache.requested_live_bytes <= limit);
    try testing.expect(after_cache.requested_peak_bytes <= limit);
    try testing.expect(after_cache.requested_peak_bytes >= published.requested_peak_bytes);

    var tiny = Builder.initWithCollectionMemory(
        testing.allocator,
        .{},
        3,
        .{ .bytes = @sizeOf(budget_allocator.BudgetAllocator) - 1 },
    );
    defer tiny.deinit();
    try testing.expectError(error.CollectionMemoryLimit, tiny.add("foo"));
}

test "Filtered analyzes each successfully parsed pattern exactly once" {
    var builder = Builder.init(testing.allocator, .{}, 3);
    defer builder.deinit();
    try testing.expectEqual(@as(usize, 0), builder.analysis_passes);
    _ = try addOk(&builder, "alpha.*omega");
    try testing.expectEqual(@as(usize, 1), builder.analysis_passes);
    try testing.expect((try builder.add("(")) == .diagnostic);
    try testing.expectEqual(@as(usize, 1), builder.analysis_passes);
    _ = try addOk(&builder, "zebra");
    try testing.expectEqual(@as(usize, 2), builder.analysis_passes);
}

test "Filtered atom publication deduplicates in first occurrence order" {
    var builder = Builder.init(testing.allocator, .{}, 3);
    defer builder.deinit();
    for ([_][]const u8{ "zebra", "alpha", "zebra", "middle" }) |pattern|
        _ = try addOk(&builder, pattern);
    var filtered = try builder.compile();
    defer filtered.deinit();
    try testing.expectEqual(@as(usize, 3), filtered.atoms().len);
    for (filtered.atoms(), [_][]const u8{ "zebra", "alpha", "middle" }) |actual, expected|
        try testing.expectEqualStrings(expected, actual);
}

test "Filtered empty small Latin and empty-atom behavior follows qualification" {
    var empty_builder = Builder.init(testing.allocator, .{}, 3);
    defer empty_builder.deinit();
    var empty = try empty_builder.compile();
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.atoms().len);
    var empty_matcher = try empty.matcher(testing.allocator);
    defer empty_matcher.deinit();
    try testing.expect((try empty_matcher.firstMatch("foo", &.{})) == null);

    var small_builder = Builder.init(testing.allocator, .{}, 4);
    defer small_builder.deinit();
    _ = try addOk(&small_builder, "(foo|bar)");
    var small = try small_builder.compile();
    defer small.deinit();
    try testing.expectEqual(@as(usize, 0), small.atoms().len);
    var small_matcher = try small.matcher(testing.allocator);
    defer small_matcher.deinit();
    try testing.expectEqual(@as(?u32, 0), try small_matcher.firstMatch("lemurs bar", &.{}));

    var latin_builder = Builder.init(testing.allocator, .{ .encoding = .latin1 }, 3);
    defer latin_builder.deinit();
    _ = try addOk(&latin_builder, "\xde\xadQ\xbe\xef");
    var latin = try latin_builder.compile();
    defer latin.deinit();
    try testing.expectEqual(@as(usize, 1), latin.atoms().len);
    try testing.expectEqualSlices(u8, "\xde\xadq\xbe\xef", latin.atoms()[0]);
    var latin_matcher = try latin.matcher(testing.allocator);
    defer latin_matcher.deinit();
    try testing.expectEqual(
        @as(?u32, 0),
        try latin_matcher.firstMatch("foo\xde\xadQ\xbe\xeflemur", &.{0}),
    );

    var bug_builder = Builder.init(testing.allocator, .{}, 0);
    defer bug_builder.deinit();
    _ = try addOk(&bug_builder, "-R.+(|ADD=;AA){12}}");
    var bug = try bug_builder.compile();
    defer bug.deinit();
    for ([_][]const u8{ "", "-r", "add=;aa", "}" }) |atom|
        try testing.expect(atomIndex(&bug, atom) != null);
    try testing.expectEqual(@as(usize, 4), bug.atoms().len);
}

test "Filtered publication interns repeated atom nodes" {
    var builder = Builder.init(testing.allocator, .{}, 1);
    defer builder.deinit();
    _ = try addOk(&builder, "foo.*bar");
    _ = try addOk(&builder, "foo.*baz");
    _ = try addOk(&builder, "foo.*bar");
    _ = try addOk(&builder, "foo.*bar.*baz");
    var filtered = try builder.compile();
    defer filtered.deinit();

    try testing.expectEqual(@as(usize, 3), filtered.atoms().len);
    var atom_nodes: usize = 0;
    for (filtered.state.plan.nodes) |node|
        atom_nodes += @intFromBool(node == .atom);
    try testing.expectEqual(filtered.atoms().len, atom_nodes);
    try testing.expectEqual(filtered.state.plan.roots[0], filtered.state.plan.roots[2]);
    const flattened = filtered.state.plan.nodes[@intFromEnum(filtered.state.plan.roots[3].?)];
    try testing.expectEqual(@as(u32, 3), flattened.and_node.len);
}

test "Filtered orders AND atoms by static selectivity" {
    var builder = Builder.init(testing.allocator, .{}, 3);
    defer builder.deinit();
    _ = try addOk(&builder, "foo.*substantiallylonger");
    var filtered = try builder.compile();
    defer filtered.deinit();
    const root = filtered.state.plan.roots[0].?;
    const span = filtered.state.plan.nodes[@intFromEnum(root)].and_node;
    const first = filtered.state.plan.children[span.start];
    const second = filtered.state.plan.children[span.start + 1];
    const first_atom = filtered.state.plan.nodes[@intFromEnum(first)].atom;
    const second_atom = filtered.state.plan.nodes[@intFromEnum(second)].atom;
    try testing.expect(filtered.atoms()[first_atom].len > filtered.atoms()[second_atom].len);
}

test "Filtered publication removes unreachable flattened intermediates" {
    var builder = Builder.init(testing.allocator, .{}, 1);
    defer builder.deinit();
    _ = try addOk(&builder, "foo.*bar.*baz");
    var filtered = try builder.compile();
    defer filtered.deinit();
    try testing.expectEqual(@as(usize, 4), filtered.state.plan.nodes.len);
    try testing.expectEqual(@as(usize, 3), filtered.state.plan.children.len);
}

test "Filtered relocation preserves matchers" {
    var builder = Builder.init(testing.allocator, .{ .perl_classes = true }, 3);
    defer builder.deinit();
    _ = try addOk(&builder, "foo\\d+");
    var original = try builder.compile();
    try testing.expectError(error.BuilderFinished, builder.add("bar"));
    try testing.expectError(error.BuilderFinished, builder.compile());
    var moved = original;
    original = undefined;
    defer moved.deinit();
    try testing.expectEqualStrings("foo", moved.atoms()[0]);
    var matcher = try moved.matcher(testing.allocator);
    defer matcher.deinit();
    try testing.expectEqual(@as(?u32, 0), try matcher.firstMatch("abc foo1 xyz", &.{0}));
    try testing.expect((try matcher.firstMatch("abc bar2 xyz", &.{0})) == null);
}

test "Filtered candidates remain conservative and verify exact matches" {
    var builder = Builder.init(testing.allocator, .{}, 3);
    defer builder.deinit();
    _ = try addOk(&builder, "(abc123|abc|defxyz|ghi789|abc1234|xyz).*[x-z]+");
    _ = try addOk(&builder, "abcd..yyy..yyyzzz");
    _ = try addOk(&builder, "mnmnpp[a-z]+PPP");
    var filtered = try builder.compile();
    defer filtered.deinit();
    var matcher = try filtered.matcher(testing.allocator);
    defer matcher.deinit();

    const abc = atomIndex(&filtered, "abc").?;
    const xyz = atomIndex(&filtered, "xyz").?;
    try testing.expectEqual(@as(usize, 0), matcher.diagnostics.evaluation_passes);
    var first = try matcher.allMatches(testing.allocator, "abc121212xyz", &.{ abc, xyz }, 3);
    defer first.deinit();
    try testing.expectEqualSlices(u32, &.{0}, first.values());
    try testing.expectEqual(@as(usize, 1), matcher.diagnostics.evaluation_passes);
    try testing.expectEqual(filtered.state.plan.nodes.len, matcher.diagnostics.evaluated_nodes);

    const abcd = atomIndex(&filtered, "abcd").?;
    const yyy = atomIndex(&filtered, "yyy").?;
    const yyyzzz = atomIndex(&filtered, "yyyzzz").?;
    var second = try matcher.allMatches(
        testing.allocator,
        "abcd12yyy32yyyzzz",
        &.{ abc, abcd, yyy, yyyzzz },
        3,
    );
    defer second.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, second.items);
    try testing.expectEqual(@as(usize, 2), matcher.diagnostics.evaluation_passes);
    try testing.expectEqual(filtered.state.plan.nodes.len * 2, matcher.diagnostics.evaluated_nodes);
    try testing.expectError(error.InvalidAtomId, matcher.firstMatch("x", &.{999}));
    try testing.expectEqual(@as(usize, 2), matcher.diagnostics.evaluation_passes);
}

test "Filtered uses one bounded verifier across all candidate regexes" {
    var builder = Builder.init(testing.allocator, .{ .dfa_memory = .disabled }, 100);
    defer builder.deinit();
    _ = try addOk(&builder, "a");
    _ = try addOk(&builder, "(ab|ac|ad|ae|af)+z");
    _ = try addOk(&builder, "longer-literal");
    var filtered = try builder.compile();
    defer filtered.deinit();
    var matcher = try filtered.matcher(testing.allocator);
    defer matcher.deinit();

    try testing.expect(matcher.verifier != null);
    var ids = try matcher.allMatches(
        testing.allocator,
        "acacz",
        &.{},
        filtered.count(),
    );
    defer ids.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, ids.items);
    try testing.expectEqual(@as(usize, 3), matcher.diagnostics.verification_binds);
    try testing.expect((try matcher.firstMatch("none", &.{})) == null);
    try testing.expectEqual(@as(usize, 6), matcher.diagnostics.verification_binds);
}

test "Filtered formula evaluation is one linear pass per atom set" {
    var builder = Builder.init(testing.allocator, .{}, 3);
    defer builder.deinit();
    _ = try addOk(&builder, "abc.*xyz");
    _ = try addOk(&builder, "def.*uvw");
    _ = try addOk(&builder, "foo|bar");
    var filtered = try builder.compile();
    defer filtered.deinit();
    var matcher = try filtered.matcher(testing.allocator);
    defer matcher.deinit();

    const abc = atomIndex(&filtered, "abc").?;
    var potentials = try matcher.allCandidates(
        testing.allocator,
        &.{abc},
        filtered.count(),
    );
    defer potentials.deinit();
    try testing.expectEqual(@as(usize, 1), matcher.diagnostics.evaluation_passes);
    try testing.expectEqual(filtered.state.plan.nodes.len, matcher.diagnostics.evaluated_nodes);

    for (0..@as(usize, filtered.count())) |id| _ = matcher.isCandidate(id);
    try testing.expectEqual(@as(usize, 1), matcher.diagnostics.evaluation_passes);
    try testing.expectEqual(filtered.state.plan.nodes.len, matcher.diagnostics.evaluated_nodes);
    try testing.expectError(error.InvalidAtomId, matcher.firstMatch("abcxyz", &.{999}));
    try testing.expectEqual(@as(usize, 1), matcher.diagnostics.evaluation_passes);
}

fn allocationFilteredLifecycle(allocator: std.mem.Allocator) !void {
    var builder = Builder.init(allocator, .{ .perl_classes = true }, 3);
    defer builder.deinit();
    _ = switch (try builder.add("foo\\d+")) {
        .success => |id| id,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    _ = switch (try builder.add("bar$")) {
        .success => |id| id,
        .diagnostic => return error.UnexpectedDiagnostic,
    };
    var filtered = try builder.compile();
    defer filtered.deinit();
    var matcher = try filtered.matcher(allocator);
    defer matcher.deinit();
    var ids = try matcher.allMatchesScanned(allocator, "foo12", 2);
    ids.deinit();
}

test "ASCII atom scanning never filters a real match" {
    var builder = Builder.init(testing.allocator, .{ .perl_classes = true }, 3);
    defer builder.deinit();
    for ([_][]const u8{
        "(abc|def).*xyz",
        "foo\\d+",
        "bar$",
        "a.*b.*c",
        "(short|tiny)",
    }) |pattern| _ = try addOk(&builder, pattern);
    var filtered = try builder.compile();
    defer filtered.deinit();
    var matcher = try filtered.matcher(testing.allocator);
    defer matcher.deinit();

    for ([_][]const u8{
        "ABC---xyz",
        "foo123 and bar",
        "xxa11b22cxx",
        "tiny",
        "no match here",
    }) |input| {
        const lower = try testing.allocator.alloc(u8, input.len);
        defer testing.allocator.free(lower);
        for (input, lower) |byte, *out| out.* = std.ascii.toLower(byte);
        var atom_ids: std.ArrayList(u32) = .empty;
        defer atom_ids.deinit(testing.allocator);
        for (filtered.atoms(), 0..) |atom, id|
            if (std.mem.indexOf(u8, lower, atom) != null)
                try atom_ids.append(testing.allocator, @intCast(id));

        var actual = try matcher.allMatches(
            testing.allocator,
            input,
            atom_ids.items,
            filtered.count(),
        );
        defer actual.deinit();
        var scanned = try matcher.allMatchesScanned(
            testing.allocator,
            input,
            filtered.count(),
        );
        defer scanned.deinit();
        var expected: std.ArrayList(u32) = .empty;
        defer expected.deinit(testing.allocator);
        for (filtered.state.entries, 0..) |*entry, id| {
            var independent = try matcher_module.Matcher.init(testing.allocator, &entry.regex);
            const matched = independent.isMatch(input);
            independent.deinit();
            if (matched) try expected.append(testing.allocator, @intCast(id));
        }
        try testing.expectEqualSlices(u32, expected.items, actual.items);
        try testing.expectEqualSlices(u32, expected.items, scanned.items);
    }
}

test "Integrated Teddy scan normalizes Unicode and verifies collisions" {
    var builder = Builder.init(testing.allocator, .{}, 2);
    defer builder.deinit();
    for ([_][]const u8{
        "(?i)ΔδΠϖπΣςσ",
        "Kilo",
        "alpha",
        "bravo",
        "charlie",
        "delta",
        "echo",
        "foxtrot",
        "golf",
    }) |pattern| _ = try addOk(&builder, pattern);
    var filtered = try builder.compile();
    defer filtered.deinit();
    try testing.expect(filtered.state.plan.scanner.depth != 0);
    var matcher = try filtered.matcher(testing.allocator);
    defer matcher.deinit();
    try testing.expectEqual(@as(?u32, 0), try matcher.firstMatchScanned("--ΔΔΠϖΠΣςΣ--"));
    try testing.expectEqual(@as(?u32, 1), try matcher.firstMatchScanned("Kilo"));
    try testing.expectEqual(@as(?u32, null), try matcher.firstMatchScanned("nothing"));
}

test "Filtered matcher scratch budget is exact and reusable after denial" {
    var builder = Builder.init(testing.allocator, .{}, 2);
    defer builder.deinit();
    _ = try addOk(&builder, "alpha.*beta");
    _ = try addOk(&builder, "gamma[0-9]+");
    var filtered = try builder.compile();
    defer filtered.deinit();

    try testing.expectError(
        error.ScratchLimitExceeded,
        filtered.matcherWithOptions(
            testing.allocator,
            .{ .scratch_memory = .{ .bytes = 0 } },
        ),
    );
    var probe = try filtered.matcherWithOptions(
        testing.allocator,
        .{ .scratch_memory = .unlimited },
    );
    try testing.expectEqual(@as(?u32, 0), try probe.firstMatchScanned("alpha--beta"));
    const required = probe.metrics().requested_peak_bytes;
    probe.deinit();
    var limited = try filtered.matcherWithOptions(
        testing.allocator,
        .{ .scratch_memory = .{ .bytes = required - 1 } },
    );
    defer limited.deinit();
    try testing.expectError(
        error.ScratchLimitExceeded,
        limited.firstMatchScanned("alpha--beta"),
    );
    var exact = try filtered.matcherWithOptions(
        testing.allocator,
        .{ .scratch_memory = .{ .bytes = required } },
    );
    defer exact.deinit();
    try testing.expectEqual(@as(?u32, 0), try exact.firstMatchScanned("alpha--beta"));
    try testing.expectError(
        error.WorkLimitExceeded,
        exact.firstMatchScannedWithWorkLimit("alpha--beta", 0),
    );
    try testing.expectEqual(
        @as(?u32, 0),
        try exact.firstMatchScannedWithWorkLimit(
            "alpha--beta",
            std.math.maxInt(usize),
        ),
    );
    try testing.expectEqual(required, exact.metrics().requested_peak_bytes);
}

test "Filtered lifecycle owns every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationFilteredLifecycle,
        .{},
    );
}
