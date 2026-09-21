const std = @import("std");

pub const control_reconciliation_interval_ms = 100;
pub const retained_cleanup_retry_ms = 100;
pub const retry_poll_interval_ns: u64 = std.time.ns_per_s;

pub const Admission = enum { no_work, retry_later, admitted };

pub const Allowance = struct {
    bytes: usize,
    items: usize,
};

pub const Wait = enum { transport, bash, idle };

pub const Outcome = union(enum) {
    continue_immediately,
    wait: Wait,
    terminate,
};

pub const State = struct {
    last_retry_poll: ?std.Io.Clock.Timestamp = null,
    next_control_reconciliation: ?std.Io.Clock.Timestamp = null,
    retained_cleanup_at: ?std.Io.Clock.Timestamp = null,
    capacity_was_full: bool = false,
};

fn due(deadline: ?std.Io.Clock.Timestamp, now: std.Io.Clock.Timestamp) bool {
    return if (deadline) |value| value.compare(.lte, now) else true;
}

fn addMs(now: std.Io.Clock.Timestamp, milliseconds: u64) std.Io.Clock.Timestamp {
    return now.addDuration(.{
        .raw = .fromMilliseconds(@intCast(milliseconds)),
        .clock = .awake,
    });
}

pub fn serviceLifecycle(state: *State, context: anytype) bool {
    context.noteLifecycleOpportunity();
    const now = context.now();
    const hint = context.consumeControlHint();
    var made_progress = false;
    if (hint or due(state.next_control_reconciliation, now)) {
        context.reconcileControls();
        state.next_control_reconciliation = addMs(now, control_reconciliation_interval_ms);
        made_progress = hint;
    }
    if (context.advanceBashPreparation()) made_progress = true;
    if (context.advanceLiveBash()) made_progress = true;
    if (context.advanceOrdinaryCleanup(now)) made_progress = true;
    if (state.retained_cleanup_at == null) state.retained_cleanup_at = now;
    if (context.advanceRetainedCleanup(now, &state.retained_cleanup_at.?)) made_progress = true;
    return made_progress;
}

fn admitWork(state: *State, context: anytype, now: std.Io.Clock.Timestamp) error{Fence}!bool {
    var made_progress = false;
    var free_slots = context.freeSlots();
    const capacity_released = state.capacity_was_full and free_slots != 0;
    const retry_poll_due = if (state.last_retry_poll) |last|
        last.durationTo(now).raw.nanoseconds >= retry_poll_interval_ns
    else
        true;
    if (try context.recoverUncertainAction()) made_progress = true;
    if (free_slots != 0 and context.bashPreparationOpen()) {
        switch (context.admitBash()) {
            .admitted => made_progress = true,
            .no_work, .retry_later => {},
        }
        free_slots = context.freeSlots();
    }
    const maintain_retries = context.providerConfigured() and (retry_poll_due or capacity_released);
    var may_admit_new = !maintain_retries;
    if (maintain_retries) {
        if (try context.recoverExhaustedRetry()) {
            made_progress = true;
            state.last_retry_poll = null;
        } else {
            state.last_retry_poll = now;
        }
        if (free_slots != 0 and context.modelPreparationOpen()) {
            switch (context.admitRetry()) {
                .admitted => {
                    made_progress = true;
                    state.last_retry_poll = null;
                },
                .no_work => may_admit_new = true,
                .retry_later => state.last_retry_poll = null,
            }
        }
    }
    if (context.providerConfigured() and may_admit_new and context.modelPreparationOpen()) {
        switch (context.admitNewModel()) {
            .admitted => made_progress = true,
            .no_work, .retry_later => {},
        }
    }
    return made_progress;
}

pub fn run(state: *State, context: anytype) Outcome {
    var made_progress = serviceLifecycle(state, context);
    const now = context.now();
    if (!context.dispatchFenced()) {
        const admitted = admitWork(state, context, now) catch return .terminate;
        if (admitted) made_progress = true;
    }
    if (serviceLifecycle(state, context)) made_progress = true;
    state.capacity_was_full = context.freeSlots() == 0;
    if (context.hasTransport()) {
        context.driveTransport() catch return .terminate;
    }
    if (context.serviceOneCompletion()) made_progress = true;
    if (serviceLifecycle(state, context)) made_progress = true;
    const allowance = context.modelPreparationAllowance();
    if (context.advanceModelPreparation(allowance.bytes, allowance.items)) made_progress = true;
    if (made_progress) return .continue_immediately;
    if (context.hasTransport()) return .{ .wait = .transport };
    if (context.hasBash()) return .{ .wait = .bash };
    return .{ .wait = .idle };
}

const Phase = enum {
    lifecycle,
    recover_action,
    admit_bash,
    recover_retry,
    admit_retry,
    admit_new,
    drive,
    completion,
    bash_preparation,
    live_bash,
    ordinary_cleanup,
    retained_cleanup,
    reconcile,
    model_preparation,
};

fn timestamp(ns: i96) std.Io.Clock.Timestamp {
    return std.Io.Timestamp.fromNanoseconds(ns).withClock(.awake);
}

const Recording = struct {
    now_ns: i96 = 0,
    auto_advance: i96 = 1,
    hint: bool = false,
    fenced: bool = false,
    provider: bool = true,
    free: usize = 1,
    bash_prep_open: bool = true,
    model_prep_open: bool = true,
    transport: bool = false,
    bash: bool = false,
    recover_action: bool = false,
    recover_retry: bool = false,
    recover_action_fence: bool = false,
    recover_retry_fence: bool = false,
    drive_fence: bool = false,
    bash_admission: Admission = .no_work,
    retry_admission: Admission = .no_work,
    new_admission: Admission = .no_work,
    completions_available: usize = 0,
    completions_consumed: usize = 0,
    model_advances: usize = 0,
    model_prep_progress: bool = false,
    bash_prep_advance: i96 = 0,
    last_allowance: Allowance = .{ .bytes = 0, .items = 0 },
    configured_allowance: Allowance = .{ .bytes = 16 * 1024, .items = 64 },
    lifecycle_count: usize = 0,
    reconcile_count: usize = 0,
    live_bash_count: usize = 0,
    bash_prep_count: usize = 0,
    ordinary_cleanup_count: usize = 0,
    retained_cleanup_count: usize = 0,
    drive_count: usize = 0,
    now_samples: [32]i96 = undefined,
    now_count: usize = 0,
    order: [128]Phase = undefined,
    order_len: usize = 0,
    lifecycle_now: [32]i96 = undefined,
    live_bash_now: [32]i96 = undefined,

    fn record(self: *Recording, phase: Phase) void {
        self.order[self.order_len] = phase;
        self.order_len += 1;
    }

    fn now(self: *Recording) std.Io.Clock.Timestamp {
        const sample = self.now_ns;
        self.now_samples[self.now_count] = sample;
        self.now_count += 1;
        self.now_ns += self.auto_advance;
        return timestamp(sample);
    }

    fn noteLifecycleOpportunity(self: *Recording) void {
        self.lifecycle_now[self.lifecycle_count] = self.now_ns;
        self.lifecycle_count += 1;
        self.record(.lifecycle);
    }

    fn consumeControlHint(self: *Recording) bool {
        const value = self.hint;
        self.hint = false;
        return value;
    }

    fn reconcileControls(self: *Recording) void {
        self.record(.reconcile);
        self.reconcile_count += 1;
    }

    fn advanceBashPreparation(self: *Recording) bool {
        self.record(.bash_preparation);
        self.bash_prep_count += 1;
        self.now_ns += self.bash_prep_advance;
        return false;
    }

    fn advanceLiveBash(self: *Recording) bool {
        self.record(.live_bash);
        self.live_bash_now[self.live_bash_count] = self.now_ns;
        self.live_bash_count += 1;
        return false;
    }

    fn advanceOrdinaryCleanup(self: *Recording, observed: std.Io.Clock.Timestamp) bool {
        _ = observed;
        self.record(.ordinary_cleanup);
        self.ordinary_cleanup_count += 1;
        return false;
    }

    fn advanceRetainedCleanup(self: *Recording, observed: std.Io.Clock.Timestamp, retry_at: *std.Io.Clock.Timestamp) bool {
        _ = observed;
        _ = retry_at;
        self.record(.retained_cleanup);
        self.retained_cleanup_count += 1;
        return false;
    }

    fn dispatchFenced(self: *const Recording) bool {
        return self.fenced;
    }

    fn providerConfigured(self: *const Recording) bool {
        return self.provider;
    }

    fn freeSlots(self: *const Recording) usize {
        return self.free;
    }

    fn bashPreparationOpen(self: *const Recording) bool {
        return self.bash_prep_open;
    }

    fn modelPreparationOpen(self: *const Recording) bool {
        return self.model_prep_open;
    }

    fn hasTransport(self: *const Recording) bool {
        return self.transport;
    }

    fn hasBash(self: *const Recording) bool {
        return self.bash;
    }

    fn recoverUncertainAction(self: *Recording) error{Fence}!bool {
        self.record(.recover_action);
        if (self.recover_action_fence) return error.Fence;
        return self.recover_action;
    }

    fn recoverExhaustedRetry(self: *Recording) error{Fence}!bool {
        self.record(.recover_retry);
        if (self.recover_retry_fence) return error.Fence;
        return self.recover_retry;
    }

    fn admitBash(self: *Recording) Admission {
        self.record(.admit_bash);
        return self.bash_admission;
    }

    fn admitRetry(self: *Recording) Admission {
        self.record(.admit_retry);
        return self.retry_admission;
    }

    fn admitNewModel(self: *Recording) Admission {
        self.record(.admit_new);
        return self.new_admission;
    }

    fn driveTransport(self: *Recording) error{Fence}!void {
        self.record(.drive);
        self.drive_count += 1;
        if (self.drive_fence) return error.Fence;
    }

    fn serviceOneCompletion(self: *Recording) bool {
        self.record(.completion);
        if (self.completions_available == 0) return false;
        self.completions_available -= 1;
        self.completions_consumed += 1;
        return true;
    }

    fn modelPreparationAllowance(self: *const Recording) Allowance {
        return self.configured_allowance;
    }

    fn advanceModelPreparation(self: *Recording, bytes: usize, items: usize) bool {
        self.record(.model_preparation);
        self.last_allowance = .{ .bytes = bytes, .items = items };
        self.model_advances += 1;
        return self.model_prep_progress;
    }

    fn count(self: *const Recording, phase: Phase) usize {
        var total: usize = 0;
        for (self.order[0..self.order_len]) |entry| {
            if (entry == phase) total += 1;
        }
        return total;
    }

    fn indexOf(self: *const Recording, phase: Phase, occurrence: usize) usize {
        var seen: usize = 0;
        for (self.order[0..self.order_len], 0..) |entry, index| {
            if (entry != phase) continue;
            if (seen == occurrence) return index;
            seen += 1;
        }
        unreachable;
    }
};

fn idle() Recording {
    return .{
        .provider = false,
        .free = 1,
        .bash_prep_open = false,
        .model_prep_open = true,
    };
}

test "one production turn removes at most one provider completion" {
    var context = idle();
    context.completions_available = 3;
    var state: State = .{};
    const outcome = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.completions_consumed);
    try std.testing.expectEqual(@as(usize, 2), context.completions_available);
    try std.testing.expectEqual(Outcome.continue_immediately, outcome);
}

test "a remaining completion burst drains across later turns with lifecycle between removals" {
    var context = idle();
    context.completions_available = 3;
    var state: State = .{};
    var turns: usize = 0;
    while (context.completions_available != 0) : (turns += 1) {
        try std.testing.expect(turns < 8);
        const before = context.completions_available;
        const lifecycle_before = context.lifecycle_count;
        try std.testing.expectEqual(Outcome.continue_immediately, run(&state, &context));
        try std.testing.expectEqual(before - 1, context.completions_available);
        try std.testing.expectEqual(lifecycle_before + 3, context.lifecycle_count);
    }
    try std.testing.expectEqual(@as(usize, 3), turns);
    try std.testing.expectEqual(@as(usize, 3), context.completions_consumed);
}

test "one production turn advances model preparation once with the configured allowance" {
    var context = idle();
    context.model_prep_open = false;
    context.configured_allowance = .{ .bytes = 32, .items = 4 };
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.model_advances);
    try std.testing.expectEqual(@as(usize, 32), context.last_allowance.bytes);
    try std.testing.expectEqual(@as(usize, 4), context.last_allowance.items);
}

test "large preparation requires a later turn rather than draining inside one turn" {
    var context = idle();
    context.model_prep_open = false;
    var state: State = .{};
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 2), context.model_advances);
    try std.testing.expectEqual(@as(usize, 6), context.lifecycle_count);
}

test "lifecycle service still runs when admission, completion, and preparation all make progress" {
    var context = Recording{
        .provider = true,
        .free = 1,
        .completions_available = 2,
        .new_admission = .admitted,
        .configured_allowance = .{ .bytes = 8, .items = 1 },
    };
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 3), context.lifecycle_count);
    try std.testing.expect(context.indexOf(.lifecycle, 0) < context.indexOf(.admit_new, 0));
    try std.testing.expect(context.indexOf(.lifecycle, 1) < context.indexOf(.completion, 0));
    try std.testing.expect(context.indexOf(.lifecycle, 2) < context.indexOf(.model_preparation, 0));
    try std.testing.expectEqual(@as(usize, 1), context.count(.completion));
    try std.testing.expectEqual(@as(usize, 1), context.count(.model_preparation));
}

test "progress from an earlier phase cannot skip a later lifecycle service" {
    var context = Recording{
        .provider = true,
        .free = 1,
        .new_admission = .admitted,
        .completions_available = 1,
    };
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_new));
    try std.testing.expectEqual(@as(usize, 3), context.count(.live_bash));
    try std.testing.expectEqual(@as(usize, 3), context.count(.ordinary_cleanup));
    try std.testing.expectEqual(@as(usize, 3), context.count(.retained_cleanup));
}

test "immediate runnable work selects continuation rather than an idle wait" {
    var context = idle();
    context.completions_available = 1;
    var state: State = .{};
    try std.testing.expectEqual(Outcome.continue_immediately, run(&state, &context));

    context = idle();
    context.model_prep_open = false;
    context.model_prep_progress = true;
    try std.testing.expectEqual(Outcome.continue_immediately, run(&state, &context));
}

test "true idle work selects a wait rather than spinning" {
    var context = idle();
    var state: State = .{};
    try std.testing.expectEqual(Outcome{ .wait = .idle }, run(&state, &context));
    context.bash = true;
    try std.testing.expectEqual(Outcome{ .wait = .bash }, run(&state, &context));
    context.transport = true;
    try std.testing.expectEqual(Outcome{ .wait = .transport }, run(&state, &context));
}

test "absent control hint still reconciles when the fallback deadline is due" {
    var context = idle();
    context.now_ns = 1_000;
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.reconcile_count);
    context.now_ns = 1_000 + 99 * std.time.ns_per_ms;
    context.auto_advance = 0;
    const skipped = run(&state, &context);
    _ = skipped;
    try std.testing.expectEqual(@as(usize, 1), context.reconcile_count);
    context.now_ns = 1_000 + 100 * std.time.ns_per_ms;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 2), context.reconcile_count);
}

test "live Bash observes a later clock than Bash preparation in the same lifecycle service" {
    var context = idle();
    context.now_ns = 100;
    context.auto_advance = 0;
    context.bash_prep_advance = 5;
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(i96, 105), context.live_bash_now[0]);
    try std.testing.expectEqual(@as(i96, 110), context.live_bash_now[1]);
    try std.testing.expectEqual(@as(i96, 115), context.live_bash_now[2]);
}

test "each lifecycle service observes a later clock than earlier bounded work" {
    var context = Recording{
        .now_ns = 99,
        .auto_advance = 2,
        .provider = true,
        .free = 1,
        .new_admission = .admitted,
        .completions_available = 1,
    };
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expect(context.lifecycle_now[1] > context.lifecycle_now[0]);
    try std.testing.expect(context.lifecycle_now[2] > context.lifecycle_now[1]);
    try std.testing.expect(context.indexOf(.live_bash, 1) > context.indexOf(.admit_new, 0));
    try std.testing.expect(context.indexOf(.live_bash, 2) > context.indexOf(.completion, 0));
}

test "retry admission runs when the poll is due and suppresses new-model admission until it reports no work" {
    var context = Recording{
        .provider = true,
        .free = 1,
        .retry_admission = .retry_later,
        .new_admission = .admitted,
    };
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.count(.recover_retry));
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_retry));
    try std.testing.expectEqual(@as(usize, 0), context.count(.admit_new));

    context.retry_admission = .no_work;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_new));
}

test "capacity release after a full turn schedules retry maintenance" {
    var context = Recording{
        .now_ns = std.time.ns_per_s,
        .provider = true,
        .free = 0,
        .retry_admission = .admitted,
        .new_admission = .admitted,
    };
    var state: State = .{ .capacity_was_full = false, .last_retry_poll = timestamp(0) };
    _ = run(&state, &context);
    try std.testing.expect(state.capacity_was_full);
    try std.testing.expectEqual(@as(usize, 0), context.count(.admit_retry));

    context.free = 1;
    context.order_len = 0;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_retry));
    try std.testing.expectEqual(@as(usize, 0), context.count(.admit_new));
}

test "occupied model preparation skips retry and new-model admission" {
    var context = Recording{
        .provider = true,
        .free = 1,
        .model_prep_open = false,
        .retry_admission = .admitted,
        .new_admission = .admitted,
    };
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 0), context.count(.admit_retry));
    try std.testing.expectEqual(@as(usize, 0), context.count(.admit_new));
}

test "Bash admission uses a free slot without sharing the model-preparation quota" {
    var context = Recording{
        .provider = true,
        .free = 1,
        .model_prep_open = false,
        .bash_admission = .admitted,
        .new_admission = .admitted,
    };
    var state: State = .{};
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_bash));
    try std.testing.expectEqual(@as(usize, 3), context.count(.bash_preparation));
    try std.testing.expectEqual(@as(usize, 1), context.count(.model_preparation));
}

test "a fenced recover does not launch later work in the same turn" {
    var context = Recording{
        .provider = true,
        .free = 1,
        .recover_action_fence = true,
        .new_admission = .admitted,
        .completions_available = 2,
        .transport = true,
    };
    var state: State = .{};
    try std.testing.expectEqual(Outcome.terminate, run(&state, &context));
    try std.testing.expectEqual(@as(usize, 0), context.count(.admit_new));
    try std.testing.expectEqual(@as(usize, 0), context.count(.completion));
    try std.testing.expectEqual(@as(usize, 0), context.drive_count);
    try std.testing.expectEqual(@as(usize, 1), context.lifecycle_count);
}
