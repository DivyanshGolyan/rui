//! Frontend-only tool references and bounded, terminal-safe output rows.
//! Closed rows retain an identity, never their output. The existing document's
//! hidden OSC 8 address representation carries these line-level markers.
const std = @import("std");
const Text = @import("TerminalText.zig");
const protocol = @import("protocol.zig");

pub const Reference = struct {
    source: enum { activity, conversation },
    position: u64,
    ordinal: u64,
    content: protocol.ActivityItem.Content,
};
pub const prefix = "rui-tool:";
pub const output_uri = "rui-tool-output";
pub const more_uri = "rui-tool-more";
pub const output_marker = Text.link_open ++ output_uri ++ Text.link_end ++ Text.link_close;
pub const more_marker = Text.link_open ++ more_uri ++ Text.link_end ++ Text.link_close;
pub const max_lines = 20;
pub const max_bytes = 8192;

pub fn marker(reference: Reference, sink: anytype) !void {
    var buffer: [192]u8 = undefined;
    const digest = std.fmt.bytesToHex(reference.content.digest, .lower);
    const uri = try std.fmt.bufPrint(&buffer, prefix ++ "{s}:{d}:{d}:{d}:{s}", .{ if (reference.source == .activity) "a" else "c", reference.position, reference.ordinal, reference.content.length, digest });
    try sink.feed(Text.link_open);
    try sink.feed(uri);
    try sink.feed(Text.link_end ++ Text.link_close);
}

pub fn parse(uri: []const u8) ?Reference {
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var parts = std.mem.splitScalar(u8, uri[prefix.len..], ':');
    const source = parts.next() orelse return null;
    const position = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const ordinal = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const length = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const hex = parts.next() orelse return null;
    if (hex.len != 64 or parts.next() != null) return null;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return null;
    return .{ .source = if (std.mem.eql(u8, source, "a")) .activity else if (std.mem.eql(u8, source, "c")) .conversation else return null, .position = position, .ordinal = ordinal, .content = .{ .length = length, .digest = digest } };
}

/// One toggle's temporary owner. Reads authenticate the whole Store content,
/// but keep only the first bounded prefix and count the remaining lines. The
/// reader allocates this in place and releases it after staging the rows.
pub const Output = struct {
    raw: [max_bytes]u8 = undefined,
    escaped: [max_bytes]u8 = undefined,
    length: usize = 0,
    received: u64 = 0,
    newlines: u64 = 0,
    last: u8 = '\n',

    pub fn feed(self: *Output, bytes: []const u8) !void {
        const count = @min(bytes.len, self.raw.len - self.length);
        @memcpy(self.raw[self.length..][0..count], bytes[0..count]);
        self.length += count;
        self.received += bytes.len;
        self.newlines += std.mem.count(u8, bytes, "\n");
        if (bytes.len != 0) self.last = bytes[bytes.len - 1];
    }

    pub fn finish(self: *Output, sink: anytype) !void {
        const total = self.newlines + @intFromBool(self.last != '\n');
        if (total == 0) return sink.feed(more_marker ++ "    (no output)\n");
        var at: usize = 0;
        var shown: u64 = 0;
        var budget: usize = max_bytes;
        while (at < self.length and shown < max_lines) {
            const end = std.mem.indexOfScalarPos(u8, self.raw[0..self.length], at, '\n') orelse self.length;
            // A prefix cut within a line has no complete line to present.
            if (end == self.length and self.received > self.length) break;
            var writer = std.Io.Writer.fixed(self.escaped[0..budget]);
            var text: Text = .{ .mode = .multiline };
            // The fixed writer can fail only on the display budget. Count
            // that whole incomplete line among the quiet omitted lines.
            text.feed(&writer, self.raw[at..end]) catch break;
            text.finish(&writer) catch break;
            try sink.feed(output_marker ++ "    ");
            try sink.feed(writer.buffered());
            try sink.feed("\n");
            budget -= writer.buffered().len;
            shown += 1;
            at = end + 1;
        }
        if (total > shown) {
            var buffer: [64]u8 = undefined;
            try sink.feed(more_marker ++ "    ");
            try sink.feed(try std.fmt.bufPrint(&buffer, "… {d} more lines\n", .{total - shown}));
        }
    }
};

test "tool references retain every authority field through the internal marker" {
    const reference: Reference = .{ .source = .conversation, .position = 987654321, .ordinal = 42, .content = .{ .length = 12345, .digest = protocol.contentDigest("saved output") } };
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try marker(reference, Sink{ .writer = &writer });
    const address = writer.buffered()[Text.link_open.len .. writer.end - Text.link_end.len - Text.link_close.len];
    try std.testing.expect(std.meta.eql(reference, parse(address).?));
    try std.testing.expect(parse("rui-tool:bad:1:2:3:abc") == null);
    try std.testing.expect(parse("https://example.com") == null);
}
