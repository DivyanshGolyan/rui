const std = @import("std");
const protocol = @import("protocol.zig");
const start_report = @import("start_report.zig");

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
    refused: struct { stage: enum { checking, starting }, failure: start_report.Failure },
    failed: Stage,
    unconfirmed: Stage,
};

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
        .replacement_observed, .cancelled, .failed, .unconfirmed, .refused => .failed,
    };
}

/// Whether the outcome leaves recovery instructions for the person.
pub fn guides(outcome: Outcome) bool {
    return switch (outcome) {
        .unsupported, .replacement_observed, .cancelled, .failed, .unconfirmed, .refused => true,
        .not_needed, .superseded, .already_ready, .ready, .client_incompatible => false,
    };
}

/// Whether a client may keep talking to its own Store's Host after this outcome.
pub fn clientSafe(outcome: Outcome) bool {
    return switch (outcome) {
        .client_incompatible, .unconfirmed, .failed, .replacement_observed, .refused => false,
        .not_needed, .superseded, .already_ready, .ready, .unsupported, .cancelled => true,
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
