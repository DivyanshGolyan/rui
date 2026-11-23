//! The line: one held, notification-only connection per client.
//!
//! This core holds one Line's state and its frame grammar over plain values. It
//! reads no socket, Store or clock. The shell (`line_intake.zig`) reads and writes
//! the bytes this core returns, walks the change ring into `absorb`, and passes
//! time in as `now_ms`.
//!
//! A frame is a 4-byte big-endian length and a JSON object with a `type`.
//! App to Host: `{"type":"watch","sessions":"all"}` or
//! `{"type":"watch","sessions":["k7m2qx"]}`. Host to app: `hello`, `changed`,
//! `resync`, `failed` and `ping`. A nudge carries no saved fact: the app reads its
//! own feed from its own cursor.

const std = @import("std");
const session_id = @import("session_id.zig");

pub const Id = [session_id.bytes]u8;
const DirtySet = std.bit_set.StaticBitSet(max_watched);

/// Pool size. Lines are served on intake and are outside its exchange capacity.
pub const capacity = 16;
pub const max_watched = 256;
pub const max_frame_bytes = 16 * 1024;
pub const ping_interval_ms = 20_000;
/// How long a closing line waits for its `failed` frame to drain before the shell closes it.
pub const close_grace_ms = 1_000;
pub const out_bytes = 8 * 1024;

/// Output held back for the frames that must always fit: `failed` and `ping`.
const reserve_bytes = 256;
const max_dirty_any = 32;
const max_payload_bytes = 256;
const frame_prefix = 4;

pub const switching_protocols = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: rui-line/1\r\nConnection: Upgrade\r\n\r\n";

pub const Failure = enum {
    store_failed,
    host_stopping,

    pub fn code(self: Failure) []const u8 {
        return @tagName(self);
    }
};

pub const Watch = union(enum) { all, sessions: usize };

pub const Line = struct {
    /// Unique for the Host's life; assigned by the shell at open.
    token: u64 = 0,
    watch_all: bool = false,
    watched_len: u16 = 0,
    /// Sorted, deduplicated. Bit `i` of `dirty` names `watched[i]`.
    watched: [max_watched]Id = undefined,
    dirty: DirtySet = std.mem.zeroes(DirtySet),
    /// Under `watch_all`: changed Sessions not yet sent. Overflow becomes `resync`.
    dirty_any: [max_dirty_any]Id = undefined,
    dirty_any_len: u8 = 0,
    resync_owed: bool = false,
    /// The change ring generation through which this line's dirty state is current.
    seen: u64 = 0,
    last_frame_ms: u64 = 0,
    failure_owed: ?Failure = null,
    closing: bool = false,
    close_by_ms: u64 = 0,
    /// Pending output is `out[out_start..out_end]`. It never holds more than `out_bytes`.
    out_start: u16 = 0,
    out_end: u16 = 0,
    out: [out_bytes]u8 = undefined,
    in_len: u16 = 0,
    in: [max_frame_bytes + frame_prefix]u8 = undefined,

    /// Sets the state of a line the shell has just accepted. Leaves the buffers alone.
    pub fn init(self: *Line, token: u64, seen: u64, now_ms: u64) void {
        self.token = token;
        self.watch_all = false;
        self.watched_len = 0;
        self.dirty.unsetAll();
        self.dirty_any_len = 0;
        self.resync_owed = false;
        self.seen = seen;
        self.last_frame_ms = now_ms;
        self.failure_owed = null;
        self.closing = false;
        self.close_by_ms = 0;
        self.out_start = 0;
        self.out_end = 0;
        self.in_len = 0;
    }

    /// The upgrade reply, then `hello`. Called once, on an empty output buffer.
    pub fn begin(self: *Line, instance: [16]u8, now_ms: u64) void {
        std.debug.assert(self.out_start == 0 and self.out_end == 0);
        @memcpy(self.out[0..switching_protocols.len], switching_protocols);
        self.out_end = switching_protocols.len;
        const hex = std.fmt.bytesToHex(instance, .lower);
        var payload: [max_payload_bytes]u8 = undefined;
        const text = std.fmt.bufPrint(&payload, "{{\"type\":\"hello\",\"line\":{d},\"instance\":\"{s}\"}}", .{ self.token, &hex }) catch unreachable;
        self.frame(text);
        self.last_frame_ms = now_ms;
    }

    /// Where the shell reads app bytes. Bytes beyond this slice cannot be read yet.
    pub fn inputRoom(self: *Line) []u8 {
        return self.in[self.in_len..];
    }

    /// Accepts `count` bytes written into `inputRoom`, applies every complete frame,
    /// and keeps the rest. A malformed frame is a protocol error; the shell closes the line.
    pub fn received(self: *Line, count: usize) error{ProtocolError}!void {
        std.debug.assert(count <= self.in.len - self.in_len);
        self.in_len += @intCast(count);
        var start: usize = 0;
        while (true) {
            const available = self.in_len - start;
            if (available < frame_prefix) break;
            const length = std.mem.readInt(u32, self.in[start..][0..frame_prefix], .big);
            if (length == 0 or length > max_frame_bytes) return error.ProtocolError;
            if (available < frame_prefix + length) break;
            try self.apply(self.in[start + frame_prefix ..][0..length]);
            start += frame_prefix + length;
        }
        const rest = self.in_len - start;
        std.mem.copyForwards(u8, self.in[0..rest], self.in[start..self.in_len]);
        self.in_len = @intCast(rest);
    }

    /// A commit touched `session` after `seen`. Only a watched Session is noted.
    pub fn absorb(self: *Line, session: Id) void {
        if (self.closing or self.resync_owed) return;
        if (self.watch_all) {
            for (self.dirty_any[0..self.dirty_any_len]) |known| if (std.mem.eql(u8, &known, &session)) return;
            if (self.dirty_any_len == max_dirty_any) {
                self.resync_owed = true;
                self.dirty_any_len = 0;
                return;
            }
            self.dirty_any[self.dirty_any_len] = session;
            self.dirty_any_len += 1;
            return;
        }
        const index = self.indexOf(session) orelse return;
        self.dirty.set(index);
    }

    /// The change ring no longer covers `seen`: the app must re-read everything.
    pub fn wrap(self: *Line, newest: u64) void {
        self.seen = newest;
        self.resync_owed = true;
        self.dirty.unsetAll();
        self.dirty_any_len = 0;
    }

    /// A walk completed through `newest`.
    pub fn advance(self: *Line, newest: u64) void {
        self.seen = newest;
    }

    /// Queues what is owed, while the output has room. Coalesced: one `changed`
    /// per Session however many commits touched it. Pings only an idle line.
    pub fn pump(self: *Line, now_ms: u64) void {
        if (self.failure_owed) |why| {
            var payload: [max_payload_bytes]u8 = undefined;
            const text = std.fmt.bufPrint(&payload, "{{\"type\":\"failed\",\"code\":\"{s}\"}}", .{why.code()}) catch unreachable;
            if (!self.roomFor(frame_prefix + text.len, 0)) return;
            self.frame(text);
            self.last_frame_ms = now_ms;
            self.failure_owed = null;
            return;
        }
        if (self.closing) return;
        if (self.resync_owed) {
            if (!self.roomFor(frame_prefix + resync_payload.len, reserve_bytes)) return;
            self.frame(resync_payload);
            self.last_frame_ms = now_ms;
            self.resync_owed = false;
        }
        while (self.firstDirty()) |session| {
            var payload: [max_payload_bytes]u8 = undefined;
            const text = std.fmt.bufPrint(&payload, "{{\"type\":\"changed\",\"session\":\"{s}\"}}", .{&session}) catch unreachable;
            if (!self.roomFor(frame_prefix + text.len, reserve_bytes)) break;
            self.frame(text);
            self.last_frame_ms = now_ms;
            self.dropFirstDirty();
        }
        if (self.out_start == self.out_end and now_ms -| self.last_frame_ms >= ping_interval_ms) {
            if (!self.roomFor(frame_prefix + ping_payload.len, reserve_bytes)) return;
            self.frame(ping_payload);
            self.last_frame_ms = now_ms;
        }
    }

    /// Stops reading and owes `failed {why}`, then the shell closes the line.
    /// Pending nudges are dropped: the failure supersedes them.
    pub fn fail(self: *Line, why: Failure, now_ms: u64) void {
        if (self.closing) return;
        self.closing = true;
        self.failure_owed = why;
        self.close_by_ms = now_ms + close_grace_ms;
        self.resync_owed = false;
        self.dirty.unsetAll();
        self.dirty_any_len = 0;
    }

    /// Output the socket has not taken yet.
    pub fn pending(self: *const Line) []const u8 {
        return self.out[self.out_start..self.out_end];
    }

    pub fn consumed(self: *Line, count: usize) void {
        std.debug.assert(count <= self.out_end - self.out_start);
        self.out_start += @intCast(count);
        if (self.out_start == self.out_end) {
            self.out_start = 0;
            self.out_end = 0;
        }
    }

    /// True once the line is closing and its `failed` frame has left the buffer.
    pub fn drained(self: *const Line) bool {
        return self.closing and self.failure_owed == null and self.out_start == self.out_end;
    }

    pub fn expired(self: *const Line, now_ms: u64) bool {
        return self.closing and now_ms >= self.close_by_ms;
    }

    /// Whether the shell should ask the socket for writability.
    pub fn wantsWrite(self: *const Line) bool {
        return self.out_start != self.out_end or self.failure_owed != null or
            (!self.closing and (self.resync_owed or self.firstDirtyPeek()));
    }

    /// The time the shell must wake for this line when nothing else happens. Null
    /// while output waits on the socket, which wakes the shell itself.
    pub fn deadline(self: *const Line) ?u64 {
        if (self.closing) return self.close_by_ms;
        if (self.out_start != self.out_end) return null;
        return self.last_frame_ms + ping_interval_ms;
    }

    const resync_payload = "{\"type\":\"resync\"}";
    const ping_payload = "{\"type\":\"ping\"}";

    fn roomFor(self: *Line, bytes: usize, reserve: usize) bool {
        if (@as(usize, self.out_end) + bytes + reserve <= out_bytes) return true;
        self.compact();
        return @as(usize, self.out_end) + bytes + reserve <= out_bytes;
    }

    fn compact(self: *Line) void {
        if (self.out_start == 0) return;
        const pending_bytes = self.out_end - self.out_start;
        std.mem.copyForwards(u8, self.out[0..pending_bytes], self.out[self.out_start..self.out_end]);
        self.out_start = 0;
        self.out_end = @intCast(pending_bytes);
    }

    /// Appends one frame. The caller checked `roomFor` first.
    fn frame(self: *Line, payload: []const u8) void {
        const end: usize = self.out_end;
        std.mem.writeInt(u32, self.out[end..][0..frame_prefix], @intCast(payload.len), .big);
        @memcpy(self.out[end + frame_prefix ..][0..payload.len], payload);
        self.out_end = @intCast(end + frame_prefix + payload.len);
    }

    fn firstDirty(self: *const Line) ?Id {
        if (self.watch_all) return if (self.dirty_any_len == 0) null else self.dirty_any[0];
        const index = self.dirty.findFirstSet() orelse return null;
        return self.watched[index];
    }

    fn firstDirtyPeek(self: *const Line) bool {
        return if (self.watch_all) self.dirty_any_len != 0 else self.dirty.count() != 0;
    }

    fn dropFirstDirty(self: *Line) void {
        if (self.watch_all) {
            std.mem.copyForwards(Id, self.dirty_any[0 .. self.dirty_any_len - 1], self.dirty_any[1..self.dirty_any_len]);
            self.dirty_any_len -= 1;
        } else self.dirty.unset(self.dirty.findFirstSet().?);
    }

    fn indexOf(self: *const Line, session: Id) ?usize {
        var low: usize = 0;
        var high: usize = self.watched_len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, &self.watched[middle], &session)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return middle,
            }
        }
        return null;
    }

    fn apply(self: *Line, payload: []const u8) error{ProtocolError}!void {
        const watch = try parseWatch(payload, &self.watched);
        switch (watch) {
            .all => {
                self.watch_all = true;
                self.watched_len = 0;
                self.dirty.unsetAll();
                self.dirty_any_len = 0;
                // Every Session is unknown to the line, so the app re-reads everything.
                self.resync_owed = true;
            },
            .sessions => |count| {
                std.mem.sort(Id, self.watched[0..count], {}, lessThan);
                var kept: usize = 0;
                for (0..count) |index| {
                    if (kept != 0 and std.mem.eql(u8, &self.watched[kept - 1], &self.watched[index])) continue;
                    self.watched[kept] = self.watched[index];
                    kept += 1;
                }
                self.watch_all = false;
                self.watched_len = @intCast(kept);
                self.dirty.unsetAll();
                self.dirty_any_len = 0;
                // Catch-up: a commit before this watch is not replayed, so each watched
                // Session is nudged once and the app reads its feed from there.
                for (0..kept) |index| self.dirty.set(index);
            },
        }
    }

    fn lessThan(_: void, a: Id, b: Id) bool {
        return std.mem.order(u8, &a, &b) == .lt;
    }
};

/// Strict grammar for the one App to Host frame in this part: exactly these keys in
/// this order, no escapes, and whitespace only between tokens.
pub fn parseWatch(payload: []const u8, sessions: *[max_watched]Id) error{ProtocolError}!Watch {
    var cursor: Cursor = .{ .bytes = payload };
    try cursor.expect("{");
    try cursor.expect("\"type\"");
    try cursor.expect(":");
    try cursor.expect("\"watch\"");
    try cursor.expect(",");
    try cursor.expect("\"sessions\"");
    try cursor.expect(":");
    cursor.skipSpace();
    if (cursor.consume("\"all\"")) {
        cursor.skipSpace();
        try cursor.expect("}");
        try cursor.end();
        return .all;
    }
    try cursor.expect("[");
    var count: usize = 0;
    cursor.skipSpace();
    if (!cursor.consume("]")) while (true) {
        cursor.skipSpace();
        if (count == max_watched) return error.ProtocolError;
        try cursor.expect("\"");
        const start = cursor.index;
        while (cursor.index < cursor.bytes.len and cursor.bytes[cursor.index] != '"') : (cursor.index += 1) {
            if (cursor.bytes[cursor.index] == '\\') return error.ProtocolError;
        }
        const text = cursor.bytes[start..cursor.index];
        if (!session_id.valid(text)) return error.ProtocolError;
        sessions[count] = text[0..session_id.bytes].*;
        count += 1;
        try cursor.expect("\"");
        cursor.skipSpace();
        if (cursor.consume("]")) break;
        try cursor.expect(",");
    };
    cursor.skipSpace();
    try cursor.expect("}");
    try cursor.end();
    return .{ .sessions = count };
}

const Cursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn skipSpace(self: *Cursor) void {
        while (self.index < self.bytes.len) : (self.index += 1) switch (self.bytes[self.index]) {
            ' ', '\t', '\r', '\n' => {},
            else => return,
        };
    }

    fn consume(self: *Cursor, literal: []const u8) bool {
        if (!std.mem.startsWith(u8, self.bytes[self.index..], literal)) return false;
        self.index += literal.len;
        return true;
    }

    fn expect(self: *Cursor, literal: []const u8) error{ProtocolError}!void {
        self.skipSpace();
        if (!self.consume(literal)) return error.ProtocolError;
    }

    fn end(self: *Cursor) error{ProtocolError}!void {
        self.skipSpace();
        if (self.index != self.bytes.len) return error.ProtocolError;
    }
};

// Tests. Each names the rule it owns; the shell's socket tests live in line_intake.zig.

fn watchSessions(line: *Line, sessions: []const []const u8, now_ms: u64) !void {
    var payload: [max_frame_bytes]u8 = undefined;
    var length: usize = 0;
    for (sessions, 0..) |session, index| {
        if (index != 0) length += (std.fmt.bufPrint(payload[length..], ",", .{}) catch unreachable).len;
        length += (std.fmt.bufPrint(payload[length..], "\"{s}\"", .{session}) catch unreachable).len;
    }
    var text: [max_frame_bytes]u8 = undefined;
    const body = try std.fmt.bufPrint(&text, "{{\"type\":\"watch\",\"sessions\":[{s}]}}", .{payload[0..length]});
    try pushFrame(line, body, now_ms);
}

fn pushFrame(line: *Line, body: []const u8, now_ms: u64) !void {
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(body.len), .big);
    const room = line.inputRoom();
    try std.testing.expect(room.len >= 4 + body.len);
    @memcpy(room[0..4], &prefix);
    @memcpy(room[4..][0..body.len], body);
    try line.received(4 + body.len);
    _ = now_ms;
}

/// Decodes the pending output into payload strings, then consumes it.
fn expectFrames(line: *Line, expected: []const []const u8) !void {
    const bytes = line.pending();
    var index: usize = 0;
    var position: usize = 0;
    while (position < bytes.len) : (index += 1) {
        try std.testing.expect(index < expected.len);
        const length = std.mem.readInt(u32, bytes[position..][0..4], .big);
        try std.testing.expectEqualStrings(expected[index], bytes[position + 4 ..][0..length]);
        position += 4 + length;
    }
    try std.testing.expectEqual(expected.len, index);
    line.consumed(bytes.len);
}

fn skipUpgrade(line: *Line) void {
    line.consumed(switching_protocols.len);
}

test "a watch frame accepts only the documented shapes" {
    var sessions: [max_watched]Id = undefined;
    try std.testing.expectEqual(Watch.all, try parseWatch("{\"type\":\"watch\",\"sessions\":\"all\"}", &sessions));
    try std.testing.expectEqual(Watch.all, try parseWatch(" { \"type\" : \"watch\" , \"sessions\" : \"all\" } ", &sessions));
    try std.testing.expectEqual(@as(usize, 0), (try parseWatch("{\"type\":\"watch\",\"sessions\":[]}", &sessions)).sessions);
    const two = try parseWatch("{\"type\":\"watch\",\"sessions\":[\"k7m2qx\", \"a00000\"]}", &sessions);
    try std.testing.expectEqual(@as(usize, 2), two.sessions);
    try std.testing.expectEqualStrings("k7m2qx", &sessions[0]);
    try std.testing.expectEqualStrings("a00000", &sessions[1]);
    const refused = [_][]const u8{
        "",
        "{}",
        "{\"type\":\"serve\",\"sessions\":\"all\"}",
        "{\"sessions\":\"all\",\"type\":\"watch\"}",
        "{\"type\":\"watch\",\"sessions\":\"ALL\"}",
        "{\"type\":\"watch\",\"sessions\":\"all\"} x",
        "{\"type\":\"watch\",\"sessions\":\"all\",}",
        "{\"type\":\"watch\",\"sessions\":[\"k7m2q\"]}",
        "{\"type\":\"watch\",\"sessions\":[\"K7M2QX\"]}",
        "{\"type\":\"watch\",\"sessions\":[\"k7m2qi\"]}",
        "{\"type\":\"watch\",\"sessions\":[\"k7m\\u0032x\"]}",
        "{\"type\":\"watch\",\"sessions\":[\"k7m2qx\"",
        "{\"type\":\"watch\",\"sessions\":[\"k7m2qx\" \"a00000\"]}",
        "{\"type\":\"watch\",\"sessions\":[,]}",
        "{\"type\":\"watch\",\"sessions\":null}",
    };
    for (refused) |payload| try std.testing.expectError(error.ProtocolError, parseWatch(payload, &sessions));
    var too_many: [4096]u8 = undefined;
    var length: usize = 0;
    length += (try std.fmt.bufPrint(too_many[length..], "{{\"type\":\"watch\",\"sessions\":[", .{})).len;
    for (0..max_watched + 1) |index| {
        if (index != 0) length += (try std.fmt.bufPrint(too_many[length..], ",", .{})).len;
        length += (try std.fmt.bufPrint(too_many[length..], "\"{s}\"", .{"k7m2qx"})).len;
    }
    length += (try std.fmt.bufPrint(too_many[length..], "]}}", .{})).len;
    try std.testing.expectError(error.ProtocolError, parseWatch(too_many[0..length], &sessions));
}

test "a line's hello names its token and instance, after the upgrade reply" {
    var line: Line = undefined;
    line.init(7, 0, 1000);
    line.begin(@splat(0xab), 1000);
    try std.testing.expectEqualStrings(switching_protocols, line.pending()[0..switching_protocols.len]);
    const hello = line.pending()[switching_protocols.len..];
    try std.testing.expectEqualStrings("{\"type\":\"hello\",\"line\":7,\"instance\":\"abababababababababababababababab\"}", hello[4..]);
    try std.testing.expectEqual(@as(u32, @intCast(hello.len - 4)), std.mem.readInt(u32, hello[0..4], .big));
}

test "a commit nudges a line only for a Session it watches" {
    var line: Line = undefined;
    line.init(1, 0, 0);
    line.begin(@splat(0), 0);
    skipUpgrade(&line);
    line.consumed(line.pending().len);
    try watchSessions(&line, &.{"k7m2qx"}, 0);
    line.pump(0);
    line.consumed(line.pending().len);
    line.absorb("a00000".*);
    line.pump(0);
    try std.testing.expectEqual(@as(usize, 0), line.pending().len);
    line.absorb("k7m2qx".*);
    line.pump(0);
    try expectFrames(&line, &.{"{\"type\":\"changed\",\"session\":\"k7m2qx\"}"});
}

test "repeated commits to one watched Session coalesce into one changed frame" {
    var line: Line = undefined;
    line.init(1, 0, 0);
    line.begin(@splat(0), 0);
    line.consumed(line.pending().len);
    try watchSessions(&line, &.{ "k7m2qx", "a00000" }, 0);
    line.pump(0);
    line.consumed(line.pending().len);
    for (0..1000) |_| {
        line.absorb("k7m2qx".*);
        line.absorb("k7m2qx".*);
    }
    line.pump(0);
    try expectFrames(&line, &.{"{\"type\":\"changed\",\"session\":\"k7m2qx\"}"});
}

test "a watch catches each watched Session up once, and watch all owes a resync" {
    var line: Line = undefined;
    line.init(1, 0, 0);
    line.begin(@splat(0), 0);
    line.consumed(line.pending().len);
    try watchSessions(&line, &.{ "zzzzzz", "a00000" }, 0);
    line.pump(0);
    try expectFrames(&line, &.{ "{\"type\":\"changed\",\"session\":\"a00000\"}", "{\"type\":\"changed\",\"session\":\"zzzzzz\"}" });
    try pushFrame(&line, "{\"type\":\"watch\",\"sessions\":\"all\"}", 0);
    line.pump(0);
    try expectFrames(&line, &.{"{\"type\":\"resync\"}"});
}

test "a ring wrap owes resync and drops the dirty state it supersedes" {
    var line: Line = undefined;
    line.init(1, 4, 0);
    line.begin(@splat(0), 0);
    line.consumed(line.pending().len);
    try watchSessions(&line, &.{"k7m2qx"}, 0);
    line.pump(0);
    line.consumed(line.pending().len);
    line.absorb("k7m2qx".*);
    line.wrap(90);
    try std.testing.expectEqual(@as(u64, 90), line.seen);
    line.pump(0);
    try expectFrames(&line, &.{"{\"type\":\"resync\"}"});
    line.absorb("k7m2qx".*);
    line.pump(0);
    try expectFrames(&line, &.{"{\"type\":\"changed\",\"session\":\"k7m2qx\"}"});
}

test "watch all overflow past its dirty list becomes one resync" {
    var line: Line = undefined;
    line.init(1, 0, 0);
    line.begin(@splat(0), 0);
    line.consumed(line.pending().len);
    try pushFrame(&line, "{\"type\":\"watch\",\"sessions\":\"all\"}", 0);
    line.pump(0);
    line.consumed(line.pending().len);
    var id_bytes: [6]u8 = "000000".*;
    for (0..max_dirty_any + 1) |index| {
        id_bytes[0] = session_id.alphabet[index % session_id.alphabet.len];
        id_bytes[1] = session_id.alphabet[index / session_id.alphabet.len];
        line.absorb(id_bytes);
    }
    line.pump(0);
    try expectFrames(&line, &.{"{\"type\":\"resync\"}"});
}

test "a ping follows twenty idle seconds and never queues behind pending frames" {
    var line: Line = undefined;
    line.init(1, 0, 1000);
    line.begin(@splat(0), 1000);
    line.consumed(line.pending().len);
    line.pump(1000 + ping_interval_ms - 1);
    try std.testing.expectEqual(@as(usize, 0), line.pending().len);
    try std.testing.expectEqual(@as(?u64, 1000 + ping_interval_ms), line.deadline());
    line.pump(1000 + ping_interval_ms);
    try expectFrames(&line, &.{"{\"type\":\"ping\"}"});
    try std.testing.expectEqual(@as(?u64, 1000 + 2 * ping_interval_ms), line.deadline());
    try watchSessions(&line, &.{"k7m2qx"}, 0);
    line.absorb("k7m2qx".*);
    line.pump(1000 + 2 * ping_interval_ms);
    try expectFrames(&line, &.{"{\"type\":\"changed\",\"session\":\"k7m2qx\"}"});
}

test "a failure owes failed even with a full output, then the line only waits to close" {
    var line: Line = undefined;
    line.init(1, 0, 0);
    line.begin(@splat(0), 0);
    line.consumed(line.pending().len);
    try watchSessions(&line, &.{"k7m2qx"}, 0);
    line.pump(0);
    line.consumed(line.pending().len);
    for (0..10_000) |_| line.absorb("k7m2qx".*);
    line.pump(0);
    while (line.pending().len > 0) line.consumed(line.pending().len);
    line.absorb("k7m2qx".*);
    line.fail(.host_stopping, 500);
    try std.testing.expect(!line.wantsWrite() or line.failure_owed != null);
    line.pump(500);
    try expectFrames(&line, &.{"{\"type\":\"failed\",\"code\":\"host_stopping\"}"});
    try std.testing.expect(line.drained());
    try std.testing.expectEqual(@as(?u64, 500 + close_grace_ms), line.deadline());
    try std.testing.expect(!line.expired(500 + close_grace_ms - 1) and line.expired(500 + close_grace_ms));
    line.absorb("k7m2qx".*);
    line.pump(600);
    try std.testing.expectEqual(@as(usize, 0), line.pending().len);
}

test "a slow reader holds bounded output and dirty state however many commits arrive" {
    var line: Line = undefined;
    line.init(1, 0, 0);
    line.begin(@splat(0), 0);
    line.consumed(line.pending().len);
    var names: [max_watched][6]u8 = undefined;
    for (&names, 0..) |*name, index| {
        name.* = "000000".*;
        name[0] = session_id.alphabet[index % session_id.alphabet.len];
        name[1] = session_id.alphabet[(index / session_id.alphabet.len) % session_id.alphabet.len];
        name[2] = session_id.alphabet[index / (session_id.alphabet.len * session_id.alphabet.len)];
    }
    var sessions: [max_watched][]const u8 = undefined;
    for (&sessions, &names) |*session, *name| session.* = name[0..];
    try watchSessions(&line, &sessions, 0);
    for (0..200_000) |round| {
        const index = round % max_watched;
        line.absorb(names[index]);
        line.pump(0);
        try std.testing.expect(line.out_end <= out_bytes);
        try std.testing.expect(line.dirty.count() <= max_watched);
    }
    try std.testing.expect(line.dirty.count() <= max_watched);
}

test "frames split across reads reassemble, and a bad length closes the line" {
    var line: Line = undefined;
    line.init(1, 0, 0);
    line.begin(@splat(0), 0);
    const body = "{\"type\":\"watch\",\"sessions\":[\"k7m2qx\"]}";
    var frame_bytes: [4 + body.len]u8 = undefined;
    std.mem.writeInt(u32, frame_bytes[0..4], body.len, .big);
    @memcpy(frame_bytes[4..], body);
    for (frame_bytes, 0..) |byte, index| {
        line.inputRoom()[0] = byte;
        try line.received(1);
        if (index + 1 < frame_bytes.len) try std.testing.expect(line.dirty.count() == 0);
    }
    line.absorb("k7m2qx".*);
    try std.testing.expectEqual(@as(usize, 1), line.dirty.count());
    var zero: [4]u8 = .{ 0, 0, 0, 0 };
    @memcpy(line.inputRoom()[0..4], &zero);
    try std.testing.expectError(error.ProtocolError, line.received(4));
    zero = .{ 0xff, 0xff, 0xff, 0xff };
    line.in_len = 0;
    @memcpy(line.inputRoom()[0..4], &zero);
    try std.testing.expectError(error.ProtocolError, line.received(4));
}
