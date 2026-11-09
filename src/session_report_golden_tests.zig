const std = @import("std");
const store = @import("store.zig");
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");

const header = "{\"version\":\"" ++ protocol.wire_version ++ "\",";
const missing = header ++
    \\"type":"session_report","delta":"full","since":null,"profile":"current","session":null,"pending_messages":"0","execution":{"status":"unavailable","reason":"session_not_found"}}
;
const current_empty = header ++
    \\"type":"session_report","delta":"full","since":null,"profile":"current","session":{"reference":"<session>","parent":null,"workspace":"<workspace>","provider":"codex","model":"model-a","compaction_trigger":"115200","context_estimate":null,"output_reservation":"0","compaction_trigger_override":"115200","output_reservation_override":null,"reasoning_effort":null,"reasoning_effort_override":null,"revision":"1","tools":["bash","web_search"],"loaded_tools":["bash","web_search"],"permission_mode":"bypass","instructions":{"bytes":"0","sha256":"11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528"},"output_schema":null,"label":null,"created_at":"<time>"},"archive_state":"active","pending_messages":"0","work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null,"latest_outcome":null},"peers":{"from_person_at":null},"first_message":null,"selected_message":null,"recent_messages":[],"actions":{"count":"0","unresolved":[],"resolved":[]},"rejected_calls":{"count":"0","items":[]},"actionable_permissions":[],"execution":{"status":"partial","dispatch_fenced":false,"custody_occupied":"0","scratch_used_bytes":"0","unavailable":["structured_output"]}}
;
const full_empty = header ++
    \\"type":"session_report","profile":"full","session":{"reference":"<session>","parent":null,"workspace":"<workspace>","provider":"codex","model":"model-a","compaction_trigger":"115200","context_estimate":null,"output_reservation":"0","compaction_trigger_override":"115200","output_reservation_override":null,"reasoning_effort":null,"reasoning_effort_override":null,"revision":"1","tools":["bash","web_search"],"loaded_tools":["bash","web_search"],"permission_mode":"bypass","instructions":{"bytes":"0","sha256":"11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528"},"output_schema":null,"label":null,"created_at":"<time>"},"archive_state":"active","pending_messages":"0","work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null,"latest_outcome":null},"peers":{"from_person_at":null},"first_message":null,"selected_message":null,"recent_messages":[],"actions":{"count":"0","unresolved":[],"resolved":[]},"rejected_calls":{"count":"0","items":[]},"actionable_permissions":[],"full":{"session_revisions":[{"revision":"1","command_key":"golden-report-config","workspace":"<workspace>","provider":"codex","model":"model-a","compaction_trigger":"115200","output_reservation":null,"reasoning_effort":null,"label":null,"tools":["bash","web_search"],"loaded_tools":["bash","web_search"],"permission_mode":"bypass","instructions":{"type":"text","bytes":"0","sha256":"11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528","text":""},"output_schema":null}],"messages":[],"conversation":[],"turns":[],"model_operations":[],"tool_calls":[],"actions":[],"permission_decisions":[],"session_stops":[],"model_interruptions":[],"tool_results":[]},"execution":{"status":"partial","dispatch_fenced":false,"custody_occupied":"0","scratch_used_bytes":"0","unavailable":["structured_output"]}}
;
const current_mcp = header ++
    \\"type":"session_report","delta":"full","since":null,"profile":"current","session":{"reference":"<session>","parent":null,"workspace":"<workspace>","provider":"codex","model":"model-a","compaction_trigger":"115200","context_estimate":"11","output_reservation":"0","compaction_trigger_override":"115200","output_reservation_override":null,"reasoning_effort":null,"reasoning_effort_override":null,"revision":"1","tools":["fetch_page"],"loaded_tools":["fetch_page"],"permission_mode":"bypass","instructions":{"bytes":"0","sha256":"11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528"},"output_schema":null,"label":null,"created_at":"<time>"},"archive_state":"active","pending_messages":"0","work":{"state":{"kind":"pending","since":"<time>"},"turn":"1","operation":"1","first_action":null,"latest_outcome":null},"peers":{"from_person_at":"<time>"},"first_message":{"position":"1","admission":"1","admitted_at":"<time>","sender":null,"content":{"bytes":"12","sha256":"702f7015ab5e5a4d47fa1cabf3b12908f0e9398e61011a3103596b08ee7bcba2"}},"selected_message":"golden-mcp-key","recent_messages":[],"actions":{"count":"1","unresolved":[{"action":"1","parent_operation":"1","call_ordinal":"0","tool":"fetch_page","permission_revision":"1","authorization":"bypass","call_id":{"type":"text","bytes":"8","sha256":"c1aa030d7b9642d1453056c235244dfedd8c6573382fdbe535b345b9ff6cb11a"},"server":"docs","arguments":{"type":"text","bytes":"2","sha256":"de16d1a68a8e3c9eea4e69185cb547810c9ac3a2999dec7e76dbf073dac34663"},"presentation":{"description":"fetch_page","code":"unresolved","publication_position":null}}],"resolved":[]},"rejected_calls":{"count":"0","items":[]},"actionable_permissions":[],"execution":{"status":"partial","dispatch_fenced":false,"custody_occupied":"0","scratch_used_bytes":"0","unavailable":["structured_output"]}}
;
const current_mixed = header ++
    \\"type":"session_report","delta":"full","since":null,"profile":"current","session":{"reference":"<session>","parent":null,"workspace":"<workspace>","provider":"codex","model":"model-a","compaction_trigger":"115200","context_estimate":"56","output_reservation":"0","compaction_trigger_override":"115200","output_reservation_override":null,"reasoning_effort":null,"reasoning_effort_override":null,"revision":"1","tools":["bash","web_search"],"loaded_tools":["bash","web_search"],"permission_mode":"ask","instructions":{"bytes":"0","sha256":"11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528"},"output_schema":null,"label":null,"created_at":"<time>"},"archive_state":"active","pending_messages":"0","work":{"state":{"kind":"approval","since":"<time>"},"turn":"2","operation":"2","first_action":"2","latest_outcome":null},"peers":{"from_person_at":"<time>"},"first_message":{"position":"1","admission":"1","admitted_at":"<time>","sender":null,"content":{"bytes":"5","sha256":"295e577a7a0c2608c470cb327496d5b7f60b8f53b5ebf48f6878d2cdd614e333"}},"selected_message":"golden-mixed-key","recent_messages":[{"turn":"1","message":"golden-answer-key","outcome":"completed"}],"actions":{"count":"2","unresolved":[{"action":"2","parent_operation":"2","call_ordinal":"1","tool":"bash","permission_revision":"1","authorization":"pending","call_id":{"type":"text","bytes":"3","sha256":"8e86e6644aa2b109430eaa8ca07939190490ac61a33862f788b398d49d2e35a5"},"arguments":{"type":"text","bytes":"52","sha256":"7ef3f0e0b68ea2d333b93093dbe1261a18c901ad73ef684361bf94d12056045c"},"presentation":{"description":"Run","code":"pending_permission","publication_position":null}}],"resolved":[{"action":"1","parent_operation":"2","call_ordinal":"0","code":"denied","acceptance_position":"13","result":{"type":"text","bytes":"18","sha256":"a251e0c566a1f73bb2338367bf1cd6e75d2ebc1e0b6d0657a7debe776a3bd881"},"presentation":{"description":"Run","code":"denied","publication_position":null}}]},"rejected_calls":{"count":"1","items":[{"parent_operation":"2","call_ordinal":"2","code":"unknown_tool","acceptance_position":"12","result":{"type":"text","bytes":"20","sha256":"e64dbe3bb67e66a800ef3ea2b21801b5f5d5025f4ba2d7a088788e6b4e0d23a7"},"name":{"type":"text","bytes":"5","sha256":"f23807757d15c3493a5f622898047eee4f2949fc3ae4d5d05afa1185dcbd240b"},"call_id":{"type":"text","bytes":"5","sha256":"3decf9438cc4009dec87c0e881fc714a1ad6abdd7fb6f231e1b5996e7aa26932"},"arguments":{"type":"text","bytes":"2","sha256":"de16d1a68a8e3c9eea4e69185cb547810c9ac3a2999dec7e76dbf073dac34663"},"presentation":{"description":null,"code":"unknown_tool","publication_position":null}}]},"actionable_permissions":[{"action":"2","permission_revision":"1"}],"execution":{"status":"partial","dispatch_fenced":false,"custody_occupied":"0","scratch_used_bytes":"0","unavailable":["structured_output"]}}
;

const Scenario = enum { missing, current_empty, full_empty, current_mcp, current_mixed };

fn run(case: *store.testing.Case, comptime scenario: Scenario) !void {
    const records = comptime store.testingCatalogRecords(&.{
        .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a docs page.", .input_schema = "{\"type\":\"object\"}" },
    });
    const digests = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var out: [records.len][32]u8 = undefined;
        for (&records, &out) |*record, *digest| digest.* = tools.recordDigest(record);
        break :blk out;
    };
    const catalog: tools.Catalog = .{ .records = &records, .digests = &digests };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store.Store = undefined;
    try store.testingStoreWith(case, &storage, &tmp, std.testing.io, if (scenario == .current_mcp) .{ .catalog = &catalog } else .{});
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    if (scenario == .missing) {
        try session.set("aaaaaa");
    } else {
        var command = try store.testingCompleteConfiguration("golden-report-config", "", workspace, "model-a");
        if (scenario == .current_mcp) {
            command.configuration.tools = try .of(&.{"fetch_page"});
            command.configuration.permission_mode.state = .value;
            try command.configuration.permission_mode.value.set("bypass");
        }
        if (scenario == .current_mixed) {
            command.configuration.permission_mode.state = .value;
            try command.configuration.permission_mode.value.set("ask");
        }
        const configured = try storage.configure(&command, .{});
        try std.testing.expect(configured == .accepted);
        session = configured.accepted.session;
        if (scenario == .current_mcp) {
            try store.testingSubmitMessage(&storage, &tmp, "golden-mcp-input", "golden-mcp-key", session.slice(), "fetch a page");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try store.settleCallsForTesting(&storage, &tmp, binding, "golden-mcp-calls", &.{.{
                .item_id = "mcp-item",
                .name = "fetch_page",
                .encoded_call_id = "mcp-call",
                .decoded_call_id = "mcp-call",
                .encoded_arguments = "{}",
                .decoded_arguments = "{}",
            }});
        }
        if (scenario == .current_mixed) {
            try store.testing.answerTestTurn(&storage, &tmp, session.slice(), "golden-answer", &.{.{ .encoded = "done", .decoded = "done" }});
            try store.testingSubmitMessage(&storage, &tmp, "golden-mixed-input", "golden-mixed-key", session.slice(), "propose");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]store.TestingCall{
                .{ .item_id = "one", .name = "bash", .encoded_call_id = "one", .decoded_call_id = "one", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"true\",\"timeout_ms\":null}" },
                .{ .item_id = "two", .name = "bash", .encoded_call_id = "two", .decoded_call_id = "two", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"true\",\"timeout_ms\":null}" },
                .{ .item_id = "three", .name = "other", .encoded_call_id = "three", .decoded_call_id = "three", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try store.settleCallsForTesting(&storage, &tmp, binding, "golden-mixed-calls", &calls);
            const before = try store.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .current);
            defer std.testing.allocator.free(before);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, before, .{});
            defer parsed.deinit();
            const unresolved = parsed.value.object.get("actions").?.object.get("unresolved").?.array.items;
            var deny: protocol.PermissionDecisionCommand = .{ .action_id = try std.fmt.parseInt(u64, unresolved[0].object.get("action").?.string, 10), .decision = .deny };
            try deny.key.set("golden-deny");
            try deny.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
        }
    }
    const profile: protocol.ReportProfile = if (scenario == .full_empty) .full else .current;
    const bytes = try store.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, profile);
    defer std.testing.allocator.free(bytes);
    const expected = switch (scenario) {
        .missing => missing,
        .current_empty => current_empty,
        .full_empty => full_empty,
        .current_mcp => current_mcp,
        .current_mixed => current_mixed,
    };
    var normalized = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(normalized);
    if (scenario != .missing) {
        try replaceField(&normalized, "reference", session.slice(), "<session>");
        try replaceField(&normalized, "workspace", workspace, "<workspace>");
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try normalizeTimes(&normalized, parsed.value);
    try std.testing.expectEqualStrings(expected, normalized);
}

fn normalizeTimes(bytes: *[]u8, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const child = entry.value_ptr.*;
                if (child == .string and (std.mem.eql(u8, key, "created_at") or std.mem.eql(u8, key, "since") or std.mem.eql(u8, key, "from_person_at") or std.mem.eql(u8, key, "admitted_at"))) {
                    try replaceField(bytes, key, child.string, "<time>");
                } else try normalizeTimes(bytes, child);
            }
        },
        .array => |items| for (items.items) |item| try normalizeTimes(bytes, item),
        else => {},
    }
}

fn replaceField(bytes: *[]u8, key: []const u8, value: []const u8, replacement: []const u8) !void {
    const a = std.testing.allocator;
    const needle = try std.fmt.allocPrint(a, "\"{s}\":\"{s}\"", .{ key, value });
    defer a.free(needle);
    const replacement_field = try std.fmt.allocPrint(a, "\"{s}\":\"{s}\"", .{ key, replacement });
    defer a.free(replacement_field);
    const result = try std.mem.replaceOwned(u8, a, bytes.*, needle, replacement_field);
    a.free(bytes.*);
    bytes.* = result;
}

test "session report golden missing Session" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .missing);
        }
    }.go);
}
test "session report golden Current empty" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .current_empty);
        }
    }.go);
}
test "session report golden Full empty" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .full_empty);
        }
    }.go);
}
test "session report golden Current MCP" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .current_mcp);
        }
    }.go);
}
test "session report golden Current mixed" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .current_mixed);
        }
    }.go);
}
