const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const connection = @import("../../connection.zig");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const tool_set_domain = @import("../domain/tool_set.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const configuration_domain = @import("../domain/configuration.zig");
const configuration_admission = @import("../../configuration_admission.zig");
const content_domain = @import("../domain/content.zig");
const store_testing = @import("../testing.zig");
const ConfigurationContentAction = configuration_domain.ConfigurationContentAction;
const ConfigurationUpdatePlan = configuration_domain.ConfigurationUpdatePlan;
const ContentReader = content_domain.ContentReader;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const expectToolSetNames = shared_fixtures.expectToolSetNames;
const testingBytesContent = shared_fixtures.testingBytesContent;
const testingContent = shared_fixtures.testingContent;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const testingSessionReport = shared_fixtures.testingSessionReport;

const served_builtins = @import("../../protocol.zig").servedBuiltIns(.endpoint);

test "a configure whose instructions and output schema are the same new bytes imports one row and verifies both files" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const rows = store_testing.content_beside_tools;

            const create_bytes = "{\"title\":\"same-create\"}";
            var create = try completeConfiguration("same-create", "", workspace, "model-a");
            create.configuration.instructions = try testingBytesContent(&tmp, "same-create-instructions", create_bytes);
            create.configuration.output_schema = try testingBytesContent(&tmp, "same-create-schema", create_bytes);
            defer create.removeTemporaryContent(std.testing.io) catch unreachable;
            const before_create = try store_testing.queryU64(&storage, rows, .{});
            const created = try storage.configure(&create, .{});
            try std.testing.expect(created == .accepted);
            try std.testing.expectEqual(before_create + 1, try store_testing.queryU64(&storage, rows, .{}));
            const session = created.accepted.session;
            const after_create = (try store_core.readSessionForTesting(&storage, session.slice())).?;
            try std.testing.expectEqual(after_create.instructions_id.?, after_create.output_schema_id.?);

            const update_bytes = "{\"title\":\"same-update\"}";
            var update = try completeConfiguration("same-update", session.slice(), workspace, "model-a");
            update.configuration.instructions = try testingBytesContent(&tmp, "same-update-instructions", update_bytes);
            update.configuration.output_schema = try testingBytesContent(&tmp, "same-update-schema", update_bytes);
            defer update.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(before_create + 2, try store_testing.queryU64(&storage, rows, .{}));
            const after_update = (try store_core.readSessionForTesting(&storage, session.slice())).?;
            try std.testing.expectEqual(after_update.instructions_id.?, after_update.output_schema_id.?);
            try std.testing.expect(after_update.instructions_id.? != after_create.instructions_id.?);

            const claimed = "{\"title\":\"same-claim\"}";
            var forged = try completeConfiguration("same-forged", session.slice(), workspace, "model-a");
            forged.configuration.instructions = try testingBytesContent(&tmp, "same-forged-instructions", claimed);
            forged.configuration.output_schema = try testingBytesContent(&tmp, "same-forged-schema", "{\"title\":\"same-other\"}");
            forged.configuration.output_schema.digest = forged.configuration.instructions.digest;
            defer forged.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(try storage.configure(&forged, .{}) != .accepted);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key='same-forged'", .{}));
            try std.testing.expectEqual(before_create + 2, try store_testing.queryU64(&storage, rows, .{}));
        }
    }.run);
}

test "configuration pre-Workspace decisions allow model revisions" {
    const Case = struct {
        name: []const u8,
        has_current: bool,
        workspace_requested: bool,
        provider_requested: ?[]const u8,
        model_requested: ?[]const u8,
        expected: ?protocol.ConfigurationRejection,
    };
    const cases = [_]Case{
        .{
            .name = "new request uses Host provider",
            .has_current = false,
            .workspace_requested = true,
            .provider_requested = null,
            .model_requested = "model-a",
            .expected = null,
        },
        .{
            .name = "new complete request",
            .has_current = false,
            .workspace_requested = true,
            .provider_requested = "codex",
            .model_requested = "model-a",
            .expected = null,
        },
        .{
            .name = "different model is accepted",
            .has_current = true,
            .workspace_requested = true,
            .provider_requested = "codex",
            .model_requested = "model-b",
            .expected = null,
        },
        .{
            .name = "same binding is accepted",
            .has_current = true,
            .workspace_requested = false,
            .provider_requested = "codex",
            .model_requested = "model-a",
            .expected = null,
        },
        .{
            .name = "omitted binding is accepted",
            .has_current = true,
            .workspace_requested = false,
            .provider_requested = null,
            .model_requested = null,
            .expected = null,
        },
    };

    var existing: CurrentConfiguration = .{};
    try existing.workspace.set("/canonical/workspace");
    existing.provider = connection.Name.parse("codex").?;
    try existing.model.set("model-a");
    existing.instructions_id = 11;
    existing.revision = 1;
    for (cases) |case| {
        var requested: wire_request.Configuration = .{};
        if (!case.has_current) {
            requested.tools = try .of(&.{"bash"});
            requested.permission_mode.state = .value;
            try requested.permission_mode.value.set("bypass");
            requested.reasoning_effort.state = .explicit_null;
            requested.compaction_trigger.state = .value;
            try requested.compaction_trigger.value.set("115200");
        }
        if (case.workspace_requested) {
            requested.workspace.state = .value;
            try requested.workspace.value.set("relative-or-different-workspace");
        }
        if (case.model_requested) |model| {
            requested.model.state = .value;
            try requested.model.value.set(model);
        }
        if (case.provider_requested) |provider| {
            requested.provider.state = .value;
            try requested.provider.value.set(provider);
        }
        const current: ?*const CurrentConfiguration = if (case.has_current) &existing else null;
        std.testing.expectEqual(
            case.expected,
            configuration_domain.configurationBeforeWorkspace(@import("../../model_catalog.zig").shipped, current, &requested),
        ) catch |err| {
            std.debug.print("configuration pre-Workspace case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "configure refuses a tool name the tool set lacks and a provider tool its provider does not run" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // The Host set holds every built-in (a Store refuses a set without them) and one provider tool.
            const records = comptime testingHostToolRecords(&.{.{ .name = "code_interpreter", .owner = .provider }});
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: store_core.Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try storage.saveHostToolSet(&.{ .records = &records, .digests = &digests });
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const Case = struct { names: []const []const u8, expected: ?protocol.ConfigurationRejection };
            for ([_]Case{
                .{ .names = &.{ "bash", "web_search" }, .expected = null },
                .{ .names = &.{}, .expected = null },
                .{ .names = &.{"edit"}, .expected = .unknown_tool },
                .{ .names = &.{ "bash", "edit" }, .expected = .unknown_tool },
                .{ .names = &.{"code_interpreter"}, .expected = .provider_tool_missing },
            }, 0..) |tool_case, index| {
                var key_buffer: [32]u8 = undefined;
                var create = try store_testing.completeConfiguration(try std.fmt.bufPrint(&key_buffer, "tools-refusal-{d}", .{index}), "", workspace, "model-a");
                create.configuration.tools = try .of(tool_case.names);
                const reply = try storage.configure(&create, .{});
                if (tool_case.expected) |code| {
                    try std.testing.expectEqual(code, reply.rejected.code);
                } else {
                    try std.testing.expect(reply == .accepted);
                }
            }
        }
    }.run);
}

test "Store configuration requires Workspace and model and, on a Host serving several, a provider" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

            for (0..8) |mask| {
                var key_buffer: [32]u8 = undefined;
                var command = try completeConfiguration(
                    try std.fmt.bufPrint(&key_buffer, "presence-{d}", .{mask}),
                    "",
                    workspace,
                    "model-a",
                );
                if (mask & 1 == 0) command.configuration.workspace.state = .omitted;
                if (mask & 2 == 0) command.configuration.provider.state = .omitted;
                if (mask & 4 == 0) command.configuration.model.state = .omitted;
                const reply = try storage.configure(&command, .{});
                if (mask == 7) {
                    try std.testing.expect(reply == .accepted);
                } else {
                    // Every missing setting is named at once: model 1, Workspace 2, provider 4.
                    const expected: u3 = @as(u3, if (mask & 4 == 0) 1 else 0) | @as(u3, if (mask & 1 == 0) 2 else 0) | @as(u3, if (mask & 2 == 0) 4 else 0);
                    try std.testing.expect(reply == .rejected);
                    try std.testing.expectEqual(protocol.ConfigurationRejection.missing_settings, reply.rejected.code);
                    try std.testing.expectEqual(expected, reply.rejected.missing.?.bits);
                    try std.testing.expect(!(try storage.inspectSessionForTesting(command.session.slice())).found);
                    const replay = try storage.configure(&command, .{});
                    try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                    try std.testing.expectEqual(protocol.ConfigurationRejection.missing_settings, replay.rejected.code);
                    try std.testing.expectEqual(expected, replay.rejected.missing.?.bits);
                }
            }

            var initial = try completeConfiguration("binding-initial", "", workspace, "model-a");
            const initial_reply = try storage.configure(&initial, .{});
            try std.testing.expect(initial_reply == .accepted);
            const session = initial_reply.accepted.session;
            const observation = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqualStrings("codex", observation.provider.?.slice());
            try std.testing.expectEqualStrings("model-a", observation.model.slice());

            var equal: wire_request.ConfigureCommand = .{};
            try equal.key.set("binding-equal");
            equal.session = session;
            equal.configuration.provider.state = .value;
            try equal.configuration.provider.value.set("codex");
            equal.configuration.model.state = .value;
            try equal.configuration.model.value.set("model-a");
            try std.testing.expect(try storage.configure(&equal, .{}) == .accepted);

            var different = equal;
            try different.key.set("binding-different");
            different.configuration.model.value.len = 0;
            try different.configuration.model.value.set("model-a ");
            const changed = try storage.configure(&different, .{});
            try std.testing.expect(changed == .accepted);
            try std.testing.expectEqual(@as(u64, 3), changed.accepted.revision);
            try std.testing.expectEqualStrings("model-a ", (try storage.inspectSessionForTesting(session.slice())).model.slice());
            var changes: protocol.ActivityPage = .{ .kinds = .initOne(.session_changed) };
            changes.session = session;
            const activity = try store_core.activityPageForTesting(&storage, changes);
            try std.testing.expectEqual(@as(usize, 1), activity.count);
            try std.testing.expectEqual(protocol.SessionField.model, activity.items[0].value.session_changed.field);
            try std.testing.expectEqual(changed.accepted.revision, activity.items[0].value.session_changed.revision);
        }
    }.run);
}

test "a Session switches only to a served connection of its own wire format, over every pair of built-in names" {
    var served = protocol.servedBuiltIns(.endpoint);
    try served.put(.{ .name = connection.Name.parse("work").?, .label = .{}, .route = .key_file, .codec = .@"openai-responses/3", .web_search = true });
    const names = [_][]const u8{ "codex", "chatgpt", "openai", "work", "ghost" };
    for (names) |from| for (names) |to| {
        const from_codec = served.codecOf(from) orelse continue;
        var existing: CurrentConfiguration = .{};
        existing.provider = connection.Name.parse(from).?;
        existing.codec = from_codec;
        const expected: ?configuration_admission.Rejection = if (std.mem.eql(u8, from, to)) null else if (served.codecOf(to)) |codec|
            (if (codec == from_codec) null else .connection_wire_differs)
        else
            .connection_unserved;
        try std.testing.expectEqual(expected, configuration_domain.switchRejection(&existing, connection.Name.parse(to).?, &served));
    };
    // A Session whose connection is no longer served still switches, by the codec it saved.
    var gone: CurrentConfiguration = .{};
    gone.provider = connection.Name.parse("retired").?;
    gone.codec = .@"openai-responses/3";
    try std.testing.expectEqual(@as(?configuration_admission.Rejection, null), configuration_domain.switchRejection(&gone, connection.Name.parse("work").?, &served));
    // The one pair the contract is about: two accounts of one wire format switch freely.
    var chat: CurrentConfiguration = .{};
    chat.provider = connection.Name.parse("chatgpt").?;
    chat.codec = .@"openai-responses/3";
    try std.testing.expectEqual(@as(?configuration_admission.Rejection, null), configuration_domain.switchRejection(&chat, connection.Name.parse("work").?, &served));
}

test "a Session moves to another account of its wire format, records the change, and refuses another wire format" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var routes = protocol.servedBuiltIns(.endpoint);
            try routes.put(.{ .name = connection.Name.parse("work").?, .label = .{}, .route = .key_file, .codec = .@"openai-responses/3", .web_search = true });
            try routes.put(.{ .name = connection.Name.parse("plain").?, .label = .{}, .route = .key_file, .codec = .@"openai-responses/3", .web_search = false });
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = routes });
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("switch-initial", "", workspace, "model-a");
            initial.configuration.provider.state = .value;
            try initial.configuration.provider.value.set("chatgpt");
            const created = try storage.configure(&initial, .{});
            try std.testing.expect(created == .accepted);
            const session = created.accepted.session;
            const before = try storage.inspectSessionForTesting(session.slice());

            // The Session holds web_search, which a connection that does not run it cannot be offered: the
            // switch is refused whole whether the saved tools are kept or named again, and accepted once they leave it.
            var plain: wire_request.ConfigureCommand = .{};
            try plain.key.set("switch-to-plain");
            try plain.session.set(session.slice());
            plain.configuration.provider.state = .value;
            try plain.configuration.provider.value.set("plain");
            const kept_tools = try storage.configure(&plain, .{});
            try std.testing.expect(kept_tools == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.provider_tool_missing, kept_tools.rejected.code);
            try std.testing.expectEqual(before.revision, (try storage.inspectSessionForTesting(session.slice())).revision);
            var named: wire_request.ConfigureCommand = .{};
            try named.key.set("switch-to-plain-named");
            try named.session.set(session.slice());
            named.configuration.provider.state = .value;
            try named.configuration.provider.value.set("plain");
            named.configuration.tools.state = .value;
            named.configuration.tools.count = 0;
            named.configuration.tools.names.len = 0;
            try named.configuration.tools.insert("web_search");
            const named_tools = try storage.configure(&named, .{});
            try std.testing.expect(named_tools == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.provider_tool_missing, named_tools.rejected.code);

            var move: wire_request.ConfigureCommand = .{};
            try move.key.set("switch-to-work");
            try move.session.set(session.slice());
            move.configuration.provider.state = .value;
            try move.configuration.provider.value.set("work");
            const moved = try storage.configure(&move, .{});
            try std.testing.expect(moved == .accepted);
            try std.testing.expectEqual(before.revision + 1, moved.accepted.revision);
            const after = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqualStrings("work", after.provider.?.slice());
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE field='provider' AND revision=?1", .{moved.accepted.revision}));
            // The Activity row names the connection the revision switched to, and no other field's row names one.
            var changes: protocol.ActivityPage = .{ .kinds = .initOne(.session_changed) };
            changes.session = session;
            const activity = try store_core.activityPageForTesting(&storage, changes);
            try std.testing.expectEqual(@as(usize, 1), activity.count);
            const row = activity.items[0].value.session_changed;
            try std.testing.expectEqual(protocol.SessionField.provider, row.field);
            try std.testing.expectEqual(moved.accepted.revision, row.revision);
            try std.testing.expectEqualStrings("work", row.provider.?.slice());

            var other: wire_request.ConfigureCommand = .{};
            try other.key.set("switch-to-codex");
            try other.session.set(session.slice());
            other.configuration.provider.state = .value;
            try other.configuration.provider.value.set("codex");
            const refused = try storage.configure(&other, .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.connection_wire_differs, refused.rejected.code);
            const kept = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(after.revision, kept.revision);
            try std.testing.expectEqualStrings("work", kept.provider.?.slice());
        }
    }.run);
}

test "an unserved connection name rejects mixed configuration atomically and replays exact shape" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("atomic-initial", "", workspace, "model-a");
            const created_session_0_reply = try storage.configure(&initial, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;

            var update: wire_request.ConfigureCommand = .{};
            try update.key.set("atomic-unsupported");
            try update.session.set(created_session_0.slice());
            update.configuration.provider.state = .value;
            try update.configuration.provider.value.set("anthropic");
            update.configuration.instructions = try testingBytesContent(&tmp, "atomic-instructions", "new instructions");
            update.configuration.output_schema = try testingBytesContent(&tmp, "atomic-schema", "{}");
            update.configuration.tools.state = .value;
            update.configuration.tools.count = 0;
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
            defer update.removeTemporaryContent(std.testing.io) catch unreachable;
            const content_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
            const revision_count = try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{});
            const rejected = try storage.configure(&update, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.connection_unserved, rejected.rejected.code);
            try std.testing.expectEqual(content_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            try std.testing.expectEqual(revision_count, try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
            const current = try storage.inspectSessionForTesting(created_session_0.slice());
            try std.testing.expectEqual(@as(u64, 1), current.revision);
            try expectToolSetNames(&storage, current.tool_set_id, &.{ "bash", "web_search" });
            try std.testing.expectEqualStrings("bypass", current.permission_mode.slice());
            const replay = try storage.configure(&update, .{});
            try std.testing.expect(replay == .rejected and replay.rejected.replayed);

            var omitted: wire_request.ConfigureCommand = .{};
            try omitted.key.set("provider-shape");
            try omitted.session.set(created_session_0.slice());
            omitted.configuration.tools.state = .value;
            omitted.configuration.tools.count = 0;
            try std.testing.expect(try storage.configure(&omitted, .{}) == .accepted);
            var explicit = omitted;
            explicit.configuration.provider.state = .value;
            try explicit.configuration.provider.value.set("codex");
            try std.testing.expect(try storage.configure(&explicit, .{}) == .conflict);
            try std.testing.expect((try storage.configure(&omitted, .{})).accepted.replayed);
        }
    }.run);
}

test "creation accepts omitted Host settings and preserves its supplied Workspace without Bash" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var missing_model = try completeConfiguration("missing-model", "", workspace, "model-a");
            missing_model.configuration.model.state = .omitted;
            const missing_model_reply = try storage.configure(&missing_model, .{});
            try std.testing.expect(missing_model_reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.missing_settings, missing_model_reply.rejected.code);
            try std.testing.expectEqual(@as(u3, 0b001), missing_model_reply.rejected.missing.?.bits);
            inline for (.{ "reasoning_effort", "compaction_trigger", "tools", "permission_mode" }) |field| {
                var command = try completeConfiguration("missing-" ++ field, "", workspace, "model-a");
                @field(command.configuration, field).state = .omitted;
                const reply = try storage.configure(&command, .{});
                try std.testing.expect(reply == .accepted);
                const observed = try storage.inspectSessionForTesting(reply.accepted.session.slice());
                try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), observed.reasoning_effort);
                try std.testing.expectEqualStrings("model-a", observed.model.slice());
            }
            var missing = try completeConfiguration("unused-missing", "", "/does-not-exist/rui-unused-workspace", "model-a");
            missing.configuration.tools = try .of(&.{});
            const refused = try storage.configure(&missing, .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_workspace, refused.rejected.code);
            var command = try completeConfiguration("unused-supplied", "", workspace, "model-a");
            command.configuration.tools = try .of(&.{});
            const reply = try storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            const observed = try storage.inspectSessionForTesting(reply.accepted.session.slice());
            try expectToolSetNames(&storage, observed.tool_set_id, &.{});
            try std.testing.expectEqualStrings("codex", observed.provider.?.slice());
            try std.testing.expectEqualStrings(workspace, observed.workspace.slice());
            var enable: wire_request.ConfigureCommand = .{};
            try enable.key.set("enable-bash");
            enable.session = reply.accepted.session;
            enable.configuration.tools = try .of(&.{"bash"});
            try std.testing.expect(try storage.configure(&enable, .{}) == .accepted);
            const enabled = try storage.inspectSessionForTesting(reply.accepted.session.slice());
            try std.testing.expectEqualStrings(workspace, enabled.workspace.slice());
            try expectToolSetNames(&storage, enabled.tool_set_id, &.{"bash"});
        }
    }.run);
}

test "ADM-33 a creation takes a served connection, the default or its parent's, and checks tools against that binding" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const records = comptime shared_fixtures.testingHostToolRecords(&.{.{ .name = "code_interpreter", .owner = .provider }});
            const digests = comptime blk: {
                @setEvalBranchQuota(10_000_000);
                var out: [records.len][32]u8 = undefined;
                for (&records, &out) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                break :blk out;
            };
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            try std.testing.expect(host_tool_set.valid());
            const Host = enum { serves_codex, serves_nothing };
            const Binding = enum { codex, chatgpt, gateway, omitted };
            const Tools = enum { omitted, web_search, code_interpreter };
            for (std.enums.values(Host)) |host| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var routes: protocol.Served = .{};
                if (host == .serves_codex) try routes.put(protocol.servedEntry(.codex, .endpoint));
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = routes, .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                // The parent names no connection, so it takes the default binding on either Host.
                var parent_key_buffer: [48]u8 = undefined;
                const parent_key = try std.fmt.bufPrint(&parent_key_buffer, "adm33-{s}-parent", .{@tagName(host)});
                var parent = try completeConfiguration(parent_key, "", workspace, "model-a");
                parent.configuration.provider.state = .omitted;
                // A child that omits tools takes the defaults, which must lie within its parent's, so the parent offers them all.
                parent.configuration.tools.state = .value;
                parent.configuration.tools.count = 0;
                parent.configuration.tools.names.len = 0;
                for (tool_defs.built_in_tool_set.records) |record| try parent.configuration.tools.insert(record.name);
                const parent_reply = try storage.configure(&parent, .{});
                try std.testing.expect(parent_reply == .accepted);
                const parent_session = parent_reply.accepted.session;
                for (std.enums.values(Binding)) |binding| for ([_]bool{ false, true }) |inherited| for (std.enums.values(Tools)) |tools| {
                    // An inherited creation may not name a provider: a child's explicit provider is refused by ADM-6.
                    if (inherited and binding != .omitted) continue;
                    var key_buffer: [96]u8 = undefined;
                    const key = try std.fmt.bufPrint(&key_buffer, "adm33-{s}-{s}-{s}-{s}", .{ @tagName(host), @tagName(binding), @tagName(tools), if (inherited) "child" else "standalone" });
                    var command: wire_request.ConfigureCommand = .{};
                    if (inherited) {
                        try command.key.set(key);
                        command.configuration.parent.state = .value;
                        try command.configuration.parent.value.set(parent_session.slice());
                        command.configuration.model.state = .value;
                        try command.configuration.model.value.set("model-a");
                    } else {
                        command = try completeConfiguration(key, "", workspace, "model-a");
                        switch (binding) {
                            .codex => try command.configuration.provider.value.set("codex"),
                            .chatgpt => try command.configuration.provider.value.set("chatgpt"),
                            .gateway => try command.configuration.provider.value.set("gateway"),
                            .omitted => command.configuration.provider.state = .omitted,
                        }
                    }
                    switch (tools) {
                        .omitted => command.configuration.tools.state = .omitted,
                        .web_search => command.configuration.tools = try .of(&.{"web_search"}),
                        .code_interpreter => command.configuration.tools = try .of(&.{"code_interpreter"}),
                    }
                    // A built-in name is a binding whether or not this Host serves it, so offline creation keeps
                    // working; an unserved name that is not built in has no codec and is refused whatever tools
                    // it asks for. Tools are checked against the binding: the default and inherited one is codex.
                    const unknown = binding == .gateway;
                    const expected: ?protocol.ConfigurationRejection = if (!inherited and unknown)
                        .connection_unserved
                    else if (tools == .code_interpreter)
                        .provider_tool_missing
                    else
                        null;
                    const before = try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{});
                    const reply = try storage.configure(&command, .{});
                    if (expected) |code| {
                        try std.testing.expect(reply == .rejected);
                        try std.testing.expectEqual(code, reply.rejected.code);
                        try std.testing.expectEqual(before, try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                    } else {
                        try std.testing.expect(reply == .accepted);
                        const observed = try storage.inspectSessionForTesting(reply.accepted.session.slice());
                        const bound = if (!inherited and binding == .chatgpt) "chatgpt" else "codex";
                        try std.testing.expectEqualStrings(bound, observed.provider.?.slice());
                        try std.testing.expectEqual(before + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                    }
                };
            }
        }
    }.run);
}

test "an omitted provider is refused on a Host serving several" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var routes: protocol.Served = .{};
            try routes.put(protocol.servedEntry(.openai, .endpoint));
            try routes.put(protocol.servedEntry(.codex, .endpoint));
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .served = routes });
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("several-providers", "", workspace, "model-a");
            command.configuration.provider.state = .omitted;
            command.configuration.tools = try .of(&.{});
            const reply = try storage.configure(&command, .{});
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.missing_settings, reply.rejected.code);
            try std.testing.expectEqual(@as(u3, 0b100), reply.rejected.missing.?.bits);
            try command.key.set("several-providers-named");
            command.configuration.provider.state = .value;
            try command.configuration.provider.value.set("openai");
            try std.testing.expect(try storage.configure(&command, .{}) == .accepted);
        }
    }.run);
}

test "compactAt enforces only known context windows on create and update" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const window: u64 = @import("../../model_catalog.zig").find(@import("../../model_catalog.zig").shipped, "gpt-6.1-sol").?.context_window.?;
            var buffer: [20]u8 = undefined;
            var command = try completeConfiguration("too-large-create", "", workspace, "gpt-6.1-sol");
            try command.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&buffer, "{d}", .{window + 1}));
            var reply = try storage.configure(&command, .{});
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.compact_at_too_large, reply.rejected.code);
            try std.testing.expect((try storage.configure(&command, .{})).rejected.replayed);
            try command.key.set("u64-too-large-create");
            try command.configuration.compaction_trigger.value.set("18446744073709551615");
            const huge = try storage.configure(&command, .{});
            try std.testing.expect(huge == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.compact_at_too_large, huge.rejected.code);
            try command.key.set("window-boundary");
            try command.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&buffer, "{d}", .{window}));
            reply = try storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set("too-large-update");
            patch.session = reply.accepted.session;
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&buffer, "{d}", .{window + 1}));
            const refused = try storage.configure(&patch, .{});
            try std.testing.expect(refused == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.compact_at_too_large, refused.rejected.code);
            try std.testing.expect((try storage.configure(&patch, .{})).rejected.replayed);
            const observed = try storage.inspectSessionForTesting(reply.accepted.session.slice());
            try std.testing.expectEqual(@as(u64, 1), observed.revision);
            try std.testing.expectEqual(@as(?u64, window), observed.compaction_trigger);
            try command.key.set("unlisted-window");
            try command.configuration.model.value.set("model-not-in-catalog");
            command.configuration.reasoning_effort.state = .explicit_null;
            try command.configuration.compaction_trigger.value.set("999999999");
            try std.testing.expect(try storage.configure(&command, .{}) == .accepted);
        }
    }.run);
}

test "model revisions validate retained effort and compactAt against the new catalog model" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const catalog = @import("../../model_catalog.zig");
            const known = catalog.find(catalog.shipped, "gpt-6.1-sol").?;
            var create = try completeConfiguration("switch-catalog-create", "", workspace, "model-a");
            create.configuration.reasoning_effort.state = .value;
            try create.configuration.reasoning_effort.value.set("none");
            var buffer: [20]u8 = undefined;
            try create.configuration.compaction_trigger.value.set(try std.fmt.bufPrint(&buffer, "{d}", .{known.context_window.? + 1}));
            const session = (try storage.configure(&create, .{})).accepted.session;
            var patch: wire_request.ConfigureCommand = .{};
            patch.session = session;
            patch.configuration.model.state = .value;
            try patch.configuration.model.value.set(known.id);
            try patch.key.set("switch-catalog-window");
            const window = try storage.configure(&patch, .{});
            try std.testing.expect(window == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.compact_at_too_large, window.rejected.code);
            try std.testing.expect((try storage.configure(&patch, .{})).rejected.replayed);
            try patch.key.set("switch-catalog-effort");
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("100");
            const effort = try storage.configure(&patch, .{});
            try std.testing.expect(effort == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, effort.rejected.code);
            try patch.key.set("switch-catalog-unlisted");
            try patch.configuration.model.value.set("model-b");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            const unlisted = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .none), unlisted.reasoning_effort);
            try patch.key.set("switch-catalog-listed");
            try patch.configuration.model.value.set(known.id);
            patch.configuration.reasoning_effort.state = .value;
            try patch.configuration.reasoning_effort.value.set("low");
            const listed = try storage.configure(&patch, .{});
            try std.testing.expect(listed == .accepted);
            try std.testing.expectEqual(@as(u64, 3), listed.accepted.revision);
        }
    }.run);
}

test "loaded tools select saved records even after the Host tool set changes or removes them" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var records = comptime testingHostToolRecords(&.{
                .{ .name = "fetch_page", .owner = .mcp, .server = "original", .description = "Original page", .input_schema = "{\"type\":\"object\"}" },
                .{ .name = "other_page", .owner = .mcp, .server = "original", .description = "Other page", .input_schema = "{\"type\":\"object\"}" },
            });
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            const original: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            try storage.saveHostToolSet(&original);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("loaded-records-create", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{ "fetch_page", "find_tools", "other_page" });
            create.configuration.loaded_tools = try .of(&.{"find_tools"});
            const first = (try storage.configure(&create, .{})).accepted.session;
            try create.key.set("loaded-records-second");
            const second = (try storage.configure(&create, .{})).accepted.session;
            const saved_record = try store_testing.queryU64(&storage, "SELECT t.tool_record_id FROM session s JOIN tool_set_member m ON m.tool_set_id=s.tool_set_id " ++
                "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name='fetch_page'", .{first.slice()});

            var changed_records = records;
            changed_records[1] = .{ .name = "fetch_page", .owner = .mcp, .server = "replacement", .description = "New page", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false}" };
            var changed_digests = digests;
            changed_digests[1] = tool_defs.recordDigest(&changed_records[1]);
            const changed: tool_defs.HostToolSet = .{ .records = &changed_records, .digests = &changed_digests };
            try storage.saveHostToolSet(&changed);
            var update: wire_request.ConfigureCommand = .{};
            try update.key.set("loaded-records-reworded");
            update.session = first;
            update.configuration.loaded_tools = try .of(&.{ "fetch_page", "find_tools" });
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            const loaded_record = try store_testing.queryU64(&storage, "SELECT t.tool_record_id FROM session s JOIN tool_set_member m ON m.tool_set_id=s.loaded_tool_set_id " ++
                "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name='fetch_page'", .{first.slice()});
            try std.testing.expectEqual(saved_record, loaded_record);
            const expected_loaded = tool_set_domain.Selection.of(&original, &update.configuration.loaded_tools, 0).?;
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session s JOIN tool_set saved ON saved.tool_set_id=s.loaded_tool_set_id WHERE s.session_ref=?1 AND saved.digest=?2", .{ first.slice(), store_testing.Blob{ .bytes = &expected_loaded.digest } }));

            var removed_records: [records.len - 1]tool_defs.Record = undefined;
            removed_records[0] = records[0];
            @memcpy(removed_records[1..], records[2..]);
            var removed_digests: [removed_records.len][32]u8 = undefined;
            for (&removed_records, &removed_digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            const removed: tool_defs.HostToolSet = .{ .records = &removed_records, .digests = &removed_digests };
            try storage.saveHostToolSet(&removed);
            try update.key.set("loaded-records-removed");
            update.session = second;
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(DISTINCT loaded_tool_set_id) FROM session WHERE session_ref=?1 OR session_ref=?2", .{ first.slice(), second.slice() }));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "configuration planning preserves sparse defaults and rejection precedence" {
    const WorkspaceRequest = enum { omitted, same, different };
    const InstructionsRequest = enum { omitted, value };
    const SchemaRequest = enum { omitted, value, clear };
    const Actions = struct {
        instructions: ConfigurationContentAction,
        output_schema: configuration_domain.OutputSchemaAction,
    };
    const Case = struct {
        name: []const u8,
        created: bool,
        workspace: WorkspaceRequest,
        model: ?[]const u8 = null,
        empty_tools: bool = false,
        permission: ?[]const u8 = null,
        instructions: InstructionsRequest = .omitted,
        schema: SchemaRequest = .omitted,
        current_revision: u64 = 7,
        expected_rejection: ?protocol.ConfigurationRejection = null,
        expected_actions: ?Actions = null,
        expected_model: []const u8 = "model-a",
        expected_permission: u8 = 0,
        expected_revision: u64 = 8,
    };
    const cases = [_]Case{
        .{
            .name = "new explicit permission",
            .created = true,
            .workspace = .same,
            .model = "model-a",
            .permission = "bypass",
            .expected_actions = .{ .instructions = .default_empty, .output_schema = .clear },
            .expected_permission = 1,
            .expected_revision = 1,
        },
        .{
            .name = "sparse update preserves omitted content",
            .created = false,
            .workspace = .omitted,
            .expected_actions = .{ .instructions = .preserve, .output_schema = .preserve },
        },
        .{
            .name = "explicit update requests imports and clear",
            .created = false,
            .workspace = .same,
            .model = "model-a",
            .empty_tools = true,
            .permission = "bypass",
            .instructions = .value,
            .schema = .clear,
            .expected_actions = .{ .instructions = .import_requested, .output_schema = .clear },
            .expected_model = "model-a",
            .expected_permission = 1,
        },
        .{
            .name = "requested schema imports",
            .created = false,
            .workspace = .omitted,
            .schema = .value,
            .expected_actions = .{ .instructions = .preserve, .output_schema = .import_requested },
        },
        .{
            .name = "Workspace immutability precedes revision exhaustion",
            .created = false,
            .workspace = .different,
            .current_revision = std.math.maxInt(i64),
            .expected_rejection = .workspace_is_immutable,
            .expected_revision = std.math.maxInt(i64),
        },
        .{
            .name = "revision exhaustion follows equal Workspace",
            .created = false,
            .workspace = .same,
            .current_revision = std.math.maxInt(i64),
            .expected_rejection = .revision_exhausted,
            .expected_revision = std.math.maxInt(i64),
        },
    };

    try std.testing.expect(@sizeOf(ConfigurationUpdatePlan) <= 4);
    for (cases) |case| {
        var existing: CurrentConfiguration = .{};
        try existing.workspace.set("/canonical/workspace");
        existing.provider = connection.Name.parse("codex").?;
        try existing.model.set("model-a");
        existing.instructions_id = 11;
        existing.tool_set_id = 1;
        existing.permission_mode = 0;
        existing.output_schema_id = 12;
        existing.revision = case.current_revision;

        var requested: wire_request.Configuration = .{};
        requested.provider.state = .value;
        try requested.provider.value.set("codex");
        if (case.workspace != .omitted) requested.workspace.state = .value;
        if (case.model) |model| {
            requested.model.state = .value;
            try requested.model.value.set(model);
        }
        if (case.empty_tools) {
            requested.tools.state = .value;
            requested.tools.count = 0;
        }
        if (case.permission) |permission| {
            requested.permission_mode.state = .value;
            try requested.permission_mode.value.set(permission);
        }
        if (case.instructions == .value) requested.instructions.state = .value;
        requested.output_schema.state = switch (case.schema) {
            .omitted => .omitted,
            .value => .value,
            .clear => .explicit_null,
        };

        const workspace_matches: ?bool = switch (case.workspace) {
            .omitted => null,
            .same => true,
            .different => false,
        };
        const current: ?*const CurrentConfiguration = if (case.created) null else &existing;
        var next = if (current) |value| value.* else CurrentConfiguration{};
        const plan = configuration_domain.planConfigurationUpdate(current, &requested, workspace_matches, &next);

        if (case.expected_rejection) |expected| {
            std.testing.expect(plan == .rejected) catch |err| {
                std.debug.print("configuration planning case failed: {s}\n", .{case.name});
                return err;
            };
            try std.testing.expectEqual(expected, plan.rejected);
        } else {
            const expected = case.expected_actions.?;
            std.testing.expect(plan == .update) catch |err| {
                std.debug.print("configuration planning case failed: {s}\n", .{case.name});
                return err;
            };
            try std.testing.expectEqual(expected.instructions, plan.update.instructions);
            try std.testing.expectEqual(expected.output_schema, plan.update.output_schema);
        }
        try std.testing.expectEqualStrings(case.expected_model, next.model.slice());
        try std.testing.expectEqual(case.expected_permission, next.permission_mode);
        try std.testing.expectEqual(case.expected_revision, next.revision);
        try std.testing.expectEqual(@as(?i64, if (case.created) null else 11), next.instructions_id);
        try std.testing.expectEqual(@as(?i64, if (case.created) null else 12), next.output_schema_id);
    }
}

test "historical model immutability rejections replay while fresh model switches are accepted" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "historical-model-initial");
            const initial = try storage.inspectSessionForTesting(session.slice());

            var update: wire_request.ConfigureCommand = .{};
            try update.key.set("historical-model-configure");
            update.session = session;
            update.configuration.model.state = .value;
            try update.configuration.model.value.set("model-b");
            var message: wire_request.MessageCommand = .{};
            try message.key.set("historical-model-message");
            message.session = session;
            message.text = try testingBytesContent(&tmp, "historical-model-body", "a previously refused Message");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;

            const sequence = try store_testing.queryU64(&storage, "SELECT coalesce(max(command_seq),0)+1 FROM core_command", .{});
            const configure_digest = update.semanticDigest();
            const message_digest = message.semanticDigest();
            try store_testing.exec(&storage, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES(?1,1,?2,?3,0,'model_is_immutable',0,0,?4)", .{ update.key.slice(), session.slice(), store_testing.Blob{ .bytes = &configure_digest }, sequence });
            try store_testing.exec(&storage, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES(?1,2,?2,?3,0,'model_is_immutable',0,0,?4)", .{ message.key.slice(), session.slice(), store_testing.Blob{ .bytes = &message_digest }, sequence + 1 });
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);

            const replay = try storage.configure(&update, .{});
            try std.testing.expect(replay == .rejected and replay.rejected.replayed);
            try std.testing.expectEqualStrings("model_is_immutable", @tagName(replay.rejected.code));
            const unchanged = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(initial.revision, unchanged.revision);
            try std.testing.expectEqualStrings(initial.model.slice(), unchanged.model.slice());

            var fresh = update;
            try fresh.key.set("fresh-model-configure");
            const accepted = try storage.configure(&fresh, .{});
            try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
            try std.testing.expectEqual(initial.revision + 1, accepted.accepted.revision);
            try std.testing.expectEqualStrings(session.slice(), accepted.accepted.session.slice());
            const old_again = try storage.configure(&update, .{});
            try std.testing.expectEqual(replay, old_again);
            const message_replay = storage.submitMessageWithModel(&message, null, .{});
            try std.testing.expect(message_replay == .rejected and message_replay.rejected.replayed);
            try std.testing.expectEqualStrings("model_is_immutable", @tagName(message_replay.rejected.code));
            try std.testing.expectEqual(message.text.length, message_replay.rejected.content.length);
            try std.testing.expectEqualSlices(u8, &message.text.digest, &message_replay.rejected.content.digest);
            const changed = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expectEqual(accepted.accepted.revision, changed.revision);
            try std.testing.expectEqualStrings("model-b", changed.model.slice());
            try std.testing.expectEqual(@as(u64, 0), changed.pending_messages);
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE accepted=0 AND code='model_is_immutable'", .{}));
        }
    }.run);
}

test "configuration answers replay without reverting newer settings" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var first = try completeConfiguration("first", "", workspace, "model-a");
            const first_reply = try storage.configure(&first, .{});
            try std.testing.expect(first_reply == .accepted);
            try std.testing.expect(first_reply.accepted.created);

            var update: wire_request.ConfigureCommand = .{};
            try update.key.set("update");
            update.session = first_reply.accepted.session;
            update.configuration.tools.state = .value;
            update.configuration.tools.count = 0;
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
            const update_reply = try storage.configure(&update, .{});
            try std.testing.expect(update_reply == .accepted);
            try std.testing.expectEqual(@as(u64, 2), update_reply.accepted.revision);

            const replay = try storage.configure(&first, .{});
            try std.testing.expect(replay == .accepted);
            try std.testing.expect(replay.accepted.replayed);
            try std.testing.expectEqual(@as(u64, 1), replay.accepted.revision);
            const observation = try storage.inspectSessionForTesting(first_reply.accepted.session.slice());
            try std.testing.expectEqualStrings("model-a", observation.model.slice());
            try std.testing.expectEqual(@as(u64, 2), observation.revision);
            try expectToolSetNames(&storage, observation.tool_set_id, &.{});
            try std.testing.expectEqualStrings("bypass", observation.permission_mode.slice());
            try std.testing.expectEqual(@as(u64, 0), observation.instructions.length);
            var empty_digest: [32]u8 = undefined;
            empty_digest = protocol.contentDigest("");
            try std.testing.expectEqualSlices(u8, &empty_digest, &observation.instructions.digest);
            try std.testing.expect(observation.output_schema == null);

            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(observation.instructions));
            defer reader.close();
            var content_window: [1]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 0), try reader.read(0, &content_window));
            try std.testing.expectError(error.RangeOutOfBounds, reader.read(1, &content_window));
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "first")).status == .accepted);

            first.configuration.tools.state = .value;
            first.configuration.tools.count = 0;
            try std.testing.expect(try storage.configure(&first, .{}) == .conflict);
        }
    }.run);
}

test "explicit native and preset restrictions survive reopen and resumed model requests" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Surface = enum { configure, preset };
            const selections = [_]struct { allowed: []const []const u8, loaded: []const []const u8 }{
                .{ .allowed = &.{}, .loaded = &.{} },
                .{ .allowed = &.{"bash"}, .loaded = &.{"bash"} },
                .{ .allowed = &.{ "bash", "find_tools", "web_search" }, .loaded = &.{ "bash", "find_tools" } },
            };
            for (std.enums.values(Surface)) |surface| for (selections) |selection| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create: wire_request.ConfigureCommand = .{};
                try create.key.set("restricted-create");
                create.configuration = try shared_fixtures.testingAgentSpec(selection.allowed, "ask");
                create.configuration.provider.state = .value;
                try create.configuration.provider.value.set("codex");
                create.configuration.workspace.state = .value;
                try create.configuration.workspace.value.set(workspace);
                create.configuration.loaded_tools = try .of(selection.loaded);
                var request: wire_request.ConfigureCommand = .{ .key = create.key };
                var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer memory.deinit();
                if (surface == .preset) {
                    request.preset = .{};
                    try request.preset.?.set("reader");
                    const arena = memory.allocator();
                    const bytes = try std.json.Stringify.valueAlloc(arena, .{
                        .connection = "codex",
                        .workspace = workspace,
                        .model = create.configuration.model.value.slice(),
                        .effort = create.configuration.reasoning_effort.value.slice(),
                        .compactAt = 100000,
                        .tools = selection.allowed,
                        .loadedTools = selection.loaded,
                        .permissionMode = "ask",
                    }, .{});
                    const preset = (try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{})).object;
                    try std.testing.expect(try @import("../../core_tools.zig").parseAgentSpec(arena, preset, &create.configuration) == .accepted);
                }
                var session: protocol.Bounded(protocol.session_id_bytes) = .{};
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const result = switch (surface) {
                        .configure => try storage.configure(&create, .{}),
                        .preset => try storage.configureWithPreset(&create, &.{ .request_digest = request.presetRequestDigest() }, .{}),
                    };
                    try std.testing.expect(result == .accepted);
                    try session.set(result.accepted.session.slice());
                    const saved = try storage.inspectSessionForTesting(session.slice());
                    try expectToolSetNames(&storage, saved.tool_set_id, selection.allowed);
                    try std.testing.expectEqualStrings("ask", saved.permission_mode.slice());
                    try store_testing.answerTestTurn(&storage, &tmp, session.slice(), "restricted-first", &.{.{ .encoded = "done", .decoded = "done" }});
                }
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    var patch: wire_request.ConfigureCommand = .{};
                    try patch.key.set("restricted-rename");
                    try patch.session.set(session.slice());
                    patch.configuration.label.state = .value;
                    try patch.configuration.label.value.set("Resumed reader");
                    try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                    try store_testing.submitTestMessage(&storage, &tmp, "restricted-resume", "restricted-resume", session.slice(), "continue");
                    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    var view: store_testing.TestingPage = undefined;
                    view.open(&storage, binding);
                    defer view.close();
                    const settings = try shared_fixtures.testSettings(&view);
                    try std.testing.expectEqual(@as(u64, @intCast(selection.loaded.len)), settings.tool_count);
                    var tool: @import("../domain/historical.zig").HistoricalTool = .{};
                    for (selection.loaded) |name| {
                        try std.testing.expect(try view.nextTool(&tool));
                        try std.testing.expectEqualStrings(name, tool.name.slice());
                    }
                    try std.testing.expect(!try view.nextTool(&tool));
                    try std.testing.expectEqualStrings(create.configuration.model.value.slice(), settings.model.slice());
                    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), settings.reasoning_effort);
                    try std.testing.expectEqual(@as(?u64, 100000), settings.compaction_trigger);
                    const resumed = try storage.inspectSessionForTesting(session.slice());
                    try std.testing.expectEqual(@as(u64, 2), resumed.revision);
                    try expectToolSetNames(&storage, resumed.tool_set_id, selection.allowed);
                    const loaded_id = try store_testing.queryU64(&storage, "SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session WHERE session_ref=?1", .{session.slice()});
                    try expectToolSetNames(&storage, loaded_id, selection.loaded);
                    try std.testing.expectEqualStrings("ask", resumed.permission_mode.slice());
                }
            };
        }
    }.run);
}

test "core preserves empty and NUL keys while Session references stay canonical" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("", "", workspace, "model-a");
            const reply = try storage.configure(&command, .{});
            try std.testing.expect(reply == .accepted);
            const session = reply.accepted.session;
            try std.testing.expect(protocol.validSessionId(session.slice()));
            const observation = try storage.inspectSessionForTesting(session.slice());
            try std.testing.expect(observation.found);
            try std.testing.expectEqualStrings(session.slice(), observation.session.slice());
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "")).status == .accepted);

            var update: wire_request.ConfigureCommand = .{};
            try update.key.set("exact\x00key");
            update.session = session;
            const updated = try storage.configure(&update, .{});
            try std.testing.expect(updated == .accepted and !updated.accepted.created);
            try std.testing.expectEqual(@as(u64, 2), updated.accepted.revision);
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "exact\x00key")).status == .accepted);
            try std.testing.expect((try storage.configure(&update, .{})).accepted.replayed);

            var invalid = try completeConfiguration("invalid-nul-session", "exact\x00reference", workspace, "model-a");
            const rejected = try storage.configure(&invalid, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_session_reference, rejected.rejected.code);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, 2), (try storage.inspectSessionForTesting(session.slice())).revision);
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a saved missing_settings rejection stays rejected after Session creation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var incomplete: wire_request.ConfigureCommand = .{};
            try incomplete.key.set("incomplete");
            const rejected = try storage.configure(&incomplete, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.missing_settings, rejected.rejected.code);

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var complete = try completeConfiguration(
                "complete",
                "",
                workspace,
                "model-a",
            );
            try std.testing.expect(try storage.configure(&complete, .{}) == .accepted);
            const replay = try storage.configure(&incomplete, .{});
            try std.testing.expect(replay == .rejected);
            try std.testing.expect(replay.rejected.replayed);
            try std.testing.expectEqual(rejected.rejected.missing.?.bits, replay.rejected.missing.?.bits);
        }
    }.run);
}

test "capability-required configuration rejects on replacement and replays its saved decision" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("capability-guard", "", workspace, "model-a");
            command.require_model = true;

            storage.servedSet().* = protocol.Served{};
            const rejected = try storage.configure(&command, .{});
            try std.testing.expect(rejected == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.model_capability_unavailable, rejected.rejected.code);
            try std.testing.expect(!(try storage.inspectSessionForTesting(command.session.slice())).found);
            const replay = try storage.configure(&command, .{});
            try std.testing.expect(replay == .rejected and replay.rejected.replayed);
            try std.testing.expectEqual(rejected.rejected.code, replay.rejected.code);

            var new_key = command;
            try new_key.key.set("capability-guard-next");
            storage.servedSet().* = protocol.servedBuiltIns(.endpoint);
            try std.testing.expect(try storage.configure(&new_key, .{}) == .accepted);
            storage.servedSet().* = protocol.Served{};
            try std.testing.expect((try storage.configure(&new_key, .{})).accepted.replayed);
            var changed_intent = command;
            changed_intent.require_model = false;
            try std.testing.expect(try storage.configure(&changed_intent, .{}) == .conflict);
            try changed_intent.key.set("explicit-offline-config");
            try std.testing.expect(try storage.configure(&changed_intent, .{}) == .accepted);
        }
    }.run);
}

test "failed commit saves neither answer nor partial Session" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration(
                "commit-fault",
                "",
                workspace,
                "model-a",
            );
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                const reply = try storage.configure(&command, .{ .before_commit = true });
                try std.testing.expect(reply == .infrastructure_failure);
                try storage.close();
            }
            {
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "commit-fault")).status == .absent);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                try std.testing.expect(try storage.configure(&command, .{}) == .accepted);
            }
        }
    }.run);
}

fn testingLabel(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8) !?[]u8 {
    const bytes = try testingSessionReport(storage, tmp, session, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer report.deinit();
    const label = report.value.object.get("session").?.object.get("label").?;
    return if (label == .null) null else try std.testing.allocator.dupe(u8, label.string);
}

test "a Label is configured, replayed, cleared and validated like any setting" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

            var create = try completeConfiguration("label-create", "", workspace, "model-a");
            create.configuration.label.state = .value;
            try create.configuration.label.value.set("Review PR 412");
            const created = try storage.configure(&create, .{});
            try std.testing.expect(created == .accepted);
            const session = created.accepted.session;
            {
                const label = (try testingLabel(&storage, &tmp, session.slice())).?;
                defer std.testing.allocator.free(label);
                try std.testing.expectEqualStrings("Review PR 412", label);
            }
            try std.testing.expect((try storage.configure(&create, .{})).accepted.replayed);
            var changed = create;
            try changed.configuration.label.value.set("Review PR 413");
            try std.testing.expect(try storage.configure(&changed, .{}) == .conflict);

            var relabel: wire_request.ConfigureCommand = .{};
            try relabel.key.set("label-relabel");
            try relabel.session.set(session.slice());
            relabel.configuration.label.state = .value;
            try relabel.configuration.label.value.set("Fix the flaky resize test");
            try std.testing.expectEqual(@as(u64, 2), (try storage.configure(&relabel, .{})).accepted.revision);
            var effort: wire_request.ConfigureCommand = .{};
            try effort.key.set("label-preserved");
            try effort.session.set(session.slice());
            effort.configuration.permission_mode.state = .value;
            try effort.configuration.permission_mode.value.set("ask");
            try std.testing.expect(try storage.configure(&effort, .{}) == .accepted);
            {
                const label = (try testingLabel(&storage, &tmp, session.slice())).?;
                defer std.testing.allocator.free(label);
                try std.testing.expectEqualStrings("Fix the flaky resize test", label);
            }
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry", .{}));
            try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE label IS NOT NULL", .{}));

            var clear: wire_request.ConfigureCommand = .{};
            try clear.key.set("label-clear");
            try clear.session.set(session.slice());
            clear.configuration.label.state = .explicit_null;
            try std.testing.expect(try storage.configure(&clear, .{}) == .accepted);
            try std.testing.expect((try testingLabel(&storage, &tmp, session.slice())) == null);

            for ([_][]const u8{ " ", "two\nlines", "tab\u{2028}separated" }, 0..) |text, index| {
                var refused: wire_request.ConfigureCommand = .{};
                var key_buffer: [32]u8 = undefined;
                try refused.key.set(try std.fmt.bufPrint(&key_buffer, "label-refused-{d}", .{index}));
                try refused.session.set(session.slice());
                refused.configuration.label.state = .value;
                try refused.configuration.label.value.set(text);
                const reply = try storage.configure(&refused, .{});
                try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_label, reply.rejected.code);
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "definite rejections retain decisions without retaining payloads for configuration; Messages retain input" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("initial", "", workspace, "model-a");
            const created_session_0_reply = try storage.configure(&initial, .{});
            try std.testing.expect(created_session_0_reply == .accepted);
            const created_session_0 = created_session_0_reply.accepted.session;
            try store_testing.withoutForeignKeys(&storage, "UPDATE session_revision SET revision=9223372036854775807 WHERE session_ref=?1", .{created_session_0.slice()});
            try store_testing.exec(&storage, "UPDATE session SET revision=9223372036854775807 WHERE session_ref=?1", .{created_session_0.slice()});

            var unknown_message: wire_request.MessageCommand = .{};
            try unknown_message.key.set("unknown-message");
            try unknown_message.session.set("absent");
            unknown_message.text = try testingContent(&tmp, "unknown-message", 'm', 64 * 1024);
            defer unknown_message.removeTemporaryContent(std.testing.io) catch unreachable;
            const unknown_reply = storage.submitMessageWithModel(&unknown_message, null, .{});
            try std.testing.expect(unknown_reply == .rejected);
            try std.testing.expectEqual(protocol.MessageRejection.unknown_session, unknown_reply.rejected.code);

            var incomplete: wire_request.ConfigureCommand = .{};
            try incomplete.key.set("incomplete");
            incomplete.configuration.instructions = try testingContent(&tmp, "incomplete", 'i', 64 * 1024);
            defer incomplete.removeTemporaryContent(std.testing.io) catch unreachable;
            const incomplete_reply = try storage.configure(&incomplete, .{});
            try std.testing.expect(incomplete_reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.missing_settings, incomplete_reply.rejected.code);

            var exhausted: wire_request.ConfigureCommand = .{};
            try exhausted.key.set("exhausted");
            try exhausted.session.set(created_session_0.slice());
            exhausted.configuration.instructions = try testingContent(&tmp, "exhausted", 'e', 64 * 1024);
            defer exhausted.removeTemporaryContent(std.testing.io) catch unreachable;
            const exhausted_reply = try storage.configure(&exhausted, .{});
            try std.testing.expect(exhausted_reply == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.revision_exhausted, exhausted_reply.rejected.code);

            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, store_testing.content_beside_tools, .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command cmd JOIN content c ON c.content_id=cmd.primary_content_id WHERE cmd.command_key=?1 AND cmd.kind=2 AND cmd.accepted=0 AND cmd.secondary_content_id IS NULL AND c.byte_length=?2 AND c.digest=?3 AND c.form=0", .{ unknown_message.key.slice(), unknown_message.text.length, store_testing.Blob{ .bytes = &unknown_message.text.digest } }));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE accepted=0 AND kind<>2 AND (primary_content_id IS NOT NULL OR secondary_content_id IS NOT NULL)", .{}));

            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            try std.testing.expect(storage.submitMessageWithModel(&unknown_message, null, .{}).rejected.replayed);
            try std.testing.expect((try storage.configure(&incomplete, .{})).rejected.replayed);
            try std.testing.expect((try storage.configure(&exhausted, .{})).rejected.replayed);

            var changed = unknown_message;
            changed.text.digest[0] ^= 1;
            try std.testing.expect(storage.submitMessageWithModel(&changed, null, .{}) == .conflict);
            var retargeted = incomplete;
            try retargeted.session.set("0ther0");
            try std.testing.expect(try storage.configure(&retargeted, .{}) == .conflict);
            var changed_kind: wire_request.MessageCommand = .{};
            try changed_kind.key.set("incomplete");
            try changed_kind.session.set("absent");
            changed_kind.text = unknown_message.text;
            try std.testing.expect(storage.submitMessageWithModel(&changed_kind, null, .{}) == .conflict);
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, store_testing.content_beside_tools, .{}));
        }
    }.run);
}

test "parent creation uses inherited provider for omitted compaction across saved provider bindings" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var parent = try completeConfiguration("inherited-compaction-parent", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            parent.configuration.tools.state = .value;
            parent.configuration.tools.count = 0;
            parent.configuration.tools.names.len = 0;
            for (tool_defs.built_in_tool_set.records) |record| try parent.configuration.tools.insert(record.name);
            const parent_session = (try storage.configure(&parent, .{})).accepted.session;
            for ([_][]const u8{ "openai", "codex" }) |saved_provider| {
                var child: wire_request.ConfigureCommand = .{};
                var key: [64]u8 = undefined;
                try child.key.set(try std.fmt.bufPrint(&key, "inherited-compaction-saved-{s}", .{saved_provider}));
                child.configuration.parent.state = .value;
                try child.configuration.parent.value.set(parent_session.slice());
                child.configuration.model.state = .value;
                try child.configuration.model.value.set("gpt-6.2-astra");
                const result = try storage.configure(&child, .{});
                try std.testing.expect(result == .accepted);
                const observed = try storage.inspectSessionForTesting(result.accepted.session.slice());
                try std.testing.expectEqualStrings("codex", observed.provider.?.slice());
                try std.testing.expectEqual(@as(?u64, 244800), observed.compaction_trigger);
                try std.testing.expectEqualStrings("gpt-6.2-astra", observed.model.slice());
                try std.testing.expect((try storage.configure(&child, .{})).accepted.replayed);
            }
        }
    }.run);
}

test "standalone creation always requires Workspace and replays saved refusal across tool sets" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |creating_message| for ([_]?[]const []const u8{ null, &.{}, &.{"web_search"}, &.{"bash"} }) |tools| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var configure = try completeConfiguration("missing-workspace", "", workspace, "model-a");
                configure.configuration.workspace.state = .omitted;
                if (tools) |names| configure.configuration.tools = try .of(names) else configure.configuration.tools.state = .omitted;
                if (creating_message) {
                    var message: wire_request.MessageCommand = .{};
                    try message.key.set("missing-workspace");
                    message.configuration = configure.configuration;
                    message.text = try testingBytesContent(&tmp, "missing-workspace-message", "create in my Workspace");
                    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
                    const refused = storage.submitMessageWithModel(&message, null, .{});
                    try std.testing.expect(refused == .rejected);
                    try std.testing.expectEqual(protocol.MessageRejection.missing_settings, refused.rejected.code);
                    try std.testing.expectEqual(@as(u3, 0b010), refused.rejected.missing.?.bits);
                    const replay = storage.submitMessageWithModel(&message, null, .{});
                    try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                    try std.testing.expectEqual(refused.rejected.code, replay.rejected.code);
                    try std.testing.expectEqual(refused.rejected.missing.?.bits, replay.rejected.missing.?.bits);
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                    try message.key.set("supplied-workspace");
                    message.configuration.?.workspace.state = .value;
                    try message.configuration.?.workspace.value.set(workspace);
                    const accepted = storage.submitMessageWithModel(&message, null, .{});
                    try std.testing.expect(accepted == .accepted);
                    const observed = try storage.inspectSessionForTesting(accepted.accepted.session.slice());
                    try std.testing.expectEqualStrings(workspace, observed.workspace.slice());
                    try std.testing.expectEqualStrings("model-a", observed.model.slice());
                } else {
                    const refused = try storage.configure(&configure, .{});
                    try std.testing.expect(refused == .rejected);
                    try std.testing.expectEqual(protocol.ConfigurationRejection.missing_settings, refused.rejected.code);
                    try std.testing.expectEqual(@as(u3, 0b010), refused.rejected.missing.?.bits);
                    const replay = try storage.configure(&configure, .{});
                    try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                    try std.testing.expectEqual(refused.rejected.code, replay.rejected.code);
                    try std.testing.expectEqual(refused.rejected.missing.?.bits, replay.rejected.missing.?.bits);
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                    try configure.key.set("supplied-workspace");
                    configure.configuration.workspace.state = .value;
                    try configure.configuration.workspace.value.set(workspace);
                    const accepted = try storage.configure(&configure, .{});
                    try std.testing.expect(accepted == .accepted);
                    const observed = try storage.inspectSessionForTesting(accepted.accepted.session.slice());
                    try std.testing.expectEqualStrings(workspace, observed.workspace.slice());
                }
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            };
        }
    }.run);
}
