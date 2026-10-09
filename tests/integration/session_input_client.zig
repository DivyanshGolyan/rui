const std = @import("std");
const client = @import("rui_client");
const Input = client.SessionInput;

// Actual library consumer: one pinned input owner and one actual captured
// reader through each send/recovery. No TTY, worker or alternate record owner.
const Capturer = struct {
    io: std.Io,
    input: *Input,
    store: []const u8,
    session: []const u8,
    record: []const u8,
    key: []const u8,
    later: []const u8 = "",

    pub fn capture(self: @This(), bytes: []const u8) !client.CapturedRecord {
        for (self.later) |byte| _ = self.input.feed(byte);
        return client.captureMessage(self.io, .{
            .store = self.store,
            .session = self.session,
            .text_path = "",
            .text = bytes,
        }, .{ .explicit = .{ .record = self.record, .key = self.key } });
    }

    pub fn recover(self: @This(), bytes: []const u8) !client.CapturedRecord {
        var captured = try client.openCaptured(self.io, std.fs.path.dirname(self.record).?, self.key);
        errdefer captured.close(self.io);
        try std.testing.expectEqualStrings(self.store, captured.identity().store.slice());
        try std.testing.expectEqualStrings(self.session, captured.identity().session.slice());
        try std.testing.expectEqualStrings(self.key, captured.identity().key.slice());
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("\x00\x00\x00\x00\x00\x00\x00\x0erui/content/v1");
        hash.update(bytes);
        try std.testing.expectEqual(@as(u64, bytes.len), captured.target.message.bytes);
        try std.testing.expectEqual(hash.finalResult(), captured.target.message.digest);
        return captured;
    }
};

fn seal(input: *Input, bytes: []const u8) !Input.Ticket {
    for (bytes) |byte| _ = input.feed(byte);
    const event = input.feed('\r');
    try std.testing.expectEqual(.message, std.meta.activeTag(event));
    return event.message;
}

fn expectDraft(view: Input.View, text: []const u8, cursor: usize) !void {
    try std.testing.expectEqualStrings(text, view.bytes);
    try std.testing.expectEqual(cursor, view.cursor);
}

fn sampleBoundary() !void {
    var credit: [1]u8 = undefined;
    if (try std.posix.read(0, &credit) != 1 or credit[0] != 'x') return error.MissingFixtureCredit;
}

fn captureFailure(io: std.Io, store: []const u8, record: []const u8) !void {
    var input: Input = undefined;
    input.init();
    const ticket = try seal(&input, "original\x1b[D");
    const capturer: Capturer = .{ .io = io, .input = &input, .store = store, .session = "opening/original", .record = record, .key = "capture-failed", .later = "next\x1b[D" };
    try std.testing.expectError(error.InsecureRecordDirectory, input.capture(ticket, capturer));
    try expectDraft(input.retained().?, "original", 7);
    try expectDraft(input.composition(), "next", 3);
    try std.testing.expectEqual(.capture_failed, input.submissionState().?);
    try std.testing.expectError(error.SubmissionUnresolved, input.capture(ticket, capturer));
    // Borrow was released even on real I/O failure; this is a custody failure,
    // not a still-live callback or evidence that publication never happened.
    try std.testing.expectError(error.SubmissionNotCaptured, input.resolve(ticket, .accepted));
}

fn publicationFailure(io: std.Io, store: []const u8, record: []const u8) !void {
    const Failure = struct {
        fn length(_: ?*anyopaque, _: std.Io.File) std.Io.File.LengthError!u64 {
            return error.AccessDenied;
        }
    };
    var vtable = io.vtable.*;
    vtable.fileLength = Failure.length; // Actual post-publication production path.
    var input: Input = undefined;
    input.init();
    const ticket = try seal(&input, "published\x1b[D");
    var capturer: Capturer = .{
        .io = .{ .userdata = io.userdata, .vtable = &vtable },
        .input = &input,
        .store = store,
        .session = "opening/original",
        .record = record,
        .key = "01234567-89ab-4cde-8fab-0123456789ab",
        .later = "following\x1b[D",
    };
    try std.testing.expectError(error.AccessDenied, input.capture(ticket, capturer));
    try std.testing.expectEqual(.capture_failed, input.submissionState().?);
    try expectDraft(input.retained().?, "published", 8);
    try expectDraft(input.composition(), "following", 8);
    capturer.io = io;
    var reply_buffer: client.ReplyBuffer = .{};
    const observed = try client.observeCommand(io, store, capturer.key, &reply_buffer);
    try std.testing.expectEqual(.absent, observed.observation.status);
    try std.testing.expectError(error.SubmissionUnresolved, input.capture(ticket, capturer));
    var captured = try input.recover(ticket, capturer);
    defer captured.close(io);
    try expectDraft(input.retained().?, "published", 8);
    const reply = try client.sendCaptured(io, &captured, null, &reply_buffer);
    try std.testing.expect(reply.isAccepted() and !(try reply.answer).replayed);
    try input.resolve(ticket, .accepted);
    try expectDraft(input.composition(), "following", 8);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    defer std.heap.c_allocator.free(args);
    if (args.len != 4) return error.InvalidArguments;
    try std.Io.File.stdout().writeStreamingAll(init.io, "input-baseline\n");
    try sampleBoundary();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try captureFailure(init.io, args[1], try std.fmt.bufPrint(&path_buffer, "{s}/blocked/intent.json", .{args[3]}));
    try publicationFailure(init.io, args[1], try std.fmt.bufPrint(&path_buffer, "{s}/01234567-89ab-4cde-8fab-0123456789ab.json", .{args[3]}));
    var input: Input = undefined;
    input.init();
    var reply_buffer: client.ReplyBuffer = .{};
    var capturer: Capturer = .{
        .io = init.io,
        .input = &input,
        .store = args[1],
        .session = "opening/original",
        .record = try std.fmt.bufPrint(&path_buffer, "{s}/original.json", .{args[3]}),
        .key = "original",
        .later = "next!\x1b[D",
    };
    const original = try seal(&input, "aéZ\x1b[D");
    {
        var captured = try input.capture(original, capturer);
        defer captured.close(init.io);
        try std.testing.expectEqual(.not_sent, input.submissionState().?);
        // Fail a real announcement after publication; it cannot reopen capture.
        const announcement = try std.Io.Dir.cwd().openFile(init.io, capturer.record, .{});
        defer announcement.close(init.io);
        var failed = false;
        announcement.writeStreamingAll(init.io, "must not write") catch {
            failed = true;
        };
        try std.testing.expect(failed);
        try std.testing.expectError(error.SubmissionUnresolved, input.capture(original, capturer));
        try std.testing.expectError(error.TruncatedResponse, client.sendCaptured(init.io, &captured, "after-commit", &reply_buffer));
        try input.resolve(original, .unconfirmed);
        var stop: client.Cancellation = .{};
        stop.requestStop();
        try std.testing.expectError(error.Cancelled, (client.Requests{ .io = init.io, .cancellation = &stop }).sendCaptured(&captured, null, &reply_buffer));
        try input.resolve(original, .not_sent);
        try std.testing.expectEqual(.unconfirmed, input.submissionState().?);
        try std.testing.expectEqual(.busy, std.meta.activeTag(input.feed('\r')));
        capturer.store = args[2]; // Future selection, not recovery authority.
        capturer.session = "selected/later";
        try std.testing.expectEqualStrings(args[1], captured.identity().store.slice());
        try std.testing.expectEqualStrings("opening/original", captured.identity().session.slice());
        const reply = try client.sendCaptured(init.io, &captured, null, &reply_buffer);
        try std.testing.expect(reply.isAccepted() and (try reply.answer).replayed);
        try input.resolve(original, .accepted);
        try expectDraft(input.composition(), "next!", 4);
    }
    capturer.record = try std.fmt.bufPrint(&path_buffer, "{s}/next.json", .{args[3]});
    capturer.key = "next";
    capturer.later = "";
    const next = try seal(&input, "");
    {
        var captured = try input.capture(next, capturer);
        defer captured.close(init.io);
        // A duplicate result for original cannot release the newly captured next.
        try std.testing.expectError(error.SubmissionChanged, input.resolve(original, .accepted));
        try expectDraft(input.retained().?, "next!", 4);
        const reply = try client.sendCaptured(init.io, &captured, null, &reply_buffer);
        try std.testing.expect(reply.isAccepted() and !(try reply.answer).replayed);
        try input.resolve(next, .accepted);
    }
    capturer.store = args[1];
    capturer.session = "missing";
    for ([_][]const u8{ "restore", "retain" }) |key| {
        capturer.record = try std.fmt.bufPrint(&path_buffer, "{s}/{s}.json", .{ args[3], key });
        capturer.key = key;
        capturer.later = if (std.mem.eql(u8, key, "retain")) "new\x1b[D" else "";
        const ticket = try seal(&input, if (std.mem.eql(u8, key, "restore")) "badé!\x1b[D" else "");
        var captured = try input.capture(ticket, capturer);
        defer captured.close(init.io);
        const reply = try client.sendCaptured(init.io, &captured, null, &reply_buffer);
        try std.testing.expectEqual(.rejected, std.meta.activeTag((try reply.answer).result));
        try input.resolve(ticket, .rejected);
        if (std.mem.eql(u8, key, "restore")) {
            try expectDraft(input.composition(), "badé!", 5);
            try std.testing.expect(input.submissionState() == null);
        } else {
            try expectDraft(input.retained().?, "badé!", 5);
            try expectDraft(input.composition(), "new", 2);
            try input.discardRejected(ticket);
            try expectDraft(input.composition(), "new", 2);
        }
    }
    input.clearComposition();
    for ("\x1b[200~") |byte| _ = input.feed(byte);
    for (0..65_532) |_| _ = input.feed('x');
    for ("\nµZ\x1b[201~") |byte| _ = input.feed(byte);
    const complete = try seal(&input, "");
    capturer.record = try std.fmt.bufPrint(&path_buffer, "{s}/complete.json", .{args[3]});
    capturer.session = "opening/original";
    capturer.key = "complete";
    capturer.later = "kept\x1b[D";
    {
        var captured = try input.capture(complete, capturer);
        defer captured.close(init.io);
        const reply = try client.sendCaptured(init.io, &captured, null, &reply_buffer);
        try std.testing.expect(reply.isAccepted() and !(try reply.answer).replayed);
        try input.resolve(complete, .accepted);
        try expectDraft(input.composition(), "kept", 3);
    }
    var output: [256]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&output, "Session input native: capture failure, announcement failure, lost reply, sticky uncertainty, original recovery, changed destination, rejection/retained discard, complete 65536; owner={d} bytes\n", .{@sizeOf(Input)}));
    try sampleBoundary(); // All capture/socket/announcement scopes have ended.
}
