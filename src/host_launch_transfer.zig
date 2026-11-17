//! One nonblocking input pump, shared by detached launch and checked-frame
//! forwarding. Every step drains BOTH bounded diagnostic readers before one
//! partial write; callers retain their existing readiness/deadline policies.
const std = @import("std");
const frame = @import("host_launch_frame.zig");
extern fn rui_launch_input_pipe(*c_int, *c_int) c_int;
extern fn rui_write_launch_input(c_int, [*]const u8, usize) c_long;

pub const Ops = struct {
    context: ?*anyopaque = null,
    read: *const fn (?*anyopaque, c_int, []u8) isize = nativeRead,
    write: *const fn (?*anyopaque, c_int, []const u8) isize = nativeWrite,
    pub fn nativeRead(_: ?*anyopaque, fd: c_int, bytes: []u8) isize {
        const count = std.c.read(fd, bytes.ptr, bytes.len);
        return if (count >= 0) count else -@as(isize, @intFromEnum(std.posix.errno(count)));
    }
    fn nativeWrite(_: ?*anyopaque, fd: c_int, bytes: []const u8) isize {
        return @intCast(rui_write_launch_input(fd, bytes.ptr, bytes.len));
    }
};
pub const Pipe = struct {
    reader: c_int = -1,
    writer: c_int = -1,
    pub fn init() !Pipe {
        var pipe: Pipe = .{};
        if (rui_launch_input_pipe(&pipe.reader, &pipe.writer) != 0) return error.SystemResources;
        return pipe;
    }
    pub fn close(self: *Pipe) void {
        if (self.reader >= 0) _ = std.c.close(self.reader);
        if (self.writer >= 0) _ = std.c.close(self.writer);
        self.* = .{};
    }
};
pub fn nonblocking(fd: c_int) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblock: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.SystemResources;
}
pub const Reader = struct { fd: c_int, buffer: []u8 };
pub const Step = struct { counts: [2]usize = .{ 0, 0 }, closed: [2]bool = .{ false, false }, progressed: bool = false };
pub const Transfer = struct {
    input: c_int,
    bytes: []const u8,
    offset: usize = 0,
    closed_early: bool = false,
    pub fn deinit(self: *Transfer) void {
        if (self.input >= 0) _ = std.c.close(self.input);
        self.input = -1;
    }
    pub fn step(self: *Transfer, ops: Ops, readers: [2]Reader) !Step {
        var result: Step = .{};
        for (readers, 0..) |reader, i| {
            if (reader.buffer.len == 0 or reader.fd < 0) continue;
            const count = ops.read(ops.context, reader.fd, reader.buffer);
            if (count >= 0) {
                result.counts[i] = @intCast(count);
                result.closed[i] = count == 0;
                result.progressed = result.progressed or count > 0;
            } else if (-count != @intFromEnum(std.posix.E.AGAIN) and -count != @intFromEnum(std.posix.E.INTR)) return error.InputOutput;
        }
        if (self.input >= 0 and self.offset < self.bytes.len) {
            const count = ops.write(ops.context, self.input, self.bytes[self.offset..][0..@min(16384, self.bytes.len - self.offset)]);
            if (count > 0) {
                self.offset += @intCast(count);
                result.progressed = true;
            } else if (count == 0 or -count == @intFromEnum(std.posix.E.PIPE)) {
                self.closed_early = true;
                self.deinit();
            } else if (-count != @intFromEnum(std.posix.E.AGAIN) and -count != @intFromEnum(std.posix.E.INTR)) return error.InputOutput;
        }
        if (self.input >= 0 and self.offset == self.bytes.len) self.deinit();
        return result;
    }
};

/// Consume and close the anonymous descriptor before any service/workload can
/// inherit it. No public source lookup or resolved value enters this decoder.
pub fn readFrame(gpa: std.mem.Allocator, io: std.Io, fd: c_int) !frame.Owned {
    defer _ = std.c.close(fd);
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.SettingsInvalid;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var wiping: @import("secret_value.zig").WipingAllocator = .{ .backing = gpa };
    const private = wiping.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    errdefer {
        std.crypto.secureZero(u8, bytes.allocatedSlice());
        bytes.deinit(private);
    }
    var buffer: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    while (true) {
        const n = try file.readStreaming(io, &.{&buffer});
        if (n == 0) break;
        if (n > frame.max_bytes -| bytes.items.len) return error.SettingsInvalid;
        try bytes.appendSlice(private, buffer[0..n]);
    }
    _ = try frame.inspect(bytes.items);
    return .{ .bytes = try bytes.toOwnedSlice(private) };
}
