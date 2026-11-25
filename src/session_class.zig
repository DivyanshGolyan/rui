//! What a Session means to the person looking at the list: whether it is listed, whose it is,
//! what it asks of them and which kind of work it shows. One pure function of the facts a viewer
//! holds about the Session and of the viewer's own inputs, so every screen that lists Sessions
//! agrees; a screen draws the answer and never re-derives it from raw fields.

const std = @import("std");
const session_work = @import("session_work.zig");
const session_archive = @import("session_archive.zig");

pub const Kind = session_work.Kind;
pub const WorkState = session_work.WorkState;

/// What a Session's work asks of the person. `failed` is its own standing; the served `Group` folded it into `done`.
pub const Standing = enum {
    /// An Action awaits a decision: an approval, or a Bash proposal with approvals pending.
    needs_you,
    /// Thinking, retrying, stopping, or running a command that waits on nobody.
    working,
    /// Waiting for a model slot, or a retry that has fallen due.
    queued,
    failed,
    /// Idle, finished or stopped: nothing is running and nothing is asked.
    done,

    pub fn needsPerson(self: Standing) bool {
        return self == .needs_you or self == .failed;
    }
};

/// The standing of work as the Host served it.
pub fn standing(state: WorkState) Standing {
    return switch (state) {
        .approval => .needs_you,
        .bash => |bash| if (bash.approvals != 0) .needs_you else .working,
        .working, .retrying, .stopping => .working,
        .pending => .queued,
        .failed => .failed,
        .idle, .finished, .stopped => .done,
    };
}

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
};

pub const Viewer = struct {
    filter: session_archive.Filter,
    now_ms: u64,
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
    const own: Standing = if (archived) .done else standing(facts.state.*);
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

const Probe = struct {
    work: WorkState,
    group: enum { needs_you, working, queued, done },
};

// The work states as Host-served groups, written from the base client classification (the overview's
// ordering over the served `group`), independently of `standing`.
const probes = [_]Probe{
    .{ .work = .{ .idle = .{ .since = 1 } }, .group = .done },
    .{ .work = .{ .pending = .{ .since = 1 } }, .group = .queued },
    .{ .work = .{ .working = .{ .since = 1 } }, .group = .working },
    .{ .work = .{ .retrying = .{ .since = 1, .due_at_ms = 5_000, .cause = .{}, .attempt = 1 } }, .group = .working },
    .{ .work = .{ .bash = .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 0 } }, .group = .working },
    .{ .work = .{ .bash = .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 2 } }, .group = .needs_you },
    .{ .work = .{ .approval = .{ .since = 1 } }, .group = .needs_you },
    .{ .work = .{ .stopping = .{ .since = 1 } }, .group = .working },
    .{ .work = .{ .finished = .{ .since = 1 } }, .group = .done },
    .{ .work = .{ .failed = .{ .since = 1, .code = .{}, .resets_at = null } }, .group = .done },
    .{ .work = .{ .stopped = .{ .since = 1, .cause = .stop } }, .group = .done },
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
                    const facts: Facts = .{ .state = &probe.work, .archive = archive, .in_list = in_list, .creator = creator, .pinned = pinned, .first_message = first_message, .from_person = from_person, .decidable = decidable, .open = open, .stop_pending = stop_pending };
                    const got = classify(facts, .{ .filter = filter, .now_ms = now_ms });
                    const archived = archive == .archived;
                    const due = probe.work == .retrying and now_ms >= probe.work.retrying.due_at_ms;
                    const expected_standing: Standing = if (archived)
                        .done
                    else switch (probe.group) {
                        .needs_you => .needs_you,
                        .working => .working,
                        .queued => .queued,
                        .done => if (probe.work == .failed) .failed else .done,
                    };
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
