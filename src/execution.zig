const std = @import("std");
const attempt = @import("attempt.zig");
const transport_policy = @import("transport_policy.zig");

const CaptureFailure = transport_policy.CaptureFailure;
const TransferOutcome = transport_policy.TransferOutcome;

/// How a failed model Attempt settles: the Store owns the retry allowance.
pub const FailureKind = enum { permanent, temporary, context_overflow };

/// A sealed HTTP error answer, interpreted before settlement.
pub const ErrorResponse = union(enum) { ordinary, context_overflow, quota: transport_policy.Quota, refusal: transport_policy.Refusal, unreadable: anyerror };

pub const TransferFailure = struct {
    code: union(enum) { named: []const u8, http: u16, temporary_http: u16 },
    answered: bool = false,
    kind: FailureKind = .permanent,
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
    quota: ?transport_policy.Quota = null,

    pub fn codeText(self: TransferFailure, buffer: *[96]u8) []const u8 {
        return switch (self.code) {
            .named => |code| code,
            .http => |status| std.fmt.bufPrint(buffer, "provider_http_{d}", .{status}) catch unreachable,
            .temporary_http => |status| std.fmt.bufPrint(buffer, "provider_temporary_http_{d}", .{status}) catch unreachable,
        };
    }
};

pub const TransferDecision = union(enum) {
    interpret_output,
    fence_request_source,
    fail: TransferFailure,
};

/// Failure facts only: Store owns retry allowance, eligibility and Turn
/// scheduling. No decision here delivers a result or releases resources.
pub fn transferDecision(
    outcome: TransferOutcome,
    error_response: ErrorResponse,
) TransferDecision {
    const evidence = switch (outcome) {
        .response_capture_failed => |failure| return .{ .fail = .{ .code = .{ .named = switch (failure) {
            .scratch_exhausted => "response_scratch_exhausted",
            .write_failed => "response_write_failed",
            .seal_failed => "response_seal_failed",
        } } } },
        .request_source_failed => return .fence_request_source,
        .transport_finished => |evidence| evidence,
    };
    if (evidence.disposition == .success) return .interpret_output;
    const answered = evidence.disposition.answered();
    if (answered) switch (error_response) {
        .context_overflow => return .{ .fail = .{
            .code = .{ .named = "provider_context_overflow" },
            .answered = true,
            .kind = .context_overflow,
        } },
        .quota => |quota| return .{ .fail = .{
            .code = .{ .named = quota.failureCode() },
            .answered = true,
            .quota = quota,
        } },
        // The code decides, whatever the status: resending cannot fix it.
        .refusal => |refusal| return .{ .fail = .{
            .code = .{ .named = refusal.failureCode() },
            .answered = true,
        } },
        .unreadable => return .{ .fail = .{
            .code = .{ .named = "response_read_failed" },
            .answered = true,
        } },
        .ordinary => {},
    };
    const temporary = evidence.disposition == .temporary_http or evidence.disposition == .temporary_connection;
    return .{ .fail = .{
        .code = switch (evidence.disposition) {
            .success => unreachable,
            .permanent_http => .{ .http = evidence.http_status },
            .temporary_http => .{ .temporary_http = evidence.http_status },
            .temporary_connection => .{ .named = "provider_transport_failure" },
            .permanent_transport => .{ .named = "provider_transport_permanent" },
            .unsupported_http_version => .{ .named = "provider_http2_required" },
            .tls_verification_failure => .{ .named = "provider_tls_verification_failed" },
            .invalid_headers => .{ .named = "invalid_provider_headers" },
        },
        .answered = answered,
        .kind = if (temporary) .temporary else .permanent,
        .retry_after_ms = if (temporary) evidence.retry_after_ms else null,
        .retry_after_deadline_ms = if (temporary) evidence.retry_after_deadline_ms else null,
    } };
}

/// Only the model endpoint's own HTTP 401 answer may spend an Operation's
/// one forced credential refresh. Every other status settles as it is.
pub fn rejectsCredential(failure: TransferFailure) bool {
    return failure.answered and failure.code == .http and failure.code.http == 401;
}

test "only an answered model 401 can claim a forced credential refresh" {
    const finished = struct {
        fn outcome(disposition: transport_policy.Disposition, status: u16) TransferOutcome {
            return .{ .transport_finished = .{ .disposition = disposition, .http_status = status } };
        }
    }.outcome;
    try std.testing.expect(rejectsCredential(transferDecision(finished(.permanent_http, 401), .ordinary).fail));
    try std.testing.expect(!rejectsCredential(transferDecision(finished(.permanent_http, 403), .ordinary).fail));
    try std.testing.expect(!rejectsCredential(transferDecision(finished(.permanent_http, 401), .{ .unreadable = error.TestUnreadable }).fail));
    try std.testing.expect(!rejectsCredential(transferDecision(finished(.temporary_http, 503), .ordinary).fail));
}

const testing_error_responses = [_]ErrorResponse{ .ordinary, .context_overflow, .{ .refusal = .model_not_found }, .{ .unreadable = error.TestUnreadable } };

test "HTTP quota refusal overrides rate limit retry evidence and retains reset detail" {
    const codes = [_][]const u8{ "provider_usage_limit_reached", "provider_insufficient_quota", "provider_usage_not_included" };
    const details = [_][]const u8{
        "{\"provider_code\":\"usage_limit_reached\",\"resets_at\":1800000123}",
        "{\"provider_code\":\"insufficient_quota\",\"resets_at\":1800000123}",
        "{\"provider_code\":\"usage_not_included\",\"resets_at\":1800000123}",
    };
    for (transport_policy.Quota.codes, codes, details) |code, expected, detail| {
        const quota: transport_policy.Quota = .{ .code = code, .resets_at = 1_800_000_123 };
        const refusal: ErrorResponse = .{ .quota = quota };
        const decision = transferDecision(.{ .transport_finished = .{
            .disposition = .temporary_http,
            .http_status = 429,
            .retry_after_ms = 12_000,
            .retry_after_deadline_ms = 99_000,
        } }, refusal);
        var buffer: [96]u8 = undefined;
        var diagnostic: [512]u8 = undefined;
        try std.testing.expectEqualStrings(expected, decision.fail.codeText(&buffer));
        try std.testing.expectEqual(.permanent, decision.fail.kind);
        try std.testing.expect(decision.fail.answered);
        try std.testing.expect(decision.fail.retry_after_ms == null);
        try std.testing.expect(decision.fail.retry_after_deadline_ms == null);
        try std.testing.expectEqualStrings(detail, decision.fail.quota.?.format(&diagnostic));
        // A body cannot override a failed transport or a successful status.
        try std.testing.expect(transferDecision(.{ .transport_finished = .{ .disposition = .success } }, refusal) == .interpret_output);
        const connection = transferDecision(.{ .transport_finished = .{ .disposition = .temporary_connection } }, refusal).fail;
        try std.testing.expectEqual(.temporary, connection.kind);
        try std.testing.expect(connection.quota == null);
    }
    var diagnostic: [512]u8 = undefined;
    const absent: transport_policy.Quota = .{ .code = .usage_limit_reached };
    try std.testing.expectEqualStrings("{\"provider_code\":\"usage_limit_reached\",\"resets_at\":null}", absent.format(&diagnostic));
}

test "transfer decisions exhaust transport dispositions and error response precedence" {
    const cases = [_]struct {
        disposition: transport_policy.Disposition,
        status: u16 = 0,
        code: []const u8,
        answered: bool = false,
        temporary: bool = false,
    }{
        .{ .disposition = .permanent_http, .status = 418, .code = "provider_http_418", .answered = true },
        .{ .disposition = .temporary_http, .status = 503, .code = "provider_temporary_http_503", .answered = true, .temporary = true },
        .{ .disposition = .temporary_connection, .code = "provider_transport_failure", .temporary = true },
        .{ .disposition = .permanent_transport, .code = "provider_transport_permanent" },
        .{ .disposition = .tls_verification_failure, .code = "provider_tls_verification_failed" },
        .{ .disposition = .invalid_headers, .code = "invalid_provider_headers" },
        .{ .disposition = .unsupported_http_version, .code = "provider_http2_required" },
    };
    try std.testing.expectEqual(std.enums.values(transport_policy.Disposition).len - 1, cases.len);
    for (testing_error_responses) |response| {
        try std.testing.expect(transferDecision(.{ .transport_finished = .{ .disposition = .success } }, response) == .interpret_output);
        for (cases) |case| {
            const decision = transferDecision(.{ .transport_finished = .{
                .disposition = case.disposition,
                .http_status = case.status,
                .retry_after_ms = 137,
                .retry_after_deadline_ms = 901,
            } }, response);
            try std.testing.expect(decision == .fail);
            const failure = decision.fail;
            var buffer: [96]u8 = undefined;
            const overflow = case.answered and response == .context_overflow;
            const unreadable = case.answered and response == .unreadable;
            const refused = case.answered and response == .refusal;
            const temporary = case.temporary and !overflow and !unreadable and !refused;
            const expected_code = if (overflow) "provider_context_overflow" else if (unreadable) "response_read_failed" else if (refused) "provider_model_not_found" else case.code;
            try std.testing.expectEqualStrings(expected_code, failure.codeText(&buffer));
            try std.testing.expectEqual(case.answered, failure.answered);
            try std.testing.expectEqual(overflow, failure.kind == .context_overflow);
            try std.testing.expectEqual(temporary, failure.kind == .temporary);
            try std.testing.expectEqual(!overflow and !temporary, failure.kind == .permanent);
            try std.testing.expectEqual(if (temporary) @as(?u64, 137) else null, failure.retry_after_ms);
            try std.testing.expectEqual(if (temporary) @as(?i64, 901) else null, failure.retry_after_deadline_ms);
        }
    }
}

test "transfer decisions never correlate capture failure or settle request source corruption" {
    for (testing_error_responses) |response| {
        try std.testing.expect(transferDecision(.request_source_failed, response) == .fence_request_source);
        for (std.enums.values(CaptureFailure), [_][]const u8{ "response_scratch_exhausted", "response_write_failed", "response_seal_failed" }) |capture, expected| {
            const decision = transferDecision(.{ .response_capture_failed = capture }, response);
            try std.testing.expect(decision == .fail);
            var buffer: [96]u8 = undefined;
            try std.testing.expectEqualStrings(expected, decision.fail.codeText(&buffer));
            try std.testing.expect(!decision.fail.answered);
            try std.testing.expectEqual(.permanent, decision.fail.kind);
            try std.testing.expect(decision.fail.retry_after_ms == null);
            try std.testing.expect(decision.fail.retry_after_deadline_ms == null);
        }
    }
}

/// One model owner's next work, derived from native owner facts, never stored
/// as a second lifecycle. Decisions grant neither Store settlement authority
/// nor permission to reuse custody before the indicated disposal succeeds.
pub const ModelObservation = union(enum) {
    preparing: struct { launch_allowed: bool },
    prepared: struct { authentication_required: bool },
    preparation_failed: struct {
        retained_scratch: bool,
        canonical_fenced: bool,
        superseded: bool,
    },
    authenticating: struct {
        cancelled: bool,
        launch_allowed: bool,
        result: enum { pending, ready, failed },
    },
    handoff_failed: enum { suppressed, superseded, unexpected },
};

pub const ModelDecision = enum {
    wait,
    advance_preparation,
    authenticate,
    launch,
    settle_preparation_failure,
    settle_authentication_failure,
    abandon,
    fence,
    retain_cleanup,
};

pub fn modelDecision(observation: ModelObservation) ModelDecision {
    return switch (observation) {
        .preparing => |value| if (value.launch_allowed) .advance_preparation else .abandon,
        .prepared => |value| if (value.authentication_required) .authenticate else .launch,
        .preparation_failed => |value| if (value.retained_scratch)
            .retain_cleanup
        else if (value.canonical_fenced)
            .fence
        else if (value.superseded)
            .abandon
        else
            .settle_preparation_failure,
        .authenticating => |value| switch (value.result) {
            // Cancellation cannot dispose a request still owned by this stage
            // until the authentication worker has returned its result.
            .pending => .wait,
            .ready => if (!value.cancelled and value.launch_allowed) .launch else .abandon,
            // Preserve known failure delivery even if local launch is fenced;
            // Store still rechecks applicability. A control suppresses both.
            .failed => if (value.cancelled) .abandon else .settle_authentication_failure,
        },
        .handoff_failed => |value| switch (value) {
            .suppressed, .superseded => .abandon,
            .unexpected => .fence,
        },
    };
}

pub const CustodyToken = struct {
    index: usize,
    generation: u64,
};

const State = enum(u8) { free, reserved, attached, detached };

/// The Attempt a custody record holds: a model Attempt or an Action's.
pub const CustodyBinding = union(enum) {
    model: attempt.AttemptBinding,
    action: attempt.ActionAttemptBinding,

    fn of(binding: anytype) CustodyBinding {
        return switch (@TypeOf(binding)) {
            attempt.AttemptBinding => .{ .model = binding },
            attempt.ActionAttemptBinding => .{ .action = binding },
            else => @compileError("not an Attempt binding: " ++ @typeName(@TypeOf(binding))),
        };
    }
};

pub const CustodyRecord = struct {
    state: std.atomic.Value(State) = .init(.free),
    generation: std.atomic.Value(u64) = .init(0),
    delivered: std.atomic.Value(bool) = .init(false),
    launch_available: std.atomic.Value(bool) = .init(false),
    binding: CustodyBinding = undefined,
};

pub const CustodyPool = struct {
    records: []CustodyRecord,

    /// Records start empty, as `.{}` or all zero bytes, so fresh pages
    /// need no initializing pass and an unused record never becomes resident.
    pub fn initialize(records: []CustodyRecord) CustodyPool {
        for (records) |*record| std.debug.assert(record.state.load(.monotonic) == .free);
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

    /// Consumes a model or Action dispatch permit into the reserved record
    /// and returns the permit's binding.
    pub fn attach(
        self: *CustodyPool,
        token: CustodyToken,
        permit: anytype,
    ) !@TypeOf(permit.binding) {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .reserved) return error.InvalidCustodyTransition;
        const attempt_binding = try permit.consume();
        record.binding = .of(attempt_binding);
        record.launch_available.store(true, .release);
        record.state.store(.attached, .release);
        return attempt_binding;
    }

    pub fn consumeLaunchAuthority(
        self: *CustodyPool,
        token: CustodyToken,
        expected: CustodyBinding,
    ) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached or !std.meta.eql(record.binding, expected)) {
            return error.ForeignLaunchAuthority;
        }
        if (record.launch_available.cmpxchgStrong(true, false, .acq_rel, .acquire) != null) {
            return error.DispatchPermitConsumed;
        }
    }

    pub fn binding(self: *CustodyPool, token: CustodyToken) !CustodyBinding {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached) return error.CustodyDetached;
        return record.binding;
    }

    pub fn claimTerminalDelivery(self: *CustodyPool, token: CustodyToken) bool {
        const record = self.current(token) catch return false;
        if (record.state.load(.acquire) != .attached) return false;
        return record.delivered.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    }

    /// An attached Action whose terminal delivery nobody claimed: detaching
    /// it leaves the Action unsettled.
    pub fn holdsUndeliveredAction(self: *CustodyPool, token: CustodyToken) bool {
        const record = self.current(token) catch return false;
        return record.state.load(.acquire) == .attached and record.binding == .action and
            !record.delivered.load(.acquire);
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

    pub fn checkAttached(self: *CustodyPool, token: CustodyToken, expected: CustodyBinding) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .attached) return error.InvalidCustodyTransition;
        try checkBinding(record, expected);
    }

    /// A null `expected` checks only that the token's record is detached,
    /// for retained owners that keep no Attempt identity.
    pub fn checkDetached(self: *CustodyPool, token: CustodyToken, expected: ?CustodyBinding) !void {
        const record = try self.current(token);
        if (record.state.load(.acquire) != .detached) return error.InvalidCustodyTransition;
        if (expected) |value| try checkBinding(record, value);
    }

    fn checkBinding(record: *const CustodyRecord, expected: CustodyBinding) !void {
        if (std.meta.activeTag(record.binding) != std.meta.activeTag(expected)) return error.CustodyDetached;
        if (!std.meta.eql(record.binding, expected)) return error.ForeignLaunchAuthority;
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

    /// Custody an Attempt holds: attached for execution or detached for
    /// cleanup. Unlike `occupied`, excludes the execution owner's in-flight
    /// admission reservation, so concurrent observers see no phantom custody
    /// while it probes capacity. A just-committed Attempt is therefore not
    /// counted until the owner attaches it, without blocking in between.
    pub fn held(self: *const CustodyPool) usize {
        var count: usize = 0;
        for (self.records) |*record| {
            switch (record.state.load(.acquire)) {
                .attached, .detached => count += 1,
                .free, .reserved => {},
            }
        }
        return count;
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
    var records: [1]CustodyRecord = @splat(.{});
    var pool = CustodyPool.initialize(&records);
    const first = pool.reserve().?;
    var first_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const first_binding = try pool.attach(first, &first_permit);
    try pool.checkAttached(first, .{ .model = first_binding });
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.checkAttached(first, .{ .model = .{ .turn_id = 1, .operation_id = 2, .attempt_ordinal = 1 } }),
    );
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.consumeLaunchAuthority(first, .{ .model = .{ .turn_id = 1, .operation_id = 2, .attempt_ordinal = 1 } }),
    );
    // Rejected launch leaves valid authority unconsumed.
    try pool.checkAttached(first, .{ .model = first_binding });
    try pool.consumeLaunchAuthority(first, .{ .model = first_binding });
    try std.testing.expectError(
        error.DispatchPermitConsumed,
        pool.consumeLaunchAuthority(first, .{ .model = first_binding }),
    );
    try std.testing.expect(pool.claimTerminalDelivery(first));
    try std.testing.expect(pool.canClaimTerminalDelivery(first) == false);
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    // Delivery is independent of launch: consuming launch twice still fails
    // after delivery, and delivery state does not restore launch authority.
    try std.testing.expectError(
        error.DispatchPermitConsumed,
        pool.consumeLaunchAuthority(first, .{ .model = first_binding }),
    );
    try pool.detach(first);
    try pool.checkDetached(first, null);
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
    try pool.checkAttached(second, .{ .model = .{ .turn_id = 2, .operation_id = 2, .attempt_ordinal = 1 } });
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    try std.testing.expectError(error.StaleCustody, pool.binding(first));
    try std.testing.expectError(error.StaleCustody, pool.checkAttached(first, .{ .model = first_binding }));
    try std.testing.expectError(error.StaleCustody, pool.checkDetached(first, null));
    try std.testing.expectEqual(@as(u64, 2), (try pool.binding(second)).model.operation_id);
    try pool.detach(second);
    try pool.cleanupComplete(second);
}

test "custody attach consumes one permit only after validating its reservation" {
    var records: [2]CustodyRecord = @splat(.{});
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
    try pool.checkAttached(first, .{ .model = attached });
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
    try pool.checkAttached(first, .{ .model = attached });
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
    try pool.checkDetached(first, null);
    try pool.cleanupComplete(first);
    try pool.checkFree(first);

    const reused = pool.reserve().?;
    try std.testing.expectError(error.StaleCustody, pool.attach(first, &next_permit));
    try std.testing.expect(next_permit.available);
    // Stale attach leaves the new reservation untouched.
    try pool.checkReserved(reused);
    const reused_binding = try pool.attach(reused, &next_permit);
    try pool.checkAttached(reused, .{ .model = reused_binding });
    try pool.detach(reused);
    try pool.cleanupComplete(reused);
    try pool.checkFree(reused);
}

test "unused reservation returns without an Attempt binding" {
    var records: [1]CustodyRecord = @splat(.{});
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    try pool.checkReserved(token);
    try std.testing.expectError(error.InvalidCustodyTransition, pool.checkAttached(token, .{ .model = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } }));
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
    var records: [2]CustodyRecord = @splat(.{});
    var pool = CustodyPool.initialize(&records);
    const model_token = pool.reserve().?;
    var model_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 2,
        .attempt_ordinal = 3,
    } };
    const model_binding = try pool.attach(model_token, &model_permit);
    try pool.checkAttached(model_token, .{ .model = model_binding });
    try std.testing.expect(try pool.binding(model_token) == .model);
    try std.testing.expectError(
        error.CustodyDetached,
        pool.checkAttached(model_token, .{ .action = .{
            .turn_id = 1,
            .parent_operation_id = 2,
            .action_id = 4,
        } }),
    );

    const action_token = pool.reserve().?;
    var action_permit = attempt.ActionDispatchPermit{ .binding = .{
        .turn_id = 1,
        .parent_operation_id = 2,
        .action_id = 4,
    } };
    const action_binding = try pool.attach(action_token, &action_permit);
    try pool.checkAttached(action_token, .{ .action = action_binding });
    try std.testing.expect(try pool.binding(action_token) == .action);
    try std.testing.expectError(
        error.CustodyDetached,
        pool.checkAttached(action_token, .{ .model = model_binding }),
    );
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.consumeLaunchAuthority(action_token, .{ .model = model_binding }),
    );
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.consumeLaunchAuthority(model_token, .{ .action = action_binding }),
    );
    // Valid bindings remain unchanged after cross-path rejection.
    try pool.checkAttached(model_token, .{ .model = model_binding });
    try pool.checkAttached(action_token, .{ .action = action_binding });

    try pool.detach(model_token);
    try pool.checkDetached(model_token, null);
    try pool.checkDetached(model_token, .{ .model = model_binding });
    try std.testing.expectError(
        error.CustodyDetached,
        pool.checkDetached(model_token, .{ .action = action_binding }),
    );
    try pool.cleanupComplete(model_token);
    try pool.checkFree(model_token);
    try pool.detach(action_token);
    try pool.checkDetached(action_token, null);
    try pool.checkDetached(action_token, .{ .action = action_binding });
    try pool.cleanupComplete(action_token);
    try pool.checkFree(action_token);
}

test "model launch authority requires every identity field" {
    var records: [1]CustodyRecord = @splat(.{});
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
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.consumeLaunchAuthority(token, .{ .model = mismatch }));
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.checkAttached(token, .{ .model = mismatch }));
    }
    // Each rejection leaves valid authority and the attached binding intact.
    try pool.checkAttached(token, .{ .model = binding });
    try pool.consumeLaunchAuthority(token, .{ .model = binding });
    try std.testing.expectError(error.DispatchPermitConsumed, pool.consumeLaunchAuthority(token, .{ .model = binding }));
    try pool.checkAttached(token, .{ .model = binding });
    try pool.detach(token);
    try pool.cleanupComplete(token);
}

test "action launch authority requires every identity field including turn" {
    var records: [1]CustodyRecord = @splat(.{});
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    var permit = attempt.ActionDispatchPermit{ .binding = .{
        .turn_id = 7,
        .parent_operation_id = 8,
        .action_id = 9,
    } };
    const binding = try pool.attach(token, &permit);

    const variants = [_]attempt.ActionAttemptBinding{
        .{ .turn_id = 70, .parent_operation_id = 8, .action_id = 9 },
        .{ .turn_id = 7, .parent_operation_id = 80, .action_id = 9 },
        .{ .turn_id = 7, .parent_operation_id = 8, .action_id = 90 },
    };
    for (variants) |mismatch| {
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.consumeLaunchAuthority(token, .{ .action = mismatch }));
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.checkAttached(token, .{ .action = mismatch }));
    }
    try pool.checkAttached(token, .{ .action = binding });
    try pool.consumeLaunchAuthority(token, .{ .action = binding });
    try std.testing.expectError(error.DispatchPermitConsumed, pool.consumeLaunchAuthority(token, .{ .action = binding }));
    try pool.checkAttached(token, .{ .action = binding });
    try pool.detach(token);
    try pool.checkDetached(token, null);
    try pool.checkDetached(token, .{ .action = binding });
    try std.testing.expectError(
        error.ForeignLaunchAuthority,
        pool.checkDetached(token, .{ .action = .{
            .turn_id = 7,
            .parent_operation_id = 8,
            .action_id = 90,
        } }),
    );
    try std.testing.expectError(
        error.CustodyDetached,
        pool.checkDetached(token, .{ .model = .{ .turn_id = 7, .operation_id = 8, .attempt_ordinal = 10 } }),
    );
    try pool.checkDetached(token, .{ .action = binding });
    try pool.cleanupComplete(token);
}

test "detached custody rejects reuse until cleanup completes" {
    var records: [1]CustodyRecord = @splat(.{});
    var pool = CustodyPool.initialize(&records);
    const token = pool.reserve().?;
    var permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const binding = try pool.attach(token, &permit);
    try pool.detach(token);
    try pool.checkDetached(token, null);
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
    try std.testing.expectError(error.InvalidCustodyTransition, pool.checkAttached(token, .{ .model = binding }));
    try pool.checkDetached(token, null);
    try pool.cleanupComplete(token);
    try pool.checkFree(token);
    try std.testing.expectEqual(@as(usize, 0), pool.occupied());
}

test "bounded custody sequences preserve invariants after every operation" {
    // Success on one record: every completed operation re-checks.
    {
        var records: [1]CustodyRecord = @splat(.{});
        var pool = CustodyPool.initialize(&records);
        const token = pool.reserve().?;
        try pool.checkReserved(token);
        var permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 1, .operation_id = 1, .attempt_ordinal = 1 } };
        const binding = try pool.attach(token, &permit);
        try pool.checkAttached(token, .{ .model = binding });
        try std.testing.expect(pool.canClaimTerminalDelivery(token));
        try pool.consumeLaunchAuthority(token, .{ .model = binding });
        try pool.checkAttached(token, .{ .model = binding });
        try std.testing.expect(pool.claimTerminalDelivery(token));
        try std.testing.expect(!pool.canClaimTerminalDelivery(token));
        try pool.detach(token);
        try pool.checkDetached(token, null);
        try std.testing.expectEqual(@as(usize, 1), pool.occupied());
        try pool.cleanupComplete(token);
        try pool.checkFree(token);
        try std.testing.expectEqual(@as(usize, 0), pool.occupied());
    }
    // Cancellation before attachment: the freed record rejects attachment
    // without consuming the fresh permit.
    {
        var records: [1]CustodyRecord = @splat(.{});
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
        var records: [1]CustodyRecord = @splat(.{});
        var pool = CustodyPool.initialize(&records);
        const first = pool.reserve().?;
        var first_permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 3, .operation_id = 3, .attempt_ordinal = 3 } };
        const first_binding = try pool.attach(first, &first_permit);
        try pool.consumeLaunchAuthority(first, .{ .model = first_binding });
        try std.testing.expectError(error.DispatchPermitConsumed, pool.consumeLaunchAuthority(first, .{ .model = first_binding }));
        try pool.checkAttached(first, .{ .model = first_binding });
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
        try pool.checkAttached(second, .{ .model = second_binding });
        try pool.detach(second);
        try pool.cleanupComplete(second);
    }
    // Two-record interference: a consumed permit cannot attach the sibling,
    // and detaching one record leaves the other attached.
    {
        var records: [2]CustodyRecord = @splat(.{});
        var pool = CustodyPool.initialize(&records);
        const first = pool.reserve().?;
        const second = pool.reserve().?;
        var first_permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 5, .operation_id = 5, .attempt_ordinal = 5 } };
        const first_binding = try pool.attach(first, &first_permit);
        try std.testing.expectError(error.DispatchPermitConsumed, pool.attach(second, &first_permit));
        try pool.checkReserved(second);
        var second_permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 6, .operation_id = 6, .attempt_ordinal = 6 } };
        const second_binding = try pool.attach(second, &second_permit);
        try pool.checkAttached(first, .{ .model = first_binding });
        try pool.checkAttached(second, .{ .model = second_binding });
        try pool.detach(first);
        try pool.checkDetached(first, null);
        try std.testing.expectError(error.ForeignLaunchAuthority, pool.consumeLaunchAuthority(first, .{ .model = first_binding }));
        try pool.checkAttached(second, .{ .model = second_binding });
        try pool.cleanupComplete(first);
        try pool.checkFree(first);
        try pool.checkAttached(second, .{ .model = second_binding });
        try pool.detach(second);
        try pool.cleanupComplete(second);
        try std.testing.expectEqual(@as(usize, 0), pool.occupied());
    }
}

test "stale tokens after reuse leave the new owner unchanged" {
    var records: [1]CustodyRecord = @splat(.{});
    var pool = CustodyPool.initialize(&records);
    const first = pool.reserve().?;
    var first_permit = attempt.DispatchPermit{ .binding = .{
        .turn_id = 1,
        .operation_id = 1,
        .attempt_ordinal = 1,
    } };
    const first_binding = try pool.attach(first, &first_permit);
    try pool.consumeLaunchAuthority(first, .{ .model = first_binding });
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
    try std.testing.expectError(error.StaleCustody, pool.consumeLaunchAuthority(first, .{ .model = first_binding }));
    try std.testing.expectError(error.StaleCustody, pool.binding(first));
    try std.testing.expect(!pool.claimTerminalDelivery(first));
    try std.testing.expectError(error.StaleCustody, pool.detach(first));
    try std.testing.expectError(error.StaleCustody, pool.cleanupComplete(first));
    try std.testing.expectError(error.StaleCustody, pool.releaseUnused(first));
    try std.testing.expectError(error.StaleCustody, pool.checkAttached(first, .{ .model = first_binding }));
    try pool.checkAttached(second, .{ .model = second_binding });
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
    var records: [1]CustodyRecord = @splat(.{});
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
    try pool.checkDetached(token, null);
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

test "model decisions preserve cancellation and known authentication failure precedence" {
    try std.testing.expectEqual(ModelDecision.advance_preparation, modelDecision(.{ .preparing = .{ .launch_allowed = true } }));
    try std.testing.expectEqual(ModelDecision.abandon, modelDecision(.{ .preparing = .{ .launch_allowed = false } }));
    // Independent expected table: rows are no control/open, no control/fenced,
    // control/open, control/fenced; columns are pending, ready, failed.
    const expected = [4][3]ModelDecision{
        .{ .wait, .launch, .settle_authentication_failure },
        .{ .wait, .abandon, .settle_authentication_failure },
        .{ .wait, .abandon, .abandon },
        .{ .wait, .abandon, .abandon },
    };
    for (expected, 0..) |row, index| {
        inline for (.{ .pending, .ready, .failed }, 0..) |result, column| {
            try std.testing.expectEqual(row[column], modelDecision(.{ .authenticating = .{
                .cancelled = index >= 2,
                .launch_allowed = index % 2 == 0,
                .result = result,
            } }));
        }
    }
}

test "model preparation failure retains resources before considering semantic delivery" {
    const expected = [_]ModelDecision{
        .settle_preparation_failure, .retain_cleanup, .fence, .retain_cleanup,
        .abandon,                    .retain_cleanup, .fence, .retain_cleanup,
    };
    for (expected, 0..) |decision, mask| {
        try std.testing.expectEqual(decision, modelDecision(.{ .preparation_failed = .{
            .retained_scratch = mask & 1 != 0,
            .canonical_fenced = mask & 2 != 0,
            .superseded = mask & 4 != 0,
        } }));
    }
}

test "model prepared routes preserve one shot handoff across rejection and reuse" {
    inline for (.{ .suppressed, .superseded, .unexpected }) |failure| {
        for ([_]bool{ false, true }) |authenticated| {
            var records: [1]CustodyRecord = @splat(.{});
            var pool = CustodyPool.initialize(&records);
            const token = pool.reserve().?;
            var permit = attempt.DispatchPermit{ .binding = .{ .turn_id = 7, .operation_id = 19, .attempt_ordinal = 3 } };
            const binding = try pool.attach(token, &permit);
            try std.testing.expectEqual(if (authenticated) ModelDecision.authenticate else .launch, modelDecision(.{ .prepared = .{
                .authentication_required = authenticated,
            } }));
            if (authenticated) {
                try std.testing.expectEqual(ModelDecision.launch, modelDecision(.{ .authenticating = .{
                    .cancelled = false,
                    .launch_allowed = true,
                    .result = .ready,
                } }));
            }
            // Canonical handoff can reject after local authority is consumed.
            try pool.consumeLaunchAuthority(token, .{ .model = binding });
            try std.testing.expectEqual(if (failure == .unexpected) ModelDecision.fence else .abandon, modelDecision(.{ .handoff_failed = failure }));
            try std.testing.expectError(error.DispatchPermitConsumed, pool.consumeLaunchAuthority(token, .{ .model = binding }));
            try pool.detach(token);
            try std.testing.expect(!pool.claimTerminalDelivery(token));
            try std.testing.expect(pool.reserve() == null);
            try pool.cleanupComplete(token);
            const reused = pool.reserve().?;
            try std.testing.expectError(error.StaleCustody, pool.consumeLaunchAuthority(token, .{ .model = binding }));
            try std.testing.expect(!pool.claimTerminalDelivery(token));
            try pool.checkReserved(reused);
            try pool.releaseUnused(reused);
        }
    }
}
