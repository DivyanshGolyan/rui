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
    } else if (std.mem.eql(u8, action, "lease")) {
        var selected = try credentials.lease(path);
        defer selected.release();
        std.debug.print("{d} {s}\n", .{ selected.record.generation, selected.record.account_id.slice() });
    } else if (std.mem.eql(u8, action, "claim")) {
        const ready_text = init.environ_map.get("RUI_CREDENTIAL_ACTOR_READY_FD") orelse return error.MissingReadyPipe;
        const ready_fd = try std.fmt.parseInt(std.posix.fd_t, ready_text, 10);
        if (std.c.write(ready_fd, "1", 1) != 1) return error.ReadyPipeFailed;
        const claimed = try credentials.exchangeRefresh(path, 1, {}, struct {
            fn exchange(_: void, current: *const credentials.Record) !credentials.Record {
                var replacement = current.*;
                replacement.state = .ready;
                replacement.refreshed_at += 1;
                return replacement;
            }
        }.exchange);
        std.debug.print("{s}\n", .{if (claimed) "claimed" else "lost"});
    } else if (std.mem.eql(u8, action, "hold-refresh")) {
        const ready_fd = try std.fmt.parseInt(std.posix.fd_t, init.environ_map.get("RUI_CREDENTIAL_ACTOR_READY_FD") orelse return error.MissingReadyPipe, 10);
        const release_fd = try std.fmt.parseInt(std.posix.fd_t, init.environ_map.get("RUI_CREDENTIAL_ACTOR_RELEASE_FD") orelse return error.MissingReleasePipe, 10);
        const Pipes = struct { ready_fd: std.posix.fd_t, release_fd: std.posix.fd_t };
        const claimed = try credentials.exchangeRefresh(path, 1, Pipes{ .ready_fd = ready_fd, .release_fd = release_fd }, struct {
            fn exchange(pipes: Pipes, current: *const credentials.Record) !credentials.Record {
                if (std.c.write(pipes.ready_fd, "1", 1) != 1) return error.ReadyPipeFailed;
                var release: [1]u8 = undefined;
                if (std.c.read(pipes.release_fd, &release, 1) != 1) return error.ReleasePipeFailed;
                var replacement = current.*;
                replacement.state = .ready;
                replacement.refreshed_at += 1;
                return replacement;
            }
        }.exchange);
        if (!claimed) return error.RefreshClaimLost;
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
