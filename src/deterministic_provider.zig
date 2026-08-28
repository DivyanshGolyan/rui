const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const binding = @import("binding.zig");
const conversation = @import("conversation.zig");
const host_store = @import("host_store.zig");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

const fixture_entry_capacity = 7;
const fixture_request_capacity = 32 * 1024;
const request_magic = "ONEREQ2\x00";

const RequestEntry = struct {
    kind: session_store.EntryKind,
    entry_id: u64,
    parent_id: u64,
    content: []const u8,
};

/// One bounded interpretation of the durable request wire format for the
/// deterministic Provider adapter. Production providers do not depend on it.
const RequestHistory = struct {
    bytes: [fixture_request_capacity]u8,
    entries: [fixture_entry_capacity]RequestEntry,
    entry_count: usize,

    fn decode(self: *RequestHistory, request: model_operation.RequestReader) !void {
        const length = request.length();
        if (length < model_operation.request_header_size or length > self.bytes.len) {
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
            read(u16, durable, 8) != model_operation.version or
            read(u16, durable, 10) != model_operation.request_header_size)
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
            tool_count != model_contract.default_catalog.len or
            instructions_length != model_contract.default_instructions.len or
            model_contract_length != model_contract.model_contract_bytes.len or
            !std.mem.eql(u8, durable[28..60], &(try model_contract.catalogDigest(&model_contract.default_catalog)).bytes) or
            !std.mem.eql(u8, durable[60..92], &binding.hash(binding.ModelContract, model_contract.model_contract_bytes).bytes))
        {
            return error.UnexpectedFixtureRequest;
        }

        var cursor: usize = model_operation.request_header_size;
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
            if (cursor > durable.len or durable.len - cursor < model_operation.tool_header_size) {
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
            cursor += model_operation.tool_header_size;
            const fields = [_][]const u8{
                definition.key,
                definition.provider_tool_name,
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
            if (cursor > durable.len or durable.len - cursor < model_operation.entry_header_size) {
                return error.UnexpectedFixtureRequest;
            }
            const header = durable[cursor..][0..model_operation.entry_header_size];
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
                content_length > durable.len - cursor - model_operation.entry_header_size)
            {
                return error.UnexpectedFixtureRequest;
            }
            const content_start = cursor + model_operation.entry_header_size;
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

pub const Fixture = struct {
    expected_task: ?[]const u8,
    final_answer: []const u8,
    finish_response: bool = true,
    calls: u32 = 0,

    pub fn provider(self: *Fixture) model_operation.Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request: model_operation.RequestReader,
        response: model_operation.ResponseWriter,
    ) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.calls += 1;
        var history: RequestHistory = undefined;
        try history.decode(request);
        const entries = history.slice();
        if (entries[0].kind != .user_text) return error.UnexpectedFixtureRequest;
        if (self.expected_task) |expected_task| try expectEntry(entries[0], .user_text, expected_task);

        var response_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = try model_protocol.encodeText(&response_buffer, self.final_answer);
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

    pub fn provider(self: *ToolFixture) model_operation.Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request: model_operation.RequestReader,
        response: model_operation.ResponseWriter,
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
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
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
                    .bash => if (!std.mem.startsWith(u8, result.content, try bashStatusPrefix(self.expected_tool_status))) {
                        return error.UnexpectedFixtureToolStatus;
                    },
                    .apply_patch => if (!std.mem.eql(u8, result.content, try patchStatusText(self.expected_patch_status))) {
                        return error.UnexpectedFixtureToolStatus;
                    },
                }
                break :blk try model_protocol.encodeText(&encoded_buffer, self.final_answer);
            },
            else => return error.UnexpectedFixtureCall,
        };
        self.calls += 1;
        try response.append(encoded);
        try response.finish();
    }
};

/// Selects each repair response only after the durable request proves the
/// preceding Action and typed Result. No call counter drives this adapter.
pub const RepairFixture = struct {
    expected_task: []const u8,
    bash_call: []const u8,
    patch: []const u8,
    final_answer: []const u8,

    pub fn provider(self: *RepairFixture) model_operation.Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request: model_operation.RequestReader,
        response: model_operation.ResponseWriter,
    ) anyerror!void {
        const self: *RepairFixture = @ptrCast(@alignCast(context));
        var decoded: RequestHistory = undefined;
        try decoded.decode(request);
        const history = decoded.slice();

        var encoded_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = switch (history.len) {
            1 => blk: {
                try expectEntry(history[0], .user_text, self.expected_task);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.bash_key,
                    try fixtureArguments(.bash, self.bash_call, &arguments),
                );
            },
            3 => blk: {
                try self.expectPrefix(history, 3);
                try expectBashResult(history[2], .nonzero_exit, 1);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.apply_patch_key,
                    try fixtureArguments(.apply_patch, self.patch, &arguments),
                );
            },
            5 => blk: {
                try self.expectPrefix(history, 5);
                try expectPatchResult(history[4], .applied);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.bash_key,
                    try fixtureArguments(.bash, self.bash_call, &arguments),
                );
            },
            7 => blk: {
                try self.expectPrefix(history, 7);
                try expectBashResult(history[6], .success, 0);
                break :blk try model_protocol.encodeText(&encoded_buffer, self.final_answer);
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
    var expected: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
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

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "deterministic Provider decodes the exact immutable request" {
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
    const repo_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path});
    var sessions = try tmp.dir.openDir(io, "sessions", .{});
    defer sessions.close(io);
    var database_path_buffer: [128]u8 = undefined;
    const database_path = try std.fmt.bufPrint(&database_path_buffer, ".zig-cache/tmp/{s}/host.sqlite3", .{tmp.sub_path});
    var storage = try host_store.StorageOwner.open(io, database_path, .{});
    defer storage.close();
    var session = try session_store.Session.create(sessions, &storage, io, .{
        .workspace_path = repo_path,
        .model = "fixture:answer",
        .task = "Explain the repository",
    });
    defer session.close();

    const digest = try model_operation.buildRequest(&session, 1001, 1, 1);
    try model_operation.verifyRequestDigest(&session, 1001, digest);
    const rebuilt_digest = try model_operation.buildRequest(&session, 1003, 1, 1);
    try std.testing.expect(binding.eql(binding.ModelDescriptor, digest, rebuilt_digest));
    var first_request = try session.openBlob(1001);
    defer first_request.close();
    var second_request = try session.openBlob(1003);
    defer second_request.close();
    try std.testing.expectEqual(first_request.length(), second_request.length());
    var first_bytes: [fixture_request_capacity]u8 = undefined;
    var second_bytes: [fixture_request_capacity]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        try first_request.readWindow(0, first_bytes[0..@intCast(first_request.length())]),
        try second_request.readWindow(0, second_bytes[0..@intCast(second_request.length())]),
    );
    var fixture: Fixture = .{
        .expected_task = "Explain the repository",
        .final_answer = "This repository contains one bounded agent core.",
    };
    var provider_io = try model_operation.ProviderIo.open(&session, 1001, 1002);
    defer provider_io.close();
    const provider = fixture.provider();
    try provider.dispatch(provider.context, provider_io.requestCapability(), provider_io.responseCapability());
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const response = try session.readBlob(1002, 0, &response_buffer);
    try std.testing.expectEqual(model_protocol.Disposition.final_answer, model_protocol.parse(response).disposition);

    var request = try session.openBlob(1001);
    defer request.close();
    var first: [fixture_request_capacity]u8 = undefined;
    const original = try request.readWindow(0, first[0..@intCast(request.length())]);
    first[model_operation.request_header_size] ^= 1;
    try session.storeBlob(1004, original);
    try std.testing.expectError(error.ModelRequestDigestMismatch, model_operation.verifyRequestDigest(&session, 1004, digest));

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
    try std.testing.expectError(error.ContextSplitsToolPair, model_operation.buildRequest(&session, 1101, 1, 2));

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
    try std.testing.expectError(error.ContextSplitsToolPair, model_operation.buildRequest(&session, 1103, 3, 1));
}
