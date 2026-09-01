const std = @import("std");
const bash_tool = @import("bash_tool.zig");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const patch_tool = @import("patch_tool.zig");

pub const Fixture = struct {
    expected_task: ?[]const u8,
    final_answer: []const u8,
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
        var last = (try request.next()) orelse return error.UnexpectedFixtureRequest;
        while (try request.next()) |entry| last = entry;
        if (self.expected_task) |expected_task| try expectText(last, .user_text, expected_task);

        try model_protocol.writeText(response, self.final_answer);
        return .candidate;
    }
};

pub const FixtureTool = enum { bash, apply_patch };

pub const BatchToolFixture = struct {
    expected_task: []const u8,
    calls: []const model_protocol.ToolCall,
    dispatch_count: u8 = 0,

    pub fn provider(self: *BatchToolFixture) model_operation.Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request_value: model_operation.RequestCursor,
        response: model_operation.CandidateWriter,
    ) anyerror!model_operation.DispatchOutcome {
        const self: *BatchToolFixture = @ptrCast(@alignCast(context));
        if (self.dispatch_count != 0) return error.UnexpectedFixtureCall;
        var request = request_value;
        try expectText((try request.next()).?, .user_text, self.expected_task);
        try expectEnd(&request);
        try model_protocol.writeToolCalls(response, self.calls);
        self.dispatch_count = 1;
        return .candidate;
    }
};

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
        switch (self.calls) {
            0 => {
                if (request.entryCount() < 1) return error.UnexpectedFixtureRequest;
                try skipEntries(&request, request.entryCount() - 1);
                try expectText((try request.next()).?, .user_text, self.expected_task);
                try expectEnd(&request);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                try model_protocol.writeTool(
                    response,
                    fixtureToolKey(self.tool),
                    try fixtureArguments(self.tool, self.tool_arguments, &arguments),
                );
            },
            1 => {
                if (request.entryCount() < 3) return error.ToolResultMissingFromContext;
                try skipEntries(&request, request.entryCount() - 3);
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
                try model_protocol.writeText(response, self.final_answer);
            },
            else => return error.UnexpectedFixtureCall,
        }
        self.calls += 1;
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

        switch (request.entryCount()) {
            1 => {
                try expectText((try request.next()).?, .user_text, self.expected_task);
                try expectEnd(&request);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                try model_protocol.writeTool(
                    response,
                    model_contract.bash_key,
                    try fixtureArguments(.bash, self.bash_call, &arguments),
                );
            },
            3 => {
                try self.expectPrefix(&request, 3);
                try expectBashResult((try request.next()).?, .nonzero_exit, 1);
                try expectEnd(&request);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                try model_protocol.writeTool(
                    response,
                    model_contract.apply_patch_key,
                    try fixtureArguments(.apply_patch, self.patch, &arguments),
                );
            },
            5 => {
                try self.expectPrefix(&request, 5);
                try expectPatchResult((try request.next()).?, .applied);
                try expectEnd(&request);
                var arguments: [model_contract.max_tool_arguments_envelope_size]u8 = undefined;
                try model_protocol.writeTool(
                    response,
                    model_contract.bash_key,
                    try fixtureArguments(.bash, self.bash_call, &arguments),
                );
            },
            7 => {
                try self.expectPrefix(&request, 7);
                try expectBashResult((try request.next()).?, .success, 0);
                try expectEnd(&request);
                try model_protocol.writeText(response, self.final_answer);
            },
            else => return error.UnexpectedRepairHistory,
        }
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

fn skipEntries(request: *model_operation.RequestCursor, count: u32) !void {
    for (0..count) |_| _ = (try request.next()) orelse return error.UnexpectedFixtureRequest;
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
