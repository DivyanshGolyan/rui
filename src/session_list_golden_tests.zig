const std = @import("std");
const store = @import("store.zig");
const protocol = @import("protocol.zig");

const one =
    \\{"version":"10","type":"session_list","sessions":[{"archive_state":"active","reference":"<id0>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}}],"delta":"full","since":"<instance>.1","next":null}
;
const pages_first =
    \\{"version":"10","type":"session_list","sessions":[{"archive_state":"active","reference":"<id0>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}},{"archive_state":"active","reference":"<id1>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}},{"archive_state":"active","reference":"<id2>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}},{"archive_state":"active","reference":"<id3>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}},{"archive_state":"active","reference":"<id4>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}},{"archive_state":"active","reference":"<id5>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}},{"archive_state":"active","reference":"<id6>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}},{"archive_state":"active","reference":"<id7>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}}],"delta":"full","since":"<instance>.9","next":{"after":"8","ceiling":"9"}}
;
const pages_second =
    \\{"version":"10","type":"session_list","sessions":[{"archive_state":"active","reference":"<id8>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":null,"created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}}],"delta":"full","since":"<instance>.9","next":null}
;
const escaped =
    \\{"version":"10","type":"session_list","sessions":[{"archive_state":"active","reference":"<id0>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":"quote \" slash \\ café","created_at":"<time>","revision":"1","end":"0","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}}],"delta":"full","since":"<instance>.1","next":null}
;
const since_changed =
    \\{"version":"10","type":"session_list","sessions":[{"archive_state":"active","reference":"<id0>","workspace":"<workspace>","provider":"codex","model":"model","tools":["bash","web_search"],"permission_mode":"bypass","parent":null,"label":"changed","created_at":"<time>","revision":"2","end":"1","first_message":null,"work":{"state":{"kind":"idle","since":"<time>"},"turn":null,"operation":null,"first_action":null},"peers":{"from_person_at":null}}],"delta":"changed","since":"<instance>.2","next":null}
;

fn run(case: *store.testing.Case, comptime scenario: enum { one, pages, escaping, since }) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store.Store = undefined;
    try store.testing.testingStore(case, &storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var root: [protocol.max_store_bytes]u8 = undefined;
    const workspace = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    var ids: [9]protocol.Bounded(protocol.max_session_bytes) = undefined;
    const count = if (scenario == .pages) 9 else 1;
    for (ids[0..count], 0..) |*id, i| {
        var key: [32]u8 = undefined;
        var command = try store.testingCompleteConfiguration(try std.fmt.bufPrint(&key, "golden-{d}", .{i}), "", workspace, "model");
        if (scenario == .escaping) {
            command.configuration.label.state = .value;
            try command.configuration.label.value.set("quote \" slash \\ café");
        }
        const result = storage.configure(&command, .{});
        try std.testing.expect(result == .accepted);
        id.* = result.accepted.session;
    }
    var used = std.atomic.Value(u64).init(0);
    const initial = try store.testingSessionList(&storage, &tmp, .{}, &used, 1);
    defer std.testing.allocator.free(initial);
    try compare(initial, &storage, workspace, ids[0..count], switch (scenario) {
        .one, .since => one,
        .pages => pages_first,
        .escaping => escaped,
    });
    if (scenario == .pages) {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, initial, .{});
        defer parsed.deinit();
        const next = parsed.value.object.get("next").?.object;
        const request: protocol.ListSessions = .{ .after = try std.fmt.parseInt(u64, next.get("after").?.string, 10), .ceiling = try std.fmt.parseInt(u64, next.get("ceiling").?.string, 10) };
        const second = try store.testingSessionList(&storage, &tmp, request, &used, 2);
        defer std.testing.allocator.free(second);
        try compare(second, &storage, workspace, ids[0..count], pages_second);
    }
    if (scenario == .since) {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, initial, .{});
        defer parsed.deinit();
        const token = try protocol.SinceToken.parse(parsed.value.object.get("since").?.string);
        var command = try store.testingCompleteConfiguration("golden-change", ids[0].slice(), workspace, "model");
        command.configuration.label.state = .value;
        try command.configuration.label.value.set("changed");
        try std.testing.expect(storage.configure(&command, .{}) == .accepted);
        const changed = try store.testingSessionList(&storage, &tmp, .{ .since = token }, &used, 2);
        defer std.testing.allocator.free(changed);
        try compare(changed, &storage, workspace, ids[0..count], since_changed);
    }
}

fn compare(bytes: []const u8, storage: *store.Store, workspace: []const u8, ids: []const protocol.Bounded(protocol.max_session_bytes), expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    var normalized = try allocator.dupe(u8, bytes);
    defer allocator.free(normalized);
    try replace(&normalized, workspace, "<workspace>");
    for (ids, 0..) |id, i| {
        var placeholder: [16]u8 = undefined;
        try replace(&normalized, id.slice(), try std.fmt.bufPrint(&placeholder, "<id{d}>", .{i}));
    }
    var token_buffer: [protocol.SinceToken.max_bytes]u8 = undefined;
    const token = (protocol.SinceToken{ .instance = storage.instance, .generation = storage.commit_generation.load(.acquire) }).format(&token_buffer);
    try replace(&normalized, token[0..32], "<instance>");
    for (parsed.value.object.get("sessions").?.array.items) |row| {
        try replace(&normalized, row.object.get("created_at").?.string, "<time>");
        try replace(&normalized, row.object.get("work").?.object.get("state").?.object.get("since").?.string, "<time>");
    }
    try std.testing.expectEqualStrings(expected, normalized);
}

fn replace(text: *[]u8, needle: []const u8, replacement: []const u8) !void {
    const next = try std.mem.replaceOwned(u8, std.testing.allocator, text.*, needle, replacement);
    std.testing.allocator.free(text.*);
    text.* = next;
}

test "session list golden one configured Session" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .one);
        }
    }.go);
}
test "session list golden paged Sessions" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .pages);
        }
    }.go);
}
test "session list golden escaped Label" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .escaping);
        }
    }.go);
}
test "session list golden since change" {
    try store.testing.forEachEngine(struct {
        fn go(case: *store.testing.Case) !void {
            try run(case, .since);
        }
    }.go);
}
