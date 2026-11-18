const std = @import("std");
const pause = @import("testing/pause.zig");
const socket = @import("testing/pause_socket.zig");

fn wake(_: *anyopaque, _: u64) void {
    _ = std.c.write(1, "R", 1);
}

const Worker = struct {
    owner: *pause.PauseController,
    closed: bool = false,
    fn run(self: *Worker) void {
        _ = self.owner.reach(.action_before_handoff, .{ .action = 255 }) catch {
            self.closed = true;
            return;
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const fd = try std.fmt.parseInt(std.posix.fd_t, args[1], 10);
    var owner = pause.PauseController.init(init.io, std.heap.c_allocator);
    defer owner.deinit();
    const adapter = try socket.Adapter.start(std.heap.c_allocator, init.io, &owner, fd);
    defer adapter.stop();
    if (std.c.fcntl(fd, std.c.F.GETFD) & std.c.FD_CLOEXEC == 0) return error.DescriptorInherited;
    try adapter.waitStart();
    var data: [1]u8 = undefined;
    while (std.c.read(0, &data, 1) == 1) {
        const byte = data[0];
        if (byte == 255) {
            var worker: Worker = .{ .owner = &owner };
            const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
            _ = try owner.wait(.{ .point = .action_before_handoff, .context = .{ .action = 255 } });
            _ = std.c.write(1, "A", 1);
            thread.join();
            _ = std.c.write(1, if (worker.closed) "C" else "R", 1);
            continue;
        }
        const result = try owner.poll(byte, .action_before_handoff, .{ .action = byte }, .{ .context = &owner, .call = wake });
        if (result == .pending) _ = std.c.write(1, "A", 1);
    }
}
