const std = @import("std");

const State = enum(u8) { available, borrowed, disabled };
var state: std.atomic.Value(State) = .init(.available);

pub fn tryAcquire() bool {
    return state.cmpxchgStrong(.available, .borrowed, .acquire, .monotonic) == null;
}

pub fn tryExclude() bool {
    const previous = state.cmpxchgStrong(.available, .borrowed, .acquire, .acquire);
    return previous == null or previous == .disabled;
}

pub fn release() void {
    _ = state.cmpxchgStrong(.borrowed, .available, .release, .monotonic);
}

pub fn writeHeld(bytes: []const u8) bool {
    const flags = std.c.fcntl(2, std.c.F.GETFL);
    if (flags < 0) return false;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const change_flags = flags & nonblock == 0;
    // Darwin can modify status flags before SETFL reports an ioctl failure.
    // Restore after every attempted enable, even when no write was permitted.
    const enabled = !change_flags or std.c.fcntl(2, std.c.F.SETFL, flags | nonblock) == 0;
    const written = if (enabled) std.c.write(2, bytes.ptr, bytes.len) else -1;
    if (change_flags and std.c.fcntl(2, std.c.F.SETFL, flags) != 0) {
        state.store(.disabled, .release);
        return false;
    }
    return written >= 0 and @as(usize, @intCast(written)) == bytes.len;
}

pub fn write(bytes: []const u8) bool {
    if (!tryAcquire()) return false;
    defer release();
    return writeHeld(bytes);
}

pub fn writeReceipt(bytes: []const u8) bool {
    var position: usize = 0;
    writeReceiptBytes(bytes, &position) catch return false;
    return true;
}

pub fn writeReceiptBytes(bytes: []const u8, position: *usize) !void {
    if (position.* == bytes.len) return;
    if (!tryAcquire()) return error.StderrReceiptUnavailable;
    defer release();
    while (position.* < bytes.len) position.* += try writeSomeTo(2, bytes[position.*..]);
}

fn writeAllTo(fd: c_int, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) at += writeSomeTo(fd, bytes[at..]) catch return false;
    return true;
}

fn writeSomeTo(fd: c_int, bytes: []const u8) !usize {
    while (true) {
        const written = std.c.write(fd, bytes.ptr, bytes.len);
        if (written > 0) return @intCast(written);
        if (written == 0) return error.ReceiptWriteFailed;
        switch (std.posix.errno(written)) {
            .INTR => {},
            .AGAIN => {
                var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&fds, -1) catch return error.ReceiptWriteFailed;
            },
            else => return error.ReceiptWriteFailed,
        }
    }
}

pub fn writeReceiptFile(io: std.Io, file: std.Io.File, length: u64, position: *u64) !void {
    if (!tryAcquire()) return error.StderrReceiptUnavailable;
    defer release();
    return writeReceiptFileTo(io, file, length, position, 2, null);
}

fn writeReceiptFileTo(io: std.Io, file: std.Io.File, length: u64, position: *u64, fd: c_int, fail_after: ?u64) !void {
    var buffer: [4096]u8 = undefined;
    while (position.* < length) {
        if (fail_after) |cut| if (position.* >= cut) return error.InjectedReceiptWriteFailure;
        const limit = @min(length, fail_after orelse length);
        const wanted: usize = @intCast(@min(buffer.len, limit - position.*));
        const count = try file.readPositional(io, &.{buffer[0..wanted]}, position.*);
        if (count == 0) return error.ReceiptReadFailed;
        var at: usize = 0;
        while (at < count) {
            const written = try writeSomeTo(fd, buffer[at..count]);
            position.* += written;
            at += written;
        }
    }
}

test "a receipt larger than the terminal takes at once arrives whole" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    try std.testing.expect(std.c.fcntl(fds[1], std.c.F.SETFL, std.c.fcntl(fds[1], std.c.F.GETFL) | nonblock) == 0);
    var receipt: [1 << 20]u8 = undefined;
    for (&receipt, 0..) |*byte, at| byte.* = @truncate(at *% 31);
    const Reader = struct {
        fn run(fd: c_int, into: []u8, got: *usize) void {
            while (true) {
                const n = std.c.read(fd, into[got.*..].ptr, into.len - got.*);
                if (n <= 0) return;
                got.* += @intCast(n);
            }
        }
    };
    const read = try std.testing.allocator.alloc(u8, receipt.len + 1);
    defer std.testing.allocator.free(read);
    var got: usize = 0;
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ fds[0], read, &got });
    const ok = writeAllTo(fds[1], &receipt);
    _ = std.c.close(fds[1]);
    reader.join();
    try std.testing.expect(ok);
    try std.testing.expectEqualSlices(u8, &receipt, read[0..got]);
}

pub noinline fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, format, args) catch return;
    _ = write(bytes);
}

pub fn diagnosticBytes(bytes: []const u8) void {
    _ = write(bytes);
}

pub fn diagnostic(comptime format: []const u8, args: anytype) void {
    print("\n" ++ format, args);
}

test "required receipt stream preserves exact partial progress excludes dirty tail and reports premature EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const source = try tmp.dir.createFile(io, "receipt", .{ .read = true });
    defer source.close(io);
    const receipt = "first diagnostic\nprivate recovery path\n";
    try source.writePositionalAll(io, receipt ++ "uncommitted dirty tail", 0);
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    var position: u64 = 0;
    try std.testing.expectError(error.InjectedReceiptWriteFailure, writeReceiptFileTo(io, source, receipt.len, &position, fds[1], 7));
    try std.testing.expectEqual(@as(u64, 7), position);
    try writeReceiptFileTo(io, source, receipt.len, &position, fds[1], null);
    try std.testing.expectEqual(@as(u64, receipt.len), position);
    try writeReceiptFileTo(io, source, receipt.len, &position, fds[1], null);
    _ = std.c.close(fds[1]);
    var bytes: [128]u8 = undefined;
    const count = std.c.read(fds[0], &bytes, bytes.len);
    try std.testing.expect(count >= 0);
    try std.testing.expectEqualStrings(receipt, bytes[0..@intCast(count)]);
    position = 0;
    try std.testing.expectError(error.ReceiptWriteFailed, writeReceiptFileTo(io, source, receipt.len, &position, -1, null));
    try std.testing.expectEqual(@as(u64, 0), position);
    try source.setLength(io, 0);
    try std.testing.expectError(error.ReceiptReadFailed, writeReceiptFileTo(io, source, receipt.len, &position, -1, null));
    try std.testing.expectEqual(@as(u64, 0), position);
}
