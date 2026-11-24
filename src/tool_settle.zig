const std = @import("std");
const execution = @import("execution.zig");
const Host = @import("server_host.zig").Host;
const store = @import("store.zig");
const result_fault = @import("result_fault.zig");
const tool_record = @import("tool_record.zig");
const tool_delivery = @import("tool_delivery.zig");
const tool_result = @import("tool_result.zig");
const Value = tool_delivery.Value;

pub const Slot = struct {
    token: execution.CustodyToken,
    binding: store.ActionAttemptBinding,
    publication_phase: []const u8,
};

pub const Delivered = enum { delivered, session_stop, lost, fenced };

pub fn result(host: *Host, slot: Slot, profile: tool_record.Profile, code: store.ActionResolutionCode, value: Value, retained: *tool_result.Result) Delivered {
    // Result uses this frozen profile for layout and retention before delivery.
    _ = profile;
    return deliverAttempt(host, slot, code, value, retained);
}

pub fn fixed(host: *Host, slot: Slot, code: store.ActionResolutionCode, text: []const u8) Delivered {
    return deliverAttempt(host, slot, code, .{ .text = text }, null);
}

pub fn message(host: *Host, slot: Slot, code: store.ActionResolutionCode, comptime fmt: []const u8, args: anytype) Delivered {
    var buffer: [256]u8 = undefined;
    return fixed(host, slot, code, std.fmt.bufPrint(&buffer, fmt, args) catch unreachable);
}

/// Rejections and control outcomes are decided at the adapter boundary.
pub fn failure(host: *Host, slot: Slot, phase: []const u8, fault: result_fault.Failure) Delivered {
    switch (result_fault.classify(fault)) {
        .storage_full => return fixed(host, slot, .storage_failed, result_fault.storage_failed_text),
        .suppressed => return .lost,
        .uncertain => {
            return fence(host, phase, fault);
        },
        .rejected, .superseded => unreachable,
    }
}

pub fn fence(host: *Host, phase: []const u8, fault: result_fault.Failure) Delivered {
    const err = switch (fault) {
        inline else => |value| value,
    };
    host.lifecycle.fenceDispatch(phase, err);
    return .fenced;
}

fn deliverAttempt(host: *Host, slot: Slot, code: store.ActionResolutionCode, value: Value, retained: ?*tool_result.Result) Delivered {
    var kept = false;
    defer if (retained) |result_value| result_value.settleRetention(kept);
    if (!host.custody.claimTerminalDelivery(slot.token)) return .lost;
    const settlement = tool_delivery.deliver(host.store, .{ .attempt = slot.binding }, code, value, host.probes.storeFaults(.action_result)) catch |err| {
        return fence(host, slot.publication_phase, .{ .store = err });
    };
    kept = settlement.attempt.kept;
    return fromSettlement(settlement.attempt);
}

fn fromSettlement(settlement: store.ActionSettlement) Delivered {
    return switch (settlement.outcome) {
        .effect => .delivered,
        .session_stop => .session_stop,
    };
}

test "shared settlement preserves session stop" {
    try std.testing.expectEqual(Delivered.delivered, fromSettlement(.{ .outcome = .effect, .kept = true }));
    try std.testing.expectEqual(Delivered.session_stop, fromSettlement(.{ .outcome = .session_stop, .kept = false }));
}
