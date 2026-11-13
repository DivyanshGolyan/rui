//! Round budget Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const tool_defs = @import("../../tools.zig");
const tool_set_domain = @import("../domain/tool_set.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const reads_domain = @import("../domain/reads.zig");
const store_testing = @import("../testing.zig");
const ActiveOperationFilter = action_domain.ActiveOperationFilter;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ContentReader = content_domain.ContentReader;
const HistoricalEntryKind = historical_domain.HistoricalEntryKind;
const HistoricalSettings = historical_domain.HistoricalSettings;
const HistoricalView = historical_domain.HistoricalView;
const ModelOperationKind = historical_domain.ModelOperationKind;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const configureTestSession = store_testing.configureTestSession;
const settleCompactionForTesting = store_testing.settleCompactionForTesting;
const settleItemsForTesting = store_testing.settleItemsForTesting;
const submitTestMessage = store_testing.submitTestMessage;
const skills_fixture_domain = @import("../domain/skills.zig");
const EntryPoint = shared_fixtures.EntryPoint;
const RoundMeter = shared_fixtures.RoundMeter;
const TestingCall = shared_fixtures.TestingCall;
const ViewRounds = shared_fixtures.ViewRounds;
const completeSessionStop = shared_fixtures.completeSessionStop;
const configureTestSessionAsk = shared_fixtures.configureTestSessionAsk;
const expectContent = shared_fixtures.expectContent;
const nextTestingItem = shared_fixtures.nextTestingItem;
const round_budgets = shared_fixtures.round_budgets;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleCallsForTestingWithFaults = shared_fixtures.settleCallsForTestingWithFaults;
const testingAgentSpec = shared_fixtures.testingAgentSpec;
const testingHostToolRecords = shared_fixtures.testingHostToolRecords;
const testingSessionList = shared_fixtures.testingSessionList;
const testingSessionReport = shared_fixtures.testingSessionReport;

/// Each entry point's content rounds (`readRaw` windows, counted in
/// `Store.testing_content_work.content_rounds`) on the same path, per
/// engine: how many windows a blob read takes depends on the engine's
/// blob access, so each engine states its own. An entry point left out
/// takes none.
fn contentRoundBudget(engine: store_testing.Engine, point: EntryPoint) u16 {
    return switch (engine) {
        // One window holds the driven content.
        .sqlite, .mysql => switch (point) {
            .readOwnedContent, .readHostToolSetText, .searchActivity, .findTools, .readSkills => 1,
            else => 0,
        },
    };
}

/// The functions that enter the Store only to serve tests, so they take
/// no round budget.
const entering_fixtures = [_][]const u8{ "prefixSealForTesting", "readSessionForTesting" };

test "every function that enters the Store has a round budget" {
    // Every Store file but its test files and wire clients;
    // import_architecture.py checks this list against src/store/.
    const sources = .{
        @embedFile("../Store.zig"),
        @embedFile("../access.zig"),
        @embedFile("../archive_tests.zig"),
        @embedFile("../engine.zig"),
        @embedFile("../engine/Sqlite.zig"),
        @embedFile("../engine/Mysql.zig"),
        @embedFile("../engine/mysql_content.zig"),
        @embedFile("../engine/mysql_open.zig"),
        @embedFile("../engine/mysql_refusal.zig"),
        @embedFile("../domain/action.zig"),
        @embedFile("../domain/forward.zig"),
        @embedFile("../domain/command.zig"),
        @embedFile("../domain/configuration.zig"),
        @embedFile("../domain/content.zig"),
        @embedFile("../domain/find_tools.zig"),
        @embedFile("../domain/historical.zig"),
        @embedFile("../domain/history_floor.zig"),
        @embedFile("../domain/model_admission.zig"),
        @embedFile("../domain/model_facts.zig"),
        @embedFile("../domain/model_attempt.zig"),
        @embedFile("../domain/model_settlement.zig"),
        @embedFile("../domain/operation_effort.zig"),
        @embedFile("../domain/reads.zig"),
        @embedFile("../domain/report.zig"),
        @embedFile("../domain/session_list_read.zig"),
        @embedFile("../domain/session_obligation.zig"),
        @embedFile("../domain/session_report_read.zig"),
        @embedFile("../domain/skills.zig"),
        @embedFile("../domain/tool_offer.zig"),
        @embedFile("../domain/tool_set.zig"),
        @embedFile("../domain/turn.zig"),
        @embedFile("../mysql_literal.zig"),
        @embedFile("../mysql_row.zig"),
        @embedFile("../rsql.zig"),
        @embedFile("../schema.zig"),
        @embedFile("../sqlite.zig"),
        @embedFile("../testing.zig"),
        @embedFile("../queue.zig"),
        @embedFile("../transition.zig"),
    };
    var found: std.EnumSet(EntryPoint) = .empty;
    var fixtures: [entering_fixtures.len]bool = @splat(false);
    // `transition.apply` enters for the entry point that calls it, so a
    // call to it enters as `enter` does, and its own `enter` is its callers'.
    // transition.zig, listed last.
    const runner = sources[sources.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, runner, "pub fn apply" ++ "(self: *Store") != null);
    inline for (sources) |source| inline for (.{ "enter", "transition.apply" }) |callee| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, callee ++ "(")) |index| : (at = index + 1) {
            if (index > 0 and (std.ascii.isAlphanumeric(source[index - 1]) or source[index - 1] == '_')) continue;
            if (std.mem.endsWith(u8, source[0..index], "fn ")) continue;
            // Every call enters with the Store it is a method of.
            if (!std.mem.startsWith(u8, source[index..], callee ++ "(self, ")) {
                std.debug.print("an {s} call takes another first argument: {s}\n", .{ callee, source[index..][0..@min(40, source.len - index)] });
                return error.EnterWithoutSelf;
            }
            const before = source[0..index];
            const fn_at = @max(std.mem.lastIndexOf(u8, before, " fn ") orelse 0, std.mem.lastIndexOf(u8, before, "\nfn ") orelse 0) + " fn ".len;
            var end = fn_at;
            while (std.ascii.isAlphanumeric(source[end]) or source[end] == '_') end += 1;
            if (source.ptr == runner.ptr and std.mem.eql(u8, source[fn_at..end], "apply")) continue;
            // The body a public entry point queues; only a test fixture
            // enters outside one, holding the Store for itself.
            const held = std.mem.endsWith(u8, source[fn_at..end], "Held");
            const name = if (held) source[fn_at .. end - "Held".len] else source[fn_at..end];
            if (!held and !std.mem.endsWith(u8, name, "ForTesting")) {
                std.debug.print("{s} enters the Store outside the queue; give it a body named {s}Held\n", .{ name, name });
                return error.EnterOutsideQueue;
            }
            if (std.mem.endsWith(u8, name, "ForTesting")) {
                const listed = for (entering_fixtures, 0..) |fixture, position| {
                    if (std.mem.eql(u8, fixture, name)) break position;
                } else {
                    std.debug.print("{s} enters the Store but is not in entering_fixtures\n", .{name});
                    return error.UnlistedFixture;
                };
                try std.testing.expect(!fixtures[listed]);
                fixtures[listed] = true;
                continue;
            }
            const point = std.meta.stringToEnum(EntryPoint, name) orelse {
                std.debug.print("{s} enters the Store but has no round budget\n", .{name});
                return error.EntryPointWithoutBudget;
            };
            try std.testing.expect(!found.contains(point));
            found.insert(point);
        }
    };
    try std.testing.expectEqual(std.enums.values(EntryPoint).len, found.count());
    for (fixtures) |seen| try std.testing.expect(seen);
}

test "MySQL round shape subtracts the entry baseline from every component" {
    const Shape = RoundMeter.QueryShape;
    const before: Shape = .{ .queries = 100, .access_passes = 10, .identity_passes = 4, .content_queries = 7, .controls = 12, .prefix_only = 3 };
    const after: Shape = .{ .queries = 109, .access_passes = 12, .identity_passes = 5, .content_queries = 10, .controls = 14, .prefix_only = 4 };
    const delta = after.since(before);
    try std.testing.expectEqual(@as(u64, 2), delta.access_passes);
    try std.testing.expectEqual(@as(u64, 1), delta.identity_passes);
    try std.testing.expectEqual(@as(u64, 3), delta.content_queries);
    try std.testing.expectEqual(@as(u64, 2), delta.controls);
    try std.testing.expectEqual(@as(u64, 1), delta.prefix_only);
    try std.testing.expectEqual(@as(u64, 9), delta.queries);
    try std.testing.expectEqual(delta.expected(), delta.queries);
}

test "each Store entry point takes its round budget on its common path" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            // A rerun repeats the rounds this counts.
            if (case.rerun) return;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var meter: RoundMeter = .{ .storage = &storage };
            meter.start();
            try storage.saveModelFacts(&.{.{ .id = "catalog-budget", .context_window = null, .efforts = .{}, .openai_listed = true }}, null);
            meter.stop(.saveModelFacts);
            meter.start();
            _ = try storage.readModelCatalogSource();
            meter.stop(.readModelCatalogSource);
            var catalog_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer catalog_arena.deinit();
            meter.start();
            _ = try storage.readModelCatalog(catalog_arena.allocator());
            meter.stop(.readModelCatalog);
            meter.start();
            _ = try storage.modelFact("catalog-budget");
            meter.stop(.modelFact);
            meter.start();
            const model_ids = try storage.readOpenAiModelIds(std.testing.allocator);
            defer {
                for (model_ids) |id| std.testing.allocator.free(id);
                std.testing.allocator.free(model_ids);
            }
            meter.stop(.readOpenAiModelIds);
            meter.start();
            try storage.saveHostToolSet(&tool_defs.built_in_tool_set);
            meter.stop(.saveHostToolSet);
            meter.start();
            const saved = (try storage.readHostToolSetSet()).?;
            meter.stop(.readHostToolSetSet);
            var rows: [tool_defs.built_in_tool_set.records.len]tool_set_domain.host_tool_records.Row = undefined;
            meter.start();
            try std.testing.expectEqual(rows.len, try storage.readHostToolSetRecords(saved.tool_set_id.get(), 0, &rows));
            meter.stop(.readHostToolSetRecords);
            var text: [tool_defs.bash_record.description.len]u8 = undefined;
            meter.start();
            try storage.readHostToolSetText(rows[0].description_id.get(), &text);
            meter.stop(.readHostToolSetText);
            try std.testing.expectEqualStrings(tool_defs.bash_record.description, &text);
            try plainTurn(&storage, &tmp, &meter);
            try toolTurn(&storage, &tmp, &meter);
            try compactedTurn(&storage, &tmp);
            try coreTurn(&storage, &tmp, &meter);
            try mcpTurn(case, &meter);
            try findTurn(&storage, &tmp, &meter);
            try skillTurn(case, &meter);
            var failed = false;
            for (std.enums.values(EntryPoint)) |point| {
                const measured = meter.measured.get(point) orelse {
                    std.debug.print("{s}: not driven\n", .{@tagName(point)});
                    failed = true;
                    continue;
                };
                if (measured.rounds != round_budgets.get(point)) failed = true;
                if (measured.content_rounds != contentRoundBudget(case.engine, point)) failed = true;
                if (case.engine == .mysql) {
                    std.testing.expectEqual(measured.shape.expected(), measured.shape.queries) catch {
                        std.debug.print("{s}: COM_QUERY shape differs\n", .{@tagName(point)});
                        failed = true;
                    };
                }
            }
            if (failed) {
                for (std.enums.values(EntryPoint)) |point| {
                    const measured = meter.measured.get(point) orelse continue;
                    std.debug.print(".{s} = {d} (budget {d}), content {d} (budget {d})\n", .{
                        @tagName(point),
                        measured.rounds,
                        round_budgets.get(point),
                        measured.content_rounds,
                        contentRoundBudget(case.engine, point),
                    });
                    if (case.engine == .mysql) std.debug.print(
                        "  COM_QUERY {d} = Access passes {d} + identity passes {d} + content queries {d} + controls {d} + prefix-only passes {d} (expected {d})\n",
                        .{
                            measured.shape.queries,
                            measured.shape.access_passes,
                            measured.shape.identity_passes,
                            measured.shape.content_queries,
                            measured.shape.controls,
                            measured.shape.prefix_only,
                            measured.shape.expected(),
                        },
                    );
                }
                return error.RoundBudgetChanged;
            }
            try std.testing.expect(!storage.isFenced());
        }

        const Launch = struct {
            fn run(_: void) !void {}
        };

        /// A Message answered with text, its result read back, a second
        /// Message interrupted, and a stop.
        fn plainTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            meter.start();
            const session = try configureTestSession(storage, "budget-plain");
            meter.stop(.configure);
            meter.start();
            try submitTestMessage(storage, tmp, "budget-plain-input", "budget-plain-key", session.slice(), "hello");
            meter.stop(.submitMessageWithModel);
            const search = try std.testing.allocator.create(protocol.ActivitySearchFacts);
            defer std.testing.allocator.destroy(search);
            var search_request: protocol.ActivitySearch = .{ .session = session, .kinds = .initOne(.admission), .limit = 1 };
            try search_request.query.set("hello");
            meter.start();
            try storage.searchActivity(&search_request, search);
            meter.stop(.searchActivity);
            try std.testing.expectEqual(@as(usize, 1), search.count);
            meter.start();
            _ = try store_testing.observeCommandForTesting(storage, "budget-plain-key");
            meter.stop(.observeCommand);
            meter.start();
            const binding = (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            meter.stop(.admitModelAttempt);
            meter.start();
            _ = try storage.modelOperationKind(binding);
            meter.stop(.checkAttempt);
            meter.start();
            try std.testing.expect(try storage.operationSupersededByControl(binding) == null);
            meter.stop(.operationSupersededByControl);
            meter.start();
            try storage.withDispatchHandoff(binding, {}, Launch.run);
            meter.stop(.withDispatchHandoff);
            meter.start();
            _ = try storage.claimModelAuthRefresh(binding);
            meter.stop(.claimModelAuthRefresh);
            const item = "{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}";
            meter.start();
            try settleItemsForTesting(storage, tmp, binding, &.{item}, "hi");
            meter.stop(.settleModelSuccess);
            meter.start();
            const result = try storage.commandResult("budget-plain-key");
            meter.stop(.commandResult);
            meter.start();
            const location = try storage.openContent(result);
            meter.stop(.openContentIdentity);
            var reader: ContentReader = undefined;
            reader.open(location);
            defer reader.close();
            var bytes: [64]u8 = undefined;
            meter.start();
            try std.testing.expectEqual(2, try reader.read(0, &bytes));
            meter.stop(.readOwnedContent);
            var request: protocol.ConversationPage = .{};
            try request.session.set(session.slice());
            var page: reads_domain.PublicConversationPage = undefined;
            meter.start();
            try storage.publicConversationPage(&request, &page);
            meter.stop(.publicConversationPage);
            const answer = for (page.items[0..page.count]) |entry| {
                if (entry.kind == .assistant) break entry.position;
            } else return error.NoAnswer;
            meter.start();
            _ = try storage.openPublicConversationContent(&.{ .session = session, .position = answer });
            meter.stop(.openPublicConversationContent);

            try submitTestMessage(storage, tmp, "budget-again-input", "budget-again-key", session.slice(), "again");
            const running = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var interrupt: protocol.ModelInterruptionCommand = .{ .turn_id = running.turn_id, .operation_id = running.operation_id };
            try interrupt.key.set("budget-interrupt");
            try interrupt.session.set(session.slice());
            meter.start();
            try std.testing.expect(storage.interruptModel(&interrupt, .{}) == .accepted);
            meter.stop(.interruptModel);
            var stop = try completeSessionStop("budget-stop", session.slice());
            meter.start();
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            meter.stop(.stopSession);
            var archive: protocol.SessionArchiveCommand = .{ .session = session };
            try archive.key.set("budget-archive");
            meter.start();
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            meter.stop(.archiveSession);
            archive.archived = false;
            try archive.key.set("budget-unarchive");
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
        }

        /// Drive MCP through an actual frozen tool set offer, without changing
        /// the built-in tool set used by the other entry points' fixtures.
        fn mcpTurn(case: *store_testing.Case, meter: *RoundMeter) !void {
            const records = comptime testingHostToolRecords(&.{
                .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a docs page.", .input_schema = "{\"type\":\"object\"}" },
            });
            const digests = comptime blk: {
                @setEvalBranchQuota(1_000_000);
                var out: [records.len][32]u8 = undefined;
                for (&records, &out) |*record, *digest| digest.* = tool_defs.recordDigest(record);
                break :blk out;
            };
            const host_tool_set: tool_defs.HostToolSet = .{ .records = &records, .digests = &digests };
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStoreWith(case, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
            defer storage.close() catch unreachable;
            const previous_storage = meter.storage;
            meter.storage = &storage;
            defer meter.storage = previous_storage;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("budget-mcp", "", workspace, "model-a");
            command.configuration.tools = try .of(&.{"fetch_page"});
            command.configuration.permission_mode.state = .value;
            try command.configuration.permission_mode.value.set("bypass");
            const configured = try storage.configure(&command, .{});
            try std.testing.expect(configured == .accepted);
            const session = configured.accepted.session;
            try submitTestMessage(&storage, &tmp, "budget-mcp-input", "budget-mcp-key", session.slice(), "fetch a page");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleCallsForTesting(&storage, &tmp, model, "budget-mcp-calls", &.{
                .{ .item_id = "mcp-item", .name = "fetch_page", .encoded_call_id = "mcp-call", .decoded_call_id = "mcp-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "mcp-item-two", .name = "fetch_page", .encoded_call_id = "mcp-call-two", .decoded_call_id = "mcp-call-two", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            });
            meter.start();
            const action = (try storage.nextAction(.mcp)).?;
            meter.stop(.nextAction);
            meter.start();
            try storage.resolveAction(action, .spawn_failed, "Failed, not run: this Host does not run MCP tool calls yet.", .{});
            meter.stop(.resolveAction);
            const second = (try storage.nextAction(.mcp)).?;
            meter.start();
            const binding = (try storage.admitActionAttempt(second, 600_000, .{})).?.permit.binding;
            meter.stop(.admitActionAttempt);
            var input: action_domain.ActionExecutionInput = undefined;
            meter.start();
            try storage.readActionExecutionInput(.mcp, binding, &input);
            meter.stop(.readMcpExecutionInput);
            _ = try storage.settleActionAttempt(binding, .succeeded, "done", .{});
            try std.testing.expect((try storage.nextAction(.mcp)) == null);
            try std.testing.expect((try storage.admitNextModelAttempt(.{})) != null);
        }

        /// Replay preflight, captured catalog read and bound ordinary skill
        /// settlement use their public entries, with real public metadata.
        fn skillTurn(case: *store_testing.Case, meter: *RoundMeter) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const previous_storage = meter.storage;
            meter.storage = &storage;
            defer meter.storage = previous_storage;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const skills = @import("../../skills.zig");
            const catalog: skills.Catalog = .{ .entries = &.{.{ .name = "demo", .description = "Budget skill", .path = "/budget/demo/SKILL.md" }} };
            const initial: skills_fixture_domain.Initial = .{ .ready = .{
                .encoded = try skills.encodeCatalog(arena.allocator(), catalog),
                .instruction = try skills.initialInstruction(arena.allocator(), catalog),
            } };
            var path: [protocol.max_workspace_bytes]u8 = undefined;
            var create = try completeConfiguration("budget-skill", "", try canonicalCwd(std.testing.io, &path), "model-a");
            create.configuration.tools = try .of(&.{"skill"});
            const session = (try storage.configureWithInitialSkills(&create, null, &initial, .{})).accepted.session;
            meter.start();
            try std.testing.expect(try storage.commandExists("budget-skill"));
            meter.stop(.commandExists);
            try std.testing.expect(!try storage.commandExists("budget-skill-absent"));
            meter.start();
            const saved = try storage.readSkills(arena.allocator(), session.slice());
            meter.stop(.readSkills);
            try std.testing.expectEqual(@as(usize, 1), saved.catalog.entries.len);
            try std.testing.expectEqualStrings("demo", saved.catalog.entries[0].name);
            try std.testing.expectEqualStrings("/budget/demo/SKILL.md", saved.catalog.entries[0].path);
            try submitTestMessage(&storage, &tmp, "budget-skill-input", "budget-skill-key", session.slice(), "use demo");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "skill-item", .name = "skill", .encoded_call_id = "skill-call", .decoded_call_id = "skill-call", .encoded_arguments = "{\\\"operation\\\":\\\"invoke\\\",\\\"name\\\":\\\"demo\\\"}", .decoded_arguments = "{\"operation\":\"invoke\",\"name\":\"demo\"}" }};
            try settleCallsForTesting(&storage, &tmp, model, "budget-skill-calls", &calls);
            const input = (try storage.nextCoreWork()).?.action;
            try std.testing.expectEqual(action_domain.CoreTool.skill, input.tool);
            const captured: skills_fixture_domain.Capture = .{ .invocation = "Skill file: \"/budget/demo/SKILL.md\"\n\nbudget bytes" };
            meter.start();
            try std.testing.expect(try storage.settleSkillTool(input.binding, arena.allocator(), &captured, .{}));
            meter.stop(.settleSkillTool);
            try std.testing.expect(!storage.isFenced());
        }

        /// SQL narrows one unloaded tool; eight matchers share one description
        /// window. A no-match call still writes no revision.
        fn findTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            var path: [protocol.max_workspace_bytes]u8 = undefined;
            var configuration = try completeConfiguration("budget-find", "", try canonicalCwd(std.testing.io, &path), "model-a");
            configuration.configuration.tools = try .of(&.{ "bash", "find_tools" });
            configuration.configuration.loaded_tools = try .of(&.{"find_tools"});
            const session = (try storage.configure(&configuration, .{})).accepted.session;
            try submitTestMessage(storage, tmp, "budget-find-input", "budget-find-key", session.slice(), "find tools");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "find-item", .name = "find_tools", .encoded_call_id = "find-call", .decoded_call_id = "find-call", .encoded_arguments = "{\\\"words\\\":\\\"absent0 absent1 absent2 absent3 absent4 absent5 absent6 absent7\\\"}", .decoded_arguments = "{\"words\":\"absent0 absent1 absent2 absent3 absent4 absent5 absent6 absent7\"}" }};
            try settleCallsForTesting(storage, tmp, model, "budget-find-calls", &calls);
            const input = (try storage.nextCoreWork()).?.action;
            const words: @import("../../core_tools.zig").FindTools = .{ .words = .{ "absent0", "absent1", "absent2", "absent3", "absent4", "absent5", "absent6", "absent7" }, .count = 8 };
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            meter.start();
            try std.testing.expect(try storage.findTools(input.binding, arena.allocator(), &words, null, .{}));
            meter.stop(.findTools);
        }

        /// Three core calls: a Message delivered, an agent started, and a
        /// start whose arguments the Host refused; then the stop the started
        /// child owes once its parent stops.
        fn coreTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var command = try completeConfiguration("budget-core", "", workspace, "model-a");
            command.configuration.tools.state = .value;
            command.configuration.tools = try .of(&.{ "message_agent", "start_agent" });
            const session = (try storage.configure(&command, .{})).accepted.session;
            try submitTestMessage(storage, tmp, "budget-core-input", "budget-core-key", session.slice(), "message yourself");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var arguments_buffer: [64]u8 = undefined;
            const decoded = try std.fmt.bufPrint(&arguments_buffer, "{{\"id\":\"{s}\",\"text\":\"hi\"}}", .{session.slice()});
            var encoded_buffer: [96]u8 = undefined;
            const encoded = try std.fmt.bufPrint(&encoded_buffer, "{{\\\"id\\\":\\\"{s}\\\",\\\"text\\\":\\\"hi\\\"}}", .{session.slice()});
            const calls = [_]TestingCall{
                .{ .item_id = "core-item", .name = "message_agent", .encoded_call_id = "core-call", .decoded_call_id = "core-call", .encoded_arguments = encoded, .decoded_arguments = decoded },
                .{ .item_id = "start-item", .name = "start_agent", .encoded_call_id = "start-call", .decoded_call_id = "start-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
                .{ .item_id = "refused-item", .name = "start_agent", .encoded_call_id = "refused-call", .decoded_call_id = "refused-call", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTesting(storage, tmp, model, "budget-core-calls", &calls);
            meter.start();
            const core = (try storage.nextCoreWork()).?.action;
            meter.stop(.nextCoreWork);
            meter.start();
            try std.testing.expect(try storage.deliverAgentMessage(core.binding, session.slice(), "hi", .{}) == .delivered);
            meter.stop(.deliverAgentMessage);
            const start = (try storage.nextCoreWork()).?.action;
            try std.testing.expect(start.tool == .start_agent);
            var spec = try testingAgentSpec(&.{"message_agent"}, "ask");
            meter.start();
            try std.testing.expect(try storage.startAgent(start.binding, session.slice(), "look around", true, &spec, null, .{}) == .started);
            meter.stop(.startAgent);
            const refused = (try storage.nextCoreWork()).?.action;
            meter.start();
            try std.testing.expect(try storage.failCoreCall(refused.binding, "Rui could not start the agent: task is required. Nothing was started.", .{}));
            meter.stop(.resolveCoreCall);
            // A Tool Result's identity comes from its original call, not the
            // group's position. Drive the public read on the last ordinal.
            const result_page = try store_core.activityPageForTesting(storage, .{ .session = session, .direction = .backward, .kinds = .initOne(.tool_result), .limit = 1 });
            const result = result_page.items[0];
            try std.testing.expectEqual(@as(u64, 3), result.ordinal);
            meter.start();
            const tool = try storage.activityTool(&.{ .session = session, .position = result.position, .ordinal = result.ordinal });
            meter.stop(.activityTool);
            try std.testing.expect(tool.presentation.code == .failed);
            try expectContent(storage, .{ .length = tool.name.length, .digest = tool.name.digest }, "start_agent");
            // Admit the child task so stopping it closes a Turn.
            while (try storage.admitNextModelAttempt(.{})) |_| {}
            var stop = try completeSessionStop("budget-core-stop", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            const owed = (try storage.nextCoreWork()).?.stop;
            var owed_stop: protocol.SessionStopCommand = .{ .key = owed.key };
            try owed_stop.session.set(owed.session.slice());
            meter.start();
            try std.testing.expect(storage.stopOwedSession(&owed_stop, .{}) == .accepted);
            meter.stop(.stopOwedSession);
            const ending = (try storage.nextCoreWork()).?.ending;
            meter.start();
            try std.testing.expect(try storage.deliverChildEnding(ending.turn_id, .{}));
            meter.stop(.deliverChildEnding);
            const forward = (try storage.nextCoreWork()).?.forward;
            meter.start();
            try std.testing.expect(try storage.deliverSessionForward(forward, .{}));
            meter.stop(.deliverSessionForward);
        }

        /// Two Bash calls under ask: one allowed, run and settled, one
        /// denied; then the continuation's history, its failure, and the
        /// Session's reads.
        fn toolTurn(storage: *Store, tmp: *std.testing.TmpDir, meter: *RoundMeter) !void {
            const session = try configureTestSessionAsk(storage, "budget-tools");
            try submitTestMessage(storage, tmp, "budget-tools-input", "budget-tools-key", session.slice(), "run");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const arguments = "{\\\"description\\\":\\\"Disk usage\\\",\\\"cmd\\\":\\\"df -h\\\",\\\"timeout_ms\\\":null}";
            const decoded = "{\"description\":\"Disk usage\",\"cmd\":\"df -h\",\"timeout_ms\":null}";
            const calls = [_]TestingCall{
                .{ .item_id = "item-a", .name = "bash", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = arguments, .decoded_arguments = decoded },
                .{ .item_id = "item-b", .name = "bash", .encoded_call_id = "call-b", .decoded_call_id = "call-b", .encoded_arguments = arguments, .decoded_arguments = decoded },
            };
            try settleCallsForTesting(storage, tmp, first, "budget-calls", &calls);
            const allowed = try store_testing.queryU64(storage, "SELECT min(action_id) FROM action_operation", .{});
            const denied = try store_testing.queryU64(storage, "SELECT max(action_id) FROM action_operation", .{});
            meter.start();
            _ = try storage.actionArguments(session.slice(), allowed);
            meter.stop(.actionContent);
            var allow: protocol.PermissionDecisionCommand = .{ .action_id = allowed, .decision = .allow_once };
            try allow.key.set("budget-allow");
            try allow.session.set(session.slice());
            meter.start();
            try std.testing.expect(storage.decidePermission(&allow, .{}) == .accepted);
            meter.stop(.decidePermission);
            meter.start();
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            meter.stop(.admitNextActionAttempt);
            var input: ActionExecutionInput = undefined;
            meter.start();
            try storage.readActionExecutionInput(.bash, action, &input);
            meter.stop(.readBashExecutionInput);
            meter.start();
            try storage.withActionDispatchHandoff(action, {}, Launch.run);
            meter.stop(.withActionDispatchHandoff);
            meter.start();
            try std.testing.expect(try storage.actionSupersededByStop(action) == null);
            meter.stop(.actionSupersededByStop);
            meter.start();
            try storage.revokeActionSender(action);
            meter.stop(.revokeActionSender);
            meter.start();
            _ = try storage.settleActionAttempt(action, .succeeded, "Bash succeeded.", .{});
            meter.stop(.settleActionAttempt);
            var deny: protocol.PermissionDecisionCommand = .{ .action_id = denied, .decision = .deny };
            try deny.key.set("budget-deny");
            try deny.session.set(session.slice());
            try std.testing.expect(storage.decidePermission(&deny, .{}) == .accepted);
            meter.start();
            try std.testing.expect(!try storage.recoverOneUncertainAction(ActiveOperationFilter.empty()));
            meter.stop(.recoverOneUncertainAction);

            // The continuation also offers web search, so its tools stage
            // reads a provider-run member.
            var add_search: wire_request.ConfigureCommand = .{};
            try add_search.key.set("budget-add-search");
            try add_search.session.set(session.slice());
            add_search.configuration.tools = try .of(&.{ "bash", "web_search" });
            add_search.configuration.tools.state = .value;
            try std.testing.expect(try storage.configure(&add_search, .{}) == .accepted);
            const continuation = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            {
                var view: HistoricalView = undefined;
                storage.openHistoricalView(continuation, &view);
                defer view.close();
                meter.start();
                _ = try view.validateOutputsStep();
                meter.stop(.validateHistoricalOutputsStep);
                while (!try view.validateOutputsStep()) {}
                var settings: HistoricalSettings = undefined;
                meter.start();
                try view.settings(&settings);
                meter.stop(.readHistoricalSettings);
                var tool: historical_domain.HistoricalTool = .{};
                meter.start();
                try std.testing.expect(try view.nextTool(&tool));
                meter.stop(.readTools);
                // Web search, past Bash.
                meter.start();
                try std.testing.expect(try view.nextProviderTool(&tool));
                meter.stop(.readProviderTool);
                // Bash was declared at the first Operation already, so the
                // one read finds nothing to declare.
                _ = try view.coverage();
                var declaration = view.currentDeclaration();
                const declared = ViewRounds.start(storage);
                try std.testing.expect(!try view.nextDeclaredTool(&declaration, &tool));
                try std.testing.expectEqual(@as(u16, 1), declared.taken().rounds);
                meter.start();
                var entry = (try view.nextEntry(0)).?;
                meter.stop(.readHistoricalEntry);
                entry = (try nextTestingItem(&view, entry.position)).?;
                try std.testing.expectEqual(HistoricalEntryKind.provider_output, entry.kind);
                meter.start();
                _ = try view.openOutput(entry.position);
                _ = try view.nextOutputPart();
                meter.stop(.readHistoricalParts);
                while (entry.kind != .tool_results) entry = (try nextTestingItem(&view, entry.position)).?;
                meter.start();
                _ = (try view.nextToolResult()).?;
                meter.stop(.readHistoricalToolResult);
                meter.start();
                try std.testing.expect(try view.prefixSeal() == null);
                meter.stop(.readPrefixSeal);
                const seal: historical_domain.PrefixSeal = .{ .anchor = null, .admission_position = 1, .span_length = 0, .digest = @splat(0) };
                meter.start();
                try view.recordPrefixSeal(&seal);
                meter.stop(.recordPrefixSeal);
            }
            meter.start();
            try storage.settleModelAttemptFailure(continuation, .{ .uncorrelated = "provider_http_422" }, .ordinary, .{});
            meter.stop(.settleModelAttemptFailure);
            meter.start();
            try std.testing.expect(try storage.tryAdmitNextModelRetry(ActiveOperationFilter.empty(), .{}, null) == null);
            meter.stop(.tryAdmitNextModelRetry);
            meter.start();
            _ = try storage.dispatchWork(false);
            meter.stop(.dispatchWork);
            meter.start();
            try std.testing.expect(!try storage.recoverOneExhaustedModelAttempt(ActiveOperationFilter.empty()));
            meter.stop(.recoverOneExhaustedModelAttempt);

            meter.start();
            _ = try storage.inspectSessionForTesting(session.slice());
            meter.stop(.inspectSession);
            var activity: protocol.ActivityPage = .{};
            try activity.session.set(session.slice());
            meter.start();
            const rows = try store_core.activityPageForTesting(storage, activity);
            meter.stop(.activityPage);
            meter.start();
            _ = try storage.openActivityContent(&.{ .session = session, .position = rows.items[0].position });
            meter.stop(.openActivityContent);
            meter.start();
            std.testing.allocator.free(try testingSessionReport(storage, tmp, session.slice(), 1024 * 1024));
            meter.stop(.readSessionReport);
            var used = std.atomic.Value(u64).init(0);
            meter.start();
            std.testing.allocator.free(try testingSessionList(storage, tmp, .{}, &used, 2));
            meter.stop(.readSessionList);
            meter.start();
            const binding = try storage.failedResponseBinding(session.slice(), continuation.operation_id, continuation.attempt_ordinal);
            meter.stop(.failedResponseBinding);
            try std.testing.expectEqualDeep(continuation, binding);
        }

        /// A Turn over the compaction trigger, compacted, so its
        /// successor's history starts at an anchor.
        fn compactedTurn(storage: *Store, tmp: *std.testing.TmpDir) !void {
            const session = try configureTestSession(storage, "budget-compacted");
            var patch: wire_request.ConfigureCommand = .{};
            try patch.key.set("budget-heuristics");
            try patch.session.set(session.slice());
            patch.configuration.compaction_trigger.state = .value;
            try patch.configuration.compaction_trigger.value.set("1000");
            patch.configuration.output_reservation.state = .value;
            try patch.configuration.output_reservation.value.set("1");
            try std.testing.expect(try storage.configure(&patch, .{}) == .accepted);
            try submitTestMessage(storage, tmp, "budget-one", "budget-one", session.slice(), "original");
            const first = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "item-a", .name = "unknown", .encoded_call_id = "call-a", .decoded_call_id = "call-a", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            };
            try settleCallsForTestingWithFaults(storage, tmp, first, "budget-usage", &calls, .{}, "{\"input_tokens\":99999,\"output_tokens\":1,\"details\":{\"input_tokens\":0}}");
            try submitTestMessage(storage, tmp, "budget-two", "budget-two", session.slice(), "later");
            const compaction = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try std.testing.expectEqual(ModelOperationKind.compaction, try storage.modelOperationKind(compaction));
            try settleCompactionForTesting(storage, tmp, compaction, &.{.compaction});
            const successor = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var view: HistoricalView = undefined;
            storage.openHistoricalView(successor, &view);
            defer view.close();
            // The boundary's round brought the base's anchor.
            while (!try view.validateOutputsStep()) {}
            const rounds = ViewRounds.start(storage);
            try std.testing.expect((try view.coverage()).anchor != null);
            try std.testing.expectEqual(@as(u16, 0), rounds.taken().rounds);
        }
    }.run);
}
