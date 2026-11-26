//! Runs `watch_github_pr` Actions on the Host. A watch is an ordinary, ephemeral Action like `bash`
//! and `read_image`: it holds one execution credit while it runs, and a Host that stops before it
//! settles leaves the Action to be resolved indeterminate at recovery. Nothing about a watch is
//! published or kept between its start and its one final Resolution.
//!
//! A worker thread binds the GitHub account when the watch starts, then polls until the pull request
//! meaningfully changes or the deadline passes. It never touches the Store: the execution thread
//! observes `done`, then settles the Action with the worker's Resolution text, or with the stopped
//! text when a Stop superseded the Action first.
const std = @import("std");
const store = @import("store.zig");
const tool_result = @import("tool_result.zig");
const action_attempt = @import("action_attempt.zig");
const server_host = @import("server_host.zig");
const tool_record = @import("tool_record.zig");
const watch = @import("github_pr_watch.zig");
const descriptor = @import("github_pr_watch_descriptor.zig");
const transport = @import("github_transport.zig");
const fetch = @import("github_observation_fetch.zig");
const pressure = @import("github_watch_pressure.zig");
const signal_stack = @import("signal_stack.zig");
const Bounded = @import("bounded.zig").Bounded;
const Admission = @import("execution_turn.zig").Admission;
const Fixture = if (@import("builtin").is_test) @import("server_host_testing.zig").Fixture else void;

const test_hooks = @import("builtin").is_test or @import("build_options").test_pauses;

const labels: action_attempt.Labels = .{
    .admission = "pull request watch admission",
    .custody = "pull request watch custody",
    .stop = "pull request watch stop",
    .result = "pull request watch result",
    .failure = "pull request watch failure",
};

/// The timing a Host gives its watches. A loopback test origin scales every wait down.
pub const Limits = struct {
    /// The longest a watch runs; the Action's own execution deadline.
    deadline_ms: u64 = 3_600_000,
    pacing: watch.Pacing = .{},
    /// How often the Host-wide request budget refills one request.
    request_interval_ms: u64 = 1000,

    pub const loopback: Limits = .{ .pacing = .loopback, .request_interval_ms = 5 };
};

/// One poll's requests and a gh helper run must each finish within this bound or the poll fails.
const step_ms = 30_000;

const Worker = struct {
    io: std.Io,
    /// Private response bodies and the token live here, wiped on release, never in the Host's allocator.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    wake: *server_host.Lifecycle,
    environment: ?*const std.process.Environ.Map,
    gh: []const u8,
    url: Bounded(descriptor.max_url_bytes),
    account: ?Bounded(descriptor.max_login_bytes),
    /// Spreads the polls of watches that started together.
    seed: u64,
    pacing: watch.Pacing,
    deadline: std.Io.Clock.Timestamp,
    origin: if (test_hooks) ?[]const u8 else void,
    budget: fetch.Budget,
    cache: pressure.Cache = .{},
    cancel: std.atomic.Value(bool) = .init(false),
    /// Release-stored last, after `code`, `text` and `cancelled` are final.
    done: std.atomic.Value(bool) = .init(false),
    /// The worker stopped because it was cancelled, so `code` and `text` hold no Resolution.
    cancelled: bool = false,
    code: store.ActionResolutionCode = .failed,
    text: [watch.max_resolution_bytes]u8 = undefined,
    text_len: usize = 0,

    fn run(self: *Worker) void {
        self.execute();
        self.done.store(true, .release);
        self.wake.wakeDispatch();
    }

    fn execute(self: *Worker) void {
        self.work() catch |err| switch (err) {
            // A Stop, a fence or shutdown cancelled the worker; its caller decides what the Action becomes.
            error.Cancelled => self.cancelled = true,
        };
    }

    /// Asks the worker to stop at its next wait or request; it still sets `done`.
    fn requestCancel(self: *Worker) void {
        self.cancel.store(true, .release);
    }

    const State = union(enum) {
        running,
        /// Cancelled before it could write a Resolution; only a Stop or shutdown disposes of it.
        cancelled,
        finished: struct { code: store.ActionResolutionCode, text: []const u8 },
    };

    fn state(self: *const Worker) State {
        if (!self.done.load(.acquire)) return .running;
        if (self.cancelled) return .cancelled;
        return .{ .finished = .{ .code = self.code, .text = self.text[0..self.text_len] } };
    }

    /// Frees what the worker kept between polls; call only after it has ended.
    fn release(self: *Worker) void {
        self.cache.deinit(self.allocator);
    }

    fn work(self: *Worker) error{Cancelled}!void {
        const environment = self.environment orelse return self.end(.gh_unavailable, null, null);
        var login_buffer: [descriptor.max_login_bytes]u8 = undefined;
        const login = (try self.bindAccount(environment, &login_buffer)) orelse return;
        var secret = transport.token(self.allocator, self.io, environment, login, self.stepDeadline(), &self.cancel, self.gh) catch |err| {
            if (err == error.Cancelled) return error.Cancelled;
            // The account exists but its credential cannot be read: expired, removed, or a slow keyring.
            return self.end(if (err == error.GhUnavailable) .gh_unavailable else .account_unavailable, null, null);
        };
        defer secret.deinit(self.allocator);
        return self.poll(login, &secret);
    }

    /// The login this watch uses, fixed here and never changed: the explicit `account`, or the only
    /// authenticated account. Zero or several accounts end the watch with the choice the model must make.
    fn bindAccount(self: *Worker, environment: *const std.process.Environ.Map, buffer: *[descriptor.max_login_bytes]u8) error{Cancelled}!?[]const u8 {
        if (self.account) |*explicit| return explicit.slice();
        var accounts = transport.discover(self.allocator, self.io, environment, self.stepDeadline(), &self.cancel, self.gh) catch |err| {
            if (err == error.Cancelled) return error.Cancelled;
            self.end(if (err == error.GhUnavailable) .gh_unavailable else .account_discovery_failed, null, null);
            return null;
        };
        defer accounts.deinit(self.allocator);
        if (accounts.names.len == 1) {
            const name = accounts.names[0];
            @memcpy(buffer[0..name.len], name);
            return buffer[0..name.len];
        }
        var names: [transport.max_accounts][]const u8 = undefined;
        for (accounts.names, 0..) |name, i| names[i] = name;
        // A hundred bounded logins always fit the Resolution buffer.
        const text = watch.encodeAccountChoice(&self.text, names[0..accounts.names.len]) catch unreachable;
        // Naming the accounts is the answer the model asked for, not a failure.
        self.finish(.succeeded, text.len);
        return null;
    }

    /// Fetches, sleeps and applies `watch.Watch`'s decisions; what each poll means is decided there.
    fn poll(self: *Worker, login: []const u8, secret: *const transport.Secret) error{Cancelled}!void {
        const pr = watch.parseUrl(self.url.slice()) catch return self.end(.pr_inaccessible, null, null);
        var state_machine: watch.Watch = .{ .pacing = self.pacing, .seed = self.seed };
        while (true) {
            if (self.cancel.load(.acquire)) return error.Cancelled;
            switch (state_machine.step(try self.observe(secret, login, pr))) {
                .wait_ms => |milliseconds| try self.wait(milliseconds),
                .end => |ending| return self.end(ending.outcome, ending.latest, ending.retry_at),
            }
        }
    }

    /// One poll as the event the decision table reads.
    fn observe(self: *Worker, secret: *const transport.Secret, login: []const u8, pr: watch.PrKey) error{Cancelled}!watch.Watch.Event {
        if (self.expired()) return .expired;
        var hint: ?i64 = null;
        var observed = self.fetchOnce(secret, login, pr, &hint) catch |err| return .{ .failed = .{
            .fault = switch (err) {
                error.Cancelled => return error.Cancelled,
                error.AuthenticationFailed, error.IdentityMismatch => .revoked,
                error.AccessDenied => .inaccessible,
                error.RequestBudgetExhausted => .budget_exhausted,
                error.RateLimited => .rate_limited,
                else => .transient,
            },
            .retry_at = hint,
            .seen_at = @intCast(std.Io.Clock.real.now(self.io).toSeconds()),
            .remaining_ms = self.remainingMs(),
        } };
        defer observed.deinit(self.allocator);
        const reduced = watch.reduce(null, observed.observation) catch return .{ .failed = .{
            .fault = .transient,
            .seen_at = @intCast(std.Io.Clock.real.now(self.io).toSeconds()),
            .remaining_ms = self.remainingMs(),
        } };
        return .{ .observed = .{ .snapshot = reduced.snapshot, .coverage = reduced.coverage } };
    }

    fn fetchOnce(self: *Worker, secret: *const transport.Secret, login: []const u8, pr: watch.PrKey, retry_at: *?i64) !fetch.Result {
        const now: i64 = @intCast(std.Io.Clock.real.now(self.io).toSeconds());
        const deadline = self.stepDeadline();
        if (comptime test_hooks) if (self.origin) |origin| {
            return fetch.fetchForTest(self.allocator, self.io, secret, login, pr, now, deadline, &self.cancel, origin, &self.cache, &self.budget, retry_at);
        };
        return fetch.fetch(self.allocator, self.io, secret, login, pr, now, deadline, &self.cancel, &self.cache, &self.budget, retry_at);
    }

    /// The nearer of this watch's deadline and one bounded step from now.
    fn stepDeadline(self: *const Worker) std.Io.Clock.Timestamp {
        const step = std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = .fromMilliseconds(step_ms), .clock = .awake });
        return if (self.deadline.raw.nanoseconds < step.raw.nanoseconds) self.deadline else step;
    }

    fn remainingMs(self: *const Worker) u64 {
        const left = self.deadline.durationFromNow(self.io).raw.toMilliseconds();
        return if (left < 0) 0 else @intCast(left);
    }

    fn expired(self: *const Worker) bool {
        return self.remainingMs() == 0;
    }

    /// Sleeps in short steps so a Stop, shutdown or the deadline is noticed promptly; returns early at the deadline.
    fn wait(self: *Worker, milliseconds: u64) error{Cancelled}!void {
        var left = milliseconds;
        while (left > 0) {
            if (self.cancel.load(.acquire)) return error.Cancelled;
            if (self.expired()) return;
            const step = @min(left, 100);
            std.Io.sleep(self.io, .fromMilliseconds(@intCast(step)), .awake) catch return error.Cancelled;
            left -= step;
        }
    }

    /// Settles this watch with `outcome`; `latest` and `retry_at` appear only where the outcome carries them.
    fn end(self: *Worker, outcome: watch.Outcome, latest: ?watch.Latest, retry_at: ?i64) void {
        const text = watch.encodeOutcome(&self.text, outcome, latest, retry_at) catch unreachable;
        self.finish(if (outcome.succeeds()) .succeeded else .failed, text.len);
    }

    fn finish(self: *Worker, code: store.ActionResolutionCode, length: usize) void {
        self.code = code;
        self.text_len = length;
    }
};

/// What every watch of a Host shares, handed to each as it starts.
const Setup = struct {
    environment: ?*const std.process.Environ.Map,
    gh: []const u8,
    limits: Limits,
    origin: if (test_hooks) ?[]const u8 else void,
    budget: *pressure.Budget,
};

const Arguments = struct {
    url: Bounded(descriptor.max_url_bytes),
    account: ?Bounded(descriptor.max_login_bytes),
};

/// One admitted watch: its attempt, its worker thread and the Stop it may have been given. Only the
/// execution thread touches it, and the worker never reaches the Store.
const Active = struct {
    attempt: action_attempt.Attempt = undefined,
    /// Taken from the admitted Parts, so later settlement never reaches through Host.
    store: *store.Store = undefined,
    input: store.ActionExecutionInput = undefined,
    worker: Worker = undefined,
    thread: ?std.Thread = null,
    /// A Stop superseded the Action; it settles cancelled once the worker has ended.
    stopping: bool = false,

    const Opening = union(enum) { active: *Active, refused, none };

    /// Admits the call through the shared attempt owner; the returned watch is not yet running.
    fn open(parts: action_attempt.Parts, results: tool_result.Results, call: store.ReadyAction, deadline_ms: u64) Opening {
        const active = results.allocator.create(Active) catch return .refused;
        active.* = .{ .store = parts.store };
        active.attempt = switch (action_attempt.admit(parts, call, deadline_ms, labels)) {
            .attempt => |attempt| attempt,
            .busy, .refused => {
                results.allocator.destroy(active);
                return .refused;
            },
            .none, .unattached => {
                results.allocator.destroy(active);
                return .none;
            },
        };
        return .{ .active = active };
    }

    fn action(self: *const Active) u64 {
        return self.attempt.binding.action_id;
    }

    /// Reads the call's arguments and starts the worker; a failure leaves the Action for `failStart`.
    fn begin(self: *Active, parts: action_attempt.Parts, results: tool_result.Results, setup: Setup) !void {
        try self.store.readActionExecutionInput(.github_pr_watch, self.attempt.binding, &self.input);
        const arguments = try self.readArguments();
        const now = std.Io.Clock.Timestamp.now(results.io, .awake);
        const limit_ms = @min(self.input.timeout_ms, setup.limits.deadline_ms);
        self.worker = .{
            .io = results.io,
            .wake = parts.lifecycle,
            .environment = setup.environment,
            .gh = setup.gh,
            .url = arguments.url,
            .account = arguments.account,
            .seed = self.action(),
            .pacing = setup.limits.pacing,
            .deadline = now.addDuration(.{ .raw = .fromMilliseconds(@intCast(limit_ms)), .clock = .awake }),
            .origin = setup.origin,
            .budget = .{ .context = setup.budget, .acquire = pressure.Budget.acquireOpaque },
        };
        switch (self.attempt.launch(.effect, now, self, spawn)) {
            .started => {},
            .authority, .handoff => |err| return err,
        }
    }

    fn spawn(self: *Active) !void {
        self.thread = try signal_stack.spawn(.{}, Worker.run, .{&self.worker});
    }

    /// The call's arguments were validated when its Message settled; parsing again here only fails on a corrupt Store.
    fn readArguments(self: *Active) !Arguments {
        var bytes: [2048]u8 = undefined;
        const length = std.math.cast(usize, self.input.arguments.length) orelse return error.InvalidArguments;
        if (length > bytes.len) return error.InvalidArguments;
        var reader: store.ContentReader = undefined;
        reader.open(try self.store.openContent(self.input.arguments));
        defer reader.close();
        var offset: usize = 0;
        while (offset < length) {
            const count = try reader.read(offset, bytes[offset..length]);
            if (count == 0) return error.ShortCanonicalRead;
            offset += count;
        }
        var memory: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&memory);
        const parsed = try descriptor.parse(fixed.allocator(), bytes[0..length]);
        return .{ .url = parsed.url, .account = parsed.account };
    }

    fn settleText(self: *Active, code: store.ActionResolutionCode, text: []const u8) void {
        _ = self.attempt.settle(.{ .text = .{ .code = code, .text = text } });
    }

    /// Settles an Action whose worker never started.
    fn failStart(self: *Active, err: anyerror) void {
        if (self.store.isFenced()) {
            _ = self.attempt.settle(.{ .fence = .{ .phase = "pull request watch start", .fault = .{ .store = err } } });
        } else if (err == error.HostDispatchSuppressed) {
            return;
        } else if (err == error.SupersededByControl) {
            self.settleText(.cancelled, tool_record.Runner.github_pr_watch.stoppedText(false, ""));
        } else {
            var buffer: [128]u8 = undefined;
            self.settleText(.failed, std.fmt.bufPrint(&buffer, "Pull request watch failed to start: {s}.", .{@errorName(err)}) catch unreachable);
        }
    }

    const Step = enum { running, settled, fenced };

    /// Notices a Stop, and settles the Action once its worker has ended: with the worker's Resolution,
    /// or cancelled when a Stop superseded the Action first. A fenced Store settles nothing.
    fn advance(self: *Active) Step {
        if (!self.stopping) switch (self.attempt.stopped()) {
            .fenced => {
                self.worker.requestCancel();
                return .fenced;
            },
            .stopped => {
                self.stopping = true;
                self.worker.requestCancel();
            },
            .running => {},
        };
        const ended = self.worker.state();
        if (ended == .running) return .running;
        if (self.stopping) {
            self.settleText(.cancelled, tool_record.Runner.github_pr_watch.stoppedText(false, ""));
            return .settled;
        }
        switch (ended) {
            .running => unreachable,
            // A worker cancelled by a fence wrote no Resolution, and no Stop owns the Action: it stays
            // for shutdown, which disposes of it, and recovery resolves the Action.
            .cancelled => return .running,
            .finished => |finished| {
                self.settleText(finished.code, finished.text);
                return .settled;
            },
        }
    }

    fn cancel(self: *Active) void {
        self.worker.requestCancel();
    }

    fn destroy(self: *Active, results: tool_result.Results) void {
        if (self.thread) |thread| {
            self.cancel();
            thread.join();
            self.worker.release();
        }
        const closing = self.attempt.close();
        results.allocator.destroy(self);
        closing.finish();
    }
};

pub const Calls = struct {
    /// One slot per custody record, allocated at the first admission: a watch holds its credit for up to an
    /// hour, so a smaller table would leave a selected watch waiting ahead of every later Action.
    entries: []?*Active = &.{},
    limits: Limits = .{},
    /// The Host's process environment: the `gh` profile and keyring context, never read for tokens.
    environment: ?*const std.process.Environ.Map = null,
    /// The executable that lists accounts and prints their tokens; tests name a fake by path.
    gh: []const u8 = "gh",
    /// A loopback fixture that stands in for api.github.com; only a test build can set it.
    origin: if (test_hooks) ?[]const u8 else void = if (test_hooks) null else {},
    budget: ?pressure.Budget = null,

    /// Points every watch at a loopback fixture, with the fixture's short waits. Only a test build has the hook.
    pub fn useFixtureOrigin(self: *Calls, fixture: ?[]const u8) void {
        if (comptime test_hooks) if (fixture) |origin| {
            self.origin = origin;
            self.limits = .loopback;
        };
    }

    pub fn any(self: *const Calls) bool {
        for (self.entries) |entry| if (entry != null) return true;
        return false;
    }

    pub fn contains(self: *const Calls, action: u64) bool {
        for (self.entries) |entry| if (entry) |active| {
            if (active.action() == action) return true;
        };
        return false;
    }

    pub noinline fn admit(self: *Calls, parts: action_attempt.Parts, results: tool_result.Results, call: store.ReadyAction) Admission {
        if (self.entries.len == 0) {
            self.entries = results.allocator.alloc(?*Active, parts.custody.records.len) catch return .retry_later;
            @memset(self.entries, null);
        }
        const entry = for (self.entries) |*entry| {
            if (entry.* == null) break entry;
        } else return .retry_later;
        const active = switch (Active.open(parts, results, call, self.limits.deadline_ms)) {
            .active => |active| active,
            .refused => return .retry_later,
            .none => return .admitted,
        };
        if (self.budget == null) self.budget = pressure.Budget.initEvery(results.io, @intCast(self.limits.request_interval_ms * std.time.ns_per_ms));
        active.begin(parts, results, .{
            .environment = self.environment,
            .gh = self.gh,
            .limits = self.limits,
            .origin = if (test_hooks) self.origin else {},
            .budget = &self.budget.?,
        }) catch |err| {
            active.failStart(err);
            active.destroy(results);
            return .admitted;
        };
        entry.* = active;
        return .admitted;
    }

    pub fn service(self: *Calls, results: tool_result.Results) bool {
        var progress = false;
        for (self.entries) |*entry| if (entry.*) |active| switch (active.advance()) {
            .running => {},
            .fenced => return progress,
            .settled => {
                active.destroy(results);
                entry.* = null;
                progress = true;
            },
        };
        return progress;
    }

    /// Cancels every worker before waiting for any, so shutdown takes one step, not one per watch.
    pub fn shutdown(self: *Calls, results: tool_result.Results) void {
        for (self.entries) |entry| if (entry) |active| active.cancel();
        for (self.entries) |*entry| if (entry.*) |active| {
            active.destroy(results);
            entry.* = null;
        };
        results.allocator.free(self.entries);
        self.entries = &.{};
    }
};

const TestParts = if (@import("builtin").is_test) @import("server_host_testing.zig").TestParts else void;
const h2 = @import("h2");
/// The fake `gh` is a POSIX shell script, so tests that run one need a Host platform.
const os = @import("os");

/// A loopback stand-in for api.github.com. Its pull request shows `first` until `switch_after`
/// pull request reads have been served, then `later`; each poll reads the pull request twice.
const Github = struct {
    arena: std.heap.ArenaAllocator,
    pull_reads: u32 = 0,
    switch_after: u32 = std.math.maxInt(u32),
    pull_status: u16 = 200,
    first: View = .{},
    later: View = .{},

    const View = struct { head: u8 = 1, state: []const u8 = "open", merged: bool = false, passing: bool = false, draft: bool = false, requested: bool = false };

    fn view(self: *const Github) View {
        return if (self.pull_reads > self.switch_after) self.later else self.first;
    }

    fn handle(peer: *h2.testing.Peer, stream: *h2.testing.Peer.Stream) void {
        const self: *Github = @ptrCast(@alignCast(peer.options.context.?));
        const path = stream.path.items;
        const authorization = stream.authorization.items;
        const login = if (std.mem.startsWith(u8, authorization, "Bearer token-")) authorization["Bearer token-".len..] else "";
        const allocator = self.arena.allocator();
        if (std.mem.eql(u8, path, "/user")) {
            peer.respond(stream, 200, std.fmt.allocPrint(allocator, "{{\"login\":\"{s}\"}}", .{login}) catch unreachable);
        } else if (std.mem.eql(u8, path, "/repos/org/repo/pulls/42")) {
            self.pull_reads += 1;
            if (self.pull_status != 200) return peer.respond(stream, self.pull_status, "{}");
            const current = self.view();
            peer.respond(stream, 200, std.fmt.allocPrint(allocator, "{{\"state\":\"{s}\",\"draft\":{s},\"merged_at\":{s},\"head\":{{\"sha\":\"{s}\"}},\"requested_reviewers\":[{s}],\"requested_teams\":[]}}", .{
                current.state,
                if (current.draft) "true" else "false",
                if (current.merged) "\"2026-01-01T00:00:00Z\"" else "null",
                sha(allocator, current.head),
                if (current.requested) "{\"login\":\"carol\"}" else "",
            }) catch unreachable);
        } else if (std.mem.startsWith(u8, path, "/repos/org/repo/pulls/42/reviews")) {
            peer.respond(stream, 200, "[]");
        } else if (std.mem.startsWith(u8, path, "/repos/org/repo/commits/")) {
            const head = path["/repos/org/repo/commits/".len..][0..40];
            if (std.mem.indexOf(u8, path, "/check-runs") != null) {
                const runs = if (self.view().passing) std.fmt.allocPrint(allocator, "{{\"id\":1,\"app\":{{\"id\":1}},\"name\":\"ci\",\"status\":\"completed\",\"conclusion\":\"success\",\"head_sha\":\"{s}\"}}", .{head}) catch unreachable else "";
                peer.respond(stream, 200, std.fmt.allocPrint(allocator, "{{\"total_count\":{d},\"check_runs\":[{s}]}}", .{ @intFromBool(runs.len != 0), runs }) catch unreachable);
            } else {
                peer.respond(stream, 200, std.fmt.allocPrint(allocator, "{{\"sha\":\"{s}\",\"state\":\"pending\",\"total_count\":0,\"statuses\":[]}}", .{head}) catch unreachable);
            }
        } else peer.respond(stream, 404, "{}");
    }

    fn sha(allocator: std.mem.Allocator, digit: u8) []const u8 {
        const text = allocator.alloc(u8, 40) catch unreachable;
        @memset(text, '0' + digit);
        return text;
    }
};

const Case = struct {
    arguments: []const u8 = "{\"url\":\"https://github.com/org/repo/pull/42\",\"account\":\"alice\"}",
    accounts: []const []const u8 = &.{"alice"},
    limits: Limits = .loopback,
    /// Each account is `login` or `login:state`; the state defaults to `success`.
    gh: enum { installed, missing } = .installed,
    /// How `gh auth status` fails, when it does.
    discovery: enum { listed, exits, garbage } = .listed,
    /// `gh` blocks until it is killed, as a keyring prompt that never answers.
    gh_blocks: bool = false,
    ending: enum { natural, stop, stop_while_binding, shutdown } = .natural,
    github: *Github,
};

const Finished = struct {
    /// Null while the Action is unresolved, as after a Host shutdown.
    code: ?[]const u8,
    text: []const u8,
    gh_calls: []const u8,
    authorizations: []const []const u8,
    requests: usize,
    action: u64,
};

/// Runs one watch through a real Store, custody pool and worker thread against `case.github`, pumping
/// the loopback peer from the test thread. `arena` owns everything in the result.
fn runWatch(arena: std.mem.Allocator, case: Case) !Finished {
    const testing = store.testing;
    const protocol = @import("protocol.zig");
    const retention = @import("output_retention.zig");
    const execution_owner = @import("execution_owner.zig");
    const execution = @import("execution.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var storage: store.Store = undefined;
    try testing.testingSqliteStore(&storage, &tmp, io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    var configure = try testing.completeConfiguration("watch-config", "", root, "model-a");
    configure.configuration.tools = try .of(&.{"watch_github_pr"});
    configure.configuration.permission_mode.state = .value;
    try configure.configuration.permission_mode.value.set("bypass");
    const session = (try storage.configure(&configure, .{})).accepted.session;
    try testing.submitTestMessage(&storage, &tmp, "watch-input", "watch-message", session.slice(), "Watch a pull request.");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var encoded_arguments: std.ArrayList(u8) = .empty;
    for (case.arguments) |byte| {
        if (byte == '"') try encoded_arguments.append(arena, '\\');
        try encoded_arguments.append(arena, byte);
    }
    try store.settleCallsForTesting(&storage, &tmp, model, "watch-call", &.{.{
        .item_id = "watch-item",
        .name = "watch_github_pr",
        .encoded_call_id = "watch-call",
        .decoded_call_id = "watch-call",
        .encoded_arguments = encoded_arguments.items,
        .decoded_arguments = case.arguments,
    }});
    const selected = (try storage.nextAction(.github_pr_watch, .{ .free_credit = .one, .mcp_open = false })).?;

    // A fake gh lists the accounts in `accounts`, hands out `token-<login>` to those and logs every call.
    try tmp.dir.createDir(io, "bin", .default_dir);
    try tmp.dir.createDir(io, "empty", .default_dir);
    var accounts_file: std.ArrayList(u8) = .empty;
    for (case.accounts) |name| try accounts_file.print(arena, "{s}\n", .{name});
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/accounts", .data = accounts_file.items });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/gh", .flags = .{ .permissions = .fromMode(0o700) }, .data =
        \\#!/bin/sh
        \\dir=$(dirname "$0")
        \\echo "$*" >> "$dir/calls.log"
        \\[ -e "$dir/blocks" ] && exec sleep 30
        \\if [ "$1 $2" = "auth status" ]; then
        \\  [ -e "$dir/status-exits" ] && exit 1
        \\  [ -e "$dir/status-garbage" ] && { echo 'not json'; exit 0; }
        \\  printf '{"hosts":{"github.com":['
        \\  separator=''
        \\  while IFS=: read -r name state; do printf '%s{"login":"%s","state":"%s"}' "$separator" "$name" "${state:-success}"; separator=','; done < "$dir/accounts"
        \\  printf ']}}\n'
        \\elif [ "$1 $2" = "auth token" ]; then
        \\  cut -d: -f1 "$dir/accounts" | grep -qx "$6" || exit 1
        \\  printf 'token-%s\n' "$6"
        \\else
        \\  exit 2
        \\fi
    });
    switch (case.discovery) {
        .listed => {},
        .exits => try tmp.dir.writeFile(io, .{ .sub_path = "bin/status-exits", .data = "" }),
        .garbage => try tmp.dir.writeFile(io, .{ .sub_path = "bin/status-garbage", .data = "" }),
    }
    if (case.gh_blocks) try tmp.dir.writeFile(io, .{ .sub_path = "bin/blocks", .data = "" });
    // A missing gh is a path nothing can execute; the Host's own PATH never stands in for the fake.
    const gh_path = try std.fmt.allocPrint(arena, "{s}/{s}/gh", .{ root, if (case.gh == .installed) "bin" else "empty" });
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    try environment.put("HOME", root);

    var peer = try h2.testing.Peer.start(std.testing.allocator, .{ .context = case.github, .on_request = Github.handle });
    defer peer.stop();
    const origin = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{peer.port});

    var used: std.atomic.Value(u64) = .init(0);
    var retained: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(io, root, .{ .used = &used, .limit = 1024 * 1024 }, &retained);
    defer queue.cleanupAll();
    var records: [1]execution.CustodyRecord = @splat(.{});
    var host: Fixture = .{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage, .retention = &queue };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    const results: tool_result.Results = .{ .io = io, .allocator = host.allocator, .retention = &queue };
    var execution_state: execution_owner.Execution = undefined;
    execution_state.init(&records, null, &host_parts.lifecycle, &host.scratch_used, null);
    const parts: action_attempt.Parts = execution_state.attempts(&storage, host.probes);
    var calls: Calls = .{ .environment = &environment, .gh = gh_path, .origin = origin, .limits = case.limits };
    defer calls.shutdown(results);
    try std.testing.expectEqual(Admission.admitted, calls.admit(parts, results, selected));
    try std.testing.expect(calls.any() and calls.contains(selected.action_id));
    try std.testing.expectEqual(@as(usize, 1), parts.custody.occupied());

    // The one credit is held, so another admission of any Action waits for it rather than starting beside it.
    try std.testing.expectEqual(Admission.retry_later, calls.admit(parts, results, selected));
    try std.testing.expectEqual(@as(usize, 1), parts.custody.occupied());

    var acted = false;
    var spins: usize = 0;
    while (calls.any()) : (spins += 1) {
        // Twenty seconds bounds a hung watch; every case here finishes in well under two.
        if (spins > 4000) return error.WatchDidNotFinish;
        try peer.pump();
        if (!acted) {
            const ready = switch (case.ending) {
                .natural => false,
                .stop, .shutdown => case.github.pull_reads >= 2,
                // The blocked gh has logged its call and is waiting; no request has reached GitHub.
                .stop_while_binding => if (tmp.dir.access(io, "bin/calls.log", .{})) true else |_| false,
            };
            if (ready) switch (case.ending) {
                .natural => unreachable,
                .stop, .stop_while_binding => {
                    acted = true;
                    var stop = try store.testingCompleteSessionStop("watch-stop", session.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                },
                .shutdown => {
                    _ = parts.lifecycle.advance(.stopping);
                    calls.shutdown(results);
                    break;
                },
            };
        }
        _ = calls.service(results);
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(!calls.any());
    try std.testing.expectEqual(@as(usize, 0), parts.custody.occupied());

    var authorizations: std.ArrayList([]const u8) = .empty;
    for (peer.streams.items) |stream| try authorizations.append(arena, try arena.dupe(u8, stream.authorization.items));
    const gh_calls: []const u8 = tmp.dir.readFileAlloc(io, "bin/calls.log", arena, .limited(4096)) catch "";
    var finished: Finished = .{ .code = null, .text = "", .gh_calls = gh_calls, .authorizations = authorizations.items, .requests = peer.streams.items.len, .action = selected.action_id };
    inline for (.{ "succeeded", "failed", "cancelled" }) |code| {
        if (try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ selected.action_id, code }) == 1) finished.code = code;
    }
    if (finished.code) |_| {
        const id = try testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{selected.action_id});
        const reference = try store.testingContentReference(&storage, id);
        const bytes = try arena.alloc(u8, @intCast(reference.length));
        var reader: store.ContentReader = undefined;
        reader.open(try storage.openContent(reference));
        defer reader.close();
        try std.testing.expectEqual(bytes.len, try reader.readRange(0, bytes));
        finished.text = bytes;
    } else {
        // A Host that stopped mid-watch leaves the Action to recovery, which resolves it indeterminate.
        try std.testing.expect(!parts.lifecycle.launchAllowed());
        try storage.close();
        storage_open = false;
        try testing.testingSqliteStore(&storage, &tmp, io);
        storage_open = true;
        try std.testing.expect(try storage.recoverOneUncertainAction(.empty()));
        try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='indeterminate' AND attempt_ordinal=1", .{selected.action_id}));
    }
    // A resolved or recovered watch is never selected again.
    try std.testing.expect(try storage.nextAction(.github_pr_watch, .{ .free_credit = .one, .mcp_open = true }) == null);
    return finished;
}

fn expectJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

fn expectOutcome(finished: Finished, code: []const u8, outcome: []const u8) !std.json.Parsed(std.json.Value) {
    try std.testing.expectEqualStrings(code, finished.code.?);
    const parsed = try expectJson(std.testing.allocator, finished.text);
    errdefer parsed.deinit();
    try std.testing.expectEqualStrings(outcome, parsed.value.object.get("outcome").?.string);
    return parsed;
}

fn expectChanged(snapshot: std.json.Value, names: []const []const u8) !void {
    const changed = snapshot.object.get("changed").?.array.items;
    try std.testing.expectEqual(names.len, changed.len);
    for (names, changed) |name, item| try std.testing.expectEqualStrings(name, item.string);
}

fn newGithub() Github {
    return .{ .arena = .init(std.testing.allocator) };
}

test "PRW-64 a watch baselines then ends with the typed snapshot of the change" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The head moves after two full polls: the third poll sees the new head and settles the baseline's watch.
    var github = newGithub();
    defer github.arena.deinit();
    github.switch_after = 4;
    github.later = .{ .head = 2 };
    const finished = try runWatch(arena, .{ .github = &github });
    const parsed = try expectOutcome(finished, "succeeded", "changed");
    defer parsed.deinit();
    const snapshot = parsed.value.object.get("snapshot").?.object;
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222", snapshot.get("head_sha").?.string);
    try std.testing.expectEqualStrings("open", snapshot.get("lifecycle").?.string);
    try std.testing.expectEqualStrings("complete", parsed.value.object.get("coverage").?.string);
    try expectChanged(parsed.value, &.{"head"});
    try std.testing.expect(github.pull_reads >= 6);
    // The one account the model named is the only credential asked for, and every request carries it.
    try std.testing.expectEqualStrings("auth token --hostname github.com --user alice --no-refresh\n", finished.gh_calls);
    for (finished.authorizations) |authorization| try std.testing.expectEqualStrings("Bearer token-alice", authorization);
    // Titles, bodies and tokens never reach the Resolution.
    try std.testing.expect(std.mem.indexOf(u8, finished.text, "token") == null);
}

test "PRW-65 only checks settling, not pending, ends a watch and a merge ends it at once" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var settled = newGithub();
    defer settled.arena.deinit();
    settled.switch_after = 4;
    settled.later = .{ .passing = true };
    const checks = try runWatch(arena, .{ .github = &settled });
    const checks_parsed = try expectOutcome(checks, "succeeded", "changed");
    defer checks_parsed.deinit();
    try expectChanged(checks_parsed.value, &.{"checks"});
    try std.testing.expectEqualStrings("passing", checks_parsed.value.object.get("snapshot").?.object.get("checks").?.string);

    // An already merged pull request ends its watch at the baseline, found through the only authenticated account.
    var merged = newGithub();
    defer merged.arena.deinit();
    merged.first = .{ .state = "closed", .merged = true };
    const done = try runWatch(arena, .{ .github = &merged, .arguments = "{\"url\":\"https://github.com/org/repo/pull/42\"}" });
    const merged_parsed = try expectOutcome(done, "succeeded", "merged");
    defer merged_parsed.deinit();
    try std.testing.expectEqualStrings("merged", merged_parsed.value.object.get("snapshot").?.object.get("lifecycle").?.string);
    try std.testing.expectEqualStrings("auth status --hostname github.com --json hosts --no-refresh\nauth token --hostname github.com --user alice --no-refresh\n", done.gh_calls);
    for (done.authorizations) |authorization| try std.testing.expectEqualStrings("Bearer token-alice", authorization);
}

test "PRW-66 a watch with no change ends at its deadline with the latest snapshot, or none if it never saw one" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var github = newGithub();
    defer github.arena.deinit();
    var limits: Limits = .loopback;
    limits.deadline_ms = 2000;
    const finished = try runWatch(arena, .{ .github = &github, .limits = limits });
    const parsed = try expectOutcome(finished, "succeeded", "no_change");
    defer parsed.deinit();
    try expectChanged(parsed.value, &.{});
    try std.testing.expectEqualStrings("pending", parsed.value.object.get("snapshot").?.object.get("checks").?.string);
    // It polled again after the baseline instead of ending there (each poll reads the pull request twice). The
    // deadline leaves the watch's startup and one poll gap a wide margin, so a slow host cannot spend it all first.
    try std.testing.expect(github.pull_reads >= 4);
}

test "PRW-67 the account is bound when the watch starts and never replaced" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const without_account = "{\"url\":\"https://github.com/org/repo/pull/42\"}";
    var github = newGithub();
    defer github.arena.deinit();

    const several = try runWatch(arena, .{ .github = &github, .arguments = without_account, .accounts = &.{ "bob", "alice" } });
    const several_parsed = try expectOutcome(several, "succeeded", "account_required");
    defer several_parsed.deinit();
    const names = several_parsed.value.object.get("usernames").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("alice", names[0].string);
    try std.testing.expectEqualStrings("bob", names[1].string);
    try std.testing.expectEqual(@as(usize, 0), several.requests);
    try std.testing.expectEqualStrings("auth status --hostname github.com --json hosts --no-refresh\n", several.gh_calls);

    const none = try runWatch(arena, .{ .github = &github, .arguments = without_account, .accounts = &.{} });
    const none_parsed = try expectOutcome(none, "succeeded", "auth_required");
    defer none_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.requests);

    // An explicit account whose credentials are missing is a refusal; no other account stands in.
    const unavailable = try runWatch(arena, .{ .github = &github, .arguments = "{\"url\":\"https://github.com/org/repo/pull/42\",\"account\":\"carol\"}", .accounts = &.{ "alice", "bob" } });
    const unavailable_parsed = try expectOutcome(unavailable, "failed", "account_unavailable");
    defer unavailable_parsed.deinit();
    try std.testing.expectEqualStrings("auth token --hostname github.com --user carol --no-refresh\n", unavailable.gh_calls);
    try std.testing.expectEqual(@as(usize, 0), unavailable.requests);

    const missing = try runWatch(arena, .{ .github = &github, .gh = .missing });
    const missing_parsed = try expectOutcome(missing, "failed", "gh_unavailable");
    defer missing_parsed.deinit();
    const missing_discovery = try runWatch(arena, .{ .github = &github, .arguments = without_account, .gh = .missing });
    const missing_discovery_parsed = try expectOutcome(missing_discovery, "failed", "gh_unavailable");
    defer missing_discovery_parsed.deinit();
}

test "PRW-68 an inaccessible pull request under the bound account is never tried with another" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var github = newGithub();
    defer github.arena.deinit();
    github.pull_status = 404;
    const finished = try runWatch(arena, .{ .github = &github, .accounts = &.{ "alice", "bob" } });
    const parsed = try expectOutcome(finished, "failed", "pr_inaccessible");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("{\"outcome\":\"pr_inaccessible\"}", finished.text);
    try std.testing.expectEqualStrings("auth token --hostname github.com --user alice --no-refresh\n", finished.gh_calls);
    for (finished.authorizations) |authorization| try std.testing.expectEqualStrings("Bearer token-alice", authorization);

    // The same holds when the account was discovered rather than named.
    var sole = newGithub();
    defer sole.arena.deinit();
    sole.pull_status = 404;
    const discovered = try runWatch(arena, .{ .github = &sole, .arguments = "{\"url\":\"https://github.com/org/repo/pull/42\"}" });
    const discovered_parsed = try expectOutcome(discovered, "failed", "pr_inaccessible");
    defer discovered_parsed.deinit();
}

test "PRW-69 repeated rate limits end the watch as rate_limited" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var github = newGithub();
    defer github.arena.deinit();
    github.pull_status = 429;
    const finished = try runWatch(arena, .{ .github = &github });
    const parsed = try expectOutcome(finished, "failed", "rate_limited");
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("snapshot").? == .null);
    try std.testing.expect(parsed.value.object.get("retry_at").? == .null);
    try std.testing.expectEqual(@as(u32, 5), github.pull_reads);
}

test "PRW-70 a Stop cancels the watch and settles it cancelled" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var github = newGithub();
    defer github.arena.deinit();
    const finished = try runWatch(arena, .{ .github = &github, .ending = .stop });
    try std.testing.expectEqualStrings("cancelled", finished.code.?);
    try std.testing.expectEqualStrings("Stopped before this pull request watch completed.", finished.text);
}

test "PRW-71 a Host that stops mid-watch releases custody and leaves the Action to recovery" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var github = newGithub();
    defer github.arena.deinit();
    const finished = try runWatch(arena, .{ .github = &github, .ending = .shutdown });
    // runWatch checked that recovery resolved the Action indeterminate exactly once.
    try std.testing.expect(finished.code == null);
}

test "PRW-78 a closed pull request, a draft made ready and a reviews change each end a watch" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Closed without merging is its own outcome, found at the baseline.
    var closed = newGithub();
    defer closed.arena.deinit();
    closed.first = .{ .state = "closed" };
    const closed_run = try runWatch(arena, .{ .github = &closed });
    const closed_parsed = try expectOutcome(closed_run, "succeeded", "closed");
    defer closed_parsed.deinit();
    try std.testing.expectEqualStrings("closed", closed_parsed.value.object.get("snapshot").?.object.get("lifecycle").?.string);

    var ready = newGithub();
    defer ready.arena.deinit();
    ready.first = .{ .draft = true };
    ready.switch_after = 4;
    ready.later = .{};
    const ready_run = try runWatch(arena, .{ .github = &ready });
    const ready_parsed = try expectOutcome(ready_run, "succeeded", "changed");
    defer ready_parsed.deinit();
    try expectChanged(ready_parsed.value, &.{"lifecycle"});
    try std.testing.expectEqualStrings("open", ready_parsed.value.object.get("snapshot").?.object.get("lifecycle").?.string);

    // A review requested of someone is a reviews change, not only a submitted decision.
    var requested = newGithub();
    defer requested.arena.deinit();
    requested.switch_after = 4;
    requested.later = .{ .requested = true };
    const requested_run = try runWatch(arena, .{ .github = &requested });
    const requested_parsed = try expectOutcome(requested_run, "succeeded", "changed");
    defer requested_parsed.deinit();
    try expectChanged(requested_parsed.value, &.{"reviews"});
    try std.testing.expectEqualStrings("pending", requested_parsed.value.object.get("snapshot").?.object.get("reviews").?.string);
}

test "PRW-79 an account that cannot be listed or is not signed in ends the watch before any request" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const without_account = "{\"url\":\"https://github.com/org/repo/pull/42\"}";
    var github = newGithub();
    defer github.arena.deinit();

    for ([_]@TypeOf(@as(Case, undefined).discovery){ .exits, .garbage }) |discovery| {
        const failed = try runWatch(arena, .{ .github = &github, .arguments = without_account, .discovery = discovery });
        const parsed = try expectOutcome(failed, "failed", "account_discovery_failed");
        defer parsed.deinit();
        try std.testing.expectEqualStrings("{\"outcome\":\"account_discovery_failed\"}", failed.text);
        try std.testing.expectEqual(@as(usize, 0), failed.requests);
    }
    // An account whose sign-in is not a success is not offered, so the model is told to authenticate.
    const signed_out = try runWatch(arena, .{ .github = &github, .arguments = without_account, .accounts = &.{"alice:error"} });
    const signed_out_parsed = try expectOutcome(signed_out, "succeeded", "auth_required");
    defer signed_out_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), signed_out.requests);
}

test "PRW-80 a Stop while the account is still being bound settles the watch cancelled" {
    if (!os.supported) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var github = newGithub();
    defer github.arena.deinit();
    // The credential read blocks for the named account; the account listing blocks for a discovered one.
    for ([_][]const u8{ "{\"url\":\"https://github.com/org/repo/pull/42\",\"account\":\"alice\"}", "{\"url\":\"https://github.com/org/repo/pull/42\"}" }) |arguments| {
        const finished = try runWatch(arena, .{ .github = &github, .arguments = arguments, .gh_blocks = true, .ending = .stop_while_binding });
        try std.testing.expectEqualStrings("cancelled", finished.code.?);
        try std.testing.expectEqualStrings("Stopped before this pull request watch completed.", finished.text);
        try std.testing.expectEqual(@as(usize, 0), finished.requests);
    }
}

test "PRW-81 a cancelled worker holds no Resolution and a finished one always does" {
    if (!os.supported) return error.SkipZigTest;
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var worker: Worker = .{
        .io = std.testing.io,
        .wake = undefined,
        .environment = &environment,
        .gh = "/nonexistent/gh",
        .url = try .from("https://github.com/org/repo/pull/42"),
        .account = try .from("alice"),
        .seed = 0,
        .pacing = .loopback,
        .deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{ .raw = .fromSeconds(60), .clock = .awake }),
        .origin = if (test_hooks) null else {},
        .budget = undefined,
    };
    try std.testing.expect(worker.state() == .running);
    // A worker cancelled by a fence ends with the default code and no text; settling that would resolve
    // the Action failed with nothing to read, so `state` reports it as cancelled instead.
    worker.requestCancel();
    worker.execute();
    worker.done.store(true, .release);
    try std.testing.expect(worker.state() == .cancelled);

    var finished: Worker = worker;
    finished.cancel = .init(false);
    finished.cancelled = false;
    finished.done = .init(false);
    finished.environment = null;
    finished.execute();
    finished.done.store(true, .release);
    try std.testing.expect(finished.state() == .finished);
    try std.testing.expectEqualStrings("{\"outcome\":\"gh_unavailable\"}", finished.state().finished.text);
    try std.testing.expectEqual(store.ActionResolutionCode.failed, finished.state().finished.code);
}
