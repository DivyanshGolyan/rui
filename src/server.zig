const std = @import("std");
const change_ring = @import("change_ring.zig");
const activity_reply = @import("activity_reply.zig");
const os = @import("os");
const socket_os = os.socket;
const pages = @import("os/pages.zig");
const HostDiagnostics = @import("HostDiagnostics.zig");
const HostStartupWait = @import("HostStartupWait.zig");
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
const host_endpoint = @import("host_endpoint.zig");
const provider = @import("provider.zig");
const providers = @import("providers.zig");
const protocol = @import("protocol.zig");
const command_spec = @import("command_spec.zig");
const host_reply = @import("host_reply.zig");
const host_drain = @import("host_drain.zig");
const ScratchBudget = @import("ScratchBudget.zig");
const wire_request = @import("wire_request.zig");
const store_module = @import("store.zig");
const session_list_reply = @import("session_list_reply.zig");
const session_report_reply = @import("session_report_reply.zig");
const host_settings = @import("host_settings.zig");
const server_mcp_settings = @import("server_mcp_settings.zig");
const MysqlUrl = @import("mysql_url.zig");
const start_report = @import("start_report.zig");
const core_tools = @import("core_tools.zig");
const tools = @import("tools.zig");
const mcp_offered = @import("mcp/offered.zig");
const server_mcp_relist = @import("server_mcp_relist.zig");
const relist = @import("mcp/relist.zig");
const stderr = @import("stderr.zig");
const server_execution = @import("server_execution.zig");
const server_host = @import("server_host.zig");
const child_exit_wake = @import("child_exit_wake.zig");
const line_intake = @import("line_intake.zig");
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
const nowNs = server_host.nowNs;
const traceSubject = server_host.traceSubject;
const traceRequest = server_host.traceRequest;
const executionFacts = server_host.executionFacts;
const waitAtTestGate = server_host.waitAtTestGate;
const traceSqliteDiagnostic = server_host.traceSqliteDiagnostic;

// Rare work with a 4 KiB capture of its own: noinline keeps the capture off
// the frame of every session inspection.
noinline fn captureFailedResponse(host: *Host, request: *const protocol.InspectSession, request_number: u64) !store_module.SessionReport {
    const selection = request.failed_response.?;
    const binding = try host.store.failedResponseBinding(request.session.slice(), selection.operation, selection.attempt);
    var capture: store_module.SessionReportCapture = .{ .io = host.io, .writer = null, .budget = host.retention.sharedBudget() };
    try capture.create(host.lease.paths.scratch.slice(), request_number, host.probes.fails(.report_unlink));
    errdefer capture.deinit();
    try failed_responses.exportRecord(host.io, host.lease.store_dir, binding, selection.part, &capture);
    return capture.seal();
}

const intake_worker_stack_bytes = 1024 * 1024;

const StopSignals = struct {
    const signals = .{ std.posix.SIG.INT, std.posix.SIG.TERM, std.posix.SIG.HUP };

    var asked: std.atomic.Value(bool) = .init(false);
    var wake: std.atomic.Value(std.posix.fd_t) = .init(-1);
    var writing: std.atomic.Value(u32) = .init(0);

    var previous: [signals.len]std.posix.Sigaction = undefined;

    noinline fn install() void {
        var blocked = std.posix.sigemptyset();
        inline for (signals) |signal| std.posix.sigaddset(&blocked, signal);
        var previous_mask: std.posix.sigset_t = undefined;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, &previous_mask);
        defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
        asked.store(false, .release);
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = handle }, .mask = std.posix.sigemptyset(), .flags = 0 };
        inline for (signals, 0..) |signal, i| std.posix.sigaction(signal, &action, &previous[i]);
    }

    noinline fn restore() void {
        inline for (signals, 0..) |signal, i| std.posix.sigaction(signal, &previous[i], null);
    }

    fn handle(_: std.posix.SIG) callconv(.c) void {
        asked.store(true, .seq_cst);
        _ = writing.fetchAdd(1, .seq_cst);
        defer _ = writing.fetchSub(1, .seq_cst);
        const fd = wake.load(.seq_cst);
        if (fd < 0) return;
        const saved = std.c._errno().*;
        hint(fd);
        std.c._errno().* = saved;
    }

    /// Coalesced: a full nonblocking socket is already readable. Never raises
    /// SIGPIPE: MSG_NOSIGNAL on Linux, SO_NOSIGPIPE set by `Intake.init` on
    /// Darwin.
    fn hint(fd: std.posix.fd_t) void {
        _ = std.c.send(fd, "x", 1, socket_os.send_flags);
    }

    fn attach(fd: std.posix.fd_t) void {
        wake.store(fd, .seq_cst);
        if (asked.load(.seq_cst)) hint(fd);
    }

    fn detach() void {
        wake.store(-1, .seq_cst);
        while (writing.load(.seq_cst) != 0) std.atomic.spinLoopHint();
    }

    fn apply(host: *Host) void {
        if (asked.swap(false, .seq_cst)) _ = host.lifecycle.stopAsked();
    }
};

const Intake = struct {
    host: *Host,
    wake: [2]std.posix.fd_t = undefined,
    exchanges: std.ArrayList(*Exchange) = .empty,
    polls: std.ArrayList(std.c.pollfd) = .empty,
    workers: [2]Worker = undefined,
    threads: [2]std.Thread = undefined,
    started: usize = 0,
    stdin: ?std.posix.fd_t = null,
    lifetime: host_settings.Interface.Lifetime = .detached,
    deadline_armed: bool = false,
    /// Held lines, outside `intake_capacity`; served on this thread only.
    lines: line_intake.Pool = .{},

    /// Upgrades an exchange whose headers named `GET /v1/line`. Lines are refused while
    /// the Store is fenced or the Host stops. The ring's lock is held only to read its
    /// newest generation and open the waker, not to allocate the line.
    fn upgradeLine(self: *Intake, exchange: *Exchange, leftover: []const u8) !void {
        if (exchange.header.instance) |identity| {
            if (!std.mem.eql(u8, &identity, &self.host.instance)) return error.HostInstanceChanged;
        }
        if (self.host.store.isFenced()) return error.CanonicalStoreFailure;
        if (self.host.lifecycle.stopping()) return error.HostStopping;
        const index = try self.lines.open(self.host.allocator, self.host.instance, exchange.fd, leftover, nowNs(self.host.io) / std.time.ns_per_ms);
        self.host.store.lockChanges();
        self.lines.admit(index, self.host.store.changes.newest);
        self.host.store.unlockChanges();
        exchange.fd = -1;
        exchange.state = .closed;
    }

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
        request: ?*wire_request.Request = null,
        reply: ?*Reply = null,
        retained_scratch: ?named_scratch.Owner = null,
        cleanup_retry_at: i128 = 0,
        environment: ?SessionEnvironments.Offer = null,
        environment_received: usize = 0,

        fn retireUnhanded(self: *Exchange) void {
            if (self.job == .fill or self.job == .cleanup) return;
            switch (self.state) {
                .header, .body => self.state = .retired,
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
            const route = self.route orelse return false;
            return route.isControl() or route == .host_info;
        }

        fn finishRetirement(self: *Exchange) void {
            self.closeSocket();
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
                const now: i128 = nowNs(host.io);
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
            reply.deinit();
            const status: u16 = switch (err) {
                error.ClientCapacity, error.ControlCapacity, error.DiscoveryCapacity, error.OutOfMemory, error.LinesFull, error.HostStopping => 503,
                error.HostInstanceChanged => 409,
                error.CanonicalStoreFailure => 500,
                error.ScratchCapacityExhausted => 507,
                error.UnsupportedControl => 501,
                error.RequestIdentityExhausted => 500,
                error.EnvironmentTooLarge => 413,
                else => 400,
            };
            const code = switch (err) {
                error.ClientCapacity => "ordinary_capacity_exhausted",
                error.LinesFull => "line_capacity_exhausted",
                error.CanonicalStoreFailure => "canonical_store_failure",
                error.HostStopping => "host_stopping",
                error.HostInstanceChanged => "host_instance_changed",
                error.ControlCapacity => "control_capacity_exhausted",
                error.DiscoveryCapacity => "discovery_capacity_exhausted",
                error.RequestTooLarge => if (self.route == .host_info) "DiscoveryRequestTooLarge" else if (self.route == .action_publish) "too_large" else "control_request_too_large",
                error.ContentTooLarge => if (self.route == .action_publish) "too_large" else @errorName(err),
                error.RequestIdentityExhausted => "request_identity_exhausted",
                error.UnsupportedControl => "control_surface_enters_in_later_slice",
                error.EnvironmentRequired => "environment_required",
                error.EnvironmentTooLarge => "environment_too_large",
                error.InvalidEnvironment => "invalid_environment",
                error.InvalidSince => "invalid_since",
                else => @errorName(err),
            };
            const kind: protocol.ErrorType = switch (err) {
                error.ClientCapacity, error.ControlCapacity, error.DiscoveryCapacity, error.OutOfMemory, error.LinesFull, error.HostStopping => .busy,
                error.CanonicalStoreFailure => .invocation_error,
                error.UnsupportedControl => .unsupported,
                else => .invocation_error,
            };
            respondStatic(reply, status, kind, code);
            self.state = if (reply.advance(self.fd) catch true) .retired else .reply;
        }

        fn read(self: *Exchange) !void {
            if (self.state == .body and self.environmentRemaining() != 0) return self.readEnvironment();
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            const wanted = if (self.ingress) |ingress|
                @min(buffer.len, self.environmentRemaining() + ingress.options.content_length - ingress.received)
            else
                buffer.len;
            if (@as(i128, nowNs(self.host.io)) >= self.deadline) return error.TransferInactive;
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
                                    if (peer.state == .closed or
                                        (peer.state == .retired and peer.canCleanupOnIntake())) continue;
                                    if (route.isControl()) {
                                        control += 1;
                                    } else if (route == .host_info) {
                                        discovery += 1;
                                    } else if (route != .line) ordinary += 1;
                                }
                            }
                            if (self.route == .line) {} else if (self.route.?.isControl()) {
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
                    if (self.route == .line) return self.owner.upgradeLine(self, bytes[consumed..]);
                    self.number = try nextRequestNumber(self.host);
                    switch (self.route.?) {
                        inline else => |route| traceRequest(self.host, "connection_request_" ++ @tagName(route), self.number.?, null),
                    }
                    const limit: u64 = switch (self.route.?) {
                        .host_info => protocol.max_host_info_request_bytes,
                        .host_stop => protocol.max_host_stop_request_bytes,
                        .host_pause => protocol.max_host_pause_request_bytes,
                        .tools_reload => protocol.max_tools_reload_request_bytes,
                        .action_publish => protocol.shapeBytes(protocol.action_publish_request),
                        inline else => |route| if (comptime route.commandKind()) |kind|
                            if (command_spec.spec(kind).is_control) command_spec.spec(kind).Request.maxBytes(protocol).? else std.math.maxInt(u64)
                        else
                            std.math.maxInt(u64),
                    };
                    if (self.header.content_length > limit) return error.RequestTooLarge;
                    const request_length = try self.reserveEnvironment();
                    const ingress = try createUnfilled(self.host.allocator, wire_request.Ingress);
                    ingress.init(self.host.allocator, .{
                        .io = self.host.io,
                        .content_length = request_length,
                        .scratch_path = self.host.lease.paths.scratch.slice(),
                        .request_number = self.number.?,
                        .content_faults = self.host.probes.contentFaults(),
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
                self.deadline = @as(i128, nowNs(self.host.io)) + 60 * std.time.ns_per_s;
            if (self.route == .message) {
                consumed += try self.receiveEnvironment(bytes[consumed..]);
                if (consumed == bytes.len) return;
            }
            if (self.route == .configure or self.route == .message) {
                try self.input.appendSlice(self.host.allocator, bytes[consumed..]);
                self.job = .receive;
                self.state = .ready;
            } else self.state = try self.receive(bytes[consumed..]);
        }

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

        fn readEnvironment(self: *Exchange) !void {
            if (@as(i128, nowNs(self.host.io)) >= self.deadline) return error.TransferInactive;
            const room = self.environment.?.room()[self.environment_received..];
            const result = std.c.read(self.fd, room.ptr, room.len);
            if (result < 0) switch (std.posix.errno(result)) {
                .AGAIN, .INTR => return,
                else => return error.ReadFailed,
            };
            if (result == 0) return error.UnexpectedEndOfBody;
            self.deadline = @as(i128, nowNs(self.host.io)) + 60 * std.time.ns_per_s;
            self.environment_received += @intCast(result);
            if (self.environmentRemaining() == 0) try self.checkEnvironment();
        }

        fn environmentRemaining(self: *const Exchange) usize {
            const offer = if (self.environment) |*held| held else return 0;
            if (offer.candidate == null) return 0;
            return offer.room().len - self.environment_received;
        }

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
            defer self.releaseRequest();
            const reply = try self.ensureReply();
            defer self.releaseEnvironment();
            try prepareReply(self.host, reply, self.fd, self.header, self.number.?, self.accepted_at_ns, self.request.?, if (self.environment) |*offer| offer else null, if (self.ingress) |ingress| ingress.parts_loan else null);
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

    /// Takes ownership of `wake` (from openIntakeWake) only when it succeeds.
    fn init(self: *Intake, host: *Host, wake: [2]std.posix.fd_t) !void {
        self.* = .{ .host = host, .wake = wake };
        errdefer self.stopWorkers();
        for (&self.workers, &self.threads) |*worker, *thread| {
            worker.* = .{ .owner = self };
            thread.* = try signal_stack.spawn(.{ .stack_size = intake_worker_stack_bytes }, Worker.run, .{worker});
            self.started += 1;
        }
    }

    fn openIntakeWake() ![2]std.posix.fd_t {
        var wake: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &wake) != 0) return error.IntakeWakeFailed;
        errdefer for (wake) |fd| {
            _ = std.c.close(fd);
        };
        for (wake) |fd| {
            try setNonblocking(fd);
            if (!socket_os.suppressSigpipe(fd)) return error.SocketFlagsFailed;
        }
        return wake;
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
        self.lines.deinit();
        for (self.exchanges.items) |exchange| {
            exchange.state = .retired;
            while (!exchange.destroy())
                self.host.io.sleep(.fromMilliseconds(execution_turn.retained_cleanup_retry_ms), .awake) catch {};
        }
        self.exchanges.deinit(self.host.allocator);
        self.polls.deinit(self.host.allocator);
        for (self.wake) |fd| _ = std.c.close(fd);
    }

    fn notify(self: *Intake) void {
        _ = std.c.write(self.wake[1], "x", 1);
    }

    fn serviceWorkers(self: *Intake) void {
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
                        if (self.host.store.isFenced()) self.host.lifecycle.fenceDispatch("reply content", err);
                        exchange.state = .retired;
                    }
                } else {
                    exchange.state = worker.next_state;
                    if (exchange.job == .receive) {
                        if (exchange.state == .ready) exchange.job = .prepare;
                        if (exchange.state == .body)
                            exchange.deadline = @as(i128, nowNs(self.host.io)) + 60 * std.time.ns_per_s;
                    }
                }
                if (exchange.state == .retired) exchange.finishRetirement();
                worker.failure = null;
                worker.exchange = null;
                worker.state = .idle;
            }
            if (worker.state != .idle) continue;
            var next: ?*Exchange = null;
            for (self.exchanges.items) |exchange| {
                const control = if (exchange.route) |route| route.isControl() else false;
                if (control != (worker_index == 1)) continue;
                if (exchange.state == .retired and nowNs(self.host.io) >= exchange.cleanup_retry_at) {
                    if (next == null) next = exchange;
                    continue;
                }
                if (exchange.state != .ready) continue;
                if (exchange.route) |route| if (route.atomicOnly()) continue;
                if (next == null) next = exchange;
            }
            if (next) |exchange| {
                const handoff = .{ .host = self.host, .exchange = exchange, .worker = worker };
                if (!self.host.lifecycle.handOff(handoff, handOffWorker)) continue;
            }
        }
    }

    fn readStdin(self: *Intake) void {
        var bytes: [256]u8 = undefined;
        const count = std.c.read(self.stdin.?, &bytes, bytes.len);
        if (count > 0) return;
        if (count < 0 and std.posix.errno(count) == .INTR) return;
        self.stdin = null;
        traceSubject(self.host, "launch_stdin_closed", "host", "launch");
        self.armShutdownDeadline();
        _ = self.host.lifecycle.stopAsked();
    }

    fn armShutdownDeadline(self: *Intake) void {
        if (self.lifetime != .stdin or self.deadline_armed) return;
        self.deadline_armed = true;
        const default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.ALRM, &default, null);
        _ = std.c.alarm(product_defaults.host_shutdown_seconds);
    }

    /// The lines' share of an intake pass before polling: drains the wake pipe, re-arms
    /// the commit waker, walks the ring's copy into each line, and fails every line once
    /// the Store is fenced or the Host stops.
    fn serveLineWake(self: *Intake) void {
        var bytes: [256]u8 = undefined;
        var woke = false;
        while (std.c.read(self.wake[0], &bytes, bytes.len) > 0) woke = true;
        self.lines.rearm();
        if (self.lines.count == 0) return;
        // A pass with no wake byte has no commit to walk: a commit that is not yet
        // drained writes its byte after its record, so it is seen on a later pass.
        if (woke) {
            self.host.store.lockChanges();
            self.lines.capture(self.host.store.changes);
            self.host.store.unlockChanges();
            self.lines.onWake();
        }
        const line_ms: u64 = nowNs(self.host.io) / std.time.ns_per_ms;
        if (self.host.store.isFenced()) self.lines.failAll(.store_failed, line_ms) else if (self.host.lifecycle.stopping()) self.lines.failAll(.host_stopping, line_ms);
    }

    fn run(self: *Intake, listener: *std.Io.net.Server, listener_open: *bool, endpoint: *host_endpoint.Endpoint) !void {
        try setNonblocking(listener.socket.handle);
        var failure: ?anyerror = null;
        var accept_retry_at: i128 = 0;
        while (true) {
            self.serveLineWake();
            StopSignals.apply(self.host);
            if (self.host.lifecycle.stopping()) {
                self.armShutdownDeadline();
                for (self.exchanges.items) |exchange| exchange.retireUnhanded();
            }
            self.serviceWorkers();
            if (self.host.lifecycle.stopping() and listener_open.*) {
                listener.deinit(self.host.io);
                listener_open.* = false;
                unbind(endpoint);
            }
            const now: i128 = nowNs(self.host.io);
            self.polls.clearRetainingCapacity();
            try self.polls.append(self.host.allocator, .{ .fd = if (listener_open.* and now >= accept_retry_at) listener.socket.handle else -1, .events = std.posix.POLL.IN, .revents = 0 });
            try self.polls.append(self.host.allocator, .{ .fd = self.wake[0], .events = std.posix.POLL.IN, .revents = 0 });
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
            const lines_base = self.polls.items.len;
            try self.lines.appendPolls(self.host.allocator, &self.polls, nowNs(self.host.io) / std.time.ns_per_ms);
            const lines_end = self.polls.items.len;
            try self.polls.append(self.host.allocator, .{ .fd = self.stdin orelse -1, .events = std.posix.POLL.IN, .revents = 0 });
            self.serviceWorkers();
            for (self.exchanges.items) |exchange| {
                if (exchange.state == .working) continue;
                if (exchange.cleanup_retry_at > now) {
                    wake_at = @min(wake_at, exchange.cleanup_retry_at);
                } else if (exchange.state == .closed) wake_at = now;
            }
            if (self.lines.deadline()) |at| wake_at = @min(wake_at, @as(i128, @intCast(at)) * std.time.ns_per_ms);
            const wait_ms: c_int = @intCast(@divFloor(@max(wake_at - now, 0) + std.time.ns_per_ms - 1, std.time.ns_per_ms));
            const count = std.c.poll(self.polls.items.ptr, @intCast(self.polls.items.len), wait_ms);
            if (count < 0 and std.posix.errno(count) != .INTR) return error.IntakePollFailed;
            self.lines.service(self.polls.items[lines_base..lines_end], nowNs(self.host.io) / std.time.ns_per_ms);
            if (self.polls.items[self.polls.items.len - 1].revents != 0) self.readStdin();
            for (self.exchanges.items, self.polls.items[2..][0..self.exchanges.items.len]) |exchange, poll| {
                if (poll.revents == 0) continue;
                switch (exchange.state) {
                    .header, .body => exchange.read() catch |err| exchange.fail(err),
                    .reply => {
                        const reply = exchange.reply.?;
                        const complete = reply.advance(exchange.fd) catch |err| {
                            if (self.host.store.isFenced()) self.host.lifecycle.fenceDispatch("reply content", err);
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
            self.lines.reap(nowNs(self.host.io) / std.time.ns_per_ms);
            if (!listener_open.* and self.exchanges.items.len == 0 and self.lines.count == 0) return failure orelse error.EffectAwareShutdown;
            if (!listener_open.* or self.polls.items[0].revents == 0) continue;
            for (0..16) |_| {
                if (self.host.intake_capacity < product_defaults.intake_capacity and
                    self.exchanges.items.len >= self.host.intake_capacity + 3)
                {
                    for (self.exchanges.items, 0..) |peer, peer_index| {
                        if (peer.state == .header and peer.route == null) {
                            const destroyed = peer.destroy();
                            std.debug.assert(destroyed);
                            _ = self.exchanges.orderedRemove(peer_index);
                            break;
                        }
                    }
                    accept_retry_at = @as(i128, nowNs(self.host.io)) + 100 * std.time.ns_per_ms;
                    break;
                }
                const fd = self.acceptSocket(listener.socket.handle) catch |err| switch (err) {
                    error.NoClient => break,
                    error.AcceptCapacity => {
                        accept_retry_at = @as(i128, nowNs(self.host.io)) + 100 * std.time.ns_per_ms;
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
                if (self.host.probes.fails(.shutdown_after_accept)) {
                    failure = error.InjectedListenerFailure;
                    _ = self.host.lifecycle.advance(.stopping);
                    break;
                }
                if (self.host.intake_capacity < product_defaults.intake_capacity and
                    self.exchanges.items.len >= self.host.intake_capacity + 3) break;
            }
        }
    }

    fn retireExchanges(self: *Intake) void {
        var index: usize = 0;
        while (index < self.exchanges.items.len) {
            const exchange = self.exchanges.items[index];
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
        return self.host.lifecycle.openUninherited(listener, acceptLocked);
    }

    fn accept(self: *Intake, fd: std.posix.fd_t) !void {
        if (self.host.limits.client_send_buffer_bytes) |bytes| {
            var value: c_int = @intCast(bytes);
            try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&value));
        }
        const exchange = try self.host.allocator.create(Exchange);
        errdefer self.host.allocator.destroy(exchange);
        const accepted_at_ns = nowNs(self.host.io);
        exchange.* = .{ .owner = self, .host = self.host, .fd = fd, .accepted_at_ns = accepted_at_ns, .deadline = @as(i128, accepted_at_ns) + 10 * std.time.ns_per_s };
        try self.exchanges.append(self.host.allocator, exchange);
    }
};

fn handOffWorker(handoff: anytype, stopping: bool) bool {
    const exchange = handoff.exchange;
    if (exchange.state == .retired) {
        exchange.job = .cleanup;
    } else {
        if (stopping) exchange.retireUnhanded();
        if (exchange.state == .retired) return false;
    }
    exchange.state = .working;
    handoff.worker.exchange = exchange;
    handoff.worker.state = .requested;
    handoff.worker.condition.signal(handoff.host.io);
    return true;
}

fn acceptLocked(listener: std.posix.fd_t) !std.posix.fd_t {
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

fn setNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking) < 0 or
        std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.SocketFlagsFailed;
}

fn descriptorTransport(served: *const providers.Providers) descriptor_capacity.Transport {
    return .{ .listings = served.liveLists() };
}

extern "c" fn rui_write_readiness(fd: c_int, bytes: [*]const u8, length: usize) c_int;

/// MCP calls and one re-list per configured server can hold sockets at once.
const mcp_socket_capacity = @import("server_mcp.zig").capacity + host_settings.max_mcp_servers;

fn reserveMcpDescriptors(requirement: *descriptor_capacity.Requirement) !void {
    const sockets = mcp_socket_capacity;
    requirement.execution = try std.math.add(usize, requirement.execution, sockets);
    requirement.total = try std.math.add(usize, requirement.total, sockets);
}

noinline fn offerMcpTools(io: std.Io, scratch: std.mem.Allocator, storage: *store_module.Store, relist_owner: *server_mcp_relist.Relist, stop: ?std.posix.fd_t) !void {
    var arena: std.heap.ArenaAllocator = .init(scratch);
    defer arena.deinit();
    var saved = try storage.readHostToolSet(arena.allocator());
    const kept: ?tools.HostToolSet = if (saved) |*found| found.toolSet() else null;
    relist_owner.startup(io, storage, if (kept) |*value| value else null, stop) catch |err| switch (err) {
        error.Stopped => return error.EffectAwareShutdown,
        else => |other| return other,
    };
}

pub noinline fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    host_directory: []const u8,
    prepared: host_settings.Prepared,
    tuning: Tuning,
    failure: *?start_report.Failure,
) !void {
    failure.* = null;
    const settings = prepared.get();
    const active_capacity = settings.execution.active_capacity.value;
    const limits = tuning.limits;
    const served_value = providers.fromSettings(settings);
    const served = &served_value;
    var connections = try server_mcp_settings.Connections.init(allocator, settings);
    defer connections.deinit();
    const mcp_servers = connections.servers;
    child_exit_wake.install();
    defer child_exit_wake.restore();
    StopSignals.install();
    defer StopSignals.restore();
    var descriptor_observation = try descriptor_limit.observe(io);
    var descriptor_requirement = try descriptor_capacity.calculate(
        descriptor_observation.open_descriptors,
        active_capacity,
        product_defaults.intake_capacity,
        3,
        descriptorTransport(served),
        served.anySignIn(),
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
                .{ descriptor_observation.soft_limit.?, descriptor_requirement.total - descriptor_capacity.ordinary_exchange_descriptors * (product_defaults.intake_capacity - descriptor_capacity.minimum_intake) },
            );
            stderr.print(
                "rui: descriptor capacity insufficient: active_capacity={d} required={d} soft_limit={d} inherited={d} fixed_host={d} clients={d} execution={d} authentication={d} self_wake={d} lines={d} (required is for default intake; RLIMIT_NOFILE).\n",
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
                    descriptor_requirement.lines,
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
        served.anySignIn(),
        os.tag,
    );
    if (mcp_servers.len != 0) try reserveMcpDescriptors(&descriptor_requirement);
    var descriptor_limit_buffer: [32]u8 = undefined;
    const descriptor_limit_text = if (descriptor_observation.soft_limit) |limit|
        try std.fmt.bufPrint(&descriptor_limit_buffer, "{d}", .{limit})
    else
        "unlimited";
    const mysql_url = if (settings.store == .mysql) try mysqlLogin(allocator, &settings.store.mysql.url.bytes) else null;
    defer if (mysql_url) |url| url.destroy();
    var socket_buffer: [host_settings.max_launch_socket_path_bytes]u8 = undefined;
    const socket_path = if (!settings.interface.dir.anchored) try std.fmt.bufPrint(&socket_buffer, "{s}/" ++ host_settings.socket_name, .{settings.interface.dir.slice()}) else "";
    const serving = try createUnfilled(allocator, struct { lease: platform.StoreLease, endpoint: host_endpoint.Endpoint, storage: store_module.Store });
    defer allocator.destroy(serving);
    const lease = &serving.lease;
    const endpoint = &serving.endpoint;
    try acquireLease(io, lease, endpoint, settings, mysql_url != null, socket_path);
    defer lease.release();
    if (tuning.admitted_directory) |directory|
        try lease.paths.host_directory.set(directory)
    else
        lease.paths.retainReachableDirectory(io, host_directory);
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
    // On the heap: each server's published view would otherwise sit in the serve frame, whose
    // chain the main-thread stack ceiling bounds.
    const mcp_relist = try allocator.create(server_mcp_relist.Relist);
    defer allocator.destroy(mcp_relist);
    // The Host's instance id is drawn once, here, and seeds the ttl re-list jitter, so Hosts' re-lists do not fall in step.
    var instance: protocol.InstanceId = undefined;
    try std.Io.randomSecure(io, &instance);
    mcp_relist.* = server_mcp_relist.Relist.init(allocator, mcp_servers, std.mem.readInt(u64, instance[0..8], .little));
    defer mcp_relist.deinit();
    const storage = &serving.storage;
    openStore(io, storage, lease, endpoint, served, &limits, mcp_servers.len != 0, mysql_url, if (diagnostics) |*writer| writer else null) catch |err| {
        if (err == error.StoreIdentityMismatch) startup_failure = "store_identity_mismatch";
        return err;
    };
    defer storage.close() catch |err| stderr.print("rui: Store close failed: {s}\n", .{@errorName(err)});
    // Registered after the Store's close, so it runs first: the endpoint retires before the Store closes and the lease releases.
    defer endpoint.retire() catch |err| stderr.print("rui: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
    return finishServing(storage, failure, serveOpened(
        io,
        allocator,
        storage,
        lease,
        endpoint,
        active_capacity,
        limits,
        tuning.hooks,
        served,
        settings.tools.bash.path.slice(),
        settings.tools.bash.timeout_ms.value,
        tuning.home,
        settings,
        if (mcp_servers.len != 0) mcp_relist else null,
        mcp_servers,
        instance,
        intake_capacity,
        descriptor_requirement.total,
        descriptor_observation.soft_limit,
        descriptor_limit_text,
        tuning.settings_digest,
        &diagnostics,
        diagnostic_open_error,
        &readiness_owned,
    ));
}

/// Takes what each Store kind needs before the Store opens. A SQLite Host
/// holds its Store's lease; the endpoint waits for `openStore`, so a Store it
/// refuses leaves the socket and interface directory untouched. A MySQL Host
/// has no Store lock before its open, so it claims the endpoint first, then
/// takes its lease, which keeps any census from removing the directory beside it.
noinline fn acquireLease(
    io: std.Io,
    lease: *platform.StoreLease,
    endpoint: *host_endpoint.Endpoint,
    settings: *const host_settings.Settings,
    mysql: bool,
    socket_path: []const u8,
) !void {
    if (mysql) {
        endpoint.* = try claimEndpoint(io, settings.interface.dir.slice());
        errdefer endpoint.retire() catch {};
        return lease.acquireMysql(io, settings.interface.dir.slice(), socket_path);
    }
    lease.* = try platform.StoreLease.acquire(io, settings.store.sqlite.dir.slice());
    errdefer lease.release();
    if (!settings.interface.dir.anchored) try lease.paths.socket.set(socket_path);
}

/// Opens the Store, then, for SQLite, claims the endpoint. Each engine's claim
/// happens in exactly one place, and a failed open or claim gives back what
/// this call took. The caller owns the endpoint's retire and the Store's close
/// once this returns.
noinline fn openStore(
    io: std.Io,
    storage: *store_module.Store,
    lease: *platform.StoreLease,
    endpoint: *host_endpoint.Endpoint,
    served: *const providers.Providers,
    limits: *const Limits,
    has_mcp: bool,
    mysql_url: ?*MysqlUrl,
    diagnostics: ?*HostDiagnostics,
) !void {
    // A MySQL endpoint was claimed by `acquireLease`; a refused open gives it back here.
    errdefer if (mysql_url != null) endpoint.retire() catch {};
    try openStoreForHost(io, storage, lease, served, limits, has_mcp, mysql_url, diagnostics);
    if (mysql_url != null) return;
    errdefer storage.close() catch {};
    endpoint.* = try claimEndpoint(io, std.fs.path.dirname(lease.paths.socket.slice()).?);
}

fn claimEndpoint(io: std.Io, directory: []const u8) !host_endpoint.Endpoint {
    return host_endpoint.claim(io, try .init(directory));
}

/// A stopping Host's socket goes as soon as its listener closes; the endpoint
/// stays reserved until the Host exits.
fn unbind(endpoint: *host_endpoint.Endpoint) void {
    endpoint.unbind() catch |err| stderr.print("rui: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
}

fn serveOpened(
    io: std.Io,
    allocator: std.mem.Allocator,
    storage: *store_module.Store,
    lease: *platform.StoreLease,
    endpoint: *host_endpoint.Endpoint,
    active_capacity: usize,
    limits: Limits,
    hooks: Hooks,
    served: *const providers.Providers,
    bash_path: []const u8,
    bash_timeout_ms: u64,
    home: ?[]const u8,
    settings: *const host_settings.Settings,
    mcp_relist: ?*server_mcp_relist.Relist,
    mcp_servers: []const server_mcp_settings.Server,
    instance: protocol.InstanceId,
    intake_capacity: usize,
    descriptor_requirement: usize,
    descriptor_soft_limit: ?usize,
    descriptor_limit_text: []const u8,
    settings_digest: ?@import("host_settings_handoff.zig").Digest,
    diagnostics: *?HostDiagnostics,
    diagnostic_open_error: ?anyerror,
    readiness_owned: *bool,
) !void {
    if (mcp_relist) |owner| try offerMcpTools(io, allocator, storage, owner, if (settings.interface.lifetime.value == .stdin) 0 else null);
    try storage.validateRetryWaits(limits.retry_waits_ms);
    try lease.prepareForServing(hooks.failures.contains(.startup_cleanup));
    host_endpoint.sweepNeighbors(allocator, endpoint);

    var listener = try endpoint.listen(.{ .kernel_backlog = 128 });
    var listener_open = true;
    errdefer if (listener_open) listener.deinit(io);

    const bash_facts = try bash.readHostFacts(io, allocator, home);
    defer bash.freeHostFacts(allocator, bash_facts);
    const environments = try allocator.create(SessionEnvironments);
    defer allocator.destroy(environments);
    try environments.init(io, allocator);
    defer environments.deinit();
    const custody_records = try pages.mapZeroed(execution.CustodyRecord, active_capacity);
    defer pages.unmapZeroed(custody_records);
    const retention_capacity = @min(
        default_retention_entry_capacity,
        limits.retention_entry_capacity orelse default_retention_entry_capacity,
    );
    const retention_entries = try pages.mapZeroed(output_retention.Entry, retention_capacity);
    defer pages.unmapZeroed(retention_entries);
    const intake_wake = try Intake.openIntakeWake();
    var intake_wake_owned = true;
    defer if (intake_wake_owned) for (intake_wake) |fd| {
        _ = std.c.close(fd);
    };
    var lifecycle: server_host.Lifecycle = .init(io, lease, settings.execution.paused.value, intake_wake[1]);
    var probes: server_host.Probes = .init(io, hooks);
    var host = Host{
        .io = io,
        .allocator = allocator,
        .intake_capacity = intake_capacity,
        .descriptor_soft_limit = descriptor_soft_limit,
        .settings_digest = settings_digest,
        .lease = lease,
        .store = storage,
        .catalog_url = if (settings.models.catalog_url) |*url| url.slice() else null,
        .limits = limits,
        .providers = served,
        .presets = settings.presets.specs,
        .bash_path = bash_path,
        .bash_facts = bash_facts,
        .environments = environments,
        .bash_timeout_ms = bash_timeout_ms,
        .background_after_ms = settings.execution.background_after_ms.value,
        .retention = undefined,
        .custody = execution.CustodyPool.initialize(custody_records),
        .lifecycle = &lifecycle,
        .probes = &probes,
        .mcp_relist = mcp_relist,
    };
    const test_pause = @import("testing/pause.zig");
    var pause_owner = test_pause.PauseController.init(io, std.heap.c_allocator);
    defer pause_owner.deinit();
    const pause_adapter = if (comptime test_pause.enabled) adapter: {
        if (hooks.pause_fd) |fd| {
            probes.attachPauseOwner(&pause_owner);
            break :adapter try @import("testing/pause_socket.zig").Adapter.start(std.heap.c_allocator, io, &pause_owner, fd);
        }
        break :adapter null;
    } else {};
    defer if (comptime test_pause.enabled) {
        if (pause_adapter) |adapter| adapter.stop();
    };
    storage.modelTimingSource().* = host.custody.timingSource();
    defer storage.modelTimingSource().* = .{};
    try host.mcp_servers.init(allocator, mcp_servers);
    defer host.mcp_servers.deinit(allocator);
    try probes.openObservation();
    defer probes.closeObservation();
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
    host.instance = instance;
    storage.instance = host.instance;
    const started_at = std.Io.Clock.real.now(io).toSeconds();
    if (started_at <= 0) return error.ClockReadFailed;
    host.started_at = @intCast(started_at);
    host.model_lists = .init(io, allocator, served);
    defer host.model_lists.deinit();
    var intake: Intake = undefined;
    try intake.init(&host, intake_wake);
    intake_wake_owned = false;
    defer intake.deinit();
    intake.lines.attach(intake.wake[1]);
    storage.commitSubscriber().store(&intake.lines.subscriber, .release);
    defer storage.commitSubscriber().store(null, .release);
    intake.lifetime = settings.interface.lifetime.value;
    if (intake.lifetime == .stdin) intake.stdin = 0;
    StopSignals.attach(intake.wake[1]);
    defer StopSignals.detach();
    if (comptime test_pause.enabled) if (pause_adapter) |adapter| try adapter.waitStart();
    const execution_thread = try signal_stack.spawn(.{}, executionMain, .{&host});
    defer {
        if (listener_open) {
            listener.deinit(io);
            listener_open = false;
            unbind(endpoint);
        }
        _ = host.lifecycle.advance(.ending);
        execution_thread.join();
        if (comptime test_pause.enabled) pause_owner.close();
    }
    try writeReadiness(&lease.paths, host.instance, active_capacity, intake_capacity, descriptor_requirement, descriptor_limit_text, retention_entries.len, served.any());
    stderr.release();
    readiness_owned.* = false;
    if (diagnostic_open_error) |err|
        stderr.print("rui: startup diagnostics unavailable ({s}); continuing under Store lease\n", .{@errorName(err)});
    if (diagnostics.*) |*writer| {
        if (writer.failure != null) writer.reportFailure();
        writer.record("ready", "serving");
        host.lifecycle.attachDiagnostics(writer);
    }

    return intake.run(&listener, &listener_open, endpoint);
}

fn finishServing(storage: *const store_module.Store, failure: *?start_report.Failure, result: anyerror!void) !void {
    if (storage.kind() == .mysql and storage.isFenced()) {
        failure.* = .init(.store_fenced, "the MySQL Store lost ownership or its connection; restart the Host");
        return error.StoreFenced;
    }
    return result;
}

noinline fn recordCapacity(writer: *HostDiagnostics, intake_capacity: usize, descriptor_requirement: usize, descriptor_limit_text: []const u8) !void {
    var detail: [256]u8 = undefined;
    writer.record("capacity", try std.fmt.bufPrint(&detail, "ordinary_intake={d} default_intake={d} minimum_intake={d} descriptor_requirement={d} descriptor_limit={s}", .{
        intake_capacity,        product_defaults.intake_capacity, descriptor_capacity.minimum_intake,
        descriptor_requirement, descriptor_limit_text,
    }));
}

noinline fn mysqlLogin(gpa: std.mem.Allocator, bytes: *const host_settings.MysqlBytes) !*MysqlUrl {
    const source = bytes.parsed.?;
    const login = try gpa.create(MysqlUrl);
    login.* = .{ .allocator = gpa, .user = source.user, .password = source.password, .host = source.host, .socket = source.socket, .database = source.database, .ca_file = source.ca_file, .port = source.port };
    return login;
}

noinline fn openStoreForHost(
    io: std.Io,
    storage: *store_module.Store,
    lease: *platform.StoreLease,
    served: *const providers.Providers,
    limits: *const Limits,
    has_mcp: bool,
    mysql_url: ?*MysqlUrl,
    diagnostics: ?*HostDiagnostics,
) !void {
    var found_schema_version: u32 = store_module.schema_version;
    var identity_mismatch: store_module.IdentityMismatch = .{};
    var migration: StartupMigration = .{ .diagnostics = diagnostics };
    const store_options: store_module.OpenOptions = .{
        .served = served.routes(),
        .cache_spill = limits.sqlite_cache_spill,
        .cache_kib = limits.sqlite_cache_kib,
        .found_schema_version = &found_schema_version,
        .identity_mismatch = &identity_mismatch,
        .migration_notice = .{ .context = &migration, .notify = StartupMigration.notify },
        .host_tool_set = if (!has_mcp) &tools.built_in_tool_set else null,
    };
    defer if (mysql_url) |url| url.wipe();
    const target: store_module.Target = if (mysql_url) |url|
        .{ .mysql = url.options() }
    else
        .{ .sqlite = lease.paths.database.slice() };
    const selector = if (mysql_url) |url| url.database.slice() else lease.paths.store_identity.slice();
    storage.openTarget(io, target, selector, store_options) catch |err| {
        if (mysql_url == null) {
            if (err == error.WrongStoreVersion) {
                try reportWrongStoreVersion(lease.paths.store_identity.slice(), found_schema_version);
                if (diagnostics) |writer| writer.record("failed", "unsupported_store_version");
            } else if (err == error.StoreIdentityMismatch) {
                try reportStoreIdentityMismatch(identity_mismatch.saved_selector.slice(), lease.paths.store_identity.slice());
            }
        }
        return err;
    };
    lease.paths.store_identity.set(storage.storeId()) catch unreachable;
}

const StartupMigration = struct {
    diagnostics: ?*HostDiagnostics,

    fn notify(context: *anyopaque, event: store_module.MigrationNotice.Event) void {
        const self: *StartupMigration = @ptrCast(@alignCast(context));
        var message: [256]u8 = undefined;
        var detail: [32]u8 = undefined;
        const text, const phase, const format = switch (event) {
            .begin => |from| .{
                std.fmt.bufPrint(&message, "rui: backing up this Store and migrating it from format {d} to {d}; a large Store takes longer " ++ HostStartupWait.migrating_tag, .{ from, store_module.schema_version }) catch unreachable,
                "migrating",
                from,
            },
            .end => .{
                std.fmt.bufPrint(&message, "rui: Store migrated to format {d} " ++ HostStartupWait.migrated_tag, .{store_module.schema_version}) catch unreachable,
                "migrated",
                store_module.schema_version,
            },
        };
        _ = stderr.writeHeld(text);
        if (self.diagnostics) |writer| writer.record(phase, std.fmt.bufPrint(&detail, "format_{d}", .{format}) catch unreachable);
    }
};

const TestParts = if (@import("builtin").is_test) @import("server_host_testing.zig").TestParts else void;

test "migration notices reach the launcher while serve holds stderr custody" {
    var pipe: [2]c_int = undefined;
    if (std.c.pipe(&pipe) != 0) return error.SystemResources;
    defer for (pipe) |fd| {
        _ = std.c.close(fd);
    };
    const saved = std.c.dup(2);
    if (saved < 0 or std.c.dup2(pipe[1], 2) < 0) return error.TestUnexpectedResult;
    try std.testing.expect(stderr.tryExclude());
    var migration: StartupMigration = .{ .diagnostics = null };
    StartupMigration.notify(&migration, .{ .begin = store_module.schema_version - 1 });
    StartupMigration.notify(&migration, .end);
    stderr.release();
    _ = std.c.dup2(saved, 2);
    _ = std.c.close(saved);
    var buffer: [1024]u8 = undefined;
    const count = std.c.read(pipe[0], &buffer, buffer.len);
    try std.testing.expect(count > 0);
    const output = buffer[0..@intCast(count)];
    var wait = HostStartupWait.init(0);
    const begin_end = std.mem.indexOf(u8, output, HostStartupWait.migrating_tag).? + HostStartupWait.migrating_tag.len;
    wait.observe(output[0..begin_end], 1);
    try std.testing.expect(!wait.expired(HostStartupWait.readiness_ns * 10));
    wait.observe(output, HostStartupWait.readiness_ns * 10);
    try std.testing.expect(!wait.expired(HostStartupWait.readiness_ns * 10 + 1));
    try std.testing.expect(wait.expired(HostStartupWait.readiness_ns * 11));
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
        "unsupported or missing Store format metadata"
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
    instance: protocol.InstanceId,
    active_capacity: usize,
    intake_capacity: usize,
    descriptor_requirement: usize,
    descriptor_limit_text: []const u8,
    retention_capacity: usize,
    provider_enabled: bool,
) !void {
    var ready: protocol.DiagnosticBuffer = .{};
    const instance_hex = std.fmt.bytesToHex(instance, .lower);
    try ready.appendFmt("ready instance={s} store={s} socket={s} active_capacity={d} intake_capacity={d} descriptor_requirement={d} descriptor_limit={s} custody_record_bytes={d} execution_slot_bytes={d} model_preparation_bytes={d} scratch_limit_bytes={d} retention_entry_bytes={d} retention_capacity={d} bash_execution=enabled execution={s}", .{
        &instance_hex,
        paths.store_identity.slice(),
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
    if (host.probes.suppressFirstControlHint()) {
        traceSubject(host, "control_hint_suppressed", "command_key", command_key);
        return;
    }
    host.lifecycle.noteControlsChanged();
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
        if (!self.host.probes.hooks.phase_trace) return null;
        return .{ .context = self, .mark_fn = markStore };
    }

    fn markStore(context: *anyopaque, phase: store_module.ControlTracePhase) void {
        const self: *ControlTiming = @ptrCast(@alignCast(context));
        switch (phase) {
            .lock_requested => {
                self.store_queued_ns = nowNs(self.host.io);
                traceSubject(self.host, "control_store_queued", "command_key", self.command_key.slice());
            },
            .lock_acquired => {
                self.lock_acquired_ns = nowNs(self.host.io);
                traceSubject(self.host, "control_lock_acquired", "command_key", self.command_key.slice());
                self.waitAtTestGate();
            },
            .durable_acceptance => {
                traceSubject(self.host, "control_durable_acceptance", "command_key", self.command_key.slice());
            },
            .store_complete => {
                self.store_complete_ns = nowNs(self.host.io);
                traceSubject(self.host, "control_store_complete", "command_key", self.command_key.slice());
            },
        }
    }

    fn waitAtTestGate(self: *ControlTiming) void {
        const gate_hook = self.host.probes.hooks.control_gate orelse return;
        var candidates = std.mem.splitScalar(u8, gate_hook.keys, ',');
        while (candidates.next()) |candidate| {
            if (!std.mem.eql(u8, candidate, self.command_key.slice())) continue;
            var gate = std.Io.Dir.cwd().openFile(self.host.io, gate_hook.path, .{}) catch return;
            defer gate.close(self.host.io);
            var release: [1]u8 = undefined;
            const count = gate.readStreaming(self.host.io, &.{&release}) catch return;
            if (count == 1) traceSubject(self.host, "control_gate_released", "command_key", self.command_key.slice());
            return;
        }
    }

    inline fn replyComplete(self: *ControlTiming) void {
        if (self.host.probes.hooks.phase_trace) self.writeReplyComplete();
    }

    noinline fn writeReplyComplete(self: *ControlTiming) void {
        const reply_complete_ns = nowNs(self.host.io);
        if (self.store_queued_ns == 0 or self.lock_acquired_ns == 0 or self.store_complete_ns == 0) return;
        var publication = self.host.probes.beginObservation("control_timing", null);
        defer if (publication) |*value| value.finish();
        var trace: protocol.DiagnosticBuffer = .{};
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
        self.host.probes.writeTrace(&trace, &publication);
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
    session_pin,
    model_interruption,
    permission_decision,
    action_background,
    action_stop,
    action_publish,
    observe,
    read_result,
    read_action,
    read_action_call_id,
    read_action_arguments,
    inspect,
    list_sessions,
    conversation_page,
    conversation_content,
    activity_page,
    activity_search,
    activity_content,
    public_parts,
    public_part_content,
    skill_suggestions,
    model_list,
    tools_reload,
    tools_status,
    line,
    unsupported_control,

    fn commandKind(comptime self: Route) ?protocol.CommandKind {
        inline for (comptime std.enums.values(protocol.CommandKind)) |command_kind| {
            if (self == @field(Route, @tagName(command_kind))) return command_kind;
        }
        return null;
    }

    fn isControl(self: Route) bool {
        return switch (self) {
            .host_stop, .host_pause, .tools_reload, .unsupported_control => true,
            inline else => |route| if (comptime route.commandKind()) |command_kind|
                command_spec.spec(command_kind).is_control
            else
                false,
        };
    }

    fn atomicOnly(self: Route) bool {
        return self == .host_info or self == .host_stop or self == .host_pause or self == .tools_reload;
    }

    fn kind(self: Route) protocol.Kind {
        return switch (self) {
            .observe => .observe_command,
            .inspect => .inspect_session,
            .unsupported_control, .line => unreachable,
            inline else => |route| @field(protocol.Kind, @tagName(route)),
        };
    }
};
test "command route projection preserves control classification" {
    inline for (comptime std.enums.values(Route)) |route| {
        const expected: ?protocol.CommandKind = switch (route) {
            .configure => .configure,
            .message => .message,
            .session_stop => .session_stop,
            .session_archive => .session_archive,
            .session_pin => .session_pin,
            .model_interruption => .model_interruption,
            .permission_decision => .permission_decision,
            .action_background => .action_background,
            .action_stop => .action_stop,
            else => null,
        };
        try std.testing.expectEqual(expected, comptime route.commandKind());
        const expected_control = switch (route) {
            .host_stop, .host_pause, .tools_reload, .unsupported_control, .session_stop, .session_archive, .session_pin, .model_interruption, .permission_decision, .action_background, .action_stop => true,
            else => false,
        };
        try std.testing.expectEqual(expected_control, route.isControl());
    }
}

const DropMode = enum { none, before_admission, during_admission, after_commit };

const Header = struct {
    route: Route,
    content_length: u64,
    environment_bytes: ?u64 = null,
    drop: DropMode = .none,
    instance: ?protocol.InstanceId = null,
};

noinline fn submitMessage(host: *Host, command: *const wire_request.MessageCommand, offer: *SessionEnvironments.Offer, receipt: ?*@import("creation_receipt.zig").Configuration) error{OutOfMemory}!store_module.MessageReply {
    return submitMessageInput(host, command, offer, null, receipt);
}

fn submitMessageInput(host: *Host, command: *const wire_request.MessageCommand, offer: *SessionEnvironments.Offer, loan: ?@import("InputCapture.zig").Loan, receipt: ?*@import("creation_receipt.zig").Configuration) error{OutOfMemory}!store_module.MessageReply {
    std.debug.assert(offer.value() != null);
    defer offer.deinit(host.allocator);
    var memory: std.heap.ArenaAllocator = .init(host.allocator);
    defer memory.deinit();
    const skill_owner = @import("session_skills.zig");
    const prepared = (if (loan) |parts|
        skill_owner.prepareMessageParts(memory.allocator(), host.allocator, host.io, host.store, command, host.bash_facts.home, parts)
    else
        skill_owner.prepareMessage(memory.allocator(), host.allocator, host.io, host.store, command, host.bash_facts.home)) catch |err| {
        if (host.store.isFenced()) return .infrastructure_failure;
        return if (err == error.OutOfMemory) error.OutOfMemory else .infrastructure_failure;
    };
    const initial_skills = prepared.initial;
    const captured_skill = prepared.captured;
    const faults = host.probes.storeFaults(.command);
    if (command.configuration) |*configuration| if (configuration.parent.state == .value) {
        var inheritance = @import("child_environment.zig").Inheritance.init(host.environments, configuration.parent.value.slice(), host.allocator, memory.allocator()) catch |err| {
            if (host.store.isFenced()) return .infrastructure_failure;
            return if (err == error.OutOfMemory) error.OutOfMemory else .infrastructure_failure;
        };
        defer inheritance.deinit(host.allocator);
        return submitMessageInputToStore(host.store, command, loan, inheritance.messageCallback(), initial_skills, if (captured_skill) |*value| value else null, receipt, faults);
    };
    const environments = host.environments orelse return submitMessageInputToStore(host.store, command, loan, null, initial_skills, if (captured_skill) |*value| value else null, receipt, faults);
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
    return submitMessageInputToStore(host.store, command, loan, .{ .context = &install, .call = Install.call }, initial_skills, if (captured_skill) |*value| value else null, receipt, faults);
}

fn submitMessageInputToStore(
    store: *store_module.Store,
    command: *const wire_request.MessageCommand,
    loan: ?@import("InputCapture.zig").Loan,
    committed: ?store_module.Store.MessageCommitted,
    initial: ?*const store_module.InitialSkills,
    captured: ?*const store_module.CapturedMessageSkills,
    receipt: ?*@import("creation_receipt.zig").Configuration,
    faults: store_module.Faults,
) store_module.MessageReply {
    if (loan) |parts| return store.submitMessagePartsCapturedSkillsInto(command, parts, committed, initial, captured, receipt, faults) catch .infrastructure_failure;
    return store.submitMessageCapturedSkillsInto(command, committed, initial, captured, receipt, faults);
}

noinline fn submitConfigure(host: *Host, command: *const wire_request.ConfigureCommand, receipt: ?*@import("creation_receipt.zig").Configuration) error{OutOfMemory}!store_module.ConfigureReply {
    const name = command.preset orelse return configureCapturedSkills(host, command, null, receipt);
    var decision: store_module.PresetDecision = .{ .request_digest = command.presetRequestDigest() };
    if (command.session.len != 0) {
        decision.rejection = .preset_on_update;
        return try host.store.configureWithCreationCommittedInto(command, &decision, null, null, host.allocator, null, receipt, host.probes.storeFaults(.command));
    }
    const preset = for (host.presets) |*entry| {
        if (std.mem.eql(u8, entry.name, name.slice())) break entry;
    } else {
        decision.rejection = .unknown_preset;
        return try host.store.configureWithCreationCommittedInto(command, &decision, null, null, host.allocator, null, receipt, host.probes.storeFaults(.command));
    };
    var memory: std.heap.ArenaAllocator = .init(host.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const resolved = try arena.create(wire_request.ConfigureCommand);
    resolved.* = .{
        .store = command.store,
        .key = command.key,
        .session = command.session,
        .require_model = command.require_model,
        .reload_skills = command.reload_skills,
    };
    const checked = core_tools.parseAgentSpec(arena, preset.spec, &resolved.configuration) catch |err| return configureFailure(host, err);
    std.debug.assert(checked == .accepted);
    overlayConfiguration(&resolved.configuration, &command.configuration);
    return configureCapturedSkills(host, resolved, &decision, receipt);
}

fn overlayConfiguration(base: *wire_request.Configuration, override: *const wire_request.Configuration) void {
    inline for (@import("session_settings.zig").spec_entries) |entry| {
        const field = &@field(override, entry.field);
        if (field.state != .omitted) @field(base, entry.field) = field.*;
    }
    if (override.preferences) |preferences| base.preferences = preferences;
}

test "preset overlay retains or replaces the whole preferences object" {
    var base: wire_request.Configuration = .{ .preferences = .{} };
    base.preferences.?.reasoning_effort.state = .value;
    try base.preferences.?.reasoning_effort.value.set("high");
    overlayConfiguration(&base, &.{});
    try std.testing.expectEqualStrings("high", base.preferences.?.reasoning_effort.value.slice());
    overlayConfiguration(&base, &.{ .preferences = .{} });
    try std.testing.expectEqual(protocol.FieldState.omitted, base.preferences.?.reasoning_effort.state);
}

fn configureFailure(host: *Host, err: anyerror) error{OutOfMemory}!store_module.ConfigureReply {
    if (host.store.isFenced()) return .infrastructure_failure;
    return if (err == error.OutOfMemory) error.OutOfMemory else .infrastructure_failure;
}

noinline fn configureCapturedSkills(host: *Host, command: *const wire_request.ConfigureCommand, preset: ?*const store_module.PresetDecision, receipt: ?*@import("creation_receipt.zig").Configuration) error{OutOfMemory}!store_module.ConfigureReply {
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
    var inheritance = if (command.session.len == 0 and command.configuration.parent.state == .value)
        @import("child_environment.zig").Inheritance.init(host.environments, command.configuration.parent.value.slice(), host.allocator, memory.allocator()) catch |err| return configureFailure(host, err)
    else
        @import("child_environment.zig").Inheritance{ .environments = null };
    defer inheritance.deinit(host.allocator);
    return host.store.configureWithCreationCommittedInto(command, preset, initial_skills, if (reload_capture) |*value| value else null, host.allocator, inheritance.creationCallback(), receipt, host.probes.storeFaults(.command));
}

fn submitControl(host: *Host, comptime kind: command_spec.CommandKind, command: *const @FieldType(wire_request.Request, @tagName(kind)), faults: store_module.Faults) host_reply.MutationResult(kind) {
    return switch (kind) {
        .session_stop => host.store.stopSession(command, faults),
        .session_archive => host.store.archiveSession(command, faults),
        .session_pin => host.store.pinSession(command, faults),
        .model_interruption => host.store.interruptModel(command, faults),
        .permission_decision => host.store.decidePermission(command, faults),
        .action_background => host.store.backgroundAction(.{ .command = command }, faults),
        .action_stop => host.store.requestActionStop(command, faults),
        .configure, .message => @compileError("control admission requires a control kind"),
    };
}

fn controlSubject(comptime kind: command_spec.CommandKind, command: *const @FieldType(wire_request.Request, @tagName(kind))) host_reply.MutationSubject(kind) {
    return switch (kind) {
        .session_stop, .session_archive, .session_pin => command.session.slice(),
        .model_interruption => .{ .session = command.session, .turn_id = command.turn_id, .operation_id = command.operation_id },
        .permission_decision => .{ .session = command.session, .action_id = command.action_id, .decision = command.decision },
        .action_background, .action_stop => .{ .session = command.session, .action_id = command.action_id },
        .configure, .message => @compileError("control subject requires a control kind"),
    };
}

// Returns false only for the deliberate post-commit drop, so controls keep the
// original timing lifetime even when reply allocation itself cannot succeed.
fn answerMutation(host: *Host, fd: *Reply, header: Header, comptime kind: command_spec.CommandKind, subject: host_reply.MutationSubject(kind), result: host_reply.MutationResult(kind)) !bool {
    if (result == .infrastructure_failure) host.lifecycle.fenceDispatch(command_spec.spec(kind).fence_message, error.CanonicalStoreFailure);
    if (header.drop == .after_commit and result != .infrastructure_failure) return false;
    try fd.json(host_reply.httpStatus(result), @max(command_spec.spec(kind).Reply(protocol).max_bytes, protocol.max_control_error_response_bytes), host_reply.renderMutationReply(kind), .{ subject, result });
    return true;
}

fn answerControl(host: *Host, fd: *Reply, header: Header, comptime kind: command_spec.CommandKind, subject: host_reply.MutationSubject(kind), result: host_reply.MutationResult(kind), timing: ControlTiming) !void {
    comptime std.debug.assert(command_spec.spec(kind).is_control);
    // Acceptance and infrastructure failure are disjoint. The hint precedes
    // every reply effect, including the deliberate post-commit drop.
    if (result == .accepted) publishControlHint(host, timing.command_key.slice());
    if (try answerMutation(host, fd, header, kind, subject, result)) fd.timing = timing;
}

fn matchesStore(kind: std.meta.Tag(wire_request.Request), supplied: []const u8, expected: []const u8) bool {
    return (kind == .host_info and supplied.len == 0) or std.mem.eql(u8, supplied, expected);
}

test "settings readiness discovers the canonical Store only through host info" {
    for (std.enums.values(std.meta.Tag(wire_request.Request))) |kind| {
        for ([_][]const u8{ "/canonical/sqlite", "0123456789abcdef0123456789abcdef" }) |identity| {
            try std.testing.expect(matchesStore(kind, identity, identity));
            try std.testing.expect(!matchesStore(kind, "wrong-identity", identity));
            try std.testing.expectEqual(kind == .host_info, matchesStore(kind, "", identity));
        }
    }
}

noinline fn prepareConfigure(host: *Host, fd: *Reply, header: Header, command: *const wire_request.ConfigureCommand) !void {
    // One bounded receipt per active creating exchange; ordinary exchanges
    // are limited by Host intake capacity. It lives only through encoding.
    const receipt = if (command.session.len == 0) try createUnfilled(host.allocator, @import("creation_receipt.zig").Configuration) else null;
    defer if (receipt) |value| host.allocator.destroy(value);
    _ = try answerMutation(host, fd, header, .configure, command.session.slice(), try submitConfigure(host, command, receipt));
}

// Each request kind runs in its own noinline handler. A switch whose arms are
// written inline gets one frame sized for every arm, and whether that frame sits
// under a deep path (configure into the Store) is the inliner's choice.
fn prepareReply(host: *Host, fd: *Reply, socket: std.posix.fd_t, header: Header, request_number: u64, accepted_at_ns: u64, request: *wire_request.Request, client_environment: ?*SessionEnvironments.Offer, parts: ?@import("InputCapture.zig").Loan) !void {
    if (!matchesStore(std.meta.activeTag(request.*), request.store(), host.lease.paths.store_identity.slice())) {
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
        .host_info => try replyHostInfo(host, fd),
        .host_pause => |pause| try replyHostPause(host, fd, pause),
        .host_stop => |stop| try replyHostStop(host, fd, stop, header),
        .configure => |*command| try prepareConfigure(host, fd, header, command),
        .message => |*command| try replyMessage(host, fd, command, header, client_environment, parts),
        inline .session_stop, .session_archive, .session_pin, .model_interruption, .permission_decision, .action_background, .action_stop => |*command, tag| try replyControl(host, fd, header, accepted_at_ns, comptime @field(command_spec.CommandKind, @tagName(tag)), command),
        .action_publish => |*command| try replyActionPublish(host, fd, command),
        .observe_command => |*command| try replyObserveCommand(host, fd, command),
        .read_result => |*command| try replyReadResult(host, fd, command),
        .read_action => |*command| try replyReadAction(host, fd, command),
        .read_action_arguments => |*command| deliverActionContent(host, fd, command, false),
        .read_action_call_id => |*command| deliverActionContent(host, fd, command, true),
        .inspect_session => |*request_value| try replyInspectSession(host, fd, request_value, request_number),
        .list_sessions => |*request_value| try replyListSessions(host, fd, request_value, request_number),
        .conversation_page => |*command| try replyConversationPage(host, fd, command),
        .conversation_content => |*command| try prepareConversationContent(host, fd, command),
        .activity_page => |*command| try replyActivityPage(host, fd, command),
        .activity_search => |*command| try replyActivitySearch(host, fd, command),
        .public_parts => |*command| try replyPublicParts(host, fd, command, request_number),
        .public_part_content => |*command| try replyPublicPartContent(host, fd, command),
        .activity_content => |*command| try replyActivityContent(host, fd, command),
        .skill_suggestions => |*command| try replySkillSuggestions(host, fd, command),
        .model_list => try replyModelList(host, fd),
        .tools_reload => |*reload| try replyToolsReload(host, fd, reload),
        .tools_status => try replyToolsStatus(host, fd),
    }
}

noinline fn replyHostInfo(host: *Host, fd: *Reply) !void {
    if (!host.lifecycle.launchAllowed()) return respondStatic(fd, 503, .host_unavailable, "dispatch_fenced");
    try fd.json(200, protocol.max_host_info_response_bytes, host_reply.renderHostInfo, .{host_reply.HostInfo{
        .store = host.lease.paths.store_identity.slice(),
        .instance = host.instance,
        .active_capacity = host.custody.records.len,
        .intake_capacity = host.intake_capacity,
        .descriptor_soft_limit = host.descriptor_soft_limit,
        .started_at = host.started_at,
        .custody_occupied = host.custody.held(),
        .paused = host.lifecycle.turnsHeld(),
        .routes = host.providers.routes(),
        .doublewrite = host.store.admissionDiagnostic().doublewrite,
        .settings_digest = host.settings_digest,
    }});
}

noinline fn replyHostPause(host: *Host, fd: *Reply, pause: @FieldType(wire_request.Request, "host_pause")) !void {
    if (!host.lifecycle.launchAllowed()) return respondStatic(fd, 503, .host_unavailable, "dispatch_fenced");
    host.lifecycle.setTurnsPaused(pause.paused);
    // A drain's hold outlasts an operator's release; reply the hold in force.
    try fd.json(200, comptime protocol.shapeBytes(protocol.host_pause_reply), host_reply.renderHostPause, .{host.lifecycle.turnsHeld()});
}

noinline fn replyHostStop(host: *Host, fd: *Reply, stop: @FieldType(wire_request.Request, "host_stop"), header: Header) !void {
    const bound = host_drain.Bound.seconds(stop.drain_seconds) catch unreachable;
    const answer = host.lifecycle.askStop(bound);
    if (answer == .stop_now) host.lifecycle.wakeListener();
    if (header.drop == .after_commit) return;
    switch (answer) {
        .stop_now, .already_stopping => try fd.json(200, protocol.host_stop_ack.len, protocol.JsonOut.append, .{protocol.host_stop_ack}),
        .drain => |drain| {
            const left_ms = (drain.until_ns -| nowNs(host.io)) / std.time.ns_per_ms;
            const until_unix_ms = (std.math.cast(u64, store_module.readUnixMilliseconds(host.io) catch 0) orelse 0) +| left_ms;
            try fd.json(200, comptime protocol.shapeBytes(protocol.host_drain_reply), host_reply.renderHostDrain, .{until_unix_ms});
        },
    }
}

noinline fn replyMessage(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "message"), header: Header, client_environment: ?*SessionEnvironments.Offer, parts: ?@import("InputCapture.zig").Loan) !void {
    if ((command.text.state == .value) == (parts != null)) return error.InvalidMessage;
    const receipt = if (command.configuration != null) try createUnfilled(host.allocator, @import("creation_receipt.zig").Configuration) else null;
    defer if (receipt) |value| host.allocator.destroy(value);
    _ = try answerMutation(host, fd, header, .message, command.session.slice(), try submitMessageInput(host, command, client_environment.?, parts, receipt));
}

noinline fn replyControl(host: *Host, fd: *Reply, header: Header, accepted_at_ns: u64, comptime kind: command_spec.CommandKind, command: *const @FieldType(wire_request.Request, @tagName(kind))) !void {
    var timing = ControlTiming.init(host, command.key, @tagName(kind), accepted_at_ns);
    const result = submitControl(host, kind, command, host.probes.storeFaults(.{ .control = timing.storeTrace() }));
    try answerControl(host, fd, header, kind, controlSubject(kind, command), result, timing);
}

noinline fn replyActionPublish(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "action_publish")) !void {
    if (command.text.length > protocol.max_action_value_bytes) return respondStatic(fd, 409, .invocation_error, "too_large");
    const bytes = try host.allocator.alloc(u8, @intCast(command.text.length));
    defer host.allocator.free(bytes);
    const count = try command.text.file.?.readPositionalAll(host.io, bytes, 0);
    if (count != bytes.len) return error.UnexpectedEndOfFile;
    const result = host.store.publishActionValue(command.handle.slice(), command.key.slice(), bytes) catch |err| {
        host.lifecycle.fenceDispatch("action value publication", err);
        return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
    };
    switch (result) {
        .accepted => |receipt| try fd.json(200, comptime protocol.shapeBytes(protocol.action_publish_reply), renderActionValueReceipt, .{receipt}),
        .refused => |reason| return respondStatic(fd, 409, .invocation_error, @tagName(reason)),
    }
}

noinline fn replyObserveCommand(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "observe_command")) !void {
    var observation: store_module.Observed = undefined;
    host.store.observeCommand(command.key.slice(), command.since, &observation) catch |err| return refuseRead(host, fd, "command observation", err);
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
}

noinline fn replyReadResult(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "read_result")) !void {
    const reference = host.store.commandResult(command.key.slice()) catch |err| switch (err) {
        error.ResultNotFound => return respondStatic(fd, 409, .result_unavailable, "result_not_found"),
        error.ResultNotReady => return respondStatic(fd, 409, .result_unavailable, "result_not_ready"),
        error.ResultFailed => return respondStatic(fd, 409, .result_unavailable, "result_failed"),
        else => return refuseRead(host, fd, "result observation", err),
    };
    const location = host.store.openContent(reference) catch |err| return refuseRead(host, fd, "result content read", err);
    try fd.setContent(location, 0, true, false);
}

noinline fn replyReadAction(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "read_action")) !void {
    const value = try createUnfilled(host.allocator, @import("action_read.zig").Read);
    defer host.allocator.destroy(value);
    host.store.readAction(command, value) catch |err| switch (err) {
        error.ActionNotFound => return respondStatic(fd, 404, .action_unavailable, "action_not_found"),
        error.InvalidCursor => return respondStatic(fd, 400, .action_unavailable, "invalid_cursor"),
        else => return refuseRead(host, fd, "Action status observation", err),
    };
    try fd.json(200, protocol.action_read_reply.max_bytes, host_reply.renderActionRead, .{value});
}

noinline fn replyInspectSession(host: *Host, fd: *Reply, request_value: *@FieldType(wire_request.Request, "inspect_session"), request_number: u64) !void {
    if (request_value.failed_response != null) {
        const capture = captureFailedResponse(host, request_value, request_number) catch |err| {
            if (err == error.ReportScratchCleanupFailed) {
                host.lifecycle.fenceDispatch("failed response export scratch cleanup", err);
                return respondStatic(fd, 500, .observation_error, "report_scratch_cleanup_failed");
            }
            if (host.store.isFenced()) {
                host.lifecycle.fenceDispatch("failed response identity", err);
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
            host.lifecycle.fenceDispatch("session report scratch cleanup", err);
            return respondStatic(fd, 500, .observation_error, "report_scratch_cleanup_failed");
        }
        return refuseRead(host, fd, "session inspection", err);
    };
    try fd.setReport(report);
    traceSubject(host, "inspection_captured", "session", request_value.session.slice());
    traceSqliteDiagnostic(host, request_value.session.slice());
    try fd.holdDelivery(host.probes.hooks.inspection_reply);
    if (fd.gate != null) traceSubject(host, "test_gate_waiting", "path", host.probes.hooks.inspection_reply.gate_path.?);
}

noinline fn replyListSessions(host: *Host, fd: *Reply, request_value: *@FieldType(wire_request.Request, "list_sessions"), request_number: u64) !void {
    if (request_value.since) |since| {
        if (request_value.changed == null and host.store.notModified(since)) {
            return fd.json(200, protocol.max_response_bytes, host_reply.renderSessionsNotModified, .{since});
        }
    }
    const page = captureSessionList(host, request_value, request_number) catch |err| {
        if (err == error.ReportScratchCleanupFailed) {
            host.lifecycle.fenceDispatch("Session list scratch cleanup", err);
            return respondStatic(fd, 500, .observation_error, "report_scratch_cleanup_failed");
        }
        return refuseRead(host, fd, "Session list", err);
    };
    try fd.setReport(page);
}

noinline fn replyConversationPage(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "conversation_page")) !void {
    const page = try createUnfilled(host.allocator, store_module.PublicConversationPage);
    defer host.allocator.destroy(page);
    host.store.publicConversationPage(command, page, host.allocator) catch |err| switch (err) {
        error.SessionNotFound, error.InvalidCursor => return respondStatic(fd, 409, .conversation_unavailable, @errorName(err)),
        else => return refuseRead(host, fd, "conversation page", err),
    };
    try fd.json(200, protocol.max_conversation_page_response_bytes, host_reply.renderConversationPage, .{page});
}

noinline fn replyActivityPage(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "activity_page")) !void {
    const page = try createUnfilled(host.allocator, protocol.ActivityFacts);
    defer host.allocator.destroy(page);
    host.store.activityPage(command, page) catch |err| switch (err) {
        error.SessionNotFound, error.InvalidCursor => return respondStatic(fd, 409, .activity_unavailable, @errorName(err)),
        else => return refuseRead(host, fd, "activity page", err),
    };
    try fd.json(200, host_reply.activityPageBytes(page), host_reply.renderActivityPage, .{page});
}

noinline fn replyActivitySearch(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "activity_search")) !void {
    const page = try createUnfilled(host.allocator, protocol.ActivitySearchFacts);
    defer host.allocator.destroy(page);
    host.store.searchActivity(command, page) catch |err| switch (err) {
        error.SessionNotFound, error.InvalidCursor => return respondStatic(fd, 409, .activity_unavailable, @errorName(err)),
        else => return refuseRead(host, fd, "activity search", err),
    };
    try fd.json(200, activity_reply.max_search_bytes, host_reply.renderActivitySearch, .{page});
}

noinline fn replyPublicParts(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "public_parts"), request_number: u64) !void {
    const report = capturePublicParts(host, fd, command, request_number) catch |err| switch (err) {
        error.ContentNotFound, error.ContentIsText => return respondStatic(fd, 409, .parts_unavailable, @errorName(err)),
        error.ReportScratchCleanupFailed => {
            host.lifecycle.fenceDispatch("public parts scratch cleanup", err);
            return respondStatic(fd, 500, .observation_error, "report_scratch_cleanup_failed");
        },
        else => return refuseRead(host, fd, "public parts", err),
    };
    try fd.setReport(report);
}

noinline fn replyPublicPartContent(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "public_part_content")) !void {
    const location = host.store.openPublicPart(command.session.slice(), command.owner, command.part, command.start) catch |err| switch (err) {
        error.ContentNotFound, error.ContentIsText, error.RangeOutOfBounds => return respondStatic(fd, 409, .parts_unavailable, @errorName(err)),
        else => return refuseRead(host, fd, "public part content", err),
    };
    try deliverPublicContent(host, fd, location, command.start, command.stream);
}

noinline fn replyActivityContent(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "activity_content")) !void {
    const location = host.store.openActivityContent(command) catch |err| switch (err) {
        error.ContentNotFound, error.ContentIsParts => return respondStatic(fd, 409, .activity_unavailable, @errorName(err)),
        else => return refuseRead(host, fd, "activity content", err),
    };
    try deliverPublicContent(host, fd, location, 0, true);
}

noinline fn replySkillSuggestions(host: *Host, fd: *Reply, command: *@FieldType(wire_request.Request, "skill_suggestions")) !void {
    const scope: @import("skill_suggestions.zig").Scope = if (command.session) |*session| .{ .session = session.slice() } else .{ .workspace = command.workspace.?.slice() };
    var page = readSkillSuggestions(host, host.allocator, scope, command.prefix.slice()) catch |err| {
        if (err == error.CanonicalStoreFailure) return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return respondStatic(fd, 409, .activity_unavailable, if (err == error.SessionNotFound) "SessionNotFound" else "skills_unavailable");
    };
    defer page.deinit(host.allocator);
    try fd.jsonGrowing(200, protocol.skill_suggestions_reply.max_bytes, host_reply.renderSkillSuggestions, .{&page});
}

noinline fn replyModelList(host: *Host, fd: *Reply) !void {
    host.listings_requested.store(true, .release);
    var arena: std.heap.ArenaAllocator = .init(host.allocator);
    defer arena.deinit();
    const facts = host.store.readModelCatalog(arena.allocator()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        host.lifecycle.fenceDispatch("model catalog", err);
        return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
    };
    try fd.jsonGrowing(200, protocol.model_list_reply.maxBytes(facts), renderModelList, .{ host, facts });
}

fn readSkillSuggestions(host: *Host, allocator: std.mem.Allocator, scope: @import("skill_suggestions.zig").Scope, prefix: []const u8) !@import("skill_suggestions.zig").Page {
    return @import("session_skills.zig").suggestions(allocator, host.allocator, host.io, host.store, scope, prefix, host.bash_facts.home) catch |err| {
        if (scope == .session and host.store.isFenced()) {
            host.lifecycle.fenceDispatch("skill suggestions", err);
            return error.CanonicalStoreFailure;
        }
        return err;
    };
}

/// Asks the execution owner to list one server, or every configured server. Asking only records a
/// request, so the reply needs no wait: the caller polls tools_status for each asked generation.
noinline fn replyToolsReload(host: *Host, fd: *Reply, request: *const @FieldType(wire_request.Request, "tools_reload")) !void {
    if (!host.lifecycle.launchAllowed()) return respondStatic(fd, 503, .host_unavailable, "dispatch_fenced");
    var asked_by_owner: [host_settings.max_mcp_servers]server_mcp_relist.Relist.Asked = undefined;
    const count = server_host.askMcpLists(host, if (request.server) |name| name.slice() else null, &asked_by_owner);
    if (request.server != null and count == 0) return respondStatic(fd, 400, .invocation_error, "unknown_mcp_server");
    var asked: [host_settings.max_mcp_servers]host_reply.ToolAsk = undefined;
    for (asked_by_owner[0..count], asked[0..count]) |ask, *each| each.* = .{ .server = ask.server, .generation = ask.generation };
    try fd.json(200, protocol.tools_reload_reply.maxBytes(host_settings.max_mcp_servers), host_reply.renderToolsReload, .{ host.instance, asked[0..count] });
}

/// Reads every configured server's published list status. Lock-free: it never waits for the owner.
noinline fn replyToolsStatus(host: *Host, fd: *Reply) !void {
    var rows: [host_settings.max_mcp_servers]host_reply.ToolServerStatus = undefined;
    var count: usize = 0;
    if (host.mcp_relist) |owner| {
        for (owner.servers, 0..) |*server, index| {
            rows[count] = .{ .server = server.name.slice(), .status = owner.status(index), .listen = owner.streamState(index) };
            count += 1;
        }
    }
    try fd.json(200, protocol.tools_status_reply.maxBytes(host_settings.max_mcp_servers), host_reply.renderToolsStatus, .{ host.instance, rows[0..count] });
}

fn renderModelList(out: protocol.JsonOut, host: *Host, facts: []const @import("model_catalog.zig").Entry) error{BufferTooLarge}!void {
    out.writer.writeAll(protocol.model_list_reply.head) catch return error.BufferTooLarge;
    host.model_lists.render(out.writer, facts) catch return error.BufferTooLarge;
    out.writer.writeAll(protocol.model_list_reply.tail) catch return error.BufferTooLarge;
}

fn captureSessionReport(host: *Host, request: *const protocol.InspectSession, request_number: u64) !store_module.SessionReport {
    const State = struct {
        capture: store_module.SessionReportCapture,
        reply: session_report_reply.Reply(store_module.SessionReportCapture),
    };
    const state = try createUnfilled(host.allocator, State);
    defer host.allocator.destroy(state);
    const capture = &state.capture;
    capture.* = .{ .io = host.io, .writer = null, .budget = host.retention.sharedBudget() };
    try capture.create(host.lease.paths.scratch.slice(), request_number, host.probes.fails(.report_unlink));
    errdefer capture.deinit();
    state.reply.capture = capture;
    state.reply.execution = executionFacts(host);
    try host.store.readSessionReport(request.session.slice(), request.profile, &state.reply);
    return capture.seal();
}

test "Session report capture releases its heap state after sealing or scratch exhaustion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    var request: protocol.InspectSession = .{};
    try request.session.set("k7m2qx");
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        host.allocator = failing.allocator();
        defer host.allocator = std.testing.allocator;
        try std.testing.expectError(error.OutOfMemory, captureSessionReport(&host, &request, 0));
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expect(!storage.isFenced());
    }
    {
        var report = try captureSessionReport(&host, &request, 1);
        defer report.deinit();
        try std.testing.expect(report.length != 0);
        try std.testing.expectEqual(report.length, host.scratch_used.load(.acquire));
        var bytes: [1024]u8 = undefined;
        const length = try report.read(0, &bytes);
        try std.testing.expectEqual(report.length, length);
        try std.testing.expect(std.mem.indexOf(u8, bytes[0..length], "session_not_found") != null);
    }
    try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
    retention.budget.limit = 1;
    try std.testing.expectError(error.ReportScratchExhausted, captureSessionReport(&host, &request, 2));
    try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
    try std.testing.expect(!storage.isFenced());
    retention.budget.limit = 9000;
    host.probes.arm(.report_unlink);
    try std.testing.expectError(error.ReportScratchCleanupFailed, captureSessionReport(&host, &request, 3));
    try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
    try std.testing.expect(!storage.isFenced());
}

fn captureSessionList(host: *Host, request: *const protocol.ListSessions, request_number: u64) !store_module.SessionReport {
    try request.validate();
    var capture: store_module.SessionReportCapture = .{ .io = host.io, .writer = null, .budget = host.retention.sharedBudget() };
    try capture.create(host.lease.paths.scratch.slice(), request_number, host.probes.fails(.report_unlink));
    errdefer capture.deinit();
    const reply = try createUnfilled(host.allocator, session_list_reply.Reply(store_module.SessionReportCapture));
    defer host.allocator.destroy(reply);
    reply.capture = &capture;
    reply.rows = 0;
    const list_pages = try createUnfilled(host.allocator, store_module.SessionListPages);
    defer host.allocator.destroy(list_pages);
    try host.store.readSessionList(request, reply, list_pages);
    return capture.seal();
}

/// One `T` on the heap whose bytes stay unwritten until its initializer or
/// producer fills them. `Allocator.create` would first write 0xAA over every
/// byte in ReleaseSafe. Freed with `allocator.destroy`.
fn createUnfilled(allocator: std.mem.Allocator, comptime T: type) error{OutOfMemory}!*T {
    const bytes = allocator.rawAlloc(@sizeOf(T), .of(T), @returnAddress()) orelse return error.OutOfMemory;
    return @ptrCast(@alignCast(bytes));
}

/// Certifies the owner's parts once, then captures the whole list into report
/// scratch under the shared retention budget. A fault mid-walk discards the
/// capture, so no partial list is ever delivered.
fn capturePublicParts(host: *Host, reply: *Reply, command: *const protocol.PublicParts, request_number: u64) !store_module.SessionReport {
    const capture = &reply.parts_capture;
    capture.* = .{ .io = host.io, .writer = null, .budget = host.retention.sharedBudget() };
    try capture.create(host.lease.paths.scratch.slice(), request_number, host.probes.fails(.report_unlink));
    errdefer capture.deinit();
    var reader = try store_module.PublicParts.Reader.init(command.session, command.owner);
    defer reader.deinit();
    var writer: protocol.public_parts_reply.Writer(store_module.SessionReportCapture) = .{ .capture = capture, .session = command.session.slice() };
    while (true) switch (try host.store.readPublicParts(&reader)) {
        .pending => {},
        .certified => |value| try writer.head(value),
        .part => |part| try writer.part(part),
        .done => break,
    };
    try writer.finish();
    return capture.seal();
}

fn deliverConversationContent(host: *Host, fd: std.posix.fd_t, command: protocol.ConversationContent) !void {
    var reply = Reply{ .io = host.io, .allocator = host.allocator };
    defer reply.deinit();
    try prepareConversationContent(host, &reply, &command);
    reply.deliver(fd) catch |err| {
        if (host.store.isFenced()) host.lifecycle.fenceDispatch("public content", err);
    };
}

noinline fn prepareConversationContent(host: *Host, fd: *Reply, command: *const protocol.ConversationContent) !void {
    const location = host.store.openPublicConversationContent(command) catch |err| switch (err) {
        error.ContentNotFound, error.RangeOutOfBounds, error.ContentIsParts => return respondStatic(fd, 409, .conversation_unavailable, @errorName(err)),
        else => return refuseRead(host, fd, "conversation content", err),
    };
    return deliverPublicContent(host, fd, location, command.start, command.stream);
}

fn deliverPublicContent(host: *Host, fd: *Reply, location: store_module.ContentLocation, start: u64, stream: bool) !void {
    fd.setContent(location, start, stream, true) catch |err| {
        host.lifecycle.fenceDispatch("public content", err);
        fd.deinit();
        return respondStatic(fd, 500, .invocation_error, "canonical_store_failure");
    };
}

noinline fn deliverActionContent(host: *Host, fd: *Reply, command: anytype, comptime call_id: bool) void {
    const phase = if (call_id) "Action call identity observation" else "Action argument observation";
    const reference = if (call_id)
        host.store.actionCallId(command.session.slice(), command.action_id)
    else
        host.store.actionArguments(command.session.slice(), command.action_id);
    const resolved = reference catch |err| switch (err) {
        error.ActionNotFound => return respondStatic(fd, 404, .action_unavailable, "action_not_found"),
        else => return refuseRead(host, fd, phase, err),
    };
    const location = host.store.openContent(resolved) catch |err| return refuseRead(host, fd, phase, err);
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
        if (std.mem.eql(u8, request_line, "GET /v1/line HTTP/1.1")) return .line;
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
        else if (std.mem.eql(u8, path, "/v1/action-publish"))
            .action_publish
        else if (std.mem.eql(u8, path, "/v1/observe-command"))
            .observe
        else if (std.mem.eql(u8, path, "/v1/read-result"))
            .read_result
        else if (std.mem.eql(u8, path, "/v1/read-action"))
            .read_action
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
        else if (std.mem.eql(u8, path, "/v1/public-parts"))
            .public_parts
        else if (std.mem.eql(u8, path, "/v1/public-part-content"))
            .public_part_content
        else if (std.mem.eql(u8, path, "/v1/skill-suggestions"))
            .skill_suggestions
        else if (std.mem.eql(u8, path, "/v1/model-list"))
            .model_list
        else if (std.mem.eql(u8, path, "/v1/control/tools-reload"))
            .tools_reload
        else if (std.mem.eql(u8, path, "/v1/tools-status"))
            .tools_status
        else if (std.mem.startsWith(u8, path, "/v1/control/"))
            .unsupported_control
        else
            error.UnknownRoute;
    }

    /// The upgrade request: `Upgrade: rui-line/1`, a `Connection` token `Upgrade`, the wire
    /// version, and an optional Host instance. A body or a framing header is refused.
    fn parseLineFields(bytes: []const u8) !Header {
        var fields = std.mem.splitSequence(u8, bytes, "\r\n");
        _ = fields.next() orelse return error.InvalidRequestLine;
        var upgrade_ok = false;
        var connection_ok = false;
        var wire_ok = false;
        var instance: ?protocol.InstanceId = null;
        while (fields.next()) |field| {
            if (field.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, field, ':') orelse return error.InvalidHeader;
            const name = std.mem.trim(u8, field[0..colon], " \t");
            const value = std.mem.trim(u8, field[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Upgrade")) {
                if (upgrade_ok or !std.mem.eql(u8, value, "rui-line/1")) return error.InvalidUpgrade;
                upgrade_ok = true;
            } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
                var tokens = std.mem.splitScalar(u8, value, ',');
                while (tokens.next()) |token| {
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "Upgrade")) connection_ok = true;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Wire-Version")) {
                wire_ok = std.mem.eql(u8, value, protocol.wire_version);
            } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Host-Instance")) {
                if (instance != null) return error.DuplicateHostInstance;
                instance = try protocol.parseInstanceId(value);
            } else if (std.ascii.eqlIgnoreCase(name, "Content-Length") or std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                return error.InvalidUpgrade;
            }
        }
        if (!upgrade_ok or !connection_ok) return error.InvalidUpgrade;
        if (!wire_ok) return error.WrongWireVersion;
        return .{ .route = .line, .content_length = 0, .instance = instance };
    }

    fn parseFields(bytes: []const u8, route: Route) !Header {
        if (route == .line) return parseLineFields(bytes);
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

test "a line upgrade takes its one route and refuses malformed upgrade headers" {
    try std.testing.expectEqual(Route.line, try HeaderReader.parseRoute("GET /v1/line HTTP/1.1"));
    try std.testing.expectError(error.InvalidMethod, HeaderReader.parseRoute("GET /v1/host-info HTTP/1.1"));
    const wire = "X-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n";
    const request = "GET /v1/line HTTP/1.1\r\n";
    const good = request ++ "Upgrade: rui-line/1\r\nConnection: keep-alive, Upgrade\r\n" ++ wire ++ "X-Rui-Host-Instance: " ++ "abababababababababababababababab" ++ "\r\n\r\n";
    const header = try HeaderReader.parseFields(good, .line);
    try std.testing.expectEqual(Route.line, header.route);
    try std.testing.expectEqual(@as(?protocol.InstanceId, @splat(0xab)), header.instance);
    const refused = [_]struct { text: []const u8, err: anyerror }{
        .{ .text = request ++ "Connection: Upgrade\r\n" ++ wire ++ "\r\n", .err = error.InvalidUpgrade },
        .{ .text = request ++ "Upgrade: rui-line/2\r\nConnection: Upgrade\r\n" ++ wire ++ "\r\n", .err = error.InvalidUpgrade },
        .{ .text = request ++ "Upgrade: rui-line/1\r\nConnection: close\r\n" ++ wire ++ "\r\n", .err = error.InvalidUpgrade },
        .{ .text = request ++ "Upgrade: rui-line/1\r\nConnection: Upgrade\r\nContent-Length: 0\r\n" ++ wire ++ "\r\n", .err = error.InvalidUpgrade },
        .{ .text = request ++ "Upgrade: rui-line/1\r\nConnection: Upgrade\r\n\r\n", .err = error.WrongWireVersion },
        .{ .text = request ++ "Upgrade: rui-line/1\r\nConnection: Upgrade\r\n" ++ wire ++ "X-Rui-Host-Instance: ABC\r\n\r\n", .err = error.InvalidInstanceId },
    };
    for (refused) |case| try std.testing.expectError(case.err, HeaderReader.parseFields(case.text, .line));
}

const line_test_instance = "abababababababababababababababab";

fn linePair() ![2]c_int {
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
    for (sockets) |fd| try setNonblocking(fd);
    return sockets;
}

/// Upgrade headers, then `frame` as one length-prefixed app frame in the same write.
fn lineRequest(buffer: []u8, instance: []const u8, frame: []const u8) ![]const u8 {
    var length = (try std.fmt.bufPrint(buffer, "GET /v1/line HTTP/1.1\r\nUpgrade: rui-line/1\r\nConnection: Upgrade\r\nX-Rui-Wire-Version: {s}\r\nX-Rui-Host-Instance: {s}\r\n\r\n", .{ protocol.wire_version, instance })).len;
    if (frame.len != 0) {
        std.mem.writeInt(u32, buffer[length..][0..4], @intCast(frame.len), .big);
        @memcpy(buffer[length + 4 ..][0..frame.len], frame);
        length += 4 + frame.len;
    }
    return buffer[0..length];
}

/// Reads what the peer has queued on a nonblocking socket. Empty means nothing yet.
fn drainPeer(fd: c_int, out: []u8) []u8 {
    var used: usize = 0;
    while (used < out.len) {
        const count = std.c.read(fd, out[used..].ptr, out.len - used);
        if (count <= 0) break;
        used += @intCast(count);
    }
    return out[0..used];
}

/// Writes out a refused exchange's reply the way the loop does on POLLOUT.
fn finishReply(exchange: *Intake.Exchange) !void {
    const reply = exchange.reply.?;
    var rounds: usize = 0;
    while (!(try reply.advance(exchange.fd))) : (rounds += 1) std.debug.assert(rounds < 8);
}

/// One intake pass over the lines, as the loop runs it: the wake work, then poll and service.
fn passLines(intake: *Intake, now_ms: u64) !void {
    intake.serveLineWake();
    intake.polls.clearRetainingCapacity();
    try intake.lines.appendPolls(intake.host.allocator, &intake.polls, now_ms);
    _ = std.c.poll(intake.polls.items.ptr, @intCast(intake.polls.items.len), 0);
    intake.lines.service(intake.polls.items, now_ms);
    intake.lines.reap(now_ms);
}

/// Writes one upgrade request, with `frame` as leftover app bytes, to a client peer.
fn sendRequest(fd: c_int, buffer: []u8, instance: []const u8, frame: []const u8) !void {
    const bytes = try lineRequest(buffer, instance, frame);
    try std.testing.expectEqual(bytes.len, @as(usize, @intCast(std.c.write(fd, bytes.ptr, bytes.len))));
}

test "a line upgrades on the Host, takes its leftover watch, hears each commit through the Store, and fails with the Host or the Store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    storage.instance = @splat(0xab);

    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage, .instance = @splat(0xab), .intake_capacity = descriptor_capacity.minimum_intake };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    const wake = try linePair();
    defer for (wake) |fd| {
        _ = std.c.close(fd);
    };
    var intake: Intake = .{ .host = &host, .wake = wake };
    defer intake.polls.deinit(host.allocator);
    defer intake.exchanges.deinit(host.allocator);
    defer for (intake.exchanges.items) |exchange| {
        std.debug.assert(exchange.destroy());
    };
    intake.lines.attach(wake[1]);
    defer intake.lines.deinit();
    storage.commitSubscriber().store(&intake.lines.subscriber, .release);
    defer storage.commitSubscriber().store(null, .release);

    // Four connections: the open line, a wrong Host instance, a stopping Host, a fenced Store.
    const pairs = [_][2]c_int{ try linePair(), try linePair(), try linePair(), try linePair() };
    defer for (pairs) |pair| {
        _ = std.c.close(pair[1]);
    };
    var request: [512]u8 = undefined;
    var sink: [1024]u8 = undefined;
    var wake_bytes: [16]u8 = undefined;

    var configure = try store_module.testingCompleteConfiguration("line-host-first", "", root, "model-a");
    _ = try storage.configure(&configure, .{});

    // The upgrade answers 101 and hello. The watch of every Session rides in the same write.
    const watch_all = "{\"type\":\"watch\",\"sessions\":\"all\"}";
    try sendRequest(pairs[0][1], &request, line_test_instance, watch_all);
    try intake.accept(pairs[0][0]);
    intake.exchanges.items[0].read() catch |err| intake.exchanges.items[0].fail(err);
    try std.testing.expectEqual(@as(usize, 1), intake.lines.count);
    try passLines(&intake, 0);
    const opened = drainPeer(pairs[0][1], &sink);
    try std.testing.expect(std.mem.startsWith(u8, opened, "HTTP/1.1 101 Switching Protocols"));
    try std.testing.expect(std.mem.indexOf(u8, opened, "{\"type\":\"hello\"") != null);

    // A commit writes one wake byte, and the line answers with a changed frame naming the new Session.
    configure.key.set("line-host-second") catch unreachable;
    const second = (try storage.configure(&configure, .{})).accepted.session;
    try std.testing.expectEqual(@as(usize, 1), drainPeer(wake[0], &wake_bytes).len);
    // The byte was counted above; put it back so the pass sees the wake it announces.
    try std.testing.expectEqual(@as(isize, 1), std.c.write(wake[1], "x", 1));
    const walks_before_commit = intake.lines.captures;
    try passLines(&intake, 0);
    try std.testing.expectEqual(walks_before_commit + 1, intake.lines.captures);
    const changed = drainPeer(pairs[0][1], &sink);
    try std.testing.expect(std.mem.indexOf(u8, changed, "{\"type\":\"changed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, second.slice()) != null);

    // With nothing committed, a pass sends nothing and writes no wake byte.
    try passLines(&intake, 0);
    try std.testing.expectEqual(@as(usize, 0), drainPeer(pairs[0][1], &sink).len);
    try std.testing.expectEqual(@as(usize, 0), drainPeer(wake[0], &wake_bytes).len);
    const walks = intake.lines.captures;
    try passLines(&intake, 0);
    try std.testing.expectEqual(walks, intake.lines.captures);

    // A different Host instance is refused with 409 and leaves the open line alone.
    try sendRequest(pairs[1][1], &request, "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", "");
    try intake.accept(pairs[1][0]);
    intake.exchanges.items[1].read() catch |err| intake.exchanges.items[1].fail(err);
    try finishReply(intake.exchanges.items[1]);
    try std.testing.expect(std.mem.startsWith(u8, drainPeer(pairs[1][1], &sink), "HTTP/1.1 409"));
    try std.testing.expectEqual(@as(usize, 1), intake.lines.count);

    // A stopping Host refuses a new line with 503, then fails the open line with its own frame and closes it.
    _ = host.lifecycle.advance(.stopping);
    try sendRequest(pairs[2][1], &request, line_test_instance, "");
    try intake.accept(pairs[2][0]);
    intake.exchanges.items[2].read() catch |err| intake.exchanges.items[2].fail(err);
    try finishReply(intake.exchanges.items[2]);
    try std.testing.expect(std.mem.startsWith(u8, drainPeer(pairs[2][1], &sink), "HTTP/1.1 503"));
    try passLines(&intake, 0);
    try std.testing.expect(std.mem.indexOf(u8, drainPeer(pairs[0][1], &sink), "{\"type\":\"failed\",\"code\":\"host_stopping\"}") != null);
    try std.testing.expectEqual(@as(usize, 0), intake.lines.count);

    // A fenced Store refuses an upgrade with the canonical store failure, not a busy reply.
    host_parts.attach(&host, undefined);
    storage.fenced.store(true, .release);
    try sendRequest(pairs[3][1], &request, line_test_instance, "");
    try intake.accept(pairs[3][0]);
    intake.exchanges.items[3].read() catch |err| intake.exchanges.items[3].fail(err);
    try finishReply(intake.exchanges.items[3]);
    const refused = drainPeer(pairs[3][1], &sink);
    try std.testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.indexOf(u8, refused, "canonical_store_failure") != null);
}

test "canonical failure classifier accepts every production mutation failure envelope" {
    const protocol_reply = @import("protocol_reply.zig");
    inline for (comptime std.meta.tags(command_spec.CommandKind)) |kind| {
        const render = host_reply.renderMutationReply(kind);
        const Subject = @typeInfo(@TypeOf(render)).@"fn".param_types[1].?;
        var response = protocol.ResponseBuffer{};
        try response.render(render, .{ std.mem.zeroes(Subject), .infrastructure_failure });
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}", response.slice());
        try std.testing.expectError(error.CanonicalStoreFailure, protocol_reply.checkCanonicalFailure(.{ .status = 500, .body = response.slice() }));
    }
}

test "initial Message reply binds its allocated Session and original input before exposing acceptance" {
    const protocol_reply = @import("protocol_reply.zig");
    const content: store_module.ContentReference = .{ .length = 9, .digest = protocol.contentDigest("seven\nµ!") };
    const configuration: @import("creation_receipt.zig").Configuration = .{
        .provider = .codex,
        .model = try .from("model-a"),
        .reasoning_effort = null,
        .workspace = try .from("/workspace"),
        .tools = .{},
        .loaded_tools = .{},
        .permission_mode = .ask,
        .compaction_trigger = null,
    };
    var allocated: protocol.Bounded(protocol.max_session_bytes) = .{};
    try allocated.set("k7m2qx");
    var response: protocol.ResponseBuffer = .{};
    try response.render(host_reply.renderMessageReply, .{ "", store_module.MessageReply{ .accepted = .{
        .replayed = true,
        .admission_id = 17,
        .configuration = &configuration,
        .content = .{ .text = content },
        .session = allocated,
    } } });
    const target: protocol_reply.MutationTarget = .{ .message = .{ .bytes = content.length, .digest = content.digest, .creates_session = true } };
    const reply = protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", target);
    try std.testing.expect(reply.isAccepted());
    try std.testing.expectEqualStrings("k7m2qx", reply.context.session.slice());
    try std.testing.expectError(error.RequestBindingMismatch, protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "111111", target).answer);
    var changed = target;
    changed.message.digest[0] ^= 1;
    try std.testing.expectError(error.RequestBindingMismatch, protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", changed).answer);
    response = .{};
    try allocated.set("BAD-ID");
    try response.render(host_reply.renderMessageReply, .{ "", store_module.MessageReply{ .accepted = .{
        .replayed = true,
        .admission_id = 17,
        .configuration = &configuration,
        .content = .{ .text = content },
        .session = allocated,
    } } });
    try std.testing.expectError(error.RequestBindingMismatch, protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", target).answer);
}

fn renderActionValueReceipt(out: protocol.JsonOut, receipt: anytype) !void {
    try out.appendShape(protocol.action_publish_reply, .{ receipt.action_id, receipt.ordinal, receipt.admission_id, receipt.replayed });
}

/// The Store owns which read failures are fatal: it fences itself for those and returns the
/// rest as ordinary refusals. Dispatch fences only after it.
fn refuseRead(host: *Host, reply: *Reply, phase: []const u8, err: anyerror) void {
    if (host.store.isFenced()) {
        host.lifecycle.fenceDispatch(phase, err);
        return respondStatic(reply, 500, .invocation_error, "canonical_store_failure");
    }
    respondStatic(reply, if (err == error.ReportScratchExhausted) 507 else 500, .observation_error, @errorName(err));
}

fn respondStatic(reply: *Reply, status: u16, kind: protocol.ErrorType, code: []const u8) void {
    reply.json(status, protocol.max_control_error_response_bytes, host_reply.renderStatic, .{ kind, code }) catch {};
}

const Reply = struct {
    parts_capture: store_module.SessionReportCapture = undefined,
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
                error.FileNotFound => return,
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

    fn json(self: *Reply, status: u16, max_bytes: usize, comptime render: anytype, args: anytype) !void {
        const body = std.Io.Writer.Allocating.initCapacity(self.allocator, max_bytes) catch return;
        return self.jsonInto(body, status, max_bytes, render, args);
    }

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

    fn setReport(self: *Reply, value: store_module.SessionReport) !void {
        std.debug.assert(self.body == .none);
        self.body = .{ .report = value };
        self.end = value.length;
        try self.prepareHeader(200, "application/json", value.length);
    }

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
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const Peer = struct {
        fd: std.posix.fd_t,
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
                        self.failed = true;
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
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
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
    inline for (comptime std.meta.tags(command_spec.CommandKind)) |control_kind| {
        if (comptime !command_spec.spec(control_kind).is_control) continue;
        const kind = @tagName(control_kind);
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
        };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        host_parts.probes.hooks = .{ .phase_trace = true };
        host_parts.probes.observation = observation;
        var original: [protocol.max_key_bytes]u8 = undefined;
        for (&original, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
        var request_key = protocol.Bounded(protocol.max_key_bytes){ .bytes = original, .len = original.len };
        var reply = Reply{ .io = std.testing.io, .allocator = std.testing.allocator };
        defer reply.deinit();
        reply.timing = ControlTiming.init(&host, request_key, kind, 1);
        reply.timing.?.store_queued_ns = 2;
        reply.timing.?.lock_acquired_ns = 3;
        reply.timing.?.store_complete_ns = 4;
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
        .content = .{ .text = content },
        .queue = .{ .admission_id = 1, .state = .queued },
        .admitted_at = 11,
        .work = .{ .state = .{ .pending = .{ .since = 10 } } },
    } } };
    try observation.target.set("s");
    const message = &observation.kind.message.?;
    try Expect.rendered(&observation, accepted ++ "queued\"" ++ input ++ queue ++ ",\"work\":{\"state\":{\"kind\":\"pending\",\"since\":\"10\"},\"first_action\":null,\"attention\":null,\"group\":\"queued\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}}}");
    message.work = .{ .state = .{ .approval = .{ .since = 10 } }, .first_action = 7 };
    try Expect.rendered(&observation, accepted ++ "waiting_for_permission\"" ++ input ++ queue ++ ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"10\"},\"first_action\":\"7\",\"attention\":{\"kind\":\"approval\",\"turn\":\"0\",\"step\":\"7\"},\"group\":\"needs_you\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}}}");
    message.queue.?.state = .{ .processing = bound };
    message.work = .{ .state = .{ .working = .{ .since = 10 } } };
    message.recovery.count = 1;
    message.recovery.calls[0] = .{ .action_id = 8, .operation_id = 3, .call = 1, .at = 12 };
    try Expect.rendered(&observation, accepted ++ "processing\"" ++ input ++ queue ++ binding ++ ",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"10\"},\"first_action\":null,\"attention\":null,\"group\":\"working\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}" ++ recovery ++ "}}");
    message.queue.?.state = .{ .completed = .{ .binding = bound, .answer = .{ .length = 6, .digest = @splat(0xff) } } };
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
    try storage.observeCommand("tier-create", first, &observed);
    try Expect.unchanged(&observed, session.slice(), first.generation);
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

test "Message observation work and recovery fit their exchange-owned response bound" {
    try std.testing.expectEqual(
        protocol.shapeBytes(protocol.command_observation_reply.work_base) + protocol.shapeBytes(protocol.SessionWork.extra_fields) + "}".len,
        protocol.shapeBytes(protocol.command_observation_reply.work),
    );
    const max = std.math.maxInt(u64);
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set(&@as([protocol.max_tool_description_bytes]u8, @splat(1)));
    var bash_description: protocol.Bounded(protocol.session_work.max_description_bytes) = .{};
    try bash_description.set(&@as([protocol.session_work.max_description_bytes]u8, @splat(1)));
    var observation = store_module.CommandObservation{ .status = .accepted, .kind = .{ .message = .{
        .content = .{ .parts = .{
            .identity = .{ .length = max, .digest = @splat(0xff) },
            .owner = .{ .message = max },
        } },
        .queue = .{ .admission_id = max, .state = .{ .processing = .{ .turn_id = max, .operation_id = max, .attempt_ordinal = max } } },
        .admitted_at = max,
        .work = .{ .state = .{ .bash = .{ .since = max, .call = max, .description = bash_description, .running = max, .approvals = max } }, .first_action = max, .served_attention = .{ .kind = .approval, .turn = max, .step = max }, .served_group = .needs_you, .actions = .{ .stop = false, .interrupt = .{ .turn = max, .operation = max }, .decide = max } },
    } } };
    try observation.target.set(&escaped_session);
    observation.kind.message.?.recovery.count = protocol.message_recovery_limit;
    for (&observation.kind.message.?.recovery.calls) |*call| call.* = .{ .action_id = max, .operation_id = max, .call = max, .description = description, .at = max };
    var response: protocol.CommandObservationBuffer = .{};
    try response.render(host_reply.renderFullCommandObservation, .{ &escaped_key, &observation, &@as([change_ring.SessionToken.max_bytes]u8, @splat(1)) });
    try std.testing.expectEqual(protocol.command_observation_reply.maxBytes(.message) - protocol.shapeBytes(protocol.command_observation_reply.code), response.len);
}

test "MCP rejection diagnostics fit the protocol-owned response bound" {
    try std.testing.expect(protocol.configuration_reply.max_bytes <= protocol.max_response_bytes);
    try std.testing.expect(protocol.message_reply.max_bytes <= protocol.max_response_bytes);
    var host_tool_set = tools.built_in_tool_set;
    host_tool_set.configured_servers = &.{"notes"};
    var response: protocol.ResponseBuffer = .{};
    try response.render(host_reply.renderMessageReply, .{ "", store_module.MessageReply{ .rejected = .{
        .replayed = false,
        .code = .mcp_server_unavailable,
        .message = host_tool_set.missingTool("lookup"),
        .content = .{ .length = 4, .digest = protocol.contentDigest("task") },
    } } });
    try std.testing.expect(std.mem.indexOf(u8, response.slice(), "MCP server notes is unavailable and may provide it") != null);
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
            try response.render(host_reply.renderMutationReply(.session_stop), .{ command.session.slice(), result });
            try std.testing.expectEqual(expected, response.len);
        }

        fn expectInterruption(
            command: *const protocol.ModelInterruptionCommand,
            result: store_module.ModelInterruptionReply,
            expected: usize,
        ) !void {
            var response: protocol.ResponseBuffer = .{};
            try response.render(host_reply.renderMutationReply(.model_interruption), .{ store_module.ModelInterruptionTarget{ .session = command.session, .turn_id = command.turn_id, .operation_id = command.operation_id }, result });
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
    try pending_response.render(host_reply.renderMutationReply(.session_stop), .{ stop_command.session.slice(), store_module.SessionStopReply{ .accepted = .{
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
            var host_parts: TestParts = undefined;
            host_parts.attach(&host, undefined);
            var intake: Intake = .{ .host = &host };
            defer intake.exchanges.deinit(host.allocator);
            defer for (intake.exchanges.items) |exchange| {
                std.debug.assert(exchange.destroy());
            };
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
                .tools_reload => "control/tools-reload",
                .session_stop => "control/session-stop",
                .session_archive => "control/session-archive",
                .session_pin => "control/session-pin",
                .model_interruption => "control/model-interruption",
                .permission_decision => "control/permission-decision",
                .action_background => "control/action-background",
                .action_stop => "control/action-stop",
                .unsupported_control => "control/unknown",
                else => unreachable,
            };
            var header: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(&header, "POST /v1/{s} HTTP/1.1\r\n", .{path});
            try writeAll(host.io, sockets[1], line);
            try successor.read();
            try std.testing.expectEqual(.header, successor.state);
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
                var host_parts: TestParts = undefined;
                host_parts.attach(&host, &lease);
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
            var host_parts: TestParts = undefined;
            host_parts.attach(&host, undefined);
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
            while (!try peer.reply.?.advance(peer.fd)) {}
            peer.state = .retired;
            if (service_workers) intake.serviceWorkers();
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
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, &lease);
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
                try ingress.feed("{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"k\",\"session\":\"peer\",\"sender\":null,\"sender_handle\":null,\"text\":{\"state\":\"value\",\"value\":\"abc\"");
            },
            .retained_scratch, .report => {
                const file = try tmp.dir.createFile(host.io, "retained", .{ .read = true });
                try file.writeStreamingAll(host.io, "abc");
                try std.testing.expect(budget.charge(3));
                retained_fd = file.handle;
                if (custody == .retained_scratch) {
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
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
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

    var intake: Intake = .{ .host = &host };
    defer intake.exchanges.deinit(std.testing.allocator);
    for (&intake.workers) |*worker| worker.* = .{ .owner = &intake };
    try intake.exchanges.append(std.testing.allocator, &exchange);
    exchange.route = .configure;
    exchange.state = .ready;
    try adoptRequestForTest(&exchange, .{ .configure = .{} });
    defer exchange.releaseRequest();
    _ = host.lifecycle.advance(.stopping);
    intake.serviceWorkers();
    try std.testing.expectEqual(.retired, exchange.state);
    try std.testing.expectEqual(.prepare, exchange.job);
    for (&intake.workers) |*worker| {
        try std.testing.expectEqual(.idle, worker.state);
        try std.testing.expectEqual(null, worker.exchange);
    }
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

    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.store_identity.set("s");
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
            .accepted_at_ns = nowNs(host.io),
            .deadline = 0,
            .route = .host_stop,
            .state = .ready,
            .number = 1,
            .header = .{ .route = .host_stop, .content_length = 0, .instance = instance_id },
        };
        defer std.debug.assert(retry.cleanup());
        try adoptRequestForTest(&retry, .{ .host_stop = .{ .store = lease.paths.store_identity } });
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
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    const wake = try Intake.openIntakeWake();
    var intake: Intake = undefined;
    intake.init(&host, wake) catch |err| {
        for (wake) |fd| _ = std.c.close(fd);
        return err;
    };
    var intake_owned = true;
    defer if (intake_owned) intake.deinit();
    var sockets: [100][2]std.posix.fd_t = undefined;
    var count: usize = 0;
    defer {
        for (sockets[0..count]) |pair| {
            _ = std.c.close(pair[1]);
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

test "Host settings fields decide fenced MySQL shutdown once at the return boundary without clients" {
    const Probe = struct {
        var storage: *store_module.Store = undefined;
        var fence_on_delete: bool = false;
        var output: [1024]u8 = undefined;
        var used: usize = 0;

        fn delete(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8) std.Io.Dir.DeleteFileError!void {
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
    const interface = try std.fmt.bufPrint(&path_buffer, "{s}/interface", .{root[0..root_len]});
    var vtable = std.testing.io.vtable.*;
    vtable.dirDeleteFile = Probe.delete;
    vtable.operate = Probe.operate;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    for ([_]host_settings.Interface.Lifetime{ .detached, .stdin }) |lifetime| {
        for ([_]bool{ false, true }) |mysql| {
            for ([_]bool{ false, true }) |early| {
                for ([_]bool{ false, true }) |late| {
                    var storage: store_module.Store = .{ .io = io, .engine = undefined, .selector = .{}, .changes = undefined };
                    storage.engine = if (mysql) .{ .mysql = undefined } else .{ .sqlite = undefined };
                    storage.fenced.store(early, .release);
                    Probe.storage = &storage;
                    Probe.fence_on_delete = late;
                    Probe.used = 0;
                    var lease: platform.StoreLease = .{
                        .io = io,
                        .paths = .{},
                        .store_dir = .cwd(),
                        .lock_file = undefined,
                    };
                    var endpoint = try host_endpoint.claim(io, try .init(interface));
                    defer endpoint.retire() catch unreachable;
                    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
                    var host_parts: TestParts = undefined;
                    host_parts.attach(&host, &lease);
                    _ = host.lifecycle.advance(.stopping);
                    var intake: Intake = .{ .host = &host, .lifetime = lifetime, .deadline_armed = true };
                    for (&intake.workers) |*worker| worker.* = .{ .owner = &intake };
                    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &intake.wake));
                    try setNonblocking(intake.wake[0]);
                    defer intake.deinit();
                    var stdin: [2]c_int = undefined;
                    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&stdin));
                    defer _ = std.c.close(stdin[0]);
                    _ = std.c.close(stdin[1]);
                    intake.stdin = stdin[0];
                    var listener = try endpoint.listen(.{ .kernel_backlog = 8 });
                    var open = true;
                    defer if (open) listener.deinit(io);
                    var failure: ?start_report.Failure = null;
                    const outcome = finishServing(&storage, &failure, intake.run(&listener, &open, &endpoint));
                    const fenced = mysql and (early or late);
                    try std.testing.expectError(if (fenced) error.StoreFenced else error.EffectAwareShutdown, outcome);
                    try std.testing.expectEqual(@as(usize, 0), Probe.used);
                    var line_buffer: [start_report.max_line_bytes]u8 = undefined;
                    try std.testing.expectEqual(fenced, failure != null);
                    try std.testing.expectEqualStrings(if (fenced)
                        "{\"rui_start_error\":{\"code\":\"store_fenced\",\"message\":\"the MySQL Store lost ownership or its connection; restart the Host\"}}\n"
                    else
                        "", if (failure) |*value| start_report.line(value, &line_buffer) else "");
                    try std.testing.expectEqual(@as(usize, 0), intake.exchanges.items.len);
                }
            }
        }
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

        fn run(intake: *Intake, listener: *std.Io.net.Server, endpoint: *host_endpoint.Endpoint) void {
            var open = true;
            intake.run(listener, &open, endpoint) catch {};
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
    var interface_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const interface = try std.fmt.bufPrint(&interface_buffer, "/tmp/rui-{s}", .{std.fs.path.basename(root)});
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, interface) catch {};
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
        var lease: platform.StoreLease = .{
            .io = std.testing.io,
            .paths = .{},
            .store_dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{}),
            .lock_file = undefined,
        };
        try lease.paths.store_identity.set("s");
        try lease.paths.scratch.set(root);
        defer lease.store_dir.close(std.testing.io);
        var endpoint = try host_endpoint.claim(std.testing.io, try .init(interface));
        defer endpoint.retire() catch unreachable;
        var socket_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
        const address = try std.Io.net.UnixAddress.init(try endpoint.socketPath(&socket_buffer));
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
        const wake = try Intake.openIntakeWake();
        var host_parts: TestParts = undefined;
        host_parts.attachWithWake(&host, &lease, wake[1]);
        var retention = output_retention.Queue.initialize(io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
        host.retention = &retention;
        var intake: Intake = undefined;
        intake.init(&host, wake) catch |err| {
            for (wake) |fd| _ = std.c.close(fd);
            return err;
        };
        defer intake.deinit();
        var listener = try endpoint.listen(.{ .kernel_backlog = 8 });
        const partial_header = try address.connect(std.testing.io);
        defer partial_header.socket.close(std.testing.io);
        const partial_body = try address.connect(std.testing.io);
        defer partial_body.socket.close(std.testing.io);
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
        const thread = try std.Thread.spawn(.{}, Probe.run, .{ &intake, &listener, &endpoint });
        var joined = false;
        defer if (!joined) {
            Probe.released.store(true, .release);
            _ = host.lifecycle.advance(.stopping);
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
        try std.testing.expect(host.lifecycle.stopping());
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
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
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
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
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
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
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
    try lease.paths.store_identity.set("s");
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
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
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
    try Send.message(&host, "first", session, "B=2\x00");
    try expectCopy(&environments, session, "A=1\x00");
    try Send.message(&host, "rejected", "zzzzzz", "C=3\x00");
    try expectCopy(&environments, "zzzzzz", null);
    try expectCopy(&environments, session, "A=1\x00");
    try std.testing.expectEqual(held, .{ environments.len, environments.value_count, environments.value_bytes });
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
        .store = undefined,
    };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
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
        exchange.cleanup_retry_at = @as(i128, nowNs(host.io)) + std.time.ns_per_s;
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
    var info: host_reply.HostInfo = .{ .store = id, .instance = @splat(1), .active_capacity = 2, .intake_capacity = 100, .descriptor_soft_limit = 1024, .started_at = 1792918800, .custody_occupied = 0, .paused = false, .routes = protocol.routesAll(.unserved), .doublewrite = "OFF", .settings_digest = null };
    try response.render(host_reply.renderHostInfo, .{info});
    const status = try protocol_reply.parseHostInfo(response.slice(), id);
    try std.testing.expectEqualStrings("OFF", status.ready.innodb_doublewrite.?.slice());
    response.len = 0;
    info.store = "/sqlite";
    info.doublewrite = null;
    try response.render(host_reply.renderHostInfo, .{info});
    try std.testing.expect(std.mem.indexOf(u8, response.slice(), "innodb_doublewrite") == null);
    const shape = protocol.host_info_reply;
    try std.testing.expectEqual(protocol.shapeBytes(shape.head) + protocol.shapeBytes(shape.doublewrite) + protocol.shapeBytes(shape.settings_digest) + protocol.shapeBytes(shape.tail), protocol.max_host_info_response_bytes);
}

test "MCP socket capacity is reserved beside model and Bash descriptors" {
    var requirement = try descriptor_capacity.calculate(3, 2, 10, 3, .requests, false, os.tag);
    const before = requirement;
    try reserveMcpDescriptors(&requirement);
    try std.testing.expectEqual(before.execution + mcp_socket_capacity, requirement.execution);
    try std.testing.expectEqual(before.total + mcp_socket_capacity, requirement.total);
    try std.testing.expectEqual(before.clients, requirement.clients);
    try std.testing.expectEqual(before.inherited, requirement.inherited);
}

test "creation receipt survives dropped and failed reply allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.store_identity.set(root);
    try lease.paths.scratch.set(root);
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    const request = try std.testing.allocator.create(wire_request.Request);
    defer std.testing.allocator.destroy(request);
    request.* = .{ .configure = try store_module.testingCompleteConfiguration("receipt-allocation", "", root, "model-a") };
    try request.configure.store.set(root);
    var header = Header{ .route = .configure, .content_length = 0 };
    var receipt_failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    host.allocator = receipt_failure.allocator();
    var reply = Reply{ .io = std.testing.io, .allocator = std.testing.allocator };
    try std.testing.expectError(error.OutOfMemory, prepareReply(&host, &reply, -1, header, 0, 0, request, null, null));
    try std.testing.expect(!try storage.commandExists(request.configure.key.slice()));
    try std.testing.expectEqual(receipt_failure.allocated_bytes, receipt_failure.freed_bytes);
    var accounting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    host.allocator = accounting.allocator();
    var output_failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    reply.allocator = output_failure.allocator();
    try prepareReply(&host, &reply, -1, header, 0, 0, request, null, null);
    try std.testing.expect(reply.body == .none);
    try std.testing.expect(try storage.commandExists(request.configure.key.slice()));
    try std.testing.expect(accounting.allocations > 0);
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
    reply.allocator = std.testing.allocator;
    try prepareReply(&host, &reply, -1, header, 0, 0, request, null, null);
    try std.testing.expect(reply.body == .json);
    try std.testing.expect(std.mem.indexOf(u8, reply.body.json, "\"configuration\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply.body.json, "\"replayed\":true") != null);
    const Session = protocol.Bounded(protocol.max_session_bytes);
    const readSession = struct {
        fn call(body: []const u8) !Session {
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
            defer parsed.deinit();
            return Session.from(parsed.value.object.get("answer").?.object.get("session").?.string);
        }
    }.call;
    const first_session = try readSession(reply.body.json);
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
    reply.deinit();
    try prepareReply(&host, &reply, -1, header, 0, 0, request, null, null);
    try std.testing.expectEqualStrings(first_session.slice(), (try readSession(reply.body.json)).slice());
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
    reply.deinit();
    try request.configure.key.set("receipt-drop");
    header.drop = .after_commit;
    try prepareReply(&host, &reply, -1, header, 0, 0, request, null, null);
    try std.testing.expect(reply.body == .none);
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
    header.drop = .none;
    try prepareReply(&host, &reply, -1, header, 0, 0, request, null, null);
    try std.testing.expect(reply.body == .json);
    try std.testing.expect(std.mem.indexOf(u8, reply.body.json, "\"configuration\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply.body.json, "\"replayed\":true") != null);
    const dropped_session = try readSession(reply.body.json);
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
    reply.deinit();
    try prepareReply(&host, &reply, -1, header, 0, 0, request, null, null);
    defer reply.deinit();
    try std.testing.expectEqualStrings(dropped_session.slice(), (try readSession(reply.body.json)).slice());
    try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
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
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    const create = try arena.create(wire_request.ConfigureCommand);
    create.* = .{ .preset = .{} };
    try create.preset.?.set("review");
    try create.key.set("preset-create");
    create.configuration.workspace.state = .value;
    try create.configuration.workspace.value.set(root);
    const reload = try arena.create(wire_request.ConfigureCommand);
    reload.* = .{ .preset = create.preset, .reload_skills = true };
    try reload.key.set("skills-reload-preset-empty");
    const reload_refused = try submitConfigure(&host, reload, null);
    try std.testing.expect(reload_refused == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_session, reload_refused.rejected.code);
    try std.testing.expect((try submitConfigure(&host, reload, null)).rejected.replayed);
    reload.reload_skills = false;
    try std.testing.expect(try submitConfigure(&host, reload, null) == .conflict);
    const first = try submitConfigure(&host, create, null);
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
    const replay = try submitConfigure(&host, create, null);
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
    const overridden = try submitConfigure(&host, override, null);
    try std.testing.expect(overridden == .accepted);
    try storage.inspectSession(overridden.accepted.session.slice(), &observed);
    try std.testing.expectEqualStrings("preset-override-model", observed.model.slice());
    try std.testing.expectEqual(protocol.Provider.codex, observed.provider.?);
    try std.testing.expectEqualStrings(root, observed.workspace.slice());
    try std.testing.expectEqual(@as(?u64, 12000), observed.compaction_trigger_override);
    try std.testing.expectEqual(@import("configuration_defaults.zig").startEffort(@import("model_catalog.zig").shipped, "preset-override-model"), observed.reasoning_effort_override);
    try std.testing.expectEqualStrings("bypass", observed.permission_mode.slice());
    try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member WHERE tool_set_id=?1", .{observed.tool_set_id}));
    try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?1 AND tool.name='start_agent'", .{observed.tool_set_id}));
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("Overridden instructions"), &observed.instructions.digest);
    try std.testing.expect(observed.output_schema == null);

    const edited_spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"model":"gpt-6-sol","effort":"low","compactAt":10000,"tools":[],"permissionMode":"ask","provider":"openai","instructions":"Preset instructions","outputSchema":{"type":"object"},"label":"Preset label"}
    , .{})).object;
    const edited_presets = [_]core_tools.Preset{.{ .name = "review", .spec = edited_spec }};
    host.presets = &edited_presets;
    const same = try submitConfigure(&host, override, null);
    try std.testing.expect(same == .accepted and same.accepted.replayed);
    try std.testing.expectEqualStrings(overridden.accepted.session.slice(), same.accepted.session.slice());
    try std.testing.expect(try submitConfigure(&host, create, null) == .conflict);
    try storage.inspectSession(session.slice(), &observed);
    try std.testing.expectEqualStrings("gpt-6.1-sol", observed.model.slice());

    const invalid = try arena.create(wire_request.ConfigureCommand);
    invalid.* = .{ .preset = create.preset };
    try invalid.key.set("preset-invalid-resolved");
    invalid.configuration.workspace.state = .value;
    try invalid.configuration.workspace.value.set(root);
    invalid.configuration.compaction_trigger.state = .value;
    try invalid.configuration.compaction_trigger.value.set("0");
    const refused = try submitConfigure(&host, invalid, null);
    try std.testing.expect(refused == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_compaction_trigger, refused.rejected.code);
    host.presets = &.{};
    try std.testing.expect(try submitConfigure(&host, create, null) == .conflict);
    const missing = try arena.create(wire_request.ConfigureCommand);
    missing.* = .{ .preset = create.preset };
    try missing.key.set("preset-missing");
    const unknown = try submitConfigure(&host, missing, null);
    try std.testing.expect(unknown == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, unknown.rejected.code);
    host.presets = &presets;
    const refused_again = try submitConfigure(&host, missing, null);
    try std.testing.expect(refused_again == .rejected and refused_again.rejected.replayed);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, refused_again.rejected.code);
    invalid.session = session;
    try invalid.key.set("preset-on-update");
    const update = try submitConfigure(&host, invalid, null);
    try std.testing.expect(update == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, update.rejected.code);
    const update_replay = try submitConfigure(&host, invalid, null);
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
                try response.render(host_reply.renderMutationReply(.session_archive), .{ command.session.slice(), store_module.SessionArchiveReply{ .accepted = .{
                    .replayed = replayed,
                    .archived = archived,
                    .completion = completion,
                } } });
                const decoded = try protocol_reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "k7m2qx", .{ .session_archive = .{ .archived = archived } }).answer;
                try std.testing.expectEqual(replayed, decoded.replayed);
                try std.testing.expectEqual(archived, decoded.result.accepted.session_archive.archived);
                try std.testing.expectEqual(completion, decoded.result.accepted.session_archive.completion);
            }
        }
    }
    for (std.meta.tags(protocol.SessionArchiveRejection)) |code| {
        var response: protocol.ResponseBuffer = .{};
        try response.render(host_reply.renderMutationReply(.session_archive), .{ command.session.slice(), store_module.SessionArchiveReply{ .rejected = .{ .replayed = true, .code = code } } });
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
    try lease.paths.store_identity.set(root);
    try lease.paths.scratch.set(root);
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    const text = "prompt /demo";
    var command: wire_request.MessageCommand = .{ .session = configured.accepted.session, .text = .{ .state = .value, .borrowed = text.ptr, .length = text.len, .digest = protocol.contentDigest(text) } };
    try command.key.set("pressure-key");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var oom_offer = try SessionEnvironments.Offer.init(std.testing.allocator, 0);
        failing = .init(std.testing.allocator, .{ .fail_index = fail_index });
        host.allocator = failing.allocator();
        const result = submitMessage(&host, &command, &oom_offer, null);
        host.allocator = std.testing.allocator;
        try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
        if (!failing.has_induced_failure) break;
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expect(!try storage.commandExists(command.key.slice()));
    }
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
    host.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, readSkillSuggestions(&host, std.testing.allocator, .{ .session = configured.accepted.session.slice() }, ""));
    host.allocator = std.testing.allocator;
    try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
    try std.testing.expectError(error.OutOfMemory, readSkillSuggestions(&host, failing.allocator(), .{ .session = configured.accepted.session.slice() }, ""));
    try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
    var preview = try readSkillSuggestions(&host, std.testing.allocator, .{ .session = configured.accepted.session.slice() }, "");
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(@import("skill_suggestions.zig").capacity, preview.entries.len);
    try std.testing.expectEqual(entries.len, preview.total);
    var retry_offer = try SessionEnvironments.Offer.init(std.testing.allocator, 0);
    const accepted = try submitMessage(&host, &command, &retry_offer, null);
    try std.testing.expect(accepted == .accepted and accepted.accepted.replayed);
    try std.testing.expectEqual(@as(u64, text.len), accepted.accepted.content.text.length);
    try std.testing.expect(host.lifecycle.launchAllowed() and !storage.isFenced());
    var reload: wire_request.ConfigureCommand = .{ .session = configured.accepted.session, .reload_skills = true };
    try reload.key.set("pressure-reload");
    fail_index = 0;
    while (true) : (fail_index += 1) {
        failing = .init(std.testing.allocator, .{ .fail_index = fail_index });
        host.allocator = failing.allocator();
        const result = submitConfigure(&host, &reload, null);
        host.allocator = std.testing.allocator;
        try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
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
    try std.testing.expect(storage.isFenced() and !host.lifecycle.launchAllowed());
}

test "inline skills suggestions answer heap exhaustion as busy, not a catalog refusal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    try lease.paths.store_identity.set("s");
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    var request_buffer: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buffer, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"skill_suggestions\",\"store\":\"s\",\"workspace\":\"{s}\",\"prefix\":\"\"}}", .{root});
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
        try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
        const status = reply.header[0..reply.header_length];
        if (!failing.has_induced_failure) {
            try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 200 "));
            break;
        }
        try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 503 "));
    }
    try std.testing.expect(fail_index > 0);
}

test "SH-51 a route that cannot serve a parts value refuses it as ordinary and leaves the Host serving" {
    // A Session holds both parts producers: a compound Message and a read_image Resolution.
    // Readers project them; every text-only route refuses a parts value and both parts routes
    // refuse a text value as ordinary 409s. Only a Store that fenced itself fences dispatch.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    try lease.paths.store_identity.set("s");
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var configure = try store_module.testingCompleteConfiguration("parts-config", "", try store_module.testingCanonicalCwd(std.testing.io, &workspace_buffer), "model-a");
    configure.configuration.tools = try .of(&.{"read_image"});
    const session = (try storage.configure(&configure, .{})).accepted.session;
    try store_module.testingSubmitMessage(&storage, &tmp, "parts-task", "parts-task", session.slice(), "look");
    const attempt = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const call: store_module.TestingCall = .{ .item_id = "parts-call", .name = "read_image", .encoded_call_id = "parts-call", .decoded_call_id = "parts-call", .encoded_arguments = "{\\\"path\\\":\\\"image.png\\\"}", .decoded_arguments = "{\"path\":\"image.png\"}" };
    try store_module.settleCallsForTesting(&storage, &tmp, attempt, "parts-call", &.{call});
    const selected = (try storage.nextAction(.read_image, .fromFree(1, false))).?;
    const effect = (try storage.admitActionAttempt(selected, 1234, .{})).?.permit.binding;
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    try store_module.testing.settleTestActionParts(&storage, &tmp, effect, &.{.{ .bytes = png, .kind = .{ .image = .{} } }});
    const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_module.settleAnswerItemsForTesting(&storage, &tmp, continuation, &.{"{\"type\":\"message\",\"id\":\"parts-answer\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}"}, "Done.");
    try store_module.testing.submitTestMessagePartsWithSkills(&storage, &tmp, "parts-message", session.slice(), &.{
        .{ .bytes = "before" }, .{ .bytes = png, .kind = .{ .image = .{} } }, .{ .bytes = "after" },
    }, null);
    _ = (try storage.admitNextModelAttempt(.{})).?;
    try std.testing.expect(!storage.isFenced());

    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;
    const head = "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"";
    // Each row expects a status and can require a substring in its response body.
    const Read = struct { path: []const u8, body: []const u8, status: []const u8 = "200", has: ?[]const u8 = null };
    const result_position = try store_module.testing.queryU64(&storage, "SELECT acceptance_position FROM action_operation WHERE action_id=?1", .{selected.action_id});
    const text_admission = try store_module.testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"parts-task"});
    const action_owner = try std.fmt.allocPrint(arena, "\"owner\":{{\"action\":\"{d}\"}}", .{selected.action_id});
    const parts_admission = try store_module.testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"parts-message"});
    const admission_position = try store_module.testing.queryU64(&storage, "SELECT admission_position FROM message_admission WHERE admission_id=?1", .{parts_admission});
    const message_position = try store_module.testing.queryU64(&storage, "SELECT session_position FROM conversation_entry WHERE source_admission_id=?1", .{parts_admission});
    const message_owner = try std.fmt.allocPrint(arena, "\"owner\":{{\"message\":\"{d}\"}}", .{parts_admission});
    const reads = [_]Read{
        .{ .path = "read-action", .body = try std.fmt.allocPrint(arena, head ++ "read_action\",\"store\":\"s\",\"session\":\"{s}\",\"action\":\"{d}\"}}", .{ session.slice(), selected.action_id }), .has = action_owner },
        .{ .path = "activity-page", .body = try std.fmt.allocPrint(arena, head ++ "activity_page\",\"store\":\"s\",\"session\":\"{s}\",\"end\":null,\"position\":\"0\",\"ordinal\":null,\"direction\":\"forward\",\"kinds\":[\"admission\",\"user\",\"assistant\",\"call\",\"tool_result\"],\"limit\":\"16\"}}", .{session.slice()}), .has = action_owner },
        .{ .path = "activity-page", .body = try std.fmt.allocPrint(arena, head ++ "activity_page\",\"store\":\"s\",\"session\":\"{s}\",\"end\":null,\"position\":\"0\",\"ordinal\":null,\"direction\":\"forward\",\"kinds\":[\"admission\",\"user\",\"assistant\",\"call\",\"tool_result\"],\"limit\":\"16\"}}", .{session.slice()}), .has = message_owner },
        .{ .path = "conversation-page", .body = try std.fmt.allocPrint(arena, head ++ "conversation_page\",\"store\":\"s\",\"session\":\"{s}\",\"end\":\"0\",\"before_position\":\"0\",\"before_ordinal\":\"0\"}}", .{session.slice()}), .has = action_owner },
        .{ .path = "conversation-page", .body = try std.fmt.allocPrint(arena, head ++ "conversation_page\",\"store\":\"s\",\"session\":\"{s}\",\"end\":\"0\",\"before_position\":\"0\",\"before_ordinal\":\"0\"}}", .{session.slice()}), .has = message_owner },
        .{ .path = "observe-command", .body = try std.fmt.allocPrint(arena, head ++ "observe_command\",\"store\":\"s\",\"key\":\"parts-message\"}}", .{}), .has = "\"type\":\"parts\"" },
        .{ .path = "inspect-session", .body = try std.fmt.allocPrint(arena, head ++ "inspect_session\",\"store\":\"s\",\"session\":\"{s}\"}}", .{session.slice()}) },
        .{ .path = "activity-search", .body = try std.fmt.allocPrint(arena, head ++ "activity_search\",\"store\":\"s\",\"session\":\"{s}\",\"query\":\"after\",\"kinds\":[\"admission\",\"user\",\"tool_result\"],\"before_position\":null,\"before_ordinal\":null,\"limit\":\"16\"}}", .{session.slice()}), .has = "\"part\":\"2\"" },
        .{ .path = "list-sessions", .body = try std.fmt.allocPrint(arena, head ++ "list_sessions\",\"store\":\"s\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"0\"}}", .{}) },
        .{ .path = "read-action-arguments", .body = try std.fmt.allocPrint(arena, head ++ "read_action_arguments\",\"store\":\"s\",\"session\":\"{s}\",\"action\":\"{d}\"}}", .{ session.slice(), selected.action_id }) },
        .{ .path = "read-action-call-id", .body = try std.fmt.allocPrint(arena, head ++ "read_action_call_id\",\"store\":\"s\",\"session\":\"{s}\",\"action\":\"{d}\"}}", .{ session.slice(), selected.action_id }) },
        .{ .path = "read-result", .body = try std.fmt.allocPrint(arena, head ++ "read_result\",\"store\":\"s\",\"key\":\"parts-message\"}}", .{}), .status = "409", .has = "result_not_ready" },
        // Text-only routes on a parts Message and a parts Action Resolution.
        .{ .path = "activity-content", .body = try std.fmt.allocPrint(arena, head ++ "activity_content\",\"store\":\"s\",\"session\":\"{s}\",\"position\":\"{d}\",\"ordinal\":\"0\"}}", .{ session.slice(), admission_position }), .status = "409", .has = "ContentIsParts" },
        .{ .path = "activity-content", .body = try std.fmt.allocPrint(arena, head ++ "activity_content\",\"store\":\"s\",\"session\":\"{s}\",\"position\":\"{d}\",\"ordinal\":\"0\"}}", .{ session.slice(), message_position }), .status = "409", .has = "ContentIsParts" },
        .{ .path = "conversation-content", .body = try std.fmt.allocPrint(arena, head ++ "conversation_content\",\"store\":\"s\",\"session\":\"{s}\",\"position\":\"{d}\",\"ordinal\":\"0\",\"start\":\"0\",\"stream\":true}}", .{ session.slice(), message_position }), .status = "409", .has = "ContentIsParts" },
        .{ .path = "activity-content", .body = try std.fmt.allocPrint(arena, head ++ "activity_content\",\"store\":\"s\",\"session\":\"{s}\",\"position\":\"{d}\",\"ordinal\":\"1\"}}", .{ session.slice(), result_position }), .status = "409", .has = "ContentIsParts" },
        .{ .path = "conversation-content", .body = try std.fmt.allocPrint(arena, head ++ "conversation_content\",\"store\":\"s\",\"session\":\"{s}\",\"position\":\"{d}\",\"ordinal\":\"1\",\"start\":\"0\"}}", .{ session.slice(), result_position }), .status = "409", .has = "ContentIsParts" },
        .{ .path = "read-action", .body = try std.fmt.allocPrint(arena, head ++ "read_action\",\"store\":\"s\",\"session\":\"{s}\",\"action\":\"{d}\",\"offset\":\"1\"}}", .{ session.slice(), selected.action_id }), .status = "400", .has = "invalid_cursor" },
        // Both parts routes on a text value.
        .{ .path = "public-parts", .body = try std.fmt.allocPrint(arena, head ++ "public_parts\",\"store\":\"s\",\"session\":\"{s}\",\"owner\":{{\"message\":\"{d}\"}}}}", .{ session.slice(), text_admission }), .status = "409", .has = "ContentIsText" },
        .{ .path = "public-part-content", .body = try std.fmt.allocPrint(arena, head ++ "public_part_content\",\"store\":\"s\",\"session\":\"{s}\",\"owner\":{{\"message\":\"{d}\"}},\"part\":\"0\",\"start\":\"0\"}}", .{ session.slice(), text_admission }), .status = "409", .has = "ContentIsText" },
        // A completed text result still streams after the ordinary refusals.
        .{ .path = "read-result", .body = try std.fmt.allocPrint(arena, head ++ "read_result\",\"store\":\"s\",\"key\":\"parts-task\"}}", .{}), .has = "Done." },
    };
    const Answer = struct { status: []const u8, body: []const u8 };
    const exchangeRead = struct {
        fn run(serving: *Host, allocator: std.mem.Allocator, read: Read) !Answer {
            var sockets: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
            defer _ = std.c.close(sockets[1]);
            try setNonblocking(sockets[0]);
            var header_buffer: [256]u8 = undefined;
            try writeAll(std.testing.io, sockets[1], try std.fmt.bufPrint(&header_buffer, "POST /v1/{s} HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Length: {d}\r\n\r\n", .{ read.path, read.body.len }));
            try writeAll(std.testing.io, sockets[1], read.body);
            const exchange = try std.testing.allocator.create(Intake.Exchange);
            exchange.* = .{ .owner = undefined, .host = serving, .fd = sockets[0], .accepted_at_ns = 0, .deadline = std.math.maxInt(i128) };
            defer std.debug.assert(exchange.destroy());
            try exchange.read();
            try std.testing.expectEqual(.ready, exchange.state);
            const reply = try exchange.ensureReply();
            exchange.prepare() catch |err| exchange.fail(err);
            return .{
                .status = try allocator.dupe(u8, reply.header[0..reply.header_length]),
                .body = try allocator.dupe(u8, switch (reply.body) {
                    .json => |bytes| bytes,
                    .content => content: {
                        try reply.fill();
                        break :content reply.window[0..reply.window_length];
                    },
                    else => "",
                }),
            };
        }
    }.run;

    for (reads) |read| {
        const answer = try exchangeRead(&host, arena, read);
        const status = std.mem.startsWith(u8, answer.status, "HTTP/1.1 ") and std.mem.startsWith(u8, answer.status["HTTP/1.1 ".len..], read.status);
        const carries = if (read.has) |member| std.mem.indexOf(u8, answer.body, member) != null else true;
        if (!status or !carries or storage.isFenced() or !host.lifecycle.launchAllowed()) {
            std.debug.print("{s}: expected {s} with {?s}, got {s}{s}\n", .{ read.path, read.status, read.has, answer.status, answer.body });
            return error.TestUnexpectedResult;
        }
    }

    // A Store that fails its own read fences, and so does the Host.
    try store_module.testingFailReadsOf(&storage, "action_operation");
    const failed = try exchangeRead(&host, arena, reads[0]);
    try std.testing.expect(std.mem.indexOf(u8, failed.body, "canonical_store_failure") != null);
    try std.testing.expect(storage.isFenced() and !host.lifecycle.launchAllowed());
}

test "INS-11 public part content windows" {
    // A Message holds a 5000-byte Text part and a named PNG part. The Host lists them,
    // serves each part's exact bytes in windows and streams, and refuses everything else.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    try lease.paths.store_identity.set("s");
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store_module.testingCanonicalCwd(std.testing.io, &workspace_buffer);
    var own_configure = try store_module.testingCompleteConfiguration("parts-own", "", workspace, "model-a");
    const own = (try storage.configure(&own_configure, .{})).accepted.session;
    var foreign_configure = try store_module.testingCompleteConfiguration("parts-foreign", "", workspace, "model-a");
    const foreign = (try storage.configure(&foreign_configure, .{})).accepted.session;
    var text: [5000]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    var name: @import("input_parts.zig").Name = .{};
    try name.set("cat \"雪\".png");
    try store_module.testing.submitTestMessageParts(&storage, &tmp, "parts-mixed", own.slice(), &.{
        .{ .bytes = &text }, .{ .bytes = png, .kind = .{ .image = .{ .assertion = .png, .name = name } } },
    });
    try store_module.testing.submitTestMessageParts(&storage, &tmp, "parts-text", own.slice(), &.{.{ .bytes = "only text" }});
    const mixed = try store_module.testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"parts-mixed"});
    const only_text = try store_module.testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"parts-text"});
    const manifest = manifest: {
        var reader = try store_module.PublicParts.Reader.init(own, .{ .message = mixed });
        defer reader.deinit();
        while (true) switch (try storage.readPublicParts(&reader)) {
            .certified => |value| break :manifest value.identity,
            .done => return error.TestUnexpectedResult,
            .pending, .part => {},
        };
    };

    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = 9000 }, &.{});
    host.retention = &retention;

    const Answer = struct { header: []const u8, body: []const u8 };
    const exchange = struct {
        fn run(serving: *Host, allocator: std.mem.Allocator, path: []const u8, body: []const u8) !Answer {
            var sockets: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets));
            defer _ = std.c.close(sockets[1]);
            try setNonblocking(sockets[0]);
            var header_buffer: [256]u8 = undefined;
            try writeAll(std.testing.io, sockets[1], try std.fmt.bufPrint(&header_buffer, "POST /v1/{s} HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nContent-Length: {d}\r\n\r\n", .{ path, body.len }));
            try writeAll(std.testing.io, sockets[1], body);
            const intake = try std.testing.allocator.create(Intake.Exchange);
            intake.* = .{ .owner = undefined, .host = serving, .fd = sockets[0], .accepted_at_ns = 0, .deadline = std.math.maxInt(i128) };
            defer std.debug.assert(intake.destroy());
            try intake.read();
            try std.testing.expectEqual(.ready, intake.state);
            const reply = try intake.ensureReply();
            intake.prepare() catch |err| intake.fail(err);
            // Every answer here fits the socket buffer, so delivery completes without a reader.
            try reply.deliver(sockets[0]);
            var received: std.ArrayList(u8) = .empty;
            var chunk: [4096]u8 = undefined;
            while (true) {
                const count = std.c.recv(sockets[1], &chunk, chunk.len, std.c.MSG.DONTWAIT);
                if (count <= 0) break;
                try received.appendSlice(allocator, chunk[0..@intCast(count)]);
            }
            const split = (std.mem.indexOf(u8, received.items, "\r\n\r\n") orelse return error.MissingHeaders) + 4;
            return .{ .header = received.items[0..split], .body = received.items[split..] };
        }
    }.run;
    const head = "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"";

    // The list: the manifest and every part, certified, in one report.
    const list = try exchange(&host, arena, "public-parts", try std.fmt.allocPrint(arena, head ++ "public_parts\",\"store\":\"s\",\"session\":\"{s}\",\"owner\":{{\"message\":\"{d}\"}}}}", .{ own.slice(), mixed }));
    try std.testing.expect(std.mem.startsWith(u8, list.header, "HTTP/1.1 200 "));
    const expected_list = try std.fmt.allocPrint(arena, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"public_parts\",\"session\":\"{s}\",\"value\":{{\"type\":\"parts\",\"bytes\":\"{d}\",\"sha256\":\"{s}\",\"owner\":{{\"message\":\"{d}\"}}}},\"parts\":[" ++
        "{{\"ordinal\":\"0\",\"type\":\"text\",\"bytes\":\"5000\",\"sha256\":\"{s}\"}}," ++
        "{{\"ordinal\":\"1\",\"type\":\"image\",\"mime\":\"image/png\",\"width\":\"1\",\"height\":\"1\",\"name\":\"cat \\\"雪\\\".png\",\"bytes\":\"{d}\",\"sha256\":\"{s}\"}}]}}", .{
        own.slice(),                                               manifest.length, std.fmt.bytesToHex(manifest.digest, .lower),             mixed,
        std.fmt.bytesToHex(protocol.contentDigest(&text), .lower), png.len,         std.fmt.bytesToHex(protocol.contentDigest(png), .lower),
    });
    try std.testing.expectEqualStrings(expected_list, list.body);

    const Read = struct { session: []const u8, owner: []const u8, part: u32, start: u64, stream: bool = false, bytes: ?[]const u8 = null, next: u64 = 0, refusal: []const u8 = "" };
    const message = try std.fmt.allocPrint(arena, "{{\"message\":\"{d}\"}}", .{mixed});
    const text_message = try std.fmt.allocPrint(arena, "{{\"message\":\"{d}\"}}", .{only_text});
    const reads = [_]Read{
        .{ .session = own.slice(), .owner = message, .part = 0, .start = 0, .bytes = text[0..4096], .next = 4096 },
        .{ .session = own.slice(), .owner = message, .part = 0, .start = 100, .bytes = text[100..4196], .next = 4196 },
        .{ .session = own.slice(), .owner = message, .part = 0, .start = 4096, .bytes = text[4096..], .next = 5000 },
        .{ .session = own.slice(), .owner = message, .part = 0, .start = 0, .stream = true, .bytes = &text, .next = 5000 },
        .{ .session = own.slice(), .owner = message, .part = 0, .start = 5000, .bytes = "", .next = 5000 },
        .{ .session = own.slice(), .owner = message, .part = 0, .start = 5001, .refusal = "RangeOutOfBounds" },
        .{ .session = own.slice(), .owner = message, .part = 1, .start = 0, .bytes = png, .next = png.len },
        .{ .session = own.slice(), .owner = message, .part = 1, .start = 0, .stream = true, .bytes = png, .next = png.len },
        .{ .session = own.slice(), .owner = message, .part = 2, .start = 0, .refusal = "ContentNotFound" },
        .{ .session = own.slice(), .owner = text_message, .part = 0, .start = 0, .refusal = "ContentIsText" },
        .{ .session = foreign.slice(), .owner = message, .part = 0, .start = 0, .refusal = "ContentNotFound" },
        .{ .session = own.slice(), .owner = "{\"action\":\"1\"}", .part = 0, .start = 0, .refusal = "ContentNotFound" },
    };
    for (reads) |read| {
        const answer = try exchange(&host, arena, "public-part-content", try std.fmt.allocPrint(arena, head ++ "public_part_content\",\"store\":\"s\",\"session\":\"{s}\",\"owner\":{s},\"part\":\"{d}\",\"start\":\"{d}\"{s}}}", .{ read.session, read.owner, read.part, read.start, if (read.stream) ",\"stream\":true" else "" }));
        if (read.bytes) |bytes| {
            const total: u64 = if (read.part == 0) text.len else png.len;
            const headers = try std.fmt.allocPrint(arena, "Content-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\n", .{ bytes.len, total, read.next });
            try std.testing.expect(std.mem.startsWith(u8, answer.header, "HTTP/1.1 200 "));
            try std.testing.expect(std.mem.indexOf(u8, answer.header, headers) != null);
            try std.testing.expectEqualSlices(u8, bytes, answer.body);
        } else {
            try std.testing.expect(std.mem.startsWith(u8, answer.header, "HTTP/1.1 409 "));
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"parts_unavailable\",\"code\":\"{s}\"}}", .{read.refusal}), answer.body);
        }
    }
    // The list refuses the same owners the part read does.
    for ([_][2][]const u8{ .{ own.slice(), text_message }, .{ foreign.slice(), message } }, [_][]const u8{ "ContentIsText", "ContentNotFound" }) |pair, code| {
        const answer = try exchange(&host, arena, "public-parts", try std.fmt.allocPrint(arena, head ++ "public_parts\",\"store\":\"s\",\"session\":\"{s}\",\"owner\":{s}}}", .{ pair[0], pair[1] }));
        try std.testing.expect(std.mem.indexOf(u8, answer.body, code) != null and std.mem.startsWith(u8, answer.header, "HTTP/1.1 409 "));
    }
    try std.testing.expect(!storage.isFenced() and host.lifecycle.launchAllowed());
}

test "SH-53 a dispatch fence records its reason in the Host diagnostics file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try HostDiagnostics.open(io, tmp.dir, HostDiagnostics.default_cap_bytes);
    defer writer.close();

    var unattached = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined };
    var unattached_parts: TestParts = undefined;
    unattached_parts.attach(&unattached, undefined);
    unattached.lifecycle.fenceDispatch("before readiness", error.Unattached);
    try std.testing.expect(unattached.lifecycle.stopping());

    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    writer.record("ready", "serving");
    host.lifecycle.attachDiagnostics(&writer);
    host.lifecycle.retainDispatchFence("retained cleanup", error.Retained);
    host.lifecycle.retainDispatchFence("retained again", error.RetainedAgain);
    host.lifecycle.fenceDispatch("Action status observation", error.InputPartsNotSupported);
    host.lifecycle.fenceDispatch("second fence", error.Later);
    try std.testing.expect(host.lifecycle.stopping());

    var buffer: [4096]u8 = undefined;
    const bytes = try tmp.dir.readFile(io, "diagnostics/host-1.jsonl", &buffer);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    const expected = [_][]const u8{
        "\"classification\":\"startup\",\"phase\":\"ready\",\"detail\":\"serving\"}",
        "\"classification\":\"fenced\",\"phase\":\"retained cleanup\",\"detail\":\"Retained\"}",
        "\"classification\":\"stopping\",\"phase\":\"Action status observation\",\"detail\":\"InputPartsNotSupported\"}",
    };
    for (expected) |suffix| try std.testing.expect(std.mem.endsWith(u8, lines.next() orelse "", suffix));
    try std.testing.expectEqual(null, lines.next());
}

test "Host startup offers a clashing MCP tool under its prefix and leaves excess tools out" {
    const Script = @import("mcp/test_server.zig");
    const built_ins = tools.built_in_tool_set.records.len;
    for ([_]bool{ false, true }) |too_many| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store_module.Store = undefined;
        try store_module.testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
        defer storage.close() catch unreachable;
        var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer json.deinit();
        try json.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[");
        if (too_many) {
            for (0..tools.max_host_tool_records) |i| {
                if (i != 0) try json.writer.writeByte(',');
                try json.writer.print("{{\"name\":\"tool_{d}\",\"inputSchema\":{{\"type\":\"object\"}}}}", .{i});
            }
        } else try json.writer.writeAll("{\"name\":\"bash\",\"inputSchema\":{\"type\":\"object\"}}");
        try json.writer.writeAll("]}}");
        const reply = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ json.written().len, json.written() });
        defer std.testing.allocator.free(reply);
        var script: Script = .{ .reply = reply };
        try script.start();
        defer script.stop();
        var server: server_mcp_settings.Server = .{};
        try server.name.set("docs");
        @memcpy(server.bearer_token.bytes[0..6], "secret");
        server.bearer_token.len = 6;
        var url: [128]u8 = undefined;
        try server.url.set(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{script.port}));
        const servers = [_]server_mcp_settings.Server{server};
        var owner = server_mcp_relist.Relist.init(std.testing.allocator, &servers, 1);
        defer owner.deinit();
        try offerMcpTools(std.testing.io, std.testing.allocator, &storage, &owner, null);
        const offered = storage.hostTools().host_tool_set;
        if (too_many) {
            try std.testing.expectEqual(tools.max_host_tool_records, offered.records.len);
            try std.testing.expectEqual(@as(u32, built_ins), owner.status(0).left_out);
            try std.testing.expectEqual(@as(u32, tools.max_host_tool_records - built_ins), owner.status(0).tools);
        } else {
            try std.testing.expectEqual(tools.Owner.rui, offered.records[offered.find("bash").?].owner);
            try std.testing.expectEqualStrings("bash", offered.records[offered.find("docs__bash").?].remote_name);
            try std.testing.expectEqual(@as(u32, 0), owner.status(0).left_out);
        }
    }
}

test "Host startup projects MCP offers after a changed listing and restart" {
    const Script = @import("mcp/test_server.zig");
    const testing = store_module.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    const replies = [_][]const u8{
        Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"fetch_page\",\"description\":\"old page\",\"inputSchema\":{\"type\":\"object\"}}]}}"),
        Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"fetch_page\",\"description\":\"new page\",\"inputSchema\":{\"type\":\"object\"},\"annotations\":{\"readOnlyHint\":true}}]}}"),
    };
    for (replies, 0..) |reply, round| {
        var script: Script = .{ .reply = reply };
        try script.start();
        defer script.stop();
        var storage: store_module.Store = undefined;
        try testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
        defer storage.close() catch unreachable;
        var server: server_mcp_settings.Server = .{};
        try server.name.set("docs");
        @memcpy(server.bearer_token.bytes[0..6], "secret");
        server.bearer_token.len = 6;
        var url: [128]u8 = undefined;
        try server.url.set(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{script.port}));
        const servers = [_]server_mcp_settings.Server{server};
        var owner = server_mcp_relist.Relist.init(std.testing.allocator, &servers, 1);
        defer owner.deinit();
        try offerMcpTools(std.testing.io, std.testing.allocator, &storage, &owner, null);
        if (round == 0) {
            var cwd: [protocol.max_workspace_bytes]u8 = undefined;
            var configure = try testing.completeConfiguration("restart-mcp-config", "", try testing.canonicalCwd(std.testing.io, &cwd), "model-a");
            configure.configuration.tools = try .of(&.{"fetch_page"});
            session = (try storage.configure(&configure, .{})).accepted.session;
        }
        const key = if (round == 0) "restart-mcp-first" else "restart-mcp-next";
        try testing.submitTestMessage(&storage, &tmp, key, key, session.slice(), "read page");
        const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT settings_revision FROM model_operation WHERE operation_id=?1", .{binding.operation_id}));
        const description = protocol.contentDigest(if (round == 0) "old page" else "new page");
        try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM model_operation m JOIN session_revision r ON r.session_ref=m.session_ref AND r.revision=m.settings_revision JOIN tool_set_member tm ON tm.tool_set_id=m.tool_set_id JOIN tool_record t ON t.tool_record_id=tm.tool_record_id JOIN content c ON c.content_id=t.description_content_id WHERE m.operation_id=?1 AND c.digest=?2", .{ binding.operation_id, testing.Blob{ .bytes = &description } }));
        try testing.settleItemsForTesting(&storage, &tmp, binding, &.{"{\"type\":\"message\",\"id\":\"done\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}"}, "done");
        try std.testing.expect(script.request_received.load(.acquire));
        try std.testing.expect(std.mem.indexOf(u8, script.seen[0..script.seen_len], "tools/list") != null);
        try std.testing.expect(!storage.isFenced());
    }
}

test "startup publishes every first list in one merge, so a tool moving between servers does not collide with its saved copy" {
    const Script = @import("mcp/test_server.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const reply = struct {
        fn of(comptime name: []const u8) []const u8 {
            return Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"" ++ name ++ "\",\"inputSchema\":{\"type\":\"object\"}}]}}");
        }
    }.of;
    // First run: a lists search, b lists other. Second run: search moved to b and a lists find.
    const rounds = [_][2][]const u8{ .{ reply("search"), reply("other") }, .{ reply("find"), reply("search") } };
    for (rounds, [_][]const u8{ "a", "b" }) |round, search_owner| {
        var a: Script = .{ .reply = round[0] };
        try a.start();
        defer a.stop();
        var b: Script = .{ .reply = round[1] };
        try b.start();
        defer b.stop();
        var storage: store_module.Store = undefined;
        try store_module.testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
        defer storage.close() catch unreachable;
        var servers = [_]server_mcp_settings.Server{ .{}, .{} };
        var urls: [2][128]u8 = undefined;
        for (&servers, &urls, [_][]const u8{ "a", "b" }, [_]u16{ a.port, b.port }) |*server, *url, name, port| {
            try server.name.set(name);
            @memcpy(server.bearer_token.bytes[0..6], "secret");
            server.bearer_token.len = 6;
            try server.url.set(try std.fmt.bufPrint(url, "http://127.0.0.1:{d}/mcp", .{port}));
        }
        var owner = server_mcp_relist.Relist.init(std.testing.allocator, &servers, 1);
        defer owner.deinit();
        try offerMcpTools(std.testing.io, std.testing.allocator, &storage, &owner, null);
        const set = storage.hostTools().host_tool_set;
        try std.testing.expectEqualStrings(search_owner, set.records[set.find("search").?].server);
    }
}

test "a server that was down at startup is listed by a backoff retry and the next Operation is offered its tools" {
    const Script = @import("mcp/test_server.zig");
    const testing = store_module.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store_module.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, std.testing.io, null);
    defer storage.close() catch unreachable;

    // Start a listener to learn a port, then close it: the server is down at startup.
    var down: Script = .{ .reply = "" };
    try down.start();
    down.stop();
    var servers = [_]server_mcp_settings.Server{.{}};
    try servers[0].name.set("docs");
    @memcpy(servers[0].bearer_token.bytes[0..6], "secret");
    servers[0].bearer_token.len = 6;
    var url: [128]u8 = undefined;
    try servers[0].url.set(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{down.port}));
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    try offerMcpTools(std.testing.io, std.testing.allocator, &storage, &owner, null);
    try std.testing.expect(storage.hostTools().host_tool_set.find("remote_lookup") == null);
    try std.testing.expectEqual(relist.Last.failed, owner.slots[0].last);

    // The server comes up on a new port; the same configured entry now points at it.
    const description = "remote page";
    var up: Script = .{ .reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"remote_lookup\",\"description\":\"" ++ description ++ "\",\"inputSchema\":{\"type\":\"object\"}}]}}") };
    try up.start();
    defer up.stop();
    try servers[0].url.set(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/mcp", .{up.port}));

    // Before the retry time nothing is due; at the retry time the list begins and lands.
    const retry_at = owner.slots[0].retry_at_ms;
    var publish_failure: ?anyerror = null;
    try std.testing.expect(!owner.service(&storage, retry_at - 1, &publish_failure));
    try std.testing.expectEqual(@as(?anyerror, null), publish_failure);
    try std.testing.expectEqual(@as(?anyerror, null), try owner.settleForTesting(std.testing.io, &storage, retry_at));
    try std.testing.expectEqual(relist.Last.listed, owner.slots[0].last);
    try std.testing.expect(storage.hostTools().host_tool_set.find("remote_lookup") != null);

    // An Operation admitted afterwards is offered the retried tool.
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    var cwd: [protocol.max_workspace_bytes]u8 = undefined;
    var configure = try testing.completeConfiguration("retry-mcp-config", "", try testing.canonicalCwd(std.testing.io, &cwd), "model-a");
    configure.configuration.tools = try .of(&.{"remote_lookup"});
    session = (try storage.configure(&configure, .{})).accepted.session;
    try testing.submitTestMessage(&storage, &tmp, "retry-mcp-next", "retry-mcp-next", session.slice(), "read page");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    const offered_digest = protocol.contentDigest(description);
    try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM model_operation m JOIN tool_set_member tm ON tm.tool_set_id=m.tool_set_id JOIN tool_record t ON t.tool_record_id=tm.tool_record_id JOIN content c ON c.content_id=t.description_content_id WHERE m.operation_id=?1 AND c.digest=?2", .{ binding.operation_id, testing.Blob{ .bytes = &offered_digest } }));
    try std.testing.expect(!storage.isFenced());
}

test "MCP list routes ask one named server or every server, refuse unknown or fenced asks, and report the Host instance" {
    const io = std.testing.io;
    const instance_hex = "7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e";
    var docs: server_mcp_settings.Server = .{};
    try docs.name.set("docs");
    var notes: server_mcp_settings.Server = .{};
    try notes.name.set("notes");
    const servers = [_]server_mcp_settings.Server{ docs, notes };
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .mcp_relist = &owner, .instance = @splat(0x7e) };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);

    // An unknown server is refused, and no list is asked.
    var request: @FieldType(wire_request.Request, "tools_reload") = .{};
    request.server = .{};
    try request.server.?.set("missing");
    {
        var reply: Reply = .{ .io = io, .allocator = std.testing.allocator };
        defer reply.deinit();
        try replyToolsReload(&host, &reply, &request);
        try std.testing.expect(std.mem.startsWith(u8, reply.header[0..reply.header_length], "HTTP/1.1 400 "));
        try std.testing.expect(std.mem.indexOf(u8, reply.body.json, "\"code\":\"unknown_mcp_server\"") != null);
    }
    try std.testing.expectEqual(@as(u64, 0), owner.asks[0].load(.acquire) + owner.asks[1].load(.acquire));
    try std.testing.expect(!host.lifecycle.dispatchWakeIsSet());

    // A fenced Host refuses the ask before recording it.
    _ = host.lifecycle.advance(.stopping);
    {
        var reply: Reply = .{ .io = io, .allocator = std.testing.allocator };
        defer reply.deinit();
        request.server = null;
        try replyToolsReload(&host, &reply, &request);
        try std.testing.expect(std.mem.startsWith(u8, reply.header[0..reply.header_length], "HTTP/1.1 503 "));
        try std.testing.expect(std.mem.indexOf(u8, reply.body.json, "dispatch_fenced") != null);
    }
    try std.testing.expectEqual(@as(u64, 0), owner.asks[0].load(.acquire) + owner.asks[1].load(.acquire));
    host_parts.attach(&host, undefined);

    // A named server asks only its own list, and the reply carries the Host instance.
    request.server = .{};
    try request.server.?.set("notes");
    {
        var reply: Reply = .{ .io = io, .allocator = std.testing.allocator };
        defer reply.deinit();
        try replyToolsReload(&host, &reply, &request);
        try std.testing.expect(std.mem.startsWith(u8, reply.header[0..reply.header_length], "HTTP/1.1 200 "));
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"" ++ instance_hex ++ "\",\"asked\":[{\"server\":\"notes\",\"generation\":\"1\"}]}", reply.body.json);
    }
    try std.testing.expectEqual(@as(u64, 0), owner.asks[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), owner.asks[1].load(.acquire));
    try std.testing.expect(host.lifecycle.dispatchWakeIsSet());

    // Without a server name every configured server is asked, in configured order.
    host.lifecycle.resetDispatchWake();
    request.server = null;
    {
        var reply: Reply = .{ .io = io, .allocator = std.testing.allocator };
        defer reply.deinit();
        try replyToolsReload(&host, &reply, &request);
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"" ++ instance_hex ++ "\",\"asked\":[{\"server\":\"docs\",\"generation\":\"1\"},{\"server\":\"notes\",\"generation\":\"2\"}]}", reply.body.json);
    }
    try std.testing.expect(host.lifecycle.dispatchWakeIsSet());

    // The status reply lists every configured server, lock-free, with the same instance.
    {
        var reply: Reply = .{ .io = io, .allocator = std.testing.allocator };
        defer reply.deinit();
        try replyToolsStatus(&host, &reply);
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_status\",\"instance\":\"" ++ instance_hex ++ "\",\"servers\":[{\"server\":\"docs\",\"state\":\"idle\",\"last\":\"never\",\"finished\":\"0\",\"tools\":\"0\",\"left_out\":\"0\",\"listen\":\"off\"},{\"server\":\"notes\",\"state\":\"idle\",\"last\":\"never\",\"finished\":\"0\",\"tools\":\"0\",\"left_out\":\"0\",\"listen\":\"off\"}]}", reply.body.json);
    }

    // A Host with no MCP servers answers empty lists, and an unnamed ask asks nothing.
    var bare = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .instance = @splat(0x7e) };
    var bare_parts: TestParts = undefined;
    bare_parts.attach(&bare, undefined);
    {
        var reply: Reply = .{ .io = io, .allocator = std.testing.allocator };
        defer reply.deinit();
        try replyToolsReload(&bare, &reply, &.{});
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"" ++ instance_hex ++ "\",\"asked\":[]}", reply.body.json);
    }
    {
        var reply: Reply = .{ .io = io, .allocator = std.testing.allocator };
        defer reply.deinit();
        try replyToolsStatus(&bare, &reply);
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_status\",\"instance\":\"" ++ instance_hex ++ "\",\"servers\":[]}", reply.body.json);
    }
    try std.testing.expect(!bare.lifecycle.dispatchWakeIsSet());
}

test "configure parent inherits the Host environment only after a fresh creation" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    try lease.paths.store_identity.set("s");
    var storage: store_module.Store = undefined;
    try store_module.testing.testingSqliteStore(&storage, &tmp, io);
    defer storage.close() catch unreachable;
    var environments: SessionEnvironments = undefined;
    try environments.init(io, allocator);
    defer environments.deinit();
    var host: Host = .{ .io = io, .allocator = allocator, .lease = &lease, .store = &storage, .environments = &environments };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var create = try store_module.testing.completeConfiguration("env-parent", "", root, "model-a");
    create.configuration.tools = try .of(&.{"bash"});
    const parent_reply = try storage.configure(&create, .{});
    const parent = parent_reply.accepted.session;
    var offer = try SessionEnvironments.Offer.init(allocator, 4);
    defer offer.deinit(allocator);
    @memcpy(offer.room(), "A=1\x00");
    environments.offer(parent.slice(), .{ .origin = .person, .admission = 1 }, &offer);
    var child: wire_request.ConfigureCommand = .{};
    try child.key.set("env-child");
    child.configuration = (try store_module.testingCompleteConfiguration("unused", "", root, "model-a")).configuration;
    child.configuration.workspace.state = .omitted;
    child.configuration.provider.state = .omitted;
    child.configuration.tools = try .of(&.{"bash"});
    try child.configuration.permission_mode.value.set("ask");
    child.configuration.parent.state = .value;
    try child.configuration.parent.value.set(parent.slice());
    const result = try submitConfigure(&host, &child, null);
    try std.testing.expect(result == .accepted);
    const session = result.accepted.session;
    const copied = (try environments.copy(session.slice(), allocator)).?;
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("A=1\x00", copied);
    const count = environments.len;
    var newer = try SessionEnvironments.Offer.init(allocator, 4);
    defer newer.deinit(allocator);
    @memcpy(newer.room(), "B=2\x00");
    environments.offer(parent.slice(), .{ .origin = .person, .admission = 2 }, &newer);
    const replay = try submitConfigure(&host, &child, null);
    try std.testing.expect(replay == .accepted and replay.accepted.replayed);
    const retained = (try environments.copy(session.slice(), allocator)).?;
    defer allocator.free(retained);
    try std.testing.expectEqualStrings("A=1\x00", retained);
    try child.key.set("env-child-refused");
    child.configuration.provider.state = .value;
    try child.configuration.provider.value.set("codex");
    const refusal = try submitConfigure(&host, &child, null);
    try std.testing.expect(refusal == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.parent_provider_forbidden, refusal.rejected.code);
    try std.testing.expectEqual(count, environments.len);
}

test "SIGINT, SIGTERM and SIGHUP ask the Host to stop once through intake's loop, in every phase" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store", .{root});
    var wake: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &wake));
    defer for (wake) |fd| {
        _ = std.c.close(fd);
    };
    for (wake) |fd| try setNonblocking(fd);
    StopSignals.attach(wake[1]);
    defer StopSignals.detach();
    inline for (StopSignals.signals) |signal| for (std.enums.values(server_host.Phase)) |before| {
        errdefer std.debug.print("signal {t}, phase before it: {t}\n", .{ signal, before });
        StopSignals.asked.store(false, .release);
        var lease = try platform.StoreLease.acquire(io, path);
        defer lease.release();
        try lease.prepareForServing(false);
        var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = &lease, .store = undefined };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, &lease);
        _ = host.lifecycle.advance(before);
        StopSignals.apply(&host);
        try std.testing.expectEqual(before, host.lifecycle.phase.load(.acquire));
        try std.testing.expectEqual(platform.StoreLease.LastStop.unasked, platform.StoreLease.lastStop(io, path));
        StopSignals.handle(signal);
        var bytes: [8]u8 = undefined;
        try std.testing.expectEqual(@as(isize, 1), std.c.read(wake[0], &bytes, bytes.len));
        try std.testing.expectEqual(before, host.lifecycle.phase.load(.acquire));
        StopSignals.apply(&host);
        try std.testing.expect(host.lifecycle.stopping());
        const recorded: platform.StoreLease.LastStop = if (before != .stopping) .asked else .unasked;
        try std.testing.expectEqual(recorded, platform.StoreLease.lastStop(io, path));
        StopSignals.handle(signal);
        StopSignals.apply(&host);
        try std.testing.expect(host.lifecycle.stopping());
        try std.testing.expectEqual(recorded, platform.StoreLease.lastStop(io, path));
        while (std.c.read(wake[0], &bytes, bytes.len) > 0) {}
    };
}

test "the Host's stop signals reach its handler until serve restores the previous ones" {
    const ignored: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var original: [StopSignals.signals.len]std.posix.Sigaction = undefined;
    inline for (StopSignals.signals, 0..) |signal, i| std.posix.sigaction(signal, &ignored, &original[i]);
    defer inline for (StopSignals.signals, 0..) |signal, i| std.posix.sigaction(signal, &original[i], null);
    var unblocked = std.posix.sigemptyset();
    inline for (StopSignals.signals) |signal| std.posix.sigaddset(&unblocked, signal);
    var previous_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &unblocked, &previous_mask);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
    StopSignals.install();
    inline for (StopSignals.signals) |signal| {
        try std.testing.expect(!StopSignals.asked.load(.acquire));
        try std.posix.raise(signal);
        try std.testing.expect(StopSignals.asked.swap(false, .acq_rel));
    }
    StopSignals.restore();
    inline for (StopSignals.signals) |signal| {
        try std.posix.raise(signal);
        try std.testing.expect(!StopSignals.asked.load(.acquire));
    }
}

test "a stop signal handler racing detach never writes to the closed or a reused wake socket" {
    // Rounds never wait for a hammer to be scheduled: those waits made the
    // test's length the scheduler's, past its timeout on two starved cores
    // (#1943). Scheduling now sets only how often a hammer lands in a round's
    // window; a detach that does not wait still fails here run after run.
    const Hammer = struct {
        stop: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                StopSignals.handle(std.posix.SIG.INT);
                std.Thread.yield() catch {};
            }
        }
    };
    var hammers: [3]Hammer = @splat(.{});
    var threads: [hammers.len]std.Thread = undefined;
    for (&hammers, &threads) |*hammer, *thread| thread.* = try std.Thread.spawn(.{}, Hammer.run, .{hammer});
    defer {
        for (&hammers) |*hammer| hammer.stop.store(true, .release);
        for (threads) |thread| thread.join();
        StopSignals.asked.store(false, .seq_cst);
    }
    var bytes: [256]u8 = undefined;
    for (0..20000) |round| {
        errdefer std.debug.print("round {d}\n", .{round});
        var wake: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &wake));
        for (wake) |fd| try setNonblocking(fd);
        StopSignals.attach(wake[1]);
        StopSignals.detach();
        _ = std.c.close(wake[0]);
        _ = std.c.close(wake[1]);
        var reused: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &reused));
        defer for (reused) |fd| {
            _ = std.c.close(fd);
        };
        for (reused) |fd| try setNonblocking(fd);
        for (reused) |fd| try std.testing.expect(std.c.read(fd, &bytes, bytes.len) < 0);
    }
}

// Captured against 5472ccf5 before the decoder refactor. This oracle checks
// exact producer bytes and complete typed outcomes for matching/mismatched
// bindings. ReplyDomainWitness independently freezes individual field edits.
const MutationWitness = struct {
    const reply = @import("protocol_reply.zig");
    const session = "k7m2qx";
    const content: store_module.ContentReference = .{ .length = 9, .digest = .{ 0xc8, 0x84, 0x92, 0x9e, 0xdd, 0xc9, 0x45, 0x02, 0xb8, 0x37, 0x7e, 0x33, 0x3d, 0xcd, 0x72, 0x80, 0x64, 0xdc, 0xb2, 0xc4, 0x57, 0xe1, 0x0c, 0x4a, 0x3c, 0xc9, 0x82, 0xde, 0xde, 0xfd, 0xcb, 0xcd } };
    const Hash = std.crypto.hash.sha2.Sha256;
    const frozen_wire_version = "20";

    fn named() protocol.Bounded(protocol.max_session_bytes) {
        var value: protocol.Bounded(protocol.max_session_bytes) = .{};
        value.set(session) catch unreachable;
        return value;
    }

    fn subject(comptime kind: command_spec.CommandKind) @typeInfo(@TypeOf(host_reply.renderMutationReply(kind))).@"fn".param_types[1].? {
        return switch (kind) {
            .model_interruption => .{ .session = named(), .turn_id = 3, .operation_id = 11 },
            .permission_decision => .{ .session = named(), .action_id = 7, .decision = .deny },
            .action_background, .action_stop => .{ .session = named(), .action_id = 7 },
            else => session,
        };
    }

    fn target(comptime kind: command_spec.CommandKind, wrong: bool) reply.MutationTarget {
        return switch (kind) {
            .configure => if (wrong) .session_stop else .configure,
            .message => .{ .message = .{ .bytes = content.length + @intFromBool(wrong), .digest = content.digest } },
            .session_stop => if (wrong) .configure else .session_stop,
            .session_archive => .{ .session_archive = .{ .archived = !wrong } },
            .session_pin => .{ .session_pin = .{ .pinned = wrong } },
            .model_interruption => .{ .model_interruption = .{ .turn = 3, .operation = if (wrong) 12 else 11 } },
            .permission_decision => .{ .permission_decision = .{ .action = 7, .decision = if (wrong) .allow_once else .deny } },
            .action_background => .{ .action_background = if (wrong) 8 else 7 },
            .action_stop => .{ .action_stop = if (wrong) 8 else 7 },
        };
    }

    fn accepted(comptime kind: command_spec.CommandKind) @typeInfo(@TypeOf(host_reply.renderMutationReply(kind))).@"fn".param_types[2].? {
        return .{ .accepted = switch (kind) {
            .configure => .{ .replayed = false, .revision = 13, .created = false, .session = named() },
            .message => .{ .replayed = false, .admission_id = 17, .content = .{ .text = content }, .session = named() },
            .session_stop => .{ .replayed = false, .selection = .{ .selected_turn_id = 19, .admission_cutoff = 23 }, .completion = .pending },
            .session_archive => .{ .replayed = false, .archived = true, .completion = .pending },
            .session_pin => .{ .replayed = false, .pinned = false },
            .model_interruption, .permission_decision => .{ .replayed = false },
            .action_background => .{ .replayed = false, .action_id = 7, .selection = .{ .kind = .background, .position = 29 } },
            .action_stop => .{ .replayed = false, .action_id = 7, .resolution = 29 },
        } };
    }

    fn requireFields(comptime T: type, comptime expected: []const []const u8) void {
        const actual_fields = @typeInfo(T).@"struct".field_names;
        if (actual_fields.len != expected.len) @compileError("Mutation witness field inventory changed: " ++ @typeName(T));
        for (actual_fields, expected) |field, name| {
            if (!std.mem.eql(u8, field, name)) @compileError("Mutation witness field inventory changed: " ++ @typeName(T));
        }
    }

    // The frozen producer-byte oracle was captured at the released wire version. Verify the
    // actual version first, then retain those captured bytes in the digest.
    fn hashResponse(hash: *Hash, body: []const u8) !void {
        const current = "{\"version\":\"" ++ protocol.wire_version ++ "\",";
        try std.testing.expect(std.mem.startsWith(u8, body, current));
        hash.update("{\"version\":\"" ++ frozen_wire_version ++ "\",");
        hash.update(body[current.len..]);
    }

    fn observe(hash: *Hash, body: []const u8, status: u16, supplied_session: []const u8, binding: reply.MutationTarget) !void {
        const decoded = reply.decodeMutationReply(.{ .status = status, .body = body }, supplied_session, binding);
        if (decoded.answer) |answer| {
            hash.update(@tagName(answer.result));
            hash.update(&.{@intFromBool(answer.replayed)});
            switch (answer.result) {
                .accepted => |value| {
                    // Preserve the frozen pre-receipt projection for existing
                    // replies. Hash receipt slices explicitly: Bounded backing
                    // arrays contain unused bytes and are not stable witnesses.
                    const OldConfigure = union(enum) { configure: struct { revision: u64, created: bool, skills: ?@import("mutation_answer.zig").SkillsReloadStatus } };
                    const OldMessage = union(enum) { message: struct { admission: u64 } };
                    const bytes = switch (value) {
                        .configure => |item| blk: {
                            comptime requireFields(@TypeOf(item), &.{ "revision", "created", "skills", "configuration" });
                            break :blk try std.json.Stringify.valueAlloc(std.testing.allocator, OldConfigure{ .configure = .{ .revision = item.revision, .created = item.created, .skills = item.skills } }, .{});
                        },
                        .message => |item| blk: {
                            comptime requireFields(@TypeOf(item), &.{ "admission", "configuration" });
                            break :blk try std.json.Stringify.valueAlloc(std.testing.allocator, OldMessage{ .message = .{ .admission = item.admission } }, .{});
                        },
                        else => try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{}),
                    };
                    defer std.testing.allocator.free(bytes);
                    hash.update(bytes);
                    const configuration = switch (value) {
                        .configure => |item| item.configuration,
                        .message => |item| item.configuration,
                        else => null,
                    };
                    if (configuration) |item| {
                        comptime requireFields(@TypeOf(item), &.{ "provider", "model", "reasoning_effort", "workspace", "tools", "loaded_tools", "permission_mode", "compaction_trigger" });
                        const receipt = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
                            .provider = item.provider,
                            .model = item.model.slice(),
                            .reasoning_effort = item.reasoning_effort,
                            .workspace = item.workspace.slice(),
                            .tools = item.tools.slice(),
                            .loaded_tools = item.loaded_tools.slice(),
                            .permission_mode = item.permission_mode,
                            .compaction_trigger = item.compaction_trigger,
                        }, .{});
                        defer std.testing.allocator.free(receipt);
                        hash.update(receipt);
                    }
                },
                .rejected => |code| hash.update(code.slice()),
                .conflict => {},
            }
            // The frozen witness hashes the original text receipt fields.
            const receipt: ?@import("mutation_answer.zig").ContentReference = if (answer.input) |value| switch (value) {
                .accepted => |accepted_input| blk: {
                    try std.testing.expect(accepted_input == .text);
                    break :blk .{ .bytes = accepted_input.text.length, .digest = accepted_input.text.digest };
                },
                .rejected => |rejected_input| blk: {
                    try std.testing.expectEqual(.text, rejected_input.form);
                    break :blk rejected_input.content;
                },
            } else null;
            const input = try std.json.Stringify.valueAlloc(std.testing.allocator, receipt, .{});
            defer std.testing.allocator.free(input);
            hash.update(input);
        } else |err| hash.update(@errorName(err));
        hash.update("\x00");
        hash.update(decoded.context.session.slice());
        hash.update("\x00");
        if (decoded.diagnostic) |diagnostic| {
            hash.update(diagnostic.type.slice());
            hash.update(diagnostic.code.slice());
        }
        hash.update("\x00");
    }

    const Field = struct { path: []const []const u8, value: []const u8 };
    const fields = [_]Field{
        .{ .path = &.{"version"}, .value = "\"" ++ protocol.wire_version ++ "\"" },
        .{ .path = &.{"type"}, .value = "\"session_pin_reply\"" },
        .{ .path = &.{"code"}, .value = "\"canonical_store_failure\"" },
        .{ .path = &.{"answer"}, .value = "{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\"}" },
        .{ .path = &.{"input"}, .value = "{\"type\":\"text\",\"bytes\":\"9\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}" },
        .{ .path = &.{"queue"}, .value = "{\"status\":\"queued\",\"admission\":\"17\"}" },
        .{ .path = &.{"execution"}, .value = "{\"status\":\"queued\"}" },
        .{ .path = &.{"completion"}, .value = "{\"status\":\"pending\"}" },
        .{ .path = &.{ "answer", "status" }, .value = "\"accepted\"" },
        .{ .path = &.{ "answer", "replayed" }, .value = "true" },
        .{ .path = &.{ "answer", "session" }, .value = "\"k7m2qx\"" },
        .{ .path = &.{ "answer", "code" }, .value = "\"unknown_session\"" },
        .{ .path = &.{ "answer", "message" }, .value = "\"detail\"" },
        .{ .path = &.{ "answer", "revision" }, .value = "\"13\"" },
        .{ .path = &.{ "answer", "created" }, .value = "false" },
        .{ .path = &.{ "answer", "skills" }, .value = "\"unchanged\"" },
        .{ .path = &.{ "answer", "admission" }, .value = "\"17\"" },
        .{ .path = &.{ "answer", "archived" }, .value = "true" },
        .{ .path = &.{ "answer", "pinned" }, .value = "false" },
        .{ .path = &.{ "answer", "action" }, .value = "\"7\"" },
        .{ .path = &.{ "answer", "decision" }, .value = "\"deny\"" },
        .{ .path = &.{ "answer", "selection" }, .value = "{\"turn\":\"19\",\"admission_cutoff\":\"23\"}" },
        .{ .path = &.{ "answer", "action_selection" }, .value = "{\"kind\":\"background\",\"position\":\"29\"}" },
        .{ .path = &.{ "answer", "target" }, .value = "{\"session\":\"k7m2qx\",\"turn\":\"3\",\"operation\":\"11\"}" },
        .{ .path = &.{ "input", "type" }, .value = "\"text\"" },
        .{ .path = &.{ "input", "bytes" }, .value = "\"9\"" },
        .{ .path = &.{ "input", "sha256" }, .value = "\"0000000000000000000000000000000000000000000000000000000000000000\"" },
        .{ .path = &.{ "queue", "status" }, .value = "\"queued\"" },
        .{ .path = &.{ "queue", "admission" }, .value = "\"17\"" },
        .{ .path = &.{ "execution", "status" }, .value = "\"unavailable\"" },
        .{ .path = &.{ "execution", "reason" }, .value = "\"direct_reply_does_not_wait_for_model_processing\"" },
        .{ .path = &.{ "completion", "status" }, .value = "\"completed\"" },
        .{ .path = &.{ "answer", "selection", "turn" }, .value = "null" },
        .{ .path = &.{ "answer", "selection", "admission_cutoff" }, .value = "\"23\"" },
        .{ .path = &.{ "answer", "target", "session" }, .value = "\"k7m2qx\"" },
        .{ .path = &.{ "answer", "target", "turn" }, .value = "\"3\"" },
        .{ .path = &.{ "answer", "target", "operation" }, .value = "\"11\"" },
        .{ .path = &.{ "answer", "action_selection", "kind" }, .value = "\"final\"" },
        .{ .path = &.{ "answer", "action_selection", "position" }, .value = "\"29\"" },
    };
};

test "mutation decoder preserves base bytes and the entire command domain" {
    // Only the version is normalized; an incorrect actual version is refused.
    var version_probe = MutationWitness.Hash.init(.{});
    try std.testing.expectError(error.TestUnexpectedResult, MutationWitness.hashResponse(&version_probe, "{\"version\":\"" ++ protocol.next_wire_version ++ "\",\"type\":\"configuration_reply\"}"));
    try MutationWitness.hashResponse(&version_probe, "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"configuration_reply\"}");
    var frozen_probe = MutationWitness.Hash.init(.{});
    frozen_probe.update("{\"version\":\"" ++ MutationWitness.frozen_wire_version ++ "\",\"type\":\"configuration_reply\"}");
    try std.testing.expectEqualSlices(u8, &frozen_probe.finalResult(), &version_probe.finalResult());
    var covered: u16 = 0;
    inline for (comptime std.meta.tags(command_spec.CommandKind)) |kind| {
        if (comptime kind == .action_stop) continue;
        covered |= @as(u16, 1) << @backingInt(kind);
        const render = host_reply.renderMutationReply(kind);
        const Result = @typeInfo(@TypeOf(render)).@"fn".param_types[2].?;
        const accepted = MutationWitness.accepted(kind);
        const rejected: Result = if (kind == .message)
            .{ .rejected = .{ .replayed = false, .code = .unknown_session, .content = MutationWitness.content } }
        else
            .{ .rejected = .{ .replayed = false, .code = .invalid_session_reference } };
        var hash = MutationWitness.Hash.init(.{});
        for ([_]Result{ accepted, rejected, .conflict, .infrastructure_failure }) |initial| {
            for ([_]bool{ false, true }) |replayed| {
                var result = initial;
                switch (result) {
                    .accepted => |*value| value.replayed = replayed,
                    .rejected => |*value| value.replayed = replayed,
                    else => {},
                }
                var response: protocol.ResponseBuffer = .{};
                try response.render(render, .{ MutationWitness.subject(kind), result });
                const status: u16 = switch (result) {
                    .accepted, .rejected => 200,
                    .conflict => 409,
                    .infrastructure_failure => 500,
                };
                try MutationWitness.hashResponse(&hash, response.slice());
                hash.update("\x00");
                for ([_]bool{ false, true }) |wrong_session| {
                    for ([_]bool{ false, true }) |wrong_target| {
                        try MutationWitness.observe(&hash, response.slice(), status, if (wrong_session) "p9q8rs" else MutationWitness.session, MutationWitness.target(kind, wrong_target));
                    }
                }
            }
        }
        // Other renderer branches: skills reload, idle stop, restored/unpinned
        // intent, final Action selection, and initial Session allocation.
        var alternate = accepted;
        switch (kind) {
            .configure => alternate.accepted.skills = .unchanged,
            .session_stop => {
                alternate.accepted.selection.selected_turn_id = null;
                alternate.accepted.completion = .completed;
            },
            .session_archive => alternate.accepted.archived = false,
            .session_pin => alternate.accepted.pinned = true,
            .action_background => alternate.accepted.selection.kind = .final,
            .action_stop => alternate.accepted.resolution = null,
            else => {},
        }
        var response: protocol.ResponseBuffer = .{};
        try response.render(render, .{ MutationWitness.subject(kind), alternate });
        try MutationWitness.hashResponse(&hash, response.slice());
        var binding = MutationWitness.target(kind, false);
        if (kind == .session_archive) binding.session_archive.archived = false;
        if (kind == .session_pin) binding.session_pin.pinned = true;
        try MutationWitness.observe(&hash, response.slice(), 200, MutationWitness.session, binding);
        if (kind == .configure or kind == .message) {
            var initial = accepted;
            if (kind == .configure) initial.accepted.created = true;
            if (kind == .message) binding.message.creates_session = true;
            response = .{};
            try response.render(render, .{ @as([]const u8, ""), initial });
            try std.testing.expectError(error.InvalidResponse, MutationWitness.reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", binding).answer);
            try MutationWitness.hashResponse(&hash, response.slice());
            try MutationWitness.observe(&hash, response.slice(), 200, "", binding);
            // Creation now requires a resolved receipt. Keep the legacy missing
            // receipt probe above and witness a valid creation independently.
            var configuration: @import("creation_receipt.zig").Configuration = .{
                .provider = .openai,
                .model = .{},
                .reasoning_effort = .low,
                .workspace = .{},
                .tools = .{},
                .loaded_tools = .{},
                .permission_mode = .ask,
                .compaction_trigger = 115200,
            };
            try configuration.model.set("gpt-6.1-sol");
            try configuration.workspace.set("/workspace");
            try configuration.tools.set("bash");
            try configuration.loaded_tools.set("bash");
            initial.accepted.configuration = &configuration;
            response = .{};
            try response.render(render, .{ @as([]const u8, ""), initial });
            const config_json = ",\"configuration\":{\"provider\":\"openai\",\"model\":\"gpt-6.1-sol\",\"reasoning_effort\":\"low\",\"workspace\":\"/workspace\",\"tools\":[\"bash\"],\"loaded_tools\":[\"bash\"],\"permission_mode\":\"ask\",\"compaction_trigger\":\"115200\"}";
            const expected_creation = if (kind == .configure)
                "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"configuration_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"revision\":\"13\",\"created\":true" ++ config_json ++ "},\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"}}"
            else
                "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"admission\":\"17\"" ++ config_json ++ "},\"input\":{\"type\":\"text\",\"bytes\":\"9\",\"sha256\":\"c884929eddc94502b8377e333dcd728064dcb2c457e10c4a3cc982dedefdcbcd\"},\"queue\":{\"status\":\"queued\",\"admission\":\"17\"},\"execution\":{\"status\":\"queued\"}}";
            try std.testing.expectEqualStrings(expected_creation, response.slice());
            const creation = try MutationWitness.reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "", binding).answer;
            const resolved = if (kind == .configure) creation.result.accepted.configure.configuration.? else creation.result.accepted.message.configuration.?;
            try std.testing.expectEqualStrings("gpt-6.1-sol", resolved.model.slice());
            try std.testing.expectEqualStrings("/workspace", resolved.workspace.slice());
            try std.testing.expectEqual(protocol.ReasoningEffort.low, resolved.reasoning_effort.?);
            try MutationWitness.hashResponse(&hash, response.slice());
            try MutationWitness.observe(&hash, response.slice(), 200, "", binding);
        }
        const expected = switch (kind) {
            .action_stop => continue,
            .configure => "b501240e06ee15fe16fae07682f8a4897ecd3d7e33aa3e89b2ef46d717957a88",
            .message => "797f0ff670112ac114ab31b9cc7fd07c953a6eb68edc921f2bee955895ce8204",
            .session_stop => "a98107ee7efe29d5c2480097568daa514649c76e9c7c1cc740ed5fbc697cbc90",
            .session_archive => "91da63974ced68e1596b479409b543ae90ec8161c1612840b3e26a0eca02acb3",
            .model_interruption => "54ed6236f058bb77a9b8039bb9a2bc144a5066bf742084c9ceb7ff7e73f890e1",
            .permission_decision => "f66bb4623f2b0d67ae3ddafb8ead166b83daf53877ab965918108eceac49a3e8",
            .session_pin => "aa74b927c4314f8576e070e3c2cff253fa4c6aeb1de6a93410f535fd255d1230",
            .action_background => "36da16c3d5ecd7bb88bdb3612c921f3dfc3eb2114fa974f9274e957356061b7f",
        };
        const actual = std.fmt.bytesToHex(hash.finalResult(), .lower);
        std.testing.expectEqualStrings(expected, &actual) catch |err| {
            std.debug.print("base mutation witness changed for {s}\n", .{@tagName(kind)});
            return err;
        };
    }
    try std.testing.expectEqual(@as(u16, 0xff), covered);
}
test "every accepted control publishes exactly one hint before reply handling" {
    const native = @import("posix");
    const Probe = struct {
        host: *Host,
        observation: *TestObservation,
        accepted: bool,
        allocations: usize = 0,
        ordered: bool = true,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }

        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.allocations += 1;
            self.ordered = self.ordered and self.host.lifecycle.controlsChangedPending() == self.accepted and
                self.observation.shared.state.load(.acquire) == @as(u64, if (self.accepted) 2 else 0);
            return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            return std.testing.allocator.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            return std.testing.allocator.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ret_addr);
        }
    };
    var covered: std.EnumSet(command_spec.CommandKind) = .empty;
    inline for (comptime std.meta.tags(command_spec.CommandKind)) |kind| {
        if (comptime !command_spec.spec(kind).is_control) continue;
        covered.insert(kind);
        const Result = host_reply.MutationResult(kind);
        const rejected: Result = .{ .rejected = .{ .replayed = false, .code = .invalid_session_reference } };
        for ([_]Result{ MutationWitness.accepted(kind), rejected, .conflict, .infrastructure_failure }) |initial| {
            for ([_]bool{ false, true }) |replayed| {
                for ([_]bool{ false, true }) |drop| {
                    var descriptors: [2]c_int = undefined;
                    try std.testing.expectEqual(@as(c_int, 0), native.pipe(&descriptors));
                    defer _ = native.close(descriptors[0]);
                    for (descriptors) |fd| try std.testing.expectEqual(@as(c_int, 0), native.fcntl(fd, native.F_SETFL, @as(c_int, native.O_NONBLOCK)));
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
                    };
                    var host_parts: TestParts = undefined;
                    host_parts.attach(&host, undefined);
                    host_parts.probes.hooks = .{ .phase_trace = true };
                    host_parts.probes.observation = observation;
                    var result = initial;
                    switch (result) {
                        .accepted => |*value| value.replayed = replayed,
                        .rejected => |*value| value.replayed = replayed,
                        else => {},
                    }
                    const accepted = result == .accepted;
                    var probe: Probe = .{ .host = &host, .observation = &observation, .accepted = accepted };
                    var reply = Reply{ .io = std.testing.io, .allocator = probe.allocator() };
                    defer reply.deinit();
                    const key = try protocol.Bounded(protocol.max_key_bytes).from("control-domain");
                    const timing = ControlTiming.init(&host, key, @tagName(kind), 1);
                    const header = Header{ .route = @field(Route, @tagName(kind)), .content_length = 0, .drop = if (drop) .after_commit else .none };
                    try answerControl(&host, &reply, header, kind, MutationWitness.subject(kind), result, timing);
                    try std.testing.expectEqual(accepted, host.lifecycle.controlsChangedPending());
                    try std.testing.expectEqual(@as(u64, if (accepted) 2 else 0), observation.shared.state.load(.acquire));
                    try std.testing.expect(probe.ordered);
                    const dropped = drop and result != .infrastructure_failure;
                    try std.testing.expectEqual(dropped, reply.body == .none);
                    try std.testing.expectEqual(!dropped, reply.timing != null);
                    try std.testing.expectEqual(!dropped, probe.allocations != 0);
                    try std.testing.expectEqual(result != .infrastructure_failure, host.lifecycle.launchAllowed());
                    var bytes: [TestObservation.record_bytes]u8 = undefined;
                    const count = native.read(descriptors[0], &bytes, bytes.len);
                    if (accepted) {
                        try std.testing.expect(count > 0);
                        try std.testing.expect(std.mem.indexOf(u8, bytes[0..@intCast(count)], "control_hint_published") != null);
                        try std.testing.expect(std.mem.indexOf(u8, bytes[0..@intCast(count)], key.slice()) != null);
                    } else try std.testing.expect(count < 0 and std.posix.errno(count) == .AGAIN);
                }
            }
        }
    }
    const expected: std.EnumSet(command_spec.CommandKind) = .initMany(&.{
        .session_stop, .session_archive,   .model_interruption, .permission_decision,
        .session_pin,  .action_background, .action_stop,
    });
    try std.testing.expectEqual(expected, covered);
}

// Each symbol below is captured by the old decoders at 5472ccf5, independently
// of command_spec's field tables. Keep the baseline artifact frozen; accepted
// behavior changes are explicit exceptions in the comparison below.
// Rows: label, then unedited outcome and set/remove/null for each listed field.
// a/A = accepted, r/R = rejected (uppercase = replayed), c = conflict,
// f = CanonicalStoreFailure, h = HostInvocationFailed, i = InvalidResponse,
// o = InvalidObservation, b = RequestBindingMismatch, x = absent.
// Captured with: zb zig build -j1 test -Dtest-filter="reply decoder frozen field domain"
// in an isolated git archive of 5472ccf5; 102 rows cover 11,856 outcomes.
const ReplyDomainWitness = struct {
    const reply = @import("protocol_reply.zig");
    const fixture = @embedFile("fixtures/command-reply-domain.txt");
    const Field = MutationWitness.Field;
    const observation_fields = [_]Field{
        .{ .path = &.{"version"}, .value = "\"" ++ protocol.wire_version ++ "\"" },
        .{ .path = &.{"type"}, .value = "\"command_observation\"" },
        .{ .path = &.{"key"}, .value = "\"k\"" },
        .{ .path = &.{"delta"}, .value = "\"full\"" },
        .{ .path = &.{"since"}, .value = "null" },
        .{ .path = &.{"observation"}, .value = "{\"status\":\"absent\"}" },
        .{ .path = &.{ "observation", "status" }, .value = "\"accepted\"" },
        .{ .path = &.{ "observation", "kind" }, .value = "\"configure\"" },
        .{ .path = &.{ "observation", "target" }, .value = "\"k7m2qx\"" },
        .{ .path = &.{ "observation", "code" }, .value = "\"unknown_session\"" },
        .{ .path = &.{ "observation", "revision" }, .value = "\"31\"" },
        .{ .path = &.{ "observation", "created" }, .value = "true" },
        .{ .path = &.{ "observation", "input" }, .value = "{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"}" },
        .{ .path = &.{ "observation", "state" }, .value = "\"queued\"" },
        .{ .path = &.{ "observation", "queue" }, .value = "{\"admission\":\"23\",\"admitted_at\":\"1762329000\"}" },
        .{ .path = &.{ "observation", "binding" }, .value = "{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"}" },
        .{ .path = &.{ "observation", "result" }, .value = "{\"status\":\"cancelled\",\"code\":\"cancelled\"}" },
        .{ .path = &.{ "observation", "work" }, .value = "{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null}" },
        .{ .path = &.{ "observation", "recovery" }, .value = "{\"unknown_outcomes\":[],\"more\":false}" },
        .{ .path = &.{ "observation", "selection" }, .value = "{\"turn\":null,\"admission_cutoff\":\"0\"}" },
        .{ .path = &.{ "observation", "archived" }, .value = "false" },
        .{ .path = &.{ "observation", "pinned" }, .value = "false" },
        .{ .path = &.{ "observation", "completion" }, .value = "{\"status\":\"completed\"}" },
        .{ .path = &.{ "observation", "interruption_target" }, .value = "{\"session\":\"k7m2qx\",\"turn\":\"3\",\"operation\":\"7\"}" },
        .{ .path = &.{ "observation", "permission_target" }, .value = "{\"action\":\"29\",\"decision\":\"allow_once\"}" },
        .{ .path = &.{ "observation", "action_target" }, .value = "{\"action\":\"29\"}" },
        .{ .path = &.{ "observation", "action_selection" }, .value = "{\"kind\":\"background\",\"position\":\"31\"}" },
    };

    const message_fields = observation_fields ++ [_]Field{
        .{ .path = &.{ "observation", "work", "state" }, .value = "{\"kind\":\"approval\",\"since\":\"1762329010\"}" },
        .{ .path = &.{ "observation", "work", "state", "kind" }, .value = "\"approval\"" },
        .{ .path = &.{ "observation", "work", "state", "since" }, .value = "\"1762329010\"" },
        .{ .path = &.{ "observation", "work", "state", "call" }, .value = "\"0\"" },
        .{ .path = &.{ "observation", "work", "state", "description" }, .value = "\"Run tests\"" },
        .{ .path = &.{ "observation", "work", "state", "running" }, .value = "\"1\"" },
        .{ .path = &.{ "observation", "work", "state", "approvals" }, .value = "\"1\"" },
        .{ .path = &.{ "observation", "work", "state", "future" }, .value = "{\"items\":[true,null,17]}" },
        .{ .path = &.{ "observation", "work", "first_action" }, .value = "\"57\"" },
        .{ .path = &.{ "observation", "work", "future" }, .value = "{\"items\":[true,null,17]}" },
        .{ .path = &.{ "observation", "recovery", "unknown_outcomes" }, .value = "[{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"}]" },
        .{ .path = &.{ "observation", "recovery", "more" }, .value = "true" },
        .{ .path = &.{ "observation", "binding", "turn" }, .value = "\"37\"" },
        .{ .path = &.{ "observation", "binding", "operation" }, .value = "\"41\"" },
        .{ .path = &.{ "observation", "binding", "attempt" }, .value = "\"0\"" },
        .{ .path = &.{ "observation", "result", "status" }, .value = "\"cancelled\"" },
        .{ .path = &.{ "observation", "result", "code" }, .value = "\"cancelled\"" },
        .{ .path = &.{ "observation", "result", "text" }, .value = "{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}" },
    };
    const message_edges = [_]struct { name: []const u8, fields: []const u8 }{
        .{ .name = "waiting-bound", .fields = ",\"state\":\"waiting_for_permission\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":\"57\"}" },
        .{ .name = "waiting-unbound", .fields = ",\"state\":\"waiting_for_permission\",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":\"57\"}" },
        .{ .name = "waiting-wrong-work", .fields = ",\"state\":\"waiting_for_permission\",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":\"57\"}" },
        .{ .name = "waiting-no-action", .fields = ",\"state\":\"waiting_for_permission\",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":null}" },
        .{ .name = "queued-approval", .fields = ",\"state\":\"queued\",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":\"57\"}" },
        .{ .name = "processing-approval", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"1762329010\"},\"first_action\":\"57\"}" },
        .{ .name = "processing-bash", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"bash\",\"since\":\"1762329010\",\"call\":\"0\",\"description\":\"Run tests\",\"running\":\"1\",\"approvals\":\"1\"},\"first_action\":\"57\"}" },
        .{ .name = "queued-bash", .fields = ",\"state\":\"queued\",\"work\":{\"state\":{\"kind\":\"bash\",\"since\":\"1762329010\",\"call\":\"0\",\"description\":\"Run tests\",\"running\":\"1\",\"approvals\":\"0\"},\"first_action\":null}" },
        .{ .name = "processing-working", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null}" },
        .{ .name = "queued-pending", .fields = ",\"state\":\"queued\",\"work\":{\"state\":{\"kind\":\"pending\",\"since\":\"1762329010\"},\"first_action\":null}" },
        .{ .name = "processing-unknown-state-field", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\",\"future\":{\"numbers\":[true,null,17]}},\"first_action\":null}" },
        .{ .name = "processing-unknown-work-field", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null,\"future\":{\"values\":[1,null,false]}}" },
        .{ .name = "processing-bad-bash", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"bash\",\"since\":\"1762329010\",\"call\":\"0\",\"description\":\"Run tests\",\"running\":\"0\",\"approvals\":\"1\"},\"first_action\":null}" },
        .{ .name = "processing-recovery", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null},\"recovery\":{\"unknown_outcomes\":[{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"}],\"more\":false}" },
        .{ .name = "completed-recovery", .fields = ",\"state\":\"completed\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"result\":{\"status\":\"completed\",\"text\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}},\"recovery\":{\"unknown_outcomes\":[{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"}],\"more\":false}" },
        .{ .name = "failed", .fields = ",\"state\":\"failed\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"}" },
        .{ .name = "cancelled-unbound", .fields = ",\"state\":\"cancelled\",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}" },
        .{ .name = "empty-recovery", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null},\"recovery\":{\"unknown_outcomes\":[],\"more\":false}" },
        .{ .name = "short-more-recovery", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null},\"recovery\":{\"unknown_outcomes\":[{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"}],\"more\":true}" },
        .{ .name = "duplicate-recovery", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null},\"recovery\":{\"unknown_outcomes\":[{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"},{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"}],\"more\":false}" },
        .{ .name = "unbound-recovery", .fields = ",\"state\":\"queued\",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null},\"recovery\":{\"unknown_outcomes\":[{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"}],\"more\":false}" },
        .{ .name = "full-recovery", .fields = ",\"state\":\"processing\",\"binding\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null},\"recovery\":{\"unknown_outcomes\":[{\"action\":\"57\",\"operation\":\"39\",\"call\":\"0\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"},{\"action\":\"56\",\"operation\":\"39\",\"call\":\"1\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"},{\"action\":\"55\",\"operation\":\"39\",\"call\":\"2\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"},{\"action\":\"54\",\"operation\":\"39\",\"call\":\"3\",\"description\":\"Run \\\"tests\\\"\",\"at\":\"1762329020\"}],\"more\":true}" },
    };

    fn failure(err: anyerror) u8 {
        return switch (err) {
            error.InvalidResponse => 'i',
            error.InvalidObservation => 'o',
            error.RequestBindingMismatch => 'b',
            error.CanonicalStoreFailure => 'f',
            error.HostInvocationFailed => 'h',
            else => std.debug.panic("unrecorded domain error: {s}", .{@errorName(err)}),
        };
    }

    fn mutation(body: []const u8, status: u16, binding: reply.MutationTarget) u8 {
        const decoded = reply.decodeMutationReply(.{ .status = status, .body = body }, MutationWitness.session, binding);
        const answer = decoded.answer catch |err| return failure(err);
        return switch (answer.result) {
            .accepted => if (answer.replayed) 'A' else 'a',
            .rejected => if (answer.replayed) 'R' else 'r',
            .conflict => 'c',
        };
    }

    fn observation(body: []const u8) u8 {
        const observed = reply.CommandObservation.parse(.{ .status = 200, .body = body }, "k") catch |err| return failure(err);
        return switch (observed.status) {
            .accepted => 'a',
            .rejected => 'r',
            .absent => 'x',
        };
    }

    fn editField(parsed: *std.json.Parsed(std.json.Value), field: Field, edit: usize) ![]const u8 {
        const allocator = parsed.arena.allocator();
        var object = &parsed.value;
        for (field.path[0 .. field.path.len - 1]) |part| {
            if (object.object.getPtr(part) == null) try object.object.put(allocator, part, .{ .object = .empty });
            object = object.object.getPtr(part).?;
            if (object.* != .object) object.* = .{ .object = .empty };
        }
        const name = field.path[field.path.len - 1];
        switch (edit) {
            0 => {
                const value = try std.json.parseFromSlice(std.json.Value, allocator, field.value, .{ .allocate = .alloc_always });
                try object.object.put(allocator, name, value.value);
            },
            1 => _ = object.object.orderedRemove(name),
            2 => try object.object.put(allocator, name, .null),
            else => unreachable,
        }
        return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    }

    fn legacyWork(body: []const u8) !bool {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const observed = parsed.value.object.get("observation") orelse return false;
        if (observed != .object) return false;
        const work = observed.object.get("work") orelse return false;
        if (work != .object) return false;
        return !work.object.contains("attention") or !work.object.contains("group") or !work.object.contains("actions");
    }

    noinline fn check(lines: *std.mem.SplitIterator(u8, .scalar), label: []const u8, actual: []const u8, fields: []const Field, tighten_pinned: bool, legacy_work: ?[]const bool) !void {
        const line = lines.next() orelse return error.MissingDomainBaseline;
        const split = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidDomainBaseline;
        try std.testing.expectEqualStrings(label, line[0..split]);
        const expected = line[split + 1 ..];
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual, 0..) |base, got, index| {
            const field = if (index == 0) null else fields[(index - 1) / 3];
            const edit = if (index == 0) 0 else (index - 1) % 3;
            // Slice 3 intentionally closes the old session_pin rejection/conflict
            // hole: a present pinned value is accepted-only, even for its owner.
            // An old successful or binding-mismatch Message work reply now needs
            // the three required Host-derived members before it can be decoded.
            const missing_work = if (legacy_work) |missing| missing[index] else false;
            // Adding an input receipt to a rejected Message observation now invalidates the reply.
            const rejected_message_input = std.mem.eql(u8, label, "observation/message/rejected") and edit == 0 and
                field != null and field.?.path.len == 2 and std.mem.eql(u8, field.?.path[0], "observation") and
                std.mem.eql(u8, field.?.path[1], "input");
            if (rejected_message_input) try std.testing.expectEqual(@as(u8, 'r'), base);
            const want: u8 = if (tighten_pinned and field != null and edit == 0 and
                std.mem.eql(u8, field.?.path[field.?.path.len - 1], "pinned")) 'i' else if (rejected_message_input or (missing_work and (base == 'a' or base == 'b'))) 'o' else base;
            if (want != got) {
                std.debug.print("domain {s}: field {any}, edit {s}: base={c}, expected={c}, actual={c}\n", .{
                    label, if (field) |value| value.path else @as([]const []const u8, &.{"<unedited>"}),
                    @as([]const u8, switch (edit) {
                        0 => "set",
                        1 => "remove",
                        2 => "null",
                        else => unreachable,
                    }),
                    base,  want,
                    got,
                });
                return error.ReplyDomainChanged;
            }
        }
    }

    // Keep the runtime edit sweeps out of the per-command inline expansions.
    noinline fn checkMutation(
        lines: *std.mem.SplitIterator(u8, .scalar),
        body: []const u8,
        status: u16,
        binding: reply.MutationTarget,
        command_name: []const u8,
        result_name: []const u8,
        replayed: bool,
        tighten_pinned: bool,
    ) !void {
        var actual: [1 + MutationWitness.fields.len * 3]u8 = undefined;
        actual[0] = mutation(body, status, binding);
        for (MutationWitness.fields, 0..) |field, index| {
            for (0..3) |edit| {
                var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
                defer parsed.deinit();
                actual[1 + index * 3 + edit] = mutation(try editField(&parsed, field, edit), status, binding);
            }
        }
        var label_buffer: [128]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "mutation/{s}/{s}/{d}", .{ command_name, result_name, @intFromBool(replayed) });
        try check(lines, label, &actual, &MutationWitness.fields, tighten_pinned, null);
    }

    noinline fn collectObservationEdits(body: []const u8, fields: []const Field, actual: []u8, legacy: []bool) !void {
        actual[0] = observation(body);
        legacy[0] = try legacyWork(body);
        for (fields, 0..) |field, index| {
            for (0..3) |edit| {
                var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
                defer parsed.deinit();
                const edited = try editField(&parsed, field, edit);
                actual[1 + index * 3 + edit] = observation(edited);
                legacy[1 + index * 3 + edit] = try legacyWork(edited);
            }
        }
    }

    fn run() !void {
        @setEvalBranchQuota(20_000);
        var lines = std.mem.splitScalar(u8, fixture, '\n');
        inline for (comptime std.meta.tags(command_spec.CommandKind)) |kind| {
            if (comptime kind == .action_stop) continue;
            const render = host_reply.renderMutationReply(kind);
            const Result = @typeInfo(@TypeOf(render)).@"fn".param_types[2].?;
            const rejected: Result = if (kind == .message)
                .{ .rejected = .{ .replayed = false, .code = .unknown_session, .content = MutationWitness.content } }
            else
                .{ .rejected = .{ .replayed = false, .code = .invalid_session_reference } };
            for ([_]Result{ MutationWitness.accepted(kind), rejected, .conflict, .infrastructure_failure }) |initial| {
                for ([_]bool{ false, true }) |replayed| {
                    var result = initial;
                    switch (result) {
                        .accepted => |*value| value.replayed = replayed,
                        .rejected => |*value| value.replayed = replayed,
                        else => {},
                    }
                    var response: protocol.ResponseBuffer = .{};
                    try response.render(render, .{ MutationWitness.subject(kind), result });
                    const status: u16 = switch (result) {
                        .accepted, .rejected => 200,
                        .conflict => 409,
                        .infrastructure_failure => 500,
                    };
                    try checkMutation(
                        &lines,
                        response.slice(),
                        status,
                        MutationWitness.target(kind, false),
                        @tagName(kind),
                        @tagName(result),
                        replayed,
                        kind == .session_pin and (result == .rejected or result == .conflict),
                    );
                }
            }
            inline for (.{ false, true }) |accepted| {
                const fields = if (accepted) switch (kind) {
                    .configure => ",\"revision\":\"31\",\"created\":true",
                    .message => ",\"state\":\"queued\",\"input\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"},\"queue\":{\"admission\":\"23\",\"admitted_at\":\"1762329000\"},\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"1762329010\"},\"first_action\":null}",
                    .session_stop => ",\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"},\"completion\":{\"status\":\"completed\"}",
                    .session_archive => ",\"archived\":false,\"completion\":{\"status\":\"completed\"}",
                    .session_pin => ",\"pinned\":false",
                    .model_interruption => ",\"interruption_target\":{\"session\":\"k7m2qx\",\"turn\":\"3\",\"operation\":\"7\"}",
                    .permission_decision => ",\"permission_target\":{\"action\":\"29\",\"decision\":\"allow_once\"}",
                    .action_background => ",\"action_target\":{\"action\":\"29\"},\"action_selection\":{\"kind\":\"background\",\"position\":\"31\"}",
                    .action_stop => ",\"action_target\":{\"action\":\"29\"},\"resolution_position\":\"31\"",
                } else switch (kind) {
                    .message => ",\"state\":\"rejected\"",
                    .model_interruption => ",\"interruption_target\":{\"session\":\"k7m2qx\",\"turn\":\"0\",\"operation\":\"0\"}",
                    .permission_decision => ",\"permission_target\":{\"action\":\"0\",\"decision\":\"deny\"}",
                    .action_background, .action_stop => ",\"action_target\":{\"action\":\"29\"}",
                    else => "",
                };
                const body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"full\",\"since\":null,\"observation\":{\"kind\":\"" ++ @tagName(kind) ++ "\",\"target\":\"k7m2qx\",\"status\":\"" ++ (if (accepted) "accepted\"" else "rejected\",\"code\":\"unknown_session\"") ++ fields ++ "}}";
                var actual: [1 + observation_fields.len * 3]u8 = undefined;
                var legacy: [actual.len]bool = undefined;
                try collectObservationEdits(body, &observation_fields, &actual, &legacy);
                try check(&lines, "observation/" ++ @tagName(kind) ++ "/" ++ (if (accepted) "accepted" else "rejected"), &actual, &observation_fields, false, &legacy);
            }
        }
        for (message_edges) |edge| {
            const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"full\",\"since\":null,\"observation\":{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"k7m2qx\",\"input\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"},\"queue\":{\"admission\":\"23\",\"admitted_at\":\"1762329000\"}";
            const body = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, edge.fields, "}}" });
            defer std.testing.allocator.free(body);
            var actual: [1 + message_fields.len * 3]u8 = undefined;
            var legacy: [actual.len]bool = undefined;
            try collectObservationEdits(body, &message_fields, &actual, &legacy);
            const label = try std.mem.concat(std.testing.allocator, u8, &.{ "message/", edge.name });
            defer std.testing.allocator.free(label);
            try check(&lines, label, &actual, &message_fields, false, &legacy);
        }
        try std.testing.expectEqualStrings("", lines.rest());
    }
};

test "reply decoder frozen field domain from 5472ccf5" {
    try ReplyDomainWitness.run();
}

test "reply decoder requires the served work fields and closed enums" {
    const body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"full\",\"since\":null,\"observation\":{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"k7m2qx\",\"state\":\"queued\",\"input\":{\"type\":\"text\",\"bytes\":\"1\",\"sha256\":\"" ++ @as([64]u8, @splat('a')) ++ "\"},\"queue\":{\"admission\":\"1\",\"admitted_at\":\"2\"},\"work\":{\"state\":{\"kind\":\"pending\",\"since\":\"2\"},\"first_action\":null,\"attention\":null,\"group\":\"queued\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}}}}";
    try std.testing.expectEqual(@as(u8, 'a'), ReplyDomainWitness.observation(body));
    const edits = [_]struct { before: []const u8, after: []const u8 }{
        .{ .before = "\"attention\":null,", .after = "" },
        .{ .before = "\"group\":\"queued\",", .after = "" },
        .{ .before = ",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null}", .after = "" },
        .{ .before = "\"group\":\"queued\"", .after = "\"group\":\"invented\"" },
        .{ .before = "\"attention\":null", .after = "\"attention\":{\"kind\":\"invented\",\"turn\":\"1\",\"step\":\"2\"}" },
        .{ .before = "\"stop\":false,", .after = "" },
        .{ .before = "\"interrupt\":null,", .after = "" },
        .{ .before = ",\"decide\":null", .after = "" },
    };
    for (edits) |edit| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, body, edit.before, edit.after);
        defer std.testing.allocator.free(changed);
        try std.testing.expect(ReplyDomainWitness.observation(changed) != 'a');
    }
}

test "Action stop mutation and observation preserve the selected Resolution" {
    const command_reply = @import("command_reply.zig");
    const reply = @import("protocol_reply.zig");
    const subject = MutationWitness.subject(.action_stop);
    for ([_]?u64{ null, 29, 9007199254740993 }) |position| {
        var response: protocol.ResponseBuffer = .{};
        try response.render(host_reply.renderMutationReply(.action_stop), .{ subject, @as(host_reply.MutationResult(.action_stop), .{ .accepted = .{ .replayed = true, .action_id = 7, .resolution = position } }) });
        const decoded = reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, MutationWitness.session, .{ .action_stop = 7 });
        try std.testing.expectEqual(position, (try decoded.answer).result.accepted.action_stop);
        try std.testing.expect((try decoded.answer).replayed);
        const foreign = reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, MutationWitness.session, .{ .action_stop = 8 });
        try std.testing.expectError(error.RequestBindingMismatch, foreign.answer);
        const another_session = reply.decodeMutationReply(.{ .status = 200, .body = response.slice() }, "p9q8rs", .{ .action_stop = 7 });
        try std.testing.expectError(error.RequestBindingMismatch, another_session.answer);
        var observed = command_reply.CommandObservation{ .status = .accepted, .target = subject.session, .kind = .{ .action_stop = .{ .action_id = 7, .resolution = position } } };
        response = .{};
        try response.render(host_reply.renderFullCommandObservation, .{ "stop", &observed, @as(?[]const u8, null) });
        const parsed = try reply.CommandObservation.parse(.{ .status = 200, .body = response.slice() }, "stop");
        try std.testing.expectEqual(position, parsed.resolution_position);
        try std.testing.expectEqual(@as(u64, 7), parsed.action_target.?);
    }
    for ([_][]const u8{ "0", "-1", "1.0", "nullx" }) |invalid| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"version\":\"{s}\",\"type\":\"action_stop_reply\",\"answer\":{{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"action\":\"7\",\"resolution_position\":{s}}}}}", .{ protocol.wire_version, invalid });
        defer std.testing.allocator.free(body);
        const decoded = reply.decodeMutationReply(.{ .status = 200, .body = body }, MutationWitness.session, .{ .action_stop = 7 });
        try std.testing.expect(std.meta.isError(decoded.answer));
    }
}

test "SH-61 Host submits a sealed ordered input through Message admission" {
    const Capture = @import("InputCapture.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    const configure = try store_module.testingCompleteConfiguration("parts-host-config", "", root, "model-a");
    const configured = try storage.configure(&configure, .{});
    try std.testing.expect(configured == .accepted);
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.store_identity.set(root);
    try lease.paths.scratch.set(root);
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var used: std.atomic.Value(u64) = .init(0);
    const spool = try tmp.dir.createFile(std.testing.io, "parts-spool", .{ .read = true });
    const index = try tmp.dir.createFile(std.testing.io, "parts-index", .{ .read = true });
    var capture: Capture = undefined;
    capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 100000 });
    defer capture.close();
    const jpeg = @embedFile("testing/fixtures/input-baseline.jpg");
    for ([_][]const u8{ "before", jpeg, "after" }, 0..) |bytes, ordinal| {
        try capture.begin(if (ordinal == 1) .{ .image = .{ .assertion = .jpeg } } else .text, bytes.len);
        var offset: usize = 0;
        while (offset < bytes.len) {
            var allowance = bytes.len - offset;
            offset += try capture.append(bytes[offset..], &allowance, false);
        }
        try capture.end();
    }
    const loan = try capture.seal();
    var command: wire_request.MessageCommand = .{ .session = configured.accepted.session };
    try command.key.set("parts-host-message");
    var offer = try SessionEnvironments.Offer.init(std.testing.allocator, 0);
    const result = try submitMessageInput(&host, &command, &offer, loan, null);
    try std.testing.expect(result == .accepted);
    const content = result.accepted.content;
    try std.testing.expect(content == .parts);
    try std.testing.expectEqualSlices(u8, &loan.digest, &content.parts.identity.digest);
    try std.testing.expectEqualDeep(@import("content_value.zig").Owner{ .message = result.accepted.admission_id }, content.parts.owner);
    var observed: store_module.Observed = undefined;
    try storage.observeCommand(command.key.slice(), null, &observed);
    try std.testing.expectEqualDeep(content, observed.full.observation.kind.message.?.content);
}

test "SH-65 Host wire admits image bytes in order and preserves refusal identity" {
    const jpeg = @embedFile("testing/fixtures/input-baseline.jpg");
    var encoded: [std.base64.standard.Encoder.calcSize(jpeg.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, jpeg);
    const other_jpeg = @embedFile("testing/fixtures/input-progressive.jpg");
    var other_encoded: [std.base64.standard.Encoder.calcSize(other_jpeg.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&other_encoded, other_jpeg);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    const configure = try store_module.testingCompleteConfiguration("wire-parts-config", "", root, "model-a");
    const configured = try storage.configure(&configure, .{});
    try std.testing.expect(configured == .accepted);
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    try lease.paths.store_identity.set("s");
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    const Exercise = struct {
        fn run(owner: *Host, body: []const u8, expected: []const u8) !void {
            var retained: ?named_scratch.Owner = null;
            var ingress: wire_request.Ingress = undefined;
            ingress.init(std.testing.allocator, .{ .io = std.testing.io, .content_length = body.len, .scratch_path = owner.lease.paths.scratch.slice(), .request_number = 991, .retained_scratch = &retained, .scratch_budget = .{ .used = &owner.scratch_used, .limit = 100000 }, .expected_kind = .message });
            defer ingress.deinit();
            try ingress.feed(body);
            const request = try ingress.finish();
            defer request.removeTemporaryContent(std.testing.io) catch unreachable;
            var offer = try SessionEnvironments.Offer.init(std.testing.allocator, 0);
            defer offer.deinit(std.testing.allocator);
            var reply: Reply = .{ .io = std.testing.io, .allocator = std.testing.allocator };
            defer reply.deinit();
            try prepareReply(owner, &reply, -1, .{ .route = .message, .content_length = body.len }, 991, 0, request, &offer, ingress.parts_loan);
            try std.testing.expect(reply.body == .json);
            try std.testing.expect(std.mem.indexOf(u8, reply.body.json, expected) != null);
        }
        fn refuseInvalid(owner: *Host, body: []const u8) !void {
            var retained: ?named_scratch.Owner = null;
            var ingress: wire_request.Ingress = undefined;
            ingress.init(std.testing.allocator, .{ .io = std.testing.io, .content_length = body.len, .scratch_path = owner.lease.paths.scratch.slice(), .request_number = 992, .retained_scratch = &retained, .scratch_budget = .{ .used = &owner.scratch_used, .limit = 100000 }, .expected_kind = .message });
            defer ingress.deinit();
            try std.testing.expectError(error.InvalidBase64, ingress.feed(body));
            try std.testing.expect(ingress.parts_loan == null);
            try std.testing.expect(!try owner.store.commandExists("wire-invalid"));
        }
    };
    const Template = struct {
        fn body(allocator: std.mem.Allocator, key: []const u8, session: []const u8, image: []const u8, text: []const u8, reversed: bool) ![]const u8 {
            const parts = if (reversed)
                try std.fmt.allocPrint(allocator, "{{\"type\":\"image\",\"mime\":\"image/jpeg\",\"data\":\"{s}\"}},{{\"type\":\"text\",\"text\":\"{s}\"}}", .{ image, text })
            else
                try std.fmt.allocPrint(allocator, "{{\"type\":\"text\",\"text\":\"{s}\"}},{{\"type\":\"image\",\"mime\":\"image/jpeg\",\"data\":\"{s}\"}}", .{ text, image });
            defer allocator.free(parts);
            return std.fmt.allocPrint(allocator, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"s\",\"key\":\"{s}\",\"session\":\"{s}\",\"sender\":null,\"sender_handle\":null,\"parts\":[{s}]}}", .{ key, session, parts });
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try Exercise.refuseInvalid(&host, try Template.body(a, "wire-invalid", configured.accepted.session.slice(), "!!!!", "before", false));
    const good = try Template.body(a, "wire-parts", configured.accepted.session.slice(), &encoded, "before", false);
    try Exercise.run(&host, good, "\"status\":\"accepted\"");
    try Exercise.run(&host, good, "\"replayed\":true");
    try Exercise.run(&host, try Template.body(a, "wire-parts", configured.accepted.session.slice(), &encoded, "changed", false), "idempotency_key_conflict");
    try Exercise.run(&host, try Template.body(a, "wire-parts", configured.accepted.session.slice(), &other_encoded, "before", false), "idempotency_key_conflict");
    try Exercise.run(&host, try Template.body(a, "wire-parts", configured.accepted.session.slice(), &encoded, "before", true), "idempotency_key_conflict");
    const refused = try Template.body(a, "wire-refused", "000000", &encoded, "before", false);
    try Exercise.run(&host, refused, "\"status\":\"rejected\"");
    try Exercise.run(&host, refused, "\"replayed\":true");
    try Exercise.run(&host, try Template.body(a, "wire-refused", "000000", &encoded, "changed", false), "idempotency_key_conflict");
    for ([_][]const u8{ "wire-parts", "wire-refused" }) |key| {
        const id = try store_module.testing.queryU64(&storage, "SELECT primary_content_id FROM core_command WHERE command_key=?1", .{key});
        for ([_][]const u8{ "before", jpeg }, 0..) |bytes, ordinal| {
            try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&storage, "SELECT count(*) FROM content_part p JOIN content c ON c.content_id=p.part_content_id WHERE p.content_id=?1 AND p.ordinal=?2 AND c.byte_length=?3 AND c.digest=?4", .{ id, ordinal, bytes.len, store_module.testing.Blob{ .bytes = &protocol.contentDigest(bytes) } }));
        }
    }
    try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
}
