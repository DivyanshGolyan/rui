//! The tests for Wrappers.zig (deep-modules U10): each wrapper form as a positive, and the
//! near misses as negatives. Expected values are written by hand from the source below.

const std = @import("std");
const Fixture = @import("Fixture.zig");
const Items = @import("Items.zig");
const References = @import("References.zig");
const Wrappers = @import("Wrappers.zig");
const ItemId = Items.ItemId;
const testing = std.testing;

const source =
    \\pub fn target(a: u8, b: u8) u8 { return a + b; }
    \\pub fn fwd(a: u8, b: u8) u8 { return target(a, b); }
    \\pub fn reordered(a: u8, b: u8) u8 { return target(b, a); }
    \\pub fn computed(a: u8, b: u8) u8 { return target(a + 1, b); }
    \\pub fn extra(a: u8, b: u8) u8 { _ = a; return target(a, b); }
    \\pub const Inner = struct {
    \\    v: u8,
    \\    pub fn put(self: *Inner, x: u8) void { self.v = x; }
    \\};
    \\pub const Outer = struct {
    \\    inner: Inner,
    \\    n: u8,
    \\    pub fn put(self: *Outer, x: u8) void { return self.inner.put(x); }
    \\    pub fn wrong(self: *Outer, x: u8) void { return self.inner.put(x + 1); }
    \\    pub fn get(self: *const Outer) u8 { return self.n; }
    \\    pub fn ref(self: *Outer) *u8 { return &self.n; }
    \\    pub fn peek(self: *const Outer) *const u8 { return &self.n; }
    \\    pub fn set(self: *Outer, x: u8) void { self.n = x; }
    \\    pub fn sum(self: *const Outer) u8 { return self.n + 1; }
    \\};
    \\
;

const Found = struct {
    loaded: Fixture.Loaded,
    wrappers: std.AutoHashMapUnmanaged(ItemId, Wrappers.Wrapper),

    fn at(self: *const Found, dotted: []const u8) ?Wrappers.Wrapper {
        return self.wrappers.get(self.loaded.item("src/main.zig", dotted));
    }
};

fn findAll(arena: std.mem.Allocator) !Found {
    const loaded = try Fixture.load(arena, &.{.{ .path = "src/main.zig", .text = source }}, "src/main.zig");
    const refs = try References.collect(arena, &loaded.sources, &loaded.items);
    const wrappers = try Wrappers.find(arena, &loaded.items, &loaded.sources, refs);
    return .{ .loaded = loaded, .wrappers = wrappers };
}

test "a forwarder is a call that passes the parameters in order, with the fields it goes through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try findAll(arena.allocator());

    const plain = found.at("fwd").?.forwarder;
    try testing.expectEqual(found.loaded.item("src/main.zig", "target"), plain.target);
    try testing.expectEqual(@as(usize, 0), plain.fields.len);

    const through = found.at("Outer.put").?.forwarder;
    try testing.expectEqual(found.loaded.item("src/main.zig", "Inner.put"), through.target);
    try testing.expectEqualSlices(ItemId, &.{found.loaded.item("src/main.zig", "Outer.inner")}, through.fields);
}

test "an accessor hands out or writes a field of self: a copy, a borrow, or a write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try findAll(arena.allocator());
    const n = found.loaded.item("src/main.zig", "Outer.n");
    const v = found.loaded.item("src/main.zig", "Inner.v");

    const copied = found.at("Outer.get").?.accessor;
    try testing.expectEqualSlices(ItemId, &.{n}, copied.copied);
    try testing.expectEqual(@as(usize, 0), copied.lent.len);

    const borrowed = found.at("Outer.ref").?.accessor;
    try testing.expectEqualSlices(ItemId, &.{n}, borrowed.lent);
    try testing.expectEqual(false, borrowed.to_read);

    const read_only = found.at("Outer.peek").?.accessor;
    try testing.expectEqualSlices(ItemId, &.{n}, read_only.lent);
    try testing.expectEqual(true, read_only.to_read);

    const setter = found.at("Outer.set").?.accessor;
    try testing.expectEqualSlices(ItemId, &.{n}, setter.lent);

    const inner_setter = found.at("Inner.put").?.accessor;
    try testing.expectEqualSlices(ItemId, &.{v}, inner_setter.lent);
}

test "near misses are no wrapper: extra statement, reordered or computed arguments, computed getter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try findAll(arena.allocator());

    try testing.expectEqual(@as(?Wrappers.Wrapper, null), found.at("reordered"));
    try testing.expectEqual(@as(?Wrappers.Wrapper, null), found.at("computed"));
    try testing.expectEqual(@as(?Wrappers.Wrapper, null), found.at("extra"));
    try testing.expectEqual(@as(?Wrappers.Wrapper, null), found.at("Outer.wrong"));
    try testing.expectEqual(@as(?Wrappers.Wrapper, null), found.at("Outer.sum"));
    try testing.expectEqual(@as(?Wrappers.Wrapper, null), found.at("target"));
}
