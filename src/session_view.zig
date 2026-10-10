//! Bounded public Activity presentation with one forward-only content pass.
//! A failed stream may leave a visible prefix; the terminal owner must not retry it.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Text = @import("TerminalText.zig");
const Renderer = @import("AnswerRenderer.zig");

pub fn current(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File) !client.Current {
    try scratch.setLength(requests.io, 0);
    const Capture = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
        }
    };
    var capture: Capture = .{ .io = requests.io, .file = scratch };
    var reply: client.ReplyBuffer = .{};
    const report = try requests.inspectSession(store, session, .current, &capture, &reply);
    return switch (try client.CurrentReply.decode(requests.io, scratch, session, report)) {
        .current => |value| value,
        .unconfigured => error.SessionNotConfigured,
        .failure => |failure| failure.err(),
    };
}

pub fn Escaped(comptime Sink: type) type {
    return struct {
        sink: Sink,
        text: Text,
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            var storage: [256]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            for (bytes) |byte| {
                if (storage.len - out.end < 16) {
                    try self.sink.feed(out.buffered());
                    out.end = 0;
                }
                try self.text.feed(&out, &.{byte});
            }
            if (out.end != 0) try self.sink.feed(out.buffered());
        }
        pub fn finish(self: *@This()) anyerror!void {
            var storage: [16]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            try self.text.finish(&out);
            if (out.end != 0) try self.sink.feed(out.buffered());
        }
    };
}

/// Initialize in final storage: Renderer borrows the embedded Writer. Preserve
/// the original rendezvous error rather than narrowing Cancelled to WriteFailed.
pub fn Answer(comptime Sink: type) type {
    return struct {
        sink: Sink,
        storage: [4096]u8 = undefined,
        writer: std.Io.Writer,
        renderer: Renderer,
        failure: ?anyerror = null,
        pub fn init(self: *@This(), sink: Sink) void {
            self.* = .{ .sink = sink, .writer = undefined, .renderer = undefined };
            self.writer = .{ .vtable = &.{ .drain = drain }, .buffer = &self.storage };
            self.renderer = .{ .out = &self.writer };
        }
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            if (self.failure) |err| return err;
            self.renderer.feed(bytes) catch |err| return self.failure orelse err;
            self.writer.flush() catch |err| return self.failure orelse err;
        }
        pub fn finish(self: *@This()) anyerror!void {
            if (self.failure) |err| return err;
            self.renderer.finish() catch |err| return self.failure orelse err;
            self.writer.flush() catch |err| return self.failure orelse err;
        }
        fn forward(self: *@This(), bytes: []const u8) std.Io.Writer.Error!void {
            if (bytes.len == 0) return;
            self.sink.feed(bytes) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
        }
        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", writer);
            try self.forward(writer.buffered());
            writer.end = 0;
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                try self.forward(bytes);
                consumed += bytes.len;
            }
            const last = data[data.len - 1];
            for (0..splat) |_| try self.forward(last);
            return consumed + last.len * splat;
        }
    };
}

fn print(sink: anytype, comptime format: []const u8, args: anytype) !void {
    var storage: [256]u8 = undefined;
    try sink.feed(try std.fmt.bufPrint(&storage, format, args));
}

/// Exact fixed-end summary requires a metadata walk, not Current or the newest
/// page. Retain only the oldest four identities; never retain history payloads.
pub const Pending = struct {
    total: u64 = 0,
    count: usize = 0,
    items: [4]struct { position: u64, ordinal: u64, content: protocol.ActivityItem.Content } = undefined,

    pub fn render(self: *const Pending, requests: client.Requests, store: []const u8, session: []const u8, sink: anytype) !void {
        if (self.total == 0) return;
        try print(sink, "Rui: {d} pending at opening snapshot.\n", .{self.total});
        const Preview = struct {
            escaped: Escaped(@TypeOf(sink)),
            remaining: usize = 256,
            omitted: bool = false,
            pub fn feed(self_: *@This(), bytes: []const u8) !void {
                const count = @min(self_.remaining, bytes.len);
                try self_.escaped.feed(bytes[0..count]);
                self_.remaining -= count;
                self_.omitted = self_.omitted or count != bytes.len;
            }
        };
        for (self.items[0..self.count]) |item| {
            try sink.feed("Rui: queued preview: ");
            var preview: Preview = .{ .escaped = .{ .sink = sink, .text = .{ .mode = .line } } };
            if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = item.content.length, .digest = item.content.digest }, &preview)) |failure| return failure.err();
            try preview.escaped.finish();
            if (preview.omitted) try sink.feed(" [preview truncated]");
            try sink.feed("\n");
        }
    }
};

pub fn pending(requests: client.Requests, store: []const u8, session: []const u8, end: u64) !Pending {
    var summary: Pending = .{};
    var cursor: client.ActivityCursor = .{ .end = end };
    while (true) {
        const page = switch (try requests.activityPage(store, session, cursor)) {
            .page => |page| page,
            .failure => |failure| return failure.err(),
        };
        for (page.facts.items[0..page.facts.count]) |item| {
            if (item.value != .admission or item.value.admission.state != .queued) continue;
            summary.total += 1;
            if (summary.count == summary.items.len) continue;
            summary.items[summary.count] = .{ .position = item.position, .ordinal = item.ordinal, .content = item.value.admission.content };
            summary.count += 1;
        }
        cursor = page.continuation() orelse return summary;
    }
}

fn content(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, reference: protocol.ActivityItem.Content, sink: anytype) !void {
    if (item.value == .assistant) {
        var answer: Answer(@TypeOf(sink)) = undefined;
        answer.init(sink);
        if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = reference.length, .digest = reference.digest }, &answer)) |failure| return failure.err();
        try answer.finish();
    } else {
        var escaped: Escaped(@TypeOf(sink)) = .{ .sink = sink, .text = .{ .mode = .multiline } };
        if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = reference.length, .digest = reference.digest }, &escaped)) |failure| return failure.err();
        try escaped.finish();
    }
    try sink.feed("\n");
}

pub fn render(requests: client.Requests, store: []const u8, session: []const u8, page: *const client.ActivityPage, sink: anytype) !void {
    const historical = page.facts.direction == .backward;
    for (0..page.facts.count) |index| {
        const item = page.facts.items[if (historical) page.facts.count - index - 1 else index];
        switch (item.value) {
            .admission => |message| {
                if (historical and message.state == .applied) continue;
                try sink.feed(if (historical) "Rui: Unapplied input:\n" else "You: ");
                try content(requests, store, session, item, message.content, sink);
            },
            .user => |message| {
                if (!historical) continue; // Live Admission already showed it.
                try sink.feed("You: ");
                try content(requests, store, session, item, message.content, sink);
            },
            .assistant => |reference| {
                try sink.feed("Assistant: ");
                try content(requests, store, session, item, reference, sink);
            },
            .tool_result => |reference| {
                try sink.feed("Tool Result:\n");
                try content(requests, store, session, item, reference, sink);
            },
            .call => |call| {
                try sink.feed("Rui: Proposal; inspection is NOT authorization.\n");
                if (call.action) |action| try print(sink, "Action identity: {d}\n", .{action});
                if (call.rejection) |rejection| try print(sink, "Immutable rejection: {s}\n", .{@tagName(rejection)});
                inline for (std.meta.tags(client.ProposalField), 0..) |field, field_index| {
                    try print(sink, "{s}:\n", .{@tagName(field)});
                    var escaped: Escaped(@TypeOf(sink)) = .{ .sink = sink, .text = .{ .mode = .multiline } };
                    const reference = call.fields[field_index];
                    if (try requests.readProposalField(store, session, item.position, field, .{ .bytes = reference.length, .digest = reference.digest }, &escaped)) |failure| return failure.err();
                    try escaped.finish();
                    try sink.feed("\n");
                }
            },
            .outcome => |outcome| {
                // Successful content aggregates assistant rows, never a second answer.
                if (outcome.code.eql("completed")) continue;
                try print(sink, "Rui: saved work outcome: {s}\n", .{outcome.code.slice()});
            },
            .stop => try sink.feed("Rui: Session stop accepted.\n"),
        }
    }
}
