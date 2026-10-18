//! Host owner of the Codex model catalog: one worker thread, one fetch at a
//! time, and the published catalog with its account and age. Decisions live
//! in `codex_model_catalog.zig`; this file owns credentials, curl, clocks and
//! publication. See ARCHITECTURE.md "Codex model catalog".
const CodexCatalog = @This();

const std = @import("std");
const builtin = @import("builtin");
const c = @import("curl");
const catalog = @import("codex_model_catalog.zig");
const codex_credentials = @import("codex_credentials.zig");
const model_adapter = @import("model_adapter.zig");
const protocol = @import("protocol.zig");

comptime {
    std.debug.assert(catalog.max_slug_bytes == protocol.max_model_bytes);
    std.debug.assert(catalog.max_observation_json_bytes == protocol.max_model_catalog_observation_bytes);
}

pub const fetch_timeout_ms = 5_000;

pub const Observation = catalog.Observation;

io: std.Io,
allocator: std.mem.Allocator,
url_storage: [model_adapter.max_catalog_url_bytes:0]u8 = undefined,
url: [:0]const u8 = "",
endpoint: []const u8,
ca_file: ?[]const u8,
authentication: model_adapter.Authentication,

mutex: std.Io.Mutex = .init,
condition: std.Io.Condition = .init,
published: catalog.Catalog = .{},
has_catalog: bool = false,
fetched_at_ms: i64 = 0,
account: protocol.Bounded(codex_credentials.max_account_id_bytes) = .{},
fedramp: bool = false,
last_failure: ?catalog.Reason = null,
requested: bool = false,
fetching: bool = false,
/// Completed fetches, successful or not; refresh callers compare against it.
completed: u64 = 0,
/// The completed count an explicit refresh still needs.
refresh_target: u64 = 0,
stopping: std.atomic.Value(bool) = .init(false),
/// Worker-owned parse destination; published only by copy under the mutex.
candidate: catalog.Catalog = .{},
thread: ?std.Thread = null,

/// Initialize in final storage; the worker borrows this address.
pub fn init(self: *CodexCatalog, io: std.Io, allocator: std.mem.Allocator, endpoint: []const u8, ca_file: ?[]const u8, authentication: model_adapter.Authentication) !void {
    self.* = .{ .io = io, .allocator = allocator, .endpoint = endpoint, .ca_file = ca_file, .authentication = authentication };
    self.url = try model_adapter.catalogUrl(endpoint, &self.url_storage);
}

pub fn start(self: *CodexCatalog) !void {
    self.thread = try std.Thread.spawn(.{}, run, .{self});
    self.request();
}

pub fn stop(self: *CodexCatalog) void {
    const thread = self.thread orelse return;
    self.mutex.lockUncancelable(self.io);
    self.stopping.store(true, .release);
    self.condition.broadcast(self.io);
    self.mutex.unlock(self.io);
    thread.join();
    self.thread = null;
}

/// Catalog age includes system suspend, so a catalog fetched before a long
/// sleep is stale after it.
fn nowMs(self: *const CodexCatalog) i64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(self.io, .boot).raw.nanoseconds, std.time.ns_per_ms));
}

/// Starts a fetch unless one is already requested or running.
pub fn request(self: *CodexCatalog) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.requestLocked();
}

fn requestLocked(self: *CodexCatalog) void {
    if (self.fetching or self.requested) return;
    self.requested = true;
    self.condition.broadcast(self.io);
}

fn stateLocked(self: *const CodexCatalog, now_ms: i64) catalog.State {
    return .{
        .catalog = if (self.has_catalog) &self.published else null,
        .fetched_at_ms = self.fetched_at_ms,
        .now_ms = now_ms,
        .last_failure = self.last_failure,
    };
}

/// The credential snapshot's account, read without Host or Store locks.
pub const Identity = struct {
    readable: bool = false,
    fedramp: bool = false,
    account: protocol.Bounded(codex_credentials.max_account_id_bytes) = .{},
};

/// Rereads the local credential snapshot. Every observation needs one, so no
/// verdict can assume the fetching account is still current. Call it outside
/// every Host and Store lock.
pub fn readIdentity(self: *const CodexCatalog) Identity {
    var record: codex_credentials.Record = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    var identity: Identity = .{};
    const readable = codex_credentials.readSnapshotInto(self.authentication.path, &record) catch false;
    if (!readable) return identity;
    identity.account.set(record.account_id.slice()) catch return identity;
    identity.fedramp = record.fedramp;
    identity.readable = true;
    return identity;
}

/// Listed slugs copied with an `absent` verdict, from the same catalog.
pub const Listed = struct {
    rows: [protocol.max_catalog_rejection_slugs]catalog.Row = undefined,
    len: usize = 0,
    /// All listed rows, including those beyond `rows`.
    count: usize = 0,

    pub fn items(self: *const Listed) []const catalog.Row {
        return self.rows[0..self.len];
    }
};

/// The current verdict from memory and an identity read beforehand. Starts a
/// background refresh when the catalog is missing or old; never waits for it.
/// For an `absent` verdict, `listed` receives the same catalog's listed rows.
pub fn observe(self: *CodexCatalog, model: []const u8, identity: *const Identity, listed: ?*Listed) Observation {
    const now_ms = self.nowMs();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const state = self.stateLocked(now_ms);
    if (catalog.needsRefresh(state)) self.requestLocked();
    const same = identity.readable and self.has_catalog and identity.fedramp == self.fedramp and
        std.mem.eql(u8, identity.account.slice(), self.account.slice());
    const observation: Observation = .{
        .verdict = catalog.classify(state, if (same) .confirmed else .unconfirmed, model),
        .age_ms = if (self.has_catalog) now_ms - self.fetched_at_ms else null,
    };
    if (listed) |out| if (observation.verdict == .absent) {
        out.* = .{};
        for (self.published.items()) |*row| {
            if (row.visibility != .list) continue;
            if (out.len < out.rows.len) {
                out.rows[out.len] = row.*;
                out.len += 1;
            }
            out.count += 1;
        }
    };
    return observation;
}

/// Requests a fetch that starts after this call and returns the completed
/// count that will include it. Never waits: Host intake workers are few, so
/// callers observe `listing().completed` instead of blocking a worker.
pub fn refresh(self: *CodexCatalog) u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    // A running fetch is joined: its completion satisfies every refresh
    // requested while it runs, so concurrent callers share one GET.
    const target = self.completed + 1;
    self.refresh_target = @max(self.refresh_target, target);
    self.requestLocked();
    return target;
}

pub const Listing = struct {
    has_catalog: bool,
    age_ms: ?i64,
    last_failure: ?catalog.Reason,
    fetching: bool,
    completed: u64,
    /// Total rows; `out` receives up to its length.
    count: usize,
};

/// Rows and status from one lock section, so availability, rows and the
/// completed count always describe the same catalog.
pub fn listing(self: *CodexCatalog, out: []catalog.Row) Listing {
    const now_ms = self.nowMs();
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var count: usize = 0;
    if (self.has_catalog) for (self.published.items()) |*row| {
        if (count < out.len) out[count] = row.*;
        count += 1;
    };
    return .{
        .has_catalog = self.has_catalog,
        .age_ms = if (self.has_catalog) now_ms - self.fetched_at_ms else null,
        .last_failure = self.last_failure,
        .fetching = self.fetching or self.requested,
        .completed = self.completed,
        .count = count,
    };
}

fn run(self: *CodexCatalog) void {
    while (true) {
        self.mutex.lockUncancelable(self.io);
        while (!self.stopping.load(.acquire) and !self.requested)
            self.condition.waitUncancelable(self.io, &self.mutex);
        if (self.stopping.load(.acquire)) {
            self.mutex.unlock(self.io);
            return;
        }
        self.requested = false;
        self.fetching = true;
        self.mutex.unlock(self.io);

        var fetched_account: protocol.Bounded(codex_credentials.max_account_id_bytes) = .{};
        var fetched_fedramp = false;
        const outcome = self.fetch(&fetched_account, &fetched_fedramp);
        // Publication requires the snapshot to name the fetching account.
        var current_account = false;
        if (outcome == null) {
            const identity = self.readIdentity();
            current_account = identity.readable and identity.fedramp == fetched_fedramp and
                std.mem.eql(u8, identity.account.slice(), fetched_account.slice());
        }
        const now_ms = self.nowMs();
        self.mutex.lockUncancelable(self.io);
        if (outcome) |reason| {
            self.last_failure = reason;
        } else if (!current_account) {
            self.last_failure = .other_account;
        } else {
            self.published = self.candidate;
            self.has_catalog = true;
            self.fetched_at_ms = now_ms;
            self.account = fetched_account;
            self.fedramp = fetched_fedramp;
            self.last_failure = null;
        }
        // An account change makes an older catalog unusable for rejection
        // until a fetch for the new account succeeds.
        if (outcome == null and !current_account) self.has_catalog = false;
        self.fetching = false;
        self.completed += 1;
        if (self.refresh_target > self.completed) self.requested = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
}

const Body = struct {
    list: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    overflow: bool = false,
    allocation_failed: bool = false,
};

fn writeCallback(data: [*c]u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
    const length = std.math.mul(usize, size, count) catch return 0;
    const body: *Body = @ptrCast(@alignCast(context orelse return 0));
    if (length > catalog.max_body_bytes - body.list.items.len) {
        body.overflow = true;
        return 0;
    }
    body.list.appendSlice(body.allocator, data[0..length]) catch {
        body.allocation_failed = true;
        return 0;
    };
    return length;
}

fn progressCallback(context: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const stopping: *const std.atomic.Value(bool) = @ptrCast(@alignCast(context orelse return 1));
    return @intFromBool(stopping.load(.acquire));
}

fn opt(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK) return error.TransportConfigurationFailed;
}

/// One bounded fetch into `candidate`. Returns null on success, else the
/// closed failure reason. Credentials never leave this frame.
fn fetch(self: *CodexCatalog, account: *protocol.Bounded(codex_credentials.max_account_id_bytes), fedramp: *bool) ?catalog.Reason {
    var headers: model_adapter.CatalogHeaders = .{};
    defer headers.deinit();
    {
        var lease: model_adapter.Credential = undefined;
        model_adapter.acquireCredentialInto(self.io, self.authentication, &lease) catch return .credential_unavailable;
        defer lease.release();
        account.set(lease.record.account_id.slice()) catch return .credential_unavailable;
        fedramp.* = lease.record.fedramp;
        headers.init(self.endpoint, self.ca_file, self.authentication, &lease) catch return .credential_unavailable;
    }
    var body: Body = .{ .allocator = self.allocator };
    defer body.list.deinit(self.allocator);
    const status = self.perform(&headers, &body) catch |err| return switch (err) {
        error.Timeout => .timeout,
        error.TooLarge => .too_large,
        else => .transport_failure,
    };
    if (status != 200) return .http_status;
    catalog.parse(body.list.items, &self.candidate) catch |err| return switch (err) {
        error.TooLarge => .too_large,
        error.Unparseable => .unparseable,
    };
    return null;
}

fn perform(self: *CodexCatalog, headers: *const model_adapter.CatalogHeaders, body: *Body) !u16 {
    const easy = c.curl_easy_init() orelse return error.TransportInitializationFailed;
    defer c.curl_easy_cleanup(easy);
    var list: ?*c.curl_slist = null;
    defer c.curl_slist_free_all(list);
    for (headers.slice()) |entry| list = c.curl_slist_append(list, entry.ptr) orelse return error.TransportInitializationFailed;
    var ca_storage: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    try opt(easy, c.CURLOPT_URL, self.url.ptr);
    try opt(easy, c.CURLOPT_HTTPGET, @as(c_long, 1));
    try opt(easy, c.CURLOPT_HTTPHEADER, list);
    try opt(easy, c.CURLOPT_WRITEFUNCTION, writeCallback);
    try opt(easy, c.CURLOPT_WRITEDATA, body);
    try opt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
    try opt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, 0));
    try opt(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
    try opt(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
    if (self.ca_file) |path| {
        const terminated = std.fmt.bufPrintSentinel(&ca_storage, "{s}", .{path}, 0) catch return error.TransportConfigurationFailed;
        try opt(easy, c.CURLOPT_CAINFO, terminated.ptr);
    } else if (builtin.os.tag == .macos) try opt(easy, c.CURLOPT_SSL_OPTIONS, @as(c_long, c.CURLSSLOPT_NATIVE_CA));
    try opt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, fetch_timeout_ms));
    try opt(easy, c.CURLOPT_TIMEOUT_MS, @as(c_long, fetch_timeout_ms));
    try opt(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    try opt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    try opt(easy, c.CURLOPT_XFERINFOFUNCTION, progressCallback);
    try opt(easy, c.CURLOPT_XFERINFODATA, &self.stopping);
    const result = c.curl_easy_perform(easy);
    if (body.overflow) return error.TooLarge;
    if (result == c.CURLE_OPERATION_TIMEDOUT) return error.Timeout;
    if (result != c.CURLE_OK) return error.TransportFailed;
    var status: c_long = 0;
    if (c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK) return error.TransportFailed;
    return std.math.cast(u16, status) orelse error.TransportFailed;
}
