const std = @import("std");
const h2 = @import("h2");
const watch = @import("github_pr_watch.zig");
const descriptor = @import("github_pr_watch_descriptor.zig");
const secrets = @import("secret_value.zig");
const process = @import("os/process.zig");

const ChildObservation = extern struct { kind: c_int, value: c_int };
extern fn rui_bash_observe(pid: c_int, observation: *ChildObservation) c_int;

pub const Cancel = *const std.atomic.Value(bool);
pub const Deadline = std.Io.Clock.Timestamp;
const max_helper_output = 64 * 1024;
const max_token = 4096;
pub const max_body = 2 * 1024 * 1024;
pub const max_accounts = 100;
pub const max_login_bytes = descriptor.max_login_bytes;

fn check(io: std.Io, deadline: Deadline, cancel: Cancel) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
    if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
}

fn environment(allocator: std.mem.Allocator, source: *const std.process.Environ.Map) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(allocator);
    errdefer env.deinit();
    // Preserve the Host's gh profile and keyring context, but not ambient tokens.
    for ([_][]const u8{ "PATH", "HOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR" }) |key| {
        if (source.get(key)) |value| try env.put(key, value);
    }
    try env.put("GH_PROMPT_DISABLED", "1");
    try env.put("GH_NO_UPDATE_NOTIFIER", "1");
    return env;
}

// Bounded output is read directly into caller-owned private memory. Neither
// stderr nor command output is logged, even on failure.
fn helper(io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8, output: []u8, deadline: Deadline, cancel: Cancel) !usize {
    return helperWithClock(io, env, argv, output, deadline, cancel, RealHelperClock{});
}

const RealHelperClock = struct {
    fn now(_: RealHelperClock, io: std.Io, clock: std.Io.Clock) std.Io.Timestamp {
        return clock.now(io);
    }
};

fn checkHelper(io: std.Io, deadline: Deadline, cancel: Cancel, clock: anytype) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
    if (clock.now(io, deadline.clock).nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
}

fn helperWithClock(io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8, output: []u8, deadline: Deadline, cancel: Cancel, clock: anytype) !usize {
    try checkHelper(io, deadline, cancel, clock);
    var child = std.process.spawn(io, .{ .argv = argv, .environ_map = env, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe, .pgid = 0 }) catch return error.GhUnavailable;
    defer {
        if (child.id) |pid| {
            // The helper starts its own group; terminate helpers it spawned as
            // well as the direct child before reaping the latter.
            _ = process.signalGroup(pid, .KILL);
            var status: c_int = undefined;
            while (std.c.waitpid(pid, &status, 0) < 0) {
                if (std.posix.errno(-1) != .INTR) break;
            }
        }
        if (child.stdout) |file| file.close(io);
        if (child.stderr) |file| file.close(io);
    }
    for ([_]std.posix.fd_t{ child.stdout.?.handle, child.stderr.?.handle }) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        const nonblock: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
    }
    var buffers: [2][4096]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&buffers));
    var closed = [2]bool{ false, false };
    var used: usize = 0;
    var stderr_size: usize = 0;
    while (!closed[0] or !closed[1]) {
        try checkHelper(io, deadline, cancel, clock);
        var progressed = false;
        for ([_]std.posix.fd_t{ child.stdout.?.handle, child.stderr.?.handle }, 0..) |fd, i| {
            if (closed[i]) continue;
            const n = std.c.read(fd, &buffers[i], buffers[i].len);
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .AGAIN or e == .INTR) continue;
                return error.InputOutput;
            }
            if (n == 0) {
                closed[i] = true;
                continue;
            }
            progressed = true;
            const count: usize = @intCast(n);
            if (i == 0) {
                if (count > output.len - used) return error.HelperOutputTooLong;
                @memcpy(output[used..][0..count], buffers[i][0..count]);
                used += count;
            } else {
                if (count > max_helper_output - stderr_size) return error.HelperOutputTooLong;
                stderr_size += count;
            }
        }
        if (!progressed) try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    // Observe exit without reaping: the unreaped leader reserves the group
    // ID until any descendants have been killed, including on success.
    while (true) {
        try checkHelper(io, deadline, cancel, clock);
        var observation: ChildObservation = undefined;
        const observed = rui_bash_observe(child.id.?, &observation);
        if (observed < 0) {
            // ECHILD means another owner reaped it; do not signal a group ID
            // that may now have been recycled.
            if (observed == -@as(c_int, @intCast(@backingInt(std.posix.E.CHILD)))) child.id = null;
            return error.GhFailed;
        }
        if (observed == 1) {
            _ = process.signalGroup(child.id.?, .KILL);
            var status: c_int = undefined;
            const waited = std.c.waitpid(child.id.?, &status, std.posix.W.NOHANG);
            if (waited < 0 and std.posix.errno(waited) == .CHILD) child.id = null;
            if (waited <= 0) return error.GhFailed;
            child.id = null;
            const bits: u32 = @bitCast(status);
            if (!std.posix.W.IFEXITED(bits) or std.posix.W.EXITSTATUS(bits) != 0) return error.GhFailed;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    return used;
}

pub const Accounts = struct {
    names: [][]u8,
    pub fn deinit(self: *Accounts, allocator: std.mem.Allocator) void {
        for (self.names) |name| allocator.free(name);
        allocator.free(self.names);
        self.* = undefined;
    }
};

/// `gh` is the executable to run: the Host passes `"gh"`, found on its own PATH; a test names a fake by path.
pub fn discover(allocator: std.mem.Allocator, io: std.Io, source: *const std.process.Environ.Map, deadline: Deadline, cancel: Cancel, gh: []const u8) !Accounts {
    var env = try environment(allocator, source);
    defer env.deinit();
    const bytes = try allocator.alloc(u8, max_helper_output);
    defer {
        secrets.wipeAndFree(allocator, bytes, .fromByteUnits(@alignOf(u8)), @returnAddress());
    }
    const used = try helper(io, &env, &.{ gh, "auth", "status", "--hostname", "github.com", "--json", "hosts", "--no-refresh" }, bytes, deadline, cancel);
    return parseAccounts(allocator, bytes[0..used]);
}

fn parseAccounts(allocator: std.mem.Allocator, input: []const u8) !Accounts {
    var wiping: secrets.WipingAllocator = .{ .backing = allocator };
    var parsed = std.json.parseFromSlice(std.json.Value, wiping.allocator(), input, .{}) catch return error.AccountDiscoveryFailed;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.AccountDiscoveryFailed;
    const hosts = root.object.get("hosts") orelse return error.AccountDiscoveryFailed;
    if (hosts != .object) return error.AccountDiscoveryFailed;
    const entries = hosts.object.get("github.com") orelse return .{ .names = try allocator.alloc([]u8, 0) };
    if (entries != .array) return error.AccountDiscoveryFailed;
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    for (entries.array.items) |entry| {
        if (entry != .object) return error.AccountDiscoveryFailed;
        const login = entry.object.get("login") orelse return error.AccountDiscoveryFailed;
        const state = entry.object.get("state") orelse return error.AccountDiscoveryFailed;
        if (login != .string or state != .string) return error.AccountDiscoveryFailed;
        // An account that cannot be bound is not offered; it must not hide the others.
        if (!descriptor.validLogin(login.string) or !std.mem.eql(u8, state.string, "success")) continue;
        var duplicate = false;
        for (names.items) |name| if (std.ascii.eqlIgnoreCase(name, login.string)) {
            duplicate = true;
            break;
        };
        if (!duplicate) {
            if (names.items.len >= max_accounts) return error.AccountDiscoveryFailed;
            const name = try allocator.dupe(u8, login.string);
            errdefer allocator.free(name);
            try names.append(allocator, name);
        }
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return .{ .names = try names.toOwnedSlice(allocator) };
}

pub const Secret = struct {
    bytes: []u8,
    pub fn deinit(self: *Secret, allocator: std.mem.Allocator) void {
        secrets.wipeAndFree(allocator, self.bytes, .fromByteUnits(@alignOf(u8)), @returnAddress());
        self.* = undefined;
    }
};

pub fn token(allocator: std.mem.Allocator, io: std.Io, source: *const std.process.Environ.Map, login: []const u8, deadline: Deadline, cancel: Cancel, gh: []const u8) !Secret {
    if (!descriptor.validLogin(login)) return error.InvalidAccount;
    var env = try environment(allocator, source);
    defer env.deinit();
    var output: [max_token + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    const used = try helper(io, &env, &.{ gh, "auth", "token", "--hostname", "github.com", "--user", login, "--no-refresh" }, &output, deadline, cancel);
    const value = std.mem.trimEnd(u8, output[0..used], "\r\n");
    if (value.len == 0 or value.len > max_token) return error.InvalidToken;
    for (value) |c| if (c <= 32 or c >= 127) return error.InvalidToken;
    return .{ .bytes = try allocator.dupe(u8, value) };
}

pub const Endpoint = union(enum) {
    identity,
    pr: watch.PrKey,
    reviews: struct { pr: watch.PrKey, page: u8 },
    check_runs: struct { pr: watch.PrKey, head: watch.Digest, page: u8 },
    status: struct { pr: watch.PrKey, head: watch.Digest, page: u8 },
};

fn path(allocator: std.mem.Allocator, endpoint: Endpoint) ![]u8 {
    if (endpoint == .identity) return allocator.dupe(u8, "/user");
    const pr: watch.PrKey = switch (endpoint) {
        .identity => unreachable,
        .pr => |p| p,
        .reviews => |v| v.pr,
        .check_runs => |v| v.pr,
        .status => |v| v.pr,
    };
    const canonical = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/pull/{d}", .{ pr.owner, pr.repo, pr.number });
    defer allocator.free(canonical);
    _ = watch.parseUrl(canonical) catch return error.InvalidTarget;
    return switch (endpoint) {
        .identity => unreachable,
        .pr => std.fmt.allocPrint(allocator, "/repos/{s}/{s}/pulls/{d}", .{ pr.owner, pr.repo, pr.number }),
        .reviews => |v| if (v.page == 0 or v.page > 10) error.InvalidPage else std.fmt.allocPrint(allocator, "/repos/{s}/{s}/pulls/{d}/reviews?per_page=100&page={d}", .{ pr.owner, pr.repo, pr.number, v.page }),
        .check_runs => |v| if (v.page == 0 or v.page > 10) error.InvalidPage else std.fmt.allocPrint(allocator, "/repos/{s}/{s}/commits/{s}/check-runs?per_page=100&page={d}&filter=all", .{ pr.owner, pr.repo, std.fmt.bytesToHex(v.head, .lower), v.page }),
        .status => |v| if (v.page == 0 or v.page > 10) error.InvalidPage else std.fmt.allocPrint(allocator, "/repos/{s}/{s}/commits/{s}/status?per_page=100&page={d}", .{ pr.owner, pr.repo, std.fmt.bytesToHex(v.head, .lower), v.page }),
    };
}

pub const Response = struct {
    status: u16,
    body: []u8,
    etag: ?[]u8 = null,
    link: ?[]u8 = null,
    retry_after: ?[]u8 = null,
    rate_remaining: ?[]u8 = null,
    rate_reset: ?[]u8 = null,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        secrets.wipeAndFree(allocator, self.body, .fromByteUnits(@alignOf(u8)), @returnAddress());
        inline for (.{ "etag", "link", "retry_after", "rate_remaining", "rate_reset" }) |field| {
            if (@field(self, field)) |value| {
                secrets.wipeAndFree(allocator, value, .fromByteUnits(@alignOf(u8)), @returnAddress());
            }
        }
        self.* = undefined;
    }
};

const Receiver = struct {
    allocator: std.mem.Allocator,
    response: *Response,
    failed: bool = false,
    pub fn observe(self: *Receiver, _: *h2.Stream, event: h2.Event) h2.Verdict {
        switch (event) {
            .head => |head| if (head.kind == .final) {
                self.response.status = head.status;
                for (head.fields) |field| {
                    const dest: ?*?[]u8 = if (std.ascii.eqlIgnoreCase(field.name, "etag")) &self.response.etag else if (std.ascii.eqlIgnoreCase(field.name, "link")) &self.response.link else if (std.ascii.eqlIgnoreCase(field.name, "retry-after")) &self.response.retry_after else if (std.ascii.eqlIgnoreCase(field.name, "x-ratelimit-remaining")) &self.response.rate_remaining else if (std.ascii.eqlIgnoreCase(field.name, "x-ratelimit-reset")) &self.response.rate_reset else null;
                    if (dest) |slot| {
                        if (slot.* != null or field.value.len > 8192) {
                            self.failed = true;
                            return .refuse;
                        }
                        slot.* = self.allocator.dupe(u8, field.value) catch {
                            self.failed = true;
                            return .refuse;
                        };
                    }
                }
            },
            else => {},
        }
        return .accept;
    }
};

// The response is private worker data; callers must reduce it before publishing.
// Redirects are returned as status codes and never followed.
pub fn get(allocator: std.mem.Allocator, io: std.Io, secret: *const Secret, endpoint: Endpoint, etag: ?[]const u8, deadline: Deadline, cancel: Cancel) !Response {
    return getAt(allocator, io, secret, endpoint, etag, deadline, cancel, "https://api.github.com", h2.proxyFromEnvironment());
}

pub const getForTest = if (@import("builtin").is_test or @import("build_options").test_pauses) getLoopback else {};

fn getLoopback(allocator: std.mem.Allocator, io: std.Io, secret: *const Secret, endpoint: Endpoint, etag: ?[]const u8, deadline: Deadline, cancel: Cancel, origin: []const u8) !Response {
    try @import("github_watch_origin.zig").validateLoopback(origin);
    return getAt(allocator, io, secret, endpoint, etag, deadline, cancel, origin, null);
}

fn getAt(allocator: std.mem.Allocator, io: std.Io, secret: *const Secret, endpoint: Endpoint, etag: ?[]const u8, deadline: Deadline, cancel: Cancel, origin: []const u8, proxy: ?h2.Proxy) !Response {
    try check(io, deadline, cancel);
    const suffix = try path(allocator, endpoint);
    defer allocator.free(suffix);
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, suffix });
    defer allocator.free(url);
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{secret.bytes});
    defer {
        secrets.wipeAndFree(allocator, auth, .fromByteUnits(@alignOf(u8)), @returnAddress());
    }
    var response: Response = .{ .status = 0, .body = try allocator.alloc(u8, max_body) };
    errdefer response.deinit(allocator);
    var client: h2.Client = undefined;
    try client.init(allocator, io, .{ .stream_capacity = 1, .inactivity_ns = 30 * std.time.ns_per_s, .connect_timeout_ns = 10 * std.time.ns_per_s, .proxy = proxy });
    defer client.deinit();
    const target = try client.addEndpoint(url);
    var fields: [5]h2.Field = undefined;
    fields[0] = .{ .name = "authorization", .value = auth, .sensitive = true };
    fields[1] = .{ .name = "accept", .value = "application/vnd.github+json" };
    fields[2] = .{ .name = "user-agent", .value = "rui-pr-watcher" };
    fields[3] = .{ .name = "x-github-api-version", .value = "2022-11-28" };
    var count: usize = 4;
    if (etag) |value| {
        if (value.len > 8192) return error.InvalidValidator;
        for (value) |c| if (c < 32 or c == 127) return error.InvalidValidator;
        fields[count] = .{ .name = "if-none-match", .value = value };
        count += 1;
    }
    var stream: h2.Stream = .idle;
    try client.prepare(&stream, .{ .endpoint = target, .method = .get, .fields = fields[0..count], .body = .{ .bytes = "" }, .sink = .{ .buffer = response.body } });
    defer {
        client.cancel(&stream);
        stream.deinit();
    }
    client.launch(&stream);
    var receiver: Receiver = .{ .allocator = allocator, .response = &response };
    while (true) {
        try check(io, deadline, cancel);
        try client.drive(&receiver);
        if (client.nextFinished()) |_| {
            if (receiver.failed or stream.end().?.cause != .complete or response.status == 0) return error.RequestFailed;
            const len: usize = @intCast(stream.responseLength());
            const exact = try allocator.dupe(u8, response.body[0..len]);
            secrets.wipeAndFree(allocator, response.body, .fromByteUnits(@alignOf(u8)), @returnAddress());
            response.body = exact;
            return response;
        }
        const left = deadline.durationFromNow(io).raw.toMilliseconds();
        if (left <= 0) return error.Timeout;
        try client.wait(@intCast(@min(left, 100)));
    }
}

test "PRW-9 paths are fixed and reject unvalidated targets" {
    const a = std.testing.allocator;
    const pr: watch.PrKey = .{ .owner = "org", .repo = "repo", .number = 42 };
    const target = try path(a, .{ .reviews = .{ .pr = pr, .page = 2 } });
    defer a.free(target);
    try std.testing.expectEqualStrings("/repos/org/repo/pulls/42/reviews?per_page=100&page=2", target);
    try std.testing.expectError(error.InvalidTarget, path(a, .{ .pr = .{ .owner = "org/other", .repo = "repo", .number = 1 } }));
    try std.testing.expectError(error.InvalidPage, path(a, .{ .reviews = .{ .pr = pr, .page = 0 } }));
    const status_path = try path(a, .{ .status = .{ .pr = pr, .head = @splat(0xab), .page = 1 } });
    defer a.free(status_path);
    try std.testing.expectEqualStrings("/repos/org/repo/commits/abababababababababababababababababababab/status?per_page=100&page=1", status_path);
    const checks_path = try path(a, .{ .check_runs = .{ .pr = pr, .head = @splat(0xab), .page = 2 } });
    defer a.free(checks_path);
    try std.testing.expectEqualStrings("/repos/org/repo/commits/abababababababababababababababababababab/check-runs?per_page=100&page=2&filter=all", checks_path);
}

test "PRW-8 gh discovery and exact account token use a scrubbed noninteractive environment" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(io, .{ .sub_path = "gh", .data =
        \\#!/bin/sh
        \\[ "${GH_PROMPT_DISABLED}" = 1 ] || exit 21
        \\[ -z "${GH_TOKEN+x}${GITHUB_TOKEN+x}${GH_ENTERPRISE_TOKEN+x}${GITHUB_ENTERPRISE_TOKEN+x}" ] || exit 22
        \\if [ "$1 $2 $3 $4 $5 $6 $7" = "auth status --hostname github.com --json hosts --no-refresh" ]; then
        \\  printf '%s\n' '{"hosts":{"github.com":[{"login":"alice","state":"success"}]}}'
        \\elif [ "$1 $2 $3 $4 $5 $6 $7" = "auth token --hostname github.com --user alice --no-refresh" ]; then
        \\  printf 'synthetic-token\n'
        \\else
        \\  exit 23
        \\fi
    , .flags = .{ .permissions = .fromMode(0o700) } });
    const fixture_path = try dir.dir.realPathFileAlloc(io, ".", a);
    defer a.free(fixture_path);
    const executable = try std.fmt.allocPrint(a, "{s}/gh", .{fixture_path});
    defer a.free(executable);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("PATH", fixture_path);
    try env.put("HOME", fixture_path);
    inline for (.{ "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN" }) |key| try env.put(key, "synthetic-ambient-secret");
    var stopped: std.atomic.Value(bool) = .init(false);
    const deadline: Deadline = .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake });
    var accounts = try discover(a, io, &env, deadline, &stopped, executable);
    defer accounts.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), accounts.names.len);
    try std.testing.expectEqualStrings("alice", accounts.names[0]);
    var credential = try token(a, io, &env, "alice", deadline, &stopped, executable);
    defer credential.deinit(a);
    try std.testing.expectEqualStrings("synthetic-token", credential.bytes);
    try std.testing.expectError(error.GhFailed, token(a, io, &env, "other", deadline, &stopped, executable));
    stopped.store(true, .release);
    try std.testing.expectError(error.Cancelled, discover(a, io, &env, deadline, &stopped, executable));
    stopped.store(false, .release);
    const expired: Deadline = .fromNow(io, .{ .raw = .fromMilliseconds(0), .clock = .awake });
    try std.testing.expectError(error.Timeout, token(a, io, &env, "alice", expired, &stopped, executable));
}

test "PRW-32 cancelled request never opens a connection" {
    var stopped: std.atomic.Value(bool) = .init(true);
    var secret: Secret = .{ .bytes = @constCast("synthetic") };
    const deadline: Deadline = .fromNow(std.testing.io, .{ .raw = .fromSeconds(1), .clock = .awake });
    try std.testing.expectError(error.Cancelled, get(std.testing.allocator, std.testing.io, &secret, .identity, null, deadline, &stopped));
}

const test_poll = @import("test_poll");

test "PRW-30 gh helper deadline covers a running child and a child that closes its pipes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const FakeClock = struct {
        expired: std.atomic.Value(bool) = .init(false),
        limit: i96,
        fn now(self: *const @This(), _: std.Io, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = if (self.expired.load(.acquire)) self.limit else self.limit - 1 };
        }
    };
    const Worker = struct {
        io: std.Io,
        env: *const std.process.Environ.Map,
        executable: []const u8,
        deadline: Deadline,
        clock: *const FakeClock,
        cancelled: *const std.atomic.Value(bool),
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var output: [32]u8 = undefined;
            _ = helperWithClock(self.io, self.env, &.{self.executable}, &output, self.deadline, self.cancelled, self.clock) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("HOME", root);
    for ([_][]const u8{
        "#!/bin/sh\ntrap '' TERM\necho \"$$\" > \"$HOME/ready.tmp\"\n/bin/mv \"$HOME/ready.tmp\" \"$HOME/ready\"\nexec /bin/sleep 300\n",
        "#!/bin/sh\ntrap '' TERM\nexec 1>&- 2>&-\necho \"$$\" > \"$HOME/ready.tmp\"\n/bin/mv \"$HOME/ready.tmp\" \"$HOME/ready\"\nexec /bin/sleep 300\n",
    }) |script| {
        try dir.dir.writeFile(io, .{ .sub_path = "gh", .data = script, .flags = .{ .permissions = .fromMode(0o700) } });
        const executable = try dir.dir.realPathFileAlloc(io, "gh", a);
        defer a.free(executable);
        const deadline: Deadline = .fromNow(io, .{ .raw = .fromSeconds(3600), .clock = .awake });
        var clock: FakeClock = .{ .limit = deadline.raw.nanoseconds };
        var cancelled: std.atomic.Value(bool) = .init(false);
        var worker: Worker = .{ .io = io, .env = &env, .executable = executable, .deadline = deadline, .clock = &clock, .cancelled = &cancelled };
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        var joined = false;
        defer if (!joined) {
            cancelled.store(true, .release);
            thread.join();
        };
        const watchdog: Deadline = .fromNow(io, .{ .raw = .fromSeconds(15), .clock = .awake });
        const Ready = struct {
            dir: std.Io.Dir,
            io: std.Io,
            fn ready(self: @This()) bool {
                self.dir.access(self.io, "ready", .{}) catch return false;
                return true;
            }
        };
        test_poll.waitUntil(io, watchdog, Ready{ .dir = dir.dir, .io = io }, Ready.ready) catch return error.TestHelperNotReady;
        const text = try dir.dir.readFileAlloc(io, "ready", a, .limited(64));
        defer a.free(text);
        const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \r\n"), 10);
        try std.testing.expect(!worker.done.load(.acquire));
        clock.expired.store(true, .release);
        test_poll.waitUntil(io, watchdog, &worker.done, test_poll.isSet) catch return error.TestHelperDidNotStop;
        thread.join();
        joined = true;
        try std.testing.expectEqual(@as(?anyerror, error.Timeout), worker.failure);
        try std.testing.expectEqual(@as(c_int, -1), std.c.kill(pid, @fromBackingInt(@intCast(0))));
        try std.testing.expectEqual(std.posix.E.SRCH, std.posix.errno(-1));
        try dir.dir.deleteFile(io, "ready");
    }
}

test "PRW-82 response release frees only storage the response owns" {
    const a = std.testing.allocator;
    // A 304 or empty 200 duplicates a zero-length body: no storage, dangling pointer.
    var empty: Response = .{ .status = 304, .body = try a.dupe(u8, ""), .etag = try a.dupe(u8, "\"v1\"") };
    empty.deinit(a);
    var owned: Response = .{ .status = 200, .body = try a.dupe(u8, "{}"), .link = try a.dupe(u8, "next") };
    owned.deinit(a);
    var bare: Response = .{ .status = 200, .body = try a.dupe(u8, "") };
    bare.deinit(a);
}
