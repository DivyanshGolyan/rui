//! The launch frame: how a program that embeds Rui starts `rui host serve
//! --launch-frame`. It writes one frame to the Host's stdin, a 4-byte
//! big-endian length and then that many bytes of UTF-8 JSON, and keeps the
//! pipe open: the Host lives until stdin closes (D5, D112, D130). The frame
//! carries the provider key, which so never touches disk, argv or the
//! environment (D70, D108).
const std = @import("std");
const api_key = @import("api_key.zig");
const protocol = @import("protocol.zig");
const core_tools = @import("core_tools.zig");
const platform = @import("platform.zig");
const http1 = @import("http1/request.zig");

/// The one frame version.
pub const version = 1;
/// A frame longer than this is refused before it is read.
pub const max_frame_bytes = 1024 * 1024;
/// The launched Host's socket, inside the frame's `runtimeDir`.
pub const socket_name = "rui.sock";
/// The longest `runtimeDir` whose socket path still binds.
pub const max_runtime_dir_bytes = platform.max_launch_socket_path_bytes - "/".len - socket_name.len;
const max_refusal_message_bytes = 256;

/// A refusal at open, as `RuiStartError.code` names it (D136).
pub const StartError = enum {
    launch_frame_invalid,
    invalid_preset,
    store_locked,
    runtime_dir_unusable,
    tool_name_collision,
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
    /// The MCP servers whose tools the Host offers (D120).
    mcp_servers: [max_mcp_servers]McpServer = @splat(.{}),
    mcp_server_count: usize = 0,
    /// Only the specs given at connect, borrowed by the Host. No allocation
    /// at all for an omitted or empty presets object (D22).
    presets: []const core_tools.Preset = &.{},
    presets_memory: ?std.heap.ArenaAllocator = null,

    pub const max_base_url_bytes = 2048;
    pub const max_mcp_servers = 8;
    pub const max_mcp_name_bytes = 64;

    /// One entry of `mcpServers`. The name labels the server in errors; the
    /// token is a secret and is wiped with the key.
    pub const McpServer = struct {
        name: protocol.Bounded(max_mcp_name_bytes) = .{},
        url: protocol.Bounded(http1.max_url_bytes) = .{},
        bearer_token: api_key.Key = .{},
        call_timeout_ms: u32 = 0,
    };

    pub fn mcpServerSlice(self: *const Frame) []const McpServer {
        return self.mcp_servers[0..self.mcp_server_count];
    }

    /// Where the Store is. A `mysql://` prefix selects the URL form, which
    /// the Store thread's Host wiring adds (D175); anything else is a
    /// SQLite Store directory.
    pub const Store = union(enum) {
        sqlite_dir: protocol.Bounded(protocol.max_store_bytes),
    };

    pub fn deinit(self: *Frame) void {
        self.wipe();
        if (self.presets_memory) |*memory| memory.deinit();
        self.presets_memory = null;
        self.presets = &.{};
    }

    pub fn wipe(self: *Frame) void {
        self.key.wipe();
        for (&self.mcp_servers) |*server| server.bearer_token.wipe();
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
    /// An invalid preset diagnostic survives the parsing arena.
    buffer: [max_refusal_message_bytes]u8 = undefined,
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

/// The frame as JSON. Unknown fields are refused.
pub const Wire = struct {
    v: i64,
    store: []const u8,
    provider: struct { kind: []const u8, baseUrl: []const u8, key: []const u8 },
    runtimeDir: []const u8,
    activeCapacity: ?i64 = null,
    paused: bool = false,
    presets: std.json.Value = .{ .object = .empty },
    mcpServers: []const struct { name: []const u8, url: []const u8, bearerToken: []const u8, callTimeoutMs: i64 } = &.{},
};

/// Parses `bytes` into `frame`; the key is copied, and every other copy of
/// it is zeroed before this returns.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, frame: *Frame, refusal: *Refusal) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Bound recursive outputSchema serialization before parsing any preset.
    var scanner = std.json.Scanner.initCompleteInput(arena.allocator(), bytes);
    defer scanner.deinit();
    try scanner.ensureTotalStackCapacity(protocol.max_json_depth);
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return refuse(refusal, "the frame is not well-formed JSON"),
        };
        if (scanner.stackHeight() > protocol.max_json_depth) return refuse(refusal, "the frame exceeds the maximum JSON nesting depth");
        if (token == .end_of_document) break;
    }
    const wire = std.json.parseFromSliceLeaky(Wire, arena.allocator(), bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return refuse(refusal, "the frame is not a JSON object of v, store, provider, runtimeDir and optional activeCapacity, paused, mcpServers and presets"),
    };
    defer std.crypto.secureZero(u8, @constCast(wire.provider.key));
    defer for (wire.mcpServers) |server| std.crypto.secureZero(u8, @constCast(server.bearerToken));
    errdefer frame.wipe();
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
    if (wire.mcpServers.len > Frame.max_mcp_servers) return refuse(refusal, "mcpServers names too many servers");
    for (wire.mcpServers, 0..) |server, at| {
        if (!validServerName(server.name)) return refuse(refusal, "an mcpServers name must be 1 to 64 letters, digits, hyphens or underscores");
        for (wire.mcpServers[0..at]) |earlier| {
            if (std.mem.eql(u8, earlier.name, server.name)) return refuse(refusal, "mcpServers names must differ");
        }
        _ = http1.parseTarget(server.url) catch return refuse(refusal, "an mcpServers url must be plain http to a loopback address");
        if (!api_key.valid(server.bearerToken)) return refuse(refusal, "an mcpServers bearerToken must be one line of visible characters, at most 1024 bytes");
        if (server.callTimeoutMs < 1) return refuse(refusal, "an mcpServers callTimeoutMs must be at least 1");
        const entry = &frame.mcp_servers[at];
        entry.name.set(server.name) catch unreachable;
        entry.url.set(server.url) catch unreachable;
        @memcpy(entry.bearer_token.bytes[0..server.bearerToken.len], server.bearerToken);
        entry.bearer_token.len = server.bearerToken.len;
        entry.call_timeout_ms = std.math.cast(u32, server.callTimeoutMs) orelse return refuse(refusal, "an mcpServers callTimeoutMs is too large");
        frame.mcp_server_count = at + 1;
    }
    const presets = switch (wire.presets) {
        .object => |object| object,
        else => return refusePreset(refusal, "presets", "must be an object of named agent specs"),
    };
    if (presets.count() > core_tools.max_presets) return refusePreset(refusal, "presets", "must name at most 64 presets");
    if (presets.count() == 0) return;
    const checked_configuration = try arena.allocator().create(protocol.Configuration);
    var entries = presets.iterator();
    while (entries.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!core_tools.validPresetName(name)) return refusePreset(refusal, name, "name must be 1 to 64 bytes of [a-z0-9_-]");
        const spec = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return refusePreset(refusal, name, "spec must be an object"),
        };
        const checked = try core_tools.parseAgentSpec(arena.allocator(), spec, checked_configuration);
        if (checked == .rejected) return refusePreset(refusal, name, checked.rejected);
    }
    // Retain just the preset data, never the provider key or a max-sized
    // collection. The serialized copy is temporary, in the parsing arena.
    var memory: std.heap.ArenaAllocator = .init(gpa);
    errdefer memory.deinit();
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), wire.presets, .{});
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, memory.allocator(), encoded, .{ .allocate = .alloc_always });
    const retained = try memory.allocator().alloc(core_tools.Preset, presets.count());
    var saved_entries = saved.object.iterator();
    for (retained) |*preset| {
        const entry = saved_entries.next().?;
        preset.* = .{ .name = entry.key_ptr.*, .spec = entry.value_ptr.object };
    }
    frame.presets = retained;
    frame.presets_memory = memory;
}

fn refusePreset(refusal: *Refusal, name: []const u8, reason: []const u8) error{LaunchFrameInvalid} {
    refusal.* = .{ .code = .invalid_preset, .message = "" };
    const shown = core_tools.diagnosticName(name);
    refusal.message = std.fmt.bufPrint(&refusal.buffer, "preset {s}: {s}", .{ shown, reason }) catch unreachable;
    return error.LaunchFrameInvalid;
}

fn validServerName(name: []const u8) bool {
    if (name.len == 0 or name.len > Frame.max_mcp_name_bytes) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

/// The one stdout line a refused launch writes before exiting.
pub fn writeRefusal(io: std.Io, refusal: Refusal) void {
    // Every diagnostic byte may need a six-byte JSON escape.
    var buffer: [6 * max_refusal_message_bytes + 128]u8 = undefined;
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

test "a launch frame carries MCP servers" {
    var frame: Frame = .{};
    defer frame.wipe();
    var refusal: Refusal = undefined;
    try parse(std.testing.allocator,
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r","mcpServers":[{"name":"drift","url":"http://127.0.0.1:3000/mcp","bearerToken":"t0k","callTimeoutMs":1800000}]}
    , &frame, &refusal);
    try std.testing.expectEqual(@as(usize, 1), frame.mcpServerSlice().len);
    const server = frame.mcpServerSlice()[0];
    try std.testing.expectEqualStrings("drift", server.name.slice());
    try std.testing.expectEqualStrings("http://127.0.0.1:3000/mcp", server.url.slice());
    try std.testing.expectEqualStrings("t0k", server.bearer_token.slice());
    try std.testing.expectEqual(@as(u32, 1800000), server.call_timeout_ms);
    frame.wipe();
    try std.testing.expectEqual(@as(usize, 0), frame.mcp_servers[0].bearer_token.len);
}

test "a launch frame refuses a bad MCP server" {
    const head =
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r","mcpServers":[
    ;
    const cases = [_][]const u8{
        head ++
            \\{"name":"a b","url":"http://127.0.0.1/m","bearerToken":"t","callTimeoutMs":1}]}
        ,
        head ++
            \\{"name":"","url":"http://127.0.0.1/m","bearerToken":"t","callTimeoutMs":1}]}
        ,
        head ++
            \\{"name":"a","url":"http://example.com/m","bearerToken":"t","callTimeoutMs":1}]}
        ,
        head ++
            \\{"name":"a","url":"https://127.0.0.1/m","bearerToken":"t","callTimeoutMs":1}]}
        ,
        head ++
            \\{"name":"a","url":"http://127.0.0.1/m","bearerToken":"two words","callTimeoutMs":1}]}
        ,
        head ++
            \\{"name":"a","url":"http://127.0.0.1/m","bearerToken":"t","callTimeoutMs":0}]}
        ,
        head ++
            \\{"name":"a","url":"http://127.0.0.1/m","bearerToken":"t","callTimeoutMs":99999999999}]}
        ,
        head ++
            \\{"name":"a","url":"http://127.0.0.1/m","bearerToken":"t","callTimeoutMs":1},{"name":"a","url":"http://127.0.0.1/n","bearerToken":"t","callTimeoutMs":1}]}
        ,
        head ++
            \\{"name":"a","url":"http://127.0.0.1/m","bearerToken":"t"}]}
        ,
    };
    for (cases) |json| {
        var frame: Frame = .{};
        var refusal: Refusal = undefined;
        try std.testing.expectError(error.LaunchFrameInvalid, parse(std.testing.allocator, json, &frame, &refusal));
        try std.testing.expectEqual(StartError.launch_frame_invalid, refusal.code);
        for (frame.mcp_servers) |server| try std.testing.expectEqual(@as(usize, 0), server.bearer_token.len);
    }
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
        \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r","unknown":{}}
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

const preset_head =
    \\{"v":1,"store":"/s","provider":{"kind":"openai_key","baseUrl":"https://a.b/v1","key":"k"},"runtimeDir":"/r","presets":
;
const creating_spec =
    \\{"model":"model-a","effort":null,"compactAt":1000,"tools":[],"permissionMode":"ask"}
;

test "presets in a launch frame are owned until frame deinit" {
    var frame: Frame = .{};
    defer frame.deinit();
    var refusal: Refusal = undefined;
    const input = try std.testing.allocator.dupe(u8, preset_head ++ "{\"review-1\":" ++ creating_spec ++ "}}");
    try parse(std.testing.allocator, input, &frame, &refusal);
    std.testing.allocator.free(input);
    try std.testing.expectEqual(@as(usize, 1), frame.presets.len);
    try std.testing.expectEqualStrings("review-1", frame.presets[0].name);
    try std.testing.expectEqualStrings("model-a", frame.presets[0].spec.get("model").?.string);
    frame.deinit();
    try std.testing.expectEqual(@as(usize, 0), frame.presets.len);
    try std.testing.expect(frame.presets_memory == null);
    try parse(std.testing.allocator, preset_head ++ "{}}", &frame, &refusal);
    try std.testing.expect(frame.presets_memory == null);
}

test "presets in a launch frame refuse bad names and incomplete specs with their fields" {
    for ([_]struct { json: []const u8, name: []const u8, field: []const u8 }{
        .{ .json = preset_head ++ "{\"\":" ++ creating_spec ++ "}}", .name = "", .field = "name" },
        .{ .json = preset_head ++ "{\"Review\":" ++ creating_spec ++ "}}", .name = "Review", .field = "name" },
        .{ .json = preset_head ++ "{\"a.b\":" ++ creating_spec ++ "}}", .name = "a.b", .field = "name" },
        .{ .json = preset_head ++ "{\"" ++ @as([63]u8, @splat('a')) ++ "é\":" ++ creating_spec ++ "}}", .name = "aaaa", .field = "name" },
        .{ .json = preset_head ++ "{\"" ++ @as([core_tools.max_preset_name_bytes + 1]u8, @splat('a')) ++ "\":" ++ creating_spec ++ "}}", .name = "aaaa", .field = "name" },
        .{ .json = preset_head ++ "{\"review\":{}}}", .name = "review", .field = "model" },
        .{ .json = preset_head ++ "{\"review\":{\"model\":\"m\",\"compactAt\":1,\"tools\":[],\"permissionMode\":\"ask\"}}}", .name = "review", .field = "effort" },
        .{ .json = preset_head ++ "{\"review\":{\"model\":\"m\",\"effort\":null,\"tools\":[],\"permissionMode\":\"ask\"}}}", .name = "review", .field = "compactAt" },
        .{ .json = preset_head ++ "{\"review\":{\"model\":\"m\",\"effort\":null,\"compactAt\":1,\"permissionMode\":\"ask\"}}}", .name = "review", .field = "tools" },
        .{ .json = preset_head ++ "{\"review\":{\"model\":\"m\",\"effort\":null,\"compactAt\":1,\"tools\":[]}}}", .name = "review", .field = "permissionMode" },
        .{ .json = preset_head ++ "{\"review\":{\"model\":\"m\",\"effort\":null,\"compactAt\":1,\"tools\":[\"bash\"],\"permissionMode\":\"ask\"}}}", .name = "review", .field = "workspace" },
        .{ .json = preset_head ++ "{\"review\":null}}", .name = "review", .field = "spec" },
        .{ .json = preset_head ++ "null}", .name = "presets", .field = "object" },
        .{ .json = preset_head ++ "[]}", .name = "presets", .field = "object" },
    }) |case| {
        var frame: Frame = .{};
        defer frame.deinit();
        var refusal: Refusal = undefined;
        try std.testing.expectError(error.LaunchFrameInvalid, parse(std.testing.allocator, case.json, &frame, &refusal));
        try std.testing.expectEqual(StartError.invalid_preset, refusal.code);
        try std.testing.expect(std.unicode.utf8ValidateSlice(refusal.message));
        try std.testing.expect(std.mem.indexOf(u8, refusal.message, case.name) != null);
        try std.testing.expect(std.mem.indexOf(u8, refusal.message, case.field) != null);
    }
}

test "presets in a launch frame accept their bounds and refuse one more" {
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    var json: std.Io.Writer.Allocating = .init(memory.allocator());
    const out = &json.writer;
    try out.writeAll(preset_head ++ "{");
    for (0..core_tools.max_presets) |at| {
        if (at != 0) try out.writeByte(',');
        try out.print("\"p{d}\":", .{at});
        try out.writeAll(creating_spec);
    }
    try out.writeAll("}}");
    var frame: Frame = .{};
    defer frame.deinit();
    var refusal: Refusal = undefined;
    try parse(std.testing.allocator, json.written(), &frame, &refusal);
    try std.testing.expectEqual(core_tools.max_presets, frame.presets.len);
    frame.deinit();
    const extra = try std.mem.concat(memory.allocator(), u8, &.{ json.written()[0 .. json.written().len - 2], ",\"extra\":", creating_spec, "}}" });
    try std.testing.expectError(error.LaunchFrameInvalid, parse(std.testing.allocator, extra, &frame, &refusal));
    try std.testing.expectEqual(StartError.invalid_preset, refusal.code);
    const longest_name = preset_head ++ "{\"" ++ @as([core_tools.max_preset_name_bytes]u8, @splat('a')) ++ "\":" ++ creating_spec ++ "}}";
    try parse(std.testing.allocator, longest_name, &frame, &refusal);
    try std.testing.expectEqual(core_tools.max_preset_name_bytes, frame.presets[0].name.len);
}
