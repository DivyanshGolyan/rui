const std = @import("std");
const stderr = @import("stderr.zig");
const c = @import("posix");
const DiagnosticFiles = @import("DiagnosticFiles.zig");

const Self = @This();
pub const default_cap_bytes: u64 = 128 * 1024 * 1024;

io: std.Io,
dir: std.Io.Dir,
file: ?std.Io.File = null,
files: DiagnosticFiles,
length: u64 = 0,
failure: ?anyerror = null,

/// The Store lease is held by the caller. Only this writer mutates diagnostic
/// files; a failure disables further writes without changing Host work.
pub fn open(io: std.Io, store_dir: std.Io.Dir, cap_bytes: u64) !Self {
    const files: DiagnosticFiles = try .init(cap_bytes);
    var dir = try store_dir.createDirPathOpen(io, "diagnostics", .{
        .permissions = .fromMode(0o700),
        .open_options = .{ .iterate = true, .follow_symlinks = false },
    });
    errdefer dir.close(io);
    try private(dir.handle, true);
    var self: Self = .{ .io = io, .dir = dir, .files = files };
    var iterator = dir.iterate();
    while (try iterator.next(io)) |item| {
        const id = DiagnosticFiles.fileNumber(item.name) orelse continue;
        var file = try dir.openFile(io, item.name, .{ .mode = .read_write, .follow_symlinks = false });
        defer file.close(io);
        try private(file.handle, false);
        try self.files.observe(id, try file.length(io));
    }
    if (try self.files.latest()) |latest| {
        var name: [64]u8 = undefined;
        self.file = try dir.openFile(io, try DiagnosticFiles.nameFor(&name, latest), .{
            .mode = .read_write,
            .follow_symlinks = false,
        });
        errdefer self.file.?.close(io);
        self.length = try repairTail(io, self.file.?);
    }
    return self;
}

pub fn close(self: *Self) void {
    if (self.file) |file| file.close(self.io);
    self.dir.close(self.io);
    self.* = undefined;
}

pub fn record(self: *Self, phase: []const u8, detail: []const u8) void {
    if (self.failure != null) return;
    self.write(phase, detail) catch |err| {
        self.failure = err;
        self.reportFailure();
    };
}

/// Retain the failure when readiness exclusion drops the initial notice.
pub fn reportFailure(self: *Self) void {
    if (self.failure) |err|
        stderr.print("rui: diagnostic writer unavailable ({s}); no Host work was changed\n", .{@errorName(err)});
}

fn write(self: *Self, phase: []const u8, detail: []const u8) !void {
    var bytes: [DiagnosticFiles.max_record_bytes]u8 = undefined;
    const time = std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds;
    // The caller supplies only trusted phase and error names, never payloads.
    const record_bytes = std.fmt.bufPrint(&bytes, "{{\"time_ns\":{d},\"classification\":\"startup\",\"phase\":\"{s}\",\"detail\":\"{s}\"}}\n", .{ time, phase, detail }) catch return error.DiagnosticRecordTooLong;
    if (self.files.needsRotation(if (self.file != null) self.length else null, record_bytes.len)) try self.rotate();
    try self.file.?.writePositionalAll(self.io, record_bytes, self.length);
    self.length += record_bytes.len;
}

fn rotate(self: *Self) !void {
    if (self.file) |file| {
        file.close(self.io);
        self.file = null;
    }
    if (self.files.retiring()) |oldest| {
        var name: [64]u8 = undefined;
        try self.dir.deleteFile(self.io, try DiagnosticFiles.nameFor(&name, oldest));
        var lowest: ?u64 = null;
        var iterator = self.dir.iterate();
        while (try iterator.next(self.io)) |item| {
            if (DiagnosticFiles.fileNumber(item.name)) |id| lowest = @min(lowest orelse id, id);
        }
        self.files.retired(lowest);
    }
    var name: [64]u8 = undefined;
    self.file = try self.dir.createFile(self.io, try DiagnosticFiles.nameFor(&name, try self.files.rotation()), .{
        .read = true,
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    self.files.rotated();
    self.length = 0;
}

fn repairTail(io: std.Io, file: std.Io.File) !u64 {
    const length = try file.length(io);
    var tail: [DiagnosticFiles.max_record_bytes]u8 = undefined;
    const size: usize = @intCast(@min(length, tail.len));
    if (try file.readPositionalAll(io, tail[0..size], length - size) != size) return error.InvalidDiagnosticFile;
    const repaired = try DiagnosticFiles.repairedLength(length, tail[0..size]);
    if (repaired != length) try file.setLength(io, repaired);
    return repaired;
}

fn private(handle: std.posix.fd_t, directory: bool) !void {
    var stat: c.struct_stat = undefined;
    if (c.fstat(handle, &stat) != 0) return error.DiagnosticStatFailed;
    if (stat.st_uid != c.geteuid() or stat.st_mode & 0o077 != 0) return error.InsecureDiagnostics;
    if (directory and stat.st_mode & c.S_IFMT != c.S_IFDIR) return error.InsecureDiagnostics;
    if (!directory and stat.st_mode & c.S_IFMT != c.S_IFREG) return error.InsecureDiagnostics;
}

test "startup diagnostics rotate before growth, repair tails and retain failures" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try open(io, tmp.dir, 16 * 4096);
    defer writer.close();
    const long_detail = @as([3900]u8, @splat('x'));
    for (0..17) |_| writer.record("ready", &long_detail);
    try std.testing.expectEqual(null, writer.failure);
    try std.testing.expectEqual(@as(usize, 16), writer.files.count);
    try std.testing.expectEqual(@as(u64, 2), writer.files.oldest);
    var removed: [64]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, writer.dir.statFile(io, try DiagnosticFiles.nameFor(&removed, 1), .{}));

    const complete = writer.length;
    try writer.file.?.writePositionalAll(io, "partial", complete);
    writer.close();
    writer = try open(io, tmp.dir, 16 * 4096);
    try std.testing.expectEqual(complete, writer.length);
    try std.testing.expectEqual(complete, try writer.file.?.length(io));

    var oldest: [64]u8 = undefined;
    const target = try DiagnosticFiles.nameFor(&oldest, writer.files.oldest);
    try writer.dir.deleteFile(io, target);
    try writer.dir.createDir(io, target, .fromMode(0o700));
    writer.record("ready", &long_detail);
    try std.testing.expect(writer.failure != null);
    try std.testing.expectEqual(@as(usize, 16), writer.files.count);
    try std.testing.expectEqual(@as(u64, 18), writer.files.next);
}
