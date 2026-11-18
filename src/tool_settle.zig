const std = @import("std");
const execution = @import("execution.zig");
const Host = @import("server_host.zig").Host;
const fenceDispatch = @import("server_host.zig").fenceDispatch;
const store = @import("store.zig");
const result_fault = @import("result_fault.zig");
const tool_record = @import("tool_record.zig");
const tool_result = @import("tool_result.zig");
const Value = tool_result.Value;

pub const Slot = struct {
    token: execution.CustodyToken,
    binding: store.ActionAttemptBinding,
    publication_phase: []const u8,
};

/// Core calls have no execution custody; attempt calls carry their claim token.
pub const Delivery = union(enum) {
    attempt: Slot,
    core: store.ActionAttemptBinding,
};

const Settlement = union(enum) {
    attempt: store.ActionSettlement,
    core: bool,
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
    fenceDispatch(host, phase, err);
    return .fenced;
}

/// The single Store settlement boundary for both delivery kinds. Core callers
/// propagate Store errors to their existing dispatch boundary; attempt callers
/// claim custody first and fence uncertain Store errors.
pub fn deliver(database: *store.Store, delivery: Delivery, code: store.ActionResolutionCode, value: Value, faults: store.Faults) !Settlement {
    return switch (delivery) {
        .core => |binding| .{ .core = switch (value) {
            .text => |text| switch (code) {
                .succeeded => try database.succeedCoreCall(binding, text, faults),
                .failed => try database.failCoreCall(binding, text, faults),
                else => unreachable,
            },
            .parts => unreachable,
        } },
        .attempt => |slot| .{ .attempt = switch (value) {
            .text => |text| try database.settleActionAttempt(slot.binding, code, text, faults),
            .parts => |loan| try database.settleActionAttemptParts(slot.binding, code, loan, faults),
        } },
    };
}

fn deliverAttempt(host: *Host, slot: Slot, code: store.ActionResolutionCode, value: Value, retained: ?*tool_result.Result) Delivered {
    var kept = false;
    defer if (retained) |result_value| result_value.settleRetention(kept);
    if (!host.custody.claimTerminalDelivery(slot.token)) return .lost;
    const settlement = deliver(host.store, .{ .attempt = slot }, code, value, host.hooks.storeFaults(.action_result)) catch |err| {
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

// Runners may use Store reads and effect transactions, but settlement is owned
// by this module. Restrict the check to production code above the first test.
test "core runners use the shared settlement boundary" {
    const sources = .{ @embedFile("read_action_tool.zig"), @embedFile("read_transcript.zig"), @embedFile("stop_action_tool.zig") };
    inline for (sources) |source| {
        const production = source[0..std.mem.indexOf(u8, source, "\ntest ").?];
        inline for (.{ "succeed" ++ "CoreCall", "fail" ++ "CoreCall", "resolve" ++ "CoreCall", "settle" ++ "ActionAttempt" }) |entry| {
            try std.testing.expect(std.mem.indexOf(u8, production, entry) == null);
        }
    }
}
