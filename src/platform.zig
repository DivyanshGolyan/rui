const std = @import("std");
const protocol = @import("protocol.zig");
const named_scratch = @import("named_scratch.zig");
const store_path = @import("store_path.zig");
const validStoreId = @import("store_id.zig").valid;
const c = @import("posix");
const hs = @import("host_settings.zig");
const start_report = @import("start_report.zig");
const host_endpoint = @import("host_endpoint.zig");

pub const database_suffix = store_path.database_suffix;
pub const scratch_suffix = "/scratch";
pub const max_database_path_bytes = store_path.max_database_path_bytes;
pub const max_scratch_path_bytes = protocol.max_store_bytes + scratch_suffix.len;
const runtime_prefix = "/tmp/rui-";
const max_uid_bytes = "4294967295".len;
pub const max_runtime_directory_bytes = runtime_prefix.len + max_uid_bytes;
/// A derived interface directory: a child of the runtime directory named for
/// the canonical Host directory (`interfaceFor`).
pub const max_interface_directory_bytes = max_runtime_directory_bytes + "/".len + 32;
pub const max_socket_path_bytes = max_interface_directory_bytes + "/".len + hs.socket_name.len;
pub const max_launch_socket_path_bytes = @import("host_settings.zig").max_launch_socket_path_bytes;

pub const Kind = @import("store_target.zig").Kind;

pub const Paths = struct {
    kind: Kind = .sqlite,
    host_directory: hs.OsBytes(protocol.max_store_bytes) = .{},
    store_identity: protocol.Bounded(protocol.max_store_bytes) = .{},
    database: protocol.Bounded(max_database_path_bytes) = .{},
    scratch: protocol.Bounded(max_scratch_path_bytes) = .{},
    socket: @import("host_settings.zig").OsBytes(@max(max_socket_path_bytes, max_launch_socket_path_bytes)) = .{},

    pub fn selector(self: *const Paths) []const u8 {
        return if (self.host_directory.len != 0) self.host_directory.slice() else self.store_identity.slice();
    }

    pub noinline fn retainReachableDirectory(self: *Paths, io: std.Io, dir: []const u8) void {
        // A foreground unsaved placement need not be reachable through DIR.
        // Keep its legacy route rather than inventing a discoverable selector.
        const saved = resolveClientPaths(io, dir) catch return;
        if (self.kind != saved.kind or !std.mem.eql(u8, self.socket.slice(), saved.socket.slice())) return;
        if (self.kind == .sqlite and !self.store_identity.eql(saved.store_identity.slice())) return;
        self.host_directory = saved.host_directory;
    }

    pub fn runtimeHint(self: *const Paths) ?[]const u8 {
        return if (self.kind == .mysql) std.fs.path.dirname(self.socket.slice()) else null;
    }

    pub fn diagnosticsDirectory(self: *const Paths) []const u8 {
        return switch (self.kind) {
            .sqlite => self.store_identity.slice(),
            .mysql => self.runtimeHint().?,
        };
    }
};

const stop_record_name = "host.stopped";

pub const StoreLease = struct {
    io: std.Io,
    paths: Paths,
    store_dir: std.Io.Dir,
    /// `host.lock` on SQLite. A MySQL Store has none: GET_LOCK and the
    /// `store_owner` fence own it, and `host_endpoint` reserves its directory.
    lock_file: ?std.Io.File,

    pub const Observation = union(enum) { owned: Paths, unowned, access_failure };

    pub fn observe(io: std.Io, supplied_path: []const u8) Observation {
        const selection = resolveClientSelection(supplied_path);
        const paths = selection.paths(io) catch |err| return switch (err) {
            error.FileNotFound => .unowned,
            else => .access_failure,
        };
        // A MySQL Store is owned by the Host that holds its interface directory;
        // host_endpoint owns that lock, so observation asks it rather than reading the lock.
        if (paths.kind == .mysql) return switch (host_endpoint.occupancy(io, paths.runtimeHint().?)) {
            .held => .{ .owned = paths },
            .free, .absent => .unowned,
            .unusable => .access_failure,
        };
        var store_dir = std.Io.Dir.cwd().openDir(io, paths.store_identity.slice(), .{}) catch |err| return switch (err) {
            error.FileNotFound => .unowned,
            else => .access_failure,
        };
        defer store_dir.close(io);
        validatePrivateDirectory(store_dir, io) catch return .access_failure;
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

    pub noinline fn acquire(io: std.Io, supplied_path: []const u8) !StoreLease {
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

    /// Opens a MySQL Host's runtime directory, which its claimed endpoint
    /// already reserves (`host_endpoint.claim`).
    pub noinline fn acquireMysql(self: *StoreLease, io: std.Io, runtime_path: []const u8, socket_path: []const u8) !void {
        self.acquireMysqlDirectory(io, runtime_path, socket_path) catch return error.RuntimeDirectoryUnusable;
    }

    fn acquireMysqlDirectory(self: *StoreLease, io: std.Io, runtime_path: []const u8, socket_path: []const u8) !void {
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, runtime_path, .{
            .permissions = .fromMode(0o700),
            .open_options = .{ .iterate = true },
        });
        errdefer dir.close(io);
        try validatePrivateDirectory(dir, io);
        self.* = .{ .io = io, .paths = .{ .kind = .mysql }, .store_dir = dir, .lock_file = null };
        var canonical: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const runtime = canonical[0..try dir.realPath(io, &canonical)];
        self.paths.scratch.len = (try std.fmt.bufPrint(&self.paths.scratch.bytes, "{s}/scratch", .{runtime})).len;
        try self.paths.socket.set(socket_path);
    }

    pub noinline fn prepareForServing(self: *StoreLease, fault_cleanup: bool) !void {
        var scratch = try self.store_dir.createDirPathOpen(self.io, "scratch", .{
            .permissions = .fromMode(0o700),
            .open_options = .{ .iterate = true },
        });
        defer scratch.close(self.io);
        try validatePrivateDirectory(scratch, self.io);
        try cleanupOwnedIngress(&scratch, self.io, fault_cleanup);
        self.store_dir.deleteFile(self.io, stop_record_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Writes the Host's stop record. An empty record is a plain stop, as
    /// every earlier Host wrote; a draining pause writes its state, then its
    /// outcome (`host_drain.Record`).
    pub fn recordStop(self: *StoreLease, text: []const u8) !void {
        const record = try self.store_dir.createFile(self.io, stop_record_name, .{ .permissions = .fromMode(0o600), .truncate = true });
        defer record.close(self.io);
        try record.writeStreamingAll(self.io, text);
    }

    pub const LastStop = @import("host_restart.zig").LastStop;

    pub fn lastStop(io: std.Io, supplied_path: []const u8) LastStop {
        const asked = stopRecord(io, supplied_path).wasAsked() orelse return .unknown;
        return if (asked) .asked else .unasked;
    }

    /// What the last Host's stop record says; read after the lease is free.
    /// The one reader of the record: a record that is not a plain file is unreadable.
    pub fn stopRecord(io: std.Io, supplied_path: []const u8) @import("host_drain.zig").Record {
        const selected = resolveClientSelection(supplied_path);
        const paths = selected.paths(io) catch return .unreadable;
        const directory = if (paths.kind == .mysql) paths.runtimeHint().? else paths.store_identity.slice();
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{}) catch return .unreadable;
        defer dir.close(io);
        const stat = dir.statFile(io, stop_record_name, .{ .follow_symlinks = false }) catch |err| return switch (err) {
            error.FileNotFound => .absent,
            else => .unreadable,
        };
        if (stat.kind != .file) return .unreadable;
        var buffer: [32]u8 = undefined;
        const bytes = dir.readFile(io, stop_record_name, &buffer) catch return .unreadable;
        return .parse(bytes);
    }

    pub fn release(self: *StoreLease) void {
        if (self.lock_file) |lock| lock.close(self.io);
        self.store_dir.close(self.io);
        self.* = undefined;
    }
};

pub const ClientSelection = union(enum) {
    directory: []const u8,
    mysql: struct { store_identity: []const u8, runtime: []const u8 },

    pub fn paths(self: ClientSelection, io: std.Io) !Paths {
        switch (self) {
            .mysql => |value| return mysqlClientPaths(io, value.store_identity, value.runtime),
            .directory => |path| {
                // Preserve the directory's admission before reading its saved placement.
                var canonical: [protocol.max_store_bytes]u8 = undefined;
                const host = try existingStoreDestination(io, path, &canonical);
                return savedPlacement(io, host) catch |err| switch (err) {
                    // A ready default Host remains attachable if its saved
                    // startup document was edited to an invalid value. Only a
                    // new start admits that document; never guess moved paths.
                    error.SettingsInvalid => return pathsForCanonicalStore(host),
                    else => return err,
                };
            },
        }
    }
};

pub fn resolveClientSelection(supplied_path: []const u8) ClientSelection {
    const hint = if (std.c.getenv("RUI_RUNTIME_DIR")) |value| std.mem.span(value) else null;
    return clientSelection(supplied_path, hint);
}

fn clientSelection(supplied_path: []const u8, runtime_hint: ?[]const u8) ClientSelection {
    return switch (@import("store_target.zig").resolveKind(supplied_path, runtime_hint)) {
        .mysql => .{ .mysql = .{ .store_identity = supplied_path, .runtime = runtime_hint.? } },
        .sqlite => .{ .directory = supplied_path },
    };
}

pub fn resolveClientPaths(io: std.Io, supplied_path: []const u8) !Paths {
    return resolveClientSelection(supplied_path).paths(io);
}

pub fn mysqlRuntimeDirectory(store: []const u8) ?[]const u8 {
    return switch (resolveClientSelection(store)) {
        .directory => null,
        .mysql => |value| value.runtime,
    };
}

/// A routing hint, not Store authority: the Host checks `store` on every call.
pub noinline fn mysqlClientPaths(io: std.Io, store: []const u8, runtime: []const u8) !Paths {
    if (!validStoreId(store) or !std.fs.path.isAbsolute(runtime)) return error.InvalidStorePath;
    return privateInterfacePaths(io, .mysql, store, runtime, .refuse);
}

/// Every explicit-interface lookup admits an existing directory before any
/// connection. Saved placement may name a directory the starter has yet to
/// create; the legacy opaque-id lookup still requires an existing runtime.
const MissingInterface = enum { allow, refuse };

fn validateInterfaceDirectory(io: std.Io, runtime: []const u8, missing: MissingInterface) !void {
    var dir = std.Io.Dir.cwd().openDir(io, runtime, .{}) catch |err| {
        if (err == error.FileNotFound and missing == .allow) return;
        return err;
    };
    defer dir.close(io);
    try validatePrivateDirectory(dir, io);
}

fn privateInterfacePaths(io: std.Io, kind: Kind, store: []const u8, runtime: []const u8, missing: MissingInterface) !Paths {
    try validateInterfaceDirectory(io, runtime, missing);
    var paths: Paths = .{ .kind = kind };
    try paths.store_identity.set(store);
    try setInterfacePaths(&paths, runtime);
    return paths;
}

fn setInterfacePaths(paths: *Paths, runtime: []const u8) !void {
    paths.socket.len = (try std.fmt.bufPrint(&paths.socket.bytes, "{s}/rui.sock", .{runtime})).len;
    paths.scratch.len = (try std.fmt.bufPrint(&paths.scratch.bytes, "{s}/scratch", .{runtime})).len;
}

pub fn anchorPlacement(io: std.Io, settings: *hs.Settings, dir: []const u8, failure: *start_report.Failure) !void {
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const host = try canonicalStoreDestination(io, dir, &canonical);
    if (settings.store == .mysql and settings.interface.dir.anchored) {
        var runtime: [max_interface_directory_bytes]u8 = undefined;
        try settings.interface.dir.text.set(try interfaceFor(host, &runtime));
        settings.interface.dir.anchored = false;
    }
    hs.anchor(settings, host) catch {
        failure.* = .init(.settings_invalid, "store.sqlite.dir: Host directory exceeds the path byte bound");
        return error.SettingsInvalid;
    };
    if (settings.store == .sqlite) {
        var selected: [protocol.max_store_bytes]u8 = undefined;
        const directory = try canonicalStoreDestination(io, settings.store.sqlite.dir.slice(), &selected);
        try settings.store.sqlite.dir.text.set(directory);
    }
}

/// Read saved placement without a login or a running Host. A MySQL result has
/// no identity yet; the client learns it through the existing host-info door.
pub noinline fn savedPlacement(io: std.Io, dir: []const u8) !Paths {
    var wiping: @import("secret_value.zig").WipingAllocator = .{ .backing = std.heap.c_allocator };
    var arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer arena.deinit();
    const settings = try arena.allocator().create(hs.Settings);
    settings.* = .{};
    defer settings.deinit();
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const host = try canonicalStoreDestination(io, dir, &canonical);
    var failure: start_report.Failure = undefined;
    _ = try @import("host_settings_file.zig").read(io, arena.allocator(), arena.allocator(), host, settings, &failure);
    try anchorPlacement(io, settings, host, &failure);
    var paths = try placementPaths(io, settings);
    try paths.host_directory.set(host);
    return paths;
}

pub noinline fn placementPaths(io: std.Io, settings: *const @import("host_settings.zig").Settings) !Paths {
    if (settings.store == .mysql) return privateInterfacePaths(io, .mysql, "", settings.interface.dir.slice(), .allow);
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    var paths = try pathsForCanonicalStore(try canonicalStoreDestination(io, settings.store.sqlite.dir.slice(), &canonical));
    if (!settings.interface.dir.anchored) {
        try validateInterfaceDirectory(io, settings.interface.dir.slice(), .allow);
        try setInterfacePaths(&paths, settings.interface.dir.slice());
    }
    return paths;
}

pub noinline fn sqliteClientPaths(io: std.Io, supplied_path: []const u8) !Paths {
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
    var buffer: [protocol.max_store_bytes]u8 = undefined;
    _ = try canonicalStoreDestination(io, supplied_path, &buffer);
}

pub noinline fn canonicalStoreDestination(io: std.Io, supplied_path: []const u8, buffer: *[protocol.max_store_bytes]u8) ![]const u8 {
    if (supplied_path.len == 0 or !std.unicode.utf8ValidateSlice(supplied_path)) return error.InvalidStorePath;
    for (supplied_path) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidStorePath;
    return existingStoreDestination(io, supplied_path, buffer) catch |err| switch (err) {
        error.FileNotFound => missingStoreDestination(io, supplied_path, buffer),
        else => err,
    };
}

noinline fn existingStoreDestination(io: std.Io, supplied_path: []const u8, buffer: *[protocol.max_store_bytes]u8) ![]const u8 {
    const paths = try sqliteClientPaths(io, supplied_path);
    @memcpy(buffer[0..paths.store_identity.len], paths.store_identity.slice());
    return buffer[0..paths.store_identity.len];
}
noinline fn missingStoreDestination(io: std.Io, supplied_path: []const u8, buffer: *[protocol.max_store_bytes]u8) ![]const u8 {
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
        @memcpy(buffer[0..length], canonical[0..length]);
        return buffer[0..length];
    }
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
    return pathsForCanonicalStore(canonical_buffer[0..canonical_length]);
}

// Construction scratch does not belong to a caller retaining other Paths.
noinline fn pathsForCanonicalStore(canonical: []const u8) !Paths {
    try validateCanonicalPath(canonical);
    var paths: Paths = .{};
    try paths.host_directory.set(canonical);
    try paths.store_identity.set(canonical);
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

pub fn runtimeDirectory(buffer: []u8) ![]const u8 {
    return runtimeDirectoryForUid(buffer, @intCast(std.c.geteuid()));
}

fn runtimeDirectoryForUid(buffer: []u8, uid: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}{d}", .{ runtime_prefix, uid });
}

/// The interface directory Rui derives for a canonical Host directory, the
/// same for SQLite and MySQL: `<runtime>/<first 16 SHA-256 bytes in hex>`.
/// `host_endpoint` owns what lives in it.
pub fn interfaceFor(canonical: []const u8, buffer: []u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hash_text = std.fmt.bytesToHex(digest[0..16].*, .lower);
    var runtime_buffer: [max_runtime_directory_bytes]u8 = undefined;
    const runtime = try runtimeDirectory(&runtime_buffer);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ runtime, hash_text });
}

fn socketPathForCanonical(canonical: []const u8, buffer: []u8) ![]const u8 {
    var interface: [max_interface_directory_bytes]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ try interfaceFor(canonical, &interface), hs.socket_name });
}

fn validatePrivateDirectory(dir: std.Io.Dir, io: std.Io) !void {
    const stat = try dir.stat(io);
    if (stat.kind != .directory) return error.NotDirectory;
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureDirectoryPermissions;
}

fn cleanupOwnedIngress(scratch: *std.Io.Dir, io: std.Io, fault_cleanup: bool) !void {
    var iterator = scratch.iterate();
    while (try iterator.next(io)) |entry| {
        if (!named_scratch.isOwned(entry.name)) continue;
        if (entry.kind != .file) return error.UnexpectedIngressLeftover;
        if (fault_cleanup) return error.InjectedCleanupFailure;
        try scratch.deleteFile(io, entry.name);
    }
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
    try std.testing.expectEqualStrings(one.store_identity.slice(), two.store_identity.slice());
    try std.testing.expectEqualStrings(one.socket.slice(), two.socket.slice());
}

test "Store lease observation owns probe mechanics and releases every descriptor" {
    const io = std.testing.io;
    const descriptors = @import("os/descriptor_limit.zig");
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
            try std.testing.expectEqualStrings(lease.paths.store_identity.slice(), observation.owned.store_identity.slice());
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

test "the stop record reads asked only when present as a file, and unknown when unreadable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store", .{root});
    try std.testing.expectEqual(StoreLease.LastStop.unknown, StoreLease.lastStop(io, path));
    {
        var lease = try StoreLease.acquire(io, path);
        defer lease.release();
        try std.testing.expectEqual(StoreLease.LastStop.unasked, StoreLease.lastStop(io, path));
        try lease.recordStop("");
        try lease.recordStop("");
    }
    try std.testing.expectEqual(StoreLease.LastStop.asked, StoreLease.lastStop(io, path));
    try tmp.dir.deleteFile(io, "store/" ++ stop_record_name);
    try std.testing.expectEqual(StoreLease.LastStop.unasked, StoreLease.lastStop(io, path));
    try tmp.dir.createDir(io, "store/" ++ stop_record_name, .default_dir);
    try std.testing.expectEqual(StoreLease.LastStop.unknown, StoreLease.lastStop(io, path));
    try tmp.dir.deleteDir(io, "store/" ++ stop_record_name);
    try tmp.dir.symLink(io, "host.lock", "store/" ++ stop_record_name, .{});
    try std.testing.expectEqual(StoreLease.LastStop.unknown, StoreLease.lastStop(io, path));
    try tmp.dir.deleteFile(io, "store/" ++ stop_record_name);
}

test "socket path uses the first 16 SHA-256 bytes in lowercase hex" {
    var buffer: [max_socket_path_bytes]u8 = undefined;
    const path = try socketPathForCanonical("/tmp/rui-stdlib-hex", &buffer);
    try std.testing.expect(std.mem.endsWith(u8, path, "/043ea4efef72c68973ebffcb0927e537/rui.sock"));
}

test "absent destination preflight checks components but bounds canonical aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var path_buffer: [2048]u8 = undefined;
    const overlong = try std.fmt.bufPrint(&path_buffer, "{s}/missing/{s}", .{ root, &@as([256]u8, @splat('x')) });
    try std.testing.expectError(error.NameTooLong, validateStoreDestination(std.testing.io, overlong));
    const canceled = try std.fmt.bufPrint(&path_buffer, "{s}/missing/{s}/../../store", .{ root, &@as([256]u8, @splat('x')) });
    try std.testing.expectError(error.NameTooLong, validateStoreDestination(std.testing.io, canceled));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(std.testing.io, "missing", .{}));
    const alias = try std.fmt.bufPrint(&path_buffer, "{s}/new/{s}store", .{ root, &@as([520]u8, @bitCast(@as([260][2]u8, @splat("./".*)))) });
    try validateStoreDestination(std.testing.io, alias);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(std.testing.io, "new", .{}));
    var lease = try StoreLease.acquire(std.testing.io, alias);
    defer lease.release();
    var expected_buffer: [protocol.max_store_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{s}/new/store", .{root});
    try std.testing.expectEqualStrings(expected, lease.paths.store_identity.slice());
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
    const descriptors = @import("os/descriptor_limit.zig");
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
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const target = @import("os").read_only_directory ++ "/rui-preflight-never-created";
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
    try std.testing.expectEqual(@as(usize, 61), max_socket_path_bytes);
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
    try std.testing.expectEqual(@as(usize, protocol.max_store_bytes), accepted.store_identity.len);
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
    try std.testing.expectEqualStrings(expected, lease.paths.store_identity.slice());
    lease.release();
}

test "invalid UTF-8 Store path remains distinct from path overflow" {
    try std.testing.expectError(error.InvalidStorePath, validateCanonicalPath(&.{0xff}));
    const overlong = @as([protocol.max_store_bytes + 1]u8, @splat('a'));
    try std.testing.expectError(error.StorePathTooLong, validateCanonicalPath(&overlong));
}

test "startup cleanup recognizes only owned ingress names" {
    try std.testing.expect(named_scratch.isOwned("request-12-2.tmp"));
    try std.testing.expect(named_scratch.isOwned("provider-request-12-2.tmp"));
    try std.testing.expect(named_scratch.isOwned("response-12-2.tmp"));
    try std.testing.expect(named_scratch.isOwned("response-metadata-12-2.tmp"));
    try std.testing.expect(named_scratch.isOwned("bash-stdout-12-2.tmp"));
    try std.testing.expect(named_scratch.isOwned("bash-stderr-12-2.tmp"));
    try std.testing.expect(named_scratch.isOwned("mcp-output-12-2.tmp"));
    try std.testing.expect(named_scratch.isOwned("report-12-2.tmp"));
    inline for (.{ "request-", "provider-request-", "response-", "response-metadata-", "bash-stdout-", "bash-stderr-", "mcp-output-", "report-" }) |prefix| {
        var name_buffer: [64]u8 = undefined;
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}-2.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}2-.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}--.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}x-2.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}12-x.tmp", .{prefix})));
        try std.testing.expectEqual(
            std.mem.eql(u8, prefix, "request-") or std.mem.eql(u8, prefix, "report-"),
            named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}0-2.tmp", .{prefix})),
        );
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}2-0.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}00-2.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}02-2.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}18446744073709551616-2.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}2-18446744073709551616.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}999999999999999999999999999999-2.tmp", .{prefix})));
        try std.testing.expect(!named_scratch.isOwned(try std.fmt.bufPrint(&name_buffer, "{s}2-999999999999999999999999999999.tmp", .{prefix})));
    }
    try std.testing.expect(!named_scratch.isOwned("response-secret.tmp"));
    try std.testing.expect(!named_scratch.isOwned("canonical.sqlite3"));
}

test "startup cleanup removes owned files and preserves lookalikes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owned = [_][]const u8{
        "request-0-1.tmp",
        "provider-request-1-1.tmp",
        "response-1-1.tmp",
        "response-metadata-2-1.tmp",
        "bash-stdout-3-1.tmp",
        "bash-stderr-3-1.tmp",
        "mcp-output-4-1.tmp",
        "report-0-1.tmp",
    };
    const preserved = [_][]const u8{
        "request-00-1.tmp",
        "request-1-0.tmp",
        "request-1-1.tmp.extra",
        "request-1-1",
        "request-x-1.tmp",
        "request-1-1-1.tmp",
        "provider-request-0-1.tmp",
        "provider-request-01-1.tmp",
        "provider-request-1-1.tmp.extra",
        "mcp-output-0-1.tmp",
        "mcp-output-01-1.tmp",
        "mcp-output-1-0.tmp",
        "mcp-output-1-1.tmp.extra",
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
    const name = "report-17-1.tmp";
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
    var tmp = try @import("socket_fixture.zig").Directory.init();
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

    var socket_path_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const address = try tmp.address("response-1-1.tmp", &socket_path_buffer);
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

test "MySQL runtime lease owns no host.lock and routes an opaque Store id" {
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    var socket_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const address = try tmp.address("rui.sock", &socket_buffer);
    const runtime = tmp.root[0..tmp.root_len];
    var lease: StoreLease = undefined;
    try lease.acquireMysql(std.testing.io, runtime, address.path);
    defer lease.release();
    try lease.prepareForServing(false);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "host.lock", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "rui.sqlite3", .{}));
    try std.testing.expectEqual(std.Io.File.Kind.directory, (try tmp.dir.statFile(std.testing.io, "scratch", .{})).kind);
    const id = "0123456789abcdef0123456789abcdef";
    const paths = try mysqlClientPaths(std.testing.io, id, runtime);
    try std.testing.expectEqual(.mysql, paths.kind);
    try std.testing.expectEqual(.mysql, lease.paths.kind);
    try std.testing.expectEqualStrings(runtime, paths.runtimeHint().?);
    try std.testing.expectEqualStrings(runtime, paths.diagnosticsDirectory());
    try std.testing.expectEqualStrings(id, paths.store_identity.slice());
    try std.testing.expectEqualStrings(address.path, paths.socket.slice());
    try std.testing.expectEqualStrings(lease.paths.scratch.slice(), paths.scratch.slice());
    try std.testing.expect(!validStoreId("/sqlite/store"));
    try std.testing.expect(!validStoreId("0123456789abcdef0123456789abcdeF"));
}

test "Store target paths keep SQLite routing with a separately launched runtime" {
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const io = std.testing.io;
    var lease = try StoreLease.acquire(io, tmp.root[0..tmp.root_len]);
    defer lease.release();
    try tmp.dir.createDir(io, "runtime", .fromMode(0o700));
    var runtime_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const runtime = (try tmp.address("runtime", &runtime_buffer)).path;
    var socket_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const socket = try std.fmt.bufPrint(&socket_buffer, "{s}/rui.sock", .{runtime});
    try lease.paths.socket.set(socket);
    try lease.prepareForServing(false);
    try std.testing.expectEqual(.sqlite, lease.paths.kind);
    try std.testing.expectEqual(@as(?[]const u8, null), lease.paths.runtimeHint());
    try std.testing.expectEqualStrings(lease.paths.store_identity.slice(), lease.paths.diagnosticsDirectory());
    try std.testing.expectEqualStrings(socket, lease.paths.socket.slice());
}

test "Store target paths refuse invalid runtime hints without SQLite fallback" {
    const id = "0123456789abcdef0123456789abcdef";
    for ([_][]const u8{ "", "relative" }) |hint| {
        const selected = clientSelection(id, hint);
        try std.testing.expect(selected == .mysql);
        try std.testing.expectError(error.InvalidStorePath, selected.paths(std.testing.io));
    }
}

test "runtime socket storage preserves every non-NUL OS byte" {
    var paths: Paths = .{};
    for (1..256) |value| {
        const byte: [1]u8 = .{@intCast(value)};
        try paths.socket.set(&byte);
        try std.testing.expectEqualSlices(u8, &byte, paths.socket.slice());
    }
    try std.testing.expectError(error.SettingsInvalid, paths.socket.set(&.{0}));
    try std.testing.expectEqualSlices(u8, &.{255}, paths.socket.slice());
    const over: [@max(max_socket_path_bytes, max_launch_socket_path_bytes) + 1]u8 = @splat('x');
    try std.testing.expectError(error.SettingsInvalid, paths.socket.set(&over));
    try std.testing.expectEqualSlices(u8, &.{255}, paths.socket.slice());
}

test "saved and legacy explicit interfaces share private directory admission before lookup" {
    const io = std.testing.io;
    var host = try @import("socket_fixture.zig").Directory.init();
    defer host.cleanup();
    var runtime = try @import("socket_fixture.zig").Directory.init();
    defer runtime.cleanup();
    const directory = runtime.root[0..runtime.root_len];
    const settings = try std.testing.allocator.create(hs.Settings);
    defer std.testing.allocator.destroy(settings);
    const id = "0123456789abcdef0123456789abcdef";
    for ([_]u16{ 0o700, 0o755, 0o777, 0o000 }) |mode| {
        errdefer std.debug.print("explicit interface admission: mode={o}\n", .{mode});
        try runtime.dir.setPermissions(io, .fromMode(mode));
        defer runtime.dir.setPermissions(io, .fromMode(0o700)) catch @panic("restore interface privacy");
        for ([_]enum { legacy_mysql, saved_mysql, moved_sqlite }{ .legacy_mysql, .saved_mysql, .moved_sqlite }) |door| {
            errdefer std.debug.print("explicit interface admission: lookup={s}\n", .{@tagName(door)});
            settings.* = .{};
            defer settings.deinit();
            try settings.interface.dir.text.set(directory);
            settings.interface.dir.anchored = false;
            if (door == .saved_mysql) settings.store = .{ .mysql = .{} } else try settings.store.sqlite.dir.text.set(host.root[0..host.root_len]);
            const paths = if (door == .legacy_mysql) mysqlClientPaths(io, id, directory) else placementPaths(io, settings);
            // Privacy and path-open authority are independent. The owned
            // descriptor proves mode 000 is private on every OS, but Darwin's
            // O_RDONLY directory open (unlike Linux O_PATH) requires read access.
            if (mode == 0) {
                try validatePrivateDirectory(runtime.dir, io);
                if (@hasField(std.posix.O, "PATH")) {
                    _ = try paths;
                } else {
                    try std.testing.expectError(error.AccessDenied, paths);
                }
            } else if (mode == 0o700) {
                _ = try paths;
            } else {
                try std.testing.expectError(error.InsecureDirectoryPermissions, paths);
            }
        }
    }
    settings.* = .{};
    defer settings.deinit();
    var missing_buffer: [hs.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buffer, "{s}/not-created", .{directory});
    try settings.interface.dir.text.set(missing);
    settings.interface.dir.anchored = false;
    for ([_]Kind{ .sqlite, .mysql }) |kind| {
        if (kind == .mysql) settings.store = .{ .mysql = .{} } else try settings.store.sqlite.dir.text.set(host.root[0..host.root_len]);
        const paths = try placementPaths(io, settings);
        try std.testing.expectEqual(kind, paths.kind);
        try std.testing.expect(std.mem.startsWith(u8, paths.socket.slice(), missing));
    }
    try std.testing.expectError(error.FileNotFound, mysqlClientPaths(io, id, missing));
    try std.testing.expectError(error.FileNotFound, runtime.dir.access(io, "not-created", .{}));
}
