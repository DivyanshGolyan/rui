const builtin = @import("builtin");
const std = @import("std");

pub const socket = @import("socket.zig");
pub const Waker = @import("Waker.zig");

pub const tag = builtin.os.tag;

pub const Semantics = struct {
    supported: bool,
    full_fsync: bool,
    read_only_directory: ?[]const u8,
    glibc_possible: bool,
    proc_memory: bool,
    full_backlog_blocks_connect: bool,
    stack_guard_bus_error: bool,
    sec_trust: bool,
    hashed_trust_directories: bool,
    link_opener: ?struct { command: []const u8, needs_display: bool },
};

pub fn semantics(comptime os: std.Target.Os.Tag) Semantics {
    return .{
        .supported = os == .linux or os == .macos,
        .full_fsync = os == .macos,
        .read_only_directory = switch (os) {
            .linux => "/sys",
            .macos => "/System",
            else => null,
        },
        .glibc_possible = os == .linux,
        .proc_memory = os == .linux,
        .full_backlog_blocks_connect = os == .linux,
        .stack_guard_bus_error = os == .macos,
        .sec_trust = os.isDarwin(),
        .hashed_trust_directories = os == .linux,
        .link_opener = switch (os) {
            .macos => .{ .command = "open", .needs_display = false },
            .linux => .{ .command = "xdg-open", .needs_display = true },
            else => null,
        },
    };
}

pub const current = semantics(tag);

pub const supported = current.supported;

/// Darwin's fsync leaves data in the drive cache; SQLite's fullfsync issues
/// F_FULLFSYNC so a committed Store survives power loss.
pub const full_fsync = current.full_fsync;

/// A directory on a read-only filesystem, which tests use as an ancestor that
/// no privilege can write: Linux's sysfs and Darwin's sealed system volume.
pub const read_only_directory = current.read_only_directory orelse @compileError("no read-only directory for this OS");

/// glibc's malloc keeps the pages of freed chunks in every arena until
/// malloc_trim returns them. Other C libraries have no malloc_trim.
pub const glibc_malloc = current.glibc_possible and builtin.link_libc and builtin.target.isGnuLibC();

/// Linux reports a process's memory in /proc/self/status and smaps_rollup;
/// Darwin has no /proc.
pub const proc_memory = current.proc_memory;

/// Linux's per-process memory totals (Rss, Pss, Private_Dirty, Anonymous),
/// readable where `proc_memory` holds.
pub const memory_rollup_path = "/proc/self/smaps_rollup";

/// Linux queues a connect beyond a full listen backlog until it times out;
/// Darwin refuses it at once.
pub const full_backlog_blocks_connect = current.full_backlog_blocks_connect;

/// Darwin may deliver a stack guard-page hit as SIGBUS, which Zig's handler
/// reports as a bus error; Linux delivers SIGSEGV.
pub const stack_guard_bus_error = current.stack_guard_bus_error;

/// Darwin verifies a peer against the system's roots with Apple SecTrust,
/// which checks revocation and ignores OpenSSL's SSL_CERT_FILE and
/// SSL_CERT_DIR (#990, #997); elsewhere system trust is OpenSSL's store.
pub const sec_trust = current.sec_trust;

/// Linux distributions keep OpenSSL hashed certificate directories, which
/// OpenSSL system trust probes before the bundles.
pub const hashed_trust_directories = current.hashed_trust_directories;

pub const LinkOpener = union(enum) {
    desktop: []const u8,
    wsl: ?[]const u8,

    pub fn open(self: LinkOpener, io: std.Io, link: []const u8) !void {
        if (!supported) return error.Unsupported;
        // Reserve the waiter before launching so failure cannot strand a child.
        const waiter = try Waiter.start();
        defer waiter.publish();
        waiter.pid = switch (self) {
            .desktop => |command| try launch(io, &.{ command, link }),
            .wsl => |fallback| launch(io, &.{ "rundll32.exe", "url.dll,FileProtocolHandler", link }) catch |err| blk: {
                const command = fallback orelse return err;
                break :blk try launch(io, &.{ command, link });
            },
        };
    }

    fn launch(io: std.Io, argv: []const []const u8) !?std.posix.pid_t {
        const child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        return child.id;
    }

    const Waiter = struct {
        ready: std.Io.Event = .unset,
        pid: ?std.posix.pid_t = null,
        // The publisher retains its reference until the event wake returns.
        references: std.atomic.Value(u8) = .init(2),

        const allocator = std.heap.smp_allocator;

        fn start() !*Waiter {
            const waiter = try allocator.create(Waiter);
            errdefer allocator.destroy(waiter);
            waiter.* = .{};
            // Leave room for glibc static TLS, including Zig's test signal stack.
            const thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, run, .{waiter});
            thread.detach();
            return waiter;
        }

        fn publish(waiter: *Waiter) void {
            waiter.ready.set(std.Io.Threaded.global_single_threaded.io());
            waiter.release();
        }

        fn run(waiter: *Waiter) void {
            waiter.ready.waitUncancelable(std.Io.Threaded.global_single_threaded.io());
            const pid = waiter.pid;
            waiter.release();
            // Only the PID outlives the launch call and its I/O context.
            if (pid) |child| {
                var status: c_int = undefined;
                while (true) switch (std.posix.errno(std.c.waitpid(child, &status, 0))) {
                    .SUCCESS => if (std.posix.W.IFEXITED(@bitCast(status)) or std.posix.W.IFSIGNALED(@bitCast(status))) return,
                    .INTR => continue,
                    else => return,
                };
            }
        }

        fn release(waiter: *Waiter) void {
            if (waiter.references.fetchSub(1, .acq_rel) == 1) allocator.destroy(waiter);
        }
    };
};

pub fn linkOpener(environ: *const std.process.Environ.Map) ?LinkOpener {
    return linkOpenerFor(tag, environ);
}

fn linkOpenerFor(comptime platform: std.Target.Os.Tag, environ: *const std.process.Environ.Map) ?LinkOpener {
    const opener = semantics(platform).link_opener orelse return null;
    const has_display = environ.get("DISPLAY") != null or environ.get("WAYLAND_DISPLAY") != null;
    const desktop: ?[]const u8 = if (!opener.needs_display or has_display) opener.command else null;
    if (platform == .linux) {
        if (environ.get("WSL_INTEROP")) |interop| {
            if (interop.len != 0) return .{ .wsl = desktop };
        }
    }
    return if (desktop) |command| .{ .desktop = command } else null;
}

test "Linux and Darwin semantics" {
    const linux = semantics(.linux);
    const mac = semantics(.macos);
    try std.testing.expect(linux.supported and mac.supported);
    try std.testing.expect(!linux.full_fsync and mac.full_fsync);
    try std.testing.expectEqualStrings("/sys", linux.read_only_directory.?);
    try std.testing.expectEqualStrings("/System", mac.read_only_directory.?);
    try std.testing.expect(linux.glibc_possible and !mac.glibc_possible);
    try std.testing.expect(linux.proc_memory and !mac.proc_memory);
    try std.testing.expect(linux.full_backlog_blocks_connect and !mac.full_backlog_blocks_connect);
    try std.testing.expect(!linux.stack_guard_bus_error and mac.stack_guard_bus_error);
    try std.testing.expect(!linux.sec_trust and mac.sec_trust);
    try std.testing.expect(linux.hashed_trust_directories and !mac.hashed_trust_directories);
    const unsupported = semantics(.windows);
    try std.testing.expect(!unsupported.supported and unsupported.read_only_directory == null);
}

test "SUI-64 browser launch selects the native route and preserves arguments through refusal" {
    if (tag != .linux and tag != .macos) return error.SkipZigTest;
    const Probe = struct {
        calls: usize = 0,
        wsl: bool,
        first_refused: bool,
        second_refused: bool,
        const url = "https://example.invalid/authorize?first=one&second=two%20words";
        fn spawn(raw: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const expected: []const []const u8 = if (self.wsl and self.calls == 0)
                &.{ "rundll32.exe", "url.dll,FileProtocolHandler", url }
            else
                &.{ if (tag == .macos) "open" else "xdg-open", url };
            std.testing.expectEqual(expected.len, options.argv.len) catch return error.Unexpected;
            for (expected, options.argv) |want, got| {
                std.testing.expectEqualStrings(want, got) catch return error.Unexpected;
            }
            std.testing.expect(options.stdin == .ignore and options.stdout == .ignore and options.stderr == .ignore) catch return error.Unexpected;
            const refused = if (self.calls == 0) self.first_refused else self.second_refused;
            self.calls += 1;
            if (refused) return error.FileNotFound;
            return .{ .id = null, .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.processSpawn = Probe.spawn;
    const displays = [_]?[]const u8{ null, "DISPLAY", "WAYLAND_DISPLAY" };
    const interops = [_]?[]const u8{ null, "", "/run/WSL/synthetic" };
    for (displays) |display| for (interops) |interop| for ([_]bool{ false, true }) |first_refused| for ([_]bool{ false, true }) |second_refused| {
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        if (display) |key| try env.put(key, ":0");
        if (interop) |value| try env.put("WSL_INTEROP", value);
        const wsl = tag == .linux and interop != null and interop.?.len != 0;
        const desktop = tag == .macos or display != null;
        const selected = linkOpener(&env);
        try std.testing.expectEqual(wsl or desktop, selected != null);
        if (selected) |opener| {
            var probe: Probe = .{ .wsl = wsl, .first_refused = first_refused, .second_refused = second_refused };
            const io: std.Io = .{ .userdata = &probe, .vtable = &vtable };
            const fallback = wsl and desktop and first_refused;
            if (first_refused and (!fallback or second_refused)) {
                try std.testing.expectError(error.FileNotFound, opener.open(io, Probe.url));
            } else {
                try opener.open(io, Probe.url);
            }
            try std.testing.expectEqual(@as(usize, if (fallback) 2 else 1), probe.calls);
        }
    };
}

test {
    _ = socket;
    _ = Waker;
}
