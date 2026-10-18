const std = @import("std");
const builtin = @import("builtin");
const TestObservation = @import("TestObservation.zig");
const execution = @import("execution.zig");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");
const store = @import("store.zig");
const transport_options = @import("transport_options");
const transport_policy = @import("transport_policy.zig");

const c = @import("curl");

pub const curl_version = "8.22.0";
pub const openssl_version = "OpenSSL/3.6.3";
pub const request_scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const max_endpoint_bytes = 2048;

pub const TransportOptions = struct {
    ca_file: ?[]const u8 = null,
    // Borrowed until start returns; curl_slist owns copies through teardown.
    extra_headers: []const [:0]const u8 = &.{},
    observation_names: ObservationNames = .{},
    inactivity_seconds: i64 = 5 * 60,
    request_read_fault: bool = false,
    response_acquire_fault: bool = false,
    response_unlink_fault: bool = false,
    response_write_fault: bool = false,
    completion_identity_fault: CompletionIdentityFault = .none,
};

pub const CompletionIdentityFault = enum { none, missing, foreign, mismatched };

pub const ScratchBudget = protocol.ScratchBudget;

pub const PreparedRequest = struct {
    io: std.Io,
    file: std.Io.File,
    length: u64,
    charged: u64,
    budget: ScratchBudget,
    structured_output: bool,
    session_affinity: [16]u8,

    pub fn deinit(self: *PreparedRequest) void {
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

fn retainedNamedScratch(
    io: std.Io,
    file: std.Io.File,
    secondary_file: ?std.Io.File,
    name: []const u8,
    budget: ScratchBudget,
    charged: u64,
    removal: named_scratch.Removal,
) named_scratch.Owner {
    return .init(io, file, secondary_file, name, budget, charged, removal);
}

pub const ProtocolObservation = struct {
    http_version: c_long,
    connection_id: c.curl_off_t,
    new_connections: c_long,
};

pub const TransferIdentity = *const opaque {};
pub const TransportHandleIdentity = *const opaque {};

pub const Completion = struct {
    outcome: execution.TransferOutcome,
    queued_after: usize,
};

pub const TransferMembership = struct {
    context: *const anyopaque,
    find_fn: *const fn (*const anyopaque, TransportHandleIdentity) ?*Transfer,

    fn find(self: TransferMembership, handle: TransportHandleIdentity) ?*Transfer {
        return self.find_fn(self.context, handle);
    }
};

var foreign_completion_identity: u8 = 0;

pub const Reactor = struct {
    multi: *c.CURLM,

    pub const Advance = enum { not_ready, progressed, resume_capture_failure };

    pub fn init(capacity: usize) !Reactor {
        const multi = c.curl_multi_init() orelse return error.TransportAllocationFailed;
        errdefer _ = c.curl_multi_cleanup(multi);
        const connections = capacity / 100 + @intFromBool(capacity % 100 != 0);
        if (connections > std.math.maxInt(c_long) or
            c.curl_multi_setopt(multi, c.CURLMOPT_PIPELINING, @as(c_long, c.CURLPIPE_MULTIPLEX)) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_MAX_CONCURRENT_STREAMS, @as(c_long, 100)) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_MAX_HOST_CONNECTIONS, @as(c_long, @intCast(connections))) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_MAX_TOTAL_CONNECTIONS, @as(c_long, @intCast(connections))) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_MAXCONNECTS, @as(c_long, @intCast(connections))) != c.CURLM_OK)
        {
            return error.TransportCapabilityMissing;
        }
        return .{ .multi = multi };
    }

    pub fn deinit(self: *Reactor) void {
        std.debug.assert(c.curl_multi_cleanup(self.multi) == c.CURLM_OK);
        self.* = undefined;
    }

    pub fn add(self: *Reactor, transfer: *Transfer) !void {
        transfer.inactivity.arm(transfer.now());
        const private: ?*anyopaque = switch (transfer.completion_identity_fault) {
            .none => @ptrCast(transfer),
            .missing => null,
            .foreign => @ptrCast(&foreign_completion_identity),
            .mismatched => @ptrCast(&transfer.response),
        };
        try setOpt(transfer.easy, c.CURLOPT_PRIVATE, private);
        if (c.curl_multi_add_handle(self.multi, transfer.easy) != c.CURLM_OK) {
            return error.TransportReactorAddFailed;
        }
        transfer.in_reactor = true;
    }

    pub fn cancel(self: *Reactor, transfer: *Transfer) void {
        if (!transfer.in_reactor) return;
        std.debug.assert(c.curl_multi_remove_handle(self.multi, transfer.easy) == c.CURLM_OK);
        transfer.in_reactor = false;
    }

    pub fn discard(self: *Reactor, transfer: *Transfer) void {
        self.cancel(transfer);
        transfer.discard();
    }

    // The execution owner samples shared writer room before its receive scan.
    // Failure/expiry still progress when that scan cannot resume captures.
    pub fn advance(self: *Reactor, transfer: *Transfer, resume_allowed: bool, response_write_on_resume: *bool) !Advance {
        if (!transfer.isReceiving()) return .not_ready;
        if (transfer.captureFailure()) |failure| {
            self.cancel(transfer);
            transfer.finish(.{ .response_capture_failed = failure }, 0);
            return .progressed;
        }
        if (resume_allowed and transfer.in_reactor and transfer.inactivity.isPaused()) {
            if (response_write_on_resume.*) {
                transfer.response.fail_write = true;
                response_write_on_resume.* = false;
            }
            // Clear before unpausing: curl may synchronously pause again in its callback.
            transfer.inactivity.resumeAfterPause(transfer.now());
            const result = c.curl_easy_pause(transfer.easy, c.CURLPAUSE_CONT);
            if (result != c.CURLE_OK) {
                const outcome = try transfer.completionOutcome(result);
                self.cancel(transfer);
                transfer.finish(outcome, 0);
                return if (transfer.captureFailure() != null) .resume_capture_failure else .progressed;
            }
            return .progressed;
        }
        // curl does not invoke progress callbacks for an easy waiting in the
        // multi connection queue, so every scan checks the same interval.
        if (!transfer.inactivity.expiredAt(transfer.now())) return .not_ready;
        self.cancel(transfer);
        transfer.finish(.{ .transport_finished = .{ .disposition = .temporary_connection } }, 0);
        return .progressed;
    }

    pub fn drive(self: *Reactor, timeout_ms: c_int) !void {
        var running: c_int = 0;
        if (c.curl_multi_perform(self.multi, &running) != c.CURLM_OK) return error.TransportReactorFailed;
        if (running != 0) {
            var descriptors: c_int = 0;
            if (c.curl_multi_poll(self.multi, null, 0, timeout_ms, &descriptors) != c.CURLM_OK) {
                return error.TransportReactorFailed;
            }
            if (c.curl_multi_perform(self.multi, &running) != c.CURLM_OK) return error.TransportReactorFailed;
        }
    }

    // Separate waiting from curl callbacks so service timing never subtracts
    // callback/capture work as though it were an idle wait.
    pub fn wait(self: *Reactor, timeout_ms: c_int) !void {
        var descriptors: c_int = 0;
        if (c.curl_multi_poll(self.multi, null, 0, timeout_ms, &descriptors) != c.CURLM_OK) {
            return error.TransportReactorFailed;
        }
    }

    // Non-destructive count of finished easy handles whose CURLMSG_DONE has
    // not been consumed through curl_multi_info_read. This is not a second
    // completion owner and must not replace identity-checked removal.
    pub fn unprocessedCompletions(self: *Reactor) !u64 {
        var value: c.curl_off_t = 0;
        if (c.curl_multi_get_offt(self.multi, c.CURLMINFO_XFERS_DONE, &value) != c.CURLM_OK) {
            return error.TransportReactorFailed;
        }
        if (value < 0) return error.TransportReactorFailed;
        return @intCast(value);
    }

    pub fn nextCompletion(self: *Reactor, membership: TransferMembership) !bool {
        var remaining: c_int = 0;
        while (c.curl_multi_info_read(self.multi, &remaining)) |message| {
            if (message.*.msg != c.CURLMSG_DONE) continue;
            const easy = message.*.easy_handle orelse return error.MissingTransportCompletionHandle;
            const result = message.*.data.result;
            const handle: TransportHandleIdentity = @ptrCast(easy);
            // Establish the actual fixed-slot owner from the completed native
            // handle before treating curl's private value as an identity. The
            // private pointer is compared only; it is never dereferenced.
            const transfer = membership.find(handle) orelse return error.UnknownTransportCompletion;
            if (!transfer.matchesHandle(handle)) return error.MismatchedTransportMembership;
            var private: ?*anyopaque = null;
            const private_result = c.curl_easy_getinfo(easy, c.CURLINFO_PRIVATE, &private);
            try self.removeCompleted(transfer);
            if (private_result != c.CURLE_OK) return error.TransportCompletionIdentityUnavailable;
            const private_pointer = private orelse return error.MissingTransportCompletionIdentity;
            const identity: TransferIdentity = @ptrCast(private_pointer);
            if (identity != transfer.identity()) return error.MismatchedTransportCompletionIdentity;
            transfer.finish(try transfer.completionOutcome(result), @intCast(@max(remaining, 0)));
            return true;
        }
        return false;
    }

    fn removeCompleted(self: *Reactor, transfer: *Transfer) !void {
        if (!transfer.in_reactor) return error.InactiveTransportCompletion;
        if (c.curl_multi_remove_handle(self.multi, transfer.easy) != c.CURLM_OK) {
            return error.TransportReactorRemoveFailed;
        }
        transfer.in_reactor = false;
    }
};

// The reactor never performs capture I/O. All accepted callback bytes live in
// this fixed queue until the single writer finishes, including its active
// entry. A paused callback has accepted nothing and curl will redeliver it.
pub const CaptureWriter = struct {
    const capacity = 16;
    const Entry = struct {
        capture: *ResponseCapture,
        length: usize = 0,
        bytes: [c.CURL_MAX_WRITE_SIZE]u8 = undefined,
        seal: bool = false,
        fail_seal: bool = false,
    };

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    entries: [capacity]Entry = undefined,
    head: usize = 0,
    count: usize = 0,
    stopping: bool = false,
    test_gate_path: ?[]const u8 = null,
    test_gate_min_written_bytes: usize = 0,
    // Borrowed through capture-writer join, before Host closes the private fd.
    test_observation: ?*TestObservation = null,

    pub fn run(self: *CaptureWriter) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.count == 0 and !self.stopping) self.available.waitUncancelable(self.io, &self.mutex);
            if (self.count == 0 and self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            self.processOne();
        }
    }

    // The caller holds the queue mutex; the active entry stays counted while
    // I/O runs without it. Tests drive this same transition without a thread.
    fn processOne(self: *CaptureWriter) void {
        std.debug.assert(self.count != 0);
        const entry = &self.entries[self.head];
        const capture = entry.capture;
        const failed = capture.failure != null;
        self.mutex.unlock(self.io);

        if (entry.seal) {
            if (!failed) capture.seal(entry.fail_seal) catch {
                self.mutex.lockUncancelable(self.io);
                capture.failure = .seal_failed;
                self.mutex.unlock(self.io);
            };
        } else if (!failed) {
            if (self.test_gate_path) |path| if (capture.length >= self.test_gate_min_written_bytes) {
                self.test_gate_path = null;
                if (self.test_observation) |writer| {
                    if (writer.begin("capture_write_gate_entered", null)) |initial| {
                        var publication = initial;
                        defer publication.finish();
                        var observation: protocol.FixedJsonBuffer(128) = .{};
                        observation.appendFmt("{{\"rui_test_phase\":\"capture_write_gate_entered\",\"at_ns\":\"{d}\",\"written_bytes\":\"{d}\"}}", .{
                            @as(u64, @intCast(std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds)),
                            capture.length,
                        }) catch unreachable;
                        publication.record(observation.slice());
                    }
                }
                if (std.Io.Dir.cwd().openFile(self.io, path, .{})) |gate| {
                    defer gate.close(self.io);
                    var release: [1]u8 = undefined;
                    _ = gate.readStreaming(self.io, &.{&release}) catch {};
                } else |_| {}
            };
            capture.file.writeStreamingAll(capture.io, entry.bytes[0..entry.length]) catch {
                self.mutex.lockUncancelable(self.io);
                capture.failure = .write_failed;
                self.mutex.unlock(self.io);
            };
        }

        self.mutex.lockUncancelable(self.io);
        if (!entry.seal and capture.failure == null) capture.length += entry.length;
        capture.pending_writes -= 1;
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        self.mutex.unlock(self.io);
    }

    pub fn stop(self: *CaptureWriter, thread: std.Thread) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.available.signal(self.io);
        self.mutex.unlock(self.io);
        thread.join();
        std.debug.assert(self.count == 0);
    }

    fn offer(self: *CaptureWriter, capture: *ResponseCapture, bytes: []const u8) usize {
        std.debug.assert(bytes.len <= c.CURL_MAX_WRITE_SIZE);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (capture.failure != null) return 0;
        if (self.count == capacity) return c.CURL_WRITEFUNC_PAUSE;
        if (capture.fail_write) {
            capture.failure = .write_failed;
            return 0;
        }
        if (!capture.budget.reserve(bytes.len)) {
            capture.failure = .scratch_exhausted;
            return 0;
        }
        capture.charged = std.math.add(u64, capture.charged, bytes.len) catch {
            capture.budget.release(bytes.len);
            capture.failure = .write_failed;
            return 0;
        };
        const entry = &self.entries[(self.head + self.count) % capacity];
        entry.* = .{ .capture = capture, .length = bytes.len };
        @memcpy(entry.bytes[0..bytes.len], bytes);
        capture.pending_writes += 1;
        self.count += 1;
        self.available.signal(self.io);
        return bytes.len;
    }

    pub fn seal(self: *CaptureWriter, capture: *ResponseCapture, fail: bool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == capacity) return false;
        self.entries[(self.head + self.count) % capacity] = .{
            .capture = capture,
            .seal = true,
            .fail_seal = fail,
        };
        capture.pending_writes += 1;
        self.count += 1;
        self.available.signal(self.io);
        return true;
    }

    pub fn drained(self: *CaptureWriter, capture: *ResponseCapture) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return capture.pending_writes == 0;
    }

    pub fn hasRoom(self: *CaptureWriter) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.count < capacity;
    }
};

pub fn initialize() !void {
    if (comptime !transport_options.enabled) return error.TransportUnavailableOnTarget;
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.TransportInitializationFailed;
    errdefer c.curl_global_cleanup();
    const info = c.curl_version_info(c.CURLVERSION_NOW) orelse return error.TransportCapabilityMissing;
    if (!std.mem.eql(u8, std.mem.span(info.*.version), curl_version) or
        info.*.ssl_version == null or
        !std.mem.startsWith(u8, std.mem.span(info.*.ssl_version), openssl_version) or
        info.*.features & c.CURL_VERSION_SSL == 0 or
        info.*.features & c.CURL_VERSION_ASYNCHDNS == 0 or
        info.*.features & c.CURL_VERSION_HTTP2 == 0 or
        info.*.features & c.CURL_VERSION_THREADSAFE == 0)
    {
        return error.TransportCapabilityMissing;
    }
}

pub fn deinitialize() void {
    if (comptime transport_options.enabled) c.curl_global_cleanup();
}

const ReadContext = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    length: u64,
    fail: bool = false,
    failed: bool = false,
};

pub const ResponseCapture = struct {
    io: std.Io,
    file: std.Io.File,
    readonly: ?std.Io.File,
    budget: ScratchBudget,
    length: u64 = 0,
    charged: u64 = 0,
    sealed: bool = false,
    fail_write: bool = false,
    failure: ?execution.CaptureFailure = null,
    pending_writes: usize = 0,

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        binding: store.AttemptBinding,
        fail_acquire: bool,
        fail_unlink: bool,
        fail_write: bool,
        retained: *?named_scratch.Owner,
    ) !ResponseCapture {
        retained.* = null;
        if (fail_acquire) return error.InjectedResponseAcquireFailure;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        var name_buffer: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "response-{d}-{d}.tmp", .{
            binding.operation_id,
            binding.attempt_ordinal,
        });
        const file = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        const readonly = scratch.openFile(io, name, .{}) catch |err| {
            retained.* = retainedNamedScratch(io, file, null, name, budget, 0, .native);
            return err;
        };
        if (fail_unlink) {
            retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0, .injected_failure);
            return error.InjectedResponseUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0, .native);
            return err;
        };
        return .{
            .io = io,
            .file = file,
            .readonly = readonly,
            .budget = budget,
            .fail_write = fail_write,
        };
    }

    pub fn seal(self: *ResponseCapture, fail: bool) !void {
        std.debug.assert(!self.sealed);
        if (fail) return error.InjectedResponseSealFailure;
        try self.file.sync(self.io);
        if (try self.file.length(self.io) != self.length) return error.ResponseSealFailed;
        const readonly = self.readonly orelse return error.ResponseSealFailed;
        self.file.close(self.io);
        self.file = readonly;
        self.readonly = null;
        self.sealed = true;
    }

    pub fn deinit(self: *ResponseCapture) void {
        std.debug.assert(self.pending_writes == 0);
        self.file.close(self.io);
        if (self.readonly) |readonly| readonly.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

const HeaderContext = struct {
    names: ObservationNames = .{},
    request_id: protocol.Bounded(256) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    alternate_model: protocol.Bounded(protocol.max_model_bytes) = .{},
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
    invalid: bool = false,
};

pub const ObservationNames = struct {
    request_id: []const u8 = "",
    model: []const u8 = "",
    alternate_model: []const u8 = "",
};

pub const Transfer = struct {
    const Local = union(enum) {
        receiving,
        finished: struct { completion: Completion, seal_queued: bool = false },
        discarded,
    };

    pub const Finalization = union(enum) { pending, discarded, ready: Completion };

    easy: *c.CURL,
    headers: ?*c.curl_slist,
    request: PreparedRequest,
    read_context: ReadContext,
    response: ResponseCapture,
    writer: *CaptureWriter,
    local: Local = .receiving,
    response_owned: bool = true,
    header_context: HeaderContext = .{},
    error_buffer: [c.CURL_ERROR_SIZE]u8 = @splat(0),
    inactivity: transport_policy.Inactivity,
    in_reactor: bool = false,
    completion_identity_fault: CompletionIdentityFault,
    binding: store.AttemptBinding,
    requires_h2: bool,

    pub fn start(
        self: *Transfer,
        endpoint: []const u8,
        request: PreparedRequest,
        binding: store.AttemptBinding,
        options: TransportOptions,
        writer: *CaptureWriter,
        scratch_path: []const u8,
        response_budget: ScratchBudget,
        retained_response: *?named_scratch.Owner,
    ) !void {
        if (options.inactivity_seconds <= 0) return error.InvalidTransportTimeout;
        const inactivity_ns = std.math.mul(i64, options.inactivity_seconds, std.time.ns_per_s) catch
            return error.InvalidTransportTimeout;
        if (options.inactivity_seconds > std.math.maxInt(c_long)) return error.InvalidTransportTimeout;
        const connect_timeout_ms = std.math.mul(
            c_long,
            @as(c_long, @intCast(options.inactivity_seconds)),
            1000,
        ) catch return error.InvalidTransportTimeout;
        try validateEndpoint(endpoint);
        var endpoint_buffer: [max_endpoint_bytes + 1:0]u8 = undefined;
        const endpoint_z = try std.fmt.bufPrintSentinel(&endpoint_buffer, "{s}", .{endpoint}, 0);
        const easy = c.curl_easy_init() orelse return error.TransportAllocationFailed;
        errdefer c.curl_easy_cleanup(easy);
        var headers: ?*c.curl_slist = null;
        errdefer freeHeaders(headers);
        try appendHeader(&headers, "Content-Type: application/json");
        for (options.extra_headers) |header| try appendHeader(&headers, header.ptr);
        var response = ResponseCapture.init(
            request.io,
            scratch_path,
            response_budget,
            binding,
            options.response_acquire_fault,
            options.response_unlink_fault,
            options.response_write_fault,
            retained_response,
        ) catch return error.ResponseCaptureAcquisitionFailed;
        errdefer response.deinit();
        self.* = .{
            .easy = easy,
            .headers = headers,
            .request = request,
            .header_context = .{ .names = options.observation_names },
            .read_context = .{
                .io = request.io,
                .file = request.file,
                .length = request.length,
                .fail = options.request_read_fault,
            },
            .response = response,
            .writer = writer,
            .binding = binding,
            .requires_h2 = !std.mem.startsWith(u8, endpoint, "http://"),
            .completion_identity_fault = options.completion_identity_fault,
            .inactivity = .{ .limit_ns = inactivity_ns },
        };
        try setOpt(easy, c.CURLOPT_URL, endpoint_z.ptr);
        try setOpt(easy, c.CURLOPT_POST, @as(c_long, 1));
        try setOpt(easy, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(request.length)));
        try setOpt(easy, c.CURLOPT_READFUNCTION, readCallback);
        try setOpt(easy, c.CURLOPT_READDATA, &self.read_context);
        try setOpt(easy, c.CURLOPT_SEEKFUNCTION, seekCallback);
        try setOpt(easy, c.CURLOPT_SEEKDATA, &self.read_context);
        try setOpt(easy, c.CURLOPT_UPLOAD_BUFFERSIZE, @as(c_long, 16 * 1024));
        try setOpt(easy, c.CURLOPT_WRITEFUNCTION, writeCallback);
        try setOpt(easy, c.CURLOPT_WRITEDATA, self);
        try setOpt(easy, c.CURLOPT_HEADERFUNCTION, headerCallback);
        try setOpt(easy, c.CURLOPT_HEADERDATA, &self.header_context);
        try setOpt(easy, c.CURLOPT_ERRORBUFFER, self.error_buffer[0..].ptr);
        try setOpt(easy, c.CURLOPT_HTTPHEADER, headers);
        try setOpt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        if (options.ca_file) |path| {
            var ca_buffer: [std.posix.PATH_MAX + 1:0]u8 = undefined;
            const ca_z = std.fmt.bufPrintSentinel(&ca_buffer, "{s}", .{path}, 0) catch return error.InvalidProviderCaFile;
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidProviderCaFile;
            try setOpt(easy, c.CURLOPT_CAINFO, ca_z.ptr);
        }
        try setOpt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, connect_timeout_ms);
        try setOpt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_XFERINFOFUNCTION, xferInfoCallback);
        try setOpt(easy, c.CURLOPT_XFERINFODATA, self);
        try setOpt(easy, c.CURLOPT_HTTP_VERSION, @as(c_long, if (std.mem.startsWith(u8, endpoint, "http://"))
            c.CURL_HTTP_VERSION_1_1
        else
            c.CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE));
        if (builtin.os.tag == .macos and !std.mem.startsWith(u8, endpoint, "http://")) {
            try setOpt(easy, c.CURLOPT_SSL_OPTIONS, @as(c_long, c.CURLSSLOPT_NATIVE_CA));
        }
    }

    fn completionOutcome(self: *Transfer, result: c.CURLcode) !execution.TransferOutcome {
        if (self.captureFailure()) |failure| return .{ .response_capture_failed = failure };
        if (self.read_context.failed) return .request_source_failed;
        return .{ .transport_finished = try self.transportEvidence(result) };
    }

    fn captureFailure(self: *Transfer) ?execution.CaptureFailure {
        self.writer.mutex.lockUncancelable(self.writer.io);
        defer self.writer.mutex.unlock(self.writer.io);
        return self.response.failure;
    }

    fn finish(self: *Transfer, outcome: execution.TransferOutcome, queued_after: usize) void {
        std.debug.assert(self.local == .receiving);
        self.local = .{ .finished = .{ .completion = .{ .outcome = outcome, .queued_after = queued_after } } };
    }

    fn isReceiving(self: *const Transfer) bool {
        return self.local == .receiving;
    }

    pub fn isDiscarded(self: *const Transfer) bool {
        return self.local == .discarded;
    }

    fn discard(self: *Transfer) void {
        self.local = .discarded;
    }

    // Transport completion is preliminary until all accepted writes (and a
    // successful response seal) finish. Cancellation retains the same capture
    // until the writer has no outstanding reference to it.
    pub fn advanceFinalization(self: *Transfer, fail_seal: bool) Finalization {
        switch (self.local) {
            .receiving => return .pending,
            .discarded => {
                std.debug.assert(!self.in_reactor);
                return if (self.writer.drained(&self.response)) .discarded else .pending;
            },
            .finished => |*finished| {
                std.debug.assert(!self.in_reactor);
                if (!finished.seal_queued and self.captureFailure() == null) {
                    switch (finished.completion.outcome) {
                        .transport_finished => |evidence| if (evidence.disposition.retainsResponse()) {
                            if (!self.writer.seal(&self.response, fail_seal)) return .pending;
                            finished.seal_queued = true;
                        },
                        else => {},
                    }
                }
                if (!self.writer.drained(&self.response)) return .pending;
                var ready = finished.completion;
                if (self.captureFailure()) |failure|
                    ready.outcome = .{ .response_capture_failed = failure };
                return .{ .ready = ready };
            },
        }
    }

    fn transportEvidence(self: *Transfer, result: c.CURLcode) !transport_policy.Evidence {
        var version: c_long = 0;
        if (c.curl_easy_getinfo(self.easy, c.CURLINFO_HTTP_VERSION, &version) != c.CURLE_OK)
            return error.InvalidHttpEvidence;
        var response_code: c_long = 0;
        const response_code_result = c.curl_easy_getinfo(self.easy, c.CURLINFO_RESPONSE_CODE, &response_code);
        return transport_policy.classify(.{
            .result = curlResult(result),
            .error_message = std.mem.sliceTo(&self.error_buffer, 0),
            .requires_h2 = self.requires_h2,
            .headers_invalid = self.header_context.invalid,
            .inactivity_expired = self.inactivity.expired,
            .version = switch (version) {
                c.CURL_HTTP_VERSION_1_1 => .http1_1,
                c.CURL_HTTP_VERSION_2_0 => .http2,
                else => .other,
            },
            .response_code = if (response_code_result == c.CURLE_OK) response_code else null,
            .retry_after_ms = self.header_context.retry_after_ms,
            .retry_after_deadline_ms = self.header_context.retry_after_deadline_ms,
        });
    }

    fn now(self: *const Transfer) std.Io.Clock.Timestamp {
        return std.Io.Clock.Timestamp.now(self.request.io, .awake);
    }

    pub fn deinit(self: *Transfer) void {
        std.debug.assert(!self.in_reactor);
        std.debug.assert(self.writer.drained(&self.response));
        c.curl_easy_cleanup(self.easy);
        freeHeaders(self.headers);
        self.request.deinit();
        if (self.response_owned) self.response.deinit();
        self.* = undefined;
    }

    pub fn takeResponse(self: *Transfer) ResponseCapture {
        std.debug.assert(self.response_owned);
        std.debug.assert(self.response.sealed);
        self.response_owned = false;
        return self.response;
    }

    pub fn requestId(self: *const Transfer) []const u8 {
        return self.header_context.request_id.slice();
    }

    /// Payload-free curl observations for a completed managed transfer.
    /// Connection IDs are meaningful only inside one Reactor/Host lifetime.
    pub fn protocolObservation(self: *const Transfer) ProtocolObservation {
        var result: ProtocolObservation = .{ .http_version = 0, .connection_id = -1, .new_connections = -1 };
        _ = c.curl_easy_getinfo(self.easy, c.CURLINFO_HTTP_VERSION, &result.http_version);
        _ = c.curl_easy_getinfo(self.easy, c.CURLINFO_CONN_ID, &result.connection_id);
        _ = c.curl_easy_getinfo(self.easy, c.CURLINFO_NUM_CONNECTS, &result.new_connections);
        return result;
    }

    pub fn observedModel(self: *const Transfer) []const u8 {
        return self.header_context.model.slice();
    }

    pub fn observedAlternateModel(self: *const Transfer) []const u8 {
        return self.header_context.alternate_model.slice();
    }

    pub fn identity(self: *const Transfer) TransferIdentity {
        return @ptrCast(self);
    }

    pub fn matchesHandle(self: *const Transfer, handle: TransportHandleIdentity) bool {
        return self.in_reactor and handle == @as(TransportHandleIdentity, @ptrCast(self.easy));
    }

    pub fn hasStructuredOutput(self: *const Transfer) bool {
        return self.request.structured_output;
    }
};

fn readCallback(pointer: [*c]u8, size: usize, count: usize, context_pointer: ?*anyopaque) callconv(.c) usize {
    const context: *ReadContext = @ptrCast(@alignCast(context_pointer orelse return c.CURL_READFUNC_ABORT));
    if (context.fail) {
        context.failed = true;
        return c.CURL_READFUNC_ABORT;
    }
    const capacity = std.math.mul(usize, size, count) catch return c.CURL_READFUNC_ABORT;
    const remaining = context.length - context.offset;
    const wanted: usize = @intCast(@min(remaining, capacity));
    if (wanted == 0) return 0;
    const actual = context.file.readPositionalAll(context.io, pointer[0..wanted], context.offset) catch {
        context.failed = true;
        return c.CURL_READFUNC_ABORT;
    };
    if (actual != wanted) {
        context.failed = true;
        return c.CURL_READFUNC_ABORT;
    }
    context.offset += actual;
    return actual;
}

fn seekCallback(context_pointer: ?*anyopaque, offset: c.curl_off_t, origin: c_int) callconv(.c) c_int {
    const context: *ReadContext = @ptrCast(@alignCast(context_pointer orelse return c.CURL_SEEKFUNC_FAIL));
    if (origin != c.SEEK_SET or offset < 0 or offset > context.length) return c.CURL_SEEKFUNC_FAIL;
    context.offset = @intCast(offset);
    return c.CURL_SEEKFUNC_OK;
}

fn xferInfoCallback(
    context_pointer: ?*anyopaque,
    _: c.curl_off_t,
    download_now: c.curl_off_t,
    _: c.curl_off_t,
    _: c.curl_off_t,
) callconv(.c) c_int {
    const transfer: *Transfer = @ptrCast(@alignCast(context_pointer orelse return 1));
    return @intFromBool(transfer.inactivity.progress(transfer.now(), download_now));
}

fn curlResult(code: c.CURLcode) transport_policy.CurlResult {
    inline for (comptime std.enums.values(transport_policy.CurlResult)) |result| {
        if (result == .other) continue;
        const name = comptime blk: {
            var upper: [@tagName(result).len]u8 = undefined;
            break :blk "CURLE_" ++ std.ascii.upperString(&upper, @tagName(result));
        };
        if (code == @field(c, name)) return result;
    }
    return .other;
}

fn writeCallback(pointer: [*c]u8, size: usize, count: usize, context_pointer: ?*anyopaque) callconv(.c) usize {
    const transfer: *Transfer = @ptrCast(@alignCast(context_pointer orelse return 0));
    const bytes = std.math.mul(usize, size, count) catch return 0;
    const accepted = transfer.writer.offer(&transfer.response, pointer[0..bytes]);
    if (accepted == c.CURL_WRITEFUNC_PAUSE) transfer.inactivity.pause(transfer.now());
    return accepted;
}

fn headerCallback(pointer: [*c]u8, size: usize, count: usize, context_pointer: ?*anyopaque) callconv(.c) usize {
    const context: *HeaderContext = @ptrCast(@alignCast(context_pointer orelse return 0));
    const bytes = std.math.mul(usize, size, count) catch return 0;
    const line = pointer[0..bytes];
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return bytes;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
    if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
        if (parseRetryAfter(value, c.time(null))) |constraint| switch (constraint) {
            .delay_ms => |delay| context.retry_after_ms = @max(context.retry_after_ms orelse 0, delay),
            .deadline_ms => |deadline| context.retry_after_deadline_ms = @max(context.retry_after_deadline_ms orelse 0, deadline),
        };
        return bytes;
    }
    const destination = if (context.names.request_id.len != 0 and std.ascii.eqlIgnoreCase(name, context.names.request_id))
        &context.request_id
    else if (context.names.model.len != 0 and std.ascii.eqlIgnoreCase(name, context.names.model))
        &context.model
    else if (context.names.alternate_model.len != 0 and std.ascii.eqlIgnoreCase(name, context.names.alternate_model))
        &context.alternate_model
    else
        return bytes;
    if (value.len == 0 or (destination.len != 0 and !destination.eql(value))) {
        context.invalid = true;
        return 0;
    }
    destination.set(value) catch {
        context.invalid = true;
        return 0;
    };
    return bytes;
}

const RetryAfter = union(enum) {
    delay_ms: u64,
    deadline_ms: i64,
};

fn parseRetryAfter(value: []const u8, now_seconds: c.time_t) ?RetryAfter {
    if (value.len == 0 or value.len > 128) return null;
    if (std.fmt.parseInt(u64, value, 10)) |seconds| {
        const delay_ms = std.math.mul(u64, seconds, 1000) catch return null;
        if (delay_ms > std.math.maxInt(i64)) return null;
        const now_ms = std.math.mul(i64, @intCast(now_seconds), 1000) catch return null;
        _ = std.math.add(i64, now_ms, @intCast(delay_ms)) catch return null;
        return .{ .delay_ms = delay_ms };
    } else |_| {}
    var buffer: [129:0]u8 = undefined;
    const value_z = std.fmt.bufPrintSentinel(&buffer, "{s}", .{value}, 0) catch return null;
    const due_seconds = c.curl_getdate(value_z.ptr, null);
    if (due_seconds < 0) return null;
    const deadline_ms = std.math.mul(i64, @intCast(due_seconds), 1000) catch return null;
    return .{ .deadline_ms = deadline_ms };
}

fn setOpt(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK) return error.TransportOptionFailed;
}

fn appendHeader(headers: *?*c.curl_slist, value: [*:0]const u8) !void {
    const next = c.curl_slist_append(headers.*, value) orelse return error.TransportAllocationFailed;
    headers.* = next;
}

fn freeHeaders(headers: ?*c.curl_slist) void {
    var node = headers;
    while (node) |current| : (node = current.*.next) {
        std.crypto.secureZero(u8, std.mem.span(current.*.data));
    }
    c.curl_slist_free_all(headers);
}

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
    if (std.mem.eql(u8, uri.scheme, "https")) return;
    if (!std.mem.eql(u8, uri.scheme, "http")) return error.InvalidProviderEndpoint;
    if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1")) return;
    return error.InsecureProviderEndpoint;
}

test "scratch reservation is bounded and releases exact charge" {
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 10 };
    try std.testing.expect(budget.reserve(7));
    try std.testing.expect(!budget.reserve(4));
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
}

test "Retry-After preserves dates and delays without unchecked arithmetic" {
    try std.testing.expectEqual(RetryAfter{ .delay_ms = 12_000 }, parseRetryAfter("12", 1_700_000_000).?);
    try std.testing.expectEqual(RetryAfter{ .deadline_ms = 1_700_000_001_000 }, parseRetryAfter("Tue, 14 Nov 2023 22:13:21 GMT", 1_700_000_000).?);
    try std.testing.expectEqual(RetryAfter{ .deadline_ms = 1_699_999_999_000 }, parseRetryAfter("Tue, 14 Nov 2023 22:13:19 GMT", 1_700_000_000).?);
    try std.testing.expect(parseRetryAfter("9223372036854775", 1_700_000_000) == null);
    try std.testing.expect(parseRetryAfter("invalid", 1_700_000_000) == null);
    try std.testing.expect(parseRetryAfter("18446744073709551615", 1_700_000_000) == null);
}

test "duplicate Retry-After headers retain both independent constraints" {
    var context: HeaderContext = .{};
    const lines = [_][]const u8{
        "Retry-After: 12\r\n",
        "Retry-After: Tue, 14 Nov 2023 22:13:21 GMT\r\n",
        "Retry-After: 3\r\n",
        "Retry-After: 9223372036854775\r\n",
        "Retry-After: Tue, 14 Nov 2023 22:13:19 GMT\r\n",
        "Retry-After: invalid\r\n",
    };
    for (lines) |line| {
        try std.testing.expectEqual(line.len, headerCallback(@constCast(line.ptr), 1, line.len, &context));
    }
    try std.testing.expectEqual(@as(?u64, 12_000), context.retry_after_ms);
    try std.testing.expectEqual(@as(?i64, 1_700_000_001_000), context.retry_after_deadline_ms);
}

test "response observations use caller-selected names and reject contradictions" {
    var context: HeaderContext = .{ .names = .{
        .request_id = "correlation",
        .model = "served-model",
        .alternate_model = "other-model",
    } };
    const ignored = "openai-model: unrelated\r\n";
    try std.testing.expectEqual(ignored.len, headerCallback(@constCast(ignored.ptr), 1, ignored.len, &context));
    const first = "Served-Model: alpha\r\n";
    const second = "other-model: beta\r\n";
    const correlation = "correlation: ref-1\r\n";
    for ([_][]const u8{ first, second, correlation }) |line|
        try std.testing.expectEqual(line.len, headerCallback(@constCast(line.ptr), 1, line.len, &context));
    try std.testing.expectEqualStrings("alpha", context.model.slice());
    try std.testing.expectEqualStrings("beta", context.alternate_model.slice());
    try std.testing.expectEqualStrings("ref-1", context.request_id.slice());
    const contradictory = "served-model: gamma\r\n";
    try std.testing.expectEqual(@as(usize, 0), headerCallback(@constCast(contradictory.ptr), 1, contradictory.len, &context));
    try std.testing.expect(context.invalid);
}

test "idle reactor reports zero unprocessed completions without consuming messages" {
    try initialize();
    defer c.curl_global_cleanup();
    for ([_]usize{ 1, 100, 101, 1000 }) |capacity| {
        var reactor = try Reactor.init(capacity);
        defer reactor.deinit();
        try std.testing.expectEqual(@as(u64, 0), try reactor.unprocessedCompletions());
        try std.testing.expectEqual(@as(u64, 0), try reactor.unprocessedCompletions());
    }
}

test "sealed POST source rewinds only within its complete length" {
    var context = ReadContext{ .io = undefined, .file = undefined, .length = 129, .offset = 101 };
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_OK), seekCallback(&context, 0, c.SEEK_SET));
    try std.testing.expectEqual(@as(u64, 0), context.offset);
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_OK), seekCallback(&context, 129, c.SEEK_SET));
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_FAIL), seekCallback(&context, 130, c.SEEK_SET));
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_FAIL), seekCallback(&context, -1, c.SEEK_SET));
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_FAIL), seekCallback(&context, 0, c.SEEK_CUR));
    try std.testing.expectEqual(@as(u64, 129), context.offset);
}

test "curl results reach transport policy by name" {
    const cases = [_]struct { code: c.CURLcode, expected: transport_policy.CurlResult }{
        .{ .code = c.CURLE_OK, .expected = .ok },
        .{ .code = c.CURLE_COULDNT_CONNECT, .expected = .couldnt_connect },
        .{ .code = c.CURLE_ABORTED_BY_CALLBACK, .expected = .aborted_by_callback },
        .{ .code = c.CURLE_PEER_FAILED_VERIFICATION, .expected = .peer_failed_verification },
        .{ .code = c.CURLE_WRITE_ERROR, .expected = .other },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, curlResult(case.code));
}

test "a full capture queue pauses the inactivity interval and curl progress cannot expire it" {
    var writer = CaptureWriter{ .io = std.testing.io, .count = CaptureWriter.capacity };
    var transfer: Transfer = undefined;
    transfer.request.io = std.testing.io;
    transfer.writer = &writer;
    transfer.response.failure = null;
    transfer.inactivity = .{ .limit_ns = std.time.ns_per_s };
    transfer.inactivity.arm(transfer.now().subDuration(.{ .raw = .fromSeconds(2), .clock = .awake }));
    var byte = [_]u8{'x'};
    try std.testing.expectEqual(@as(usize, c.CURL_WRITEFUNC_PAUSE), writeCallback(&byte, 1, 1, &transfer));
    try std.testing.expect(transfer.inactivity.isPaused());
    try std.testing.expectEqual(@as(c_int, 0), xferInfoCallback(&transfer, 0, 0, 0, 0));
    try std.testing.expect(!transfer.inactivity.expired);
    // Resuming restores the interval that had already elapsed before the pause.
    transfer.inactivity.resumeAfterPause(transfer.now());
    try std.testing.expectEqual(@as(c_int, 1), xferInfoCallback(&transfer, 0, 0, 0, 0));
    try std.testing.expect(transfer.inactivity.expired);
}

test "Transfer finalization waits for real writer drainage and seals once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "capture", .{ .read = true });
    const readonly = try tmp.dir.openFile(std.testing.io, "capture", .{});
    try tmp.dir.deleteFile(std.testing.io, "capture");
    var used = std.atomic.Value(u64).init(0);
    var writer = CaptureWriter{ .io = std.testing.io };
    var transfer: Transfer = undefined;
    transfer.writer = &writer;
    transfer.response = .{
        .io = std.testing.io,
        .file = file,
        .readonly = readonly,
        .budget = .{ .used = &used, .limit = 100 },
    };
    defer transfer.response.deinit();
    transfer.local = .receiving;
    transfer.in_reactor = false;

    try std.testing.expect(transfer.advanceFinalization(false) == .pending);
    try std.testing.expectEqual(@as(usize, 3), writer.offer(&transfer.response, "abc"));
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    transfer.finish(.{ .transport_finished = .{ .disposition = .success } }, 7);
    try std.testing.expect(transfer.advanceFinalization(false) == .pending);
    try std.testing.expectEqual(@as(usize, 2), writer.count); // write and seal both remain owned
    writer.mutex.lockUncancelable(writer.io);
    writer.processOne();
    try std.testing.expect(transfer.advanceFinalization(false) == .pending);
    try std.testing.expectEqual(@as(u64, 3), transfer.response.length);
    writer.mutex.lockUncancelable(writer.io);
    writer.processOne();
    const ready = transfer.advanceFinalization(false);
    try std.testing.expect(ready == .ready);
    try std.testing.expect(ready.ready.outcome == .transport_finished);
    try std.testing.expectEqual(@as(usize, 7), ready.ready.queued_after);
    try std.testing.expect(transfer.response.sealed);
    try std.testing.expectEqual(@as(usize, 0), writer.count);
    try std.testing.expect(transfer.advanceFinalization(false) == .ready);
    try std.testing.expectEqual(@as(usize, 0), writer.count);
}

test "receive scans without resume capacity still settle capture failure and queue expiry" {
    var writer = CaptureWriter{ .io = std.testing.io };
    var reactor: Reactor = undefined; // Neither case retains a native handle.
    var inject_resume_failure = false;
    for ([_]bool{ true, false }) |capture_failed| {
        var transfer: Transfer = undefined;
        transfer.writer = &writer;
        transfer.local = .receiving;
        transfer.in_reactor = false;
        transfer.response.failure = if (capture_failed) .write_failed else null;
        transfer.request.io = std.testing.io;
        transfer.inactivity = .{ .limit_ns = std.time.ns_per_s };
        transfer.inactivity.arm(transfer.now().subDuration(.{ .raw = .fromSeconds(2), .clock = .awake }));
        try std.testing.expectEqual(Reactor.Advance.progressed, try reactor.advance(&transfer, false, &inject_resume_failure));
        const outcome = transfer.local.finished.completion.outcome;
        if (capture_failed) {
            try std.testing.expectEqual(execution.CaptureFailure.write_failed, outcome.response_capture_failed);
        } else {
            try std.testing.expectEqual(transport_policy.Disposition.temporary_connection, outcome.transport_finished.disposition);
        }
    }
}

test "full capture queue rejects an offer without changing its charge or pending writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "full-queue", .{ .read = true });
    const readonly = try tmp.dir.openFile(std.testing.io, "full-queue", .{});
    try tmp.dir.deleteFile(std.testing.io, "full-queue");
    var used = std.atomic.Value(u64).init(0);
    var writer = CaptureWriter{ .io = std.testing.io };
    var capture = ResponseCapture{
        .io = std.testing.io,
        .file = file,
        .readonly = readonly,
        .budget = .{ .used = &used, .limit = CaptureWriter.capacity + 1 },
    };
    for (0..CaptureWriter.capacity) |_| try std.testing.expectEqual(@as(usize, 1), writer.offer(&capture, "x"));
    try std.testing.expectEqual(@as(usize, CaptureWriter.capacity), writer.count);
    try std.testing.expectEqual(@as(u64, CaptureWriter.capacity), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, c.CURL_WRITEFUNC_PAUSE), writer.offer(&capture, "y"));
    try std.testing.expectEqual(@as(usize, CaptureWriter.capacity), capture.pending_writes);
    try std.testing.expectEqual(@as(u64, CaptureWriter.capacity), capture.charged);
    try std.testing.expectEqual(@as(u64, CaptureWriter.capacity), used.load(.acquire));
    for (0..CaptureWriter.capacity) |_| {
        writer.mutex.lockUncancelable(writer.io);
        writer.processOne();
    }
    try std.testing.expectEqual(@as(usize, 0), writer.count);
    try std.testing.expectEqual(@as(u64, CaptureWriter.capacity), capture.length);
    capture.deinit();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "Transfer finalization records late capture failure and retains discarded writes and seals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(41);
    var writer = CaptureWriter{ .io = std.testing.io };
    for ([_]enum { write_failure, seal_failure, discard, discard_after_completion }{
        .write_failure, .seal_failure, .discard, .discard_after_completion,
    }, 0..) |scenario, index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "capture-{d}", .{index});
        const created = try tmp.dir.createFile(std.testing.io, name, .{ .read = true });
        const file = if (scenario == .write_failure) blk: {
            created.close(std.testing.io);
            break :blk try tmp.dir.openFile(std.testing.io, name, .{});
        } else created;
        const readonly = try tmp.dir.openFile(std.testing.io, name, .{});
        try tmp.dir.deleteFile(std.testing.io, name);
        var transfer: Transfer = undefined;
        transfer.writer = &writer;
        transfer.response = .{
            .io = std.testing.io,
            .file = file,
            .readonly = readonly,
            .budget = .{ .used = &used, .limit = 100 },
        };
        transfer.local = .receiving;
        transfer.in_reactor = false;
        try std.testing.expectEqual(@as(usize, 3), writer.offer(&transfer.response, "xyz"));
        try std.testing.expectEqual(@as(u64, 44), used.load(.acquire));
        if (scenario == .discard or scenario == .discard_after_completion) {
            if (scenario == .discard_after_completion) {
                transfer.finish(.{ .transport_finished = .{ .disposition = .success } }, 0);
                try std.testing.expect(transfer.advanceFinalization(false) == .pending);
                try std.testing.expectEqual(@as(usize, 2), writer.count);
            }
            transfer.discard();
            try std.testing.expect(transfer.advanceFinalization(false) == .pending);
        } else {
            transfer.finish(.{ .transport_finished = .{ .disposition = .success } }, 0);
            try std.testing.expect(transfer.advanceFinalization(scenario == .seal_failure) == .pending);
        }
        writer.mutex.lockUncancelable(writer.io);
        writer.processOne();
        if (scenario == .write_failure) {
            try std.testing.expectEqual(execution.CaptureFailure.write_failed, transfer.captureFailure().?);
            try std.testing.expectEqual(@as(u64, 0), transfer.response.length);
        }
        if (scenario != .discard) {
            try std.testing.expectEqual(@as(usize, 1), transfer.response.pending_writes);
            try std.testing.expect(transfer.advanceFinalization(true) == .pending);
            writer.mutex.lockUncancelable(writer.io);
            writer.processOne();
        }
        if (scenario == .discard_after_completion) try std.testing.expect(transfer.response.sealed);
        const final = transfer.advanceFinalization(false);
        switch (scenario) {
            .discard, .discard_after_completion => try std.testing.expect(final == .discarded),
            .write_failure => try std.testing.expect(final == .ready and final.ready.outcome == .response_capture_failed and final.ready.outcome.response_capture_failed == .write_failed),
            .seal_failure => try std.testing.expect(final == .ready and final.ready.outcome == .response_capture_failed and final.ready.outcome.response_capture_failed == .seal_failed),
        }
        try std.testing.expectEqual(@as(usize, 0), writer.count);
        transfer.response.deinit();
        try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    }
}
