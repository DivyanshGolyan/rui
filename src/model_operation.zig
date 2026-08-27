const std = @import("std");
const binding = @import("binding.zig");
const host_store = @import("host_store.zig");
const bash_tool = @import("bash_tool.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");

pub const request_header_size = 16;
pub const entry_header_size = 40;
pub const request_window_size = 4096;
pub const version: u16 = 1;
const fixture_entry_capacity = 7;
const fixture_request_capacity = 32 * 1024;

const request_magic = "ONEREQ\x00\x00";

const RequestEntry = struct {
    kind: session_store.EntryKind,
    content: []const u8,
};

/// One bounded, fixture-private interpretation of the durable request wire
/// format. All deterministic providers inspect history through this decoder.
const RequestHistory = struct {
    bytes: [fixture_request_capacity]u8,
    entries: [fixture_entry_capacity]RequestEntry,
    entry_count: usize,

    fn decode(self: *RequestHistory, request: RequestReader) !void {
        const length = request.length();
        if (length < request_header_size or length > self.bytes.len) {
            return error.UnexpectedFixtureRequest;
        }
        const byte_count: usize = @intCast(length);
        var offset: usize = 0;
        while (offset < byte_count) {
            const bytes = try request.readWindow(offset, self.bytes[offset..byte_count]);
            if (bytes.len == 0 or bytes.len > byte_count - offset) {
                return error.UnexpectedFixtureRequest;
            }
            if (bytes.ptr != self.bytes[offset..].ptr) {
                @memcpy(self.bytes[offset..][0..bytes.len], bytes);
            }
            offset += bytes.len;
        }

        const durable = self.bytes[0..byte_count];
        if (!std.mem.eql(u8, durable[0..request_magic.len], request_magic) or
            read(u16, durable, 8) != version or
            read(u16, durable, 10) != request_header_size)
        {
            return error.UnexpectedFixtureRequest;
        }
        const count: usize = @intCast(read(u32, durable, 12));
        if (count == 0 or count > self.entries.len) return error.UnexpectedFixtureRequest;

        var cursor: usize = request_header_size;
        for (0..count) |index| {
            if (cursor > durable.len or durable.len - cursor < entry_header_size) {
                return error.UnexpectedFixtureRequest;
            }
            const header = durable[cursor..][0..entry_header_size];
            const kind: session_store.EntryKind = switch (header[0]) {
                1 => .user,
                2 => .assistant,
                3 => .tool_result,
                4 => .context_checkpoint,
                else => return error.UnexpectedFixtureRequest,
            };
            const content_length = read(u64, header, 32);
            if (read(u64, header, 8) != index + 1 or
                read(u64, header, 16) != index or
                read(u64, header, 24) == 0 or
                content_length > durable.len - cursor - entry_header_size)
            {
                return error.UnexpectedFixtureRequest;
            }
            const content_start = cursor + entry_header_size;
            const content_end = content_start + @as(usize, @intCast(content_length));
            self.entries[index] = .{
                .kind = kind,
                .content = self.bytes[content_start..content_end],
            };
            cursor = content_end;
        }
        if (cursor != durable.len) return error.UnexpectedFixtureRequest;
        self.entry_count = count;
    }

    fn slice(self: *const RequestHistory) []const RequestEntry {
        return self.entries[0..self.entry_count];
    }
};

pub const Descriptor = struct {
    request_ref: u64,
    digest: binding.ModelDescriptor,
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
        request_ref: u64,
        response_ref: u64,
    ) !ProviderIo {
        var request = try session.openBlob(request_ref);
        errdefer request.close();
        const response = try session.beginBlob(response_ref);
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
        response_ref: u64,
    ) !u64 {
        self.response.abort();
        return publishFailureResult(session, response_ref);
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

pub fn publishFailureResult(
    session: *session_store.Session,
    identity: u64,
) !u64 {
    const failure_ref = (@as(u64, 1) << 56) | (identity & ((@as(u64, 1) << 56) - 1));
    var buffer: [model_protocol.header_size]u8 = undefined;
    const encoded = try model_protocol.encodeText(&buffer, .provider_error, "");
    try session.storeBlob(failure_ref, encoded);
    return failure_ref;
}

pub fn buildRequest(
    session: *session_store.Session,
    request_ref: u64,
    first_entry: u32,
    entry_count: u32,
) !Descriptor {
    if (request_ref == 0 or first_entry == 0 or entry_count == 0) {
        return error.InvalidContextSelection;
    }
    const last = @as(u64, first_entry) + entry_count - 1;
    if (last > session.entryCount()) return error.InvalidContextSelection;

    var writer = try session.beginBlob(request_ref);
    errdefer writer.abort();
    var hasher = binding.Hasher(binding.ModelDescriptor).init();
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
        var content = try session.openBlob(entry.content_ref);
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

    return .{
        .request_ref = request_ref,
        .digest = hasher.final(),
        .length = total,
        .first_entry = first_entry,
        .entry_count = entry_count,
    };
}

fn appendHashed(
    writer: *session_store.BlobWriter,
    hasher: *binding.Hasher(binding.ModelDescriptor),
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
        var history: RequestHistory = undefined;
        try history.decode(request);
        const entries = history.slice();
        if (entries[0].kind != .user) return error.UnexpectedFixtureRequest;
        if (self.expected_task) |expected_task| {
            try expectEntry(entries[0], .user, expected_task);
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
        var history: RequestHistory = undefined;
        try history.decode(request);
        const entries = history.slice();
        var encoded_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = switch (self.calls) {
            0 => blk: {
                if (entries.len != 1) return error.UnexpectedFixtureRequest;
                try expectEntry(entries[0], .user, self.expected_task);
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    self.tool,
                    self.tool_arguments,
                );
            },
            1 => blk: {
                if (entries.len != 3) return error.ToolResultMissingFromContext;
                try expectEntry(entries[0], .user, self.expected_task);
                if (entries[1].kind != .assistant or
                    !std.mem.eql(u8, entries[1].content, self.tool_arguments))
                {
                    return error.ToolCallMissingFromContext;
                }
                const result = entries[2].content;
                switch (self.tool) {
                    .bash => {
                        if (result.len < bash_tool.result_header_size) return error.InvalidFixtureToolResult;
                        const view = try bash_tool.decodeResult(result);
                        if (view.status != self.expected_tool_status) return error.UnexpectedFixtureToolStatus;
                    },
                    .apply_patch => {
                        if (result.len != patch_tool.result_size) return error.InvalidFixtureToolResult;
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

/// Drives the complete deterministic repair from the exact committed
/// Conversation. It has no call counter: each response is selected only after
/// the durable request proves the preceding Action and typed Result.
pub const RepairFixture = struct {
    expected_task: []const u8,
    bash_call: []const u8,
    patch: []const u8,
    final_answer: []const u8,

    pub fn provider(self: *RepairFixture) Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request: RequestReader,
        response: ResponseWriter,
    ) anyerror!void {
        const self: *RepairFixture = @ptrCast(@alignCast(context));
        var decoded: RequestHistory = undefined;
        try decoded.decode(request);
        const history = decoded.slice();

        var encoded_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = switch (history.len) {
            1 => blk: {
                try expectEntry(history[0], .user, self.expected_task);
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    .bash,
                    self.bash_call,
                );
            },
            3 => blk: {
                try self.expectPrefix(history, 3);
                try expectBashResult(history[2], .nonzero_exit, 1);
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    .apply_patch,
                    self.patch,
                );
            },
            5 => blk: {
                try self.expectPrefix(history, 5);
                try expectPatchResult(history[4], .applied);
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    .bash,
                    self.bash_call,
                );
            },
            7 => blk: {
                try self.expectPrefix(history, 7);
                try expectBashResult(history[6], .success, 0);
                break :blk try model_protocol.encodeText(
                    &encoded_buffer,
                    .complete,
                    self.final_answer,
                );
            },
            else => return error.UnexpectedRepairHistory,
        };
        try response.append(encoded);
        try response.finish();
    }

    fn expectPrefix(self: *const RepairFixture, entries: []const RequestEntry, count: usize) !void {
        if (entries.len != count) return error.UnexpectedRepairHistory;
        try expectEntry(entries[0], .user, self.expected_task);
        try expectEntry(entries[1], .assistant, self.bash_call);
        if (count >= 5) {
            try expectBashResult(entries[2], .nonzero_exit, 1);
            try expectEntry(entries[3], .assistant, self.patch);
        }
        if (count >= 7) {
            try expectPatchResult(entries[4], .applied);
            try expectEntry(entries[5], .assistant, self.bash_call);
        }
    }
};

fn expectEntry(entry: RequestEntry, kind: session_store.EntryKind, content: []const u8) !void {
    if (entry.kind != kind or !std.mem.eql(u8, entry.content, content)) {
        return error.UnexpectedRepairHistory;
    }
}

fn expectBashResult(entry: RequestEntry, status: bash_tool.Status, exit_code: u8) !void {
    if (entry.kind != .tool_result) return error.UnexpectedRepairHistory;
    const result = try bash_tool.decodeResult(entry.content);
    if (result.status != status or result.exit_code != exit_code or
        result.stdout.len != 0 or result.stderr.len != 0)
    {
        return error.UnexpectedRepairHistory;
    }
}

fn expectPatchResult(entry: RequestEntry, status: patch_tool.ResultStatus) !void {
    if (entry.kind != .tool_result or entry.content.len != patch_tool.result_size) {
        return error.UnexpectedRepairHistory;
    }
    const bytes: *const [patch_tool.result_size]u8 = @ptrCast(entry.content.ptr);
    if ((try patch_tool.decodeResult(bytes)).status != status) {
        return error.UnexpectedRepairHistory;
    }
}

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
    const descriptor = try buildRequest(&session, 1001, 1, 1);
    try std.testing.expectEqual(@as(usize, 32), descriptor.digest.bytes.len);
    try std.testing.expectEqual(@as(u32, 1), descriptor.entry_count);

    var fixture: Fixture = .{
        .expected_task = "Explain the repository",
        .final_answer = "This repository contains one bounded agent core.",
    };
    const provider = fixture.provider();
    var provider_io = try ProviderIo.open(&session, descriptor.request_ref, 1002);
    defer provider_io.close();
    try provider.dispatch(
        provider.context,
        provider_io.requestCapability(),
        provider_io.responseCapability(),
    );
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const response = try session.readBlob(1002, 0, &response_buffer);
    try std.testing.expectEqual(
        model_protocol.Disposition.final_answer,
        model_protocol.parse(response).disposition,
    );
}
