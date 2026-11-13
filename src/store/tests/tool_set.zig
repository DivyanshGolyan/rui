//! Tool set Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const expectToolSetNames = shared_fixtures.expectToolSetNames;
const membershipToolSet = shared_fixtures.membershipToolSet;
const membership_records = shared_fixtures.membership_records;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingAgentSpec = shared_fixtures.testingAgentSpec;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;

test "loaded tools configure defaults equality membership and reachability" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

            var initial = try completeConfiguration("loaded-default", "", workspace, "model-a");
            const created = try storage.configure(&initial, .{});
            try std.testing.expect(created == .accepted);
            const session = created.accepted.session;
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));

            var update: wire_request.ConfigureCommand = .{};
            try update.session.set(session.slice());
            try update.key.set("loaded-equal");
            update.configuration.tools = try .of(&.{"bash"});
            update.configuration.loaded_tools = try .of(&.{"bash"});
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expect((try storage.configure(&update, .{})).accepted.replayed);
            var conflict = update;
            conflict.configuration.loaded_tools.state = .omitted;
            try std.testing.expect(try storage.configure(&conflict, .{}) == .conflict);

            try update.key.set("loaded-not-in-tools");
            update.configuration.loaded_tools = try .of(&.{"web_search"});
            const outside = try storage.configure(&update, .{});
            try std.testing.expect(outside == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_not_in_tools, outside.rejected.code);
            try std.testing.expect((try storage.configure(&update, .{})).rejected.replayed);

            try update.key.set("loaded-unreachable");
            update.configuration.loaded_tools = try .of(&.{});
            const unreachable_set = try storage.configure(&update, .{});
            try std.testing.expect(unreachable_set == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_unreachable, unreachable_set.rejected.code);

            // Membership is checked against saved tools if tools is omitted.
            try update.key.set("loaded-saved-tools");
            update.configuration.tools.state = .omitted;
            update.configuration.loaded_tools = try .of(&.{"web_search"});
            const saved_outside = try storage.configure(&update, .{});
            try std.testing.expect(saved_outside == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_not_in_tools, saved_outside.rejected.code);

            // An omitted loaded list continues to follow tools after equality.
            try update.key.set("loaded-follow-tools");
            update.configuration.tools = try .of(&.{ "bash", "web_search" });
            update.configuration.loaded_tools.state = .omitted;
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL AND revision=3", .{session.slice()}));

            // Explicit equality is also accepted on create, including empty sets.
            var equal = try completeConfiguration("loaded-create-equal", "", workspace, "model-a");
            equal.configuration.tools = try .of(&.{"bash"});
            equal.configuration.loaded_tools = try .of(&.{"bash"});
            try std.testing.expect(try storage.configure(&equal, .{}) == .accepted);
            try equal.key.set("loaded-create-empty");
            equal.configuration.tools = try .of(&.{});
            equal.configuration.loaded_tools = try .of(&.{});
            try std.testing.expect(try storage.configure(&equal, .{}) == .accepted);
            try equal.key.set("loaded-create-unreachable");
            equal.configuration.tools = try .of(&.{"bash"});
            const rejected_create = try storage.configure(&equal, .{});
            try std.testing.expect(rejected_create == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_unreachable, rejected_create.rejected.code);
        }
    }.run);
}

test "loaded tools preserve and intersect a saved subset through the tool set" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // The production tool set now makes strict loaded subsets reachable.
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var initial = try completeConfiguration("loaded-subset-create", "", workspace, "model-a");
            initial.configuration.tools = try .of(&.{ "bash", "find_tools", "web_search" });
            initial.configuration.loaded_tools = try .of(&.{ "bash", "find_tools" });
            const created = try storage.configure(&initial, .{});
            try std.testing.expect(created == .accepted);
            const session = created.accepted.session;
            const loaded_id = try store_testing.queryU64(&storage, "SELECT loaded_tool_set_id FROM session WHERE session_ref=?1", .{session.slice()});
            try std.testing.expect(loaded_id > 0);

            // An unrelated update must preserve the saved set id.
            var update: wire_request.ConfigureCommand = .{};
            try update.session.set(session.slice());
            try update.key.set("loaded-subset-label");
            update.configuration.label.state = .value;
            try update.configuration.label.value.set("same loaded subset");
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(loaded_id, try store_testing.queryU64(&storage, "SELECT loaded_tool_set_id FROM session WHERE session_ref=?1", .{session.slice()}));

            try update.key.set("loaded-subset-intersect");
            update.configuration.tools = try .of(&.{ "find_tools", "web_search" });
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session s JOIN tool_set_member m ON m.tool_set_id=s.loaded_tool_set_id " ++
                "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name='find_tools'", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT member_count FROM session s JOIN tool_set t ON t.tool_set_id=s.loaded_tool_set_id WHERE s.session_ref=?1", .{session.slice()}));

            // Re-adding a configured tool does not implicitly load it.
            try update.key.set("loaded-subset-grow-tools");
            update.configuration.tools = try .of(&.{ "bash", "find_tools", "web_search" });
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT member_count FROM session s JOIN tool_set t ON t.tool_set_id=s.loaded_tool_set_id WHERE s.session_ref=?1", .{session.slice()}));

            try update.key.set("loaded-subset-unreachable");
            update.configuration.tools = try .of(&.{"bash"});
            const unreachable_set = try storage.configure(&update, .{});
            try std.testing.expect(unreachable_set == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_unreachable, unreachable_set.rejected.code);

            // Intersection with an empty tools set is equality, not an
            // unreachable subset, and normalizes to NULL.
            try update.key.set("loaded-subset-clear");
            update.configuration.tools = try .of(&.{});
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));

            // Explicit equality uses NULL, including when clearing both sets.
            try update.key.set("loaded-subset-equal");
            update.configuration.tools = try .of(&.{ "bash", "find_tools", "web_search" });
            update.configuration.loaded_tools = try .of(&.{ "bash", "find_tools", "web_search" });
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
            try update.key.set("loaded-subset-empty");
            update.configuration.tools = try .of(&.{});
            update.configuration.loaded_tools.state = .omitted;
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
        }
    }.run);
}

const MembershipOutcome = enum { accepted, removed, unknown };

const MembershipCase = struct {
    name: []const u8,
    outcome: MembershipOutcome = .accepted,
    offered: bool = true,
    loaded: bool = true,
    // Change current Session settings only after freezing the Operation.
    change_after_admission: bool = false,
    withdraw: bool = false,
};

fn configureMembership(storage: *Store, tools: []const []const u8, loaded: ?[]const []const u8) !protocol.Bounded(protocol.max_session_bytes) {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var command = try store_testing.completeConfiguration("membership-config", "", try store_testing.canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    command.configuration.tools = try .of(tools);
    if (loaded) |names| command.configuration.loaded_tools = try .of(names);
    const reply = try storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

fn membershipCall(name: []const u8) TestingCall {
    const bash = std.mem.eql(u8, name, "bash");
    return .{
        .item_id = "membership-item",
        .name = name,
        .encoded_call_id = "membership-call",
        .decoded_call_id = "membership-call",
        .encoded_arguments = if (bash) "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"true\\\"}" else "{}",
        .decoded_arguments = if (bash) "{\"description\":\"Run\",\"cmd\":\"true\"}" else "{}",
    };
}

fn expectMembershipRemovedOutput(storage: *Store, binding: store_core.AttemptBinding) !void {
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expectEqual(binding.turn_id, continuation.turn_id);
    var view: historical_domain.HistoricalView = undefined;
    storage.openHistoricalView(continuation, &view);
    defer view.close();
    var position: u64 = 0;
    while (try view.nextEntry(position)) |entry| {
        position = entry.position;
        if (entry.kind == .tool_results) break;
    } else return error.MissingToolResults;
    const result = (try view.nextToolResult()).?;
    var output: historical_domain.HistoricalReader = undefined;
    try view.openContent(result.output, &output);
    defer output.close();
    var buffer: [tool_defs.removed_tool_result.len + 1]u8 = undefined;
    const count = try output.read(0, &buffer);
    try std.testing.expectEqualStrings(tool_defs.removed_tool_result, buffer[0..count]);
    try std.testing.expect((try view.nextToolResult()) == null);
}

test "tool membership settlement covers builtin provider MCP withdrawn unknown and loaded tools" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            var digests: [membership_records.len][32]u8 = undefined;
            const host_tool_set = membershipToolSet(&digests);
            const cases = [_]MembershipCase{
                .{ .name = "read_transcript" },
                .{ .name = "bash" },
                .{ .name = "web_search", .outcome = .unknown },
                .{ .name = "web_search", .outcome = .unknown, .withdraw = true },
                .{ .name = "fetch_page", .change_after_admission = true },
                .{ .name = "fetch_page", .outcome = .removed },
                .{ .name = "bash", .outcome = .removed },
                .{ .name = "never_offered", .outcome = .unknown, .offered = false },
                .{ .name = "fetch_page", .outcome = .unknown, .loaded = false, .change_after_admission = true },
            };
            for (cases) |test_case| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                var offered = [_][]const u8{ test_case.name, "find_tools" };
                if (std.mem.lessThan(u8, offered[1], offered[0])) std.mem.swap([]const u8, &offered[0], &offered[1]);
                const discovery_only = &.{"find_tools"};
                const session = try configureMembership(&storage, if (test_case.offered) &offered else discovery_only, if (test_case.loaded) null else discovery_only);
                if (test_case.outcome == .removed or test_case.withdraw) {
                    var update: wire_request.ConfigureCommand = .{ .session = session };
                    try update.key.set("membership-withdraw");
                    update.configuration.tools = try .of(discovery_only);
                    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                }
                try store_testing.submitTestMessage(&storage, &tmp, "membership-input", "membership-message", session.slice(), "classify");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (test_case.change_after_admission) {
                    var update: wire_request.ConfigureCommand = .{ .session = session };
                    try update.key.set("membership-current-only");
                    if (test_case.loaded) {
                        // Withdrawal now must not narrow the frozen offer.
                        update.configuration.tools = try .of(discovery_only);
                    } else {
                        // Loading now must not widen the frozen offer.
                        update.configuration.loaded_tools = try .of(&offered);
                    }
                    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation o JOIN session s ON s.session_ref=o.session_ref WHERE o.operation_id=?1 AND o.settings_revision<s.revision", .{binding.operation_id}));
                }
                const calls = [_]TestingCall{membershipCall(test_case.name)};
                const before = storage.testing_content_work.rounds;
                try settleCallsForTesting(&storage, &tmp, binding, "membership-output", &calls);
                const rounds = storage.testing_content_work.rounds - before;
                if (!engine.rerun and test_case.outcome == .removed and std.mem.eql(u8, test_case.name, "bash"))
                    try std.testing.expect(rounds <= 4);
                const accepted = test_case.outcome == .accepted;
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE operation_id=?1 AND call_ordinal=0 AND name_content_id IN (SELECT content_id FROM content WHERE digest=?2)", .{ binding.operation_id, store_testing.Blob{ .bytes = &protocol.contentDigest(test_case.name) } }));
                try std.testing.expectEqual(@as(u64, @intFromBool(accepted)), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE rejection_code IS NULL AND rejection_content_id IS NULL AND action_kind IS NOT NULL", .{}));
                try std.testing.expectEqual(@as(u64, @intFromBool(!accepted)), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE rejection_code='unknown_tool' AND rejection_content_id IS NOT NULL AND action_kind IS NULL", .{}));
                try std.testing.expectEqual(@as(u64, @intFromBool(accepted)), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE parent_operation_id=?1 AND call_ordinal=0 AND authorized=1 AND resolution_code IS NULL", .{binding.operation_id}));
                try std.testing.expectEqual(@as(u64, @intFromBool(accepted)), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
                if (test_case.outcome == .removed) try expectMembershipRemovedOutput(&storage, binding);
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "tool membership settlement fences an offered nonbuiltin with a corrupt owner" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            var digests: [membership_records.len][32]u8 = undefined;
            const host_tool_set = membershipToolSet(&digests);
            for ([_][]const u8{ "rui", "provider" }) |owner| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                const session = try configureMembership(&storage, &.{"fetch_page"}, null);
                try store_testing.submitTestMessage(&storage, &tmp, "membership-input", "membership-message", session.slice(), "classify");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                // Keep the row's SQL shape valid while corrupting its owner.
                try store_testing.exec(&storage, "UPDATE tool_record SET owner=?1,server='' WHERE name='fetch_page'", .{owner});
                const calls = [_]TestingCall{membershipCall("fetch_page")};
                try std.testing.expectError(error.CorruptStore, settleCallsForTesting(&storage, &tmp, binding, "membership-corrupt", &calls));
                try std.testing.expect(storage.isFenced());
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call", .{}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation", .{}));
            }
        }
    }.run);
}

test "tool membership rejects MCP tool set shadows of every builtin name" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            for (tool_defs.built_in_tool_set.records, 0..) |builtin, index| {
                var shadow_records: [tool_defs.built_in_tool_set.records.len]tool_defs.Record = undefined;
                @memcpy(&shadow_records, tool_defs.built_in_tool_set.records);
                shadow_records[index].owner = .mcp;
                shadow_records[index].server = "docs";
                var shadow_digests: [shadow_records.len][32]u8 = undefined;
                for (&shadow_records, &shadow_digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                const shadow: tool_defs.HostToolSet = .{ .records = &shadow_records, .digests = &shadow_digests };
                try std.testing.expectError(error.InvalidHostToolSet, storage.saveHostToolSet(&shadow));
                try std.testing.expect(!storage.isFenced());
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_record WHERE name=?1 AND owner='mcp'", .{builtin.name}));
            }
        }
    }.run);
}

test "MCP missing tools refuse create update creating Message and start_agent with one tool set rule" {
    try store_testing.forEachEngine(struct {
        fn check(reply: anytype, unavailable: bool, message: []const u8, replayed: bool) !void {
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqualStrings(if (unavailable) "mcp_server_unavailable" else "unknown_tool", @tagName(reply.rejected.code));
            var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer text.deinit();
            if (reply.rejected.message) |detail| try detail.write(&text.writer);
            try std.testing.expectEqualStrings(message, text.written());
            try std.testing.expectEqual(replayed, reply.rejected.replayed);
        }

        fn run(case: *store_testing.Case) !void {
            for (0..5) |mode| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer memory.deinit();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                // Host listing/fallback belongs to mcp/offered's tests. The
                // Store consumes only tool set records and configured names.
                const records = comptime testingHostToolRecords(&.{.{ .name = "kept", .owner = .mcp, .server = "notes", .description = "Saved tool", .input_schema = "{\"type\":\"object\"}" }});
                var digests: [records.len][32]u8 = undefined;
                for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                var host_tool_set = tool_defs.built_in_tool_set;
                if (mode == 2 or mode == 3) host_tool_set = .{ .records = &records, .digests = &digests };
                if (mode == 3) {
                    // Admit the unavailable server's copies through the same
                    // saved-tool-set interface a restarted Host reads.
                    try storage.saveHostToolSet(&host_tool_set);
                    const saved = (try storage.readHostToolSet(memory.allocator())).?;
                    host_tool_set = saved.toolSet();
                }
                host_tool_set.configured_servers = switch (mode) {
                    0, 2, 3 => &.{"notes"},
                    1 => &.{ "notes", "other" },
                    else => &.{},
                };
                try storage.saveHostToolSet(&host_tool_set);
                const unavailable = mode < 2;
                const detail = if (mode == 1)
                    "spec.tools: lookup is not a known tool; MCP servers notes, other are unavailable and may provide it"
                else if (unavailable)
                    "spec.tools: lookup is not a known tool; MCP server notes is unavailable and may provide it"
                else
                    "spec.tools: lookup is not a known tool";
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var create = try completeConfiguration("mcp-missing-parent", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                const parent_names: []const []const u8 = if (mode == 2 or mode == 3) &.{ "kept", "start_agent" } else &.{"start_agent"};
                create.configuration.tools = try .of(parent_names);
                const parent = (try storage.configure(&create, .{})).accepted.session;

                try create.key.set("mcp-missing-create");
                // Captured specs hold canonical name order; skip known names.
                create.configuration.tools = try .of(&.{ "bash", "lookup", "zz_absent" });
                try check(try storage.configure(&create, .{}), unavailable, detail, false);
                try check(try storage.configure(&create, .{}), unavailable, detail, true);
                var update: wire_request.ConfigureCommand = .{ .session = parent };
                try update.key.set("mcp-missing-update");
                update.configuration.tools = create.configuration.tools;
                try check(try storage.configure(&update, .{}), unavailable, detail, false);
                try check(try storage.configure(&update, .{}), unavailable, detail, true);
                var message: wire_request.MessageCommand = .{ .configuration = create.configuration, .text = .{ .state = .value, .borrowed = "task".ptr, .length = 4, .digest = protocol.contentDigest("task") } };
                try message.key.set("mcp-missing-message");
                try check(storage.submitMessageWithModel(&message, null, .{}), unavailable, detail, false);
                try check(storage.submitMessageWithModel(&message, null, .{}), unavailable, detail, true);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                const unchanged = try storage.inspectSessionForTesting(parent.slice());
                try expectToolSetNames(&storage, unchanged.tool_set_id, parent_names);

                // Parent creation shares the tool set refusal before narrowing:
                // never invent ownership for a name absent from every record.
                var child: wire_request.ConfigureCommand = .{};
                try child.key.set("mcp-missing-parent-create");
                child.configuration = try testingAgentSpec(&.{"lookup"}, "ask");
                child.configuration.parent.state = .value;
                try child.configuration.parent.value.set(parent.slice());
                try check(try storage.configure(&child, .{}), unavailable, detail, false);
                try check(try storage.configure(&child, .{}), unavailable, detail, true);
                var parent_message = message;
                try parent_message.key.set("mcp-missing-parent-message");
                parent_message.configuration = child.configuration;
                try check(storage.submitMessageWithModel(&parent_message, null, .{}), unavailable, detail, false);
                try check(storage.submitMessageWithModel(&parent_message, null, .{}), unavailable, detail, true);

                // A known saved copy is admitted by every spec entry point.
                if (mode == 3) {
                    try child.key.set("mcp-kept-parent-create");
                    child.configuration.tools = try .of(&.{"kept"});
                    const created = try storage.configure(&child, .{});
                    try std.testing.expect(created == .accepted);
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND parent_ref=?2", .{ created.accepted.session.slice(), parent.slice() }));
                    try parent_message.key.set("mcp-kept-parent-message");
                    parent_message.configuration = child.configuration;
                    try create.key.set("mcp-kept-create");
                    create.configuration.tools = try .of(&.{"kept"});
                    try std.testing.expect(try storage.configure(&create, .{}) == .accepted);
                    try update.key.set("mcp-kept-update");
                    update.configuration.tools = try .of(&.{ "kept", "start_agent" });
                    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                }

                try submitTestMessage(&storage, &tmp, "mcp-parent-message", "mcp-parent-message", parent.slice(), "start a child");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const call: TestingCall = .{ .item_id = "missing-child", .name = "start_agent", .encoded_call_id = "missing-child", .decoded_call_id = "missing-child", .encoded_arguments = "{}", .decoded_arguments = "{}" };
                try settleCallsForTesting(&storage, &tmp, model, "mcp-child-calls", &.{call});
                const action = (try storage.nextCoreWork()).?.action;
                var spec = try testingAgentSpec(if (mode == 3) &.{"kept"} else &.{"lookup"}, "ask");
                const result = try storage.startAgent(action.binding, parent.slice(), "read", true, &spec, null, .{});
                if (mode == 3) {
                    try std.testing.expectEqual(command_domain.AgentStart.started, result);
                    try std.testing.expect(storage.submitMessageWithModel(&parent_message, null, .{}) == .accepted);
                    try message.key.set("mcp-kept-message");
                    message.configuration.?.tools = try .of(&.{"kept"});
                    try std.testing.expect(storage.submitMessageWithModel(&message, null, .{}) == .accepted);
                } else {
                    try std.testing.expectEqual(command_domain.AgentStart.failed, result);
                    const text = if (unavailable)
                        try std.fmt.allocPrint(memory.allocator(), "{s} (mcp_server_unavailable). Nothing was started.", .{detail})
                    else
                        "spec.tools: lookup is not a known tool (unknown_tool). Nothing was started.";
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ action.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(text) } }));
                }
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}
