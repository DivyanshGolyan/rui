const std = @import("std");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");

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
    record: []const u8,
    key: []const u8,
    session: []const u8,
    workspace: OptionalText = .{},
    provider: OptionalText = .{},
    model: OptionalText = .{},
    instructions: OptionalFile = .{},
    tools: ?[]const u8 = null,
    permission_mode: OptionalText = .{},
    output_schema: OptionalFile = .{},
    drop_reply: ?[]const u8 = null,
    captured: ?*const fn (std.Io, []const u8) anyerror!void = null,
};

pub const MessageInput = struct {
    store: []const u8,
    record: []const u8,
    key: []const u8,
    session: []const u8,
    text_path: []const u8,
    text: ?[]const u8 = null,
    drop_reply: ?[]const u8 = null,
    captured: ?*const fn (std.Io, []const u8) anyerror!void = null,
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
    record: []const u8,
    key: []const u8,
    session: []const u8,
    action_id: u64,
    decision: protocol.PermissionDecision = .deny,
    drop_reply: ?[]const u8 = null,
    captured: ?*const fn (std.Io, []const u8) anyerror!void = null,
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

/// Observation only: never creates a Store, acquires ownership or reads SQLite.
pub fn hostStatus(io: std.Io, store_path: []const u8) HostStatus {
    return hostStatusUntil(io, store_path, null);
}

/// Startup callers can bound the entire readiness loop, including each probe.
pub fn hostStatusUntil(io: std.Io, store_path: []const u8, deadline: ?i128) HostStatus {
    const paths = platform.resolveClientPaths(io, store_path) catch |err| return switch (err) {
        error.FileNotFound => .unavailable,
        else => .access_failure,
    };
    var store_dir = std.Io.Dir.cwd().openDir(io, paths.store.slice(), .{}) catch return .access_failure;
    defer store_dir.close(io);
    // A replaced lock node may be a FIFO: open must not wait for a writer
    // before the nonblocking lock probe can classify the selected Store.
    const fd = std.posix.openat(store_dir.handle, "host.lock", .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| return switch (err) {
        error.FileNotFound => .unavailable,
        else => .access_failure,
    };
    const lock_file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer lock_file.close(io);
    const stat = lock_file.stat(io) catch return .access_failure;
    if (stat.kind != .file) return .access_failure;
    return switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB))) {
        .SUCCESS => .unavailable,
        .AGAIN => readHostInfo(io, &paths, deadline),
        else => .access_failure,
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
    const reply = sendSource(io, paths, "/v1/host-info", body.len, null, body.slice(), null, &reply_buffer, until) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_failure,
        error.WrongWireVersion, error.InvalidResponse, error.ResponseHeaderTooLarge,
        error.ResponseTooLarge, error.InvalidCharacter, error.Overflow => .incompatible,
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

pub fn configure(io: std.Io, input: ConfigureInput, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    try captureConfigure(io, &paths, input);
    if (input.captured) |notify| try notify(io, input.record);
    return sendRecord(io, &paths, input.record, "/v1/configure", input.drop_reply, reply_buffer);
}

pub fn message(io: std.Io, input: MessageInput, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    try captureMessage(io, &paths, input);
    if (input.captured) |notify| try notify(io, input.record);
    return sendRecord(io, &paths, input.record, "/v1/message", input.drop_reply, reply_buffer);
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

pub fn denyPermission(io: std.Io, input: PermissionDecisionInput, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    if (input.action_id == 0) return error.InvalidTarget;
    try capturePermissionDecision(io, &paths, input);
    if (input.captured) |notify| try notify(io, input.record);
    return sendRecord(io, &paths, input.record, "/v1/control/permission-decision", input.drop_reply, reply_buffer);
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
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    reply_buffer: *ReplyBuffer,
) !CommandReply {
    reply_buffer.len = 0;
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, "observe_command", paths.store.slice(), "key", key, null, null);
    return sendBytes(io, &paths, "/v1/observe-command", body.slice(), null, reply_buffer);
}

pub fn readResult(
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    reply_buffer.len = 0;
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, "read_result", paths.store.slice(), "key", key, null, null);
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const stream = try address.connect(io);
    defer stream.close(io);
    const fd = stream.socket.handle;
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/read-result HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{body.len});
    try writeAll(fd, header);
    try writeAll(fd, body.slice());
    return readResultResponse(io, fd, destination, reply_buffer);
}

pub fn inspectSession(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    profile: protocol.ReportProfile,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ReportReply {
    reply_buffer.len = 0;
    if (session.len == 0 or session.len > protocol.max_session_bytes or
        !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, "inspect_session", paths.store.slice(), "session", session, null, profile);
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const stream = try address.connect(io);
    defer stream.close(io);
    const fd = stream.socket.handle;
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/inspect-session HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{body.len});
    try writeAll(fd, header);
    try writeAll(fd, body.slice());
    return readReportResponse(io, fd, destination, reply_buffer);
}

pub fn readActionArguments(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return readActionContent(io, store_path, session, action_id, "read_action_arguments", "/v1/read-action-arguments", destination, reply_buffer);
}

pub fn readActionCallId(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return readActionContent(io, store_path, session, action_id, "read_action_call_id", "/v1/read-action-call-id", destination, reply_buffer);
}

fn readActionContent(
    io: std.Io,
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
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, kind, paths.store.slice(), "session", session, action_id, null);
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const stream = try address.connect(io);
    defer stream.close(io);
    const fd = stream.socket.handle;
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{ route, body.len });
    try writeAll(fd, header);
    try writeAll(fd, body.slice());
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

// Capture writes identity first, before variable content. Recover the bounded
// prefix without loading or copying the potentially large captured payload.
pub fn readCapturedIdentity(io: std.Io, path: []const u8, handle: []const u8) !CapturedIdentity {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
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

fn captureConfigure(io: std.Io, paths: *const platform.Paths, input: ConfigureInput) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, input.record, &output_buffer);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"configure\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(input.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
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
    try capture.write("}}");
    try capture.commit();
}

fn captureMessage(io: std.Io, paths: *const platform.Paths, input: MessageInput) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, input.record, &output_buffer);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"message\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(input.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
    try capture.write(",\"text\":{\"state\":\"value\",\"value\":");
    if (input.text) |value| {
        if (value.len > protocol.max_sqlite_content_bytes) return error.ContentTooLarge;
        try capture.writeJsonString(value);
    } else try capture.writeJsonFile(input.text_path);
    try capture.write("}}");
    try capture.commit();
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

fn capturePermissionDecision(io: std.Io, paths: *const platform.Paths, input: PermissionDecisionInput) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, input.record, &output_buffer);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"permission_decision\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(input.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
    var suffix: [96]u8 = undefined;
    try capture.write(try std.fmt.bufPrint(&suffix, ",\"action\":\"{d}\",\"decision\":\"{s}\"}}", .{
        input.action_id,
        @tagName(input.decision),
    }));
    try capture.commit();
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
    return sendSource(io, paths, route, length, &file, null, drop_reply, reply_buffer, null);
}

fn sendBytes(
    io: std.Io,
    paths: *const platform.Paths,
    route: []const u8,
    body: []const u8,
    drop_reply: ?[]const u8,
    reply_buffer: *ReplyBuffer,
) !CommandReply {
    return sendSource(io, paths, route, body.len, null, body, drop_reply, reply_buffer, null);
}

fn sendSource(
    io: std.Io,
    paths: *const platform.Paths,
    route: []const u8,
    length: u64,
    file: ?*std.Io.File,
    bytes: ?[]const u8,
    drop_reply: ?[]const u8,
    reply_buffer: *ReplyBuffer,
    until: ?i128,
) !CommandReply {
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const stream = if (until == null) try address.connect(io) else null;
    const fd = if (stream) |connected| connected.socket.handle else try connectUntil(io, address.path, until.?);
    defer {
        if (stream) |connected| connected.close(io) else _ = std.c.close(fd);
    }
    var header_buffer: [512]u8 = undefined;
    const header = if (drop_reply) |drop|
        try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\nX-Rui-Test-Drop-Reply: {s}\r\n\r\n", .{ route, length, drop })
    else
        try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{ route, length });
    try writeAllUntil(io, fd, header, until);
    if (file) |source| {
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var sent: u64 = 0;
        while (sent < length) {
            const wanted: usize = @intCast(@min(length - sent, buffer.len));
            const count = try source.readStreaming(io, &.{buffer[0..wanted]});
            if (count != wanted) return error.RecordChangedDuringSend;
            try writeAllUntil(io, fd, buffer[0..count], until);
            sent += count;
        }
    } else try writeAllUntil(io, fd, bytes.?, until);
    return readCommandResponseUntil(io, fd, reply_buffer, until);
}

fn connectUntil(io: std.Io, path: []const u8, deadline: i128) !std.posix.fd_t {
    if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline) return error.TransferInactive;
    const fd = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(fd) != .SUCCESS) return error.UnixConnectFailed;
    const socket: std.posix.fd_t = @intCast(fd);
    errdefer _ = std.c.close(socket);
    if (std.c.fcntl(socket, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.UnixConnectFailed;
    const flags = std.c.fcntl(socket, std.c.F.GETFL);
    const nonblocking: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    if (flags < 0 or std.c.fcntl(socket, std.c.F.SETFL, flags | @as(c_int, @intCast(nonblocking))) < 0) return error.UnixConnectFailed;
    var address: std.posix.sockaddr.un = .{ .path = undefined };
    @memcpy(address.path[0..path.len], path);
    address.path[path.len] = 0;
    const size: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1);
    if (@hasField(std.posix.sockaddr.un, "len")) address.len = @intCast(size);
    switch (std.posix.errno(std.c.connect(socket, @ptrCast(&address), size))) {
        .SUCCESS => {},
        .INPROGRESS, .AGAIN => {
            const left = deadline - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
            if (left <= 0) return error.TransferInactive;
            var poll_fd = [_]std.posix.pollfd{.{ .fd = socket, .events = std.posix.POLL.OUT, .revents = 0 }};
            const milliseconds: i32 = @intCast(@min(std.math.maxInt(i32), @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
            if (try std.posix.poll(&poll_fd, milliseconds) == 0) return error.TransferInactive;
            var result: c_int = 0;
            var result_len: std.posix.socklen_t = @sizeOf(c_int);
            if (std.c.getsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &result, &result_len) < 0 or result_len != @sizeOf(c_int) or result < 0) return error.UnixConnectFailed;
            if (result != 0) return connectFailure(@enumFromInt(result));
        },
        else => |err| return connectFailure(err),
    }
    if (std.c.fcntl(socket, std.c.F.SETFL, flags) < 0) return error.UnixConnectFailed;
    return socket;
}

fn connectFailure(code: std.posix.E) error{ AccessDenied, PermissionDenied, UnixConnectFailed } {
    return switch (code) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        else => error.UnixConnectFailed,
    };
}

const ResponseKind = enum { command_json, result_text };

const ResponseHead = struct {
    status: u16,
    content_length: u64,
    kind: ResponseKind,
};

fn readResponseHead(fd: std.posix.fd_t) !ResponseHead {
    return readResponseHeadWithInactivity(fd, 60_000);
}

fn readResponseHeadWithInactivity(fd: std.posix.fd_t, inactivity_ms: i32) !ResponseHead {
    return readResponseHeadUntil(std.Io.Threaded.global_single_threaded.io(), fd, inactivity_ms, null);
}

fn readResponseHeadUntil(io: std.Io, fd: std.posix.fd_t, inactivity_ms: i32, until: ?i128) !ResponseHead {
    var header_buffer: [protocol.max_header_bytes]u8 = undefined;
    // Ordinary requests start their inactivity window after the first byte;
    // Host readiness alone has an absolute deadline that includes this wait.
    if (until != null and !try waitReadableUntil(io, fd, inactivity_ms, until)) return error.ResponseInactive;
    const first_count = try std.posix.read(fd, header_buffer[0..1]);
    if (first_count == 0) return error.TruncatedResponse;
    var used: usize = first_count;
    while (used < header_buffer.len) {
        if (used >= 4 and std.mem.eql(u8, header_buffer[used - 4 .. used], "\r\n\r\n")) break;
        if (!try waitReadableUntil(io, fd, inactivity_ms, until)) return error.ResponseInactive;
        const count = try std.posix.read(fd, header_buffer[used .. used + 1]);
        if (count == 0) return error.TruncatedResponse;
        used += count;
    } else return error.ResponseHeaderTooLarge;
    var lines = std.mem.splitSequence(u8, header_buffer[0..used], "\r\n");
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
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (length != null) return error.InvalidResponse;
            length = try std.fmt.parseInt(u64, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Wire-Version")) {
            if (wire_ok != null) return error.InvalidResponse;
            wire_ok = std.mem.eql(u8, value, protocol.wire_version);
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            if (kind != null) return error.InvalidResponse;
            kind = if (std.ascii.eqlIgnoreCase(value, "application/json"))
                .command_json
            else if (std.ascii.eqlIgnoreCase(value, "text/plain; charset=utf-8"))
                .result_text
            else
                return error.InvalidResponse;
        }
    }
    if (wire_ok != true) return error.WrongWireVersion;
    return .{
        .status = status,
        .content_length = length orelse return error.InvalidResponse,
        .kind = kind orelse return error.InvalidResponse,
    };
}

fn readCommandResponse(fd: std.posix.fd_t, reply_buffer: *ReplyBuffer) !CommandReply {
    return readCommandResponseUntil(std.Io.Threaded.global_single_threaded.io(), fd, reply_buffer, null);
}

fn readCommandResponseUntil(io: std.Io, fd: std.posix.fd_t, reply_buffer: *ReplyBuffer, until: ?i128) !CommandReply {
    reply_buffer.len = 0;
    const head = try readResponseHeadUntil(io, fd, 60_000, until);
    if (head.kind != .command_json) return error.InvalidResponse;
    return readCommandBodyUntil(io, fd, head, reply_buffer, until);
}

fn readResultResponse(
    io: std.Io,
    fd: std.posix.fd_t,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    reply_buffer.len = 0;
    const head = try readResponseHead(fd);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        return .{ .command = try readCommandBody(fd, head, reply_buffer) };
    }
    if (head.kind != .result_text) return error.InvalidResponse;
    var remaining = head.content_length;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    while (remaining != 0) {
        if (!try waitReadable(fd, 60_000)) return error.ResponseInactive;
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        const count = try std.posix.read(fd, buffer[0..wanted]);
        if (count == 0) return error.TruncatedResponse;
        try destination.writeStreamingAll(io, buffer[0..count]);
        remaining -= count;
    }
    return .{ .answer = .{ .bytes = head.content_length } };
}

fn readReportResponse(
    io: std.Io,
    fd: std.posix.fd_t,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ReportReply {
    reply_buffer.len = 0;
    const head = try readResponseHead(fd);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        return .{ .command = try readCommandBody(fd, head, reply_buffer) };
    }
    if (head.kind != .command_json) return error.InvalidResponse;
    var remaining = head.content_length;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    while (remaining != 0) {
        if (!try waitReadable(fd, 60_000)) return error.ResponseInactive;
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        const count = try std.posix.read(fd, buffer[0..wanted]);
        if (count == 0) return error.TruncatedResponse;
        try destination.writeStreamingAll(io, buffer[0..count]);
        remaining -= count;
    }
    return .{ .report = .{ .bytes = head.content_length } };
}

fn readCommandBody(fd: std.posix.fd_t, head: ResponseHead, reply_buffer: *ReplyBuffer) !CommandReply {
    return readCommandBodyUntil(std.Io.Threaded.global_single_threaded.io(), fd, head, reply_buffer, null);
}

fn readCommandBodyUntil(io: std.Io, fd: std.posix.fd_t, head: ResponseHead, reply_buffer: *ReplyBuffer, until: ?i128) !CommandReply {
    reply_buffer.len = 0;
    errdefer reply_buffer.len = 0;
    if (head.content_length > protocol.max_response_bytes) return error.ResponseTooLarge;
    const body_length: usize = @intCast(head.content_length);
    var offset: usize = 0;
    while (offset < body_length) {
        if (!try waitReadableUntil(io, fd, 60_000, until)) return error.ResponseInactive;
        const count = try std.posix.read(fd, reply_buffer.bytes[offset..body_length]);
        if (count == 0) return error.TruncatedResponse;
        offset += count;
    }
    reply_buffer.len = body_length;
    return .{ .status = head.status, .body = reply_buffer.slice() };
}

fn waitReadable(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var poll_fd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return try std.posix.poll(&poll_fd, timeout_ms) != 0;
}

fn waitReadableUntil(io: std.Io, fd: std.posix.fd_t, timeout_ms: i32, until: ?i128) !bool {
    if (until) |deadline| {
        const left = deadline - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (left <= 0) return false;
        const milliseconds: i32 = @intCast(@min(timeout_ms, @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        return waitReadable(fd, milliseconds);
    }
    return waitReadable(fd, timeout_ms);
}

fn writeAll(fd: std.posix.fd_t, value: []const u8) !void {
    return writeAllUntil(std.Io.Threaded.global_single_threaded.io(), fd, value, null);
}

fn writeAllUntil(io: std.Io, fd: std.posix.fd_t, value: []const u8, until: ?i128) !void {
    var offset: usize = 0;
    while (offset < value.len) {
        const timeout = if (until) |deadline| blk: {
            const left = deadline - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
            if (left <= 0) return error.TransferInactive;
            break :blk @as(i32, @intCast(@min(60_000, @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms))));
        } else 60_000;
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fd, timeout) == 0) return error.TransferInactive;
        const count = std.c.write(fd, value[offset..].ptr, value.len - offset);
        if (count < 0) return error.WriteFailed;
        if (count == 0) return error.ConnectionClosed;
        offset += @intCast(count);
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
    try capturePermissionDecision(std.testing.io, &paths, .{
        .store = "unused",
        .record = permission_path,
        .key = &escaped_key,
        .session = &escaped_session,
        .action_id = std.math.maxInt(u64),
        .decision = .allow_once,
    });
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
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: 1\r\n\r\n",
        .{context.length},
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
