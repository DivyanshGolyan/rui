//! Sole owner of a Host's endpoint: the interface directory D, its `rui.lock`
//! and its `rui.sock`. Every Host serves from `D/rui.sock` while it holds
//! `D/rui.lock` exclusively, as the inode D names, from before it touches the
//! socket until after it unlinks it. A lock this process holds and verifies is
//! a kernel fact that no Host of any release serves D: new Hosts bind only
//! under it, older MySQL and explicit-directory Hosts bind only under a flock
//! on the same file, and older SQLite Hosts never bind inside a derived D.
//! So only the holder of that lock unlinks a Host socket, and whoever can hold
//! it (a starting Host, the upgrade census) may remove a dead endpoint.
const std = @import("std");
const c = @import("posix");
const platform = @import("platform.zig");
const host_settings = @import("host_settings.zig");

pub const lock_name = "rui.lock";
pub const socket_name = host_settings.socket_name;

/// Bounded so `D/rui.sock` fits Darwin's 104-byte `sun_path`.
pub const Path = host_settings.OsBytes(host_settings.max_runtime_dir_bytes);

/// Where D comes from. A derived D, a 32-lowercase-hex child of the per-user
/// runtime directory, is Rui's: it is censused, swept and removed once empty.
/// Any other (a configured `interface.dir`) belongs to the user, and only
/// Rui's two files in it are ever removed.
pub const Interface = union(enum) {
    derived: Path,
    configured: Path,

    /// The one classification, shared with `census`: the shape of the path
    /// decides, so a Host and a census never disagree about who owns D.
    pub fn init(directory: []const u8) !Interface {
        var buffer: [platform.max_runtime_directory_bytes]u8 = undefined;
        return within(try platform.runtimeDirectory(&buffer), directory);
    }

    fn within(runtime: []const u8, directory: []const u8) !Interface {
        var bytes: Path = .{};
        try bytes.set(directory);
        const parent = std.fs.path.dirname(directory) orelse "";
        return if (std.mem.eql(u8, parent, runtime) and derivedName(std.fs.path.basename(directory)))
            .{ .derived = bytes }
        else
            .{ .configured = bytes };
    }

    pub fn path(self: *const Interface) []const u8 {
        return switch (self.*) {
            inline else => |*bytes| bytes.slice(),
        };
    }
};

fn derivedName(name: []const u8) bool {
    if (name.len != 32) return false;
    for (name) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

/// Proof, held in this process, that `D/rui.lock` is locked exclusively by this
/// open file description and is the inode D names now. Only `lockVerified`
/// makes one, and every unlink of a Host socket or lock in Rui takes one.
const Held = struct {
    dir: std.Io.Dir,
    lock: std.Io.File,

    /// Unlinks `D/rui.sock` when it is a Unix socket. Anything else at that
    /// name is not Rui's and stays.
    fn clearSocket(self: *const Held, io: std.Io) !void {
        const stat = self.dir.statFile(io, socket_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .unix_domain_socket) return error.UnexpectedSocketPath;
        self.dir.deleteFile(io, socket_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// The one teardown. The socket goes before the lock file, so Rui never
    /// leaves `rui.sock` without `rui.lock`; a derived D goes last and only
    /// when empty (MySQL scratch, diagnostics and `host.stopped` stay). A crash
    /// or failure at any step leaves a free or absent lock, which the next
    /// census or claim proves and finishes. Always releases the lock.
    fn dissolve(self: *Held, io: std.Io, interface: *const Interface) !void {
        defer self.release(io);
        try self.clearSocket(io);
        self.dir.deleteFile(io, lock_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (interface.* == .derived) std.Io.Dir.cwd().deleteDir(io, interface.path()) catch |err| switch (err) {
            error.FileNotFound, error.DirNotEmpty => {},
            else => return err,
        };
    }

    /// Closing the lock's only descriptor is all SIGKILL does, too.
    fn release(self: *Held, io: std.Io) void {
        self.lock.close(io);
        self.dir.close(io);
        self.* = undefined;
    }
};

const LockResult = union(enum) {
    held: Held,
    /// Another open file description holds the lock: a Host that claimed D, or
    /// an inspect taking it for a moment; or the lock was replaced while this
    /// call took it.
    busy,
    /// D is gone, or it has no `rui.lock` and `create` was false.
    absent,
    /// D or `rui.lock` is not a private same-owner directory and file.
    unusable: anyerror,
};

/// The single decision point for endpoint ownership.
fn lockVerified(io: std.Io, directory: []const u8, create: bool) LockResult {
    const dir = std.Io.Dir.cwd().openDir(io, directory, .{}) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .{ .unusable = err },
    };
    var kept = false;
    defer if (!kept) dir.close(io);
    const dir_stat = privateDirectory(dir.handle) catch |err| return .{ .unusable = err };
    // A hostile FIFO must not block the open; never follow a planted link.
    const fd = std.posix.openat(dir.handle, lock_name, .{
        .ACCMODE = .RDONLY,
        .CREAT = create,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .{ .unusable = err },
    };
    const lock: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer if (!kept) lock.close(io);
    _ = ownStat(fd, .file) catch |err| return .{ .unusable = err };
    switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => {},
        .AGAIN => return .busy,
        else => return .{ .unusable = error.EndpointLockFailed },
    }
    // flock belongs to an inode. A lock on a file someone unlinked (and maybe
    // recreated) after our open, or in a D replaced since, proves nothing.
    if (!namesLock(io, dir.handle, fd) or !namesDirectory(io, directory, &dir_stat)) return .busy;
    kept = true;
    return .{ .held = .{ .dir = dir, .lock = lock } };
}

fn ownStat(fd: std.posix.fd_t, kind: enum { directory, file }) !c.struct_stat {
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.EndpointStatFailed;
    const format = stat.st_mode & c.S_IFMT;
    const expected = switch (kind) {
        .directory => format == c.S_IFDIR,
        .file => format == c.S_IFREG,
    };
    if (!expected or stat.st_uid != c.geteuid()) return error.UnexpectedEndpointNode;
    return stat;
}

fn privateDirectory(fd: std.posix.fd_t) !c.struct_stat {
    const stat = try ownStat(fd, .directory);
    if (stat.st_mode & 0o077 != 0) return error.InsecureDirectoryPermissions;
    return stat;
}

fn sameNode(a: *const c.struct_stat, b: *const c.struct_stat) bool {
    return a.st_dev == b.st_dev and a.st_ino == b.st_ino;
}

fn namesLock(io: std.Io, dir: std.posix.fd_t, fd: std.posix.fd_t) bool {
    var held: c.struct_stat = undefined;
    if (c.fstat(fd, &held) != 0 or held.st_nlink == 0) return false;
    const named = std.posix.openat(dir, lock_name, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return false;
    const file: std.Io.File = .{ .handle = named, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    var current: c.struct_stat = undefined;
    return c.fstat(named, &current) == 0 and sameNode(&held, &current);
}

fn namesDirectory(io: std.Io, directory: []const u8, opened: *const c.struct_stat) bool {
    const dir = std.Io.Dir.cwd().openDir(io, directory, .{}) catch return false;
    defer dir.close(io);
    var current: c.struct_stat = undefined;
    return c.fstat(dir.handle, &current) == 0 and sameNode(opened, &current);
}

/// A Host's endpoint, from `claim` until `retire`.
pub const Endpoint = struct {
    io: std.Io,
    interface: Interface,
    held: ?Held,

    pub fn socketPath(self: *const Endpoint, buffer: *[std.Io.net.UnixAddress.max_len]u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.interface.path(), socket_name });
    }

    /// Clears a socket a dead Host left at `D/rui.sock`, binds, listens and
    /// sets mode 0600. A SQLite caller already holds its Store's lease, so no
    /// older Host of that Store serves here either.
    pub fn listen(self: *Endpoint, options: std.Io.net.UnixAddress.ListenOptions) !std.Io.net.Server {
        const held = &self.held.?;
        try held.clearSocket(self.io);
        var buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
        const address = try std.Io.net.UnixAddress.init(try self.socketPath(&buffer));
        var server = try address.listen(self.io, options);
        errdefer server.deinit(self.io);
        // A directory descriptor names the socket the bind just made, whatever
        // happens to the path; D is private, so the window before is too.
        if (c.fchmodat(held.dir.handle, socket_name, 0o600, 0) != 0) return error.SocketProtectionFailed;
        return server;
    }

    /// A stopping Host closed its listener: unlink the socket and keep the
    /// lock, which still tells status readers a Host owns D until it exits.
    pub fn unbind(self: *Endpoint) !void {
        if (self.held) |*held| try held.clearSocket(self.io);
    }

    /// Idempotent; every exit path calls it. A failed unlink is left for the
    /// next census or claim, which can prove it dead.
    pub fn retire(self: *Endpoint) !void {
        var held = self.held orelse return;
        self.held = null;
        try held.dissolve(self.io, &self.interface);
    }
};

/// The window a Host start waits for an inspect (a census look), which holds
/// the lock for microseconds, before it reports the directory in use.
const claim_wait_ns = 100 * std.time.ns_per_ms;

/// Host start: creates D (0700) and holds its lock. Does not touch `rui.sock`;
/// that waits for `listen`, after the caller owns its Store.
pub fn claim(io: std.Io, interface: Interface) error{ RuntimeDirectoryInUse, RuntimeDirectoryUnusable }!Endpoint {
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + claim_wait_ns;
    while (true) {
        createDirectory(io, &interface) catch return error.RuntimeDirectoryUnusable;
        switch (lockVerified(io, interface.path(), true)) {
            .held => |held| return .{ .io = io, .interface = interface, .held = held },
            .unusable => return error.RuntimeDirectoryUnusable,
            // `absent`: a census removed the empty D between our mkdir and open.
            .busy, .absent => {
                if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= until) return error.RuntimeDirectoryInUse;
                std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .awake) catch return error.RuntimeDirectoryInUse;
            },
        }
    }
}

fn createDirectory(io: std.Io, interface: *const Interface) !void {
    const directory = interface.path();
    if (interface.* == .configured) {
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, directory, .{ .permissions = .fromMode(0o700) });
        dir.close(io);
        return;
    }
    const runtime = try std.Io.Dir.cwd().createDirPathOpen(io, std.fs.path.dirname(directory).?, .{ .permissions = .fromMode(0o700) });
    defer runtime.close(io);
    _ = try privateDirectory(runtime.handle);
    runtime.createDir(io, std.fs.path.basename(directory), .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// What one look at an interface directory found.
pub const Sighting = enum {
    /// This call proved the endpoint dead and removed it.
    reclaimed,
    /// D, or its lock and socket, were already gone.
    vanished,
    /// Someone holds the lock: a live or starting Host. Probe its socket.
    busy,
    /// A socket without a lock file, or a node Rui did not make. Rui never
    /// leaves this state, and never removes it.
    unprovable,
};

/// Takes the lock without creating it; a held lock is dissolved. Never blocks.
pub fn inspect(io: std.Io, interface: *const Interface) Sighting {
    switch (lockVerified(io, interface.path(), false)) {
        .held => |value| {
            var held = value;
            held.dissolve(io, interface) catch return .unprovable;
            return .reclaimed;
        },
        .busy => return .busy,
        .unusable => return .unprovable,
        .absent => {
            const dir = std.Io.Dir.cwd().openDir(io, interface.path(), .{}) catch |err| return switch (err) {
                error.FileNotFound => .vanished,
                else => .unprovable,
            };
            defer dir.close(io);
            if (dir.statFile(io, socket_name, .{ .follow_symlinks = false })) |_| return .unprovable else |err| switch (err) {
                error.FileNotFound => {},
                else => return .unprovable,
            }
            if (interface.* == .derived) std.Io.Dir.cwd().deleteDir(io, interface.path()) catch {};
            return .vanished;
        },
    }
}

/// The upgrade census: inspects every derived D of this user, removing the
/// dead ones, and returns the socket paths of the rest (sorted, owned by the
/// caller). Flat sockets of older releases are not endpoints and stay; the
/// process census finds a live Host there.
pub fn census(allocator: std.mem.Allocator, io: std.Io) ![][]u8 {
    var buffer: [platform.max_runtime_directory_bytes]u8 = undefined;
    return censusIn(allocator, io, try platform.runtimeDirectory(&buffer), null);
}

/// Host start, best effort: the census without its report, skipping this
/// Host's own D, so killed Hosts' endpoints do not pile up between upgrades.
pub noinline fn sweepNeighbors(allocator: std.mem.Allocator, own: *const Endpoint) void {
    var buffer: [platform.max_runtime_directory_bytes]u8 = undefined;
    const runtime = platform.runtimeDirectory(&buffer) catch return;
    const found = censusIn(allocator, own.io, runtime, own.interface.path()) catch return;
    freeSockets(allocator, found);
}

pub fn freeSockets(allocator: std.mem.Allocator, sockets: []const []u8) void {
    for (sockets) |socket| allocator.free(socket);
    allocator.free(sockets);
}

fn censusIn(allocator: std.mem.Allocator, io: std.Io, runtime: []const u8, skip: ?[]const u8) ![][]u8 {
    const directory = std.Io.Dir.cwd().openDir(io, runtime, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]u8, 0),
        else => return err,
    };
    defer directory.close(io);
    _ = try privateDirectory(directory.handle);
    var found: std.ArrayList([]u8) = .empty;
    errdefer {
        for (found.items) |path| allocator.free(path);
        found.deinit(allocator);
    }
    var entries = directory.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory or !derivedName(entry.name)) continue;
        var interface: Interface = .{ .derived = .{} };
        var path_buffer: [Path.max_bytes]u8 = undefined;
        interface.derived.set(std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ runtime, entry.name }) catch continue) catch continue;
        if (skip != null and std.mem.eql(u8, skip.?, interface.path())) continue;
        switch (inspect(io, &interface)) {
            .reclaimed, .vanished => continue,
            // A Host before its bind has no socket yet; the process census finds it.
            .busy => if (!socketPresent(io, &interface)) continue,
            .unprovable => {},
        }
        try found.ensureUnusedCapacity(allocator, 1);
        found.appendAssumeCapacity(try std.fmt.allocPrint(allocator, "{s}/{s}", .{ interface.path(), socket_name }));
    }
    // Paths are distinct (each names a different directory entry), so an
    // unstable sort gives the same order; pdq needs no stack cache.
    std.mem.sortUnstable([]u8, found.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return found.toOwnedSlice(allocator);
}

fn socketPresent(io: std.Io, interface: *const Interface) bool {
    const dir = std.Io.Dir.cwd().openDir(io, interface.path(), .{}) catch return false;
    defer dir.close(io);
    _ = dir.statFile(io, socket_name, .{ .follow_symlinks = false }) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const socket_fixture = @import("socket_fixture.zig");
const testing = std.testing;

/// What is left in one D, read independently of this module.
const Left = struct {
    directory: bool = true,
    lock: bool = false,
    socket: ?std.Io.File.Kind = null,
    extra: bool = false,
};

fn leftIn(io: std.Io, directory: []const u8) !Left {
    const dir = std.Io.Dir.cwd().openDir(io, directory, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .directory = false },
        else => return err,
    };
    defer dir.close(io);
    var left: Left = .{};
    left.lock = if (dir.statFile(io, lock_name, .{ .follow_symlinks = false })) |_| true else |_| false;
    left.socket = if (dir.statFile(io, socket_name, .{ .follow_symlinks = false })) |stat| stat.kind else |_| null;
    left.extra = if (dir.statFile(io, "extra", .{ .follow_symlinks = false })) |_| true else |_| false;
    return left;
}

const LockState = enum { absent, free, held_elsewhere };
const SocketState = enum { absent, socket, regular, symlink };

/// Builds one D in its row's state. A free lock is a lock file nobody holds,
/// which is what a SIGKILLed holder leaves; `held_elsewhere` returns the
/// other holder's descriptor.
fn arrange(io: std.Io, directory: []const u8, lock: LockState, socket: SocketState, extra: bool) !?std.Io.File {
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, directory, .{ .permissions = .fromMode(0o700) });
    defer dir.close(io);
    var holder: ?std.Io.File = null;
    if (lock != .absent) {
        const file = try dir.createFile(io, lock_name, .{ .read = true, .truncate = false, .permissions = .fromMode(0o600) });
        if (lock == .held_elsewhere) {
            try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.posix.system.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB)));
            holder = file;
        } else file.close(io);
    }
    switch (socket) {
        .absent => {},
        .socket => {
            var buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
            const address = try std.Io.net.UnixAddress.init(try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ directory, socket_name }));
            // A closed listener leaves its node, as a killed Host's does.
            var listener = try address.listen(io, .{});
            listener.deinit(io);
        },
        .regular => (try dir.createFile(io, socket_name, .{})).close(io),
        .symlink => try dir.symLink(io, "elsewhere", socket_name, .{}),
    }
    if (extra) (try dir.createFile(io, "extra", .{})).close(io);
    return holder;
}

fn acceptsConnection(io: std.Io, path: []const u8) bool {
    const address = std.Io.net.UnixAddress.init(path) catch return false;
    const stream = address.connect(io) catch return false;
    stream.close(io);
    return true;
}

const Actor = enum { census, host };

const OwnershipRow = struct {
    lock: LockState,
    socket: SocketState,
    extra: bool,
    /// What a census look reports, and what it leaves.
    sighting: Sighting,
    after: Left,
    /// What `claim` then `listen` does from this state.
    serves: enum { yes, in_use, unexpected_socket },
};

fn ownershipRow(io: std.Io, derived: *const Interface, row: OwnershipRow, actor: Actor) !void {
    const directory = derived.path();
    const holder = try arrange(io, directory, row.lock, row.socket, row.extra);
    defer if (holder) |file| file.close(io);
    if (actor == .census) {
        try testing.expectEqual(row.sighting, inspect(io, derived));
        try testing.expectEqual(row.after, try leftIn(io, directory));
        // The next look finds what the first left: removal is final.
        const again = inspect(io, derived);
        try testing.expect(again == row.sighting or (row.sighting == .reclaimed and again == .vanished));
        return;
    }
    var endpoint = claim(io, derived.*) catch |err| {
        try testing.expectEqual(row.serves, .in_use);
        try testing.expectEqual(error.RuntimeDirectoryInUse, err);
        try testing.expectEqual(row.after, try leftIn(io, directory));
        return;
    };
    var listener = endpoint.listen(.{}) catch |err| {
        try testing.expectEqual(row.serves, .unexpected_socket);
        try testing.expectEqual(error.UnexpectedSocketPath, err);
        try testing.expectError(error.UnexpectedSocketPath, endpoint.retire());
        // A node Rui did not make keeps the lock file, which nobody holds now.
        try testing.expect((try leftIn(io, directory)).lock);
        try testing.expectEqual(Sighting.unprovable, inspect(io, derived));
        return;
    };
    try testing.expectEqual(row.serves, .yes);
    var socket_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const socket = try endpoint.socketPath(&socket_buffer);
    try testing.expect(acceptsConnection(io, socket));
    // Liveness: no look while the holder lives removes its socket.
    try testing.expectEqual(Sighting.busy, inspect(io, derived));
    try testing.expect(acceptsConnection(io, socket));
    listener.deinit(io);
    try endpoint.unbind();
    try testing.expectEqual(Sighting.busy, inspect(io, derived));
    try testing.expectEqual(Left{ .lock = true, .extra = row.extra }, try leftIn(io, directory));
    try endpoint.retire();
    try endpoint.retire();
    try testing.expectEqual(if (row.extra) Left{ .extra = true } else Left{ .directory = false }, try leftIn(io, directory));
}

test "SH-11 only the holder of an interface directory's rui.lock removes its endpoint" {
    const io = testing.io;
    var runtime = try socket_fixture.Directory.init();
    defer runtime.cleanup();
    const root = runtime.root[0..runtime.root_len];
    var directory_buffer: [Path.max_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(&directory_buffer, "{s}/{s}", .{ root, "0123456789abcdef0123456789abcdef" });
    const derived = try Interface.within(root, directory);
    try testing.expect(derived == .derived);
    for ([_][]const u8{ "0123456789abcdef0123456789abcdeF", "0123456789abcdef", "rui.sock", "0123456789abcdef0123456789abcdef0" }) |name| {
        var other: [Path.max_bytes]u8 = undefined;
        try testing.expect(try Interface.within(root, try std.fmt.bufPrint(&other, "{s}/{s}", .{ root, name })) == .configured);
    }
    try testing.expect(try Interface.within(root, root) == .configured);

    // Ownership table. Expected outcomes are the contract's, written out per
    // row: only a lock this call holds lets anything be removed, and only a
    // Unix socket, the lock file and an empty derived D are ever removed.
    const rows = [_]OwnershipRow{
        .{ .lock = .absent, .socket = .absent, .extra = false, .sighting = .vanished, .after = .{ .directory = false }, .serves = .yes },
        .{ .lock = .absent, .socket = .absent, .extra = true, .sighting = .vanished, .after = .{ .extra = true }, .serves = .yes },
        .{ .lock = .absent, .socket = .socket, .extra = false, .sighting = .unprovable, .after = .{ .socket = .unix_domain_socket }, .serves = .yes },
        .{ .lock = .absent, .socket = .regular, .extra = false, .sighting = .unprovable, .after = .{ .socket = .file }, .serves = .unexpected_socket },
        .{ .lock = .absent, .socket = .symlink, .extra = true, .sighting = .unprovable, .after = .{ .socket = .sym_link, .extra = true }, .serves = .unexpected_socket },
        .{ .lock = .free, .socket = .absent, .extra = false, .sighting = .reclaimed, .after = .{ .directory = false }, .serves = .yes },
        .{ .lock = .free, .socket = .socket, .extra = false, .sighting = .reclaimed, .after = .{ .directory = false }, .serves = .yes },
        .{ .lock = .free, .socket = .socket, .extra = true, .sighting = .reclaimed, .after = .{ .extra = true }, .serves = .yes },
        .{ .lock = .free, .socket = .regular, .extra = false, .sighting = .unprovable, .after = .{ .lock = true, .socket = .file }, .serves = .unexpected_socket },
        .{ .lock = .free, .socket = .symlink, .extra = false, .sighting = .unprovable, .after = .{ .lock = true, .socket = .sym_link }, .serves = .unexpected_socket },
        .{ .lock = .held_elsewhere, .socket = .absent, .extra = false, .sighting = .busy, .after = .{ .lock = true }, .serves = .in_use },
        .{ .lock = .held_elsewhere, .socket = .socket, .extra = true, .sighting = .busy, .after = .{ .lock = true, .socket = .unix_domain_socket, .extra = true }, .serves = .in_use },
        .{ .lock = .held_elsewhere, .socket = .regular, .extra = false, .sighting = .busy, .after = .{ .lock = true, .socket = .file }, .serves = .in_use },
    };
    for (rows) |row| for ([_]Actor{ .census, .host }) |actor| {
        errdefer std.debug.print("endpoint ownership row: {any} actor={s}\n", .{ row, @tagName(actor) });
        try ownershipRow(io, &derived, row, actor);
        try std.Io.Dir.cwd().deleteTree(io, directory);
    };

    // Crash points: a Host killed after each step of its life leaves a state
    // the next look proves dead and removes, and the next claim serves from.
    const Step = enum { mkdir, lock_created, claimed, bound, socket_unlinked, lock_unlinked };
    for (std.enums.values(Step)) |step| {
        errdefer std.debug.print("endpoint crash point: {s}\n", .{@tagName(step)});
        for ([_]bool{ true, false }) |census_first| {
            switch (step) {
                .mkdir, .lock_unlinked => _ = try arrange(io, directory, .absent, .absent, false),
                .lock_created, .socket_unlinked => _ = try arrange(io, directory, .free, .absent, false),
                .claimed, .bound => {
                    var endpoint = try claim(io, derived);
                    if (step == .bound) {
                        var listener = try endpoint.listen(.{});
                        listener.deinit(io);
                    }
                    // SIGKILL: the kernel closes every descriptor, nothing else.
                    endpoint.held.?.release(io);
                },
            }
            if (census_first) {
                try testing.expect(inspect(io, &derived) != .unprovable);
                try testing.expectEqual(Left{ .directory = false }, try leftIn(io, directory));
            } else {
                var endpoint = try claim(io, derived);
                var listener = try endpoint.listen(.{});
                listener.deinit(io);
                try endpoint.retire();
                try testing.expectEqual(Left{ .directory = false }, try leftIn(io, directory));
            }
        }
    }

    // A second claim of a held D is in use; a configured D keeps the directory.
    {
        var first = try claim(io, derived);
        try testing.expectError(error.RuntimeDirectoryInUse, claim(io, derived));
        try first.retire();
        var configured_buffer: [Path.max_bytes]u8 = undefined;
        const configured = try Interface.within(root, try std.fmt.bufPrint(&configured_buffer, "{s}/configured", .{root}));
        try testing.expect(configured == .configured);
        var endpoint = try claim(io, configured);
        var listener = try endpoint.listen(.{});
        listener.deinit(io);
        endpoint.held.?.release(io);
        try testing.expectEqual(Sighting.reclaimed, inspect(io, &configured));
        try testing.expectEqual(Left{}, try leftIn(io, configured.path()));
    }

    // The census: dead endpoints go and are not reported; a live one, and a
    // socket nobody can prove dead, are reported and left; a Host before its
    // bind is left to the process census; other names are never touched.
    {
        const names = [_][]const u8{ "00000000000000000000000000000001", "00000000000000000000000000000002", "00000000000000000000000000000003", "00000000000000000000000000000004" };
        var paths: [names.len][Path.max_bytes]u8 = undefined;
        var interfaces: [names.len]Interface = undefined;
        for (names, &paths, &interfaces) |name, *buffer, *interface| interface.* = try Interface.within(root, try std.fmt.bufPrint(buffer, "{s}/{s}", .{ root, name }));
        _ = try arrange(io, interfaces[0].path(), .free, .socket, false);
        var live = try claim(io, interfaces[1]);
        var live_listener = try live.listen(.{});
        errdefer live_listener.deinit(io);
        _ = try arrange(io, interfaces[2].path(), .absent, .socket, false);
        var starting = try claim(io, interfaces[3]);
        try runtime.dir.createDir(io, "not-an-endpoint", .fromMode(0o700));
        (try runtime.dir.createFile(io, "0123456789abcdef0123456789abcdef.sock", .{})).close(io);
        const found = try censusIn(testing.allocator, io, root, null);
        defer freeSockets(testing.allocator, found);
        try testing.expectEqual(@as(usize, 2), found.len);
        var expected: [std.Io.net.UnixAddress.max_len]u8 = undefined;
        try testing.expectEqualStrings(try live.socketPath(&expected), found[0]);
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{s}/{s}", .{ interfaces[2].path(), socket_name }), found[1]);
        try testing.expectEqual(Left{ .directory = false }, try leftIn(io, interfaces[0].path()));
        try testing.expect(acceptsConnection(io, found[0]));
        try testing.expectEqual(Left{ .lock = true }, try leftIn(io, interfaces[3].path()));
        _ = try runtime.dir.statFile(io, "not-an-endpoint", .{});
        _ = try runtime.dir.statFile(io, "0123456789abcdef0123456789abcdef.sock", .{});
        // A sweep from the starting Host leaves itself and every live endpoint alone.
        starting.held.?.release(io);
        const swept = try censusIn(testing.allocator, io, root, interfaces[3].path());
        defer freeSockets(testing.allocator, swept);
        try testing.expectEqual(@as(usize, 2), swept.len);
        try testing.expect((try leftIn(io, interfaces[3].path())).lock);
        try testing.expectEqual(Sighting.reclaimed, inspect(io, &interfaces[3]));
        live_listener.deinit(io);
        try live.retire();
    }
}
