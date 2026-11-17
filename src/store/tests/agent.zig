const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const command_domain = @import("../domain/command.zig");
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ContentReader = content_domain.ContentReader;
const Faults = store_core.Faults;
const HistoricalSettings = historical_domain.HistoricalSettings;
const TestingPage = store_testing.TestingPage;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const skills_fixture_domain = @import("../domain/skills.zig");
const RoundMeter = shared_fixtures.RoundMeter;
const TestingCall = shared_fixtures.TestingCall;
const TestingCommits = shared_fixtures.TestingCommits;
const completeSessionStop = shared_fixtures.completeSessionStop;
const expectContent = shared_fixtures.expectContent;
const expectToolSetNames = shared_fixtures.expectToolSetNames;
const round_budgets = shared_fixtures.round_budgets;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingAgentSpec = shared_fixtures.testingAgentSpec;
const testingContentReference = shared_fixtures.testingContentReference;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "core_tools start_agent persists optional borrowed spec content" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("optional-agent-parent", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"start_agent"});
            const parent = (try storage.configure(&create, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "optional-agent-message", "optional-agent-key", parent.slice(), "start a child");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, model, "optional-agent-call", &.{.{
                .item_id = "optional-item",
                .name = "start_agent",
                .encoded_call_id = "optional-call",
                .decoded_call_id = "optional-call",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
            const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const core_tools = @import("../../core_tools.zig");
            const start = try arena.allocator().create(core_tools.StartAgent);
            const result = try core_tools.checkStartAgent(arena.allocator(), "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"model-a\",\"effort\":null,\"compactAt\":100000,\"tools\":[],\"permissionMode\":\"ask\",\"instructions\":\"Persist these instructions\",\"outputSchema\":{\"type\":\"object\"}}}", start);
            try std.testing.expect(result == .accepted);
            const Capture = struct {
                child: protocol.Bounded(protocol.session_id_bytes) = .{},
                fn call(context: *anyopaque, admission: Store.MessageAdmission) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.child.set(admission.session) catch unreachable;
                }
            };
            var capture: Capture = .{};
            try std.testing.expect(try storage.startAgent(action.binding, parent.slice(), start.task, start.attached, &start.configuration, .{ .context = &capture, .call = Capture.call }, .{}) == .started);
            const child = (try store_core.readSessionForTesting(&storage, capture.child.slice())).?;
            const instructions = try testingContentReference(&storage, @intCast(child.instructions_id.?));
            const schema = try testingContentReference(&storage, @intCast(child.output_schema_id.?));
            try std.testing.expectEqual(@as(u64, "Persist these instructions".len), instructions.length);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("Persist these instructions"), &instructions.digest);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest("{\"type\":\"object\"}"), &schema.digest);
        }
    }.run);
}

test "core_tools start_agent spec refusals fail calls and name the refused setting" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("refused-agent-parent", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"start_agent"});
            const parent = (try storage.configure(&create, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "refused-agent-message", "refused-agent-key", parent.slice(), "start children");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const cases = .{
                .{ "\"model\":null", "model" },
                .{ "\"model\":\"gpt-6.1-sol\",\"effort\":123", "effort" },
                .{ "\"model\":\"gpt-6.1-sol\",\"compactAt\":0", "compactAt" },
                .{ "\"model\":\"gpt-6.1-sol\",\"tools\":null", "tools" },
                .{ "\"model\":\"gpt-6.1-sol\",\"permissionMode\":\"never\"", "permissionMode" },
                .{ "\"model\":\"gpt-6.1-sol\",\"effort\":\"low\",\"compactAt\":1050001,\"tools\":[],\"permissionMode\":\"ask\"", "compact_at_too_large" },
                .{ "\"model\":\"gpt-6.1-sol\",\"effort\":\"none\",\"compactAt\":1,\"tools\":[],\"permissionMode\":\"ask\"", "unsupported_reasoning_effort" },
            };
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var calls: [cases.len]TestingCall = undefined;
            var arguments: [cases.len][]const u8 = undefined;
            inline for (cases, 0..) |entry, index| {
                const id = std.fmt.comptimePrint("refused-{d}", .{index});
                const bytes = "{\"task\":\"read\",\"attached\":false,\"spec\":{" ++ entry[0] ++ "}}";
                const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), bytes, .{});
                arguments[index] = bytes;
                calls[index] = .{ .item_id = id, .name = "start_agent", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = bytes };
            }
            try settleCallsForTesting(&storage, &tmp, model, "refused-agent-calls", &calls);
            const core_tools = @import("../../core_tools.zig");
            const start = try arena.allocator().create(core_tools.StartAgent);
            inline for (cases, 0..) |entry, index| {
                const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                const check = try core_tools.checkStartAgent(arena.allocator(), arguments[index], start);
                const expected_reason = switch (check) {
                    .accepted => accepted: {
                        try std.testing.expect(try storage.startAgent(action.binding, parent.slice(), start.task, start.attached, &start.configuration, null, .{}) == .failed);
                        break :accepted "Rui could not start the agent (" ++ entry[1] ++ "). Nothing was started.";
                    },
                    .rejected => |reason| refused: {
                        try std.testing.expect(std.mem.indexOf(u8, reason, entry[1]) != null);
                        try std.testing.expect(try storage.failCoreCall(action.binding, reason, .{}));
                        break :refused reason;
                    },
                };
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ action.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(expected_reason) } }));
            }
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
        }
    }.run);
}

test "a start_agent call fails and starts nothing when its key is taken or its task's skill is unreadable, and a started one saves every skill its task bound" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) {
                storage.close() catch unreachable;
            };
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("unstarted-agent-parent", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"start_agent"});
            const parent = (try storage.configure(&create, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "unstarted-agent-message", "unstarted-agent-key", parent.slice(), "start children");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const arguments = "{\"task\":\"read\",\"attached\":true,\"spec\":{\"model\":\"model-a\",\"effort\":null,\"compactAt\":100000,\"tools\":[],\"permissionMode\":\"ask\"}}";
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), arguments, .{});
            var calls: [3]TestingCall = undefined;
            inline for (&calls, 0..) |*call, index| {
                const id = std.fmt.comptimePrint("unstarted-{d}", .{index});
                call.* = .{ .item_id = id, .name = "start_agent", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments };
            }
            try settleCallsForTesting(&storage, &tmp, model, "unstarted-agent-calls", &calls);
            const core_tools = @import("../../core_tools.zig");
            const start = try arena.allocator().create(core_tools.StartAgent);
            const failed_sql = "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2";

            const taken = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            var key_buffer: [64]u8 = undefined;
            try submitTestMessage(&storage, &tmp, "unstarted-agent-taken", try std.fmt.bufPrint(&key_buffer, "rui.core/start_agent/{d}", .{taken.binding.action_id}), parent.slice(), "taken");
            try std.testing.expect(try core_tools.checkStartAgent(arena.allocator(), arguments, start) == .accepted);
            try std.testing.expectError(error.InjectedContentImportFailure, storage.startAgent(taken.binding, parent.slice(), start.task, start.attached, &start.configuration, null, .{ .content_import = true }));
            try storage.close();
            opened = false;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            opened = true;
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{taken.binding.action_id}));
            try std.testing.expectEqual(taken.binding.action_id, (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action.binding.action_id);
            try std.testing.expect(try core_tools.checkStartAgent(arena.allocator(), arguments, start) == .accepted);
            try std.testing.expect(try storage.startAgent(taken.binding, parent.slice(), start.task, start.attached, &start.configuration, null, .{}) == .failed);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, failed_sql, .{ taken.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest("Rui could not start the agent: its command key is already taken. Nothing was started.") } }));

            const unreadable = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            const diagnostic = "Skill missing is not in the new Session's catalog.";
            const captured: skills_fixture_domain.MessageCapture = .{ .failed = .{ .code = .skill_file_unavailable, .bytes = diagnostic } };
            try std.testing.expect(try core_tools.checkStartAgent(arena.allocator(), arguments, start) == .accepted);
            try std.testing.expect(try storage.startAgentWithInitialSkills(unreadable.binding, parent.slice(), start.task, start.attached, &start.configuration, null, null, &captured, .{}) == .failed);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, failed_sql, .{ unreadable.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(diagnostic ++ " Nothing was started.") } }));

            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));

            const bound_call = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            const bound: skills_fixture_domain.MessageCapture = .{ .bound = &.{ .{ .name = "first", .bytes = "first body" }, .{ .name = "second", .bytes = "second body" } } };
            try std.testing.expect(try core_tools.checkStartAgent(arena.allocator(), arguments, start) == .accepted);
            try std.testing.expect(try storage.startAgentWithInitialSkills(bound_call.binding, parent.slice(), start.task, start.attached, &start.configuration, null, null, &bound, .{}) == .started);
            const child_sql = "SELECT count(*) FROM message_skill k JOIN message_admission m ON m.admission_id=k.admission_id JOIN content c ON c.content_id=k.content_id WHERE m.session_ref<>?1 AND k.position=?2 AND k.name=?3 AND c.digest=?4";
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_skill", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, child_sql, .{ parent.slice(), @as(u64, 1), "first", store_testing.Blob{ .bytes = &protocol.contentDigest("first body") } }));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, child_sql, .{ parent.slice(), @as(u64, 2), "second", store_testing.Blob{ .bytes = &protocol.contentDigest("second body") } }));
        }
    }.run);
}

test "a start_agent child works in its caller's Workspace with its provider" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for (std.enums.values(protocol.ReasoningEffort)) |effort| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("binding-agent-parent", "", workspace, "model-a");
                create.configuration.tools = try .of(&.{ "bash", "start_agent" });
                const parent = (try storage.configure(&create, .{})).accepted.session;
                try submitTestMessage(&storage, &tmp, "binding-agent-message", "binding-agent-key", parent.slice(), "start a child");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCallsForTesting(&storage, &tmp, model, "binding-agent-call", &.{.{
                    .item_id = "binding-item",
                    .name = "start_agent",
                    .encoded_call_id = "binding-call",
                    .decoded_call_id = "binding-call",
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                }});
                const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                var spec = try testingAgentSpec(&.{"bash"}, "ask");
                try spec.model.value.set("unlisted-effort-model");
                spec.reasoning_effort.state = .value;
                try spec.reasoning_effort.value.set(@tagName(effort));
                try std.testing.expect(try storage.startAgent(action.binding, parent.slice(), "work here", true, &spec, null, .{}) == .started);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1 AND workspace=?2 AND provider='codex'", .{ parent.slice(), workspace }));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision r JOIN session s ON s.session_ref=r.session_ref WHERE s.parent_ref=?1 AND r.reasoning_effort=?2", .{ parent.slice(), @tagName(effort) }));
            }
        }
    }.run);
}

test "start_agent narrows configured tool names including unloaded MCP members" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var records = comptime testingHostToolRecords(&.{
                .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page", .input_schema = "{\"type\":\"object\"}" },
                .{ .name = "other_page", .owner = .mcp, .server = "docs", .description = "Fetch another page", .input_schema = "{\"type\":\"object\"}" },
            });
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            try storage.saveHostToolSet(&host_tool_set);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var create = try completeConfiguration("names-agent-parent", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            create.configuration.tools = try .of(&.{ "fetch_page", "find_tools", "start_agent" });
            create.configuration.loaded_tools = try .of(&.{ "find_tools", "start_agent" });
            const parent = (try storage.configure(&create, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "names-agent-message", "names-agent-key", parent.slice(), "start children");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const cases = [_]struct { names: []const []const u8, refusal: ?[]const u8 = null, remove_tool_set: bool = false }{
                .{ .names = &.{"fetch_page"} },
                .{ .names = &.{ "fetch_page", "start_agent" } },
                .{ .names = &.{} },
                .{ .names = &.{"other_page"}, .refusal = "spec.tools: other_page is not one of your tools. Nothing was started." },
                .{ .names = &.{"bash"}, .refusal = "spec.tools: bash is not one of your tools. Nothing was started." },
                .{ .names = &.{"fetch"}, .refusal = "spec.tools: fetch is not a known tool (unknown_tool). Nothing was started." },
                .{ .names = &.{"fetch_page"}, .remove_tool_set = true, .refusal = "spec.tools: fetch_page is not a known tool (unknown_tool). Nothing was started." },
            };
            var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer memory.deinit();
            const arena = memory.allocator();
            var calls: [cases.len]TestingCall = undefined;
            for (&calls, 0..) |*call, index| {
                const id = try std.fmt.allocPrint(arena, "names-agent-{d}", .{index});
                call.* = .{ .item_id = id, .name = "start_agent", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = "{}", .decoded_arguments = "{}" };
            }
            try settleCallsForTesting(&storage, &tmp, model, "names-agent-calls", &calls);
            const Capture = struct {
                child: protocol.Bounded(protocol.session_id_bytes) = .{},
                fn call(context: *anyopaque, admission: Store.MessageAdmission) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.child.set(admission.session) catch unreachable;
                }
            };
            var started: u64 = 0;
            for (cases) |entry| {
                if (entry.remove_tool_set) try storage.saveHostToolSet(&tool_defs.built_in_tool_set);
                const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                var spec = try testingAgentSpec(entry.names, "ask");
                var capture: Capture = .{};
                const result = try storage.startAgent(action.binding, parent.slice(), "read", true, &spec, .{ .context = &capture, .call = Capture.call }, .{});
                if (entry.refusal) |reason| {
                    try std.testing.expectEqual(command_domain.AgentStart.failed, result);
                    try std.testing.expectEqual(@as(usize, 0), capture.child.len);
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ action.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(reason) } }));
                } else {
                    try std.testing.expectEqual(command_domain.AgentStart.started, result);
                    const child = try storage.inspectSessionForTesting(capture.child.slice());
                    try expectToolSetNames(&storage, child.tool_set_id, entry.names);
                    try std.testing.expectEqualStrings("ask", child.permission_mode.slice());
                    try std.testing.expectEqualStrings(create.configuration.workspace.value.slice(), child.workspace.slice());
                    try std.testing.expectEqual(protocol.Provider.codex, child.provider.?);
                    started += 1;
                }
                try std.testing.expectEqual(1 + started, try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "session message writer covers peer message_agent start_agent and ending with wake and refusal" {
    const owner = @embedFile("../domain/sourced_input.zig");
    const callers = @embedFile("../domain/command.zig");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, owner, "a.write(admit_message,"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, owner, "a.write(admit_sent_message,"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, owner, "a.identity(.admission_id)"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, callers, "INSERT INTO message_admission"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, callers, "sourced_input.queue("));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, callers, "try admitFromSession("));
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Source = enum { peer, message_agent, start_agent, ending };
            inline for (std.enums.values(Source)) |source| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var path: [protocol.max_workspace_bytes]u8 = undefined;
                var create = try completeConfiguration("writer-source", "", try canonicalCwd(std.testing.io, &path), "model-a");
                create.configuration.tools = try .of(&.{ "bash", "message_agent", "start_agent" });
                create.configuration.permission_mode.state = .value;
                try create.configuration.permission_mode.value.set("bypass");
                const sender = (try storage.configure(&create, .{})).accepted.session;
                var receiver = try configureTestSession(&storage, "writer-target");
                if (source == .peer or source == .message_agent) {
                    var stop = try completeSessionStop("writer-target-stop", receiver.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                }
                if (source == .ending) try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ receiver.slice(), sender.slice() });
                try submitTestMessage(&storage, &tmp, "writer-task", "writer-task", sender.slice(), "send");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const text = "writer's saved content";
                var key_buffer: [128]u8 = undefined;
                var key: []const u8 = undefined;
                var action: action_domain.CoreActionInput = undefined;
                var peer: ActionExecutionInput = undefined;
                if (source == .peer) {
                    try settleTwoActionsForTesting(&storage, &tmp, model, "writer-peer-calls");
                    const binding = (try storage.admitNextActionAttempt(.{ .free_credit = .one, .mcp_open = true }, 300_000, .{})).?.permit.binding;
                    try storage.readActionExecutionInput(.bash, binding, &peer);
                    key = "writer-peer-send";
                } else if (source == .ending) {
                    try settleItemsForTesting(&storage, &tmp, model, &.{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"writer's saved content\"}]}"}, text);
                    key = try std.fmt.bufPrint(&key_buffer, "rui.core/ending/{d}", .{model.turn_id});
                } else {
                    const name = @tagName(source);
                    var arguments_buffer: [128]u8 = undefined;
                    const arguments = if (source == .message_agent) try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"hello\"}}", .{receiver.slice()}) else "{}";
                    var encoded_buffer: [192]u8 = undefined;
                    const encoded = if (source == .message_agent) try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hello\\\"}}", .{receiver.slice()}) else "{}";
                    const calls = [_]TestingCall{
                        .{ .item_id = "send", .name = name, .encoded_call_id = "send", .decoded_call_id = "send", .encoded_arguments = encoded, .decoded_arguments = arguments },
                        .{ .item_id = "missing", .name = name, .encoded_call_id = "missing", .decoded_call_id = "missing", .encoded_arguments = encoded, .decoded_arguments = arguments },
                    };
                    try settleCallsForTesting(&storage, &tmp, model, "writer-core-calls", &calls);
                    action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                    key = try std.fmt.bufPrint(&key_buffer, "rui.core/{s}/{d}", .{ name, action.binding.action_id });
                }
                const sender_position = try store_testing.queryU64(&storage, "SELECT next_position FROM session WHERE session_ref=?1", .{sender.slice()});
                var wake: std.Io.Event = .unset;
                storage.commitWake().store(&wake, .release);
                defer storage.commitWake().store(null, .release);
                var commits: TestingCommits = .{};
                switch (source) {
                    .peer => {
                        const file = try tmp.dir.createFile(std.testing.io, "peer-content", .{ .read = true });
                        try file.writeStreamingAll(std.testing.io, text);
                        try file.sync(std.testing.io);
                        var command = try completeMessage(key, receiver.slice(), file, text);
                        defer command.removeTemporaryContent(std.testing.io) catch unreachable;
                        command.sender = .{ .store = storage.selector, .session = sender };
                        command.sender_handle = peer.sender_handle;
                        try std.testing.expect(storage.submitMessageWithModel(&command, commits.callback(), .{}) == .accepted);
                    },
                    .message_agent => try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(action.binding, receiver.slice(), text, .{})),
                    .start_agent => {
                        var spec = try testingAgentSpec(&.{"message_agent"}, "bypass");
                        try std.testing.expectEqual(command_domain.AgentStart.started, try storage.startAgent(action.binding, sender.slice(), text, true, &spec, commits.callback(), .{}));
                        const sent = try store_core.activityPageForTesting(&storage, .{ .session = sender, .kinds = .initOne(.sent) });
                        receiver = sent.items[0].value.sent.target.session;
                    },
                    .ending => try std.testing.expect(try storage.deliverChildEnding(model.turn_id, .{})),
                }
                try std.testing.expect(wake.isSet());
                if (source == .peer or source == .start_agent) {
                    try std.testing.expectEqual(@as(usize, 1), commits.count);
                    try std.testing.expect(commits.calls[0].from_peer);
                    try std.testing.expectEqualStrings(receiver.slice(), commits.calls[0].session.slice());
                }
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission m JOIN content c ON c.content_id=m.content_id WHERE m.command_key=?1 AND m.session_ref=?2 AND m.sender_session_ref=?3 AND m.sender_position=?4 AND c.digest=?5", .{ key, receiver.slice(), sender.slice(), sender_position, store_testing.Blob{ .bytes = &protocol.contentDigest(text) } }));
                const content_id = try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE command_key=?1", .{key});
                try expectContent(&storage, try testingContentReference(&storage, content_id), text);
                try std.testing.expectEqual(try store_testing.queryU64(&storage, "SELECT next_position-1 FROM session WHERE session_ref=?1", .{receiver.slice()}), try store_testing.queryU64(&storage, "SELECT admission_position FROM message_admission WHERE command_key=?1", .{key}));
                if (source == .peer) {
                    const file = try tmp.dir.createFile(std.testing.io, "missing-content", .{ .read = true });
                    try file.writeStreamingAll(std.testing.io, text);
                    try file.sync(std.testing.io);
                    var missing = try completeMessage("writer-missing", "zzzzzz", file, text);
                    defer missing.removeTemporaryContent(std.testing.io) catch unreachable;
                    missing.sender = .{ .store = storage.selector, .session = sender };
                    missing.sender_handle = peer.sender_handle;
                    try std.testing.expectEqual(protocol.MessageRejection.unknown_session, storage.submitMessageWithModel(&missing, null, .{}).rejected.code);
                } else if (source == .message_agent) {
                    const missing = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                    try std.testing.expectEqual(command_domain.AgentDelivery.failed, try storage.deliverAgentMessage(missing.binding, "zzzzzz", text, .{}));
                }
            }
        }
    }.run);
}

test "core call writes roll back on injected faults and save every bound skill" {
    try store_testing.forEachEngine(struct {
        fn reopen(case: *store_testing.Case, storage: *Store, tmp: *std.testing.TmpDir, opened: *bool) !void {
            try storage.close();
            opened.* = false;
            try store_testing.testingStore(case, storage, tmp, std.testing.io);
            opened.* = true;
        }

        fn expectSkills(storage: *Store, session: []const u8, comptime names: []const []const u8) !void {
            try std.testing.expectEqual(@as(u64, names.len), try store_testing.queryU64(storage, "SELECT count(*) FROM message_skill k JOIN message_admission m ON m.admission_id=k.admission_id WHERE m.session_ref=?1", .{session}));
            inline for (names, 1..) |name, position| {
                const content_id = try store_testing.queryU64(storage, "SELECT k.content_id FROM message_skill k JOIN message_admission m ON m.admission_id=k.admission_id WHERE m.session_ref=?1 AND k.position=?2 AND k.name=?3", .{ session, @as(u64, position), name });
                try expectContent(storage, try testingContentReference(storage, content_id), name ++ " body");
            }
        }

        fn stop(storage: *Store, key: []const u8, session: []const u8) !void {
            var command = try completeSessionStop(key, session);
            try std.testing.expect(storage.stopSession(&command, .{}) == .accepted);
        }

        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) {
                storage.close() catch unreachable;
            };
            var path: [protocol.max_workspace_bytes]u8 = undefined;
            var create = try completeConfiguration("faults-sender", "", try canonicalCwd(std.testing.io, &path), "model-a");
            create.configuration.tools = try .of(&.{"message_agent"});
            create.configuration.permission_mode.state = .value;
            try create.configuration.permission_mode.value.set("bypass");
            const sender = (try storage.configure(&create, .{})).accepted.session;
            const receiver = try configureTestSession(&storage, "faults-receiver");
            const root = try configureTestSession(&storage, "faults-root");
            try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), sender.slice() });
            try submitTestMessage(&storage, &tmp, "faults-task", "faults-task", sender.slice(), "send");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var arguments_buffer: [128]u8 = undefined;
            const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"hello\"}}", .{receiver.slice()});
            var encoded_buffer: [192]u8 = undefined;
            const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hello\\\"}}", .{receiver.slice()});
            var calls: [5]TestingCall = undefined;
            for (&calls, [_][]const u8{ "send", "fail", "succeed", "taken", "owed" }) |*call, name| call.* = .{ .item_id = name, .name = "message_agent", .encoded_call_id = name, .decoded_call_id = name, .encoded_arguments = encoded, .decoded_arguments = arguments };
            try settleCallsForTesting(&storage, &tmp, model, "faults-calls", &calls);
            const injected = [_]struct { Faults, anyerror }{
                .{ .{ .content_import = true }, error.InjectedContentImportFailure },
                .{ .{ .before_commit = true }, error.InjectedCommitFailure },
            };

            const bound: skills_fixture_domain.MessageCapture = .{ .bound = &.{ .{ .name = "first", .bytes = "first body" }, .{ .name = "second", .bytes = "second body" } } };
            for (injected) |fault| for ([_]?*const skills_fixture_domain.MessageCapture{ null, &bound }) |captured| {
                const send = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                try std.testing.expectError(fault[1], storage.deliverAgentMessageBound(send.binding, receiver.slice(), "hello", captured, fault[0]));
                try reopen(case, &storage, &tmp, &opened);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{receiver.slice()}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_skill", .{}));
                try std.testing.expectEqual(send.binding.action_id, (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action.binding.action_id);
            };
            const send = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessageBound(send.binding, receiver.slice(), "hello", &bound, .{}));
            try expectSkills(&storage, receiver.slice(), &.{ "first", "second" });

            const Resolution = struct { code: []const u8, result: []const u8 };
            inline for (.{ Resolution{ .code = "failed", .result = "the call failed" }, Resolution{ .code = "succeeded", .result = "the call succeeded" } }) |expected| {
                const resolve = if (comptime std.mem.eql(u8, expected.code, "failed")) Store.failCoreCall else Store.succeedCoreCall;
                const call = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                for (injected) |fault| {
                    try std.testing.expectError(fault[1], resolve(&storage, call.binding, expected.result, fault[0]));
                    try reopen(case, &storage, &tmp, &opened);
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{call.binding.action_id}));
                }
                try std.testing.expect(try resolve(&storage, call.binding, expected.result, .{}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ call.binding.action_id, expected.code }));
                const result_id = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{call.binding.action_id});
                try expectContent(&storage, try testingContentReference(&storage, result_id), expected.result);
            }

            const taken = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            var key_buffer: [128]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buffer, "rui.core/message_agent/{d}", .{taken.binding.action_id});
            try store_testing.exec(&storage, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES(?1,2,?2,?3,1,'',0,0,1000000)", .{ key, receiver.slice(), store_testing.Blob{ .bytes = &protocol.contentDigest("taken") } });
            try std.testing.expectEqual(command_domain.AgentDelivery.failed, try storage.deliverAgentMessage(taken.binding, receiver.slice(), "hello", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{receiver.slice()}));
            const taken_id = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1 AND resolution_code='failed'", .{taken.binding.action_id});
            try expectContent(&storage, try testingContentReference(&storage, taken_id), "Rui could not send this Message: its command key is already taken. Nothing was sent.");

            const owed = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            try stop(&storage, "faults-root-stop", root.slice());
            try std.testing.expect(!try storage.failCoreCall(owed.binding, "too late", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{owed.binding.action_id}));

            try stop(&storage, "faults-sender-stop", sender.slice());
            try stop(&storage, "faults-receiver-stop", receiver.slice());
            const parent = try configureTestSession(&storage, "faults-parent");
            var endings: [2]u64 = undefined;
            inline for (.{ "faults-child", "faults-other-child" }) |name| {
                const child = try configureTestSession(&storage, name);
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
                try submitTestMessage(&storage, &tmp, name ++ "-task", name ++ "-task", child.slice(), "answer");
            }
            for (&endings) |*ending| {
                const child_model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleItemsForTesting(&storage, &tmp, child_model, &.{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"saved answer\"}]}"}, "saved answer");
                ending.* = child_model.turn_id;
            }
            const ending_bound: skills_fixture_domain.MessageCapture = .{ .bound = &.{ .{ .name = "third", .bytes = "third body" }, .{ .name = "fourth", .bytes = "fourth body" } } };
            for (injected) |fault| for ([_]?*const skills_fixture_domain.MessageCapture{ null, &ending_bound }) |captured| {
                try std.testing.expectError(fault[1], storage.deliverChildEndingBound(endings[0], captured, fault[0]));
                try reopen(case, &storage, &tmp, &opened);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
            };
            try std.testing.expect(try storage.deliverChildEndingBound(endings[0], &ending_bound, .{}));
            try expectSkills(&storage, parent.slice(), &.{ "third", "fourth" });
            try std.testing.expect(!try storage.deliverChildEndingBound(endings[0], &ending_bound, .{}));

            var archive: protocol.SessionArchiveCommand = .{ .session = parent, .archived = true };
            try archive.key.set("faults-parent-archive");
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try store_testing.exec(&storage, "UPDATE session_forward SET suppress_message=0 WHERE source_id=?1 AND kind=2", .{endings[1]});
            try std.testing.expect(try storage.deliverChildEnding(endings[1], .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT message_delivered FROM session_forward WHERE source_id=?1 AND kind=2", .{endings[1]}));
        }
    }.run);
}

test "child ending Message includes bounded provider report done answer and quiet parent stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Ending = enum { failed, provider_refused, done, stopped, quiet };
            inline for (std.enums.values(Ending)) |ending| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const parent = try configureTestSession(&storage, "report-parent");
                const child = try configureTestSession(&storage, "report-child");
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
                try submitTestMessage(&storage, &tmp, "report-task", "report-task", child.slice(), "answer");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const report: [protocol.max_report_bytes]u8 = @splat('r');
                if (ending == .done) {
                    try settleItemsForTesting(&storage, &tmp, model, &.{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"saved answer\"}]}"}, "saved answer");
                } else if (ending == .stopped) {
                    var stop = try completeSessionStop("report-child-stop", child.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                } else if (ending == .quiet) {
                    var stop = try completeSessionStop("report-parent-stop", parent.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    const owed = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.stop;
                    var child_stop: protocol.SessionStopCommand = .{ .key = owed.key, .session = child };
                    try std.testing.expect(storage.stopOwedSession(&child_stop, .{}) == .accepted);
                } else {
                    try storage.settleModelAttemptFailure(model, .{ .correlated = .{ .code = if (ending == .failed) "malformed_provider_output" else "provider_http_400", .request_id = .{}, .report = &report } }, .ordinary, .{});
                }
                try std.testing.expect(try storage.deliverChildEnding(model.turn_id, .{}));
                try std.testing.expect(!try storage.deliverChildEnding(model.turn_id, .{}));
                const count = try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()});
                try std.testing.expectEqual(@as(u64, if (ending == .quiet) 0 else 1), count);
                if (ending != .quiet) {
                    const content_id = try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE session_ref=?1", .{parent.slice()});
                    if (ending == .done) {
                        try expectContent(&storage, try testingContentReference(&storage, content_id), "saved answer");
                        try std.testing.expectEqual(content_id, try store_testing.queryU64(&storage, "SELECT outcome_content_id FROM turn WHERE turn_id=?1", .{model.turn_id}));
                    } else {
                        var expected: [96 + protocol.max_report_bytes]u8 = undefined;
                        const text = try std.fmt.bufPrint(&expected, "[Rui: this agent's Turn ended without an answer: {s}.]{s}{s}", .{ @tagName(ending), if (ending == .stopped) "" else "\n", if (ending == .stopped) "" else &report });
                        var reader: ContentReader = undefined;
                        reader.open(try storage.openContent(try testingContentReference(&storage, content_id)));
                        defer reader.close();
                        var actual: [96 + protocol.max_report_bytes]u8 = undefined;
                        const length = try reader.read(0, &actual);
                        try std.testing.expectEqualStrings(text, actual[0..length]);
                        try std.testing.expectEqual(@as(usize, 0), try reader.read(length, &actual));
                    }
                }
            }
        }
    }.run);
}

test "child ending forward is the single durable owed fact across recovery for every ending" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Ending = enum { done, failed, stopped, quiet, root };
            inline for (std.enums.values(Ending)) |ending| {
                errdefer std.debug.print("ending case {s} failed\n", .{@tagName(ending)});
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) {
                    storage.close() catch unreachable;
                };
                const ancestor = try configureTestSession(&storage, "once-ancestor");
                const parent = try configureTestSession(&storage, "once-parent");
                const child = try configureTestSession(&storage, "once-child");
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ ancestor.slice(), parent.slice() });
                if (ending != .root) try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
                try submitTestMessage(&storage, &tmp, "once-task", "once-task", child.slice(), "answer");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (ending == .done or ending == .root) {
                    try settleItemsForTesting(&storage, &tmp, model, &.{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"saved answer\"}]}"}, "saved answer");
                } else if (ending == .failed) {
                    const report = "saved failure";
                    try storage.settleModelAttemptFailure(model, .{ .correlated = .{ .code = "malformed_provider_output", .request_id = .{}, .report = report } }, .ordinary, .{});
                } else {
                    var stop = try completeSessionStop("once-stop", if (ending == .quiet) parent.slice() else child.slice());
                    try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    if (ending == .quiet) {
                        const owed = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.stop;
                        var child_stop: protocol.SessionStopCommand = .{ .key = owed.key, .session = child };
                        try std.testing.expect(storage.stopOwedSession(&child_stop, .{}) == .accepted);
                    }
                }
                try std.testing.expectEqual(@as(u64, if (ending == .root) 0 else 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_forward WHERE source_id=?1 AND kind=2 AND message_delivered=0 AND position IS NULL", .{model.turn_id}));
                try storage.close();
                opened = false;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                if (ending == .root) {
                    try std.testing.expect(!try storage.deliverChildEnding(model.turn_id, .{}));
                    try std.testing.expect((try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })) == null);
                    continue;
                }
                const first = try store_testing.queryU64(&storage, "SELECT forward_id FROM session_forward WHERE source_id=?1 AND target_ref=?2", .{ model.turn_id, parent.slice() });
                try std.testing.expect(try storage.deliverSessionForward(first, .{}));
                try std.testing.expectError(error.InjectedCommitFailure, storage.deliverChildEnding(model.turn_id, .{ .before_commit = true }));
                try storage.close();
                opened = false;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
                try std.testing.expect(try storage.deliverChildEnding(model.turn_id, .{}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT message_delivered FROM session_forward WHERE forward_id=?1", .{first}));
                try storage.close();
                opened = false;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                try std.testing.expect(!try storage.deliverChildEnding(model.turn_id, .{}));
                try std.testing.expectEqual(@as(u64, if (ending == .quiet) 0 else 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
                const hop = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.forward;
                try std.testing.expect(try storage.deliverSessionForward(hop, .{}));
                try std.testing.expect(!try storage.deliverSessionForward(hop, .{}));
                try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_forward WHERE source_id=?1 AND position IS NOT NULL", .{model.turn_id}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_forward WHERE source_id=?1 AND message_delivered IS NOT NULL", .{model.turn_id}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{ancestor.slice()}));
                try std.testing.expect((try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })) == null);
            }
        }
    }.run);
}

test "ending migration preserves unsettled and settled Messages exactly once with the new digest" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            inline for (.{ false, true }) |keep_pending_forward| {
                inline for (.{ false, true }) |suppress_message| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    var opened = true;
                    defer if (opened) {
                        storage.close() catch unreachable;
                    };
                    const parent = try configureTestSession(&storage, "upgrade-parent");
                    const child = try configureTestSession(&storage, "upgrade-child");
                    try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ parent.slice(), child.slice() });
                    var turns: [2]u64 = undefined;
                    inline for (0..2) |index| {
                        const key = if (index == 0) "upgrade-settled" else "upgrade-unsettled";
                        try submitTestMessage(&storage, &tmp, key, key, child.slice(), "answer");
                        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        turns[index] = model.turn_id;
                        try settleItemsForTesting(&storage, &tmp, model, &.{"{\"type\":\"message\",\"id\":\"answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"saved answer\"}]}"}, "saved answer");
                    }
                    try std.testing.expect(try storage.deliverChildEnding(turns[0], .{}));
                    if (suppress_message) try store_testing.exec(&storage, "UPDATE session_forward SET suppress_message=1 WHERE source_id=?1 AND message_delivered=0", .{turns[1]});
                    try store_testing.stageEndingMessageUpgrade(&storage, keep_pending_forward);
                    try storage.close();
                    opened = false;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    opened = true;
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT message_delivered FROM session_forward WHERE source_id=?1 AND message_delivered IS NOT NULL", .{turns[0]}));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT message_delivered FROM session_forward WHERE source_id=?1 AND message_delivered IS NOT NULL", .{turns[1]}));
                    try std.testing.expectEqual(@as(u64, @intFromBool(suppress_message)), try store_testing.queryU64(&storage, "SELECT suppress_message FROM session_forward WHERE source_id=?1 AND message_delivered=0", .{turns[1]}));
                    try std.testing.expect(!try storage.deliverChildEnding(turns[0], .{}));
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
                    try std.testing.expect(try storage.deliverChildEnding(turns[1], .{}));
                    try storage.close();
                    opened = false;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    opened = true;
                    try std.testing.expect(!try storage.deliverChildEnding(turns[0], .{}));
                    try std.testing.expect(!try storage.deliverChildEnding(turns[1], .{}));
                    try std.testing.expectEqual(@as(u64, if (suppress_message) 1 else 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{parent.slice()}));
                }
            }
        }
    }.run);
}

test "configure parent inherits binding without a task, uses the create round budget and delivers child endings" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var parent_spec = try completeConfiguration("parent-create-owner", "", workspace, "model-a");
            parent_spec.configuration.tools = try .of(&.{ "bash", "start_agent" });
            const parent = (try storage.configure(&parent_spec, .{})).accepted.session;
            var child: wire_request.ConfigureCommand = .{};
            try child.key.set("parent-create-child");
            child.configuration = try testingAgentSpec(&.{"bash"}, "ask");
            child.configuration.parent.state = .value;
            try child.configuration.parent.value.set(parent.slice());
            var meter: RoundMeter = .{ .storage = &storage };
            // COM_QUERY counts belong to one connection; replay reconnects reset them.
            // Measure only the ordinary path whose budget is asserted below.
            if (!case.rerun) meter.start();
            const reconnects_before = if (case.rerun) storage.engine.mysql.state.testing_shape.reconnects else 0;
            const result = try storage.configure(&child, .{});
            try std.testing.expect(result == .accepted);
            if (!case.rerun) {
                meter.stop(.configure);
                const measured = meter.measured.get(.configure).?;
                try std.testing.expectEqual(round_budgets.get(.configure), measured.rounds);
                if (case.engine == .mysql) try std.testing.expectEqual(measured.shape.expected(), measured.shape.queries);
            } else {
                try std.testing.expect(storage.engine.mysql.state.testing_shape.reconnects > reconnects_before);
            }
            const session = result.accepted.session;
            const configured = try storage.inspectSessionForTesting(session.slice());
            try expectToolSetNames(&storage, configured.tool_set_id, &.{"bash"});
            try std.testing.expectEqualStrings("ask", configured.permission_mode.slice());
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND parent_ref=?2 AND workspace=?3 AND provider='codex'", .{ session.slice(), parent.slice(), workspace }));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1", .{session.slice()}));
            const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 128 * 1024, .current);
            defer std.testing.allocator.free(report);
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings(parent.slice(), parsed.value.object.get("session").?.object.get("parent").?.string);
            const replay = try storage.configure(&child, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqualStrings(session.slice(), replay.accepted.session.slice());
            try child.configuration.parent.value.set("zzzzzz");
            try std.testing.expect(try storage.configure(&child, .{}) == .conflict);
            try submitTestMessage(&storage, &tmp, "native-child-task", "native-child-task", session.slice(), "answer");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            {
                var view: TestingPage = undefined;
                view.open(&storage, model);
                defer view.close();
                var settings: HistoricalSettings = undefined;
                try view.settings(&settings);
                try std.testing.expect(settings.parent != null);
                try std.testing.expectEqualStrings(parent.slice(), settings.parent.?.slice());
            }
            const item = "{\"type\":\"message\",\"id\":\"native-child-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}";
            try settleItemsForTesting(&storage, &tmp, model, &.{item}, "hello");
            const ending = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.ending;
            try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission WHERE session_ref=?1 AND sender_session_ref=?2", .{ parent.slice(), session.slice() }));
        }
    }.run);
}

test "configure parent refuses every widening field, missing or ended parents and parent on update" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("parent-refuse-owner", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{"start_agent"});
            try create.configuration.permission_mode.value.set("ask");
            const parent = (try storage.configure(&create, .{})).accepted.session;
            const Case = enum { tools, permission, provider, workspace, missing, update, ended };
            for (std.enums.values(Case), 0..) |variant, index| {
                var child: wire_request.ConfigureCommand = .{};
                var key_buffer: [64]u8 = undefined;
                try child.key.set(try std.fmt.bufPrint(&key_buffer, "parent-refuse-{d}", .{index}));
                child.configuration = try testingAgentSpec(&.{}, "ask");
                child.configuration.parent.state = .value;
                try child.configuration.parent.value.set(parent.slice());
                const expected: protocol.ConfigurationRejection = switch (variant) {
                    .tools => refusal: {
                        child.configuration.tools = try .of(&.{"bash"});
                        break :refusal .tools_not_in_parent;
                    },
                    .permission => refusal: {
                        try child.configuration.permission_mode.value.set("bypass");
                        break :refusal .permission_mode_wider_than_parent;
                    },
                    .provider => refusal: {
                        child.configuration.provider.state = .value;
                        try child.configuration.provider.value.set("codex");
                        break :refusal .parent_provider_forbidden;
                    },
                    .workspace => refusal: {
                        child.configuration.workspace.state = .value;
                        try child.configuration.workspace.value.set(workspace);
                        break :refusal .parent_workspace_forbidden;
                    },
                    .missing => refusal: {
                        try child.configuration.parent.value.set("zzzzzz");
                        break :refusal .unknown_session;
                    },
                    .update => refusal: {
                        child.session = parent;
                        break :refusal .parent_on_update;
                    },
                    .ended => refusal: {
                        var archive: protocol.SessionArchiveCommand = .{ .archived = true };
                        try archive.key.set("parent-ended");
                        try archive.session.set(parent.slice());
                        try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
                        break :refusal .unknown_session;
                    },
                };
                const result = try storage.configure(&child, .{});
                try std.testing.expect(result == .rejected);
                try std.testing.expectEqual(expected, result.rejected.code);
                const replay = try storage.configure(&child, .{});
                try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                try std.testing.expectEqual(expected, replay.rejected.code);
                if (variant == .tools or variant == .permission or variant == .provider or variant == .workspace) {
                    const outcome = try storage.commandResult(child.key.slice());
                    try std.testing.expect(outcome.length > 0);
                }
            }
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1", .{parent.slice()}));
        }
    }.run);
}

test "received and sent Activity reject disagreement with their accepted Message source" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Damage = enum { kind, accepted, target, content, missing_content, missing_command };
            inline for (.{ false, true }) |sent| {
                inline for (std.enums.values(Damage)) |damage| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    var path: [protocol.max_workspace_bytes]u8 = undefined;
                    var create = try completeConfiguration("source-check-sender", "", try canonicalCwd(std.testing.io, &path), "model-a");
                    create.configuration.tools = try .of(&.{"message_agent"});
                    create.configuration.permission_mode.state = .value;
                    try create.configuration.permission_mode.value.set("bypass");
                    const sender = (try storage.configure(&create, .{})).accepted.session;
                    const receiver = try configureTestSession(&storage, "source-check-receiver");
                    try submitTestMessage(&storage, &tmp, "source-check-task", "source-check-task", sender.slice(), "send");
                    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    var arguments_buffer: [128]u8 = undefined;
                    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"hello\"}}", .{receiver.slice()});
                    var encoded_buffer: [192]u8 = undefined;
                    const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hello\\\"}}", .{receiver.slice()});
                    try settleCallsForTesting(&storage, &tmp, model, "source-check-call", &.{.{ .item_id = "send", .name = "message_agent", .encoded_call_id = "send", .decoded_call_id = "send", .encoded_arguments = encoded, .decoded_arguments = arguments }});
                    const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                    const original = "\xef\xbb\xbfexact\x00peer";
                    try std.testing.expectEqual(command_domain.AgentDelivery.delivered, try storage.deliverAgentMessage(action.binding, receiver.slice(), original, .{}));
                    const request: protocol.ActivityPage = .{ .session = if (sent) sender else receiver, .kinds = if (sent) .initOne(.sent) else .initOne(.received) };
                    const page = try store_core.activityPageForTesting(&storage, request);
                    try std.testing.expectEqual(@as(usize, 1), page.count);
                    const id = try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE session_ref=?1", .{receiver.slice()});
                    try expectContent(&storage, try testingContentReference(&storage, id), original);
                    try std.testing.expect(!storage.isFenced());
                    switch (damage) {
                        .kind => try store_testing.exec(&storage, "UPDATE core_command SET kind=1 WHERE command_key=(SELECT command_key FROM message_admission WHERE session_ref=?1)", .{receiver.slice()}),
                        .accepted => try store_testing.exec(&storage, "UPDATE core_command SET accepted=0 WHERE command_key=(SELECT command_key FROM message_admission WHERE session_ref=?1)", .{receiver.slice()}),
                        .target => try store_testing.exec(&storage, "UPDATE core_command SET target=?1 WHERE command_key=(SELECT command_key FROM message_admission WHERE session_ref=?2)", .{ sender.slice(), receiver.slice() }),
                        .content => try store_testing.exec(&storage, "UPDATE core_command SET primary_content_id=(SELECT content_id FROM message_admission WHERE command_key='source-check-task') WHERE command_key=(SELECT command_key FROM message_admission WHERE session_ref=?1)", .{receiver.slice()}),
                        .missing_content => try store_testing.exec(&storage, "UPDATE core_command SET primary_content_id=NULL WHERE command_key=(SELECT command_key FROM message_admission WHERE session_ref=?1)", .{receiver.slice()}),
                        .missing_command => try store_testing.withoutForeignKeys(&storage, "DELETE FROM core_command WHERE command_key=(SELECT command_key FROM message_admission WHERE session_ref=?1)", .{receiver.slice()}),
                    }
                    try std.testing.expectError(error.CorruptStore, store_core.activityPageForTesting(&storage, request));
                    try std.testing.expect(storage.isFenced());
                }
            }
        }
    }.run);
}

test "parent authority refuses omitted defaults across Configure Message and start_agent and preserves refused replay" {
    try store_testing.forEachEngine(struct {
        const Surface = enum { configure, message, start_agent };

        fn widen(storage: *Store, parent: protocol.Bounded(protocol.max_session_bytes)) !void {
            var patch: wire_request.ConfigureCommand = .{ .session = parent };
            try patch.key.set("default-parent-widen");
            patch.configuration.tools.state = .value;
            for (tool_defs.built_in_tool_set.records) |record| try patch.configuration.tools.insert(record.name);
            patch.configuration.loaded_tools = patch.configuration.tools;
            patch.configuration.permission_mode.state = .value;
            try patch.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
        }

        fn run(case: *store_testing.Case) !void {
            for (std.enums.values(Surface)) |surface| for ([_]bool{ false, true }) |permission_only| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var create = try completeConfiguration("default-parent", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                create.configuration.tools = try .of(&.{"start_agent"});
                try create.configuration.permission_mode.value.set("ask");
                const parent = (try storage.configure(&create, .{})).accepted.session;
                const expected: protocol.ConfigurationRejection = if (permission_only) .permission_mode_wider_than_parent else .tools_not_in_parent;
                var child: wire_request.ConfigureCommand = .{};
                try child.key.set("default-child");
                if (permission_only) child.configuration.tools = try .of(&.{});
                if (surface == .start_agent) {
                    try submitTestMessage(&storage, &tmp, "default-parent-message", "default-parent-message", parent.slice(), "start agents");
                    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCallsForTesting(&storage, &tmp, model, "default-parent-calls", &.{
                        .{ .item_id = "default-item-one", .name = "start_agent", .encoded_call_id = "default-call-one", .decoded_call_id = "default-call-one", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                        .{ .item_id = "default-item-two", .name = "start_agent", .encoded_call_id = "default-call-two", .decoded_call_id = "default-call-two", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                    });
                    const first = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                    try std.testing.expect(try storage.startAgent(first.binding, parent.slice(), "read", true, &child.configuration, null, .{}) == .failed);
                    const reason = if (permission_only)
                        "spec.permissionMode: you ask before running commands, so your agents ask too. Nothing was started."
                    else
                        "spec.tools: bash is not one of your tools. Nothing was started.";
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ first.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(reason) } }));
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1", .{parent.slice()}));
                    try widen(&storage, parent);
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ first.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(reason) } }));
                    const second = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                    try std.testing.expect(try storage.startAgent(second.binding, parent.slice(), "read", true, &child.configuration, null, .{}) == .started);
                } else {
                    child.configuration.parent.state = .value;
                    try child.configuration.parent.value.set(parent.slice());
                    if (surface == .configure) {
                        const refused = try storage.configure(&child, .{});
                        try std.testing.expect(refused == .rejected);
                        try std.testing.expectEqual(expected, refused.rejected.code);
                        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1", .{parent.slice()}));
                        try widen(&storage, parent);
                        const replay = try storage.configure(&child, .{});
                        try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                        try std.testing.expectEqual(expected, replay.rejected.code);
                        try child.key.set("default-child-fresh");
                        try std.testing.expect(try storage.configure(&child, .{}) == .accepted);
                    } else {
                        const text = "child task";
                        const file = try tmp.dir.createFile(std.testing.io, "default-child-message", .{ .read = true });
                        try file.writeStreamingAll(std.testing.io, text);
                        try file.sync(std.testing.io);
                        var message = try completeMessage("default-child", "", file, text);
                        defer message.removeTemporaryContent(std.testing.io) catch unreachable;
                        message.configuration = child.configuration;
                        const refused = storage.submitMessageWithModel(&message, null, .{});
                        try std.testing.expect(refused == .rejected);
                        try std.testing.expectEqualStrings(@tagName(expected), @tagName(refused.rejected.code));
                        try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1", .{parent.slice()}));
                        try widen(&storage, parent);
                        const replay = storage.submitMessageWithModel(&message, null, .{});
                        try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                        try std.testing.expectEqualStrings(@tagName(expected), @tagName(replay.rejected.code));
                        try message.key.set("default-child-fresh");
                        try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
                    }
                }
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1", .{parent.slice()}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE parent_ref=?1 AND model=?2", .{ parent.slice(), @import("../../product_defaults.zig").recommended_model }));
            };
        }
    }.run);
}
