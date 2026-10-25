//! Blocking work for one connection setup, on a short-lived thread of its
//! own: a name lookup, or a SecTrust evaluation on macOS. Internal.
//!
//! A job owns nothing but its work: no socket, no session, no stream. The
//! thread exists only while the work runs, so an idle Client holds no
//! thread. The job is shared by two references, the owner's and the
//! thread's; whichever lets go last frees it. Finished work wakes the
//! owner's `wait`, unless the owner abandoned it first (the connection or
//! Client closed), in which case the thread only frees the job. A thread
//! may outlive `Client.deinit` until its work returns, which nothing can
//! interrupt.
const std = @import("std");
const Waker = @import("Waker.zig");

/// `Work` has `fn run(*Work) void`, called once on the job's thread, and
/// may have `fn deinit(*Work) void`, called when the job is freed.
pub fn Job(comptime Work: type) type {
    return struct {
        const Self = @This();

        mutex: std.c.pthread_mutex_t,
        references: u8,
        state: enum(u8) { running, done, abandoned },
        waker: *Waker,
        work: Work,

        /// Starts `work` and returns the owner's reference, or null when no
        /// thread could be started (and `work` was deinitialized).
        pub fn start(waker: *Waker, work: Work) ?*Self {
            // Freed by whichever thread lets go last, so not the Client's allocator.
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

        /// Owner thread: the finished work, null while it runs.
        pub fn result(self: *Self) ?*const Work {
            self.lock();
            defer self.unlock();
            return if (self.state == .done) &self.work else null;
        }

        /// Owner thread: lets go of the owner's reference. No wake follows.
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
                // Under the lock: the owner cannot have released, so its waker lives.
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
