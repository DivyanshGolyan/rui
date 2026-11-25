const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const tool_record = @import("../../tool_record.zig");
const command_input = @import("../../command_input.zig");
const tool_offer_domain = @import("../domain/tool_offer.zig");
const tool_set_domain = @import("../domain/tool_set.zig");
const store_core = @import("../Store.zig");
const app_tools = @import("../../tool_record.zig").app_tools;
const Store = store_core.Store;
const command_domain = @import("../domain/command.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const TestingReader = store_testing.TestingReader;
const TestingPage = store_testing.TestingPage;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const expectToolSetNames = shared_fixtures.expectToolSetNames;
const membershipToolSet = shared_fixtures.membershipToolSet;
const membership_records = shared_fixtures.membership_records;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const AttemptBinding = store_core.AttemptBinding;
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

            try update.key.set("loaded-saved-tools");
            update.configuration.tools.state = .omitted;
            update.configuration.loaded_tools = try .of(&.{"web_search"});
            const saved_outside = try storage.configure(&update, .{});
            try std.testing.expect(saved_outside == .rejected);
            try std.testing.expectEqual(protocol.ConfigurationRejection.loaded_tools_not_in_tools, saved_outside.rejected.code);

            try update.key.set("loaded-follow-tools");
            update.configuration.tools = try .of(&.{ "bash", "web_search" });
            update.configuration.loaded_tools.state = .omitted;
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 3), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL AND revision=3", .{session.slice()}));

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

            try update.key.set("loaded-subset-grow-tools");
            update.configuration.tools = try .of(&.{ "bash", "find_tools", "web_search" });
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT member_count FROM session s JOIN tool_set t ON t.tool_set_id=s.loaded_tool_set_id WHERE s.session_ref=?1", .{session.slice()}));

            try update.key.set("loaded-subset-fallback");
            update.configuration.tools = try .of(&.{"bash"});
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));

            try update.key.set("loaded-subset-clear");
            update.configuration.tools = try .of(&.{});
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND loaded_tool_set_id IS NULL", .{session.slice()}));

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

// All subsets of an ordinary Action, discovery, and a provider tool, in bit order.
const loaded_tool_selections = [_][]const []const u8{
    &.{},
    &.{"bash"},
    &.{"find_tools"},
    &.{ "bash", "find_tools" },
    &.{"web_search"},
    &.{ "bash", "web_search" },
    &.{ "find_tools", "web_search" },
    &.{ "bash", "find_tools", "web_search" },
};

fn expectLoadedRevision(storage: *Store, session: []const u8, revision: u64, tools: []const []const u8, loaded: []const []const u8) !void {
    const saved_tools = try store_testing.queryU64(storage, "SELECT tool_set_id FROM session_revision WHERE session_ref=?1 AND revision=?2", .{ session, revision });
    const saved_loaded = try store_testing.queryU64(storage, "SELECT coalesce(loaded_tool_set_id,tool_set_id) FROM session_revision WHERE session_ref=?1 AND revision=?2", .{ session, revision });
    try expectToolSetNames(storage, saved_tools, tools);
    try expectToolSetNames(storage, saved_loaded, loaded);
    try std.testing.expectEqual(@as(u64, @intFromBool(tools.len == loaded.len)), try store_testing.queryU64(storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1 AND revision=?2 AND loaded_tool_set_id IS NULL", .{ session, revision }));
}

fn expectCurrentLoadedRevision(storage: *Store, session: []const u8, revision: u64) !void {
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(storage, "SELECT count(*) FROM session s JOIN session_revision r ON r.session_ref=s.session_ref AND r.revision=s.revision " ++
        "WHERE s.session_ref=?1 AND s.revision=?2 AND s.tool_set_id=r.tool_set_id AND coalesce(s.loaded_tool_set_id,0)=coalesce(r.loaded_tool_set_id,0)", .{ session, revision }));
}

test "loaded tools configure implicit changes cover every three-tool intent and replacement" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            // Every valid prior intent. Expected replacements are explicit oracles,
            // including empty and nonempty intersections without discovery.
            const Prior = struct { tools: usize, loaded: usize, expected: [8]usize };
            const prior_intents = [_]Prior{
                .{ .tools = 0, .loaded = 0, .expected = .{ 0, 1, 2, 3, 4, 5, 6, 7 } },
                .{ .tools = 1, .loaded = 1, .expected = .{ 0, 1, 2, 3, 4, 5, 6, 7 } },
                .{ .tools = 2, .loaded = 2, .expected = .{ 0, 1, 2, 3, 4, 5, 6, 7 } },
                .{ .tools = 3, .loaded = 3, .expected = .{ 0, 1, 2, 3, 4, 5, 6, 7 } },
                .{ .tools = 4, .loaded = 4, .expected = .{ 0, 1, 2, 3, 4, 5, 6, 7 } },
                .{ .tools = 5, .loaded = 5, .expected = .{ 0, 1, 2, 3, 4, 5, 6, 7 } },
                .{ .tools = 6, .loaded = 6, .expected = .{ 0, 1, 2, 3, 4, 5, 6, 7 } },
                .{ .tools = 7, .loaded = 7, .expected = .{ 0, 1, 2, 3, 4, 5, 6, 7 } },
                .{ .tools = 3, .loaded = 2, .expected = .{ 0, 1, 2, 2, 4, 5, 2, 2 } },
                .{ .tools = 6, .loaded = 2, .expected = .{ 0, 1, 2, 2, 4, 5, 2, 2 } },
                .{ .tools = 7, .loaded = 2, .expected = .{ 0, 1, 2, 2, 4, 5, 2, 2 } },
                .{ .tools = 7, .loaded = 3, .expected = .{ 0, 1, 2, 3, 4, 5, 2, 3 } },
                .{ .tools = 7, .loaded = 6, .expected = .{ 0, 1, 2, 2, 4, 5, 6, 6 } },
            };
            for (prior_intents, 0..) |prior, prior_index| for (loaded_tool_selections, 0..) |next_tools, next_index| {
                var key_buffer: [64]u8 = undefined;
                var initial = try completeConfiguration(try std.fmt.bufPrint(&key_buffer, "implicit-create-{d}-{d}", .{ prior_index, next_index }), "", workspace, "model-a");
                initial.configuration.tools = try .of(loaded_tool_selections[prior.tools]);
                initial.configuration.loaded_tools = try .of(loaded_tool_selections[prior.loaded]);
                const created = try storage.configure(&initial, .{});
                try std.testing.expect(created == .accepted);
                const session = created.accepted.session.slice();

                var update: wire_request.ConfigureCommand = .{};
                try update.key.set(try std.fmt.bufPrint(&key_buffer, "implicit-update-{d}-{d}", .{ prior_index, next_index }));
                try update.session.set(session);
                update.configuration.tools = try .of(next_tools);
                const changed = try storage.configure(&update, .{});
                try std.testing.expect(changed == .accepted);
                try std.testing.expectEqual(@as(u64, 2), changed.accepted.revision);
                try expectLoadedRevision(&storage, session, 2, next_tools, loaded_tool_selections[prior.expected[next_index]]);
                try expectCurrentLoadedRevision(&storage, session, 2);
                try expectLoadedRevision(&storage, session, 1, loaded_tool_selections[prior.tools], loaded_tool_selections[prior.loaded]);
                try std.testing.expect((try storage.configure(&update, .{})).accepted.replayed);
                try expectCurrentLoadedRevision(&storage, session, 2);
            };
        }
    }.run);
}

test "loaded tools configure explicit selections retain membership and reachability refusals" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const Outcome = enum { accepted, outside, unreachable_set };
            const a = Outcome.accepted;
            const o = Outcome.outside;
            const u = Outcome.unreachable_set;
            // Rows select tools; columns select explicitly loaded tools.
            const outcomes = [8][8]Outcome{
                .{ a, o, o, o, o, o, o, o },
                .{ u, a, o, o, o, o, o, o },
                .{ u, o, a, o, o, o, o, o },
                .{ u, u, a, a, o, o, o, o },
                .{ u, o, o, o, a, o, o, o },
                .{ u, u, o, o, u, a, o, o },
                .{ u, o, a, o, u, o, a, o },
                .{ u, u, a, a, u, u, a, a },
            };
            for ([_]bool{ false, true }) |explicit_tools| for (loaded_tool_selections, 0..) |tools, tools_index| for (loaded_tool_selections, 0..) |loaded, loaded_index| {
                var key_buffer: [64]u8 = undefined;
                var initial = try completeConfiguration(try std.fmt.bufPrint(&key_buffer, "explicit-create-{}-{d}-{d}", .{ explicit_tools, tools_index, loaded_index }), "", workspace, "model-a");
                initial.configuration.tools = try .of(tools);
                const created = try storage.configure(&initial, .{});
                try std.testing.expect(created == .accepted);
                const session = created.accepted.session.slice();
                var update: wire_request.ConfigureCommand = .{};
                try update.key.set(try std.fmt.bufPrint(&key_buffer, "explicit-update-{}-{d}-{d}", .{ explicit_tools, tools_index, loaded_index }));
                try update.session.set(session);
                if (explicit_tools) update.configuration.tools = try .of(tools);
                update.configuration.loaded_tools = try .of(loaded);
                const result = try storage.configure(&update, .{});
                const outcome = outcomes[tools_index][loaded_index];
                switch (outcome) {
                    .accepted => {
                        try std.testing.expect(result == .accepted);
                        try expectLoadedRevision(&storage, session, 2, tools, loaded);
                        try expectCurrentLoadedRevision(&storage, session, 2);
                    },
                    .outside, .unreachable_set => {
                        try std.testing.expect(result == .rejected);
                        try std.testing.expectEqual(if (outcome == .outside) protocol.ConfigurationRejection.loaded_tools_not_in_tools else protocol.ConfigurationRejection.loaded_tools_unreachable, result.rejected.code);
                        try std.testing.expect((try storage.configure(&update, .{})).rejected.replayed);
                        try expectCurrentLoadedRevision(&storage, session, 1);
                        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1", .{session}));
                    },
                }
                try expectLoadedRevision(&storage, session, 1, tools, tools);
            };
        }
    }.run);
}

test "loaded tools configure fallback changes saved and resumed Sessions only with explicit tools" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const original_tools = loaded_tool_selections[7];
            const original_loaded = loaded_tool_selections[3];
            // Both an empty intersection and a surviving ordinary tool need fallback.
            for ([_]usize{ 4, 5 }) |next_index| {
                const next_tools = loaded_tool_selections[next_index];
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var session: protocol.Bounded(protocol.session_id_bytes) = .{};
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    var initial = try completeConfiguration("fallback-saved-create", "", workspace, "model-a");
                    initial.configuration.tools = try .of(original_tools);
                    initial.configuration.loaded_tools = try .of(original_loaded);
                    const created = try storage.configure(&initial, .{});
                    try std.testing.expect(created == .accepted);
                    try session.set(created.accepted.session.slice());
                    try store_testing.answerTestTurn(&storage, &tmp, session.slice(), "fallback-first", &.{.{ .encoded = "done", .decoded = "done" }});
                }
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    try expectLoadedRevision(&storage, session.slice(), 1, original_tools, original_loaded);
                    try expectCurrentLoadedRevision(&storage, session.slice(), 1);
                    try store_testing.answerTestTurn(&storage, &tmp, session.slice(), "fallback-resume-before", &.{.{ .encoded = "done", .decoded = "done" }});
                    try expectCurrentLoadedRevision(&storage, session.slice(), 1);

                    var update: wire_request.ConfigureCommand = .{};
                    try update.session.set(session.slice());
                    try update.key.set("fallback-label");
                    update.configuration.label.state = .value;
                    try update.configuration.label.value.set("Resumed subset");
                    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                    try expectLoadedRevision(&storage, session.slice(), 2, original_tools, original_loaded);
                    try expectCurrentLoadedRevision(&storage, session.slice(), 2);
                    try store_testing.answerTestTurn(&storage, &tmp, session.slice(), "fallback-resume-label", &.{.{ .encoded = "done", .decoded = "done" }});

                    try update.key.set("fallback-tools");
                    update.configuration.label.state = .omitted;
                    update.configuration.tools = try .of(next_tools);
                    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                    try expectLoadedRevision(&storage, session.slice(), 3, next_tools, next_tools);
                    try expectCurrentLoadedRevision(&storage, session.slice(), 3);
                    try expectLoadedRevision(&storage, session.slice(), 1, original_tools, original_loaded);
                    try expectLoadedRevision(&storage, session.slice(), 2, original_tools, original_loaded);
                    // Requests completed before the change keep their frozen offers.
                    const old_offer = try store_testing.queryU64(&storage, "SELECT tool_set_id FROM model_operation WHERE session_ref=?1 AND settings_revision=2", .{session.slice()});
                    try expectToolSetNames(&storage, old_offer, original_loaded);
                    try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE session_ref=?1 AND settings_revision=1 AND tool_set_id=?2", .{ session.slice(), old_offer }));
                }
                {
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    try expectLoadedRevision(&storage, session.slice(), 3, next_tools, next_tools);
                    try expectCurrentLoadedRevision(&storage, session.slice(), 3);
                    try submitTestMessage(&storage, &tmp, "fallback-resume-after", "fallback-resume-after", session.slice(), "continue");
                    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    var view: TestingPage = undefined;
                    view.open(&storage, binding);
                    defer view.close();
                    const settings = try shared_fixtures.testSettings(&view);
                    try std.testing.expectEqual(@as(u64, @intCast(next_tools.len)), settings.tool_count);
                    var tool: historical_domain.HistoricalTool = .{};
                    for (next_tools) |name| {
                        try std.testing.expect(try view.nextTool(&tool));
                        try std.testing.expectEqualStrings(name, tool.name.slice());
                    }
                    try std.testing.expect(!try view.nextTool(&tool));
                }
            }
        }
    }.run);
}

const MembershipOutcome = enum { accepted, removed, unknown };

const MembershipCase = struct {
    name: []const u8,
    outcome: MembershipOutcome = .accepted,
    offered: bool = true,
    loaded: bool = true,
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

fn expectReportedToolNames(value: std.json.Value, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, value.array.items.len);
    for (expected, value.array.items) |name, actual| try std.testing.expectEqualStrings(name, actual.string);
}

fn expectReportedToolsField(value: std.json.Value, expected: *const protocol.ToolsField) !void {
    try std.testing.expectEqual(@as(usize, expected.count), value.array.items.len);
    var names = expected.iterator();
    for (value.array.items) |actual| try std.testing.expectEqualStrings(names.next().?, actual.string);
    try std.testing.expect(names.next() == null);
}

fn expectFrozenToolNames(storage: *Store, binding: store_core.AttemptBinding, expected: []const []const u8) !void {
    var view: TestingPage = undefined;
    view.open(storage, binding);
    defer view.close();
    var settings: historical_domain.HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expectEqual(@as(u64, expected.len), settings.tool_count);
    var tool: historical_domain.HistoricalTool = .{};
    for (expected) |name| {
        try std.testing.expect(try view.nextTool(&tool));
        try std.testing.expectEqualStrings(name, tool.name.slice());
    }
    try std.testing.expect(!try view.nextTool(&tool));
}

test "tool inspection distinguishes allowed loaded and frozen operation offers through edits" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            var digests: [membership_records.len][32]u8 = undefined;
            const host_tool_set = membershipToolSet(&digests);
            const allowed: []const []const u8 = &.{ "bash", "fetch_page", "find_tools" };
            const loaded: []const []const u8 = &.{ "fetch_page", "find_tools" };
            const cases = [_]struct {
                allowed: []const []const u8,
                loaded: ?[]const []const u8,
                effective: []const []const u8,
                withdraw_mcp: bool = false,
            }{
                .{ .allowed = allowed, .loaded = loaded, .effective = loaded },
                .{ .allowed = allowed, .loaded = null, .effective = allowed },
                .{ .allowed = &.{}, .loaded = &.{}, .effective = &.{} },
                .{ .allowed = &.{"bash"}, .loaded = null, .effective = &.{"bash"} },
                .{ .allowed = allowed, .loaded = loaded, .effective = &.{"find_tools"}, .withdraw_mcp = true },
            };
            for (cases) |scenario| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                const session = try configureMembership(&storage, scenario.allowed, scenario.loaded);
                if (scenario.withdraw_mcp) try storage.saveHostToolSet(&tool_defs.built_in_tool_set);
                try submitTestMessage(&storage, &tmp, "inspection-message", "inspection-message", session.slice(), "Inspect tool intent");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try expectFrozenToolNames(&storage, binding, scenario.effective);

                var update: wire_request.ConfigureCommand = .{};
                update.session = session;
                try update.key.set("inspection-edit");
                const next_allowed: []const []const u8 = &.{ "find_tools", "web_search" };
                const next_loaded: []const []const u8 = &.{"find_tools"};
                update.configuration.tools = try .of(next_allowed);
                update.configuration.loaded_tools = try .of(next_loaded);
                try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
                    const bytes = try shared_fixtures.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, profile);
                    defer std.testing.allocator.free(bytes);
                    const report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                    defer report.deinit();
                    const settings = report.value.object.get("session").?.object;
                    try expectReportedToolNames(settings.get("tools").?, next_allowed);
                    try expectReportedToolNames(settings.get("loaded_tools").?, next_loaded);
                    if (profile == .full) {
                        const full = report.value.object.get("full").?.object;
                        const revisions = full.get("session_revisions").?.array.items;
                        try std.testing.expectEqual(@as(usize, 2), revisions.len);
                        try expectReportedToolNames(revisions[0].object.get("tools").?, scenario.allowed);
                        try expectReportedToolNames(revisions[0].object.get("loaded_tools").?, scenario.loaded orelse scenario.allowed);
                        try expectReportedToolNames(revisions[1].object.get("tools").?, next_allowed);
                        try expectReportedToolNames(revisions[1].object.get("loaded_tools").?, next_loaded);
                        const operations = full.get("model_operations").?.array.items;
                        try std.testing.expectEqual(@as(usize, 1), operations.len);
                        try std.testing.expectEqualStrings("1", operations[0].object.get("settings_revision").?.string);
                        const offered = operations[0].object.get("offered_tools") orelse return error.MissingFrozenOperationOffer;
                        try expectReportedToolNames(offered, scenario.effective);
                    }
                }
                try expectFrozenToolNames(&storage, binding, scenario.effective);
            }
        }
    }.run);
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
    var view: TestingPage = undefined;
    view.open(storage, continuation);
    defer view.close();
    var position: u64 = 0;
    while (try view.nextEntry(position)) |entry| {
        position = entry.position;
        if (entry.kind == .tool_results) break;
    } else return error.MissingToolResults;
    const result = (try view.nextToolResult()).?;
    var output: TestingReader = undefined;
    try view.openContent(result.output.?, &output);
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
                        update.configuration.tools = try .of(discovery_only);
                    } else {
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
                const records = comptime testingHostToolRecords(&.{.{ .name = "kept", .owner = .mcp, .server = "notes", .description = "Saved tool", .input_schema = "{\"type\":\"object\"}" }});
                var digests: [records.len][32]u8 = undefined;
                for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                var host_tool_set = tool_defs.built_in_tool_set;
                if (mode == 2 or mode == 3) host_tool_set = .{ .records = &records, .digests = &digests };
                if (mode == 3) {
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
                const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
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

test "a replaced Host tool set can be freed once the save returns" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

            const records_source = comptime testingHostToolRecords(&.{.{ .name = "kept", .owner = .mcp, .server = "notes", .description = "Saved tool", .input_schema = "{\"type\":\"object\"}" }});
            var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
            const first_records = try memory.allocator().dupe(tool_defs.Record, &records_source);
            const first_digests = try memory.allocator().alloc([32]u8, first_records.len);
            for (first_records, first_digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            var first: tool_defs.HostToolSet = .{
                .records = first_records,
                .digests = first_digests,
                .configured_servers = try memory.allocator().dupe([]const u8, &.{"notes"}),
            };
            try storage.saveHostToolSet(&first);

            var second = tool_defs.built_in_tool_set;
            second.configured_servers = &.{"notes"};
            try storage.saveHostToolSet(&second);
            memory.deinit();

            var create = try completeConfiguration("replaced-set-create", "", workspace, "model-a");
            create.configuration.tools = try .of(&.{ "bash", "lookup" });
            const reply = try storage.configure(&create, .{});
            try std.testing.expect(reply == .rejected);
            try std.testing.expectEqualStrings("mcp_server_unavailable", @tagName(reply.rejected.code));
            var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer text.deinit();
            if (reply.rejected.message) |detail| try detail.write(&text.writer);
            try std.testing.expectEqualStrings("spec.tools: lookup is not a known tool; MCP server notes is unavailable and may provide it", text.written());
            try std.testing.expectEqual(@as(*const tool_defs.HostToolSet, &second), storage.hostTools().host_tool_set);
        }
    }.run);
}

test "a model admission freezes an offer the Host's tool set no longer holds, and a later one reuses the set it saved" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const records = comptime testingHostToolRecords(&.{
                .{ .name = "read_page", .owner = .mcp, .server = "docs", .description = "Read a page.", .input_schema = "{\"type\":\"object\"}" },
                .{ .name = "write_page", .owner = .mcp, .server = "docs", .description = "Write a page.", .input_schema = "{\"type\":\"object\"}" },
            });
            const digests = comptime blk: {
                @setEvalBranchQuota(10_000_000);
                var out: [records.len][32]u8 = undefined;
                for (&records, &out) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                break :blk out;
            };
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var configure = try completeConfiguration("stale-offer-one", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            configure.configuration.tools = try .of(&.{ "read_page", "write_page" });
            const one = (try storage.configure(&configure, .{})).accepted.session;
            try configure.key.set("stale-offer-two");
            const two = (try storage.configure(&configure, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "stale-offer-input-one", "stale-offer-message-one", one.slice(), "one");
            try submitTestMessage(&storage, &tmp, "stale-offer-input-two", "stale-offer-message-two", two.slice(), "two");
            const offered = try store_testing.queryU64(&storage, "SELECT tool_set_id FROM session WHERE session_ref=?1", .{one.slice()});
            const kept = comptime testingHostToolRecords(&.{
                .{ .name = "read_page", .owner = .mcp, .server = "docs", .description = "Read a page.", .input_schema = "{\"type\":\"object\"}" },
            });
            const kept_digests = comptime blk: {
                @setEvalBranchQuota(10_000_000);
                var out: [kept.len][32]u8 = undefined;
                for (&kept, &out) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                break :blk out;
            };
            const withdrawn: tool_defs.HostToolSet = .{ .records = &kept, .digests = &kept_digests };
            try storage.saveHostToolSet(&withdrawn);
            const sets = try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{});

            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(sets + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{}));
            const frozen = try store_testing.queryU64(&storage, "SELECT tool_set_id FROM model_operation WHERE operation_id=?1", .{first.operation_id});
            try std.testing.expect(frozen != offered);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member m JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE m.tool_set_id=?1 AND t.name='read_page'", .{frozen}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member m JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE m.tool_set_id=?1 AND t.name='write_page'", .{frozen}));

            const second = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(sets + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{}));
            try std.testing.expectEqual(frozen, try store_testing.queryU64(&storage, "SELECT tool_set_id FROM model_operation WHERE operation_id=?1", .{second.operation_id}));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "stop_action is offered exactly when it is loaded" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for (0..4) |mask| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("paired-config", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                configure.configuration.tools = try switch (mask) {
                    0 => @import("../../command_input.zig").ToolsField.of(&.{}),
                    1 => @import("../../command_input.zig").ToolsField.of(&.{"read_action"}),
                    2 => @import("../../command_input.zig").ToolsField.of(&.{"stop_action"}),
                    3 => @import("../../command_input.zig").ToolsField.of(&.{ "read_action", "stop_action" }),
                    else => unreachable,
                };
                const session = (try storage.configure(&configure, .{})).accepted.session;
                try submitTestMessage(&storage, &tmp, "paired-input", "paired-input", session.slice(), "check tools");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const frozen = try store_testing.queryU64(&storage, "SELECT tool_set_id FROM model_operation WHERE operation_id=?1", .{model.operation_id});
                const count = try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member m JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE m.tool_set_id=?1 AND t.name='stop_action'", .{frozen});
                try std.testing.expectEqual(@as(u64, if (mask & 2 != 0) 1 else 0), count);
            }
        }
    }.run);
}

test "the offer at the settings limit holds exactly the loaded tools" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const extras = comptime blk: {
                @setEvalBranchQuota(10_000_000);
                var records: [126]tool_defs.Record = undefined;
                const remaining_bytes = protocol.max_tool_list_name_bytes - "find_tools".len - "read_action".len;
                for (&records, 0..) |*record, i| {
                    const prefix = std.fmt.comptimePrint("stub{d:0>3}", .{i});
                    const length = remaining_bytes / records.len + @intFromBool(i < remaining_bytes % records.len);
                    record.* = .{
                        .name = prefix ++ @as([length - prefix.len]u8, @splat('x')),
                        .remote_name = prefix ++ @as([length - prefix.len]u8, @splat('x')),
                        .owner = .mcp,
                        .server = "docs",
                        .description = "Read a page.",
                        .input_schema = "{\"type\":\"object\"}",
                    };
                }
                break :blk records;
            };
            const records = comptime testingHostToolRecords(&extras);
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            const host_tools: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            for ([_]usize{ 127, 128 }) |count| {
                for ([_]bool{ false, true }) |explicit| {
                    for ([_]bool{ false, true }) |loaded_read| {
                        var tmp = std.testing.tmpDir(.{});
                        defer tmp.cleanup();
                        var storage: Store = undefined;
                        try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tools });
                        defer storage.close() catch unreachable;
                        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                        var configure = try completeConfiguration("offer-limit", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                        var allowed: protocol.ToolsField = .{ .state = .value };
                        var loaded: protocol.ToolsField = .{ .state = .value };
                        try allowed.insert("find_tools");
                        try loaded.insert("find_tools");
                        try allowed.insert("read_action");
                        if (loaded_read) try loaded.insert("read_action");
                        if (explicit) {
                            try allowed.insert("stop_action");
                            try loaded.insert("stop_action");
                        }
                        for (extras[0 .. count - 2 - @intFromBool(explicit)]) |record| {
                            try allowed.insert(record.name);
                            try loaded.insert(record.name);
                        }
                        if (count == protocol.max_tools and !explicit) {
                            try std.testing.expectEqual(protocol.max_tool_list_name_bytes, allowed.names.len - (allowed.count - 1));
                            var overflow = allowed;
                            try std.testing.expectError(error.InvalidJsonShape, overflow.insert("stop_action"));
                        }
                        configure.configuration.tools = allowed;
                        configure.configuration.loaded_tools = loaded;
                        const session = (try storage.configure(&configure, .{})).accepted.session;
                        try submitTestMessage(&storage, &tmp, "offer-limit-input", "offer-limit-input", session.slice(), "check");
                        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                        var page: TestingPage = undefined;
                        page.open(&storage, binding);
                        defer page.close();
                        var settings: historical_domain.HistoricalSettings = undefined;
                        try page.settings(&settings);
                        const expected = count - @as(usize, @intFromBool(!loaded_read));
                        try std.testing.expectEqual(@as(u64, @intCast(expected)), settings.tool_count);
                        for ([_]protocol.ReportProfile{ .current, .full }) |profile| {
                            const bytes = try shared_fixtures.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, profile);
                            defer std.testing.allocator.free(bytes);
                            const report = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
                            defer report.deinit();
                            const current = report.value.object.get("session").?.object;
                            try expectReportedToolsField(current.get("tools").?, &allowed);
                            try expectReportedToolsField(current.get("loaded_tools").?, &loaded);
                            if (profile == .full) {
                                const full = report.value.object.get("full").?.object;
                                const revisions = full.get("session_revisions").?.array.items;
                                try std.testing.expectEqual(@as(usize, 1), revisions.len);
                                try expectReportedToolsField(revisions[0].object.get("tools").?, &allowed);
                                try expectReportedToolsField(revisions[0].object.get("loaded_tools").?, &loaded);
                                const operations = full.get("model_operations").?.array.items;
                                try std.testing.expectEqual(@as(usize, 1), operations.len);
                                const offered = operations[0].object.get("offered_tools").?.array.items;
                                try std.testing.expectEqual(expected, offered.len);
                                var previous: []const u8 = "";
                                var name_bytes: usize = 0;
                                var tool: historical_domain.HistoricalTool = .{};
                                for (offered) |item| {
                                    const name = item.string;
                                    try std.testing.expect(std.mem.lessThan(u8, previous, name));
                                    try std.testing.expect(loaded.contains(name));
                                    try std.testing.expect(try page.nextTool(&tool));
                                    try std.testing.expectEqualStrings(name, tool.name.slice());
                                    previous = name;
                                    name_bytes += name.len;
                                }
                                try std.testing.expect(!try page.nextTool(&tool));
                                if (count == protocol.max_tools and !explicit and loaded_read) {
                                    try std.testing.expectEqual(@import("../../tool_name.zig").max_list_name_bytes, name_bytes);
                                }
                            }
                        }
                        try std.testing.expect(!storage.isFenced());
                    }
                }
            }
        }
    }.run);
}

test "creation receipts retain maximum configured and loaded tools" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const extras = comptime blk: {
                @setEvalBranchQuota(10_000_000);
                var records: [127]tool_defs.Record = undefined;
                const bytes = protocol.max_tool_list_name_bytes - "find_tools".len;
                for (&records, 0..) |*record, index| {
                    const prefix = std.fmt.comptimePrint("stub{d:0>3}", .{index});
                    const length = bytes / records.len + @intFromBool(index < bytes % records.len);
                    record.* = .{
                        .name = prefix ++ @as([length - prefix.len]u8, @splat('x')),
                        .remote_name = prefix ++ @as([length - prefix.len]u8, @splat('x')),
                        .owner = .mcp,
                        .server = "docs",
                        .description = "Read a page.",
                        .input_schema = "{\"type\":\"object\"}",
                    };
                }
                break :blk records;
            };
            const records = comptime testingHostToolRecords(&extras);
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            const host_tools: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            var allowed: protocol.ToolsField = .{ .state = .value };
            try allowed.insert("find_tools");
            for (extras) |record| try allowed.insert(record.name);
            try std.testing.expectEqual(protocol.max_tools, allowed.count);
            try std.testing.expectEqual(protocol.max_tool_list_name_bytes, allowed.names.len - (allowed.count - 1));
            var expected: [@import("../../tool_name.zig").max_names_bytes]u8 = undefined;
            const expected_names = expected[0..allowed.names.len];
            for (allowed.names.slice(), expected_names) |byte, *out| out.* = if (byte == ' ') ',' else byte;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("large-tools-config", "", workspace, "model-a");
            create.configuration.tools = allowed;
            create.configuration.loaded_tools = allowed;
            var message: wire_request.MessageCommand = .{ .configuration = create.configuration };
            try message.key.set("large-tools-message");
            message.text = try shared_fixtures.testingBytesContent(&tmp, "large-tools-input", "initial");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            var config_session: protocol.Bounded(protocol.max_session_bytes) = undefined;
            var message_session: protocol.Bounded(protocol.max_session_bytes) = undefined;
            {
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tools });
                defer storage.close() catch unreachable;
                var configured_receipt: @import("../../creation_receipt.zig").Configuration = undefined;
                const configured = try storage.configureInto(&create, &configured_receipt, .{});
                var submitted_receipt: @import("../../creation_receipt.zig").Configuration = undefined;
                const submitted = storage.submitMessageWithModelInto(&message, null, &submitted_receipt, .{});
                try std.testing.expect(configured == .accepted and submitted == .accepted);
                config_session = configured.accepted.session;
                message_session = submitted.accepted.session;
                try check(configured.accepted.configuration, expected_names);
                try check(submitted.accepted.configuration, expected_names);
            }
            {
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tools });
                defer storage.close() catch unreachable;
                var configured_receipt: @import("../../creation_receipt.zig").Configuration = undefined;
                const configured = try storage.configureInto(&create, &configured_receipt, .{});
                var submitted_receipt: @import("../../creation_receipt.zig").Configuration = undefined;
                const submitted = storage.submitMessageWithModelInto(&message, null, &submitted_receipt, .{});
                try std.testing.expect(configured == .accepted and configured.accepted.replayed);
                try std.testing.expect(submitted == .accepted and submitted.accepted.replayed);
                try std.testing.expectEqualStrings(config_session.slice(), configured.accepted.session.slice());
                try std.testing.expectEqualStrings(message_session.slice(), submitted.accepted.session.slice());
                try check(configured.accepted.configuration, expected_names);
                try check(submitted.accepted.configuration, expected_names);
            }
        }

        fn check(receipt: ?*const @import("../../creation_receipt.zig").Configuration, expected: []const u8) !void {
            try std.testing.expect(receipt != null);
            try std.testing.expectEqualStrings(expected, receipt.?.tools.slice());
            try std.testing.expectEqualStrings(expected, receipt.?.loaded_tools.slice());
        }
    }.run);
}

// SH-118: an app record a lane root declares reads back through the offer and the saved selection with the digest it
// was saved with, on both engines.
test "SH-118 a tool record read back from the Store through the offer, the selection and readHostToolSet has the digest it was saved with" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(engine, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var create = try store_testing.completeConfiguration("app-policy-config", "", try store_testing.canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            const declaration = "[{\"name\":\"ask\",\"description\":\"Ask the app.\",\"input_schema\":{\"type\":\"object\"},\"replay\":\"safe\",\"restart_limit\":2,\"wait_ms\":5000}]";
            declareAppTools(&create.configuration, declaration);
            const reply = try storage.configure(&create, .{});
            try std.testing.expect(reply == .accepted);
            const app_set = try store_testing.queryU64(&storage, "SELECT app_tool_set_id FROM session WHERE session_ref=?1", .{reply.accepted.session.slice()});
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_record WHERE owner='app' AND name='ask' AND replay='safe' AND restart_limit=2 AND wait_ms=5000", .{}));

            // The declared record's digest, rebuilt by the same owner the offer and the selection use.
            const decl_arena = try std.testing.allocator.alloc(u8, app_tools.arena_bytes);
            defer std.testing.allocator.free(decl_arena);
            var decl_fixed: std.heap.FixedBufferAllocator = .init(decl_arena);
            const declared = app_tools.parse(decl_fixed.allocator(), declaration).declared;
            const saved_digest = tool_record.recordDigest(&declared.records[0]);

            // The offer and the saved selection rebuild it from the same rows.
            const names = try command_input.ToolsField.of(&.{"ask"});
            var offer: tool_offer_domain.Freeze = .{};
            var selection: tool_set_domain.SavedSelection = .{ .names = &names };
            try storage.readToolDigestsForTesting(app_set, &names, &offer, &selection);
            var offered: ?[32]u8 = null;
            for (offer.projection.members[0..offer.projection.count]) |member| {
                if (std.mem.eql(u8, member.name.slice(), "ask")) offered = member.digest;
            }
            try std.testing.expectEqualSlices(u8, &saved_digest, &(offered orelse return error.TestUnexpectedResult));
            var expected_set: tool_record.SetDigest = .init();
            expected_set.add(&saved_digest);
            const expected_selection = expected_set.final();
            try std.testing.expectEqualSlices(u8, &expected_selection, &(try selection.selection()).digest);
        }
    }.run);
}

// SH-144: a lane root's configure saves its declared app tools as one tool set that the Session names; replacing the
// declaration changes that set, an empty list clears it, a child refuses a declaration by name, and a replayed
// create keeps one set. Both engines run the same Store API calls.
fn declareAppTools(configuration: *wire_request.Configuration, bytes: []const u8) void {
    configuration.app_tools = .{ .state = .value, .borrowed = bytes.ptr, .length = bytes.len, .digest = protocol.contentDigest(bytes) };
}

test "SH-144 a lane root saves its app tools as one set; replacing, clearing and a child's refusal hold on both engines" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const first = "[{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"},\"replay\":\"safe\",\"restart_limit\":2,\"wait_ms\":5000}]";
            const second = "[{\"name\":\"other\",\"description\":\"Other.\",\"input_schema\":{\"type\":\"object\"}}]";
            var create = try store_testing.completeConfiguration("app-root", "", workspace, "model-a");
            declareAppTools(&create.configuration, first);
            const root_reply = try storage.configure(&create, .{});
            try std.testing.expect(root_reply == .accepted);
            const root = root_reply.accepted.session.slice();
            const first_set = try store_testing.queryU64(&storage, "SELECT app_tool_set_id FROM session WHERE session_ref=?1", .{root});
            try std.testing.expect(first_set > 0);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT member_count FROM tool_set WHERE tool_set_id=?1", .{first_set}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_record WHERE owner='app' AND name='ask' AND replay='safe' AND restart_limit=2 AND wait_ms=5000", .{}));
            // The saved set's digest is the set digest of the declared record, as the offer and selection rebuild it.
            const decl_arena = try std.testing.allocator.alloc(u8, app_tools.arena_bytes);
            defer std.testing.allocator.free(decl_arena);
            var decl_fixed: std.heap.FixedBufferAllocator = .init(decl_arena);
            const declared = app_tools.parse(decl_fixed.allocator(), first).declared;
            var expected_set: tool_record.SetDigest = .init();
            expected_set.add(&tool_record.recordDigest(&declared.records[0]));
            const set_names = try command_input.ToolsField.of(&.{"ask"});
            var offer: tool_offer_domain.Freeze = .{};
            var selection: tool_set_domain.SavedSelection = .{ .names = &set_names };
            try storage.readToolDigestsForTesting(first_set, &set_names, &offer, &selection);
            try std.testing.expectEqualSlices(u8, &expected_set.final(), &(try selection.selection()).digest);
            // A replayed create answers the same Session and keeps its set.
            const replay = try storage.configure(&create, .{});
            try std.testing.expect(replay.accepted.replayed);
            try std.testing.expectEqual(first_set, try store_testing.queryU64(&storage, "SELECT app_tool_set_id FROM session WHERE session_ref=?1", .{root}));

            // A configure with a new declaration replaces the set and records the change once.
            var replace: wire_request.ConfigureCommand = .{};
            try replace.key.set("app-root-replace");
            try replace.session.set(root);
            declareAppTools(&replace.configuration, second);
            try std.testing.expect((try storage.configure(&replace, .{})) == .accepted);
            const second_set = try store_testing.queryU64(&storage, "SELECT app_tool_set_id FROM session WHERE session_ref=?1", .{root});
            try std.testing.expect(second_set != first_set);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE session_ref=?1 AND field='app_tools'", .{root}));

            // An empty list clears the declaration: the Session names no set.
            var clear: wire_request.ConfigureCommand = .{};
            try clear.key.set("app-root-clear");
            try clear.session.set(root);
            declareAppTools(&clear.configuration, "[]");
            try std.testing.expect((try storage.configure(&clear, .{})) == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND app_tool_set_id IS NULL", .{root}));

            // A child, attached to the root, may not declare app tools.
            var child: wire_request.ConfigureCommand = .{};
            try child.key.set("app-child");
            child.configuration = try shared_fixtures.testingAgentSpec(&.{}, "bypass");
            child.configuration.parent.state = .value;
            try child.configuration.parent.value.set(root);
            child.configuration.model.state = .value;
            try child.configuration.model.value.set("model-a");
            declareAppTools(&child.configuration, second);
            const refused = try storage.configure(&child, .{});
            try std.testing.expectEqual(protocol.ConfigurationRejection.app_tools_on_child, refused.rejected.code);
            // An empty list is a declaration too: a child refuses it as well.
            try child.key.set("app-child-empty");
            declareAppTools(&child.configuration, "[]");
            const refused_empty = try storage.configure(&child, .{});
            try std.testing.expectEqual(protocol.ConfigurationRejection.app_tools_on_child, refused_empty.rejected.code);
        }
    }.run);
}

// SH-145: a lane root's configure or create saves a declared app tool set of any supported size in one transaction,
// whether its texts are fresh or already stored, and the set reads back with every declared record.
const declared_counts = [_]usize{ 1, 8, app_tools.max_records };

/// One declaration of `count` tools whose texts carry `tag`; `wait_ms` changes each record's digest without changing its texts.
fn writeAppDeclaration(buffer: []u8, count: usize, tag: []const u8, wait_ms: u32) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeByte('[');
    for (0..count) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print(
            "{{\"name\":\"tool-{d:0>2}\",\"description\":\"Tool {s} {d}.\",\"input_schema\":{{\"type\":\"object\"}},\"wait_ms\":{d}}}",
            .{ index, tag, index, wait_ms },
        );
    }
    try writer.writeByte(']');
    return writer.buffered();
}

fn expectAppSetReadsBack(storage: *Store, root: []const u8, document: []const u8, count: usize) !void {
    const set = try store_testing.queryU64(storage, "SELECT app_tool_set_id FROM session WHERE session_ref=?1", .{root});
    try std.testing.expect(set > 0);
    try std.testing.expectEqual(@as(u64, count), try store_testing.queryU64(storage, "SELECT member_count FROM tool_set WHERE tool_set_id=?1", .{set}));
    const decl_arena = try std.testing.allocator.alloc(u8, app_tools.arena_bytes);
    defer std.testing.allocator.free(decl_arena);
    var decl_fixed: std.heap.FixedBufferAllocator = .init(decl_arena);
    const declared = app_tools.parse(decl_fixed.allocator(), document).declared;
    var expected_set: tool_record.SetDigest = .init();
    var names: [app_tools.max_records][]const u8 = undefined;
    for (declared.records, 0..) |*record, index| {
        expected_set.add(&tool_record.recordDigest(record));
        names[index] = record.name;
    }
    const set_names = try command_input.ToolsField.of(names[0..count]);
    var offer: tool_offer_domain.Freeze = .{};
    var selection: tool_set_domain.SavedSelection = .{ .names = &set_names };
    try storage.readToolDigestsForTesting(set, &set_names, &offer, &selection);
    try std.testing.expectEqualSlices(u8, &expected_set.final(), &(try selection.selection()).digest);
}

test "SH-145 a lane root saves a declared app tool set of every supported size on create and configure, fresh or with stored texts" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var document: [app_tools.max_document_bytes]u8 = undefined;
            var tag_buffer: [32]u8 = undefined;
            var key_buffer: [64]u8 = undefined;
            for (declared_counts) |count| {
                // Fresh texts are tagged per count and operation, so no earlier declaration has stored them. The
                // stored-texts declaration repeats the tag with another wait_ms: its records differ, its texts do not.
                const fresh_create = try writeAppDeclaration(&document, count, try std.fmt.bufPrint(&tag_buffer, "c{d}-create", .{count}), 1000);
                var create = try store_testing.completeConfiguration(try std.fmt.bufPrint(&key_buffer, "sh125-create-fresh-{d}", .{count}), "", workspace, "model-a");
                declareAppTools(&create.configuration, fresh_create);
                const created = try storage.configure(&create, .{});
                try std.testing.expect(created == .accepted);
                try expectAppSetReadsBack(&storage, created.accepted.session.slice(), fresh_create, count);

                const stored_create = try writeAppDeclaration(&document, count, try std.fmt.bufPrint(&tag_buffer, "c{d}-create", .{count}), 2000);
                var repeat = try store_testing.completeConfiguration(try std.fmt.bufPrint(&key_buffer, "sh125-create-stored-{d}", .{count}), "", workspace, "model-a");
                declareAppTools(&repeat.configuration, stored_create);
                const repeated = try storage.configure(&repeat, .{});
                try std.testing.expect(repeated == .accepted);
                try expectAppSetReadsBack(&storage, repeated.accepted.session.slice(), stored_create, count);

                const fresh_configure = try writeAppDeclaration(&document, count, try std.fmt.bufPrint(&tag_buffer, "c{d}-configure", .{count}), 1000);
                var plain = try store_testing.completeConfiguration(try std.fmt.bufPrint(&key_buffer, "sh125-plain-fresh-{d}", .{count}), "", workspace, "model-a");
                const plain_root = try storage.configure(&plain, .{});
                try std.testing.expect(plain_root == .accepted);
                const fresh_root = plain_root.accepted.session.slice();
                var configure: wire_request.ConfigureCommand = .{};
                try configure.key.set(try std.fmt.bufPrint(&key_buffer, "sh125-configure-fresh-{d}", .{count}));
                try configure.session.set(fresh_root);
                declareAppTools(&configure.configuration, fresh_configure);
                try std.testing.expect((try storage.configure(&configure, .{})) == .accepted);
                try expectAppSetReadsBack(&storage, fresh_root, fresh_configure, count);

                const stored_configure = try writeAppDeclaration(&document, count, try std.fmt.bufPrint(&tag_buffer, "c{d}-configure", .{count}), 2000);
                var plain_again = try store_testing.completeConfiguration(try std.fmt.bufPrint(&key_buffer, "sh125-plain-stored-{d}", .{count}), "", workspace, "model-a");
                const stored_plain_root = try storage.configure(&plain_again, .{});
                try std.testing.expect(stored_plain_root == .accepted);
                const stored_root = stored_plain_root.accepted.session.slice();
                var stored: wire_request.ConfigureCommand = .{};
                try stored.key.set(try std.fmt.bufPrint(&key_buffer, "sh125-configure-stored-{d}", .{count}));
                try stored.session.set(stored_root);
                declareAppTools(&stored.configuration, stored_configure);
                try std.testing.expect((try storage.configure(&stored, .{})) == .accepted);
                try expectAppSetReadsBack(&storage, stored_root, stored_configure, count);
            }
        }
    }.run);
}

// SH-161..SH-172: the tools a model request carries from its lane's declared app tools, read through the request page
// the provider reads (admission freezes the offer; the page walks its tool set).
const two_app_tools = "[{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"}},{\"name\":\"other\",\"description\":\"Other.\",\"input_schema\":{\"type\":\"object\"}}]";
const ask_app_tool = "[{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"}}]";
const unserved_answer = "No app is serving this tool yet.";

/// The tools one model request carries, by name and owner, in the order its request page lists them.
const Offered = struct {
    count: usize = 0,
    names: [@import("../../tool_name.zig").max_offered_tools]@FieldType(historical_domain.HistoricalTool, "name") = undefined,
    owners: [@import("../../tool_name.zig").max_offered_tools]@FieldType(historical_domain.HistoricalTool, "owner") = undefined,

    fn owner(self: *const Offered, name: []const u8) ?@FieldType(historical_domain.HistoricalTool, "owner") {
        for (self.names[0..self.count], self.owners[0..self.count]) |*candidate, kind| {
            if (std.mem.eql(u8, candidate.slice(), name)) return kind;
        }
        return null;
    }
};

/// Admits the Session's next model request after a Message, and returns its binding.
fn admitMessage(storage: *Store, tmp: *std.testing.TmpDir, key: []const u8, session: []const u8) !AttemptBinding {
    try submitTestMessage(storage, tmp, key, key, session, "question");
    return (try storage.admitNextModelAttempt(.{})).?.permit.binding;
}

/// Reads the tools the request `binding` carries, as its request page walks them.
fn offerOf(storage: *Store, binding: AttemptBinding, out: *Offered) !void {
    var view: TestingPage = undefined;
    view.open(storage, binding);
    defer view.close();
    var settings: historical_domain.HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expect(try view.validateOutputsStep());
    _ = try view.coverage();
    view.expectTools(.all);
    out.* = .{};
    var tool: historical_domain.HistoricalTool = .{};
    while (try view.nextTool(&tool)) : (out.count += 1) {
        out.names[out.count] = tool.name;
        out.owners[out.count] = tool.owner;
    }
    try std.testing.expectEqual(settings.tool_count, out.count);
}

fn createRoot(storage: *Store, key: []const u8, declaration: ?[]const u8, buffer: []u8) ![]const u8 {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var create = try store_testing.completeConfiguration(key, "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    // The creation profile, so a child that names no tools is within its parent's tools (as a Host's own roots are).
    create.configuration.tools = .{};
    if (declaration) |document| declareAppTools(&create.configuration, document);
    const reply = try storage.configure(&create, .{});
    try std.testing.expect(reply == .accepted);
    return copyRef(buffer, reply.accepted.session.slice());
}

fn copyRef(buffer: []u8, ref: []const u8) []const u8 {
    @memcpy(buffer[0..ref.len], ref);
    return buffer[0..ref.len];
}

const ChildReply = union(enum) { accepted: []const u8, rejected: protocol.ConfigurationRejection };

/// A child attached to `parent`: it names `tools`, or none when `tools` is null.
fn configureChild(storage: *Store, key: []const u8, parent: []const u8, tools: ?[]const []const u8, buffer: []u8) !ChildReply {
    var child: wire_request.ConfigureCommand = .{};
    try child.key.set(key);
    child.configuration = try shared_fixtures.testingAgentSpec(&.{}, "ask");
    child.configuration.tools = if (tools) |names| try .of(names) else .{};
    child.configuration.parent.state = .value;
    try child.configuration.parent.value.set(parent);
    child.configuration.model.state = .value;
    try child.configuration.model.value.set("model-a");
    const reply = try storage.configure(&child, .{});
    return switch (reply) {
        .accepted => |accepted| .{ .accepted = copyRef(buffer, accepted.session.slice()) },
        .rejected => |refused| .{ .rejected = refused.code },
        .conflict, .infrastructure_failure => error.TestUnexpectedResult,
    };
}

test "SH-161 a lane root's model request carries every app tool its lane declares, beside the Host tools" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh148-root", two_app_tools, &buffer);
            var offer: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh148-message", root), &offer);
            try std.testing.expectEqual(tool_record.Owner.app, offer.owner("ask").?);
            try std.testing.expectEqual(tool_record.Owner.app, offer.owner("other").?);
            try std.testing.expect(offer.owner("bash") != null);
        }
    }.run);
}

test "SH-162 a lane root that declares no app tools offers none, as a Host without app tools does" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh149-root", null, &buffer);
            var offer: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh149-message", root), &offer);
            try std.testing.expect(offer.owner("ask") == null);
            try std.testing.expect(offer.owner("bash") != null);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND app_tool_set_id IS NOT NULL", .{root}));
        }
    }.run);
}

test "SH-163 a re-declare changes the next request's tools, and the admitted request keeps the records it was made with" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh150-root", two_app_tools, &buffer);
            const first = try admitMessage(&storage, &tmp, "sh150-first", root);
            var before: Offered = undefined;
            try offerOf(&storage, first, &before);
            var replace: wire_request.ConfigureCommand = .{};
            try replace.key.set("sh150-replace");
            try replace.session.set(root);
            declareAppTools(&replace.configuration, ask_app_tool);
            try std.testing.expect((try storage.configure(&replace, .{})) == .accepted);
            var still: Offered = undefined;
            try offerOf(&storage, first, &still);
            try std.testing.expect(still.owner("other") != null);
            const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}"};
            try settleItemsForTesting(&storage, &tmp, first, &items, "answer");
            var after: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh150-second", root), &after);
            try std.testing.expect(after.owner("ask") != null);
            try std.testing.expect(after.owner("other") == null);
            try std.testing.expect(before.owner("other") != null);
        }
    }.run);
}

test "SH-164 an attached child that names no tools offers every app tool its lane declares" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root_buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh151-root", two_app_tools, &root_buffer);
            var child_buffer: [128]u8 = undefined;
            const child = (try configureChild(&storage, "sh151-child", root, null, &child_buffer)).accepted;
            var offer: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh151-message", child), &offer);
            try std.testing.expect(offer.owner("ask") != null);
            try std.testing.expect(offer.owner("other") != null);
        }
    }.run);
}

test "SH-165 a child that names an app tool offers that tool alone; a child that names only Host tools offers every app tool" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root_buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh152-root", two_app_tools, &root_buffer);
            var named_buffer: [128]u8 = undefined;
            const named = (try configureChild(&storage, "sh152-named", root, &.{ "ask", "bash" }, &named_buffer)).accepted;
            var host_buffer: [128]u8 = undefined;
            const host = (try configureChild(&storage, "sh152-host", root, &.{"bash"}, &host_buffer)).accepted;
            var named_offer: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh152-named-message", named), &named_offer);
            try std.testing.expect(named_offer.owner("ask") != null);
            try std.testing.expect(named_offer.owner("other") == null);
            var host_offer: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh152-host-message", host), &host_offer);
            try std.testing.expect(host_offer.owner("ask") != null);
            try std.testing.expect(host_offer.owner("other") != null);
        }
    }.run);
}

test "SH-166 a child that names an app tool its lane lacks is refused by name" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root_buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh153-root", two_app_tools, &root_buffer);
            var child_buffer: [128]u8 = undefined;
            const reply = try configureChild(&storage, "sh153-child", root, &.{ "bash", "missing_tool" }, &child_buffer);
            try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_tool, reply.rejected);
        }
    }.run);
}

test "SH-167 a child names only the app tools its parent offers; a parent that narrows to one refuses the other" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root_buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh154-root", two_app_tools, &root_buffer);
            var narrow: wire_request.ConfigureCommand = .{};
            try narrow.key.set("sh154-narrow");
            try narrow.session.set(root);
            narrow.configuration.tools = try .of(&.{ "ask", "bash" });
            try std.testing.expect((try storage.configure(&narrow, .{})) == .accepted);
            var offer: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh154-root-message", root), &offer);
            try std.testing.expect(offer.owner("ask") != null);
            try std.testing.expect(offer.owner("other") == null);
            var other_buffer: [128]u8 = undefined;
            const reply = try configureChild(&storage, "sh154-child-other", root, &.{ "bash", "other" }, &other_buffer);
            try std.testing.expectEqual(protocol.ConfigurationRejection.tools_not_in_parent, reply.rejected);
            var ask_buffer: [128]u8 = undefined;
            _ = try configureChild(&storage, "sh154-child-ask", root, &.{ "ask", "bash" }, &ask_buffer);
        }
    }.run);
}

test "SH-168 a grandchild's request carries the app tools its root's lane declares" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root_buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh155-root", two_app_tools, &root_buffer);
            var child_buffer: [128]u8 = undefined;
            const child = (try configureChild(&storage, "sh155-child", root, null, &child_buffer)).accepted;
            var grandchild_buffer: [128]u8 = undefined;
            const grandchild = (try configureChild(&storage, "sh155-grandchild", child, null, &grandchild_buffer)).accepted;
            var offer: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh155-message", grandchild), &offer);
            try std.testing.expect(offer.owner("ask") != null);
            try std.testing.expect(offer.owner("other") != null);
        }
    }.run);
}

test "SH-169 a Session whose lane declares no app set is never stale for its app offer" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh156-root", null, &buffer);
            const stale = try store_testing.queryU64(&storage, "SELECT CASE WHEN (" ++ tool_offer_domain.stale_sql ++ ") THEN 1 ELSE 0 END FROM session s WHERE s.session_ref=?1", .{root});
            try std.testing.expectEqual(@as(u64, 0), stale);
        }
    }.run);
}

test "SH-171 a detached child shares its lane's app tools, as an attached child does" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var root_buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh158-root", two_app_tools, &root_buffer);
            try submitTestMessage(&storage, &tmp, "sh158-message", "sh158-key", root, "start a child");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const arguments = "{\"task\":\"read\",\"attached\":false,\"spec\":{\"model\":\"model-a\",\"effort\":null,\"compactAt\":100000,\"tools\":[],\"permissionMode\":\"ask\"}}";
            const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), arguments, .{});
            var calls = [_]TestingCall{.{ .item_id = "sh158-item", .name = "start_agent", .encoded_call_id = "sh158-call", .decoded_call_id = "sh158-call", .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = arguments }};
            try settleCallsForTesting(&storage, &tmp, model, "sh158-calls", &calls);
            const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
            const core_tools = @import("../../core_tools.zig");
            const start = try arena.allocator().create(core_tools.StartAgent);
            try std.testing.expect(try core_tools.checkStartAgent(arena.allocator(), arguments, start) == .accepted);
            const Capture = struct {
                child: protocol.Bounded(protocol.session_id_bytes) = .{},
                fn call(context: *anyopaque, admission: Store.MessageAdmission) void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.child.set(admission.session) catch unreachable;
                }
            };
            var capture: Capture = .{};
            try std.testing.expect(try storage.startAgent(action.binding, root, start.task, start.attached, &start.configuration, .{ .context = &capture, .call = Capture.call }, .{}) == .started);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND creator_ref=?2 AND parent_ref IS NULL AND app_lane=?2", .{ capture.child.slice(), root }));
            var offer: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh158-child-message", capture.child.slice()), &offer);
            try std.testing.expect(offer.owner("ask") != null);
            try std.testing.expect(offer.owner("other") != null);
        }
    }.run);
}

test "SH-172 after an unserved app call settles, the next model request carries the text the model reads" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh159-root", two_app_tools, &buffer);
            const first = try admitMessage(&storage, &tmp, "sh159-message", root);
            var calls = [_]TestingCall{.{ .item_id = "sh159-item", .name = "ask", .encoded_call_id = "sh159-call", .decoded_call_id = "sh159-call", .encoded_arguments = "{}", .decoded_arguments = "{}" }};
            try settleCallsForTesting(&storage, &tmp, first, "sh159-calls", &calls);
            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: TestingPage = undefined;
            view.open(&storage, next);
            defer view.close();
            var found = false;
            var position: u64 = 0;
            var out_buffer: [256]u8 = undefined;
            while (try view.nextEntry(position)) |entry| : (position = entry.position) {
                if (entry.kind != .tool_results) continue;
                while (try view.nextToolResult()) |result| {
                    const output = result.output orelse continue;
                    var out = std.Io.Writer.fixed(&out_buffer);
                    try shared_fixtures.readTestingContent(&view, output, &out);
                    if (std.mem.eql(u8, out.buffered(), unserved_answer)) found = true;
                }
            }
            try std.testing.expect(found);
        }
    }.run);
}

// SH-170: a model call to an app tool that no app serves yet resolves its Action once, as failed, with the text the
// model reads; the Action's answer is one content row, and no app call waits on a runner.
test "SH-170 a model call to an app tool no app serves yet resolves once as failed with the text the model reads" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh136-root", two_app_tools, &buffer);
            try submitTestMessage(&storage, &tmp, "sh136-input", "sh136-message", root, "ask");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, binding, "sh136-calls", &.{.{
                .item_id = "item-1",
                .name = "ask",
                .encoded_call_id = "call-1",
                .decoded_call_id = "call-1",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
            const answer = "No app is serving this tool yet.";
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE parent_operation_id=?1 AND resolution_code='failed'", .{binding.operation_id}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.parent_operation_id=?1 AND c.byte_length=?2", .{ binding.operation_id, answer.len }));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE parent_operation_id=?1 AND resolution_code IS NULL", .{binding.operation_id}));
        }
    }.run);
}

// SH-160: configure and start_agent resolve a lane's names alike. A Host tool and a lane app tool are accepted and an
// unknown name is refused by name. The app tool reaches a child through its parent's own tools, so the lane round,
// not an earlier Host-only check, decides on both paths.
const lane_declaration = "[{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"}}]";
const LaneCase = struct { name: []const u8, refused: bool };
const lane_cases = [_]LaneCase{
    .{ .name = "start_agent", .refused = false },
    .{ .name = "ask", .refused = false },
    .{ .name = "nope", .refused = true },
};

test "SH-160 configure and start_agent resolve a lane's names alike: a Host tool and a lane app tool are accepted, an unknown name is refused" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var key_buffer: [96]u8 = undefined;
            var text_buffer: [256]u8 = undefined;
            for (lane_cases, 0..) |lane_case, index| {
                // The root declares the app tool, then names it once the lane holds it: configure reads the lane on update.
                var create = try completeConfiguration(try std.fmt.bufPrint(&key_buffer, "sh160-root-{d}", .{index}), "", workspace, "model-a");
                declareAppTools(&create.configuration, lane_declaration);
                create.configuration.tools = try .of(&.{ "find_tools", "start_agent" });
                const root_reply = try storage.configure(&create, .{});
                try std.testing.expect(root_reply == .accepted);
                const root = root_reply.accepted.session.slice();
                var names: wire_request.ConfigureCommand = .{};
                try names.key.set(try std.fmt.bufPrint(&key_buffer, "sh160-names-{d}", .{index}));
                try names.session.set(root);
                names.configuration.tools = try .of(&.{ "ask", "find_tools", "start_agent" });
                try std.testing.expect((try storage.configure(&names, .{})) == .accepted);

                // configure: a child of the root names the case's tool on create.
                var child: wire_request.ConfigureCommand = .{};
                try child.key.set(try std.fmt.bufPrint(&key_buffer, "sh160-child-{d}", .{index}));
                child.configuration = try testingAgentSpec(&.{lane_case.name}, "ask");
                child.configuration.parent.state = .value;
                try child.configuration.parent.value.set(root);
                const configured = try storage.configure(&child, .{});
                if (lane_case.refused) {
                    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_tool, configured.rejected.code);
                } else try std.testing.expect(configured == .accepted);

                // start_agent refuses an unknown name by name. Its acceptance of a Host or lane name is covered elsewhere (the MCP
                // missing-tool test starts a child). An app-only name reaches the model's offer, which this branch does not project
                // yet (pr-b2b does), so this check runs only for the unknown name.
                if (!lane_case.refused) continue;
                var start_root_command = try completeConfiguration(try std.fmt.bufPrint(&key_buffer, "sh160-start-root-{d}", .{index}), "", workspace, "model-a");
                declareAppTools(&start_root_command.configuration, lane_declaration);
                start_root_command.configuration.tools = try .of(&.{"start_agent"});
                const start_root_reply = try storage.configure(&start_root_command, .{});
                try std.testing.expect(start_root_reply == .accepted);
                const start_root = start_root_reply.accepted.session.slice();
                var file_buffer: [48]u8 = undefined;
                try submitTestMessage(&storage, &tmp, try std.fmt.bufPrint(&file_buffer, "sh160-file-{d}", .{index}), try std.fmt.bufPrint(&key_buffer, "sh160-message-{d}", .{index}), start_root, "start a child");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const call: TestingCall = .{ .item_id = "lane-call", .name = "start_agent", .encoded_call_id = "lane-call", .decoded_call_id = "lane-call", .encoded_arguments = "{}", .decoded_arguments = "{}" };
                try settleCallsForTesting(&storage, &tmp, model, try std.fmt.bufPrint(&key_buffer, "sh160-calls-{d}", .{index}), &.{call});
                const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                var spec = try testingAgentSpec(&.{lane_case.name}, "ask");
                const started = try storage.startAgent(action.binding, start_root, "read", true, &spec, null, .{});
                if (lane_case.refused) {
                    try std.testing.expectEqual(command_domain.AgentStart.failed, started);
                    const text = try std.fmt.bufPrint(&text_buffer, "spec.tools: {s} is not a known tool (unknown_tool). Nothing was started.", .{lane_case.name});
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.digest=?2", .{ action.binding.action_id, store_testing.Blob{ .bytes = &protocol.contentDigest(text) } }));
                } else try std.testing.expectEqual(command_domain.AgentStart.started, started);
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

// SH-173: an app tool never shares a name with a Host tool. A declaration that names a Host tool, an MCP tool included, is
// refused by name on configure. An app tool that a Host tool of its name arrives beside is not offered on the next request,
// narrowed or not, and the Host tool takes the name in the offer.
test "SH-173 an app tool never shares a name with a Host tool: a clashing declaration is refused by name, and a later Host tool takes the name in the offer" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

            // An MCP tool named like the declared app tool is in the Host set: the declaration is refused by name.
            const clash = comptime testingHostToolRecords(&.{.{ .name = "ask", .owner = .mcp, .server = "notes", .description = "Saved tool", .input_schema = "{\"type\":\"object\"}" }});
            var clash_digests: [clash.len][32]u8 = undefined;
            for (&clash, &clash_digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            try storage.saveHostToolSet(&.{ .records = &clash, .digests = &clash_digests });
            var refused_create = try store_testing.completeConfiguration("sh173-clash", "", workspace, "model-a");
            declareAppTools(&refused_create.configuration, ask_app_tool);
            const refused = try storage.configure(&refused_create, .{});
            try std.testing.expectEqual(protocol.ConfigurationRejection.app_tool_host_clash, refused.rejected.code);

            // With no clash, an unnarrowed root offers both its app tools, and a root that names one offers that one alone.
            try storage.saveHostToolSet(&tool_defs.built_in_tool_set);
            var buffer: [128]u8 = undefined;
            const root = try createRoot(&storage, "sh173-root", two_app_tools, &buffer);
            const first = try admitMessage(&storage, &tmp, "sh173-first", root);
            var before: Offered = undefined;
            try offerOf(&storage, first, &before);
            try std.testing.expectEqual(tool_record.Owner.app, before.owner("ask").?);
            try std.testing.expectEqual(tool_record.Owner.app, before.owner("other").?);

            var narrow_buffer: [128]u8 = undefined;
            const narrowed = try createRoot(&storage, "sh173-narrow", two_app_tools, &narrow_buffer);
            var names: wire_request.ConfigureCommand = .{};
            try names.key.set("sh173-narrow-names");
            try names.session.set(narrowed);
            names.configuration.tools = try .of(&.{ "ask", "find_tools" });
            try std.testing.expect((try storage.configure(&names, .{})) == .accepted);
            var narrow: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh173-narrow-first", narrowed), &narrow);
            try std.testing.expectEqual(tool_record.Owner.app, narrow.owner("ask").?);
            try std.testing.expect(narrow.owner("other") == null);

            // A Host tool named `other` arrives: the root's next request offers the Host tool, not the app tool, and keeps `ask`.
            const shadow = comptime testingHostToolRecords(&.{.{ .name = "other", .owner = .mcp, .server = "notes", .description = "Later tool", .input_schema = "{\"type\":\"object\"}" }});
            var shadow_digests: [shadow.len][32]u8 = undefined;
            for (&shadow, &shadow_digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            try storage.saveHostToolSet(&.{ .records = &shadow, .digests = &shadow_digests });
            // The Host tool joins the root's selection by name: a profile does not offer every Host tool, only the ones named.
            var takes_name: wire_request.ConfigureCommand = .{};
            try takes_name.key.set("sh173-takes-name");
            try takes_name.session.set(root);
            takes_name.configuration.tools = try .of(&.{ "ask", "find_tools", "other" });
            try expectAccepted("takes_name", try storage.configure(&takes_name, .{}));
            const items = [_][]const u8{"{\"type\":\"message\",\"id\":\"m0\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}"};
            try settleItemsForTesting(&storage, &tmp, first, &items, "answer");
            var after: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh173-second", root), &after);
            try std.testing.expectEqual(tool_record.Owner.mcp, after.owner("other").?);
            try std.testing.expectEqual(tool_record.Owner.app, after.owner("ask").?);
        }
    }.run);
}

// SH-174: a request's offer holds the Host's whole tool set beside every app tool a lane declares, with each app name at
// the full 64 bytes. The offer is sized from max_offered_tools, which counts the Host tools and
// the app records, so this is the largest offer the owner admits.
test "SH-174 a request offers the Host's full tool set beside every app tool a lane declares, at the largest name sizes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const tool_name = @import("../../tool_name.zig");
            const host_extras = comptime blk: {
                @setEvalBranchQuota(10_000_000);
                const count = tool_name.max_offered_tools - app_tools.max_records - tool_defs.built_in_tool_set.records.len;
                var records: [count]tool_defs.Record = undefined;
                // The root names every Host tool: those names and the stubs fill the configurable list's bytes (its separators counted once).
                var builtin_bytes: usize = 0;
                var builtin_count: usize = 0;
                for (tool_defs.built_in_tool_set.records) |record| {
                    builtin_bytes += record.name.len;
                    builtin_count += 1;
                }
                const bytes = protocol.max_tool_list_name_bytes - builtin_bytes - (builtin_count + count - 1);
                for (&records, 0..) |*record, index| {
                    const prefix = std.fmt.comptimePrint("stub{d:0>3}", .{index});
                    const length = bytes / records.len + @intFromBool(index < bytes % records.len);
                    const name = prefix ++ @as([length - prefix.len]u8, @splat('x'));
                    record.* = .{
                        .name = name,
                        .remote_name = name,
                        .owner = .mcp,
                        .server = "docs",
                        .description = "Read a page.",
                        .input_schema = "{\"type\":\"object\"}",
                    };
                }
                break :blk records;
            };
            const records = comptime testingHostToolRecords(&host_extras);
            // The names the root configures: the Host's built-ins, then every stub.
            const configured_names = comptime blk: {
                var names: [tool_defs.built_in_tool_set.records.len + host_extras.len][]const u8 = undefined;
                var at: usize = 0;
                for (tool_defs.built_in_tool_set.records) |record| {
                    names[at] = record.name;
                    at += 1;
                }
                for (host_extras) |record| {
                    names[at] = record.name;
                    at += 1;
                }
                break :blk names;
            };
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try storage.saveHostToolSet(&.{ .records = &records, .digests = &digests });

            // Every app name is 64 bytes, so the app names take the whole app-name budget.
            var document: [app_tools.max_document_bytes]u8 = undefined;
            var writer = std.Io.Writer.fixed(&document);
            try writer.writeByte('[');
            for (0..app_tools.max_records) |index| {
                var name: [tool_name.max_bytes]u8 = @splat('x');
                _ = try std.fmt.bufPrint(&name, "app{d:0>2}", .{index});
                if (index != 0) try writer.writeByte(',');
                try writer.print("{{\"name\":\"{s}\",\"description\":\"App {d}.\",\"input_schema\":{{\"type\":\"object\"}}}}", .{ name[0..], index });
            }
            try writer.writeByte(']');

            var configured: protocol.ToolsField = .{ .state = .value };
            for (configured_names) |name| try configured.insert(name);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var root_create = try completeConfiguration("sh174-root", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
            declareAppTools(&root_create.configuration, writer.buffered());
            root_create.configuration.tools = configured;
            const root_reply = try storage.configure(&root_create, .{});
            try expectAccepted("root", root_reply);
            var root_buffer: [128]u8 = undefined;
            const root = keepRef(&root_buffer, root_reply.accepted.session.slice());
            var offered: Offered = undefined;
            try offerOf(&storage, try admitMessage(&storage, &tmp, "sh174-first", root), &offered);
            try std.testing.expectEqual(@as(usize, tool_name.max_offered_tools), offered.count);
            var app_count: usize = 0;
            for (offered.owners[0..offered.count]) |kind| {
                if (kind == .app) app_count += 1;
            }
            try std.testing.expectEqual(@as(usize, app_tools.max_records), app_count);
            for (0..app_tools.max_records) |index| {
                var name: [tool_name.max_bytes]u8 = @splat('x');
                _ = try std.fmt.bufPrint(&name, "app{d:0>2}", .{index});
                try std.testing.expectEqual(tool_record.Owner.app, offered.owner(name[0..]).?);
            }
            try std.testing.expectEqual(tool_record.Owner.mcp, offered.owner(host_extras[host_extras.len - 1].name).?);
        }
    }.run);
}

const ask_and_other_declaration = "[{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"}},{\"name\":\"other\",\"description\":\"Other.\",\"input_schema\":{\"type\":\"object\"}}]";
const lookup_and_ask_declaration = "[{\"name\":\"lookup\",\"description\":\"App lookup.\",\"input_schema\":{\"type\":\"object\"}},{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"}}]";

/// The Session reference a configure returned, copied out of the reply so a later configure cannot overwrite it.
fn keepRef(buffer: []u8, ref: []const u8) []const u8 {
    @memcpy(buffer[0..ref.len], ref);
    return buffer[0..ref.len];
}

/// A configure that must be accepted: a refusal fails the test by naming the step and the code it returned.
fn expectAccepted(step: []const u8, reply: anytype) !void {
    switch (reply) {
        .accepted => {},
        .rejected => |refused| try std.testing.expectEqualStrings(step, @tagName(refused.code)),
        else => return error.TestUnexpectedResult,
    }
}

// SH-175: one lane resolver decides a configure's names: the declaration the request carries (create, replace or clear),
// else the saved lane, with Host precedence. A parent narrows its children's app tools only by naming app tools the Host
// does not shadow. start_agent resolves the same names through the same lane round; its acceptance of an app-only
// name needs the model offer projecting app tools, which pr-b2b adds, so it is not checked on this branch.
test "SH-175 configure resolves names through the lane's effective declaration, and a Host-shadowed app tool narrows no parent" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try storage.saveHostToolSet(&tool_defs.built_in_tool_set);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var refs: [4][128]u8 = undefined;

            // Create: the declaration and a selection of its name in one request.
            var created = try completeConfiguration("sh175-create", "", workspace, "model-a");
            declareAppTools(&created.configuration, ask_and_other_declaration);
            created.configuration.tools = try .of(&.{ "ask", "find_tools" });
            const created_reply = try storage.configure(&created, .{});
            try expectAccepted("created", created_reply);
            const root = keepRef(&refs[0], created_reply.accepted.session.slice());

            // Replace: the new declaration drops `other`, so naming it is refused; naming the kept `ask` is accepted.
            var replace_other: wire_request.ConfigureCommand = .{};
            try replace_other.key.set("sh175-replace-other");
            try replace_other.session.set(root);
            declareAppTools(&replace_other.configuration, ask_only_declaration);
            replace_other.configuration.tools = try .of(&.{"other"});
            try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_tool, (try storage.configure(&replace_other, .{})).rejected.code);
            var replace_ask: wire_request.ConfigureCommand = .{};
            try replace_ask.key.set("sh175-replace-ask");
            try replace_ask.session.set(root);
            declareAppTools(&replace_ask.configuration, ask_only_declaration);
            replace_ask.configuration.tools = try .of(&.{ "ask", "find_tools" });
            try expectAccepted("replace_ask", try storage.configure(&replace_ask, .{}));

            // Clear: an empty declaration leaves the lane no app tools, so naming `ask` is refused.
            var clear: wire_request.ConfigureCommand = .{};
            try clear.key.set("sh175-clear");
            try clear.session.set(root);
            declareAppTools(&clear.configuration, "[]");
            clear.configuration.tools = try .of(&.{"ask"});
            try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_tool, (try storage.configure(&clear, .{})).rejected.code);

            // Omitted: an update without appTools keeps the saved declaration, so the name resolves.
            var omitted: wire_request.ConfigureCommand = .{};
            try omitted.key.set("sh175-omitted");
            try omitted.session.set(root);
            omitted.configuration.tools = try .of(&.{ "ask", "find_tools" });
            try expectAccepted("omitted", try storage.configure(&omitted, .{}));

            // A root declares `lookup` while the Host has none, and names it. Then an MCP `lookup` arrives in the Host set:
            // it shadows the app tool, so a declaration that names it is refused by name (app_tool_host_clash).
            var shadowed = try completeConfiguration("sh175-shadowed", "", workspace, "model-a");
            declareAppTools(&shadowed.configuration, lookup_and_ask_declaration);
            shadowed.configuration.tools = try .of(&.{"lookup"});
            const shadowed_reply = try storage.configure(&shadowed, .{});
            try expectAccepted("shadowed", shadowed_reply);
            const shadow_root = keepRef(&refs[1], shadowed_reply.accepted.session.slice());
            const shadow = comptime testingHostToolRecords(&.{.{ .name = "lookup", .owner = .mcp, .server = "notes", .description = "Lookup.", .input_schema = "{\"type\":\"object\"}" }});
            var shadow_digests: [shadow.len][32]u8 = undefined;
            for (&shadow, &shadow_digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            try storage.saveHostToolSet(&.{ .records = &shadow, .digests = &shadow_digests });
            var clashing = try completeConfiguration("sh175-clash", "", workspace, "model-a");
            declareAppTools(&clashing.configuration, lookup_and_ask_declaration);
            clashing.configuration.tools = try .of(&.{"ask"});
            try std.testing.expectEqual(protocol.ConfigurationRejection.app_tool_host_clash, (try storage.configure(&clashing, .{})).rejected.code);

            // A child of that root names `ask`: the shadowed `lookup` narrows nothing, so `ask` is offered to it.
            // A child inherits its parent's workspace, so its spec names none.
            var child_ask: wire_request.ConfigureCommand = .{};
            try child_ask.key.set("sh175-child-ask");
            child_ask.configuration = try testingAgentSpec(&.{"ask"}, "ask");
            child_ask.configuration.parent.state = .value;
            try child_ask.configuration.parent.value.set(shadow_root);
            try expectAccepted("child_ask", try storage.configure(&child_ask, .{}));

            // A real subset: the root names `ask` alone of its two app tools, so its child may not name `other`.
            var subset_root_command = try completeConfiguration("sh175-subset-root", "", workspace, "model-a");
            declareAppTools(&subset_root_command.configuration, ask_and_other_declaration);
            subset_root_command.configuration.tools = try .of(&.{ "ask", "find_tools" });
            const subset_reply = try storage.configure(&subset_root_command, .{});
            try expectAccepted("subset", subset_reply);
            const subset_root = keepRef(&refs[2], subset_reply.accepted.session.slice());
            var child_other: wire_request.ConfigureCommand = .{};
            try child_other.key.set("sh175-child-other");
            child_other.configuration = try testingAgentSpec(&.{"other"}, "ask");
            child_other.configuration.parent.state = .value;
            try child_other.configuration.parent.value.set(subset_root);
            try std.testing.expectEqual(protocol.ConfigurationRejection.tools_not_in_parent, (try storage.configure(&child_other, .{})).rejected.code);
        }
    }.run);
}

const ask_only_declaration = "[{\"name\":\"ask\",\"description\":\"Ask.\",\"input_schema\":{\"type\":\"object\"}}]";

// SH-176: settlement classifies a call by the owner its frozen offer gives the name. A Host tool that takes an app tool's
// name while the request is in flight does not reclassify the call the model was offered as the app's. A Host tool
// already present at admission is what the projection offers, and the app tool it shadows is not offered.
test "SH-176 settlement classifies a call by its frozen offer's owner, and a Host tool present at admission shadows the app tool" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const mcp_ask = comptime testingHostToolRecords(&.{.{ .name = "ask", .owner = .mcp, .server = "notes", .description = "Ask.", .input_schema = "{\"type\":\"object\"}" }});
            var mcp_digests: [mcp_ask.len][32]u8 = undefined;
            for (&mcp_ask, &mcp_digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            var key_buffer: [96]u8 = undefined;
            var root_buffer: [128]u8 = undefined;
            for ([_]bool{ false, true }) |narrowed| {
                const tag = if (narrowed) "narrow" else "wide";
                // In flight: the Host tool takes the app tool's name after the request is admitted, before it settles.
                try storage.saveHostToolSet(&tool_defs.built_in_tool_set);
                var create = try store_testing.completeConfiguration(try std.fmt.bufPrint(&key_buffer, "sh176-root-{s}", .{tag}), "", workspace, "model-a");
                declareAppTools(&create.configuration, two_app_tools);
                if (narrowed) create.configuration.tools = try .of(&.{ "ask", "find_tools" });
                const root_reply = try storage.configure(&create, .{});
                try expectAccepted("root", root_reply);
                const root = copyRef(&root_buffer, root_reply.accepted.session.slice());
                const binding = try admitMessage(&storage, &tmp, try std.fmt.bufPrint(&key_buffer, "sh176-in-flight-{s}", .{tag}), root);
                var admitted: Offered = undefined;
                try offerOf(&storage, binding, &admitted);
                try std.testing.expectEqual(tool_record.Owner.app, admitted.owner("ask").?);
                try storage.saveHostToolSet(&.{ .records = &mcp_ask, .digests = &mcp_digests });
                try settleCallsForTesting(&storage, &tmp, binding, try std.fmt.bufPrint(&key_buffer, "sh176-calls-{s}", .{tag}), &.{.{
                    .item_id = "item-1",
                    .name = "ask",
                    .encoded_call_id = "call-1",
                    .decoded_call_id = "call-1",
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                }});
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE parent_operation_id=?1 AND resolution_code='failed'", .{binding.operation_id}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE parent_operation_id=?1 AND resolution_code IS NULL", .{binding.operation_id}));

                // At admission: the root was declared before the Host tool came, and now the Host tool is in the set, so the next request
                // offers the Host tool for the name and no app tool of that name.
                // A selection saved before the Host tool came holds the app member; the narrowed root names the tool again to hold the Host one.
                if (narrowed) {
                    var refresh: wire_request.ConfigureCommand = .{};
                    try refresh.key.set(try std.fmt.bufPrint(&key_buffer, "sh176-refresh-{s}", .{tag}));
                    try refresh.session.set(root);
                    refresh.configuration.tools = try .of(&.{ "ask", "find_tools" });
                    try expectAccepted("refresh", try storage.configure(&refresh, .{}));
                }
                const second = try admitMessage(&storage, &tmp, try std.fmt.bufPrint(&key_buffer, "sh176-second-{s}", .{tag}), root);
                var offered: Offered = undefined;
                try offerOf(&storage, second, &offered);
                if (narrowed) {
                    try std.testing.expectEqual(tool_record.Owner.mcp, offered.owner("ask").?);
                } else {
                    try std.testing.expect(offered.owner("ask") == null);
                }
            }
        }
    }.run);
}
