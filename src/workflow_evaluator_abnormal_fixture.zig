const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &buffer);
    var first: [1]u8 = undefined;
    const first_length = try reader.interface.readSliceShort(&first);
    while (try reader.interface.discardRemaining() != 0) {}
    if (first_length == 1 and first[0] == 0xff) {
        _ = std.posix.system.close(std.posix.STDOUT_FILENO);
        _ = std.posix.system.close(std.posix.STDERR_FILENO);
        while (true) {}
    }
    std.process.exit(9);
}
