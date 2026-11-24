//! Test fixtures for the deep-modules units: in-memory source files loaded through the
//! real pipeline (Sources, Items), so a test names a declaration by its file and dotted path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Items = @import("Items.zig");
const Sources = @import("Sources.zig");
const FileId = Sources.FileId;
const ItemId = Items.ItemId;

pub const Loaded = struct {
    sources: Sources,
    items: Items.Items,

    pub fn file(self: *const Loaded, path: []const u8) FileId {
        return self.sources.findFile(path).?;
    }

    /// The item at `dotted` (for example `Holder.Inner`) in the file at `file_path`; the file's own item for "".
    pub fn item(self: *const Loaded, file_path: []const u8, dotted: []const u8) ItemId {
        var current = self.items.files[@backingInt(self.file(file_path))];
        if (dotted.len == 0) return current;
        var parts = std.mem.splitScalar(u8, dotted, '.');
        while (parts.next()) |part| current = Items.lookup(&self.items, current, part).?;
        return current;
    }
};

pub fn load(arena: Allocator, entries: []const Sources.Memory.Entry, root: []const u8) !Loaded {
    const memory: Sources.Memory = .{ .entries = entries };
    var failure: Sources.Failure = .{};
    const sources = try Sources.load(arena, memory.reader(), root, &.{}, &failure);
    const items = try Items.collect(arena, &sources);
    return .{ .sources = sources, .items = items };
}
