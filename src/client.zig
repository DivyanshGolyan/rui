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
    model: OptionalText = .{},
    instructions: OptionalFile = .{},
    tools: ?[]const u8 = null,
    permission_mode: OptionalText = .{},
    output_schema: OptionalFile = .{},
    drop_reply: ?[]const u8 = null,
};

pub const MessageInput = struct {
    store: []const u8,
    record: []const u8,
    key: []const u8,
    session: []const u8,
    text_path: []const u8,
    drop_reply: ?[]const u8 = null,
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

pub const ReplyBuffer = protocol.ResponseBuffer;

pub const CommandReply = struct {
    status: u16,
    // Borrowed from the caller's ReplyBuffer until that buffer is reused.
    body: []const u8,
};

pub const ResultReply = union(enum) {
    answer: struct { bytes: u64 },
    command: CommandReply,
};

pub fn configure(io: std.Io, input: ConfigureInput, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    try captureConfigure(io, &paths, input);
    return sendRecord(io, &paths, input.record, "/v1/configure", input.drop_reply, reply_buffer);
}

pub fn message(io: std.Io, input: MessageInput, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    try captureMessage(io, &paths, input);
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
    var body: protocol.ResponseBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"observe_command\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"key\":");
    try body.appendJsonString(key);
    try body.append("}");
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
    var body: protocol.ResponseBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"read_result\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"key\":");
    try body.appendJsonString(key);
    try body.append("}");
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const stream = try address.connect(io);
    defer stream.close(io);
    const fd = stream.socket.handle;
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/read-result HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Latifa-Wire-Version: 1\r\n\r\n", .{body.len});
    try writeAll(fd, header);
    try writeAll(fd, body.slice());
    return readResultResponse(io, fd, destination, reply_buffer);
}

pub fn inspectSession(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    reply_buffer: *ReplyBuffer,
) !CommandReply {
    reply_buffer.len = 0;
    if (session.len == 0 or session.len > protocol.max_session_bytes or
        !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.ResponseBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"session\":");
    try body.appendJsonString(session);
    try body.append("}");
    return sendBytes(io, &paths, "/v1/inspect-session", body.slice(), null, reply_buffer);
}

fn validateIdentityInputs(key: []const u8, session: []const u8) !void {
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    if (session.len == 0 or session.len > protocol.max_session_bytes or
        !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
}

fn captureConfigure(io: std.Io, paths: *const platform.Paths, input: ConfigureInput) !void {
    var capture = try Capture.open(io, input.record);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"configure\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(input.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
    try capture.write(",\"configuration\":{\"workspace\":");
    try capture.writeOptionalText(input.workspace);
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
    var capture = try Capture.open(io, input.record);
    errdefer capture.abort();
    try capture.write("{\"version\":\"1\",\"kind\":\"message\",\"store\":");
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(input.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
    try capture.write(",\"text\":{\"state\":\"value\",\"value\":");
    try capture.writeJsonFile(input.text_path);
    try capture.write("}}");
    try capture.commit();
}

fn captureSessionStop(io: std.Io, paths: *const platform.Paths, input: SessionStopInput) !void {
    var capture = try Capture.open(io, input.record);
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
    var capture = try Capture.open(io, input.record);
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

const Capture = struct {
    io: std.Io,
    file: std.Io.File,
    parent: std.Io.Dir,
    final_name: protocol.Bounded(std.Io.Dir.max_name_bytes) = .{},
    temporary_name: protocol.Bounded(std.Io.Dir.max_name_bytes) = .{},
    active: bool = true,
    file_open: bool = true,
    published: bool = false,

    fn open(io: std.Io, record_path: []const u8) !Capture {
        const parent_path = std.fs.path.dirname(record_path) orelse ".";
        const final_name = std.fs.path.basename(record_path);
        if (final_name.len == 0) return error.InvalidRecordPath;
        var parent = try std.Io.Dir.cwd().createDirPathOpen(io, parent_path, .{
            .permissions = .fromMode(0o700),
        });
        errdefer parent.close(io);
        const stat = try parent.stat(io);
        if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
        if (parent.statFile(io, final_name, .{})) |_| return error.RecordAlreadyExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        var temporary_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const temporary = try std.fmt.bufPrint(&temporary_buffer, ".{s}.capture-{d}", .{
            final_name,
            std.c.getpid(),
        });
        const file = try parent.createFile(io, temporary, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        var capture = Capture{ .io = io, .file = file, .parent = parent };
        try capture.final_name.set(final_name);
        try capture.temporary_name.set(temporary);
        return capture;
    }

    fn abort(self: *Capture) void {
        if (!self.active) return;
        if (self.file_open) self.file.close(self.io);
        if (!self.published) self.parent.deleteFile(self.io, self.temporary_name.slice()) catch |err| {
            std.debug.print("latifa: retained caller capture after cleanup failure: {s}\n", .{@errorName(err)});
        };
        self.parent.close(self.io);
        self.active = false;
    }

    fn commit(self: *Capture) !void {
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
        self.parent.close(self.io);
        self.active = false;
    }

    fn write(self: *Capture, bytes: []const u8) !void {
        try self.file.writeStreamingAll(self.io, bytes);
    }

    fn writeJsonString(self: *Capture, value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        try self.write("\"");
        for (value) |byte| try self.writeEscapedByte(byte);
        try self.write("\"");
    }

    fn writeEscapedByte(self: *Capture, byte: u8) !void {
        switch (byte) {
            '"' => try self.write("\\\""),
            '\\' => try self.write("\\\\"),
            '\x08' => try self.write("\\b"),
            '\x0c' => try self.write("\\f"),
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            0...7, 11, 14...0x1f => {
                const alphabet = "0123456789abcdef";
                var escaped: [6]u8 = undefined;
                escaped = .{ '\\', 'u', '0', '0', alphabet[byte >> 4], alphabet[byte & 0x0f] };
                try self.write(&escaped);
            },
            else => try self.write(&.{byte}),
        }
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
        var file = if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdin()
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer if (!std.mem.eql(u8, path, "-")) file.close(self.io);
        try self.write("\"");
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var validator = Utf8Validator{};
        while (true) {
            const count = file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (count == 0) break;
            try validator.feed(buffer[0..count]);
            for (buffer[0..count]) |byte| try self.writeEscapedByte(byte);
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
    return sendSource(io, paths, route, length, &file, null, drop_reply, reply_buffer);
}

fn sendBytes(
    io: std.Io,
    paths: *const platform.Paths,
    route: []const u8,
    body: []const u8,
    drop_reply: ?[]const u8,
    reply_buffer: *ReplyBuffer,
) !CommandReply {
    return sendSource(io, paths, route, body.len, null, body, drop_reply, reply_buffer);
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
) !CommandReply {
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const stream = try address.connect(io);
    defer stream.close(io);
    const fd = stream.socket.handle;
    var header_buffer: [512]u8 = undefined;
    const header = if (drop_reply) |drop|
        try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Latifa-Wire-Version: 1\r\nX-Latifa-Test-Drop-Reply: {s}\r\n\r\n", .{ route, length, drop })
    else
        try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Latifa-Wire-Version: 1\r\n\r\n", .{ route, length });
    try writeAll(fd, header);
    if (file) |source| {
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var sent: u64 = 0;
        while (sent < length) {
            const wanted: usize = @intCast(@min(length - sent, buffer.len));
            const count = try source.readStreaming(io, &.{buffer[0..wanted]});
            if (count != wanted) return error.RecordChangedDuringSend;
            try writeAll(fd, buffer[0..count]);
            sent += count;
        }
    } else try writeAll(fd, bytes.?);
    return readCommandResponse(fd, reply_buffer);
}

const ResponseKind = enum { command_json, result_text };

const ResponseHead = struct {
    status: u16,
    content_length: u64,
    kind: ResponseKind,
};

fn readResponseHead(fd: std.posix.fd_t) !ResponseHead {
    var header_buffer: [protocol.max_header_bytes]u8 = undefined;
    var used: usize = 0;
    while (used < header_buffer.len) {
        if (!try waitReadable(fd, 60_000)) return error.ResponseInactive;
        const count = try std.posix.read(fd, header_buffer[used .. used + 1]);
        if (count == 0) return error.TruncatedResponse;
        used += count;
        if (used >= 4 and std.mem.eql(u8, header_buffer[used - 4 .. used], "\r\n\r\n")) break;
    } else return error.ResponseHeaderTooLarge;
    var lines = std.mem.splitSequence(u8, header_buffer[0..used], "\r\n");
    const status_line = lines.next() orelse return error.InvalidResponse;
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidResponse, "HTTP/1.1")) return error.InvalidResponse;
    const status = try std.fmt.parseInt(u16, parts.next() orelse return error.InvalidResponse, 10);
    var length: ?u64 = null;
    var wire_ok = false;
    var kind: ?ResponseKind = null;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (length != null) return error.InvalidResponse;
            length = try std.fmt.parseInt(u64, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Latifa-Wire-Version")) {
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
    if (!wire_ok) return error.WrongWireVersion;
    return .{
        .status = status,
        .content_length = length orelse return error.InvalidResponse,
        .kind = kind orelse return error.InvalidResponse,
    };
}

fn readCommandResponse(fd: std.posix.fd_t, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    const head = try readResponseHead(fd);
    if (head.kind != .command_json) return error.InvalidResponse;
    return readCommandBody(fd, head, reply_buffer);
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

fn readCommandBody(fd: std.posix.fd_t, head: ResponseHead, reply_buffer: *ReplyBuffer) !CommandReply {
    reply_buffer.len = 0;
    errdefer reply_buffer.len = 0;
    if (head.content_length > protocol.max_response_bytes) return error.ResponseTooLarge;
    const body_length: usize = @intCast(head.content_length);
    var offset: usize = 0;
    while (offset < body_length) {
        if (!try waitReadable(fd, 60_000)) return error.ResponseInactive;
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

fn writeAll(fd: std.posix.fd_t, value: []const u8) !void {
    var offset: usize = 0;
    while (offset < value.len) {
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fd, 60_000) == 0) return error.TransferInactive;
        const count = std.c.write(fd, value[offset..].ptr, value.len - offset);
        if (count < 0) return error.WriteFailed;
        if (count == 0) return error.ConnectionClosed;
        offset += @intCast(count);
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
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Latifa-Wire-Version: 1\r\n\r\n{\"status\":\"error\"}",
    );
    var buffer: ReplyBuffer = .{};
    const reply = try readCommandResponse(descriptors[0], &buffer);
    try std.testing.expectEqual(@as(u16, 409), reply.status);
    try std.testing.expectEqualStrings("{\"status\":\"error\"}", reply.body);
    try std.testing.expectEqual(@intFromPtr(buffer.bytes[0..].ptr), @intFromPtr(reply.body.ptr));
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

    var stop_path_buffer: [protocol.max_store_bytes + 64]u8 = undefined;
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

    var interruption_path_buffer: [protocol.max_store_bytes + 64]u8 = undefined;
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
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\nX-Latifa-Wire-Version: 1\r\n\r\n{}",
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
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nX-Latifa-Wire-Version: 1\r\n\r\n",
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

test "result response streams eight MiB into an explicit file" {
    const result_bytes = 8 * 1024 * 1024;
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
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Latifa-Wire-Version: 1\r\n\r\n{\"status\":\"error\"}",
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
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 4\r\nX-Latifa-Wire-Version: 1\r\n\r\nab",
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
