//! A bounded visual window over one authenticated Activity page. Global rows
//! remain source-addressed by the page's existing item identity and anchors;
//! only the framework's local row coordinates are limited.
const std = @import("std");
const Self = @This();

total: usize,
limit: u32,
start: usize = 0,

pub fn init(total: usize, limit: u32) Self {
    std.debug.assert(limit != 0);
    return .{ .total = total, .limit = limit };
}

pub fn count(self: Self) u32 {
    if (self.start >= self.total) return 0;
    const remainder = self.total % self.limit;
    if (self.start == 0 and remainder != 0) return @intCast(remainder);
    return @intCast(@min(self.limit, self.total - self.start));
}

pub fn end(self: *Self) void {
    self.start = self.total - @min(self.total, self.limit);
}

pub fn select(self: *Self, row: usize) ?u32 {
    if (row >= self.total) return null;
    const remainder = self.total % self.limit;
    self.start = if (row < remainder) 0 else remainder + ((row - remainder) / self.limit) * self.limit;
    return @intCast(row - self.start);
}

pub fn previous(self: *Self) bool {
    if (self.start == 0) return false;
    self.start -|= self.limit;
    return true;
}

pub fn next(self: *Self) bool {
    const end_row = self.start + self.count();
    if (end_row >= self.total) return false;
    self.start = end_row;
    return true;
}

pub fn global(self: Self, row: usize) ?usize {
    if (row >= self.count()) return null;
    return self.start + row;
}

test "native source row windows cover and seek both sides of u32 without loss" {
    for ([_]usize{ 0, 1, 3, 4, 5, 11, @as(usize, std.math.maxInt(u32)) + 73 }) |total| {
        var window = Self.init(total, 4);
        window.end();
        if (total == 0) {
            try std.testing.expectEqual(@as(u32, 0), window.count());
            try std.testing.expect(!window.previous());
            continue;
        }
        const last = total - 1;
        try std.testing.expectEqual(last, window.global(window.count() - 1).?);
        const before = window.start;
        if (window.previous()) {
            try std.testing.expectEqual(before, window.start + window.count());
            try std.testing.expect(window.next());
            try std.testing.expectEqual(before, window.start);
        }
        for ([_]usize{ 0, total / 2, last }) |row| {
            const local = window.select(row).?;
            try std.testing.expectEqual(row, window.global(local).?);
            try std.testing.expect(window.count() <= 4);
        }
        try std.testing.expectEqual(@as(?u32, null), window.select(total));
    }
}
