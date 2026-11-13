//! Settings presets and direct configuration resolve the same offered tools.
const std = @import("std");
const hs = @import("host_settings.zig");
const protocol = @import("protocol.zig");
const wire_request = @import("wire_request.zig");
const core_tools = @import("core_tools.zig");
const start_report = @import("start_report.zig");

fn checkPreset(gpa: std.mem.Allocator, spec: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
    const configuration = try gpa.create(wire_request.Configuration);
    defer gpa.destroy(configuration);
    return switch (try core_tools.parseAgentSpec(gpa, spec, configuration)) {
        .accepted => null,
        .rejected => |reason| reason,
    };
}

test "settings presets resolve MCP tools through the same tool set as configure" {
    const store_testing = @import("store.zig").testing;
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const tool_defs = @import("tools.zig");
            const store = @import("store.zig");
            var settings: hs.Settings = .{};
            defer settings.deinit();
            var refusal: start_report.Failure = undefined;
            try hs.apply(&settings, std.testing.allocator,
                \\{"presets":{"reader":{"model":"model-a","effort":null,"compactAt":1000,"tools":["fetch_page"],"permissionMode":"ask"}}}
            , .pipe, checkPreset, &refusal);
            var records = comptime store.testingHostToolRecords(&.{
                .{ .name = "fetch_page", .owner = .mcp, .server = "pages", .description = "Fetch page", .input_schema = "{\"type\":\"object\"}" },
            });
            var digests: [records.len][32]u8 = undefined;
            for (&records, &digests) |*record, *digest| digest.* = tool_defs.recordDigest(record);
            const offered: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            var routes = protocol.routesAll(.unserved);
            routes.openai = .endpoint;
            for ([_]bool{ false, true }) |available| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: store.Store = undefined;
                try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{
                    .served = routes,
                    .host_tool_set = if (available) &offered else &tool_defs.built_in_tool_set,
                });
                defer storage.close() catch unreachable;

                var direct: wire_request.ConfigureCommand = .{};
                try direct.key.set("mcp-direct");
                direct.configuration.model.state = .value;
                try direct.configuration.model.value.set("model-a");
                direct.configuration.reasoning_effort.state = .explicit_null;
                direct.configuration.compaction_trigger.state = .value;
                try direct.configuration.compaction_trigger.value.set("1000");
                direct.configuration.tools = try .of(&.{"fetch_page"});
                direct.configuration.permission_mode.state = .value;
                try direct.configuration.permission_mode.value.set("ask");
                const ordinary = try storage.configure(&direct, .{});

                var request: wire_request.ConfigureCommand = .{ .preset = .{} };
                try request.key.set("mcp-preset");
                try request.preset.?.set("reader");
                var resolved: wire_request.ConfigureCommand = .{ .key = request.key };
                var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer memory.deinit();
                try std.testing.expect(try core_tools.parseAgentSpec(memory.allocator(), settings.presets.specs[0].spec, &resolved.configuration) == .accepted);
                const preset = try storage.configureWithPreset(&resolved, &.{ .request_digest = request.presetRequestDigest() }, .{});
                if (available) {
                    try std.testing.expect(ordinary == .accepted);
                    try std.testing.expect(preset == .accepted);
                    for ([_]@TypeOf(ordinary.accepted.session){ ordinary.accepted.session, preset.accepted.session }) |session| {
                        try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session s JOIN tool_set_member m ON m.tool_set_id=s.tool_set_id " ++
                            "JOIN tool_record t ON t.tool_record_id=m.tool_record_id WHERE s.session_ref=?1 AND t.name='fetch_page'", .{session.slice()}));
                    }
                } else {
                    try std.testing.expect(ordinary == .rejected);
                    try std.testing.expect(preset == .rejected);
                    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_tool, ordinary.rejected.code);
                    try std.testing.expectEqual(ordinary.rejected.code, preset.rejected.code);
                    try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                }
            }
        }
    }.run);
}
