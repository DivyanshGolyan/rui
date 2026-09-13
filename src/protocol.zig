const std = @import("std");

pub const wire_version = "1";
pub const max_key_bytes = 128;
pub const max_session_bytes = 128;
pub const max_store_bytes = 4096;
pub const max_workspace_bytes = 4096;
pub const max_model_bytes = 256;
pub const max_header_bytes = 16 * 1024;
pub const content_window_bytes = 4096;
pub const max_json_depth = 64;
pub const max_sqlite_content_bytes: u64 = 1024 * 1024 * 1024 - 4096;

pub fn Bounded(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn set(self: *@This(), value: []const u8) !void {
            if (value.len > capacity) return error.ValueTooLong;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        pub fn eql(self: *const @This(), value: []const u8) bool {
            return std.mem.eql(u8, self.slice(), value);
        }
    };
}

pub const FieldState = enum { omitted, value };

pub fn OptionalBounded(comptime capacity: usize) type {
    return struct {
        state: FieldState = .omitted,
        value: Bounded(capacity) = .{},
    };
}

pub const ContentField = struct {
    state: enum { omitted, value, explicit_null } = .omitted,
    // A parsed request owns an unlinked file descriptor. The Store imports
    // through this sealed custody; no pathname can be swapped after capture.
    file: ?std.Io.File = null,
    length: u64 = 0,
    digest: [32]u8 = [_]u8{0} ** 32,

    pub fn hasFile(self: *const ContentField) bool {
        return self.file != null;
    }
};

pub const ToolsField = struct {
    state: FieldState = .omitted,
    count: u2 = 0,
    values: [2]enum { bash, edit } = undefined,
};

pub const Configuration = struct {
    workspace: OptionalBounded(max_workspace_bytes) = .{},
    model: OptionalBounded(max_model_bytes) = .{},
    instructions: ContentField = .{},
    tools: ToolsField = .{},
    permission_mode: OptionalBounded(16) = .{},
    output_schema: ContentField = .{},
};

pub const Kind = enum { configure, message, observe_command, read_result, inspect_session };

pub const ConfigureCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    configuration: Configuration = .{},

    pub fn removeTemporaryContent(self: *ConfigureCommand, io: std.Io) !void {
        var cleanup_error: ?anyerror = null;
        removeContent(&self.configuration.instructions, io) catch |err| {
            cleanup_error = err;
        };
        removeContent(&self.configuration.output_schema, io) catch |err| {
            cleanup_error = err;
        };
        if (cleanup_error) |err| return err;
    }

    pub fn semanticDigest(self: *const ConfigureCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "latifa/core/configure/v1");
        hashField(&hash, self.session.slice());
        hashOptional(&hash, &self.configuration.workspace);
        hashOptional(&hash, &self.configuration.model);
        hashContent(&hash, &self.configuration.instructions);
        hash.update(&.{@intFromEnum(self.configuration.tools.state)});
        if (self.configuration.tools.state == .value) {
            hash.update(&.{self.configuration.tools.count});
            for (self.configuration.tools.values[0..self.configuration.tools.count]) |tool| {
                hashField(&hash, @tagName(tool));
            }
        }
        hashOptional(&hash, &self.configuration.permission_mode);
        hashContent(&hash, &self.configuration.output_schema);
        return hash.finalResult();
    }
};

pub const MessageCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
    text: ContentField = .{},

    pub fn removeTemporaryContent(self: *MessageCommand, io: std.Io) !void {
        try removeContent(&self.text, io);
    }

    pub fn semanticDigest(self: *const MessageCommand) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "latifa/core/message/v1");
        hashField(&hash, self.session.slice());
        hashContent(&hash, &self.text);
        return hash.finalResult();
    }
};

pub const ObserveCommand = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
};

pub const ReadResult = struct {
    store: Bounded(max_store_bytes) = .{},
    key: Bounded(max_key_bytes) = .{},
};

pub const InspectSession = struct {
    store: Bounded(max_store_bytes) = .{},
    session: Bounded(max_session_bytes) = .{},
};

pub const Request = union(Kind) {
    configure: ConfigureCommand,
    message: MessageCommand,
    observe_command: ObserveCommand,
    read_result: ReadResult,
    inspect_session: InspectSession,

    pub fn removeTemporaryContent(self: *Request, io: std.Io) !void {
        switch (self.*) {
            .configure => |*command| try command.removeTemporaryContent(io),
            .message => |*command| try command.removeTemporaryContent(io),
            .observe_command, .read_result, .inspect_session => {},
        }
    }

    pub fn store(self: *const Request) []const u8 {
        return switch (self.*) {
            inline else => |request| request.store.slice(),
        };
    }
};

fn removeContent(content: *ContentField, io: std.Io) !void {
    if (content.file) |file| file.close(io);
    content.file = null;
    content.state = .omitted;
}

fn hashField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hash.update(&length);
    hash.update(value);
}

fn hashOptional(hash: *std.crypto.hash.sha2.Sha256, field: anytype) void {
    hash.update(&.{@intFromEnum(field.state)});
    if (field.state == .value) hashField(hash, field.value.slice());
}

fn hashContent(hash: *std.crypto.hash.sha2.Sha256, field: *const ContentField) void {
    hash.update(&.{@intFromEnum(field.state)});
    if (field.state == .value) {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, field.length, .big);
        hash.update(&length);
        hash.update(&field.digest);
    }
}

pub fn contentHasher() std.crypto.hash.sha2.Sha256 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "latifa/content/v1");
    return hash;
}

pub fn contentDigest(value: []const u8) [32]u8 {
    var hash = contentHasher();
    hash.update(value);
    return hash.finalResult();
}

pub const ParseOptions = struct {
    io: std.Io,
    fd: std.posix.fd_t,
    content_length: u64,
    scratch_path: []const u8,
    request_number: u64,
    fault_content_acquire: bool = false,
    fault_content_write: bool = false,
    fault_content_short_write: bool = false,
    fault_content_seal: bool = false,
    cleanup_failed: *bool,
};

pub fn parseRequest(options: ParseOptions) !Request {
    var source = SocketBody.init(options.fd, options.content_length);
    var parser = Parser{ .source = &source, .options = options };
    var request = try parser.parse();
    errdefer request.removeTemporaryContent(options.io) catch {
        options.cleanup_failed.* = true;
    };
    if (source.remaining != 0 or source.start != source.end) return error.TrailingInput;
    return request;
}

const SocketBody = struct {
    fd: std.posix.fd_t,
    remaining: u64,
    buffer: [content_window_bytes]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn init(fd: std.posix.fd_t, length: u64) SocketBody {
        return .{ .fd = fd, .remaining = length };
    }

    fn readByte(self: *SocketBody) !u8 {
        if (self.start == self.end) try self.refill();
        const byte = self.buffer[self.start];
        self.start += 1;
        return byte;
    }

    fn refill(self: *SocketBody) !void {
        if (self.remaining == 0) return error.UnexpectedEndOfBody;
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fd, 60_000) == 0) return error.TransferInactive;
        const limit: usize = @intCast(@min(self.remaining, self.buffer.len));
        const count = try std.posix.read(self.fd, self.buffer[0..limit]);
        if (count == 0) return error.UnexpectedEndOfBody;
        self.remaining -= count;
        self.start = 0;
        self.end = count;
    }
};

const Parser = struct {
    source: *SocketBody,
    options: ParseOptions,
    content_ordinal: u8 = 0,

    fn parse(self: *Parser) !Request {
        try self.expectByte('{');
        try self.expectKey("version");
        var version: Bounded(8) = .{};
        try self.readSmallString(&version);
        if (!version.eql(wire_version)) return error.WrongWireVersion;
        try self.expectByte(',');
        try self.expectKey("kind");
        var kind_text: Bounded(32) = .{};
        try self.readSmallString(&kind_text);
        const kind: Kind = if (kind_text.eql("configure"))
            .configure
        else if (kind_text.eql("message"))
            .message
        else if (kind_text.eql("observe_command"))
            .observe_command
        else if (kind_text.eql("read_result"))
            .read_result
        else if (kind_text.eql("inspect_session"))
            .inspect_session
        else
            return error.UnknownCommand;

        try self.expectByte(',');
        try self.expectKey("store");
        var store: Bounded(max_store_bytes) = .{};
        try self.readSmallString(&store);

        var request: Request = switch (kind) {
            .configure => .{ .configure = try self.parseConfigure(store) },
            .message => .{ .message = try self.parseMessage(store) },
            .observe_command => .{ .observe_command = try self.parseObserve(store) },
            .read_result => .{ .read_result = try self.parseReadResult(store) },
            .inspect_session => .{ .inspect_session = try self.parseInspect(store) },
        };
        errdefer request.removeTemporaryContent(self.options.io) catch {
            self.options.cleanup_failed.* = true;
        };
        try self.expectByte('}');
        if (self.source.remaining != 0 or self.source.start != self.source.end) {
            return error.TrailingInput;
        }
        return request;
    }

    fn parseConfigure(self: *Parser, store: Bounded(max_store_bytes)) !ConfigureCommand {
        var request = ConfigureCommand{ .store = store };
        errdefer request.removeTemporaryContent(self.options.io) catch {
            self.options.cleanup_failed.* = true;
        };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("configuration");
        try self.expectByte('{');
        try self.expectKey("workspace");
        try self.readOptionalSmall(max_workspace_bytes, &request.configuration.workspace);
        try self.expectByte(',');
        try self.expectKey("model");
        try self.readOptionalSmall(max_model_bytes, &request.configuration.model);
        try self.expectByte(',');
        try self.expectKey("instructions");
        try self.readContent(&request.configuration.instructions, false);
        try self.expectByte(',');
        try self.expectKey("tools");
        try self.readTools(&request.configuration.tools);
        try self.expectByte(',');
        try self.expectKey("permission_mode");
        try self.readOptionalSmall(16, &request.configuration.permission_mode);
        try self.expectByte(',');
        try self.expectKey("output_schema");
        try self.readContent(&request.configuration.output_schema, true);
        try self.expectByte('}');
        return request;
    }

    fn parseMessage(self: *Parser, store: Bounded(max_store_bytes)) !MessageCommand {
        var request = MessageCommand{ .store = store };
        errdefer request.removeTemporaryContent(self.options.io) catch {
            self.options.cleanup_failed.* = true;
        };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        try self.expectByte(',');
        try self.expectKey("text");
        try self.readContent(&request.text, false);
        if (request.text.state != .value) return error.InvalidMessage;
        return request;
    }

    fn parseObserve(self: *Parser, store: Bounded(max_store_bytes)) !ObserveCommand {
        var request = ObserveCommand{ .store = store };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        return request;
    }

    fn parseInspect(self: *Parser, store: Bounded(max_store_bytes)) !InspectSession {
        var request = InspectSession{ .store = store };
        try self.expectByte(',');
        try self.expectKey("session");
        try self.readSmallString(&request.session);
        return request;
    }

    fn parseReadResult(self: *Parser, store: Bounded(max_store_bytes)) !ReadResult {
        var request = ReadResult{ .store = store };
        try self.expectByte(',');
        try self.expectKey("key");
        try self.readSmallString(&request.key);
        return request;
    }

    fn readOptionalSmall(self: *Parser, comptime capacity: usize, field: *OptionalBounded(capacity)) !void {
        try self.expectByte('{');
        try self.expectKey("state");
        var state: Bounded(16) = .{};
        try self.readSmallString(&state);
        if (state.eql("omitted")) {
            field.state = .omitted;
        } else if (state.eql("value")) {
            field.state = .value;
            try self.expectByte(',');
            try self.expectKey("value");
            try self.readSmallString(&field.value);
        } else return error.InvalidFieldState;
        try self.expectByte('}');
    }

    fn readContent(self: *Parser, field: *ContentField, allow_null: bool) !void {
        try self.expectByte('{');
        try self.expectKey("state");
        var state: Bounded(16) = .{};
        try self.readSmallString(&state);
        if (state.eql("omitted")) {
            field.state = .omitted;
        } else if (allow_null and state.eql("null")) {
            field.state = .explicit_null;
        } else if (state.eql("value")) {
            field.state = .value;
            try self.expectByte(',');
            try self.expectKey("value");
            try self.readContentString(field);
        } else return error.InvalidFieldState;
        try self.expectByte('}');
    }

    fn readTools(self: *Parser, tools: *ToolsField) !void {
        try self.expectByte('{');
        try self.expectKey("state");
        var state: Bounded(16) = .{};
        try self.readSmallString(&state);
        if (state.eql("omitted")) {
            tools.state = .omitted;
        } else if (state.eql("value")) {
            tools.state = .value;
            try self.expectByte(',');
            try self.expectKey("value");
            try self.expectByte('[');
            if (!try self.consumeIf(']')) {
                while (true) {
                    if (tools.count == tools.values.len) return error.TooManyTools;
                    var value: Bounded(16) = .{};
                    try self.readSmallString(&value);
                    const tool: @TypeOf(tools.values[0]) = if (value.eql("bash"))
                        .bash
                    else if (value.eql("edit"))
                        .edit
                    else
                        return error.UnknownTool;
                    for (tools.values[0..tools.count]) |existing| {
                        if (existing == tool) return error.DuplicateTool;
                    }
                    tools.values[tools.count] = tool;
                    tools.count += 1;
                    if (try self.consumeIf(']')) break;
                    try self.expectByte(',');
                }
            }
        } else return error.InvalidFieldState;
        try self.expectByte('}');
    }

    fn readSmallString(self: *Parser, destination: anytype) !void {
        var sink = SmallSink(@TypeOf(destination.*)){ .destination = destination };
        try self.readJsonString(&sink);
        if (!std.unicode.utf8ValidateSlice(destination.slice())) return error.InvalidUtf8;
    }

    fn readContentString(self: *Parser, field: *ContentField) !void {
        self.content_ordinal += 1;
        if (self.options.fault_content_acquire) return error.InjectedContentAcquireFailure;
        var path_buffer: [max_store_bytes + 128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/request-{d}-{d}.tmp", .{
            self.options.scratch_path,
            self.options.request_number,
            self.content_ordinal,
        });
        const writer = try std.Io.Dir.createFileAbsolute(self.options.io, path, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        var writer_open = true;
        errdefer if (writer_open) writer.close(self.options.io);
        errdefer std.Io.Dir.deleteFileAbsolute(self.options.io, path) catch {
            self.options.cleanup_failed.* = true;
        };
        var transferred = false;
        var sealed: ?std.Io.File = null;
        errdefer if (!transferred) if (sealed) |file| file.close(self.options.io);
        var sink = ContentSink{
            .io = self.options.io,
            .file = writer,
            .inject_short_writes = self.options.fault_content_short_write,
        };
        try self.readJsonString(&sink);
        if (self.options.fault_content_write) return error.InjectedContentWriteFailure;
        try sink.finish();
        writer.sync(self.options.io) catch return error.ContentSyncFailed;
        if (self.options.fault_content_seal) return error.InjectedContentSealFailure;
        field.length = sink.length;
        field.digest = sink.hash.finalResult();
        if (field.length > max_sqlite_content_bytes) return error.ContentTooLarge;
        // Downgrade custody at seal: retain a read-only descriptor, close the
        // sole writer, then unlink the name before admission can observe it.
        sealed = try std.Io.Dir.openFileAbsolute(self.options.io, path, .{});
        writer.close(self.options.io);
        writer_open = false;
        // The errdefer owns the final retry and records retained cleanup only
        // if that retry also fails. A transient first unlink failure must not
        // leave a phantom scratch charge after the name is removed.
        try std.Io.Dir.deleteFileAbsolute(self.options.io, path);
        field.file = sealed.?;
        transferred = true;
    }

    fn readJsonString(self: *Parser, sink: anytype) !void {
        try self.expectByte('"');
        while (true) {
            const byte = try self.source.readByte();
            switch (byte) {
                '"' => break,
                0...0x1f => return error.InvalidJsonString,
                '\\' => {
                    const escaped = try self.source.readByte();
                    switch (escaped) {
                        '"', '\\', '/' => try sink.write(&.{escaped}),
                        'b' => try sink.write("\x08"),
                        'f' => try sink.write("\x0c"),
                        'n' => try sink.write("\n"),
                        'r' => try sink.write("\r"),
                        't' => try sink.write("\t"),
                        'u' => {
                            const first = try self.readHex16();
                            var codepoint: u21 = undefined;
                            if (first >= 0xd800 and first <= 0xdbff) {
                                if (try self.source.readByte() != '\\' or try self.source.readByte() != 'u') {
                                    return error.InvalidUnicodeEscape;
                                }
                                const second = try self.readHex16();
                                if (second < 0xdc00 or second > 0xdfff) return error.InvalidUnicodeEscape;
                                codepoint = @intCast(0x10000 +
                                    ((@as(u32, first) - 0xd800) << 10) +
                                    (@as(u32, second) - 0xdc00));
                            } else {
                                if (first >= 0xdc00 and first <= 0xdfff) return error.InvalidUnicodeEscape;
                                codepoint = @intCast(first);
                            }
                            var encoded: [4]u8 = undefined;
                            const length = try std.unicode.utf8Encode(codepoint, &encoded);
                            try sink.write(encoded[0..length]);
                        },
                        else => return error.InvalidJsonEscape,
                    }
                },
                else => try sink.write(&.{byte}),
            }
        }
        try sink.endString();
    }

    fn readHex16(self: *Parser) !u16 {
        var value: u16 = 0;
        for (0..4) |_| {
            const byte = try self.source.readByte();
            const digit: u16 = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => return error.InvalidUnicodeEscape,
            };
            value = value * 16 + digit;
        }
        return value;
    }

    fn expectKey(self: *Parser, key: []const u8) !void {
        try self.skipWhitespace();
        try self.expectByte('"');
        for (key) |expected| if (try self.source.readByte() != expected) return error.UnexpectedField;
        if (try self.source.readByte() != '"') return error.UnexpectedField;
        try self.expectByte(':');
    }

    fn expectByte(self: *Parser, expected: u8) !void {
        try self.skipWhitespace();
        if (try self.source.readByte() != expected) return error.InvalidJsonShape;
    }

    fn consumeIf(self: *Parser, expected: u8) !bool {
        try self.skipWhitespace();
        const byte = try self.source.readByte();
        if (byte == expected) return true;
        self.source.start -= 1;
        return false;
    }

    fn skipWhitespace(self: *Parser) !void {
        while (true) {
            const byte = try self.source.readByte();
            switch (byte) {
                ' ', '\t', '\r', '\n' => {},
                else => {
                    self.source.start -= 1;
                    return;
                },
            }
        }
    }
};

fn SmallSink(comptime T: type) type {
    return struct {
        destination: *T,

        fn write(self: *@This(), bytes: []const u8) !void {
            if (self.destination.len + bytes.len > self.destination.bytes.len) return error.ValueTooLong;
            @memcpy(self.destination.bytes[self.destination.len..][0..bytes.len], bytes);
            self.destination.len += bytes.len;
        }

        fn endString(_: *@This()) !void {}
    };
}

const ContentSink = struct {
    io: std.Io,
    file: std.Io.File,
    buffer: [content_window_bytes]u8 = undefined,
    used: usize = 0,
    length: u64 = 0,
    hash: std.crypto.hash.sha2.Sha256 = contentHasher(),
    utf8: Utf8State = .{},
    inject_short_writes: bool = false,
    partial_returns: usize = 0,

    fn write(self: *ContentSink, bytes: []const u8) !void {
        try self.utf8.feed(bytes);
        self.hash.update(bytes);
        self.length = std.math.add(u64, self.length, bytes.len) catch return error.ContentTooLarge;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = @min(self.buffer.len - self.used, bytes.len - offset);
            @memcpy(self.buffer[self.used..][0..count], bytes[offset..][0..count]);
            self.used += count;
            offset += count;
            if (self.used == self.buffer.len) try self.flush();
        }
    }

    fn endString(self: *ContentSink) !void {
        if (!self.utf8.complete()) return error.InvalidUtf8;
    }

    fn finish(self: *ContentSink) !void {
        try self.flush();
    }

    fn flush(self: *ContentSink) !void {
        if (self.used == 0) return;
        var offset: usize = 0;
        while (offset < self.used) {
            const remaining = self.buffer[offset..self.used];
            const count = try self.writeSome(remaining);
            if (count == 0) return error.ContentWriteMadeNoProgress;
            if (count < remaining.len) self.partial_returns += 1;
            offset += count;
        }
        self.used = 0;
    }

    fn writeSome(self: *ContentSink, bytes: []const u8) !usize {
        // This controlled writer returns a genuine partial count to flush;
        // writeStreamingAll only certifies the prefix that the injected lower
        // layer accepted.
        const count = if (self.inject_short_writes) @min(bytes.len, 7) else bytes.len;
        try self.file.writeStreamingAll(self.io, bytes[0..count]);
        return count;
    }
};

const Utf8State = struct {
    bytes: [4]u8 = undefined,
    used: u3 = 0,
    expected: u3 = 0,

    fn feed(self: *Utf8State, input: []const u8) !void {
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

    fn complete(self: *const Utf8State) bool {
        return self.used == 0;
    }
};

pub fn maximumJsonStringBytes(input_bytes: usize) usize {
    return 2 + 6 * input_bytes;
}

// The Session inspection is the largest issue-173 response. This bound uses
// every literal emitted by renderSessionObservation, maximum decimal u64
// widths, both tools, a present schema, and worst-case JSON escaping.
pub const max_response_bytes =
    "{\"version\":\"1\",\"type\":\"session_observation\",\"session\":{\"reference\":".len +
    maximumJsonStringBytes(max_session_bytes) +
    ",\"workspace\":".len + maximumJsonStringBytes(max_workspace_bytes) +
    ",\"model\":".len + maximumJsonStringBytes(max_model_bytes) +
    ",\"revision\":\"".len + 20 +
    "\",\"tools\":[\"bash\",\"edit\"],\"permission_mode\":".len + maximumJsonStringBytes(16) +
    ",\"instructions\":{\"bytes\":\"".len + 20 +
    "\",\"sha256\":\"".len + 64 +
    "\"},\"output_schema\":{\"bytes\":\"".len + 20 +
    "\",\"sha256\":\"".len + 64 +
    "\"}},\"pending_messages\":\"".len + 20 +
    "\",\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"18446744073709551615\",\"scratch_used_bytes\":\"18446744073709551615\",\"unavailable\":[\"retry_and_restart_resolution\"]}}".len;

pub const ResponseBuffer = struct {
    bytes: [max_response_bytes]u8 = undefined,
    len: usize = 0,

    pub fn append(self: *ResponseBuffer, value: []const u8) !void {
        if (self.len + value.len > self.bytes.len) return error.ResponseTooLarge;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
    }

    pub fn appendFmt(self: *ResponseBuffer, comptime format: []const u8, args: anytype) !void {
        const value = try std.fmt.bufPrint(self.bytes[self.len..], format, args);
        self.len += value.len;
    }

    pub fn appendJsonString(self: *ResponseBuffer, value: []const u8) !void {
        try self.append("\"");
        for (value) |byte| switch (byte) {
            '"' => try self.append("\\\""),
            '\\' => try self.append("\\\\"),
            '\x08' => try self.append("\\b"),
            '\x0c' => try self.append("\\f"),
            '\n' => try self.append("\\n"),
            '\r' => try self.append("\\r"),
            '\t' => try self.append("\\t"),
            0...7, 11, 14...0x1f => {
                const alphabet = "0123456789abcdef";
                try self.append(&.{ '\\', 'u', '0', '0', alphabet[byte >> 4], alphabet[byte & 0x0f] });
            },
            else => try self.append(&.{byte}),
        };
        try self.append("\"");
    }

    pub fn slice(self: *const ResponseBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

test "semantic digest distinguishes omission, null, and value" {
    var omitted = ConfigureCommand{};
    try omitted.session.set("s");
    var null_schema = omitted;
    null_schema.configuration.output_schema.state = .explicit_null;
    var value_schema = omitted;
    value_schema.configuration.output_schema.state = .value;
    value_schema.configuration.output_schema.digest = [_]u8{1} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &omitted.semanticDigest(), &null_schema.semanticDigest()));
    try std.testing.expect(!std.mem.eql(u8, &null_schema.semanticDigest(), &value_schema.semanticDigest()));
}

test "captured content cleanup closes sealed custody" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "content", .{ .read = true });
    var content: ContentField = .{ .state = .value, .file = file };
    try removeContent(&content, std.testing.io);
    try std.testing.expect(!content.hasFile());
}

test "content sink completes after controlled short returns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "short-writes", .{ .read = true });
    defer file.close(std.testing.io);
    const expected = "short-return-data" ** 300;
    var sink = ContentSink{
        .io = std.testing.io,
        .file = file,
        .inject_short_writes = true,
    };
    try sink.write(expected);
    try sink.endString();
    try sink.finish();
    try std.testing.expect(sink.partial_returns > 0);
    var actual: [expected.len]u8 = undefined;
    try std.testing.expectEqual(expected.len, try file.readPositionalAll(std.testing.io, &actual, 0));
    try std.testing.expectEqualSlices(u8, expected, &actual);
}
