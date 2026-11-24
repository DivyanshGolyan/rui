const std = @import("std");

pub const max_image_bytes = 16 * 1024 * 1024;
pub const max_text_bytes = 65_537;

const base64 = std.base64.standard;
const chunk_limit = 4096;
const password_limit = base64.Encoder.calcSize(128);
const header_limit = 512;

pub const Mime = enum {
    png,
    jpeg,
    text,
    tiff,

    pub fn mime(self: Mime) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .text => "text/plain",
            .tiff => "image/tiff",
        };
    }

    fn limit(self: Mime) usize {
        return switch (self) {
            .png, .jpeg => max_image_bytes,
            .text => max_text_bytes,
            .tiff => unreachable,
        };
    }
};

pub const Request = struct {
    buffer: [288]u8 = undefined,
    len: usize = 0,

    /// The complete OSC, borrowed from this value.
    pub fn bytes(self: *const Request) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub const Effect = union(enum) {
    read: Request,
    /// The caller owns text and image bytes through the receive allocator.
    text: struct { epoch: u64, bytes: []u8 },
    image: struct { epoch: u64, bytes: []u8, mime: Mime },
    local_image: u64,
};

pub const Transaction = struct {
    phase: union(enum) {
        idle,
        offer: Offer,
        read: Read,
    } = .idle,
    next_id: u64 = 0,

    const Offer = struct {
        epoch: u64,
        primary: bool,
        password: [password_limit]u8 = undefined,
        password_len: usize = 0,
        listed: bool = false,
        preferred: ?Mime = null,
        discarded: bool = false,

        fn token(self: *const Offer) []const u8 {
            return self.password[0..self.password_len];
        }
    };

    const Read = struct {
        epoch: u64,
        id: u64,
        mime: Mime,
        content: std.ArrayList(u8) = .empty,
        started: bool = false,
        ignoring_offer: bool = false,
        discarded: bool = false,

        fn discard(self: *Read, allocator: std.mem.Allocator) void {
            self.content.deinit(allocator);
            self.content = .empty;
            self.discarded = true;
        }
    };

    /// True while awaiting another frame, including after abort.
    pub fn pending(self: *const Transaction) bool {
        return self.phase != .idle;
    }

    /// Drop buffered content and consume the rest of the announced burst.
    pub fn abort(self: *Transaction, allocator: std.mem.Allocator) void {
        switch (self.phase) {
            .idle => {},
            .offer => |*offer| offer.discarded = true,
            .read => |*read| read.discard(allocator),
        }
    }

    /// Release all storage when the terminal stream ends or times out.
    /// Retain the request sequence so a late tagged reply stays stale.
    pub fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
        self.abort(allocator);
        self.phase = .idle;
    }

    /// Consume one OSC payload after `5522;`, with the terminator stripped.
    /// The epoch belongs to the target at the offer's opening OK.
    pub fn receive(self: *Transaction, allocator: std.mem.Allocator, payload: []const u8, epoch: u64) ?Effect {
        const frame = Frame.parse(payload);
        if (!frame.is_read) return null;

        switch (self.phase) {
            .idle => self.beginOffer(frame, epoch),
            .offer => return self.receiveOffer(frame, epoch),
            .read => return self.receiveRead(allocator, frame, epoch),
        }
        return null;
    }

    fn beginOffer(self: *Transaction, frame: Frame, epoch: u64) void {
        if (frame.id != null or frame.status != .OK) return;
        self.phase = .{ .offer = .{ .epoch = epoch, .primary = frame.primary } };
        const offer = &self.phase.offer;
        if (!frame.valid) {
            offer.discarded = true;
            return;
        }
        if (frame.password) |password| {
            @memcpy(offer.password[0..password.len], password);
            offer.password_len = password.len;
        }
    }

    fn receiveOffer(self: *Transaction, frame: Frame, epoch: u64) ?Effect {
        if (frame.id != null) return null;
        const offer = &self.phase.offer;
        if (!frame.valid or epoch != offer.epoch or
            (frame.password != null and !eql(frame.password.?, offer.token()))) offer.discarded = true;

        switch (frame.status orelse return null) {
            .OK => offer.discarded = true,
            .DATA => {
                if (offer.discarded) return null;
                if (offer.listed or !eql(frame.mime orelse "", "Lg==")) {
                    offer.discarded = true;
                    return null;
                }
                offer.listed = true;
                var decoded: [chunk_limit]u8 = undefined;
                const list = decodeChunk(&decoded, frame.payload) orelse {
                    offer.discarded = true;
                    return null;
                };
                for (list) |byte| if (!std.ascii.isPrint(byte) and !std.ascii.isWhitespace(byte)) {
                    offer.discarded = true;
                    return null;
                };
                offer.preferred = preferredMime(list);
            },
            .DONE => {
                const completed = offer.*;
                self.phase = .idle;
                if (completed.discarded) return null;
                const mime = completed.preferred orelse return null;
                if (mime == .tiff) return if (completed.primary) null else .{ .local_image = completed.epoch };
                self.next_id +%= 1;
                const request = makeRequest(self.next_id, completed.primary, completed.token(), mime);
                self.phase = .{ .read = .{ .epoch = completed.epoch, .id = self.next_id, .mime = mime } };
                return .{ .read = request };
            },
            else => self.phase = .idle,
        }
        return null;
    }

    fn receiveRead(self: *Transaction, allocator: std.mem.Allocator, frame: Frame, epoch: u64) ?Effect {
        const read = &self.phase.read;
        if (epoch != read.epoch) read.discard(allocator);
        if (frame.id) |id| {
            var expected: [20]u8 = undefined;
            if (!eql(id, std.fmt.bufPrint(&expected, "{d}", .{read.id}) catch unreachable)) return null;
        } else if (ignoreOffer(read, frame)) return null;

        if (!frame.valid or frame.password != null) read.discard(allocator);
        switch (frame.status orelse return null) {
            .OK => {
                if (read.started) read.discard(allocator);
                read.started = true;
            },
            .DATA => {
                if (read.discarded) return null;
                if (!read.started or !append(read, allocator, frame)) read.discard(allocator);
            },
            .DONE => {
                defer self.phase = .idle;
                defer read.discard(allocator);
                if (read.discarded or !read.started or read.content.items.len == 0) return null;
                if (read.mime == .text and !std.unicode.utf8ValidateSlice(read.content.items)) return null;
                const bytes = read.content.toOwnedSlice(allocator) catch return null;
                return if (read.mime == .text)
                    .{ .text = .{ .epoch = read.epoch, .bytes = bytes } }
                else
                    .{ .image = .{ .epoch = read.epoch, .bytes = bytes, .mime = read.mime } };
            },
            else => {
                // A failed read sends an error in place of OK, with no DONE.
                if (frame.valid and !read.started) {
                    read.discard(allocator);
                    self.phase = .idle;
                } else {
                    read.discard(allocator);
                }
            },
        }
        return null;
    }
};

/// A password on an untagged OK identifies another unsolicited offer.
/// Untagged traffic without a password has to pass the read's own checks.
fn ignoreOffer(read: *Transaction.Read, frame: Frame) bool {
    if (read.ignoring_offer) {
        if (frame.status == .DONE) read.ignoring_offer = false;
        return true;
    }
    if (frame.valid and frame.status == .OK and frame.password != null) {
        read.ignoring_offer = true;
        return true;
    }
    return false;
}

fn append(read: *Transaction.Read, allocator: std.mem.Allocator, frame: Frame) bool {
    var mime_encoded: [base64.Encoder.calcSize("text/plain".len)]u8 = undefined;
    const expected = base64.Encoder.encode(&mime_encoded, read.mime.mime());
    if (!eql(frame.mime orelse return false, expected)) return false;
    const size = decodedSize(frame.payload, chunk_limit) orelse return false;
    const old_len = read.content.items.len;
    const needed = old_len + size;
    const limit = read.mime.limit();
    if (needed > limit) return false;
    if (needed > read.content.capacity) {
        const capacity = @min(limit, @max(needed, @max(chunk_limit, read.content.capacity * 2)));
        read.content.ensureTotalCapacityPrecise(allocator, capacity) catch return false;
    }
    const dest = read.content.addManyAsSliceAssumeCapacity(size);
    base64.Decoder.decode(dest, frame.payload) catch return false;
    return true;
}

const Status = enum { OK, DATA, DONE, ENOSYS, EPERM, EBUSY, EIO, EINVAL, EFBIG };
const Field = enum { type, status, id, pw, mime, loc };

const Frame = struct {
    is_read: bool = false,
    status: ?Status = null,
    id: ?[]const u8 = null,
    password: ?[]const u8 = null,
    mime: ?[]const u8 = null,
    payload: []const u8 = "",
    primary: bool = false,
    valid: bool = true,

    fn parse(bytes: []const u8) Frame {
        var result: Frame = .{};
        const first = bytes[0..@min(bytes.len, header_limit + 1)];
        const sep = std.mem.indexOfScalar(u8, first, ';');
        const metadata = if (sep) |i| first[0..i] else first;
        if (sep) |i| result.payload = bytes[i + 1 ..];
        result.valid = metadata.len <= header_limit;
        var fields = std.mem.splitScalar(u8, metadata, ':');
        var seen: std.EnumSet(Field) = .{};
        while (fields.next()) |entry| {
            const i = std.mem.indexOfScalar(u8, entry, '=') orelse {
                result.valid = false;
                continue;
            };
            const key = entry[0..i];
            const value = entry[i + 1 ..];
            if (key.len == 0 or !metadataValue(key) or !metadataValue(value)) result.valid = false;
            const field = std.meta.stringToEnum(Field, key) orelse continue;
            if (seen.contains(field)) {
                result.valid = false;
                continue;
            }
            seen.insert(field);
            switch (field) {
                .type => result.is_read = eql(value, "read"),
                .status => result.status = std.meta.stringToEnum(Status, value),
                .id => result.id = value,
                .pw => {
                    result.password = value;
                    if (!validPassword(value)) result.valid = false;
                },
                .mime => result.mime = value,
                .loc => {
                    result.primary = eql(value, "primary");
                    if (!result.primary) result.valid = false;
                },
            }
        }
        const data = result.status == .DATA;
        if (result.status == null or data != (result.mime != null) or (!data and result.payload.len != 0)) {
            result.valid = false;
        }
        return result;
    }
};

fn metadataValue(bytes: []const u8) bool {
    for (bytes) |byte| if (byte < '!' or byte > '~') return false;
    return true;
}

fn validPassword(encoded: []const u8) bool {
    if (encoded.len == 0 or encoded.len > password_limit) return false;
    var decoded: [128]u8 = undefined;
    const bytes = decodeChunk(&decoded, encoded) orelse return false;
    return std.unicode.utf8ValidateSlice(bytes);
}

fn decodedSize(encoded: []const u8, limit: usize) ?usize {
    if (encoded.len > base64.Encoder.calcSize(limit)) return null;
    const size = base64.Decoder.calcSizeForSlice(encoded) catch return null;
    if (size > limit) return null;
    return size;
}

fn decodeChunk(buffer: []u8, encoded: []const u8) ?[]const u8 {
    const size = decodedSize(encoded, buffer.len) orelse return null;
    const dest = buffer[0..size];
    base64.Decoder.decode(dest, encoded) catch return null;
    return dest;
}

fn preferredMime(bytes: []const u8) ?Mime {
    var best: ?Mime = null;
    var tokens = std.mem.tokenizeAny(u8, bytes, " \t\r\n\x0b\x0c");
    while (tokens.next()) |token| {
        for (std.enums.values(Mime)) |mime| {
            if (best != null and @backingInt(mime) >= @backingInt(best.?)) break;
            if (eql(token, mime.mime())) {
                best = mime;
                break;
            }
        }
    }
    return best;
}

fn makeRequest(id: u64, primary: bool, password: []const u8, mime: Mime) Request {
    var request: Request = .{};
    var writer = std.Io.Writer.fixed(&request.buffer);
    writer.print("\x1b]5522;type=read:id={d}", .{id}) catch unreachable;
    if (primary) writer.writeAll(":loc=primary") catch unreachable;
    if (password.len != 0) writer.print(":pw={s}:name=UGFzdGUgZXZlbnQ=", .{password}) catch unreachable;
    var encoded: [base64.Encoder.calcSize("text/plain".len)]u8 = undefined;
    writer.print(";{s}\x1b\\", .{base64.Encoder.encode(&encoded, mime.mime())}) catch unreachable;
    request.len = writer.end;
    return request;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

fn testInput(transaction: *Transaction, epoch: u64, payload: []const u8) !void {
    try testing.expectEqual(null, transaction.receive(testing.allocator, payload, epoch));
}

fn testOffer(transaction: *Transaction, epoch: u64, list: []const u8) !?Effect {
    try testInput(transaction, epoch, "type=read:status=OK");
    try testChunk(transaction, epoch, "type=read:status=DATA:mime=Lg==;", list);
    return transaction.receive(testing.allocator, "type=read:status=DONE", epoch);
}

fn testChunk(transaction: *Transaction, epoch: u64, header: []const u8, data: []const u8) !void {
    var packet: [header_limit + 1 + base64.Encoder.calcSize(chunk_limit + 1)]u8 = undefined;
    @memcpy(packet[0..header.len], header);
    const body = base64.Encoder.encode(packet[header.len..], data);
    try testInput(transaction, epoch, packet[0 .. header.len + body.len]);
}

test "offers prefer PNG, then JPEG, then text; TIFF alone can use the local clipboard" {
    const cases = [_]struct { list: []const u8, type_payload: ?[]const u8 = null, local: bool = false }{
        .{ .list = "text/plain image/jpeg image/tiff image/png\n", .type_payload = "aW1hZ2UvcG5n" },
        .{ .list = "image/png\timage/jpeg", .type_payload = "aW1hZ2UvcG5n" },
        .{ .list = "image/tiff text/plain image/jpeg\r\n", .type_payload = "aW1hZ2UvanBlZw==" },
        .{ .list = "image/tiff text/plain blah\n", .type_payload = "dGV4dC9wbGFpbg==" },
        .{ .list = "text/html image/tiff", .local = true },
        .{ .list = "text/uri-list text/html text/plain-extra" },
        .{ .list = "" },
    };
    for (cases) |case| {
        var transaction: Transaction = .{};
        defer transaction.deinit(testing.allocator);
        const result = try testOffer(&transaction, 17, case.list);
        if (case.type_payload) |encoded| {
            var output: [128]u8 = undefined;
            const expected = try std.fmt.bufPrint(&output, "\x1b]5522;type=read:id=1;{s}\x1b\\", .{encoded});
            try testing.expectEqualStrings(expected, result.?.read.bytes());
        } else if (case.local) {
            try testing.expectEqual(@as(u64, 17), result.?.local_image);
        } else {
            try testing.expectEqual(null, result);
        }
    }
}

test "Ghostty's repeated token and primary location produce the authenticated read" {
    var transaction: Transaction = .{};
    defer transaction.deinit(testing.allocator);
    try testInput(&transaction, 41, "type=read:status=OK:loc=primary:pw=c2VjcmV0NDU2");
    try testChunk(&transaction, 41, "type=read:status=DATA:mime=Lg==:pw=c2VjcmV0NDU2;", "text/html text/plain\n");
    const read = transaction.receive(testing.allocator, "type=read:status=DONE:pw=c2VjcmV0NDU2", 41).?.read;
    try testing.expectEqualStrings("\x1b]5522;type=read:id=1:loc=primary:pw=c2VjcmV0NDU2:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\", read.bytes());
    try testInput(&transaction, 41, "type=read:status=OK:loc=primary");
    try testInput(&transaction, 41, "type=read:status=DATA:mime=dGV4dC9wbGFpbg==;SGVsbG8sIA==");
    try testInput(&transaction, 41, "type=read:status=DATA:mime=dGV4dC9wbGFpbg==;d29ybGQh");
    const text = transaction.receive(testing.allocator, "type=read:status=DONE", 41).?.text;
    defer testing.allocator.free(text.bytes);
    try testing.expectEqual(@as(u64, 41), text.epoch);
    try testing.expectEqualStrings("Hello, world!", text.bytes);
}

test "tagged replies ignore old identifiers and serialize an overlapping offer" {
    var transaction: Transaction = .{};
    defer transaction.deinit(testing.allocator);
    _ = (try testOffer(&transaction, 6, "image/jpeg")).?.read;
    try testInput(&transaction, 6, "type=read:status=OK:id=99");
    try testInput(&transaction, 6, "type=read:status=DATA:id=99:mime=aW1hZ2UvanBlZw==;broken");
    try testInput(&transaction, 6, "type=read:status=DONE:id=99");
    try testInput(&transaction, 6, "type=read:status=OK:id=1");
    try testInput(&transaction, 6, "type=read:status=OK:pw=c2VjcmV0");
    try testChunk(&transaction, 6, "type=read:status=DATA:mime=Lg==;", "text/plain\n");
    try testInput(&transaction, 6, "type=read:status=DONE");
    try testInput(&transaction, 6, "type=read:status=DATA:id=1:mime=aW1hZ2UvanBlZw==;/9j/2Q==");
    const image = transaction.receive(testing.allocator, "type=read:status=DONE:id=1", 6).?.image;
    defer testing.allocator.free(image.bytes);
    try testing.expectEqual(@as(u64, 6), image.epoch);
    try testing.expectEqual(.jpeg, image.mime);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xd8, 0xff, 0xd9 }, image.bytes);
    const request = (try testOffer(&transaction, 7, "image/png")).?.read;
    try testing.expectEqualStrings("\x1b]5522;type=read:id=2;aW1hZ2UvcG5n\x1b\\", request.bytes());
}

test "stale focus, explicit abort and malformed reads drain through their own DONE" {
    const cases = [_]enum { focus, abort, missing_ok, bad_data, bad_mime, bad_utf8, bad_done, unexpected_offer }{
        .focus, .abort, .missing_ok, .bad_data, .bad_mime, .bad_utf8, .bad_done, .unexpected_offer,
    };
    for (cases) |case| {
        var transaction: Transaction = .{};
        defer transaction.deinit(testing.allocator);
        _ = (try testOffer(&transaction, 1, "text/plain")).?.read;
        if (case != .missing_ok) try testInput(&transaction, 1, "type=read:status=OK:id=1");
        switch (case) {
            .abort => {
                try testChunk(&transaction, 1, "type=read:status=DATA:id=1:mime=dGV4dC9wbGFpbg==;", "discarded bytes");
                transaction.abort(testing.allocator);
            },
            .bad_data => try testInput(&transaction, 1, "type=read:status=DATA:id=1:mime=dGV4dC9wbGFpbg==;e!=="),
            .bad_mime => try testInput(&transaction, 1, "type=read:status=DATA:id=1:mime=aW1hZ2UvcG5n;eA=="),
            .bad_utf8 => try testChunk(&transaction, 1, "type=read:status=DATA:id=1:mime=dGV4dC9wbGFpbg==;", "\xff"),
            .unexpected_offer => try testChunk(&transaction, 1, "type=read:status=DATA:mime=Lg==;", "text/plain"),
            else => {},
        }
        try testChunk(&transaction, if (case == .focus) 2 else 1, "type=read:status=DATA:id=1:mime=dGV4dC9wbGFpbg==;", "tail");
        try testInput(&transaction, 1, "type=read:status=DONE:id=99");
        try testInput(&transaction, 1, if (case == .bad_done) "type=read:status=DONE:id=1;bad" else "type=read:status=DONE:id=1");
        const request = (try testOffer(&transaction, 2, "text/plain")).?.read;
        try testing.expectEqualStrings("\x1b]5522;type=read:id=2;dGV4dC9wbGFpbg==\x1b\\", request.bytes());
    }
}

test "invalid and inconsistent offer tokens, unsolicited data and stale offers emit no request" {
    var transaction: Transaction = .{};
    defer transaction.deinit(testing.allocator);
    try testChunk(&transaction, 1, "type=read:status=DATA:mime=Lg==;", "text/plain");
    try testInput(&transaction, 1, "type=read:status=DONE");
    for ([_][]const u8{
        "type=read:status=OK:pw=YWJj\x1b\\",
        "type=read:status=OK:pw=YWJj:pw=YWJj",
        "type=read:status=OK:pw=/w==",
        "type=read:status=OK:pw=YR==",
        "type=read:status=OK:loc=invalid",
        "type=read:status=OK:pw=b3RoZXI=",
    }) |frame| {
        try testInput(&transaction, 1, frame);
        try testChunk(&transaction, 1, "type=read:status=DATA:mime=Lg==:pw=YWJj;", "text/plain");
        try testInput(&transaction, 1, "type=read:status=DONE");
    }
    try testInput(&transaction, 2, "type=read:status=OK");
    try testChunk(&transaction, 2, "type=read:status=DATA:mime=Lg==;", "text/plain");
    try testInput(&transaction, 3, "type=read:status=DONE");
    try testing.expect((try testOffer(&transaction, 3, "text/plain")) != null);
}

test "TIFF from primary selection and an unanswered offer drop without a local effect" {
    var transaction: Transaction = .{};
    defer transaction.deinit(testing.allocator);
    try testInput(&transaction, 1, "type=read:status=OK:loc=primary");
    try testChunk(&transaction, 1, "type=read:status=DATA:mime=Lg==;", "image/tiff");
    try testInput(&transaction, 1, "type=read:status=DONE");
    try testInput(&transaction, 1, "type=read:status=OK");
    transaction.abort(testing.allocator);
    try testChunk(&transaction, 1, "type=read:status=DATA:mime=Lg==;", "image/tiff");
    try testInput(&transaction, 1, "type=read:status=DONE");
}

test "terminal permission refusal releases the read with no requirement for DONE" {
    var transaction: Transaction = .{};
    defer transaction.deinit(testing.allocator);
    _ = (try testOffer(&transaction, 1, "text/plain")).?.read;
    try testInput(&transaction, 1, "type=read:status=EPERM:id=1");
    try testing.expect((try testOffer(&transaction, 1, "text/plain")) != null);
}

test "decoded text and image limits accept exactly the bound and discard one byte over" {
    const cases = [_]struct { mime: []const u8, wire: []const u8, limit: usize }{
        .{ .mime = "text/plain", .wire = "dGV4dC9wbGFpbg==", .limit = 65_537 },
        .{ .mime = "image/png", .wire = "aW1hZ2UvcG5n", .limit = 16 * 1024 * 1024 },
    };
    for (cases) |case| for ([_]bool{ false, true }) |overflow| {
        var transaction: Transaction = .{};
        defer transaction.deinit(testing.allocator);
        _ = (try testOffer(&transaction, 4, case.mime)).?.read;
        try testInput(&transaction, 4, "type=read:status=OK");
        var header: [128]u8 = undefined;
        const frame = try std.fmt.bufPrint(&header, "type=read:status=DATA:mime={s};", .{case.wire});
        const chunk: [chunk_limit]u8 = @splat('z');
        for (0..case.limit / chunk_limit) |_| try testChunk(&transaction, 4, frame, &chunk);
        if (case.limit % chunk_limit != 0) try testChunk(&transaction, 4, frame, chunk[0 .. case.limit % chunk_limit]);
        if (overflow) try testChunk(&transaction, 4, frame, "x");
        const result = transaction.receive(testing.allocator, "type=read:status=DONE", 4);
        if (overflow) {
            try testing.expectEqual(null, result);
        } else {
            const bytes = switch (result.?) {
                .image => |image| image.bytes,
                .text => |text| text.bytes,
                else => return error.UnexpectedEffect,
            };
            defer testing.allocator.free(bytes);
            try testing.expectEqual(case.limit, bytes.len);
            try testing.expectEqual(@as(u8, 'z'), bytes[case.limit - 1]);
        }
        try testing.expect((try testOffer(&transaction, 4, "text/plain")) != null);
    };
}

test "an oversized data frame is refused even when the total fits" {
    var transaction: Transaction = .{};
    defer transaction.deinit(testing.allocator);
    _ = (try testOffer(&transaction, 4, "text/plain")).?.read;
    try testInput(&transaction, 4, "type=read:status=OK");
    const chunk: [chunk_limit + 1]u8 = @splat('z');
    try testChunk(&transaction, 4, "type=read:status=DATA:mime=dGV4dC9wbGFpbg==;", &chunk);
    try testInput(&transaction, 4, "type=read:status=DONE");
}

test "maximum password and identifier fit the read command" {
    var transaction: Transaction = .{ .next_id = std.math.maxInt(u64) - 1 };
    defer transaction.deinit(testing.allocator);
    const password: [128]u8 = @splat('p');
    var encoded: [password_limit]u8 = undefined;
    const token = base64.Encoder.encode(&encoded, &password);
    var ok_frame: [header_limit]u8 = undefined;
    try testInput(&transaction, 7, try std.fmt.bufPrint(&ok_frame, "type=read:status=OK:loc=primary:pw={s}", .{token}));
    try testChunk(&transaction, 7, "type=read:status=DATA:mime=Lg==;", "text/plain");
    const request = transaction.receive(testing.allocator, "type=read:status=DONE", 7).?.read;
    try testing.expect(std.mem.startsWith(u8, request.bytes(), "\x1b]5522;type=read:id=18446744073709551615:loc=primary:pw="));
    try testing.expect(std.mem.endsWith(u8, request.bytes(), ":name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\"));
}

test "pending includes offer and drain; timeout drops stored data and preserves request sequence" {
    var transaction: Transaction = .{};
    defer transaction.deinit(testing.allocator);
    try testing.expect(!transaction.pending());
    try testInput(&transaction, 1, "type=read:status=OK");
    try testing.expect(transaction.pending());
    try testChunk(&transaction, 1, "type=read:status=DATA:mime=Lg==;", "text/plain");
    _ = transaction.receive(testing.allocator, "type=read:status=DONE", 1).?.read;
    try testing.expect(transaction.pending());
    try testInput(&transaction, 1, "type=read:status=OK:id=1");
    try testChunk(&transaction, 1, "type=read:status=DATA:id=1:mime=dGV4dC9wbGFpbg==;", "timed out");
    transaction.abort(testing.allocator);
    try testing.expect(transaction.pending());
    transaction.deinit(testing.allocator);
    try testing.expect(!transaction.pending());
    const read = (try testOffer(&transaction, 2, "text/plain")).?.read;
    try testing.expectEqualStrings("\x1b]5522;type=read:id=2;dGV4dC9wbGFpbg==\x1b\\", read.bytes());
    try testInput(&transaction, 2, "type=read:status=DONE:id=1");
    try testing.expect(transaction.pending());
    try testInput(&transaction, 2, "type=read:status=DONE:id=2");
    try testing.expect(!transaction.pending());
}

test "allocation failure discards the read until its DONE" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    var transaction: Transaction = .{};
    defer transaction.deinit(allocator);
    _ = (try testOffer(&transaction, 1, "text/plain")).?.read;
    try testing.expectEqual(null, transaction.receive(allocator, "type=read:status=OK", 1));
    try testing.expectEqual(null, transaction.receive(allocator, "type=read:status=DATA:mime=dGV4dC9wbGFpbg==;eA==", 1));
    try testing.expect(transaction.pending());
    try testing.expectEqual(null, transaction.receive(allocator, "type=read:status=DONE", 1));
    try testing.expect(!transaction.pending());
}
