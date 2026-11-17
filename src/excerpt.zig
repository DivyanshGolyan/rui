const std = @import("std");
const utf8 = @import("utf8_validation.zig");

pub const boundary_capacity = 5;
pub const Count = u64;
pub const head_note_format = "\n[{d} more bytes not shown]";
pub const left_out_format = "\n[{d} bytes left out]\n";
pub const head_note_max = std.fmt.count(head_note_format, .{std.math.maxInt(Count)});
pub const left_out_max = std.fmt.count(left_out_format, .{std.math.maxInt(Count)});
pub const not_retained = "\nFull output was not retained.\n";
pub const footer_max = 1 + 2 * ("Full stderr: ".len + std.posix.PATH_MAX + 1);

/// A shared byte allowance. Bytes are preserved, including malformed UTF-8: MCP
/// can render raw HTTP bodies and truncated response prefixes. When cutting,
/// the boundary is moved back over continuation bytes, just as the MCP prefix
/// writer does. The caller retains source chunks separately for any spill.
/// A run must be closed before beginning the next one.
pub const Window = struct {
    remaining: usize,
    run_limit: usize,
    run_total: Count = 0,
    run_shown: usize = 0,
    tail: [boundary_capacity]u8 = undefined,
    tail_len: usize = 0,
    ever_omitted: bool = false,
    exhausted: bool = false,

    pub fn init(allowance: usize) Window {
        return .{ .remaining = allowance, .run_limit = allowance };
    }

    /// Writes the safe prefix to out; at most five boundary bytes are delayed
    /// until closeRun. The entire original chunk remains the caller's to retain.
    /// out must have room for min(chunk.len, remaining).
    pub fn feed(self: *Window, chunk: []const u8, out: []u8) Fed {
        self.run_total += chunk.len;
        const direct_limit = self.run_limit -| 4;
        const direct = @min(chunk.len, direct_limit - self.run_shown);
        @memcpy(out[0..direct], chunk[0..direct]);
        self.run_shown += direct;
        const saved = @min(chunk.len - direct, @min(self.tail.len, self.run_limit +| 1) - self.tail_len);
        @memcpy(self.tail[self.tail_len..][0..saved], chunk[direct..][0..saved]);
        self.tail_len += saved;
        return .{ .written = direct };
    }

    /// Flushes boundary bytes and a note, returning their length. out must have
    /// at least boundary_capacity + head_note_max bytes. Repeated calls without a feed are empty.
    pub fn closeRun(self: *Window, out: []u8) []const u8 {
        if (self.run_total == 0) return out[0..0];
        var take = self.tail_len;
        if (self.run_total > self.run_limit) {
            take = utf8.scalarStart(self.tail[0..self.tail_len], @min(self.run_limit - self.run_shown, self.tail_len));
        }
        @memcpy(out[0..take], self.tail[0..take]);
        self.run_shown += take;
        const omitted = self.run_total - self.run_shown;
        self.remaining -= self.run_shown;
        var written = take;
        if (omitted != 0) {
            self.ever_omitted = true;
            self.exhausted = true;
            const note = std.fmt.bufPrint(out[written..], head_note_format, .{omitted}) catch unreachable;
            written += note.len;
        }
        self.run_total = 0;
        self.run_shown = 0;
        self.tail_len = 0;
        self.run_limit = if (self.exhausted) 0 else self.remaining;
        return out[0..written];
    }

    pub fn omittedAny(self: *const Window) bool {
        return self.ever_omitted or self.run_total > self.run_limit;
    }
};
pub const Fed = struct { written: usize };

/// Samples must be read with the same source-byte allotment used by the caller:
/// head and tail include complete UTF-8 units at their outer boundaries.
pub const Seekable = struct { head: []const u8, tail: []const u8, tail_starts_line: bool, source_length: u64 };
pub const Cut = struct { head_end: usize, tail_start: usize, left_out: u64, truncated: bool };

pub const Utf8Unit = struct { source: usize, encoded: usize, valid: bool };
/// Decode one source unit, replacing each invalid byte independently.
pub fn utf8Unit(bytes: []const u8, at: usize) Utf8Unit {
    const n = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return .{ .source = 1, .encoded = 3, .valid = false };
    if (at + n > bytes.len) return .{ .source = 1, .encoded = 3, .valid = false };
    _ = std.unicode.utf8Decode(bytes[at..][0..n]) catch return .{ .source = 1, .encoded = 3, .valid = false };
    return .{ .source = n, .encoded = n, .valid = true };
}

/// Length after replacing each invalid byte with U+FFFD, as Bash renders it.
pub fn encodedLength(bytes: []const u8) usize {
    var pos: usize = 0;
    var count: usize = 0;
    while (pos < bytes.len) {
        const u = utf8Unit(bytes, pos);
        pos += u.source;
        count += u.encoded;
    }
    return count;
}

pub fn cutSeekable(text: Seekable, allowance: usize) Cut {
    const length = encodedLength(text.head) + encodedLength(text.tail);
    if (text.head.len == text.source_length and length <= allowance)
        return .{ .head_end = text.head.len, .tail_start = text.head.len, .left_out = 0, .truncated = false };
    const head_allowance = allowance / 2;
    var end: usize = 0;
    var encoded: usize = 0;
    while (end < text.head.len) {
        const u = utf8Unit(text.head, end);
        if (u.encoded > head_allowance - encoded) break;
        end += u.source;
        encoded += u.encoded;
    }
    const window = end -| 256;
    if (std.mem.lastIndexOfScalar(u8, text.head[window..end], '\n')) |newline| end = window + newline + 1;
    const tail = if (text.head.len == text.source_length) text.head else text.tail;
    var start: usize = 0;
    encoded = encodedLength(tail);
    while (encoded > allowance - head_allowance) {
        const u = utf8Unit(tail, start);
        start += u.source;
        encoded -= u.encoded;
    }
    const starts_line = if (start == 0) text.tail_starts_line else tail[start - 1] == '\n';
    if (!starts_line) if (std.mem.indexOfScalar(u8, tail[start..][0..@min(256, tail.len - start)], '\n')) |newline| {
        start += newline + 1;
    };
    return .{ .head_end = end, .tail_start = start, .left_out = text.source_length - end - (tail.len - start), .truncated = true };
}

/// The last stream gets up to half first; earlier streams take the rest in
/// order, then the last receives any remainder. Works for source or encoded lengths.
pub fn allot(lengths: []const u64, total: usize, out: []usize) void {
    std.debug.assert(lengths.len == out.len);
    if (lengths.len == 0) return;
    const last = lengths.len - 1;
    const base: usize = @intCast(@min(lengths[last], total / 2));
    var remaining = total - base;
    for (lengths[0..last], 0..) |length, i| {
        out[i] = @intCast(@min(length, remaining));
        remaining -= out[i];
    }
    out[last] = base + @as(usize, @intCast(@min(lengths[last] - base, remaining)));
}

pub const Retained = struct { label: []const u8, path: ?[]const u8 };

/// Caller supplies only truncated streams. A failed retention produces one
/// shared refusal footer, matching the existing MCP and Bash renderers.
pub fn footer(truncated: []const Retained, retain: bool, out: []u8) []const u8 {
    if (!retain or truncated.len == 0) return out[0..0];
    for (truncated) |item| if (item.path == null) {
        @memcpy(out[0..not_retained.len], not_retained);
        return out[0..not_retained.len];
    };
    var writer: std.Io.Writer = .fixed(out);
    writer.writeByte('\n') catch unreachable;
    for (truncated) |item| writer.print("Full {s}: {s}\n", .{ item.label, item.path.? }) catch unreachable;
    return writer.buffered();
}

fn compareOracle(ended: @import("mcp/result_text_legacy_test.zig").Ended, chunk_size: usize) !void {
    const result_text = @import("mcp/result_text_legacy_test.zig");
    const gpa = std.testing.allocator;
    const capacity = 32_000;
    const full = try gpa.alloc(u8, capacity);
    defer gpa.free(full);
    const expected = try gpa.alloc(u8, capacity);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, capacity);
    defer gpa.free(actual);
    var full_writer: std.Io.Writer = .fixed(full);
    try result_text.writeFull(&full_writer, ended);
    var expected_writer: std.Io.Writer = .fixed(expected);
    const oracle = try result_text.writeExcerpt(&expected_writer, ended);
    var window = Window.init(result_text.excerpt_bytes);
    var length: usize = 0;
    const bytes = full_writer.buffered();
    var at: usize = 0;
    var random: u64 = 0x4d595df4d0f33173;
    while (at < bytes.len) {
        random = random *% 6364136223846793005 +% 1442695040888963407;
        const width = 1 + @as(usize, @intCast(random % chunk_size));
        const end = @min(bytes.len, at + width);
        const fed = window.feed(bytes[at..end], actual[length..]);
        length += fed.written;
        at = end;
    }
    length += window.closeRun(actual[length..]).len;
    try std.testing.expectEqual(oracle.omitted, window.omittedAny());
    try std.testing.expectEqualStrings(expected_writer.buffered(), actual[0..length]);
}

test "window agrees with MCP excerpt over chunked raw and decoded outcomes" {
    const result_text = @import("mcp/result_text_legacy_test.zig");
    const reply = @import("mcp/reply.zig");
    const gpa = std.testing.allocator;
    const body = try gpa.alloc(u8, 20_100);
    defer gpa.free(body);
    for ([_]usize{ 1, 2, 3, 4, 7, 97, 10000, 20000 }) |chunk| {
        for ([_][]const u8{ "é", "€", "😀", "\xff", "\xed\xa0\x80" }) |scalar| {
            for ([_]usize{ 9962, 9965, 9966, 9967, 9999 }) |pos| {
                @memset(body, 'x');
                @memcpy(body[pos..][0..scalar.len], scalar);
                const ended: result_text.Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .refused = .{ .status = 403, .body = body } } } };
                try compareOracle(ended, chunk);
            }
        }
        for ([_]usize{ 9965, 9966, 9967, 9968 }) |body_len| {
            @memset(body, 'x');
            try compareOracle(.{ .server_name = "test", .ended = .{ .outcome = .{ .refused = .{ .status = 403, .body = body[0..body_len] } } } }, chunk);
        }
        const decoded: result_text.Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = "[{\"type\":\"text\",\"text\":\"a\\n\\ud83d\\ude00\"},{\"type\":\"text\",\"text\":\"b\"}]", .structured = null, .is_error = true } } } };
        try compareOracle(decoded, chunk);
        const invalid = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"\\ud800\"}]}}";
        const outcome = reply.readCallAnswer(.{ .bytes = invalid, .id = 7 });
        try std.testing.expect(outcome == .refused);
        try compareOracle(.{ .server_name = "test", .ended = .{ .outcome = outcome } }, chunk);
        try compareOracle(.{ .server_name = "test", .ended = .{ .oversized = .{ .bytes = "raw\xff\xe2\x82", .id = 7, .status = 403, .extent = .cut } } }, chunk);
    }
}

test "window shares allowance across runs and footer describes retention" {
    var window = Window.init(3);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), window.feed("abcd", &buffer).written);
    try std.testing.expectEqualStrings("abc\n[1 more bytes not shown]", window.closeRun(&buffer));
    try std.testing.expect(window.omittedAny());
    try std.testing.expectEqual(@as(usize, 0), window.feed("z", &buffer).written);
    try std.testing.expectEqualStrings("\n[1 more bytes not shown]", window.closeRun(&buffer));
    try std.testing.expectEqualStrings("", window.closeRun(&buffer));
    try std.testing.expectEqualStrings("", footer(&.{.{ .label = "output", .path = null }}, false, &buffer));
    try std.testing.expectEqualStrings(not_retained, footer(&.{.{ .label = "output", .path = null }}, true, &buffer));
    try std.testing.expectEqualStrings("\nFull output: /tmp/result\n", footer(&.{.{ .label = "output", .path = "/tmp/result" }}, true, &buffer));
}

// This exercises the P1 text volume and ordering without asking the legacy
// renderer to validate images: diagnostics are the text a shared result
// receives after image rejection, followed by the large text block.
test "window matches legacy excerpt for P1 diagnostic and text volume" {
    const result_text = @import("mcp/result_text_legacy_test.zig");
    const gpa = std.testing.allocator;
    const content = try gpa.alloc(u8, 24_000);
    defer gpa.free(content);
    var writer: std.Io.Writer = .fixed(content);
    try writer.writeAll("[{\"type\":\"text\",\"text\":\"");
    for (0..6) |_| try writer.writeAll("[Image unavailable: invalid base64]");
    for (0..20_000) |_| try writer.writeByte('x');
    try writer.writeAll("\"}]");
    const ended: result_text.Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = writer.buffered(), .structured = null, .is_error = false } } } };
    for ([_]usize{ 1, 2, 7, 97, 10_000, 20_000 }) |chunk| try compareOracle(ended, chunk);
}

test "seekable allot shares allowance and handles empty streams" {
    var out: [3]usize = undefined;
    allot(&.{ 100, 100, 100 }, 20, &out);
    try std.testing.expectEqualSlices(usize, &.{ 10, 0, 10 }, &out);
    allot(&.{ 2, 3, 100 }, 20, &out);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 15 }, &out);
    allot(&.{ 0, 0, 0 }, 20, &out);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 0 }, &out);
    allot(&.{}, 0, &.{});
}

test "seekable cuts preserve byte accounting and newline boundaries" {
    const whole = Seekable{ .head = "abc\xffdef", .tail = "", .tail_starts_line = true, .source_length = 7 };
    try std.testing.expectEqual(@as(usize, 9), encodedLength(whole.head));
    try std.testing.expect(!cutSeekable(whole, 9).truncated);
    const cut = cutSeekable(whole, 4);
    try std.testing.expect(cut.truncated);
    try std.testing.expectEqual(@as(usize, 2), cut.head_end);
    try std.testing.expectEqual(@as(usize, 5), cut.tail_start);
    try std.testing.expectEqual(@as(u64, 3), cut.left_out);
    const lines = Seekable{ .head = "abc\ndef", .tail = "", .tail_starts_line = true, .source_length = 7 };
    const line_cut = cutSeekable(lines, 6);
    try std.testing.expectEqual(@as(usize, 3), line_cut.head_end);
    try std.testing.expectEqual(@as(usize, 4), line_cut.tail_start);
    try std.testing.expectEqual(@as(u64, 1), line_cut.left_out);
}
