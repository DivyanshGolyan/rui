//! The Store's own thread. It alone touches the Store's connection, scratch
//! and id allocator: each public entry point hands its body to `call`, and
//! the calling thread waits for the answer. One body runs at a time, so the
//! worker gives each entry point the exclusive access a lock used to give.

const std = @import("std");
const builtin = @import("builtin");
const signal_stack = @import("../signal_stack.zig");

pub const Worker = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    /// Requests in arrival order, each on its waiting caller's stack.
    head: ?*Job = null,
    tail: ?*Job = null,
    stopping: bool = false,
    /// What a parked worker waits for: `resumeWorker` after a held call.
    resumed: std.Io.Event = .unset,
    /// The worker's thread, once it runs.
    id: std.atomic.Value(std.Thread.Id) = .init(0),
    /// The thread allowed to touch the connection: the worker while it runs
    /// a body, the opening thread before the worker starts, or a test thread
    /// that borrowed it (`borrow`). Safe builds check it.
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    thread: ?std.Thread = null,

    /// One request: which body to run and where its answer goes. Lives on
    /// the caller's stack, which waits until `done`.
    pub const Job = struct {
        next: ?*Job = null,
        run: *const fn (*Job) void,
        done: std.Io.Event = .unset,
        /// Set by `run` when the worker parks after answering.
        park: bool = false,
    };

    /// Prepares a worker the opening thread owns until `start`.
    pub fn init(io: std.Io) Worker {
        return .{ .io = io, .owner = .init(std.Thread.getCurrentId()) };
    }

    pub fn start(self: *Worker) !void {
        self.thread = try signal_stack.spawn(.{}, serve, .{self});
    }

    /// Ends the thread once the queue is empty; the caller owns the
    /// connection afterwards.
    pub fn stop(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.ready.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.owner.store(std.Thread.getCurrentId(), .monotonic);
    }

    /// Runs `body(args...)` on the worker and returns its answer. Noinline,
    /// as is `callHeld`: the request stays in this frame, not in the frame
    /// of every caller that would inline it.
    pub noinline fn call(self: *Worker, comptime body: anytype, args: anytype) Answer(body) {
        var request: Request(body, @TypeOf(args), false) = .{ .args = args };
        self.wait(&request.job);
        return request.answer;
    }

    /// As `call`, but when the body succeeds the worker runs nothing else
    /// until the caller calls `resumeWorker`: what the caller does in
    /// between is atomic with the body.
    pub noinline fn callHeld(self: *Worker, comptime body: anytype, args: anytype) Answer(body) {
        var request: Request(body, @TypeOf(args), true) = .{ .args = args };
        self.wait(&request.job);
        return request.answer;
    }

    pub fn resumeWorker(self: *Worker) void {
        self.resumed.set(self.io);
    }

    pub fn onWorker(self: *const Worker) bool {
        return std.Thread.getCurrentId() == self.id.load(.monotonic);
    }

    pub fn owned(self: *const Worker) bool {
        return std.Thread.getCurrentId() == self.owner.load(.monotonic);
    }

    /// Tests only: parks the worker and hands the connection to this thread
    /// until `giveBack`, so a test can open an Entry of its own.
    pub fn borrow(self: *Worker) void {
        comptime std.debug.assert(builtin.is_test);
        self.callHeld(nothing, .{}) catch unreachable;
        self.owner.store(std.Thread.getCurrentId(), .monotonic);
    }

    pub fn giveBack(self: *Worker) void {
        comptime std.debug.assert(builtin.is_test);
        self.owner.store(self.id.load(.monotonic), .monotonic);
        self.resumeWorker();
    }

    fn nothing() error{}!void {}

    fn wait(self: *Worker, job: *Job) void {
        // A body that called an entry point would wait on itself.
        std.debug.assert(!self.onWorker());
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(!self.stopping);
        if (self.tail) |tail| tail.next = job else self.head = job;
        self.tail = job;
        self.ready.signal(self.io);
        self.mutex.unlock(self.io);
        job.done.waitUncancelable(self.io);
    }

    /// Noinline: the stack-frame gate names this thread by it.
    noinline fn serve(self: *Worker) void {
        const id = std.Thread.getCurrentId();
        self.id.store(id, .monotonic);
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.head == null and !self.stopping) self.ready.waitUncancelable(self.io, &self.mutex);
            const job = self.head orelse {
                self.mutex.unlock(self.io);
                return;
            };
            self.head = job.next;
            if (self.head == null) self.tail = null;
            self.mutex.unlock(self.io);

            self.owner.store(id, .monotonic);
            job.run(job);
            // The caller may return once `done` is set: read the job first.
            const park = job.park;
            job.done.set(self.io);
            if (park) {
                self.resumed.waitUncancelable(self.io);
                self.resumed.reset();
            }
        }
    }

    fn Answer(comptime body: anytype) type {
        return @typeInfo(@TypeOf(body)).@"fn".return_type.?;
    }

    fn Request(comptime body: anytype, comptime Args: type, comptime held: bool) type {
        return struct {
            job: Job = .{ .run = run },
            args: Args,
            answer: Answer(body) = undefined,

            fn run(job: *Job) void {
                const self: *@This() = @fieldParentPtr("job", job);
                self.answer = @call(.auto, body, self.args);
                if (held) job.park = if (self.answer) |_| true else |_| false;
            }
        };
    }
};

const Probe = struct {
    io: std.Io,
    log: [8]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),
    on_worker: bool = true,

    fn note(self: *Probe, worker: *const Worker, mark: u8) error{Refused}!void {
        if (!worker.onWorker()) self.on_worker = false;
        self.log[self.len.fetchAdd(1, .monotonic)] = mark;
        if (mark == 'x') return error.Refused;
    }

    fn other(self: *Probe, worker: *Worker, started: *std.Io.Event) void {
        started.set(self.io);
        worker.call(note, .{ self, worker, 'b' }) catch unreachable;
    }
};

test "the worker runs each body on its own thread and answers its caller" {
    const io = std.testing.io;
    var worker: Worker = .init(io);
    try worker.start();
    defer worker.stop();
    var probe: Probe = .{ .io = io };
    try worker.call(Probe.note, .{ &probe, &worker, 'a' });
    try std.testing.expectError(error.Refused, worker.call(Probe.note, .{ &probe, &worker, 'x' }));
    try std.testing.expect(probe.on_worker);
    try std.testing.expectEqualStrings("ax", probe.log[0..probe.len.load(.monotonic)]);
}

test "a held call runs nothing else until its caller resumes the worker" {
    const io = std.testing.io;
    var worker: Worker = .init(io);
    try worker.start();
    defer worker.stop();
    var probe: Probe = .{ .io = io };
    try worker.callHeld(Probe.note, .{ &probe, &worker, 'a' });
    // Another thread queues a request while the worker is held.
    var started: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &worker, &started });
    started.waitUncancelable(io);
    // Until its request is queued: an unheld worker would now run it.
    while (true) {
        worker.mutex.lockUncancelable(io);
        defer worker.mutex.unlock(io);
        if (worker.head != null) break;
    }
    probe.log[probe.len.fetchAdd(1, .monotonic)] = 'h';
    worker.resumeWorker();
    thread.join();
    try std.testing.expectEqualStrings("ahb", probe.log[0..probe.len.load(.monotonic)]);
    // A refused held call leaves the worker free: the next call answers.
    try std.testing.expectError(error.Refused, worker.callHeld(Probe.note, .{ &probe, &worker, 'x' }));
    try worker.call(Probe.note, .{ &probe, &worker, 'c' });
    try std.testing.expectEqualStrings("ahbxc", probe.log[0..probe.len.load(.monotonic)]);
}
