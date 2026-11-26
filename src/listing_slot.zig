const std = @import("std");
const connection = @import("connection.zig");

/// One independent model-listing fetch. Slot 0 is the models.dev catalog; every other slot belongs to the
/// connection at that position of the Host's served table (`slot = 1 + index`), so a listing is keyed by
/// the connection it lists and never by a provider kind.
pub const ListingSlot = enum(u8) {
    catalog = 0,
    _,

    pub const count = 1 + connection.max_served;
    pub const all: [count]ListingSlot = blk: {
        var slots: [count]ListingSlot = undefined;
        for (&slots, 0..) |*slot, index| slot.* = @fromBackingInt(@intCast(index));
        break :blk slots;
    };

    pub fn ofConnection(index: usize) ListingSlot {
        std.debug.assert(index < connection.max_served);
        return @fromBackingInt(@intCast(1 + index));
    }

    /// The served-table position this slot lists, null for the catalog.
    pub fn connectionIndex(self: ListingSlot) ?usize {
        return if (self == .catalog) null else @backingInt(self) - 1;
    }
};

/// A value per listing slot.
pub fn ListingArray(comptime T: type) type {
    return struct {
        values: [ListingSlot.count]T,

        pub fn initFill(value: T) @This() {
            return .{ .values = @splat(value) };
        }

        pub fn get(self: *const @This(), slot: ListingSlot) T {
            return self.values[@backingInt(slot)];
        }

        pub fn getPtr(self: *@This(), slot: ListingSlot) *T {
            return &self.values[@backingInt(slot)];
        }

        pub fn set(self: *@This(), slot: ListingSlot, value: T) void {
            self.values[@backingInt(slot)] = value;
        }
    };
}

test "EXR-102 a listing slot names the catalog or one served-table position, and nothing else" {
    try std.testing.expectEqual(@as(?usize, null), ListingSlot.catalog.connectionIndex());
    try std.testing.expectEqual(connection.max_served + 1, ListingSlot.count);
    try std.testing.expectEqual(ListingSlot.count, ListingSlot.all.len);
    for (0..connection.max_served) |index| {
        const slot = ListingSlot.ofConnection(index);
        try std.testing.expect(slot != .catalog);
        try std.testing.expectEqual(@as(?usize, index), slot.connectionIndex());
        try std.testing.expectEqual(slot, ListingSlot.all[1 + index]);
    }
}
