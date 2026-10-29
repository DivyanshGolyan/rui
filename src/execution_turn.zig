const std = @import("std");
const deadline = @import("deadline.zig");

pub const control_reconciliation_interval_ms = 100;
pub const retained_cleanup_retry_ms = 100;
pub const retry_poll_interval_ns: u64 = std.time.ns_per_s;

pub const Admission = enum { no_work, retry_later, admitted };
const Kind = enum { bash, retry, message, tool_continuation };

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

/// Every fact the Bash, message and tool-continuation scans depend on
/// besides Store rows; the rows move the commit generation.
const AdmissionKey = struct { generation: u64, free_slots: usize, bash_open: bool, model_open: bool };

pub const State = struct {
    preference: [4]Kind = .{ .bash, .retry, .message, .tool_continuation },
    retry_admission_due: bool = true,
    last_retry_poll: ?std.Io.Clock.Timestamp = null,
    next_control_reconciliation: ?std.Io.Clock.Timestamp = null,
    /// Commit generation read before the last complete reconciliation.
    reconciled_generation: ?u64 = null,
    /// An Action loses custody unsettled only once dispatch is fenced or the
    /// Host shuts down, so uncertain Actions come only from an earlier Host.
    uncertain_action_scan_exhausted: bool = false,
    /// Admission facts before the last pass whose Bash, message and
    /// tool-continuation scans all found nothing. Those scans read only
    /// Store rows, so they rerun only once a fact changes. Retry admission
    /// is due by time instead and keeps its own poll.
    idle_admission: ?AdmissionKey = null,
    retained_cleanup_at: ?std.Io.Clock.Timestamp = null,
    capacity_was_full: bool = false,
};

fn due(at: ?std.Io.Clock.Timestamp, now: std.Io.Clock.Timestamp) bool {
    return if (at) |value| deadline.reached(now, value) else true;
}

pub fn serviceLifecycle(state: *State, context: anytype) bool {
    context.noteLifecycleOpportunity();
    const now = context.now();
    const hint = context.consumeControlHint();
    var made_progress = false;
    if (hint or due(state.next_control_reconciliation, now)) {
        // A lost hint still follows its control's commit, so the fallback
        // reads controls only after the generation moved.
        const generation = context.commitGeneration();
        if (hint or state.reconciled_generation != generation) {
            context.reconcileControls();
            state.reconciled_generation = generation;
        }
        state.next_control_reconciliation = deadline.after(now, control_reconciliation_interval_ms);
        made_progress = hint;
    }
    if (context.advanceBashPreparation()) made_progress = true;
    if (context.advanceLiveBash()) made_progress = true;
    if (state.retained_cleanup_at == null) state.retained_cleanup_at = now;
    if (context.advanceRetainedCleanup(now, &state.retained_cleanup_at.?)) made_progress = true;
    return made_progress;
}

fn admitWork(state: *State, context: anytype, now: std.Io.Clock.Timestamp) error{Fence}!bool {
    var made_progress = false;
    const capacity_released = state.capacity_was_full and context.freeSlots() != 0;
    const retry_poll_due = if (state.last_retry_poll) |last|
        last.durationTo(now).raw.nanoseconds >= retry_poll_interval_ns
    else
        true;
    if (!state.uncertain_action_scan_exhausted) {
        if (try context.recoverUncertainAction()) made_progress = true else state.uncertain_action_scan_exhausted = true;
    }
    const maintain_retries = context.providerConfigured() and (retry_poll_due or capacity_released);
    if (maintain_retries) {
        state.retry_admission_due = true;
        if (try context.recoverExhaustedRetry()) {
            made_progress = true;
            state.last_retry_poll = null;
        } else {
            state.last_retry_poll = now;
        }
    }
    const admission_key: AdmissionKey = .{
        .generation = context.commitGeneration(),
        .free_slots = context.freeSlots(),
        .bash_open = context.bashPreparationOpen(),
        .model_open = context.modelPreparationOpen(),
    };
    const scanned = if (state.idle_admission) |previous| std.meta.eql(previous, admission_key) else false;
    var found_nothing = true;
    for (state.preference, 0..) |kind, index| {
        if (context.dispatchFenced() or context.freeSlots() == 0) {
            found_nothing = false;
            break;
        }
        if (scanned and kind != .retry) continue;
        const admission = switch (kind) {
            .bash => if (context.bashPreparationOpen()) context.admitBash() else continue,
            .retry, .message, .tool_continuation => blk: {
                if (!context.providerConfigured() or !context.modelPreparationOpen()) continue;
                break :blk switch (kind) {
                    .retry => if (state.retry_admission_due) context.admitRetry() else continue,
                    .message => context.admitNewModel(),
                    .tool_continuation => context.admitToolContinuation(),
                    .bash => unreachable,
                };
            },
        };
        if (kind == .retry) state.retry_admission_due = admission != .no_work;
        if (kind != .retry and admission != .no_work) found_nothing = false;
        if (admission == .admitted) {
            // Only a committed winner moves. Skipped kinds keep their place,
            // including while their shared preparation owner is occupied.
            std.mem.copyForwards(Kind, state.preference[index .. state.preference.len - 1], state.preference[index + 1 ..]);
            state.preference[state.preference.len - 1] = kind;
            state.idle_admission = null;
            return true;
        }
    }
    state.idle_admission = if (found_nothing) admission_key else null;
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
    admit_continuation,
    drive,
    completion,
    bash_preparation,
    live_bash,
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
    // Each read observes a new commit unless a test holds the Store still.
    generation: u64 = 0,
    generation_advance: u64 = 1,
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
    continuation_admission: Admission = .no_work,
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
    retained_cleanup_count: usize = 0,
    drive_count: usize = 0,
    now_samples: [128]i96 = undefined,
    now_count: usize = 0,
    order: [512]Phase = undefined,
    order_len: usize = 0,
    lifecycle_now: [64]i96 = undefined,
    live_bash_now: [64]i96 = undefined,

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

    fn commitGeneration(self: *Recording) u64 {
        self.generation += self.generation_advance;
        return self.generation;
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

    fn admitToolContinuation(self: *Recording) Admission {
        self.record(.admit_continuation);
        return self.continuation_admission;
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
    // Without a commit, a due fallback has nothing a lost hint could hide.
    context.generation_advance = 0;
    context.generation += 1;
    context.now_ns = 1_000 + 300 * std.time.ns_per_ms;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 3), context.reconcile_count);
    context.now_ns = 1_000 + 500 * std.time.ns_per_ms;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 3), context.reconcile_count);
    context.hint = true;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 4), context.reconcile_count);
    // A commit whose hint was lost is found by the next due fallback.
    context.generation += 1;
    context.now_ns = 1_000 + 700 * std.time.ns_per_ms;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 5), context.reconcile_count);
}

test "uncertain Action recovery scans until one scan finds none" {
    var context = idle();
    context.recover_action = true;
    var state: State = .{};
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 2), context.count(.recover_action));
    context.recover_action = false;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 3), context.count(.recover_action));
    // Commits and released slots cannot create another uncertain Action.
    context.free = 2;
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 3), context.count(.recover_action));
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

test "sustained messages cannot starve a tool continuation after preparation reopens" {
    var state: State = .{};
    var first = Recording{ .new_admission = .admitted, .continuation_admission = .admitted };
    _ = run(&state, &first);
    try std.testing.expectEqual(@as(usize, 1), first.count(.admit_new));

    var closed = Recording{ .model_prep_open = false, .bash_admission = .admitted };
    _ = run(&state, &closed);
    var reopened = Recording{ .new_admission = .admitted, .continuation_admission = .admitted };
    _ = run(&state, &reopened);
    try std.testing.expectEqual(@as(usize, 1), reopened.count(.admit_continuation));
    try std.testing.expectEqual(@as(usize, 0), reopened.count(.admit_new));
}

test "rolled back retry admission does not suppress other kinds or lose preference" {
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
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_new));

    context.retry_admission = .admitted;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 2), context.count(.admit_retry));
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

test "admission scans rerun only after a commit, a released slot or a reopened preparation" {
    var context = Recording{ .provider = true, .free = 1, .generation_advance = 0 };
    var state: State = .{};
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_bash));
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_new));
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_continuation));
    context.generation += 1;
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 2), context.count(.admit_new));
    context.free = 2;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 3), context.count(.admit_new));
    // A shared preparation owner reopening needs no commit.
    context.model_prep_open = false;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 4), context.count(.admit_bash));
    try std.testing.expectEqual(@as(usize, 3), context.count(.admit_new));
    context.model_prep_open = true;
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 4), context.count(.admit_new));
    try std.testing.expectEqual(@as(usize, 4), context.count(.admit_continuation));
    try std.testing.expectEqual(@as(usize, 5), context.count(.admit_bash));
    context.bash_prep_open = false;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 5), context.count(.admit_new));
    context.bash_prep_open = true;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 6), context.count(.admit_bash));
}

test "an admission that must retry later keeps scanning without a commit" {
    var context = Recording{ .provider = true, .free = 1, .generation_advance = 0, .continuation_admission = .retry_later };
    var state: State = .{};
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 2), context.count(.admit_continuation));
    try std.testing.expectEqual(@as(usize, 2), context.count(.admit_new));
    context.continuation_admission = .no_work;
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 3), context.count(.admit_continuation));
}

test "retry admission keeps its own poll while the commit-gated scans wait" {
    var context = Recording{ .provider = true, .free = 1, .generation_advance = 0, .auto_advance = 0 };
    var state: State = .{};
    _ = run(&state, &context);
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_retry));
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_new));
    context.now_ns += retry_poll_interval_ns;
    _ = run(&state, &context);
    try std.testing.expectEqual(@as(usize, 2), context.count(.recover_retry));
    try std.testing.expectEqual(@as(usize, 2), context.count(.admit_retry));
    try std.testing.expectEqual(@as(usize, 1), context.count(.admit_new));
}
