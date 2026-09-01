const std = @import("std");
const store_module = @import("host_store.zig");

const State = enum { available, reserved, permitted, dispatched, evidence_committed };

const LeaseState = struct {
    pool: *Pool,
    index: usize,
    state: State = .available,
    attempt_id: u64 = 0,
};

/// Opaque volatile Host custody. Callers cannot manufacture the value accepted
/// by Attempt admission or copy a one-shot dispatch permit.
pub const Lease = opaque {
    pub fn admitAttempt(
        self: *Lease,
        store: *store_module.Store,
        command: store_module.AdmitAttempt,
    ) !store_module.AdmissionResult {
        const value = leaseState(self);
        if (value.state != .reserved) return error.ExecutionCellNotReserved;
        const admitted = try store.admitAttempt(command);
        if (admitted == .admitted) {
            value.attempt_id = command.attempt_id;
            value.state = .permitted;
        }
        return admitted;
    }

    pub fn consume(self: *Lease, attempt_id: u64) !void {
        const value = leaseState(self);
        if (value.state != .permitted or value.attempt_id != attempt_id) {
            return error.DispatchPermitConsumed;
        }
        value.state = .dispatched;
    }

    pub fn completionCommitted(self: *Lease, attempt_id: u64) !void {
        const value = leaseState(self);
        if (value.state != .dispatched or value.attempt_id != attempt_id) {
            return error.ExecutionCellDoesNotOwnAttempt;
        }
        value.state = .evidence_committed;
    }

    pub fn release(self: *Lease) void {
        const value = leaseState(self);
        if (value.state == .available) return;
        value.state = .available;
        value.attempt_id = 0;
    }
};

/// Volatile process-local custody for external work. The Store records durable
/// authorization; this Host-owned pool alone records live physical custody.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    cells: []LeaseState,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Pool {
        if (capacity == 0 or capacity > std.math.maxInt(u32)) {
            return error.InvalidExecutionCellCapacity;
        }
        const cells = try allocator.alloc(LeaseState, capacity);
        var pool: Pool = .{ .allocator = allocator, .cells = cells };
        for (pool.cells, 0..) |*cell, index| cell.* = .{ .pool = &pool, .index = index };
        return pool;
    }

    pub fn deinit(self: *Pool) void {
        for (self.cells) |cell| std.debug.assert(cell.state == .available);
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn reserve(self: *Pool) !*Lease {
        for (self.cells, 0..) |*cell, index| {
            if (cell.state != .available) continue;
            cell.pool = self;
            cell.index = index;
            cell.state = .reserved;
            return @ptrCast(cell);
        }
        return error.NoExecutionCellAvailable;
    }
};

fn leaseState(lease: *Lease) *LeaseState {
    return @ptrCast(@alignCast(lease));
}

test "execution cell lease is exclusive and reusable" {
    var pool = try Pool.init(std.testing.allocator, 1);
    defer pool.deinit();
    const first = try pool.reserve();
    try std.testing.expectError(error.NoExecutionCellAvailable, pool.reserve());
    first.release();
    const second = try pool.reserve();
    second.release();
}
