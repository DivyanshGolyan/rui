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

pub fn configure(io: std.Io, input: ConfigureInput) !u16 {
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    try captureConfigure(io, &paths, input);
    return sendRecord(io, &paths, input.record, "/v1/configure", input.drop_reply);
}

pub fn message(io: std.Io, input: MessageInput) !u16 {
    const paths = try platform.resolveClientPaths(io, input.store);
    try validateIdentityInputs(input.key, input.session);
    try captureMessage(io, &paths, input);
    return sendRecord(io, &paths, input.record, "/v1/message", input.drop_reply);
}

pub fn retry(
    io: std.Io,
    store_path: []const u8,
    record: []const u8,
    kind: []const u8,
) !u16 {
    const paths = try platform.resolveClientPaths(io, store_path);
    const route = if (std.mem.eql(u8, kind, "configure"))
        "/v1/configure"
    else if (std.mem.eql(u8, kind, "message"))
        "/v1/message"
    else
        return error.InvalidRetryKind;
    return sendRecord(io, &paths, record, route, null);
}

pub fn observeCommand(io: std.Io, store_path: []const u8, key: []const u8) !u16 {
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.ResponseBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"observe_command\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"key\":");
    try body.appendJsonString(key);
    try body.append("}");
    return sendBytes(io, &paths, "/v1/observe-command", body.slice(), null);
}

pub fn inspectSession(io: std.Io, store_path: []const u8, session: []const u8) !u16 {
    if (session.len == 0 or session.len > protocol.max_session_bytes or
        !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.ResponseBuffer = .{};
    try body.append("{\"version\":\"1\",\"kind\":\"inspect_session\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append(",\"session\":");
    try body.appendJsonString(session);
    try body.append("}");
    return sendBytes(io, &paths, "/v1/inspect-session", body.slice(), null);
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
) !u16 {
    var file = try std.Io.Dir.cwd().openFile(io, record, .{});
    defer file.close(io);
    const length = try file.length(io);
    return sendSource(io, paths, route, length, &file, null, drop_reply);
}

fn sendBytes(
    io: std.Io,
    paths: *const platform.Paths,
    route: []const u8,
    body: []const u8,
    drop_reply: ?[]const u8,
) !u16 {
    return sendSource(io, paths, route, body.len, null, body, drop_reply);
}

fn sendSource(
    io: std.Io,
    paths: *const platform.Paths,
    route: []const u8,
    length: u64,
    file: ?*std.Io.File,
    bytes: ?[]const u8,
    drop_reply: ?[]const u8,
) !u16 {
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
    return readResponse(io, fd);
}

fn readResponse(io: std.Io, fd: std.posix.fd_t) !u16 {
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
    var length: ?usize = null;
    var wire_ok = false;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (length != null) return error.InvalidResponse;
            length = try std.fmt.parseInt(usize, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Latifa-Wire-Version")) {
            wire_ok = std.mem.eql(u8, value, protocol.wire_version);
        }
    }
    if (!wire_ok) return error.WrongWireVersion;
    const body_length = length orelse return error.InvalidResponse;
    if (body_length > 16 * 1024) return error.ResponseTooLarge;
    var body: [16 * 1024]u8 = undefined;
    var offset: usize = 0;
    while (offset < body_length) {
        if (!try waitReadable(fd, 60_000)) return error.ResponseInactive;
        const count = try std.posix.read(fd, body[offset..body_length]);
        if (count == 0) return error.TruncatedResponse;
        offset += count;
    }
    try std.Io.File.stdout().writeStreamingAll(io, body[0..body_length]);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    return status;
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
