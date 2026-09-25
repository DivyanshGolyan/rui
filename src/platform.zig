const std = @import("std");
const protocol = @import("protocol.zig");

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
        isOwnedEvaluatorScratch(name);
}

fn isOwnedEvaluatorScratch(name: []const u8) bool {
    const prefix = "evaluator-";
    const suffix = if (std.mem.endsWith(u8, name, ".tmp"))
        ".tmp"
    else if (std.mem.endsWith(u8, name, ".index"))
        ".index"
    else
        return false;
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const value = name[prefix.len .. name.len - suffix.len];
    if (value.len == 0 or value.len > 16 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    _ = std.fmt.parseInt(u64, value, 16) catch return false;
    return true;
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

test "socket path uses the first 16 SHA-256 bytes in lowercase hex" {
    var buffer: [max_socket_path_bytes]u8 = undefined;
    const path = try socketPathForCanonical("/tmp/rui-stdlib-hex", &buffer);
    try std.testing.expect(std.mem.endsWith(u8, path, "/043ea4efef72c68973ebffcb0927e537.sock"));
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
    try std.testing.expect(isOwnedIngressName("evaluator-1a2b3c.index"));
    try std.testing.expect(isOwnedIngressName("evaluator-ffffffffffffffff.tmp"));
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
        "evaluator-01.index",
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
    const owned = [_][]const u8{
        "request-0-1.tmp",
        "response-1-1.tmp",
        "response-metadata-2-1.tmp",
        "bash-input-3-1.tmp",
        "bash-stdout-3-1.tmp",
        "bash-stderr-3-1.tmp",
        "report-0-1.tmp",
        "evaluator-0.tmp",
        "evaluator-deadbeef.index",
    };
    const preserved = [_][]const u8{
        "request-00-1.tmp",
        "request-1-0.tmp",
        "request-1-1.tmp.extra",
        "request-1-1",
        "request-x-1.tmp",
        "request-1-1-1.tmp",
        "evaluator-00.tmp",
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
    try tmp.dir.createDir(std.testing.io, "request-1-1.tmp", .default_dir);
    var root = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer root.close(std.testing.io);
    try std.testing.expectError(
        error.UnexpectedIngressLeftover,
        cleanupOwnedIngress(&root, std.testing.io, false),
    );
    try std.testing.expectEqual(
        std.Io.File.Kind.directory,
        (try tmp.dir.statFile(std.testing.io, "request-1-1.tmp", .{})).kind,
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
