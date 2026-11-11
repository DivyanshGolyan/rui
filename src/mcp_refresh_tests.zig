//! Current MCP offers are derived from intent and frozen only at admission.
const std = @import("std");
const store = @import("store.zig");
const testing = store.testing;
const tools = @import("tools.zig");
const protocol = @import("protocol.zig");

const Records = [tools.built_in.records.len + 2]tools.Record;
fn records() Records {
    return testing.catalogRecordsWith(&.{
        .{ .name = "fetch_a", .owner = .mcp, .server = "docs", .description = "old a", .input_schema = "{}" },
        .{ .name = "fetch_b", .owner = .mcp, .server = "docs", .description = "old b", .input_schema = "{}" },
    });
}
fn catalog(rows: []const tools.Record, digests: [][32]u8) tools.Catalog {
    for (rows, digests) |*row, *digest| digest.* = tools.recordDigest(row);
    return .{ .records = rows, .digests = digests };
}
fn revisions(storage: *store.Store, session: []const u8) !u64 {
    return testing.queryU64(storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1", .{session});
}
fn member(storage: *store.Store, session: []const u8, name: []const u8) !bool {
    return 1 == try testing.queryU64(storage, "SELECT count(*) FROM model_operation o JOIN tool_set_member m ON m.tool_set_id=o.tool_set_id JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE o.operation_id=(SELECT max(latest.operation_id) FROM model_operation latest WHERE latest.session_ref=?1) AND t.name=?2", .{ session, name });
}
fn done(storage: *store.Store, tmp: *std.testing.TmpDir, binding: store.AttemptBinding) !void {
    try testing.settleItemsForTesting(storage, tmp, binding, &.{"{\"type\":\"message\",\"id\":\"done\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}"}, "done");
}

fn narrowedChild(storage: *store.Store, tmp: *std.testing.TmpDir, parent: protocol.Bounded(protocol.max_session_bytes)) !protocol.Bounded(protocol.max_session_bytes) {
    try testing.submitTestMessage(storage, tmp, "refresh-child-input", "refresh-child-input", parent.slice(), "start child");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store.settleCallsForTesting(storage, tmp, model, "refresh-child-call", &.{.{ .item_id = "child", .name = "start_agent", .encoded_call_id = "child", .decoded_call_id = "child", .encoded_arguments = "{}", .decoded_arguments = "{}" }});
    const action = (try storage.nextCoreWork()).?.action;
    var cwd: [protocol.max_workspace_bytes]u8 = undefined;
    var spec = try testing.completeConfiguration("unused", "", try testing.canonicalCwd(std.testing.io, &cwd), "model-a");
    spec.configuration.tools = try .of(&.{"fetch_a"});
    const Capture = struct {
        child: protocol.Bounded(protocol.max_session_bytes) = .{},
        fn call(context: *anyopaque, admission: store.Store.MessageAdmission) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.child.set(admission.session) catch unreachable;
        }
    };
    var capture: Capture = .{};
    try std.testing.expect(try storage.startAgent(action.binding, parent.slice(), "read a", true, &spec.configuration, .{ .context = &capture, .call = Capture.call }, .{}) == .started);
    const continuation = (try storage.admitModelAttempt(.tool_continuation, .{})).?.permit.binding;
    try done(storage, tmp, continuation);
    return capture.child;
}

test "MCP offer projection covers identity changes removals additions and name narrowing" {
    try testing.forEachEngine(struct {
        fn run(engine: *testing.Case) !void {
            const Scenario = enum { unchanged, description, schema, server, read_only, owner, name, removed, mixed, added, builtins, narrowed, unloaded, key_namespace };
            for (std.enums.values(Scenario)) |scenario| {
                errdefer std.debug.print("MCP refresh scenario {s}\n", .{@tagName(scenario)});
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var before_rows = records();
                var before_digests: [before_rows.len][32]u8 = undefined;
                const before = catalog(&before_rows, &before_digests);
                var storage: store.Store = undefined;
                try testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .catalog = &before });
                defer storage.close() catch unreachable;
                var cwd: [protocol.max_workspace_bytes]u8 = undefined;
                var configure = try testing.completeConfiguration("refresh-config", "", try testing.canonicalCwd(std.testing.io, &cwd), "model-a");
                configure.configuration.tools = try .of(if (scenario == .builtins) &.{"bash"} else if (scenario == .narrowed) &.{ "fetch_a", "fetch_b", "start_agent" } else &.{ "fetch_a", "fetch_b", "find_tools" });
                if (scenario == .unloaded) configure.configuration.loaded_tools = try .of(&.{"find_tools"});
                var session = (try storage.configure(&configure, .{})).accepted.session;
                if (scenario == .narrowed) session = try narrowedChild(&storage, &tmp, session);
                try testing.submitTestMessage(&storage, &tmp, "refresh-first", "refresh-first", session.slice(), "start");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try done(&storage, &tmp, first);
                if (scenario == .key_namespace) {
                    var patch: @import("wire_request.zig").ConfigureCommand = .{};
                    var key: [96]u8 = undefined;
                    try patch.key.set(try std.fmt.bufPrint(&key, "rui.core/mcp_tools/{s}/2", .{session.slice()}));
                    patch.session = session;
                    patch.configuration.tools = try .of(&.{"fetch_a"});
                    try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                }
                var after_rows = records();
                const a = before.find("fetch_a").?;
                const b = before.find("fetch_b").?;
                var remove: ?usize = null;
                switch (scenario) {
                    .description, .unloaded => after_rows[a].description = "new a",
                    .schema => after_rows[a].input_schema = "{\"type\":\"object\"}",
                    .server => after_rows[a].server = "moved",
                    .read_only => after_rows[a].read_only = true,
                    .owner => {
                        after_rows[a].owner = .rui;
                        after_rows[a].server = "";
                    },
                    .name => after_rows[a].name = "fetch_new",
                    .removed => remove = a,
                    .mixed => {
                        after_rows[a].description = "new a";
                        remove = b;
                    },
                    .builtins, .narrowed, .key_namespace => after_rows[b].description = "new b",
                    .unchanged, .added => {},
                }
                // A removal and return exercise additions inside the saved name
                // ceiling; a brand-new renamed tool must not widen that ceiling.
                if (scenario == .added) {
                    var missing = records();
                    missing[a] = missing[missing.len - 1];
                    testing.sortCatalogRecords(missing[0 .. missing.len - 1]);
                    var digests: [missing.len - 1][32]u8 = undefined;
                    const absent = catalog(missing[0 .. missing.len - 1], &digests);
                    try storage.saveCatalog(&absent);
                    try testing.submitTestMessage(&storage, &tmp, "refresh-missing", "refresh-missing", session.slice(), "missing");
                    const missing_call = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try std.testing.expect(!try member(&storage, session.slice(), "fetch_a"));
                    try done(&storage, &tmp, missing_call);
                }
                var count = after_rows.len;
                if (remove) |index| {
                    count -= 1;
                    after_rows[index] = after_rows[count];
                }
                testing.sortCatalogRecords(after_rows[0..count]);
                var after_digests: [after_rows.len][32]u8 = undefined;
                const after = catalog(after_rows[0..count], after_digests[0..count]);
                try storage.saveCatalog(&after);
                const old_count = try revisions(&storage, session.slice());
                try testing.submitTestMessage(&storage, &tmp, "refresh-next", "refresh-next", session.slice(), "next");
                // Projection interning and the admitted Operation roll back together.
                if (scenario == .mixed and !engine.rerun) {
                    try std.testing.expectError(error.InjectedAttemptCommitFailure, storage.admitNextModelAttempt(.{ .attempt_before_commit = true }));
                    // A fault fences; reopen with the same startup catalog.
                    try storage.close();
                    try testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .catalog = &after });
                    try std.testing.expectEqual(old_count, try revisions(&storage, session.slice()));
                }
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(old_count, try revisions(&storage, session.slice()));
                try std.testing.expectEqual(scenario != .builtins and scenario != .removed and scenario != .name and scenario != .unloaded, try member(&storage, session.slice(), "fetch_a"));
                try std.testing.expect(!try member(&storage, session.slice(), "fetch_new"));
                if (scenario != .builtins and scenario != .removed and scenario != .name and scenario != .unloaded) {
                    // Identity equality, not just a revision increment: every
                    // field must resolve to today's saved record for this name.
                    try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM model_operation o JOIN tool_set_member m ON m.tool_set_id=o.tool_set_id JOIN tool_record t ON t.tool_record_id=m.tool_record_id JOIN host_catalog h ON h.slot=1 JOIN tool_set_member hm ON hm.tool_set_id=h.tool_set_id AND hm.tool_record_id=m.tool_record_id WHERE o.operation_id=?1 AND t.name='fetch_a'", .{next.operation_id}));
                }
                // Old frozen requests and their records are never rewritten.
                try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND settings_revision=1", .{first.operation_id}));
                // Only synthetic catalogs can change MCP ownership to an
                // unsupported Rui tool. Refresh still preserves that identity;
                // normal settlement correctly refuses such a catalog.
                if (scenario == .owner or scenario == .narrowed) continue;
                if (scenario == .removed) {
                    try store.settleCallsForTesting(&storage, &tmp, next, "refresh-removed-call", &.{.{ .item_id = "removed", .name = "fetch_a", .encoded_call_id = "removed", .decoded_call_id = "removed", .encoded_arguments = "{}", .decoded_arguments = "{}" }});
                    try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call WHERE operation_id=?1 AND rejection_code='unknown_tool'", .{next.operation_id}));
                    const removed_text = protocol.contentDigest(tools.removed_tool_result);
                    try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM model_tool_call mc JOIN content c ON c.content_id=mc.rejection_content_id WHERE mc.operation_id=?1 AND c.digest=?2", .{ next.operation_id, testing.Blob{ .bytes = &removed_text } }));
                    // Finish the tool-result continuation too.
                    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try done(&storage, &tmp, continuation);
                } else try done(&storage, &tmp, next);
                const saved_count = try revisions(&storage, session.slice());
                try testing.submitTestMessage(&storage, &tmp, "refresh-again", "refresh-again", session.slice(), "again");
                const again = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(saved_count, try revisions(&storage, session.slice()));
                try done(&storage, &tmp, again);
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

fn intended(storage: *store.Store, session: []const u8, name: []const u8, comptime loaded: bool) !bool {
    const sql = if (loaded)
        "SELECT count(*) FROM session s JOIN tool_set_member m ON m.tool_set_id=coalesce(s.loaded_tool_set_id,s.tool_set_id) JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name=?2"
    else
        "SELECT count(*) FROM session s JOIN tool_set_member m ON m.tool_set_id=s.tool_set_id JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name=?2";
    return 1 == try testing.queryU64(storage, sql, .{ session, name });
}

test "MCP intent removal return crosses explicit equal and changed tools and loaded tools" {
    try testing.forEachEngine(struct {
        fn run(engine: *testing.Case) !void {
            const Field = enum { tools, loaded_tools, omitted };
            for (std.enums.values(Field)) |field| for ([_]bool{ false, true }) |changed| {
                errdefer std.debug.print("intent field={s} changed={}\n", .{ @tagName(field), changed });
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var rows = records();
                var digests: [rows.len][32]u8 = undefined;
                const full = catalog(&rows, &digests);
                var storage: store.Store = undefined;
                try testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .catalog = &full });
                defer storage.close() catch unreachable;
                var cwd: [protocol.max_workspace_bytes]u8 = undefined;
                var config = try testing.completeConfiguration("intent-create", "", try testing.canonicalCwd(std.testing.io, &cwd), "model-a");
                config.configuration.tools = try .of(&.{ "fetch_a", "fetch_b", "find_tools" });
                const session = (try storage.configure(&config, .{})).accepted.session;
                try testing.submitTestMessage(&storage, &tmp, "intent-first", "intent-first", session.slice(), "first");
                const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try done(&storage, &tmp, first);
                var missing_rows = records();
                const a = full.find("fetch_a").?;
                missing_rows[a] = missing_rows[missing_rows.len - 1];
                testing.sortCatalogRecords(missing_rows[0 .. missing_rows.len - 1]);
                var missing_digests: [missing_rows.len - 1][32]u8 = undefined;
                const missing = catalog(missing_rows[0 .. missing_rows.len - 1], &missing_digests);
                try storage.saveCatalog(&missing);
                try testing.submitTestMessage(&storage, &tmp, "intent-missing", "intent-missing", session.slice(), "missing");
                const absent = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expect(!try member(&storage, session.slice(), "fetch_a"));
                try std.testing.expect(try intended(&storage, session.slice(), "fetch_a", false));
                try std.testing.expect(try intended(&storage, session.slice(), "fetch_a", true));
                try std.testing.expectEqual(@as(u64, 1), try revisions(&storage, session.slice()));
                try done(&storage, &tmp, absent);
                var patch: @import("wire_request.zig").ConfigureCommand = .{ .session = session };
                // Caller keys cannot change provenance or bypass explicit intent.
                var key: [96]u8 = undefined;
                try patch.key.set(try std.fmt.bufPrint(&key, "rui.core/mcp_tools/{s}/2", .{session.slice()}));
                switch (field) {
                    .tools => patch.configuration.tools = try .of(if (changed) &.{"fetch_b"} else &.{ "fetch_b", "find_tools" }),
                    .loaded_tools => patch.configuration.loaded_tools = try .of(if (changed) &.{"find_tools"} else &.{ "fetch_b", "find_tools" }),
                    .omitted => if (changed) {
                        patch.configuration.label.state = .value;
                        try patch.configuration.label.value.set("not tool intent");
                    },
                }
                try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
                try testing.submitTestMessage(&storage, &tmp, "intent-patched", "intent-patched", session.slice(), "patched");
                const patched = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(field != .loaded_tools or !changed, try member(&storage, session.slice(), "fetch_b"));
                try std.testing.expectEqual(field != .tools or !changed, try member(&storage, session.slice(), "find_tools"));
                try done(&storage, &tmp, patched);
                // A new identity returning after reopen must obey name intent,
                // not an earlier change row or the latest reduced offer.
                rows[a].description = "returned a";
                const returned = catalog(&rows, &digests);
                try storage.close();
                try testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .catalog = &returned });
                try testing.submitTestMessage(&storage, &tmp, "intent-return", "intent-return", session.slice(), "returned");
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(field == .omitted, try member(&storage, session.slice(), "fetch_a"));
                try std.testing.expectEqual(field != .tools, try intended(&storage, session.slice(), "fetch_a", false));
                try std.testing.expectEqual(field == .omitted, try intended(&storage, session.slice(), "fetch_a", true));
                try std.testing.expectEqual(@as(u64, 2), try revisions(&storage, session.slice()));
                try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM model_operation o JOIN tool_set_member m ON m.tool_set_id=o.tool_set_id JOIN tool_record t ON t.tool_record_id=m.tool_record_id JOIN content c ON c.content_id=t.description_content_id WHERE o.operation_id=?1 AND t.name='fetch_a' AND c.digest=?2", .{ first.operation_id, testing.Blob{ .bytes = &protocol.contentDigest("old a") } }));
                try done(&storage, &tmp, next);
                try std.testing.expect(!storage.isFenced());
            };
        }
    }.run);
}

test "MCP find_tools expands loaded intent without losing or inventing unavailable names" {
    try testing.forEachEngine(struct {
        fn run(engine: *testing.Case) !void {
            for ([_]bool{ false, true }) |a_loaded| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                var rows = records();
                var digests: [rows.len][32]u8 = undefined;
                const full = catalog(&rows, &digests);
                var storage: store.Store = undefined;
                try testing.testingStoreWith(engine, &storage, &tmp, std.testing.io, .{ .catalog = &full });
                defer storage.close() catch unreachable;
                var cwd: [protocol.max_workspace_bytes]u8 = undefined;
                var config = try testing.completeConfiguration("load-intent-create", "", try testing.canonicalCwd(std.testing.io, &cwd), "model-a");
                config.configuration.tools = try .of(&.{ "fetch_a", "fetch_b", "find_tools" });
                config.configuration.loaded_tools = try .of(if (a_loaded) &.{ "fetch_a", "find_tools" } else &.{"find_tools"});
                const session = (try storage.configure(&config, .{})).accepted.session;
                var missing_rows = records();
                missing_rows[full.find("fetch_a").?] = missing_rows[missing_rows.len - 1];
                testing.sortCatalogRecords(missing_rows[0 .. missing_rows.len - 1]);
                var missing_digests: [missing_rows.len - 1][32]u8 = undefined;
                const missing = catalog(missing_rows[0 .. missing_rows.len - 1], &missing_digests);
                try storage.saveCatalog(&missing);
                try testing.submitTestMessage(&storage, &tmp, "load-intent-start", "load-intent-start", session.slice(), "find");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try store.settleCallsForTesting(&storage, &tmp, model, "load-intent-call", &.{.{ .item_id = "find", .name = "find_tools", .encoded_call_id = "find", .decoded_call_id = "find", .encoded_arguments = "{\\\"words\\\":\\\"fetch_b\\\"}", .decoded_arguments = "{\"words\":\"fetch_b\"}" }});
                const input = (try storage.nextCoreWork()).?.action;
                try @import("find_tools.zig").run(&storage, arena.allocator(), &input, .{});
                try std.testing.expectEqual(a_loaded, try intended(&storage, session.slice(), "fetch_a", true));
                try std.testing.expect(try intended(&storage, session.slice(), "fetch_b", true));
                const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expect(!try member(&storage, session.slice(), "fetch_a"));
                try std.testing.expect(try member(&storage, session.slice(), "fetch_b"));
                try done(&storage, &tmp, continuation);
                try storage.saveCatalog(&full);
                try testing.submitTestMessage(&storage, &tmp, "load-intent-return", "load-intent-return", session.slice(), "return");
                const returned = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try std.testing.expectEqual(a_loaded, try member(&storage, session.slice(), "fetch_a"));
                try std.testing.expect(try member(&storage, session.slice(), "fetch_b"));
                try std.testing.expectEqual(@as(u64, 2), try revisions(&storage, session.slice()));
                try done(&storage, &tmp, returned);
            }
        }
    }.run);
}
