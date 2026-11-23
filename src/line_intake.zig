//! The shell of the line pool: sockets, the commit waker and the walk of the change
//! ring into each line. The frame grammar and the nudge rules are in `line.zig`.
//!
//! Owner: the intake thread. Only `Waker.notify` runs elsewhere: the committing thread
//! calls it through the Store's commit subscriber, and touches nothing but its atomics
//! and one byte written to the intake wake pipe.

const std = @import("std");
const line = @import("line.zig");
const change_ring = @import("change_ring.zig");
const store = @import("store.zig");
const socket_flags = @import("os").socket.send_flags;

/// Writes one byte to the intake wake pipe, at most once until intake re-arms it,
/// and only while a line is open.
pub const Waker = struct {
    pipe: std.posix.fd_t = -1,
    armed: std.atomic.Value(bool) = .init(false),
    open: std.atomic.Value(bool) = .init(false),

    pub fn notify(self: *Waker) void {
        if (!self.open.load(.seq_cst)) return;
        if (self.armed.swap(true, .seq_cst)) return;
        _ = std.c.send(self.pipe, "x", 1, socket_flags);
    }

    fn notifyContext(context: *anyopaque) void {
        const self: *Waker = @ptrCast(@alignCast(context));
        self.notify();
    }
};

pub const Pool = struct {
    const Slot = struct { line: *line.Line, fd: std.posix.fd_t };

    slots: [line.capacity]?Slot = @splat(null),
    count: usize = 0,
    next_token: u64 = 1,
    waker: Waker = .{},
    subscriber: store.CommitSubscriber = undefined,
    allocator: ?std.mem.Allocator = null,

    /// Wires the waker to the commit subscriber. Call once, at the pool's final address.
    pub fn attach(self: *Pool, pipe: std.posix.fd_t) void {
        self.waker.pipe = pipe;
        self.subscriber = .{ .context = &self.waker, .notify = Waker.notifyContext };
    }

    /// Intake calls this after draining the wake pipe, before it walks the ring.
    pub fn rearm(self: *Pool) void {
        self.waker.armed.store(false, .seq_cst);
    }

    /// Upgrades `fd`: answers 101 and `hello`, and takes `leftover` (app bytes read
    /// after the request). The caller holds the change ring's lock, so the line starts
    /// from the ring's newest generation and every later commit reaches it.
    /// On success the pool owns `fd`; on failure the caller still does.
    pub fn open(
        self: *Pool,
        allocator: std.mem.Allocator,
        instance: [16]u8,
        fd: std.posix.fd_t,
        leftover: []const u8,
        now_ms: u64,
        ring: *const change_ring.Ring,
    ) error{ LinesFull, OutOfMemory, ProtocolError }!void {
        const index = for (self.slots, 0..) |slot, position| {
            if (slot == null) break position;
        } else return error.LinesFull;
        self.waker.open.store(true, .seq_cst);
        errdefer self.syncOpen();
        const created = try allocator.create(line.Line);
        errdefer allocator.destroy(created);
        created.init(self.next_token, ring.newest, now_ms);
        created.begin(instance, now_ms);
        if (leftover.len != 0) {
            const room = created.inputRoom();
            std.debug.assert(leftover.len <= room.len);
            @memcpy(room[0..leftover.len], leftover);
            try created.received(leftover.len);
        }
        self.next_token += 1;
        self.allocator = allocator;
        self.slots[index] = .{ .line = created, .fd = fd };
        self.count += 1;
    }

    /// The caller holds the change ring's lock. Each line walks the entries newer than
    /// its own generation and notes the watched Sessions; a ring that no longer covers a
    /// line's generation owes it a resync.
    pub fn onWake(self: *Pool, ring: *const change_ring.Ring) void {
        for (self.slots) |maybe| {
            const slot = maybe orelse continue;
            if (!ring.covers(slot.line.seen)) {
                slot.line.wrap(ring.newest);
                continue;
            }
            var walk = ring.newer(slot.line.seen);
            while (walk.next()) |entry| slot.line.absorb(entry.session);
            slot.line.advance(ring.newest);
        }
    }

    /// Stops every line with `why`. Each then closes once its `failed` frame has drained,
    /// or when its grace period ends.
    pub fn failAll(self: *Pool, why: line.Failure, now_ms: u64) void {
        for (self.slots) |maybe| {
            const slot = maybe orelse continue;
            slot.line.fail(why, now_ms);
        }
    }

    /// Queues what each line owes and fills `polls` with one entry per open line, in
    /// slot order. `service` takes the revents for exactly these entries.
    pub fn appendPolls(self: *Pool, allocator: std.mem.Allocator, polls: *std.ArrayList(std.c.pollfd), now_ms: u64) !void {
        for (self.slots) |maybe| {
            const slot = maybe orelse continue;
            slot.line.pump(now_ms);
            var events: i16 = 0;
            if (!slot.line.closing) events |= std.posix.POLL.IN;
            if (slot.line.wantsWrite()) events |= std.posix.POLL.OUT;
            try polls.append(allocator, .{ .fd = slot.fd, .events = events, .revents = 0 });
        }
    }

    /// Acts on the revents of the entries `appendPolls` made, then closes lines that are
    /// finished, failed, or expired.
    pub fn service(self: *Pool, polls: []const std.c.pollfd, now_ms: u64) void {
        var index: usize = 0;
        for (&self.slots) |*maybe| {
            const slot = maybe.* orelse continue;
            const events = polls[index].revents;
            index += 1;
            if (events & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
                self.close(maybe);
                continue;
            }
            if (events & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0 and !slot.line.closing) {
                if (!readApp(slot)) {
                    self.close(maybe);
                    continue;
                }
            }
            // Pump and write in the same pass as the input that caused the owed frames, so
            // intake does not sleep on them. A socket that is full just writes nothing.
            slot.line.pump(now_ms);
            if (!writePending(slot)) {
                self.close(maybe);
                continue;
            }
            if (slot.line.drained() or slot.line.expired(now_ms)) self.close(maybe);
        }
    }

    /// Closes lines whose grace period has ended, without waiting for poll.
    pub fn reap(self: *Pool, now_ms: u64) void {
        for (&self.slots) |*maybe| {
            const slot = maybe.* orelse continue;
            if (slot.line.drained() or slot.line.expired(now_ms)) self.close(maybe);
        }
    }

    /// The earliest time a line needs intake to wake, or null when only the socket can.
    pub fn deadline(self: *const Pool) ?u64 {
        var earliest: ?u64 = null;
        for (self.slots) |maybe| {
            const slot = maybe orelse continue;
            const at = slot.line.deadline() orelse continue;
            earliest = if (earliest) |current| @min(current, at) else at;
        }
        return earliest;
    }

    pub fn closeAll(self: *Pool) void {
        for (&self.slots) |*maybe| {
            if (maybe.* != null) self.close(maybe);
        }
    }

    fn close(self: *Pool, maybe: *?Slot) void {
        const slot = maybe.* orelse return;
        _ = std.c.close(slot.fd);
        self.allocator.?.destroy(slot.line);
        maybe.* = null;
        self.count -= 1;
        self.syncOpen();
    }

    fn syncOpen(self: *Pool) void {
        self.waker.open.store(self.count != 0, .seq_cst);
    }
};

/// Reads app bytes into the line. False when the line must close.
fn readApp(slot: Pool.Slot) bool {
    const room = slot.line.inputRoom();
    if (room.len == 0) return false;
    const result = std.c.read(slot.fd, room.ptr, room.len);
    if (result == 0) return false;
    if (result < 0) return switch (std.posix.errno(result)) {
        .AGAIN, .INTR => true,
        else => false,
    };
    slot.line.received(@intCast(result)) catch return false;
    return true;
}

/// Writes what the line has pending. False when the socket failed.
fn writePending(slot: Pool.Slot) bool {
    const pending = slot.line.pending();
    if (pending.len == 0) return true;
    const result = std.c.send(slot.fd, pending.ptr, pending.len, socket_flags);
    if (result < 0) return switch (std.posix.errno(result)) {
        .AGAIN, .INTR => true,
        else => false,
    };
    slot.line.consumed(@intCast(result));
    return true;
}

// Socket tests. The frame grammar, coalescing and the ping and resync rules are owned by line.zig.

fn socketPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    for (fds) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        if (std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking) < 0) return error.SocketFlagsFailed;
    }
    return fds;
}

/// One intake pass at a given time: queue, poll with zero timeout, service, reap.
/// Socket writes on a local pair are synchronous, so the peer sees bytes at once.
fn step(pool: *Pool, polls: *std.ArrayList(std.c.pollfd), now_ms: u64) !void {
    polls.clearRetainingCapacity();
    try pool.appendPolls(std.testing.allocator, polls, now_ms);
    const count = std.c.poll(polls.items.ptr, @intCast(polls.items.len), 0);
    try std.testing.expect(count >= 0);
    pool.service(polls.items, now_ms);
    pool.reap(now_ms);
}

/// Reads whatever the peer has queued. Zero means nothing, or end of stream.
fn readAvailable(fd: std.posix.fd_t, out: []u8) usize {
    var used: usize = 0;
    while (used < out.len) {
        const count = std.c.read(fd, out[used..].ptr, out.len - used);
        if (count <= 0) break;
        used += @intCast(count);
    }
    return used;
}

fn sendFrame(fd: std.posix.fd_t, body: []const u8) !void {
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(body.len), .big);
    try std.testing.expectEqual(@as(isize, 4), std.c.write(fd, &prefix, 4));
    try std.testing.expectEqual(@as(isize, @intCast(body.len)), std.c.write(fd, body.ptr, body.len));
}

/// Records a commit into the ring and notifies the waker, as the Store does.
fn commit(ring: *change_ring.Ring, pool: *Pool, generation: u64, session: []const u8) void {
    var touched: change_ring.Touched = .{};
    touched.add(.{ .session = session[0..6].*, .workspace = 1 });
    ring.record(generation, &touched);
    pool.waker.notify();
}

fn wakeBytes(fd: std.posix.fd_t) usize {
    var bytes: [16]u8 = undefined;
    return readAvailable(fd, &bytes);
}

fn expectOneFrame(fd: std.posix.fd_t, payload: []const u8) !void {
    var bytes: [256]u8 = undefined;
    const count = readAvailable(fd, &bytes);
    try std.testing.expectEqual(@as(usize, 4 + payload.len), count);
    try std.testing.expectEqualStrings(payload, bytes[4..count]);
}

test "an upgrade answers 101 and hello, and a commit nudges only a watching line once" {
    const allocator = std.testing.allocator;
    const wake = try socketPair();
    defer for (wake) |fd| {
        _ = std.c.close(fd);
    };
    var pool: Pool = .{};
    pool.attach(wake[1]);
    defer pool.closeAll();
    var ring: change_ring.Ring = .{};
    var polls: std.ArrayList(std.c.pollfd) = .empty;
    defer polls.deinit(allocator);

    const pair = try socketPair();
    defer _ = std.c.close(pair[1]);
    try pool.open(allocator, @splat(0xab), pair[0], "", 0, &ring);
    try step(&pool, &polls, 0);
    var reply: [512]u8 = undefined;
    const reply_length = readAvailable(pair[1], &reply);
    try std.testing.expect(std.mem.startsWith(u8, reply[0..reply_length], "HTTP/1.1 101 Switching Protocols"));

    // The watch catch-up nudges the watched Session once, before any commit.
    try sendFrame(pair[1], "{\"type\":\"watch\",\"sessions\":[\"k7m2qx\"]}");
    try step(&pool, &polls, 0);
    try expectOneFrame(pair[1], "{\"type\":\"changed\",\"session\":\"k7m2qx\"}");

    // An unwatched commit writes the wake byte but nudges nothing.
    commit(&ring, &pool, 1, "a00000");
    try std.testing.expectEqual(@as(usize, 1), wakeBytes(wake[0]));
    pool.rearm();
    pool.onWake(&ring);
    try step(&pool, &polls, 0);
    try std.testing.expectEqual(@as(usize, 0), readAvailable(pair[1], &reply));

    // Two watched commits coalesce: one wake byte, one changed frame.
    commit(&ring, &pool, 2, "k7m2qx");
    try std.testing.expectEqual(@as(usize, 1), wakeBytes(wake[0]));
    commit(&ring, &pool, 3, "k7m2qx");
    try std.testing.expectEqual(@as(usize, 0), wakeBytes(wake[0]));
    pool.rearm();
    pool.onWake(&ring);
    try step(&pool, &polls, 0);
    try expectOneFrame(pair[1], "{\"type\":\"changed\",\"session\":\"k7m2qx\"}");
    try std.testing.expectEqual(@as(usize, 1), pool.count);
}

test "the pool refuses a line past its capacity and leaves the open lines alone" {
    const allocator = std.testing.allocator;
    var pool: Pool = .{};
    pool.attach(-1);
    defer pool.closeAll();
    var ring: change_ring.Ring = .{};
    var pairs: [line.capacity + 1][2]std.posix.fd_t = undefined;
    for (&pairs) |*pair| pair.* = try socketPair();
    defer for (pairs) |pair| {
        _ = std.c.close(pair[1]);
    };
    for (pairs[0..line.capacity], 0..) |pair, index| {
        try pool.open(allocator, @splat(0), pair[0], "", @intCast(index), &ring);
    }
    try std.testing.expectEqual(@as(usize, line.capacity), pool.count);
    try std.testing.expectError(error.LinesFull, pool.open(allocator, @splat(0), pairs[line.capacity][0], "", 0, &ring));
    try std.testing.expectEqual(@as(usize, line.capacity), pool.count);
    _ = std.c.close(pairs[line.capacity][0]);
}

test "a ring that no longer covers a line owes it resync" {
    const allocator = std.testing.allocator;
    const wake = try socketPair();
    defer for (wake) |fd| {
        _ = std.c.close(fd);
    };
    var pool: Pool = .{};
    pool.attach(wake[1]);
    defer pool.closeAll();
    var ring: change_ring.Ring = .{};
    var polls: std.ArrayList(std.c.pollfd) = .empty;
    defer polls.deinit(allocator);
    const pair = try socketPair();
    defer _ = std.c.close(pair[1]);
    try pool.open(allocator, @splat(0), pair[0], "", 0, &ring);
    try sendFrame(pair[1], "{\"type\":\"watch\",\"sessions\":\"all\"}");
    try step(&pool, &polls, 0);
    var sink: [256]u8 = undefined;
    _ = readAvailable(pair[1], &sink);
    var generation: u64 = 1;
    while (generation <= change_ring.capacity + 1) : (generation += 1) commit(&ring, &pool, generation, "k7m2qx");
    pool.rearm();
    pool.onWake(&ring);
    try step(&pool, &polls, 0);
    try expectOneFrame(pair[1], "{\"type\":\"resync\"}");
}

test "a fence and a drain each send one failed frame, then close the line" {
    const allocator = std.testing.allocator;
    var pool: Pool = .{};
    pool.attach(-1);
    defer pool.closeAll();
    var ring: change_ring.Ring = .{};
    var polls: std.ArrayList(std.c.pollfd) = .empty;
    defer polls.deinit(allocator);
    for ([_]line.Failure{ .store_failed, .host_stopping }) |why| {
        const pair = try socketPair();
        defer _ = std.c.close(pair[1]);
        try pool.open(allocator, @splat(0), pair[0], "", 0, &ring);
        try step(&pool, &polls, 0);
        var sink: [256]u8 = undefined;
        _ = readAvailable(pair[1], &sink);
        pool.failAll(why, 0);
        try step(&pool, &polls, 0);
        var expected: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&expected, "{{\"type\":\"failed\",\"code\":\"{s}\"}}", .{why.code()});
        try expectOneFrame(pair[1], text);
        try std.testing.expectEqual(@as(usize, 0), pool.count);
        try std.testing.expectEqual(@as(usize, 0), readAvailable(pair[1], &sink));
    }
}

test "an idle line pings at twenty seconds of fake time, and a zero length frame closes it" {
    const allocator = std.testing.allocator;
    var pool: Pool = .{};
    pool.attach(-1);
    defer pool.closeAll();
    var ring: change_ring.Ring = .{};
    var polls: std.ArrayList(std.c.pollfd) = .empty;
    defer polls.deinit(allocator);
    const pair = try socketPair();
    defer _ = std.c.close(pair[1]);
    try pool.open(allocator, @splat(0), pair[0], "", 1000, &ring);
    try step(&pool, &polls, 1000);
    var sink: [256]u8 = undefined;
    _ = readAvailable(pair[1], &sink);
    try step(&pool, &polls, 1000 + line.ping_interval_ms - 1);
    try std.testing.expectEqual(@as(usize, 0), readAvailable(pair[1], &sink));
    try step(&pool, &polls, 1000 + line.ping_interval_ms);
    try expectOneFrame(pair[1], "{\"type\":\"ping\"}");
    try std.testing.expectEqual(@as(?u64, 1000 + 2 * line.ping_interval_ms), pool.deadline());
    try std.testing.expectEqual(@as(isize, 4), std.c.write(pair[1], &[4]u8{ 0, 0, 0, 0 }, 4));
    try step(&pool, &polls, 1000 + line.ping_interval_ms);
    try std.testing.expectEqual(@as(usize, 0), pool.count);
}
