//! Acquire a pinned regular file without opening a special file for I/O.
const std = @import("std");

/// A safe same-object regular-file opener is currently available through Linux's
/// O_PATH and procfs. Other platforms fail before acquiring any source handle.
pub const available = @import("builtin").os.tag == .linux;

/// Owned handle. O_PATH only acquires a reference, including for a device or
/// FIFO. Reopening its procfs descriptor after checking its immutable inode
/// kind cannot race with replacement of the caller's pathname.
pub fn open(io: std.Io, workspace: []const u8, path: []const u8) !std.Io.File {
    return if (available) openLinux(io, workspace, path) else error.SafeImageReadUnsupported;
}

fn openLinux(io: std.Io, workspace: []const u8, path: []const u8) !std.Io.File {
    var directory: ?std.Io.Dir = null;
    defer if (directory) |dir| dir.close(io);
    const parent = if (std.fs.path.isAbsolute(path)) std.posix.AT.FDCWD else relative: {
        directory = try std.Io.Dir.openDirAbsolute(io, workspace, .{});
        break :relative directory.?.handle;
    };
    const pinned: std.Io.File = .{ .handle = try std.posix.openat(parent, path, .{ .PATH = true, .CLOEXEC = true }, 0), .flags = .{ .nonblocking = true } };
    defer pinned.close(io);
    if ((try pinned.stat(io)).kind != .file) return error.ImageNotRegular;
    var descriptor: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&descriptor, "/proc/self/fd/{d}", .{pinned.handle});
    const source: std.Io.File = .{ .handle = try std.posix.openat(std.posix.AT.FDCWD, name, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0), .flags = .{ .nonblocking = true } };
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
}
