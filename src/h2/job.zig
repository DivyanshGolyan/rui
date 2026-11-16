const std = @import("std");
const Waker = @import("Waker.zig");

pub fn Job(comptime Work: type) type {
    return struct {
        const Self = @This();

        mutex: std.c.pthread_mutex_t,
        references: u8,
        state: enum(u8) { running, done, abandoned },
        waker: *Waker,
        work: Work,

        pub fn start(waker: *Waker, work: Work) ?*Self {
            const self = std.heap.c_allocator.create(Self) catch {
                var unused = work;
                deinitWork(&unused);
                return null;
            };
            self.* = .{ .mutex = .{}, .references = 2, .state = .running, .waker = waker, .work = work };
            // The libc default stack: glibc sizes it around static TLS, which a
            // fixed small size would not. Only the pages the work touches count.
            var thread: std.c.pthread_t = undefined;
            if (std.c.pthread_create(&thread, null, run, self) != .SUCCESS) {
                self.free();
                return null;
            }
            _ = std.c.pthread_detach(thread);
            return self;
        }

        pub fn finished(waker: *Waker, work: Work) ?*Self {
            const self = std.heap.c_allocator.create(Self) catch return null;
            self.* = .{ .mutex = .{}, .references = 1, .state = .done, .waker = waker, .work = work };
            return self;
        }

        pub fn result(self: *Self) ?*const Work {
            self.lock();
            defer self.unlock();
            return if (self.state == .done) &self.work else null;
        }

        pub fn release(self: *Self) void {
            self.lock();
            if (self.state == .running) self.state = .abandoned;
            self.references -= 1;
            const last = self.references == 0;
            self.unlock();
            if (last) self.free();
        }

        fn run(argument: ?*anyopaque) callconv(.c) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(argument.?));
            self.work.run();
            self.lock();
            if (self.state == .running) {
                self.state = .done;
                self.waker.wake();
            }
            self.references -= 1;
            const last = self.references == 0;
            self.unlock();
            if (last) self.free();
            return null;
        }

        fn free(self: *Self) void {
            deinitWork(&self.work);
            std.heap.c_allocator.destroy(self);
        }

        fn deinitWork(work: *Work) void {
            if (@hasDecl(Work, "deinit")) work.deinit();
        }

        fn lock(self: *Self) void {
            std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
        }

        fn unlock(self: *Self) void {
            std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
        }
    };
}
