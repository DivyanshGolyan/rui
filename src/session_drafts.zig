//! Process-local, sparse drafts. Only non-empty inactive chats own storage;
//! taking a draft transfers its exact-length bytes to the caller.
const std = @import("std");
const session_id = @import("session_id.zig");

pub const Draft = struct {
    bytes: []u8,
    cursor: usize,

    pub fn deinit(self: Draft, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }
};

pub const Drafts = struct {
    // One small node per non-empty draft, no retained capacity for empty chats.
    first: ?*Node = null,

    const Node = struct {
        id: [session_id.bytes]u8,
        draft: Draft,
        next: ?*Node,
    };

    pub fn deinit(self: *Drafts, gpa: std.mem.Allocator) void {
        while (self.first) |node| {
            self.first = node.next;
            node.draft.deinit(gpa);
            gpa.destroy(node);
        }
    }

    /// Copies an editor's bytes. Replacement is atomic on allocation failure;
    /// an empty composition removes the entry and frees all its storage.
    pub fn put(self: *Drafts, gpa: std.mem.Allocator, id: []const u8, bytes: []const u8, cursor: usize) !void {
        std.debug.assert(session_id.valid(id));
        std.debug.assert(cursor <= bytes.len);
        if (bytes.len == 0) {
            if (self.take(gpa, id)) |draft| draft.deinit(gpa);
            return;
        }
        const copy = try gpa.dupe(u8, bytes);
        errdefer gpa.free(copy);
        const draft: Draft = .{ .bytes = copy, .cursor = cursor };
        var next = &self.first;
        while (next.*) |node| : (next = &node.next) {
            if (std.mem.eql(u8, &node.id, id)) {
                node.draft.deinit(gpa);
                node.draft = draft;
                return;
            }
        }
        const node = try gpa.create(Node);
        node.* = .{ .id = id[0..session_id.bytes].*, .draft = draft, .next = null };
        next.* = node;
    }

    /// Removes the saved draft; the caller owns the returned bytes.
    pub fn take(self: *Drafts, gpa: std.mem.Allocator, id: []const u8) ?Draft {
        var next = &self.first;
        while (next.*) |node| : (next = &node.next) {
            if (std.mem.eql(u8, &node.id, id)) {
                next.* = node.next;
                const draft = node.draft;
                gpa.destroy(node);
                return draft;
            }
        }
        return null;
    }
};

test "session_drafts put take replace and empty release only their Session's bytes" {
    const gpa = std.testing.allocator;
    var drafts: Drafts = .{};
    defer drafts.deinit(gpa);
    const cases = [_]struct { id: []const u8, bytes: []const u8, cursor: usize }{
        .{ .id = "aaaaaa", .bytes = "first\nα", .cursor = 6 },
        .{ .id = "bbbbbb", .bytes = "other", .cursor = 0 },
        .{ .id = "aaaaaa", .bytes = "replaced", .cursor = 3 },
        .{ .id = "cccccc", .bytes = "", .cursor = 0 },
        .{ .id = "bbbbbb", .bytes = "", .cursor = 0 },
    };
    for (cases) |case| try drafts.put(gpa, case.id, case.bytes, case.cursor);
    try std.testing.expect(drafts.take(gpa, "bbbbbb") == null);
    try std.testing.expect(drafts.take(gpa, "cccccc") == null);
    const taken = drafts.take(gpa, "aaaaaa").?;
    defer taken.deinit(gpa);
    try std.testing.expectEqualStrings("replaced", taken.bytes);
    try std.testing.expectEqual(@as(usize, 3), taken.cursor);
    try std.testing.expect(drafts.take(gpa, "aaaaaa") == null);
    try std.testing.expect(drafts.first == null);
    // The store owns a copy, not the editor's borrowed buffer.
    var bytes = [_]u8{ 'o', 'k' };
    try drafts.put(gpa, "aaaaaa", &bytes, 1);
    bytes[0] = 'X';
    const copied = drafts.take(gpa, "aaaaaa").?;
    defer copied.deinit(gpa);
    try std.testing.expectEqualStrings("ok", copied.bytes);
}

test "session_drafts allocation failure keeps the previous draft" {
    const gpa = std.testing.allocator;
    var drafts: Drafts = .{};
    defer drafts.deinit(gpa);
    try drafts.put(gpa, "aaaaaa", "original", 2);
    var space: [0]u8 = .{};
    var failing: std.heap.FixedBufferAllocator = .init(&space);
    try std.testing.expectError(error.OutOfMemory, drafts.put(failing.allocator(), "aaaaaa", "replacement", 7));
    try std.testing.expectError(error.OutOfMemory, drafts.put(failing.allocator(), "bbbbbb", "new", 0));
    // The text fits, but a node cannot be allocated: the copy is released.
    var text_only: [3]u8 = undefined;
    var no_node: std.heap.FixedBufferAllocator = .init(&text_only);
    try std.testing.expectError(error.OutOfMemory, drafts.put(no_node.allocator(), "bbbbbb", "new", 0));
    try std.testing.expect(drafts.take(gpa, "bbbbbb") == null);
    const saved = drafts.take(gpa, "aaaaaa").?;
    defer saved.deinit(gpa);
    try std.testing.expectEqualStrings("original", saved.bytes);
    try std.testing.expectEqual(@as(usize, 2), saved.cursor);
}

test "session_drafts many Sessions retain independent bytes and carets and deinit leftovers" {
    const gpa = std.testing.allocator;
    var drafts: Drafts = .{};
    defer drafts.deinit(gpa);
    for (0..256) |i| {
        var id: [session_id.bytes]u8 = undefined;
        _ = try std.fmt.bufPrint(&id, "{x:0>6}", .{i});
        try drafts.put(gpa, &id, &id, i % (id.len + 1));
    }
    // Reverse order exercises unlinking the tail, middle and head.
    for (0..128) |at| {
        const i = 255 - at * 2;
        var id: [session_id.bytes]u8 = undefined;
        _ = try std.fmt.bufPrint(&id, "{x:0>6}", .{i});
        const draft = drafts.take(gpa, &id).?;
        defer draft.deinit(gpa);
        try std.testing.expectEqualStrings(&id, draft.bytes);
        try std.testing.expectEqual(i % (id.len + 1), draft.cursor);
    }
}
