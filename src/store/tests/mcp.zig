//! Mcp Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const store_testing = @import("../testing.zig");
const ActionAttemptBinding = action_domain.ActionAttemptBinding;
const ActionSettlement = action_domain.ActionSettlement;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const TestingCall = shared_fixtures.TestingCall;
const expectOneWork = shared_fixtures.expectOneWork;
const membershipToolSet = shared_fixtures.membershipToolSet;
const membership_records = shared_fixtures.membership_records;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const testingListRow = shared_fixtures.testingListRow;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

test "MCP settlement saves one decoded presentation line or the tool name" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            const records = testingHostToolRecords(&.{.{
                .name = "fetch_page",
                .owner = .mcp,
                .server = "docs",
                .description = "Fetch a page.",
                .input_schema = "{\"type\":\"object\",\"properties\":{}}",
            }});
            const digests = blk: {
                var out: [records.len][32]u8 = undefined;
                for (records, &out) |record, *digest| digest.* = tool_defs.recordDigest(&record);
                break :blk out;
            };
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            const Case = struct { arguments: []const u8, expected: []const u8 = "fetch_page" };
            const cases = [_]Case{
                .{ .arguments = "{\"rui_call_description\":\"Fetch page\"}", .expected = "Fetch page" },
                .{ .arguments = "{\"rui_call_description\":\"" ++ @as([200]u8, @splat('a')) ++ "\"}", .expected = &@as([200]u8, @splat('a')) },
                .{ .arguments = "{\"rui_call_description\":\"" ++ @as([200]u8, @bitCast(@as([100][2]u8, @splat("é".*)))) ++ "\"}", .expected = &@as([200]u8, @bitCast(@as([100][2]u8, @splat("é".*)))) },
                .{ .arguments = "{\"rui_call_description\":\"Fetch \\u00e9 page\"}", .expected = "Fetch é page" },
                .{ .arguments = "{\"padding\":\"" ++ @as([4100]u8, @splat('x')) ++ "\",\"rui_call_description\":\"Fetch after padding\"}", .expected = "Fetch after padding" },
                .{ .arguments = "{\"rui_call_\\u0064escription\":\"" ++ @as([1200]u8, @bitCast(@as([200][6]u8, @splat("\\u0061".*)))) ++ "\"}", .expected = &@as([200]u8, @splat('a')) },
                .{ .arguments = "{\"rui_call_description\":\"" ++ @as([201]u8, @splat('a')) ++ "\"}" },
                .{ .arguments = "{\"rui_call_description\":\"" ++ @as([202]u8, @bitCast(@as([101][2]u8, @splat("é".*)))) ++ "\"}" },
                .{ .arguments = "{}" },
                .{ .arguments = "{\"rui_call_description\":7}" },
                .{ .arguments = "{\"rui_call_description\":null}" },
                .{ .arguments = "{\"rui_call_description\":\"\"}" },
                .{ .arguments = "{\"rui_call_description\":\" \\t\\u00a0\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\npage\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\rpage\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\u0085page\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\u2028page\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch\\u2029page\"}" },
                .{ .arguments = "{\"rui_call_description\":\"Fetch page\",\"broken\":" },
            };
            for (cases) |line| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("mcp-line-config", "", try canonicalCwd(std.testing.io, &workspace), "model-a");
                configure.configuration.tools = try .of(&.{"fetch_page"});
                const configured = try storage.configure(&configure, .{});
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "mcp-line-input", "mcp-line-message", session.slice(), "fetch");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var encoded: [8192]u8 = undefined;
                var writer = std.Io.Writer.fixed(&encoded);
                try std.json.Stringify.value(line.arguments, .{}, &writer);
                const quoted = writer.buffered();
                try settleCallsForTesting(&storage, &tmp, binding, "mcp-line-calls", &.{.{
                    .item_id = "item-1",
                    .name = "fetch_page",
                    .encoded_call_id = "call-1",
                    .decoded_call_id = "call-1",
                    .encoded_arguments = quoted[1 .. quoted.len - 1],
                    .decoded_arguments = line.arguments,
                }});
                errdefer std.debug.print("MCP arguments: {s}\n", .{line.arguments});
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE description=?1", .{line.expected}));
                if (line.expected.len == 200) {
                    // These projections must read the frozen row, not parse
                    // the original arguments or shorten it to the Bash bound.
                    const page = try store_core.activityPageForTesting(&storage, .{ .session = session });
                    try std.testing.expectEqual(@as(usize, 1), page.call_activity.count);
                    try std.testing.expectEqualStrings(line.expected, page.call_activity.entries[0].presentation.description.?.slice());
                    const report = try testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
                    defer std.testing.allocator.free(report);
                    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
                    defer parsed.deinit();
                    const unresolved = parsed.value.object.get("actions").?.object.get("unresolved").?.array.items;
                    try std.testing.expectEqualStrings(line.expected, unresolved[0].object.get("presentation").?.object.get("description").?.string);
                }
            }
        }
    }.run);
}

test "saved MCP call lines survive all work reads pending, running and completed at every boundary" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            var digests: [membership_records.len][32]u8 = undefined;
            const host_tool_set = membershipToolSet(&digests);
            for ([_]usize{ 100, 101, 200 }) |length| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                var workspace: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("mcp-work-config", "", try canonicalCwd(std.testing.io, &workspace), "model-a");
                configure.configuration.tools = try .of(&.{"fetch_page"});
                configure.configuration.permission_mode.state = .value;
                try configure.configuration.permission_mode.value.set("bypass");
                const configured = try storage.configure(&configure, .{});
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "mcp-work-input", "mcp-work-message", session.slice(), "fetch");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var description: [protocol.max_tool_description_bytes]u8 = @splat('x');
                for (0..length / 2) |i| @memcpy(description[i * 2 ..][0..2], "é");
                const text = description[0..length];
                var arguments: [1024]u8 = undefined;
                const args = try std.fmt.bufPrint(&arguments, "{{\"rui_call_description\":\"{s}\"}}", .{text});
                var encoded: [2048]u8 = undefined;
                var writer = std.Io.Writer.fixed(&encoded);
                try std.json.Stringify.value(args, .{}, &writer);
                const quoted = writer.buffered();
                try settleCallsForTesting(&storage, &tmp, model, "mcp-work-calls", &.{.{
                    .item_id = "item-1",
                    .name = "fetch_page",
                    .encoded_call_id = "call-1",
                    .decoded_call_id = "call-1",
                    .encoded_arguments = quoted[1 .. quoted.len - 1],
                    .decoded_arguments = args,
                }});
                try reads(&storage, &tmp, session.slice(), "pending", text);
                const action = (try storage.nextAction(.mcp)).?;
                const binding = (try storage.admitActionAttempt(action, 600_000, .{})).?.permit.binding;
                try reads(&storage, &tmp, session.slice(), "bash", text);
                _ = try storage.settleActionAttempt(binding, .succeeded, "done", .{});
                try reads(&storage, &tmp, session.slice(), "pending", text);
            }
        }

        fn reads(storage: *Store, tmp: *std.testing.TmpDir, session: []const u8, kind: []const u8, description: []const u8) !void {
            // This compares the entire Current and Activity state, not just
            // its kind. List and Message progress must project that same text.
            _ = try expectOneWork(storage, tmp, session, kind);
            var request: protocol.ActivityPage = .{};
            try request.session.set(session);
            const page = try store_core.activityPageForTesting(storage, request);
            for (page.call_activity.entries[0..page.call_activity.count]) |*call|
                try std.testing.expectEqualStrings(description, call.presentation.description.?.slice());
            var listed = try testingListRow(storage, tmp, session);
            defer listed.deinit();
            try std.testing.expectEqualStrings(kind, listed.get(&.{ "work", "state", "kind" }).string);
            const observed = (try store_testing.observeCommandForTesting(storage, "mcp-work-message")).kind.message.?;
            const state = observed.work.?.state;
            try std.testing.expectEqualStrings(kind, @tagName(state));
            if (state == .bash) {
                try std.testing.expectEqualStrings(description, page.work.work.state.bash.description.?.slice());
                try std.testing.expectEqualStrings(description, listed.get(&.{ "work", "state", "description" }).string);
                try std.testing.expectEqualStrings(description, state.bash.description.?.slice());
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "MCP read-only ordering uses frozen offers and admits read waves between writes" {
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
            const patterns = [_]struct { reads: []const bool, waves: []const usize }{
                .{ .reads = &.{ false, true, true, false }, .waves = &.{ 1, 2, 1 } },
                .{ .reads = &.{ true, true }, .waves = &.{2} },
                .{ .reads = &.{ false, false }, .waves = &.{ 1, 1 } },
            };
            for (patterns) |pattern| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try completeConfiguration("read-only-order", "", try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                configure.configuration.tools = try .of(&.{ "read_page", "write_page" });
                configure.configuration.permission_mode.state = .value;
                try configure.configuration.permission_mode.value.set("bypass");
                const configured = try storage.configure(&configure, .{});
                try std.testing.expect(configured == .accepted);
                const session = configured.accepted.session;
                try submitTestMessage(&storage, &tmp, "read-only-input", "read-only-message", session.slice(), "exercise read waves");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                var calls: [4]TestingCall = undefined;
                const ids = [_][]const u8{ "call-a", "call-b", "call-c", "call-d" };
                for (pattern.reads, 0..) |read, index| calls[index] = .{
                    .item_id = ids[index],
                    .name = if (read) "read_page" else "write_page",
                    .encoded_call_id = ids[index],
                    .decoded_call_id = ids[index],
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                };
                try settleCallsForTesting(&storage, &tmp, model, "read-only-calls", calls[0..pattern.reads.len]);

                // Today's tool set now says the opposite. Admission must still
                // follow each call's frozen offer, and both record identities
                // must coexist rather than overwrite one another.
                var changed_records = records;
                var changed_digests = digests;
                for (&changed_records, &changed_digests) |*record, *digest| {
                    if (record.owner == .mcp) record.read_only = !record.read_only;
                    digest.* = tool_defs.recordDigest(record);
                }
                const changed: tool_defs.HostToolSet = .{ .records = &changed_records, .digests = &changed_digests };
                try storage.saveHostToolSet(&changed);
                try std.testing.expectEqual(@as(u64, 4), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_record WHERE owner='mcp'", .{}));
                for ([_][]const u8{ "read_page", "write_page" }) |name| {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_record WHERE name=?1 AND read_only=0", .{name}));
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_record WHERE name=?1 AND read_only=1", .{name}));
                }
                var saved = (try storage.readHostToolSet(std.testing.allocator)).?;
                defer saved.deinit(std.testing.allocator);
                const saved_tool_set = saved.toolSet();
                for (changed.records, changed.digests) |record, digest| {
                    const index = saved_tool_set.find(record.name).?;
                    try std.testing.expectEqual(record.read_only, saved_tool_set.records[index].read_only);
                    try std.testing.expectEqualSlices(u8, &digest, &saved_tool_set.digests[index]);
                }
                // Re-saving the original tool set reuses its set and records.
                const sets = try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{});
                try storage.saveHostToolSet(&host_tool_set);
                try std.testing.expectEqual(sets, try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set", .{}));
                try storage.saveHostToolSet(&changed);

                var ready: [4]action_domain.ReadyAction = undefined;
                var bindings: [4]ActionAttemptBinding = undefined;
                for (ready[0..pattern.reads.len], 0..) |*action, index| {
                    action.* = .{ .action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1 AND call_ordinal=?2", .{ model.operation_id, index }), .runner = .mcp };
                    try action.server.set("docs");
                }
                var start: usize = 0;
                for (pattern.waves) |width| {
                    const end = start + width;
                    for (start..end) |index| {
                        const next = try storage.nextAction(.mcp);
                        try std.testing.expect(next != null);
                        const selected = next.?;
                        try std.testing.expectEqual(ready[index].action_id, selected.action_id);
                        bindings[index] = (try storage.admitActionAttempt(selected, 1234, .{})).?.permit.binding;
                        // A caller cannot bypass selection's barrier by holding
                        // a later Action id and asking for admission directly.
                        for (ready[end..pattern.reads.len]) |blocked| {
                            try std.testing.expect((try storage.admitActionAttempt(blocked, 1234, .{})) == null);
                        }
                    }
                    try std.testing.expect((try storage.nextAction(.mcp)) == null);
                    for (start..end) |index| {
                        try std.testing.expectEqual(ActionSettlement.effect, try storage.settleActionAttempt(bindings[index], .succeeded, "done", .{}));
                        if (index + 1 < end) try std.testing.expect((try storage.nextAction(.mcp)) == null);
                    }
                    start = end;
                }
                try std.testing.expect((try storage.nextAction(.mcp)) == null);
            }
        }
    }.run);
}
