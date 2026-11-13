//! Bounded credential storage and header-safe value validation.
const std = @import("std");

/// The longest key Rui accepts. OpenAI keys are about 170 bytes.
pub const max_key_bytes = 1024;

/// One key, held for a Host's life in its caller's storage.
pub const Key = struct {
    bytes: [max_key_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Key) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn wipe(self: *Key) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }
};

/// Visible ASCII only, so the key is a valid header value as it stands.
pub fn valid(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key_bytes) return false;
    for (key) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

test "a key is visible ASCII within its bound" {
    try std.testing.expect(valid("sk-proj-abc_DEF-123"));
    for ([_][]const u8{ "", "sk abc", "sk\tabc", "sk\x7f", "sk\xc3\xa9" }) |bad| try std.testing.expect(!valid(bad));
    try std.testing.expect(valid(&@as([max_key_bytes]u8, @splat('k'))));
    try std.testing.expect(!valid(&@as([max_key_bytes + 1]u8, @splat('k'))));
}

test "key wipe clears the whole storage and length" {
    var key: Key = .{ .bytes = @splat(0xa5), .len = 3 };
    @memcpy(key.bytes[0..3], "key");
    try std.testing.expectEqualStrings("key", key.slice());
    key.wipe();
    try std.testing.expectEqual(@as(usize, 0), key.len);
    try std.testing.expectEqualStrings("", key.slice());
    try std.testing.expectEqualSlices(u8, &@as([max_key_bytes]u8, @splat(0)), &key.bytes);
}

test "key validation checks every byte against visible ASCII" {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        try std.testing.expectEqual(value >= 0x21 and value <= 0x7e, valid(&.{byte}));
    }
}

/// Wipes every backing allocation before freeing; temporary arenas never move.
pub const WipingAllocator = struct {
    backing: std.mem.Allocator,

    pub fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, ret);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, bytes);
        self.backing.rawFree(bytes, alignment, ret);
    }
};

test "wiping arenas erase full backing blocks before release" {
    const Observer = struct {
        child: std.mem.Allocator,
        frees: usize = 0,
        all_zero: bool = true,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.child.rawAlloc(len, alignment, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.frees += 1;
            for (bytes) |byte| if (byte != 0) {
                self.all_zero = false;
            };
            self.child.rawFree(bytes, alignment, ret);
        }
    };
    var observer: Observer = .{ .child = std.testing.allocator };
    var wiping: WipingAllocator = .{ .backing = observer.allocator() };
    var arena: std.heap.ArenaAllocator = .init(wiping.allocator());
    const secret = try arena.allocator().dupe(u8, "secret allocated inside a larger backing block");
    try std.testing.expect(secret.len > 0);
    arena.deinit();
    try std.testing.expect(observer.frees > 0);
    try std.testing.expect(observer.all_zero);
}
