//! Keyed containers over connection names, bounded by the served set's size.
//! They hold no provider knowledge: a name is a key, nothing more.

const std = @import("std");
const connection = @import("connection.zig");
const max_served = connection.max_served;

/// A bounded set of connection names: at most `max_served`, each once. The
/// keyed container for anything a Host serves, in place of an enum set.
pub const NameSet = struct {
    names: [max_served]connection.Name = undefined,
    len: usize = 0,

    pub fn insert(self: *NameSet, name: connection.Name) error{ServedFull}!void {
        if (self.contains(name)) return;
        if (self.len == max_served) return error.ServedFull;
        self.names[self.len] = name;
        self.len += 1;
    }

    pub fn contains(self: *const NameSet, name: connection.Name) bool {
        for (self.slice()) |*one| if (one.eql(name)) return true;
        return false;
    }

    pub fn slice(self: *const NameSet) []const connection.Name {
        return self.names[0..self.len];
    }

    pub fn unionWith(self: *NameSet, other: *const NameSet) error{ServedFull}!void {
        for (other.slice()) |name| try self.insert(name);
    }

    /// The set holding exactly these names, for fixtures and the built-in set.
    pub fn of(names: []const connection.Name) NameSet {
        var set: NameSet = .{};
        for (names) |name| set.insert(name) catch unreachable;
        return set;
    }
};

/// A bounded map from connection name to a value, at most `max_served` names.
/// Looked up by name; an absent name has no value.
pub fn NameArray(comptime T: type) type {
    return struct {
        const Self = @This();

        names: [max_served]connection.Name = undefined,
        values: [max_served]T = undefined,
        len: usize = 0,

        pub fn set(self: *Self, name: connection.Name, value: T) error{ServedFull}!void {
            for (self.names[0..self.len], 0..) |*one, index| {
                if (one.eql(name)) {
                    self.values[index] = value;
                    return;
                }
            }
            if (self.len == max_served) return error.ServedFull;
            self.names[self.len] = name;
            self.values[self.len] = value;
            self.len += 1;
        }

        /// The stored value for a name, by pointer, so a large value is not copied.
        pub fn find(self: *const Self, name: connection.Name) ?*const T {
            for (self.names[0..self.len], 0..) |*one, index| if (one.eql(name)) return &self.values[index];
            return null;
        }

        pub fn get(self: *const Self, name: connection.Name) ?T {
            for (self.names[0..self.len], self.values[0..self.len]) |*one, value| {
                if (one.eql(name)) return value;
            }
            return null;
        }
    };
}

test "NameSet and NameArray key by exact name within the served bound" {
    var set: NameSet = .{};
    try set.insert(connection.Name.parse("alpha").?);
    try set.insert(connection.Name.parse("alpha").?);
    try std.testing.expectEqual(@as(usize, 1), set.slice().len);
    try std.testing.expect(set.contains(connection.Name.parse("alpha").?));
    try std.testing.expect(!set.contains(connection.Name.parse("alph").?));
    var full: NameSet = .{};
    var buffer: [max_served + 1][4]u8 = undefined;
    for (0..max_served) |index| try full.insert(connection.Name.parse(std.fmt.bufPrint(&buffer[index], "c{d}", .{index}) catch unreachable).?);
    try std.testing.expectError(error.ServedFull, full.insert(connection.Name.parse("extra").?));

    var array: NameArray(u8) = .{};
    try array.set(connection.Name.parse("alpha").?, 1);
    try array.set(connection.Name.parse("beta").?, 2);
    try array.set(connection.Name.parse("alpha").?, 3);
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqual(@as(?u8, 3), array.get(connection.Name.parse("alpha").?));
    try std.testing.expectEqual(@as(?u8, null), array.get(connection.Name.parse("openai").?));
}
