const std = @import("std");
const builtin = @import("builtin");

pub const Queue = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    held: bool = false,
    head: ?*Job = null,
    tail: ?*Job = null,
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    batch: Batch,

    pub const Batch = struct {
        context: *anyopaque,
        start: *const fn (*anyopaque) void,
        finish: *const fn (*anyopaque) bool,
        closed: *const fn (*anyopaque) bool,
        arm: *const fn (*anyopaque, bool) void,
        recover: *const fn (*anyopaque) bool,
    };

    pub const Job = struct {
        next: ?*Job = null,
        run: ?*const fn (*Job) void,
        done: std.Io.Event = .unset,
        own: bool,
        handed: bool = false,
        lost: bool = false,
    };

    pub const drain_limit = 64;

    pub fn init(io: std.Io, batch: Batch) Queue {
        return .{ .io = io, .held = true, .owner = .init(std.Thread.getCurrentId()), .batch = batch };
    }

    pub fn opened(self: *Queue) void {
        self.release();
    }

    pub noinline fn run(self: *Queue, comptime body: anytype, args: anytype) Answer(body) {
        var job: Job = .{ .run = null, .own = true };
        std.debug.assert(self.take(&job));
        defer self.release();
        return @call(.auto, body, args);
    }

    pub noinline fn write(self: *Queue, comptime body: anytype, args: anytype) Answer(body) {
        var request: Write(body, @TypeOf(args)) = .{ .args = args, .job = .{ .run = Write(body, @TypeOf(args)).run, .own = false } };
        if (self.take(&request.job)) {
            const committed = self.drain(&request.job);
            return if (committed) request.answer else lostAnswer(Answer(body), request.answer);
        }
        return if (request.job.lost) lostAnswer(Answer(body), request.answer) else request.answer;
    }

    pub noinline fn callHeld(self: *Queue, comptime body: anytype, args: anytype) Answer(body) {
        var job: Job = .{ .run = null, .own = true };
        std.debug.assert(self.take(&job));
        const answer = @call(.auto, body, args);
        if (answer) |_| {} else |_| self.release();
        return answer;
    }

    pub fn release(self: *Queue) void {
        _ = self.drain(null);
    }

    noinline fn drain(self: *Queue, own: ?*Job) bool {
        std.debug.assert(self.owned());
        var batching = false;
        var first = true;
        var committed = true;
        var ran: u32 = 0;
        var batched: ?*Job = null;
        if (own) |job| {
            self.batch.start(self.batch.context);
            self.batch.arm(self.batch.context, true);
            batching = true;
            job.run.?(job);
            job.next = null;
            batched = job;
        }
        while (true) {
            const closed = batching and self.batch.closed(self.batch.context);
            self.mutex.lockUncancelable(self.io);
            const next = self.head;
            if (next) |job| if (!job.own and ran < drain_limit and !closed) {
                self.pop();
                self.mutex.unlock(self.io);
                if (!batching) {
                    self.batch.start(self.batch.context);
                    self.batch.arm(self.batch.context, true);
                }
                batching = true;
                job.run.?(job);
                ran += 1;
                job.next = batched;
                batched = job;
                continue;
            };
            if (batching) {
                self.mutex.unlock(self.io);
                var ok = self.batch.finish(self.batch.context);
                self.batch.arm(self.batch.context, false);
                if (self.batch.recover(self.batch.context)) {
                    batched = reversed(batched);
                    self.batch.start(self.batch.context);
                    var at = batched;
                    while (at) |job| : (at = job.next) job.run.?(job);
                    ok = self.batch.finish(self.batch.context);
                }
                if (first and own != null) committed = ok;
                first = false;
                batching = false;
                answerBatch(self.io, batched, ok);
                batched = null;
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

    fn reversed(list: ?*Job) ?*Job {
        var result: ?*Job = null;
        var at = list;
        while (at) |job| {
            at = job.next;
            job.next = result;
            result = job;
        }
        return result;
    }

    fn pop(self: *Queue) void {
        const job = self.head.?;
        self.head = job.next;
        if (self.head == null) self.tail = null;
    }

    fn answerBatch(io: std.Io, batched: ?*Job, committed: bool) void {
        var at = batched;
        while (at) |job| {
            at = job.next;
            job.lost = !committed;
            job.done.set(io);
        }
    }

    fn lostAnswer(comptime T: type, answer: T) T {
        return switch (@typeInfo(T)) {
            .error_union => |info| if (answer) |payload|
                (if (comptime isReply(info.payload)) lostAnswer(info.payload, payload) else error.StoreFenced)
            else |err|
                err,
            .@"enum", .@"union" => .infrastructure_failure,
            else => @compileError("a write answers an error union or a reply with infrastructure_failure: " ++ @typeName(T)),
        };
    }

    fn isReply(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"enum", .@"union" => @hasField(T, "infrastructure_failure"),
            else => false,
        };
    }

    pub fn closing(self: *Queue) void {
        _ = self.callHeld(nothing, .{}) catch unreachable;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.head == null);
    }

    pub fn writeWaiting(self: *Queue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return if (self.head) |job| !job.own else false;
    }

    pub fn owned(self: *const Queue) bool {
        return std.Thread.getCurrentId() == self.owner.load(.monotonic);
    }

    pub fn borrow(self: *Queue) void {
        comptime std.debug.assert(builtin.is_test);
        self.callHeld(nothing, .{}) catch unreachable;
    }

    pub fn giveBack(self: *Queue) void {
        comptime std.debug.assert(builtin.is_test);
        self.release();
    }

    fn nothing() error{}!void {}

    fn take(self: *Queue, job: *Job) bool {
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
    log: [32]u8 = undefined,
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

pub fn waitQueued(queue: *Queue, count: usize) void {
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
    const first = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, 'b', .write });
    waitQueued(&queue, 1);
    const second = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, 'c', .held });
    waitQueued(&queue, 2);
    const third = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, 'd', .write });
    waitQueued(&queue, 3);
    const fourth = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, 'e', .run });
    waitQueued(&queue, 4);
    try probe.note('h');
    queue.release();
    first.join();
    second.join();
    third.join();
    fourth.join();
    try std.testing.expectEqualStrings("ahbcde", probe.logged());
    try std.testing.expect(!queue.held);
}

const Batches = struct {
    started: u32 = 0,
    finished: u32 = 0,
    fail: bool = false,
    armed: u32 = 0,
    rerun: u32 = 0,
    closes: bool = false,

    var ignored: Batches = .{};
    const none: Queue.Batch = hooks(&ignored);

    fn hooks(self: *Batches) Queue.Batch {
        return .{ .context = self, .start = start, .finish = finish, .closed = closed, .arm = arm, .recover = recover };
    }

    fn closed(context: *anyopaque) bool {
        const self: *Batches = @ptrCast(@alignCast(context));
        return self.closes;
    }

    fn arm(context: *anyopaque, on: bool) void {
        const self: *Batches = @ptrCast(@alignCast(context));
        if (on) self.armed += 1;
    }

    fn recover(context: *anyopaque) bool {
        const self: *Batches = @ptrCast(@alignCast(context));
        if (self.rerun == 0) return false;
        self.rerun -= 1;
        return true;
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
    try queue.write(Probe.note, .{ &probe, 'a' });
    try std.testing.expectEqual(@as(u32, 1), batches.finished);
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
    batches.closes = true;
    try queue.callHeld(Probe.note, .{ &probe, 'j' });
    for (&threads, "klm", 1..) |*thread, mark, queued| {
        thread.* = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, mark, .write });
        waitQueued(&queue, queued);
    }
    queue.release();
    for (threads) |thread| thread.join();
    try std.testing.expectEqualStrings("ahbcdjklm", probe.logged());
    try std.testing.expectEqual(@as(u32, 5), batches.started);
    try std.testing.expectEqual(@as(u32, 5), batches.finished);
    batches.closes = false;
    batches.fail = true;
    try queue.callHeld(Probe.note, .{ &probe, 'i' });
    const lost = try std.Thread.spawn(.{}, Probe.lose, .{ &probe, &queue });
    waitQueued(&queue, 1);
    queue.release();
    lost.join();
    try std.testing.expect(probe.lost);
    try std.testing.expectError(error.StoreFenced, queue.write(Probe.note, .{ &probe, 'f' }));
}

test "a batch that lost its connection with nothing saved runs once more, whole and in order" {
    const io = std.testing.io;
    var batches: Batches = .{};
    var queue: Queue = .init(io, batches.hooks());
    queue.opened();
    var probe: Probe = .{ .io = io };
    try queue.run(Probe.note, .{ &probe, 'r' });
    try std.testing.expectEqual(@as(u32, 0), batches.armed);
    try queue.callHeld(Probe.note, .{ &probe, 'h' });
    var threads: [3]std.Thread = undefined;
    for (&threads, "bcd", 1..) |*thread, mark, queued| {
        thread.* = try std.Thread.spawn(.{}, Probe.other, .{ &probe, &queue, mark, .write });
        waitQueued(&queue, queued);
    }
    batches.rerun = 1;
    const started = batches.started;
    queue.release();
    for (threads) |thread| thread.join();
    try std.testing.expectEqualStrings("rhbcdbcd", probe.logged());
    try std.testing.expectEqual(started + 2, batches.started);
    batches.rerun = 1;
    try queue.write(Probe.note, .{ &probe, 'w' });
    try std.testing.expectEqualStrings("rhbcdbcdww", probe.logged());
}
