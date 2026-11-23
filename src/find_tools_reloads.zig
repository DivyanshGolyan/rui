//! The Host's table of model `find_tools` reloads waiting on re-lists: one Record per reload Action, keyed by its
//! Action id, held in memory. The pure decisions and reports are in find_tools_reload.zig.

const std = @import("std");
const reload = @import("find_tools_reload.zig");

/// The most reloads the table holds. A reload Action stopped while it waits never settles, so its record is never
/// forgotten; past this many records the oldest is dropped. Dropping is safe: a still-pending reload that finds no
/// record asks again and reports against the newer snapshot.
pub const max_records = 32;

pub const Table = struct {
    /// The highest Action id the Store held when this process started (see `Store.highestActionId`).
    watermark: u64 = 0,
    records: std.AutoHashMapUnmanaged(u64, reload.Record) = .empty,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        var values = self.records.valueIterator();
        while (values.next()) |record| record.arena.deinit();
        self.records.deinit(allocator);
        self.* = .{};
    }

    pub fn find(self: *const Table, action_id: u64) ?*const reload.Record {
        return self.records.getPtr(action_id);
    }

    /// Stores a new record; it takes ownership of the record's arena.
    pub fn remember(self: *Table, allocator: std.mem.Allocator, action_id: u64, record: reload.Record) !void {
        if (self.records.count() >= max_records) {
            var oldest: u64 = std.math.maxInt(u64);
            var keys = self.records.keyIterator();
            while (keys.next()) |key| oldest = @min(oldest, key.*);
            var dropped = self.forget(oldest).?;
            dropped.arena.deinit();
        }
        try self.records.put(allocator, action_id, record);
    }

    /// Removes a settled record and returns it. The caller frees its arena once the report is written.
    pub fn forget(self: *Table, action_id: u64) ?reload.Record {
        const removed = self.records.fetchRemove(action_id) orelse return null;
        return removed.value;
    }
};

test "the table forgets a settled reload once and frees what it held" {
    var table: Table = .{};
    defer table.deinit(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const generations = try arena.allocator().dupe(u64, &.{1});
    try table.remember(std.testing.allocator, 40, .{ .arena = arena, .generations = generations, .before = &.{} });
    try std.testing.expect(table.find(40) != null);
    try std.testing.expect(table.find(41) == null);
    var settled = table.forget(40).?;
    settled.arena.deinit();
    try std.testing.expect(table.forget(40) == null);
}

test "the table holds at most max_records reloads and drops the oldest" {
    var table: Table = .{};
    defer table.deinit(std.testing.allocator);
    for (0..max_records + 3) |index| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        const generations = try arena.allocator().dupe(u64, &.{1});
        try table.remember(std.testing.allocator, 100 + index, .{ .arena = arena, .generations = generations, .before = &.{} });
    }
    try std.testing.expectEqual(@as(u32, max_records), table.records.count());
    for (0..3) |index| try std.testing.expect(table.find(100 + index) == null);
    try std.testing.expect(table.find(100 + max_records + 2) != null);
    try std.testing.expect(table.find(103) != null);
}
