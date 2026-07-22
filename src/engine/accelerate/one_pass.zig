//! Deterministic capture-plan construction and exact-range execution.
//!
//! Plan construction computes the epsilon closure for every Program root. A
//! closure is OnePass-eligible only when each byte class selects at most one
//! consuming successor and there is at most one accepting route. Ambiguous
//! overlap, unsupported assertion interaction, or too many capture slots rejects
//! the entire plan rather than approximating it.
//!
//! Capture instructions encountered along a unique route become a bit mask. All
//! writes in one closure occur at the same absolute position, so one compact mask
//! is sufficient. `PlanState` stores the end route and a dense route table indexed
//! by `(state, byte class)`; successor roots become plan-state IDs.
//!
//! `Plan` is immutable and shared by all Matchers for a Regex. `Executor` owns the
//! mutable capture slots only. Exact execution walks the requested byte range in
//! one route per byte, applies capture masks at each position, and accepts only
//! through the planned endpoint route. A null/ineligible plan or execution error
//! is a clean decline to BitState/capture NFA.

const std = @import("std");
const match_types = @import("../../match.zig");
const program = @import("../../program/program.zig");

/// The u16 action mask admits whole match plus seven explicit groups.
pub const capture_slot_limit: u32 = 16;
const CaptureMask = u16;
/// Deterministic transition for one byte class. Actions write capture slots at
/// the transition's current absolute position.
const Route = struct {
    destination: u32 = 0,
    actions: CaptureMask = 0,
    valid: bool = false,
};
/// Closure summary for one Program root: dense byte-class routes plus one
/// optional exact-end accepting route.
const PlanState = struct {
    routes: []Route,
    end_actions: CaptureMask,
    accepts_end: bool,
};
/// Explicit closure path carrying accumulated capture actions and whether an
/// end-text assertion restricts this path to the exact endpoint.
const Work = struct {
    root: u32,
    index: u32,
    actions: CaptureMask,
    end_only: bool,
};

/// Fully prepared immutable closure plans shared by every Regex matcher. Each
/// root indexes a deterministic byte-route/action table proved by plan building;
/// the owner records the backing allocator because publication may outlive its
/// temporary budget wrapper.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    plans: []?*PlanState,

    pub fn init(
        allocator: std.mem.Allocator,
        prog: *const program.Program,
    ) (error{ OutOfMemory, Ineligible })!Plan {
        return initWithBackingAllocator(allocator, allocator, prog);
    }

    /// Builds every PlanState reachable from the start root transactionally.
    /// Temporary construction uses `allocator`; published ownership records
    /// `backing_allocator` for teardown after a budget wrapper disappears.
    pub fn initWithBackingAllocator(
        allocator: std.mem.Allocator,
        backing_allocator: std.mem.Allocator,
        prog: *const program.Program,
    ) (error{ OutOfMemory, Ineligible })!Plan {
        if (prog.capture_slots > capture_slot_limit) return error.Ineligible;
        var builder = try Matcher.initPlanBuilder(allocator, prog);
        defer builder.deinit();
        var queued = try allocator.alloc(bool, prog.priority_lists.lists.len);
        defer allocator.free(queued);
        @memset(queued, false);
        var roots: std.ArrayList(u32) = .empty;
        defer roots.deinit(allocator);
        try roots.append(allocator, prog.priority_lists.start_root);
        queued[prog.priority_lists.start_root] = true;
        var index: usize = 0;
        while (index < roots.items.len) : (index += 1) {
            const state = try builder.buildPlan(roots.items[index]);
            for (state.routes) |route| {
                if (!route.valid or queued[route.destination]) continue;
                queued[route.destination] = true;
                try roots.append(allocator, route.destination);
            }
        }
        const plans = builder.plans;
        builder.owns_plans = false;
        return .{ .allocator = backing_allocator, .plans = plans };
    }

    pub fn requestedBytes(self: *const Plan) usize {
        var total = self.plans.len * @sizeOf(?*PlanState);
        for (self.plans) |plan| if (plan) |value| {
            total +|= @sizeOf(PlanState);
            total +|= value.routes.len * @sizeOf(Route);
        };
        return total;
    }

    pub fn stateCount(self: *const Plan) usize {
        var count: usize = 0;
        for (self.plans) |plan| count += @intFromBool(plan != null);
        return count;
    }

    pub fn deinit(self: *Plan) void {
        for (self.plans) |plan| if (plan) |value| {
            self.allocator.free(value.routes);
            self.allocator.destroy(value);
        };
        if (self.plans.len != 0) self.allocator.free(self.plans);
        self.* = undefined;
    }
};

/// Matcher-local capture slots executing one shared immutable Plan.
pub const Executor = struct {
    allocator: std.mem.Allocator,
    prog: *const program.Program,
    plans: []?*PlanState,
    slots: []?usize,

    /// Allocates only matcher-local result slots over a borrowed immutable Plan.
    /// The Program and Plan must outlive this Executor.
    pub fn init(
        allocator: std.mem.Allocator,
        prog: *const program.Program,
        plan: *const Plan,
    ) error{OutOfMemory}!Executor {
        return .{
            .allocator = allocator,
            .prog = prog,
            .plans = plan.plans,
            .slots = try allocator.alloc(?usize, prog.capture_slots),
        };
    }

    pub fn deinit(self: *Executor) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Executes the prepared deterministic route over exactly the requested
    /// range. `null` is real non-acceptance; `Ineligible` means a needed plan
    /// state was not published and permits another exact capture engine.
    pub fn capturesExact(
        self: *Executor,
        input: []const u8,
        range_start: usize,
        range_end: usize,
    ) (error{ InvalidRange, OutOfMemory, Ineligible })!?match_types.CaptureView {
        if (range_start > range_end or range_end > input.len) return error.InvalidRange;
        return runExact(self, input, range_start, range_end);
    }

    /// Borrows a prepared state; absence is a decline rather than a semantic
    /// no-match because immutable Executors are not allowed to extend the Plan.
    fn executionPlan(self: *Executor, state: u32) error{ OutOfMemory, Ineligible }!*PlanState {
        return self.plans[state] orelse error.Ineligible;
    }
};

/// Combined lazy plan builder/executor used by direct engine tests and as the
/// construction machinery behind immutable `Plan`. `owns_plans` controls whether
/// teardown releases the plan table after publication transfers it.
pub const Matcher = struct {
    allocator: std.mem.Allocator,
    prog: *const program.Program,
    plans: []?*PlanState,
    work: std.ArrayList(Work) = .empty,
    seen_rows: []bool,
    seen: []bool,
    seen_actions: []CaptureMask,
    seen_end_only: []bool,
    slots: []?usize,
    eligible: bool,
    owns_plans: bool = true,

    /// Creates the direct/test form that owns lazy plans and result slots.
    /// Production sharing normally builds a `Plan` and uses a smaller Executor.
    pub fn init(allocator: std.mem.Allocator, prog: *const program.Program) !Matcher {
        return initMode(allocator, prog, true);
    }

    fn initPlanBuilder(allocator: std.mem.Allocator, prog: *const program.Program) !Matcher {
        return initMode(allocator, prog, false);
    }

    /// Allocates common plan-construction scratch and optionally execution slots.
    /// Immutable Plan construction sets `execution_slots = false` to avoid
    /// retaining matcher-local result memory.
    fn initMode(
        allocator: std.mem.Allocator,
        prog: *const program.Program,
        comptime execution_slots: bool,
    ) !Matcher {
        const plans = try allocator.alloc(?*PlanState, prog.priority_lists.lists.len);
        errdefer allocator.free(plans);
        @memset(plans, null);
        const item_count = prog.priority_lists.items.len;
        const seen_len = std.math.mul(usize, item_count, 2) catch
            return error.OutOfMemory;
        const seen_rows = try allocator.alloc(bool, seen_len);
        errdefer allocator.free(seen_rows);
        const seen_actions = try allocator.alloc(CaptureMask, item_count);
        errdefer allocator.free(seen_actions);
        const slots: []?usize = if (execution_slots)
            try allocator.alloc(?usize, prog.capture_slots)
        else
            &.{};
        return .{
            .allocator = allocator,
            .prog = prog,
            .plans = plans,
            .seen_rows = seen_rows,
            .seen = seen_rows[0..item_count],
            .seen_actions = seen_actions,
            .seen_end_only = seen_rows[item_count..],
            .slots = slots,
            .eligible = prog.capture_slots <= capture_slot_limit,
        };
    }

    pub fn deinit(self: *Matcher) void {
        if (self.owns_plans) {
            for (self.plans) |plan| if (plan) |value| {
                self.allocator.free(value.routes);
                self.allocator.destroy(value);
            };
            if (self.plans.len != 0) self.allocator.free(self.plans);
        }
        if (self.slots.len != 0) self.allocator.free(self.slots);
        if (self.seen_actions.len != 0) self.allocator.free(self.seen_actions);
        if (self.seen_rows.len != 0) self.allocator.free(self.seen_rows);
        self.work.deinit(self.allocator);
        self.* = undefined;
    }

    /// Lazily proves and follows every plan state reached by one exact range.
    /// The first ambiguity permanently marks this builder ineligible so callers
    /// can fall back without confusing ambiguity with no-match.
    pub fn capturesExact(
        self: *Matcher,
        input: []const u8,
        range_start: usize,
        range_end: usize,
    ) (error{ InvalidRange, OutOfMemory, Ineligible })!?match_types.CaptureView {
        if (range_start > range_end or range_end > input.len) return error.InvalidRange;
        if (!self.eligible) return error.Ineligible;
        return runExact(self, input, range_start, range_end) catch |err| {
            if (err == error.Ineligible) self.eligible = false;
            return err;
        };
    }

    pub fn isEligible(self: *const Matcher) bool {
        return self.eligible;
    }

    /// Supplies the common executor with a state, building and proving it on
    /// first reach in the owning direct form.
    fn executionPlan(self: *Matcher, state: u32) error{ OutOfMemory, Ineligible }!*PlanState {
        return self.buildPlan(state);
    }

    /// Closes one root and proves deterministic identity. Reaching an item with
    /// different accumulated actions/end-only state, overlapping byte routes, or
    /// incompatible accepting actions makes the Program ineligible.
    fn buildPlan(self: *Matcher, start: u32) (error{ OutOfMemory, Ineligible })!*PlanState {
        const index = start;
        if (self.plans[index]) |existing| return existing;
        if (!self.owns_plans) return error.Ineligible;

        const state = try self.allocator.create(PlanState);
        errdefer self.allocator.destroy(state);
        const routes = try self.allocator.alloc(Route, self.prog.byte_class_count);
        errdefer self.allocator.free(routes);
        @memset(routes, .{});
        state.* = .{ .routes = routes, .end_actions = 0, .accepts_end = false };

        @memset(self.seen, false);
        @memset(self.seen_actions, 0);
        @memset(self.seen_end_only, false);
        self.work.clearRetainingCapacity();
        try self.work.append(self.allocator, .{
            .root = start,
            .index = 0,
            .actions = 0,
            .end_only = false,
        });
        while (self.work.pop()) |work| {
            const list = self.prog.priority_lists.lists[work.root];
            var item_index = work.index;
            while (item_index < list.len) : (item_index += 1) {
                const item_id = list.offset + item_index;
                if (self.seen[item_id]) {
                    if (self.seen_actions[item_id] != work.actions or
                        self.seen_end_only[item_id] != work.end_only) return error.Ineligible;
                    break;
                }
                self.seen[item_id] = true;
                self.seen_actions[item_id] = work.actions;
                self.seen_end_only[item_id] = work.end_only;
                const item = self.prog.priority_lists.items[item_id];
                if (item.isRoot()) {
                    if (item_index + 1 < list.len)
                        try self.push(work.root, item_index + 1, work.actions, work.end_only);
                    try self.push(item.root(), 0, work.actions, work.end_only);
                    break;
                }
                const instruction = self.prog.runtimeInstruction(item);
                switch (instruction.opcode()) {
                    .fail => {},
                    .empty_width => {
                        const mask = instruction.emptyMask();
                        const bits: u32 = @bitCast(mask);
                        const proven_start = @popCount(bits) == 1 and
                            ((mask.begin_line and self.prog.anchor_line_start) or
                                (mask.begin_text and self.prog.anchor_start));
                        if (proven_start) {
                            if (item_index + 1 < list.len) try self.push(
                                work.root,
                                item_index + 1,
                                work.actions,
                                work.end_only,
                            );
                            try self.push(
                                self.prog.instructionSuccessor(instruction),
                                0,
                                work.actions,
                                work.end_only,
                            );
                            break;
                        }
                        if (!mask.end_text or @popCount(bits) != 1)
                            return error.Ineligible;
                        if (item_index + 1 < list.len) try self.push(
                            work.root,
                            item_index + 1,
                            work.actions,
                            work.end_only,
                        );
                        try self.push(
                            self.prog.instructionSuccessor(instruction),
                            0,
                            work.actions,
                            true,
                        );
                        break;
                    },
                    .capture => {
                        const slot = @intFromEnum(instruction.captureSlot());
                        if (slot >= capture_slot_limit) return error.Ineligible;
                        const actions = work.actions |
                            (@as(CaptureMask, 1) << @intCast(slot));
                        if (item_index + 1 < list.len) try self.push(
                            work.root,
                            item_index + 1,
                            work.actions,
                            work.end_only,
                        );
                        try self.push(
                            self.prog.instructionSuccessor(instruction),
                            0,
                            actions,
                            work.end_only,
                        );
                        break;
                    },
                    .byte_range => {
                        if (work.end_only) continue;
                        const destination = self.prog.instructionSuccessor(instruction);
                        var previous_class: ?u8 = null;
                        var previous_folded_class: ?u8 = null;
                        var byte: u16 = instruction.byteLo();
                        while (byte <= instruction.byteHi()) : (byte += 1) {
                            const compared: u8 = @intCast(byte);
                            const class = self.prog.byteClasses()[compared];
                            if (previous_class != class) {
                                previous_class = class;
                                try assignRoute(
                                    &state.routes[class],
                                    destination,
                                    work.actions,
                                );
                            }
                            if (instruction.foldsAscii() and
                                compared >= 'a' and compared <= 'z')
                            {
                                const folded_class = self.prog.byteClasses()[compared - ('a' - 'A')];
                                if (folded_class != class and
                                    previous_folded_class != folded_class)
                                {
                                    previous_folded_class = folded_class;
                                    try assignRoute(
                                        &state.routes[folded_class],
                                        destination,
                                        work.actions,
                                    );
                                }
                            }
                        }
                    },
                    .match => {
                        if (state.accepts_end) return error.Ineligible;
                        state.accepts_end = true;
                        state.end_actions = work.actions;
                    },
                    .jump, .split => unreachable,
                }
            }
        }
        self.plans[index] = state;
        return state;
    }

    /// Schedules one closure continuation with its accumulated capture writes
    /// and endpoint-only restriction intact.
    fn push(
        self: *Matcher,
        root: u32,
        index: u32,
        actions: CaptureMask,
        end_only: bool,
    ) error{OutOfMemory}!void {
        try self.work.append(self.allocator, .{
            .root = root,
            .index = index,
            .actions = actions,
            .end_only = end_only,
        });
    }
};

/// Executes Executor or test Matcher through their common `executionPlan`
/// interface, consuming exactly `[range_start,range_end)`.
fn runExact(
    provider: anytype,
    input: []const u8,
    range_start: usize,
    range_end: usize,
) (error{ OutOfMemory, Ineligible })!?match_types.CaptureView {
    @memset(provider.slots, null);
    provider.slots[0] = range_start;
    var state = provider.prog.priority_lists.start_root;
    var position = range_start;

    while (true) {
        const plan = try provider.executionPlan(state);
        if (position == range_end) {
            if (!plan.accepts_end) return null;
            applyActions(provider.slots, plan.end_actions, position);
            provider.slots[1] = position;
            return .{ .slots = provider.slots };
        }
        const route = plan.routes[provider.prog.byteClasses()[input[position]]];
        if (!route.valid) return null;
        applyActions(provider.slots, route.actions, position);
        const source = state;
        state = route.destination;
        position += 1;
        if (route.actions == 0 and state == source) {
            while (position < range_end) {
                const repeated = plan.routes[provider.prog.byteClasses()[input[position]]];
                if (!repeated.valid or repeated.actions != 0 or
                    repeated.destination != source) break;
                position += 1;
            }
        }
    }
}

/// Writes the current absolute position to every slot selected by a compact mask.
fn applyActions(slots: []?usize, actions_value: CaptureMask, position: usize) void {
    var actions = actions_value;
    while (actions != 0) {
        const slot: u4 = @intCast(@ctz(actions));
        slots[slot] = position;
        actions &= actions - 1;
    }
}

/// Publishes a class route once; a second non-identical route proves ambiguity.
fn assignRoute(
    route: *Route,
    destination: u32,
    actions: CaptureMask,
) error{Ineligible}!void {
    if (route.valid) {
        if (route.destination == destination and route.actions == actions) return;
        return error.Ineligible;
    }
    route.* = .{ .destination = destination, .actions = actions, .valid = true };
}

const parser = @import("../../syntax/parser.zig");
const compiler = @import("../../program/compiler.zig");
const regexp = @import("../../syntax/regexp.zig");
const testing = std.testing;

fn compilePattern(pattern: []const u8) !struct { regexp.Regexp, program.Program } {
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
    const prog = try compiler.compile(testing.allocator, &tree, .{
        .encoding = .utf8,
        .max_instructions = 100_000,
    });
    return .{ tree, prog };
}

test "OnePass executes deterministic captures and rejects overlap" {
    var values = try compilePattern("(x+)(z)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.capturesExact("xxxz", 0, 4)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 3 }, view.group(1).?);
    try testing.expectEqual(match_types.Match{ .start = 3, .end = 4 }, view.group(2).?);

    var ambiguous_values = try compilePattern("((x|xx)*)z");
    defer ambiguous_values[0].deinit(testing.allocator);
    defer ambiguous_values[1].deinit(testing.allocator);
    var ambiguous = try Matcher.init(testing.allocator, &ambiguous_values[1]);
    defer ambiguous.deinit();
    try testing.expectError(error.Ineligible, ambiguous.capturesExact("xxxz", 0, 4));
}

fn allocationPlan(allocator: std.mem.Allocator, prog: *const program.Program) !void {
    var plan = try Plan.init(allocator, prog);
    plan.deinit();
}

test "Prepared OnePass plan is immutable across execution scratch" {
    var values = try compilePattern("(a+)(b)");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, allocationPlan, .{&values[1]});
    var plan = try Plan.init(testing.allocator, &values[1]);
    defer plan.deinit();
    var first = try Executor.init(testing.allocator, &values[1], &plan);
    defer first.deinit();
    var second = try Executor.init(testing.allocator, &values[1], &plan);
    defer second.deinit();
    try testing.expect(@sizeOf(Executor) < @sizeOf(Matcher));
    const a = (try first.capturesExact("aaab", 0, 4)).?;
    const b = (try second.capturesExact("ab", 0, 2)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 3 }, a.group(1).?);
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 1 }, b.group(1).?);
}

test "OnePass uses every bit in its capture action mask" {
    var eligible_values = try compilePattern("(a)(b)(c)(d)(e)(f)(g)");
    defer eligible_values[0].deinit(testing.allocator);
    defer eligible_values[1].deinit(testing.allocator);
    var eligible = try Matcher.init(testing.allocator, &eligible_values[1]);
    defer eligible.deinit();
    try testing.expect(eligible.isEligible());
    const captured = (try eligible.capturesExact("abcdefg", 0, 7)).?;
    try testing.expectEqual(match_types.Match{ .start = 6, .end = 7 }, captured.group(7).?);

    var declined_values = try compilePattern("(a)(b)(c)(d)(e)(f)(g)(h)");
    defer declined_values[0].deinit(testing.allocator);
    defer declined_values[1].deinit(testing.allocator);
    var declined = try Matcher.init(testing.allocator, &declined_values[1]);
    defer declined.deinit();
    try testing.expect(!declined.isEligible());
    try testing.expectError(error.Ineligible, declined.capturesExact("abcdefgh", 0, 8));
}

test "OnePass handles absolute end assertion on exact ranges" {
    var values = try compilePattern("([\\p{Greek}]+)$");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.capturesExact("αβγ", 0, "αβγ".len)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = "αβγ".len }, view.group(1).?);
}

test "OnePass handles optional and repeated final captures" {
    var values = try compilePattern("(a+)(b)?(c)*");
    defer values[0].deinit(testing.allocator);
    defer values[1].deinit(testing.allocator);
    var matcher = try Matcher.init(testing.allocator, &values[1]);
    defer matcher.deinit();
    const view = (try matcher.capturesExact("aaacc", 0, 5)).?;
    try testing.expectEqual(match_types.Match{ .start = 0, .end = 3 }, view.group(1).?);
    try testing.expect(view.group(2) == null);
    try testing.expectEqual(match_types.Match{ .start = 4, .end = 5 }, view.group(3).?);
}
