const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const rsql = @import("../rsql.zig");
const Store = store_core.Store;
const configuration_domain = @import("../domain/configuration.zig");
const operation_effort = @import("../domain/operation_effort.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const AttemptBinding = store_core.AttemptBinding;
const CurrentConfiguration = configuration_domain.CurrentConfiguration;
const HistoricalSettings = historical_domain.HistoricalSettings;
const TestingPage = store_testing.TestingPage;
const answerTestTurn = store_testing.answerTestTurn;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;

test "unlisted effort passes configure preset Message creation and update unchanged" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Surface = enum { configure, preset, message };
            for (std.enums.values(Surface)) |surface| for (std.enums.values(protocol.ReasoningEffort)) |effort| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("unlisted-create", "", workspace, "unlisted-effort-model");
                create.configuration.reasoning_effort.state = .value;
                try create.configuration.reasoning_effort.value.set(@tagName(effort));
                const session = switch (surface) {
                    .configure => configured: {
                        const reply = try storage.configure(&create, .{});
                        try std.testing.expect(reply == .accepted);
                        break :configured reply.accepted.session;
                    },
                    .preset => configured: {
                        create.preset = .{};
                        try create.preset.?.set("worker");
                        const reply = try storage.configureWithPreset(&create, &.{ .request_digest = create.presetRequestDigest() }, .{});
                        try std.testing.expect(reply == .accepted);
                        break :configured reply.accepted.session;
                    },
                    .message => configured: {
                        const text = "work";
                        const file = try tmp.dir.createFile(std.testing.io, "unlisted-message", .{ .read = true });
                        try file.writeStreamingAll(std.testing.io, text);
                        try file.sync(std.testing.io);
                        var message = try completeMessage("unlisted-message", "", file, text);
                        defer message.removeTemporaryContent(std.testing.io) catch unreachable;
                        message.configuration = create.configuration;
                        const reply = storage.submitMessageWithModel(&message, null, .{});
                        try std.testing.expect(reply == .accepted);
                        break :configured reply.accepted.session;
                    },
                };
                try std.testing.expectEqual(@as(?protocol.ReasoningEffort, effort), (try storage.inspectSessionForTesting(session.slice())).reasoning_effort);
                var empty = try completeConfiguration("unlisted-empty", "", workspace, "unlisted-effort-model");
                empty.configuration.reasoning_effort.state = .explicit_null;
                const target = (try storage.configure(&empty, .{})).accepted.session;
                var update: wire_request.ConfigureCommand = .{ .session = target };
                try update.key.set("unlisted-update");
                update.configuration.reasoning_effort.state = .value;
                try update.configuration.reasoning_effort.value.set(@tagName(effort));
                try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
                try std.testing.expectEqual(@as(?protocol.ReasoningEffort, effort), (try storage.inspectSessionForTesting(target.slice())).reasoning_effort);
            };
        }
    }.run);
}

test "configuration validates effective effort across retained requested and target model states" {
    const catalog = @import("../../model_catalog.zig");
    const efforts = std.enums.values(protocol.ReasoningEffort);
    for ([_][]const u8{ "gpt-5.5", "openai/whisper-1", "unlisted-target" }) |target| {
        const known = catalog.find(catalog.shipped, target);
        for (0..efforts.len + 1) |retained_index| {
            const retained: ?protocol.ReasoningEffort = if (retained_index == 0) null else efforts[retained_index - 1];
            for ([_]bool{ false, true }) |legacy| {
                for ([_]bool{ true, false }) |model_supplied| {
                    var current: CurrentConfiguration = .{ .provider = .codex };
                    try current.model.set(if (model_supplied) "unlisted-source" else target);
                    current.reasoning_effort = if (legacy) null else retained;
                    current.previous_reasoning_effort = if (legacy) retained else null;
                    for (0..efforts.len + 2) |request_index| {
                        var requested: wire_request.Configuration = .{};
                        if (model_supplied) {
                            requested.model.state = .value;
                            try requested.model.value.set(target);
                        }
                        if (request_index == 1) requested.reasoning_effort.state = .explicit_null;
                        if (request_index >= 2) {
                            requested.reasoning_effort.state = .value;
                            try requested.reasoning_effort.value.set(@tagName(efforts[request_index - 2]));
                        }
                        const selected = if (request_index == 0) retained else if (request_index == 1) null else efforts[request_index - 2];
                        const supported = if (known) |row|
                            (if (selected) |value| row.efforts.contains(value) else row.efforts.count() == 0)
                        else
                            true;
                        const clears = request_index == 1 and retained != null;
                        const expected: ?protocol.ConfigurationRejection = if (supported and !clears) null else .unsupported_reasoning_effort;
                        errdefer std.debug.print("target={s} retained={?s} legacy={} model_supplied={} request={s} value={?s}\n", .{
                            target,
                            if (retained) |value| @tagName(value) else null,
                            legacy,
                            model_supplied,
                            @tagName(requested.reasoning_effort.state),
                            if (selected) |value| @tagName(value) else null,
                        });
                        try std.testing.expectEqual(expected, configuration_domain.configurationBeforeWorkspace(@import("../../model_catalog.zig").shipped, &tool_defs.built_in_tool_set, &current, &requested, .codex));
                    }
                }
            }
        }
    }
}

test "effort refusal requires an emitted Operation update across configure cycles" {
    try store_testing.forEachEngine(struct {
        const Scenario = enum { first, unchanged, label, cycle_back, genuine, skipped_choice };

        fn run(case: *store_testing.Case) !void {
            for ([_]?protocol.ReasoningEffort{ null, .low }) |initial| for ([_]bool{ false, true }) |legacy_codec| for (std.enums.values(Scenario)) |scenario| {
                if (initial == null and scenario == .cycle_back) continue;
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("wire-effort-create", "", workspace, "unlisted-effort");
                create.configuration.reasoning_effort.state = if (initial == null) .explicit_null else .value;
                if (initial) |value| try create.configuration.reasoning_effort.value.set(@tagName(value));
                const session = (try storage.configure(&create, .{})).accepted.session;
                // Retain the historical null case after fresh null requests became default resets.
                if (initial == null) try store_testing.setLegacyNullEffortForTesting(&storage, session.slice());
                if (legacy_codec) try store_testing.exec(&storage, "UPDATE session SET codec='openai-responses/1' WHERE session_ref=?1", .{session.slice()});
                if (scenario != .first) try answerTestTurn(&storage, &tmp, session.slice(), "wire-effort-first", &.{.{ .encoded = "ok", .decoded = "ok" }});
                var change: wire_request.ConfigureCommand = .{};
                change.session = session;
                var selected = initial;
                if (scenario != .unchanged and scenario != .label) {
                    change.configuration.reasoning_effort.state = .value;
                    try change.key.set("wire-effort-high");
                    try change.configuration.reasoning_effort.value.set("high");
                    _ = (try storage.configure(&change, .{})).accepted;
                    selected = .high;
                }
                if (scenario == .cycle_back or scenario == .skipped_choice) {
                    try change.key.set("wire-effort-final");
                    selected = if (scenario == .cycle_back) .low else .xhigh;
                    try change.configuration.reasoning_effort.value.set(@tagName(selected.?));
                    _ = (try storage.configure(&change, .{})).accepted;
                }
                if (scenario == .label) {
                    try change.key.set("wire-effort-label");
                    change.configuration.label.state = .value;
                    try change.configuration.label.value.set("not an effort update");
                    _ = (try storage.configure(&change, .{})).accepted;
                }
                try submitTestMessage(&storage, &tmp, "wire-effort-next", "wire-effort-message", session.slice(), "observe wire effort");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                const emitted = !legacy_codec and (scenario == .genuine or scenario == .skipped_choice);
                try std.testing.expectEqual(@intFromBool(emitted), try store_testing.queryU64(&storage, "SELECT effort_update FROM model_operation WHERE operation_id=?1", .{binding.operation_id}));
                try storage.settleModelAttemptFailure(binding, .{ .correlated = .{ .code = "provider_http_400", .request_id = .{}, .report = "unsupported_value: reasoning.effort" } }, .effort_change_refused, .{});
                try std.testing.expectEqual(@intFromBool(emitted), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE session_ref=?1 AND field='reasoning_effort_refused'", .{session.slice()}));
                const expected = if (emitted) initial else selected;
                try std.testing.expectEqual(expected, (try storage.inspectSessionForTesting(session.slice())).reasoning_effort);
                try std.testing.expectEqual(@intFromBool(!emitted), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code='provider_http_400'", .{binding.operation_id}));
                if (emitted) {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE refused_operation_id=?1 AND revision=(SELECT effort_source_revision FROM model_operation WHERE operation_id=?1)", .{binding.operation_id}));
                    var retry = (try storage.tryAdmitNextModelRetry(.empty(), .{}, null)).?;
                    const retried = try retry.permit.consume();
                    var view: TestingPage = undefined;
                    view.open(&storage, retried);
                    defer view.close();
                    var settings: HistoricalSettings = undefined;
                    try view.settings(&settings);
                    try std.testing.expectEqual(initial, settings.reasoning_effort);
                    try std.testing.expect(!settings.effort_update);
                    try storage.settleModelAttemptFailure(retried, .{ .correlated = .{ .code = "provider_http_400", .request_id = .{}, .report = "unsupported_value: reasoning.effort" } }, .effort_change_refused, .{});
                    try std.testing.expect(try storage.tryAdmitNextModelRetry(.empty(), .{}, null) == null);
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE refused_operation_id=?1", .{binding.operation_id}));
                } else try std.testing.expect(try storage.tryAdmitNextModelRetry(.empty(), .{}, null) == null);
            };
        }
    }.run);
}

test "effort provenance excludes refused Operations across unrelated revisions" {
    try store_testing.forEachEngine(struct {
        fn expectEffort(storage: *Store, binding: AttemptBinding, effort: ?protocol.ReasoningEffort) !void {
            var view: TestingPage = undefined;
            view.open(storage, binding);
            defer view.close();
            var settings: HistoricalSettings = undefined;
            try view.settings(&settings);
            try std.testing.expectEqual(effort, settings.reasoning_effort);
        }

        fn run(case: *store_testing.Case) !void {
            const Before = enum { none, before_admission, after_admission };
            const After = enum { none, label, no_op };
            const efforts = [_]?protocol.ReasoningEffort{ null, .none, .low, .medium, .high, .xhigh, .max };
            for (efforts) |effort| for ([_]bool{ false, true }) |legacy| for (std.enums.values(Before)) |before| for (std.enums.values(After)) |after| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("provenance-create", "", workspace, "unlisted-effort-model");
                if (effort) |value| {
                    create.configuration.reasoning_effort.state = .value;
                    try create.configuration.reasoning_effort.value.set(@tagName(value));
                } else create.configuration.reasoning_effort.state = .explicit_null;
                const session = (try storage.configure(&create, .{})).accepted.session;
                // Retain the historical null case after fresh null requests became default resets.
                if (effort == null) try store_testing.setLegacyNullEffortForTesting(&storage, session.slice());
                try answerTestTurn(&storage, &tmp, session.slice(), "provenance-first", &.{.{ .encoded = "ok", .decoded = "ok" }});
                if (legacy) try store_testing.setLegacyNullEffortForTesting(&storage, session.slice());
                const override = if (legacy) null else effort;
                const rejected: protocol.ReasoningEffort = if (effort == .high) .max else .high;
                var change: wire_request.ConfigureCommand = .{};
                change.session = session;
                try change.key.set("provenance-rejected-choice");
                change.configuration.reasoning_effort.state = .value;
                try change.configuration.reasoning_effort.value.set(@tagName(rejected));
                const revision = (try storage.configure(&change, .{})).accepted.revision;
                var unrelated: wire_request.ConfigureCommand = .{};
                unrelated.session = session;
                if (before != .none) {
                    try unrelated.key.set("provenance-before");
                    unrelated.configuration.label.state = .value;
                    try unrelated.configuration.label.value.set("before refusal");
                    if (before == .before_admission) try std.testing.expect(try storage.configure(&unrelated, .{}) == .accepted);
                }
                try submitTestMessage(&storage, &tmp, "provenance-input", "provenance-message", session.slice(), "change effort");
                const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                if (before == .after_admission) try std.testing.expect(try storage.configure(&unrelated, .{}) == .accepted);
                try expectEffort(&storage, binding, rejected);
                try store_testing.settleModelFailureWithTimings(&storage, binding, .{ .correlated = .{ .code = "provider_http_400", .request_id = .{}, .report = "unsupported_value: effort update" } }, .effort_change_refused, .{ .latency_ms = 999, .first_event_ms = 111 }, .{});
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code IS NULL AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND latency_ms=999 AND first_event_ms=111", .{binding.operation_id}));
                const refused = try storage.inspectSessionForTesting(session.slice());
                try std.testing.expectEqual(effort, refused.reasoning_effort);
                try std.testing.expectEqual(override, refused.reasoning_effort_override);
                if (after != .none) {
                    try unrelated.key.set("provenance-after");
                    unrelated.configuration = .{};
                    if (after == .label) {
                        unrelated.configuration.label.state = .value;
                        try unrelated.configuration.label.value.set("after refusal");
                    }
                    try std.testing.expect(try storage.configure(&unrelated, .{}) == .accepted);
                }
                const observed = try storage.inspectSessionForTesting(session.slice());
                try std.testing.expectEqual(effort, observed.reasoning_effort);
                try std.testing.expectEqual(override, observed.reasoning_effort_override);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_change WHERE session_ref=?1 AND revision=?2 AND field='reasoning_effort_refused'", .{ session.slice(), revision }));
                var retry = (try storage.tryAdmitNextModelRetry(.empty(), .{}, null)).?;
                const retried = try retry.permit.consume();
                try expectEffort(&storage, retried, effort);
                try settleItemsForTesting(&storage, &tmp, retried, &.{"{\"type\":\"message\",\"id\":\"provenance-answer\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}"}, "ok");
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM model_operation WHERE operation_id=?1 AND resolution_code='answer' AND attempt_ordinal=2 AND latency_ms IS NULL AND first_event_ms IS NULL", .{binding.operation_id}));
                try submitTestMessage(&storage, &tmp, "provenance-next", "provenance-next-message", session.slice(), "next Operation");
                const next = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try expectEffort(&storage, next, effort);
                try std.testing.expectEqual(effort, (try storage.inspectSessionForTesting(session.slice())).reasoning_effort);
                try change.key.set("provenance-new-choice");
                const chosen = (try storage.configure(&change, .{})).accepted;
                try std.testing.expectEqual(@as(?protocol.ReasoningEffort, rejected), (try storage.inspectSessionForTesting(session.slice())).reasoning_effort);
                try std.testing.expectEqual(chosen.revision, try store_testing.queryU64(&storage, "SELECT " ++ configuration_domain.effortChoiceRevisionSql("s") ++ " FROM session s WHERE s.session_ref=?1", .{session.slice()}));
                try expectEffort(&storage, next, effort);
            };
        }
    }.run);
}

test "effective effort carries legacy history without inferring a fresh default" {
    var current: CurrentConfiguration = .{ .provider = .codex };
    try current.model.set("unlisted-model");
    try std.testing.expect(configuration_domain.effectiveReasoningEffort(&current) == null);
    current.previous_reasoning_effort = .high;
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), configuration_domain.effectiveReasoningEffort(&current));
    var requested: wire_request.Configuration = .{};
    requested.reasoning_effort.state = .explicit_null;
    try std.testing.expectEqual(protocol.ConfigurationRejection.unsupported_reasoning_effort, configuration_domain.configurationBeforeWorkspace(@import("../../model_catalog.zig").shipped, &tool_defs.built_in_tool_set, &current, &requested, .codex).?);
    current.reasoning_effort = .low;
    try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .low), configuration_domain.effectiveReasoningEffort(&current));
}

const EffortCarryRead = struct {
    const query = rsql.Read(.{
        .sql = "SELECT " ++ historical_domain.effortBeforeSql("?1", "?2", "?3", "?4", "?5") ++ " AS effort",
        .Args = struct { session: []const u8, boundary: u64, model: []const u8, floor: ?u64, first: ?protocol.ReasoningEffort },
        .Row = struct { effort: ?protocol.ReasoningEffort },
        .cardinality = .one,
    });

    const eligible = rsql.Read(.{
        .sql = "SELECT " ++ operation_effort.refusalEligibleSql("o") ++ " AS eligible FROM model_operation o WHERE o.operation_id=?1",
        .Args = struct { operation: u64 },
        .Row = struct { eligible: bool },
        .cardinality = .one,
    });

    fn refusalEligible(storage: *Store, operation: u64) !bool {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: store_access.Access(.read, error{}) = .open(&entry);
        defer a.deinit();
        var result: eligible.Result = undefined;
        a.read(eligible, .{ .operation = operation }, &result);
        try a.run();
        return result.eligible;
    }

    fn read(storage: *Store, args: query.Args) !?protocol.ReasoningEffort {
        const entry = try store_core.enter(storage, .none);
        defer entry.release();
        var a: store_access.Access(.read, error{}) = .open(&entry);
        defer a.deinit();
        var result: query.Result = undefined;
        a.read(query, args, &result);
        try a.run();
        return result.effort;
    }
};

test "admitted effort carry agrees with replay recipe across the owner domain" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Recipe = @import("../../replay_recipe.zig").Recipe;
            const Entry = struct { position: u64, model: []const u8, effort: ?protocol.ReasoningEffort };
            for ([_]?protocol.ReasoningEffort{ null, .low }) |top| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("carry-create", "", workspace, "unlisted-A");
                if (top) |value| {
                    create.configuration.reasoning_effort.state = .value;
                    try create.configuration.reasoning_effort.value.set(@tagName(value));
                } else create.configuration.reasoning_effort.state = .explicit_null;
                const session = (try storage.configure(&create, .{})).accepted.session;
                // Retain the historical null case after fresh null requests became default resets.
                if (top == null) try store_testing.setLegacyNullEffortForTesting(&storage, session.slice());
                try answerTestTurn(&storage, &tmp, session.slice(), "carry-first", &.{.{ .encoded = "ok", .decoded = "ok" }});
                var change: wire_request.ConfigureCommand = .{};
                change.session = session;
                try change.key.set("carry-B");
                change.configuration.model.state = .value;
                try change.configuration.model.value.set("unlisted-B");
                try std.testing.expect(try storage.configure(&change, .{}) == .accepted);
                try store_testing.exec(&storage, "UPDATE model_operation SET admission_position=2 WHERE session_ref=?1", .{session.slice()});
                try store_testing.exec(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,reasoning_effort,attempt_ordinal,resolution_code,resolved_at,tool_set_id,history_floor,context_window) SELECT 90,turn_id,session_ref,1,input_cutoff,10,1,0,'high',1,'failed',1,tool_set_id,10,context_window FROM model_operation WHERE session_ref=?1 AND admission_position=2", .{session.slice()});
                try store_testing.exec(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,reasoning_effort,attempt_ordinal,resolution_code,resolved_at,tool_set_id,history_floor,context_window) SELECT 91,turn_id,session_ref,2,input_cutoff,20,1,0,'xhigh',1,'failed',1,tool_set_id,20,context_window FROM model_operation WHERE session_ref=?1 AND admission_position=2", .{session.slice()});
                try store_testing.exec(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,reasoning_effort,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window) SELECT 92,turn_id,session_ref,1,input_cutoff,22,0,'none',1,'failed',1,tool_set_id,context_window FROM model_operation WHERE session_ref=?1 AND admission_position=2", .{session.slice()});
                try store_testing.exec(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,reasoning_effort,attempt_ordinal,resolution_code,resolved_at,tool_set_id,context_window) SELECT 93,turn_id,session_ref,1,input_cutoff,25,0,NULL,1,'failed',1,tool_set_id,context_window FROM model_operation WHERE session_ref=?1 AND admission_position=2", .{session.slice()});
                try store_testing.exec(&storage, "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count) SELECT 90,0,session_ref,11,4,1,item_id_digest,0,0,extras_content_id,0 FROM model_output_item WHERE session_ref=?1 AND item_ordinal=0 LIMIT 1", .{session.slice()});
                try store_testing.exec(&storage, "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count) SELECT 91,0,session_ref,21,4,1,item_id_digest,0,0,extras_content_id,0 FROM model_output_item WHERE operation_id=90 AND session_ref=?1", .{session.slice()});
                const entries = [_]Entry{ .{ .position = 2, .model = "unlisted-A", .effort = top }, .{ .position = 10, .model = "unlisted-A", .effort = .high }, .{ .position = 20, .model = "unlisted-B", .effort = .xhigh }, .{ .position = 22, .model = "unlisted-A", .effort = .none }, .{ .position = 25, .model = "unlisted-A", .effort = null } };
                for (0..3) |profile| {
                    try store_testing.exec(&storage, "UPDATE model_operation SET resolution_code=CASE WHEN (?1>=1 AND operation_id=90) OR (?1=2 AND operation_id=91) THEN 'compacted' ELSE 'failed' END WHERE operation_id IN (90,91)", .{profile});
                    for ([_][]const u8{ "unlisted-A", "unlisted-B" }) |model| for ([_]u64{ 2, 9, 10, 11, 20, 21, 22, 23, 25, 26, 30 }) |boundary| for ([_]?u64{ null, 0, 10, 11, 20, 22, 25, 40 }) |own_floor| {
                        const candidate: ?@import("../../replay_recipe.zig").Base = if (profile == 2 and boundary > 20) .{ .position = 20, .floor = 20, .model = "unlisted-B" } else if (profile >= 1 and boundary > 10) .{ .position = 10, .floor = 10, .model = "unlisted-A" } else null;
                        const recipe = Recipe.select(model, candidate, own_floor orelse 0);
                        const anchor: u64 = if (recipe.frontier == 0) 0 else recipe.frontier + 1;
                        var expected: ?protocol.ReasoningEffort = .medium;
                        for (entries) |item| {
                            if (item.position < boundary and std.mem.eql(u8, item.model, model)) {
                                expected = item.effort;
                                break;
                            }
                        }
                        var declined = false;
                        for (entries) |item| if (item.position < boundary and item.position > recipe.floor and item.position >= anchor and std.mem.eql(u8, item.model, model)) {
                            if (item.effort == null and expected != null) {
                                declined = true;
                                break;
                            }
                            expected = item.effort;
                        };
                        if (declined) continue;
                        try std.testing.expectEqual(expected, try EffortCarryRead.read(&storage, .{ .session = session.slice(), .boundary = boundary, .model = model, .floor = own_floor, .first = .medium }));
                    };
                }
            }
        }
    }.run);
}

test "effort refusal eligibility excludes a source refused by any Operation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("eligible-create", "", workspace, "unlisted-effort-model");
            create.configuration.reasoning_effort.state = .value;
            try create.configuration.reasoning_effort.value.set("low");
            const session = (try storage.configure(&create, .{})).accepted.session;
            try answerTestTurn(&storage, &tmp, session.slice(), "eligible-first", &.{.{ .encoded = "ok", .decoded = "ok" }});
            var change: wire_request.ConfigureCommand = .{};
            change.session = session;
            try change.key.set("eligible-high");
            change.configuration.reasoning_effort.state = .value;
            try change.configuration.reasoning_effort.value.set("high");
            _ = (try storage.configure(&change, .{})).accepted;
            try submitTestMessage(&storage, &tmp, "eligible-input", "eligible-message", session.slice(), "change");
            const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try store_testing.exec(&storage, "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,reasoning_effort,attempt_ordinal,resolution_code,resolved_at,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,context_window) SELECT 999,turn_id,session_ref,settings_revision,input_cutoff,999,0,reasoning_effort,1,'failed',1,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,context_window FROM model_operation WHERE operation_id=?1", .{binding.operation_id});
            try std.testing.expect(try EffortCarryRead.refusalEligible(&storage, binding.operation_id));
            try std.testing.expect(try EffortCarryRead.refusalEligible(&storage, 999));
            try storage.settleModelAttemptFailure(binding, .{ .correlated = .{ .code = "provider_http_400", .request_id = .{}, .report = "unsupported_value: reasoning.effort" } }, .effort_change_refused, .{});
            try std.testing.expect(!try EffortCarryRead.refusalEligible(&storage, binding.operation_id));
            try std.testing.expect(!try EffortCarryRead.refusalEligible(&storage, 999));
            try change.key.set("eligible-new-choice");
            try change.configuration.reasoning_effort.value.set("xhigh");
            const revision = (try storage.configure(&change, .{})).accepted.revision;
            try store_testing.exec(&storage, "UPDATE model_operation SET settings_revision=?1,effort_source_revision=?1,reasoning_effort='xhigh' WHERE operation_id=999", .{revision});
            try std.testing.expect(try EffortCarryRead.refusalEligible(&storage, 999));
        }
    }.run);
}

test "sparse creation and default reset replay keep admitted catalog defaults" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]?protocol.ReasoningEffort{ .low, .high, null }) |initial| for ([_]protocol.FieldState{ .omitted, .explicit_null }) |state| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const catalog = @import("../../model_catalog.zig");
                var efforts: catalog.Efforts = .{};
                if (initial) |effort| efforts.insert(effort);
                try storage.saveModelFacts(&.{.{ .id = "runtime-default", .context_window = 1000, .efforts = efforts, .openai_listed = true }}, null);
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var create = try completeConfiguration("sparse-catalog-create", "", try canonicalCwd(std.testing.io, &workspace_buffer), "runtime-default");
                create.configuration.tools.state = .omitted;
                create.configuration.permission_mode.state = .omitted;
                create.configuration.reasoning_effort.state = state;
                create.configuration.compaction_trigger.state = state;
                const created = try storage.configure(&create, .{});
                try std.testing.expect(created == .accepted);
                const session = created.accepted.session;
                const first = try storage.inspectSessionForTesting(session.slice());
                try std.testing.expectEqual(initial, first.reasoning_effort);
                try std.testing.expectEqual(@as(?u64, 900), first.compaction_trigger);
                try std.testing.expectEqualStrings(@import("../../product_defaults.zig").permission_mode, first.permission_mode.slice());
                try std.testing.expectEqual(@as(u64, tool_defs.built_in_tool_set.records.len), try store_testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member WHERE tool_set_id=?1", .{first.tool_set_id}));
                var retained: wire_request.ConfigureCommand = .{ .session = session };
                try retained.key.set("sparse-catalog-retain");
                retained.configuration.label.state = .value;
                try retained.configuration.label.value.set("preserve omitted defaults");
                try std.testing.expect(try storage.configure(&retained, .{}) == .accepted);
                const unchanged = try storage.inspectSessionForTesting(session.slice());
                try std.testing.expectEqual(initial, unchanged.reasoning_effort);
                try std.testing.expectEqual(first.compaction_trigger, unchanged.compaction_trigger);

                try storage.saveModelFacts(&.{.{ .id = "runtime-default", .context_window = 2000, .efforts = .init(.{ .medium = true }), .openai_listed = true }}, null);
                const create_replay = try storage.configure(&create, .{});
                try std.testing.expect(create_replay == .accepted and create_replay.accepted.replayed);
                try std.testing.expectEqual(created.accepted.revision, create_replay.accepted.revision);
                try std.testing.expectEqualStrings(session.slice(), create_replay.accepted.session.slice());
                const after_create_replay = try storage.inspectSessionForTesting(session.slice());
                try std.testing.expectEqual(initial, after_create_replay.reasoning_effort);
                try std.testing.expectEqual(@as(?u64, 900), after_create_replay.compaction_trigger);

                var reset: wire_request.ConfigureCommand = .{ .session = session };
                try reset.key.set("sparse-catalog-reset");
                reset.configuration.reasoning_effort.state = .explicit_null;
                reset.configuration.compaction_trigger.state = .explicit_null;
                const resolved = try storage.configure(&reset, .{});
                try std.testing.expect(resolved == .accepted);
                const after_reset = try storage.inspectSessionForTesting(session.slice());
                try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .medium), after_reset.reasoning_effort);
                try std.testing.expectEqual(@as(?u64, 1800), after_reset.compaction_trigger);

                try storage.saveModelFacts(&.{.{ .id = "runtime-default", .context_window = 4000, .efforts = .init(.{ .high = true }), .openai_listed = true }}, null);
                const reset_replay = try storage.configure(&reset, .{});
                try std.testing.expect(reset_replay == .accepted and reset_replay.accepted.replayed);
                try std.testing.expectEqual(resolved.accepted.revision, reset_replay.accepted.revision);
                const after_reset_replay = try storage.inspectSessionForTesting(session.slice());
                try std.testing.expectEqual(after_reset.revision, after_reset_replay.revision);
                try std.testing.expectEqual(after_reset.reasoning_effort, after_reset_replay.reasoning_effort);
                try std.testing.expectEqual(after_reset.compaction_trigger, after_reset_replay.compaction_trigger);
                try reset.key.set("sparse-catalog-fresh-reset");
                try std.testing.expect(try storage.configure(&reset, .{}) == .accepted);
                const fresh = try storage.inspectSessionForTesting(session.slice());
                try std.testing.expectEqual(@as(?protocol.ReasoningEffort, .high), fresh.reasoning_effort);
                try std.testing.expectEqual(@as(?u64, 3600), fresh.compaction_trigger);
            };
        }
    }.run);
}
