const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const media = @import("input_media.zig");

/// The stored representation of a Content value. The domain is part of the
/// identity, so a manifest cannot be read as ordinary content bytes.
pub const Form = enum(u8) {
    bytes = 0,
    parts = 1,

    pub fn hasher(self: Form) std.crypto.hash.sha2.Sha256 {
        return switch (self) {
            .bytes => @import("content_string.zig").hasher(),
            .parts => Digest.init().hash,
        };
    }

    pub fn decode(value: u64) error{CorruptStore}!Form {
        return switch (value) {
            0 => .bytes,
            1 => .parts,
            else => error.CorruptStore,
        };
    }
};

pub const ContentReference = struct { length: u64, digest: [32]u8 };

pub const Reference = union(Form) {
    bytes: ContentReference,
    parts: ContentReference,

    pub fn identity(self: Reference) ContentReference {
        return switch (self) {
            inline else => |value| value,
        };
    }
};

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

pub const Digest = struct {
    hash: std.crypto.hash.sha2.Sha256 align(@alignOf(u64)),
    count: u32 = 0,

    pub fn init() Digest {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        field(&hash, "rui/input-parts/v1");
        return .{ .hash = hash };
    }

    pub fn append(self: *Digest, identity: *const Identity) error{TooManyInputParts}!void {
        var entry: [Manifest.max_entry_bytes]u8 = undefined;
        try self.appendEncoded(encodeEntry(identity, &entry));
    }

    fn appendEncoded(self: *Digest, entry: []const u8) error{TooManyInputParts}!void {
        self.count = std.math.add(u32, self.count, 1) catch return error.TooManyInputParts;
        var hash = self.hash;
        hash.update(entry);
        self.hash = hash;
    }

    pub fn finish(self: *const Digest) error{EmptyInput}![32]u8 {
        if (self.count == 0) return error.EmptyInput;
        var hash = self.hash;
        number(&hash, self.count);
        return hash.finalResult();
    }
};

pub const max_parts = 1500;

pub const Manifest = struct {
    pub const max_entry_bytes = 1 + 8 + 32 + 1 + 8 + 8 + 1 + 8 + max_name_bytes;
    pub const trailer_bytes = 8;

    /// Incrementally decodes entries, keeping only a split entry in memory.
    /// The caller supplies the final eight-byte count separately to finish.
    pub const Decoder = struct {
        remaining: u64,
        count: u32 = 0,
        first_text: bool = false,
        partial: [max_entry_bytes]u8 = undefined,
        partial_length: usize = 0,

        fn needed(self: *const Decoder) error{CorruptStore}!usize {
            const n = self.partial_length;
            if (n == 0) return 1;
            const tag = self.partial[0];
            if (tag != 1 and tag != 2) return error.CorruptStore;
            if (n < 41 or tag == 1) return 41;
            if (n < 59) return 59;
            const named = self.partial[58];
            if (named == 0) return 59;
            if (named != 1) return error.CorruptStore;
            if (n < 67) return 67;
            const length = std.mem.readInt(u64, self.partial[59..67], .big);
            if (length == 0 or length > max_name_bytes) return error.CorruptStore;
            return 67 + @as(usize, @intCast(length));
        }

        pub fn next(self: *Decoder, window: []const u8, consumed: *usize) error{CorruptStore}!?Identity {
            if (consumed.* > window.len or self.remaining < trailer_bytes) return error.CorruptStore;
            while (true) {
                const need = try self.needed();
                if (self.partial_length == need and need > 1) {
                    const b = &self.partial;
                    var result: Identity = .{
                        .length = std.mem.readInt(u64, b[1..9], .big),
                        .digest = b[9..41].*,
                        .kind = .text,
                    };
                    if (result.length > @import("content_string.zig").max_bytes) return error.CorruptStore;
                    if (b[0] == 2) {
                        const format = std.enums.fromInt(media.Format, b[41]) orelse return error.CorruptStore;
                        const width = std.mem.readInt(u64, b[42..50], .big);
                        const height = std.mem.readInt(u64, b[50..58], .big);
                        if (width == 0 or width > std.math.maxInt(u32) or height == 0 or height > std.math.maxInt(u32)) return error.CorruptStore;
                        const name = if (b[58] == 0) null else displayName(b[67..need]) catch return error.CorruptStore;
                        result.kind = .{ .image = .{ .media = .{ .format = format, .width = @intCast(width), .height = @intCast(height) }, .name = name } };
                    }
                    if (self.count >= max_parts) return error.CorruptStore;
                    if (self.count == 0) self.first_text = result.kind == .text;
                    self.count += 1;
                    self.partial_length = 0;
                    return result;
                }
                if (self.remaining == trailer_bytes) {
                    if (self.partial_length != 0) return error.CorruptStore;
                    return null;
                }
                if (consumed.* == window.len) return null;
                const available: usize = @intCast(@min(self.remaining - trailer_bytes, window.len - consumed.*));
                const take = @min(need - self.partial_length, available);
                @memcpy(self.partial[self.partial_length..][0..take], window[consumed.*..][0..take]);
                self.partial_length += take;
                consumed.* += take;
                self.remaining -= take;
            }
        }

        pub fn finish(self: *Decoder, trailer: *const [trailer_bytes]u8) error{CorruptStore}!u32 {
            if (self.remaining != trailer_bytes or self.partial_length != 0 or self.count == 0 or
                (self.count == 1 and self.first_text) or std.mem.readInt(u64, trailer, .big) != self.count) return error.CorruptStore;
            self.remaining = 0;
            return self.count;
        }
    };

    pub const Encoder = struct {
        digest: Digest = .init(),
        length: u64 = trailer_bytes,
        single_text: ?ContentReference = null,

        pub fn append(self: *Encoder, part: *const Identity, out: *[max_entry_bytes]u8) error{TooManyInputParts}![]const u8 {
            if (self.digest.count >= max_parts) return error.TooManyInputParts;
            const entry = encodeEntry(part, out);
            if (self.digest.count == 0 and part.kind == .text)
                self.single_text = .{ .length = part.length, .digest = part.digest };
            try self.digest.appendEncoded(entry);
            self.length += entry.len;
            return entry;
        }

        pub fn finish(self: *const Encoder) error{EmptyInput}!Reference {
            const digest = try self.digest.finish();
            if (self.digest.count == 1) if (self.single_text) |text| return .{ .bytes = text };
            return .{ .parts = .{ .length = self.length, .digest = digest } };
        }
    };
};

/// The entry is the single byte representation used for both stored manifests
/// and ordered-input digests. The caller owns the bounded output buffer.
fn encodeEntry(part: *const Identity, out: *[Manifest.max_entry_bytes]u8) []const u8 {
    var pos: usize = 0;
    out[pos] = switch (part.kind) {
        .text => 1,
        .image => 2,
    };
    pos += 1;
    std.mem.writeInt(u64, out[pos..][0..8], part.length, .big);
    pos += 8;
    @memcpy(out[pos..][0..32], &part.digest);
    pos += 32;
    switch (part.kind) {
        .text => {},
        .image => |image| {
            out[pos] = @backingInt(image.media.format);
            pos += 1;
            std.mem.writeInt(u64, out[pos..][0..8], image.media.width, .big);
            pos += 8;
            std.mem.writeInt(u64, out[pos..][0..8], image.media.height, .big);
            pos += 8;
            out[pos] = @intFromBool(image.name != null);
            pos += 1;
            if (image.name) |name| {
                std.mem.writeInt(u64, out[pos..][0..8], name.len, .big);
                pos += 8;
                @memcpy(out[pos..][0..name.len], name.slice());
                pos += name.len;
            }
        },
    }
    return out[0..pos];
}

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

test "manifest encoding uses the ordered input digest and canonical text reference" {
    const text: Identity = .{ .length = 1, .digest = @import("content_string.zig").digest("x"), .kind = .text };
    const image: Identity = .{ .length = 1, .digest = text.digest, .kind = .{ .image = .{ .media = .{ .format = .png, .width = 1, .height = 2 } } } };
    var encoder: Manifest.Encoder = .{};
    var entry: [Manifest.max_entry_bytes]u8 = undefined;
    var hash = Form.parts.hasher();
    const first = try encoder.append(&text, &entry);
    hash.update(first);
    const reference = try encoder.finish();
    try std.testing.expect(reference == .bytes);
    try std.testing.expectEqual(text.digest, reference.bytes.digest);
    const second = try encoder.append(&image, &entry);
    hash.update(second);
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u64, &trailer, 2, .big);
    hash.update(&trailer);
    const compound = try encoder.finish();
    try std.testing.expect(compound == .parts);
    try std.testing.expectEqual(hash.finalResult(), compound.parts.digest);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "7ffd3d1468a23bdb5f42390451224e4f08988376a5675e773c181ce28a6fc8ca");
    try std.testing.expectEqual(expected, compound.parts.digest);
    try std.testing.expectEqual(@as(u64, first.len + second.len + trailer.len), compound.parts.length);
    try std.testing.expectError(error.CorruptStore, Form.decode(2));
}

test "manifest encoder matches every ordered input digest vector" {
    const text: Identity = .{ .length = 1, .digest = @import("content_string.zig").digest("x"), .kind = .text };
    const image: Identity = .{ .length = 1, .digest = text.digest, .kind = .{ .image = .{ .media = .{ .format = .png, .width = 1, .height = 2 } } } };
    var named = image;
    named.kind.image.name = try displayName("a\"b.png");
    const cases = [_]struct { values: [2]Identity, hex: []const u8 }{
        .{ .values = .{ text, image }, .hex = "7ffd3d1468a23bdb5f42390451224e4f08988376a5675e773c181ce28a6fc8ca" },
        .{ .values = .{ image, text }, .hex = "4f3e959b006b41fbe27259e32778ee280aadad79a18e63a0af745bf3ceac03a2" },
        .{ .values = .{ text, text }, .hex = "01c4b6df7b4430e77e0587d1ec2b10a8b63d4a90e8385b2fde8d57b9b0d9b549" },
        .{ .values = .{ text, named }, .hex = "f905b06a8b01dedde2f2ed78c68f6d9328a9ca69546d3adddd728a78805548cd" },
    };
    for (cases) |case| {
        var encoder: Manifest.Encoder = .{};
        var bytes: [Manifest.max_entry_bytes]u8 = undefined;
        for (case.values) |part| _ = try encoder.append(&part, &bytes);
        const encoded = try encoder.finish();
        try std.testing.expect(encoded == .parts);
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case.hex);
        try std.testing.expectEqual(expected, encoded.parts.digest);
    }
}

test "manifest entry bytes feed both digest consumers for text and image variants" {
    const text_digest = @import("content_string.zig").digest("x");
    const named = try displayName("a\"b.jpeg");
    const variants = [_]Identity{
        .{ .length = 1, .digest = text_digest, .kind = .text },
        .{ .length = 1, .digest = text_digest, .kind = .{ .image = .{ .media = .{ .format = .png, .width = 1, .height = 2 } } } },
        .{ .length = 1, .digest = text_digest, .kind = .{ .image = .{ .media = .{ .format = .jpeg, .width = 42, .height = 73 }, .name = named } } },
    };
    for (variants) |variant| {
        var digest = Digest.init();
        var encoder: Manifest.Encoder = .{};
        var entry: [Manifest.max_entry_bytes]u8 = undefined;
        var bytes_hash = Form.parts.hasher();
        try digest.append(&variant);
        bytes_hash.update(try encoder.append(&variant, &entry));
        var trailer: [Manifest.trailer_bytes]u8 = undefined;
        std.mem.writeInt(u64, &trailer, 1, .big);
        bytes_hash.update(&trailer);
        try std.testing.expectEqual(try digest.finish(), bytes_hash.finalResult());
        try std.testing.expectEqual(try digest.finish(), try encoder.digest.finish());
    }
}

test "manifest decoder rejects one text and accepts split entries" {
    const text: Identity = .{ .length = 1, .digest = @import("content_string.zig").digest("x"), .kind = .text };
    var encoder: Manifest.Encoder = .{};
    var entry: [Manifest.max_entry_bytes]u8 = undefined;
    const bytes = try encoder.append(&text, &entry);
    var decoder: Manifest.Decoder = .{ .remaining = bytes.len + Manifest.trailer_bytes };
    var count: usize = 0;
    try std.testing.expect((try decoder.next(bytes[0..3], &count)) == null);
    count = 0;
    const decoded = (try decoder.next(bytes[3..], &count)).?;
    try std.testing.expect(decoded.kind == .text);
    try std.testing.expectEqual(text.digest, decoded.digest);
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u64, &trailer, 1, .big);
    try std.testing.expectError(error.CorruptStore, decoder.finish(&trailer));
}

test "manifest encoder enforces the part cap without truncating" {
    const text: Identity = .{ .length = 1, .digest = @import("content_string.zig").digest("x"), .kind = .text };
    var encoder: Manifest.Encoder = .{};
    var entry: [Manifest.max_entry_bytes]u8 = undefined;
    for (0..max_parts) |_| _ = try encoder.append(&text, &entry);
    try std.testing.expectError(error.TooManyInputParts, encoder.append(&text, &entry));
    try std.testing.expectEqual(@as(u32, max_parts), encoder.digest.count);
}
