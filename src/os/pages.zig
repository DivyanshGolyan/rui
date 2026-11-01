//! Fresh anonymous pages: zero, resident only once written, and returned to
//! the kernel when unmapped; and a file's bytes mapped read-only.

const std = @import("std");

/// Returns `count` items in fresh anonymous pages: every byte is zero and no
/// page is resident until first written. Allocator.alloc promises neither,
/// because ReleaseSafe fills new memory with 0xAA and an init loop writes
/// every page, so callers whose empty state is all zero bytes use this.
pub fn mapZeroed(comptime T: type, count: usize) ![]T {
    if (count == 0) return &.{};
    const bytes = try std.posix.mmap(
        null,
        try std.math.mul(usize, @sizeOf(T), count),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    return @as([*]T, @ptrCast(@alignCast(bytes.ptr)))[0..count];
}

/// Returns the pages to the kernel.
pub fn unmapZeroed(items: anytype) void {
    if (items.len == 0) return;
    std.posix.munmap(@alignCast(std.mem.sliceAsBytes(items)));
}

/// One zeroed `T` in its own pages, for rare work: mapped where the call
/// starts and unmapped where it returns, so its pages leave Private_Dirty when
/// the call ends. Recurring single-instance engine work belongs in the engine
/// `Workspace` instead, and per-request work in its exchange's heap objects.
pub fn Mapped(comptime T: type) type {
    return struct {
        value: *T,

        pub fn map() !@This() {
            return .{ .value = &(try mapZeroed(T, 1))[0] };
        }

        pub fn unmap(self: @This()) void {
            unmapZeroed(@as(*[1]T, self.value));
        }
    };
}

/// The first `length` bytes of `file`, mapped read-only and shared: the
/// pages are the file's page cache, so no second copy is made. Pages written
/// but not yet written back show as Private_Dirty while mapped, and clean
/// once written back. A file shorter than `length` is `error.FileShorter`,
/// since a mapped byte past its end would fault. Borrowed until
/// `unmapReadOnly`.
pub fn mapReadOnly(io: std.Io, file: std.Io.File, length: u64) ![]align(std.heap.page_size_min) const u8 {
    if (length == 0) return &.{};
    if (try file.length(io) < length) return error.FileShorter;
    const count = std.math.cast(usize, length) orelse return error.FileTooBig;
    return std.posix.mmap(null, count, .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0);
}

pub fn unmapReadOnly(bytes: []align(std.heap.page_size_min) const u8) void {
    if (bytes.len != 0) std.posix.munmap(bytes);
}

test "a mapped value starts zero and its pages return at unmap" {
    const Scratch = struct { window: [64 * 1024]u8, count: usize };
    const mapped = try Mapped(Scratch).map();
    try std.testing.expectEqual(@as(usize, 0), mapped.value.count);
    try std.testing.expect(std.mem.allEqual(u8, &mapped.value.window, 0));
    mapped.value.window[mapped.value.window.len - 1] = 1;
    mapped.unmap();
    try std.testing.expectEqual(@as(usize, 0), (try mapZeroed(Scratch, 0)).len);
}

test "a file maps read-only as its bytes, and an empty length maps nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "body", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "0123456789");
    const bytes = try mapReadOnly(std.testing.io, file, 4);
    defer unmapReadOnly(bytes);
    try std.testing.expectEqualStrings("0123", bytes);
    const empty = try mapReadOnly(std.testing.io, file, 0);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    unmapReadOnly(empty);
    try std.testing.expectError(error.FileShorter, mapReadOnly(std.testing.io, file, 11));
}
