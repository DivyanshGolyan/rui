//! Allocation SQLite mechanism tests.
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const TestingCall = tests.TestingCall;
const settleCallsForTesting = tests.settleCallsForTesting;

test "an engine OutOfMemory under configure, a skills reload or a catalog read answers OutOfMemory without fencing" {
    const skills = @import("../../skills.zig");
    const skills_domain = @import("../domain/skills.zig");
    for ([_]enum { configure, reload, read, tool }{ .configure, .reload, .read, .tool }) |door| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try store_testing.testingStore(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io);
        defer storage.close() catch unreachable;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const saved: skills.Catalog = .{ .entries = &.{.{ .name = "demo", .description = "engine pressure", .path = "/skills/demo/SKILL.md" }} };
        const initial: skills_domain.Initial = .{ .ready = .{
            .encoded = try skills.encodeCatalog(arena.allocator(), saved),
            .instruction = try skills.initialInstruction(arena.allocator(), saved),
        } };
        var path: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try store_testing.canonicalCwd(std.testing.io, &path);
        var create = try store_testing.completeConfiguration("engine-oom", "", workspace, "model-a");
        create.configuration.tools = try .of(&.{"skill"});
        const session = (try storage.configureWithInitialSkills(&create, null, &initial, .{})).accepted.session;
        const candidate: skills_domain.Capture = .{ .reload = .{ .entries = &.{} } };
        const binding = if (door == .tool) binding: {
            try store_testing.submitTestMessage(&storage, &tmp, "engine-oom-input", "engine-oom-message", session.slice(), "reload");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "reload-item", .name = "skill", .encoded_call_id = "reload-call", .decoded_call_id = "reload-call", .encoded_arguments = "{\\\"operation\\\":\\\"reload\\\"}", .decoded_arguments = "{\"operation\":\"reload\"}" }};
            try settleCallsForTesting(&storage, &tmp, model, "engine-oom-calls", &calls);
            break :binding (try storage.nextCoreWork()).?.action.binding;
        } else undefined;
        // The first statement the call prepares again fails in the engine,
        // as when its cache cannot grow, with the caller's own memory to spare.
        const cache = &storage.engine.sqlite.statements;
        var cached: [512][*:0]const u8 = undefined;
        var count: usize = 0;
        // Test oracles on temp tables stay cached; only Store statements go.
        for (cache.slots) |slot| if (slot.sql) |sql| if (std.mem.indexOf(u8, std.mem.span(sql), "temp.") == null) {
            cached[count] = sql;
            count += 1;
        };
        for (cached[0..count]) |sql| cache.remove(sql);
        sqlite.testing_fail_next_insert = true;
        defer sqlite.testing_fail_next_insert = false;
        switch (door) {
            .configure => {
                var update = try store_testing.completeConfiguration("engine-oom-update", session.slice(), workspace, "model-a");
                update.configuration.tools = try .of(&.{"skill"});
                try std.testing.expectError(error.OutOfMemory, storage.configure(&update, .{}));
            },
            .reload => {
                var reload: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
                try reload.key.set("engine-oom-reload");
                try std.testing.expectError(error.OutOfMemory, storage.configureWithCapturedSkills(&reload, null, null, &candidate, std.testing.allocator, .{}));
            },
            .read => try std.testing.expectError(error.OutOfMemory, storage.readSkills(arena.allocator(), session.slice())),
            .tool => try std.testing.expectError(error.OutOfMemory, storage.settleSkillTool(binding, arena.allocator(), &candidate, .{})),
        }
        try std.testing.expect(!sqlite.testing_fail_next_insert);
        try std.testing.expect(!storage.isFenced());
    }
}
