const std = @import("std");
const InputCapture = @import("../InputCapture.zig");
const media = @import("../input_media.zig");
const input_parts = @import("../input_parts.zig");
const max_parts = input_parts.max_parts;
const utf8 = @import("../utf8_validation.zig");
const document = @import("document.zig");
const result_parts = @import("result_parts.zig");
const result_text = @import("result_text.zig");

/// Collects each text run until an image boundary, preserving the text budget
/// across runs. Call finish after renderParts, before sealing the capture.
pub const Capture = struct {
    capture: *InputCapture,
    text_budget: usize = result_text.excerpt_bytes,
    out: *std.Io.Writer = undefined,
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    failure: ?anyerror = null,
    text: [result_text.excerpt_bytes + 256]u8 = undefined,
    text_len: usize = 0,
    shown: usize = 0,
    omitted: usize = 0,
    virtual_count: u32 = 0,
    virtual_image_bytes: u64 = 0,
    suffix: bool = false,
    run_lengths: [max_parts]u64 = undefined,
    run_index: usize = 0,
    run_bytes: u64 = 0,
    run_open: bool = false,
    record_runs: bool = false,
    ended: ?result_text.Ended = null,
    dry_run: bool = false,
    counted_text_bytes: u64 = 0,
    planned_bytes: u64 = 0,
    omitted_ever: bool = false,
    hint: []const u8 = "",
    sanitized_out: ?*std.Io.Writer = null,

    pub fn init(self: *Capture, capture: *InputCapture) void {
        self.* = .{ .capture = capture };
    }

    /// Initializes the writer pointer after Capture has reached its final address.
    pub fn sink(self: *Capture) *Capture {
        self.out = &self.writer;
        return self;
    }

    pub const Plan = struct { scratch_bytes: u64, omitted: bool };

    pub fn plan(self: *Capture, ended: result_text.Ended, hint: []const u8) !Plan {
        const summary = try self.preflight(ended, hint);
        return .{ .scratch_bytes = summary.scratch_bytes, .omitted = summary.omitted };
    }

    const Summary = struct { scratch_bytes: u64, omitted: bool, text_bytes: u64, no_images: bool, code: result_text.Code };

    fn preflight(self: *Capture, ended: result_text.Ended, hint: []const u8) !Summary {
        self.ended = ended;
        self.hint = hint;
        self.resetRun();
        self.dry_run = true;
        self.record_runs = true;
        self.sanitized_out = null;
        const code = result_text.renderParts(self.sink(), ended) catch |err| return self.failure orelse err;
        try self.finish();
        return .{ .scratch_bytes = self.planned_bytes, .omitted = self.omitted_ever, .text_bytes = self.counted_text_bytes, .no_images = self.virtual_image_bytes == 0, .code = code };
    }

    pub fn render(self: *Capture, ended: result_text.Ended) !result_text.Code {
        return self.renderWithHint(ended, "");
    }

    pub fn renderWithHint(self: *Capture, ended: result_text.Ended, hint: []const u8) !result_text.Code {
        const summary = try self.preflight(ended, hint);
        self.resetRun();
        self.dry_run = false;
        self.record_runs = false;
        _ = result_text.renderParts(self.sink(), ended) catch |err| return self.failure orelse err;
        try self.finish();
        return summary.code;
    }

    pub fn writeSanitized(self: *Capture, out: *std.Io.Writer, ended: result_text.Ended, hint: []const u8) !void {
        self.ended = ended;
        self.hint = hint;
        self.resetRun();
        self.dry_run = true;
        self.record_runs = false;
        self.sanitized_out = out;
        defer self.sanitized_out = null;
        _ = result_text.renderParts(self.sink(), ended) catch |err| return self.failure orelse err;
        try self.finish();
    }

    fn resetRun(self: *Capture) void {
        self.text_len = 0;
        self.shown = 0;
        self.omitted = 0;
        self.virtual_count = 0;
        self.virtual_image_bytes = 0;
        self.suffix = false;
        self.run_index = 0;
        self.run_bytes = 0;
        self.run_open = false;
        self.record_runs = false;
        self.counted_text_bytes = 0;
        self.planned_bytes = 0;
        self.omitted_ever = false;
        self.failure = null;
    }

    pub fn finish(self: *Capture) !void {
        try self.flushTextWithExtra(if (self.omitted_ever) self.hint else "");
        try self.endRun();
    }

    fn appendText(self: *Capture, bytes: []const u8) void {
        std.debug.assert(self.text_budget <= result_text.excerpt_bytes);
        const count = @min(bytes.len, self.text_budget - self.shown);
        @memcpy(self.text[self.text_len..][0..count], bytes[0..count]);
        self.text_len += count;
        self.shown += count;
        self.omitted += bytes.len - count;
        self.omitted_ever = self.omitted_ever or count != bytes.len;
    }

    fn flushText(self: *Capture) !void {
        try self.flushTextWithExtra("");
    }

    fn flushTextWithExtra(self: *Capture, extra: []const u8) !void {
        if (self.omitted != 0) {
            const complete = utf8.completePrefix(self.text[0..self.text_len]).len;
            self.omitted += self.text_len - complete;
            self.text_len = complete;
            const note = try std.fmt.bufPrint(self.text[self.text_len..], "\n[{d} more bytes not shown]", .{self.omitted});
            self.text_len += note.len;
            self.omitted = 0;
        }
        if (self.text_len == 0 and extra.len == 0) return;
        const length = self.text_len + extra.len;
        self.counted_text_bytes += length;
        self.run_bytes += length;
        if (!self.dry_run) {
            if (!self.run_open) {
                try self.capture.begin(.text, self.run_lengths[self.run_index]);
                self.run_open = true;
            }
            try self.appendBytes(self.text[0..self.text_len]);
            try self.appendBytes(extra);
        }
        self.text_len = 0;
    }

    fn endRun(self: *Capture) !void {
        if (self.run_bytes == 0) return;
        std.debug.assert(self.run_index < max_parts);
        if (self.record_runs) self.run_lengths[self.run_index] = self.run_bytes;
        if (self.run_open) try self.capture.end();
        self.planned_bytes += self.run_bytes + input_parts.Record.byte_length;
        self.virtual_count += 1;
        self.run_index += 1;
        self.run_bytes = 0;
        self.run_open = false;
    }

    fn appendBytes(self: *Capture, bytes: []const u8) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            var allowance: usize = bytes.len - at;
            at += try self.capture.append(bytes[at..], &allowance, false);
        }
    }

    fn diagnostic(self: *Capture, reason: []const u8) !void {
        // Complete a truncated scalar before appending an independent diagnostic.
        if (self.omitted != 0) try self.flushText();
        // Diagnostics are not subject to the text budget and never contain data.
        if (self.text.len - self.text_len < reason.len + 21 + self.text_budget - self.shown) try self.flushText();
        const message = try std.fmt.bufPrint(self.text[self.text_len..], "[Image unavailable: {s}]", .{reason});
        if (self.sanitized_out) |out| try out.writeAll(message);
        self.text_len += message.len;
    }

    pub fn badImage(self: *Capture, reason: []const u8, _: []const u8) !void {
        try self.diagnostic(reason);
    }

    pub fn image(self: *Capture, image_block: result_parts.Image, raw: []const u8) !void {
        const format: media.Format = if (document.keyIs(image_block.mime, "image/png")) .png else if (document.keyIs(image_block.mime, "image/jpeg")) .jpeg else {
            return self.diagnostic("unsupported MIME type");
        };
        const length = result_parts.decodedLength(image_block.data) catch return self.diagnostic("invalid base64");
        const total = std.math.add(u64, self.virtual_image_bytes, length) catch return self.diagnostic("image resource limit");
        if (total > self.capture.limits.max_bytes) return self.diagnostic("image resource limit");
        // InputCapture becomes failed on validation errors. Validate first so a
        // bad image can be replaced in place without discarding earlier parts.
        var scanner = media.Scanner.init(length, format, self.capture.limits) catch |err| return self.diagnostic(@errorName(err));
        var decoder = result_parts.Decoder.init(image_block.data);
        var window: [InputCapture.window_bytes]u8 = undefined;
        while (true) {
            const bytes = try decoder.next(&window);
            if (bytes.len == 0) break;
            var allowance = bytes.len;
            _ = scanner.advance(bytes, &allowance) catch |err| return self.diagnostic(@errorName(err));
        }
        _ = scanner.finish() catch |err| return self.diagnostic(@errorName(err));
        {
            if (self.suffix) return self.diagnostic("image part limit");
            const preceding = self.virtual_count + @as(u32, if (self.run_bytes != 0 or self.text_len != 0 or self.omitted != 0) 1 else 0);
            const reserve = if (preceding < max_parts - 1) false else if (preceding >= max_parts) true else (self.hint.len != 0 and self.omitted_ever) or try moreAfter(self.ended.?, raw);
            if (reserve) {
                self.suffix = true;
                return self.diagnostic("image part limit");
            }
        }
        try self.flushText();
        try self.endRun();
        self.virtual_count += 1;
        self.virtual_image_bytes = total;
        self.planned_bytes += length + input_parts.Record.byte_length;
        if (self.sanitized_out) |out| try out.writeAll("[Image]");
        if (self.dry_run) return;
        try self.capture.begin(.{ .image = .{ .assertion = format } }, length);
        decoder = result_parts.Decoder.init(image_block.data);
        while (true) {
            const bytes = try decoder.next(&window);
            if (bytes.len == 0) break;
            var at: usize = 0;
            while (at < bytes.len) {
                var allowance = bytes.len - at;
                at += try self.capture.append(bytes[at..], &allowance, false);
            }
        }
        try self.capture.end();
    }

    fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Capture = @fieldParentPtr("writer", writer);
        var count: usize = 0;
        for (parts[0 .. parts.len - 1]) |part| {
            if (self.sanitized_out) |out| out.writeAll(part) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            self.appendText(part);
            count += part.len;
        }
        for (0..splat) |_| {
            if (self.sanitized_out) |out| out.writeAll(parts[parts.len - 1]) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
            self.appendText(parts[parts.len - 1]);
            count += parts[parts.len - 1].len;
        }
        return count;
    }
};

// At the last available slot, replay the renderer to see whether the current
// image is the final output. Only reserve a suffix when more output follows.
fn moreAfter(ended: result_text.Ended, target: []const u8) !bool {
    var look: Lookahead = .{ .target = target.ptr };
    look.out = &look.writer;
    _ = try result_text.renderParts(&look, ended);
    return look.more;
}

const Lookahead = struct {
    target: [*]const u8,
    seen: bool = false,
    more: bool = false,
    out: *std.Io.Writer = undefined,
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    pub fn image(self: *Lookahead, _: result_parts.Image, raw: []const u8) !void {
        self.block(raw);
    }

    pub fn badImage(self: *Lookahead, _: []const u8, raw: []const u8) !void {
        self.block(raw);
    }

    fn block(self: *Lookahead, raw: []const u8) void {
        if (self.seen) self.more = true else if (raw.ptr == self.target) {
            self.seen = true;
        }
    }

    fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Lookahead = @fieldParentPtr("writer", writer);
        var count: usize = 0;
        for (parts[0 .. parts.len - 1]) |part| count += part.len;
        count += parts[parts.len - 1].len * splat;
        if (self.seen and count != 0) self.more = true;
        return count;
    }
};

fn testCapture(capture: *InputCapture, dir: std.Io.Dir, used: *std.atomic.Value(u64), limit: u64) !void {
    const spool = try dir.createFile(std.testing.io, "spool", .{ .read = true });
    errdefer spool.close(std.testing.io);
    try dir.deleteFile(std.testing.io, "spool");
    const index = try dir.createFile(std.testing.io, "index", .{ .read = true });
    errdefer index.close(std.testing.io);
    try dir.deleteFile(std.testing.io, "index");
    capture.init(std.testing.io, spool, index, .{ .used = used, .limit = limit });
}

fn expectPart(cursor: *InputCapture.Cursor, expected: []const u8, is_image: bool) !void {
    const part = (try cursor.next()).?;
    try std.testing.expectEqual(is_image, part.kind == .image);
    const bytes = try std.testing.allocator.alloc(u8, expected.len);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(expected.len, try part.range.file.readPositionalAll(std.testing.io, bytes, part.range.offset));
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

test "result capture preserves ordered text and images" {
    const jpg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const alloc = std.testing.allocator;
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(jpg.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, jpg);
    const image_json = try std.fmt.allocPrint(alloc, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}", .{encoded});
    defer alloc.free(image_json);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { before: []const u8, after: []const u8, adjacent: bool, is_error: bool }{
        .{ .before = "{\"type\":\"text\",\"text\":\"before\"},", .after = ",{\"type\":\"text\",\"text\":\"after\"}", .adjacent = false, .is_error = false },
        .{ .before = "", .after = "", .adjacent = false, .is_error = false },
        .{ .before = "", .after = "", .adjacent = true, .is_error = false },
        .{ .before = "", .after = "", .adjacent = false, .is_error = true },
    };
    for (cases) |case| {
        const content = try std.fmt.allocPrint(alloc, "[{s}{s}{s}{s}{s}]", .{ case.before, image_json, if (case.adjacent) "," else "", if (case.adjacent) image_json else "", case.after });
        defer alloc.free(content);
        var used = std.atomic.Value(u64).init(0);
        var input: InputCapture = undefined;
        try testCapture(&input, tmp.dir, &used, 100_000);
        defer input.close();
        var capture: Capture = undefined;
        capture.init(&input);
        const code = try capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = case.is_error, .structured = null } } } });
        try std.testing.expectEqual(if (case.is_error) result_text.Code.failed else .succeeded, code);
        var cursor = (try input.seal()).cursor();
        if (case.is_error) try expectPart(&cursor, "The tool reported an error:\n", false);
        if (case.before.len != 0) try expectPart(&cursor, "before", false);
        try expectPart(&cursor, jpg, true);
        if (case.adjacent) {
            try expectPart(&cursor, jpg, true);
        }
        if (case.after.len != 0) try expectPart(&cursor, "after", false);
        try std.testing.expect((try cursor.next()) == null);
    }
}

test "result capture diagnoses bad images and preserves later images after text budget" {
    const jpg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const alloc = std.testing.allocator;
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(jpg.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, jpg);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const invalid = [_]struct { block: []const u8, diagnostic: []const u8 }{
        .{ .block = "{\"type\":\"image\",\"data\":\"WA==\",\"mimeType\":\"image/gif\"}", .diagnostic = "[Image unavailable: unsupported MIME type]" },
        .{ .block = "{\"type\":\"image\",\"data\":\"!\",\"mimeType\":\"image/png\"}", .diagnostic = "[Image unavailable: invalid base64]" },
        .{ .block = "{\"type\":\"image\",\"data\":\"iVBORw0KGgo=\",\"mimeType\":\"image/png\"}", .diagnostic = "[Image unavailable: TruncatedImage]" },
        .{ .block = "{\"type\":\"image\"}", .diagnostic = "[Image unavailable: missing image data]" },
    };
    for (invalid) |case| {
        const content = try std.fmt.allocPrint(alloc, "[{s}]", .{case.block});
        defer alloc.free(content);
        var used = std.atomic.Value(u64).init(0);
        var input: InputCapture = undefined;
        try testCapture(&input, tmp.dir, &used, 100_000);
        defer input.close();
        var capture: Capture = undefined;
        capture.init(&input);
        _ = try capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } });
        const loan = try input.seal();
        try std.testing.expect(loan.single_text != null);
        var cursor = loan.cursor();
        try expectPart(&cursor, case.diagnostic, false);
        try std.testing.expect((try cursor.next()) == null);
    }
    const content = try std.fmt.allocPrint(alloc, "[{{\"type\":\"text\",\"text\":\"abcdef\"}},{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}]", .{encoded});
    defer alloc.free(content);
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 100_000);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    capture.text_budget = 3;
    _ = try capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } });
    var cursor = (try input.seal()).cursor();
    try expectPart(&cursor, "abc\n[3 more bytes not shown]", false);
    try expectPart(&cursor, jpg, true);
    try std.testing.expect((try cursor.next()) == null);
}

test "result capture propagates scratch exhaustion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 0);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    try std.testing.expectError(error.ScratchCapacityExceeded, capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = "[{\"type\":\"image\"}]", .is_error = false, .structured = null } } } }));
}

test "result capture reserves final part for excess image diagnostics" {
    const jpg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const alloc = std.testing.allocator;
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(jpg.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, jpg);
    const block = try std.fmt.allocPrint(alloc, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}", .{encoded});
    defer alloc.free(block);
    const count = max_parts + 303;
    const extra = ",{\"type\":\"text\",\"text\":\"end\"},{\"type\":\"image\"}]";
    const content = try alloc.alloc(u8, 1 + count * block.len + count - 1 + extra.len);
    defer alloc.free(content);
    var at: usize = 0;
    content[at] = '[';
    at += 1;
    for (0..count) |i| {
        if (i != 0) {
            content[at] = ',';
            at += 1;
        }
        @memcpy(content[at..][0..block.len], block);
        at += block.len;
    }
    @memcpy(content[at..][0..extra.len], extra);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 10_000_000);
    defer input.close();
    input.limits.max_bytes = jpg.len * count;
    var capture: Capture = undefined;
    capture.init(&input);
    _ = try capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } });
    const loan = try input.seal();
    try std.testing.expectEqual(max_parts, loan.count);
    var cursor = loan.cursor();
    for (0..max_parts - 1) |_| try expectPart(&cursor, jpg, true);
    const diagnostic = "[Image unavailable: image part limit]";
    const suffix = "end\n[Image unavailable: missing image data]";
    const expected = try alloc.alloc(u8, (count - (max_parts - 1)) * diagnostic.len + suffix.len);
    defer alloc.free(expected);
    var pos: usize = 0;
    for (0..count - (max_parts - 1)) |_| {
        @memcpy(expected[pos..][0..diagnostic.len], diagnostic);
        pos += diagnostic.len;
    }
    @memcpy(expected[pos..][0..suffix.len], suffix);
    try expectPart(&cursor, expected, false);
    try std.testing.expect((try cursor.next()) == null);
}

test "result capture truncates UTF-8 before an image diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 10_000);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    capture.text_budget = 2;
    _ = try capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = "[{\"type\":\"text\",\"text\":\"aé\"},{\"type\":\"image\"}]", .is_error = false, .structured = null } } } });
    var cursor = (try input.seal()).cursor();
    try expectPart(&cursor, "a\n[3 more bytes not shown][Image unavailable: missing image data]", false);
    try std.testing.expect((try cursor.next()) == null);
}

test "result capture retains PNG bytes and checks MIME assertion" {
    const base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
    var png: [try std.base64.standard.Decoder.calcSizeForSlice(base64)]u8 = undefined;
    try std.base64.standard.Decoder.decode(&png, base64);
    const content = "[{\"type\":\"image\",\"data\":\"" ++ base64 ++ "\",\"mimeType\":\"image/png\"},{\"type\":\"image\",\"data\":\"" ++ base64 ++ "\",\"mimeType\":\"image/jpeg\"}]";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 10_000);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    _ = try capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } });
    var cursor = (try input.seal()).cursor();
    try expectPart(&cursor, &png, true);
    try expectPart(&cursor, "[Image unavailable: ImageMimeMismatch]", false);
    try std.testing.expect((try cursor.next()) == null);
}

test "result capture coalesces many bad images into canonical text" {
    const block = "{\"type\":\"image\"}";
    const diagnostic = "[Image unavailable: missing image data]";
    const count = 1000;
    const alloc = std.testing.allocator;
    const content = try alloc.alloc(u8, 2 + count * block.len + count - 1);
    defer alloc.free(content);
    content[0] = '[';
    var at: usize = 1;
    for (0..count) |i| {
        if (i != 0) {
            content[at] = ',';
            at += 1;
        }
        @memcpy(content[at..][0..block.len], block);
        at += block.len;
    }
    content[at] = ']';
    const expected = try alloc.alloc(u8, count * diagnostic.len + count - 1);
    defer alloc.free(expected);
    at = 0;
    for (0..count) |i| {
        if (i != 0) {
            expected[at] = '\n';
            at += 1;
        }
        @memcpy(expected[at..][0..diagnostic.len], diagnostic);
        at += diagnostic.len;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 100_000);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    _ = try capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } });
    const loan = try input.seal();
    try std.testing.expect(loan.single_text != null);
    var cursor = loan.cursor();
    try expectPart(&cursor, expected, false);
    try std.testing.expect((try cursor.next()) == null);
}

test "result capture accepts exact image part limit and diagnoses one over" {
    const jpg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const alloc = std.testing.allocator;
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(jpg.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, jpg);
    const block = try std.fmt.allocPrint(alloc, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}", .{encoded});
    defer alloc.free(block);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]usize{ max_parts, max_parts + 1 }) |count| {
        const content = try alloc.alloc(u8, 2 + count * block.len + count - 1);
        defer alloc.free(content);
        content[0] = '[';
        var at: usize = 1;
        for (0..count) |i| {
            if (i != 0) {
                content[at] = ',';
                at += 1;
            }
            @memcpy(content[at..][0..block.len], block);
            at += block.len;
        }
        content[at] = ']';
        var used = std.atomic.Value(u64).init(0);
        var input: InputCapture = undefined;
        try testCapture(&input, tmp.dir, &used, 10_000_000);
        defer input.close();
        var capture: Capture = undefined;
        capture.init(&input);
        _ = try capture.render(.{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } });
        const loan = try input.seal();
        try std.testing.expectEqual(max_parts, loan.count);
        var cursor = loan.cursor();
        for (0..if (count == max_parts) max_parts else max_parts - 1) |_| try expectPart(&cursor, jpg, true);
        if (count > max_parts) try expectPart(&cursor, "[Image unavailable: image part limit][Image unavailable: image part limit]", false);
        try std.testing.expect((try cursor.next()) == null);
    }
}

test "result capture keeps image after maximum-sized bad-image text run" {
    const jpg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const alloc = std.testing.allocator;
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(jpg.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, jpg);
    const last = try std.fmt.allocPrint(alloc, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}]", .{encoded});
    defer alloc.free(last);
    const block = "{\"type\":\"image\"},";
    const count = (result_text.max_answer_bytes - last.len - 1) / block.len;
    const content = try alloc.alloc(u8, 1 + count * block.len + last.len);
    defer alloc.free(content);
    content[0] = '[';
    var at: usize = 1;
    for (0..count) |_| {
        @memcpy(content[at..][0..block.len], block);
        at += block.len;
    }
    @memcpy(content[at..], last);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 20_000_000);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    const ended: result_text.Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } };
    const planned = try capture.plan(ended, "");
    _ = try capture.render(ended);
    try std.testing.expectEqual(planned.scratch_bytes, used.load(.acquire));
    const loan = try input.seal();
    try std.testing.expectEqual(@as(u32, 2), loan.count);
    var cursor = loan.cursor();
    try std.testing.expect((try cursor.next()).?.kind == .text);
    try expectPart(&cursor, jpg, true);
    try std.testing.expect((try cursor.next()) == null);
}

test "result capture plans exact scratch and retains sanitized full text" {
    const jpg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const alloc = std.testing.allocator;
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(jpg.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, jpg);
    const content = try std.fmt.allocPrint(alloc, "[{{\"type\":\"text\",\"text\":\"abcdef\"}},{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}},{{\"type\":\"image\"}},{{\"type\":\"text\",\"text\":\"tail\"}}]", .{encoded});
    defer alloc.free(content);
    const ended: result_text.Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } };
    const hint = "\nFull output: /tmp/result\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 100_000);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    capture.text_budget = 3;
    const plan = try capture.plan(ended, hint);
    try std.testing.expect(plan.omitted);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try capture.writeSanitized(&writer, ended, hint);
    try std.testing.expectEqualStrings("abcdef[Image][Image unavailable: missing image data]\ntail", writer.buffered());
    _ = try capture.renderWithHint(ended, hint);
    try std.testing.expectEqual(plan.scratch_bytes, used.load(.acquire));
    var cursor = (try input.seal()).cursor();
    try expectPart(&cursor, "abc\n[3 more bytes not shown]", false);
    try expectPart(&cursor, jpg, true);
    try expectPart(&cursor, "[Image unavailable: missing image data]\n[5 more bytes not shown]\nFull output: /tmp/result\n", false);
    try std.testing.expect((try cursor.next()) == null);
}

test "result capture reserves trailing hint at exact part limit" {
    const jpg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const alloc = std.testing.allocator;
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(jpg.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, jpg);
    const block = try std.fmt.allocPrint(alloc, ",{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}", .{encoded});
    defer alloc.free(block);
    const prefix = "[{\"type\":\"text\",\"text\":\"abcdef\"}";
    const content = try alloc.alloc(u8, prefix.len + (max_parts - 1) * block.len + 1);
    defer alloc.free(content);
    @memcpy(content[0..prefix.len], prefix);
    var at = prefix.len;
    for (0..max_parts - 1) |_| {
        @memcpy(content[at..][0..block.len], block);
        at += block.len;
    }
    content[at] = ']';
    const ended: result_text.Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } };
    const hint = "\nFull output: /tmp/result\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 10_000_000);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    capture.text_budget = 3;
    const plan = try capture.plan(ended, hint);
    const output = try alloc.alloc(u8, 20_000);
    defer alloc.free(output);
    var writer: std.Io.Writer = .fixed(output);
    try capture.writeSanitized(&writer, ended, hint);
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), "[Image unavailable: image part limit]"));
    _ = try capture.renderWithHint(ended, hint);
    try std.testing.expectEqual(plan.scratch_bytes, used.load(.acquire));
    const loan = try input.seal();
    try std.testing.expectEqual(max_parts, loan.count);
    var cursor = loan.cursor();
    try expectPart(&cursor, "abc\n[3 more bytes not shown]", false);
    for (0..max_parts - 2) |_| try expectPart(&cursor, jpg, true);
    try expectPart(&cursor, "[Image unavailable: image part limit]\nFull output: /tmp/result\n", false);
    try std.testing.expect((try cursor.next()) == null);
}

test "result capture coalesces diagnostics after exhausted text budget before image" {
    const jpg = @embedFile("../testing/fixtures/input-baseline.jpg");
    const alloc = std.testing.allocator;
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(jpg.len));
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, jpg);
    const image = try std.fmt.allocPrint(alloc, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}]", .{encoded});
    defer alloc.free(image);
    const prefix = "[{\"type\":\"text\",\"text\":\"abcdef\"},";
    const bad = "{\"type\":\"image\"},";
    const count = 2500;
    const content = try alloc.alloc(u8, prefix.len + count * bad.len + image.len);
    defer alloc.free(content);
    @memcpy(content[0..prefix.len], prefix);
    var at: usize = prefix.len;
    for (0..count) |_| {
        @memcpy(content[at..][0..bad.len], bad);
        at += bad.len;
    }
    @memcpy(content[at..], image);
    const ended: result_text.Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content, .is_error = false, .structured = null } } } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(0);
    var input: InputCapture = undefined;
    try testCapture(&input, tmp.dir, &used, 1_000_000);
    defer input.close();
    var capture: Capture = undefined;
    capture.init(&input);
    capture.text_budget = 3;
    const plan = try capture.plan(ended, "");
    const output = try alloc.alloc(u8, 200_000);
    defer alloc.free(output);
    var writer: std.Io.Writer = .fixed(output);
    try capture.writeSanitized(&writer, ended, "");
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), "[Image]"));
    _ = try capture.render(ended);
    try std.testing.expectEqual(plan.scratch_bytes, used.load(.acquire));
    const loan = try input.seal();
    try std.testing.expectEqual(@as(u32, 2), loan.count);
    var cursor = loan.cursor();
    try std.testing.expect((try cursor.next()).?.kind == .text);
    try expectPart(&cursor, jpg, true);
    try std.testing.expect((try cursor.next()) == null);
}
