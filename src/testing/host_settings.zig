const std = @import("std");
const hs = @import("../host_settings.zig");
const protocol = @import("../protocol.zig");
const connection = @import("../connection.zig");
const core_tools = @import("../core_tools.zig");
const wire_request = @import("../wire_request.zig");
const preset_value = @import("../preset_value.zig");
const start_report = @import("../start_report.zig");

fn checkPreset(allocator: std.mem.Allocator, object: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
    const configuration = try allocator.create(wire_request.Configuration);
    return switch (try core_tools.parseAgentSpec(allocator, object, configuration)) {
        .accepted => null,
        .rejected => |reason| reason,
    };
}

/// The Host's own header names (`provider.hostField`) are owned by the shell;
/// this table names none, so the stand-in refuses no header.
fn noHostField(_: []const u8) bool {
    return false;
}
const checks: hs.Checks = .{ .preset = checkPreset, .host_field = noHostField };

const creation_fields = "\"workspace\":\"/tmp/workspace\",\"connection\":\"" ++ @tagName(std.enums.values(@import("../provider_name.zig").Provider)[0]) ++ "\",";
const spec = "{" ++ creation_fields ++
    \\"model":"model-a","effort":"low","compactAt":1000,"tools":["bash"],"permissionMode":"ask","instructions":"Retained instructions","outputSchema":{"type":"object","properties":{"answer":{"type":"string"}}}}
;
const changed_spec = "{" ++ creation_fields ++
    \\"model":"model-b","effort":null,"compactAt":2000,"tools":[],"permissionMode":"bypass"}
;

fn expectModel(settings: *const hs.Settings, name: []const u8, expected: []const u8) !void {
    for (settings.presets.specs) |preset| if (std.mem.eql(u8, name, preset.name)) {
        try std.testing.expectEqualStrings(expected, preset.spec.get("model").?.string);
        return;
    };
    return error.TestExpectedPreset;
}

fn document(allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"presets\":{{\"{s}\":{s}}}}}", .{ name, value });
}

test "Host settings real preset checker accepts specs and retains independent input storage" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = .init(.settings_invalid, "");
    const input = try document(gpa, "reader", spec);
    defer gpa.free(input);
    try hs.apply(settings, gpa, input, .pipe, checks, &failure);
    @memset(input, 'x');
    try std.testing.expectEqual(@as(usize, 1), settings.presets.specs.len);
    try expectModel(settings, "reader", "model-a");
    const retained = settings.presets.specs[0].spec;
    try std.testing.expectEqualStrings("Retained instructions", retained.get("instructions").?.string);
    try std.testing.expectEqualStrings("bash", retained.get("tools").?.array.items[0].string);
    const answer = retained.get("outputSchema").?.object.get("properties").?.object.get("answer").?.object;
    try std.testing.expectEqualStrings("string", answer.get("type").?.string);
    var memory: std.heap.ArenaAllocator = .init(gpa);
    defer memory.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try checkPreset(memory.allocator(), retained));
}

test "Host settings real preset checker refuses semantic errors with path and no value" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = .init(.settings_invalid, "");
    const invalid =
        \\{"presets":{"reader":{"model":"model-a","effort":"DO_NOT_PRINT_PRESET_VALUE","compactAt":1000,"tools":[],"permissionMode":"ask"}}}
    ;
    try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, invalid, .file, checks, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "presets.reader") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "effort") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "DO_NOT_PRINT_PRESET_VALUE") == null);
    try std.testing.expectEqual(@as(usize, 0), settings.presets.specs.len);
}

test "Host settings presets replace sets while CLI edits preserve retained siblings" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = .init(.settings_invalid, "");
    const input = try document(gpa, "reader", spec);
    defer gpa.free(input);
    try hs.apply(settings, gpa, input, .pipe, checks, &failure);
    try hs.assign(settings, gpa, "presets.writer", changed_spec, checks, &failure);
    try std.testing.expectEqual(@as(usize, 2), settings.presets.specs.len);
    try expectModel(settings, "reader", "model-a");
    try expectModel(settings, "writer", "model-b");
    try hs.assign(settings, gpa, "presets.writer", spec, checks, &failure);
    try expectModel(settings, "reader", "model-a");
    try expectModel(settings, "writer", "model-a");
    try hs.assign(settings, gpa, "presets.reader", "null", checks, &failure);
    try std.testing.expectEqual(@as(usize, 1), settings.presets.specs.len);
    try expectModel(settings, "writer", "model-a");
    try hs.apply(settings, gpa, "{}", .file, checks, &failure);
    try expectModel(settings, "writer", "model-a");
    try hs.apply(settings, gpa, input, .file, checks, &failure);
    try std.testing.expectEqual(@as(usize, 1), settings.presets.specs.len);
    try expectModel(settings, "reader", "model-a");
    try hs.apply(settings, gpa, "{\"presets\":{}}", .file, checks, &failure);
    try std.testing.expectEqual(@as(usize, 0), settings.presets.specs.len);
    try std.testing.expect(settings.presets.memory == null);
}

test "Host settings real preset collection derives name and count limits" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = .init(.settings_invalid, "");
    const longest: [preset_value.max_preset_name_bytes]u8 = @splat('a');
    const input = try document(gpa, &longest, spec);
    defer gpa.free(input);
    try hs.apply(settings, gpa, input, .pipe, checks, &failure);
    try expectModel(settings, &longest, "model-a");
    const overlong: [preset_value.max_preset_name_bytes + 1]u8 = @splat('a');
    const invalid = try document(gpa, &overlong, spec);
    defer gpa.free(invalid);
    try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, invalid, .pipe, checks, &failure));
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try output.writer.writeAll("{\"presets\":{");
    for (0..preset_value.max_presets + 1) |i| {
        if (i != 0) try output.writer.writeByte(',');
        try output.writer.print("\"entry_{d}\":{s}", .{ i, spec });
        if (i + 1 == preset_value.max_presets) {
            const boundary = try std.fmt.allocPrint(gpa, "{s}}}}}", .{output.written()});
            defer gpa.free(boundary);
            try hs.apply(settings, gpa, boundary, .pipe, checks, &failure);
            try std.testing.expectEqual(preset_value.max_presets, settings.presets.specs.len);
        }
    }
    try output.writer.writeAll("}}");
    try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, output.written(), .pipe, checks, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "presets") != null);
}

fn allocationFailureCase(gpa: std.mem.Allocator) !void {
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = .init(.settings_invalid, "");
    const input = "{\"store\":{\"mysql\":{\"url\":{\"value\":\"mysql://user:PRIVATE_PASSWORD@localhost/database\"}}}," ++
        "\"providers\":{},\"interface\":{\"dir\":\"/tmp/settings-test\"}," ++
        "\"tools\":{\"mcp\":{\"sample\":{\"url\":\"http://127.0.0.1:3000/mcp\",\"bearerToken\":{\"value\":\"PRIVATE_MCP_TOKEN\"}}}}," ++
        "\"presets\":{\"reader\":" ++ spec ++ "}}";
    try hs.apply(settings, gpa, input, .pipe, checks, &failure);
    try std.testing.expectEqualStrings("mysql://user:PRIVATE_PASSWORD@localhost/database", settings.store.mysql.url.value());
    try std.testing.expectEqualStrings("PRIVATE_MCP_TOKEN", settings.tools.mcp.values[0].bearer_token.value());
    try hs.assign(settings, gpa, "presets.writer", changed_spec, checks, &failure);
    try hs.assign(settings, gpa, "presets.reader", changed_spec, checks, &failure);
    try std.testing.expectEqual(@as(usize, 2), settings.presets.specs.len);
    try expectModel(settings, "reader", "model-b");
}

test "Host settings real preset mixed secret allocation failures clean every owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

test "Host settings secret vacancy allocation failures erase every copy" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, hs.testing.secretVacancyAllocationFailures, .{});
}

const alpha_connection =
    \\{"name":"alpha","label":"Alpha","base_url":"https://alpha.example/v1","credential":{"kind":"key","source":{"kind":"saved"},"placement":"bearer"},"headers":[],"refusals":[],"formats":[{"family":"responses","dialect":"openai-responses/3","web_search":false}],"assign":[],"models":{"list":"openai"}}
;
const beta_connection =
    \\{"name":"beta","label":"Beta","base_url":"https://beta.example/v1","credential":{"kind":"key","source":{"kind":"env","name":"BETA_KEY"},"placement":"bearer"},"headers":[],"refusals":[],"formats":[{"family":"responses","dialect":"openai-responses/3","web_search":false}],"assign":[],"models":{"list":"openai"}}
;

fn connectionDocument(gpa: std.mem.Allocator, entries: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("{\"providers\":{},\"connections\":[");
    for (entries, 0..) |entry, i| {
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.writeAll(entry);
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn replaced(gpa: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, text, from, to);
}

fn expectRefusal(gpa: std.mem.Allocator, text: []const u8, path: []const u8, reason: []const u8) !void {
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = .init(.settings_invalid, "");
    try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, text, .pipe, checks, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), path) != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), reason) != null);
    try std.testing.expectEqual(@as(usize, 0), settings.connections.entries.len);
}

// SH-153 is the connections document's admission: the parser's refusals name
// the entry and field, and a name is unique and not a sign-in's. SH-154 is
// this slice's served shape: each shape another Rui version serves is refused
// by name at seal, and nothing else is.
test "HST connections: SH-153 two valid entries parse, seal and round-trip through write" {
    const gpa = std.testing.allocator;
    const text = try connectionDocument(gpa, &.{ alpha_connection, beta_connection });
    defer gpa.free(text);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = .init(.settings_invalid, "");
    try hs.apply(settings, gpa, text, .file, checks, &failure);
    try std.testing.expectEqual(@as(usize, 2), settings.connections.entries.len);
    try std.testing.expectEqualStrings("alpha", settings.connections.entries[0].value.name.slice());
    try std.testing.expectEqualStrings("beta", settings.connections.entries[1].value.name.slice());
    try hs.anchor(settings, "/tmp/host-settings");
    _ = try hs.seal(settings, &failure);

    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    try hs.write(settings, &first.writer);
    const again = try gpa.create(hs.Settings);
    defer gpa.destroy(again);
    again.* = .{};
    defer again.deinit();
    try hs.apply(again, gpa, first.written(), .pipe, checks, &failure);
    try std.testing.expectEqual(@as(usize, 2), again.connections.entries.len);
    try std.testing.expect(std.meta.activeTag(again.connections.entries[1].value.credential.key.source) == .env);
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try hs.write(again, &second.writer);
    try std.testing.expectEqualStrings(first.written(), second.written());
}

test "HST connections: SH-153 each entry refusal names its entry and field" {
    const gpa = std.testing.allocator;
    const doc_1 = try connectionDocument(gpa, &.{ alpha_connection, alpha_connection });
    defer gpa.free(doc_1);
    try expectRefusal(gpa, doc_1, "connections[1].name", "duplicate connection name");
    for ([_][]const u8{ "codex", "chatgpt" }) |reserved| {
        const named = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"", .{reserved});
        defer gpa.free(named);
        const entry = try replaced(gpa, alpha_connection, "{\"name\":\"alpha\"", named);
        defer gpa.free(entry);
        const text = try connectionDocument(gpa, &.{entry});
        defer gpa.free(text);
        try expectRefusal(gpa, text, "connections[0].name", "reserved for the ChatGPT sign-in");
    }
    const bad_name = try replaced(gpa, alpha_connection, "{\"name\":\"alpha\"", "{\"name\":\"Alpha\"");
    defer gpa.free(bad_name);
    const doc_2 = try connectionDocument(gpa, &.{bad_name});
    defer gpa.free(doc_2);
    try expectRefusal(gpa, doc_2, "connections[0].name", "invalid_name");
    const no_format = try replaced(gpa, alpha_connection, "\"formats\":[{\"family\":\"responses\",\"dialect\":\"openai-responses/3\",\"web_search\":false}]", "\"formats\":[]");
    defer gpa.free(no_format);
    const doc_3 = try connectionDocument(gpa, &.{no_format});
    defer gpa.free(doc_3);
    try expectRefusal(gpa, doc_3, "connections[0].formats", "no_format");
    const label_twice = try replaced(gpa, alpha_connection, "\"label\":\"Alpha\"", "\"label\":\"Alpha\",\"label\":\"Again\"");
    defer gpa.free(label_twice);
    const doc_4 = try connectionDocument(gpa, &.{label_twice});
    defer gpa.free(doc_4);
    try expectRefusal(gpa, doc_4, "connections.label", "duplicate key");
    var too_many: [connection.max_list + 1][]const u8 = undefined;
    for (&too_many) |*entry| entry.* = alpha_connection;
    const doc_5 = try connectionDocument(gpa, &too_many);
    defer gpa.free(doc_5);
    try expectRefusal(gpa, doc_5, "connections", "too many connections");
}

test "HST connections: SH-153 the nesting bound refuses the next container inside connections" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"providers\":{},\"connections\":");
    const depth = protocol.max_json_depth;
    for (0..depth) |_| try out.writer.writeByte('[');
    for (0..depth) |_| try out.writer.writeByte(']');
    try out.writer.writeByte('}');
    try expectRefusal(gpa, out.written(), "connections", "nesting");
}

test "HST connections: SH-154 a sign-in connection seals only at the Adapter's endpoint with its own listing and issuer" {
    const gpa = std.testing.allocator;
    const device_ok = "{\"kind\":\"openai-device\",\"client_id\":\"app_x\",\"audience\":\"https://chatgpt.com/backend-api/codex\"}";
    const oauth_ok = "{\"kind\":\"oauth\",\"authorize_url\":\"https://auth.openai.com/oauth/authorize\",\"token_url\":\"https://auth.openai.com/oauth/token\",\"client_id\":\"client\",\"scopes\":\"openid chatgpt.tokens.use.direct\",\"required_scope\":\"chatgpt.tokens.use.direct\",\"audience\":\"https://api.openai.com/v1\",\"link\":[]}";
    const oauth_foreign = "{\"kind\":\"oauth\",\"authorize_url\":\"https://auth.example/authorize\",\"token_url\":\"https://auth.example/token\",\"client_id\":\"client\",\"scopes\":\"openid chatgpt.tokens.use.direct\",\"required_scope\":\"chatgpt.tokens.use.direct\",\"audience\":\"https://api.openai.com/v1\",\"link\":[]}";
    const cases = [_]struct { credential: []const u8, dialect: []const u8, base: []const u8, list: []const u8, refused: ?[]const u8 }{
        .{ .credential = device_ok, .dialect = "openai-responses/2", .base = "https://chatgpt.com/backend-api/codex", .list = "catalog", .refused = null },
        .{ .credential = device_ok, .dialect = "openai-responses/3", .base = "https://chatgpt.com/backend-api/codex", .list = "catalog", .refused = "credential" },
        .{ .credential = device_ok, .dialect = "openai-responses/2", .base = "https://chatgpt.com/backend-api/codex", .list = "openai", .refused = "models.list" },
        .{ .credential = oauth_ok, .dialect = "openai-responses/3", .base = "https://api.openai.com/v1", .list = "chatgpt_plan", .refused = null },
        .{ .credential = oauth_ok, .dialect = "openai-responses/2", .base = "https://api.openai.com/v1", .list = "chatgpt_plan", .refused = "credential" },
        .{ .credential = oauth_ok, .dialect = "openai-responses/3", .base = "https://api.openai.com/v1", .list = "catalog", .refused = "models.list" },
        .{ .credential = oauth_ok, .dialect = "openai-responses/3", .base = "https://gateway.example/v1", .list = "chatgpt_plan", .refused = "base_url" },
        .{ .credential = oauth_foreign, .dialect = "openai-responses/3", .base = "https://api.openai.com/v1", .list = "chatgpt_plan", .refused = "credential" },
    };
    for (cases) |case| {
        const entry = try std.fmt.allocPrint(gpa, "{{\"name\":\"work\",\"label\":\"Work\",\"base_url\":\"{s}\",\"credential\":{s},\"headers\":[],\"refusals\":[],\"formats\":[{{\"family\":\"responses\",\"dialect\":\"{s}\",\"web_search\":false}}],\"assign\":[],\"models\":{{\"list\":\"{s}\"}}}}", .{ case.base, case.credential, case.dialect, case.list });
        defer gpa.free(entry);
        const text = try connectionDocument(gpa, &.{entry});
        defer gpa.free(text);
        const settings = try gpa.create(hs.Settings);
        defer gpa.destroy(settings);
        settings.* = .{};
        defer settings.deinit();
        var failure: start_report.Failure = .init(.settings_invalid, "");
        try hs.apply(settings, gpa, text, .file, checks, &failure);
        try hs.anchor(settings, "/tmp/host-settings");
        if (case.refused) |field| {
            try std.testing.expectError(error.SettingsInvalid, hs.seal(settings, &failure));
            const expected = try std.fmt.allocPrint(gpa, "connections.work.{s}", .{field});
            defer gpa.free(expected);
            try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), expected) != null);
        } else _ = try hs.seal(settings, &failure);
    }
}

test "HST connections: SH-154 seal refuses each shape this Rui version does not serve, by name" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { from: []const u8, to: []const u8, field: []const u8 }{
        .{ .from = "{\"kind\":\"saved\"}", .to = "{\"kind\":\"command\",\"command\":\"printf x\"}", .field = "credential.source" },
        .{ .from = "\"placement\":\"bearer\"", .to = "\"placement\":\"x-api-key\"", .field = "credential" },
        .{ .from = "\"credential\":{\"kind\":\"key\",\"source\":{\"kind\":\"saved\"},\"placement\":\"bearer\"}", .to = "\"credential\":{\"kind\":\"openai-device\",\"client_id\":\"app_x\",\"audience\":\"https://alpha.example/v1\"}", .field = "credential" },
        .{ .from = "\"formats\":[{\"family\":\"responses\",\"dialect\":\"openai-responses/3\",\"web_search\":false}]", .to = "\"formats\":[{\"family\":\"messages\",\"dialect\":\"anthropic-messages/1\",\"web_search\":false}]", .field = "formats" },
        .{ .from = "\"headers\":[]", .to = "\"headers\":[{\"name\":\"x-team\",\"from\":{\"kind\":\"literal\",\"value\":\"a\"}}]", .field = "headers" },
        .{ .from = "\"refusals\":[]", .to = "\"refusals\":[{\"status\":403,\"body_contains\":\"x\",\"means\":\"key_rejected\"}]", .field = "refusals" },
    };
    for (cases) |case| {
        const entry = try replaced(gpa, alpha_connection, case.from, case.to);
        defer gpa.free(entry);
        const text = try connectionDocument(gpa, &.{entry});
        defer gpa.free(text);
        const settings = try gpa.create(hs.Settings);
        defer gpa.destroy(settings);
        settings.* = .{};
        defer settings.deinit();
        var failure: start_report.Failure = .init(.settings_invalid, "");
        try hs.apply(settings, gpa, text, .file, checks, &failure);
        try hs.anchor(settings, "/tmp/host-settings");
        try std.testing.expectError(error.SettingsInvalid, hs.seal(settings, &failure));
        const expected = try std.fmt.allocPrint(gpa, "connections.alpha.{s}", .{case.field});
        defer gpa.free(expected);
        if (std.mem.eql(u8, case.field, "credential")) {
            try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "connections.alpha.credential") != null);
        } else try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), expected) != null);
        try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "not served by this Rui version") != null);
    }
}
