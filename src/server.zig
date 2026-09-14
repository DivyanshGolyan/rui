const std = @import("std");
const execution = @import("execution.zig");
const platform = @import("platform.zig");
const provider = @import("provider.zig");
const provider_output = @import("provider_output.zig");
const protocol = @import("protocol.zig");
const store_module = @import("store.zig");

pub const default_active_capacity = 1000;
pub const default_retry_waits_ms = [3]u64{ 2_000, 4_000, 8_000 };
pub const scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const max_clients = 128;
pub const max_ordinary_clients = 120;
pub const control_headroom = 8;
// The complete Debug request -> SQLite -> response path exceeds 512 KiB.
// One MiB is the next fixed tested bound; at 128 clients the maximum virtual
// stack reservation is therefore 128 MiB, while physical use remains on the
// production resource-measurement path.
pub const connection_stack_bytes = 1024 * 1024;
pub const maximum_connection_stack_reservation_bytes = max_clients * connection_stack_bytes;

pub const Faults = struct {
    content_acquire: bool = false,
    content_write: bool = false,
    content_short_write: bool = false,
    content_seal: bool = false,
    content_read: bool = false,
    content_import: bool = false,
    scratch_acquire: bool = false,
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
    request_read: bool = false,
    request_unlink: bool = false,
    provider_prepare: bool = false,
    completion_identity_fault: provider.CompletionIdentityFault = .none,
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
    retry_waits_ms: [3]u64 = default_retry_waits_ms,
    before_launch_delay_ms: i64 = 0,
    before_result_delay_ms: i64 = 0,
    inspection_reply_delay_ms: i64 = 0,
    test_phase_trace: bool = false,
    suppress_first_control_hint: bool = false,
    sqlite_diagnostics: bool = false,
    sqlite_cache_spill: bool = true,
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
    controls_changed: std.atomic.Value(bool) = .init(false),
    control_hint_suppressed: std.atomic.Value(bool) = .init(false),
    request_counter: std.atomic.Value(u64) = .init(0),
    active_clients: std.atomic.Value(usize) = .init(0),
    classification_clients: std.atomic.Value(usize) = .init(0),
    ordinary_clients: std.atomic.Value(usize) = .init(0),
    scratch_used: std.atomic.Value(u64) = .init(0),
    trace_mutex: std.Io.Mutex = .init,
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
    accepted_at_ns: u64,
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
    var storage = try store_module.Store.openWithOptions(
        io,
        lease.paths.database.slice(),
        lease.paths.store.slice(),
        .{ .cache_spill = faults.sqlite_cache_spill },
    );
    defer storage.close() catch |err| std.debug.print("latifa: Store close failed: {s}\n", .{@errorName(err)});
    try storage.validateRetryWaits(faults.retry_waits_ms);
    try lease.prepareForServing(faults.startup_cleanup);

    const address = try std.Io.net.UnixAddress.init(lease.paths.socket.slice());
    var listener = try address.listen(io, .{ .kernel_backlog = max_clients });
    defer listener.deinit(io);
    defer std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
        // The lock still protects this failed cleanup. A later startup will
        // remove the owned socket or refuse to serve if it cannot do so.
        std.debug.print("latifa: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
    };
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
    // The listener stops accepting before this defer runs; draining keeps the
    // stack-owned Host, Store and lock alive through every transferred Stream.
    defer host.drain();
    var execution_thread: ?std.Thread = null;
    if (provider_endpoint) |endpoint| {
        try provider.validateEndpoint(endpoint);
        try provider.initialize();
        errdefer provider.deinitialize();
        execution_thread = try std.Thread.spawn(.{}, executionMain, .{&host});
    }
    defer if (execution_thread) |thread| {
        host.execution_shutdown.store(true, .release);
        thread.join();
        provider.deinitialize();
    };
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
        connection.* = .{
            .host = &host,
            .stream = stream,
            .accepted_at_ns = nowNs(&host),
        };
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

const AttemptOwner = struct {
    token: execution.CustodyToken = undefined,
    binding: store_module.AttemptBinding = undefined,
};

const ProviderSlot = struct {
    owner: AttemptOwner,
    transfer: provider.Transfer = undefined,
};

const CleanupSlot = struct {
    owner: AttemptOwner,
    cleanup_ticks: u32 = 0,
};

const RetainedScratchSlot = struct {
    token: execution.CustodyToken,
    scratch: provider.RetainedScratch,
};

const RetainedMetadataSlot = struct {
    token: execution.CustodyToken,
    metadata: store_module.RetainedOutputMetadata,
};

const ExecutionSlot = union(enum) {
    free,
    provider: ProviderSlot,
    cleanup: CleanupSlot,
    retained_scratch: RetainedScratchSlot,
    retained_metadata: RetainedMetadataSlot,
};

const AdmissionProgress = enum { no_work, retry_later, admitted };

fn executionMain(host: *Host) void {
    const slots = host.allocator.alloc(ExecutionSlot, host.custody.records.len) catch |err| {
        fenceDispatch(host, "execution workspace allocation", err);
        return;
    };
    defer host.allocator.free(slots);
    for (slots) |*slot| slot.* = .free;
    var reactor = provider.Reactor.init() catch |err| {
        fenceDispatch(host, "transport reactor initialization", err);
        return;
    };
    defer reactor.deinit();
    defer shutdownExecution(host, &reactor, slots);

    var last_retry_poll: ?std.Io.Clock.Timestamp = null;
    var capacity_was_full = slots.len == 0;
    while (!host.execution_shutdown.load(.acquire) and !host.effect_shutdown.load(.acquire)) {
        var made_progress = false;
        const now = std.Io.Clock.Timestamp.now(host.io, .awake);
        const free_slots = countFreeSlots(slots);
        const capacity_released = capacity_was_full and free_slots != 0;
        const retry_poll_due = if (last_retry_poll) |last|
            last.durationTo(now).raw.nanoseconds >= std.time.ns_per_s
        else
            true;
        if (!host.dispatch_fenced.load(.acquire)) {
            const active_slots = ActiveSlots{ .slots = slots };
            const active_filter = store_module.ActiveOperationFilter{
                .context = &active_slots,
                .containsFn = activeOperationContains,
                .maximum_exclusions = slots.len,
            };
            const maintain_retries = retry_poll_due or capacity_released;
            var may_admit_new = !maintain_retries;
            if (maintain_retries) {
                const recovered = host.store.recoverOneExhaustedModelAttempt(active_filter) catch |err| {
                    fenceDispatch(host, "exhausted retry recovery", err);
                    break;
                };
                if (recovered) {
                    made_progress = true;
                    last_retry_poll = null;
                } else {
                    last_retry_poll = now;
                }
                if (free_slots != 0) {
                    for (slots) |*slot| {
                        if (!slotIsFree(slot)) continue;
                        switch (admitRetryAttempt(host, &reactor, slot, active_filter)) {
                            .admitted => {
                                made_progress = true;
                                last_retry_poll = null;
                            },
                            .no_work => may_admit_new = true,
                            .retry_later => {
                                last_retry_poll = null;
                            },
                        }
                        break;
                    }
                }
            }
            if (may_admit_new) {
                for (slots) |*slot| {
                    if (!slotIsFree(slot)) continue;
                    switch (admitNewAttempt(host, &reactor, slot)) {
                        .admitted => made_progress = true,
                        .no_work, .retry_later => {},
                    }
                    break;
                }
            }
        }
        if (host.controls_changed.swap(false, .acq_rel)) {
            cancelSupersededTransfers(host, &reactor, slots);
            made_progress = true;
        }
        capacity_was_full = countFreeSlots(slots) == 0;
        if (hasTransport(slots)) {
            reactor.drive(if (made_progress) 0 else 25) catch |err| {
                fenceDispatch(host, "transport reactor", err);
                break;
            };
        } else if (!made_progress) {
            _ = host.io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
        while (true) {
            const active_transfers = ActiveSlots{ .slots = slots };
            const completion = reactor.nextCompletion(.{
                .context = &active_transfers,
                .find_fn = findActiveTransfer,
            }) catch |err| {
                fenceDispatch(host, "transport completion", err);
                return;
            } orelse break;
            completeTransfer(host, slots, completion);
        }
        advanceCleanup(host, slots);
    }
}

fn cancelSupersededTransfers(host: *Host, reactor: *provider.Reactor, slots: []ExecutionSlot) void {
    for (slots) |*slot| switch (slot.*) {
        .provider => |*active| {
            const superseded = host.store.operationSupersededByControl(active.owner.binding) catch |err| {
                fenceDispatch(host, "control reconciliation", err);
                return;
            };
            if (!superseded) continue;
            const owner = active.owner;
            reactor.cancel(&active.transfer);
            active.transfer.deinit();
            beginCleanup(host, slot, owner);
        },
        .free, .cleanup, .retained_scratch, .retained_metadata => {},
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
        .cleanup => |value| if (value.owner.binding.operation_id == operation_id) return true,
        .free, .retained_scratch, .retained_metadata => {},
    };
    return false;
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
    reactor: *provider.Reactor,
    slot: *ExecutionSlot,
) AdmissionProgress {
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
    return beginAdmittedAttempt(host, reactor, slot, token, &admission.permit);
}

fn admitRetryAttempt(
    host: *Host,
    reactor: *provider.Reactor,
    slot: *ExecutionSlot,
    active: store_module.ActiveOperationFilter,
) AdmissionProgress {
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.tryAdmitNextModelRetry(
        active,
        .{ .attempt_before_commit = host.faults.attempt_before_commit },
    ) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        if (err != error.InjectedAttemptCommitFailure) {
            fenceDispatch(host, "retry Attempt admission", err);
        }
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    return beginAdmittedAttempt(host, reactor, slot, token, &admission.permit);
}

fn beginAdmittedAttempt(
    host: *Host,
    reactor: *provider.Reactor,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    permit: *store_module.DispatchPermit,
) AdmissionProgress {
    const binding = host.custody.attach(token, permit) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "custody attachment", err);
        return .admitted;
    };

    var view = host.store.openHistoricalView(binding) catch |err| {
        if (err == error.SupersededByControl) {
            finishCustodyNow(host, token);
            return .admitted;
        }
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
            slot.* = .{ .retained_scratch = .{
                .token = token,
                .scratch = retained,
            } };
            retainDispatchFence(host, "request scratch unlink", err);
            return .admitted;
        }
        if (host.store.isFenced()) {
            fenceDispatch(host, "canonical request read", err);
            finishCustodyNow(host, token);
            return .admitted;
        }
        if (err == error.SupersededByControl) {
            finishCustodyNow(host, token);
            return .admitted;
        }
        settleAttemptFailure(host, token, binding, preparationFailureCode(err), .terminal);
        finishCustodyNow(host, token);
        return .admitted;
    };
    var retained_response: ?provider.RetainedScratch = null;
    if (host.faults.provider_prepare) {
        request.deinit();
        settleAttemptFailure(host, token, binding, "provider_transport_failure", .{ .retryable = .{
            .waits_ms = host.faults.retry_waits_ms,
        } });
        finishCustodyNow(host, token);
        return .admitted;
    }
    // Transfer.start gives curl pointers into the Transfer, so construct it in
    // its final slot and keep that union arm active through removal and deinit.
    slot.* = .{ .provider = .{
        .owner = .{ .token = token, .binding = binding },
        .transfer = undefined,
    } };
    const active = &slot.provider;
    active.transfer.start(host.provider_endpoint.?, request, binding, .{
        .inactivity_seconds = @intCast(host.faults.provider_inactivity_seconds),
        .request_read_fault = host.faults.request_read,
        .response_acquire_fault = host.faults.response_acquire,
        .response_unlink_fault = host.faults.response_unlink,
        .response_write_fault = host.faults.response_write,
        .completion_identity_fault = host.faults.completion_identity_fault,
    }, host.lease.paths.scratch.slice(), request_budget, &retained_response) catch |err| {
        request.deinit();
        if (retained_response) |retained| {
            slot.* = .{ .retained_scratch = .{
                .token = token,
                .scratch = retained,
            } };
            retainDispatchFence(host, "response scratch unlink", err);
            return .admitted;
        }
        std.debug.print("latifa: provider preparation failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        if (err == error.ResponseCaptureAcquisitionFailed) {
            settleAttemptFailure(host, token, binding, "response_capture_failed", .terminal);
        } else {
            fenceDispatch(host, "provider preparation", err);
        }
        finishCustodyNow(host, token);
        slot.* = .free;
        return .admitted;
    };
    if (host.faults.before_launch_delay_ms != 0) {
        traceOperation(host, "prepared_before_handoff", binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_launch_delay_ms), .awake) catch {};
    }
    host.custody.consumeLaunchAuthority(token, binding) catch |err| {
        active.transfer.deinit();
        std.debug.print("latifa: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        fenceDispatch(host, "dispatch handoff", err);
        finishCustodyNow(host, token);
        slot.* = .free;
        return .admitted;
    };
    host.store.withDispatchHandoff(
        binding,
        .{ .reactor = reactor, .transfer = &active.transfer },
        struct {
            fn handoff(context: anytype) !void {
                try context.reactor.add(context.transfer);
            }
        }.handoff,
    ) catch |err| {
        active.transfer.deinit();
        if (err == error.SupersededByControl) {
            traceOperation(host, "canonical_handoff_superseded", binding);
            finishCustodyNow(host, token);
            slot.* = .free;
            return .admitted;
        }
        std.debug.print("latifa: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        fenceDispatch(host, "dispatch handoff", err);
        finishCustodyNow(host, token);
        slot.* = .free;
        return .admitted;
    };
    traceOperation(host, "transport_handoff_committed", binding);
    return .admitted;
}

fn completeTransfer(
    host: *Host,
    slots: []ExecutionSlot,
    completion: provider.Completion,
) void {
    const slot = for (slots) |*candidate| {
        switch (candidate.*) {
            .provider => |*active| if (active.transfer.identity() == completion.identity) break candidate,
            else => {},
        }
    } else {
        fenceDispatch(host, "unknown transport completion", error.UnknownTransportCompletion);
        return;
    };
    const active = &slot.provider;
    const owner = active.owner;
    const evidence = switch (completion.outcome) {
        .response_capture_failed => |failure| {
            const code = switch (failure) {
                .scratch_exhausted => "response_scratch_exhausted",
                .write_failed => "response_write_failed",
            };
            settleAttemptFailure(host, owner.token, owner.binding, code, .terminal);
            active.transfer.deinit();
            beginCleanup(host, slot, owner);
            return;
        },
        .request_source_failed => {
            fenceDispatch(host, "request scratch read", error.RequestScratchReadFailed);
            active.transfer.deinit();
            beginCleanup(host, slot, owner);
            return;
        },
        .transport_finished => |evidence| evidence,
    };
    if (evidence.disposition == .success) {
        switch (completeSuccessfulTransfer(host, active)) {
            .cleanup => beginCleanup(host, slot, owner),
            .retained_metadata => |metadata| slot.* = .{ .retained_metadata = .{
                .token = owner.token,
                .metadata = metadata,
            } },
        }
        return;
    }
    var code_buffer: [96]u8 = undefined;
    const code = switch (evidence.disposition) {
        .success => unreachable,
        .permanent_http => std.fmt.bufPrint(&code_buffer, "provider_http_{d}", .{evidence.http_status}) catch unreachable,
        .temporary_http => std.fmt.bufPrint(&code_buffer, "provider_temporary_http_{d}", .{evidence.http_status}) catch unreachable,
        .temporary_connection => "provider_transport_failure",
        .permanent_transport => "provider_transport_permanent",
        .authentication_failure => "provider_authentication_failed",
        .tls_verification_failure => "provider_tls_verification_failed",
        .invalid_headers => "invalid_provider_headers",
    };
    const failure_disposition: store_module.ModelFailureDisposition =
        if (evidence.disposition == .temporary_http or
        evidence.disposition == .temporary_connection)
            .{ .retryable = .{
                .waits_ms = host.faults.retry_waits_ms,
                .retry_after_ms = evidence.retry_after_ms,
            } }
        else
            .terminal;
    settleAttemptFailure(
        host,
        owner.token,
        owner.binding,
        code,
        failure_disposition,
    );
    active.transfer.deinit();
    beginCleanup(host, slot, owner);
}

const SuccessfulCompletion = union(enum) {
    cleanup,
    retained_metadata: store_module.RetainedOutputMetadata,
};

fn completeSuccessfulTransfer(host: *Host, active: *ProviderSlot) SuccessfulCompletion {
    const owner = active.owner;
    const structured_output = active.transfer.hasStructuredOutput();
    active.transfer.response.seal(host.faults.response_seal) catch |err| {
        std.debug.print("latifa: response seal failed for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        settleAttemptFailure(host, owner.token, owner.binding, "response_seal_failed", .terminal);
        active.transfer.deinit();
        return .cleanup;
    };
    if (structured_output) {
        settleAttemptFailure(host, owner.token, owner.binding, "unsupported_output_schema", .terminal);
        active.transfer.deinit();
        return .cleanup;
    }
    var request_id: protocol.Bounded(256) = .{};
    request_id.set(active.transfer.requestId()) catch unreachable;
    var openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    openai_model.set(active.transfer.openaiModel()) catch unreachable;
    var x_openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    x_openai_model.set(active.transfer.xOpenaiModel()) catch unreachable;
    var response = active.transfer.takeResponse();
    active.transfer.deinit();
    defer response.deinit();

    var metadata_name_buffer: [96]u8 = undefined;
    const metadata_name = std.fmt.bufPrint(&metadata_name_buffer, "response-metadata-{d}-{d}.tmp", .{
        owner.binding.operation_id,
        owner.binding.attempt_ordinal,
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
            retainDispatchFence(host, "response metadata unlink", err);
            return .{ .retained_metadata = retained };
        }
        std.debug.print("latifa: response metadata acquisition failed for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        settleAttemptFailure(host, owner.token, owner.binding, "response_metadata_exhausted", .terminal);
        return .cleanup;
    };
    defer metadata.deinit();
    const validated = provider_output.validate(host.io, response.file, response.length, &metadata, .{
        .metadata = host.faults.response_metadata,
    }) catch |err| {
        std.debug.print("latifa: provider output rejected for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        settleAttemptFailure(host, owner.token, owner.binding, provider_output.failureCode(err), .terminal);
        return .cleanup;
    };
    if (!modelObservationsAgree(
        validated.evidence.served_model.slice(),
        openai_model.slice(),
        x_openai_model.slice(),
    )) {
        settleAttemptFailure(host, owner.token, owner.binding, "contradictory_provider_output", .terminal);
        return .cleanup;
    }
    if (host.faults.before_result_delay_ms != 0) {
        traceOperation(host, "sealed_before_settlement", owner.binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_result_delay_ms), .awake) catch {};
    }
    if (!host.custody.claimTerminalDelivery(owner.token)) return .cleanup;
    var settlement_trace = SettlementTrace.init(host, owner.binding);
    host.store.settleModelSuccess(owner.binding, &.{
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
        .settlement_trace = settlement_trace.storeTrace(),
    }) catch |err| {
        if (err == error.SupersededByControl) {
            traceOperation(host, "model_settlement_superseded", owner.binding);
        } else {
            fenceDispatch(host, "model output import", err);
        }
        return .cleanup;
    };
    traceOperation(host, "model_settlement_committed", owner.binding);
    return .cleanup;
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

fn beginCleanup(host: *Host, slot: *ExecutionSlot, owner: AttemptOwner) void {
    host.custody.detach(owner.token) catch unreachable;
    traceOperation(host, "cleanup_started", owner.binding);
    slot.* = .{ .cleanup = .{
        .owner = owner,
        .cleanup_ticks = @intCast(@divFloor(host.faults.cleanup_delay_ms + 24, 25)),
    } };
    if (slot.cleanup.cleanup_ticks == 0) finishSlotCleanup(host, slot);
}

fn advanceCleanup(host: *Host, slots: []ExecutionSlot) void {
    for (slots) |*slot| {
        switch (slot.*) {
            .cleanup => |*cleanup| {
                if (cleanup.cleanup_ticks == 0) continue;
                cleanup.cleanup_ticks -= 1;
                if (cleanup.cleanup_ticks == 0) finishSlotCleanup(host, slot);
            },
            else => {},
        }
    }
}

fn finishSlotCleanup(host: *Host, slot: *ExecutionSlot) void {
    const owner = slot.cleanup.owner;
    const token = owner.token;
    host.custody.cleanupComplete(token) catch unreachable;
    traceOperation(host, "cleanup_completed", owner.binding);
    slot.* = .free;
}

fn shutdownExecution(host: *Host, reactor: *provider.Reactor, slots: []ExecutionSlot) void {
    for (slots) |*slot| switch (slot.*) {
        .free => {},
        .provider => |*active| {
            const token = active.owner.token;
            reactor.cancel(&active.transfer);
            active.transfer.deinit();
            host.custody.detach(token) catch unreachable;
            host.custody.cleanupComplete(token) catch unreachable;
        },
        .cleanup => |cleanup| {
            host.custody.cleanupComplete(cleanup.owner.token) catch unreachable;
        },
        .retained_scratch => |*retained| {
            retained.scratch.cleanup() catch |err| {
                std.debug.print("latifa: retained named scratch after cleanup failure: {s}\n", .{@errorName(err)});
                continue;
            };
            host.custody.detach(retained.token) catch unreachable;
            host.custody.cleanupComplete(retained.token) catch unreachable;
        },
        .retained_metadata => |*retained| {
            retained.metadata.cleanup() catch |err| {
                std.debug.print("latifa: retained named response metadata after cleanup failure: {s}\n", .{@errorName(err)});
                continue;
            };
            host.custody.detach(retained.token) catch unreachable;
            host.custody.cleanupComplete(retained.token) catch unreachable;
        },
    };
}

fn hasTransport(slots: []const ExecutionSlot) bool {
    for (slots) |slot| {
        if (slot == .provider) return true;
    }
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
    disposition: store_module.ModelFailureDisposition,
) void {
    if (!host.custody.claimTerminalDelivery(token)) return;
    host.store.settleModelAttemptFailure(binding, code, disposition, .{
        .before_commit = host.faults.result_before_commit,
    }) catch |err| if (err != error.SupersededByControl)
        fenceDispatch(host, "model failure save", err);
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

fn nowNs(host: *Host) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(host.io, .awake).raw.nanoseconds);
}

fn writeTestTrace(host: *Host, trace: *protocol.ResponseBuffer) void {
    if (!host.faults.test_phase_trace) return;
    trace.append("\n") catch return;
    host.trace_mutex.lockUncancelable(host.io);
    defer host.trace_mutex.unlock(host.io);
    std.Io.File.stderr().writeStreamingAll(host.io, trace.slice()) catch return;
}

fn traceSubject(host: *Host, phase: []const u8, subject_kind: []const u8, subject: []const u8) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"latifa_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"subject_kind\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(subject_kind) catch return;
    trace.append(",\"subject\":") catch return;
    trace.appendJsonString(subject) catch return;
    trace.append("}") catch return;
    writeTestTrace(host, &trace);
}

fn traceOperation(host: *Host, phase: []const u8, binding: store_module.AttemptBinding) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"latifa_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\"}}", .{
        nowNs(host),
        binding.turn_id,
        binding.operation_id,
    }) catch return;
    writeTestTrace(host, &trace);
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
    const value = host.store.sqliteDiagnostic();
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"latifa_test_phase\":\"sqlite_diagnostic\",\"at_ns\":\"") catch return;
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
    appendOptionalSigned(&trace, "cache_size_pages", value.cache_size_pages) catch return;
    trace.append(",") catch return;
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
    writeTestTrace(host, &trace);
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
    command_key: []const u8,
    kind: []const u8,
    accepted_at_ns: u64,
    store_queued_ns: u64,
    lock_acquired_ns: u64 = 0,
    store_complete_ns: u64 = 0,

    fn init(host: *Host, command_key: []const u8, kind: []const u8, accepted_at_ns: u64) ControlTiming {
        return .{
            .host = host,
            .command_key = command_key,
            .kind = kind,
            .accepted_at_ns = accepted_at_ns,
            .store_queued_ns = nowNs(host),
        };
    }

    fn storeTrace(self: *ControlTiming) ?store_module.ControlTrace {
        if (!self.host.faults.test_phase_trace) return null;
        return .{ .context = self, .mark_fn = markStore };
    }

    fn markStore(context: *anyopaque, phase: store_module.ControlTracePhase) void {
        const self: *ControlTiming = @ptrCast(@alignCast(context));
        switch (phase) {
            .lock_acquired => self.lock_acquired_ns = nowNs(self.host),
            .store_complete => self.store_complete_ns = nowNs(self.host),
        }
    }

    fn replyComplete(self: *ControlTiming) void {
        if (!self.host.faults.test_phase_trace) return;
        const reply_complete_ns = nowNs(self.host);
        if (self.lock_acquired_ns == 0 or self.store_complete_ns == 0) return;
        var trace: protocol.ResponseBuffer = .{};
        trace.append("{\"latifa_test_phase\":\"control_timing\",\"command_key\":") catch return;
        trace.appendJsonString(self.command_key) catch return;
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
        writeTestTrace(self.host, &trace);
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
            .lock_acquired => "settlement_lock_acquired",
            .settlement_complete => "settlement_complete",
        }, self.binding);
    }
};

fn connectionMain(connection: *Connection) void {
    const host = connection.host;
    const stream = connection.stream;
    const accepted_at_ns = connection.accepted_at_ns;
    defer {
        stream.close(host.io);
        host.allocator.destroy(connection);
        // This is the last Host access: drain may release the stack owner as
        // soon as the active population reaches zero.
        host.clientFinished();
    }
    handleConnection(host, stream.socket.handle, accepted_at_ns) catch |err| {
        sendStatic(host.io, stream.socket.handle, 400, "invocation_error", @errorName(err)) catch {};
    };
}

const Route = enum {
    configure,
    message,
    session_stop,
    model_interruption,
    observe,
    read_result,
    inspect,
    unsupported_control,

    fn isControl(self: Route) bool {
        return self == .session_stop or self == .model_interruption or self == .unsupported_control;
    }
};
const DropMode = enum { none, before_admission, during_admission, after_commit };

const Header = struct {
    route: Route,
    content_length: u64,
    drop: DropMode = .none,
};

fn handleConnection(host: *Host, fd: std.posix.fd_t, accepted_at_ns: u64) !void {
    var classification_held = true;
    defer if (classification_held) {
        _ = host.classification_clients.fetchSub(1, .acq_rel);
    };
    var ordinary_held = false;
    defer if (ordinary_held) {
        _ = host.ordinary_clients.fetchSub(1, .acq_rel);
    };
    var header_reader = HeaderReader.init(host.io, fd);
    const route = try header_reader.readRoute();
    const ordinary = !route.isControl();
    if (ordinary) {
        const previous = host.ordinary_clients.fetchAdd(1, .acq_rel);
        if (previous >= max_ordinary_clients) {
            _ = host.ordinary_clients.fetchSub(1, .acq_rel);
            return respondStatic(host.io, fd, 503, "busy", "ordinary_capacity_exhausted");
        }
        ordinary_held = true;
        const prior = host.classification_clients.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 0);
        classification_held = false;
    }
    const header = try header_reader.finish(route);
    if (header.route == .unsupported_control) {
        return respondStatic(host.io, fd, 501, "unsupported", "control_surface_enters_in_later_slice");
    }
    const control = header.route.isControl();
    const control_limit: u64 = switch (header.route) {
        .session_stop => protocol.max_session_stop_request_bytes,
        .model_interruption => protocol.max_model_interruption_request_bytes,
        else => 0,
    };
    if (control and header.content_length > control_limit) {
        return respondStatic(host.io, fd, 400, "invocation_error", "control_request_too_large");
    }
    if (!control and (host.faults.scratch_acquire or !try reserveScratch(host, header.content_length))) {
        return respondStatic(host.io, fd, 507, "invocation_error", "scratch_capacity_exhausted");
    }
    var release_scratch = !control;
    defer if (release_scratch) releaseScratch(host, header.content_length);

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
        .fault_content_short_write = host.faults.content_short_write,
        .fault_content_seal = host.faults.content_seal,
        .cleanup_failed = &cleanup_failed,
    }) catch |err| {
        if (cleanup_failed) release_scratch = false;
        return respondStatic(host.io, fd, 400, "invocation_error", @errorName(err));
    };
    defer request.removeTemporaryContent(host.io) catch |err| {
        release_scratch = false;
        std.debug.print("latifa: retained scratch charge after cleanup failure: {s}\n", .{@errorName(err)});
    };
    if (!std.mem.eql(u8, request.store(), host.lease.paths.store.slice())) {
        return respondStatic(host.io, fd, 409, "invocation_error", "wrong_store_identity");
    }
    const route_matches = switch (request) {
        .configure => header.route == .configure,
        .message => header.route == .message,
        .session_stop => header.route == .session_stop,
        .model_interruption => header.route == .model_interruption,
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
        .session_stop => |*command| {
            var timing = ControlTiming.init(host, command.key.slice(), "session_stop", accepted_at_ns);
            const result = host.store.stopSession(command, .{
                .before_commit = host.faults.before_commit,
                .control_trace = timing.storeTrace(),
            });
            if (result == .infrastructure_failure and host.store.isFenced()) {
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
            timing.replyComplete();
        },
        .model_interruption => |*command| {
            var timing = ControlTiming.init(host, command.key.slice(), "model_interruption", accepted_at_ns);
            const result = host.store.interruptModel(command, .{
                .before_commit = host.faults.before_commit,
                .control_trace = timing.storeTrace(),
            });
            if (result == .infrastructure_failure and host.store.isFenced()) {
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
            timing.replyComplete();
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
            const scratch_used = host.scratch_used.load(.acquire);
            std.debug.assert(scratch_used >= header.content_length);
            try renderSessionObservation(&response, observation, .{
                .dispatch_fenced = host.dispatch_fenced.load(.acquire),
                .custody_occupied = host.custody.occupied(),
                // Report workload scratch, not the inspection request that is
                // currently using the shared ingress scratch pool.
                .scratch_used_bytes = scratch_used - header.content_length,
            });
            traceSubject(host, "inspection_captured", "session", request_value.session.slice());
            traceSqliteDiagnostic(host, request_value.session.slice());
            if (host.faults.inspection_reply_delay_ms != 0) {
                _ = host.io.sleep(.fromMilliseconds(host.faults.inspection_reply_delay_ms), .awake) catch {};
            }
            deliverResponse(host.io, fd, 200, response.slice());
        },
    }
}

fn reserveScratch(host: *Host, amount: u64) !bool {
    if (amount > scratch_limit_bytes) return false;
    var current = host.scratch_used.load(.acquire);
    while (true) {
        const next = std.math.add(u64, current, amount) catch return false;
        if (next > scratch_limit_bytes) return false;
        current = host.scratch_used.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return true;
    }
}

fn releaseScratch(host: *Host, amount: u64) void {
    const prior = host.scratch_used.fetchSub(amount, .acq_rel);
    std.debug.assert(prior >= amount);
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
    io: std.Io,
    fd: std.posix.fd_t,
    buffer: [protocol.max_header_bytes]u8 = undefined,
    used: usize = 0,
    started: std.Io.Clock.Timestamp,

    fn init(io: std.Io, fd: std.posix.fd_t) HeaderReader {
        return .{ .io = io, .fd = fd, .started = .now(io, .awake) };
    }

    fn readRoute(self: *HeaderReader) !Route {
        while (self.used < self.buffer.len) {
            try self.readByte();
            if (self.used >= 2 and std.mem.eql(u8, self.buffer[self.used - 2 .. self.used], "\r\n")) break;
        } else return error.HeaderTooLarge;
        const request_line = self.buffer[0 .. self.used - 2];
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
        return if (std.mem.eql(u8, path, "/v1/configure"))
            .configure
        else if (std.mem.eql(u8, path, "/v1/message"))
            .message
        else if (std.mem.eql(u8, path, "/v1/control/session-stop"))
            .session_stop
        else if (std.mem.eql(u8, path, "/v1/control/model-interruption"))
            .model_interruption
        else if (std.mem.eql(u8, path, "/v1/observe-command"))
            .observe
        else if (std.mem.eql(u8, path, "/v1/read-result"))
            .read_result
        else if (std.mem.eql(u8, path, "/v1/inspect-session"))
            .inspect
        else if (std.mem.startsWith(u8, path, "/v1/control/"))
            .unsupported_control
        else
            error.UnknownRoute;
    }

    fn finish(self: *HeaderReader, route: Route) !Header {
        while (self.used < self.buffer.len) {
            try self.readByte();
            if (self.used >= 4 and std.mem.eql(u8, self.buffer[self.used - 4 .. self.used], "\r\n\r\n")) break;
        } else return error.HeaderTooLarge;

        var lines = std.mem.splitSequence(u8, self.buffer[0..self.used], "\r\n");
        _ = lines.next() orelse return error.InvalidRequestLine;
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
        return .{
            .route = route,
            .content_length = content_length orelse return error.MissingContentLength,
            .drop = drop,
        };
    }

    fn readByte(self: *HeaderReader) !void {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        const elapsed = self.started.durationTo(now).raw.nanoseconds;
        if (elapsed >= 10 * std.time.ns_per_s) return error.HeaderDeadlineExceeded;
        const remaining_ms: i32 = @intCast(@max(
            1,
            @divFloor(10 * std.time.ns_per_s - elapsed, std.time.ns_per_ms),
        ));
        var poll_fd = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fd, remaining_ms) == 0) return error.HeaderDeadlineExceeded;
        const count = try std.posix.read(self.fd, self.buffer[self.used .. self.used + 1]);
        if (count == 0) return error.IncompleteHeader;
        self.used += count;
    }
};

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

fn renderSessionStopReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.SessionStopCommand,
    result: store_module.SessionStopReply,
) !void {
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
        .infrastructure_failure => try response.append(",\"code\":\"canonical_store_failure\""),
    }
    try response.append("},\"completion\":{\"status\":\"");
    try response.append(if (result == .accepted) "completed" else "unavailable");
    try response.append("\"}}");
}

fn renderModelInterruptionReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.ModelInterruptionCommand,
    result: store_module.ModelInterruptionReply,
) !void {
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
        .infrastructure_failure => try response.append(",\"code\":\"canonical_store_failure\""),
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
    try response.appendFmt("}},\"pending_messages\":\"{d}\",\"execution\":{{\"status\":\"partial\",\"dispatch_fenced\":{s},\"custody_occupied\":\"{d}\",\"scratch_used_bytes\":\"{d}\",\"unavailable\":[\"structured_output\"]}}}}", .{
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

fn appendHex(response: *protocol.ResponseBuffer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try response.append(&.{ alphabet[byte >> 4], alphabet[byte & 0x0f] });
    }
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

test "connection populations preserve eight control places" {
    try std.testing.expectEqual(max_clients, max_ordinary_clients + control_headroom);
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), maximum_connection_stack_reservation_bytes);
}

test "model retry and inactivity defaults match the owning resource contract" {
    try std.testing.expectEqual([3]u64{ 2_000, 4_000, 8_000 }, default_retry_waits_ms);
    try std.testing.expectEqual(@as(i64, 5 * 60), (Faults{}).provider_inactivity_seconds);
    try std.testing.expectEqual(
        store_module.maximum_model_attempts,
        @as(u64, default_retry_waits_ms.len + 1),
    );
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

    const content = store_module.ContentReference{ .length = 3, .digest = [_]u8{0} ** 32 };
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
    try Expect.rendered(
        observation,
        accepted_prefix ++ ",\"queue\":{\"status\":\"queued\",\"admission\":\"1\"}}}",
    );

    observation.message.?.queue.?.state = .{ .processing = processing };
    try Expect.rendered(
        observation,
        accepted_prefix ++ ",\"queue\":{\"status\":\"processing\",\"admission\":\"1\"}" ++ binding ++ "}}",
    );

    observation.message.?.queue.?.state = .{ .completed = .{
        .binding = processing,
        .answer = .{ .length = 6, .digest = [_]u8{0xff} ** 32 },
    } };
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

test "control response variants fit exact worst-case JSON bounds" {
    const escaped_session = [_]u8{1} ** protocol.max_session_bytes;
    const escaped_key = [_]u8{1} ** protocol.max_key_bytes;
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
    } }, protocol.max_session_stop_accepted_reply_bytes);
    try Cases.expectStop(&stop_command, .{ .rejected = .{
        .replayed = false,
        .code = .invalid_session_reference,
    } }, protocol.max_session_stop_rejected_reply_bytes);
    try Cases.expectStop(&stop_command, .conflict, protocol.max_session_stop_conflict_reply_bytes);
    try Cases.expectStop(
        &stop_command,
        .infrastructure_failure,
        protocol.max_session_stop_infrastructure_reply_bytes,
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
        protocol.max_model_interruption_infrastructure_reply_bytes,
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
