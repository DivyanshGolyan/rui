//! Model-facing public transcript reads. Store owns provenance and visibility;
//! this module only selects public rows and renders their bounded text windows.
const std = @import("std");
const protocol = @import("protocol.zig");
const wire_request = @import("wire_request.zig");
const core = @import("core_tools.zig");
const storage = @import("store.zig");

const window_bytes = 16 * 1024;

/// A read has no durable effect until its one resolution commits. In particular,
/// retries after a crash simply read the public feed again.
pub fn run(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, faults: storage.Faults) !void {
    // Store reads can drain queued writes on this stack. Keep bounded
    // argument scratch in the same arena as the feed windows.
    const arguments = try arena.create(core.ReadTranscript);
    arguments.* = .{};
    const check: core.ReadTranscriptCheck = if (input.arguments.length > core.read_transcript_max_argument_bytes)
        .{ .rejected = "the arguments take more than 4096 bytes" }
    else check: {
        const bytes = try arena.alloc(u8, @intCast(input.arguments.length));
        try store.readCoreArguments(input, bytes);
        break :check try core.checkReadTranscript(arena, bytes, arguments);
    };
    if (check == .rejected) return fail(store, arena, input, check.rejected, faults);
    const session = if (arguments.id) |id| id.slice() else input.session.slice();
    const result = render(store, arena, session, arguments) catch |err| switch (err) {
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
    if (arguments.query) |query| {
        const search = try arena.create(protocol.ActivitySearch);
        search.* = .{ .query = query, .kinds = arguments.kinds, .limit = arguments.limit };
        try search.session.set(session);
        if (arguments.before) |before| {
            search.before_position = before.position;
            search.before_ordinal = before.ordinal;
        }
        const facts = try arena.create(protocol.ActivitySearchFacts);
        try store.searchActivity(search, facts);
        try out.print("Session {s}, newest first: search matches.\n", .{session});
        for (facts.items[0..facts.count]) |*match| {
            const item = try findEntry(store, page, request, .{ .position = match.position, .ordinal = match.ordinal });
            try outline(store, arena, session, item, out);
            for (match.hits[0..match.count]) |*hit| {
                try std.json.Stringify.value(hit.snippet.slice(), .{}, out);
                try out.writeByte('\n');
            }
        }
        if (facts.next) |next| {
            try continuation(out, session, arguments, next.position, next.ordinal);
        } else try out.writeAll("Start of the Session.\n");
    } else if (arguments.full) |address| {
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
            try continuation(out, session, arguments, last.position, last.ordinal);
        } else try out.writeAll("Start of the Session.\n");
    }
    return output.written();
}

/// A full address need not be a valid page cursor. Start at the preceding
/// position boundary and page forward, stopping as soon as it is passed.
/// The exact arguments of the next read of the same selection, so a model
/// that follows the line reads the same Session, kinds, query and limit.
fn continuation(out: *std.Io.Writer, session: []const u8, arguments: *const core.ReadTranscript, position: u64, ordinal: u64) !void {
    try out.print("More: call read_transcript with {{\"id\":\"{s}\"", .{session});
    if (arguments.query) |query| {
        try out.writeAll(",\"query\":");
        try std.json.Stringify.value(query.slice(), .{}, out);
    }
    if (!arguments.kinds.eql(.full)) {
        try out.writeAll(",\"kinds\":[");
        var kinds = arguments.kinds.iterator();
        var first = true;
        while (kinds.next()) |kind| {
            try out.print("{s}\"{s}\"", .{ if (first) "" else ",", @tagName(kind) });
            first = false;
        }
        try out.writeAll("]");
    }
    if (arguments.limit != protocol.ActivityPage.items) try out.print(",\"limit\":{d}", .{arguments.limit});
    try out.print(",\"before\":\"{d}.{d}\"}}.\n", .{ position, ordinal });
}

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
        // A Label is display text, never model input: only the sender's ID.
        .received => |message| if (message.sender) |sender| try out.print(" {s}", .{sender.session.slice()}),
        .sent => |sent| try out.print(" {s}", .{sent.target.session.slice()}),
        .send_failed => |sent| if (sent.target) |target|
            try out.print(" {s}", .{target.session.slice()})
        else
            try out.writeAll(" (no valid target reference)"),
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
        .turn_ended => |ended| {
            try out.print(" {s}", .{@tagName(ended.ending)});
            // A descendant's ending: name the agent whose Turn it was.
            if (!std.mem.eql(u8, ended.session.slice(), session)) try out.print(" agent {s}", .{ended.session.slice()});
        },
        .approval_requested => |requested| if (!std.mem.eql(u8, requested.session.slice(), session)) try out.print(" agent {s}", .{requested.session.slice()}),
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

test "read_transcript core runner reads other Session outlines before full windows unknown id and self" {
    const Store = storage.Store;
    const testingStore = storage.testing.testingSqliteStore;
    const configureTestSession = storage.testing.configureTestSession;
    const submitTestMessage = storage.testingSubmitMessage;
    const TestingCall = storage.TestingCall;
    const settleCallsForTesting = storage.settleCallsForTesting;
    const ContentReader = storage.ContentReader;
    const testingContentReference = storage.testingContentReference;
    const completeConfiguration = storage.testingCompleteConfiguration;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database: Store = undefined;
    try testingStore(&database, &tmp, std.testing.io);
    defer database.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try storage.testingCanonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("transcript-caller", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{"read_transcript"});
    command.configuration.permission_mode.state = .value;
    try command.configuration.permission_mode.value.set("ask");
    const caller = (try database.configure(&command, .{})).accepted.session;
    try submitTestMessage(&database, &tmp, "transcript-task", "transcript-task", caller.slice(), "read the public feed");
    const model = (try database.admitNextModelAttempt(.{})).?.permit.binding;

    const other = try configureTestSession(&database, "transcript-other");
    const long = try arena.alloc(u8, 16 * 1024 + 64);
    @memset(long, 'x');
    @memcpy(long[16383..][0..4], "😀");
    try submitTestMessage(&database, &tmp, "transcript-old", "transcript-old", other.slice(), "old message");
    try submitTestMessage(&database, &tmp, "transcript-long", "transcript-long", other.slice(), long);
    try submitTestMessage(&database, &tmp, "transcript-new", "transcript-new", other.slice(), "new message");
    const page = try arena.create(protocol.ActivityFacts);
    try database.activityPage(&.{ .session = other, .direction = .backward }, page);
    try std.testing.expectEqual(@as(usize, 3), page.count);
    const newest = page.items[0].position;
    const middle = page.items[1].position;
    const oldest = page.items[2].position;
    const args = [_][]const u8{
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"limit\":1}}", .{other.slice()}),
        // Exactly the continuation call 0 emits, so the test follows it.
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"limit\":1,\"before\":\"{d}.0\"}}", .{ other.slice(), newest }),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\"}}", .{ other.slice(), middle }),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\",\"offset\":16383}}", .{ other.slice(), middle }),
        "{\"id\":\"zzzzzz\"}",
        "{}",
        "{\"limit\":0}",
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"999999.0\"}}", .{other.slice()}),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\",\"offset\":16384}}", .{ other.slice(), middle }),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"query\":\"MESSAGE\",\"kinds\":[\"admission\"],\"limit\":1}}", .{other.slice()}),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"query\":\"MESSAGE\",\"before\":\"{d}.0\"}}", .{ other.slice(), newest }),
    };
    var calls: [args.len]TestingCall = undefined;
    for (&calls, args, 0..) |*call, arguments, index| {
        const quoted = try std.json.Stringify.valueAlloc(arena, arguments, .{});
        const id = try std.fmt.allocPrint(arena, "read-{d}", .{index});
        call.* = .{ .item_id = id, .name = "read_transcript", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = quoted[1 .. quoted.len - 1], .decoded_arguments = arguments };
    }
    try settleCallsForTesting(&database, &tmp, model, "transcript-metadata", &calls);
    // Even malformed runtime arguments settle as core calls under ask.
    try std.testing.expectEqual(@as(u64, args.len), try storage.testing.sqlite_only.queryU64(&database, "SELECT count(*) FROM action_operation WHERE authorized=1 AND approval_position IS NULL", .{}));
    try std.testing.expect(try database.admitNextActionAttempt(300_000, .{}) == null);
    const note = try std.fmt.allocPrint(arena, "Read {s}'s transcript", .{other.slice()});
    try std.testing.expectEqual(@as(u64, 8), try storage.testing.sqlite_only.queryU64(&database, "SELECT count(*) FROM model_tool_call WHERE description=?1", .{note}));
    try std.testing.expectEqual(@as(u64, 2), try storage.testing.sqlite_only.queryU64(&database, "SELECT count(*) FROM model_tool_call WHERE description='Read own transcript'", .{}));
    try std.testing.expectEqual(@as(u64, 1), try storage.testing.sqlite_only.queryU64(&database, "SELECT count(*) FROM model_tool_call WHERE description='Read zzzzzz''s transcript'", .{}));

    for (args, 0..) |_, index| {
        const work = (try database.nextCoreWork()).?.action;
        try std.testing.expect(work.tool == .read_transcript);
        try run(&database, arena, &work, .{});
        const result_id = try storage.testing.sqlite_only.queryU64(&database, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{work.binding.action_id});
        const reference = try testingContentReference(&database, result_id);
        const bytes = try arena.alloc(u8, @intCast(reference.length));
        var reader: ContentReader = undefined;
        reader.open(try database.openContent(reference));
        defer reader.close();
        try std.testing.expectEqual(bytes.len, try reader.readRange(0, bytes));
        const succeeded = index < 4 or index == 5 or index >= 9;
        try std.testing.expectEqual(@as(u64, 1), try storage.testing.sqlite_only.queryU64(&database, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ work.binding.action_id, if (succeeded) "succeeded" else "failed" }));
        switch (index) {
            0 => {
                const expected = try std.fmt.allocPrint(arena, "{d}.0 admission person", .{newest});
                try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "new message") != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "old message") == null);
                const more = try std.fmt.allocPrint(arena, "More: call read_transcript with {s}.\n", .{args[1]});
                try std.testing.expect(std.mem.indexOf(u8, bytes, more) != null);
            },
            1 => {
                const expected = try std.fmt.allocPrint(arena, "{d}.0 admission person", .{middle});
                try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
                const excluded = try std.fmt.allocPrint(arena, "{d}.0 admission", .{newest});
                try std.testing.expect(std.mem.indexOf(u8, bytes, excluded) == null);
                const older = try std.fmt.allocPrint(arena, "{d}.0 admission", .{oldest});
                try std.testing.expect(std.mem.indexOf(u8, bytes, older) == null);
            },
            2 => {
                const expected = try std.fmt.allocPrint(arena, "Entry {d}.0 admission, bytes 0 to 16383 of {d}:\n{s}\nMore: call read_transcript with {s}.\n", .{ middle, long.len, long[0..16383], args[3] });
                try std.testing.expectEqualStrings(expected, bytes);
            },
            3 => {
                const expected = try std.fmt.allocPrint(arena, "Entry {d}.0 admission, bytes 16383 to {d} of {d}:\n{s}", .{ middle, long.len, long.len, long[16383..] });
                try std.testing.expectEqualStrings(expected, bytes);
            },
            4 => try std.testing.expectEqualStrings("Rui could not read the transcript: id names an unknown Session.", bytes),
            5 => {
                const heading = try std.fmt.allocPrint(arena, "Session {s}, newest first", .{caller.slice()});
                try std.testing.expect(std.mem.startsWith(u8, bytes, heading));
                try std.testing.expect(std.mem.indexOf(u8, bytes, "read_transcript") != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "Read own transcript") != null);
            },
            6 => try std.testing.expectEqualStrings("Rui could not read the transcript: limit must be 1 to 16.", bytes),
            7 => try std.testing.expectEqualStrings("Rui could not read the transcript: full names no public entry.", bytes),
            8 => try std.testing.expect(std.mem.indexOf(u8, bytes, "offset must be within the entry and on a UTF-8 character boundary") != null),
            9 => {
                const expected = try std.fmt.allocPrint(arena, "{d}.0 admission person", .{newest});
                try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "\"new message\"\n\"new message\"\n") != null);
                const more = try std.fmt.allocPrint(arena, "More: call read_transcript with {{\"id\":\"{s}\",\"query\":\"MESSAGE\",\"kinds\":[\"admission\"],\"limit\":1,\"before\":\"{d}.0\"}}.", .{ other.slice(), newest });
                try std.testing.expect(std.mem.indexOf(u8, bytes, more) != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "old message") == null);
            },
            10 => {
                try std.testing.expect(std.mem.indexOf(u8, bytes, "\"old message\"\n\"old message\"\n") != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "new message") == null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "Start of the Session.") != null);
            },
            else => unreachable,
        }
    }
    try std.testing.expect(try database.nextCoreWork() == null);
}

test "read_transcript opens public calls and no-content rows and identifies nonzero result ordinals" {
    const Store = storage.Store;
    const testingStore = storage.testing.testingSqliteStore;
    const completeSessionStop = storage.testingCompleteSessionStop;
    const submitTestMessage = storage.testingSubmitMessage;
    const TestingCall = storage.TestingCall;
    const settleCallsForTesting = storage.settleCallsForTesting;
    const BashExecutionInput = storage.BashExecutionInput;
    const ActionSettlement = storage.ActionSettlement;
    const ContentReader = storage.ContentReader;
    const testingBytesContent = storage.testingBytesContent;
    const testingContentReference = storage.testingContentReference;
    const completeConfiguration = storage.testingCompleteConfiguration;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database: Store = undefined;
    try testingStore(&database, &tmp, std.testing.io);
    defer database.close() catch unreachable;
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try storage.testingCanonicalCwd(std.testing.io, &workspace_buffer);
    var source_command = try completeConfiguration("transcript-source", "", workspace, "model-a");
    source_command.configuration.tools = try .of(&.{ "bash", "message_agent" });
    const source_reply = try database.configure(&source_command, .{});
    try std.testing.expect(source_reply == .accepted);
    const source = source_reply.accepted.session;
    try submitTestMessage(&database, &tmp, "transcript-source-message", "transcript-source-message", source.slice(), "make calls");
    const source_model = (try database.admitNextModelAttempt(.{})).?.permit.binding;
    const source_arguments = "{\"id\":\"zzzzzz\",\"text\":\"hello\"}";
    const quoted = try std.json.Stringify.valueAlloc(arena, source_arguments, .{});
    const sender_arguments = "{\"cmd\":\"true\",\"description\":\"Send peer Messages\",\"timeout_ms\":null}";
    const quoted_sender = try std.json.Stringify.valueAlloc(arena, sender_arguments, .{});
    const source_calls = [_]TestingCall{
        .{ .item_id = "unknown", .name = "not_offered", .encoded_call_id = "unknown", .decoded_call_id = "unknown", .encoded_arguments = "{}", .decoded_arguments = "{}" },
        .{ .item_id = "message", .name = "message_agent", .encoded_call_id = "message", .decoded_call_id = "message", .encoded_arguments = quoted[1 .. quoted.len - 1], .decoded_arguments = source_arguments },
        .{ .item_id = "sender", .name = "bash", .encoded_call_id = "sender", .decoded_call_id = "sender", .encoded_arguments = quoted_sender[1 .. quoted_sender.len - 1], .decoded_arguments = sender_arguments },
    };
    try settleCallsForTesting(&database, &tmp, source_model, "transcript-source-calls", &source_calls);
    const work = (try database.nextCoreWork()).?.action;
    try std.testing.expect(try database.deliverAgentMessage(work.binding, "zzzzzz", "hello", .{}) == .failed);
    const sender_action = (try database.admitNextActionAttempt(300_000, .{})).?.permit.binding;
    var sender_input: BashExecutionInput = undefined;
    try database.readBashExecutionInput(sender_action, &sender_input);
    var rename: wire_request.ConfigureCommand = .{};
    try rename.key.set("transcript-source-label");
    rename.session = source;
    rename.configuration.label.state = .value;
    try rename.configuration.label.value.set("Never expose this target label");
    try std.testing.expect(try database.configure(&rename, .{}) == .accepted);
    // The real Bash sender writes refusal positions and command identities
    // together; this fixture never bypasses the open Store's identity owner.
    const refusals = [_]struct { key: []const u8, target: []const u8, code: protocol.MessageRejection }{
        .{ .key = "transcript-invalid-target", .target = "BAD/attempt", .code = .invalid_session_reference },
        .{ .key = "transcript-unknown-target", .target = "absent", .code = .unknown_session },
        .{ .key = "transcript-named-target", .target = source.slice(), .code = .invalid_session_reference },
    };
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    for (refusals, 0..) |refusal, index| {
        var refused: wire_request.MessageCommand = .{
            .text = try testingBytesContent(&tmp, refusal.key, "Rejected text is never transcript content."),
            .sender = .{},
            .sender_handle = sender_input.sender_handle,
            // A nonempty target on an initial Message is refused, while
            // its canonical spelling still identifies a named public peer.
            .configuration = if (index == 2) .{} else null,
        };
        defer refused.removeTemporaryContent(std.testing.io) catch unreachable;
        try refused.key.set(refusal.key);
        try refused.session.set(refusal.target);
        try refused.sender.?.store.set(root);
        refused.sender.?.session = source;
        const reply = database.submitMessageWithModel(&refused, null, .{});
        try std.testing.expect(reply == .rejected);
        try std.testing.expectEqual(refusal.code, reply.rejected.code);
    }
    var stop = try completeSessionStop("transcript-source-stop", source.slice());
    try std.testing.expect(database.stopSession(&stop, .{}) == .accepted);
    try std.testing.expectEqual(ActionSettlement.session_stop, try database.settleActionAttempt(sender_action, .cancelled, "Sender stopped.", .{}));
    const page = try arena.create(protocol.ActivityFacts);
    try database.activityPage(&.{ .session = source, .direction = .backward, .kinds = .initMany(&.{ .call, .stop, .send_failed }) }, page);
    var call_address: u64 = 0;
    var stop_address: u64 = 0;
    var refusal_addresses: [refusals.len]u64 = @splat(0);
    for (page.items[0..page.count]) |*item| switch (item.value) {
        .call => |call| if (call.call_ordinal == 1) {
            call_address = item.position;
        },
        .stop => stop_address = item.position,
        .send_failed => |failed| {
            for (refusals, 0..) |refusal, index| {
                if (std.mem.eql(u8, refusal.key, failed.key.slice())) {
                    refusal_addresses[index] = item.position;
                    if (index == 0) {
                        try std.testing.expect(failed.target == null);
                    } else {
                        try std.testing.expectEqualStrings(refusal.target, failed.target.?.session.slice());
                        try std.testing.expectEqualStrings(if (index == 1) "" else "Never expose this target label", failed.target.?.label.slice());
                    }
                }
            }
        },
        else => {},
    };
    try std.testing.expect(call_address != 0 and stop_address != 0);
    for (refusal_addresses) |address| try std.testing.expect(address != 0);
    var command = try completeConfiguration("transcript-reader", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{"read_transcript"});
    const reader_reply = try database.configure(&command, .{});
    try std.testing.expect(reader_reply == .accepted);
    const reader_session = reader_reply.accepted.session;
    try submitTestMessage(&database, &tmp, "transcript-reader-message", "transcript-reader-message", reader_session.slice(), "read calls");
    const model = (try database.admitNextModelAttempt(.{})).?.permit.binding;
    const full_text = "message_agent\n" ++ source_arguments;
    const arguments = [_][]const u8{
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"kinds\":[\"tool_result\"]}}", .{source.slice()}),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\"}}", .{ source.slice(), call_address }),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\",\"offset\":13}}", .{ source.slice(), call_address }),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\"}}", .{ source.slice(), stop_address }),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"kinds\":[\"assistant\"]}}", .{source.slice()}),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\",\"offset\":{d}}}", .{ source.slice(), call_address, full_text.len + 1 }),
        "{" ++ @as([4096]u8, @splat(' ')),
        "{",
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"kinds\":[\"send_failed\"]}}", .{source.slice()}),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\"}}", .{ source.slice(), refusal_addresses[0] }),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\"}}", .{ source.slice(), refusal_addresses[1] }),
        try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"full\":\"{d}.0\"}}", .{ source.slice(), refusal_addresses[2] }),
    };
    var calls: [arguments.len]TestingCall = undefined;
    for (&calls, arguments, 0..) |*call, args, index| {
        const encoded = try std.json.Stringify.valueAlloc(arena, args, .{});
        const id = try std.fmt.allocPrint(arena, "tool-read-{d}", .{index});
        call.* = .{ .item_id = id, .name = "read_transcript", .encoded_call_id = id, .decoded_call_id = id, .encoded_arguments = encoded[1 .. encoded.len - 1], .decoded_arguments = args };
    }
    try settleCallsForTesting(&database, &tmp, model, "transcript-reader-calls", &calls);
    for (arguments, 0..) |_, index| {
        const input = (try database.nextCoreWork()).?.action;
        try run(&database, arena, &input, .{});
        const result_id = try storage.testing.sqlite_only.queryU64(&database, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{input.binding.action_id});
        const reference = try testingContentReference(&database, result_id);
        var reader: ContentReader = undefined;
        reader.open(try database.openContent(reference));
        defer reader.close();
        const bytes = try arena.alloc(u8, @intCast(reference.length));
        try std.testing.expectEqual(bytes.len, try reader.readRange(0, bytes));
        try std.testing.expectEqual(@as(u64, 1), try storage.testing.sqlite_only.queryU64(&database, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ input.binding.action_id, if (index < 5 or index >= 8) "succeeded" else "failed" }));
        switch (index) {
            0 => {
                try std.testing.expect(std.mem.indexOf(u8, bytes, ".2 tool_result message_agent failed") != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, ".1 tool_result not_offered unknown_tool") != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "Message zzzzzz") != null);
            },
            1, 2 => {
                const offset: usize = if (index == 1) 0 else 13;
                const expected = try std.fmt.allocPrint(arena, "Entry {d}.0 call, bytes {d} to {d} of {d}:\n{s}", .{ call_address, offset, full_text.len, full_text.len, full_text[offset..] });
                try std.testing.expectEqualStrings(expected, bytes);
            },
            3 => try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d}.0 stop\n", .{stop_address}), bytes),
            4 => try std.testing.expect(std.mem.indexOf(u8, bytes, "empty selection") != null),
            5 => try std.testing.expect(std.mem.indexOf(u8, bytes, "offset must be within") != null),
            6 => try std.testing.expect(std.mem.indexOf(u8, bytes, "more than 4096 bytes") != null),
            7 => try std.testing.expect(std.mem.indexOf(u8, bytes, "not one well-formed JSON object") != null),
            8 => {
                for (refusal_addresses, 0..) |address, refusal| {
                    const suffix = if (refusal == 0) "(no valid target reference)" else refusals[refusal].target;
                    const line = try std.fmt.allocPrint(arena, "{d}.0 send_failed {s}\n", .{ address, suffix });
                    try std.testing.expect(std.mem.indexOf(u8, bytes, line) != null);
                }
            },
            9, 10, 11 => {
                const refusal = index - 9;
                const suffix = if (refusal == 0) "(no valid target reference)" else refusals[refusal].target;
                const expected = try std.fmt.allocPrint(arena, "{d}.0 send_failed {s}\n", .{ refusal_addresses[refusal], suffix });
                try std.testing.expectEqualStrings(expected, bytes);
            },
            else => unreachable,
        }
        if (index >= 8) {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "Never expose this target label") == null);
            try std.testing.expect(std.mem.indexOf(u8, bytes, "BAD/attempt") == null);
            try std.testing.expect(std.mem.indexOf(u8, bytes, "invalid_session_reference") == null);
            try std.testing.expect(std.mem.indexOf(u8, bytes, "Rejected text is never transcript content.") == null);
        }
    }
}

test "searchActivity finds start_agent call names and stored JSON arguments not call IDs" {
    const Store = storage.Store;
    const testingStore = storage.testing.testingSqliteStore;
    const submitTestMessage = storage.testingSubmitMessage;
    const settleCallsForTesting = storage.settleCallsForTesting;
    const ContentReader = storage.ContentReader;
    const testingContentReference = storage.testingContentReference;
    const canonicalCwd = storage.testingCanonicalCwd;
    const completeConfiguration = storage.testingCompleteConfiguration;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var database: Store = undefined;
    try testingStore(&database, &tmp, std.testing.io);
    defer database.close() catch unreachable;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration("search-calls", "", workspace, "model-a");
    command.configuration.tools = try .of(&.{ "read_transcript", "start_agent" });
    const session = (try database.configure(&command, .{})).accepted.session;
    try submitTestMessage(&database, &tmp, "search-call-task", "search-call-task", session.slice(), "make calls");
    const model = (try database.admitNextModelAttempt(.{})).?.permit.binding;
    const arguments = "{\"text\":\"find\\nthis\"}";
    const quoted = try std.json.Stringify.valueAlloc(arena, arguments, .{});
    const query_args = "{\"kinds\":[\"call\"],\"query\":\"START_AGENT\"}";
    const query_quoted = try std.json.Stringify.valueAlloc(arena, query_args, .{});
    try settleCallsForTesting(&database, &tmp, model, "search-call-metadata", &.{
        .{ .item_id = "start", .name = "start_agent", .encoded_call_id = "hidden-call-identity", .decoded_call_id = "hidden-call-identity", .encoded_arguments = quoted[1 .. quoted.len - 1], .decoded_arguments = arguments },
        .{ .item_id = "read", .name = "read_transcript", .encoded_call_id = "read", .decoded_call_id = "read", .encoded_arguments = query_quoted[1 .. query_quoted.len - 1], .decoded_arguments = query_args },
    });
    const result = try arena.create(protocol.ActivitySearchFacts);
    var request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.call) };
    try request.query.set("start_agent");
    try database.searchActivity(&request, result);
    // The reader's own query also names start_agent in its arguments JSON.
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("start_agent\n{\"text\":\"find\\nthis\"}", result.items[1].hits[0].snippet.slice());
    try request.query.set("find\\nthis");
    try database.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try request.query.set("find\nthis");
    try database.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try request.query.set("hidden-call-identity");
    try database.searchActivity(&request, result);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    // Settle the earlier invalid start call at its owner boundary, then run
    // read_transcript against the same public call inventory (D163).
    const start = (try database.nextCoreWork()).?.action;
    try std.testing.expect(start.tool == .start_agent);
    _ = try database.failCoreCall(start.binding, "invalid start arguments", .{});
    const read = (try database.nextCoreWork()).?.action;
    try run(&database, arena, &read, .{});
    const id = try storage.testing.sqlite_only.queryU64(&database, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{read.binding.action_id});
    const reference = try testingContentReference(&database, id);
    const bytes = try arena.alloc(u8, @intCast(reference.length));
    var reader: ContentReader = undefined;
    reader.open(try database.openContent(reference));
    defer reader.close();
    try std.testing.expectEqual(bytes.len, try reader.readRange(0, bytes));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "call start_agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"start_agent\\n") != null);
    try std.testing.expect(!database.isFenced());
}
