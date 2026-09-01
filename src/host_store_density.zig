const std = @import("std");
const store_module = @import("host_store.zig");

pub fn main(init: std.process.Init) !void {
    var random: u64 = 0;
    while (random == 0) init.io.random(std.mem.asBytes(&random));
    var path: [160]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &path,
        ".zig-cache/onepage-relational-density-{x}.sqlite3",
        .{random},
    );
    var store = try store_module.Store.open(database_path);
    defer store.close();
    var identity: u64 = 1;
    const scope = store_module.semanticDigest(.access_scope, "/workspace");
    for (0..10_000) |index| {
        const session_id = identity;
        const turn_id = identity + 1;
        _ = try store.admitTurn(.{
            .session_id = session_id,
            .turn_id = turn_id,
            .turn_ordinal = 1,
            .entry_id = identity + 2,
            .content_id = identity + 3,
            .expected_conversation_revision = 0,
            .workspace_path = "/workspace",
            .access_scope_digest = scope,
            .admission_digest = store_module.semanticDigest(.turn, "dormant"),
            .user_text = "dormant",
        });
        _ = try store.settleTurn(.{ .turn_id = turn_id, .outcome = .cancelled });
        identity += 4;
        if (index + 1 == 100 or index + 1 == 1_000 or index + 1 == 10_000) {
            var line: [96]u8 = undefined;
            const message = try std.fmt.bufPrint(&line, "durable_sessions={d}\n", .{index + 1});
            try std.Io.File.stdout().writeStreamingAll(init.io, message);
        }
    }
}
