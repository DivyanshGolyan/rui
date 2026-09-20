const std = @import("std");

pub const Allowance = struct {
    bytes: usize,
    items: usize,
};

pub const Next = enum { again, wait };

/// One production turn. The driver owns effects, not ordering: admission and
/// settlement remain atomic Store calls, and preparation performs one advance.
/// Keep calls on the left of `or`; progress must not short-circuit later work.
pub fn run(driver: anytype, allowance: Allowance) !Next {
    var made_progress = driver.serviceLifecycle(driver.now());
    made_progress = (try driver.admit()) or made_progress;
    made_progress = driver.serviceLifecycle(driver.now()) or made_progress;
    try driver.driveTransport();
    if (try driver.nextCompletion()) |completion| {
        driver.complete(completion);
        made_progress = true;
    }
    made_progress = driver.serviceLifecycle(driver.now()) or made_progress;
    made_progress = driver.advancePreparation(allowance) or made_progress;
    return if (made_progress) .again else .wait;
}

/// The execution owner's existing fallback deadline, with time supplied by its
/// caller. A notification accelerates reconciliation; it never replaces it.
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

// Script only external results. There is no second turn implementation here.
const TestDriver = struct {
    const Failure = enum { admission, transport, completion };

    events: [16]u8 = undefined,
    event_count: usize = 0,
    now_ns: u64 = 0,
    admission_elapsed_ns: u64 = 0,
    completion_elapsed_ns: u64 = 0,
    lifecycle_times: [3]u64 = @splat(0),
    lifecycle_calls: usize = 0,
    lifecycle_progress: bool = false,
    admission_progress: bool = false,
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

    pub fn serviceLifecycle(self: *TestDriver, now_ns: u64) bool {
        self.event('L');
        self.lifecycle_times[self.lifecycle_calls % self.lifecycle_times.len] = now_ns;
        self.lifecycle_calls += 1;
        return self.lifecycle_progress;
    }

    pub fn admit(self: *TestDriver) !bool {
        self.event('A');
        if (self.failure == .admission) return error.InjectedAdmissionFailure;
        self.now_ns += self.admission_elapsed_ns;
        return self.admission_progress;
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
        if (self.preparation_steps_remaining == 0) return false;
        self.preparation_steps_remaining -= 1;
        return true;
    }
};

const test_allowance = Allowance{ .bytes = 17, .items = 3 };

test "execution turn orders all boundaries and removes one completion" {
    var driver = TestDriver{
        .completions_remaining = 2,
        .preparation_steps_remaining = 2,
    };
    try std.testing.expectEqual(Next.again, try run(&driver, test_allowance));
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

test "execution turn never short circuits later work when any earlier stage progresses" {
    for (0..16) |mask| {
        var driver = TestDriver{
            .lifecycle_progress = mask & 1 != 0,
            .admission_progress = mask & 2 != 0,
            .completions_remaining = if (mask & 4 != 0) 1 else 0,
            .preparation_steps_remaining = if (mask & 8 != 0) 1 else 0,
        };
        try std.testing.expectEqual(
            if (mask == 0) Next.wait else Next.again,
            try run(&driver, test_allowance),
        );
        try std.testing.expectEqual(@as(usize, 3), driver.lifecycle_calls);
        try std.testing.expectEqual(@as(usize, 1), driver.preparation_calls);
        const expected = if (mask & 4 != 0) "LALDNCLP" else "LALDNLP";
        try std.testing.expectEqual(expected.len, driver.event_count);
        try std.testing.expectEqualStrings(expected, driver.events[0..expected.len]);
    }
}

test "execution turn drains finite independent completion and preparation populations without waiting" {
    const sizes = [_]usize{ 0, 1, 2, 31, 256, 4096 };
    for (sizes) |completions| {
        for (sizes) |steps| {
            var driver = TestDriver{
                .completions_remaining = completions,
                .preparation_steps_remaining = steps,
            };
            const turns = @max(completions, steps);
            for (0..turns) |index| {
                driver.event_count = 0;
                const removed = driver.completions_removed;
                const settled = driver.completions_settled;
                const preparation_calls = driver.preparation_calls;
                try std.testing.expectEqual(Next.again, try run(&driver, test_allowance));
                const expected: usize = if (index < completions) 1 else 0;
                try std.testing.expectEqual(expected, driver.completions_removed - removed);
                try std.testing.expectEqual(expected, driver.completions_settled - settled);
                try std.testing.expectEqual(@as(usize, 1), driver.preparation_calls - preparation_calls);
                try std.testing.expectEqual(3 * (index + 1), driver.lifecycle_calls);
            }
            driver.event_count = 0;
            try std.testing.expectEqual(Next.wait, try run(&driver, test_allowance));
            try std.testing.expectEqual(completions, driver.completions_settled);
            try std.testing.expectEqual(@as(usize, 0), driver.preparation_steps_remaining);
        }
    }
}

test "execution turn samples fresh lifecycle time after admission and completion" {
    var driver = TestDriver{
        .completions_remaining = 1,
        .admission_elapsed_ns = 200 * std.time.ns_per_ms,
        .completion_elapsed_ns = 400 * std.time.ns_per_ms,
    };
    _ = try run(&driver, test_allowance);
    try std.testing.expectEqual(
        [3]u64{ 0, 200 * std.time.ns_per_ms, 600 * std.time.ns_per_ms },
        driver.lifecycle_times,
    );
    // A deadline reached while an atomic call runs is visible at the very
    // next service opportunity, rather than waiting for another whole turn.
    const due_after_admission: u64 = 150 * std.time.ns_per_ms;
    const due_after_completion: u64 = 500 * std.time.ns_per_ms;
    try std.testing.expect(driver.lifecycle_times[0] < due_after_admission);
    try std.testing.expect(driver.lifecycle_times[1] >= due_after_admission);
    try std.testing.expect(driver.lifecycle_times[1] < due_after_completion);
    try std.testing.expect(driver.lifecycle_times[2] >= due_after_completion);
}

test "execution turn control polling remains authoritative when notifications are lost" {
    var poll: ControlPoll = .{};
    try std.testing.expect(poll.due(0, false));
    for (1..100) |tick| {
        try std.testing.expect(!poll.due(tick * std.time.ns_per_ms, false));
    }
    try std.testing.expect(poll.due(ControlPoll.interval_ns, false));
    try std.testing.expect(!poll.due(ControlPoll.interval_ns, false));
    try std.testing.expect(poll.due(ControlPoll.interval_ns + 1, true));
    try std.testing.expect(!poll.due(2 * ControlPoll.interval_ns, false));
    try std.testing.expect(poll.due(2 * ControlPoll.interval_ns + 1, false));
    // Reconciliation is due immediately after a large elapsed-time jump.
    try std.testing.expect(poll.due(100 * ControlPoll.interval_ns, false));
}

test "execution turn propagates fatal effect failures without issuing later work" {
    var admission = TestDriver{ .failure = .admission };
    try std.testing.expectError(error.InjectedAdmissionFailure, run(&admission, test_allowance));
    try std.testing.expectEqualStrings("LA", admission.events[0..admission.event_count]);
    var transport = TestDriver{ .failure = .transport };
    try std.testing.expectError(error.InjectedTransportFailure, run(&transport, test_allowance));
    try std.testing.expectEqualStrings("LALD", transport.events[0..transport.event_count]);
    var completion = TestDriver{ .failure = .completion };
    try std.testing.expectError(error.InjectedCompletionFailure, run(&completion, test_allowance));
    try std.testing.expectEqualStrings("LALDN", completion.events[0..completion.event_count]);
}
