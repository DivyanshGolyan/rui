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
pub const At = struct { source: enum { activity, conversation }, position: u64, ordinal: u64 };

pub const Display = struct {
    /// Exact length of the display bytes `stream` delivers.
    length: u64,
    store: []const u8,
    session: []const u8,
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
        const parts = switch (value) {
            .text => |reference| return .{ .display = .{ .length = reference.length, .store = store, .session = session, .body = .{ .text = .{ .at = at, .reference = reference } } } },
            .parts => |parts| parts,
        };
        const list = switch (try readList(requests, store, session, parts, scratch)) {
            .list => |list| list,
            .failure => |failure| return .{ .failure = failure },
        };
        var iterator: protocol_reply.PartIterator = undefined;
        try list.iterator(&iterator);
        return .{ .display = .{ .length = try part_text.length(&iterator), .store = store, .session = session, .body = .{ .parts = list } } };
    }

    /// Feeds exactly `length` display bytes into `sink`. Every Text part is read whole and
    /// must match its certified identity, or the read fails with `ContentBindingMismatch`.
    /// A sink with an `image(part)` method receives images instead of their placeholders.
    pub fn stream(self: *const Display, requests: client.Requests, sink: anytype) !?protocol_reply.ReadFailure {
        switch (self.body) {
            .text => |text| {
                const expected: protocol_reply.CommandObservation.ContentReference = .{ .bytes = text.reference.length, .digest = text.reference.digest };
                return switch (text.at.source) {
                    .activity => requests.readActivityContent(self.store, self.session, text.at.position, text.at.ordinal, expected, sink),
                    .conversation => requests.readConversationContent(self.store, self.session, text.at.position, text.at.ordinal, expected, sink),
                };
            },
            .parts => |*list| {
                var source: PartSource = .{ .requests = requests, .store = self.store, .session = self.session, .owner = list.value.owner, .iterator = undefined };
                try list.iterator(&source.iterator);
                return part_text.write(&source, null, sink);
            },
        }
    }
};

/// The display's first line, for the activity entry at `position`. Parts join with "\n",
/// so the line lies wholly in part 0: that Text part's first line, or the first placeholder.
pub fn firstLine(requests: client.Requests, store: []const u8, session: []const u8, position: u64, value: content_value.Value, scratch: std.Io.File, buffer: []u8) !protocol_reply.ActivityPrefixReply {
    const parts = switch (value) {
        .text => return requests.readActivityPrefix(store, session, position, buffer),
        .parts => |parts| parts,
    };
    const list = switch (try readList(requests, store, session, parts, scratch)) {
        .list => |list| list,
        .failure => |failure| return .{ .failure = failure },
    };
    var iterator: protocol_reply.PartIterator = undefined;
    try list.iterator(&iterator);
    // The decoded list holds at least one part.
    const first = (try iterator.next()).?;
    switch (first.kind) {
        .text => return requests.readPublicPartPrefix(store, session, parts.owner, first, buffer),
        .image => |image| {
            var out: [part_text.max_placeholder_bytes]u8 = undefined;
            const text = part_text.placeholder(1, image, first.reference.length, &out);
            const count = @min(text.len, buffer.len);
            @memcpy(buffer[0..count], text[0..count]);
            return .{ .line = buffer[0..count] };
        },
    }
}

/// Reads the owner's list into `scratch` and accepts it only for this value's owner and manifest.
fn readList(requests: client.Requests, store: []const u8, session: []const u8, parts: content_value.Value.Parts, scratch: std.Io.File) !protocol_reply.PublicPartsReply {
    var sink: ScratchSink = .{ .io = requests.io, .file = scratch };
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try requests.readPublicParts(store, session, parts.owner, &sink, &reply_buffer);
    return protocol_reply.PublicPartsReply.decode(requests.io, scratch, reply, .{ .session = session, .owner = parts.owner, .identity = parts.identity });
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
    requests: client.Requests,
    store: []const u8,
    session: []const u8,
    owner: content_value.Owner,
    iterator: protocol_reply.PartIterator,

    pub const Stop = protocol_reply.ReadFailure;

    pub fn next(self: *PartSource) !?content_value.Part {
        return self.iterator.next();
    }

    pub fn text(self: *PartSource, part: content_value.Part, start: u64, count: u64, sink: anytype) !?protocol_reply.ReadFailure {
        // A Display streams whole, so each Text part is asked for whole.
        std.debug.assert(start == 0 and count == part.reference.length);
        return self.requests.readPublicPartContent(self.store, self.session, self.owner, part, sink);
    }
};

const fake_host = @import("testing/fake_host.zig");
const protocol = @import("protocol.zig");

/// Serves one parts value under one owner, and one text value at every activity and
/// conversation coordinate, through the routes a Display reads.
const PartsHost = struct {
    parts: []const content_value.Part,
    texts: []const []const u8,
    /// Bytes served for a part instead of its certified ones.
    served: ?struct { ordinal: u32, bytes: []const u8 } = null,
    refuse_list: bool = false,
    /// The manifest identity the served list names.
    identity: content_value.Reference = manifest,
    lists: usize = 0,
    part_reads: usize = 0,
    text_reads: usize = 0,

    const owner: content_value.Owner = .{ .action = 9 };
    const manifest: content_value.Reference = .{ .length = 215, .digest = @splat(0x4b) };
    const value: content_value.Value = .{ .parts = .{ .identity = manifest, .owner = owner } };
    const plain = "plain text\nsecond line";

    fn plainValue() content_value.Value {
        return .{ .text = .{ .length = plain.len, .digest = digest(plain) } };
    }

    fn digest(bytes: []const u8) [32]u8 {
        var hash = protocol.contentHasher();
        hash.update(bytes);
        return hash.finalResult();
    }

    fn textPart(ordinal: u32, bytes: []const u8) content_value.Part {
        return .{ .ordinal = ordinal, .kind = .text, .reference = .{ .length = bytes.len, .digest = digest(bytes) } };
    }

    fn imagePart(ordinal: u32, width: u32, height: u32, bytes: u64) content_value.Part {
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
        const request = try fake_host.readRequest(fd, &buffer) orelse return;
        if (request.is("/v1/public-parts")) {
            self.lists += 1;
            if (self.refuse_list) return fake_host.refuse(fd, .parts_unavailable, "ContentIsText");
            var capture: Capture = .{};
            var writer: protocol.public_parts_reply.Writer(Capture) = .{ .capture = &capture, .session = "k7m2qx" };
            try writer.head(.{ .identity = self.identity, .owner = owner });
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
        } else if (request.is("/v1/activity-content") or request.is("/v1/conversation-content")) {
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
            const at: At = .{ .source = .activity, .position = 4, .ordinal = 0 };

            // A text value is read from where it was shown, with no list request.
            for ([_]@FieldType(At, "source"){ .activity, .conversation }) |source| {
                const display = (try Display.open(requests, root, "k7m2qx", .{ .source = source, .position = 4, .ordinal = 1 }, PartsHost.plainValue(), scratch)).display;
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
        }
    };
    const texts = [_][]const u8{ "Describe this screenshot.", "", "line one\nline two" };
    const parts = [_]content_value.Part{ PartsHost.textPart(0, texts[0]), PartsHost.imagePart(1, 1024, 768, 245_012), PartsHost.textPart(2, texts[2]) };
    var host: PartsHost = .{ .parts = &parts, .texts = &texts };
    var domain: Domain = .{};
    try fake_host.withHost(&host, &domain);
}
