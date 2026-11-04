//! Who holds the Store. A caller that finds it free holds it and runs its
//! entry point's body on its own thread. A caller that finds it busy queues
//! a request and sleeps. A queued write the holder runs itself before it
//! lets go, so that writer wakes once, with its answer, and queued writes
//! can share a commit; any other request gets the Store handed over, and
//! runs on its own thread. Bodies run one at a time, in arrival order: the
//! exclusive access a lock gave, with no thread added for it.
//!
//! Writes the holder runs back to back form a batch (`Batch`): one
//! transaction, each write in a savepoint of its own, one COMMIT. No writer
//! hears its answer before that COMMIT, and when it fails every writer in
//! the batch hears the failure.

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
    batch: Batch,

    /// How the Store opens and commits a batch of writes. `finish` answers
    /// whether the batch committed; when it did not, the Store is fenced.
    pub const Batch = struct {
        context: *anyopaque,
        start: *const fn (*anyopaque) void,
        finish: *const fn (*anyopaque) bool,
    };

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
        /// Set by a holder whose batch failed to commit: the body's answer
        /// never became durable.
        lost: bool = false,
    };

    /// Bodies one holder runs for others before it hands the Store to the
    /// next waiter, so no caller's own work waits behind an endless queue.
    const drain_limit = 64;

    /// The opening thread holds the Store until open returns.
    pub fn init(io: std.Io, batch: Batch) Queue {
        return .{ .io = io, .held = true, .owner = .init(std.Thread.getCurrentId()), .batch = batch };
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

    /// As `run`, for a write, which joins a batch: a holder that finds it
    /// queued runs it on its own thread, and the caller wakes to the answer
    /// once the batch has committed. A batch that failed to commit answers
    /// `lostAnswer`.
    pub noinline fn write(self: *Queue, comptime body: anytype, args: anytype) Answer(body) {
        var request: Write(body, @TypeOf(args)) = .{ .args = args, .job = .{ .run = Write(body, @TypeOf(args)).run, .own = false } };
        if (self.take(&request.job)) {
            self.batch.start(self.batch.context);
            const answer = @call(.auto, body, args);
            return if (self.drain(true)) answer else lostAnswer(Answer(body), answer);
        }
        return if (request.job.lost) lostAnswer(Answer(body), request.answer) else request.answer;
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

    /// Runs the queued writes, up to `drain_limit`, in batches, then lets
    /// the Store go or hands it to the next waiter.
    pub fn release(self: *Queue) void {
        _ = self.drain(false);
    }

    /// `release`, after a write of the holder's own when `open`: then the
    /// answer is whether the batch that write joined committed.
    noinline fn drain(self: *Queue, open: bool) bool {
        std.debug.assert(self.owned());
        var batching = open;
        var first = true;
        var committed = true;
        var ran: u32 = 0;
        // The batch's writers, answered once it commits.
        var batched: ?*Job = null;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const next = self.head;
            if (next) |job| if (!job.own and ran < drain_limit) {
                self.pop();
                self.mutex.unlock(self.io);
                if (!batching) self.batch.start(self.batch.context);
                batching = true;
                job.run.?(job);
                ran += 1;
                job.next = batched;
                batched = job;
                continue;
            };
            if (batching) {
                self.mutex.unlock(self.io);
                const ok = self.batch.finish(self.batch.context);
                if (first and open) committed = ok;
                first = false;
                batching = false;
                answerBatch(self.io, batched, ok);
                batched = null;
                // More writes may have queued meanwhile.
                continue;
            }
            const job = next orelse {
                self.held = false;
                self.owner.store(0, .monotonic);
                self.mutex.unlock(self.io);
                return committed;
            };
            self.pop();
            self.mutex.unlock(self.io);
            self.owner.store(0, .monotonic);
            job.handed = true;
            job.done.set(self.io);
            return committed;
        }
    }

    fn pop(self: *Queue) void {
        const job = self.head.?;
        self.head = job.next;
        if (self.head == null) self.tail = null;
    }

    fn answerBatch(io: std.Io, batched: ?*Job, committed: bool) void {
        var at = batched;
        while (at) |job| {
            // The caller may return once `done` is set: read `next` first.
            at = job.next;
            job.lost = !committed;
            job.done.set(io);
        }
    }

    /// What a write whose batch failed to commit answers: the failure its
    /// entry point reports when it finds the Store fenced. A write that
    /// already failed keeps its own error, which says more.
    fn lostAnswer(comptime T: type, answer: T) T {
        return switch (@typeInfo(T)) {
            .error_union => if (answer) |_| error.StoreFenced else |err| err,
            .@"enum", .@"union" => .infrastructure_failure,
            else => @compileError("a write answers an error union or a reply with infrastructure_failure: " ++ @typeName(T)),
        };
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
    lost: bool = false,

    fn note(self: *Probe, mark: u8) error{ Refused, StoreFenced }!void {
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

    fn lose(self: *Probe, queue: *Queue) void {
        queue.write(note, .{ self, 'e' }) catch |err| switch (err) {
            error.StoreFenced => self.lost = true,
            else => unreachable,
        };
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
    var queue: Queue = .init(std.testing.io, Batches.none);
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
    var queue: Queue = .init(io, Batches.none);
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

/// A test's batch hooks: counts the batches and their commits, and fails
/// a commit on request.
const Batches = struct {
    started: u32 = 0,
    finished: u32 = 0,
    fail: bool = false,

    var ignored: Batches = .{};
    const none: Queue.Batch = hooks(&ignored);

    fn hooks(self: *Batches) Queue.Batch {
        return .{ .context = self, .start = start, .finish = finish };
    }

    fn start(context: *anyopaque) void {
        const self: *Batches = @ptrCast(@alignCast(context));
        self.started += 1;
    }

    fn finish(context: *anyopaque) bool {
        const self: *Batches = @ptrCast(@alignCast(context));
        self.finished += 1;
        return !self.fail;
    }
};

test "writes queued behind the holder share one batch and hear it fail together" {
    const io = std.testing.io;
    var batches: Batches = .{};
    var queue: Queue = .init(io, batches.hooks());
    queue.opened();
    var probe: Probe = .{ .io = io };
    // Alone, a write is a batch of one.
    try queue.write(Probe.note, .{ &probe, 'a' });
    try std.testing.expectEqual(@as(u32, 1), batches.finished);
    // Three writes queue behind a held read and commit as one batch.
    try queue.callHeld(Probe.note, .{ &probe, 'h' });
    var threads: [3]std.Thread = undefined;
    for (&threads, "bcd", 1..) |*thread, mark, queued| {
        thread.* = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, mark, .write });
        waitQueued(&queue, queued);
    }
    queue.release();
    for (threads) |thread| thread.join();
    try std.testing.expectEqualStrings("ahbcd", probe.logged());
    try std.testing.expectEqual(@as(u32, 2), batches.started);
    try std.testing.expectEqual(@as(u32, 2), batches.finished);
    // A commit that fails reaches every writer in its batch.
    batches.fail = true;
    try queue.callHeld(Probe.note, .{ &probe, 'i' });
    const lost = try std.Thread.spawn(.{}, Probe.lose, .{ &probe, &queue });
    waitQueued(&queue, 1);
    queue.release();
    lost.join();
    try std.testing.expect(probe.lost);
    try std.testing.expectError(error.StoreFenced, queue.write(Probe.note, .{ &probe, 'f' }));
}
