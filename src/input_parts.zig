//! Closed ordered input identities and fixed-size spool index records.
//! Producer authority and byte custody remain with their owners.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const media = @import("input_media.zig");

pub const max_name_bytes = 255;
pub const Name = Bounded(max_name_bytes);
pub const Image = struct {
    media: media.Metadata,
    name: ?Name = null,
};
pub const Kind = union(enum) { text, image: Image };
pub const Identity = struct {
    length: u64,
    digest: [32]u8,
    kind: Kind,
};

/// A compound's identity includes boundaries even between adjacent Text
/// parts. A single Text producer uses its existing legacy identity instead.
pub const Digest = struct {
    // Keep the stored state compatible with existing Store scratch alignment;
    // SHA-256 works on an aligned local copy, not an under-aligned pointer.
    hash: std.crypto.hash.sha2.Sha256 align(@alignOf(u64)),
    count: u32 = 0,

    pub fn init() Digest {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        field(&hash, "rui/input-parts/v1");
        return .{ .hash = hash };
    }

    pub fn append(self: *Digest, identity: *const Identity) error{TooManyInputParts}!void {
        self.count = std.math.add(u32, self.count, 1) catch return error.TooManyInputParts;
        var hash = self.hash;
        hash.update(&.{switch (identity.kind) {
            .text => 1,
            .image => 2,
        }});
        number(&hash, identity.length);
        hash.update(&identity.digest);
        switch (identity.kind) {
            .text => {},
            .image => |image| {
                hash.update(&.{@backingInt(image.media.format)});
                number(&hash, image.media.width);
                number(&hash, image.media.height);
                hash.update(&.{@intFromBool(image.name != null)});
                if (image.name) |*name| field(&hash, name.slice());
            },
        }
        self.hash = hash;
    }

    pub fn finish(self: *const Digest) error{EmptyInput}![32]u8 {
        if (self.count == 0) return error.EmptyInput;
        var hash = self.hash;
        number(&hash, self.count);
        return hash.finalResult();
    }
};

fn number(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    hash.update(&bytes);
}

fn field(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    number(hash, value.len);
    hash.update(value);
}

pub fn displayName(bytes: []const u8) error{InvalidImageName}!Name {
    if (bytes.len == 0 or bytes.len > max_name_bytes or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidImageName;
    var name: Name = .{};
    name.set(bytes) catch return error.InvalidImageName;
    return name;
}

/// One spool index record. Its fixed size is charged on disk, not multiplied
/// into the request's stack or heap. It is private scratch, not a Store ABI.
pub const Record = struct {
    offset: u64,
    identity: Identity,

    pub const byte_length = 320;

    pub fn encode(self: *const Record, out: *[byte_length]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u64, out[0..8], self.offset, .big);
        std.mem.writeInt(u64, out[8..16], self.identity.length, .big);
        @memcpy(out[16..48], &self.identity.digest);
        switch (self.identity.kind) {
            .text => out[48] = 1,
            .image => |*image| {
                out[48] = 2;
                out[49] = @backingInt(image.media.format);
                std.mem.writeInt(u32, out[50..54], image.media.width, .big);
                std.mem.writeInt(u32, out[54..58], image.media.height, .big);
                if (image.name) |*name| {
                    std.mem.writeInt(u16, out[58..60], @intCast(name.len + 1), .big);
                    @memcpy(out[60..][0..name.len], name.slice());
                }
            },
        }
    }

    pub fn decode(bytes: *const [byte_length]u8) error{InvalidInputIndex}!Record {
        var record: Record = .{
            .offset = std.mem.readInt(u64, bytes[0..8], .big),
            .identity = .{ .length = std.mem.readInt(u64, bytes[8..16], .big), .digest = bytes[16..48].*, .kind = .text },
        };
        if (record.identity.length > @import("content_string.zig").max_bytes) return error.InvalidInputIndex;
        _ = std.math.add(u64, record.offset, record.identity.length) catch return error.InvalidInputIndex;
        switch (bytes[48]) {
            1 => if (!std.mem.allEqual(u8, bytes[49..], 0)) return error.InvalidInputIndex,
            2 => {
                const format = std.enums.fromInt(media.Format, bytes[49]) orelse return error.InvalidInputIndex;
                const width = std.mem.readInt(u32, bytes[50..54], .big);
                const height = std.mem.readInt(u32, bytes[54..58], .big);
                if (width == 0 or height == 0) return error.InvalidInputIndex;
                const name_length = std.mem.readInt(u16, bytes[58..60], .big);
                if (name_length > max_name_bytes + 1 or name_length == 1) return error.InvalidInputIndex;
                const actual = name_length -| 1;
                const name = if (name_length == 0) null else displayName(bytes[60..][0..actual]) catch return error.InvalidInputIndex;
                if (!std.mem.allEqual(u8, bytes[60 + actual ..], 0)) return error.InvalidInputIndex;
                record.identity.kind = .{ .image = .{ .media = .{ .format = format, .width = width, .height = height }, .name = name } };
            },
            else => return error.InvalidInputIndex,
        }
        return record;
    }
};

test "ordered input identity distinguishes order boundaries kind and semantic image metadata" {
    const text: Identity = .{ .length = 1, .digest = @import("content_string.zig").digest("x"), .kind = .text };
    const image: Identity = .{ .length = 1, .digest = text.digest, .kind = .{ .image = .{ .media = .{ .format = .png, .width = 1, .height = 2 } } } };
    var a = Digest.init();
    try a.append(&text);
    try a.append(&image);
    var b = Digest.init();
    try b.append(&image);
    try b.append(&text);
    try std.testing.expect(!std.mem.eql(u8, &try a.finish(), &try b.finish()));
    b = Digest.init();
    try b.append(&text);
    try b.append(&text);
    try std.testing.expect(!std.mem.eql(u8, &try a.finish(), &try b.finish()));
    var named = image;
    named.kind.image.name = try displayName("a\"b.png");
    b = Digest.init();
    try b.append(&text);
    try b.append(&named);
    try std.testing.expect(!std.mem.eql(u8, &try a.finish(), &try b.finish()));
    b = Digest.init();
    try b.append(&text);
    try b.append(&image);
    try std.testing.expectEqual(try a.finish(), try b.finish());
}

test "ordered input digest preserves independent identities at eight-byte but not sixteen-byte alignment" {
    const Placement = struct {
        anchor: u64 align(16) = 0,
        digest: Digest,
    };
    comptime {
        std.debug.assert(@alignOf(Digest) == @alignOf(u64));
        std.debug.assert(@offsetOf(Placement, "digest") % 16 == 8);
    }
    var placed: Placement = .{ .digest = Digest.init() };
    try std.testing.expectEqual(@as(usize, 8), @intFromPtr(&placed.digest) % 16);
    const text: Identity = .{ .length = 1, .digest = @import("content_string.zig").digest("x"), .kind = .text };
    const image: Identity = .{ .length = 1, .digest = text.digest, .kind = .{ .image = .{ .media = .{ .format = .png, .width = 1, .height = 2 } } } };
    var named = image;
    named.kind.image.name = try displayName("a\"b.png");
    // Independent Python hashlib/struct encoding of the existing domains,
    // tags, big-endian numbers, raw Content digest and sequence boundaries.
    const cases = [_]struct { values: [2]Identity, hex: []const u8 }{
        .{ .values = .{ text, image }, .hex = "7ffd3d1468a23bdb5f42390451224e4f08988376a5675e773c181ce28a6fc8ca" },
        .{ .values = .{ image, text }, .hex = "4f3e959b006b41fbe27259e32778ee280aadad79a18e63a0af745bf3ceac03a2" },
        .{ .values = .{ text, text }, .hex = "01c4b6df7b4430e77e0587d1ec2b10a8b63d4a90e8385b2fde8d57b9b0d9b549" },
        .{ .values = .{ text, named }, .hex = "f905b06a8b01dedde2f2ed78c68f6d9328a9ca69546d3adddd728a78805548cd" },
    };
    for (cases) |case| {
        placed.digest = Digest.init();
        for (case.values) |value| try placed.digest.append(&value);
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case.hex);
        try std.testing.expectEqual(expected, try placed.digest.finish());
        // Finishing is observational: later reads retain the same identity.
        try std.testing.expectEqual(expected, try placed.digest.finish());
    }
}

test "input spool record preserves exact text and image identities without normalization" {
    for ([_]Kind{ .text, .{ .image = .{ .media = .{ .format = .jpeg, .width = 42, .height = 73 }, .name = try displayName("<unsafe>\n.jpg") } } }) |kind| {
        const expected: Record = .{ .offset = 99, .identity = .{ .length = 0, .digest = @import("content_string.zig").digest(""), .kind = kind } };
        var bytes: [Record.byte_length]u8 = undefined;
        expected.encode(&bytes);
        const actual = try Record.decode(&bytes);
        try std.testing.expectEqual(expected.offset, actual.offset);
        try std.testing.expectEqual(expected.identity.length, actual.identity.length);
        var original_digest = Digest.init();
        var decoded_digest = Digest.init();
        try original_digest.append(&expected.identity);
        try decoded_digest.append(&actual.identity);
        try std.testing.expectEqual(try original_digest.finish(), try decoded_digest.finish());
        bytes[319] = 1;
        try std.testing.expectError(error.InvalidInputIndex, Record.decode(&bytes));
    }
    const empty = Digest.init();
    try std.testing.expectError(error.EmptyInput, empty.finish());
    try std.testing.expectError(error.InvalidImageName, displayName("\xff"));
}
