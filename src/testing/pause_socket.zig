//! Test-only control channel. The caller owns the controller and joins this
//! adapter before deinitializing it. The adapter takes ownership of the fd.
const std = @import("std");
const socket = @import("../os/socket.zig");
const pause = @import("pause.zig");

const WireContext = struct {
    session: ?[]const u8 = null,
    request: ?[]const u8 = null,
    operation: ?u64 = null,
    action: ?u64 = null,
    attempt: ?u64 = null,
    fn id(s: ?[]const u8) !?pause.Id {
        const value = s orelse return null;
        if (value.len != 32) return error.InvalidId;
        return value[0..32].*;
    }
    fn convert(self: WireContext) !pause.Context {
        return .{ .session = try id(self.session), .request = try id(self.request), .operation = self.operation, .action = self.action, .attempt = self.attempt };
    }
    fn from(c: *const pause.Context) WireContext {
        return .{ .session = if (c.session) |*v| v else null, .request = if (c.request) |*v| v else null, .operation = c.operation, .action = c.action, .attempt = c.attempt };
    }
};
const Request = struct {
    seq: u64,
    op: []const u8,
    point: ?[]const u8 = null,
    context: WireContext = .{},
    occurrence: ?u64 = null,
    id: ?u64 = null,
    fn selection(self: Request) !pause.Selection {
        const name = self.point orelse return error.InvalidPoint;
        inline for (std.meta.tags(pause.Point)) |point| {
            if (std.mem.eql(u8, point.wireName(), name)) return .{ .point = point, .context = try self.context.convert(), .occurrence = self.occurrence };
        }
        return error.InvalidPoint;
    }
};
const WireArrival = struct { id: u64, point: []const u8, context: WireContext, occurrence: u64 };
const Response = struct { seq: u64, err: ?[]const u8 = null, arrival: ?WireArrival = null };

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    owner: *pause.PauseController,
    fd: std.posix.fd_t,
    thread: std.Thread,
    write_mutex: std.Io.Mutex = .init,
    io: std.Io,
    workers: std.ArrayList(std.Thread) = .empty,
    start_mutex: std.Io.Mutex = .init,
    start_changed: std.Io.Condition = .init,
    started: bool = false,
    closed: bool = false,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, owner: *pause.PauseController, fd: std.posix.fd_t) !*Adapter {
        if (!pause.enabled) return error.Disabled;
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.SocketFlagsFailed;
        if (!socket.suppressSigpipe(fd)) return error.SocketFlagsFailed;
        const self = try allocator.create(Adapter);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .owner = owner, .fd = fd, .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn waitStart(self: *Adapter) !void {
        self.start_mutex.lockUncancelable(self.io);
        defer self.start_mutex.unlock(self.io);
        while (!self.started and !self.closed) self.start_changed.waitUncancelable(self.io, &self.start_mutex);
        // A peer may start and then close before this thread wakes; start
        // happened, so the close is the session's later EOF, not a refusal.
        if (!self.started) return error.Closed;
    }
    pub fn stop(self: *Adapter) void {
        _ = socket.shutdown(self.fd, 2);
        self.thread.join();
        _ = std.c.close(self.fd);
        self.workers.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn reply(self: *Adapter, response: Response) bool {
        const json = std.json.Stringify.valueAlloc(self.allocator, response, .{}) catch return false;
        defer self.allocator.free(json);
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        for ([_][]const u8{ json, "\n" }) |part| {
            var offset: usize = 0;
            while (offset < part.len) {
                const n = std.c.send(self.fd, part[offset..].ptr, part.len - offset, socket.send_flags);
                if (n <= 0) return false;
                offset += @intCast(n);
            }
        }
        return true;
    }
    const Job = struct { self: *Adapter, seq: u64, selection: pause.Selection };
    fn waitJob(job: *Job) void {
        defer job.self.allocator.destroy(job);
        const arrival = job.self.owner.wait(job.selection) catch |err| {
            _ = job.self.reply(.{ .seq = job.seq, .err = @errorName(err) });
            return;
        };
        _ = job.self.reply(.{ .seq = job.seq, .arrival = .{ .id = arrival.id, .point = arrival.point.wireName(), .context = WireContext.from(&arrival.context), .occurrence = arrival.occurrence } });
    }
    fn handle(self: *Adapter, line: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Request, self.allocator, line, .{});
        defer parsed.deinit();
        const req = parsed.value;
        self.execute(req) catch |err| {
            _ = self.reply(.{ .seq = req.seq, .err = @errorName(err) });
        };
    }
    fn execute(self: *Adapter, req: Request) !void {
        if (std.mem.eql(u8, req.op, "start")) {
            self.start_mutex.lockUncancelable(self.io);
            defer self.start_mutex.unlock(self.io);
            if (self.started) return error.AlreadyStarted;
            if (!self.reply(.{ .seq = req.seq })) return error.SocketClosed;
            self.started = true;
            self.start_changed.broadcast(self.io);
            return;
        } else if (std.mem.eql(u8, req.op, "arm")) {
            if (self.started) return error.AlreadyStarted;
            try self.owner.arm(try req.selection());
        } else if (std.mem.eql(u8, req.op, "release")) {
            try self.owner.release(req.id orelse return error.InvalidId, .proceed);
        } else if (std.mem.eql(u8, req.op, "wait")) {
            const selection = try req.selection();
            try self.workers.ensureUnusedCapacity(self.allocator, 1);
            const job = try self.allocator.create(Job);
            job.* = .{ .self = self, .seq = req.seq, .selection = selection };
            const thread = std.Thread.spawn(.{}, waitJob, .{job}) catch |err| {
                self.allocator.destroy(job);
                return err;
            };
            self.workers.appendAssumeCapacity(thread);
            return;
        } else return error.InvalidOperation;
        _ = self.reply(.{ .seq = req.seq });
    }
    fn run(self: *Adapter) void {
        defer {
            self.start_mutex.lockUncancelable(self.io);
            self.closed = true;
            self.start_changed.broadcast(self.io);
            self.start_mutex.unlock(self.io);
            self.owner.close();
            for (self.workers.items) |worker| worker.join();
        }
        var line: [8192]u8 = undefined;
        var len: usize = 0;
        while (true) {
            var data: [1]u8 = undefined;
            const n = std.c.recv(self.fd, &data, 1, 0);
            if (n <= 0) return;
            const byte = data[0];
            if (byte == '\n') {
                self.handle(line[0..len]) catch return;
                len = 0;
            } else {
                if (len == line.len) return;
                line[len] = byte;
                len += 1;
            }
        }
    }
};
