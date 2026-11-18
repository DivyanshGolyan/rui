const std = @import("std");
pub const enabled = @import("build_options").test_pauses;

pub const Point = enum {
    action_attempt_committed,
    action_before_handoff,
    action_result_ready,
    action_result_committed,
    model_preparation_advanced,
    model_before_handoff,
    model_result_ready,
    action_bash_exit_observed,
    host_shutdown_signalled,

    pub fn wireName(self: Point) []const u8 {
        return switch (self) {
            .action_attempt_committed => "action.attempt_committed",
            .action_before_handoff => "action.before_handoff",
            .action_result_ready => "action.result_ready",
            .action_result_committed => "action.result_committed",
            .model_preparation_advanced => "model.preparation_advanced",
            .model_before_handoff => "model.before_handoff",
            .model_result_ready => "model.result_ready",
            .action_bash_exit_observed => "action.bash_exit_observed",
            .host_shutdown_signalled => "host.shutdown_signalled",
        };
    }
};

// IDs are copied values, not references into the work being observed.
pub const Id = [32]u8;
pub const Context = struct {
    session: ?Id = null,
    request: ?Id = null,
    operation: ?u64 = null,
    action: ?u64 = null,
    attempt: ?u64 = null,
};
pub const Arrival = struct { id: u64, point: Point, context: Context, occurrence: u64 };
pub const FaultCode = enum { unavailable, failed };
pub const Fault = union(enum) { fail: FaultCode, short_write: usize, unknown_partial_write, disconnect, commit_outcome_unknown };
pub const Decision = union(enum) { proceed, fault: Fault };
// A selection declares its decision when armed, allowing validation before work starts.
pub const Selection = struct { point: Point, context: Context = .{}, occurrence: ?u64 = null, decision: Decision = .proceed };
pub const Poll = union(enum) { pending: Arrival, ready: Decision };
pub const Wake = struct { context: *anyopaque, call: *const fn (*anyopaque, u64) void };

fn matchesContext(filter: Context, actual: Context) bool {
    return (filter.session == null or std.meta.eql(filter.session, actual.session)) and
        (filter.request == null or std.meta.eql(filter.request, actual.request)) and
        (filter.operation == null or filter.operation == actual.operation) and
        (filter.action == null or filter.action == actual.action) and
        (filter.attempt == null or filter.attempt == actual.attempt);
}

fn contextsOverlap(a: Context, b: Context) bool {
    return (a.session == null or b.session == null or std.meta.eql(a.session, b.session)) and
        (a.request == null or b.request == null or std.meta.eql(a.request, b.request)) and
        (a.operation == null or b.operation == null or a.operation == b.operation) and
        (a.action == null or b.action == null or a.action == b.action) and
        (a.attempt == null or b.attempt == null or a.attempt == b.attempt);
}

// These first four points only describe observations. Effect-specific points must
// define their fault mapping before they can accept a fault.
fn validDecision(_: Point, decision: Decision) bool {
    return decision == .proceed;
}

pub const PauseController = if (enabled) EnabledController else DisabledController;

const DisabledController = struct {
    pub fn init(_: std.Io, _: std.mem.Allocator) DisabledController {
        return .{};
    }
    pub fn deinit(_: *DisabledController) void {}
    pub fn arm(_: *DisabledController, _: Selection) !void {
        return error.Disabled;
    }
    pub fn wait(_: *DisabledController, _: Selection) !Arrival {
        return error.Disabled;
    }
    pub fn inspect(_: *DisabledController, _: u64) !Arrival {
        return error.Disabled;
    }
    pub fn release(_: *DisabledController, _: u64, _: Decision) !void {
        return error.Disabled;
    }
    pub fn close(_: *DisabledController) void {}
    pub fn reach(_: *DisabledController, _: Point, _: Context) !Decision {
        return .proceed;
    }
    pub fn poll(_: *DisabledController, _: u64, _: Point, _: Context, _: Wake) !Poll {
        return .{ .ready = .proceed };
    }
};

const EnabledController = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    selections: std.ArrayList(Armed) = .empty,
    arrivals: std.ArrayList(Entry) = .empty,
    counts: std.ArrayList(Count) = .empty,
    next_id: u64 = 1,
    closed: bool = false,

    const Armed = struct { selection: Selection };
    const Count = struct { point: Point, context: Context, total: u64 };
    const Entry = struct {
        arrival: Arrival,
        expected: Decision,
        decision: ?Decision = null,
        observed: bool = false,
        consumed: bool = false,
        work: ?u64 = null,
        wake: ?Wake = null,
    };

    pub fn init(io: std.Io, allocator: std.mem.Allocator) EnabledController {
        return .{ .io = io, .allocator = allocator };
    }
    // Caller closes and joins all users before deinitializing the owner.
    pub fn deinit(self: *EnabledController) void {
        self.selections.deinit(self.allocator);
        self.arrivals.deinit(self.allocator);
        self.counts.deinit(self.allocator);
    }
    pub fn arm(self: *EnabledController, selection: Selection) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (!validDecision(selection.point, selection.decision)) return error.InvalidFault;
        // Overlapping filters are ambiguous unless they have identical contexts
        // and explicitly select different occurrences of that context.
        for (self.selections.items) |armed| {
            const other = armed.selection;
            if (other.point != selection.point or !contextsOverlap(other.context, selection.context)) continue;
            if (std.meta.eql(other.context, selection.context) and other.occurrence != null and
                selection.occurrence != null and other.occurrence.? != selection.occurrence.?) continue;
            return error.AlreadyArmed;
        }
        if (selection.occurrence) |occurrence| {
            if (occurrence <= try self.count(selection.point, selection.context)) return error.OccurrencePassed;
        }
        try self.selections.append(self.allocator, .{ .selection = selection });
    }
    // Store counts by actual context so a filter first armed later can count
    // all prior matching arrivals, including those without any selection.
    fn count(self: *EnabledController, point: Point, filter: Context) !u64 {
        var total: u64 = 0;
        for (self.counts.items) |entry| {
            if (entry.point == point and matchesContext(filter, entry.context))
                total = std.math.add(u64, total, entry.total) catch return error.Exhausted;
        }
        return total;
    }
    fn register(self: *EnabledController, point: Point, context: Context, work: ?u64, wake: ?Wake) !?usize {
        if (self.closed) return error.Closed;
        var found = false;
        for (self.counts.items) |*entry| {
            if (entry.point == point and std.meta.eql(entry.context, context)) {
                entry.total = std.math.add(u64, entry.total, 1) catch return error.Exhausted;
                found = true;
                break;
            }
        }
        if (!found) try self.counts.append(self.allocator, .{ .point = point, .context = context, .total = 1 });
        for (self.selections.items) |armed| {
            const selection = armed.selection;
            if (selection.point != point or !matchesContext(selection.context, context)) continue;
            const occurrence = try self.count(point, selection.context);
            if (selection.occurrence != null and selection.occurrence.? != occurrence) continue;
            const id = self.next_id;
            const next_id = std.math.add(u64, id, 1) catch return error.Exhausted;
            try self.arrivals.append(self.allocator, .{
                .arrival = .{ .id = id, .point = point, .context = context, .occurrence = occurrence },
                .expected = selection.decision,
                .work = work,
                .wake = wake,
            });
            self.next_id = next_id;
            self.changed.broadcast(self.io);
            return self.arrivals.items.len - 1;
        }
        return null;
    }
    pub fn wait(self: *EnabledController, selection: Selection) !Arrival {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            for (self.arrivals.items) |*entry| {
                const a = entry.arrival;
                if (!entry.observed and a.point == selection.point and matchesContext(selection.context, a.context) and
                    (selection.occurrence == null or selection.occurrence.? == a.occurrence))
                {
                    entry.observed = true;
                    return a;
                }
            }
            if (self.closed) return error.Closed;
            self.changed.waitUncancelable(self.io, &self.mutex);
        }
    }
    pub fn inspect(self: *EnabledController, id: u64) !Arrival {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.arrivals.items) |entry| if (entry.arrival.id == id) return entry.arrival;
        return error.UnknownArrival;
    }
    pub fn release(self: *EnabledController, id: u64, decision: Decision) !void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return error.Closed;
        }
        for (self.arrivals.items) |*entry| {
            if (entry.arrival.id != id) continue;
            if (entry.decision != null) {
                self.mutex.unlock(self.io);
                return error.AlreadyReleased;
            }
            if (!std.meta.eql(entry.expected, decision)) {
                self.mutex.unlock(self.io);
                return error.InvalidDecision;
            }
            entry.decision = decision;
            const wake = entry.wake;
            entry.wake = null;
            const work = entry.work;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
            if (wake) |w| w.call(w.context, work.?);
            return;
        }
        self.mutex.unlock(self.io);
        return error.UnknownArrival;
    }
    pub fn close(self: *EnabledController) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        self.changed.broadcast(self.io);
        // Detach each callback under the lock, but call it unlocked so a
        // scheduler can safely poll again from its wake function.
        var i: usize = 0;
        while (i < self.arrivals.items.len) : (i += 1) {
            const entry = &self.arrivals.items[i];
            const wake = if (!entry.consumed) entry.wake else null;
            const work = entry.work;
            entry.wake = null;
            if (wake) |w| {
                self.mutex.unlock(self.io);
                w.call(w.context, work.?);
                self.mutex.lockUncancelable(self.io);
            }
        }
        self.mutex.unlock(self.io);
    }
    pub fn reach(self: *EnabledController, point: Point, context: Context) !Decision {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const i = (try self.register(point, context, null, null)) orelse return .proceed;
        while (self.arrivals.items[i].decision == null and !self.closed)
            self.changed.waitUncancelable(self.io, &self.mutex);
        if (self.closed) return error.Closed;
        self.arrivals.items[i].consumed = true;
        return self.arrivals.items[i].decision.?;
    }
    // Wake must schedule a level-triggered or latched continuation: release may
    // call it before this poll returns. It must not discard an early wake.
    // Each work ID is unique for the lifetime of this owner. A consumed ID is
    // retained so a repeated poll cannot accidentally create a second arrival.
    pub fn poll(self: *EnabledController, work: u64, point: Point, context: Context, wake: Wake) !Poll {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        for (self.arrivals.items) |*entry| if (entry.work != null and entry.work.? == work) {
            if (entry.arrival.point != point or !std.meta.eql(entry.arrival.context, context)) return error.WorkIdentityMismatch;
            if (entry.consumed) return error.AlreadyConsumed;
            if (entry.decision) |decision| {
                entry.consumed = true;
                return .{ .ready = decision };
            }
            return .{ .pending = entry.arrival };
        };
        const i = (try self.register(point, context, work, wake)) orelse return .{ .ready = .proceed };
        return .{ .pending = self.arrivals.items[i].arrival };
    }
};

pub fn reach(owner: *PauseController, point: Point, context: Context) !Decision {
    return owner.reach(point, context);
}
pub fn poll(owner: *PauseController, work: u64, point: Point, context: Context, wake: Wake) !Poll {
    return owner.poll(work, point, context, wake);
}

test "pause PAU-1 owner is zero sized when disabled" {
    try std.testing.expect(@sizeOf(DisabledController) == 0);
    if (!enabled) try std.testing.expect(@sizeOf(PauseController) == 0);
}

const TestWorker = struct {
    owner: *EnabledController,
    context: Context = .{},
    result: ?anyerror = null,
    fn run(self: *TestWorker) void {
        _ = self.owner.reach(.action_before_handoff, self.context) catch |err| {
            self.result = err;
            return;
        };
    }
};

test "pause PAU-2 arrival before wait is retained" {
    var owner = EnabledController.init(std.testing.io, std.testing.allocator);
    defer owner.deinit();
    defer owner.close();
    try owner.arm(.{ .point = .action_result_ready });
    var wakes: usize = 0;
    const wake: Wake = .{ .context = &wakes, .call = struct {
        fn call(ctx: *anyopaque, _: u64) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.call };
    const arrived = try owner.poll(1, .action_result_ready, .{}, wake);
    try std.testing.expect(arrived == .pending);
    const observed = try owner.wait(.{ .point = .action_result_ready });
    try std.testing.expectEqualDeep(arrived.pending, observed);
    try owner.release(observed.id, .proceed);
    try std.testing.expect((try owner.poll(1, .action_result_ready, .{}, wake)) == .ready);
}

test "pause PAU-3 concurrent arrivals have distinct ids and release independently" {
    var owner = EnabledController.init(std.testing.io, std.testing.allocator);
    defer owner.deinit();
    try owner.arm(.{ .point = .action_before_handoff });
    var a: TestWorker = .{ .owner = &owner, .context = .{ .action = 1 } };
    var b: TestWorker = .{ .owner = &owner, .context = .{ .action = 2 } };
    const ta = try std.Thread.spawn(.{}, TestWorker.run, .{&a});
    const tb = std.Thread.spawn(.{}, TestWorker.run, .{&b}) catch |err| {
        owner.close();
        ta.join();
        return err;
    };
    var joined_a = false;
    var joined_b = false;
    defer {
        owner.close();
        if (!joined_a) ta.join();
        if (!joined_b) tb.join();
    }
    const aa = try owner.wait(.{ .point = .action_before_handoff, .context = a.context });
    const bb = try owner.wait(.{ .point = .action_before_handoff, .context = b.context });
    try std.testing.expect(aa.id != bb.id);
    try std.testing.expectEqualDeep(aa, try owner.inspect(aa.id));
    try owner.release(bb.id, .proceed);
    try std.testing.expectError(error.AlreadyReleased, owner.release(bb.id, .proceed));
    tb.join();
    joined_b = true;
    try std.testing.expectEqual(@as(?anyerror, null), b.result);
    try owner.release(aa.id, .proceed);
    ta.join();
    joined_a = true;
    try std.testing.expectEqual(@as(?anyerror, null), a.result);

    // Also observe that releasing one arrival leaves another pending.
    var wakes: usize = 0;
    const wake: Wake = .{ .context = &wakes, .call = struct {
        fn call(ctx: *anyopaque, _: u64) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.call };
    const first = try owner.poll(1, .action_before_handoff, .{}, wake);
    const second = try owner.poll(2, .action_before_handoff, .{}, wake);
    try owner.release(first.pending.id, .proceed);
    try std.testing.expect((try owner.poll(2, .action_before_handoff, .{}, wake)) == .pending);
    try owner.release(second.pending.id, .proceed);
    try std.testing.expect((try owner.poll(1, .action_before_handoff, .{}, wake)) == .ready);
    try std.testing.expect((try owner.poll(2, .action_before_handoff, .{}, wake)) == .ready);
}

test "pause PAU-7 selections count matching contexts independently" {
    const point: Point = .action_result_ready;
    const Case = struct { first: u64, second: u64, between: bool, disjoint: bool };
    const cases = [_]Case{
        .{ .first = 1, .second = 2, .between = false, .disjoint = false },
        .{ .first = 2, .second = 1, .between = false, .disjoint = false },
        .{ .first = 1, .second = 2, .between = true, .disjoint = false },
        .{ .first = 2, .second = 1, .between = true, .disjoint = false },
        .{ .first = 1, .second = 2, .between = false, .disjoint = true },
        .{ .first = 2, .second = 1, .between = false, .disjoint = true },
        .{ .first = 1, .second = 2, .between = true, .disjoint = true },
        .{ .first = 2, .second = 1, .between = true, .disjoint = true },
    };
    for (cases) |case| {
        var owner = EnabledController.init(std.testing.io, std.testing.allocator);
        defer owner.deinit();
        defer owner.close();
        const a: Context = .{ .action = 1 };
        const b: Context = if (case.disjoint) .{ .action = 2 } else a;
        const first: Selection = .{ .point = point, .context = a, .occurrence = case.first };
        const second: Selection = .{ .point = point, .context = b, .occurrence = case.second };
        var wakes: usize = 0;
        const wake: Wake = .{ .context = &wakes, .call = struct {
            fn call(ctx: *anyopaque, _: u64) void {
                const n: *usize = @ptrCast(@alignCast(ctx));
                n.* += 1;
            }
        }.call };
        try owner.arm(first);
        if (!case.between) try owner.arm(second);
        try std.testing.expectError(error.AlreadyArmed, owner.arm(.{ .point = point }));
        var work: u64 = 1;
        for (0..2) |step| {
            if (step == 1 and case.between) {
                if (case.second == 1) {
                    try std.testing.expectError(error.OccurrencePassed, owner.arm(second));
                } else try owner.arm(second);
            }
            for (if (case.disjoint) &[_]Context{ a, b } else &[_]Context{a}) |context| {
                const occurrence: u64 = @intCast(step + 1);
                const selected = (std.meta.eql(context, a) and case.first == occurrence) or
                    ((!case.between or step == 1) and std.meta.eql(context, b) and case.second == occurrence);
                const result = try owner.poll(work, point, context, wake);
                if (selected) {
                    try std.testing.expect(result == .pending);
                    try std.testing.expectEqual(occurrence, result.pending.occurrence);
                    try owner.release(result.pending.id, .proceed);
                    try std.testing.expect((try owner.poll(work, point, context, wake)) == .ready);
                } else try std.testing.expect(result == .ready);
                work += 1;
            }
        }
        try std.testing.expectError(error.OccurrencePassed, owner.arm(.{ .point = point, .context = .{ .action = 3 }, .occurrence = 0 }));
    }
    // A filter first armed after several different actual contexts counts all
    // prior matches, including arrivals at a point with no armed selections.
    var owner = EnabledController.init(std.testing.io, std.testing.allocator);
    defer owner.deinit();
    defer owner.close();
    _ = try owner.reach(point, .{ .action = 1 });
    _ = try owner.reach(point, .{ .action = 2 });
    _ = try owner.reach(.action_attempt_committed, .{ .action = 3 });
    try std.testing.expectError(error.OccurrencePassed, owner.arm(.{ .point = point, .occurrence = 2 }));
    try owner.arm(.{ .point = point, .occurrence = 3 });
    var wakes: usize = 0;
    const wake: Wake = .{ .context = &wakes, .call = struct {
        fn call(_: *anyopaque, _: u64) void {}
    }.call };
    const result = try owner.poll(1, point, .{ .action = 3 }, wake);
    try std.testing.expect(result == .pending);
    try std.testing.expectEqual(@as(u64, 3), result.pending.occurrence);
    try owner.release(result.pending.id, .proceed);
}

test "pause PAU-4 poll remains pending until release and consumes once" {
    var owner = EnabledController.init(std.testing.io, std.testing.allocator);
    defer owner.deinit();
    defer owner.close();
    try owner.arm(.{ .point = .action_result_ready });
    var wakes: usize = 0;
    const wake: Wake = .{ .context = &wakes, .call = struct {
        fn call(ctx: *anyopaque, _: u64) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.call };
    const first = try owner.poll(7, .action_result_ready, .{}, wake);
    try std.testing.expect(first == .pending);
    const second = try owner.poll(7, .action_result_ready, .{}, wake);
    try std.testing.expectEqual(first.pending.id, second.pending.id);
    try owner.release(first.pending.id, .proceed);
    try std.testing.expectEqual(@as(usize, 1), wakes);
    try std.testing.expect((try owner.poll(7, .action_result_ready, .{}, wake)) == .ready);
    try std.testing.expectError(error.AlreadyConsumed, owner.poll(7, .action_result_ready, .{}, wake));
}

test "pause PAU-5 rejects unsupported faults before arming" {
    var owner = EnabledController.init(std.testing.io, std.testing.allocator);
    defer owner.deinit();
    for (std.enums.values(Point)) |point| {
        const faults = [_]Fault{ .{ .fail = .unavailable }, .{ .fail = .failed }, .{ .short_write = 1 }, .unknown_partial_write, .disconnect, .commit_outcome_unknown };
        for (faults) |fault| try std.testing.expectError(error.InvalidFault, owner.arm(.{ .point = point, .decision = .{ .fault = fault } }));
        try owner.arm(.{ .point = point });
    }
}

test "pause PAU-6 close releases parked workers with closed" {
    var owner = EnabledController.init(std.testing.io, std.testing.allocator);
    defer owner.deinit();
    try owner.arm(.{ .point = .action_before_handoff });
    var worker: TestWorker = .{ .owner = &owner };
    const thread = try std.Thread.spawn(.{}, TestWorker.run, .{&worker});
    var joined = false;
    defer {
        owner.close();
        if (!joined) thread.join();
    }
    _ = try owner.wait(.{ .point = .action_before_handoff });
    owner.close();
    thread.join();
    joined = true;
    try std.testing.expectEqual(error.Closed, worker.result.?);
}
