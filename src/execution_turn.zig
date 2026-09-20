const std = @import("std");

pub const Allowance = struct {
    bytes: usize,
    items: usize,
};

pub const Next = enum { again, wait };
pub const Admission = enum { no_work, retry_later, admitted };

/// These are the execution owner's existing scheduling facts, not another
/// queue or a copy of Store state. Store still selects and admits work inside
/// its own transactions. One State lives for one executionMain invocation.
pub const State = struct {
    last_retry_poll_ns: ?u64 = null,
    capacity_was_full: bool = false,
    controls: ControlPoll = .{},
};

/// One production turn. The driver supplies observations and executes the
/// existing owner operations; all turn ordering and admission scheduling live
/// here. No native handle moves across this boundary.
/// Keep calls on the left of `or`: progress must not skip later work.
pub fn run(state: *State, driver: anytype, allowance: Allowance) !Next {
    var made_progress = serviceLifecycle(state, driver);
    made_progress = (try admit(state, driver)) or made_progress;
    made_progress = serviceLifecycle(state, driver) or made_progress;
    state.capacity_was_full = driver.freeSlots() == 0;
    try driver.driveTransport();
    if (try driver.nextCompletion()) |completion| {
        driver.complete(completion);
        made_progress = true;
    }
    made_progress = serviceLifecycle(state, driver) or made_progress;
    made_progress = driver.advancePreparation(allowance) or made_progress;
    // A hint or ready completion may arrive during the last bounded unit.
    // Read readiness at the wait boundary, not only at the start of the turn.
    const ready = try driver.immediatelyRunnable();
    return if (made_progress or ready) .again else .wait;
}

/// A lifecycle opportunity invokes the real owners, rather than just emitting
/// a trace. Bash samples time inside each native owner's service call. Cleanup
/// samples again after reconciliation and Bash work; the boundary timestamp
/// must not masquerade as current time after potentially blocking operations.
pub fn serviceLifecycle(state: *State, driver: anytype) bool {
    const now_ns = driver.now();
    driver.observeLifecycle(now_ns);
    const hint = driver.takeControlHint();
    var made_progress = false;
    if (state.controls.due(now_ns, hint)) {
        made_progress = driver.reconcileControls() or hint;
    }
    made_progress = driver.prepareBash() or made_progress;
    made_progress = driver.serviceBash() or made_progress;
    made_progress = driver.cleanup(driver.now()) or made_progress;
    return made_progress;
}

fn admit(state: *State, driver: anytype) !bool {
    const now_ns = driver.now();
    var free_slots = driver.freeSlots();
    const capacity_released = state.capacity_was_full and free_slots != 0;
    const retry_poll_due = if (state.last_retry_poll_ns) |last|
        now_ns -| last >= std.time.ns_per_s
    else
        true;
    if (driver.dispatchFenced()) return false;

    var made_progress = try driver.recoverAction();
    if (free_slots != 0 and !driver.bashPreparing()) {
        if (driver.admitBash() == .admitted) made_progress = true;
        free_slots = driver.freeSlots();
    }
    const maintain_retries = driver.providerEnabled() and (retry_poll_due or capacity_released);
    var may_admit_new = !maintain_retries;
    if (maintain_retries) {
        if (try driver.recoverExhaustedModel()) {
            made_progress = true;
            state.last_retry_poll_ns = null;
        } else {
            state.last_retry_poll_ns = now_ns;
        }
        if (free_slots != 0 and !driver.modelPreparing()) {
            switch (driver.admitRetry()) {
                .admitted => {
                    made_progress = true;
                    state.last_retry_poll_ns = null;
                },
                .no_work => may_admit_new = true,
                .retry_later => state.last_retry_poll_ns = null,
            }
        }
    }
    if (driver.providerEnabled() and may_admit_new and !driver.modelPreparing() and
        driver.freeSlots() != 0)
    {
        if (driver.admitNew() == .admitted) made_progress = true;
    }
    return made_progress;
}

/// Notifications accelerate reconciliation; committed facts remain authority.
pub const ControlPoll = struct {
    pub const interval_ns: u64 = 100 * std.time.ns_per_ms;

    next_ns: ?u64 = null,

    pub fn due(self: *ControlPoll, now_ns: u64, hint: bool) bool {
        if (!hint) {
            if (self.next_ns) |next| {
                if (now_ns < next) return false;
            }
        }
        self.next_ns = now_ns +| interval_ns;
        return true;
    }
};

// Script only external observations and owner-operation outcomes. In
// particular, this driver contains no admission policy, encoder, Store model,
// Bash supervisor or cleanup state machine. Native owner tests live beside
// server/execution/named_scratch and exercise those actual owners directly.
const TestDriver = struct {
    const Failure = enum { action_recovery, model_recovery, transport, completion, readiness };

    events: [32]u8 = undefined,
    event_count: usize = 0,
    now_ns: u64 = 0,
    admission_elapsed_ns: u64 = 0,
    completion_elapsed_ns: u64 = 0,
    preparation_elapsed_ns: u64 = 0,
    bash_preparation_elapsed_ns: u64 = 0,
    lifecycle_times: [3]u64 = @splat(0),
    bash_service_times: [3]u64 = @splat(0),
    cleanup_times: [3]u64 = @splat(0),
    lifecycle_calls: usize = 0,
    bash_service_calls: usize = 0,
    cleanup_calls: usize = 0,
    control_hint: bool = false,
    reconcile_progress: bool = false,
    reconciliations: usize = 0,
    bash_progress: bool = false,
    cleanup_progress: bool = false,
    ready: bool = false,
    ready_after_preparation: bool = false,
    free_slots: usize = 2,
    released_capacity: usize = 0,
    fenced: bool = false,
    provider_enabled: bool = true,
    bash_preparing: bool = false,
    model_preparing: bool = false,
    recovered_action: bool = false,
    recovered_model: bool = false,
    bash_admission: Admission = .no_work,
    retry_admission: Admission = .no_work,
    new_admission: Admission = .no_work,
    action_recovery_calls: usize = 0,
    model_recovery_calls: usize = 0,
    bash_admission_calls: usize = 0,
    retry_admission_calls: usize = 0,
    new_admission_calls: usize = 0,
    completions_remaining: usize = 0,
    preparation_steps_remaining: usize = 0,
    completions_removed: usize = 0,
    completions_settled: usize = 0,
    preparation_calls: usize = 0,
    last_allowance: ?Allowance = null,
    failure: ?Failure = null,

    fn event(self: *TestDriver, value: u8) void {
        if (self.event_count < self.events.len) self.events[self.event_count] = value;
        self.event_count += 1;
    }

    pub fn now(self: *TestDriver) u64 {
        return self.now_ns;
    }

    pub fn observeLifecycle(self: *TestDriver, now_ns: u64) void {
        self.event('L');
        self.lifecycle_times[self.lifecycle_calls % 3] = now_ns;
        self.lifecycle_calls += 1;
    }

    pub fn takeControlHint(self: *TestDriver) bool {
        const hint = self.control_hint;
        self.control_hint = false;
        return hint;
    }

    pub fn reconcileControls(self: *TestDriver) bool {
        self.reconciliations += 1;
        const progress = self.reconcile_progress;
        self.reconcile_progress = false;
        return progress;
    }

    pub fn prepareBash(self: *TestDriver) bool {
        self.now_ns += self.bash_preparation_elapsed_ns;
        return false;
    }

    pub fn serviceBash(self: *TestDriver) bool {
        self.bash_service_times[self.bash_service_calls % 3] = self.now();
        self.bash_service_calls += 1;
        return self.bash_progress;
    }

    pub fn cleanup(self: *TestDriver, now_ns: u64) bool {
        self.cleanup_times[self.cleanup_calls % 3] = now_ns;
        self.cleanup_calls += 1;
        const released = self.released_capacity;
        self.released_capacity = 0;
        self.free_slots += released;
        return released != 0 or self.cleanup_progress;
    }

    pub fn freeSlots(self: *TestDriver) usize {
        return self.free_slots;
    }

    pub fn dispatchFenced(self: *TestDriver) bool {
        return self.fenced;
    }

    pub fn providerEnabled(self: *TestDriver) bool {
        return self.provider_enabled;
    }

    pub fn bashPreparing(self: *TestDriver) bool {
        return self.bash_preparing;
    }

    pub fn modelPreparing(self: *TestDriver) bool {
        return self.model_preparing;
    }

    pub fn recoverAction(self: *TestDriver) !bool {
        self.event('A');
        self.action_recovery_calls += 1;
        if (self.failure == .action_recovery) return error.InjectedActionRecoveryFailure;
        return self.recovered_action;
    }

    pub fn recoverExhaustedModel(self: *TestDriver) !bool {
        self.model_recovery_calls += 1;
        if (self.failure == .model_recovery) return error.InjectedModelRecoveryFailure;
        return self.recovered_model;
    }

    pub fn admitBash(self: *TestDriver) Admission {
        self.bash_admission_calls += 1;
        if (self.bash_admission == .admitted) {
            self.free_slots -= 1;
            self.bash_preparing = true;
        }
        return self.bash_admission;
    }

    pub fn admitRetry(self: *TestDriver) Admission {
        self.retry_admission_calls += 1;
        if (self.retry_admission == .admitted) {
            self.free_slots -= 1;
            self.model_preparing = true;
        }
        return self.retry_admission;
    }

    pub fn admitNew(self: *TestDriver) Admission {
        self.new_admission_calls += 1;
        self.now_ns += self.admission_elapsed_ns;
        if (self.new_admission == .admitted) {
            self.free_slots -= 1;
            self.model_preparing = true;
        }
        return self.new_admission;
    }

    pub fn driveTransport(self: *TestDriver) !void {
        self.event('D');
        if (self.failure == .transport) return error.InjectedTransportFailure;
    }

    pub fn nextCompletion(self: *TestDriver) !?usize {
        self.event('N');
        if (self.failure == .completion) return error.InjectedCompletionFailure;
        if (self.completions_remaining == 0) return null;
        self.completions_remaining -= 1;
        self.completions_removed += 1;
        return self.completions_removed;
    }

    pub fn complete(self: *TestDriver, completion: usize) void {
        std.debug.assert(completion == self.completions_removed);
        self.event('C');
        self.completions_settled += 1;
        self.now_ns += self.completion_elapsed_ns;
    }

    pub fn advancePreparation(self: *TestDriver, allowance: Allowance) bool {
        self.event('P');
        self.preparation_calls += 1;
        self.last_allowance = allowance;
        self.now_ns += self.preparation_elapsed_ns;
        self.ready = self.ready or self.ready_after_preparation;
        if (self.preparation_steps_remaining == 0) return false;
        self.preparation_steps_remaining -= 1;
        return true;
    }

    pub fn immediatelyRunnable(self: *TestDriver) !bool {
        if (self.failure == .readiness) return error.InjectedReadinessFailure;
        return self.ready;
    }
};

const test_allowance = Allowance{ .bytes = 17, .items = 3 };

test "execution turn orders all boundaries and removes one completion" {
    var state: State = .{};
    var driver = TestDriver{ .completions_remaining = 2, .preparation_steps_remaining = 2 };
    try std.testing.expectEqual(Next.again, try run(&state, &driver, test_allowance));
    try std.testing.expectEqual(@as(usize, 8), driver.event_count);
    try std.testing.expectEqualStrings("LALDNCLP", driver.events[0..8]);
    try std.testing.expectEqual(@as(usize, 1), driver.completions_removed);
    try std.testing.expectEqual(@as(usize, 1), driver.completions_settled);
    try std.testing.expectEqual(@as(usize, 1), driver.completions_remaining);
    try std.testing.expectEqual(@as(usize, 1), driver.preparation_calls);
    try std.testing.expectEqual(@as(usize, 1), driver.preparation_steps_remaining);
    try std.testing.expectEqual(test_allowance.bytes, driver.last_allowance.?.bytes);
    try std.testing.expectEqual(test_allowance.items, driver.last_allowance.?.items);
}

test "execution turn never short circuits a lifecycle owner or later work" {
    for (0..128) |mask| {
        var state: State = .{};
        var driver = TestDriver{
            .reconcile_progress = mask & 1 != 0,
            .bash_progress = mask & 2 != 0,
            .cleanup_progress = mask & 4 != 0,
            .new_admission = if (mask & 8 != 0) .admitted else .no_work,
            .completions_remaining = if (mask & 16 != 0) 1 else 0,
            .preparation_steps_remaining = if (mask & 32 != 0) 1 else 0,
            .ready = mask & 64 != 0,
        };
        try std.testing.expectEqual(if (mask == 0) Next.wait else Next.again, try run(&state, &driver, test_allowance));
        try std.testing.expectEqual(@as(usize, 3), driver.lifecycle_calls);
        try std.testing.expectEqual(@as(usize, 3), driver.bash_service_calls);
        try std.testing.expectEqual(@as(usize, 3), driver.cleanup_calls);
        try std.testing.expectEqual(@as(usize, 1), driver.preparation_calls);
        const expected = if (mask & 16 != 0) "LALDNCLP" else "LALDNLP";
        try std.testing.expectEqual(expected.len, driver.event_count);
        try std.testing.expectEqualStrings(expected, driver.events[0..expected.len]);
    }
}

test "execution turn drains finite independent completion and preparation populations without waiting" {
    const sizes = [_]usize{ 0, 1, 2, 31, 256, 4096 };
    for (sizes) |completions| {
        for (sizes) |steps| {
            var state: State = .{};
            var driver = TestDriver{ .completions_remaining = completions, .preparation_steps_remaining = steps };
            for (0..@max(completions, steps)) |index| {
                driver.event_count = 0;
                const removed = driver.completions_removed;
                const settled = driver.completions_settled;
                const preparation_calls = driver.preparation_calls;
                try std.testing.expectEqual(Next.again, try run(&state, &driver, test_allowance));
                const expected: usize = if (index < completions) 1 else 0;
                try std.testing.expectEqual(expected, driver.completions_removed - removed);
                try std.testing.expectEqual(expected, driver.completions_settled - settled);
                try std.testing.expectEqual(@as(usize, 1), driver.preparation_calls - preparation_calls);
                try std.testing.expectEqual(3 * (index + 1), driver.lifecycle_calls);
            }
            driver.event_count = 0;
            try std.testing.expectEqual(Next.wait, try run(&state, &driver, test_allowance));
            try std.testing.expectEqual(completions, driver.completions_settled);
            try std.testing.expectEqual(@as(usize, 0), driver.preparation_steps_remaining);
        }
    }
}

test "execution turn samples service time again after each bounded or atomic unit" {
    var state: State = .{};
    var driver = TestDriver{
        .completions_remaining = 1,
        .admission_elapsed_ns = 200,
        .completion_elapsed_ns = 400,
        .preparation_elapsed_ns = 800,
        .bash_preparation_elapsed_ns = 10,
    };
    _ = try run(&state, &driver, test_allowance);
    try std.testing.expectEqual([3]u64{ 0, 210, 620 }, driver.lifecycle_times);
    try std.testing.expectEqual([3]u64{ 10, 220, 630 }, driver.bash_service_times);
    try std.testing.expectEqual([3]u64{ 10, 220, 630 }, driver.cleanup_times);
    // Preparation is the last bounded unit. Its next service opportunity is
    // the first boundary of the following turn, with a new observation.
    driver.event_count = 0;
    _ = try run(&state, &driver, test_allowance);
    try std.testing.expectEqual(@as(u64, 1430), driver.lifecycle_times[0]);
    try std.testing.expectEqual(@as(u64, 1440), driver.bash_service_times[0]);
    // Deadlines at 215 and 1000 are visible at the next Bash service, not at
    // the earlier boundary samples 210 and 620. Signal/reap semantics belong
    // to the actual Bash owner and its focused native tests.
    try std.testing.expect(driver.bash_service_times[0] >= 1000);
}

test "execution turn discovers a lost control hint at the fallback boundary" {
    var state: State = .{};
    var driver: TestDriver = .{};
    try std.testing.expect(!serviceLifecycle(&state, &driver));
    try std.testing.expectEqual(@as(usize, 1), driver.reconciliations);
    driver.reconcile_progress = true; // The next canonical reconciliation changes an owner.
    driver.now_ns = ControlPoll.interval_ns - 1;
    try std.testing.expect(!serviceLifecycle(&state, &driver));
    try std.testing.expectEqual(@as(usize, 1), driver.reconciliations);
    driver.now_ns += 1;
    try std.testing.expect(serviceLifecycle(&state, &driver));
    try std.testing.expectEqual(@as(usize, 2), driver.reconciliations);
    try std.testing.expect(!driver.control_hint);
    driver.control_hint = true;
    try std.testing.expect(serviceLifecycle(&state, &driver));
    try std.testing.expectEqual(@as(usize, 3), driver.reconciliations);
}

test "execution turn control polling handles exact deadlines and elapsed jumps" {
    var poll: ControlPoll = .{};
    try std.testing.expect(poll.due(0, false));
    for (1..100) |tick| try std.testing.expect(!poll.due(tick * std.time.ns_per_ms, false));
    try std.testing.expect(poll.due(ControlPoll.interval_ns, false));
    try std.testing.expect(!poll.due(ControlPoll.interval_ns, false));
    try std.testing.expect(poll.due(ControlPoll.interval_ns + 1, true));
    try std.testing.expect(!poll.due(2 * ControlPoll.interval_ns, false));
    try std.testing.expect(poll.due(2 * ControlPoll.interval_ns + 1, false));
    try std.testing.expect(poll.due(100 * ControlPoll.interval_ns, false));
}

test "execution turn rechecks ready work immediately before selecting a wait" {
    var state: State = .{};
    var driver = TestDriver{ .ready_after_preparation = true };
    try std.testing.expectEqual(Next.again, try run(&state, &driver, test_allowance));
    try std.testing.expectEqual(@as(usize, 0), driver.completions_settled);
    driver.ready = false;
    driver.ready_after_preparation = false;
    driver.event_count = 0;
    try std.testing.expectEqual(Next.wait, try run(&state, &driver, test_allowance));
}

test "execution admission observes capacity release and gives due retries their existing precedence" {
    for ([_]Admission{ .no_work, .retry_later, .admitted }) |retry| {
        var state = State{ .last_retry_poll_ns = 0, .capacity_was_full = true };
        var driver = TestDriver{ .now_ns = 1, .free_slots = 0, .released_capacity = 1, .retry_admission = retry };
        _ = try run(&state, &driver, test_allowance);
        try std.testing.expectEqual(@as(usize, 1), driver.retry_admission_calls);
        try std.testing.expectEqual(@as(usize, if (retry == .no_work) 1 else 0), driver.new_admission_calls);
        if (retry == .no_work) {
            try std.testing.expectEqual(@as(?u64, 1), state.last_retry_poll_ns);
        } else try std.testing.expectEqual(@as(?u64, null), state.last_retry_poll_ns);
    }
}

test "execution admission retains independent preparation owners and respects disabled or fenced dispatch" {
    for (0..16) |mask| {
        var state: State = .{};
        var driver = TestDriver{
            .provider_enabled = mask & 1 != 0,
            .fenced = mask & 2 != 0,
            .bash_preparing = mask & 4 != 0,
            .model_preparing = mask & 8 != 0,
        };
        _ = try run(&state, &driver, test_allowance);
        try std.testing.expectEqual(@as(usize, if (driver.fenced) 0 else 1), driver.action_recovery_calls);
        try std.testing.expectEqual(@as(usize, if (driver.fenced or driver.bash_preparing) 0 else 1), driver.bash_admission_calls);
        try std.testing.expectEqual(@as(usize, if (driver.fenced or !driver.provider_enabled) 0 else 1), driver.model_recovery_calls);
        try std.testing.expectEqual(@as(usize, if (driver.fenced or !driver.provider_enabled or driver.model_preparing) 0 else 1), driver.retry_admission_calls);
    }
    var state: State = .{};
    var driver = TestDriver{ .free_slots = 1, .bash_admission = .admitted };
    _ = try run(&state, &driver, test_allowance);
    try std.testing.expectEqual(@as(usize, 0), driver.free_slots);
    try std.testing.expectEqual(@as(usize, 0), driver.retry_admission_calls);
    try std.testing.expectEqual(@as(usize, 0), driver.new_admission_calls);
    try std.testing.expect(state.capacity_was_full);
}

test "execution admission polls retries at the deadline without delaying ordinary discovery" {
    var state = State{ .last_retry_poll_ns = 0 };
    var driver = TestDriver{ .now_ns = std.time.ns_per_s - 1 };
    _ = try run(&state, &driver, test_allowance);
    try std.testing.expectEqual(@as(usize, 0), driver.retry_admission_calls);
    try std.testing.expectEqual(@as(usize, 1), driver.new_admission_calls);
    driver.now_ns += 1;
    driver.event_count = 0;
    _ = try run(&state, &driver, test_allowance);
    try std.testing.expectEqual(@as(usize, 1), driver.retry_admission_calls);
    try std.testing.expectEqual(@as(usize, 2), driver.new_admission_calls);
}

test "execution turn propagates fatal effect failures without issuing later work" {
    const cases = .{
        .{ TestDriver.Failure.action_recovery, error.InjectedActionRecoveryFailure, "LA" },
        .{ TestDriver.Failure.model_recovery, error.InjectedModelRecoveryFailure, "LA" },
        .{ TestDriver.Failure.transport, error.InjectedTransportFailure, "LALD" },
        .{ TestDriver.Failure.completion, error.InjectedCompletionFailure, "LALDN" },
        .{ TestDriver.Failure.readiness, error.InjectedReadinessFailure, "LALDNLP" },
    };
    inline for (cases) |case| {
        var state: State = .{};
        var driver = TestDriver{ .failure = case[0] };
        try std.testing.expectError(case[1], run(&state, &driver, test_allowance));
        try std.testing.expectEqualStrings(case[2], driver.events[0..driver.event_count]);
    }
}
