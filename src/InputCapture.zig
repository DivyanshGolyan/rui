//! One request's ordered input custody. The caller transfers two empty,
//! unlinked files. Ranges borrow the sealed spool; only this owner closes
//! the descriptors and returns its byte and index charges.
const std = @import("std");
const InputCapture = @This();
const ScratchBudget = @import("ScratchBudget.zig");
const content_string = @import("content_string.zig");
const custody = @import("content_custody.zig");
const parts = @import("input_parts.zig");
const media = @import("input_media.zig");
const Utf8 = @import("utf8_validation.zig").State;

io: std.Io,
resources: ?struct { spool: std.Io.File, index: std.Io.File, budget: ScratchBudget, charged: u64 = 0 },
limits: media.Limits = .{},
length: u64 = 0,
count: u32 = 0,
raw_image_bytes: u64 = 0,
digest: parts.Digest = .init(),
state: enum { building, sealed, failed } = .building,
pending: ?Pending = null,

pub const window_bytes = 2048;

pub const Incoming = union(enum) {
    text,
    image: struct { assertion: ?media.Format = null, name: ?parts.Name = null },
};

const Pending = struct {
    offset: u64,
    length: u64,
    written: u64 = 0,
    hash: std.crypto.hash.sha2.Sha256 = content_string.hasher(),
    kind: union(enum) { text: Utf8, image: struct { scanner: media.Scanner, name: ?parts.Name } },
};

pub fn init(self: *InputCapture, io: std.Io, spool: std.Io.File, index: std.Io.File, budget: ScratchBudget) void {
    self.* = .{ .io = io, .resources = .{ .spool = spool, .index = index, .budget = budget } };
}

pub fn close(self: *InputCapture) void {
    const resources = self.resources orelse return;
    resources.spool.close(self.io);
    resources.index.close(self.io);
    resources.budget.release(resources.charged);
    self.resources = null;
}

pub fn begin(self: *InputCapture, kind: Incoming, length: u64) !void {
    std.debug.assert(self.resources != null and self.state == .building and self.pending == null);
    errdefer self.state = .failed;
    if (length > content_string.max_bytes) return error.ContentTooLarge;
    if (self.count == std.math.maxInt(u32)) return error.TooManyInputParts;
    _ = std.math.add(u64, self.length, length) catch return error.ContentTooLarge;
    const validator: @FieldType(Pending, "kind") = switch (kind) {
        .text => .{ .text = .{} },
        .image => |image| image: {
            const total = std.math.add(u64, self.raw_image_bytes, length) catch return error.ImageResourceLimit;
            if (total > self.limits.max_bytes) return error.ImageResourceLimit;
            break :image .{ .image = .{ .scanner = try .init(length, image.assertion, self.limits), .name = image.name } };
        },
    };
    self.pending = .{ .offset = self.length, .length = length, .kind = validator };
}

/// Appends at most `allowance` bytes. Every reservation remains held even
/// after a partial/failed write, until `close` owns the cleanup.
pub fn append(self: *InputCapture, bytes: []const u8, allowance: *usize, cancelled: bool) !usize {
    std.debug.assert(self.resources != null and self.state == .building);
    errdefer self.state = .failed;
    if (cancelled) return error.Canceled;
    try self.io.checkCancel();
    const pending = if (self.pending) |*pending| pending else return error.NoInputPart;
    const count = @min(bytes.len, allowance.*, window_bytes);
    if (count > pending.length - pending.written) return error.ContentChanged;
    if (count == 0) return 0;
    const selected = bytes[0..count];
    switch (pending.kind) {
        .text => |*text| try text.feed(selected),
        .image => |*image| {
            var scanner_allowance: usize = count;
            const read = try image.scanner.advance(selected, &scanner_allowance);
            std.debug.assert(read == count);
        },
    }
    const resources = &self.resources.?;
    if (!resources.budget.allocate(count)) return error.ScratchCapacityExceeded;
    resources.charged += count;
    try resources.spool.writePositionalAll(self.io, selected, pending.offset + pending.written);
    pending.hash.update(selected);
    pending.written += count;
    self.length += count;
    allowance.* -= count;
    return count;
}

pub fn end(self: *InputCapture) !void {
    std.debug.assert(self.resources != null and self.state == .building);
    errdefer self.state = .failed;
    const pending = if (self.pending) |*pending| pending else return error.NoInputPart;
    if (pending.written != pending.length) return error.ContentChanged;
    const kind: parts.Kind = switch (pending.kind) {
        .text => |*text| if (text.complete()) .text else return error.InvalidUtf8,
        .image => |*image| .{ .image = .{ .media = try image.scanner.finish(), .name = image.name } },
    };
    const record: parts.Record = .{ .offset = pending.offset, .identity = .{ .length = pending.length, .digest = pending.hash.finalResult(), .kind = kind } };
    var bytes: [parts.Record.byte_length]u8 = undefined;
    record.encode(&bytes);
    const resources = &self.resources.?;
    if (!resources.budget.allocate(bytes.len)) return error.ScratchCapacityExceeded;
    resources.charged += bytes.len;
    try resources.index.writePositionalAll(self.io, &bytes, @as(u64, self.count) * parts.Record.byte_length);
    try self.digest.append(&record.identity);
    self.count += 1;
    if (kind == .image) self.raw_image_bytes += pending.length;
    self.pending = null;
}

pub fn seal(self: *InputCapture) !Loan {
    std.debug.assert(self.resources != null and self.state == .building);
    errdefer self.state = .failed;
    if (self.pending != null) return error.IncompleteInput;
    if (self.count == 0) return error.EmptyInput;
    if (try self.resources.?.spool.length(self.io) != self.length or
        try self.resources.?.index.length(self.io) != @as(u64, self.count) * parts.Record.byte_length) return error.ContentChanged;
    const digest = try self.digest.finish();
    var single_text: ?Loan.TextIdentity = null;
    if (self.count == 1) {
        var bytes: [parts.Record.byte_length]u8 = undefined;
        if (try self.resources.?.index.readPositionalAll(self.io, &bytes, 0) != bytes.len) return error.ContentChanged;
        const record = try parts.Record.decode(&bytes);
        var identity = parts.Digest.init();
        try identity.append(&record.identity);
        if (!std.mem.eql(u8, &try identity.finish(), &digest)) return error.ContentChanged;
        if (record.identity.kind == .text) single_text = .{ .length = record.identity.length, .digest = record.identity.digest };
    }
    self.state = .sealed;
    return .{ .capture = self, .digest = digest, .count = self.count, .single_text = single_text };
}

/// Borrowed until the capture closes. Its cursor has fixed-size metadata,
/// regardless of how many image parts the index holds.
pub const Loan = struct {
    capture: *InputCapture,
    digest: [32]u8,
    count: u32,
    /// The exact original Content identity, only for one Text. Message
    /// hashing can preserve v4 without reading files inside a Store hold.
    single_text: ?TextIdentity,

    pub const TextIdentity = struct { length: u64, digest: [32]u8 };

    pub fn cursor(self: Loan) Cursor {
        std.debug.assert(self.capture.resources != null and self.capture.state == .sealed);
        return .{ .loan = self };
    }
};

pub const Part = struct {
    range: custody.Range,
    kind: parts.Kind,
};

pub const Cursor = struct {
    loan: Loan,
    ordinal: u32 = 0,
    offset: u64 = 0,
    digest: parts.Digest = .init(),
    failed: bool = false,

    pub fn next(self: *Cursor) !?Part {
        if (self.failed) return error.ContentChanged;
        errdefer self.failed = true;
        const capture = self.loan.capture;
        std.debug.assert(capture.resources != null and capture.state == .sealed);
        if (self.loan.count != capture.count or self.loan.count == 0) return error.ContentChanged;
        if (self.ordinal == self.loan.count) return null;
        var bytes: [parts.Record.byte_length]u8 = undefined;
        const count = try capture.resources.?.index.readPositionalAll(capture.io, &bytes, @as(u64, self.ordinal) * parts.Record.byte_length);
        if (count != bytes.len) return error.ContentChanged;
        const record = try parts.Record.decode(&bytes);
        if (record.offset != self.offset) return error.ContentChanged;
        self.offset = std.math.add(u64, self.offset, record.identity.length) catch return error.ContentChanged;
        if (self.offset > capture.length) return error.ContentChanged;
        try self.digest.append(&record.identity);
        self.ordinal += 1;
        if (self.ordinal == self.loan.count) {
            if (self.offset != capture.length or !std.mem.eql(u8, &try self.digest.finish(), &self.loan.digest)) return error.ContentChanged;
            if (try capture.resources.?.spool.length(capture.io) != capture.length or
                try capture.resources.?.index.length(capture.io) != @as(u64, self.loan.count) * parts.Record.byte_length) return error.ContentChanged;
            if (self.loan.count == 1 and record.identity.kind == .text) {
                const text = self.loan.single_text orelse return error.ContentChanged;
                if (text.length != record.identity.length or !std.mem.eql(u8, &text.digest, &record.identity.digest)) return error.ContentChanged;
            } else if (self.loan.single_text != null) return error.ContentChanged;
        }
        return .{ .range = .{
            .file = capture.resources.?.spool,
            .offset = record.offset,
            .length = record.identity.length,
            .digest = record.identity.digest,
            .sealed_length = capture.length,
        }, .kind = record.identity.kind };
    }
};

fn testCapture(capture: *InputCapture, dir: std.Io.Dir, budget: ScratchBudget) !void {
    const spool = try dir.createFile(std.testing.io, "spool", .{ .read = true });
    errdefer spool.close(std.testing.io);
    try dir.deleteFile(std.testing.io, "spool");
    const index = try dir.createFile(std.testing.io, "index", .{ .read = true });
    errdefer index.close(std.testing.io);
    try dir.deleteFile(std.testing.io, "index");
    capture.init(std.testing.io, spool, index, budget);
}

test "input capture retains exact ordered ranges with one shared charge owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(17);
    var capture: InputCapture = undefined;
    try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 4096 });
    defer capture.close();
    for ([_][]const u8{ "before", "", "after\xc3\xa9" }) |text| {
        try capture.begin(.text, text.len);
        var at: usize = 0;
        while (at < text.len) {
            var allowance: usize = 1;
            at += try capture.append(text[at..], &allowance, false);
        }
        try capture.end();
    }
    var cursor = (try capture.seal()).cursor();
    for ([_][]const u8{ "before", "", "after\xc3\xa9" }) |expected| {
        const part = (try cursor.next()).?;
        try std.testing.expect(part.kind == .text);
        try std.testing.expectEqual(@as(u64, expected.len), part.range.length);
        var bytes: [32]u8 = undefined;
        const count = try part.range.file.readPositionalAll(std.testing.io, bytes[0..expected.len], part.range.offset);
        try std.testing.expectEqualSlices(u8, expected, bytes[0..count]);
        try std.testing.expectEqual(content_string.digest(expected), part.range.digest);
    }
    try std.testing.expect((try cursor.next()) == null);
    try std.testing.expectEqual(@as(u64, 17 + 13 + 3 * parts.Record.byte_length), used.load(.acquire));
    capture.close();
    capture.close();
    try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
}

test "input capture cancellation and metadata capacity failure release exact charges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..4) |cut| {
        var used = std.atomic.Value(u64).init(23);
        var capture: InputCapture = undefined;
        try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 26 });
        defer capture.close();
        try capture.begin(.text, 3);
        var allowance = cut;
        _ = try capture.append("abc", &allowance, false);
        if (cut != 3) {
            allowance = 1;
            try std.testing.expectError(error.Canceled, capture.append("x", &allowance, true));
        } else try std.testing.expectError(error.ScratchCapacityExceeded, capture.end());
        capture.close();
        try std.testing.expectEqual(@as(u64, 23), used.load(.acquire));
    }
}

test "input capture rejects incomplete text and empty sequences without leaking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var capture: InputCapture = undefined;
    try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 4096 });
    try std.testing.expectError(error.EmptyInput, capture.seal());
    capture.close();
    try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 4096 });
    defer capture.close();
    try capture.begin(.text, 1);
    var allowance: usize = 1;
    _ = try capture.append("\xc3", &allowance, false);
    try std.testing.expectError(error.InvalidUtf8, capture.end());
    capture.close();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "input capture write failure retains the full charge until close" {
    const Probe = struct {
        fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
            return error.NoSpaceLeft;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(41);
    var capture: InputCapture = undefined;
    try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 512 });
    defer capture.close();
    var vtable = std.testing.io.vtable.*;
    vtable.fileWritePositional = Probe.write;
    capture.io.vtable = &vtable;
    try capture.begin(.text, 3);
    var allowance: usize = 3;
    try std.testing.expectError(error.NoSpaceLeft, capture.append("abc", &allowance, false));
    try std.testing.expectEqual(@as(u64, 44), used.load(.acquire));
    capture.close();
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
}

test "input capture metadata grows on disk rather than in per-part arrays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var capture: InputCapture = undefined;
    try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 2048 * parts.Record.byte_length });
    defer capture.close();
    for (0..2048) |_| {
        try capture.begin(.text, 0);
        try capture.end();
    }
    var cursor = (try capture.seal()).cursor();
    var count: usize = 0;
    while (try cursor.next()) |part| {
        try std.testing.expectEqual(@as(u64, 0), part.range.length);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2048), count);
    try std.testing.expectEqual(@as(u64, 2048 * parts.Record.byte_length), used.load(.acquire));
    capture.close();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "input capture preserves image only repeated and interleaved original bytes" {
    const first = @embedFile("testing/fixtures/input-baseline.jpg");
    const second = @embedFile("testing/fixtures/input-progressive.jpg");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_][]const []const u8{
        &.{first},
        &.{ first, first },
        &.{ "before", first, "", second, "after" },
    };
    for (cases) |inputs| {
        var used = std.atomic.Value(u64).init(0);
        var capture: InputCapture = undefined;
        try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 8192 });
        defer capture.close();
        for (inputs) |input| {
            const image = input.len != 0 and input[0] == 0xff;
            try capture.begin(if (image) .{ .image = .{ .assertion = .jpeg, .name = try parts.displayName("unsafe<name>\n.jpg") } } else .text, input.len);
            var at: usize = 0;
            while (at < input.len) {
                var allowance: usize = 7;
                at += try capture.append(input[at..], &allowance, false);
            }
            try capture.end();
        }
        var cursor = (try capture.seal()).cursor();
        for (inputs) |expected| {
            const part = (try cursor.next()).?;
            var actual: [first.len]u8 = undefined;
            const count = try part.range.file.readPositionalAll(std.testing.io, actual[0..expected.len], part.range.offset);
            try std.testing.expectEqualSlices(u8, expected, actual[0..count]);
            if (expected.len != 0 and expected[0] == 0xff) {
                try std.testing.expect(part.kind == .image);
                try std.testing.expectEqual(media.Metadata{ .format = .jpeg, .width = 3, .height = 2 }, part.kind.image.media);
            } else try std.testing.expect(part.kind == .text);
        }
        try std.testing.expect((try cursor.next()) == null);
        capture.close();
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
}

test "input capture resource rejection cannot seal a partial sequence" {
    const fixture = @embedFile("testing/fixtures/input-baseline.jpg");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var capture: InputCapture = undefined;
    try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 8192 });
    defer capture.close();
    capture.limits.max_bytes = fixture.len * 2 - 1;
    try capture.begin(.{ .image = .{} }, fixture.len);
    var allowance: usize = fixture.len;
    _ = try capture.append(fixture, &allowance, false);
    try capture.end();
    try std.testing.expectError(error.ImageResourceLimit, capture.begin(.{ .image = .{} }, fixture.len));
    try std.testing.expectEqual(.failed, capture.state);
    capture.close();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "one captured Text retains exact legacy Content identity including empty bytes" {
    const cases = [_]struct { text: []const u8, digest: []const u8 }{
        .{ .text = "", .digest = "11fba2ec1cfcbd2a4453bc49eb07258f9742a754a795c7c3dba4fd05416f4528" },
        .{ .text = "word\n\x00é", .digest = "495d81e325c75724883b998045cec39f71d4857d852e101a59486ad08fe830bc" },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (cases) |case| {
        var used = std.atomic.Value(u64).init(0);
        var capture: InputCapture = undefined;
        try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 1024 });
        defer capture.close();
        try capture.begin(.text, case.text.len);
        var allowance: usize = case.text.len;
        _ = try capture.append(case.text, &allowance, false);
        try capture.end();
        const loan = try capture.seal();
        try std.testing.expectEqual(@as(u32, 1), loan.count);
        try std.testing.expectEqual(@as(u64, case.text.len), loan.single_text.?.length);
        var digest: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&digest, case.digest);
        try std.testing.expectEqual(digest, loan.single_text.?.digest);
        capture.close();
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
}


test "input cursor verifies its whole certificate before returning the last part" {
    const first = @embedFile("testing/fixtures/input-baseline.jpg");
    const second = @embedFile("testing/fixtures/input-progressive.jpg");
    const Damage = enum { semantic_metadata, short_range, wrong_offset, fewer_parts, more_parts, extra_record, truncated_record, sequence_digest, forged_text_identity };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (std.enums.values(Damage)) |damage| {
        var used = std.atomic.Value(u64).init(53);
        var capture: InputCapture = undefined;
        try testCapture(&capture, tmp.dir, .{ .used = &used, .limit = 8192 });
        defer capture.close();
        for ([_][]const u8{ first, second }) |image| {
            try capture.begin(.{ .image = .{ .assertion = .jpeg } }, image.len);
            var allowance: usize = image.len;
            _ = try capture.append(image, &allowance, false);
            try capture.end();
        }
        var loan = try capture.seal();
        const index = capture.resources.?.index;
        var bytes: [parts.Record.byte_length]u8 = undefined;
        try std.testing.expectEqual(bytes.len, try index.readPositionalAll(std.testing.io, &bytes, parts.Record.byte_length));
        var record = try parts.Record.decode(&bytes);
        switch (damage) {
            .semantic_metadata, .short_range, .wrong_offset => {
                switch (damage) {
                    .semantic_metadata => record.identity.kind.image.media.width += 1,
                    .short_range => record.identity.length -= 1,
                    .wrong_offset => record.offset += 1,
                    else => unreachable,
                }
                record.encode(&bytes);
                try index.writePositionalAll(std.testing.io, &bytes, parts.Record.byte_length);
            },
            .fewer_parts => loan.count -= 1,
            .more_parts => loan.count += 1,
            .extra_record => try index.writePositionalAll(std.testing.io, &bytes, 2 * parts.Record.byte_length),
            .truncated_record => try index.setLength(std.testing.io, 2 * parts.Record.byte_length - 1),
            .sequence_digest => loan.digest[0] ^= 1,
            .forged_text_identity => loan.single_text = .{ .length = first.len + second.len, .digest = loan.digest },
        }
        var cursor = loan.cursor();
        if (damage != .fewer_parts and damage != .more_parts) {
            // A producer may legitimately save this first part in its open
            // transaction. It must not receive a last part and commit.
            try std.testing.expect((try cursor.next()) != null);
        }
        try std.testing.expectError(error.ContentChanged, cursor.next());
        // A caught error cannot turn a failed certificate into an end marker.
        try std.testing.expectError(error.ContentChanged, cursor.next());
        capture.close();
        capture.close();
        try std.testing.expectEqual(@as(u64, 53), used.load(.acquire));
    }
}
