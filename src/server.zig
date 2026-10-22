const std = @import("std");
const builtin = @import("builtin");
const HostDiagnostics = @import("HostDiagnostics.zig");
const TerminalText = @import("TerminalText.zig");
const TestObservation = @import("TestObservation.zig");
const trace_native = @import("posix");
const bash = @import("bash.zig");
const descriptor_capacity = @import("descriptor_capacity.zig");
const product_defaults = @import("product_defaults.zig");
const descriptor_limit = @import("descriptor_limit.zig");
const execution = @import("execution.zig");
const execution_turn = @import("execution_turn.zig");
const model_adapter = @import("model_adapter.zig");
const named_scratch = @import("named_scratch.zig");
const output_format = @import("output_format.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol.zig");
const retry_policy = @import("retry_policy.zig");
const store_module = @import("store.zig");
const stderr = @import("stderr.zig");

pub const default_bash_timeout_ms: u64 = 5 * 60 * 1000;
pub const default_bash_path = "/bin/bash";
pub const scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const default_retention_entry_capacity =
    output_retention.orchestration_bytes / @sizeOf(output_retention.Entry);
// The complete Debug request -> SQLite -> response path exceeds 512 KiB.
// Only the two shared workers reserve these stacks, independent of exchanges.
const intake_worker_stack_bytes = 1024 * 1024;

/// Real operating limits. Tests may narrow them; production uses the defaults.
pub const Limits = struct {
    request_scratch_limit_bytes: u64 = scratch_limit_bytes,
    request_preparation_byte_allowance: usize = model_adapter.preparation_byte_allowance,
    request_preparation_item_allowance: usize = model_adapter.preparation_item_allowance,
    bash_scratch_limit_bytes: u64 = scratch_limit_bytes,
    retention_entry_capacity: ?usize = null,
    provider_inactivity_seconds: i64 = 5 * 60,
    retry_waits_ms: retry_policy.Waits = retry_policy.default_waits_ms,
    client_send_buffer_bytes: ?u32 = null,
    sqlite_cache_spill: bool = true,
    sqlite_cache_kib: u32 = (store_module.OpenOptions{}).cache_kib,
};

/// Injected failures, delays, gates and test observation only.
pub const Faults = struct {
    content_acquire: bool = false,
    content_write: bool = false,
    content_seal: bool = false,
    content_read: bool = false,
    content_import: bool = false,
    before_commit: bool = false,
    startup_cleanup: bool = false,
    shutdown_after_accept: bool = false,
    attempt_before_commit: bool = false,
    result_before_commit: bool = false,
    request_first_step: bool = false,
    request_write: bool = false,
    request_seal: bool = false,
    request_scratch_acquire: bool = false,
    request_preparation_advance_delay_ms: i64 = 0,
    request_read: bool = false,
    request_unlink: bool = false,
    provider_prepare: bool = false,
    completion_identity_fault: provider.CompletionIdentityFault = .none,
    response_acquire: bool = false,
    response_unlink: bool = false,
    response_write: bool = false,
    response_write_on_resume: bool = false,
    response_seal: bool = false,
    response_capture_gate_path: ?[]const u8 = null,
    response_capture_gate_min_written_bytes: usize = 0,
    response_metadata: bool = false,
    response_metadata_unlink: bool = false,
    response_read: bool = false,
    response_import: bool = false,
    response_commit: bool = false,
    bash_preparation: bool = false,
    bash_preparation_after_captures: bool = false,
    bash_spawn: bool = false,
    bash_service: bool = false,
    bash_capture_read: bool = false,
    bash_capture_write: bool = false,
    bash_seal: bool = false,
    bash_cleanup: bool = false,
    bash_lifecycle_fault: bash.LifecycleFault = .none,
    bash_fault_gated: bool = false,
    retention_removal: bool = false,
    before_launch_delay_ms: i64 = 0,
    before_result_delay_ms: i64 = 0,
    model_result_gate_path: ?[]const u8 = null,
    inspection_reply_delay_ms: i64 = 0,
    inspection_reply_gate_path: ?[]const u8 = null,
    report_unlink: bool = false,
    test_phase_trace: bool = false,
    test_observation_fd: ?c_int = null,
    test_observation_state_fd: ?c_int = null,
    test_observation_plan: ?TestObservation.Plan = null,
    test_transition: ?TestTransition = null,
    test_transition_gate_path: ?[]const u8 = null,
    bash_observed_exit_gate_path: ?[]const u8 = null,
    bash_cleanup_gate_path: ?[]const u8 = null,
    control_gate_keys: ?[]const u8 = null,
    control_gate_path: ?[]const u8 = null,
    suppress_first_control_hint: bool = false,
    sqlite_diagnostics: bool = false,
};

const TestTransition = enum {
    action_attempt_admitted,
    prepared_before_handoff,
    action_result_ready,
    action_result_committed,
};

const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    lease: *platform.StoreLease,
    store: *store_module.Store,
    instance: protocol.InstanceId = undefined,
    faults: Faults,
    limits: Limits = .{},
    provider_endpoint: ?[]const u8 = null,
    provider_ca_file: ?[]const u8 = null,
    authentication: ?model_adapter.Authentication = null,
    auth_worker: ?*AuthWorker = null,
    capture_writer: ?*provider.CaptureWriter = null,
    bash_path: []const u8 = default_bash_path,
    bash_environment: *const std.process.Environ.Map = &bash.empty_environment,
    bash_timeout_ms: u64 = default_bash_timeout_ms,
    retention: *output_retention.Queue = undefined,
    custody: execution.CustodyPool = .{ .records = &.{} },
    execution_shutdown: std.atomic.Value(bool) = .init(false),
    effect_shutdown: std.atomic.Value(bool) = .init(false),
    dispatch_fenced: std.atomic.Value(bool) = .init(false),
    controls_changed: std.atomic.Value(bool) = .init(false),
    control_hint_suppressed: std.atomic.Value(bool) = .init(false),
    request_counter: std.atomic.Value(u64) = .init(0),
    intake: ?*Intake = null,
    intake_capacity: usize = product_defaults.intake_capacity,
    descriptor_soft_limit: ?usize = null,
    scratch_used: std.atomic.Value(u64) = .init(0),
    launch_mutex: std.Io.Mutex = .init,
    trace_run_ns: u64 = 0,
    trace_sequence: u64 = 0,
    trace_lost: std.atomic.Value(bool) = .init(false),
    test_observation: ?*TestObservation = null,
    last_unprocessed_completions: ?u64 = null,

    // Canonical permission belongs to Store; process-local permission belongs
    // to Host. The Store handoff must enter this gate, in that lock order, for
    // every effect. A preflight observation alone cannot authorize a launch.
    fn launchAllowed(self: *const Host) bool {
        return !self.dispatch_fenced.load(.acquire) and
            !self.execution_shutdown.load(.acquire) and
            !self.effect_shutdown.load(.acquire);
    }

    fn withEffectLaunch(self: *Host, context: anytype, comptime launch: anytype) !void {
        self.launch_mutex.lockUncancelable(self.io);
        defer self.launch_mutex.unlock(self.io);
        if (!self.launchAllowed()) return error.HostDispatchSuppressed;
        try launch(context);
    }
};

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
            const kind = switch (err) {
                error.ClientCapacity, error.ControlCapacity, error.DiscoveryCapacity => "busy",
                error.UnsupportedControl => "unsupported",
                else => "invocation_error",
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
                            for (self.host.intake.?.exchanges.items) |peer| {
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
            thread.* = try std.Thread.spawn(.{ .stack_size = intake_worker_stack_bytes }, Worker.run, .{worker});
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
                    if (self.host.effect_shutdown.load(.acquire)) exchange.retireUnhanded();
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
            if (self.host.effect_shutdown.load(.acquire)) {
                for (self.exchanges.items) |exchange| exchange.retireUnhanded();
            }
            self.serviceWorkers();
            if (self.host.effect_shutdown.load(.acquire) and listener_open.*) {
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
                    self.host.launch_mutex.lockUncancelable(self.host.io);
                    self.host.effect_shutdown.store(true, .release);
                    self.host.dispatch_fenced.store(true, .release);
                    self.host.launch_mutex.unlock(self.host.io);
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
        exchange.* = .{ .host = self.host, .fd = fd, .accepted_at_ns = accepted_at_ns, .deadline = @as(i128, accepted_at_ns) + 10 * std.time.ns_per_s };
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
        builtin.os.tag,
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
        builtin.os.tag,
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
    const custody_records = try allocator.alloc(execution.CustodyRecord, active_capacity);
    defer allocator.free(custody_records);
    const retention_capacity = @min(
        default_retention_entry_capacity,
        limits.retention_entry_capacity orelse default_retention_entry_capacity,
    );
    const retention_entries = try allocator.alloc(output_retention.Entry, retention_capacity);
    defer allocator.free(retention_entries);
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
    var provider_initialization_owned = false;
    if (provider_endpoint) |endpoint| {
        try provider.validateEndpoint(endpoint);
        if (authentication) |selected| try model_adapter.validateAuthenticationEndpoint(endpoint, provider_ca_file, selected);
        try provider.initialize();
        provider_initialization_owned = true;
    }
    errdefer if (provider_initialization_owned) provider.deinitialize();
    try std.Io.randomSecure(io, &host.instance);
    var intake: Intake = undefined;
    try intake.init(&host);
    defer intake.deinit();
    host.intake = &intake;
    const execution_thread = try std.Thread.spawn(.{}, executionMain, .{&host});
    provider_initialization_owned = false;
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
        host.launch_mutex.lockUncancelable(host.io);
        host.execution_shutdown.store(true, .release);
        host.launch_mutex.unlock(host.io);
        execution_thread.join();
        if (provider_endpoint != null) provider.deinitialize();
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
        try ready.appendFmt(" curl={s} openssl={s}", .{ provider.curl_version, provider.openssl_version });
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

const AttemptOwner = struct {
    token: execution.CustodyToken = undefined,
    binding: store_module.AttemptBinding = undefined,
};

const ProviderSlot = struct {
    owner: AttemptOwner,
    transfer: provider.Transfer = undefined,
};

const NamedScratchSlot = struct {
    token: execution.CustodyToken,
    owner: named_scratch.Owner,
};

const BashSlot = struct {
    token: execution.CustodyToken,
    binding: store_module.ActionAttemptBinding,
    execution: bash.Execution,
    stop_accepted: bool = false,
    delivery: union(enum) {
        open,
        closed: struct {
            reclaim_at: std.Io.Clock.Timestamp,
            reclaim_failed: bool = false,
        },
    } = .open,
};

const BashPreparedCleanupSlot = struct {
    token: execution.CustodyToken,
    cleanup: bash.PreparedCleanup,
};

const BashPreparingSlot = struct {
    token: execution.CustodyToken,
    binding: store_module.ActionAttemptBinding,
};

const ModelPreparingSlot = struct {
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
};

const ModelAuthenticatingSlot = struct {
    owner: ModelPreparingSlot,
    request: provider.PreparedRequest,
    cancelled: bool = false,
};

const ExecutionSlot = union(enum) {
    free,
    model_preparing: ModelPreparingSlot,
    model_authenticating: ModelAuthenticatingSlot,
    provider: ProviderSlot,
    bash_preparing: BashPreparingSlot,
    bash: BashSlot,
    bash_prepared_cleanup: BashPreparedCleanupSlot,
    named_scratch: NamedScratchSlot,
};

/// Execution-owned consistency checks beside ExecutionSlot. Each inspects
/// current slot and custody facts without mutating them. The legal
/// checkpoint is after a complete admission, preparation, completion, or
/// cleanup transition on the execution owner, when no admission
/// temporaries are outstanding. Payloads match by custody token, never by
/// array index. Aggregate reconciliation runs only here, not midway
/// through beginAdmittedAttempt or launchPreparedRequest where partially
/// established local ownership is legitimate.
fn slotToken(slot: *const ExecutionSlot) ?execution.CustodyToken {
    return switch (slot.*) {
        .free => null,
        .model_preparing => |*active| active.token,
        .model_authenticating => |*active| active.owner.token,
        .provider => |*active| active.owner.token,
        .bash_preparing => |*active| active.token,
        .bash => |*active| active.token,
        .bash_prepared_cleanup => |*retained| retained.token,
        .named_scratch => |*retained| retained.token,
    };
}

fn checkSlotCustodyAgreement(slots: []const ExecutionSlot, custody: *execution.CustodyPool) !void {
    var represented: usize = 0;
    for (slots, 0..) |*slot, i| {
        switch (slot.*) {
            .free => {},
            .model_preparing => |*active| try custody.checkAttachedModel(active.token, active.binding),
            .model_authenticating => |*active| try custody.checkAttachedModel(active.owner.token, active.owner.binding),
            .provider => |*active| try custody.checkAttachedModel(active.owner.token, active.owner.binding),
            .bash_preparing => |*active| try custody.checkAttachedAction(active.token, active.binding),
            // Delivery closure detaches custody while the .bash payload is
            // retained for reclamation: open delivery requires attachment,
            // closed delivery requires detachment plus the retained typed
            // identity. Token-only retained owners (prepared cleanup,
            // named scratch) keep the token-only detached check.
            .bash => |*active| switch (active.delivery) {
                .open => try custody.checkAttachedAction(active.token, active.binding),
                .closed => try custody.checkDetachedAction(active.token, active.binding),
            },
            .bash_prepared_cleanup => |*retained| try custody.checkDetached(retained.token),
            .named_scratch => |*retained| try custody.checkDetached(retained.token),
        }
        const token = slotToken(slot) orelse continue;
        represented += 1;
        for (slots[i + 1 ..]) |*later| {
            const other = slotToken(later) orelse continue;
            if (other.index == token.index and other.generation == token.generation) return error.DuplicateExecutionToken;
        }
    }
    // Reverse reconciliation: every occupied custody record must have its
    // owning slot in the checked population. A missing payload with live
    // custody is capacity that can neither progress nor clean up.
    if (represented != custody.occupied()) return error.OrphanedExecutionCustody;
}

/// Execution-owned preparation correspondence. The live preparations stay
/// in their final storage under the existing single-owner discipline; this
/// establishes that the preparing slots belong to those live objects, not
/// merely that the counts agree. A null preparation must have no matching
/// slot. For Bash only the facts its preparation owns (action identity)
/// are compared; no second stored identity is introduced.
fn checkSharedPreparation(
    slots: []const ExecutionSlot,
    model_preparation: ?*model_adapter.Preparation,
    bash_preparation: ?*const bash.Preparation,
) !void {
    var model_slot: ?store_module.AttemptBinding = null;
    var bash_slot: ?store_module.ActionAttemptBinding = null;
    for (slots) |*slot| switch (slot.*) {
        .model_preparing => |*active| {
            if (model_slot != null) return error.PreparationOwnershipMismatch;
            model_slot = active.binding;
        },
        .bash_preparing => |*active| {
            if (bash_slot != null) return error.PreparationOwnershipMismatch;
            bash_slot = active.binding;
        },
        else => {},
    };
    if (model_preparation) |preparation| {
        const binding = model_slot orelse return error.PreparationOwnershipMismatch;
        try preparation.checkIntegrity(binding);
    } else if (model_slot != null) {
        return error.PreparationOwnershipMismatch;
    }
    if (bash_preparation) |preparation| {
        const slot_binding = bash_slot orelse return error.PreparationOwnershipMismatch;
        if (preparation.action_id != slot_binding.action_id or
            preparation.attempt_ordinal != slot_binding.attempt_ordinal)
        {
            return error.PreparationOwnershipMismatch;
        }
    } else if (bash_slot != null) {
        return error.PreparationOwnershipMismatch;
    }
}

const AdmissionProgress = enum { no_work, retry_later, admitted };

const LifecycleMeasurement = struct {
    last_service_at: ?std.Io.Clock.Timestamp = null,
    next_trace_at: ?std.Io.Clock.Timestamp = null,
    maximum_gap_ns: u64 = 0,
    wait_since_service_ns: u64 = 0,
};

const lifecycle_trace_interval_ms = 100;

// One Host-wide authentication I/O job. Canonical custody remains in the
// execution slot while file locks, refresh TLS and persistence run here.
const AuthWorker = struct {
    io: std.Io,
    authentication: model_adapter.Authentication,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: enum { idle, requested, ready, in_use, failed } = .idle,
    // Only .ready/.in_use own this final storage. The execution thread borrows
    // it through launch; the worker never publishes a value copy of the lease.
    credential: model_adapter.Credential = undefined,
    failure: ?anyerror = null,
    stopping: bool = false,

    const Result = union(enum) { ready: *const model_adapter.Credential, failed: anyerror };

    fn request(self: *AuthWorker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.state == .idle);
        self.state = .requested;
        self.condition.broadcast(self.io);
    }

    fn take(self: *AuthWorker) ?Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return switch (self.state) {
            .idle, .requested, .in_use => null,
            .ready => result: {
                self.state = .in_use;
                break :result .{ .ready = &self.credential };
            },
            .failed => result: {
                const err = self.failure.?;
                self.failure = null;
                self.state = .idle;
                break :result .{ .failed = err };
            },
        };
    }

    fn finish(self: *AuthWorker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.state == .in_use);
        self.credential.release();
        self.state = .idle;
    }

    fn stop(self: *AuthWorker, thread: std.Thread) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        thread.join();
        std.debug.assert(self.state != .in_use);
        if (self.state == .ready) self.credential.release();
    }

    fn run(self: *AuthWorker) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and self.state != .requested)
                self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            self.mutex.unlock(self.io);
            model_adapter.acquireCredentialInto(self.io, self.authentication, &self.credential) catch |err| {
                self.mutex.lockUncancelable(self.io);
                self.failure = err;
                self.state = .failed;
                self.condition.broadcast(self.io);
                self.mutex.unlock(self.io);
                continue;
            };
            self.mutex.lockUncancelable(self.io);
            self.state = .ready;
            self.condition.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }
};

fn executionMain(host: *Host) void {
    var auth_worker = AuthWorker{ .io = host.io, .authentication = host.authentication orelse undefined };
    const auth_thread: ?std.Thread = if (host.authentication != null)
        std.Thread.spawn(.{}, AuthWorker.run, .{&auth_worker}) catch |err| {
            fenceDispatch(host, "authentication worker initialization", err);
            return;
        }
    else
        null;
    if (auth_thread != null) host.auth_worker = &auth_worker;
    defer if (auth_thread) |thread| {
        host.auth_worker = null;
        auth_worker.stop(thread);
    };
    const slots = host.allocator.alloc(ExecutionSlot, host.custody.records.len) catch |err| {
        fenceDispatch(host, "execution workspace allocation", err);
        return;
    };
    defer host.allocator.free(slots);
    for (slots) |*slot| slot.* = .free;
    var capture_writer = provider.CaptureWriter{
        .io = host.io,
        .test_gate_path = host.faults.response_capture_gate_path,
        .test_gate_min_written_bytes = host.faults.response_capture_gate_min_written_bytes,
        .test_observation = host.test_observation,
    };
    const capture_thread: ?std.Thread = if (host.provider_endpoint != null)
        std.Thread.spawn(.{}, provider.CaptureWriter.run, .{&capture_writer}) catch |err| {
            fenceDispatch(host, "capture writer initialization", err);
            return;
        }
    else
        null;
    if (capture_thread != null) host.capture_writer = &capture_writer;
    defer if (capture_thread) |thread| {
        host.capture_writer = null;
        capture_writer.stop(thread);
    };
    var reactor: ?provider.Reactor = if (host.provider_endpoint != null)
        provider.Reactor.init(slots.len) catch |err| {
            fenceDispatch(host, "transport reactor initialization", err);
            return;
        }
    else
        null;
    defer if (reactor) |*active| active.deinit();
    var bash_preparation: ?bash.Preparation = null;
    var model_preparation: model_adapter.Preparation = undefined;
    defer shutdownExecution(
        host,
        if (reactor) |*active| active else null,
        slots,
        &bash_preparation,
        &model_preparation,
    );

    var turn_state = execution_turn.State{ .capacity_was_full = slots.len == 0 };
    var measurement: LifecycleMeasurement = .{};
    var next_receive_slot: usize = 0;
    while (!host.execution_shutdown.load(.acquire) and !host.effect_shutdown.load(.acquire)) {
        var bash_window: [bash.copy_window_bytes]u8 = undefined;
        var native = NativeTurn{
            .host = host,
            .reactor = if (reactor) |*active| active else null,
            .slots = slots,
            .next_receive_slot = &next_receive_slot,
            .bash_preparation = &bash_preparation,
            .model_preparation = &model_preparation,
            .bash_window = &bash_window,
            .measurement = &measurement,
            .fenced = false,
        };
        switch (execution_turn.run(&turn_state, &native)) {
            .continue_immediately => {},
            .wait => |kind| {
                const wait_started = std.Io.Clock.Timestamp.now(host.io, .awake);
                switch (kind) {
                    .transport => reactor.?.wait(25) catch |err| {
                        fenceDispatch(host, "transport wait", err);
                        break;
                    },
                    .bash => _ = host.io.sleep(.fromMilliseconds(25), .awake) catch {},
                    .idle => _ = host.io.sleep(.fromMilliseconds(100), .awake) catch {},
                }
                const wait_finished = std.Io.Clock.Timestamp.now(host.io, .awake);
                measurement.wait_since_service_ns += @intCast(wait_started.durationTo(wait_finished).raw.nanoseconds);
            },
            .terminate => break,
        }
        if (native.fenced) break;
    }
    const stopped_at = std.Io.Clock.Timestamp.now(host.io, .awake);
    if (measurement.last_service_at) |last| {
        traceServiceBoundary(
            host,
            @intCast(last.raw.nanoseconds),
            @intCast(stopped_at.raw.nanoseconds),
            measurement.wait_since_service_ns,
        );
        measurement.maximum_gap_ns = @max(
            measurement.maximum_gap_ns,
            @as(u64, @intCast(last.durationTo(stopped_at).raw.nanoseconds)),
        );
    }
    traceLifecycleService(host, measurement.maximum_gap_ns);
}

const NativeTurn = struct {
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    next_receive_slot: *usize,
    bash_preparation: *?bash.Preparation,
    model_preparation: *model_adapter.Preparation,
    bash_window: []u8,
    measurement: *LifecycleMeasurement,
    fenced: bool,

    pub fn now(self: *NativeTurn) std.Io.Clock.Timestamp {
        return std.Io.Clock.Timestamp.now(self.host.io, .awake);
    }

    pub fn noteLifecycleOpportunity(self: *NativeTurn) void {
        const observed = self.now();
        if (self.measurement.last_service_at) |last| {
            traceServiceBoundary(
                self.host,
                @intCast(last.raw.nanoseconds),
                @intCast(observed.raw.nanoseconds),
                self.measurement.wait_since_service_ns,
            );
            self.measurement.maximum_gap_ns = @max(
                self.measurement.maximum_gap_ns,
                @as(u64, @intCast(last.durationTo(observed).raw.nanoseconds)),
            );
        }
        self.measurement.last_service_at = observed;
        self.measurement.wait_since_service_ns = 0;
        const trace_due = if (self.measurement.next_trace_at) |deadline| deadline.compare(.lte, observed) else true;
        if (trace_due) {
            traceLifecycleService(self.host, self.measurement.maximum_gap_ns);
            self.measurement.next_trace_at = observed.addDuration(.{
                .raw = .fromMilliseconds(lifecycle_trace_interval_ms),
                .clock = .awake,
            });
        }
    }

    pub fn consumeControlHint(self: *NativeTurn) bool {
        return self.host.controls_changed.swap(false, .acq_rel);
    }

    pub fn reconcileControls(self: *NativeTurn) void {
        cancelSupersededTransfers(
            self.host,
            self.reactor,
            self.slots,
            self.model_preparation,
        );
        stopSupersededBash(self.host, self.slots, self.bash_preparation);
    }

    pub fn advanceBashPreparation(self: *NativeTurn) bool {
        return callAdvanceBashPreparation(self.host, self.slots, self.bash_preparation);
    }

    pub fn advanceLiveBash(self: *NativeTurn) bool {
        return advanceBash(self.host, self.slots, self.bash_window);
    }

    pub fn advanceRetainedCleanup(self: *NativeTurn, observed: std.Io.Clock.Timestamp, retry_at: *std.Io.Clock.Timestamp) bool {
        return callAdvanceRetainedCleanup(self.host, self.slots, observed, retry_at);
    }

    pub fn dispatchFenced(self: *const NativeTurn) bool {
        return self.host.dispatch_fenced.load(.acquire);
    }

    pub fn providerConfigured(self: *const NativeTurn) bool {
        return self.host.provider_endpoint != null;
    }

    pub fn freeSlots(self: *const NativeTurn) usize {
        return countFreeSlots(self.slots);
    }

    pub fn bashPreparationOpen(self: *const NativeTurn) bool {
        return self.bash_preparation.* == null;
    }

    pub fn modelPreparationOpen(self: *const NativeTurn) bool {
        for (self.slots) |slot| switch (slot) {
            .model_preparing, .model_authenticating => return false,
            else => {},
        };
        return true;
    }

    pub fn hasTransport(self: *const NativeTurn) bool {
        return slotsHaveTransport(self.slots);
    }

    pub fn hasBash(self: *const NativeTurn) bool {
        return slotsHaveBash(self.slots);
    }

    pub fn recoverUncertainAction(self: *NativeTurn) error{Fence}!bool {
        const active_slots = ActiveSlots{ .slots = self.slots };
        const active_actions = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeActionContains,
            .maximum_exclusions = self.slots.len,
        };
        return self.host.store.recoverOneUncertainAction(active_actions) catch |err| {
            fenceDispatch(self.host, "uncertain Bash recovery", err);
            self.fenced = true;
            return error.Fence;
        };
    }

    pub fn recoverExhaustedRetry(self: *NativeTurn) error{Fence}!bool {
        const active_slots = ActiveSlots{ .slots = self.slots };
        const active_filter = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeOperationContains,
            .maximum_exclusions = self.slots.len,
        };
        return self.host.store.recoverOneExhaustedModelAttempt(active_filter) catch |err| {
            fenceDispatch(self.host, "exhausted retry recovery", err);
            self.fenced = true;
            return error.Fence;
        };
    }

    fn firstFreeSlot(self: *NativeTurn) ?*ExecutionSlot {
        for (self.slots) |*slot| {
            if (slotIsFree(slot)) return slot;
        }
        return null;
    }

    pub fn admitBash(self: *NativeTurn) execution_turn.Admission {
        const slot = self.firstFreeSlot() orelse return .no_work;
        return switch (admitBashAttempt(self.host, slot, self.bash_preparation)) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
        };
    }

    pub fn admitRetry(self: *NativeTurn) execution_turn.Admission {
        const slot = self.firstFreeSlot() orelse return .no_work;
        const active_slots = ActiveSlots{ .slots = self.slots };
        const active_filter = store_module.ActiveOperationFilter{
            .context = &active_slots,
            .containsFn = activeOperationContains,
            .maximum_exclusions = self.slots.len,
        };
        return switch (admitRetryAttempt(
            self.host,
            slot,
            active_filter,
            self.model_preparation,
        )) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
        };
    }

    pub fn admitNewModel(self: *NativeTurn) execution_turn.Admission {
        return self.admitModel(.message);
    }

    pub fn admitToolContinuation(self: *NativeTurn) execution_turn.Admission {
        return self.admitModel(.tool_continuation);
    }

    fn admitModel(self: *NativeTurn, kind: store_module.ModelAdmissionKind) execution_turn.Admission {
        const slot = self.firstFreeSlot() orelse return .no_work;
        return switch (admitNewAttempt(
            self.host,
            slot,
            kind,
            self.model_preparation,
        )) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
        };
    }

    pub fn driveTransport(self: *NativeTurn) error{Fence}!void {
        self.reactor.?.drive(0) catch |err| {
            fenceDispatch(self.host, "transport reactor", err);
            self.fenced = true;
            return error.Fence;
        };
        observeUnprocessedCompletions(self.host, self.reactor.?);
    }

    pub fn serviceOneCompletion(self: *NativeTurn) bool {
        return callServiceOneCompletion(self.host, self.reactor, self.slots, self.next_receive_slot);
    }

    pub fn modelPreparationAllowance(self: *const NativeTurn) execution_turn.Allowance {
        return .{
            .bytes = self.host.limits.request_preparation_byte_allowance,
            .items = self.host.limits.request_preparation_item_allowance,
        };
    }

    pub fn advanceModelPreparation(self: *NativeTurn, byte_allowance: usize, item_allowance: usize) bool {
        return callAdvanceModelPreparation(
            self.host,
            self.reactor,
            self.slots,
            self.model_preparation,
            byte_allowance,
            item_allowance,
        );
    }
};

const callServiceOneCompletion = serviceOneCompletion;
const callAdvanceBashPreparation = advanceBashPreparation;
const callAdvanceModelPreparation = advanceModelPreparation;
const callAdvanceRetainedCleanup = advanceRetainedCleanup;
const slotsHaveTransport = hasTransport;
const slotsHaveBash = hasBash;

fn serviceOneCompletion(host: *Host, reactor: ?*provider.Reactor, slots: []ExecutionSlot, next_receive_slot: *usize) bool {
    const active_reactor = reactor orelse return false;
    for (slots) |*slot| switch (slot.*) {
        .provider => if (advanceModelFinalization(host, slot, host.faults.response_seal)) return true,
        else => {},
    };
    const active_transfers = ActiveSlots{ .slots = slots };
    const completed = active_reactor.nextCompletion(.{
        .context = &active_transfers,
        .find_fn = findActiveTransfer,
    }) catch |err| {
        fenceDispatch(host, "transport completion", err);
        return false;
    };
    if (completed) return true;
    return advanceOneTransfer(host, active_reactor, slots, next_receive_slot);
}

fn advanceOneTransfer(host: *Host, reactor: anytype, slots: []ExecutionSlot, next_receive_slot: *usize) bool {
    // This thread is the sole producer. Freeze readiness for the scan so a
    // worker drain cannot let a later slot bypass an earlier paused one.
    const resume_allowed = host.capture_writer.?.hasRoom();
    for (0..slots.len) |offset| {
        const index = (next_receive_slot.* + offset) % slots.len;
        const slot = &slots[index];
        switch (slot.*) {
            .provider => |*active| {
                const progress = reactor.advance(&active.transfer, resume_allowed, &host.faults.response_write_on_resume) catch |err| {
                    fenceDispatch(host, "transport advance", err);
                    return false;
                };
                switch (progress) {
                    .progressed, .resume_capture_failure => {
                        next_receive_slot.* = (index + 1) % slots.len;
                        if (progress == .resume_capture_failure)
                            traceSubject(host, "transport_resume_capture_failure", "cause", "local_capture");
                        return true;
                    },
                    .not_ready => {},
                }
            },
            else => {},
        }
    }
    return false;
}

test "receive advancement serves paused siblings across recurring queue pressure" {
    const RecordingReactor = struct {
        slots: []ExecutionSlot,
        writer: *provider.CaptureWriter,
        selected: ?usize = null,
        drain_during_scan: bool = false,

        fn advance(self: *@This(), transfer: *provider.Transfer, resume_allowed: bool, _: *bool) error{}!provider.Reactor.Advance {
            // A worker may release space just after a paused candidate was
            // examined. That must not let a later candidate bypass it.
            if (self.drain_during_scan) {
                self.writer.count = 0;
                self.drain_during_scan = false;
            }
            if (!resume_allowed) return .not_ready;
            for (self.slots, 0..) |*slot, index| {
                if (slot.* == .provider and &slot.provider.transfer == transfer) {
                    self.selected = index;
                    self.writer.count = 16;
                    return .progressed;
                }
            }
            unreachable;
        }
    };
    var writer = provider.CaptureWriter{ .io = std.testing.io };
    var host: Host = undefined;
    host.capture_writer = &writer;
    host.faults = .{};
    var slots = [_]ExecutionSlot{ .{ .provider = .{ .owner = .{} } }, .free, .{ .provider = .{ .owner = .{} } } };
    var reactor = RecordingReactor{ .slots = &slots, .writer = &writer };
    var next: usize = 0;
    for ([_]usize{ 0, 2, 0, 2 }) |expected| {
        writer.count = 0;
        try std.testing.expect(advanceOneTransfer(&host, &reactor, &slots, &next));
        try std.testing.expectEqual(expected, reactor.selected.?);
    }
    next = 2;
    reactor.selected = null;
    reactor.drain_during_scan = true;
    try std.testing.expectEqual(false, advanceOneTransfer(&host, &reactor, &slots, &next));
    try std.testing.expectEqual(@as(?usize, null), reactor.selected);
    try std.testing.expectEqual(@as(usize, 2), next);
    try std.testing.expect(advanceOneTransfer(&host, &reactor, &slots, &next));
    try std.testing.expectEqual(@as(usize, 2), reactor.selected.?);
    slots[2] = .free;
    writer.count = 0;
    try std.testing.expect(advanceOneTransfer(&host, &reactor, &slots, &next));
    try std.testing.expectEqual(@as(usize, 0), reactor.selected.?);
    try std.testing.expect(!advanceOneTransfer(&host, &reactor, &.{}, &next));
}

fn advanceModelFinalization(host: *Host, slot: *ExecutionSlot, fail_seal: bool) bool {
    const active = &slot.provider;
    switch (active.transfer.advanceFinalization(fail_seal)) {
        .pending => return false,
        .discarded => {
            const token = active.owner.token;
            active.transfer.deinit();
            finishCustodyNow(host, slot, token);
        },
        .ready => |finished| completeTransfer(host, slot, finished),
    }
    return true;
}

fn cancelSupersededTransfers(
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *model_adapter.Preparation,
) void {
    for (slots) |*slot| switch (slot.*) {
        .model_preparing => |active| {
            const superseded = host.store.operationSupersededByControl(active.binding) catch |err| {
                fenceDispatch(host, "preparation control reconciliation", err);
                return;
            };
            const control = superseded orelse continue;
            traceOperationControl(host, "effect_stop_requested", control.command_key.slice(), active.binding);
            preparation.cancel();
            finishCustodyNow(host, slot, active.token);
        },
        .model_authenticating => |*active| {
            if (active.cancelled) continue;
            const superseded = host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                fenceDispatch(host, "authentication control reconciliation", err);
                return;
            };
            if (superseded) |control| {
                traceOperationControl(host, "effect_stop_requested", control.command_key.slice(), active.owner.binding);
                active.cancelled = true;
            }
        },
        .provider => |*active| {
            if (active.transfer.isDiscarded()) continue;
            const superseded = host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                fenceDispatch(host, "control reconciliation", err);
                return;
            };
            const control = superseded orelse continue;
            const owner = active.owner;
            traceOperationControl(host, "effect_stop_requested", control.command_key.slice(), owner.binding);
            reactor.?.discard(&active.transfer);
            _ = advanceModelFinalization(host, slot, false);
        },
        .free, .bash_preparing, .bash, .bash_prepared_cleanup, .named_scratch => {},
    };
}

fn countFreeSlots(slots: []const ExecutionSlot) usize {
    var free: usize = 0;
    for (slots) |slot| {
        if (slot == .free) free += 1;
    }
    return free;
}

fn slotIsFree(slot: *const ExecutionSlot) bool {
    return slot.* == .free;
}

const ActiveSlots = struct {
    slots: []ExecutionSlot,
};

fn activeOperationContains(context: *const anyopaque, operation_id: u64) bool {
    const active: *const ActiveSlots = @ptrCast(@alignCast(context));
    for (active.slots) |slot| switch (slot) {
        .provider => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .model_preparing => |value| if (value.binding.operation_id == operation_id) return true,
        .model_authenticating => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .free, .bash_preparing, .bash, .bash_prepared_cleanup, .named_scratch => {},
    };
    return false;
}

fn activeActionContains(context: *const anyopaque, action_id: u64) bool {
    const active: *const ActiveSlots = @ptrCast(@alignCast(context));
    for (active.slots) |slot| switch (slot) {
        .bash_preparing => |value| if (value.binding.action_id == action_id) return true,
        .bash => |value| if (value.binding.action_id == action_id) return true,
        else => {},
    };
    return false;
}

fn advanceBash(host: *Host, slots: []ExecutionSlot, window: []u8) bool {
    var made_progress = false;
    for (slots) |*slot| switch (slot.*) {
        .bash => |*active| {
            const service = active.execution.service(window);
            made_progress = made_progress or service.made_progress;
            if (service.timeout_action) |action| {
                traceActionDeadline(host, "bash_deadline_serviced", action.deadline_ns, action.signal_failed, active.binding);
            }
            if (service.leader_observed_with_open_pipes) {
                traceAction(host, "bash_leader_observed_with_open_pipes", active.binding);
                if (host.faults.bash_observed_exit_gate_path) |path| waitAtTestGate(host, path);
            }
            if (service.fault) |err| {
                made_progress = failBash(host, active, "Bash process service", err) or made_progress;
            }
            if (active.delivery == .open and service.retired) {
                completeBash(host, active);
                made_progress = true;
            }
            if (active.delivery == .closed and service.retired) {
                const closed = &active.delivery.closed;
                const now = std.Io.Clock.Timestamp.now(host.io, .awake);
                if (now.raw.nanoseconds >= closed.reclaim_at.raw.nanoseconds) {
                    made_progress = reclaimBash(host, slot, now) or made_progress;
                }
            }
        },
        else => {},
    };
    return made_progress;
}

fn admitBashAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    preparation: *?bash.Preparation,
) AdmissionProgress {
    std.debug.assert(preparation.* == null);
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.admitNextActionAttempt(host.bash_timeout_ms, .{
        .attempt_before_commit = host.faults.attempt_before_commit,
    }) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "Bash Attempt admission", err);
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    const action_binding = host.custody.attachAction(token, &admission.permit) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "Bash custody attachment", err);
        return .admitted;
    };
    testTransition(host, .action_attempt_admitted, action_binding);
    const input = host.store.readBashExecutionInput(action_binding) catch |err| {
        settleActionFailure(host, token, action_binding, .storage_failed, "Bash input could not be read.");
        finishCustodyNow(host, slot, token);
        if (host.store.isFenced()) fenceDispatch(host, "Bash canonical input", err);
        return .admitted;
    };
    const arguments = host.store.openContent(input.arguments) catch |err| {
        settleActionFailure(host, token, action_binding, .storage_failed, "Bash input could not be opened.");
        finishCustodyNow(host, slot, token);
        fenceDispatch(host, "Bash canonical input", err);
        return .admitted;
    };
    const bash_budget = host.retention.sharedBudget().narrowed(host.limits.bash_scratch_limit_bytes);
    const started = bash.startPreparation(
        host.io,
        host.allocator,
        arguments,
        input.arguments.length,
        input.session,
        host.lease.paths.store.slice(),
        input.workspace,
        host.lease.paths.scratch.slice(),
        host.bash_path,
        input.timeout_ms,
        bash_budget,
        action_binding.action_id,
        action_binding.attempt_ordinal,
        .{
            .preparation = host.faults.bash_preparation,
            .preparation_after_captures = host.faults.bash_preparation_after_captures,
            .spawn = host.faults.bash_spawn,
            .service = host.faults.bash_service,
            .capture_read = host.faults.bash_capture_read,
            .capture_write = host.faults.bash_capture_write,
            .seal = host.faults.bash_seal,
            .cleanup = host.faults.bash_cleanup,
            .lifecycle = host.faults.bash_lifecycle_fault,
            .fault_gated = host.faults.bash_fault_gated,
        },
    );
    switch (started) {
        .preparing => |value| {
            preparation.* = value;
            slot.* = .{ .bash_preparing = .{
                .token = token,
                .binding = action_binding,
            } };
        },
        .failed => |value| {
            var failure = value;
            finishBashPreparationFailure(host, slot, token, action_binding, &failure);
        },
    }
    return .admitted;
}

fn advanceBashPreparation(
    host: *Host,
    slots: []ExecutionSlot,
    preparation: *?bash.Preparation,
) bool {
    const active_preparation = if (preparation.*) |*value| value else return false;
    const slot = for (slots) |*candidate| switch (candidate.*) {
        .bash_preparing => break candidate,
        else => {},
    } else unreachable;
    const preparing = slot.bash_preparing;
    if (!host.launchAllowed()) {
        const cleanup = active_preparation.cancel();
        preparation.* = null;
        discardBashResources(host, slot, preparing.token, cleanup);
        return true;
    }
    switch (active_preparation.advance()) {
        .pending => return true,
        .failed => |value| {
            var failure = value;
            preparation.* = null;
            finishBashPreparationFailure(
                host,
                slot,
                preparing.token,
                preparing.binding,
                &failure,
            );
        },
        .prepared => |value| {
            var prepared = value;
            preparation.* = null;
            launchPreparedBash(host, slot, preparing.token, preparing.binding, &prepared);
        },
    }
    return true;
}

fn finishBashPreparationFailure(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    binding: store_module.ActionAttemptBinding,
    failure: *bash.PreparationFailure,
) void {
    const canonical_failure = failure.cause == error.InvalidCanonicalBashDescriptor or
        failure.cause == error.ShortCanonicalRead;
    if (failure.cause == error.BashCommandTooLong) {
        settleActionFailure(host, token, binding, .spawn_failed, std.fmt.comptimePrint(
            "Bash was not started: the decoded command exceeds {d} bytes. Split long content across several smaller commands.",
            .{bash.max_command_bytes},
        ));
    } else if (!canonical_failure) {
        settleActionFailure(host, token, binding, .storage_failed, "Bash preparation failed.");
    }
    failure.cleanup.cleanup() catch |cleanup_err| {
        retainBashPreparedCleanup(host, slot, token, failure.cleanup, cleanup_err);
        return;
    };
    finishCustodyNow(host, slot, token);
    if (canonical_failure or host.store.isFenced()) {
        fenceDispatch(host, "Bash canonical preparation", failure.cause);
    }
}

// Discarding an unlaunched effect changes only local custody. In particular,
// infrastructure suppression is not a user stop or a saved Action result.
fn discardBashResources(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    resources: bash.PreparedCleanup,
) void {
    var cleanup = resources;
    cleanup.cleanup() catch |err| {
        retainBashPreparedCleanup(host, slot, token, cleanup, err);
        return;
    };
    finishCustodyNow(host, slot, token);
}

fn launchPreparedBash(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    action_binding: store_module.ActionAttemptBinding,
    prepared: *bash.Prepared,
) void {
    testTransition(host, .prepared_before_handoff, action_binding);
    if (host.faults.before_launch_delay_ms != 0) {
        traceAction(host, "prepared_before_handoff", action_binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_launch_delay_ms), .awake) catch {};
    }
    if (!host.launchAllowed()) {
        discardBashResources(host, slot, token, prepared.takeCleanup());
        return;
    }
    host.custody.consumeActionLaunchAuthority(token, action_binding) catch |err| {
        discardBashResources(host, slot, token, prepared.takeCleanup());
        fenceDispatch(host, "Bash launch authority", err);
        return;
    };
    var launched: ?bash.Execution = null;
    host.store.withActionDispatchHandoff(action_binding, .{
        .host = host,
        .prepared = prepared,
        .launched = &launched,
    }, struct {
        fn handoff(context: anytype) !void {
            try context.host.withEffectLaunch(context, launch);
        }

        fn launch(context: anytype) !void {
            context.launched.* = try context.prepared.launch(context.host.bash_environment);
        }
    }.handoff) catch |err| {
        if (err == error.SupersededByControl) {
            settleActionFailure(host, token, action_binding, .cancelled, "Bash was stopped before launch.");
        } else if (err == error.BashSpawnFailed) {
            settleActionFailure(host, token, action_binding, .spawn_failed, "Bash process creation failed.");
        } else if (err != error.HostDispatchSuppressed) {
            fenceDispatch(host, "Bash dispatch handoff", err);
        }
        discardBashResources(host, slot, token, prepared.takeCleanup());
        return;
    };
    slot.* = .{ .bash = .{
        .token = token,
        .binding = action_binding,
        .execution = launched.?,
    } };
    traceAction(host, "bash_handoff_committed", action_binding);
    const deadline_ns = slot.bash.execution.deadlineNs();
    traceActionDeadline(host, "bash_deadline_established", deadline_ns, false, action_binding);
}

fn stopSupersededBash(
    host: *Host,
    slots: []ExecutionSlot,
    preparation: *?bash.Preparation,
) void {
    for (slots) |*slot| switch (slot.*) {
        .bash_preparing => |active| {
            const stopped = host.store.actionSupersededByStop(active.binding) catch |err| {
                fenceDispatch(host, "Bash stop reconciliation", err);
                return;
            };
            const control = stopped orelse continue;
            traceActionControl(host, "effect_stop_requested", control.command_key.slice(), active.binding);
            var cleanup = preparation.*.?.cancel();
            preparation.* = null;
            settleActionFailure(host, active.token, active.binding, .cancelled, "Bash was stopped before launch.");
            cleanup.cleanup() catch |cleanup_err| {
                retainBashPreparedCleanup(host, slot, active.token, cleanup, cleanup_err);
                continue;
            };
            finishCustodyNow(host, slot, active.token);
        },
        .bash => |*active| {
            const stopped = host.store.actionSupersededByStop(active.binding) catch |err| {
                fenceDispatch(host, "Bash stop reconciliation", err);
                return;
            };
            if (stopped) |control| {
                if (!active.stop_accepted) {
                    active.stop_accepted = true;
                    traceActionControl(host, "effect_stop_requested", control.command_key.slice(), active.binding);
                    const action = active.execution.requestStop(.now(host.io, .awake));
                    traceActionControlOutcome(
                        host,
                        "lifecycle_action_attempted",
                        control.command_key.slice(),
                        action.attempted,
                        action.signal_failed,
                        active.binding,
                    );
                }
            }
        },
        else => {},
    };
}

fn completeBash(host: *Host, active: *BashSlot) void {
    const token = active.token;
    const binding = active.binding;
    const include_paths = active.execution.reserveOutput(host.retention) catch |err| {
        _ = failBash(host, active, "Bash output reservation", err);
        return;
    };
    const outcome = active.execution.outcome(include_paths) catch |err| {
        active.execution.releaseOutputReservation(host.retention);
        _ = failBash(host, active, "Bash outcome materialization", err);
        return;
    };
    if (host.faults.before_result_delay_ms != 0) {
        traceAction(host, "sealed_before_settlement", binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_result_delay_ms), .awake) catch {};
    }
    testTransition(host, .action_result_ready, binding);
    if (host.custody.claimTerminalDelivery(token)) {
        const settlement = host.store.settleActionAttempt(binding, outcome.code, outcome.text(), .{
            .content_import = host.faults.content_import,
            .before_commit = host.faults.result_before_commit,
        }) catch |err| {
            active.execution.releaseOutputReservation(host.retention);
            _ = failBash(host, active, "Bash result settlement", err);
            return;
        };
        testTransition(host, .action_result_committed, binding);
        if (settlement == .session_stop) active.execution.releaseOutputReservation(host.retention);
    } else active.execution.releaseOutputReservation(host.retention);
    closeBashDelivery(host, active);
}

fn failBash(host: *Host, active: *BashSlot, phase: []const u8, err: anyerror) bool {
    var closed = false;
    if (active.delivery == .open) {
        active.execution.releaseOutputReservation(host.retention);
        closeBashDelivery(host, active);
        closed = true;
    }
    fenceDispatch(host, phase, err);
    return closed;
}

fn closeBashDelivery(host: *Host, active: *BashSlot) void {
    std.debug.assert(active.delivery == .open);
    host.custody.detach(active.token) catch unreachable;
    traceAction(host, "cleanup_started", active.binding);
    active.delivery = .{ .closed = .{ .reclaim_at = .now(host.io, .awake) } };
}

fn reclaimBash(host: *Host, slot: *ExecutionSlot, now: std.Io.Clock.Timestamp) bool {
    const active = &slot.bash;
    if (host.faults.bash_cleanup_gate_path) |path| {
        if (testGateActive(host, path)) {
            active.delivery.closed.reclaim_at = now.addDuration(.{
                .raw = .fromMilliseconds(100),
                .clock = .awake,
            });
            return false;
        }
        // A released gate is one owner transition, not reclamation retry history.
        // reclaim_failed already remembers whether this owner attempted reclaim.
        if (!active.delivery.closed.reclaim_failed)
            traceAction(host, "cleanup_release_observed", active.binding);
    }
    active.execution.reclaim(host.retention) catch |err| {
        const first_failure = !active.delivery.closed.reclaim_failed;
        active.delivery.closed.reclaim_failed = true;
        active.delivery.closed.reclaim_at = now.addDuration(.{
            .raw = .fromMilliseconds(100),
            .clock = .awake,
        });
        if (first_failure) retainDispatchFence(host, "Bash resource reclamation", err);
        return first_failure;
    };
    const token = active.token;
    const binding = active.binding;
    host.custody.cleanupComplete(token) catch unreachable;
    slot.* = .free;
    traceAction(host, "cleanup_completed", binding);
    return true;
}

fn retainBashPreparedCleanup(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    cleanup: bash.PreparedCleanup,
    err: anyerror,
) void {
    host.custody.detach(token) catch unreachable;
    slot.* = .{ .bash_prepared_cleanup = .{
        .token = token,
        .cleanup = cleanup,
    } };
    retainDispatchFence(host, "Bash preparation cleanup", err);
}

fn settleActionFailure(
    host: *Host,
    token: execution.CustodyToken,
    binding: store_module.ActionAttemptBinding,
    code: store_module.ActionResolutionCode,
    result: []const u8,
) void {
    if (!host.custody.claimTerminalDelivery(token)) return;
    _ = host.store.settleActionAttempt(binding, code, result, .{
        .content_import = host.faults.content_import,
        .before_commit = host.faults.result_before_commit,
    }) catch |err| {
        fenceDispatch(host, "Bash failure settlement", err);
        return;
    };
}

fn findActiveTransfer(
    context: *const anyopaque,
    handle: provider.TransportHandleIdentity,
) ?*provider.Transfer {
    const active: *const ActiveSlots = @ptrCast(@alignCast(context));
    for (active.slots) |*slot| {
        switch (slot.*) {
            .provider => |*value| if (value.transfer.matchesHandle(handle)) return &value.transfer,
            else => {},
        }
    }
    return null;
}

fn admitNewAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    kind: store_module.ModelAdmissionKind,
    preparation: *model_adapter.Preparation,
) AdmissionProgress {
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.admitModelAttempt(kind, .{
        .attempt_before_commit = host.faults.attempt_before_commit,
    }) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "Attempt admission", err);
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    return beginAdmittedAttempt(host, slot, token, &admission.permit, preparation);
}

fn admitRetryAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    active: store_module.ActiveOperationFilter,
    preparation: *model_adapter.Preparation,
) AdmissionProgress {
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.tryAdmitNextModelRetry(
        active,
        .{ .attempt_before_commit = host.faults.attempt_before_commit },
    ) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "retry Attempt admission", err);
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    return beginAdmittedAttempt(host, slot, token, &admission.permit, preparation);
}

fn beginAdmittedAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    permit: *store_module.DispatchPermit,
    preparation: *model_adapter.Preparation,
) AdmissionProgress {
    std.debug.assert(slot.* == .free);
    const binding = host.custody.attach(token, permit) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "custody attachment", err);
        return .admitted;
    };
    slot.* = .{ .model_preparing = .{ .token = token, .binding = binding } };
    const view = host.store.openHistoricalView(binding) catch |err| {
        if (err == error.SupersededByControl) {
            finishCustodyNow(host, slot, token);
            return .admitted;
        }
        fenceDispatch(host, "historical view", err);
        finishCustodyNow(host, slot, token);
        return .admitted;
    };
    const request_budget = host.retention.sharedBudget().narrowed(
        if (host.faults.request_scratch_acquire) 0 else host.limits.request_scratch_limit_bytes,
    );
    var retained_scratch: ?named_scratch.Owner = null;
    preparation.init(
        host.io,
        view,
        host.lease.paths.scratch.slice(),
        request_budget,
        .{
            .managed_route = host.authentication != null,
            .first_step = host.faults.request_first_step,
            .write = host.faults.request_write,
            .seal = host.faults.request_seal,
            .unlink = host.faults.request_unlink,
        },
        &retained_scratch,
    ) catch |err| {
        finishModelPreparationFailure(host, slot, slot.model_preparing, err, retained_scratch);
        return .admitted;
    };
    traceOperation(host, "preparation_started", binding);
    return .admitted;
}

fn advanceModelPreparation(
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *model_adapter.Preparation,
    byte_allowance: usize,
    item_allowance: usize,
) bool {
    if (host.auth_worker != null) {
        for (slots) |*slot| if (slot.* == .model_authenticating)
            return advanceAuthentication(host, reactor.?, slot);
    }
    const slot = for (slots) |*candidate| switch (candidate.*) {
        .model_preparing => break candidate,
        else => {},
    } else return false;
    const owner = slot.model_preparing;
    if (execution.modelDecision(.{ .preparing = .{ .launch_allowed = host.launchAllowed() } }) == .abandon) {
        preparation.cancel();
        // Infrastructure fencing does not invent a user stop or a Resolution.
        finishCustodyNow(host, slot, owner.token);
        return true;
    }
    traceOperation(host, "preparation_advance_started", owner.binding);
    const progress = preparation.advance(byte_allowance, item_allowance);
    const stats = preparation.advanceStats();
    switch (progress) {
        .pending => {
            tracePreparationAdvance(host, "preparation_advance_completed", stats, owner.binding);
            if (host.faults.request_preparation_advance_delay_ms != 0) {
                _ = host.io.sleep(.fromMilliseconds(host.faults.request_preparation_advance_delay_ms), .awake) catch {};
            }
        },
        .failed => |err| {
            tracePreparationAdvanceError(host, "preparation_advance_failed", err, stats, owner.binding);
            preparation.cancel();
            finishModelPreparationFailure(host, slot, owner, err, null);
        },
        .prepared => |value| {
            tracePreparationAdvance(host, "preparation_advance_completed", stats, owner.binding);
            traceOperation(host, "preparation_completed", owner.binding);
            var request = value;
            switch (execution.modelDecision(.{ .prepared = .{ .authentication_required = host.auth_worker != null } })) {
                .authenticate => {
                    slot.* = .{ .model_authenticating = .{ .owner = owner, .request = request } };
                    host.auth_worker.?.request();
                },
                .launch => launchPreparedRequest(host, reactor.?, slot, owner, &request, null),
                else => unreachable,
            }
        },
    }
    return true;
}

fn advanceAuthentication(host: *Host, reactor: *provider.Reactor, slot: *ExecutionSlot) bool {
    const worker = host.auth_worker.?;
    const result = worker.take();
    const active = &slot.model_authenticating;
    const decision = execution.modelDecision(.{ .authenticating = .{
        .cancelled = active.cancelled,
        .launch_allowed = host.launchAllowed(),
        .result = if (result) |value| (if (value == .ready) .ready else .failed) else .pending,
    } });
    if (decision == .wait) return false;
    defer if (result.? == .ready) worker.finish();
    const owner = active.owner;
    var request = active.request;
    switch (decision) {
        .launch => launchPreparedRequest(host, reactor, slot, owner, &request, result.?.ready),
        .abandon, .settle_authentication_failure => {
            request.deinit();
            if (decision == .settle_authentication_failure)
                settleUnansweredFailure(host, owner.token, owner.binding, model_adapter.authenticationFailureCode(result.?.failed), .ordinary);
            finishCustodyNow(host, slot, owner.token);
        },
        else => unreachable,
    }
    return true;
}

fn finishModelPreparationFailure(
    host: *Host,
    slot: *ExecutionSlot,
    owner: ModelPreparingSlot,
    err: anyerror,
    retained_scratch: ?named_scratch.Owner,
) void {
    switch (execution.modelDecision(.{ .preparation_failed = .{
        .retained_scratch = retained_scratch != null,
        .canonical_fenced = retained_scratch == null and host.store.isFenced(),
        .superseded = err == error.SupersededByControl,
    } })) {
        .retain_cleanup => {
            host.custody.detach(owner.token) catch unreachable;
            slot.* = .{ .named_scratch = .{ .token = owner.token, .owner = retained_scratch.? } };
            retainDispatchFence(host, "request scratch unlink", err);
            return;
        },
        .fence => fenceDispatch(host, "canonical request read", err),
        .settle_preparation_failure => settleUnansweredFailure(host, owner.token, owner.binding, model_adapter.preparationFailureCode(err), .ordinary),
        .abandon => {},
        else => unreachable,
    }
    finishCustodyNow(host, slot, owner.token);
}

fn launchPreparedRequest(
    host: *Host,
    reactor: *provider.Reactor,
    slot: *ExecutionSlot,
    owner: ModelPreparingSlot,
    request: *provider.PreparedRequest,
    credential: ?*const model_adapter.Credential,
) void {
    const token = owner.token;
    const binding = owner.binding;
    if (!host.launchAllowed()) {
        request.deinit();
        finishCustodyNow(host, slot, token);
        return;
    }
    const request_budget = host.retention.sharedBudget().narrowed(
        if (host.faults.request_scratch_acquire) 0 else host.limits.request_scratch_limit_bytes,
    );
    var retained_response: ?named_scratch.Owner = null;
    if (host.faults.provider_prepare) {
        request.deinit();
        settleUnansweredFailure(host, token, binding, "provider_transport_failure", failureClass(host, .temporary, null, null));
        finishCustodyNow(host, slot, token);
        return;
    }
    var headers: model_adapter.Headers = .{};
    defer headers.deinit();
    if (credential) |value| {
        headers.init(host.provider_endpoint.?, host.provider_ca_file, host.authentication.?, value, request.session_affinity) catch |err| {
            request.deinit();
            fenceDispatch(host, "provider preparation", err);
            finishCustodyNow(host, slot, token);
            return;
        };
    }
    // Transfer.start gives curl pointers into the Transfer, so construct it in
    // its final slot and keep that union arm active through removal and deinit.
    slot.* = .{ .provider = .{
        .owner = .{ .token = token, .binding = binding },
        .transfer = undefined,
    } };
    const active = &slot.provider;
    active.transfer.start(host.provider_endpoint.?, request.*, binding, .{
        .ca_file = host.provider_ca_file,
        .extra_headers = headers.slice(),
        .observation_names = model_adapter.observation_names,
        .inactivity_seconds = @intCast(host.limits.provider_inactivity_seconds),
        .request_read_fault = host.faults.request_read,
        .response_acquire_fault = host.faults.response_acquire,
        .response_unlink_fault = host.faults.response_unlink,
        .response_write_fault = host.faults.response_write,
        .completion_identity_fault = host.faults.completion_identity_fault,
    }, host.capture_writer.?, host.lease.paths.scratch.slice(), request_budget, &retained_response) catch |err| {
        request.deinit();
        if (retained_response) |retained| {
            host.custody.detach(token) catch unreachable;
            slot.* = .{ .named_scratch = .{
                .token = token,
                .owner = retained,
            } };
            retainDispatchFence(host, "response scratch unlink", err);
            return;
        }
        stderr.print("rui: provider preparation failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        if (err == error.ResponseCaptureAcquisitionFailed) {
            settleUnansweredFailure(host, token, binding, "response_capture_failed", .ordinary);
        } else {
            fenceDispatch(host, "provider preparation", err);
        }
        finishCustodyNow(host, slot, token);
        return;
    };
    if (host.faults.before_launch_delay_ms != 0) {
        traceOperation(host, "prepared_before_handoff", binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_launch_delay_ms), .awake) catch {};
    }
    host.custody.consumeLaunchAuthority(token, binding) catch |err| {
        active.transfer.deinit();
        stderr.print("rui: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        fenceDispatch(host, "dispatch handoff", err);
        finishCustodyNow(host, slot, token);
        return;
    };
    host.store.withDispatchHandoff(
        binding,
        .{ .host = host, .reactor = reactor, .transfer = &active.transfer },
        struct {
            fn handoff(context: anytype) !void {
                try context.host.withEffectLaunch(context, launch);
            }

            fn launch(context: anytype) !void {
                try context.reactor.add(context.transfer);
            }
        }.handoff,
    ) catch |err| {
        active.transfer.deinit();
        switch (execution.modelDecision(.{ .handoff_failed = if (err == error.HostDispatchSuppressed)
            .suppressed
        else if (err == error.SupersededByControl)
            .superseded
        else
            .unexpected })) {
            .abandon => if (err == error.SupersededByControl) {
                traceOperation(host, "canonical_handoff_superseded", binding);
            },
            .fence => {
                stderr.print("rui: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
                fenceDispatch(host, "dispatch handoff", err);
            },
            else => unreachable,
        }
        finishCustodyNow(host, slot, token);
        return;
    };
    traceOperation(host, "transport_handoff_committed", binding);
}

fn completeTransfer(
    host: *Host,
    slot: *ExecutionSlot,
    completion: provider.Completion,
) void {
    const active = &slot.provider;
    const owner = active.owner;
    traceCompletionQueue(host, completion.queued_after, owner.binding);
    defer traceOperation(host, "provider_completion_serviced", owner.binding);
    if (host.authentication != null and host.faults.test_phase_trace) {
        var publication = beginTestObservation(host, "codex_transfer", null);
        defer if (publication) |*value| value.finish();
        const observation = active.transfer.protocolObservation();
        const correlation = active.transfer.requestId();
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(correlation, &digest, .{});
        var trace: protocol.ResponseBuffer = .{};
        trace.appendFmt("{{\"rui_test_phase\":\"codex_transfer\",\"operation\":\"{d}\",\"http_version\":{d},\"connection_id\":{d},\"new_connections\":{d},\"correlation_present\":{s},\"correlation_sha256\":\"{x}\",\"alpn\":\"unavailable\"}}", .{
            owner.binding.operation_id,
            observation.http_version,
            observation.connection_id,
            observation.new_connections,
            if (correlation.len != 0) "true" else "false",
            digest,
        }) catch unreachable;
        writeTestTrace(host, &trace, &publication);
    }
    var error_response: execution.ErrorResponse = .ordinary;
    switch (completion.outcome) {
        .transport_finished => |evidence| if (evidence.disposition.answered()) {
            // The transport has sealed this HTTP answer. Interpretation
            // borrows it; this owner still disposes it before settlement.
            var response = active.transfer.takeResponse();
            defer response.deinit();
            error_response = model_adapter.interpretErrorResponse(host.io, response.file, response.length, evidence.http_status);
            if (error_response == .unreadable) stderr.print("rui: provider error capture unreadable for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(error_response.unreadable) });
        },
        else => {},
    }
    switch (execution.transferDecision(completion.outcome, error_response)) {
        .interpret_output => {
            switch (completeSuccessfulTransfer(host, active)) {
                .cleanup => finishCustodyNow(host, slot, owner.token),
                .named_scratch => |scratch| {
                    host.custody.detach(owner.token) catch unreachable;
                    slot.* = .{ .named_scratch = .{
                        .token = owner.token,
                        .owner = scratch,
                    } };
                },
            }
            return;
        },
        .fence_request_source => fenceDispatch(host, "request scratch read", error.RequestScratchReadFailed),
        .fail => |failure| {
            var code_buffer: [96]u8 = undefined;
            const code = failure.codeText(&code_buffer);
            const disposition = failureClass(host, failure.kind, failure.retry_after_ms, failure.retry_after_deadline_ms);
            if (failure.answered) {
                const answered: AnsweredAttempt = .init(host, owner, &active.transfer);
                answered.fail(code, disposition);
            } else {
                settleUnansweredFailure(host, owner.token, owner.binding, code, disposition);
            }
        },
    }
    active.transfer.deinit();
    finishCustodyNow(host, slot, owner.token);
}

fn failureClass(
    host: *const Host,
    kind: execution.FailureKind,
    retry_after_ms: ?u64,
    retry_after_deadline_ms: ?i64,
) store_module.ModelFailureClass {
    return switch (kind) {
        .permanent => .ordinary,
        .context_overflow => .context_overflow,
        .temporary => .{ .retryable = .{
            .waits_ms = host.limits.retry_waits_ms,
            .retry_after_ms = retry_after_ms,
            .retry_after_deadline_ms = retry_after_deadline_ms,
        } },
    };
}

const SuccessfulCompletion = union(enum) {
    cleanup,
    named_scratch: named_scratch.Owner,
};

fn completeSuccessfulTransfer(host: *Host, active: *ProviderSlot) SuccessfulCompletion {
    const owner = active.owner;
    const structured_output = active.transfer.hasStructuredOutput();
    const answered: AnsweredAttempt = .init(host, owner, &active.transfer);
    var openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    openai_model.set(active.transfer.observedModel()) catch unreachable;
    var x_openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    x_openai_model.set(active.transfer.observedAlternateModel()) catch unreachable;
    var response = active.transfer.takeResponse();
    active.transfer.deinit();
    defer response.deinit();
    if (model_adapter.outputSchemaRejection(structured_output, response.length)) |rejection| {
        var detail: [512]u8 = undefined;
        answered.reject(rejection.code, rejection.format(&detail), .ordinary);
        return .cleanup;
    }

    var metadata_name_buffer: [96]u8 = undefined;
    const metadata_name = std.fmt.bufPrint(&metadata_name_buffer, "response-metadata-{d}-{d}.tmp", .{
        owner.binding.operation_id,
        owner.binding.attempt_ordinal,
    }) catch unreachable;
    var retained_metadata: ?named_scratch.Owner = null;
    const metadata_budget = host.retention.sharedBudget().narrowed(host.limits.request_scratch_limit_bytes);
    var metadata = output_format.OutputMetadataWriter.init(
        host.io,
        host.lease.paths.scratch.slice(),
        metadata_name,
        metadata_budget,
        host.faults.response_metadata_unlink,
        &retained_metadata,
    ) catch |err| {
        if (retained_metadata) |retained| {
            retainDispatchFence(host, "response metadata unlink", err);
            return .{ .named_scratch = retained };
        }
        stderr.print("rui: response metadata acquisition failed for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        answered.fail("response_metadata_exhausted", .ordinary);
        return .cleanup;
    };
    defer metadata.deinit();
    traceOperation(host, "validation_started", owner.binding);
    const operation = host.store.modelOperationKind(owner.binding) catch |err| {
        if (err != error.SupersededByControl) fenceDispatch(host, "model operation purpose", err);
        return .cleanup;
    };
    const accepted = switch (model_adapter.interpretOutput(host.io, response.file, response.length, &metadata, operation, .{
        .openai = openai_model.slice(),
        .alternate = x_openai_model.slice(),
    }, .{
        .metadata = host.faults.response_metadata,
    })) {
        .accepted => |value| value,
        .rejected => |rejection| {
            traceOperation(host, "validation_failed", owner.binding);
            stderr.print("rui: provider output rejected for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(rejection.reason) });
            var detail: [512]u8 = undefined;
            answered.reject(rejection.code, rejection.format(&detail), failureClass(host, rejection.kind, null, null));
            return .cleanup;
        },
    };
    const validated = accepted.output;
    traceOperation(host, "validation_completed", owner.binding);
    if (host.faults.before_result_delay_ms != 0 or host.faults.model_result_gate_path != null) {
        traceOperation(host, "sealed_before_settlement", owner.binding);
        if (host.faults.model_result_gate_path) |path| waitAtTestGate(host, path);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_result_delay_ms), .awake) catch {};
    }
    if (!host.custody.claimTerminalDelivery(owner.token)) return .cleanup;
    var settlement_trace = SettlementTrace.init(host, owner.binding);
    host.store.settleModelSuccess(owner.binding, &.{
        .source = response.file,
        .source_length = response.length,
        .metadata = metadata.file,
        .item_count = validated.item_count,
        .call_count = validated.call_count,
        .answer_length = validated.answer_length,
        .answer_digest = validated.answer_digest,
        .response_id = validated.evidence.response_id,
        .model_evidence = accepted.model_evidence,
        .request_id = answered.request_id,
    }, .{
        .output_read = host.faults.response_read,
        .output_import = host.faults.response_import,
        .output_commit = host.faults.response_commit,
        .settlement_trace = settlement_trace.storeTrace(),
    }) catch |err| {
        if (err == error.SupersededByControl) {
            traceOperation(host, "model_settlement_superseded", owner.binding);
        } else if (err == error.InvalidProviderEnvelope) {
            const rejection: model_adapter.Output.Rejection = .{ .stage = .response, .byte_offset = response.length };
            var detail: [512]u8 = undefined;
            host.store.settleModelAttemptFailure(owner.binding, answered.rejection(
                "contradictory_provider_output",
                rejection.format(err, &detail),
            ), .ordinary, .{
                .before_commit = host.faults.result_before_commit,
            }) catch |failure_err| if (failure_err != error.SupersededByControl)
                fenceDispatch(host, "model envelope rejection save", failure_err);
        } else {
            fenceDispatch(host, "model output import", err);
        }
        return .cleanup;
    };
    traceOperation(host, "model_settlement_committed", owner.binding);
    return .cleanup;
}

fn advanceRetainedCleanup(
    host: *Host,
    slots: []ExecutionSlot,
    now: std.Io.Clock.Timestamp,
    retry_at: *std.Io.Clock.Timestamp,
) bool {
    if (now.raw.nanoseconds < retry_at.raw.nanoseconds) return false;
    retry_at.* = now.addDuration(.{ .raw = .fromMilliseconds(100), .clock = .awake });
    var made_progress = false;
    for (slots) |*slot| switch (slot.*) {
        .bash_prepared_cleanup => |*retained| {
            retained.cleanup.cleanup() catch continue;
            host.custody.cleanupComplete(retained.token) catch unreachable;
            slot.* = .free;
            made_progress = true;
        },
        .named_scratch => |*retained| {
            _ = retained.owner.reclaim(host.lease.paths.scratch.slice()) catch continue;
            host.custody.cleanupComplete(retained.token) catch unreachable;
            slot.* = .free;
            made_progress = true;
        },
        else => {},
    };
    return made_progress;
}

fn shutdownExecution(
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *?bash.Preparation,
    model_preparation: *model_adapter.Preparation,
) void {
    // Initiate every effect's shutdown before waiting for any retirement.
    // Discarded transfers retain their pointer-stable capture storage until
    // the writer drains; that wait must not delay Bash signals or cleanup.
    for (slots) |*slot| switch (slot.*) {
        .free => {},
        .model_preparing => |active| {
            model_preparation.cancel();
            finishCustodyNow(host, slot, active.token);
        },
        .model_authenticating => |*active| {
            active.request.deinit();
            finishCustodyNow(host, slot, active.owner.token);
        },
        .bash_preparing => |active| {
            const cleanup = preparation.*.?.cancel();
            preparation.* = null;
            discardBashResources(host, slot, active.token, cleanup);
        },
        .bash => |*active| active.execution.requestInfrastructureShutdown(.now(host.io, .awake)),
        .bash_prepared_cleanup, .named_scratch => {},
        .provider => |*active| reactor.?.discard(&active.transfer),
    };
    var bash_window: [bash.copy_window_bytes]u8 = undefined;
    var retained_cleanup_at = std.Io.Clock.Timestamp.now(host.io, .awake);
    while (hasOwnedSlots(slots)) {
        var made_progress = false;
        for (slots) |*slot| switch (slot.*) {
            .provider => {
                // Shutdown discards transport evidence rather than invoking
                // ordinary model completion or saving a semantic failure.
                if (advanceModelFinalization(host, slot, false)) made_progress = true;
            },
            else => {},
        };
        made_progress = advanceBash(host, slots, &bash_window) or made_progress;
        const now = std.Io.Clock.Timestamp.now(host.io, .awake);
        made_progress = advanceRetainedCleanup(host, slots, now, &retained_cleanup_at) or made_progress;
        if (!made_progress) _ = host.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
}

fn hasTransport(slots: []const ExecutionSlot) bool {
    for (slots) |slot| {
        if (slot == .provider) return true;
    }
    return false;
}

fn hasBash(slots: []const ExecutionSlot) bool {
    for (slots) |slot| {
        if (slot == .bash_preparing or slot == .bash) return true;
    }
    return false;
}

fn hasOwnedSlots(slots: []const ExecutionSlot) bool {
    for (slots) |slot| {
        if (slot != .free) return true;
    }
    return false;
}

/// An Attempt the provider answered with an HTTP status. Its failures carry
/// the provider's own correlation, so no answered path records a code alone.
const AnsweredAttempt = struct {
    host: *Host,
    owner: AttemptOwner,
    request_id: protocol.Bounded(256),

    fn init(host: *Host, owner: AttemptOwner, transfer: *const provider.Transfer) AnsweredAttempt {
        var request_id: protocol.Bounded(256) = .{};
        request_id.set(transfer.requestId()) catch unreachable;
        return .{ .host = host, .owner = owner, .request_id = request_id };
    }

    fn fail(self: *const AnsweredAttempt, code: []const u8, disposition: store_module.ModelFailureClass) void {
        settleFailure(self.host, self.owner.token, self.owner.binding, .{ .correlated = .{
            .code = code,
            .request_id = self.request_id,
        } }, disposition);
    }

    fn reject(self: *const AnsweredAttempt, code: []const u8, diagnostic: []const u8, disposition: store_module.ModelFailureClass) void {
        settleFailure(self.host, self.owner.token, self.owner.binding, self.rejection(code, diagnostic), disposition);
    }

    /// For a settlement whose terminal delivery is already claimed.
    fn rejection(self: *const AnsweredAttempt, code: []const u8, diagnostic: []const u8) store_module.ModelFailure {
        return .{ .rejected = .{ .code = code, .diagnostic = diagnostic, .request_id = self.request_id } };
    }
};

/// A failure with no provider answer to correlate. Answered paths settle
/// through `AnsweredAttempt` instead.
fn settleUnansweredFailure(
    host: *Host,
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    code: []const u8,
    disposition: store_module.ModelFailureClass,
) void {
    settleFailure(host, token, binding, .{ .uncorrelated = code }, disposition);
}

fn settleFailure(
    host: *Host,
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    failure: store_module.ModelFailure,
    disposition: store_module.ModelFailureClass,
) void {
    if (!host.custody.claimTerminalDelivery(token)) return;
    host.store.settleModelAttemptFailure(binding, failure, disposition, .{
        .before_commit = host.faults.result_before_commit,
    }) catch |err| if (err != error.SupersededByControl)
        fenceDispatch(host, "model failure save", err);
}

fn finishCustodyNow(host: *Host, slot: *ExecutionSlot, token: execution.CustodyToken) void {
    // Capture checked identity while attached, but observe only after callers
    // have retired resources and this owner has released custody and the slot.
    const model_binding = if (host.faults.test_phase_trace)
        host.custody.binding(token) catch null
    else
        null;
    const action_binding = if (host.faults.test_phase_trace and model_binding == null)
        host.custody.actionBinding(token) catch unreachable
    else
        null;
    host.custody.detach(token) catch unreachable;
    host.custody.cleanupComplete(token) catch unreachable;
    slot.* = .free;
    if (model_binding) |binding| traceOperation(host, "cleanup_completed", binding);
    if (action_binding) |binding| traceAction(host, "cleanup_completed", binding);
}

fn fenceDispatch(host: *Host, phase: []const u8, err: anyerror) void {
    host.launch_mutex.lockUncancelable(host.io);
    const already_shutting_down = host.effect_shutdown.swap(true, .acq_rel);
    host.dispatch_fenced.store(true, .release);
    host.launch_mutex.unlock(host.io);
    if (already_shutting_down) return;
    stderr.print("rui: dispatch fenced after {s} failure: {s}\nHost cannot safely continue; wait for shutdown before restarting this Store. Use saved request handles; do not resubmit uncertain work.\n", .{ phase, @errorName(err) });
    wakeListener(host);
}

fn wakeListener(host: *Host) void {
    if (host.intake) |intake| intake.notify();
}

fn retainDispatchFence(host: *Host, phase: []const u8, err: anyerror) void {
    host.launch_mutex.lockUncancelable(host.io);
    host.dispatch_fenced.store(true, .release);
    host.launch_mutex.unlock(host.io);
    stderr.print("rui: dispatch fenced after {s} failure: {s}\nNew work is blocked; retained cleanup is still owned. Inspect saved requests; do not resubmit uncertain work.\n", .{ phase, @errorName(err) });
}

fn nowNs(host: *Host) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(host.io, .awake).raw.nanoseconds);
}

fn beginTestObservation(host: *Host, phase: []const u8, subject: ?[]const u8) ?TestObservation.Publication {
    const writer = host.test_observation orelse return null;
    return writer.begin(phase, subject);
}

fn writeTestTrace(host: *Host, trace: *protocol.ResponseBuffer, publication: *?TestObservation.Publication) void {
    if (!host.faults.test_phase_trace) return;
    if (publication.*) |*value| value.record(trace.slice());
    if (!stderr.tryAcquire()) {
        host.trace_lost.store(true, .release);
        return;
    }
    defer stderr.release();
    host.trace_sequence += 1;
    const original = trace.slice();
    if (original.len == 0 or original[original.len - 1] != '}') {
        host.trace_lost.store(true, .release);
        return;
    }
    var complete: protocol.ResponseBuffer = .{};
    complete.append(original[0 .. original.len - 1]) catch {
        host.trace_lost.store(true, .release);
        return;
    };
    complete.appendFmt(
        ",\"process\":\"{d}\",\"run\":\"{d}\",\"clock\":\"awake_ns\",\"sequence\":\"{d}\",\"trace_lost\":{s}}}\n",
        .{ trace_native.getpid(), host.trace_run_ns, host.trace_sequence, if (host.trace_lost.load(.acquire)) "true" else "false" },
    ) catch {
        host.trace_lost.store(true, .release);
        return;
    };
    if (!stderr.writeHeld(complete.slice())) host.trace_lost.store(true, .release);
}

fn traceSubject(host: *Host, phase: []const u8, subject_kind: []const u8, subject: []const u8) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, subject);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"subject_kind\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(subject_kind) catch return;
    trace.append(",\"subject\":") catch return;
    trace.appendJsonString(subject) catch return;
    trace.append("}") catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceRequest(host: *Host, phase: []const u8, request_number: u64, scratch_used_bytes: ?u64) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(
        ",\"at_ns\":\"{d}\",\"subject_kind\":\"request_number\",\"subject\":\"{d}\"",
        .{ nowNs(host), request_number },
    ) catch return;
    if (scratch_used_bytes) |used|
        trace.appendFmt(",\"scratch_used_bytes\":\"{d}\"", .{used}) catch return;
    trace.append("}") catch return;
    writeTestTrace(host, &trace, &publication);
}

/// Local execution facts for inspection, read from another thread than the
/// execution owner's.
fn executionFacts(host: *Host) store_module.SessionReportExecution {
    return .{
        .dispatch_fenced = host.dispatch_fenced.load(.acquire),
        .custody_occupied = host.custody.held(),
        .scratch_used_bytes = host.scratch_used.load(.acquire),
    };
}

fn traceServiceBoundary(host: *Host, start_ns: u64, end_ns: u64, wait_ns: u64) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, "lifecycle_boundary", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"lifecycle_boundary\",\"at_ns\":\"{d}\",\"start_ns\":\"{d}\",\"wait_ns\":\"{d}\"}}",
        .{ end_ns, start_ns, wait_ns },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceLifecycleService(host: *Host, maximum_gap_ns: u64) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, "lifecycle_service_observation", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"lifecycle_service_observation\",\"at_ns\":\"{d}\",\"maximum_gap_ns\":\"{d}\",\"owner\":\"execution\"}}",
        .{ nowNs(host), maximum_gap_ns },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceOperation(host: *Host, phase: []const u8, binding: store_module.AttemptBinding) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        nowNs(host),
        binding.turn_id,
        binding.operation_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn tracePreparationAdvance(
    host: *Host,
    phase: []const u8,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(
        ",\"at_ns\":\"{d}\",\"work_bytes\":\"{d}\",\"work_items\":\"{d}\",\"request_bytes\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ nowNs(host), stats.work_bytes, stats.work_items, stats.request_bytes, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn tracePreparationAdvanceError(
    host: *Host,
    phase: []const u8,
    err: anyerror,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"error\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(@errorName(err)) catch return;
    trace.appendFmt(
        ",\"work_bytes\":\"{d}\",\"work_items\":\"{d}\",\"request_bytes\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ stats.work_bytes, stats.work_items, stats.request_bytes, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceCompletionQueue(host: *Host, queued_after: usize, binding: store_module.AttemptBinding) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, "provider_completion_removed", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"provider_completion_removed\",\"at_ns\":\"{d}\",\"queued_after\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ nowNs(host), queued_after, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceAction(host: *Host, phase: []const u8, binding: store_module.ActionAttemptBinding) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        nowNs(host),
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceOperationControl(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.AttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        binding.turn_id,
        binding.operation_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceActionControl(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.ActionAttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceActionControlOutcome(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    attempted: bool,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"control_key\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(command_key) catch return;
    trace.appendFmt(",\"attempted\":{s},\"failed\":{s},\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        if (attempted) "true" else "false",
        if (failed) "true" else "false",
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn traceActionDeadline(
    host: *Host,
    phase: []const u8,
    deadline_ns: u64,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, phase, null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"deadline_ns\":\"{d}\",\"failed\":{s},\"turn\":\"{d}\",\"operation\":\"{d}\",\"action\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        nowNs(host),
        deadline_ns,
        if (failed) "true" else "false",
        binding.turn_id,
        binding.parent_operation_id,
        binding.action_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn testTransition(host: *Host, transition: TestTransition, binding: store_module.ActionAttemptBinding) void {
    if (host.faults.test_transition != transition) return;
    traceAction(host, @tagName(transition), binding);
    waitAtTestGate(host, host.faults.test_transition_gate_path.?);
}

fn waitAtTestGate(host: *Host, path: []const u8) void {
    // Release is a byte or persistent EOF after unlink/sole-writer close.
    // macOS does not broadcast EOF to all already-blocked FIFO reads. Keep
    // reads nonblocking so every waiter observes the shared release fact,
    // including an opener that resolved the name before it was unlinked.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return;
    var gate: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer gate.close(host.io);
    var release: [1]u8 = undefined;
    var waiting_traced = false;
    while (true) {
        _ = std.posix.read(fd, &release) catch |err| switch (err) {
            error.WouldBlock => {
                if (!waiting_traced) {
                    traceSubject(host, "test_gate_waiting", "path", path);
                    waiting_traced = true;
                }
                std.Io.sleep(host.io, .fromMilliseconds(10), .awake) catch return;
                continue;
            },
            else => return,
        };
        return;
    }
}

fn testGateActive(host: *Host, path: []const u8) bool {
    const gate = std.Io.Dir.cwd().openFile(host.io, path, .{}) catch return false;
    gate.close(host.io);
    return true;
}

fn observeUnprocessedCompletions(host: *Host, reactor: *provider.Reactor) void {
    const count = reactor.unprocessedCompletions() catch |err| {
        fenceDispatch(host, "native completion observation", err);
        return;
    };
    if (host.last_unprocessed_completions) |previous| {
        if (previous == count) return;
    }
    host.last_unprocessed_completions = count;
    if (!host.faults.test_phase_trace) return;
    var publication = beginTestObservation(host, "native_completions_unprocessed", null);
    defer if (publication) |*value| value.finish();
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"native_completions_unprocessed\",\"at_ns\":\"{d}\",\"queued_after\":\"{d}\"}}",
        .{ nowNs(host), count },
    ) catch return;
    writeTestTrace(host, &trace, &publication);
}

fn appendOptionalUnsigned(
    trace: *protocol.ResponseBuffer,
    name: []const u8,
    value: ?u64,
) !void {
    try trace.appendJsonString(name);
    try trace.append(":");
    if (value) |present| {
        try trace.appendFmt("{d}", .{present});
    } else try trace.append("null");
}

fn appendOptionalSigned(
    trace: *protocol.ResponseBuffer,
    name: []const u8,
    value: ?i64,
) !void {
    try trace.appendJsonString(name);
    try trace.append(":");
    if (value) |present| {
        try trace.appendFmt("{d}", .{present});
    } else try trace.append("null");
}

fn traceSqliteDiagnostic(host: *Host, subject: []const u8) void {
    if (!host.faults.test_phase_trace or !host.faults.sqlite_diagnostics) return;
    var publication = beginTestObservation(host, "sqlite_diagnostic", subject);
    defer if (publication) |*value| value.finish();
    const value = host.store.sqliteDiagnostic();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":\"sqlite_diagnostic\",\"at_ns\":\"") catch return;
    trace.appendFmt("{d}", .{nowNs(host)}) catch return;
    trace.append("\",\"subject\":") catch return;
    trace.appendJsonString(subject) catch return;
    trace.append(",\"process_memory_scope\":\"SQLite process-global allocator; one Store per Host\",") catch return;
    appendOptionalUnsigned(&trace, "process_memory_current_bytes", value.process_memory_current_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "process_memory_highwater_bytes", value.process_memory_highwater_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "cache_used_bytes", value.cache_used_bytes) catch return;
    trace.append(",\"cache_used_scope\":\"connection-current approximate pager bytes\",") catch return;
    appendOptionalUnsigned(&trace, "cache_spills", value.cache_spills) catch return;
    trace.append(",\"cache_spills_scope\":\"connection cumulative mid-transaction spills\",") catch return;
    appendOptionalUnsigned(&trace, "hard_heap_limit_bytes", value.hard_heap_limit_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "page_size_bytes", value.page_size_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalSigned(&trace, "cache_size_setting", value.cache_size_setting) catch return;
    trace.append(",\"cache_size_setting_scope\":\"raw PRAGMA cache_size; negative magnitude is suggested KiB, positive value is suggested pages\",") catch return;
    appendOptionalSigned(&trace, "cache_spill_threshold", value.cache_spill_threshold) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "mmap_size_bytes", value.mmap_size_bytes) catch return;
    trace.append(",") catch return;
    appendOptionalSigned(&trace, "synchronous", value.synchronous) catch return;
    trace.append(",") catch return;
    appendOptionalSigned(&trace, "temp_store", value.temp_store) catch return;
    trace.append(",") catch return;
    appendOptionalUnsigned(&trace, "busy_timeout_ms", value.busy_timeout_ms) catch return;
    trace.append(",\"journal_mode\":") catch return;
    if (value.journal_mode) |mode| {
        trace.appendJsonString(mode.slice()) catch return;
    } else trace.append("null") catch return;
    trace.append("}") catch return;
    writeTestTrace(host, &trace, &publication);
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

const SettlementTrace = struct {
    host: *Host,
    binding: store_module.AttemptBinding,

    fn init(host: *Host, binding: store_module.AttemptBinding) SettlementTrace {
        return .{ .host = host, .binding = binding };
    }

    fn storeTrace(self: *SettlementTrace) ?store_module.SettlementTrace {
        if (!self.host.faults.test_phase_trace) return null;
        return .{ .context = self, .mark_fn = markStore };
    }

    fn markStore(context: *anyopaque, phase: store_module.SettlementTracePhase) void {
        const self: *SettlementTrace = @ptrCast(@alignCast(context));
        traceOperation(self.host, switch (phase) {
            .lock_requested => "settlement_lock_requested",
            .lock_acquired => "settlement_lock_acquired",
            .transaction_active => "settlement_transaction_active",
            .settlement_complete => "settlement_complete",
        }, self.binding);
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
        return respondStatic(host.io, fd, 409, "invocation_error", "wrong_store_identity");
    }
    if (header.instance) |instance| {
        if (!std.mem.eql(u8, &instance, &host.instance)) {
            return respondStatic(host.io, fd, 409, "invocation_error", "host_instance_changed");
        }
    }
    if (header.route == .host_stop and header.instance == null) {
        return respondStatic(host.io, fd, 400, "invocation_error", "host_instance_required");
    }
    if (header.drop == .before_admission) return;
    if (header.drop == .during_admission and std.c.shutdown(socket, std.c.SHUT.RDWR) != 0) {
        return error.InjectedDisconnectFailed;
    }

    switch (request.*) {
        .host_info => {
            if (!host.launchAllowed()) return respondStatic(host.io, fd, 503, "host_unavailable", "dispatch_fenced");
            var response: protocol.ResponseBuffer = .{};
            try response.append("{\"version\":\"1\",\"type\":\"host_info\",\"store\":");
            try response.appendJsonString(host.lease.paths.store.slice());
            try response.append(",\"instance\":\"");
            try response.append(&std.fmt.bytesToHex(host.instance, .lower));
            try response.appendFmt("\",\"active_capacity\":\"{d}\",\"intake_capacity\":\"{d}\",\"descriptor_limit\":\"", .{
                host.custody.records.len,
                host.intake_capacity,
            });
            if (host.descriptor_soft_limit) |limit| try response.appendFmt("{d}", .{limit}) else try response.append("unlimited");
            try response.appendFmt("\",\"capabilities\":{{\"bash\":true,\"model\":{s},\"managed_authentication\":{s}}}}}", .{
                if (host.provider_endpoint != null) "true" else "false",
                if (host.provider_endpoint != null and host.authentication != null) "true" else "false",
            });
            std.debug.assert(response.len <= protocol.max_host_info_response_bytes);
            try fd.setJson(200, response.slice());
        },
        .host_stop => {
            host.launch_mutex.lockUncancelable(host.io);
            const first = !host.effect_shutdown.swap(true, .acq_rel);
            host.dispatch_fenced.store(true, .release);
            host.launch_mutex.unlock(host.io);
            if (first) wakeListener(host);
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
                return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
            };
            var response: protocol.ResponseBuffer = .{};
            try renderCommandObservation(&response, command.key.slice(), observation);
            deliverResponse(host.io, fd, 200, response.slice());
        },
        .read_result => |command| {
            const reference = host.store.commandResult(command.key.slice()) catch |err| switch (err) {
                error.ResultNotFound => return respondStatic(host.io, fd, 409, "result_unavailable", "result_not_found"),
                error.ResultNotReady => return respondStatic(host.io, fd, 409, "result_unavailable", "result_not_ready"),
                error.ResultFailed => return respondStatic(host.io, fd, 409, "result_unavailable", "result_failed"),
                else => {
                    fenceDispatch(host, "result observation", err);
                    return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
                },
            };
            const reader = host.store.openContent(reference) catch |err| {
                fenceDispatch(host, "result content read", err);
                return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
            };
            try fd.setContent(reader, 0, true, false);
        },
        .read_action_arguments => |command| deliverActionContent(host, fd, command, false),
        .read_action_call_id => |command| deliverActionContent(host, fd, command, true),
        .inspect_session => |request_value| {
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
                    return respondStatic(host.io, fd, 500, "observation_error", "report_scratch_cleanup_failed");
                }
                if (host.store.isFenced()) {
                    fenceDispatch(host, "session inspection", err);
                    return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
                }
                return respondStatic(
                    host.io,
                    fd,
                    if (err == error.ReportScratchExhausted) 507 else 500,
                    "observation_error",
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
                    return respondStatic(host.io, fd, 500, "observation_error", "report_scratch_cleanup_failed");
                }
                if (host.store.isFenced()) {
                    fenceDispatch(host, "Session list", err);
                    return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
                }
                return respondStatic(host.io, fd, if (err == error.ReportScratchExhausted) 507 else 500, "observation_error", @errorName(err));
            };
            try fd.setReport(page);
        },
        .conversation_page => |command| {
            const page = host.store.publicConversationPage(command) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(host.io, fd, 409, "conversation_unavailable", @errorName(err)),
                else => {
                    fenceDispatch(host, "conversation page", err);
                    return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
                },
            };
            var response: protocol.FixedJsonBuffer(protocol.max_conversation_page_response_bytes) = .{};
            try response.appendFmt("{{\"version\":\"1\",\"type\":\"conversation_page\",\"direction\":\"newest_first\",\"end\":\"{d}\",\"items\":[", .{page.end});
            for (page.items[0..page.count], 0..) |item, index| {
                if (index != 0) try response.append(",");
                try response.appendFmt("{{\"position\":\"{d}\",\"ordinal\":\"{d}\",\"kind\":\"{s}\",\"content\":{{\"bytes\":\"{d}\",\"sha256\":\"{s}\",\"display\":\"omitted\"}}", .{
                    item.position, item.ordinal, @tagName(item.kind), item.content.length, std.fmt.bytesToHex(item.content.digest, .lower),
                });
                if (item.admitted_at) |second| {
                    try response.appendFmt(",\"admitted_at\":\"{d}\",\"sender\":", .{second});
                    if (item.sender) |sender| {
                        var buffer: [protocol.max_peer_json_bytes]u8 = undefined;
                        var writer = std.Io.Writer.fixed(&buffer);
                        try sender.writeJson(&writer);
                        try response.append(writer.buffered());
                    } else try response.append("null");
                }
                if (item.presentation) |presentation| {
                    var buffer: [protocol.max_tool_presentation_json_bytes]u8 = undefined;
                    var writer = std.Io.Writer.fixed(&buffer);
                    try presentation.writeJson(&writer);
                    try response.append(",\"presentation\":");
                    try response.append(writer.buffered());
                }
                try response.append("}");
            }
            try response.appendFmt("],\"more\":{s}", .{if (page.more) "true" else "false"});
            if (page.more) {
                const last = page.items[page.count - 1];
                try response.appendFmt(",\"before_position\":\"{d}\",\"before_ordinal\":\"{d}\"", .{ last.position, last.ordinal });
            }
            try response.append("}");
            deliverResponse(host.io, fd, 200, response.slice());
        },
        .conversation_content => |command| try prepareConversationContent(host, fd, command),
        .proposal_page => |command| {
            const page = host.store.proposalPage(command) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(host.io, fd, 409, "proposal_unavailable", @errorName(err)),
                else => {
                    fenceDispatch(host, "proposal page", err);
                    return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
                },
            };
            var response: protocol.FixedJsonBuffer(protocol.max_proposal_page_response_bytes) = .{};
            try response.appendFmt("{{\"version\":\"1\",\"type\":\"proposal_page\",\"end\":\"{d}\",\"items\":[", .{page.end});
            for (page.items[0..page.count], 0..) |item, index| {
                if (index != 0) try response.append(",");
                try response.appendFmt("{{\"position\":\"{d}\",\"operation\":\"{d}\",\"turn\":\"{d}\",\"call_ordinal\":\"{d}\",\"action\":", .{ item.position, item.operation, item.turn, item.call_ordinal });
                if (item.action) |action| try response.appendFmt("\"{d}\"", .{action}) else try response.append("null");
                try response.append(",\"rejection\":");
                if (item.rejection) |code| try response.appendJsonString(@tagName(code)) else try response.append("null");
                try response.append(",\"fields\":{");
                inline for (std.meta.tags(protocol.ProposalField), 0..) |field, field_index| {
                    if (field_index != 0) try response.append(",");
                    const reference = item.fields[field_index];
                    try response.appendFmt("\"{s}\":{{\"bytes\":\"{d}\",\"sha256\":\"{s}\"}}", .{ @tagName(field), reference.length, std.fmt.bytesToHex(reference.digest, .lower) });
                }
                try response.append("}}");
            }
            try response.appendFmt("],\"more\":{s}}}", .{if (page.more) "true" else "false"});
            deliverResponse(host.io, fd, 200, response.slice());
        },
        .proposal_field => |command| {
            const reader = host.store.openProposalField(command) catch |err| switch (err) {
                error.ContentNotFound => return respondStatic(host.io, fd, 409, "proposal_unavailable", @errorName(err)),
                else => {
                    fenceDispatch(host, "proposal field", err);
                    return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
                },
            };
            try deliverPublicContent(host, fd, reader, 0, true);
        },
        .activity_page => |command| {
            const page = host.store.activityPage(command) catch |err| switch (err) {
                error.SessionNotFound, error.InvalidCursor => return respondStatic(host.io, fd, 409, "activity_unavailable", @errorName(err)),
                else => {
                    fenceDispatch(host, "activity page", err);
                    return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
                },
            };
            var buffer: [protocol.max_activity_page_response_bytes]u8 = undefined;
            var out = std.Io.Writer.fixed(&buffer);
            try page.writeJson(&out);
            deliverResponse(host.io, fd, 200, out.buffered());
        },
        .activity_content => |command| {
            const reader = host.store.openActivityContent(command) catch |err| switch (err) {
                error.ContentNotFound => return respondStatic(host.io, fd, 409, "activity_unavailable", @errorName(err)),
                else => {
                    fenceDispatch(host, "activity content", err);
                    return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
                },
            };
            try deliverPublicContent(host, fd, reader, 0, true);
        },
    }
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
        error.ContentNotFound, error.RangeOutOfBounds => return respondStatic(host.io, fd, 409, "conversation_unavailable", @errorName(err)),
        else => {
            fenceDispatch(host, "conversation content", err);
            return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
        },
    };
    return deliverPublicContent(host, fd, reader, command.start, command.stream);
}

fn deliverPublicContent(host: *Host, fd: *Reply, reader: store_module.ContentReader, start: u64, stream: bool) !void {
    fd.setContent(reader, start, stream, true) catch |err| {
        fenceDispatch(host, "public content", err);
        fd.deinit();
        return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
    };
}

fn deliverActionContent(host: *Host, fd: *Reply, command: anytype, comptime call_id: bool) void {
    const phase = if (call_id) "Action call identity observation" else "Action argument observation";
    const reference = if (call_id)
        host.store.actionCallId(command.session.slice(), command.action_id)
    else
        host.store.actionArguments(command.session.slice(), command.action_id);
    const resolved = reference catch |err| switch (err) {
        error.ActionNotFound => return respondStatic(host.io, fd, 404, "action_unavailable", "action_not_found"),
        else => {
            fenceDispatch(host, phase, err);
            return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
        },
    };
    const reader = host.store.openContent(resolved) catch |err| {
        fenceDispatch(host, phase, err);
        return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
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
    if (result == .infrastructure_failure) return renderStatic(response, "invocation_error", "canonical_store_failure");
    try response.append("{\"version\":\"1\",\"type\":\"configuration_reply\",\"answer\":{\"status\":\"");
    try response.append(@tagName(result));
    const replayed = switch (result) {
        .accepted => |value| value.replayed,
        .rejected => |value| value.replayed,
        .conflict, .infrastructure_failure => false,
    };
    try response.append("\",\"replayed\":");
    try response.append(if (replayed) "true" else "false");
    try response.append(",\"session\":");
    try response.appendJsonString(command.session.slice());
    switch (result) {
        .rejected => |value| {
            try response.append(",\"code\":");
            try response.appendJsonString(@tagName(value.code));
        },
        .conflict => {
            try response.append(",\"code\":\"idempotency_key_conflict\"");
        },
        .infrastructure_failure => unreachable,
        .accepted => {},
    }
    if (result == .accepted) {
        const value = result.accepted;
        try response.appendFmt(",\"revision\":\"{d}\",\"created\":{s}", .{
            value.revision,
            if (value.created) "true" else "false",
        });
    }
    try response.append("},\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}}");
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
    const session = "original/é\n";
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
            0 => .{ .accepted = .{ .replayed = true, .revision = 13, .created = false } },
            1 => .{ .accepted = .{ .replayed = true, .admission_id = 17, .content = content } },
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
                try std.testing.expectError(error.RequestBindingMismatch, client.decodeMutationReply(.{ .status = status, .body = response.slice() }, "other/session", target).answer);
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
    if (result == .infrastructure_failure) return renderStatic(response, "invocation_error", "canonical_store_failure");
    try response.append("{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"");
    try response.append(@tagName(result));
    try response.append("\",\"replayed\":");
    const replayed = switch (result) {
        .accepted => |value| value.replayed,
        .rejected => |value| value.replayed,
        .conflict, .infrastructure_failure => false,
    };
    try response.append(if (replayed) "true" else "false");
    try response.append(",\"session\":");
    try response.appendJsonString(command.session.slice());
    switch (result) {
        .rejected => |value| {
            try response.append(",\"code\":");
            try response.appendJsonString(@tagName(value.code));
        },
        .conflict => {
            try response.append(",\"code\":\"idempotency_key_conflict\"");
        },
        .infrastructure_failure => unreachable,
        .accepted => |value| {
            try response.appendFmt(",\"admission\":\"{d}\"", .{value.admission_id});
        },
    }
    try response.append("}");
    switch (result) {
        .accepted => |value| {
            try response.append(",\"input\":");
            try renderContentReference(response, value.content);
            try response.appendFmt(",\"queue\":{{\"status\":\"queued\",\"admission\":\"{d}\"}}", .{value.admission_id});
        },
        .rejected => |value| {
            try response.append(",\"input\":");
            try renderContentReference(response, value.content);
        },
        .conflict, .infrastructure_failure => {},
    }
    try response.append(",\"execution\":{\"status\":\"queued\"}}");
}

fn renderSessionStopReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.SessionStopCommand,
    result: store_module.SessionStopReply,
) !void {
    if (result == .infrastructure_failure) return renderStatic(response, "invocation_error", "canonical_store_failure");
    try response.append("{\"version\":\"1\",\"type\":\"session_stop_reply\",\"answer\":{\"status\":\"");
    try response.append(@tagName(result));
    const replayed = switch (result) {
        .accepted => |value| value.replayed,
        .rejected => |value| value.replayed,
        .conflict, .infrastructure_failure => false,
    };
    try response.append(if (replayed) "\",\"replayed\":true,\"session\":" else "\",\"replayed\":false,\"session\":");
    try response.appendJsonString(command.session.slice());
    switch (result) {
        .accepted => |value| {
            try response.append(",\"selection\":{\"turn\":");
            if (value.selection.selected_turn_id) |turn_id| {
                try response.appendFmt("\"{d}\"", .{turn_id});
            } else try response.append("null");
            try response.appendFmt(",\"admission_cutoff\":\"{d}\"}}", .{value.selection.admission_cutoff});
        },
        .rejected => |value| {
            try response.append(",\"code\":");
            try response.appendJsonString(@tagName(value.code));
        },
        .conflict => try response.append(",\"code\":\"idempotency_key_conflict\""),
        .infrastructure_failure => unreachable,
    }
    try response.append("},\"completion\":{\"status\":\"");
    switch (result) {
        .accepted => |value| try response.append(@tagName(value.completion)),
        .rejected, .conflict, .infrastructure_failure => try response.append("unavailable"),
    }
    try response.append("\"}}");
}

fn renderModelInterruptionReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.ModelInterruptionCommand,
    result: store_module.ModelInterruptionReply,
) !void {
    if (result == .infrastructure_failure) return renderStatic(response, "invocation_error", "canonical_store_failure");
    try response.append("{\"version\":\"1\",\"type\":\"model_interruption_reply\",\"answer\":{\"status\":\"");
    try response.append(@tagName(result));
    const replayed = switch (result) {
        .accepted => |value| value.replayed,
        .rejected => |value| value.replayed,
        .conflict, .infrastructure_failure => false,
    };
    try response.append(if (replayed) "\",\"replayed\":true,\"target\":{\"session\":" else "\",\"replayed\":false,\"target\":{\"session\":");
    try response.appendJsonString(command.session.slice());
    try response.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\"}}", .{
        command.turn_id,
        command.operation_id,
    });
    switch (result) {
        .rejected => |value| {
            try response.append(",\"code\":");
            try response.appendJsonString(@tagName(value.code));
        },
        .conflict => try response.append(",\"code\":\"idempotency_key_conflict\""),
        .infrastructure_failure => unreachable,
        .accepted => {},
    }
    try response.append("}}");
}

fn renderPermissionDecisionReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.PermissionDecisionCommand,
    result: store_module.PermissionDecisionReply,
) !void {
    if (result == .infrastructure_failure) return renderStatic(response, "invocation_error", "canonical_store_failure");
    try response.append("{\"version\":\"1\",\"type\":\"permission_decision_reply\",\"answer\":{\"status\":\"");
    try response.append(@tagName(result));
    const replayed = switch (result) {
        .accepted => |value| value.replayed,
        .rejected => |value| value.replayed,
        .conflict, .infrastructure_failure => false,
    };
    try response.append(if (replayed) "\",\"replayed\":true" else "\",\"replayed\":false");
    try response.append(",\"session\":");
    try response.appendJsonString(command.session.slice());
    try response.appendFmt(",\"action\":\"{d}\",\"decision\":\"{s}\"", .{
        command.action_id,
        @tagName(command.decision),
    });
    switch (result) {
        .rejected => |value| {
            try response.append(",\"code\":");
            try response.appendJsonString(@tagName(value.code));
        },
        .conflict => try response.append(",\"code\":\"idempotency_key_conflict\""),
        .infrastructure_failure => unreachable,
        .accepted => {},
    }
    try response.append("}}");
}

fn renderCommandObservation(
    response: *protocol.ResponseBuffer,
    key: []const u8,
    observation: store_module.CommandObservation,
) !void {
    try response.append("{\"version\":\"1\",\"type\":\"command_observation\",\"key\":");
    try response.appendJsonString(key);
    try response.append(",\"observation\":{\"status\":\"");
    try response.append(@tagName(observation.status));
    try response.append("\"");
    if (observation.status != .absent) {
        try response.append(",\"kind\":\"");
        try response.append(@tagName(observation.kind));
        try response.append("\",\"target\":");
        try response.appendJsonString(observation.target.slice());
        if (observation.code.len != 0) {
            try response.append(",\"code\":");
            try response.appendJsonString(observation.code.slice());
        }
        if (observation.status == .accepted and observation.kind == .configure) {
            try response.appendFmt(",\"revision\":\"{d}\",\"created\":{s}", .{
                observation.revision,
                if (observation.created) "true" else "false",
            });
        }
        if (observation.message) |message| {
            try response.append(",\"input\":");
            try renderContentReference(response, message.content);
            if (message.queue) |accepted| {
                try response.appendFmt(",\"queue\":{{\"status\":\"{s}\",\"admission\":\"{d}\"}}", .{
                    @tagName(accepted.state),
                    accepted.admission_id,
                });
                switch (accepted.state) {
                    .queued => {},
                    .excluded => |excluded| {
                        try response.append(",\"result\":{\"status\":\"cancelled\",\"code\":");
                        try response.appendJsonString(excluded.code.slice());
                        try response.append("}");
                    },
                    .processing => |binding| try renderProcessingBinding(response, binding),
                    .completed => |completed| {
                        try renderProcessingBinding(response, completed.binding);
                        try response.append(",\"result\":{\"status\":\"completed\",\"text\":");
                        try renderContentReference(response, completed.answer);
                        try response.append("}");
                    },
                    .cancelled => |cancelled| {
                        try renderProcessingBinding(response, cancelled.binding);
                        try response.append(",\"result\":{\"status\":\"cancelled\",\"code\":");
                        try response.appendJsonString(cancelled.code.slice());
                        try response.append("}");
                    },
                    .failed => |failed| {
                        try renderProcessingBinding(response, failed.binding);
                        try response.append(",\"result\":{\"status\":\"failed\",\"code\":");
                        try response.appendJsonString(failed.code.slice());
                        try response.append("}");
                    },
                }
                if (message.progress) |progress| {
                    try response.appendFmt(",\"progress\":{{\"status\":\"{s}\",\"action\":", .{@tagName(progress.status)});
                    if (progress.action_id) |id| try response.appendFmt("\"{d}\"", .{id}) else try response.append("null");
                    try response.append("}");
                }
            }
        }
        if (observation.session_stop) |stop| {
            try response.append(",\"selection\":{\"turn\":");
            if (stop.selection.selected_turn_id) |turn_id| {
                try response.appendFmt("\"{d}\"", .{turn_id});
            } else try response.append("null");
            try response.appendFmt(",\"admission_cutoff\":\"{d}\"}},\"completion\":{{\"status\":\"{s}\"}}", .{
                stop.selection.admission_cutoff,
                @tagName(stop.completion),
            });
        }
        if (observation.model_interruption) |target| {
            try response.append(",\"interruption_target\":{\"session\":");
            try response.appendJsonString(target.session.slice());
            try response.appendFmt(",\"turn\":\"{d}\",\"operation\":\"{d}\"}}", .{
                target.turn_id,
                target.operation_id,
            });
        }
        if (observation.permission_action_id) |action_id| {
            try response.appendFmt(",\"permission_target\":{{\"action\":\"{d}\",\"decision\":\"{s}\"}}", .{
                action_id,
                @tagName(observation.permission_decision orelse return error.InvalidCommandObservation),
            });
        }
    }
    try response.append("}}");
}

fn renderProcessingBinding(response: *protocol.ResponseBuffer, binding: store_module.AttemptBinding) !void {
    try response.appendFmt(",\"processing\":{{\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        binding.turn_id,
        binding.operation_id,
        binding.attempt_ordinal,
    });
}

fn renderContentReference(response: *protocol.ResponseBuffer, reference: store_module.ContentReference) !void {
    try response.appendFmt("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
    try appendHex(response, &reference.digest);
    try response.append("\"}");
}

fn appendHex(response: *protocol.ResponseBuffer, bytes: *const [32]u8) !void {
    try response.append(&std.fmt.bytesToHex(bytes.*, .lower));
}

fn renderStatic(response: *protocol.ResponseBuffer, kind: []const u8, code: []const u8) !void {
    try response.append("{\"version\":\"1\",\"type\":");
    try response.appendJsonString(kind);
    try response.append(",\"code\":");
    try response.appendJsonString(code);
    try response.append("}");
}

fn respondStatic(io: std.Io, reply: *Reply, status: u16, kind: []const u8, code: []const u8) void {
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
            _ = std.c.shutdown(sockets[0], std.c.SHUT.WR);
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
    exchange.* = .{ .host = &host, .fd = sockets[0], .accepted_at_ns = 0, .deadline = 10 * std.time.ns_per_s };
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
                    _ = std.c.shutdown(self.fd, std.c.SHUT.RDWR);
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

test "model retry and inactivity defaults match the owning resource contract" {
    try std.testing.expectEqual([3]u64{ 2_000, 4_000, 8_000 }, retry_policy.default_waits_ms);
    try std.testing.expectEqual(@as(u64, 4), retry_policy.maximum_attempts);
    try std.testing.expectEqual(@as(i64, 5 * 60), (Limits{}).provider_inactivity_seconds);
}

test "authentication handoff borrows the sole credential lease and releases it once" {
    const credentials = @import("codex_credentials.zig");
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(io, "private", .{
        .permissions = .fromMode(0o700),
    });
    private.close(io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/private/auth", .{root[0..root_len]});
    var record = credentials.Record{
        .generation = 0,
        .account_id = .{},
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = 4_102_444_800,
        .refreshed_at = 1_750_000_000,
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try record.account_id.set("test-account");
    try record.id_token.set("aaa.bbb.ccc");
    try record.access_token.set("aaa.bbb.ccc");
    try record.refresh_token.set("test-refresh");
    try credentials.install(path, &record, null);

    var worker = AuthWorker{ .io = io, .authentication = .{ .path = path } };
    try credentials.leaseInto(path, &worker.credential);
    worker.state = .ready;
    defer if (worker.state == .ready or worker.state == .in_use) worker.credential.release();
    const borrowed = worker.take().?.ready;
    try std.testing.expect(borrowed == &worker.credential);
    try std.testing.expect(worker.take() == null);
    try std.testing.expectEqualStrings("test-refresh", borrowed.record.refresh_token.slice());
    worker.finish();
    try std.testing.expect(worker.state == .idle);
    worker.request();
    try std.testing.expect(worker.state == .requested);
    // The released lock can be acquired again for the next generation.
    var next: credentials.Lease = undefined;
    try credentials.leaseInto(path, &next);
    next.release();

    // Exercise the production model owner after cancellation, both before
    // the worker publishes and with either actual result. No Store or reactor
    // may be touched; the request and credential lease remain native owners.
    for ([_]bool{ false, true }) |ready| {
        var records: [1]execution.CustodyRecord = undefined;
        var host = Host{
            .io = io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{},
            .custody = execution.CustodyPool.initialize(&records),
            .auth_worker = &worker,
        };
        const token = host.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 7,
            .operation_id = 19,
            .attempt_ordinal = 3,
        } };
        const binding = try host.custody.attach(token, &permit);
        const output = try tmp.dir.createFile(io, "request", .{});
        try output.writeStreamingAll(io, "body");
        output.close(io);
        const input = try tmp.dir.openFile(io, "request", .{});
        try tmp.dir.deleteFile(io, "request");
        host.scratch_used.store(4, .release);
        var slot = ExecutionSlot{ .model_authenticating = .{
            .owner = .{ .token = token, .binding = binding },
            .cancelled = true,
            .request = .{
                .io = io,
                .file = input,
                .length = 4,
                .charged = 4,
                .budget = .{ .used = &host.scratch_used, .limit = 4 },
                .structured_output = false,
                .session_affinity = @splat(0),
            },
        } };
        defer if (slot == .model_authenticating) slot.model_authenticating.request.deinit();
        var reactor: provider.Reactor = undefined;
        worker.state = .requested;
        try std.testing.expect(!advanceAuthentication(&host, &reactor, &slot));
        try std.testing.expect(slot == .model_authenticating);
        try std.testing.expectEqual(@as(u64, 4), host.scratch_used.load(.acquire));
        try std.testing.expect(host.custody.reserve() == null);
        if (ready) {
            try credentials.leaseInto(path, &worker.credential);
            worker.state = .ready;
        } else {
            worker.failure = error.AuthenticationFailed;
            worker.state = .failed;
        }
        try std.testing.expect(advanceAuthentication(&host, &reactor, &slot));
        try std.testing.expect(slot == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
        try std.testing.expect(worker.state == .idle);
        const reused = host.custody.reserve().?;
        try std.testing.expect(reused.generation != token.generation);
        try std.testing.expect(!host.custody.claimTerminalDelivery(token));
        try host.custody.releaseUnused(reused);
    }
}

test "inspection counts held custody, not an in-flight admission reservation" {
    // The execution owner reserves before each admission probe and releases
    // when nothing is runnable. Inspection reads from another thread, so it
    // must not report that probe as a second custody beside gated cleanup.
    var records: [2]execution.CustodyRecord = undefined;
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .faults = .{},
        .custody = execution.CustodyPool.initialize(&records),
    };
    const cleanup = host.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 } };
    _ = try host.custody.attach(cleanup, &permit);
    try host.custody.detach(cleanup);
    const probe = host.custody.reserve().?;
    try std.testing.expectEqual(@as(usize, 1), executionFacts(&host).custody_occupied);
    // The reservation still blocks reuse and stays visible to reconciliation.
    try std.testing.expectEqual(@as(usize, 2), host.custody.occupied());
    try std.testing.expect(host.custody.reserve() == null);
    try host.custody.releaseUnused(probe);
    try std.testing.expectEqual(@as(usize, 1), executionFacts(&host).custody_occupied);
    try host.custody.cleanupComplete(cleanup);
    try std.testing.expectEqual(@as(usize, 0), executionFacts(&host).custody_occupied);
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

test "required Bash observations publish while optional stderr custody is held" {
    const native = @import("posix");
    inline for (.{ TestObservation.Plan.bash_cleanup, TestObservation.Plan.bash_pipes }) |plan| {
        var descriptors: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), native.pipe(&descriptors));
        defer _ = native.close(descriptors[0]);
        for (descriptors) |fd| {
            try std.testing.expectEqual(@as(c_int, 0), native.fcntl(fd, native.F_SETFL, @as(c_int, native.O_NONBLOCK)));
        }
        const backing = native.tmpfile() orelse return error.TestUnexpectedResult;
        defer _ = native.fclose(backing);
        try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(native.fileno(backing), TestObservation.state_bytes));
        var observation = try TestObservation.init(descriptors[1], native.dup(native.fileno(backing)), plan, 37);
        defer observation.close();
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{ .test_phase_trace = true },
            .test_observation = &observation,
        };
        try std.testing.expect(stderr.tryAcquire());
        defer stderr.release();
        var count: u64 = 0;
        inline for (.{ "cleanup_started", "cleanup_release_observed", "cleanup_completed", "inspection_captured", "bash_leader_observed_with_open_pipes", "control_store_complete" }) |phase| {
            if (std.mem.eql(u8, phase, "inspection_captured") or std.mem.eql(u8, phase, "control_store_complete")) {
                traceSubject(&host, phase, "command_key", "required");
            } else {
                traceAction(&host, phase, .{ .turn_id = 1, .parent_operation_id = 2, .action_id = 3, .attempt_ordinal = 1 });
            }
            const selected = if (plan == .bash_cleanup)
                std.mem.startsWith(u8, phase, "cleanup_") or std.mem.eql(u8, phase, "inspection_captured")
            else
                std.mem.eql(u8, phase, "bash_leader_observed_with_open_pipes") or std.mem.eql(u8, phase, "control_store_complete");
            var bytes: [TestObservation.record_bytes]u8 = undefined;
            const length = native.read(descriptors[0], &bytes, bytes.len);
            if (selected) {
                count += 1;
                try std.testing.expect(length >= 28);
                const frame = bytes[0..@intCast(length)];
                try std.testing.expectEqual(@as(u8, 0), frame[3]);
                try std.testing.expectEqual(count, std.mem.readInt(u64, frame[4..12], .little));
                try std.testing.expect(std.mem.indexOf(u8, frame, phase) != null);
            } else {
                try std.testing.expectEqual(@as(isize, -1), length);
            }
            try std.testing.expectEqual(count * 2, observation.shared.state.load(.acquire));
            try std.testing.expectEqual(@as(u64, 0), observation.shared.active.load(.acquire));
        }
        try std.testing.expect(host.trace_lost.load(.acquire));
    }
}

test "HTTP error capture retires before execution custody" {
    const Boundary = struct {
        var slot: *ExecutionSlot = undefined;
        var custody: *execution.CustodyPool = undefined;
        var used: *std.atomic.Value(u64) = undefined;
        var response_fd: std.Io.File.Handle = -1;
        var closes: usize = 0;
        var retirement_observed: bool = false;

        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            for (files) |file| if (file.handle == response_fd) {
                // Observe the real descriptor while close still owns it,
                // including a close that suspends before retiring the handle.
                std.debug.assert(slot.* == .provider);
                std.debug.assert(custody.occupied() == 1);
                closes += 1;
            };
            std.testing.io.vtable.fileClose(userdata, files);
        }

        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            if (slot.* == .free) {
                std.debug.assert(closes == 1);
                std.debug.assert(std.c.fcntl(response_fd, std.c.F.GETFD) < 0);
                std.debug.assert(used.load(.acquire) == 17);
                retirement_observed = true;
            }
            return std.testing.io.vtable.now(userdata, clock);
        }
    };
    try provider.initialize();
    defer provider.deinitialize();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var vtable = std.testing.io.vtable.*;
    vtable.fileClose = Boundary.close;
    vtable.now = Boundary.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    for (0..3) |kind| {
        var used: std.atomic.Value(u64) = .init(17);
        const budget = protocol.ScratchBudget{ .used = &used, .limit = 4096 };
        var records: [1]execution.CustodyRecord = undefined;
        var host = Host{
            .io = io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{ .test_phase_trace = true },
            .custody = execution.CustodyPool.initialize(&records),
        };
        const token = host.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 3,
            .operation_id = 7,
            .attempt_ordinal = 2,
        } };
        const binding = try host.custody.attach(token, &permit);
        // Delivery already claimed: this owner regression exercises physical
        // retirement without fabricating a Store settlement. Dispatch integration
        // separately verifies the durable HTTP overflow/failure meanings.
        try std.testing.expect(host.custody.claimTerminalDelivery(token));
        var slot: ExecutionSlot = .{ .provider = .{ .owner = .{ .token = token, .binding = binding } } };
        Boundary.slot = &slot;
        Boundary.custody = &host.custody;
        Boundary.used = &used;
        Boundary.response_fd = -1;
        Boundary.closes = 0;
        Boundary.retirement_observed = false;
        const request_file = try tmp.dir.createFile(io, "request", .{ .read = true });
        try request_file.writeStreamingAll(io, "{}");
        try std.testing.expect(budget.charge(2));
        var writer = provider.CaptureWriter{ .io = io };
        var retained: ?named_scratch.Owner = null;
        try slot.provider.transfer.start("http://127.0.0.1:1/responses", .{
            .io = io,
            .file = request_file,
            .length = 2,
            .charged = 2,
            .budget = budget,
            .structured_output = false,
            .session_affinity = @splat(0),
        }, binding, .{}, &writer, root, budget, &retained);
        errdefer if (slot == .provider) slot.provider.transfer.deinit();
        const body = if (kind == 2) "{\"error\":{\"code\":\"invalid_api_key\"}}" else "{\"error\":{\"code\":\"context_length_exceeded\"}}";
        const response = &slot.provider.transfer.response;
        try response.file.writeStreamingAll(io, body);
        try std.testing.expect(budget.charge(body.len));
        response.charged = body.len;
        response.length = body.len;
        try response.seal(false);
        Boundary.response_fd = response.file.handle;
        if (kind == 1) {
            // A short sealed read is a real classifier error, not malformed
            // JSON's negative-overflow result.
            response.length += 1;
            try std.testing.expectError(error.ShortSealedRead, model_adapter.Output.contextOverflow(io, response.file, response.length, 400));
        }
        completeTransfer(&host, &slot, .{
            .outcome = .{ .transport_finished = .{ .disposition = .permanent_http, .http_status = 400 } },
            .queued_after = 0,
        });
        try std.testing.expect(Boundary.retirement_observed);
        try std.testing.expectEqual(@as(usize, 1), Boundary.closes);
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
        try std.testing.expectEqual(@as(u64, 17), used.load(.acquire));
        try std.testing.expect(slot == .free);
        try std.testing.expect(host.custody.reserve() != null);
    }
}

test "cleanup publication follows complete execution retirement" {
    const Boundary = struct {
        slot: *const ExecutionSlot = undefined,
        custody: *execution.CustodyPool = undefined,
        token: execution.CustodyToken = undefined,
        observed: bool = false,
        release_expected: bool = false,
        releases: usize = 0,

        fn now(context: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.release_expected) {
                std.debug.assert(self.slot.* == .bash);
                self.custody.checkDetached(self.token) catch unreachable;
                self.release_expected = false;
                self.releases += 1;
                return clock.now(std.testing.io);
            }
            // The completion timestamp is constructed before either native
            // publication or optional stderr. Inspect actual owner facts here.
            std.debug.assert(self.slot.* == .free);
            self.custody.checkFree(self.token) catch unreachable;
            checkSlotCustodyAgreement(@as([*]const ExecutionSlot, @ptrCast(self.slot))[0..1], self.custody) catch unreachable;
            self.observed = true;
            return clock.now(std.testing.io);
        }
    };
    var boundary: Boundary = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = Boundary.now;
    var records: [1]execution.CustodyRecord = undefined;
    var host = Host{
        .io = .{ .userdata = &boundary, .vtable = &vtable },
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .faults = .{ .test_phase_trace = true },
        .custody = execution.CustodyPool.initialize(&records),
    };
    var slot: ExecutionSlot = .free;
    boundary.slot = &slot;
    boundary.custody = &host.custody;
    // Both typed owners and admission-local Action custody before an
    // execution payload is installed share this boundary.
    for (0..3) |kind| {
        const token = host.custody.reserve().?;
        boundary.token = token;
        boundary.observed = false;
        if (kind == 0) {
            var permit = store_module.DispatchPermit{ .binding = .{
                .turn_id = 3,
                .operation_id = 7,
                .attempt_ordinal = 2,
            } };
            const binding = try host.custody.attach(token, &permit);
            slot = .{ .model_preparing = .{ .token = token, .binding = binding } };
            finishCustodyNow(&host, &slot, token);
        } else {
            var permit = store_module.ActionDispatchPermit{ .binding = .{
                .turn_id = 3,
                .parent_operation_id = 7,
                .action_id = 11,
                .attempt_ordinal = 2,
            } };
            const binding = try host.custody.attachAction(token, &permit);
            if (kind == 2) slot = .{ .bash_preparing = .{ .token = token, .binding = binding } };
            finishCustodyNow(&host, &slot, token);
        }
        try std.testing.expect(boundary.observed);
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    }

    // Exercise the distinct delayed Bash owner with real process/pipe
    // retirement and charged capture resources, not a model stand-in.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root});
    var storage = try store_module.Store.open(std.testing.io, database, root);
    defer storage.close() catch unreachable;
    const arguments = "{\"description\":\"Print test marker\",\"cmd\":\"printf x\",\"timeout_ms\":1000}";
    const content = try store_module.testingPublicProjection(&storage, &tmp, &.{.{
        .encoded = "{\\\"description\\\":\\\"Print test marker\\\",\\\"cmd\\\":\\\"printf x\\\",\\\"timeout_ms\\\":1000}",
        .decoded = arguments,
    }});
    const reader = try storage.openPublicConversationContent(content);
    var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
    try workspace.set(root);
    var used: std.atomic.Value(u64) = .init(0);
    const budget = protocol.ScratchBudget{ .used = &used, .limit = 4096 };
    var entries: [2]output_retention.Entry = undefined;
    var retention = output_retention.Queue.initialize(std.testing.io, root, budget, &entries);
    defer retention.cleanupAll();
    host.retention = &retention;
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try session.set("direct/bash");
    var preparation = switch (bash.startPreparation(std.testing.io, std.testing.allocator, reader, arguments.len, session, root, workspace, root, default_bash_path, 1000, budget, 11, 2, .{})) {
        .preparing => |value| value,
        .failed => |initial| {
            var failure = initial;
            try failure.cleanup.cleanup();
            return failure.cause;
        },
    };
    var preparation_owned = true;
    defer if (preparation_owned) {
        var cleanup = preparation.cancel();
        cleanup.cleanup() catch unreachable;
    };
    var prepared = while (true) {
        switch (preparation.advance()) {
            .pending => {},
            .prepared => |value| {
                preparation_owned = false;
                break value;
            },
            .failed => |initial| {
                preparation_owned = false;
                var failure = initial;
                try failure.cleanup.cleanup();
                return failure.cause;
            },
        }
    };
    defer prepared.cleanup() catch unreachable;
    const token = host.custody.reserve().?;
    var permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 3,
        .parent_operation_id = 7,
        .action_id = 11,
        .attempt_ordinal = 2,
    } };
    const binding = try host.custody.attachAction(token, &permit);
    try host.custody.detach(token);
    const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{
        .raw = .fromSeconds(5),
        .clock = .awake,
    });
    slot = .{ .bash = .{ .token = token, .binding = binding, .execution = try prepared.launch(&bash.empty_environment), .delivery = .{ .closed = .{ .reclaim_at = deadline } } } };
    var window: [bash.copy_window_bytes]u8 = undefined;
    defer if (slot == .bash) {
        slot.bash.execution.requestInfrastructureShutdown(.now(std.testing.io, .awake));
        const cleanup_deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{
            .raw = .fromSeconds(5),
            .clock = .awake,
        });
        while (!slot.bash.execution.retired()) {
            std.debug.assert(std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds < cleanup_deadline.raw.nanoseconds);
            _ = slot.bash.execution.service(&window);
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch unreachable;
        }
        slot.bash.execution.reclaim(&retention) catch unreachable;
    };
    while (!slot.bash.execution.retired()) {
        try std.testing.expect(std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds < deadline.raw.nanoseconds);
        const progress = slot.bash.execution.service(&window);
        try std.testing.expect(progress.fault == null);
        if (!progress.made_progress) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try slot.bash.execution.checkRetired();
    try std.testing.expectEqual(store_module.ActionResolutionCode.succeeded, (try slot.bash.execution.outcome(false)).code);
    // One captured stdout byte remains owned.
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    boundary.token = token;
    boundary.observed = false;
    var gate_path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    host.faults.bash_cleanup_gate_path = try std.fmt.bufPrint(&gate_path_buffer, "{s}/released-gate", .{root});
    // A released gate grants one reclamation transition, even if removal
    // fails repeatedly. The same charged capture and custody survive retry.
    slot.bash.execution.stdout_capture.cleanup_fault = .persistent;
    boundary.release_expected = true;
    try std.testing.expect(reclaimBash(&host, &slot, deadline));
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expect(!boundary.observed);
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    try checkSlotCustodyAgreement(@as([*]const ExecutionSlot, @ptrCast(&slot))[0..1], &host.custody);
    try std.testing.expect(!reclaimBash(&host, &slot, deadline));
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expectEqual(@as(u64, 1), used.load(.acquire));
    try host.custody.checkDetachedAction(token, binding);
    slot.bash.execution.stdout_capture.cleanup_fault = .none;
    try std.testing.expect(reclaimBash(&host, &slot, deadline));
    try std.testing.expect(boundary.observed);
    try std.testing.expectEqual(@as(usize, 1), boundary.releases);
    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "named scratch retry releases custody through the shutdown owner path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch_path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const scratch_path_length = try tmp.dir.realPath(std.testing.io, &scratch_path_buffer);
    var paths: platform.Paths = .{};
    try paths.scratch.set(scratch_path_buffer[0..scratch_path_length]);
    var lease = platform.StoreLease{
        .io = std.testing.io,
        .paths = paths,
        .store_dir = undefined,
        .lock_file = undefined,
    };
    var scratch = try std.Io.Dir.cwd().openDir(std.testing.io, lease.paths.scratch.slice(), .{});
    defer scratch.close(std.testing.io);
    const primary = try scratch.createFile(std.testing.io, "named-owner.tmp", .{ .read = true });
    const secondary = try scratch.openFile(std.testing.io, "named-owner.tmp", .{});
    var scratch_used: std.atomic.Value(u64) = .init(9);
    var removal_gate: std.atomic.Value(bool) = .init(true);
    var records: [1]execution.CustodyRecord = undefined;
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined,
        .faults = .{},
        .custody = execution.CustodyPool.initialize(&records),
    };
    const token = host.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const binding = try host.custody.attach(token, &permit);
    const owner = ModelPreparingSlot{ .token = token, .binding = binding };
    var slots = [_]ExecutionSlot{.{ .model_preparing = owner }};
    finishModelPreparationFailure(
        &host,
        &slots[0],
        owner,
        error.InjectedScratchRemovalFailure,
        .init(
            std.testing.io,
            primary,
            secondary,
            "named-owner.tmp",
            .{ .used = &scratch_used, .limit = 9 },
            9,
            .{ .gated = &removal_gate },
        ),
    );
    try std.testing.expect(slots[0] == .named_scratch);
    try std.testing.expect(host.dispatch_fenced.load(.acquire));
    try host.custody.checkDetachedModel(token, binding);

    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var retry_at = now;
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, now, &retry_at));
    try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
    try std.testing.expectEqual(@as(u64, 9), scratch_used.load(.acquire));
    _ = try scratch.statFile(std.testing.io, "named-owner.tmp", .{});

    var preparation: ?bash.Preparation = null;
    const Shutdown = struct {
        fn run(
            test_host: *Host,
            test_slots: []ExecutionSlot,
            test_preparation: *?bash.Preparation,
        ) void {
            var model_preparation: model_adapter.Preparation = undefined;
            shutdownExecution(
                test_host,
                null,
                test_slots,
                test_preparation,
                &model_preparation,
            );
        }
    };
    const shutdown = try std.Thread.spawn(
        .{},
        Shutdown.run,
        .{ &host, slots[0..], &preparation },
    );
    removal_gate.store(false, .release);
    shutdown.join();

    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expectEqual(@as(u64, 0), scratch_used.load(.acquire));
    try std.testing.expect(slots[0] == .free);
    try std.testing.expectError(
        error.FileNotFound,
        scratch.statFile(std.testing.io, "named-owner.tmp", .{}),
    );
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, now, &retry_at));
}

test "execution slots agree with custody across the complete population" {
    var records: [2]execution.CustodyRecord = undefined;
    var custody = execution.CustodyPool.initialize(&records);

    var model_permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const model_token = custody.reserve().?;
    const model_binding = try custody.attach(model_token, &model_permit);
    var action_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 1,
        .action_id = 2,
        .attempt_ordinal = 1,
    } };
    const action_token = custody.reserve().?;
    const action_binding = try custody.attachAction(action_token, &action_permit);

    var slots = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } },
        .{ .bash = .{
            .token = action_token,
            .binding = action_binding,
            .execution = undefined,
        } },
    };
    try checkSlotCustodyAgreement(&slots, &custody);

    // A foreign binding in one payload is rejected while the other still agrees.
    slots[0] = .{ .provider = .{ .owner = .{
        .token = model_token,
        .binding = .{ .turn_id = 9, .operation_id = 9, .attempt_ordinal = 9 },
    } } };
    try std.testing.expectError(error.ForeignLaunchAuthority, checkSlotCustodyAgreement(&slots, &custody));
    slots[0] = .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } };
    try checkSlotCustodyAgreement(&slots, &custody);

    // An occupied custody record with no owning slot is orphaned capacity:
    // attached or detached, it must fail the whole-execution check.
    var orphan = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = model_token, .binding = model_binding } } },
        .free,
    };
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&orphan, &custody));
    try custody.detach(action_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&orphan, &custody));
    var empty = [_]ExecutionSlot{ .free, .free };
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody));
    try custody.cleanupComplete(action_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody));
    try custody.detach(model_token);
    try std.testing.expectError(error.OrphanedExecutionCustody, checkSlotCustodyAgreement(&empty, &custody));
    try custody.cleanupComplete(model_token);
    try checkSlotCustodyAgreement(&empty, &custody);

    // Two payloads on one token collide instead of sharing it.
    const retoken = custody.reserve().?;
    var repermit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 3,
        .operation_id = 3,
        .attempt_ordinal = 1,
    } };
    const rebinding = try custody.attach(retoken, &repermit);
    var shared = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = retoken, .binding = rebinding } } },
        .{ .provider = .{ .owner = .{ .token = retoken, .binding = rebinding } } },
    };
    try std.testing.expectError(error.DuplicateExecutionToken, checkSlotCustodyAgreement(&shared, &custody));

    // A stale payload after reuse leaves the new owner unchanged.
    try custody.detach(retoken);
    try custody.cleanupComplete(retoken);
    const reused = custody.reserve().?;
    var reused_permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 1,
    } };
    const reused_binding = try custody.attach(reused, &reused_permit);
    var stale = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = retoken, .binding = rebinding } } },
    };
    try std.testing.expectError(error.StaleCustody, checkSlotCustodyAgreement(&stale, &custody));
    // The complete population names the current owner: no orphan remains.
    var current = [_]ExecutionSlot{
        .{ .provider = .{ .owner = .{ .token = reused, .binding = reused_binding } } },
    };
    try checkSlotCustodyAgreement(&current, &custody);
    try custody.detach(reused);
    try custody.cleanupComplete(reused);
}

test "no-work admission restores only its temporary custody reservation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite3", .{root});
    var storage = try store_module.Store.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;

    // Every call has genuinely free capacity and a real Store with no eligible
    // work. A represented sibling must survive release of the new reservation.
    const Kind = enum { bash, retry, message, tool_continuation };
    inline for (std.meta.tags(Kind)) |kind| {
        for ([_]bool{ false, true }) |with_sibling| {
            var records: [3]execution.CustodyRecord = undefined;
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = undefined,
                .store = &storage,
                .faults = .{},
                .custody = execution.CustodyPool.initialize(&records),
            };
            var slots = [_]ExecutionSlot{ .free, .free, .free };
            const sibling = if (with_sibling) host.custody.reserve().? else null;
            if (sibling) |token| {
                var permit = store_module.DispatchPermit{ .binding = .{
                    .turn_id = 17,
                    .operation_id = 23,
                    .attempt_ordinal = 2,
                } };
                const binding = try host.custody.attach(token, &permit);
                slots[1] = .{ .model_preparing = .{ .token = token, .binding = binding } };
            }
            defer if (sibling) |token| {
                host.custody.detach(token) catch unreachable;
                host.custody.cleanupComplete(token) catch unreachable;
            };
            const baseline: usize = if (with_sibling) 1 else 0;
            var model_preparation: model_adapter.Preparation = undefined;
            var bash_preparation: ?bash.Preparation = null;
            const progress = switch (kind) {
                .bash => admitBashAttempt(&host, &slots[0], &bash_preparation),
                .retry => admitRetryAttempt(&host, &slots[0], store_module.ActiveOperationFilter.empty(), &model_preparation),
                .message => admitNewAttempt(&host, &slots[0], .message, &model_preparation),
                .tool_continuation => admitNewAttempt(&host, &slots[0], .tool_continuation, &model_preparation),
            };
            try std.testing.expectEqual(AdmissionProgress.no_work, progress);
            try std.testing.expect(slots[0] == .free);
            try std.testing.expect(bash_preparation == null);
            try std.testing.expect(!host.dispatch_fenced.load(.acquire));
            try std.testing.expectEqual(baseline, host.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &host.custody);
            try std.testing.expect(!(try storage.inspectSession("direct/no-work")).found);

            // Restored accounting must mean immediately reusable capacity,
            // not just a corrected counter or accidental sibling release.
            var reused: [records.len]execution.CustodyToken = undefined;
            const free = records.len - baseline;
            for (reused[0..free]) |*token| token.* = host.custody.reserve() orelse return error.TestExpectedCapacity;
            try std.testing.expect(host.custody.reserve() == null);
            for (reused[0..free]) |token| try host.custody.releaseUnused(token);
            try std.testing.expectEqual(baseline, host.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &host.custody);
        }
    }
}

test "failed admission releases its reservation and fences the Store and dispatch" {
    // Message admission fails its real commit; every other admission meets the
    // Store that failure fenced. Each catch must release the new reservation.
    const Kind = enum { bash, retry, message, tool_continuation };
    inline for (std.meta.tags(Kind)) |kind| {
        for ([_]bool{ false, true }) |with_sibling| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var root_buffer: [protocol.max_store_bytes]u8 = undefined;
            const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
            var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
            const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
            var storage = try store_module.Store.open(std.testing.io, database, root);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
            defer directory.close(std.testing.io);
            const workspace = workspace_buffer[0..try directory.realPath(std.testing.io, &workspace_buffer)];
            var command: protocol.ConfigureCommand = .{};
            try command.key.set("failed-admission-config");
            try command.session.set("direct/failed-admission");
            command.configuration.workspace.state = .value;
            try command.configuration.workspace.value.set(workspace);
            command.configuration.provider.state = .value;
            try command.configuration.provider.value.set("codex");
            command.configuration.model.state = .value;
            try command.configuration.model.value.set("model-a");
            try std.testing.expect(storage.configure(&command, true, .{}) == .accepted);
            const file = try tmp.dir.createFile(std.testing.io, "failed-admission-message", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, "hello");
            try file.sync(std.testing.io);
            var message: protocol.MessageCommand = .{};
            try message.key.set("failed-admission-key");
            try message.session.set("direct/failed-admission");
            message.text = .{
                .state = .value,
                .file = file,
                .length = 5,
                .digest = protocol.contentDigest("hello"),
            };
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
            if (kind != .message) {
                try std.testing.expectError(
                    error.InjectedAttemptCommitFailure,
                    storage.admitModelAttempt(.message, .{ .attempt_before_commit = true }),
                );
                try std.testing.expect(storage.isFenced());
            }

            var records: [3]execution.CustodyRecord = undefined;
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = undefined,
                .store = &storage,
                .faults = .{ .attempt_before_commit = kind == .message },
                .custody = execution.CustodyPool.initialize(&records),
            };
            var slots = [_]ExecutionSlot{ .free, .free, .free };
            const sibling = if (with_sibling) host.custody.reserve().? else null;
            if (sibling) |token| {
                var permit = store_module.DispatchPermit{ .binding = .{
                    .turn_id = 17,
                    .operation_id = 23,
                    .attempt_ordinal = 2,
                } };
                const binding = try host.custody.attach(token, &permit);
                slots[1] = .{ .model_preparing = .{ .token = token, .binding = binding } };
            }
            defer if (sibling) |token| {
                host.custody.detach(token) catch unreachable;
                host.custody.cleanupComplete(token) catch unreachable;
            };
            const baseline: usize = if (with_sibling) 1 else 0;
            var model_preparation: model_adapter.Preparation = undefined;
            var bash_preparation: ?bash.Preparation = null;
            const progress = switch (kind) {
                .bash => admitBashAttempt(&host, &slots[0], &bash_preparation),
                .retry => admitRetryAttempt(&host, &slots[0], store_module.ActiveOperationFilter.empty(), &model_preparation),
                .message => admitNewAttempt(&host, &slots[0], .message, &model_preparation),
                .tool_continuation => admitNewAttempt(&host, &slots[0], .tool_continuation, &model_preparation),
            };
            try std.testing.expectEqual(AdmissionProgress.retry_later, progress);
            try std.testing.expect(storage.isFenced());
            try std.testing.expect(host.dispatch_fenced.load(.acquire));
            try std.testing.expect(slots[0] == .free);
            try std.testing.expect(bash_preparation == null);
            try std.testing.expectEqual(baseline, host.custody.occupied());
            try checkSlotCustodyAgreement(&slots, &host.custody);

            var reused: [records.len]execution.CustodyToken = undefined;
            const free = records.len - baseline;
            for (reused[0..free]) |*token| token.* = host.custody.reserve() orelse return error.TestExpectedCapacity;
            try std.testing.expect(host.custody.reserve() == null);
            for (reused[0..free]) |token| try host.custody.releaseUnused(token);
            try std.testing.expectEqual(baseline, host.custody.occupied());
        }
    }
}

test "closed Bash delivery retains its payload with detached custody" {
    var records: [2]execution.CustodyRecord = undefined;
    var lease = platform.StoreLease{
        .io = std.testing.io,
        .paths = .{},
        .store_dir = undefined,
        .lock_file = undefined,
    };
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined,
        .faults = .{},
        .custody = execution.CustodyPool.initialize(&records),
    };
    const token = host.custody.reserve().?;
    var permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 1,
        .action_id = 2,
        .attempt_ordinal = 1,
    } };
    const binding = try host.custody.attachAction(token, &permit);
    var slots = [_]ExecutionSlot{
        .{ .bash = .{
            .token = token,
            .binding = binding,
            .execution = undefined,
        } },
    };
    try checkSlotCustodyAgreement(&slots, &host.custody);

    // The real delivery-close transition detaches custody while retaining
    // the .bash payload for reclamation: the checker must accept it.
    closeBashDelivery(&host, &slots[0].bash);
    try std.testing.expect(slots[0].bash.delivery == .closed);
    try host.custody.checkDetachedAction(token, binding);
    try checkSlotCustodyAgreement(&slots, &host.custody);
    // The flagged failed-reclamation state is accepted by the checker. This
    // covers the flag value only: no failing reclaimer runs here and no Bash
    // resources are retained through retry.
    slots[0].bash.delivery.closed.reclaim_failed = true;
    try checkSlotCustodyAgreement(&slots, &host.custody);

    // Closed delivery with still-attached custody is the invalid shape:
    // it must fail rather than pass as a retained payload.
    const second = host.custody.reserve().?;
    var second_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 4,
        .parent_operation_id = 4,
        .action_id = 5,
        .attempt_ordinal = 1,
    } };
    const second_binding = try host.custody.attachAction(second, &second_permit);
    const bad = [_]ExecutionSlot{
        .{ .bash = .{
            .token = second,
            .binding = second_binding,
            .execution = undefined,
            .delivery = .{ .closed = .{
                .reclaim_at = std.Io.Clock.Timestamp.now(std.testing.io, .awake),
            } },
        } },
        .free,
    };
    // Complete population: the first slot's detached token plus the bad
    // slot's attached token account for both occupied records, so the
    // failure below is the custody-state mismatch, not an orphan.
    var both = [_]ExecutionSlot{ slots[0], bad[0] };
    try std.testing.expectError(error.InvalidCustodyTransition, checkSlotCustodyAgreement(&both, &host.custody));
    try host.custody.detach(second);
    try host.custody.cleanupComplete(second);
    try host.custody.cleanupComplete(token);
    slots[0] = .free;
    try checkSlotCustodyAgreement(&slots, &host.custody);
}

test "closed Bash payloads keep their typed binding identity" {
    var records: [2]execution.CustodyRecord = undefined;
    var custody = execution.CustodyPool.initialize(&records);
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);

    var first_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 1,
        .action_id = 1,
        .attempt_ordinal = 1,
    } };
    const first_token = custody.reserve().?;
    const first_binding = try custody.attachAction(first_token, &first_permit);
    var second_permit = store_module.ActionDispatchPermit{ .binding = .{
        .turn_id = 2,
        .parent_operation_id = 2,
        .action_id = 2,
        .attempt_ordinal = 1,
    } };
    const second_token = custody.reserve().?;
    const second_binding = try custody.attachAction(second_token, &second_permit);
    try custody.detach(first_token);
    try custody.detach(second_token);

    var slots = [_]ExecutionSlot{
        .{ .bash = .{
            .token = first_token,
            .binding = first_binding,
            .execution = undefined,
            .delivery = .{ .closed = .{ .reclaim_at = now } },
        } },
        .{ .bash = .{
            .token = second_token,
            .binding = second_binding,
            .execution = undefined,
            .delivery = .{ .closed = .{ .reclaim_at = now } },
        } },
    };
    try checkSlotCustodyAgreement(&slots, &custody);

    slots[0].bash.token = second_token;
    slots[1].bash.token = first_token;
    try std.testing.expectError(error.ForeignLaunchAuthority, checkSlotCustodyAgreement(&slots, &custody));
    slots[0].bash.token = first_token;
    slots[1].bash.token = second_token;
    try checkSlotCustodyAgreement(&slots, &custody);
    try custody.cleanupComplete(first_token);
    try custody.cleanupComplete(second_token);
}

test "preparing slots belong to their live preparations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage = try store_module.Store.open(std.testing.io, database, root);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer directory.close(std.testing.io);
    const workspace = workspace_buffer[0..try directory.realPath(std.testing.io, &workspace_buffer)];
    var command: protocol.ConfigureCommand = .{};
    try command.key.set("prep-belong-config");
    try command.session.set("direct/prep-belong");
    command.configuration.workspace.state = .value;
    try command.configuration.workspace.value.set(workspace);
    command.configuration.provider.state = .value;
    try command.configuration.provider.value.set("codex");
    command.configuration.model.state = .value;
    try command.configuration.model.value.set("model-a");
    try std.testing.expect(storage.configure(&command, true, .{}) == .accepted);
    const file = try tmp.dir.createFile(std.testing.io, "prep-belong-message", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, "hello");
    try file.sync(std.testing.io);
    var message: protocol.MessageCommand = .{};
    try message.key.set("prep-belong-key");
    try message.session.set("direct/prep-belong");
    message.text = .{
        .state = .value,
        .file = file,
        .length = 5,
        .digest = protocol.contentDigest("hello"),
    };
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);
    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding_a = try admitted.permit.consume();

    // A live preparation for Attempt A, held in final storage under test
    // ownership with a guard beside the acquisition.
    const view = try storage.openHistoricalView(binding_a);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var preparation: model_adapter.Preparation = undefined;
    try preparation.init(std.testing.io, view, root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
    var preparation_active = true;
    defer if (preparation_active) preparation.cancel();

    var records: [1]execution.CustodyRecord = undefined;
    var custody = execution.CustodyPool.initialize(&records);
    // A valid slot/custody binding for a different Attempt B: internally
    // consistent, but it does not belong to the live preparation.
    const token = custody.reserve().?;
    var permit_b = store_module.DispatchPermit{ .binding = .{
        .turn_id = binding_a.turn_id + 100,
        .operation_id = binding_a.operation_id + 100,
        .attempt_ordinal = binding_a.attempt_ordinal,
    } };
    const binding_b = try custody.attach(token, &permit_b);
    var mismatched = [_]ExecutionSlot{
        .{ .model_preparing = .{ .token = token, .binding = binding_b } },
    };
    try checkSlotCustodyAgreement(&mismatched, &custody);
    try std.testing.expectError(error.PreparationBindingMismatch, checkSharedPreparation(&mismatched, &preparation, null));

    // The slot naming Attempt A belongs together with the live preparation.
    var matched = [_]ExecutionSlot{
        .{ .model_preparing = .{ .token = token, .binding = binding_a } },
    };
    // Re-anchor custody to A so each layer agrees before composing them.
    try custody.detach(token);
    try custody.cleanupComplete(token);
    const retoken = custody.reserve().?;
    var permit_a = store_module.DispatchPermit{ .binding = binding_a };
    const attached_a = try custody.attach(retoken, &permit_a);
    matched[0] = .{ .model_preparing = .{ .token = retoken, .binding = attached_a } };
    try checkSlotCustodyAgreement(&matched, &custody);
    try checkSharedPreparation(&matched, &preparation, null);

    // No live preparation with a preparing slot, and vice versa.
    var empty = [_]ExecutionSlot{.free};
    try std.testing.expectError(error.PreparationOwnershipMismatch, checkSharedPreparation(&empty, &preparation, null));
    try std.testing.expectError(error.PreparationOwnershipMismatch, checkSharedPreparation(&matched, null, null));
    try checkSharedPreparation(&empty, null, null);

    // Bash correspondence uses only the facts its preparation owns.
    var bash_preparation = bash.Preparation{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .session = .{},
        .store_selector = root,
        .workspace = .{},
        .scratch_path = root,
        .bash_path = default_bash_path,
        .timeout_ms = 1,
        .action_id = 7,
        .attempt_ordinal = 1,
        .faults = .{},
        .source = undefined,
        .cleanup = .{ .scratch_path = root },
    };
    var bash_matched = [_]ExecutionSlot{
        .{ .bash_preparing = .{ .token = retoken, .binding = .{
            .turn_id = 1,
            .parent_operation_id = 1,
            .action_id = 7,
            .attempt_ordinal = 1,
        } } },
    };
    // Note: retoken is model-attached above, so slot/custody agreement is
    // not asserted for this slice; only preparation correspondence is.
    try checkSharedPreparation(&bash_matched, null, &bash_preparation);
    bash_matched[0].bash_preparing.binding.action_id = 8;
    try std.testing.expectError(error.PreparationOwnershipMismatch, checkSharedPreparation(&bash_matched, null, &bash_preparation));

    try custody.detach(retoken);
    try custody.cleanupComplete(retoken);
    preparation.cancel();
    preparation_active = false;
}

test "retained named scratch blocks its slot until the same owner reclaims" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch_path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const scratch_path_length = try tmp.dir.realPath(std.testing.io, &scratch_path_buffer);
    var paths: platform.Paths = .{};
    try paths.scratch.set(scratch_path_buffer[0..scratch_path_length]);
    var lease = platform.StoreLease{
        .io = std.testing.io,
        .paths = paths,
        .store_dir = undefined,
        .lock_file = undefined,
    };
    var scratch = try std.Io.Dir.cwd().openDir(std.testing.io, lease.paths.scratch.slice(), .{});
    defer scratch.close(std.testing.io);
    const primary = try scratch.createFile(std.testing.io, "named-direct.tmp", .{ .read = true });
    const secondary = try scratch.openFile(std.testing.io, "named-direct.tmp", .{});
    var scratch_used: std.atomic.Value(u64) = .init(9);
    var removal_gate: std.atomic.Value(bool) = .init(true);
    var records: [1]execution.CustodyRecord = undefined;
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = &lease,
        .store = undefined,
        .faults = .{},
        .custody = execution.CustodyPool.initialize(&records),
    };
    const token = host.custody.reserve().?;
    var permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const binding = try host.custody.attach(token, &permit);
    try std.testing.expectEqual(@as(u64, 1), binding.operation_id);
    try host.custody.detach(token);
    var slots = [_]ExecutionSlot{.{ .named_scratch = .{
        .token = token,
        .owner = .init(
            std.testing.io,
            primary,
            secondary,
            "named-direct.tmp",
            .{ .used = &scratch_used, .limit = 9 },
            9,
            .{ .gated = &removal_gate },
        ),
    } }};

    // Removal blocked: the actual release caller retains the slot, the
    // detached custody, the reservation, and the pathname. No admission
    // can reuse that capacity.
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var retry_at = start;
    var reclaimed = false;
    errdefer if (!reclaimed) {
        removal_gate.store(false, .release);
        var retry = retry_at;
        _ = advanceRetainedCleanup(&host, &slots, retry, &retry);
    };
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, start, &retry_at));
    try host.custody.checkDetached(token);
    try checkSlotCustodyAgreement(&slots, &host.custody);
    try checkSharedPreparation(&slots, null, null);
    try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
    try std.testing.expectEqual(@as(usize, 0), countFreeSlots(&slots));
    try std.testing.expectEqual(@as(u64, 9), scratch_used.load(.acquire));
    _ = try scratch.statFile(std.testing.io, "named-direct.tmp", .{});

    // The same instant is too early for the low-frequency retry.
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, start, &retry_at));

    // After the fault clears, the same production path reclaims the owner
    // before completing custody, and the slot becomes reusable.
    removal_gate.store(false, .release);
    try std.testing.expect(advanceRetainedCleanup(&host, &slots, retry_at, &retry_at));
    reclaimed = true;
    try host.custody.checkFree(token);
    try checkSlotCustodyAgreement(&slots, &host.custody);
    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expectEqual(@as(usize, 1), countFreeSlots(&slots));
    try std.testing.expectEqual(@as(u64, 0), scratch_used.load(.acquire));
    try std.testing.expect(slots[0] == .free);
    try std.testing.expectError(
        error.FileNotFound,
        scratch.statFile(std.testing.io, "named-direct.tmp", .{}),
    );
    try std.testing.expect(!advanceRetainedCleanup(&host, &slots, retry_at, &retry_at));
}

test "provider metadata uses shared scratch reclamation without widening its limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const root_budget = protocol.ScratchBudget{ .used = &used, .limit = 104 };
    var entries: [2]output_retention.Entry = undefined;
    var retention = output_retention.Queue.initialize(std.testing.io, root, root_budget, &entries);
    defer retention.cleanupAll();

    var stdout = try tmp.dir.createFile(std.testing.io, "stdout", .{ .read = true });
    var stderr_file = try tmp.dir.createFile(std.testing.io, "stderr", .{ .read = true });
    try std.testing.expect(root_budget.charge(2));
    const pair = (try retention.reservePair("stdout", 1, "stderr", 1)).?;
    var retained_metadata: ?named_scratch.Owner = null;
    var metadata = try output_format.OutputMetadataWriter.init(
        std.testing.io,
        root,
        "metadata",
        retention.sharedBudget(),
        false,
        &retained_metadata,
    );
    try std.testing.expectError(
        error.MetadataScratchExhausted,
        metadata.append(.{ .tag = .usage, .start = 0, .length = 0 }),
    );
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), retention.occupied());

    stdout.close(std.testing.io);
    stderr_file.close(std.testing.io);
    try retention.publishPair(pair);
    try metadata.append(.{ .tag = .usage, .start = 0, .length = 0 });
    try std.testing.expectEqual(@as(u64, 104), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), retention.occupied());
    metadata.deinit();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));

    var limited = try output_format.OutputMetadataWriter.init(
        std.testing.io,
        root,
        "limited-metadata",
        retention.sharedBudget().narrowed(103),
        false,
        &retained_metadata,
    );
    defer limited.deinit();
    try std.testing.expectError(
        error.MetadataScratchExhausted,
        limited.append(.{ .tag = .usage, .start = 0, .length = 0 }),
    );
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
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

    var code: protocol.Bounded(96) = .{};
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
    try std.testing.expect(response.len <= protocol.max_message_observation_bytes);
}

test "control response variants fit exact worst-case JSON bounds" {
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
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
    } }, protocol.max_session_stop_accepted_reply_bytes);
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
    } }, protocol.max_session_stop_rejected_reply_bytes);
    try Cases.expectStop(&stop_command, .conflict, protocol.max_session_stop_conflict_reply_bytes);
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
        protocol.max_model_interruption_accepted_reply_bytes,
    );
    try Cases.expectInterruption(&interruption_command, .{ .rejected = .{
        .replayed = false,
        .code = .invalid_session_reference,
    } }, protocol.max_model_interruption_rejected_reply_bytes);
    try Cases.expectInterruption(
        &interruption_command,
        .conflict,
        protocol.max_model_interruption_conflict_reply_bytes,
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
    try Cases.expectObservation(&escaped_key, stop_accepted, protocol.max_session_stop_accepted_observation_bytes);

    var stop_rejected = store_module.CommandObservation{ .status = .rejected, .kind = .session_stop };
    try stop_rejected.target.set(&escaped_session);
    try stop_rejected.code.set("invalid_session_reference");
    try Cases.expectObservation(&escaped_key, stop_rejected, protocol.max_session_stop_rejected_observation_bytes);

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
        protocol.max_model_interruption_accepted_observation_bytes,
    );

    var interruption_rejected = store_module.CommandObservation{
        .status = .rejected,
        .kind = .model_interruption,
        .model_interruption = target,
    };
    try interruption_rejected.target.set(&escaped_session);
    try interruption_rejected.code.set("invalid_session_reference");
    try Cases.expectObservation(
        &escaped_key,
        interruption_rejected,
        protocol.max_model_interruption_rejected_observation_bytes,
    );
}

test "retired reserved exchanges cannot block their successors while workers are occupied" {
    for (std.enums.values(Route)) |route| {
        if (!route.isControl() and route != .host_info) continue;
        for ([_]Intake.Exchange.State{ .retired, .closed }) |retired_state| {
            var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .faults = .{}, .intake_capacity = descriptor_capacity.minimum_intake };
            var intake: Intake = .{ .host = &host };
            host.intake = &intake;
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
                host.intake = &intake;
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
                        try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(sockets[1], std.c.SHUT.WR));
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
        host.intake = &intake;
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
                try ingress.feed("{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"text\":{\"state\":\"value\",\"value\":\"abc\"");
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
    var exchange = Intake.Exchange{ .host = &host, .fd = -1, .accepted_at_ns = 0, .deadline = 0 };
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
    host.effect_shutdown.store(true, .release);
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
        try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(sockets[0], std.c.SHUT.WR));
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
                try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(fd, std.c.SHUT.WR));
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
    const message = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"text\":{\"state\":\"value\",\"value\":\"" ++
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
        try configure.session.set("peer");
        configure.configuration.workspace.state = .value;
        try configure.configuration.workspace.value.set(root);
        configure.configuration.provider.state = .value;
        try configure.configuration.provider.value.set("codex");
        configure.configuration.model.state = .value;
        try configure.configuration.model.value.set("model-a");
        try std.testing.expect(storage.configure(&configure, true, .{}) == .accepted);
        var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage, .instance = @splat(0), .faults = .{} };
        var retention = output_retention.Queue.initialize(io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
        host.retention = &retention;
        var intake: Intake = undefined;
        try intake.init(&host);
        defer intake.deinit();
        host.intake = &intake;
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
            host.effect_shutdown.store(true, .release);
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
        for ([_]struct { route: []const u8, body: []const u8, key: []const u8, kind: store_module.CommandKind, status: @FieldType(store_module.CommandObservation, "status") }{
            .{ .route = "/v1/control/session-stop", .body = "{\"version\":\"1\",\"kind\":\"session_stop\",\"store\":\"s\",\"key\":\"stop\",\"session\":\"peer\"}", .key = "stop", .kind = .session_stop, .status = .accepted },
            .{ .route = "/v1/control/model-interruption", .body = "{\"version\":\"1\",\"kind\":\"model_interruption\",\"store\":\"s\",\"key\":\"interrupt\",\"target\":{\"session\":\"peer\",\"turn\":\"1\",\"operation\":\"1\"}}", .key = "interrupt", .kind = .model_interruption, .status = .rejected },
            .{ .route = "/v1/control/permission-decision", .body = "{\"version\":\"1\",\"kind\":\"permission_decision\",\"store\":\"s\",\"key\":\"decision\",\"session\":\"peer\",\"action\":\"1\",\"decision\":\"deny\"}", .key = "decision", .kind = .permission_decision, .status = .rejected },
        }) |control| {
            const peer = try address.connect(std.testing.io);
            defer peer.socket.close(std.testing.io);
            try Probe.send(peer.socket.handle, control.route, control.body, false);
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
        try std.testing.expect(host.effect_shutdown.load(.acquire));
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
                exchange.* = .{ .host = &host, .fd = sockets[0], .accepted_at_ns = 0, .deadline = 10 * std.time.ns_per_s };
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
    const body = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"text\":{\"state\":\"value\",\"value\":\"" ++ payload ++ "\"}}";
    var header_buffer: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/message HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: {d}\r\n\r\n", .{body.len});
    try writeAll(std.testing.io, sockets[1], header);
    try writeAll(std.testing.io, sockets[1], body);
    const exchange = try std.testing.allocator.create(Intake.Exchange);
    exchange.* = .{ .host = &host, .fd = sockets[0], .accepted_at_ns = std.time.ns_per_s, .deadline = 10 * std.time.ns_per_s };
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
    const prefix = "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"text\":{\"state\":\"value\",\"value\":\"";
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
        exchange.* = .{ .host = &host, .fd = sockets[0], .accepted_at_ns = 0, .deadline = 0, .state = .retired };
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

test "Host fences dispose admitted preparation without touching canonical state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    inline for (.{ "dispatch_fenced", "execution_shutdown", "effect_shutdown" }) |flag| {
        var records: [1]execution.CustodyRecord = undefined;
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined, // The suppression path must not query or settle.
            .faults = .{},
            .custody = execution.CustodyPool.initialize(&records),
        };
        const token = host.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 1,
            .operation_id = 1,
            .attempt_ordinal = 1,
        } };
        const binding = try host.custody.attach(token, &permit);
        var preparation: model_adapter.Preparation = undefined;
        var retained: ?named_scratch.Owner = null;
        try preparation.init(
            std.testing.io,
            .{ .store = undefined, .binding = binding },
            root,
            .{ .used = &host.scratch_used, .limit = 1024 },
            .{},
            &retained,
        );
        // Real file aliases and a real reservation are owned before fencing.
        try preparation.writer.write("partial request");
        var slots = [_]ExecutionSlot{.{ .model_preparing = .{
            .token = token,
            .binding = binding,
        } }};
        @field(host, flag).store(true, .release);
        try std.testing.expect(advanceModelPreparation(
            &host,
            null,
            &slots,
            &preparation,
            host.limits.request_preparation_byte_allowance,
            host.limits.request_preparation_item_allowance,
        ));
        try std.testing.expect(!preparation.active and !preparation.view.active);
        try std.testing.expect(slots[0] == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    }
}

test "Host fences dispose a sealed request before native transfer construction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "dispatch_fenced", "execution_shutdown", "effect_shutdown" }) |flag| {
        var records: [1]execution.CustodyRecord = undefined;
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{},
            .custody = execution.CustodyPool.initialize(&records),
        };
        const token = host.custody.reserve().?;
        var permit = store_module.DispatchPermit{ .binding = .{
            .turn_id = 1,
            .operation_id = 1,
            .attempt_ordinal = 1,
        } };
        const binding = try host.custody.attach(token, &permit);
        const writer = try tmp.dir.createFile(std.testing.io, "sealed", .{});
        try writer.writeStreamingAll(std.testing.io, "{}");
        writer.close(std.testing.io);
        const reader = try tmp.dir.openFile(std.testing.io, "sealed", .{});
        try tmp.dir.deleteFile(std.testing.io, "sealed");
        host.scratch_used.store(2, .release);
        var request = provider.PreparedRequest{
            .io = std.testing.io,
            .file = reader,
            .length = 2,
            .charged = 2,
            .budget = .{ .used = &host.scratch_used, .limit = 2 },
            .structured_output = false,
            .session_affinity = @splat(0),
        };
        const owner = ModelPreparingSlot{ .token = token, .binding = binding };
        var slot = ExecutionSlot{ .model_preparing = owner };
        var reactor: provider.Reactor = undefined; // Must never be accessed.
        @field(host, flag).store(true, .release);
        launchPreparedRequest(&host, &reactor, &slot, owner, &request, null);
        try std.testing.expect(slot == .free);
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    }
}

test "effect launch gate rechecks every Host suppression combination" {
    const Launch = struct {
        fn run(calls: *usize) !void {
            calls.* += 1;
        }
    };
    for (0..8) |mask| {
        var host = Host{
            .io = std.testing.io,
            .allocator = std.testing.allocator,
            .lease = undefined,
            .store = undefined,
            .faults = .{},
        };
        // The preflight result is deliberately stale before the real gate.
        try std.testing.expect(host.launchAllowed());
        host.dispatch_fenced.store(mask & 1 != 0, .release);
        host.execution_shutdown.store(mask & 2 != 0, .release);
        host.effect_shutdown.store(mask & 4 != 0, .release);
        var calls: usize = 0;
        if (mask == 0) {
            try host.withEffectLaunch(&calls, Launch.run);
            try std.testing.expectEqual(@as(usize, 1), calls);
        } else {
            try std.testing.expectError(error.HostDispatchSuppressed, host.withEffectLaunch(&calls, Launch.run));
            try std.testing.expectEqual(@as(usize, 0), calls);
        }
    }
}

test "effect launch gate releases its mutex after native failure" {
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .faults = .{},
    };
    const Launch = struct {
        fn fail(calls: *usize) !void {
            calls.* += 1;
            return error.TestLaunchFailure;
        }

        fn succeed(calls: *usize) !void {
            calls.* += 1;
        }
    };
    var calls: usize = 0;
    try std.testing.expectError(error.TestLaunchFailure, host.withEffectLaunch(&calls, Launch.fail));
    try host.withEffectLaunch(&calls, Launch.succeed);
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "Host fences discard prepared Bash without settling and retain failed cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var paths: platform.Paths = .{};
    try paths.scratch.set(root);
    var lease = platform.StoreLease{
        .io = std.testing.io,
        .paths = paths,
        .store_dir = undefined,
        .lock_file = undefined,
    };
    inline for (.{ "dispatch_fenced", "execution_shutdown", "effect_shutdown" }) |flag| {
        for ([_]bool{ false, true }) |fail_cleanup| {
            var records: [1]execution.CustodyRecord = undefined;
            var host = Host{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .lease = &lease,
                .store = undefined, // No canonical query, cancellation, or result.
                .faults = .{},
                .custody = execution.CustodyPool.initialize(&records),
            };
            const token = host.custody.reserve().?;
            var permit = store_module.ActionDispatchPermit{ .binding = .{
                .turn_id = 1,
                .parent_operation_id = 1,
                .action_id = 1,
                .attempt_ordinal = 1,
            } };
            const binding = try host.custody.attachAction(token, &permit);
            const file = try tmp.dir.createFile(std.testing.io, "suppressed-bash", .{});
            try file.writeStreamingAll(std.testing.io, "output\n");
            var name: protocol.Bounded(96) = .{};
            try name.set("suppressed-bash");
            host.scratch_used.store(7, .release);
            if (fail_cleanup) {
                const gate = try tmp.dir.createFile(std.testing.io, bash.fault_gate_name, .{});
                gate.close(std.testing.io);
            }
            var prepared = bash.Prepared{
                .io = std.testing.io,
                .allocator = std.testing.allocator,
                .session = .{},
                .store_selector = "",
                .workspace = .{},
                .scratch_path = root,
                .bash_path = undefined, // Native construction must not run.
                .timeout_ms = 1,
                .faults = .{},
                .command = try std.testing.allocator.dupeSentinel(u8, "exit 0", 0),
                .stdout_capture = .{
                    .io = std.testing.io,
                    .file = file,
                    .name = name,
                    .charged = 7,
                    .budget = .{ .used = &host.scratch_used, .limit = 7 },
                    .cleanup_fault = if (fail_cleanup) .gated else .none,
                },
                .stderr_capture = null,
            };
            var slots = [_]ExecutionSlot{.{ .bash_preparing = .{
                .token = token,
                .binding = binding,
            } }};
            @field(host, flag).store(true, .release);
            launchPreparedBash(&host, &slots[0], token, binding, &prepared);
            try std.testing.expect(prepared.stdout_capture == null);
            try std.testing.expect(prepared.command == null);
            // A retained cleanup fence must not become an effect shutdown.
            try std.testing.expectEqual(std.mem.eql(u8, flag, "effect_shutdown"), host.effect_shutdown.load(.acquire));
            if (fail_cleanup) {
                try std.testing.expect(slots[0] == .bash_prepared_cleanup);
                try std.testing.expect(slots[0].bash_prepared_cleanup.cleanup.stdout_capture.?.file == null);
                try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
                try std.testing.expectEqual(@as(u64, 7), host.scratch_used.load(.acquire));
                try tmp.dir.deleteFile(std.testing.io, bash.fault_gate_name);
                const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
                var retry_at = now;
                try std.testing.expect(advanceRetainedCleanup(&host, &slots, now, &retry_at));
            }
            try std.testing.expect(slots[0] == .free);
            try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
            try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "suppressed-bash", .{}));
        }
    }
}
