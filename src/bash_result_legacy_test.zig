// Test-only copy of the base Bash formatter's seekable excerpt implementation.
// Kept independent of excerpt.zig to compare the complete composed result.
const std = @import("std");

const Utf8Unit = struct {
    source_length: usize,
    encoded_length: usize,
    valid: bool,
};

fn utf8Unit(bytes: []const u8, index: usize) Utf8Unit {
    const sequence_length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
        return .{ .source_length = 1, .encoded_length = "�".len, .valid = false };
    };
    if (index + sequence_length > bytes.len) {
        return .{ .source_length = 1, .encoded_length = "�".len, .valid = false };
    }
    _ = std.unicode.utf8Decode(bytes[index .. index + sequence_length]) catch {
        return .{ .source_length = 1, .encoded_length = "�".len, .valid = false };
    };
    return .{ .source_length = sequence_length, .encoded_length = sequence_length, .valid = true };
}

fn validUtf8Length(bytes: []const u8) usize {
    var length: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const unit = utf8Unit(bytes, index);
        length += unit.encoded_length;
        index += unit.source_length;
    }
    return length;
}

const Excerpt = struct {
    head: []const u8,
    tail: []const u8,
    tail_starts_line: bool,
    source_length: u64,

    fn encodedLength(self: Excerpt) usize {
        return validUtf8Length(self.head) + validUtf8Length(self.tail);
    }

    fn append(self: Excerpt, writer: *std.Io.Writer, allowance: usize) !bool {
        if (self.head.len == self.source_length and self.encodedLength() <= allowance) {
            _ = try appendValidUtf8Tail(writer, self.head, allowance);
            return false;
        }
        const head_allowance = allowance / 2;
        var head_end = utf8HeadEnd(self.head, head_allowance);
        const head_window = head_end -| 256;
        if (std.mem.lastIndexOfScalar(u8, self.head[head_window..head_end], '\n')) |newline| {
            head_end = head_window + newline + 1;
        }
        const tail = if (self.head.len == self.source_length) self.head else self.tail;
        var tail_start = utf8TailStart(tail, allowance - head_allowance);
        const tail_starts_line = if (tail_start == 0) self.tail_starts_line else tail[tail_start - 1] == '\n';
        if (!tail_starts_line) if (std.mem.indexOfScalar(u8, tail[tail_start..][0..@min(256, tail.len - tail_start)], '\n')) |newline| {
            tail_start += newline + 1;
        };
        _ = try appendValidUtf8Tail(writer, self.head[0..head_end], head_allowance);
        if (head_end != 0 and self.head[head_end - 1] != '\n') try writer.writeByte('\n');
        try writer.print("[{d} bytes left out]\n", .{self.source_length - head_end - (tail.len - tail_start)});
        _ = try appendValidUtf8Tail(writer, tail[tail_start..], allowance - head_allowance);
        return true;
    }
};

fn readExcerpt(file: std.Io.File, io: std.Io, length: u64, take: usize, buffer: []u8) !Excerpt {
    if (length <= take) {
        if (try file.readPositionalAll(io, buffer[0..take], 0) != take) return error.ShortCaptureRead;
        return .{ .head = buffer[0..take], .tail = "", .tail_starts_line = true, .source_length = length };
    }
    const head_take = take / 2;
    const head_read: usize = @intCast(@min(length, head_take + 3));
    if (try file.readPositionalAll(io, buffer[0..head_read], 0) != head_read) return error.ShortCaptureRead;
    var head_end: usize = 0;
    while (head_end < head_take) head_end += utf8Unit(buffer[0..head_read], head_end).source_length;
    const tail_take = take - head_take;
    const tail_offset = length - tail_take;
    const context: usize = @intCast(@min(tail_offset, 4));
    const tail_read = tail_take + context;
    const tail = buffer[head_read..][0..tail_read];
    if (try file.readPositionalAll(io, tail, tail_offset - context) != tail_read) return error.ShortCaptureRead;
    var tail_start: usize = 0;
    while (tail_start < context) {
        const next = tail_start + utf8Unit(tail, tail_start).source_length;
        if (next > context) break;
        tail_start = next;
    }
    return .{
        .head = buffer[0..head_end],
        .tail = tail[tail_start..],
        .tail_starts_line = if (tail_start == 0) tail_offset - context == 0 else tail[tail_start - 1] == '\n',
        .source_length = length,
    };
}

fn utf8HeadEnd(bytes: []const u8, allowance: usize) usize {
    var encoded_length: usize = 0;
    var end: usize = 0;
    while (end < bytes.len) {
        const unit = utf8Unit(bytes, end);
        if (unit.encoded_length > allowance - encoded_length) break;
        encoded_length += unit.encoded_length;
        end += unit.source_length;
    }
    return end;
}

fn utf8TailStart(bytes: []const u8, allowance: usize) usize {
    var encoded_length = validUtf8Length(bytes);
    var start: usize = 0;
    while (encoded_length > allowance) {
        const unit = utf8Unit(bytes, start);
        encoded_length -= unit.encoded_length;
        start += unit.source_length;
    }
    return start;
}

fn appendValidUtf8Tail(writer: *std.Io.Writer, bytes: []const u8, allowance: usize) !bool {
    const start = utf8TailStart(bytes, allowance);
    var index = start;
    while (index < bytes.len) {
        const unit = utf8Unit(bytes, index);
        if (unit.valid) {
            try writer.writeAll(bytes[index .. index + unit.source_length]);
        } else {
            try writer.writeAll("�");
        }
        index += unit.source_length;
    }
    return start != 0;
}

pub fn format(writer: *std.Io.Writer, files: [2]std.Io.File, lengths: [2]u64, root: []const u8, include_paths: bool, retain: bool) !void {
    const total: usize = 20_000;
    const stderr_base: usize = @intCast(@min(lengths[1], total / 2));
    const stdout_take: usize = @intCast(@min(lengths[0], total - stderr_base));
    const stderr_take = stderr_base + @as(usize, @intCast(@min(lengths[1] - stderr_base, total - stderr_base - stdout_take)));
    const sample = try std.testing.allocator.alloc(u8, total + 14);
    defer std.testing.allocator.free(sample);
    const stdout = try readExcerpt(files[0], std.testing.io, lengths[0], stdout_take, sample[0 .. stdout_take + 7]);
    const stderr = try readExcerpt(files[1], std.testing.io, lengths[1], stderr_take, sample[stdout_take + 7 ..][0 .. stderr_take + 7]);
    const encoded_base = @min(stderr.encodedLength(), total / 2);
    const stdout_allowance = @min(stdout.encodedLength(), total - encoded_base);
    const stderr_allowance = encoded_base + @min(stderr.encodedLength() - encoded_base, total - encoded_base - stdout_allowance);
    try writer.writeAll("Bash succeeded. Exit code: 0.\n");
    var stdout_omitted = false;
    if (lengths[0] != 0) {
        try writer.writeAll("stdout:\n");
        stdout_omitted = try stdout.append(writer, stdout_allowance);
    }
    var stderr_omitted = false;
    if (lengths[1] != 0) {
        try writer.writeAll(if (lengths[0] != 0) "\nstderr:\n" else "stderr:\n");
        stderr_omitted = try stderr.append(writer, stderr_allowance);
    }
    if ((!stdout_omitted and !stderr_omitted) or !retain) return;
    if (!include_paths) {
        try writer.writeAll("\nFull output was not retained.\n");
        return;
    }
    try writer.writeByte('\n');
    if (stdout_omitted) try writer.print("Full stdout: {s}/stdout\n", .{root});
    if (stderr_omitted) try writer.print("Full stderr: {s}/stderr\n", .{root});
}

const excerpt_bytes: usize = 20_000;

test "seekable cutter matches Bash formatResult stream pairs" {
    const core = @import("excerpt.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "capture", .{ .read = true });
    defer file.close(std.testing.io);
    const gpa = std.testing.allocator;
    const source = try gpa.alloc(u8, 24000);
    defer gpa.free(source);
    const samples = try gpa.alloc(u8, 20014);
    defer gpa.free(samples);
    const expected = try gpa.alloc(u8, 21000);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, 21000);
    defer gpa.free(actual);
    for ([_]usize{ 0, 1, 9999, 10000, 10001, 24000 }) |n1| {
        for ([_]usize{ 0, 3, 9999, 10001, 24000 }) |n2| {
            for (0..4) |pattern| {
                const lengths = [_]u64{ n1, n2 };
                var takes: [2]usize = undefined;
                core.allot(&lengths, excerpt_bytes, &takes);
                const stderr_base: usize = @intCast(@min(n2, excerpt_bytes / 2));
                const old_first = @min(n1, excerpt_bytes - stderr_base);
                const old_second = stderr_base + @min(n2 - stderr_base, excerpt_bytes - stderr_base - old_first);
                try std.testing.expectEqualSlices(usize, &.{ old_first, old_second }, &takes);
                var excerpts: [2]Excerpt = undefined;
                var offset: usize = 0;
                for (lengths, 0..) |length, i| {
                    for (source, 0..) |*byte, j| byte.* = switch (pattern) {
                        0 => 'x',
                        1 => if (j % 113 == 0) '\n' else 'y',
                        2 => if (j % 7 == 0) 0xff else if (j % 101 == 0) '\n' else 'z',
                        else => ("é🙂\xff\nabc")[j % "é🙂\xff\nabc".len],
                    };
                    // Different data per stream is already stored in the samples.
                    try file.writePositionalAll(std.testing.io, source[0..@intCast(length)], 0);
                    excerpts[i] = try readExcerpt(file, std.testing.io, length, takes[i], samples[offset..][0 .. takes[i] + 7]);
                    offset += takes[i] + 7;
                }
                const encoded = [_]u64{ excerpts[0].encodedLength(), excerpts[1].encodedLength() };
                var allowances: [2]usize = undefined;
                core.allot(&encoded, excerpt_bytes, &allowances);
                const base = @min(excerpts[1].encodedLength(), excerpt_bytes / 2);
                const first = @min(excerpts[0].encodedLength(), excerpt_bytes - base);
                const second = base + @min(excerpts[1].encodedLength() - base, excerpt_bytes - base - first);
                try std.testing.expectEqualSlices(usize, &.{ first, second }, &allowances);
                for (excerpts, 0..) |old, i| {
                    var oracle = std.Io.Writer.fixed(expected);
                    const omitted = try old.append(&oracle, allowances[i]);
                    const cut = core.cutSeekable(.{ .head = old.head, .tail = old.tail, .tail_starts_line = old.tail_starts_line, .source_length = old.source_length }, allowances[i]);
                    var got = std.Io.Writer.fixed(actual);
                    _ = try appendValidUtf8Tail(&got, old.head[0..cut.head_end], allowances[i]);
                    if (cut.truncated) {
                        if (cut.head_end != 0 and old.head[cut.head_end - 1] != '\n') try got.writeByte('\n');
                        try got.print("[{d} bytes left out]\n", .{cut.left_out});
                        const tail = if (old.head.len == old.source_length) old.head else old.tail;
                        _ = try appendValidUtf8Tail(&got, tail[cut.tail_start..], allowances[i]);
                    }
                    try std.testing.expectEqual(omitted, cut.truncated);
                    try std.testing.expectEqualStrings(oracle.buffered(), got.buffered());
                }
            }
        }
    }
}
