const std = @import("std");
const host_store = @import("host_store.zig");
const lifecycle = @import("lifecycle.zig");
const session_store = @import("session.zig");

pub const Config = struct {
    sqlite_heap_limit_bytes: u64 = 8 * 1024 * 1024,
    storage: host_store.Config = .{},
};

var runtime_open: std.atomic.Value(bool) = .init(false);

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    state_root: std.Io.Dir,
    storage: host_store.StorageOwner,
    execution: lifecycle.Host = .{},
    harness_owners: std.atomic.Value(usize) = .init(0),
    retired_lock: std.Io.Mutex = .init,
    retired: ?*Retired = null,
};

pub const Retired = struct {
    next: ?*Retired = null,
    context: *anyopaque,
    destroy: *const fn (std.mem.Allocator, *anyopaque) void,
};

pub const Lease = struct {
    runtime: *HostRuntime,
    io: std.Io,
    allocator: std.mem.Allocator,
    execution: *lifecycle.Host,
    active: bool = true,

    pub fn acquire(runtime: *HostRuntime) !Lease {
        try retainHarness(runtime);
        const value = state(runtime);
        return .{
            .runtime = runtime,
            .io = value.io,
            .allocator = value.allocator,
            .execution = &value.execution,
        };
    }

    pub fn createSession(self: Lease, config: session_store.Config) !session_store.Session {
        const value = state(self.runtime);
        return session_store.Session.create(value.state_root, &value.storage, self.io, config);
    }

    pub fn restoreSession(self: Lease, session_id: u64) !session_store.Restored {
        const value = state(self.runtime);
        return session_store.Session.openExisting(
            value.state_root,
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
        releaseHarness(self.runtime);
        self.active = false;
    }

    pub fn retire(self: *Lease, retired: *Retired) void {
        if (!self.active) return;
        const value = state(self.runtime);
        value.retired_lock.lockUncancelable(self.io);
        retired.next = value.retired;
        value.retired = retired;
        value.retired_lock.unlock(self.io);
        self.release();
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
        const runtime = try allocator.create(State);
        runtime.* = .{
            .io = io,
            .allocator = allocator,
            .state_root = state_root,
            .storage = storage,
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
        runtime.storage.close();
        host_store.disableProcessHeapLimit();
        runtime.state_root.close(runtime.io);
        const allocator = runtime.allocator;
        var retired = runtime.retired;
        while (retired) |node| {
            const next = node.next;
            node.destroy(allocator, node.context);
            retired = next;
        }
        allocator.destroy(runtime);
        runtime_open.store(false, .release);
    }

    pub fn occupiedActivationBytes(self: *const HostRuntime) usize {
        return state(self).execution.slots.occupiedBytes();
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
