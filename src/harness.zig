const std = @import("std");

pub const max_completion_capacity = 32;

/// A bounded value copied across the producer-to-owner boundary.
pub const Completion = extern struct {
    agent_id: u64,
    agent_generation: u64,
    operation_id: u64,
    operation_generation: u32,
    result: u64,
};

pub const OfferResult = enum {
    queued,
    full,
    busy,
    unavailable,
    closed,
    invalid,
};

pub const CompletionState = enum {
    applicable,
    durable,
    stale,
    duplicate,
};

pub const Transition = struct {
    context: *anyopaque,
    classify: *const fn (*anyopaque, Completion) anyerror!CompletionState,
    persist: *const fn (*anyopaque, Completion) anyerror!void,
    apply: *const fn (*anyopaque, Completion) anyerror!void,
};

pub const Config = struct {
    completion_capacity: u8,
    drive_quantum: u8,
    transition: Transition,
};

pub const Progress = struct {
    consumed: u8,
    applied: u8,
    stale: u8,
    duplicate: u8,
    more: bool,
};

pub const Harness = struct {
    capacity: u8,
    quantum: u8,
    transition: Transition,
    entries: [max_completion_capacity]Completion = undefined,
    head: u8 = 0,
    len: u8 = 0,
    failed: bool = false,
    closed: bool = false,
    admission_lock: std.atomic.Mutex = .unlocked,

    /// Constructs one fixed-capacity owner. No allocation occurs here or later.
    pub fn open(config: Config) !Harness {
        if (config.completion_capacity == 0 or
            config.completion_capacity > max_completion_capacity or
            config.drive_quantum == 0)
        {
            return error.InvalidCapacity;
        }
        return .{
            .capacity = config.completion_capacity,
            .quantum = config.drive_quantum,
            .transition = config.transition,
        };
    }

    /// Attempts to transfer one completion credit without waiting.
    pub fn offer(self: *Harness, completion: Completion) OfferResult {
        if (!self.admission_lock.tryLock()) return .busy;
        defer self.admission_lock.unlock();
        if (self.closed) return .closed;
        if (self.failed) return .unavailable;
        if (completion.agent_id == 0 or
            completion.agent_generation == 0 or
            completion.operation_id == 0 or
            completion.operation_generation == 0)
        {
            return .invalid;
        }
        if (self.len == self.capacity) return .full;
        const tail = (self.head + self.len) % self.capacity;
        self.entries[tail] = completion;
        self.len += 1;
        return .queued;
    }

    /// Performs at most one configured quantum of owner-only transitions.
    /// Transition callbacks must not reenter this harness.
    pub fn drive(self: *Harness) !Progress {
        if (!self.admission_lock.tryLock()) return error.HarnessBusy;
        defer self.admission_lock.unlock();
        if (self.closed) return error.HarnessClosed;
        if (self.failed) return error.HarnessUnavailable;
        var consumed: u8 = 0;
        var applied: u8 = 0;
        var stale_count: u8 = 0;
        var duplicate_count: u8 = 0;
        while (consumed < self.quantum and self.len > 0) {
            const completion = self.entries[self.head];
            const state = self.transition.classify(self.transition.context, completion) catch |err| {
                self.failed = true;
                return err;
            };
            switch (state) {
                .applicable => {
                    self.transition.persist(self.transition.context, completion) catch |err| {
                        self.failed = true;
                        return err;
                    };
                    self.transition.apply(self.transition.context, completion) catch |err| {
                        self.failed = true;
                        return err;
                    };
                    applied += 1;
                },
                .durable => {
                    self.transition.apply(self.transition.context, completion) catch |err| {
                        self.failed = true;
                        return err;
                    };
                    applied += 1;
                },
                .stale => stale_count += 1,
                .duplicate => duplicate_count += 1,
            }
            self.head = (self.head + 1) % self.capacity;
            self.len -= 1;
            consumed += 1;
        }
        return .{
            .consumed = consumed,
            .applied = applied,
            .stale = stale_count,
            .duplicate = duplicate_count,
            .more = self.len > 0,
        };
    }

    /// Scrubs and closes a quiescent harness. Only its owner may call close,
    /// and never from a transition callback.
    pub fn close(self: *Harness) void {
        while (!self.admission_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.admission_lock.unlock();
        @memset(std.mem.asBytes(&self.entries), 0);
        self.head = 0;
        self.len = 0;
        self.closed = true;
    }
};

comptime {
    std.debug.assert(@sizeOf(Completion) == 40);
    std.debug.assert(@sizeOf(Harness) <= 1536);
}

fn applicable(_: *anyopaque, _: Completion) anyerror!CompletionState {
    return .applicable;
}

fn noOp(_: *anyopaque, _: Completion) anyerror!void {}

test "offer consumes exactly the configured resident credits" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .completion_capacity = 2,
        .drive_quantum = 1,
        .transition = .{
            .context = &context,
            .classify = applicable,
            .persist = noOp,
            .apply = noOp,
        },
    });

    const first: Completion = .{
        .agent_id = 1,
        .agent_generation = 1,
        .operation_id = 11,
        .operation_generation = 1,
        .result = 101,
    };
    var second = first;
    second.agent_id = 2;
    var third = first;
    third.agent_id = 3;

    try std.testing.expectEqual(OfferResult.queued, harness.offer(first));
    try std.testing.expectEqual(OfferResult.queued, harness.offer(second));
    try std.testing.expectEqual(OfferResult.full, harness.offer(third));
}

const Trace = struct {
    calls: [2]u8 = .{ 0, 0 },
    len: u8 = 0,

    fn persist(context: *anyopaque, _: Completion) anyerror!void {
        const self: *Trace = @ptrCast(@alignCast(context));
        self.calls[self.len] = 1;
        self.len += 1;
    }

    fn apply(context: *anyopaque, _: Completion) anyerror!void {
        const self: *Trace = @ptrCast(@alignCast(context));
        if (self.len != 1 or self.calls[0] != 1) return error.AppliedBeforeDurable;
        self.calls[self.len] = 2;
        self.len += 1;
    }
};

test "drive persists a completion before applying it" {
    var trace: Trace = .{};
    var harness = try Harness.open(.{
        .completion_capacity = 1,
        .drive_quantum = 1,
        .transition = .{
            .context = &trace,
            .classify = applicable,
            .persist = Trace.persist,
            .apply = Trace.apply,
        },
    });
    const completion: Completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    };
    try std.testing.expectEqual(OfferResult.queued, harness.offer(completion));

    const progress = try harness.drive();

    try std.testing.expectEqual(@as(u8, 1), progress.consumed);
    try std.testing.expectEqual(@as(u8, 1), progress.applied);
    try std.testing.expect(!progress.more);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &trace.calls);
}

test "offer rejects structurally invalid completion identities" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .completion_capacity = 1,
        .drive_quantum = 1,
        .transition = .{
            .context = &context,
            .classify = applicable,
            .persist = noOp,
            .apply = noOp,
        },
    });
    const invalid: Completion = .{
        .agent_id = 0,
        .agent_generation = 1,
        .operation_id = 11,
        .operation_generation = 1,
        .result = 101,
    };

    try std.testing.expectEqual(OfferResult.invalid, harness.offer(invalid));
}

fn stale(_: *anyopaque, _: Completion) anyerror!CompletionState {
    return .stale;
}

fn unexpectedTransition(_: *anyopaque, _: Completion) anyerror!void {
    return error.UnexpectedTransition;
}

test "drive rejects a stale generation before persistence or mutation" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .completion_capacity = 1,
        .drive_quantum = 1,
        .transition = .{
            .context = &context,
            .classify = stale,
            .persist = unexpectedTransition,
            .apply = unexpectedTransition,
        },
    });
    const completion: Completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    };
    try std.testing.expectEqual(OfferResult.queued, harness.offer(completion));

    const progress = try harness.drive();

    try std.testing.expectEqual(@as(u8, 1), progress.consumed);
    try std.testing.expectEqual(@as(u8, 0), progress.applied);
    try std.testing.expectEqual(@as(u8, 1), progress.stale);
    try std.testing.expect(!progress.more);
}

const RecoveryState = struct {
    persisted: bool = false,
    applied: bool = false,
    fail_apply: bool = true,
    persist_count: u8 = 0,
    apply_count: u8 = 0,

    fn classify(context: *anyopaque, _: Completion) anyerror!CompletionState {
        const self: *RecoveryState = @ptrCast(@alignCast(context));
        if (self.applied) return .duplicate;
        if (self.persisted) return .durable;
        return .applicable;
    }

    fn persist(context: *anyopaque, _: Completion) anyerror!void {
        const self: *RecoveryState = @ptrCast(@alignCast(context));
        self.persisted = true;
        self.persist_count += 1;
    }

    fn apply(context: *anyopaque, _: Completion) anyerror!void {
        const self: *RecoveryState = @ptrCast(@alignCast(context));
        if (self.fail_apply) return error.SimulatedCrash;
        self.applied = true;
        self.apply_count += 1;
    }

    fn config(self: *RecoveryState) Config {
        return .{
            .completion_capacity = 1,
            .drive_quantum = 1,
            .transition = .{
                .context = self,
                .classify = classify,
                .persist = persist,
                .apply = apply,
            },
        };
    }
};

test "a replayed durable completion applies exactly once after owner restart" {
    var state: RecoveryState = .{};
    const completion: Completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    };

    var interrupted = try Harness.open(state.config());
    try std.testing.expectEqual(OfferResult.queued, interrupted.offer(completion));
    try std.testing.expectError(error.SimulatedCrash, interrupted.drive());
    try std.testing.expectEqual(@as(u8, 1), state.persist_count);
    try std.testing.expectEqual(@as(u8, 0), state.apply_count);

    state.fail_apply = false;
    var recovered = try Harness.open(state.config());
    try std.testing.expectEqual(OfferResult.queued, recovered.offer(completion));
    const recovered_progress = try recovered.drive();
    try std.testing.expectEqual(@as(u8, 1), recovered_progress.applied);
    try std.testing.expectEqual(@as(u8, 1), state.persist_count);
    try std.testing.expectEqual(@as(u8, 1), state.apply_count);

    try std.testing.expectEqual(OfferResult.queued, recovered.offer(completion));
    const duplicate_progress = try recovered.drive();
    try std.testing.expectEqual(@as(u8, 1), duplicate_progress.duplicate);
    try std.testing.expectEqual(@as(u8, 1), state.persist_count);
    try std.testing.expectEqual(@as(u8, 1), state.apply_count);
}

fn persistenceFailure(_: *anyopaque, _: Completion) anyerror!void {
    return error.StorageUnavailable;
}

fn classificationFailure(_: *anyopaque, _: Completion) anyerror!CompletionState {
    return error.JournalUnreadable;
}

test "a classification failure makes the owner unavailable" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .completion_capacity = 1,
        .drive_quantum = 1,
        .transition = .{
            .context = &context,
            .classify = classificationFailure,
            .persist = noOp,
            .apply = noOp,
        },
    });
    const completion: Completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    };
    try std.testing.expectEqual(OfferResult.queued, harness.offer(completion));
    try std.testing.expectError(error.JournalUnreadable, harness.drive());
    try std.testing.expectEqual(OfferResult.unavailable, harness.offer(completion));
}

test "a transition failure makes the owner unavailable until reconstruction" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .completion_capacity = 2,
        .drive_quantum = 1,
        .transition = .{
            .context = &context,
            .classify = applicable,
            .persist = persistenceFailure,
            .apply = noOp,
        },
    });
    const completion: Completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    };
    try std.testing.expectEqual(OfferResult.queued, harness.offer(completion));
    try std.testing.expectError(error.StorageUnavailable, harness.drive());

    try std.testing.expectEqual(OfferResult.unavailable, harness.offer(completion));
    try std.testing.expectError(error.HarnessUnavailable, harness.drive());
}

test "close rejects new work and further driving" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .completion_capacity = 1,
        .drive_quantum = 1,
        .transition = .{
            .context = &context,
            .classify = applicable,
            .persist = noOp,
            .apply = noOp,
        },
    });
    harness.close();
    const completion: Completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    };

    try std.testing.expectEqual(OfferResult.closed, harness.offer(completion));
    try std.testing.expectError(error.HarnessClosed, harness.drive());
}

const Producer = struct {
    harness: *Harness,
    start: *std.atomic.Value(bool),
    ready: *std.atomic.Value(u8),
    queued: *std.atomic.Value(u8),
    failed: *std.atomic.Value(u8),
    first_id: u64,

    fn run(self: *Producer) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (!self.start.load(.acquire)) std.Thread.yield() catch {};
        for (0..8) |offset| {
            const id = self.first_id + offset;
            const completion: Completion = .{
                .agent_id = id,
                .agent_generation = 1,
                .operation_id = id + 100,
                .operation_generation = 1,
                .result = id,
            };
            while (true) switch (self.harness.offer(completion)) {
                .queued => {
                    _ = self.queued.fetchAdd(1, .monotonic);
                    break;
                },
                .busy => std.Thread.yield() catch {},
                else => {
                    _ = self.failed.fetchAdd(1, .monotonic);
                    break;
                },
            };
        }
    }
};

test "concurrent producers cannot exceed fixed admission credits" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .completion_capacity = max_completion_capacity,
        .drive_quantum = 1,
        .transition = .{
            .context = &context,
            .classify = applicable,
            .persist = noOp,
            .apply = noOp,
        },
    });
    var start = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(u8).init(0);
    var queued = std.atomic.Value(u8).init(0);
    var failed = std.atomic.Value(u8).init(0);
    var producers: [4]Producer = undefined;
    var threads: [4]std.Thread = undefined;
    for (&producers, &threads, 0..) |*producer, *thread, index| {
        producer.* = .{
            .harness = &harness,
            .start = &start,
            .ready = &ready,
            .queued = &queued,
            .failed = &failed,
            .first_id = @as(u64, @intCast(index)) * 8 + 1,
        };
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
    }
    while (ready.load(.acquire) != producers.len) std.Thread.yield() catch {};
    start.store(true, .release);
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(u8, max_completion_capacity), queued.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), failed.load(.acquire));
    const overflow: Completion = .{
        .agent_id = 99,
        .agent_generation = 1,
        .operation_id = 199,
        .operation_generation = 1,
        .result = 99,
    };
    try std.testing.expectEqual(OfferResult.full, harness.offer(overflow));
}

const CountState = struct {
    persisted: u32 = 0,
    applied: u32 = 0,

    fn persist(context: *anyopaque, _: Completion) anyerror!void {
        const self: *CountState = @ptrCast(@alignCast(context));
        self.persisted += 1;
    }

    fn apply(context: *anyopaque, _: Completion) anyerror!void {
        const self: *CountState = @ptrCast(@alignCast(context));
        self.applied += 1;
    }
};

test "drive bounds each owner turn by the configured quantum" {
    var state: CountState = .{};
    var harness = try Harness.open(.{
        .completion_capacity = 3,
        .drive_quantum = 2,
        .transition = .{
            .context = &state,
            .classify = applicable,
            .persist = CountState.persist,
            .apply = CountState.apply,
        },
    });
    for (1..4) |id| {
        try std.testing.expectEqual(OfferResult.queued, harness.offer(.{
            .agent_id = id,
            .agent_generation = 1,
            .operation_id = id + 100,
            .operation_generation = 1,
            .result = id,
        }));
    }

    const first = try harness.drive();
    try std.testing.expectEqual(@as(u8, 2), first.consumed);
    try std.testing.expect(first.more);
    const second = try harness.drive();
    try std.testing.expectEqual(@as(u8, 1), second.consumed);
    try std.testing.expect(!second.more);
}

test "ten thousand reuse cycles keep the resident control budget fixed" {
    var state: CountState = .{};
    var harness = try Harness.open(.{
        .completion_capacity = 1,
        .drive_quantum = 1,
        .transition = .{
            .context = &state,
            .classify = applicable,
            .persist = CountState.persist,
            .apply = CountState.apply,
        },
    });
    for (0..10_000) |index| {
        const id = index + 1;
        try std.testing.expectEqual(OfferResult.queued, harness.offer(.{
            .agent_id = id,
            .agent_generation = 1,
            .operation_id = id,
            .operation_generation = 1,
            .result = id,
        }));
        const progress = try harness.drive();
        try std.testing.expectEqual(@as(u8, 1), progress.applied);
        try std.testing.expect(!progress.more);
    }
    try std.testing.expectEqual(@as(u32, 10_000), state.persisted);
    try std.testing.expectEqual(@as(u32, 10_000), state.applied);
}
