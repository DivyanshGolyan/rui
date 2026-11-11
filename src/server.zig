const std = @import("std");
const change_ring = @import("change_ring.zig");
const activity_reply = @import("activity_reply.zig");
const os = @import("os/os.zig");
const socket_os = @import("os/socket.zig");
const pages = @import("os/pages.zig");
const HostDiagnostics = @import("HostDiagnostics.zig");
const TerminalText = @import("TerminalText.zig");
const TestObservation = @import("TestObservation.zig");
const bash = @import("bash.zig");
const environment = @import("environment.zig");
const SessionEnvironments = @import("SessionEnvironments.zig");
const descriptor_capacity = @import("descriptor_capacity.zig");
const product_defaults = @import("product_defaults.zig");
const descriptor_limit = @import("os/descriptor_limit.zig");
const execution = @import("execution.zig");
const execution_turn = @import("execution_turn.zig");
const model_adapter = @import("model_adapter.zig");
const failed_responses = @import("failed_responses.zig");
const named_scratch = @import("named_scratch.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const provider = @import("provider.zig");
const providers = @import("providers.zig");
const protocol = @import("protocol.zig");
const host_reply = @import("host_reply.zig");
const ScratchBudget = @import("ScratchBudget.zig");
const wire_request = @import("wire_request.zig");
const store_module = @import("store.zig");
const session_list_reply = @import("session_list_reply.zig");
const session_report_reply = @import("session_report_reply.zig");
const launch_frame = @import("launch_frame.zig");
const core_tools = @import("core_tools.zig");
const tools = @import("tools.zig");
const mcp_offered = @import("mcp/offered.zig");
const stderr = @import("stderr.zig");
const server_execution = @import("server_execution.zig");
const server_host = @import("server_host.zig");
const signal_stack = @import("signal_stack.zig");
const test_poll = @import("test_poll");
const ExecutionSlot = server_execution.ExecutionSlot;
const executionMain = server_execution.executionMain;

pub const default_bash_timeout_ms = server_host.default_bash_timeout_ms;
pub const default_bash_path = server_host.default_bash_path;
pub const scratch_limit_bytes = server_host.scratch_limit_bytes;
pub const default_retention_entry_capacity = server_host.default_retention_entry_capacity;
pub const Limits = server_host.Limits;
pub const Hooks = server_host.Hooks;
pub const Tuning = server_host.Tuning;
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

fn captureFailedResponse(host: *Host, request: *const protocol.InspectSession, request_number: u64) !store_module.SessionReport {
    const selection = request.failed_response.?;
    const binding = try host.store.failedResponseBinding(request.session.slice(), selection.operation, selection.attempt);
    var capture: store_module.SessionReportCapture = .{ .io = host.io, .writer = null, .budget = host.retention.sharedBudget() };
    try capture.create(host.lease.paths.scratch.slice(), request_number, host.hooks.fails(.report_unlink));
    errdefer capture.deinit();
    try failed_responses.exportRecord(host.io, host.lease.store_dir, binding, selection.part, &capture);
    return capture.seal();
}

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
    /// A launched Host's stdin, watched for its close (D5, D118).
    stdin: ?std.posix.fd_t = null,
    /// Set for a Host started from a launch frame; its shutdown is bounded.
    launched: bool = false,
    deadline_armed: bool = false,

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
        ingress: ?*wire_request.Ingress = null,
        /// The finished Request; it lives in `ingress`.
        request: ?*wire_request.Request = null,
        reply: ?*Reply = null,
        retained_scratch: ?named_scratch.Owner = null,
        cleanup_retry_at: i128 = 0,
        /// A Message's client environment: the body's first
        /// `X-Rui-Environment-Bytes` bytes, read before the request straight
        /// into the allocation the Session's register keeps. Admission
        /// spends it.
        environment: ?SessionEnvironments.Offer = null,
        environment_received: usize = 0,

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
                self.request = null;
                self.releaseIngress();
            }
        }

        fn releaseIngress(self: *Exchange) void {
            if (self.ingress) |ingress| {
                ingress.deinit();
                self.host.allocator.destroy(ingress);
                self.ingress = null;
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
            self.releaseIngress();
            self.input.deinit(host.allocator);
            self.input = .empty;
            self.releaseEnvironment();
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
            const reply = try createUnfilled(self.host.allocator, Reply);
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
                error.ClientCapacity, error.ControlCapacity, error.DiscoveryCapacity, error.OutOfMemory => 503,
                error.ScratchCapacityExhausted => 507,
                error.UnsupportedControl => 501,
                error.RequestIdentityExhausted => 500,
                error.EnvironmentTooLarge => 413,
                else => 400,
            };
            const code = switch (err) {
                error.ClientCapacity => "ordinary_capacity_exhausted",
                error.ControlCapacity => "control_capacity_exhausted",
                error.DiscoveryCapacity => "discovery_capacity_exhausted",
                error.RequestTooLarge => if (self.route == .host_info) "DiscoveryRequestTooLarge" else "control_request_too_large",
                error.RequestIdentityExhausted => "request_identity_exhausted",
                error.UnsupportedControl => "control_surface_enters_in_later_slice",
                error.EnvironmentRequired => "environment_required",
                error.EnvironmentTooLarge => "environment_too_large",
                error.InvalidEnvironment => "invalid_environment",
                error.InvalidSince => "invalid_since",
                else => @errorName(err),
            };
            const kind: protocol.ErrorType = switch (err) {
                error.ClientCapacity, error.ControlCapacity, error.DiscoveryCapacity, error.OutOfMemory => .busy,
                error.UnsupportedControl => .unsupported,
                else => .invocation_error,
            };
            respondStatic(reply, status, kind, code);
            // Detect a disconnected predecessor before classifying another
            // peer in this socket pass. Half-closed clients still receive
            // their bounded error through the ordinary reply state.
            self.state = if (reply.advance(self.fd) catch true) .retired else .reply;
        }

        fn read(self: *Exchange) !void {
            if (self.state == .body and self.environmentRemaining() != 0) return self.readEnvironment();
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            const wanted = if (self.ingress) |ingress|
                @min(buffer.len, self.environmentRemaining() + ingress.options.content_length - ingress.received)
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
                        .host_pause => protocol.max_host_pause_request_bytes,
                        .session_stop => protocol.max_session_stop_request_bytes,
                        .session_archive => protocol.max_session_archive_request_bytes,
                        .model_interruption => protocol.max_model_interruption_request_bytes,
                        .permission_decision => protocol.max_permission_decision_request_bytes,
                        else => std.math.maxInt(u64),
                    };
                    if (self.header.content_length > limit) return error.RequestTooLarge;
                    const request_length = try self.reserveEnvironment();
                    const ingress = try createUnfilled(self.host.allocator, wire_request.Ingress);
                    ingress.init(self.host.allocator, .{
                        .io = self.host.io,
                        .content_length = request_length,
                        .scratch_path = self.host.lease.paths.scratch.slice(),
                        .request_number = self.number.?,
                        .content_faults = self.host.hooks.contentFaults(),
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
            if (self.route == .message) {
                consumed += try self.receiveEnvironment(bytes[consumed..]);
                // The environment alone arrived: the record, never empty,
                // is still to come.
                if (consumed == bytes.len) return;
            }
            if (self.route == .configure or self.route == .message) {
                // One bounded window is borrowed by local capture work. No
                // socket read or peer wait runs on those shared stacks.
                try self.input.appendSlice(self.host.allocator, bytes[consumed..]);
                self.job = .receive;
                self.state = .ready;
            } else self.state = try self.receive(bytes[consumed..]);
        }

        /// A Message's body starts with its client environment; every other
        /// route carries none. Returns the request's own length, which for a
        /// Message is never zero, so its environment is always complete and
        /// checked before its request is.
        fn reserveEnvironment(self: *Exchange) !u64 {
            const length = self.header.environment_bytes orelse {
                if (self.route == .message) return error.EnvironmentRequired;
                return self.header.content_length;
            };
            if (self.route != .message) return error.InvalidEnvironment;
            if (length > protocol.max_environment_bytes) return error.EnvironmentTooLarge;
            if (length >= self.header.content_length) return error.InvalidEnvironment;
            self.environment = try .init(self.host.allocator, @intCast(length));
            if (length == 0) try self.checkEnvironment();
            return self.header.content_length - length;
        }

        /// Reads the rest of a Message's environment straight into the
        /// allocation the register keeps.
        fn readEnvironment(self: *Exchange) !void {
            if (@as(i128, nowNs(self.host)) >= self.deadline) return error.TransferInactive;
            const room = self.environment.?.room()[self.environment_received..];
            const result = std.c.read(self.fd, room.ptr, room.len);
            if (result < 0) switch (std.posix.errno(result)) {
                .AGAIN, .INTR => return,
                else => return error.ReadFailed,
            };
            if (result == 0) return error.UnexpectedEndOfBody;
            self.deadline = @as(i128, nowNs(self.host)) + 60 * std.time.ns_per_s;
            self.environment_received += @intCast(result);
            if (self.environmentRemaining() == 0) try self.checkEnvironment();
        }

        fn environmentRemaining(self: *const Exchange) usize {
            const offer = if (self.environment) |*held| held else return 0;
            if (offer.candidate == null) return 0;
            return offer.room().len - self.environment_received;
        }

        /// Takes the environment's bytes from the front of `bytes` and checks
        /// the whole once it has arrived. Returns how many it took.
        fn receiveEnvironment(self: *Exchange, bytes: []const u8) !usize {
            const wanted = @min(bytes.len, self.environmentRemaining());
            if (wanted == 0) return 0;
            @memcpy(self.environment.?.room()[self.environment_received..][0..wanted], bytes[0..wanted]);
            self.environment_received += wanted;
            if (self.environmentRemaining() == 0) try self.checkEnvironment();
            return wanted;
        }

        fn checkEnvironment(self: *Exchange) !void {
            const offer = &self.environment.?;
            offer.settle((try environment.received(self.host.allocator, offer.room())).len);
        }

        fn releaseEnvironment(self: *Exchange) void {
            if (self.environment) |*offer| offer.deinit(self.host.allocator);
            self.environment = null;
        }

        fn receive(self: *Exchange, bytes: []const u8) !State {
            const ingress = self.ingress.?;
            try ingress.feed(bytes);
            if (ingress.received == ingress.options.content_length) {
                self.request = try ingress.finish();
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
            // Admission spends the environment; nothing of it outlives this.
            defer self.releaseEnvironment();
            try prepareReply(self.host, reply, self.fd, self.header, self.number.?, self.accepted_at_ns, self.request.?, if (self.environment) |*offer| offer else null);
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
                if (exchange.route) |route| if (route.atomicOnly()) continue;
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

    /// stdin carries nothing after the launch frame; its close, or any
    /// failure to read it, stops the Host. Shutdown then has 10 seconds
    /// before the alarm's default action ends the process (D118).
    fn readStdin(self: *Intake) void {
        var bytes: [256]u8 = undefined;
        const count = std.c.read(self.stdin.?, &bytes, bytes.len);
        if (count > 0) return;
        if (count < 0 and std.posix.errno(count) == .INTR) return;
        self.stdin = null;
        traceSubject(self.host, "launch_stdin_closed", "host", "launch");
        self.armShutdownDeadline();
        _ = self.host.advance(.stopping);
    }

    /// A launched Host's shutdown, however it began (stdin close or
    /// `host-stop`), ends the process 10 seconds later if cleanup is still
    /// running; the alarm survives the drains after intake returns.
    fn armShutdownDeadline(self: *Intake) void {
        if (!self.launched or self.deadline_armed) return;
        self.deadline_armed = true;
        const default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.ALRM, &default, null);
        _ = std.c.alarm(product_defaults.host_shutdown_seconds);
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
                self.armShutdownDeadline();
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
                    .ready => if (exchange.route.?.atomicOnly()) {
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
            try self.polls.append(self.host.allocator, .{ .fd = self.stdin orelse -1, .events = std.posix.POLL.IN, .revents = 0 });
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
            if (self.polls.items[self.polls.items.len - 1].revents != 0) self.readStdin();
            for (self.exchanges.items, self.polls.items[2..][0..self.exchanges.items.len]) |exchange, poll| {
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
                if (self.host.hooks.fails(.shutdown_after_accept)) {
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

fn descriptorTransport(served: *const providers.Providers) descriptor_capacity.Transport {
    return if (served.modelListKey() != null) .listings else .catalog;
}

extern "c" fn rui_write_readiness(fd: c_int, bytes: [*]const u8, length: usize) c_int;

// MCP sockets run beside, not inside, the Bash/model slot population.
fn reserveMcpDescriptors(requirement: *descriptor_capacity.Requirement) !void {
    const sockets = @import("server_mcp.zig").capacity;
    requirement.execution = try std.math.add(usize, requirement.execution, sockets);
    requirement.total = try std.math.add(usize, requirement.total, sockets);
}

/// A Host started with a launch frame: its socket path, in the caller's
/// runtime directory, and the stdin whose close stops it.
pub const Launch = struct {
    runtime_dir: []const u8,
    socket_path: []const u8,
    stdin: std.posix.fd_t,
    mysql_url: ?*launch_frame.MysqlUrl = null,
    /// Open with Turns paused (D196): set before execution starts, so a Turn
    /// recovered from the Store waits too.
    paused: bool = false,
    /// The MCP servers whose tools the Host offers (M3a).
    mcp_servers: []const launch_frame.Frame.McpServer = &.{},
    presets: []const core_tools.Preset = &.{},
};

/// Lists each MCP server and saves the Host's catalog: the built-ins and
/// the servers' tools, with an unreachable server's last saved tools kept
/// (D147). A name two sources share refuses the start (D142).
noinline fn offerMcpTools(io: std.Io, arena: std.mem.Allocator, scratch: std.mem.Allocator, storage: *store_module.Store, servers: []const launch_frame.Frame.McpServer, stop: ?std.posix.fd_t) !void {
    var saved = try storage.readCatalog(arena);
    const kept: ?tools.Catalog = if (saved) |*found| found.catalog() else null;
    var collision: mcp_offered.Collision = .{};
    const catalog = mcp_offered.collect(io, arena, scratch, servers, if (kept) |*value| value else null, &collision, stop) catch |err| switch (err) {
        // The launcher closed stdin: stop as a closed stdin does later.
        error.Stopped => return error.EffectAwareShutdown,
        error.ToolNameCollision => {
            var message: [256]u8 = undefined;
            launch_frame.writeRefusal(io, .{
                .code = .tool_name_collision,
                .message = std.fmt.bufPrint(&message, "tool name {s} is offered by {s} and by {s}", .{ collision.name, collision.first, collision.second }) catch "a tool name is offered twice",
            });
            return err;
        },
        error.TooManyTools => {
            launch_frame.writeRefusal(io, .{ .code = .launch_frame_invalid, .message = "the MCP servers list more tools than a Host offers" });
            return err;
        },
        else => |other| return other,
    };
    const owned = try arena.create(tools.Catalog);
    owned.* = catalog;
    try storage.saveCatalog(owned);
}

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    store_path: []const u8,
    active_capacity: usize,
    limits: Limits,
    hooks: Hooks,
    served: *const providers.Providers,
    bash_path: []const u8,
    bash_timeout_ms: u64,
    home: ?[]const u8,
    launch: ?Launch,
) !void {
    const mcp_servers: []const launch_frame.Frame.McpServer = if (launch) |value| value.mcp_servers else &.{};
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
        descriptorTransport(served),
        served.leasedSignIn() != null,
        os.tag,
    );
    if (mcp_servers.len != 0) try reserveMcpDescriptors(&descriptor_requirement);
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
        descriptorTransport(served),
        served.leasedSignIn() != null,
        os.tag,
    );
    if (mcp_servers.len != 0) try reserveMcpDescriptors(&descriptor_requirement);
    var descriptor_limit_buffer: [32]u8 = undefined;
    const descriptor_limit_text = if (descriptor_observation.soft_limit) |limit|
        try std.fmt.bufPrint(&descriptor_limit_buffer, "{d}", .{limit})
    else
        "unlimited";
    const mysql_url = if (launch) |value| value.mysql_url else null;
    var lease: platform.StoreLease = undefined;
    if (mysql_url != null)
        try lease.acquireMysql(io, launch.?.runtime_dir, launch.?.socket_path)
    else
        lease = try platform.StoreLease.acquire(io, store_path);
    defer lease.release();
    if (mysql_url == null) if (launch) |value| try lease.useRuntimeDirectory(value.runtime_dir, value.socket_path);
    // fd1 may alias fd2. Exclude flag borrowing before any continuing
    // startup diagnostic, through readiness delivery and failed unwind.
    if (!stderr.tryExclude()) return error.HostReadinessOutputUnavailable;
    var readiness_owned = true;
    defer if (readiness_owned) stderr.release();
    var diagnostic_open_error: ?anyerror = null;
    var diagnostics: ?HostDiagnostics = HostDiagnostics.open(io, lease.store_dir, HostDiagnostics.default_cap_bytes) catch |err| blk: {
        diagnostic_open_error = err;
        break :blk null;
    };
    defer if (diagnostics) |*writer| writer.close();
    if (diagnostics) |*writer| writer.record("begin", "lease_acquired");
    if (diagnostics) |*writer| try recordCapacity(writer, intake_capacity, descriptor_requirement.total, descriptor_limit_text);
    var startup_failure: []const u8 = "startup_error";
    errdefer if (diagnostics) |*writer| writer.record("failed", startup_failure);
    // The catalog's records point into this arena, and the Store keeps the
    // catalog for its life, so it outlives the Store.
    var catalog_memory = std.heap.ArenaAllocator.init(allocator);
    defer catalog_memory.deinit();
    var storage: store_module.Store = undefined;
    openStoreForHost(io, &storage, &lease, served, &limits, mcp_servers.len != 0, mysql_url, if (diagnostics) |*writer| writer else null) catch |err| {
        if (err == error.StoreIdentityMismatch) startup_failure = "store_identity_mismatch";
        return err;
    };
    defer storage.close() catch |err| stderr.print("rui: Store close failed: {s}\n", .{@errorName(err)});
    return finishServing(io, &storage, launch != null, serveOpened(
        io,
        allocator,
        &storage,
        &lease,
        active_capacity,
        limits,
        hooks,
        served,
        bash_path,
        bash_timeout_ms,
        home,
        launch,
        &catalog_memory,
        mcp_servers,
        intake_capacity,
        descriptor_requirement.total,
        descriptor_observation.soft_limit,
        descriptor_limit_text,
        &diagnostics,
        diagnostic_open_error,
        &readiness_owned,
    ));
}

/// All serving owners drain before the Store's shutdown result is decided.
fn serveOpened(
    io: std.Io,
    allocator: std.mem.Allocator,
    storage: *store_module.Store,
    lease: *platform.StoreLease,
    active_capacity: usize,
    limits: Limits,
    hooks: Hooks,
    served: *const providers.Providers,
    bash_path: []const u8,
    bash_timeout_ms: u64,
    home: ?[]const u8,
    launch: ?Launch,
    catalog_memory: *std.heap.ArenaAllocator,
    mcp_servers: []const launch_frame.Frame.McpServer,
    intake_capacity: usize,
    descriptor_requirement: usize,
    descriptor_soft_limit: ?usize,
    descriptor_limit_text: []const u8,
    diagnostics: *?HostDiagnostics,
    diagnostic_open_error: ?anyerror,
    readiness_owned: *bool,
) !void {
    if (mcp_servers.len != 0) try offerMcpTools(io, catalog_memory.allocator(), allocator, storage, mcp_servers, if (launch) |value| value.stdin else null);
    try storage.validateRetryWaits(limits.retry_waits_ms);
    try lease.prepareForServing(hooks.fails(.startup_cleanup));

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

    const bash_facts = try bash.readHostFacts(io, allocator, home);
    defer bash.freeHostFacts(allocator, bash_facts);
    const environments = try allocator.create(SessionEnvironments);
    defer allocator.destroy(environments);
    try environments.init(io, allocator);
    defer environments.deinit();
    // Zero bytes are an empty custody record and retention entry, so fresh
    // pages need no initializing pass and an unused one never becomes resident.
    const custody_records = try pages.mapZeroed(execution.CustodyRecord, active_capacity);
    defer pages.unmapZeroed(custody_records);
    const retention_capacity = @min(
        default_retention_entry_capacity,
        limits.retention_entry_capacity orelse default_retention_entry_capacity,
    );
    const retention_entries = try pages.mapZeroed(output_retention.Entry, retention_capacity);
    defer pages.unmapZeroed(retention_entries);
    var host = Host{
        .io = io,
        .allocator = allocator,
        .intake_capacity = intake_capacity,
        .descriptor_soft_limit = descriptor_soft_limit,
        .lease = lease,
        .store = storage,
        .hooks = hooks,
        .limits = limits,
        .providers = served,
        .presets = if (launch) |value| value.presets else &.{},
        .bash_path = bash_path,
        .bash_facts = bash_facts,
        .environments = environments,
        .bash_timeout_ms = bash_timeout_ms,
        .retention = undefined,
        .trace_run_ns = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds),
        .custody = execution.CustodyPool.initialize(custody_records),
        .turns_paused = .init(if (launch) |value| value.paused else false),
    };
    try host.mcp_servers.init(allocator, mcp_servers);
    defer host.mcp_servers.deinit(allocator);
    var observation: ?TestObservation = if (hooks.observation_fd) |fd|
        try TestObservation.init(fd, hooks.observation_state_fd orelse return error.MissingTestObservationState, hooks.observation_plan orelse return error.MissingTestObservationPlan, host.trace_run_ns)
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
        if (hooks.retention_removal) .injected_failure else .native,
    );
    host.retention = &retention;
    defer retention.cleanupAll();
    host.failed_response_store = lease.store_dir;
    if (served.any()) {
        for (served.table.values) |entry| if (entry) |value| {
            try provider.validateEndpoint(value.endpoint);
            try value.credential.validate(value.endpoint, served.ca_file);
        };
        try provider.checkLibraries();
    }
    try std.Io.randomSecure(io, &host.instance);
    const started_at = std.Io.Clock.real.now(io).toSeconds();
    if (started_at <= 0) return error.ClockReadFailed;
    host.started_at = @intCast(started_at);
    // Freed after intake and execution are joined: they read and fill it.
    // Pending from the start: execution launches the fetch, or settles it.
    host.model_lists = .{ .io = io, .allocator = allocator, .providers = served, .live = if (served.modelListKey() != null) .pending else .catalog };
    defer host.model_lists.deinit();
    var intake: Intake = undefined;
    try intake.init(&host);
    defer intake.deinit();
    if (launch) |value| {
        intake.stdin = value.stdin;
        intake.launched = true;
    }
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
    try writeReadiness(&lease.paths, active_capacity, intake_capacity, descriptor_requirement, descriptor_limit_text, retention_entries.len, served.any());
    stderr.release();
    readiness_owned.* = false;
    if (diagnostic_open_error) |err|
        stderr.print("rui: startup diagnostics unavailable ({s}); continuing under Store lease\n", .{@errorName(err)});
    if (diagnostics.*) |*writer| {
        if (writer.failure != null) writer.reportFailure();
        writer.record("ready", "serving");
        writer.close();
        diagnostics.* = null;
    }

    return intake.run(&listener, &listener_open, &socket_owned);
}

fn finishServing(io: std.Io, storage: *const store_module.Store, launched: bool, result: anyerror!void) !void {
    // This is the sole decision and publication site, after intake, workers
    // and execution have drained. A fence wins over every serving outcome.
    if (launched and storage.kind() == .mysql and storage.isFenced()) {
        launch_frame.writeRefusal(io, .{ .code = .store_fenced, .message = "the MySQL Store lost ownership or its connection; restart the Host" });
        return error.StoreFenced;
    }
    return result;
}

// serve's frame stays resident for the Host's life, so each startup-only
// buffer lives in a noinline function of its own.

noinline fn recordCapacity(writer: *HostDiagnostics, intake_capacity: usize, descriptor_requirement: usize, descriptor_limit_text: []const u8) !void {
    var detail: [256]u8 = undefined;
    writer.record("capacity", try std.fmt.bufPrint(&detail, "ordinary_intake={d} default_intake={d} minimum_intake={d} descriptor_requirement={d} descriptor_limit={s}", .{
        intake_capacity,        product_defaults.intake_capacity, descriptor_capacity.minimum_intake,
        descriptor_requirement, descriptor_limit_text,
    }));
}

/// Admission's options and login framing are startup scratch, not part of
/// serve's resident frame on either engine. The caller provides both owners.
noinline fn openStoreForHost(
    io: std.Io,
    storage: *store_module.Store,
    lease: *platform.StoreLease,
    served: *const providers.Providers,
    limits: *const Limits,
    has_mcp: bool,
    mysql_url: ?*launch_frame.MysqlUrl,
    diagnostics: ?*HostDiagnostics,
) !void {
    var found_schema_version: u32 = store_module.schema_version;
    var identity_mismatch: store_module.IdentityMismatch = .{};
    const store_options: store_module.OpenOptions = .{
        .served = served.routes(),
        .cache_spill = limits.sqlite_cache_spill,
        .cache_kib = limits.sqlite_cache_kib,
        .found_schema_version = &found_schema_version,
        .identity_mismatch = &identity_mismatch,
        // With MCP servers the catalog is saved below, once they are listed.
        .catalog = if (!has_mcp) &tools.built_in else null,
    };
    // The login is borrowed only by admission and wiped on every exit.
    defer if (mysql_url) |url| url.wipe();
    const target: store_module.Target = if (mysql_url) |url|
        .{ .mysql = url.options() }
    else
        .{ .sqlite = lease.paths.database.slice() };
    const selector = if (mysql_url) |url| url.database.slice() else lease.paths.store.slice();
    storage.openTarget(io, target, selector, store_options) catch |err| {
        if (mysql_url == null) {
            if (err == error.WrongStoreVersion) {
                try reportWrongStoreVersion(lease.paths.store.slice(), found_schema_version);
                if (diagnostics) |writer| writer.record("failed", "unsupported_store_version");
            } else if (err == error.StoreIdentityMismatch) {
                try reportStoreIdentityMismatch(identity_mismatch.saved_selector.slice(), lease.paths.store.slice());
            }
        }
        return err;
    };
    lease.paths.store.set(storage.storeId()) catch unreachable;
}

noinline fn reportStoreIdentityMismatch(saved_selector: []const u8, actual_selector: []const u8) !void {
    var message: [2 * TerminalText.max_bytes_per_byte * protocol.max_store_bytes + 512]u8 = undefined;
    var output = std.Io.Writer.fixed(&message);
    try writeStoreIdentityMismatch(&output, saved_selector, actual_selector);
    const text = output.buffered();
    _ = rui_write_readiness(2, text.ptr, text.len);
}

fn writeStoreIdentityMismatch(output: *std.Io.Writer, saved_selector: []const u8, actual_selector: []const u8) !void {
    try output.writeAll("rui: SQLite Store identity mismatch.\nSaved original canonical folder: ");
    var saved_text: TerminalText = .{ .mode = .line };
    try saved_text.feed(output, saved_selector);
    try saved_text.finish(output);
    try output.writeAll("\nActual canonical folder: ");
    var actual_text: TerminalText = .{ .mode = .line };
    try actual_text.feed(output, actual_selector);
    try actual_text.finish(output);
    try output.writeAll("\nStop Hosts and preserve the complete Store. Restore the directory to its saved original canonical folder, or back up this Store and choose a fresh --store. A symlink at the old path does not restore canonical identity. No Store identity was changed.\n");
}

test "Store identity diagnostic fits startup forwarding at maximum escaped paths" {
    const path = @as([protocol.max_store_bytes]u8, @splat(1));
    var bytes: [2 * TerminalText.max_bytes_per_byte * protocol.max_store_bytes + 512]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    try writeStoreIdentityMismatch(&output, &path, &path);
    const text = output.buffered();
    try std.testing.expect(text.len < 8192);
    try std.testing.expectEqual(@as(usize, 2 * protocol.max_store_bytes), std.mem.count(u8, text, "\\x01"));
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 1) == null);
    try std.testing.expect(std.mem.endsWith(u8, text, "No Store identity was changed.\n"));
}

noinline fn reportWrongStoreVersion(store_path: []const u8, found_schema_version: u32) !void {
    var message: [4 * protocol.max_store_bytes + 512]u8 = undefined;
    var output = std.Io.Writer.fixed(&message);
    const reason = if (found_schema_version == store_module.schema_version)
        "unsupported or missing Store wire metadata"
    else
        "unsupported Store format";
    try output.print("rui: {s} at ", .{reason});
    var path_text: TerminalText = .{ .mode = .line };
    try path_text.feed(&output, store_path);
    try path_text.finish(&output);
    try output.print(": found schema {d}, this build supports schema {d} (wire {s}). Use a compatible Rui build at the Store's original path, or back up this Store and choose a fresh Store with --store. No migration was performed; do not delete your saved work. See https://github.com/DivyanshGolyan/rui#start-fresh-after-a-store-format-change\n", .{
        found_schema_version, store_module.schema_version, protocol.wire_version,
    });
    const text = output.buffered();
    _ = rui_write_readiness(2, text.ptr, text.len);
}

noinline fn writeReadiness(
    paths: *const platform.Paths,
    active_capacity: usize,
    intake_capacity: usize,
    descriptor_requirement: usize,
    descriptor_limit_text: []const u8,
    retention_capacity: usize,
    provider_enabled: bool,
) !void {
    var ready: protocol.ResponseBuffer = .{};
    try ready.appendFmt("ready store={s} socket={s} active_capacity={d} intake_capacity={d} descriptor_requirement={d} descriptor_limit={s} custody_record_bytes={d} execution_slot_bytes={d} model_preparation_bytes={d} scratch_limit_bytes={d} retention_entry_bytes={d} retention_capacity={d} bash_execution=enabled execution={s}", .{
        paths.store.slice(),
        paths.socket.slice(),
        active_capacity,
        intake_capacity,
        descriptor_requirement,
        descriptor_limit_text,
        @sizeOf(execution.CustodyRecord),
        @sizeOf(ExecutionSlot),
        @sizeOf(model_adapter.Preparation),
        scratch_limit_bytes,
        @sizeOf(output_retention.Entry),
        retention_capacity,
        if (provider_enabled) "enabled" else "unavailable",
    });
    if (provider_enabled) {
        try ready.appendFmt(" nghttp2={s} openssl={s}", .{ provider.nghttp2_version, provider.openssl_version });
    }
    try ready.append("\n");
    if (rui_write_readiness(1, ready.slice().ptr, ready.slice().len) != 0)
        return error.HostReadinessOutputUnavailable;
}

fn publishControlHint(host: *Host, command_key: []const u8) void {
    if (host.hooks.suppress_first_control_hint and
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
        if (!self.host.hooks.phase_trace) return null;
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
        const gate_hook = self.host.hooks.control_gate orelse return;
        var candidates = std.mem.splitScalar(u8, gate_hook.keys, ',');
        while (candidates.next()) |candidate| {
            if (!std.mem.eql(u8, candidate, self.command_key.slice())) continue;
            // Integration tests deliberately hold this acquired Store entry
            // (the Store runs nothing else meanwhile) until intake routes a competing control. Their keeper
            // descriptor prevents FIFO-open deadlock; process teardown bounds
            // a missing release without granting this gate semantic authority.
            var gate = std.Io.Dir.cwd().openFile(self.host.io, gate_hook.path, .{}) catch return;
            defer gate.close(self.host.io);
            var release: [1]u8 = undefined;
            const count = gate.readStreaming(self.host.io, &.{&release}) catch return;
            if (count == 1) traceSubject(self.host, "control_gate_released", "command_key", self.command_key.slice());
            return;
        }
    }

    /// An inline guard and a noinline body, like the server_host traces.
    inline fn replyComplete(self: *ControlTiming) void {
        if (self.host.hooks.phase_trace) self.writeReplyComplete();
    }

    noinline fn writeReplyComplete(self: *ControlTiming) void {
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
    host_pause,
    configure,
    message,
    session_stop,
    session_archive,
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
    activity_page,
    activity_search,
    activity_content,
    skill_suggestions,
    model_list,
    unsupported_control,

    fn isControl(self: Route) bool {
        return self == .host_stop or self == .host_pause or self == .session_stop or self == .session_archive or self == .model_interruption or self == .permission_decision or self == .unsupported_control;
    }

    /// Answered on the listener from atomics and fixed values alone,
    /// never by a worker or SQLite.
    fn atomicOnly(self: Route) bool {
        return self == .host_info or self == .host_stop or self == .host_pause;
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
    /// `X-Rui-Environment-Bytes`: how much of the body is client environment.
    environment_bytes: ?u64 = null,
    drop: DropMode = .none,
    instance: ?protocol.InstanceId = null,
};

/// Admits a Message and, in the same Store transaction's lock, offers its
/// client environment to the Session's register, so execution never starts
/// the Turn's Bash before the environment is in place. The register keeps
/// `offer`'s allocation or leaves it, with what it released, to be freed
/// right after admission.
noinline fn submitMessage(host: *Host, command: *const wire_request.MessageCommand, offer: *SessionEnvironments.Offer) error{OutOfMemory}!store_module.MessageReply {
    std.debug.assert(offer.value() != null);
    defer offer.deinit(host.allocator);
    var memory: std.heap.ArenaAllocator = .init(host.allocator);
    defer memory.deinit();
    const prepared = @import("session_skills.zig").prepareMessage(memory.allocator(), host.allocator, host.io, host.store, command, host.bash_facts.home) catch |err| {
        // The Store owns canonical fault classification. An allocation outside
        // held access (binding included) cannot corrupt that Store.
        if (host.store.isFenced()) return .infrastructure_failure;
        return if (err == error.OutOfMemory) error.OutOfMemory else .infrastructure_failure;
    };
    const initial_skills = prepared.initial;
    const captured_skill = prepared.captured;
    const faults = host.hooks.storeFaults(.command);
    const environments = host.environments orelse return host.store.submitMessageCapturedSkills(command, null, initial_skills, if (captured_skill) |*value| value else null, faults);
    const Install = struct {
        environments: *SessionEnvironments,
        offer: *SessionEnvironments.Offer,

        fn call(context: *anyopaque, admission: store_module.Store.MessageAdmission) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.environments.offer(admission.session, .{
                .origin = if (admission.from_peer) .peer else .person,
                .admission = admission.admission_id,
            }, self.offer);
        }
    };
    var install: Install = .{ .environments = environments, .offer = offer };
    return host.store.submitMessageCapturedSkills(command, .{ .context = &install, .call = Install.call }, initial_skills, if (captured_skill) |*value| value else null, faults);
}

/// Resolve before the Store hashes or saves. Normal answers bind the resolved
/// configuration; a preset lookup/update refusal binds the original request,
/// including its name. The Store keeps that identity for a saved refusal even
/// if the preset later exists: the same request cannot become an acceptance.
noinline fn submitConfigure(host: *Host, command: *const wire_request.ConfigureCommand) error{OutOfMemory}!store_module.ConfigureReply {
    const name = command.preset orelse return configureCapturedSkills(host, command, null);
    var decision: store_module.PresetDecision = .{ .request_digest = command.presetRequestDigest() };
    if (command.session.len != 0) {
        decision.rejection = .preset_on_update;
        return try host.store.configureWithPreset(command, &decision, host.hooks.storeFaults(.command));
    }
    const preset = for (host.presets) |*entry| {
        if (std.mem.eql(u8, entry.name, name.slice())) break entry;
    } else {
        decision.rejection = .unknown_preset;
        return try host.store.configureWithPreset(command, &decision, host.hooks.storeFaults(.command));
    };
    var memory: std.heap.ArenaAllocator = .init(host.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    // Configuration is kilobytes, owned by this request rather than the stack.
    const resolved = try arena.create(wire_request.ConfigureCommand);
    resolved.* = .{
        .store = command.store,
        .key = command.key,
        .session = command.session,
        .require_model = command.require_model,
        .reload_skills = command.reload_skills,
    };
    const checked = core_tools.parseAgentSpec(arena, preset.spec, &resolved.configuration) catch |err| return configureFailure(host, err);
    // The immutable launch frame checked this same spec with this parser.
    std.debug.assert(checked == .accepted);
    inline for (@typeInfo(wire_request.Configuration).@"struct".field_names) |field| {
        const override = &@field(command.configuration, field);
        if (override.state != .omitted) @field(resolved.configuration, field) = override.*;
    }
    return configureCapturedSkills(host, resolved, &decision);
}

/// The Store owns canonical fault classification. Running out of heap
/// outside held access cannot corrupt the Store: the Host is busy.
fn configureFailure(host: *Host, err: anyerror) error{OutOfMemory}!store_module.ConfigureReply {
    if (host.store.isFenced()) return .infrastructure_failure;
    return if (err == error.OutOfMemory) error.OutOfMemory else .infrastructure_failure;
}

noinline fn configureCapturedSkills(host: *Host, command: *const wire_request.ConfigureCommand, preset: ?*const store_module.PresetDecision) error{OutOfMemory}!store_module.ConfigureReply {
    var memory: std.heap.ArenaAllocator = .init(host.allocator);
    defer memory.deinit();
    const reload_capture: ?store_module.CapturedSkill = if (command.reload_skills and !(host.store.commandExists(command.key.slice()) catch return .infrastructure_failure))
        @import("session_skills.zig").capture(memory.allocator(), host.allocator, host.io, host.store, command.session.slice(), &.{ .operation = .reload }, host.bash_facts.home) catch |err| return configureFailure(host, err)
    else
        null;
    const initial_skills = if (command.session.len == 0 and !command.reload_skills)
        @import("session_skills.zig").initial(memory.allocator(), host.allocator, host.io, host.store, command.key.slice(), &command.configuration, host.bash_facts.home) catch |err| return configureFailure(host, err)
    else
        null;
    return host.store.configureWithCapturedSkills(command, preset, initial_skills, if (reload_capture) |*value| value else null, host.allocator, host.hooks.storeFaults(.command));
}

/// `client_environment` holds a Message's checked environment.
fn prepareReply(host: *Host, fd: *Reply, socket: std.posix.fd_t, header: Header, request_number: u64, accepted_at_ns: u64, request: *wire_request.Request, client_environment: ?*SessionEnvironments.Offer) !void {
    // The first MySQL readiness probe learns the opaque id over the private
    // socket. All subsequent work must name that exact id, never the URL.
    const discovering = request.* == .host_info and request.store().len == 0 and host.store.kind() == .mysql;
    if (!discovering and !std.mem.eql(u8, request.store(), host.lease.paths.store.slice())) {
        return respondStatic(fd, 409, .invocation_error, "wrong_store_identity");
    }
    if (header.instance) |instance| {
        if (!std.mem.eql(u8, &instance, &host.instance)) {
            return respondStatic(fd, 409, .invocation_error, "host_instance_changed");
        }
    }
    if (header.route == .host_stop and header.instance == null) {
        return respondStatic(fd, 400, .invocation_error, "host_instance_required");
    }
    if (header.drop == .before_admission) return;
    if (header.drop == .during_admission and socket_os.shutdown(socket, std.c.SHUT.RDWR) == .failed) {
        return error.InjectedDisconnectFailed;
    }

    switch (request.*) {
        .host_info => {
            if (!host.launchAllowed()) return respondStatic(fd, 503, .host_unavailable, "dispatch_fenced");
            // Atomics and fixed values only: this reply never touches SQLite.
            try fd.json(200, protocol.max_host_info_response_bytes, host_reply.renderHostInfo, .{host_reply.HostInfo{
                .store = host.lease.paths.store.slice(),
                .instance = host.instance,
                .active_capacity = host.custody.records.len,
                .intake_capacity = host.intake_capacity,
                .descriptor_soft_limit = host.descriptor_soft_limit,
                .started_at = host.started_at,
                .custody_occupied = host.custody.held(),
                .paused = host.turns_paused.load(.acquire),
                .routes = host.providers.routes(),
                .doublewrite = host.store.admissionDiagnostic().doublewrite,
            }});
        },
        .host_pause => |pause| {
            if (!host.launchAllowed()) return respondStatic(fd, 503, .host_unavailable, "dispatch_fenced");
            // Execution reads the flag at its next admission pass.
            host.turns_paused.store(pause.paused, .release);
            try fd.json(200, comptime protocol.shapeBytes(protocol.host_pause_reply), host_reply.renderHostPause, .{pause.paused});
        },
        .host_stop => {
            if (host.advance(.stopping) != .stopping) wakeListener(host);
            if (header.drop != .after_commit) try fd.json(200, protocol.host_stop_ack.len, protocol.JsonOut.append, .{protocol.host_stop_ack});
        },
        .configure => |*command| {
            const result = try submitConfigure(host, command);
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "configuration save", error.CanonicalStoreFailure);
            }
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            try fd.json(host_reply.httpStatus(result), protocol.max_response_bytes, host_reply.renderConfigureReply, .{ command.session.slice(), result });
        },
        .message => |*command| {
            const result = try submitMessage(host, command, client_environment.?);
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "message save", error.CanonicalStoreFailure);
            }
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            try fd.json(host_reply.httpStatus(result), protocol.max_response_bytes, host_reply.renderMessageReply, .{ command.session.slice(), result });
        },
        .session_stop => |*command| {
            var timing = ControlTiming.init(host, command.key, "session_stop", accepted_at_ns);
            const result = host.store.stopSession(command, host.hooks.storeFaults(.{ .control = timing.storeTrace() }));
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "Session stop save", error.CanonicalStoreFailure);
            }
            if (result == .accepted) publishControlHint(host, command.key.slice());
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            try fd.json(host_reply.httpStatus(result), protocol.max_response_bytes, host_reply.renderSessionStopReply, .{ command.session.slice(), result });
            fd.timing = timing;
        },
        .session_archive => |*command| {
            var timing = ControlTiming.init(host, command.key, "session_archive", accepted_at_ns);
            const result = host.store.archiveSession(command, host.hooks.storeFaults(.{ .control = timing.storeTrace() }));
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "Session archive save", error.CanonicalStoreFailure);
            }
            if (result == .accepted) publishControlHint(host, command.key.slice());
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            try fd.json(host_reply.httpStatus(result), protocol.max_response_bytes, host_reply.renderSessionArchiveReply, .{ command.session.slice(), result });
            fd.timing = timing;
        },
        .model_interruption => |*command| {
            var timing = ControlTiming.init(host, command.key, "model_interruption", accepted_at_ns);
            const result = host.store.interruptModel(command, host.hooks.storeFaults(.{ .control = timing.storeTrace() }));
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "model interruption save", error.CanonicalStoreFailure);
            }
            if (result == .accepted) publishControlHint(host, command.key.slice());
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            try fd.json(host_reply.httpStatus(result), protocol.max_response_bytes, host_reply.renderModelInterruptionReply, .{ store_module.ModelInterruptionTarget{ .session = command.session, .turn_id = command.turn_id, .operation_id = command.operation_id }, result });
            fd.timing = timing;
        },
        .permission_decision => |*command| {
            var timing = ControlTiming.init(host, command.key, "permission_decision", accepted_at_ns);
            const result = host.store.decidePermission(command, host.hooks.storeFaults(.{ .control = timing.storeTrace() }));
            if (result == .infrastructure_failure) {
                fenceDispatch(host, "permission decision save", error.CanonicalStoreFailure);
            }
            if (result == .accepted) publishControlHint(host, command.key.slice());
            if (header.drop == .after_commit and result != .infrastructure_failure) return;
            try fd.json(host_reply.httpStatus(result), protocol.max_response_bytes, host_reply.renderPermissionDecisionReply, .{ host_reply.PermissionTarget{ .session = command.session, .action_id = command.action_id, .decision = command.decision }, result });
            fd.timing = timing;
        },
        .observe_command => |*command| {
            var observation: store_module.Observed = undefined;
            host.store.observeCommand(command.key.slice(), command.since, &observation) catch |err| {
                fenceDispatch(host, "command observation", err);
                return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
            };
            switch (observation) {
                .full => server_host.traceCommandObservation(host, command.key.slice(), "request_observation_full"),
                .not_modified => |token| if (command.since) |since| {
                    server_host.traceCommandObservation(host, command.key.slice(), if (token.generation > since.generation)
                        "request_observation_tier2"
                    else
                        "request_observation_tier1");
                },
            }
            try fd.json(200, host_reply.commandObservationBytes(&observation), host_reply.renderCommandObservation, .{ command.key.slice(), &observation });
        },
        .read_result => |*command| {
            const reference = host.store.commandResult(command.key.slice()) catch |err| switch (err) {
                error.ResultNotFound => return respondStatic(fd, 409, .result_unavailable, "result_not_found"),
                error.ResultNotReady => return respondStatic(fd, 409, .result_unavailable, "result_not_ready"),
                error.ResultFailed => return respondStatic(fd, 409, .result_unavailable, "result_failed"),
                else => {
                    fenceDispatch(host, "result observation", err);
                    return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            const location = host.store.openContent(reference) catch |err| {
                fenceDispatch(host, "result content read", err);
                return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
            };
            try fd.setContent(location, 0, true, false);
        },
        .read_action_arguments => |*command| deliverActionContent(host, fd, command, false),
        .read_action_call_id => |*command| deliverActionContent(host, fd, command, true),
        .inspect_session => |*request_value| {
            if (request_value.failed_response != null) {
                const capture = captureFailedResponse(host, request_value, request_number) catch |err| {
                    if (err == error.ReportScratchCleanupFailed) {
                        fenceDispatch(host, "failed response export scratch cleanup", err);
                        return respondStatic(fd, 500, .observation_error, "report_scratch_cleanup_failed");
                    }
                    if (host.store.isFenced()) {
                        fenceDispatch(host, "failed response identity", err);
                        return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                    }
                    return respondStatic(fd, 409, .failed_response_unavailable, @errorName(err));
                };
                try fd.setReport(capture);
                try fd.prepareHeader(200, "application/octet-stream", capture.length);
                return;
            }
            const report = captureSessionReport(host, request_value, request_number) catch |err| {
                if (err == error.ReportScratchCleanupFailed) {
                    fenceDispatch(host, "session report scratch cleanup", err);
                    return respondStatic(fd, 500, .observation_error, "report_scratch_cleanup_failed");
                }
                if (host.store.isFenced()) {
                    fenceDispatch(host, "session inspection", err);
                    return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                }
                return respondStatic(fd, if (err == error.ReportScratchExhausted) 507 else 500, .observation_error, @errorName(err));
            };
            try fd.setReport(report);
            traceSubject(host, "inspection_captured", "session", request_value.session.slice());
            traceSqliteDiagnostic(host, request_value.session.slice());
            try fd.holdDelivery(host.hooks.inspection_reply);
            if (fd.gate != null) traceSubject(host, "test_gate_waiting", "path", host.hooks.inspection_reply.gate_path.?);
        },
        .list_sessions => |*request_value| {
            // Nothing changed since the token: answered from atomics, with no
            // Store lock, scratch or SQLite.
            if (request_value.since) |since| {
                if (request_value.changed == null and host.store.notModified(since)) {
                    return fd.json(200, protocol.max_response_bytes, host_reply.renderSessionsNotModified, .{since});
                }
            }
            const page = captureSessionList(host, request_value, request_number) catch |err| {
                if (err == error.ReportScratchCleanupFailed) {
                    fenceDispatch(host, "Session list scratch cleanup", err);
                    return respondStatic(fd, 500, .observation_error, "report_scratch_cleanup_failed");
                }
                if (host.store.isFenced()) {
                    fenceDispatch(host, "Session list", err);
                    return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                }
                return respondStatic(fd, if (err == error.ReportScratchExhausted) 507 else 500, .observation_error, @errorName(err));
            };
            try fd.setReport(page);
        },
        .conversation_page => |*command| {
            const page = try createUnfilled(host.allocator, store_module.PublicConversationPage);
            defer host.allocator.destroy(page);
            host.store.publicConversationPage(command, page) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(fd, 409, .conversation_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "conversation page", err);
                    return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            try fd.json(200, protocol.max_conversation_page_response_bytes, host_reply.renderConversationPage, .{page});
        },
        .conversation_content => |*command| try prepareConversationContent(host, fd, command),
        .activity_page => |*command| {
            const page = try createUnfilled(host.allocator, protocol.ActivityFacts);
            defer host.allocator.destroy(page);
            host.store.activityPage(command, page) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(fd, 409, .activity_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "activity page", err);
                    return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            try fd.json(200, host_reply.activityPageBytes(page), host_reply.renderActivityPage, .{page});
        },
        .activity_search => |*command| {
            const page = try createUnfilled(host.allocator, protocol.ActivitySearchFacts);
            defer host.allocator.destroy(page);
            host.store.searchActivity(command, page) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(fd, 409, .activity_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "activity search", err);
                    return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            try fd.json(200, activity_reply.max_search_bytes, host_reply.renderActivitySearch, .{page});
        },
        .activity_content => |*command| {
            const location = host.store.openActivityContent(command) catch |err| switch (err) {
                error.ContentNotFound => return respondStatic(fd, 409, .activity_unavailable, @errorName(err)),
                else => {
                    fenceDispatch(host, "activity content", err);
                    return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                },
            };
            try deliverPublicContent(host, fd, location, 0, true);
        },
        .skill_suggestions => |*command| {
            const scope: @import("skill_suggestions.zig").Scope = if (command.session) |*session| .{ .session = session.slice() } else .{ .workspace = command.workspace.?.slice() };
            var page = readSkillSuggestions(host, host.allocator, scope, command.prefix.slice()) catch |err| {
                if (err == error.CanonicalStoreFailure) return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
                // Heap exhaustion is the Host being busy, as for a Message: 503.
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return respondStatic(fd, 409, .activity_unavailable, if (err == error.SessionNotFound) "SessionNotFound" else "skills_unavailable");
            };
            defer page.deinit(host.allocator);
            try fd.jsonGrowing(200, protocol.skill_suggestions_reply.max_bytes, host_reply.renderSkillSuggestions, .{&page});
        },
        // Refresh is asynchronous; the selected facts are an operation-scoped
        // Store read, never retained beside the provider's live account list.
        .model_list => {
            host.listings_requested.store(true, .release);
            var arena: std.heap.ArenaAllocator = .init(host.allocator);
            defer arena.deinit();
            const facts = host.store.readModelCatalog(arena.allocator()) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                fenceDispatch(host, "model catalog", err);
                return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
            };
            try fd.jsonGrowing(200, protocol.model_list_reply.maxBytes(facts), renderModelList, .{ host, facts });
        },
    }
}

/// Materialization uses caller-owned memory after the canonical catalog read.
fn readSkillSuggestions(host: *Host, allocator: std.mem.Allocator, scope: @import("skill_suggestions.zig").Scope, prefix: []const u8) !@import("skill_suggestions.zig").Page {
    return @import("session_skills.zig").suggestions(allocator, host.allocator, host.io, host.store, scope, prefix, host.bash_facts.home) catch |err| {
        if (scope == .session and host.store.isFenced()) {
            fenceDispatch(host, "skill suggestions", err);
            return error.CanonicalStoreFailure;
        }
        return err;
    };
}

fn renderModelList(out: protocol.JsonOut, host: *Host, facts: []const @import("model_catalog.zig").Entry) error{BufferTooLarge}!void {
    out.writer.writeAll(protocol.model_list_reply.head) catch return error.BufferTooLarge;
    host.model_lists.render(out.writer, facts) catch return error.BufferTooLarge;
    out.writer.writeAll(protocol.model_list_reply.tail) catch return error.BufferTooLarge;
}

/// One Session report, read by the Store and written by the Host
/// (`session_report_reply`), in an owned, unlinked scratch file: no SQLite
/// cursor survives it. Deinitializing it releases its scratch charge.
fn captureSessionReport(host: *Host, request: *const protocol.InspectSession, request_number: u64) !store_module.SessionReport {
    var capture: store_module.SessionReportCapture = .{ .io = host.io, .writer = null, .budget = host.retention.sharedBudget() };
    try capture.create(host.lease.paths.scratch.slice(), request_number, host.hooks.fails(.report_unlink));
    errdefer capture.deinit();
    const reply = try createUnfilled(host.allocator, session_report_reply.Reply(store_module.SessionReportCapture));
    defer host.allocator.destroy(reply);
    reply.capture = &capture;
    reply.execution = executionFacts(host);
    try host.store.readSessionReport(request.session.slice(), request.profile, reply);
    return capture.seal();
}

/// One list page, read by the Store and written by the Host
/// (`session_list_reply`), in an owned, unlinked scratch file: no SQLite
/// cursor survives it. Deinitializing it releases its scratch charge.
fn captureSessionList(host: *Host, request: *const protocol.ListSessions, request_number: u64) !store_module.SessionReport {
    try request.validate();
    var capture: store_module.SessionReportCapture = .{ .io = host.io, .writer = null, .budget = host.retention.sharedBudget() };
    try capture.create(host.lease.paths.scratch.slice(), request_number, host.hooks.fails(.report_unlink));
    errdefer capture.deinit();
    const reply = try createUnfilled(host.allocator, session_list_reply.Reply(store_module.SessionReportCapture));
    defer host.allocator.destroy(reply);
    reply.capture = &capture;
    reply.rows = 0;
    try host.store.readSessionList(request, reply);
    return capture.seal();
}

/// One `T` on the heap whose bytes stay unwritten until its initializer or
/// producer fills them. `Allocator.create` would first write 0xAA over every
/// byte in ReleaseSafe. Freed with `allocator.destroy`.
fn createUnfilled(allocator: std.mem.Allocator, comptime T: type) error{OutOfMemory}!*T {
    const bytes = allocator.rawAlloc(@sizeOf(T), .of(T), @returnAddress()) orelse return error.OutOfMemory;
    return @ptrCast(@alignCast(bytes));
}

fn deliverConversationContent(host: *Host, fd: std.posix.fd_t, command: protocol.ConversationContent) !void {
    var reply = Reply{ .io = host.io, .allocator = host.allocator };
    defer reply.deinit();
    try prepareConversationContent(host, &reply, &command);
    reply.deliver(fd) catch |err| {
        if (host.store.isFenced()) fenceDispatch(host, "public content", err);
    };
}

fn prepareConversationContent(host: *Host, fd: *Reply, command: *const protocol.ConversationContent) !void {
    const location = host.store.openPublicConversationContent(command) catch |err| switch (err) {
        error.ContentNotFound, error.RangeOutOfBounds => return respondStatic(fd, 409, .conversation_unavailable, @errorName(err)),
        else => {
            fenceDispatch(host, "conversation content", err);
            return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
        },
    };
    return deliverPublicContent(host, fd, location, command.start, command.stream);
}

fn deliverPublicContent(host: *Host, fd: *Reply, location: store_module.ContentLocation, start: u64, stream: bool) !void {
    fd.setContent(location, start, stream, true) catch |err| {
        fenceDispatch(host, "public content", err);
        fd.deinit();
        return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
    };
}

fn deliverActionContent(host: *Host, fd: *Reply, command: anytype, comptime call_id: bool) void {
    const phase = if (call_id) "Action call identity observation" else "Action argument observation";
    const reference = if (call_id)
        host.store.actionCallId(command.session.slice(), command.action_id)
    else
        host.store.actionArguments(command.session.slice(), command.action_id);
    const resolved = reference catch |err| switch (err) {
        error.ActionNotFound => return respondStatic(fd, 404, .action_unavailable, "action_not_found"),
        else => {
            fenceDispatch(host, phase, err);
            return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
        },
    };
    const location = host.store.openContent(resolved) catch |err| {
        fenceDispatch(host, phase, err);
        return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
    };
    fd.setContent(location, 0, true, false) catch {};
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
        inline for (comptime std.enums.values(protocol.CommandKind)) |kind| {
            if (std.mem.eql(u8, path, kind.route())) return @field(Route, @tagName(kind));
        }
        return if (std.mem.eql(u8, path, "/v1/host-info"))
            .host_info
        else if (std.mem.eql(u8, path, "/v1/control/host-stop"))
            .host_stop
        else if (std.mem.eql(u8, path, "/v1/control/host-pause"))
            .host_pause
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
        else if (std.mem.eql(u8, path, "/v1/activity-search"))
            .activity_search
        else if (std.mem.eql(u8, path, "/v1/activity-page"))
            .activity_page
        else if (std.mem.eql(u8, path, "/v1/activity-content"))
            .activity_content
        else if (std.mem.eql(u8, path, "/v1/skill-suggestions"))
            .skill_suggestions
        else if (std.mem.eql(u8, path, "/v1/model-list"))
            .model_list
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
        var environment_bytes: ?u64 = null;
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
            } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Environment-Bytes")) {
                if (environment_bytes != null) return error.InvalidEnvironment;
                environment_bytes = std.fmt.parseInt(u64, value, 10) catch return error.InvalidEnvironment;
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
            .environment_bytes = environment_bytes,
            .drop = drop,
            .instance = instance,
        };
    }
};

test "canonical failure classifier accepts every production mutation failure envelope" {
    const protocol_reply = @import("protocol_reply.zig");
    inline for (.{ host_reply.renderConfigureReply, host_reply.renderMessageReply, host_reply.renderSessionStopReply, host_reply.renderSessionArchiveReply, host_reply.renderModelInterruptionReply, host_reply.renderPermissionDecisionReply }) |render| {
        const Subject = @typeInfo(@TypeOf(render)).@"fn".param_types[1].?;
        var response = protocol.ResponseBuffer{};
        try response.render(render, .{ std.mem.zeroes(Subject), .infrastructure_failure });
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}", response.slice());
        try std.testing.expectError(error.CanonicalStoreFailure, protocol_reply.checkCanonicalFailure(.{ .status = 500, .body = response.slice() }));
    }
}

// Test-only DOM edits let every witness start from an actual producer reply;
// production continues to parse once into bounded values, without a DOM.
fn expectMutationFieldPresence(body: []const u8, status: u16, session: []const u8, target: @import("protocol_reply.zig").MutationTarget) !void {
    const protocol_reply = @import("protocol_reply.zig");
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const Section = struct { path: []const []const u8, fields: []const []const u8 };
    const sections = [_]Section{
        .{ .path = &.{}, .fields = &.{ "version", "type", "code", "answer", "input", "queue", "execution", "completion" } },
        .{ .path = &.{"answer"}, .fields = &.{ "status", "replayed", "session", "code", "revision", "created", "admission", "archived", "action", "decision", "selection", "target" } },
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
                const decoded = protocol_reply.decodeMutationReply(.{ .status = status, .body = encoded }, session, target);
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
                    try std.testing.expectError(error.InvalidResponse, protocol_reply.decodeMutationReply(.{ .status = status, .body = omitted }, session, target).answer);
                    try object.object.put(parsed.arena.allocator(), field, value);
                }
            }
        }
    }
}

test "mutation decoder validates all six actual producers and preserved domain answers" {
    const protocol_reply = @import("protocol_reply.zig");
    const session = "k7m2qx";
    const content: store_module.ContentReference = .{ .length = 9, .digest = protocol.contentDigest("seven\nµ!") };
    inline for (.{ host_reply.renderConfigureReply, host_reply.renderMessageReply, host_reply.renderSessionStopReply, host_reply.renderModelInterruptionReply, host_reply.renderPermissionDecisionReply, host_reply.renderSessionArchiveReply }, 0..) |render, index| {
        const MutationReply = @typeInfo(@TypeOf(render)).@"fn".param_types[2].?;
        var named: protocol.Bounded(protocol.max_session_bytes) = .{};
        try named.set(session);
        const subject = switch (index) {
            3 => store_module.ModelInterruptionTarget{ .session = named, .turn_id = 3, .operation_id = 11 },
            4 => host_reply.PermissionTarget{ .session = named, .action_id = 7, .decision = .deny },
            else => @as([]const u8, session),
        };
        const target: protocol_reply.MutationTarget = switch (index) {
            0 => .configure,
            1 => .{ .message = .{ .bytes = content.length, .digest = content.digest } },
            2 => .session_stop,
            3 => .{ .model_interruption = .{ .turn = 3, .operation = 11 } },
            4 => .{ .permission_decision = .{ .action = 7, .decision = .deny } },
            5 => .{ .session_archive = .{ .archived = true } },
            else => unreachable,
        };
        const accepted: MutationReply = switch (index) {
            0 => .{ .accepted = .{ .replayed = true, .revision = 13, .created = false, .session = named } },
            1 => .{ .accepted = .{ .replayed = true, .admission_id = 17, .content = content, .session = named } },
            2 => .{ .accepted = .{ .replayed = true, .selection = .{ .selected_turn_id = 19, .admission_cutoff = 23 }, .completion = .pending } },
            3, 4 => .{ .accepted = .{ .replayed = true } },
            5 => .{ .accepted = .{ .replayed = true, .archived = true, .completion = .pending } },
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
                try response.render(render, .{ subject, result });
                const status: u16 = if (result == .conflict) 409 else if (result == .infrastructure_failure) 500 else 200;
                const decoded = protocol_reply.decodeMutationReply(.{ .status = status, .body = response.slice() }, session, target);
                try std.testing.expectEqual(status, decoded.status);
                try expectMutationFieldPresence(response.slice(), status, session, target);
                if (result == .infrastructure_failure) {
                    try std.testing.expectError(error.CanonicalStoreFailure, decoded.answer);
                    continue;
                }
                const answer = try decoded.answer;
                try std.testing.expectEqualStrings(@tagName(result), @tagName(answer.result));
                try std.testing.expectEqual(result != .conflict and replayed, answer.replayed);
                try std.testing.expectError(error.RequestBindingMismatch, protocol_reply.decodeMutationReply(.{ .status = status, .body = response.slice() }, "p9q8rs", target).answer);
                if (result == .accepted) switch (answer.result.accepted) {
                    .configure => |value| try std.testing.expectEqual(@as(u64, 13), value.revision),
                    .message => |value| try std.testing.expectEqual(@as(u64, 17), value.admission),
                    .session_stop => |value| {
                        try std.testing.expectEqual(@as(?u64, 19), value.turn);
                        try std.testing.expectEqual(@as(u64, 23), value.admission_cutoff);
                        try std.testing.expectEqual(.pending, value.completion);
                    },
                    .session_archive => |value| {
                        try std.testing.expect(value.archived);
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
            try response.render(render, .{ subject, idle });
            const answer = try protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, session, target).answer;
            try std.testing.expectEqual(@as(?u64, null), answer.result.accepted.session_stop.turn);
            try std.testing.expectEqual(.completed, answer.result.accepted.session_stop.completion);
            try expectMutationFieldPresence(response.slice(), 200, session, target);
        }
    }
}

test "initial Message reply binds its allocated Session and original input before exposing acceptance" {
    const protocol_reply = @import("protocol_reply.zig");
    const content: store_module.ContentReference = .{ .length = 9, .digest = protocol.contentDigest("seven\nµ!") };
    var allocated: protocol.Bounded(protocol.max_session_bytes) = .{};
    try allocated.set("k7m2qx");
    var response: protocol.ResponseBuffer = .{};
    try response.render(host_reply.renderMessageReply, .{ "", store_module.MessageReply{ .accepted = .{
        .replayed = true,
        .admission_id = 17,
        .content = content,
        .session = allocated,
    } } });
    const target: protocol_reply.MutationTarget = .{ .message = .{ .bytes = content.length, .digest = content.digest, .creates_session = true } };
    const reply = protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", target);
    try std.testing.expect(reply.isAccepted());
    try std.testing.expectEqualStrings("k7m2qx", reply.context.session.slice());
    try expectMutationFieldPresence(response.slice(), 200, "", target);
    // Ordinary addressed sends cannot adopt a different Session from a reply.
    try std.testing.expectError(error.RequestBindingMismatch, protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "111111", target).answer);
    var changed = target;
    changed.message.digest[0] ^= 1;
    try std.testing.expectError(error.RequestBindingMismatch, protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", changed).answer);
    response = .{};
    try allocated.set("BAD-ID");
    try response.render(host_reply.renderMessageReply, .{ "", store_module.MessageReply{ .accepted = .{
        .replayed = true,
        .admission_id = 17,
        .content = content,
        .session = allocated,
    } } });
    try std.testing.expectError(error.RequestBindingMismatch, protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", target).answer);
}

fn respondStatic(reply: *Reply, status: u16, kind: protocol.ErrorType, code: []const u8) void {
    reply.json(status, protocol.max_control_error_response_bytes, host_reply.renderStatic, .{ kind, code }) catch {};
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
        content: struct { reader: store_module.ContentReader = undefined, public: bool },
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

    fn holdDelivery(self: *Reply, hold: Hooks.Hold) !void {
        self.not_before_ns = std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds + @as(i128, hold.delay_ms) * std.time.ns_per_ms;
        if (hold.gate_path) |value| {
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
        const header = try std.fmt.bufPrint(&self.header, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{ status, httpReason(status), content_type, length });
        self.header_length = header.len;
        self.renew();
    }

    /// Renders one JSON body straight into heap storage reserved at the
    /// renderer's proven bound. The reservation writes none of its bytes, so
    /// only rendered pages become resident, and the body then shrinks to its
    /// exact length. Allocation or header failure leaves no body and the exchange
    /// retires unanswered: it cannot revoke an already saved semantic answer.
    /// Only the renderer's own failure, or outgrowing `max_bytes`, returns.
    fn json(self: *Reply, status: u16, max_bytes: usize, comptime render: anytype, args: anytype) !void {
        const body = std.Io.Writer.Allocating.initCapacity(self.allocator, max_bytes) catch return;
        return self.jsonInto(body, status, max_bytes, render, args);
    }

    /// As `json`, growing from empty: for a bound far above most replies.
    fn jsonGrowing(self: *Reply, status: u16, max_bytes: usize, comptime render: anytype, args: anytype) !void {
        return self.jsonInto(.init(self.allocator), status, max_bytes, render, args);
    }

    fn jsonInto(self: *Reply, initial: std.Io.Writer.Allocating, status: u16, max_bytes: usize, comptime render: anytype, args: anytype) !void {
        std.debug.assert(self.body == .none);
        var body = initial;
        defer body.deinit();
        try @call(.auto, render, .{protocol.JsonOut{ .writer = &body.writer }} ++ args);
        if (body.written().len > max_bytes) return error.BufferTooLarge;
        const bytes = body.toOwnedSlice() catch return;
        self.prepareHeader(status, "application/json", bytes.len) catch {
            self.allocator.free(bytes);
            return;
        };
        self.body = .{ .json = bytes };
        self.end = bytes.len;
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
    /// Opens the reader in this Reply. The location came from a Store open.
    fn setContent(self: *Reply, location: store_module.ContentLocation, start: u64, stream: bool, public: bool) !void {
        std.debug.assert(self.body == .none);
        self.body = .{ .content = .{ .public = public } };
        self.body.content.reader.open(location);
        self.offset = start;
        const length = if (stream) location.reference.length - start else @min(location.reference.length - start, protocol.content_window_bytes);
        self.end = start + length;
        if (public) {
            try self.fill();
            const header = try std.fmt.bufPrint(&self.header, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{ length, location.reference.length, self.end });
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
            wire_request.pollExchange(self.io, fd, std.posix.POLL.OUT, self.deadline()) catch |err|
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

/// A finished Request in its Ingress, as `receive` leaves it.
fn adoptRequestForTest(exchange: *Intake.Exchange, request: wire_request.Request) !void {
    const ingress = try exchange.host.allocator.create(wire_request.Ingress);
    ingress.init(exchange.host.allocator, .{
        .io = exchange.host.io,
        .content_length = 0,
        .scratch_path = "",
        .request_number = 0,
        .retained_scratch = &exchange.retained_scratch,
    });
    ingress.request = request;
    exchange.ingress = ingress;
    exchange.request = &ingress.request;
}

fn writeHttpUntil(io: std.Io, fd: std.posix.fd_t, status: u16, body: []const u8, deadline: ?i128) !void {
    var reply = Reply{ .io = io, .allocator = std.testing.allocator, .absolute_deadline = deadline };
    defer reply.deinit();
    try reply.json(status, 64 * 1024, protocol.JsonOut.append, .{body});
    try reply.deliver(fd);
}

fn writeAll(io: std.Io, fd: std.posix.fd_t, bytes: []const u8) !void {
    var reply = Reply{ .io = io, .allocator = std.testing.allocator };
    defer reply.deinit();
    reply.body = .{ .json = try std.testing.allocator.dupe(u8, bytes) };
    reply.end = bytes.len;
    try reply.deliver(fd);
}

test "Conversation stream native delivery reads each byte once and closes on failed handoff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    const expected = @as([8189]u8, @splat('x')) ++ @as([257 * "é中🙂\n\\\"/".len]u8, @bitCast(@as([257]["é中🙂\n\\\"/".len]u8, @splat("é中🙂\n\\\"/".*)))) ++ "tail";
    var command = try store_module.testingPublicProjection(&storage, &tmp, &.{
        .{ .encoded = &@as([8189]u8, @splat('x')), .decoded = &@as([8189]u8, @splat('x')) },
        .{ .encoded = @as([257 * "\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".len]u8, @bitCast(@as([257]["\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".len]u8, @splat("\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".*)))) ++ "tail", .decoded = @as([257 * "é中🙂\n\\\"/".len]u8, @bitCast(@as([257]["é中🙂\n\\\"/".len]u8, @splat("é中🙂\n\\\"/".*)))) ++ "tail" },
    });
    command.stream = true;
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const Peer = struct {
        fd: std.posix.fd_t,
        /// Readable once delivery has returned, when every byte it wrote is queued.
        returned: std.posix.fd_t,
        received: [expected.len + 320]u8 = undefined,
        used: usize = 0,
        failed: bool = false,

        /// Darwin can mark a Unix socket's end without waking a reader
        /// blocked on it: in #934, recv saw EOF while this peer's read slept
        /// 1200 s. So the peer never waits for EOF. It waits for bytes or
        /// for delivery to return, and reads only what is already queued.
        fn drain(self: *@This()) void {
            while (true) {
                var ready = [_]std.c.pollfd{
                    .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 },
                    .{ .fd = self.returned, .events = std.posix.POLL.IN, .revents = 0 },
                };
                const polled = std.c.poll(&ready, ready.len, -1);
                if (polled < 0) {
                    if (std.posix.errno(polled) == .INTR) continue;
                    self.failed = true;
                    return;
                }
                while (true) {
                    if (self.used == self.received.len) {
                        self.failed = true; // More bytes than the response.
                        return;
                    }
                    const count = std.c.recv(self.fd, self.received[self.used..].ptr, self.received.len - self.used, std.c.MSG.DONTWAIT);
                    if (count < 0) switch (std.posix.errno(count)) {
                        .INTR => continue,
                        .AGAIN => break,
                        else => {
                            self.failed = true;
                            return;
                        },
                    };
                    if (count == 0) return;
                    self.used += @intCast(count);
                }
                if (ready[1].revents != 0) return;
            }
        }
    };
    var returned: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&returned));
    defer _ = std.c.close(returned[0]);
    defer _ = std.c.close(returned[1]);
    var peer = Peer{ .fd = sockets[1], .returned = returned[0] };
    storage.testing_content_work = .{};
    {
        // Drain during delivery: the response exceeds Darwin's socket queue.
        // The parent owns both FDs and keeps peer storage alive until join,
        // including when delivery fails before the assertions below.
        const thread = try std.Thread.spawn(.{}, Peer.drain, .{&peer});
        defer {
            std.debug.assert(std.c.write(returned[1], "r", 1) == 1);
            thread.join();
        }
        try deliverConversationContent(&host, sockets[0], command);
    }
    try std.testing.expectEqual(@as(u64, expected.len), storage.testing_content_work.read.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), storage.testing_content_work.closes.load(.monotonic));
    try std.testing.expect(!storage.isFenced());
    try std.testing.expect(!peer.failed);
    const body_start = (std.mem.indexOf(u8, peer.received[0..peer.used], "\r\n\r\n") orelse return error.MissingHeaders) + 4;
    try std.testing.expectEqualStrings(expected, peer.received[body_start..peer.used]);
    // Failed delivery is not canonical corruption; the one reader still closes
    // without traversing the rest of the content or keeping caller storage.
    storage.testing_content_work = .{};
    try deliverConversationContent(&host, -1, command);
    try std.testing.expectEqual(@as(u64, protocol.content_window_bytes), storage.testing_content_work.read.load(.monotonic));
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
    const header = "POST /v1/host-info HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Length: 0\r\n\r\n";
    try writeAll(std.testing.io, sockets[1], header);
    Clock.fd = sockets[0];
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined };
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
    inline for (.{ "session_stop", "session_archive", "model_interruption", "permission_decision" }) |kind| {
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
            .hooks = .{ .phase_trace = true },
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
        try reply.json(200, protocol.max_response_bytes, protocol.JsonOut.append, .{"{\"accepted\":true}"});
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

test "message observation renders Host state binding live work and persistent recovery byte exactly" {
    const zero_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const full_digest = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const head = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"full\",\"since\":null,\"observation\":{";
    const accepted = head ++ "\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"s\",\"state\":\"";
    const input = ",\"input\":{\"type\":\"text\",\"bytes\":\"3\",\"sha256\":\"" ++ zero_digest ++ "\"}";
    const queue = ",\"queue\":{\"admission\":\"1\",\"admitted_at\":\"11\"}";
    const binding = ",\"binding\":{\"turn\":\"2\",\"operation\":\"3\",\"attempt\":\"4\"}";
    const recovery = ",\"recovery\":{\"unknown_outcomes\":[{\"action\":\"8\",\"operation\":\"3\",\"call\":\"1\",\"description\":null,\"at\":\"12\"}],\"more\":false}";
    const Expect = struct {
        fn rendered(observation: *const store_module.CommandObservation, expected: []const u8) !void {
            var response: protocol.CommandObservationBuffer = .{};
            try response.render(host_reply.renderFullCommandObservation, .{ "k", observation, null });
            try std.testing.expectEqualStrings(expected, response.slice());
        }
    };
    var rejected = store_module.CommandObservation{ .status = .rejected, .kind = .{ .message = null } };
    try rejected.target.set("s");
    try rejected.code.set("unknown_session");
    try Expect.rendered(&rejected, head ++ "\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"s\",\"code\":\"unknown_session\",\"state\":\"rejected\"}}");

    const content = store_module.ContentReference{ .length = 3, .digest = @splat(0) };
    const bound = store_module.AttemptBinding{ .turn_id = 2, .operation_id = 3, .attempt_ordinal = 4 };
    var observation = store_module.CommandObservation{ .status = .accepted, .kind = .{ .message = .{
        .content = content,
        .queue = .{ .admission_id = 1, .state = .queued },
        .admitted_at = 11,
        .work = .{ .state = .{ .pending = .{ .since = 10 } } },
    } } };
    try observation.target.set("s");
    const message = &observation.kind.message.?;
    try Expect.rendered(&observation, accepted ++ "queued\"" ++ input ++ queue ++ ",\"work\":{\"state\":{\"kind\":\"pending\",\"since\":\"10\"},\"first_action\":null}}}");
    message.work = .{ .state = .{ .approval = .{ .since = 10 } }, .first_action = 7 };
    try Expect.rendered(&observation, accepted ++ "waiting_for_permission\"" ++ input ++ queue ++ ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"10\"},\"first_action\":\"7\"}}}");
    message.queue.?.state = .{ .processing = bound };
    message.work = .{ .state = .{ .working = .{ .since = 10 } } };
    message.recovery.count = 1;
    message.recovery.calls[0] = .{ .action_id = 8, .operation_id = 3, .call = 1, .at = 12 };
    try Expect.rendered(&observation, accepted ++ "processing\"" ++ input ++ queue ++ binding ++ ",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"10\"},\"first_action\":null}" ++ recovery ++ "}}");
    message.queue.?.state = .{ .completed = .{ .binding = bound, .answer = .{ .length = 6, .digest = @splat(0xff) } } };
    // Even inconsistent synthetic live work must never leak after a result.
    try Expect.rendered(&observation, accepted ++ "completed\"" ++ input ++ queue ++ binding ++ ",\"result\":{\"status\":\"completed\",\"text\":{\"type\":\"text\",\"bytes\":\"6\",\"sha256\":\"" ++ full_digest ++ "\"}}" ++ recovery ++ "}}");
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set("provider_http_422");
    message.queue.?.state = .{ .failed = .{ .binding = bound, .code = code } };
    try Expect.rendered(&observation, accepted ++ "failed\"" ++ input ++ queue ++ binding ++ ",\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"}" ++ recovery ++ "}}");
    try code.set("cancelled");
    message.queue.?.state = .{ .cancelled = .{ .binding = bound, .code = code } };
    try Expect.rendered(&observation, accepted ++ "cancelled\"" ++ input ++ queue ++ binding ++ ",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}" ++ recovery ++ "}}");
    message.queue.?.state = .{ .excluded = .{ .code = code } };
    message.recovery.count = 0;
    try Expect.rendered(&observation, accepted ++ "cancelled\"" ++ input ++ queue ++ ",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}}}");
}

test "activity page both unchanged tiers render byte exactly with independent reservations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    storage.instance = @splat(0xab);
    var configure = try store_module.testingCompleteConfiguration("page-tier-create", "", root, "model-a");
    const session = (try storage.configure(&configure, .{})).accepted.session;
    var request: protocol.ActivityPage = .{};
    try request.session.set(session.slice());
    const page = try std.testing.allocator.create(protocol.ActivityFacts);
    defer std.testing.allocator.destroy(page);
    try storage.activityPage(&request, page);
    try std.testing.expect(!page.not_modified);
    try std.testing.expectEqual(activity_reply.max_page_bytes, host_reply.activityPageBytes(page));
    request.position = page.end;
    request.since = page.token.?;
    for (0..2) |tier| {
        if (tier == 1) {
            try configure.key.set("page-tier-sibling");
            try std.testing.expect(try storage.configure(&configure, .{}) == .accepted);
        }
        try storage.activityPage(&request, page);
        try std.testing.expect(page.not_modified);
        var bytes: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try host_reply.renderActivityPage(.{ .writer = &writer }, page);
        var expected: [256]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.{d}.{s}\"}}", .{ storage.commitGeneration(), session.slice() }), writer.buffered());
        try std.testing.expectEqual(protocol.shapeBytes(activity_reply.page_reply.unchanged), host_reply.activityPageBytes(page));
        try std.testing.expect(host_reply.activityPageBytes(page) < activity_reply.max_page_bytes);
    }
}

test "command observation full and both unchanged tiers render byte exactly with independent reservations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    storage.instance = @splat(0xab);
    var configure = try store_module.testingCompleteConfiguration("tier-create", "", root, "model-a");
    const configured = try storage.configure(&configure, .{});
    try std.testing.expect(configured == .accepted);
    const session = configured.accepted.session;
    var observed: store_module.Observed = undefined;
    try storage.observeCommand("tier-create", null, &observed);
    const first = observed.full.token.?;
    const Expect = struct {
        fn full(value: *const store_module.Observed, id: []const u8, generation: u64) !void {
            var response: protocol.CommandObservationBuffer = .{};
            try response.render(host_reply.renderCommandObservation, .{ "tier-create", value });
            var expected: [1024]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"tier-create\",\"delta\":\"full\",\"since\":\"abababababababababababababababab.{d}.{s}\",\"observation\":{{\"status\":\"accepted\",\"kind\":\"configure\",\"target\":\"{s}\",\"revision\":\"1\",\"created\":true}}}}", .{ generation, id, id }), response.slice());
            try std.testing.expectEqual(protocol.command_observation_reply.maxBytes(.configure), host_reply.commandObservationBytes(value));
        }
        fn unchanged(value: *const store_module.Observed, id: []const u8, generation: u64) !void {
            var response: protocol.CommandObservationBuffer = .{};
            try response.render(host_reply.renderCommandObservation, .{ "tier-create", value });
            var expected: [256]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"tier-create\",\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.{d}.{s}\"}}", .{ generation, id }), response.slice());
            try std.testing.expectEqual(protocol.shapeBytes(protocol.command_observation_reply.not_modified), host_reply.commandObservationBytes(value));
            try std.testing.expect(host_reply.commandObservationBytes(value) < protocol.command_observation_reply.max_bytes);
        }
    };
    try Expect.full(&observed, session.slice(), first.generation);
    // Tier 1 returns exactly the generation already seen, without a holder.
    try storage.observeCommand("tier-create", first, &observed);
    try Expect.unchanged(&observed, session.slice(), first.generation);
    // Tier 2 advances over a sibling's commit, without a read access.
    try configure.key.set("tier-sibling");
    try std.testing.expect(try storage.configure(&configure, .{}) == .accepted);
    try storage.observeCommand("tier-create", first, &observed);
    try std.testing.expect(observed.not_modified.generation > first.generation);
    try Expect.unchanged(&observed, session.slice(), storage.commitGeneration());
    const sibling = observed.not_modified;
    var update: wire_request.ConfigureCommand = .{};
    try update.key.set("tier-update");
    try update.session.set(session.slice());
    update.configuration.label.state = .value;
    try update.configuration.label.value.set("changed");
    try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
    try storage.observeCommand("tier-create", sibling, &observed);
    try Expect.full(&observed, session.slice(), storage.commitGeneration());
    try storage.observeCommand("absent", null, &observed);
    var absent: protocol.CommandObservationBuffer = .{};
    try absent.render(host_reply.renderCommandObservation, .{ "absent", &observed });
    try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"absent\",\"delta\":\"full\",\"since\":null,\"observation\":{\"status\":\"absent\"}}", absent.slice());
    try std.testing.expectEqual(protocol.shapeBytes(protocol.command_observation_reply.absent), host_reply.commandObservationBytes(&observed));
}

test "Message observation work and recovery fit the unchanged resident response bound" {
    const max = std.math.maxInt(u64);
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set(&@as([protocol.max_tool_description_bytes]u8, @splat(1)));
    var bash_description: protocol.Bounded(protocol.session_work.max_description_bytes) = .{};
    try bash_description.set(&@as([protocol.session_work.max_description_bytes]u8, @splat(1)));
    var observation = store_module.CommandObservation{ .status = .accepted, .kind = .{ .message = .{
        .content = .{ .length = max, .digest = @splat(0xff) },
        .queue = .{ .admission_id = max, .state = .{ .processing = .{ .turn_id = max, .operation_id = max, .attempt_ordinal = max } } },
        .admitted_at = max,
        .work = .{ .state = .{ .bash = .{ .since = max, .call = max, .description = bash_description, .running = max, .approvals = max } }, .first_action = max },
    } } };
    try observation.target.set(&escaped_session);
    observation.kind.message.?.recovery.count = protocol.message_recovery_limit;
    for (&observation.kind.message.?.recovery.calls) |*call| call.* = .{ .action_id = max, .operation_id = max, .call = max, .description = description, .at = max };
    var response: protocol.CommandObservationBuffer = .{};
    try response.render(host_reply.renderFullCommandObservation, .{ &escaped_key, &observation, &@as([change_ring.SessionToken.max_bytes]u8, @splat(1)) });
    try std.testing.expectEqual(protocol.command_observation_reply.maxBytes(.message) - protocol.shapeBytes(protocol.command_observation_reply.code), response.len);
    // The existing response owner is sized by host-info's escaped Store path,
    // not these added per-observation facts; no resident pool grows.
    try std.testing.expectEqual(protocol.max_host_info_response_bytes, protocol.max_response_bytes);
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
            try response.render(host_reply.renderSessionStopReply, .{ command.session.slice(), result });
            try std.testing.expectEqual(expected, response.len);
        }

        fn expectInterruption(
            command: *const protocol.ModelInterruptionCommand,
            result: store_module.ModelInterruptionReply,
            expected: usize,
        ) !void {
            var response: protocol.ResponseBuffer = .{};
            try response.render(host_reply.renderModelInterruptionReply, .{ store_module.ModelInterruptionTarget{ .session = command.session, .turn_id = command.turn_id, .operation_id = command.operation_id }, result });
            try std.testing.expectEqual(expected, response.len);
        }

        fn expectObservation(
            key: []const u8,
            observation: store_module.CommandObservation,
            expected: usize,
        ) !void {
            var response: protocol.CommandObservationBuffer = .{};
            try response.render(host_reply.renderFullCommandObservation, .{ key, &observation, &@as([change_ring.SessionToken.max_bytes]u8, @splat(1)) });
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
    try pending_response.render(host_reply.renderSessionStopReply, .{ stop_command.session.slice(), store_module.SessionStopReply{ .accepted = .{
        .replayed = false,
        .selection = .{
            .selected_turn_id = std.math.maxInt(u64),
            .admission_cutoff = std.math.maxInt(u64),
        },
        .completion = .pending,
    } } });
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
    const canonical_error = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}";
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
        .kind = .{ .session_stop = .{
            .selection = .{
                .selected_turn_id = std.math.maxInt(u64),
                .admission_cutoff = std.math.maxInt(u64),
            },
            .completion = .completed,
        } },
    };
    try stop_accepted.target.set(&escaped_session);
    try Cases.expectObservation(&escaped_key, stop_accepted, observationBytes(.session_stop, .{observation_shapes.session_stop}));

    var stop_rejected = store_module.CommandObservation{ .status = .rejected, .kind = .{ .session_stop = null } };
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
        .kind = .{ .model_interruption = target },
    };
    try interruption_accepted.target.set(&escaped_session);
    try Cases.expectObservation(
        &escaped_key,
        interruption_accepted,
        observationBytes(.model_interruption, .{observation_shapes.model_interruption}),
    );

    var interruption_rejected = store_module.CommandObservation{
        .status = .rejected,
        .kind = .{ .model_interruption = target },
    };
    try interruption_rejected.target.set(&escaped_session);
    try interruption_rejected.code.set(&escaped_code);
    try Cases.expectObservation(
        &escaped_key,
        interruption_rejected,
        observationBytes(.model_interruption, .{ observation_shapes.code, observation_shapes.model_interruption }),
    );
}

test "an unchanged listing echoes its token with no rows, as a client reads it" {
    const protocol_reply = @import("protocol_reply.zig");
    const io = std.testing.io;
    const since = try protocol.SinceToken.parse("abababababababababababababababab.42");
    var response: protocol.ResponseBuffer = .{};
    try response.render(host_reply.renderSessionsNotModified, .{since});
    try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"session_list\",\"sessions\":[],\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42\",\"next\":null}", response.slice());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, response.slice(), 0);
    const page = try protocol_reply.SessionListPage.read(io, file, response.len, null, .{ .since = since });
    try std.testing.expectEqual(protocol.ListDelta.not_modified, page.delta);
    try std.testing.expectEqual(@as(usize, 0), page.count);
}

test "failed send without a canonical target writes explicit null within activity bounds" {
    var key: protocol.Bounded(protocol.max_key_bytes) = .{};
    try key.set("refused-creation");
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set("unsupported_reasoning_effort");
    const item: protocol.ActivityItem = .{
        .position = 7,
        .ordinal = 0,
        .at = 1,
        .value = .{ .send_failed = .{ .key = key, .target = null, .code = code } },
    };
    var buffer: [activity_reply.ItemJson.max_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try (activity_reply.ItemJson{ .item = &item }).writeJson(&writer);
    try std.testing.expectEqualStrings(
        "{\"position\":\"7\",\"ordinal\":\"0\",\"at\":\"1\",\"value\":{\"send_failed\":{\"key\":\"refused-creation\",\"target\":null,\"code\":\"unsupported_reasoning_effort\"}}}",
        writer.buffered(),
    );
}

test "retired reserved exchanges cannot block their successors while workers are occupied" {
    for (std.enums.values(Route)) |route| {
        if (!route.isControl() and route != .host_info) continue;
        for ([_]Intake.Exchange.State{ .retired, .closed }) |retired_state| {
            var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .intake_capacity = descriptor_capacity.minimum_intake };
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
                .host_pause => "control/host-pause",
                .session_stop => "control/session-stop",
                .session_archive => "control/session-archive",
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
                var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined, .intake_capacity = descriptor_capacity.minimum_intake };
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
                    if (body) try writeAll(host.io, sockets[1], "Content-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Length: 2\r\n\r\n{");
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
            var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined };
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
        var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined, .intake_capacity = descriptor_capacity.minimum_intake };
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
        const budget: ScratchBudget = .{ .used = &host.scratch_used, .limit = 9000 };
        switch (custody) {
            .ingress => {
                const ingress = try host.allocator.create(wire_request.Ingress);
                ingress.init(host.allocator, .{
                    .io = host.io,
                    .content_length = 4096,
                    .scratch_path = root,
                    .request_number = 7,
                    .retained_scratch = &retained.retained_scratch,
                    .scratch_budget = budget,
                    .expected_kind = .message,
                });
                retained.ingress = ingress;
                // Seal the content file, but leave request framing incomplete.
                try ingress.feed("{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"abc\"");
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
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined };
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
    try adoptRequestForTest(&exchange, .{ .configure = .{} });
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
        try adoptRequestForTest(&retry, .{ .host_stop = .{ .store = lease.paths.store } });
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
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined };
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

test "launch frame fenced MySQL shutdown is decided once at the return boundary without clients" {
    const Probe = struct {
        var storage: *store_module.Store = undefined;
        var fence_on_delete: bool = false;
        var output: [1024]u8 = undefined;
        var used: usize = 0;

        fn delete(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8) std.Io.Dir.DeleteFileError!void {
            // Listener retirement is after the old loop-top fence check.
            // Emulate execution fencing in that window, without a thread.
            if (fence_on_delete) storage.fenced.store(true, .release);
            return std.testing.io.vtable.dirDeleteFile(userdata, dir, path);
        }

        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming and operation.file_write_streaming.file.handle == 1) {
                const write = operation.file_write_streaming;
                var out = std.Io.Writer.fixed(output[used..]);
                out.writeAll(write.header) catch return .{ .file_write_streaming = error.NoSpaceLeft };
                for (write.data, 0..) |part, index| {
                    const repeats = if (index == write.data.len - 1) write.splat else 1;
                    for (0..repeats) |_| out.writeAll(part) catch return .{ .file_write_streaming = error.NoSpaceLeft };
                }
                used += out.buffered().len;
                return .{ .file_write_streaming = out.buffered().len };
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/host.sock", .{root[0..root_len]});
    var vtable = std.testing.io.vtable.*;
    vtable.dirDeleteFile = Probe.delete;
    vtable.operate = Probe.operate;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    for ([_]struct { mysql: bool, launched: bool, early: bool, late: bool }{
        .{ .mysql = true, .launched = true, .early = false, .late = true },
        .{ .mysql = true, .launched = true, .early = true, .late = false },
        .{ .mysql = true, .launched = true, .early = false, .late = false },
        .{ .mysql = true, .launched = false, .early = false, .late = true },
        .{ .mysql = false, .launched = true, .early = false, .late = true },
    }) |case| {
        var storage: store_module.Store = .{ .io = io, .engine = undefined, .selector = .{}, .changes = undefined };
        // No engine operation occurs: only its tag and atomic fence are read.
        storage.engine = if (case.mysql) .{ .mysql = undefined } else .{ .sqlite = undefined };
        storage.fenced.store(case.early, .release);
        Probe.storage = &storage;
        Probe.fence_on_delete = case.late;
        Probe.used = 0;
        var lease: platform.StoreLease = undefined;
        lease.paths = .{};
        try lease.paths.socket.set(path);
        var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage, .phase = .init(.stopping) };
        var intake: Intake = .{ .host = &host, .launched = case.launched, .deadline_armed = true };
        // Reuse the real intake owner, with idle workers but no worker threads.
        for (&intake.workers) |*worker| worker.* = .{ .owner = &intake };
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &intake.wake));
        try setNonblocking(intake.wake[0]);
        defer intake.deinit();
        var stdin: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&stdin));
        defer _ = std.c.close(stdin[0]);
        _ = std.c.close(stdin[1]);
        intake.stdin = stdin[0]; // EOF makes poll ready without a sleep.
        const address = try std.Io.net.UnixAddress.init(path);
        var listener = try address.listen(io, .{ .kernel_backlog = 8 });
        var open = true;
        var owned = true;
        defer if (open) listener.deinit(io);
        const outcome = finishServing(io, &storage, case.launched, intake.run(&listener, &open, &owned));
        const fenced = case.mysql and case.launched and (case.early or case.late);
        try std.testing.expectError(if (fenced) error.StoreFenced else error.EffectAwareShutdown, outcome);
        try std.testing.expectEqualStrings(if (fenced)
            "{\"rui_start_error\":{\"code\":\"store_fenced\",\"message\":\"the MySQL Store lost ownership or its connection; restart the Host\"}}\n"
        else
            "", Probe.output[0..Probe.used]);
        try std.testing.expectEqual(@as(usize, 0), intake.exchanges.items.len);
    }
}

test "blocked ingress file work leaves controls discovery and shutdown responsive" {
    const Probe = struct {
        const Phase = enum { write, cleanup };
        var entered = std.atomic.Value(bool).init(false);
        var released = std.atomic.Value(bool).init(false);
        var phase: Phase = .write;

        fn hold() void {
            entered.store(true, .release);
            test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(30)), &released, test_poll.isSet) catch
                @panic("held ingress write was never released");
        }

        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (phase == .write and operation == .file_write_streaming) hold();
            return std.testing.io.vtable.operate(userdata, operation);
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
            const message = std.mem.eql(u8, route, "/v1/message");
            const bytes = try std.fmt.bufPrint(&header, "POST {s} HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n{s}{s}Content-Length: {d}\r\n\r\n", .{ route, if (identity) "X-Rui-Host-Instance: 00000000000000000000000000000000\r\n" else "", if (message) "X-Rui-Environment-Bytes: 0\r\n" else "", body.len });
            try writeAll(std.testing.io, fd, bytes);
            if (phase == .cleanup and message) {
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
    const message_template = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"" ++
        @as([4097]u8, @splat('x')) ++ "\"}}";
    for (std.enums.values(Probe.Phase)) |phase| {
        Probe.phase = phase;
        Probe.entered.store(false, .release);
        Probe.released.store(false, .release);
        var vtable = std.testing.io.vtable.*;
        vtable.operate = Probe.operate;
        vtable.dirDeleteFile = Probe.delete;
        const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
        var lease: platform.StoreLease = undefined;
        lease.paths = .{};
        try lease.paths.store.set("s");
        try lease.paths.scratch.set(root);
        try lease.paths.socket.set(socket_path);
        var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
        const database = try std.fmt.bufPrint(&database_buffer, "{s}/{s}.sqlite", .{ root, @tagName(phase) });
        var storage: store_module.Store = undefined;
        try storage.open(std.testing.io, database, root);
        defer storage.close() catch unreachable;
        var configure: wire_request.ConfigureCommand = .{};
        try configure.key.set("config");
        configure.configuration.workspace.state = .value;
        try configure.configuration.workspace.value.set(root);
        configure.configuration.provider.state = .value;
        try configure.configuration.provider.value.set("codex");
        configure.configuration.model.state = .value;
        try configure.configuration.model.value.set("model-a");
        configure.configuration.tools = try .of(&.{ "bash", "web_search" });
        configure.configuration.permission_mode.state = .value;
        try configure.configuration.permission_mode.value.set("bypass");
        configure.configuration.compaction_trigger.state = .value;
        try configure.configuration.compaction_trigger.value.set("115200");
        configure.configuration.reasoning_effort.state = .explicit_null;
        const configured = try storage.configure(&configure, .{});
        try std.testing.expect(configured == .accepted);
        const session = configured.accepted.session.slice();
        const message = try std.mem.replaceOwned(u8, std.testing.allocator, message_template, "peer", session);
        defer std.testing.allocator.free(message);
        var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage, .instance = @splat(0) };
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
            "POST /v1/control/host-stop HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Length: 1024\r\n\r\n{",
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
        const deadline = test_poll.after(std.testing.io, .fromSeconds(3));
        try test_poll.waitUntil(std.testing.io, deadline, &Probe.entered, test_poll.isSet);
        const sibling = try address.connect(std.testing.io);
        defer sibling.socket.close(std.testing.io);
        try Probe.send(sibling.socket.handle, "/v1/message", message, false);
        // Classification occurs in the socket pass before its worker handoff
        // and before that pass can read a subsequently issued control.
        const Uploads = struct {
            host: *const Host,
            expected: u64,

            fn classified(self: @This()) bool {
                return self.host.request_counter.load(.acquire) >= self.expected;
            }
        };
        try test_poll.waitUntil(std.testing.io, deadline, Uploads{ .host = &host, .expected = before_uploads + 2 }, Uploads.classified);
        try std.testing.expectEqual(before_uploads + 2, host.request_counter.load(.acquire));
        for ([_]struct { route: []const u8, body: []const u8, key: []const u8, kind: protocol.CommandKind, status: @FieldType(store_module.CommandObservation, "status") }{
            .{ .route = "/v1/control/session-stop", .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"session_stop\",\"store\":\"s\",\"key\":\"stop\",\"session\":\"peer\"}", .key = "stop", .kind = .session_stop, .status = .accepted },
            .{ .route = "/v1/control/session-archive", .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"session_archive\",\"store\":\"s\",\"key\":\"archive\",\"session\":\"peer\",\"archived\":true}", .key = "archive", .kind = .session_archive, .status = .accepted },
            .{ .route = "/v1/control/session-archive", .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"session_archive\",\"store\":\"s\",\"key\":\"restore\",\"session\":\"peer\",\"archived\":false}", .key = "restore", .kind = .session_archive, .status = .accepted },
            .{ .route = "/v1/control/model-interruption", .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"model_interruption\",\"store\":\"s\",\"key\":\"interrupt\",\"target\":{\"session\":\"peer\",\"turn\":\"1\",\"operation\":\"1\"}}", .key = "interrupt", .kind = .model_interruption, .status = .rejected },
            .{ .route = "/v1/control/permission-decision", .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"permission_decision\",\"store\":\"s\",\"key\":\"decision\",\"session\":\"peer\",\"action\":\"1\",\"decision\":\"deny\"}", .key = "decision", .kind = .permission_decision, .status = .rejected },
        }) |control| {
            const peer = try address.connect(std.testing.io);
            defer peer.socket.close(std.testing.io);
            const body = try std.mem.replaceOwned(u8, std.testing.allocator, control.body, "peer", session);
            defer std.testing.allocator.free(body);
            try Probe.send(peer.socket.handle, control.route, body, false);
            try Probe.response(peer.socket.handle);
            var saved: store_module.Observed = undefined;
            try storage.observeCommand(control.key, null, &saved);
            try std.testing.expectEqual(control.kind, std.meta.activeTag(saved.full.observation.kind));
            try std.testing.expectEqual(control.status, saved.full.observation.status);
            try std.testing.expect(!Probe.released.load(.acquire));
        }
        const discovery = try address.connect(std.testing.io);
        defer discovery.socket.close(std.testing.io);
        try Probe.send(discovery.socket.handle, "/v1/host-info", "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"host_info\",\"store\":\"s\"}", false);
        try Probe.response(discovery.socket.handle);
        const stop = try address.connect(std.testing.io);
        defer stop.socket.close(std.testing.io);
        try Probe.send(stop.socket.handle, "/v1/control/host-stop", "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"host_stop\",\"store\":\"s\"}", true);
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
    var host = Host{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .allocator = std.testing.allocator, .lease = &lease, .store = undefined };
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
                const body = try std.fmt.bufPrint(&body_buffer, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"{s}\",\"store\":\"s\"}}", .{@tagName(route)});
                var header_buffer: [256]u8 = undefined;
                const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/{s} HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Length: {d}\r\n\r\n", .{ if (route == .host_stop) "control/host-stop" else "host-info", body.len });
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
    var host = Host{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable }, .allocator = std.testing.allocator, .lease = &lease, .store = undefined };
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[1]);
    try setNonblocking(sockets[0]);
    const payload = @as([4097]u8, @splat('x'));
    const body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"" ++ payload ++ "\"}}";
    var header_buffer: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/message HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nX-Rui-Environment-Bytes: 0\r\nContent-Length: {d}\r\n\r\n", .{body.len});
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

test "a Message's environment header and entries are checked before admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    // No Store: a check that reached admission would fault.
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined };
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    const request = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"x\"}}";
    const Case = struct { route: []const u8 = "message", header: []const u8, entries: []const u8 = "", record: bool = true, result: anyerror!?[]const u8 };
    for ([_]Case{
        .{ .header = "", .result = error.EnvironmentRequired },
        .{ .header = "X-Rui-Environment-Bytes: 65537\r\n", .result = error.EnvironmentTooLarge },
        .{ .header = "X-Rui-Environment-Bytes: 999999\r\n", .result = error.EnvironmentTooLarge },
        .{ .header = "X-Rui-Environment-Bytes: -1\r\n", .result = error.InvalidEnvironment },
        .{ .header = "X-Rui-Environment-Bytes: 0\r\nX-Rui-Environment-Bytes: 0\r\n", .result = error.InvalidEnvironment },
        .{ .header = "X-Rui-Environment-Bytes: 3\r\n", .entries = "A=1", .result = error.InvalidEnvironment },
        .{ .header = "X-Rui-Environment-Bytes: 8\r\n", .entries = "A=1\x00A=2\x00", .result = error.InvalidEnvironment },
        .{ .route = "configure", .header = "X-Rui-Environment-Bytes: 0\r\n", .result = error.InvalidEnvironment },
        // A record is never empty, so an environment is never the whole body.
        .{ .header = "X-Rui-Environment-Bytes: 4\r\n", .entries = "A=1\x00", .record = false, .result = error.InvalidEnvironment },
        .{ .header = "X-Rui-Environment-Bytes: 0\r\n", .record = false, .result = error.InvalidEnvironment },
        .{ .header = "X-Rui-Environment-Bytes: 0\r\n", .result = "" },
        .{ .header = "X-Rui-Environment-Bytes: 14\r\n", .entries = "A=1\x00RUI_X=2\x00C=", .result = error.InvalidEnvironment },
        .{ .header = "X-Rui-Environment-Bytes: 14\r\n", .entries = "A=1\x00RUI_X=2\x00C\x00", .result = error.InvalidEnvironment },
        .{ .header = "X-Rui-Environment-Bytes: 16\r\n", .entries = "A=1\x00RUI_X=2\x00C=3\x00", .result = "A=1\x00C=3\x00" },
    }) |case| {
        var sockets: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
        defer _ = std.c.close(sockets[1]);
        try setNonblocking(sockets[0]);
        var header_buffer: [256]u8 = undefined;
        const record: []const u8 = if (case.record) request else "";
        const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/{s} HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n{s}Content-Length: {d}\r\n\r\n", .{ case.route, case.header, case.entries.len + record.len });
        try writeAll(std.testing.io, sockets[1], header);
        try writeAll(std.testing.io, sockets[1], case.entries);
        try writeAll(std.testing.io, sockets[1], record);
        const exchange = try std.testing.allocator.create(Intake.Exchange);
        exchange.* = .{ .owner = undefined, .host = &host, .fd = sockets[0], .accepted_at_ns = 0, .deadline = std.math.maxInt(i128) };
        defer std.debug.assert(exchange.destroy());
        const read = exchange.read();
        if (case.result) |expected| {
            try read;
            try std.testing.expectEqualStrings(expected.?, exchange.environment.?.value().?);
            // The request's own bytes follow, unchanged.
            try std.testing.expectEqualStrings(request, exchange.input.items);
        } else |expected| try std.testing.expectError(expected, read);
    }
}

test "only a fresh Message changes its Session's environment; a replay or a rejection leaves the register as it was" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    try lease.paths.store.set("s");
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    var configure: wire_request.ConfigureCommand = .{};
    try configure.key.set("config");
    configure.configuration.workspace.state = .value;
    try configure.configuration.workspace.value.set(root);
    configure.configuration.provider.state = .value;
    try configure.configuration.provider.value.set("codex");
    configure.configuration.model.state = .value;
    try configure.configuration.model.value.set("model-a");
    configure.configuration.tools = try .of(&.{ "bash", "web_search" });
    configure.configuration.permission_mode.state = .value;
    try configure.configuration.permission_mode.value.set("bypass");
    configure.configuration.compaction_trigger.state = .value;
    try configure.configuration.compaction_trigger.value.set("115200");
    configure.configuration.reasoning_effort.state = .explicit_null;
    const configured = try storage.configure(&configure, .{});
    try std.testing.expect(configured == .accepted);
    const session = configured.accepted.session.slice();
    var environments: SessionEnvironments = undefined;
    try environments.init(std.testing.io, std.testing.allocator);
    defer environments.deinit();
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage, .environments = &environments };
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    const Send = struct {
        fn message(owner: *Host, key: []const u8, to: []const u8, entries: []const u8) !void {
            var request_buffer: [512]u8 = undefined;
            const request = try std.fmt.bufPrint(&request_buffer, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"{s}\",\"session\":\"{s}\",\"sender\":null,\"sender_handle\":null,\"text\":{{\"state\":\"value\",\"value\":\"x\"}}}}", .{ key, to });
            var sockets: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
            defer _ = std.c.close(sockets[1]);
            try setNonblocking(sockets[0]);
            var header_buffer: [256]u8 = undefined;
            try writeAll(std.testing.io, sockets[1], try std.fmt.bufPrint(&header_buffer, "POST /v1/message HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nX-Rui-Environment-Bytes: {d}\r\nContent-Length: {d}\r\n\r\n", .{ entries.len, entries.len + request.len }));
            try writeAll(std.testing.io, sockets[1], entries);
            try writeAll(std.testing.io, sockets[1], request);
            const exchange = try std.testing.allocator.create(Intake.Exchange);
            exchange.* = .{ .owner = undefined, .host = owner, .fd = sockets[0], .accepted_at_ns = 0, .deadline = std.math.maxInt(i128) };
            defer std.debug.assert(exchange.destroy());
            try exchange.read();
            try std.testing.expectEqual(.ready, exchange.state);
            exchange.state = try exchange.work();
            try std.testing.expectEqual(.ready, exchange.state);
            try exchange.prepare();
            // Admission spent the environment.
            try std.testing.expectEqual(null, exchange.environment);
        }
    };
    const expectCopy = struct {
        fn of(table: *SessionEnvironments, from: []const u8, expected: ?[]const u8) !void {
            const copied = try table.copy(from, std.testing.allocator);
            defer if (copied) |bytes| std.testing.allocator.free(bytes);
            if (expected) |bytes| try std.testing.expectEqualStrings(bytes, copied.?) else try std.testing.expectEqual(null, copied);
        }
    }.of;
    try Send.message(&host, "first", session, "A=1\x00");
    try expectCopy(&environments, session, "A=1\x00");
    const held = .{ environments.len, environments.value_count, environments.value_bytes };
    // The same request again, from another terminal: a replay installs nothing.
    try Send.message(&host, "first", session, "B=2\x00");
    try expectCopy(&environments, session, "A=1\x00");
    // A Message the Store rejects installs nothing, for its Session or another.
    try Send.message(&host, "rejected", "zzzzzz", "C=3\x00");
    try expectCopy(&environments, "zzzzzz", null);
    try expectCopy(&environments, session, "A=1\x00");
    try std.testing.expectEqual(held, .{ environments.len, environments.value_count, environments.value_bytes });
    // A fresh Message does.
    try Send.message(&host, "second", session, "D=4\x00");
    try expectCopy(&environments, session, "D=4\x00");
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
    };
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"";
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
        const ingress = try std.testing.allocator.create(wire_request.Ingress);
        ingress.init(std.testing.allocator, .{
            .io = io,
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

test "MySQL Host readiness reports doublewrite OFF while SQLite stays unchanged" {
    const protocol_reply = @import("protocol_reply.zig");
    var response: protocol.ResponseBuffer = .{};
    const id = "0123456789abcdef0123456789abcdef";
    var info: host_reply.HostInfo = .{ .store = id, .instance = @splat(1), .active_capacity = 2, .intake_capacity = 100, .descriptor_soft_limit = 1024, .started_at = 1792918800, .custody_occupied = 0, .paused = false, .routes = protocol.routesAll(.unserved), .doublewrite = "OFF" };
    try response.render(host_reply.renderHostInfo, .{info});
    const status = try protocol_reply.parseHostInfo(response.slice(), id);
    try std.testing.expectEqualStrings("OFF", status.ready.innodb_doublewrite.?.slice());
    response.len = 0;
    info.store = "/sqlite";
    info.doublewrite = null;
    try response.render(host_reply.renderHostInfo, .{info});
    try std.testing.expect(std.mem.indexOf(u8, response.slice(), "innodb_doublewrite") == null);
    // The common public bound includes the optional diagnostic even beside
    // a maximum-width selector; SQLite omits that entire fragment.
    const shape = protocol.host_info_reply;
    try std.testing.expectEqual(protocol.shapeBytes(shape.head) + protocol.shapeBytes(shape.doublewrite) + protocol.shapeBytes(shape.tail), protocol.max_host_info_response_bytes);
}

test "MCP socket capacity is reserved beside model and Bash descriptors" {
    var requirement = try descriptor_capacity.calculate(3, 2, 10, 3, .requests, false, os.tag);
    const before = requirement;
    try reserveMcpDescriptors(&requirement);
    try std.testing.expectEqual(before.execution + @import("server_mcp.zig").capacity, requirement.execution);
    try std.testing.expectEqual(before.total + @import("server_mcp.zig").capacity, requirement.total);
    try std.testing.expectEqual(before.clients, requirement.clients);
    try std.testing.expectEqual(before.inherited, requirement.inherited);
}

test "presets seed configure before Store validation and idempotency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"model":"gpt-6.1-sol","effort":"low","compactAt":10000,"tools":[],"permissionMode":"ask","provider":"openai","instructions":"Preset instructions","outputSchema":{"type":"object"},"label":"Preset label"}
    , .{})).object;
    const presets = [_]core_tools.Preset{.{ .name = "review", .spec = spec }};
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage, .presets = &presets };
    const create = try arena.create(wire_request.ConfigureCommand);
    create.* = .{ .preset = .{} };
    try create.preset.?.set("review");
    try create.key.set("preset-create");
    // Native API intent survives preset resolution: reload cannot create a
    // Session, and its saved refusal cannot become a plain preset creation.
    const reload = try arena.create(wire_request.ConfigureCommand);
    reload.* = .{ .preset = create.preset, .reload_skills = true };
    try reload.key.set("skills-reload-preset-empty");
    const reload_refused = try submitConfigure(&host, reload);
    try std.testing.expect(reload_refused == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_session, reload_refused.rejected.code);
    try std.testing.expect((try submitConfigure(&host, reload)).rejected.replayed);
    reload.reload_skills = false;
    try std.testing.expect(try submitConfigure(&host, reload) == .conflict);
    const first = try submitConfigure(&host, create);
    try std.testing.expect(first == .accepted);
    try std.testing.expect(!first.accepted.replayed);
    const session = first.accepted.session;
    var observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqualStrings("gpt-6.1-sol", observed.model.slice());
    try std.testing.expectEqual(@as(?u64, 10000), observed.compaction_trigger_override);
    try std.testing.expectEqual(protocol.ReasoningEffort.low, observed.reasoning_effort_override.?);
    try std.testing.expectEqualStrings("ask", observed.permission_mode.slice());
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("Preset instructions"), &observed.instructions.digest);
    try std.testing.expect(observed.output_schema != null);
    const replay = try submitConfigure(&host, create);
    try std.testing.expect(replay == .accepted and replay.accepted.replayed);
    try std.testing.expectEqualStrings(session.slice(), replay.accepted.session.slice());
    try std.testing.expectEqual(first.accepted.revision, replay.accepted.revision);

    const override = try arena.create(wire_request.ConfigureCommand);
    override.* = .{ .preset = create.preset };
    try override.key.set("preset-overrides");
    override.configuration.model.state = .value;
    try override.configuration.model.value.set("preset-override-model");
    override.configuration.provider.state = .value;
    try override.configuration.provider.value.set("codex");
    override.configuration.workspace.state = .value;
    try override.configuration.workspace.value.set(root);
    override.configuration.reasoning_effort.state = .explicit_null;
    override.configuration.compaction_trigger.state = .value;
    try override.configuration.compaction_trigger.value.set("12000");
    override.configuration.tools = try .of(&.{"start_agent"});
    override.configuration.permission_mode.state = .value;
    try override.configuration.permission_mode.value.set("bypass");
    override.configuration.label.state = .explicit_null;
    override.configuration.output_schema.state = .explicit_null;
    override.configuration.instructions = .{
        .state = .value,
        .borrowed = "Overridden instructions".ptr,
        .length = "Overridden instructions".len,
        .digest = protocol.contentDigest("Overridden instructions"),
    };
    const overridden = try submitConfigure(&host, override);
    try std.testing.expect(overridden == .accepted);
    try storage.inspectSession(overridden.accepted.session.slice(), &observed);
    try std.testing.expectEqualStrings("preset-override-model", observed.model.slice());
    try std.testing.expectEqual(protocol.Provider.codex, observed.provider.?);
    try std.testing.expectEqualStrings(root, observed.workspace.slice());
    try std.testing.expectEqual(@as(?u64, 12000), observed.compaction_trigger_override);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), observed.reasoning_effort_override);
    try std.testing.expectEqualStrings("bypass", observed.permission_mode.slice());
    try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member WHERE tool_set_id=?1", .{observed.tool_set_id}));
    try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?1 AND tool.name='start_agent'", .{observed.tool_set_id}));
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("Overridden instructions"), &observed.instructions.digest);
    try std.testing.expect(observed.output_schema == null);

    // An edited preset is not saved or looked up by name in the Store. A
    // request overriding its edited field still has the same resolved digest.
    const edited_spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"model":"gpt-6-sol","effort":"low","compactAt":10000,"tools":[],"permissionMode":"ask","provider":"openai","instructions":"Preset instructions","outputSchema":{"type":"object"},"label":"Preset label"}
    , .{})).object;
    const edited_presets = [_]core_tools.Preset{.{ .name = "review", .spec = edited_spec }};
    host.presets = &edited_presets;
    const same = try submitConfigure(&host, override);
    try std.testing.expect(same == .accepted and same.accepted.replayed);
    try std.testing.expectEqualStrings(overridden.accepted.session.slice(), same.accepted.session.slice());
    try std.testing.expect(try submitConfigure(&host, create) == .conflict);
    // Changing the catalog does not change the already created Session.
    try storage.inspectSession(session.slice(), &observed);
    try std.testing.expectEqualStrings("gpt-6.1-sol", observed.model.slice());

    const invalid = try arena.create(wire_request.ConfigureCommand);
    invalid.* = .{ .preset = create.preset };
    try invalid.key.set("preset-invalid-resolved");
    invalid.configuration.compaction_trigger.state = .explicit_null;
    const refused = try submitConfigure(&host, invalid);
    try std.testing.expect(refused == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_compaction_trigger, refused.rejected.code);
    host.presets = &.{};
    try std.testing.expect(try submitConfigure(&host, create) == .conflict);
    const missing = try arena.create(wire_request.ConfigureCommand);
    missing.* = .{ .preset = create.preset };
    try missing.key.set("preset-missing");
    const unknown = try submitConfigure(&host, missing);
    try std.testing.expect(unknown == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, unknown.rejected.code);
    host.presets = &presets;
    const refused_again = try submitConfigure(&host, missing);
    try std.testing.expect(refused_again == .rejected and refused_again.rejected.replayed);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, refused_again.rejected.code);
    invalid.session = session;
    try invalid.key.set("preset-on-update");
    const update = try submitConfigure(&host, invalid);
    try std.testing.expect(update == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, update.rejected.code);
    const update_replay = try submitConfigure(&host, invalid);
    try std.testing.expect(update_replay == .rejected and update_replay.rejected.replayed);
    try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, update_replay.rejected.code);
}

test "session archive renders accepted intent and completion for both archive and restore" {
    const protocol_reply = @import("protocol_reply.zig");
    var command: protocol.SessionArchiveCommand = .{};
    try command.session.set("k7m2qx");
    inline for (.{ false, true }) |archived| {
        command.archived = archived;
        for (std.meta.tags(protocol.SessionStopCompletion)) |completion| {
            for ([_]bool{ false, true }) |replayed| {
                var response: protocol.ResponseBuffer = .{};
                try response.render(host_reply.renderSessionArchiveReply, .{ command.session.slice(), store_module.SessionArchiveReply{ .accepted = .{
                    .replayed = replayed,
                    .archived = archived,
                    .completion = completion,
                } } });
                const decoded = try protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "k7m2qx", .{ .session_archive = .{ .archived = archived } }).answer;
                try std.testing.expectEqual(replayed, decoded.replayed);
                try std.testing.expectEqual(archived, decoded.result.accepted.session_archive.archived);
                try std.testing.expectEqual(completion, decoded.result.accepted.session_archive.completion);
                try expectMutationFieldPresence(response.slice(), 200, "k7m2qx", .{ .session_archive = .{ .archived = archived } });
            }
        }
    }
    for (std.meta.tags(protocol.SessionArchiveRejection)) |code| {
        var response: protocol.ResponseBuffer = .{};
        try response.render(host_reply.renderSessionArchiveReply, .{ command.session.slice(), store_module.SessionArchiveReply{ .rejected = .{ .replayed = true, .code = code } } });
        const decoded = try protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "k7m2qx", .{ .session_archive = .{ .archived = true } }).answer;
        try std.testing.expectEqualStrings(@tagName(code), decoded.result.rejected.slice());
    }
}

test "inline skills binding under heap exhaustion answers 503 without key admission or Host fencing" {
    const skills = @import("skills.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const file = try tmp.dir.createFile(std.testing.io, "SKILL.md", .{});
    try file.writeStreamingAll(std.testing.io, &@as([512]u8, @splat('x')));
    file.close(std.testing.io);
    var path_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/SKILL.md", .{root});
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // Enough unbound entries that decoding the catalog grows the request
    // arena, so the sweep fails allocations inside the Store's held read.
    var entries: [65]skills.Entry = undefined;
    entries[0] = .{ .name = "demo", .description = "Metadata", .path = path };
    var names: [64][6]u8 = undefined;
    const description = @as([1024]u8, @splat('d'));
    for (entries[1..], &names, 0..) |*entry, *name, index| {
        _ = try std.fmt.bufPrint(name, "pad-{d:0>2}", .{index});
        entry.* = .{ .name = name, .description = &description, .path = "/never-read" };
    }
    const initial = try skills.initialCatalog(arena.allocator(), .{ .entries = &entries });
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/pressure.sqlite", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, database, root);
    defer storage.close() catch unreachable;
    const configure = try store_module.testingCompleteConfiguration("pressure-config", "", root, "model-a");
    const configured = try storage.configureWithInitialSkills(&configure, null, &.{ .ready = .{ .encoded = initial.encoded, .instruction = initial.instruction } }, .{});
    try std.testing.expect(configured == .accepted);
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.store.set(root);
    try lease.paths.scratch.set(root);
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    const text = "prompt /demo";
    var command: wire_request.MessageCommand = .{ .session = configured.accepted.session, .text = .{ .state = .value, .borrowed = text.ptr, .length = text.len, .digest = protocol.contentDigest(text) } };
    try command.key.set("pressure-key");
    // Heap pressure anywhere in binding, the recipient catalog's held read
    // included, is the Host being busy, never canonical corruption: each
    // allocation in turn fails, until the Message is admitted.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        // Admission takes its offer whether or not it admits.
        var oom_offer = try SessionEnvironments.Offer.init(std.testing.allocator, 0);
        failing = .init(std.testing.allocator, .{ .fail_index = fail_index });
        host.allocator = failing.allocator();
        const result = submitMessage(&host, &command, &oom_offer);
        host.allocator = std.testing.allocator;
        try std.testing.expect(!storage.isFenced() and host.launchAllowed());
        if (!failing.has_induced_failure) break;
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expect(!try storage.commandExists(command.key.slice()));
    }
    // Readings past the catalog's held read are the ones the sweep reached.
    try std.testing.expect(fail_index > 2);
    try std.testing.expect(try storage.commandExists(command.key.slice()));
    var intake: Intake = .{ .host = &host };
    var exchange: Intake.Exchange = .{ .owner = &intake, .host = &host, .fd = -1, .accepted_at_ns = 0, .deadline = 0 };
    defer if (exchange.reply) |reply| {
        reply.deinit();
        host.allocator.destroy(reply);
    };
    exchange.fail(error.OutOfMemory);
    try std.testing.expect(std.mem.startsWith(u8, exchange.reply.?.header[0..exchange.reply.?.header_length], "HTTP/1.1 503 "));
    // readSkills' initial allocation is also before its canonical held access.
    host.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, readSkillSuggestions(&host, std.testing.allocator, .{ .session = configured.accepted.session.slice() }, ""));
    host.allocator = std.testing.allocator;
    try std.testing.expect(!storage.isFenced() and host.launchAllowed());
    // Page allocation follows a successful durable read, outside Store access.
    try std.testing.expectError(error.OutOfMemory, readSkillSuggestions(&host, failing.allocator(), .{ .session = configured.accepted.session.slice() }, ""));
    try std.testing.expect(!storage.isFenced() and host.launchAllowed());
    var preview = try readSkillSuggestions(&host, std.testing.allocator, .{ .session = configured.accepted.session.slice() }, "");
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(@import("skill_suggestions.zig").capacity, preview.entries.len);
    try std.testing.expectEqual(entries.len, preview.total);
    // The key the sweep admitted replays, with the typed text its content.
    var retry_offer = try SessionEnvironments.Offer.init(std.testing.allocator, 0);
    const accepted = try submitMessage(&host, &command, &retry_offer);
    try std.testing.expect(accepted == .accepted and accepted.accepted.replayed);
    try std.testing.expectEqual(@as(u64, text.len), accepted.accepted.content.length);
    try std.testing.expect(host.launchAllowed() and !storage.isFenced());
    // A skills reload's capture and its held write answer the same way; the
    // root's skills are not the 65 saved, so the reload replaces them.
    var reload: wire_request.ConfigureCommand = .{ .session = configured.accepted.session, .reload_skills = true };
    try reload.key.set("pressure-reload");
    fail_index = 0;
    while (true) : (fail_index += 1) {
        failing = .init(std.testing.allocator, .{ .fail_index = fail_index });
        host.allocator = failing.allocator();
        const result = submitConfigure(&host, &reload);
        host.allocator = std.testing.allocator;
        try std.testing.expect(!storage.isFenced() and host.launchAllowed());
        if (!failing.has_induced_failure) {
            try std.testing.expectEqual(protocol.SkillsReloadStatus.reloaded, (try result).accepted.skills.?);
            break;
        }
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expect(!try storage.commandExists(reload.key.slice()));
    }
    try std.testing.expect(fail_index > 2);
    try store_module.testingFailReadsOf(&storage, "session_skill_catalog");
    try std.testing.expectError(error.CanonicalStoreFailure, readSkillSuggestions(&host, std.testing.allocator, .{ .session = configured.accepted.session.slice() }, ""));
    try std.testing.expect(storage.isFenced() and !host.launchAllowed());
}

test "inline skills suggestions answer heap exhaustion as busy, not a catalog refusal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    try lease.paths.store.set("s");
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buffer, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"skill_suggestions\",\"store\":\"s\",\"workspace\":\"{s}\",\"prefix\":\"\"}}", .{root});
    // Each allocation in turn fails, until the page is served: every
    // failure is a 503, and none fences the Store or the Host.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var sockets: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
        defer _ = std.c.close(sockets[1]);
        try setNonblocking(sockets[0]);
        var header_buffer: [256]u8 = undefined;
        try writeAll(std.testing.io, sockets[1], try std.fmt.bufPrint(&header_buffer, "POST /v1/skill-suggestions HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Length: {d}\r\n\r\n", .{request.len}));
        try writeAll(std.testing.io, sockets[1], request);
        const exchange = try std.testing.allocator.create(Intake.Exchange);
        exchange.* = .{ .owner = undefined, .host = &host, .fd = sockets[0], .accepted_at_ns = 0, .deadline = std.math.maxInt(i128) };
        defer std.debug.assert(exchange.destroy());
        try exchange.read();
        try std.testing.expectEqual(.ready, exchange.state);
        const reply = try exchange.ensureReply();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        host.allocator = failing.allocator();
        exchange.prepare() catch |err| exchange.fail(err);
        host.allocator = std.testing.allocator;
        try std.testing.expect(!storage.isFenced() and host.launchAllowed());
        const status = reply.header[0..reply.header_length];
        if (!failing.has_induced_failure) {
            try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 200 "));
            break;
        }
        try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 503 "));
    }
    try std.testing.expect(fail_index > 0);
}
