const std = @import("std");
const execution = @import("execution.zig");
const platform = @import("platform.zig");
const provider = @import("provider.zig");
const provider_output = @import("provider_output.zig");
const protocol = @import("protocol.zig");
const store_module = @import("store.zig");

pub const default_active_capacity = 1000;
pub const scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const max_clients = 12;
pub const max_ordinary_clients = 10;
pub const control_headroom = 2;
// The complete Debug request -> SQLite -> response path exceeds 512 KiB.
// One MiB is the next fixed tested bound; at 12 clients the maximum virtual
// stack reservation is therefore 12 MiB, while physical use remains on the
// production resource-measurement path.
pub const connection_stack_bytes = 1024 * 1024;
pub const maximum_connection_stack_reservation_bytes = max_clients * connection_stack_bytes;

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
    request_scratch_limit_bytes: u64 = scratch_limit_bytes,
    request_unlink: bool = false,
    response_acquire: bool = false,
    response_unlink: bool = false,
    response_write: bool = false,
    response_seal: bool = false,
    response_metadata: bool = false,
    response_metadata_unlink: bool = false,
    response_read: bool = false,
    response_import: bool = false,
    response_commit: bool = false,
    cleanup_delay_ms: i64 = 0,
    provider_inactivity_seconds: i64 = 5 * 60,
    before_launch_delay_ms: i64 = 0,
};

const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    lease: *platform.StoreLease,
    store: *store_module.Store,
    faults: Faults,
    provider_endpoint: ?[]const u8 = null,
    custody: execution.CustodyPool = .{ .records = &.{} },
    execution_shutdown: std.atomic.Value(bool) = .init(false),
    effect_shutdown: std.atomic.Value(bool) = .init(false),
    dispatch_fenced: std.atomic.Value(bool) = .init(false),
    request_counter: std.atomic.Value(u64) = .init(0),
    active_clients: std.atomic.Value(usize) = .init(0),
    classification_clients: std.atomic.Value(usize) = .init(0),
    ordinary_clients: std.atomic.Value(usize) = .init(0),
    scratch_used: std.atomic.Value(u64) = .init(0),
    drain_mutex: std.Io.Mutex = .init,
    drain_condition: std.Io.Condition = .init,

    fn clientFinished(self: *Host) void {
        self.drain_mutex.lockUncancelable(self.io);
        const prior = self.active_clients.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 0);
        self.drain_condition.broadcast(self.io);
        self.drain_mutex.unlock(self.io);
    }

    fn drain(self: *Host) void {
        self.drain_mutex.lockUncancelable(self.io);
        defer self.drain_mutex.unlock(self.io);
        while (self.active_clients.load(.acquire) != 0) {
            self.drain_condition.waitUncancelable(self.io, &self.drain_mutex);
        }
    }
};

const Connection = struct {
    host: *Host,
    stream: std.Io.net.Stream,
};

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    store_path: []const u8,
    active_capacity: usize,
    faults: Faults,
    provider_endpoint: ?[]const u8,
) !void {
    var lease = try platform.StoreLease.acquire(io, store_path);
    defer lease.release();
    var storage = try store_module.Store.open(io, lease.paths.database.slice(), lease.paths.store.slice());
    defer storage.close() catch |err| std.debug.print("latifa: Store close failed: {s}\n", .{@errorName(err)});
    try lease.prepareForServing(faults.startup_cleanup);

    const address = try std.Io.net.UnixAddress.init(lease.paths.socket.slice());
    var listener = try address.listen(io, .{ .kernel_backlog = max_clients });
    var listener_open = true;
    var socket_owned = true;
    errdefer {
        if (listener_open) listener.deinit(io);
        if (socket_owned) std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
            std.debug.print("latifa: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
        };
    }
    var socket_path: [257:0]u8 = undefined;
    const socket_z = try std.fmt.bufPrintZ(&socket_path, "{s}", .{lease.paths.socket.slice()});
    if (std.c.chmod(socket_z, 0o600) != 0) return error.SocketProtectionFailed;

    const custody_records = try allocator.alloc(execution.CustodyRecord, active_capacity);
    defer allocator.free(custody_records);
    var host = Host{
        .io = io,
        .allocator = allocator,
        .lease = &lease,
        .store = &storage,
        .faults = faults,
        .provider_endpoint = provider_endpoint,
        .custody = execution.CustodyPool.initialize(custody_records),
    };
    var execution_thread: ?std.Thread = null;
    if (provider_endpoint) |endpoint| {
        try provider.validateEndpoint(endpoint);
        try provider.initialize();
        errdefer provider.deinitialize();
        execution_thread = try std.Thread.spawn(.{}, executionMain, .{&host});
    }
    defer {
        // Stop admitting new connections before releasing any Host-owned
        // execution or request custody. Store and lease outlive both drains.
        listener.deinit(io);
        listener_open = false;
        std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
            // The lock still protects this failed cleanup. A later startup
            // removes the owned socket or refuses to serve if it cannot.
            std.debug.print("latifa: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
        };
        socket_owned = false;
        if (execution_thread) |thread| {
            host.execution_shutdown.store(true, .release);
            thread.join();
            provider.deinitialize();
        }
        host.drain();
    }
    var ready: protocol.ResponseBuffer = .{};
    try ready.appendFmt("ready store={s} socket={s} active_capacity={d} custody_record_bytes={d} execution_slot_bytes={d} scratch_limit_bytes={d} execution={s}", .{
        lease.paths.store.slice(),
        lease.paths.socket.slice(),
        active_capacity,
        @sizeOf(execution.CustodyRecord),
        @sizeOf(ExecutionSlot),
        scratch_limit_bytes,
        if (provider_endpoint != null) "enabled" else "unavailable",
    });
    if (provider_endpoint != null) {
        try ready.appendFmt(" curl={s} openssl={s}", .{ provider.curl_version, provider.openssl_version });
    }
    try ready.append("\n");
    try std.Io.File.stdout().writeStreamingAll(io, ready.slice());

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            error.SocketNotListening => if (host.effect_shutdown.load(.acquire))
                return error.EffectAwareShutdown
            else
                return err,
            else => return err,
        };
        if (host.effect_shutdown.load(.acquire)) {
            stream.close(io);
            return error.EffectAwareShutdown;
        }
        const previous = host.active_clients.fetchAdd(1, .acq_rel);
        if (previous >= max_clients) {
            host.clientFinished();
            sendStatic(io, stream.socket.handle, 503, "busy", "connection_capacity_exhausted") catch {};
            stream.close(io);
            continue;
        }
        const previous_classification = host.classification_clients.fetchAdd(1, .acq_rel);
        if (previous_classification >= control_headroom) {
            _ = host.classification_clients.fetchSub(1, .acq_rel);
            host.clientFinished();
            sendStatic(io, stream.socket.handle, 503, "busy", "classification_capacity_exhausted") catch {};
            stream.close(io);
            continue;
        }
        const connection = allocator.create(Connection) catch {
            _ = host.classification_clients.fetchSub(1, .acq_rel);
            host.clientFinished();
            stream.close(io);
            continue;
        };
        connection.* = .{ .host = &host, .stream = stream };
        const thread = std.Thread.spawn(.{ .stack_size = connection_stack_bytes }, connectionMain, .{connection}) catch {
            allocator.destroy(connection);
            _ = host.classification_clients.fetchSub(1, .acq_rel);
            host.clientFinished();
            stream.close(io);
            continue;
        };
        thread.detach();
        if (host.faults.shutdown_after_accept) return error.InjectedListenerFailure;
    }
}

const ExecutionSlot = struct {
    state: enum { free, transport, cleanup, retained_scratch, retained_metadata } = .free,
    token: execution.CustodyToken = undefined,
    binding: store_module.AttemptBinding = undefined,
    transfer: provider.Transfer = undefined,
    cleanup_ticks: u32 = 0,
    retained_scratch: provider.RetainedScratch = undefined,
    retained_metadata: store_module.RetainedOutputMetadata = undefined,
};

const AdmissionProgress = enum { no_work, retry_later, admitted };

fn executionMain(host: *Host) void {
    const slots = host.allocator.alloc(ExecutionSlot, host.custody.records.len) catch |err| {
        fenceDispatch(host, "execution workspace allocation", err);
        return;
    };
    defer host.allocator.free(slots);
    for (slots) |*slot| slot.* = .{};
    var reactor = provider.Reactor.init() catch |err| {
        fenceDispatch(host, "transport reactor initialization", err);
        return;
    };
    defer reactor.deinit();
    defer shutdownExecution(host, &reactor, slots);

    while (!host.execution_shutdown.load(.acquire) and !host.effect_shutdown.load(.acquire)) {
        var found_work = false;
        if (!host.dispatch_fenced.load(.acquire)) {
            for (slots) |*slot| {
                if (slot.state != .free) continue;
                switch (admitAttempt(host, &reactor, slot)) {
                    .admitted => found_work = true,
                    .no_work, .retry_later => break,
                }
                if (host.dispatch_fenced.load(.acquire)) break;
            }
        }
        reactor.drive(if (hasTransport(slots)) 25 else 0) catch |err| {
            fenceDispatch(host, "transport reactor", err);
            break;
        };
        while (reactor.nextCompletion()) |completion| {
            completeTransfer(host, &reactor, slots, completion);
        }
        advanceCleanup(host, slots);
        if (!found_work and !hasTransport(slots)) {
            _ = host.io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
    }
}

fn admitAttempt(host: *Host, reactor: *provider.Reactor, slot: *ExecutionSlot) AdmissionProgress {
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.admitNextModelAttempt(.{
        .attempt_before_commit = host.faults.attempt_before_commit,
    }) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        if (err != error.InjectedAttemptCommitFailure) {
            fenceDispatch(host, "Attempt admission", err);
        }
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    const binding = admission.permit.consume() catch unreachable;
    host.custody.attach(token, binding) catch unreachable;

    var view = host.store.openHistoricalView(binding) catch |err| {
        fenceDispatch(host, "historical view", err);
        finishCustodyNow(host, token);
        return .admitted;
    };
    defer view.close();
    const request_budget = provider.ScratchBudget{
        .used = &host.scratch_used,
        .limit = if (host.faults.request_scratch_acquire) 0 else host.faults.request_scratch_limit_bytes,
    };
    var retained_scratch: ?provider.RetainedScratch = null;
    var request = provider.materialize(
        host.io,
        &view,
        host.lease.paths.scratch.slice(),
        request_budget,
        .{
            .first_step = host.faults.request_first_step,
            .write = host.faults.request_write,
            .seal = host.faults.request_seal,
            .unlink = host.faults.request_unlink,
        },
        &retained_scratch,
    ) catch |err| {
        if (retained_scratch) |retained| {
            slot.state = .retained_scratch;
            slot.token = token;
            slot.binding = binding;
            slot.retained_scratch = retained;
            retainDispatchFence(host, "request scratch unlink", err);
            return .admitted;
        }
        if (host.store.isFenced()) {
            fenceDispatch(host, "canonical request read", err);
            finishCustodyNow(host, token);
            return .admitted;
        }
        settleAttemptFailure(host, token, binding, preparationFailureCode(err));
        finishCustodyNow(host, token);
        return .admitted;
    };
    var retained_response: ?provider.RetainedScratch = null;
    slot.transfer.start(host.provider_endpoint.?, request, binding, .{
        .inactivity_seconds = @intCast(host.faults.provider_inactivity_seconds),
        .response_acquire_fault = host.faults.response_acquire,
        .response_unlink_fault = host.faults.response_unlink,
        .response_write_fault = host.faults.response_write,
    }, host.lease.paths.scratch.slice(), request_budget, &retained_response) catch |err| {
        request.deinit();
        if (retained_response) |retained| {
            slot.state = .retained_scratch;
            slot.token = token;
            slot.binding = binding;
            slot.retained_scratch = retained;
            retainDispatchFence(host, "response scratch unlink", err);
            return .admitted;
        }
        std.debug.print("latifa: provider preparation failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        if (err == error.ResponseCaptureAcquisitionFailed) {
            settleAttemptFailure(host, token, binding, "response_capture_failed");
        }
        finishCustodyNow(host, token);
        return .admitted;
    };
    if (host.faults.before_launch_delay_ms != 0) {
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_launch_delay_ms), .awake) catch {};
    }
    provider.launch(reactor, &slot.transfer, &host.custody, token, host.store) catch |err| {
        slot.transfer.deinit();
        std.debug.print("latifa: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        if (host.store.isFenced()) {
            fenceDispatch(host, "dispatch handoff", err);
            finishCustodyNow(host, token);
            return .admitted;
        }
        finishCustodyNow(host, token);
        return .admitted;
    };
    slot.state = .transport;
    slot.token = token;
    slot.binding = binding;
    return .admitted;
}

fn completeTransfer(
    host: *Host,
    reactor: *provider.Reactor,
    slots: []ExecutionSlot,
    completion: provider.Completion,
) void {
    const slot = for (slots) |*candidate| {
        if (candidate.state == .transport and candidate.transfer.easy == completion.easy) break candidate;
    } else {
        fenceDispatch(host, "unknown transport completion", error.UnknownTransportCompletion);
        return;
    };
    reactor.remove(&slot.transfer);
    if (slot.transfer.responseFailureCode()) |code| {
        settleAttemptFailure(host, slot.token, slot.binding, code);
        slot.transfer.deinit();
        beginCleanup(host, slot);
        return;
    }
    const evidence = slot.transfer.evidence(completion.result) catch |err| {
        std.debug.print("latifa: invalid provider evidence for operation {d}: {s}\n", .{ slot.binding.operation_id, @errorName(err) });
        slot.transfer.deinit();
        beginCleanup(host, slot);
        return;
    };
    if (evidence.class == .success) {
        completeSuccessfulTransfer(host, slot);
        return;
    }
    // Retry settlement enters in a later slice. Transport uncertainty and
    // temporary HTTP failures must leave the consumed Attempt unresolved.
    if (evidence.class == .permanent_http) {
        var code_buffer: [96]u8 = undefined;
        const code = std.fmt.bufPrint(&code_buffer, "provider_http_{d}", .{evidence.http_status}) catch unreachable;
        settleAttemptFailure(host, slot.token, slot.binding, code);
    }
    slot.transfer.deinit();
    beginCleanup(host, slot);
}

fn completeSuccessfulTransfer(host: *Host, slot: *ExecutionSlot) void {
    const structured_output = slot.transfer.hasStructuredOutput();
    slot.transfer.response.seal(host.faults.response_seal) catch |err| {
        std.debug.print("latifa: response seal failed for operation {d}: {s}\n", .{ slot.binding.operation_id, @errorName(err) });
        settleAttemptFailure(host, slot.token, slot.binding, "response_seal_failed");
        slot.transfer.deinit();
        beginCleanup(host, slot);
        return;
    };
    if (structured_output) {
        settleAttemptFailure(host, slot.token, slot.binding, "unsupported_output_schema");
        slot.transfer.deinit();
        beginCleanup(host, slot);
        return;
    }
    var request_id: protocol.Bounded(256) = .{};
    request_id.set(slot.transfer.requestId()) catch unreachable;
    var openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    openai_model.set(slot.transfer.openaiModel()) catch unreachable;
    var x_openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    x_openai_model.set(slot.transfer.xOpenaiModel()) catch unreachable;
    var response = slot.transfer.takeResponse();
    slot.transfer.deinit();
    defer response.deinit();

    var metadata_name_buffer: [96]u8 = undefined;
    const metadata_name = std.fmt.bufPrint(&metadata_name_buffer, "response-metadata-{d}-{d}.tmp", .{
        slot.binding.operation_id,
        slot.binding.attempt_ordinal,
    }) catch unreachable;
    var retained_metadata: ?store_module.RetainedOutputMetadata = null;
    var metadata = store_module.OutputMetadataWriter.init(
        host.io,
        host.lease.paths.scratch.slice(),
        metadata_name,
        &host.scratch_used,
        host.faults.request_scratch_limit_bytes,
        host.faults.response_metadata_unlink,
        &retained_metadata,
    ) catch |err| {
        if (retained_metadata) |retained| {
            slot.state = .retained_metadata;
            slot.retained_metadata = retained;
            retainDispatchFence(host, "response metadata unlink", err);
            return;
        }
        std.debug.print("latifa: response metadata acquisition failed for operation {d}: {s}\n", .{ slot.binding.operation_id, @errorName(err) });
        settleAttemptFailure(host, slot.token, slot.binding, "response_metadata_exhausted");
        beginCleanup(host, slot);
        return;
    };
    defer metadata.deinit();
    const validated = provider_output.validate(host.io, response.file, response.length, &metadata, .{
        .metadata = host.faults.response_metadata,
    }) catch |err| {
        std.debug.print("latifa: provider output rejected for operation {d}: {s}\n", .{ slot.binding.operation_id, @errorName(err) });
        settleAttemptFailure(host, slot.token, slot.binding, provider_output.failureCode(err));
        beginCleanup(host, slot);
        return;
    };
    if (!modelObservationsAgree(
        validated.evidence.served_model.slice(),
        openai_model.slice(),
        x_openai_model.slice(),
    )) {
        settleAttemptFailure(host, slot.token, slot.binding, "contradictory_provider_output");
        beginCleanup(host, slot);
        return;
    }
    if (!host.custody.claimTerminalDelivery(slot.token)) {
        beginCleanup(host, slot);
        return;
    }
    host.store.settleModelSuccess(slot.binding, &.{
        .source = response.file,
        .source_length = response.length,
        .metadata = metadata.file,
        .item_count = validated.item_count,
        .answer_length = validated.answer_length,
        .answer_digest = validated.answer_digest,
        .response_id = validated.evidence.response_id,
        .body_model = validated.evidence.served_model,
        .openai_model = openai_model,
        .x_openai_model = x_openai_model,
        .request_id = request_id,
    }, .{
        .output_read = host.faults.response_read,
        .output_import = host.faults.response_import,
        .output_commit = host.faults.response_commit,
    }) catch |err| fenceDispatch(host, "model output import", err);
    beginCleanup(host, slot);
}

fn modelObservationsAgree(body: []const u8, openai: []const u8, x_openai: []const u8) bool {
    const values = [_][]const u8{ body, openai, x_openai };
    var observed: ?[]const u8 = null;
    for (values) |value| {
        if (value.len == 0) continue;
        if (observed) |prior| {
            if (!std.mem.eql(u8, prior, value)) return false;
        } else observed = value;
    }
    return true;
}

fn beginCleanup(host: *Host, slot: *ExecutionSlot) void {
    host.custody.detach(slot.token) catch unreachable;
    slot.state = .cleanup;
    slot.cleanup_ticks = @intCast(@divFloor(host.faults.cleanup_delay_ms + 24, 25));
    if (slot.cleanup_ticks == 0) finishSlotCleanup(host, slot);
}

fn advanceCleanup(host: *Host, slots: []ExecutionSlot) void {
    for (slots) |*slot| {
        if (slot.state != .cleanup or slot.cleanup_ticks == 0) continue;
        slot.cleanup_ticks -= 1;
        if (slot.cleanup_ticks == 0) finishSlotCleanup(host, slot);
    }
}

fn finishSlotCleanup(host: *Host, slot: *ExecutionSlot) void {
    host.custody.cleanupComplete(slot.token) catch unreachable;
    slot.* = .{};
}

fn shutdownExecution(host: *Host, reactor: *provider.Reactor, slots: []ExecutionSlot) void {
    for (slots) |*slot| switch (slot.state) {
        .free => {},
        .transport => {
            reactor.remove(&slot.transfer);
            slot.transfer.deinit();
            host.custody.detach(slot.token) catch unreachable;
            host.custody.cleanupComplete(slot.token) catch unreachable;
        },
        .cleanup => {
            host.custody.cleanupComplete(slot.token) catch unreachable;
        },
        .retained_scratch => {
            slot.retained_scratch.cleanup() catch |err| {
                std.debug.print("latifa: retained named scratch after cleanup failure: {s}\n", .{@errorName(err)});
                continue;
            };
            host.custody.detach(slot.token) catch unreachable;
            host.custody.cleanupComplete(slot.token) catch unreachable;
        },
        .retained_metadata => {
            slot.retained_metadata.cleanup() catch |err| {
                std.debug.print("latifa: retained named response metadata after cleanup failure: {s}\n", .{@errorName(err)});
                continue;
            };
            host.custody.detach(slot.token) catch unreachable;
            host.custody.cleanupComplete(slot.token) catch unreachable;
        },
    };
}

fn hasTransport(slots: []const ExecutionSlot) bool {
    for (slots) |slot| if (slot.state == .transport) return true;
    return false;
}

fn preparationFailureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.InjectedFirstPreparationFailure => "request_preparation_failed",
        error.RequestScratchExhausted => "request_scratch_exhausted",
        error.InjectedRequestWriteFailure => "request_write_failed",
        error.InjectedRequestSealFailure, error.RequestSealFailed => "request_seal_failed",
        else => "request_preparation_failed",
    };
}

fn settleAttemptFailure(
    host: *Host,
    token: execution.CustodyToken,
    binding: store_module.AttemptBinding,
    code: []const u8,
) void {
    if (!host.custody.claimTerminalDelivery(token)) return;
    host.store.settleModelFailure(binding, code, .{
        .before_commit = host.faults.result_before_commit,
    }) catch |err| fenceDispatch(host, "model failure save", err);
}

fn finishCustodyNow(host: *Host, token: execution.CustodyToken) void {
    host.custody.detach(token) catch unreachable;
    host.custody.cleanupComplete(token) catch unreachable;
}

fn fenceDispatch(host: *Host, phase: []const u8, err: anyerror) void {
    if (host.effect_shutdown.swap(true, .acq_rel)) return;
    host.dispatch_fenced.store(true, .release);
    std.debug.print("latifa: dispatch fenced after {s} failure: {s}\n", .{ phase, @errorName(err) });
    // Waking accept transfers shutdown to serve's owner. That owner stops new
    // connections, joins the execution thread (which detaches any active
    // effects under custody), drains existing clients, then releases Store.
    const address = std.Io.net.UnixAddress.init(host.lease.paths.socket.slice()) catch |address_err| {
        std.debug.print("latifa: listener wake address after dispatch fence failed: {s}\n", .{@errorName(address_err)});
        return;
    };
    const wake = address.connect(host.io) catch |connect_err| {
        std.debug.print("latifa: listener wake after dispatch fence failed: {s}\n", .{@errorName(connect_err)});
        return;
    };
    wake.close(host.io);
}

fn retainDispatchFence(host: *Host, phase: []const u8, err: anyerror) void {
    host.dispatch_fenced.store(true, .release);
    std.debug.print("latifa: dispatch fenced after {s} failure: {s}\n", .{ phase, @errorName(err) });
}

fn connectionMain(connection: *Connection) void {
    const host = connection.host;
    const stream = connection.stream;
    defer {
        stream.close(host.io);
        host.allocator.destroy(connection);
        // This is the last Host access: drain may release the stack owner as
        // soon as the active population reaches zero.
        host.clientFinished();
    }
    handleConnection(host, stream.socket.handle) catch |err| {
        sendStatic(host.io, stream.socket.handle, 400, "invocation_error", @errorName(err)) catch {};
    };
}

const Route = enum { configure, message, observe, read_result, inspect, unsupported_control };
const DropMode = enum { none, before_admission, during_admission, after_commit };

const Header = struct {
    route: Route,
    content_length: u64,
    drop: DropMode = .none,
};

fn handleConnection(host: *Host, fd: std.posix.fd_t) !void {
    var classification_held = true;
    defer if (classification_held) {
        _ = host.classification_clients.fetchSub(1, .acq_rel);
    };
    const header = try readHeader(host.io, fd);
    const ordinary = header.route != .unsupported_control;
    if (ordinary) {
        const previous = host.ordinary_clients.fetchAdd(1, .acq_rel);
        if (previous >= max_ordinary_clients) {
            _ = host.ordinary_clients.fetchSub(1, .acq_rel);
            return respondStatic(host.io, fd, 503, "busy", "ordinary_capacity_exhausted");
        }
        defer _ = host.ordinary_clients.fetchSub(1, .acq_rel);
        const prior = host.classification_clients.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 0);
        classification_held = false;
    }
    if (header.route == .unsupported_control) {
        return respondStatic(host.io, fd, 501, "unsupported", "control_surface_enters_in_later_slice");
    }
    const request_number = nextRequestNumber(host) catch {
        return respondStatic(host.io, fd, 500, "invocation_error", "request_identity_exhausted");
    };
    var cleanup_failed = false;
    var request = protocol.parseRequest(.{
        .io = host.io,
        .fd = fd,
        .content_length = header.content_length,
        .scratch_path = host.lease.paths.scratch.slice(),
        .request_number = request_number,
        .fault_content_acquire = host.faults.content_acquire,
        .fault_content_write = host.faults.content_write,
        .fault_content_seal = host.faults.content_seal,
        .cleanup_failed = &cleanup_failed,
        .scratch_budget = .{ .used = &host.scratch_used, .limit = scratch_limit_bytes },
    }) catch |err| {
        if (cleanup_failed) std.debug.print("latifa: retained ingress file and charge after cleanup failure\n", .{});
        return respondStatic(host.io, fd, if (err == error.ScratchCapacityExhausted) @as(u16, 507) else 400, "invocation_error", @errorName(err));
    };
    defer request.removeTemporaryContent(host.io) catch |err| {
        std.debug.print("latifa: retained scratch charge after cleanup failure: {s}\n", .{@errorName(err)});
    };
    if (!std.mem.eql(u8, request.store(), host.lease.paths.store.slice())) {
        return respondStatic(host.io, fd, 409, "invocation_error", "wrong_store_identity");
    }
    const route_matches = switch (request) {
        .configure => header.route == .configure,
        .message => header.route == .message,
        .observe_command => header.route == .observe,
        .read_result => header.route == .read_result,
        .inspect_session => header.route == .inspect,
    };
    if (!route_matches) {
        return respondStatic(host.io, fd, 400, "invocation_error", "route_kind_mismatch");
    }
    if (header.drop == .before_admission) return;
    if (header.drop == .during_admission and std.c.shutdown(fd, std.c.SHUT.RDWR) != 0) {
        return error.InjectedDisconnectFailed;
    }

    switch (request) {
        .configure => |*command| {
            const result = host.store.configure(command, .{
                .content_read = host.faults.content_read,
                .content_import = host.faults.content_import,
                .before_commit = host.faults.before_commit,
            });
            if (result == .infrastructure_failure and host.store.isFenced()) {
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
            if (result == .infrastructure_failure and host.store.isFenced()) {
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
            var reader = host.store.openContent(reference) catch |err| {
                fenceDispatch(host, "result content read", err);
                return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
            };
            defer reader.close();
            deliverContent(host.io, fd, &reader) catch {};
        },
        .inspect_session => |request_value| {
            const observation = host.store.inspectSession(request_value.session.slice()) catch |err| {
                fenceDispatch(host, "session inspection", err);
                return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
            };
            var response: protocol.ResponseBuffer = .{};
            try renderSessionObservation(&response, observation, .{
                .dispatch_fenced = host.dispatch_fenced.load(.acquire),
                .custody_occupied = host.custody.occupied(),
                .scratch_used_bytes = host.scratch_used.load(.acquire),
            });
            deliverResponse(host.io, fd, 200, response.slice());
        },
    }
}

fn nextRequestNumber(host: *Host) !u64 {
    var current = host.request_counter.load(.acquire);
    while (true) {
        if (current == std.math.maxInt(u64)) return error.RequestIdentityExhausted;
        current = host.request_counter.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse
            return current;
    }
}

fn readHeader(io: std.Io, fd: std.posix.fd_t) !Header {
    var buffer: [protocol.max_header_bytes]u8 = undefined;
    var used: usize = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    while (used < buffer.len) {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed = start.durationTo(now).raw.nanoseconds;
        if (elapsed >= 10 * std.time.ns_per_s) return error.HeaderDeadlineExceeded;
        const remaining_ms: i32 = @intCast(@max(1, @divFloor(10 * std.time.ns_per_s - elapsed, std.time.ns_per_ms)));
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fd, remaining_ms) == 0) return error.HeaderDeadlineExceeded;
        const count = try std.posix.read(fd, buffer[used .. used + 1]);
        if (count == 0) return error.IncompleteHeader;
        used += count;
        if (used >= 4 and std.mem.eql(u8, buffer[used - 4 .. used], "\r\n\r\n")) break;
    } else return error.HeaderTooLarge;

    const headers = buffer[0..used];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    const request_line = lines.next() orelse return error.InvalidRequestLine;
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
    const route: Route = if (std.mem.eql(u8, path, "/v1/configure"))
        .configure
    else if (std.mem.eql(u8, path, "/v1/message"))
        .message
    else if (std.mem.eql(u8, path, "/v1/observe-command"))
        .observe
    else if (std.mem.eql(u8, path, "/v1/read-result"))
        .read_result
    else if (std.mem.eql(u8, path, "/v1/inspect-session"))
        .inspect
    else if (std.mem.startsWith(u8, path, "/v1/control/"))
        .unsupported_control
    else
        return error.UnknownRoute;

    var content_length: ?u64 = null;
    var wire_ok = false;
    var content_type_ok = false;
    var drop: DropMode = .none;
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
        } else if (std.ascii.eqlIgnoreCase(name, "X-Latifa-Wire-Version")) {
            wire_ok = std.mem.eql(u8, value, protocol.wire_version);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Latifa-Test-Drop-Reply")) {
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
    return .{ .route = route, .content_length = content_length orelse return error.MissingContentLength, .drop = drop };
}

fn renderConfigureReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.ConfigureCommand,
    result: store_module.ConfigureReply,
) !void {
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
        .infrastructure_failure => {
            try response.append(",\"code\":\"canonical_store_failure\"");
        },
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

fn renderMessageReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.MessageCommand,
    result: store_module.MessageReply,
) !void {
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
        .infrastructure_failure => {
            try response.append(",\"code\":\"canonical_store_failure\"");
        },
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
            if (message.admission_id) |admission_id| {
                try response.appendFmt(",\"queue\":{{\"status\":\"{s}\",\"admission\":\"{d}\"}}", .{
                    @tagName(message.status),
                    admission_id,
                });
            }
            if (message.turn_id) |turn_id| {
                try response.appendFmt(",\"processing\":{{\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
                    turn_id,
                    message.operation_id.?,
                    message.attempt_ordinal.?,
                });
            }
            if (message.failure.len != 0) {
                try response.append(",\"result\":{\"status\":\"failed\",\"code\":");
                try response.appendJsonString(message.failure.slice());
                try response.append("}");
            } else if (message.answer) |answer| {
                try response.append(",\"result\":{\"status\":\"completed\",\"text\":");
                try renderContentReference(response, answer);
                try response.append("}");
            }
        }
    }
    try response.append("}}");
}

const ExecutionObservation = struct {
    dispatch_fenced: bool = false,
    custody_occupied: usize = 0,
    scratch_used_bytes: u64 = 0,
};

fn renderSessionObservation(
    response: *protocol.ResponseBuffer,
    observation: store_module.SessionObservation,
    execution_observation: ExecutionObservation,
) !void {
    try response.append("{\"version\":\"1\",\"type\":\"session_observation\",\"session\":");
    if (!observation.found) {
        try response.append("null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}");
        return;
    }
    try response.append("{\"reference\":");
    try response.appendJsonString(observation.session.slice());
    try response.append(",\"workspace\":");
    try response.appendJsonString(observation.workspace.slice());
    try response.append(",\"model\":");
    try response.appendJsonString(observation.model.slice());
    try response.appendFmt(",\"revision\":\"{d}\",\"tools\":[", .{observation.revision});
    var need_comma = false;
    if (observation.tools_mask & 1 != 0) {
        try response.append("\"bash\"");
        need_comma = true;
    }
    if (observation.tools_mask & 2 != 0) {
        if (need_comma) try response.append(",");
        try response.append("\"edit\"");
    }
    try response.append("],\"permission_mode\":");
    try response.appendJsonString(observation.permission_mode.slice());
    try response.appendFmt(",\"instructions\":{{\"bytes\":\"{d}\",\"sha256\":\"", .{observation.instructions.length});
    try appendHex(response, &observation.instructions.digest);
    try response.append("\"},\"output_schema\":");
    if (observation.output_schema) |reference| {
        try response.appendFmt("{{\"bytes\":\"{d}\",\"sha256\":\"", .{reference.length});
        try appendHex(response, &reference.digest);
        try response.append("\"}");
    } else {
        try response.append("null");
    }
    try response.appendFmt("}},\"pending_messages\":\"{d}\",\"execution\":{{\"status\":\"partial\",\"dispatch_fenced\":{s},\"custody_occupied\":\"{d}\",\"scratch_used_bytes\":\"{d}\",\"unavailable\":[\"structured_output\",\"retry_and_restart_resolution\"]}}}}", .{
        observation.pending_messages,
        if (execution_observation.dispatch_fenced) "true" else "false",
        execution_observation.custody_occupied,
        execution_observation.scratch_used_bytes,
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

fn sendStatic(io: std.Io, fd: std.posix.fd_t, status: u16, kind: []const u8, code: []const u8) !void {
    var response: protocol.ResponseBuffer = .{};
    try response.append("{\"version\":\"1\",\"type\":");
    try response.appendJsonString(kind);
    try response.append(",\"code\":");
    try response.appendJsonString(code);
    try response.append("}");
    try writeHttp(io, fd, status, response.slice());
}

fn respondStatic(io: std.Io, fd: std.posix.fd_t, status: u16, kind: []const u8, code: []const u8) void {
    sendStatic(io, fd, status, kind, code) catch {};
}

fn deliverResponse(io: std.Io, fd: std.posix.fd_t, status: u16, body: []const u8) void {
    // A delivery failure leaves the saved semantic answer recoverable. Never
    // append a second HTTP message to an already-started response.
    writeHttp(io, fd, status, body) catch {};
}

fn deliverContent(io: std.Io, fd: std.posix.fd_t, reader: *store_module.ContentReader) !void {
    _ = io;
    var header_buffer: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\nX-Latifa-Wire-Version: 1\r\n\r\n", .{reader.reference.length});
    try writeAll(fd, header);
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.reference.length) {
        const wanted: usize = @intCast(@min(reader.reference.length - offset, buffer.len));
        const count = try reader.read(offset, buffer[0..wanted]);
        if (count != wanted) return error.ShortCanonicalRead;
        try writeAll(fd, buffer[0..count]);
        offset += count;
    }
}

fn writeHttp(io: std.Io, fd: std.posix.fd_t, status: u16, body: []const u8) !void {
    _ = io;
    const reason = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        409 => "Conflict",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        507 => "Insufficient Storage",
        else => "Error",
    };
    var header_buffer: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Latifa-Wire-Version: 1\r\n\r\n", .{ status, reason, body.len });
    try writeAll(fd, header);
    try writeAll(fd, body);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fd, 60_000) == 0) return error.TransferInactive;
        const count = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0) return error.WriteFailed;
        if (count == 0) return error.ConnectionClosed;
        offset += @intCast(count);
    }
}

test "connection populations preserve two control places" {
    try std.testing.expectEqual(max_clients, max_ordinary_clients + control_headroom);
    try std.testing.expectEqual(@as(usize, 12 * 1024 * 1024), maximum_connection_stack_reservation_bytes);
}

test "Session observation buffer covers worst-case JSON escaping" {
    var observation: store_module.SessionObservation = .{ .found = true };
    try observation.session.set(&([_]u8{0x1f} ** protocol.max_session_bytes));
    try observation.workspace.set(&([_]u8{0x1f} ** protocol.max_workspace_bytes));
    try observation.model.set(&([_]u8{0x1f} ** protocol.max_model_bytes));
    try observation.permission_mode.set("bypass");
    observation.revision = std.math.maxInt(u64);
    observation.tools_mask = 3;
    observation.instructions = .{
        .length = std.math.maxInt(u64),
        .digest = [_]u8{0xff} ** 32,
    };
    observation.output_schema = .{
        .length = std.math.maxInt(u64),
        .digest = [_]u8{0xff} ** 32,
    };
    var response: protocol.ResponseBuffer = .{};
    try renderSessionObservation(&response, observation, .{});
    try std.testing.expect(response.len <= protocol.max_response_bytes);
}

fn finishTestClient(host: *Host, release: *std.atomic.Value(bool), completed: *std.atomic.Value(bool)) void {
    while (!release.load(.acquire)) std.atomic.spinLoopHint();
    host.clientFinished();
    completed.store(true, .release);
}

test "shutdown drain retains stack-owned Host until active clients finish" {
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .faults = .{},
    };
    host.active_clients.store(1, .release);
    var release: std.atomic.Value(bool) = .init(false);
    var completed: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, finishTestClient, .{ &host, &release, &completed });
    release.store(true, .release);
    host.drain();
    try std.testing.expect(completed.load(.acquire));
    thread.join();
}
