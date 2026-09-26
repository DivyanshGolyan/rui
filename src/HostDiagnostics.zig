const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const Self = @This();
pub const default_cap_bytes: u64 = 128 * 1024 * 1024;
const max_files = 16;
const max_record_bytes = 4096;

io: std.Io,
dir: std.Io.Dir,
file: ?std.Io.File = null,
next: u64 = 1,
oldest: u64 = 0,
count: usize = 0,
length: u64 = 0,
file_cap: u64,
disabled: bool = false,

/// The Store lease is held by the caller. Only this writer mutates diagnostic
/// files; a failure disables further writes without changing Host work.
pub fn open(io: std.Io, store_dir: std.Io.Dir, cap_bytes: u64) !Self {
    const file_cap = cap_bytes / max_files;
    if (file_cap < max_record_bytes) return error.InvalidDiagnosticCap;
    var dir = try store_dir.createDirPathOpen(io, "diagnostics", .{
        .permissions = .fromMode(0o700),
        .open_options = .{ .iterate = true, .follow_symlinks = false },
    });
    errdefer dir.close(io);
    try private(dir.handle, true);
    var self: Self = .{ .io = io, .dir = dir, .file_cap = file_cap };
    var iterator = dir.iterate();
    while (try iterator.next(io)) |item| {
        const id = fileNumber(item.name) orelse continue;
        var file = try dir.openFile(io, item.name, .{ .mode = .read_write, .follow_symlinks = false });
        defer file.close(io);
        try private(file.handle, false);
        if ((try file.length(io)) > file_cap) return error.InvalidDiagnosticFile;
        self.count += 1;
        if (self.oldest == 0 or id < self.oldest) self.oldest = id;
        if (id >= self.next) self.next = std.math.add(u64, id, 1) catch return error.DiagnosticSequenceExhausted;
    }
    if (self.count > max_files) return error.InvalidDiagnosticFile;
    if (self.count != 0) {
        const latest = self.next - 1;
        var name: [64]u8 = undefined;
        self.file = try dir.openFile(io, try nameFor(&name, latest), .{
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
    if (self.disabled) return;
    self.write(phase, detail) catch |err| {
        self.disabled = true;
        std.debug.print("rui: diagnostic writer unavailable ({s}); no Host work was changed\n", .{@errorName(err)});
    };
}

fn write(self: *Self, phase: []const u8, detail: []const u8) !void {
    var bytes: [max_record_bytes]u8 = undefined;
    const time = std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds;
    // The caller supplies only trusted phase and error names, never payloads.
    const record_bytes = std.fmt.bufPrint(&bytes, "{{\"time_ns\":{d},\"classification\":\"startup\",\"phase\":\"{s}\",\"detail\":\"{s}\"}}\n", .{ time, phase, detail }) catch return error.DiagnosticRecordTooLong;
    if (self.file == null or self.length + record_bytes.len > self.file_cap) try self.rotate();
    try self.file.?.writePositionalAll(self.io, record_bytes, self.length);
    self.length += record_bytes.len;
}

fn rotate(self: *Self) !void {
    if (self.file) |file| {
        file.close(self.io);
        self.file = null;
    }
    if (self.count == max_files) {
        // Delete before growth; a failed deletion never claims reclaimed space.
        var name: [64]u8 = undefined;
        try self.dir.deleteFile(self.io, try nameFor(&name, self.oldest));
        self.count -= 1;
        var lowest: u64 = self.next;
        var iterator = self.dir.iterate();
        while (try iterator.next(self.io)) |item| {
            if (fileNumber(item.name)) |id| lowest = @min(lowest, id);
        }
        self.oldest = lowest;
    }
    if (self.next == std.math.maxInt(u64)) return error.DiagnosticSequenceExhausted;
    var name: [64]u8 = undefined;
    self.file = try self.dir.createFile(self.io, try nameFor(&name, self.next), .{
        .read = true,
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    if (self.count == 0) self.oldest = self.next;
    self.next = try std.math.add(u64, self.next, 1);
    self.count += 1;
    self.length = 0;
}

fn repairTail(io: std.Io, file: std.Io.File) !u64 {
    const length = try file.length(io);
    if (length == 0) return 0;
    var tail: [max_record_bytes]u8 = undefined;
    const size: usize = @intCast(@min(length, tail.len));
    if (try file.readPositionalAll(io, tail[0..size], length - size) != size) return error.InvalidDiagnosticFile;
    if (tail[size - 1] == '\n') return length;
    const last = std.mem.lastIndexOfScalar(u8, tail[0..size], '\n');
    const repaired = length - size + if (last) |index| index + 1 else 0;
    if (last == null and length > size) return error.InvalidDiagnosticFile;
    try file.setLength(io, repaired);
    return repaired;
}

fn nameFor(buffer: []u8, id: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "host-{d}.jsonl", .{id});
}

fn fileNumber(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "host-") or !std.mem.endsWith(u8, name, ".jsonl")) return null;
    const id = std.fmt.parseInt(u64, name[5 .. name.len - 6], 10) catch return null;
    var canonical: [64]u8 = undefined;
    if (id == 0 or !std.mem.eql(u8, name, nameFor(&canonical, id) catch return null)) return null;
    return id;
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
    const long_detail = [_]u8{'x'} ** 3900;
    for (0..17) |_| writer.record("ready", &long_detail);
    try std.testing.expect(!writer.disabled);
    try std.testing.expectEqual(@as(usize, 16), writer.count);
    try std.testing.expectEqual(@as(u64, 2), writer.oldest);
    var removed: [64]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, writer.dir.statFile(io, try nameFor(&removed, 1), .{}));

    const complete = writer.length;
    try writer.file.?.writePositionalAll(io, "partial", complete);
    writer.close();
    writer = try open(io, tmp.dir, 16 * 4096);
    try std.testing.expectEqual(complete, writer.length);
    try std.testing.expectEqual(complete, try writer.file.?.length(io));

    var oldest: [64]u8 = undefined;
    const target = try nameFor(&oldest, writer.oldest);
    try writer.dir.deleteFile(io, target);
    try writer.dir.createDir(io, target, .fromMode(0o700));
    writer.record("ready", &long_detail);
    try std.testing.expect(writer.disabled);
    try std.testing.expectEqual(@as(usize, 16), writer.count);
    try std.testing.expectEqual(@as(u64, 18), writer.next);
}
