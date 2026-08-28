const std = @import("std");
const binding = @import("binding.zig");
const conversation = @import("conversation.zig");
const host_store = @import("host_store.zig");
const bash_tool = @import("bash_tool.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

pub const request_header_size = 92;
pub const tool_header_size = 20;
pub const entry_header_size = 32;
pub const request_window_size = 4096;
pub const version: u16 = 2;
const fixture_entry_capacity = 7;
const fixture_request_capacity = 32 * 1024;

const request_magic = "ONEREQ2\x00";

const RequestEntry = struct {
    kind: session_store.EntryKind,
    entry_id: u64,
    parent_id: u64,
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
        const tool_count: usize = read(u16, durable, 16);
        const model_length: usize = read(u16, durable, 18);
        const instructions_length: usize = read(u32, durable, 20);
        const model_contract_length: usize = read(u32, durable, 24);
        if (model_length == 0 or model_length > session_store.model_name_capacity or
            tool_count == 0 or
            tool_count > model_contract.max_tool_count or
            instructions_length != model_contract.default_instructions.len or
            model_contract_length != model_contract.model_contract_bytes.len or
            !std.mem.eql(u8, durable[28..60], &(try model_contract.catalogDigest(&model_contract.default_catalog)).bytes) or
            !std.mem.eql(u8, durable[60..92], &binding.hash(binding.ModelContract, model_contract.model_contract_bytes).bytes))
        {
            return error.UnexpectedFixtureRequest;
        }

        var cursor: usize = request_header_size;
        if (model_length > durable.len - cursor or
            !model_contract.utf8Valid(durable[cursor..][0..model_length]))
        {
            return error.UnexpectedFixtureRequest;
        }
        cursor += model_length;
        if (instructions_length > durable.len - cursor or
            !std.mem.eql(u8, durable[cursor..][0..instructions_length], model_contract.default_instructions))
        {
            return error.UnexpectedFixtureRequest;
        }
        cursor += instructions_length;
        if (model_contract_length > durable.len - cursor or
            !std.mem.eql(u8, durable[cursor..][0..model_contract_length], model_contract.model_contract_bytes))
        {
            return error.UnexpectedFixtureRequest;
        }
        cursor += model_contract_length;
        for (model_contract.default_catalog) |definition| {
            if (cursor > durable.len or durable.len - cursor < tool_header_size) {
                return error.UnexpectedFixtureRequest;
            }
            const lengths = [_]usize{
                read(u16, durable, cursor),
                read(u16, durable, cursor + 2),
                read(u32, durable, cursor + 4),
                read(u32, durable, cursor + 8),
                read(u32, durable, cursor + 12),
            };
            if (read(u32, durable, cursor + 16) != 0) return error.UnexpectedFixtureRequest;
            cursor += tool_header_size;
            const fields = [_][]const u8{
                definition.key,
                definition.provider_name,
                definition.description,
                definition.input_schema,
                definition.result_contract,
            };
            for (lengths, fields) |field_length, expected| {
                if (field_length != expected.len or field_length > durable.len - cursor or
                    !std.mem.eql(u8, durable[cursor..][0..field_length], expected))
                {
                    return error.UnexpectedFixtureRequest;
                }
                cursor += field_length;
            }
        }
        for (0..count) |index| {
            if (cursor > durable.len or durable.len - cursor < entry_header_size) {
                return error.UnexpectedFixtureRequest;
            }
            const header = durable[cursor..][0..entry_header_size];
            const kind: session_store.EntryKind = switch (header[0]) {
                1 => .user_text,
                2 => .assistant_text,
                3 => .tool_call,
                4 => .tool_result,
                5 => .context_checkpoint,
                else => return error.UnexpectedFixtureRequest,
            };
            const content_length = read(u64, header, 24);
            const entry_id = read(u64, header, 8);
            const parent_id = read(u64, header, 16);
            if (entry_id != index + 1 or parent_id != index or
                content_length > durable.len - cursor - entry_header_size)
            {
                return error.UnexpectedFixtureRequest;
            }
            const content_start = cursor + entry_header_size;
            const content_end = content_start + @as(usize, @intCast(content_length));
            self.entries[index] = .{
                .kind = kind,
                .entry_id = entry_id,
                .parent_id = parent_id,
                .content = self.bytes[content_start..content_end],
            };
            if (kind == .tool_call) _ = conversation.decodeToolCall(self.entries[index].content) catch
                return error.UnexpectedFixtureRequest;
            if (kind == .tool_result) {
                const result = conversation.decodeToolResult(self.entries[index].content) catch
                    return error.UnexpectedFixtureRequest;
                if (result.parent_id != parent_id or index == 0 or
                    self.entries[index - 1].kind != .tool_call or
                    self.entries[index - 1].entry_id != parent_id)
                {
                    return error.UnexpectedFixtureRequest;
                }
            }
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
    tool_catalog_digest: binding.ToolCatalog,
    model_contract_digest: binding.ModelContract,
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
    const encoded = try model_protocol.encodeFailure(&buffer, .provider_error);
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
    const first = try session.readEntry(first_entry);
    const last_entry = try session.readEntry(last);
    if (first.kind == .tool_result or last_entry.kind == .tool_call) {
        return error.ContextSplitsToolPair;
    }

    const catalog_digest = try model_contract.catalogDigest(&model_contract.default_catalog);
    const contract_digest = binding.hash(binding.ModelContract, model_contract.model_contract_bytes);

    var writer = try session.beginBlob(request_ref);
    errdefer writer.abort();
    var hasher = binding.Hasher(binding.ModelDescriptor).init();
    var total: u64 = 0;
    var request_header: [request_header_size]u8 = @splat(0);
    @memcpy(request_header[0..request_magic.len], request_magic);
    write(u16, &request_header, 8, version);
    write(u16, &request_header, 10, request_header_size);
    write(u32, &request_header, 12, entry_count);
    write(u16, &request_header, 16, model_contract.default_catalog.len);
    write(u16, &request_header, 18, @intCast(session.modelName().len));
    write(u32, &request_header, 20, model_contract.default_instructions.len);
    write(u32, &request_header, 24, model_contract.model_contract_bytes.len);
    @memcpy(request_header[28..60], &catalog_digest.bytes);
    @memcpy(request_header[60..92], &contract_digest.bytes);
    try appendHashed(&writer, &hasher, &total, &request_header);
    try appendHashed(&writer, &hasher, &total, session.modelName());
    try appendHashed(&writer, &hasher, &total, model_contract.default_instructions);
    try appendHashed(&writer, &hasher, &total, model_contract.model_contract_bytes);
    for (model_contract.default_catalog) |definition| {
        var tool_header: [tool_header_size]u8 = @splat(0);
        write(u16, &tool_header, 0, @intCast(definition.key.len));
        write(u16, &tool_header, 2, @intCast(definition.provider_name.len));
        write(u32, &tool_header, 4, @intCast(definition.description.len));
        write(u32, &tool_header, 8, @intCast(definition.input_schema.len));
        write(u32, &tool_header, 12, @intCast(definition.result_contract.len));
        try appendHashed(&writer, &hasher, &total, &tool_header);
        try appendHashed(&writer, &hasher, &total, definition.key);
        try appendHashed(&writer, &hasher, &total, definition.provider_name);
        try appendHashed(&writer, &hasher, &total, definition.description);
        try appendHashed(&writer, &hasher, &total, definition.input_schema);
        try appendHashed(&writer, &hasher, &total, definition.result_contract);
    }

    var sequence: u64 = first_entry;
    while (sequence <= last) : (sequence += 1) {
        const entry = try session.readEntry(sequence);
        var content = try session.openBlob(entry.content_ref);
        defer content.close();
        var entry_header: [entry_header_size]u8 = @splat(0);
        entry_header[0] = @intFromEnum(entry.kind);
        write(u64, &entry_header, 8, entry.entry_id);
        write(u64, &entry_header, 16, entry.parent_id);
        write(u64, &entry_header, 24, content.length());
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
        .tool_catalog_digest = catalog_digest,
        .model_contract_digest = contract_digest,
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
        if (entries[0].kind != .user_text) return error.UnexpectedFixtureRequest;
        if (self.expected_task) |expected_task| {
            try expectEntry(entries[0], .user_text, expected_task);
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

pub const FixtureTool = enum { bash, apply_patch };

pub const ToolFixture = struct {
    expected_task: []const u8,
    tool_arguments: []const u8,
    final_answer: []const u8,
    tool: FixtureTool = .bash,
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
                try expectEntry(entries[0], .user_text, self.expected_task);
                var arguments: [model_contract.max_arguments_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    fixtureToolKey(self.tool),
                    try fixtureArguments(self.tool, self.tool_arguments, &arguments),
                );
            },
            1 => blk: {
                if (entries.len != 3) return error.ToolResultMissingFromContext;
                try expectEntry(entries[0], .user_text, self.expected_task);
                try expectToolCall(entries[1], self.tool, self.tool_arguments);
                const result = try conversation.decodeToolResult(entries[2].content);
                switch (self.tool) {
                    .bash => {
                        if (!std.mem.startsWith(u8, result.content, try bashStatusPrefix(self.expected_tool_status))) {
                            return error.UnexpectedFixtureToolStatus;
                        }
                    },
                    .apply_patch => {
                        if (!std.mem.eql(u8, result.content, try patchStatusText(self.expected_patch_status))) {
                            return error.UnexpectedFixtureToolStatus;
                        }
                    },
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
                try expectEntry(history[0], .user_text, self.expected_task);
                var arguments: [model_contract.max_arguments_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.bash_key,
                    try fixtureArguments(.bash, self.bash_call, &arguments),
                );
            },
            3 => blk: {
                try self.expectPrefix(history, 3);
                try expectBashResult(history[2], .nonzero_exit, 1);
                var arguments: [model_contract.max_arguments_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.apply_patch_key,
                    try fixtureArguments(.apply_patch, self.patch, &arguments),
                );
            },
            5 => blk: {
                try self.expectPrefix(history, 5);
                try expectPatchResult(history[4], .applied);
                var arguments: [model_contract.max_arguments_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.bash_key,
                    try fixtureArguments(.bash, self.bash_call, &arguments),
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
        try expectEntry(entries[0], .user_text, self.expected_task);
        try expectToolCall(entries[1], .bash, self.bash_call);
        if (count >= 5) {
            try expectBashResult(entries[2], .nonzero_exit, 1);
            try expectToolCall(entries[3], .apply_patch, self.patch);
        }
        if (count >= 7) {
            try expectPatchResult(entries[4], .applied);
            try expectToolCall(entries[5], .bash, self.bash_call);
        }
    }
};

fn fixtureToolKey(tool: FixtureTool) []const u8 {
    return switch (tool) {
        .bash => model_contract.bash_key,
        .apply_patch => model_contract.apply_patch_key,
    };
}

fn fixtureArguments(tool: FixtureTool, raw: []const u8, out: []u8) ![]const u8 {
    return switch (tool) {
        .bash => blk: {
            const call = try bash_tool.decodeCall(raw);
            break :blk try model_contract.encodeJson(out, .{
                .command = call.command,
                .timeout_ms = call.timeout_ms,
            });
        },
        .apply_patch => model_contract.encodeJson(out, .{ .patch = raw }),
    };
}

fn expectToolCall(entry: RequestEntry, tool: FixtureTool, raw: []const u8) !void {
    if (entry.kind != .tool_call) return error.ToolCallMissingFromContext;
    const call = try conversation.decodeToolCall(entry.content);
    if (!std.mem.eql(u8, call.key, fixtureToolKey(tool))) return error.ToolCallMissingFromContext;
    var expected: [model_contract.max_arguments_size]u8 = undefined;
    if (!std.mem.eql(u8, call.arguments, try fixtureArguments(tool, raw, &expected))) {
        return error.ToolCallMissingFromContext;
    }
}

fn bashStatusPrefix(status: bash_tool.Status) ![]const u8 {
    return switch (status) {
        .success => "status=success",
        .nonzero_exit => "status=nonzero_exit",
        .timeout => "status=timeout",
        .cancelled => "status=cancelled",
        .missing_executable => "status=missing_executable",
        .truncated => "status=truncated",
        .denied => "status=denied",
        .indeterminate => "status=indeterminate",
        .spawn_error => "status=spawn_error",
    };
}

fn patchStatusText(status: patch_tool.ResultStatus) ![]const u8 {
    return switch (status) {
        .denied => "status=denied",
        .stale => "status=stale",
        .applied => "status=applied",
        .indeterminate => "status=indeterminate",
    };
}

fn expectEntry(entry: RequestEntry, kind: session_store.EntryKind, content: []const u8) !void {
    if (entry.kind != kind or !std.mem.eql(u8, entry.content, content)) {
        return error.UnexpectedRepairHistory;
    }
}

fn expectBashResult(entry: RequestEntry, status: bash_tool.Status, exit_code: u8) !void {
    if (entry.kind != .tool_result) return error.UnexpectedRepairHistory;
    const result = try conversation.decodeToolResult(entry.content);
    var expected: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&expected, "{s}\nexit_code={d}\n", .{ try bashStatusPrefix(status), exit_code });
    if (!std.mem.startsWith(u8, result.content, prefix)) return error.UnexpectedRepairHistory;
}

fn expectPatchResult(entry: RequestEntry, status: patch_tool.ResultStatus) !void {
    if (entry.kind != .tool_result) return error.UnexpectedRepairHistory;
    const result = try conversation.decodeToolResult(entry.content);
    if (!std.mem.eql(u8, result.content, try patchStatusText(status))) return error.UnexpectedRepairHistory;
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
    try std.testing.expect(binding.eql(
        binding.ToolCatalog,
        descriptor.tool_catalog_digest,
        try model_contract.catalogDigest(&model_contract.default_catalog),
    ));
    try std.testing.expect(binding.eql(
        binding.ModelContract,
        descriptor.model_contract_digest,
        binding.hash(binding.ModelContract, model_contract.model_contract_bytes),
    ));
    const reconstructed = try buildRequest(&session, 1003, 1, 1);
    try std.testing.expect(binding.eql(binding.ModelDescriptor, descriptor.digest, reconstructed.digest));
    try std.testing.expectEqual(descriptor.length, reconstructed.length);
    var first_request: [fixture_request_capacity]u8 = undefined;
    var second_request: [fixture_request_capacity]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        try session.readBlob(descriptor.request_ref, 0, first_request[0..@intCast(descriptor.length)]),
        try session.readBlob(reconstructed.request_ref, 0, second_request[0..@intCast(reconstructed.length)]),
    );

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

    var call_buffer: [128]u8 = undefined;
    const call_bytes = try conversation.encodeToolCall(&call_buffer, .{
        .key = "fixture.inspect.v1",
        .arguments = "{\"path\":\"README.md\"}",
    });
    try session.storeBlob(1100, call_bytes);
    const call_entry = try session.appendConversation(.tool_call, 1100, null);
    _ = try session.commitSemantic(&.{session_transition.conversationAdvanced(.{
        .agent = .{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        },
        .entry_id = call_entry.entry_id,
        .parent_id = call_entry.parent_id,
        .kind = call_entry.kind,
        .content_ref = call_entry.content_ref,
    })}, null);
    try std.testing.expectError(error.ContextSplitsToolPair, buildRequest(&session, 1101, 1, 2));

    var result_buffer: [128]u8 = undefined;
    const result_bytes = try conversation.encodeToolResult(&result_buffer, .{
        .parent_id = call_entry.entry_id,
        .is_error = false,
        .content = "status=observed",
    });
    try session.storeBlob(1102, result_bytes);
    const result_entry = try session.appendConversation(.tool_result, 1102, null);
    _ = try session.commitSemantic(&.{session_transition.conversationAdvanced(.{
        .agent = .{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        },
        .entry_id = result_entry.entry_id,
        .parent_id = result_entry.parent_id,
        .kind = result_entry.kind,
        .content_ref = result_entry.content_ref,
    })}, null);
    try std.testing.expectError(error.ContextSplitsToolPair, buildRequest(&session, 1103, 3, 1));
}
