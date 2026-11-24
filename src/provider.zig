const std = @import("std");
const h2 = @import("h2");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");
const attempt = @import("attempt.zig");
const transport_policy = @import("transport_policy.zig");
const codec_abi = @import("codec_abi.zig");
const codecs = @import("codecs.zig");
const pages = @import("os/pages.zig");

pub const nghttp2_version = h2.nghttp2_version;
pub const openssl_version = h2.openssl_version;
pub const max_endpoint_bytes = @import("endpoint_value.zig").max_endpoint_bytes;
pub const checkLibraries = h2.checkLibraries;

pub const ScratchBudget = @import("ScratchBudget.zig");

pub const PreparedRequest = struct {
    file: std.Io.File,
    length: u64,
    charged: u64,
    structured_output: bool,
    provider: protocol.Provider,
    codec: protocol.Codec,
    headers: codec_abi.Headers,

    pub fn deinit(self: *PreparedRequest, io: std.Io, budget: ScratchBudget) void {
        self.file.close(io);
        budget.release(self.charged);
        self.* = undefined;
    }
};

const content_type: h2.Field = .{ .name = "content-type", .value = "application/json", .borrowed = true };

pub const host_request_fields = [_][]const u8{ content_type.name, "authorization", "chatgpt-account-id", "user-agent", "x-openai-fedramp" } ++ routing_fields;

const routing_fields = fields: {
    var names: []const []const u8 = &.{};
    for (std.enums.values(protocol.Codec)) |codec| {
        const name = codecs.manifest(codec).observe.turn_state;
        if (name.len != 0) names = names ++ .{name};
    }
    break :fields names[0..names.len].*;
};

pub fn hostField(name: []const u8) bool {
    for (host_request_fields ++ h2.owned_fields) |owned| {
        if (std.mem.eql(u8, name, owned)) return true;
    }
    return false;
}

pub const max_turn_state_bytes = 4096;

pub const TurnStateSink = struct {
    context: *anyopaque,
    capture: *const fn (context: *anyopaque, key: TurnStateKey, value: []const u8) void,
    replay: *const fn (context: *anyopaque, served: protocol.Provider, turn_id: u64, owner: RoutingOwner) Replay,

    pub const Replay = struct { epoch: u64, value: []const u8 };
};

pub const RoutingOwner = [32]u8;

pub const Routing = struct { turn_id: u64, owner: RoutingOwner };

pub const TurnStateKey = struct {
    provider: protocol.Provider,
    turn_id: u64,
    epoch: u64,
};

pub fn AllowanceField(comptime T: type) type {
    return union(enum) {
        missing,
        invalid,
        value: T,

        fn add(self: *@This(), value: ?T) void {
            const parsed = value orelse {
                self.* = .invalid;
                return;
            };
            switch (self.*) {
                .missing => self.* = .{ .value = parsed },
                .invalid => {},
                .value => |previous| if (previous != parsed) {
                    self.* = .invalid;
                },
            }
        }
    };
}

pub const AllowanceWindow = struct {
    used: AllowanceField(f64) = .missing,
    minutes: AllowanceField(u64) = .missing,
    reset_at: AllowanceField(u64) = .missing,
};

pub const AllowanceObservation = struct {
    binding: attempt.AttemptBinding,
    provider: protocol.Provider,
    status: u16,
    observed_at: i64,
    primary: AllowanceWindow = .{},
    secondary: AllowanceWindow = .{},

    fn field(self: *AllowanceObservation, names: *const codec_abi.ObservedHeaders, name: []const u8, value: []const u8) void {
        const fields = .{
            .{ names.primary_used, &self.primary.used },
            .{ names.secondary_used, &self.secondary.used },
        };
        inline for (fields) |entry| {
            if (entry[0].len != 0 and std.mem.eql(u8, name, entry[0])) {
                const number = std.fmt.parseFloat(f64, value) catch {
                    entry[1].add(null);
                    return;
                };
                entry[1].add(if (std.math.isFinite(number) and number >= 0) number else null);
                return;
            }
        }
        const integers = .{
            .{ names.primary_minutes, &self.primary.minutes },
            .{ names.primary_reset_at, &self.primary.reset_at },
            .{ names.secondary_minutes, &self.secondary.minutes },
            .{ names.secondary_reset_at, &self.secondary.reset_at },
        };
        inline for (integers) |entry| {
            if (entry[0].len != 0 and std.mem.eql(u8, name, entry[0])) {
                const number = std.fmt.parseUnsigned(u64, value, 10) catch {
                    entry[1].add(null);
                    return;
                };
                entry[1].add(if (number > 0) number else null);
                return;
            }
        }
    }
};

pub const AllowanceSource = struct { binding: attempt.AttemptBinding, provider: protocol.Provider };

/// The Reactor-wide observation. Header names belong to each Transfer's codec (its manifest).
pub const HeaderObservation = struct {
    turn_state: ?TurnStateSink = null,
};

pub const Options = struct {
    endpoints: std.EnumArray(protocol.Provider, ?[]const u8),
    ca_file: ?[]const u8 = null,
    capacity: usize,
    inactivity_seconds: i64,
    observation: HeaderObservation = .{},
    scratch_path: []const u8,
    budget: ScratchBudget,
    listing_urls: std.EnumArray(ListingKind, ?[]const u8) = .initFill(null),
};

pub const ListingKind = blk: {
    var count = 1;
    for (std.enums.values(protocol.Provider)) |served| count += @intFromBool(served.facts().model_list == .live);
    var names: [count][]const u8 = undefined;
    var values: [count]u8 = undefined;
    names[0] = "catalog";
    var at = 1;
    for (std.enums.values(protocol.Provider)) |served| if (served.facts().model_list == .live) {
        names[at] = @tagName(served);
        at += 1;
    };
    for (&values, 0..) |*value, index| value.* = index;
    break :blk @Enum(u8, .exhaustive, &names, &values);
};

pub fn providerListing(served: protocol.Provider) ?ListingKind {
    return switch (served) {
        inline else => |name| if (@hasField(ListingKind, @tagName(name))) @field(ListingKind, @tagName(name)) else null,
    };
}

pub fn listedProvider(kind: ListingKind) ?protocol.Provider {
    return switch (kind) {
        .catalog => null,
        inline else => |name| @field(protocol.Provider, @tagName(name)),
    };
}
pub const ListingFetch = struct {
    stream: h2.Stream,
    finished: bool,
    etag: ?protocol.Bounded(512) = null,
};

pub const Faults = struct {
    request_read: bool = false,
    response_acquire: bool = false,
    response_unlink: bool = false,
    response_write: bool = false,
};

pub const Completion = struct {
    transfer: *Transfer,
    outcome: transport_policy.TransferOutcome,
    queued_after: usize,
};

pub const ProtocolObservation = struct {
    new_connections: u1,
    replays: u8,
};

pub const SharedCredential = struct {
    next: ?*SharedCredential,
    users: u32,
    authorization_len: u32,
    account_id_len: u32,

    const scheme = "Bearer ";

    pub fn authorization(self: *SharedCredential) []const u8 {
        return self.bytes()[0..self.authorization_len];
    }

    pub fn accountId(self: *SharedCredential) []const u8 {
        return self.bytes()[self.authorization_len..];
    }

    fn bytes(self: *SharedCredential) []u8 {
        return self.allocation()[@sizeOf(SharedCredential)..];
    }

    fn allocation(self: *SharedCredential) []align(@alignOf(SharedCredential)) u8 {
        const base: [*]align(@alignOf(SharedCredential)) u8 = @ptrCast(self);
        return base[0 .. @sizeOf(SharedCredential) + self.authorization_len + self.account_id_len];
    }
};

pub const Credentials = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    head: ?*SharedCredential = null,

    pub fn share(self: *Credentials, access_token: []const u8, account_id: []const u8) error{OutOfMemory}!*SharedCredential {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const scheme = SharedCredential.scheme;
        var node = self.head;
        while (node) |shared| : (node = shared.next) {
            const authorization = shared.authorization();
            if (authorization.len == scheme.len + access_token.len and
                std.mem.eql(u8, authorization[scheme.len..], access_token) and
                std.mem.eql(u8, shared.accountId(), account_id))
            {
                shared.users += 1;
                return shared;
            }
        }
        const authorization_len = scheme.len + access_token.len;
        const memory = try self.allocator.alignedAlloc(u8, .of(SharedCredential), @sizeOf(SharedCredential) + authorization_len + account_id.len);
        const shared: *SharedCredential = @ptrCast(memory.ptr);
        shared.* = .{
            .next = self.head,
            .users = 1,
            .authorization_len = @intCast(authorization_len),
            .account_id_len = @intCast(account_id.len),
        };
        const destination = shared.bytes();
        @memcpy(destination[0..scheme.len], scheme);
        @memcpy(destination[scheme.len..authorization_len], access_token);
        @memcpy(destination[authorization_len..], account_id);
        self.head = shared;
        return shared;
    }

    pub fn release(self: *Credentials, shared: *SharedCredential) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        shared.users -= 1;
        if (shared.users != 0) return;
        var link = &self.head;
        while (link.* != shared) link = &link.*.?.next;
        link.* = shared.next;
        const memory = shared.allocation();
        std.crypto.secureZero(u8, memory);
        self.allocator.free(memory);
    }
};

pub const Reactor = struct {
    comptime {
        const required_endpoints = std.enums.values(protocol.Provider).len + std.enums.values(ListingKind).len;
        if (h2.max_endpoints < required_endpoints)
            @compileError("provider request and independent listing URLs exceed H2 endpoint capacity");
    }

    client: h2.Client,
    endpoints: std.EnumArray(protocol.Provider, ?h2.Endpoint),
    io: std.Io,
    observation: HeaderObservation,
    scratch_path: []const u8,
    budget: ScratchBudget,
    credentials: Credentials,
    listing_endpoints: std.EnumArray(ListingKind, ?h2.Endpoint),
    catalog_endpoint_error: ?h2.EndpointError,
    listings: std.EnumArray(ListingKind, ?*ListingFetch),
    mutex: std.Io.Mutex = .init,
    stopping: bool = false,
    failure: ?h2.DriveError = null,
    wake: ?*std.Io.Event = null,

    pub fn init(self: *Reactor, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
        return self.initWithProxy(allocator, io, options, h2.proxyFromEnvironment());
    }

    /// Loopback request counters must never inherit a caller's external proxy.
    pub fn initForTesting(self: *Reactor, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
        if (!@import("builtin").is_test) @compileError("test-only direct Reactor initialization");
        return self.initWithProxy(allocator, io, options, null);
    }

    fn initWithProxy(self: *Reactor, allocator: std.mem.Allocator, io: std.Io, options: Options, proxy: ?h2.Proxy) !void {
        if (options.inactivity_seconds <= 0) return error.InvalidTransportTimeout;
        const interval_ns = std.math.mul(u64, @intCast(options.inactivity_seconds), std.time.ns_per_s) catch
            return error.InvalidTransportTimeout;
        if (options.ca_file) |path| if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
            return error.InvalidProviderCaFile;
        self.* = .{
            .client = undefined,
            .endpoints = .initFill(null),
            .io = io,
            .observation = options.observation,
            .scratch_path = options.scratch_path,
            .budget = options.budget,
            .credentials = .{ .allocator = allocator, .io = io },
            .listing_endpoints = .initFill(null),
            .catalog_endpoint_error = null,
            .listings = .initFill(null),
        };
        var streams = options.capacity;
        for (options.listing_urls.values) |url| {
            streams = std.math.add(usize, streams, @intFromBool(url != null)) catch return error.TransportCapacityTooLarge;
        }
        try self.client.init(allocator, io, .{
            .stream_capacity = std.math.cast(u32, streams) orelse return error.TransportCapacityTooLarge,
            .inactivity_ns = interval_ns,
            .connect_timeout_ns = interval_ns,
            .trust = if (options.ca_file) |path| .{ .ca_file = path } else .system,
            .proxy = proxy,
        });
        errdefer self.client.deinit();
        for (options.endpoints.values, &self.endpoints.values) |url, *endpoint| {
            if (url) |value| endpoint.* = try self.client.addEndpoint(value);
        }
        for (options.listing_urls.values, &self.listing_endpoints.values, std.enums.values(ListingKind)) |url, *endpoint, kind| {
            if (url) |value| endpoint.* = self.client.addEndpoint(value) catch |err| {
                if (kind != .catalog) return err;
                self.catalog_endpoint_error = err;
                continue;
            };
        }
    }

    pub fn startListing(self: *Reactor, kind: ListingKind, fetch: *ListingFetch, fields: []const h2.Field, response: []u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.unlockWaking();
        std.debug.assert(self.listings.get(kind) == null);
        fetch.* = .{ .stream = .idle, .finished = false };
        try self.client.prepare(&fetch.stream, .{
            .endpoint = self.listing_endpoints.get(kind).?,
            .method = .get,
            .fields = fields,
            .body = .{ .bytes = "" },
            .sink = .{ .buffer = response },
        });
        self.listings.set(kind, fetch);
        self.client.launch(&fetch.stream);
    }

    pub fn finishedListing(self: *Reactor, kind: ListingKind) ?*ListingFetch {
        const fetch = self.listings.get(kind) orelse return null;
        return if (fetch.finished) fetch else null;
    }

    pub fn listingPending(self: *const Reactor) bool {
        for (self.listings.values) |fetch| if (fetch != null) return true;
        return false;
    }

    pub fn endListing(self: *Reactor, kind: ListingKind) void {
        const fetch = self.listings.get(kind) orelse return;
        self.mutex.lockUncancelable(self.io);
        defer self.unlockWaking();
        self.client.cancel(&fetch.stream);
        fetch.stream.deinit();
        self.listings.set(kind, null);
        if (kind == .catalog) self.client.retireConnections(self.listing_endpoints.get(kind).?);
    }

    pub fn deinit(self: *Reactor) void {
        std.debug.assert(self.credentials.head == null and !self.listingPending());
        self.client.deinit();
        self.* = undefined;
    }

    pub fn launch(self: *Reactor, transfer: *Transfer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.unlockWaking();
        if (transfer.timing) |timing| timing.begin(std.Io.Clock.awake.now(self.io));
        self.client.launch(&transfer.stream);
    }

    pub noinline fn serve(self: *Reactor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.stopping) {
            self.client.drive(self) catch |err| return self.fail(err);
            if (self.client.finishedCount() != 0) self.signalFinished();
            const armed = self.client.armWait(std.math.maxInt(u32));
            self.mutex.unlock(self.io);
            const blocked = armed.block();
            self.mutex.lockUncancelable(self.io);
            blocked catch |err| return self.fail(err);
        }
    }

    fn fail(self: *Reactor, err: h2.DriveError) void {
        self.failure = err;
        self.signalFinished();
    }

    fn signalFinished(self: *Reactor) void {
        if (self.wake) |wake| wake.set(self.io);
    }

    pub fn stop(self: *Reactor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.unlockWaking();
        self.stopping = true;
    }

    pub fn failed(self: *Reactor) ?h2.DriveError {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure;
    }

    fn unlockWaking(self: *Reactor) void {
        self.mutex.unlock(self.io);
        self.client.wake();
    }

    pub fn finishedCount(self: *Reactor) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.client.finishedCount();
    }

    pub fn hasConnections(self: *Reactor) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.client.hasConnections();
    }

    pub fn nextCompletion(self: *Reactor, fail_seal: bool) error{InvalidHttpEvidence}!?Completion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stream = next: while (self.client.nextFinished()) |stream| {
            for (self.listings.values) |listing| {
                if (listing) |fetch| if (stream == &fetch.stream) {
                    fetch.finished = true;
                    continue :next;
                };
            }
            break :next stream;
        } else return null;
        const transfer: *Transfer = @fieldParentPtr("stream", stream);
        var outcome = try transfer.outcome();
        switch (outcome) {
            .transport_finished => |evidence| if (evidence.disposition.retainsResponse()) {
                transfer.response.seal(self.io, fail_seal, stream.responseLength()) catch {
                    outcome = .{ .response_capture_failed = .seal_failed };
                };
            },
            else => {},
        }
        return .{ .transfer = transfer, .outcome = outcome, .queued_after = self.client.finishedCount() };
    }

    pub fn observe(self: *Reactor, stream: *h2.Stream, event: h2.Event) h2.Verdict {
        for (self.listings.values, std.enums.values(ListingKind)) |listing, kind| {
            if (listing) |fetch| if (stream == &fetch.stream) {
                if (kind == .catalog and event == .head and event.head.kind == .final) {
                    for (event.head.fields) |field| {
                        if (std.mem.eql(u8, field.name, "etag")) {
                            if (fetch.etag != null) return .refuse;
                            var etag: protocol.Bounded(512) = .{};
                            etag.set(field.value) catch return .refuse;
                            fetch.etag = etag;
                        }
                    }
                }
                return .accept;
            };
        }
        const transfer: *Transfer = @fieldParentPtr("stream", stream);
        if (event == .head or event == .body) {
            if (transfer.timing) |timing| timing.responseEvent(std.Io.Clock.awake.now(self.io));
        }
        switch (event) {
            .head => |head| {
                transfer.releaseCredential();
                transfer.headers.block(head.kind, head.status);
                const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
                for (head.fields) |field| {
                    transfer.headers.field(transfer.observe, self.observation.turn_state, field.name, field.value, now_seconds) catch |err| {
                        if (err == error.OutOfMemory) transfer.headers.local_failure = true;
                        return .refuse;
                    };
                }
                if (head.kind == .final and transfer.allowance == null) if (transfer.allowance_source) |source| {
                    var snapshot: AllowanceObservation = .{
                        .binding = source.binding,
                        .provider = source.provider,
                        .status = head.status,
                        .observed_at = now_seconds,
                    };
                    for (head.fields) |field| snapshot.field(transfer.observe, field.name, field.value);
                    transfer.allowance = snapshot;
                };
                return .accept;
            },
            .body => |length| {
                const next = std.math.add(u64, transfer.response.length, length) catch return .refuse;
                if (next > transfer.response.charged) {
                    if (!self.budget.allocate(next - transfer.response.charged)) return .refuse;
                    transfer.response.charged = next;
                }
                transfer.response.length = next;
                return .accept;
            },
            .body_retired => {
                transfer.retireRequest();
                return .accept;
            },
        }
    }
};

pub const ResponseCapture = struct {
    file: std.Io.File,
    readonly: ?std.Io.File,
    length: u64 = 0,
    charged: u64 = 0,
    workspace: []align(std.heap.page_size_min) u8 = &.{},

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        binding: attempt.AttemptBinding,
        fail_acquire: bool,
        fail_unlink: bool,
        retained: *?named_scratch.Owner,
        reserve_bytes: usize,
    ) !ResponseCapture {
        retained.* = null;
        if (fail_acquire) return error.InjectedResponseAcquireFailure;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        var name_buffer: [96]u8 = undefined;
        const name = try named_scratch.NumericName.response.format(
            &name_buffer,
            binding.operation_id,
            binding.attempt_ordinal,
        );
        const file = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        const readonly = scratch.openFile(io, name, .{}) catch |err| {
            retained.* = .init(io, file, null, name, budget, 0, .native);
            return err;
        };
        if (fail_unlink) {
            retained.* = .init(io, file, readonly, name, budget, 0, .injected_failure);
            return error.InjectedResponseUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = .init(io, file, readonly, name, budget, 0, .native);
            return err;
        };
        errdefer file.close(io);
        errdefer readonly.close(io);
        if (reserve_bytes != 0 and !budget.allocate(reserve_bytes)) return error.ResponseScratchExhausted;
        errdefer budget.release(reserve_bytes);
        if (reserve_bytes != 0) try file.setLength(io, reserve_bytes);
        const workspace = try pages.mapWritable(io, file, reserve_bytes);
        return .{ .file = file, .readonly = readonly, .charged = reserve_bytes, .workspace = workspace };
    }

    fn sink(self: *const ResponseCapture, fail_write: bool) h2.Sink {
        return .{ .file = if (fail_write) self.readonly.?.handle else self.file.handle };
    }

    pub fn seal(self: *ResponseCapture, io: std.Io, fail: bool, written: u64) !void {
        std.debug.assert(self.readonly != null);
        if (fail) return error.InjectedResponseSealFailure;
        if (self.length != written or self.charged != @max(@as(u64, self.workspace.len), written) or
            try self.file.length(io) != self.charged) return error.ResponseSealFailed;
        if (self.workspace.len == 0) {
            self.file.close(io);
            self.file = self.readonly.?;
        } else {
            // A reserved capture becomes its settlement workspace after parsing.
            // Keep the existing writable alias; no extra handle survives.
            self.readonly.?.close(io);
        }
        self.readonly = null;
    }

    pub fn deinit(self: *ResponseCapture, io: std.Io, budget: ScratchBudget) void {
        if (self.workspace.len != 0) pages.unmapReadOnly(self.workspace);
        self.file.close(io);
        if (self.readonly) |readonly| readonly.close(io);
        budget.release(self.charged);
        self.* = undefined;
    }
};

pub const SealedResponse = struct {
    io: std.Io,
    file: std.Io.File,
    length: u64,
    charged: u64,
    budget: ScratchBudget,
    workspace: []align(std.heap.page_size_min) u8 = &.{},

    pub fn state(self: *const SealedResponse, comptime T: type) *T {
        std.debug.assert(self.workspace.len >= @sizeOf(T));
        return @ptrCast(@alignCast(self.workspace.ptr));
    }

    pub fn deinit(self: *SealedResponse) void {
        if (self.workspace.len != 0) pages.unmapReadOnly(self.workspace);
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

const HeaderContext = struct {
    observed: Observed = .{},
    turn_state: ?TurnStateKey = null,
    turn_state_seen: bool = false,
    successful_block: bool = false,
    retry_after_ms: u64 = 0,
    retry_after_deadline_ms: i64 = 0,
    has_retry_after_ms: bool = false,
    has_retry_after_deadline_ms: bool = false,
    local_failure: bool = false,

    fn retryAfterMs(self: *const HeaderContext) ?u64 {
        return if (self.has_retry_after_ms) self.retry_after_ms else null;
    }

    fn retryAfterDeadlineMs(self: *const HeaderContext) ?i64 {
        return if (self.has_retry_after_deadline_ms) self.retry_after_deadline_ms else null;
    }

    fn block(self: *HeaderContext, kind: @FieldType(h2.Head, "kind"), status: u16) void {
        self.successful_block = kind == .final and status >= 200 and status < 300;
    }

    fn field(self: *HeaderContext, names: *const codec_abi.ObservedHeaders, turn_state_sink: ?TurnStateSink, name: []const u8, raw: []const u8, now_seconds: i64) error{ InvalidValue, OutOfMemory }!void {
        const value = std.mem.trim(u8, raw, " \t");
        // h2 delivers field names lowercase (RFC 9113 8.2.1, enforced by nghttp2).
        if (std.mem.eql(u8, name, "retry-after")) {
            if (transport_policy.parseRetryAfter(value, now_seconds)) |constraint| switch (constraint) {
                .delay_ms => |delay| {
                    self.retry_after_ms = @max(self.retry_after_ms, delay);
                    self.has_retry_after_ms = true;
                },
                .deadline_ms => |deadline| {
                    self.retry_after_deadline_ms = @max(self.retry_after_deadline_ms, deadline);
                    self.has_retry_after_deadline_ms = true;
                },
            };
            return;
        }
        if (names.turn_state.len != 0 and std.mem.eql(u8, name, names.turn_state)) {
            if (!self.successful_block or self.turn_state_seen) return;
            self.turn_state_seen = true;
            if (value.len == 0 or value.len > max_turn_state_bytes) return;
            for (value) |byte| if (byte < 0x20 or byte > 0x7e) return;
            if (turn_state_sink) |sink| if (self.turn_state) |key| sink.capture(sink.context, key, value);
            return;
        }
        const observed: Observed.Name = if (names.request_id.len != 0 and std.mem.eql(u8, name, names.request_id))
            .request_id
        else if (names.model.len != 0 and std.mem.eql(u8, name, names.model))
            .model
        else if (names.alternate_model.len != 0 and std.mem.eql(u8, name, names.alternate_model))
            .alternate_model
        else
            return;
        try self.observed.put(observed, value);
    }
};

const Observed = struct {
    const Name = enum { request_id, model, alternate_model };
    const capacity = std.EnumArray(Name, usize).init(.{
        .request_id = 256,
        .model = protocol.max_model_bytes,
        .alternate_model = protocol.max_model_bytes,
    });
    const Span = struct { start: u16 = 0, len: u16 = 0 };

    bytes: []u8 = &.{},
    spans: std.EnumArray(Name, Span) = .initFill(.{}),

    fn get(self: *const Observed, name: Name) []const u8 {
        const span = self.spans.get(name);
        return self.bytes[span.start..][0..span.len];
    }

    fn put(self: *Observed, name: Name, value: []const u8) error{ InvalidValue, OutOfMemory }!void {
        if (value.len == 0 or value.len > capacity.get(name) or !std.unicode.utf8ValidateSlice(value)) return error.InvalidValue;
        if (self.spans.get(name).len != 0)
            return if (std.mem.eql(u8, self.get(name), value)) {} else error.InvalidValue;
        const start = self.bytes.len;
        self.bytes = try std.heap.c_allocator.realloc(self.bytes, start + value.len);
        @memcpy(self.bytes[start..], value);
        self.spans.set(name, .{ .start = @intCast(start), .len = @intCast(value.len) });
    }

    fn deinit(self: *Observed) void {
        std.heap.c_allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const AttemptTiming = @import("model_timing.zig").Attempt;

pub const Transfer = struct {
    timing: ?*AttemptTiming = null,
    stream: h2.Stream,
    reactor: *Reactor,
    /// The observed header names of the codec this Transfer was prepared with: a pointer
    /// into the codec's static manifest, not a copy.
    observe: *const codec_abi.ObservedHeaders,
    request: RetainedRequest,
    request_open: bool = true,
    response: ResponseCapture,
    response_owned: bool = true,
    headers: HeaderContext,
    credential: ?*SharedCredential,
    allowance_source: ?AllowanceSource = null,
    allowance: ?AllowanceObservation = null,

    pub const StartOptions = struct {
        fields: []const h2.Field = &.{},
        credential: ?*SharedCredential = null,
        routing: ?Routing = null,
        faults: Faults = .{},
        timing: ?*AttemptTiming = null,
        response_workspace_bytes: usize = 0,
        observe_allowance: bool = false,
    };

    const RetainedRequest = struct {
        file: std.Io.File,
        charged: u64,
        structured_output: bool,
        codec: protocol.Codec,
    };

    pub fn start(
        self: *Transfer,
        reactor: *Reactor,
        request: *const PreparedRequest,
        binding: attempt.AttemptBinding,
        options: StartOptions,
        retained_response: *?named_scratch.Owner,
    ) !void {
        errdefer if (options.credential) |shared| reactor.credentials.release(shared);
        var count = 1 + request.headers.count + options.fields.len;
        if (count + @intFromBool(options.routing != null) > h2.max_fields) return error.TooManyProviderHeaders;
        var fields: [h2.max_fields]h2.Field = undefined;
        fields[0] = content_type;
        for (fields[1..][0..request.headers.count], request.headers.names[0..request.headers.count], 0..) |*field, name, index|
            field.* = .{ .name = codecs.headerName(request.codec, name), .value = request.headers.value(index) };
        @memcpy(fields[1 + request.headers.count ..][0..options.fields.len], options.fields);
        const response = ResponseCapture.init(
            reactor.io,
            reactor.scratch_path,
            reactor.budget,
            binding,
            options.faults.response_acquire,
            options.faults.response_unlink,
            retained_response,
            options.response_workspace_bytes,
        ) catch return error.ResponseCaptureAcquisitionFailed;
        self.* = .{
            .stream = .idle,
            .reactor = reactor,
            .observe = &codecs.manifest(request.codec).observe,
            .request = .{ .file = request.file, .charged = request.charged, .structured_output = request.structured_output, .codec = request.codec },
            .response = response,
            .headers = .{},
            .credential = options.credential,
            .timing = options.timing,
            .allowance_source = if (options.observe_allowance and (request.provider == .codex or request.provider == .chatgpt))
                .{ .binding = binding, .provider = request.provider }
            else
                null,
        };
        errdefer {
            self.response.deinit(reactor.io, reactor.budget);
            self.* = undefined;
        }
        reactor.mutex.lockUncancelable(reactor.io);
        defer reactor.mutex.unlock(reactor.io);
        if (options.routing) |routing| if (reactor.observation.turn_state) |table| {
            const replay = table.replay(table.context, request.provider, routing.turn_id, routing.owner);
            self.headers.turn_state = .{ .provider = request.provider, .turn_id = routing.turn_id, .epoch = replay.epoch };
            const name = self.observe.turn_state;
            if (name.len != 0 and replay.value.len != 0) {
                fields[count] = .{ .name = name, .value = replay.value };
                count += 1;
            }
        };
        try reactor.client.prepare(&self.stream, .{
            .endpoint = reactor.endpoints.get(request.provider).?,
            .fields = fields[0..count],
            .body = .{ .file = .{
                .handle = request.file.handle,
                .length = request.length + @intFromBool(options.faults.request_read),
            } },
            .sink = self.response.sink(options.faults.response_write),
        });
    }

    pub fn deinit(self: *Transfer) void {
        const reactor = self.reactor;
        reactor.mutex.lockUncancelable(reactor.io);
        defer reactor.unlockWaking();
        reactor.client.cancel(&self.stream);
        self.stream.deinit();
        self.retireRequest();
        self.headers.observed.deinit();
        if (self.response_owned) self.response.deinit(reactor.io, reactor.budget);
        self.releaseCredential();
        self.* = undefined;
    }

    fn releaseCredential(self: *Transfer) void {
        const shared = self.credential orelse return;
        self.credential = null;
        self.reactor.credentials.release(shared);
    }

    fn retireRequest(self: *Transfer) void {
        if (!self.request_open) return;
        self.request_open = false;
        self.request.file.close(self.reactor.io);
        self.reactor.budget.release(self.request.charged);
    }

    fn outcome(self: *const Transfer) error{InvalidHttpEvidence}!transport_policy.TransferOutcome {
        const end = self.stream.end().?;
        return transport_policy.outcome(.{
            .cause = policyCause(end.cause),
            .status = self.stream.status(),
            .headers_local_failure = self.headers.local_failure,
            .retry_after_ms = self.headers.retryAfterMs(),
            .retry_after_deadline_ms = self.headers.retryAfterDeadlineMs(),
        });
    }

    pub fn takeResponse(self: *Transfer) SealedResponse {
        std.debug.assert(self.response_owned);
        std.debug.assert(self.response.readonly == null);
        self.response_owned = false;
        return .{
            .io = self.reactor.io,
            .file = self.response.file,
            .length = self.response.length,
            .charged = self.response.charged,
            .budget = self.reactor.budget,
            .workspace = self.response.workspace,
        };
    }

    pub fn partialResponse(self: *const Transfer) struct { file: std.Io.File, length: u64 } {
        std.debug.assert(self.response_owned);
        return .{ .file = self.response.file, .length = self.stream.responseLength() };
    }

    pub fn requestId(self: *const Transfer) []const u8 {
        return self.headers.observed.get(.request_id);
    }

    pub fn protocolObservation(self: *const Transfer) ProtocolObservation {
        return .{
            .new_connections = @intFromBool(self.stream.openedConnection()),
            .replays = self.stream.replays(),
        };
    }

    pub fn observedModel(self: *const Transfer) []const u8 {
        return self.headers.observed.get(.model);
    }

    pub fn observedAlternateModel(self: *const Transfer) []const u8 {
        return self.headers.observed.get(.alternate_model);
    }

    pub fn hasStructuredOutput(self: *const Transfer) bool {
        return self.request.structured_output;
    }

    pub fn codec(self: *const Transfer) protocol.Codec {
        return self.request.codec;
    }
};

fn policyCause(cause: h2.Cause) transport_policy.Cause {
    return switch (cause) {
        inline else => |tag| @field(transport_policy.Cause, @tagName(tag)),
    };
}

comptime {
    for (std.meta.fieldNames(transport_policy.Cause)) |name| _ = @field(h2.Cause, name);
}

pub const validateEndpoint = @import("endpoint_value.zig").validateEndpoint;

test "idle reactor reports zero finished transfers and no completion" {
    var used: std.atomic.Value(u64) = .init(0);
    var reactor: Reactor = undefined;
    try reactor.init(std.testing.allocator, std.testing.io, .{
        .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null, .chatgpt = null }),
        .capacity = 1,
        .inactivity_seconds = 1,
        .scratch_path = "/nonexistent",
        .budget = .{ .used = &used, .limit = 1 },
    });
    defer reactor.deinit();
    const transport = try std.Thread.spawn(.{}, Reactor.serve, .{&reactor});
    try std.testing.expectEqual(@as(usize, 0), reactor.finishedCount());
    try std.testing.expectEqual(@as(?Completion, null), try reactor.nextCompletion(false));
    reactor.stop();
    transport.join();
    try std.testing.expectEqual(@as(?h2.DriveError, null), reactor.failed());
}

test "Reactor registers every provider and independent listing subset without endpoint exhaustion" {
    const request_urls = [_][]const u8{
        "http://127.0.0.1:1/codex/responses",
        "http://127.0.0.1:2/openai/responses",
        "http://127.0.0.1:3/chatgpt/responses",
    };
    const listing_urls = [_][]const u8{
        "http://127.0.0.1:4/catalog",
        "http://127.0.0.1:5/openai/models",
        "http://127.0.0.1:6/chatgpt/models",
    };
    for (0..8) |served_mask| for (0..8) |listing_mask| {
        var used: std.atomic.Value(u64) = .init(0);
        var reactor: Reactor = undefined;
        var options: Options = .{
            .endpoints = .initFill(null),
            .capacity = 1,
            .inactivity_seconds = 1,
            .scratch_path = "/nonexistent",
            .budget = .{ .used = &used, .limit = 1 },
        };
        for (&options.endpoints.values, request_urls, 0..) |*url, value, bit| {
            if (served_mask & (@as(usize, 1) << @intCast(bit)) != 0) url.* = value;
        }
        for (&options.listing_urls.values, listing_urls, 0..) |*url, value, bit| {
            if (listing_mask & (@as(usize, 1) << @intCast(bit)) != 0) url.* = value;
        }
        try reactor.init(std.testing.allocator, std.testing.io, options);
        defer reactor.deinit();
        try std.testing.expectEqual(@as(?h2.EndpointError, null), reactor.catalog_endpoint_error);
        for (reactor.endpoints.values, 0..) |endpoint, bit| {
            try std.testing.expectEqual(served_mask & (@as(usize, 1) << @intCast(bit)) != 0, endpoint != null);
        }
        for (reactor.listing_endpoints.values, 0..) |endpoint, bit| {
            try std.testing.expectEqual(listing_mask & (@as(usize, 1) << @intCast(bit)) != 0, endpoint != null);
        }
    };
}

test "catalog endpoint setup failure leaves HTTP provider and listing usable" {
    var used: std.atomic.Value(u64) = .init(0);
    var reactor: Reactor = undefined;
    const options: Options = .{
        .endpoints = .init(.{ .codex = null, .openai = "http://127.0.0.1:1/responses", .chatgpt = null }),
        .ca_file = "/nonexistent/rui-catalog-ca.pem",
        .capacity = 1,
        .inactivity_seconds = 1,
        .scratch_path = "/nonexistent",
        .budget = .{ .used = &used, .limit = 1 },
        .listing_urls = listing_urls: {
            var urls: std.EnumArray(ListingKind, ?[]const u8) = .initFill(null);
            urls.set(.openai, "http://127.0.0.1:1/models");
            urls.set(.catalog, "https://models.dev/api.json");
            break :listing_urls urls;
        },
    };
    try reactor.init(std.testing.allocator, std.testing.io, options);
    {
        defer reactor.deinit();
        try std.testing.expectEqual(error.InvalidCaFile, reactor.catalog_endpoint_error.?);
        try std.testing.expect(reactor.endpoints.get(.openai) != null);
        try std.testing.expect(reactor.listing_endpoints.get(.catalog) == null);
        var fetch: ListingFetch = undefined;
        var response: [1]u8 = undefined;
        try reactor.startListing(.openai, &fetch, &.{}, &response);
        defer reactor.endListing(.openai);
        try std.testing.expectEqual(@as(?Completion, null), try reactor.nextCompletion(false));
    }
    var required = options;
    required.endpoints.set(.openai, "https://example.com/responses");
    try std.testing.expectError(error.InvalidCaFile, reactor.init(std.testing.allocator, std.testing.io, required));
}

test "Transfers presenting one credential share one copy, freed with the last use" {
    var credentials: Credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const first = try credentials.share("token-a", "account");
    const second = try credentials.share("token-a", "account");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("Bearer token-a", first.authorization());
    try std.testing.expectEqualStrings("account", first.accountId());
    const refreshed = try credentials.share("token-b", "account");
    const other = try credentials.share("token-a", "other");
    try std.testing.expect(refreshed != first and other != first and other != refreshed);
    try std.testing.expectEqualStrings("Bearer token-b", refreshed.authorization());
    credentials.release(first);
    try std.testing.expectEqual(first, try credentials.share("token-a", "account"));
    credentials.release(first);
    credentials.release(refreshed);
    credentials.release(second);
    credentials.release(other);
    try std.testing.expectEqual(@as(?*SharedCredential, null), credentials.head);
}

test "a Transfer's credential use ends at its first response head, once" {
    var reactor: Reactor = undefined;
    reactor.io = std.testing.io;
    reactor.observation = .{};
    reactor.listings = .initFill(null);
    reactor.credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var transfer: Transfer = undefined;
    transfer.reactor = &reactor;
    transfer.allowance_source = null;
    transfer.allowance = null;
    var timing: AttemptTiming = .{};
    transfer.timing = &timing;
    transfer.headers = .{};
    transfer.credential = try reactor.credentials.share("token", "account");
    const sibling = try reactor.credentials.share("token", "account");
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&transfer.stream, .{ .head = .{ .kind = .interim, .status = 100, .fields = &.{} } }));
    try std.testing.expectEqual(@as(?*SharedCredential, null), transfer.credential);
    try std.testing.expectEqual(@as(u32, 1), sibling.users);
    _ = reactor.observe(&transfer.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &.{} } });
    transfer.releaseCredential();
    try std.testing.expectEqual(@as(u32, 1), sibling.users);
    reactor.credentials.release(sibling);
    try std.testing.expectEqual(@as(?*SharedCredential, null), reactor.credentials.head);
}

test "a Transfer that fails to start releases its credential use" {
    var reactor: Reactor = undefined;
    reactor.credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var transfer: Transfer = undefined;
    var retained: ?named_scratch.Owner = null;
    var request: PreparedRequest = undefined;
    request.provider = .codex;
    request.codec = .@"openai-responses/1";
    const settings: codec_abi.Settings = .{ .effort = null, .session_affinity = @splat(0), .model_length = 0 };
    codecs.requestHeaders(request.codec, &settings, &request.headers);
    const too_many: [h2.max_fields - 1]h2.Field = @splat(.{ .name = "x-field", .value = "" });
    try std.testing.expectError(error.TooManyProviderHeaders, transfer.start(&reactor, &request, undefined, .{
        .fields = &too_many,
        .credential = try reactor.credentials.share("token", "account"),
    }, &retained));
    try std.testing.expectEqual(@as(?*SharedCredential, null), reactor.credentials.head);
}

test "scratch reservation is bounded and releases exact charge" {
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 10 };
    try std.testing.expect(budget.charge(7));
    try std.testing.expect(!budget.charge(4));
    budget.release(7);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

fn observeLines(context: *HeaderContext, names: *const codec_abi.ObservedHeaders, sink: ?TurnStateSink, lines: []const []const u8) !void {
    for (lines) |line| {
        if (std.mem.startsWith(u8, line, ":status ")) {
            const status = try std.fmt.parseInt(u16, line[":status ".len..], 10);
            context.block(if (status < 200) .interim else .final, status);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        try context.field(names, sink, line[0..colon], line[colon + 1 ..], 1_700_000_000);
    }
}

test "duplicate Retry-After headers retain both independent constraints" {
    var context: HeaderContext = .{};
    try observeLines(&context, &.{}, null, &.{
        "retry-after: 12",
        "retry-after: Tue, 14 Nov 2023 22:13:21 GMT",
        "retry-after: 3",
        "retry-after: 9223372036854775",
        "retry-after: Tue, 14 Nov 2023 22:13:19 GMT",
        "retry-after: invalid",
    });
    try std.testing.expectEqual(@as(?u64, 12_000), context.retryAfterMs());
    try std.testing.expectEqual(@as(?i64, 1_700_000_001_000), context.retryAfterDeadlineMs());
}

test "response observations use caller-selected names and reject contradictions" {
    const names: codec_abi.ObservedHeaders = .{
        .request_id = "correlation",
        .model = "served-model",
        .alternate_model = "other-model",
    };
    var context: HeaderContext = .{};
    defer context.observed.deinit();
    try observeLines(&context, &names, null, &.{ "openai-model: unrelated", "served-model: alpha", "other-model: beta", "correlation: ref-1" });
    try std.testing.expectEqualStrings("alpha", context.observed.get(.model));
    try std.testing.expectEqualStrings("beta", context.observed.get(.alternate_model));
    try std.testing.expectEqualStrings("ref-1", context.observed.get(.request_id));
    try observeLines(&context, &names, null, &.{"served-model: alpha"});
    try std.testing.expectError(error.InvalidValue, observeLines(&context, &names, null, &.{"served-model: gamma"}));
}

test "response observations keep their real length and reject empty, invalid UTF-8 or oversized values" {
    const names: codec_abi.ObservedHeaders = .{ .request_id = "correlation", .model = "served-model" };
    var context: HeaderContext = .{};
    defer context.observed.deinit();
    try observeLines(&context, &names, null, &.{":status 200"});
    try std.testing.expectEqual(@as(usize, 0), context.observed.bytes.len);
    try observeLines(&context, &names, null, &.{ "served-model: m", "correlation: " ++ @as([256]u8, @splat('r')), "served-model: m" });
    try std.testing.expectEqual(@as(usize, 257), context.observed.bytes.len);
    try std.testing.expectEqualStrings("m", context.observed.get(.model));
    try std.testing.expectEqualStrings(&@as([256]u8, @splat('r')), context.observed.get(.request_id));
    try std.testing.expectEqualStrings("", context.observed.get(.alternate_model));
    for ([_][]const u8{ "served-model: ", "served-model: caf\xc3", "served-model: " ++ @as([protocol.max_model_bytes + 1]u8, @splat('m')) }) |line| {
        var rejected: HeaderContext = .{};
        defer rejected.observed.deinit();
        try std.testing.expectError(error.InvalidValue, observeLines(&rejected, &names, null, &.{line}));
        try std.testing.expectEqual(@as(usize, 0), rejected.observed.bytes.len);
    }
}

test "turn state observation keeps only the first value of a successful final block" {
    const name = "x-codex-turn-state";
    const oversized = "x-codex-turn-state: " ++ @as([max_turn_state_bytes + 1]u8, @splat('v'));
    const exact = "x-codex-turn-state: " ++ @as([max_turn_state_bytes]u8, @splat('v'));
    const cases = [_]struct { lines: []const []const u8, expected: []const u8 }{
        .{ .lines = &.{ ":status 100", "x-codex-turn-state: interim", ":status 200", "x-codex-turn-state:  first value ", "x-codex-turn-state: second" }, .expected = "first value" },
        .{ .lines = &.{ ":status 503", "x-codex-turn-state: error" }, .expected = "" },
        .{ .lines = &.{ ":status 401", "x-codex-turn-state: denied" }, .expected = "" },
        .{ .lines = &.{"x-codex-turn-state: no-status"}, .expected = "" },
        .{ .lines = &.{ ":status 200", "x-codex-turn-state: ", "x-codex-turn-state: later" }, .expected = "" },
        .{ .lines = &.{ ":status 200", "x-codex-turn-state: a\x01b", "x-codex-turn-state: later" }, .expected = "" },
        .{ .lines = &.{ ":status 200", "x-codex-turn-state: caf\xc3\xa9" }, .expected = "" },
        .{ .lines = &.{ ":status 200", oversized }, .expected = "" },
        .{ .lines = &.{ ":status 200", exact }, .expected = &@as([max_turn_state_bytes]u8, @splat('v')) },
        .{ .lines = &.{ ":status 200", "x-codex-turn-states: prefix", "x-codex-turn-stat: prefix" }, .expected = "" },
    };
    for (cases) |case| {
        var record: TurnStateRecord = .{};
        const names: codec_abi.ObservedHeaders = .{ .turn_state = name };
        var context: HeaderContext = .{ .turn_state = .{ .provider = .openai, .turn_id = 7, .epoch = 3 } };
        try observeLines(&context, &names, record.sink(), case.lines);
        try std.testing.expectEqualStrings(case.expected, record.value.slice());
        try std.testing.expectEqual(@intFromBool(case.expected.len != 0), record.captures);
        if (record.captures != 0) try std.testing.expectEqual(TurnStateKey{ .provider = .openai, .turn_id = 7, .epoch = 3 }, record.key.?);
    }
    var record: TurnStateRecord = .{};
    const names: codec_abi.ObservedHeaders = .{ .turn_state = name };
    const key: TurnStateKey = .{ .provider = .codex, .turn_id = 1, .epoch = 1 };
    var trailers: HeaderContext = .{ .turn_state = key };
    trailers.block(.final, 200);
    trailers.block(.trailers, 0);
    try trailers.field(&names, record.sink(), name, "late", 0);
    try std.testing.expectEqual(@as(usize, 0), record.captures);
    const unnamed: codec_abi.ObservedHeaders = .{};
    var unnamed_context: HeaderContext = .{ .turn_state = key };
    try observeLines(&unnamed_context, &unnamed, record.sink(), &.{ ":status 200", "x-codex-turn-state: value" });
    try std.testing.expectEqual(@as(usize, 0), record.captures);
    var unkeyed: HeaderContext = .{};
    try observeLines(&unkeyed, &names, record.sink(), &.{ ":status 200", "x-codex-turn-state: value" });
    try std.testing.expectEqual(@as(usize, 0), record.captures);
}

const TurnStateRecord = struct {
    value: protocol.Bounded(max_turn_state_bytes) = .{},
    key: ?TurnStateKey = null,
    captures: usize = 0,

    fn sink(self: *TurnStateRecord) TurnStateSink {
        return .{ .context = self, .capture = capture, .replay = replay };
    }

    fn replay(_: *anyopaque, _: protocol.Provider, _: u64, _: RoutingOwner) TurnStateSink.Replay {
        unreachable;
    }

    fn capture(context: *anyopaque, key: TurnStateKey, value: []const u8) void {
        const self: *TurnStateRecord = @ptrCast(@alignCast(context));
        self.captures += 1;
        self.key = key;
        self.value.set(value) catch unreachable;
    }
};

test "each live-list provider has its own listing beside the catalog's" {
    var kinds: usize = 0;
    for (std.enums.values(protocol.Provider)) |served| {
        const live = served.facts().model_list == .live;
        try std.testing.expectEqual(live, providerListing(served) != null);
        if (providerListing(served)) |kind| {
            try std.testing.expectEqual(served, listedProvider(kind).?);
            kinds += 1;
        }
    }
    try std.testing.expectEqual(@as(?protocol.Provider, null), listedProvider(.catalog));
    try std.testing.expectEqual(kinds + 1, std.enums.values(ListingKind).len);
}

test "catalog listing captures a bounded ETag and rejects duplicates without observing provider headers" {
    var reactor: Reactor = undefined;
    reactor.listings = .initFill(null);
    var fetch: ListingFetch = .{ .stream = .idle, .finished = false };
    reactor.listings.set(.catalog, &fetch);
    const head: h2.Event = .{ .head = .{
        .kind = .final,
        .status = 200,
        .fields = &.{.{ .name = "etag", .value = "W/\"catalog\"" }},
    } };
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&fetch.stream, head));
    try std.testing.expectEqualStrings("W/\"catalog\"", fetch.etag.?.slice());
    try std.testing.expectEqual(h2.Verdict.refuse, reactor.observe(&fetch.stream, head));
    fetch.etag = null;
    const oversized: [513]u8 = @splat('x');
    try std.testing.expectEqual(h2.Verdict.refuse, reactor.observe(&fetch.stream, .{ .head = .{
        .kind = .final,
        .status = 200,
        .fields = &.{.{ .name = "etag", .value = &oversized }},
    } }));
    try std.testing.expect(fetch.etag == null);
    reactor.listings.set(.catalog, null);
    reactor.listings.set(.openai, &fetch);
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&fetch.stream, head));
    try std.testing.expect(fetch.etag == null);
}

test "model timings start at handoff and capture only the first HTTP response event on each retry" {
    const Clock = struct {
        var awake_ns: i96 = 0;

        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            if (clock == .awake) return .fromNanoseconds(awake_ns);
            return std.testing.io.vtable.now(userdata, clock);
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    var io = std.testing.io;
    io.vtable = &vtable;
    var used: std.atomic.Value(u64) = .init(0);
    var reactor: Reactor = undefined;
    try reactor.init(std.testing.allocator, io, .{
        .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null, .chatgpt = null }),
        .capacity = 1,
        .inactivity_seconds = 1,
        .scratch_path = "/nonexistent",
        .budget = .{ .used = &used, .limit = 0 },
    });
    defer reactor.deinit();
    var transfer: Transfer = undefined;
    transfer.stream = .idle;
    transfer.reactor = &reactor;
    transfer.allowance_source = null;
    transfer.allowance = null;
    var timing: AttemptTiming = .{};
    transfer.timing = &timing;
    transfer.headers = .{};
    transfer.credential = null;
    transfer.request_open = false;
    transfer.response.charged = 0;
    transfer.response.length = 0;
    var sink: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?u64, null), transfer.timing.?.elapsedMs(.fromNanoseconds(99)));
    for (0..4) |ordinal| {
        Clock.awake_ns = @as(i96, @intCast(ordinal + 1)) * std.time.ns_per_s;
        try reactor.client.prepare(&transfer.stream, .{
            .endpoint = reactor.endpoints.get(.codex).?,
            .fields = &.{},
            .body = .{ .bytes = "" },
            .sink = .{ .buffer = &sink },
        });
        defer {
            reactor.client.cancel(&transfer.stream);
            transfer.stream.deinit();
        }
        reactor.launch(&transfer);
        const sent_at = Clock.awake_ns;
        try std.testing.expectEqual(@as(i64, @intCast(@divTrunc(sent_at, std.time.ns_per_ms))), transfer.timing.?.sent_at_ms.load(.acquire));
        try std.testing.expectEqual(@as(?u64, null), transfer.timing.?.firstEventMs());
        _ = reactor.observe(&transfer.stream, .body_retired);
        try std.testing.expectEqual(@as(?u64, null), transfer.timing.?.firstEventMs());
        switch (ordinal) {
            0 => {
                Clock.awake_ns = sent_at + 5 * std.time.ns_per_ms;
                _ = reactor.observe(&transfer.stream, .{ .head = .{ .kind = .interim, .status = 100, .fields = &.{} } });
                Clock.awake_ns = sent_at + 9 * std.time.ns_per_ms;
                _ = reactor.observe(&transfer.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &.{} } });
                try std.testing.expectEqual(h2.Verdict.refuse, reactor.observe(&transfer.stream, .{ .body = 1 }));
                try std.testing.expectEqual(@as(?u64, 5), transfer.timing.?.firstEventMs());
            },
            1 => {
                Clock.awake_ns = sent_at + 7 * std.time.ns_per_ms;
                try std.testing.expectEqual(h2.Verdict.refuse, reactor.observe(&transfer.stream, .{ .body = 1 }));
                Clock.awake_ns = sent_at + 11 * std.time.ns_per_ms;
                _ = reactor.observe(&transfer.stream, .{ .head = .{ .kind = .final, .status = 503, .fields = &.{} } });
                try std.testing.expectEqual(@as(?u64, 7), transfer.timing.?.firstEventMs());
            },
            2 => {
                Clock.awake_ns = sent_at;
                _ = reactor.observe(&transfer.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &.{} } });
                Clock.awake_ns = sent_at + 3 * std.time.ns_per_ms;
                _ = reactor.observe(&transfer.stream, .{ .head = .{ .kind = .trailers, .status = 0, .fields = &.{} } });
                try std.testing.expectEqual(@as(?u64, 0), transfer.timing.?.firstEventMs());
            },
            else => try std.testing.expectEqual(@as(?u64, null), transfer.timing.?.firstEventMs()),
        }
        Clock.awake_ns = sent_at + 19 * std.time.ns_per_ms + 999_999;
        try std.testing.expectEqual(@as(?u64, 19), transfer.timing.?.elapsedMs(.fromNanoseconds(Clock.awake_ns)));
    }
}

test "response continuation reservation accounts for bodies below and above its extent" {
    for ([_]usize{ 0, 128 }) |reserve| for ([_]usize{ 0, 3, 200 }) |body_length| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root: [protocol.max_store_bytes]u8 = undefined;
        const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
        var used: std.atomic.Value(u64) = .init(17);
        const budget: ScratchBudget = .{ .used = &used, .limit = 217 };
        var retained: ?named_scratch.Owner = null;
        const capture = try ResponseCapture.init(std.testing.io, path, budget, .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 }, false, false, &retained, reserve);
        var reactor: Reactor = undefined;
        reactor.io = std.testing.io;
        reactor.budget = budget;
        reactor.listings = .initFill(null);
        var transfer: Transfer = .{ .stream = .idle, .reactor = &reactor, .observe = &.{}, .request = undefined, .response = capture, .headers = .{}, .credential = null };
        var owned = true;
        defer if (owned) transfer.response.deinit(std.testing.io, budget);
        try std.testing.expectEqual(@as(u64, 17 + reserve), used.load(.acquire));
        const body: [200]u8 = @splat('r');
        if (body_length != 0) {
            try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&transfer.stream, .{ .body = @intCast(body_length) }));
            try transfer.response.file.writePositionalAll(std.testing.io, body[0..body_length], 0);
        }
        try transfer.response.seal(std.testing.io, false, body_length);
        var sealed = transfer.takeResponse();
        owned = false;
        var sealed_owned = true;
        defer if (sealed_owned) sealed.deinit();
        try std.testing.expectEqual(@as(u64, body_length), sealed.length);
        try std.testing.expectEqual(@as(u64, @max(reserve, body_length)), sealed.charged);
        try std.testing.expectEqual(@as(u64, 17 + @max(reserve, body_length)), used.load(.acquire));
        const mapped = try pages.mapReadOnly(std.testing.io, sealed.file, sealed.length);
        try std.testing.expectEqualSlices(u8, body[0..body_length], mapped);
        pages.unmapReadOnly(mapped);
        if (reserve == 0) {
            try std.testing.expectError(error.NotOpenForWriting, sealed.file.writePositionalAll(std.testing.io, "x", 0));
        } else {
            const state = sealed.state([128]u8);
            state.* = @splat('s');
            try std.testing.expectEqual(@as(u64, 17 + @max(reserve, body_length)), used.load(.acquire));
        }
        sealed.deinit();
        sealed_owned = false;
        try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
    };
}

test "response continuation reservation fails before launch and cancellation returns every charge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [protocol.max_store_bytes]u8 = undefined;
    const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var used: std.atomic.Value(u64) = .init(17);
    const budget: ScratchBudget = .{ .used = &used, .limit = 144 };
    var retained: ?named_scratch.Owner = null;
    const binding: attempt.AttemptBinding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 };
    try std.testing.expectError(error.ResponseScratchExhausted, ResponseCapture.init(std.testing.io, path, budget, binding, false, false, &retained, 128));
    try std.testing.expect(retained == null);
    try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "response-1-1.tmp", .{}));
    const enough: ScratchBudget = .{ .used = &used, .limit = 145 };
    var capture = try ResponseCapture.init(std.testing.io, path, enough, binding, false, false, &retained, 128);
    try std.testing.expectEqual(@as(u64, 145), used.load(.acquire));
    capture.deinit(std.testing.io, enough);
    try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
    try std.testing.expectError(error.InjectedResponseUnlinkFailure, ResponseCapture.init(std.testing.io, path, enough, binding, false, true, &retained, 128));
    try std.testing.expect(retained != null);
    try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
    // The failed unlink predates reservation; the existing owner keeps both
    // aliases and the name until an explicit successful reclamation.
    retained.?.resources.?.removal = .native;
    _ = try retained.?.reclaim(path);
    try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
}

test "response continuation reservation rejects a mismatched semantic body length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [protocol.max_store_bytes]u8 = undefined;
    const path = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var used: std.atomic.Value(u64) = .init(17);
    const budget: ScratchBudget = .{ .used = &used, .limit = 145 };
    var retained: ?named_scratch.Owner = null;
    const capture = try ResponseCapture.init(std.testing.io, path, budget, .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 }, false, false, &retained, 128);
    var reactor: Reactor = undefined;
    reactor.io = std.testing.io;
    reactor.budget = budget;
    reactor.listings = .initFill(null);
    var transfer: Transfer = .{ .stream = .idle, .reactor = &reactor, .observe = &.{}, .request = undefined, .response = capture, .headers = .{}, .credential = null };
    defer transfer.response.deinit(std.testing.io, budget);
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&transfer.stream, .{ .body = 3 }));
    try transfer.response.file.writePositionalAll(std.testing.io, "abc", 0);
    for ([_]u64{ 2, 5 }) |reported| {
        try std.testing.expectError(error.ResponseSealFailed, transfer.response.seal(std.testing.io, false, reported));
        try std.testing.expectEqual(@as(u64, 3), transfer.response.length);
        try std.testing.expect(transfer.response.readonly != null);
        try std.testing.expectEqual(@as(u64, 145), used.load(.acquire));
    }
    try transfer.response.seal(std.testing.io, false, 3);
    try std.testing.expectEqual(@as(u64, 3), transfer.response.length);
    try std.testing.expectEqual(@as(u64, 128), transfer.response.charged);
}

test "CM-46 allowance final head stays bound to its issued attempt" {
    var reactor: Reactor = undefined;
    reactor.io = std.testing.io;
    reactor.observation = .{};
    reactor.listings = .initFill(null);
    reactor.credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var a: Transfer = undefined;
    var b: Transfer = undefined;
    for ([_]*Transfer{ &a, &b }) |transfer| {
        transfer.reactor = &reactor;
        transfer.timing = null;
        transfer.headers = .{};
        transfer.credential = null;
        transfer.observe = &codecs.manifest(.@"openai-responses/2").observe;
        transfer.allowance = null;
    }
    const other_names: codec_abi.ObservedHeaders = .{ .primary_used = "example-usage" };
    b.observe = &other_names;
    var issued: attempt.AttemptBinding = .{ .turn_id = 1, .operation_id = 11, .attempt_ordinal = 1 };
    a.allowance_source = .{ .binding = issued, .provider = .codex };
    issued.operation_id = 99;
    b.allowance_source = .{ .binding = .{ .turn_id = 2, .operation_id = 22, .attempt_ordinal = 2 }, .provider = .chatgpt };
    const fields = [_]h2.Field{
        .{ .name = "x-codex-primary-used-percent", .value = "25.5" },
        .{ .name = "x-codex-primary-window-minutes", .value = "300" },
        .{ .name = "x-codex-primary-reset-at", .value = "1700000000" },
        .{ .name = "x-codex-secondary-used-percent", .value = "101" },
        .{ .name = "x-codex-secondary-window-minutes", .value = "bad" },
        .{ .name = "x-codex-secondary-reset-at", .value = "7" },
        .{ .name = "x-codex-secondary-reset-at", .value = "8" },
        .{ .name = "unrelated", .value = "private" },
    };
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&a.stream, .{ .head = .{ .kind = .interim, .status = 100, .fields = &fields } }));
    try std.testing.expect(a.allowance == null);
    const other_fields = [_]h2.Field{ .{ .name = "x-codex-primary-used-percent", .value = "99" }, .{ .name = "example-usage", .value = "12" } };
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&b.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &other_fields } }));
    try std.testing.expectEqual(@as(f64, 12), b.allowance.?.primary.used.value);
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&a.stream, .{ .head = .{ .kind = .final, .status = 429, .fields = &fields } }));
    try std.testing.expectEqual(@as(u64, 11), a.allowance.?.binding.operation_id);
    try std.testing.expectEqual(protocol.Provider.codex, a.allowance.?.provider);
    try std.testing.expectEqual(@as(u64, 22), b.allowance.?.binding.operation_id);
    try std.testing.expectEqual(protocol.Provider.chatgpt, b.allowance.?.provider);
    try std.testing.expectEqual(@as(f64, 25.5), a.allowance.?.primary.used.value);
    try std.testing.expectEqual(@as(u64, 300), a.allowance.?.primary.minutes.value);
    try std.testing.expectEqual(@as(f64, 101), a.allowance.?.secondary.used.value);
    try std.testing.expect(a.allowance.?.secondary.minutes == .invalid);
    try std.testing.expect(a.allowance.?.secondary.reset_at == .invalid);
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&a.stream, .{ .head = .{ .kind = .trailers, .status = 0, .fields = &.{} } }));
    try std.testing.expectEqual(@as(u16, 429), a.allowance.?.status);
    const original_time = a.allowance.?.observed_at;
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&a.stream, .{ .head = .{ .kind = .final, .status = 201, .fields = &.{} } }));
    try std.testing.expectEqual(@as(u16, 429), a.allowance.?.status);
    try std.testing.expectEqual(original_time, a.allowance.?.observed_at);
    try std.testing.expectEqual(@as(f64, 25.5), a.allowance.?.primary.used.value);
    a.allowance_source = null;
    a.allowance = null;
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&a.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &fields } }));
    try std.testing.expect(a.allowance == null);
}

test "CM-47 allowance numeric fields reject invalid and conflicting values without refusing" {
    var reactor: Reactor = undefined;
    reactor.io = std.testing.io;
    reactor.observation = .{};
    reactor.listings = .initFill(null);
    reactor.credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var transfer: Transfer = undefined;
    transfer.reactor = &reactor;
    transfer.timing = null;
    transfer.headers = .{};
    transfer.credential = null;
    transfer.observe = &codecs.manifest(.@"openai-responses/2").observe;
    transfer.allowance = null;
    transfer.allowance_source = .{ .binding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 }, .provider = .codex };
    const fields = [_]h2.Field{
        .{ .name = "x-codex-primary-used-percent", .value = "NaN" },
        .{ .name = "x-codex-primary-used-percent", .value = "4" },
        .{ .name = "x-codex-primary-window-minutes", .value = "0" },
        .{ .name = "x-codex-primary-reset-at", .value = "-1" },
        .{ .name = "x-codex-secondary-used-percent", .value = "3" },
        .{ .name = "x-codex-secondary-used-percent", .value = "3" },
    };
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&transfer.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &fields } }));
    const observed = transfer.allowance.?;
    try std.testing.expect(observed.primary.used == .invalid and observed.primary.minutes == .invalid and observed.primary.reset_at == .invalid);
    try std.testing.expectEqual(@as(f64, 3), observed.secondary.used.value);
    try std.testing.expect(observed.secondary.minutes == .missing);
}

test "CM-48 allowance Transfer start freezes native attempt and defaults off" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 4096 };
    var reactor: Reactor = undefined;
    try reactor.initForTesting(std.testing.allocator, io, .{
        .endpoints = .init(.{
            .codex = "http://127.0.0.1:1/codex",
            .chatgpt = "http://127.0.0.1:1/chatgpt",
            .openai = "http://127.0.0.1:1/openai",
        }),
        .capacity = 1,
        .inactivity_seconds = 1,
        .scratch_path = root,
        .budget = budget,
    });
    defer reactor.deinit();
    const cases = [_]struct { served: protocol.Provider, enabled: bool, expected: bool }{
        .{ .served = .codex, .enabled = true, .expected = true },
        .{ .served = .chatgpt, .enabled = true, .expected = true },
        .{ .served = .openai, .enabled = true, .expected = false },
        .{ .served = .codex, .enabled = false, .expected = false },
    };
    for (cases, 0..) |case, index| {
        const file = try tmp.dir.createFile(io, "request", .{ .read = true });
        try file.writeStreamingAll(io, "{}");
        try std.testing.expect(budget.charge(2));
        var request: PreparedRequest = .{
            .file = file,
            .length = 2,
            .charged = 2,
            .structured_output = false,
            .provider = case.served,
            .codec = .@"openai-responses/1",
            .headers = .{ .count = 0 },
        };
        var binding: attempt.AttemptBinding = .{ .turn_id = 1, .operation_id = @intCast(index + 1), .attempt_ordinal = 1 };
        var transfer: Transfer = undefined;
        var retained: ?named_scratch.Owner = null;
        const options: Transfer.StartOptions = if (case.enabled) .{ .observe_allowance = true } else .{};
        try transfer.start(&reactor, &request, binding, options, &retained);
        defer transfer.deinit();
        request.provider = .openai;
        binding.operation_id = 999;
        const fields = [_]h2.Field{.{ .name = "x-codex-primary-used-percent", .value = "14" }};
        try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&transfer.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &fields } }));
        try std.testing.expectEqual(case.expected, transfer.allowance != null);
        if (transfer.allowance) |snapshot| {
            try std.testing.expectEqual(case.served, snapshot.provider);
            try std.testing.expectEqual(@as(u64, @intCast(index + 1)), snapshot.binding.operation_id);
            try std.testing.expectEqual(@as(f64, 14), snapshot.primary.used.value);
        }
    }
}

test "CM-49 allowance callback handles extreme and sparse final heads" {
    var reactor: Reactor = undefined;
    reactor.io = std.testing.io;
    reactor.observation = .{};
    reactor.listings = .initFill(null);
    reactor.credentials = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    const cases = [_]struct { value: []const u8, invalid: bool }{
        .{ .value = "-1", .invalid = true },
        .{ .value = "inf", .invalid = true },
        .{ .value = "1e9999", .invalid = true },
        .{ .value = "1.7976931348623157e308", .invalid = false },
    };
    for (cases) |case| {
        var transfer: Transfer = undefined;
        transfer.reactor = &reactor;
        transfer.timing = null;
        transfer.headers = .{};
        transfer.credential = null;
        transfer.observe = &codecs.manifest(.@"openai-responses/2").observe;
        transfer.allowance = null;
        transfer.allowance_source = .{ .binding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 }, .provider = .codex };
        const fields = [_]h2.Field{.{ .name = "x-codex-primary-used-percent", .value = case.value }};
        try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&transfer.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &fields } }));
        try std.testing.expectEqual(case.invalid, transfer.allowance.?.primary.used == .invalid);
        if (!case.invalid) try std.testing.expectEqual(std.math.floatMax(f64), transfer.allowance.?.primary.used.value);
    }
    var sparse: Transfer = undefined;
    sparse.reactor = &reactor;
    sparse.timing = null;
    sparse.headers = .{};
    sparse.credential = null;
    sparse.observe = &codecs.manifest(.@"openai-responses/2").observe;
    sparse.allowance = null;
    sparse.allowance_source = .{ .binding = .{ .turn_id = 1, .operation_id = 2, .attempt_ordinal = 1 }, .provider = .chatgpt };
    const reset = [_]h2.Field{.{ .name = "x-codex-primary-reset-at", .value = "42" }};
    try std.testing.expectEqual(h2.Verdict.accept, reactor.observe(&sparse.stream, .{ .head = .{ .kind = .final, .status = 200, .fields = &reset } }));
    try std.testing.expect(sparse.allowance.?.primary.used == .missing);
    try std.testing.expect(sparse.allowance.?.primary.minutes == .missing);
    try std.testing.expectEqual(@as(u64, 42), sparse.allowance.?.primary.reset_at.value);
    try std.testing.expect(sparse.allowance.?.secondary.used == .missing);
}
