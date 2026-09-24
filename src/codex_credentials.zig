const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const io = std.Io.Threaded.global_single_threaded.io();

pub const max_account_id_bytes = 1024;
pub const max_token_bytes = 16 * 1024;
pub const max_file_bytes = 64 * 1024;

pub fn Bounded(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), value: []const u8) !void {
            if (value.len > capacity) return error.CredentialFieldTooLong;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const State = enum { ready, refresh_pending };

/// A complete credential value. It owns every returned slice; no pathname or
/// file buffer is borrowed. Callers should overwrite it after the final header
/// consumer releases its borrow.
pub const Record = struct {
    version: u32 = 3,
    generation: u64,
    account_id: Bounded(max_account_id_bytes),
    fedramp: bool = false,
    id_token: Bounded(max_token_bytes),
    access_token: Bounded(max_token_bytes),
    refresh_token: Bounded(max_token_bytes),
    expires_at: i64,
    refreshed_at: i64,
    state: State = .ready,
};

/// Holds the stable cross-process lock through the model launch decision.
/// The caller owns the returned record and must release this lease on every path.
pub const Lease = struct {
    owner: Owner,
    lock: std.Io.File,
    record: Record,

    pub fn release(self: *Lease) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&self.record));
        self.lock.close(io);
        self.owner.close();
        self.* = undefined;
    }
};

pub fn lease(path: []const u8) !Lease {
    var owner = try Owner.open(path);
    errdefer owner.close();
    const lock = try owner.acquireLock(.shared);
    errdefer lock.close(io);
    var record = try owner.readRecord();
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try owner.syncDirectory();
    if (record.state != .ready) return error.RefreshRequiresLogin;
    return .{ .owner = owner, .lock = lock, .record = record };
}

pub fn load(path: []const u8) !Record {
    var owner = try Owner.open(path);
    defer owner.close();
    const lock = try owner.acquireLock(.shared);
    defer lock.close(io);
    var record = try owner.readRecord();
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try owner.syncDirectory();
    return record;
}

/// `expected_generation == null` is an explicit login. It may replace an
/// existing login and advances its generation. A non-null value is a refresh
/// compare-and-swap and must preserve the account binding.
pub fn install(path: []const u8, record: *const Record, expected_generation: ?u64) !void {
    try validateRecord(record);
    if (record.state != .ready) return error.InstallMustBeReady;
    var owner = try Owner.open(path);
    defer owner.close();
    const lock = try owner.acquireLock(.exclusive);
    defer lock.close(io);

    var current = owner.readRecord() catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (current) |*old| std.crypto.secureZero(u8, std.mem.asBytes(old));
    var replacement = record.*;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&replacement));
    if (expected_generation) |expected| {
        const old = current orelse return error.GenerationMismatch;
        if (old.generation != expected or old.state != .refresh_pending)
            return error.GenerationMismatch;
        if (!std.mem.eql(u8, old.account_id.slice(), replacement.account_id.slice()))
            return error.AccountMismatch;
        replacement.generation = std.math.add(u64, expected, 1) catch return error.GenerationExhausted;
    } else {
        replacement.generation = if (current) |old|
            std.math.add(u64, old.generation, 1) catch return error.GenerationExhausted
        else
            1;
    }
    try owner.publish(&replacement);
}

/// Commits the refresh fence before any network refresh. A restart that sees
/// this state must require explicit login; it must not replay the refresh.
pub fn markRefreshPending(path: []const u8, expected_generation: u64) !void {
    var owner = try Owner.open(path);
    defer owner.close();
    const lock = try owner.acquireLock(.exclusive);
    defer lock.close(io);
    var record = try owner.readRecord();
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    if (record.generation != expected_generation or record.state != .ready)
        return error.GenerationMismatch;
    record.state = .refresh_pending;
    try owner.publish(&record);
}

const Owner = struct {
    parent: std.Io.Dir,
    name: [std.Io.Dir.max_name_bytes]u8,
    name_len: usize,

    fn open(path: []const u8) !Owner {
        if (!std.fs.path.isAbsolute(path)) return error.PathMustBeAbsolute;
        const basename = std.fs.path.basename(path);
        if (basename.len == 0 or basename.len > std.Io.Dir.max_name_bytes or
            std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, ".."))
            return error.InvalidCredentialPath;
        const parent_path = std.fs.path.dirname(path) orelse return error.InvalidCredentialPath;
        var parent = try openAbsoluteNoSymlinks(parent_path);
        errdefer parent.close(io);
        try validatePrivate(parent);
        var result: Owner = .{ .parent = parent, .name = undefined, .name_len = basename.len };
        @memcpy(result.name[0..basename.len], basename);
        return result;
    }

    fn close(self: *Owner) void {
        self.parent.close(io);
    }

    fn finalName(self: *const Owner) []const u8 {
        return self.name[0..self.name_len];
    }

    fn derivedName(self: *const Owner, suffix: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, ".{s}{s}", .{ self.finalName(), suffix });
    }

    fn acquireLock(self: *Owner, kind: std.Io.File.Lock) !std.Io.File {
        var buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const name = try self.derivedName(".lock", &buffer);
        const file = while (true) {
            break self.parent.openFile(io, name, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .lock = kind,
            }) catch |err| switch (err) {
                error.FileNotFound => self.parent.createFile(io, name, .{
                    .read = true,
                    .truncate = false,
                    .exclusive = true,
                    .lock = kind,
                    .permissions = .fromMode(0o600),
                }) catch |create_err| switch (create_err) {
                    // Another process won creation; open and lock its stable inode.
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                },
                else => return err,
            };
        };
        errdefer file.close(io);
        try validatePrivateFile(file);
        return file;
    }

    fn readRecord(self: *Owner) !Record {
        const file = try self.parent.openFile(io, self.finalName(), .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer file.close(io);
        try validatePrivateFile(file);
        const stat = try file.stat(io);
        if (stat.size > max_file_bytes) return error.CredentialFileTooLarge;
        var bytes: [max_file_bytes + 1]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const count = try file.readPositionalAll(io, bytes[0..@intCast(stat.size + 1)], 0);
        if (count != stat.size) return error.CredentialFileChanged;
        return parse(bytes[0..count]);
    }

    fn publish(self: *Owner, record: *const Record) !void {
        return self.publishWithFault(record, null);
    }

    const PublishFault = enum { write, file_sync, rename, directory_sync };

    fn publishWithFault(self: *Owner, record: *const Record, fault: ?PublishFault) !void {
        if (self.parent.openFile(io, self.finalName(), .{
            .allow_directory = false,
            .follow_symlinks = false,
        })) |old| {
            defer old.close(io);
            try validatePrivateFile(old);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var temp_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const temp_name = try self.derivedName(".tmp", &temp_buffer);
        if (self.parent.openFile(io, temp_name, .{
            .allow_directory = false,
            .follow_symlinks = false,
        })) |stale| {
            defer stale.close(io);
            try validatePrivateFile(stale);
            try self.parent.deleteFile(io, temp_name);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const file = try self.parent.createFile(io, temp_name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        var file_open = true;
        var published = false;
        defer {
            if (file_open) file.close(io);
            if (!published) self.parent.deleteFile(io, temp_name) catch {};
        }
        var bytes: [max_file_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const encoded = try encode(record, &bytes);
        if (fault == .write) {
            try file.writeStreamingAll(io, encoded[0..@min(4, encoded.len)]);
            return error.InjectedCredentialWriteFailure;
        }
        try file.writeStreamingAll(io, encoded);
        if (fault == .file_sync) return error.InjectedCredentialFileSyncFailure;
        try file.sync(io);
        file.close(io);
        file_open = false;
        if (fault == .rename) return error.InjectedCredentialRenameFailure;
        try self.parent.rename(temp_name, self.parent, self.finalName(), io);
        published = true;
        // After rename the new value is visible and committed at file level. If
        // this fails, callers receive DirectorySyncFailed and must inspect on
        // restart; blindly repeating a refresh is unsafe because publication is
        // uncertain across power loss.
        if (fault == .directory_sync) return error.InjectedCredentialDirectorySyncFailure;
        try self.syncDirectory();
    }

    fn syncDirectory(self: *Owner) !void {
        if (std.c.fsync(self.parent.handle) != 0) return error.DirectorySyncFailed;
    }
};

fn openAbsoluteNoSymlinks(path: []const u8) !std.Io.Dir {
    var current = try std.Io.Dir.openDirAbsolute(io, "/", .{ .iterate = true, .follow_symlinks = false });
    errdefer current.close(io);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.InvalidCredentialPath;
        const next = try current.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
        current.close(io);
        current = next;
    }
    return current;
}

fn validatePrivate(dir: std.Io.Dir) !void {
    const stat = try dir.stat(io);
    if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0)
        return error.InsecureCredentialDirectory;
    try validateOwner(dir.handle);
}

fn validatePrivateFile(file: std.Io.File) !void {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0)
        return error.InsecureCredentialFile;
    try validateOwner(file.handle);
}

fn validateOwner(handle: anytype) !void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    var stat: c.struct_stat = undefined;
    if (c.fstat(handle, &stat) != 0) return error.StatFailed;
    if (stat.st_uid != c.geteuid()) return error.NotOwnedByCurrentUser;
}

fn validateText(value: []const u8, empty_allowed: bool) !void {
    if (!empty_allowed and value.len == 0) return error.EmptyCredentialField;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidCredentialByte;
}

fn validateRecord(record: *const Record) !void {
    if (record.version != 3) return error.UnsupportedCredentialVersion;
    try validateText(record.account_id.slice(), false);
    try validateText(record.id_token.slice(), false);
    try validateText(record.access_token.slice(), false);
    try validateText(record.refresh_token.slice(), false);
    if (record.expires_at < 0 or record.refreshed_at <= 0) return error.InvalidCredentialTime;
    var segments = std.mem.splitScalar(u8, record.access_token.slice(), '.');
    var count: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidAccessToken;
        count += 1;
    }
    if (count != 1 and count != 3) return error.InvalidAccessToken;
}

fn encode(record: *const Record, destination: []u8) ![]const u8 {
    try validateRecord(record);
    return std.fmt.bufPrint(destination, "version=3\ngeneration={d}\naccount_id={s}\nfedramp={d}\nid_token={s}\naccess_token={s}\nrefresh_token={s}\nexpires_at={d}\nrefreshed_at={d}\nstate={s}\n", .{ record.generation, record.account_id.slice(), @intFromBool(record.fedramp), record.id_token.slice(), record.access_token.slice(), record.refresh_token.slice(), record.expires_at, record.refreshed_at, @tagName(record.state) }) catch
        return error.CredentialFileTooLarge;
}

fn parse(bytes: []const u8) !Record {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidCredentialFile, "version=3"))
        return error.UnsupportedCredentialVersion;
    var record: Record = .{ .generation = try decimal(u64, field(lines.next(), "generation=")), .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 0, .refreshed_at = 0 };
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try record.account_id.set(try field(lines.next(), "account_id="));
    const fedramp = try field(lines.next(), "fedramp=");
    if (std.mem.eql(u8, fedramp, "1")) record.fedramp = true else if (!std.mem.eql(u8, fedramp, "0")) return error.InvalidCredentialFile;
    try record.id_token.set(try field(lines.next(), "id_token="));
    try record.access_token.set(try field(lines.next(), "access_token="));
    try record.refresh_token.set(try field(lines.next(), "refresh_token="));
    record.expires_at = try decimal(i64, field(lines.next(), "expires_at="));
    record.refreshed_at = try decimal(i64, field(lines.next(), "refreshed_at="));
    record.state = std.meta.stringToEnum(State, try field(lines.next(), "state=")) orelse
        return error.InvalidCredentialState;
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidCredentialFile, "") or lines.next() != null)
        return error.TrailingCredentialData;
    try validateRecord(&record);
    return record;
}

fn field(line: ?[]const u8, prefix: []const u8) ![]const u8 {
    const value = line orelse return error.InvalidCredentialFile;
    if (!std.mem.startsWith(u8, value, prefix)) return error.InvalidCredentialFile;
    return value[prefix.len..];
}

fn decimal(comptime T: type, value: anytype) !T {
    return std.fmt.parseInt(T, try value, 10) catch return error.InvalidCredentialNumber;
}

fn testRecord(account: []const u8, generation: u64) !Record {
    var result: Record = .{ .generation = generation, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 1234, .refreshed_at = 1_750_000_000 };
    try result.account_id.set(account);
    try result.id_token.set("aaa.bbb.ccc");
    try result.access_token.set("aaa.bbb.ccc");
    try result.refresh_token.set("private-refresh");
    return result;
}

fn testPath(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var private = try tmp.dir.createDirPathOpen(io, "private", .{
        .permissions = .fromMode(0o700),
        .open_options = .{ .iterate = true },
    });
    private.close(io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &root);
    return std.fmt.bufPrint(buffer, "{s}/private/{s}", .{ root[0..len], name });
}

test "successive login, generation compare, pending restart, and privacy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "auth", &path_buffer);
    var first = try testRecord("acct", 999);
    try install(path, &first, null);
    try std.testing.expectEqual(@as(u64, 1), (try load(path)).generation);
    var second = try testRecord("acct", 0);
    try install(path, &second, null);
    try std.testing.expectEqual(@as(u64, 2), (try load(path)).generation);
    try std.testing.expectError(error.GenerationMismatch, install(path, &second, 1));
    try markRefreshPending(path, 2);
    const pending = try load(path);
    try std.testing.expectEqual(State.refresh_pending, pending.state);
    try std.testing.expectError(error.GenerationMismatch, markRefreshPending(path, 2));
    try std.testing.expectEqual(@as(u64, 2), pending.generation);
    try install(path, &second, 2);
    try std.testing.expectEqual(@as(u64, 3), (try load(path)).generation);

    const stat = try tmp.dir.statFile(io, "private/auth", .{});
    const lock_stat = try tmp.dir.statFile(io, "private/.auth.lock", .{});
    try std.testing.expectEqual(@as(u16, 0o600), stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u16, 0o600), lock_stat.permissions.toMode() & 0o777);
}

test "explicit login overtakes refresh intent without overwriting its new account" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "auth", &path_buffer);
    var original = try testRecord("account-A", 0);
    try install(path, &original, null);
    var initial = try lease(path);
    try std.testing.expectEqualStrings("account-A", initial.record.account_id.slice());
    initial.release();
    try markRefreshPending(path, 1);
    try std.testing.expectError(error.RefreshRequiresLogin, lease(path));
    var new_login = try testRecord("account-B", 0);
    try std.testing.expectError(error.AccountMismatch, install(path, &new_login, 1));
    try install(path, &new_login, null);
    try std.testing.expectError(error.GenerationMismatch, install(path, &original, 1));
    var selected = try lease(path);
    defer selected.release();
    try std.testing.expectEqual(@as(u64, 2), selected.record.generation);
    try std.testing.expectEqualStrings("account-B", selected.record.account_id.slice());
}

test "unsafe paths and credential aliases fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "auth", &path_buffer);
    var record = try testRecord("acct", 0);
    try std.testing.expectError(error.PathMustBeAbsolute, install("relative", &record, null));
    var private = try tmp.dir.openDir(io, "private", .{});
    defer private.close(io);
    try private.symLink(io, "missing", "auth", .{});
    try std.testing.expectError(error.SymLinkLoop, install(path, &record, null));
}

test "private file, lock, directory, and abandoned temp are validated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "auth", &path_buffer);
    var record = try testRecord("acct", 0);
    try install(path, &record, null);
    var private = try tmp.dir.openDir(io, "private", .{ .iterate = true });
    defer private.close(io);
    const file = try private.openFile(io, "auth", .{ .mode = .read_write });
    try file.setPermissions(io, .fromMode(0o644));
    try std.testing.expectError(error.InsecureCredentialFile, load(path));
    try file.setPermissions(io, .fromMode(0o600));
    file.close(io);
    const lock = try private.openFile(io, ".auth.lock", .{ .mode = .read_write });
    try lock.setPermissions(io, .fromMode(0o644));
    try std.testing.expectError(error.InsecureCredentialFile, load(path));
    try lock.setPermissions(io, .fromMode(0o600));
    lock.close(io);
    try private.symLink(io, "auth", ".auth.tmp", .{});
    try std.testing.expectError(error.SymLinkLoop, install(path, &record, null));
    try std.testing.expectEqual(@as(u64, 1), (try load(path)).generation);
    try private.deleteFile(io, ".auth.tmp");
    try private.setPermissions(io, .fromMode(0o755));
    try std.testing.expectError(error.InsecureCredentialDirectory, load(path));
    try private.setPermissions(io, .fromMode(0o700));
}

test "format is bounded and strictly consumed" {
    var record = try testRecord("acct", 7);
    var bytes: [max_file_bytes]u8 = undefined;
    const encoded = try encode(&record, &bytes);
    const decoded = try parse(encoded);
    try std.testing.expectEqual(@as(u64, 7), decoded.generation);
    try record.access_token.set("opaque-access");
    record.expires_at = 0;
    const opaque_encoded = try encode(&record, &bytes);
    try std.testing.expectEqualStrings("opaque-access", (try parse(opaque_encoded)).access_token.slice());
    var extra: [max_file_bytes]u8 = undefined;
    @memcpy(extra[0..opaque_encoded.len], opaque_encoded);
    @memcpy(extra[opaque_encoded.len..][0..4], "junk");
    try std.testing.expectError(error.TrailingCredentialData, parse(extra[0 .. opaque_encoded.len + 4]));
}

test "each replacement failure leaves only a complete old or new credential" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "auth", &path_buffer);
    var original = try testRecord("old", 0);
    try install(path, &original, null);
    var replacement = try testRecord("new", 2);
    inline for (.{
        .{ Owner.PublishFault.write, error.InjectedCredentialWriteFailure },
        .{ Owner.PublishFault.file_sync, error.InjectedCredentialFileSyncFailure },
        .{ Owner.PublishFault.rename, error.InjectedCredentialRenameFailure },
        .{ Owner.PublishFault.directory_sync, error.InjectedCredentialDirectorySyncFailure },
    }) |case| {
        var owner = try Owner.open(path);
        const lock = try owner.acquireLock(.exclusive);
        try std.testing.expectError(case[1], owner.publishWithFault(&replacement, case[0]));
        lock.close(io);
        owner.close();
        var observed = try load(path);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&observed));
        try std.testing.expectEqualStrings(if (case[0] == .directory_sync) "new" else "old", observed.account_id.slice());
        if (case[0] == .directory_sync) break;
    }
}
