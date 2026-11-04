//! Who holds the Store. A caller that finds it free holds it and runs its
//! entry point's body on its own thread. A caller that finds it busy queues
//! a request and sleeps. A queued write the holder runs itself before it
//! lets go, so that writer wakes once, with its answer, and queued writes
//! can share a commit; any other request gets the Store handed over, and
//! runs on its own thread. Bodies run one at a time, in arrival order: the
//! exclusive access a lock gave, with no thread added for it.

const std = @import("std");
const builtin = @import("builtin");

pub const Queue = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    held: bool = false,
    /// Requests in arrival order, each on its waiting caller's stack.
    head: ?*Job = null,
    tail: ?*Job = null,
    /// The thread that holds the Store, zero when none does. Safe builds
    /// check it before the connection, scratch or ids are touched.
    owner: std.atomic.Value(std.Thread.Id) = .init(0),

    /// One waiting caller's request, on its stack until `done`.
    pub const Job = struct {
        next: ?*Job = null,
        /// How a holder runs a queued write; null for a request that runs
        /// on its own thread.
        run: ?*const fn (*Job) void,
        done: std.Io.Event = .unset,
        /// Runs on its own caller's thread (`run`, `callHeld`): the holder
        /// hands the Store over rather than running the body. Only a write
        /// (`write`) lets the holder run it.
        own: bool,
        /// Set by a holder that handed over the Store instead of running
        /// the body: the caller now holds it and runs its own.
        handed: bool = false,
    };

    /// Bodies one holder runs for others before it hands the Store to the
    /// next waiter, so no caller's own work waits behind an endless queue.
    const drain_limit = 64;

    /// The opening thread holds the Store until open returns.
    pub fn init(io: std.Io) Queue {
        return .{ .io = io, .held = true, .owner = .init(std.Thread.getCurrentId()) };
    }

    /// Ends `init`'s hold once the Store is open.
    pub fn opened(self: *Queue) void {
        self.release();
    }

    /// Runs `body(args...)` on this thread while it holds the Store, and
    /// returns its answer. Noinline, as are `write` and `callHeld`: the
    /// request stays in this frame, not in the frame of every caller that
    /// would inline it.
    pub noinline fn run(self: *Queue, comptime body: anytype, args: anytype) Answer(body) {
        var job: Job = .{ .run = null, .own = true };
        std.debug.assert(self.take(&job));
        defer self.release();
        return @call(.auto, body, args);
    }

    /// As `run`, for a write: a holder that finds it queued runs it on
    /// its own thread, and the caller wakes to the answer.
    pub noinline fn write(self: *Queue, comptime body: anytype, args: anytype) Answer(body) {
        var request: Write(body, @TypeOf(args)) = .{ .args = args, .job = .{ .run = Write(body, @TypeOf(args)).run, .own = false } };
        if (self.take(&request.job)) {
            defer self.release();
            return @call(.auto, body, args);
        }
        return request.answer;
    }

    /// As `call`, but when the body succeeds the caller keeps the Store
    /// until `release`: what it does in between is atomic with the body.
    pub noinline fn callHeld(self: *Queue, comptime body: anytype, args: anytype) Answer(body) {
        var job: Job = .{ .run = null, .own = true };
        std.debug.assert(self.take(&job));
        const answer = @call(.auto, body, args);
        if (answer) |_| {} else |_| self.release();
        return answer;
    }

    /// Runs the queued writes, up to `drain_limit`, then lets the Store go
    /// or hands it to the next waiter.
    pub fn release(self: *Queue) void {
        std.debug.assert(self.owned());
        var ran: u32 = 0;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const job = self.head orelse {
                self.held = false;
                self.owner.store(0, .monotonic);
                self.mutex.unlock(self.io);
                return;
            };
            self.head = job.next;
            if (self.head == null) self.tail = null;
            self.mutex.unlock(self.io);
            if (job.own or ran == drain_limit) {
                self.owner.store(0, .monotonic);
                job.handed = true;
                job.done.set(self.io);
                return;
            }
            job.run.?(job);
            ran += 1;
            // The caller may return once `done` is set: touch nothing after.
            job.done.set(self.io);
        }
    }

    /// Takes the Store for good, to close it: nothing may be queued.
    pub fn closing(self: *Queue) void {
        _ = self.callHeld(nothing, .{}) catch unreachable;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.head == null);
    }

    pub fn owned(self: *const Queue) bool {
        return std.Thread.getCurrentId() == self.owner.load(.monotonic);
    }

    /// Tests only: holds the Store on this thread until `giveBack`, so a
    /// test can open an Entry of its own.
    pub fn borrow(self: *Queue) void {
        comptime std.debug.assert(builtin.is_test);
        self.callHeld(nothing, .{}) catch unreachable;
    }

    pub fn giveBack(self: *Queue) void {
        comptime std.debug.assert(builtin.is_test);
        self.release();
    }

    fn nothing() error{}!void {}

    /// Whether the caller now holds the Store: it was free, or a holder
    /// handed it over. Otherwise a holder ran the body.
    fn take(self: *Queue, job: *Job) bool {
        // A body that called an entry point would wait on itself.
        std.debug.assert(!self.owned());
        self.mutex.lockUncancelable(self.io);
        if (!self.held) {
            self.held = true;
            self.mutex.unlock(self.io);
            self.owner.store(std.Thread.getCurrentId(), .monotonic);
            return true;
        }
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
        self.mutex.unlock(self.io);
        job.done.waitUncancelable(self.io);
        if (!job.handed) return false;
        self.owner.store(std.Thread.getCurrentId(), .monotonic);
        return true;
    }

    fn Answer(comptime body: anytype) type {
        return @typeInfo(@TypeOf(body)).@"fn".return_type.?;
    }

    /// A queued write, which the holder runs through `run`.
    fn Write(comptime body: anytype, comptime Args: type) type {
        return struct {
            job: Job,
            args: Args,
            answer: Answer(body) = undefined,

            fn run(job: *Job) void {
                const self: *@This() = @fieldParentPtr("job", job);
                self.answer = @call(.auto, body, self.args);
            }
        };
    }
};

const Probe = struct {
    io: std.Io,
    log: [16]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),

    fn note(self: *Probe, mark: u8) error{Refused}!void {
        self.log[self.len.fetchAdd(1, .monotonic)] = mark;
        if (mark == 'x') return error.Refused;
    }

    fn other(self: *Probe, queue: *Queue, mark: u8, how: enum { run, write, held }) void {
        switch (how) {
            .run => queue.run(note, .{ self, mark }) catch unreachable,
            .write => queue.write(note, .{ self, mark }) catch unreachable,
            .held => {
                queue.callHeld(note, .{ self, mark }) catch unreachable;
                queue.release();
            },
        }
    }

    fn logged(self: *Probe) []const u8 {
        return self.log[0..self.len.load(.monotonic)];
    }
};

fn waitQueued(queue: *Queue, count: usize) void {
    while (true) {
        queue.mutex.lockUncancelable(queue.io);
        defer queue.mutex.unlock(queue.io);
        var queued: usize = 0;
        var at = queue.head;
        while (at) |job| : (at = job.next) queued += 1;
        if (queued == count) return;
    }
}

test "a free Store runs the body on its caller, and a refusal lets it go" {
    var queue: Queue = .init(std.testing.io);
    queue.opened();
    var probe: Probe = .{ .io = std.testing.io };
    try queue.write(Probe.note, .{ &probe, 'a' });
    try std.testing.expectError(error.Refused, queue.callHeld(Probe.note, .{ &probe, 'x' }));
    try std.testing.expect(!queue.owned());
    try queue.run(Probe.note, .{ &probe, 'b' });
    try std.testing.expectEqualStrings("axb", probe.logged());
}

test "the holder runs queued writes in order, and hands the Store to anything else" {
    const io = std.testing.io;
    var queue: Queue = .init(io);
    queue.opened();
    var probe: Probe = .{ .io = io };
    try queue.callHeld(Probe.note, .{ &probe, 'a' });
    // While held, a write, a held call, a write and a read queue.
    const first = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, 'b', .write });
    waitQueued(&queue, 1);
    const second = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, 'c', .held });
    waitQueued(&queue, 2);
    const third = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, 'd', .write });
    waitQueued(&queue, 3);
    const fourth = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, 'e', .run });
    waitQueued(&queue, 4);
    // Nothing queued ran while the Store was held.
    try probe.note('h');
    queue.release();
    first.join();
    second.join();
    third.join();
    fourth.join();
    try std.testing.expectEqualStrings("ahbcde", probe.logged());
    try std.testing.expect(!queue.held);
}
