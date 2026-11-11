//! The Host's request ingress: it captures each content string into a sealed
//! scratch file while protocol.zig's Parser reads the rest, then hands the
//! parsed Request its content's custody. Files, scratch charges and polling
//! live here; the grammar they serve is protocol.zig's.
const std = @import("std");
const protocol = @import("protocol.zig");
const named_scratch = @import("named_scratch.zig");
const ScratchBudget = @import("ScratchBudget.zig");

pub const Custody = @import("content_custody.zig");
pub const ContentField = Custody.ContentField;
pub const Configuration = Custody.Configuration;
pub const ConfigureCommand = Custody.ConfigureCommand;
pub const MessageCommand = Custody.MessageCommand;
const requests = protocol.Requests(Custody);
pub const Request = requests.Request;
const Parser = requests.Parser;

/// Injected failures of a request's content capture.
pub const ContentFaults = struct {
    acquire: bool = false,
    write: bool = false,
    seal: bool = false,
};

pub const ParseOptions = struct {
    io: std.Io,
    content_length: u64,
    scratch_path: []const u8,
    request_number: u64,
    content_faults: ContentFaults = .{},
    retained_scratch: *?named_scratch.Owner,
    scratch_budget: ?ScratchBudget = null,
    expected_kind: ?protocol.Kind = null,
};

/// Resumable ingress owns captures until complete framing and validation.
/// Parser remains the sole wire grammar: only its content-read instruction
/// can open a capture. Replays see metadata, never descriptors or charges.
pub const Ingress = struct {
    allocator: std.mem.Allocator,
    options: ParseOptions,
    metadata: std.ArrayList(u8) = .empty,
    received: u64 = 0,
    lexical: enum { plain, string, escape } = .plain,
    /// Where the next byte goes: the metadata, the opening quote of a
    /// content string, or `capture`.
    content_state: enum { metadata, awaiting_quote, capturing } = .metadata,
    /// Live while `content_state` is `.capturing`.
    capture: ContentCapture = undefined,
    decoder: protocol.StringDecoder = .{},
    contents: [protocol.max_request_contents]ContentField = @splat(.{}),
    content_count: usize = 0,
    complete: bool = false,
    /// The one home of the parsed Request: preview and finish parse into it.
    /// After finish, the Ingress's owner borrows it until it releases the Ingress.
    request: Request = undefined,

    // Initial Message combines configuration scalars and sender identity.
    // Allow worst-case escaping of both, of a full `tools` list, and of 128
    // short grammar tokens (keys, states and literals, each at most 32
    // bytes), plus punctuation and one preserved whitespace separator at
    // every lexical boundary.
    const metadata_limit = 2 * (6 * (protocol.max_store_bytes + protocol.max_key_bytes + protocol.max_session_bytes +
        protocol.max_workspace_bytes + protocol.max_provider_bytes + protocol.max_model_bytes + 16 + 2 * protocol.max_tool_list_name_bytes + 128 * 32) + (128 + 2 * protocol.max_tools) * 8);

    /// Builds the Ingress in its home. `request` stays unwritten.
    pub fn init(self: *Ingress, allocator: std.mem.Allocator, options: ParseOptions) void {
        self.* = .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Ingress) void {
        if (self.content_state == .capturing) self.capture.deinit();
        self.content_state = .metadata;
        for (&self.contents) |*field| field.removeTemporaryContent(self.options.io) catch unreachable;
        self.metadata.deinit(self.allocator);
        self.metadata = .empty;
    }

    pub fn feed(self: *Ingress, bytes: []const u8) !void {
        if (bytes.len > self.options.content_length - self.received) return error.TrailingInput;
        for (bytes) |byte| {
            if (self.complete) return error.TrailingInput;
            self.received += 1;
            switch (self.content_state) {
                .metadata => {},
                .awaiting_quote => {
                    switch (byte) {
                        ' ', '\t', '\r', '\n' => continue,
                        '"' => {
                            try self.capture.init(self.options, @intCast(self.content_count + 1));
                            self.content_state = .capturing;
                            self.decoder = .{};
                            continue;
                        },
                        // A plain nullable spec value needs no capture. Keep
                        // its literal in metadata for the protocol to validate.
                        'n' => self.content_state = .metadata,
                        else => return error.InvalidJsonShape,
                    }
                },
                .capturing => {
                    if (try self.decoder.feed(byte, &self.capture.sink)) {
                        self.contents[self.content_count] = try self.capture.seal();
                        self.content_count += 1;
                        self.capture.deinit();
                        self.content_state = .metadata;
                        try self.append('"');
                        try self.append('"');
                        try self.preview();
                    }
                    continue;
                },
            }
            var boundary = false;
            switch (self.lexical) {
                .plain => switch (byte) {
                    ' ', '\t', '\r', '\n' => {
                        // Do not join tokens (t rue) or erase trailing input.
                        if (self.metadata.items.len == 0 or self.metadata.items[self.metadata.items.len - 1] != ' ')
                            try self.append(' ');
                        continue;
                    },
                    '"' => self.lexical = .string,
                    '{', '}', '[', ']', ',', ':' => boundary = true,
                    else => {},
                },
                .string => switch (byte) {
                    '"' => {
                        self.lexical = .plain;
                        boundary = true;
                    },
                    '\\' => self.lexical = .escape,
                    else => {},
                },
                .escape => self.lexical = .string,
            }
            try self.append(byte);
            if (boundary) try self.preview();
        }
    }

    fn append(self: *Ingress, byte: u8) !void {
        if (self.metadata.items.len == metadata_limit) return error.ValueTooLong;
        try self.metadata.append(self.allocator, byte);
    }

    fn parse(self: *Ingress) !void {
        var source: protocol.MetadataSource = .{ .input = self.metadata.items };
        var parser = Parser{
            .source = &source,
            .expected_kind = self.options.expected_kind,
            .captured = self.contents[0..self.content_count],
        };
        try parser.parse(&self.request);
        std.debug.assert(parser.content_ordinal == self.content_count);
    }

    fn preview(self: *Ingress) !void {
        self.parse() catch |err| switch (err) {
            error.NeedInput => return,
            error.NeedContent => {
                std.debug.assert(self.content_count < self.contents.len);
                self.content_state = .awaiting_quote;
                return;
            },
            else => return err,
        };
        self.complete = true;
        if (self.received != self.options.content_length) return error.TrailingInput;
    }

    /// Parses the complete body into `request`, moves the captured content
    /// into it, and returns it.
    pub fn finish(self: *Ingress) !*Request {
        if (self.received != self.options.content_length) return error.UnexpectedEndOfBody;
        self.parse() catch |err| switch (err) {
            error.NeedInput, error.NeedContent => return error.UnexpectedEndOfBody,
            else => return err,
        };
        const request = &self.request;
        // All fallible validation precedes this non-failing custody transfer.
        // Each value takes the capture its string arrived in, whatever the
        // members' order.
        var moved: usize = 0;
        switch (request.*) {
            .configure => |*command| {
                for ([_]*ContentField{ &command.configuration.instructions, &command.configuration.output_schema }) |field| {
                    if (field.state != .value) continue;
                    self.take(field);
                    moved += 1;
                }
            },
            .message => |*command| {
                if (command.configuration) |*configuration| {
                    for ([_]*ContentField{ &configuration.instructions, &configuration.output_schema }) |field| {
                        if (field.state != .value) continue;
                        self.take(field);
                        moved += 1;
                    }
                }
                if (command.text.state == .value) {
                    self.take(&command.text);
                    moved += 1;
                }
            },
            else => {},
        }
        std.debug.assert(moved == self.content_count);
        self.metadata.deinit(self.allocator);
        self.metadata = .empty;
        return request;
    }

    fn take(self: *Ingress, field: *ContentField) void {
        const index = field.capture - 1;
        field.* = self.contents[index];
        self.contents[index] = .{};
    }
};

// One absolute budget; progress cannot extend an absolute exchange.
pub fn pollExchange(io: std.Io, fd: std.posix.fd_t, events: i16, deadline: ?i128) !void {
    const end = deadline orelse {
        var descriptors = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        if (try std.posix.poll(&descriptors, 60_000) == 0) return error.TransferInactive;
        return;
    };
    while (true) {
        const remaining = end - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (remaining <= 0) return error.ExchangeDeadlineExceeded;
        const milliseconds: c_int = @intCast(@min(60_000, @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        var descriptors = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        // Recompute after EINTR rather than retrying the original timeout.
        const result = std.c.poll(&descriptors, descriptors.len, milliseconds);
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result > 0) {
                if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= end) return error.ExchangeDeadlineExceeded;
                return;
            },
            .INTR => {},
            else => return error.PollFailed,
        }
    }
}

const ContentCapture = struct {
    options: ParseOptions,
    path: [protocol.max_store_bytes + "/scratch/request-".len + 20 + 1 + 3 + ".tmp".len]u8 = undefined,
    path_len: usize,
    sink: ContentSink,
    /// The read-only reopen. Seal closes the writer as it sets this, so this
    /// is the only open descriptor once set; while null, `sink.file` is.
    sealed: ?std.Io.File = null,
    transferred: bool = false,

    /// Opens the scratch file and builds the capture in place. On error
    /// nothing is open and the capture is not live.
    fn init(self: *ContentCapture, options: ParseOptions, ordinal: u8) !void {
        if (options.content_faults.acquire) return error.InjectedContentAcquireFailure;
        var name_buffer: [96]u8 = undefined;
        const name = try named_scratch.NumericName.request.format(&name_buffer, options.request_number, ordinal);
        const path = try std.fmt.bufPrint(&self.path, "{s}/{s}", .{ options.scratch_path, name });
        const writer = try std.Io.Dir.createFileAbsolute(options.io, path, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        self.options = options;
        self.path_len = path.len;
        self.sink = .{ .io = options.io, .file = writer, .scratch_budget = options.scratch_budget };
        self.sealed = null;
        self.transferred = false;
    }

    fn seal(self: *ContentCapture) !ContentField {
        if (self.options.content_faults.write) return error.InjectedContentWriteFailure;
        try self.sink.finish();
        if (self.options.content_faults.seal) return error.InjectedContentSealFailure;
        self.sealed = try std.Io.Dir.openFileAbsolute(self.options.io, self.path[0..self.path_len], .{});
        self.sink.file.close(self.options.io);
        try std.Io.Dir.deleteFileAbsolute(self.options.io, self.path[0..self.path_len]);
        self.transferred = true;
        return .{
            .state = .value,
            .file = self.sealed.?,
            .scratch_budget = self.sink.scratch_budget,
            .charged = self.sink.charged,
            .length = self.sink.length,
            .digest = self.sink.hash.finalResult(),
        };
    }

    fn deinit(self: *ContentCapture) void {
        if (self.transferred) return;
        const removed = if (std.Io.Dir.deleteFileAbsolute(self.options.io, self.path[0..self.path_len])) |_| true else |err| switch (err) {
            error.FileNotFound => true,
            else => false,
        };
        if (removed) {
            (self.sealed orelse self.sink.file).close(self.options.io);
            if (self.sink.scratch_budget) |budget| budget.release(self.sink.charged);
        } else {
            const retained = self.options.retained_scratch;
            std.debug.assert(retained.* == null);
            retained.* = named_scratch.Owner.init(
                self.options.io,
                self.sealed orelse self.sink.file,
                null,
                std.fs.path.basename(self.path[0..self.path_len]),
                self.sink.scratch_budget,
                self.sink.charged,
                .native,
            );
        }
        self.transferred = true;
    }
};

const ContentSink = struct {
    scratch_budget: ?ScratchBudget = null,
    charged: u64 = 0,
    io: std.Io,
    file: std.Io.File,
    buffer: [protocol.content_window_bytes]u8 = undefined,
    used: usize = 0,
    length: u64 = 0,
    hash: std.crypto.hash.sha2.Sha256 = protocol.contentHasher(),
    utf8: protocol.Utf8State = .{},

    pub fn write(self: *ContentSink, bytes: []const u8) !void {
        const next_length = std.math.add(u64, self.length, bytes.len) catch return error.ContentTooLarge;
        if (next_length > protocol.max_sqlite_content_bytes) return error.ContentTooLarge;
        try self.utf8.feed(bytes);
        self.hash.update(bytes);
        self.length = next_length;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = @min(self.buffer.len - self.used, bytes.len - offset);
            @memcpy(self.buffer[self.used..][0..count], bytes[offset..][0..count]);
            self.used += count;
            offset += count;
            if (self.used == self.buffer.len) try self.flush();
        }
    }

    pub fn endString(self: *ContentSink) !void {
        if (!self.utf8.complete()) return error.InvalidUtf8;
    }

    pub fn finish(self: *ContentSink) !void {
        try self.flush();
    }

    pub fn flush(self: *ContentSink) !void {
        if (self.used == 0) return;
        if (self.scratch_budget) |budget| {
            if (!budget.allocate(self.used)) return error.ScratchCapacityExhausted;
            // A failed streaming write may have written a prefix. Retain the
            // complete submitted increment until this file is safely removed.
            self.charged += self.used;
        }
        try self.file.writeStreamingAll(self.io, self.buffer[0..self.used]);
        self.used = 0;
    }
};

/// Captures one JSON string the way Ingress.feed does, into `field`.
fn captureForTest(field: *ContentField, options: ParseOptions, ordinal: u8, json: []const u8) !void {
    std.debug.assert(json[0] == '"');
    var capture: ContentCapture = undefined;
    try capture.init(options, ordinal);
    defer capture.deinit();
    var decoder: protocol.StringDecoder = .{};
    for (json[1..]) |byte| {
        if (try decoder.feed(byte, &capture.sink)) {
            field.* = try capture.seal();
            return;
        }
    }
    return error.UnexpectedEndOfBody;
}

test "captured content cleanup closes sealed custody" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "content", .{ .read = true });
    var content: ContentField = .{ .state = .value, .file = file };
    try content.removeTemporaryContent(std.testing.io);
    try std.testing.expect(!content.hasFile());
}

test "creating Message content sealing peaks at five descriptors with its socket" {
    const Probe = struct {
        var live_files: usize = 0;
        var maximum_live_files: usize = 0;
        var directory_opens: usize = 0;

        fn createFile(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            path: []const u8,
            options: std.Io.Dir.CreateFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirCreateFile(userdata, dir, path, options);
            live_files += 1;
            maximum_live_files = @max(maximum_live_files, live_files);
            return file;
        }

        fn openFile(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            path: []const u8,
            options: std.Io.Dir.OpenFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
            live_files += 1;
            maximum_live_files = @max(maximum_live_files, live_files);
            return file;
        }

        fn closeFiles(userdata: ?*anyopaque, files: []const std.Io.File) void {
            std.debug.assert(live_files >= files.len);
            live_files -= files.len;
            std.testing.io.vtable.fileClose(userdata, files);
        }

        fn openDir(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            path: []const u8,
            options: std.Io.Dir.OpenOptions,
        ) std.Io.Dir.OpenError!std.Io.Dir {
            directory_opens += 1;
            return std.testing.io.vtable.dirOpenDir(userdata, dir, path, options);
        }
    };
    Probe.live_files = 0;
    Probe.maximum_live_files = 0;
    Probe.directory_opens = 0;

    var vtable = std.testing.io.vtable.*;
    vtable.dirCreateFile = Probe.createFile;
    vtable.dirOpenFile = Probe.openFile;
    vtable.fileClose = Probe.closeFiles;
    vtable.dirOpenDir = Probe.openDir;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var retained: ?named_scratch.Owner = null;
    const options: ParseOptions = .{
        .io = io,
        .content_length = 22,
        .scratch_path = root[0..root_len],
        .request_number = 1,
        .retained_scratch = &retained,
    };
    var instructions = ContentField{};
    errdefer instructions.removeTemporaryContent(io) catch unreachable;
    var output_schema = ContentField{};
    errdefer output_schema.removeTemporaryContent(io) catch unreachable;
    try captureForTest(&instructions, options, 1, "\"instructions\"");
    try captureForTest(&output_schema, options, 2, "\"schema\"");
    var text = ContentField{};
    errdefer text.removeTemporaryContent(io) catch unreachable;
    try captureForTest(&text, options, 3, "\"text\"");
    try std.testing.expectEqual(@as(usize, 5), 1 + Probe.maximum_live_files);
    try std.testing.expectEqual(@import("descriptor_capacity.zig").ordinary_exchange_descriptors, 1 + Probe.maximum_live_files);
    try std.testing.expectEqual(@as(usize, 0), Probe.directory_opens);
    try text.removeTemporaryContent(io);
    try output_schema.removeTemporaryContent(io);
    try instructions.removeTemporaryContent(io);
    try std.testing.expectEqual(@as(usize, 0), Probe.live_files);
}

test "content sink enforces the decoded consumer boundary before retention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "content", .{});
    defer file.close(std.testing.io);

    var escaped = ContentSink{ .io = std.testing.io, .file = file };
    escaped.length = protocol.max_sqlite_content_bytes - 1;
    try escaped.write("\n");
    try std.testing.expectEqual(protocol.max_sqlite_content_bytes, escaped.length);
    try std.testing.expectError(error.ContentTooLarge, escaped.write("x"));
    try escaped.finish();
    try std.testing.expectEqual(@as(u64, 1), try file.length(std.testing.io));

    var multibyte = ContentSink{ .io = std.testing.io, .file = file };
    multibyte.length = protocol.max_sqlite_content_bytes - 3;
    try multibyte.write("€");
    try std.testing.expectEqual(protocol.max_sqlite_content_bytes, multibyte.length);
    try std.testing.expectError(error.ContentTooLarge, multibyte.write("x"));
}

test "ingress charges decoded growth and transfers file charge through cleanup" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root);
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    for ([_][]const u8{ "\"abc\"", "\"\\u0061\\u0062\\u0063\"" }, 0..) |json, ordinal| {
        var field = ContentField{};
        try captureForTest(&field, .{
            .io = io,
            .content_length = 999999,
            .scratch_path = root[0..n],
            .request_number = ordinal,
            .retained_scratch = &retained,
            .scratch_budget = .{ .used = &used, .limit = 3 },
        }, 1, json);
        try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
        try std.testing.expectEqual(@as(u64, 3), field.length);
        try field.removeTemporaryContent(io);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
    const file = try tmp.dir.createFile(io, "bounded", .{});
    defer file.close(io);
    var sink = ContentSink{ .io = io, .file = file, .scratch_budget = .{ .used = &used, .limit = 3 } };
    try sink.write("abcd");
    try std.testing.expectError(error.ScratchCapacityExhausted, sink.finish());
    try std.testing.expectEqual(@as(u64, 0), try file.length(io));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "failed ingress unlink retains an actionable owner and only the affected charge" {
    const FailDelete = struct {
        fn delete(_: ?*anyopaque, _: std.Io.Dir, _: []const u8) std.Io.Dir.DeleteFileError!void {
            return error.AccessDenied;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root);
    var used = std.atomic.Value(u64).init(0);
    var vtable = io.vtable.*;
    vtable.dirDeleteFile = FailDelete.delete;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var retained: ?named_scratch.Owner = null;
    const json = "\"abc\"";
    const options: ParseOptions = .{
        .io = failing_io,
        .content_length = json.len,
        .scratch_path = root[0..n],
        .request_number = 1,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = 8 },
    };
    const good_file = try tmp.dir.createFile(io, "good", .{});
    try good_file.writeStreamingAll(io, "ok");
    try tmp.dir.deleteFile(io, "good");
    const budget = ScratchBudget{ .used = &used, .limit = 8 };
    try std.testing.expect(budget.charge(2));
    var good_field = ContentField{ .file = good_file, .scratch_budget = budget, .charged = 2 };
    var field = ContentField{};
    try std.testing.expectError(error.AccessDenied, captureForTest(&field, options, 1, json));
    try std.testing.expect(!field.hasFile());
    try std.testing.expectEqual(@as(u64, 5), used.load(.acquire));
    try good_field.removeTemporaryContent(io);
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), (try tmp.dir.statFile(io, "request-1-1.tmp", .{})).size);
    try std.testing.expect(retained != null);
    try std.testing.expectError(error.AccessDenied, retained.?.reclaim(root[0..n]));
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    vtable.dirDeleteFile = io.vtable.dirDeleteFile;
    try std.testing.expectEqual(named_scratch.Reclamation.removed, try retained.?.reclaim(root[0..n]));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "request-1-1.tmp", .{}));
}

test "ingress unknown write failure keeps submitted charge until close" {
    const FailWrite = struct {
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) return .{ .file_write_streaming = error.NoSpaceLeft };
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "failed", .{});
    var used = std.atomic.Value(u64).init(0);
    var vtable = io.vtable.*;
    vtable.operate = FailWrite.operate;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var sink = ContentSink{ .io = failing_io, .file = file, .scratch_budget = .{ .used = &used, .limit = 3 } };
    try sink.write("abc");
    try std.testing.expectError(error.NoSpaceLeft, sink.finish());
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try tmp.dir.deleteFile(io, "failed");
    var field = ContentField{ .file = file, .scratch_budget = sink.scratch_budget, .charged = sink.charged };
    try field.removeTemporaryContent(io);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "incremental ingress streams fragmented content and transfers charged custody only at complete framing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"p\\u0000é\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"";
    const encoded = @as([8193]u8, @splat('x')) ++ "\\n\\ud83d\\ude42\\u0000é\\\"\\\\";
    const expected = @as([8193]u8, @splat('x')) ++ "\n🙂\x00é\"\\";
    const suffix = "\"}}";
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    var ingress: Ingress = undefined;
    ingress.init(std.testing.allocator, .{
        .io = io,
        .content_length = prefix.len + encoded.len + suffix.len,
        .scratch_path = root[0..root_len],
        .request_number = 42,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = expected.len },
        .expected_kind = .message,
    });
    defer ingress.deinit();
    for (prefix ++ encoded) |byte| try ingress.feed(&.{byte});
    try std.testing.expectEqual(@as(u64, 8192), used.load(.acquire));
    try std.testing.expectError(error.UnexpectedEndOfBody, ingress.finish());
    for (suffix) |byte| try ingress.feed(&.{byte});
    const request = try ingress.finish();
    defer request.removeTemporaryContent(io) catch unreachable;
    // Disposing the exchange's parser cannot refund or close admitted ingress.
    ingress.deinit();
    try std.testing.expectEqual(@as(u64, expected.len), used.load(.acquire));
    try std.testing.expectEqualStrings("p\x00é", request.message.session.slice());
    var actual: [expected.len]u8 = undefined;
    try std.testing.expectEqual(actual.len, try request.message.text.file.?.readPositionalAll(io, &actual, 0));
    try std.testing.expectEqualStrings(expected, &actual);
    var hash = protocol.contentHasher();
    hash.update(expected);
    try std.testing.expectEqualSlices(u8, &hash.finalResult(), &request.message.text.digest);
    try request.removeTemporaryContent(io);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expect(retained == null);
}

test "initial Message ingress streams the plain spec and transfers all three content custodies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const large = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    for ([_]bool{ false, true }) |text_first| {
        for ([_]bool{ false, true }) |null_schema| {
            var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer body.deinit();
            try body.writer.writeAll("{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"\",\"sender\":null,\"sender_handle\":null,");
            if (text_first) try body.writer.writeAll("\"text\":{\"state\":\"value\",\"value\":\"task\"},");
            try body.writer.writeAll("\"configuration\":{\"model\":\"custom\",\"effort\":null,\"compactAt\":1000,\"tools\":[],\"permissionMode\":\"ask\",\"instructions\":");
            try std.json.Stringify.value(large, .{}, &body.writer);
            try body.writer.writeAll(",\"outputSchema\":");
            if (null_schema) try body.writer.writeAll("null") else try std.json.Stringify.value(large, .{}, &body.writer);
            try body.writer.writeAll("}");
            if (!text_first) try body.writer.writeAll(",\"text\":{\"state\":\"value\",\"value\":\"task\"}");
            try body.writer.writeAll("}");
            var used = std.atomic.Value(u64).init(0);
            var retained: ?named_scratch.Owner = null;
            const ingress = try std.testing.allocator.create(Ingress);
            defer std.testing.allocator.destroy(ingress);
            ingress.init(std.testing.allocator, .{
                .io = io,
                .content_length = body.written().len,
                .scratch_path = root[0..root_len],
                .request_number = 43,
                .retained_scratch = &retained,
                .scratch_budget = .{ .used = &used, .limit = 2 * large.len + 4 },
                .expected_kind = .message,
            });
            defer ingress.deinit();
            try ingress.feed(body.written());
            try std.testing.expect(ingress.metadata.items.len < 4096);
            const request = try ingress.finish();
            defer request.removeTemporaryContent(io) catch unreachable;
            ingress.deinit();
            const configuration = &request.message.configuration.?;
            try std.testing.expect(configuration.instructions.hasFile());
            try std.testing.expectEqual(large.len, configuration.instructions.length);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(large), &configuration.instructions.digest);
            if (null_schema) try std.testing.expectEqual(.explicit_null, configuration.output_schema.state) else {
                try std.testing.expect(configuration.output_schema.hasFile());
                try std.testing.expectEqual(large.len, configuration.output_schema.length);
                try std.testing.expectEqualSlices(u8, &protocol.contentDigest(large), &configuration.output_schema.digest);
            }
            try std.testing.expect(request.message.text.hasFile());
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("task"), &request.message.text.digest);
            try std.testing.expectEqual(@as(u64, large.len * @as(usize, if (null_schema) 1 else 2) + 4), used.load(.acquire));
            try request.removeTemporaryContent(io);
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expect(retained == null);
        }
    }
}

test "only a creating Message carries require_model, and it binds the digest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const creating = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"\",\"sender\":null,\"sender_handle\":null,\"configuration\":{\"model\":\"model\",\"tools\":[],\"permissionMode\":\"default\",\"compactAt\":1000,\"effort\":null},\"text\":{\"state\":\"value\",\"value\":\"go\"}";
    const addressed = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"go\"}";
    const cases = [_]struct { bytes: []const u8, require_model: bool = false, failure: ?anyerror = null }{
        .{ .bytes = creating ++ "}" },
        .{ .bytes = creating ++ ",\"require_model\":false}" },
        .{ .bytes = creating ++ ",\"require_model\":true}", .require_model = true },
        .{ .bytes = creating ++ ",\"require_model\":1}", .failure = error.InvalidJsonShape },
        .{ .bytes = creating ++ ",\"required_model\":true}", .failure = error.UnexpectedField },
        .{ .bytes = addressed ++ "}" },
        .{ .bytes = addressed ++ ",\"require_model\":true}", .failure = error.InvalidMessage },
        .{ .bytes = addressed ++ ",\"require_model\":false}", .failure = error.InvalidMessage },
    };
    var digests: [cases.len][32]u8 = undefined;
    for (cases, 0..) |case, index| {
        var used = std.atomic.Value(u64).init(0);
        var retained: ?named_scratch.Owner = null;
        var ingress: Ingress = undefined;
        ingress.init(std.testing.allocator, .{
            .io = io,
            .content_length = case.bytes.len,
            .scratch_path = root[0..root_len],
            .request_number = 44,
            .retained_scratch = &retained,
            .scratch_budget = .{ .used = &used, .limit = 16 },
            .expected_kind = .message,
        });
        defer ingress.deinit();
        if (case.failure) |failure| {
            const result = if (ingress.feed(case.bytes)) |_| ingress.finish() else |err| err;
            try std.testing.expectError(failure, result);
            continue;
        }
        try ingress.feed(case.bytes);
        const request = try ingress.finish();
        defer request.removeTemporaryContent(io) catch unreachable;
        try std.testing.expectEqual(case.require_model, request.message.require_model);
        digests[index] = request.message.semanticDigest();
    }
    // An explicit false is the omitted condition; true is a different intent.
    try std.testing.expectEqualSlices(u8, &digests[0], &digests[1]);
    try std.testing.expect(!std.mem.eql(u8, &digests[0], &digests[2]));
    try std.testing.expect(!std.mem.eql(u8, &digests[0], &digests[5]));
}

test "incremental ingress preserves grammar and releases both captures after late failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const configure = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"configuration\":{\"instructions\":\"first\\n\",\"outputSchema\":\"{}\"}";
    const cases = [_]struct { bytes: []const u8, kind: protocol.Kind = .configure, failure: ?anyerror = null }{
        .{ .bytes = configure ++ "}" },
        .{ .bytes = configure ++ ",\"require_model\":true}" },
        .{ .bytes = configure ++ ",\"require_model\":t rue}", .failure = error.InvalidJsonShape },
        .{ .bytes = configure ++ "} ", .failure = error.TrailingInput },
        .{ .bytes = configure ++ ",\"extra\":true}", .failure = error.UnexpectedField },
        .{ .bytes = configure ++ "}", .kind = .session_stop, .failure = error.RouteKindMismatch },
        .{ .bytes = configure, .failure = error.UnexpectedEndOfBody },
    };
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    for (cases, 0..) |case, index| {
        // Every split of this small command must have the same grammar and
        // capture lifetime, including suspension between surrogate/quote bytes.
        for (0..case.bytes.len + 1) |split| {
            var ingress: Ingress = undefined;
            ingress.init(std.testing.allocator, .{
                .io = io,
                .content_length = case.bytes.len,
                .scratch_path = root[0..root_len],
                .request_number = index,
                .retained_scratch = &retained,
                .scratch_budget = .{ .used = &used, .limit = 8 },
                .expected_kind = case.kind,
                // A mismatched kind must fail before file acquisition.
                .content_faults = .{ .acquire = case.kind != .configure },
            });
            const result: anyerror!*Request = blk: {
                ingress.feed(case.bytes[0..split]) catch |err| break :blk err;
                ingress.feed(case.bytes[split..]) catch |err| break :blk err;
                break :blk ingress.finish();
            };
            if (case.failure) |failure| {
                try std.testing.expectError(failure, result);
            } else {
                const request = try result;
                try std.testing.expectEqual(@as(u64, 8), used.load(.acquire));
                try std.testing.expectEqual(index == 1, request.configure.require_model);
                const fields = [_]ContentField{ request.configure.configuration.instructions, request.configure.configuration.output_schema };
                const expected = [_][]const u8{ "first\n", "{}" };
                for (fields, expected) |field, bytes| {
                    var buffer: [8]u8 = undefined;
                    const count = try field.file.?.readPositionalAll(io, &buffer, 0);
                    try std.testing.expectEqualStrings(bytes, buffer[0..count]);
                }
                try request.removeTemporaryContent(io);
            }
            ingress.deinit();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expect(retained == null);
        }
    }
}

test "a request's members may come in any order, and its content lands in its own field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    // Content fields can arrive in either order, before or after the header.
    const reordered = "{\"configuration\":{\"outputSchema\":\"{}\",\"label\":\"Map\",\"tools\":[\"bash\"],\"instructions\":\"first\\n\"},\"require_model\":true,\"session\":\"peer\",\"key\":\"k\",\"store\":\"s\",\"kind\":\"configure\",\"version\":\"" ++ protocol.wire_version ++ "\"}";
    const ordered = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"configure\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"configuration\":{\"instructions\":\"first\\n\",\"tools\":[\"bash\"],\"outputSchema\":\"{}\",\"label\":\"Map\"},\"require_model\":true}";
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    var digests: [2][32]u8 = undefined;
    for ([_][]const u8{ ordered, reordered }, 0..) |bytes, index| {
        // Every split suspends capture at a different byte.
        for (0..bytes.len + 1) |split| {
            var ingress: Ingress = undefined;
            ingress.init(std.testing.allocator, .{
                .io = io,
                .content_length = bytes.len,
                .scratch_path = root[0..root_len],
                .request_number = index,
                .retained_scratch = &retained,
                .scratch_budget = .{ .used = &used, .limit = 8 },
                .expected_kind = .configure,
            });
            defer ingress.deinit();
            try ingress.feed(bytes[0..split]);
            try ingress.feed(bytes[split..]);
            const request = try ingress.finish();
            defer request.removeTemporaryContent(io) catch unreachable;
            const configuration = request.configure.configuration;
            try std.testing.expect(request.configure.require_model);
            try std.testing.expectEqualStrings("Map", configuration.label.value.slice());
            try std.testing.expectEqual(@as(u2, 1), configuration.tools.count);
            const fields = [_]ContentField{ configuration.instructions, configuration.output_schema };
            for (fields, [_][]const u8{ "first\n", "{}" }) |field, expected| {
                var buffer: [8]u8 = undefined;
                const count = try field.file.?.readPositionalAll(io, &buffer, 0);
                try std.testing.expectEqualStrings(expected, buffer[0..count]);
            }
            digests[index] = request.configure.semanticDigest();
        }
    }
    try std.testing.expectEqualSlices(u8, &digests[0], &digests[1]);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "an order-free request still names each member once, carries every required one, and holds content only where its kind allows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    const header = "\"version\":\"" ++ protocol.wire_version ++ "\",\"store\":\"s\"";
    const value = "{\"value\":\"x\",\"state\":\"value\"}";
    const configuration = "{\"model\":\"custom\",\"effort\":null,\"compactAt\":1000,\"tools\":[],\"permissionMode\":\"ask\"";
    const cases = [_]struct { json: []const u8, failure: ?anyerror = null }{
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\"," ++ header ++ "}" },
        .{ .json = "{\"archived\":false,\"session\":\"x\",\"key\":\"k\"," ++ header ++ ",\"kind\":\"session_archive\"}" },
        .{ .json = "{\"target\":{\"operation\":\"2\",\"turn\":\"1\",\"session\":\"x\"},\"key\":\"k\"," ++ header ++ ",\"kind\":\"model_interruption\"}" },
        .{ .json = "{\"text\":" ++ value ++ ",\"sender_handle\":null,\"sender\":{\"session\":\"k7m2qx\",\"store\":\"/s\"},\"session\":\"x\",\"key\":\"k\"," ++ header ++ ",\"kind\":\"message\"}" },
        .{ .json = "{\"attempt\":\"1\",\"operation\":\"2\",\"failed_response\":\"body\",\"session\":\"x\",\"kind\":\"inspect_session\"," ++ header ++ "}" },
        .{ .json = "{\"session\":\"x\",\"kind\":\"session_stop\"," ++ header ++ "}", .failure = error.MissingField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\"," ++ header ++ "}", .failure = error.MissingField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"store\":\"s\"}", .failure = error.MissingField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"kind\":\"session_stop\"," ++ header ++ "}", .failure = error.UnexpectedField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"session\":\"y\",\"kind\":\"session_stop\"," ++ header ++ "}", .failure = error.UnexpectedField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"extra\":[[[[[\"deep\"]]]]]," ++ header ++ "}", .failure = error.InvalidJsonShape },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"extra\":{\"a\":[1]}," ++ header ++ "}", .failure = error.UnexpectedField },
        .{ .json = "{\"session\":\"x\",\"key\":\"k\",\"kind\":\"session_stop\",\"extra\":{\"a\":[true,null]}," ++ header ++ "}", .failure = error.UnexpectedField },
        .{ .json = "{\"kind\":\"session_stop\",\"text\":" ++ value ++ ",\"session\":\"x\",\"key\":\"k\"," ++ header ++ "}", .failure = error.UnexpectedField },
        // A value with no state, or a state with no value.
        .{ .json = "{\"kind\":\"message\",\"text\":{\"value\":\"x\"},\"sender_handle\":null,\"sender\":null,\"session\":\"x\",\"key\":\"k\"," ++ header ++ "}", .failure = error.MissingField },
        .{ .json = "{\"kind\":\"message\",\"text\":{\"state\":\"value\"},\"sender_handle\":null,\"sender\":null,\"session\":\"x\",\"key\":\"k\"," ++ header ++ "}", .failure = error.InvalidFieldState },
        // Creating Messages carry the same content spec in either field order.
        .{ .json = "{\"kind\":\"message\",\"configuration\":" ++ configuration ++ ",\"outputSchema\":null,\"instructions\":\"x\"},\"text\":" ++ value ++ ",\"sender_handle\":null,\"sender\":null,\"session\":\"\",\"key\":\"k\"," ++ header ++ "}" },
        .{ .json = "{\"configuration\":" ++ configuration ++ ",\"outputSchema\":\"x\",\"instructions\":\"x\"},\"text\":" ++ value ++ ",\"sender_handle\":null,\"sender\":null,\"session\":\"\",\"key\":\"k\"," ++ header ++ ",\"kind\":\"message\"}" },
        .{ .json = "{\"configuration\":" ++ configuration ++ ",\"outputSchema\":\"x\",\"instructions\":\"x\"},\"text\":" ++ value ++ ",\"key\":\"k\",\"session\":\"x\"," ++ header ++ ",\"kind\":\"configure\"}", .failure = error.UnexpectedField },
        .{ .json = "{\"configuration\":" ++ configuration ++ "},\"text\":" ++ value ++ ",\"sender_handle\":null,\"sender\":null,\"session\":\"x\",\"key\":\"k\"," ++ header ++ ",\"kind\":\"message\"}", .failure = error.UnexpectedField },
    };
    var used = std.atomic.Value(u64).init(0);
    var retained: ?named_scratch.Owner = null;
    for (cases, 0..) |case, index| {
        var ingress: Ingress = undefined;
        ingress.init(std.testing.allocator, .{
            .io = io,
            .content_length = case.json.len,
            .scratch_path = root[0..root_len],
            .request_number = index,
            .retained_scratch = &retained,
            .scratch_budget = .{ .used = &used, .limit = 8 },
        });
        defer ingress.deinit();
        const result = if (ingress.feed(case.json)) |_| ingress.finish() else |err| err;
        if (case.failure) |failure| {
            try std.testing.expectError(failure, result);
            continue;
        }
        const request = try result;
        try request.removeTemporaryContent(io);
    }
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expect(retained == null);
}

test "observation needs no scratch at a full budget" {
    const json = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"observe_command\",\"store\":\"store\",\"key\":\"key\"}";
    var used = std.atomic.Value(u64).init(3);
    var retained: ?named_scratch.Owner = null;
    var ingress: Ingress = undefined;
    ingress.init(std.testing.allocator, .{
        .io = std.testing.io,
        .content_length = json.len,
        .scratch_path = "unused",
        .request_number = 0,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = 3 },
    });
    defer ingress.deinit();
    try ingress.feed(json);
    const request = try ingress.finish();
    try std.testing.expect(request.* == .observe_command);
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try std.testing.expect(retained == null);
}
