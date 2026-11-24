const std = @import("std");
const status = @import("upgrade_status.zig");
const activation = @import("host_activation.zig");

pub const Version = status.Version;

/// `rui upgrade --check`, or every run that may install.
pub const Mode = enum { check, install };

/// The selected installation as `Installation.inspect` classified it.
pub const Selection = union(enum) { absent, ineligible, source, unknown_managed, released: Version };

/// The class of error an effect returned, as `caller_error` names it.
pub const Cause = enum { cancelled, download, release, preparation, other };

/// The result of one effect: what it read, or why it could not.
pub fn Seen(comptime T: type) type {
    return union(enum) { ok: T, failed: Cause };
}

/// What a publication left selected: whether it changed the selection, and
/// the version its receipt names.
pub const Published = struct { changed: bool, selected: Version };

/// Everything one Upgrade run has read so far; `null` means not read yet.
pub const Facts = struct {
    /// Read only once the caller continues past the check.
    mode: Mode,
    selection: ?Seen(Selection) = null,
    release: ?Seen(Version) = null,
    /// Hosts found before installing; a warning only.
    census: ?Seen(usize) = null,
    /// The caller continued past the check.
    resumed: bool = false,
    prepared: ?Seen(void) = null,
    published: ?Seen(Published) = null,
    /// The published build was re-inspected after publication and has the receipt's version.
    pinned: ?Seen(void) = null,
    /// The restart batch, folded by `host_activation`.
    hosts: ?Seen(activation.Summary) = null,
};

/// The next thing the shell does. Only `checked` and `end` read no fact.
pub const Effect = union(enum) {
    /// Classify the selected installation.
    inspect_selection,
    /// Read the newest published release. A run always reads it itself:
    /// a release read earlier may since have been replaced.
    release,
    /// Discover running Hosts and observe PATH.
    census,
    /// The check is complete; the caller prints it or decides to continue.
    checked,
    /// Download and verify the release beside the selection.
    prepare,
    /// Publish the selected build again, or the prepared one.
    publish: enum { selected, prepared },
    /// Re-read the published build and require the receipt's version.
    pin_target,
    /// Restart every Host found now on the pinned build. It carries nothing
    /// from `census`: restart discovers Hosts afresh.
    restart_hosts,
    end,
};

pub fn next(f: Facts) Effect {
    const selection = f.selection orelse return .inspect_selection;
    if (selection == .failed) return .end;
    const release = f.release orelse return .release;
    if (release == .failed) return .end;
    const census = f.census orelse return .census;
    if (census == .failed) return .end;
    if (!f.resumed) return .checked;
    if (f.mode == .check or !installable(f)) return .end;
    const published = f.published orelse {
        if (holdsRelease(f)) return .{ .publish = .selected };
        const prepared = f.prepared orelse return .prepare;
        return if (prepared == .failed) .end else .{ .publish = .prepared };
    };
    if (published == .failed) return .end;
    const pinned = f.pinned orelse return .pin_target;
    if (pinned == .failed) return .end;
    return if (f.hosts == null) .restart_hosts else .end;
}

/// Only a selected managed release can be replaced.
pub fn installable(f: Facts) bool {
    const selection = f.selection orelse return false;
    return selection == .ok and selection.ok == .released;
}

/// The selected managed release is not older than the release, so it is
/// published again rather than replaced.
pub fn holdsRelease(f: Facts) bool {
    if (!installable(f)) return false;
    const release = f.release orelse return false;
    return release == .ok and f.selection.?.ok.released.order(release.ok) != .lt;
}

/// `f` with the fact that the pending effect would fill set to failed.
pub fn failing(f: Facts, cause: Cause) Facts {
    var result = f;
    switch (next(f)) {
        .inspect_selection => result.selection = .{ .failed = cause },
        .release => result.release = .{ .failed = cause },
        .census => result.census = .{ .failed = cause },
        .prepare => result.prepared = .{ .failed = cause },
        .publish => result.published = .{ .failed = cause },
        .pin_target => result.pinned = .{ .failed = cause },
        .restart_hosts => result.hosts = .{ .failed = cause },
        .checked, .end => unreachable,
    }
    return result;
}

/// The Host restart batch. A failure after publication fails the batch as a
/// whole, beside the kept receipt.
pub fn hostsOf(f: Facts) activation.Summary {
    const failure: ?Cause = if (f.hosts) |hosts| switch (hosts) {
        .ok => |summary| return summary,
        .failed => |cause| cause,
    } else if (f.pinned) |pinned| switch (pinned) {
        .ok => null,
        .failed => |cause| cause,
    } else null;
    const empty: activation.Tally = .{};
    return empty.finish(if (failure) |cause| if (cause == .cancelled) .cancelled else .other else null);
}

/// How the CLI exits after the run.
pub const Exit = enum { done, check_failed, not_installable, install_failed, restart_failed };

pub fn exit(f: Facts) Exit {
    if (failed(f.selection) or failed(f.release) or failed(f.census)) return .check_failed;
    if (f.mode == .check) return .done;
    if (!installable(f)) return .not_installable;
    if (failed(f.prepared) or failed(f.published)) return .install_failed;
    if (hostsOf(f).counts.failed != 0) return .restart_failed;
    return .done;
}

fn failed(seen: anytype) bool {
    const value = seen orelse return false;
    return value == .failed;
}

/// A world for the tests below: the facts the shell starts from and, for
/// each effect, the cause it fails with or none.
const world = struct {
    const Kind = enum { selection, release, census, prepare, publish, pin, hosts };
    const kinds = std.enums.values(Kind);
    const causes = std.enums.values(Cause);
    const release: Version = .{ .schema = 60, .patch = 5 };
    /// Selected releases below, at and above `release`; schema orders before patch.
    const versions = [_]struct { Version, std.math.Order }{
        .{ .{ .schema = 59, .patch = 9 }, .lt },
        .{ .{ .schema = 60, .patch = 4 }, .lt },
        .{ .{ .schema = 60, .patch = 5 }, .eq },
        .{ .{ .schema = 60, .patch = 6 }, .gt },
        .{ .{ .schema = 61, .patch = 0 }, .gt },
    };
    const selections = [_]Selection{ .absent, .ineligible, .source, .unknown_managed };

    const Script = struct {
        mode: Mode,
        selection: Selection,
        /// The one effect that fails, and how.
        failure: ?struct { Kind, Cause } = null,
        /// Hosts the restart reports as failed when it runs.
        restart_failures: usize = 0,
    };

    const Trace = struct {
        effects: [16]Effect = undefined,
        len: usize = 0,
        facts: Facts,

        fn has(self: *const Trace, tag: std.meta.Tag(Effect)) bool {
            return self.index(tag) != null;
        }

        fn index(self: *const Trace, tag: std.meta.Tag(Effect)) ?usize {
            for (self.effects[0..self.len], 0..) |effect, at| if (effect == tag) return at;
            return null;
        }
    };

    fn kindOf(effect: Effect) Kind {
        return switch (effect) {
            .inspect_selection => .selection,
            .release => .release,
            .census => .census,
            .prepare => .prepare,
            .publish => .publish,
            .pin_target => .pin,
            .restart_hosts => .hosts,
            .checked, .end => unreachable,
        };
    }

    fn kindEffect(kind: Kind) std.meta.Tag(Effect) {
        return switch (kind) {
            .selection => .inspect_selection,
            .release => .release,
            .census => .census,
            .prepare => .prepare,
            .publish => .publish,
            .pin => .pin_target,
            .hosts => .restart_hosts,
        };
    }

    fn count(trace: *const Trace, effect: Effect) usize {
        var found: usize = 0;
        for (trace.effects[0..trace.len]) |seen| found += @intFromBool(std.meta.eql(seen, effect));
        return found;
    }

    /// Applies each effect as the script says, resuming once after `checked`.
    fn run(script: Script) !Trace {
        var trace: Trace = .{ .facts = .{ .mode = script.mode } };
        while (true) {
            const effect = next(trace.facts);
            try std.testing.expect(trace.len < trace.effects.len);
            trace.effects[trace.len] = effect;
            trace.len += 1;
            switch (effect) {
                .end => return trace,
                .checked => {
                    try std.testing.expect(!trace.facts.resumed);
                    trace.facts.resumed = true;
                    continue;
                },
                else => {},
            }
            const kind = kindOf(effect);
            if (script.failure) |failure| if (failure[0] == kind) {
                trace.facts = failing(trace.facts, failure[1]);
                continue;
            };
            switch (kind) {
                .selection => trace.facts.selection = .{ .ok = script.selection },
                .release => trace.facts.release = .{ .ok = release },
                .census => trace.facts.census = .{ .ok = 2 },
                .prepare => trace.facts.prepared = .{ .ok = {} },
                .publish => trace.facts.published = .{ .ok = .{ .changed = effect.publish == .prepared, .selected = release } },
                .pin => trace.facts.pinned = .{ .ok = {} },
                .hosts => {
                    var tally: activation.Tally = .{};
                    for (0..script.restart_failures) |_| tally.add(.{ .place = .other, .state = .{ .failed = .of(.observation, error.OutOfMemory) } });
                    tally.add(.{ .place = .own, .state = .{ .outcome = .{ .ready = .{ .instance = @splat(1), .pid = 7 } } } });
                    trace.facts.hosts = .{ .ok = tally.finish(null) };
                },
            }
        }
    }

    /// Every script: both modes, every selection (a release
    /// at each version), and no failure or one failure at each effect with
    /// each cause. One failure is enough: a run ends at its first.
    fn each(context: anytype, comptime visit: fn (@TypeOf(context), Script, ?std.math.Order) anyerror!void) !void {
        var worlds: usize = 0;
        for ([_]Mode{ .check, .install }) |mode| {
            for (0..selections.len + versions.len) |index| {
                const selection: Selection, const ordered: ?std.math.Order = if (index < selections.len)
                    .{ selections[index], null }
                else
                    .{ .{ .released = versions[index - selections.len][0] }, versions[index - selections.len][1] };
                for (0..kinds.len * causes.len + 2) |choice| {
                    var script: Script = .{ .mode = mode, .selection = selection };
                    if (choice < kinds.len * causes.len) {
                        script.failure = .{ kinds[choice / causes.len], causes[choice % causes.len] };
                    } else if (choice == kinds.len * causes.len + 1) {
                        script.restart_failures = 1;
                    }
                    try visit(context, script, ordered);
                    worlds += 1;
                }
            }
        }
        try std.testing.expectEqual(@as(usize, 2 * 9 * (7 * 5 + 2)), worlds);
    }
};

test "SH-72 a run observes the selection, then the release, then the Hosts" {
    try world.each({}, struct {
        fn visit(_: void, script: world.Script, _: ?std.math.Order) !void {
            const trace = try world.run(script);
            // The check's effects, cut after the first that fails.
            const observations = [_]Effect{ .inspect_selection, .release, .census };
            var expected = observations.len;
            var stopped = false;
            for (observations, 0..) |effect, at| if (script.failure) |failure| if (failure[0] == world.kindOf(effect)) {
                expected = at + 1;
                stopped = true;
                break;
            };
            for (observations[0..expected], trace.effects[0..expected]) |want, got| try std.testing.expectEqual(want, got);
            if (stopped) {
                // A failed observation ends the run at once.
                try std.testing.expectEqual(expected + 1, trace.len);
                try std.testing.expectEqual(Effect.end, trace.effects[expected]);
                try std.testing.expectEqual(Exit.check_failed, exit(trace.facts));
            } else {
                try std.testing.expectEqual(Effect.checked, trace.effects[expected]);
                try std.testing.expect(exit(trace.facts) != .check_failed);
            }
            // The run reads the release itself, at most once.
            try std.testing.expect(world.count(&trace, .release) <= 1);
            try std.testing.expectEqual(@as(usize, 1), world.count(&trace, .inspect_selection));
        }
    }.visit);
}

test "SH-73 a run prepares a release only to replace an older managed selection" {
    // The first effect after the check, and what follows preparation, from
    // `upgrade.install` before this core (`canInstall`, `holdsRelease`).
    const Row = struct { mode: Mode, selection: Selection, first: Effect, exit: Exit };
    const below: Version = .{ .schema = 60, .patch = 4 };
    const equal: Version = .{ .schema = 60, .patch = 5 };
    const above: Version = .{ .schema = 61, .patch = 0 };
    const older_schema: Version = .{ .schema = 59, .patch = 9 };
    const newer_patch: Version = .{ .schema = 60, .patch = 6 };
    const rows = [_]Row{
        .{ .mode = .install, .selection = .absent, .first = .end, .exit = .not_installable },
        .{ .mode = .install, .selection = .ineligible, .first = .end, .exit = .not_installable },
        .{ .mode = .install, .selection = .source, .first = .end, .exit = .not_installable },
        .{ .mode = .install, .selection = .unknown_managed, .first = .end, .exit = .not_installable },
        .{ .mode = .install, .selection = .{ .released = older_schema }, .first = .prepare, .exit = .done },
        .{ .mode = .install, .selection = .{ .released = below }, .first = .prepare, .exit = .done },
        .{ .mode = .install, .selection = .{ .released = equal }, .first = .{ .publish = .selected }, .exit = .done },
        .{ .mode = .install, .selection = .{ .released = newer_patch }, .first = .{ .publish = .selected }, .exit = .done },
        .{ .mode = .install, .selection = .{ .released = above }, .first = .{ .publish = .selected }, .exit = .done },
        .{ .mode = .check, .selection = .absent, .first = .end, .exit = .done },
        .{ .mode = .check, .selection = .ineligible, .first = .end, .exit = .done },
        .{ .mode = .check, .selection = .source, .first = .end, .exit = .done },
        .{ .mode = .check, .selection = .unknown_managed, .first = .end, .exit = .done },
        .{ .mode = .check, .selection = .{ .released = older_schema }, .first = .end, .exit = .done },
        .{ .mode = .check, .selection = .{ .released = below }, .first = .end, .exit = .done },
        .{ .mode = .check, .selection = .{ .released = equal }, .first = .end, .exit = .done },
        .{ .mode = .check, .selection = .{ .released = above }, .first = .end, .exit = .done },
    };
    for (rows) |row| {
        var facts: Facts = .{ .mode = row.mode, .selection = .{ .ok = row.selection }, .release = .{ .ok = world.release }, .census = .{ .ok = 0 }, .resumed = true };
        try std.testing.expectEqual(row.first, next(facts));
        try std.testing.expectEqual(row.selection == .released, installable(facts));
        if (row.first == .end) {
            try std.testing.expectEqual(row.exit, exit(facts));
            continue;
        }
        if (row.first == .prepare) {
            try std.testing.expectEqual(Effect{ .publish = .prepared }, next(f: {
                var prepared = facts;
                prepared.prepared = .{ .ok = {} };
                break :f prepared;
            }));
            for (std.enums.values(Cause)) |cause| {
                const refused = failing(facts, cause);
                try std.testing.expectEqual(Effect.end, next(refused));
                try std.testing.expectEqual(Exit.install_failed, exit(refused));
            }
        }
        facts.published = .{ .ok = .{ .changed = row.first == .prepare, .selected = world.release } };
        try std.testing.expectEqual(Effect.pin_target, next(facts));
    }

    // Over every world: preparation happens exactly when the selection is an
    // older managed release in an install run, and comes before the one publication.
    try world.each({}, struct {
        fn visit(_: void, script: world.Script, ordered: ?std.math.Order) !void {
            const trace = try world.run(script);
            const checked = trace.has(.checked);
            const route = checked and script.mode == .install and ordered != null;
            try std.testing.expectEqual(route and ordered.? == .lt, trace.has(.prepare));
            const publishes = world.count(&trace, .{ .publish = .selected }) + world.count(&trace, .{ .publish = .prepared });
            try std.testing.expect(publishes <= 1);
            if (trace.index(.publish)) |at| {
                try std.testing.expectEqual(trace.has(.prepare), trace.effects[at].publish == .prepared);
                if (trace.index(.prepare)) |prepared| try std.testing.expect(prepared < at);
            }
            if (checked and !route) {
                const end = trace.index(.checked).? + 1;
                try std.testing.expectEqual(end + 1, trace.len);
                try std.testing.expectEqual(if (script.mode == .check) Exit.done else Exit.not_installable, exit(trace.facts));
            }
        }
    }.visit);
}

test "SH-74 nothing reaches a Host before publication, and nothing after it undoes the receipt" {
    try world.each({}, struct {
        fn visit(_: void, script: world.Script, _: ?std.math.Order) !void {
            const trace = try world.run(script);
            const published = trace.index(.publish);
            const pinned = trace.index(.pin_target);
            const restarted = trace.index(.restart_hosts);
            // Restart follows a successful publication and pin, never the census alone.
            if (restarted) |at| {
                try std.testing.expect(pinned.? < at and published.? < pinned.?);
                try std.testing.expect(trace.facts.published.? == .ok and trace.facts.pinned.? == .ok);
            }
            if (pinned) |at| try std.testing.expect(published.? < at and trace.facts.published.? == .ok);
            if (published) |at| {
                // Every observation and preparation succeeded before it.
                for (trace.effects[0..at]) |effect| switch (effect) {
                    .checked => {},
                    else => try std.testing.expect(script.failure == null or script.failure.?[0] != world.kindOf(effect)),
                };
            }
            const failure = script.failure orelse {
                const expected: Exit = if (script.mode == .check)
                    .done
                else if (script.selection != .released)
                    .not_installable
                else if (script.restart_failures != 0)
                    .restart_failed
                else
                    .done;
                try std.testing.expectEqual(expected, exit(trace.facts));
                try std.testing.expectEqual(script.mode == .install and script.selection == .released, restarted != null);
                return;
            };
            const kind, const cause = failure;
            switch (kind) {
                .selection, .release, .census => try std.testing.expectEqual(Exit.check_failed, exit(trace.facts)),
                .prepare, .publish => if (trace.has(world.kindEffect(kind))) {
                    try std.testing.expectEqual(Exit.install_failed, exit(trace.facts));
                    try std.testing.expect(!trace.has(.pin_target) and !trace.has(.restart_hosts));
                },
                .pin, .hosts => if (trace.has(world.kindEffect(kind))) {
                    // The receipt stays; the whole batch failed once, with guidance,
                    // and only a cancel leaves the client safe.
                    try std.testing.expect(trace.facts.published.? == .ok);
                    try std.testing.expectEqual(kind == .hosts, trace.has(.restart_hosts));
                    const hosts = hostsOf(trace.facts);
                    try std.testing.expectEqual(activation.Counts{ .failed = 1 }, hosts.counts);
                    try std.testing.expect(hosts.guidance);
                    try std.testing.expectEqual(cause == .cancelled, activation.selectedClientSafe(hosts.own));
                    // The ending always names the kept publication receipt, even on restart failure.
                    const receipt = trace.facts.published.?.ok.selected;
                    const ended = ending(trace.facts, false);
                    const shown = switch (ended) {
                        .upgraded => |value| value.version,
                        .up_to_date, .superseded, .incompatible => |value| value,
                        else => return error.TestUnexpectedResult,
                    };
                    try std.testing.expectEqualDeep(receipt, shown);
                    try std.testing.expectEqual(Exit.restart_failed, exit(trace.facts));
                },
            }
        }
    }.visit);
}

test "SH-37 a check run asks for observations only" {
    try world.each({}, struct {
        fn visit(_: void, script: world.Script, _: ?std.math.Order) !void {
            if (script.mode != .check) return;
            const trace = try world.run(script);
            for (trace.effects[0..trace.len]) |effect| switch (effect) {
                .inspect_selection, .release, .census, .checked, .end => {},
                .prepare, .publish, .pin_target, .restart_hosts => return error.TestUnexpectedResult,
            };
            try std.testing.expect(exit(trace.facts) == .done or exit(trace.facts) == .check_failed);
        }
    }.visit);
}

/// The worker's progress, published through the job's existing atomic.
pub const Phase = enum(u8) { checking, preparing, publishing, stopping, awaiting_retirement, starting, verifying, finished };

fn checkComplete(f: Facts) bool {
    return f.selection != null and f.selection.? == .ok and f.release != null and f.release.? == .ok and f.census != null and f.census.? == .ok;
}

fn failureCause(f: Facts) ?Cause {
    inline for (.{ f.selection, f.release, f.census, f.prepared, f.published }) |seen| {
        if (seen) |value| if (value == .failed) return value.failed;
    }
    return null;
}

pub fn ending(f: Facts, stopping: bool) status.Ended {
    const cause = failureCause(f);
    if (!checkComplete(f)) return if (stopping) .cancelled else .{ .failed = failureClass(cause) };
    if (f.published) |publication| if (publication == .ok) {
        const receipt = publication.ok;
        const hosts = hostsOf(f);
        if (!activation.selectedClientSafe(hosts.own)) return .{ .incompatible = receipt.selected };
        const restarted = hosts.counts.restarted != 0;
        if (!receipt.changed and !restarted) return if (receipt.selected.order(f.release.?.ok) == .gt)
            .{ .superseded = receipt.selected }
        else
            .{ .up_to_date = receipt.selected };
        return .{ .upgraded = .{ .version = receipt.selected, .restarted = restarted } };
    };
    if (stopping) return .cancelled;
    if (cause != null) return .{ .failed = failureClass(cause) };
    return .{ .refused = switch (f.selection.?.ok) {
        .absent => .first_install,
        .source => .source_build,
        .unknown_managed => .unknown_build,
        .ineligible => .package_managed,
        .released => unreachable,
    } };
}

fn failureClass(cause: ?Cause) status.Failure {
    return switch (cause orelse .other) {
        .download => .download,
        .release, .preparation => .release,
        .cancelled, .other => .other,
    };
}

pub fn outcome(f: Facts) status.Outcome {
    if (f.published) |publication| if (publication == .ok) return if (activation.selectedClientSafe(hostsOf(f).own)) .compatible else .incompatible;
    return .unchanged;
}

pub fn installed(f: Facts) bool {
    const publication = f.published orelse return false;
    return publication == .ok and publication.ok.changed;
}

/// A run step failed for a reason other than the person's own cancel;
/// a cancel alone changed nothing and needs no failure guidance (#1792).
pub fn failedBeyondCancel(f: Facts) bool {
    return if (failureCause(f)) |cause| cause != .cancelled else false;
}

pub fn guidance(f: Facts, cleanup_retained: bool, path_selected: bool) bool {
    return failedBeyondCancel(f) or cleanup_retained or hostsOf(f).guidance or !path_selected;
}

pub fn run(f: Facts, stopping: bool, finished: bool, phase: Phase) status.Run {
    if (finished) return .{ .ended = .{ .how = ending(f, stopping), .outcome = outcome(f) } };
    if (stopping) return .cancelling;
    if (f.resumed and checkComplete(f) and !(holdsRelease(f) and f.census.?.ok == 0)) return .{ .installing = .{
        .found = .{ .host = if (f.census.?.ok == 0) .none else .{ .running = f.census.?.ok } },
        .step = switch (phase) {
            .checking, .preparing, .finished => .preparing,
            .publishing => .publishing,
            .stopping, .awaiting_retirement, .starting, .verifying => .restarting,
        },
    } };
    return .checking;
}

test "SH-75 a run's ending outcome exit and relaunch follow its facts" {
    const receipt: Version = .{ .schema = 61, .patch = 2 };
    const Row = struct {
        changed: bool,
        hosts: activation.Summary,
        ended: status.Ended,
        result: status.Outcome,
        relaunch: bool,
        guidance: bool,
        exit_class: Exit,
    };
    const empty = activation.Summary{ .counts = .{}, .guidance = false, .own = .{ .outcome = .not_needed } };
    const restarted = activation.Summary{ .counts = .{ .restarted = 1 }, .guidance = false, .own = .{ .outcome = .{ .ready = .{ .instance = @splat(0), .pid = 1 } } } };
    const current = activation.Summary{ .counts = .{ .current = 1 }, .guidance = false, .own = .{ .outcome = .{ .already_ready = .{ .instance = @splat(0), .pid = 1 } } } };
    const failed_other = activation.Summary{ .counts = .{ .failed = 1 }, .guidance = true, .own = .{ .outcome = .not_needed } };
    const unsafe_host = activation.Summary{ .counts = .{ .failed = 1 }, .guidance = true, .own = .{ .outcome = .{ .unconfirmed = .verifying } } };
    const cancelled = activation.Summary{ .counts = .{ .failed = 1 }, .guidance = true, .own = .{ .outcome = .cancelled } };
    // Literal expectations from UpgradeJob before moving these decisions.
    const rows = [_]Row{
        .{ .changed = true, .hosts = empty, .ended = .{ .upgraded = .{ .version = receipt, .restarted = false } }, .result = .compatible, .relaunch = true, .guidance = false, .exit_class = .done },
        .{ .changed = false, .hosts = empty, .ended = .{ .superseded = receipt }, .result = .compatible, .relaunch = false, .guidance = false, .exit_class = .done },
        .{ .changed = true, .hosts = restarted, .ended = .{ .upgraded = .{ .version = receipt, .restarted = true } }, .result = .compatible, .relaunch = true, .guidance = false, .exit_class = .done },
        .{ .changed = false, .hosts = restarted, .ended = .{ .upgraded = .{ .version = receipt, .restarted = true } }, .result = .compatible, .relaunch = false, .guidance = false, .exit_class = .done },
        .{ .changed = true, .hosts = current, .ended = .{ .upgraded = .{ .version = receipt, .restarted = false } }, .result = .compatible, .relaunch = true, .guidance = false, .exit_class = .done },
        .{ .changed = false, .hosts = current, .ended = .{ .superseded = receipt }, .result = .compatible, .relaunch = false, .guidance = false, .exit_class = .done },
        .{ .changed = true, .hosts = failed_other, .ended = .{ .upgraded = .{ .version = receipt, .restarted = false } }, .result = .compatible, .relaunch = true, .guidance = true, .exit_class = .restart_failed },
        .{ .changed = false, .hosts = failed_other, .ended = .{ .superseded = receipt }, .result = .compatible, .relaunch = false, .guidance = true, .exit_class = .restart_failed },
        .{ .changed = true, .hosts = unsafe_host, .ended = .{ .incompatible = receipt }, .result = .incompatible, .relaunch = true, .guidance = true, .exit_class = .restart_failed },
        .{ .changed = false, .hosts = unsafe_host, .ended = .{ .incompatible = receipt }, .result = .incompatible, .relaunch = false, .guidance = true, .exit_class = .restart_failed },
        .{ .changed = true, .hosts = cancelled, .ended = .{ .upgraded = .{ .version = receipt, .restarted = false } }, .result = .compatible, .relaunch = true, .guidance = true, .exit_class = .restart_failed },
        .{ .changed = false, .hosts = cancelled, .ended = .{ .superseded = receipt }, .result = .compatible, .relaunch = false, .guidance = true, .exit_class = .restart_failed },
    };
    const releases = [_]struct { Version, status.Ended }{
        .{ .{ .schema = 60, .patch = 1 }, .{ .superseded = receipt } },
        .{ receipt, .{ .up_to_date = receipt } },
        .{ .{ .schema = 62, .patch = 0 }, .{ .up_to_date = receipt } },
    };
    const selections = [_]Selection{ .absent, .ineligible, .source, .unknown_managed, .{ .released = receipt } };
    for (rows) |row| for (releases) |release_row| for (selections) |selection| for ([_]bool{ false, true }) |stopping| {
        const f: Facts = .{ .mode = .install, .selection = .{ .ok = selection }, .release = .{ .ok = release_row[0] }, .census = .{ .ok = 0 }, .resumed = true, .published = .{ .ok = .{ .changed = row.changed, .selected = receipt } }, .pinned = .{ .ok = {} }, .hosts = .{ .ok = row.hosts } };
        const expected = if (row.ended == .superseded) release_row[1] else row.ended;
        try std.testing.expectEqualDeep(expected, ending(f, stopping));
        try std.testing.expectEqual(row.result, outcome(f));
        try std.testing.expectEqual(row.relaunch, installed(f));
        try std.testing.expectEqual(row.guidance, guidance(f, false, true));
        try std.testing.expect(guidance(f, true, true));
        try std.testing.expect(guidance(f, false, false));
        try std.testing.expectEqual(if (selection == .released) row.exit_class else Exit.not_installable, exit(f));
    };
    const cases = [_]struct { Selection, status.Refusal }{
        .{ .absent, .first_install }, .{ .source, .source_build }, .{ .unknown_managed, .unknown_build }, .{ .ineligible, .package_managed },
    };
    for (cases) |row| {
        const f: Facts = .{ .mode = .install, .selection = .{ .ok = row[0] }, .release = .{ .ok = receipt }, .census = .{ .ok = 0 }, .resumed = true };
        try std.testing.expectEqualDeep(status.Ended{ .refused = row[1] }, ending(f, false));
        try std.testing.expectEqual(status.Ended.cancelled, ending(f, true));
        try std.testing.expectEqual(Exit.not_installable, exit(f));
    }
    // Absent and failed publications, crossed with the same selection,
    // release, Host and stopping domains as the successful receipts above.
    for (rows) |row| for (releases) |release_row| for (selections) |selection| for ([_]bool{ false, true }) |stopping| {
        var f: Facts = .{ .mode = .install, .selection = .{ .ok = selection }, .release = .{ .ok = release_row[0] }, .census = .{ .ok = 0 }, .resumed = true, .hosts = .{ .ok = row.hosts } };
        if (selection != .released or stopping) {
            const expected: status.Ended = if (stopping) .cancelled else .{ .refused = switch (selection) {
                .absent => .first_install,
                .ineligible => .package_managed,
                .source => .source_build,
                .unknown_managed => .unknown_build,
                .released => unreachable,
            } };
            try std.testing.expectEqualDeep(expected, ending(f, stopping));
            try std.testing.expectEqual(status.Outcome.unchanged, outcome(f));
            try std.testing.expect(!installed(f));
            try std.testing.expectEqual(row.guidance, guidance(f, false, true));
            try std.testing.expectEqual(if (selection != .released) Exit.not_installable else if (row.exit_class == .restart_failed) Exit.restart_failed else Exit.done, exit(f));
        }
        f.published = .{ .failed = .download };
        try std.testing.expectEqualDeep(if (stopping) status.Ended.cancelled else status.Ended{ .failed = .download }, ending(f, stopping));
        try std.testing.expectEqual(status.Outcome.unchanged, outcome(f));
        try std.testing.expect(!installed(f));
        try std.testing.expect(guidance(f, false, true));
        try std.testing.expectEqual(if (selection == .released) Exit.install_failed else Exit.not_installable, exit(f));
    };
    const errors = [_]struct { Cause, status.Failure }{
        .{ .download, .download }, .{ .release, .release }, .{ .preparation, .release }, .{ .other, .other }, .{ .cancelled, .other },
    };
    for (errors) |row| for ([_]bool{ false, true }) |stopping| {
        var f: Facts = .{ .mode = .install, .selection = .{ .ok = .{ .released = receipt } }, .release = .{ .ok = receipt }, .census = .{ .ok = 0 }, .resumed = true, .published = .{ .failed = row[0] } };
        try std.testing.expectEqualDeep(if (stopping) status.Ended.cancelled else status.Ended{ .failed = row[1] }, ending(f, stopping));
        try std.testing.expectEqual(status.Outcome.unchanged, outcome(f));
        try std.testing.expect(!installed(f));
        try std.testing.expectEqual(row[0] != .cancelled, guidance(f, false, true));
        try std.testing.expectEqual(Exit.install_failed, exit(f));
        f.selection = .{ .failed = row[0] };
        try std.testing.expectEqualDeep(if (stopping) status.Ended.cancelled else status.Ended{ .failed = row[1] }, ending(f, stopping));
        try std.testing.expectEqual(Exit.check_failed, exit(f));
    };
    const phases = [_]struct { Phase, status.Step }{
        .{ .checking, .preparing },   .{ .preparing, .preparing },            .{ .publishing, .publishing },
        .{ .stopping, .restarting },  .{ .awaiting_retirement, .restarting }, .{ .starting, .restarting },
        .{ .verifying, .restarting }, .{ .finished, .preparing },
    };
    for (phases) |row| {
        const f: Facts = .{ .mode = .install, .selection = .{ .ok = .{ .released = .{ .schema = 60, .patch = 0 } } }, .release = .{ .ok = receipt }, .census = .{ .ok = 2 }, .resumed = true };
        try std.testing.expectEqualDeep(status.Run{ .installing = .{ .found = .{ .host = .{ .running = 2 } }, .step = row[1] } }, run(f, false, false, row[0]));
        try std.testing.expectEqual(status.Run.cancelling, run(f, true, false, row[0]));
    }
    // #1792: a cancellation before publication is not failure guidance.
    const cancelled_before_publication: Facts = .{ .mode = .install, .selection = .{ .ok = .{ .released = receipt } }, .release = .{ .ok = receipt }, .census = .{ .ok = 0 }, .resumed = true, .published = .{ .failed = .cancelled } };
    try std.testing.expectEqual(status.Ended.cancelled, ending(cancelled_before_publication, true));
    try std.testing.expect(!guidance(cancelled_before_publication, false, true));
}
