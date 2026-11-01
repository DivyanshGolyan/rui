//! Rui's provider transport over its own HTTP/2 client. h2 is the
//! mechanism; this file is Rui's policy about it, and the only Rui file
//! that names h2's Client. What lives here and nowhere else:
//! - which response header fields are evidence (request id, models,
//!   Retry-After, turn state) and the rules that make a block invalid;
//! - the response capture: its scratch file, the budget charge per body
//!   event, and the seal; the request scratch file until h2 retires it;
//! - the fault hooks, each injected through a production path;
//! - mapping an h2 ending plus capture facts to `transport_policy`.
const std = @import("std");
const h2 = @import("h2");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");
const attempt = @import("attempt.zig");
const transport_policy = @import("transport_policy.zig");
const codec_abi = @import("codec_abi.zig");
const codecs = @import("codecs.zig");

pub const nghttp2_version = h2.nghttp2_version;
pub const openssl_version = h2.openssl_version;
pub const max_endpoint_bytes = h2.max_url_bytes;
/// The linked nghttp2 and OpenSSL are exactly the pinned versions.
pub const checkLibraries = h2.checkLibraries;

pub const ScratchBudget = protocol.ScratchBudget;

/// A sealed request. It may sit in an execution slot, so it keeps no io or
/// budget: its owner passes them when it releases the request.
pub const PreparedRequest = struct {
    file: std.Io.File,
    length: u64,
    charged: u64,
    structured_output: bool,
    /// The Session's provider, whose endpoint the request goes to.
    provider: protocol.Provider,
    /// The codec the Session pinned, which also classifies the answer's
    /// error body.
    codec: protocol.Codec,
    /// The codec's headers, which `Transfer.start` sends ahead of the
    /// Host's own and copies, so the Transfer does not keep them.
    headers: codec_abi.Headers,

    pub fn deinit(self: *PreparedRequest, io: std.Io, budget: ScratchBudget) void {
        self.file.close(io);
        budget.release(self.charged);
        self.* = undefined;
    }
};

/// The field every Transfer sends first, ahead of the codec's headers.
const content_type: h2.Field = .{ .name = "content-type", .value = "application/json", .borrowed = true };

/// The request fields the Host writes itself, which no codec header names:
/// `content_type` and model_adapter.Headers' credential, user-agent, FedRAMP
/// and turn-state fields.
pub const host_request_fields = [_][]const u8{ content_type.name, "authorization", "chatgpt-account-id", "user-agent", "x-openai-fedramp", "x-codex-turn-state" };

/// Whether the Host or h2 writes a field of this name itself.
pub fn hostField(name: []const u8) bool {
    for (host_request_fields ++ h2.owned_fields) |owned| {
        if (std.mem.eql(u8, name, owned)) return true;
    }
    return false;
}

pub const max_turn_state_bytes = 4096;

/// Takes a routing value while its header block is decoded, so a Transfer
/// keeps no copy. The value is borrowed for the call only.
pub const TurnStateSink = struct {
    context: *anyopaque,
    capture: *const fn (context: *anyopaque, key: TurnStateKey, value: []const u8) void,
};

/// The one transfer-specific part of turn-state delivery: its Turn and the
/// epoch selected at launch.
pub const TurnStateKey = struct {
    turn_id: u64 = 0,
    epoch: u64 = 0,
};

/// One per Reactor, so a Transfer holds a pointer instead of copies.
pub const HeaderObservation = struct {
    names: codec_abi.ObservedHeaders = .{},
    turn_state: ?TurnStateSink = null,
};

pub const Options = struct {
    /// Each served provider's endpoint.
    endpoints: std.EnumArray(protocol.Provider, ?[]const u8),
    ca_file: ?[]const u8 = null,
    /// The most Transfers alive at once.
    capacity: usize,
    inactivity_seconds: i64,
    observation: HeaderObservation = .{},
    scratch_path: []const u8,
    /// The scratch account every request and response of this Host charges.
    budget: ScratchBudget,
};

/// Per-launch fault hooks, each through a production path.
pub const Faults = struct {
    /// The body is declared one byte longer than its file, so h2's read
    /// comes up short and the stream ends `.body_failed`.
    request_read: bool = false,
    /// The capture file is never created, so the Transfer never starts.
    response_acquire: bool = false,
    /// The capture's name is not unlinked; its owner retains it for cleanup.
    response_unlink: bool = false,
    /// The sink is the read-only alias, so the first write fails.
    response_write: bool = false,
};

/// What `nextCompletion` hands the execution owner: the finished Transfer,
/// whose slot it finds by address, and its outcome, already sealed.
pub const Completion = struct {
    transfer: *Transfer,
    outcome: transport_policy.TransferOutcome,
    /// Finished transfers still waiting after this one.
    queued_after: usize,
};

/// Payload-free connection facts for the codex_transfer test trace.
pub const ProtocolObservation = struct {
    /// 1 when this stream was the first on a connection opened for it.
    new_connections: u1,
    replays: u8,
};

/// One copy of each credential's request fields, however many Transfers
/// present it. h2 borrows the copy (see `h2.Field.borrowed`), so a stream
/// holds two addresses for it instead of the bytes. A Transfer holds one use
/// from `start` until its first response head, when h2 is done with its
/// fields, or `deinit`; the last release wipes and frees the copy, so a
/// credential stays in memory no longer than a per-stream copy did.
pub const SharedCredential = struct {
    next: ?*SharedCredential,
    users: u32,
    authorization_len: u32,
    account_id_len: u32,

    const scheme = "Bearer ";

    /// The `authorization` value. Like `accountId`, borrowed until the
    /// caller's use is released, and invalid once the last one is.
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

/// At most one copy per distinct token and account in use, so a handful at
/// most (a refresh overlaps the old token's last Transfers); each lookup is
/// a scan of that short list.
pub const Credentials = struct {
    allocator: std.mem.Allocator,
    head: ?*SharedCredential = null,

    /// A use of the copy of these bytes, made now if none is live.
    pub fn share(self: *Credentials, access_token: []const u8, account_id: []const u8) error{OutOfMemory}!*SharedCredential {
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
    client: h2.Client,
    endpoints: std.EnumArray(protocol.Provider, ?h2.Endpoint),
    io: std.Io,
    observation: HeaderObservation,
    scratch_path: []const u8,
    budget: ScratchBudget,
    credentials: Credentials,

    /// In final storage: h2's Client is pointer-stable. Host startup has
    /// already run `checkLibraries` and `validateEndpoint`.
    pub fn init(self: *Reactor, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
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
            .credentials = .{ .allocator = allocator },
        };
        try self.client.init(allocator, io, .{
            .stream_capacity = std.math.cast(u32, options.capacity) orelse return error.TransportCapacityTooLarge,
            .inactivity_ns = interval_ns,
            .connect_timeout_ns = interval_ns,
            .trust = if (options.ca_file) |path| .{ .ca_file = path } else .system,
            .proxy = h2.proxyFromEnvironment(),
        });
        errdefer self.client.deinit();
        for (options.endpoints.values, &self.endpoints.values) |url, *endpoint| {
            if (url) |value| endpoint.* = try self.client.addEndpoint(value);
        }
    }

    pub fn deinit(self: *Reactor) void {
        std.debug.assert(self.credentials.head == null);
        self.client.deinit();
        self.* = undefined;
    }

    /// Infallible, and no request byte exists before it returns.
    pub fn launch(self: *Reactor, transfer: *Transfer) void {
        self.client.launch(&transfer.stream);
    }

    pub fn drive(self: *Reactor) !void {
        try self.client.drive(self);
    }

    pub fn wait(self: *Reactor, timeout_ms: u32) !void {
        try self.client.wait(timeout_ms);
    }

    pub fn finishedCount(self: *const Reactor) usize {
        return self.client.finishedCount();
    }

    /// A connection with no Transfer left still needs driving: the reset
    /// of a cancelled stream, PING answers and the idle close.
    pub fn hasConnections(self: *const Reactor) bool {
        return self.client.hasConnections();
    }

    /// At most one finished Transfer per call. A retained response is sealed
    /// here, synchronously, before its outcome is known to the caller.
    /// A finished stream with an impossible status is an error: the
    /// caller fences, since no settlement can be derived from it.
    pub fn nextCompletion(self: *Reactor, fail_seal: bool) error{InvalidHttpEvidence}!?Completion {
        const stream = self.client.nextFinished() orelse return null;
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

    /// h2's receiver, inside `drive` on the execution thread.
    pub fn observe(self: *Reactor, stream: *h2.Stream, event: h2.Event) h2.Verdict {
        const transfer: *Transfer = @fieldParentPtr("stream", stream);
        switch (event) {
            .head => |head| {
                transfer.releaseCredential();
                transfer.headers.block(head.kind, head.status);
                const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
                for (head.fields) |field| {
                    transfer.headers.field(&self.observation, field.name, field.value, now_seconds) catch |err| {
                        if (err == error.OutOfMemory) transfer.headers.local_failure = true;
                        return .refuse;
                    };
                }
                return .accept;
            },
            .body => |length| {
                // A refusal here is the only way a Rui stream ends
                // `.sink_refused`, so that cause means scratch exhausted.
                if (!self.budget.allocate(length)) return .refuse;
                transfer.response.charged += length;
                return .accept;
            },
            .body_retired => {
                transfer.retireRequest();
                return .accept;
            },
        }
    }
};

/// A response being captured in its Transfer's slot. Like PreparedRequest
/// it keeps no io or budget; its Transfer's Reactor holds both.
pub const ResponseCapture = struct {
    file: std.Io.File,
    readonly: ?std.Io.File,
    length: u64 = 0,
    /// Bytes charged by accepted body events, so a failed write's charge is
    /// still released.
    charged: u64 = 0,
    sealed: bool = false,

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        binding: attempt.AttemptBinding,
        fail_acquire: bool,
        fail_unlink: bool,
        retained: *?named_scratch.Owner,
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
        return .{ .file = file, .readonly = readonly };
    }

    /// The sink h2 writes, positionally at the response length.
    fn sink(self: *const ResponseCapture, fail_write: bool) h2.Sink {
        return .{ .file = if (fail_write) self.readonly.?.handle else self.file.handle };
    }

    /// Check the length h2 wrote, then keep only the read-only alias.
    pub fn seal(self: *ResponseCapture, io: std.Io, fail: bool, written: u64) !void {
        std.debug.assert(!self.sealed);
        self.length = written;
        if (fail) return error.InjectedResponseSealFailure;
        if (try self.file.length(io) != written) return error.ResponseSealFailed;
        const readonly = self.readonly orelse return error.ResponseSealFailed;
        self.file.close(io);
        self.file = readonly;
        self.readonly = null;
        self.sealed = true;
    }

    pub fn deinit(self: *ResponseCapture, io: std.Io, budget: ScratchBudget) void {
        self.file.close(io);
        if (self.readonly) |readonly| readonly.close(io);
        budget.release(self.charged);
        self.* = undefined;
    }
};

/// A sealed response moved out of its Transfer. It lives on its completing
/// owner's stack, so it keeps the io and budget that release it.
pub const SealedResponse = struct {
    io: std.Io,
    file: std.Io.File,
    length: u64,
    charged: u64,
    budget: ScratchBudget,

    pub fn deinit(self: *SealedResponse) void {
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

/// The response header rules, applied to each decoded block in turn. The
/// Reactor's one HeaderObservation comes with each field, so no Transfer
/// keeps a copy of its address.
const HeaderContext = struct {
    observed: Observed = .{},
    /// Where the observation's sink files the first caller-named routing
    /// value of a successful final block. A routing hint never fails the
    /// transfer: an unusable first value is dropped, and later values are
    /// ignored.
    turn_state: TurnStateKey = .{},
    turn_state_seen: bool = false,
    successful_block: bool = false,
    /// The largest Retry-After of each form, valid once its flag is set;
    /// flags rather than optionals keep the pair at 16 bytes per Transfer.
    retry_after_ms: u64 = 0,
    retry_after_deadline_ms: i64 = 0,
    has_retry_after_ms: bool = false,
    has_retry_after_deadline_ms: bool = false,
    /// A refused block was refused for want of memory, not for its values.
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

    /// An error refuses the block: an invalid value, or no memory for it.
    fn field(self: *HeaderContext, observation: *const HeaderObservation, name: []const u8, raw: []const u8, now_seconds: i64) error{ InvalidValue, OutOfMemory }!void {
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
        const names = &observation.names;
        if (names.turn_state.len != 0 and std.mem.eql(u8, name, names.turn_state)) {
            if (!self.successful_block or self.turn_state_seen) return;
            self.turn_state_seen = true;
            if (value.len == 0 or value.len > max_turn_state_bytes) return;
            for (value) |byte| if (byte < 0x20 or byte > 0x7e) return;
            if (observation.turn_state) |sink| sink.capture(sink.context, self.turn_state, value);
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

/// The caller-named response values, each at its real length, back to back
/// in one buffer the Transfer owns. A transfer whose headers have not
/// arrived owns none.
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

    /// A value is non-empty UTF-8 within its capacity, and a repeated name
    /// must repeat its value.
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

/// Embedded in an execution slot and built there: h2 holds the stream's
/// address from launch until `nextCompletion` or `cancel`.
pub const Transfer = struct {
    stream: h2.Stream,
    reactor: *Reactor,
    request: RetainedRequest,
    /// Until h2 retires the request body or the Transfer ends.
    request_open: bool = true,
    response: ResponseCapture,
    response_owned: bool = true,
    headers: HeaderContext,
    credential: ?*SharedCredential,

    pub const StartOptions = struct {
        /// Lowercase names. Borrowed until `start` returns, since h2 copies
        /// them, except a borrowed field, which must be a literal or bytes
        /// of `credential`.
        fields: []const h2.Field = &.{},
        /// A use of the Reactor's `credentials`, which the Transfer releases:
        /// at its first response head, in `deinit`, or in `start` when it
        /// fails.
        credential: ?*SharedCredential = null,
        turn_state: TurnStateKey = .{},
        faults: Faults = .{},
    };

    /// What a Transfer keeps of its request.
    const RetainedRequest = struct {
        file: std.Io.File,
        charged: u64,
        structured_output: bool,
        codec: protocol.Codec,
    };

    /// Opens the response capture, then prepares the stream with
    /// `content-type: application/json`, the request's codec headers and
    /// the options' fields, in that order. Takes the request's file and
    /// charge. Touches no socket; `Reactor.launch` is the handoff. Unlink
    /// failure still hands back the named owner through
    /// `retained_response`.
    pub fn start(
        self: *Transfer,
        reactor: *Reactor,
        request: *const PreparedRequest,
        binding: attempt.AttemptBinding,
        options: StartOptions,
        retained_response: *?named_scratch.Owner,
    ) !void {
        errdefer if (options.credential) |shared| reactor.credentials.release(shared);
        const count = 1 + request.headers.count + options.fields.len;
        if (count > h2.max_fields) return error.TooManyProviderHeaders;
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
        ) catch return error.ResponseCaptureAcquisitionFailed;
        self.* = .{
            .stream = .idle,
            .reactor = reactor,
            .request = .{ .file = request.file, .charged = request.charged, .structured_output = request.structured_output, .codec = request.codec },
            .response = response,
            .headers = .{ .turn_state = options.turn_state },
            .credential = options.credential,
        };
        errdefer {
            self.response.deinit(reactor.io, reactor.budget);
            self.* = undefined;
        }
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

    /// At any point after `start`. Cancels the stream if it is still live
    /// (a reset for an open one, sent by the next drive), then closes every
    /// file still held and releases both charges.
    pub fn deinit(self: *Transfer) void {
        const reactor = self.reactor;
        reactor.client.cancel(&self.stream);
        self.stream.deinit();
        self.retireRequest();
        self.headers.observed.deinit();
        if (self.response_owned) self.response.deinit(reactor.io, reactor.budget);
        // After the cancel, so h2 no longer holds the borrowed bytes.
        self.releaseCredential();
        self.* = undefined;
    }

    fn releaseCredential(self: *Transfer) void {
        const shared = self.credential orelse return;
        self.credential = null;
        self.reactor.credentials.release(shared);
    }

    /// h2 will not read the request again: close it and release its charge
    /// now, not at completion, since an answer can stream for minutes.
    fn retireRequest(self: *Transfer) void {
        if (!self.request_open) return;
        self.request_open = false;
        // Its other facts outlive its file.
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

    /// The sealed answer, success or HTTP error.
    pub fn takeResponse(self: *Transfer) SealedResponse {
        std.debug.assert(self.response_owned);
        std.debug.assert(self.response.sealed);
        self.response_owned = false;
        return .{
            .io = self.reactor.io,
            .file = self.response.file,
            .length = self.response.length,
            .charged = self.response.charged,
            .budget = self.reactor.budget,
        };
    }

    /// The unsealed bytes h2 wrote before an unanswered failure.
    pub fn partialResponse(self: *const Transfer) struct { file: std.Io.File, length: u64 } {
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
    // The converse of `policyCause`: no policy tag lacks an h2 cause.
    for (std.meta.fieldNames(transport_policy.Cause)) |name| _ = @field(h2.Cause, name);
}

/// Rui's endpoint rule, which h2's own URL rule must also accept.
pub fn validateEndpoint(endpoint: []const u8) !void {
    if (endpoint.len == 0 or endpoint.len > max_endpoint_bytes or
        std.mem.indexOfScalar(u8, endpoint, 0) != null or !std.unicode.utf8ValidateSlice(endpoint))
    {
        return error.InvalidProviderEndpoint;
    }
    const uri = std.Uri.parse(endpoint) catch return error.InvalidProviderEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidProviderEndpoint;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const component = uri.host orelse return error.InvalidProviderEndpoint;
    const host = component.toRaw(&host_buffer) catch return error.InvalidProviderEndpoint;
    if (host.len == 0) return error.InvalidProviderEndpoint;
    if (std.mem.eql(u8, uri.scheme, "http")) {
        if (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "::1")) return error.InsecureProviderEndpoint;
    } else if (!std.mem.eql(u8, uri.scheme, "https")) return error.InvalidProviderEndpoint;
    _ = h2.parseUrl(endpoint) catch |err| return switch (err) {
        error.CleartextNotLoopback => error.InsecureProviderEndpoint,
        error.InvalidUrl => error.InvalidProviderEndpoint,
    };
}

test "idle reactor reports zero finished transfers and no completion" {
    var used: std.atomic.Value(u64) = .init(0);
    var reactor: Reactor = undefined;
    try reactor.init(std.testing.allocator, std.testing.io, .{
        .endpoints = .init(.{ .codex = "http://127.0.0.1:1/responses", .openai = null }),
        .capacity = 1,
        .inactivity_seconds = 1,
        .scratch_path = "/nonexistent",
        .budget = .{ .used = &used, .limit = 1 },
    });
    defer reactor.deinit();
    try std.testing.expectEqual(@as(usize, 0), reactor.finishedCount());
    try reactor.drive();
    try std.testing.expectEqual(@as(usize, 0), reactor.finishedCount());
    try std.testing.expectEqual(@as(?Completion, null), try reactor.nextCompletion(false));
}

test "Transfers presenting one credential share one copy, freed with the last use" {
    // The testing allocator fails the test on a leak or a double free.
    var credentials: Credentials = .{ .allocator = std.testing.allocator };
    const first = try credentials.share("token-a", "account");
    const second = try credentials.share("token-a", "account");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("Bearer token-a", first.authorization());
    try std.testing.expectEqualStrings("account", first.accountId());
    // A refreshed token, or another account, is a separate copy.
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
    reactor.credentials = .{ .allocator = std.testing.allocator };
    var transfer: Transfer = undefined;
    transfer.reactor = &reactor;
    transfer.headers = .{};
    transfer.credential = try reactor.credentials.share("token", "account");
    // A sibling Transfer still presenting the same credential.
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
    reactor.credentials = .{ .allocator = std.testing.allocator };
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

test "endpoint validation permits TLS and loopback fixture HTTP only" {
    try validateEndpoint("https://example.com/responses");
    try validateEndpoint("http://127.0.0.1:9876/fail");
    try std.testing.expectError(error.InsecureProviderEndpoint, validateEndpoint("http://example.com/fail"));
    try std.testing.expectError(
        error.InvalidProviderEndpoint,
        validateEndpoint("http://127.0.0.1:80@example.com/fail"),
    );
    try std.testing.expectError(
        error.InvalidProviderEndpoint,
        validateEndpoint("http://127.0.0.1:80@127.0.0.1:9876/fail"),
    );
    try std.testing.expectError(error.InvalidProviderEndpoint, validateEndpoint("https://user@example.com/fail"));
    try std.testing.expectError(error.InsecureProviderEndpoint, validateEndpoint("http://[::1]evil:80/fail"));
    // Accepted by the URI grammar but not by h2's: a query with no path.
    try std.testing.expectError(error.InvalidProviderEndpoint, validateEndpoint("https://example.com?q=1"));
}

fn observeLines(context: *HeaderContext, observation: *const HeaderObservation, lines: []const []const u8) !void {
    for (lines) |line| {
        if (std.mem.startsWith(u8, line, ":status ")) {
            const status = try std.fmt.parseInt(u16, line[":status ".len..], 10);
            context.block(if (status < 200) .interim else .final, status);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        try context.field(observation, line[0..colon], line[colon + 1 ..], 1_700_000_000);
    }
}

test "duplicate Retry-After headers retain both independent constraints" {
    var context: HeaderContext = .{};
    try observeLines(&context, &.{}, &.{
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
    const observation: HeaderObservation = .{ .names = .{
        .request_id = "correlation",
        .model = "served-model",
        .alternate_model = "other-model",
    } };
    var context: HeaderContext = .{};
    defer context.observed.deinit();
    try observeLines(&context, &observation, &.{ "openai-model: unrelated", "served-model: alpha", "other-model: beta", "correlation: ref-1" });
    try std.testing.expectEqualStrings("alpha", context.observed.get(.model));
    try std.testing.expectEqualStrings("beta", context.observed.get(.alternate_model));
    try std.testing.expectEqualStrings("ref-1", context.observed.get(.request_id));
    // A later block (trailers) must repeat a value, not contradict it.
    try observeLines(&context, &observation, &.{"served-model: alpha"});
    try std.testing.expectError(error.InvalidValue, observeLines(&context, &observation, &.{"served-model: gamma"}));
}

test "response observations keep their real length and reject empty, invalid UTF-8 or oversized values" {
    const observation: HeaderObservation = .{ .names = .{ .request_id = "correlation", .model = "served-model" } };
    var context: HeaderContext = .{};
    defer context.observed.deinit();
    try observeLines(&context, &observation, &.{":status 200"});
    try std.testing.expectEqual(@as(usize, 0), context.observed.bytes.len);
    try observeLines(&context, &observation, &.{ "served-model: m", "correlation: " ++ @as([256]u8, @splat('r')), "served-model: m" });
    try std.testing.expectEqual(@as(usize, 257), context.observed.bytes.len);
    try std.testing.expectEqualStrings("m", context.observed.get(.model));
    try std.testing.expectEqualStrings(&@as([256]u8, @splat('r')), context.observed.get(.request_id));
    try std.testing.expectEqualStrings("", context.observed.get(.alternate_model));
    for ([_][]const u8{ "served-model: ", "served-model: caf\xc3", "served-model: " ++ @as([protocol.max_model_bytes + 1]u8, @splat('m')) }) |line| {
        var rejected: HeaderContext = .{};
        defer rejected.observed.deinit();
        try std.testing.expectError(error.InvalidValue, observeLines(&rejected, &observation, &.{line}));
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
        const observation: HeaderObservation = .{ .names = .{ .turn_state = name }, .turn_state = record.sink() };
        var context: HeaderContext = .{ .turn_state = .{ .turn_id = 7, .epoch = 3 } };
        try observeLines(&context, &observation, case.lines);
        try std.testing.expectEqualStrings(case.expected, record.value.slice());
        try std.testing.expectEqual(@intFromBool(case.expected.len != 0), record.captures);
        if (record.captures != 0) try std.testing.expectEqual(TurnStateKey{ .turn_id = 7, .epoch = 3 }, record.key);
    }
    // A value in trailers, after a successful final block, is not routing.
    var record: TurnStateRecord = .{};
    const observation: HeaderObservation = .{ .names = .{ .turn_state = name }, .turn_state = record.sink() };
    var trailers: HeaderContext = .{};
    trailers.block(.final, 200);
    trailers.block(.trailers, 0);
    try trailers.field(&observation, name, "late", 0);
    try std.testing.expectEqual(@as(usize, 0), record.captures);
    // Unnamed callers observe nothing.
    const unnamed_observation: HeaderObservation = .{ .turn_state = record.sink() };
    var unnamed: HeaderContext = .{};
    try observeLines(&unnamed, &unnamed_observation, &.{ ":status 200", "x-codex-turn-state: value" });
    try std.testing.expectEqual(@as(usize, 0), record.captures);
}

const TurnStateRecord = struct {
    value: protocol.Bounded(max_turn_state_bytes) = .{},
    key: TurnStateKey = .{},
    captures: usize = 0,

    fn sink(self: *TurnStateRecord) TurnStateSink {
        return .{ .context = self, .capture = capture };
    }

    fn capture(context: *anyopaque, key: TurnStateKey, value: []const u8) void {
        const self: *TurnStateRecord = @ptrCast(@alignCast(context));
        self.captures += 1;
        self.key = key;
        self.value.set(value) catch unreachable;
    }
};
