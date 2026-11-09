//! Bounded semantic catalog preview. No paths, bodies or persistent registry.
const std = @import("std");
pub const capacity: usize = 24;
pub const Scope = union(enum) { session: []const u8, workspace: []const u8 };
pub const Entry = struct { name: []const u8, description: []const u8 };
pub const Page = struct {
    entries: []const Entry = &.{},
    revision: u64 = 0,
    total: usize = 0,

    /// The supplied allocator owns every string and the outer slice.
    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.description);
        }
        allocator.free(self.entries);
        self.* = .{};
    }
};
