const std = @import("std");
const document = @import("document.zig");
const json = @import("../codecs/json.zig");

pub const Image = struct { data: []const u8, mime: []const u8 };
pub const Block = union(enum) {
    text: []const u8,
    image: Image,
    bad_image: []const u8,
    other: []const u8,
};

/// Input is a value from a checked JSON document. String contents remain escaped.
pub fn classify(block: []const u8) Block {
    if (document.kind(block) != .object) return .{ .other = block };
    const kind = document.member(block, "type") orelse return .{ .other = block };
    if (document.kind(kind) != .string) return .{ .other = block };
    const tag = document.contents(kind);
    if (document.keyIs(tag, "image")) {
        const data = document.member(block, "data") orelse return .{ .bad_image = "missing image data" };
        const mime = document.member(block, "mimeType") orelse return .{ .bad_image = "missing image MIME type" };
        if (document.kind(data) != .string) return .{ .bad_image = "image data is not a string" };
        if (document.kind(mime) != .string) return .{ .bad_image = "image MIME type is not a string" };
        return .{ .image = .{ .data = document.contents(data), .mime = document.contents(mime) } };
    }
    if (document.keyIs(tag, "text")) {
        const text = document.member(block, "text") orelse return .{ .other = block };
        if (document.kind(text) == .string) return .{ .text = document.contents(text) };
    }
    return .{ .other = block };
}

/// Decodes JSON string contents and standard padded base64 in bounded windows.
/// A nonempty window is required; an empty returned slice means end of input.
pub const Decoder = struct {
    data: []const u8,
    at: usize = 0,
    pending: [3]u8 = undefined,
    pending_at: usize = 0,
    pending_len: usize = 0,
    ended: bool = false,

    pub fn init(data: []const u8) Decoder {
        return .{ .data = data };
    }

    pub fn next(self: *Decoder, window: []u8) error{InvalidBase64}![]const u8 {
        std.debug.assert(window.len > 0);
        var count: usize = 0;
        while (count < window.len) {
            if (self.pending_at < self.pending_len) {
                window[count] = self.pending[self.pending_at];
                count += 1;
                self.pending_at += 1;
                continue;
            }
            if (self.ended) break;
            if (self.at == self.data.len) {
                self.ended = true;
                break;
            }
            var group: [4]u8 = undefined;
            for (&group) |*byte| byte.* = (try self.character()) orelse return error.InvalidBase64;
            const size = std.base64.standard.Decoder.calcSizeForSlice(&group) catch return error.InvalidBase64;
            std.base64.standard.Decoder.decode(self.pending[0..size], &group) catch return error.InvalidBase64;
            if (size < 3 and self.at != self.data.len) return error.InvalidBase64;
            self.pending_at = 0;
            self.pending_len = size;
            if (size < 3) self.ended = true;
        }
        return window[0..count];
    }

    fn character(self: *Decoder) error{InvalidBase64}!?u8 {
        if (self.at == self.data.len) return null;
        const start = self.at;
        if (self.data[start] != '\\') {
            self.at += 1;
            return self.data[start];
        }
        if (start + 1 >= self.data.len) return error.InvalidBase64;
        const end = if (self.data[start + 1] == 'u') start + 6 else start + 2;
        if (end > self.data.len) return error.InvalidBase64;
        var sink: One = .{};
        _ = json.decodeString(self.data[start..end], 0, &sink) catch return error.InvalidBase64;
        self.at = end;
        if (sink.len != 1) return error.InvalidBase64;
        return sink.byte;
    }
};

const One = struct {
    byte: u8 = 0,
    len: usize = 0,
    pub fn append(self: *One, bytes: []const u8, _: ?u21) void {
        self.len += bytes.len;
        if (bytes.len == 1) self.byte = bytes[0];
    }
};

test "result parts classify image typed blocks without leaking malformed images" {
    const cases = [_]struct { value: []const u8, tag: std.meta.Tag(Block) }{
        .{ .value = "{\"type\":\"text\",\"text\":\"a\\nb\"}", .tag = .text },
        .{ .value = "{\"type\":\"im\\u0061ge\",\"data\":\"YQ==\",\"mimeType\":\"image/png\"}", .tag = .image },
        .{ .value = "{\"type\":\"image\"}", .tag = .bad_image },
        .{ .value = "{\"type\":\"image\",\"data\":42,\"mimeType\":\"image/png\"}", .tag = .bad_image },
        .{ .value = "{\"type\":\"image\",\"data\":\"x\",\"mimeType\":null}", .tag = .bad_image },
        .{ .value = "{\"type\":\"text\",\"text\":4}", .tag = .other },
        .{ .value = "{\"type\":\"audio\"}", .tag = .other },
        .{ .value = "4", .tag = .other },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.tag, std.meta.activeTag(classify(case.value)));
    }
    try std.testing.expectEqualStrings("a\\nb", classify(cases[0].value).text);
}

test "result parts base64 decoder matches standard at every window size" {
    var random_state: u32 = 12345;
    var input: [128]u8 = undefined;
    var encoded: [172]u8 = undefined;
    var expected: [128]u8 = undefined;
    var actual: [128]u8 = undefined;
    for (0..input.len + 1) |len| {
        for (input[0..len]) |*byte| {
            random_state ^= random_state << 13;
            random_state ^= random_state >> 17;
            random_state ^= random_state << 5;
            byte.* = @truncate(random_state);
        }
        const data = std.base64.standard.Encoder.encode(&encoded, input[0..len]);
        const size = try std.base64.standard.Decoder.calcSizeForSlice(data);
        try std.base64.standard.Decoder.decode(expected[0..size], data);
        for (1..input.len + 2) |width| {
            var decoder = Decoder.init(data);
            var window: [129]u8 = undefined;
            var at: usize = 0;
            while (true) {
                const part = try decoder.next(window[0..width]);
                if (part.len == 0) break;
                @memcpy(actual[at..][0..part.len], part);
                at += part.len;
            }
            try std.testing.expectEqualSlices(u8, expected[0..size], actual[0..at]);
        }
    }
    var escaped = Decoder.init("\\u0059Q==");
    var escaped_window: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a", try escaped.next(&escaped_window));
    for ([_][]const u8{ "A", "AAA", "A===", "====", "AA=A", "AA==AAAA", "!!!!", "AB==", "AAA=AAAA", "YQ=\\u003dA" }) |bad| {
        var decoder = Decoder.init(bad);
        try std.testing.expectError(error.InvalidBase64, decoder.next(&actual));
    }
}
