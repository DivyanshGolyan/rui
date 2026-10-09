const std = @import("std");
pub const client = @import("client.zig");
const protocol = @import("protocol.zig");
const platform = @import("platform.zig");
const View = @import("SessionView.zig");

pub const item_bytes = View.historical_item_bytes;
pub const max_scratch_bytes = item_bytes * protocol.public_conversation_page_items;

/// Owns metadata, never the scratch descriptor. Scratch is borrowed and must
/// remain unchanged from successful prepare through render. No cursor mutation
/// or display occurs during prepare; caller commits only after success.
pub const Prepared = struct {
    page: client.ConversationPage,
    store: protocol.Bounded(protocol.max_store_bytes),
    session: protocol.Bounded(protocol.max_session_bytes),
    offsets: [protocol.public_conversation_page_items]?u64 = @splat(null),
    bytes: u64 = 0,

    pub fn continuation(self: *const Prepared) ?client.ConversationCursor {
        return self.page.continuation();
    }

    /// Synchronous feed windows expire on return. No socket or authority is
    /// retained; rendering consumes only the verified, bounded scratch page.
    pub fn render(self: *const Prepared, io: std.Io, scratch: std.Io.File, sink: anytype) !void {
        var window: [protocol.content_window_bytes]u8 = undefined;
        var output: [256]u8 = undefined;
        for (0..self.page.count) |reverse| {
            const index = self.page.count - 1 - reverse;
            const item = self.page.items[index];
            const label = switch (item.kind) {
                .user => "You",
                .assistant => "Assistant",
                .tool_result => "Tool Result",
            };
            try sink.feed(try std.fmt.bufPrint(&output, "\n{s} (Conversation position {d}, ordinal {d}):\n", .{ label, item.position, item.ordinal }));
            if (self.offsets[index]) |start| {
                var offset: u64 = 0;
                var answer: View.Answer(@TypeOf(sink)) = undefined;
                answer.init(sink);
                var escaped: View.Escaped(@TypeOf(sink)) = .{ .sink = sink, .text = .{ .mode = .multiline } };
                while (offset < item.content.bytes) {
                    const wanted: usize = @intCast(@min(item.content.bytes - offset, window.len));
                    if (try scratch.readPositionalAll(io, window[0..wanted], start + offset) != wanted) return error.TruncatedHistoryScratch;
                    if (item.kind == .assistant) try answer.feed(window[0..wanted]) else try escaped.feed(window[0..wanted]);
                    offset += wanted;
                }
                if (item.kind == .assistant) try answer.finish() else try escaped.finish();
                try sink.feed("\n");
            } else {
                try View.omission(sink, self.store.slice(), self.session.slice(), item.position, item.ordinal, item.content.bytes);
            }
        }
    }
};

/// A whole-page prepass exclusive to /history, not opening/live rendering.
/// At most 16*8192 staged bytes, one caller-owned scratch descriptor, no heap.
/// Failure exposes neither prepared metadata nor new cursor; retry old cursor.
pub fn prepare(requests: client.Requests, store: []const u8, session: []const u8, cursor: client.ConversationCursor, scratch: std.Io.File) !Prepared {
    const paths = try platform.resolveClientPaths(requests.io, store);
    const page = switch (try requests.conversationPage(paths.store.slice(), session, cursor)) {
        .page => |value| value,
        .failure => |failure| return failure.err(),
    };
    var prepared: Prepared = .{ .page = page, .store = paths.store, .session = .{} };
    try prepared.session.set(session);
    const Staging = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64,
        remaining: u64,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            if (bytes.len > self.remaining) return error.HistoryContentOverflow;
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
            self.remaining -= bytes.len;
        }
    };
    for (page.items[0..page.count], 0..) |item, index| {
        if (item.content.bytes > item_bytes) continue;
        prepared.offsets[index] = prepared.bytes;
        var staging: Staging = .{ .io = requests.io, .file = scratch, .offset = prepared.bytes, .remaining = item.content.bytes };
        if (try requests.readConversationContent(prepared.store.slice(), session, item.position, item.ordinal, item.content, &staging)) |failure| return failure.err();
        if (staging.remaining != 0) return error.TruncatedHistoryContent;
        prepared.bytes = staging.offset;
    }
    // Received-byte integrity does not establish staged-byte integrity. Verify
    // the complete page before exposing Prepared or allowing cursor commit.
    var window: [protocol.content_window_bytes]u8 = undefined;
    for (page.items[0..page.count], prepared.offsets[0..page.count]) |item, staged| {
        const start = staged orelse continue;
        var hash = protocol.contentHasher();
        var offset: u64 = 0;
        while (offset < item.content.bytes) {
            const wanted: usize = @intCast(@min(item.content.bytes - offset, window.len));
            if (try scratch.readPositionalAll(requests.io, window[0..wanted], start + offset) != wanted) return error.TruncatedHistoryScratch;
            hash.update(window[0..wanted]);
            offset += wanted;
        }
        if (!std.mem.eql(u8, &hash.finalResult(), &item.content.digest)) return error.ContentBindingMismatch;
    }
    return prepared;
}
