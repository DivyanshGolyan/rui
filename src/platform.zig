const std = @import("std");
const protocol = @import("protocol.zig");
const named_scratch = @import("named_scratch.zig");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
});

pub const database_suffix = "/rui.sqlite3";
pub const scratch_suffix = "/scratch";
pub const max_database_path_bytes = protocol.max_store_bytes + database_suffix.len;
pub const max_scratch_path_bytes = protocol.max_store_bytes + scratch_suffix.len;
const runtime_prefix = "/tmp/rui-";
const max_uid_bytes = "4294967295".len;
const socket_suffix = ".sock";
pub const max_runtime_directory_bytes = runtime_prefix.len + max_uid_bytes;
pub const max_socket_path_bytes = max_runtime_directory_bytes + "/".len + 32 + socket_suffix.len;

pub const Paths = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    database: protocol.Bounded(max_database_path_bytes) = .{},
    scratch: protocol.Bounded(max_scratch_path_bytes) = .{},
    socket: protocol.Bounded(max_socket_path_bytes) = .{},
};

pub const StoreLease = struct {
    io: std.Io,
    paths: Paths,
    store_dir: std.Io.Dir,
    lock_file: std.Io.File,

    pub const Observation = union(enum) { owned: Paths, unowned, access_failure };

    /// Read-only observation, not lease acquisition or readiness. Returns
    /// owned canonical paths by value; every probe descriptor closes here.
    pub fn observe(io: std.Io, supplied_path: []const u8) Observation {
        var store_dir = std.Io.Dir.cwd().openDir(io, supplied_path, .{}) catch |err| return switch (err) {
            error.FileNotFound => .unowned,
            else => .access_failure,
        };
        defer store_dir.close(io);
        validatePrivateDirectory(store_dir, io) catch return .access_failure;
        const paths = pathsFromOpenStore(store_dir, io) catch return .access_failure;
        // A hostile FIFO must not wait for a writer; never follow or create
        // a replacement lock node during observation.
        const fd = std.posix.openat(store_dir.handle, "host.lock", .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0) catch |err| return switch (err) {
            error.FileNotFound => .unowned,
            else => .access_failure,
        };
        const lock_file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        defer lock_file.close(io);
        const stat = lock_file.stat(io) catch return .access_failure;
        if (stat.kind != .file) return .access_failure;
        return switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB))) {
            .SUCCESS => .unowned,
            .AGAIN => .{ .owned = paths },
            else => .access_failure,
        };
    }

    pub fn acquire(io: std.Io, supplied_path: []const u8) !StoreLease {
        var store_dir = try std.Io.Dir.cwd().createDirPathOpen(io, supplied_path, .{
            .permissions = .fromMode(0o700),
            .open_options = .{ .iterate = true },
        });
        errdefer store_dir.close(io);
        try validatePrivateDirectory(store_dir, io);

        const paths = try pathsFromOpenStore(store_dir, io);
        var lock_file = store_dir.createFile(io, "host.lock", .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock => return error.StoreAlreadyOwned,
            else => return err,
        };
        errdefer lock_file.close(io);

        return .{
            .io = io,
            .paths = paths,
            .store_dir = store_dir,
            .lock_file = lock_file,
        };
    }

    pub fn prepareForServing(self: *StoreLease, fault_cleanup: bool) !void {
        var scratch = try self.store_dir.createDirPathOpen(self.io, "scratch", .{
            .permissions = .fromMode(0o700),
            .open_options = .{ .iterate = true },
        });
        defer scratch.close(self.io);
        try validatePrivateDirectory(scratch, self.io);
        try cleanupOwnedIngress(&scratch, self.io, fault_cleanup);

        var runtime_dir_path: [max_runtime_directory_bytes]u8 = undefined;
        const runtime_path = try runtimeDirectory(&runtime_dir_path);
        var runtime_dir = try std.Io.Dir.cwd().createDirPathOpen(self.io, runtime_path, .{
            .permissions = .fromMode(0o700),
        });
        defer runtime_dir.close(self.io);
        try validatePrivateDirectory(runtime_dir, self.io);

        try reclaimStaleSocket(self.io, self.paths.socket.slice());
    }

    pub fn release(self: *StoreLease) void {
        self.lock_file.close(self.io);
        self.store_dir.close(self.io);
        self.* = undefined;
    }
};

pub fn resolveClientPaths(io: std.Io, supplied_path: []const u8) !Paths {
    var store_dir = try std.Io.Dir.cwd().openDir(io, supplied_path, .{});
    defer store_dir.close(io);
    try validatePrivateDirectory(store_dir, io);
    return pathsFromOpenStore(store_dir, io);
}

/// Read-only destination check before authentication repair. Existing Stores
/// retain their private-directory checks; absent explicit/HOME destinations
/// must fit after canonicalizing their nearest existing parent. Serving still
/// checks the actual created directory and acquires its lease against races.
pub fn validateStoreDestination(io: std.Io, supplied_path: []const u8) !void {
    if (supplied_path.len == 0 or !std.unicode.utf8ValidateSlice(supplied_path)) return error.InvalidStorePath;
    for (supplied_path) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidStorePath;
    _ = resolveClientPaths(io, supplied_path) catch |err| switch (err) {
        error.FileNotFound => {
            var parent = supplied_path;
            while (true) {
                parent = std.fs.path.dirname(parent) orelse ".";
                var directory: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, parent, .{}) catch |parent_err| switch (parent_err) {
                    error.FileNotFound => continue,
                    else => return parent_err,
                };
                defer if (directory) |dir| dir.close(io);
                var canonical: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
                var length = try directory.?.realPath(io, &canonical);
                var name_max = c.fpathconf(directory.?.handle, c._PC_NAME_MAX);
                if (name_max <= 0) return error.StoreComponentLimitUnavailable;
                // The handle anchors the existing prefix. Missing depth tracks
                // virtual directories only; canceling them resumes real checks.
                // Creation traverses even components later canceled by '..'.
                var missing_depth: usize = 0;
                const suffix = if (std.mem.eql(u8, parent, ".")) supplied_path else supplied_path[parent.len..];
                var components = std.mem.tokenizeScalar(u8, suffix, '/');
                while (components.next()) |component| {
                    if (component.len > name_max) return error.NameTooLong;
                    if (missing_depth == 0 and c.faccessat(directory.?.handle, ".", c.X_OK, 0) != 0) return error.AccessDenied;
                    if (std.mem.eql(u8, component, ".")) continue;
                    if (std.mem.eql(u8, component, "..")) {
                        length = if (std.fs.path.dirname(canonical[0..length])) |up| up.len else 1;
                        if (missing_depth != 0) {
                            missing_depth -= 1;
                            continue;
                        }
                    } else {
                        const separator: usize = if (length == 1) 0 else 1;
                        if (length + separator + component.len > canonical.len) return error.NameTooLong;
                        if (separator != 0) canonical[length] = '/';
                        @memcpy(canonical[length + separator ..][0..component.len], component);
                        length += separator + component.len;
                        if (missing_depth != 0) {
                            missing_depth += 1;
                            continue;
                        }
                        const stat = std.Io.Dir.cwd().statFile(io, canonical[0..length], .{ .follow_symlinks = false }) catch |stat_err| switch (stat_err) {
                            error.FileNotFound => {
                                if (c.faccessat(directory.?.handle, ".", c.W_OK | c.X_OK, 0) != 0) return error.AccessDenied;
                                missing_depth = 1;
                                continue;
                            },
                            else => return stat_err,
                        };
                        // Recursive creation rejects an existing symlink at a
                        // prefix it visits, unlike opening the initial ancestor.
                        if (stat.kind != .directory) return error.NotDir;
                    }
                    directory.?.close(io);
                    directory = null;
                    directory = try std.Io.Dir.cwd().openDir(io, canonical[0..length], .{});
                    name_max = c.fpathconf(directory.?.handle, c._PC_NAME_MAX);
                    if (name_max <= 0) return error.StoreComponentLimitUnavailable;
                }
                if (missing_depth == 0) try validatePrivateDirectory(directory.?, io);
                try validateCanonicalPath(canonical[0..length]);
                return;
            }
        },
        else => return err,
    };
}

fn pathsFromOpenStore(store_dir: std.Io.Dir, io: std.Io) !Paths {
    // A full Linux readlink buffer can mean truncation. One extra byte makes
    // both an exact 493-byte path and any truncated longer path reject.
    var canonical_buffer: [protocol.max_store_bytes + 1]u8 = undefined;
    const canonical_length = store_dir.realPath(io, &canonical_buffer) catch |err| switch (err) {
        error.NameTooLong => return error.StorePathTooLong,
        else => return err,
    };
    if (canonical_length > protocol.max_store_bytes) return error.StorePathTooLong;
    const canonical = canonical_buffer[0..canonical_length];
    try validateCanonicalPath(canonical);

    var paths: Paths = .{};
    try paths.store.set(canonical);
    var database_buffer: [max_database_path_bytes]u8 = undefined;
    try paths.database.set(try std.fmt.bufPrint(&database_buffer, "{s}{s}", .{ canonical, database_suffix }));
    var scratch_buffer: [max_scratch_path_bytes]u8 = undefined;
    try paths.scratch.set(try std.fmt.bufPrint(&scratch_buffer, "{s}{s}", .{ canonical, scratch_suffix }));

    var socket_buffer: [max_socket_path_bytes]u8 = undefined;
    try paths.socket.set(try socketPathForCanonical(canonical, &socket_buffer));
    if (paths.socket.len > std.Io.net.UnixAddress.max_len) return error.SocketPathTooLong;
    return paths;
}

fn validateCanonicalPath(canonical: []const u8) !void {
    if (canonical.len > protocol.max_store_bytes) return error.StorePathTooLong;
    if (!std.unicode.utf8ValidateSlice(canonical)) return error.InvalidStorePath;
}

fn runtimeDirectory(buffer: []u8) ![]const u8 {
    return runtimeDirectoryForUid(buffer, @intCast(std.c.geteuid()));
}

fn runtimeDirectoryForUid(buffer: []u8, uid: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}{d}", .{ runtime_prefix, uid });
}

fn socketPathForCanonical(canonical: []const u8, buffer: []u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hash_text = std.fmt.bytesToHex(digest[0..16].*, .lower);
    var runtime_buffer: [max_runtime_directory_bytes]u8 = undefined;
    const runtime = try runtimeDirectory(&runtime_buffer);
    return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ runtime, hash_text, socket_suffix });
}

fn validatePrivateDirectory(dir: std.Io.Dir, io: std.Io) !void {
    const stat = try dir.stat(io);
    if (stat.kind != .directory) return error.NotDirectory;
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureDirectoryPermissions;
}

fn isOwnedIngressName(name: []const u8) bool {
    return isOwnedNumericScratch(name, "request-") or
        isOwnedNumericScratch(name, "response-") or
        isOwnedNumericScratch(name, "response-metadata-") or
        isOwnedNumericScratch(name, "bash-input-") or
        isOwnedNumericScratch(name, "bash-stdout-") or
        isOwnedNumericScratch(name, "bash-stderr-") or
        isOwnedNumericScratch(name, "report-") or
        named_scratch.EvaluatorName.isOwned(name);
}

fn isOwnedNumericScratch(name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".tmp")) return false;
    const middle = name[prefix.len .. name.len - ".tmp".len];
    const separator = std.mem.indexOfScalar(u8, middle, '-') orelse return false;
    if (std.mem.indexOfScalar(u8, middle[separator + 1 ..], '-') != null) return false;
    const zero_request_number = (std.mem.eql(u8, prefix, "request-") or
        std.mem.eql(u8, prefix, "report-")) and std.mem.eql(u8, middle[0..separator], "0");
    return (zero_request_number or isCanonicalPositiveDecimal(middle[0..separator])) and
        isCanonicalPositiveDecimal(middle[separator + 1 ..]);
}

fn isCanonicalPositiveDecimal(value: []const u8) bool {
    if (value.len == 0 or value[0] < '1' or value[0] > '9') return false;
    for (value[1..]) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    _ = std.fmt.parseInt(u64, value, 10) catch return false;
    return true;
}

fn cleanupOwnedIngress(scratch: *std.Io.Dir, io: std.Io, fault_cleanup: bool) !void {
    var iterator = scratch.iterate();
    while (try iterator.next(io)) |entry| {
        if (!isOwnedIngressName(entry.name)) continue;
        if (entry.kind != .file) return error.UnexpectedIngressLeftover;
        if (fault_cleanup) return error.InjectedCleanupFailure;
        try scratch.deleteFile(io, entry.name);
    }
}

fn reclaimStaleSocket(io: std.Io, socket_path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, socket_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) return error.UnexpectedSocketPath;
    try std.Io.Dir.deleteFileAbsolute(io, socket_path);
}

fn createDirectoryAtCanonicalLength(
    parent: std.Io.Dir,
    io: std.Io,
    target_length: usize,
    path_buffer: []u8,
) ![]const u8 {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try parent.realPath(io, &root_buffer)];
    if (target_length <= root.len) return error.InvalidTargetLength;
    const relative_length = target_length - root.len - 1;
    var relative_buffer: [protocol.max_store_bytes]u8 = undefined;
    var offset: usize = 0;
    var remaining = relative_length;
    while (remaining > 255) {
        @memset(relative_buffer[offset .. offset + 255], 'a');
        relative_buffer[offset + 255] = '/';
        offset += 256;
        remaining -= 256;
    }
    if (remaining == 0) return error.InvalidTargetLength;
    @memset(relative_buffer[offset .. offset + remaining], 'b');
    const relative = relative_buffer[0 .. offset + remaining];
    var directory = try parent.createDirPathOpen(io, relative, .{
        .permissions = .fromMode(0o700),
    });
    directory.close(io);
    const path = try std.fmt.bufPrint(path_buffer, "{s}/{s}", .{ root, relative });
    std.debug.assert(path.len == target_length);
    return path;
}

fn expectNoStoreEffects(path: []const u8, io: std.Io) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    try std.testing.expectError(error.FileNotFound, directory.statFile(io, "host.lock", .{}));
    try std.testing.expectError(error.FileNotFound, directory.statFile(io, "rui.sqlite3", .{}));
    var socket_buffer: [max_socket_path_bytes]u8 = undefined;
    const socket_path = try socketPathForCanonical(path, &socket_buffer);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, socket_path, .{ .follow_symlinks = false }),
    );
}

test "Store paths canonicalize aliases to one socket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try tmp.dir.createDirPathOpen(std.testing.io, "store", .{
        .permissions = .fromMode(0o700),
    });
    store.close(std.testing.io);

    var first = try tmp.dir.openDir(std.testing.io, "store", .{});
    defer first.close(std.testing.io);
    const one = try pathsFromOpenStore(first, std.testing.io);
    var second = try tmp.dir.openDir(std.testing.io, "./store", .{});
    defer second.close(std.testing.io);
    const two = try pathsFromOpenStore(second, std.testing.io);
    try std.testing.expectEqualStrings(one.store.slice(), two.store.slice());
    try std.testing.expectEqualStrings(one.socket.slice(), two.socket.slice());
}

test "Store lease observation owns probe mechanics and releases every descriptor" {
    const io = std.testing.io;
    const descriptors = @import("descriptor_limit.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store", .{root});
    const baseline = (try descriptors.observe(io)).open_descriptors;
    for (0..16) |_| try std.testing.expect(StoreLease.observe(io, path) == .unowned);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "store", .{}));
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    for (0..16) |_| try std.testing.expect(StoreLease.observe(io, path) == .unowned);
    try expectNoStoreEffects(path, io);
    try std.testing.expectEqual(baseline, (try descriptors.observe(io)).open_descriptors);

    try tmp.dir.symLink(io, "store", "alias", .{ .is_directory = true });
    var alias_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const alias = try std.fmt.bufPrint(&alias_buffer, "{s}/alias", .{root});
    {
        var lease = try StoreLease.acquire(io, path);
        defer lease.release();
        const leased = (try descriptors.observe(io)).open_descriptors;
        for (0..16) |_| {
            const observation = StoreLease.observe(io, alias);
            try std.testing.expect(observation == .owned);
            try std.testing.expectEqualStrings(lease.paths.store.slice(), observation.owned.store.slice());
            try std.testing.expectEqualStrings(lease.paths.socket.slice(), observation.owned.socket.slice());
        }
        try std.testing.expectEqual(leased, (try descriptors.observe(io)).open_descriptors);
    }
    for (0..16) |_| try std.testing.expect(StoreLease.observe(io, alias) == .unowned);
    try std.testing.expectEqual(baseline, (try descriptors.observe(io)).open_descriptors);

    try tmp.dir.deleteFile(io, "store/host.lock");
    const target = try tmp.dir.createFile(io, "target", .{});
    target.close(io);
    try tmp.dir.symLink(io, "../target", "store/host.lock", .{});
    for (0..16) |_| try std.testing.expect(StoreLease.observe(io, path) == .access_failure);
    try tmp.dir.deleteFile(io, "store/host.lock");
    try tmp.dir.createDir(io, "store/host.lock", .default_dir);
    for (0..16) |_| try std.testing.expect(StoreLease.observe(io, path) == .access_failure);
    try tmp.dir.deleteDir(io, "store/host.lock");
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifoat(tmp.dir.handle, "store/host.lock", 0o600));
    for (0..16) |_| try std.testing.expect(StoreLease.observe(io, path) == .access_failure);
    try tmp.dir.deleteFile(io, "store/host.lock");
    var store = try tmp.dir.openDir(io, "store", .{ .iterate = true });
    defer store.close(io);
    try store.setPermissions(io, .fromMode(0o755));
    for (0..16) |_| try std.testing.expect(StoreLease.observe(io, path) == .access_failure);
    try std.testing.expectEqual(baseline + 1, (try descriptors.observe(io)).open_descriptors);
}

test "socket path uses the first 16 SHA-256 bytes in lowercase hex" {
    var buffer: [max_socket_path_bytes]u8 = undefined;
    const path = try socketPathForCanonical("/tmp/rui-stdlib-hex", &buffer);
    try std.testing.expect(std.mem.endsWith(u8, path, "/043ea4efef72c68973ebffcb0927e537.sock"));
}

test "absent destination preflight checks components but bounds canonical aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var path_buffer: [2048]u8 = undefined;
    const overlong = try std.fmt.bufPrint(&path_buffer, "{s}/missing/{s}", .{ root, &([_]u8{'x'} ** 256) });
    try std.testing.expectError(error.NameTooLong, validateStoreDestination(std.testing.io, overlong));
    const canceled = try std.fmt.bufPrint(&path_buffer, "{s}/missing/{s}/../../store", .{ root, &([_]u8{'x'} ** 256) });
    try std.testing.expectError(error.NameTooLong, validateStoreDestination(std.testing.io, canceled));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(std.testing.io, "missing", .{}));
    const alias = try std.fmt.bufPrint(&path_buffer, "{s}/new/{s}store", .{ root, "./" ** 260 });
    try validateStoreDestination(std.testing.io, alias);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(std.testing.io, "new", .{}));
    var lease = try StoreLease.acquire(std.testing.io, alias);
    defer lease.release();
    var expected_buffer: [protocol.max_store_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{s}/new/store", .{root});
    try std.testing.expectEqualStrings(expected, lease.paths.store.slice());
}

test "absent destination preflight resumes filesystem checks after missing components cancel" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "other/deep");
    try tmp.dir.symLink(io, "other/deep", "link", .{});
    var insecure = try tmp.dir.createDirPathOpen(io, "insecure", .{ .open_options = .{ .iterate = true } });
    defer insecure.close(io);
    try insecure.setPermissions(io, .fromMode(0o755));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [2048]u8 = undefined;
    const descriptors = @import("descriptor_limit.zig");
    const baseline = (try descriptors.observe(io)).open_descriptors;
    const symlink = try std.fmt.bufPrint(&path_buffer, "{s}/missing/../link/../store", .{root});
    try std.testing.expectError(error.NotDir, validateStoreDestination(io, symlink));
    const existing = try std.fmt.bufPrint(&path_buffer, "{s}/missing/../insecure", .{root});
    try std.testing.expectError(error.InsecureDirectoryPermissions, validateStoreDestination(io, existing));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "missing", .{}));
    const valid = try std.fmt.bufPrint(&path_buffer, "{s}/missing/../other/store", .{root});
    try validateStoreDestination(io, valid);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "missing", .{}));
    var lease = try StoreLease.acquire(io, valid);
    lease.release();
    const alias = try std.fmt.bufPrint(&path_buffer, "{s}/link/new-store", .{root});
    try validateStoreDestination(io, alias);
    var aliased = try StoreLease.acquire(io, alias);
    aliased.release();
    try std.testing.expectEqual(baseline, (try descriptors.observe(io)).open_descriptors);
    if (std.c.geteuid() != 0) {
        try insecure.setPermissions(io, .fromMode(0o500));
        const denied = try std.fmt.bufPrint(&path_buffer, "{s}/insecure/missing/../../other/new", .{root});
        try std.testing.expectError(error.AccessDenied, validateStoreDestination(io, denied));
        try std.testing.expectError(error.FileNotFound, insecure.openDir(io, "missing", .{}));
        try insecure.setPermissions(io, .fromMode(0o755));
    }
}

test "absent destination preflight checks read-only ancestor reached through dot dot" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const target = "/sys/rui-preflight-never-created";
    try std.testing.expectError(error.AccessDenied, validateStoreDestination(io, target));
    var path_buffer: [2048]u8 = undefined;
    var length = (try std.fmt.bufPrint(&path_buffer, "{s}/missing/", .{root})).len;
    for (root) |byte| {
        if (byte == '/') {
            @memcpy(path_buffer[length..][0..3], "../");
            length += 3;
        }
    }
    @memcpy(path_buffer[length..][0..3], "../");
    length += 3;
    const tail = target[1..];
    @memcpy(path_buffer[length..][0..tail.len], tail);
    length += tail.len;
    try std.testing.expectError(error.AccessDenied, validateStoreDestination(io, path_buffer[0..length]));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "missing", .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, target, .{}));
}

test "Store path capacities follow the SQLite VFS and derived suffixes" {
    try std.testing.expectEqual(@as(usize, 492), protocol.max_store_bytes);
    try std.testing.expectEqual(@as(usize, 504), max_database_path_bytes);
    try std.testing.expectEqual(@as(usize, 500), max_scratch_path_bytes);
    try std.testing.expectEqual(@as(usize, 57), max_socket_path_bytes);
    var runtime_buffer: [max_runtime_directory_bytes]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, max_runtime_directory_bytes),
        (try runtimeDirectoryForUid(&runtime_buffer, std.math.maxInt(u32))).len,
    );
}

test "canonical Store boundary rejects before ownership or endpoint effects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var accepted_buffer: [protocol.max_store_bytes]u8 = undefined;
    const accepted_path = try createDirectoryAtCanonicalLength(
        tmp.dir,
        std.testing.io,
        protocol.max_store_bytes,
        &accepted_buffer,
    );
    const accepted = try resolveClientPaths(std.testing.io, accepted_path);
    try std.testing.expectEqual(@as(usize, protocol.max_store_bytes), accepted.store.len);
    try std.testing.expectEqual(@as(usize, max_database_path_bytes), accepted.database.len);
    try std.testing.expectEqual(@as(usize, max_scratch_path_bytes), accepted.scratch.len);

    var exact_overflow_buffer: [protocol.max_store_bytes + 1]u8 = undefined;
    const exact_overflow = try createDirectoryAtCanonicalLength(
        tmp.dir,
        std.testing.io,
        protocol.max_store_bytes + 1,
        &exact_overflow_buffer,
    );
    try std.testing.expectError(
        error.StorePathTooLong,
        StoreLease.acquire(std.testing.io, exact_overflow),
    );
    try expectNoStoreEffects(exact_overflow, std.testing.io);

    var truncated_buffer: [protocol.max_store_bytes + 2]u8 = undefined;
    const truncated = try createDirectoryAtCanonicalLength(
        tmp.dir,
        std.testing.io,
        protocol.max_store_bytes + 2,
        &truncated_buffer,
    );
    try std.testing.expectError(
        error.StorePathTooLong,
        StoreLease.acquire(std.testing.io, truncated),
    );
    try expectNoStoreEffects(truncated, std.testing.io);
}

test "long raw Store aliases remain usable when their canonical path fits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try tmp.dir.createDirPathOpen(std.testing.io, "store", .{
        .permissions = .fromMode(0o700),
    });
    store.close(std.testing.io);

    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var alias_buffer: [protocol.max_store_bytes + 128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&alias_buffer);
    try stream.writeAll(root);
    try stream.writeAll("/store");
    while (stream.end <= protocol.max_store_bytes) try stream.writeAll("/.");
    const alias = stream.buffered();
    try std.testing.expect(alias.len > protocol.max_store_bytes);

    var lease = try StoreLease.acquire(std.testing.io, alias);
    var expected_buffer: [protocol.max_store_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{s}/store", .{root});
    try std.testing.expectEqualStrings(expected, lease.paths.store.slice());
    lease.release();
}

test "invalid UTF-8 Store path remains distinct from path overflow" {
    try std.testing.expectError(error.InvalidStorePath, validateCanonicalPath(&.{0xff}));
    const overlong = [_]u8{'a'} ** (protocol.max_store_bytes + 1);
    try std.testing.expectError(error.StorePathTooLong, validateCanonicalPath(&overlong));
}

test "startup cleanup recognizes only owned ingress names" {
    try std.testing.expect(isOwnedIngressName("request-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("response-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("response-metadata-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("bash-input-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("bash-stdout-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("bash-stderr-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("report-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("evaluator-0.tmp"));
    try std.testing.expect(isOwnedIngressName("evaluator-ffffffffffffffff.tmp"));
    for ([_]u64{ 0, 0x1a2b3c, std.math.maxInt(u64) }) |id| {
        var buffer: [64]u8 = undefined;
        try std.testing.expect(isOwnedIngressName(try named_scratch.EvaluatorName.format(&buffer, id)));
    }
    inline for (.{ "request-", "response-", "response-metadata-", "bash-input-", "bash-stdout-", "bash-stderr-", "report-" }) |prefix| {
        var name_buffer: [64]u8 = undefined;
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}2-.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}--.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}x-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}12-x.tmp", .{prefix})));
        try std.testing.expectEqual(
            std.mem.eql(u8, prefix, "request-") or std.mem.eql(u8, prefix, "report-"),
            isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}0-2.tmp", .{prefix})),
        );
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}2-0.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}00-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}02-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}18446744073709551616-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}2-18446744073709551616.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}999999999999999999999999999999-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}2-999999999999999999999999999999.tmp", .{prefix})));
    }
    try std.testing.expect(!isOwnedIngressName("response-secret.tmp"));
    inline for (.{
        "evaluator-.tmp",
        "evaluator-00.tmp",
        "evaluator-1.index",
        "evaluator-1A.tmp",
        "evaluator-g.tmp",
        "evaluator-10000000000000000.tmp",
        "evaluator-1.tmp.extra",
        "evaluator-1.index.tmp",
    }) |name| try std.testing.expect(!isOwnedIngressName(name));
    try std.testing.expect(!isOwnedIngressName("canonical.sqlite3"));
}

test "startup cleanup removes owned files and preserves lookalikes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output_buffer: [64]u8 = undefined;
    const owned = [_][]const u8{
        "request-0-1.tmp",
        "response-1-1.tmp",
        "response-metadata-2-1.tmp",
        "bash-input-3-1.tmp",
        "bash-stdout-3-1.tmp",
        "bash-stderr-3-1.tmp",
        "report-0-1.tmp",
        try named_scratch.EvaluatorName.format(&output_buffer, 0),
    };
    const preserved = [_][]const u8{
        "request-00-1.tmp",
        "request-1-0.tmp",
        "request-1-1.tmp.extra",
        "request-1-1",
        "request-x-1.tmp",
        "request-1-1-1.tmp",
        "evaluator-00.tmp",
        "evaluator-deadbeef.index",
        "evaluator-DEADBEEF.index",
        "evaluator-deadbeef.index.extra",
        "diagnostic.log",
        "canonical.sqlite3",
    };
    for (owned ++ preserved) |name| {
        const file = try tmp.dir.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }

    var root = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer root.close(std.testing.io);
    try cleanupOwnedIngress(&root, std.testing.io, false);
    for (owned) |name| {
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, name, .{}));
    }
    for (preserved) |name| {
        try std.testing.expectEqual(std.Io.File.Kind.file, (try tmp.dir.statFile(std.testing.io, name, .{})).kind);
    }
}

test "startup cleanup refuses an owned name with the wrong type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buffer: [64]u8 = undefined;
    const name = try named_scratch.EvaluatorName.format(&name_buffer, 17);
    try tmp.dir.createDir(std.testing.io, name, .default_dir);
    var root = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer root.close(std.testing.io);
    try std.testing.expectError(
        error.UnexpectedIngressLeftover,
        cleanupOwnedIngress(&root, std.testing.io, false),
    );
    try std.testing.expectEqual(
        std.Io.File.Kind.directory,
        (try tmp.dir.statFile(std.testing.io, name, .{})).kind,
    );
}

test "startup cleanup refuses owned symlink and socket names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmp.dir.createFile(std.testing.io, "target", .{});
    target.close(std.testing.io);
    try tmp.dir.symLink(std.testing.io, "target", "request-1-1.tmp", .{});
    var root = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer root.close(std.testing.io);
    try std.testing.expectError(
        error.UnexpectedIngressLeftover,
        cleanupOwnedIngress(&root, std.testing.io, false),
    );
    try std.testing.expectEqual(
        std.Io.File.Kind.sym_link,
        (try tmp.dir.statFile(std.testing.io, "request-1-1.tmp", .{ .follow_symlinks = false })).kind,
    );
    try tmp.dir.deleteFile(std.testing.io, "request-1-1.tmp");

    var root_path_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_path = root_path_buffer[0..try tmp.dir.realPath(std.testing.io, &root_path_buffer)];
    var socket_path_buffer: [protocol.max_store_bytes]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_path_buffer, "{s}/response-1-1.tmp", .{root_path});
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    try std.testing.expectError(
        error.UnexpectedIngressLeftover,
        cleanupOwnedIngress(&root, std.testing.io, false),
    );
    try std.testing.expectEqual(
        std.Io.File.Kind.unix_domain_socket,
        (try tmp.dir.statFile(std.testing.io, "response-1-1.tmp", .{ .follow_symlinks = false })).kind,
    );
}

test "startup reclaims only a stale Unix socket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var socket_path_buffer: [protocol.max_store_bytes]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_path_buffer, "{s}/stale.sock", .{root});
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try address.listen(std.testing.io, .{});
    try reclaimStaleSocket(std.testing.io, socket_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, socket_path, .{ .follow_symlinks = false }),
    );
    listener.deinit(std.testing.io);

    const lookalike = try tmp.dir.createFile(std.testing.io, "stale.sock", .{});
    lookalike.close(std.testing.io);
    try std.testing.expectError(error.UnexpectedSocketPath, reclaimStaleSocket(std.testing.io, socket_path));
    try std.testing.expectEqual(
        std.Io.File.Kind.file,
        (try tmp.dir.statFile(std.testing.io, "stale.sock", .{ .follow_symlinks = false })).kind,
    );
}
