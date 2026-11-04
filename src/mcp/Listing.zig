//! One MCP server's tool list, fetched page by page at Host start (D110).
//! The owner polls `fd()` for `events()` and calls `advance()`, as with
//! `Request`; nothing here blocks or runs on its own.
//!
//! Each tool is copied, with `rui_call_description` added to its schema
//! (D105), into the caller's storage before the next page overwrites the
//! answer buffer. A tool the server lists badly is left out and counted.
//! Two tools of one name, or one whose schema already has the description
//! property, fail the listing (D142); `collision` names the tool.
//!
//! Lifetime: a Listing holds a Request, so it has one address; its owner
//! initializes it in place. Everything it was given is borrowed until
//! `deinit`; the entries point into the caller's `arena`.
const std = @import("std");
const http1 = @import("../http1/request.zig");
const Request = @import("Request.zig");
const post = @import("post.zig");
const reply = @import("reply.zig");
const shape = @import("shape.zig");
const document = @import("document.zig");

const Listing = @This();

/// More than this many pages is a server that never stops.
pub const max_pages = 16;
/// The longest tool name OpenAI accepts as a function name.
pub const max_name_bytes = 64;

pub const Entry = struct {
    name: []const u8,
    description: ?[]const u8,
    /// The server's `inputSchema` with `rui_call_description` added.
    input_schema: []const u8,
    read_only: bool,
};

/// Caller-provided room for one listing.
pub const Storage = struct {
    entries: []Entry,
    /// Names, descriptions and shaped schemas are copied here.
    arena: []u8,
    /// Each `tools/list` answer is read here, one page at a time.
    answer: []u8,
    /// Each request is written here.
    request: []u8,
};

pub const Error = Request.Error || post.Error || error{
    /// More tools than `Storage.entries` holds, or more pages than `max_pages`.
    TooMany,
    /// The tools outgrew `Storage.arena`, or a request outgrew its buffer.
    NoRoom,
    /// Two tools share a name, or a schema already names
    /// `rui_call_description`; `collision` says which tool.
    ToolNameCollision,
    /// The answer is not a tool list.
    BadSchema,
};

pub const Outcome = union(enum) {
    waiting,
    /// Every page is in.
    listed,
    /// The server answered, but not with a tool list: a JSON-RPC error or
    /// an HTTP status. The caller keeps its saved copies (D147).
    unavailable,
};

server: post.Server,
client: post.Client,
storage: Storage,
current: Request,
page_open: bool,
pages: usize,
/// The cursor the next page asks for, held in `cursor_bytes`.
cursor_len: ?usize,
cursor_bytes: [256]u8,
count: usize,
arena_used: usize,
left_out: usize,
collision: ?[]const u8,

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
        .collision = null,
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

/// The tools collected so far.
pub fn entries(self: *const Listing) []const Entry {
    return self.storage.entries[0..self.count];
}

/// How many listed tools were left out for a malformed definition, an
/// invalid `x-mcp-header` (D206) or a name no function can carry.
pub fn leftOut(self: *const Listing) usize {
    return self.left_out;
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

/// Collects one page; true when the server has another.
fn take(self: *Listing, result: []const u8) Error!bool {
    const list = reply.readList(result) catch return error.BadSchema;
    var tools = reply.Tools.init(list);
    while (tools.next()) |listed| switch (listed) {
        .left_out => self.left_out += 1,
        .tool => |tool| try self.add(tool),
    };
    const cursor = list.next_cursor orelse return false;
    if (cursor.len > self.cursor_bytes.len) return error.NoRoom;
    @memcpy(self.cursor_bytes[0..cursor.len], cursor);
    self.cursor_len = cursor.len;
    return true;
}

fn add(self: *Listing, tool: reply.Tool) Error!void {
    if (!functionName(tool.name)) {
        self.left_out += 1;
        return;
    }
    for (self.entries()) |earlier| {
        if (std.mem.eql(u8, earlier.name, tool.name)) {
            self.collision = earlier.name;
            return error.ToolNameCollision;
        }
    }
    if (self.count == self.storage.entries.len) return error.TooMany;
    const mark = self.arena_used;
    const name = try self.copy(tool.name);
    const description: ?[]const u8 = if (tool.description) |text| try self.copy(text) else null;
    const room = self.storage.arena[self.arena_used..];
    var writer: std.Io.Writer = .fixed(room);
    shape.writeSchema(&writer, tool.input_schema) catch |err| switch (err) {
        error.WriteFailed => return error.NoRoom,
        error.NameTaken => {
            self.collision = name;
            return error.ToolNameCollision;
        },
        error.Malformed => {
            // Only this tool is unusable; its copies are dropped.
            self.arena_used = mark;
            self.left_out += 1;
            return;
        },
    };
    const schema = writer.buffered();
    self.arena_used += schema.len;
    self.storage.entries[self.count] = .{ .name = name, .description = description, .input_schema = schema, .read_only = tool.read_only };
    self.count += 1;
}

fn copy(self: *Listing, bytes: []const u8) Error![]const u8 {
    const room = self.storage.arena[self.arena_used..];
    if (bytes.len > room.len) return error.NoRoom;
    @memcpy(room[0..bytes.len], bytes);
    self.arena_used += bytes.len;
    return room[0..bytes.len];
}

/// Whether `name` is a function name: 1 to 64 letters, digits, hyphens and
/// underscores. An escaped name is not one, so names compare byte for byte.
fn functionName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

const Script = @import("test_server.zig");

fn target(script: *const Script, buffer: []u8) !http1.Target {
    return http1.parseTarget(try std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/mcp", .{script.port}));
}

/// Lists `script`'s tools into `storage` and drives the listing to its end.
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
    try std.testing.expect(found[0].read_only);
    try std.testing.expect(std.mem.indexOf(u8, found[0].input_schema, "rui_call_description") != null);
    try document.check(found[0].input_schema);
    try std.testing.expectEqualStrings("write", found[1].name);
    try std.testing.expect(found[1].description == null);
    try std.testing.expect(!found[1].read_only);
    // The second request carried the first page's cursor.
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
    // The dropped tools' copies were not kept.
    try std.testing.expectEqual(listing.entries()[0].name.ptr, @as([*]const u8, &room.arena));
}

test "two tools of one name fail the listing and name the tool" {
    var script: Script = .{ .reply = pageOf(write ++ "," ++ write, null) };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    try std.testing.expectError(error.ToolNameCollision, run(&script, room.storage(), &listing));
    try std.testing.expectEqualStrings("write", listing.collision.?);
}

test "a schema that already names the description property fails the listing" {
    const taken = "{\"name\":\"t\",\"inputSchema\":{\"properties\":{\"rui_call_description\":{}}}}";
    var script: Script = .{ .reply = pageOf(taken, null) };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    try std.testing.expectError(error.ToolNameCollision, run(&script, room.storage(), &listing));
    try std.testing.expectEqualStrings("t", listing.collision.?);
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

test "more tools than the storage holds is refused" {
    var script: Script = .{ .reply = pageOf(search ++ "," ++ write, null) };
    var room: TestRoom = .{};
    var listing: Listing = undefined;
    var storage = room.storage();
    storage.entries = storage.entries[0..1];
    try std.testing.expectError(error.TooMany, run(&script, storage, &listing));
}
