const std = @import("std");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const session_view = @import("session_view.zig");
const client = @This();

/// Construct in final storage before spawning its borrower. Only requestStop
/// crosses threads; reset/reuse or destruction is permitted only after join.
pub const Cancellation = struct {
    stopped: std.atomic.Value(bool) = .init(false),

    pub fn requestStop(self: *Cancellation) void {
        self.stopped.store(true, .release);
    }

    pub fn check(self: *const Cancellation) error{Cancelled}!void {
        if (self.stopped.load(.acquire)) return error.Cancelled;
    }
};

/// Explicit request capability. io, token, inputs, captures and sinks are
/// borrowed until the worker returns. No descriptor escapes the worker; each
/// exchange closes its socket on every return. The token must remain at its
/// final address until join. Reply slices borrow the supplied reply buffer.
pub const Requests = struct {
    io: std.Io,
    cancellation: ?*const Cancellation = null,

    pub fn check(self: Requests) error{Cancelled}!void {
        if (self.cancellation) |token| try token.check();
    }

    pub const sendCaptured = client.sendCaptured;
    pub const observeCommand = client.observeCommand;
    pub const observeMessage = client.observeMessage;
    pub const sessionView = client.sessionView;
    pub const conversationPage = client.conversationPage;
    pub const conversationContentStream = client.conversationContentStream;
    pub const sessionCallContentStream = client.sessionCallContentStream;
    pub const messageContent = client.messageContent;
    pub const messageContentStream = client.messageContentStream;
    pub const inspectSession = client.inspectSession;
    pub const readResultStream = client.readResultStream;
    pub const readActionArguments = client.readActionArguments;
    pub const readActionCallId = client.readActionCallId;
};

// Ordinary scripted callers and explicit cancellable callers share builders,
// parsers and framing. Only this typed capability changes transport policy.
fn requestIo(requests: anytype) std.Io {
    if (@TypeOf(requests) == std.Io) return requests;
    const typed: Requests = if (@TypeOf(requests) == Requests) requests else requests.*;
    return typed.io;
}

fn checkCancellation(requests: anytype) error{Cancelled}!void {
    if (@TypeOf(requests) != std.Io) try requests.check();
}

fn cancellable(requests: anytype) bool {
    if (@TypeOf(requests) == std.Io) return false;
    return requests.cancellation != null;
}

pub const OptionalText = struct {
    present: bool = false,
    value: []const u8 = "",
};

pub const OptionalFile = struct {
    state: enum { omitted, value, explicit_null } = .omitted,
    path: []const u8 = "",
};

pub const ConfigureInput = struct {
    store: []const u8,
    session: union(enum) {
        named: []const u8,
        from_capture_key,
    },
    require_model: bool = false,
    workspace: OptionalText = .{},
    provider: OptionalText = .{},
    model: OptionalText = .{},
    instructions: OptionalFile = .{},
    tools: ?[]const u8 = null,
    permission_mode: OptionalText = .{},
    output_schema: OptionalFile = .{},
};

pub const MessageInput = struct {
    store: []const u8,
    session: []const u8,
    text_path: []const u8,
    text: ?[]const u8 = null,
};

pub const SessionStopInput = struct {
    store: []const u8,
    record: []const u8,
    key: []const u8,
    session: []const u8,
    drop_reply: ?[]const u8 = null,
};

pub const ModelInterruptionInput = struct {
    store: []const u8,
    record: []const u8,
    key: []const u8,
    session: []const u8,
    turn_id: u64,
    operation_id: u64,
    drop_reply: ?[]const u8 = null,
};

pub const PermissionDecisionInput = struct {
    store: []const u8,
    session: []const u8,
    action_id: u64,
    decision: protocol.PermissionDecision = .deny,
};

pub const ReplyBuffer = protocol.ResponseBuffer;

pub const HostStatus = union(enum) {
    ready: struct {
        store: protocol.Bounded(protocol.max_store_bytes),
        instance: protocol.InstanceId,
        active_capacity: usize,
        capabilities: @FieldType(protocol.HostInfo, "capabilities"),
    },
    unavailable,
    owned_unavailable,
    incompatible,
    access_failure,
};

pub const HostStopInput = struct {
    store: []const u8,
    // Retain the instance from the original observation across every retry.
    instance: protocol.InstanceId,
    drop_reply: ?[]const u8 = null,
};

pub const HostStopResult = enum { acknowledged, instance_changed, unavailable };

/// Acknowledgement means the matching Host fenced dispatch, not that it drained.
/// Retry with the same input after a lost reply; never rediscover a new target.
pub fn stopHost(io: std.Io, input: HostStopInput, reply_buffer: *ReplyBuffer) !HostStopResult {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    var body: protocol.RequestBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"host_stop\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append("}");
    const reply = sendSource(io, &paths, "/v1/control/host-stop", body.len, null, body.slice(), input.drop_reply, &input.instance, reply_buffer, null);
    const result = reply catch |err| return if (err == error.FileNotFound or err == error.ConnectionRefused)
        .unavailable
    else
        err;
    if (result.status == 200 and std.mem.eql(u8, result.body, protocol.host_stop_ack)) return .acknowledged;
    if (result.status == 409) {
        const Failure = struct { version: []const u8, type: []const u8, code: []const u8 };
        var parse_storage: [protocol.max_control_error_response_bytes * 2]u8 = undefined;
        var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
        const failure = std.json.parseFromSliceLeaky(Failure, arena.allocator(), result.body, .{ .ignore_unknown_fields = false }) catch return error.InvalidHostStopResponse;
        if (std.mem.eql(u8, failure.version, protocol.wire_version) and
            std.mem.eql(u8, failure.type, "invocation_error") and
            std.mem.eql(u8, failure.code, "host_instance_changed")) return .instance_changed;
    }
    if (result.status == 503) return .unavailable;
    return error.InvalidHostStopResponse;
}

/// Observation only: never creates a Store, acquires ownership or reads SQLite.
pub fn hostStatus(io: std.Io, store_path: []const u8) HostStatus {
    return hostStatusUntil(io, store_path, null);
}

/// Startup callers can bound the entire readiness loop, including each probe.
pub fn hostStatusUntil(io: std.Io, store_path: []const u8, deadline: ?i128) HostStatus {
    return switch (platform.StoreLease.observe(io, store_path)) {
        .owned => |paths| readHostInfo(io, &paths, deadline),
        .unowned => .unavailable,
        .access_failure => .access_failure,
    };
}

fn readHostInfo(io: std.Io, paths: *const platform.Paths, deadline: ?i128) HostStatus {
    var body: protocol.RequestBuffer = .{};
    body.append("{\"version\":\"1\",\"kind\":\"host_info\",\"store\":") catch unreachable;
    body.appendJsonString(paths.store.slice()) catch unreachable;
    body.append("}") catch unreachable;
    var reply_buffer: ReplyBuffer = .{};
    const probe_end = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
    const until = @min(probe_end, deadline orelse probe_end);
    const reply = sendSource(io, paths, "/v1/host-info", body.len, null, body.slice(), null, null, &reply_buffer, until) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_failure,
        error.WrongWireVersion, error.InvalidResponse, error.ResponseHeaderTooLarge, error.ResponseTooLarge, error.InvalidCharacter, error.Overflow => .incompatible,
        else => .owned_unavailable,
    };
    if (reply.status == 503) return if (validHostUnavailable(reply.body)) .owned_unavailable else .incompatible;
    if (reply.status != 200) return .incompatible;
    return parseHostInfo(reply.body, paths.store.slice()) catch .incompatible;
}

fn validHostUnavailable(body: []const u8) bool {
    if (body.len > protocol.max_control_error_response_bytes) return false;
    var parse_storage: [protocol.max_control_error_response_bytes * 2]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
    const reply = std.json.parseFromSliceLeaky(struct {
        version: []const u8,
        type: []const u8,
        code: []const u8,
    }, arena.allocator(), body, .{ .ignore_unknown_fields = false, .allocate = .alloc_if_needed }) catch return false;
    if (!std.mem.eql(u8, reply.version, protocol.wire_version)) return false;
    if (std.mem.eql(u8, reply.type, "host_unavailable")) return std.mem.eql(u8, reply.code, "dispatch_fenced");
    if (!std.mem.eql(u8, reply.type, "busy")) return false;
    return std.mem.eql(u8, reply.code, "connection_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "classification_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "discovery_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "ordinary_capacity_exhausted");
}

fn parseHostInfo(body: []const u8, store: []const u8) !HostStatus {
    if (body.len > protocol.max_host_info_response_bytes) return error.InvalidHostInfo;
    var parse_storage: [protocol.max_host_info_response_bytes * 2]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
    const info = try std.json.parseFromSliceLeaky(protocol.HostInfo, arena.allocator(), body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_if_needed,
    });
    if (!std.mem.eql(u8, info.version, protocol.wire_version) or
        !std.mem.eql(u8, info.type, "host_info") or
        !std.mem.eql(u8, info.store, store) or
        info.active_capacity.len == 0 or info.active_capacity.len > 20 or
        (info.active_capacity.len > 1 and info.active_capacity[0] == '0'))
        return error.InvalidHostInfo;
    for (info.active_capacity) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidHostInfo;
    const instance = protocol.parseInstanceId(info.instance) catch return error.InvalidHostInfo;
    const capacity = std.fmt.parseInt(usize, info.active_capacity, 10) catch return error.InvalidHostInfo;
    var identity: protocol.Bounded(protocol.max_store_bytes) = .{};
    try identity.set(info.store);
    return .{ .ready = .{
        .store = identity,
        .instance = instance,
        .active_capacity = capacity,
        .capabilities = info.capabilities,
    } };
}

test "Host information is bounded and rejects ambiguous identities and capacity" {
    const golden = "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"17\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}";
    const result = try parseHostInfo(golden, "/one");
    try std.testing.expect(result.ready.store.eql("/one"));
    try std.testing.expectEqual(@as(usize, 17), result.ready.active_capacity);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &result.ready.instance);
    try std.testing.expect(result.ready.capabilities.bash);
    try std.testing.expect(!result.ready.capabilities.model);
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(golden, "/other"));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0F\",\"active_capacity\":\"17\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
        "/one",
    ));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
        "/one",
    ));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"01\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
        "/one",
    ));
    for ([_]struct { needle: []const u8, replacement: []const u8 }{
        .{ .needle = "\"store\":\"/one\"", .replacement = "\"store\":\"/other\",\"store\":\"/one\"" },
        .{ .needle = "\"bash\":true", .replacement = "\"bash\":false,\"bash\":true" },
    }) |case| {
        const duplicated = try std.mem.replaceOwned(u8, std.testing.allocator, golden, case.needle, case.replacement);
        defer std.testing.allocator.free(duplicated);
        try std.testing.expectError(error.DuplicateField, parseHostInfo(duplicated, "/one"));
    }
}

test "Host unavailable replies require a known complete error" {
    for ([_][]const u8{
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"connection_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"classification_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"host_unavailable\",\"code\":\"dispatch_fenced\"}",
    }) |body| try std.testing.expect(validHostUnavailable(body));
    for ([_][]const u8{
        "{}",
        "{\"version\":\"2\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"dispatch_fenced\"}",
        "{\"version\":\"1\",\"type\":\"host_unavailable\",\"code\":\"unknown\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"code\":\"ordinary_capacity_exhausted\"}",
    }) |body| try std.testing.expect(!validHostUnavailable(body));
}

pub const CommandReply = struct {
    status: u16,
    // Borrowed from the caller's ReplyBuffer until that buffer is reused.
    body: []const u8,
};

pub const ResultReply = union(enum) {
    answer: struct { bytes: u64 },
    command: CommandReply,
};

pub const ReportReply = union(enum) {
    report: struct { bytes: u64 },
    command: CommandReply,
};

pub const SessionListCursor = struct { after: u64 = 0, ceiling: u64 = 0 };

fn renderSessionListRequest(body: *protocol.RequestBuffer, store: []const u8, workspace: ?[]const u8, cursor: SessionListCursor) !void {
    try body.append("{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":");
    try body.appendJsonString(store);
    try body.append(",\"workspace\":");
    if (workspace) |value| try body.appendJsonString(value) else try body.append("null");
    try body.appendFmt(",\"after\":\"{d}\",\"ceiling\":\"{d}\"}}", .{ cursor.after, cursor.ceiling });
}

fn renderReadRequest(
    body: *protocol.RequestBuffer,
    kind: []const u8,
    store: []const u8,
    target_name: []const u8,
    target: []const u8,
    action_id: ?u64,
    report_profile: ?protocol.ReportProfile,
) !void {
    try body.append("{\"version\":\"1\",\"kind\":");
    try body.appendJsonString(kind);
    try body.append(",\"store\":");
    try body.appendJsonString(store);
    try body.append(",");
    try body.appendJsonString(target_name);
    try body.append(":");
    try body.appendJsonString(target);
    if (action_id) |id| try body.appendFmt(",\"action\":\"{d}\"", .{id});
    if (report_profile) |profile| {
        if (profile == .full) try body.append(",\"profile\":\"full\"");
    }
    try body.append("}");
}

pub fn stopSession(io: std.Io, input: SessionStopInput, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    try captureSessionStop(io, &paths, input);
    return sendRecord(
        io,
        &paths,
        input.record,
        "/v1/control/session-stop",
        input.drop_reply,
        reply_buffer,
    );
}

pub fn interruptModel(io: std.Io, input: ModelInterruptionInput, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    if (input.turn_id == 0 or input.operation_id == 0) return error.InvalidTarget;
    try captureModelInterruption(io, &paths, input);
    return sendRecord(
        io,
        &paths,
        input.record,
        "/v1/control/model-interruption",
        input.drop_reply,
        reply_buffer,
    );
}

pub fn retry(
    io: std.Io,
    store_path: []const u8,
    record: []const u8,
    kind: []const u8,
    reply_buffer: *ReplyBuffer,
) !CommandReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, store_path);
    const route = if (std.mem.eql(u8, kind, "configure"))
        "/v1/configure"
    else if (std.mem.eql(u8, kind, "message"))
        "/v1/message"
    else if (std.mem.eql(u8, kind, "session-stop"))
        "/v1/control/session-stop"
    else if (std.mem.eql(u8, kind, "model-interruption"))
        "/v1/control/model-interruption"
    else if (std.mem.eql(u8, kind, "permission-decision"))
        "/v1/control/permission-decision"
    else
        return error.InvalidRetryKind;
    return sendRecord(io, &paths, record, route, null, reply_buffer);
}

pub fn observeCommand(
    io: anytype,
    store_path: []const u8,
    key: []const u8,
    reply_buffer: *ReplyBuffer,
) !CommandReply {
    reply_buffer.len = 0;
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, "observe_command", paths.store.slice(), "key", key, null, null);
    return sendBytes(io, &paths, "/v1/observe-command", body.slice(), null, reply_buffer);
}

/// An owned selected address, independent of any local request capture.
pub const MessageAddress = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},

    pub fn init(store: []const u8, session: []const u8, key: []const u8) !MessageAddress {
        try validateIdentityInputs(key, session);
        var address: MessageAddress = .{};
        try address.store.set(store);
        try address.session.set(session);
        try address.key.set(key);
        return address;
    }
};

/// Owns decoded storage. Code slices borrow it until deinit, independently of
/// the reply buffer. Consumers use facts and writeJson, never the parsed tree.
pub const MessageObservation = struct {
    state: State,
    code: ?[]const u8 = null,
    processing_turn: ?u64 = null,
    progress: ?Progress = null,
    storage: *Storage,

    const Storage = opaque {};

    pub const State = enum {
        accepted,
        queued,
        processing,
        rejected,
        completed,
        failed,
        cancelled,

        pub fn terminal(self: State) bool {
            return switch (self) {
                .rejected, .completed, .failed, .cancelled => true,
                else => false,
            };
        }
    };

    pub const Progress = struct {
        status: enum { runnable, in_flight, waiting_for_permission },
        action: ?u64,
    };

    pub fn deinit(self: *MessageObservation) void {
        const parsed: *std.json.Parsed(std.json.Value) = @ptrCast(@alignCast(self.storage));
        parsed.deinit();
        self.* = undefined;
    }

    /// Writes the complete supported observation, including fields not consumed
    /// by typed facts. No second serialized payload or typed reconstruction.
    pub fn writeJson(self: *const MessageObservation, writer: *std.Io.Writer) !void {
        const parsed: *const std.json.Parsed(std.json.Value) = @ptrCast(@alignCast(self.storage));
        try std.json.Stringify.value(parsed.value.object.get("observation").?, .{}, writer);
    }

    pub fn parse(allocator: std.mem.Allocator, reply: CommandReply, address: *const MessageAddress) !MessageObservation {
        try checkCanonicalFailure(reply);
        if (reply.status != 200) return error.ObservationFailed;
        if (reply.body.len > protocol.max_response_bytes) return error.ResponseTooLarge;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply.body, .{ .allocate = .alloc_always, .parse_numbers = false });
        errdefer parsed.deinit();
        const root = parsed.value;
        if (!std.mem.eql(u8, try observationString(root, "version"), protocol.wire_version) or
            !std.mem.eql(u8, try observationString(root, "type"), "command_observation")) return error.InvalidObservation;
        if (!std.mem.eql(u8, try observationString(root, "key"), address.key.slice())) return error.RequestBindingMismatch;
        const observation = try observationField(root, "observation");
        const status = try observationString(observation, "status");
        if (std.mem.eql(u8, status, "absent")) return error.RequestNotAdmitted;
        if (!std.mem.eql(u8, try observationString(observation, "kind"), "message") or
            !std.mem.eql(u8, try observationString(observation, "target"), address.session.slice())) return error.RequestBindingMismatch;

        // Store the private lifetime record in the parser's existing arena: no
        // independent allocation owner or second copy of the observation tree.
        const storage = try parsed.arena.allocator().create(@TypeOf(parsed));
        storage.* = parsed;
        var result: MessageObservation = .{ .state = .accepted, .storage = @ptrCast(storage) };
        if (std.mem.eql(u8, status, "rejected")) {
            result.state = .rejected;
            result.code = try observationCode(observation);
            return result;
        }
        if (!std.mem.eql(u8, status, "accepted")) return error.InvalidObservation;
        if (observation.object.get("processing")) |processing|
            result.processing_turn = try observationId(try observationField(processing, "turn"));
        // The selected Message's terminal result wins over queue/progress hints,
        // including an excluded queue and a successor's permission attention.
        if (observation.object.get("result")) |terminal_result| {
            const outcome = try observationString(terminal_result, "status");
            result.state = std.meta.stringToEnum(State, outcome) orelse return error.InvalidObservation;
            if (result.state != .completed and result.state != .failed and result.state != .cancelled) return error.InvalidObservation;
            result.code = try observationCode(terminal_result);
            return result;
        }
        if (observation.object.get("queue")) |queue| {
            const queued = try observationString(queue, "status");
            result.state = std.meta.stringToEnum(State, queued) orelse return error.InvalidObservation;
            if (result.state != .queued and result.state != .processing) return error.InvalidObservation;
        }
        if (observation.object.get("progress")) |progress| {
            const progress_status = std.meta.stringToEnum(@FieldType(Progress, "status"), try observationString(progress, "status")) orelse return error.InvalidObservation;
            const action = try observationField(progress, "action");
            const action_id: ?u64 = switch (action) {
                .null => null,
                else => try observationId(action),
            };
            if (progress_status == .waiting_for_permission and action_id == null) return error.InvalidObservation;
            result.progress = .{ .status = progress_status, .action = action_id };
        }
        return result;
    }
};

fn observationField(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidObservation;
    return value.object.get(name) orelse error.InvalidObservation;
}

fn observationString(value: std.json.Value, name: []const u8) ![]const u8 {
    const field = try observationField(value, name);
    if (field != .string) return error.InvalidObservation;
    return field.string;
}

fn observationId(value: std.json.Value) !u64 {
    if (value != .string or value.string.len == 0) return error.InvalidObservation;
    for (value.string) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidObservation;
    const id = std.fmt.parseInt(u64, value.string, 10) catch return error.InvalidObservation;
    if (id == 0) return error.InvalidObservation;
    return id;
}

fn observationCode(value: std.json.Value) !?[]const u8 {
    if (value != .object) return error.InvalidObservation;
    if (value.object.get("code")) |code| {
        if (code != .string) return error.InvalidObservation;
        return code.string;
    }
    return null;
}

pub fn observeMessage(io: anytype, allocator: std.mem.Allocator, address: *const MessageAddress) !MessageObservation {
    var buffer: ReplyBuffer = .{};
    const reply = try observeCommand(io, address.store.slice(), address.key.slice(), &buffer);
    return MessageObservation.parse(allocator, reply, address);
}

pub fn readResult(
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return readResultWithSink(io, store_path, key, destination, reply_buffer);
}

/// Streams answer windows to the caller without retaining a complete copy.
/// The sink receives borrowed windows valid only during each feed call.
pub fn readResultStream(
    io: anytype,
    store_path: []const u8,
    key: []const u8,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return readResultWithSink(io, store_path, key, sink, reply_buffer);
}

fn readResultWithSink(
    io: anytype,
    store_path: []const u8,
    key: []const u8,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    reply_buffer.len = 0;
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, "read_result", paths.store.slice(), "key", key, null, null);
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(io, address, null);
    defer closeRequest(io, fd);
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/read-result HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{body.len});
    try writeAllUntil(io, fd, header, null);
    try writeAllUntil(io, fd, body.slice(), null);
    return readResultResponseSink(io, fd, sink, reply_buffer);
}

pub fn inspectSession(
    io: anytype,
    store_path: []const u8,
    session: []const u8,
    profile: protocol.ReportProfile,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ReportReply {
    reply_buffer.len = 0;
    if (session.len == 0 or session.len > protocol.max_session_bytes or
        !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, "inspect_session", paths.store.slice(), "session", session, null, profile);
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(io, address, null);
    defer closeRequest(io, fd);
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/inspect-session HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{body.len});
    try writeAllUntil(io, fd, header, null);
    try writeAllUntil(io, fd, body.slice(), null);
    return readReportResponse(io, fd, destination, reply_buffer);
}

/// Streams one complete JSON page into destination. A non-200 reply borrows
/// reply_buffer; a partial destination after an I/O error is not a valid page.
/// Pass the response's next cursor and the same workspace for continuation.
pub fn listSessions(
    io: std.Io,
    store_path: []const u8,
    workspace: ?[]const u8,
    cursor: SessionListCursor,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ReportReply {
    reply_buffer.len = 0;
    if (workspace) |value| {
        if (value.len == 0 or value.len > protocol.max_workspace_bytes or
            !std.unicode.utf8ValidateSlice(value)) return error.InvalidWorkspace;
    }
    if (cursor.after > std.math.maxInt(i64) or cursor.ceiling > std.math.maxInt(i64) or
        (cursor.after == 0 and cursor.ceiling != 0) or
        (cursor.after != 0 and cursor.after > cursor.ceiling)) return error.InvalidCursor;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try renderSessionListRequest(&body, paths.store.slice(), workspace, cursor);
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const stream = try address.connect(io);
    defer stream.close(io);
    const fd = stream.socket.handle;
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/list-sessions HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{body.len});
    try writeAll(fd, header);
    try writeAll(fd, body.slice());
    return readReportResponse(io, fd, destination, reply_buffer);
}

pub const ConversationCursor = struct { end: u64 = 0, before_position: u64 = 0, before_ordinal: u64 = 0 };

pub fn sessionView(io: anytype, store: []const u8, session: []const u8, cursor: session_view.Cursor, reply_buffer: *ReplyBuffer) !session_view.Page {
    try validateConversationSession(session);
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), store);
    var body: protocol.RequestBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"session_view\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"session\":");
    try body.appendJsonString(session);
    try body.appendFmt(",\"end\":\"{d}\",\"position\":\"{d}\",\"ordinal\":\"{d}\",\"recent\":{s}}}", .{ cursor.end, cursor.position, cursor.ordinal, if (cursor.recent) "true" else "false" });
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(io, address, null);
    defer closeRequest(io, fd);
    try sendReadRequest(io, fd, "/v1/session-view", body.slice());
    const head = try readResponseHeadUntil(io, fd, 60_000, null);
    if (head.kind != .command_json) return error.InvalidResponse;
    if (head.status != 200) {
        try checkCanonicalFailure(try readCommandBodyUntil(io, fd, head, reply_buffer, null));
        return error.SessionViewUnavailable;
    }
    if (head.content_length > session_view.response_bytes) return error.ResponseTooLarge;
    var bytes: [session_view.response_bytes]u8 = undefined;
    var offset: usize = 0;
    const length: usize = @intCast(head.content_length);
    while (offset < length) {
        const count = try readRequest(io, fd, bytes[offset..length], 60_000, null);
        if (count == 0) return error.TruncatedResponse;
        offset += count;
    }
    return session_view.decode(bytes[0..length], cursor);
}

/// Streams a bounded public page into an unlinked caller-owned file.
pub fn conversationPage(io: anytype, store: []const u8, session: []const u8, cursor: ConversationCursor, destination: std.Io.File, reply_buffer: *ReplyBuffer) !ReportReply {
    try validateConversationSession(session);
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), store);
    var body: protocol.RequestBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"conversation_page\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"session\":");
    try body.appendJsonString(session);
    try body.appendFmt(",\"end\":\"{d}\",\"before_position\":\"{d}\",\"before_ordinal\":\"{d}\"}}", .{ cursor.end, cursor.before_position, cursor.before_ordinal });
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(io, address, null);
    defer closeRequest(io, fd);
    try sendReadRequest(io, fd, "/v1/conversation-page", body.slice());
    return readReportResponse(io, fd, destination, reply_buffer);
}

pub const ConversationRange = struct { total: u64, next: u64 };

/// Streams complete public name/arguments, including rejected proposals. A
/// failed transfer may have delivered a prefix, never a complete saved value.
pub fn sessionCallContentStream(io: anytype, store: []const u8, session: []const u8, position: u64, field: protocol.SessionCallContent.Field, destination: anytype, reply_buffer: *ReplyBuffer) !u64 {
    return (try sourceContentRead(io, store, session, .{ .call = .{ .position = position, .field = field } }, 0, true, protocol.content_window_bytes, null, destination, reply_buffer)).total;
}

/// Reads an exact admission, whether pending, applied or excluded. The returned
/// bytes borrow destination; identities do not depend on text equality.
pub fn messageContent(io: anytype, store: []const u8, session: []const u8, admission_id: u64, start: u64, destination: []u8, reply_buffer: *ReplyBuffer) !ConversationRange {
    if (destination.len == 0 or destination.len > protocol.content_window_bytes) return error.InvalidRange;
    return sourceContentRead(io, store, session, .{ .message = admission_id }, start, false, destination.len, null, destination, reply_buffer);
}

/// Synchronously delivers complete content using the existing bounded sink
/// adapter, binding its header to the expected saved length before delivery.
/// A failed transfer may leave a prefix in the caller's sink.
pub fn messageContentStream(io: anytype, store: []const u8, session: []const u8, admission_id: u64, expected_total: u64, destination: anytype, reply_buffer: *ReplyBuffer) !u64 {
    return (try sourceContentRead(io, store, session, .{ .message = admission_id }, 0, true, protocol.content_window_bytes, expected_total, destination, reply_buffer)).total;
}

const ContentSource = union(enum) {
    call: struct { position: u64, field: protocol.SessionCallContent.Field },
    message: u64,
};

fn sourceContentRead(io: anytype, store: []const u8, session: []const u8, source: ContentSource, start: u64, stream_all: bool, length: usize, expected_total: ?u64, destination: anytype, reply_buffer: *ReplyBuffer) !ConversationRange {
    try validateConversationSession(session);
    const position = switch (source) {
        .call => |value| value.position,
        .message => |value| value,
    };
    if (position == 0 or position > std.math.maxInt(i64)) return error.InvalidCursor;
    const kind: []const u8 = switch (source) {
        .call => "session_call_content",
        .message => "message_content",
    };
    const route: []const u8 = switch (source) {
        .call => "/v1/session-call-content",
        .message => "/v1/message-content",
    };
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), store);
    var body: protocol.RequestBuffer = .{};
    try body.appendFmt("{{\"version\":\"1\",\"kind\":\"{s}\",\"store\":", .{kind});
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"session\":");
    try body.appendJsonString(session);
    switch (source) {
        .call => |value| try body.appendFmt(",\"position\":\"{d}\",\"field\":\"{s}\",\"start\":\"{d}\"", .{ position, @tagName(value.field), start }),
        .message => try body.appendFmt(",\"admission_id\":\"{d}\",\"start\":\"{d}\"", .{ position, start }),
    }
    if (stream_all) try body.append(",\"stream\":true}") else try body.appendFmt(",\"length\":\"{d}\"}}", .{length});
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(io, address, null);
    defer closeRequest(io, fd);
    try sendReadRequest(io, fd, route, body.slice());
    return readPublicContentResponse(io, fd, start, stream_all, length, expected_total, destination, reply_buffer);
}

/// Appends exactly one (at most 4 KiB) byte range to destination. The caller
/// owns the file and follows next until total, including split UTF-8 scalars.
pub fn conversationContent(io: anytype, store: []const u8, session: []const u8, position: u64, ordinal: u64, start: u64, destination: std.Io.File, reply_buffer: *ReplyBuffer) !ConversationRange {
    return conversationContentRead(io, store, session, position, ordinal, start, false, null, destination, reply_buffer);
}

/// Copies one exact public item through one sequential Host reader. On error
/// the caller's output may contain a prefix and must not be treated as complete.
/// Snapshot callers supply expected_total; raw exports have no prior length.
pub fn conversationContentStream(io: anytype, store: []const u8, session: []const u8, position: u64, ordinal: u64, expected_total: ?u64, destination: anytype, reply_buffer: *ReplyBuffer) !u64 {
    const result = try conversationContentRead(io, store, session, position, ordinal, 0, true, expected_total, destination, reply_buffer);
    return result.total;
}

fn conversationContentRead(io: anytype, store: []const u8, session: []const u8, position: u64, ordinal: u64, start: u64, stream_all: bool, expected_total: ?u64, destination: anytype, reply_buffer: *ReplyBuffer) !ConversationRange {
    try validateConversationSession(session);
    if (position == 0) return error.InvalidCursor;
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), store);
    var body: protocol.RequestBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"conversation_content\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"session\":");
    try body.appendJsonString(session);
    if (stream_all)
        try body.appendFmt(",\"position\":\"{d}\",\"ordinal\":\"{d}\",\"start\":\"0\",\"stream\":true}}", .{ position, ordinal })
    else
        try body.appendFmt(",\"position\":\"{d}\",\"ordinal\":\"{d}\",\"start\":\"{d}\"}}", .{ position, ordinal, start });
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(io, address, null);
    defer closeRequest(io, fd);
    try sendReadRequest(io, fd, "/v1/conversation-content", body.slice());
    return readPublicContentResponse(io, fd, start, stream_all, protocol.content_window_bytes, expected_total, destination, reply_buffer);
}

fn readPublicContentResponse(io: anytype, fd: std.posix.fd_t, start: u64, stream_all: bool, length: usize, expected_total: ?u64, destination: anytype, reply_buffer: *ReplyBuffer) !ConversationRange {
    reply_buffer.len = 0;
    const head = try readResponseHeadUntil(io, fd, 60_000, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        try checkCanonicalFailure(try readCommandBodyUntil(io, fd, head, reply_buffer, null));
        return error.ConversationUnavailable;
    }
    if (head.kind != .content_bytes) return error.InvalidResponse;
    const total = head.total orelse return error.InvalidResponse;
    if (expected_total) |expected| if (total != expected) return error.InvalidResponse;
    const next = head.next orelse return error.InvalidResponse;
    if (start > total) return error.InvalidResponse;
    if (!stream_all and head.content_length != @min(length, total - start)) return error.InvalidResponse;
    if (next < start or next - start != head.content_length or next > total or (stream_all and next != total)) return error.InvalidResponse;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var remaining = head.content_length;
    while (remaining != 0) {
        const count = try readRequest(io, fd, buffer[0..@intCast(@min(remaining, buffer.len))], 60_000, null);
        if (count == 0) return error.TruncatedResponse;
        if (@TypeOf(destination) == []u8) {
            const offset: usize = @intCast(head.content_length - remaining);
            @memcpy(destination[offset..][0..count], buffer[0..count]);
        } else if (@TypeOf(destination) == std.Io.File or !@hasDecl(@typeInfo(@TypeOf(destination)).pointer.child, "feed")) {
            try destination.writeStreamingAll(requestIo(io), buffer[0..count]);
        } else try destination.feed(buffer[0..count]);
        remaining -= count;
    }
    return .{ .total = total, .next = next };
}

fn validateConversationSession(session: []const u8) !void {
    if (session.len == 0 or session.len > protocol.max_session_bytes or !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
}

fn sendReadRequest(io: anytype, fd: std.posix.fd_t, route: []const u8, body: []const u8) !void {
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{ route, body.len });
    try writeAllUntil(io, fd, header, null);
    try writeAllUntil(io, fd, body, null);
}

pub fn readActionArguments(
    io: anytype,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return readActionContent(io, store_path, session, action_id, "read_action_arguments", "/v1/read-action-arguments", destination, reply_buffer);
}

pub fn readActionCallId(
    io: anytype,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return readActionContent(io, store_path, session, action_id, "read_action_call_id", "/v1/read-action-call-id", destination, reply_buffer);
}

fn readActionContent(
    io: anytype,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    comptime kind: []const u8,
    comptime route: []const u8,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    reply_buffer.len = 0;
    if (session.len == 0 or session.len > protocol.max_session_bytes or action_id == 0) return error.InvalidTarget;
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, kind, paths.store.slice(), "session", session, action_id, null);
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(io, address, null);
    defer closeRequest(io, fd);
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{ route, body.len });
    try writeAllUntil(io, fd, header, null);
    try writeAllUntil(io, fd, body.slice(), null);
    return readResultResponse(io, fd, destination, reply_buffer);
}

fn validateIdentityInputs(key: []const u8, session: []const u8) !void {
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    if (session.len == 0 or session.len > protocol.max_session_bytes or
        !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
}

pub const CapturedIdentity = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    kind: protocol.Bounded(32) = .{},
};

pub const CaptureTarget = union(enum) {
    generated: []const u8, // Caller-selected private directory, not HOME policy.
    explicit: struct { record: []const u8, key: []const u8 },

    fn resolve(self: CaptureTarget, io: std.Io, path: []u8, key: *[36]u8) !@FieldType(CaptureTarget, "explicit") {
        return switch (self) {
            .explicit => |value| value,
            .generated => |directory| blk: {
                var bytes: [16]u8 = undefined;
                try std.Io.randomSecure(io, &bytes);
                bytes[6] = (bytes[6] & 0x0f) | 0x40;
                bytes[8] = (bytes[8] & 0x3f) | 0x80;
                const id = try std.fmt.bufPrint(key, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
                    std.mem.readInt(u32, bytes[0..4], .big),
                    std.mem.readInt(u16, bytes[4..6], .big),
                    std.mem.readInt(u16, bytes[6..8], .big),
                    std.mem.readInt(u16, bytes[8..10], .big),
                    std.mem.readInt(u48, bytes[10..16], .big),
                });
                break :blk .{ .record = try requestPath(directory, id, path), .key = id };
            },
        };
    }
};

// Owns one read-only descriptor, never the saved name's deletion. Identity
// borrows this value and remains available after any send failure. Do not copy
// the live owner; close once after the last send/identity consumer.
pub const CapturedRecord = struct {
    file: std.Io.File,
    length: u64,
    saved: CapturedIdentity,

    pub fn identity(self: *const CapturedRecord) *const CapturedIdentity {
        return &self.saved;
    }

    pub fn close(self: *CapturedRecord, io: std.Io) void {
        self.file.close(io);
        self.* = undefined;
    }
};

pub fn validRequestHandle(handle: []const u8) bool {
    if (handle.len != 36) return false;
    for (handle, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn requestPath(directory: []const u8, handle: []const u8, buffer: []u8) ![]const u8 {
    if (!validRequestHandle(handle)) return error.InvalidRequestHandle;
    return std.fmt.bufPrint(buffer, "{s}/{s}.json", .{ directory, handle });
}

// Generated recovery intentionally supports only configure/message/permission
// decisions. Stop/interruption retain the explicit retry route, not a new parser.
pub fn openCaptured(io: std.Io, directory: []const u8, handle: []const u8) !CapturedRecord {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(directory, handle, &path_buffer);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    const saved = try readCapturedIdentity(io, &file, handle);
    _ = try capturedRoute(&saved);
    return .{ .file = file, .length = try file.length(io), .saved = saved };
}

fn capturedRoute(saved: *const CapturedIdentity) ![]const u8 {
    if (saved.kind.eql("configure")) return "/v1/configure";
    if (saved.kind.eql("message")) return "/v1/message";
    if (saved.kind.eql("permission_decision")) return "/v1/control/permission-decision";
    return error.InvalidRequestRecord;
}

pub fn sendCaptured(io: anytype, captured: *const CapturedRecord, drop_reply: ?[]const u8, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    try checkCancellation(io);
    const paths = try platform.resolveClientPaths(requestIo(io), captured.saved.store.slice());
    return sendSource(io, &paths, try capturedRoute(&captured.saved), captured.length, &captured.file, null, drop_reply, null, reply_buffer, null);
}

// Capture writes identity first, before variable content. Recover the bounded
// prefix without loading or copying the potentially large captured payload.
fn readCapturedIdentity(io: std.Io, file: *std.Io.File, handle: []const u8) !CapturedIdentity {
    const header_bytes = 6 * (protocol.max_store_bytes + protocol.max_key_bytes + protocol.max_session_bytes) + 256;
    var buffer: [header_bytes]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    const prefix = buffer[0..count];
    const kind_marker = std.mem.indexOf(u8, prefix, ",\"configuration\"") orelse
        std.mem.indexOf(u8, prefix, ",\"text\"") orelse
        std.mem.indexOf(u8, prefix, ",\"decision\"") orelse
        return error.InvalidRequestRecord;
    var head: [header_bytes]u8 = undefined;
    if (kind_marker + 1 > head.len) return error.InvalidRequestRecord;
    @memcpy(head[0..kind_marker], prefix[0..kind_marker]);
    head[kind_marker] = '}';
    const Fields = struct {
        version: []const u8,
        kind: []const u8,
        store: []const u8,
        key: []const u8,
        session: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Fields, std.heap.c_allocator, head[0 .. kind_marker + 1], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.version, "1") or !std.mem.eql(u8, parsed.value.key, handle)) return error.InvalidRequestRecord;
    var identity: CapturedIdentity = .{};
    try identity.store.set(parsed.value.store);
    try identity.key.set(parsed.value.key);
    try identity.session.set(parsed.value.session);
    try identity.kind.set(parsed.value.kind);
    return identity;
}

pub fn captureConfigure(io: std.Io, input: ConfigureInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    var session_buffer: ["rui/".len + protocol.max_key_bytes]u8 = undefined;
    const session = switch (input.session) {
        .named => |name| name,
        .from_capture_key => try std.fmt.bufPrint(&session_buffer, "rui/{s}", .{location.key}),
    };
    try validateIdentityInputs(location.key, session);
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"configure\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(location.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(session);
    try capture.write(",\"configuration\":{\"workspace\":");
    try capture.writeOptionalText(input.workspace);
    try capture.write(",\"provider\":");
    try capture.writeOptionalText(input.provider);
    try capture.write(",\"model\":");
    try capture.writeOptionalText(input.model);
    try capture.write(",\"instructions\":");
    try capture.writeOptionalFile(input.instructions, false);
    try capture.write(",\"tools\":");
    try capture.writeTools(input.tools);
    try capture.write(",\"permission_mode\":");
    try capture.writeOptionalText(input.permission_mode);
    try capture.write(",\"output_schema\":");
    try capture.writeOptionalFile(input.output_schema, true);
    try capture.write(if (input.require_model) "},\"require_model\":true}" else "}}");
    return finishCapture(io, &capture, paths.store.slice(), location.key, session, "configure");
}

pub fn captureMessage(io: std.Io, input: MessageInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try validateIdentityInputs(location.key, input.session);
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"message\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(location.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
    try capture.write(",\"text\":{\"state\":\"value\",\"value\":");
    if (input.text) |value| {
        if (value.len > protocol.max_sqlite_content_bytes) return error.ContentTooLarge;
        try capture.writeJsonString(value);
    } else try capture.writeJsonFile(input.text_path);
    try capture.write("}}");
    return finishCapture(io, &capture, paths.store.slice(), location.key, input.session, "message");
}

fn captureSessionStop(io: std.Io, paths: *const platform.Paths, input: SessionStopInput) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, input.record, &output_buffer);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"session_stop\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(input.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
    try capture.write("}");
    try capture.commit();
}

fn captureModelInterruption(
    io: std.Io,
    paths: *const platform.Paths,
    input: ModelInterruptionInput,
) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, input.record, &output_buffer);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"model_interruption\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(input.key);
    try capture.write(",\"target\":{\"session\":");
    try capture.writeJsonString(input.session);
    var ids: [96]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&ids, ",\"turn\":\"{d}\",\"operation\":\"{d}\"}}}}", .{
        input.turn_id,
        input.operation_id,
    });
    try capture.write(suffix);
    try capture.commit();
}

pub fn capturePermissionDecision(io: std.Io, input: PermissionDecisionInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try validateIdentityInputs(location.key, input.session);
    if (input.action_id == 0) return error.InvalidTarget;
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writePermissionDecision(paths.store.slice(), location.key, input);
    return finishCapture(io, &capture, paths.store.slice(), location.key, input.session, "permission_decision");
}

fn finishCapture(io: std.Io, capture: *Capture, store: []const u8, key: []const u8, session: []const u8, kind: []const u8) !CapturedRecord {
    var saved: CapturedIdentity = .{};
    try saved.store.set(store);
    try saved.key.set(key);
    try saved.session.set(session);
    try saved.kind.set(kind);
    // Pin the temporary inode under capture custody, before exposing its name.
    // This reader observes the final flush, not a later public-path replacement.
    var file = try capture.parent.openFile(io, capture.temporary_name.slice(), .{});
    errdefer file.close(io);
    // A post-publication directory-sync failure returns no transmissible owner,
    // but abort preserves the published name for later explicit recovery.
    try capture.commit();
    return .{ .file = file, .length = try file.length(io), .saved = saved };
}

const Capture = struct {
    io: std.Io,
    file: std.Io.File,
    lock_file: std.Io.File,
    parent: std.Io.Dir,
    writer: std.Io.File.Writer,
    final_name: protocol.Bounded(std.Io.Dir.max_name_bytes) = .{},
    temporary_name: protocol.Bounded(std.Io.Dir.max_name_bytes) = .{},
    active: bool = true,
    file_open: bool = true,
    published: bool = false,

    // The caller owns buffer through commit/abort and keeps Capture pointer-stable.
    fn open(io: std.Io, record_path: []const u8, buffer: []u8) !Capture {
        const parent_path = std.fs.path.dirname(record_path) orelse ".";
        const final_name = std.fs.path.basename(record_path);
        if (final_name.len == 0) return error.InvalidRecordPath;
        var parent = try std.Io.Dir.cwd().createDirPathOpen(io, parent_path, .{
            // Linux opens non-iterable directories with O_PATH, which cannot
            // be fsynced after publishing the record.
            .open_options = .{ .iterate = true },
            .permissions = .fromMode(0o700),
        });
        errdefer parent.close(io);
        const stat = try parent.stat(io);
        if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
        var lock_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const lock_name = try std.fmt.bufPrint(&lock_buffer, ".{s}.capture.lock", .{final_name});
        const lock_file = parent.createFile(io, lock_name, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock => return error.RecordCaptureBusy,
            else => return err,
        };
        errdefer lock_file.close(io);
        if (parent.statFile(io, final_name, .{})) |_| return error.RecordAlreadyExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        var temporary_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const temporary = try std.fmt.bufPrint(&temporary_buffer, ".{s}.capture.tmp", .{final_name});
        // This stable lock also owns recovery. Never unlink its inode: another
        // opener could otherwise acquire an unrelated lock for the same record.
        parent.deleteFile(io, temporary) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const file = try parent.createFile(io, temporary, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        var capture = Capture{ .io = io, .file = file, .lock_file = lock_file, .parent = parent, .writer = file.writerStreaming(io, buffer) };
        try capture.final_name.set(final_name);
        try capture.temporary_name.set(temporary);
        return capture;
    }

    fn abort(self: *Capture) void {
        if (!self.active) return;
        if (self.file_open) self.file.close(self.io);
        if (!self.published) self.parent.deleteFile(self.io, self.temporary_name.slice()) catch |err| {
            std.debug.print("rui: retained caller capture after cleanup failure: {s}\n", .{@errorName(err)});
        };
        self.lock_file.close(self.io);
        self.parent.close(self.io);
        self.active = false;
    }

    fn commit(self: *Capture) !void {
        try self.writer.flush();
        try self.file.sync(self.io);
        self.file.close(self.io);
        self.file_open = false;
        try self.parent.renamePreserve(
            self.temporary_name.slice(),
            self.parent,
            self.final_name.slice(),
            self.io,
        );
        self.published = true;
        if (std.c.fsync(self.parent.handle) != 0) return error.RecordDirectorySyncFailed;
        self.lock_file.close(self.io);
        self.parent.close(self.io);
        self.active = false;
    }

    fn write(self: *Capture, bytes: []const u8) !void {
        self.writer.interface.writeAll(bytes) catch return self.writer.err orelse error.WriteFailed;
    }

    fn writeJsonString(self: *Capture, value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        std.json.Stringify.encodeJsonString(value, .{}, &self.writer.interface) catch
            return self.writer.err orelse error.WriteFailed;
    }

    fn writePermissionDecision(self: *Capture, store: []const u8, key: []const u8, input: PermissionDecisionInput) !void {
        try self.write("{\"version\":\"1\",\"kind\":\"permission_decision\",\"store\":");
        try self.writeJsonString(store);
        try self.write(",\"key\":");
        try self.writeJsonString(key);
        try self.write(",\"session\":");
        try self.writeJsonString(input.session);
        var suffix: [96]u8 = undefined;
        try self.write(try std.fmt.bufPrint(&suffix, ",\"action\":\"{d}\",\"decision\":\"{s}\"}}", .{
            input.action_id,
            @tagName(input.decision),
        }));
    }

    fn writeOptionalText(self: *Capture, value: OptionalText) !void {
        if (!value.present) return self.write("{\"state\":\"omitted\"}");
        try self.write("{\"state\":\"value\",\"value\":");
        try self.writeJsonString(value.value);
        try self.write("}");
    }

    fn writeOptionalFile(self: *Capture, value: OptionalFile, allow_null: bool) !void {
        switch (value.state) {
            .omitted => try self.write("{\"state\":\"omitted\"}"),
            .explicit_null => {
                if (!allow_null) return error.NullNotAllowed;
                try self.write("{\"state\":\"null\"}");
            },
            .value => {
                try self.write("{\"state\":\"value\",\"value\":");
                try self.writeJsonFile(value.path);
                try self.write("}");
            },
        }
    }

    fn writeJsonFile(self: *Capture, path: []const u8) !void {
        return self.writeJsonFileBounded(path, protocol.max_sqlite_content_bytes);
    }

    fn writeJsonFileBounded(self: *Capture, path: []const u8, limit: u64) !void {
        var file = if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdin()
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer if (!std.mem.eql(u8, path, "-")) file.close(self.io);
        try self.write("\"");
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var validator = Utf8Validator{};
        var decoded_bytes: u64 = 0;
        while (true) {
            const count = file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (count == 0) break;
            const next = std.math.add(u64, decoded_bytes, count) catch return error.ContentTooLarge;
            if (next > limit) return error.ContentTooLarge;
            decoded_bytes = next;
            try validator.feed(buffer[0..count]);
            // Default encoding copies non-ASCII bytes unchanged, including a UTF-8
            // sequence split across reads; the streaming validator owns validity.
            std.json.Stringify.encodeJsonStringChars(buffer[0..count], .{}, &self.writer.interface) catch
                return self.writer.err orelse error.WriteFailed;
        }
        if (!validator.complete()) return error.InvalidUtf8;
        try self.write("\"");
    }

    fn writeTools(self: *Capture, tools: ?[]const u8) !void {
        const value = tools orelse return self.write("{\"state\":\"omitted\"}");
        try self.write("{\"state\":\"value\",\"value\":[");
        if (!std.mem.eql(u8, value, "none")) {
            var iterator = std.mem.splitScalar(u8, value, ',');
            var count: usize = 0;
            var seen_bash = false;
            var seen_edit = false;
            while (iterator.next()) |tool| {
                if (count != 0) try self.write(",");
                if (std.mem.eql(u8, tool, "bash")) {
                    if (seen_bash) return error.DuplicateTool;
                    seen_bash = true;
                } else if (std.mem.eql(u8, tool, "edit")) {
                    if (seen_edit) return error.DuplicateTool;
                    seen_edit = true;
                } else return error.UnknownTool;
                try self.writeJsonString(tool);
                count += 1;
                if (count > 2) return error.TooManyTools;
            }
        }
        try self.write("]}");
    }
};

const Utf8Validator = struct {
    bytes: [4]u8 = undefined,
    used: u3 = 0,
    expected: u3 = 0,

    fn feed(self: *Utf8Validator, input: []const u8) !void {
        for (input) |byte| {
            if (self.used == 0) {
                if (byte < 0x80) continue;
                self.expected = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
            }
            self.bytes[self.used] = byte;
            self.used += 1;
            if (self.used == self.expected) {
                _ = std.unicode.utf8Decode(self.bytes[0..self.expected]) catch return error.InvalidUtf8;
                self.used = 0;
                self.expected = 0;
            }
        }
    }

    fn complete(self: *const Utf8Validator) bool {
        return self.used == 0;
    }
};

fn sendRecord(
    io: std.Io,
    paths: *const platform.Paths,
    record: []const u8,
    route: []const u8,
    drop_reply: ?[]const u8,
    reply_buffer: *ReplyBuffer,
) !CommandReply {
    var file = try std.Io.Dir.cwd().openFile(io, record, .{});
    defer file.close(io);
    const length = try file.length(io);
    return sendSource(io, paths, route, length, &file, null, drop_reply, null, reply_buffer, null);
}

fn sendBytes(
    io: anytype,
    paths: *const platform.Paths,
    route: []const u8,
    body: []const u8,
    drop_reply: ?[]const u8,
    reply_buffer: *ReplyBuffer,
) !CommandReply {
    return sendSource(io, paths, route, body.len, null, body, drop_reply, null, reply_buffer, null);
}

fn sendSource(
    io: anytype,
    paths: *const platform.Paths,
    route: []const u8,
    length: u64,
    file: ?*const std.Io.File,
    bytes: ?[]const u8,
    drop_reply: ?[]const u8,
    instance: ?*const protocol.InstanceId,
    reply_buffer: *ReplyBuffer,
    until: ?i128,
) !CommandReply {
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(io, address, until);
    defer closeRequest(io, fd);
    var header_buffer: [512]u8 = undefined;
    var used = (try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n", .{ route, length })).len;
    if (instance) |id| {
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Host-Instance: {s}\r\n", .{std.fmt.bytesToHex(id.*, .lower)})).len;
    }
    if (drop_reply) |drop| {
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Test-Drop-Reply: {s}\r\n", .{drop})).len;
    }
    used += (try std.fmt.bufPrint(header_buffer[used..], "\r\n", .{})).len;
    try writeAllUntil(io, fd, header_buffer[0..used], until);
    if (file) |source| {
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var sent: u64 = 0;
        while (sent < length) {
            try checkCancellation(io);
            const wanted: usize = @intCast(@min(length - sent, buffer.len));
            const count = try source.readPositionalAll(requestIo(io), buffer[0..wanted], sent);
            if (count != wanted) return error.RecordChangedDuringSend;
            try writeAllUntil(io, fd, buffer[0..count], until);
            sent += count;
        }
    } else try writeAllUntil(io, fd, bytes.?, until);
    return readCommandResponseUntil(io, fd, reply_buffer, until);
}

fn connectRequest(io: anytype, address: std.Io.net.UnixAddress, until: ?i128) !std.posix.fd_t {
    try checkCancellation(io);
    if (until != null or cancellable(io)) return connectUntil(io, address.path, until);
    return (try address.connect(requestIo(io))).socket.handle;
}

fn closeRequest(io: anytype, fd: std.posix.fd_t) void {
    const base = requestIo(io);
    base.vtable.netClose(base.userdata, &.{fd});
}

fn addNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblocking: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @intCast(nonblocking))) < 0) return error.UnixConnectFailed;
}

fn connectUntil(io: anytype, path: []const u8, deadline: ?i128) !std.posix.fd_t {
    try checkCancellation(io);
    if (deadline) |end| if (requestNow(io) >= end) return error.TransferInactive;
    const fd = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(fd) != .SUCCESS) return error.UnixConnectFailed;
    const socket: std.posix.fd_t = @intCast(fd);
    errdefer _ = std.c.close(socket);
    if (std.c.fcntl(socket, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.UnixConnectFailed;
    try addNonblocking(socket);
    var address: std.posix.sockaddr.un = .{ .path = undefined };
    @memcpy(address.path[0..path.len], path);
    address.path[path.len] = 0;
    const size: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1);
    if (@hasField(std.posix.sockaddr.un, "len")) address.len = @intCast(size);
    while (true) {
        try checkCancellation(io);
        if (deadline) |end| if (requestNow(io) >= end) return error.TransferInactive;
        switch (std.posix.errno(std.c.connect(socket, @ptrCast(&address), size))) {
            .SUCCESS => break,
            .INPROGRESS, .INTR => {
                if (!try waitRequest(io, socket, std.posix.POLL.OUT, deadline)) return error.TransferInactive;
                var result: c_int = 0;
                var result_len: std.posix.socklen_t = @sizeOf(c_int);
                if (std.c.getsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &result, &result_len) < 0 or result_len != @sizeOf(c_int) or result < 0) return error.UnixConnectFailed;
                if (result != 0) return connectFailure(@enumFromInt(result));
                break;
            },
            .AGAIN => {
                // Linux AF_UNIX full backlog has not initiated a connection:
                // POLLOUT/HUP and SO_ERROR=0 do not mean connected. Continue
                // the same socket's connect after a service quantum; no new
                // socket, request transmission, deadline or exchange retry.
                var milliseconds: c_int = 100;
                if (deadline) |end| milliseconds = @intCast(@min(milliseconds, @divTrunc(end - requestNow(io) + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
                if (milliseconds <= 0) return error.TransferInactive;
                var no_descriptors: [0]std.c.pollfd = .{};
                const waited = std.c.poll(&no_descriptors, 0, milliseconds);
                switch (std.posix.errno(waited)) {
                    .SUCCESS, .INTR => {},
                    else => return error.PollFailed,
                }
            },
            else => |err| return connectFailure(err),
        }
    }
    try checkCancellation(io);
    // The requesting worker owns this nonblocking descriptor through its final
    // body byte; a writable/readable poll must not become an unbounded syscall.
    return socket;
}

fn connectFailure(code: std.posix.E) error{ AccessDenied, PermissionDenied, UnixConnectFailed } {
    return switch (code) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        else => error.UnixConnectFailed,
    };
}

const ResponseKind = enum { command_json, result_text, content_bytes };

const ResponseHead = struct {
    status: u16,
    content_length: u64,
    kind: ResponseKind,
    total: ?u64 = null,
    next: ?u64 = null,
};

fn readResponseHead(fd: std.posix.fd_t) !ResponseHead {
    return readResponseHeadWithInactivity(fd, 60_000);
}

fn readResponseHeadWithInactivity(fd: std.posix.fd_t, inactivity_ms: i32) !ResponseHead {
    return readResponseHeadUntil(std.Io.Threaded.global_single_threaded.io(), fd, inactivity_ms, null);
}

fn readResponseHeadUntil(io: anytype, fd: std.posix.fd_t, inactivity_ms: i32, until: ?i128) !ResponseHead {
    var header_buffer: [protocol.max_header_bytes]u8 = undefined;
    // Ordinary requests start their inactivity window after the first byte;
    // Host readiness alone has an absolute deadline that includes this wait.
    const first_count = try readRequest(io, fd, header_buffer[0..1], null, until);
    if (first_count == 0) return error.TruncatedResponse;
    var used: usize = first_count;
    while (used < header_buffer.len) {
        if (used >= 4 and std.mem.eql(u8, header_buffer[used - 4 .. used], "\r\n\r\n")) break;
        const count = try readRequest(io, fd, header_buffer[used .. used + 1], inactivity_ms, until);
        if (count == 0) return error.TruncatedResponse;
        used += count;
    } else return error.ResponseHeaderTooLarge;
    return parseResponseHead(header_buffer[0..used]);
}

// Rui uses Content-Length framing. Validate the entire bounded header before
// interpreting any field; an ignored extension cannot repair invalid syntax.
fn parseResponseHead(bytes: []const u8) !ResponseHead {
    if (!std.mem.endsWith(u8, bytes, "\r\n\r\n")) return error.InvalidResponse;
    var lines = std.mem.splitSequence(u8, bytes[0 .. bytes.len - 4], "\r\n");
    const status_line = lines.next() orelse return error.InvalidResponse;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") or status_line.len < "HTTP/1.1 200 X".len or
        status_line[12] != ' ' or std.mem.trim(u8, status_line[13..], " \t").len == 0) return error.InvalidResponse;
    const code = status_line[9..12];
    for (code) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidResponse;
    for (status_line[13..]) |byte| if ((byte < ' ' and byte != '\t') or byte == 0x7f) return error.InvalidResponse;
    const status = try std.fmt.parseInt(u16, code, 10);
    var length: ?u64 = null;
    var wire_ok: ?bool = null;
    var kind: ?ResponseKind = null;
    var total: ?u64 = null;
    var next: ?u64 = null;
    while (lines.next()) |line| {
        if (line.len == 0) return error.InvalidResponse;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
        const name = line[0..colon];
        if (name.len == 0) return error.InvalidResponse;
        for (name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
                return error.InvalidResponse;
        }
        for (line[colon + 1 ..]) |byte| {
            if (byte != '\t' and (byte < ' ' or byte == 0x7f)) return error.InvalidResponse;
        }
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (length != null) return error.InvalidResponse;
            if (value.len == 0) return error.InvalidResponse;
            for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidResponse;
            length = std.fmt.parseInt(u64, value, 10) catch return error.InvalidResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Wire-Version")) {
            if (wire_ok != null) return error.InvalidResponse;
            wire_ok = std.mem.eql(u8, value, protocol.wire_version);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Content-Bytes")) {
            if (total != null) return error.InvalidResponse;
            total = try std.fmt.parseInt(u64, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Next-Offset")) {
            if (next != null) return error.InvalidResponse;
            next = try std.fmt.parseInt(u64, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            if (kind != null) return error.InvalidResponse;
            kind = if (std.ascii.eqlIgnoreCase(value, "application/json"))
                .command_json
            else if (std.ascii.eqlIgnoreCase(value, "text/plain; charset=utf-8"))
                .result_text
            else if (std.ascii.eqlIgnoreCase(value, "application/octet-stream"))
                .content_bytes
            else
                return error.InvalidResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or
            std.ascii.eqlIgnoreCase(name, "Content-Encoding"))
        {
            return error.InvalidResponse;
        }
    }
    if (wire_ok != true) return error.WrongWireVersion;
    return .{
        .status = status,
        .content_length = length orelse return error.InvalidResponse,
        .kind = kind orelse return error.InvalidResponse,
        .total = total,
        .next = next,
    };
}

fn readCommandResponse(fd: std.posix.fd_t, reply_buffer: *ReplyBuffer) !CommandReply {
    return readCommandResponseUntil(std.Io.Threaded.global_single_threaded.io(), fd, reply_buffer, null);
}

fn readCommandResponseUntil(io: anytype, fd: std.posix.fd_t, reply_buffer: *ReplyBuffer, until: ?i128) !CommandReply {
    reply_buffer.len = 0;
    const head = try readResponseHeadUntil(io, fd, 60_000, until);
    if (head.kind != .command_json) return error.InvalidResponse;
    return readCommandBodyUntil(io, fd, head, reply_buffer, until);
}

fn readResultResponse(
    io: anytype,
    fd: std.posix.fd_t,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return readResultResponseSink(io, fd, destination, reply_buffer);
}

fn readResultResponseSink(
    io: anytype,
    fd: std.posix.fd_t,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    reply_buffer.len = 0;
    const head = try readResponseHeadUntil(io, fd, 60_000, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        return .{ .command = try readCommandBodyUntil(io, fd, head, reply_buffer, null) };
    }
    if (head.kind != .result_text) return error.InvalidResponse;
    var remaining = head.content_length;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    while (remaining != 0) {
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        const count = try readRequest(io, fd, buffer[0..wanted], 60_000, null);
        if (count == 0) return error.TruncatedResponse;
        if (@TypeOf(sink) == std.Io.File)
            try sink.writeStreamingAll(requestIo(io), buffer[0..count])
        else
            try sink.feed(buffer[0..count]);
        remaining -= count;
    }
    return .{ .answer = .{ .bytes = head.content_length } };
}

fn readReportResponse(
    io: anytype,
    fd: std.posix.fd_t,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ReportReply {
    reply_buffer.len = 0;
    const head = try readResponseHeadUntil(io, fd, 60_000, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        return .{ .command = try readCommandBodyUntil(io, fd, head, reply_buffer, null) };
    }
    if (head.kind != .command_json) return error.InvalidResponse;
    var remaining = head.content_length;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    while (remaining != 0) {
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        const count = try readRequest(io, fd, buffer[0..wanted], 60_000, null);
        if (count == 0) return error.TruncatedResponse;
        try destination.writeStreamingAll(requestIo(io), buffer[0..count]);
        remaining -= count;
    }
    return .{ .report = .{ .bytes = head.content_length } };
}

fn readCommandBody(fd: std.posix.fd_t, head: ResponseHead, reply_buffer: *ReplyBuffer) !CommandReply {
    return readCommandBodyUntil(std.Io.Threaded.global_single_threaded.io(), fd, head, reply_buffer, null);
}

fn readCommandBodyUntil(io: anytype, fd: std.posix.fd_t, head: ResponseHead, reply_buffer: *ReplyBuffer, until: ?i128) !CommandReply {
    reply_buffer.len = 0;
    errdefer reply_buffer.len = 0;
    if (head.content_length > protocol.max_response_bytes) return error.ResponseTooLarge;
    const body_length: usize = @intCast(head.content_length);
    var offset: usize = 0;
    while (offset < body_length) {
        const count = try readRequest(io, fd, reply_buffer.bytes[offset..body_length], 60_000, until);
        if (count == 0) return error.TruncatedResponse;
        offset += count;
    }
    reply_buffer.len = body_length;
    return .{ .status = head.status, .body = reply_buffer.slice() };
}

// Canonical failure is authority, never an optional presentation outage.
// Scripted/raw command callers can retain the complete error JSON instead.
pub fn checkCanonicalFailure(reply: CommandReply) !void {
    if (reply.status == 200) return;
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const Envelope = struct {
        const Code = enum {
            other,
            canonical,

            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                // A plain []const u8 field also accepts JSON byte arrays.
                if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
                const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                defer if (token == .allocated_string) allocator.free(token.allocated_string);
                const value = switch (token) {
                    .string, .allocated_string => |string| string,
                    else => unreachable,
                };
                return if (std.mem.eql(u8, value, "canonical_store_failure")) .canonical else .other;
            }
        };

        code: Code = .other,
        answer: struct { code: Code = .other } = .{},
    };
    // Reserve nesting first, including malformed N-opening-delimiter prefixes.
    // Names/code decode one byte string at a time and free it before advancing.
    // std.json frees even a matched "answer" name before descending into it.
    // With stack growth excluded, FBA grows/shrinks that last allocation in
    // place. Both byte arrays are bounded by stdlib's capacity growth formula.
    const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) +
        std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
    var storage: [capacity]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();
    var scanner = std.json.Scanner.initCompleteInput(allocator, reply.body);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
    const envelope = std.json.parseFromTokenSourceLeaky(Envelope, allocator, &scanner, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => unreachable, // The bounded-storage proof above covers every input.
        else => return error.InvalidResponse,
    };
    // Unknown values receive full syntax validation but no duplicate-key policy;
    // consequential decoded answer/code fields must be unambiguous.
    if (envelope.code == .canonical or envelope.answer.code == .canonical) return error.CanonicalStoreFailure;
}

test "canonical failure classifier validates complete string-only error envelope" {
    const canonical = [_][]const u8{
        "{\"code\":\"canonical_store_failure\"}",
        "{\"co\\u0064e\":\"canonical_store_\\u0066ailure\",\"extra\":[1,{}]}",
        "{\"code\":\"canonical_store_failure\",\"extra\":{\"x\":1,\"x\":2},\"extra\":null}",
        "{\"answer\":{\"status\":\"infrastructure_failure\",\"code\":\"canonical_store_failure\"}}",
        "{\"answ\\u0065r\":{\"co\\u0064e\":\"canonical_store_\\u0066ailure\"}}",
    };
    for (canonical) |body| try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body }));
    for ([_][]const u8{
        "{\"code\":\"canonical_store_failure\",\"co\\u0064e\":\"other\"}",
        "{\"code\":\"canonical_store_failure\",\"extra\":[}",
        "{\"code\":\"canonical_store_failure\"} trailing",
        "{\"code\":null}",
        "{\"code\":[99,97,110,111,110,105,99,97,108,95,115,116,111,114,101,95,102,97,105,108,117,114,101]}",
        "{\"answer\":{\"code\":\"canonical_store_failure\",\"co\\u0064e\":\"other\"}}",
        "{\"answer\":{\"code\":\"canonical_store_failure\"},\"answ\\u0065r\":{}}",
        "{\"answer\":null}",
        "{\"answer\":{\"code\":null}}",
        "{\"answer\":{\"code\":\"canonical_store_failure\"}} trailing",
        "[]",
    }) |body| try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body }));
    try checkCanonicalFailure(.{ .status = 503, .body = "{\"code\":\"unavailable\"}" });
    try checkCanonicalFailure(.{ .status = 409, .body = "{\"answer\":{\"code\":\"idempotency_key_conflict\"}}" });
    try checkCanonicalFailure(.{ .status = 500, .body = "{\"extra\":{\"code\":\"canonical_store_failure\"}}" });
    try checkCanonicalFailure(.{ .status = 500, .body = "{\"extra\":\"canonical_store_failure\"}" });
    try checkCanonicalFailure(.{ .status = 200, .body = "not an error envelope" });
}

test "nested canonical failure retains bounded escaped-name and depth storage" {
    const prefix = "{\"answ\\u0065r\":{\"co\\u0064e\":\"canonical_store_\\u0066ailure\",\"extra\":";
    var body: [protocol.max_response_bytes]u8 = undefined;
    @memcpy(body[0..prefix.len], prefix);
    const depth = (body.len - prefix.len - 3) / 2;
    @memset(body[prefix.len..][0..depth], '[');
    var length = prefix.len + depth;
    body[length] = '0';
    length += 1;
    @memset(body[length..][0..depth], ']');
    length += depth;
    @memcpy(body[length..][0..2], "}}");
    length += 2;
    @memset(body[length..], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = &body }));
    @memset(body[prefix.len..], '[');
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = &body }));

    const opening = "{\"answ\\u0065r\":{\"";
    const ending = "\":0,\"co\\u0064e\":\"canonical_store_failure\"}}";
    @memcpy(body[0..opening.len], opening);
    length = opening.len;
    while (length + 6 + ending.len <= body.len) : (length += 6) @memcpy(body[length..][0..6], "\\u0061");
    @memcpy(body[length..][0..ending.len], ending);
    length += ending.len;
    @memset(body[length..], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = &body }));
}

test "canonical failure classifier bounds deep wide and escaped maximum replies" {
    const prefix = "{\"code\":\"canonical_store_failure\",\"extra\":";
    var body: [protocol.max_response_bytes + 1]u8 = undefined;
    @memcpy(body[0..prefix.len], prefix);
    const depth = (protocol.max_response_bytes - prefix.len - 2) / 2;
    @memset(body[prefix.len..][0..depth], '[');
    var length = prefix.len + depth;
    body[length] = '0';
    length += 1;
    @memset(body[length..][0..depth], ']');
    length += depth;
    body[length] = '}';
    length += 1;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
    @memset(body[prefix.len..protocol.max_response_bytes], '[');
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));

    // A nearly maximum escaped field name must be released before code decode.
    const field_prefix = "{\"";
    const field_suffix = "\":0,\"co\\u0064e\":\"canonical_store_\\u0066ailure\"}";
    @memcpy(body[0..field_prefix.len], field_prefix);
    length = field_prefix.len;
    const escaped_end = protocol.max_response_bytes - field_suffix.len - 6;
    @memset(body[length..escaped_end], 'x');
    length = escaped_end;
    @memcpy(body[length..][0..6], "\\u0078");
    length += 6;
    @memcpy(body[length..][0..field_suffix.len], field_suffix);
    length += field_suffix.len;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));

    @memcpy(body[0..prefix.len], prefix);
    length = prefix.len;
    const wide = "{\"x\":0,\"x\":0}";
    // Discarded wide objects validate syntax, not irrelevant key uniqueness.
    body[length] = '[';
    length += 1;
    while (length + wide.len + 3 <= protocol.max_response_bytes) {
        @memcpy(body[length..][0..wide.len], wide);
        length += wide.len;
        body[length] = ',';
        length += 1;
    }
    length -= 1;
    @memcpy(body[length..][0..2], "]}");
    length += 2;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
    body[protocol.max_response_bytes] = ' ';
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = &body }));

    @memcpy(body[0..prefix.len], prefix);
    length = prefix.len;
    // Consecutive escaped names must not accumulate decoded allocations.
    const names = "\"ignored\",\"\\u0061\":0,";
    @memcpy(body[length..][0..names.len], names);
    length += names.len;
    const name = "\"\\u0061\":0,";
    while (length + name.len + 1 <= protocol.max_response_bytes) {
        @memcpy(body[length..][0..name.len], name);
        length += name.len;
    }
    length -= 1;
    body[length] = '}';
    length += 1;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
}

fn requestNow(io: anytype) i128 {
    return std.Io.Clock.Timestamp.now(requestIo(io), .awake).raw.nanoseconds;
}

// A quantum is a cancellation service point, not an exchange timeout. Keep
// the same absolute deadline across EINTR, EAGAIN and expired quanta.
fn waitRequest(io: anytype, fd: std.posix.fd_t, events: i16, deadline: ?i128) !bool {
    while (true) {
        try checkCancellation(io);
        var milliseconds: c_int = -1;
        if (deadline) |end| {
            const left = end - requestNow(io);
            if (left <= 0) return false;
            milliseconds = @intCast(@min(std.math.maxInt(c_int), @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        }
        if (cancellable(io)) milliseconds = if (milliseconds < 0) 100 else @min(milliseconds, 100);
        var poll_fd = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const result = std.c.poll(&poll_fd, poll_fd.len, milliseconds);
        try checkCancellation(io);
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result != 0) return true,
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn readRequest(io: anytype, fd: std.posix.fd_t, buffer: []u8, inactivity_ms: ?i32, until: ?i128) !usize {
    try checkCancellation(io);
    const deadline = until orelse if (inactivity_ms) |ms| requestNow(io) + @as(i128, ms) * std.time.ns_per_ms else null;
    while (true) {
        if (!try waitRequest(io, fd, std.posix.POLL.IN, deadline)) return error.ResponseInactive;
        try checkCancellation(io);
        return std.posix.read(fd, buffer) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
    }
}

fn writeAll(fd: std.posix.fd_t, value: []const u8) !void {
    return writeAllUntil(std.Io.Threaded.global_single_threaded.io(), fd, value, null);
}

fn writeAllUntil(io: anytype, fd: std.posix.fd_t, value: []const u8, until: ?i128) !void {
    try checkCancellation(io);
    var offset: usize = 0;
    var deadline = until orelse requestNow(io) + 60 * std.time.ns_per_s;
    while (offset < value.len) {
        if (!try waitRequest(io, fd, std.posix.POLL.OUT, deadline)) return error.TransferInactive;
        try checkCancellation(io);
        const count = std.c.write(fd, value[offset..].ptr, value.len - offset);
        if (count < 0) {
            if (std.posix.errno(count) == .AGAIN or std.posix.errno(count) == .INTR) continue;
            // Request delivery is not terminal presentation. Keep provenance
            // so interactive auxiliary requests may recover without detaching.
            return error.RequestWriteFailed;
        }
        if (count == 0) return error.ConnectionClosed;
        offset += @intCast(count);
        if (until == null) deadline = requestNow(io) + 60 * std.time.ns_per_s;
    }
}

const empty_test_response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "X-Rui-Wire-Version: 1\r\n\r\n";

fn socketPair() ![2]std.posix.fd_t {
    var sockets: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    return sockets;
}

test "request peer closure preserves write failure provenance" {
    // Block SIGPIPE only for this calling thread and consume the generated
    // signal before restoring its ambient mask; do not change disposition.
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, .PIPE);
    var previous: std.posix.sigset_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pthread_sigmask(@intCast(std.posix.SIG.BLOCK), &set, &previous));
    var discarded: std.posix.sigset_t = undefined;
    defer _ = std.c.pthread_sigmask(@intCast(std.posix.SIG.SETMASK), &previous, &discarded);
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    closeTestDescriptor(sockets[1]);
    const result = writeAllUntil(std.testing.io, sockets[0], "actual request bytes", null);
    var signal_number: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 0), std.c.sigwait(&set, &signal_number));
    try std.testing.expectEqual(@as(c_int, @intCast(@intFromEnum(std.posix.SIG.PIPE))), signal_number);
    try std.testing.expectError(error.RequestWriteFailed, result);
}

test "public content rejects short ranges and snapshot mismatches before destination writes" {
    const Sink = struct {
        bytes: [16]u8 = @splat('?'),
        count: usize = 0,
        calls: usize = 0,

        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.count..][0..bytes.len], bytes);
            self.count += bytes.len;
            self.calls += 1;
        }
    };
    const cases = [_]struct { start: u64, total: u64, next: u64, body: []const u8, stream: bool = false, expected_total: ?u64 = null, valid: bool }{
        .{ .start = 0, .total = 100, .next = 1, .body = "x", .valid = false },
        .{ .start = 4, .total = 5, .next = 5, .body = "x", .valid = true },
        .{ .start = 5, .total = 5, .next = 5, .body = "", .valid = true },
        .{ .start = 6, .total = 5, .next = 6, .body = "", .valid = false },
        .{ .start = 0, .total = 9, .next = 9, .body = "123456789", .stream = true, .valid = true },
        .{ .start = 0, .total = 9, .next = 9, .body = "123456789", .stream = true, .expected_total = 9, .valid = true },
        .{ .start = 0, .total = 9, .next = 9, .body = "123456789", .stream = true, .expected_total = 8, .valid = false },
        .{ .start = 0, .total = 9, .next = 9, .body = "123456789", .stream = true, .expected_total = 10, .valid = false },
        .{ .start = 0, .total = 1, .next = 1, .body = "x", .stream = true, .expected_total = 0, .valid = false },
        .{ .start = 0, .total = 0, .next = 0, .body = "", .stream = true, .expected_total = 1, .valid = false },
        .{ .start = 0, .total = 0, .next = 0, .body = "", .stream = true, .expected_total = 0, .valid = true },
    };
    for (cases) |case| inline for ([_]bool{ false, true }) |stream_sink| {
        const sockets = try socketPair();
        defer closeTestDescriptor(sockets[0]);
        defer closeTestDescriptor(sockets[1]);
        var response_buffer: [512]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buffer, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nX-Rui-Wire-Version: 1\r\n\r\n{s}", .{ case.body.len, case.total, case.next, case.body });
        try writeAll(sockets[1], response);
        var destination: [16]u8 = @splat('?');
        var sink: Sink = .{};
        var reply: ReplyBuffer = .{};
        const result = if (stream_sink)
            readPublicContentResponse(std.testing.io, sockets[0], case.start, case.stream, 8, case.expected_total, &sink, &reply)
        else
            readPublicContentResponse(std.testing.io, sockets[0], case.start, case.stream, 8, case.expected_total, @as([]u8, &destination), &reply);
        if (case.valid) {
            try std.testing.expectEqualDeep(ConversationRange{ .total = case.total, .next = case.next }, try result);
            const delivered = if (stream_sink) &sink.bytes else &destination;
            try std.testing.expectEqualSlices(u8, case.body, delivered[0..case.body.len]);
            for (delivered[case.body.len..]) |byte| try std.testing.expectEqual(@as(u8, '?'), byte);
            if (stream_sink) try std.testing.expectEqual(case.body.len, sink.count);
        } else {
            try std.testing.expectError(error.InvalidResponse, result);
            try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat('?')), &destination);
            try std.testing.expectEqual(@as(usize, 0), sink.calls);
        }
    };
}

fn delayedResponse(io: std.Io, fd: std.posix.fd_t, delay: std.Io.Duration, response: []const u8) void {
    defer closeTestDescriptor(fd);
    std.Io.sleep(io, delay, .awake) catch return;
    writeAll(fd, response) catch {};
}

test "Host processing wait starts inactivity only after the first response byte" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, delayedResponse, .{
        std.testing.io,
        sockets[1],
        std.Io.Duration.fromMilliseconds(50),
        empty_test_response,
    });
    defer writer.join();
    const head = try readResponseHeadWithInactivity(sockets[0], 10);
    try std.testing.expectEqual(@as(u16, 200), head.status);
}

test "Host-info first byte is bounded independently of normal processing waits" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, delayedResponse, .{
        std.testing.io,
        sockets[1],
        std.Io.Duration.fromMilliseconds(50),
        empty_test_response,
    });
    defer writer.join();
    var buffer: ReplyBuffer = .{};
    const until = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
    try std.testing.expectError(error.ResponseInactive, readCommandResponseUntil(std.testing.io, sockets[0], &buffer, until));
}

test "Host-info deadline includes partial header and body" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\nab";
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
    for ([_]usize{ 1, body_start + 1 }) |prefix_len| {
        const sockets = try socketPair();
        defer closeTestDescriptor(sockets[0]);
        const flags = std.c.fcntl(sockets[0], std.c.F.GETFL);
        const nonblocking: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
        try std.testing.expect(flags >= 0 and std.c.fcntl(sockets[0], std.c.F.SETFL, flags | @as(c_int, @intCast(nonblocking))) == 0);
        try writeAll(sockets[1], response[0..prefix_len]);
        const writer = try std.Thread.spawn(.{}, delayedResponse, .{
            std.testing.io,
            sockets[1],
            std.Io.Duration.fromMilliseconds(50),
            response[prefix_len..],
        });
        defer writer.join();
        var buffer: ReplyBuffer = .{};
        const until = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
        try std.testing.expectError(error.ResponseInactive, readCommandResponseUntil(std.testing.io, sockets[0], &buffer, until));
        try std.testing.expectEqual(@as(usize, 0), buffer.len);
    }
}

test "Host processing wait does not consume response transfer inactivity" {
    // The fast test above checks the same boundary; this opt-in witness checks
    // the production 60-second value with real elapsed time.
    if (!std.mem.eql(u8, std.process.Environ.getPosix(std.testing.environ, "RUI_TEST_EXACT_INACTIVITY") orelse "", "1"))
        return error.SkipZigTest;
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, delayedResponse, .{
        std.testing.io,
        sockets[1],
        std.Io.Duration.fromSeconds(61),
        empty_test_response,
    });
    defer writer.join();
    var buffer: ReplyBuffer = .{};
    const reply = try readCommandResponse(sockets[0], &buffer);
    try std.testing.expectEqual(@as(u16, 200), reply.status);
}

test "response transfer inactivity begins after the first byte" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, delayedResponse, .{
        std.testing.io,
        sockets[1],
        std.Io.Duration.fromMilliseconds(50),
        empty_test_response[1..],
    });
    defer writer.join();
    try writeAll(sockets[1], empty_test_response[0..1]);
    try std.testing.expectError(
        error.ResponseInactive,
        readResponseHeadWithInactivity(sockets[0], 10),
    );
}

test "response closure and truncation stay explicit" {
    {
        const sockets = try socketPair();
        defer closeTestDescriptor(sockets[0]);
        closeTestDescriptor(sockets[1]);
        try std.testing.expectError(error.TruncatedResponse, readResponseHead(sockets[0]));
    }
    {
        const sockets = try socketPair();
        defer closeTestDescriptor(sockets[0]);
        try writeAll(
            sockets[1],
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\nx",
        );
        closeTestDescriptor(sockets[1]);
        var buffer: ReplyBuffer = .{};
        try std.testing.expectError(error.TruncatedResponse, readCommandResponse(sockets[0], &buffer));
    }
}

test "response framing rejects ambiguous or malformed fields before interpreting body" {
    for ([_][]const u8{
        "Content-Length : 0\r\n",
        "Content-Length: +0\r\n",
        "Content-Length: 0_0\r\n",
        "Transfer-Encoding: chunked\r\nContent-Length: 0\r\n",
        "Content-Length: 0\r\nTransfer-Encoding: identity\r\n",
        "Bad Name: value\r\nContent-Length: 0\r\n",
        "X-Extra: valid\x01not\r\nContent-Length: 0\r\n",
        "X-Extra: valid\r\n folded\r\nContent-Length: 0\r\n",
    }) |fields| {
        const sockets = try socketPair();
        defer closeTestDescriptor(sockets[0]);
        defer closeTestDescriptor(sockets[1]);
        var response: [512]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\n{s}\r\n", .{fields});
        try writeAll(sockets[1], bytes);
        try std.testing.expectError(error.InvalidResponse, readResponseHead(sockets[0]));
    }
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    defer closeTestDescriptor(sockets[1]);
    try writeAll(sockets[1], "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 00\r\nX-Rui-Wire-Version: 1\r\nX-Extra: one\r\nx-extra: two\r\n\r\n");
    try std.testing.expectEqual(@as(u16, 200), (try readResponseHead(sockets[0])).status);
}

test "capture configure derives Session from captured key and retains model admission" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var captured = try captureConfigure(io, .{
        .store = root,
        .session = .from_capture_key,
        .require_model = true,
    }, .{ .generated = root });
    const saved = captured.identity().*;
    var bytes: [2048]u8 = undefined;
    const count = blk: {
        defer captured.close(io);
        break :blk try captured.file.readPositionalAll(io, &bytes, 0);
    };
    try std.testing.expect(validRequestHandle(saved.key.slice()));
    var expected_buffer: ["rui/".len + 36]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "rui/{s}", .{saved.key.slice()});
    try std.testing.expectEqualStrings(expected, saved.session.slice());
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..count], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(saved.key.slice(), parsed.value.object.get("key").?.string);
    try std.testing.expectEqualStrings(expected, parsed.value.object.get("session").?.string);
    try std.testing.expect(parsed.value.object.get("require_model").?.bool);
    var recovered = try openCaptured(io, root, saved.key.slice());
    defer recovered.close(io);
    try std.testing.expectEqualStrings(expected, recovered.identity().session.slice());
}

test "capture returns original identity before send and preserves empty explicit keys" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const input: MessageInput = .{ .store = root, .session = "original/é", .text_path = "", .text = "original\ntext" };
    var generated = try captureMessage(io, input, .{ .generated = root });
    const saved = generated.identity().*;
    const descriptor = generated.file.handle;
    {
        defer generated.close(io);
        try std.testing.expect(validRequestHandle(saved.key.slice()));
        try std.testing.expectEqual(@as(u8, '4'), saved.key.slice()[14]);
        try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", saved.key.slice()[19]) != null);
        try std.testing.expectEqualStrings(root, saved.store.slice());
        try std.testing.expectEqualStrings("original/é", saved.session.slice());
        try std.testing.expectEqualStrings("message", saved.kind.slice());
        var reply: ReplyBuffer = .{};
        try std.testing.expectError(error.FileNotFound, sendCaptured(io, &generated, null, &reply));
        try std.testing.expectEqualStrings(saved.key.slice(), generated.identity().key.slice());
        try std.testing.expectEqualStrings(root, generated.identity().store.slice());
    }
    try std.testing.expect(std.c.fcntl(descriptor, std.c.F.GETFD) < 0);
    var recovered = try openCaptured(io, root, saved.key.slice());
    defer recovered.close(io);
    try std.testing.expectEqualStrings(saved.key.slice(), recovered.identity().key.slice());
    var record: [2048]u8 = undefined;
    const n = try recovered.file.readPositionalAll(io, &record, 0);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, record[0..n], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("original\ntext", parsed.value.object.get("text").?.object.get("value").?.string);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/explicit", .{root});
    var explicit = try captureMessage(io, input, .{ .explicit = .{ .record = path, .key = "" } });
    defer explicit.close(io);
    try std.testing.expectEqualStrings("", explicit.identity().key.slice());
    try std.testing.expectError(error.RecordAlreadyExists, captureMessage(io, input, .{ .explicit = .{ .record = path, .key = "different" } }));
    try std.testing.expectError(error.InvalidRequestHandle, openCaptured(io, root, ""));
}

test "capture retransmits complete original bytes after a lost reply" {
    const Peer = struct {
        var client_fd: std.posix.fd_t = undefined;
        var failure: ?anyerror = null;
        fn connect(_: ?*anyopaque, _: *const std.Io.net.UnixAddress) std.Io.net.UnixAddress.ConnectError!std.Io.net.Socket.Handle {
            return client_fd;
        }
        fn serve(fd: std.posix.fd_t, expected: []const u8, reply: bool) void {
            exchange(fd, expected, reply) catch |err| {
                failure = err;
            };
        }
        fn exchange(fd: std.posix.fd_t, expected: []const u8, reply: bool) !void {
            defer closeTestDescriptor(fd);
            var head: [512]u8 = undefined;
            var used: usize = 0;
            while (!std.mem.endsWith(u8, head[0..used], "\r\n\r\n")) {
                if (used == head.len) return error.TestRequestHeadTooLarge;
                const n = std.posix.system.read(fd, head[used..].ptr, 1);
                if (n != 1) return error.TestRequestTruncated;
                used += 1;
            }
            try std.testing.expect(std.mem.startsWith(u8, head[0..used], "POST /v1/message HTTP/1.1\r\n"));
            var length_buffer: [64]u8 = undefined;
            const length = try std.fmt.bufPrint(&length_buffer, "Content-Length: {d}\r\n", .{expected.len});
            try std.testing.expect(std.mem.indexOf(u8, head[0..used], length) != null);
            var bytes: [protocol.content_window_bytes]u8 = undefined;
            var offset: usize = 0;
            while (offset < expected.len) {
                const wanted = @min(bytes.len, expected.len - offset);
                const n = std.posix.system.read(fd, &bytes, wanted);
                if (n <= 0) return error.TestRequestTruncated;
                const count: usize = @intCast(n);
                try std.testing.expectEqualSlices(u8, expected[offset..][0..count], bytes[0..count]);
                offset += count;
            }
            if (reply) try writeAll(fd, empty_test_response);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/explicit", .{root});
    const text = [_]u8{'q'} ** (2 * protocol.content_window_bytes + 3);
    var captured = try captureMessage(io, .{ .store = root, .session = "original/session", .text_path = "", .text = &text }, .{ .explicit = .{ .record = path, .key = "owned-key" } });
    defer captured.close(io);
    var expected_buffer: [text.len + 1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"1\",\"kind\":\"message\",\"store\":\"{s}\",\"key\":\"owned-key\",\"session\":\"original/session\",\"text\":{{\"state\":\"value\",\"value\":\"{s}\"}}}}", .{ root, text });
    var vtable = io.vtable.*;
    vtable.netConnectUnix = Peer.connect;
    const connected_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]bool{ false, true }) |reply| {
        const sockets = try socketPair();
        Peer.client_fd = sockets[0]; // The production send owns and closes it.
        Peer.failure = null;
        const peer = try std.Thread.spawn(.{}, Peer.serve, .{ sockets[1], expected, reply });
        var buffer: ReplyBuffer = .{};
        const result = sendCaptured(connected_io, &captured, null, &buffer);
        peer.join();
        if (Peer.failure) |err| return err;
        if (reply) {
            try std.testing.expectEqual(@as(u16, 200), (try result).status);
        } else try std.testing.expectError(error.TruncatedResponse, result);
        try std.testing.expectEqualStrings("owned-key", captured.identity().key.slice());
    }
}

test "capture publication transfers original inode across pathname replacement" {
    const Replacement = struct {
        fn rename(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8) std.Io.Dir.RenamePreserveError!void {
            try std.testing.io.vtable.dirRenamePreserve(userdata, old_dir, old_path, new_dir, new_path);
            // Simulate a second local process immediately after the production
            // rename, before sync/lock release and the captured-owner handoff.
            new_dir.rename(new_path, new_dir, "displaced-original", std.testing.io) catch return error.Unexpected;
            const file = new_dir.createFile(std.testing.io, new_path, .{}) catch return error.Unexpected;
            defer file.close(std.testing.io);
            file.writeStreamingAll(std.testing.io, "replacement bytes") catch return error.Unexpected;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root});
    var vtable = io.vtable.*;
    vtable.dirRenamePreserve = Replacement.rename;
    const replaced_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var captured = try captureMessage(replaced_io, .{ .store = root, .session = "original/session", .text_path = "", .text = "original\ntext" }, .{ .explicit = .{ .record = path, .key = "original-key" } });
    defer captured.close(io);
    var expected_buffer: [2048]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"1\",\"kind\":\"message\",\"store\":\"{s}\",\"key\":\"original-key\",\"session\":\"original/session\",\"text\":{{\"state\":\"value\",\"value\":\"original\\ntext\"}}}}", .{root});
    var bytes: [2048]u8 = undefined;
    const count = try captured.file.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings(expected, bytes[0..count]);
    try std.testing.expectEqual(@as(u64, expected.len), captured.length);
}

test "capture closes pinned reader when publication or handoff fails" {
    const Failure = struct {
        var reader: std.posix.fd_t = undefined;
        var closed: usize = 0;
        fn open(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
            reader = file.handle;
            return file;
        }
        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            for (files) |file| if (file.handle == reader) {
                closed += 1;
            };
            std.testing.io.vtable.fileClose(userdata, files);
        }
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.NoSpaceLeft;
        }
        fn length(_: ?*anyopaque, _: std.Io.File) std.Io.File.LengthError!u64 {
            return error.AccessDenied;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root});
    for ([_]bool{ false, true }) |published| {
        var vtable = io.vtable.*;
        vtable.dirOpenFile = Failure.open;
        vtable.fileClose = Failure.close;
        if (published) vtable.fileLength = Failure.length else vtable.fileSync = Failure.sync;
        const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        Failure.closed = 0;
        try std.testing.expectError(if (published) error.AccessDenied else error.NoSpaceLeft, captureMessage(failing_io, .{ .store = root, .session = "original/session", .text_path = "", .text = "original" }, .{ .explicit = .{ .record = path, .key = "original-key" } }));
        try std.testing.expectEqual(@as(usize, 1), Failure.closed);
        try std.testing.expect(std.c.fcntl(Failure.reader, std.c.F.GETFD) < 0);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".record.capture.tmp", .{}));
        if (published) {
            _ = try tmp.dir.statFile(io, "record", .{});
        } else try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
    }
}

test "capture recovery closes rejected records and retains only its reader lifetime" {
    const Probe = struct {
        var opened: usize = 0;
        var closed: usize = 0;
        fn open(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
            opened += 1;
            return file;
        }
        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            closed += files.len;
            std.testing.io.vtable.fileClose(userdata, files);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const handle = "01234567-89ab-4cde-8012-3456789abcde";
    const filename = handle ++ ".json";
    var vtable = io.vtable.*;
    vtable.dirOpenFile = Probe.open;
    vtable.fileClose = Probe.close;
    const observed_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    Probe.opened = 0;
    Probe.closed = 0;
    for ([_][]const u8{
        "not json",
        "{\"version\":\"1\",\"kind\":\"session_stop\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"original\"}",
        "{\"version\":\"1\",\"kind\":\"model_interruption\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"target\":{\"session\":\"original\",\"turn\":\"1\",\"operation\":\"2\"}}",
        "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"other\",\"session\":\"original\",\"text\":{}}",
        "{\"version\":\"1\",\"kind\":\"unknown\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"original\",\"text\":{}}",
    }) |bytes| {
        const file = try tmp.dir.createFile(io, filename, .{});
        try file.writeStreamingAll(io, bytes);
        file.close(io);
        try std.testing.expectError(error.InvalidRequestRecord, openCaptured(observed_io, root, handle));
        try std.testing.expectEqual(Probe.opened, Probe.closed);
    }
    try tmp.dir.deleteFile(io, filename);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(root, handle, &path_buffer);
    var captured = try captureConfigure(io, .{ .store = root, .session = .{ .named = "original" } }, .{ .explicit = .{ .record = path, .key = handle } });
    captured.close(io);
    var recovered = try openCaptured(observed_io, root, handle);
    const descriptor = recovered.file.handle;
    {
        defer recovered.close(observed_io);
        try std.testing.expectEqual(Probe.opened, Probe.closed + 1);
        try tmp.dir.rename(filename, tmp.dir, "original-record", io);
        const replacement = try tmp.dir.createFile(io, filename, .{});
        try replacement.writeStreamingAll(io, "replacement must not change the open original");
        replacement.close(io);
        var bytes: [2048]u8 = undefined;
        const n = try recovered.file.readPositionalAll(io, &bytes, 0);
        try std.testing.expect(std.mem.startsWith(u8, bytes[0..n], "{\"version\":\"1\",\"kind\":\"configure\""));
    }
    try std.testing.expectEqual(Probe.opened, Probe.closed);
    try std.testing.expect(std.c.fcntl(descriptor, std.c.F.GETFD) < 0);
}

test "capture batches escaped file output and flushes before publication" {
    const Probe = struct {
        var writes: usize = 0;
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) writes += 1;
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var source_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_path_buffer, "{s}/source", .{root[0..root_len]});
    var record_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const record_path = try std.fmt.bufPrint(&record_path_buffer, "{s}/record", .{root[0..root_len]});
    const source = try tmp.dir.createFile(std.testing.io, "source", .{});
    const chunk = [_]u8{'x'} ** protocol.content_window_bytes;
    const chunks = 8192;
    for (0..chunks) |_| try source.writeStreamingAll(std.testing.io, &chunk);
    source.close(std.testing.io);
    var vtable = std.testing.io.vtable.*;
    vtable.operate = Probe.operate;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    Probe.writes = 0;
    var output: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, record_path, &output);
    errdefer capture.abort();
    try capture.writeJsonFile(source_path);
    try capture.commit();
    try std.testing.expect(Probe.writes <= chunks + 2);
    const record = try tmp.dir.openFile(std.testing.io, "record", .{});
    defer record.close(std.testing.io);
    var read_buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: usize = 0;
    while (true) {
        const n = record.readStreaming(std.testing.io, &.{&read_buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        for (read_buffer[0..n]) |byte| {
            const expected: u8 = if (offset == 0 or offset == chunks * chunk.len + 1) '"' else 'x';
            try std.testing.expectEqual(expected, byte);
            offset += 1;
        }
    }
    try std.testing.expectEqual(chunks * chunk.len + 2, offset);
}

test "capture validates split UTF8 and does not publish after final flush failure" {
    const FailWrite = struct {
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) return .{ .file_write_streaming = error.NoSpaceLeft };
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var source_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_path_buffer, "{s}/source", .{root[0..root_len]});
    var record_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const record_path = try std.fmt.bufPrint(&record_path_buffer, "{s}/record", .{root[0..root_len]});
    var input = [_]u8{'x'} ** (protocol.content_window_bytes + 1);
    input[input.len - 2] = 0xc3;
    input[input.len - 1] = 0xa9;
    for ([_]bool{ false, true }) |truncated| {
        const source = try tmp.dir.createFile(io, "source", .{});
        try source.writeStreamingAll(io, input[0 .. input.len - @intFromBool(truncated)]);
        source.close(io);
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var capture = try Capture.open(io, record_path, &buffer);
        defer capture.abort();
        if (truncated) {
            try std.testing.expectError(error.InvalidUtf8, capture.writeJsonFile(source_path));
            capture.abort();
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, capture.temporary_name.slice(), .{}));
        } else {
            try capture.writeJsonFile(source_path);
            try capture.commit();
            const file = try tmp.dir.openFile(io, "record", .{});
            defer file.close(io);
            var bytes: [input.len + 2]u8 = undefined;
            const n = try file.readStreaming(io, &.{&bytes});
            try std.testing.expectEqual(bytes.len, n);
            try std.testing.expectEqualStrings(&input, bytes[1 .. bytes.len - 1]);
            try tmp.dir.deleteFile(io, "record");
        }
    }
    var vtable = io.vtable.*;
    vtable.operate = FailWrite.operate;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(failing_io, record_path, &buffer);
    defer capture.abort();
    try capture.writeJsonString("buffered until commit");
    try std.testing.expectError(error.NoSpaceLeft, capture.commit());
    capture.abort();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, capture.temporary_name.slice(), .{}));
}

test "capture bounds decoded bytes and preserves record ownership" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root[0..n]});
    var source_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_buffer, "{s}/source", .{root[0..n]});
    const source = try tmp.dir.createFile(io, "source", .{});
    try source.writeStreamingAll(io, "\x00\n€");
    source.close(io);
    var buffer: [32]u8 = undefined;
    var other_buffer: [32]u8 = undefined;
    var capture = try Capture.open(io, path, &buffer);
    defer capture.abort();
    try std.testing.expectError(error.RecordCaptureBusy, Capture.open(io, path, &other_buffer));
    try std.testing.expectError(error.ContentTooLarge, capture.writeJsonFileBounded(source_path, 4));
    capture.abort();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
    capture = try Capture.open(io, path, &buffer);
    try capture.writeJsonFileBounded(source_path, 5);
    try capture.commit();
    try std.testing.expectError(error.RecordAlreadyExists, Capture.open(io, path, &other_buffer));
    const saved = try tmp.dir.openFile(io, "record", .{});
    defer saved.close(io);
    var bytes: [32]u8 = undefined;
    const count = try saved.readStreaming(io, &.{&bytes});
    try std.testing.expectEqualStrings("\"\\u0000\\n€\"", bytes[0..count]);
}

test "stdin capture uses the same decoded bound before publication" {
    const Stdin = struct {
        var sent: bool = false;
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_read_streaming and operation.file_read_streaming.file.handle == std.Io.File.stdin().handle) {
                if (sent) return .{ .file_read_streaming = error.EndOfStream };
                sent = true;
                @memcpy(operation.file_read_streaming.data[0][0..3], "a\nb");
                return .{ .file_read_streaming = 3 };
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root[0..n]});
    var vtable = io.vtable.*;
    vtable.operate = Stdin.operate;
    const input_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var buffer: [32]u8 = undefined;
    for ([_]u64{ 2, 3 }) |limit| {
        Stdin.sent = false;
        var capture = try Capture.open(input_io, path, &buffer);
        defer capture.abort();
        if (limit == 2) {
            try std.testing.expectError(error.ContentTooLarge, capture.writeJsonFileBounded("-", limit));
            capture.abort();
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
        } else {
            try capture.writeJsonFileBounded("-", limit);
            try capture.commit();
            const saved = try tmp.dir.openFile(io, "record", .{});
            defer saved.close(io);
            var bytes: [16]u8 = undefined;
            const count = try saved.readStreaming(io, &.{&bytes});
            try std.testing.expectEqualStrings("\"a\\nb\"", bytes[0..count]);
        }
    }
}
fn testPipe() ![2]std.posix.fd_t {
    var descriptors: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&descriptors) != 0) return error.TestPipeFailed;
    return descriptors;
}

fn closeTestDescriptor(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn writeTestResponse(fd: std.posix.fd_t, response: []const u8) !void {
    defer closeTestDescriptor(fd);
    try writeAll(fd, response);
}

test "command reply borrows the caller buffer" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    try writeTestResponse(
        descriptors[1],
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Rui-Wire-Version: 1\r\n\r\n{\"status\":\"error\"}",
    );
    var buffer: ReplyBuffer = .{};
    const reply = try readCommandResponse(descriptors[0], &buffer);
    try std.testing.expectEqual(@as(u16, 409), reply.status);
    try std.testing.expectEqualStrings("{\"status\":\"error\"}", reply.body);
    try std.testing.expectEqual(@intFromPtr(buffer.bytes[0..].ptr), @intFromPtr(reply.body.ptr));
}

test "bounded read requests attain their independent worst-case capacities" {
    const escaped_store = [_]u8{1} ** protocol.max_store_bytes;
    const escaped_key = [_]u8{1} ** protocol.max_key_bytes;
    const escaped_session = [_]u8{1} ** protocol.max_session_bytes;
    const cases = .{
        .{ "observe_command", "key", &escaped_key, null, null, protocol.max_observe_command_request_bytes },
        .{ "read_result", "key", &escaped_key, null, null, protocol.max_read_result_request_bytes },
        .{ "inspect_session", "session", &escaped_session, null, protocol.ReportProfile.full, protocol.max_inspect_session_request_bytes },
        .{ "read_action_call_id", "session", &escaped_session, std.math.maxInt(u64), null, protocol.max_read_action_call_id_request_bytes },
        .{ "read_action_arguments", "session", &escaped_session, std.math.maxInt(u64), null, protocol.max_read_action_arguments_request_bytes },
    };
    inline for (cases) |case| {
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, case[0], &escaped_store, case[1], case[2], case[3], case[4]);
        try std.testing.expectEqual(@as(usize, case[5]), body.len);
    }
    var full: protocol.RequestBuffer = .{};
    full.len = full.bytes.len;
    try std.testing.expectError(error.BufferTooLarge, full.append("x"));
}

test "Session list client renders exact cursor and maximum escaped workspace without truncation" {
    var empty: protocol.RequestBuffer = .{};
    try renderSessionListRequest(&empty, "/store", null, .{});
    try std.testing.expectEqualStrings(
        "{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":\"/store\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"0\"}",
        empty.slice(),
    );
    const escaped_store = [_]u8{1} ** protocol.max_store_bytes;
    const escaped_workspace = [_]u8{1} ** protocol.max_workspace_bytes;
    var maximum: protocol.RequestBuffer = .{};
    try renderSessionListRequest(&maximum, &escaped_store, &escaped_workspace, .{
        .after = std.math.maxInt(i64),
        .ceiling = std.math.maxInt(i64),
    });
    try std.testing.expectEqual(protocol.max_list_sessions_request_bytes - 1, maximum.len);
    try std.testing.expect(std.mem.endsWith(u8, maximum.slice(), "\"after\":\"9223372036854775807\",\"ceiling\":\"9223372036854775807\"}"));
}

test "control captures attain their exact worst-case request bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var records = try tmp.dir.createDirPathOpen(std.testing.io, "records", .{
        .permissions = .fromMode(0o700),
    });
    records.close(std.testing.io);

    const escaped_store = [_]u8{1} ** protocol.max_store_bytes;
    const escaped_key = [_]u8{1} ** protocol.max_key_bytes;
    const escaped_session = [_]u8{1} ** protocol.max_session_bytes;
    var paths: platform.Paths = .{};
    try paths.store.set(&escaped_store);

    var stop_path_buffer: [protocol.max_store_bytes + "/records/stop-record".len]u8 = undefined;
    const stop_path = try std.fmt.bufPrint(
        &stop_path_buffer,
        "{s}/records/stop-record",
        .{root_buffer[0..root_length]},
    );
    try captureSessionStop(std.testing.io, &paths, .{
        .store = "unused",
        .record = stop_path,
        .key = &escaped_key,
        .session = &escaped_session,
    });
    const stop_file = try std.Io.Dir.cwd().openFile(std.testing.io, stop_path, .{});
    defer stop_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_session_stop_request_bytes),
        try stop_file.length(std.testing.io),
    );

    var interruption_path_buffer: [protocol.max_store_bytes + "/records/interruption-record".len]u8 = undefined;
    const interruption_path = try std.fmt.bufPrint(
        &interruption_path_buffer,
        "{s}/records/interruption-record",
        .{root_buffer[0..root_length]},
    );
    try captureModelInterruption(std.testing.io, &paths, .{
        .store = "unused",
        .record = interruption_path,
        .key = &escaped_key,
        .session = &escaped_session,
        .turn_id = std.math.maxInt(u64),
        .operation_id = std.math.maxInt(u64),
    });
    const interruption_file = try std.Io.Dir.cwd().openFile(std.testing.io, interruption_path, .{});
    defer interruption_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_model_interruption_request_bytes),
        try interruption_file.length(std.testing.io),
    );

    var permission_path_buffer: [protocol.max_store_bytes + "/records/permission-record".len]u8 = undefined;
    const permission_path = try std.fmt.bufPrint(
        &permission_path_buffer,
        "{s}/records/permission-record",
        .{root_buffer[0..root_length]},
    );
    var permission_buffer: [protocol.content_window_bytes]u8 = undefined;
    var permission_capture = try Capture.open(std.testing.io, permission_path, &permission_buffer);
    defer permission_capture.abort();
    try permission_capture.writePermissionDecision(paths.store.slice(), &escaped_key, .{
        .store = "unused",
        .session = &escaped_session,
        .action_id = std.math.maxInt(u64),
        .decision = .allow_once,
    });
    try permission_capture.commit();
    const permission_file = try std.Io.Dir.cwd().openFile(std.testing.io, permission_path, .{});
    defer permission_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_permission_decision_request_bytes),
        try permission_file.length(std.testing.io),
    );
}

test "response parsing rejects truncated head and command body" {
    {
        const descriptors = try testPipe();
        defer closeTestDescriptor(descriptors[0]);
        try writeTestResponse(descriptors[1], "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n");
        var buffer: ReplyBuffer = .{};
        try std.testing.expectError(error.TruncatedResponse, readCommandResponse(descriptors[0], &buffer));
    }
    {
        const descriptors = try testPipe();
        defer closeTestDescriptor(descriptors[0]);
        try writeTestResponse(
            descriptors[1],
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
        );
        var buffer: ReplyBuffer = .{};
        try std.testing.expectError(error.TruncatedResponse, readCommandResponse(descriptors[0], &buffer));
        try std.testing.expectEqual(@as(usize, 0), buffer.len);
    }
}

const LargeResponseContext = struct {
    fd: std.posix.fd_t,
    length: u64,
    content_type: []const u8 = "text/plain; charset=utf-8",
    failure: ?anyerror = null,
};

fn testPattern(buffer: []u8, offset: u64) void {
    for (buffer, 0..) |*byte, index| byte.* = @intCast((offset + index) % 251);
}

fn writeLargeTestResponse(context: *LargeResponseContext) void {
    defer closeTestDescriptor(context.fd);
    var header_buffer: [256]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: 1\r\n\r\n",
        .{ context.content_type, context.length },
    ) catch |err| {
        context.failure = err;
        return;
    };
    writeAll(context.fd, header) catch |err| {
        context.failure = err;
        return;
    };
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < context.length) {
        const count: usize = @intCast(@min(context.length - offset, buffer.len));
        testPattern(buffer[0..count], offset);
        writeAll(context.fd, buffer[0..count]) catch |err| {
            context.failure = err;
            return;
        };
        offset += count;
    }
}

test "result response streams 100,000 bytes into an explicit file" {
    const result_bytes = 100_000;
    const descriptors = try testPipe();
    var context = LargeResponseContext{ .fd = descriptors[1], .length = result_bytes };
    const writer = try std.Thread.spawn(.{}, writeLargeTestResponse, .{&context});
    var writer_joined = false;
    defer {
        closeTestDescriptor(descriptors[0]);
        if (!writer_joined) writer.join();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try tmp.dir.createFile(std.testing.io, "answer", .{ .read = true });
    defer destination.close(std.testing.io);
    var reply_buffer: ReplyBuffer = .{};
    const reply = try readResultResponse(std.testing.io, descriptors[0], destination, &reply_buffer);
    writer.join();
    writer_joined = true;
    switch (reply) {
        .answer => |answer| try std.testing.expectEqual(@as(u64, result_bytes), answer.bytes),
        .command => return error.ExpectedAnswer,
    }
    try std.testing.expectEqual(@as(usize, 0), reply_buffer.len);
    try std.testing.expectEqual(@as(u64, result_bytes), try destination.length(std.testing.io));

    var expected_hash = std.crypto.hash.sha2.Sha256.init(.{});
    var actual_hash = std.crypto.hash.sha2.Sha256.init(.{});
    var expected_buffer: [protocol.content_window_bytes]u8 = undefined;
    var actual_buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < result_bytes) {
        const count: usize = @intCast(@min(result_bytes - offset, expected_buffer.len));
        testPattern(expected_buffer[0..count], offset);
        expected_hash.update(expected_buffer[0..count]);
        const actual = try destination.readPositionalAll(std.testing.io, actual_buffer[0..count], offset);
        try std.testing.expectEqual(count, actual);
        actual_hash.update(actual_buffer[0..actual]);
        offset += count;
    }
    try std.testing.expectEqual(expected_hash.finalResult(), actual_hash.finalResult());
    try std.testing.expect(context.failure == null);
}

test "Session list client streams a page larger than the resident reply buffer" {
    const page_bytes = 100_000;
    const descriptors = try testPipe();
    var context = LargeResponseContext{ .fd = descriptors[1], .length = page_bytes, .content_type = "application/json" };
    const writer = try std.Thread.spawn(.{}, writeLargeTestResponse, .{&context});
    defer closeTestDescriptor(descriptors[0]);
    defer writer.join();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer destination.close(std.testing.io);
    var reply_buffer: ReplyBuffer = .{};
    const reply = try readReportResponse(std.testing.io, descriptors[0], destination, &reply_buffer);
    switch (reply) {
        .report => |report| try std.testing.expectEqual(@as(u64, page_bytes), report.bytes),
        .command => return error.ExpectedReport,
    }
    try std.testing.expectEqual(@as(u64, page_bytes), try destination.length(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), reply_buffer.len);
}

test "read result returns bounded command errors without touching destination" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    try writeTestResponse(
        descriptors[1],
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Rui-Wire-Version: 1\r\n\r\n{\"status\":\"error\"}",
    );
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try tmp.dir.createFile(std.testing.io, "answer", .{ .read = true });
    defer destination.close(std.testing.io);
    var buffer: ReplyBuffer = .{};
    const reply = try readResultResponse(std.testing.io, descriptors[0], destination, &buffer);
    switch (reply) {
        .answer => return error.ExpectedCommandReply,
        .command => |command| {
            try std.testing.expectEqual(@as(u16, 409), command.status);
            try std.testing.expectEqualStrings("{\"status\":\"error\"}", command.body);
        },
    }
    try std.testing.expectEqual(@as(u64, 0), try destination.length(std.testing.io));
}

test "truncated result body leaves only an unsuccessful destination prefix" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    try writeTestResponse(
        descriptors[1],
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 1\r\n\r\nab",
    );
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try tmp.dir.createFile(std.testing.io, "answer", .{ .read = true });
    defer destination.close(std.testing.io);
    var buffer: ReplyBuffer = .{};
    try std.testing.expectError(
        error.TruncatedResponse,
        readResultResponse(std.testing.io, descriptors[0], destination, &buffer),
    );
    try std.testing.expectEqual(@as(u64, 2), try destination.length(std.testing.io));
}

test "Message observation retains selected Turn independently of terminal progress" {
    const address = try MessageAddress.init("/store", "s", "k");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"kind\":\"message\",\"target\":\"s\",\"status\":\"accepted\",\"processing\":{\"turn\":\"37\"},";
    inline for (.{
        .{ "\"queue\":{\"status\":\"processing\"}}}", MessageObservation.State.processing },
        .{ "\"result\":{\"status\":\"completed\"},\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"91\"}}}", MessageObservation.State.completed },
        .{ "\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"}}}", MessageObservation.State.failed },
        .{ "\"result\":{\"status\":\"cancelled\"}}}", MessageObservation.State.cancelled },
    }) |case| {
        var observed = try MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = prefix ++ case[0] }, &address);
        defer observed.deinit();
        try std.testing.expectEqual(case[1], observed.state);
        try std.testing.expectEqual(@as(?u64, 37), observed.processing_turn);
        try std.testing.expect(observed.progress == null);
    }
}

test "Message observation preserves binding outcomes and absent progress" {
    const address = try MessageAddress.init("/store", "original/session", "original-key");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"original-key\",\"observation\":{\"kind\":\"message\",\"target\":\"original/session\",";
    const cases = .{
        .{ "\"status\":\"accepted\"}}", MessageObservation.State.accepted, null },
        .{ "\"status\":\"accepted\",\"queue\":{\"status\":\"queued\"}}}", MessageObservation.State.queued, null },
        .{ "\"status\":\"accepted\",\"queue\":{\"status\":\"processing\"}}}", MessageObservation.State.processing, null },
        .{ "\"status\":\"rejected\",\"code\":\"unknown_session\"}}", MessageObservation.State.rejected, "unknown_session" },
        .{ "\"status\":\"accepted\",\"queue\":{\"status\":\"processing\"},\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"},\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"19\"}}}", MessageObservation.State.failed, "provider_http_422" },
        .{ "\"status\":\"accepted\",\"queue\":{\"status\":\"excluded\"},\"result\":{\"status\":\"cancelled\",\"code\":\"session_stopped\"}}}", MessageObservation.State.cancelled, "session_stopped" },
        .{ "\"status\":\"accepted\",\"queue\":{\"status\":\"completed\"},\"result\":{\"status\":\"completed\"}}}", MessageObservation.State.completed, null },
    };
    inline for (cases) |case| {
        var observed = try MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = prefix ++ case[0] }, &address);
        defer observed.deinit();
        try std.testing.expectEqual(case[1], observed.state);
        const expected_code: ?[]const u8 = case[2];
        if (expected_code) |code| try std.testing.expectEqualStrings(code, observed.code.?) else try std.testing.expect(observed.code == null);
        try std.testing.expect(observed.progress == null);
        try std.testing.expect(observed.processing_turn == null);
    }
    const other_session = try MessageAddress.init("/store", "later/session", "original-key");
    const other_key = try MessageAddress.init("/store", "original/session", "later-key");
    const completed: CommandReply = .{ .status = 200, .body = prefix ++ "\"status\":\"accepted\",\"result\":{\"status\":\"completed\"}}}" };
    try std.testing.expectError(error.RequestBindingMismatch, MessageObservation.parse(std.testing.allocator, completed, &other_session));
    try std.testing.expectError(error.RequestBindingMismatch, MessageObservation.parse(std.testing.allocator, completed, &other_key));
    try std.testing.expectError(error.InvalidResponse, MessageObservation.parse(std.testing.allocator, .{ .status = 503, .body = "" }, &address));
    try std.testing.expectError(error.ObservationFailed, MessageObservation.parse(std.testing.allocator, .{ .status = 503, .body = "{\"code\":\"host_unavailable\"}" }, &address));
    try std.testing.expectError(error.CanonicalStoreFailure, MessageObservation.parse(std.testing.allocator, .{ .status = 500, .body = "{\"code\":\"canonical_store_failure\"}" }, &address));
    try std.testing.expectError(error.RequestNotAdmitted, MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = prefix ++ "\"status\":\"absent\"}}" }, &address));
    try std.testing.expectError(error.RequestBindingMismatch, MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"original-key\",\"observation\":{\"status\":\"accepted\",\"kind\":\"configure\",\"target\":\"original/session\"}}" }, &address));
}

test "Message observation rejects malformed facts rather than work failures" {
    const address = try MessageAddress.init("/store", "s", "k");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"kind\":\"message\",\"target\":\"s\",\"status\":\"accepted\",";
    inline for (.{
        "\"processing\":null}}",
        "\"processing\":{}}}",
        "\"processing\":{\"turn\":7}}}",
        "\"processing\":{\"turn\":\"0\"}}}",
        "\"processing\":{\"turn\":\"+7\"}}}",
        "\"processing\":{\"turn\":\"18446744073709551616\"}}}",
        "\"queue\":null}}",
        "\"queue\":{\"status\":\"excluded\"}}}",
        "\"result\":{\"status\":\"processing\"}}}",
        "\"result\":{\"status\":\"failed\",\"code\":17}}}",
        "\"progress\":{\"status\":\"invented\",\"action\":null}}}",
        "\"progress\":{\"status\":\"waiting_for_permission\",\"action\":null}}}",
        "\"progress\":{\"status\":\"in_flight\"}}}",
        "\"progress\":{\"status\":\"in_flight\",\"action\":17}}}",
        "\"progress\":{\"status\":\"in_flight\",\"action\":\"0\"}}}",
        "\"progress\":{\"status\":\"in_flight\",\"action\":\"+7\"}}}",
        "\"progress\":{\"status\":\"in_flight\",\"action\":\"18446744073709551616\"}}}",
    }) |suffix| try std.testing.expectError(error.InvalidObservation, MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = prefix ++ suffix }, &address));
    inline for (.{ "{}", "[]", "{\"version\":\"2\"}", "{\"version\":\"1\",\"type\":\"wrong\"}" }) |body|
        try std.testing.expectError(error.InvalidObservation, MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = body }, &address));
    try std.testing.expectError(error.DuplicateField, MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = prefix ++ "\"queue\":{\"status\":\"queued\",\"status\":\"processing\"}}}" }, &address));
    var oversized: [protocol.max_response_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.ResponseTooLarge, MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = &oversized }, &address));
}

test "Message observation owns decoded strings and writes complete JSON after reply reuse" {
    const address = try MessageAddress.init("/store", "s", "k");
    const observation = "{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"s\",\"input\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"digest\"},\"queue\":{\"status\":\"processing\",\"admission\":\"41\"},\"processing\":{\"turn\":\"3\",\"operation\":\"9\",\"attempt\":\"15\"},\"result\":{\"status\":\"failed\",\"code\":\"plain_code\"},\"extra\":{\"precise\":123456789012345678901234567890,\"decimal\":0.123456789012345678901234567890,\"items\":[true,null,\"line\\n\\u001b\"]}}";
    const body = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":" ++ observation ++ "}";
    var reply_storage: [body.len]u8 = undefined;
    @memcpy(&reply_storage, body);
    var observed = try MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = &reply_storage }, &address);
    defer observed.deinit();
    @memset(&reply_storage, 'x');
    try std.testing.expectEqualStrings("plain_code", observed.code.?);
    try std.testing.expectEqual(@as(?u64, 3), observed.processing_turn);
    var output: [body.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try observed.writeJson(&writer);
    try std.testing.expectEqualStrings(observation, writer.buffered());
    var too_small = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, observed.writeJson(&too_small));
}

test "Message observation releases storage across allocation failures and repeated polls" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const address = try MessageAddress.init("/store", "s", "k");
            const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"s\",";
            var observed = try MessageObservation.parse(allocator, .{ .status = 200, .body = prefix ++ "\"queue\":{\"status\":\"processing\"},\"progress\":{\"status\":\"in_flight\",\"action\":\"18446744073709551615\"}}}" }, &address);
            defer observed.deinit();
            try std.testing.expectEqual(std.math.maxInt(u64), observed.progress.?.action.?);
            var invalid = MessageObservation.parse(allocator, .{ .status = 200, .body = prefix ++ "\"progress\":{\"status\":\"in_flight\",\"action\":false}}}" }, &address) catch |err| switch (err) {
                error.InvalidObservation => return,
                else => return err,
            };
            invalid.deinit();
            return error.ExpectedInvalidObservation;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
    for (0..100) |_| {
        var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        try Harness.run(tracked.allocator());
        try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
        try std.testing.expectEqual(tracked.allocations, tracked.deallocations);
    }
}

test "transport cancellation typed capability checks before connection and preserves capture" {
    var token: Cancellation = .{};
    token.requestStop();
    const requests: Requests = .{ .io = std.testing.io, .cancellation = &token };
    const Sink = struct {
        pub fn feed(_: *@This(), _: []const u8) !void {
            return error.UnexpectedDelivery;
        }
    };
    var sink: Sink = .{};
    var reply: ReplyBuffer = .{};
    var captured: CapturedRecord = .{ .file = .{ .handle = -1, .flags = .{ .nonblocking = false } }, .length = 0, .saved = .{} };
    try captured.saved.store.set("/never-open");
    try captured.saved.kind.set("permission_decision");
    const destination: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };
    const address = try MessageAddress.init("/never-open", "s", "k");
    var range: [8]u8 = undefined;
    try std.testing.expectError(error.Cancelled, requests.check());
    try std.testing.expectError(error.Cancelled, requests.sendCaptured(&captured, null, &reply));
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), captured.file.handle);
    try std.testing.expectError(error.Cancelled, requests.observeMessage(std.testing.allocator, &address));
    try std.testing.expectError(error.Cancelled, requests.sessionView("/never-open", "s", .{}, &reply));
    try std.testing.expectError(error.Cancelled, requests.conversationPage("/never-open", "s", .{}, destination, &reply));
    try std.testing.expectError(error.Cancelled, requests.conversationContentStream("/never-open", "s", 1, 0, null, &sink, &reply));
    try std.testing.expectError(error.Cancelled, requests.sessionCallContentStream("/never-open", "s", 1, .arguments, &sink, &reply));
    try std.testing.expectError(error.Cancelled, requests.messageContent("/never-open", "s", 1, 0, &range, &reply));
    try std.testing.expectError(error.Cancelled, requests.messageContentStream("/never-open", "s", 1, 1, &sink, &reply));
    try std.testing.expectError(error.Cancelled, requests.inspectSession("/never-open", "s", .current, destination, &reply));
    try std.testing.expectError(error.Cancelled, requests.readResultStream("/never-open", "k", &sink, &reply));
    try std.testing.expectError(error.Cancelled, requests.readActionArguments("/never-open", "s", 1, destination, &reply));
    try std.testing.expectError(error.Cancelled, requests.readActionCallId("/never-open", "s", 1, destination, &reply));
    try std.testing.expectError(error.Cancelled, connectRequest(requests, try .init("/never-open"), null));
}

test "transport cancellation joins production exchange before held peer release" {
    const Probe = struct {
        var descriptor: std.posix.fd_t = -1;
        var closes: usize = 0;
        fn close(_: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
            descriptor = handles[0];
            closes += handles.len;
            std.testing.io.vtable.netClose(std.testing.io.userdata, handles);
        }
    };
    const Worker = struct {
        const Mode = enum { command, backpressure, result, content, report };
        requests: Requests,
        paths: *const platform.Paths,
        mode: Mode,
        destination: std.Io.File,
        failure: ?anyerror = null,
        delivered: usize = 0,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.exchange() catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try std.testing.expectEqualStrings("a", bytes);
            self.delivered += bytes.len;
        }
        fn exchange(self: *@This()) !void {
            var reply: ReplyBuffer = .{};
            switch (self.mode) {
                .command, .backpressure => {
                    // Static test input; transport retains no payload copy.
                    const large = [_]u8{'q'} ** (1024 * 1024);
                    const bytes: []const u8 = if (self.mode == .backpressure) &large else "{}";
                    _ = try sendSource(self.requests, self.paths, "/v1/message", bytes.len, null, bytes, null, null, &reply, null);
                },
                .result => _ = try self.requests.readResultStream(self.paths.store.slice(), "k", self, &reply),
                .content => _ = try self.requests.messageContentStream(self.paths.store.slice(), "s", 1, 4, self, &reply),
                .report => _ = try self.requests.conversationPage(self.paths.store.slice(), "s", .{}, self.destination, &reply),
            }
        }
    };
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 1\r\n\r\nabcd";
    const result_response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 1\r\n\r\nabcd";
    const content_response = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 1\r\nX-Rui-Content-Bytes: 4\r\nX-Rui-Next-Offset: 4\r\n\r\nabcd";
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var lease = try platform.StoreLease.acquire(std.testing.io, root[0..root_len]);
    defer lease.release();
    try lease.prepareForServing(false);
    const paths = lease.paths;
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    var listener = try address.listen(std.testing.io, .{});
    // Test-only socket name, never an accepted capture or Host's endpoint.
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, paths.socket.slice()) catch unreachable;
    defer listener.deinit(std.testing.io);
    const destination = try tmp.dir.createFile(std.testing.io, "report", .{});
    defer destination.close(std.testing.io);
    // No first byte; partial head; partial body; initially-writable large send.
    const Case = struct { mode: Worker.Mode, response: []const u8 = response, prefix: usize };
    for ([_]Case{
        .{ .mode = .command, .prefix = 0 },
        .{ .mode = .command, .prefix = 1 },
        .{ .mode = .command, .prefix = body_start + 1 },
        .{ .mode = .backpressure, .prefix = 0 },
        .{ .mode = .result, .response = result_response, .prefix = result_response.len - 3 },
        .{ .mode = .content, .response = content_response, .prefix = content_response.len - 3 },
        .{ .mode = .report, .prefix = body_start + 1 },
    }) |case| {
        var token: Cancellation = .{};
        var vtable = std.testing.io.vtable.*;
        vtable.netClose = Probe.close;
        Probe.descriptor = -1;
        Probe.closes = 0;
        var worker: Worker = .{
            .requests = .{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .cancellation = &token },
            .paths = &paths,
            .mode = case.mode,
            .destination = destination,
        };
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        var joined = false;
        const peer = try listener.accept(std.testing.io);
        var peer_open = true;
        defer {
            token.requestStop();
            if (peer_open) peer.close(std.testing.io);
            if (!joined) thread.join();
        }
        if (case.mode != .backpressure) try writeAll(peer.socket.handle, case.response[0..case.prefix]);
        // Let more than two service quanta expire: expiry must not be timeout.
        try std.Io.sleep(std.testing.io, .fromMilliseconds(250), .awake);
        const pending = !worker.done.load(.acquire);
        token.requestStop();
        const end = requestNow(std.testing.io) + std.time.ns_per_s;
        while (!worker.done.load(.acquire) and requestNow(std.testing.io) < end)
            try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
        const returned_before_release = worker.done.load(.acquire);
        // Releases a disabled-cancellation mutant too, keeping the oracle finite.
        peer.close(std.testing.io);
        peer_open = false;
        thread.join();
        joined = true;
        try std.testing.expect(pending);
        try std.testing.expect(returned_before_release);
        try std.testing.expectEqual(error.Cancelled, worker.failure.?);
        try std.testing.expectEqual(@as(usize, 1), Probe.closes);
        try std.testing.expect(std.c.fcntl(Probe.descriptor, std.c.F.GETFD) < 0);
        try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(-1));
        if (case.mode == .result or case.mode == .content) try std.testing.expectEqual(@as(usize, 1), worker.delivered);
        if (case.mode == .report) try std.testing.expectEqual(@as(u64, 1), try destination.length(std.testing.io));
    }
}

test "transport cancellation nonblocking setup preserves regular file flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "flags", .{ .read = true });
    defer file.close(std.testing.io);
    const before = std.c.fcntl(file.handle, std.c.F.GETFL);
    const append: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .APPEND = true })));
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expect(before >= 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(file.handle, std.c.F.SETFL, before | append));
    const retained = std.c.fcntl(file.handle, std.c.F.GETFL);
    try addNonblocking(file.handle);
    try std.testing.expectEqual(retained | nonblocking, std.c.fcntl(file.handle, std.c.F.GETFL));
}

test "transport cancellation services Linux Unix connect backlog and releases failed socket" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Worker = struct {
        requests: Requests,
        address: std.Io.net.UnixAddress,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.connect() catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
        fn connect(self: *@This()) !void {
            const fd = try connectRequest(self.requests, self.address, null);
            defer closeRequest(self.requests, fd);
        }
    };
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var lease = try platform.StoreLease.acquire(std.testing.io, root[0..try tmp.dir.realPath(std.testing.io, &root)]);
    defer lease.release();
    try lease.prepareForServing(false);
    const address = try std.Io.net.UnixAddress.init(lease.paths.socket.slice());
    var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 0 });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, address.path) catch unreachable;
    defer listener.deinit(std.testing.io);
    // Linux admits one pending connection with backlog zero. Do not accept it
    // until the cancellation oracle has sampled the second connector.
    const pending = try address.connect(std.testing.io);
    defer pending.close(std.testing.io);
    const descriptors = @import("descriptor_limit.zig");
    const baseline = (try descriptors.observe(std.testing.io)).open_descriptors;
    const deadline = requestNow(std.testing.io) + 10 * std.time.ns_per_ms;
    try std.testing.expectError(error.TransferInactive, connectRequest(std.testing.io, address, deadline));
    try std.testing.expectEqual(baseline, (try descriptors.observe(std.testing.io)).open_descriptors);
    var token: Cancellation = .{};
    var worker: Worker = .{ .requests = .{ .io = std.testing.io, .cancellation = &token }, .address = address };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var joined = false;
    defer {
        token.requestStop();
        if (!joined) thread.join();
    }
    try std.Io.sleep(std.testing.io, .fromMilliseconds(250), .awake);
    const waiting_before_stop = !worker.done.load(.acquire);
    token.requestStop();
    const end = requestNow(std.testing.io) + std.time.ns_per_s;
    while (!worker.done.load(.acquire) and requestNow(std.testing.io) < end)
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    const returned_before_release = worker.done.load(.acquire);
    // Unblock a disabled-stop mutant through the real backlog, not a timeout
    // in the connector or a cross-thread close of its owned descriptor.
    const accepted = try listener.accept(std.testing.io);
    accepted.close(std.testing.io);
    thread.join();
    joined = true;
    try std.testing.expect(waiting_before_stop);
    try std.testing.expect(returned_before_release);
    try std.testing.expectEqual(error.Cancelled, worker.failure.?);
    try std.testing.expectEqual(baseline, (try descriptors.observe(std.testing.io)).open_descriptors);
}
