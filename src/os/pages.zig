//! Fresh anonymous pages: zero, resident only once written, and returned to
//! the kernel when unmapped.

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

test "a mapped value starts zero and its pages return at unmap" {
    const Scratch = struct { window: [64 * 1024]u8, count: usize };
    const mapped = try Mapped(Scratch).map();
    try std.testing.expectEqual(@as(usize, 0), mapped.value.count);
    try std.testing.expect(std.mem.allEqual(u8, &mapped.value.window, 0));
    mapped.value.window[mapped.value.window.len - 1] = 1;
    mapped.unmap();
    try std.testing.expectEqual(@as(usize, 0), (try mapZeroed(Scratch, 0)).len);
}
