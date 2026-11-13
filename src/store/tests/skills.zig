//! Skills Store conformance tests.

const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const wire_request = @import("../../wire_request.zig");
const store_core = @import("../Store.zig");
const store_access = @import("../access.zig");
const Store = store_core.Store;
const action_domain = @import("../domain/action.zig");
const configuration_domain = @import("../domain/configuration.zig");
const content_domain = @import("../domain/content.zig");
const historical_domain = @import("../domain/historical.zig");
const store_testing = @import("../testing.zig");
const AttemptBinding = store_core.AttemptBinding;
const ActionExecutionInput = action_domain.ActionExecutionInput;
const ContentReader = content_domain.ContentReader;
const Faults = store_core.Faults;
const HistoricalView = historical_domain.HistoricalView;
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const completeMessage = store_testing.completeMessage;
const configureTestSession = store_testing.configureTestSession;
const submitTestMessage = store_testing.submitTestMessage;
const skills_fixture_domain = @import("../domain/skills.zig");
const TestingCall = shared_fixtures.TestingCall;
const completeSessionStop = shared_fixtures.completeSessionStop;
const expectContent = shared_fixtures.expectContent;
const settleCallsForTesting = shared_fixtures.settleCallsForTesting;
const settleTwoActionsForTesting = shared_fixtures.settleTwoActionsForTesting;
const testingAgentSpec = shared_fixtures.testingAgentSpec;
const testingBytesContent = shared_fixtures.testingBytesContent;
const testingContentReference = shared_fixtures.testingContentReference;
const testingSessionReportWithProfile = shared_fixtures.testingSessionReportWithProfile;

const skills_fixture_initial: skills_fixture_domain.Initial = .{ .ready = .{
    .encoded = "{\"entries\":[{\"name\":\"child-catalog\",\"description\":\"Captured after the parent was created\",\"path\":\"/skills/child-catalog/SKILL.md\"}]}",
    .instruction = "Available skills: child-catalog at /skills/child-catalog/SKILL.md",
} };

test "skills start_agent imports six distinct contents atomically and retries after reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            for ([_]bool{ false, true }) |before_commit| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                // The parent predates capture: none of the child's new content
                // can be deduplicated against an inherited catalog or reload.
                var create = try completeConfiguration("skills-six-parent", "", workspace, "model-a");
                create.configuration.tools = try .of(&.{"start_agent"});
                const parent = (try storage.configure(&create, .{})).accepted.session;
                try submitTestMessage(&storage, &tmp, "skills-six-input", "skills-six-input", parent.slice(), "Please start a fresh worker");
                const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                try settleCallsForTesting(&storage, &tmp, model, "skills-six-call", &.{.{
                    .item_id = "skills-six-item",
                    .name = "start_agent",
                    .encoded_call_id = "skills-six-call",
                    .decoded_call_id = "skills-six-call",
                    .encoded_arguments = "{}",
                    .decoded_arguments = "{}",
                }});
                const action = (try storage.nextCoreWork()).?.action;
                const baseline = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                const parent_position = (try store_core.readSessionForTesting(&storage, parent.slice())).?.next_position;
                const task = "A distinct child task captured after its parent existed";
                const authored = "Distinct child-authored instructions, not a catalog";
                const schema = "{\"type\":\"object\",\"properties\":{\"six_imports\":{\"type\":\"boolean\"}}}";
                var spec = try testingAgentSpec(&.{}, "ask");
                spec.instructions = .{ .state = .value, .borrowed = authored.ptr, .length = authored.len, .digest = protocol.contentDigest(authored) };
                spec.output_schema = .{ .state = .value, .borrowed = schema.ptr, .length = schema.len, .digest = protocol.contentDigest(schema) };
                const Capture = struct {
                    child: protocol.Bounded(protocol.session_id_bytes) = .{},
                    calls: usize = 0,
                    fn call(context: *anyopaque, admission: Store.MessageAdmission) void {
                        const self: *@This() = @ptrCast(@alignCast(context));
                        self.child.set(admission.session) catch unreachable;
                        self.calls += 1;
                    }
                };
                var capture: Capture = .{};
                const callback: Store.MessageCommitted = .{ .context = &capture, .call = Capture.call };
                try std.testing.expectError(if (before_commit) error.InjectedCommitFailure else error.InjectedContentImportFailure, storage.startAgentWithInitialSkills(action.binding, parent.slice(), task, true, &spec, callback, &skills_fixture_initial, null, .{
                    .before_commit = before_commit,
                    .content_import = !before_commit,
                }));
                try std.testing.expect(storage.isFenced());
                try std.testing.expectEqual(@as(usize, 0), capture.calls);
                try storage.close();
                opened = false;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                try std.testing.expectEqual(baseline, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog", .{}));
                try std.testing.expectEqual(parent_position, (try store_core.readSessionForTesting(&storage, parent.slice())).?.next_position);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE resolution_code IS NOT NULL", .{}));
                try std.testing.expect(try storage.startAgentWithInitialSkills(action.binding, parent.slice(), task, true, &spec, callback, &skills_fixture_initial, null, .{}) == .started);
                try std.testing.expectEqual(@as(usize, 1), capture.calls);
                try std.testing.expectEqual(baseline + 6, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                var result_buffer: [64]u8 = undefined;
                const started = try std.fmt.bufPrint(&result_buffer, "Started {s}.", .{capture.child.slice()});
                for ([_][]const u8{ authored, schema, skills_fixture_initial.ready.encoded, skills_fixture_initial.ready.instruction.?, task, started }) |bytes| {
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM content WHERE digest=?1 AND byte_length=?2 AND private=0", .{ store_testing.Blob{ .bytes = &protocol.contentDigest(bytes) }, bytes.len }));
                }
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry e JOIN session_skill_catalog c ON c.session_ref=e.session_ref AND c.position=e.source_catalog_position JOIN content text_content ON text_content.content_id=e.content_id JOIN content metadata ON metadata.content_id=c.catalog_content_id WHERE e.session_ref=?1 AND e.entry_kind=2 AND e.turn_id IS NULL AND e.source_revision IS NULL AND e.source_admission_id IS NULL AND e.source_operation_id IS NULL AND e.session_position=e.source_catalog_position AND text_content.private=0 AND metadata.private=0", .{capture.child.slice()}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog WHERE session_ref=?1", .{parent.slice()}));
                const child = (try store_core.readSessionForTesting(&storage, capture.child.slice())).?;
                try std.testing.expectEqualSlices(u8, &protocol.contentDigest(authored), &(try testingContentReference(&storage, @intCast(child.instructions_id.?))).digest);
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const state = try storage.readSkills(arena.allocator(), capture.child.slice());
                try std.testing.expectEqual(@as(usize, 1), state.catalog.entries.len);
                try std.testing.expectEqualStrings("/skills/child-catalog/SKILL.md", state.catalog.entries[0].path);
            }
        }
    }.run);
}

test "skills catalog provenance fences readSkills history and full reports" {
    try store_testing.forEachEngine(struct {
        fn scan(storage: *Store, binding: AttemptBinding) !void {
            var view: HistoricalView = undefined;
            storage.openHistoricalView(binding, &view);
            defer view.close();
            var position: u64 = 0;
            while (try view.nextEntry(position)) |entry| position = entry.position;
        }

        fn run(case: *store_testing.Case) !void {
            const Corruption = enum { detached, private_metadata, private_instruction };
            const Consumer = enum { skills, history, full_report };
            for ([_]Corruption{ .detached, .private_metadata, .private_instruction }) |corruption| {
                for ([_]Consumer{ .skills, .history, .full_report }) |consumer| {
                    var tmp = std.testing.tmpDir(.{});
                    defer tmp.cleanup();
                    var storage: Store = undefined;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    defer storage.close() catch unreachable;
                    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                    var create = try completeConfiguration("skills-certificate", "", workspace, "model-a");
                    const session = (try storage.configureWithInitialSkills(&create, null, &skills_fixture_initial, .{})).accepted.session;
                    try submitTestMessage(&storage, &tmp, "skills-certificate-input", "skills-certificate-input", session.slice(), "Read the catalog");
                    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
                    switch (corruption) {
                        .detached => try store_testing.exec(&storage, "DELETE FROM conversation_entry WHERE session_ref=?1 AND source_catalog_position IS NOT NULL", .{session.slice()}),
                        .private_metadata => try store_testing.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT catalog_content_id FROM session_skill_catalog WHERE session_ref=?1)", .{session.slice()}),
                        .private_instruction => try store_testing.exec(&storage, "UPDATE content SET private=1 WHERE content_id=(SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND source_catalog_position IS NOT NULL)", .{session.slice()}),
                    }
                    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                    defer arena.deinit();
                    switch (consumer) {
                        .skills => try std.testing.expectError(error.CorruptStore, storage.readSkills(arena.allocator(), session.slice())),
                        .history => try std.testing.expectError(error.CorruptStore, scan(&storage, binding)),
                        .full_report => try std.testing.expectError(error.CorruptStore, testingSessionReportWithProfile(&storage, &tmp, session.slice(), 1024 * 1024, .full)),
                    }
                    try std.testing.expect(storage.isFenced());
                    try std.testing.expectError(error.StoreFenced, storage.readSkills(arena.allocator(), session.slice()));
                }
            }
        }
    }.run);
}

test "skills empty initial snapshot is valid and schema rejects mismatched catalog positions" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("skills-empty", "", workspace, "model-a");
            const empty: skills_fixture_domain.Initial = .{ .ready = .{ .encoded = "{\"entries\":[]}", .instruction = null } };
            const session = (try storage.configureWithInitialSkills(&create, null, &empty, .{})).accepted.session;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const state = try storage.readSkills(arena.allocator(), session.slice());
            try std.testing.expectEqual(@as(usize, 0), state.catalog.entries.len);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog WHERE session_ref=?1 AND position=0", .{session.slice()}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE session_ref=?1 AND source_catalog_position IS NOT NULL", .{session.slice()}));
            var reload: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
            try reload.key.set("skills-empty-reload");
            const candidate: skills_fixture_domain.Capture = .{ .reload = .{ .entries = &.{.{ .name = "nonempty", .description = "now available", .path = "/skills/nonempty/SKILL.md" }} } };
            try std.testing.expect(try storage.configureWithCapturedSkills(&reload, null, null, &candidate, std.testing.allocator, .{}) == .accepted);
            // Position zero exists, so the FK alone cannot reject this: the
            // catalog instruction must certify its own conversation position.
            const constraint_error = if (case.engine == .mysql) error.MysqlFixtureFailed else error.StatementFailed;
            try std.testing.expectError(constraint_error, store_testing.exec(&storage, "UPDATE conversation_entry SET source_catalog_position=0 WHERE session_ref=?1 AND source_catalog_position IS NOT NULL", .{session.slice()}));
            try std.testing.expect(!storage.isFenced());
            const reloaded = try storage.readSkills(arena.allocator(), session.slice());
            try std.testing.expectEqual(@as(usize, 1), reloaded.catalog.entries.len);
        }
    }.run);
}

test "skills initial catalog equal to an earlier Session's shares its content and starts the conversation" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var sessions: [2]protocol.Bounded(protocol.max_session_bytes) = undefined;
            for (&sessions, [_][]const u8{ "skills-shared-first", "skills-shared-second" }) |*session, key| {
                var create = try completeConfiguration(key, "", workspace, "model-a");
                session.* = (try storage.configureWithInitialSkills(&create, null, &skills_fixture_initial, .{})).accepted.session;
            }
            const catalog_sql = "SELECT catalog_content_id FROM session_skill_catalog WHERE session_ref=?1";
            const text_sql = "SELECT content_id FROM conversation_entry WHERE session_ref=?1 AND source_catalog_position IS NOT NULL";
            try std.testing.expectEqual(try store_testing.queryU64(&storage, catalog_sql, .{sessions[0].slice()}), try store_testing.queryU64(&storage, catalog_sql, .{sessions[1].slice()}));
            try std.testing.expectEqual(try store_testing.queryU64(&storage, text_sql, .{sessions[0].slice()}), try store_testing.queryU64(&storage, text_sql, .{sessions[1].slice()}));
            for (sessions) |session| try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT entry_ordinal FROM conversation_entry WHERE session_ref=?1 AND source_catalog_position IS NOT NULL", .{session.slice()}));
        }
    }.run);
}

test "skills a Message's refusal diagnostic that fails to import saves nothing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("skills-diagnostic-session", "", workspace, "model-a");
            const session = (try storage.configure(&create, .{})).accepted.session;
            const text = "/missing please";
            const file = try tmp.dir.createFile(std.testing.io, "skills-diagnostic-text", .{ .read = true });
            try file.writeStreamingAll(std.testing.io, text);
            try file.sync(std.testing.io);
            var message = try completeMessage("skills-diagnostic-message", session.slice(), file, text);
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            const diagnostic = "Skill missing is not in this Session's saved catalog; nothing was sent.";
            const captured: skills_fixture_domain.MessageCapture = .{ .failed = .{ .code = .skill_file_unavailable, .bytes = diagnostic } };
            try std.testing.expect(storage.submitMessageCapturedSkills(&message, null, null, &captured, .{ .content_import = true }) == .infrastructure_failure);
            try std.testing.expect(storage.isFenced());
            try storage.close();
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try std.testing.expect((try store_testing.observeCommandForTesting(&storage, "skills-diagnostic-message")).status == .absent);
            const rejected = storage.submitMessageCapturedSkills(&message, null, null, &captured, .{});
            try std.testing.expect(rejected == .rejected and !rejected.rejected.replayed);
            try std.testing.expectEqual(protocol.MessageRejection.skill_file_unavailable, rejected.rejected.code);
            try std.testing.expectEqual(@as(u64, diagnostic.len), try store_testing.queryU64(&storage, "SELECT content.byte_length FROM core_command JOIN content ON content.content_id=core_command.primary_content_id WHERE command_key=?1", .{"skills-diagnostic-message"}));
        }
    }.run);
}

test "skills a creating Message saves the skills its text bound with its admission" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            const settings = try completeConfiguration("skills-creating", "", workspace, "model-a");
            var message: wire_request.MessageCommand = .{ .configuration = settings.configuration };
            try message.key.set("skills-creating");
            message.text = try testingBytesContent(&tmp, "skills-creating-text", "use /demo");
            defer message.removeTemporaryContent(std.testing.io) catch unreachable;
            const capture: skills_fixture_domain.MessageCapture = .{ .bound = &.{.{ .name = "demo", .bytes = "demo body" }} };
            const reply = storage.submitMessageCapturedSkills(&message, null, null, &capture, .{});
            try std.testing.expect(reply == .accepted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_skill k JOIN content c ON c.content_id=k.content_id WHERE k.admission_id=?1 AND k.name='demo' AND c.digest=?2", .{ reply.accepted.admission_id, store_testing.Blob{ .bytes = &protocol.contentDigest("demo body") } }));
        }
    }.run);
}

test "a Message's replay whose admission names other content fences the Store" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "replay-content");
            var first = try completeMessage("replay-content-first", session.slice(), try tmp.dir.createFile(std.testing.io, "first", .{ .read = true }), "first text");
            try first.text.file.?.writeStreamingAll(std.testing.io, "first text");
            defer first.removeTemporaryContent(std.testing.io) catch unreachable;
            var second = try completeMessage("replay-content-second", session.slice(), try tmp.dir.createFile(std.testing.io, "second", .{ .read = true }), "second text");
            try second.text.file.?.writeStreamingAll(std.testing.io, "second text");
            defer second.removeTemporaryContent(std.testing.io) catch unreachable;
            try std.testing.expect(storage.submitMessageWithModel(&first, null, .{}) == .accepted);
            try std.testing.expect(storage.submitMessageWithModel(&second, null, .{}) == .accepted);
            try std.testing.expect(storage.submitMessageWithModel(&first, null, .{}).accepted.replayed);
            const other = try store_testing.queryU64(&storage, "SELECT content_id FROM message_admission WHERE command_key=?1", .{"replay-content-second"});
            try store_testing.exec(&storage, "UPDATE message_admission SET content_id=?2 WHERE command_key=?1", .{ "replay-content-first", other });
            try std.testing.expect(storage.submitMessageWithModel(&first, null, .{}) == .infrastructure_failure);
            try std.testing.expect(storage.isFenced());
        }
    }.run);
}

test "skills reload out of memory in configure or the skill tool rolls back without fencing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const skills = @import("../../skills.zig");
            // Enough entries that reading the saved catalog allocates
            // inside the write, not only the candidate's encoding.
            const entries = try arena.allocator().alloc(skills.Entry, 66);
            for (entries, 0..) |*entry, index| entry.* = .{
                .name = try std.fmt.allocPrint(arena.allocator(), "skill-{d:0>3}", .{index}),
                .description = "reload pressure",
                .path = try std.fmt.allocPrint(arena.allocator(), "/skills/skill-{d:0>3}/SKILL.md", .{index}),
            };
            const saved: skills.Catalog = .{ .entries = entries[0..64] };
            const initial: skills_fixture_domain.Initial = .{ .ready = .{
                .encoded = try skills.encodeCatalog(arena.allocator(), saved),
                .instruction = try skills.initialInstruction(arena.allocator(), saved),
            } };
            var path: [protocol.max_workspace_bytes]u8 = undefined;
            var create = try completeConfiguration("reload-oom", "", try canonicalCwd(std.testing.io, &path), "model-a");
            create.configuration.tools = try .of(&.{"skill"});
            const session = (try storage.configureWithInitialSkills(&create, null, &initial, .{})).accepted.session;

            var reload: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
            try reload.key.set("reload-oom-configure");
            const configured: skills_fixture_domain.Capture = .{ .reload = .{ .entries = entries[0..65] } };
            var fail_index: usize = 0;
            while (true) : (fail_index += 1) {
                var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
                const reply = storage.configureWithCapturedSkills(&reload, null, null, &configured, failing.allocator(), .{});
                try std.testing.expect(!storage.isFenced());
                if (!failing.has_induced_failure) {
                    try std.testing.expectEqual(protocol.SkillsReloadStatus.reloaded, (try reply).accepted.skills.?);
                    break;
                }
                try std.testing.expectError(error.OutOfMemory, reply);
                try std.testing.expect(!try storage.commandExists("reload-oom-configure"));
            }
            try std.testing.expect(fail_index > 1);
            try std.testing.expectEqual(@as(usize, 65), (try storage.readSkills(arena.allocator(), session.slice())).catalog.entries.len);

            try submitTestMessage(&storage, &tmp, "reload-oom-input", "reload-oom-message", session.slice(), "reload skills");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{.{ .item_id = "reload-item", .name = "skill", .encoded_call_id = "reload-call", .decoded_call_id = "reload-call", .encoded_arguments = "{\\\"operation\\\":\\\"reload\\\"}", .decoded_arguments = "{\"operation\":\"reload\"}" }};
            try settleCallsForTesting(&storage, &tmp, model, "reload-oom-calls", &calls);
            const input = (try storage.nextCoreWork()).?.action;
            const tool: skills_fixture_domain.Capture = .{ .reload = .{ .entries = entries } };
            fail_index = 0;
            while (true) : (fail_index += 1) {
                var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
                var memory: std.heap.ArenaAllocator = .init(failing.allocator());
                defer memory.deinit();
                const settled = storage.settleSkillTool(input.binding, memory.allocator(), &tool, .{});
                try std.testing.expect(!storage.isFenced());
                if (!failing.has_induced_failure) {
                    try std.testing.expect(try settled);
                    break;
                }
                try std.testing.expectError(error.OutOfMemory, settled);
                try std.testing.expectEqual(@as(usize, 65), (try storage.readSkills(arena.allocator(), session.slice())).catalog.entries.len);
            }
            try std.testing.expect(fail_index > 1);
            try std.testing.expectEqual(@as(usize, 66), (try storage.readSkills(arena.allocator(), session.slice())).catalog.entries.len);
        }
    }.run);
}

test "skills peer refusal persists authenticated activity diagnostic and keyed replay across reopen" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const sender = try configureTestSession(&storage, "skills-peer-sender");
            const receiver = try configureTestSession(&storage, "skills-peer-receiver");
            var update: wire_request.ConfigureCommand = .{ .session = sender };
            try update.key.set("skills-peer-bypass");
            update.configuration.tools = try .of(&.{"bash"});
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "skills-peer-input", "skills-peer-input", sender.slice(), "Invoke a skill for my peer");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, model, "skills-peer-call");
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            var input: ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, action, &input);
            var command: wire_request.MessageCommand = .{ .session = receiver, .text = .{ .state = .value, .digest = protocol.contentDigest("") }, .sender = .{}, .sender_handle = input.sender_handle };
            try command.key.set("skills-peer-refusal");
            try command.sender.?.store.set(storage.selector.slice());
            command.sender.?.session = sender;
            const diagnostic = "Skill missing-peer-skill is not in the receiver's saved catalog; nothing was sent.";
            const captured: skills_fixture_domain.MessageCapture = .{ .failed = .{ .code = .skill_file_unavailable, .bytes = diagnostic } };
            const sender_position = (try store_core.readSessionForTesting(&storage, sender.slice())).?.next_position;
            const receiver_position = (try store_core.readSessionForTesting(&storage, receiver.slice())).?.next_position;
            var activity_request: protocol.ActivityPage = .{ .session = sender };
            activity_request.position = (try store_core.activityPageForTesting(&storage, activity_request)).end;
            const rejected = storage.submitMessageCapturedSkills(&command, null, null, &captured, .{});
            try std.testing.expect(rejected == .rejected and !rejected.rejected.replayed);
            try std.testing.expectEqual(protocol.MessageRejection.skill_file_unavailable, rejected.rejected.code);
            try storage.revokeActionSender(action);
            // Neither later capture text nor a revoked handle may rewrite the
            // original keyed outcome, including after a genuine database reopen.
            const later: skills_fixture_domain.MessageCapture = .{ .failed = .{ .code = .skill_text_invalid, .bytes = "A different later disk failure" } };
            for (0..2) |pass| {
                if (pass == 1) {
                    try storage.close();
                    opened = false;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    opened = true;
                }
                const replay = storage.submitMessageCapturedSkills(&command, null, null, &later, .{});
                try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                try std.testing.expectEqual(protocol.MessageRejection.skill_file_unavailable, replay.rejected.code);
                try std.testing.expectEqual(sender_position + 1, (try store_core.readSessionForTesting(&storage, sender.slice())).?.next_position);
                try std.testing.expectEqual(receiver_position, (try store_core.readSessionForTesting(&storage, receiver.slice())).?.next_position);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM sent_rejection WHERE command_key=?1 AND sender_session_ref=?2 AND sender_position=?3", .{ command.key.slice(), sender.slice(), sender_position }));
                const activity = try store_core.activityPageForTesting(&storage, activity_request);
                try std.testing.expectEqual(@as(usize, 1), activity.count);
                try std.testing.expectEqual(sender_position, activity.items[0].position);
                try std.testing.expectEqualStrings("skill_file_unavailable", activity.items[0].value.send_failed.code.slice());
                try std.testing.expectEqualStrings(receiver.slice(), activity.items[0].value.send_failed.target.?.session.slice());
                const diagnostic_id = try store_testing.queryU64(&storage, "SELECT primary_content_id FROM core_command WHERE command_key=?1 AND accepted=0 AND code='skill_file_unavailable'", .{command.key.slice()});
                const reference = try testingContentReference(&storage, diagnostic_id);
                var reader: ContentReader = undefined;
                reader.open(try storage.openContent(reference));
                defer reader.close();
                var bytes: [diagnostic.len]u8 = undefined;
                try std.testing.expectEqual(bytes.len, try reader.read(0, &bytes));
                try std.testing.expectEqualStrings(diagnostic, &bytes);
            }
        }
    }.run);
}

test "inline skills a peer Session's Message may list the recipient's skills" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const sender = try configureTestSession(&storage, "skills-peer-accept-sender");
            const receiver = try configureTestSession(&storage, "skills-peer-accept-receiver");
            var update: wire_request.ConfigureCommand = .{ .session = sender };
            try update.key.set("skills-peer-accept-bypass");
            update.configuration.tools = try .of(&.{"bash"});
            update.configuration.permission_mode.state = .value;
            try update.configuration.permission_mode.value.set("bypass");
            try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
            try submitTestMessage(&storage, &tmp, "skills-peer-accept-input", "skills-peer-accept-input", sender.slice(), "Ask my peer to use its skill");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            try settleTwoActionsForTesting(&storage, &tmp, model, "skills-peer-accept-call");
            const action = (try storage.admitNextActionAttempt(300_000, .{})).?.permit.binding;
            var input: ActionExecutionInput = undefined;
            try storage.readActionExecutionInput(.bash, action, &input);
            const authored = "check the flaky tests";
            var command = try completeMessage("skills-peer-accept", receiver.slice(), try tmp.dir.createFile(std.testing.io, "peer-authored", .{ .read = true }), authored);
            try command.text.file.?.writeStreamingAll(std.testing.io, authored);
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            command.sender = .{};
            try command.sender.?.store.set(storage.selector.slice());
            command.sender.?.session = sender;
            command.sender_handle = input.sender_handle;
            // The Host bound demo against the receiver's catalog.
            const body = "Skill file: \"/receiver/skills/demo/SKILL.md\"\n\nreceiver body";
            const capture: skills_fixture_domain.MessageCapture = .{ .bound = &.{.{ .name = "demo", .bytes = body }} };
            var activity_request: protocol.ActivityPage = .{ .session = receiver };
            activity_request.position = (try store_core.activityPageForTesting(&storage, activity_request)).end;
            const reply = storage.submitMessageCapturedSkills(&command, null, null, &capture, .{});
            try std.testing.expect(reply == .accepted and !reply.accepted.replayed);
            const page = try store_core.activityPageForTesting(&storage, activity_request);
            try std.testing.expectEqual(@as(usize, 1), page.count);
            const received = switch (page.items[0].value) {
                .admission, .received => |message| message,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqualStrings("skills-peer-accept", received.key.slice());
            try std.testing.expectEqualStrings(sender.slice(), received.sender.?.session.slice());
            // The Message is the text the peer sent; the skill is saved after it.
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(authored), &received.content.digest);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_skill k JOIN message_admission m ON m.admission_id=k.admission_id JOIN content c ON c.content_id=k.content_id WHERE m.command_key='skills-peer-accept' AND k.position=1 AND k.name='demo' AND c.digest=?1", .{store_testing.Blob{ .bytes = &protocol.contentDigest(body) }}));
        }
    }.run);
}

test "skills reload settles catalog and result atomically across faults retry replay and no-op" {
    try store_testing.forEachEngine(struct {
        fn expectResult(storage: *Store, key: []const u8, expected: []const u8) !void {
            const reference = try storage.commandResult(key);
            try std.testing.expectEqual(@as(u64, expected.len), reference.length);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(expected), &reference.digest);
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(reference));
            defer reader.close();
            var bytes: [128]u8 = undefined;
            try std.testing.expectEqual(expected.len, try reader.read(0, bytes[0..expected.len]));
            try std.testing.expectEqualStrings(expected, bytes[0..expected.len]);
        }

        fn expectCatalog(storage: *Store, allocator: std.mem.Allocator, session: []const u8, encoded: []const u8) !void {
            const state = try storage.readSkills(allocator, session);
            const actual = try @import("../../skills.zig").encodeCatalog(allocator, state.catalog);
            try std.testing.expectEqualStrings(encoded, actual);
        }

        fn run(case: *store_testing.Case) !void {
            const skills = @import("../../skills.zig");
            for ([_]bool{ false, true }) |before_commit| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                var opened = true;
                defer if (opened) storage.close() catch unreachable;
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var create = try completeConfiguration("skills-reload-atomic-create", "", workspace, "model-a");
                const authored = "Authored baseline instructions must survive every catalog reload";
                create.configuration.instructions = .{ .state = .value, .borrowed = authored.ptr, .length = authored.len, .digest = protocol.contentDigest(authored) };
                const session = (try storage.configureWithInitialSkills(&create, null, &skills_fixture_initial, .{})).accepted.session;
                const baseline = (try store_core.readSessionForTesting(&storage, session.slice())).?;
                try std.testing.expectEqual(@as(u64, 1), baseline.revision);
                const original_content = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                const original_commands = try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{});
                const original_snapshot = try store_testing.queryU64(&storage, "SELECT position FROM session_skill_catalog WHERE session_ref=?1", .{session.slice()});
                var command: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
                try command.key.set("skills-reload-atomic");
                const candidate: skills_fixture_domain.Capture = .{ .reload = .{ .entries = &.{.{
                    .name = "reloaded-only",
                    .description = "A distinct catalog captured for this reload",
                    .path = "/skills/reloaded-only/SKILL.md",
                }} } };
                const encoded = try skills.encodeCatalog(arena.allocator(), candidate.reload);
                const old_catalog = try skills.decodeCatalog(arena.allocator(), skills_fixture_initial.ready.encoded);
                const delta = try skills.diff(arena.allocator(), old_catalog, candidate.reload);
                const delta_text = try skills.deltaInstruction(arena.allocator(), delta);
                const refused = try storage.configureWithCapturedSkills(&command, null, null, &candidate, std.testing.allocator, .{
                    .content_import = !before_commit,
                    .before_commit = before_commit,
                });
                try std.testing.expect(refused == .infrastructure_failure);
                try std.testing.expect(storage.isFenced());
                try storage.close();
                opened = false;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                // A failed settlement publishes neither half of the catalog
                // change, its command acknowledgment, nor a replacement view.
                try std.testing.expectEqual(original_content, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                try std.testing.expectEqual(original_commands, try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key=?1", .{command.key.slice()}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog WHERE session_ref=?1", .{session.slice()}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE session_ref=?1 AND source_catalog_position IS NOT NULL", .{session.slice()}));
                try std.testing.expectEqual(baseline.next_position, (try store_core.readSessionForTesting(&storage, session.slice())).?.next_position);
                try std.testing.expectError(error.ResultNotFound, storage.commandResult(command.key.slice()));
                try expectCatalog(&storage, arena.allocator(), session.slice(), skills_fixture_initial.ready.encoded);
                const accepted = try storage.configureWithCapturedSkills(&command, null, null, &candidate, std.testing.allocator, .{});
                try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed and !accepted.accepted.created);
                try std.testing.expectEqual(@as(u64, 1), accepted.accepted.revision);
                try std.testing.expectEqual(protocol.SkillsReloadStatus.reloaded, accepted.accepted.skills.?);
                try std.testing.expectEqual(original_content + 3, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                try std.testing.expectEqual(original_commands + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{}));
                try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog WHERE session_ref=?1", .{session.slice()}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog s JOIN content c ON c.content_id=s.catalog_content_id WHERE s.session_ref=?1 AND s.position=?2 AND c.digest=?3 AND c.private=0", .{ session.slice(), baseline.next_position, store_testing.Blob{ .bytes = &protocol.contentDigest(encoded) } }));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry e JOIN content c ON c.content_id=e.content_id WHERE e.session_ref=?1 AND e.session_position=?2 AND e.source_catalog_position=e.session_position AND e.entry_kind=2 AND e.turn_id IS NULL AND c.digest=?3 AND c.private=0", .{ session.slice(), baseline.next_position, store_testing.Blob{ .bytes = &protocol.contentDigest(delta_text) } }));
                try expectCatalog(&storage, arena.allocator(), session.slice(), encoded);
                try expectResult(&storage, command.key.slice(), "Skills catalog reloaded.");
                const other_captures = [_]skills_fixture_domain.Capture{
                    .{ .reload = .{ .entries = &.{} } },
                    .{ .failed = .{ .code = .skills_unavailable, .bytes = "A later scan failed, but cannot replace the saved acknowledgment" } },
                };
                for (&other_captures) |*captured| {
                    const replay = try storage.configureWithCapturedSkills(&command, null, null, captured, std.testing.allocator, .{});
                    try std.testing.expect(replay == .accepted and replay.accepted.replayed);
                    try std.testing.expectEqual(protocol.SkillsReloadStatus.reloaded, replay.accepted.skills.?);
                    try std.testing.expectEqual(@as(u64, 1), replay.accepted.revision);
                    try expectResult(&storage, command.key.slice(), "Skills catalog reloaded.");
                    try expectCatalog(&storage, arena.allocator(), session.slice(), encoded);
                    try std.testing.expectEqual(original_content + 3, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                    try std.testing.expectEqual(original_commands + 1, try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command", .{}));
                    try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog WHERE session_ref=?1", .{session.slice()}));
                    try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE session_ref=?1 AND source_catalog_position IS NOT NULL", .{session.slice()}));
                }
                var unchanged = command;
                try unchanged.key.set("skills-reload-atomic-unchanged");
                const noop = try storage.configureWithCapturedSkills(&unchanged, null, null, &candidate, std.testing.allocator, .{});
                try std.testing.expect(noop == .accepted and !noop.accepted.replayed);
                try std.testing.expectEqual(protocol.SkillsReloadStatus.unchanged, noop.accepted.skills.?);
                try expectResult(&storage, unchanged.key.slice(), "Skills are unchanged.");
                try std.testing.expectEqual(original_content + 4, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
                try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog WHERE session_ref=?1", .{session.slice()}));
                try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry WHERE session_ref=?1 AND source_catalog_position IS NOT NULL", .{session.slice()}));
                const after = (try store_core.readSessionForTesting(&storage, session.slice())).?;
                try std.testing.expectEqual(@as(u64, 1), after.revision);
                try std.testing.expectEqual(baseline.instructions_id, after.instructions_id);
                try std.testing.expectEqual(baseline.next_position + 1, after.next_position);
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1", .{session.slice()}));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog s JOIN content c ON c.content_id=s.catalog_content_id WHERE s.session_ref=?1 AND s.position=?2 AND c.digest=?3 AND c.private=0", .{ session.slice(), original_snapshot, store_testing.Blob{ .bytes = &protocol.contentDigest(skills_fixture_initial.ready.encoded) } }));
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry e JOIN content c ON c.content_id=e.content_id WHERE e.session_ref=?1 AND e.source_catalog_position=?2 AND c.digest=?3 AND c.private=0", .{ session.slice(), original_snapshot, store_testing.Blob{ .bytes = &protocol.contentDigest(skills_fixture_initial.ready.instruction.?) } }));
            }
        }
    }.run);
}

test "skills preserve archive intent until a fresh invocation is admitted" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "skills-archive-session");
            var archive: protocol.SessionArchiveCommand = .{ .session = session };
            try archive.key.set("skills-archive");
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try std.testing.expectEqual(protocol.SessionArchiveState.archived, (try storage.inspectSessionForTesting(session.slice())).archive_state);
            var command: wire_request.MessageCommand = .{ .session = session, .text = .{ .state = .value, .digest = protocol.contentDigest("") } };
            try command.key.set("skills-archive-refused");
            const failed: skills_fixture_domain.MessageCapture = .{ .failed = .{ .code = .skill_file_unavailable, .bytes = "The advertised name was not found" } };
            const refused = storage.submitMessageCapturedSkills(&command, null, null, &failed, .{});
            try std.testing.expect(refused == .rejected and refused.rejected.code == .skill_file_unavailable);
            try std.testing.expectEqual(protocol.SessionArchiveState.archived, (try storage.inspectSessionForTesting(session.slice())).archive_state);
            var reload: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
            try reload.key.set("skills-archive-reload");
            const empty: skills_fixture_domain.Capture = .{ .reload = .{ .entries = &.{} } };
            try std.testing.expect(try storage.configureWithCapturedSkills(&reload, null, null, &empty, std.testing.allocator, .{}) == .accepted);
            try std.testing.expectEqual(protocol.SessionArchiveState.archived, (try storage.inspectSessionForTesting(session.slice())).archive_state);
            try command.key.set("skills-archive-admitted");
            const invocation: skills_fixture_domain.MessageCapture = .{ .bound = &.{.{ .name = "demo", .bytes = "Skill file: \"/skills/demo/SKILL.md\"\n\nComplete ordinary skill input" }} };
            const accepted = storage.submitMessageCapturedSkills(&command, null, null, &invocation, .{});
            try std.testing.expect(accepted == .accepted and !accepted.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionArchiveState.active, (try storage.inspectSessionForTesting(session.slice())).archive_state);
            try archive.key.set("skills-archive-again");
            try std.testing.expect(storage.archiveSession(&archive, .{}) == .accepted);
            try std.testing.expectEqual(protocol.SessionArchiveState.archived, (try storage.inspectSessionForTesting(session.slice())).archive_state);
            const replay = storage.submitMessageCapturedSkills(&command, null, null, &failed, .{});
            try std.testing.expect(replay == .accepted and replay.accepted.replayed);
            try std.testing.expectEqual(protocol.SessionArchiveState.archived, (try storage.inspectSessionForTesting(session.slice())).archive_state);
        }
    }.run);
}

test "skills native reload validates targets after replay without changing ordinary precedence" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            const session = try store_testing.configureTestSession(&storage, "reload-target-create");
            const candidate: skills_fixture_domain.Capture = .{ .reload = .{ .entries = &.{} } };
            const targets = [_][]const u8{ "bad", "abcdefg", "ABCDEF", "iiiiii", "ab/cde", "ab\x00cde", "éabcd", "absent", "" };
            for (targets, 0..) |target, index| {
                var key: [64]u8 = undefined;
                var command: wire_request.ConfigureCommand = .{ .reload_skills = true };
                try command.key.set(try std.fmt.bufPrint(&key, "reload-target-{d}", .{index}));
                try command.session.set(target);
                const expected: protocol.ConfigurationRejection = if (index < targets.len - 2) .invalid_session_reference else .unknown_session;
                const answer = try storage.configureWithCapturedSkills(&command, null, null, &candidate, std.testing.allocator, .{});
                try std.testing.expect(answer == .rejected);
                try std.testing.expectEqual(expected, answer.rejected.code);
                try std.testing.expect(!answer.rejected.replayed);
                // Reopen before replay: the refusal must stay typed and saved,
                // even without a capture and with the target still absent.
                try storage.close();
                opened = false;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                opened = true;
                const replay = try storage.configureWithCapturedSkills(&command, null, null, null, std.testing.allocator, .{});
                try std.testing.expect(replay == .rejected and replay.rejected.replayed);
                try std.testing.expectEqual(expected, replay.rejected.code);
                command.reload_skills = false;
                try std.testing.expect(try storage.configure(&command, .{}) == .conflict);
            }
            var existing: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
            try existing.key.set("reload-target-existing");
            const accepted = try storage.configureWithCapturedSkills(&existing, null, null, &candidate, std.testing.allocator, .{});
            try std.testing.expect(accepted == .accepted);
            try std.testing.expectEqual(@as(u64, 1), accepted.accepted.revision);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry", .{}));
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog", .{}));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "a skills reload is refused when it carries settings or has no catalog, and saves a failed capture's diagnostic" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try store_testing.configureTestSession(&storage, "reload-failed-create");
            var command: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
            try command.key.set("reload-failed");
            const diagnostic = "Rui could not reload skills: the scan failed. The previous catalog is unchanged.";
            const failed: skills_fixture_domain.Capture = .{ .failed = .{ .code = .skills_unavailable, .bytes = diagnostic } };
            const refused = try storage.configureWithCapturedSkills(&command, null, null, &failed, std.testing.allocator, .{});
            try std.testing.expect(refused == .rejected and !refused.rejected.replayed);
            try std.testing.expectEqual(protocol.ConfigurationRejection.skills_unavailable, refused.rejected.code);
            const diagnostic_id = try store_testing.queryU64(&storage, "SELECT primary_content_id FROM core_command WHERE command_key=?1 AND accepted=0 AND code='skills_unavailable'", .{command.key.slice()});
            var reader: ContentReader = undefined;
            reader.open(try storage.openContent(try testingContentReference(&storage, diagnostic_id)));
            defer reader.close();
            var bytes: [diagnostic.len]u8 = undefined;
            try std.testing.expectEqual(bytes.len, try reader.read(0, &bytes));
            try std.testing.expectEqualStrings(diagnostic, &bytes);
            // A replay answers the saved refusal, whatever the Host captures now.
            const replay = try storage.configureWithCapturedSkills(&command, null, null, null, std.testing.allocator, .{});
            try std.testing.expect(replay == .rejected and replay.rejected.replayed);
            try std.testing.expectEqual(protocol.ConfigurationRejection.skills_unavailable, replay.rejected.code);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog", .{}));
            // A reload changes nothing else: one that carries a setting, or
            // requires a model, is refused before its capture is read.
            const empty: skills_fixture_domain.Capture = .{ .reload = .{ .entries = &.{} } };
            for (0..2) |index| {
                var mixed: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
                try mixed.key.set(if (index == 0) "reload-with-label" else "reload-requiring-model");
                if (index == 0) {
                    mixed.configuration.label.state = .value;
                    try mixed.configuration.label.value.set("renamed");
                } else mixed.require_model = true;
                const answer = try storage.configureWithCapturedSkills(&mixed, null, null, &empty, std.testing.allocator, .{});
                try std.testing.expect(answer == .rejected and !answer.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.incomplete_initial_configuration, answer.rejected.code);
            }
            // Without a catalog to reload, the skills are unavailable.
            const invocation: skills_fixture_domain.Capture = .{ .invocation = "a model tool's capture" };
            for ([_]?*const skills_fixture_domain.Capture{ null, &invocation }, 0..) |captured, index| {
                var uncaptured: wire_request.ConfigureCommand = .{ .session = session, .reload_skills = true };
                try uncaptured.key.set(if (index == 0) "reload-uncaptured" else "reload-invocation");
                const answer = try storage.configureWithCapturedSkills(&uncaptured, null, null, captured, std.testing.allocator, .{});
                try std.testing.expect(answer == .rejected and !answer.rejected.replayed);
                try std.testing.expectEqual(protocol.ConfigurationRejection.skills_unavailable, answer.rejected.code);
            }
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_skill_catalog", .{}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision", .{}));
        }
    }.run);
}

test "skills saved catalog read retains only decoded result metadata" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
            var create = try completeConfiguration("catalog-read-retention", "", workspace, "model-a");
            const session = (try storage.configureWithInitialSkills(&create, null, &skills_fixture_initial, .{})).accepted.session;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var requested = std.testing.FailingAllocator.init(arena.allocator(), .{});
            const result = try storage.readSkills(requested.allocator(), session.slice());
            try std.testing.expectEqual(@as(usize, 1), result.catalog.entries.len);
            const entry = result.catalog.entries[0];
            const owned_bytes = @sizeOf(Store.SkillsState) + @sizeOf(protocol.Bounded(protocol.max_workspace_bytes)) +
                @sizeOf(@import("../../skills.zig").Entry) + entry.name.len + entry.description.len + entry.path.len;
            try std.testing.expectEqual(owned_bytes, requested.allocated_bytes);
        }
    }.run);
}

test "inline skills keep the typed text once and project each bound skill as its own entry after it" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            const session = try configureTestSession(&storage, "bound-config");
            const typed = "use /other then /demo";
            const body = "Skill file: \"/skills/same/SKILL.md\"\n\nsame body";
            var command = try completeMessage("bound-message", session.slice(), try tmp.dir.createFile(std.testing.io, "typed", .{ .read = true }), typed);
            try command.text.file.?.writeStreamingAll(std.testing.io, typed);
            defer command.removeTemporaryContent(std.testing.io) catch unreachable;
            // Eight skills, more than one Access's table of imported rows
            // holds, in the order the text names them; two share bytes.
            const capture: skills_fixture_domain.MessageCapture = .{ .bound = &.{
                .{ .name = "other", .bytes = body }, .{ .name = "demo", .bytes = body }, .{ .name = "s3", .bytes = "three" }, .{ .name = "s4", .bytes = "four" },
                .{ .name = "s5", .bytes = "five" },  .{ .name = "s6", .bytes = "six" },  .{ .name = "s7", .bytes = "seven" }, .{ .name = "s8", .bytes = "eight" },
            } };
            const reply = storage.submitMessageCapturedSkills(&command, null, null, &capture, .{});
            try std.testing.expect(reply == .accepted);
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(typed), &reply.accepted.content.digest);
            const page = try store_core.activityPageForTesting(&storage, .{ .session = session, .kinds = .initOne(.admission) });
            try std.testing.expectEqualSlices(u8, &protocol.contentDigest(typed), &page.items[0].value.admission.content.digest);
            // Equal bodies share one content row.
            try std.testing.expectEqual(@as(u64, 7), try store_testing.queryU64(&storage, "SELECT count(DISTINCT content_id) FROM message_skill", .{}));
            _ = (try storage.admitNextModelAttempt(.{})).?;
            // The Message's entry, then each skill's, in the text's order.
            const Entry = struct { kind: u64, skill: u64, name: []const u8, bytes: []const u8 };
            const expected = [_]Entry{ .{ .kind = 1, .skill = 0, .name = "", .bytes = typed }, .{ .kind = 4, .skill = 1, .name = "other", .bytes = body }, .{ .kind = 4, .skill = 2, .name = "demo", .bytes = body }, .{ .kind = 4, .skill = 8, .name = "s8", .bytes = "eight" } };
            const first = try store_testing.queryU64(&storage, "SELECT min(session_position) FROM conversation_entry WHERE session_ref=?1 AND entry_kind IN (1,4)", .{session.slice()});
            for (expected) |entry| {
                const offset = entry.skill;
                try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM conversation_entry e JOIN content c ON c.content_id=e.content_id " ++
                    "LEFT JOIN message_skill k ON k.admission_id=e.source_skill_admission_id AND k.position=e.source_skill_position " ++
                    "WHERE e.session_ref=?1 AND e.session_position=?2 AND e.entry_kind=?3 AND coalesce(e.source_skill_position,0)=?4 AND coalesce(k.name,'')=?5 AND c.digest=?6", .{ session.slice(), first + offset, entry.kind, entry.skill, entry.name, store_testing.Blob{ .bytes = &protocol.contentDigest(entry.bytes) } }));
            }
            // A skill entry must name its Message's skill.
            const constraint_error = if (case.engine == .mysql) error.MysqlFixtureFailed else error.SqliteExecFailed;
            try std.testing.expectError(constraint_error, store_testing.exec(&storage, "UPDATE conversation_entry SET source_skill_position=NULL WHERE entry_kind=4", .{}));
        }
    }.run);
}

test "inline skills initial failure preserves all ordinary configuration refusals before creation writes" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            const Case = struct { field: []const u8, value: []const u8, code: protocol.MessageRejection };
            const cases = [_]Case{
                .{ .field = "model", .value = "", .code = .invalid_model },
                .{ .field = "permission", .value = "not-a-mode", .code = .unsupported_permission_mode },
                .{ .field = "tool", .value = "not-a-tool", .code = .unknown_tool },
                .{ .field = "workspace", .value = "/rui-no-such-inline-workspace", .code = .invalid_workspace },
                .{ .field = "label", .value = "bad\nlabel", .code = .invalid_label },
            };
            for (cases) |test_case| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
                var configure = try completeConfiguration("inline-invalid-config", "", workspace, "model-a");
                const configuration = &configure.configuration;
                if (std.mem.eql(u8, test_case.field, "model")) try configuration.model.value.set(test_case.value);
                if (std.mem.eql(u8, test_case.field, "permission")) try configuration.permission_mode.value.set(test_case.value);
                if (std.mem.eql(u8, test_case.field, "tool")) configuration.tools = try .of(&.{test_case.value});
                if (std.mem.eql(u8, test_case.field, "workspace")) try configuration.workspace.value.set(test_case.value);
                if (std.mem.eql(u8, test_case.field, "label")) {
                    configuration.label.state = .value;
                    try configuration.label.value.set(test_case.value);
                }
                var command: wire_request.MessageCommand = .{ .key = configure.key, .configuration = configuration.*, .text = .{ .state = .value, .borrowed = "authored".ptr, .length = 8, .digest = protocol.contentDigest("authored") } };
                const failed: skills_fixture_domain.MessageCapture = .{ .failed = .{ .code = .skill_file_unavailable, .bytes = "missing skill" } };
                const baseline = try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{});
                const reply = storage.submitMessageCapturedSkills(&command, null, &skills_fixture_initial, &failed, .{});
                try std.testing.expect(reply == .rejected);
                try std.testing.expectEqual(test_case.code, reply.rejected.code);
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM session", .{}));
                try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM message_admission", .{}));
                try std.testing.expectEqual(baseline, try store_testing.queryU64(&storage, "SELECT count(*) FROM content", .{}));
            }
        }
    }.run);
}

test "inline skills configuration validation borrows one Store-owned plan through content imports" {
    const Ready = @FieldType(configuration_domain.ConfigurationValidation, "ready");
    // The validation-only phase must not return another Settings value onto
    // the Host's creation/import chain. This is an ownership API contract.
    try std.testing.expect(Ready == *const configuration_domain.ValidatedConfiguration);
    if (comptime Ready == *const configuration_domain.ValidatedConfiguration) {
        try store_testing.forEachEngine(struct {
            fn run(case: *store_testing.Case) !void {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var storage: Store = undefined;
                try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                defer storage.close() catch unreachable;
                const session = try configureTestSession(&storage, "borrowed-plan-config");
                var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
                var update = try completeConfiguration("borrowed-plan-update", session.slice(), try canonicalCwd(std.testing.io, &workspace_buffer), "model-a");
                update.configuration.instructions = try testingBytesContent(&tmp, "plan-instructions", "new retained plan instructions");
                defer update.removeTemporaryContent(std.testing.io) catch unreachable;
                update.configuration.label.state = .value;
                try update.configuration.label.value.set("retained");
                update.configuration.permission_mode.state = .value;
                try update.configuration.permission_mode.value.set("ask");
                {
                    const entry = try store_core.enter(&storage, .none);
                    defer entry.release();
                    var a: store_access.Access(.write, error{SessionUpdateFailed}) = .open(&entry);
                    defer a.deinit();
                    const reads = storage.configurationReads();
                    reads.* = .{ .next = .{ .workspace = .{ .len = 0 }, .model = .{ .len = 0 } } };
                    configuration_domain.prepareConfiguration(&a, storage.hostTools().host_tool_set, session.slice(), &update.configuration, reads);
                    try a.run();
                    const checked = try configuration_domain.validateConfiguration(&a, storage.io, session.slice(), &update.configuration, null, reads);
                    try std.testing.expect(checked == .ready);
                    const plan = checked.ready;
                    try std.testing.expect(plan == &reads.validated);
                    const original_instructions = plan.before.?.instructions_id;
                    try std.testing.expect(plan.before.?.label == null);
                    const applied = try configuration_domain.applyValidatedConfiguration(&a, storage.io, session.slice(), &update.configuration, null, .{}, reads);
                    try std.testing.expect(applied == .accepted);
                    try std.testing.expect(plan == &reads.validated);
                    try std.testing.expectEqual(original_instructions, plan.before.?.instructions_id);
                    try std.testing.expect(reads.next.instructions_id != original_instructions);
                    try std.testing.expect(plan.before.?.label == null);
                    try std.testing.expectEqualStrings("retained", reads.next.label.?.slice());
                    const expected: std.EnumSet(protocol.SessionField) = .initMany(&.{ .instructions, .permission_mode, .label });
                    try std.testing.expectEqual(expected, applied.accepted.changes);
                    try a.run();
                    try a.abandon(.{});
                }
                const saved = (try store_core.readSessionForTesting(&storage, session.slice())).?;
                try std.testing.expectEqual(@as(u64, 1), saved.revision);
                try std.testing.expect(saved.label == null);
                try std.testing.expect(!storage.isFenced());
            }
        }.run);
    }
}

test "find_tools and the skill tool leave a call whose Session owes a stop to that stop" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            var path: [protocol.max_workspace_bytes]u8 = undefined;
            var create = try completeConfiguration("owed-calls", "", try canonicalCwd(std.testing.io, &path), "model-a");
            create.configuration.tools = try .of(&.{ "find_tools", "skill" });
            const session = (try storage.configure(&create, .{})).accepted.session;
            // The Session is a child, so its parent's stop makes it owe one.
            const root = try configureTestSession(&storage, "owed-calls-root");
            try store_testing.exec(&storage, "UPDATE session SET parent_ref=?1 WHERE session_ref=?2", .{ root.slice(), session.slice() });
            try submitTestMessage(&storage, &tmp, "owed-calls-input", "owed-calls-key", session.slice(), "find and invoke");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            const calls = [_]TestingCall{
                .{ .item_id = "find", .name = "find_tools", .encoded_call_id = "find", .decoded_call_id = "find", .encoded_arguments = "{\\\"words\\\":\\\"skill\\\"}", .decoded_arguments = "{\"words\":\"skill\"}" },
                .{ .item_id = "invoke", .name = "skill", .encoded_call_id = "invoke", .decoded_call_id = "invoke", .encoded_arguments = "{\\\"operation\\\":\\\"reload\\\"}", .decoded_arguments = "{\"operation\":\"reload\"}" },
            };
            try settleCallsForTesting(&storage, &tmp, model, "owed-calls", &calls);
            const find = (try storage.nextCoreWork()).?.action;
            try std.testing.expect(find.tool == .find_tools);
            var skill = find.binding;
            skill.action_id = try store_testing.queryU64(&storage, "SELECT action_id FROM action_operation WHERE parent_operation_id=?1 AND action_id<>?2", .{ find.binding.parent_operation_id, find.binding.action_id });
            var stop = try completeSessionStop("owed-calls-root-stop", root.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            const open_sql = "SELECT count(*) FROM action_operation WHERE parent_operation_id=?1 AND resolution_code IS NULL";
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, open_sql, .{model.operation_id}));
            const revisions = try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1", .{session.slice()});

            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var words: @import("../../find_tools_words.zig").FindTools = .{ .count = 1 };
            words.words[0] = "skill";
            try std.testing.expect(!try storage.findTools(find.binding, arena.allocator(), &words, null, .{}));
            const invocation: skills_fixture_domain.Capture = .{ .invocation = "a skill's body" };
            try std.testing.expect(!try storage.settleSkillTool(skill, arena.allocator(), &invocation, .{}));
            // Neither call saved a command, a revision or a resolution.
            try std.testing.expectEqual(@as(u64, 2), try store_testing.queryU64(&storage, open_sql, .{model.operation_id}));
            try std.testing.expectEqual(revisions, try store_testing.queryU64(&storage, "SELECT count(*) FROM session_revision WHERE session_ref=?1", .{session.slice()}));
            const key = try std.fmt.allocPrint(arena.allocator(), "rui.core/find_tools/{d}", .{find.binding.action_id});
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT count(*) FROM core_command WHERE command_key=?1", .{key}));
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}

test "the skill tool resolves an invocation or a failed capture with its text, and a fault saves nothing" {
    try store_testing.forEachEngine(struct {
        fn run(case: *store_testing.Case) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
            var opened = true;
            defer if (opened) storage.close() catch unreachable;
            var path: [protocol.max_workspace_bytes]u8 = undefined;
            var create = try completeConfiguration("skill-tool", "", try canonicalCwd(std.testing.io, &path), "model-a");
            create.configuration.tools = try .of(&.{"skill"});
            const session = (try storage.configure(&create, .{})).accepted.session;
            try submitTestMessage(&storage, &tmp, "skill-tool-input", "skill-tool-key", session.slice(), "invoke");
            const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
            var calls: [2]TestingCall = undefined;
            for (&calls, [_][]const u8{ "invoke", "fail" }) |*call, name| call.* = .{ .item_id = name, .name = "skill", .encoded_call_id = name, .decoded_call_id = name, .encoded_arguments = "{\\\"operation\\\":\\\"reload\\\"}", .decoded_arguments = "{\"operation\":\"reload\"}" };
            try settleCallsForTesting(&storage, &tmp, model, "skill-tool-calls", &calls);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const invocation: skills_fixture_domain.Capture = .{ .invocation = "the skill's own text" };
            const failed: skills_fixture_domain.Capture = .{ .failed = .{ .code = .skill_file_unavailable, .bytes = "Rui could not read the skill's file." } };
            const Expected = struct { captured: *const skills_fixture_domain.Capture, code: []const u8, text: []const u8 };
            for ([_]Expected{
                .{ .captured = &invocation, .code = "succeeded", .text = "the skill's own text" },
                .{ .captured = &failed, .code = "failed", .text = "Rui could not read the skill's file." },
            }) |expected| {
                const pending = (try storage.nextCoreWork()).?.action;
                // An injected fault rolls back the result and resolution.
                for ([_]struct { Faults, anyerror }{
                    .{ .{ .content_import = true }, error.InjectedContentImportFailure },
                    .{ .{ .before_commit = true }, error.InjectedCommitFailure },
                }) |fault| {
                    try std.testing.expectError(fault[1], storage.settleSkillTool(pending.binding, arena.allocator(), expected.captured, fault[0]));
                    try storage.close();
                    opened = false;
                    try store_testing.testingStore(case, &storage, &tmp, std.testing.io);
                    opened = true;
                    try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{pending.binding.action_id}));
                }
                try std.testing.expect(try storage.settleSkillTool(pending.binding, arena.allocator(), expected.captured, .{}));
                const result_id = try store_testing.queryU64(&storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ pending.binding.action_id, expected.code });
                try expectContent(&storage, try testingContentReference(&storage, result_id), expected.text);
            }
            try std.testing.expect(!storage.isFenced());
        }
    }.run);
}
