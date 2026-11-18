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
    /// Background discovery handed over a release candidate.
    adopted: bool = false,
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
    /// Take the handed-over candidate, or discover the release.
    release: enum { adopt, discover },
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
    const release = f.release orelse return .{ .release = if (f.adopted) .adopt else .discover };
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
    return release == .ok and order(f.selection.?.ok.released, release.ok) != .lt;
}

fn order(a: Version, b: Version) std.math.Order {
    const schema = std.math.order(a.schema, b.schema);
    return if (schema == .eq) std.math.order(a.patch, b.patch) else schema;
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
        adopted: bool,
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
        var trace: Trace = .{ .facts = .{ .mode = script.mode, .adopted = script.adopted } };
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
                    for (0..script.restart_failures) |_| tally.add(.{ .place = .other, .state = .failed });
                    tally.add(.{ .place = .own, .state = .{ .outcome = .{ .ready = .{ .instance = @splat(1), .pid = 7 } } } });
                    trace.facts.hosts = .{ .ok = tally.finish(null) };
                },
            }
        }
    }

    /// Every script: both modes, adopted or not, every selection (a release
    /// at each version), and no failure or one failure at each effect with
    /// each cause. One failure is enough: a run ends at its first.
    fn each(context: anytype, comptime visit: fn (@TypeOf(context), Script, ?std.math.Order) anyerror!void) !void {
        var worlds: usize = 0;
        for ([_]Mode{ .check, .install }) |mode| for ([_]bool{ false, true }) |adopted| {
            for (0..selections.len + versions.len) |index| {
                const selection: Selection, const ordered: ?std.math.Order = if (index < selections.len)
                    .{ selections[index], null }
                else
                    .{ .{ .released = versions[index - selections.len][0] }, versions[index - selections.len][1] };
                for (0..kinds.len * causes.len + 2) |choice| {
                    var script: Script = .{ .mode = mode, .adopted = adopted, .selection = selection };
                    if (choice < kinds.len * causes.len) {
                        script.failure = .{ kinds[choice / causes.len], causes[choice % causes.len] };
                    } else if (choice == kinds.len * causes.len + 1) {
                        script.restart_failures = 1;
                    }
                    try visit(context, script, ordered);
                    worlds += 1;
                }
            }
        };
        try std.testing.expectEqual(@as(usize, 2 * 2 * 9 * (7 * 5 + 2)), worlds);
    }
};

test "SH-72 a run observes the selection, then the release, then the Hosts" {
    try world.each({}, struct {
        fn visit(_: void, script: world.Script, _: ?std.math.Order) !void {
            const trace = try world.run(script);
            // The check's effects, cut after the first that fails.
            const observations = [_]Effect{ .inspect_selection, .{ .release = if (script.adopted) .adopt else .discover }, .census };
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
            // The release is read once, and not at all when it was handed over.
            var reads: usize = 0;
            for (trace.effects[0..trace.len]) |effect| if (effect == .release) {
                reads += 1;
                try std.testing.expectEqual(script.adopted, effect.release == .adopt);
            };
            try std.testing.expect(reads <= 1);
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
                    try std.testing.expectEqual(cause == .cancelled, activation.clientSafe(hosts.own));
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
