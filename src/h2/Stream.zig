const std = @import("std");
const h2 = @import("h2.zig");
const policy = @import("policy.zig");

const Record = @This();

pub const State = enum(u8) { idle = 0, prepared, pending, open, finished, collected, cancelled };

prev: ?*Record,
next: ?*Record,
last_activity_ns: u64,
/// The owned request field block (see `FieldBlock`), exact length. nghttp2
/// references it without copying, so outside the caller it holds the only
/// copy of a credential that was not borrowed. Held while a replay is possible, then zeroed and
/// freed at the first response frame.
fields: ?[*]u8,
fields_len: u32,
endpoint: u8,
state: State,
status: u16,
body_offset: u64,
body_length: u64,
body_source: usize,
sink_written: u64,
sink_target: usize,
sink_capacity: u32,
cause: ?policy.Cause,
flags: Flags,
route: Route,

pub const Route = extern union {
    queued_next: ?*Record,
    open: extern struct { stream_id: i32, connection: u32 },
};

pub const Flags = packed struct(u16) {
    body_is_bytes: bool = false,
    sink_is_buffer: bool = false,
    request_sent: bool = false,
    response_started: bool = false,
    final_seen: bool = false,
    end_stream_seen: bool = false,
    body_done: bool = false,
    body_retired: bool = false,
    opened_connection: bool = false,
    replays: u3 = 0,
    get: bool = false,
    _: u3 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Record) <= 96);
}

pub const size = @sizeOf(Record);
pub const alignment = @alignOf(Record);

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

pub const FieldBlock = struct {
    pub const header_bytes = 7;
    pub const sensitive: u8 = 1;
    pub const borrowed: u8 = 2;
    const address_bytes = @sizeOf(usize);

    pub const Entry = h2.Field;

    pub const Iterator = struct {
        bytes: []const u8,

        pub fn next(self: *Iterator) ?Entry {
            if (self.bytes.len == 0) return null;
            const flags = self.bytes[0];
            const name_len = std.mem.readInt(u16, self.bytes[1..3], .little);
            const value_len = std.mem.readInt(u32, self.bytes[3..7], .little);
            const rest = self.bytes[header_bytes..];
            var entry: Entry = .{ .name = undefined, .value = undefined, .sensitive = flags & sensitive != 0, .borrowed = flags & borrowed != 0 };
            if (entry.borrowed) {
                entry.name = address(rest[0..address_bytes])[0..name_len];
                entry.value = address(rest[address_bytes..][0..address_bytes])[0..value_len];
            } else {
                entry.name = rest[0..name_len];
                entry.value = rest[name_len..][0..value_len];
            }
            self.bytes = self.bytes[entryBytes(entry)..];
            return entry;
        }

        fn address(bytes: *const [address_bytes]u8) [*]const u8 {
            return @ptrFromInt(std.mem.readInt(usize, bytes, .little));
        }
    };

    pub fn entryBytes(entry: Entry) usize {
        return header_bytes + if (entry.borrowed) 2 * address_bytes else entry.name.len + entry.value.len;
    }

    pub fn put(buffer: []u8, entry: Entry) usize {
        buffer[0] = (if (entry.sensitive) sensitive else 0) | (if (entry.borrowed) borrowed else 0);
        std.mem.writeInt(u16, buffer[1..3], @intCast(entry.name.len), .little);
        std.mem.writeInt(u32, buffer[3..7], @intCast(entry.value.len), .little);
        const rest = buffer[header_bytes..];
        if (entry.borrowed) {
            std.mem.writeInt(usize, rest[0..address_bytes], @intFromPtr(entry.name.ptr), .little);
            std.mem.writeInt(usize, rest[address_bytes..][0..address_bytes], @intFromPtr(entry.value.ptr), .little);
        } else {
            @memcpy(rest[0..entry.name.len], entry.name);
            @memcpy(rest[entry.name.len..][0..entry.value.len], entry.value);
        }
        return entryBytes(entry);
    }
};

pub fn fieldEntries(self: *const Record) FieldBlock.Iterator {
    return .{ .bytes = (self.fields orelse return .{ .bytes = &.{} })[0..self.fields_len] };
}

pub fn releaseFields(self: *Record, allocator: std.mem.Allocator) void {
    const block = self.fields orelse return;
    const bytes = block[0..self.fields_len];
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
    self.fields = null;
    self.fields_len = 0;
}

pub const Body = union(enum) {
    file: struct { handle: usize, length: u64 },
    bytes: []const u8,
};

pub const Sink = union(enum) {
    file: usize,
    buffer: []u8,
};

pub const Prepared = struct {
    fields: ?[*]u8,
    fields_len: u32,
    endpoint: u8,
    get: bool,
    body: Body,
    sink: Sink,
};

pub const Event = union(enum) {
    prepare: Prepared,
    launch: u64,
    open: struct { stream_id: i32, connection: u32, first: bool },
    requeue: struct { replay: bool },
    finish: policy.Cause,
    collect,
    cancel,
};

/// The one decision table for the lifecycle: each event asserts the state it leaves and writes the next state and its fields.
pub fn apply(self: *Record, event: Event) void {
    switch (event) {
        .prepare => |with| {
            std.debug.assert(self.state == .idle);
            self.* = std.mem.zeroes(Record);
            self.fields = with.fields;
            self.fields_len = with.fields_len;
            self.endpoint = with.endpoint;
            self.flags.get = with.get;
            switch (with.body) {
                .file => |file| {
                    self.body_source = file.handle;
                    self.body_length = file.length;
                },
                .bytes => |bytes| {
                    self.flags.body_is_bytes = true;
                    self.body_source = @intFromPtr(bytes.ptr);
                    self.body_length = bytes.len;
                },
            }
            switch (with.sink) {
                .file => |fd| self.sink_target = fd,
                .buffer => |buffer| {
                    self.flags.sink_is_buffer = true;
                    self.sink_target = @intFromPtr(buffer.ptr);
                    self.sink_capacity = @intCast(buffer.len);
                },
            }
            self.state = .prepared;
        },
        .launch => |now_ns| {
            std.debug.assert(self.state == .prepared);
            self.state = .pending;
            self.last_activity_ns = now_ns;
        },
        .open => |opened| {
            std.debug.assert(self.state == .pending);
            self.route = .{ .open = .{ .stream_id = opened.stream_id, .connection = opened.connection } };
            self.state = .open;
            if (opened.first) self.flags.opened_connection = true;
        },
        .requeue => |requeued| {
            std.debug.assert(self.state == .open and !self.flags.response_started);
            if (requeued.replay) self.flags.replays += 1;
            self.state = .pending;
            self.body_offset = 0;
            self.flags.body_done = false;
        },
        .finish => |cause| {
            std.debug.assert(self.state == .pending or self.state == .open);
            self.cause = cause;
            self.state = .finished;
        },
        .collect => {
            std.debug.assert(self.state == .finished);
            self.state = .collected;
        },
        .cancel => {
            std.debug.assert(self.state != .idle and self.state != .collected and self.state != .cancelled);
            self.state = .cancelled;
        },
    }
}

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

    pub fn moveToTail(self: *List, record: *Record) void {
        if (self.tail == record) return;
        self.remove(record);
        self.pushTail(record);
    }
};

pub const Queue = struct {
    head: ?*Record = null,
    tail: ?*Record = null,
    len: u32 = 0,
    put_back: ?*Record = null,

    pub fn pushTail(self: *Queue, record: *Record) void {
        record.route = .{ .queued_next = null };
        if (self.tail) |tail| tail.route.queued_next = record else self.head = record;
        self.tail = record;
        self.len += 1;
    }

    pub fn putBack(self: *Queue, record: *Record) void {
        if (self.put_back) |previous| {
            record.route = .{ .queued_next = previous.route.queued_next };
            previous.route.queued_next = record;
            if (self.tail == previous) self.tail = record;
        } else {
            record.route = .{ .queued_next = self.head };
            self.head = record;
            if (self.tail == null) self.tail = record;
        }
        self.put_back = record;
        self.len += 1;
    }

    pub fn popHead(self: *Queue) ?*Record {
        const head = self.head orelse return null;
        if (self.put_back == head) self.put_back = null;
        self.head = head.route.queued_next;
        if (self.head == null) self.tail = null;
        self.len -= 1;
        return head;
    }

    pub fn remove(self: *Queue, record: *Record) void {
        var previous: ?*Record = null;
        var current = self.head;
        while (current) |node| : ({
            previous = node;
            current = node.route.queued_next;
        }) {
            if (node != record) continue;
            if (self.put_back == node) self.put_back = previous;
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

test "the queue serves put-back records first, in the order put back" {
    var records: [5]Record = undefined;
    for (&records) |*r| r.* = std.mem.zeroes(Record);
    var queue: Queue = .{};
    queue.pushTail(&records[0]);
    queue.pushTail(&records[1]);
    queue.putBack(&records[2]);
    queue.putBack(&records[3]);
    queue.remove(&records[0]);
    try std.testing.expectEqual(@as(u32, 3), queue.len);
    try std.testing.expectEqual(&records[2], queue.popHead().?);
    queue.putBack(&records[4]);
    try std.testing.expectEqual(&records[3], queue.popHead().?);
    try std.testing.expectEqual(&records[4], queue.popHead().?);
    try std.testing.expectEqual(&records[1], queue.popHead().?);
    try std.testing.expectEqual(@as(?*Record, null), queue.popHead());

    queue.putBack(&records[0]);
    queue.putBack(&records[1]);
    queue.remove(&records[1]);
    queue.putBack(&records[2]);
    try std.testing.expectEqual(&records[0], queue.popHead().?);
    try std.testing.expectEqual(&records[2], queue.popHead().?);
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

test "a borrowed field keeps only its addresses in the block" {
    const value: []const u8 = "Bearer " ++ @as([1200]u8, @splat('t'));
    var buffer: [128]u8 = undefined;
    var len = FieldBlock.put(&buffer, .{ .name = "authorization", .value = value, .sensitive = true, .borrowed = true });
    try std.testing.expectEqual(FieldBlock.header_bytes + 2 * @sizeOf(usize), len);
    len += FieldBlock.put(buffer[len..], .{ .name = "session-id", .value = "abc", .sensitive = false });
    var entries: FieldBlock.Iterator = .{ .bytes = buffer[0..len] };
    const first = entries.next().?;
    try std.testing.expectEqual(value.ptr, first.value.ptr);
    try std.testing.expectEqual(value.len, first.value.len);
    try std.testing.expectEqualStrings("authorization", first.name);
    try std.testing.expect(first.sensitive and first.borrowed);
    const second = entries.next().?;
    try std.testing.expectEqualStrings("abc", second.value);
    try std.testing.expect(!second.borrowed);
    try std.testing.expectEqual(@as(?FieldBlock.Entry, null), entries.next());
}

test "CM-70 a stream record moves through its lifecycle only by applying events, and each event leaves the state it expects" {
    var buffer: [8]u8 = undefined;
    const bodies = [_]Body{ .{ .file = .{ .handle = 7, .length = 40 } }, .{ .bytes = "abc" } };
    const sinks = [_]Sink{ .{ .file = 9 }, .{ .buffer = &buffer } };
    for (bodies) |body| for (sinks) |sink| for ([_]bool{ false, true }) |get| {
        var record = std.mem.zeroes(Record);
        record.apply(.{ .prepare = .{ .fields = null, .fields_len = 0, .endpoint = 3, .get = get, .body = body, .sink = sink } });
        try std.testing.expectEqual(State.prepared, record.state);
        try std.testing.expectEqual(@as(u8, 3), record.endpoint);
        try std.testing.expectEqual(get, record.flags.get);
        try std.testing.expectEqual(body == .bytes, record.flags.body_is_bytes);
        try std.testing.expectEqual(sink == .buffer, record.flags.sink_is_buffer);
        switch (body) {
            .file => |file| try std.testing.expectEqual(file.length, record.body_length),
            .bytes => |bytes| try std.testing.expectEqual(@as(u64, bytes.len), record.body_length),
        }
        switch (sink) {
            .file => |fd| try std.testing.expectEqual(fd, record.sink_target),
            .buffer => |target| try std.testing.expectEqual(@as(u32, @intCast(target.len)), record.sink_capacity),
        }

        record.apply(.{ .launch = 500 });
        try std.testing.expectEqual(State.pending, record.state);
        try std.testing.expectEqual(@as(u64, 500), record.last_activity_ns);

        // From pending, finish and cancel are both legal.
        var from_pending = record;
        from_pending.apply(.{ .finish = .body_failed });
        try std.testing.expectEqual(State.finished, from_pending.state);
        try std.testing.expectEqual(@as(?policy.Cause, .body_failed), from_pending.cause);
        from_pending.apply(.collect);
        try std.testing.expectEqual(State.collected, from_pending.state);
        var cancelled = record;
        cancelled.apply(.cancel);
        try std.testing.expectEqual(State.cancelled, cancelled.state);

        for ([_]bool{ false, true }) |first| {
            var opened = record;
            opened.apply(.{ .open = .{ .stream_id = 5, .connection = 2, .first = first } });
            try std.testing.expectEqual(State.open, opened.state);
            try std.testing.expectEqual(@as(i32, 5), opened.route.open.stream_id);
            try std.testing.expectEqual(@as(u32, 2), opened.route.open.connection);
            try std.testing.expectEqual(first, opened.flags.opened_connection);

            for ([_]bool{ false, true }) |replay| {
                var again = opened;
                again.body_offset = 12;
                again.flags.body_done = true;
                again.apply(.{ .requeue = .{ .replay = replay } });
                try std.testing.expectEqual(State.pending, again.state);
                try std.testing.expectEqual(@as(u64, 0), again.body_offset);
                try std.testing.expect(!again.flags.body_done);
                try std.testing.expectEqual(@as(u3, if (replay) 1 else 0), again.flags.replays);
            }

            var finished = opened;
            finished.apply(.{ .finish = .body_failed });
            try std.testing.expectEqual(State.finished, finished.state);
            var cancelled_open = opened;
            cancelled_open.apply(.cancel);
            try std.testing.expectEqual(State.cancelled, cancelled_open.state);
        }
    };
}
