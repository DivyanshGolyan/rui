const std = @import("std");
const catalog = @import("../../skills.zig");
const workspace_path = @import("../../workspace_path.zig");
const content_string = @import("../../content_string.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const mutation_answer = @import("../../mutation_answer.zig");
const message_admission = @import("../../message_admission.zig");
const configuration_admission = @import("../../configuration_admission.zig");
const content = @import("content.zig");
const rsql = @import("../rsql.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");
const action_domain = @import("action.zig");

pub const Initial = union(enum) {
    ready: struct { encoded: []const u8, instruction: ?[]const u8 },
    unavailable,
};

pub fn instructionConsistentSql(comptime e: []const u8) []const u8 {
    return "(" ++ e ++ ".entry_kind=2 AND " ++ e ++ ".turn_id IS NULL AND " ++
        e ++ ".source_revision IS NULL AND " ++ e ++ ".source_admission_id IS NULL AND " ++
        e ++ ".source_operation_id IS NULL AND " ++ e ++ ".source_catalog_position=" ++ e ++ ".session_position AND " ++
        "EXISTS(SELECT 1 FROM session_skill_catalog catalog_source JOIN content catalog_metadata " ++
        "ON catalog_metadata.content_id=catalog_source.catalog_content_id JOIN content catalog_text " ++
        "ON catalog_text.content_id=" ++ e ++ ".content_id WHERE catalog_source.session_ref=" ++ e ++ ".session_ref " ++
        "AND catalog_source.position=" ++ e ++ ".source_catalog_position AND catalog_metadata.private=0 AND catalog_text.private=0))";
}

pub fn sourcesConsistentSql(comptime session: []const u8, comptime scope: []const u8) []const u8 {
    return "NOT EXISTS(SELECT 1 FROM session_skill_catalog catalog_required WHERE catalog_required.session_ref=" ++ session ++
        " AND catalog_required.position>0 AND (" ++ scope ++ ") AND NOT EXISTS(SELECT 1 FROM conversation_entry catalog_entry " ++
        "WHERE catalog_entry.session_ref=catalog_required.session_ref AND catalog_entry.source_catalog_position=catalog_required.position " ++
        "AND " ++ instructionConsistentSql("catalog_entry") ++ "))";
}

pub const latest = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,s.workspace,c.catalog_content_id,c.position AS catalog_position,content.byte_length,content.digest,content.private," ++
        "CASE WHEN c.position=0 OR EXISTS(SELECT 1 FROM conversation_entry source_entry WHERE source_entry.session_ref=c.session_ref " ++
        "AND source_entry.source_catalog_position=c.position AND " ++ instructionConsistentSql("source_entry") ++ ") THEN 1 ELSE 0 END AS source_consistent " ++
        "FROM session s LEFT JOIN session_skill_catalog c ON c.session_ref=s.session_ref AND c.position=(SELECT max(last.position) FROM session_skill_catalog last WHERE last.session_ref=s.session_ref) " ++
        "LEFT JOIN content ON content.content_id=c.catalog_content_id WHERE s.session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        session: rsql.SessionHead,
        workspace: *Bounded(workspace_path.max_bytes),
        catalog_content_id: ?rsql.Positive,
        catalog_position: ?u64 = null,
        byte_length: ?u64,
        digest: ?[32]u8,
        private: ?bool = null,
        source_consistent: bool = false,
    },
    .cardinality = .optional,
});

const ordinal = rsql.Read(.{
    .sql = "SELECT coalesce(max(entry_ordinal),0) AS ordinal FROM conversation_entry WHERE session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { ordinal: u64 },
    .cardinality = .one,
});

const insert_snapshot = rsql.Write(.{
    .sql = "INSERT INTO session_skill_catalog(session_ref,position,catalog_content_id) VALUES(@session(?1),?2,?3)",
    .Args = struct { session: rsql.SessionHead, position: u64, catalog_content_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

const insert_instruction = rsql.Write(.{
    .sql = "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_catalog_position,content_id,recorded_at) " ++
        "VALUES(@session(?1),?2,?3,2,NULL,?3,?4,@now)",
    .Args = struct { session: rsql.SessionHead, ordinal: u64, position: u64, content_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub const Appending = struct {
    session: rsql.SessionHead,
    encoded: []const u8,
    instruction: ?[]const u8,
    metadata: content.Import = undefined,
    text: content.Import = undefined,
    rows: content.Pair = undefined,
    last: ordinal.Row = undefined,

    pub fn initial(session: rsql.SessionHead, captured: ?*const Initial) error{SkillCatalogUnavailable}!?Appending {
        const value = captured orelse return null;
        const ready = switch (value.*) {
            .ready => |prepared| prepared,
            .unavailable => return error.SkillCatalogUnavailable,
        };
        return .{ .session = session, .encoded = ready.encoded, .instruction = ready.instruction };
    }

    pub fn queue(appending: *Appending, a: anytype) void {
        appending.metadata = .ofBytes(appending.encoded, false);
        appending.text = .ofBytes(appending.instruction orelse "", false);
        appending.rows = .{ .first = null, .second = null };
        content.lookupPair(a, &appending.metadata, &appending.text, &appending.rows);
        if (appending.instruction != null) a.read(ordinal, .{ .session = &appending.session.ref }, &appending.last);
    }

    pub fn finish(appending: *Appending, a: anytype, faults: store_core.Faults) !void {
        const session = appending.session;
        content.foundPair(&appending.rows, &appending.metadata, &appending.text);
        if (faults.content_import) return error.InjectedContentImportFailure;
        const metadata_id = try content.importBytes(a, &appending.metadata, appending.encoded);
        const position = if (appending.instruction != null) try (try a.positions(session)).take(1) else 0;
        a.write(insert_snapshot, .{ .session = session, .position = position, .catalog_content_id = metadata_id });
        if (appending.instruction) |bytes| {
            const text_id = try content.importBytes(a, &appending.text, bytes);
            a.write(insert_instruction, .{ .session = session, .ordinal = appending.last.ordinal + 1, .position = position, .content_id = text_id });
        }
    }
};

pub noinline fn read(a: anytype, allocator: std.mem.Allocator, session: []const u8) !catalog.Catalog {
    var reading: Reading = .{ .session = session, .allocator = allocator };
    defer reading.deinit();
    var ran: ?ReadRound = null;
    while (true) switch (try reading.step(a, ran)) {
        .round => |at| {
            if (at != .window) try a.run();
            ran = at;
        },
        .read => |value| return value,
    };
}

pub const ReadRound = enum { latest, window };

pub const Reading = struct {
    session: []const u8,
    allocator: std.mem.Allocator,
    row: latest.Row = undefined,
    found: @import("../access.zig").Found = .missing,
    bytes: []u8 = &.{},
    offset: usize = 0,

    pub const Step = union(enum) { round: ReadRound, read: catalog.Catalog };

    pub fn step(reading: *Reading, a: anytype, ran: ?ReadRound) !Step {
        const at = ran orelse {
            const workspace = try reading.allocator.create(Bounded(workspace_path.max_bytes));
            reading.row = .{ .workspace = workspace, .session = undefined, .catalog_content_id = null, .byte_length = null, .digest = null };
            a.readInto(latest, .{ .session = reading.session }, &reading.row, &reading.found);
            return .{ .round = .latest };
        };
        if (at == .latest) {
            if (!reading.found.get()) return error.SessionNotFound;
            const row = &reading.row;
            if (row.catalog_content_id == null) return .{ .read = .{ .entries = &.{} } };
            if (row.private != false or !row.source_consistent) return error.CorruptStore;
            if (row.catalog_position == null) return error.CorruptStore;
            const length = row.byte_length orelse return error.CorruptStore;
            if (row.digest == null) return error.CorruptStore;
            if (length > catalog.max_catalog_bytes) return error.CorruptStore;
            reading.bytes = try std.heap.c_allocator.alloc(u8, @intCast(length));
        }
        return reading.nextWindow(a);
    }

    fn nextWindow(reading: *Reading, a: anytype) !Step {
        const bytes = reading.bytes;
        const row = &reading.row;
        if (reading.offset < bytes.len) {
            const end = @min(reading.offset + content.verified_window_bytes, bytes.len);
            try a.readRaw(row.catalog_content_id.?.get(), reading.offset, bytes[reading.offset..end]);
            reading.offset = end;
            return .{ .round = .window };
        }
        defer reading.deinit();
        if (!std.mem.eql(u8, &content_string.digest(bytes), &row.digest.?)) return error.CorruptStore;
        const decoded = catalog.decodeCatalog(reading.allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CorruptStore,
        };
        if (row.catalog_position.? == 0 and decoded.entries.len != 0) return error.CorruptStore;
        return .{ .read = decoded };
    }

    pub fn deinit(reading: *Reading) void {
        std.heap.c_allocator.free(reading.bytes);
        reading.bytes = &.{};
    }
};

pub const ReloadRound = enum { latest, window, append };

pub const Reloading = struct {
    session: rsql.SessionHead,
    candidate: catalog.Catalog,
    allocator: std.mem.Allocator,
    phase: union(enum) { reading: Reading, appending: Appending },

    pub const Step = union(enum) { round: ReloadRound, reloaded: Result };

    pub fn init(session: rsql.SessionHead, candidate: catalog.Catalog, allocator: std.mem.Allocator) Reloading {
        return .{ .session = session, .candidate = candidate, .allocator = allocator, .phase = .{ .reading = .{ .session = &.{}, .allocator = allocator } } };
    }

    pub fn step(reloading: *Reloading, a: anytype, faults: store_core.Faults, ran: ?ReloadRound) !Step {
        const read_ran: ?ReadRound = if (ran) |at| switch (at) {
            .latest => .latest,
            .window => .window,
            .append => {
                try reloading.phase.appending.finish(a, faults);
                return .{ .reloaded = .{ .bytes = "Skills catalog reloaded.", .succeeded = true, .reload_status = .reloaded } };
            },
        } else null;
        const reading = &reloading.phase.reading;
        reading.session = &reloading.session.ref;
        const previous = switch (try reading.step(a, read_ran)) {
            .round => |at| return .{ .round = switch (at) {
                .latest => .latest,
                .window => .window,
            } },
            .read => |value| value,
        };
        const allocator = reloading.allocator;
        const delta = try catalog.diff(allocator, previous, reloading.candidate);
        if (delta.isEmpty()) return .{ .reloaded = .{ .bytes = "Skills are unchanged.", .succeeded = true, .reload_status = .unchanged } };
        const encoded = try catalog.encodeCatalog(allocator, reloading.candidate);
        const instruction = try catalog.deltaInstruction(allocator, delta);
        reloading.phase = .{ .appending = .{ .session = reloading.session, .encoded = encoded, .instruction = instruction } };
        reloading.phase.appending.queue(a);
        return .{ .round = .append };
    }

    pub fn deinit(reloading: *Reloading) void {
        switch (reloading.phase) {
            .reading => |*reading| reading.deinit(),
            .appending => {},
        }
    }
};

pub const Failure = struct {
    code: enum { unknown_session, unknown_skill, skill_file_unavailable, skill_file_too_large, skill_text_invalid, skills_unavailable },
    bytes: []const u8,

    pub fn configurationRejection(self: Failure) configuration_admission.Rejection {
        return switch (self.code) {
            .unknown_session => .unknown_session,
            .skills_unavailable => .skills_unavailable,
            .unknown_skill, .skill_file_unavailable, .skill_file_too_large, .skill_text_invalid => unreachable,
        };
    }
};

pub const ImportingFailure = struct {
    bytes: []const u8,
    outcome: content.Import = undefined,

    pub fn lookup(importing: *ImportingFailure, a: anytype) void {
        importing.outcome = .ofBytes(importing.bytes, false);
        content.lookup(a, &importing.outcome);
    }

    pub fn import(importing: *ImportingFailure, a: anytype, faults: store_core.Faults) !u64 {
        if (faults.content_import) return error.InjectedContentImportFailure;
        return content.importBytes(a, &importing.outcome, importing.bytes);
    }
};

pub const Capture = union(enum) {
    invocation: []const u8,
    reload: catalog.Catalog,
    failed: Failure,
};

pub const BoundSkill = struct { name: []const u8, bytes: []const u8 };

pub const MessageCapture = union(enum) {
    bound: []const BoundSkill,
    failed: MessageFailure,
};

const insert_message_skill = rsql.Write(.{
    .sql = "INSERT INTO message_skill(admission_id,position,name,content_id) VALUES(?1,?2,?3,?4)",
    .Args = struct { admission_id: u64, position: u64, name: []const u8, content_id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub const SavingBound = struct {
    admission_id: u64 = 0,
    bound: []const BoundSkill = &.{},
    saved: usize = 0,
    body: content.Import = undefined,

    pub fn lookupNext(saving: *SavingBound, a: anytype) bool {
        if (saving.saved == saving.bound.len) return false;
        saving.body = .ofBytes(saving.bound[saving.saved].bytes, false);
        content.lookup(a, &saving.body);
        return true;
    }

    pub fn save(saving: *SavingBound, a: anytype, faults: store_core.Faults) !void {
        if (faults.content_import) return error.InjectedContentImportFailure;
        const skill = saving.bound[saving.saved];
        const body = &saving.body;
        const content_id: u64 = if (body.found) |row| row.content_id.get() else a.insertedContent(&body.digest, body.length, false) orelse id: {
            const id = try content.insertRow(a, body);
            a.writeContent(id, skill.bytes);
            break :id id;
        };
        saving.saved += 1;
        a.write(insert_message_skill, .{ .admission_id = saving.admission_id, .position = saving.saved, .name = skill.name, .content_id = content_id });
    }
};

pub const MessageFailure = struct {
    code: enum { skill_file_unavailable, skill_file_too_large, skill_text_invalid },
    bytes: []const u8,

    pub fn rejection(self: MessageFailure) message_admission.Rejection {
        return switch (self.code) {
            inline else => |code| @field(message_admission.Rejection, @tagName(code)),
        };
    }
};

pub const Result = struct { bytes: []const u8, succeeded: bool, reload_status: ?mutation_answer.SkillsReloadStatus = null };

pub const SettleTool = struct {
    pub const rounds = transition.rounds(.{
        .facts = .{.always},
        .skills = .{.branch},
        .skills_window = .{.raw},
        .skills_append = .{.branch},
        .outcome = .{.always},
    });
    pub const round_budget = 3;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .facts;
    pub const Input = struct {
        binding: action_domain.ActionAttemptBinding,
        allocator: std.mem.Allocator,
        captured: *const Capture,
    };
    pub const Result = bool;
    pub const Ordinary = store_core.Ordinary.action_attempt || error{OutOfMemory};
    pub const Guards = store_core.Ordinary.action_attempt;
    pub const Declined = error{};

    input: Input,
    facts: action_domain.core_facts.Result = undefined,
    reloading: ?Reloading = null,
    bytes: []const u8 = &.{},
    succeeded: bool = false,
    outcome: content.Import = undefined,

    pub fn step(t: *SettleTool, r: *transition.Round(SettleTool), ran: ?rounds.At) !transition.Next(SettleTool) {
        const at = ran orelse {
            const binding = t.input.binding;
            const names: action_domain.CoreNames = .of();
            r.read(action_domain.core_facts, names.args(.{ .action_id = binding.action_id, .parent_operation_id = binding.parent_operation_id, .turn_id = binding.turn_id }), &t.facts);
            return .{ .round = .facts };
        };
        switch (at) {
            .facts => {
                const found = t.facts orelse return error.StaleActionAttemptBinding;
                if (found.stopped) return .{ .done = false };
                switch (t.input.captured.*) {
                    .invocation => |bytes| return t.lookupOutcome(r, bytes, true),
                    .failed => |failure| return t.lookupOutcome(r, failure.bytes, false),
                    .reload => |candidate| {
                        t.reloading = .init(found.session, candidate, t.input.allocator);
                        return t.reload(r, null);
                    },
                }
            },
            .skills => return t.reload(r, .latest),
            .skills_window => return t.reload(r, .window),
            .skills_append => return t.reload(r, .append),
            .outcome => {
                if (r.faults().content_import) return error.InjectedContentImportFailure;
                const outcome_id = try content.importBytes(r, &t.outcome, t.bytes);
                try action_domain.queueResolution(r, t.input.binding, t.facts.?.session, if (t.succeeded) .succeeded else .failed, outcome_id);
                if (r.faults().before_commit) return error.InjectedCommitFailure;
                return .commit;
            },
        }
    }

    noinline fn reload(t: *SettleTool, r: *transition.Round(SettleTool), ran: ?ReloadRound) !transition.Next(SettleTool) {
        const result = switch (try t.reloading.?.step(r, r.faults(), ran)) {
            .round => |round| return .{ .round = switch (round) {
                .latest => .skills,
                .window => .skills_window,
                .append => .skills_append,
            } },
            .reloaded => |value| value,
        };
        return t.lookupOutcome(r, result.bytes, result.succeeded);
    }

    fn lookupOutcome(t: *SettleTool, r: *transition.Round(SettleTool), bytes: []const u8, succeeded: bool) transition.Next(SettleTool) {
        t.bytes = bytes;
        t.succeeded = succeeded;
        t.outcome = .ofBytes(bytes, false);
        content.lookup(r, &t.outcome);
        return .{ .round = .outcome };
    }

    pub fn committed(_: *const SettleTool) bool {
        return true;
    }

    pub fn deinit(t: *SettleTool) void {
        if (t.reloading) |*reloading| reloading.deinit();
    }
};
