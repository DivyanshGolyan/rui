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
    instance: protocol.InstanceId,
    refresh: bool,
};

pub const Block = struct {
    kind: enum { user, assistant },
    position: u64,
    ordinal: u64,
    reference: protocol.ActivityItem.Content,
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
pub fn conversation(allocator: std.mem.Allocator, requests: client.Requests, store: []const u8, id: []const u8, since: ?replies.SessionToken, after: ?replies.ActivityCursor, previous_instance: ?protocol.InstanceId, force_refresh: bool, refreshing: *std.atomic.Value(bool)) !?Conversation {
    const instance = try servingInstance(requests.io, store);
    var fenced = requests;
    fenced.host_instance = &instance;
    const refresh = force_refresh or if (previous_instance) |previous| !std.mem.eql(u8, &instance, &previous) else false;
    if (refresh) refreshing.store(true, .release);
    const result = try conversationOnHost(allocator, fenced, store, id, if (refresh) null else since, if (refresh) null else after, instance, refresh);
    const still_serving = try servingInstance(requests.io, store);
    if (!std.mem.eql(u8, &instance, &still_serving)) return error.HostInstanceChanged;
    return result;
}

pub fn ensureServing(io: std.Io, store: []const u8, expected: protocol.InstanceId) !void {
    const instance = try servingInstance(io, store);
    if (!std.mem.eql(u8, &instance, &expected)) return error.HostInstanceChanged;
}

fn servingInstance(io: std.Io, store: []const u8) !protocol.InstanceId {
    return switch (client.hostStatus(io, store)) {
        .ready => |ready| ready.instance,
        else => error.HostUnavailable,
    };
}

fn conversationOnHost(allocator: std.mem.Allocator, requests: client.Requests, store: []const u8, id: []const u8, since: ?replies.SessionToken, after: ?replies.ActivityCursor, instance: protocol.InstanceId, refresh: bool) !?Conversation {
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
            try blocks.append(allocator, .{ .kind = value.kind, .position = item.position, .ordinal = item.ordinal, .reference = value.content, .source = source, .display = try safe(allocator, .multiline, source) });
        }
        cursor = page.continuation() orelse break;
    }
    return .{ .blocks = try blocks.toOwnedSlice(allocator), .token = snapshot_token, .cursor = last, .instance = instance, .refresh = refresh };
}

/// One authoritative Activity page; no content bytes are retained here.
/// Cursors preserve the Host's pinned end and source identity is bound to the
/// serving Host instance, session and Activity position/ordinal.
pub const SourcePage = struct {
    pub const Item = struct {
        kind: @FieldType(Block, "kind"),
        position: u64,
        ordinal: u64,
        reference: protocol.ActivityItem.Content,
    };

    instance: protocol.InstanceId,
    session: [protocol.session_id_bytes]u8,
    items: [protocol.ActivityPage.items]Item = undefined,
    count: usize = 0,
    next: ?replies.ActivityCursor,
    /// Directional boundaries include non-message Activity items, so page
    /// changes cannot skip identities that were not selected for display.
    before: ?replies.ActivityCursor,
    after: ?replies.ActivityCursor,
    end: u64,
    token: ?replies.SessionToken,
    direction: @FieldType(replies.ActivityCursor, "direction"),
};

/// Fetch just one directional page. If a previous page is being followed,
/// its Host fence must still be serving before and after the request.
pub fn sourcePage(requests: client.Requests, store: []const u8, id: *const [protocol.session_id_bytes]u8, cursor: replies.ActivityCursor, expected_instance: ?protocol.InstanceId) !SourcePage {
    const instance = try servingInstance(requests.io, store);
    if (expected_instance) |expected| if (!std.mem.eql(u8, &instance, &expected)) return error.HostInstanceChanged;
    var fenced = requests;
    fenced.host_instance = &instance;
    const page = switch (try fenced.activityPage(store, id, cursor)) {
        .page => |value| value,
        .failure => |failure| return fenced.failRead(failure),
    };
    var result: SourcePage = .{ .instance = instance, .session = id.*, .next = page.continuation(), .before = null, .after = null, .end = page.facts.end, .token = page.facts.token, .direction = cursor.direction };
    const bounds = pageBounds(page.facts.items[0..page.facts.count], page.facts.end, cursor);
    result.before = bounds.before;
    result.after = bounds.after;
    for (page.facts.items[0..page.facts.count]) |item| {
        const selected: ?struct { kind: @FieldType(Block, "kind"), content: protocol.ActivityItem.Content } = switch (item.value) {
            .user => |message| .{ .kind = .user, .content = message.content },
            .assistant => |answer| .{ .kind = .assistant, .content = answer.content },
            else => null,
        };
        const value = selected orelse continue;
        result.items[result.count] = .{ .kind = value.kind, .position = item.position, .ordinal = item.ordinal, .reference = value.content };
        result.count += 1;
    }
    const still_serving = try servingInstance(requests.io, store);
    if (!std.mem.eql(u8, &instance, &still_serving)) return error.HostInstanceChanged;
    return result;
}

const PageBounds = struct { before: ?replies.ActivityCursor = null, after: ?replies.ActivityCursor = null };

fn pageBounds(items: []const protocol.ActivityItem, end: u64, cursor: replies.ActivityCursor) PageBounds {
    if (items.len == 0) return .{};
    const first = items[0];
    const last = items[items.len - 1];
    const earliest = if (cursor.direction == .forward) first else last;
    const latest = if (cursor.direction == .forward) last else first;
    return .{
        .before = .{ .end = end, .position = earliest.position, .ordinal = earliest.ordinal, .direction = .backward, .kinds = cursor.kinds, .limit = cursor.limit },
        .after = .{ .end = end, .position = latest.position, .ordinal = latest.ordinal, .direction = .forward, .kinds = cursor.kinds, .limit = cursor.limit },
    };
}

test "native Activity page boundaries include undisplayed identities in both directions" {
    const ascending = [_]protocol.ActivityItem{
        .{ .position = 3, .ordinal = 0, .at = 1, .value = .{ .assistant = .{ .content = .{ .length = 0, .digest = @splat(0) } } } },
        .{ .position = 4, .ordinal = 0, .at = 1, .value = .{ .assistant = .{ .content = .{ .length = 0, .digest = @splat(0) } } } },
        .{ .position = 4, .ordinal = 1, .at = 1, .value = .{ .assistant = .{ .content = .{ .length = 0, .digest = @splat(0) } } } },
    };
    const descending = [_]protocol.ActivityItem{ ascending[2], ascending[1], ascending[0] };
    const forward = pageBounds(&ascending, 10, .{ .direction = .forward, .limit = 3 });
    const backward = pageBounds(&descending, 10, .{ .direction = .backward, .limit = 3 });
    for ([_]PageBounds{ forward, backward }) |bounds| {
        try std.testing.expectEqual(@as(u64, 3), bounds.before.?.position);
        try std.testing.expectEqual(@as(?u64, 0), bounds.before.?.ordinal);
        try std.testing.expectEqual(@as(u64, 4), bounds.after.?.position);
        try std.testing.expectEqual(@as(?u64, 1), bounds.after.?.ordinal);
        try std.testing.expectEqual(@as(?u64, 10), bounds.before.?.end);
        try std.testing.expectEqual(@as(?u64, 10), bounds.after.?.end);
    }
    const empty = pageBounds(&.{}, 0, .{});
    try std.testing.expect(empty.before == null and empty.after == null);
}

pub const SourceChange = struct {
    changed: bool,
    token: ?replies.SessionToken,

    fn fromFacts(end: u64, facts: *const protocol.ActivityFacts) SourceChange {
        return .{ .changed = !facts.not_modified and facts.end != end, .token = facts.token };
    }
};

/// Follow from the saved snapshot end. Only an unpinned forward request
/// without an ordinal can receive and use the Host's follow token.
pub fn sourceChanged(requests: client.Requests, store: []const u8, page: *const SourcePage) !SourceChange {
    const instance = try servingInstance(requests.io, store);
    if (!std.mem.eql(u8, &instance, &page.instance)) return error.HostInstanceChanged;
    var fenced = requests;
    fenced.host_instance = &instance;
    const cursor: replies.ActivityCursor = .{ .position = page.end, .direction = .forward, .limit = 1 };
    const reply = switch (try fenced.activityPageSince(store, &page.session, cursor, page.token)) {
        .page => |value| value,
        .failure => |failure| return fenced.failRead(failure),
    };
    try ensureServing(requests.io, store, instance);
    return SourceChange.fromFacts(page.end, &reply.facts);
}

test "native follow polling distinguishes unchanged snapshots and later activity" {
    const t = std.testing;
    const token: replies.SessionToken = .{ .instance = [_]u8{1} ** 16, .generation = 7, .session = "abc123".* };
    var facts: protocol.ActivityFacts = .{ .end = 42, .token = token };
    var change = SourceChange.fromFacts(42, &facts);
    try t.expect(!change.changed);
    try t.expectEqualDeep(token, change.token.?);
    facts.not_modified = true;
    facts.end = 0; // not-modified carries no new end on the wire
    change = SourceChange.fromFacts(42, &facts);
    try t.expect(!change.changed);
    facts.not_modified = false;
    facts.end = 43;
    facts.token = null;
    change = SourceChange.fromFacts(42, &facts);
    try t.expect(change.changed);
    try t.expect(change.token == null);
}

/// Load one identified item into exclusively owned temporary custody. Its
/// bytes cannot be observed before the complete source passes authentication.
pub fn openPageSource(allocator: std.mem.Allocator, requests: client.Requests, dir: std.Io.Dir, store: []const u8, page: *const SourcePage, item_index: usize) !*client.VerifiedContentScratch {
    if (item_index >= page.count) return error.InvalidTarget;
    const item = page.items[item_index];
    const instance = try servingInstance(requests.io, store);
    if (!std.mem.eql(u8, &instance, &page.instance)) return error.HostInstanceChanged;
    var fenced = requests;
    fenced.host_instance = &instance;
    const scratch = try fenced.readVerifiedActivityScratch(allocator, dir, store, &page.session, item.position, item.ordinal, .{ .bytes = item.reference.length, .digest = item.reference.digest });
    errdefer scratch.close();
    const still_serving = try servingInstance(requests.io, store);
    if (!std.mem.eql(u8, &instance, &still_serving)) return error.HostInstanceChanged;
    return scratch;
}
