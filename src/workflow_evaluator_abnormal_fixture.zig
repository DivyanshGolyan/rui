const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &buffer);
    var first: [1]u8 = undefined;
    const first_length = try reader.interface.readSliceShort(&first);
    while (try reader.interface.discardRemaining() != 0) {}
    if (first_length == 1) switch (first[0]) {
        0xfb => {
            var output: [4096]u8 = @splat('x');
            var writer_buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writer(init.io, &writer_buffer);
            var remaining: usize = 512 * 1024 + 1;
            while (remaining != 0) {
                const amount = @min(remaining, output.len);
                try writer.interface.writeAll(output[0..amount]);
                remaining -= amount;
            }
            try writer.interface.flush();
            return;
        },
        0xfc => try std.posix.kill(std.c.getpid(), .XCPU),
        0xfd => try std.posix.kill(std.c.getpid(), .SEGV),
        0xfe => try std.posix.kill(std.c.getpid(), .KILL),
        else => {},
    };
    if (first_length == 1 and first[0] == 0xff) {
        _ = std.posix.system.close(std.posix.STDOUT_FILENO);
        _ = std.posix.system.close(std.posix.STDERR_FILENO);
        while (true) {}
    }
    std.process.exit(9);
}
