const std = @import("std");
const watch = @import("github_pr_watch.zig");
const parse = @import("github_observation.zig");
const transport = @import("github_transport.zig");
const pressure = @import("github_watch_pressure.zig");
const transport_policy = @import("transport_policy.zig");
const secrets = @import("secret_value.zig");

pub const Budget = struct { context: *anyopaque, acquire: *const fn (*anyopaque) bool };

pub const Result = struct {
    observation: watch.Observation,
    checks: []watch.Check,
    reviews: []watch.Review,
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.checks);
        allocator.free(self.reviews);
        self.* = undefined;
    }
};

fn json(wiping: *secrets.WipingAllocator, response: anytype) !std.json.Parsed(std.json.Value) {
    if (response.status != 200) return error.HttpFailure;
    return std.json.parseFromSlice(std.json.Value, wiping.allocator(), response.body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidResponse,
    };
}

// Only numeric timing leaves the private HTTP response. Invalid
// headers are ignored and the runner applies its ordinary backoff.
fn responseStatus(response: anytype, now: i64, retry_at: *?i64) !void {
    const limited = response.status == 429 or (response.status == 403 and (response.retry_after != null or (if (response.rate_remaining) |remaining| std.mem.eql(u8, remaining, "0") else false)));
    if (limited) {
        var when = now;
        if (response.retry_after) |header| {
            if (transport_policy.parseRetryAfter(header, now)) |constraint| {
                when = switch (constraint) {
                    .delay_ms => |delay_ms| std.math.add(i64, now, @intCast(delay_ms / 1000)) catch std.math.maxInt(i64),
                    .deadline_ms => |deadline_ms| @max(when, @divFloor(deadline_ms, 1000)),
                };
            } else if (header.len > 0) {
                // A number too large to represent holds the watch for the full cap.
                var digits_only = true;
                for (header) |c| if (!std.ascii.isDigit(c)) {
                    digits_only = false;
                    break;
                };
                if (digits_only) when = std.math.maxInt(i64);
            }
        }
        if (response.rate_reset) |header| {
            if (std.fmt.parseInt(i64, header, 10)) |reset| {
                when = @max(when, reset);
            } else |_| {}
        }
        // A header never holds a watch for longer than the cap; the runner still ends it at its deadline.
        if (when > now) retry_at.* = @min(when, std.math.add(i64, now, watch.max_retry_seconds) catch std.math.maxInt(i64));
        return error.RateLimited;
    }
    if (response.status == 401) return error.AuthenticationFailed;
    if (response.status == 403 or response.status == 404) return error.AccessDenied;
    if (response.status != 200) return error.HttpFailure;
}

/// Returns only typed facts. All bodies and identity strings remain private.
/// The caller owns Result and must deinit it with the supplied allocator.
pub fn fetch(allocator: std.mem.Allocator, io: std.Io, secret: *const transport.Secret, login: []const u8, pr: watch.PrKey, observed_at: i64, deadline: transport.Deadline, cancel: transport.Cancel, cache: *pressure.Cache, budget: *const Budget, retry_at: *?i64) !Result {
    retry_at.* = null;
    var backend: Backend = .{ .cache = cache, .budget = budget, .login = login };
    return fetchInternal(false, &backend, allocator, io, secret, login, pr, observed_at, deadline, cancel, "", retry_at);
}

pub const fetchForTest = if (@import("builtin").is_test or @import("build_options").test_pauses) fetchLoopback else {};
fn fetchLoopback(allocator: std.mem.Allocator, io: std.Io, secret: *const transport.Secret, login: []const u8, pr: watch.PrKey, observed_at: i64, deadline: transport.Deadline, cancel: transport.Cancel, origin: []const u8, cache: *pressure.Cache, budget: *const Budget, retry_at: *?i64) !Result {
    retry_at.* = null;
    var backend: Backend = .{ .cache = cache, .budget = budget, .login = login };
    return fetchInternal(true, &backend, allocator, io, secret, login, pr, observed_at, deadline, cancel, origin, retry_at);
}

const Backend = struct {
    cache: *pressure.Cache,
    budget: *const Budget,
    login: []const u8,
    fn get(self: *Backend, comptime test_mode: bool, allocator: std.mem.Allocator, io: std.Io, secret: *const transport.Secret, endpoint: transport.Endpoint, deadline: transport.Deadline, cancel: transport.Cancel, origin: []const u8, scope: ?watch.Digest) !transport.Response {
        if (cancel.load(.acquire)) return error.Cancelled;
        if (!self.budget.acquire(self.budget.context)) return error.RequestBudgetExhausted;
        const cached = if (endpoint == .identity) null else self.cache.get(self.login, endpoint, scope);
        const validator: ?[]const u8 = if (cached) |entry| entry.etag else null;
        var response = if (comptime test_mode)
            try transport.getForTest(allocator, io, secret, endpoint, validator, deadline, cancel, origin)
        else
            try transport.get(allocator, io, secret, endpoint, validator, deadline, cancel);
        errdefer response.deinit(allocator);
        if (response.status == 304) {
            const entry = cached orelse return error.InvalidResponse;
            const copy = try pressure.clone(allocator, entry);
            response.deinit(allocator);
            return copy;
        }
        if (response.status == 200 and endpoint != .identity) {
            const reflected = secret.bytes.len > 0 and (std.mem.indexOf(u8, response.body, secret.bytes) != null or
                (if (response.etag) |value| std.mem.indexOf(u8, value, secret.bytes) != null else false) or
                (if (response.link) |value| std.mem.indexOf(u8, value, secret.bytes) != null else false));
            if (reflected) {
                var uncached = response;
                uncached.etag = null;
                try self.cache.put(allocator, self.login, endpoint, scope, &uncached);
            } else try self.cache.put(allocator, self.login, endpoint, scope, &response);
        }
        return response;
    }
};

fn fetchInternal(comptime test_mode: bool, backend: anytype, allocator: std.mem.Allocator, io: std.Io, secret: *const transport.Secret, login: []const u8, pr: watch.PrKey, observed_at: i64, deadline: transport.Deadline, cancel: transport.Cancel, origin: []const u8, retry_at: *?i64) !Result {
    var wiping: secrets.WipingAllocator = .{ .backing = allocator };
    var identity_response = try backend.get(test_mode, allocator, io, secret, .identity, deadline, cancel, origin, null);
    defer identity_response.deinit(allocator);
    try responseStatus(&identity_response, @intCast(std.Io.Clock.real.now(io).toSeconds()), retry_at);
    var identity_json = try json(&wiping, &identity_response);
    defer identity_json.deinit();
    if (identity_json.value != .object) return error.IdentityMismatch;
    const actual = identity_json.value.object.get("login") orelse return error.IdentityMismatch;
    if (actual != .string or !std.ascii.eqlIgnoreCase(actual.string, login)) return error.IdentityMismatch;

    var first_response = try backend.get(test_mode, allocator, io, secret, .{ .pr = pr }, deadline, cancel, origin, null);
    defer first_response.deinit(allocator);
    try responseStatus(&first_response, @intCast(std.Io.Clock.real.now(io).toSeconds()), retry_at);
    var first_json = try json(&wiping, &first_response);
    defer first_json.deinit();
    const first = try parse.pull(first_json.value);
    const check_buffer = try allocator.alloc(watch.Check, 2000);
    errdefer allocator.free(check_buffer);
    const review_buffer = try allocator.alloc(watch.Review, 1000);
    errdefer allocator.free(review_buffer);
    var checks: parse.Checks = .{ .items = check_buffer };
    var reviews: parse.Reviews = .{ .items = review_buffer };
    const runs_complete = try pages(test_mode, backend, allocator, io, secret, pr, first.head, deadline, cancel, origin, retry_at, .runs, &checks, &reviews);
    const statuses_complete = try pages(test_mode, backend, allocator, io, secret, pr, first.head, deadline, cancel, origin, retry_at, .statuses, &checks, &reviews);
    const reviews_complete = try pages(test_mode, backend, allocator, io, secret, pr, first.head, deadline, cancel, origin, retry_at, .reviews, &checks, &reviews);
    var last_response = try backend.get(test_mode, allocator, io, secret, .{ .pr = pr }, deadline, cancel, origin, null);
    defer last_response.deinit(allocator);
    try responseStatus(&last_response, @intCast(std.Io.Clock.real.now(io).toSeconds()), retry_at);
    var last_json = try json(&wiping, &last_response);
    defer last_json.deinit();
    const last = try parse.pull(last_json.value);
    if (!std.mem.eql(u8, &first.head, &last.head)) return error.HeadChanged;
    return .{ .checks = check_buffer, .reviews = review_buffer, .observation = .{
        .observed_at = observed_at,
        .head_before = first.head,
        .head_after = last.head,
        .lifecycle = last.lifecycle,
        .checks = check_buffer[0..checks.len],
        .checks_coverage = if (runs_complete and statuses_complete) .complete else .partial,
        .reviews = review_buffer[0..reviews.len],
        .reviews_coverage = if (reviews_complete) .complete else .partial,
        .review_requested = last.review_requested,
    } };
}

const Kind = enum { runs, statuses, reviews };
fn pages(comptime test_mode: bool, backend: anytype, allocator: std.mem.Allocator, io: std.Io, secret: *const transport.Secret, pr: watch.PrKey, head: watch.Digest, deadline: transport.Deadline, cancel: transport.Cancel, origin: []const u8, retry_at: *?i64, kind: Kind, checks: *parse.Checks, reviews: *parse.Reviews) !bool {
    var wiping: secrets.WipingAllocator = .{ .backing = allocator };
    var page: u8 = 1;
    var count: usize = 0;
    var expected: ?u64 = null;
    while (page <= 10) : (page += 1) {
        const endpoint: transport.Endpoint = switch (kind) {
            .runs => .{ .check_runs = .{ .pr = pr, .head = head, .page = page } },
            .statuses => .{ .status = .{ .pr = pr, .head = head, .page = page } },
            .reviews => .{ .reviews = .{ .pr = pr, .page = page } },
        };
        var response = backend.get(test_mode, allocator, io, secret, endpoint, deadline, cancel, origin, head) catch |err| switch (err) {
            // Only an HTTP-level answer can mean partial coverage; a transport failure is retried by the runner.
            else => return err,
        };
        defer response.deinit(allocator);
        responseStatus(&response, @intCast(std.Io.Clock.real.now(io).toSeconds()), retry_at) catch |err| switch (err) {
            error.AuthenticationFailed, error.RateLimited => return err,
            else => return false,
        };
        if (!validLinks(response.link, pr, head, kind)) return false;
        var parsed = json(&wiping, &response) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        defer parsed.deinit();
        const checks_before = checks.len;
        const reviews_before = reviews.len;
        const result = switch (kind) {
            .runs => parse.checks(parsed.value, head, checks),
            .statuses => parse.statuses(parsed.value, head, checks),
            .reviews => parse.reviews(parsed.value, head, reviews),
        } catch return false;
        // Repeated IDs imply unstable or overlapping pages; they cannot prove
        // that every item was observed even when the total count matches.
        switch (kind) {
            .runs, .statuses => for (checks.items[checks_before..checks.len], checks_before..) |item, i| {
                for (checks.items[0..i]) |previous| {
                    if (item.source == previous.source and item.id == previous.id) return false;
                }
            },
            .reviews => for (reviews.items[reviews_before..reviews.len], reviews_before..) |item, i| {
                for (reviews.items[0..i]) |previous| if (item.id == previous.id) {
                    return false;
                };
            },
        }
        count += result.count;
        if (result.total) |total| {
            if (expected) |previous| if (previous != total) return false;
            expected = total;
            if (count > total) return false;
        }
        if (result.count < 100) {
            const has_next = if (response.link) |link| std.mem.indexOf(u8, link, "; rel=\"next\"") != null else false;
            return !has_next and (if (expected) |total| count == total else true);
        }
    }
    return false;
}

// Links are never followed. Reject even an unused destination outside the
// exact approved endpoint; the next page number is constructed locally.
fn validLinks(link: ?[]const u8, pr: watch.PrKey, head: watch.Digest, kind: Kind) bool {
    const text = link orelse return true;
    var buffer: [512]u8 = undefined;
    const prefix = switch (kind) {
        .reviews => std.fmt.bufPrint(&buffer, "https://api.github.com/repos/{s}/{s}/pulls/{d}/reviews?", .{ pr.owner, pr.repo, pr.number }),
        .runs => std.fmt.bufPrint(&buffer, "https://api.github.com/repos/{s}/{s}/commits/{s}/check-runs?", .{ pr.owner, pr.repo, std.fmt.bytesToHex(head, .lower) }),
        .statuses => std.fmt.bufPrint(&buffer, "https://api.github.com/repos/{s}/{s}/commits/{s}/status?", .{ pr.owner, pr.repo, std.fmt.bytesToHex(head, .lower) }),
    } catch return false;
    var entries = std.mem.splitScalar(u8, text, ',');
    while (entries.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " ");
        if (entry.len < 4 or entry[0] != '<') return false;
        const end = std.mem.indexOfScalar(u8, entry, '>') orelse return false;
        const url = entry[1..end];
        if (!std.mem.startsWith(u8, url, prefix)) return false;
        const query = url[prefix.len..];
        var parts = std.mem.splitScalar(u8, query, '&');
        var per_page = false;
        var page_number = false;
        var all_runs = false;
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "per_page=100") and !per_page) {
                per_page = true;
            } else if (std.mem.startsWith(u8, part, "page=") and !page_number) {
                const number = part[5..];
                if (number.len == 0) return false;
                for (number) |c| if (!std.ascii.isDigit(c)) return false;
                const n = std.fmt.parseInt(u16, number, 10) catch return false;
                if (n == 0) return false;
                page_number = true;
            } else if (kind == .runs and std.mem.eql(u8, part, "filter=all") and !all_runs) {
                all_runs = true;
            } else return false;
        }
        if (!per_page or !page_number or (kind == .runs and !all_runs)) return false;
        const rel = std.mem.trim(u8, entry[end + 1 ..], " ");
        if (!std.mem.eql(u8, rel, "; rel=\"next\"") and !std.mem.eql(u8, rel, "; rel=\"last\"") and !std.mem.eql(u8, rel, "; rel=\"prev\"") and !std.mem.eql(u8, rel, "; rel=\"first\"")) return false;
    }
    return true;
}

test "PRW-6 pagination links stay on the approved endpoint" {
    const pr: watch.PrKey = .{ .owner = "org", .repo = "repo", .number = 5 };
    const head: watch.Digest = @splat(0);
    try std.testing.expect(validLinks(null, pr, head, .reviews));
    try std.testing.expect(validLinks("<https://api.github.com/repos/org/repo/pulls/5/reviews?page=2&per_page=100>; rel=\"next\"", pr, head, .reviews));
    try std.testing.expect(validLinks("<https://api.github.com/repos/org/repo/pulls/5/reviews?per_page=100&page=2>; rel=\"next\"", pr, head, .reviews));
    try std.testing.expect(validLinks("<https://api.github.com/repos/org/repo/commits/0000000000000000000000000000000000000000/check-runs?per_page=100&page=2&filter=all>; rel=\"next\"", pr, head, .runs));
    try std.testing.expect(validLinks("<https://api.github.com/repos/org/repo/commits/0000000000000000000000000000000000000000/check-runs?filter=all&page=2&per_page=100>; rel=\"next\"", pr, head, .runs));
    try std.testing.expect(!validLinks("<https://api.github.com/repos/org/repo/commits/0000000000000000000000000000000000000000/check-runs?per_page=100&page=2>; rel=\"next\"", pr, head, .runs));
    try std.testing.expect(!validLinks("<https://api.github.com/repos/org/repo/commits/0000000000000000000000000000000000000000/check-runs?per_page=100&page=2&filter=latest>; rel=\"next\"", pr, head, .runs));
    const bad = [_][]const u8{
        "<https://evil.example/repos/org/repo/pulls/5/reviews?per_page=100&page=2>; rel=\"next\"",
        "<https://api.github.com/repos/org/other/pulls/5/reviews?per_page=100&page=2>; rel=\"next\"",
        "<https://api.github.com/repos/org/repo/pulls/5/reviews?per_page=100&page=2&access_token=x>; rel=\"next\"",
        "<https://api.github.com/repos/org/repo/pulls/5/reviews?per_page=100&page=0>; rel=\"next\"",
        "<https://api.github.com/repos/org/repo/pulls/5/reviews?per_page=100&page=+2>; rel=\"next\"",
        "<https://api.github.com/repos/org/repo/pulls/5/reviews?page=2&per_page=100&page=3>; rel=\"next\"",
        "<https://api.github.com/repos/org/repo/pulls/5/reviews?page=2&per_page=100&per_page=100>; rel=\"next\"",
        "<https://api.github.com/repos/org/repo/pulls/5/reviews?page=2&per_page=100&filter=all>; rel=\"next\"",
        "<https://api.github.com/repos/org/repo/pulls/5/reviews?per_page=100&page=2>; rel=\"other\"",
    };
    for (bad) |link| try std.testing.expect(!validLinks(link, pr, head, .reviews));
}

test "PRW-15 rate limits expose only bounded retry times" {
    var retry: ?i64 = null;
    var response: struct { status: u16 = 429, retry_after: ?[]const u8 = "90", rate_reset: ?[]const u8 = "1300", rate_remaining: ?[]const u8 = null } = .{};
    try std.testing.expectError(error.RateLimited, responseStatus(&response, 1000, &retry));
    try std.testing.expectEqual(@as(?i64, 1300), retry);
    response.status = 403;
    response.rate_remaining = "0";
    response.retry_after = "999999999";
    retry = null;
    try std.testing.expectError(error.RateLimited, responseStatus(&response, 1000, &retry));
    try std.testing.expectEqual(@as(?i64, 1000 + watch.max_retry_seconds), retry);
    response.rate_remaining = null;
    response.rate_reset = null;
    response.retry_after = "Tue, 14 Nov 2023 22:13:21 GMT";
    retry = null;
    try std.testing.expectError(error.RateLimited, responseStatus(&response, 1_700_000_000, &retry));
    try std.testing.expectEqual(@as(?i64, 1_700_000_001), retry);
    response.retry_after = "Tuesday, 14-Nov-23 22:13:21 GMT";
    retry = null;
    try std.testing.expectError(error.RateLimited, responseStatus(&response, 1_700_000_000, &retry));
    try std.testing.expectEqual(@as(?i64, 1_700_000_001), retry);
    response.retry_after = "not a date";
    retry = null;
    try std.testing.expectError(error.RateLimited, responseStatus(&response, 1_700_000_000, &retry));
    try std.testing.expectEqual(@as(?i64, null), retry);
    response.status = 401;
    try std.testing.expectError(error.AuthenticationFailed, responseStatus(&response, 1000, &retry));
    response.status = 404;
    try std.testing.expectError(error.AccessDenied, responseStatus(&response, 1000, &retry));
    response.status = 403;
    response.rate_remaining = null;
    response.retry_after = null;
    try std.testing.expectError(error.AccessDenied, responseStatus(&response, 1000, &retry));
}

const Fixture = struct {
    const Mode = enum { normal, stale, partial, pages, checks_limit, redirected, cancelled, rate_limited, unreachable_network };
    const Response = struct {
        status: u16 = 200,
        body: []const u8,
        link: ?[]const u8 = null,
        retry_after: ?[]const u8 = null,
        rate_remaining: ?[]const u8 = null,
        rate_reset: ?[]const u8 = null,
        fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };
    mode: Mode,
    full_page: []const u8,
    check_pages: []const []const u8 = &.{},
    pr_calls: usize = 0,
    review_calls: usize = 0,
    check_calls: usize = 0,
    fn get(self: *Fixture, comptime _: bool, _: std.mem.Allocator, _: std.Io, _: *const transport.Secret, endpoint: transport.Endpoint, _: transport.Deadline, _: transport.Cancel, _: []const u8, _: ?watch.Digest) anyerror!Response {
        const pr_a = "{\"head\":{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"state\":\"open\",\"draft\":false,\"merged_at\":null,\"requested_reviewers\":[],\"requested_teams\":[]}";
        const pr_b = "{\"head\":{\"sha\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"state\":\"open\",\"draft\":false,\"merged_at\":null,\"requested_reviewers\":[],\"requested_teams\":[]}";
        return switch (endpoint) {
            .identity => .{ .body = "{\"login\":\"Alice\"}" },
            .pr => blk: {
                self.pr_calls += 1;
                break :blk .{ .body = if (self.mode == .stale and self.pr_calls == 2) pr_b else pr_a };
            },
            .check_runs => |request| blk: {
                self.check_calls += 1;
                if (self.mode == .cancelled) return error.Cancelled;
                if (self.mode == .unreachable_network) return error.RequestFailed;
                if (self.mode == .rate_limited) break :blk .{ .status = 429, .body = "", .retry_after = "30" };
                if (self.mode == .checks_limit) break :blk .{ .body = self.check_pages[request.page - 1] };
                break :blk .{ .body = "{\"total_count\":0,\"check_runs\":[]}" };
            },
            .status => .{ .body = if (self.mode == .partial) "{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"total_count\":1,\"statuses\":[]}" else "{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"total_count\":0,\"statuses\":[]}" },
            .reviews => blk: {
                self.review_calls += 1;
                if (self.mode == .redirected) break :blk .{ .status = 302, .body = "" };
                if (self.mode == .pages) break :blk .{ .body = self.full_page };
                break :blk .{ .body = "[]" };
            },
        };
    }
};

test "PRW-16 fetch rejects stale heads and bounds incomplete collections" {
    const allocator = std.testing.allocator;
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(allocator);
    try full.appendSlice(allocator, "[");
    for (0..100) |i| {
        if (i > 0) try full.appendSlice(allocator, ",");
        try full.appendSlice(allocator, "{\"state\":\"PENDING\"}");
    }
    try full.appendSlice(allocator, "]");
    // Simulate the API reporting a full suite at its 1,000-run ceiling. Even
    // when total_count agrees, the final full page cannot prove completeness.
    var check_pages: [10][]const u8 = undefined;
    var initialized: usize = 0;
    defer for (check_pages[0..initialized]) |body| allocator.free(body);
    for (0..check_pages.len) |page| {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        try body.appendSlice(allocator, "{\"total_count\":1000,\"check_runs\":[");
        for (0..100) |index| {
            if (index > 0) try body.appendSlice(allocator, ",");
            const run = try std.fmt.allocPrint(allocator, "{{\"head_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"id\":{d},\"app\":{{\"id\":7}},\"check_suite\":{{\"id\":1}},\"name\":\"ci\",\"status\":\"completed\",\"conclusion\":\"success\"}}", .{page * 100 + index + 1});
            defer allocator.free(run);
            try body.appendSlice(allocator, run);
        }
        try body.appendSlice(allocator, "]}");
        check_pages[page] = try body.toOwnedSlice(allocator);
        initialized += 1;
    }
    const secret: transport.Secret = .{ .bytes = &.{} };
    const pr: watch.PrKey = .{ .owner = "org", .repo = "repo", .number = 1 };
    const deadline = std.Io.Timestamp.fromNanoseconds(0).withClock(.awake);
    var cancelled: std.atomic.Value(bool) = .init(false);
    inline for (.{ Fixture.Mode.normal, .partial, .pages, .checks_limit, .redirected }) |mode| {
        var fixture: Fixture = .{ .mode = mode, .full_page = full.items, .check_pages = &check_pages };
        var retry: ?i64 = null;
        var result = try fetchInternal(false, &fixture, allocator, std.testing.io, &secret, "alice", pr, 1, deadline, &cancelled, "", &retry);
        defer result.deinit(allocator);
        const reduced = try watch.reduce(null, result.observation);
        if (mode == .normal) {
            try std.testing.expectEqual(watch.Coverage.complete, reduced.coverage);
        } else {
            try std.testing.expectEqual(watch.Coverage.partial, reduced.coverage);
            if (mode == .partial or mode == .checks_limit) try std.testing.expectEqual(watch.Checks.incomplete, reduced.snapshot.checks) else try std.testing.expectEqual(watch.Reviews.incomplete, reduced.snapshot.reviews);
        }
        if (mode == .pages) try std.testing.expectEqual(@as(usize, 10), fixture.review_calls);
        if (mode == .checks_limit) try std.testing.expectEqual(@as(usize, 10), fixture.check_calls);
    }
    inline for (.{ Fixture.Mode.stale, .cancelled, .rate_limited, .unreachable_network }) |mode| {
        var fixture: Fixture = .{ .mode = mode, .full_page = full.items };
        var retry: ?i64 = null;
        const expected = switch (mode) {
            .stale => error.HeadChanged,
            .cancelled => error.Cancelled,
            .rate_limited => error.RateLimited,
            .unreachable_network => error.RequestFailed,
            else => unreachable,
        };
        try std.testing.expectError(expected, fetchInternal(false, &fixture, allocator, std.testing.io, &secret, "alice", pr, 1, deadline, &cancelled, "", &retry));
        if (mode == .rate_limited) try std.testing.expect(retry != null);
    }
}

test "PRW-22 response parsing wipes decoded temporary data" {
    const Observer = struct {
        child: std.mem.Allocator,
        frees: usize = 0,
        all_zero: bool = true,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.child.rawAlloc(len, alignment, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.frees += 1;
            for (bytes) |byte| if (byte != 0) {
                self.all_zero = false;
            };
            self.child.rawFree(bytes, alignment, ret);
        }
    };
    var observer: Observer = .{ .child = std.testing.allocator };
    var wiping: secrets.WipingAllocator = .{ .backing = observer.allocator() };
    const response = .{ .status = @as(u16, 200), .body = "{\"value\":\"s\\u0065cret\"}" };
    var parsed = try json(&wiping, &response);
    try std.testing.expectEqualStrings("secret", parsed.value.object.get("value").?.string);
    parsed.deinit();
    try std.testing.expect(observer.frees > 0);
    try std.testing.expect(observer.all_zero);
}
