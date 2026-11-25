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
pub fn changesBetween(previous: ?Snapshot, current: Snapshot) Changes {
    const old = previous orelse return .{ .head = true, .lifecycle = true, .checks = true, .reviews = true };
    return .{
        .head = !std.mem.eql(u8, &old.head, &current.head),
        .lifecycle = old.lifecycle != current.lifecycle,
        .checks = old.checks != current.checks,
        .reviews = old.reviews != current.reviews,
    };
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
