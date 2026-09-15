const std = @import("std");
const protocol = @import("protocol.zig");

pub const Paths = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    database: protocol.Bounded(protocol.max_store_bytes + 64) = .{},
    scratch: protocol.Bounded(protocol.max_store_bytes + 64) = .{},
    socket: protocol.Bounded(256) = .{},
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

        var runtime_dir_path: [128]u8 = undefined;
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
    var canonical_buffer: [protocol.max_store_bytes]u8 = undefined;
    const canonical_length = try store_dir.realPath(io, &canonical_buffer);
    const canonical = canonical_buffer[0..canonical_length];
    if (!std.unicode.utf8ValidateSlice(canonical)) return error.InvalidStorePath;

    var paths: Paths = .{};
    try paths.store.set(canonical);
    var database_buffer: [protocol.max_store_bytes + 64]u8 = undefined;
    try paths.database.set(try std.fmt.bufPrint(&database_buffer, "{s}/latifa.sqlite3", .{canonical}));
    var scratch_buffer: [protocol.max_store_bytes + 64]u8 = undefined;
    try paths.scratch.set(try std.fmt.bufPrint(&scratch_buffer, "{s}/scratch", .{canonical}));

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    var hash_text: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_text, "{x}", .{digest[0..16]}) catch unreachable;
    var runtime_buffer: [128]u8 = undefined;
    const runtime = try runtimeDirectory(&runtime_buffer);
    var socket_buffer: [256]u8 = undefined;
    try paths.socket.set(try std.fmt.bufPrint(&socket_buffer, "{s}/{s}.sock", .{ runtime, hash_text }));
    if (paths.socket.len > std.Io.net.UnixAddress.max_len) return error.SocketPathTooLong;
    return paths;
}

fn runtimeDirectory(buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "/tmp/latifa-{d}", .{std.c.geteuid()});
}

fn validatePrivateDirectory(dir: std.Io.Dir, io: std.Io) !void {
    const stat = try dir.stat(io);
    if (stat.kind != .directory) return error.NotDirectory;
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureDirectoryPermissions;
}

fn isOwnedIngressName(name: []const u8) bool {
    return isOwnedNumericScratch(name, "request-") or
        isOwnedNumericScratch(name, "response-") or
        isOwnedNumericScratch(name, "response-metadata-");
}

fn isOwnedNumericScratch(name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".tmp")) return false;
    const middle = name[prefix.len .. name.len - ".tmp".len];
    const separator = std.mem.indexOfScalar(u8, middle, '-') orelse return false;
    if (std.mem.indexOfScalar(u8, middle[separator + 1 ..], '-') != null) return false;
    const request_zero = std.mem.eql(u8, prefix, "request-") and std.mem.eql(u8, middle[0..separator], "0");
    return (request_zero or isCanonicalPositiveDecimal(middle[0..separator])) and
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

test "startup cleanup recognizes only owned ingress names" {
    try std.testing.expect(isOwnedIngressName("request-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("response-12-2.tmp"));
    try std.testing.expect(isOwnedIngressName("response-metadata-12-2.tmp"));
    inline for (.{ "request-", "response-", "response-metadata-" }) |prefix| {
        var name_buffer: [64]u8 = undefined;
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}2-.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}--.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}x-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}12-x.tmp", .{prefix})));
        try std.testing.expectEqual(std.mem.eql(u8, prefix, "request-"), isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}0-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}2-0.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}00-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}02-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}18446744073709551616-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}2-18446744073709551616.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}999999999999999999999999999999-2.tmp", .{prefix})));
        try std.testing.expect(!isOwnedIngressName(try std.fmt.bufPrint(&name_buffer, "{s}2-999999999999999999999999999999.tmp", .{prefix})));
    }
    try std.testing.expect(!isOwnedIngressName("response-secret.tmp"));
    try std.testing.expect(!isOwnedIngressName("canonical.sqlite3"));
}
