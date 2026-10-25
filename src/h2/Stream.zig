//! The record behind the opaque `h2.Stream`, stored in caller memory that
//! does not move from `Client.prepare` until `Stream.deinit`. Its size is
//! the client's per-held-request cost, so it holds only what a held stream
//! needs; anything transient lives per connection or per Client.
//!
//!   idle --prepare--> prepared --launch--> pending --submit--> open --settle--> finished --nextFinished--> collected
//!                         |                   ^                  |
//!                         |                   +-----requeue------+   (HEADERS never left, or the server
//!                         |                                          proved it did not process them)
//!                         +--(pending, open, finished)--cancel--> cancelled
//!   (prepared, collected, cancelled) --deinit--> idle
//!
//! A launched record is in the Client's timer list, ordered by
//! `last_activity_ns`; a pending one is also in its origin's queue through
//! `route.queued_next`; a finished one is in the finished list instead.
const std = @import("std");
const h2 = @import("h2.zig");
const policy = @import("policy.zig");

const Record = @This();

pub const State = enum(u8) { idle = 0, prepared, pending, open, finished, collected, cancelled };

prev: ?*Record,
next: ?*Record,
/// Provider time of launch or of the latest response bytes. The deadline is
/// this plus the Client's inactivity interval.
last_activity_ns: u64,
/// The owned request field block (see `FieldBlock`), exact length. nghttp2
/// references it without copying, so it is the only copy of any credential
/// outside the caller. Held while a replay is possible, then zeroed and
/// freed at the first response frame.
fields: ?[*]u8,
fields_len: u32,
endpoint: u8,
state: State,
status: u16,
body_offset: u64,
body_length: u64,
/// A file descriptor, or a pointer to borrowed bytes when `flags.body_is_bytes`.
body_source: usize,
sink_written: u64,
/// A file descriptor, or a buffer pointer when `flags.sink_is_buffer`.
sink_target: usize,
sink_capacity: u32,
/// Set once by `finish`; before that, a local cause recorded during decode
/// that waits for nghttp2 to close the stream.
cause: ?policy.Cause,
flags: Flags,
route: Route,

pub const Route = extern union {
    /// Pending: the next record in its origin's queue.
    queued_next: ?*Record,
    /// Open: where nghttp2 carries it. `connection` is the table index + 1.
    open: extern struct { stream_id: i32, connection: u32 },
};

pub const Flags = packed struct(u16) {
    body_is_bytes: bool = false,
    sink_is_buffer: bool = false,
    /// HEADERS were packed for sending on some connection. Sticky across
    /// replays, so "nothing was sent" is claimed only when it is certain.
    request_sent: bool = false,
    /// A response frame arrived: the server processed the request.
    response_started: bool = false,
    final_seen: bool = false,
    end_stream_seen: bool = false,
    body_done: bool = false,
    body_retired: bool = false,
    opened_connection: bool = false,
    replays: u3 = 0,
    _: u4 = 0,
};

comptime {
    // The per-held-request budget (issue #556): keep the record within it.
    std.debug.assert(@sizeOf(Record) <= 96);
}

pub const size = @sizeOf(Record);
pub const alignment = @alignOf(Record);

pub fn of(stream: *h2.Stream) *Record {
    return @ptrCast(stream);
}

pub fn ofConst(stream: *const h2.Stream) *const Record {
    return @ptrCast(stream);
}

pub fn public(self: *Record) *h2.Stream {
    return @ptrCast(self);
}

pub fn facts(self: *const Record) policy.StreamFacts {
    return .{
        .request_sent = self.flags.request_sent,
        .response_started = self.flags.response_started,
        .final_seen = self.flags.final_seen,
        .end_stream_seen = self.flags.end_stream_seen,
        .replays = self.flags.replays,
        .local = if (self.state == .finished) null else self.cause,
    };
}

/// The owned request field block: for each field a flags byte, a u16 name
/// length and a u32 value length (little endian), then name and value.
pub const FieldBlock = struct {
    pub const header_bytes = 7;
    pub const sensitive: u8 = 1;

    pub const Entry = struct { name: []const u8, value: []const u8, sensitive: bool };

    pub const Iterator = struct {
        bytes: []const u8,

        pub fn next(self: *Iterator) ?Entry {
            if (self.bytes.len == 0) return null;
            const flags = self.bytes[0];
            const name_len = std.mem.readInt(u16, self.bytes[1..3], .little);
            const value_len = std.mem.readInt(u32, self.bytes[3..7], .little);
            const name = self.bytes[header_bytes..][0..name_len];
            const value = self.bytes[header_bytes + name_len ..][0..value_len];
            self.bytes = self.bytes[header_bytes + name_len + value_len ..];
            return .{ .name = name, .value = value, .sensitive = flags & sensitive != 0 };
        }
    };

    pub fn put(buffer: []u8, entry: Entry) usize {
        buffer[0] = if (entry.sensitive) sensitive else 0;
        std.mem.writeInt(u16, buffer[1..3], @intCast(entry.name.len), .little);
        std.mem.writeInt(u32, buffer[3..7], @intCast(entry.value.len), .little);
        @memcpy(buffer[header_bytes..][0..entry.name.len], entry.name);
        @memcpy(buffer[header_bytes + entry.name.len ..][0..entry.value.len], entry.value);
        return header_bytes + entry.name.len + entry.value.len;
    }
};

pub fn fieldEntries(self: *const Record) FieldBlock.Iterator {
    return .{ .bytes = (self.fields orelse return .{ .bytes = &.{} })[0..self.fields_len] };
}

/// Zeroes and frees the field block if it is still held.
pub fn releaseFields(self: *Record, allocator: std.mem.Allocator) void {
    const block = self.fields orelse return;
    const bytes = block[0..self.fields_len];
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
    self.fields = null;
    self.fields_len = 0;
}

/// Intrusive doubly linked list over `prev`/`next`.
pub const List = struct {
    head: ?*Record = null,
    tail: ?*Record = null,

    pub fn pushTail(self: *List, record: *Record) void {
        std.debug.assert(record.prev == null and record.next == null and self.head != record);
        record.prev = self.tail;
        if (self.tail) |tail| tail.next = record else self.head = record;
        self.tail = record;
    }

    pub fn remove(self: *List, record: *Record) void {
        if (record.prev) |prev| prev.next = record.next else {
            std.debug.assert(self.head == record);
            self.head = record.next;
        }
        if (record.next) |next| next.prev = record.prev else {
            std.debug.assert(self.tail == record);
            self.tail = record.prev;
        }
        record.prev = null;
        record.next = null;
    }

    pub fn popHead(self: *List) ?*Record {
        const head = self.head orelse return null;
        self.remove(head);
        return head;
    }

    /// Renewal is a move to the tail. Every record of a Client shares one
    /// interval, so activity order is deadline order and the head is due first.
    pub fn moveToTail(self: *List, record: *Record) void {
        if (self.tail == record) return;
        self.remove(record);
        self.pushTail(record);
    }
};

/// A FIFO of pending records through `route.queued_next`.
pub const Queue = struct {
    head: ?*Record = null,
    tail: ?*Record = null,
    len: u32 = 0,

    pub fn pushTail(self: *Queue, record: *Record) void {
        record.route = .{ .queued_next = null };
        if (self.tail) |tail| tail.route.queued_next = record else self.head = record;
        self.tail = record;
        self.len += 1;
    }

    /// A requeued record launched before everything still waiting goes first.
    pub fn pushHead(self: *Queue, record: *Record) void {
        record.route = .{ .queued_next = self.head };
        self.head = record;
        if (self.tail == null) self.tail = record;
        self.len += 1;
    }

    pub fn popHead(self: *Queue) ?*Record {
        const head = self.head orelse return null;
        self.head = head.route.queued_next;
        if (self.head == null) self.tail = null;
        self.len -= 1;
        return head;
    }

    /// O(n); only a cancel or an expiry of a waiting record removes from the middle.
    pub fn remove(self: *Queue, record: *Record) void {
        var previous: ?*Record = null;
        var current = self.head;
        while (current) |node| : ({
            previous = node;
            current = node.route.queued_next;
        }) {
            if (node != record) continue;
            if (previous) |p| p.route.queued_next = node.route.queued_next else self.head = node.route.queued_next;
            if (self.tail == node) self.tail = previous;
            self.len -= 1;
            return;
        }
        unreachable;
    }
};

test "the list keeps activity order through renewals and removals" {
    var records: [3]Record = undefined;
    for (&records) |*r| r.* = std.mem.zeroes(Record);
    var list: List = .{};
    for (&records) |*r| list.pushTail(r);
    list.moveToTail(&records[0]);
    try std.testing.expectEqual(&records[1], list.head.?);
    list.remove(&records[2]);
    try std.testing.expectEqual(&records[1], list.popHead().?);
    try std.testing.expectEqual(&records[0], list.popHead().?);
    try std.testing.expectEqual(@as(?*Record, null), list.popHead());
}

test "the queue serves requeued records first" {
    var records: [3]Record = undefined;
    for (&records) |*r| r.* = std.mem.zeroes(Record);
    var queue: Queue = .{};
    queue.pushTail(&records[0]);
    queue.pushTail(&records[1]);
    queue.pushHead(&records[2]);
    queue.remove(&records[0]);
    try std.testing.expectEqual(@as(u32, 2), queue.len);
    try std.testing.expectEqual(&records[2], queue.popHead().?);
    try std.testing.expectEqual(&records[1], queue.popHead().?);
    try std.testing.expectEqual(@as(?*Record, null), queue.popHead());
}

test "the field block round-trips names, values and sensitivity" {
    var buffer: [64]u8 = undefined;
    var len = FieldBlock.put(&buffer, .{ .name = "authorization", .value = "Bearer x", .sensitive = true });
    len += FieldBlock.put(buffer[len..], .{ .name = "accept", .value = "", .sensitive = false });
    var entries: FieldBlock.Iterator = .{ .bytes = buffer[0..len] };
    const first = entries.next().?;
    try std.testing.expectEqualStrings("authorization", first.name);
    try std.testing.expectEqualStrings("Bearer x", first.value);
    try std.testing.expect(first.sensitive);
    const second = entries.next().?;
    try std.testing.expectEqualStrings("accept", second.name);
    try std.testing.expect(!second.sensitive);
    try std.testing.expectEqual(@as(?FieldBlock.Entry, null), entries.next());
}
