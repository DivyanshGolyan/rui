//! Metadata before selection, then one forward-only presentation pass.
//! Scratch and sink belong to the caller; a late failure leaves a prefix and
//! must not trigger retry or selection rollback. No terminal/worker authority.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const TerminalText = @import("TerminalText.zig");

pub const Stage = struct { current: client.Current, page: client.ActivityPage };

pub fn inspectCurrent(requests: client.Requests, store: []const u8, session: []const u8, file: std.Io.File) !client.Current {
    // Positional capture makes reused scratch independent of its stream cursor.
    try file.setLength(requests.io, 0);
    const Capture = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
        }
    };
    var capture: Capture = .{ .io = requests.io, .file = file };
    var buffer: client.ReplyBuffer = .{};
    const reply = try requests.inspectSession(store, session, .current, &capture, &buffer);
    return switch (try client.CurrentReply.decode(requests.io, file, session, reply)) {
        .current => |value| value,
        .unconfigured => return error.SessionNotConfigured,
        .failure => |failure| return failure.err(),
    };
}

pub fn stage(requests: client.Requests, store: []const u8, session: []const u8, file: std.Io.File) !Stage {
    const observed = try inspectCurrent(requests, store, session, file);
    const page = switch (try requests.activityPage(store, session, .{ .end = null, .position = 0, .ordinal = null, .direction = .backward })) {
        .page => |value| value,
        .failure => |failure| return failure.err(),
    };
    return .{ .current = observed, .page = page };
}

// A fixed Writer is drained before it can fill. UTF-8 state survives every
// drain and source feed; at most twelve transformed bytes arise per input byte.
pub fn Escaped(comptime Sink: type) type {
    return struct {
        sink: Sink,
        text: TerminalText,
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

pub fn text(sink: anytype, bytes: []const u8) !void {
    var escaped: Escaped(@TypeOf(sink)) = .{ .sink = sink, .text = .{ .mode = .line } };
    try escaped.feed(bytes);
    try escaped.finish();
}

fn print(sink: anytype, comptime format: []const u8, args: anytype) !void {
    var storage: [256]u8 = undefined;
    try sink.feed(try std.fmt.bufPrint(&storage, format, args));
}

pub fn header(staged: *const Stage, sink: anytype) !void {
    const current = &staged.current;
    try sink.feed("Rui Session: ");
    try text(sink, current.settings.reference.slice());
    try sink.feed("\nWorkspace: ");
    try text(sink, current.settings.workspace.slice());
    try sink.feed("\nProvider/model: ");
    try text(sink, @tagName(current.settings.provider.value));
    try sink.feed("/");
    try text(sink, current.settings.model.slice());
    try print(sink, "\nPermission Mode: {s}\n", .{@tagName(current.settings.permission_mode.value)});
    if (bypassWarning(current.settings.tools.bash, current.settings.permission_mode.value == .bypass))
        try sink.feed("Rui: WARNING — Bash bypasses approval.\n");
    // Historical snapshot metadata is never substituted for Current attention.
    const facts = &staged.page.facts;
    if (facts.pending_total != 0) try print(sink, "Rui: {d} pending at opening snapshot.\n", .{facts.pending_total});
}

fn content(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, reference: protocol.ActivityItem.Content, sink: anytype) !void {
    var escaped: Escaped(@TypeOf(sink)) = .{ .sink = sink, .text = .{ .mode = .multiline } };
    if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = reference.length, .digest = reference.digest }, &escaped)) |failure| return failure.err();
    try escaped.finish();
    try sink.feed("\n");
}

pub fn render(requests: client.Requests, store: []const u8, session: []const u8, page: *const client.ActivityPage, sink: anytype) !void {
    // Opening captures one backward page; forward catch-up must not replay
    // these frozen queue notices or substitute Current's newer queue.
    if (page.facts.direction == .backward) {
        for (page.facts.pending[0..page.facts.pending_count]) |item| {
            try sink.feed("Rui: queued preview: ");
            var preview = Preview(@TypeOf(sink)){ .escaped = .{ .sink = sink, .text = .{ .mode = .line } } };
            const reference = item.value.admission.content;
            // Drain the complete bound read, including EOF integrity checks.
            // The display allowance is not a successful shortened wire read.
            if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = reference.length, .digest = reference.digest }, &preview)) |failure| return failure.err();
            try preview.escaped.finish();
            if (preview.omitted) try sink.feed(" [preview truncated]");
            try sink.feed("\n");
        }
    }
    for (0..page.facts.count) |index| {
        const item = page.facts.items[rowIndex(page, index)];
        switch (item.value) {
            .admission => |message| {
                // Applied admissions are represented exactly once by User.
                if (message.state == .applied) continue;
                try print(sink, "Rui: Message {s}.\n", .{@tagName(message.state)});
            },
            .user => |message| {
                try sink.feed("\nYou:\n");
                try content(requests, store, session, item, message.content, sink);
            },
            .assistant => |reference| {
                try sink.feed("\n--- Assistant ---\n");
                try content(requests, store, session, item, reference, sink);
            },
            .tool_result => |reference| {
                try sink.feed("\nTool Result:\n");
                try content(requests, store, session, item, reference, sink);
            },
            .call => |call| {
                try sink.feed("\nRui: Proposal; inspection is NOT authorization.\n");
                if (call.action) |action| try print(sink, "Action identity: {d} (not a current permission decision)\n", .{action});
                if (call.rejection) |rejection| try print(sink, "Immutable admission rejection: {s}\n", .{@tagName(rejection)});
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
                if (std.mem.eql(u8, outcome.code.slice(), "completed")) {
                    if (outcome.content.?.length == 0) try sink.feed("Rui: Completed without a public answer.\n");
                    continue;
                }
                try sink.feed("Rui: Outcome: ");
                try text(sink, outcome.code.slice());
                try sink.feed("\n");
                // Completed content is the aggregate of assistant entries, not
                // another conversational answer (even at a page boundary).
            },
            .stop => |stop| try print(sink, "Rui: Accepted Stop; completion {s}.\n", .{@tagName(stop.completion)}),
        }
    }
}

fn rowIndex(page: *const client.ActivityPage, index: usize) usize {
    return if (page.facts.direction == .backward) page.facts.count - 1 - index else index;
}

fn bypassWarning(bash: bool, bypass: bool) bool {
    return bash and bypass;
}

test "SessionView warning requires Bash and bypass independently" {
    try std.testing.expect(bypassWarning(true, true));
    try std.testing.expect(!bypassWarning(false, true));
    try std.testing.expect(!bypassWarning(true, false));
    try std.testing.expect(!bypassWarning(false, false));
}

test "SessionView preview escapes a bounded prefix and drains later feeds" {
    const Sink = struct {
        bytes: [4096]u8 = undefined,
        len: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
    };
    var sink: Sink = .{};
    var preview: Preview(*Sink) = .{ .escaped = .{ .sink = &sink, .text = .{ .mode = .line } } };
    try preview.feed("\x1b\n");
    try preview.feed(&(@as([254]u8, @splat('a'))));
    try std.testing.expect(!preview.omitted);
    try preview.feed("not displayed");
    try preview.escaped.finish();
    try std.testing.expect(preview.omitted);
    try std.testing.expectEqual(@as(usize, 0), preview.remaining);
    try std.testing.expectEqualStrings("\\x1b\\n" ++ "a" ** 254, sink.bytes[0..sink.len]);
}

// Presentation-only source-byte allowance; escaping has a fixed expansion
// bound. A cut UTF-8 scalar is escaped by finish rather than emitted raw.
fn Preview(comptime Sink: type) type {
    return struct {
        escaped: Escaped(Sink),
        remaining: usize = 256,
        omitted: bool = false,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            const count = @min(self.remaining, bytes.len);
            try self.escaped.feed(bytes[0..count]);
            self.remaining -= count;
            self.omitted = self.omitted or count != bytes.len;
        }
    };
}

test "completed outcome does not read or duplicate its aggregate answer" {
    const Sink = struct {
        bytes: [256]u8 = undefined,
        len: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
    };
    var page: client.ActivityPage = .{ .facts = .{ .end = 1, .count = 1 } };
    var code: protocol.Bounded(96) = .{};
    try code.set("completed");
    page.facts.items[0] = .{ .position = 1, .value = .{ .outcome = .{
        .turn = 2,
        .operation = 3,
        .code = code,
        .content = .{ .length = 99, .digest = @splat(0) },
    } } };
    var sink: Sink = .{};
    // Invalid store would fail if an aggregate read were accidentally added.
    try render(.{ .io = std.testing.io }, "", "", &page, &sink);
    try std.testing.expectEqualStrings("", sink.bytes[0..sink.len]);
    page.facts.items[0].value.outcome.content.?.length = 0;
    try render(.{ .io = std.testing.io }, "", "", &page, &sink);
    try std.testing.expectEqualStrings("Rui: Completed without a public answer.\n", sink.bytes[0..sink.len]);
    sink.len = 0;
    try code.set("failed");
    page.facts.items[0].value.outcome.code = code;
    try render(.{ .io = std.testing.io }, "", "", &page, &sink);
    try std.testing.expectEqualStrings("Rui: Outcome: failed\n", sink.bytes[0..sink.len]);
}

test "chronological indices reverse backward pages only" {
    var page: client.ActivityPage = .{ .facts = .{ .end = 3, .count = 3, .direction = .backward } };
    try std.testing.expectEqual(@as(usize, 2), rowIndex(&page, 0));
    try std.testing.expectEqual(@as(usize, 0), rowIndex(&page, 2));
    page.facts.direction = .forward;
    try std.testing.expectEqual(@as(usize, 0), rowIndex(&page, 0));
}

test "bounded escaping preserves split Unicode and propagates sink failure" {
    const Sink = struct {
        bytes: [128]u8 = undefined,
        len: usize = 0,
        fail: bool = false,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            if (self.fail) return error.OutputLost;
            @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
    };
    var sink: Sink = .{};
    var escaped: Escaped(*Sink) = .{ .sink = &sink, .text = .{ .mode = .line } };
    try escaped.feed("\xc3");
    try escaped.feed("\xa9\x1b\n\xe2\x80");
    try escaped.feed("\xae");
    try escaped.finish();
    try std.testing.expectEqualStrings("é\\x1b\\n\\u202e", sink.bytes[0..sink.len]);
    sink.fail = true;
    try std.testing.expectError(error.OutputLost, escaped.feed("x"));
}
