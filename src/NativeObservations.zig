//! Host observations for the native interactive surface. A worker owns each
//! result and its arena until it joins; widgets never borrow a running worker.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const replies = @import("protocol_reply.zig");
const TerminalText = @import("TerminalText.zig");

pub const Row = struct {
    id: [protocol.session_id_bytes]u8,
    name: []const u8,
    directory: []const u8,
    category: u8,
    updated_at: ?u64,
};

pub const Conversation = struct {
    blocks: []Block,
    token: ?replies.SessionToken,
    /// Last activity item, including non-message items, for the next delta.
    cursor: ?replies.ActivityCursor,
};

pub const Block = struct {
    kind: enum { user, assistant },
    /// Exact Host content remains distinct from terminal-safe display bytes.
    source: []const u8,
    display: []const u8,
};

const FileSink = struct {
    io: std.Io,
    file: std.Io.File,
    at: u64 = 0,
    pub fn feed(self: *@This(), bytes: []const u8) !void {
        try self.file.writePositionalAll(self.io, bytes, self.at);
        self.at += bytes.len;
    }
};

const Bytes = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    pub fn feed(self: *@This(), data: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, data);
    }
};

fn safe(allocator: std.mem.Allocator, mode: TerminalText.Mode, bytes: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var text: TerminalText = .{ .mode = mode };
    try text.feed(&out.writer, bytes);
    try text.finish(&out.writer);
    return allocator.dupe(u8, out.written());
}

fn category(row: *const protocol.SessionRow) u8 {
    if (row.archive_state == .archived) return 4;
    const active = row.work.state.progress() != null;
    return if (row.peers.from_person_at != null) (if (active) 0 else 1) else (if (active) 2 else 3);
}

fn earlier(_: void, a: Row, b: Row) bool {
    if (a.category != b.category) return a.category < b.category;
    if (a.updated_at != b.updated_at) {
        if (a.updated_at == null) return false;
        if (b.updated_at == null) return true;
        return a.updated_at.? > b.updated_at.?;
    }
    return std.mem.order(u8, &a.id, &b.id) == .lt;
}

/// Traverses all actual Host pages; a missing activity timestamp stays unknown.
pub fn list(allocator: std.mem.Allocator, requests: client.Requests, store: []const u8, scratch: std.Io.File) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    var cursor: replies.SessionListCursor = .{};
    while (true) {
        var sink: FileSink = .{ .io = requests.io, .file = scratch };
        var buffer: client.ReplyBuffer = .{};
        const report = try requests.listSessionsFiltered(store, null, .all, cursor, &sink, &buffer);
        const page = switch (try replies.SessionListReply.decode(requests.io, scratch, null, cursor, report)) {
            .page => |value| value,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.rows[0..page.count]) |*row| {
            const id = row.reference.slice()[0..protocol.session_id_bytes].*;
            var updated_at: ?u64 = null;
            const latest = requests.activityPage(store, &id, .{ .direction = .backward, .limit = 1 }) catch null;
            if (latest) |reply| if (reply == .page and reply.page.facts.count != 0) {
                updated_at = reply.page.facts.items[0].at;
            };
            const label = if (row.label) |*value| value.slice() else row.reference.slice();
            const path = row.workspace.slice();
            const directory = std.fs.path.basename(path);
            try rows.append(allocator, .{
                .id = id,
                .name = try safe(allocator, .label, label),
                .directory = try safe(allocator, .label, if (directory.len == 0) path else directory),
                .category = category(row),
                .updated_at = updated_at,
            });
        }
        cursor = page.next orelse break;
    }
    std.mem.sort(Row, rows.items, {}, earlier);
    return rows.toOwnedSlice(allocator);
}

/// Reads Message content with the Host's length and digest binding. The
/// returned blocks are values, not screen geometry or a mutable editor.
pub fn conversation(allocator: std.mem.Allocator, requests: client.Requests, store: []const u8, id: []const u8, since: ?replies.SessionToken, after: ?replies.ActivityCursor) !?Conversation {
    if (since) |token| {
        const poll = switch (try requests.activityPageSince(store, id, .{}, token)) {
            .page => |value| value,
            .failure => |failure| return requests.failRead(failure),
        };
        if (poll.facts.not_modified) return null;
    }
    var blocks: std.ArrayList(Block) = .empty;
    var cursor: replies.ActivityCursor = after orelse .{};
    var last = after;
    var snapshot_token: ?replies.SessionToken = null;
    var first = true;
    while (true) {
        const page = switch (try requests.activityPage(store, id, cursor)) {
            .page => |value| value,
            .failure => |failure| return requests.failRead(failure),
        };
        if (first) {
            snapshot_token = page.facts.token;
            first = false;
        }
        for (page.facts.items[0..page.facts.count]) |item| {
            last = .{ .position = item.position, .ordinal = item.ordinal };
            const selected: ?struct { kind: @FieldType(Block, "kind"), content: protocol.ActivityItem.Content } = switch (item.value) {
                .user => |message| .{ .kind = .user, .content = message.content },
                .assistant => |answer| .{ .kind = .assistant, .content = answer.content },
                else => null,
            };
            const value = selected orelse continue;
            var sink: Bytes = .{ .allocator = allocator };
            if (try requests.readActivityContent(store, id, item.position, item.ordinal, .{ .bytes = value.content.length, .digest = value.content.digest }, &sink)) |failure| return requests.failRead(failure);
            const source = try sink.bytes.toOwnedSlice(allocator);
            try blocks.append(allocator, .{ .kind = value.kind, .source = source, .display = try safe(allocator, .multiline, source) });
        }
        cursor = page.continuation() orelse break;
    }
    return .{ .blocks = try blocks.toOwnedSlice(allocator), .token = snapshot_token, .cursor = last };
}
