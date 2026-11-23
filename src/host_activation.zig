const std = @import("std");
const protocol = @import("protocol.zig");
const start_report = @import("start_report.zig");
const settings_handoff = @import("host_settings_handoff.zig");

/// Why a running Host was left as it is.
pub const Limitation = enum {
    inaccessible,
    incompatible,
    ownership_status,
    ownership_observation,
    ownership_directory_unavailable,
    ownership_directory_mismatch,
    ownership_confirmation,
    application_owned,
    configuration_unavailable,
    target_capability,
};

/// The steps after a Host was asked to stop.
pub const Stage = enum { stopping, awaiting_retirement, starting, verifying };

/// The target-build steps before any stop; a failure there leaves the Host untouched.
pub const TargetStep = enum { resolving, checking };

/// How one Host's restart ended. `HostLifecycle` re-exports it as
/// `ActivationOutcome`; `host_coordinator` serializes it by field name.
pub const Outcome = union(enum) {
    not_needed,
    superseded,
    already_ready: struct { instance: protocol.InstanceId, pid: c_int },
    ready: struct { instance: protocol.InstanceId, pid: c_int },
    /// Target public status, answering peer release and new instance were
    /// verified; only the calling client's wire is incompatible.
    client_incompatible: c_int,
    unsupported: Limitation,
    replacement_observed,
    cancelled,
    /// The target build could not be resolved or checked; nothing was stopped (#1791, #1793).
    target_unusable: TargetStep,
    refused: struct { stage: enum { checking, starting }, failure: start_report.Failure },
    failed: Stage,
    unconfirmed: Stage,
};

/// What a running Host's observation has read so far; `null` is not read yet.
/// The shell reads each fact in the order `eligibility` asks for it.
pub const Seen = struct {
    /// The Host's public status over its socket.
    status: ?enum { unavailable, owned_unavailable, access_failure, incompatible, ready } = null,
    /// Its Host information answered with a process id.
    observed: ?bool = null,
    /// Its process executable, argv and environment were read.
    snapshot: ?bool = null,
    /// Its executable is a managed build with a release version.
    managed: ?bool = null,
    /// Its captured environment can be passed to a replacement.
    environment: ?bool = null,
    /// Its argv names restartable sources with an absolute Host directory.
    sources: ?bool = null,
    /// That directory, canonicalized, against the one the Host answers for.
    directory: ?enum { unavailable, mismatch, same } = null,
    /// A second read found the same Host in the same process generation.
    confirmed: ?bool = null,
};

/// The next fact an observation reads, or what the running Host is.
pub const Eligibility = union(enum) {
    read: enum { status, observe, snapshot, version, environment, sources, directory, confirm },
    absent,
    unsupported: Limitation,
    managed,
};

/// Whether a running Host may be offered for restart. The first fact that
/// fails names the limitation; a Host with no owner is absent.
pub fn eligibility(seen: Seen) Eligibility {
    switch (seen.status orelse return .{ .read = .status }) {
        .unavailable => return .absent,
        .owned_unavailable => return .{ .unsupported = .ownership_status },
        .access_failure => return .{ .unsupported = .inaccessible },
        .incompatible, .ready => {},
    }
    if (!(seen.observed orelse return .{ .read = .observe })) return .{ .unsupported = .ownership_observation };
    if (!(seen.snapshot orelse return .{ .read = .snapshot })) return .{ .unsupported = .configuration_unavailable };
    if (!(seen.managed orelse return .{ .read = .version })) return .{ .unsupported = .application_owned };
    if (!(seen.environment orelse return .{ .read = .environment })) return .{ .unsupported = .configuration_unavailable };
    if (!(seen.sources orelse return .{ .read = .sources })) return .{ .unsupported = .configuration_unavailable };
    switch (seen.directory orelse return .{ .read = .directory }) {
        .unavailable => return .{ .unsupported = .ownership_directory_unavailable },
        .mismatch => return .{ .unsupported = .ownership_directory_mismatch },
        .same => {},
    }
    if (!(seen.confirmed orelse return .{ .read = .confirm })) return .{ .unsupported = .ownership_confirmation };
    return .managed;
}

/// A re-read of the running Host against what was observed: unreadable, a
/// different Host or process, or the same one.
pub const Reading = enum { unreadable, changed, same };

/// The running Host a restart found already on the target executable.
pub const Running = @FieldType(Outcome, "already_ready");

/// A running Host on the target executable, with the settings digest it reports
/// (`null` when it reports none, as a foreground `host serve` does). The same
/// build restarts only when a reported digest differs from the target's checked
/// frame; a Host that reports none stays as it is.
pub const Same = struct { running: Running, settings: ?settings_handoff.Digest };

/// What one Host's activation has read and done so far; `null` is not yet.
/// The shell fills the field of the effect `next` named.
pub const Facts = struct {
    /// The observation, with the managed Host's facts that need no read.
    eligibility: union(enum) {
        absent,
        unsupported: Limitation,
        managed: struct {
            /// The running Host's version against the target's.
            order: std.math.Order,
            /// Every captured environment entry has a name and a value.
            environment_parses: bool,
        },
    },
    /// Whether the Host restart-all listed is still the one observed now.
    census: enum { same, replaced } = .same,
    /// A target step the shell could not complete; set only for the step `next` asked for.
    target_failed: ?TargetStep = null,
    /// The target's executable resolves to the running one.
    same_executable: ?bool = null,
    /// Read only when the executable is the same.
    current: ?union(enum) { unreadable, changed, same: Same } = null,
    /// The running Host's sources were reconstructed for the target.
    sources: ?bool = null,
    /// The target's public settings check; `ok` carries the digest of the frame it printed.
    check: ?union(enum) {
        cancelled,
        /// It could not run or did not finish in time.
        unavailable,
        refused: start_report.Failure,
        untyped,
        bad_frame,
        ok: settings_handoff.Digest,
    } = null,
    before_stop: ?Reading = null,
    snapshot: ?Reading = null,
    stop: ?enum { failed, instance_changed, done } = null,
    retired: ?bool = null,
    start: ?union(enum) { unavailable, refused: start_report.Failure, untyped, started } = null,
    /// The verification's outcome.
    proof: ?Outcome = null,
};

/// The next effect of one activation, or how it ended.
pub const Effect = union(enum) {
    resolve_target,
    confirm_current,
    reconstruct_sources,
    check_target,
    reobserve,
    snapshot,
    /// The point of no return: every check before it held.
    stop,
    await_retirement,
    start,
    verify,
    done: Outcome,
};

/// The running Host a same-build activation leaves current when the target gives no
/// settings frame to compare: one on the target executable that reports a digest.
fn keptRunning(facts: Facts) ?Running {
    if (facts.same_executable != true) return null;
    return switch (facts.current orelse return null) {
        .same => |value| if (value.settings != null) value.running else null,
        else => null,
    };
}

fn keep(kept: ?Running, outcome: Outcome) Effect {
    return .{ .done = if (kept) |running| .{ .already_ready = running } else outcome };
}

/// One Host's activation, in the order its checks run. `cancelled` is the
/// caller's stop as the shell polls it now; it is read only before the
/// target is resolved and between the check and the stop.
pub fn next(facts: Facts, cancelled: bool) Effect {
    const managed = switch (facts.eligibility) {
        .absent => return .{ .done = .not_needed },
        .unsupported => |reason| return .{ .done = .{ .unsupported = reason } },
        .managed => |value| value,
    };
    if (facts.census == .replaced) return .{ .done = .replacement_observed };
    if (cancelled and facts.same_executable == null) return .{ .done = .cancelled };
    if (managed.order == .gt) return .{ .done = .superseded };
    if (!managed.environment_parses) return .{ .done = .{ .unsupported = .configuration_unavailable } };
    // A Host already on the target that reports its settings is restarted only for a
    // checked frame that differs; a target step that gives no frame leaves it current.
    const kept = keptRunning(facts);
    if (facts.target_failed) |step| return keep(kept, .{ .target_unusable = step });
    const same = facts.same_executable orelse return .resolve_target;
    var running: ?Same = null;
    if (same) running = switch (facts.current orelse return .confirm_current) {
        .unreadable => return .{ .done = .{ .unconfirmed = .verifying } },
        .changed => return .{ .done = .replacement_observed },
        // A Host that reports no settings (a foreground `host serve`, or a
        // build before the digest) has nothing to compare: the same build stays.
        .same => |value| if (value.settings == null) return .{ .done = .{ .already_ready = value.running } } else value,
    };
    if (!(facts.sources orelse return .reconstruct_sources)) return keep(kept, .{ .unsupported = .configuration_unavailable });
    const checked: settings_handoff.Digest = switch (facts.check orelse return .check_target) {
        .cancelled => return .{ .done = .cancelled },
        .unavailable => return keep(kept, .{ .target_unusable = .checking }),
        .refused => |failure| return keep(kept, .{ .refused = .{ .stage = .checking, .failure = failure } }),
        .untyped, .bad_frame => return keep(kept, .{ .unsupported = .target_capability }),
        .ok => |digest| digest,
    };
    // The same build is restarted only when its saved settings changed since it started.
    if (running) |same_host| if (std.mem.eql(u8, &same_host.settings.?, &checked)) return .{ .done = .{ .already_ready = same_host.running } };
    if (cancelled and facts.before_stop == null) return .{ .done = .cancelled };
    switch (facts.before_stop orelse return .reobserve) {
        .unreadable => return .{ .done = .{ .unconfirmed = .stopping } },
        .changed => return .{ .done = .replacement_observed },
        .same => {},
    }
    switch (facts.snapshot orelse return .snapshot) {
        .unreadable => return .{ .done = .{ .unconfirmed = .stopping } },
        .changed => return .{ .done = .{ .unsupported = .configuration_unavailable } },
        .same => {},
    }
    switch (facts.stop orelse return .stop) {
        .failed => return .{ .done = .{ .unconfirmed = .stopping } },
        .instance_changed => return .{ .done = .replacement_observed },
        .done => {},
    }
    if (!(facts.retired orelse return .await_retirement)) return .{ .done = .{ .unconfirmed = .awaiting_retirement } };
    switch (facts.start orelse return .start) {
        .unavailable => return .{ .done = .{ .unconfirmed = .starting } },
        .refused => |failure| return .{ .done = .{ .refused = .{ .stage = .starting, .failure = failure } } },
        .untyped => return .{ .done = .{ .failed = .starting } },
        .started => {},
    }
    return .{ .done = facts.proof orelse return .verify };
}

/// A Host's identity as its Host information and status report it.
pub const Identity = struct {
    instance: protocol.InstanceId,
    store: []const u8,
    capacity: usize,

    fn eql(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, &a.instance, &b.instance) and std.mem.eql(u8, a.store, b.store) and a.capacity == b.capacity;
    }
};

/// One verification pass after a start; `null` is not read yet.
pub const Probe = struct {
    /// The Host that was stopped, as observed before the stop.
    stopped: Identity,
    /// A peer process answered on the Store before the status command.
    before: ?bool = null,
    /// The target's public status command.
    status: ?union(enum) {
        /// It could not run.
        unavailable,
        /// It ran and failed, or printed no replacement facts.
        unanswered,
        answered: Identity,
    } = null,
    /// The peer read after the command is the one read before it.
    after: ?bool = null,
    /// The answering executable's managed release version against the target.
    version: ?union(enum) { unknown, order: std.math.Order } = null,
    /// This client's own status read of the Store.
    own: ?union(enum) { unavailable, incompatible, ready: Identity } = null,
    /// The last peer read, when it is the process read after the command.
    final: ?union(enum) { differs, same: c_int } = null,
};

/// The next read of a verification pass, or its verdict. `again` waits for
/// the shell's next pass; the shell owns the clock and its deadline.
pub const Verdict = union(enum) {
    read: enum { before, status, after, version, own, final },
    again,
    done: Outcome,
};

/// A replacement is ready only on complete proof: a new instance of the
/// stopped Host's Store and capacity, answered by a managed executable of
/// the target version between equal peer readings, which this client's
/// own status read confirms or cannot speak.
pub fn verdict(probe: Probe) Verdict {
    if (!(probe.before orelse return .{ .read = .before })) return .again;
    const answered = switch (probe.status orelse return .{ .read = .status }) {
        .unavailable => return .{ .done = .{ .unconfirmed = .verifying } },
        .unanswered => return .again,
        .answered => |identity| identity,
    };
    if (!(probe.after orelse return .{ .read = .after })) return .again;
    const order = switch (probe.version orelse return .{ .read = .version }) {
        .unknown => return .{ .done = .{ .unconfirmed = .verifying } },
        .order => |value| value,
    };
    if (order != .eq or std.mem.eql(u8, &answered.instance, &probe.stopped.instance) or
        !std.mem.eql(u8, answered.store, probe.stopped.store) or answered.capacity != probe.stopped.capacity) return .{ .done = .replacement_observed };
    const own = probe.own orelse return .{ .read = .own };
    switch (own) {
        .unavailable => return .again,
        .incompatible => {},
        .ready => |identity| if (!identity.eql(answered)) return .again,
    }
    const pid = switch (probe.final orelse return .{ .read = .final }) {
        .differs => return .again,
        .same => |value| value,
    };
    return .{ .done = if (own == .incompatible) .{ .client_incompatible = pid } else .{ .ready = .{ .instance = answered.instance, .pid = pid } } };
}

/// The count an outcome falls in on the restart report.
pub const Category = enum { restarted, current, skipped, failed };

/// A restart report's counts, one per Host.
pub const Counts = struct {
    restarted: usize = 0,
    current: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,

    pub fn add(self: *Counts, kind: Category) void {
        switch (kind) {
            .restarted => self.restarted += 1,
            .current => self.current += 1,
            .skipped => self.skipped += 1,
            .failed => self.failed += 1,
        }
    }
};

pub fn category(outcome: Outcome) Category {
    return switch (outcome) {
        .ready, .client_incompatible => .restarted,
        .already_ready => .current,
        .superseded, .not_needed, .unsupported => .skipped,
        .replacement_observed, .cancelled, .target_unusable, .failed, .unconfirmed, .refused => .failed,
    };
}

/// Whether the outcome leaves recovery instructions for the person.
pub fn guides(outcome: Outcome) bool {
    return switch (outcome) {
        .unsupported, .replacement_observed, .cancelled, .target_unusable, .failed, .unconfirmed, .refused => true,
        .not_needed, .superseded, .already_ready, .ready, .client_incompatible => false,
    };
}

/// Whether a client may keep talking to its own Store's Host after this outcome.
pub fn clientSafe(outcome: Outcome) bool {
    return switch (outcome) {
        .client_incompatible, .unconfirmed, .failed, .replacement_observed, .refused => false,
        .not_needed, .superseded, .already_ready, .ready, .unsupported, .cancelled, .target_unusable => true,
    };
}

/// One restart-batch entry, placed against the client's Store by the shell:
/// `own` when its Host directory (or Store) is the client's, `unlocated` when
/// the entry names neither.
pub const Line = struct {
    place: enum { own, other, unlocated },
    state: union(enum) { outcome: Outcome, failed },
};

/// A batch that could not finish as a whole.
pub const BatchFailure = enum { cancelled, other };

/// What a restart batch amounts to.
pub const Summary = struct {
    counts: Counts,
    guidance: bool,
    /// The client's own Store's outcome; an entry that failed there is unconfirmed.
    own: Outcome,
};

/// Folds a batch's lines in order. Every line counts once; only the first
/// line placed at the client's own Store decides that Store's outcome.
pub const Tally = struct {
    counts: Counts = .{},
    guidance: bool = false,
    own: ?Outcome = null,
    unlocated: bool = false,

    pub fn add(self: *Tally, line: Line) void {
        const outcome: ?Outcome = switch (line.state) {
            .outcome => |value| value,
            .failed => null,
        };
        self.counts.add(if (outcome) |value| category(value) else .failed);
        self.guidance = self.guidance or (if (outcome) |value| guides(value) else true);
        switch (line.place) {
            .own => if (self.own == null) {
                self.own = outcome orelse .{ .unconfirmed = .verifying };
            },
            .other => {},
            .unlocated => self.unlocated = true,
        }
    }

    pub fn finish(self: Tally, failure: ?BatchFailure) Summary {
        var counts = self.counts;
        if (failure != null) counts.add(.failed);
        return .{
            .counts = counts,
            .guidance = self.guidance or failure != null,
            .own = self.own orelse if (failure == .cancelled)
                .cancelled
            else if (self.unlocated or failure != null)
                .{ .unconfirmed = .verifying }
            else
                .not_needed,
        };
    }
};

/// The base commit's per-outcome answers (531600a53): `host_restart_all.category`,
/// `host_restart_all.Batch.hasGuidance` and `upgrade.compatible`, typed by hand.
const sh60 = struct {
    const Row = struct { outcome: Outcome, category: Category, guides: bool, safe: bool };
    const failure = start_report.Failure.init(.settings_invalid, "typed refusal");
    const rows = [_]Row{
        .{ .outcome = .not_needed, .category = .skipped, .guides = false, .safe = true },
        .{ .outcome = .superseded, .category = .skipped, .guides = false, .safe = true },
        .{ .outcome = .{ .already_ready = .{ .instance = @splat(1), .pid = 42 } }, .category = .current, .guides = false, .safe = true },
        .{ .outcome = .{ .ready = .{ .instance = @splat(2), .pid = 43 } }, .category = .restarted, .guides = false, .safe = true },
        .{ .outcome = .{ .client_incompatible = 44 }, .category = .restarted, .guides = false, .safe = false },
        .{ .outcome = .{ .unsupported = .inaccessible }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .incompatible }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .ownership_status }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .ownership_observation }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .ownership_directory_unavailable }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .ownership_directory_mismatch }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .ownership_confirmation }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .application_owned }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .configuration_unavailable }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .{ .unsupported = .target_capability }, .category = .skipped, .guides = true, .safe = true },
        .{ .outcome = .replacement_observed, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .cancelled, .category = .failed, .guides = true, .safe = true },
        .{ .outcome = .{ .target_unusable = .resolving }, .category = .failed, .guides = true, .safe = true },
        .{ .outcome = .{ .target_unusable = .checking }, .category = .failed, .guides = true, .safe = true },
        .{ .outcome = .{ .refused = .{ .stage = .checking, .failure = failure } }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .refused = .{ .stage = .starting, .failure = failure } }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .failed = .stopping }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .failed = .awaiting_retirement }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .failed = .starting }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .failed = .verifying }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .unconfirmed = .stopping }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .unconfirmed = .awaiting_retirement }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .unconfirmed = .starting }, .category = .failed, .guides = true, .safe = false },
        .{ .outcome = .{ .unconfirmed = .verifying }, .category = .failed, .guides = true, .safe = false },
    };

    fn expectSummary(expected: struct { restarted: usize = 0, current: usize = 0, skipped: usize = 0, failed: usize = 0, guidance: bool, own: Outcome, safe: bool }, actual: Summary) !void {
        try std.testing.expectEqual(expected.restarted, actual.counts.restarted);
        try std.testing.expectEqual(expected.current, actual.counts.current);
        try std.testing.expectEqual(expected.skipped, actual.counts.skipped);
        try std.testing.expectEqual(expected.failed, actual.counts.failed);
        try std.testing.expectEqual(expected.guidance, actual.guidance);
        try std.testing.expect(std.meta.eql(expected.own, actual.own));
        try std.testing.expectEqual(expected.safe, clientSafe(actual.own));
    }
};

test "SH-69 every outcome counts once and only the client's own Store decides its safety" {
    var covered: std.EnumSet(std.meta.Tag(Outcome)) = .empty;
    for (sh60.rows) |row| {
        covered.insert(std.meta.activeTag(row.outcome));
        try std.testing.expectEqual(row.category, category(row.outcome));
        try std.testing.expectEqual(row.guides, guides(row.outcome));
        try std.testing.expectEqual(row.safe, clientSafe(row.outcome));
    }
    try std.testing.expectEqual(std.meta.tags(std.meta.Tag(Outcome)).len, covered.count());

    // One entry, an outcome or a failed entry, at each place, under each batch
    // failure. The client's outcome is its own entry's; with none it is
    // cancelled for a cancelled batch, unconfirmed when an entry is unlocated
    // or the batch failed, and otherwise no restart was needed.
    const failures = [_]?BatchFailure{ null, .cancelled, .other };
    for (0..sh60.rows.len + 1) |index| {
        const row: ?sh60.Row = if (index < sh60.rows.len) sh60.rows[index] else null;
        for ([_]@FieldType(Line, "place"){ .own, .other, .unlocated }) |place| for (failures) |failure| {
            var tally: Tally = .{};
            tally.add(.{ .place = place, .state = if (row) |value| .{ .outcome = value.outcome } else .failed });
            const own: Outcome = if (place == .own)
                (if (row) |value| value.outcome else .{ .unconfirmed = .verifying })
            else if (failure == .cancelled)
                .cancelled
            else if (place == .unlocated or failure != null)
                .{ .unconfirmed = .verifying }
            else
                .not_needed;
            const own_safe = for (sh60.rows) |candidate| {
                if (std.meta.eql(candidate.outcome, own)) break candidate.safe;
            } else unreachable;
            const kind: Category = if (row) |value| value.category else .failed;
            const batch_failed: usize = @intFromBool(failure != null);
            try sh60.expectSummary(.{
                .restarted = @intFromBool(kind == .restarted),
                .current = @intFromBool(kind == .current),
                .skipped = @intFromBool(kind == .skipped),
                .failed = @intFromBool(kind == .failed) + batch_failed,
                .guidance = (if (row) |value| value.guides else true) or failure != null,
                .own = own,
                .safe = own_safe,
            }, tally.finish(failure));
        };
    }

    // Whole batches, moved from the former `upgrade.zig` test "upgrade restart results retain unknown
    // failures and other Store guidance without borrowing compatibility".
    const ready: Outcome = .{ .ready = .{ .instance = @splat(1), .pid = 42 } };
    const Batch = struct { lines: []const Line, failure: ?BatchFailure = null, restarted: usize = 0, current: usize = 0, skipped: usize = 0, failed: usize = 0, guidance: bool, own: Outcome, safe: bool };
    for ([_]Batch{
        .{ .lines = &.{}, .guidance = false, .own = .not_needed, .safe = true },
        .{ .lines = &.{}, .failure = .other, .failed = 1, .guidance = true, .own = .{ .unconfirmed = .verifying }, .safe = false },
        .{ .lines = &.{}, .failure = .cancelled, .failed = 1, .guidance = true, .own = .cancelled, .safe = true },
        .{ .lines = &.{
            .{ .place = .other, .state = .{ .outcome = .{ .client_incompatible = 123 } } },
            .{ .place = .own, .state = .{ .outcome = ready } },
        }, .restarted = 2, .guidance = false, .own = ready, .safe = true },
        .{ .lines = &.{
            .{ .place = .other, .state = .{ .outcome = .{ .failed = .starting } } },
            .{ .place = .own, .state = .{ .outcome = ready } },
        }, .restarted = 1, .failed = 1, .guidance = true, .own = ready, .safe = true },
        .{ .lines = &.{
            .{ .place = .unlocated, .state = .failed },
            .{ .place = .own, .state = .{ .outcome = ready } },
        }, .restarted = 1, .failed = 1, .guidance = true, .own = ready, .safe = true },
        .{ .lines = &.{
            .{ .place = .unlocated, .state = .failed },
        }, .failed = 1, .guidance = true, .own = .{ .unconfirmed = .verifying }, .safe = false },
        // The first entry at the client's Store decides; later ones still count.
        .{ .lines = &.{
            .{ .place = .own, .state = .{ .outcome = ready } },
            .{ .place = .own, .state = .{ .outcome = .{ .client_incompatible = 7 } } },
            .{ .place = .other, .state = .{ .outcome = .{ .unsupported = .application_owned } } },
            .{ .place = .other, .state = .{ .outcome = .{ .already_ready = .{ .instance = @splat(3), .pid = 9 } } } },
        }, .restarted = 2, .current = 1, .skipped = 1, .guidance = true, .own = ready, .safe = true },
        .{ .lines = &.{
            .{ .place = .own, .state = .failed },
            .{ .place = .own, .state = .{ .outcome = ready } },
        }, .failure = .cancelled, .restarted = 1, .failed = 2, .guidance = true, .own = .{ .unconfirmed = .verifying }, .safe = false },
    }) |batch| {
        var tally: Tally = .{};
        for (batch.lines) |line| tally.add(line);
        try sh60.expectSummary(.{
            .restarted = batch.restarted,
            .current = batch.current,
            .skipped = batch.skipped,
            .failed = batch.failed,
            .guidance = batch.guidance,
            .own = batch.own,
            .safe = batch.safe,
        }, tally.finish(batch.failure));
    }
}

test "SH-49 a running Host is offered for restart only when every observation holds" {
    // Base commit 531600a53, `HostLifecycle.observe` and `ownershipLimitation`:
    // the observations in the order they are read, and what each failing
    // value names. The first failing observation decides; an unread one is
    // read next.
    const Status = Child(@FieldType(Seen, "status"));
    const Directory = Child(@FieldType(Seen, "directory"));
    const flags = [_]?bool{ null, false, true };
    var count: usize = 0;
    for ([_]?Status{ null, .unavailable, .owned_unavailable, .access_failure, .incompatible, .ready }) |status| for (flags) |observed| for (flags) |snapshot| for (flags) |managed| for (flags) |environment| for (flags) |sources| for ([_]?Directory{ null, .unavailable, .mismatch, .same }) |directory| for (flags) |confirmed| {
        const seen: Seen = .{ .status = status, .observed = observed, .snapshot = snapshot, .managed = managed, .environment = environment, .sources = sources, .directory = directory, .confirmed = confirmed };
        const expected: Eligibility = expected: {
            const Read = @FieldType(Eligibility, "read");
            const s = status orelse break :expected .{ .read = .status };
            if (s == .unavailable) break :expected .absent;
            if (s == .owned_unavailable) break :expected .{ .unsupported = .ownership_status };
            if (s == .access_failure) break :expected .{ .unsupported = .inaccessible };
            const reads = [_]struct { value: ?bool, read: Read, limitation: Limitation }{
                .{ .value = observed, .read = .observe, .limitation = .ownership_observation },
                .{ .value = snapshot, .read = .snapshot, .limitation = .configuration_unavailable },
                .{ .value = managed, .read = .version, .limitation = .application_owned },
                .{ .value = environment, .read = .environment, .limitation = .configuration_unavailable },
                .{ .value = sources, .read = .sources, .limitation = .configuration_unavailable },
            };
            for (reads) |row| {
                const value = row.value orelse break :expected .{ .read = row.read };
                if (!value) break :expected .{ .unsupported = row.limitation };
            }
            const d = directory orelse break :expected .{ .read = .directory };
            if (d == .unavailable) break :expected .{ .unsupported = .ownership_directory_unavailable };
            if (d == .mismatch) break :expected .{ .unsupported = .ownership_directory_mismatch };
            const c = confirmed orelse break :expected .{ .read = .confirm };
            break :expected if (c) .managed else .{ .unsupported = .ownership_confirmation };
        };
        const actual = eligibility(seen);
        try std.testing.expect(std.meta.eql(expected, actual));
        // Offered only when every observation holds.
        try std.testing.expectEqual(status != null and (status.? == .incompatible or status.? == .ready) and observed == true and snapshot == true and
            managed == true and environment == true and sources == true and directory == .same and confirmed == true, actual == .managed);
        count += 1;
    };
    try std.testing.expectEqual(6 * 3 * 3 * 3 * 3 * 3 * 4 * 3, count);
}

/// SH-24, SH-81 and SH-80 fixtures: the shapes of `Facts` and `Probe` fields.
const fixture = struct {
    const Managed = @FieldType(@FieldType(Facts, "eligibility"), "managed");
    const Current = Child(@FieldType(Facts, "current"));
    const Check = Child(@FieldType(Facts, "check"));
    const Stop = Child(@FieldType(Facts, "stop"));
    const Start = Child(@FieldType(Facts, "start"));
    const refusal = start_report.Failure.init(.settings_invalid, "typed refusal");
    const running: Running = .{ .instance = @splat(5), .pid = 55 };
    const digest: settings_handoff.Digest = @splat('c');
    const readings = [_]?Reading{ null, .unreadable, .changed, .same };
    const flags = [_]?bool{ null, false, true };

    fn expectEffect(expected: Effect, actual: Effect) !void {
        try std.testing.expect(std.meta.eql(expected, actual));
    }

    /// Every check before the stop holds.
    fn checked() Facts {
        return .{
            .eligibility = .{ .managed = .{ .order = .lt, .environment_parses = true } },
            .same_executable = false,
            .sources = true,
            .check = .{ .ok = digest },
            .before_stop = .same,
            .snapshot = .same,
        };
    }
};

test "SH-24 a stop is asked for only after every check before it holds" {
    // Base commit 531600a53: `host_restart_all.restart`'s replacement test,
    // then `HostLifecycle.activate` up to its stop, typed as the ordered table
    // of the Upgrade design (section 2): the first line that applies wins.
    const Eligibility_ = @FieldType(Facts, "eligibility");
    var eligibilities: [1 + std.enums.values(Limitation).len + 6]Eligibility_ = undefined;
    eligibilities[0] = .absent;
    for (std.enums.values(Limitation), 1..) |reason, index| eligibilities[index] = .{ .unsupported = reason };
    var index: usize = 1 + std.enums.values(Limitation).len;
    for ([_]std.math.Order{ .lt, .eq, .gt }) |order| for ([_]bool{ false, true }) |parses| {
        eligibilities[index] = .{ .managed = .{ .order = order, .environment_parses = parses } };
        index += 1;
    };
    const digests = [_]settings_handoff.Digest{ @splat('a'), @splat('b') };
    const checks = [_]?fixture.Check{ null, .cancelled, .unavailable, .{ .refused = fixture.refusal }, .untyped, .bad_frame, .{ .ok = digests[0] }, .{ .ok = digests[1] } };
    const currents = [_]?fixture.Current{
        null,
        .unreadable,
        .changed,
        .{ .same = .{ .running = fixture.running, .settings = null } },
        .{ .same = .{ .running = fixture.running, .settings = digests[0] } },
        .{ .same = .{ .running = fixture.running, .settings = digests[1] } },
    };
    var stops: usize = 0;
    var count: usize = 0;
    const target_failures = [_]?TargetStep{ null, .resolving, .checking };
    for (eligibilities) |eligible| for ([_]@FieldType(Facts, "census"){ .same, .replaced }) |census| for ([_]bool{ false, true }) |cancelled|
        for (target_failures) |target_failed| for (fixture.flags) |same_executable| for (currents) |current| for (fixture.flags) |sources|
            for (checks) |check| for (fixture.readings) |before_stop| for (fixture.readings) |snapshot| {
                const facts: Facts = .{ .eligibility = eligible, .census = census, .target_failed = target_failed, .same_executable = same_executable, .current = current, .sources = sources, .check = check, .before_stop = before_stop, .snapshot = snapshot };
                const expected: Effect = expected: {
                    // 1. Not a managed Host.
                    const managed = switch (eligible) {
                        .absent => break :expected .{ .done = .not_needed },
                        .unsupported => |reason| break :expected .{ .done = .{ .unsupported = reason } },
                        .managed => |value| value,
                    };
                    // 2. Restart-all's census no longer matches the Host.
                    if (census == .replaced) break :expected .{ .done = .replacement_observed };
                    // 3. A caller's stop before the target is resolved.
                    if (cancelled and same_executable == null) break :expected .{ .done = .cancelled };
                    // 4. A newer running Host.
                    if (managed.order == .gt) break :expected .{ .done = .superseded };
                    // 5. An environment entry without a value.
                    if (!managed.environment_parses) break :expected .{ .done = .{ .unsupported = .configuration_unavailable } };
                    // A same-build Host reporting a digest stays current when the target gives no frame.
                    const kept_running: ?Running = if (same_executable == true) if (current) |value| switch (value) {
                        .same => |same_value| if (same_value.settings != null) same_value.running else null,
                        else => null,
                    } else null else null;
                    const kept_done: ?Effect = if (kept_running) |value| .{ .done = .{ .already_ready = value } } else null;
                    // 5a. A target step the shell could not complete.
                    if (target_failed) |step| break :expected kept_done orelse .{ .done = .{ .target_unusable = step } };
                    // 6, 7. The target is the running executable.
                    const same = same_executable orelse break :expected .resolve_target;
                    var running_same: ?@FieldType(fixture.Current, "same") = null;
                    if (same) running_same = switch (current orelse break :expected .confirm_current) {
                        .unreadable => break :expected .{ .done = .{ .unconfirmed = .verifying } },
                        .changed => break :expected .{ .done = .replacement_observed },
                        .same => |value| if (value.settings == null) break :expected .{ .done = .{ .already_ready = value.running } } else value,
                    };
                    // 8. Sources the target cannot be given.
                    if (!(sources orelse break :expected .reconstruct_sources)) break :expected kept_done orelse .{ .done = .{ .unsupported = .configuration_unavailable } };
                    // 9. The target's check.
                    const checked_digest: settings_handoff.Digest = switch (check orelse break :expected .check_target) {
                        .cancelled => break :expected .{ .done = .cancelled },
                        .unavailable => break :expected kept_done orelse .{ .done = .{ .target_unusable = .checking } },
                        .refused => break :expected kept_done orelse .{ .done = .{ .refused = .{ .stage = .checking, .failure = fixture.refusal } } },
                        .untyped, .bad_frame => break :expected kept_done orelse .{ .done = .{ .unsupported = .target_capability } },
                        .ok => |digest| digest,
                    };
                    if (running_same) |value| if (value.settings) |settings| {
                        if (std.mem.eql(u8, &settings, &checked_digest)) break :expected .{ .done = .{ .already_ready = value.running } };
                    };
                    // 11. A caller's stop after the check.
                    if (cancelled and before_stop == null) break :expected .{ .done = .cancelled };
                    // 12. The Host re-read before the stop.
                    switch (before_stop orelse break :expected .reobserve) {
                        .unreadable => break :expected .{ .done = .{ .unconfirmed = .stopping } },
                        .changed => break :expected .{ .done = .replacement_observed },
                        .same => {},
                    }
                    // 13. Its process snapshot re-read before the stop.
                    switch (snapshot orelse break :expected .snapshot) {
                        .unreadable => break :expected .{ .done = .{ .unconfirmed = .stopping } },
                        .changed => break :expected .{ .done = .{ .unsupported = .configuration_unavailable } },
                        .same => {},
                    }
                    break :expected .stop;
                };
                const actual = next(facts, cancelled);
                try fixture.expectEffect(expected, actual);
                // The stop is asked for exactly when every line holds.
                // The same build restarts unless its running settings equal the checked digest.
                const running_settings: ?settings_handoff.Digest = if (current) |value| switch (value) {
                    .same => |same_value| same_value.settings,
                    else => null,
                } else null;
                const checked_settings: ?settings_handoff.Digest = if (check) |value| switch (value) {
                    .ok => |digest| digest,
                    else => null,
                } else null;
                const unchanged = running_settings != null and checked_settings != null and std.mem.eql(u8, &running_settings.?, &checked_settings.?);
                const restarts = same_executable == false or (same_executable == true and running_settings != null and !unchanged);
                const holds = eligible == .managed and eligible.managed.order != .gt and eligible.managed.environment_parses and census == .same and
                    target_failed == null and restarts and sources == true and check != null and check.? == .ok and
                    before_stop == .same and snapshot == .same;
                try std.testing.expectEqual(holds, actual == .stop);
                // Nothing before the stop is reported at a stage after it.
                if (actual == .done) switch (actual.done) {
                    .failed => unreachable,
                    .unconfirmed => |stage| try std.testing.expect(stage == .stopping or stage == .verifying),
                    .refused => |refused| try std.testing.expectEqual(.checking, refused.stage),
                    else => {},
                };
                stops += @intFromBool(holds);
                count += 1;
            };
    try std.testing.expectEqual(eligibilities.len * 2 * 2 * target_failures.len * 3 * currents.len * 3 * checks.len * 4 * 4, count);
    // Per order and `cancelled`: a differing executable restarts for every current (6 * 2 checks),
    // and the same executable restarts only when a reported digest differs from the checked one (2 pairs).
    try std.testing.expectEqual(2 * 2 * (currents.len * 2 + 2), stops);
}

test "SH-81 after the stop every ending names a stage" {
    // Base commit 531600a53, `HostLifecycle.activate` after `Progress.stopping`:
    // each step's failure, typed by hand. A caller's stop is no longer read.
    const proofs = [_]?Outcome{ null, .{ .ready = .{ .instance = fixture.running.instance, .pid = fixture.running.pid } }, .{ .client_incompatible = 9 }, .replacement_observed, .{ .unconfirmed = .verifying } };
    const starts = [_]?fixture.Start{ null, .unavailable, .{ .refused = fixture.refusal }, .untyped, .started };
    var count: usize = 0;
    for ([_]fixture.Stop{ .failed, .instance_changed, .done }) |stop| for (fixture.flags) |retired| for (starts) |start| for (proofs) |proof| {
        var facts = fixture.checked();
        facts.stop = stop;
        facts.retired = retired;
        facts.start = start;
        facts.proof = proof;
        const expected: Effect = switch (stop) {
            .failed => .{ .done = .{ .unconfirmed = .stopping } },
            .instance_changed => .{ .done = .replacement_observed },
            .done => if (retired) |value| (if (!value) .{ .done = .{ .unconfirmed = .awaiting_retirement } } else if (start) |value_start| switch (value_start) {
                .unavailable => .{ .done = .{ .unconfirmed = .starting } },
                .refused => .{ .done = .{ .refused = .{ .stage = .starting, .failure = fixture.refusal } } },
                .untyped => .{ .done = .{ .failed = .starting } },
                .started => if (proof) |value_proof| .{ .done = value_proof } else .verify,
            } else .start) else .await_retirement,
        };
        for ([_]bool{ false, true }) |cancelled| {
            const actual = next(facts, cancelled);
            try fixture.expectEffect(expected, actual);
            if (actual == .done) switch (actual.done) {
                .cancelled, .unsupported, .not_needed, .superseded, .already_ready, .target_unusable => return error.TestUnexpectedResult,
                .unconfirmed, .failed => {},
                .refused => |refused| try std.testing.expectEqual(.starting, refused.stage),
                .ready, .client_incompatible, .replacement_observed => {},
            };
            count += 1;
        }
    };
    try std.testing.expectEqual(3 * 3 * starts.len * proofs.len * 2, count);
    // Before the stop is asked for, the stop is the next effect.
    try fixture.expectEffect(.stop, next(fixture.checked(), true));
}

test "SH-80 only complete proof makes a replacement ready" {
    const stopped: Identity = .{ .instance = @splat(1), .store = "database-wire-identity", .capacity = 3 };
    const replacement: Identity = .{ .instance = @splat(2), .store = "database-wire-identity", .capacity = 3 };
    const Status = Child(@FieldType(Probe, "status"));
    const Version = Child(@FieldType(Probe, "version"));
    const Own = Child(@FieldType(Probe, "own"));
    const Final = Child(@FieldType(Probe, "final"));
    const old_instance: Identity = .{ .instance = stopped.instance, .store = replacement.store, .capacity = 3 };
    const other_store: Identity = .{ .instance = replacement.instance, .store = "other-store", .capacity = 3 };
    const other_capacity: Identity = .{ .instance = replacement.instance, .store = replacement.store, .capacity = 4 };
    const statuses = [_]?Status{ null, .unavailable, .unanswered, .{ .answered = replacement }, .{ .answered = old_instance }, .{ .answered = other_store }, .{ .answered = other_capacity } };
    const versions = [_]?Version{ null, .unknown, .{ .order = .lt }, .{ .order = .eq }, .{ .order = .gt } };
    const owns = [_]?Own{ null, .unavailable, .incompatible, .{ .ready = replacement }, .{ .ready = old_instance }, .{ .ready = other_store }, .{ .ready = other_capacity } };
    const finals = [_]?Final{ null, .differs, .{ .same = 77 } };
    var proven: usize = 0;
    var count: usize = 0;
    for (fixture.flags) |before| for (statuses) |status| for (fixture.flags) |after| for (versions) |version| for (owns) |own| for (finals) |final| {
        const probe: Probe = .{ .stopped = stopped, .before = before, .status = status, .after = after, .version = version, .own = own, .final = final };
        // Base commit 531600a53, `HostLifecycle.verify` with `replacementMatches`
        // and `statusAgrees`: the reads of one pass in order, typed by hand.
        const expected: Verdict = expected: {
            if (!(before orelse break :expected .{ .read = .before })) break :expected .again;
            const answered = switch (status orelse break :expected .{ .read = .status }) {
                .unavailable => break :expected .{ .done = .{ .unconfirmed = .verifying } },
                .unanswered => break :expected .again,
                .answered => |identity| identity,
            };
            if (!(after orelse break :expected .{ .read = .after })) break :expected .again;
            const v = version orelse break :expected .{ .read = .version };
            if (v == .unknown) break :expected .{ .done = .{ .unconfirmed = .verifying } };
            // Only the replacement itself on the target version matches; a
            // mismatch is a replacement at once.
            if (v.order != .eq or answered.capacity != 3 or !std.mem.eql(u8, answered.store, "database-wire-identity") or answered.instance[0] != 2)
                break :expected .{ .done = .replacement_observed };
            const o = own orelse break :expected .{ .read = .own };
            const agrees = switch (o) {
                .unavailable => false,
                .incompatible => true,
                .ready => |identity| identity.instance[0] == 2 and identity.capacity == 3 and std.mem.eql(u8, identity.store, "database-wire-identity"),
            };
            if (!agrees) break :expected .again;
            const f = final orelse break :expected .{ .read = .final };
            if (f == .differs) break :expected .again;
            break :expected .{ .done = if (o == .incompatible) .{ .client_incompatible = 77 } else .{ .ready = .{ .instance = replacement.instance, .pid = 77 } } };
        };
        const actual = verdict(probe);
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("expected {any}, found {any}\n", .{ expected, actual });
            return error.TestExpectedEqual;
        }
        // Ready or client_incompatible exactly when every proof field holds.
        const complete = before == true and status != null and status.? == .answered and status.?.answered.instance[0] == 2 and
            status.?.answered.capacity == 3 and std.mem.eql(u8, status.?.answered.store, stopped.store) and after == true and
            version != null and version.? == .order and version.?.order == .eq and own != null and
            (own.? == .incompatible or (own.? == .ready and own.?.ready.instance[0] == 2 and own.?.ready.capacity == 3 and std.mem.eql(u8, own.?.ready.store, stopped.store))) and
            final != null and final.? == .same;
        try std.testing.expectEqual(complete, actual == .done and (actual.done == .ready or actual.done == .client_incompatible));
        proven += @intFromBool(complete);
        count += 1;
    };
    try std.testing.expectEqual(3 * statuses.len * 3 * versions.len * owns.len * finals.len, count);
    try std.testing.expectEqual(2, proven);

    // The literal cases of `HostLifecycle.zig` "upgrade replacement proof
    // accepts adopted target version but not old instance or guessed readiness".
    const proof: Probe = .{ .stopped = stopped, .before = true, .status = .{ .answered = replacement }, .after = true, .version = .{ .order = .eq }, .own = .{ .ready = replacement }, .final = .{ .same = 8 } };
    try std.testing.expect(std.meta.eql(Verdict{ .done = .{ .ready = .{ .instance = replacement.instance, .pid = 8 } } }, verdict(proof)));
    for ([_]struct { probe: Probe, expected: Verdict }{
        .{ .probe = with(proof, "own", .incompatible), .expected = .{ .done = .{ .client_incompatible = 8 } } },
        .{ .probe = with(proof, "own", .unavailable), .expected = .again },
        .{ .probe = with(proof, "own", .{ .ready = old_instance }), .expected = .again },
        .{ .probe = with(proof, "own", .{ .ready = other_capacity }), .expected = .again },
        .{ .probe = with(proof, "status", .{ .answered = old_instance }), .expected = .{ .done = .replacement_observed } },
        .{ .probe = with(proof, "status", .{ .answered = other_capacity }), .expected = .{ .done = .replacement_observed } },
        .{ .probe = with(proof, "status", .{ .answered = other_store }), .expected = .{ .done = .replacement_observed } },
        .{ .probe = with(proof, "version", .{ .order = .lt }), .expected = .{ .done = .replacement_observed } },
        .{ .probe = with(proof, "version", .unknown), .expected = .{ .done = .{ .unconfirmed = .verifying } } },
    }) |case| try std.testing.expect(std.meta.eql(case.expected, verdict(case.probe)));
}

fn Child(comptime Optional: type) type {
    return @typeInfo(Optional).optional.child;
}

fn with(probe: Probe, comptime name: []const u8, value: Child(@FieldType(Probe, name))) Probe {
    var result = probe;
    @field(result, name) = value;
    return result;
}
