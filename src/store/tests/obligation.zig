const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const reads_domain = @import("../domain/reads.zig");
const report_domain = @import("../domain/report.zig");
const store_testing = @import("../testing.zig");
const history = @import("../history.zig");
const TestingAnswerPart = store_testing.TestingAnswerPart;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const TestingListing = shared_fixtures.TestingListing;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const expectOneWork = shared_fixtures.expectOneWork;
const refreshFrontierForTesting = shared_fixtures.refreshFrontierForTesting;
const refreshFrontiersForTesting = shared_fixtures.refreshFrontiersForTesting;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingAgentSpec = shared_fixtures.testingAgentSpec;
const testingIdLess = shared_fixtures.testingIdLess;
const testingListRow = shared_fixtures.testingListRow;

test "obligation projection recomputes a dirty forest together in either head order" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |reverse| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const root = try configureTestSession(&storage, "forest-root");
                const left = try configureTestSession(&storage, "forest-left");
                const right = try configureTestSession(&storage, "forest-right");
                const separate = try configureTestSession(&storage, "forest-separate");
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref IN (?2,?3)", .{ root.slice(), left.slice(), right.slice() });
                try submitTestMessage(&storage, &tmp, "forest-left", "forest-left-task", left.slice(), "left");
                try submitTestMessage(&storage, &tmp, "forest-right", "forest-right-task", right.slice(), "right");
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=?1 WHERE session_ref=?2", .{ @as(u64, 100), left.slice() });
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=?1 WHERE session_ref=?2", .{ @as(u64, 50), right.slice() });
                try refreshFrontiersForTesting(&storage, &.{ left.slice(), right.slice() });
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=?1 WHERE session_ref=?2", .{ @as(u64, 300), left.slice() });
                try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=?1 WHERE session_ref=?2", .{ @as(u64, 200), right.slice() });
                const before = storage.testing_content_work.rounds;
                if (reverse) {
                    try refreshFrontiersForTesting(&storage, &.{ separate.slice(), root.slice(), right.slice(), left.slice() });
                } else {
                    try refreshFrontiersForTesting(&storage, &.{ left.slice(), right.slice(), root.slice(), separate.slice() });
                }
                if (!case.rerun) try std.testing.expectEqual(@as(u32, 2), storage.testing_content_work.rounds - before);
                try std.testing.expectEqual(@as(u64, 200), try store_testing.queryU64(&storage, "SELECT obligation_since FROM session WHERE session_ref=?1", .{root.slice()}));
                try std.testing.expectEqual(@as(u64, 300), try store_testing.queryU64(&storage, "SELECT obligation_since FROM session WHERE session_ref=?1", .{left.slice()}));
                try std.testing.expectEqual(@as(u64, 200), try store_testing.queryU64(&storage, "SELECT obligation_since FROM session WHERE session_ref=?1", .{right.slice()}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE session_ref=?1 AND obligation_since IS NOT NULL", .{separate.slice()}));
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "obligation projection rejects a cyclic component even alongside a rooted component" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |three_node| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const root = try configureTestSession(&storage, "cycle-root");
                const left = try configureTestSession(&storage, "cycle-left");
                const right = try configureTestSession(&storage, "cycle-right");
                const extra = try configureTestSession(&storage, "cycle-extra");
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ right.slice(), left.slice() });
                try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ if (three_node) extra.slice() else left.slice(), right.slice() });
                if (three_node) try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ left.slice(), extra.slice() });
                if (refreshFrontiersForTesting(&storage, &.{ root.slice(), left.slice() })) |_| {
                    return error.TestUnexpectedResult;
                } else |_| {}
                try std.testing.expect(storage.isFenced());
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE obligation_since IS NOT NULL", .{}));
            }
        }
    }.run);
}

test "Session work includes only attached descendants with unfinished work" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Descendant = enum { absent, working, approval, grandchild, finished, standalone, queued, excluded };
            inline for (std.enums.values(Descendant)) |descendant| {
                for ([_]bool{ false, true }) |root_finished| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    const root = try configureTestSession(&storage, "tree-root");
                    _ = try expectOneWork(&storage, &tmp, root.slice(), "idle");
                    if (root_finished) {
                        const answer = [_]TestingAnswerPart{.{ .encoded = "root done", .decoded = "root done" }};
                        try answerTestTurn(&storage, &tmp, root.slice(), "tree-root-answer", &answer);
                    }
                    if (descendant != .absent) {
                        const child = try configureTestSessionAsk(&storage, "tree-child");
                        if (descendant != .standalone) try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
                        const target = if (descendant == .grandchild) grandchild: {
                            const grandchild = try configureTestSession(&storage, "tree-grandchild");
                            try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ child.slice(), grandchild.slice() });
                            break :grandchild grandchild;
                        } else child;
                        if (descendant == .finished) {
                            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
                            try answerTestTurn(&storage, &tmp, target.slice(), "tree-answer", &answer);
                        } else {
                            try submitTestMessage(&storage, &tmp, "tree-task", "tree-message", target.slice(), "work");
                            if (descendant == .excluded) {
                                var stop = try completeSessionStop("tree-stop", target.slice());
                                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                            } else if (descendant != .queued) {
                                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                                if (descendant == .approval) try settleTwoActionsForTesting(&storage, &tmp, model, "tree-actions");
                            }
                        }
                    }
                    const busy = switch (descendant) {
                        .working, .approval, .grandchild, .queued, .finished => true,
                        .absent, .standalone, .excluded => false,
                    };
                    _ = try expectOneWork(&storage, &tmp, root.slice(), if (busy) "working" else if (root_finished) "finished" else "idle");
                    try std.testing.expect(!storage.isFenced());
                }
            }
        }
    }.run);
}

test "descendant changes invalidate ancestor tokens without invalidating standalone starters" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Shape = enum { child, grandchild, standalone };
            inline for (std.enums.values(Shape)) |shape| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("invalidate-root", "", workspace, "model-a");
                create.configuration.tools = try .of(&.{"start_agent"});
                const root = (try storage.configure(&create, .{})).accepted.session;
                const child = if (shape == .standalone) standalone: {
                    try submitTestMessage(&storage, &tmp, "starter-file", "starter-message", root.slice(), "start independently");
                    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    try settleCallsForTesting(&storage, &tmp, model, "starter-call", &.{.{
                        .item_id = "starter-item",
                        .name = "start_agent",
                        .encoded_call_id = "starter-call",
                        .decoded_call_id = "starter-call",
                        .encoded_arguments = "{}",
                        .decoded_arguments = "{}",
                    }});
                    const action = (try storage.nextCoreWork(.{ .free_credit = .one, .mcp_open = true })).?.action;
                    var spec = try testingAgentSpec(&.{}, "ask");
                    try std.testing.expect(try storage.startAgent(action.binding, root.slice(), "independent work", false, &spec, null, .{}) == .started);
                    const sessions = try TestingListing.read(&storage, &tmp, .{});
                    try std.testing.expectEqual(@as(usize, 2), sessions.count);
                    var agent: protocol.Bounded(protocol.max_session_bytes) = .{};
                    for (sessions.references[0..sessions.count]) |*ref| {
                        if (!std.mem.eql(u8, ref, root.slice())) try agent.set(ref);
                    }
                    var child_stop = try completeSessionStop("starter-child-stop", agent.slice());
                    try std.testing.expect(storage.stopSession(&child_stop, .{}) == .accepted);
                    var root_stop = try completeSessionStop("starter-root-stop", root.slice());
                    try std.testing.expect(storage.stopSession(&root_stop, .{}) == .accepted);
                    break :standalone agent;
                } else try configureTestSession(&storage, "invalidate-child");
                const unrelated = try configureTestSession(&storage, "invalidate-unrelated");
                if (shape != .standalone) try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
                const target = if (shape == .grandchild) grandchild: {
                    const grandchild = try configureTestSession(&storage, "invalidate-grandchild");
                    try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ child.slice(), grandchild.slice() });
                    break :grandchild grandchild;
                } else child;
                var request: protocol.ActivityPage = .{};
                try request.session.set(root.slice());
                var page: protocol.ActivityFacts = undefined;
                try storage.activityPage(&request, &page);
                var token = page.token.?;
                var listing = try TestingListing.read(&storage, &tmp, .{});
                var observed: store_core.Observed = undefined;
                try storage.observeCommand("invalidate-root", null, &observed);
                var observation_token = observed.full.token.?;
                var unrelated_request: protocol.ActivityPage = .{};
                try unrelated_request.session.set(unrelated.slice());
                var unrelated_page: protocol.ActivityFacts = undefined;
                try storage.activityPage(&unrelated_request, &unrelated_page);
                unrelated_request.since = unrelated_page.token.?;
                unrelated_request.position = unrelated_page.end;

                for (0..3) |phase| {
                    const queued = phase != 2;
                    request.position = page.end;
                    request.since = token;
                    if (queued) {
                        try submitTestMessage(&storage, &tmp, if (phase == 0) "invalidate-file" else "invalidate-more-file", if (phase == 0) "invalidate-message" else "invalidate-more", target.slice(), "queued");
                    } else {
                        var stop = try completeSessionStop("invalidate-stop", target.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    }
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE session_ref=?1", .{target.slice()}));
                    try storage.activityPage(&request, &page);
                    try std.testing.expectEqual(shape == .standalone, page.not_modified);
                    const kind = if (shape == .standalone) "stopped" else if (queued) "working" else "idle";
                    if (!page.not_modified) try std.testing.expectEqualStrings(kind, @tagName(page.work.work.state));
                    token = page.token.?;
                    try storage.observeCommand("invalidate-root", observation_token, &observed);
                    try std.testing.expectEqual(shape == .standalone, observed == .not_modified);
                    observation_token = if (observed == .full) observed.full.token.? else observed.not_modified;
                    const changed = try TestingListing.read(&storage, &tmp, .{ .since = listing.since });
                    try std.testing.expectEqual(protocol.ListDelta.changed, changed.delta);
                    var expected: [3]change_ring.Id = undefined;
                    var count: usize = 0;
                    expected[count] = target.slice()[0..protocol.session_id_bytes].*;
                    count += 1;
                    expected[count] = root.slice()[0..protocol.session_id_bytes].*;
                    count += 1;
                    if (shape == .grandchild) {
                        expected[count] = child.slice()[0..protocol.session_id_bytes].*;
                        count += 1;
                    }
                    std.mem.sort(change_ring.Id, expected[0..count], {}, testingIdLess);
                    try changed.expectReferences(expected[0..count]);
                    listing = changed;
                    _ = try expectOneWork(&storage, &tmp, root.slice(), kind);
                    var row = try testingListRow(&storage, &tmp, root.slice());
                    defer row.deinit();
                    try std.testing.expectEqualStrings(kind, row.get(&.{ "work", "state", "kind" }).string);
                    try storage.activityPage(&unrelated_request, &unrelated_page);
                    try std.testing.expect(unrelated_page.not_modified);
                    try std.testing.expect(!storage.isFenced());
                }
            }
        }
    }.run);
}

/// Ending kinds of the frontier test; their order is the bit order of obligationConfig.
const ObligationEnding = enum { normal, quiet, stopped };

/// One row of the frozen format-72 frontier state. `configs` has a bit per (ending, multi_hop) shape, bit
/// obligationConfig(ending, multi_hop). `mysql` is the row's MySQL text when it differs from `sqlite`: format 72
/// keeps a content's bytes in content_chunk on MySQL, not in content.payload. message_first changes no bit.
const ObligationRow = struct { configs: u6, sqlite: [:0]const u8, mysql: ?[:0]const u8 = null };

fn obligationConfig(comptime ending: ObligationEnding, comptime multi_hop: bool) u6 {
    const index = @as(usize, @backingInt(ending)) * 2 + @intFromBool(multi_hop);
    return @as(u6, 1) << index;
}

/// The rows every shape shares, per engine: the built-in tool sets and their content.
const obligation_shared_sqlite: [:0]const u8 = @embedFile("obligation_seed72.sqlite.sql");
const obligation_shared_mysql: [:0]const u8 = @embedFile("obligation_seed72.mysql.sql");

/// The rows of the frontier state at format 72, before the first Message is delivered, in an order that
/// satisfies the foreign keys. The last rows set each Message's turn after its Turn exists.
const obligation_rows = [_]ObligationRow{
    .{ .configs = 0b000001, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-root-answer-key',2,'rtfab1',X'f1c0b97d8be92abdd73b9fb460e552b268760bc17cb853c59a02dbea849c778d',20,NULL,1,'',0,0,2);" },
    .{ .configs = 0b111011, .sqlite = "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key,parent_ref) VALUES('rtfab1','/home/user/rui-pr6d','codex','openai-responses/2',NULL,NULL,'model-a',19,2,NULL,1,NULL,1,115200,NULL,'low',NULL,1795456910,6,1,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1,NULL);" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-root-answer-key',2,'rtfab1',X'3a5c29521848460944058c8406febcef1f6ee23c04cd275c688041e94a8452a1',20,NULL,1,'',0,0,2);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-root-answer-key',2,'rtfab1',X'c0ee535381b533711cbe3a1e33384e7375478a4b0a3ec6a1e097c963dd605b80',20,NULL,1,'',0,0,2);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key,parent_ref) VALUES('rtfab1','/home/user/rui-pr6d','codex','openai-responses/2',NULL,NULL,'model-a',19,2,NULL,1,NULL,1,115200,NULL,'low',NULL,1795456910,7,1,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1,NULL);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-root-answer-key',2,'rtfab1',X'84e337d86464e6dbfcec58336139e8fc3f07905fad7441ae344e52781b463af5',20,NULL,1,'',0,0,2);" },
    .{ .configs = 0b010000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-root-answer-key',2,'rtfab1',X'c563d15c7ac378fb160b3ec73e61358466b6914c7982e6a0d25c2bf2cb72d091',20,NULL,1,'',0,0,2);" },
    .{ .configs = 0b100000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-root-answer-key',2,'rtfab1',X'f69d40bad02fae7528cec42faaa98170044286fe19eac8b0f66f8e8aff1de821',20,NULL,1,'',0,0,2);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,sender_session_ref) VALUES(1,'rtfab1','owed-root-answer-key',20,1,NULL,1795456910,NULL);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-root',1,'rtfab1',X'03c6d9134b43b37296b650f5e6234f186b63b8765667fcf4897295de61c9a159',NULL,NULL,1,'',1,1,1);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label,effort_source_revision) VALUES('rtfab1',1,'owed-root','/home/user/rui-pr6d','codex','model-a',19,1,2,NULL,1,NULL,115200,NULL,'low',NULL,1);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES(1,'rtfab1',1,1,1,'completed',23,5,1795456910,NULL);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES('rtfab1',1,2,1,1,1,NULL,NULL,NULL,NULL,NULL,NULL,20,1795456910);" },
    .{ .configs = 0b010101, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-child',1,'chfab3',X'03c6d9134b43b37296b650f5e6234f186b63b8765667fcf4897295de61c9a159',NULL,NULL,1,'',1,1,3);" },
    .{ .configs = 0b010101, .sqlite = "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key,parent_ref) VALUES('chfab3','/home/user/rui-pr6d','codex','openai-responses/2',NULL,NULL,'model-a',19,2,NULL,1,NULL,1,115200,NULL,'low',NULL,1795456910,6,2,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1,'rtfab1');" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-child',1,'chfab3',X'03c6d9134b43b37296b650f5e6234f186b63b8765667fcf4897295de61c9a159',NULL,NULL,1,'',1,1,5);" },
    .{ .configs = 0b100010, .sqlite = "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key,parent_ref) VALUES('mdfab2','/home/user/rui-pr6d','codex','openai-responses/2',NULL,NULL,'model-a',19,2,NULL,1,NULL,1,115200,NULL,'low',NULL,1795456910,6,2,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1,'rtfab1');" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key,parent_ref) VALUES('mdfab2','/home/user/rui-pr6d','codex','openai-responses/2',NULL,NULL,'model-a',19,2,NULL,1,NULL,1,115200,NULL,'low',NULL,1795456910,7,2,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1,'rtfab1');" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key,parent_ref) VALUES('chfab3','/home/user/rui-pr6d','codex','openai-responses/2',NULL,NULL,'model-a',19,2,NULL,1,NULL,1,115200,NULL,'low',NULL,1795456910,6,3,X'4f734373106b18b4300a06683393f27fe72fcb98f82b72cb0a3b98950e714433',1,'mdfab2');" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label,effort_source_revision) VALUES('chfab3',1,'owed-child','/home/user/rui-pr6d','codex','model-a',19,1,2,NULL,1,NULL,115200,NULL,'low',NULL,1);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-middle',1,'mdfab2',X'03c6d9134b43b37296b650f5e6234f186b63b8765667fcf4897295de61c9a159',NULL,NULL,1,'',1,1,3);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label,effort_source_revision) VALUES('mdfab2',1,'owed-middle','/home/user/rui-pr6d','codex','model-a',19,1,2,NULL,1,NULL,115200,NULL,'low',NULL,1);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) VALUES(1,1,'rtfab1',1,1,3,0,115200,0,'low',1,1,0,NULL,NULL,'answer',23,NULL,X'01000000000000',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1795456910,NULL,NULL,NULL,2,1,NULL,0,NULL,NULL,NULL,128000);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) VALUES(1,0,'rtfab1',4,2,23,1,X'39dbe3cba52908fdb3610df812d007a7fc134eea8803b34a97e9aa229d815fae',0,0,22,1,NULL,0);" },
    .{ .configs = 0b000001, .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(25,X'8adb1df89108abd08615623106fec662fc8e745bd790ba2c7bf1791a870e000f',13,1,X'226964223a22616e7377657222');", .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(25,X'8adb1df89108abd08615623106fec662fc8e745bd790ba2c7bf1791a870e000f',13,1);INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(25,0,X'226964223a22616e7377657222');" },
    .{ .configs = 0b000001, .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(26,X'59d1f617dd0a42308bd85f83787f964356c0a21bc6d52bf1899479788d6751eb',10,0,X'6368696c6420646f6e65');", .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(26,X'59d1f617dd0a42308bd85f83787f964356c0a21bc6d52bf1899479788d6751eb',10,0);INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(26,0,X'6368696c6420646f6e65');" },
    .{ .configs = 0b010101, .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(24,X'f7c19691de5011347caa8e2afe10f6eea0f89c7cad32f17cba8c6b04b8e1dc19',6,0,X'616e73776572');", .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(24,X'f7c19691de5011347caa8e2afe10f6eea0f89c7cad32f17cba8c6b04b8e1dc19',6,0);INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(24,0,X'616e73776572');" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(24,X'16d37ad984fb55c19e49a2347fecc8e1b9c5d5df1c6a5ef181a13b3b3f278f00',11,0,X'6d6964646c6520646f6e65');", .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(24,X'16d37ad984fb55c19e49a2347fecc8e1b9c5d5df1c6a5ef181a13b3b3f278f00',11,0);INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(24,0,X'6d6964646c6520646f6e65');" },
    .{ .configs = 0b000001, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-message',2,'chfab3',X'6ffed68391b56d8a29065cee683554713a1c2bad3c31b276db93672bada9654e',24,NULL,1,'',0,0,4);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(25,X'f7c19691de5011347caa8e2afe10f6eea0f89c7cad32f17cba8c6b04b8e1dc19',6,0,X'616e73776572');", .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(25,X'f7c19691de5011347caa8e2afe10f6eea0f89c7cad32f17cba8c6b04b8e1dc19',6,0);INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(25,0,X'616e73776572');" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-message',2,'chfab3',X'd0cb56374ace90248ce0bf9aa538c8b4a901b72b0401acfca8b3dd823b9e2d47',25,NULL,1,'',0,0,6);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-message',2,'chfab3',X'ac9a6b8bcec5708fbda72de5d5eeaedebc0a705031f10461448b218c8236b422',24,NULL,1,'',0,0,4);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-message',2,'chfab3',X'1c38ae41433e3b36d8dea1ea688de63bc5812b8630059a482e393a414aa5f8f1',25,NULL,1,'',0,0,6);" },
    .{ .configs = 0b010000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-message',2,'chfab3',X'e20a611af4f289c543a8693fbd598fcac343d87d316b5b2538dafd10cffe320d',24,NULL,1,'',0,0,4);" },
    .{ .configs = 0b100000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-message',2,'chfab3',X'6645e41ab3b33c77cbfb50fc9df435ef9ff2c922213097c3671dc5330d961407',25,NULL,1,'',0,0,6);" },
    .{ .configs = 0b010101, .sqlite = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,sender_session_ref) VALUES(2,'chfab3','owed-message',24,1,NULL,1795456910,NULL);" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(26,X'8adb1df89108abd08615623106fec662fc8e745bd790ba2c7bf1791a870e000f',13,1,X'226964223a22616e7377657222');", .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(26,X'8adb1df89108abd08615623106fec662fc8e745bd790ba2c7bf1791a870e000f',13,1);INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(26,0,X'226964223a22616e7377657222');" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-middle-answer-key',2,'mdfab2',X'2e3275835df52c706828b2349cc40fa0f304fe9c39c69df9bffb039bd95146f3',20,NULL,1,'',0,0,4);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-middle-answer-key',2,'mdfab2',X'c85f67e0b129335ee3d261c8168ca5ce6376e509b086d8bb93c267f754059af8',20,NULL,1,'',0,0,4);" },
    .{ .configs = 0b100000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-middle-answer-key',2,'mdfab2',X'69343bfa976e6a210649785cb789ec122e6235e70c2d5033c5b4e4935af20b69',20,NULL,1,'',0,0,4);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,sender_session_ref) VALUES(2,'mdfab2','owed-middle-answer-key',20,1,NULL,1795456910,NULL);" },
    .{ .configs = 0b000001, .sqlite = "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES(2,'chfab3',2,2,2,'completed',26,5,1795456910,NULL);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES(2,'mdfab2',2,2,2,'completed',24,5,1795456910,NULL);" },
    .{ .configs = 0b010100, .sqlite = "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES(2,'chfab3',2,2,2,'cancelled',NULL,5,1795456910,NULL);" },
    .{ .configs = 0b000001, .sqlite = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) VALUES(2,2,'chfab3',1,2,3,0,115200,0,'low',1,1,0,NULL,NULL,'answer',26,NULL,X'01000000000000',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1795456910,NULL,NULL,NULL,2,1,NULL,0,NULL,NULL,NULL,128000);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) VALUES(2,2,'mdfab2',1,2,3,0,115200,0,'low',1,1,0,NULL,NULL,'answer',24,NULL,X'01000000000000',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1795456910,NULL,NULL,NULL,2,1,NULL,0,NULL,NULL,NULL,128000);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('rui.core/stop/owed/6',3,'chfab3',X'a254db6dc5dfe005bc920760071eb32d2c2682d5746200145baf47ef3ac8d691',NULL,NULL,1,'',0,0,6);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('rui.core/stop/owed/6',3,'chfab3',X'3e889beb744f4b0297b8053a69a58b886b965cc02d3fe96a62f524704cb575fc',NULL,NULL,1,'',0,0,8);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) VALUES(2,2,'chfab3',1,2,3,0,115200,0,'low',NULL,1,0,NULL,NULL,'interrupted',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'rui.core/stop/owed/6',NULL,NULL,1795456910,NULL,NULL,NULL,2,1,NULL,0,NULL,NULL,NULL,128000);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-stop',3,'rtfab1',X'76756a6a224222049f4967f79523cf96fe2b0fedd8fc59d6a24b28b11b52de34',NULL,NULL,1,'',0,0,5);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-stop',3,'mdfab2',X'b0f01cb6a22b43e3cea41b9d89f2ddfd4dbbb5fb21e5b228857eb5117e8e2ec1',NULL,NULL,1,'',0,0,7);" },
    .{ .configs = 0b010000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-stop',3,'chfab3',X'480e7c6ae25129350645fd1216764a2fb27b4ea721c0981e89cbf5f68768fc61',NULL,NULL,1,'',0,0,5);" },
    .{ .configs = 0b100000, .sqlite = "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('owed-stop',3,'chfab3',X'77748b76a23e01cd43dc8d98d6d8d554e408dc1df3185c33fb32b742107db4b4',NULL,NULL,1,'',0,0,7);" },
    .{ .configs = 0b010000, .sqlite = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) VALUES(2,2,'chfab3',1,2,3,0,115200,0,'low',NULL,1,0,NULL,NULL,'interrupted',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'owed-stop',NULL,NULL,1795456910,NULL,NULL,NULL,2,1,NULL,0,NULL,NULL,NULL,128000);" },
    .{ .configs = 0b000001, .sqlite = "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) VALUES(2,0,'chfab3',4,2,26,1,X'f7c19691de5011347caa8e2afe10f6eea0f89c7cad32f17cba8c6b04b8e1dc19',0,0,25,1,NULL,0);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) VALUES(2,0,'mdfab2',4,2,24,1,X'39dbe3cba52908fdb3610df812d007a7fc134eea8803b34a97e9aa229d815fae',0,0,22,1,NULL,0);" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO content(content_id,digest,byte_length,private,payload) VALUES(27,X'59d1f617dd0a42308bd85f83787f964356c0a21bc6d52bf1899479788d6751eb',10,0,X'6368696c6420646f6e65');", .mysql = "INSERT INTO content(content_id,digest,byte_length,private) VALUES(27,X'59d1f617dd0a42308bd85f83787f964356c0a21bc6d52bf1899479788d6751eb',10,0);INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(27,0,X'6368696c6420646f6e65');" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,sender_session_ref) VALUES(3,'chfab3','owed-message',25,1,NULL,1795456910,NULL);" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES(3,'chfab3',3,3,3,'completed',27,5,1795456910,NULL);" },
    .{ .configs = 0b101000, .sqlite = "INSERT INTO turn(turn_id,session_ref,first_admission_id,input_cutoff,operation_id,outcome_code,outcome_content_id,outcome_position,outcome_at,continuation_operation_id) VALUES(3,'chfab3',3,3,3,'cancelled',NULL,5,1795456910,NULL);" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) VALUES(3,3,'chfab3',1,3,3,0,115200,0,'low',1,1,0,NULL,NULL,'answer',27,NULL,X'01000000000000',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1795456910,NULL,NULL,NULL,2,1,NULL,0,NULL,NULL,NULL,128000);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) VALUES(3,3,'chfab3',1,3,3,0,115200,0,'low',NULL,1,0,NULL,NULL,'interrupted',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'rui.core/stop/owed/6',NULL,NULL,1795456910,NULL,NULL,NULL,2,1,NULL,0,NULL,NULL,NULL,128000);" },
    .{ .configs = 0b100000, .sqlite = "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) VALUES(3,3,'chfab3',1,3,3,0,115200,0,'low',NULL,1,0,NULL,NULL,'interrupted',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'owed-stop',NULL,NULL,1795456910,NULL,NULL,NULL,2,1,NULL,0,NULL,NULL,NULL,128000);" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) VALUES(3,0,'chfab3',4,2,27,1,X'f7c19691de5011347caa8e2afe10f6eea0f89c7cad32f17cba8c6b04b8e1dc19',0,0,26,1,NULL,0);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES('rtfab1',2,4,3,1,NULL,NULL,NULL,NULL,NULL,1,0,23,1795456910);" },
    .{ .configs = 0b111111, .sqlite = "INSERT INTO model_output_part(operation_id,item_ordinal,part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id) VALUES(1,0,0,1,1,9,NULL,21);" },
    .{ .configs = 0b010101, .sqlite = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES('chfab3',1,2,1,2,2,NULL,NULL,NULL,NULL,NULL,NULL,24,1795456910);" },
    .{ .configs = 0b000001, .sqlite = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES('chfab3',2,4,3,2,NULL,NULL,NULL,NULL,NULL,2,0,26,1795456910);" },
    .{ .configs = 0b000001, .sqlite = "INSERT INTO model_output_part(operation_id,item_ordinal,part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id) VALUES(2,0,0,1,1,10,NULL,21);" },
    .{ .configs = 0b010101, .sqlite = "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) VALUES(2,'rtfab1','chfab3',2,2,NULL,0,NULL,0,0);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES('chfab3',1,2,1,3,3,NULL,NULL,NULL,NULL,NULL,NULL,25,1795456910);" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES('chfab3',2,4,3,3,NULL,NULL,NULL,NULL,NULL,3,0,27,1795456910);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES('mdfab2',1,2,1,2,2,NULL,NULL,NULL,NULL,NULL,NULL,20,1795456910);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) VALUES('mdfab2',2,4,3,2,NULL,NULL,NULL,NULL,NULL,2,0,24,1795456910);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO model_output_part(operation_id,item_ordinal,part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id) VALUES(2,0,0,1,1,11,NULL,21);" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO model_output_part(operation_id,item_ordinal,part_ordinal,part_array,part_kind,text_length,text_content_id,extras_content_id) VALUES(3,0,0,1,1,10,NULL,21);" },
    .{ .configs = 0b101010, .sqlite = "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) VALUES(3,'mdfab2','chfab3',2,3,NULL,0,NULL,0,0);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) VALUES('owed-stop','rtfab1',NULL,6,1,1795456910,0);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) VALUES('rui.core/stop/owed/6','chfab3',2,4,2,1795456910,1);" },
    .{ .configs = 0b000100, .sqlite = "INSERT INTO session_stop_owed(child_ref,cause_ref,cause_position,settled) VALUES('chfab3','rtfab1',6,1);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) VALUES('owed-stop','mdfab2',NULL,6,2,1795456910,0);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) VALUES('rui.core/stop/owed/6','chfab3',3,4,3,1795456910,1);" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO session_stop_owed(child_ref,cause_ref,cause_position,settled) VALUES('chfab3','mdfab2',6,1);" },
    .{ .configs = 0b010000, .sqlite = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) VALUES('owed-stop','chfab3',2,4,2,1795456910,0);" },
    .{ .configs = 0b100000, .sqlite = "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) VALUES('owed-stop','chfab3',3,4,3,1795456910,0);" },
    .{ .configs = 0b111111, .sqlite = "UPDATE message_admission SET turn_id=1 WHERE admission_id=1;" },
    .{ .configs = 0b010101, .sqlite = "UPDATE message_admission SET turn_id=2 WHERE admission_id=2;" },
    .{ .configs = 0b101010, .sqlite = "UPDATE message_admission SET turn_id=2 WHERE admission_id=2;" },
    .{ .configs = 0b101010, .sqlite = "UPDATE message_admission SET turn_id=3 WHERE admission_id=3;" },
};

/// The updates of the state after the child's forward deliveries, which the second upgrade of a
/// message_first == false variant starts from.
const obligation_forwarded_rows = [_]ObligationRow{
    .{ .configs = 0b000001, .sqlite = "UPDATE session SET next_position=7 WHERE session_ref='rtfab1';" },
    .{ .configs = 0b000001, .sqlite = "UPDATE session_forward SET position=6,delivered_at=1795456910 WHERE forward_id=2;" },
    .{ .configs = 0b000010, .sqlite = "UPDATE session SET next_position=7 WHERE session_ref='mdfab2';" },
    .{ .configs = 0b000010, .sqlite = "UPDATE session SET next_position=7 WHERE session_ref='rtfab1';" },
    .{ .configs = 0b000010, .sqlite = "UPDATE session_forward SET position=6,delivered_at=1795456910 WHERE forward_id=3;" },
    .{ .configs = 0b000010, .sqlite = "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) VALUES(4,'rtfab1','chfab3',2,3,6,0,1795456910,NULL,0);" },
    .{ .configs = 0b000100, .sqlite = "UPDATE session SET next_position=8 WHERE session_ref='rtfab1';" },
    .{ .configs = 0b000100, .sqlite = "UPDATE session_forward SET position=7,delivered_at=1795456910 WHERE forward_id=2;" },
    .{ .configs = 0b001000, .sqlite = "UPDATE session SET next_position=8 WHERE session_ref='mdfab2';" },
    .{ .configs = 0b001000, .sqlite = "UPDATE session SET next_position=7 WHERE session_ref='rtfab1';" },
    .{ .configs = 0b001000, .sqlite = "UPDATE session_forward SET position=7,delivered_at=1795456910 WHERE forward_id=3;" },
    .{ .configs = 0b001000, .sqlite = "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) VALUES(4,'rtfab1','chfab3',2,3,6,0,1795456910,NULL,0);" },
    .{ .configs = 0b010000, .sqlite = "UPDATE session SET next_position=7 WHERE session_ref='rtfab1';" },
    .{ .configs = 0b010000, .sqlite = "UPDATE session_forward SET position=6,delivered_at=1795456910 WHERE forward_id=2;" },
    .{ .configs = 0b100000, .sqlite = "UPDATE session SET next_position=7 WHERE session_ref='mdfab2';" },
    .{ .configs = 0b100000, .sqlite = "UPDATE session SET next_position=7 WHERE session_ref='rtfab1';" },
    .{ .configs = 0b100000, .sqlite = "UPDATE session_forward SET position=6,delivered_at=1795456910 WHERE forward_id=3;" },
    .{ .configs = 0b100000, .sqlite = "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) VALUES(4,'rtfab1','chfab3',2,3,6,0,1795456910,NULL,0);" },
};

fn obligationText(comptime rows: []const ObligationRow, comptime engine: store_testing.Engine, comptime bit: u6) [:0]const u8 {
    @setEvalBranchQuota(4_000_000);
    comptime {
        var text: [:0]const u8 = "";
        for (rows) |row| {
            if (row.configs & bit != 0) text = text ++ (if (engine == .mysql) row.mysql orelse row.sqlite else row.sqlite);
        }
        return text;
    }
}

/// The format-72 Start of one frontier shape: the shared rows and the shape's rows, with no fixture rows.
pub fn obligationStart72(comptime ending: ObligationEnding, comptime multi_hop: bool) history.Start {
    @setEvalBranchQuota(4_000_000);
    const bit = comptime obligationConfig(ending, multi_hop);
    const sqlite = comptime obligation_shared_sqlite ++ obligationText(&obligation_rows, .sqlite, bit);
    const mysql = comptime obligation_shared_mysql ++ obligationText(&obligation_rows, .mysql, bit);
    return .{ .format = 72, .sql = .{ .per_engine = .{ .sqlite = sqlite, .mysql = mysql } }, .baseline_rows = false };
}

/// The Start after the child's forward deliveries, for the second upgrade of a message_first == false shape.
pub fn obligationForwardedStart72(comptime ending: ObligationEnding, comptime multi_hop: bool) history.Start {
    @setEvalBranchQuota(4_000_000);
    const bit = comptime obligationConfig(ending, multi_hop);
    const sqlite = comptime obligation_shared_sqlite ++ obligationText(&obligation_rows, .sqlite, bit) ++ obligationText(&obligation_forwarded_rows, .sqlite, bit);
    const mysql = comptime obligation_shared_mysql ++ obligationText(&obligation_rows, .mysql, bit) ++ obligationText(&obligation_forwarded_rows, .mysql, bit);
    return .{ .format = 72, .sql = .{ .per_engine = .{ .sqlite = sqlite, .mysql = mysql } }, .baseline_rows = false };
}

test "obligation frontier spans ending feed and Message transfers in either order" {
    try store_testing.forEachEngine(struct {
        fn run(engine: *store_testing.Case) !void {
            inline for (std.enums.values(ObligationEnding)) |ending| {
                inline for ([_]bool{ false, true }) |multi_hop| {
                    inline for ([_]bool{ false, true }) |message_first| {
                        var tmp = std.testing.tmpDir(.{});
                        defer tmp.cleanup();
                        const start = comptime obligationStart72(ending, multi_hop);
                        var storage: Store = undefined;
                        try history.openAt(engine, &storage, &tmp, std.testing.io, &start);
                        var opened = true;
                        defer if (opened) storage.close() catch unreachable;
                        const root = try protocol.Bounded(protocol.max_session_bytes).from("rtfab1");
                        const middle = try protocol.Bounded(protocol.max_session_bytes).from("mdfab2");
                        const parent = if (multi_hop) middle else root;
                        const child = try protocol.Bounded(protocol.max_session_bytes).from("chfab3");
                        // The frozen state's own Turn, the child's Turn that the Message admits, and the activity position.
                        const own_turn: u64 = 1;
                        const model_turn: u64 = if (multi_hop) 3 else 2;
                        const baseline_end: u64 = 5;
                        const between = try store_core.activityPageForTesting(&storage, .{ .session = root, .position = baseline_end, .kinds = if (ending == .quiet) .initOne(.turn_ended) else .full });
                        try std.testing.expectEqual(@as(usize, 0), between.count);
                        try std.testing.expect(between.work.work.state == .working);
                        try std.testing.expectEqual(own_turn, between.work.work.turn.?);
                        _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                        if (message_first) {
                            try std.testing.expect(try storage.deliverChildEnding(model_turn, .{}));
                            try std.testing.expect(!try storage.deliverChildEnding(model_turn, .{}));
                        }
                        for (0..@as(usize, if (multi_hop) 2 else 1)) |_| {
                            const expected = if (message_first and ending != .quiet and !multi_hop) "pending" else "working";
                            _ = try expectOneWork(&storage, &tmp, root.slice(), expected);
                            const forward = try store_testing.queryU64(&storage, "SELECT forward_id FROM session_forward WHERE source_id=?1 AND kind=2 AND position IS NULL ORDER BY forward_id LIMIT 1", .{model_turn});
                            try std.testing.expect(try storage.deliverSessionForward(forward, .{}));
                            try std.testing.expect(!try storage.deliverSessionForward(forward, .{}));
                        }
                        const landed = try store_core.activityPageForTesting(&storage, .{ .session = root, .position = baseline_end, .kinds = .initOne(.turn_ended) });
                        try std.testing.expectEqual(@as(usize, 1), landed.count);
                        try std.testing.expectEqualStrings(child.slice(), landed.items[0].value.turn_ended.session.slice());
                        if (!message_first) {
                            _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                            // The second upgrade starts from the state after the forward deliveries, in its own directory.
                            try storage.close();
                            opened = false;
                            tmp.cleanup();
                            tmp = std.testing.tmpDir(.{});
                            const forwarded = comptime obligationForwardedStart72(ending, multi_hop);
                            try history.openAt(engine, &storage, &tmp, std.testing.io, &forwarded);
                            opened = true;
                            _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                            try std.testing.expect(try storage.deliverChildEnding(model_turn, .{}));
                        }
                        if (ending == .quiet) {
                            _ = try expectOneWork(&storage, &tmp, root.slice(), "finished");
                            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session WHERE obligation_since IS NOT NULL", .{}));
                        } else {
                            _ = try expectOneWork(&storage, &tmp, root.slice(), if (multi_hop) "working" else "pending");
                            const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM turn WHERE turn_id=?1 AND session_ref=?2 AND outcome_code IS NULL", .{ next.turn_id, parent.slice() }));
                            _ = try expectOneWork(&storage, &tmp, root.slice(), "working");
                            const working = try store_core.activityPageForTesting(&storage, .{ .session = root });
                            if (multi_hop) try std.testing.expectEqual(own_turn, working.work.work.turn.?) else try std.testing.expect(own_turn != working.work.work.turn.?);
                        }
                        try std.testing.expect(!storage.isFenced());
                    }
                }
            }
        }
    }.run);
}

test "obligation frontier preserves eligible admission times when clocks step backward" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try configureTestSession(&storage, "seed-root");
            const child = try configureTestSession(&storage, "seed-child");
            try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), child.slice() });
            try submitTestMessage(&storage, &tmp, "seed-first-file", "seed-first", child.slice(), "first");
            try submitTestMessage(&storage, &tmp, "seed-later-file", "seed-later", child.slice(), "later");
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=17 WHERE command_key='seed-first'", .{});
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=9 WHERE command_key='seed-later'", .{});
            try refreshFrontierForTesting(&storage, child.slice());
            try expectSeed(&storage, root.slice(), 9);
            var stop = try completeSessionStop("seed-stop", child.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            try expectSeed(&storage, root.slice(), null);
            try submitTestMessage(&storage, &tmp, "seed-after-file", "seed-after", child.slice(), "after stop");
            try store_testing.exec(&storage, "UPDATE message_admission SET admitted_at=23 WHERE command_key='seed-after'", .{});
            try refreshFrontierForTesting(&storage, child.slice());
            try expectSeed(&storage, root.slice(), 23);
            try std.testing.expect(try storage.admitNextModelAttempt(.{}) != null);
            try refreshFrontierForTesting(&storage, child.slice());
            try expectSeed(&storage, root.slice(), 23);
        }

        fn expectSeed(storage: *Store, root: []const u8, expected: ?u64) !void {
            const entry = try store_core.enter(storage, .none);
            defer entry.release();
            var a: reads_domain.ReadAccess = .open(&entry);
            defer a.deinit();
            var works = [_]report_domain.WorkRead{.{ .session = root }};
            try report_domain.readWorks(&a, &works);
            try std.testing.expectEqual(expected, works[0].inputs.owed_since);
        }
    }.run);
}

test "new attachments invalidate saved ancestors and deep trees forget ring coverage" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const root = try configureTestSession(&storage, "attach-root");
            const unrelated = try configureTestSession(&storage, "attach-unrelated");
            var parent = root;
            for (0..5) |depth| {
                var request: protocol.ActivityPage = .{};
                try request.session.set(root.slice());
                var page: protocol.ActivityFacts = undefined;
                try storage.activityPage(&request, &page);
                const before = page.token.?;
                const listing = try TestingListing.read(&storage, &tmp, .{});
                var key: [32]u8 = undefined;
                var command: wire_request.ConfigureCommand = .{};
                try command.key.set(try std.fmt.bufPrint(&key, "attach-{d}", .{depth}));
                command.configuration = try testingAgentSpec(&.{}, "ask");
                command.configuration.parent.state = .value;
                try command.configuration.parent.value.set(parent.slice());
                parent = (try storage.configure(&command, .{})).accepted.session;
                request.position = page.end;
                request.since = before;
                try storage.activityPage(&request, &page);
                try std.testing.expect(!page.not_modified);
                try std.testing.expect(page.work.work.state == .idle);
                const changed = try TestingListing.read(&storage, &tmp, .{ .since = listing.since });
                if (depth < 3) {
                    try std.testing.expectEqual(protocol.ListDelta.changed, changed.delta);
                    try std.testing.expectEqual(depth + 2, changed.count);
                    for (changed.references[0..changed.count]) |ref| try std.testing.expect(!std.mem.eql(u8, &ref, unrelated.slice()));
                } else {
                    try std.testing.expectEqual(protocol.ListDelta.full, changed.delta);
                }
                try std.testing.expect(!storage.isFenced());
            }
        }
    }.run);
}

test "a stop that selected no Turn decides work only through the input it excluded" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "no-turn-stop-config");
            const answer = [_]TestingAnswerPart{.{ .encoded = "done", .decoded = "done" }};
            try answerTestTurn(&storage, &tmp, session.slice(), "no-turn-stop-answer", &answer);

            var idle_stop = try completeSessionStop("no-turn-stop-idle", session.slice());
            try std.testing.expect(storage.stopSession(&idle_stop, .{}) == .accepted);
            _ = try expectOneWork(&storage, &tmp, session.slice(), "finished");

            try submitTestMessage(&storage, &tmp, "no-turn-stop-file", "no-turn-stop-queued", session.slice(), "queued");
            var effective = try completeSessionStop("no-turn-stop-effective", session.slice());
            try std.testing.expect(storage.stopSession(&effective, .{}) == .accepted);
            const stopped_at = try store_testing.queryU64(&storage, "SELECT stopped_at FROM session_stop WHERE command_key='no-turn-stop-effective'", .{});
            try std.testing.expectEqual(stopped_at, try expectOneWork(&storage, &tmp, session.slice(), "stopped"));
            var later = try completeSessionStop("no-turn-stop-later", session.slice());
            try std.testing.expect(storage.stopSession(&later, .{}) == .accepted);
            try std.testing.expectEqual(stopped_at, try expectOneWork(&storage, &tmp, session.slice(), "stopped"));

            try submitTestMessage(&storage, &tmp, "no-turn-stop-next-file", "no-turn-stop-next", session.slice(), "next");
            _ = try expectOneWork(&storage, &tmp, session.slice(), "pending");
            _ = (try storage.admitNextModelAttempt(.{})).?;
            _ = try expectOneWork(&storage, &tmp, session.slice(), "working");
        }
    }.run);
}
