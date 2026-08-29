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
        request_value: model_operation.RequestCursor,
        response: model_operation.CandidateWriter,
    ) anyerror!model_operation.DispatchOutcome {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.calls += 1;
        var request = request_value;
        const first = (try request.next()) orelse return error.UnexpectedFixtureRequest;
        if (self.expected_task) |expected_task| try expectText(first, .user_text, expected_task);
        while (try request.next()) |_| {}

        var response_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = try model_protocol.encodeText(&response_buffer, self.final_answer);
        try response.append(encoded);
        if (!self.finish_response) return error.IncompleteFixtureResponse;
        return .candidate;
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
        request_value: model_operation.RequestCursor,
        response: model_operation.CandidateWriter,
    ) anyerror!model_operation.DispatchOutcome {
        const self: *ToolFixture = @ptrCast(@alignCast(context));
        var request = request_value;
        var encoded_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = switch (self.calls) {
            0 => blk: {
                if (request.entryCount() != 1) return error.UnexpectedFixtureRequest;
                try expectText((try request.next()).?, .user_text, self.expected_task);
                try expectEnd(&request);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    fixtureToolKey(self.tool),
                    try fixtureArguments(self.tool, self.tool_arguments, &arguments),
                );
            },
            1 => blk: {
                if (request.entryCount() != 3) return error.ToolResultMissingFromContext;
                try expectText((try request.next()).?, .user_text, self.expected_task);
                try expectToolCall((try request.next()).?, self.tool, self.tool_arguments);
                const result = switch ((try request.next()).?) {
                    .tool_result => |result| result,
                    else => return error.ToolResultMissingFromContext,
                };
                try expectEnd(&request);
                switch (self.tool) {
                    .bash => if (!try contentStartsWith(result.content, try bashStatusPrefix(self.expected_tool_status))) {
                        return error.UnexpectedFixtureToolStatus;
                    },
                    .apply_patch => if (!try contentEquals(result.content, try patchStatusText(self.expected_patch_status))) {
                        return error.UnexpectedFixtureToolStatus;
                    },
                }
                break :blk try model_protocol.encodeText(&encoded_buffer, self.final_answer);
            },
            else => return error.UnexpectedFixtureCall,
        };
        self.calls += 1;
        try response.append(encoded);
        return .candidate;
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
        request_value: model_operation.RequestCursor,
        response: model_operation.CandidateWriter,
    ) anyerror!model_operation.DispatchOutcome {
        const self: *RepairFixture = @ptrCast(@alignCast(context));
        var request = request_value;

        var encoded_buffer: [model_protocol.max_response_size]u8 = undefined;
        const encoded = switch (request.entryCount()) {
            1 => blk: {
                try expectText((try request.next()).?, .user_text, self.expected_task);
                try expectEnd(&request);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.bash_key,
                    try fixtureArguments(.bash, self.bash_call, &arguments),
                );
            },
            3 => blk: {
                try self.expectPrefix(&request, 3);
                try expectBashResult((try request.next()).?, .nonzero_exit, 1);
                try expectEnd(&request);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.apply_patch_key,
                    try fixtureArguments(.apply_patch, self.patch, &arguments),
                );
            },
            5 => blk: {
                try self.expectPrefix(&request, 5);
                try expectPatchResult((try request.next()).?, .applied);
                try expectEnd(&request);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                break :blk try model_protocol.encodeTool(
                    &encoded_buffer,
                    model_contract.bash_key,
                    try fixtureArguments(.bash, self.bash_call, &arguments),
                );
            },
            7 => blk: {
                try self.expectPrefix(&request, 7);
                try expectBashResult((try request.next()).?, .success, 0);
                try expectEnd(&request);
                break :blk try model_protocol.encodeText(&encoded_buffer, self.final_answer);
            },
            else => return error.UnexpectedRepairHistory,
        };
        try response.append(encoded);
        return .candidate;
    }

    fn expectPrefix(
        self: *const RepairFixture,
        request: *model_operation.RequestCursor,
        count: usize,
    ) !void {
        if (request.entryCount() != count) return error.UnexpectedRepairHistory;
        try expectText((try request.next()).?, .user_text, self.expected_task);
        try expectToolCall((try request.next()).?, .bash, self.bash_call);
        if (count >= 5) {
            try expectBashResult((try request.next()).?, .nonzero_exit, 1);
            try expectToolCall((try request.next()).?, .apply_patch, self.patch);
        }
        if (count >= 7) {
            try expectPatchResult((try request.next()).?, .applied);
            try expectToolCall((try request.next()).?, .bash, self.bash_call);
        }
    }
};

fn fixtureToolKey(tool: FixtureTool) []const u8 {
    return switch (tool) {
        .bash => model_contract.bash_key,
        .apply_patch => model_contract.apply_patch_key,
    };
}

fn fixtureArguments(
    tool: FixtureTool,
    raw: []const u8,
    out: []u8,
) ![]const u8 {
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

fn expectToolCall(
    entry: model_operation.RequestEntry,
    tool: FixtureTool,
    raw: []const u8,
) !void {
    const call = switch (entry) {
        .tool_call => |call| call,
        else => return error.ToolCallMissingFromContext,
    };
    if (!std.mem.eql(u8, call.key(), fixtureToolKey(tool))) return error.ToolCallMissingFromContext;
    var expected: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
    if (!try contentEquals(call.arguments, try fixtureArguments(tool, raw, &expected))) {
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

fn expectText(entry: model_operation.RequestEntry, kind: model_operation.EntryKind, content: []const u8) !void {
    const actual = switch (entry) {
        .user_text => |value| if (kind == .user_text) value.content else return error.UnexpectedRepairHistory,
        .assistant_text => |value| if (kind == .assistant_text) value.content else return error.UnexpectedRepairHistory,
        .context_checkpoint => |value| if (kind == .context_checkpoint) value.content else return error.UnexpectedRepairHistory,
        else => return error.UnexpectedRepairHistory,
    };
    if (!try contentEquals(actual, content)) return error.UnexpectedRepairHistory;
}

fn expectBashResult(entry: model_operation.RequestEntry, status: bash_tool.Status, exit_code: u8) !void {
    const result = switch (entry) {
        .tool_result => |result| result,
        else => return error.UnexpectedRepairHistory,
    };
    var expected: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&expected, "{s}\nexit_code={d}\n", .{ try bashStatusPrefix(status), exit_code });
    if (!try contentStartsWith(result.content, prefix)) return error.UnexpectedRepairHistory;
}

fn expectPatchResult(entry: model_operation.RequestEntry, status: patch_tool.ResultStatus) !void {
    const result = switch (entry) {
        .tool_result => |result| result,
        else => return error.UnexpectedRepairHistory,
    };
    if (!try contentEquals(result.content, try patchStatusText(status))) return error.UnexpectedRepairHistory;
}

fn expectEnd(request: *model_operation.RequestCursor) !void {
    if (try request.next() != null) return error.UnexpectedFixtureRequest;
}

fn contentEquals(content: model_operation.ContentView, expected: []const u8) !bool {
    if (content.length() != expected.len) return false;
    var window: [model_operation.request_window_size]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const actual = try content.readWindow(offset, &window);
        if (actual.len == 0 or !std.mem.eql(u8, actual, expected[offset..][0..actual.len])) return false;
        offset += actual.len;
    }
    return true;
}

fn contentStartsWith(content: model_operation.ContentView, expected: []const u8) !bool {
    if (content.length() < expected.len) return false;
    var window: [model_operation.request_window_size]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const count = @min(window.len, expected.len - offset);
        const actual = try content.readWindow(offset, window[0..count]);
        if (actual.len != count or !std.mem.eql(u8, actual, expected[offset..][0..count])) return false;
        offset += count;
    }
    return true;
}

fn expectBlobReadersEqual(
    first: *session_store.BlobReader,
    second: *session_store.BlobReader,
) !void {
    if (first.length() != second.length()) return error.RequestLengthMismatch;
    var first_window: [model_operation.request_window_size]u8 = undefined;
    var second_window: [model_operation.request_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < first.length()) {
        const first_bytes = try first.readWindow(offset, &first_window);
        const second_bytes = try second.readWindow(offset, second_window[0..first_bytes.len]);
        try std.testing.expectEqualSlices(u8, first_bytes, second_bytes);
        offset += first_bytes.len;
    }
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
    try expectBlobReadersEqual(&first_request, &second_request);
    var fixture: Fixture = .{
        .expected_task = "Explain the repository",
        .final_answer = "This repository contains one bounded agent core.",
    };
    var provider_io = try model_operation.ProviderIo.open(&session, 1001, 1002);
    defer provider_io.close();
    const provider = fixture.provider();
    try provider_io.settle(try provider.dispatch(
        provider.context,
        try provider_io.request(),
        provider_io.candidateCapability(),
    ));
    var response_buffer: [model_protocol.max_response_size]u8 = undefined;
    const response = try session.readBlob(1002, 0, &response_buffer);
    var response_validation: model_protocol.ValidationScratch = undefined;
    try std.testing.expectEqual(
        model_protocol.Disposition.final_answer,
        model_protocol.parse(&response_validation, response).disposition,
    );

    var request = try session.openBlob(1001);
    defer request.close();
    var first: [model_operation.request_window_size]u8 = undefined;
    try std.testing.expect(request.length() <= first.len);
    const original = try request.readWindow(0, first[0..@intCast(request.length())]);
    first[model_operation.request_header_size] ^= 1;
    try session.storeBlob(1004, original);
    try std.testing.expectError(error.ModelRequestDigestMismatch, model_operation.verifyRequestDigest(&session, 1004, digest));

    var call_buffer: [128]u8 = undefined;
    var json_scratch: model_contract.StrictToolJsonScratch = undefined;
    const call_bytes = try conversation.encodeToolCall(&call_buffer, .{
        .key = "fixture.inspect.v1",
        .arguments = try model_contract.validateStrictToolJson(&json_scratch, "{\"path\":\"README.md\"}"),
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

    var large_content: [40 * 1024]u8 = @splat('x');
    for (0..9) |index| {
        const content_ref: u64 = 1200 + index;
        const content: []const u8 = if (index == 0) &large_content else "later context";
        try session.storeBlob(content_ref, content);
        const entry = try session.appendConversation(.assistant_text, content_ref, null);
        _ = try session.commitSemantic(&.{session_transition.conversationAdvanced(.{
            .agent = .{
                .agent_id = session.agent_id,
                .agent_generation = 1,
                .ownership_epoch = session.ownership_epoch,
            },
            .entry_id = entry.entry_id,
            .parent_id = entry.parent_id,
            .kind = entry.kind,
            .content_ref = entry.content_ref,
        })}, null);
    }
    _ = try model_operation.buildRequest(&session, 1300, 4, 9);
    var large_io = try model_operation.ProviderIo.open(&session, 1300, 1301);
    defer large_io.close();
    var semantic_request = try large_io.request();
    try std.testing.expectEqual(@as(u32, 9), semantic_request.entryCount());
    try std.testing.expectEqualStrings("fixture:answer", semantic_request.modelName());
    var catalog = semantic_request.toolCatalog();
    try std.testing.expectEqual(model_contract.default_catalog.len, catalog.count());
    var definition_buffer: model_operation.ToolDefinitionBuffer = .{};
    for (model_contract.default_catalog) |expected| {
        const definition = (try catalog.next(&definition_buffer)).?;
        try std.testing.expectEqualStrings(expected.key, definition.key);
        try std.testing.expectEqualStrings(expected.input_schema, definition.input_schema);
    }
    try std.testing.expect((try catalog.next(&definition_buffer)) == null);
    const first_late = (try semantic_request.next()).?;
    const first_late_text = switch (first_late) {
        .assistant_text => |text| text,
        else => return error.UnexpectedSemanticEntry,
    };
    try std.testing.expectEqual(@as(u64, 4), first_late_text.entry_id);
    try std.testing.expectEqual(@as(u64, large_content.len), first_late_text.content.length());
    var large_window: [model_operation.request_window_size]u8 = undefined;
    var large_offset: u64 = 0;
    while (large_offset < first_late_text.content.length()) {
        const bytes = try first_late_text.content.readWindow(large_offset, &large_window);
        try std.testing.expect(bytes.len != 0);
        large_offset += bytes.len;
    }
    var semantic_count: u32 = 1;
    while (try semantic_request.next()) |_| semantic_count += 1;
    try std.testing.expectEqual(@as(u32, 9), semantic_count);
    var large_request_blob = try session.openBlob(1300);
    defer large_request_blob.close();
    try std.testing.expect(large_request_blob.length() > 32 * 1024);

    const fixture_catalog = [_]model_contract.ToolDefinition{.{
        .key = "fixture.inspect.v1",
        .provider_tool_name = "fixture_inspect",
        .description = "Inspect one fixture value.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":64}},\"required\":[\"query\"],\"additionalProperties\":false}",
        .result_contract = "Bounded fixture text.",
    }};
    const fixture_digest = try model_operation.buildRequestWithCatalog(
        &session,
        1400,
        1,
        1,
        &fixture_catalog,
    );
    try model_operation.verifyRequestDigest(&session, 1400, fixture_digest);
    var fixture_catalog_storage: model_operation.ToolDefinitionBuffer = .{};
    const restored_catalog_definition = (try model_operation.readToolDefinition(
        &session,
        1400,
        fixture_catalog[0].key,
        &fixture_catalog_storage,
    )).?;
    try std.testing.expectEqualStrings(fixture_catalog[0].key, restored_catalog_definition.key);
    try std.testing.expectEqualStrings(
        fixture_catalog[0].input_schema,
        restored_catalog_definition.input_schema,
    );
    var fixture_io = try model_operation.ProviderIo.open(&session, 1400, 1401);
    defer fixture_io.close();
    var fixture_request = try fixture_io.request();
    var fixture_cursor = fixture_request.toolCatalog();
    var fixture_definition_buffer: model_operation.ToolDefinitionBuffer = .{};
    const restored_definition = (try fixture_cursor.next(&fixture_definition_buffer)).?;
    try std.testing.expectEqualStrings(fixture_catalog[0].key, restored_definition.key);
    try std.testing.expect((try fixture_cursor.next(&fixture_definition_buffer)) == null);
}
