//! The launch frame: how a program that embeds Rui starts `rui host serve
//! --launch-frame`. It writes one frame to the Host's stdin, a 4-byte
//! big-endian length and then that many bytes of UTF-8 JSON, and keeps the
//! pipe open: the Host lives until stdin closes (D5, D112, D130). The frame
//! carries the provider key, which so never touches disk, argv or the
//! environment (D70, D108).
const std = @import("std");
const api_key = @import("api_key.zig");
const protocol = @import("protocol.zig");
const platform = @import("platform.zig");

/// The one frame version.
pub const version = 1;
/// A frame longer than this is refused before it is read.
pub const max_frame_bytes = 1024 * 1024;
/// The launched Host's socket, inside the frame's `runtimeDir`.
pub const socket_name = "rui.sock";
/// The longest `runtimeDir` whose socket path still binds.
pub const max_runtime_dir_bytes = platform.max_launch_socket_path_bytes - "/".len - socket_name.len;

/// A refusal at open, as `RuiStartError.code` names it (D136).
pub const StartError = enum {
    launch_frame_invalid,
    store_locked,
    runtime_dir_unusable,
};

pub const Frame = struct {
    store: Store = .{ .sqlite_dir = .{} },
    /// `baseUrl`, as the frame spells it; `providers.endpointUnder` checks it.
    base_url: protocol.Bounded(max_base_url_bytes) = .{},
    key: api_key.Key = .{},
    runtime_dir: protocol.Bounded(max_runtime_dir_bytes) = .{},
    active_capacity: ?usize = null,
    /// The Host opens with Turns paused, as if `host_pause` had just run (D196).
    paused: bool = false,

    pub const max_base_url_bytes = 2048;

    /// Where the Store is. A `mysql://` prefix selects the URL form, which
    /// the Store thread's Host wiring adds (D175); anything else is a
    /// SQLite Store directory.
    pub const Store = union(enum) {
        sqlite_dir: protocol.Bounded(protocol.max_store_bytes),
    };

    pub fn wipe(self: *Frame) void {
        self.key.wipe();
    }

    /// `runtimeDir/rui.sock`.
    pub fn socketPath(self: *const Frame, buffer: *[platform.max_launch_socket_path_bytes]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}/" ++ socket_name, .{self.runtime_dir.slice()}) catch unreachable;
    }
};

/// Why a frame was refused, for the one line that reports it.
pub const Refusal = struct {
    code: StartError,
    message: []const u8,
};

/// Reads one frame from `file` into `frame`. On refusal, `refusal` says why.
pub fn read(io: std.Io, file: std.Io.File, gpa: std.mem.Allocator, frame: *Frame, refusal: *Refusal) !void {
    var prefix: [4]u8 = undefined;
    readExact(io, file, &prefix) catch return refuse(refusal, "stdin closed before the 4-byte frame length");
    const length = std.mem.readInt(u32, &prefix, .big);
    if (length == 0 or length > max_frame_bytes) return refuse(refusal, "the frame length must be 1 to 1048576 bytes");
    const bytes = try gpa.alloc(u8, length);
    defer {
        std.crypto.secureZero(u8, bytes);
        gpa.free(bytes);
    }
    readExact(io, file, bytes) catch return refuse(refusal, "stdin closed before the whole frame arrived");
    return parse(gpa, bytes, frame, refusal);
}

fn readExact(io: std.Io, file: std.Io.File, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const count = try file.readStreaming(io, &.{buffer[filled..]});
        if (count == 0) return error.EndOfStream;
        filled += count;
    }
}

fn refuse(refusal: *Refusal, message: []const u8) error{LaunchFrameInvalid} {
    refusal.* = .{ .code = .launch_frame_invalid, .message = message };
    return error.LaunchFrameInvalid;
}

/// The frame as JSON. Unknown fields are refused: `mcpServers` and
/// `presets` arrive with the units that use them.
const Wire = struct {
    v: i64,
    store: []const u8,
    provider: struct { kind: []const u8, baseUrl: []const u8, key: []const u8 },
    runtimeDir: []const u8,
    activeCapacity: ?i64 = null,
    paused: bool = false,
};

/// Parses `bytes` into `frame`; the key is copied, and every other copy of
/// it is zeroed before this returns.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, frame: *Frame, refusal: *Refusal) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const wire = std.json.parseFromSliceLeaky(Wire, arena.allocator(), bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return refuse(refusal, "the frame is not a JSON object of v, store, provider, runtimeDir and optional activeCapacity"),
    };
    defer std.crypto.secureZero(u8, @constCast(wire.provider.key));
    if (wire.v != version) return refuse(refusal, "v must be 1");
    if (wire.store.len == 0) return refuse(refusal, "store must name a Store directory");
    if (std.mem.startsWith(u8, wire.store, "mysql://")) return refuse(refusal, "this build opens SQLite Stores only");
    frame.store = .{ .sqlite_dir = .{} };
    frame.store.sqlite_dir.set(wire.store) catch return refuse(refusal, "store is too long");
    if (!std.mem.eql(u8, wire.provider.kind, "openai_key")) return refuse(refusal, "provider.kind must be openai_key");
    frame.base_url.set(wire.provider.baseUrl) catch return refuse(refusal, "provider.baseUrl is too long");
    if (!api_key.valid(wire.provider.key)) return refuse(refusal, "provider.key must be one line of visible characters, at most 1024 bytes");
    @memcpy(frame.key.bytes[0..wire.provider.key.len], wire.provider.key);
    frame.key.len = wire.provider.key.len;
    errdefer frame.key.wipe();
    if (wire.runtimeDir.len == 0 or wire.runtimeDir[0] != '/') return refuse(refusal, "runtimeDir must be an absolute path");
    frame.runtime_dir.set(std.mem.trimEnd(u8, wire.runtimeDir, "/")) catch return refuse(refusal, "runtimeDir is too long for a socket path");
    if (frame.runtime_dir.len == 0) return refuse(refusal, "runtimeDir must not be /");
    if (wire.activeCapacity) |capacity| {
        if (capacity < 1) return refuse(refusal, "activeCapacity must be at least 1");
        frame.active_capacity = std.math.cast(usize, capacity) orelse return refuse(refusal, "activeCapacity is too large");
    }
    frame.paused = wire.paused;
}

/// The one stdout line a refused launch writes before exiting.
pub fn writeRefusal(io: std.Io, refusal: Refusal) void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    out.writeAll("{\"rui_start_error\":{\"code\":\"") catch return;
    out.writeAll(@tagName(refusal.code)) catch return;
    out.writeAll("\",\"message\":") catch return;
    std.json.Stringify.encodeJsonString(refusal.message, .{}, &out) catch return;
    out.writeAll("}}\n") catch return;
    std.Io.File.stdout().writeStreamingAll(io, out.buffered()) catch {};
}

fn frameBytes(comptime json: []const u8) [4 + json.len]u8 {
    var out: [4 + json.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], json.len, .big);
    @memcpy(out[4..], json);
    return out;
}

const valid_json =
    \\{"v":1,"store":"/tmp/s","provider":{"kind":"openai_key","baseUrl":"https://api.openai.com/v1","key":"sk-test"},"runtimeDir":"/tmp/r/","activeCapacity":4}
;

test "a launch frame carries the Store, provider key and runtime directory" {
    var frame: Frame = .{};
    defer frame.wipe();
    var refusal: Refusal = undefined;
    try parse(std.testing.allocator, valid_json, &frame, &refusal);
    try std.testing.expectEqualStrings("/tmp/s", frame.store.sqlite_dir.slice());
    try std.testing.expectEqualStrings("https://api.openai.com/v1", frame.base_url.slice());
    try std.testing.expectEqualStrings("sk-test", frame.key.slice());
    try std.testing.expectEqualStrings("/tmp/r", frame.runtime_dir.slice());
    try std.testing.expectEqual(@as(?usize, 4), frame.active_capacity);
    var buffer: [platform.max_launch_socket_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/r/rui.sock", frame.socketPath(&buffer));
}

test "a launch frame can open the Host paused" {
    var frame: Frame = .{};
    defer frame.wipe();
    var refusal: Refusal = undefined;
    try parse(std.testing.allocator, valid_json, &frame, &refusal);
    try std.testing.expect(!frame.paused);
    try parse(std.testing.allocator,
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r","paused":true}
    , &frame, &refusal);
    try std.testing.expect(frame.paused);
}

test "a launch frame is refused with launch_frame_invalid when it is wrong" {
    const cases = [_][]const u8{
        "not json",
        \\{"v":2,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r"}
        ,
        \\{"v":1,"store":"","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r"}
        ,
        \\{"v":1,"store":"mysql://u:p@h/db","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r"}
        ,
        \\{"v":1,"store":"/s","provider":{"kind":"chatgpt","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r"}
        ,
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"two words"},"runtimeDir":"/r"}
        ,
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"relative"}
        ,
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/"}
        ,
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r","activeCapacity":0}
        ,
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r","presets":{}}
        ,
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"}}
        ,
        "{\"v\":1,\"store\":\"/s\",\"provider\":{\"kind\":\"openai_key\",\"baseUrl\":\"https://a.b/v1\",\"key\":\"k\"},\"runtimeDir\":\"/" ++ &@as([max_runtime_dir_bytes + 1]u8, @splat('r')) ++ "\"}",
    };
    for (cases) |json| {
        var frame: Frame = .{};
        var refusal: Refusal = undefined;
        try std.testing.expectError(error.LaunchFrameInvalid, parse(std.testing.allocator, json, &frame, &refusal));
        try std.testing.expectEqual(StartError.launch_frame_invalid, refusal.code);
        try std.testing.expectEqual(@as(usize, 0), frame.key.len);
    }
}

test "a launch frame is read whole from a pipe, and a short one is refused" {
    const io = std.testing.io;
    const bytes = frameBytes(valid_json);
    for ([_]usize{ bytes.len, 2, 4, bytes.len - 1 }) |sent| {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        defer reader.close(io);
        const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        try writer.writeStreamingAll(io, bytes[0..sent]);
        writer.close(io);
        var frame: Frame = .{};
        defer frame.wipe();
        var refusal: Refusal = undefined;
        if (sent == bytes.len) {
            try read(io, reader, std.testing.allocator, &frame, &refusal);
            try std.testing.expectEqualStrings("sk-test", frame.key.slice());
        } else {
            try std.testing.expectError(error.LaunchFrameInvalid, read(io, reader, std.testing.allocator, &frame, &refusal));
        }
    }
}

test "an oversized frame length is refused before any body is read" {
    const io = std.testing.io;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer reader.close(io);
    const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer writer.close(io);
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, max_frame_bytes + 1, .big);
    try writer.writeStreamingAll(io, &prefix);
    var frame: Frame = .{};
    var refusal: Refusal = undefined;
    try std.testing.expectError(error.LaunchFrameInvalid, read(io, reader, std.testing.allocator, &frame, &refusal));
}
