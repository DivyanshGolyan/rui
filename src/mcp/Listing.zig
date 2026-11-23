const std = @import("std");
const http1 = @import("../http1/request.zig");
const Request = @import("Request.zig");
const post = @import("post.zig");
const reply = @import("reply.zig");
const shape = @import("shape.zig");
const document = @import("document.zig");
const stderr = @import("../stderr.zig");

const Listing = @This();

pub const max_pages = 16;
pub const max_name_bytes = 64;

pub const Entry = struct {
    name: []const u8,
    description: ?[]const u8,
    input_schema: []const u8,
};

pub const Storage = struct {
    entries: []Entry,
    arena: []u8,
    answer: []u8,
    request: []u8,
};

pub const Error = Request.Error || post.Error || error{
    TooMany,
    NoRoom,
    BadSchema,
};

pub const Outcome = union(enum) {
    waiting,
    listed,
    unavailable,
};

server: post.Server,
client: post.Client,
storage: Storage,
current: Request,
page_open: bool,
pages: usize,
cursor_len: ?usize,
cursor_bytes: [256]u8,
count: usize,
arena_used: usize,
left_out: usize,
/// The smallest positive `ttlMs` over the pages read so far; null while no page carried one.
ttl_ms: ?u64,

pub fn init(self: *Listing, server: post.Server, client: post.Client, storage: Storage) Error!void {
    self.* = .{
        .server = server,
        .client = client,
        .storage = storage,
        .current = undefined,
        .page_open = false,
        .pages = 0,
        .cursor_len = null,
        .cursor_bytes = undefined,
        .count = 0,
        .arena_used = 0,
        .left_out = 0,
        .ttl_ms = null,
    };
    try self.openPage();
}

pub fn deinit(self: *Listing) void {
    if (self.page_open) self.current.deinit();
    self.page_open = false;
}

pub fn fd(self: *const Listing) std.posix.fd_t {
    return self.current.fd();
}

pub fn events(self: *const Listing) i16 {
    return self.current.events();
}

pub fn entries(self: *const Listing) []const Entry {
    return self.storage.entries[0..self.count];
}

pub fn leftOut(self: *const Listing) usize {
    return self.left_out;
}

/// How long the listed tools stay fresh: the smallest positive page ttl, or null when no page gave one.
pub fn ttlMs(self: *const Listing) ?u64 {
    return self.ttl_ms;
}

fn openPage(self: *Listing) Error!void {
    if (self.pages == max_pages) return error.TooMany;
    self.pages += 1;
    const id: u64 = self.pages;
    var writer: std.Io.Writer = .fixed(self.storage.request);
    const cursor: ?[]const u8 = if (self.cursor_len) |length| self.cursor_bytes[0..length] else null;
    post.writeList(&writer, self.server, self.client, id, cursor) catch |err| switch (err) {
        error.WriteFailed => return error.NoRoom,
        else => |other| return other,
    };
    try self.current.init(self.server.target, writer.buffered(), id, self.storage.answer);
    self.page_open = true;
}

pub fn advance(self: *Listing) Error!Outcome {
    while (true) {
        const outcome = try self.current.advance();
        switch (outcome) {
            .waiting => return .waiting,
            .failed => return .unavailable,
            .answered => |message| switch (message) {
                .notification => unreachable,
                .rpc_error => return .unavailable,
                .result => |result| {
                    if (!try self.take(result)) return .listed;
                    self.current.deinit();
                    self.page_open = false;
                    try self.openPage();
                },
            },
        }
    }
}

fn take(self: *Listing, result: []const u8) Error!bool {
    const list = reply.readList(result) catch return error.BadSchema;
    if (list.ttl_ms) |ttl| self.ttl_ms = if (self.ttl_ms) |kept| @min(kept, ttl) else ttl;
    var tools = reply.Tools.init(list);
    while (tools.next()) |listed| switch (listed) {
        .left_out => |left| self.leave(left.name, "bad definition"),
        .tool => |tool| try self.add(tool),
    };
    const cursor = list.next_cursor orelse return false;
    if (cursor.len > self.cursor_bytes.len) return error.NoRoom;
    @memcpy(self.cursor_bytes[0..cursor.len], cursor);
    self.cursor_len = cursor.len;
    return true;
}

/// Counts a tool the listing leaves out and logs it with its reason.
fn leave(self: *Listing, name: ?[]const u8, reason: []const u8) void {
    self.left_out += 1;
    stderr.diagnostic("rui: MCP server {s}: tool {s} left out: {s}\n", .{ self.server.label, name orelse "(unnamed)", reason });
}

/// Keeps a listed tool whose definition is usable. A name two tools share is kept on both sides: the
/// merge offers neither under a clashing name. A tool past the entry capacity or with a bad definition is left out.
fn add(self: *Listing, tool: reply.Tool) Error!void {
    if (self.count == self.storage.entries.len) {
        var reason: [64]u8 = undefined;
        self.leave(tool.name, std.fmt.bufPrint(&reason, "more than {d} tools from this server", .{self.storage.entries.len}) catch "too many tools from this server");
        return;
    }
    if (!functionName(tool.name)) {
        self.leave(tool.name, "bad definition");
        return;
    }
    const mark = self.arena_used;
    const name = try self.copy(tool.name);
    const description: ?[]const u8 = if (tool.description) |text| try self.copy(text) else null;
    const room = self.storage.arena[self.arena_used..];
    var writer: std.Io.Writer = .fixed(room);
    shape.writeSchema(&writer, tool.input_schema) catch |err| switch (err) {
        error.WriteFailed => return error.NoRoom,
        error.NameTaken, error.Malformed => {
            self.arena_used = mark;
            self.leave(tool.name, "bad definition");
            return;
        },
    };
    const schema = writer.buffered();
    self.arena_used += schema.len;
    self.storage.entries[self.count] = .{ .name = name, .description = description, .input_schema = schema };
    self.count += 1;
}

fn copy(self: *Listing, bytes: []const u8) Error![]const u8 {
    const room = self.storage.arena[self.arena_used..];
    if (bytes.len > room.len) return error.NoRoom;
    @memcpy(room[0..bytes.len], bytes);
    self.arena_used += bytes.len;
    return room[0..bytes.len];
}

fn functionName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

const Script = @import("test_server.zig");

fn target(script: *const Script, buffer: []u8) !http1.Target {
    return http1.parseTarget(try std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/mcp", .{script.port}));
}

fn run(script: *Script, storage: Storage, listing: *Listing) !Outcome {
    try script.start();
    defer script.stop();
    var url: [64]u8 = undefined;
    try listing.init(.{ .target = try target(script, &url), .bearer_token = "t" }, .{ .name = "rui", .version = "test" }, storage);
    defer listing.deinit();
    while (true) {
        const outcome = try listing.advance();
        if (outcome != .waiting) return outcome;
        var poll_fd = [_]std.c.pollfd{.{ .fd = listing.fd(), .events = listing.events(), .revents = 0 }};
        if (std.c.poll(&poll_fd, 1, 10_000) <= 0) return error.ConnectionLost;
    }
}

const TestRoom = struct {
    entries: [8]Entry = undefined,
    arena: [2048]u8 = undefined,
    answer: [1024]u8 = undefined,
    request: [1024]u8 = undefined,

    fn storage(self: *TestRoom) Storage {
        return .{ .entries = &self.entries, .arena = &self.arena, .answer = &self.answer, .request = &self.request };
    }
};

fn pageOf(comptime tools: []const u8, comptime cursor: ?[]const u8) []const u8 {
    const next = if (cursor) |c| ",\"nextCursor\":\"" ++ c ++ "\"" else "";
    return Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[" ++ tools ++ "]" ++ next ++ "}}");
}

fn pageId(comptime id: u8, comptime tools: []const u8) []const u8 {
    return Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":" ++ &[_]u8{'0' + id} ++ ",\"result\":{\"tools\":[" ++ tools ++ "]}}");
}

const search = "{\"name\":\"search\",\"description\":\"Find things\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}},\"required\":[\"q\"]},\"annotations\":{\"readOnlyHint\":true}}";
const write = "{\"name\":\"write\",\"inputSchema\":{\"type\":\"object\"}}";

test "a listing collects tools across pages and shapes their schemas" {
    var script: Script = .{ .reply = pageOf(search, "p2"), .more = &.{pageId(2, write)} };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    try std.testing.expectEqual(Outcome.listed, try run(&script, room.storage(), &listing));
    const found = listing.entries();
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("search", found[0].name);
    try std.testing.expectEqualStrings("Find things", found[0].description.?);
    try std.testing.expect(std.mem.indexOf(u8, found[0].input_schema, "rui_call_description") != null);
    try document.check(found[0].input_schema);
    try std.testing.expectEqualStrings("write", found[1].name);
    try std.testing.expect(found[1].description == null);
    try std.testing.expect(std.mem.indexOf(u8, script.seen[0..script.seen_len], "\"cursor\":\"p2\"") != null);
}

test "a tool with a bad definition or name is left out and counted" {
    const bad = "{\"name\":\"has.dot\",\"inputSchema\":{\"type\":\"object\"}},{\"inputSchema\":{}},";
    var script: Script = .{ .reply = pageOf(bad ++ write, null) };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    try std.testing.expectEqual(Outcome.listed, try run(&script, room.storage(), &listing));
    try std.testing.expectEqual(@as(usize, 1), listing.entries().len);
    try std.testing.expectEqual(@as(usize, 2), listing.leftOut());
}

test "a tool whose schema is malformed is left out and its siblings are kept" {
    const malformed = "{\"name\":\"bad\",\"description\":\"x\",\"inputSchema\":{\"properties\":[]}},{\"name\":\"worse\",\"inputSchema\":{\"required\":\"q\"}},";
    var script: Script = .{ .reply = pageOf(malformed ++ write, null) };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    try std.testing.expectEqual(Outcome.listed, try run(&script, room.storage(), &listing));
    try std.testing.expectEqual(@as(usize, 1), listing.entries().len);
    try std.testing.expectEqualStrings("write", listing.entries()[0].name);
    try std.testing.expectEqual(@as(usize, 2), listing.leftOut());
    try std.testing.expectEqual(listing.entries()[0].name.ptr, @as([*]const u8, &room.arena));
}

test "two tools of one name are both listed; the merge leaves both out" {
    var script: Script = .{ .reply = pageOf(write ++ "," ++ write, null) };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    try std.testing.expectEqual(Outcome.listed, try run(&script, room.storage(), &listing));
    try std.testing.expectEqual(@as(usize, 2), listing.entries().len);
    try std.testing.expectEqual(@as(usize, 0), listing.leftOut());
}

test "a schema that already names the description property leaves that tool out" {
    const taken = "{\"name\":\"t\",\"inputSchema\":{\"properties\":{\"rui_call_description\":{}}}}";
    var script: Script = .{ .reply = pageOf(taken ++ "," ++ write, null) };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    try std.testing.expectEqual(Outcome.listed, try run(&script, room.storage(), &listing));
    try std.testing.expectEqual(@as(usize, 1), listing.entries().len);
    try std.testing.expectEqual(@as(usize, 1), listing.leftOut());
}

test "a JSON-RPC error or a bad status leaves the server unavailable" {
    const failure = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"down\"}}");
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    var rpc: Script = .{ .reply = failure };
    try std.testing.expectEqual(Outcome.unavailable, try run(&rpc, room.storage(), &listing));
    var status: Script = .{ .reply = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n" };
    try std.testing.expectEqual(Outcome.unavailable, try run(&status, room.storage(), &listing));
}

test "more tools than the storage holds are left out, not a failed listing" {
    var script: Script = .{ .reply = pageOf(search ++ "," ++ write, null) };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    var storage = room.storage();
    storage.entries = storage.entries[0..1];
    try std.testing.expectEqual(Outcome.listed, try run(&script, storage, &listing));
    try std.testing.expectEqual(@as(usize, 1), listing.entries().len);
    try std.testing.expectEqual(@as(usize, 1), listing.leftOut());
}

test "EXR-70 a listing keeps the smallest positive ttlMs over its pages" {
    const first = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ttlMs\":300000,\"nextCursor\":\"p2\",\"tools\":[" ++ search ++ "]}}");
    const second = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ttlMs\":120000,\"tools\":[" ++ write ++ "]}}");
    var script: Script = .{ .reply = first, .more = &.{second} };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    try std.testing.expectEqual(Outcome.listed, try run(&script, room.storage(), &listing));
    try std.testing.expectEqual(@as(?u64, 120_000), listing.ttlMs());

    // A zero or absent ttl on a later page does not cancel an earlier positive one.
    const zero = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ttlMs\":0,\"nextCursor\":\"p2\",\"tools\":[" ++ search ++ "]}}");
    const absent = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[" ++ write ++ "]}}");
    var none: Script = .{ .reply = zero, .more = &.{absent} };
    var none_room: TestRoom = .{};
    var none_listing: Listing = undefined;
    try std.testing.expectEqual(Outcome.listed, try run(&none, none_room.storage(), &none_listing));
    try std.testing.expectEqual(@as(?u64, null), none_listing.ttlMs());
}
