const std = @import("std");
const checkpoint = @import("checkpoint.zig");

pub const Boundary = enum {
    after_write,
    after_file_sync,
    after_rename,
    after_dir_sync,
};

pub const FaultHook = struct {
    context: *anyopaque,
    reached: *const fn (*anyopaque, Boundary) anyerror!void,
};

/// Publishes one canonical checkpoint through a same-directory atomic rename.
/// The caller owns the exact-size encoding buffer and every path slice.
pub fn publish(
    dir: std.Io.Dir,
    io: std.Io,
    final_path: []const u8,
    temp_path: []const u8,
    encoded: []u8,
    agent_id: u64,
    generation: u64,
    page: []const u8,
    fault: ?FaultHook,
) !void {
    try checkpoint.encode(encoded, agent_id, generation, page);

    var temp = try dir.createFile(io, temp_path, .{});
    var temp_open = true;
    defer if (temp_open) temp.close(io);
    try temp.writePositionalAll(io, encoded, 0);
    try reach(fault, .after_write);
    try temp.sync(io);
    try reach(fault, .after_file_sync);
    temp.close(io);
    temp_open = false;

    try dir.rename(temp_path, dir, final_path, io);
    try reach(fault, .after_rename);
    const directory_file: std.Io.File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try directory_file.sync(io);
    try reach(fault, .after_dir_sync);
}

fn reach(fault: ?FaultHook, boundary: Boundary) !void {
    if (fault) |hook| try hook.reached(hook.context, boundary);
}

const InjectedFault = struct {
    boundary: Boundary,

    fn reached(context: *anyopaque, boundary: Boundary) anyerror!void {
        const self: *InjectedFault = @ptrCast(@alignCast(context));
        if (boundary == self.boundary) return error.InjectedCrash;
    }

    fn hook(self: *InjectedFault) FaultHook {
        return .{ .context = self, .reached = reached };
    }
};

fn fill(page: []u8, value: u8) void {
    @memset(page, value);
}

fn expectFinal(
    dir: std.Io.Dir,
    io: std.Io,
    buffer: []u8,
    expected: u8,
) !void {
    var file = try dir.openFile(io, "agent.page", .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, buffer, 0);
    try std.testing.expectEqual(@as(usize, checkpoint.encoded_size), read);
    const decoded = try checkpoint.decode(buffer, 42, 7);
    for (decoded.page) |byte| try std.testing.expectEqual(expected, byte);
}

test "atomic publication replaces a canonical checkpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const page = try allocator.alloc(u8, checkpoint.page_size);
    defer allocator.free(page);
    const encoded = try allocator.alloc(u8, checkpoint.encoded_size);
    defer allocator.free(encoded);

    fill(page, 0x11);
    try publish(tmp.dir, io, "agent.page", "agent.page.tmp", encoded, 42, 7, page, null);
    fill(page, 0x22);
    try publish(tmp.dir, io, "agent.page", "agent.page.tmp", encoded, 42, 7, page, null);
    try expectFinal(tmp.dir, io, encoded, 0x22);
}

test "every interrupted boundary leaves the old or new canonical checkpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    inline for (std.meta.tags(Boundary)) |boundary| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const page = try allocator.alloc(u8, checkpoint.page_size);
        defer allocator.free(page);
        const encoded = try allocator.alloc(u8, checkpoint.encoded_size);
        defer allocator.free(encoded);

        fill(page, 0x11);
        try publish(tmp.dir, io, "agent.page", "agent.page.tmp", encoded, 42, 7, page, null);
        fill(page, 0x22);
        var fault: InjectedFault = .{ .boundary = boundary };
        try std.testing.expectError(
            error.InjectedCrash,
            publish(
                tmp.dir,
                io,
                "agent.page",
                "agent.page.tmp",
                encoded,
                42,
                7,
                page,
                fault.hook(),
            ),
        );
        const expected: u8 = switch (boundary) {
            .after_write, .after_file_sync => 0x11,
            .after_rename, .after_dir_sync => 0x22,
        };
        try expectFinal(tmp.dir, io, encoded, expected);
    }
}
