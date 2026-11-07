//! Read-only OS observations, never authority to stop a process. A matching
//! snapshot does not authenticate a release or make mutable argv/env immutable.
const std = @import("std");

extern "c" fn rui_host_peer_pid(socket: c_int, pid: *c_int) c_int;
extern "c" fn rui_process_generation(pid: c_int, started: *c_ulonglong) c_int;
extern "c" fn rui_process_snapshot(pid: c_int, exe: [*]u8, exe_cap: usize, data: [*]u8, cap: usize, length: *usize, argc: *usize, env_offset: *usize, started: *c_ulonglong) c_int;

const executable_capacity = 4096;
// One caller-owned observation and one equally bounded C comparison scratch.
const data_capacity = 2 * 1024 * 1024;

/// All slices borrow this value's private storage. Do not log or persist argv or
/// environment. The owner must call deinit even when using an arena allocator.
pub const Snapshot = struct {
    pid: c_int,
    started: u64,
    executable: []const u8,
    argv: []const []const u8,
    environment: []const []const u8,
    storage: []u8,
    entries: [][]const u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.storage);
        allocator.free(self.entries);
        // Preserve the secure wipe through allocators whose free is a no-op
        // (arenas), rather than replacing it with debug undefined poisoning.
        allocator.rawFree(self.storage, .fromByteUnits(@alignOf(u8)), @returnAddress());
        self.* = undefined;
    }
};

pub fn generation(pid: c_int) !u64 {
    var started: c_ulonglong = 0;
    if (rui_process_generation(pid, &started) != 0 or started == 0) return error.HostProcessSnapshotUnavailable;
    return started;
}

pub fn peer(fd: c_int) !c_int {
    var pid: c_int = 0;
    if (rui_host_peer_pid(fd, &pid) != 0 or pid <= 0) return error.HostPeerIdentityUnavailable;
    return pid;
}

/// Returns owned bytes. Native failures deliberately expose no argv/env/path.
pub fn snapshot(allocator: std.mem.Allocator, pid: c_int) !Snapshot {
    const storage = try allocator.alloc(u8, executable_capacity + data_capacity);
    errdefer {
        std.crypto.secureZero(u8, storage);
        allocator.free(storage);
    }
    const exe = storage[0..executable_capacity];
    const data = storage[executable_capacity..];
    var length: usize = 0;
    var argc: usize = 0;
    var env_offset: usize = 0;
    var started: c_ulonglong = 0;
    if (rui_process_snapshot(pid, exe.ptr, exe.len, data.ptr, data.len, &length, &argc, &env_offset, &started) != 0)
        return error.HostProcessSnapshotUnavailable;
    const exe_end = std.mem.indexOfScalar(u8, exe, 0) orelse return error.InvalidHostProcessSnapshot;
    if (exe_end == 0 or exe[0] != '/' or started == 0 or length > data.len or env_offset > length or argc == 0)
        return error.InvalidHostProcessSnapshot;
    return decode(allocator, storage, pid, started, exe[0..exe_end], data[0..length], argc, env_offset);
}

fn decode(allocator: std.mem.Allocator, storage: []u8, pid: c_int, started: u64, executable: []const u8, data: []const u8, argc: usize, env_offset: usize) !Snapshot {
    if (env_offset > data.len or env_offset == 0 or data[env_offset - 1] != 0 or
        (data.len != 0 and data[data.len - 1] != 0) or
        std.mem.count(u8, data[0..env_offset], "\x00") != argc)
        return error.InvalidHostProcessSnapshot;
    const count = std.mem.count(u8, data, "\x00");
    const entries = try allocator.alloc([]const u8, count);
    errdefer allocator.free(entries);
    var cursor: usize = 0;
    for (entries, 0..) |*entry, index| {
        const end = std.mem.indexOfScalarPos(u8, data, cursor, 0) orelse return error.InvalidHostProcessSnapshot;
        entry.* = data[cursor..end];
        if (index >= argc) {
            const equals = std.mem.indexOfScalar(u8, entry.*, '=') orelse return error.InvalidHostProcessSnapshot;
            if (equals == 0) return error.InvalidHostProcessSnapshot;
        }
        cursor = end + 1;
    }
    return .{
        .pid = pid,
        .started = started,
        .executable = executable,
        .argv = entries[0..argc],
        .environment = entries[argc..],
        .storage = storage,
        .entries = entries,
    };
}

test "host identity rejects absent process and invalid peer without reading launch data" {
    try std.testing.expectError(error.HostPeerIdentityUnavailable, peer(-1));
    try std.testing.expectError(error.HostProcessSnapshotUnavailable, generation(-1));
    var started: c_ulonglong = 99;
    try std.testing.expect(rui_process_generation(-1, &started) != 0);
    try std.testing.expectEqual(@as(c_ulonglong, 0), started);
    try std.testing.expectError(error.HostProcessSnapshotUnavailable, snapshot(std.testing.allocator, -1));
}

test "host identity decoder preserves synthetic empty args and private environment" {
    const allocator = std.testing.allocator;
    const data = "rui\x00\x00host\x00PRIVATE=synthetic-only\x00EMPTY=\x00";
    const storage = try allocator.dupe(u8, data);
    var result = try decode(allocator, storage, 123, 456, "/synthetic/rui", storage, 3, 10);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), result.argv.len);
    try std.testing.expectEqualStrings("", result.argv[1]);
    try std.testing.expectEqualStrings("PRIVATE=synthetic-only", result.environment[0]);
    try std.testing.expectEqualStrings("EMPTY=", result.environment[1]);
}

test "host identity deinit wipes private bytes before allocator reclamation" {
    var memory: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const allocator = fixed.allocator();
    const storage = try allocator.dupe(u8, "rui\x00PRIVATE=synthetic-only\x00");
    const private_bytes = storage;
    var value = try decode(allocator, storage, 1, 1, "/rui", storage, 1, 4);
    value.deinit(allocator);
    for (private_bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "host identity decoder refuses truncated and malformed synthetic records" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "rui", "rui\x00NAME=unterminated", "rui\x00=bad\x00", "rui\x00bad\x00" }) |data| {
        try std.testing.expectError(error.InvalidHostProcessSnapshot, decode(allocator, &.{}, 1, 1, "/rui", data, 1, 4));
    }
    try std.testing.expectError(error.InvalidHostProcessSnapshot, decode(allocator, &.{}, 1, 1, "/rui", "rui\x00", 2, 4));
}

test "host identity native snapshot observes only a gated synthetic child" {
    // The child runs only this selected test, with a synthetic-only env. Its
    // gate avoids protected system binaries: Darwin intentionally
    // hides the environment of SIP-restricted executables such as /bin/sh.
    if (std.c.getenv("RUI_IDENTITY_FIXTURE")) |marker| {
        if (std.mem.eql(u8, std.mem.span(marker), "synthetic-only")) {
            if (std.c.write(1, "R", 1) != 1) std.c._exit(1);
            var release: [1]u8 = undefined;
            if (std.c.read(0, &release, 1) != 0) std.c._exit(1);
            std.c._exit(0);
        }
    }
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment: std.process.Environ.Map = .init(allocator);
    defer environment.deinit();
    try environment.put("RUI_IDENTITY_FIXTURE", "synthetic-only");
    const self_executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_executable);
    const argv: []const []const u8 = &.{ self_executable, "--listen=-" };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer if (child.id != null) {
        if (child.stdin) |input| input.close(io);
        child.stdin = null;
        // Preserve the body failure if fixture setup failed before the gate.
        _ = child.wait(io) catch {};
    };
    // The pinned Zig runner's protocol selects this one test even when this
    // module is imported into a broad root. Never rerun unrelated tests in the
    // synthetic child (they may own their own native fixtures).
    var read_buffer: [256]u8 = undefined;
    var write_buffer: [64]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &read_buffer);
    var writer = child.stdin.?.writerStreaming(io, &write_buffer);
    const protocol: std.zig.Client = .{ .in = &reader.interface, .out = &writer.interface };
    const hello = try protocol.receiveMessage();
    try std.testing.expectEqual(std.zig.Server.Message.Tag.zig_version, hello.tag);
    try reader.interface.discardAll(hello.bytes_len);
    const test_index: u32 = for (@import("builtin").test_functions, 0..) |test_function, index| {
        if (std.mem.endsWith(u8, test_function.name, "test.host identity native snapshot observes only a gated synthetic child")) break @intCast(index);
    } else return error.IdentityFixtureTestMissing;
    try protocol.serveRunTest(test_index);
    const entered = try protocol.receiveMessage();
    try std.testing.expectEqual(std.zig.Server.Message.Tag.test_started, entered.tag);
    try std.testing.expectEqual(@as(u32, 0), entered.bytes_len);
    try std.testing.expectEqual(@as(u8, 'R'), try reader.interface.takeByte());
    const before_generation = try generation(child.id.?);
    var first = try snapshot(allocator, child.id.?);
    defer first.deinit(allocator);
    var second = try snapshot(allocator, child.id.?);
    defer second.deinit(allocator);
    try std.testing.expectEqual(child.id.?, first.pid);
    try std.testing.expect(first.started != 0);
    try std.testing.expectEqual(before_generation, first.started);
    try std.testing.expectEqual(first.started, try generation(child.id.?));
    try std.testing.expectEqual(first.started, second.started);
    try std.testing.expectEqualStrings(first.executable, second.executable);
    try std.testing.expectEqual(@as(usize, 2), first.argv.len);
    for (argv, first.argv) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    var marker = false;
    for (first.environment) |entry| {
        if (std.mem.eql(u8, entry, "RUI_IDENTITY_FIXTURE=synthetic-only")) marker = true;
    }
    try std.testing.expect(marker);

    // Tiny native output bounds must reject, not truncate, and erase partial
    // private data. Never ask the adapter to inspect this test's environment.
    var exe: [4096]u8 = undefined;
    var data: [1]u8 = .{255};
    var length: usize = 99;
    var argc: usize = 99;
    var env_offset: usize = 99;
    var started: c_ulonglong = 99;
    try std.testing.expect(rui_process_snapshot(child.id.?, &exe, exe.len, &data, data.len, &length, &argc, &env_offset, &started) != 0);
    try std.testing.expectEqual(@as(u8, 0), data[0]);
    try std.testing.expectEqual(@as(usize, 0), length);
    try std.testing.expectEqual(@as(c_ulonglong, 0), started);
    const exited_pid = child.id.?;
    child.stdin.?.close(io);
    child.stdin = null;
    try std.testing.expect((try child.wait(io)).success());
    try std.testing.expectError(error.HostProcessSnapshotUnavailable, snapshot(allocator, exited_pid));
    try std.testing.expectError(error.HostProcessSnapshotUnavailable, generation(exited_pid));
}

test "host identity native Unix peer is same effective user and actual process" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair));
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    try std.testing.expectEqual(std.c.getpid(), try peer(pair[0]));
    try std.testing.expectEqual(std.c.getpid(), try peer(pair[1]));
}
