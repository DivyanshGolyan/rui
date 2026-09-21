const std = @import("std");
const attempt = @import("attempt.zig");

pub const CustodyToken = struct {
    index: usize,
    generation: u64,
};

const State = enum(u8) { free, reserved, attached, detached };
const BindingKind = enum(u8) { model, action };

pub const CustodyRecord = struct {
    state: std.atomic.Value(State) = .init(.free),
    generation: std.atomic.Value(u64) = .init(0),
    delivered: std.atomic.Value(bool) = .init(false),
    launch_available: std.atomic.Value(bool) = .init(false),
    binding_kind: BindingKind = .model,
    binding: attempt.AttemptBinding = undefined,
    action_binding: attempt.ActionAttemptBinding = undefined,
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
        permit: *attempt.DispatchPermit,
    ) !attempt.AttemptBinding {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .reserved) return error.InvalidCustodyTransition;
        const attempt_binding = try permit.consume();
        record.binding = attempt_binding;
        record.binding_kind = .model;
        record.launch_available.store(true, .release);
        record.state.store(.attached, .release);
        return attempt_binding;
    }

    pub fn attachAction(
        self: *CustodyPool,
        token: CustodyToken,
        permit: *attempt.ActionDispatchPermit,
    ) !attempt.ActionAttemptBinding {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .reserved) return error.InvalidCustodyTransition;
        const action_binding = try permit.consume();
        record.action_binding = action_binding;
        record.binding_kind = .action;
        record.launch_available.store(true, .release);
        record.state.store(.attached, .release);
        return action_binding;
    }

    pub fn consumeLaunchAuthority(
        self: *CustodyPool,
        token: CustodyToken,
        attempt_binding: attempt.AttemptBinding,
    ) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached or record.binding_kind != .model or
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

    pub fn consumeActionLaunchAuthority(
        self: *CustodyPool,
        token: CustodyToken,
        action_binding: attempt.ActionAttemptBinding,
    ) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached or record.binding_kind != .action or
            record.action_binding.turn_id != action_binding.turn_id or
            record.action_binding.action_id != action_binding.action_id or
            record.action_binding.parent_operation_id != action_binding.parent_operation_id or
            record.action_binding.attempt_ordinal != action_binding.attempt_ordinal)
        {
            return error.ForeignLaunchAuthority;
        }
        if (record.launch_available.cmpxchgStrong(true, false, .acq_rel, .acquire) != null) {
            return error.DispatchPermitConsumed;
        }
    }

    pub fn binding(self: *CustodyPool, token: CustodyToken) !attempt.AttemptBinding {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached or record.binding_kind != .model) return error.CustodyDetached;
        return record.binding;
    }

    pub fn actionBinding(self: *CustodyPool, token: CustodyToken) !attempt.ActionAttemptBinding {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached or record.binding_kind != .action) return error.CustodyDetached;
        return record.action_binding;
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

    /// Custody-local structural checks. Each inspects the current
    /// production record without mutating it. Legal checkpoints are
    /// immediately after a complete custody operation, under the
    /// existing ownership discipline. Free and reserved records may
    /// retain historical binding fields; only the checked state,
    /// generation, kind, and identity must agree.
    pub fn checkReserved(self: *CustodyPool, token: CustodyToken) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .reserved) return error.InvalidCustodyTransition;
    }

    pub fn checkAttachedModel(
        self: *CustodyPool,
        token: CustodyToken,
        expected: attempt.AttemptBinding,
    ) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached) return error.InvalidCustodyTransition;
        if (record.binding_kind != .model) return error.CustodyDetached;
        if (record.binding.turn_id != expected.turn_id or
            record.binding.operation_id != expected.operation_id or
            record.binding.attempt_ordinal != expected.attempt_ordinal)
        {
            return error.ForeignLaunchAuthority;
        }
    }

    pub fn checkAttachedAction(
        self: *CustodyPool,
        token: CustodyToken,
        expected: attempt.ActionAttemptBinding,
    ) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached) return error.InvalidCustodyTransition;
        if (record.binding_kind != .action) return error.CustodyDetached;
        if (record.action_binding.turn_id != expected.turn_id or
            record.action_binding.action_id != expected.action_id or
            record.action_binding.parent_operation_id != expected.parent_operation_id or
            record.action_binding.attempt_ordinal != expected.attempt_ordinal)
        {
            return error.ForeignLaunchAuthority;
        }
    }

    pub fn checkDetached(self: *CustodyPool, token: CustodyToken) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .detached) return error.InvalidCustodyTransition;
    }

    pub fn checkFree(self: *CustodyPool, token: CustodyToken) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .free) return error.InvalidCustodyTransition;
    }

    pub fn canClaimTerminalDelivery(self: *CustodyPool, token: CustodyToken) bool {
        const record = self.current(token) catch return false;
        if (record.state.load(.acquire) != .attached) return false;
        return !record.delivered.load(.acquire);
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
    var first_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const first_binding = try pool.attach(first, &first_permit);
    try pool.checkAttachedModel(first, first_binding);
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.checkAttachedModel(first, .{ .turn_id = 1, .operation_id = 2, .attempt_ordinal = 1 }),
    );
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.consumeLaunchAuthority(first, .{ .turn_id = 1, .operation_id = 2, .attempt_ordinal = 1 }),
    );
    // Rejected launch leaves valid authority unconsumed.
    try pool.checkAttachedModel(first, first_binding);
    try pool.consumeLaunchAuthority(first, first_binding);
    try std.testing.expectError(
        error.DispatchPermitConsumed,
        pool.consumeLaunchAuthority(first, first_binding),
    );
    try std.testing.expect(pool.claimTerminalDelivery(first));
    try std.testing.expect(pool.canClaimTerminalDelivery(first) == false);
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    // Delivery is independent of launch: consuming launch twice still fails
    // after delivery, and delivery state does not restore launch authority.
    try std.testing.expectError(
        error.DispatchPermitConsumed,
        pool.consumeLaunchAuthority(first, first_binding),
    );
    try pool.detach(first);
    try pool.checkDetached(first);
    try std.testing.expectEqual(@as(usize, 1), pool.occupied());
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    try pool.cleanupComplete(first);

    const second = pool.reserve().?;
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    var second_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 1,
    } };
    _ = try pool.attach(second, &second_permit);
    try pool.checkAttachedModel(second, .{ .turn_id = 2, .operation_id = 2, .attempt_ordinal = 1 });
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    try std.testing.expectError(error.StaleCustody, pool.binding(first));
    try std.testing.expectError(error.StaleCustody, pool.checkAttachedModel(first, first_binding));
    try std.testing.expectError(error.StaleCustody, pool.checkDetached(first));
    try std.testing.expectEqual(@as(u64, 2), (try pool.binding(second)).operation_id);
    try pool.detach(second);
    try pool.cleanupComplete(second);
}

test "custody attach consumes one permit only after validating its reservation" {
    var records: [2]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const first = pool.reserve().?;
    const second = pool.reserve().?;
    try pool.checkReserved(first);
    try pool.checkReserved(second);
    // Capacity is exhausted.
    try std.testing.expect(pool.reserve() == null);
    try std.testing.expectEqual(@as(usize, 2), pool.occupied());
    var permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const attached = try pool.attach(first, &permit);
    try pool.checkAttachedModel(first, attached);
    try std.testing.expectError(error.DispatchPermitConsumed, pool.attach(second, &permit));
    // Rejected attachment leaves the reservation and its generation intact.
    try pool.checkReserved(second);
    try std.testing.expect(!permit.available);
    // A fresh permit still cannot attach to an already-attached record.
    var fresh = attempt.DispatchPermit{ .binding = .{
        .turn_id = 9,
        .operation_id = 9,
        .attempt_ordinal = 9,
    } };
    try std.testing.expectError(error.InvalidCustodyTransition, pool.attach(first, &fresh));
    try std.testing.expect(fresh.available);
    try pool.checkAttachedModel(first, attached);
    try pool.releaseUnused(second);
    try pool.checkFree(second);

    var next_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 1,
    } };
    const foreign = CustodyToken{ .index = records.len, .generation = 1 };
    try std.testing.expectError(error.ForeignCustody, pool.attach(foreign, &next_permit));
    try std.testing.expect(next_permit.available);
    try std.testing.expectError(error.ForeignCustody, pool.checkReserved(foreign));
    try pool.detach(first);
    try pool.checkDetached(first);
    try pool.cleanupComplete(first);
    try pool.checkFree(first);

    const reused = pool.reserve().?;
    try std.testing.expectError(error.StaleCustody, pool.attach(first, &next_permit));
    try std.testing.expect(next_permit.available);
    // Stale attach leaves the new reservation untouched.
    try pool.checkReserved(reused);
    const reused_binding = try pool.attach(reused, &next_permit);
    try pool.checkAttachedModel(reused, reused_binding);
    try pool.detach(reused);
    try pool.cleanupComplete(reused);
    try pool.checkFree(reused);
}

test "unused reservation returns without an Attempt binding" {
    var records: [1]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    try pool.checkReserved(token);
    try std.testing.expectError(error.InvalidCustodyTransition, pool.checkAttachedModel(token, .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    }));
    try std.testing.expectError(error.InvalidCustodyTransition, pool.detach(token));
    try std.testing.expectError(error.InvalidCustodyTransition, pool.cleanupComplete(token));
    try pool.releaseUnused(token);
    try pool.checkFree(token);
    try std.testing.expectEqual(@as(usize, 0), pool.occupied());
    // Releasing twice is rejected and leaves the slot free.
    try std.testing.expectError(error.InvalidCustodyTransition, pool.releaseUnused(token));
    try pool.checkFree(token);
}

test "model and Action Attempt bindings cannot cross custody paths" {
    var records: [2]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const model_token = pool.reserve().?;
    var model_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 2,
        .attempt_ordinal = 3,
    } };
    const model_binding = try pool.attach(model_token, &model_permit);
    try pool.checkAttachedModel(model_token, model_binding);
    try std.testing.expectError(error.CustodyDetached, pool.actionBinding(model_token));
    try std.testing.expectError(
        error.CustodyDetached,
        pool.checkAttachedAction(model_token, .{
            .turn_id = 1,
            .parent_operation_id = 2,
            .action_id = 4,
            .attempt_ordinal = 1,
        }),
    );

    const action_token = pool.reserve().?;
    var action_permit = attempt.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 2,
        .action_id = 4,
        .attempt_ordinal = 1,
    } };
    const action_binding = try pool.attachAction(action_token, &action_permit);
    try pool.checkAttachedAction(action_token, action_binding);
    try std.testing.expectError(error.CustodyDetached, pool.binding(action_token));
    try std.testing.expectError(
        error.CustodyDetached,
        pool.checkAttachedModel(action_token, model_binding),
    );
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.consumeLaunchAuthority(action_token, model_binding),
    );
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.consumeActionLaunchAuthority(model_token, action_binding),
    );
    // Valid bindings remain unchanged after cross-path rejection.
    try pool.checkAttachedModel(model_token, model_binding);
    try pool.checkAttachedAction(action_token, action_binding);

    try pool.detach(model_token);
    try pool.checkDetached(model_token);
    try pool.cleanupComplete(model_token);
    try pool.checkFree(model_token);
    try pool.detach(action_token);
    try pool.checkDetached(action_token);
    try pool.cleanupComplete(action_token);
    try pool.checkFree(action_token);
}

test "model launch authority requires every identity field" {
    var records: [1]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    var permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 7,
        .operation_id = 8,
        .attempt_ordinal = 9,
    } };
    const binding = try pool.attach(token, &permit);

    const variants = [_]attempt.AttemptBinding{
        .{ .turn_id = 70, .operation_id = 8, .attempt_ordinal = 9 },
        .{ .turn_id = 7, .operation_id = 80, .attempt_ordinal = 9 },
        .{ .turn_id = 7, .operation_id = 8, .attempt_ordinal = 90 },
    };
    for (variants) |mismatch| {
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.consumeLaunchAuthority(token, mismatch));
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.checkAttachedModel(token, mismatch));
    }
    // Each rejection leaves valid authority and the attached binding intact.
    try pool.checkAttachedModel(token, binding);
    try pool.consumeLaunchAuthority(token, binding);
    try std.testing.expectError(error.DispatchPermitConsumed, pool.consumeLaunchAuthority(token, binding));
    try pool.checkAttachedModel(token, binding);
    try pool.detach(token);
    try pool.cleanupComplete(token);
}

test "action launch authority requires every identity field including turn" {
    var records: [1]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    var permit = attempt.ActionDispatchPermit{ .binding = .{
        .turn_id = 7,
        .parent_operation_id = 8,
        .action_id = 9,
        .attempt_ordinal = 10,
    } };
    const binding = try pool.attachAction(token, &permit);

    const variants = [_]attempt.ActionAttemptBinding{
        .{ .turn_id = 70, .parent_operation_id = 8, .action_id = 9, .attempt_ordinal = 10 },
        .{ .turn_id = 7, .parent_operation_id = 80, .action_id = 9, .attempt_ordinal = 10 },
        .{ .turn_id = 7, .parent_operation_id = 8, .action_id = 90, .attempt_ordinal = 10 },
        .{ .turn_id = 7, .parent_operation_id = 8, .action_id = 9, .attempt_ordinal = 100 },
    };
    for (variants) |mismatch| {
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.consumeActionLaunchAuthority(token, mismatch));
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.checkAttachedAction(token, mismatch));
    }
    try pool.checkAttachedAction(token, binding);
    try pool.consumeActionLaunchAuthority(token, binding);
    try std.testing.expectError(error.DispatchPermitConsumed, pool.consumeActionLaunchAuthority(token, binding));
    try pool.checkAttachedAction(token, binding);
    try pool.detach(token);
    try pool.cleanupComplete(token);
}

test "detached custody rejects reuse until cleanup completes" {
    var records: [1]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    var permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const binding = try pool.attach(token, &permit);
    try pool.detach(token);
    try pool.checkDetached(token);
    try std.testing.expectEqual(@as(usize, 1), pool.occupied());
    // Detached records cannot be reserved, re-attached, released, or delivered.
    try std.testing.expect(pool.reserve() == null);
    var late_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 2,
    } };
    try std.testing.expectError(error.InvalidCustodyTransition, pool.attach(token, &late_permit));
    try std.testing.expect(late_permit.available);
    try std.testing.expectError(error.InvalidCustodyTransition, pool.releaseUnused(token));
    try std.testing.expect(!pool.claimTerminalDelivery(token));
    try std.testing.expect(!pool.canClaimTerminalDelivery(token));
    try std.testing.expectError(error.InvalidCustodyTransition, pool.checkAttachedModel(token, binding));
    try pool.checkDetached(token);
    try pool.cleanupComplete(token);
    try pool.checkFree(token);
    try std.testing.expectEqual(@as(usize, 0), pool.occupied());
}

test "bounded custody sequences preserve invariants after every operation" {
    // Success on one record: every completed operation re-checks.
    {
        var records: [1]CustodyRecord = undefined;
        var pool = CustodyPool.initialize(&records);
        const token = pool.reserve().?;
        try pool.checkReserved(token);
        var permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 } };
        const binding = try pool.attach(token, &permit);
        try pool.checkAttachedModel(token, binding);
        try std.testing.expect(pool.canClaimTerminalDelivery(token));
        try pool.consumeLaunchAuthority(token, binding);
        try pool.checkAttachedModel(token, binding);
        try std.testing.expect(pool.claimTerminalDelivery(token));
        try std.testing.expect(!pool.canClaimTerminalDelivery(token));
        try pool.detach(token);
        try pool.checkDetached(token);
        try std.testing.expectEqual(@as(usize, 1), pool.occupied());
        try pool.cleanupComplete(token);
        try pool.checkFree(token);
        try std.testing.expectEqual(@as(usize, 0), pool.occupied());
    }
    // Cancellation before attachment: the freed record rejects attachment
    // without consuming the fresh permit.
    {
        var records: [1]CustodyRecord = undefined;
        var pool = CustodyPool.initialize(&records);
        const token = pool.reserve().?;
        try pool.checkReserved(token);
        try pool.releaseUnused(token);
        try pool.checkFree(token);
        var permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 2, .operation_id = 2, .attempt_ordinal = 2 } };
        try std.testing.expectError(error.InvalidCustodyTransition, pool.attach(token, &permit));
        try std.testing.expect(permit.available);
        try pool.checkFree(token);
    }
    // Double claims then reuse: one-shot authority and delivery hold, and a
    // stale attach after reuse leaves the new reservation untouched.
    {
        var records: [1]CustodyRecord = undefined;
        var pool = CustodyPool.initialize(&records);
        const first = pool.reserve().?;
        var first_permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 3, .operation_id = 3, .attempt_ordinal = 3 } };
        const first_binding = try pool.attach(first, &first_permit);
        try pool.consumeLaunchAuthority(first, first_binding);
        try std.testing.expectError(error.DispatchPermitConsumed, pool.consumeLaunchAuthority(first, first_binding));
        try pool.checkAttachedModel(first, first_binding);
        try std.testing.expect(pool.claimTerminalDelivery(first));
        try std.testing.expect(!pool.claimTerminalDelivery(first));
        try pool.detach(first);
        try pool.cleanupComplete(first);
        const second = pool.reserve().?;
        try std.testing.expectEqual(first.index, second.index);
        try std.testing.expectError(error.StaleCustody, pool.attach(first, &first_permit));
        try pool.checkReserved(second);
        var second_permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 4, .operation_id = 4, .attempt_ordinal = 4 } };
        const second_binding = try pool.attach(second, &second_permit);
        try pool.checkAttachedModel(second, second_binding);
        try pool.detach(second);
        try pool.cleanupComplete(second);
    }
    // Two-record interference: a consumed permit cannot attach the sibling,
    // and detaching one record leaves the other attached.
    {
        var records: [2]CustodyRecord = undefined;
        var pool = CustodyPool.initialize(&records);
        const first = pool.reserve().?;
        const second = pool.reserve().?;
        var first_permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 5, .operation_id = 5, .attempt_ordinal = 5 } };
        const first_binding = try pool.attach(first, &first_permit);
        try std.testing.expectError(error.DispatchPermitConsumed, pool.attach(second, &first_permit));
        try pool.checkReserved(second);
        var second_permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 6, .operation_id = 6, .attempt_ordinal = 6 } };
        const second_binding = try pool.attach(second, &second_permit);
        try pool.checkAttachedModel(first, first_binding);
        try pool.checkAttachedModel(second, second_binding);
        try pool.detach(first);
        try pool.checkDetached(first);
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.consumeLaunchAuthority(first, first_binding));
        try pool.checkAttachedModel(second, second_binding);
        try pool.cleanupComplete(first);
        try pool.checkFree(first);
        try pool.checkAttachedModel(second, second_binding);
        try pool.detach(second);
        try pool.cleanupComplete(second);
        try std.testing.expectEqual(@as(usize, 0), pool.occupied());
    }
}

test "stale tokens after reuse leave the new owner unchanged" {
    var records: [1]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const first = pool.reserve().?;
    var first_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const first_binding = try pool.attach(first, &first_permit);
    try pool.consumeLaunchAuthority(first, first_binding);
    try std.testing.expect(pool.claimTerminalDelivery(first));
    try pool.detach(first);
    try pool.cleanupComplete(first);

    const second = pool.reserve().?;
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    var second_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 2,
        .operation_id = 2,
        .attempt_ordinal = 2,
    } };
    const second_binding = try pool.attach(second, &second_permit);

    // Every old-token operation fails without touching the new owner.
    try std.testing.expectError(error.StaleCustody, pool.consumeLaunchAuthority(first, first_binding));
    try std.testing.expectError(error.StaleCustody, pool.binding(first));
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    try std.testing.expectError(error.StaleCustody, pool.detach(first));
    try std.testing.expectError(error.StaleCustody, pool.cleanupComplete(first));
    try std.testing.expectError(error.StaleCustody, pool.releaseUnused(first));
    try std.testing.expectError(error.StaleCustody, pool.checkAttachedModel(first, first_binding));
    try pool.checkAttachedModel(second, second_binding);
    try std.testing.expect(pool.canClaimTerminalDelivery(second));
    try std.testing.expectEqual(@as(usize, 1), pool.occupied());
    try pool.detach(second);
    try pool.cleanupComplete(second);
}

test "failed reclamation keeps custody occupied until the same owner succeeds" {
    const named_scratch = @import("named_scratch.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const primary = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    var used: std.atomic.Value(u64) = .init(4);
    var gate: std.atomic.Value(bool) = .init(true);
    var records: [1]CustodyRecord = undefined;
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    var permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    _ = try pool.attach(token, &permit);
    try pool.detach(token);
    var owner = named_scratch.Owner.init(
        std.testing.io,
        primary,
        null,
        "owned",
        .{ .used = &used, .limit = 4 },
        4,
        .{ .gated = &gate },
    );
    var root_buffer: [4096]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var reclaimed = false;
    errdefer if (!reclaimed) {
        gate.store(false, .release);
        _ = owner.reclaim(root) catch {};
        pool.cleanupComplete(token) catch {};
    };

    try std.testing.expectError(
        error.InjectedScratchRemovalFailure,
        owner.reclaim(root),
    );
    try pool.checkDetached(token);
    try std.testing.expectEqual(@as(usize, 1), pool.occupied());
    try std.testing.expectEqual(@as(u64, 4), used.load(.acquire));

    gate.store(false, .release);
    try std.testing.expectEqual(named_scratch.Reclamation.removed, try owner.reclaim(root));
    try pool.cleanupComplete(token);
    reclaimed = true;
    try pool.checkFree(token);
    try std.testing.expectEqual(@as(usize, 0), pool.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}
