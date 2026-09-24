const std = @import("std");
const credentials = @import("codex_credentials");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len != 3) return error.ExpectedActionAndCredentialPath;
    const action = args[1];
    const path = args[2];
    if (std.mem.eql(u8, action, "inspect")) {
        var record = try credentials.load(path);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
        std.debug.print("{d} {s} {s}\n", .{ record.generation, @tagName(record.state), record.account_id.slice() });
    } else if (std.mem.eql(u8, action, "claim")) {
        const ready_text = init.environ_map.get("RUI_CREDENTIAL_ACTOR_READY_FD") orelse return error.MissingReadyPipe;
        const ready_fd = try std.fmt.parseInt(std.posix.fd_t, ready_text, 10);
        if (std.c.write(ready_fd, "1", 1) != 1) return error.ReadyPipeFailed;
        credentials.markRefreshPending(path, 1) catch |err| switch (err) {
            error.GenerationMismatch => {
                std.debug.print("lost\n", .{});
                return;
            },
            else => return err,
        };
        std.debug.print("claimed\n", .{});
    } else if (std.mem.eql(u8, action, "login")) {
        var replacement = try credentials.load(path);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&replacement));
        try replacement.account_id.set("account-B");
        try replacement.id_token.set("e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2NvdW50LUIifQ.c2ln");
        replacement.state = .ready;
        try credentials.install(path, &replacement, null);
    } else if (std.mem.eql(u8, action, "stale-refresh")) {
        var replacement = try credentials.load(path);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&replacement));
        try replacement.account_id.set("rui-test-account");
        try replacement.id_token.set("e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJydWktdGVzdC1hY2NvdW50In0.c2ln");
        credentials.install(path, &replacement, 1) catch |err| switch (err) {
            error.GenerationMismatch => return,
            else => return err,
        };
        return error.StaleRefreshOverwroteLogin;
    } else return error.UnknownAction;
}
