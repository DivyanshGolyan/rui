const std = @import("std");
const store = @import("store.zig");

pub const CustodyToken = struct {
    index: usize,
    generation: u64,
};

const State = enum(u8) { free, reserved, attached, detached };

pub const CustodyRecord = struct {
    state: std.atomic.Value(State) = .init(.free),
    generation: std.atomic.Value(u64) = .init(0),
    delivered: std.atomic.Value(bool) = .init(false),
    launch_available: std.atomic.Value(bool) = .init(false),
    binding: store.AttemptBinding = undefined,
};

pub const CustodyPool = struct {
    records: []CustodyRecord,

    pub fn initialize(records: []CustodyRecord) CustodyPool {
        for (records) |*record| record.* = .{};
        return .{ .records = records };
    }

    pub fn reserve(self: *CustodyPool) ?CustodyToken {
        for (self.records, 0..) |*record, index| {
            if (record.state.cmpxchgStrong(.free, .reserved, .acq_rel, .acquire) != null) continue;
            const generation = record.generation.fetchAdd(1, .acq_rel) + 1;
            record.delivered.store(false, .release);
            return .{ .index = index, .generation = generation };
        }
        return null;
    }

    pub fn attach(
        self: *CustodyPool,
        token: CustodyToken,
        permit: *store.DispatchPermit,
    ) !store.AttemptBinding {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .reserved) return error.InvalidCustodyTransition;
        const attempt_binding = try permit.consume();
        record.binding = attempt_binding;
        record.launch_available.store(true, .release);
        record.state.store(.attached, .release);
        return attempt_binding;
    }

    pub fn consumeLaunchAuthority(
        self: *CustodyPool,
        token: CustodyToken,
        attempt_binding: store.AttemptBinding,
    ) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached or
            record.binding.turn_id != attempt_binding.turn_id or
            record.binding.operation_id != attempt_binding.operation_id or
            record.binding.attempt_ordinal != attempt_binding.attempt_ordinal)
        {
            return error.ForeignLaunchAuthority;
        }
        if (record.launch_available.cmpxchgStrong(true, false, .acq_rel, .acquire) != null) {
            return error.DispatchPermitConsumed;
        }
    }

    pub fn binding(self: *CustodyPool, token: CustodyToken) !store.AttemptBinding {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached) return error.CustodyDetached;
        return record.binding;
    }

    pub fn claimTerminalDelivery(self: *CustodyPool, token: CustodyToken) bool {
        const record = self.current(token) catch return false;
        if (record.state.load(.acquire) != .attached) return false;
        return record.delivered.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    }

    pub fn detach(self: *CustodyPool, token: CustodyToken) !void {
        const record = try self.current(token);
        if (record.state.cmpxchgStrong(.attached, .detached, .acq_rel, .acquire) != null) {
            return error.InvalidCustodyTransition;
        }
    }

    pub fn releaseUnused(self: *CustodyPool, token: CustodyToken) !void {
        const record = try self.current(token);
        if (record.state.cmpxchgStrong(.reserved, .free, .acq_rel, .acquire) != null) {
            return error.InvalidCustodyTransition;
        }
    }

    pub fn cleanupComplete(self: *CustodyPool, token: CustodyToken) !void {
        const record = try self.current(token);
        if (record.state.cmpxchgStrong(.detached, .free, .acq_rel, .acquire) != null) {
            return error.InvalidCustodyTransition;
        }
    }

    pub fn occupied(self: *const CustodyPool) usize {
        var count: usize = 0;
        for (self.records) |*record| {
            if (record.state.load(.acquire) != .free) count += 1;
        }
        return count;
    }

    fn current(self: *CustodyPool, token: CustodyToken) !*CustodyRecord {
        if (token.index >= self.records.len) return error.ForeignCustody;
        const record = &self.records[token.index];
        if (record.generation.load(.acquire) != token.generation) return error.StaleCustody;
        return record;
    }
};

test "custody remains occupied through detachment and rejects late delivery after reuse" {
    var records: [1]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const first = pool.reserve().?;
    var first_permit = store.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const first_binding = try pool.attach(first, &first_permit);
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.consumeLaunchAuthority(first, .{ .turn_id = 1, .operation_id = 2, .attempt_ordinal = 1 }),
    );
    try pool.consumeLaunchAuthority(first, first_binding);
    try std.testing.expectError(
        error.DispatchPermitConsumed,
        pool.consumeLaunchAuthority(first, first_binding),
    );
    try std.testing.expect(pool.claimTerminalDelivery(first));
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    try pool.detach(first);
    try std.testing.expectEqual(@as(usize, 1), pool.occupied());
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    try pool.cleanupComplete(first);

    const second = pool.reserve().?;
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    var second_permit = store.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 1,
    } };
    _ = try pool.attach(second, &second_permit);
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    try std.testing.expectError(error.StaleCustody, pool.binding(first));
    try std.testing.expectEqual(@as(u64, 2), (try pool.binding(second)).operation_id);
    try pool.detach(second);
    try pool.cleanupComplete(second);
}

test "custody attach consumes one permit only after validating its reservation" {
    var records: [2]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const first = pool.reserve().?;
    const second = pool.reserve().?;
    var permit = store.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    _ = try pool.attach(first, &permit);
    try std.testing.expectError(error.DispatchPermitConsumed, pool.attach(second, &permit));
    try pool.releaseUnused(second);

    var next_permit = store.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 1,
    } };
    const foreign = CustodyToken{ .index = records.len, .generation = 1 };
    try std.testing.expectError(error.ForeignCustody, pool.attach(foreign, &next_permit));
    try std.testing.expect(next_permit.available);
    try pool.detach(first);
    try pool.cleanupComplete(first);

    const reused = pool.reserve().?;
    try std.testing.expectError(error.StaleCustody, pool.attach(first, &next_permit));
    try std.testing.expect(next_permit.available);
    _ = try pool.attach(reused, &next_permit);
    try pool.detach(reused);
    try pool.cleanupComplete(reused);
}

test "unused reservation returns without an Attempt binding" {
    var records: [1]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    try pool.releaseUnused(token);
    try std.testing.expectEqual(@as(usize, 0), pool.occupied());
}
