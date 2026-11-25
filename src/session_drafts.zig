const std = @import("std");
const session_id = @import("session_id.zig");
const Input = @import("SessionInput.zig");

pub const Draft = struct {
    snapshot: Input.Snapshot,
    image: ?Input.Image = null,

    pub fn deinit(self: Draft, gpa: std.mem.Allocator) void {
        gpa.free(self.snapshot.bytes);
        if (self.image) |image| image.deinit();
    }
};

pub const Drafts = struct {
    first: ?*Node = null,

    const Node = struct {
        id: [session_id.bytes]u8,
        draft: Draft,
        next: ?*Node,
    };

    pub const Entry = struct { id: []const u8, snapshot: Input.Snapshot, image: ?Input.Image };
    pub const Iterator = struct {
        node: ?*const Node,

        pub fn next(self: *Iterator) ?Entry {
            const node = self.node orelse return null;
            self.node = node.next;
            return .{ .id = &node.id, .snapshot = node.draft.snapshot, .image = node.draft.image };
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

    pub fn put(self: *Drafts, gpa: std.mem.Allocator, id: []const u8, snapshot: Input.Snapshot) std.mem.Allocator.Error!void {
        return self.putDraft(gpa, id, snapshot, null);
    }

    pub fn putDraft(self: *Drafts, gpa: std.mem.Allocator, id: []const u8, snapshot: Input.Snapshot, image: ?Input.Image) std.mem.Allocator.Error!void {
        return self.putDraftWith(gpa, id, snapshot, image, Input.Image.clone);
    }

    fn putDraftWith(self: *Drafts, gpa: std.mem.Allocator, id: []const u8, snapshot: Input.Snapshot, image: ?Input.Image, clone: anytype) std.mem.Allocator.Error!void {
        std.debug.assert(session_id.valid(id));
        std.debug.assert(snapshot.cursor <= snapshot.bytes.len);
        if (snapshot.bytes.len == 0 and snapshot.anchor == null and snapshot.rejected == null and image == null) {
            if (self.take(gpa, id)) |draft| draft.deinit(gpa);
            return;
        }
        const copy = try gpa.dupe(u8, snapshot.bytes);
        errdefer gpa.free(copy);
        const image_copy = if (image) |value| try clone(value) else null;
        errdefer if (image_copy) |value| value.deinit();
        var draft: Draft = .{ .snapshot = snapshot, .image = image_copy };
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

    pub fn imageBytes(self: *const Drafts) usize {
        var total: usize = 0;
        var entries = self.iterator();
        while (entries.next()) |entry| if (entry.image) |image| {
            total += image.bytes.len;
        };
        return total;
    }

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

test "SUI-115 an image-only draft survives changing Sessions" {
    const allocator = std.testing.allocator;
    var drafts: Drafts = .{};
    defer drafts.deinit(allocator);
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    const image = try Input.Image.validate(png);
    try drafts.putDraft(allocator, "aaaaaa", .{ .bytes = "", .cursor = 0 }, image);
    try drafts.put(allocator, "bbbbbb", .{ .bytes = "other chat", .cursor = 3 });
    try std.testing.expectEqual(png.len, drafts.imageBytes());
    const draft = drafts.take(allocator, "aaaaaa").?;
    defer draft.deinit(allocator);
    try std.testing.expectEqualSlices(u8, png, draft.image.?.bytes);
    try std.testing.expectEqual(@as(usize, 0), drafts.imageBytes());
    const other = drafts.take(allocator, "bbbbbb").?;
    defer other.deinit(allocator);
    try std.testing.expectEqualStrings("other chat", other.snapshot.bytes);

    const FailImage = struct {
        fn clone(_: Input.Image) error{OutOfMemory}!Input.Image {
            return error.OutOfMemory;
        }
    };
    try drafts.putDraft(allocator, "aaaaaa", .{ .bytes = "original", .cursor = 2 }, image);
    try std.testing.expectError(error.OutOfMemory, drafts.putDraftWith(allocator, "aaaaaa", .{ .bytes = "replacement", .cursor = 3 }, image, FailImage.clone));
    const kept = drafts.take(allocator, "aaaaaa").?;
    defer kept.deinit(allocator);
    try std.testing.expectEqualStrings("original", kept.snapshot.bytes);
    try std.testing.expectEqual(@as(usize, 2), kept.snapshot.cursor);
    try std.testing.expectEqualSlices(u8, png, kept.image.?.bytes);
}
