const std = @import("std");
const builtin = @import("builtin");
const trace_native = @cImport({
    @cInclude("unistd.h");
});
const bash = @import("bash.zig");
const descriptor_capacity = @import("descriptor_capacity.zig");
const descriptor_limit = @import("descriptor_limit.zig");
const execution = @import("execution.zig");
const execution_turn = @import("execution_turn.zig");
const model_adapter = @import("model_adapter.zig");
const named_scratch = @import("named_scratch.zig");
const output_retention = @import("output_retention.zig");
const platform = @import("platform.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol.zig");
const store_module = @import("store.zig");

pub const default_active_capacity = 1000;
pub const default_retry_waits_ms = [3]u64{ 2_000, 4_000, 8_000 };
pub const default_bash_timeout_ms: u64 = 5 * 60 * 1000;
pub const default_bash_path = "/bin/bash";
pub const scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const default_retention_entry_capacity =
    output_retention.orchestration_bytes / @sizeOf(output_retention.Entry);
pub const max_clients = 12;
pub const max_ordinary_clients = 10;
pub const control_headroom = 2;
// The complete Debug request -> SQLite -> response path exceeds 512 KiB.
// One MiB is the next fixed tested bound; at 12 clients the maximum virtual
// stack reservation is therefore 12 MiB, while physical use remains on the
// production resource-measurement path.
pub const connection_stack_bytes = 1024 * 1024;
pub const maximum_connection_stack_reservation_bytes = max_clients * connection_stack_bytes;
pub const maximum_result_delivery_buffers_bytes = max_ordinary_clients * store_module.ContentReader.content_window_bytes;

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
    request_preparation_byte_allowance: usize = model_adapter.preparation_byte_allowance,
    request_preparation_item_allowance: usize = model_adapter.preparation_item_allowance,
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
    bash_preparation_after_script: bool = false,
    bash_spawn: bool = false,
    bash_service: bool = false,
    bash_capture_read: bool = false,
    bash_capture_write: bool = false,
    bash_seal: bool = false,
    bash_cleanup: bool = false,
    bash_lifecycle_fault: bash.LifecycleFault = .none,
    bash_fault_gated: bool = false,
    bash_scratch_limit_bytes: u64 = scratch_limit_bytes,
    retention_entry_capacity: ?usize = null,
    retention_removal: bool = false,
    cleanup_delay_ms: i64 = 0,
    provider_inactivity_seconds: i64 = 5 * 60,
    retry_waits_ms: [3]u64 = default_retry_waits_ms,
    before_launch_delay_ms: i64 = 0,
    before_result_delay_ms: i64 = 0,
    inspection_reply_delay_ms: i64 = 0,
    report_unlink: bool = false,
    client_send_buffer_bytes: ?u32 = null,
    test_phase_trace: bool = false,
    test_transition: ?TestTransition = null,
    test_transition_gate_path: ?[]const u8 = null,
    model_cleanup_gate_path: ?[]const u8 = null,
    bash_observed_exit_gate_path: ?[]const u8 = null,
    bash_cleanup_gate_path: ?[]const u8 = null,
    control_gate_keys: ?[]const u8 = null,
    control_gate_path: ?[]const u8 = null,
    suppress_first_control_hint: bool = false,
    sqlite_diagnostics: bool = false,
    sqlite_cache_spill: bool = true,
    sqlite_cache_kib: u32 = 4096,
};

const TestTransition = enum {
    action_attempt_admitted,
    action_result_ready,
    action_result_committed,
};

const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    lease: *platform.StoreLease,
    store: *store_module.Store,
    faults: Faults,
    provider_endpoint: ?[]const u8 = null,
    provider_ca_file: ?[]const u8 = null,
    authentication: ?model_adapter.Authentication = null,
    auth_worker: ?*AuthWorker = null,
    capture_writer: ?*provider.CaptureWriter = null,
    bash_path: []const u8 = default_bash_path,
    bash_timeout_ms: u64 = default_bash_timeout_ms,
    retention: *output_retention.Queue = undefined,
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
    launch_mutex: std.Io.Mutex = .init,
    trace_mutex: std.Io.Mutex = .init,
    trace_run_ns: u64 = 0,
    trace_sequence: u64 = 0,
    trace_lost: bool = false,
    last_unprocessed_completions: ?u64 = null,
    drain_mutex: std.Io.Mutex = .init,
    drain_condition: std.Io.Condition = .init,

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
    provider_ca_file: ?[]const u8,
    authentication: ?model_adapter.Authentication,
    bash_path: []const u8,
    bash_timeout_ms: u64,
) !void {
    const descriptor_observation = try descriptor_limit.observe(io);
    const descriptor_requirement = try descriptor_capacity.calculate(
        descriptor_observation.open_descriptors,
        active_capacity,
        max_ordinary_clients,
        control_headroom,
        provider_endpoint != null,
        authentication != null,
        builtin.os.tag,
    );
    descriptor_capacity.validate(
        descriptor_requirement.total,
        descriptor_observation.soft_limit,
    ) catch |err| {
        if (err == error.DescriptorCapacityInsufficient) {
            std.debug.print(
                "rui: descriptor capacity insufficient: active_capacity={d} required={d} soft_limit={d} inherited={d} fixed_host={d} clients={d} execution={d} authentication={d} self_wake={d}\n",
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
    var lease = try platform.StoreLease.acquire(io, store_path);
    defer lease.release();
    var storage = try store_module.Store.openWithOptions(
        io,
        lease.paths.database.slice(),
        lease.paths.store.slice(),
        .{ .cache_spill = faults.sqlite_cache_spill, .cache_kib = faults.sqlite_cache_kib },
    );
    defer storage.close() catch |err| std.debug.print("rui: Store close failed: {s}\n", .{@errorName(err)});
    try storage.validateRetryWaits(faults.retry_waits_ms);
    try lease.prepareForServing(faults.startup_cleanup);

    const address = try std.Io.net.UnixAddress.init(lease.paths.socket.slice());
    var listener = try address.listen(io, .{ .kernel_backlog = max_clients });
    var listener_open = true;
    var socket_owned = true;
    errdefer {
        if (listener_open) listener.deinit(io);
        if (socket_owned) std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
            std.debug.print("rui: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
        };
    }
    var socket_path: [257:0]u8 = undefined;
    const socket_z = try std.fmt.bufPrintZ(&socket_path, "{s}", .{lease.paths.socket.slice()});
    if (std.c.chmod(socket_z, 0o600) != 0) return error.SocketProtectionFailed;

    const custody_records = try allocator.alloc(execution.CustodyRecord, active_capacity);
    defer allocator.free(custody_records);
    const retention_capacity = @min(
        default_retention_entry_capacity,
        faults.retention_entry_capacity orelse default_retention_entry_capacity,
    );
    const retention_entries = try allocator.alloc(output_retention.Entry, retention_capacity);
    defer allocator.free(retention_entries);
    var host = Host{
        .io = io,
        .allocator = allocator,
        .lease = &lease,
        .store = &storage,
        .faults = faults,
        .provider_endpoint = provider_endpoint,
        .provider_ca_file = provider_ca_file,
        .authentication = authentication,
        .bash_path = bash_path,
        .bash_timeout_ms = bash_timeout_ms,
        .retention = undefined,
        .trace_run_ns = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds),
        .custody = execution.CustodyPool.initialize(custody_records),
    };
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
    const execution_thread = try std.Thread.spawn(.{}, executionMain, .{&host});
    provider_initialization_owned = false;
    defer {
        // Stop admitting new connections before releasing any Host-owned
        // execution or request custody. Store and lease outlive both drains.
        listener.deinit(io);
        listener_open = false;
        std.Io.Dir.deleteFileAbsolute(io, lease.paths.socket.slice()) catch |err| {
            // The lock still protects this failed cleanup. A later startup
            // removes the owned socket or refuses to serve if it cannot.
            std.debug.print("rui: retained stale socket after cleanup failure: {s}\n", .{@errorName(err)});
        };
        socket_owned = false;
        host.launch_mutex.lockUncancelable(host.io);
        host.execution_shutdown.store(true, .release);
        host.launch_mutex.unlock(host.io);
        execution_thread.join();
        if (provider_endpoint != null) provider.deinitialize();
        host.drain();
    }
    var ready: protocol.ResponseBuffer = .{};
    var descriptor_limit_buffer: [32]u8 = undefined;
    const descriptor_limit_text = if (descriptor_observation.soft_limit) |limit|
        try std.fmt.bufPrint(&descriptor_limit_buffer, "{d}", .{limit})
    else
        "unlimited";
    try ready.appendFmt("ready store={s} socket={s} active_capacity={d} descriptor_requirement={d} descriptor_limit={s} custody_record_bytes={d} execution_slot_bytes={d} model_preparation_bytes={d} scratch_limit_bytes={d} retention_entry_bytes={d} retention_capacity={d} bash_execution=enabled execution={s}", .{
        lease.paths.store.slice(),
        lease.paths.socket.slice(),
        active_capacity,
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
        if (host.faults.client_send_buffer_bytes) |bytes| {
            var value: c_int = @intCast(bytes);
            std.posix.setsockopt(
                stream.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.SNDBUF,
                std.mem.asBytes(&value),
            ) catch |err| {
                stream.close(io);
                return err;
            };
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
    cleanup_deadline: std.Io.Clock.Timestamp,
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
    cleanup: CleanupSlot,
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
        .cleanup => |*cleanup| cleanup.owner.token,
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
            .cleanup => |*cleanup| try custody.checkDetachedModel(cleanup.owner.token, cleanup.owner.binding),
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
    var model_preparation_active = false;
    defer shutdownExecution(
        host,
        if (reactor) |*active| active else null,
        slots,
        &bash_preparation,
        &model_preparation,
        &model_preparation_active,
    );

    var turn_state = execution_turn.State{ .capacity_was_full = slots.len == 0 };
    var measurement: LifecycleMeasurement = .{};
    while (!host.execution_shutdown.load(.acquire) and !host.effect_shutdown.load(.acquire)) {
        var bash_window: [bash.copy_window_bytes]u8 = undefined;
        var native = NativeTurn{
            .host = host,
            .reactor = if (reactor) |*active| active else null,
            .slots = slots,
            .bash_preparation = &bash_preparation,
            .model_preparation = &model_preparation,
            .model_preparation_active = &model_preparation_active,
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
    bash_preparation: *?bash.Preparation,
    model_preparation: *model_adapter.Preparation,
    model_preparation_active: *bool,
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
            self.model_preparation_active,
        );
        stopSupersededBash(self.host, self.slots, self.bash_preparation);
    }

    pub fn advanceBashPreparation(self: *NativeTurn) bool {
        return callAdvanceBashPreparation(self.host, self.slots, self.bash_preparation);
    }

    pub fn advanceLiveBash(self: *NativeTurn) bool {
        return advanceBash(self.host, self.slots, self.bash_window);
    }

    pub fn advanceOrdinaryCleanup(self: *NativeTurn, observed: std.Io.Clock.Timestamp) bool {
        return advanceCleanupAt(self.host, self.slots, observed);
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
        if (self.model_preparation_active.*) return false;
        for (self.slots) |slot| if (slot == .model_authenticating) return false;
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
            self.model_preparation_active,
        )) {
            .admitted => .admitted,
            .no_work => .no_work,
            .retry_later => .retry_later,
        };
    }

    pub fn admitNewModel(self: *NativeTurn) execution_turn.Admission {
        const slot = self.firstFreeSlot() orelse return .no_work;
        return switch (admitNewAttempt(
            self.host,
            slot,
            self.model_preparation,
            self.model_preparation_active,
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
        return callServiceOneCompletion(self.host, self.reactor, self.slots);
    }

    pub fn modelPreparationAllowance(self: *const NativeTurn) execution_turn.Allowance {
        return .{
            .bytes = self.host.faults.request_preparation_byte_allowance,
            .items = self.host.faults.request_preparation_item_allowance,
        };
    }

    pub fn advanceModelPreparation(self: *NativeTurn, byte_allowance: usize, item_allowance: usize) bool {
        return callAdvanceModelPreparation(
            self.host,
            self.reactor,
            self.slots,
            self.model_preparation,
            self.model_preparation_active,
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

fn serviceOneCompletion(host: *Host, reactor: ?*provider.Reactor, slots: []ExecutionSlot) bool {
    const active_reactor = reactor orelse return false;
    for (slots) |*slot| switch (slot.*) {
        .provider => |*active| {
            switch (active.transfer.advanceFinalization(host.faults.response_seal)) {
                .pending => {},
                .discarded => {
                    const owner = active.owner;
                    active.transfer.deinit();
                    beginCleanup(host, slot, owner);
                    return true;
                },
                .ready => |finished| {
                    completeTransfer(host, slot, finished);
                    return true;
                },
            }
        },
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
    for (slots) |*slot| switch (slot.*) {
        .provider => |*active| {
            const progress = active_reactor.advance(&active.transfer, &host.faults.response_write_on_resume) catch |err| {
                fenceDispatch(host, "transport advance", err);
                return false;
            };
            switch (progress) {
                .progressed => return true,
                .resume_capture_failure => {
                    traceSubject(host, "transport_resume_capture_failure", "cause", "local_capture");
                    return true;
                },
                .not_ready => {},
            }
        },
        else => {},
    };
    return false;
}

fn cancelSupersededTransfers(
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *model_adapter.Preparation,
    preparation_active: *bool,
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
            preparation_active.* = false;
            finishCustodyNow(host, active.token);
            slot.* = .free;
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
            if (active.transfer.advanceFinalization(false) == .discarded) {
                active.transfer.deinit();
                beginCleanup(host, slot, owner);
            }
        },
        .free, .bash_preparing, .bash, .bash_prepared_cleanup, .cleanup, .named_scratch => {},
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
        .cleanup => |value| if (value.owner.binding.operation_id == operation_id) return true,
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
        if (err != error.InjectedAttemptCommitFailure) fenceDispatch(host, "Bash Attempt admission", err);
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
        finishCustodyNow(host, token);
        if (host.store.isFenced()) fenceDispatch(host, "Bash canonical input", err);
        return .admitted;
    };
    const arguments = host.store.openContent(input.arguments) catch |err| {
        settleActionFailure(host, token, action_binding, .storage_failed, "Bash input could not be opened.");
        finishCustodyNow(host, token);
        fenceDispatch(host, "Bash canonical input", err);
        return .admitted;
    };
    const bash_budget = host.retention.sharedBudget().narrowed(host.faults.bash_scratch_limit_bytes);
    const started = bash.startPreparation(
        host.io,
        host.allocator,
        arguments,
        input.arguments.length,
        input.workspace,
        host.lease.paths.scratch.slice(),
        host.bash_path,
        input.timeout_ms,
        bash_budget,
        action_binding.action_id,
        action_binding.attempt_ordinal,
        .{
            .preparation = host.faults.bash_preparation,
            .preparation_after_script = host.faults.bash_preparation_after_script,
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
    if (!canonical_failure) {
        settleActionFailure(host, token, binding, .storage_failed, "Bash preparation failed.");
    }
    failure.cleanup.cleanup() catch |cleanup_err| {
        retainBashPreparedCleanup(host, slot, token, failure.cleanup, cleanup_err);
        return;
    };
    finishCustodyNow(host, token);
    slot.* = .free;
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
    finishCustodyNow(host, token);
    slot.* = .free;
}

fn launchPreparedBash(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    action_binding: store_module.ActionAttemptBinding,
    prepared: *bash.Prepared,
) void {
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
            context.launched.* = try context.prepared.launch();
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
            finishCustodyNow(host, active.token);
            slot.* = .free;
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
    const started = std.Io.Clock.Timestamp.now(host.io, .awake);
    active.delivery = .{ .closed = .{
        .reclaim_at = started.addDuration(.{
            .raw = .fromMilliseconds(host.faults.cleanup_delay_ms),
            .clock = .awake,
        }),
    } };
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
    traceAction(host, "cleanup_completed", binding);
    slot.* = .free;
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
    preparation: *model_adapter.Preparation,
    preparation_active: *bool,
) AdmissionProgress {
    const token = host.custody.reserve() orelse return .no_work;
    var admission = host.store.admitNextModelAttempt(.{
        .attempt_before_commit = host.faults.attempt_before_commit,
    }) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        if (err == error.InjectedAttemptCommitFailure) {
            traceSubject(host, "attempt_admission_rolled_back", "attempt_kind", "model");
        } else {
            fenceDispatch(host, "Attempt admission", err);
        }
        return .retry_later;
    } orelse {
        host.custody.releaseUnused(token) catch unreachable;
        return .no_work;
    };
    return beginAdmittedAttempt(host, slot, token, &admission.permit, preparation, preparation_active);
}

fn admitRetryAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    active: store_module.ActiveOperationFilter,
    preparation: *model_adapter.Preparation,
    preparation_active: *bool,
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
    return beginAdmittedAttempt(host, slot, token, &admission.permit, preparation, preparation_active);
}

fn beginAdmittedAttempt(
    host: *Host,
    slot: *ExecutionSlot,
    token: execution.CustodyToken,
    permit: *store_module.DispatchPermit,
    preparation: *model_adapter.Preparation,
    preparation_active: *bool,
) AdmissionProgress {
    std.debug.assert(!preparation_active.*);
    const binding = host.custody.attach(token, permit) catch |err| {
        host.custody.releaseUnused(token) catch unreachable;
        fenceDispatch(host, "custody attachment", err);
        return .admitted;
    };
    slot.* = .{ .model_preparing = .{ .token = token, .binding = binding } };
    const view = host.store.openHistoricalView(binding) catch |err| {
        if (err == error.SupersededByControl) {
            finishCustodyNow(host, token);
            slot.* = .free;
            return .admitted;
        }
        fenceDispatch(host, "historical view", err);
        finishCustodyNow(host, token);
        slot.* = .free;
        return .admitted;
    };
    const request_budget = host.retention.sharedBudget().narrowed(
        if (host.faults.request_scratch_acquire) 0 else host.faults.request_scratch_limit_bytes,
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
        if (retained_scratch) |retained| {
            host.custody.detach(token) catch unreachable;
            slot.* = .{ .named_scratch = .{
                .token = token,
                .owner = retained,
            } };
            retainDispatchFence(host, "request scratch unlink", err);
            return .admitted;
        }
        if (host.store.isFenced()) {
            fenceDispatch(host, "canonical request read", err);
            finishCustodyNow(host, token);
            slot.* = .free;
            return .admitted;
        }
        if (err == error.SupersededByControl) {
            finishCustodyNow(host, token);
            slot.* = .free;
            return .admitted;
        }
        settleAttemptFailure(host, token, binding, model_adapter.preparationFailureCode(err), .terminal);
        finishCustodyNow(host, token);
        slot.* = .free;
        return .admitted;
    };
    preparation_active.* = true;
    traceOperation(host, "preparation_started", binding);
    return .admitted;
}

fn advanceModelPreparation(
    host: *Host,
    reactor: ?*provider.Reactor,
    slots: []ExecutionSlot,
    preparation: *model_adapter.Preparation,
    preparation_active: *bool,
    byte_allowance: usize,
    item_allowance: usize,
) bool {
    if (host.auth_worker != null) {
        for (slots) |*slot| if (slot.* == .model_authenticating)
            return advanceAuthentication(host, reactor.?, slot);
    }
    if (!preparation_active.*) return false;
    const slot = for (slots) |*candidate| switch (candidate.*) {
        .model_preparing => break candidate,
        else => {},
    } else unreachable;
    const owner = slot.model_preparing;
    if (!host.launchAllowed()) {
        preparation.cancel();
        preparation_active.* = false;
        // Infrastructure fencing does not invent a user stop or a Resolution.
        finishCustodyNow(host, owner.token);
        slot.* = .free;
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
            preparation_active.* = false;
            finishModelPreparationFailure(host, slot, owner, err);
        },
        .prepared => |value| {
            tracePreparationAdvance(host, "preparation_advance_completed", stats, owner.binding);
            traceOperation(host, "preparation_completed", owner.binding);
            preparation_active.* = false;
            var request = value;
            if (host.auth_worker) |worker| {
                slot.* = .{ .model_authenticating = .{ .owner = owner, .request = request } };
                worker.request();
            } else launchPreparedRequest(host, reactor.?, slot, owner, &request, null);
        },
    }
    return true;
}

fn advanceAuthentication(host: *Host, reactor: *provider.Reactor, slot: *ExecutionSlot) bool {
    const worker = host.auth_worker.?;
    const result = worker.take() orelse return false;
    const active = &slot.model_authenticating;
    const owner = active.owner;
    var request = active.request;
    if (result == .ready) {
        defer worker.finish();
        if (!active.cancelled and host.launchAllowed()) {
            launchPreparedRequest(host, reactor, slot, owner, &request, result.ready);
        } else {
            request.deinit();
            finishCustodyNow(host, owner.token);
            slot.* = .free;
        }
    } else {
        request.deinit();
        if (!active.cancelled)
            settleAttemptFailure(host, owner.token, owner.binding, model_adapter.authenticationFailureCode(result.failed), .terminal);
        finishCustodyNow(host, owner.token);
        slot.* = .free;
    }
    return true;
}

fn finishModelPreparationFailure(
    host: *Host,
    slot: *ExecutionSlot,
    owner: ModelPreparingSlot,
    err: anyerror,
) void {
    if (host.store.isFenced()) {
        fenceDispatch(host, "canonical request read", err);
    } else if (err != error.SupersededByControl) {
        settleAttemptFailure(host, owner.token, owner.binding, model_adapter.preparationFailureCode(err), .terminal);
    }
    finishCustodyNow(host, owner.token);
    slot.* = .free;
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
        finishCustodyNow(host, token);
        slot.* = .free;
        return;
    }
    const request_budget = host.retention.sharedBudget().narrowed(
        if (host.faults.request_scratch_acquire) 0 else host.faults.request_scratch_limit_bytes,
    );
    var retained_response: ?named_scratch.Owner = null;
    if (host.faults.provider_prepare) {
        request.deinit();
        settleAttemptFailure(host, token, binding, "provider_transport_failure", .{ .retryable = .{
            .waits_ms = host.faults.retry_waits_ms,
        } });
        finishCustodyNow(host, token);
        slot.* = .free;
        return;
    }
    var headers: model_adapter.Headers = .{};
    defer headers.deinit();
    if (credential) |value| {
        headers.init(host.provider_endpoint.?, host.provider_ca_file, host.authentication.?, value, request.session_affinity) catch |err| {
            request.deinit();
            fenceDispatch(host, "provider preparation", err);
            finishCustodyNow(host, token);
            slot.* = .free;
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
        .inactivity_seconds = @intCast(host.faults.provider_inactivity_seconds),
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
        std.debug.print("rui: provider preparation failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        if (err == error.ResponseCaptureAcquisitionFailed) {
            settleAttemptFailure(host, token, binding, "response_capture_failed", .terminal);
        } else {
            fenceDispatch(host, "provider preparation", err);
        }
        finishCustodyNow(host, token);
        slot.* = .free;
        return;
    };
    if (host.faults.before_launch_delay_ms != 0) {
        traceOperation(host, "prepared_before_handoff", binding);
        _ = host.io.sleep(.fromMilliseconds(host.faults.before_launch_delay_ms), .awake) catch {};
    }
    host.custody.consumeLaunchAuthority(token, binding) catch |err| {
        active.transfer.deinit();
        std.debug.print("rui: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        fenceDispatch(host, "dispatch handoff", err);
        finishCustodyNow(host, token);
        slot.* = .free;
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
        if (err == error.HostDispatchSuppressed) {
            finishCustodyNow(host, token);
            slot.* = .free;
            return;
        }
        if (err == error.SupersededByControl) {
            traceOperation(host, "canonical_handoff_superseded", binding);
            finishCustodyNow(host, token);
            slot.* = .free;
            return;
        }
        std.debug.print("rui: provider launch failed for operation {d}: {s}\n", .{ binding.operation_id, @errorName(err) });
        fenceDispatch(host, "dispatch handoff", err);
        finishCustodyNow(host, token);
        slot.* = .free;
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
        writeTestTrace(host, &trace);
    }
    const evidence = switch (completion.outcome) {
        .response_capture_failed => |failure| {
            const code = switch (failure) {
                .scratch_exhausted => "response_scratch_exhausted",
                .write_failed => "response_write_failed",
                .seal_failed => "response_seal_failed",
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
            .named_scratch => |scratch| {
                host.custody.detach(owner.token) catch unreachable;
                slot.* = .{ .named_scratch = .{
                    .token = owner.token,
                    .owner = scratch,
                } };
            },
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
        .unsupported_http_version => "provider_http2_required",
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
                .retry_after_deadline_ms = evidence.retry_after_deadline_ms,
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
    named_scratch: named_scratch.Owner,
};

fn completeSuccessfulTransfer(host: *Host, active: *ProviderSlot) SuccessfulCompletion {
    const owner = active.owner;
    const structured_output = active.transfer.hasStructuredOutput();
    if (structured_output) {
        settleAttemptFailure(host, owner.token, owner.binding, "unsupported_output_schema", .terminal);
        active.transfer.deinit();
        return .cleanup;
    }
    var request_id: protocol.Bounded(256) = .{};
    request_id.set(active.transfer.requestId()) catch unreachable;
    var openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    openai_model.set(active.transfer.observedModel()) catch unreachable;
    var x_openai_model: protocol.Bounded(protocol.max_model_bytes) = .{};
    x_openai_model.set(active.transfer.observedAlternateModel()) catch unreachable;
    var response = active.transfer.takeResponse();
    active.transfer.deinit();
    defer response.deinit();

    var metadata_name_buffer: [96]u8 = undefined;
    const metadata_name = std.fmt.bufPrint(&metadata_name_buffer, "response-metadata-{d}-{d}.tmp", .{
        owner.binding.operation_id,
        owner.binding.attempt_ordinal,
    }) catch unreachable;
    var retained_metadata: ?named_scratch.Owner = null;
    const metadata_budget = host.retention.sharedBudget().narrowed(host.faults.request_scratch_limit_bytes);
    var metadata = store_module.OutputMetadataWriter.init(
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
        std.debug.print("rui: response metadata acquisition failed for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        settleAttemptFailure(host, owner.token, owner.binding, "response_metadata_exhausted", .terminal);
        return .cleanup;
    };
    defer metadata.deinit();
    traceOperation(host, "validation_started", owner.binding);
    const validated = model_adapter.Output.validate(host.io, response.file, response.length, &metadata, .{
        .metadata = host.faults.response_metadata,
    }) catch |err| {
        traceOperation(host, "validation_failed", owner.binding);
        std.debug.print("rui: provider output rejected for operation {d}: {s}\n", .{ owner.binding.operation_id, @errorName(err) });
        settleAttemptFailure(host, owner.token, owner.binding, model_adapter.Output.failureCode(err), .terminal);
        return .cleanup;
    };
    traceOperation(host, "validation_completed", owner.binding);
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
        .call_count = validated.call_count,
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
        } else if (err == error.InvalidProviderEnvelope) {
            host.store.settleModelAttemptFailure(owner.binding, "contradictory_provider_output", .terminal, .{
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
    beginCleanupAt(host, slot, owner, .now(host.io, .awake));
}

fn beginCleanupAt(
    host: *Host,
    slot: *ExecutionSlot,
    owner: AttemptOwner,
    now: std.Io.Clock.Timestamp,
) void {
    host.custody.detach(owner.token) catch unreachable;
    traceOperation(host, "cleanup_started", owner.binding);
    slot.* = .{ .cleanup = .{
        .owner = owner,
        .cleanup_deadline = now.addDuration(.{
            .raw = .fromMilliseconds(host.faults.cleanup_delay_ms),
            .clock = .awake,
        }),
    } };
    if (host.faults.cleanup_delay_ms == 0) finishSlotCleanupIfReleased(host, slot, now);
}

fn advanceCleanupAt(
    host: *Host,
    slots: []ExecutionSlot,
    now: std.Io.Clock.Timestamp,
) bool {
    var made_progress = false;
    for (slots) |*slot| {
        switch (slot.*) {
            .cleanup => |cleanup| {
                if (cleanup.cleanup_deadline.compare(.lte, now)) {
                    finishSlotCleanupIfReleased(host, slot, now);
                    if (slot.* == .free) made_progress = true;
                }
            },
            else => {},
        }
    }
    return made_progress;
}

fn finishSlotCleanupIfReleased(
    host: *Host,
    slot: *ExecutionSlot,
    now: std.Io.Clock.Timestamp,
) void {
    if (host.faults.model_cleanup_gate_path) |path| {
        if (testGateActive(host, path)) {
            slot.cleanup.cleanup_deadline = now.addDuration(.{
                .raw = .fromMilliseconds(100),
                .clock = .awake,
            });
            return;
        }
        traceOperation(host, "cleanup_release_observed", slot.cleanup.owner.binding);
    }
    finishSlotCleanup(host, slot);
}

fn finishSlotCleanup(host: *Host, slot: *ExecutionSlot) void {
    const owner = slot.cleanup.owner;
    const token = owner.token;
    host.custody.cleanupComplete(token) catch unreachable;
    traceOperation(host, "cleanup_completed", owner.binding);
    slot.* = .free;
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
    model_preparation_active: *bool,
) void {
    for (slots) |*slot| switch (slot.*) {
        .free => {},
        .model_preparing => |active| {
            std.debug.assert(model_preparation_active.*);
            model_preparation.cancel();
            model_preparation_active.* = false;
            finishCustodyNow(host, active.token);
            slot.* = .free;
        },
        .model_authenticating => |*active| {
            active.request.deinit();
            finishCustodyNow(host, active.owner.token);
            slot.* = .free;
        },
        .bash_preparing => |active| {
            const cleanup = preparation.*.?.cancel();
            preparation.* = null;
            discardBashResources(host, slot, active.token, cleanup);
        },
        .bash => |*active| active.execution.requestInfrastructureShutdown(.now(host.io, .awake)),
        .bash_prepared_cleanup, .named_scratch => {},
        .provider => |*active| {
            const token = active.owner.token;
            reactor.?.discard(&active.transfer);
            while (active.transfer.advanceFinalization(false) == .pending)
                _ = host.io.sleep(.fromMilliseconds(25), .awake) catch {};
            active.transfer.deinit();
            host.custody.detach(token) catch unreachable;
            host.custody.cleanupComplete(token) catch unreachable;
            slot.* = .free;
        },
        .cleanup => |cleanup| {
            host.custody.cleanupComplete(cleanup.owner.token) catch unreachable;
            slot.* = .free;
        },
    };
    var bash_window: [bash.copy_window_bytes]u8 = undefined;
    var retained_cleanup_at = std.Io.Clock.Timestamp.now(host.io, .awake);
    while (hasOwnedSlots(slots)) {
        var made_progress = advanceBash(host, slots, &bash_window);
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
    host.launch_mutex.lockUncancelable(host.io);
    const already_shutting_down = host.effect_shutdown.swap(true, .acq_rel);
    host.dispatch_fenced.store(true, .release);
    host.launch_mutex.unlock(host.io);
    if (already_shutting_down) return;
    std.debug.print("rui: dispatch fenced after {s} failure: {s}\n", .{ phase, @errorName(err) });
    // Waking accept transfers shutdown to serve's owner. That owner stops new
    // connections, joins the execution thread (which detaches any active
    // effects under custody), drains existing clients, then releases Store.
    const address = std.Io.net.UnixAddress.init(host.lease.paths.socket.slice()) catch |address_err| {
        std.debug.print("rui: listener wake address after dispatch fence failed: {s}\n", .{@errorName(address_err)});
        return;
    };
    const wake = address.connect(host.io) catch |connect_err| {
        std.debug.print("rui: listener wake after dispatch fence failed: {s}\n", .{@errorName(connect_err)});
        return;
    };
    wake.close(host.io);
}

fn retainDispatchFence(host: *Host, phase: []const u8, err: anyerror) void {
    host.launch_mutex.lockUncancelable(host.io);
    host.dispatch_fenced.store(true, .release);
    host.launch_mutex.unlock(host.io);
    std.debug.print("rui: dispatch fenced after {s} failure: {s}\n", .{ phase, @errorName(err) });
}

fn nowNs(host: *Host) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(host.io, .awake).raw.nanoseconds);
}

fn writeTestTrace(host: *Host, trace: *protocol.ResponseBuffer) void {
    if (!host.faults.test_phase_trace) return;
    host.trace_mutex.lockUncancelable(host.io);
    defer host.trace_mutex.unlock(host.io);
    host.trace_sequence += 1;
    const original = trace.slice();
    if (original.len == 0 or original[original.len - 1] != '}') {
        host.trace_lost = true;
        return;
    }
    var complete: protocol.ResponseBuffer = .{};
    complete.append(original[0 .. original.len - 1]) catch {
        host.trace_lost = true;
        return;
    };
    complete.appendFmt(
        ",\"process\":\"{d}\",\"run\":\"{d}\",\"clock\":\"awake_ns\",\"sequence\":\"{d}\",\"trace_lost\":{s}}}\n",
        .{ trace_native.getpid(), host.trace_run_ns, host.trace_sequence, if (host.trace_lost) "true" else "false" },
    ) catch {
        host.trace_lost = true;
        return;
    };
    std.Io.File.stderr().writeStreamingAll(host.io, complete.slice()) catch {
        host.trace_lost = true;
    };
}

fn traceSubject(host: *Host, phase: []const u8, subject_kind: []const u8, subject: []const u8) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"subject_kind\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(subject_kind) catch return;
    trace.append(",\"subject\":") catch return;
    trace.appendJsonString(subject) catch return;
    trace.append("}") catch return;
    writeTestTrace(host, &trace);
}

fn traceServiceBoundary(host: *Host, start_ns: u64, end_ns: u64, wait_ns: u64) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"lifecycle_boundary\",\"at_ns\":\"{d}\",\"start_ns\":\"{d}\",\"wait_ns\":\"{d}\"}}",
        .{ end_ns, start_ns, wait_ns },
    ) catch return;
    writeTestTrace(host, &trace);
}

fn traceLifecycleService(host: *Host, maximum_gap_ns: u64) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"lifecycle_service_observation\",\"at_ns\":\"{d}\",\"maximum_gap_ns\":\"{d}\",\"owner\":\"execution\"}}",
        .{ nowNs(host), maximum_gap_ns },
    ) catch return;
    writeTestTrace(host, &trace);
}

fn traceOperation(host: *Host, phase: []const u8, binding: store_module.AttemptBinding) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{
        nowNs(host),
        binding.turn_id,
        binding.operation_id,
        binding.attempt_ordinal,
    }) catch return;
    writeTestTrace(host, &trace);
}

fn tracePreparationAdvance(
    host: *Host,
    phase: []const u8,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(
        ",\"at_ns\":\"{d}\",\"work_bytes\":\"{d}\",\"work_items\":\"{d}\",\"request_bytes\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ nowNs(host), stats.work_bytes, stats.work_items, stats.request_bytes, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace);
}

fn tracePreparationAdvanceError(
    host: *Host,
    phase: []const u8,
    err: anyerror,
    stats: model_adapter.PreparationAdvanceStats,
    binding: store_module.AttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.append("{\"rui_test_phase\":") catch return;
    trace.appendJsonString(phase) catch return;
    trace.appendFmt(",\"at_ns\":\"{d}\",\"error\":", .{nowNs(host)}) catch return;
    trace.appendJsonString(@errorName(err)) catch return;
    trace.appendFmt(
        ",\"work_bytes\":\"{d}\",\"work_items\":\"{d}\",\"request_bytes\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ stats.work_bytes, stats.work_items, stats.request_bytes, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace);
}

fn traceCompletionQueue(host: *Host, queued_after: usize, binding: store_module.AttemptBinding) void {
    if (!host.faults.test_phase_trace) return;
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"provider_completion_removed\",\"at_ns\":\"{d}\",\"queued_after\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}",
        .{ nowNs(host), queued_after, binding.turn_id, binding.operation_id, binding.attempt_ordinal },
    ) catch return;
    writeTestTrace(host, &trace);
}

fn traceAction(host: *Host, phase: []const u8, binding: store_module.ActionAttemptBinding) void {
    if (!host.faults.test_phase_trace) return;
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
    writeTestTrace(host, &trace);
}

fn traceOperationControl(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.AttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
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
    writeTestTrace(host, &trace);
}

fn traceActionControl(
    host: *Host,
    phase: []const u8,
    command_key: []const u8,
    binding: store_module.ActionAttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
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
    writeTestTrace(host, &trace);
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
    writeTestTrace(host, &trace);
}

fn traceActionDeadline(
    host: *Host,
    phase: []const u8,
    deadline_ns: u64,
    failed: bool,
    binding: store_module.ActionAttemptBinding,
) void {
    if (!host.faults.test_phase_trace) return;
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
    writeTestTrace(host, &trace);
}

fn testTransition(host: *Host, transition: TestTransition, binding: store_module.ActionAttemptBinding) void {
    if (host.faults.test_transition != transition) return;
    traceAction(host, @tagName(transition), binding);
    waitAtTestGate(host, host.faults.test_transition_gate_path.?);
}

fn waitAtTestGate(host: *Host, path: []const u8) void {
    var gate = std.Io.Dir.cwd().openFile(host.io, path, .{}) catch return;
    defer gate.close(host.io);
    var release: [1]u8 = undefined;
    _ = gate.readStreaming(host.io, &.{&release}) catch return;
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
    var trace: protocol.ResponseBuffer = .{};
    trace.appendFmt(
        "{{\"rui_test_phase\":\"native_completions_unprocessed\",\"at_ns\":\"{d}\",\"queued_after\":\"{d}\"}}",
        .{ nowNs(host), count },
    ) catch return;
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
    store_queued_ns: u64 = 0,
    lock_acquired_ns: u64 = 0,
    store_complete_ns: u64 = 0,

    fn init(host: *Host, command_key: []const u8, kind: []const u8, accepted_at_ns: u64) ControlTiming {
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
                traceSubject(self.host, "control_store_queued", "command_key", self.command_key);
            },
            .lock_acquired => {
                self.lock_acquired_ns = nowNs(self.host);
                traceSubject(self.host, "control_lock_acquired", "command_key", self.command_key);
                self.waitAtTestGate();
            },
            .durable_acceptance => {
                traceSubject(self.host, "control_durable_acceptance", "command_key", self.command_key);
            },
            .store_complete => {
                self.store_complete_ns = nowNs(self.host);
                traceSubject(self.host, "control_store_complete", "command_key", self.command_key);
            },
        }
    }

    fn waitAtTestGate(self: *ControlTiming) void {
        const keys = self.host.faults.control_gate_keys orelse return;
        const path = self.host.faults.control_gate_path orelse return;
        var candidates = std.mem.splitScalar(u8, keys, ',');
        while (candidates.next()) |candidate| {
            if (!std.mem.eql(u8, candidate, self.command_key)) continue;
            // Integration tests deliberately hold this acquired Store mutex
            // until a competing control reaches lock_requested. Their keeper
            // descriptor prevents FIFO-open deadlock; process teardown bounds
            // a missing release without granting this gate semantic authority.
            var gate = std.Io.Dir.cwd().openFile(self.host.io, path, .{}) catch return;
            defer gate.close(self.host.io);
            var release: [1]u8 = undefined;
            const count = gate.readStreaming(self.host.io, &.{&release}) catch return;
            if (count == 1) traceSubject(self.host, "control_gate_released", "command_key", self.command_key);
            return;
        }
    }

    fn replyComplete(self: *ControlTiming) void {
        if (!self.host.faults.test_phase_trace) return;
        const reply_complete_ns = nowNs(self.host);
        if (self.store_queued_ns == 0 or self.lock_acquired_ns == 0 or self.store_complete_ns == 0) return;
        var trace: protocol.ResponseBuffer = .{};
        trace.append("{\"rui_test_phase\":\"control_timing\",\"command_key\":") catch return;
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
            .lock_requested => "settlement_lock_requested",
            .lock_acquired => "settlement_lock_acquired",
            .transaction_active => "settlement_transaction_active",
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
    permission_decision,
    observe,
    read_result,
    read_action_call_id,
    read_action_arguments,
    inspect,
    unsupported_control,

    fn isControl(self: Route) bool {
        return self == .session_stop or self == .model_interruption or self == .permission_decision or self == .unsupported_control;
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
    const control_limit: u64 = switch (header.route) {
        .session_stop => protocol.max_session_stop_request_bytes,
        .model_interruption => protocol.max_model_interruption_request_bytes,
        .permission_decision => protocol.max_permission_decision_request_bytes,
        else => 0,
    };
    if (header.route.isControl() and header.content_length > control_limit) {
        return respondStatic(host.io, fd, 400, "invocation_error", "control_request_too_large");
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
        .scratch_budget = host.retention.sharedBudget(),
    }) catch |err| {
        if (cleanup_failed) std.debug.print("rui: retained ingress file and charge after cleanup failure\n", .{});
        return respondStatic(host.io, fd, if (err == error.ScratchCapacityExhausted) @as(u16, 507) else 400, "invocation_error", @errorName(err));
    };
    defer request.removeTemporaryContent(host.io) catch |err| {
        std.debug.print("rui: retained scratch charge after cleanup failure: {s}\n", .{@errorName(err)});
    };
    if (!std.mem.eql(u8, request.store(), host.lease.paths.store.slice())) {
        return respondStatic(host.io, fd, 409, "invocation_error", "wrong_store_identity");
    }
    const route_matches = switch (request) {
        .configure => header.route == .configure,
        .message => header.route == .message,
        .session_stop => header.route == .session_stop,
        .model_interruption => header.route == .model_interruption,
        .permission_decision => header.route == .permission_decision,
        .observe_command => header.route == .observe,
        .read_result => header.route == .read_result,
        .read_action_call_id => header.route == .read_action_call_id,
        .read_action_arguments => header.route == .read_action_arguments,
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
        .permission_decision => |*command| {
            var timing = ControlTiming.init(host, command.key.slice(), "permission_decision", accepted_at_ns);
            const result = host.store.decidePermission(command, .{
                .before_commit = host.faults.before_commit,
                .control_trace = timing.storeTrace(),
            });
            if (result == .infrastructure_failure and host.store.isFenced()) {
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
        .read_action_arguments => |command| deliverActionContent(host, fd, command, false),
        .read_action_call_id => |command| deliverActionContent(host, fd, command, true),
        .inspect_session => |request_value| {
            var report = host.store.captureSessionReport(request_value.session.slice(), .{
                .scratch_path = host.lease.paths.scratch.slice(),
                .scratch_budget = host.retention.sharedBudget(),
                .request_number = request_number,
                .profile = request_value.profile,
                .fail_unlink = host.faults.report_unlink,
                .execution = .{
                    .dispatch_fenced = host.dispatch_fenced.load(.acquire),
                    .custody_occupied = host.custody.occupied(),
                    .scratch_used_bytes = host.scratch_used.load(.acquire),
                },
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
            defer report.deinit();
            traceSubject(host, "inspection_captured", "session", request_value.session.slice());
            traceSqliteDiagnostic(host, request_value.session.slice());
            if (host.faults.inspection_reply_delay_ms != 0) {
                _ = host.io.sleep(.fromMilliseconds(host.faults.inspection_reply_delay_ms), .awake) catch {};
            }
            deliverReport(host.io, fd, &report) catch {};
        },
    }
}

fn deliverActionContent(host: *Host, fd: std.posix.fd_t, command: anytype, comptime call_id: bool) void {
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
    var reader = host.store.openContent(resolved) catch |err| {
        fenceDispatch(host, phase, err);
        return respondStatic(host.io, fd, 500, "invocation_error", "canonical_store_failure");
    };
    defer reader.close();
    deliverContent(host.io, fd, &reader) catch {};
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
            } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Wire-Version")) {
                wire_ok = std.mem.eql(u8, value, protocol.wire_version);
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

fn renderPermissionDecisionReply(
    response: *protocol.ResponseBuffer,
    command: *const protocol.PermissionDecisionCommand,
    result: store_module.PermissionDecisionReply,
) !void {
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
    const header = try std.fmt.bufPrint(&header_buffer, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{reader.reference.length});
    try writeAll(fd, header);
    var buffer: [store_module.ContentReader.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < reader.reference.length) {
        const wanted: usize = @intCast(@min(reader.reference.length - offset, buffer.len));
        const count = try reader.read(offset, buffer[0..wanted]);
        if (count != wanted) return error.ShortCanonicalRead;
        try writeAll(fd, buffer[0..count]);
        offset += count;
    }
}

fn deliverReport(io: std.Io, fd: std.posix.fd_t, report: *store_module.SessionReport) !void {
    _ = io;
    var header_buffer: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{report.length});
    try writeAll(fd, header);
    var buffer: [store_module.SessionReport.read_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < report.length) {
        const wanted: usize = @intCast(@min(report.length - offset, buffer.len));
        const count = try report.read(offset, buffer[0..wanted]);
        if (count != wanted) return error.ShortReportRead;
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
    const header = try std.fmt.bufPrint(&header_buffer, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{ status, reason, body.len });
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
    try std.testing.expectEqual(@as(usize, 10 * 64 * 1024), maximum_result_delivery_buffers_bytes);
}

test "model retry and inactivity defaults match the owning resource contract" {
    try std.testing.expectEqual([3]u64{ 2_000, 4_000, 8_000 }, default_retry_waits_ms);
    try std.testing.expectEqual(@as(i64, 5 * 60), (Faults{}).provider_inactivity_seconds);
    try std.testing.expectEqual(
        store_module.maximum_model_attempts,
        @as(u64, default_retry_waits_ms.len + 1),
    );
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
}

test "cleanup delay follows elapsed time and preserves custody reuse" {
    var records: [1]execution.CustodyRecord = undefined;
    var host = Host{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .lease = undefined,
        .store = undefined,
        .faults = .{ .cleanup_delay_ms = 1_500 },
        .custody = execution.CustodyPool.initialize(&records),
    };
    var slots = [_]ExecutionSlot{.free};
    const start = std.Io.Timestamp.fromNanoseconds(std.time.ns_per_s).withClock(.awake);
    const before_deadline = start.addDuration(.{
        .raw = .fromMilliseconds(1_499),
        .clock = .awake,
    });
    const deadline = start.addDuration(.{
        .raw = .fromMilliseconds(1_500),
        .clock = .awake,
    });
    const far_after_deadline = start.addDuration(.{
        .raw = .fromSeconds(10),
        .clock = .awake,
    });
    const Attach = struct {
        fn run(custody: *execution.CustodyPool, turn: u64) !AttemptOwner {
            const token = custody.reserve().?;
            var permit = store_module.DispatchPermit{ .binding = .{
                .turn_id = turn,
                .operation_id = turn,
                .attempt_ordinal = 1,
            } };
            return .{ .token = token, .binding = try custody.attach(token, &permit) };
        }
    };

    const first = try Attach.run(&host.custody, 1);
    beginCleanupAt(&host, &slots[0], first, start);
    try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
    for (0..100) |_| _ = advanceCleanupAt(&host, &slots, before_deadline);
    try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
    _ = advanceCleanupAt(&host, &slots, deadline);
    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expect(slots[0] == .free);
    _ = advanceCleanupAt(&host, &slots, far_after_deadline);

    const second = try Attach.run(&host.custody, 2);
    try std.testing.expectEqual(first.token.index, second.token.index);
    try std.testing.expect(first.token.generation != second.token.generation);
    try std.testing.expectError(error.StaleCustody, host.custody.binding(first.token));
    beginCleanupAt(&host, &slots[0], second, start);
    _ = advanceCleanupAt(&host, &slots, far_after_deadline);
    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expect(slots[0] == .free);

    host.faults.cleanup_delay_ms = 0;
    const third = try Attach.run(&host.custody, 3);
    beginCleanupAt(&host, &slots[0], third, start);
    try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
    try std.testing.expect(slots[0] == .free);
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
    _ = try host.custody.attach(token, &permit);
    try host.custody.detach(token);
    var slots = [_]ExecutionSlot{.{ .named_scratch = .{
        .token = token,
        .owner = .init(
            std.testing.io,
            primary,
            secondary,
            "named-owner.tmp",
            .{ .used = &scratch_used, .limit = 9 },
            9,
            .{ .gated = &removal_gate },
        ),
    } }};

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
            var model_preparation_active = false;
            shutdownExecution(
                test_host,
                null,
                test_slots,
                test_preparation,
                &model_preparation,
                &model_preparation_active,
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

    // Two cleanup payloads on one detached token collide instead of sharing it.
    const retoken = custody.reserve().?;
    var repermit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 3,
        .operation_id = 3,
        .attempt_ordinal = 1,
    } };
    const rebinding = try custody.attach(retoken, &repermit);
    try custody.detach(retoken);
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var retained = [_]ExecutionSlot{
        .{ .cleanup = .{ .owner = .{ .token = retoken, .binding = rebinding }, .cleanup_deadline = now } },
        .{ .cleanup = .{ .owner = .{ .token = retoken, .binding = rebinding }, .cleanup_deadline = now } },
    };
    try std.testing.expectError(error.DuplicateExecutionToken, checkSlotCustodyAgreement(&retained, &custody));

    // A stale payload after reuse leaves the new owner unchanged.
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

test "detached payloads keep their typed binding identity" {
    var records: [2]execution.CustodyRecord = undefined;
    var custody = execution.CustodyPool.initialize(&records);
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);

    var first_permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const first_token = custody.reserve().?;
    const first_binding = try custody.attach(first_token, &first_permit);
    var second_permit = store_module.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 1,
    } };
    const second_token = custody.reserve().?;
    const second_binding = try custody.attach(second_token, &second_permit);
    try custody.detach(first_token);
    try custody.detach(second_token);

    var slots = [_]ExecutionSlot{
        .{ .cleanup = .{ .owner = .{ .token = first_token, .binding = first_binding }, .cleanup_deadline = now } },
        .{ .cleanup = .{ .owner = .{ .token = second_token, .binding = second_binding }, .cleanup_deadline = now } },
    };
    try checkSlotCustodyAgreement(&slots, &custody);

    // Swap only the scalar tokens while leaving bindings unchanged. Both
    // tokens are current, both records are detached, tokens stay unique,
    // and the represented count still equals occupied custody: only the
    // retained typed identity can reject this arrangement.
    slots[0].cleanup.owner.token = second_token;
    slots[1].cleanup.owner.token = first_token;
    try std.testing.expectError(error.ForeignLaunchAuthority, checkSlotCustodyAgreement(&slots, &custody));
    // Restore before cleanup so the same owners release exactly once.
    slots[0].cleanup.owner.token = first_token;
    slots[1].cleanup.owner.token = second_token;
    try checkSlotCustodyAgreement(&slots, &custody);
    try custody.cleanupComplete(first_token);
    try custody.cleanupComplete(second_token);
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
    try std.testing.expect(storage.configure(&command, .{}) == .accepted);
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
    var stderr = try tmp.dir.createFile(std.testing.io, "stderr", .{ .read = true });
    try std.testing.expect(root_budget.reserve(2));
    const pair = (try retention.reservePair("stdout", 1, "stderr", 1)).?;
    var retained_metadata: ?named_scratch.Owner = null;
    var metadata = try store_module.OutputMetadataWriter.init(
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
    stderr.close(std.testing.io);
    try retention.publishPair(pair);
    try metadata.append(.{ .tag = .usage, .start = 0, .length = 0 });
    try std.testing.expectEqual(@as(u64, 104), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), retention.occupied());
    metadata.deinit();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));

    var limited = try store_module.OutputMetadataWriter.init(
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
        .answer = .{ .length = 6, .digest = [_]u8{0xff} ** 32 },
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
    const escaped_key = [_]u8{1} ** protocol.max_key_bytes;
    const escaped_session = [_]u8{1} ** protocol.max_session_bytes;
    var observation = store_module.CommandObservation{ .status = .accepted, .kind = .message };
    try observation.target.set(&escaped_session);
    observation.message = .{
        .content = .{ .length = std.math.maxInt(u64), .digest = [_]u8{0xff} ** 32 },
        .queue = .{ .admission_id = std.math.maxInt(u64), .state = .queued },
        .progress = .{ .status = .waiting_for_permission, .action_id = std.math.maxInt(u64) },
    };
    var response: protocol.ResponseBuffer = .{};
    try renderCommandObservation(&response, &escaped_key, observation);
    try std.testing.expect(response.len <= protocol.max_message_observation_bytes);
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
    completed.store(true, .release);
    host.clientFinished();
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
        var active = true;
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
            &active,
            host.faults.request_preparation_byte_allowance,
            host.faults.request_preparation_item_allowance,
        ));
        try std.testing.expect(!active and !preparation.active and !preparation.view.active);
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
            .session_affinity = .{0} ** 16,
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
            try file.writeStreamingAll(std.testing.io, "exit 0\n");
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
                .workspace = .{},
                .scratch_path = root,
                .bash_path = undefined, // Native construction must not run.
                .timeout_ms = 1,
                .faults = .{},
                .script = .{
                    .io = std.testing.io,
                    .file = file,
                    .name = name,
                    .charged = 7,
                    .budget = .{ .used = &host.scratch_used, .limit = 7 },
                    .cleanup_fault = if (fail_cleanup) .gated else .none,
                },
                .stdout_capture = null,
                .stderr_capture = null,
            };
            var slots = [_]ExecutionSlot{.{ .bash_preparing = .{
                .token = token,
                .binding = binding,
            } }};
            @field(host, flag).store(true, .release);
            launchPreparedBash(&host, &slots[0], token, binding, &prepared);
            try std.testing.expect(prepared.script == null);
            // A retained cleanup fence must not become an effect shutdown.
            try std.testing.expectEqual(std.mem.eql(u8, flag, "effect_shutdown"), host.effect_shutdown.load(.acquire));
            if (fail_cleanup) {
                try std.testing.expect(slots[0] == .bash_prepared_cleanup);
                try std.testing.expect(slots[0].bash_prepared_cleanup.cleanup.script.?.file == null);
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
