const std = @import("std");
const os = @import("os/os.zig");
const socket_os = @import("os/socket.zig");
const HostDiagnostics = @import("HostDiagnostics.zig");
const TerminalText = @import("TerminalText.zig");
const TestObservation = @import("TestObservation.zig");
const bash = @import("bash.zig");
const descriptor_capacity = @import("descriptor_capacity.zig");
const product_defaults = @import("product_defaults.zig");
const model_capability = @import("model_capability.zig");
const descriptor_limit = @import("os/descriptor_limit.zig");
const execution = @import("execution.zig");
const execution_turn = @import("execution_turn.zig");
const model_adapter = @import("model_adapter.zig");
const named_scratch = @import("named_scratch.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol.zig");
const store_module = @import("store.zig");
const stderr = @import("stderr.zig");
const server_execution = @import("server_execution.zig");
const server_host = @import("server_host.zig");
const signal_stack = @import("signal_stack.zig");
const ExecutionSlot = server_execution.ExecutionSlot;
const executionMain = server_execution.executionMain;

pub const default_bash_timeout_ms = server_host.default_bash_timeout_ms;
pub const default_bash_path = server_host.default_bash_path;
pub const scratch_limit_bytes = server_host.scratch_limit_bytes;
pub const default_retention_entry_capacity = server_host.default_retention_entry_capacity;
pub const Limits = server_host.Limits;
pub const Faults = server_host.Faults;
const Host = server_host.Host;
const fenceDispatch = server_host.fenceDispatch;
const wakeListener = server_host.wakeListener;
const nowNs = server_host.nowNs;
const beginTestObservation = server_host.beginTestObservation;
const writeTestTrace = server_host.writeTestTrace;
const traceSubject = server_host.traceSubject;
const traceRequest = server_host.traceRequest;
const executionFacts = server_host.executionFacts;
const waitAtTestGate = server_host.waitAtTestGate;
const traceSqliteDiagnostic = server_host.traceSqliteDiagnostic;

// The complete Debug request -> SQLite -> response path exceeds 512 KiB.
// Only the two shared workers reserve these stacks, independent of exchanges.
const intake_worker_stack_bytes = 1024 * 1024;

// One socket owner and one ordinary/one control local-work stack replace
// per-exchange threads. Workers never wait on peers. Complete requests waiting
// for Store access remain transient exchanges, not another pending authority.
const Intake = struct {
    host: *Host,
    wake: [2]std.posix.fd_t = undefined,
    exchanges: std.ArrayList(*Exchange) = .empty,
    polls: std.ArrayList(std.c.pollfd) = .empty,
    workers: [2]Worker = undefined,
    threads: [2]std.Thread = undefined,
    started: usize = 0,

    const Worker = struct {
        owner: *Intake,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        state: enum { idle, requested, running, done } = .idle,
        exchange: ?*Exchange = null,
        stopping: bool = false,
        failure: ?anyerror = null,
        next_state: Exchange.State = .reply,

        fn run(self: *Worker) void {
            const io = self.owner.host.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (true) {
                while (self.state != .requested and !self.stopping)
                    self.condition.waitUncancelable(io, &self.mutex);
                if (self.stopping) return;
                const exchange = self.exchange.?;
                self.state = .running;
                self.mutex.unlock(io);
                self.next_state = exchange.work() catch |err| blk: {
                    self.failure = err;
                    break :blk .retired;
                };
                self.mutex.lockUncancelable(io);
                self.state = .done;
                self.owner.notify();
            }
        }
    };

    const Exchange = struct {
        const State = enum { header, body, ready, working, reply, retired, closed };

        owner: *Intake,
        host: *Host,
        fd: std.posix.fd_t,
        accepted_at_ns: u64,
        deadline: i128,
        state: State = .header,
        job: enum { receive, prepare, fill, cleanup } = .prepare,
        header_bytes: std.ArrayList(u8) = .empty,
        input: std.ArrayList(u8) = .empty,
        route: ?Route = null,
        header: Header = undefined,
        number: ?u64 = null,
        ingress: ?*protocol.Ingress = null,
        request: ?*protocol.Request = null,
        reply: ?*Reply = null,
        retained_scratch: ?named_scratch.Owner = null,
        cleanup_retry_at: i128 = 0,

        fn retireUnhanded(self: *Exchange) void {
            // Capture handoff retains files, but grants no admission authority.
            if (self.job == .fill or self.job == .cleanup) return;
            switch (self.state) {
                .header, .body => self.state = .retired,
                // Only complete stop retries can still earn their guarded ack.
                .ready => if (self.route != .host_stop) {
                    self.state = .retired;
                },
                .working, .reply, .retired, .closed => {},
            }
        }

        fn releaseRequest(self: *Exchange) void {
            if (self.request) |request| {
                request.removeTemporaryContent(self.host.io) catch unreachable;
                self.host.allocator.destroy(request);
                self.request = null;
            }
        }

        fn closeSocket(self: *Exchange) void {
            // Only intake invalidates this descriptor, after local borrowers
            // finish. Reclamation retries retain scratch, not a finished peer.
            if (self.fd < 0) return;
            _ = std.c.close(self.fd);
            self.fd = -1;
        }

        fn canCleanupOnIntake(self: *const Exchange) bool {
            if (self.retained_scratch != null) return false;
            if (self.reply) |reply| {
                if (reply.body != .none and reply.body != .json) return false;
            }
            if (self.ingress == null and self.request == null) return true;
            // Reserved routes can own metadata, but cannot capture files.
            const route = self.route orelse return false;
            return route.isControl() or route == .host_info;
        }

        fn finishRetirement(self: *Exchange) void {
            self.closeSocket();
            // File-free retirement must not wait for a local worker while
            // holding either a classification or a total intake place.
            if (self.canCleanupOnIntake()) {
                std.debug.assert(self.cleanup());
                self.state = .closed;
            }
        }

        fn cleanup(self: *Exchange) bool {
            const host = self.host;
            if (self.reply) |reply| {
                reply.deinit();
                host.allocator.destroy(reply);
                self.reply = null;
            }
            self.releaseRequest();
            if (self.ingress) |ingress| {
                ingress.deinit();
                host.allocator.destroy(ingress);
                self.ingress = null;
            }
            self.input.deinit(host.allocator);
            self.input = .empty;
            if (self.retained_scratch) |*retained| {
                const now: i128 = nowNs(host);
                if (now < self.cleanup_retry_at) return false;
                _ = retained.reclaim(host.lease.paths.scratch.slice()) catch {
                    self.cleanup_retry_at = now + execution_turn.retained_cleanup_retry_ms * std.time.ns_per_ms;
                    return false;
                };
                self.retained_scratch = null;
            }
            return true;
        }

        fn destroy(self: *Exchange) bool {
            const host = self.host;
            std.debug.assert(self.state != .working);
            self.closeSocket();
            if (!self.cleanup()) return false;
            self.header_bytes.deinit(host.allocator);
            if (self.number) |number|
                traceRequest(host, "connection_resources_released", number, host.scratch_used.load(.acquire))
            else
                traceSubject(host, "connection_place_released", "place", "classification");
            host.allocator.destroy(self);
            return true;
        }

        fn ensureReply(self: *Exchange) !*Reply {
            if (self.reply) |reply| return reply;
            const reply = try self.host.allocator.create(Reply);
            reply.* = .{ .io = self.host.io, .allocator = self.host.allocator };
            if (self.state == .header or self.route == .host_info)
                reply.absolute_deadline = @as(i128, self.accepted_at_ns) + 10 * std.time.ns_per_s;
            self.reply = reply;
            return reply;
        }

        fn fail(self: *Exchange, err: anyerror) void {
            const reply = self.ensureReply() catch {
                self.state = .retired;
                return;
            };
            // No successful header has left while preparation is fallible.
            reply.deinit();
            const status: u16 = switch (err) {
                error.ClientCapacity, error.ControlCapacity, error.DiscoveryCapacity => 503,
                error.ScratchCapacityExhausted => 507,
                error.UnsupportedControl => 501,
                error.RequestIdentityExhausted => 500,
                else => 400,
            };
            const code = switch (err) {
                error.ClientCapacity => "ordinary_capacity_exhausted",
                error.ControlCapacity => "control_capacity_exhausted",
                error.DiscoveryCapacity => "discovery_capacity_exhausted",
                error.RequestTooLarge => if (self.route == .host_info) "DiscoveryRequestTooLarge" else "control_request_too_large",
                error.RequestIdentityExhausted => "request_identity_exhausted",
                error.UnsupportedControl => "control_surface_enters_in_later_slice",
                else => @errorName(err),
            };
            const kind: protocol.ErrorType = switch (err) {
                error.ClientCapacity, error.ControlCapacity, error.DiscoveryCapacity => .busy,
                error.UnsupportedControl => .unsupported,
                else => .invocation_error,
            };
            respondStatic(self.host.io, reply, status, kind, code);
            // Detect a disconnected predecessor before classifying another
            // peer in this socket pass. Half-closed clients still receive
            // their bounded error through the ordinary reply state.
            self.state = if (reply.advance(self.fd) catch true) .retired else .reply;
        }

        fn read(self: *Exchange) !void {
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            const wanted = if (self.ingress) |ingress|
                @min(buffer.len, ingress.options.content_length - ingress.received)
            else
                buffer.len;
            if (@as(i128, nowNs(self.host)) >= self.deadline) return error.TransferInactive;
            const result = std.c.read(self.fd, &buffer, @intCast(wanted));
            if (result < 0) switch (std.posix.errno(result)) {
                .AGAIN, .INTR => return,
                else => return error.ReadFailed,
            };
            if (result == 0) return error.UnexpectedEndOfBody;
            const bytes = buffer[0..@intCast(result)];
            var consumed: usize = 0;
            if (self.state == .header) {
                for (bytes) |byte| {
                    if (self.header_bytes.items.len == protocol.max_header_bytes) return error.HeaderTooLarge;
                    try self.header_bytes.append(self.host.allocator, byte);
                    consumed += 1;
                    const header = self.header_bytes.items;
                    if (self.route == null and std.mem.endsWith(u8, header, "\r\n")) {
                        self.route = try HeaderReader.parseRoute(header[0 .. header.len - 2]);
                        if (self.host.intake_capacity < product_defaults.intake_capacity) {
                            var ordinary: usize = 0;
                            var control: usize = 0;
                            var discovery: usize = 0;
                            for (self.owner.exchanges.items) |peer| {
                                if (peer.route) |route| {
                                    // A prior reply can finish earlier in this
                                    // same socket pass, before retirement is
                                    // serviced. Ordinary scratch custody still
                                    // counts until its worker releases it.
                                    if (peer.state == .closed or
                                        (peer.state == .retired and peer.canCleanupOnIntake())) continue;
                                    if (route.isControl()) {
                                        control += 1;
                                    } else if (route == .host_info) {
                                        discovery += 1;
                                    } else ordinary += 1;
                                }
                            }
                            if (self.route.?.isControl()) {
                                if (control > 2) return error.ControlCapacity;
                            } else if (self.route == .host_info) {
                                if (discovery > 1) return error.DiscoveryCapacity;
                            } else if (ordinary > self.host.intake_capacity) return error.ClientCapacity;
                        }
                        if (!self.route.?.isControl() and self.route != .host_info)
                            traceSubject(self.host, "ordinary_classification_released", "route", @tagName(self.route.?));
                    }
                    if (!std.mem.endsWith(u8, header, "\r\n\r\n")) continue;
                    self.header = try HeaderReader.parseFields(header, self.route.?);
                    if (self.route == .unsupported_control) return error.UnsupportedControl;
                    self.number = try nextRequestNumber(self.host);
                    switch (self.route.?) {
                        inline else => |route| traceRequest(self.host, "connection_request_" ++ @tagName(route), self.number.?, null),
                    }
                    const limit: u64 = switch (self.route.?) {
                        .host_info => protocol.max_host_info_request_bytes,
                        .host_stop => protocol.max_host_stop_request_bytes,
                        .session_stop => protocol.max_session_stop_request_bytes,
                        .model_interruption => protocol.max_model_interruption_request_bytes,
                        .permission_decision => protocol.max_permission_decision_request_bytes,
                        else => std.math.maxInt(u64),
                    };
                    if (self.header.content_length > limit) return error.RequestTooLarge;
                    const ingress = try self.host.allocator.create(protocol.Ingress);
                    ingress.* = protocol.Ingress.init(self.host.allocator, .{
                        .io = self.host.io,
                        .fd = self.fd,
                        .content_length = self.header.content_length,
                        .scratch_path = self.host.lease.paths.scratch.slice(),
                        .request_number = self.number.?,
                        .fault_content_acquire = self.host.faults.content_acquire,
                        .fault_content_write = self.host.faults.content_write,
                        .fault_content_seal = self.host.faults.content_seal,
                        .retained_scratch = &self.retained_scratch,
                        .scratch_budget = self.host.retention.sharedBudget(),
                        .expected_kind = self.route.?.kind(),
                    });
                    self.ingress = ingress;
                    self.state = .body;
                    self.header_bytes.deinit(self.host.allocator);
                    self.header_bytes = .empty;
                    break;
                }
            }
            if (self.state != .body) return;
            if (self.route != .host_info)
                self.deadline = @as(i128, nowNs(self.host)) + 60 * std.time.ns_per_s;
            if (self.route == .configure or self.route == .message) {
                // One bounded window is borrowed by local capture work. No
                // socket read or peer wait runs on those shared stacks.
                try self.input.appendSlice(self.host.allocator, bytes[consumed..]);
                self.job = .receive;
                self.state = .ready;
            } else self.state = try self.receive(bytes[consumed..]);
        }

        fn receive(self: *Exchange, bytes: []const u8) !State {
            const ingress = self.ingress.?;
            try ingress.feed(bytes);
            if (ingress.received == ingress.options.content_length) {
                const request = try self.host.allocator.create(protocol.Request);
                errdefer self.host.allocator.destroy(request);
                request.* = try ingress.finish();
                self.request = request;
                ingress.deinit();
                self.host.allocator.destroy(ingress);
                self.ingress = null;
                self.input.deinit(self.host.allocator);
                self.input = .empty;
                return .ready;
            }
            return .body;
        }

        fn prepare(self: *Exchange) !void {
            // Reply owns all prepared bytes/readers. Imported ingress is no
            // longer borrowed, even when a peer holds acknowledgment delivery.
            defer self.releaseRequest();
            const reply = try self.ensureReply();
            try prepareReply(self.host, reply, self.fd, self.header, self.number.?, self.accepted_at_ns, self.request.?);
        }

        fn work(self: *Exchange) !State {
            return switch (self.job) {
                .receive => {
                    const state = try self.receive(self.input.items);
                    self.input.clearRetainingCapacity();
                    return state;
                },
                .prepare => blk: {
                    try self.prepare();
                    break :blk .reply;
                },
                .fill => blk: {
                    try self.reply.?.fill();
                    break :blk .reply;
                },
                .cleanup => if (self.cleanup()) .closed else .retired,
            };
        }
    };

    fn init(self: *Intake, host: *Host) !void {
        self.* = .{ .host = host };
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &self.wake) != 0) return error.IntakeWakeFailed;
        errdefer {
            _ = std.c.close(self.wake[0]);
            _ = std.c.close(self.wake[1]);
        }
        for (self.wake) |fd| try setNonblocking(fd);
        errdefer self.stopWorkers();
        for (&self.workers, &self.threads) |*worker, *thread| {
            worker.* = .{ .owner = self };
            thread.* = try signal_stack.spawn(.{ .stack_size = intake_worker_stack_bytes }, Worker.run, .{worker});
            self.started += 1;
        }
    }

    fn stopWorkers(self: *Intake) void {
        for (self.workers[0..self.started]) |*worker| {
            worker.mutex.lockUncancelable(self.host.io);
            worker.stopping = true;
            worker.condition.signal(self.host.io);
            worker.mutex.unlock(self.host.io);
        }
        for (self.threads[0..self.started]) |thread| thread.join();
        self.started = 0;
    }

    fn deinit(self: *Intake) void {
        self.stopWorkers();
        for (self.exchanges.items) |exchange| {
            // Joining workers, not response delivery, ends their borrowing.
            exchange.state = .retired;
            while (!exchange.destroy())
                self.host.io.sleep(.fromMilliseconds(execution_turn.retained_cleanup_retry_ms), .awake) catch {};
        }
        self.exchanges.deinit(self.host.allocator);
        self.polls.deinit(self.host.allocator);
        for (self.wake) |fd| _ = std.c.close(fd);
    }

    fn notify(self: *Intake) void {
        // Coalesced hints: a full nonblocking socket is already readable.
        _ = std.c.write(self.wake[1], "x", 1);
    }

    fn serviceWorkers(self: *Intake) void {
        // Retire peers even when both workers are busy or cleanup is not due.
        for (self.exchanges.items) |exchange| {
            if (exchange.state == .retired) exchange.finishRetirement();
        }
        for (&self.workers, 0..) |*worker, worker_index| {
            worker.mutex.lockUncancelable(self.host.io);
            defer worker.mutex.unlock(self.host.io);
            if (worker.state == .done) {
                const exchange = worker.exchange.?;
                if (worker.failure) |err| {
                    if (exchange.job != .fill) exchange.fail(err) else {
                        // Delivery already began. Never append a second reply.
                        if (self.host.store.isFenced()) fenceDispatch(self.host, "reply content", err);
                        exchange.state = .retired;
                    }
                } else {
                    exchange.state = worker.next_state;
                    if (exchange.job == .receive) {
                        if (exchange.state == .ready) exchange.job = .prepare;
                        if (exchange.state == .body)
                            exchange.deadline = @as(i128, nowNs(self.host)) + 60 * std.time.ns_per_s;
                    }
                }
                if (exchange.state == .retired) exchange.finishRetirement();
                worker.failure = null;
                worker.exchange = null;
                worker.state = .idle;
            }
            if (worker.state != .idle) continue;
            // Ordinary capture, fill and cleanup cannot exhaust control work.
            // Neither lane can preempt a canonical Store operation.
            var next: ?*Exchange = null;
            for (self.exchanges.items) |exchange| {
                const control = if (exchange.route) |route| route.isControl() else false;
                if (control != (worker_index == 1)) continue;
                if (exchange.state == .retired and nowNs(self.host) >= exchange.cleanup_retry_at) {
                    if (next == null) next = exchange;
                    continue;
                }
                if (exchange.state != .ready) continue;
                if (exchange.route == .host_info or exchange.route == .host_stop) continue;
                if (next == null) next = exchange;
            }
            if (next) |exchange| {
                // Share the shutdown/launch gate only through handoff. Never
                // hold it across Store I/O or draining an already-owned reply.
                self.host.launch_mutex.lockUncancelable(self.host.io);
                defer self.host.launch_mutex.unlock(self.host.io);
                if (exchange.state == .retired) {
                    exchange.job = .cleanup;
                } else {
                    if (self.host.stopping()) exchange.retireUnhanded();
                    if (exchange.state == .retired) continue;
                }
                exchange.state = .working;
                worker.exchange = exchange;
                worker.state = .requested;
                worker.condition.signal(self.host.io);
            }
        }
    }

    fn run(self: *Intake, listener: *std.Io.net.Server, listener_open: *bool, socket_owned: *bool) !void {
        try setNonblocking(listener.socket.handle);
        var failure: ?anyerror = null;
        var accept_retry_at: i128 = 0;
        while (true) {
            // Drain before rechecking: a hint written after this read stays
            // readable, so the bounded poll below cannot sleep past it.
            var bytes: [256]u8 = undefined;
            while (std.c.read(self.wake[0], &bytes, bytes.len) > 0) {}
            if (self.host.stopping()) {
                for (self.exchanges.items) |exchange| exchange.retireUnhanded();
            }
            self.serviceWorkers();
            if (self.host.stopping() and listener_open.*) {
                listener.deinit(self.host.io);
                listener_open.* = false;
                std.Io.Dir.deleteFileAbsolute(self.host.io, self.host.lease.paths.socket.slice()) catch |err|
                    stderr.print("rui: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
                socket_owned.* = false;
            }
            const now: i128 = nowNs(self.host);
            self.polls.clearRetainingCapacity();
            // A readable backlog stays readable when accept cannot acquire a
            // descriptor or kernel memory. Pause only acquisition, not peers,
            // workers or shutdown, and avoid spinning on that same readiness.
            try self.polls.append(self.host.allocator, .{ .fd = if (listener_open.* and now >= accept_retry_at) listener.socket.handle else -1, .events = std.posix.POLL.IN, .revents = 0 });
            try self.polls.append(self.host.allocator, .{ .fd = self.wake[0], .events = std.posix.POLL.IN, .revents = 0 });
            // Sleep until the earliest owned deadline. Workers and shutdown
            // write the wake pipe; one second bounds any unowned change.
            var wake_at: i128 = now + std.time.ns_per_s;
            if (listener_open.* and now < accept_retry_at) wake_at = @min(wake_at, accept_retry_at);
            for (self.exchanges.items) |exchange| {
                var fd: std.posix.fd_t = -1;
                var events: i16 = std.posix.POLL.IN;
                switch (exchange.state) {
                    .header, .body => {
                        if (now >= exchange.deadline) {
                            exchange.fail(error.TransferInactive);
                            wake_at = now;
                        } else {
                            fd = exchange.fd;
                            wake_at = @min(wake_at, exchange.deadline);
                        }
                    },
                    .ready => if (exchange.route == .host_info or exchange.route == .host_stop) {
                        exchange.state = .reply;
                        exchange.prepare() catch |err| exchange.fail(err);
                        wake_at = now;
                    },
                    .reply => {
                        if (exchange.reply) |reply| {
                            if (reply.body == .none or now >= reply.deadline()) {
                                exchange.state = .retired;
                                wake_at = now;
                            } else if (reply.deliveryReady() catch false) {
                                if (reply.needsFill()) {
                                    exchange.job = .fill;
                                    exchange.state = .ready;
                                } else {
                                    fd = exchange.fd;
                                    events = std.posix.POLL.OUT;
                                    wake_at = @min(wake_at, reply.deadline());
                                }
                            } else {
                                // Test delivery holds: a FIFO gate has no
                                // readiness here, so keep checking it briefly.
                                wake_at = @min(wake_at, reply.deadline(), if (reply.gate != null) now + 20 * std.time.ns_per_ms else reply.not_before_ns);
                            }
                        } else {
                            exchange.state = .retired;
                            wake_at = now;
                        }
                    },
                    .working, .retired, .closed => {},
                }
                try self.polls.append(self.host.allocator, .{ .fd = fd, .events = events, .revents = 0 });
            }
            self.serviceWorkers();
            // Worker results applied above can leave closures to destroy or
            // cleanup to retry. A worker owns its exchange's fields meanwhile.
            for (self.exchanges.items) |exchange| {
                if (exchange.state == .working) continue;
                if (exchange.cleanup_retry_at > now) {
                    wake_at = @min(wake_at, exchange.cleanup_retry_at);
                } else if (exchange.state == .closed) wake_at = now;
            }
            const wait_ms: c_int = @intCast(@divFloor(@max(wake_at - now, 0) + std.time.ns_per_ms - 1, std.time.ns_per_ms));
            const count = std.c.poll(self.polls.items.ptr, @intCast(self.polls.items.len), wait_ms);
            if (count < 0 and std.posix.errno(count) != .INTR) return error.IntakePollFailed;
            for (self.exchanges.items, self.polls.items[2..]) |exchange, poll| {
                if (poll.revents == 0) continue;
                switch (exchange.state) {
                    .header, .body => exchange.read() catch |err| exchange.fail(err),
                    .reply => {
                        const reply = exchange.reply.?;
                        const complete = reply.advance(exchange.fd) catch |err| {
                            if (self.host.store.isFenced()) fenceDispatch(self.host, "reply content", err);
                            exchange.state = .retired;
                            continue;
                        };
                        if (complete) {
                            if (reply.timing) |*timing| timing.replyComplete();
                            exchange.state = .retired;
                        }
                    },
                    else => {},
                }
            }
            self.retireExchanges();
            if (!listener_open.* and self.exchanges.items.len == 0) return failure orelse error.EffectAwareShutdown;
            if (!listener_open.* or self.polls.items[0].revents == 0) continue;
            // Accept a bounded batch, then return to existing exchanges.
            for (0..16) |_| {
                if (self.host.intake_capacity < product_defaults.intake_capacity and
                    self.exchanges.items.len >= self.host.intake_capacity + 3)
                {
                    // Unknown routes cannot hold all reserved progress places.
                    // Release one before accepting its successor: never acquire
                    // an unbudgeted descriptor or evict classified work. Stop
                    // this batch so survivors get a read turn before turnover.
                    for (self.exchanges.items, 0..) |peer, peer_index| {
                        if (peer.state == .header and peer.route == null) {
                            const destroyed = peer.destroy();
                            std.debug.assert(destroyed);
                            _ = self.exchanges.orderedRemove(peer_index);
                            break;
                        }
                    }
                    accept_retry_at = @as(i128, nowNs(self.host)) + 100 * std.time.ns_per_ms;
                    break;
                }
                const fd = self.acceptSocket(listener.socket.handle) catch |err| switch (err) {
                    error.NoClient => break,
                    error.AcceptCapacity => {
                        accept_retry_at = @as(i128, nowNs(self.host)) + 100 * std.time.ns_per_ms;
                        break;
                    },
                    error.SocketFlagsFailed => {
                        stderr.print("rui: intake unavailable: SocketFlagsFailed; recover original request\n", .{});
                        continue;
                    },
                    else => return err,
                };
                self.accept(fd) catch |err| {
                    _ = std.c.close(fd);
                    stderr.print("rui: intake unavailable: {s}; recover original request\n", .{@errorName(err)});
                };
                if (self.host.faults.shutdown_after_accept) {
                    failure = error.InjectedListenerFailure;
                    _ = self.host.advance(.stopping);
                    break;
                }
                // Give a newly acquired reserved place a classification turn
                // before considering it for pressure-driven turnover.
                if (self.host.intake_capacity < product_defaults.intake_capacity and
                    self.exchanges.items.len >= self.host.intake_capacity + 3) break;
            }
        }
    }

    fn retireExchanges(self: *Intake) void {
        var index: usize = 0;
        while (index < self.exchanges.items.len) {
            const exchange = self.exchanges.items[index];
            // Finish this socket pass's retirements before considering the
            // listener. No unclassified peer needs evicting for a freed place.
            if (exchange.state == .retired) exchange.finishRetirement();
            if (exchange.state != .closed) {
                index += 1;
                continue;
            }
            if (exchange.destroy()) {
                _ = self.exchanges.orderedRemove(index);
            } else index += 1;
        }
    }

    fn acceptSocket(self: *Intake, listener: std.posix.fd_t) !std.posix.fd_t {
        // A child must never copy a socket before CLOEXEC is installed. Keep
        // only native acquisition/flagging (and failure-close) under the same
        // gate as Prepared.launch, not exchange allocation or peer service.
        self.host.launch_mutex.lockUncancelable(self.host.io);
        defer self.host.launch_mutex.unlock(self.host.io);
        const fd = std.c.accept(listener, null, null);
        if (fd < 0) return switch (std.posix.errno(fd)) {
            .AGAIN, .INTR, .CONNABORTED => error.NoClient,
            .MFILE, .NFILE, .NOBUFS, .NOMEM => error.AcceptCapacity,
            else => error.IntakeAcceptFailed,
        };
        errdefer _ = std.c.close(fd);
        try setNonblocking(fd);
        return fd;
    }

    fn accept(self: *Intake, fd: std.posix.fd_t) !void {
        if (self.host.limits.client_send_buffer_bytes) |bytes| {
            var value: c_int = @intCast(bytes);
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&value));
        }
        const exchange = try self.host.allocator.create(Exchange);
        errdefer self.host.allocator.destroy(exchange);
        const accepted_at_ns = nowNs(self.host);
        exchange.* = .{ .owner = self, .host = self.host, .fd = fd, .accepted_at_ns = accepted_at_ns, .deadline = @as(i128, accepted_at_ns) + 10 * std.time.ns_per_s };
        try self.exchanges.append(self.host.allocator, exchange);
    }
};

fn setNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking) < 0 or
        std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.SocketFlagsFailed;
}

extern "c" fn rui_write_readiness(fd: c_int, bytes: [*]const u8, length: usize) c_int;

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    store_path: []const u8,
    active_capacity: usize,
    limits: Limits,
    faults: Faults,
    provider_endpoint: ?[]const u8,
    provider_ca_file: ?[]const u8,
    authentication: ?model_adapter.Authentication,
    bash_path: []const u8,
    bash_timeout_ms: u64,
    home: ?[]const u8,
) !void {
    // The Host owns child waits. Automatic reaping or an inherited handler
    // would release process identities before their signal owners retire.
    const child_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &child_action, null);
    var descriptor_observation = try descriptor_limit.observe(io);
    var descriptor_requirement = try descriptor_capacity.calculate(
        descriptor_observation.open_descriptors,
        active_capacity,
        product_defaults.intake_capacity,
        3, // Two controls and concurrent discovery.
        provider_endpoint != null,
        authentication != null,
        os.tag,
    );
    if (descriptor_observation.soft_limit) |limit| {
        if (limit < descriptor_requirement.total) {
            descriptor_limit.raise(descriptor_requirement.total);
            descriptor_observation = try descriptor_limit.observe(io);
        }
    }
    const intake_capacity = descriptor_capacity.fitIntake(descriptor_requirement.total, descriptor_observation.soft_limit) catch |err| {
        if (err == error.DescriptorCapacityInsufficient) {
            stderr.print(
                "rui: Host cannot start: descriptor soft limit {d} is below the minimum intake requirement {d} (10 ordinary clients). Rui already tried raising it. Inspect limits with ulimit -Sn and ulimit -Hn; raise the hard limit in your system/session settings (ask your administrator if needed), then retry rui host start.\n",
                .{ descriptor_observation.soft_limit.?, descriptor_requirement.total - 4 * (product_defaults.intake_capacity - descriptor_capacity.minimum_intake) },
            );
            stderr.print(
                "rui: descriptor capacity insufficient: active_capacity={d} required={d} soft_limit={d} inherited={d} fixed_host={d} clients={d} execution={d} authentication={d} self_wake={d} (required is for default intake; RLIMIT_NOFILE).\n",
                .{
                    active_capacity,
                    descriptor_requirement.total,
                    descriptor_observation.soft_limit.?,
                    descriptor_requirement.inherited,
                    descriptor_requirement.fixed_host,
                    descriptor_requirement.clients,
                    descriptor_requirement.execution,
                    descriptor_requirement.authentication,
                    descriptor_requirement.self_wake,
                },
            );
        }
        return err;
    };
    descriptor_requirement = try descriptor_capacity.calculate(
        descriptor_observation.open_descriptors,
        active_capacity,
        intake_capacity,
        3,
        provider_endpoint != null,
        authentication != null,
        os.tag,
    );
    var descriptor_limit_buffer: [32]u8 = undefined;
    const descriptor_limit_text = if (descriptor_observation.soft_limit) |limit|
        try std.fmt.bufPrint(&descriptor_limit_buffer, "{d}", .{limit})
    else
        "unlimited";
    var lease = try platform.StoreLease.acquire(io, store_path);
    defer lease.release();
    // fd1 may alias fd2. Exclude flag borrowing before any continuing
    // startup diagnostic, through readiness delivery and failed unwind.
    if (!stderr.tryExclude()) return error.HostReadinessOutputUnavailable;
    var readiness_owned = true;
    defer if (readiness_owned) stderr.release();
    // Only the lease winner warns, before readiness. Preferences are advice
    // for future Sessions: unreadable/missing defaults must not stop this Host
    // from serving existing work, and an unsupported saved pin stays intact.
    if (home) |absolute_home| {
        const saved = @import("preferences.zig").load(absolute_home) catch null;
        if (saved) |values| {
            if (values.model.len != 0 and !model_capability.supportsModel(values.model.slice())) {
                var bytes: [4 * protocol.max_model_bytes + model_capability.model_help.len + 384]u8 = undefined;
                var out = std.Io.Writer.fixed(&bytes);
                try out.writeAll("rui: saved new-Session default model \"");
                var text: TerminalText = .{ .mode = .line };
                try text.feed(&out, values.model.slice());
                try text.finish(&out);
                try out.writeAll("\" is unsupported by this release; it has not been changed.\n" ++ model_capability.model_help ++
                    "Choose rui defaults configure --model ID, or remove the saved pin with rui defaults configure --clear-model. Existing Sessions are unchanged.\n");
                _ = stderr.writeHeld(out.buffered());
            }
        }
    }
    var diagnostic_open_error: ?anyerror = null;
    var diagnostics: ?HostDiagnostics = HostDiagnostics.open(io, lease.store_dir, HostDiagnostics.default_cap_bytes) catch |err| blk: {
        diagnostic_open_error = err;
        break :blk null;
    };
    defer if (diagnostics) |*writer| writer.close();
    if (diagnostics) |*writer| writer.record("begin", "lease_acquired");
    if (diagnostics) |*writer| {
        var detail: [256]u8 = undefined;
        writer.record("capacity", try std.fmt.bufPrint(&detail, "ordinary_intake={d} default_intake={d} minimum_intake={d} descriptor_requirement={d} descriptor_limit={s}", .{
            intake_capacity,              product_defaults.intake_capacity, descriptor_capacity.minimum_intake,
            descriptor_requirement.total, descriptor_limit_text,
        }));
    }
    errdefer if (diagnostics) |*writer| writer.record("failed", "startup_error");
    var found_schema_version: u32 = store_module.schema_version;
    var storage = store_module.Store.openWithOptions(
        io,
        lease.paths.database.slice(),
        lease.paths.store.slice(),
        .{ .cache_spill = limits.sqlite_cache_spill, .cache_kib = limits.sqlite_cache_kib, .found_schema_version = &found_schema_version },
    ) catch |err| {
        if (err == error.WrongStoreVersion) {
            var message: [4 * protocol.max_store_bytes + 512]u8 = undefined;
            var output = std.Io.Writer.fixed(&message);
            const reason = if (found_schema_version == store_module.schema_version)
                "unsupported or missing Store wire metadata"
            else
                "unsupported Store format";
            try output.print("rui: {s} at ", .{reason});
            var path_text: TerminalText = .{ .mode = .line };
            try path_text.feed(&output, lease.paths.store.slice());
            try path_text.finish(&output);
            try output.print(": found schema {d}, this build supports schema {d} (wire {s}). Use a compatible Rui build at the Store's original path, or back up this Store and choose a fresh Store with --store. No migration was performed; do not delete your saved work. See https://github.com/DivyanshGolyan/rui#start-fresh-after-a-store-format-change\n", .{
                found_schema_version, store_module.schema_version, protocol.wire_version,
            });
            const text = output.buffered();
            _ = rui_write_readiness(2, text.ptr, text.len);
            if (diagnostics) |*writer| writer.record("failed", "unsupported_store_version");
        }
        return err;
    };
    defer storage.close() catch |err| stderr.print("rui: Store close failed: {s}\n", .{@errorName(err)});
    try storage.validateRetryWaits(limits.retry_waits_ms);
    try lease.prepareForServing(faults.startup_cleanup);

    const address = try std.Io.net.UnixAddress.init(lease.paths.socket.slice());
    var listener = try address.listen(io, .{ .kernel_backlog = 128 });
    var listener_open = true;
    var socket_owned = true;
    errdefer {
        if (listener_open) listener.deinit(io);
        if (socket_owned) std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
            stderr.print("rui: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
        };
    }
    var socket_path: [257:0]u8 = undefined;
    const socket_z = try std.fmt.bufPrintSentinel(&socket_path, "{s}", .{lease.paths.socket.slice()}, 0);
    if (std.c.chmod(socket_z, 0o600) != 0) return error.SocketProtectionFailed;

    var bash_environment = try bash.environment(io, allocator, home);
    defer bash_environment.deinit();
    // Zero bytes are an empty custody record and retention entry, so fresh
    // pages need no initializing pass and an unused one never becomes resident.
    const custody_records = try server_host.mapZeroed(execution.CustodyRecord, active_capacity);
    defer server_host.unmapZeroed(custody_records);
    const retention_capacity = @min(
        default_retention_entry_capacity,
        limits.retention_entry_capacity orelse default_retention_entry_capacity,
    );
    const retention_entries = try server_host.mapZeroed(output_retention.Entry, retention_capacity);
    defer server_host.unmapZeroed(retention_entries);
    var host = Host{
        .io = io,
        .allocator = allocator,
        .intake_capacity = intake_capacity,
        .descriptor_soft_limit = descriptor_observation.soft_limit,
        .lease = &lease,
        .store = &storage,
        .faults = faults,
        .limits = limits,
        .provider_endpoint = provider_endpoint,
        .provider_ca_file = provider_ca_file,
        .authentication = authentication,
        .bash_path = bash_path,
        .bash_environment = &bash_environment,
        .bash_timeout_ms = bash_timeout_ms,
        .retention = undefined,
        .trace_run_ns = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds),
        .custody = execution.CustodyPool.initialize(custody_records),
    };
    var observation: ?TestObservation = if (faults.test_observation_fd) |fd|
        try TestObservation.init(fd, faults.test_observation_state_fd orelse return error.MissingTestObservationState, faults.test_observation_plan orelse return error.MissingTestObservationPlan, host.trace_run_ns)
    else
        null;
    // This scope outlives connection, execution and capture-writer joins.
    defer if (observation) |*writer| writer.close();
    host.test_observation = if (observation) |*writer| writer else null;
    var retention = output_retention.Queue.initializeWithRemoval(
        io,
        lease.paths.scratch.slice(),
        .{ .used = &host.scratch_used, .limit = scratch_limit_bytes },
        retention_entries,
        if (faults.retention_removal) .injected_failure else .native,
    );
    host.retention = &retention;
    defer retention.cleanupAll();
    host.failed_response_store = lease.store_dir;
    if (provider_endpoint) |endpoint| {
        try provider.validateEndpoint(endpoint);
        if (authentication) |selected| try model_adapter.validateAuthenticationEndpoint(endpoint, provider_ca_file, selected);
        try provider.checkLibraries();
    }
    try std.Io.randomSecure(io, &host.instance);
    var intake: Intake = undefined;
    try intake.init(&host);
    defer intake.deinit();
    host.intake_wake = intake.wake[1];
    const execution_thread = try signal_stack.spawn(.{}, executionMain, .{&host});
    defer {
        // Stop admitting new connections before releasing any Host-owned
        // execution or request custody. Store and lease outlive both drains.
        if (listener_open) listener.deinit(io);
        listener_open = false;
        if (socket_owned) std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
            // The lock still protects this failed cleanup. A later startup
            // removes the owned socket or refuses to serve if it cannot.
            stderr.print("rui: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
        };
        socket_owned = false;
        _ = host.advance(.draining);
        execution_thread.join();
    }
    var ready: protocol.ResponseBuffer = .{};
    try ready.appendFmt("ready store={s} socket={s} active_capacity={d} intake_capacity={d} descriptor_requirement={d} descriptor_limit={s} custody_record_bytes={d} execution_slot_bytes={d} model_preparation_bytes={d} scratch_limit_bytes={d} retention_entry_bytes={d} retention_capacity={d} bash_execution=enabled execution={s}", .{
        lease.paths.store.slice(),
        lease.paths.socket.slice(),
        active_capacity,
        intake_capacity,
        descriptor_requirement.total,
        descriptor_limit_text,
        @sizeOf(execution.CustodyRecord),
        @sizeOf(ExecutionSlot),
        @sizeOf(model_adapter.Preparation),
        scratch_limit_bytes,
        @sizeOf(output_retention.Entry),
        retention_entries.len,
        if (provider_endpoint != null) "enabled" else "unavailable",
    });
    if (provider_endpoint != null) {
        try ready.appendFmt(" nghttp2={s} openssl={s}", .{ provider.nghttp2_version, provider.openssl_version });
    }
    try ready.append("\n");
    if (rui_write_readiness(1, ready.slice().ptr, ready.slice().len) != 0)
        return error.HostReadinessOutputUnavailable;
    stderr.release();
    readiness_owned = false;
    if (diagnostic_open_error) |err|
        stderr.print("rui: startup diagnostics unavailable ({s}); continuing under Store lease\n", .{@errorName(err)});
    if (diagnostics) |*writer| {
        if (writer.failure != null) writer.reportFailure();
        writer.record("ready", "serving");
        writer.close();
        diagnostics = null;
    }

    return intake.run(&listener, &listener_open, &socket_owned);
}

fn publishControlHint(host: *Host, command_key: []const u8) void {
    if (host.faults.suppress_first_control_hint and
        !host.control_hint_suppressed.swap(true, .acq_rel))
    {
        traceSubject(host, "control_hint_suppressed", "command_key", command_key);
        return;
    }
    host.controls_changed.store(true, .release);
    traceSubject(host, "control_hint_published", "command_key", command_key);
}

const ControlTiming = struct {
    host: *Host,
    command_key: protocol.Bounded(protocol.max_key_bytes),
    kind: []const u8,
    accepted_at_ns: u64,
    store_queued_ns: u64 = 0,
    lock_acquired_ns: u64 = 0,
    store_complete_ns: u64 = 0,

    fn init(host: *Host, command_key: protocol.Bounded(protocol.max_key_bytes), kind: []const u8, accepted_at_ns: u64) ControlTiming {
        return .{
            .host = host,
            .command_key = command_key,
            .kind = kind,
            .accepted_at_ns = accepted_at_ns,
        };
    }

    fn storeTrace(self: *ControlTiming) ?store_module.ControlTrace {
        if (!self.host.faults.test_phase_trace) return null;
        return .{ .context = self, .mark_fn = markStore };
    }

    fn markStore(context: *anyopaque, phase: store_module.ControlTracePhase) void {
        const self: *ControlTiming = @ptrCast(@alignCast(context));
        switch (phase) {
            .lock_requested => {
                self.store_queued_ns = nowNs(self.host);
                traceSubject(self.host, "control_store_queued", "command_key", self.command_key.slice());
            },
            .lock_acquired => {
                self.lock_acquired_ns = nowNs(self.host);
                traceSubject(self.host, "control_lock_acquired", "command_key", self.command_key.slice());
                self.waitAtTestGate();
            },
            .durable_acceptance => {
                traceSubject(self.host, "control_durable_acceptance", "command_key", self.command_key.slice());
            },
            .store_complete => {
                self.store_complete_ns = nowNs(self.host);
                traceSubject(self.host, "control_store_complete", "command_key", self.command_key.slice());
            },
        }
    }

    fn waitAtTestGate(self: *ControlTiming) void {
        const keys = self.host.faults.control_gate_keys orelse return;
        const path = self.host.faults.control_gate_path orelse return;
        var candidates = std.mem.splitScalar(u8, keys, ',');
        while (candidates.next()) |candidate| {
            if (!std.mem.eql(u8, candidate, self.command_key.slice())) continue;
            // Integration tests deliberately hold this acquired Store mutex
            // until intake routes a competing control. Their keeper
            // descriptor prevents FIFO-open deadlock; process teardown bounds
            // a missing release without granting this gate semantic authority.
            var gate = std.Io.Dir.cwd().openFile(self.host.io, path, .{}) catch return;
            defer gate.close(self.host.io);
            var release: [1]u8 = undefined;
            const count = gate.readStreaming(self.host.io, &.{&release}) catch return;
            if (count == 1) traceSubject(self.host, "control_gate_released", "command_key", self.command_key.slice());
            return;
        }
    }

    fn replyComplete(self: *ControlTiming) void {
        if (!self.host.faults.test_phase_trace) return;
        const reply_complete_ns = nowNs(self.host);
        if (self.store_queued_ns == 0 or self.lock_acquired_ns == 0 or self.store_complete_ns == 0) return;
        var publication = beginTestObservation(self.host, "control_timing", null);
        defer if (publication) |*value| value.finish();
        var trace: protocol.ResponseBuffer = .{};
        trace.append("{\"rui_test_phase\":\"control_timing\",\"command_key\":") catch return;
        trace.appendJsonString(self.command_key.slice()) catch return;
        trace.append(",\"kind\":") catch return;
        trace.appendJsonString(self.kind) catch return;
        trace.appendFmt(",\"store_queued_at_ns\":\"{d}\",\"lock_acquired_at_ns\":\"{d}\",\"store_complete_at_ns\":\"{d}\",\"reply_complete_at_ns\":\"{d}\",\"queue_wait_ns\":\"{d}\",\"store_lock_wait_ns\":\"{d}\",\"store_service_ns\":\"{d}\",\"post_commit_reply_ns\":\"{d}\",\"host_total_ns\":\"{d}\"}}", .{
            self.store_queued_ns,
            self.lock_acquired_ns,
            self.store_complete_ns,
            reply_complete_ns,
            self.store_queued_ns - self.accepted_at_ns,
            self.lock_acquired_ns - self.store_queued_ns,
            self.store_complete_ns - self.lock_acquired_ns,
            reply_complete_ns - self.store_complete_ns,
            reply_complete_ns - self.accepted_at_ns,
        }) catch return;
        writeTestTrace(self.host, &trace, &publication);
    }
};

const Route = enum {
    host_info,
    host_stop,
    configure,
    message,
    session_stop,
    model_interruption,
    permission_decision,
    observe,
    read_result,
    read_action_call_id,
    read_action_arguments,
    inspect,
    list_sessions,
    conversation_page,
    conversation_content,
    proposal_page,
    proposal_field,
    activity_page,
    activity_content,
    unsupported_control,

    fn isControl(self: Route) bool {
        return self == .host_stop or self == .session_stop or self == .model_interruption or self == .permission_decision or self == .unsupported_control;
    }

    fn kind(self: Route) protocol.Kind {
        return switch (self) {
            .observe => .observe_command,
            .inspect => .inspect_session,
            .unsupported_control => unreachable,
            inline else => |route| @field(protocol.Kind, @tagName(route)),
        };
    }
};
const DropMode = enum { none, before_admission, during_admission, after_commit };

const Header = struct {
    route: Route,
    content_length: u64,
    drop: DropMode = .none,
    instance: ?protocol.InstanceId = null,
};

fn prepareReply(host: *Host, fd: *Reply, socket: std.posix.fd_t, header: Header, request_number: u64, accepted_at_ns: u64, request: *protocol.Request) !void {
    if (!std.mem.eql(u8, request.store(), host.lease.paths.store.slice())) {
        return respondStatic(host.io, fd, 409, .invocation_error, "wrong_store_identity");
    }
    if (header.instance) |instance| {
        if (!std.mem.eql(u8, &instance, &host.instance)) {
            return respondStatic(host.io, fd, 409, .invocation_error, "host_instance_changed");
        }
    }
    if (header.route == .host_stop and header.instance == null) {
        return respondStatic(host.io, fd, 400, .invocation_error, "host_instance_required");
    }
    if (header.drop == .before_admission) return;
    if (header.drop == .during_admission and socket_os.shutdown(socket, std.c.SHUT.RDWR) == .failed) {
        return error.InjectedDisconnectFailed;
    }

    switch (request.*) {
        .host_info => {
            if (!host.launchAllowed()) return respondStatic(host.io, fd, 503, .host_unavailable, "dispatch_fenced");
            var response: protocol.ResponseBuffer = .{};
            try renderHostInfo(&response, host.lease.paths.store.slice(), host.instance, host.custody.records.len, host.intake_capacity, host.descriptor_soft_limit, host.provider_endpoint != null, host.provider_endpoint != null and host.authentication != null);
            try fd.setJson(200, response.slice());
        },
        .host_stop => {
            if (host.advance(.stopping) != .stopping) wakeListener(host);
            if (header.drop != .after_commit) deliverResponse(host.io, fd, 200, protocol.host_stop_ack);
        },
        .configure => |*command| {
            const result = host.store.configure(command, host.provider_endpoint != null, .{
                .content_read = host.faults.content_read,
                .content_import = host.faults.content_import,
                .before_commit = host.faults.before_commit,
            });
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "configuration save", error.CanonicalStoreFailure);
            }
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            var response: protocol.ResponseBuffer = .{};
            try renderConfigureReply(&response, command, result);
            const status: u16 = switch (result) {
                .accepted, .rejected => 200,
                .conflict => 409,
                .infrastructure_failure => 500,
            };
            deliverResponse(host.io, fd, status, response.slice());
        },
        .message => |*command| {
            const result = host.store.submitMessage(command, .{
                .content_read = host.faults.content_read,
                .content_import = host.faults.content_import,
                .before_commit = host.faults.before_commit,
            });
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "message save", error.CanonicalStoreFailure);
            }
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            var response: protocol.ResponseBuffer = .{};
            try renderMessageReply(&response, command, result);
            const status: u16 = switch (result) {
                .accepted, .rejected => 200,
                .conflict => 409,
                .infrastructure_failure => 500,
            };
            deliverResponse(host.io, fd, status, response.slice());
        },
        .session_stop => |*command| {
            var timing = ControlTiming.init(host, command.key, "session_stop", accepted_at_ns);
            const result = host.store.stopSession(command, .{
                .before_commit = host.faults.before_commit,
                .control_trace = timing.storeTrace(),
            });
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "Session stop save", error.CanonicalStoreFailure);
            }
            if (result == .accepted) publishControlHint(host, command.key.slice());
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            var response: protocol.ResponseBuffer = .{};
            try renderSessionStopReply(&response, command, result);
            const status: u16 = switch (result) {
                .accepted, .rejected => 200,
                .conflict => 409,
                .infrastructure_failure => 500,
            };
            deliverResponse(host.io, fd, status, response.slice());
            fd.timing = timing;
        },
        .model_interruption => |*command| {
            var timing = ControlTiming.init(host, command.key, "model_interruption", accepted_at_ns);
            const result = host.store.interruptModel(command, .{
                .before_commit = host.faults.before_commit,
                .control_trace = timing.storeTrace(),
            });
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "model interruption save", error.CanonicalStoreFailure);
            }
            if (result == .accepted) publishControlHint(host, command.key.slice());
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            var response: protocol.ResponseBuffer = .{};
            try renderModelInterruptionReply(&response, command, result);
            const status: u16 = switch (result) {
                .accepted, .rejected => 200,
                .conflict => 409,
                .infrastructure_failure => 500,
            };
            deliverResponse(host.io, fd, status, response.slice());
            fd.timing = timing;
        },
        .permission_decision => |*command| {
            var timing = ControlTiming.init(host, command.key, "permission_decision", accepted_at_ns);
            const result = host.store.decidePermission(command, .{
                .before_commit = host.faults.before_commit,
                .control_trace = timing.storeTrace(),
            });
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "permission decision save", error.CanonicalStoreFailure);
            }
            if (result == .accepted) publishControlHint(host, command.key.slice());
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            var response: protocol.ResponseBuffer = .{};
            try renderPermissionDecisionReply(&response, command, result);
            const status: u16 = switch (result) {
                .accepted, .rejected => 200,
                .conflict => 409,
                .infrastructure_failure => 500,
            };
            deliverResponse(host.io, fd, status, response.slice());
            fd.timing = timing;
        },
        .observe_command => |command| {
            const observation = host.store.observeCommand(command.key.slice()) catch |err| {
                fenceDispatch(host, "command observation", err);
                return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
            };
            var response: protocol.ResponseBuffer = .{};
            try renderCommandObservation(&response, command.key.slice(), observation);
            deliverResponse(host.io, fd, 200, response.slice());
        },
        .read_result => |command| {
            const reference = host.store.commandResult(command.key.slice()) catch |err| switch (err) {
                error.ResultNotFound => return respondStatic(host.io, fd, 409, .result_unavailable, "result_not_found"),
                error.ResultNotReady => return respondStatic(host.io, fd, 409, .result_unavailable, "result_not_ready"),
                error.ResultFailed => return respondStatic(host.io, fd, 409, .result_unavailable, "result_failed"),
                else => {
                    fenceDispatch(host, "result observation", err);
                    return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            const reader = host.store.openContent(reference) catch |err| {
                fenceDispatch(host, "result content read", err);
                return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
            };
            try fd.setContent(reader, 0, true, false);
        },
        .read_action_arguments => |command| deliverActionContent(host, fd, command, false),
        .read_action_call_id => |command| deliverActionContent(host, fd, command, true),
        .inspect_session => |request_value| {
            if (request_value.failed_response != null) {
                const capture = host.store.captureFailedResponse(request_value, host.lease.store_dir, .{
                    .scratch_path = host.lease.paths.scratch.slice(),
                    .scratch_budget = host.retention.sharedBudget(),
                    .request_number = request_number,
                    .fail_unlink = host.faults.report_unlink,
                }) catch |err| {
                    if (err == error.ReportScratchCleanupFailed) {
                        fenceDispatch(host, "failed response export scratch cleanup", err);
                        return respondStatic(host.io, fd, 500, .observation_error, "report_scratch_cleanup_failed");
                    }
                    if (host.store.isFenced()) {
                        fenceDispatch(host, "failed response identity", err);
                        return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                    }
                    return respondStatic(host.io, fd, 409, .failed_response_unavailable, @errorName(err));
                };
                try fd.setReport(capture);
                try fd.prepareHeader(200, "application/octet-stream", capture.length);
                return;
            }
            const report = host.store.captureSessionReport(request_value.session.slice(), .{
                .scratch_path = host.lease.paths.scratch.slice(),
                .scratch_budget = host.retention.sharedBudget(),
                .request_number = request_number,
                .profile = request_value.profile,
                .fail_unlink = host.faults.report_unlink,
                .execution = executionFacts(host),
            }) catch |err| {
                if (err == error.ReportScratchCleanupFailed) {
                    fenceDispatch(host, "session report scratch cleanup", err);
                    return respondStatic(host.io, fd, 500, .observation_error, "report_scratch_cleanup_failed");
                }
                if (host.store.isFenced()) {
                    fenceDispatch(host, "session inspection", err);
                    return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                }
                return respondStatic(
                    host.io,
                    fd,
                    if (err == error.ReportScratchExhausted) 507 else 500,
                    .observation_error,
                    @errorName(err),
                );
            };
            try fd.setReport(report);
            traceSubject(host, "inspection_captured", "session", request_value.session.slice());
            traceSqliteDiagnostic(host, request_value.session.slice());
            try fd.holdDelivery(host.faults.inspection_reply_gate_path, host.faults.inspection_reply_delay_ms);
            if (fd.gate != null) traceSubject(host, "test_gate_waiting", "path", host.faults.inspection_reply_gate_path.?);
        },
        .list_sessions => |request_value| {
            const page = host.store.captureSessionList(request_value, .{
                .scratch_path = host.lease.paths.scratch.slice(),
                .scratch_budget = host.retention.sharedBudget(),
                .request_number = request_number,
                .fail_unlink = host.faults.report_unlink,
            }) catch |err| {
                if (err == error.ReportScratchCleanupFailed) {
                    fenceDispatch(host, "Session list scratch cleanup", err);
                    return respondStatic(host.io, fd, 500, .observation_error, "report_scratch_cleanup_failed");
                }
                if (host.store.isFenced()) {
                    fenceDispatch(host, "Session list", err);
                    return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                }
                return respondStatic(host.io, fd, if (err == error.ReportScratchExhausted) 507 else 500, .observation_error, @errorName(err));
            };
            try fd.setReport(page);
        },
        .conversation_page => |command| {
            const page = host.store.publicConversationPage(command) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(host.io, fd, 409, .conversation_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "conversation page", err);
                    return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            var response: protocol.FixedJsonBuffer(protocol.max_conversation_page_response_bytes) = .{};
            try renderConversationPage(&response, &page);
            deliverResponse(host.io, fd, 200, response.slice());
        },
        .conversation_content => |command| try prepareConversationContent(host, fd, command),
        .proposal_page => |command| {
            const page = host.store.proposalPage(command) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(host.io, fd, 409, .proposal_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "proposal page", err);
                    return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            var response: protocol.FixedJsonBuffer(protocol.max_proposal_page_response_bytes) = .{};
            try renderProposalPage(&response, &page);
            deliverResponse(host.io, fd, 200, response.slice());
        },
        .proposal_field => |command| {
            const reader = host.store.openProposalField(command) catch |err| switch (err) {
                error.ContentNotFound => return respondStatic(host.io, fd, 409, .proposal_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "proposal field", err);
                    return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            try deliverPublicContent(host, fd, reader, 0, true);
        },
        .activity_page => |command| {
            const page = host.store.activityPage(command) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(host.io, fd, 409, .activity_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "activity page", err);
                    return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            try prepareActivityPage(host.io, fd, &page);
        },
        .activity_content => |command| {
            const reader = host.store.openActivityContent(command) catch |err| switch (err) {
                error.ContentNotFound => return respondStatic(host.io, fd, 409, .activity_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "activity content", err);
                    return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            try deliverPublicContent(host, fd, reader, 0, true);
        },
    }
}

// The response buffer is needed only after Store/SQLite reads return. Do not
// keep it on the intake worker's bounded stack during recursive SQL planning.
fn prepareActivityPage(io: std.Io, reply: *Reply, page: *const protocol.ActivityFacts) !void {
    var buffer: [protocol.max_activity_page_response_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try page.writeJson(&out);
    deliverResponse(io, reply, 200, out.buffered());
}

fn deliverConversationContent(host: *Host, fd: std.posix.fd_t, command: protocol.ConversationContent) !void {
    var reply = Reply{ .io = host.io, .allocator = host.allocator };
    defer reply.deinit();
    try prepareConversationContent(host, &reply, command);
    reply.deliver(fd) catch |err| {
        if (host.store.isFenced()) fenceDispatch(host, "public content", err);
    };
}

fn prepareConversationContent(host: *Host, fd: *Reply, command: protocol.ConversationContent) !void {
    const reader = host.store.openPublicConversationContent(command) catch |err| switch (err) {
        error.ContentNotFound, error.RangeOutOfBounds => return respondStatic(host.io, fd, 409, .conversation_unavailable, @errorName(err)),
        else => {
            fenceDispatch(host, "conversation content", err);
            return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
        },
    };
    return deliverPublicContent(host, fd, reader, command.start, command.stream);
}

fn deliverPublicContent(host: *Host, fd: *Reply, reader: store_module.ContentReader, start: u64, stream: bool) !void {
    fd.setContent(reader, start, stream, true) catch |err| {
        fenceDispatch(host, "public content", err);
        fd.deinit();
        return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
    };
}

fn deliverActionContent(host: *Host, fd: *Reply, command: anytype, comptime call_id: bool) void {
    const phase = if (call_id) "Action call identity observation" else "Action argument observation";
    const reference = if (call_id)
        host.store.actionCallId(command.session.slice(), command.action_id)
    else
        host.store.actionArguments(command.session.slice(), command.action_id);
    const resolved = reference catch |err| switch (err) {
        error.ActionNotFound => return respondStatic(host.io, fd, 404, .action_unavailable, "action_not_found"),
        else => {
            fenceDispatch(host, phase, err);
            return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
        },
    };
    const reader = host.store.openContent(resolved) catch |err| {
        fenceDispatch(host, phase, err);
        return respondStatic(host.io, fd, 500, .invocation_error, "canonical_store_failure");
    };
    fd.setContent(reader, 0, true, false) catch {};
}

fn nextRequestNumber(host: *Host) !u64 {
    var current = host.request_counter.load(.acquire);
    while (true) {
        if (current == std.math.maxInt(u64)) return error.RequestIdentityExhausted;
        current = host.request_counter.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse
            return current;
    }
}

const HeaderReader = struct {
    fn parseRoute(request_line: []const u8) !Route {
        var request_parts = std.mem.splitScalar(u8, request_line, ' ');
        if (!std.mem.eql(u8, request_parts.next() orelse return error.InvalidRequestLine, "POST")) {
            return error.InvalidMethod;
        }
        const path = request_parts.next() orelse return error.InvalidRequestLine;
        if (!std.mem.eql(u8, request_parts.next() orelse return error.InvalidRequestLine, "HTTP/1.1") or
            request_parts.next() != null)
        {
            return error.InvalidRequestLine;
        }
        return if (std.mem.eql(u8, path, "/v1/host-info"))
            .host_info
        else if (std.mem.eql(u8, path, "/v1/control/host-stop"))
            .host_stop
        else if (std.mem.eql(u8, path, "/v1/configure"))
            .configure
        else if (std.mem.eql(u8, path, "/v1/message"))
            .message
        else if (std.mem.eql(u8, path, "/v1/control/session-stop"))
            .session_stop
        else if (std.mem.eql(u8, path, "/v1/control/model-interruption"))
            .model_interruption
        else if (std.mem.eql(u8, path, "/v1/control/permission-decision"))
            .permission_decision
        else if (std.mem.eql(u8, path, "/v1/observe-command"))
            .observe
        else if (std.mem.eql(u8, path, "/v1/read-result"))
            .read_result
        else if (std.mem.eql(u8, path, "/v1/read-action-call-id"))
            .read_action_call_id
        else if (std.mem.eql(u8, path, "/v1/read-action-arguments"))
            .read_action_arguments
        else if (std.mem.eql(u8, path, "/v1/inspect-session"))
            .inspect
        else if (std.mem.eql(u8, path, "/v1/list-sessions"))
            .list_sessions
        else if (std.mem.eql(u8, path, "/v1/conversation-page"))
            .conversation_page
        else if (std.mem.eql(u8, path, "/v1/conversation-content"))
            .conversation_content
        else if (std.mem.eql(u8, path, "/v1/proposal-page"))
            .proposal_page
        else if (std.mem.eql(u8, path, "/v1/proposal-field"))
            .proposal_field
        else if (std.mem.eql(u8, path, "/v1/activity-page"))
            .activity_page
        else if (std.mem.eql(u8, path, "/v1/activity-content"))
            .activity_content
        else if (std.mem.startsWith(u8, path, "/v1/control/"))
            .unsupported_control
        else
            error.UnknownRoute;
    }

    fn parseFields(bytes: []const u8, route: Route) !Header {
        var lines = std.mem.splitSequence(u8, bytes, "\r\n");
        _ = lines.next() orelse return error.InvalidRequestLine;
        var content_length: ?u64 = null;
        var wire_ok = false;
        var content_type_ok = false;
        var drop: DropMode = .none;
        var instance: ?protocol.InstanceId = null;
        while (lines.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                if (content_length != null) return error.DuplicateContentLength;
                content_length = try std.fmt.parseInt(u64, value, 10);
            } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
                content_type_ok = std.ascii.eqlIgnoreCase(value, "application/json");
            } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Wire-Version")) {
                wire_ok = std.mem.eql(u8, value, protocol.wire_version);
            } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Host-Instance")) {
                if (instance != null) return error.DuplicateHostInstance;
                instance = try protocol.parseInstanceId(value);
            } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Test-Drop-Reply")) {
                drop = if (std.mem.eql(u8, value, "before-admission"))
                    .before_admission
                else if (std.mem.eql(u8, value, "during-admission"))
                    .during_admission
                else if (std.mem.eql(u8, value, "after-commit"))
                    .after_commit
                else
                    return error.InvalidTestDropMode;
            } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                return error.TransferEncodingUnsupported;
            }
        }
        if (!wire_ok) return error.WrongWireVersion;
        if (!content_type_ok) return error.InvalidContentType;
        return .{
            .route = route,
            .content_length = content_length orelse return error.MissingContentLength,
            .drop = drop,
            .instance = instance,
        };
    }
};

fn renderConfigureReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.ConfigureCommand,
    result: store_module.ConfigureReply,
) !void {
    const shapes = protocol.configuration_reply;
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, value.session.slice(), value.revision, value.created }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, command.session.slice(), value.code }),
        .conflict => response.appendShape(shapes.conflict, .{command.session.slice()}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

test "canonical failure classifier accepts every production mutation failure envelope" {
    const client = @import("client.zig");
    inline for (.{ renderConfigureReply, renderMessageReply, renderSessionStopReply, renderModelInterruptionReply, renderPermissionDecisionReply }) |render| {
        var response = protocol.ResponseBuffer{};
        try render(&response, &.{}, .infrastructure_failure);
        try std.testing.expectEqualStrings("{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}", response.slice());
        try std.testing.expectError(error.CanonicalStoreFailure, client.checkCanonicalFailure(.{ .status = 500, .body = response.slice() }));
    }
}

// Test-only DOM edits let every witness start from an actual producer reply;
// production continues to parse once into bounded values, without a DOM.
fn expectMutationFieldPresence(body: []const u8, status: u16, session: []const u8, target: @import("client.zig").MutationTarget) !void {
    const client = @import("client.zig");
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const Section = struct { path: []const []const u8, fields: []const []const u8 };
    const sections = [_]Section{
        .{ .path = &.{}, .fields = &.{ "version", "type", "code", "answer", "input", "queue", "execution", "completion" } },
        .{ .path = &.{"answer"}, .fields = &.{ "status", "replayed", "session", "code", "revision", "created", "admission", "action", "decision", "selection", "target" } },
        .{ .path = &.{"input"}, .fields = &.{ "type", "bytes", "sha256" } },
        .{ .path = &.{"queue"}, .fields = &.{ "status", "admission" } },
        .{ .path = &.{"execution"}, .fields = &.{ "status", "reason" } },
        .{ .path = &.{"completion"}, .fields = &.{"status"} },
        .{ .path = &.{ "answer", "selection" }, .fields = &.{ "turn", "admission_cutoff" } },
        .{ .path = &.{ "answer", "target" }, .fields = &.{ "session", "turn", "operation" } },
    };
    for (sections) |section| {
        var object = &parsed.value;
        for (section.path) |part| object = object.object.getPtr(part) orelse break else {
            for (section.fields) |field| {
                const original = object.object.get(field);
                try object.object.put(parsed.arena.allocator(), field, .null);
                const encoded = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
                defer allocator.free(encoded);
                const decoded = client.decodeMutationReply(.{ .status = status, .body = encoded }, session, target);
                const nullable_turn = section.path.len == 2 and std.mem.eql(u8, section.path[1], "selection") and std.mem.eql(u8, field, "turn");
                if (nullable_turn) {
                    try std.testing.expectEqual(@as(?u64, null), (try decoded.answer).result.accepted.session_stop.turn);
                } else {
                    std.testing.expectError(error.InvalidResponse, decoded.answer) catch |err| {
                        std.debug.print("null witness: operation={s}, HTTP={d}, path={any}, field={s}\n", .{ @tagName(target), status, section.path, field });
                        return err;
                    };
                    try std.testing.expect(!decoded.isAccepted());
                    try std.testing.expect(decoded.diagnostic == null);
                    try std.testing.expectEqualStrings(session, decoded.context.session.slice());
                }
                // Every field emitted by these producers is required for its
                // particular outcome; nullable turn is required, not optional.
                _ = object.object.orderedRemove(field);
                if (original) |value| {
                    const omitted = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
                    defer allocator.free(omitted);
                    try std.testing.expectError(error.InvalidResponse, client.decodeMutationReply(.{ .status = status, .body = omitted }, session, target).answer);
                    try object.object.put(parsed.arena.allocator(), field, value);
                }
            }
        }
    }
}

test "mutation decoder validates all five actual producers and preserved domain answers" {
    const client = @import("client.zig");
    const session = "k7m2qx";
    const content: store_module.ContentReference = .{ .length = 9, .digest = protocol.contentDigest("seven\nµ!") };
    inline for (.{ renderConfigureReply, renderMessageReply, renderSessionStopReply, renderModelInterruptionReply, renderPermissionDecisionReply }, 0..) |render, index| {
        const Command = @typeInfo(@typeInfo(@TypeOf(render)).@"fn".param_types[1].?).pointer.child;
        const MutationReply = @typeInfo(@TypeOf(render)).@"fn".param_types[2].?;
        var command: Command = .{};
        try command.session.set(session);
        if (index == 3) {
            command.turn_id = 3;
            command.operation_id = 11;
        }
        if (index == 4) command.action_id = 7;
        const target: client.MutationTarget = switch (index) {
            0 => .configure,
            1 => .{ .message = .{ .bytes = content.length, .digest = content.digest } },
            2 => .session_stop,
            3 => .{ .model_interruption = .{ .turn = 3, .operation = 11 } },
            4 => .{ .permission_decision = .{ .action = 7, .decision = .deny } },
            else => unreachable,
        };
        const accepted: MutationReply = switch (index) {
            0 => .{ .accepted = .{ .replayed = true, .revision = 13, .created = false, .session = command.session } },
            1 => .{ .accepted = .{ .replayed = true, .admission_id = 17, .content = content, .session = command.session } },
            2 => .{ .accepted = .{ .replayed = true, .selection = .{ .selected_turn_id = 19, .admission_cutoff = 23 }, .completion = .pending } },
            3, 4 => .{ .accepted = .{ .replayed = true } },
            else => unreachable,
        };
        const rejected: MutationReply = if (index == 1)
            .{ .rejected = .{ .replayed = true, .code = .unknown_session, .content = content } }
        else
            .{ .rejected = .{ .replayed = true, .code = .invalid_session_reference } };
        for ([_]MutationReply{ accepted, rejected, .conflict, .infrastructure_failure }) |initial| {
            for ([_]bool{ false, true }) |replayed| {
                var result = initial;
                switch (result) {
                    .accepted => |*value| value.replayed = replayed,
                    .rejected => |*value| value.replayed = replayed,
                    else => {},
                }
                var response: protocol.ResponseBuffer = .{};
                try render(&response, &command, result);
                const status: u16 = if (result == .conflict) 409 else if (result == .infrastructure_failure) 500 else 200;
                const decoded = client.decodeMutationReply(.{ .status = status, .body = response.slice() }, session, target);
                try std.testing.expectEqual(status, decoded.status);
                try expectMutationFieldPresence(response.slice(), status, session, target);
                if (result == .infrastructure_failure) {
                    try std.testing.expectError(error.CanonicalStoreFailure, decoded.answer);
                    continue;
                }
                const answer = try decoded.answer;
                try std.testing.expectEqualStrings(@tagName(result), @tagName(answer.result));
                try std.testing.expectEqual(result != .conflict and replayed, answer.replayed);
                try std.testing.expectError(error.RequestBindingMismatch, client.decodeMutationReply(.{ .status = status, .body = response.slice() }, "p9q8rs", target).answer);
                if (result == .accepted) switch (answer.result.accepted) {
                    .configure => |value| try std.testing.expectEqual(@as(u64, 13), value.revision),
                    .message => |value| try std.testing.expectEqual(@as(u64, 17), value.admission),
                    .session_stop => |value| {
                        try std.testing.expectEqual(@as(?u64, 19), value.turn);
                        try std.testing.expectEqual(@as(u64, 23), value.admission_cutoff);
                        try std.testing.expectEqual(.pending, value.completion);
                    },
                    .model_interruption, .permission_decision => {},
                };
            }
        }
        if (index == 2) {
            var idle = accepted;
            idle.accepted.selection.selected_turn_id = null;
            idle.accepted.completion = .completed;
            var response: protocol.ResponseBuffer = .{};
            try render(&response, &command, idle);
            const answer = try client.decodeMutationReply(.{ .status = 200, .body = response.slice() }, session, target).answer;
            try std.testing.expectEqual(@as(?u64, null), answer.result.accepted.session_stop.turn);
            try std.testing.expectEqual(.completed, answer.result.accepted.session_stop.completion);
            try expectMutationFieldPresence(response.slice(), 200, session, target);
        }
    }
}

fn renderMessageReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.MessageCommand,
    result: store_module.MessageReply,
) !void {
    const shapes = protocol.message_reply;
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, value.session.slice(), value.admission_id, value.content.length, value.content.digest, value.admission_id }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, command.session.slice(), value.code, value.content.length, value.content.digest }),
        .conflict => response.appendShape(shapes.conflict, .{command.session.slice()}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

test "initial Message reply binds its allocated Session and original input before exposing acceptance" {
    const client = @import("client.zig");
    const content: store_module.ContentReference = .{ .length = 9, .digest = protocol.contentDigest("seven\nµ!") };
    var allocated: protocol.Bounded(protocol.max_session_bytes) = .{};
    try allocated.set("k7m2qx");
    var response: protocol.ResponseBuffer = .{};
    try renderMessageReply(&response, &.{ .configuration = .{} }, .{ .accepted = .{
        .replayed = true,
        .admission_id = 17,
        .content = content,
        .session = allocated,
    } });
    const target: client.MutationTarget = .{ .message = .{ .bytes = content.length, .digest = content.digest, .creates_session = true } };
    const reply = client.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", target);
    try std.testing.expect(reply.isAccepted());
    try std.testing.expectEqualStrings("k7m2qx", reply.context.session.slice());
    try expectMutationFieldPresence(response.slice(), 200, "", target);
    // Ordinary addressed sends cannot adopt a different Session from a reply.
    try std.testing.expectError(error.RequestBindingMismatch, client.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "111111", target).answer);
    var changed = target;
    changed.message.digest[0] ^= 1;
    try std.testing.expectError(error.RequestBindingMismatch, client.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", changed).answer);
    response = .{};
    try allocated.set("BAD-ID");
    try renderMessageReply(&response, &.{ .configuration = .{} }, .{ .accepted = .{
        .replayed = true,
        .admission_id = 17,
        .content = content,
        .session = allocated,
    } });
    try std.testing.expectError(error.RequestBindingMismatch, client.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", target).answer);
}

fn renderConversationPage(response: *protocol.FixedJsonBuffer(protocol.max_conversation_page_response_bytes), page: *const store_module.PublicConversationPage) !void {
    const shapes = protocol.conversation_page_reply;
    try response.appendShape(shapes.head, .{page.end});
    for (page.items[0..page.count], 0..) |item, index| {
        if (index != 0) try response.append(",");
        switch (item.kind) {
            inline else => |kind| try response.appendShape(shapes.item(kind), .{ item.position, item.ordinal, item.content.length, item.content.digest }),
        }
        switch (item.kind) {
            .user => if (item.admitted_at) |second| try response.appendShape(shapes.admission, .{ second, item.sender }),
            .tool_result => if (item.presentation) |presentation| try response.appendShape(shapes.presentation, .{presentation}),
            .assistant => {},
        }
        try response.appendShape(shapes.item_end, .{});
    }
    if (page.more) {
        const last = page.items[page.count - 1];
        try response.appendShape(shapes.more, .{ last.position, last.ordinal });
    } else try response.appendShape(shapes.last, .{});
}

fn renderProposalPage(response: *protocol.FixedJsonBuffer(protocol.max_proposal_page_response_bytes), page: *const store_module.ProposalPage) !void {
    const shapes = protocol.proposal_page_reply;
    try response.appendShape(shapes.head, .{page.end});
    for (page.items[0..page.count], 0..) |item, index| {
        if (index != 0) try response.append(",");
        try response.appendShape(shapes.item_head, .{ item.position, item.operation, item.turn, item.call_ordinal, item.action, item.rejection });
        inline for (comptime std.meta.fieldNames(protocol.ProposalField), 0..) |name, field_index| {
            const reference = item.fields[field_index];
            try response.appendShape(shapes.field(@field(protocol.ProposalField, name)), .{ reference.length, reference.digest });
        }
        try response.appendShape(shapes.item_end, .{});
    }
    try response.appendShape(shapes.tail, .{page.more});
}

fn renderSessionStopReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.SessionStopCommand,
    result: store_module.SessionStopReply,
) !void {
    const shapes = protocol.session_stop_reply;
    const session = command.session.slice();
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, session, value.selection.selected_turn_id, value.selection.admission_cutoff, value.completion }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, session, value.code }),
        .conflict => response.appendShape(shapes.conflict, .{session}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

fn renderModelInterruptionReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.ModelInterruptionCommand,
    result: store_module.ModelInterruptionReply,
) !void {
    const shapes = protocol.model_interruption_reply;
    const session = command.session.slice();
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, session, command.turn_id, command.operation_id }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, session, command.turn_id, command.operation_id, value.code }),
        .conflict => response.appendShape(shapes.conflict, .{ session, command.turn_id, command.operation_id }),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

fn renderPermissionDecisionReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.PermissionDecisionCommand,
    result: store_module.PermissionDecisionReply,
) !void {
    const shapes = protocol.permission_decision_reply;
    const session = command.session.slice();
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, session, command.action_id, command.decision }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, session, command.action_id, command.decision, value.code }),
        .conflict => response.appendShape(shapes.conflict, .{ session, command.action_id, command.decision }),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

fn renderCommandObservation(
    response: *protocol.ResponseBuffer,
    key: []const u8,
    observation: store_module.CommandObservation,
) !void {
    const shapes = protocol.command_observation_reply;
    if (observation.status == .absent) return response.appendShape(shapes.absent, .{key});
    switch (observation.kind) {
        inline else => |kind| try response.appendShape(shapes.head(kind), .{ key, observation.status, observation.target.slice() }),
    }
    if (observation.code.len != 0) try response.appendShape(shapes.code, .{observation.code.slice()});
    switch (observation.kind) {
        .configure => if (observation.status == .accepted) try response.appendShape(shapes.revision, .{ observation.revision, observation.created }),
        .message => if (observation.message) |message| {
            try response.appendShape(shapes.input, .{ message.content.length, message.content.digest });
            if (message.queue) |accepted| {
                const admission = accepted.admission_id;
                try switch (accepted.state) {
                    .queued => response.appendShape(shapes.queued, .{admission}),
                    .excluded => |excluded| response.appendShape(shapes.excluded, .{ admission, excluded.code.slice() }),
                    .processing => |binding| response.appendShape(shapes.processing, .{ admission, binding.turn_id, binding.operation_id, binding.attempt_ordinal }),
                    .completed => |completed| response.appendShape(shapes.completed, .{
                        admission,                         completed.binding.turn_id, completed.binding.operation_id,
                        completed.binding.attempt_ordinal, completed.answer.length,   completed.answer.digest,
                    }),
                    .cancelled => |cancelled| response.appendShape(shapes.cancelled, .{ admission, cancelled.binding.turn_id, cancelled.binding.operation_id, cancelled.binding.attempt_ordinal, cancelled.code.slice() }),
                    .failed => |failed| response.appendShape(shapes.failed, .{ admission, failed.binding.turn_id, failed.binding.operation_id, failed.binding.attempt_ordinal, failed.code.slice() }),
                };
                if (message.progress) |progress| try response.appendShape(shapes.progress, .{ progress.status, progress.action_id });
            }
        },
        .session_stop => if (observation.session_stop) |stop| try response.appendShape(shapes.session_stop, .{ stop.selection.selected_turn_id, stop.selection.admission_cutoff, stop.completion }),
        .model_interruption => if (observation.model_interruption) |target| try response.appendShape(shapes.model_interruption, .{ target.session.slice(), target.turn_id, target.operation_id }),
        .permission_decision => if (observation.permission_action_id) |action_id| try response.appendShape(shapes.permission_decision, .{
            action_id,
            observation.permission_decision orelse return error.InvalidCommandObservation,
        }),
    }
    try response.appendShape(shapes.tail, .{});
}

fn renderHostInfo(
    response: *protocol.ResponseBuffer,
    store: []const u8,
    instance: protocol.InstanceId,
    active_capacity: u64,
    intake_capacity: u64,
    descriptor_soft_limit: ?u64,
    model: bool,
    managed_authentication: bool,
) !void {
    var digits: [protocol.Hole.maxBytes(.decimal)]u8 = undefined;
    const limit_text = if (descriptor_soft_limit) |limit| std.fmt.bufPrint(&digits, "{d}", .{limit}) catch unreachable else "unlimited";
    try response.appendShape(protocol.host_info_reply, .{ store, instance, active_capacity, intake_capacity, limit_text, model, managed_authentication });
    std.debug.assert(response.len <= protocol.max_host_info_response_bytes);
}

fn renderStatic(response: *protocol.ResponseBuffer, kind: protocol.ErrorType, code: []const u8) !void {
    try response.appendShape(protocol.error_reply, .{ kind, code });
}

fn respondStatic(io: std.Io, reply: *Reply, status: u16, kind: protocol.ErrorType, code: []const u8) void {
    var response: protocol.ResponseBuffer = .{};
    renderStatic(&response, kind, code) catch return;
    deliverResponse(io, reply, status, response.slice());
}

fn deliverResponse(_: std.Io, reply: *Reply, status: u16, body: []const u8) void {
    // Allocation failure cannot revoke an already saved semantic answer.
    reply.setJson(status, body) catch {};
}

// A reply retains its reader, not a handler stack or a complete content copy.
// The exchange owner calls advance only when the socket is writable and keeps
// this value alive through physical socket retirement, even after the last byte.
const Reply = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    header: [320]u8 = undefined,
    header_length: usize = 0,
    header_sent: usize = 0,
    window: [protocol.content_window_bytes]u8 = undefined,
    window_length: usize = 0,
    window_sent: usize = 0,
    offset: u64 = 0,
    end: u64 = 0,
    body: union(enum) {
        none,
        json: []u8,
        report: store_module.SessionReport,
        content: struct { reader: store_module.ContentReader, public: bool },
    } = .none,
    absolute_deadline: ?i128 = null,
    inactivity_deadline: i128 = 0,
    timing: ?ControlTiming = null,
    gate: ?std.posix.fd_t = null,
    not_before_ns: i128 = 0,

    fn deinit(self: *Reply) void {
        if (self.gate) |gate| _ = std.c.close(gate);
        switch (self.body) {
            .none => {},
            .json => |bytes| self.allocator.free(bytes),
            .report => |*report| report.deinit(),
            .content => |*content| content.reader.close(),
        }
        self.* = .{ .io = self.io, .allocator = self.allocator, .absolute_deadline = self.absolute_deadline };
    }

    fn holdDelivery(self: *Reply, path: ?[]const u8, delay_ms: i64) !void {
        self.not_before_ns = std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds + @as(i128, delay_ms) * std.time.ns_per_ms;
        if (path) |value| {
            self.gate = std.posix.openat(std.posix.AT.FDCWD, value, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |err| switch (err) {
                error.FileNotFound => return, // The fixture already released it.
                else => return err,
            };
        }
    }

    fn deliveryReady(self: *Reply) !bool {
        if (std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds < self.not_before_ns) return false;
        if (self.gate) |gate| {
            var byte: [1]u8 = undefined;
            const count = std.c.read(gate, &byte, 1);
            if (count < 0) switch (std.posix.errno(count)) {
                .AGAIN, .INTR => return false,
                else => return error.DeliveryGateReadFailed,
            };
            // ReleaseGate publishes persistent EOF for all existing readers.
            _ = std.c.close(gate);
            self.gate = null;
        }
        return true;
    }

    fn prepareHeader(self: *Reply, status: u16, content_type: []const u8, length: u64) !void {
        const header = try std.fmt.bufPrint(&self.header, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{ status, httpReason(status), content_type, length });
        self.header_length = header.len;
        self.renew();
    }

    fn setJson(self: *Reply, status: u16, bytes: []const u8) !void {
        std.debug.assert(self.body == .none);
        self.body = .{ .json = try self.allocator.dupe(u8, bytes) };
        self.end = bytes.len;
        try self.prepareHeader(status, "application/json", bytes.len);
    }

    /// Moves a report, including its scratch charge, into delivery custody.
    fn setReport(self: *Reply, value: store_module.SessionReport) !void {
        std.debug.assert(self.body == .none);
        self.body = .{ .report = value };
        self.end = value.length;
        try self.prepareHeader(200, "application/json", value.length);
    }

    /// Moves one canonical reader; public reads verify their first window and
    /// empty/one-window EOF before any successful header can leave the Host.
    fn setContent(self: *Reply, reader: store_module.ContentReader, start: u64, stream: bool, public: bool) !void {
        std.debug.assert(self.body == .none);
        self.body = .{ .content = .{ .reader = reader, .public = public } };
        self.offset = start;
        const length = if (stream) reader.reference.length - start else @min(reader.reference.length - start, protocol.content_window_bytes);
        self.end = start + length;
        if (public) {
            try self.fill();
            const header = try std.fmt.bufPrint(&self.header, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{ length, reader.reference.length, self.end });
            self.header_length = header.len;
            self.renew();
        } else try self.prepareHeader(200, "text/plain; charset=utf-8", length);
    }

    fn fill(self: *Reply) !void {
        const wanted: usize = @intCast(@min(self.end - self.offset, self.window.len));
        const count = switch (self.body) {
            .content => |*value| if (value.public)
                try value.reader.readRange(self.offset, self.window[0..@max(wanted, 1)])
            else
                try value.reader.read(self.offset, self.window[0..wanted]),
            .report => |*value| try value.read(self.offset, self.window[0..wanted]),
            .none, .json => unreachable,
        };
        if (count != wanted) return error.ShortCanonicalRead;
        self.window_length = count;
        self.window_sent = 0;
        // Local production is not socket inactivity. Discovery, in contrast,
        // retains its original absolute budget regardless of local progress.
        self.renew();
    }

    fn renew(self: *Reply) void {
        self.inactivity_deadline = std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds + 60 * std.time.ns_per_s;
    }

    fn deadline(self: *const Reply) i128 {
        return self.absolute_deadline orelse self.inactivity_deadline;
    }

    fn needsFill(self: *const Reply) bool {
        return self.header_sent == self.header_length and self.offset != self.end and
            self.body != .json and self.window_sent == self.window_length;
    }

    /// One nonblocking write, or one bounded production window, per turn.
    /// false means more delivery remains; readiness alone never renews time.
    fn advance(self: *Reply, fd: std.posix.fd_t) !bool {
        if (std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds >= self.deadline())
            return if (self.absolute_deadline != null) error.ExchangeDeadlineExceeded else error.TransferInactive;
        if (self.header_sent < self.header_length) {
            self.header_sent += try self.write(fd, self.header[self.header_sent..self.header_length]);
            return false;
        }
        if (self.offset == self.end) return true;
        if (self.body == .json) {
            const start: usize = @intCast(self.offset);
            const end = @min(self.body.json.len, start + protocol.content_window_bytes);
            self.offset += try self.write(fd, self.body.json[start..end]);
        } else {
            if (self.window_sent == self.window_length) {
                try self.fill();
                return false;
            }
            const count = try self.write(fd, self.window[self.window_sent..self.window_length]);
            self.window_sent += count;
            self.offset += count;
        }
        return self.offset == self.end;
    }

    fn write(self: *Reply, fd: std.posix.fd_t, bytes: []const u8) !usize {
        const count = std.c.write(fd, bytes.ptr, bytes.len);
        if (count < 0) switch (std.posix.errno(count)) {
            .AGAIN, .INTR => return 0,
            else => return error.WriteFailed,
        };
        if (count == 0) return error.ConnectionClosed;
        self.renew();
        return @intCast(count);
    }

    fn deliver(self: *Reply, fd: std.posix.fd_t) !void {
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking) < 0) return error.WriteFailed;
        self.renew();
        while (true) {
            protocol.pollExchange(self.io, fd, std.posix.POLL.OUT, self.deadline()) catch |err|
                return if (err == error.ExchangeDeadlineExceeded and self.absolute_deadline == null) error.TransferInactive else err;
            if (try self.advance(fd)) {
                if (self.timing) |*timing| timing.replyComplete();
                return;
            }
        }
    }
};

fn httpReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        409 => "Conflict",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        507 => "Insufficient Storage",
        else => "Error",
    };
}

fn writeHttpUntil(io: std.Io, fd: std.posix.fd_t, status: u16, body: []const u8, deadline: ?i128) !void {
    var reply = Reply{ .io = io, .allocator = std.testing.allocator, .absolute_deadline = deadline };
    defer reply.deinit();
    try reply.setJson(status, body);
    try reply.deliver(fd);
}

fn writeAll(io: std.Io, fd: std.posix.fd_t, bytes: []const u8) !void {
    var reply = Reply{ .io = io, .allocator = std.testing.allocator };
    defer reply.deinit();
    reply.body = .{ .json = try std.testing.allocator.dupe(u8, bytes) };
    reply.end = bytes.len;
    try reply.deliver(fd);
}

test "Conversation stream native delivery decodes once and closes on failed handoff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root});
    var storage = try store_module.Store.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    const expected = @as([8189]u8, @splat('x')) ++ @as([257 * "é中🙂\n\\\"/".len]u8, @bitCast(@as([257]["é中🙂\n\\\"/".len]u8, @splat("é中🙂\n\\\"/".*)))) ++ "tail";
    var command = try store_module.testingPublicProjection(&storage, &tmp, &.{
        .{ .encoded = &@as([8189]u8, @splat('x')), .decoded = &@as([8189]u8, @splat('x')) },
        .{ .encoded = @as([257 * "\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".len]u8, @bitCast(@as([257]["\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".len]u8, @splat("\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".*)))) ++ "tail", .decoded = @as([257 * "é中🙂\n\\\"/".len]u8, @bitCast(@as([257]["é中🙂\n\\\"/".len]u8, @splat("é中🙂\n\\\"/".*)))) ++ "tail" },
    });
    command.stream = true;
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage, .faults = .{} };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const Peer = struct {
        fd: std.posix.fd_t,
        received: [expected.len + 320]u8 = undefined,
        used: usize = 0,
        failed: bool = false,

        fn drain(self: *@This()) void {
            while (self.used < self.received.len) {
                const count = std.c.read(self.fd, self.received[self.used..].ptr, self.received.len - self.used);
                if (count < 0) {
                    if (std.posix.errno(count) == .INTR) continue;
                    self.failed = true;
                    return;
                }
                if (count == 0) return;
                self.used += @intCast(count);
            }
            self.failed = true; // A full buffer is not evidence of EOF.
        }
    };
    var peer = Peer{ .fd = sockets[1] };
    storage.testing_content_work = .{};
    {
        // Drain during delivery: the response exceeds Darwin's socket queue.
        // The parent owns both FDs and keeps peer storage alive until join,
        // including when delivery fails before the assertions below.
        const thread = try std.Thread.spawn(.{}, Peer.drain, .{&peer});
        defer {
            _ = socket_os.shutdown(sockets[0], std.c.SHUT.WR);
            thread.join();
        }
        try deliverConversationContent(&host, sockets[0], command);
    }
    try std.testing.expectEqual(@as(u64, expected.len), storage.testing_content_work.decoded.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), storage.testing_content_work.closes.load(.monotonic));
    try std.testing.expect(!storage.isFenced());
    try std.testing.expect(!peer.failed);
    const body_start = (std.mem.indexOf(u8, peer.received[0..peer.used], "\r\n\r\n") orelse return error.MissingHeaders) + 4;
    try std.testing.expectEqualStrings(expected, peer.received[body_start..peer.used]);
    // Failed delivery is not canonical corruption; the one reader still closes
    // without traversing the rest of the content or keeping caller storage.
    storage.testing_content_work = .{};
    try deliverConversationContent(&host, -1, command);
    try std.testing.expectEqual(@as(u64, protocol.content_window_bytes), storage.testing_content_work.decoded.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), storage.testing_content_work.closes.load(.monotonic));
    try std.testing.expect(!storage.isFenced());
}

test "reply delivery establishes nonblocking only when sending" {
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[0], std.c.F.GETFL) & nonblocking);
    try writeAll(std.testing.io, sockets[0], "a\xc3\xa9\x00z");
    var actual: [5]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 5), std.c.read(sockets[1], &actual, actual.len));
    try std.testing.expectEqualSlices(u8, "a\xc3\xa9\x00z", &actual);
    try std.testing.expectEqual(nonblocking, std.c.fcntl(sockets[0], std.c.F.GETFL) & nonblocking);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[1], std.c.F.GETFL) & nonblocking);
}

test "discovery identity exhaustion cannot start a new error delivery budget" {
    const Clock = struct {
        var fd: std.posix.fd_t = undefined;
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            var descriptors = [_]std.c.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const available = std.c.poll(&descriptors, descriptors.len, 0);
            std.debug.assert(available >= 0);
            // Reading the last header byte consumes the original budget.
            return .fromNanoseconds(if (available > 0) 0 else 10 * std.time.ns_per_s);
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[1]);
    const header = "POST /v1/host-info HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: 0\r\n\r\n";
    try writeAll(std.testing.io, sockets[1], header);
    Clock.fd = sockets[0];
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .faults = .{} };
    host.request_counter.store(std.math.maxInt(u64), .release);
    const exchange = try host.allocator.create(Intake.Exchange);
    exchange.* = .{ .owner = undefined, .host = &host, .fd = sockets[0], .accepted_at_ns = 0, .deadline = 10 * std.time.ns_per_s };
    defer std.debug.assert(exchange.destroy());
    try std.testing.expectError(error.RequestIdentityExhausted, exchange.read());
    exchange.fail(error.RequestIdentityExhausted);
    try std.testing.expectError(error.ExchangeDeadlineExceeded, exchange.reply.?.advance(sockets[0]));
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[1], std.c.F.SETFL, nonblocking));
    var response: [512]u8 = undefined;
    try std.testing.expectEqual(@as(isize, -1), std.c.read(sockets[1], &response, response.len));
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(@as(isize, -1)));
}

test "discovery reply delivery shares its absolute budget across header and partial body writes" {
    const Peer = struct {
        fd: std.posix.fd_t,
        actual: [65536 + 256]u8 = undefined,
        used: usize = 0,
        writes: usize = 0,
        at: i96 = 0,

        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const before = self.used;
            while (self.used < self.actual.len) {
                const count = std.c.read(self.fd, self.actual[self.used..].ptr, self.actual.len - self.used);
                if (count < 0) {
                    std.debug.assert(std.posix.errno(count) == .AGAIN);
                    break;
                }
                std.debug.assert(count > 0);
                self.used += @intCast(count);
            }
            if (self.used != before) {
                self.writes += 1;
                self.at += 3 * std.time.ns_per_s;
            }
            return .fromNanoseconds(self.at);
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const capacity: c_int = 1024;
    try std.posix.setsockopt(sockets[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&capacity));
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[1], std.c.F.SETFL, nonblocking));
    var peer: Peer = .{ .fd = sockets[1] };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Peer.now;
    const io: std.Io = .{ .userdata = &peer, .vtable = &vtable };
    var body: [65536]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast((index * 19 + 37) % 251);
    try std.testing.expectError(error.ExchangeDeadlineExceeded, writeHttpUntil(io, sockets[0], 200, &body, 10 * std.time.ns_per_s));
    const boundary = std.mem.indexOf(u8, peer.actual[0..peer.used], "\r\n\r\n").? + 4;
    try std.testing.expect(peer.writes >= 4 and peer.at >= 10 * std.time.ns_per_s);
    try std.testing.expect(peer.used > boundary and peer.used - boundary < body.len);
    try std.testing.expectEqualSlices(u8, body[0 .. peer.used - boundary], peer.actual[boundary..peer.used]);
}

test "reply delivery renews on short writes and excludes production between windows" {
    const Peer = struct {
        fd: std.posix.fd_t,
        actual: [65536]u8 = undefined,
        used: usize = 0,
        writes: usize = 0,
        at: i96 = 0,

        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const before = self.used;
            while (self.used < self.actual.len) {
                const count = std.c.read(self.fd, self.actual[self.used..].ptr, self.actual.len - self.used);
                if (count < 0) {
                    std.debug.assert(std.posix.errno(count) == .AGAIN);
                    break;
                }
                std.debug.assert(count > 0);
                self.used += @intCast(count);
            }
            if (self.used != before) {
                self.writes += 1;
                self.at += 30 * std.time.ns_per_s;
            }
            return .fromNanoseconds(self.at);
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    var capacity: c_int = 1024;
    try std.posix.setsockopt(sockets[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&capacity));
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[1], std.c.F.SETFL, nonblocking));
    var peer: Peer = .{ .fd = sockets[1] };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Peer.now;
    const io: std.Io = .{ .userdata = &peer, .vtable = &vtable };
    var expected: [65536]u8 = undefined;
    for (&expected, 0..) |*byte, index| byte.* = @intCast((index * 17 + 29) % 251);
    try writeAll(io, sockets[0], &expected);
    try std.testing.expectEqualSlices(u8, &expected, peer.actual[0..peer.used]);
    try std.testing.expect(peer.writes >= 3);
    try std.testing.expect(peer.at > 60 * std.time.ns_per_s);
    // A producer can take longer than the socket inactivity interval before
    // offering its next window; the next write still gets a fresh budget.
    peer.used = 0;
    peer.at += 120 * std.time.ns_per_s;
    try writeAll(io, sockets[0], "next\x00window");
    try std.testing.expectEqualSlices(u8, "next\x00window", peer.actual[0..peer.used]);
}

test "reply delivery retries actual AGAIN without renewing inactivity" {
    const Race = struct {
        fd: std.posix.fd_t,
        calls: usize = 0,
        filled: usize = 0,

        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (self.calls == 3) {
                // Invalidate the successful poll: another writer fills this
                // socket before the production write. It must return AGAIN.
                const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
                std.debug.assert(std.c.fcntl(self.fd, std.c.F.GETFL) & nonblocking != 0);
                const bytes = @as([1024]u8, @splat(0x69));
                while (true) {
                    const count = std.c.write(self.fd, &bytes, bytes.len);
                    if (count < 0) {
                        std.debug.assert(std.posix.errno(count) == .AGAIN);
                        break;
                    }
                    std.debug.assert(count > 0);
                    self.filled += @intCast(count);
                }
            }
            return .fromNanoseconds(if (self.calls > 3) @as(i96, @intCast(self.calls - 3)) * 60 * std.time.ns_per_s else 0);
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    var race: Race = .{ .fd = sockets[0] };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Race.now;
    const io: std.Io = .{ .userdata = &race, .vtable = &vtable };
    try std.testing.expectError(error.TransferInactive, writeAll(io, sockets[0], "not delivered"));
    try std.testing.expect(race.filled > 0);
    try std.testing.expectEqual(@as(usize, 4), race.calls);
}

test "reply delivery interrupted poll consumes the existing inactivity budget" {
    const Interrupt = struct {
        var hits: std.atomic.Value(u32) = .init(0);
        target: std.c.pthread_t,
        fd: std.posix.fd_t,
        stop: std.atomic.Value(bool) = .init(false),

        fn signal(_: std.posix.SIG) callconv(.c) void {
            _ = hits.fetchAdd(1, .monotonic);
        }

        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .fromNanoseconds(@as(i96, hits.load(.monotonic)) * 20 * std.time.ns_per_s);
        }

        fn run(self: *@This()) void {
            const io = std.Io.Threaded.global_single_threaded.io();
            const limit = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 3 * std.time.ns_per_s;
            while (!self.stop.load(.acquire)) {
                std.Io.sleep(io, .fromMilliseconds(5), .awake) catch unreachable;
                if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= limit) {
                    // Bound even a mutant that keeps retrying poll with the
                    // original timeout. This is test cleanup, not Host policy.
                    _ = socket_os.shutdown(self.fd, std.c.SHUT.RDWR);
                    return;
                }
                _ = std.c.pthread_kill(self.target, .USR1);
            }
        }
    };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(sockets[0], std.c.F.SETFL, nonblocking));
    const bytes = @as([1024]u8, @splat(0x53));
    while (std.c.write(sockets[0], &bytes, bytes.len) >= 0) {}
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(@as(isize, -1)));
    var old_action: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = Interrupt.signal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.USR1, &action, &old_action);
    defer std.posix.sigaction(.USR1, &old_action, null);
    Interrupt.hits.store(0, .monotonic);
    var interrupt: Interrupt = .{ .target = std.c.pthread_self(), .fd = sockets[0] };
    const thread = try std.Thread.spawn(.{}, Interrupt.run, .{&interrupt});
    defer {
        interrupt.stop.store(true, .release);
        thread.join();
    }
    var vtable = std.testing.io.vtable.*;
    vtable.now = Interrupt.now;
    const io: std.Io = .{ .userdata = null, .vtable = &vtable };
    try std.testing.expectError(error.TransferInactive, writeAll(io, sockets[0], "not delivered"));
    try std.testing.expect(Interrupt.hits.load(.monotonic) >= 3);
}

test "delayed control replies retain command identity after request storage reuse" {
    const native = @import("posix");
    inline for (.{ "session_stop", "model_interruption", "permission_decision" }) |kind| {
        var descriptors: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), native.pipe(&descriptors));
        defer _ = native.close(descriptors[0]);
        for (descriptors) |fd| {
            try std.testing.expectEqual(@as(c_int, 0), native.fcntl(fd, native.F_SETFL, @as(c_int, native.O_NONBLOCK)));
        }
        const backing = native.tmpfile() orelse return error.TestUnexpectedResult;
        defer _ = native.fclose(backing);
        try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(native.fileno(backing), TestObservation.state_bytes));
        var observation = try TestObservation.init(descriptors[1], native.dup(native.fileno(backing)), .control, 37);
        defer observation.close();
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{ .test_phase_trace = true },
            .test_observation = &observation,
        };
        var original: [protocol.max_key_bytes]u8 = undefined;
        for (&original, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
        var request_key = protocol.Bounded(protocol.max_key_bytes){ .bytes = original, .len = original.len };
        var reply = Reply{ .io = std.testing.io, .allocator = std.testing.allocator };
        defer reply.deinit();
        reply.timing = ControlTiming.init(&host, request_key, kind, 1);
        reply.timing.?.store_queued_ns = 2;
        reply.timing.?.lock_acquired_ns = 3;
        reply.timing.?.store_complete_ns = 4;
        // The request is retired before the reply's physical delivery.
        @memset(&request_key.bytes, 'X');
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
        defer _ = std.c.close(sockets[0]);
        defer _ = std.c.close(sockets[1]);
        try reply.setJson(200, "{\"accepted\":true}");
        try reply.deliver(sockets[0]);
        var bytes: [TestObservation.record_bytes]u8 = undefined;
        const length = native.read(descriptors[0], &bytes, bytes.len);
        try std.testing.expect(length >= 28);
        const frame = bytes[0..@intCast(length)];
        try std.testing.expect(std.mem.indexOf(u8, frame, "control_timing") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, &original) != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, kind) != null);
        try std.testing.expectEqual(@as(u64, 2), observation.shared.state.load(.acquire));
    }
}

test "message observation renders every closed queue state without fabricated rejection state" {
    const zero_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const full_digest = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const input = ",\"input\":{\"type\":\"text\",\"bytes\":\"3\",\"sha256\":\"" ++ zero_digest ++ "\"}";
    const accepted_prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"s\"" ++ input;
    const binding = ",\"processing\":{\"turn\":\"2\",\"operation\":\"3\",\"attempt\":\"4\"}";
    const Expect = struct {
        fn rendered(observation: store_module.CommandObservation, expected: []const u8) !void {
            var response: protocol.ResponseBuffer = .{};
            try renderCommandObservation(&response, "k", observation);
            try std.testing.expectEqualStrings(expected, response.slice());
        }
    };

    const content = store_module.ContentReference{ .length = 3, .digest = @splat(0) };
    const processing = store_module.AttemptBinding{
        .turn_id = 2,
        .operation_id = 3,
        .attempt_ordinal = 4,
    };
    var rejected = store_module.CommandObservation{
        .status = .rejected,
        .kind = .message,
        .message = .{ .content = content },
    };
    try rejected.target.set("s");
    try rejected.code.set("unknown_session");
    try Expect.rendered(
        rejected,
        "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"s\",\"code\":\"unknown_session\"" ++ input ++ "}}",
    );

    var observation = rejected;
    observation.status = .accepted;
    observation.code.len = 0;
    observation.message.?.queue = .{ .admission_id = 1, .state = .queued };
    observation.message.?.progress = .{ .status = .waiting_for_permission, .action_id = 7 };
    try Expect.rendered(
        observation,
        accepted_prefix ++ ",\"queue\":{\"status\":\"queued\",\"admission\":\"1\"},\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"7\"}}}",
    );

    observation.message.?.queue.?.state = .{ .processing = processing };
    observation.message.?.progress = .{ .status = .in_flight };
    try Expect.rendered(
        observation,
        accepted_prefix ++ ",\"queue\":{\"status\":\"processing\",\"admission\":\"1\"}" ++ binding ++ ",\"progress\":{\"status\":\"in_flight\",\"action\":null}}}",
    );

    observation.message.?.queue.?.state = .{ .completed = .{
        .binding = processing,
        .answer = .{ .length = 6, .digest = @splat(0xff) },
    } };
    observation.message.?.progress = null;
    try Expect.rendered(
        observation,
        accepted_prefix ++ ",\"queue\":{\"status\":\"completed\",\"admission\":\"1\"}" ++ binding ++ ",\"result\":{\"status\":\"completed\",\"text\":{\"type\":\"text\",\"bytes\":\"6\",\"sha256\":\"" ++ full_digest ++ "\"}}}}",
    );

    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set("provider_http_422");
    observation.message.?.queue.?.state = .{ .failed = .{ .binding = processing, .code = code } };
    try Expect.rendered(
        observation,
        accepted_prefix ++ ",\"queue\":{\"status\":\"failed\",\"admission\":\"1\"}" ++ binding ++ ",\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"}}}",
    );

    try code.set("cancelled");
    observation.message.?.queue.?.state = .{ .cancelled = .{ .binding = processing, .code = code } };
    try Expect.rendered(
        observation,
        accepted_prefix ++ ",\"queue\":{\"status\":\"cancelled\",\"admission\":\"1\"}" ++ binding ++ ",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}}}",
    );
}

test "Message observation progress fits the resident response bound with escaped identities" {
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    var observation = store_module.CommandObservation{ .status = .accepted, .kind = .message };
    try observation.target.set(&escaped_session);
    observation.message = .{
        .content = .{ .length = std.math.maxInt(u64), .digest = @splat(0xff) },
        .queue = .{ .admission_id = std.math.maxInt(u64), .state = .queued },
        .progress = .{ .status = .waiting_for_permission, .action_id = std.math.maxInt(u64) },
    };
    var response: protocol.ResponseBuffer = .{};
    try renderCommandObservation(&response, &escaped_key, observation);
    try std.testing.expect(response.len <= protocol.command_observation_reply.maxBytes(.message));
}

test "control response variants fit exact worst-case JSON bounds" {
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const escaped_code = @as([protocol.max_code_bytes]u8, @splat(1));
    const observation_shapes = protocol.command_observation_reply;
    const observationBytes = struct {
        fn bytes(comptime kind: protocol.CommandKind, comptime parts: anytype) usize {
            var total = protocol.shapeBytes(observation_shapes.head(kind)) + protocol.shapeBytes(observation_shapes.tail);
            inline for (parts) |part| total += protocol.shapeBytes(part);
            return total;
        }
    }.bytes;
    var stop_command: protocol.SessionStopCommand = .{};
    try stop_command.session.set(&escaped_session);
    var interruption_command: protocol.ModelInterruptionCommand = .{
        .turn_id = std.math.maxInt(u64),
        .operation_id = std.math.maxInt(u64),
    };
    try interruption_command.session.set(&escaped_session);

    const Cases = struct {
        fn expectStop(
            command: *const protocol.SessionStopCommand,
            result: store_module.SessionStopReply,
            expected: usize,
        ) !void {
            var response: protocol.ResponseBuffer = .{};
            try renderSessionStopReply(&response, command, result);
            try std.testing.expectEqual(expected, response.len);
        }

        fn expectInterruption(
            command: *const protocol.ModelInterruptionCommand,
            result: store_module.ModelInterruptionReply,
            expected: usize,
        ) !void {
            var response: protocol.ResponseBuffer = .{};
            try renderModelInterruptionReply(&response, command, result);
            try std.testing.expectEqual(expected, response.len);
        }

        fn expectObservation(
            key: []const u8,
            observation: store_module.CommandObservation,
            expected: usize,
        ) !void {
            var response: protocol.ResponseBuffer = .{};
            try renderCommandObservation(&response, key, observation);
            try std.testing.expectEqual(expected, response.len);
        }
    };

    try Cases.expectStop(&stop_command, .{ .accepted = .{
        .replayed = false,
        .selection = .{
            .selected_turn_id = std.math.maxInt(u64),
            .admission_cutoff = std.math.maxInt(u64),
        },
        .completion = .completed,
    } }, protocol.shapeBytes(protocol.session_stop_reply.accepted));
    var pending_response: protocol.ResponseBuffer = .{};
    try renderSessionStopReply(&pending_response, &stop_command, .{ .accepted = .{
        .replayed = false,
        .selection = .{
            .selected_turn_id = std.math.maxInt(u64),
            .admission_cutoff = std.math.maxInt(u64),
        },
        .completion = .pending,
    } });
    try std.testing.expect(std.mem.endsWith(
        u8,
        pending_response.slice(),
        "\"completion\":{\"status\":\"pending\"}}",
    ));
    try Cases.expectStop(&stop_command, .{ .rejected = .{
        .replayed = false,
        .code = .invalid_session_reference,
    } }, protocol.shapeBytes(protocol.session_stop_reply.rejected));
    try Cases.expectStop(&stop_command, .conflict, protocol.shapeBytes(protocol.session_stop_reply.conflict));
    // Canonical faults use the fixed invocation error, not a command answer.
    const canonical_error = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}";
    try Cases.expectStop(
        &stop_command,
        .infrastructure_failure,
        canonical_error.len,
    );

    try Cases.expectInterruption(
        &interruption_command,
        .{ .accepted = .{ .replayed = false } },
        protocol.shapeBytes(protocol.model_interruption_reply.accepted),
    );
    try Cases.expectInterruption(&interruption_command, .{ .rejected = .{
        .replayed = false,
        .code = .invalid_session_reference,
    } }, protocol.shapeBytes(protocol.model_interruption_reply.rejected));
    try Cases.expectInterruption(
        &interruption_command,
        .conflict,
        protocol.shapeBytes(protocol.model_interruption_reply.conflict),
    );
    try Cases.expectInterruption(
        &interruption_command,
        .infrastructure_failure,
        canonical_error.len,
    );

    var stop_accepted = store_module.CommandObservation{
        .status = .accepted,
        .kind = .session_stop,
        .session_stop = .{
            .selection = .{
                .selected_turn_id = std.math.maxInt(u64),
                .admission_cutoff = std.math.maxInt(u64),
            },
            .completion = .completed,
        },
    };
    try stop_accepted.target.set(&escaped_session);
    try Cases.expectObservation(&escaped_key, stop_accepted, observationBytes(.session_stop, .{observation_shapes.session_stop}));

    var stop_rejected = store_module.CommandObservation{ .status = .rejected, .kind = .session_stop };
    try stop_rejected.target.set(&escaped_session);
    try stop_rejected.code.set(&escaped_code);
    try Cases.expectObservation(&escaped_key, stop_rejected, observationBytes(.session_stop, .{observation_shapes.code}));

    var target = store_module.ModelInterruptionTarget{
        .session = .{},
        .turn_id = std.math.maxInt(u64),
        .operation_id = std.math.maxInt(u64),
    };
    try target.session.set(&escaped_session);
    var interruption_accepted = store_module.CommandObservation{
        .status = .accepted,
        .kind = .model_interruption,
        .model_interruption = target,
    };
    try interruption_accepted.target.set(&escaped_session);
    try Cases.expectObservation(
        &escaped_key,
        interruption_accepted,
        observationBytes(.model_interruption, .{observation_shapes.model_interruption}),
    );

    var interruption_rejected = store_module.CommandObservation{
        .status = .rejected,
        .kind = .model_interruption,
        .model_interruption = target,
    };
    try interruption_rejected.target.set(&escaped_session);
    try interruption_rejected.code.set(&escaped_code);
    try Cases.expectObservation(
        &escaped_key,
        interruption_rejected,
        observationBytes(.model_interruption, .{ observation_shapes.code, observation_shapes.model_interruption }),
    );
}

test "every reply renders its exact worst-case bound from the shape it writes" {
    // Each bound comes from the shape its renderer writes, so the longest
    // value of every variant must reach it exactly. Text a renderer wrote
    // outside its shape, or a hole the bound missed, would fail here.
    const max = std.math.maxInt(u64);
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const escaped_code = @as([protocol.max_code_bytes]u8, @splat(1));
    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const content: store_module.ContentReference = .{ .length = max, .digest = @splat(0xff) };
    const binding: store_module.AttemptBinding = .{ .turn_id = max, .operation_id = max, .attempt_ordinal = max };
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try session.set(&escaped_session);
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set(&escaped_code);
    const Worst = struct {
        /// The tag a bound must allow for: the longest name.
        fn tag(comptime E: type) E {
            var longest = std.meta.tags(E)[0];
            for (std.meta.tags(E)) |value| {
                if (@tagName(value).len > @tagName(longest).len) longest = value;
            }
            return longest;
        }

        fn reply(render: anytype, command: anytype, results: anytype) !usize {
            var bytes: usize = 0;
            inline for (results) |result| {
                var response: protocol.ResponseBuffer = .{};
                try render(&response, command, result);
                bytes = @max(bytes, response.len);
            }
            return bytes;
        }

        fn observation(key: []const u8, value: store_module.CommandObservation) !usize {
            var response: protocol.ResponseBuffer = .{};
            try renderCommandObservation(&response, key, value);
            return response.len;
        }
    };

    var configure: protocol.ConfigureCommand = .{};
    try configure.session.set(&escaped_session);
    try std.testing.expectEqual(protocol.configuration_reply.max_bytes, try Worst.reply(renderConfigureReply, &configure, .{
        store_module.ConfigureReply{ .accepted = .{ .replayed = false, .revision = max, .created = false, .session = session } },
        store_module.ConfigureReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.ConfigurationRejection) } },
        store_module.ConfigureReply.conflict,
    }));

    var message: protocol.MessageCommand = .{};
    try message.session.set(&escaped_session);
    try std.testing.expectEqual(protocol.message_reply.max_bytes, try Worst.reply(renderMessageReply, &message, .{
        store_module.MessageReply{ .accepted = .{ .replayed = false, .admission_id = max, .content = content, .session = session } },
        store_module.MessageReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.MessageRejection), .content = content } },
        store_module.MessageReply.conflict,
    }));

    var stop: protocol.SessionStopCommand = .{};
    try stop.session.set(&escaped_session);
    try std.testing.expectEqual(protocol.session_stop_reply.max_bytes, try Worst.reply(renderSessionStopReply, &stop, .{
        store_module.SessionStopReply{ .accepted = .{ .replayed = false, .selection = .{ .selected_turn_id = max, .admission_cutoff = max }, .completion = Worst.tag(protocol.SessionStopCompletion) } },
        store_module.SessionStopReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.SessionStopRejection) } },
        store_module.SessionStopReply.conflict,
    }));

    var interruption: protocol.ModelInterruptionCommand = .{ .turn_id = max, .operation_id = max };
    try interruption.session.set(&escaped_session);
    try std.testing.expectEqual(protocol.model_interruption_reply.max_bytes, try Worst.reply(renderModelInterruptionReply, &interruption, .{
        store_module.ModelInterruptionReply{ .accepted = .{ .replayed = false } },
        store_module.ModelInterruptionReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.ModelInterruptionRejection) } },
        store_module.ModelInterruptionReply.conflict,
    }));

    var decision: protocol.PermissionDecisionCommand = .{ .action_id = max, .decision = Worst.tag(protocol.PermissionDecision) };
    try decision.session.set(&escaped_session);
    try std.testing.expectEqual(protocol.permission_decision_reply.max_bytes, try Worst.reply(renderPermissionDecisionReply, &decision, .{
        store_module.PermissionDecisionReply{ .accepted = .{ .replayed = false } },
        store_module.PermissionDecisionReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.PermissionDecisionRejection) } },
        store_module.PermissionDecisionReply.conflict,
    }));

    var failure: protocol.ResponseBuffer = .{};
    try renderStatic(&failure, Worst.tag(protocol.ErrorType), &escaped_code);
    try std.testing.expectEqual(protocol.max_control_error_response_bytes, failure.len);

    var host_info: protocol.ResponseBuffer = .{};
    try renderHostInfo(&host_info, &escaped_store, @splat(0xff), max, max, max, false, false);
    try std.testing.expectEqual(protocol.max_host_info_response_bytes, host_info.len);

    const observations = protocol.command_observation_reply;
    var configured = store_module.CommandObservation{ .status = .accepted, .kind = .configure, .code = code, .revision = max, .created = false };
    try configured.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.configure), try Worst.observation(&escaped_key, configured));

    const states = [_]store_module.AcceptedMessageQueue.State{
        .queued,
        .{ .excluded = .{ .code = code } },
        .{ .processing = binding },
        .{ .completed = .{ .binding = binding, .answer = content } },
        .{ .cancelled = .{ .binding = binding, .code = code } },
        .{ .failed = .{ .binding = binding, .code = code } },
    };
    var longest_message: usize = 0;
    for (states) |state| {
        var queued = store_module.CommandObservation{ .status = .accepted, .kind = .message, .code = code, .message = .{
            .content = content,
            .queue = .{ .admission_id = max, .state = state },
            .progress = .{ .status = Worst.tag(protocol.MessageProgressStatus), .action_id = max },
        } };
        try queued.target.set(&escaped_session);
        longest_message = @max(longest_message, try Worst.observation(&escaped_key, queued));
    }
    try std.testing.expectEqual(observations.maxBytes(.message), longest_message);

    var stopped = store_module.CommandObservation{ .status = .accepted, .kind = .session_stop, .code = code, .session_stop = .{
        .selection = .{ .selected_turn_id = max, .admission_cutoff = max },
        .completion = Worst.tag(protocol.SessionStopCompletion),
    } };
    try stopped.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.session_stop), try Worst.observation(&escaped_key, stopped));

    var interrupted = store_module.CommandObservation{ .status = .accepted, .kind = .model_interruption, .code = code, .model_interruption = .{
        .session = session,
        .turn_id = max,
        .operation_id = max,
    } };
    try interrupted.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.model_interruption), try Worst.observation(&escaped_key, interrupted));

    var decided = store_module.CommandObservation{ .status = .accepted, .kind = .permission_decision, .code = code, .permission_action_id = max, .permission_decision = Worst.tag(protocol.PermissionDecision) };
    try decided.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.permission_decision), try Worst.observation(&escaped_key, decided));
    try std.testing.expect(try Worst.observation(&escaped_key, .{ .status = .absent }) <= protocol.command_observation_reply.max_bytes);

    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set(&@as([protocol.max_tool_description_bytes]u8, @splat(1)));
    const presentation: protocol.ToolPresentation = .{ .description = description, .code = Worst.tag(protocol.ToolPresentation.Code), .publication_position = max };
    var longest_conversation: usize = 0;
    for (std.meta.tags(protocol.ConversationItemKind)) |kind| {
        var page: store_module.PublicConversationPage = .{ .end = max, .count = protocol.public_conversation_page_items, .more = true };
        for (&page.items) |*item| item.* = .{
            .position = max,
            .ordinal = max,
            .kind = kind,
            .content = content,
            .presentation = if (kind == .tool_result) presentation else null,
            .admitted_at = if (kind == .user) max else null,
            .sender = if (kind == .user) .{ .session = session } else null,
        };
        var response: protocol.FixedJsonBuffer(protocol.max_conversation_page_response_bytes) = .{};
        try renderConversationPage(&response, &page);
        longest_conversation = @max(longest_conversation, response.len);
    }
    try std.testing.expectEqual(protocol.max_conversation_page_response_bytes, longest_conversation);

    var proposals: store_module.ProposalPage = .{ .end = max, .count = protocol.proposal_page_items, .more = false };
    for (&proposals.items) |*item| item.* = .{
        .position = max,
        .operation = max,
        .turn = max,
        .call_ordinal = max,
        .action = max,
        .rejection = Worst.tag(protocol.ProposalRejection),
        .fields = @splat(.{ .length = max, .digest = content.digest }),
    };
    var proposal_response: protocol.FixedJsonBuffer(protocol.max_proposal_page_response_bytes) = .{};
    try renderProposalPage(&proposal_response, &proposals);
    try std.testing.expectEqual(protocol.max_proposal_page_response_bytes, proposal_response.len);

    var key: protocol.Bounded(protocol.max_key_bytes) = .{};
    try key.set(&escaped_key);
    const peer: protocol.Peer = .{ .session = session };
    const reference: protocol.ActivityItem.Content = .{ .length = max, .digest = content.digest };
    const field: @typeInfo(@FieldType(protocol.ProposalMetadata, "fields")).array.child = .{ .length = max, .digest = content.digest };
    const values = [_]protocol.ActivityItem.Value{
        .{ .admission = .{ .admission = max, .key = key, .turn = max, .state = Worst.tag(@FieldType(protocol.ActivityItem.Message, "state")), .content = reference, .admitted_at = max, .sender = peer } },
        .{ .user = .{ .admission = max, .key = key, .turn = max, .state = Worst.tag(@FieldType(protocol.ActivityItem.Message, "state")), .content = reference, .admitted_at = max, .sender = peer } },
        .{ .assistant = reference },
        .{ .call = .{ .position = max, .operation = max, .turn = max, .call_ordinal = max, .action = max, .rejection = Worst.tag(protocol.ProposalRejection), .fields = @splat(field) } },
        .{ .tool_result = .{ .content = reference, .presentation = presentation } },
        .{ .outcome = .{ .turn = max, .operation = max, .code = code, .content = reference } },
        .{ .stop = .{ .key = key, .turn = max, .cutoff = max, .completion = Worst.tag(protocol.SessionStopCompletion) } },
        .{ .sent = .{ .admission = max, .target = peer, .content = reference, .admitted_at = max } },
        .{ .send_failed = .{ .key = key, .target = peer, .code = code } },
    };
    try std.testing.expectEqual(std.meta.tags(std.meta.Tag(protocol.ActivityItem.Value)).len, values.len);
    var longest_item: protocol.ActivityItem = undefined;
    var longest_item_bytes: usize = 0;
    for (values) |value| {
        const item: protocol.ActivityItem = .{ .position = max, .ordinal = max, .value = value };
        var buffer: [protocol.ActivityItem.max_json_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try item.writeJson(&writer);
        if (writer.end > longest_item_bytes) {
            longest_item_bytes = writer.end;
            longest_item = item;
        }
    }
    try std.testing.expectEqual(protocol.ActivityItem.max_json_bytes, longest_item_bytes);
    var facts: protocol.ActivityFacts = .{ .end = max, .direction = Worst.tag(@FieldType(protocol.ActivityPage, "direction")), .count = 16, .more = false };
    @memset(&facts.items, longest_item);
    facts.call_activity = .{ .total = max, .count = 3 };
    @memset(&facts.call_activity.entries, .{ .operation = max, .ordinal = max, .presentation = presentation });
    facts.work = .{ .status = Worst.tag(protocol.PageWork.Status), .turn = max, .operation = max, .first_action = max, .revision = max };
    @memset(facts.work.workspace.bytes[0..protocol.max_workspace_bytes], 0x01);
    facts.work.workspace.len = protocol.max_workspace_bytes;
    var page_buffer: [protocol.max_activity_page_response_bytes]u8 = undefined;
    var page_writer = std.Io.Writer.fixed(&page_buffer);
    try facts.writeJson(&page_writer);
    try std.testing.expectEqual(protocol.max_activity_page_response_bytes, page_writer.end);
}

test "retired reserved exchanges cannot block their successors while workers are occupied" {
    for (std.enums.values(Route)) |route| {
        if (!route.isControl() and route != .host_info) continue;
        for ([_]Intake.Exchange.State{ .retired, .closed }) |retired_state| {
            var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .faults = .{}, .intake_capacity = descriptor_capacity.minimum_intake };
            var intake: Intake = .{ .host = &host };
            defer intake.exchanges.deinit(host.allocator);
            defer for (intake.exchanges.items) |exchange| {
                std.debug.assert(exchange.destroy());
            };
            // Neither local-work lane can reclaim these entries for us.
            for (&intake.workers) |*worker| worker.* = .{ .owner = &intake, .state = .running };
            const places: usize = if (route == .host_info) 1 else 2;
            for (0..places) |_| {
                var sockets: [2]c_int = undefined;
                try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
                defer _ = std.c.close(sockets[1]);
                try intake.accept(sockets[0]);
                const peer = intake.exchanges.items[intake.exchanges.items.len - 1];
                peer.route = route;
                peer.state = retired_state;
                if (retired_state == .closed) peer.closeSocket();
            }
            var sockets: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
            defer _ = std.c.close(sockets[1]);
            try intake.accept(sockets[0]);
            const successor = intake.exchanges.items[intake.exchanges.items.len - 1];
            const path = switch (route) {
                .host_info => "host-info",
                .host_stop => "control/host-stop",
                .session_stop => "control/session-stop",
                .model_interruption => "control/model-interruption",
                .permission_decision => "control/permission-decision",
                .unsupported_control => "control/unknown",
                else => unreachable,
            };
            var header: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(&header, "POST /v1/{s} HTTP/1.1\r\n", .{path});
            try writeAll(host.io, sockets[1], line);
            try successor.read();
            try std.testing.expectEqual(.header, successor.state);
            // A live reservation must still reject excess work.
            for (intake.exchanges.items[0..places]) |peer| peer.state = .header;
            successor.route = null;
            try writeAll(host.io, sockets[1], line);
            successor.header_bytes.clearRetainingCapacity();
            try std.testing.expectError(if (route == .host_info) error.DiscoveryCapacity else error.ControlCapacity, successor.read());
            for (intake.exchanges.items[0..places]) |peer| peer.state = .retired;
            intake.serviceWorkers();
            for (intake.exchanges.items[0..places]) |peer| {
                try std.testing.expectEqual(.closed, peer.state);
                try std.testing.expectEqual(@as(c_int, -1), peer.fd);
            }
        }
    }
}

test "disconnected reserved peers release classification while half-closed peers receive errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    for ([_][]const u8{ "host-info", "control/session-stop" }) |path| {
        for ([_]bool{ false, true }) |half_closed| {
            for ([_]bool{ true, false }) |body| {
                var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined, .faults = .{}, .intake_capacity = descriptor_capacity.minimum_intake };
                var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
                host.retention = &retention;
                var intake: Intake = .{ .host = &host };
                defer intake.exchanges.deinit(host.allocator);
                defer for (intake.exchanges.items) |exchange| std.debug.assert(exchange.destroy());
                const places: usize = if (std.mem.eql(u8, path, "host-info")) 1 else 2;
                var clients: [2]c_int = .{ -1, -1 };
                defer for (clients) |fd| {
                    if (fd >= 0) _ = std.c.close(fd);
                };
                var header: [128]u8 = undefined;
                const line = try std.fmt.bufPrint(&header, "POST /v1/{s} HTTP/1.1\r\n", .{path});
                for (0..places) |index| {
                    var sockets: [2]c_int = undefined;
                    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
                    clients[index] = sockets[1];
                    try setNonblocking(sockets[0]);
                    try intake.accept(sockets[0]);
                    const peer = intake.exchanges.items[index];
                    try writeAll(host.io, sockets[1], line);
                    if (body) try writeAll(host.io, sockets[1], "Content-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: 2\r\n\r\n{");
                    try peer.read();
                    if (half_closed) {
                        try std.testing.expectEqual(socket_os.Shutdown.done, socket_os.shutdown(sockets[1], std.c.SHUT.WR));
                    } else {
                        _ = std.c.close(sockets[1]);
                        clients[index] = -1;
                    }
                    // The listener can already have accepted the successor when
                    // this socket pass observes EOF on its predecessor.
                    peer.read() catch |err| peer.fail(err);
                }
                var sockets: [2]c_int = undefined;
                try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
                defer _ = std.c.close(sockets[1]);
                try intake.accept(sockets[0]);
                const successor = intake.exchanges.items[places];
                try writeAll(host.io, sockets[1], line);
                if (half_closed) {
                    try std.testing.expectError(if (places == 1) error.DiscoveryCapacity else error.ControlCapacity, successor.read());
                    for (intake.exchanges.items[0..places], clients[0..places]) |peer, client| {
                        while (!try peer.reply.?.advance(peer.fd)) {}
                        peer.state = .retired;
                        var response: [1024]u8 = undefined;
                        const length = try std.posix.read(client, &response);
                        try std.testing.expect(std.mem.startsWith(u8, response[0..length], "HTTP/1.1 400 "));
                        try std.testing.expect(std.mem.indexOf(u8, response[0..length], "UnexpectedEndOfBody") != null);
                    }
                    successor.route = null;
                    successor.header_bytes.clearRetainingCapacity();
                    try writeAll(host.io, sockets[1], line);
                }
                const failure: ?anyerror = if (successor.read()) |_| null else |err| err;
                try std.testing.expectEqual(@as(?anyerror, null), failure);
                try std.testing.expectEqual(.header, successor.state);
            }
        }
    }
}

test "file-free retirement releases intake places before acceptance with occupied workers" {
    for ([_]?Route{ null, .host_info, .host_stop, .configure, .inspect }) |route| {
        for ([_]bool{ false, true }) |service_workers| {
            var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .faults = .{} };
            var intake: Intake = .{ .host = &host };
            defer intake.exchanges.deinit(host.allocator);
            defer for (intake.exchanges.items) |exchange| {
                std.debug.assert(exchange.destroy());
            };
            for (&intake.workers) |*worker| worker.* = .{ .owner = &intake, .state = .running };
            var sockets: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
            defer _ = std.c.close(sockets[1]);
            try setNonblocking(sockets[1]);
            try intake.accept(sockets[0]);
            const peer = intake.exchanges.items[0];
            peer.route = route;
            peer.fail(error.ClientCapacity);
            // Complete a real bounded error reply, as the socket pass does.
            while (!try peer.reply.?.advance(peer.fd)) {}
            peer.state = .retired;
            if (service_workers) intake.serviceWorkers();
            // This is the same owner transition used between poll and accept.
            intake.retireExchanges();
            try std.testing.expectEqual(@as(usize, 0), intake.exchanges.items.len);
            var byte: [1024]u8 = undefined;
            while (try std.posix.read(sockets[1], &byte) != 0) {}
        }
    }
}

test "retired ordinary capture still consumes its intake classification and resource place" {
    for (std.enums.values(enum { ingress, retained_scratch, report })) |custody| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var lease: platform.StoreLease = undefined;
        lease.paths = .{};
        try lease.paths.scratch.set(root);
        var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined, .faults = .{}, .intake_capacity = descriptor_capacity.minimum_intake };
        var intake: Intake = .{ .host = &host };
        defer intake.exchanges.deinit(host.allocator);
        defer {
            for (intake.exchanges.items) |exchange| {
                if (exchange.retained_scratch) |*scratch| scratch.resources.?.removal = .native;
                exchange.cleanup_retry_at = 0;
                std.debug.assert(exchange.destroy());
            }
            std.debug.assert(host.scratch_used.load(.acquire) == 0);
        }
        for (&intake.workers) |*worker| worker.* = .{ .owner = &intake, .state = .running };
        for (0..host.intake_capacity) |_| {
            var sockets: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
            defer _ = std.c.close(sockets[1]);
            try intake.accept(sockets[0]);
            intake.exchanges.items[intake.exchanges.items.len - 1].route = .message;
        }
        const retained = intake.exchanges.items[0];
        var retained_fd: ?c_int = null;
        const budget: protocol.ScratchBudget = .{ .used = &host.scratch_used, .limit = 9000 };
        switch (custody) {
            .ingress => {
                const ingress = try host.allocator.create(protocol.Ingress);
                ingress.* = protocol.Ingress.init(host.allocator, .{
                    .io = host.io,
                    .fd = retained.fd,
                    .content_length = 4096,
                    .scratch_path = root,
                    .request_number = 7,
                    .retained_scratch = &retained.retained_scratch,
                    .scratch_budget = budget,
                    .expected_kind = .message,
                });
                retained.ingress = ingress;
                // Seal the content file, but leave request framing incomplete.
                try ingress.feed("{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"abc\"");
            },
            .retained_scratch, .report => {
                const file = try tmp.dir.createFile(host.io, "retained", .{ .read = true });
                try file.writeStreamingAll(host.io, "abc");
                try std.testing.expect(budget.charge(3));
                retained_fd = file.handle;
                if (custody == .retained_scratch) {
                    // Failed reclaim must stay off intake, even with no ingress left.
                    retained.retained_scratch = named_scratch.Owner.init(host.io, file, null, "retained", budget, 3, .injected_failure);
                } else {
                    retained.route = .inspect;
                    const reply = try retained.ensureReply();
                    try reply.setReport(.{ .io = host.io, .file = file, .length = 3, .charged = 3, .budget = budget });
                }
            },
        }
        retained.state = .retired;
        var sockets: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
        defer _ = std.c.close(sockets[1]);
        try intake.accept(sockets[0]);
        const successor = intake.exchanges.items[intake.exchanges.items.len - 1];
        try writeAll(host.io, sockets[1], "POST /v1/message HTTP/1.1\r\n");
        try std.testing.expectError(error.ClientCapacity, successor.read());
        intake.serviceWorkers();
        intake.retireExchanges();
        try std.testing.expectEqual(host.intake_capacity + 1, intake.exchanges.items.len);
        try std.testing.expectEqual(.retired, retained.state);
        try std.testing.expectEqual(@as(u64, 3), host.scratch_used.load(.acquire));
        if (retained_fd) |fd| try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFL) >= 0);
        // Only worker cleanup releases the file and charge, once reclamation can
        // succeed; the occupied lanes above must not perform it on intake.
        if (retained.retained_scratch) |*scratch| scratch.resources.?.removal = .native;
        retained.job = .cleanup;
        retained.state = try retained.work();
        try std.testing.expectEqual(.closed, retained.state);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        if (retained_fd) |fd| try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(fd, std.c.F.GETFL));
    }
}

test "shutdown fences every unhanded route while preserving request and reply custody" {
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .faults = .{} };
    var exchange = Intake.Exchange{ .owner = undefined, .host = &host, .fd = -1, .accepted_at_ns = 0, .deadline = 0 };
    const State = @TypeOf(exchange.state);
    for (std.enums.values(Route)) |route| {
        for ([_][2]State{
            .{ .header, .retired },  .{ .body, .retired }, .{ .ready, .retired },
            .{ .working, .working }, .{ .reply, .reply },  .{ .retired, .retired },
            .{ .closed, .closed },
        }) |states| {
            exchange.route = route;
            exchange.state = states[0];
            exchange.retireUnhanded();
            try std.testing.expectEqual(if (route == .host_stop and states[0] == .ready) .ready else states[1], exchange.state);
        }
    }
    exchange.route = null;
    exchange.state = .header;
    exchange.retireUnhanded();
    try std.testing.expectEqual(.retired, exchange.state);

    // Exercise actual worker handoff, including the race where shutdown wins
    // after the socket owner's earlier preflight. No worker may touch Store.
    var intake: Intake = .{ .host = &host };
    defer intake.exchanges.deinit(std.testing.allocator);
    for (&intake.workers) |*worker| worker.* = .{ .owner = &intake };
    try intake.exchanges.append(std.testing.allocator, &exchange);
    exchange.route = .configure;
    exchange.state = .ready;
    exchange.request = try std.testing.allocator.create(protocol.Request);
    exchange.request.?.* = .{ .configure = .{} };
    defer exchange.releaseRequest();
    _ = host.advance(.stopping);
    intake.serviceWorkers();
    try std.testing.expectEqual(.retired, exchange.state);
    try std.testing.expectEqual(.prepare, exchange.job);
    for (&intake.workers) |*worker| {
        try std.testing.expectEqual(.idle, worker.state);
        try std.testing.expectEqual(null, worker.exchange);
    }
    // The next owner pass schedules reclamation in the ordinary lane;
    // control cannot borrow that job merely because shutdown won handoff.
    intake.serviceWorkers();
    try std.testing.expectEqual(.cleanup, exchange.job);
    for (&intake.workers) |*worker| {
        if (worker.exchange) |owned| {
            try std.testing.expectEqual(.cleanup, owned.job);
            worker.next_state = try owned.work();
            worker.state = .done;
        }
    }
    intake.serviceWorkers();
    try std.testing.expectEqual(.closed, exchange.state);
    exchange.job = .fill;
    exchange.state = .ready;
    exchange.retireUnhanded();
    intake.serviceWorkers();
    try std.testing.expectEqual(.working, exchange.state);
    try std.testing.expectEqual(.requested, intake.workers[0].state);
    try std.testing.expectEqual(&exchange, intake.workers[0].exchange.?);

    // Complete retries already in intake must still validate their instance
    // and deliver the same acknowledgment after the shutdown fence.
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.store.set("s");
    host.lease = &lease;
    host.instance = @splat(17);
    for ([_]?protocol.InstanceId{ @splat(0), host.instance, host.instance, null }, [_][]const u8{
        "host_instance_changed", protocol.host_stop_ack, protocol.host_stop_ack, "host_instance_required",
    }) |instance_id, expected| {
        var sockets: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
        defer _ = std.c.close(sockets[0]);
        defer _ = std.c.close(sockets[1]);
        var retry = Intake.Exchange{
            .owner = &intake,
            .host = &host,
            .fd = sockets[0],
            .accepted_at_ns = nowNs(&host),
            .deadline = 0,
            .route = .host_stop,
            .state = .ready,
            .number = 1,
            .header = .{ .route = .host_stop, .content_length = 0, .instance = instance_id },
        };
        defer std.debug.assert(retry.cleanup());
        retry.request = try std.testing.allocator.create(protocol.Request);
        retry.request.?.* = .{ .host_stop = .{ .store = lease.paths.store } };
        retry.retireUnhanded();
        try std.testing.expectEqual(.ready, retry.state);
        try retry.prepare();
        try retry.reply.?.deliver(sockets[0]);
        try std.testing.expectEqual(socket_os.Shutdown.done, socket_os.shutdown(sockets[0], std.c.SHUT.WR));
        var response: [1024]u8 = undefined;
        var length: usize = 0;
        while (true) {
            try std.testing.expect(length < response.len);
            const count = std.c.read(sockets[1], response[length..].ptr, response.len - length);
            try std.testing.expect(count >= 0);
            if (count == 0) break;
            length += @intCast(count);
        }
        try std.testing.expect(std.mem.indexOf(u8, response[0..length], expected) != null);
    }
}

test "intake accepts and physically retires a hundred incomplete exchanges" {
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .faults = .{} };
    var intake: Intake = undefined;
    try intake.init(&host);
    var intake_owned = true;
    defer if (intake_owned) intake.deinit();
    var sockets: [100][2]std.posix.fd_t = undefined;
    var count: usize = 0;
    defer {
        for (sockets[0..count]) |pair| {
            _ = std.c.close(pair[1]);
            // Retain cleanup even for a mutant that omits physical close.
            if (!intake_owned and std.c.fcntl(pair[0], std.c.F.GETFL) >= 0) _ = std.c.close(pair[0]);
        }
    }
    for (&sockets) |*pair| {
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, pair));
        errdefer {
            _ = std.c.close(pair[0]);
            _ = std.c.close(pair[1]);
        }
        try setNonblocking(pair[0]);
        try intake.accept(pair[0]);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), intake.exchanges.items.len);
    intake.deinit();
    intake_owned = false;
    for (sockets) |pair| {
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(pair[0], std.c.F.GETFL));
        try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(@as(c_int, -1)));
    }
}

test "blocked ingress file work leaves controls discovery and shutdown responsive" {
    const Probe = struct {
        const Phase = enum { write, sync, cleanup };
        var entered = std.atomic.Value(bool).init(false);
        var released = std.atomic.Value(bool).init(false);
        var phase: Phase = .write;

        fn hold() void {
            entered.store(true, .release);
            while (!released.load(.acquire)) std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }

        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (phase == .write and operation == .file_write_streaming) hold();
            return std.testing.io.vtable.operate(userdata, operation);
        }

        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            if (phase == .sync) hold();
            return std.testing.io.vtable.fileSync(userdata, file);
        }

        fn delete(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8) std.Io.Dir.DeleteFileError!void {
            if (phase == .cleanup and (std.mem.startsWith(u8, path, "request-") or std.mem.indexOf(u8, path, "/request-") != null)) hold();
            return std.testing.io.vtable.dirDeleteFile(userdata, dir, path);
        }

        fn run(intake: *Intake, listener: *std.Io.net.Server) void {
            var open = true;
            var owned = true;
            intake.run(listener, &open, &owned) catch {};
            if (open) listener.deinit(std.testing.io);
        }

        fn send(fd: c_int, route: []const u8, body: []const u8, identity: bool) !void {
            var header: [512]u8 = undefined;
            const bytes = try std.fmt.bufPrint(&header, "POST {s} HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\n{s}Content-Length: {d}\r\n\r\n", .{ route, if (identity) "X-Rui-Host-Instance: 00000000000000000000000000000000\r\n" else "", body.len });
            try writeAll(std.testing.io, fd, bytes);
            if (phase == .cleanup and std.mem.eql(u8, route, "/v1/message")) {
                try writeAll(std.testing.io, fd, body[0 .. body.len - 3]);
                try std.testing.expectEqual(socket_os.Shutdown.done, socket_os.shutdown(fd, std.c.SHUT.WR));
            } else try writeAll(std.testing.io, fd, body);
        }

        fn response(fd: c_int) !void {
            var polls = [_]std.c.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            var bytes: [1024]u8 = undefined;
            var used: usize = 0;
            const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 3 * std.time.ns_per_s;
            while (true) {
                const remaining = deadline - std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds;
                try std.testing.expect(remaining > 0);
                try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&polls, 1, @intCast(@divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms))));
                try std.testing.expect(used < bytes.len);
                const count = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
                try std.testing.expect(count >= 0);
                if (count == 0) break;
                used += @intCast(count);
            }
            const response_bytes = bytes[0..used];
            try std.testing.expect(std.mem.startsWith(u8, response_bytes, "HTTP/1.1 200 "));
            const header_end = std.mem.indexOf(u8, response_bytes, "\r\n\r\n") orelse return error.IncompleteReply;
            const length_start = (std.mem.indexOf(u8, response_bytes[0..header_end], "Content-Length: ") orelse return error.MissingReplyLength) + "Content-Length: ".len;
            const length_end = std.mem.indexOfPos(u8, response_bytes, length_start, "\r\n").?;
            const length = try std.fmt.parseInt(usize, response_bytes[length_start..length_end], 10);
            try std.testing.expectEqual(length, used - header_end - 4);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var socket_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&socket_buffer, "/tmp/rui-{s}.sock", .{std.fs.path.basename(root)});
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const message_template = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"" ++
        @as([4097]u8, @splat('x')) ++ "\"}}";
    for (std.enums.values(Probe.Phase)) |phase| {
        Probe.phase = phase;
        Probe.entered.store(false, .release);
        Probe.released.store(false, .release);
        var vtable = std.testing.io.vtable.*;
        vtable.operate = Probe.operate;
        vtable.fileSync = Probe.sync;
        vtable.dirDeleteFile = Probe.delete;
        const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
        var lease: platform.StoreLease = undefined;
        lease.paths = .{};
        try lease.paths.store.set("s");
        try lease.paths.scratch.set(root);
        try lease.paths.socket.set(socket_path);
        var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
        const database = try std.fmt.bufPrint(&database_buffer, "{s}/{s}.sqlite", .{ root, @tagName(phase) });
        var storage = try store_module.Store.open(std.testing.io, database, root);
        defer storage.close() catch unreachable;
        var configure: protocol.ConfigureCommand = .{};
        try configure.key.set("config");
        configure.configuration.workspace.state = .value;
        try configure.configuration.workspace.value.set(root);
        configure.configuration.provider.state = .value;
        try configure.configuration.provider.value.set("codex");
        configure.configuration.model.state = .value;
        try configure.configuration.model.value.set("model-a");
        const configured = storage.configure(&configure, true, .{});
        try std.testing.expect(configured == .accepted);
        const session = configured.accepted.session.slice();
        const message = try std.mem.replaceOwned(u8, std.testing.allocator, message_template, "peer", session);
        defer std.testing.allocator.free(message);
        var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage, .instance = @splat(0), .faults = .{} };
        var retention = output_retention.Queue.initialize(io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
        host.retention = &retention;
        var intake: Intake = undefined;
        try intake.init(&host);
        defer intake.deinit();
        host.intake_wake = intake.wake[1];
        var listener = try address.listen(std.testing.io, .{ .kernel_backlog = 8 });
        const partial_header = try address.connect(std.testing.io);
        defer partial_header.socket.close(std.testing.io);
        const partial_body = try address.connect(std.testing.io);
        defer partial_body.socket.close(std.testing.io);
        // Establish both actual owner states before the reactor starts, so
        // EOF later proves retirement rather than unconsumed input.
        for ([_]c_int{ partial_header.socket.handle, partial_body.socket.handle }, [_][]const u8{
            "POST /v1/control/host-stop HTTP/1.1\r\nContent-Type: application/json\r\n",
            "POST /v1/control/host-stop HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: 1024\r\n\r\n{",
        }, [_]Intake.Exchange.State{ .header, .body }) |peer, bytes, state| {
            try writeAll(std.testing.io, peer, bytes);
            const accepted = try intake.acceptSocket(listener.socket.handle);
            intake.accept(accepted) catch |err| {
                _ = std.c.close(accepted);
                return err;
            };
            const exchange = intake.exchanges.items[intake.exchanges.items.len - 1];
            try exchange.read();
            try std.testing.expectEqual(state, exchange.state);
            try std.testing.expectEqual(.host_stop, exchange.route.?);
        }
        const before_uploads = host.request_counter.load(.acquire);
        const thread = try std.Thread.spawn(.{}, Probe.run, .{ &intake, &listener });
        var joined = false;
        defer if (!joined) {
            Probe.released.store(true, .release);
            _ = host.advance(.stopping);
            intake.notify();
            thread.join();
        };
        const upload = try address.connect(std.testing.io);
        defer upload.socket.close(std.testing.io);
        try Probe.send(upload.socket.handle, "/v1/message", message, false);
        const deadline = nowNs(&host) + 3 * std.time.ns_per_s;
        while (!Probe.entered.load(.acquire) and nowNs(&host) < deadline)
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        try std.testing.expect(Probe.entered.load(.acquire));
        const sibling = try address.connect(std.testing.io);
        defer sibling.socket.close(std.testing.io);
        try Probe.send(sibling.socket.handle, "/v1/message", message, false);
        // Classification occurs in the socket pass before its worker handoff
        // and before that pass can read a subsequently issued control.
        while (host.request_counter.load(.acquire) < before_uploads + 2 and nowNs(&host) < deadline)
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        try std.testing.expectEqual(before_uploads + 2, host.request_counter.load(.acquire));
        for ([_]struct { route: []const u8, body: []const u8, key: []const u8, kind: protocol.CommandKind, status: @FieldType(store_module.CommandObservation, "status") }{
            .{ .route = "/v1/control/session-stop", .body = "{\"version\":\"1\",\"kind\":\"session_stop\",\"store\":\"s\",\"key\":\"stop\",\"session\":\"peer\"}", .key = "stop", .kind = .session_stop, .status = .accepted },
            .{ .route = "/v1/control/model-interruption", .body = "{\"version\":\"1\",\"kind\":\"model_interruption\",\"store\":\"s\",\"key\":\"interrupt\",\"target\":{\"session\":\"peer\",\"turn\":\"1\",\"operation\":\"1\"}}", .key = "interrupt", .kind = .model_interruption, .status = .rejected },
            .{ .route = "/v1/control/permission-decision", .body = "{\"version\":\"1\",\"kind\":\"permission_decision\",\"store\":\"s\",\"key\":\"decision\",\"session\":\"peer\",\"action\":\"1\",\"decision\":\"deny\"}", .key = "decision", .kind = .permission_decision, .status = .rejected },
        }) |control| {
            const peer = try address.connect(std.testing.io);
            defer peer.socket.close(std.testing.io);
            const body = try std.mem.replaceOwned(u8, std.testing.allocator, control.body, "peer", session);
            defer std.testing.allocator.free(body);
            try Probe.send(peer.socket.handle, control.route, body, false);
            try Probe.response(peer.socket.handle);
            const saved = try storage.observeCommand(control.key);
            try std.testing.expectEqual(control.kind, saved.kind);
            try std.testing.expectEqual(control.status, saved.status);
            try std.testing.expect(!Probe.released.load(.acquire));
        }
        const discovery = try address.connect(std.testing.io);
        defer discovery.socket.close(std.testing.io);
        try Probe.send(discovery.socket.handle, "/v1/host-info", "{\"version\":\"1\",\"kind\":\"host_info\",\"store\":\"s\"}", false);
        try Probe.response(discovery.socket.handle);
        const stop = try address.connect(std.testing.io);
        defer stop.socket.close(std.testing.io);
        try Probe.send(stop.socket.handle, "/v1/control/host-stop", "{\"version\":\"1\",\"kind\":\"host_stop\",\"store\":\"s\"}", true);
        try Probe.response(stop.socket.handle);
        try std.testing.expect(host.stopping());
        try std.testing.expect(!Probe.released.load(.acquire));
        for ([_]c_int{ partial_header.socket.handle, partial_body.socket.handle }) |peer| {
            var polls = [_]std.c.pollfd{.{ .fd = peer, .events = std.posix.POLL.IN, .revents = 0 }};
            try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&polls, 1, 3000));
            var byte: [1]u8 = undefined;
            try std.testing.expectEqual(@as(isize, 0), std.c.read(peer, &byte, 1));
        }
        Probe.released.store(true, .release);
        thread.join();
        joined = true;
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
    }
}

test "readable ingress cannot cross its header or body deadline" {
    const Clock = struct {
        var nanoseconds: i96 = std.time.ns_per_s;
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = nanoseconds };
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    var host = Host{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .allocator = std.testing.allocator, .lease = &lease, .store = undefined, .faults = .{} };
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    for ([_]Route{ .host_stop, .host_info }) |route| {
        for ([_]bool{ false, true }) |body_only| {
            for ([_]i96{ -1, 0, 1 }) |offset| {
                Clock.nanoseconds = std.time.ns_per_s;
                var sockets: [2]c_int = undefined;
                try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
                defer _ = std.c.close(sockets[1]);
                try setNonblocking(sockets[0]);
                const exchange = try std.testing.allocator.create(Intake.Exchange);
                exchange.* = .{ .owner = undefined, .host = &host, .fd = sockets[0], .accepted_at_ns = 0, .deadline = 10 * std.time.ns_per_s };
                defer std.debug.assert(exchange.destroy());
                var body_buffer: [128]u8 = undefined;
                const body = try std.fmt.bufPrint(&body_buffer, "{{\"version\":\"1\",\"kind\":\"{s}\",\"store\":\"s\"}}", .{@tagName(route)});
                var header_buffer: [256]u8 = undefined;
                const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/{s} HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: {d}\r\n\r\n", .{ if (route == .host_stop) "control/host-stop" else "host-info", body.len });
                if (body_only) {
                    try writeAll(std.testing.io, sockets[1], header);
                    try exchange.read();
                    try std.testing.expectEqual(.body, exchange.state);
                }
                const deadline = exchange.deadline;
                Clock.nanoseconds = @intCast(deadline + offset);
                var wire_buffer: [384]u8 = undefined;
                const wire = try std.fmt.bufPrint(&wire_buffer, "{s}{s}", .{ if (body_only) "" else header, body });
                try writeAll(std.testing.io, sockets[1], wire);
                // Readiness is real, but cannot authorize bytes after expiry.
                var poll = [_]std.c.pollfd{.{ .fd = sockets[0], .events = std.posix.POLL.IN, .revents = 0 }};
                try std.testing.expectEqual(@as(c_int, 1), std.c.poll(&poll, poll.len, 0));
                if (offset >= 0) {
                    try std.testing.expectError(error.TransferInactive, exchange.read());
                    try std.testing.expectEqual(deadline, exchange.deadline);
                    try std.testing.expectEqual(null, exchange.request);
                    var remaining: [384]u8 = undefined;
                    const count = std.c.read(sockets[0], &remaining, remaining.len);
                    try std.testing.expectEqual(@as(isize, @intCast(wire.len)), count);
                    try std.testing.expectEqualStrings(wire, remaining[0..@intCast(count)]);
                } else {
                    try exchange.read();
                    try std.testing.expectEqual(.ready, exchange.state);
                    try std.testing.expectEqual(route.kind(), std.meta.activeTag(exchange.request.?.*));
                    const expected = if (route == .host_info) deadline else Clock.nanoseconds + 60 * std.time.ns_per_s;
                    try std.testing.expectEqual(@as(i128, expected), exchange.deadline);
                }
            }
        }
    }
}

test "ingress resumes its peer wait after local capture completion" {
    const Clock = struct {
        var nanoseconds: i96 = std.time.ns_per_s;
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = nanoseconds };
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    Clock.nanoseconds = std.time.ns_per_s;
    var host = Host{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .allocator = std.testing.allocator, .lease = &lease, .store = undefined, .faults = .{} };
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[1]);
    try setNonblocking(sockets[0]);
    const payload = @as([4097]u8, @splat('x'));
    const body = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"" ++ payload ++ "\"}}";
    var header_buffer: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/message HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: {d}\r\n\r\n", .{body.len});
    try writeAll(std.testing.io, sockets[1], header);
    try writeAll(std.testing.io, sockets[1], body);
    const exchange = try std.testing.allocator.create(Intake.Exchange);
    exchange.* = .{ .owner = undefined, .host = &host, .fd = sockets[0], .accepted_at_ns = std.time.ns_per_s, .deadline = 10 * std.time.ns_per_s };
    defer std.debug.assert(exchange.destroy());
    var intake: Intake = .{ .host = &host };
    defer intake.exchanges.deinit(std.testing.allocator);
    for (&intake.workers) |*worker| worker.* = .{ .owner = &intake };
    try intake.exchanges.append(std.testing.allocator, exchange);
    try exchange.read();
    intake.serviceWorkers();
    const worker = &intake.workers[0];
    try std.testing.expectEqual(.working, exchange.state);
    Clock.nanoseconds = 70 * std.time.ns_per_s;
    worker.next_state = try exchange.work();
    worker.state = .done;
    intake.serviceWorkers();
    try std.testing.expectEqual(.body, exchange.state);
    try std.testing.expectEqual(@as(i128, 130 * std.time.ns_per_s), exchange.deadline);
    // The remaining bytes were already queued during local capture. Consume
    // them through the same receive owner without expiring the peer first.
    while (exchange.state == .body) {
        try exchange.read();
        exchange.state = try exchange.work();
    }
    try std.testing.expectEqual(.ready, exchange.state);
    try std.testing.expectEqual(@as(u64, payload.len), exchange.request.?.message.text.length);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(&payload), &exchange.request.?.message.text.digest);
}

test "exchange retirement retains failed ingress cleanup through retry" {
    const FailDelete = struct {
        fn delete(_: ?*anyopaque, _: std.Io.Dir, _: []const u8) std.Io.Dir.DeleteFileError!void {
            return error.AccessDenied;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var paths: platform.Paths = .{};
    try paths.scratch.set(root);
    var lease: platform.StoreLease = undefined;
    lease.paths = paths;
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined, // Failed/incomplete captures never reach admission.
        .faults = .{},
    };
    const prefix = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"";
    const payload = @as([8192]u8, @splat('x'));
    const suffix = "\"}}";
    for ([_]bool{ false, true }) |seal| {
        var vtable = std.testing.io.vtable.*;
        vtable.dirDeleteFile = FailDelete.delete;
        const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
        var sockets: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
        defer _ = std.c.close(sockets[1]);
        const exchange = try std.testing.allocator.create(Intake.Exchange);
        exchange.* = .{ .owner = undefined, .host = &host, .fd = sockets[0], .accepted_at_ns = 0, .deadline = 0, .state = .retired };
        const ingress = try std.testing.allocator.create(protocol.Ingress);
        ingress.* = protocol.Ingress.init(std.testing.allocator, .{
            .io = io,
            .fd = sockets[0],
            .content_length = prefix.len + payload.len + suffix.len,
            .scratch_path = root,
            .request_number = 7,
            .retained_scratch = &exchange.retained_scratch,
            .scratch_budget = .{ .used = &host.scratch_used, .limit = 9000 },
            .expected_kind = .message,
        });
        exchange.ingress = ingress;
        var destroyed = false;
        defer if (!destroyed) {
            vtable.dirDeleteFile = std.testing.io.vtable.dirDeleteFile;
            exchange.cleanup_retry_at = 0;
            std.debug.assert(exchange.destroy());
        };
        host.scratch_used.store(23, .release);
        try ingress.feed(prefix ++ payload);
        if (seal) try std.testing.expectError(error.AccessDenied, ingress.feed(suffix));
        var intake: Intake = .{ .host = &host };
        defer intake.exchanges.deinit(std.testing.allocator);
        for (&intake.workers) |*worker| worker.* = .{ .owner = &intake };
        try intake.exchanges.append(std.testing.allocator, exchange);
        exchange.cleanup_retry_at = @as(i128, nowNs(&host)) + std.time.ns_per_s;
        intake.serviceWorkers();
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(sockets[0], std.c.F.GETFL));
        try std.testing.expect(!exchange.destroy());
        try std.testing.expect(!exchange.destroy());
        try std.testing.expectEqual(@as(u64, 8215), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(sockets[0], std.c.F.GETFL));
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(isize, 0), std.c.read(sockets[1], &byte, 1));
        const retained_fd = exchange.retained_scratch.?.resources.?.primary.handle;
        try std.testing.expect(std.c.fcntl(retained_fd, std.c.F.GETFL) >= 0);
        // A later cleanup retry must not close a new owner's reused fd.
        const recycled = @import("posix").dup2(sockets[1], sockets[0]);
        try std.testing.expectEqual(sockets[0], recycled);
        defer _ = std.c.close(recycled);
        exchange.cleanup_retry_at = 0;
        try std.testing.expect(!exchange.destroy());
        try std.testing.expect(std.c.fcntl(recycled, std.c.F.GETFL) >= 0);
        vtable.dirDeleteFile = std.testing.io.vtable.dirDeleteFile;
        exchange.cleanup_retry_at = 0;
        try std.testing.expect(exchange.destroy());
        destroyed = true;
        try std.testing.expectEqual(@as(u64, 23), host.scratch_used.load(.acquire));
        try std.testing.expect(std.c.fcntl(recycled, std.c.F.GETFL) >= 0);
        try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(retained_fd, std.c.F.GETFL));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "request-7-1.tmp", .{}));
    }
}
