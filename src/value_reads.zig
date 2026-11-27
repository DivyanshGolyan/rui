//! The client path from a stored content value to the bytes a screen draws. A text
//! value is read through the route that showed it; a parts value through its owner's
//! certified list, laid out by `part_text`, with each Text part checked against the
//! length and digest the list certified.
const std = @import("std");
const client = @import("client.zig");
const content_value = @import("content_value.zig");
const part_text = @import("part_text.zig");
const protocol_reply = @import("protocol_reply.zig");

/// Where a text value was shown: the read that delivers its bytes.
pub const At = struct { position: u64, ordinal: u64 };

pub const Display = struct {
    /// Exact length of the display bytes `stream` delivers.
    length: u64,
    reads: client.SessionReads,
    body: union(enum) {
        text: struct { at: At, reference: content_value.Reference },
        /// Borrows the scratch file `open` read the list into.
        parts: protocol_reply.PartList,
    },

    pub const Opened = union(enum) { display: Display, failure: protocol_reply.ReadFailure };

    /// A text value costs no request. A parts value reads its owner's certified list once
    /// into `scratch`, which every later `stream` re-reads, so it outlives the Display.
    /// `store` and `session` are borrowed for the Display's life.
    pub fn open(requests: client.Requests, store: []const u8, session: []const u8, at: At, value: content_value.Value, scratch: std.Io.File) !Opened {
        return openUsing(client.SessionReads.selected(requests, store, session), at, value, scratch);
    }

    /// A scan can open only an Activity value through its bound route.
    pub fn openActivity(reads: client.SessionReads, position: u64, ordinal: u64, value: content_value.Value, scratch: std.Io.File) !Opened {
        return openUsing(reads, .{ .position = position, .ordinal = ordinal }, value, scratch);
    }

    fn openUsing(reads: client.SessionReads, at: At, value: content_value.Value, scratch: std.Io.File) !Opened {
        const parts = switch (value) {
            .text => |reference| return .{ .display = .{ .length = reference.length, .reads = reads, .body = .{ .text = .{ .at = at, .reference = reference } } } },
            .parts => |parts| parts,
        };
        const list = switch (try readList(reads, parts, scratch)) {
            .list => |list| list,
            .failure => |failure| return .{ .failure = failure },
        };
        var iterator: protocol_reply.PartIterator = undefined;
        try list.iterator(&iterator);
        return .{ .display = .{ .length = try part_text.displayLength(&iterator, labels(parts.owner)), .reads = reads, .body = .{ .parts = list } } };
    }

    /// Feeds exactly `length` display bytes into `sink`. Every Text part is read whole and
    /// must match its certified identity, or the read fails with `ContentBindingMismatch`.
    /// A sink with an `image(part)` method receives images instead of their placeholders.
    pub fn stream(self: *const Display, requests: client.Requests, sink: anytype) !?protocol_reply.ReadFailure {
        return self.streamUsing(self.reads.withStandaloneRequests(requests), sink);
    }

    /// Streams a Display returned by openActivity with its original read context.
    /// A bound route is borrowed only until the originating worker completes;
    /// Displays returned by open use stream with the caller's read context.
    pub fn streamBound(self: *const Display, sink: anytype) !?protocol_reply.ReadFailure {
        return self.streamUsing(self.reads, sink);
    }

    fn streamUsing(self: *const Display, reads: client.SessionReads, sink: anytype) !?protocol_reply.ReadFailure {
        switch (self.body) {
            .text => |text| {
                const expected: protocol_reply.CommandObservation.ContentReference = .{ .bytes = text.reference.length, .digest = text.reference.digest };
                return reads.readActivityContent(text.at.position, text.at.ordinal, expected, sink);
            },
            .parts => |*list| {
                var source: PartSource = .{ .reads = reads, .list = list, .pass = if (list.value.owner == .message) .images else .stored };
                try list.iterator(&source.iterator);
                return part_text.streamDisplay(&source, labels(list.value.owner), null, sink);
            },
        }
    }
};

/// The display's first line, for the activity entry at `position`. Parts join with "\n",
/// so the line lies wholly in part 0: that Text part's first line, or the first placeholder.
pub fn firstLine(requests: client.Requests, store: []const u8, session: []const u8, position: u64, value: content_value.Value, scratch: std.Io.File, buffer: []u8) !protocol_reply.ActivityPrefixReply {
    return firstLineWith(client.SessionReads.selected(requests, store, session), position, value, scratch, buffer);
}

pub fn firstLineWith(reads: client.SessionReads, position: u64, value: content_value.Value, scratch: std.Io.File, buffer: []u8) !protocol_reply.ActivityPrefixReply {
    const parts = switch (value) {
        .text => return reads.readActivityPrefix(position, buffer),
        .parts => |parts| parts,
    };
    const list = switch (try readList(reads, parts, scratch)) {
        .list => |list| list,
        .failure => |failure| return .{ .failure = failure },
    };
    var iterator: protocol_reply.PartIterator = undefined;
    try list.iterator(&iterator);
    // The decoded list holds at least one part.
    const first = (try iterator.next()).?;
    switch (first.kind) {
        .text => return reads.readPublicPartPrefix(parts.owner, first, buffer),
        .image => |image| {
            var out: [part_text.max_placeholder_bytes]u8 = undefined;
            const text = part_text.displayPlaceholder(labels(parts.owner), 1, image, first.reference.length, &out);
            const count = @min(text.len, buffer.len);
            @memcpy(buffer[0..count], text[0..count]);
            return .{ .line = buffer[0..count] };
        },
    }
}

fn labels(owner: content_value.Owner) part_text.Labels {
    return if (owner == .message) .compact else .detailed;
}

/// Reads the owner's list into `scratch` and accepts it only for this value's owner and manifest.
fn readList(reads: client.SessionReads, parts: content_value.Value.Parts, scratch: std.Io.File) !protocol_reply.PublicPartsReply {
    var sink: ScratchSink = .{ .io = reads.io(), .file = scratch };
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try reads.readPublicParts(parts.owner, &sink, &reply_buffer);
    return protocol_reply.PublicPartsReply.decode(reads.io(), scratch, reply, .{ .session = reads.sessionId(), .owner = parts.owner, .identity = parts.identity });
}

/// Writes the list from offset 0 whatever the file's cursor, so a reused scratch is overwritten.
const ScratchSink = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,

    pub fn feed(self: *ScratchSink, bytes: []const u8) !void {
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

/// The certified list as a `part_text` source; Text parts come from the parts route.
const PartSource = struct {
    reads: client.SessionReads,
    list: *const protocol_reply.PartList,
    iterator: protocol_reply.PartIterator = undefined,
    pass: enum { stored, images, text },

    pub const Stop = protocol_reply.ReadFailure;

    pub fn next(self: *PartSource) !?content_value.Part {
        while (true) {
            const part = (try self.iterator.next()) orelse {
                if (self.pass != .images) return null;
                try self.list.iterator(&self.iterator);
                self.pass = .text;
                continue;
            };
            if (self.pass == .stored or (self.pass == .images) == (part.kind == .image)) return part;
        }
    }

    pub fn text(self: *PartSource, part: content_value.Part, start: u64, count: u64, sink: anytype) !?protocol_reply.ReadFailure {
        // A Display streams whole, so each Text part is asked for whole.
        std.debug.assert(start == 0 and count == part.reference.length);
        return self.reads.readPublicPartContent(self.list.value.owner, part, sink);
    }
};

const fake_host = @import("testing/fake_host.zig");
const protocol = @import("protocol.zig");

/// Serves one parts value under one owner, and one text value at every activity and
/// conversation coordinate, through the routes a Display reads.
pub const PartsHost = struct {
    parts: []const content_value.Part,
    texts: []const []const u8,
    /// Bytes served for a part instead of its certified ones.
    served: ?struct { ordinal: u32, bytes: []const u8 } = null,
    refuse_list: bool = false,
    /// The manifest identity the served list names.
    identity: content_value.Reference = manifest,
    served_owner: content_value.Owner = owner,
    lists: usize = 0,
    part_reads: usize = 0,
    text_reads: usize = 0,

    const owner: content_value.Owner = .{ .action = 9 };
    const manifest: content_value.Reference = .{ .length = 215, .digest = @splat(0x4b) };
    pub const value: content_value.Value = .{ .parts = .{ .identity = manifest, .owner = owner } };
    const plain = "plain text\nsecond line";

    fn plainValue() content_value.Value {
        return .{ .text = .{ .length = plain.len, .digest = digest(plain) } };
    }

    fn digest(bytes: []const u8) [32]u8 {
        var hash = protocol.contentHasher();
        hash.update(bytes);
        return hash.finalResult();
    }

    pub fn textPart(ordinal: u32, bytes: []const u8) content_value.Part {
        return .{ .ordinal = ordinal, .kind = .text, .reference = .{ .length = bytes.len, .digest = digest(bytes) } };
    }

    pub fn imagePart(ordinal: u32, width: u32, height: u32, bytes: u64) content_value.Part {
        return .{ .ordinal = ordinal, .kind = .{ .image = .{ .media = .{ .format = .png, .width = width, .height = height }, .name = null } }, .reference = .{ .length = bytes, .digest = @splat(0xe3) } };
    }

    const Capture = struct {
        buffer: [4096]u8 = undefined,
        len: usize = 0,
        pub fn append(self: *Capture, bytes: []const u8) !void {
            @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
    };

    pub fn answer(self: *PartsHost, fd: std.posix.fd_t) !void {
        var buffer: [8192]u8 = undefined;
        try self.serve(fd, try fake_host.readRequest(fd, &buffer) orelse return);
    }

    /// Answers one request already read.
    pub fn serve(self: *PartsHost, fd: std.posix.fd_t, request: fake_host.Request) !void {
        if (request.is("/v1/public-parts")) {
            self.lists += 1;
            if (self.refuse_list) return fake_host.refuse(fd, .parts_unavailable, "ContentIsText");
            var capture: Capture = .{};
            var writer: protocol.public_parts_reply.Writer(Capture) = .{ .capture = &capture, .session = "k7m2qx" };
            try writer.head(.{ .identity = self.identity, .owner = self.served_owner });
            for (self.parts) |part| try writer.part(part);
            try writer.finish();
            fake_host.respond(fd, "200 OK", "application/json", "", capture.buffer[0..capture.len]);
        } else if (request.is("/v1/public-part-content")) {
            self.part_reads += 1;
            const Body = struct { part: []const u8 };
            var storage: [1024]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&storage);
            const body = try std.json.parseFromSliceLeaky(Body, fixed.allocator(), request.body, .{ .ignore_unknown_fields = true });
            const ordinal = try std.fmt.parseInt(u32, body.part, 10);
            if (self.served) |served| if (served.ordinal == ordinal) return fake_host.respondContent(fd, served.bytes);
            fake_host.respondContent(fd, self.texts[ordinal]);
        } else if (request.is("/v1/activity-content")) {
            self.text_reads += 1;
            fake_host.respondContent(fd, plain);
        }
    }
};

const Collect = struct {
    buffer: [1024]u8 = undefined,
    len: usize = 0,

    pub fn feed(self: *Collect, bytes: []const u8) !void {
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn slice(self: *const Collect) []const u8 {
        return self.buffer[0..self.len];
    }
};

test "SUI-60 parts values draw as text and image placeholders" {
    const Domain = struct {
        pub fn run(_: *@This(), host: *PartsHost, dir: std.Io.Dir, root: []const u8) !void {
            const io = std.testing.io;
            const requests: client.Requests = .{ .io = io };
            const scratch = try dir.createFile(io, "list", .{ .read = true });
            defer scratch.close(io);
            // A stale, longer list in the scratch never reaches a later read.
            try scratch.writePositionalAll(io, &@as([5000]u8, @splat('x')), 0);
            const at: At = .{ .position = 4, .ordinal = 0 };

            // A text value is read from where it was shown, with no list request.
            {
                const display = (try Display.open(requests, root, "k7m2qx", .{ .position = 4, .ordinal = 1 }, PartsHost.plainValue(), scratch)).display;
                var out: Collect = .{};
                try std.testing.expectEqual(@as(?protocol_reply.ReadFailure, null), try display.stream(requests, &out));
                try std.testing.expectEqualStrings(PartsHost.plain, out.slice());
                try std.testing.expectEqual(@as(u64, PartsHost.plain.len), display.length);
            }
            try std.testing.expectEqual(@as(usize, 0), host.lists);

            // Text, Image, Text: one list read, then each Text part once; the length is known before.
            const display = (try Display.open(requests, root, "k7m2qx", at, PartsHost.value, scratch)).display;
            const expected = "Describe this screenshot.\n[image 1: PNG 1024x768, 245 KB]\nline one\nline two";
            try std.testing.expectEqual(@as(u64, expected.len), display.length);
            try std.testing.expectEqual(@as(usize, 0), host.part_reads);
            for (0..2) |_| {
                var out: Collect = .{};
                try std.testing.expectEqual(@as(?protocol_reply.ReadFailure, null), try display.stream(requests, &out));
                try std.testing.expectEqualStrings(expected, out.slice());
            }
            try std.testing.expectEqual(@as(usize, 1), host.lists);
            try std.testing.expectEqual(@as(usize, 4), host.part_reads);

            // A sink that takes images is handed the Image part instead of its placeholder.
            const Pixels = struct {
                text: Collect = .{},
                images: usize = 0,
                pub fn feed(self: *@This(), bytes: []const u8) !void {
                    try self.text.feed(bytes);
                }
                pub fn image(self: *@This(), part: content_value.Part) !void {
                    try std.testing.expectEqual(@as(u32, 1), part.ordinal);
                    self.images += 1;
                }
            };
            var pixels: Pixels = .{};
            _ = try display.stream(requests, &pixels);
            try std.testing.expectEqualStrings("Describe this screenshot.\n\nline one\nline two", pixels.text.slice());
            try std.testing.expectEqual(@as(usize, 1), pixels.images);

            // First lines: a text value's own, a leading Text part's, a leading Image's placeholder.
            // They read lists into their own scratch: `display` still borrows its list's file.
            const lines = try dir.createFile(io, "lines", .{ .read = true });
            defer lines.close(io);
            var line: [64]u8 = undefined;
            try std.testing.expectEqualStrings("plain text", (try firstLine(requests, root, "k7m2qx", 4, PartsHost.plainValue(), lines, &line)).line);
            try std.testing.expectEqualStrings("Describe this screenshot.", (try firstLine(requests, root, "k7m2qx", 4, PartsHost.value, lines, &line)).line);
            const image_first = [_]content_value.Part{ PartsHost.imagePart(0, 1024, 768, 245_012), PartsHost.textPart(1, "after") };
            const original = host.parts;
            host.parts = &image_first;
            try std.testing.expectEqualStrings("[image 1: PNG 1024x768, 245 KB]", (try firstLine(requests, root, "k7m2qx", 4, PartsHost.value, lines, &line)).line);
            var short: [8]u8 = undefined;
            try std.testing.expectEqualStrings("[image 1", (try firstLine(requests, root, "k7m2qx", 4, PartsHost.value, lines, &short)).line);
            host.parts = original;

            // Text part bytes that miss their certified digest or length fail the read.
            for ([_][]const u8{ "line one\nline twO", "line one\nline two!", "line one" }) |damaged| {
                host.served = .{ .ordinal = 2, .bytes = damaged };
                var out: Collect = .{};
                try std.testing.expectError(error.ContentBindingMismatch, display.stream(requests, &out));
                try std.testing.expect(std.mem.indexOf(u8, out.slice(), damaged) == null);
            }
            host.served = .{ .ordinal = 0, .bytes = "Describe this screenshot!" };
            var damaged_first: Collect = .{};
            try std.testing.expectError(error.ContentBindingMismatch, display.stream(requests, &damaged_first));
            try std.testing.expectEqualStrings("", damaged_first.slice());
            host.served = .{ .ordinal = 0, .bytes = "Describe this." };
            try std.testing.expectError(error.ContentBindingMismatch, firstLine(requests, root, "k7m2qx", 4, PartsHost.value, lines, &line));
            host.served = null;

            // A list for another manifest is not this value's list; a refusal is a read failure.
            host.identity = .{ .length = 216, .digest = PartsHost.manifest.digest };
            try std.testing.expectError(error.InvalidPartList, Display.open(requests, root, "k7m2qx", at, PartsHost.value, scratch));
            host.identity = PartsHost.manifest;
            host.refuse_list = true;
            const refused = (try Display.open(requests, root, "k7m2qx", at, PartsHost.value, scratch)).failure;
            try std.testing.expectEqualStrings("ContentIsText", refused.diagnostic.code.slice());
            try std.testing.expectEqualStrings("ContentIsText", (try firstLine(requests, root, "k7m2qx", 4, PartsHost.value, lines, &line)).failure.diagnostic.code.slice());
            host.refuse_list = false;

            // A bound Display keeps the route and cancellation context it opened with,
            // even when another Store contains the same certified bytes and owner IDs.
            const Bound = struct {
                paths: *const @import("platform.zig").Paths,
                dir: std.Io.Dir,
                alias: []const u8,
                scratch: std.Io.File,
                original: *PartsHost,
                pub fn run(self: *@This(), other: *PartsHost, _: std.Io.Dir, other_root: []const u8) !void {
                    const io_ = std.testing.io;
                    const original_requests: client.Requests = .{ .io = io_ };
                    const reads = client.SessionReads.bound(original_requests, self.paths, "k7m2qx");
                    const text_display = (try Display.openActivity(reads, 4, 0, PartsHost.plainValue(), self.scratch)).display;
                    const parts_display = (try Display.openActivity(reads, 4, 0, PartsHost.value, self.scratch)).display;
                    try self.dir.deleteFile(io_, "route-alias");
                    try self.dir.symLink(io_, other_root, "route-alias", .{ .is_directory = true });
                    var stopped: client.Cancellation = .{};
                    stopped.requestStop();
                    var other_origin: client.FailureOrigin = .local;
                    const replacement: client.Requests = .{ .io = io_, .cancellation = &stopped, .failure_origin = &other_origin };
                    try std.testing.expect(!@hasDecl(Display, "streamWith"));
                    try std.testing.expect(!@hasDecl(Display, "openWith"));
                    var text_out: Collect = .{};
                    try std.testing.expectEqual(@as(?protocol_reply.ReadFailure, null), try text_display.stream(replacement, &text_out));
                    try std.testing.expectEqualStrings(PartsHost.plain, text_out.slice());
                    var parts_out: Collect = .{};
                    try std.testing.expectEqual(@as(?protocol_reply.ReadFailure, null), try parts_display.stream(replacement, &parts_out));
                    try std.testing.expectEqualStrings("Describe this screenshot.\n[image 1: PNG 1024x768, 245 KB]\nline one\nline two", parts_out.slice());
                    try std.testing.expectEqual(client.FailureOrigin.local, other_origin);
                    try std.testing.expectEqual(@as(usize, 0), other.text_reads + other.lists + other.part_reads);
                    // The legacy selected adapter still uses the supplied context.
                    const selected = (try Display.open(original_requests, self.alias, "k7m2qx", .{ .position = 4, .ordinal = 0 }, PartsHost.plainValue(), self.scratch)).display;
                    var stopped_out: Collect = .{};
                    try std.testing.expectError(error.Cancelled, selected.stream(replacement, &stopped_out));
                    var other_out: Collect = .{};
                    try std.testing.expectEqual(@as(?protocol_reply.ReadFailure, null), try selected.stream(original_requests, &other_out));
                    try std.testing.expectEqualStrings(PartsHost.plain, other_out.slice());
                    try std.testing.expectEqual(@as(usize, 1), other.text_reads);
                    try std.testing.expect(self.original.part_reads != 0);
                }
            };
            try dir.symLink(io, ".", "route-alias", .{ .is_directory = true });
            var alias_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const alias = try std.fmt.bufPrint(&alias_buffer, "{s}/route-alias", .{root});
            const paths = try client.resolveClientPaths(io, alias);
            var other: PartsHost = .{ .parts = host.parts, .texts = host.texts };
            var bound: Bound = .{ .paths = &paths, .dir = dir, .alias = alias, .scratch = scratch, .original = host };
            try fake_host.withHost(&other, &bound);
        }
    };
    const texts = [_][]const u8{ "Describe this screenshot.", "", "line one\nline two" };
    const parts = [_]content_value.Part{ PartsHost.textPart(0, texts[0]), PartsHost.imagePart(1, 1024, 768, 245_012), PartsHost.textPart(2, texts[2]) };
    var host: PartsHost = .{ .parts = &parts, .texts = &texts };
    var domain: Domain = .{};
    try fake_host.withHost(&host, &domain);
}
