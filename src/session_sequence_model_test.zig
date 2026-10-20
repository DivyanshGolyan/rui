//! TD1's independent bounded oracle. The Python runner supplies actual private
//! Frontend transitions without changing the frozen source checkout. Worker
//! payloads are already-validated read facts, not a substitute Host or Store.
const std = @import("std");
const Screen = @import("SessionScreen.zig");
const Task = @import("ClientTask.zig");
const client = @import("client.zig");
const Consent = @import("session_consent.zig");
const Viewport = @import("ConversationViewport.zig");

pub const Suite = enum { focus, pages, acknowledgement, retention, publication };

fn printPrefix(comptime Event: type, sequence: usize, count: usize) void {
    const events = std.enums.values(Event);
    var word = sequence;
    std.debug.print("TD1 prefix:", .{});
    for (0..count) |_| {
        std.debug.print(" {s}", .{@tagName(events[word % events.len])});
        word /= events.len;
    }
    std.debug.print("\n", .{});
}

// A plain string/caret oracle: no production editor, decoder, view or consent
// policy is used to derive expected values.
const Text = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    fn insert(self: *Text, bytes: []const u8) void {
        std.mem.copyBackwards(u8, self.bytes[self.cursor + bytes.len .. self.len + bytes.len], self.bytes[self.cursor..self.len]);
        @memcpy(self.bytes[self.cursor..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
    }

    fn left(self: *Text) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        while (self.cursor != 0 and self.bytes[self.cursor] & 0xc0 == 0x80) self.cursor -= 1;
    }
};

fn Fixture(comptime Frontend: type, comptime ops: anytype) type {
    return struct {
        const Self = @This();
        front: *Frontend,
        screen: *Screen,
        tmp: std.testing.TmpDir,
        page: std.Io.File,
        action: std.Io.File,
        output: std.Io.File,
        input: [2]c_int,
        saved_stdin: c_int,
        root: [std.Io.Dir.max_path_bytes]u8 = undefined,

        fn init(self: *Self) !void {
            self.tmp = std.testing.tmpDir(.{});
            self.page = try self.tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
            self.action = try self.tmp.dir.createFile(std.testing.io, "action", .{ .read = true });
            self.output = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
            self.saved_stdin = std.c.dup(0);
            try std.testing.expect(self.saved_stdin >= 0);
            try std.testing.expect(std.c.pipe(&self.input) == 0);
            try std.testing.expect(std.c.dup2(self.input[0], 0) >= 0);
            self.screen = try std.testing.allocator.create(Screen);
            var environ = try std.testing.environ.createMap(std.testing.allocator);
            defer environ.deinit();
            try self.screen.init(std.testing.io, &environ, false);
            self.front = try std.testing.allocator.create(Frontend);
            const path = self.root[0..try self.tmp.dir.realPath(std.testing.io, &self.root)];
            self.front.* = .{
                .init = undefined,
                .store = "td1-no-host",
                .session = "model",
                .directory = path,
                .scratch = self.page,
                .inspection_file = self.page,
                .status_file = self.page,
                .action_file = self.action,
                .command = undefined,
                .colour = false,
                .opening = false,
                .terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = self.screen, .output = self.output.handle, .active = false },
                .current = std.mem.zeroes(client.Current),
            };
            self.front.init.io = std.testing.io;
            self.front.input.init();
            self.front.submission = .{ .io = std.testing.io, .store = self.front.store, .session = "model", .directory = path, .input = &self.front.input };
            self.front.choice = .{ .buffer = &self.front.choice_buffer, .allow_paste = false };
            try self.setPage("EARLIER PAGE\n");
            try self.action.writePositionalAll(std.testing.io, "Run Bash\nprintf exact\nWorkspace: /model\n", 0);
            try ops.draw(self.front);
        }

        fn deinit(self: *Self) void {
            _ = self.front.submission.join();
            self.front.submission.close();
            self.front.reader.join() catch unreachable;
            self.screen.deinit();
            std.testing.allocator.destroy(self.screen);
            std.testing.allocator.destroy(self.front);
            std.debug.assert(std.c.dup2(self.saved_stdin, 0) >= 0);
            for ([_]c_int{ self.saved_stdin, self.input[0], self.input[1] }) |fd| std.debug.assert(std.c.close(fd) == 0);
            self.output.close(std.testing.io);
            self.action.close(std.testing.io);
            self.page.close(std.testing.io);
            self.tmp.cleanup();
        }

        fn setPage(self: *Self, content: []const u8) !void {
            try self.page.setLength(std.testing.io, 0);
            try self.page.writePositionalAll(std.testing.io, content, 0);
        }

        fn byte(self: *Self, value: u8) !void {
            try std.testing.expect(std.c.write(self.input[1], &.{value}, 1) == 1);
            try std.testing.expectEqual(Consent.Service.byte, try ops.step(self.front, 0));
        }

        fn bytes(self: *Self, values: []const u8) !void {
            for (values) |value| try self.byte(value);
        }

        fn complete(self: *Self) !void {
            // The worker owns only the frozen Job. Completion is real join
            // authority, but its staged payload is deliberately deterministic.
            const Idle = struct {
                fn run(_: *anyopaque, _: *Task) !void {}
            };
            try self.front.reader.start(std.testing.io, &self.front.job, Idle.run);
            try ops.settleReader(self.front);
        }

        fn checkText(self: *Self, draft: *const Text, choice: *const Text, choosing: bool) !void {
            const actual = self.front.input.composition();
            try std.testing.expectEqualStrings(draft.slice(), actual.bytes);
            try std.testing.expectEqual(draft.cursor, actual.cursor);
            try std.testing.expectEqualStrings(choice.slice(), self.front.choice.buffer[0..self.front.choice.length]);
            try std.testing.expectEqual(choice.cursor, self.front.choice.cursor);
            try ops.draw(self.front);
            const shown = if (choosing) choice else draft;
            const window = self.screen.vx.window();
            const row = self.screen.vx.screen.cursor.row;
            try std.testing.expectEqualStrings(if (choosing) ">" else "›", window.readCell(0, row).?.char.grapheme);
            var expected_column: u16 = 2;
            var column: u16 = 2;
            var index: usize = 0;
            while (index < shown.len) {
                const length: usize = try std.unicode.utf8ByteSequenceLength(shown.bytes[index]);
                try std.testing.expectEqualStrings(shown.bytes[index..][0..length], window.readCell(column, row).?.char.grapheme);
                if (index < shown.cursor) expected_column += 1;
                index += length;
                column += 1;
            }
            try std.testing.expectEqual(expected_column, self.screen.vx.screen.cursor.col);
        }
    };
}

pub fn run(comptime Frontend: type, comptime ops: anytype, comptime suite: Suite) !void {
    switch (suite) {
        .focus => try focus(Frontend, ops),
        .pages => try pages(Frontend, ops),
        .acknowledgement => try acknowledgement(Frontend, ops),
        .retention => try retention(Frontend, ops),
        .publication => try publication(Frontend, ops),
    }
}

fn focus(comptime Frontend: type, comptime ops: anytype) !void {
    const Event = enum { unicode, left, enter, pause, latest, receipt, allow, paste };
    const events = std.enums.values(Event);
    // Same exhaustive base-eight, length-three words as session_consent.zig.
    // Complete, preview and no-Action seeds exercise both displayed editors.
    for (0..6) |seed| for (0..512) |sequence| {
        var fixture: Fixture(Frontend, ops) = undefined;
        try fixture.init();
        defer fixture.deinit();
        const front = fixture.front;
        var draft: Text = .{};
        var choice: Text = .{};
        draft.insert("ZX");
        draft.left();
        try fixture.bytes("ZX\x1b[D");
        const blocked = seed == 3 or seed == 4;
        const unread = seed == 5;
        var alive = seed == 1 or seed == 2 or seed == 4 or unread;
        var visible = alive;
        var fresh = false;
        // A choice line keeps its editor through Enter even if a page hides
        // the Action. Discarding stale text does not transfer the line.
        var choice_line = false;
        var submitted: usize = 0;
        var decision = false;
        var sealed: Text = .{};
        if (blocked) {
            front.input.command_buffer[0] = 'x';
            front.input.command_length = 1;
        }
        if (alive) {
            if (unread) {
                const line = "UNREAD ACTION ROW\n";
                for (0..100) |row| try fixture.action.writePositionalAll(std.testing.io, line, row * line.len);
            }
            try fixture.screen.prepareAction(std.testing.io, fixture.action);
            front.consent.adopt(913, if (seed == 2) .preview else .complete);
            try ops.draw(front);
        }
        var index = sequence;
        for (0..3) |prefix| {
            const event = events[index % events.len];
            index /= events.len;
            errdefer {
                std.debug.print("TD1 focus seed={d} sequence={d} prefix={d}\n", .{ seed, sequence, prefix + 1 });
                printPrefix(Event, sequence, prefix + 1);
            }
            const choosing = choice_line or (alive and visible and seed != 2);
            switch (event) {
                .unicode => {
                    // Observe the incomplete UTF-8 prefix before completing it.
                    try fixture.byte(0xc3);
                    try fixture.checkText(&draft, &choice, choosing);
                    try fixture.byte(0xa9);
                    if (!choosing) draft.insert("é") else {
                        choice_line = true;
                        if (fresh) choice.insert("é");
                    }
                },
                .paste => {
                    // Marked paste cannot authorize even beside a fresh Action.
                    try fixture.bytes("\x1b[200~a\x1b[201~");
                    if (!choosing) draft.insert("a") else {
                        // Rejection is reported at the unpasted line end,
                        // not while the stream still owns paste custody.
                        try fixture.byte(13);
                        choice = .{};
                        choice_line = false;
                        fresh = false;
                    }
                },
                .left => {
                    try fixture.bytes("\x1b[D");
                    if (!choosing) draft.left() else if (fresh) choice.left();
                },
                .enter => {
                    const send = !blocked and !alive and !decision and draft.len != 0 and submitted == 0;
                    try fixture.byte(13);
                    if (send) {
                        submitted += 1;
                        sealed = draft;
                        try std.testing.expectEqualStrings(draft.slice(), try front.input.message(front.submission.intent.?.message));
                        draft = .{};
                        visible = false;
                    } else if (choosing) {
                        choice = .{};
                        choice_line = false;
                        fresh = false;
                    }
                },
                .pause => {
                    try ops.showInspection(front);
                    visible = false;
                    fresh = false;
                    choice = .{};
                },
                .latest => {
                    try ops.navigation(front, .latest);
                    visible = alive;
                },
                .receipt => {
                    try ops.draw(front);
                    const service = try ops.step(front, 0);
                    _ = ops.receipt(front, service);
                    if (alive and visible and seed != 2 and !blocked) fresh = true;
                },
                .allow => {
                    try fixture.bytes("a\r");
                    if (choosing) {
                        if (fresh and !blocked and !unread and choice.len == 0) {
                            alive = false;
                            visible = false;
                            decision = true;
                            try std.testing.expectEqual(@as(u64, 913), front.submission.intent.?.decision.action);
                        }
                        choice = .{};
                        choice_line = false;
                        fresh = false;
                    } else {
                        draft.insert("a");
                        if (!blocked and !alive and !decision and submitted == 0) {
                            submitted += 1;
                            sealed = draft;
                            draft = .{};
                        }
                    }
                },
            }
            // Paused input invalidates the choice and never submits the draft.
            if (alive and !choosing and (event == .unicode or event == .paste or event == .left or event == .enter or event == .allow)) {
                fresh = false;
                choice = .{};
            }
            try std.testing.expectEqual(submitted, front.sent);
            try std.testing.expectEqual(decision or submitted != 0, front.submission.intent != null);
            if (submitted != 0) try std.testing.expectEqualStrings(sealed.slice(), try front.input.message(front.submission.intent.?.message));
            try std.testing.expectEqual(fresh, front.consent.acceptsInput());
            try fixture.checkText(&draft, &choice, choice_line or (alive and visible and seed != 2));
        }
    };
}

fn pages(comptime Frontend: type, comptime ops: anytype) !void {
    const Event = enum { details, history, status, complete, send, latest, transcript, edit };
    const events = std.enums.values(Event);
    const first_cursor: client.ConversationCursor = .{ .end = 99, .before_position = 79, .before_ordinal = 3 };
    const next_cursor: client.ConversationCursor = .{ .end = 99, .before_position = 23, .before_ordinal = 1 };
    for (0..4) |seed| for (0..512) |sequence| {
        var fixture: Fixture(Frontend, ops) = undefined;
        try fixture.init();
        defer fixture.deinit();
        const front = fixture.front;
        var selected: Screen.ViewKind = .live;
        var generation: u64 = 0;
        var sent: u64 = 0;
        var requested_at: u64 = 0;
        var request_generation: u64 = 0;
        var request: ?enum { details, history, status } = null;
        var draft: Text = .{};
        var older: ?client.ConversationCursor = null;
        // Seed a real retained boundary. History is launched only from the
        // transcript, including A -> launch -> new B -> delayed completion.
        front.job.result.boundaries.add(.{ .output = 0, .cursor = first_cursor, .admitted = first_cursor.before_position });
        try ops.showStaged(front);
        if (seed % 2 == 1) {
            try ops.beginTranscript(front);
            generation = 1;
            selected = .transcript;
            older = first_cursor;
        }
        var fragment = seed >= 2;
        if (fragment) try fixture.byte(0xc3);
        var index = sequence;
        for (0..3) |prefix| {
            const event = events[index % events.len];
            index /= events.len;
            errdefer {
                std.debug.print("TD1 pages seed={d} sequence={d} prefix={d}\n", .{ seed, sequence, prefix + 1 });
                printPrefix(Event, sequence, prefix + 1);
            }
            switch (event) {
                .details, .history, .status => if (request == null and (event != .history or (selected == .transcript and older != null))) {
                    if (event == .history) try std.testing.expect(ops.olderWanted(front));
                    request = switch (event) {
                        .details => .details,
                        .history => .history,
                        else => .status,
                    };
                    requested_at = sent;
                    request_generation = generation;
                    front.read_phase = switch (event) {
                        .details => .details,
                        .history => .history,
                        else => .activity,
                    };
                    front.details_sent = front.sent;
                    front.job = ops.freeze(front, front.read_phase);
                    front.job.result.history_cursor = next_cursor;
                    if (event == .status) {
                        front.status_requested = true;
                        front.job.open_status = true;
                        front.job.result = .{ .settled = true, .status = true, .current = std.mem.zeroes(client.Current) };
                    }
                },
                .complete => if (request) |pending| {
                    try fixture.complete();
                    switch (pending) {
                        .details => if (sent == requested_at) {
                            selected = .inspection;
                        },
                        .status => if (sent == requested_at) {
                            selected = .inspection;
                        },
                        .history => {
                            if (selected == .transcript and generation == request_generation) {
                                try std.testing.expect(std.mem.indexOf(u8, fixture.screen.browsing.text(), "EARLIER PAGE\n") != null);
                                older = next_cursor;
                            } else try std.testing.expect(std.mem.indexOf(u8, fixture.screen.browsing.text(), "EARLIER PAGE") == null);
                        },
                    }
                    request = null;
                },
                .send => {
                    if (sent == 0) {
                        if (fragment) {
                            try fixture.byte(0xa9);
                            draft.insert("é");
                            fragment = false;
                            try fixture.checkText(&draft, &.{}, false);
                        }
                        // Also keep the queued, not-yet-launched request in
                        // scope: send must retire both kinds of old read work.
                        front.history_requested = .older;
                        try fixture.bytes("message\r");
                        sent = 1;
                        selected = .live;
                        draft = .{};
                        try std.testing.expect(front.history_requested == null);
                    }
                },
                .latest => {
                    try ops.navigation(front, .latest);
                    selected = .live;
                },
                .transcript => {
                    if (selected != .live) try ops.navigation(front, .latest);
                    try ops.beginTranscript(front);
                    generation += 1;
                    selected = .transcript;
                    older = first_cursor;
                },
                .edit => {
                    if (fragment) try fixture.byte(0xa9) else try fixture.bytes("é");
                    fragment = false;
                    draft.insert("é");
                },
            }
            try std.testing.expectEqual(selected, fixture.screen.view);
            try std.testing.expectEqual(sent, front.sent);
            try std.testing.expectEqual(older, front.transcript_older);
            try fixture.checkText(&draft, &.{}, false);
        }
    };
}

fn acknowledgement(comptime Frontend: type, comptime ops: anytype) !void {
    const Event = enum { deliver_old, deliver_new, accept_old, accept_new, silent, unsettled, evict, redraw };
    const events = std.enums.values(Event);
    for (0..512) |sequence| {
        var fixture: Fixture(Frontend, ops) = undefined;
        try fixture.init();
        defer fixture.deinit();
        const front = fixture.front;
        var delivered: u64 = 0;
        var echo: ?u64 = null;
        var index = sequence;
        for (0..3) |prefix| {
            const event = events[index % events.len];
            index /= events.len;
            errdefer {
                std.debug.print("TD1 acknowledgement sequence={d} prefix={d}\n", .{ sequence, prefix + 1 });
                printPrefix(Event, sequence, prefix + 1);
            }
            switch (event) {
                .accept_old, .accept_new => {
                    const admission: u64 = if (event == .accept_old) 7 else 913;
                    try ops.presentAdmission(front, .{ .accepted = .{ .kind = .message, .confirmed = false, .admission = admission } });
                    echo = if (admission > delivered) admission else null;
                },
                .deliver_old, .deliver_new, .silent, .unsettled => {
                    const admission: u64 = if (event == .deliver_old) 7 else if (event == .deliver_new or event == .unsettled) 913 else 0;
                    front.read_phase = .activity;
                    front.job.result = .{ .settled = event != .unsettled, .delivered = admission, .current = std.mem.zeroes(client.Current) };
                    try ops.applyReader(front, .complete);
                    if (event != .unsettled) {
                        delivered = @max(delivered, admission);
                        if (echo) |value| if (value <= delivered) {
                            echo = null;
                        };
                    }
                },
                .evict => {
                    const block: [4096]u8 = @splat('x');
                    for (0..66) |_| {
                        try fixture.screen.append(&block);
                        try fixture.screen.append("\n");
                    }
                    try std.testing.expect(fixture.screen.live.origin > 0);
                },
                .redraw => try ops.draw(front),
            }
            try std.testing.expectEqual(delivered, front.delivered);
            try std.testing.expectEqual(echo, front.echo);
            try std.testing.expect(fixture.screen.live.length <= Viewport.capacity);
        }
    }
}

fn retention(comptime Frontend: type, comptime ops: anytype) !void {
    // Drive real Host-produced pages, not fabricated marks. The runner admits
    // a 59,199-byte Message behind a held answer, releases the provider only
    // after this UI has read its Admission, then waits for canonical completion.
    // The independent oracle identifies that Message by exact content digest.
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const store = environ.get("RUI_TD1_STORE") orelse return error.MissingRetentionHost;
    const gate = environ.get("RUI_TD1_GATE") orelse return error.MissingRetentionGate;
    var gate_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, gate, .{});
    defer gate_dir.close(std.testing.io);
    const ready_file = try gate_dir.openFile(std.testing.io, "ready", .{ .mode = .write_only });
    defer ready_file.close(std.testing.io);
    const release_file = try gate_dir.openFile(std.testing.io, "release", .{});
    defer release_file.close(std.testing.io);
    var fixture: Fixture(Frontend, ops) = undefined;
    try fixture.init();
    defer fixture.deinit();
    const front = fixture.front;
    front.store = store;
    front.read_phase = .activity;
    front.job = ops.freeze(front, .activity);
    var task: Task = .{ .io = std.testing.io };
    try ops.scan(&front.job, &task);
    try std.testing.expect(front.job.result.settled);
    try ops.showStaged(front);
    try ops.applyReader(front, .complete);
    try historyReachability(front, ops, 0);
    try std.testing.expect(std.c.write(ready_file.handle, "x", 1) == 1);
    var byte: [1]u8 = undefined;
    try std.testing.expect(std.c.read(release_file.handle, &byte, 1) == 1);
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
    for (0..16) |prefix| {
        front.job = ops.freeze(front, .activity);
        try ops.scan(&front.job, &task);
        try std.testing.expect(front.job.result.settled);
        try ops.showStaged(front);
        try ops.applyReader(front, .complete);
        try std.testing.expect(fixture.screen.live.length <= Viewport.capacity);
        try historyReachability(front, ops, prefix + 1);
        if (front.cursor.end == null) break;
    } else return error.ActivityDidNotDrain;
    try std.testing.expect(fixture.screen.live.origin > 0);
}

fn historyReachability(front: anytype, comptime ops: anytype, prefix: usize) !void {
    try ops.navigation(front, .latest);
    try ops.beginTranscript(front);
    const message: [59_199]u8 = @splat('m');
    const messages = [_][]const u8{ "driver", &message };
    var reachable: [2]bool = undefined;
    var digests: [2][32]u8 = undefined;
    for (messages, 0..) |text, index| {
        // A suffix is not a reachable Message: either every byte remains in
        // the frozen transcript or its exact canonical User identity is older.
        reachable[index] = std.mem.indexOf(u8, front.terminal.screen.browsing.text(), text) != null;
        // Independently encode the public content identity domain, not raw
        // SHA-256 and not the production contentDigest implementation.
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&.{ 0, 0, 0, 0, 0, 0, 0, 14 });
        hash.update("rui/content/v1");
        hash.update(text);
        hash.final(&digests[index]);
    }
    var cursor = front.transcript_older;
    const requests: client.Requests = .{ .io = std.testing.io };
    for (0..16) |_| {
        const next = cursor orelse break;
        const page = switch (try requests.conversationPage(front.store, "model", next)) {
            .page => |page| page,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.items[0..page.count]) |item| {
            for (messages, 0..) |text, index| {
                if (item.kind == .user and item.content.bytes == text.len and std.mem.eql(u8, &item.content.digest, &digests[index])) reachable[index] = true;
            }
        }
        cursor = page.continuation();
    } else return error.HistoryDidNotDrain;
    var all_reachable = true;
    for (reachable, 0..) |found, index| {
        if (!found) std.debug.print("TD1 retention counterexample: admit M behind held answer; scan Admission; release answer; scan settled work; evict; browse. prefix={d}, message={s}, origin={d}, cursor={any}; complete Message absent retained view and excluded from canonical history\n", .{ prefix, if (index == 0) "driver" else "queued", front.terminal.screen.live.origin, front.transcript_older });
        all_reachable = all_reachable and found;
    }
    try std.testing.expect(all_reachable);
}

fn publication(comptime Frontend: type, comptime ops: anytype) !void {
    const FlushFailure = struct {
        writer: std.Io.Writer,
        accepted: usize = 0,
        flushed: bool = false,

        fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", writer);
            var count = parts[parts.len - 1].len * splat;
            for (parts[0 .. parts.len - 1]) |part| count += part.len;
            self.accepted += count;
            return count;
        }

        fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *@This() = @fieldParentPtr("writer", writer);
            self.flushed = true;
            return error.WriteFailed;
        }
    };
    for (0..3) |mode| {
        var fixture: Fixture(Frontend, ops) = undefined;
        try fixture.init();
        defer fixture.deinit();
        try fixture.screen.prepareAction(std.testing.io, fixture.action);
        fixture.front.consent.adopt(913, .complete);
        if (mode == 2) {
            // Success is distinct from both failed invocations and still
            // requires a post-write empty-input observation.
            try ops.draw(fixture.front);
            try std.testing.expect(fixture.screen.approvalReady());
            try std.testing.expect(!fixture.front.consent.acceptsInput());
            try std.testing.expect(fixture.front.consent.promptCompleted(try ops.step(fixture.front, 0), false, false));
            try std.testing.expect(fixture.front.consent.acceptsInput());
            continue;
        }
        const before = fixture.screen.action_seen;
        var empty: [0]u8 = .{};
        if (mode == 0) {
            var output = std.Io.Writer.fixed(&empty);
            try std.testing.expectError(error.WriteFailed, fixture.screen.render(&output, fixture.front.terminal.geometry(), "", 0, "", "> ", &.{}));
        } else {
            // Every frame byte is accepted before flush fails. Publishing
            // between writeAll and flush must fail this independent control.
            var output: FlushFailure = .{ .writer = .{ .buffer = &empty, .vtable = &.{ .drain = FlushFailure.drain, .flush = FlushFailure.flush } } };
            try std.testing.expectError(error.WriteFailed, fixture.screen.render(&output.writer, fixture.front.terminal.geometry(), "", 0, "", "> ", &.{}));
            try std.testing.expect(output.accepted > 0 and output.flushed);
        }
        try std.testing.expectEqual(before, fixture.screen.action_seen);
        try std.testing.expect(!fixture.screen.approvalReady());
        try std.testing.expect(!fixture.front.consent.acceptsInput());
    }
}
