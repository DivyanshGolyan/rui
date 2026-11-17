//! Bounded image validation and copying into an ordered input capture.
const std = @import("std");
const InputCapture = @import("InputCapture.zig");
const media = @import("input_media.zig");
const Failure = @import("result_fault.zig").Failure;

/// The context and its bytes remain alive and at stable addresses until intake
/// finishes. A replayable source promises identical bytes on both passes.
/// `next` fills at most window.len bytes; zero means EOF, never a transient
/// lack of progress. The window is nonempty and is borrowed only for the call.
/// A null rewind denotes a streamed source; rewind resets to the beginning.
pub const Source = struct {
    length: u64,
    format: ?media.Format = null,
    context: *anyopaque,
    next: *const fn (*anyopaque, []u8) anyerror!usize,
    rewind: ?*const fn (*anyopaque) anyerror!void = null,
};

pub const Progress = union(enum) {
    pending,
    /// Validation is complete for replayable sources, or size preflight is
    /// complete for streams. The caller may now open and prepare the capture.
    ready,
    kept,
    failed: Failure,
};

pub const Intake = struct {
    source: Source = undefined,
    scanner: media.Scanner = undefined,
    window: [InputCapture.window_bytes]u8 = undefined,
    offset: u64 = 0,
    capture: ?*InputCapture = null,
    phase: enum { idle, scan, ready, copy, done } = .idle,

    /// Does no I/O or capture allocation; call before opening scratch files.
    pub fn begin(self: *Intake, source: Source, limits: media.Limits) Progress {
        std.debug.assert(self.phase == .idle or self.phase == .done);
        self.source = source;
        self.offset = 0;
        self.capture = null;
        self.scanner = media.Scanner.init(source.length, source.format, limits) catch |err| {
            self.phase = .done;
            return .{ .failed = .{ .source = err } };
        };
        self.phase = if (source.rewind == null) .ready else .scan;
        return if (self.phase == .ready) .ready else .pending;
    }

    /// Discard a preflighted source when layout cannot admit another image.
    pub fn cancelReady(self: *Intake) void {
        std.debug.assert(self.phase == .ready);
        self.phase = .done;
    }

    /// Starts the image part after the caller has written any preceding parts.
    /// A failure makes the capture unusable, as with InputCapture.begin.
    pub fn attach(self: *Intake, capture: *InputCapture) Progress {
        std.debug.assert(self.phase == .ready);
        capture.begin(.{ .image = .{ .assertion = self.source.format } }, self.source.length) catch |err| {
            self.phase = .done;
            return .{ .failed = .{ .capture = err } };
        };
        self.capture = capture;
        self.phase = .copy;
        return .pending;
    }

    /// Advances at most one 2 KiB payload window plus a one-byte EOF probe.
    /// The attached capture must remain alive at a stable address until done.
    pub fn step(self: *Intake) Progress {
        std.debug.assert(self.phase == .scan or self.phase == .copy);
        const remaining = self.source.length - self.offset;
        if (remaining != 0) {
            const limit: usize = @intCast(@min(remaining, self.window.len));
            const count = self.source.next(self.source.context, self.window[0..limit]) catch |err| return self.fail(.{ .source = err });
            if (count == 0 or count > limit) return self.fail(.{ .source = error.ContentChanged });
            if (self.phase == .scan) {
                var allowance = count;
                _ = self.scanner.advance(self.window[0..count], &allowance) catch |err| return self.fail(.{ .source = err });
            } else {
                var allowance = count;
                const written = self.capture.?.append(self.window[0..count], &allowance, false) catch |err| return self.fail(.{ .capture = err });
                std.debug.assert(written == count);
            }
            self.offset += count;
            if (self.offset != self.source.length) return .pending;
        }
        const extra = self.source.next(self.source.context, self.window[0..1]) catch |err| return self.fail(.{ .source = err });
        if (extra != 0) return self.fail(.{ .source = error.ContentChanged });
        if (self.phase == .scan) {
            _ = self.scanner.finish() catch |err| return self.fail(.{ .source = err });
            self.source.rewind.?(self.source.context) catch |err| return self.fail(.{ .source = err });
            self.offset = 0;
            self.phase = .ready;
            return .ready;
        }
        self.capture.?.end() catch |err| return self.fail(.{ .capture = err });
        self.phase = .done;
        return .kept;
    }

    fn fail(self: *Intake, failure: Failure) Progress {
        self.phase = .done;
        return .{ .failed = failure };
    }
};

const TestSource = struct {
    bytes: []const u8,
    at: usize = 0,
    calls: usize = 0,
    max_read: usize = InputCapture.window_bytes,
    failure: ?anyerror = null,

    fn source(self: *TestSource, replayable: bool) Source {
        return .{ .length = self.bytes.len, .context = self, .next = next, .rewind = if (replayable) rewind else null };
    }
    fn next(context: *anyopaque, window: []u8) !usize {
        const self: *TestSource = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.failure) |err| return err;
        const count = @min(window.len, self.max_read, self.bytes.len - self.at);
        @memcpy(window[0..count], self.bytes[self.at..][0..count]);
        self.at += count;
        return count;
    }
    fn rewind(context: *anyopaque) !void {
        const self: *TestSource = @ptrCast(@alignCast(context));
        self.at = 0;
    }
};

fn testCapture(capture: *InputCapture, dir: std.Io.Dir, used: *std.atomic.Value(u64), limit: u64) !void {
    const spool = try dir.createFile(std.testing.io, "spool", .{ .read = true });
    errdefer spool.close(std.testing.io);
    const index = try dir.createFile(std.testing.io, "index", .{ .read = true });
    errdefer index.close(std.testing.io);
    capture.init(std.testing.io, spool, index, .{ .used = used, .limit = limit });
}

test "replayable intake validates before capture and preserves preceding parts" {
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    var source: TestSource = .{ .bytes = png };
    var intake: Intake = .{};
    try std.testing.expect(intake.begin(source.source(true), .{}) == .pending);
    try std.testing.expect(intake.step() == .ready);
    try std.testing.expectEqual(@as(usize, 0), source.at);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used: std.atomic.Value(u64) = .init(0);
    var capture: InputCapture = undefined;
    try testCapture(&capture, tmp.dir, &used, 4096);
    defer capture.close();
    try capture.begin(.text, 1);
    var allowance: usize = 1;
    _ = try capture.append("x", &allowance, false);
    try capture.end();
    try std.testing.expect(intake.attach(&capture) == .pending);
    try std.testing.expect(intake.step() == .kept);
    var cursor = (try capture.seal()).cursor();
    try std.testing.expect((try cursor.next()).?.kind == .text);
    const image = (try cursor.next()).?;
    try std.testing.expect(image.kind == .image);
    var actual: [png.len]u8 = undefined;
    try std.testing.expectEqual(png.len, try image.range.file.readPositionalAll(std.testing.io, &actual, image.range.offset));
    try std.testing.expectEqualSlices(u8, png, &actual);
    try std.testing.expect((try cursor.next()) == null);
}

test "intake rejects invalid replayable and oversized images before capture" {
    var source: TestSource = .{ .bytes = "not an image" };
    var intake: Intake = .{};
    try std.testing.expect(intake.begin(source.source(true), .{}) == .pending);
    const invalid = intake.step();
    try std.testing.expect(invalid == .failed);
    try std.testing.expect(invalid.failed == .source);
    try std.testing.expectEqual(error.UnsupportedImage, invalid.failed.source);
    var too_large = source.source(false);
    too_large.length = 100;
    try std.testing.expect(intake.begin(too_large, .{ .max_bytes = 99 }) == .failed);
}

test "intake preserves source and capture failure origins" {
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    var source: TestSource = .{ .bytes = png, .failure = error.NoSpaceLeft };
    var intake: Intake = .{};
    try std.testing.expect(intake.begin(source.source(false), .{}) == .ready);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used: std.atomic.Value(u64) = .init(0);
    var capture: InputCapture = undefined;
    try testCapture(&capture, tmp.dir, &used, 4096);
    defer capture.close();
    var vtable = std.testing.io.vtable.*;
    vtable.fileWritePositional = struct {
        fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
            return error.NoSpaceLeft;
        }
    }.write;
    try std.testing.expect(intake.attach(&capture) == .pending);
    const source_failure = intake.step();
    try std.testing.expect(source_failure == .failed and source_failure.failed == .source);
    try std.testing.expectEqual(error.NoSpaceLeft, source_failure.failed.source);
    capture.close();
    try testCapture(&capture, tmp.dir, &used, 4096);
    capture.io.vtable = &vtable;
    source.failure = null;
    try std.testing.expect(intake.begin(source.source(false), .{}) == .ready);
    try std.testing.expect(intake.attach(&capture) == .pending);
    const capture_failure = intake.step();
    try std.testing.expect(capture_failure == .failed and capture_failure.failed == .capture);
    try std.testing.expectEqual(error.NoSpaceLeft, capture_failure.failed.capture);
}

test "stream intake advances by one bounded read per step" {
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    var source: TestSource = .{ .bytes = png, .max_read = 1 };
    var intake: Intake = .{};
    try std.testing.expect(intake.begin(source.source(false), .{}) == .ready);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used: std.atomic.Value(u64) = .init(0);
    var capture: InputCapture = undefined;
    try testCapture(&capture, tmp.dir, &used, 4096);
    defer capture.close();
    try std.testing.expect(intake.attach(&capture) == .pending);
    for (0..png.len - 1) |_| {
        const before = source.calls;
        try std.testing.expect(intake.step() == .pending);
        try std.testing.expectEqual(before + 1, source.calls);
    }
    try std.testing.expect(intake.step() == .kept);
    try std.testing.expectEqual(@as(usize, png.len + 1), source.calls);
    _ = try capture.seal();
}

test "intake can decline a ready image before beginning another" {
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    var source: TestSource = .{ .bytes = png };
    var intake: Intake = .{};
    try std.testing.expect(intake.begin(source.source(true), .{}) == .pending);
    try std.testing.expect(intake.step() == .ready);
    intake.cancelReady();
    try std.testing.expect(intake.begin(source.source(false), .{}) == .ready);
    intake.cancelReady();
}
