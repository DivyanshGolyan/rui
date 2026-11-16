//! Effort SQLite mechanism tests.
const tests = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const retry_policy = @import("../../retry_policy.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const configuration_domain = @import("../domain/configuration.zig");
const historical_domain = @import("../domain/historical.zig");
const sqlite = @import("../sqlite.zig");
const store_testing = @import("../testing.zig");
const c = sqlite.c;
const ConfigureReply = configuration_domain.ConfigureReply;
const HistoricalView = historical_domain.HistoricalView;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const admitRetryForTesting = tests.admitRetryForTesting;
const testSettings = tests.testSettings;
const testingStore = store_testing.testingSqliteStore;

fn configureTestEffort(storage: *Store, key: []const u8, session: []const u8, state: protocol.FieldState, value: []const u8) !ConfigureReply {
    var command: wire_request.ConfigureCommand = .{};
    try command.key.set(key);
    try command.session.set(session);
    command.configuration.reasoning_effort.state = state;
    if (state == .value) try command.configuration.reasoning_effort.value.set(value);
    return try storage.configure(&command, .{});
}

fn testingRevisionEfforts(storage: *Store, session: []const u8, destination: []?protocol.ReasoningEffort) !usize {
    const statement = try sqlite.prepare(storage.sqliteDatabase(), "SELECT reasoning_effort FROM session_revision WHERE session_ref=?1 ORDER BY revision");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, session);
    var count: usize = 0;
    while (c.sqlite3_step(statement) == c.SQLITE_ROW) : (count += 1) {
        destination[count] = try sqlite.readNullableEffort(statement, 0);
    }
    return count;
}

test "reasoning effort overrides are model-checked and frozen on each admitted Operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    var storage_open = true;
    defer if (storage_open) storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);

    var create = try completeConfiguration("effort-create", "", workspace, "gpt-6.1-sol");
    create.configuration.reasoning_effort.state = .value;
    try create.configuration.reasoning_effort.value.set("high");
    const created = try storage.configure(&create, .{});
    try std.testing.expect(created == .accepted);
    const session = created.accepted.session;
    var observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), observed.reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), observed.reasoning_effort_override);

    try submitTestMessage(&storage, &tmp, "effort-one", "effort-one", session.slice(), "first");
    const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;

    // D111/D165: the pinned codec cannot return to unspecified effort.
    const clear = try configureTestEffort(&storage, "effort-clear", session.slice(), .explicit_null, "");
    try std.testing.expect(clear == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, clear.rejected.code);
    try std.testing.expectEqual(observed.revision, (try storage.inspectSessionForTesting(session.slice())).revision);
    // A client resolves its default to a concrete value before sending it.
    try std.testing.expect(try configureTestEffort(&storage, "effort-client-default", session.slice(), .value, "low") == .accepted);
    observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), observed.reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), observed.reasoning_effort_override);

    // A replacement Attempt keeps its Operation's frozen effort.
    try storage.settleModelAttemptFailure(first, .{ .uncorrelated = "temporary" }, .{ .retryable = .{ .waits_ms = .{ 1, 1, 1 } } }, .{});
    try store_testing.sqlite_only.exec(&storage, "UPDATE model_operation SET retry_due_at_ms=1 WHERE resolution_code IS NULL", .{});
    const retry = (try admitRetryForTesting(&storage)).?.permit.binding;
    try std.testing.expectEqual(first.operation_id, retry.operation_id);
    {
        var view: HistoricalView = undefined;
        storage.openHistoricalView(retry, &view);
        defer view.close();
        try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), (try testSettings(&view)).reasoning_effort);
    }

    // Unsupported and outside-grammar values reject without a revision.
    const revision = observed.revision;
    for ([_][]const u8{ "none", "ultra", "HIGH", "" }, 0..) |invalid, index| {
        var key: [32]u8 = undefined;
        const rejected = try configureTestEffort(&storage, try std.fmt.bufPrint(&key, "effort-invalid-{d}", .{index}), session.slice(), .value, invalid);
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, rejected.rejected.code);
        try std.testing.expectEqual(revision, (try storage.inspectSessionForTesting(session.slice())).revision);
    }
    // An omitted field preserves an override distinct from the client default.
    try std.testing.expect(try configureTestEffort(&storage, "effort-medium", session.slice(), .value, "medium") == .accepted);
    try std.testing.expect(try configureTestEffort(&storage, "effort-omitted", session.slice(), .omitted, "") == .accepted);
    observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .medium), observed.reasoning_effort_override);
    var revisions: [8]?protocol.ReasoningEffort = undefined;
    const revision_count = try testingRevisionEfforts(&storage, session.slice(), &revisions);
    try std.testing.expectEqualSlices(?protocol.ReasoningEffort, &.{ .high, .low, .medium, .medium }, revisions[0..revision_count]);

    // D229: an unlisted model accepts the entire effort grammar, not arbitrary text.
    const unknown = try configureTestSession(&storage, "effort-unknown");
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), (try storage.inspectSessionForTesting(unknown.slice())).reasoning_effort);
    for (std.enums.values(protocol.ReasoningEffort)) |effort| {
        var key: [64]u8 = undefined;
        const accepted = try configureTestEffort(&storage, try std.fmt.bufPrint(&key, "effort-unknown-{s}", .{@tagName(effort)}), unknown.slice(), .value, @tagName(effort));
        try std.testing.expect(accepted == .accepted);
        const settings = try storage.inspectSessionForTesting(unknown.slice());
        try std.testing.expectEqual(@as(?protocol.ReasoningEffort, effort), settings.reasoning_effort);
        try std.testing.expectEqual(@as(?protocol.ReasoningEffort, effort), settings.reasoning_effort_override);
    }
    const unknown_revision = (try storage.inspectSessionForTesting(unknown.slice())).revision;
    for ([_][]const u8{ "ultra", "HIGH", "" }, 0..) |invalid, index| {
        var key: [64]u8 = undefined;
        const rejected = try configureTestEffort(&storage, try std.fmt.bufPrint(&key, "effort-unknown-invalid-{d}", .{index}), unknown.slice(), .value, invalid);
        try std.testing.expect(rejected == .rejected);
        try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, rejected.rejected.code);
        try std.testing.expectEqual(unknown_revision, (try storage.inspectSessionForTesting(unknown.slice())).revision);
    }

    // A new Operation freezes the effective effort current at its admission,
    // and the frozen value survives reopening.
    try storage.settleModelAttemptFailure(retry, .{ .uncorrelated = "permanent" }, .ordinary, .{});
    try submitTestMessage(&storage, &tmp, "effort-two", "effort-two", session.slice(), "second");
    const second = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try std.testing.expect(try configureTestEffort(&storage, "effort-xhigh", session.slice(), .value, "xhigh") == .accepted);
    try storage.close();
    storage_open = false;
    var reopened: Store = undefined;
    try testingStore(&reopened, &tmp, std.testing.io);
    defer reopened.close() catch unreachable;
    var view: HistoricalView = undefined;
    reopened.openHistoricalView(second, &view);
    defer view.close();
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .medium), (try testSettings(&view)).reasoning_effort);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .xhigh), (try reopened.inspectSessionForTesting(session.slice())).reasoning_effort);
}

test "an exhausted Attempt still retains its effort refusal for the next Operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try testingStore(&storage, &tmp, std.testing.io);
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var create = try completeConfiguration("exhausted-effort-create", "", workspace, "model-a");
    create.configuration.reasoning_effort.state = .value;
    try create.configuration.reasoning_effort.value.set("low");
    const session = (try storage.configure(&create, .{})).accepted.session;
    try answerTestTurn(&storage, &tmp, session.slice(), "exhausted-effort-first", &.{.{ .encoded = "ok", .decoded = "ok" }});
    var change: wire_request.ConfigureCommand = .{};
    change.session = session;
    try change.key.set("exhausted-effort-high");
    change.configuration.reasoning_effort.state = .value;
    try change.configuration.reasoning_effort.value.set("high");
    const revision = (try storage.configure(&change, .{})).accepted.revision;
    try submitTestMessage(&storage, &tmp, "exhausted-effort-input", "exhausted-effort-message", session.slice(), "continue");
    var binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store_testing.exec(&storage, "UPDATE model_operation SET attempt_ordinal=?1 WHERE operation_id=?2", .{ retry_policy.maximum_attempts, binding.operation_id });
    binding.attempt_ordinal = retry_policy.maximum_attempts;
    try store_testing.settleModelFailureWithTimings(&storage, binding, .{ .correlated = .{ .code = "provider_http_400", .request_id = .{}, .report = "unsupported_value: high" } }, .effort_change_refused, .{ .latency_ms = 37, .first_event_ms = 7 }, .{});
    try std.testing.expect(try storage.tryAdmitNextModelRetry(.empty(), .{}, null) == null);
    const observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqual(revision, observed.revision);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), observed.reasoning_effort);
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE session_ref=?1 AND revision=?2 AND field='reasoning_effort_refused' AND provider_text='unsupported_value: high'", .{ session.slice(), revision }));
    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code='retry_exhausted' AND latency_ms=37 AND first_event_ms=7", .{binding.operation_id}));
    try submitTestMessage(&storage, &tmp, "exhausted-effort-next-input", "exhausted-effort-next", session.slice(), "next Operation");
    const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    var view: historical_domain.HistoricalView = undefined;
    storage.openHistoricalView(next, &view);
    defer view.close();
    var settings: historical_domain.HistoricalSettings = undefined;
    try view.settings(&settings);
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), settings.reasoning_effort);
}
