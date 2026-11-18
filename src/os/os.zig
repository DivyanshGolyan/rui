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

/// The command that opens a link in a browser here, given the environment:
/// macOS's `open` always has one; Linux's `xdg-open` only in a graphical
/// session, which names `DISPLAY` or `WAYLAND_DISPLAY`.
pub fn linkOpener(environ: *const std.process.Environ.Map) ?[]const u8 {
    const opener = current.link_opener orelse return null;
    if (opener.needs_display and environ.get("DISPLAY") == null and environ.get("WAYLAND_DISPLAY") == null) return null;
    return opener.command;
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
    try std.testing.expectEqualStrings("xdg-open", linux.link_opener.?.command);
    try std.testing.expect(linux.link_opener.?.needs_display and !mac.link_opener.?.needs_display);
    try std.testing.expectEqualStrings("open", mac.link_opener.?.command);
    const unsupported = semantics(.windows);
    try std.testing.expect(!unsupported.supported and unsupported.read_only_directory == null);
}

test {
    _ = socket;
    _ = Waker;
}
