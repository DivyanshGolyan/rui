const std = @import("std");

pub const max_input_capacity = 32;

/// A bounded value copied across the producer-to-owner boundary.
pub const Completion = extern struct {
    agent_id: u64,
    agent_generation: u64,
    operation_id: u64,
    operation_generation: u32,
    result: u64,
};

pub const TaskInput = extern struct {
    task_id: u64,
    agent_id: u64,
    agent_generation: u64,
    task_ref: u64,
};

pub const AgentIdentity = extern struct {
    agent_id: u64,
    agent_generation: u64,
};

pub const Permission = enum(u8) {
    allow,
    deny,
};

pub const PermissionDecision = extern struct {
    agent_id: u64,
    agent_generation: u64,
    operation_id: u64,
    operation_generation: u32,
    decision: Permission,
    descriptor_digest: u64,
};

pub const Input = union(enum) {
    start_task: TaskInput,
    completion: Completion,
    permission: PermissionDecision,
    cancel: AgentIdentity,
    shutdown,
};

pub const OfferResult = enum {
    queued,
    full,
    busy,
    unavailable,
    closed,
    invalid,
};

pub const InputState = enum {
    applicable,
    durable,
    stale,
    duplicate,
};

pub const Transition = struct {
    context: *anyopaque,
    classify: *const fn (*anyopaque, Input) anyerror!InputState,
    persist: *const fn (*anyopaque, Input) anyerror!void,
    apply: *const fn (*anyopaque, Input) anyerror!void,
};

pub const Config = struct {
    input_capacity: u8,
    drive_quantum: u8,
    transition: Transition,
};

pub const Progress = struct {
    consumed: u8,
    committed: u8,
    dispatched: u8,
    applied: u8,
    stale: u8,
    duplicate: u8,
    projections: [max_input_capacity + 1]Projection,
    projection_count: u8,
    state: State,
    more: bool,

    pub fn projectionSlice(self: *const Progress) []const Projection {
        return self.projections[0..self.projection_count];
    }
};

pub const State = enum {
    running,
    suspended,
    finished,
    closed,
    failed,
};

pub const ProjectionKind = enum {
    task_started,
    completion_committed,
    permission_committed,
    cancelled,
    closed,
};

pub const Projection = struct {
    kind: ProjectionKind,
    subject: u64,
};

const Phase = enum {
    running,
    cancelling,
    finished,
    closed,
    failed,
};

const Entry = extern struct {
    words: [5]u64,
};

fn tagBits(tag: std.meta.Tag(Input)) u64 {
    return @as(u64, @intFromEnum(tag)) << 56;
}

fn entryTag(entry: Entry) std.meta.Tag(Input) {
    return @enumFromInt(@as(u8, @truncate(entry.words[3] >> 56)));
}

fn encode(input: Input) Entry {
    return switch (input) {
        .start_task => |task| .{ .words = .{
            task.task_id,
            task.agent_id,
            task.agent_generation,
            tagBits(.start_task),
            task.task_ref,
        } },
        .completion => |completion| .{ .words = .{
            completion.agent_id,
            completion.agent_generation,
            completion.operation_id,
            tagBits(.completion) | completion.operation_generation,
            completion.result,
        } },
        .permission => |permission| .{ .words = .{
            permission.agent_id,
            permission.agent_generation,
            permission.operation_id,
            tagBits(.permission) |
                @as(u64, permission.operation_generation) |
                (@as(u64, @intFromEnum(permission.decision)) << 32),
            permission.descriptor_digest,
        } },
        .cancel => |identity| .{ .words = .{
            identity.agent_id,
            identity.agent_generation,
            0,
            tagBits(.cancel),
            0,
        } },
        .shutdown => .{ .words = .{ 0, 0, 0, tagBits(.shutdown), 0 } },
    };
}

fn decode(entry: Entry) Input {
    return switch (entryTag(entry)) {
        .start_task => .{ .start_task = .{
            .task_id = entry.words[0],
            .agent_id = entry.words[1],
            .agent_generation = entry.words[2],
            .task_ref = entry.words[4],
        } },
        .completion => .{ .completion = .{
            .agent_id = entry.words[0],
            .agent_generation = entry.words[1],
            .operation_id = entry.words[2],
            .operation_generation = @truncate(entry.words[3]),
            .result = entry.words[4],
        } },
        .permission => .{ .permission = .{
            .agent_id = entry.words[0],
            .agent_generation = entry.words[1],
            .operation_id = entry.words[2],
            .operation_generation = @truncate(entry.words[3]),
            .decision = @enumFromInt(@as(u8, @truncate(entry.words[3] >> 32))),
            .descriptor_digest = entry.words[4],
        } },
        .cancel => .{ .cancel = .{
            .agent_id = entry.words[0],
            .agent_generation = entry.words[1],
        } },
        .shutdown => .shutdown,
    };
}

fn structurallyValid(input: Input) bool {
    return switch (input) {
        .start_task => |task| task.task_id != 0 and
            task.agent_id != 0 and
            task.agent_generation != 0 and
            task.task_ref != 0,
        .completion => |completion| completion.agent_id != 0 and
            completion.agent_generation != 0 and
            completion.operation_id != 0 and
            completion.operation_generation != 0,
        .permission => |permission| permission.agent_id != 0 and
            permission.agent_generation != 0 and
            permission.operation_id != 0 and
            permission.operation_generation != 0 and
            permission.descriptor_digest != 0,
        .cancel => |identity| identity.agent_id != 0 and identity.agent_generation != 0,
        .shutdown => true,
    };
}

fn projectionFor(input: Input) ?Projection {
    return switch (input) {
        .start_task => |task| .{ .kind = .task_started, .subject = task.task_id },
        .completion => |completion| .{
            .kind = .completion_committed,
            .subject = completion.operation_id,
        },
        .permission => |permission| .{
            .kind = .permission_committed,
            .subject = permission.operation_id,
        },
        .cancel, .shutdown => null,
    };
}

pub const Harness = struct {
    capacity: u8,
    quantum: u8,
    transition: Transition,
    entries: [max_input_capacity]Entry = undefined,
    head: u8 = 0,
    len: u8 = 0,
    phase: Phase = .running,
    task_admitted: bool = false,
    cancel_admitted: bool = false,
    shutdown_admitted: bool = false,
    admission_lock: std.atomic.Mutex = .unlocked,

    /// Constructs one fixed-capacity owner. No allocation occurs here or later.
    pub fn open(config: Config) !Harness {
        if (config.input_capacity == 0 or
            config.input_capacity > max_input_capacity or
            config.drive_quantum == 0)
        {
            return error.InvalidCapacity;
        }
        return .{
            .capacity = config.input_capacity,
            .quantum = config.drive_quantum,
            .transition = config.transition,
        };
    }

    /// Attempts to transfer one bounded input without waiting or performing I/O.
    pub fn offer(self: *Harness, input: Input) OfferResult {
        if (!self.admission_lock.tryLock()) return .busy;
        defer self.admission_lock.unlock();
        if (self.phase == .closed or self.shutdown_admitted) return .closed;
        if (self.phase == .failed) return .unavailable;
        if (!structurallyValid(input)) return .invalid;
        if (self.phase == .finished and input != .shutdown) return .closed;
        switch (input) {
            .start_task => if (self.task_admitted or self.cancel_admitted) return .invalid,
            .permission => if (self.cancel_admitted) return .invalid,
            .cancel => if (self.cancel_admitted) return .invalid,
            .completion, .shutdown => {},
        }
        if (self.len == self.capacity) return .full;
        const tail = (self.head + self.len) % self.capacity;
        self.entries[tail] = encode(input);
        self.len += 1;
        switch (input) {
            .start_task => self.task_admitted = true,
            .cancel => self.cancel_admitted = true,
            .shutdown => self.shutdown_admitted = true,
            .completion, .permission => {},
        }
        return .queued;
    }

    /// Performs at most one configured quantum of owner-only transitions.
    /// Transition callbacks must not reenter this harness.
    pub fn drive(self: *Harness) !Progress {
        if (!self.admission_lock.tryLock()) return error.HarnessBusy;
        defer self.admission_lock.unlock();
        if (self.phase == .closed) return error.HarnessClosed;
        if (self.phase == .failed) return error.HarnessUnavailable;
        if (self.phase == .finished and self.len == 0) return error.HarnessFinished;
        var consumed: u8 = 0;
        var committed: u8 = 0;
        var applied: u8 = 0;
        var stale_count: u8 = 0;
        var duplicate_count: u8 = 0;
        var projections: [max_input_capacity + 1]Projection = undefined;
        var projection_count: u8 = 0;
        while (consumed < self.quantum and self.len > 0) {
            const input = decode(self.entries[self.head]);
            const state = self.transition.classify(self.transition.context, input) catch |err| {
                self.phase = .failed;
                return err;
            };
            switch (state) {
                .applicable => {
                    self.transition.persist(self.transition.context, input) catch |err| {
                        self.phase = .failed;
                        return err;
                    };
                    committed += 1;
                    self.transition.apply(self.transition.context, input) catch |err| {
                        self.phase = .failed;
                        return err;
                    };
                    applied += 1;
                },
                .durable => {
                    self.transition.apply(self.transition.context, input) catch |err| {
                        self.phase = .failed;
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
            if (state == .applicable or state == .durable) {
                if (projectionFor(input)) |projection| {
                    projections[projection_count] = projection;
                    projection_count += 1;
                }
                switch (input) {
                    .cancel => self.phase = .cancelling,
                    .shutdown => self.phase = .closed,
                    .start_task, .completion, .permission => {},
                }
            }
            if (self.phase == .cancelling and
                (self.len == 0 or
                    (self.len == 1 and entryTag(self.entries[self.head]) == .shutdown)))
            {
                self.phase = .finished;
                projections[projection_count] = .{
                    .kind = .cancelled,
                    .subject = 0,
                };
                projection_count += 1;
            }
        }
        if (self.phase == .closed) {
            std.debug.assert(self.len == 0);
            projections[projection_count] = .{ .kind = .closed, .subject = 0 };
            projection_count += 1;
            @memset(std.mem.asBytes(&self.entries), 0);
            self.head = 0;
        }
        return .{
            .consumed = consumed,
            .committed = committed,
            .dispatched = 0,
            .applied = applied,
            .stale = stale_count,
            .duplicate = duplicate_count,
            .projections = projections,
            .projection_count = projection_count,
            .state = self.publicState(),
            .more = self.len > 0,
        };
    }

    fn publicState(self: *const Harness) State {
        return switch (self.phase) {
            .running => if (self.len == 0) .suspended else .running,
            .cancelling => .running,
            .finished => .finished,
            .closed => .closed,
            .failed => .failed,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Completion) == 40);
    std.debug.assert(@sizeOf(Entry) == 40);
    std.debug.assert(@sizeOf(Harness) <= 1536);
}

fn applicable(_: *anyopaque, _: Input) anyerror!InputState {
    return .applicable;
}

fn noOp(_: *anyopaque, _: Input) anyerror!void {}

test "ingress encoding preserves every bounded field" {
    const inputs = [_]Input{
        .{ .start_task = .{
            .task_id = std.math.maxInt(u64),
            .agent_id = 2,
            .agent_generation = 3,
            .task_ref = 4,
        } },
        .{ .completion = .{
            .agent_id = 5,
            .agent_generation = 6,
            .operation_id = 7,
            .operation_generation = std.math.maxInt(u32),
            .result = std.math.maxInt(u64),
        } },
        .{ .permission = .{
            .agent_id = 8,
            .agent_generation = 9,
            .operation_id = 10,
            .operation_generation = std.math.maxInt(u32),
            .decision = .deny,
            .descriptor_digest = std.math.maxInt(u64),
        } },
        .{ .cancel = .{
            .agent_id = std.math.maxInt(u64),
            .agent_generation = std.math.maxInt(u64),
        } },
        .shutdown,
    };
    for (inputs) |input| try std.testing.expectEqualDeep(input, decode(encode(input)));
}

const InputTrace = struct {
    kinds: [5]std.meta.Tag(Input) = undefined,
    persisted: u8 = 0,
    applied: u8 = 0,

    fn persist(context: *anyopaque, input: Input) anyerror!void {
        const self: *InputTrace = @ptrCast(@alignCast(context));
        self.kinds[self.persisted] = std.meta.activeTag(input);
        self.persisted += 1;
    }

    fn apply(context: *anyopaque, input: Input) anyerror!void {
        const self: *InputTrace = @ptrCast(@alignCast(context));
        if (self.applied >= self.persisted or
            self.kinds[self.applied] != std.meta.activeTag(input))
        {
            return error.AppliedBeforeDurable;
        }
        self.applied += 1;
    }

    fn transition(self: *InputTrace) Transition {
        return .{
            .context = self,
            .classify = applicable,
            .persist = persist,
            .apply = apply,
        };
    }
};

test "all input kinds share the bounded durable owner path" {
    var trace: InputTrace = .{};
    var harness = try Harness.open(.{
        .input_capacity = 5,
        .drive_quantum = 5,
        .transition = trace.transition(),
    });
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .start_task = .{
        .task_id = 41,
        .agent_id = 7,
        .agent_generation = 3,
        .task_ref = 91,
    } }));
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    } }));
    try std.testing.expectEqual(@as(u8, 0), trace.persisted);
    try std.testing.expectEqual(@as(u8, 0), trace.applied);
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .permission = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 20,
        .operation_generation = 1,
        .decision = .allow,
        .descriptor_digest = 0xabc,
    } }));
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .cancel = .{
        .agent_id = 7,
        .agent_generation = 3,
    } }));
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.shutdown));

    const progress = try harness.drive();

    try std.testing.expectEqual(@as(u8, 5), progress.consumed);
    try std.testing.expectEqual(@as(u8, 5), progress.committed);
    try std.testing.expectEqual(@as(u8, 5), progress.applied);
    try std.testing.expectEqual(State.closed, progress.state);
    try std.testing.expectEqual(@as(u8, 5), trace.persisted);
    try std.testing.expectEqual(@as(u8, 5), trace.applied);
    try std.testing.expectEqualSlices(
        std.meta.Tag(Input),
        &.{ .start_task, .completion, .permission, .cancel, .shutdown },
        &trace.kinds,
    );
    try std.testing.expectEqualSlices(
        Projection,
        &.{
            .{ .kind = .task_started, .subject = 41 },
            .{ .kind = .completion_committed, .subject = 19 },
            .{ .kind = .permission_committed, .subject = 20 },
            .{ .kind = .cancelled, .subject = 0 },
            .{ .kind = .closed, .subject = 0 },
        },
        progress.projectionSlice(),
    );
}

test "cancellation settles an already accepted completion before finishing" {
    var trace: InputTrace = .{};
    var harness = try Harness.open(.{
        .input_capacity = 2,
        .drive_quantum = 1,
        .transition = trace.transition(),
    });
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .cancel = .{
        .agent_id = 7,
        .agent_generation = 3,
    } }));
    try std.testing.expectEqual(OfferResult.invalid, harness.offer(.{ .start_task = .{
        .task_id = 41,
        .agent_id = 7,
        .agent_generation = 3,
        .task_ref = 91,
    } }));
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    } }));

    const cancelling = try harness.drive();
    try std.testing.expectEqual(State.running, cancelling.state);
    try std.testing.expect(cancelling.more);
    try std.testing.expectEqual(@as(u8, 0), cancelling.projection_count);

    const finished = try harness.drive();
    try std.testing.expectEqual(State.finished, finished.state);
    try std.testing.expect(!finished.more);
    try std.testing.expectEqualSlices(
        Projection,
        &.{
            .{ .kind = .completion_committed, .subject = 19 },
            .{ .kind = .cancelled, .subject = 0 },
        },
        finished.projectionSlice(),
    );

    try std.testing.expectEqual(OfferResult.queued, harness.offer(.shutdown));
    const closed = try harness.drive();
    try std.testing.expectEqual(State.closed, closed.state);
}

test "offer consumes exactly the configured resident credits" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .input_capacity = 2,
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

    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = first }));
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = second }));
    try std.testing.expectEqual(OfferResult.full, harness.offer(.{ .completion = third }));
}

const Trace = struct {
    calls: [2]u8 = .{ 0, 0 },
    len: u8 = 0,

    fn persist(context: *anyopaque, _: Input) anyerror!void {
        const self: *Trace = @ptrCast(@alignCast(context));
        self.calls[self.len] = 1;
        self.len += 1;
    }

    fn apply(context: *anyopaque, _: Input) anyerror!void {
        const self: *Trace = @ptrCast(@alignCast(context));
        if (self.len != 1 or self.calls[0] != 1) return error.AppliedBeforeDurable;
        self.calls[self.len] = 2;
        self.len += 1;
    }
};

test "drive persists a completion before applying it" {
    var trace: Trace = .{};
    var harness = try Harness.open(.{
        .input_capacity = 1,
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
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = completion }));

    const progress = try harness.drive();

    try std.testing.expectEqual(@as(u8, 1), progress.consumed);
    try std.testing.expectEqual(@as(u8, 1), progress.applied);
    try std.testing.expect(!progress.more);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &trace.calls);
}

test "offer rejects structurally invalid completion identities" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .input_capacity = 1,
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

    try std.testing.expectEqual(OfferResult.invalid, harness.offer(.{ .completion = invalid }));
}

fn stale(_: *anyopaque, _: Input) anyerror!InputState {
    return .stale;
}

fn unexpectedTransition(_: *anyopaque, _: Input) anyerror!void {
    return error.UnexpectedTransition;
}

test "drive rejects a stale generation before persistence or mutation" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .input_capacity = 1,
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
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = completion }));

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

    fn classify(context: *anyopaque, _: Input) anyerror!InputState {
        const self: *RecoveryState = @ptrCast(@alignCast(context));
        if (self.applied) return .duplicate;
        if (self.persisted) return .durable;
        return .applicable;
    }

    fn persist(context: *anyopaque, _: Input) anyerror!void {
        const self: *RecoveryState = @ptrCast(@alignCast(context));
        self.persisted = true;
        self.persist_count += 1;
    }

    fn apply(context: *anyopaque, _: Input) anyerror!void {
        const self: *RecoveryState = @ptrCast(@alignCast(context));
        if (self.fail_apply) return error.SimulatedCrash;
        self.applied = true;
        self.apply_count += 1;
    }

    fn config(self: *RecoveryState) Config {
        return .{
            .input_capacity = 1,
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
    try std.testing.expectEqual(OfferResult.queued, interrupted.offer(.{ .completion = completion }));
    try std.testing.expectError(error.SimulatedCrash, interrupted.drive());
    try std.testing.expectEqual(@as(u8, 1), state.persist_count);
    try std.testing.expectEqual(@as(u8, 0), state.apply_count);

    state.fail_apply = false;
    var recovered = try Harness.open(state.config());
    try std.testing.expectEqual(OfferResult.queued, recovered.offer(.{ .completion = completion }));
    const recovered_progress = try recovered.drive();
    try std.testing.expectEqual(@as(u8, 1), recovered_progress.applied);
    try std.testing.expectEqual(@as(u8, 1), state.persist_count);
    try std.testing.expectEqual(@as(u8, 1), state.apply_count);

    try std.testing.expectEqual(OfferResult.queued, recovered.offer(.{ .completion = completion }));
    const duplicate_progress = try recovered.drive();
    try std.testing.expectEqual(@as(u8, 1), duplicate_progress.duplicate);
    try std.testing.expectEqual(@as(u8, 1), state.persist_count);
    try std.testing.expectEqual(@as(u8, 1), state.apply_count);
}

fn persistenceFailure(_: *anyopaque, _: Input) anyerror!void {
    return error.StorageUnavailable;
}

fn classificationFailure(_: *anyopaque, _: Input) anyerror!InputState {
    return error.JournalUnreadable;
}

test "a classification failure makes the owner unavailable" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .input_capacity = 1,
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
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = completion }));
    try std.testing.expectError(error.JournalUnreadable, harness.drive());
    try std.testing.expectEqual(OfferResult.unavailable, harness.offer(.{ .completion = completion }));
}

test "a transition failure makes the owner unavailable until reconstruction" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .input_capacity = 2,
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
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = completion }));
    try std.testing.expectError(error.StorageUnavailable, harness.drive());

    try std.testing.expectEqual(OfferResult.unavailable, harness.offer(.{ .completion = completion }));
    try std.testing.expectError(error.HarnessUnavailable, harness.drive());
}

test "shutdown is offered and driven instead of bypassing the owner loop" {
    var context: u8 = 0;
    var harness = try Harness.open(.{
        .input_capacity = 1,
        .drive_quantum = 1,
        .transition = .{
            .context = &context,
            .classify = applicable,
            .persist = noOp,
            .apply = noOp,
        },
    });
    try std.testing.expectEqual(OfferResult.queued, harness.offer(.shutdown));
    const progress = try harness.drive();
    try std.testing.expectEqual(State.closed, progress.state);
    try std.testing.expectEqualSlices(
        Projection,
        &.{.{ .kind = .closed, .subject = 0 }},
        progress.projectionSlice(),
    );
    const completion: Completion = .{
        .agent_id = 7,
        .agent_generation = 3,
        .operation_id = 19,
        .operation_generation = 2,
        .result = 101,
    };

    try std.testing.expectEqual(OfferResult.closed, harness.offer(.{ .completion = completion }));
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
            while (true) switch (self.harness.offer(.{ .completion = completion })) {
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
        .input_capacity = max_input_capacity,
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

    try std.testing.expectEqual(@as(u8, max_input_capacity), queued.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), failed.load(.acquire));
    const overflow: Completion = .{
        .agent_id = 99,
        .agent_generation = 1,
        .operation_id = 199,
        .operation_generation = 1,
        .result = 99,
    };
    try std.testing.expectEqual(OfferResult.full, harness.offer(.{ .completion = overflow }));
}

const CountState = struct {
    persisted: u32 = 0,
    applied: u32 = 0,

    fn persist(context: *anyopaque, _: Input) anyerror!void {
        const self: *CountState = @ptrCast(@alignCast(context));
        self.persisted += 1;
    }

    fn apply(context: *anyopaque, _: Input) anyerror!void {
        const self: *CountState = @ptrCast(@alignCast(context));
        self.applied += 1;
    }
};

test "drive bounds each owner turn by the configured quantum" {
    var state: CountState = .{};
    var harness = try Harness.open(.{
        .input_capacity = 3,
        .drive_quantum = 2,
        .transition = .{
            .context = &state,
            .classify = applicable,
            .persist = CountState.persist,
            .apply = CountState.apply,
        },
    });
    for (1..4) |id| {
        try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = .{
            .agent_id = id,
            .agent_generation = 1,
            .operation_id = id + 100,
            .operation_generation = 1,
            .result = id,
        } }));
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
        .input_capacity = 1,
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
        try std.testing.expectEqual(OfferResult.queued, harness.offer(.{ .completion = .{
            .agent_id = id,
            .agent_generation = 1,
            .operation_id = id,
            .operation_generation = 1,
            .result = id,
        } }));
        const progress = try harness.drive();
        try std.testing.expectEqual(@as(u8, 1), progress.applied);
        try std.testing.expect(!progress.more);
    }
    try std.testing.expectEqual(@as(u32, 10_000), state.persisted);
    try std.testing.expectEqual(@as(u32, 10_000), state.applied);
}
