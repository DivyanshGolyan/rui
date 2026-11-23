const std = @import("std");
const os = @import("os");

pub const GroupSignal = enum { sent, absent, zombie_group_denied, failed };

pub fn signalGroup(pgid: std.posix.pid_t, signal: std.posix.SIG) GroupSignal {
    std.posix.kill(-pgid, signal) catch |err| return classifyGroupSignal(err, os.tag);
    return .sent;
}

/// Darwin returns EPERM for kill(-pgid) when every member of the group is a
/// zombie; Linux delivers to the zombies. Elsewhere EPERM is a real refusal.
pub fn classifyGroupSignal(err: std.posix.KillError, tag: std.Target.Os.Tag) GroupSignal {
    return switch (err) {
        error.ProcessNotFound => .absent,
        error.PermissionDenied => if (tag == .macos) .zombie_group_denied else .failed,
        else => .failed,
    };
}

test "group EPERM is a zombie group only on Darwin" {
    try std.testing.expectEqual(GroupSignal.zombie_group_denied, classifyGroupSignal(error.PermissionDenied, .macos));
    try std.testing.expectEqual(GroupSignal.failed, classifyGroupSignal(error.PermissionDenied, .linux));
    for ([_]std.Target.Os.Tag{ .linux, .macos }) |tag| {
        try std.testing.expectEqual(GroupSignal.absent, classifyGroupSignal(error.ProcessNotFound, tag));
    }
}

/// Return the free heap pages the allocator still holds to the kernel. glibc's
/// malloc_trim covers every thread's arena, whichever thread calls it.
pub fn releaseFreeHeap() void {
    if (os.glibc_malloc) _ = glibc.malloc_trim(0);
}

const glibc = struct {
    extern "c" fn malloc_trim(pad: usize) c_int;
};

/// Darwin `rui host` replaces its image once with MallocMaxMagazines and
/// MallocSpaceEfficient defaults, which libmalloc reads before main. Call it
/// before acquiring Store custody; key presence prevents another exec, and
/// explicit caller values (including empty values) always take precedence.
pub fn applyHostMallocDefaults(init: std.process.Init, args: []const []const u8) !void {
    if (os.tag != .macos) return;
    if (std.mem.eql(u8, init.environ_map.get("RUI_HOST_MALLOC_DEFAULTS") orelse "", "0")) return;
    var changed = false;
    for ([_][]const u8{ "MallocMaxMagazines", "MallocSpaceEfficient" }) |key| {
        if (init.environ_map.get(key) != null) continue;
        try init.environ_map.put(key, "1");
        changed = true;
    }
    if (!changed) return;

    const argv = try init.arena.allocator().dupe([]const u8, args);
    argv[0] = try @import("../self_executable.zig").path(init.io);
    return std.process.replace(init.io, .{ .argv = argv, .environ_map = init.environ_map });
}
