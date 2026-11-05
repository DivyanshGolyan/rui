//! Model-facing public transcript reads. Store owns provenance and visibility;
//! this module only selects public rows and renders their bounded text windows.
const std = @import("std");
const protocol = @import("protocol.zig");
const core = @import("core_tools.zig");
const storage = @import("store.zig");

const window_bytes = 16 * 1024;

/// A read has no durable effect until its one resolution commits. In particular,
/// retries after a crash simply read the public feed again.
pub fn run(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, faults: storage.Faults) !void {
    var arguments: core.ReadTranscript = .{};
    const check: core.ReadTranscriptCheck = if (input.arguments.length > core.read_transcript_max_argument_bytes)
        .{ .rejected = "the arguments take more than 4096 bytes" }
    else check: {
        const bytes = try arena.alloc(u8, @intCast(input.arguments.length));
        try store.readCoreArguments(input, bytes);
        break :check try core.checkReadTranscript(arena, bytes, &arguments);
    };
    if (check == .rejected) return fail(store, arena, input, check.rejected, faults);
    const session = if (arguments.id) |id| id.slice() else input.session.slice();
    const result = render(store, arena, session, &arguments) catch |err| switch (err) {
        error.SessionNotFound => return fail(store, arena, input, "id names an unknown Session", faults),
        error.EntryNotFound, error.ContentNotFound => return fail(store, arena, input, "full names no public entry", faults),
        error.InvalidCursor => return fail(store, arena, input, if (arguments.full != null) "full names no public entry" else "before must name a public entry or position in this Session", faults),
        error.InvalidEntryText => return fail(store, arena, input, "full entry is not valid UTF-8 text", faults),
        error.InvalidOffset => return fail(store, arena, input, "offset must be within the entry and on a UTF-8 character boundary", faults),
        else => return err,
    };
    _ = try store.succeedCoreCall(input.binding, result, faults);
}

fn fail(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, reason: []const u8, faults: storage.Faults) !void {
    const text = try std.fmt.allocPrint(arena, "Rui could not read the transcript: {s}.", .{reason});
    _ = try store.failCoreCall(input.binding, text, faults);
}

fn render(store: *storage.Store, arena: std.mem.Allocator, session: []const u8, arguments: *const core.ReadTranscript) ![]const u8 {
    const request = try arena.create(protocol.ActivityPage);
    request.* = .{ .direction = .backward, .limit = arguments.limit, .kinds = arguments.kinds };
    try request.session.set(session);
    if (arguments.before) |before| {
        request.position = before.position;
        request.ordinal = before.ordinal;
    }
    const page = try arena.create(protocol.ActivityFacts);
    var output: std.Io.Writer.Allocating = .init(arena);
    const out = &output.writer;
    if (arguments.full) |address| {
        const item = try findEntry(store, page, request, address);
        try full(store, arena, session, item, arguments.offset, out);
    } else {
        try store.activityPage(request, page);
        if (page.count == 0) {
            try out.print("Session {s}, newest first: empty selection.\n", .{session});
        } else {
            const first = &page.items[0];
            const last = &page.items[page.count - 1];
            try out.print("Session {s}, newest first, entries {d}.{d} to {d}.{d}:\n", .{ session, first.position, first.ordinal, last.position, last.ordinal });
            for (page.items[0..page.count]) |*item| try outline(store, arena, session, item, out);
        }
        if (page.more) {
            const last = &page.items[page.count - 1];
            try out.print("More: call read_transcript with {{\"id\":\"{s}\"", .{session});
            if (!arguments.kinds.eql(.full)) {
                try out.writeAll(",\"kinds\":[");
                var kinds = arguments.kinds.iterator();
                var first_kind = true;
                while (kinds.next()) |kind| {
                    try out.print("{s}\"{s}\"", .{ if (first_kind) "" else ",", @tagName(kind) });
                    first_kind = false;
                }
                try out.writeAll("]");
            }
            if (arguments.limit != protocol.ActivityPage.items) try out.print(",\"limit\":{d}", .{arguments.limit});
            try out.print(",\"before\":\"{d}.{d}\"}}.\n", .{ last.position, last.ordinal });
        } else try out.writeAll("Start of the Session.\n");
    }
    return output.written();
}

/// A full address need not be a valid page cursor. Start at the preceding
/// position boundary and page forward, stopping as soon as it is passed.
fn findEntry(store: *storage.Store, page: *protocol.ActivityFacts, request: *protocol.ActivityPage, address: core.TranscriptAddress) !*const protocol.ActivityItem {
    request.direction = .forward;
    request.position = address.position - 1;
    request.ordinal = null;
    request.limit = protocol.ActivityPage.items;
    request.kinds = .full;
    while (true) {
        try store.activityPage(request, page);
        // Pin subsequent pages to this read's public end.
        request.end = page.end;
        for (page.items[0..page.count]) |*item| {
            if (item.position > address.position or (item.position == address.position and item.ordinal > address.ordinal.?)) return error.EntryNotFound;
            if (item.position == address.position and item.ordinal == address.ordinal.?) return item;
        }
        if (!page.more) return error.EntryNotFound;
        const last = &page.items[page.count - 1];
        request.position = last.position;
        request.ordinal = last.ordinal;
    }
}

fn contentOf(item: *const protocol.ActivityItem) ?protocol.ActivityItem.Content {
    return switch (item.value) {
        .admission, .user, .received => |message| message.content,
        .assistant => |assistant| assistant.content,
        .tool_result => |result| result.content,
        .sent => |sent| sent.content,
        .turn_ended => |ended| ended.content,
        else => null,
    };
}

/// A request carries the wire's Store and Session buffers (hundreds of
/// bytes). Keep these bounded per-row objects in the call's arena as well:
/// Store reads can drain other queued writes on the engine's current stack.
fn contentRequest(arena: std.mem.Allocator, session: []const u8, item: *const protocol.ActivityItem) !*protocol.ReadActivityContent {
    const request = try arena.create(protocol.ReadActivityContent);
    request.* = .{ .position = item.position, .ordinal = item.ordinal };
    request.session.set(session) catch unreachable;
    return request;
}

fn readLocation(arena: std.mem.Allocator, location: storage.ContentLocation, offset: u64, maximum: usize) ![]const u8 {
    if (offset > location.reference.length) return error.InvalidOffset;
    const bytes = try arena.alloc(u8, @intCast(@min(maximum, location.reference.length - offset)));
    var reader: storage.ContentReader = undefined;
    reader.open(location);
    defer reader.close();
    var read: usize = 0;
    while (read < bytes.len) {
        const count = try reader.read(offset + read, bytes[read..]);
        if (count == 0) return error.ShortCanonicalRead;
        read += count;
    }
    return bytes;
}

/// Only the final character may be partial in a prefix of valid UTF-8.
fn wholePrefix(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (end -= 1) {
        if (bytes.len - end == 3) return bytes[0..0];
    }
    return bytes[0..end];
}

fn nameText(store: *storage.Store, arena: std.mem.Allocator, name: protocol.ProposalFieldReference) ![]const u8 {
    const location = try store.openContent(.{ .length = name.length, .digest = name.digest });
    // Known tool names fit the wire's name bound. Rejected calls can name
    // arbitrarily long tools; keep their outline bounded as well.
    return wholePrefix(try readLocation(arena, location, 0, protocol.max_tool_name_bytes));
}

fn outline(store: *storage.Store, arena: std.mem.Allocator, session: []const u8, item: *const protocol.ActivityItem, out: *std.Io.Writer) !void {
    try out.print("{d}.{d} {s}", .{ item.position, item.ordinal, @tagName(item.value) });
    var note: ?protocol.Bounded(protocol.max_tool_description_bytes) = null;
    switch (item.value) {
        .admission, .user => try out.writeAll(" person"),
        .received => |message| if (message.sender) |sender| {
            try out.print(" {s}", .{sender.session.slice()});
            if (sender.label.len != 0) try out.print(" ({s})", .{sender.label.slice()});
        },
        .sent => |sent| try out.print(" {s}", .{sent.target.session.slice()}),
        .send_failed => |sent| try out.print(" {s}", .{sent.target.session.slice()}),
        .call, .tool_result => {
            const request = try contentRequest(arena, session, item);
            const tool = try store.activityTool(request);
            const name = try nameText(store, arena, tool.name);
            try out.print(" {s}", .{name});
            if (name.len < tool.name.length) try out.writeAll("…");
            note = tool.presentation.description;
            if (item.value == .tool_result) try out.print(" {s}", .{@tagName(item.value.tool_result.presentation.code)});
        },
        // The public hosted row exposes only its presentation. web_search
        // is the sole provider-run tool (the provider owns its arguments).
        .hosted_call => |presentation| {
            try out.writeAll(" web_search");
            note = presentation.description;
        },
        .turn_ended => |ended| try out.print(" {s}", .{@tagName(ended.ending)}),
        else => {},
    }
    if (contentOf(item)) |content| {
        try out.print(" {d} bytes", .{content.length});
        if (item.value == .assistant and item.value.assistant.final) try out.writeAll(", final");
        if (item.value != .tool_result) {
            const request = try contentRequest(arena, session, item);
            const bytes = try readLocation(arena, try store.openActivityContent(request), 0, 100);
            const line = bytes[0 .. std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len];
            try out.writeAll(": ");
            try std.json.Stringify.value(wholePrefix(line), .{}, out);
        }
    }
    if (note) |description| try out.print(": {s}", .{description.slice()});
    try out.writeByte('\n');
}

fn full(store: *storage.Store, arena: std.mem.Allocator, session: []const u8, item: *const protocol.ActivityItem, offset: u64, out: *std.Io.Writer) !void {
    const request = try contentRequest(arena, session, item);
    var text: []const u8 = undefined;
    var total: u64 = undefined;
    if (item.value == .call) {
        // A call is a virtual public text: name, newline, arguments JSON.
        // Read only the pieces intersecting this window, not the whole JSON.
        const fields = item.value.call.fields;
        const name = fields[@backingInt(protocol.ProposalField.name)];
        const arguments = fields[@backingInt(protocol.ProposalField.arguments)];
        total = name.length + 1 + arguments.length;
        if (offset > total) return error.InvalidOffset;
        const bytes = try arena.alloc(u8, @intCast(@min(window_bytes, total - offset)));
        var written: usize = 0;
        var start = offset;
        if (start < name.length) {
            const piece = try readLocation(arena, try store.openContent(.{ .length = name.length, .digest = name.digest }), start, bytes.len);
            @memcpy(bytes[0..piece.len], piece);
            written += piece.len;
            start += piece.len;
        }
        if (start == name.length and written < bytes.len) {
            bytes[written] = '\n';
            written += 1;
            start += 1;
        }
        if (written < bytes.len) {
            const piece = try readLocation(arena, try store.openContent(.{ .length = arguments.length, .digest = arguments.digest }), start - name.length - 1, bytes.len - written);
            @memcpy(bytes[written..][0..piece.len], piece);
        }
        text = bytes;
    } else if (contentOf(item)) |_| {
        const location = try store.openActivityContent(request);
        total = location.reference.length;
        text = try readLocation(arena, location, offset, window_bytes);
    } else {
        if (offset != 0) return error.InvalidOffset;
        return outline(store, arena, session, item, out);
    }
    if (text.len > 0 and text[0] & 0xc0 == 0x80) return error.InvalidOffset;
    const prefix = wholePrefix(text);
    // Canonical content is byte-oriented. Never return a continuation at the
    // same offset if a public result contains malformed text in its interior.
    if (text.len != 0 and prefix.len == 0) return error.InvalidEntryText;
    text = prefix;
    const end = offset + text.len;
    try out.print("Entry {d}.{d} {s}, bytes {d} to {d} of {d}:\n", .{ item.position, item.ordinal, @tagName(item.value), offset, end, total });
    try out.writeAll(text);
    if (end < total) try out.print("\nMore: call read_transcript with {{\"id\":\"{s}\",\"full\":\"{d}.{d}\",\"offset\":{d}}}.\n", .{ session, item.position, item.ordinal, end });
}

test "read_transcript previews and windows cut only at whole UTF-8 characters" {
    try std.testing.expectEqualStrings("abc", wholePrefix("abc\xc3"));
    try std.testing.expectEqualStrings("aé", wholePrefix("aé\xf0\x9f\x98"));
    try std.testing.expectEqualStrings("aé😀", wholePrefix("aé😀"));
}
