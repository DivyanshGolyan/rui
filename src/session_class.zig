//! What a Session means to the person looking at the list: whether it is listed, whose it is,
//! what it asks of them, which kind of work it shows and which provider trouble the list tells them about. One pure function of the facts a viewer
//! holds about the Session and of the viewer's own inputs, so every screen that lists Sessions
//! agrees; a screen draws the answer and never re-derives it from raw fields.

const std = @import("std");
const session_work = @import("session_work.zig");
const session_archive = @import("session_archive.zig");
const connection = @import("connection.zig");
const failure_class = @import("failure_class.zig");

pub const Kind = session_work.Kind;
pub const WorkState = session_work.WorkState;

pub const Standing = session_work.Standing;

/// The kind of work a viewer reads: its own unanswered stop already reads as stopping, whatever the Host last served.
pub fn withStop(work: Kind, stop_pending: bool) Kind {
    return if (stop_pending) .stopping else work;
}

/// The facts a viewer holds about one Session. Borrowed, never stored: the caller builds it from its own row.
pub const Facts = struct {
    /// The work as the Host last served it.
    state: *const WorkState,
    archive: session_archive.State,
    /// The Host's latest list answer still names the Session.
    in_list: bool,
    creator: bool,
    pinned: bool,
    first_message: bool,
    /// A person wrote to it, not only a peer.
    from_person: bool,
    /// An Action of it awaits this viewer's decision.
    decidable: bool,
    /// This viewer has its chat open.
    open: bool,
    /// This viewer's own stop is unanswered: the Session already counts as working it down.
    stop_pending: bool,
    provider: ?connection.Name,
    model: []const u8,
};

pub const Viewer = struct {
    filter: session_archive.Filter,
    now_ms: u64,
    /// When this device last signed in, in seconds: a failure older than it was about a credential since replaced.
    login_at: ?u64 = null,
};

pub const Class = struct {
    /// The kind of work shown: an Archived row reads stopped, a pending stop reads stopping, an awaited decision reads approval.
    kind: Kind,
    /// What the Host's work asks of the person. This viewer's own pending stop changes the kind shown and where the Session counts, never what the work asks.
    standing: Standing,
    /// Listed by default: still named by the Host, inside the archive filter, and either made, pinned or written to,
    /// or open in this viewer's chat. An empty Session nobody opened is not shown.
    visible: bool,
    /// The person wrote in it, or it has no first Message yet.
    yours: bool,
    /// A Session a peer started that asks nothing of the person: its row recedes.
    quiet: bool,
    /// Where the counts line counts it, or nowhere: only a visible, unarchived Session counts, and this viewer's own pending stop
    /// counts it as working.
    counted: ?Standing,
};

pub fn classify(facts: Facts, viewer: Viewer) Class {
    const state = facts.state.asOf(viewer.now_ms);
    const archived = facts.archive == .archived;
    const kind: Kind = if (archived)
        .stopped
    else if (facts.decidable and !facts.stop_pending)
        .approval
    else
        withStop(std.meta.activeTag(state), facts.stop_pending);
    // Standing follows the work as handed in. The overview advances each row's work with its clock on every tick, so a retry that has
    // fallen due arrives here as pending; `kind` also reads it so for a row not yet advanced.
    const own: Standing = if (archived) .done else session_work.standing(facts.state.*);
    const yours = !facts.first_message or facts.from_person;
    const visible = facts.in_list and viewer.filter.includes(facts.archive) and (facts.creator or facts.pinned or facts.first_message or facts.open);
    return .{
        .kind = kind,
        .standing = own,
        .visible = visible,
        .yours = yours,
        .quiet = !yours and !own.needsPerson(),
        .counted = if (!visible or archived) null else if (facts.stop_pending) .working else own,
    };
}

/// How many visible, unarchived Sessions sit in each standing; the overview's counts line.
pub const Counts = struct {
    needs_you: usize = 0,
    working: usize = 0,
    queued: usize = 0,
    failed: usize = 0,

    pub fn add(self: *Counts, class: Class) void {
        switch (class.counted orelse return) {
            .needs_you => self.needs_you += 1,
            .working => self.working += 1,
            .queued => self.queued += 1,
            .failed => self.failed += 1,
            .done => {},
        }
    }
};

pub const Trouble = failure_class.Trouble;

/// The Sessions a viewer holds, read one at a time, so the classifier needs neither a copy of them nor their owner's type.
pub const Rows = struct {
    context: *const anyopaque,
    count: usize,
    at: *const fn (context: *const anyopaque, index: usize) Facts,

    fn get(self: Rows, index: usize) Facts {
        return self.at(self.context, index);
    }
};

/// Provider trouble across the Sessions a viewer sees.
pub const Band = struct {
    trouble: Trouble,
    /// The Sessions retrying, for rate limits.
    sessions: u32 = 0,
    resets_at: ?u64 = null,
    provider: ?connection.Name = null,
};

/// The one provider trouble to tell the person about, or null. A failure is current until its provider and model answer
/// again: a visible, unarchived row on both whose answered state (a finished turn, or a tool call it proposed) began at or
/// after it. Rows on another provider or model say nothing about this one's quota or sign-in. Sign-in and key failures end
/// at the viewer's last sign-in, a quota failure at its reset; the order of `Trouble` is the order of precedence, with
/// rate limits last.
pub fn trouble(rows: Rows, viewer: Viewer) ?Band {
    const Held = struct { row: usize, failed: WorkState.Failed };
    var newest: [std.enums.values(Trouble).len]?Held = @splat(null);
    var limited: u32 = 0;
    for (0..rows.count) |index| {
        const facts = rows.get(index);
        if (!listedAndLive(facts, viewer)) continue;
        switch (facts.state.asOf(viewer.now_ms)) {
            .failed => |failed| if (failure_class.troubleOfFailure(failed.code.slice())) |found| {
                const slot = &newest[@backingInt(found)];
                if (slot.* == null or slot.*.?.failed.since < failed.since) slot.* = .{ .row = index, .failed = failed };
            },
            .retrying => |retry| if (failure_class.troubleOfRetry(retry.cause.slice()) != null) {
                limited += 1;
            },
            else => {},
        }
    }
    for (std.enums.values(Trouble), newest) |found, held_or_null| {
        if (found == .rate_limit) break;
        const held = held_or_null orelse continue;
        const failed = held.failed;
        if (reachedSince(rows, held.row, failed.since, viewer)) continue;
        if (found.clearedBySignIn()) if (viewer.login_at) |at| if (failed.since <= at) continue;
        if (found.endsAtReset()) if (failed.resets_at) |at| if (at <= viewer.now_ms / 1000) continue;
        return .{ .trouble = found, .resets_at = failed.resets_at, .provider = rows.get(held.row).provider };
    }
    if (limited != 0) return .{ .trouble = .rate_limit, .sessions = limited };
    return null;
}

fn listedAndLive(facts: Facts, viewer: Viewer) bool {
    return facts.archive != .archived and classify(facts, viewer).visible;
}

fn reachedSince(rows: Rows, failed_row: usize, since: u64, viewer: Viewer) bool {
    const failed = rows.get(failed_row);
    for (0..rows.count) |index| {
        const facts = rows.get(index);
        if (!listedAndLive(facts, viewer) or !connection.Name.eqlOptional(facts.provider, failed.provider) or !std.mem.eql(u8, facts.model, failed.model)) continue;
        const work = facts.state.asOf(viewer.now_ms);
        if (std.meta.activeTag(work).answered() and work.since() >= since) return true;
    }
    return false;
}

const Probe = struct {
    work: WorkState,
    standing: Standing,
};

// The work states with the standing each must have, written from the base client classification
// independently of `session_work.standing`; a failed Turn is its own standing.
const probes = [_]Probe{
    .{ .work = .{ .idle = .{ .since = 1 } }, .standing = .done },
    .{ .work = .{ .pending = .{ .since = 1 } }, .standing = .queued },
    .{ .work = .{ .working = .{ .since = 1 } }, .standing = .working },
    .{ .work = .{ .retrying = .{ .since = 1, .due_at_ms = 5_000, .cause = .{}, .attempt = 1 } }, .standing = .working },
    .{ .work = .{ .bash = .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 0 } }, .standing = .working },
    .{ .work = .{ .bash = .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 2 } }, .standing = .needs_you },
    .{ .work = .{ .approval = .{ .since = 1 } }, .standing = .needs_you },
    .{ .work = .{ .stopping = .{ .since = 1 } }, .standing = .working },
    .{ .work = .{ .finished = .{ .since = 1 } }, .standing = .done },
    .{ .work = .{ .failed = .{ .since = 1, .code = .{}, .resets_at = null } }, .standing = .failed },
    .{ .work = .{ .stopped = .{ .since = 1, .cause = .stop } }, .standing = .done },
};

test "SUI-169 a Session's class follows its work, archive state, listing and the viewer's inputs" {
    var cases: usize = 0;
    for (probes) |probe| for (std.enums.values(session_archive.State)) |archive| for (std.enums.values(session_archive.Filter)) |filter| {
        for (0..1 << 7) |bits| {
            const in_list = bits & 1 != 0;
            const creator = bits & 2 != 0;
            const pinned = bits & 4 != 0;
            const first_message = bits & 8 != 0;
            const from_person = bits & 16 != 0;
            const decidable = bits & 32 != 0;
            const open = bits & 64 != 0;
            for ([_]bool{ false, true }) |stop_pending| {
                // A retry that has fallen due reads as pending work in its kind only; its standing follows the state handed in.
                for ([_]u64{ 1_000, 5_000 }) |now_ms| {
                    const facts: Facts = .{ .state = &probe.work, .archive = archive, .in_list = in_list, .creator = creator, .pinned = pinned, .first_message = first_message, .from_person = from_person, .decidable = decidable, .open = open, .stop_pending = stop_pending, .provider = null, .model = "" };
                    const got = classify(facts, .{ .filter = filter, .now_ms = now_ms });
                    const archived = archive == .archived;
                    const due = probe.work == .retrying and now_ms >= probe.work.retrying.due_at_ms;
                    const expected_standing: Standing = if (archived) .done else probe.standing;
                    const expected_kind: Kind = if (archived) .stopped else if (stop_pending) .stopping else if (decidable) .approval else if (due) .pending else std.meta.activeTag(probe.work);
                    const listed = in_list and switch (filter) {
                        .active => !archived,
                        .archived => archived,
                        .all => true,
                    };
                    const expected_yours = !first_message or from_person;
                    try std.testing.expectEqual(expected_kind, got.kind);
                    try std.testing.expectEqual(expected_standing, got.standing);
                    try std.testing.expectEqual(listed and (creator or pinned or first_message or open), got.visible);
                    try std.testing.expectEqual(expected_yours, got.yours);
                    try std.testing.expectEqual(!expected_yours and expected_standing != .needs_you and expected_standing != .failed, got.quiet);

                    var counts: Counts = .{};
                    counts.add(got);
                    const counted = got.visible and !archived;
                    // This viewer's unanswered stop moves the Session into working for the count only.
                    const counted_as: Standing = if (stop_pending) .working else expected_standing;
                    try std.testing.expectEqual(counted and counted_as == .needs_you, counts.needs_you == 1);
                    try std.testing.expectEqual(counted and counted_as == .working, counts.working == 1);
                    try std.testing.expectEqual(counted and counted_as == .queued, counts.queued == 1);
                    try std.testing.expectEqual(counted and counted_as == .failed, counts.failed == 1);
                    cases += 1;
                }
            }
        }
    };
    try std.testing.expectEqual(probes.len * 3 * 3 * 128 * 2 * 2, cases);
}

fn testRows(facts: *const []const Facts) Rows {
    const Read = struct {
        fn at(context: *const anyopaque, index: usize) Facts {
            const all: *const []const Facts = @ptrCast(@alignCast(context));
            return all.*[index];
        }
    };
    return .{ .context = @ptrCast(facts), .count = facts.len, .at = Read.at };
}

fn failedWork(code: []const u8, since: u64, resets_at: ?u64) WorkState {
    var bounded: @FieldType(WorkState.Failed, "code") = .{};
    bounded.set(code) catch unreachable;
    return .{ .failed = .{ .since = since, .code = bounded, .resets_at = resets_at } };
}

fn retryingWork(cause: []const u8, due_at_ms: u64) WorkState {
    var bounded: @FieldType(WorkState.Retrying, "cause") = .{};
    bounded.set(cause) catch unreachable;
    return .{ .retrying = .{ .since = 1, .due_at_ms = due_at_ms, .cause = bounded, .attempt = 1 } };
}

fn listedFacts(state: *const WorkState, provider: []const u8, model: []const u8) Facts {
    return .{ .state = state, .archive = .active, .in_list = true, .creator = true, .pinned = false, .first_message = true, .from_person = true, .decidable = false, .open = false, .stop_pending = false, .provider = connection.Name.parse(provider), .model = model };
}

test "SUI-170 provider trouble follows failures, answers since, sign-in and resets, then retries" {
    const now_s: u64 = 10_000;
    const viewer: Viewer = .{ .filter = .active, .now_ms = now_s * 1000 };
    const sign_in = failedWork("provider_http_401", 100, null);
    const api_key = failedWork("provider_api_key_rejected", 100, null);
    const quota = failedWork("provider_quota", 100, now_s + 60);
    const spent_quota = failedWork("provider_quota", 100, now_s - 1);
    const other_failure = failedWork("provider_policy", 100, null);
    const newer_sign_in = failedWork("provider_http_401", 120, null);
    const edge_quota = failedWork("provider_quota", 100, now_s);
    const limited = retryingWork("provider_temporary_http_429", (now_s + 5) * 1000);
    const due_limit = retryingWork("provider_temporary_http_429", now_s * 1000);
    const transient = retryingWork("provider_temporary_error", (now_s + 5) * 1000);
    const answered_later: WorkState = .{ .finished = .{ .since = 200 } };
    const answered_before: WorkState = .{ .finished = .{ .since = 50 } };
    const proposed: WorkState = .{ .bash = .{ .since = 150, .call = 0, .description = null, .running = 1, .approvals = 0 } };
    const thinking: WorkState = .{ .working = .{ .since = 300 } };

    // Each case is the rows of one list, then the band the viewer is told about.
    const Case = struct { rows: []const Facts, viewer: Viewer = viewer, expected: ?Band };
    var archived_answer = listedFacts(&answered_later, "codex", "m");
    archived_answer.archive = .archived;
    var unlisted_answer = listedFacts(&answered_later, "codex", "m");
    unlisted_answer.in_list = false;
    var empty_answer = listedFacts(&answered_later, "codex", "m");
    empty_answer.creator = false;
    empty_answer.first_message = false;
    var archived_failure = listedFacts(&newer_sign_in, "openai", "m");
    archived_failure.archive = .archived;
    var unlisted_failure = listedFacts(&newer_sign_in, "openai", "m");
    unlisted_failure.in_list = false;
    const cases = [_]Case{
        .{ .rows = &.{listedFacts(&sign_in, "codex", "m")}, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{listedFacts(&api_key, "codex", "m")}, .expected = .{ .trouble = .api_key, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{listedFacts(&quota, "codex", "m")}, .expected = .{ .trouble = .quota, .resets_at = now_s + 60, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{listedFacts(&spent_quota, "codex", "m")}, .expected = null },
        .{ .rows = &.{listedFacts(&other_failure, "codex", "m")}, .expected = null },
        // A later answer on the same provider and model clears it; an earlier one, another model, another provider or a row nobody lists does not.
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&answered_later, "codex", "m") }, .expected = null },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&proposed, "codex", "m") }, .expected = null },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&thinking, "codex", "m") }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&answered_before, "codex", "m") }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&answered_later, "codex", "other") }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&answered_later, "openai", "m") }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), archived_answer }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), unlisted_answer }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), empty_answer }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        // A sign-in after the failure clears a credential failure but not a quota failure.
        .{ .rows = &.{listedFacts(&sign_in, "codex", "m")}, .viewer = .{ .filter = .active, .now_ms = viewer.now_ms, .login_at = 100 }, .expected = null },
        .{ .rows = &.{listedFacts(&api_key, "codex", "m")}, .viewer = .{ .filter = .active, .now_ms = viewer.now_ms, .login_at = 99 }, .expected = .{ .trouble = .api_key, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{listedFacts(&quota, "codex", "m")}, .viewer = .{ .filter = .active, .now_ms = viewer.now_ms, .login_at = 5000 }, .expected = .{ .trouble = .quota, .resets_at = now_s + 60, .provider = connection.Name.parse("codex") } },
        // Precedence, and the newest failure of a trouble is the one named.
        .{ .rows = &.{ listedFacts(&quota, "codex", "m"), listedFacts(&sign_in, "openai", "m"), listedFacts(&limited, "codex", "m") }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("openai") } },
        .{ .rows = &.{ listedFacts(&quota, "codex", "m"), listedFacts(&limited, "codex", "m") }, .expected = .{ .trouble = .quota, .resets_at = now_s + 60, .provider = connection.Name.parse("codex") } },
        // The newest failure of a trouble is the one named, in either row order; a tie keeps the first row.
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&newer_sign_in, "openai", "m") }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("openai") } },
        .{ .rows = &.{ listedFacts(&newer_sign_in, "openai", "m"), listedFacts(&sign_in, "codex", "m") }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("openai") } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&sign_in, "openai", "m") }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        // Only the newest failure is judged against the answers: an answer to it hides an older failure of the same trouble too.
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&newer_sign_in, "openai", "m"), listedFacts(&answered_later, "openai", "m") }, .expected = null },
        // An archived or unlisted failure names nothing.
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), archived_failure }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), unlisted_failure }, .expected = .{ .trouble = .sign_in, .provider = connection.Name.parse("codex") } },
        // A failure that is over, answered or ended, falls through to rate limits.
        .{ .rows = &.{ listedFacts(&spent_quota, "codex", "m"), listedFacts(&limited, "codex", "m") }, .expected = .{ .trouble = .rate_limit, .sessions = 1 } },
        .{ .rows = &.{ listedFacts(&sign_in, "codex", "m"), listedFacts(&answered_later, "codex", "m"), listedFacts(&limited, "codex", "n") }, .expected = .{ .trouble = .rate_limit, .sessions = 1 } },
        // A reset time that has just been reached ends a quota failure; a sign-in at the failure's own second is the last that clears it.
        .{ .rows = &.{listedFacts(&edge_quota, "codex", "m")}, .expected = null },
        .{ .rows = &.{listedFacts(&sign_in, "codex", "m")}, .viewer = .{ .filter = .all, .now_ms = viewer.now_ms, .login_at = 101 }, .expected = null },
        // Rate limits count their Sessions; a due retry reads as pending work, and other retries ask nothing.
        .{ .rows = &.{ listedFacts(&limited, "codex", "m"), listedFacts(&limited, "codex", "n"), listedFacts(&transient, "codex", "m") }, .expected = .{ .trouble = .rate_limit, .sessions = 2 } },
        .{ .rows = &.{ listedFacts(&due_limit, "codex", "m"), listedFacts(&transient, "codex", "m") }, .expected = null },
    };
    for (cases, 0..) |case, number| {
        errdefer std.debug.print("provider trouble case {d}\n", .{number});
        try std.testing.expectEqualDeep(case.expected, trouble(testRows(&case.rows), case.viewer));
    }
}
