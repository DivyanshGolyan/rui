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

test "a model admission freezes an offer the Host's tool set no longer holds, and a later one reuses the set it saved" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const records = comptime testingHostToolRecords(&.{
                .{ .name = "read_page", .owner = .mcp, .server = "docs", .read_only = true, .description = "Read a page.", .input_schema = "{\"type\":\"object\"}" },
                .{ .name = "write_page", .owner = .mcp, .server = "docs", .description = "Write a page.", .input_schema = "{\"type\":\"object\"}" },
            });
            const digests = comptime blk: {
                @setEvalBranchQuota(1_000_000);
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
                .{ .name = "read_page", .owner = .mcp, .server = "docs", .read_only = true, .description = "Read a page.", .input_schema = "{\"type\":\"object\"}" },
            });
            const kept_digests = comptime blk: {
                @setEvalBranchQuota(1_000_000);
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

test "stop_action follows the frozen read_action offer" {
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
                try std.testing.expectEqual(@as(u64, if (mask & 1 != 0) 1 else 0), count);
            }
        }
    }.run);
}

test "stop_action effective offer preserves the historical settings limit" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const extras = comptime blk: {
                @setEvalBranchQuota(1_000_000);
                var records: [126]tool_defs.Record = undefined;
                const remaining_bytes = protocol.max_tool_list_name_bytes - "find_tools".len - "read_action".len;
                for (&records, 0..) |*record, i| {
                    const prefix = std.fmt.comptimePrint("stub{d:0>3}", .{i});
                    const length = remaining_bytes / records.len + @intFromBool(i < remaining_bytes % records.len);
                    record.* = .{
                        .name = prefix ++ @as([length - prefix.len]u8, @splat('x')),
                        .owner = .mcp,
                        .server = "docs",
                        .read_only = true,
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
                        const expected = count - @as(usize, @intFromBool(!loaded_read)) - @as(usize, @intFromBool(explicit and !loaded_read)) + @as(usize, @intFromBool(!explicit and loaded_read));
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
                                    if (std.mem.eql(u8, name, "stop_action")) {
                                        try std.testing.expect(loaded_read);
                                    } else try std.testing.expect(loaded.contains(name));
                                    try std.testing.expect(try page.nextTool(&tool));
                                    try std.testing.expectEqualStrings(name, tool.name.slice());
                                    previous = name;
                                    name_bytes += name.len;
                                }
                                try std.testing.expect(!try page.nextTool(&tool));
                                if (count == protocol.max_tools and !explicit and loaded_read) {
                                    try std.testing.expectEqual(@import("../../tool_name.zig").max_offered_list_name_bytes, name_bytes);
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
                @setEvalBranchQuota(1_000_000);
                var records: [127]tool_defs.Record = undefined;
                const bytes = protocol.max_tool_list_name_bytes - "find_tools".len;
                for (&records, 0..) |*record, index| {
                    const prefix = std.fmt.comptimePrint("stub{d:0>3}", .{index});
                    const length = bytes / records.len + @intFromBool(index < bytes % records.len);
                    record.* = .{
                        .name = prefix ++ @as([length - prefix.len]u8, @splat('x')),
                        .owner = .mcp,
                        .server = "docs",
                        .read_only = true,
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
                const configured = try storage.configure(&create, .{});
                const submitted = storage.submitMessageWithModel(&message, null, .{});
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
                const configured = try storage.configure(&create, .{});
                const submitted = storage.submitMessageWithModel(&message, null, .{});
                try std.testing.expect(configured == .accepted and configured.accepted.replayed);
                try std.testing.expect(submitted == .accepted and submitted.accepted.replayed);
                try std.testing.expectEqualStrings(config_session.slice(), configured.accepted.session.slice());
                try std.testing.expectEqualStrings(message_session.slice(), submitted.accepted.session.slice());
                try check(configured.accepted.configuration, expected_names);
                try check(submitted.accepted.configuration, expected_names);
            }
        }

        fn check(receipt: ?@import("../../creation_receipt.zig").Configuration, expected: []const u8) !void {
            try std.testing.expect(receipt != null);
            try std.testing.expectEqualStrings(expected, receipt.?.tools.slice());
            try std.testing.expectEqualStrings(expected, receipt.?.loaded_tools.slice());
        }
    }.run);
}
