//! Acquire a regular image source. Linux pins the inode before opening for I/O.
//! macOS rejects special paths before opening and checks the opened handle;
//! a device swapped into the path between stat and open can still be opened,
//! but its handle is rejected before any read.
const std = @import("std");

const builtin = @import("builtin");

pub const available = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

/// Return an owned regular-file handle resolved relative to the frozen Workspace
/// or directly by absolute path. Unsupported platforms acquire no handles.
pub fn open(io: std.Io, workspace: []const u8, path: []const u8) !std.Io.File {
    if (!available) return error.SafeImageReadUnsupported;
    var directory: ?std.Io.Dir = null;
    defer if (directory) |dir| dir.close(io);
    const parent = if (std.fs.path.isAbsolute(path)) std.Io.Dir.cwd() else relative: {
        directory = try std.Io.Dir.openDirAbsolute(io, workspace, .{});
        break :relative directory.?;
    };
    return switch (builtin.os.tag) {
        .linux => openLinux(io, parent, path),
        .macos => openPortable(io, parent, path),
        else => unreachable,
    };
}

/// O_PATH pins an inode without opening it for I/O. Reopening its procfs
/// descriptor after checking its immutable kind avoids pathname replacement.
fn openLinux(io: std.Io, parent: std.Io.Dir, path: []const u8) !std.Io.File {
    const pinned: std.Io.File = .{ .handle = try std.posix.openat(parent.handle, path, .{ .PATH = true, .CLOEXEC = true }, 0), .flags = .{ .nonblocking = true } };
    defer pinned.close(io);
    if ((try pinned.stat(io)).kind != .file) return error.ImageNotRegular;
    var descriptor: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&descriptor, "/proc/self/fd/{d}", .{pinned.handle});
    const source: std.Io.File = .{ .handle = try std.posix.openat(std.posix.AT.FDCWD, name, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0), .flags = .{ .nonblocking = true } };
    errdefer source.close(io);
    if ((try source.stat(io)).kind != .file) return error.ImageNotRegular;
    return source;
}

/// The path check rejects existing special files without opening them. The
/// handle check rejects a replacement before reading; NONBLOCK prevents a
/// substituted FIFO from waiting for a writer. Device-open side effects during
/// the stat/open race remain possible on this portable path.
fn openPortable(io: std.Io, parent: std.Io.Dir, path: []const u8) !std.Io.File {
    if ((try parent.statFile(io, path, .{})).kind != .file) return error.ImageNotRegular;
    const source: std.Io.File = .{ .handle = try std.posix.openat(parent.handle, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0), .flags = .{ .nonblocking = true } };
    errdefer source.close(io);
    if ((try source.stat(io)).kind != .file) return error.ImageNotRegular;
    return source;
}

test "read_image regular acquisition rejects directories missing files and devices" {
    if (!available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    try std.testing.expectError(error.ImageNotRegular, open(std.testing.io, root, "."));
    try std.testing.expectError(error.FileNotFound, open(std.testing.io, root, "missing"));
    try std.testing.expectError(error.ImageNotRegular, open(std.testing.io, root, "/dev/null"));
    try std.testing.expectEqual(@as(c_int, 0), @import("posix").mkfifoat(tmp.dir.handle, "fifo", 0o600));
    try std.testing.expectError(error.ImageNotRegular, open(std.testing.io, root, "fifo"));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "regular", .data = "exact" });
    const file = try open(std.testing.io, root, "regular");
    defer file.close(std.testing.io);
    var absolute: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&absolute, "{s}/regular", .{root});
    const direct = try open(std.testing.io, "/missing-workspace", full_path);
    direct.close(std.testing.io);
    try tmp.dir.deleteFile(std.testing.io, "regular");
    var bytes: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try file.readPositionalAll(std.testing.io, &bytes, 0));
    try std.testing.expectEqualStrings("exact", &bytes);
    var fixture = try @import("../socket_fixture.zig").Directory.init();
    defer fixture.cleanup();
    var buffer: [@import("../socket_fixture.zig").max_path_bytes]u8 = undefined;
    const address = try fixture.address("image.sock", &buffer);
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    // Removing the pinned-kind check makes the Linux procfs reopen fail
    // instead of rejecting the socket at this assertion.
    try std.testing.expectError(error.ImageNotRegular, open(std.testing.io, fixture.root[0..fixture.root_len], "image.sock"));
}

test "read_image portable acquisition reads regular relative absolute and symlink paths" {
    if (!available) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "regular", .data = "exact" });
    try tmp.dir.symLink(io, "regular", "alias", .{});
    const file = try openPortable(io, tmp.dir, "alias");
    defer file.close(io);
    const descriptor_flags = std.c.fcntl(file.handle, std.c.F.GETFD);
    try std.testing.expect(descriptor_flags >= 0);
    try std.testing.expect(descriptor_flags & std.c.FD_CLOEXEC != 0);
    const status_flags = std.c.fcntl(file.handle, std.c.F.GETFL);
    try std.testing.expect(status_flags >= 0);
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    try std.testing.expectEqual(nonblock, status_flags & nonblock);
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absolute = path[0..try tmp.dir.realPathFile(io, "regular", &path)];
    const direct = try openPortable(io, .{ .handle = -1 }, absolute);
    direct.close(io);
    try tmp.dir.deleteFile(io, "regular");
    var bytes: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try file.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("exact", &bytes);
}

test "read_image portable acquisition rejects special and missing paths before open" {
    if (!available) return error.SkipZigTest;
    const io = std.testing.io;
    var fixture = try @import("../socket_fixture.zig").Directory.init();
    defer fixture.cleanup();
    try std.testing.expectError(error.ImageNotRegular, openPortable(io, fixture.dir, "."));
    try std.testing.expectError(error.FileNotFound, openPortable(io, fixture.dir, "missing"));
    try std.testing.expectError(error.ImageNotRegular, openPortable(io, fixture.dir, "/dev/null"));
    try std.testing.expectEqual(@as(c_int, 0), @import("posix").mkfifoat(fixture.dir.handle, "fifo", 0o600));
    try std.testing.expectError(error.ImageNotRegular, openPortable(io, fixture.dir, "fifo"));
    try fixture.dir.symLink(io, "fifo", "fifo-alias", .{});
    try std.testing.expectError(error.ImageNotRegular, openPortable(io, fixture.dir, "fifo-alias"));
    try fixture.dir.symLink(io, "missing", "dangling", .{});
    try std.testing.expectError(error.FileNotFound, openPortable(io, fixture.dir, "dangling"));
    var buffer: [@import("../socket_fixture.zig").max_path_bytes]u8 = undefined;
    const address = try fixture.address("image.sock", &buffer);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    // A socket cannot be opened as a file. Without the pre-open kind check,
    // openat fails instead of reporting ImageNotRegular at this assertion.
    try std.testing.expectError(error.ImageNotRegular, openPortable(io, fixture.dir, "image.sock"));
}

test "read_image portable acquisition rejects a FIFO substituted after stat and closes it" {
    if (!available) return error.SkipZigTest;
    const Boundary = struct {
        var descriptor: std.posix.fd_t = -1;

        fn statPath(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
            const stat = try std.testing.io.vtable.dirStatFile(userdata, dir, path, options);
            dir.rename("replacement", dir, path, std.testing.io) catch return error.Unexpected;
            return stat;
        }

        fn statHandle(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            descriptor = file.handle;
            return std.testing.io.vtable.fileStat(userdata, file);
        }
    };
    Boundary.descriptor = -1;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "regular", .data = "exact" });
    try std.testing.expectEqual(@as(c_int, 0), @import("posix").mkfifoat(tmp.dir.handle, "replacement", 0o600));
    var vtable = std.testing.io.vtable.*;
    vtable.dirStatFile = Boundary.statPath;
    vtable.fileStat = Boundary.statHandle;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.ImageNotRegular, openPortable(io, tmp.dir, "regular"));
    try std.testing.expect(Boundary.descriptor >= 0);
    try std.testing.expect(std.c.fcntl(Boundary.descriptor, std.c.F.GETFD) < 0);
}
