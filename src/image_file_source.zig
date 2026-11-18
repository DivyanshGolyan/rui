//! Source backed by the descriptor acquired for read_image.
const std = @import("std");
const intake = @import("image_intake.zig");

/// Borrows the opened file; the owner closes it after intake finishes. The
/// descriptor prevents pathname replacement from redirecting the read. Changes
/// that preserve length are not detected as a separate snapshot condition.
pub const FileSource = struct {
    io: std.Io,
    file: std.Io.File,
    length: u64,
    offset: u64 = 0,

    pub fn source(self: *FileSource) intake.Source {
        return .{ .length = self.length, .context = self, .next = next };
    }

    fn next(context: *anyopaque, window: []u8) !usize {
        const self: *FileSource = @ptrCast(@alignCast(context));
        std.debug.assert(window.len != 0);
        const remaining = self.length - self.offset;
        const size: usize = if (remaining == 0) 1 else @intCast(@min(remaining, window.len));
        const count = try self.file.readPositionalAll(self.io, window[0..size], self.offset);
        if ((remaining == 0 and count != 0) or (remaining != 0 and count == 0)) return error.ImageFileChanged;
        self.offset += count;
        return count;
    }
};

test "file source reads the opened descriptor and detects changed length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image", .data = "abcdef" });
    const file = try tmp.dir.openFile(std.testing.io, "image", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try tmp.dir.rename("image", tmp.dir, "original", std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image", .data = "other" });
    var original: FileSource = .{ .io = std.testing.io, .file = file, .length = 6 };
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try FileSource.next(&original, &bytes));
    try std.testing.expectEqualStrings("abcdef", bytes[0..6]);
    try std.testing.expectEqual(@as(usize, 0), try FileSource.next(&original, &bytes));
    var growing: FileSource = .{ .io = std.testing.io, .file = file, .length = 5 };
    try std.testing.expectEqual(@as(usize, 5), try FileSource.next(&growing, &bytes));
    try std.testing.expectError(error.ImageFileChanged, FileSource.next(&growing, &bytes));
    var shrinking: FileSource = .{ .io = std.testing.io, .file = file, .length = 7 };
    try std.testing.expectEqual(@as(usize, 6), try FileSource.next(&shrinking, &bytes));
    try std.testing.expectError(error.ImageFileChanged, FileSource.next(&shrinking, &bytes));
}

test "file intake captures an image over several service windows" {
    const InputCapture = @import("InputCapture.zig");
    const png = @embedFile("codecs/fixtures/image-input/pixel-multi-window.png");
    try std.testing.expect(png.len > 2 * InputCapture.window_bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image.png", .data = png });
    const file = try tmp.dir.openFile(std.testing.io, "image.png", .{});
    defer file.close(std.testing.io);
    const spool = try tmp.dir.createFile(std.testing.io, "spool", .{ .read = true });
    const index = try tmp.dir.createFile(std.testing.io, "index", .{ .read = true });
    var used: std.atomic.Value(u64) = .init(0);
    var capture: InputCapture = undefined;
    capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = png.len + 1024 });
    defer capture.close();
    var file_source: FileSource = .{ .io = std.testing.io, .file = file, .length = png.len };
    var reader: intake.Intake = .{};
    try std.testing.expect(reader.begin(file_source.source(), .{}) == .ready);
    try std.testing.expect(reader.attach(&capture) == .pending);
    try std.testing.expect(reader.step() == .pending);
    try std.testing.expectEqual(@as(u64, InputCapture.window_bytes), file_source.offset);
    try std.testing.expect(reader.step() == .pending);
    try std.testing.expectEqual(@as(u64, 2 * InputCapture.window_bytes), file_source.offset);
    try std.testing.expect(reader.step() == .kept);
    var cursor = (try capture.seal()).cursor();
    const part = (try cursor.next()).?;
    try std.testing.expect(part.kind == .image);
    var bytes: [png.len]u8 = undefined;
    try std.testing.expectEqual(png.len, try part.range.file.readPositionalAll(std.testing.io, &bytes, part.range.offset));
    try std.testing.expectEqualSlices(u8, png, &bytes);
    try std.testing.expect((try cursor.next()) == null);
}
