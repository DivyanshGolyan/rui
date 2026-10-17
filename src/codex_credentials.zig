const std = @import("std");
const builtin = @import("builtin");
const c = @import("posix");
const policy = @import("codex_credential_policy.zig");

const io = std.Io.Threaded.global_single_threaded.io();

pub const max_account_id_bytes = policy.max_account_id_bytes;
pub const max_token_bytes = policy.max_token_bytes;
pub const max_file_bytes = policy.max_file_bytes;
pub const State = policy.State;
pub const Record = policy.Record;

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
    var result: Lease = undefined;
    try leaseInto(path, &result);
    return result;
}

/// Initialize the lease in its final owner storage; on failure no lock or
/// token-bearing record remains with the caller.
pub fn leaseInto(path: []const u8, destination: *Lease) !void {
    destination.owner = try Owner.open(path);
    errdefer destination.owner.close();
    destination.lock = try destination.owner.acquireLock(.shared);
    errdefer destination.lock.close(io);
    try destination.owner.readRecordInto(&destination.record);
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(&destination.record));
    try destination.owner.syncDirectory();
    try policy.requireReady(&destination.record);
}

pub fn load(path: []const u8) !Record {
    var result: Record = undefined;
    try loadInto(path, &result);
    return result;
}

pub fn loadInto(path: []const u8, destination: *Record) !void {
    var owner = try Owner.open(path);
    defer owner.close();
    const lock = try owner.acquireLock(.shared);
    defer lock.close(io);
    try owner.readRecordInto(destination);
    errdefer std.crypto.secureZero(u8, std.mem.asBytes(destination));
    try owner.syncDirectory();
}

/// Read an atomic snapshot without creating a lock or refreshing. On success
/// the caller owns destination and must wipe it after its final consumer.
pub fn readSnapshotInto(path: []const u8, destination: *Record) !bool {
    var owner = Owner.open(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer owner.close();
    owner.readRecordInto(destination) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// `expected_generation == null` is an explicit login. It may replace an
/// existing login and advances its generation. A non-null value is a refresh
/// compare-and-swap and must preserve the account binding.
pub fn install(path: []const u8, record: *const Record, expected_generation: ?u64) !void {
    // Refuse an incomplete record before touching the owner directory;
    // admission checks it again with the current record.
    try policy.validateReplacement(record);
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
    replacement.generation = try policy.admitReplacement(if (current) |*old| old else null, &replacement, expected_generation);
    try owner.publish(&replacement);
}

/// Keep the stable lock from the durable intent through the exchange and save.
/// Other Hosts wait for the live claimant; after a crash they see the pending
/// record and require login instead of repeating a possibly consumed token.
/// The exchange owns its network effects and returns a complete replacement.
pub fn exchangeRefresh(path: []const u8, expected_generation: u64, context: anytype, exchange: anytype) !bool {
    var owner = try Owner.open(path);
    defer owner.close();
    const lock = try owner.acquireLock(.exclusive);
    defer lock.close(io);
    var record = try owner.readRecord();
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    if (try policy.claimRefresh(&record, expected_generation) == .superseded) return false;
    try owner.publish(&record);
    var replacement = try exchange(context, &record);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&replacement));
    replacement.generation = try policy.admitReplacement(&record, &replacement, expected_generation);
    try owner.publish(&replacement);
    return true;
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
        var result: Record = undefined;
        try self.readRecordInto(&result);
        return result;
    }

    fn readRecordInto(self: *Owner, destination: *Record) !void {
        // Reject a private FIFO after opening it without waiting for a writer.
        const file: std.Io.File = .{ .handle = try std.posix.openat(self.parent.handle, self.finalName(), .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0), .flags = .{ .nonblocking = true } };
        defer file.close(io);
        try validatePrivateFile(file);
        const stat = try file.stat(io);
        if (stat.size > max_file_bytes) return error.CredentialFileTooLarge;
        var bytes: [max_file_bytes + 1]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const count = try file.readPositionalAll(io, bytes[0..@intCast(stat.size + 1)], 0);
        if (count != stat.size) return error.CredentialFileChanged;
        try policy.parseInto(bytes[0..count], destination);
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
        const encoded = try policy.encode(record, &bytes);
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

test "installed local credential status completes under the exclusive mutation lock" {
    const auth = @import("codex_auth.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "auth", &path_buffer);
    var record = try testRecord(auth.fixture_account_id, 0);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try record.id_token.set(auth.fixture_id_token);
    try record.access_token.set(auth.fixture_access_token);
    record.expires_at = 4_102_444_800;
    try install(path, &record, null);
    var private = try tmp.dir.openDir(io, "private", .{});
    defer private.close(io);
    var before_buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &before_buffer);
    const before = try private.readFile(io, "auth", &before_buffer);
    const Worker = struct {
        path: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        configured: ?auth.LocalStatus = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.configured = auth.localStatus(self.path, 4_102_444_799) catch |err| result: {
                self.failure = err;
                break :result null;
            };
            self.done.store(true, .release);
        }
    };
    const lock = try private.openFile(io, ".auth.lock", .{ .mode = .read_write, .lock = .exclusive });
    var worker: Worker = .{ .path = path };
    const thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch |err| {
        lock.close(io);
        return err;
    };
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    while (!worker.done.load(.acquire) and start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds < 2 * std.time.ns_per_s)
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    // Record before releasing, then join even on the negative path: a shared
    // lock regression fails at this boundary rather than hanging the runner.
    const completed_while_locked = worker.done.load(.acquire);
    lock.close(io);
    thread.join();
    try std.testing.expect(completed_while_locked);
    try std.testing.expectEqual(@as(?anyerror, null), worker.failure);
    try std.testing.expectEqual(@as(?auth.LocalStatus, .configured), worker.configured);
    var after_buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &after_buffer);
    try std.testing.expectEqualStrings(before, try private.readFile(io, "auth", &after_buffer));
}

test "a rejected refresh replacement leaves the claim pending until login" {
    // Both routing directions and the admission rules are value-tested in
    // codex_credential_policy.zig. This proves the shell publishes the pending
    // claim before the exchange and nothing after a rejected replacement.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "auth", &path_buffer);
    var original = try testRecord("acct", 0);
    try install(path, &original, null);
    try std.testing.expectError(error.AccountMismatch, exchangeRefresh(path, 1, {}, struct {
        fn change(_: void, current: *const Record) !Record {
            var replacement = current.*;
            replacement.fedramp = !current.fedramp;
            replacement.state = .ready;
            return replacement;
        }
    }.change));
    const pending = try load(path);
    try std.testing.expectEqual(State.refresh_pending, pending.state);
    try std.testing.expectEqual(@as(u64, 1), pending.generation);
    try std.testing.expect(!pending.fedramp);
    try std.testing.expectError(error.RefreshRequiresLogin, lease(path));
    var changed = original;
    changed.fedramp = true;
    try install(path, &changed, null);
    var selected = try lease(path);
    defer selected.release();
    try std.testing.expectEqual(@as(u64, 2), selected.record.generation);
    try std.testing.expect(selected.record.fedramp);
}

test "unsafe paths and credential aliases fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "auth", &path_buffer);
    var record = try testRecord("acct", 0);
    try std.testing.expectError(error.PathMustBeAbsolute, install("relative", &record, null));
    // An incomplete record is refused before the owner path is examined.
    record.state = .refresh_pending;
    try std.testing.expectError(error.InstallMustBeReady, install("relative", &record, null));
    record.state = .ready;
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
    for ([_][]const u8{ "private/auth", "private/.auth.lock" }) |name|
        try std.testing.expectEqual(@as(u16, 0o600), (try tmp.dir.statFile(io, name, .{})).permissions.toMode() & 0o777);
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
