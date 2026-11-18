const std = @import("std");
const InputCapture = @import("InputCapture.zig");
const excerpt = @import("excerpt.zig");
const input_parts = @import("input_parts.zig");
const media = @import("input_media.zig");
const intake = @import("image_intake.zig");
const layout_mod = @import("result_layout.zig");
const retention = @import("output_retention.zig");
const ScratchBudget = @import("ScratchBudget.zig");
const Failure = @import("result_fault.zig").Failure;
const fault = @import("result_fault.zig");
const Host = @import("server_host.zig").Host;
const Profile = @import("tool_record.zig").Profile;

pub const SeekableStream = struct {
    label: []const u8,
    section: []const u8,
    file: std.Io.File,
    length: u64,
    context: *anyopaque,
    adopt: *const fn (*anyopaque) ?retention.Spill,
};

pub const Value = union(enum) { text: []const u8, parts: InputCapture.Loan };
pub const Rejection = union(enum) { reason: []const u8, failure: Failure };
pub const ImageProgress = union(enum) { pending, kept, rejected: Rejection, failed: Failure };
pub const Finished = union(enum) { value: Value, failed: struct { failure: Failure, seal: bool } };
const max_excerpt = @import("tool_record.zig").max_result_excerpt_bytes;
const frame_capacity = 4096;
const run_capacity = max_excerpt + frame_capacity + excerpt.max_retained * excerpt.left_out_max + excerpt.boundary_capacity + excerpt.head_note_max + excerpt.footer_max;
const image_marker = "[Image]";
const prefix_capacity = max_excerpt + input_parts.max_parts * image_marker.len;

comptime {
    if (run_capacity > 40 * 1024) @compileError("result run exceeds 40 KiB");
    if (prefix_capacity < excerpt.max_retained * excerpt.max_path_bytes)
        @compileError("result prefix cannot hold retained paths");
    if (prefix_capacity < max_excerpt + excerpt.max_retained * 7)
        @compileError("result prefix cannot hold seekable samples");
}

/// One composition for text, images, bounded excerpt and optional retained output.
/// The object, its capture, and any in-flight Source context must stay at stable addresses.
pub const Result = struct {
    host: *Host,
    action: u64,
    profile: Profile,
    window: excerpt.Window,
    layout: layout_mod.Layout = .{},
    run: [run_capacity]u8 = undefined,
    run_len: usize = 0,
    frame_len: usize = 0,
    file_spills: [excerpt.max_retained]?retention.Spill = @splat(null),
    file_advertised: bool = false,
    files_started: bool = false,
    prefix: [prefix_capacity]u8 = undefined,
    path_buffer: [std.posix.PATH_MAX]u8 = undefined,
    footer_buffer: [excerpt.footer_max]u8 = undefined,
    prefix_len: usize = 0,
    spill: ?retention.Spill = null,
    spill_attempted: bool = false,
    advertised: bool = false,
    capture: ?InputCapture = null,
    credit: ?ScratchBudget.Credit = null,
    image: intake.Intake = .{},
    image_last: bool = false,
    image_length: u64 = 0,
    attached: bool = false,
    done: bool = false,
    test_reserve_hook: if (@import("builtin").is_test) ?*const fn (*Result) void else void = if (@import("builtin").is_test) null else {},
    test_competing: if (@import("builtin").is_test) u64 else void = if (@import("builtin").is_test) 0 else {},
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    pub noinline fn create(host: *Host, action: u64, profile: Profile) !*Result {
        if (profile.excerpt_bytes > max_excerpt) return error.InvalidResultProfile;
        const self = try host.allocator.create(Result);
        self.* = .{ .host = host, .action = action, .profile = profile, .window = excerpt.Window.init(profile.excerpt_bytes) };
        return self;
    }

    pub fn destroy(self: *Result) void {
        if (self.capture) |*capture| capture.close();
        if (self.credit) |*credit| credit.releaseUnused();
        if (self.spill) |*spill| spill.release();
        for (&self.file_spills) |*spill| if (spill.*) |*value| value.release();
        self.host.allocator.destroy(self);
    }

    /// Framing is outside the shared content allowance.
    pub fn frame(self: *Result, bytes: []const u8) !void {
        std.debug.assert(!self.done and !self.attached and self.capture == null);
        if (self.files_started) return error.ResultFilesComplete;
        try self.appendFrame(bytes);
    }

    fn appendFrame(self: *Result, bytes: []const u8) !void {
        if (bytes.len > frame_capacity - self.frame_len) return error.FrameTooLarge;
        self.closeRun();
        @memcpy(self.run[self.run_len..][0..bytes.len], bytes);
        self.run_len += bytes.len;
        self.frame_len += bytes.len;
    }

    /// Compose up to two seekable streams. Only cut streams are offered for
    /// adoption, after all reads succeed. A failed adoption suppresses all paths.
    pub noinline fn files(self: *Result, streams: []const SeekableStream) !void {
        std.debug.assert(!self.done and !self.attached and self.capture == null);
        if (self.files_started) return error.ResultFilesComplete;
        if (streams.len > excerpt.max_retained) return error.TooManyStreams;
        for (streams) |stream| {
            if (stream.label.len > excerpt.max_label_bytes) return error.InvalidRetainedLabel;
        }
        self.files_started = true;
        std.debug.assert(self.prefix_len == 0 and self.spill == null and self.window.run_total == 0);
        self.closeRun();
        var lengths: [excerpt.max_retained]u64 = @splat(0);
        var takes: [excerpt.max_retained]usize = @splat(0);
        var samples: [excerpt.max_retained]excerpt.Seekable = undefined;
        for (streams, 0..) |stream, i| lengths[i] = stream.length;
        excerpt.allot(lengths[0..streams.len], self.window.remaining, takes[0..streams.len]);
        var offset: usize = 0;
        for (streams, 0..) |stream, i| {
            const buffer = self.prefix[offset..][0 .. takes[i] + 7];
            samples[i] = try readFileSample(stream.file, self.host.io, stream.length, takes[i], buffer);
            offset += takes[i] + 7;
            lengths[i] = excerpt.encodedLength(samples[i].head) + excerpt.encodedLength(samples[i].tail);
        }
        excerpt.allot(lengths[0..streams.len], self.window.remaining, takes[0..streams.len]);
        var cuts: [excerpt.max_retained]excerpt.Cut = undefined;
        for (streams, 0..) |_, i| cuts[i] = excerpt.cutSeekable(samples[i], takes[i]);
        var any_cut = false;
        var previous = false;
        for (streams, 0..) |stream, i| {
            if (stream.length == 0) continue;
            if (previous) try self.appendFrame("\n");
            try self.appendFrame(stream.section);
            previous = true;
            var writer: std.Io.Writer = .fixed(self.run[self.run_len..]);
            const sample = samples[i];
            const cut = cuts[i];
            try writeValid(&writer, sample.head[0..cut.head_end]);
            if (cut.truncated) {
                any_cut = true;
                if (cut.head_end != 0 and sample.head[cut.head_end - 1] != '\n') try writer.writeByte('\n');
                try writer.print("[{d} bytes left out]\n", .{cut.left_out});
                const tail = if (sample.head.len == sample.source_length) sample.head else sample.tail;
                try writeValid(&writer, tail[cut.tail_start..]);
            }
            self.run_len += writer.buffered().len;
        }
        if (!any_cut or !self.profile.retain) return;
        var items: [excerpt.max_retained]excerpt.Retained = undefined;
        var count: usize = 0;
        for (streams, 0..) |stream, i| {
            if (!cuts[i].truncated) continue;
            var path: ?[]const u8 = null;
            if (self.profile.retain) {
                self.file_spills[i] = stream.adopt(stream.context);
                if (self.file_spills[i]) |*spill| path = std.fmt.bufPrint(self.prefix[i * std.posix.PATH_MAX ..][0..std.posix.PATH_MAX], "{s}/{s}", .{ self.host.retention.scratch_path, spill.name() }) catch null;
            }
            items[count] = .{ .label = stream.label, .path = path };
            count += 1;
        }
        self.file_advertised = self.profile.retain;
        for (items[0..count]) |item| if (item.path == null) {
            self.file_advertised = false;
        };
        if (!self.file_advertised) {
            for (&self.file_spills) |*spill| if (spill.*) |*value| {
                value.release();
                spill.* = null;
            };
            items[0].path = null;
        }
        self.run_len += (try excerpt.footer(items[0..count], true, self.run[self.run_len..])).len;
    }

    pub fn text(self: *Result) *std.Io.Writer {
        return &self.writer;
    }

    /// Accept one complete image source. `last` means no later content item.
    /// Replayable sources scan before any capture is opened or changed.
    pub noinline fn beginImage(self: *Result, source: intake.Source, last: bool) ImageProgress {
        std.debug.assert(!self.done and !self.attached);
        if (self.files_started) return .{ .failed = .{ .source = error.ResultFilesComplete } };
        self.image_last = last;
        self.image_length = source.length;
        return self.advance(self.image.begin(source, media.Limits{}));
    }

    /// Advances at most one intake window. If scanning reaches ready, attach
    /// in this tick but do not perform an additional intake step.
    pub noinline fn stepImage(self: *Result) ImageProgress {
        return self.advance(self.image.step());
    }

    fn advance(self: *Result, progress: intake.Progress) ImageProgress {
        return switch (progress) {
            .pending => .pending,
            .ready => self.attach(),
            .kept => blk: {
                self.attached = false;
                self.layout.committed(self.image_length);
                self.retainMarker();
                break :blk .kept;
            },
            .failed => |failure| blk: {
                if (self.attached) {
                    self.discardCapture();
                    self.attached = false;
                    break :blk .{ .failed = failure };
                }
                if (failure == .source and fault.classify(failure) == .rejected)
                    break :blk .{ .rejected = .{ .failure = failure } };
                break :blk .{ .failed = failure };
            },
        };
    }

    fn attach(self: *Result) ImageProgress {
        self.layout.run_open = self.run_len != 0 or self.window.run_total != 0;
        switch (self.layout.image(.{
            .length = self.image_length,
            .last = self.image_last,
            .footer_pending = self.profile.retain and self.window.omittedAny(),
        }, media.Limits{})) {
            .refuse => |reason| {
                self.image.cancelReady();
                return .{ .rejected = .{ .reason = reason } };
            },
            .commit => {},
        }
        if (self.capture == null) {
            self.capture = @as(InputCapture, undefined);
            var budget = self.host.retention.sharedBudget();
            budget.reclaim_context = self;
            budget.reclaim_fn = reclaim;
            self.credit = ScratchBudget.Credit.init(budget);
            @import("server_input_scratch.zig").init(self.host, self.action, &self.capture.?, self.credit.?.budget()) catch |err| {
                self.capture = null;
                return .{ .failed = .{ .capture = err } };
            };
        }
        self.closeRun();
        self.flushRun() catch |err| {
            self.discardCapture();
            return .{ .failed = .{ .capture = err } };
        };
        self.attached = true;
        const progress = self.image.attach(&self.capture.?);
        return self.advance(progress);
    }

    fn discardCapture(self: *Result) void {
        if (self.capture) |*capture| capture.close();
        self.capture = null;
    }

    fn closeRun(self: *Result) void {
        self.run_len += self.window.closeRun(self.run[self.run_len..]).len;
    }

    fn flushRun(self: *Result) !void {
        if (self.run_len == 0) return;
        const capture = &self.capture.?;
        try capture.begin(.text, self.run_len);
        var at: usize = 0;
        while (at < self.run_len) {
            var allowance = self.run_len - at;
            at += try capture.append(self.run[at..self.run_len], &allowance, false);
        }
        try capture.end();
        self.run_len = 0;
    }

    fn append(self: *Result, bytes: []const u8) void {
        if (self.profile.retain) {
            // Detect crossing before feeding: the prefix still contains every
            // preceding source byte, including Window's delayed tail.
            if (!self.spill_attempted and bytes.len > self.window.run_limit -| self.window.run_total) self.openSpill();
            if (self.spill_attempted) {
                if (self.spill) |*spill| spill.write(bytes);
            } else {
                std.debug.assert(self.prefix_len + bytes.len <= self.prefix.len);
                @memcpy(self.prefix[self.prefix_len..][0..bytes.len], bytes);
                self.prefix_len += bytes.len;
            }
        }
        const fed = self.window.feed(bytes, self.run[self.run_len..]);
        self.run_len += fed.written;
        if (bytes.len != 0) self.layout.run_open = true;
    }

    fn retainMarker(self: *Result) void {
        if (!self.profile.retain) return;
        const marker = image_marker;
        if (self.spill_attempted) {
            if (self.spill) |*spill| spill.write(marker);
        } else {
            std.debug.assert(self.prefix_len + marker.len <= self.prefix.len);
            @memcpy(self.prefix[self.prefix_len..][0..marker.len], marker);
            self.prefix_len += marker.len;
        }
    }

    fn openSpill(self: *Result) void {
        self.spill_attempted = true;
        var name_buffer: [96]u8 = undefined;
        const name = @import("named_scratch.zig").NumericName.@"mcp-output".format(&name_buffer, self.action, @import("attempt.zig").action_attempt_ordinal) catch return;
        self.spill = retention.Spill.open(self.host.retention, name);
        if (self.spill) |*spill| spill.write(self.prefix[0..self.prefix_len]);
        self.prefix_len = 0;
    }

    fn reclaim(context: *anyopaque, amount: u64, limit: u64) bool {
        const self: *Result = @ptrCast(@alignCast(context));
        if (self.spill) |*spill| _ = spill.yield();
        return self.host.retention.sharedBudget().narrowed(limit).allocate(amount);
    }

    /// Complete the value before settlement; it remains borrowed until destroy.
    /// Call keep() only after successful terminal delivery.
    pub noinline fn finish(self: *Result) Finished {
        std.debug.assert(!self.done and !self.attached);
        self.done = true;
        self.closeRun();
        var path: ?[]const u8 = null;
        const has_footer = self.window.omittedAny() and self.profile.retain;
        if (has_footer) {
            if (self.spill) |*spill| {
                if (spill.alive()) path = std.fmt.bufPrint(&self.path_buffer, "{s}/{s}", .{ self.host.retention.scratch_path, spill.name() }) catch null;
            }
            if (path == null) {
                if (self.spill) |*spill| _ = spill.yield();
            }
            if (self.capture != null) {
                // Reserve only this final text part. A successful reclaim may
                // yield the spill, so choose the footer after reserving.
                const path_footer = excerpt.footer(&.{.{ .label = "output", .path = path }}, true, &self.footer_buffer) catch |err| return .{ .failed = .{ .failure = .{ .capture = err }, .seal = false } };
                const path_len = path_footer.len;
                const footer_len = @max(path_len, excerpt.not_retained.len);
                const required = self.run_len + footer_len + input_parts.Record.byte_length;
                if (!self.credit.?.reserve(required)) {
                    if (self.spill) |*spill| _ = spill.yield();
                    path = null;
                    const fallback = self.run_len + excerpt.not_retained.len + input_parts.Record.byte_length;
                    if (!self.credit.?.reserve(fallback)) return .{ .failed = .{ .failure = .{ .capture = error.ScratchCapacityExceeded }, .seal = false } };
                }
                if (@import("builtin").is_test) if (self.test_reserve_hook) |hook| hook(self);
                if (self.spill) |*spill| {
                    if (!spill.alive()) path = null;
                } else path = null;
            }
            self.advertised = path != null;
            const footer = excerpt.footer(&.{.{ .label = "output", .path = path }}, true, self.run[self.run_len..]) catch |err| return .{ .failed = .{ .failure = .{ .capture = err }, .seal = false } };
            self.run_len += footer.len;
        }
        defer if (self.credit) |*credit| credit.releaseUnused();
        if (self.spill) |*spill| spill.close();
        if (self.capture == null) return .{ .value = .{ .text = self.run[0..self.run_len] } };
        self.flushRun() catch |err| return .{ .failed = .{ .failure = .{ .capture = err }, .seal = false } };
        const loan = self.capture.?.seal() catch |err| return .{ .failed = .{ .failure = .{ .capture = err }, .seal = true } };
        return .{ .value = .{ .parts = loan } };
    }

    pub fn keep(self: *Result) void {
        if (self.advertised) if (self.spill) |*spill| spill.keep();
        if (self.file_advertised) for (&self.file_spills) |*spill| if (spill.*) |*value| value.keep();
    }

    fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Result = @alignCast(@fieldParentPtr("writer", writer));
        if (self.files_started) return error.WriteFailed;
        var count: usize = 0;
        for (parts[0 .. parts.len - 1]) |part| {
            self.append(part);
            count += part.len;
        }
        for (0..splat) |_| {
            self.append(parts[parts.len - 1]);
            count += parts[parts.len - 1].len;
        }
        return count;
    }
};

fn readFileSample(file: std.Io.File, io: std.Io, length: u64, take: usize, buffer: []u8) !excerpt.Seekable {
    if (length <= take) {
        if (try file.readPositionalAll(io, buffer[0..take], 0) != take) return error.ShortCaptureRead;
        return .{ .head = buffer[0..take], .tail = "", .tail_starts_line = true, .source_length = length };
    }
    const head_take = take / 2;
    const head_read: usize = @intCast(@min(length, head_take + 3));
    if (try file.readPositionalAll(io, buffer[0..head_read], 0) != head_read) return error.ShortCaptureRead;
    var head_end: usize = 0;
    while (head_end < head_take) head_end += excerpt.utf8Unit(buffer[0..head_read], head_end).source;
    const tail_take = take - head_take;
    const tail_offset = length - tail_take;
    const context: usize = @intCast(@min(tail_offset, 4));
    const tail = buffer[head_read..][0 .. tail_take + context];
    if (try file.readPositionalAll(io, tail, tail_offset - context) != tail.len) return error.ShortCaptureRead;
    var start: usize = 0;
    while (start < context) {
        const next = start + excerpt.utf8Unit(tail, start).source;
        if (next > context) break;
        start = next;
    }
    return .{ .head = buffer[0..head_end], .tail = tail[start..], .tail_starts_line = if (start == 0) tail_offset - context == 0 else tail[start - 1] == '\n', .source_length = length };
}

fn writeValid(writer: *std.Io.Writer, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const unit = excerpt.utf8Unit(bytes, at);
        if (unit.valid) try writer.writeAll(bytes[at..][0..unit.source]) else try writer.writeAll("�");
        at += unit.source;
    }
}

const TestSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    fn source(self: *TestSource) intake.Source {
        return .{ .length = self.bytes.len, .context = self, .next = next, .rewind = rewind };
    }
    fn next(context: *anyopaque, out: []u8) !usize {
        const self: *TestSource = @ptrCast(@alignCast(context));
        const count = @min(out.len, self.bytes.len - self.offset);
        @memcpy(out[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
    fn rewind(context: *anyopaque) !void {
        const self: *TestSource = @ptrCast(@alignCast(context));
        self.offset = 0;
    }
};

fn testImage(result: *Result, bytes: []const u8, last: bool) ImageProgress {
    var source: TestSource = .{ .bytes = bytes };
    var progress = result.beginImage(source.source(), last);
    while (progress == .pending) progress = result.stepImage();
    return progress;
}

test "result budgets image diagnostics and keeps a later image" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [4]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 1_000_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 10_000, .retain = false });
    defer result.destroy();
    for (0..6) |_| {
        try std.testing.expect(testImage(result, "bad", false) == .rejected);
        try result.text().writeAll("[Image unavailable: invalid base64]");
    }
    var long: [20_000]u8 = @splat('x');
    try result.text().writeAll(&long);
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, true) == .kept);
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .parts);
    var cursor = finished.value.parts.cursor();
    const first = (try cursor.next()).?;
    try std.testing.expect(first.kind == .text);
    const diagnostic = "[Image unavailable: invalid base64]";
    const shown_x = 10_000 - 6 * diagnostic.len;
    var text_bytes: [10_100]u8 = undefined;
    const count: usize = @intCast(first.range.length);
    try std.testing.expectEqual(count, try first.range.file.readPositionalAll(std.testing.io, text_bytes[0..count], first.range.offset));
    for (0..6) |i| try std.testing.expectEqualStrings(diagnostic, text_bytes[i * diagnostic.len ..][0..diagnostic.len]);
    for (text_bytes[6 * diagnostic.len .. 10_000]) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
    var note_buffer: [80]u8 = undefined;
    const note = try std.fmt.bufPrint(&note_buffer, "\n[{d} more bytes not shown]", .{20_000 - shown_x});
    try std.testing.expectEqual(10_000 + note.len, count);
    try std.testing.expectEqualStrings(note, text_bytes[10_000..count]);
    const image = (try cursor.next()).?;
    try std.testing.expect(image.kind == .image);
    try std.testing.expectEqual(@as(u64, png.len), image.range.length);
    var image_bytes: [png.len]u8 = undefined;
    try std.testing.expectEqual(png.len, try image.range.file.readPositionalAll(std.testing.io, &image_bytes, image.range.offset));
    try std.testing.expectEqualSlices(u8, png, &image_bytes);
    try std.testing.expect((try cursor.next()) == null);
}

test "fitting result creates no retained file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 1_000_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 10_000, .retain = true });
    defer result.destroy();
    try result.text().writeAll("complete text");
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .text);
    try std.testing.expectEqualStrings("complete text", finished.value.text);
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "result reserves final part for refusal text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 2_000_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 10_000, .retain = false });
    defer result.destroy();
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    for (0..input_parts.max_parts - 1) |_| try std.testing.expect(testImage(result, png, false) == .kept);
    const refused = testImage(result, png, false);
    try std.testing.expect(refused == .rejected);
    try std.testing.expectEqualStrings("image part limit", refused.rejected.reason);
    try result.text().writeAll("[Image unavailable: image part limit]");
    try std.testing.expect(testImage(result, png, true) == .rejected);
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .parts);
    try std.testing.expectEqual(@as(u32, input_parts.max_parts), finished.value.parts.count);
}

test "result text excerpt is independent of chunk boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 1_000_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 4, .retain = false });
    defer result.destroy();
    try result.text().writeAll("ab\xe2");
    try result.text().writeAll("\x82\xacZ");
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .text);
    try std.testing.expectEqualStrings("ab\n[4 more bytes not shown]", finished.value.text);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "required image capture reclaims optional spill" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 8, .retain = true });
    defer result.destroy();
    const long: [20_000]u8 = @splat('x');
    try result.text().writeAll(&long);
    try std.testing.expect(used.load(.acquire) >= long.len);
    // Tighten before capture is initialized to simulate other owners using the
    // remaining scratch while the optional spill holds the available bytes.
    queue.budget.limit = 1_000;
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, true) == .kept);
    const finished = result.finish();
    // Three index records and the image alone exceed this deliberately tight
    // quota; reclaiming optional output does not make that required cost fit.
    try std.testing.expect(finished == .failed);
    try std.testing.expect(!finished.failed.seal);
    try std.testing.expect(finished.failed.failure == .capture);
    try std.testing.expectEqual(error.ScratchCapacityExceeded, finished.failed.failure.capture);
    try std.testing.expect(result.spill != null and !result.spill.?.alive());
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
}

test "result retained path names complete sanitized output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 3, .retain = true });
    defer result.destroy();
    try result.text().writeAll("abcdef");
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, false) == .kept);
    try result.text().writeAll("tail");
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .parts);
    const spill = &result.spill.?;
    try std.testing.expect(spill.alive());
    var expected_buffer: [std.posix.PATH_MAX + 64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "\n[4 more bytes not shown]\nFull output: {s}/{s}\n", .{ root, spill.name() });
    var cursor = finished.value.parts.cursor();
    _ = (try cursor.next()).?;
    _ = (try cursor.next()).?;
    const tail = (try cursor.next()).?;
    var tail_buffer: [std.posix.PATH_MAX + 128]u8 = undefined;
    const n = try tail.range.file.readPositionalAll(std.testing.io, &tail_buffer, tail.range.offset);
    try std.testing.expectEqualStrings(expected, tail_buffer[0..n]);
    result.keep();
    var output: [128]u8 = undefined;
    var name_buffer: [96]u8 = undefined;
    const file_name = try @import("named_scratch.zig").NumericName.@"mcp-output".format(&name_buffer, 1, @import("attempt.zig").action_attempt_ordinal);
    try std.testing.expectEqualStrings("abcdef[Image]tail", try tmp.dir.readFile(std.testing.io, file_name, &output));
}

test "plain result preserves unavailable-retention footer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 0 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 3, .retain = true });
    defer result.destroy();
    try result.text().writeAll("abcdef");
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .text);
    try std.testing.expectEqualStrings("abc\n[3 more bytes not shown]\nFull output was not retained.\n", finished.value.text);
}

test "final reservation yields spill before choosing footer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 8, .retain = true });
    defer result.destroy();
    const long: [20_000]u8 = @splat('x');
    try result.text().writeAll(&long);
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, true) == .kept);
    const competing = queue.budget.limit - used.load(.acquire) - 1;
    try std.testing.expect(queue.budget.charge(competing));
    defer queue.budget.release(competing);
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .parts);
    try std.testing.expect(!result.advertised);
    try std.testing.expect(!result.spill.?.alive());
    var cursor = finished.value.parts.cursor();
    _ = (try cursor.next()).?;
    _ = (try cursor.next()).?;
    const footer = (try cursor.next()).?;
    var buffer: [128]u8 = undefined;
    const n = try footer.range.file.readPositionalAll(std.testing.io, &buffer, footer.range.offset);
    try std.testing.expectEqualStrings(excerpt.not_retained, buffer[0..n]);
}

test "result accepts exactly the full image part limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 2_000_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 10_000, .retain = false });
    defer result.destroy();
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    for (0..input_parts.max_parts) |i| try std.testing.expect(testImage(result, png, i + 1 == input_parts.max_parts) == .kept);
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .parts);
    try std.testing.expectEqual(@as(u32, input_parts.max_parts), finished.value.parts.count);
    var cursor = finished.value.parts.cursor();
    for (0..input_parts.max_parts) |_| try std.testing.expect((try cursor.next()).?.kind == .image);
    try std.testing.expect((try cursor.next()) == null);
}

test "destroying an unfinished result releases capture and spill" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 3, .retain = true });
    try result.text().writeAll("abcdef");
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, false) == .kept);
    try std.testing.expect(used.load(.acquire) > 0);
    result.destroy();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
}

test "final reservation retries with shorter refusal footer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 3, .retain = true });
    defer result.destroy();
    try result.text().writeAll("abcdef");
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, true) == .kept);
    const spill_charge = result.spill.?.charged;
    var path_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, result.spill.?.name() });
    var footer_buffer: [excerpt.footer_max]u8 = undefined;
    const path_footer = try excerpt.footer(&.{.{ .label = "output", .path = path }}, true, &footer_buffer);
    try std.testing.expect(path_footer.len > excerpt.not_retained.len);
    const fallback = excerpt.not_retained.len + input_parts.Record.byte_length;
    try std.testing.expect(spill_charge < fallback);
    const free_before_yield = fallback - spill_charge;
    const competing = queue.budget.limit - used.load(.acquire) - free_before_yield;
    try std.testing.expect(queue.budget.charge(competing));
    defer queue.budget.release(competing);
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .parts);
    try std.testing.expect(!result.advertised and !result.spill.?.alive());
    var cursor = finished.value.parts.cursor();
    _ = (try cursor.next()).?;
    _ = (try cursor.next()).?;
    const part = (try cursor.next()).?;
    var buffer: [128]u8 = undefined;
    const n = try part.range.file.readPositionalAll(std.testing.io, &buffer, part.range.offset);
    try std.testing.expectEqualStrings(excerpt.not_retained, buffer[0..n]);
}

test "final reservation protects the advertised footer from competing allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 8, .retain = true });
    defer result.destroy();
    const long: [20_000]u8 = @splat('x');
    try result.text().writeAll(&long);
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, true) == .kept);
    result.test_reserve_hook = struct {
        fn compete(value: *Result) void {
            const budget = value.host.retention.budget;
            value.test_competing = budget.limit - budget.used.load(.acquire);
            std.debug.assert(budget.charge(value.test_competing));
        }
    }.compete;
    const finished = result.finish();
    defer queue.budget.release(result.test_competing);
    try std.testing.expect(result.test_competing > 0);
    try std.testing.expect(finished == .value and finished.value == .parts);
    try std.testing.expect(result.advertised and result.spill.?.alive());
}

test "fitting mixed result does not retain output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 100, .retain = true });
    try result.text().writeAll("before");
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, false) == .kept);
    try result.text().writeAll("after");
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .parts);
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    var name_buffer: [96]u8 = undefined;
    const name = try @import("named_scratch.zig").NumericName.@"mcp-output".format(&name_buffer, 1, @import("attempt.zig").action_attempt_ordinal);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, name, .{}));
    try std.testing.expect(used.load(.acquire) > 0);
    result.keep();
    result.destroy();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
}

test "image capture yields optional spill and finishes under contention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 8, .retain = true });
    defer result.destroy();
    const long: [20_000]u8 = @splat('x');
    try result.text().writeAll(&long);
    const competing = queue.budget.limit - used.load(.acquire) - 1;
    try std.testing.expect(queue.budget.charge(competing));
    defer queue.budget.release(competing);
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try std.testing.expect(testImage(result, png, true) == .kept);
    try std.testing.expect(!result.spill.?.alive());
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .parts);
    var cursor = finished.value.parts.cursor();
    const head = (try cursor.next()).?;
    try std.testing.expect(head.kind == .text);
    var text: [128]u8 = undefined;
    const head_len: usize = @intCast(head.range.length);
    try std.testing.expectEqual(head_len, try head.range.file.readPositionalAll(std.testing.io, text[0..head_len], head.range.offset));
    try std.testing.expectEqualStrings("xxxxxxxx\n[19992 more bytes not shown]", text[0..head_len]);
    const image = (try cursor.next()).?;
    try std.testing.expect(image.kind == .image);
    try std.testing.expectEqual(@as(u64, png.len), image.range.length);
    var actual_image: [png.len]u8 = undefined;
    try std.testing.expectEqual(png.len, try image.range.file.readPositionalAll(std.testing.io, &actual_image, image.range.offset));
    try std.testing.expectEqualSlices(u8, png, &actual_image);
    const footer = (try cursor.next()).?;
    try std.testing.expect(footer.kind == .text);
    const footer_len: usize = @intCast(footer.range.length);
    try std.testing.expectEqual(footer_len, try footer.range.file.readPositionalAll(std.testing.io, text[0..footer_len], footer.range.offset));
    try std.testing.expectEqualStrings(excerpt.not_retained, text[0..footer_len]);
    try std.testing.expect((try cursor.next()) == null);
}

const FileTestCapture = struct {
    queue: *retention.Queue,
    name: []const u8,
    file: ?std.Io.File,
    charged: u64,
    calls: usize = 0,
    transferred: bool = false,
    refuse: bool = false,

    fn adopt(context: *anyopaque) ?retention.Spill {
        const self: *FileTestCapture = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.file.?.close(self.queue.io);
        self.file = null;
        if (self.refuse) return null;
        const spill = retention.Spill.adopt(self.queue, self.name, self.charged) orelse return null;
        self.transferred = true;
        return spill;
    }

    fn cleanup(self: *FileTestCapture, dir: std.Io.Dir) void {
        if (self.file) |file| file.close(self.queue.io);
        if (!self.transferred) {
            dir.deleteFile(self.queue.io, self.name) catch unreachable;
            self.queue.budget.release(self.charged);
        }
    }
};

test "file results reject oversized labels before reading or adoption" {
    const Adoption = struct {
        called: bool = false,
        fn adopt(context: *anyopaque) ?retention.Spill {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            return null;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "capture", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "abcdefghijklmnop");
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = undefined };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 4, .retain = true });
    defer result.destroy();
    var first: Adoption = .{};
    var second: Adoption = .{};
    const label: [excerpt.max_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidRetainedLabel, result.files(&.{
        .{ .label = "stdout", .section = "stdout:\n", .file = file, .length = 16, .context = &first, .adopt = Adoption.adopt },
        .{ .label = &label, .section = "stderr:\n", .file = file, .length = 16, .context = &second, .adopt = Adoption.adopt },
    }));
    try std.testing.expectEqual(false, first.called);
    try std.testing.expectEqual(false, second.called);
    try result.frame("still open");
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .text);
    try std.testing.expectEqualStrings("still open", finished.value.text);
}

test "file results frame outside allowance and adopt only cut streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const a = try tmp.dir.createFile(std.testing.io, "a", .{ .read = true });
    try a.writeStreamingAll(std.testing.io, "abcdefghijklmnop");
    const b = try tmp.dir.createFile(std.testing.io, "b", .{ .read = true });
    try b.writeStreamingAll(std.testing.io, "ok");
    try std.testing.expect(queue.budget.charge(18));
    var first: FileTestCapture = .{ .queue = &queue, .name = "a", .file = a, .charged = 16 };
    var second: FileTestCapture = .{ .queue = &queue, .name = "b", .file = b, .charged = 2 };
    defer first.cleanup(tmp.dir);
    defer second.cleanup(tmp.dir);
    {
        const result = try Result.create(&host, 1, .{ .excerpt_bytes = 8, .retain = true });
        errdefer result.destroy();
        try result.frame("header\n");
        try result.files(&.{
            .{ .label = "stdout", .section = "stdout:\n", .file = a, .length = 16, .context = &first, .adopt = FileTestCapture.adopt },
            .{ .label = "stderr", .section = "stderr:\n", .file = b, .length = 2, .context = &second, .adopt = FileTestCapture.adopt },
        });
        try std.testing.expectError(error.ResultFilesComplete, result.frame("late"));
        try std.testing.expectError(error.ResultFilesComplete, result.files(&.{}));
        try std.testing.expectError(error.WriteFailed, result.text().writeAll("late"));
        var image_source: TestSource = .{ .bytes = "image" };
        const image_result = result.beginImage(image_source.source(), true);
        try std.testing.expect(image_result == .failed and image_result.failed == .source and image_result.failed.source == error.ResultFilesComplete);
        const finished = result.finish();
        try std.testing.expect(finished == .value and finished.value == .text);
        const text = finished.value.text;
        const expected = "header\nstdout:\nabc\n[10 bytes left out]\nnop\nstderr:\nok\nFull stdout: ";
        try std.testing.expectEqualStrings(expected, text[0..@min(text.len, expected.len)]);
        try std.testing.expectEqual(@as(usize, 1), first.calls);
        try std.testing.expectEqual(@as(usize, 0), second.calls);
        result.keep();
        result.destroy();
    }
    try std.testing.expectEqual(@as(usize, 1), queue.occupied());
    try std.testing.expectEqual(@as(u64, 18), used.load(.acquire));
}

test "file result falls back and releases adopted output when another transfer fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const a = try tmp.dir.createFile(std.testing.io, "a", .{ .read = true });
    try a.writeStreamingAll(std.testing.io, "abcdefghijklmnop");
    const b = try tmp.dir.createFile(std.testing.io, "b", .{ .read = true });
    try b.writeStreamingAll(std.testing.io, "abcdefghijklmnop");
    try std.testing.expect(queue.budget.charge(32));
    var first: FileTestCapture = .{ .queue = &queue, .name = "a", .file = a, .charged = 16 };
    var second: FileTestCapture = .{ .queue = &queue, .name = "b", .file = b, .charged = 16, .refuse = true };
    defer first.cleanup(tmp.dir);
    defer second.cleanup(tmp.dir);
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 8, .retain = true });
    try result.files(&.{
        .{ .label = "stdout", .section = "stdout:\n", .file = a, .length = 16, .context = &first, .adopt = FileTestCapture.adopt },
        .{ .label = "stderr", .section = "stderr:\n", .file = b, .length = 16, .context = &second, .adopt = FileTestCapture.adopt },
    });
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .text);
    try std.testing.expect(std.mem.endsWith(u8, finished.value.text, excerpt.not_retained));
    try std.testing.expect(std.mem.indexOf(u8, finished.value.text, "Full stdout:") == null);
    try std.testing.expect(first.transferred and !second.transferred);
    try std.testing.expectEqual(@as(u64, 16), used.load(.acquire));
    result.keep();
    result.destroy();
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
}

test "file result keeps capture ownership when retention sequence is exhausted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [1]retention.Entry = @splat(.{});
    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
    defer queue.cleanupAll();
    queue.next_sequence = std.math.maxInt(u64);
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
    const file = try tmp.dir.createFile(std.testing.io, "capture", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "abcdefghijklmnop");
    try std.testing.expect(queue.budget.charge(16));
    var capture: FileTestCapture = .{ .queue = &queue, .name = "capture", .file = file, .charged = 16 };
    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 4, .retain = true });
    try result.files(&.{.{ .label = "stdout", .section = "stdout:\n", .file = file, .length = 16, .context = &capture, .adopt = FileTestCapture.adopt }});
    const finished = result.finish();
    try std.testing.expect(finished == .value and finished.value == .text);
    try std.testing.expect(std.mem.endsWith(u8, finished.value.text, excerpt.not_retained));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(!capture.transferred);
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectEqual(@as(u64, 16), used.load(.acquire));
    const retained_file = try tmp.dir.openFile(std.testing.io, "capture", .{});
    retained_file.close(std.testing.io);
    result.keep();
    result.destroy();
    try std.testing.expectEqual(@as(u64, 16), used.load(.acquire));
    capture.cleanup(tmp.dir);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "capture", .{}));
}

test "file results release unkept output and suppress footer when retention is disabled" {
    for ([_]bool{ false, true }) |retain| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var used: std.atomic.Value(u64) = .init(0);
        var entries: [1]retention.Entry = @splat(.{});
        var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
        defer queue.cleanupAll();
        var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .retention = &queue };
        const file = try tmp.dir.createFile(std.testing.io, "capture", .{ .read = true });
        try file.writeStreamingAll(std.testing.io, "abcdefghijklmnop");
        try std.testing.expect(queue.budget.charge(16));
        var capture: FileTestCapture = .{ .queue = &queue, .name = "capture", .file = file, .charged = 16 };
        defer capture.cleanup(tmp.dir);
        const result = try Result.create(&host, 1, .{ .excerpt_bytes = 4, .retain = retain });
        try result.files(&.{.{ .label = "stdout", .section = "stdout:\n", .file = file, .length = 16, .context = &capture, .adopt = FileTestCapture.adopt }});
        const finished = result.finish();
        try std.testing.expect(finished == .value and finished.value == .text);
        if (!retain) try std.testing.expect(std.mem.indexOf(u8, finished.value.text, "Full output") == null);
        try std.testing.expectEqual(@as(usize, @intFromBool(retain)), capture.calls);
        result.destroy();
        try std.testing.expectEqual(@as(usize, 0), queue.occupied());
        try std.testing.expectEqual(@as(u64, if (retain) 0 else 16), used.load(.acquire));
    }
}
test "file results match base Bash formatter for generated stream pairs" {
    const legacy = @import("bash_result_legacy_test.zig");
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, 24_000);
    defer allocator.free(data);
    const expected = try allocator.alloc(u8, 40_000);
    defer allocator.free(expected);
    for ([_]usize{ 0, 1, 9_999, 10_000, 10_001, 24_000 }) |stdout_len| {
        for ([_]usize{ 0, 3, 9_999, 10_001, 24_000 }) |stderr_len| {
            for (0..4) |pattern| {
                // Paths available, retention disabled, and reservation failure.
                for (0..3) |mode| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var root_buffer: [std.posix.PATH_MAX]u8 = undefined;
                    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
                    var used: std.atomic.Value(u64) = .init(0);
                    var entries: [2]retention.Entry = @splat(.{});
                    var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 100_000 }, &entries);
                    defer queue.cleanupAll();
                    var host: Host = .{ .io = std.testing.io, .allocator = allocator, .lease = undefined, .store = undefined, .retention = &queue };
                    const stdout = try tmp.dir.createFile(std.testing.io, "stdout", .{ .read = true });
                    const stderr = try tmp.dir.createFile(std.testing.io, "stderr", .{ .read = true });
                    const files = [_]std.Io.File{ stdout, stderr };
                    const lengths = [_]usize{ stdout_len, stderr_len };
                    for (files, lengths, 0..) |file, length, stream| {
                        for (data, 0..) |*byte, i| byte.* = switch (pattern) {
                            0 => if (stream == 0) 'x' else 'y',
                            1 => if ((i + stream * 17) % 113 == 0) '\n' else 'z',
                            2 => if ((i + stream) % 7 == 0) 0xff else if (i % 101 == 0) '\n' else 'q',
                            else => ("é🙂\xff\nabc")[(i + stream) % "é🙂\xff\nabc".len],
                        };
                        try file.writeStreamingAll(std.testing.io, data[0..length]);
                    }
                    try std.testing.expect(queue.budget.charge(stdout_len + stderr_len));
                    var first: FileTestCapture = .{ .queue = &queue, .name = "stdout", .file = stdout, .charged = stdout_len, .refuse = mode == 2 };
                    var second: FileTestCapture = .{ .queue = &queue, .name = "stderr", .file = stderr, .charged = stderr_len, .refuse = mode == 2 };
                    defer first.cleanup(tmp.dir);
                    defer second.cleanup(tmp.dir);
                    var oracle: std.Io.Writer = .fixed(expected);
                    try legacy.format(&oracle, files, .{ stdout_len, stderr_len }, root, mode == 0, mode != 1);
                    const result = try Result.create(&host, 1, .{ .excerpt_bytes = 20_000, .retain = mode != 1 });
                    defer result.destroy();
                    try result.frame("Bash succeeded. Exit code: 0.\n");
                    try result.files(&.{
                        .{ .label = "stdout", .section = "stdout:\n", .file = stdout, .length = stdout_len, .context = &first, .adopt = FileTestCapture.adopt },
                        .{ .label = "stderr", .section = "stderr:\n", .file = stderr, .length = stderr_len, .context = &second, .adopt = FileTestCapture.adopt },
                    });
                    const finished = result.finish();
                    try std.testing.expect(finished == .value and finished.value == .text);
                    if (!std.mem.eql(u8, oracle.buffered(), finished.value.text)) {
                        std.debug.print("stream lengths {d}/{d}, pattern {d}, mode {d}\n", .{ stdout_len, stderr_len, pattern, mode });
                        try std.testing.expectEqualStrings(oracle.buffered(), finished.value.text);
                    }
                }
            }
        }
    }
}
