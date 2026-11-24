//! Strongly connected components (deep-modules U11): the sets of nodes in which each
//! reaches every other, by Tarjan's algorithm. It keeps its own stack of frames instead
//! of recursing, so a long chain cannot overflow the thread's stack.

const std = @import("std");
const Allocator = std.mem.Allocator;

const unseen = std.math.maxInt(u32);

/// A node being walked, and how many of its edges are taken.
const Frame = struct { node: u32, edge: u32 };

const Tarjan = struct {
    arena: Allocator,
    edges: []const []const u32,
    index: []u32,
    low: []u32,
    on_stack: []bool,
    stack: std.ArrayList(u32) = .empty,
    work: std.ArrayList(Frame) = .empty,
    next: u32 = 0,
    found: std.ArrayList([]const u32) = .empty,

    fn open(self: *Tarjan, node: u32) Allocator.Error!void {
        self.index[node] = self.next;
        self.low[node] = self.next;
        self.next += 1;
        try self.stack.append(self.arena, node);
        self.on_stack[node] = true;
        try self.work.append(self.arena, .{ .node = node, .edge = 0 });
    }

    fn walk(self: *Tarjan, start: u32) Allocator.Error!void {
        try self.open(start);
        while (self.work.items.len > 0) {
            const top = self.work.items.len - 1;
            const frame = self.work.items[top];
            const out = self.edges[frame.node];
            if (frame.edge < out.len) {
                self.work.items[top].edge += 1;
                const to = out[frame.edge];
                if (self.index[to] == unseen) {
                    try self.open(to);
                } else if (self.on_stack[to]) {
                    self.low[frame.node] = @min(self.low[frame.node], self.index[to]);
                }
                continue;
            }
            _ = self.work.pop();
            if (self.work.items.len > 0) {
                const parent = self.work.items[self.work.items.len - 1].node;
                self.low[parent] = @min(self.low[parent], self.low[frame.node]);
            }
            if (self.low[frame.node] == self.index[frame.node]) try self.pop(frame.node);
        }
    }

    /// Takes the stack down to `root`: that is one component, kept when it has two or more members.
    fn pop(self: *Tarjan, root: u32) Allocator.Error!void {
        var members: std.ArrayList(u32) = .empty;
        while (self.stack.pop()) |member| {
            self.on_stack[member] = false;
            try members.append(self.arena, member);
            if (member == root) break;
        }
        if (members.items.len < 2) return;
        std.mem.sort(u32, members.items, {}, lessU32);
        try self.found.append(self.arena, members.items);
    }
};

fn lessU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

fn lessCircle(_: void, a: []const u32, b: []const u32) bool {
    return std.mem.order(u32, a, b) == .lt;
}

/// Each set of two or more nodes that reach each other, each sorted, the sets sorted by
/// their first node. `edges[node]` are the nodes that `node` reaches in one step; a node
/// that reaches only itself is no set.
pub fn circles(arena: Allocator, edges: []const []const u32) Allocator.Error![]const []const u32 {
    const count = edges.len;
    var state: Tarjan = .{
        .arena = arena,
        .edges = edges,
        .index = try arena.alloc(u32, count),
        .low = try arena.alloc(u32, count),
        .on_stack = try arena.alloc(bool, count),
    };
    @memset(state.index, unseen);
    @memset(state.on_stack, false);
    for (0..count) |start| {
        if (state.index[start] == unseen) try state.walk(@intCast(start));
    }
    std.mem.sort([]const u32, state.found.items, {}, lessCircle);
    return state.found.items;
}

/// A tie by the names of its two members.
pub const Edge = struct { user: []const u8, used: []const u8 };

/// The indexes of the ties of the shortest circle through the first of `ties`, the first
/// first. Of two as short, the cheaper ties come first, as the caller sorted them.
pub fn shortestCircle(arena: Allocator, ties: []const Edge) Allocator.Error![]usize {
    const start = ties[0].user;
    const end = ties[0].used;
    // By member, the tie it was first reached by, going out from `end`.
    var reached: std.StringHashMapUnmanaged(?usize) = .empty;
    try reached.put(arena, end, null);
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.append(arena, end);
    var head: usize = 0;
    while (head < queue.items.len) {
        const at = queue.items[head];
        head += 1;
        if (std.mem.eql(u8, at, start)) break;
        for (ties, 0..) |tie, index| {
            if (!std.mem.eql(u8, tie.user, at) or reached.contains(tie.used)) continue;
            try reached.put(arena, tie.used, index);
            try queue.append(arena, tie.used);
        }
    }
    var circle: std.ArrayList(usize) = .empty;
    var at = start;
    while (reached.get(at)) |found| {
        const index = found orelse break;
        try circle.append(arena, index);
        at = ties[index].user;
    }
    try circle.append(arena, 0);
    std.mem.reverse(usize, circle.items);
    return circle.items;
}

const testing = std.testing;

fn expectCircles(expected: []const []const u32, edges: []const []const u32) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try circles(arena.allocator(), edges);
    try testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| try testing.expectEqualSlices(u32, want, got);
}

test "a ring is one circle" {
    try expectCircles(&.{&.{ 0, 1, 2 }}, &.{ &.{1}, &.{2}, &.{0} });
}

test "a chord inside a ring keeps one circle, and a node the ring only leads to is left out" {
    // 0 -> 1 -> 2 -> 0, 0 -> 2 is a chord, 2 -> 3 leads out of the ring.
    try expectCircles(&.{&.{ 0, 1, 2 }}, &.{ &.{ 1, 2 }, &.{2}, &.{ 0, 3 }, &.{} });
}

test "two separate circles are both found, and a one-way edge joins neither" {
    // 0 <-> 1, 2 <-> 3, and 1 -> 2 which is one way only.
    try expectCircles(&.{ &.{ 0, 1 }, &.{ 2, 3 } }, &.{ &.{1}, &.{ 0, 2 }, &.{3}, &.{2} });
}

test "a self-loop makes no circle" {
    try expectCircles(&.{}, &.{ &.{0}, &.{} });
    try expectCircles(&.{}, &.{ &.{ 0, 1 }, &.{1} });
}

test "each circle of deslop's graph test is found and the rest left out" {
    // 0 -> 1 -> 2 -> 0, 2 -> 3, 3 -> 4 -> 3, 5 alone.
    try expectCircles(&.{ &.{ 0, 1, 2 }, &.{ 3, 4 } }, &.{ &.{1}, &.{2}, &.{ 0, 3 }, &.{4}, &.{3}, &.{} });
}

test "a ring of ten thousand nodes is one circle, found without recursion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const count = 10_000;
    const edges = try arena.allocator().alloc([]const u32, count);
    for (edges, 0..) |*slot, node| {
        const next: u32 = @intCast((node + 1) % count);
        slot.* = try arena.allocator().dupe(u32, &.{next});
    }
    const found = try circles(arena.allocator(), edges);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(usize, count), found[0].len);
}

fn pairOf(user: []const u8, used: []const u8) Edge {
    return .{ .user = user, .used = used };
}

fn expectCircle(want: []const usize, edges: []const Edge) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try shortestCircle(arena.allocator(), edges);
    try testing.expectEqualSlices(usize, want, got);
}

test "the shortest circle through the first tie of the cheapest: a ring" {
    try expectCircle(&.{ 0, 1, 2 }, &.{ pairOf("a", "b"), pairOf("b", "c"), pairOf("c", "a") });
}

test "the shortest circle through the first tie takes a chord back" {
    try expectCircle(&.{ 0, 3 }, &.{ pairOf("a", "b"), pairOf("b", "c"), pairOf("c", "a"), pairOf("b", "a") });
}

test "of two circles, the shorter one is drawn" {
    try expectCircle(&.{ 0, 1, 4 }, &.{
        pairOf("a", "b"), pairOf("b", "d"), pairOf("b", "c"), pairOf("c", "a"), pairOf("d", "a"),
    });
}
