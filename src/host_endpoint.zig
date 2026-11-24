//! Sole owner of a Host's endpoint: the interface directory D and the
//! `rui.sock` inside it. A Host serves from `D/rui.sock` while it holds an
//! exclusive flock on D itself, as the inode D's path names, from before it
//! touches the socket until after it unlinks it. D is the lock, so an endpoint
//! holds no regular file for an OS temp cleaner to age (#2128): macOS
//! clean-tmps and tmp_cleaner delete only regular files and empty old
//! directories, and systemd-tmpfiles spares live sockets and, from v242,
//! locked directories. A Host of the previous release still locks
//! `D/rui.lock`; the one-release check in `lockVerified` keeps its socket
//! safe, and `legacy_lock_name` goes with that check.
//! So only the holder of D's lock unlinks a Host socket, and whoever can hold
//! it (a starting Host, the upgrade census) may remove a dead endpoint.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("posix");
const runtime_directory = @import("runtime_directory.zig");
const host_settings = @import("host_settings.zig");

pub const socket_name = host_settings.socket_name;

/// The lock file of the previous release. One release only: `lockVerified`
/// refuses a D it holds, and `dissolve` removes the file once it is free.
const legacy_lock_name = "rui.lock";

/// Bounded so `D/rui.sock` fits Darwin's 104-byte `sun_path`.
pub const Path = host_settings.OsBytes(host_settings.max_runtime_dir_bytes);

/// Where D comes from. A derived D, a 32-lowercase-hex child of the per-user
/// runtime directory, is Rui's: it is censused, swept and removed once empty.
/// Any other (a configured `interface.dir`) belongs to the user, and only
/// Rui's files in it are ever removed.
pub const Interface = union(enum) {
    derived: Path,
    configured: Path,

    /// The one classification, shared with `census`: the shape of the path
    /// decides, so a Host and a census never disagree about who owns D.
    pub fn init(directory: []const u8) !Interface {
        var buffer: [runtime_directory.max_runtime_directory_bytes]u8 = undefined;
        return within(try runtime_directory.runtimeDirectory(&buffer), directory);
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

/// Proof, held in this process, that this open file description holds an
/// exclusive flock on D and D's path names that inode now. Only `lockVerified`
/// makes one. The lock is the descriptor: closing it unlocks, as SIGKILL does.
const Held = struct {
    dir: std.Io.Dir,

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

    /// The one teardown, under D's lock so no census or claim interleaves: the
    /// socket, then a free legacy lock file, then a derived D if it is empty
    /// (MySQL scratch, diagnostics and `host.stopped` stay). A previous-release
    /// Host that holds `rui.lock` makes this `.busy`, with nothing removed. A
    /// crash or failure at any step leaves a free D, which the next census or
    /// claim proves and finishes. Always releases the lock.
    fn dissolve(self: *Held, io: std.Io, interface: *const Interface) !Teardown {
        defer self.release(io);
        // Held through the socket unlink and the rmdir below: a legacy Host that
        // starts now cannot take the lock, so its socket is not removed under it.
        const legacy = takeLegacyLock(self.dir.handle) catch |err| switch (err) {
            error.LegacyLockHeld => return .busy,
            else => return err,
        };
        defer if (legacy) |fd| {
            _ = c.close(fd);
        };
        try self.clearSocket(io);
        if (legacy != null) self.dir.deleteFile(io, legacy_lock_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        // A Host that lost D (EndpointLost) holds an inode the path no longer names. The path may now
        // name another Host's freshly claimed D, so only the held inode's own name is ever removed.
        if (interface.* == .derived and namesDirectory(io, interface.path(), self.dir.handle)) std.Io.Dir.cwd().deleteDir(io, interface.path()) catch |err| switch (err) {
            error.FileNotFound, error.DirNotEmpty => {},
            else => return err,
        };
        return .done;
    }

    fn release(self: *Held, io: std.Io) void {
        self.dir.close(io);
        self.* = undefined;
    }
};

const Teardown = enum { done, busy };

const LockResult = union(enum) {
    held: Held,
    /// Another open file description holds D, a previous-release Host holds
    /// its `rui.lock`, or D was replaced while this call took its lock.
    busy,
    /// D does not exist.
    absent,
    /// D is not a private directory of this user, or it is a node Rui does
    /// not expect at D's path.
    unusable: anyerror,
};

/// Test seam: the steps of `claim`, `lockVerified` and `occupancyOnce` call
/// `pauseAt`, so a test can change the world exactly there. The hook exists
/// only in test builds and is a no-op until a test sets it.
const Stage = enum { created, opened, checked };
fn noPauseHook(_: Stage) void {}
var pause_hook: if (builtin.is_test) *const fn (Stage) void else void = if (builtin.is_test) noPauseHook else {};
inline fn pauseAt(stage: Stage) void {
    if (builtin.is_test) pause_hook(stage);
}

/// The single decision point for endpoint ownership.
fn lockVerified(io: std.Io, directory: []const u8) LockResult {
    const dir = openDirectory(directory) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .{ .unusable = err },
    };
    var kept = false;
    defer if (!kept) dir.close(io);
    privateDirectory(dir.handle) catch |err| return .{ .unusable = err };
    pauseAt(.opened);
    switch (std.posix.errno(std.posix.system.flock(dir.handle, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => {},
        .AGAIN => return .busy,
        else => return .{ .unusable = error.EndpointLockFailed },
    }
    // flock belongs to an inode: a D replaced since our open proves nothing.
    if (!namesDirectory(io, directory, dir.handle)) return .busy;
    switch (legacyState(dir.handle)) {
        .absent, .free => {},
        .held => return .busy,
        .unusable => return .{ .unusable = error.UnexpectedEndpointNode },
    }
    pauseAt(.checked);
    kept = true;
    return .{ .held = .{ .dir = dir } };
}

/// Opens D itself. A symlink at D's own name is refused rather than followed.
fn openDirectory(directory: []const u8) !std.Io.Dir {
    const fd = try std.posix.openat(std.Io.Dir.cwd().handle, directory, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    return .{ .handle = fd };
}

fn privateDirectory(fd: std.posix.fd_t) !void {
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.EndpointStatFailed;
    if (stat.st_mode & c.S_IFMT != c.S_IFDIR or stat.st_uid != c.geteuid()) return error.UnexpectedEndpointNode;
    if (stat.st_mode & 0o077 != 0) return error.InsecureDirectoryPermissions;
}

/// Whether D's path still names the inode `fd` holds.
fn namesDirectory(io: std.Io, directory: []const u8, fd: std.posix.fd_t) bool {
    var held: c.struct_stat = undefined;
    if (c.fstat(fd, &held) != 0) return false;
    const current = openDirectory(directory) catch return false;
    defer current.close(io);
    var named: c.struct_stat = undefined;
    return c.fstat(current.handle, &named) == 0 and held.st_dev == named.st_dev and held.st_ino == named.st_ino;
}

const Legacy = enum { absent, free, held, unusable };

/// One release only (#2128): a previous-release Host locks `D/rui.lock`, not
/// D. A new Host must not claim, census or remove that Host's live socket, so
/// a held legacy lock makes D busy. `dissolve` takes the same lock before it
/// removes anything. A lock created after that check can still race: a
/// previous-release Host that starts during a census is not excluded until
/// its file exists. Remove this with `takeLegacyLock` and `legacyState`.
fn legacyState(dir: std.posix.fd_t) Legacy {
    const fd = std.posix.openat(dir, legacy_lock_name, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .unusable,
    };
    defer _ = c.close(fd);
    return switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB))) {
        .SUCCESS => .free,
        .AGAIN => .held,
        else => .unusable,
    };
}

/// One release only (#2128): the previous release's lock, taken exclusively
/// by the caller, or `null` when the file is absent. `error.LegacyLockHeld`
/// when a previous-release Host holds it.
fn takeLegacyLock(dir: std.posix.fd_t) !?std.posix.fd_t {
    const fd = std.posix.openat(dir, legacy_lock_name, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer _ = c.close(fd);
    switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => return fd,
        .AGAIN => return error.LegacyLockHeld,
        else => return error.EndpointLockFailed,
    }
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
    /// sets mode 0600. Fails with `error.EndpointLost`, before touching
    /// anything, when D was removed after `claim` (a stalled Host whose empty
    /// D a cleaner took): binding would land in whatever now sits at that path.
    pub fn listen(self: *Endpoint, options: std.Io.net.UnixAddress.ListenOptions) !std.Io.net.Server {
        const held = &self.held.?;
        if (!namesDirectory(self.io, self.interface.path(), held.dir.handle)) return error.EndpointLost;
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
        _ = try held.dissolve(self.io, &self.interface);
    }
};

/// The window a Host start waits for an inspect (a census look), which holds
/// the lock for microseconds, before it reports the directory in use.
const claim_wait_ns = 100 * std.time.ns_per_ms;

/// Host start: creates D (0700), holds its lock and sets D's times to now, once,
/// through the held descriptor. Between this claim and `listen` D is empty, so
/// only a cleaner that ignores locks, after D stalls for its whole age, can
/// remove it; `listen` then refuses a removed D. After the bind, D is protected
/// because it is non-empty and locked, and the bind and unbind refresh its
/// mtime. Does not touch `rui.sock`; that waits for `listen`, after the caller
/// owns its Store.
pub fn claim(io: std.Io, interface: Interface) error{ RuntimeDirectoryInUse, RuntimeDirectoryUnusable }!Endpoint {
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + claim_wait_ns;
    while (true) {
        createDirectory(io, &interface) catch return error.RuntimeDirectoryUnusable;
        pauseAt(.created);
        switch (lockVerified(io, interface.path())) {
            .held => |value| {
                var held = value;
                if (c.futimens(held.dir.handle, null) != 0) {
                    held.release(io);
                    return error.RuntimeDirectoryUnusable;
                }
                return .{ .io = io, .interface = interface, .held = held };
            },
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
    try privateDirectory(runtime.handle);
    runtime.createDir(io, std.fs.path.basename(directory), .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// What one look at an interface directory found.
pub const Sighting = enum {
    /// This call proved the endpoint dead and removed it.
    reclaimed,
    /// D was already gone.
    vanished,
    /// Someone holds D's lock: a live or starting Host. Probe its socket.
    busy,
    /// D is not a private directory of this user, or a node Rui did not make
    /// is at `D/rui.sock` (a regular file or a symlink), or a dissolve failed.
    /// Rui never leaves this state, and never removes it.
    unprovable,
};

/// Takes D's lock without creating D; a free D is dissolved. Never blocks.
pub fn inspect(io: std.Io, interface: *const Interface) Sighting {
    switch (lockVerified(io, interface.path())) {
        .held => |value| {
            var held = value;
            return switch (held.dissolve(io, interface) catch return .unprovable) {
                .done => .reclaimed,
                .busy => .busy,
            };
        },
        .busy => return .busy,
        .unusable => return .unprovable,
        .absent => return .vanished,
    }
}

/// Whether some Host holds D, read without removing anything: the MySQL Store's
/// observation, which asks this owner instead of reading the lock itself. A
/// shared flock on D is taken and dropped, and a previous-release holder of
/// `rui.lock` counts as held.
pub const Occupancy = enum { held, free, absent, unusable };

/// Looks again when a stopping Host removed or replaced D between the open
/// and the name check, a race that is normal and not an access failure.
const occupancy_attempts = 4;

pub fn occupancy(io: std.Io, directory: []const u8) Occupancy {
    for (0..occupancy_attempts) |_| {
        if (occupancyOnce(io, directory)) |result| return result;
    }
    return .unusable;
}

/// One look; null when D's path stopped naming the locked inode.
fn occupancyOnce(io: std.Io, directory: []const u8) ?Occupancy {
    const dir = openDirectory(directory) catch |err| return switch (err) {
        error.FileNotFound => .absent,
        else => .unusable,
    };
    defer dir.close(io);
    privateDirectory(dir.handle) catch return .unusable;
    pauseAt(.opened);
    switch (std.posix.errno(std.posix.system.flock(dir.handle, std.posix.LOCK.SH | std.posix.LOCK.NB))) {
        .SUCCESS => {},
        .AGAIN => return .held,
        else => return .unusable,
    }
    // As in lockVerified: a lock on a D replaced since the open says nothing about D's path.
    if (!namesDirectory(io, directory, dir.handle)) return null;
    return switch (legacyState(dir.handle)) {
        .absent, .free => .free,
        .held => .held,
        .unusable => .unusable,
    };
}

/// The upgrade census: inspects every derived D of this user, removing the
/// dead ones, and returns the socket paths of the rest (sorted, owned by the
/// caller). Flat sockets of older releases are not endpoints and stay; the
/// process census finds a live Host there.
pub fn census(allocator: std.mem.Allocator, io: std.Io) ![][]u8 {
    var buffer: [runtime_directory.max_runtime_directory_bytes]u8 = undefined;
    return censusIn(allocator, io, try runtime_directory.runtimeDirectory(&buffer), null);
}

/// Host start, best effort: the census without its report, skipping this
/// Host's own D, so killed Hosts' endpoints do not pile up between upgrades.
pub noinline fn sweepNeighbors(allocator: std.mem.Allocator, own: *const Endpoint) void {
    var buffer: [runtime_directory.max_runtime_directory_bytes]u8 = undefined;
    const runtime = runtime_directory.runtimeDirectory(&buffer) catch return;
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
    try privateDirectory(directory.handle);
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
    const dir = openDirectory(interface.path()) catch return false;
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
    legacy: bool = false,
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
    left.legacy = if (dir.statFile(io, legacy_lock_name, .{ .follow_symlinks = false })) |_| true else |_| false;
    left.socket = if (dir.statFile(io, socket_name, .{ .follow_symlinks = false })) |stat| stat.kind else |_| null;
    left.extra = if (dir.statFile(io, "extra", .{ .follow_symlinks = false })) |_| true else |_| false;
    return left;
}

/// Who holds D's lock. A `null` lock in a row means D is absent.
const LockState = enum { free, held_elsewhere };
const LegacyFile = enum { absent, free, held_elsewhere };
const SocketState = enum { absent, socket, regular, symlink };

/// The open descriptors a test keeps: a holder keeps its lock until released.
const Holders = struct {
    dir: ?std.Io.Dir = null,
    legacy: ?std.Io.File = null,

    fn release(self: Holders, io: std.Io) void {
        if (self.legacy) |file| file.close(io);
        if (self.dir) |dir| dir.close(io);
    }
};

fn expectFlock(fd: std.posix.fd_t) !void {
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB)));
}

/// Builds one present D in a row's state. A free lock is no holder; a held
/// one is a descriptor that holds the flock, which the caller releases.
fn arrange(io: std.Io, directory: []const u8, lock: LockState, legacy: LegacyFile, socket: SocketState, extra: bool) !Holders {
    // A flock needs a real descriptor: the directory is reopened the way a Host opens it.
    (try std.Io.Dir.cwd().createDirPathOpen(io, directory, .{ .permissions = .fromMode(0o700) })).close(io);
    var holders: Holders = .{ .dir = try openDirectory(directory) };
    errdefer holders.release(io);
    const dir = holders.dir.?;
    if (lock == .held_elsewhere) try expectFlock(dir.handle);
    if (legacy != .absent) {
        const file = try dir.createFile(io, legacy_lock_name, .{ .read = true, .truncate = false, .permissions = .fromMode(0o600) });
        holders.legacy = file;
        if (legacy == .held_elsewhere) try expectFlock(file.handle);
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
    return holders;
}

fn acceptsConnection(io: std.Io, path: []const u8) bool {
    const address = std.Io.net.UnixAddress.init(path) catch return false;
    const stream = address.connect(io) catch return false;
    stream.close(io);
    return true;
}

const Actor = enum { census, host };

const OwnershipRow = struct {
    /// null: D is absent.
    lock: ?LockState,
    legacy: LegacyFile = .absent,
    socket: SocketState = .absent,
    extra: bool = false,
    /// What a census look reports, and what it leaves.
    sighting: Sighting,
    after: Left,
    /// What `claim` then `listen` does from this state.
    serves: enum { yes, in_use, unexpected_socket },
};

fn ownershipRow(io: std.Io, derived: *const Interface, row: OwnershipRow, actor: Actor) !void {
    const directory = derived.path();
    const holders: Holders = if (row.lock) |lock| try arrange(io, directory, lock, row.legacy, row.socket, row.extra) else .{};
    defer holders.release(io);
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
        try testing.expectEqual(row.after, try leftIn(io, directory));
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
    try testing.expectEqual(Left{ .legacy = row.legacy != .absent, .extra = row.extra }, try leftIn(io, directory));
    try endpoint.retire();
    try endpoint.retire();
    try testing.expectEqual(if (row.extra) Left{ .extra = true } else Left{ .directory = false }, try leftIn(io, directory));
}

test "SH-11 only the holder of an interface directory's lock removes its endpoint" {
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
    // row: only the holder of D's lock lets anything be removed, and only a
    // Unix socket, a free legacy lock file and an empty derived D go.
    const rows = [_]OwnershipRow{
        .{ .lock = null, .sighting = .vanished, .after = .{ .directory = false }, .serves = .yes },
        .{ .lock = .free, .sighting = .reclaimed, .after = .{ .directory = false }, .serves = .yes },
        .{ .lock = .free, .extra = true, .sighting = .reclaimed, .after = .{ .extra = true }, .serves = .yes },
        .{ .lock = .free, .socket = .socket, .sighting = .reclaimed, .after = .{ .directory = false }, .serves = .yes },
        .{ .lock = .free, .socket = .socket, .extra = true, .sighting = .reclaimed, .after = .{ .extra = true }, .serves = .yes },
        .{ .lock = .free, .socket = .regular, .sighting = .unprovable, .after = .{ .socket = .file }, .serves = .unexpected_socket },
        .{ .lock = .free, .socket = .symlink, .extra = true, .sighting = .unprovable, .after = .{ .socket = .sym_link, .extra = true }, .serves = .unexpected_socket },
        .{ .lock = .free, .legacy = .free, .sighting = .reclaimed, .after = .{ .directory = false }, .serves = .yes },
        .{ .lock = .free, .legacy = .free, .socket = .socket, .sighting = .reclaimed, .after = .{ .directory = false }, .serves = .yes },
        .{ .lock = .free, .legacy = .held_elsewhere, .sighting = .busy, .after = .{ .legacy = true }, .serves = .in_use },
        .{ .lock = .held_elsewhere, .sighting = .busy, .after = .{}, .serves = .in_use },
        .{ .lock = .held_elsewhere, .socket = .socket, .extra = true, .sighting = .busy, .after = .{ .socket = .unix_domain_socket, .extra = true }, .serves = .in_use },
        .{ .lock = .held_elsewhere, .socket = .regular, .sighting = .busy, .after = .{ .socket = .file }, .serves = .in_use },
    };
    for (rows) |row| for ([_]Actor{ .census, .host }) |actor| {
        errdefer std.debug.print("endpoint ownership row: {any} actor={s}\n", .{ row, @tagName(actor) });
        try ownershipRow(io, &derived, row, actor);
        try std.Io.Dir.cwd().deleteTree(io, directory);
    };

    // Interleavings: one actor's step meets an interference at a point in that
    // step, and the outcome is the contract's. A row's `step` is a hook point
    // inside claim, lockVerified or occupancy, or `claimed`, the moment after
    // claim returns, before listen or retire. Rows whose interference is a
    // held legacy rui.lock before the look are covered by the ownership table
    // for claim and inspect; occupancy has its own row.
    const Caller = enum { claim, listen, inspect, occupancy, retire };
    const Step = enum { created, opened, checked, claimed };
    const Meddle = enum { none, replace, replace_every, remove, legacy_lock };
    const Outcome = enum { busy_then_reclaimed, busy_keeps_files, absent, unusable, held, claim_holds, listen_lost, replacement_survives };
    const Row = struct {
        caller: Caller,
        step: Step,
        meddle: Meddle,
        socket: SocketState = .absent,
        outcome: Outcome,
    };
    const interleavings = [_]Row{
        // A D replaced after the open: the lock proves nothing, and the next look reclaims the new D.
        .{ .caller = .inspect, .step = .opened, .meddle = .replace, .outcome = .busy_then_reclaimed },
        // A stopping Host removes D after occupancy's open: looks again, and finds it absent.
        .{ .caller = .occupancy, .step = .opened, .meddle = .remove, .outcome = .absent },
        // D replaced every time it is opened: occupancy gives up as unusable.
        .{ .caller = .occupancy, .step = .opened, .meddle = .replace_every, .outcome = .unusable },
        // A census removes the empty D between claim's mkdir and open: claim retries and holds it.
        .{ .caller = .claim, .step = .created, .meddle = .remove, .outcome = .claim_holds },
        // D removed after claim, before listen: listen refuses to bind into it.
        .{ .caller = .listen, .step = .claimed, .meddle = .remove, .outcome = .listen_lost },
        // A Host that lost D retires; the replacement claim at the path is left alone.
        .{ .caller = .retire, .step = .claimed, .meddle = .replace, .outcome = .replacement_survives },
        // A previous-release Host locks rui.lock after the check: the teardown keeps its socket.
        .{ .caller = .inspect, .step = .checked, .meddle = .legacy_lock, .socket = .socket, .outcome = .busy_keeps_files },
        // A previous-release Host locks rui.lock during occupancy's look: the look reports held.
        .{ .caller = .occupancy, .step = .opened, .meddle = .legacy_lock, .outcome = .held },
    };
    const Script = struct {
        var step: Step = .created;
        var meddle: Meddle = .none;
        var armed = false;
        var path: []const u8 = "";
        var legacy: ?std.Io.File = null;

        fn hook(stage: Stage) void {
            if (!armed or !std.mem.eql(u8, @tagName(step), @tagName(stage))) return;
            armed = meddle == .replace_every;
            switch (meddle) {
                .none => {},
                .replace, .replace_every => {
                    std.Io.Dir.cwd().deleteDir(testing.io, path) catch unreachable;
                    std.Io.Dir.cwd().createDir(testing.io, path, .fromMode(0o700)) catch unreachable;
                },
                .remove => std.Io.Dir.cwd().deleteDir(testing.io, path) catch unreachable,
                .legacy_lock => {
                    const dir = openDirectory(path) catch unreachable;
                    defer dir.close(testing.io);
                    const file = dir.createFile(testing.io, legacy_lock_name, .{ .read = true, .truncate = false, .permissions = .fromMode(0o600) }) catch unreachable;
                    expectFlock(file.handle) catch unreachable;
                    legacy = file;
                },
            }
        }
    };
    for (interleavings) |row| {
        errdefer std.debug.print("endpoint interleaving row: {any}\n", .{row});
        {
            (try arrange(io, directory, .free, .absent, row.socket, false)).release(io);
            Script.step = row.step;
            Script.meddle = row.meddle;
            Script.armed = row.step != .claimed and row.meddle != .none;
            Script.path = directory;
            pause_hook = Script.hook;
            defer {
                pause_hook = noPauseHook;
                Script.armed = false;
                if (Script.legacy) |file| file.close(io);
                Script.legacy = null;
            }
            switch (row.caller) {
                .claim => {
                    var endpoint = try claim(io, derived);
                    try testing.expectEqual(Sighting.busy, inspect(io, &derived));
                    try endpoint.retire();
                    try testing.expectEqual(Left{ .directory = false }, try leftIn(io, directory));
                },
                .listen => {
                    var endpoint = try claim(io, derived);
                    try std.Io.Dir.cwd().deleteDir(io, directory);
                    try testing.expectError(error.EndpointLost, endpoint.listen(.{}));
                    try testing.expectEqual(Left{ .directory = false }, try leftIn(io, directory));
                    try endpoint.retire();
                },
                .retire => {
                    var lost = try claim(io, derived);
                    try std.Io.Dir.cwd().deleteDir(io, directory);
                    var replacement = try claim(io, derived);
                    try testing.expectError(error.EndpointLost, lost.listen(.{}));
                    try lost.retire();
                    try testing.expectEqual(Left{}, try leftIn(io, directory));
                    var listener = try replacement.listen(.{});
                    listener.deinit(io);
                    try replacement.retire();
                    try testing.expectEqual(Left{ .directory = false }, try leftIn(io, directory));
                },
                .inspect => {
                    try testing.expectEqual(Sighting.busy, inspect(io, &derived));
                    if (row.outcome == .busy_then_reclaimed) {
                        // The new D is free and empty; the look that follows reclaims it.
                        try testing.expectEqual(Sighting.reclaimed, inspect(io, &derived));
                        try testing.expectEqual(Left{ .directory = false }, try leftIn(io, directory));
                    } else {
                        try testing.expectEqual(Left{ .socket = .unix_domain_socket, .legacy = true }, try leftIn(io, directory));
                    }
                },
                .occupancy => {
                    const expected: Occupancy = switch (row.outcome) {
                        .absent => .absent,
                        .unusable => .unusable,
                        .held => .held,
                        else => unreachable,
                    };
                    try testing.expectEqual(expected, occupancy(io, directory));
                },
            }
        }
        try std.Io.Dir.cwd().deleteTree(io, directory);
    }

    // Crash points: a Host killed after each step of its life leaves a state
    // the next look proves dead and removes, and the next claim serves from.
    const Crash = enum { created, claimed, bound, socket_unlinked };
    for (std.enums.values(Crash)) |crash| {
        errdefer std.debug.print("endpoint crash point: {s}\n", .{@tagName(crash)});
        for ([_]bool{ true, false }) |census_first| {
            switch (crash) {
                .created, .socket_unlinked => (try arrange(io, directory, .free, .absent, .absent, false)).release(io),
                .claimed, .bound => {
                    var endpoint = try claim(io, derived);
                    if (crash == .bound) {
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
        const dead = try arrange(io, interfaces[0].path(), .free, .absent, .socket, false);
        defer dead.release(io);
        var live = try claim(io, interfaces[1]);
        var live_listener = try live.listen(.{});
        errdefer live_listener.deinit(io);
        const unprovable = try arrange(io, interfaces[2].path(), .free, .absent, .regular, false);
        defer unprovable.release(io);
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
        try testing.expectEqual(Left{}, try leftIn(io, interfaces[3].path()));
        _ = try runtime.dir.statFile(io, "not-an-endpoint", .{});
        _ = try runtime.dir.statFile(io, "0123456789abcdef0123456789abcdef.sock", .{});
        // A sweep from the starting Host leaves itself and every live endpoint alone.
        starting.held.?.release(io);
        const swept = try censusIn(testing.allocator, io, root, interfaces[3].path());
        defer freeSockets(testing.allocator, swept);
        try testing.expectEqual(@as(usize, 2), swept.len);
        try testing.expectEqual(Left{}, try leftIn(io, interfaces[3].path()));
        try testing.expectEqual(Sighting.reclaimed, inspect(io, &interfaces[3]));
        live_listener.deinit(io);
        try live.retire();
    }
}

/// The cleaners' published rules as pure predicates over one node (evidence.md
/// has the sources). A node is removed only when its timestamps are older than
/// the cleaner's age, so a node the Host refreshed is kept by its times, and a
/// node it holds is kept by its lock, where the cleaner honours one.
const Cleaner = enum {
    /// Apple 110.clean-tmps (crontabs-54) and tmp_cleaner (macOS 14+, reported):
    /// `-type f` with every timestamp old, and `-type d -empty` with mtime old.
    /// Locks are ignored (E1, E3).
    darwin_find,
    /// systemd-tmpfiles before v242: ages everything except live sockets, and
    /// ignores locks (E9, E11).
    tmpfiles_pre242,
    /// v242 to v253: also skips a directory it cannot LOCK_EX, and everything below it (E9, E10).
    tmpfiles_242,
    /// v254 and later: also skips a non-directory it cannot LOCK_EX (E10).
    tmpfiles_254,

    /// The age a pass removes at: periodic's default for /tmp (E2) and systemd's (E7).
    fn ageNs(cleaner: Cleaner) i96 {
        const days: i96 = switch (cleaner) {
            .darwin_find => 3,
            .tmpfiles_pre242, .tmpfiles_242, .tmpfiles_254 => 10,
        };
        return days * std.time.ns_per_day;
    }
};

/// One node as a cleaner's rule reads it.
const Node = struct {
    kind: enum { directory, socket, regular },
    /// A directory with no entries left (a cleaner removes it only then).
    empty: bool = false,
    /// A socket that accepts connections (E11: a live socket is spared).
    live: bool = false,
    /// Someone holds LOCK_EX on it.
    locked: bool = false,
    /// Its timestamps are older than the cleaner's age.
    old: bool = false,
};

fn cleanerRemoves(cleaner: Cleaner, node: Node) bool {
    if (!node.old) return false;
    if (node.kind == .socket and node.live) return false;
    if (node.locked) switch (cleaner) {
        .darwin_find, .tmpfiles_pre242 => {},
        .tmpfiles_242 => if (node.kind == .directory) return false,
        .tmpfiles_254 => return false,
    };
    return switch (node.kind) {
        .regular => true,
        .socket => cleaner != .darwin_find,
        .directory => node.empty,
    };
}

fn oldAt(cleaner: Cleaner, timestamp: std.Io.Timestamp, now: i96) bool {
    return timestamp.nanoseconds < now - cleaner.ageNs();
}

/// Whether someone else holds LOCK_EX on the open node `fd`. A probe, as a lock-honouring cleaner takes it.
fn lockHeldElsewhere(fd: std.posix.fd_t) !bool {
    return switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => false,
        .AGAIN => true,
        else => error.EndpointLockFailed,
    };
}

/// Whether someone else holds LOCK_EX on D. The directory is opened the way a lock-honouring cleaner opens it.
fn directoryLocked(io: std.Io, directory: []const u8) !bool {
    const dir = try openDirectory(directory);
    defer dir.close(io);
    return lockHeldElsewhere(dir.handle);
}

/// Applies one cleaner's pass to the entries of D, removing what its rule
/// removes, then to D itself. Ages come from the real timestamps, and locks
/// from real probes. Returns whether D went.
fn applyCleaner(io: std.Io, cleaner: Cleaner, directory: []const u8) !bool {
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer dir.close(io);
    var remaining: usize = 0;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        var buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ directory, entry.name });
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        const old = oldAt(cleaner, stat.mtime, now) and if (stat.atime) |atime| oldAt(cleaner, atime, now) else true;
        const node: Node = if (stat.kind == .unix_domain_socket)
            .{ .kind = .socket, .live = acceptsConnection(io, path), .old = old }
        else blk: {
            const file = try dir.openFile(io, entry.name, .{});
            defer file.close(io);
            break :blk .{ .kind = .regular, .locked = try lockHeldElsewhere(file.handle), .old = old };
        };
        if (cleanerRemoves(cleaner, node)) try dir.deleteFile(io, entry.name) else remaining += 1;
    }
    // D is read after its entries went, so an unlink's mtime bump keeps an emptied D young for this pass.
    const node: Node = .{
        .kind = .directory,
        .empty = remaining == 0,
        .locked = try directoryLocked(io, directory),
        .old = oldAt(cleaner, (try dir.stat(io)).mtime, now),
    };
    if (!cleanerRemoves(cleaner, node)) return false;
    try std.Io.Dir.cwd().deleteDir(io, directory);
    return true;
}

/// Sets an open node's atime and mtime to the epoch, as a claim from days ago would have left them.
/// Its ctime is set to now by the kernel, which is why the model reads only atime and mtime.
fn backdate(fd: std.posix.fd_t) !void {
    const epoch = [2]c.timespec{ .{ .tv_sec = 0, .tv_nsec = 0 }, .{ .tv_sec = 0, .tv_nsec = 0 } };
    if (c.futimens(fd, &epoch) != 0) return error.BackdateFailed;
}

/// Sets the node at `path` to the epoch without following a symlink, so the
/// cleaner model's age rule reaches a socket the way a real cleaner does.
fn backdatePath(path: []const u8) !void {
    var buffer: [std.Io.net.UnixAddress.max_len + 1]u8 = undefined;
    if (path.len >= buffer.len) return error.BackdateFailed;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const epoch = [2]c.timespec{ .{ .tv_sec = 0, .tv_nsec = 0 }, .{ .tv_sec = 0, .tv_nsec = 0 } };
    if (c.utimensat(c.AT_FDCWD, buffer[0..path.len :0].ptr, &epoch, c.AT_SYMLINK_NOFOLLOW) != 0) return error.BackdateFailed;
}

test "SH-121 no OS temp cleaner's rules remove a node of a live endpoint" {
    const io = testing.io;
    var runtime = try socket_fixture.Directory.init();
    defer runtime.cleanup();
    const root = runtime.root[0..runtime.root_len];
    var directory_buffer: [Path.max_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(&directory_buffer, "{s}/{s}", .{ root, "0123456789abcdef0123456789abcdef" });
    const derived = try Interface.within(root, directory);

    // claimed_over_old: an empty D from days ago, which the claim refreshes.
    // old_legacy_lock: the pre-#2128 endpoint, an old D holding an old regular
    // rui.lock that a previous-release Host locks.
    const Phase = enum { claimed, claimed_over_old, claimed_stalled, bound, unbound, old_legacy_lock };
    for (std.enums.values(Phase)) |phase| for (std.enums.values(Cleaner)) |cleaner| {
        errdefer std.debug.print("endpoint cleaner row: phase={s} cleaner={s}\n", .{ @tagName(phase), @tagName(cleaner) });
        if (phase == .old_legacy_lock) {
            {
                const holders = try arrange(io, directory, .free, .held_elsewhere, .absent, false);
                defer holders.release(io);
                try backdate(holders.legacy.?.handle);
                try backdate(holders.dir.?.handle);
                _ = try applyCleaner(io, cleaner, directory);
            }
            // Only v254 and later, which skip a locked regular file, keep it (E10).
            try testing.expectEqual(cleaner == .tmpfiles_254, (try leftIn(io, directory)).legacy);
            try std.Io.Dir.cwd().deleteTree(io, directory);
            continue;
        }
        if (phase == .claimed_over_old) {
            (try arrange(io, directory, .free, .absent, .absent, false)).release(io);
            const old = try openDirectory(directory);
            defer old.close(io);
            try backdate(old.handle);
        }
        var endpoint = try claim(io, derived);
        if (phase == .claimed_over_old) {
            const probe = try std.Io.Dir.cwd().openDir(io, directory, .{});
            defer probe.close(io);
            try testing.expect((try probe.stat(io)).mtime.nanoseconds != 0);
        }
        var listener: ?std.Io.net.Server = null;
        switch (phase) {
            .claimed, .claimed_over_old, .claimed_stalled, .old_legacy_lock => {},
            .bound => listener = try endpoint.listen(.{}),
            .unbound => {
                var served = try endpoint.listen(.{});
                served.deinit(io);
                try endpoint.unbind();
            },
        }
        // Aged D: a stalled claim (its times are as old as the claim's), and a
        // bound D whose socket keeps it non-empty and locked. A fresh claim, and
        // an unbind, leave D's own refresh in place.
        if (phase == .claimed_stalled or phase == .bound) try backdate(endpoint.held.?.dir.handle);
        // A bound D's socket is old too: only its live probe spares it.
        if (phase == .bound) {
            var socket_path_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
            try backdatePath(try std.fmt.bufPrint(&socket_path_buffer, "{s}/{s}", .{ directory, socket_name }));
        }
        const removed = try applyCleaner(io, cleaner, directory);
        if (removed) {
            // Only a stalled claim under a cleaner that ignores locks loses D.
            try testing.expectEqual(Phase.claimed_stalled, phase);
            try testing.expect(cleaner == .darwin_find or cleaner == .tmpfiles_pre242);
            try testing.expectError(error.EndpointLost, endpoint.listen(.{}));
            try testing.expectEqual(Left{ .directory = false }, try leftIn(io, directory));
            try endpoint.retire();
            continue;
        }
        switch (phase) {
            .claimed, .claimed_over_old, .claimed_stalled => {
                var served = try endpoint.listen(.{});
                var socket_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
                try testing.expect(acceptsConnection(io, try endpoint.socketPath(&socket_buffer)));
                try testing.expectEqual(Sighting.busy, inspect(io, &derived));
                served.deinit(io);
                try endpoint.unbind();
            },
            .bound => {
                var socket_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
                try testing.expect(acceptsConnection(io, try endpoint.socketPath(&socket_buffer)));
                try testing.expectEqual(Sighting.busy, inspect(io, &derived));
                listener.?.deinit(io);
                try endpoint.unbind();
            },
            .unbound => try testing.expectEqual(Sighting.busy, inspect(io, &derived)),
            .old_legacy_lock => unreachable,
        }
        try endpoint.retire();
        try testing.expectEqual(Left{ .directory = false }, try leftIn(io, directory));
    };
}
