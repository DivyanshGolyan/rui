//! How a parts value reads as text. Parts join with exactly one "\n"; a Text part
//! is its exact bytes; an Image part is `[image N: FORMAT WxH, SIZE]`, where N counts
//! images from 1. The saved name stays in list metadata only: it is user-supplied text.
//! The display length follows from the certified list alone, so a reader can check
//! the bytes it draws against it before reading any part.
const std = @import("std");
const content_value = @import("content_value.zig");
const input_parts = @import("input_parts.zig");
const byte_size = @import("byte_size.zig");

pub const separator = "\n";
pub const first_image = "[Image 1]";
pub const Labels = enum { compact, detailed };

pub const max_placeholder_bytes = "[image ".len + 10 + ": ".len + "JPEG".len + " ".len + 10 + "x".len + 10 + ", ".len + 24 + "]".len;

pub fn placeholder(labels: Labels, number: u32, image: input_parts.Image, bytes: u64, out: *[max_placeholder_bytes]u8) []const u8 {
    if (labels == .compact) {
        if (number == 1) return first_image;
        return std.fmt.bufPrint(out, "[Image {d}]", .{number}) catch unreachable;
    }
    var size: [24]u8 = undefined;
    const format = switch (image.media.format) {
        .png => "PNG",
        .jpeg => "JPEG",
    };
    return std.fmt.bufPrint(out, "[image {d}: {s} {d}x{d}, {s}]", .{ number, format, image.media.width, image.media.height, byte_size.kilobytes(bytes, &size) }) catch unreachable;
}

/// A slice of the display bytes, in display offsets.
pub const Range = struct { start: u64, length: u64 };

/// Exact display length: the Text lengths, the placeholders and one separator between parts.
/// `source.next() !?content_value.Part` yields the certified list in order.
pub fn length(source: anytype, labels: Labels) !u64 {
    var total: u64 = 0;
    var images: u32 = 0;
    var first = true;
    while (try source.next()) |part| {
        if (!first) total = try std.math.add(u64, total, separator.len);
        first = false;
        var buffer: [max_placeholder_bytes]u8 = undefined;
        total = try std.math.add(u64, total, switch (part.kind) {
            .text => part.reference.length,
            .image => |image| placeholder(labels, try nextImage(&images), image, part.reference.length, &buffer).len,
        });
    }
    return total;
}

/// Writes the display bytes, or only those inside `range`, into `sink.feed`.
/// `source.next()` yields the certified list in order, and `source.text(part, start, count, sink)`
/// feeds that slice of one Text part's bytes, returning a non-null `Source.Stop` to end the write.
/// Without a range every Text part is delivered whole, empty ones included; with one, only
/// Text parts that overlap it are read. A sink with an `image(part)` method receives each image
/// the range reaches instead of its placeholder bytes.
pub fn write(source: anytype, labels: Labels, range: ?Range, sink: anytype) !?Stop(@TypeOf(source)) {
    const start = if (range) |value| value.start else 0;
    const end = if (range) |value| try std.math.add(u64, value.start, value.length) else std.math.maxInt(u64);
    var offset: u64 = 0;
    var images: u32 = 0;
    var first = true;
    while (offset < end or range == null) {
        const part = try source.next() orelse break;
        if (!first) {
            try feedOverlap(sink, separator, offset, start, end);
            offset += separator.len;
        }
        first = false;
        switch (part.kind) {
            .text => {
                const after = try std.math.add(u64, offset, part.reference.length);
                const from = @max(offset, start);
                const to = @min(after, end);
                if (range == null or from < to) if (try source.text(part, from - offset, to - from, sink)) |stop| return stop;
                offset = after;
            },
            .image => |image| {
                var buffer: [max_placeholder_bytes]u8 = undefined;
                const text = placeholder(labels, try nextImage(&images), image, part.reference.length, &buffer);
                if (comptime std.meta.hasMethod(@TypeOf(sink), "image")) {
                    if (range == null or (offset < end and offset + text.len > start)) try sink.image(part);
                } else try feedOverlap(sink, text, offset, start, end);
                offset = try std.math.add(u64, offset, text.len);
            },
        }
    }
    return null;
}

fn Stop(comptime Source: type) type {
    return switch (@typeInfo(Source)) {
        .pointer => |pointer| pointer.child.Stop,
        else => Source.Stop,
    };
}

fn nextImage(images: *u32) !u32 {
    images.* = try std.math.add(u32, images.*, 1);
    return images.*;
}

fn feedOverlap(sink: anytype, bytes: []const u8, at: u64, start: u64, end: u64) !void {
    const from = @max(at, start);
    const to = @min(at + bytes.len, end);
    if (from < to) try sink.feed(bytes[@intCast(from - at)..@intCast(to - at)]);
}

const Fixture = struct {
    parts: []const content_value.Part,
    texts: []const []const u8,
    next_index: usize = 0,
    reads: usize = 0,

    pub const Stop = void;

    pub fn next(self: *Fixture) !?content_value.Part {
        if (self.next_index == self.parts.len) return null;
        defer self.next_index += 1;
        return self.parts[self.next_index];
    }

    pub fn text(self: *Fixture, part: content_value.Part, start: u64, count: u64, sink: anytype) !?void {
        self.reads += 1;
        try sink.feed(self.texts[part.ordinal][@intCast(start)..@intCast(start + count)]);
        return null;
    }

    fn restart(self: *Fixture) void {
        self.next_index = 0;
        self.reads = 0;
    }
};

const Format = @FieldType(@FieldType(input_parts.Image, "media"), "format");

fn imagePart(ordinal: u32, format: Format, width: u32, height: u32, name: ?[]const u8, bytes: u64) content_value.Part {
    var saved: ?input_parts.Name = null;
    if (name) |text| {
        saved = .{};
        saved.?.set(text) catch unreachable;
    }
    return .{ .ordinal = ordinal, .kind = .{ .image = .{ .media = .{ .format = format, .width = width, .height = height }, .name = saved } }, .reference = .{ .length = bytes, .digest = @splat(0) } };
}

fn textPart(ordinal: u32, bytes: []const u8) content_value.Part {
    return .{ .ordinal = ordinal, .kind = .text, .reference = .{ .length = bytes.len, .digest = @splat(0) } };
}

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

test "SUI-59 parts display layout" {
    // Placeholders: PNG and JPEG, dimensions 1 and 2^32-1, size boundaries, and a saved
    // name absent, 1 byte or 255 bytes of UTF-8, which never reaches the text.
    const long_name = comptime blk: {
        var name: []const u8 = "a";
        for (0..127) |_| name = name ++ "\u{e9}";
        break :blk name;
    };
    comptime std.debug.assert(long_name.len == input_parts.max_name_bytes);
    const max = std.math.maxInt(u32);
    for ([_]struct { u32, content_value.Part, []const u8 }{
        .{ 1, imagePart(0, .png, 1, 1, null, 999), "[image 1: PNG 1x1, 1.0 KB]" },
        .{ 2, imagePart(0, .jpeg, max, 1, "a", 1000), "[image 2: JPEG 4294967295x1, 1.0 KB]" },
        .{ 3, imagePart(0, .png, 1, max, long_name, 9950), "[image 3: PNG 1x4294967295, 10 KB]" },
        .{ 1500, imagePart(0, .png, 1024, 768, "cat.png", 245_012), "[image 1500: PNG 1024x768, 245 KB]" },
        .{ max, imagePart(0, .jpeg, max, max, long_name, std.math.maxInt(u64)), "[image 4294967295: JPEG 4294967295x4294967295, 18446744073709551 KB]" },
    }) |case| {
        var out: [max_placeholder_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(case[2], placeholder(.detailed, case[0], case[1].kind.image, case[1].reference.length, &out));
    }

    // Every adjacent kind pair, empty Text, a Text ending in "\n" before an image, and a
    // 3-part value. Expected text is written out, not built by the code under test.
    const png = imagePart(0, .png, 2, 3, "shot.png", 1000);
    const jpeg = imagePart(0, .jpeg, 5, 7, null, 9950);
    const Case = struct { parts: []const content_value.Part, texts: []const []const u8, display: []const u8 };
    const cases = [_]Case{
        .{ .parts = &.{textPart(0, "ab")}, .texts = &.{"ab"}, .display = "ab" },
        .{ .parts = &.{textPart(0, "")}, .texts = &.{""}, .display = "" },
        .{ .parts = &.{withOrdinal(png, 0)}, .texts = &.{""}, .display = "[image 1: PNG 2x3, 1.0 KB]" },
        .{ .parts = &.{ textPart(0, "ab"), textPart(1, "cd") }, .texts = &.{ "ab", "cd" }, .display = "ab\ncd" },
        .{ .parts = &.{ textPart(0, ""), textPart(1, "") }, .texts = &.{ "", "" }, .display = "\n" },
        .{ .parts = &.{ textPart(0, "ab\n"), withOrdinal(png, 1) }, .texts = &.{ "ab\n", "" }, .display = "ab\n\n[image 1: PNG 2x3, 1.0 KB]" },
        .{ .parts = &.{ withOrdinal(png, 0), textPart(1, "cd") }, .texts = &.{ "", "cd" }, .display = "[image 1: PNG 2x3, 1.0 KB]\ncd" },
        .{ .parts = &.{ withOrdinal(png, 0), withOrdinal(jpeg, 1) }, .texts = &.{ "", "" }, .display = "[image 1: PNG 2x3, 1.0 KB]\n[image 2: JPEG 5x7, 10 KB]" },
        .{ .parts = &.{ textPart(0, "Describe 雪"), withOrdinal(jpeg, 1), textPart(2, "done") }, .texts = &.{ "Describe 雪", "", "done" }, .display = "Describe 雪\n[image 1: JPEG 5x7, 10 KB]\ndone" },
    };
    for (cases) |case| {
        var source: Fixture = .{ .parts = case.parts, .texts = case.texts };
        try std.testing.expectEqual(@as(u64, case.display.len), try length(&source, .detailed));
        // A whole write reads every Text part once, empty ones included.
        source.restart();
        var whole: Collect = .{};
        try std.testing.expectEqual(@as(?void, null), try write(&source, .detailed, null, &whole));
        try std.testing.expectEqualStrings(case.display, whole.slice());
        var text_parts: usize = 0;
        for (case.parts) |part| text_parts += @intFromBool(part.kind == .text);
        try std.testing.expectEqual(text_parts, source.reads);
        // Every range gives exactly that slice of the display.
        for (0..case.display.len + 1) |start| for (0..case.display.len - start + 1) |count| {
            source.restart();
            var ranged: Collect = .{};
            _ = try write(&source, .detailed, .{ .start = start, .length = count }, &ranged);
            try std.testing.expectEqualStrings(case.display[start..][0..count], ranged.slice());
        };
    }

    // A range inside a placeholder reads no Text part.
    var three: Fixture = .{ .parts = cases[cases.len - 1].parts, .texts = cases[cases.len - 1].texts };
    var inside: Collect = .{};
    _ = try write(&three, .detailed, .{ .start = "Describe 雪\n".len + 1, .length = 5 }, &inside);
    try std.testing.expectEqualStrings("image", inside.slice());
    try std.testing.expectEqual(@as(usize, 0), three.reads);

    // A sink that takes images receives each image the range reaches instead of its placeholder.
    const Pixels = struct {
        text: Collect = .{},
        images: [4]u32 = undefined,
        count: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.text.feed(bytes);
        }
        pub fn image(self: *@This(), part: content_value.Part) !void {
            self.images[self.count] = part.ordinal;
            self.count += 1;
        }
    };
    const mixed = [_]content_value.Part{ textPart(0, "ab"), withOrdinal(png, 1), withOrdinal(jpeg, 2) };
    var source: Fixture = .{ .parts = &mixed, .texts = &.{ "ab", "", "" } };
    var pixels: Pixels = .{};
    _ = try write(&source, .detailed, null, &pixels);
    try std.testing.expectEqualStrings("ab\n\n", pixels.text.slice());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, pixels.images[0..pixels.count]);
    source.restart();
    pixels = .{};
    _ = try write(&source, .detailed, .{ .start = 0, .length = 4 }, &pixels);
    try std.testing.expectEqualStrings("ab\n", pixels.text.slice());
    try std.testing.expectEqualSlices(u32, &.{1}, pixels.images[0..pixels.count]);

    // Lengths a list cannot add up to are refused, not wrapped.
    const huge = [_]content_value.Part{ .{ .ordinal = 0, .kind = .text, .reference = .{ .length = std.math.maxInt(u64), .digest = @splat(0) } }, textPart(1, "") };
    var overflowing: Fixture = .{ .parts = &huge, .texts = &.{ "", "" } };
    try std.testing.expectError(error.Overflow, length(&overflowing, .detailed));
}

fn withOrdinal(part: content_value.Part, ordinal: u32) content_value.Part {
    var copy = part;
    copy.ordinal = ordinal;
    return copy;
}
