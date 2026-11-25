const std = @import("std");
const store = @import("store.zig");
const InputCapture = @import("InputCapture.zig");

/// The text or captured input a tool delivers as its Action result.
pub const Value = union(enum) { text: []const u8, parts: InputCapture.Loan };

/// Core calls have no execution custody; attempt calls carry their Store binding.
pub const Delivery = union(enum) {
    attempt: store.ActionAttemptBinding,
    core: store.ActionAttemptBinding,
};

pub const Settlement = union(enum) {
    attempt: store.ActionSettlement,
    core: bool,
};

/// The single Store settlement boundary for both delivery kinds. Core callers
/// propagate Store errors to their existing dispatch boundary; attempt callers
/// decide custody and fencing above this function.
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
        .attempt => |binding| .{ .attempt = switch (value) {
            .text => |text| try database.settleActionAttempt(binding, code, text, faults),
            .parts => |loan| try database.settleActionAttemptParts(binding, code, loan, faults),
        } },
    };
}

// Runners may use Store reads and effect transactions, but settlement is owned
// by this module. Restrict the check to production code above the first test.
test "core runners use the shared settlement boundary" {
    const sources = .{ @embedFile("read_transcript.zig"), @embedFile("stop_action_tool.zig") };
    inline for (sources) |source| {
        const production = source[0..std.mem.indexOf(u8, source, "\ntest ").?];
        inline for (.{ "succeed" ++ "CoreCall", "fail" ++ "CoreCall", "resolve" ++ "CoreCall", "settle" ++ "ActionAttempt" }) |entry| {
            try std.testing.expect(std.mem.indexOf(u8, production, entry) == null);
        }
    }
}
