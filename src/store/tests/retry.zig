//! Retry Store conformance tests.
const std = @import("std");
const retry_policy = @import("../../retry_policy.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const store_testing = @import("../testing.zig");
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;

test "retry settlement adds actual entropy after the provider deadline" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            // With no retry scheduled, the admission scan says so.
            var scheduled: ?u64 = 1;
            try std.testing.expect((try storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{}, &scheduled)) == null);
            try std.testing.expectEqual(@as(?u64, null), scheduled);
            const session = try configureTestSession(&storage, "jitter-config");
            try submitTestMessage(&storage, &tmp, "jitter-input", "jitter-message", session.slice(), "retry");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const Fixed = struct {
                fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
                    return .{ .nanoseconds = 31_000_000_000 };
                }
                fn random(_: ?*anyopaque, bytes: []u8) void {
                    const draw: u64 = 499;
                    @memcpy(bytes, std.mem.asBytes(&draw));
                }
            };
            var vtable = std.testing.io.vtable.*;
            vtable.now = Fixed.now;
            vtable.random = Fixed.random;
            storage.io.vtable = &vtable;
            defer storage.io = std.testing.io;
            try storage.settleModelAttemptFailure(binding, .{ .uncorrelated = "provider_temporary_http_429" }, .{ .retryable = .{
                .waits_ms = retry_policy.default_waits_ms,
                .retry_after_ms = 7_000,
                .retry_after_deadline_ms = 40_000,
            } }, .{});
            try std.testing.expectEqual(@as(u64, 40_500), try store_testing.queryU64(&storage, "SELECT retry_due_at_ms FROM model_operation", .{}));
            // Not due yet: the scan admits nothing and reads when the
            // earliest scheduled retry falls due, in its own round.
            const rounds = storage.testing_content_work.rounds;
            try std.testing.expect((try storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{}, &scheduled)) == null);
            try std.testing.expectEqual(@as(?u64, 40_500), scheduled);
            try std.testing.expectEqual(rounds + 1, storage.testing_content_work.rounds);
        }
    }.run);
}
