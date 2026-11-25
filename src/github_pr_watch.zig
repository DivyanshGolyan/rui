const std = @import("std");

/// Owner and repository borrow from the input URL, which must outlive the key.
pub const PrKey = struct {
    owner: []const u8,
    repo: []const u8,
    number: u64,
};

/// Accept only an unambiguous GitHub.com web URL. API routes are constructed
/// from these validated components, never from the original URL.
pub fn parseUrl(url: []const u8) error{InvalidUrl}!PrKey {
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidUrl;
    var parts = std.mem.splitScalar(u8, url[prefix.len..], '/');
    const owner = parts.next() orelse return error.InvalidUrl;
    const repo = parts.next() orelse return error.InvalidUrl;
    const pull = parts.next() orelse return error.InvalidUrl;
    const number_text = parts.next() orelse return error.InvalidUrl;
    if (parts.next() != null or !std.mem.eql(u8, pull, "pull")) return error.InvalidUrl;
    if (!validOwner(owner) or !validRepo(repo) or number_text.len == 0 or number_text.len > 20) return error.InvalidUrl;
    for (number_text) |c| if (!std.ascii.isDigit(c)) return error.InvalidUrl;
    // One numeric spelling per pull request number; owner and repository keep the
    // caller's case, which GitHub treats as the same pull request.
    if (number_text[0] == '0') return error.InvalidUrl;
    const number = std.fmt.parseInt(u64, number_text, 10) catch return error.InvalidUrl;
    return .{ .owner = owner, .repo = repo, .number = number };
}

fn validOwner(s: []const u8) bool {
    if (s.len == 0 or s.len > 39 or !std.ascii.isAlphanumeric(s[0]) or !std.ascii.isAlphanumeric(s[s.len - 1])) return false;
    for (s, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
        if (c == '-' and i > 0 and s[i - 1] == '-') return false;
    }
    return true;
}

fn validRepo(s: []const u8) bool {
    if (s.len == 0 or s.len > 100 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}

/// Digests and identities are fixed-width binary values; no API text is
/// retained in the observation or emitted in a snapshot.
pub const Digest = [20]u8;
pub const Identity = [32]u8;
pub const Lifecycle = enum { open, draft, closed, merged };
pub const Checks = enum { pending, passing, failing, incomplete };
pub const Reviews = enum { none, pending, approved, changes_requested, incomplete };
pub const Coverage = enum { complete, partial };
pub const CheckState = enum { pending, success, failure, neutral, skipped };
pub const CheckSource = enum { check_run, commit_status };

/// The identity must include the check's stable identity (or status context).
/// Source keeps a check run and a legacy status with the same identity apart.
/// updated_at and id form the deterministic ordering of reruns.
pub const Check = struct {
    source: CheckSource,
    identity: Identity,
    updated_at: i64,
    id: u64,
    state: CheckState,
};

pub const ReviewDecision = enum { approved, changes_requested, dismissed, comment };
pub const Review = struct {
    reviewer: Identity,
    submitted_at: i64,
    id: u64,
    decision: ReviewDecision,
    /// Whether GitHub's observed review applies to the current head. The
    /// transport must conservatively decide this; branch rules are not known.
    applicable: bool,
};

pub const Observation = struct {
    observed_at: i64,
    head_before: Digest,
    head_after: Digest,
    lifecycle: Lifecycle,
    checks: []const Check,
    checks_coverage: Coverage,
    reviews: []const Review,
    reviews_coverage: Coverage,
    review_requested: bool,
};

pub const Snapshot = struct {
    observed_at: i64,
    head: Digest,
    lifecycle: Lifecycle,
    checks: Checks,
    reviews: Reviews,
};
pub const Changes = packed struct {
    head: bool = false,
    lifecycle: bool = false,
    checks: bool = false,
    reviews: bool = false,
};
pub const Reduction = struct {
    snapshot: Snapshot,
    changed: Changes,
    coverage: Coverage,
};

/// The dimensions of `current` that differ from `previous`; everything differs from no previous snapshot.
/// Checks and reviews differ only between two complete values: a dimension a partial page left
/// `incomplete` on either side says nothing about the pull request, so it is never a change.
pub fn changesBetween(previous: ?Snapshot, current: Snapshot) Changes {
    const old = previous orelse return .{ .head = true, .lifecycle = true, .checks = true, .reviews = true };
    return .{
        .head = !std.mem.eql(u8, &old.head, &current.head),
        .lifecycle = old.lifecycle != current.lifecycle,
        .checks = old.checks != current.checks and old.checks != .incomplete and current.checks != .incomplete,
        .reviews = old.reviews != current.reviews and old.reviews != .incomplete and current.reviews != .incomplete,
    };
}

/// The baseline a later poll compares against: `baseline`, except that a checks or reviews value it
/// could not complete adopts the complete value `current` reports. Without this an `incomplete`
/// baseline would never compare equal to anything and the dimension could never end the watch.
pub fn rebase(baseline: Snapshot, current: Snapshot) Snapshot {
    var next = baseline;
    if (baseline.checks == .incomplete) next.checks = current.checks;
    if (baseline.reviews == .incomplete) next.reviews = current.reviews;
    return next;
}

/// The transport must collect checks for head_before, re-read head_after,
/// bound each input slice, and mark truncated or unavailable sources partial.
/// A head race invalidates the entire observation; nothing stale is emitted.
pub fn reduce(previous: ?Snapshot, observation: Observation) error{HeadChanged}!Reduction {
    if (!std.mem.eql(u8, &observation.head_before, &observation.head_after)) return error.HeadChanged;
    const snapshot: Snapshot = .{
        .observed_at = observation.observed_at,
        .head = observation.head_before,
        .lifecycle = observation.lifecycle,
        .checks = reduceChecks(observation.checks, observation.checks_coverage),
        .reviews = reduceReviews(observation.reviews, observation.reviews_coverage, observation.review_requested),
    };
    const changed = changesBetween(previous, snapshot);
    return .{
        .snapshot = snapshot,
        .changed = changed,
        .coverage = if (observation.checks_coverage == .complete and observation.reviews_coverage == .complete) .complete else .partial,
    };
}

fn newer(time: i64, id: u64, other_time: i64, other_id: u64) bool {
    return time > other_time or (time == other_time and id > other_id);
}

fn reduceChecks(checks: []const Check, coverage: Coverage) Checks {
    if (coverage == .partial) return .incomplete;
    var any = false;
    var pending = false;
    for (checks, 0..) |check, i| {
        var superseded = false;
        for (checks, 0..) |other, j| {
            if (i == j or check.source != other.source or !std.mem.eql(u8, &check.identity, &other.identity)) continue;
            if (newer(other.updated_at, other.id, check.updated_at, check.id)) {
                superseded = true;
                break;
            }
        }
        if (superseded) continue;
        any = true;
        switch (check.state) {
            .failure => return .failing,
            .pending => pending = true,
            .success, .neutral, .skipped => {},
        }
    }
    if (!any or pending) return .pending;
    return .passing;
}

fn reduceReviews(reviews: []const Review, coverage: Coverage, requested: bool) Reviews {
    if (coverage == .partial) return .incomplete;
    var approved = false;
    for (reviews, 0..) |review, i| {
        if (!review.applicable or review.decision == .comment) continue;
        var superseded = false;
        for (reviews, 0..) |other, j| {
            if (i == j or !other.applicable or other.decision == .comment or !std.mem.eql(u8, &review.reviewer, &other.reviewer)) continue;
            if (newer(other.submitted_at, other.id, review.submitted_at, review.id)) {
                superseded = true;
                break;
            }
        }
        if (superseded) continue;
        switch (review.decision) {
            .changes_requested => return .changes_requested,
            .approved => approved = true,
            .dismissed, .comment => {},
        }
    }
    if (requested) return .pending;
    return if (approved) .approved else .none;
}

/// How a watch ended; the tag is the Resolution's `outcome`. `changed`, `closed`,
/// `merged` and `no_change` deliver the latest snapshot; the failures end a watch
/// that could not keep observing; the rest refuse before any observation.
pub const Outcome = enum {
    changed,
    closed,
    merged,
    no_change,
    network_failure,
    rate_limited,
    revoked,
    pr_inaccessible,
    account_unavailable,
    gh_unavailable,
    account_discovery_failed,

    /// Whether the model asked for what it got: a delivered snapshot, even at the deadline. The rest are
    /// failures it can act on: pick another account, fix access, or call again later.
    pub fn succeeds(self: Outcome) bool {
        return switch (self) {
            .changed, .closed, .merged, .no_change => true,
            else => false,
        };
    }

    fn carriesSnapshot(self: Outcome) bool {
        return switch (self) {
            .changed, .closed, .merged, .no_change, .network_failure, .rate_limited => true,
            .revoked, .pr_inaccessible, .account_unavailable, .gh_unavailable, .account_discovery_failed => false,
        };
    }
};

/// Whether `current` ends a watch whose first observation was `baseline`. A closed or merged pull request
/// always ends it. Otherwise a new head, a lifecycle change or a reviews change ends it, and a checks
/// change ends it only into a settled state: pending moves alone do not. Changes are those of
/// `changesBetween`, so a dimension that is `incomplete` on either side never ends a watch.
pub fn endingOutcome(baseline: Snapshot, current: Snapshot) ?Outcome {
    switch (current.lifecycle) {
        .closed => return .closed,
        .merged => return .merged,
        .open, .draft => {},
    }
    const changed = changesBetween(baseline, current);
    if (changed.head or changed.lifecycle or changed.reviews) return .changed;
    if (changed.checks and (current.checks == .passing or current.checks == .failing)) return .changed;
    return null;
}

/// The latest observation a Resolution reports, with what differs from the baseline.
pub const Latest = struct { snapshot: Snapshot, changed: Changes, coverage: Coverage };

/// The longest a rate-limit hint holds a watch, and so the longest the fetch layer reports.
pub const max_retry_seconds: i64 = 3600;
/// Consecutive failed polls that end a watch; one good poll resets the count.
pub const max_failures = 5;

/// How long a watch waits, in milliseconds. Production waits are the defaults; a loopback fixture scales
/// every wait down so it sees a poll in milliseconds, never a different decision.
pub const Pacing = struct {
    poll_ms: u64 = 60_000,
    poll_jitter_ms: u64 = 5000,
    /// One second of failure backoff and rate-limit waiting.
    second_ms: u64 = 1000,
    /// The wait when the Host-wide request budget is spent.
    budget_wait_ms: u64 = 40_000,

    pub const loopback: Pacing = .{ .poll_ms = 100, .poll_jitter_ms = 10, .second_ms = 10, .budget_wait_ms = 300 };
};

/// What one watch has decided so far, and the one place that decides what happens next. The worker only
/// fetches, sleeps and applies the `Decision`; every outcome, count and wait is chosen here.
pub const Watch = struct {
    pacing: Pacing,
    /// Spreads the polls of watches that started together.
    seed: u64,
    /// The first observation, completed by later ones where it was `incomplete`.
    baseline: ?Snapshot = null,
    /// The latest observation, with what differs from the baseline.
    latest: ?Latest = null,
    failures: u8 = 0,

    pub const Fault = enum {
        /// The token no longer authenticates, or no longer belongs to the bound account.
        revoked,
        /// The pull request cannot be read under the bound account.
        inaccessible,
        /// The Host-wide request budget is spent: pacing, not a failure of this watch.
        budget_exhausted,
        rate_limited,
        /// Anything else that failed this poll: transport, a bad page, a head race.
        transient,
    };

    pub const Event = union(enum) {
        /// The watch's deadline has passed.
        expired,
        observed: struct { snapshot: Snapshot, coverage: Coverage },
        /// `seen_at` is when the failure was observed, in unix seconds, the clock `retry_at` is on.
        failed: struct { fault: Fault, retry_at: ?i64 = null, seen_at: i64, remaining_ms: u64 },
    };

    pub const End = struct { outcome: Outcome, latest: ?Latest = null, retry_at: ?i64 = null };
    pub const Decision = union(enum) { wait_ms: u64, end: End };

    pub fn step(self: *Watch, event: Event) Decision {
        switch (event) {
            .expired => return self.ended(.no_change, null),
            .observed => |observed| {
                const first = self.baseline orelse observed.snapshot;
                self.latest = .{ .snapshot = observed.snapshot, .changed = changesBetween(first, observed.snapshot), .coverage = observed.coverage };
                self.baseline = rebase(first, observed.snapshot);
                if (endingOutcome(first, observed.snapshot)) |outcome| return self.ended(outcome, null);
                self.failures = 0;
                return .{ .wait_ms = self.pacing.poll_ms + self.jitter(self.pacing.poll_jitter_ms) };
            },
            .failed => |failed| switch (failed.fault) {
                .revoked => return self.ended(.revoked, null),
                .inaccessible => return self.ended(.pr_inaccessible, null),
                .budget_exhausted => return .{ .wait_ms = self.pacing.budget_wait_ms + self.jitter(self.pacing.budget_wait_ms) },
                .rate_limited, .transient => {
                    self.failures +|= 1;
                    const limited = failed.fault == .rate_limited;
                    const hold_ms = self.backoffMs(failed.retry_at, failed.seen_at);
                    // A hold that would outlast the deadline is reported now: the model can call again then.
                    if (limited and failed.retry_at != null and hold_ms >= failed.remaining_ms) return self.ended(.rate_limited, failed.retry_at);
                    if (self.failures >= max_failures) return self.ended(if (limited) .rate_limited else .network_failure, failed.retry_at);
                    return .{ .wait_ms = hold_ms };
                },
            },
        }
    }

    fn ended(self: *const Watch, outcome: Outcome, retry_at: ?i64) Decision {
        return .{ .end = .{ .outcome = outcome, .latest = self.latest, .retry_at = retry_at } };
    }

    fn jitter(self: *const Watch, modulus: u64) u64 {
        return if (modulus == 0) 0 else self.seed % modulus;
    }

    /// A rate-limit time the response named (unix seconds, clamped by the fetch layer), else exponential seconds.
    fn backoffMs(self: *const Watch, retry_at: ?i64, seen_at: i64) u64 {
        const seconds: u64 = if (retry_at) |when|
            @intCast(@max(1, @min(max_retry_seconds, when - seen_at)))
        else
            @as(u64, 1) << @intCast(@min(self.failures, 6));
        return seconds * self.pacing.second_ms + self.jitter(self.pacing.second_ms);
    }
};

pub const max_resolution_bytes = 8192;

/// Builds the Resolution text of a finished watch from typed values only: no response body, title,
/// review text or check output can reach it. `retry_at` is reported for `rate_limited` alone.
pub fn encodeOutcome(buffer: []u8, outcome: Outcome, latest: ?Latest, retry_at: ?i64) error{NoSpaceLeft}![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    out.print("{{\"outcome\":\"{s}\"", .{@tagName(outcome)}) catch return error.NoSpaceLeft;
    if (outcome.carriesSnapshot()) {
        if (latest) |value| {
            const snapshot = value.snapshot;
            out.print(",\"snapshot\":{{\"observed_at\":{d},\"head_sha\":\"{x}\",\"lifecycle\":\"{s}\",\"checks\":\"{s}\",\"reviews\":\"{s}\"}},\"changed\":[", .{
                snapshot.observed_at,
                &snapshot.head,
                @tagName(snapshot.lifecycle),
                @tagName(snapshot.checks),
                @tagName(snapshot.reviews),
            }) catch return error.NoSpaceLeft;
            var first = true;
            for ([_]struct { name: []const u8, changed: bool }{
                .{ .name = "head", .changed = value.changed.head },
                .{ .name = "lifecycle", .changed = value.changed.lifecycle },
                .{ .name = "checks", .changed = value.changed.checks },
                .{ .name = "reviews", .changed = value.changed.reviews },
            }) |dimension| {
                if (!dimension.changed) continue;
                out.print("{s}\"{s}\"", .{ if (first) "" else ",", dimension.name }) catch return error.NoSpaceLeft;
                first = false;
            }
            out.print("],\"coverage\":\"{s}\"", .{@tagName(value.coverage)}) catch return error.NoSpaceLeft;
        } else out.writeAll(",\"snapshot\":null") catch return error.NoSpaceLeft;
    }
    if (outcome == .rate_limited) {
        if (retry_at) |when| out.print(",\"retry_at\":{d}", .{when}) catch return error.NoSpaceLeft else out.writeAll(",\"retry_at\":null") catch return error.NoSpaceLeft;
    }
    out.writeAll("}") catch return error.NoSpaceLeft;
    return out.buffered();
}

/// The Resolution of a watch that started without an account: no authenticated account, or several to choose from.
/// `names` are sorted logins that already passed `validLogin`, so they need no escaping.
pub fn encodeAccountChoice(buffer: []u8, names: []const []const u8) error{NoSpaceLeft}![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    if (names.len == 0) {
        out.writeAll("{\"outcome\":\"auth_required\",\"host\":\"github.com\"}") catch return error.NoSpaceLeft;
        return out.buffered();
    }
    out.writeAll("{\"outcome\":\"account_required\",\"host\":\"github.com\",\"usernames\":[") catch return error.NoSpaceLeft;
    for (names, 0..) |name, i| out.print("{s}\"{s}\"", .{ if (i == 0) "" else ",", name }) catch return error.NoSpaceLeft;
    out.writeAll("]}") catch return error.NoSpaceLeft;
    return out.buffered();
}

test "PRW-1 URL accepts only bounded unambiguous GitHub pull requests" {
    _ = try parseUrl("https://github.com/alice_acme/repo/pull/1");
    try std.testing.expectError(error.InvalidUrl, parseUrl("https://github.com/_alice/repo/pull/1"));
    const key = try parseUrl("https://github.com/Octocat/a-repo_1.git/pull/42");
    try std.testing.expectEqualStrings("Octocat", key.owner);
    try std.testing.expectEqualStrings("a-repo_1.git", key.repo);
    try std.testing.expectEqual(@as(u64, 42), key.number);
    const bad = [_][]const u8{
        "http://github.com/a/b/pull/1",                     "https://GITHUB.com/a/b/pull/1",
        "https://github.com.evil/a/b/pull/1",               "https://x@github.com/a/b/pull/1",
        "https://github.com:443/a/b/pull/1",                "https://github.com/a/b/pull/0",
        "https://github.com/a/b/pull/01",                   "https://github.com/a/b/pull/1/",
        "https://github.com/a/b/pull/1?q=x",                "https://github.com/a/b/pull/1#x",
        "https://github.com/a/%62/pull/1",                  "https://github.com/a/../pull/1",
        "https://github.com/a/b/pull/18446744073709551616", "https://github.com/a--b/b/pull/1",
        "https://github.com/a/b/issues/1",                  "https://github.com/a/b/pull/+1",
    };
    for (bad) |url| try std.testing.expectError(error.InvalidUrl, parseUrl(url));
}

test "PRW-2 typed observations reject head races and report only semantic changes" {
    const a: Digest = @splat(1);
    const b: Digest = @splat(2);
    var obs: Observation = .{ .observed_at = 1, .head_before = a, .head_after = a, .lifecycle = .open, .checks = &.{}, .checks_coverage = .complete, .reviews = &.{}, .reviews_coverage = .complete, .review_requested = false };
    const first = try reduce(null, obs);
    try std.testing.expectEqual(Checks.pending, first.snapshot.checks);
    try std.testing.expectEqual(Reviews.none, first.snapshot.reviews);
    try std.testing.expectEqual(Changes{ .head = true, .lifecycle = true, .checks = true, .reviews = true }, first.changed);
    obs.observed_at = 2;
    const same = try reduce(first.snapshot, obs);
    try std.testing.expectEqual(Changes{}, same.changed);
    obs.head_after = b;
    try std.testing.expectError(error.HeadChanged, reduce(first.snapshot, obs));
    obs.head_before = b;
    obs.lifecycle = .merged;
    const changed = try reduce(first.snapshot, obs);
    try std.testing.expect(changed.changed.head and changed.changed.lifecycle);
    try std.testing.expectEqual(Checks.pending, changed.snapshot.checks);
    // An approval for the old head must be marked inapplicable by the fetcher.
    const old_approval = [_]Review{.{ .reviewer = @splat(1), .submitted_at = 1, .id = 1, .decision = .approved, .applicable = true }};
    obs.head_before = a;
    obs.head_after = a;
    obs.reviews = &old_approval;
    const approved = try reduce(null, obs);
    try std.testing.expectEqual(Reviews.approved, approved.snapshot.reviews);
    var stale_approval = old_approval;
    stale_approval[0].applicable = false;
    obs.head_before = b;
    obs.head_after = b;
    obs.reviews = &stale_approval;
    const reset = try reduce(approved.snapshot, obs);
    try std.testing.expectEqual(Reviews.none, reset.snapshot.reviews);
    try std.testing.expect(reset.changed.head and reset.changed.reviews);
    obs.checks_coverage = .partial;
    obs.reviews_coverage = .partial;
    const partial = try reduce(changed.snapshot, obs);
    try std.testing.expectEqual(Coverage.partial, partial.coverage);
    try std.testing.expectEqual(Checks.incomplete, partial.snapshot.checks);
    try std.testing.expectEqual(Reviews.incomplete, partial.snapshot.reviews);
}

test "PRW-3 latest check runs and status contexts determine aggregate checks" {
    const one: Identity = @splat(1);
    const checks = [_]Check{
        .{ .source = .check_run, .identity = one, .updated_at = 1, .id = 1, .state = .failure },
        .{ .source = .check_run, .identity = one, .updated_at = 2, .id = 2, .state = .success },
        .{ .source = .commit_status, .identity = one, .updated_at = 1, .id = 3, .state = .pending },
    };
    try std.testing.expectEqual(Checks.pending, testChecks(&checks, .complete));
    try std.testing.expectEqual(Checks.passing, testChecks(checks[0..2], .complete));
    try std.testing.expectEqual(Checks.failing, testChecks(checks[0..1], .complete));
    try std.testing.expectEqual(Checks.incomplete, testChecks(&checks, .partial));
    for ([_]CheckState{ .success, .neutral, .skipped }) |state| {
        const item = [_]Check{.{ .source = .check_run, .identity = one, .updated_at = 1, .id = 1, .state = state }};
        try std.testing.expectEqual(Checks.passing, testChecks(&item, .complete));
    }
}

test "PRW-4 latest applicable reviewer decisions determine observed reviews" {
    const one: Identity = @splat(1);
    const two: Identity = @splat(2);
    var reviews = [_]Review{
        .{ .reviewer = one, .submitted_at = 1, .id = 1, .decision = .changes_requested, .applicable = true },
        .{ .reviewer = one, .submitted_at = 2, .id = 2, .decision = .approved, .applicable = true },
        .{ .reviewer = one, .submitted_at = 3, .id = 3, .decision = .comment, .applicable = true },
        .{ .reviewer = two, .submitted_at = 1, .id = 4, .decision = .changes_requested, .applicable = true },
    };
    try std.testing.expectEqual(Reviews.approved, testReviews(reviews[0..3], .complete, false));
    try std.testing.expectEqual(Reviews.changes_requested, testReviews(&reviews, .complete, false));
    reviews[3].applicable = false;
    try std.testing.expectEqual(Reviews.pending, testReviews(&reviews, .complete, true));
    reviews[1].decision = .dismissed;
    try std.testing.expectEqual(Reviews.none, testReviews(&reviews, .complete, false));
    try std.testing.expectEqual(Reviews.incomplete, testReviews(&reviews, .partial, false));
    // On a force-push back to A, the newer decision on B is inapplicable.
    const force_push_back = [_]Review{
        .{ .reviewer = one, .submitted_at = 1, .id = 1, .decision = .approved, .applicable = true },
        .{ .reviewer = one, .submitted_at = 2, .id = 2, .decision = .changes_requested, .applicable = false },
    };
    try std.testing.expectEqual(Reviews.approved, testReviews(&force_push_back, .complete, false));
    var dismissed = force_push_back;
    dismissed[1].decision = .dismissed;
    try std.testing.expectEqual(Reviews.approved, testReviews(&dismissed, .complete, false));
    dismissed[1].applicable = true;
    try std.testing.expectEqual(Reviews.none, testReviews(&dismissed, .complete, false));
}

fn testChecks(checks: []const Check, coverage: Coverage) Checks {
    const head: Digest = @splat(0);
    const result = reduce(null, .{ .observed_at = 0, .head_before = head, .head_after = head, .lifecycle = .open, .checks = checks, .checks_coverage = coverage, .reviews = &.{}, .reviews_coverage = .complete, .review_requested = false }) catch unreachable;
    return result.snapshot.checks;
}

fn testReviews(reviews: []const Review, coverage: Coverage, requested: bool) Reviews {
    const head: Digest = @splat(0);
    const result = reduce(null, .{ .observed_at = 0, .head_before = head, .head_after = head, .lifecycle = .open, .checks = &.{}, .checks_coverage = .complete, .reviews = reviews, .reviews_coverage = coverage, .review_requested = requested }) catch unreachable;
    return result.snapshot.reviews;
}

fn testSnapshot(lifecycle: Lifecycle, checks: Checks, reviews: Reviews) Snapshot {
    return .{ .observed_at = 7, .head = @splat(0xab), .lifecycle = lifecycle, .checks = checks, .reviews = reviews };
}

test "PRW-61 a watch ends on a new head, lifecycle, reviews, settled checks or a closed pull request" {
    const base = testSnapshot(.open, .pending, .none);
    try std.testing.expectEqual(@as(?Outcome, null), endingOutcome(base, base));
    // Checks moving among unsettled states, or out of a settled one, never end a watch alone.
    try std.testing.expectEqual(@as(?Outcome, null), endingOutcome(base, testSnapshot(.open, .incomplete, .none)));
    try std.testing.expectEqual(@as(?Outcome, null), endingOutcome(testSnapshot(.open, .passing, .none), testSnapshot(.open, .pending, .none)));
    try std.testing.expectEqual(@as(?Outcome, null), endingOutcome(testSnapshot(.open, .passing, .none), testSnapshot(.open, .incomplete, .none)));
    // A partial page is no change either way: PRW-73 owns the whole domain.
    try std.testing.expectEqual(@as(?Outcome, null), endingOutcome(testSnapshot(.open, .incomplete, .none), testSnapshot(.open, .passing, .none)));
    try std.testing.expectEqual(@as(?Outcome, null), endingOutcome(base, testSnapshot(.open, .pending, .incomplete)));
    for ([_]Checks{ .passing, .failing }) |settled| {
        try std.testing.expectEqual(@as(?Outcome, .changed), endingOutcome(base, testSnapshot(.open, settled, .none)));
    }
    try std.testing.expectEqual(@as(?Outcome, .changed), endingOutcome(testSnapshot(.open, .passing, .none), testSnapshot(.open, .failing, .none)));
    for ([_]Reviews{ .pending, .approved, .changes_requested }) |reviews| {
        try std.testing.expectEqual(@as(?Outcome, .changed), endingOutcome(base, testSnapshot(.open, .pending, reviews)));
    }
    try std.testing.expectEqual(@as(?Outcome, .changed), endingOutcome(base, testSnapshot(.draft, .pending, .none)));
    var moved = base;
    moved.head = @splat(0xcd);
    try std.testing.expectEqual(@as(?Outcome, .changed), endingOutcome(base, moved));
    try std.testing.expectEqual(@as(?Outcome, .closed), endingOutcome(base, testSnapshot(.closed, .pending, .none)));
    try std.testing.expectEqual(@as(?Outcome, .merged), endingOutcome(base, testSnapshot(.merged, .pending, .none)));
    // A pull request that is already closed ends its watch at the baseline.
    const closed = testSnapshot(.closed, .passing, .approved);
    try std.testing.expectEqual(@as(?Outcome, .closed), endingOutcome(closed, closed));
}

fn changedIf(ends: bool) ?Outcome {
    return if (ends) Outcome.changed else null;
}

const all_checks = [_]Checks{ .pending, .passing, .failing, .incomplete };
const all_reviews = [_]Reviews{ .none, .pending, .approved, .changes_requested, .incomplete };

test "PRW-73 checks and reviews change only between two complete values" {
    for (all_checks) |before| for (all_checks) |after| {
        const complete = before != .incomplete and after != .incomplete;
        const old = testSnapshot(.open, before, .none);
        const new = testSnapshot(.open, after, .none);
        try std.testing.expectEqual(complete and before != after, changesBetween(old, new).checks);
        // A settled state ends the watch only when the move into it is a real one.
        const ends = complete and before != after and (after == .passing or after == .failing);
        try std.testing.expectEqual(changedIf(ends), endingOutcome(old, new));
    };
    for (all_reviews) |before| for (all_reviews) |after| {
        const complete = before != .incomplete and after != .incomplete;
        const old = testSnapshot(.open, .pending, before);
        const new = testSnapshot(.open, .pending, after);
        try std.testing.expectEqual(complete and before != after, changesBetween(old, new).reviews);
        try std.testing.expectEqual(changedIf(complete and before != after), endingOutcome(old, new));
    };
    // The first observation still differs from nothing in every dimension.
    try std.testing.expectEqual(Changes{ .head = true, .lifecycle = true, .checks = true, .reviews = true }, changesBetween(null, testSnapshot(.open, .incomplete, .incomplete)));
    // A head or lifecycle move ends the watch whatever the partial dimensions say.
    var moved = testSnapshot(.open, .incomplete, .incomplete);
    moved.head = @splat(0xcd);
    try std.testing.expectEqual(@as(?Outcome, .changed), endingOutcome(testSnapshot(.open, .incomplete, .incomplete), moved));
    try std.testing.expectEqual(@as(?Outcome, .merged), endingOutcome(testSnapshot(.open, .passing, .none), testSnapshot(.merged, .incomplete, .incomplete)));
}

test "PRW-74 a baseline completes only the dimensions it could not read" {
    for (all_checks) |before| for (all_checks) |after| {
        const next = rebase(testSnapshot(.open, before, .approved), testSnapshot(.open, after, .none));
        try std.testing.expectEqual(if (before == .incomplete) after else before, next.checks);
        // Reviews were complete in the baseline, so they never move.
        try std.testing.expectEqual(Reviews.approved, next.reviews);
    };
    for (all_reviews) |before| for (all_reviews) |after| {
        const next = rebase(testSnapshot(.open, .pending, before), testSnapshot(.open, .passing, after));
        try std.testing.expectEqual(if (before == .incomplete) after else before, next.reviews);
        try std.testing.expectEqual(Checks.pending, next.checks);
    };
    // Everything else stays the baseline's: the head and lifecycle are compared, never adopted.
    var current = testSnapshot(.draft, .passing, .approved);
    current.head = @splat(0xcd);
    current.observed_at = 99;
    const next = rebase(testSnapshot(.open, .incomplete, .incomplete), current);
    try std.testing.expectEqual(Lifecycle.open, next.lifecycle);
    try std.testing.expectEqual(@as(i64, 7), next.observed_at);
    try std.testing.expectEqualSlices(u8, &testSnapshot(.open, .pending, .none).head, &next.head);
}

fn seen(snapshot: Snapshot, coverage: Coverage) Watch.Event {
    return .{ .observed = .{ .snapshot = snapshot, .coverage = coverage } };
}

fn failedPoll(fault: Watch.Fault, retry_at: ?i64, remaining_ms: u64) Watch.Event {
    return .{ .failed = .{ .fault = fault, .retry_at = retry_at, .seen_at = 1000, .remaining_ms = remaining_ms } };
}

fn expectWait(expected_ms: u64, decision: Watch.Decision) !void {
    try std.testing.expectEqual(Watch.Decision{ .wait_ms = expected_ms }, decision);
}

fn expectEnd(outcome: Outcome, retry_at: ?i64, decision: Watch.Decision) !void {
    try std.testing.expect(decision == .end);
    try std.testing.expectEqual(outcome, decision.end.outcome);
    try std.testing.expectEqual(retry_at, decision.end.retry_at);
}

test "PRW-75 a watch polls until a real change, and a partial page neither ends it nor blinds it" {
    var state: Watch = .{ .pacing = .{ .poll_ms = 1000, .poll_jitter_ms = 100 }, .seed = 7 };
    // Every poll waits the interval plus this watch's own jitter.
    try expectWait(1007, state.step(seen(testSnapshot(.open, .pending, .none), .complete)));
    try expectWait(1007, state.step(seen(testSnapshot(.open, .pending, .none), .complete)));
    // One bad reviews page reads as incomplete reviews: no change, and the gap is reported as partial coverage.
    try expectWait(1007, state.step(seen(testSnapshot(.open, .pending, .incomplete), .partial)));
    try std.testing.expectEqual(Coverage.partial, state.latest.?.coverage);
    try std.testing.expectEqual(Changes{}, state.latest.?.changed);
    try expectWait(1007, state.step(seen(testSnapshot(.open, .pending, .none), .complete)));
    try std.testing.expectEqual(Reviews.none, state.baseline.?.reviews);
    // A real change ends it with the latest snapshot and what differs from the baseline.
    var moved = testSnapshot(.open, .pending, .none);
    moved.head = @splat(0xcd);
    const ended = state.step(seen(moved, .complete));
    try expectEnd(.changed, null, ended);
    try std.testing.expectEqual(Changes{ .head = true }, ended.end.latest.?.changed);
    try std.testing.expectEqualSlices(u8, &moved.head, &ended.end.latest.?.snapshot.head);

    // A baseline whose checks were incomplete takes the first complete value, so settling later still ends it.
    var partial_first: Watch = .{ .pacing = .{}, .seed = 0 };
    _ = partial_first.step(seen(testSnapshot(.open, .incomplete, .none), .partial));
    try std.testing.expect(partial_first.step(seen(testSnapshot(.open, .passing, .none), .complete)) == .wait_ms);
    // The poll that first completes the checks is the baseline, not a change; the next move ends the watch.
    try std.testing.expectEqual(Checks.passing, partial_first.baseline.?.checks);
    try expectEnd(.changed, null, partial_first.step(seen(testSnapshot(.open, .failing, .none), .complete)));

    // Closed and merged end a watch at the first sight of them.
    var closed: Watch = .{ .pacing = .{}, .seed = 0 };
    try expectEnd(.closed, null, closed.step(seen(testSnapshot(.closed, .pending, .none), .complete)));
    var merged: Watch = .{ .pacing = .{}, .seed = 0 };
    try expectEnd(.merged, null, merged.step(seen(testSnapshot(.merged, .pending, .none), .complete)));
}

test "PRW-76 failures back off, recover, and end the watch only when they cannot be waited out" {
    const pacing: Pacing = .{ .second_ms = 1000, .budget_wait_ms = 400 };
    // Five transient failures in a row end it as a network failure, each waiting twice as long as the last.
    var failing: Watch = .{ .pacing = pacing, .seed = 0 };
    _ = failing.step(seen(testSnapshot(.open, .pending, .none), .complete));
    for ([_]u64{ 2000, 4000, 8000, 16_000 }) |hold| try expectWait(hold, failing.step(failedPoll(.transient, null, 3_600_000)));
    const network = failing.step(failedPoll(.transient, null, 3_600_000));
    try expectEnd(.network_failure, null, network);
    try std.testing.expect(network.end.latest != null);

    // A good poll in between resets the count: four more failures are all waited out.
    var recovering: Watch = .{ .pacing = pacing, .seed = 0 };
    for (0..4) |_| try std.testing.expect(recovering.step(failedPoll(.transient, null, 3_600_000)) == .wait_ms);
    _ = recovering.step(seen(testSnapshot(.open, .pending, .none), .complete));
    for (0..4) |_| try std.testing.expect(recovering.step(failedPoll(.transient, null, 3_600_000)) == .wait_ms);
    try expectEnd(.network_failure, null, recovering.step(failedPoll(.transient, null, 3_600_000)));

    // A rate limit whose named time lies past the deadline ends at once with that time; a shorter one waits it out.
    var limited: Watch = .{ .pacing = pacing, .seed = 0 };
    try expectEnd(.rate_limited, 1030, limited.step(failedPoll(.rate_limited, 1030, 20_000)));
    var waits: Watch = .{ .pacing = pacing, .seed = 0 };
    try expectWait(30_000, waits.step(failedPoll(.rate_limited, 1030, 60_000)));
    try std.testing.expect(waits.step(failedPoll(.rate_limited, 1030, 30_000)) == .end);
    // Without a named time, repeated rate limits end as rate_limited after the same five tries.
    var unnamed: Watch = .{ .pacing = pacing, .seed = 0 };
    for (0..4) |_| try std.testing.expect(unnamed.step(failedPoll(.rate_limited, null, 3_600_000)) == .wait_ms);
    try expectEnd(.rate_limited, null, unnamed.step(failedPoll(.rate_limited, null, 3_600_000)));
    // A rate limit that comes last names the failure even after transient ones.
    var mixed: Watch = .{ .pacing = pacing, .seed = 0 };
    for (0..4) |_| _ = mixed.step(failedPoll(.transient, null, 3_600_000));
    try expectEnd(.rate_limited, null, mixed.step(failedPoll(.rate_limited, null, 3_600_000)));
    // A named time already in the past still waits one second, never zero.
    var past: Watch = .{ .pacing = pacing, .seed = 0 };
    try expectWait(1000, past.step(failedPoll(.rate_limited, 900, 3_600_000)));
}

test "PRW-77 pacing, revocation, inaccessibility and the deadline" {
    const pacing: Pacing = .{ .second_ms = 1000, .budget_wait_ms = 400 };
    // A spent request budget paces the watch without counting as one of its failures.
    var paced: Watch = .{ .pacing = pacing, .seed = 5 };
    for (0..4) |_| _ = paced.step(failedPoll(.transient, null, 3_600_000));
    for (0..10) |_| try expectWait(405, paced.step(failedPoll(.budget_exhausted, null, 3_600_000)));
    try expectEnd(.network_failure, null, paced.step(failedPoll(.transient, null, 3_600_000)));

    // A token that stopped authenticating, or a pull request that cannot be read, ends it at the first sight.
    var revoked: Watch = .{ .pacing = pacing, .seed = 0 };
    try expectEnd(.revoked, null, revoked.step(failedPoll(.revoked, null, 3_600_000)));
    var inaccessible: Watch = .{ .pacing = pacing, .seed = 0 };
    try expectEnd(.pr_inaccessible, null, inaccessible.step(failedPoll(.inaccessible, null, 3_600_000)));

    // The deadline ends it as no_change with the latest snapshot, or with none when no poll ever succeeded.
    var never: Watch = .{ .pacing = pacing, .seed = 0 };
    const empty = never.step(.expired);
    try expectEnd(.no_change, null, empty);
    try std.testing.expect(empty.end.latest == null);
    var observed: Watch = .{ .pacing = pacing, .seed = 0 };
    _ = observed.step(seen(testSnapshot(.open, .pending, .none), .complete));
    const late = observed.step(.expired);
    try expectEnd(.no_change, null, late);
    try std.testing.expect(late.end.latest != null);

    // A model gets a success only for a delivered snapshot.
    for (std.enums.values(Outcome)) |outcome| {
        const delivered = outcome == .changed or outcome == .closed or outcome == .merged or outcome == .no_change;
        try std.testing.expectEqual(delivered, outcome.succeeds());
    }
}

test "PRW-62 a Resolution holds only typed values" {
    var buffer: [max_resolution_bytes]u8 = undefined;
    const latest: Latest = .{ .snapshot = testSnapshot(.open, .passing, .approved), .changed = .{ .head = true, .checks = true }, .coverage = .partial };
    try std.testing.expectEqualStrings(
        "{\"outcome\":\"changed\",\"snapshot\":{\"observed_at\":7,\"head_sha\":\"abababababababababababababababababababab\",\"lifecycle\":\"open\",\"checks\":\"passing\",\"reviews\":\"approved\"},\"changed\":[\"head\",\"checks\"],\"coverage\":\"partial\"}",
        try encodeOutcome(&buffer, .changed, latest, null),
    );
    try std.testing.expectEqualStrings(
        "{\"outcome\":\"no_change\",\"snapshot\":{\"observed_at\":7,\"head_sha\":\"abababababababababababababababababababab\",\"lifecycle\":\"open\",\"checks\":\"pending\",\"reviews\":\"none\"},\"changed\":[],\"coverage\":\"complete\"}",
        try encodeOutcome(&buffer, .no_change, .{ .snapshot = testSnapshot(.open, .pending, .none), .changed = .{}, .coverage = .complete }, 99),
    );
    // A watch that never saw the pull request says so, rather than reporting a snapshot it does not have.
    try std.testing.expectEqualStrings("{\"outcome\":\"no_change\",\"snapshot\":null}", try encodeOutcome(&buffer, .no_change, null, null));
    try std.testing.expectEqualStrings("{\"outcome\":\"rate_limited\",\"snapshot\":null,\"retry_at\":1234}", try encodeOutcome(&buffer, .rate_limited, null, 1234));
    try std.testing.expectEqualStrings("{\"outcome\":\"rate_limited\",\"snapshot\":null,\"retry_at\":null}", try encodeOutcome(&buffer, .rate_limited, null, null));
    try std.testing.expectEqualStrings("{\"outcome\":\"network_failure\",\"snapshot\":null}", try encodeOutcome(&buffer, .network_failure, null, 5));
    for ([_]Outcome{ .revoked, .pr_inaccessible, .account_unavailable, .gh_unavailable, .account_discovery_failed }) |refusal| {
        const text = try encodeOutcome(&buffer, refusal, latest, 5);
        var expected: [64]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"outcome\":\"{s}\"}}", .{@tagName(refusal)}), text);
    }
    try std.testing.expectError(error.NoSpaceLeft, encodeOutcome(buffer[0..20], .changed, latest, null));
}

test "PRW-63 an account choice lists the sorted logins or asks for authentication" {
    var buffer: [max_resolution_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("{\"outcome\":\"auth_required\",\"host\":\"github.com\"}", try encodeAccountChoice(&buffer, &.{}));
    try std.testing.expectEqualStrings("{\"outcome\":\"account_required\",\"host\":\"github.com\",\"usernames\":[\"alice\",\"bob_2\"]}", try encodeAccountChoice(&buffer, &.{ "alice", "bob_2" }));
}
