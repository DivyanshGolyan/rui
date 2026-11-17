const std = @import("std");
const execution = @import("execution.zig");
const Host = @import("server_host.zig").Host;
const fenceDispatch = @import("server_host.zig").fenceDispatch;
const store = @import("store.zig");
const result_fault = @import("result_fault.zig");
const tool_record = @import("tool_record.zig");
const Value = @import("tool_result.zig").Value;

pub const Slot = struct {
    token: execution.CustodyToken,
    binding: store.ActionAttemptBinding,
    publication_phase: []const u8,
};

pub const Delivered = enum { delivered, lost, fenced };

pub fn result(host: *Host, slot: Slot, profile: tool_record.Profile, code: store.ActionResolutionCode, value: Value) Delivered {
    // The profile belongs to the result route; layout and retention arrive in unit 4.
    _ = profile;
    return deliver(host, slot, code, value);
}

pub fn fixed(host: *Host, slot: Slot, code: store.ActionResolutionCode, text: []const u8) Delivered {
    return deliver(host, slot, code, .{ .text = text });
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
    fenceDispatch(host, phase, err);
    return .fenced;
}

fn deliver(host: *Host, slot: Slot, code: store.ActionResolutionCode, value: Value) Delivered {
    if (!host.custody.claimTerminalDelivery(slot.token)) return .lost;
    switch (value) {
        .text => |text| _ = host.store.settleActionAttempt(slot.binding, code, text, host.hooks.storeFaults(.action_result)) catch |err| {
            return fence(host, slot.publication_phase, .{ .store = err });
        },
        .parts => |loan| _ = host.store.settleActionAttemptParts(slot.binding, code, loan, host.hooks.storeFaults(.action_result)) catch |err| {
            return fence(host, slot.publication_phase, .{ .store = err });
        },
    }
    return .delivered;
}
