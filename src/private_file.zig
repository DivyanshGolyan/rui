//! Private local-file admission and bounded reads, shared by saved settings
//! and credentials. These rules do not interpret the bytes or select a provider.
const std = @import("std");
const c = @import("posix");

/// Admit the parent and final component of an absolute private-file path.
/// The returned directory is owned by the caller; it must be closed.
pub fn openParent(io: std.Io, path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.PathMustBeAbsolute;
    const basename = std.fs.path.basename(path);
    if (basename.len == 0 or basename.len > std.Io.Dir.max_name_bytes or
        std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, ".."))
        return error.InvalidCredentialPath;
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidCredentialPath;
    // Follow aliases above the parent (including macOS /var -> /private/var),
    // but never a symlink standing in for the private parent itself.
    var parent = try std.Io.Dir.openDirAbsolute(io, parent_path, .{ .iterate = true, .follow_symlinks = false });
    errdefer parent.close(io);
    try validateDirectory(io, parent);
    return parent;
}

/// Null means absent. Returned bytes borrow buffer and must be wiped by caller.
pub fn read(io: std.Io, path: []const u8, buffer: []u8) !?[]u8 {
    var parent = openParent(io, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer parent.close(io);
    return readAt(io, parent, std.fs.path.basename(path), buffer) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Read an admitted parent's private regular file. The file must be shorter
/// than buffer; an error wipes every byte the read could have written.
pub fn readAt(io: std.Io, parent: std.Io.Dir, name: []const u8, buffer: []u8) ![]u8 {
    // Reject a private FIFO after opening it without waiting for a writer.
    const file: std.Io.File = .{ .handle = try std.posix.openat(parent.handle, name, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0), .flags = .{ .nonblocking = true } };
    defer file.close(io);
    try validateFile(io, file);
    const stat = try file.stat(io);
    if (stat.size >= buffer.len) return error.CredentialFileTooLarge;
    // The read writes at most this prefix; the rest stays untouched.
    const bytes = buffer[0..@intCast(stat.size + 1)];
    errdefer std.crypto.secureZero(u8, bytes);
    const count = try file.readPositionalAll(io, bytes, 0);
    if (count != stat.size) return error.CredentialFileChanged;
    std.crypto.secureZero(u8, bytes[count..]);
    return bytes[0..count];
}

pub fn validateDirectory(io: std.Io, dir: std.Io.Dir) !void {
    const stat = try dir.stat(io);
    if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0)
        return error.InsecureCredentialDirectory;
    try validateOwner(dir.handle);
}

pub fn validateFile(io: std.Io, file: std.Io.File) !void {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0)
        return error.InsecureCredentialFile;
    try validateOwner(file.handle);
}

fn validateOwner(handle: anytype) !void {
    if (!@import("os/os.zig").supported) return error.UnsupportedPlatform;
    var stat: c.struct_stat = undefined;
    if (c.fstat(handle, &stat) != 0) return error.StatFailed;
    if (stat.st_uid != c.geteuid()) return error.NotOwnedByCurrentUser;
}
