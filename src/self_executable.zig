//! The running build's own executable, pinned once when the process starts.
//!
//! Every place that launches "this same build again" (the upgrade's Host
//! coordinator, a Host child, the macOS malloc re-exec, the Bash PATH entry)
//! reads it here. `std.process.executablePath` must not be called for that:
//! on macOS it re-resolves the launch path on every call, and that path is
//! usually the `~/.local/bin/rui` symlink an upgrade repoints mid-run. A call
//! made after publication then names the newly installed build, so an older
//! client would hand its private, same-build pipes to a newer program. Linux
//! reads `/proc/self/exe`, which already names the running file, so the bug
//! only ever showed on a Mac.

const std = @import("std");
const builtin = @import("builtin");

var buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
var pinned: ?[:0]const u8 = null;

/// Resolves the running executable to its real file. `cli.main` calls it
/// first, before any thread starts or any upgrade can publish a build.
pub fn pin(io: std.Io) !void {
    if (pinned != null) return;
    const length = try std.process.executablePath(io, buffer[0 .. buffer.len - 1]);
    buffer[length] = 0;
    pinned = buffer[0..length :0];
}

/// The file this process was started from, as resolved at `pin`.
pub fn path(io: std.Io) ![:0]const u8 {
    if (pinned) |value| return value;
    // Test binaries have no `cli.main`; production always pinned at start.
    if (!builtin.is_test) unreachable;
    try pin(io);
    return pinned.?;
}

test "the pinned path names the running file, not a later resolution" {
    const io = std.testing.io;
    const first = try path(io);
    try std.testing.expect(std.fs.path.isAbsolute(first));
    var now: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try std.process.executablePath(io, &now);
    try std.testing.expectEqualStrings(now[0..length], first);
    // Repeated reads return the same pinned bytes without resolving again.
    try std.testing.expectEqual(first.ptr, (try path(io)).ptr);
}

test "a build launched through a symlink keeps naming itself after the symlink moves" {
    // The child is this test binary running only this test. It pins as cli.main
    // does, then reports the pin after the parent repointed the link it was
    // launched through, the way an upgrade repoints ~/.local/bin/rui.
    if (std.c.getenv("RUI_SELF_EXECUTABLE_FIXTURE")) |marker| {
        if (std.mem.eql(u8, std.mem.span(marker), "pin")) {
            const own = path(std.testing.io) catch std.c._exit(1);
            if (std.c.write(1, "R", 1) != 1) std.c._exit(1);
            var release: [1]u8 = undefined;
            if (std.c.read(0, &release, 1) != 0) std.c._exit(1);
            if (std.c.write(1, own.ptr, own.len) != @as(isize, @intCast(own.len))) std.c._exit(1);
            std.c._exit(0);
        }
    }
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const running = try path(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, running, "rui", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "other", .data = "" });
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const link = try std.fs.path.join(allocator, &.{ directory, "rui" });
    defer allocator.free(link);
    var environment: std.process.Environ.Map = .init(allocator);
    defer environment.deinit();
    try environment.put("RUI_SELF_EXECUTABLE_FIXTURE", "pin");
    var child = try std.process.spawn(io, .{
        .argv = &.{ link, "--listen=-" },
        .environ_map = &environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer if (child.id != null) {
        if (child.stdin) |input| input.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
    };
    var read_buffer: [std.Io.Dir.max_path_bytes + 256]u8 = undefined;
    var write_buffer: [64]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &read_buffer);
    var writer = child.stdin.?.writerStreaming(io, &write_buffer);
    const protocol: std.zig.Client = .{ .in = &reader.interface, .out = &writer.interface };
    const hello = try protocol.receiveMessage();
    try std.testing.expectEqual(std.zig.Server.Message.Tag.zig_version, hello.tag);
    try reader.interface.discardAll(hello.bytes_len);
    const test_index: u32 = for (builtin.test_functions, 0..) |test_function, index| {
        if (std.mem.endsWith(u8, test_function.name, "test.a build launched through a symlink keeps naming itself after the symlink moves")) break @intCast(index);
    } else return error.SelfExecutableFixtureTestMissing;
    try protocol.serveRunTest(test_index);
    const entered = try protocol.receiveMessage();
    try std.testing.expectEqual(std.zig.Server.Message.Tag.test_started, entered.tag);
    try std.testing.expectEqual(@as(u8, 'R'), try reader.interface.takeByte());
    try tmp.dir.deleteFile(io, "rui");
    try tmp.dir.symLink(io, "other", "rui", .{});
    child.stdin.?.close(io);
    child.stdin = null;
    const reported = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(reported);
    try std.testing.expect((try child.wait(io)).success());
    try std.testing.expectEqualStrings(running, reported);
}
