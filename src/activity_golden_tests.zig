const std = @import("std");
const store = @import("store.zig");
const protocol = @import("protocol.zig");
const host_reply = @import("host_reply.zig");
const wire_request = @import("wire_request.zig");

const header = "{\"version\":\"" ++ protocol.wire_version ++ "\",";
const mixed_first = header ++
    \\"type":"activity_page","end":"13","direction":"forward","items":[{"position":"1","ordinal":"0","at":"<time>","value":{"session_changed":{"revision":"2","field":"label","provider_text":null}}},{"position":"2","ordinal":"0","at":"<time>","value":{"admission":{"admission":"1","key":"golden-answer-key","turn":"1","state":"applied","admitted_at":"<time>","sender":null,"content":{"bytes":"5","sha256":"295e577a7a0c2608c470cb327496d5b7f60b8f53b5ebf48f6878d2cdd614e333"}}}},{"position":"3","ordinal":"0","at":"<time>","value":{"user":{"admission":"1","key":"golden-answer-key","turn":"1","state":"applied","admitted_at":"<time>","sender":null,"content":{"bytes":"5","sha256":"295e577a7a0c2608c470cb327496d5b7f60b8f53b5ebf48f6878d2cdd614e333"}}}},{"position":"4","ordinal":"0","at":"<time>","value":{"model_call":{"model":"model-a","served_model":null,"input_tokens":null,"output_tokens":null,"cached_tokens":null,"latency_ms":null,"first_event_ms":null,"status":"answer","attempts":"1"}}},{"position":"5","ordinal":"0","at":"<time>","value":{"assistant":{"content":{"bytes":"10","sha256":"6ccf7b7f01e0630973470dfef6d2d1d59f1f6d8541b08d170fd276abbd5be7c3"},"final":true}}},{"position":"6","ordinal":"0","at":"<time>","value":{"turn_ended":{"session":"<session>","turn":"1","operation":"1","ending":"done","code":"completed","content":{"bytes":"10","sha256":"6ccf7b7f01e0630973470dfef6d2d1d59f1f6d8541b08d170fd276abbd5be7c3"}}}},{"position":"7","ordinal":"0","at":"<time>","value":{"admission":{"admission":"2","key":"golden-activity-key","turn":"2","state":"applied","admitted_at":"<time>","sender":null,"content":{"bytes":"13","sha256":"3c4f20957d172bd1973eaef8182190c29051893ebf7091a7f1a561ae6190ec57"}}}},{"position":"8","ordinal":"0","at":"<time>","value":{"user":{"admission":"2","key":"golden-activity-key","turn":"2","state":"applied","admitted_at":"<time>","sender":null,"content":{"bytes":"13","sha256":"3c4f20957d172bd1973eaef8182190c29051893ebf7091a7f1a561ae6190ec57"}}}},{"position":"9","ordinal":"0","at":"<time>","value":{"model_call":{"model":"model-a","served_model":null,"input_tokens":null,"output_tokens":null,"cached_tokens":null,"latency_ms":null,"first_event_ms":null,"status":"tool_proposals","attempts":"1"}}},{"position":"10","ordinal":"0","at":"<time>","value":{"call":{"operation":"2","turn":"2","call_ordinal":"0","action":"1","rejection":null,"fields":[{"bytes":"4","sha256":"a0fbca0ae84c22252231e4bffa4714809c6d0949720b266767b8fce2aae50557"},{"bytes":"3","sha256":"b4457cfe347adbf6057d2f6ac87b2892672e8e9c1aed61119da906cf6089f160"},{"bytes":"52","sha256":"7ef3f0e0b68ea2d333b93093dbe1261a18c901ad73ef684361bf94d12056045c"}],"description":"Run","tool":"bash","server":null}}},{"position":"10","ordinal":"1","at":"<time>","value":{"approval_requested":{"session":"<session>","action":"1","operation":"2","call_ordinal":"0","description":"Run","tool":"bash","server":null}}},{"position":"11","ordinal":"0","at":"<time>","value":{"call":{"operation":"2","turn":"2","call_ordinal":"1","action":null,"rejection":"unknown_tool","fields":[{"bytes":"5","sha256":"f23807757d15c3493a5f622898047eee4f2949fc3ae4d5d05afa1185dcbd240b"},{"bytes":"3","sha256":"8e86e6644aa2b109430eaa8ca07939190490ac61a33862f788b398d49d2e35a5"},{"bytes":"2","sha256":"de16d1a68a8e3c9eea4e69185cb547810c9ac3a2999dec7e76dbf073dac34663"}],"description":null,"tool":"other","server":null}}},{"position":"13","ordinal":"0","at":"<time>","value":{"admission":{"admission":"3","key":"golden-activity-queued-key","turn":null,"state":"queued","admitted_at":"<time>","sender":null,"content":{"bytes":"10","sha256":"d189ef49e79c8c1487ebf6e7405e05c8d66724ad7dbe7323c8d6a67919eeff79"}}}}],"more":false,"call_activity":{"total":"2","entries":[{"operation":"2","ordinal":"0","presentation":{"description":"Run","code":"pending_permission","publication_position":null}},{"operation":"2","ordinal":"1","presentation":{"description":null,"code":"unknown_tool","publication_position":null}}]},"queued":{"count":"1","oldest_position":"13","newest_admission":"3","newest_position":"13"},"work":{"state":{"kind":"approval","since":"<time>"},"turn":"2","operation":"2","first_action":"1","revision":"2","workspace":"<workspace>"},"delta":"full","since":"<token>"}
;
const mixed_admissions = header ++
    \\"type":"activity_page","end":"13","direction":"backward","items":[{"position":"13","ordinal":"0","at":"<time>","value":{"admission":{"admission":"3","key":"golden-activity-queued-key","turn":null,"state":"queued","admitted_at":"<time>","sender":null,"content":{"bytes":"10","sha256":"d189ef49e79c8c1487ebf6e7405e05c8d66724ad7dbe7323c8d6a67919eeff79"}}}}],"more":true,"call_activity":{"total":"0","entries":[]},"queued":{"count":"0","oldest_position":"0","newest_admission":"0","newest_position":"0"},"work":{"state":{"kind":"approval","since":"<time>"},"turn":"2","operation":"2","first_action":"1","revision":"2","workspace":"<workspace>"},"delta":"full","since":null}
;
const unchanged = header ++
    \\"type":"activity_page","delta":"not_modified","since":"<token>"}
;
const search_all = header ++
    \\"type":"activity_search","items":[{"position":"13","ordinal":"0","kind":"admission","hits":[{"snippet":"queued Run","offset":"7","length":"3"}]},{"position":"10","ordinal":"0","kind":"call","hits":[{"snippet":"bash\n{\"description\":\"Run\",\"cmd\":\"true\",\"timeout_ms\":null}","offset":"21","length":"3"}]},{"position":"8","ordinal":"0","kind":"user","hits":[{"snippet":"propose a Run","offset":"10","length":"3"}]},{"position":"7","ordinal":"0","kind":"admission","hits":[{"snippet":"propose a Run","offset":"10","length":"3"}]}],"next":null}
;
const search_next = header ++
    \\"type":"activity_search","items":[{"position":"6","ordinal":"0","kind":"turn_ended","hits":[{"snippet":"done \"雪\"","offset":"6","length":"3"}]}],"next":{"position":"6","ordinal":"0"}}
;

const every_kind = header ++
    \\"type":"activity_page","end":"20","direction":"backward","items":[{"position":"1","ordinal":"0","at":"1000","value":{"admission":{"admission":"1","key":"key \" é","turn":null,"state":"queued","admitted_at":"100","sender":null,"content":{"bytes":"3","sha256":"abababababababababababababababababababababababababababababababab"}}}},{"position":"2","ordinal":"1","at":"1001","value":{"user":{"admission":"1","key":"key \" é","turn":"2","state":"applied","admitted_at":"100","sender":null,"content":{"bytes":"3","sha256":"abababababababababababababababababababababababababababababababab"}}}},{"position":"3","ordinal":"0","at":"1002","value":{"assistant":{"content":{"bytes":"3","sha256":"abababababababababababababababababababababababababababababababab"},"final":true}}},{"position":"4","ordinal":"1","at":"1003","value":{"call":{"operation":"3","turn":"2","call_ordinal":"1","action":null,"rejection":"unknown_tool","fields":[{"bytes":"2","sha256":"0101010101010101010101010101010101010101010101010101010101010101"},{"bytes":"0","sha256":"0202020202020202020202020202020202020202020202020202020202020202"},{"bytes":"2","sha256":"0101010101010101010101010101010101010101010101010101010101010101"}],"description":null,"tool":null,"server":null}}},{"position":"5","ordinal":"0","at":"1004","value":{"tool_result":{"content":{"bytes":"3","sha256":"abababababababababababababababababababababababababababababababab"},"presentation":{"description":"Run \"it\"","code":"succeeded","publication_position":"4"}}}},{"position":"6","ordinal":"1","at":"1005","value":{"hosted_call":{"presentation":{"description":null,"code":"succeeded","publication_position":null}}}},{"position":"7","ordinal":"0","at":"1006","value":{"turn_ended":{"session":"a1b2c3","turn":"2","operation":"3","ending":"done","code":"completed","content":null}}},{"position":"8","ordinal":"1","at":"1007","value":{"stop":{"key":"key \" é","turn":null,"cutoff":"9","completion":"pending"}}},{"position":"9","ordinal":"0","at":"1008","value":{"sent":{"admission":"4","admitted_at":"101","target":{"session":"k7m2qx","label":"peer \\ label"},"content":{"bytes":"3","sha256":"abababababababababababababababababababababababababababababababab"}}}},{"position":"10","ordinal":"1","at":"1009","value":{"send_failed":{"key":"key \" é","target":null,"code":"completed"}}},{"position":"11","ordinal":"0","at":"1010","value":{"received":{"admission":"5","key":"key \" é","turn":"3","state":"excluded","admitted_at":"102","sender":{"session":"p3n4rs","label":null},"content":{"bytes":"3","sha256":"abababababababababababababababababababababababababababababababab"}}}},{"position":"12","ordinal":"1","at":"1011","value":{"approval_requested":{"session":"a1b2c3","action":"7","operation":"3","call_ordinal":"0","description":null,"tool":null,"server":null}}},{"position":"13","ordinal":"0","at":"1012","value":{"session_changed":{"revision":"2","field":"label","provider_text":null}}},{"position":"14","ordinal":"1","at":"1013","value":{"compacted":{"operation":"8","dropped":"0"}}},{"position":"15","ordinal":"0","at":"1014","value":{"model_call":{"model":"requested \"雪\"","served_model":"served-model","input_tokens":"100","output_tokens":"7","cached_tokens":"40","latency_ms":"23","first_event_ms":"5","status":"completed","attempts":"2"}}}],"more":true,"call_activity":{"total":"5","entries":[{"operation":"3","ordinal":"0","presentation":{"description":"Run \"it\"","code":"succeeded","publication_position":"4"}},{"operation":"3","ordinal":"1","presentation":{"description":null,"code":"succeeded","publication_position":null}}]},"queued":{"count":"2","oldest_position":"11","newest_admission":"6","newest_position":"14"},"work":{"state":{"kind":"stopped","since":"50","cause":"stop"},"turn":"2","operation":null,"first_action":null,"revision":"3","workspace":"/w \"x\""},"delta":"full","since":null}
;

const Scenario = enum { mixed, unchanged, search };

fn run(case: *store.testing.Case, comptime scenario: Scenario) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store.Store = undefined;
    try store.testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var command = try store.testingCompleteConfiguration("golden-activity-config", "", workspace, "model-a");
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const configured = try storage.configure(&command, .{});
    try std.testing.expect(configured == .accepted);
    const session = configured.accepted.session;
    var update: wire_request.ConfigureCommand = .{};
    try update.key.set("golden-activity-revision");
    try update.session.set(session.slice());
    update.configuration.label.state = .value;
    try update.configuration.label.value.set("quote \" slash \\ café");
    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
    try store.testing.answerTestTurn(&storage, &tmp, session.slice(), "golden-answer", &.{.{ .encoded = "done \\\"雪\\\"", .decoded = "done \"雪\"" }});
    try store.testingSubmitMessage(&storage, &tmp, "golden-activity-input", "golden-activity-key", session.slice(), "propose a Run");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const calls = [_]store.TestingCall{
        .{ .item_id = "one", .name = "bash", .encoded_call_id = "one", .decoded_call_id = "one", .encoded_arguments = "{\\\"description\\\":\\\"Run\\\",\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}", .decoded_arguments = "{\"description\":\"Run\",\"cmd\":\"true\",\"timeout_ms\":null}" },
        .{ .item_id = "two", .name = "other", .encoded_call_id = "two", .decoded_call_id = "two", .encoded_arguments = "{}", .decoded_arguments = "{}" },
    };
    try store.settleCallsForTesting(&storage, &tmp, binding, "golden-activity-calls", &calls);
    try store.testingSubmitMessage(&storage, &tmp, "golden-activity-queued", "golden-activity-queued-key", session.slice(), "queued Run");
    var request: protocol.ActivityPage = .{};
    try request.session.set(session.slice());
    switch (scenario) {
        .mixed => {
            try expectPage(&storage, &request, session.slice(), workspace, mixed_first);
            var admissions: protocol.ActivityPage = .{ .direction = .backward, .kinds = .initMany(&.{ .admission, .user }), .limit = 1 };
            try admissions.session.set(session.slice());
            try expectPage(&storage, &admissions, session.slice(), workspace, mixed_admissions);
        },
        .unchanged => {
            request.limit = protocol.ActivityPage.items;
            const page = try std.testing.allocator.create(protocol.ActivityFacts);
            defer std.testing.allocator.destroy(page);
            // Drain the Session forward so the last page grants a follow token.
            while (true) {
                try storage.activityPage(&request, page);
                if (!page.more) break;
                const last = page.items[page.count - 1];
                request.end = page.end;
                request.position = last.position;
                request.ordinal = last.ordinal;
            }
            request = .{ .since = page.token.? };
            try request.session.set(session.slice());
            try expectPage(&storage, &request, session.slice(), workspace, unchanged);
        },
        .search => {
            var search: protocol.ActivitySearch = .{};
            try search.session.set(session.slice());
            try search.query.set("Run");
            try expectSearch(&storage, &search, search_all);
            search.limit = 1;
            try search.query.set("雪");
            try expectSearch(&storage, &search, search_next);
        },
    }
}

fn expectPage(storage: *store.Store, request: *const protocol.ActivityPage, session: []const u8, workspace: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const page = try allocator.create(protocol.ActivityFacts);
    defer allocator.destroy(page);
    try storage.activityPage(request, page);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try host_reply.renderActivityPage(.{ .writer = &out.writer }, page);
    var normalized = try allocator.dupe(u8, out.written());
    defer allocator.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();
    if (parsed.value.object.get("since")) |since| if (since == .string) try replaceField(&normalized, "since", since.string, "<token>");
    try replaceField(&normalized, "session", session, "<session>");
    try replaceField(&normalized, "workspace", workspace, "<workspace>");
    try normalizeTimes(&normalized, parsed.value);
    try std.testing.expectEqualStrings(expected, normalized);
}

fn expectSearch(storage: *store.Store, request: *const protocol.ActivitySearch, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const page = try allocator.create(protocol.ActivitySearchFacts);
    defer allocator.destroy(page);
    try storage.searchActivity(request, page);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try host_reply.renderActivitySearch(.{ .writer = &out.writer }, page);
    try std.testing.expectEqualStrings(expected, out.written());
}

/// Wall-clock seconds: each row's `at`, a Message's `admitted_at` and the
/// work state's `since`.
fn normalizeTimes(bytes: *[]u8, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const child = entry.value_ptr.*;
                if (child == .string and (std.mem.eql(u8, key, "at") or std.mem.eql(u8, key, "admitted_at") or
                    (std.mem.eql(u8, key, "since") and object.get("kind") != null)))
                {
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

test "activity golden mixed pages" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .mixed);
        }
    }.go);
}
test "activity golden not modified" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .unchanged);
        }
    }.go);
}
test "activity golden search" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .search);
        }
    }.go);
}
test "activity golden every kind" {
    var key: protocol.Bounded(protocol.max_key_bytes) = .{};
    try key.set("key \" é");
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set("completed");
    var peer: protocol.NamedPeer = .{ .session = .{} };
    try peer.session.set("k7m2qx");
    try peer.label.set("peer \\ label");
    var bare: protocol.NamedPeer = .{ .session = .{} };
    try bare.session.set("p3n4rs");
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set("Run \"it\"");
    const presentation: protocol.ToolPresentation = .{ .description = description, .code = .succeeded, .publication_position = 4 };
    const content: protocol.ActivityItem.Content = .{ .length = 3, .digest = @splat(0xab) };
    const field: protocol.ProposalFieldReference = .{ .length = 2, .digest = @splat(0x01) };
    const session: protocol.Bounded(protocol.session_id_bytes) = .{ .bytes = "a1b2c3".*, .len = 6 };
    var model: protocol.Bounded(protocol.max_model_bytes) = .{};
    try model.set("requested \"雪\"");
    var served: protocol.Bounded(protocol.max_model_bytes) = .{};
    try served.set("served-model");
    const values = [_]protocol.ActivityItem.Value{
        .{ .admission = .{ .admission = 1, .key = key, .turn = null, .state = .queued, .content = content, .admitted_at = 100 } },
        .{ .user = .{ .admission = 1, .key = key, .turn = 2, .state = .applied, .content = content, .admitted_at = 100 } },
        .{ .assistant = .{ .content = content, .final = true } },
        .{ .call = .{ .position = 5, .operation = 3, .turn = 2, .call_ordinal = 1, .action = null, .rejection = .unknown_tool, .fields = .{ field, .{ .length = 0, .digest = @splat(0x02) }, field } } },
        .{ .tool_result = .{ .content = content, .presentation = presentation } },
        .{ .hosted_call = .{ .description = null, .code = .succeeded, .publication_position = null } },
        .{ .turn_ended = .{ .session = session, .turn = 2, .operation = 3, .ending = .done, .code = code, .content = null } },
        .{ .stop = .{ .key = key, .turn = null, .cutoff = 9, .completion = .pending } },
        .{ .sent = .{ .admission = 4, .target = peer, .content = content, .admitted_at = 101 } },
        .{ .send_failed = .{ .key = key, .target = null, .code = code } },
        .{ .received = .{ .admission = 5, .key = key, .turn = 3, .state = .excluded, .content = content, .admitted_at = 102, .sender = bare } },
        .{ .approval_requested = .{ .session = session, .action = 7, .operation = 3, .call_ordinal = 0 } },
        .{ .session_changed = .{ .revision = 2, .field = .label } },
        .{ .compacted = .{ .operation = 8, .dropped = 0 } },
        .{ .model_call = .{ .model = model, .served_model = served, .input_tokens = 100, .output_tokens = 7, .cached_tokens = 40, .latency_ms = 23, .first_event_ms = 5, .status = code, .attempts = 2 } },
    };
    comptime std.debug.assert(values.len == std.meta.tags(protocol.ActivityItem.Kind).len);
    const facts = try std.testing.allocator.create(protocol.ActivityFacts);
    defer std.testing.allocator.destroy(facts);
    facts.* = .{ .end = 20, .direction = .backward, .count = values.len, .more = true, .work = .{ .revision = 3, .work = .{ .state = .{ .stopped = .{ .since = 50, .cause = .stop } }, .turn = 2 } } };
    for (values, facts.items[0..values.len], 0..) |value, *item, index| item.* = .{ .position = index + 1, .ordinal = if (value == .model_call) 0 else index % 2, .at = 1000 + index, .value = value };
    try facts.work.workspace.set("/w \"x\"");
    facts.call_activity = .{ .total = 5, .count = 2 };
    facts.call_activity.entries[0] = .{ .operation = 3, .ordinal = 0, .presentation = presentation };
    facts.call_activity.entries[1] = .{ .operation = 3, .ordinal = 1, .presentation = .{ .description = null, .code = .succeeded, .publication_position = null } };
    facts.queued = .{ .count = 2, .oldest_position = 11, .newest_admission = 6, .newest_position = 14 };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try host_reply.renderActivityPage(.{ .writer = &out.writer }, facts);
    try std.testing.expectEqualStrings(every_kind, out.written());
}
