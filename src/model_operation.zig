const std = @import("std");
const host_store = @import("host_store.zig");
const bash_tool = @import("bash_tool.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");

pub const request_header_size = 16;
pub const entry_header_size = 40;
pub const request_window_size = 4096;
pub const version: u16 = 1;

const request_magic = "ONEREQ\x00\x00";

pub const Descriptor = struct {
    request_ref: u64,
    digest: u64,
    length: u64,
    first_entry: u32,
    entry_count: u32,
};

pub const Provider = struct {
    context: *anyopaque,
    dispatch: *const fn (
        *anyopaque,
        RequestReader,
        ResponseWriter,
    ) anyerror!void,
};

pub const RequestReader = struct {
    context: *anyopaque,
    length_fn: *const fn (*anyopaque) u64,
    read_fn: *const fn (*anyopaque, u64, []u8) anyerror![]const u8,

    pub fn length(self: RequestReader) u64 {
        return self.length_fn(self.context);
    }

    pub fn readWindow(self: RequestReader, offset: u64, out: []u8) ![]const u8 {
        return self.read_fn(self.context, offset, out);
    }
};

pub const ResponseWriter = struct {
    context: *anyopaque,
    append_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    finish_fn: *const fn (*anyopaque) anyerror!void,

    pub fn append(self: ResponseWriter, bytes: []const u8) !void {
        try self.append_fn(self.context, bytes);
    }

    pub fn finish(self: ResponseWriter) !void {
        try self.finish_fn(self.context);
    }
};

/// Owns the host-side resources behind the deliberately narrow provider
/// capabilities. Providers can read one immutable request and append one
/// predetermined response; they receive no Session or owner authority.
pub const ProviderIo = struct {
    request: session_store.BlobReader,
    response: session_store.BlobWriter,

    pub fn open(
        session: *session_store.Session,
        token: session_store.OwnerToken,
        request_ref: u64,
        response_ref: u64,
    ) !ProviderIo {
        var request = try session.openBlob(token, request_ref);
        errdefer request.close();
        const response = try session.beginBlob(token, response_ref);
        return .{ .request = request, .response = response };
    }

    pub fn close(self: *ProviderIo) void {
        self.request.close();
        self.response.abort();
    }

    pub fn requestCapability(self: *ProviderIo) RequestReader {
        return .{ .context = self, .length_fn = requestLength, .read_fn = requestRead };
    }

    pub fn responseCapability(self: *ProviderIo) ResponseWriter {
        return .{ .context = self, .append_fn = responseAppend, .finish_fn = responseFinish };
    }

    pub fn ensureResponsePublished(self: *const ProviderIo) !void {
        if (self.response.open) return error.ProviderResponseIncomplete;
    }

    pub fn publishProviderFailure(
        self: *ProviderIo,
        session: *session_store.Session,
        token: session_store.OwnerToken,
        response_ref: u64,
    ) !u64 {
        self.response.abort();
        const failure_ref = (@as(u64, 1) << 56) | response_ref;
        var buffer: [model_protocol.header_size]u8 = undefined;
        const encoded = try model_protocol.encodeText(&buffer, .provider_error, "");
        try session.storeBlob(token, failure_ref, encoded);
        return failure_ref;
    }

    fn requestLength(context: *anyopaque) u64 {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        return self.request.length();
    }

    fn requestRead(context: *anyopaque, offset: u64, out: []u8) anyerror![]const u8 {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        return self.request.readWindow(offset, out);
    }

    fn responseAppend(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        try self.response.append(bytes);
    }

    fn responseFinish(context: *anyopaque) anyerror!void {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        try self.response.finish();
    }
};

pub fn buildRequest(
    session: *session_store.Session,
    token: session_store.OwnerToken,
    request_ref: u64,
    first_entry: u32,
    entry_count: u32,
) !Descriptor {
    if (request_ref == 0 or first_entry == 0 or entry_count == 0) {
        return error.InvalidContextSelection;
    }
    const last = @as(u64, first_entry) + entry_count - 1;
    if (last > session.entry_count) return error.InvalidContextSelection;

    var writer = try session.beginBlob(token, request_ref);
    errdefer writer.abort();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var request_header: [request_header_size]u8 = @splat(0);
    @memcpy(request_header[0..request_magic.len], request_magic);
    write(u16, &request_header, 8, version);
    write(u16, &request_header, 10, request_header_size);
    write(u32, &request_header, 12, entry_count);
    try appendHashed(&writer, &hasher, &total, &request_header);

    var sequence: u64 = first_entry;
    while (sequence <= last) : (sequence += 1) {
        const entry = try session.readEntry(sequence);
        var content = try session.openBlob(token, entry.content_ref);
        defer content.close();
        var entry_header: [entry_header_size]u8 = @splat(0);
        entry_header[0] = @intFromEnum(entry.kind);
        write(u64, &entry_header, 8, entry.entry_id);
        write(u64, &entry_header, 16, entry.parent_id);
        write(u64, &entry_header, 24, entry.content_ref);
        write(u64, &entry_header, 32, content.length());
        try appendHashed(&writer, &hasher, &total, &entry_header);

        var window: [request_window_size]u8 = undefined;
        var offset: u64 = 0;
        while (offset < content.length()) {
            const bytes = try content.readWindow(offset, &window);
            if (bytes.len == 0) return error.TruncatedContextBlob;
            try appendHashed(&writer, &hasher, &total, bytes);
            offset += bytes.len;
        }
    }
    try writer.finish();

    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest_bytes);
    var digest = std.mem.readInt(u64, digest_bytes[0..8], .little);
    if (digest == 0) digest = 1;
    return .{
        .request_ref = request_ref,
        .digest = digest,
        .length = total,
        .first_entry = first_entry,
        .entry_count = entry_count,
    };
}

fn appendHashed(
    writer: *session_store.BlobWriter,
    hasher: *std.crypto.hash.sha2.Sha256,
    total: *u64,
    bytes: []const u8,
) !void {
    try writer.append(bytes);
    hasher.update(bytes);
    total.* += bytes.len;
}

pub const Fixture = struct {
    expected_task: ?[]const u8,
    final_answer: []const u8,
    status: model_protocol.Status = .complete,
    finish_response: bool = true,
    calls: u32 = 0,

    pub fn provider(self: *Fixture) Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request: RequestReader,
        response: ResponseWriter,
    ) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.calls += 1;
        var header: [request_header_size + entry_header_size]u8 = undefined;
        const prefix = try request.readWindow(0, &header);
        if (prefix.len != header.len or
            !std.mem.eql(u8, prefix[0..request_magic.len], request_magic) or
            read(u16, prefix, 8) != version or
            read(u16, prefix, 10) != request_header_size or
            read(u32, prefix, 12) == 0 or
            prefix[request_header_size] != @intFromEnum(session_store.EntryKind.user))
        {
            return error.UnexpectedFixtureRequest;
        }
        if (self.expected_task) |expected_task| {
            const task_length = read(u64, prefix, request_header_size + 32);
            if (task_length != expected_task.len or task_length > request_window_size) {
                return error.UnexpectedFixtureRequest;
            }
            var task_buffer: [request_window_size]u8 = undefined;
            const task = try request.readWindow(header.len, task_buffer[0..@intCast(task_length)]);
            if (!std.mem.eql(u8, task, expected_task)) return error.UnexpectedFixtureRequest;
        }

        var response_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = try model_protocol.encodeText(
            &response_buffer,
            self.status,
            self.final_answer,
        );
        try response.append(encoded);
        if (self.finish_response) try response.finish();
    }
};

pub const ToolFixture = struct {
    expected_task: []const u8,
    tool_arguments: []const u8,
    final_answer: []const u8,
    tool: model_protocol.Tool = .bash,
    expected_tool_status: bash_tool.Status = .success,
    expected_patch_status: patch_tool.ResultStatus = .denied,
    calls: u8 = 0,

    pub fn provider(self: *ToolFixture) Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request: RequestReader,
        response: ResponseWriter,
    ) anyerror!void {
        const self: *ToolFixture = @ptrCast(@alignCast(context));
        var header: [request_header_size + entry_header_size]u8 = undefined;
        const prefix = try request.readWindow(0, &header);
        if (prefix.len != header.len or
            !std.mem.eql(u8, prefix[0..request_magic.len], request_magic) or
            read(u16, prefix, 8) != version or read(u16, prefix, 10) != request_header_size)
        {
            return error.UnexpectedFixtureRequest;
        }
        const entry_count = read(u32, prefix, 12);
        var encoded_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = switch (self.calls) {
            0 => blk: {
                if (entry_count != 1 or prefix[request_header_size] != @intFromEnum(session_store.EntryKind.user)) {
                    return error.UnexpectedFixtureRequest;
                }
                const task_length = read(u64, prefix, request_header_size + 32);
                if (task_length != self.expected_task.len or task_length > request_window_size) {
                    return error.UnexpectedFixtureRequest;
                }
                var task_buffer: [request_window_size]u8 = undefined;
                const task = try request.readWindow(header.len, task_buffer[0..@intCast(task_length)]);
                if (!std.mem.eql(u8, task, self.expected_task)) return error.UnexpectedFixtureRequest;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    self.tool,
                    self.tool_arguments,
                );
            },
            1 => blk: {
                if (entry_count != 3) return error.ToolResultMissingFromContext;
                const task_length = read(u64, prefix, request_header_size + 32);
                const second_header_offset = request_header_size + entry_header_size + task_length;
                var second_header: [entry_header_size]u8 = undefined;
                const second = try request.readWindow(second_header_offset, &second_header);
                if (second.len != second_header.len or
                    second[0] != @intFromEnum(session_store.EntryKind.assistant))
                {
                    return error.ToolCallMissingFromContext;
                }
                const call_length = read(u64, second, 32);
                if (call_length != self.tool_arguments.len) return error.ToolCallMissingFromContext;
                if (call_length > request_window_size) return error.ToolCallMissingFromContext;
                var call_buffer: [request_window_size]u8 = undefined;
                const call_bytes = try request.readWindow(
                    second_header_offset + entry_header_size,
                    call_buffer[0..@intCast(call_length)],
                );
                if (!std.mem.eql(u8, call_bytes, self.tool_arguments)) return error.ToolCallMissingFromContext;
                const third_header_offset = second_header_offset + entry_header_size + call_length;
                var third_header: [entry_header_size]u8 = undefined;
                const third = try request.readWindow(third_header_offset, &third_header);
                if (third.len != third_header.len or
                    third[0] != @intFromEnum(session_store.EntryKind.tool_result))
                {
                    return error.ToolResultMissingFromContext;
                }
                const result_length = read(u64, third, 32);
                if (result_length > request_window_size) {
                    return error.InvalidFixtureToolResult;
                }
                var result_buffer: [request_window_size]u8 = undefined;
                const result = try request.readWindow(
                    third_header_offset + entry_header_size,
                    result_buffer[0..@intCast(result_length)],
                );
                switch (self.tool) {
                    .bash => {
                        if (result_length < bash_tool.result_header_size) return error.InvalidFixtureToolResult;
                        const view = try bash_tool.decodeResult(result);
                        if (view.status != self.expected_tool_status) return error.UnexpectedFixtureToolStatus;
                    },
                    .apply_patch => {
                        if (result_length != patch_tool.result_size) return error.InvalidFixtureToolResult;
                        const bytes: *const [patch_tool.result_size]u8 = @ptrCast(result.ptr);
                        const view = try patch_tool.decodeResult(bytes);
                        if (view.status != self.expected_patch_status) return error.UnexpectedFixtureToolStatus;
                    },
                    .none => return error.UnexpectedFixtureTool,
                }
                break :blk try model_protocol.encodeText(
                    &encoded_buffer,
                    .complete,
                    self.final_answer,
                );
            },
            else => return error.UnexpectedFixtureCall,
        };
        self.calls += 1;
        try response.append(encoded);
        try response.finish();
    }
};

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "request reconstruction walks durable entries through bounded windows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "sessions", .default_dir);
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try repo.createDir(io, ".git", .default_dir);
    var git_dir = try repo.openDir(io, ".git", .{});
    defer git_dir.close(io);
    try git_dir.createDir(io, "objects", .default_dir);
    try git_dir.createDir(io, "refs", .default_dir);
    var config = try git_dir.createFile(io, "config", .{});
    defer config.close(io);
    try config.writePositionalAll(io, "[core]\n\trepositoryformatversion = 0\n", 0);
    var head = try git_dir.createFile(io, "HEAD", .{});
    defer head.close(io);
    try head.writePositionalAll(io, "ref: refs/heads/main\n", 0);
    var path_buffer: [128]u8 = undefined;
    const repo_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/repo",
        .{tmp.sub_path},
    );
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var database_path_buffer: [128]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        ".zig-cache/tmp/{s}/host.sqlite3",
        .{tmp.sub_path},
    );
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();
    var session = try session_store.Session.create(sessions, &storage, io, .{
        .workspace_path = repo_path,
        .model = "fixture:answer",
        .task = "Explain the repository",
    });
    defer session.close();
    const token = session.ownerToken();
    const descriptor = try buildRequest(&session, token, 1001, 1, 1);
    try std.testing.expect(descriptor.digest != 0);
    try std.testing.expectEqual(@as(u32, 1), descriptor.entry_count);

    var fixture: Fixture = .{
        .expected_task = "Explain the repository",
        .final_answer = "This repository contains one bounded agent core.",
    };
    const provider = fixture.provider();
    var provider_io = try ProviderIo.open(&session, token, descriptor.request_ref, 1002);
    defer provider_io.close();
    try provider.dispatch(
        provider.context,
        provider_io.requestCapability(),
        provider_io.responseCapability(),
    );
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const response = try session.readBlob(token, 1002, 0, &response_buffer);
    try std.testing.expectEqual(
        model_protocol.Disposition.final_answer,
        model_protocol.parse(response).disposition,
    );
}
