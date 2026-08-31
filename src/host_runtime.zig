const std = @import("std");
const core_image = @import("core_image.zig");
const host_store = @import("host_store.zig");
const lifecycle = @import("lifecycle.zig");
const model_contract = @import("model_contract.zig");
const session_store = @import("session.zig");

pub const Config = struct {
    active_capacity: usize = 1,
    sqlite_heap_limit_bytes: u64 = 8 * 1024 * 1024,
    storage: host_store.Config = .{},
};

pub const max_active_capacity: usize = 100;

var runtime_open: std.atomic.Value(bool) = .init(false);

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    state_root: std.Io.Dir,
    storage: host_store.StorageOwner,
    execution: lifecycle.Host,
    harness_owners: std.atomic.Value(usize) = .init(0),
};

pub const Lease = struct {
    runtime: *HostRuntime,
    io: std.Io,
    allocator: std.mem.Allocator,
    execution: *lifecycle.Host,
    credit: lifecycle.Host.ActiveCredit,
    active: bool = true,

    pub fn acquire(runtime: *HostRuntime) !Lease {
        const value = state(runtime);
        var credit = try value.execution.reserveActiveCredit();
        errdefer credit.release();
        try retainHarness(runtime);
        return .{
            .runtime = runtime,
            .io = value.io,
            .allocator = value.allocator,
            .execution = &value.execution,
            .credit = credit,
        };
    }

    pub fn createSession(
        self: Lease,
        scratch: *session_store.TransientScratch,
        config: session_store.Config,
    ) !session_store.Session {
        const value = state(self.runtime);
        return session_store.Session.create(value.state_root, scratch, &value.storage, self.io, config);
    }

    pub fn restoreSession(
        self: Lease,
        scratch: *session_store.TransientScratch,
        session_id: u64,
    ) !session_store.Session {
        const value = state(self.runtime);
        return session_store.Session.openExisting(
            value.state_root,
            scratch,
            &value.storage,
            self.io,
            session_id,
        );
    }

    pub fn recoverSemanticWindow(
        self: Lease,
        session: *session_store.Session,
        frame_budget: u8,
    ) !session_store.RecoveryProgress {
        return lifecycle.recoverSemanticWindow(self.execution, session, frame_budget);
    }

    pub fn release(self: *Lease) void {
        if (!self.active) return;
        // Return the admission token before dropping the retained runtime
        // owner: HostRuntime.close may destroy the Host as soon as that owner
        // count reaches zero.
        self.credit.release();
        releaseHarness(self.runtime);
        self.active = false;
    }
};

pub const HostRuntime = opaque {
    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        state_path: []const u8,
        config: Config,
    ) !*HostRuntime {
        if (state_path.len == 0) return error.InvalidStatePath;
        if (config.active_capacity == 0 or config.active_capacity > max_active_capacity) {
            return error.InvalidActiveCapacity;
        }
        try model_contract.validateBuiltinCatalog();
        if (runtime_open.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            return error.HostRuntimeAlreadyOpen;
        }
        errdefer runtime_open.store(false, .release);
        try host_store.configureProcessHeapLimit(config.sqlite_heap_limit_bytes);
        errdefer host_store.disableProcessHeapLimit();
        var state_root = try std.Io.Dir.cwd().createDirPathOpen(
            io,
            state_path,
            .{ .permissions = .fromMode(0o700) },
        );
        errdefer state_root.close(io);
        const database_path = try std.fs.path.join(allocator, &.{ state_path, "host.sqlite3" });
        defer allocator.free(database_path);
        var storage = try host_store.StorageOwner.open(io, database_path, config.storage);
        errdefer storage.close();
        var execution = try lifecycle.Host.init(allocator, config.active_capacity);
        errdefer execution.deinit();
        const runtime = try allocator.create(State);
        runtime.* = .{
            .io = io,
            .allocator = allocator,
            .state_root = state_root,
            .storage = storage,
            .execution = execution,
        };
        return @ptrCast(runtime);
    }

    /// The application owner serializes this call against Harness.open. The
    /// retained-owner count rejects close while an opened Harness is live; it
    /// does not make an unretained raw pointer safe to acquire during teardown.
    pub fn close(self: *HostRuntime) !void {
        const runtime = state(self);
        const closing = std.math.maxInt(usize);
        if (runtime.harness_owners.cmpxchgStrong(0, closing, .acq_rel, .acquire)) |owners| {
            if (owners == closing) return error.HostRuntimeClosed;
            return error.HostRuntimeBusy;
        }
        runtime.execution.deinit();
        runtime.storage.close();
        host_store.disableProcessHeapLimit();
        runtime.state_root.close(runtime.io);
        const allocator = runtime.allocator;
        allocator.destroy(runtime);
        runtime_open.store(false, .release);
    }

    pub fn occupiedActivationBytes(self: *const HostRuntime) usize {
        return state(self).execution.slots.occupiedBytes();
    }

    pub fn occupiedActivationHighWaterBytes(self: *const HostRuntime) usize {
        return state(self).execution.slots.occupiedHighWaterBytes();
    }

    pub fn activeCapacity(self: *const HostRuntime) usize {
        return state(self).execution.slots.capacity();
    }

    pub fn activationSlotBytes(_: *const HostRuntime) usize {
        return @sizeOf(core_image.ActivationSlot);
    }

    pub fn activationReservationBytes(self: *const HostRuntime) usize {
        return state(self).execution.slots.residentBytes();
    }

    pub fn activationPoolOverheadBytes(self: *const HostRuntime) usize {
        return state(self).execution.slots.hostOverheadBytes();
    }
};

fn retainHarness(runtime: *HostRuntime) !void {
    // Harness.open is serialized against HostRuntime.close by the application
    // owner. Atomic retention supports concurrent Harness opens and closes once
    // each caller already owns a valid runtime reference.
    const value = state(runtime);
    const closing = std.math.maxInt(usize);
    var owners = value.harness_owners.load(.acquire);
    while (true) {
        if (owners == closing) return error.HostRuntimeClosed;
        if (owners == closing - 1) return error.HostRuntimeOwnerCapacityExceeded;
        owners = value.harness_owners.cmpxchgWeak(
            owners,
            owners + 1,
            .acq_rel,
            .acquire,
        ) orelse return;
    }
}

fn releaseHarness(runtime: *HostRuntime) void {
    const value = state(runtime);
    const previous = value.harness_owners.fetchSub(1, .release);
    std.debug.assert(previous > 0 and previous != std.math.maxInt(usize));
}

fn state(runtime: *const HostRuntime) *State {
    return @ptrCast(@alignCast(@constCast(runtime)));
}

test "Host Runtime validates and exposes startup-fixed active capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.testing.expectError(
        error.InvalidActiveCapacity,
        HostRuntime.open(std.testing.io, std.testing.allocator, path, .{ .active_capacity = 0 }),
    );
    try std.testing.expectError(
        error.InvalidActiveCapacity,
        HostRuntime.open(std.testing.io, std.testing.allocator, path, .{
            .active_capacity = max_active_capacity + 1,
        }),
    );

    const runtime = try HostRuntime.open(std.testing.io, std.testing.allocator, path, .{
        .active_capacity = max_active_capacity,
    });
    try std.testing.expectEqual(max_active_capacity, runtime.activeCapacity());
    try std.testing.expectEqual(
        max_active_capacity * runtime.activationSlotBytes(),
        runtime.activationReservationBytes(),
    );
    try runtime.close();
}
