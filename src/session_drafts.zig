//! Process-local, sparse drafts. Only inactive chats with draft state own
//! storage; taking a draft transfers its exact-length bytes to the caller.
const std = @import("std");
const session_id = @import("session_id.zig");
const Input = @import("SessionInput.zig");

pub const Draft = struct {
    snapshot: Input.Snapshot,

    pub fn deinit(self: Draft, gpa: std.mem.Allocator) void {
        gpa.free(self.snapshot.bytes);
    }
};

pub const Drafts = struct {
    // One small node per saved draft, no retained capacity for stateless chats.
    first: ?*Node = null,

    const Node = struct {
        id: [session_id.bytes]u8,
        draft: Draft,
        next: ?*Node,
    };

    pub const Entry = struct { id: []const u8, snapshot: Input.Snapshot };
    pub const Iterator = struct {
        node: ?*const Node,

        /// Borrows each snapshot until the collection is changed.
        pub fn next(self: *Iterator) ?Entry {
            const node = self.node orelse return null;
            self.node = node.next;
            return .{ .id = &node.id, .snapshot = node.draft.snapshot };
        }
    };

    pub fn iterator(self: *const Drafts) Iterator {
        return .{ .node = self.first };
    }

    pub fn deinit(self: *Drafts, gpa: std.mem.Allocator) void {
        while (self.first) |node| {
            self.first = node.next;
            node.draft.deinit(gpa);
            gpa.destroy(node);
        }
    }

    /// Copies a snapshot's bytes. Replacement is atomic on allocation failure;
    /// a stateless empty composition removes the entry and frees its storage.
    pub fn put(self: *Drafts, gpa: std.mem.Allocator, id: []const u8, snapshot: Input.Snapshot) !void {
        std.debug.assert(session_id.valid(id));
        std.debug.assert(snapshot.cursor <= snapshot.bytes.len);
        if (snapshot.bytes.len == 0 and snapshot.anchor == null and snapshot.rejected == null) {
            if (self.take(gpa, id)) |draft| draft.deinit(gpa);
            return;
        }
        const copy = try gpa.dupe(u8, snapshot.bytes);
        errdefer gpa.free(copy);
        var draft: Draft = .{ .snapshot = snapshot };
        draft.snapshot.bytes = copy;
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
    for (cases) |case| try drafts.put(gpa, case.id, .{ .bytes = case.bytes, .cursor = case.cursor });
    try std.testing.expect(drafts.take(gpa, "bbbbbb") == null);
    try std.testing.expect(drafts.take(gpa, "cccccc") == null);
    const taken = drafts.take(gpa, "aaaaaa").?;
    defer taken.deinit(gpa);
    try std.testing.expectEqualStrings("replaced", taken.snapshot.bytes);
    try std.testing.expectEqual(@as(usize, 3), taken.snapshot.cursor);
    try std.testing.expect(drafts.take(gpa, "aaaaaa") == null);
    try std.testing.expect(drafts.first == null);
    // The store owns a copy, not the editor's borrowed buffer.
    var bytes = [_]u8{ 'o', 'k' };
    try drafts.put(gpa, "aaaaaa", .{ .bytes = &bytes, .cursor = 1 });
    bytes[0] = 'X';
    const copied = drafts.take(gpa, "aaaaaa").?;
    defer copied.deinit(gpa);
    try std.testing.expectEqualStrings("ok", copied.snapshot.bytes);
}

test "session_drafts allocation failure keeps the previous draft" {
    const gpa = std.testing.allocator;
    var drafts: Drafts = .{};
    defer drafts.deinit(gpa);
    try drafts.put(gpa, "aaaaaa", .{ .bytes = "original", .cursor = 2, .rejected = .invalid, .anchor = .{ .position = 7, .end = 9 } });
    var space: [0]u8 = .{};
    var failing: std.heap.FixedBufferAllocator = .init(&space);
    try std.testing.expectError(error.OutOfMemory, drafts.put(failing.allocator(), "aaaaaa", .{ .bytes = "replacement", .cursor = 7 }));
    try std.testing.expectError(error.OutOfMemory, drafts.put(failing.allocator(), "bbbbbb", .{ .bytes = "new", .cursor = 0 }));
    // The text fits, but a node cannot be allocated: the copy is released.
    var text_only: [3]u8 = undefined;
    var no_node: std.heap.FixedBufferAllocator = .init(&text_only);
    try std.testing.expectError(error.OutOfMemory, drafts.put(no_node.allocator(), "bbbbbb", .{ .bytes = "new", .cursor = 0 }));
    try std.testing.expect(drafts.take(gpa, "bbbbbb") == null);
    const saved = drafts.take(gpa, "aaaaaa").?;
    defer saved.deinit(gpa);
    try std.testing.expectEqualStrings("original", saved.snapshot.bytes);
    try std.testing.expectEqual(@as(usize, 2), saved.snapshot.cursor);
    try std.testing.expectEqual(.invalid, saved.snapshot.rejected.?);
    try std.testing.expectEqual(Input.Recalled{ .position = 7, .end = 9 }, saved.snapshot.anchor.?);
}

test "session_drafts many Sessions retain independent bytes and carets and deinit leftovers" {
    const gpa = std.testing.allocator;
    var drafts: Drafts = .{};
    defer drafts.deinit(gpa);
    for (0..256) |i| {
        var id: [session_id.bytes]u8 = undefined;
        _ = try std.fmt.bufPrint(&id, "{x:0>6}", .{i});
        try drafts.put(gpa, &id, .{ .bytes = &id, .cursor = i % (id.len + 1) });
    }
    // Reverse order exercises unlinking the tail, middle and head.
    for (0..128) |at| {
        const i = 255 - at * 2;
        var id: [session_id.bytes]u8 = undefined;
        _ = try std.fmt.bufPrint(&id, "{x:0>6}", .{i});
        const draft = drafts.take(gpa, &id).?;
        defer draft.deinit(gpa);
        try std.testing.expectEqualStrings(&id, draft.snapshot.bytes);
        try std.testing.expectEqual(i % (id.len + 1), draft.snapshot.cursor);
    }
}

test "session_drafts preserves the whole snapshot including empty rejected drafts and recall anchors" {
    const gpa = std.testing.allocator;
    var drafts: Drafts = .{};
    defer drafts.deinit(gpa);
    const cases = [_]Input.Snapshot{
        .{ .bytes = "aéZ", .cursor = "aé".len },
        .{ .bytes = "full", .cursor = 2, .rejected = .overflow },
        .{ .bytes = "text", .cursor = 1, .rejected = .invalid },
        .{ .bytes = "", .cursor = 0, .rejected = .invalid },
        .{ .bytes = "recalled", .cursor = 3, .anchor = .{ .position = 7, .end = 9 } },
        .{ .bytes = "", .cursor = 0, .anchor = .{ .position = 8, .end = 10 } },
    };
    for (cases) |snapshot| {
        try drafts.put(gpa, "aaaaaa", snapshot);
        const saved = drafts.take(gpa, "aaaaaa").?;
        defer saved.deinit(gpa);
        try std.testing.expectEqualStrings(snapshot.bytes, saved.snapshot.bytes);
        try std.testing.expectEqual(snapshot.cursor, saved.snapshot.cursor);
        try std.testing.expectEqual(snapshot.rejected, saved.snapshot.rejected);
        try std.testing.expectEqual(snapshot.anchor, saved.snapshot.anchor);
    }
}
