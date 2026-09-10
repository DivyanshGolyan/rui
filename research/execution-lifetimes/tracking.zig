const std = @import("std");
pub const Track = struct {
    live: usize = 0,
    peak: usize = 0,
    pub fn allocator(self: *Track) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn add(self: *Track, n: usize) void {
        self.live += n;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ret: usize) ?[*]u8 {
        const p = std.heap.c_allocator.rawAlloc(n, a, ret) orelse return null;
        const self: *Track = @ptrCast(@alignCast(ctx));
        self.add(n);
        return p;
    }
    fn resize(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, ret: usize) bool {
        if (!std.heap.c_allocator.rawResize(b, a, n, ret)) return false;
        const self: *Track = @ptrCast(@alignCast(ctx));
        self.live -= b.len;
        self.add(n);
        return true;
    }
    fn remap(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, ret: usize) ?[*]u8 {
        const p = std.heap.c_allocator.rawRemap(b, a, n, ret) orelse return null;
        const self: *Track = @ptrCast(@alignCast(ctx));
        self.live -= b.len;
        self.add(n);
        return p;
    }
    fn free(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, ret: usize) void {
        const self: *Track = @ptrCast(@alignCast(ctx));
        self.live -= b.len;
        std.heap.c_allocator.rawFree(b, a, ret);
    }
};
