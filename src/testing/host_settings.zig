//! Integration witnesses for settings' injected, real preset grammar.
const std = @import("std");
const hs = @import("../host_settings.zig");
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

const creation_fields = "\"workspace\":\"/tmp/workspace\",\"provider\":\"" ++ @tagName(std.enums.values(@import("../provider_name.zig").Provider)[0]) ++ "\",";
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
    try hs.apply(settings, gpa, input, .pipe, checkPreset, &failure);
    @memset(input, 'x');
    try std.testing.expectEqual(@as(usize, 1), settings.presets.specs.len);
    try expectModel(settings, "reader", "model-a");
    const retained = settings.presets.specs[0].spec;
    try std.testing.expectEqualStrings("Retained instructions", retained.get("instructions").?.string);
    try std.testing.expectEqualStrings("bash", retained.get("tools").?.array.items[0].string);
    const answer = retained.get("outputSchema").?.object.get("properties").?.object.get("answer").?.object;
    try std.testing.expectEqualStrings("string", answer.get("type").?.string);
    // Exercise the retained representation through its real consumer too.
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
    try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, invalid, .file, checkPreset, &failure));
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
    try hs.apply(settings, gpa, input, .pipe, checkPreset, &failure);
    try hs.assign(settings, gpa, "presets.writer", changed_spec, checkPreset, &failure);
    try std.testing.expectEqual(@as(usize, 2), settings.presets.specs.len);
    try expectModel(settings, "reader", "model-a");
    try expectModel(settings, "writer", "model-b");
    // Editing one entry serializes borrowed sibling specs before freeing the old arena.
    try hs.assign(settings, gpa, "presets.writer", spec, checkPreset, &failure);
    try expectModel(settings, "reader", "model-a");
    try expectModel(settings, "writer", "model-a");
    try hs.assign(settings, gpa, "presets.reader", "null", checkPreset, &failure);
    try std.testing.expectEqual(@as(usize, 1), settings.presets.specs.len);
    try expectModel(settings, "writer", "model-a");
    try hs.apply(settings, gpa, "{}", .file, checkPreset, &failure);
    try expectModel(settings, "writer", "model-a");
    try hs.apply(settings, gpa, input, .file, checkPreset, &failure);
    try std.testing.expectEqual(@as(usize, 1), settings.presets.specs.len);
    try expectModel(settings, "reader", "model-a");
    try hs.apply(settings, gpa, "{\"presets\":{}}", .file, checkPreset, &failure);
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
    try hs.apply(settings, gpa, input, .pipe, checkPreset, &failure);
    try expectModel(settings, &longest, "model-a");
    const overlong: [preset_value.max_preset_name_bytes + 1]u8 = @splat('a');
    const invalid = try document(gpa, &overlong, spec);
    defer gpa.free(invalid);
    try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, invalid, .pipe, checkPreset, &failure));
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try output.writer.writeAll("{\"presets\":{");
    for (0..preset_value.max_presets + 1) |i| {
        if (i != 0) try output.writer.writeByte(',');
        try output.writer.print("\"entry_{d}\":{s}", .{ i, spec });
        if (i + 1 == preset_value.max_presets) {
            // The count boundary itself accepts the complete real specs.
            const boundary = try std.fmt.allocPrint(gpa, "{s}}}}}", .{output.written()});
            defer gpa.free(boundary);
            try hs.apply(settings, gpa, boundary, .pipe, checkPreset, &failure);
            try std.testing.expectEqual(preset_value.max_presets, settings.presets.specs.len);
        }
    }
    try output.writer.writeAll("}}");
    try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, output.written(), .pipe, checkPreset, &failure));
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
    try hs.apply(settings, gpa, input, .pipe, checkPreset, &failure);
    try std.testing.expectEqualStrings("mysql://user:PRIVATE_PASSWORD@localhost/database", settings.store.mysql.url.value());
    try std.testing.expectEqualStrings("PRIVATE_MCP_TOKEN", settings.tools.mcp.values[0].bearer_token.value());
    // Every injected failure after apply must also clean old retained presets,
    // parsed login storage and fixed secrets, not just the new editing arena.
    try hs.assign(settings, gpa, "presets.writer", changed_spec, checkPreset, &failure);
    try hs.assign(settings, gpa, "presets.reader", changed_spec, checkPreset, &failure);
    try std.testing.expectEqual(@as(usize, 2), settings.presets.specs.len);
    try expectModel(settings, "reader", "model-b");
}

test "Host settings real preset mixed secret allocation failures clean every owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

test "Host settings secret vacancy allocation failures erase every copy" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, hs.testing.secretVacancyAllocationFailures, .{});
}
