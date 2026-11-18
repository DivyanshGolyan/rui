//! One nonblocking input pump, shared by detached launch and checked-handoff
//! forwarding. Every step drains BOTH bounded diagnostic readers before one
//! partial write; callers retain their existing readiness/deadline policies.
const std = @import("std");
const settings_handoff = @import("host_settings_handoff.zig");
extern fn rui_launch_input_pipe(*c_int, *c_int) c_int;
extern fn rui_write_launch_input(c_int, [*]const u8, usize) c_long;

pub const Ops = struct {
    context: ?*anyopaque = null,
    read: *const fn (?*anyopaque, c_int, []u8) isize = nativeRead,
    write: *const fn (?*anyopaque, c_int, []const u8) isize = nativeWrite,
    pub fn nativeRead(_: ?*anyopaque, fd: c_int, bytes: []u8) isize {
        const count = std.c.read(fd, bytes.ptr, bytes.len);
        return if (count >= 0) count else -@as(isize, @backingInt(std.posix.errno(count)));
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
            } else if (-count != @backingInt(std.posix.E.AGAIN) and -count != @backingInt(std.posix.E.INTR)) return error.InputOutput;
        }
        if (self.input >= 0 and self.offset < self.bytes.len) {
            const count = ops.write(ops.context, self.input, self.bytes[self.offset..][0..@min(16384, self.bytes.len - self.offset)]);
            if (count > 0) {
                self.offset += @intCast(count);
                result.progressed = true;
            } else if (count == 0 or -count == @backingInt(std.posix.E.PIPE)) {
                self.closed_early = true;
                self.deinit();
            } else if (-count != @backingInt(std.posix.E.AGAIN) and -count != @backingInt(std.posix.E.INTR)) return error.InputOutput;
        }
        if (self.input >= 0 and self.offset == self.bytes.len) self.deinit();
        return result;
    }
};

/// Consume and close the anonymous descriptor before any service/workload can
/// inherit it. No public source lookup or resolved value enters this decoder.
pub fn readHandoff(gpa: std.mem.Allocator, io: std.Io, fd: c_int) !settings_handoff.Owned {
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
        const n = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        if (n > settings_handoff.max_bytes -| bytes.items.len) return error.SettingsInvalid;
        try bytes.appendSlice(private, buffer[0..n]);
    }
    _ = try settings_handoff.inspect(bytes.items);
    return .{ .bytes = try bytes.toOwnedSlice(private) };
}

test "frozen launch input consumes EOF and closes valid malformed and truncated descriptors" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(@import("host_settings.zig").Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: @import("start_report.zig").Failure = undefined;
    var owned = try settings_handoff.freeze(gpa, "/frozen-input", settings, .automatic, .none, &failure);
    defer owned.deinit(gpa);
    for ([_][]const u8{ owned.bytes, owned.bytes[0 .. owned.bytes.len - 1], "not a frame" }, 0..) |bytes, i| {
        var pipe = try Pipe.init();
        defer pipe.close();
        try std.testing.expectEqual(@as(c_long, @intCast(bytes.len)), rui_write_launch_input(pipe.writer, bytes.ptr, bytes.len));
        _ = std.c.close(pipe.writer);
        pipe.writer = -1;
        const fd = pipe.reader;
        pipe.reader = -1; // readHandoff owns and closes it on every exit.
        if (i == 0) {
            var read = try readHandoff(gpa, std.testing.io, fd);
            defer read.deinit(gpa);
            try std.testing.expectEqualSlices(u8, owned.bytes, read.bytes);
        } else try std.testing.expectError(error.SettingsInvalid, readHandoff(gpa, std.testing.io, fd));
        try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) < 0);
    }
}

test "frozen launch transfer drains both channels through partial interrupted blocked and closed writes" {
    const Fixture = struct {
        calls: usize = 0,
        reads: [2]usize = .{ 0, 0 },
        sent: [4]u8 = undefined,
        length: usize = 0,
        fn read(context: ?*anyopaque, fd: c_int, buffer: []u8) isize {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const index: usize = if (fd == 11) 0 else 1;
            self.reads[index] += 1;
            buffer[0] = @intCast(self.reads[index]);
            return 1;
        }
        fn write(context: ?*anyopaque, _: c_int, bytes: []const u8) isize {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            defer self.calls += 1;
            switch (self.calls) {
                0 => return -@as(isize, @backingInt(std.posix.E.INTR)),
                1 => return -@as(isize, @backingInt(std.posix.E.AGAIN)),
                2, 3 => {
                    self.sent[self.length] = bytes[0];
                    self.length += 1;
                    return 1;
                },
                else => return -@as(isize, @backingInt(std.posix.E.PIPE)),
            }
        }
    };
    var fixture: Fixture = .{};
    var pipe = try Pipe.init();
    defer pipe.close();
    var transfer: Transfer = .{ .input = pipe.writer, .bytes = "abcd" };
    pipe.writer = -1;
    defer transfer.deinit();
    var a: [1]u8 = undefined;
    var b: [1]u8 = undefined;
    for (0..5) |_| {
        const step_result = try transfer.step(.{ .context = &fixture, .read = Fixture.read, .write = Fixture.write }, .{
            .{ .fd = 11, .buffer = &a }, .{ .fd = 12, .buffer = &b },
        });
        try std.testing.expectEqual([2]usize{ 1, 1 }, step_result.counts);
    }
    try std.testing.expectEqual([2]usize{ 5, 5 }, fixture.reads);
    try std.testing.expectEqualStrings("ab", fixture.sent[0..fixture.length]);
    try std.testing.expectEqual(@as(usize, 2), transfer.offset);
    try std.testing.expect(transfer.closed_early);
    try std.testing.expectEqual(@as(c_int, -1), transfer.input);
}

test "frozen launch native closed reader reports EPIPE without terminating the caller" {
    var pipe = try Pipe.init();
    defer pipe.close();
    _ = std.c.close(pipe.reader);
    pipe.reader = -1;
    try std.testing.expectEqual(-@as(c_long, @backingInt(std.posix.E.PIPE)), rui_write_launch_input(pipe.writer, "input", 5));
}
