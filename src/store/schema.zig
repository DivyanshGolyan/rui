//! The Store's tables, indexes and triggers, created on a new database and
//! checked on an existing one when the Store opens.

const std = @import("std");
const protocol = @import("../protocol.zig");
const tool_catalog = @import("../tools.zig");
const prefix_seal = @import("../prefix_seal.zig");
const retry_policy = @import("../retry_policy.zig");
const turn_policy = @import("../turn_policy.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const sqlite = @import("sqlite.zig");
const c = sqlite.c;
const retry_allowance_open_sql = model_admission_domain.retry_allowance_open_sql;
const retry_exhausted_sql = model_admission_domain.retry_exhausted_sql;

comptime {
    // The schema's fixed literal for the seal's length.
    std.debug.assert(prefix_seal.encoded_bytes == 56);
}

pub const application_id: u32 = 0x4c544631; // LTF1
pub const schema_version: u32 = 45;

/// SQL membership of `column` in a set of enum tags or enum literals,
/// generated at compile time. An OR of equalities, not IN: SQLite builds a
/// temporary b-tree for an IN list of more than two values each time the
/// statement runs.
pub inline fn oneOf(comptime column: []const u8, comptime set: anytype) []const u8 {
    comptime var sql: []const u8 = "(";
    inline for (set, 0..) |tag, index| sql = sql ++ (if (index == 0) "" else " OR ") ++ column ++ "='" ++ @tagName(tag) ++ "'";
    return sql ++ ")";
}

/// The Resolutions whose output later context reads, as fixed literals: the
/// `model_operation_context_history` predicate and every query that must
/// repeat it term for term share this set, so the Store format never follows
/// `turn_policy.accepted` silently.
pub const accepted_resolutions = [_]turn_policy.Resolution{ .answer, .compacted, .tool_proposals };
comptime {
    if (!std.mem.eql(turn_policy.Resolution, &accepted_resolutions, &turn_policy.accepted))
        @compileError("turn_policy.accepted changed: change accepted_resolutions under a new schema_version");
}

const reasoning_effort_column_sql = " reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR " ++
    oneOf("reasoning_effort", .{ .none, .low, .medium, .high, .xhigh, .max }) ++ "),\n";

pub inline fn resolutionIs(comptime column: []const u8, comptime resolution: turn_policy.Resolution) []const u8 {
    return column ++ "='" ++ @tagName(resolution) ++ "'";
}

pub fn bootstrap(database: *c.sqlite3, selector: []const u8) !void {
    try sqlite.exec(database, "BEGIN EXCLUSIVE");
    errdefer sqlite.rollback(database);
    try sqlite.exec(database,
        \\CREATE TABLE store_meta(
        \\ key TEXT PRIMARY KEY,
        \\ value TEXT NOT NULL
        \\) STRICT;
        \\CREATE TABLE content(
        \\ content_id INTEGER PRIMARY KEY,
        \\ digest BLOB NOT NULL CHECK(length(digest)=32),
        \\ byte_length INTEGER NOT NULL CHECK(byte_length>=0 AND byte_length<=1073737728),
        \\ private INTEGER NOT NULL CHECK(private IN (0,1)),
        \\ payload BLOB NOT NULL CHECK(length(payload)=byte_length),
        \\ UNIQUE(digest,byte_length,private)
        \\) STRICT;
        \\CREATE TABLE session(
        \\ session_ref TEXT PRIMARY KEY CHECK(length(session_ref)=6 AND length(CAST(session_ref AS BLOB))=6 AND session_ref NOT GLOB '*[^0123456789abcdefghjkmnpqrstvwxyz]*'),
        \\ workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),
        \\ -- A label's syntax, not a provider list, so a new provider is no format change.
        \\ provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND provider NOT GLOB '*[^a-z0-9_-]*'),
        \\ -- The Session's immutable binding: grammar version and its options.
        \\ codec TEXT NOT NULL CHECK(length(CAST(codec AS BLOB)) BETWEEN 3 AND 40),
        \\ codec_options BLOB CHECK(codec_options IS NULL OR length(codec_options) BETWEEN 1 AND 512),
        \\ -- What the last fully rebuilt history span encoded to (prefix_seal.zig).
        \\ prefix_seal BLOB CHECK(prefix_seal IS NULL OR length(prefix_seal)=56),
        \\ model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
    ++ std.fmt.comptimePrint(" tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND {d}),\n", .{comptime tool_catalog.toolBit(.bash)}) ++
        \\ permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ revision INTEGER NOT NULL CHECK(revision>0),
        \\ compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
        \\ output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),
    ++ reasoning_effort_column_sql ++
        \\ label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),
        \\ created_at INTEGER NOT NULL CHECK(created_at>0),
        \\ next_position INTEGER NOT NULL CHECK(next_position>0)
        \\) STRICT;
        \\CREATE INDEX session_workspace_list ON session(workspace);
        \\CREATE TABLE core_command(
        \\ command_key TEXT PRIMARY KEY CHECK(length(CAST(command_key AS BLOB))<=128),
        \\ kind INTEGER NOT NULL CHECK(kind BETWEEN 1 AND 5),
        \\ target TEXT NOT NULL CHECK(length(CAST(target AS BLOB))<=128),
        \\ input_digest BLOB NOT NULL CHECK(length(input_digest)=32),
        \\ primary_content_id INTEGER REFERENCES content(content_id),
        \\ secondary_content_id INTEGER REFERENCES content(content_id),
        \\ accepted INTEGER NOT NULL CHECK(accepted IN (0,1)),
        \\ code TEXT NOT NULL CHECK(length(CAST(code AS BLOB))<=96),
        \\ revision INTEGER NOT NULL CHECK(revision>=0),
        \\ created INTEGER NOT NULL CHECK(created IN (0,1))
        \\) STRICT;
        \\CREATE TABLE session_revision(
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ revision INTEGER NOT NULL CHECK(revision>0),
        \\ command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ workspace TEXT NOT NULL,
        \\ provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND provider NOT GLOB '*[^a-z0-9_-]*'),
        \\ model TEXT NOT NULL,
        \\ instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ instructions_updated INTEGER NOT NULL CHECK(instructions_updated IN (0,1)),
    ++ std.fmt.comptimePrint(" tools_mask INTEGER NOT NULL CHECK(tools_mask BETWEEN 0 AND {d}),\n", .{comptime tool_catalog.toolBit(.bash)}) ++
        \\ permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),
        \\ output_schema_content_id INTEGER REFERENCES content(content_id),
        \\ compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
        \\ output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),
    ++ reasoning_effort_column_sql ++
        \\ label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),
        \\ PRIMARY KEY(session_ref,revision)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE message_admission(
        \\ admission_id INTEGER PRIMARY KEY CHECK(admission_id>0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ admission_position INTEGER CHECK(admission_position>0),
        \\ turn_id INTEGER REFERENCES turn(turn_id) DEFERRABLE INITIALLY DEFERRED,
        \\ admitted_at INTEGER NOT NULL CHECK(admitted_at>0),
        \\ sender_session_ref TEXT REFERENCES session(session_ref),
        \\ sender_position INTEGER CHECK(sender_position>0),
        \\ CHECK((sender_session_ref IS NULL)=(sender_position IS NULL))
        \\) STRICT;
        \\CREATE UNIQUE INDEX message_admission_sent ON message_admission(sender_session_ref,sender_position) WHERE sender_session_ref IS NOT NULL;
        \\CREATE TABLE sent_rejection(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key) DEFERRABLE INITIALLY DEFERRED,
        \\ sender_session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ sender_position INTEGER NOT NULL CHECK(sender_position>0),
        \\ rejected_at INTEGER NOT NULL CHECK(rejected_at>0),
        \\ UNIQUE(sender_session_ref,sender_position)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE turn(
        \\ turn_id INTEGER PRIMARY KEY CHECK(turn_id>0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ first_admission_id INTEGER NOT NULL REFERENCES message_admission(admission_id) DEFERRABLE INITIALLY DEFERRED,
        \\ input_cutoff INTEGER NOT NULL CHECK(input_cutoff>=first_admission_id),
        \\ operation_id INTEGER NOT NULL,
        \\ outcome_code TEXT CHECK(outcome_code IS NULL OR length(CAST(outcome_code AS BLOB)) BETWEEN 1 AND 96),
        \\ outcome_content_id INTEGER REFERENCES content(content_id),
        \\ outcome_position INTEGER CHECK(outcome_position>0),
        \\ outcome_at INTEGER CHECK(outcome_at IS NULL OR outcome_at>0),
        \\ continuation_operation_id INTEGER CHECK(continuation_operation_id IS NULL OR continuation_operation_id<=operation_id),
        \\ CHECK((outcome_code IS NULL)=(outcome_at IS NULL))
        \\) STRICT;
        \\CREATE UNIQUE INDEX turn_one_active_per_session ON turn(session_ref) WHERE outcome_code IS NULL;
        \\CREATE INDEX turn_tool_continuation ON turn(operation_id) WHERE outcome_code IS NULL AND continuation_operation_id=operation_id;
        \\CREATE TABLE session_stop(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ selected_turn_id INTEGER REFERENCES turn(turn_id),
        \\ position INTEGER CHECK(position>0),
        \\ admission_cutoff INTEGER NOT NULL CHECK(admission_cutoff>=0),
        \\ stopped_at INTEGER NOT NULL CHECK(stopped_at>0)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_interruption_command(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ session_ref TEXT NOT NULL CHECK(length(CAST(session_ref AS BLOB))<=128),
        \\ turn_id TEXT NOT NULL CHECK(length(turn_id) BETWEEN 1 AND 20),
        \\ operation_id TEXT NOT NULL CHECK(length(operation_id) BETWEEN 1 AND 20)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_operation(
        \\ operation_id INTEGER PRIMARY KEY CHECK(operation_id>0),
        \\ turn_id INTEGER NOT NULL REFERENCES turn(turn_id) DEFERRABLE INITIALLY DEFERRED,
        \\ session_ref TEXT NOT NULL,
        \\ settings_revision INTEGER NOT NULL CHECK(settings_revision>0),
        \\ input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),
        \\ admission_position INTEGER NOT NULL CHECK(admission_position>0),
        \\ purpose INTEGER NOT NULL DEFAULT 0 CHECK(purpose IN (0,1)),
        \\ compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),
        \\ output_reservation INTEGER NOT NULL CHECK(output_reservation>=0),
    ++ reasoning_effort_column_sql ++
        \\ output_item_count INTEGER CHECK(output_item_count IS NULL OR output_item_count>=0),
        \\
    ++ std.fmt.comptimePrint(" attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal BETWEEN 1 AND {d}),\n", .{retry_policy.maximum_attempts}) ++
        \\ auth_refresh_claimed INTEGER NOT NULL DEFAULT 0 CHECK(auth_refresh_claimed IN (0,1)),
        \\ retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),
        \\ last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),
        \\ resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),
        \\ resolution_content_id INTEGER REFERENCES content(content_id),
        \\ response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),
        \\ model_evidence BLOB CHECK(model_evidence IS NULL OR length(model_evidence) BETWEEN 7 AND 775),
        \\ request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),
        \\ usage_content_id INTEGER REFERENCES content(content_id),
        \\ usage_uncached_tokens INTEGER CHECK(usage_uncached_tokens IS NULL OR usage_uncached_tokens>=0),
        \\ usage_cache_read_tokens INTEGER CHECK(usage_cache_read_tokens IS NULL OR usage_cache_read_tokens>=0),
        \\ usage_cache_write_tokens INTEGER CHECK(usage_cache_write_tokens IS NULL OR usage_cache_write_tokens>=0),
        \\ usage_output_tokens INTEGER CHECK(usage_output_tokens IS NULL OR usage_output_tokens>=0),
        \\ interrupted_by_command_key TEXT REFERENCES core_command(command_key),
        \\ attempt_at INTEGER CHECK(attempt_at IS NULL OR attempt_at>0),
        \\ retry_scheduled_at INTEGER CHECK(retry_scheduled_at IS NULL OR retry_scheduled_at>0),
        \\ resolved_at INTEGER CHECK(resolved_at IS NULL OR resolved_at>0),
        \\ FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),
        \\ -- Usage counts are all present or all absent, and only beside the report.
        \\ CHECK((usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR
        \\       (usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND
        \\        usage_output_tokens IS NOT NULL AND usage_content_id IS NOT NULL)),
        \\ CHECK((resolution_code IS NULL AND retry_due_at_ms IS NOT NULL) OR (resolution_code IS NOT NULL AND retry_due_at_ms IS NULL)),
        \\ -- The second the current state began: exactly the time its state owns.
        \\ CHECK((resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at IS NOT NULL AND retry_scheduled_at IS NULL AND resolved_at IS NULL) OR
        \\       (resolution_code IS NULL AND retry_due_at_ms>0 AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND resolved_at IS NULL) OR
        \\       (resolution_code IS NOT NULL AND attempt_at IS NULL AND retry_scheduled_at IS NULL AND resolved_at IS NOT NULL)),
        \\ CHECK((resolution_code IS 'interrupted' AND interrupted_by_command_key IS NOT NULL) OR
        \\       (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL)),
        \\ UNIQUE(operation_id,session_ref)
        \\) STRICT;
        \\CREATE TABLE conversation_entry(
        \\ session_ref TEXT NOT NULL,
        \\ entry_ordinal INTEGER NOT NULL CHECK(entry_ordinal>0),
        \\ session_position INTEGER NOT NULL CHECK(session_position>0),
        \\ entry_kind INTEGER NOT NULL CHECK(entry_kind BETWEEN 1 AND 3),
        \\ turn_id INTEGER NOT NULL REFERENCES turn(turn_id),
        \\ source_admission_id INTEGER UNIQUE REFERENCES message_admission(admission_id),
        \\ source_revision INTEGER,
        \\ source_operation_id INTEGER REFERENCES model_operation(operation_id),
        \\ source_item_ordinal INTEGER CHECK(source_item_ordinal IS NULL OR source_item_ordinal>=0),
        \\ content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ recorded_at INTEGER NOT NULL CHECK(recorded_at>0),
        \\ PRIMARY KEY(session_ref,entry_ordinal),
        \\ UNIQUE(session_ref,session_position),
        \\ UNIQUE(session_ref,source_revision),
        \\ FOREIGN KEY(session_ref,source_revision) REFERENCES session_revision(session_ref,revision),
        \\ FOREIGN KEY(source_operation_id,source_item_ordinal) REFERENCES model_output_item(operation_id,item_ordinal),
        \\ CHECK((entry_kind=3)=(source_item_ordinal IS NOT NULL)),
        \\ CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_operation_id IS NULL) OR
        \\       (entry_kind=2 AND source_admission_id IS NULL AND source_revision IS NOT NULL AND source_operation_id IS NULL) OR
        \\       (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_operation_id IS NOT NULL))
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_output_item(
        \\ operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
        \\ item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
        \\ session_ref TEXT NOT NULL,
        \\ session_position INTEGER NOT NULL CHECK(session_position>0),
        \\ item_kind INTEGER NOT NULL CHECK(item_kind BETWEEN 1 AND 4),
        \\ -- A message's text: its text parts back to back, stored once.
        \\ message_content_id INTEGER REFERENCES content(content_id) CHECK((message_content_id IS NOT NULL)=(item_kind=2)),
        \\ attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),
        \\ item_id_digest BLOB NOT NULL CHECK(length(item_id_digest)=32),
        \\ replay_omits_reasoning_text INTEGER NOT NULL CHECK(replay_omits_reasoning_text IN (0,1) AND (replay_omits_reasoning_text=0 OR item_kind=1)),
        \\ -- Rui's own form: the message phase, the parts below, and the
        \\ -- provider bag of what that form does not hold.
        \\ phase INTEGER NOT NULL DEFAULT 0 CHECK(phase IN (0,1,2) AND (phase=0 OR item_kind=2)),
        \\ extras_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ part_count INTEGER NOT NULL CHECK(part_count>=0 AND (part_count=0 OR item_kind IN (1,2))),
        \\ PRIMARY KEY(operation_id,item_ordinal),
        \\ UNIQUE(session_ref,session_position),
        \\ UNIQUE(operation_id,item_id_digest)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_output_part(
        \\ operation_id INTEGER NOT NULL,
        \\ item_ordinal INTEGER NOT NULL,
        \\ part_ordinal INTEGER NOT NULL CHECK(part_ordinal>=0),
        \\ part_array INTEGER NOT NULL CHECK(part_array IN (1,2)),
        \\ -- output_text and refusal are message content, summary_text a
        \\ -- summary, reasoning_text reasoning content; 0 is an opaque block.
        \\ part_kind INTEGER NOT NULL CHECK(part_kind=0 OR (part_kind IN (1,2,4) AND part_array=1) OR (part_kind=3 AND part_array=2)),
        \\ -- A message part's text is the next text_length bytes of its
        \\ -- item's message text; a reasoning part's text is its own row.
        \\ text_length INTEGER CHECK(text_length IS NULL OR text_length>=0),
        \\ text_content_id INTEGER REFERENCES content(content_id),
        \\ extras_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ CHECK((text_length IS NOT NULL)=(part_kind IN (1,2)) AND (text_content_id IS NOT NULL)=(part_kind IN (3,4))),
        \\ PRIMARY KEY(operation_id,item_ordinal,part_ordinal)
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE model_tool_call(
        \\ operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
        \\ call_ordinal INTEGER NOT NULL CHECK(call_ordinal>=0),
        \\ item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),
        \\ name_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ call_id_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ arguments_content_id INTEGER NOT NULL REFERENCES content(content_id),
        \\ description TEXT CHECK(description IS NULL OR length(CAST(description AS BLOB)) BETWEEN 1 AND 100),
        \\ field_metadata BLOB NOT NULL CHECK(length(field_metadata)=120),
        \\ rejection_code TEXT CHECK(rejection_code IS NULL OR rejection_code IN ('unknown_tool','invalid_arguments')),
        \\ rejection_content_id INTEGER REFERENCES content(content_id),
        \\ acceptance_position INTEGER CHECK(acceptance_position IS NULL OR acceptance_position>0),
        \\ action_kind INTEGER CHECK(action_kind IS NULL OR action_kind=1),
        \\ PRIMARY KEY(operation_id,call_ordinal),
        \\ UNIQUE(operation_id,item_ordinal),
        \\ UNIQUE(operation_id,call_id_content_id),
        \\ UNIQUE(operation_id,call_ordinal,action_kind),
        \\ CHECK((rejection_code IS NULL AND rejection_content_id IS NULL AND acceptance_position IS NULL AND action_kind IS 1) OR
        \\       (rejection_code IS NOT NULL AND rejection_content_id IS NOT NULL AND acceptance_position IS NOT NULL AND action_kind IS NULL))
        \\) STRICT, WITHOUT ROWID;
        \\CREATE TABLE action_operation(
        \\ action_id INTEGER PRIMARY KEY CHECK(action_id>0),
        \\ parent_operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),
        \\ call_ordinal INTEGER NOT NULL CHECK(call_ordinal>=0),
        \\ session_ref TEXT NOT NULL REFERENCES session(session_ref),
        \\ tool_kind INTEGER NOT NULL CHECK(tool_kind=1),
        \\ permission_revision INTEGER NOT NULL CHECK(permission_revision>0),
        \\ -- Written only by the insert, under a `bypass` revision, and by an
        \\ -- accepted `allow_once` decision. Stored because it keys the
        \\ -- admission index, and no partial index can see the revision or grant.
        \\ authorized INTEGER NOT NULL CHECK(authorized IN (0,1)),
        \\ attempt_ordinal INTEGER NOT NULL DEFAULT 0 CHECK(attempt_ordinal IN (0,1)),
        \\ bash_timeout_override_ms INTEGER CHECK(bash_timeout_override_ms IS NULL OR bash_timeout_override_ms>0),
        \\ bash_timeout_ms INTEGER CHECK(bash_timeout_ms IS NULL OR bash_timeout_ms>0),
        \\ sender_handle TEXT CHECK(sender_handle IS NULL OR (length(sender_handle)=32 AND sender_handle NOT GLOB '*[^0-9a-f]*')),
    ++ " resolution_code TEXT CHECK(resolution_code IS NULL OR " ++ oneOf("resolution_code", .{ .denied, .cancelled, .succeeded, .failed, .timed_out, .indeterminate, .storage_failed, .spawn_failed, .infrastructure_shutdown }) ++ "),\n" ++
        \\ resolution_content_id INTEGER REFERENCES content(content_id),
        \\ acceptance_position INTEGER CHECK(acceptance_position IS NULL OR acceptance_position>0),
        \\ attempt_at INTEGER CHECK(attempt_at IS NULL OR attempt_at>0),
        \\ decided_at INTEGER CHECK(decided_at IS NULL OR decided_at>0),
        \\ resolved_at INTEGER CHECK(resolved_at IS NULL OR resolved_at>0),
        \\ UNIQUE(parent_operation_id,call_ordinal),
        \\ FOREIGN KEY(parent_operation_id,session_ref) REFERENCES model_operation(operation_id,session_ref),
        \\ FOREIGN KEY(parent_operation_id,call_ordinal,tool_kind) REFERENCES model_tool_call(operation_id,call_ordinal,action_kind),
        \\ FOREIGN KEY(session_ref,permission_revision) REFERENCES session_revision(session_ref,revision),
        \\ CHECK(resolution_code IS NOT 'denied' OR (authorized=0 AND attempt_ordinal=0)),
        \\ CHECK((attempt_ordinal=0 AND bash_timeout_ms IS NULL) OR
        \\       (attempt_ordinal=1 AND bash_timeout_ms IS NOT NULL)),
        \\ CHECK((resolution_code IS NULL AND resolution_content_id IS NULL AND acceptance_position IS NULL) OR
        \\       (resolution_code IS NOT NULL AND resolution_content_id IS NOT NULL AND acceptance_position IS NOT NULL)),
        \\ CHECK((attempt_ordinal=1)=(attempt_at IS NOT NULL)),
        \\ CHECK((authorized=1)=(decided_at IS NOT NULL)),
        \\ CHECK((resolution_code IS NULL)=(resolved_at IS NULL))
        \\) STRICT;
        \\CREATE TABLE permission_decision_command(
        \\ command_key TEXT PRIMARY KEY REFERENCES core_command(command_key),
        \\ action_id TEXT NOT NULL CHECK(length(action_id) BETWEEN 1 AND 20),
        \\ decision TEXT NOT NULL CHECK(decision IN ('allow_once','deny'))
        \\) STRICT, WITHOUT ROWID;
        \\CREATE INDEX message_admission_session_order ON message_admission(session_ref,turn_id,admission_id);
        \\CREATE INDEX message_admission_pending ON message_admission(admission_id,session_ref) WHERE turn_id IS NULL;
        \\CREATE INDEX message_admission_session_pending ON message_admission(session_ref,admission_id) WHERE turn_id IS NULL;
        \\CREATE INDEX message_admission_person ON message_admission(session_ref,admission_position) WHERE sender_session_ref IS NULL;
        \\CREATE INDEX message_admission_unpositioned ON message_admission(session_ref) WHERE admission_position IS NULL;
        \\CREATE INDEX session_stop_exclusion ON session_stop(session_ref,admission_cutoff,position);
        \\CREATE INDEX session_stop_unpositioned ON session_stop(session_ref) WHERE position IS NULL;
        \\CREATE INDEX session_stop_turn ON session_stop(selected_turn_id);
        \\CREATE INDEX action_operation_session_order ON action_operation(session_ref,action_id);
        \\CREATE UNIQUE INDEX action_operation_sender_handle ON action_operation(sender_handle) WHERE sender_handle IS NOT NULL;
        \\CREATE INDEX action_operation_acceptance ON action_operation(session_ref,acceptance_position);
        \\CREATE INDEX action_operation_executable ON action_operation(action_id) WHERE authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0;
        \\CREATE INDEX action_operation_unresolved_attempt ON action_operation(action_id) WHERE resolution_code IS NULL AND attempt_ordinal=1;
        \\CREATE INDEX model_tool_call_rejections ON model_tool_call(operation_id,call_ordinal) WHERE rejection_code IS NOT NULL;
        \\
    ++ "CREATE INDEX model_operation_retry_due ON model_operation(retry_due_at_ms,operation_id) WHERE resolution_code IS NULL AND " ++
        retry_allowance_open_sql ++ ";\n" ++
        "CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE " ++ retry_exhausted_sql ++ ";\n" ++
        \\CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id);
        \\CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id);
        \\
    ++ "CREATE INDEX model_operation_context_history ON model_operation(session_ref,admission_position) WHERE " ++
        oneOf("resolution_code", &accepted_resolutions) ++ ";\n" ++
        "CREATE INDEX model_operation_compaction_bases ON model_operation(session_ref,admission_position) WHERE purpose=1 AND " ++
        resolutionIs("resolution_code", .compacted) ++ ";\n" ++
        \\CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position);
        \\CREATE INDEX model_output_history ON model_output_item(session_ref,session_position);
        \\CREATE INDEX model_output_compaction_anchor ON model_output_item(operation_id,item_ordinal) WHERE item_kind=4;
        \\CREATE INDEX turn_session_latest ON turn(session_ref,turn_id DESC);
        \\CREATE INDEX turn_unpositioned ON turn(session_ref) WHERE (outcome_code IS NULL)!=(outcome_position IS NULL);
    );
    try sqlite.exec(database, "PRAGMA application_id=1280591409");
    try sqlite.exec(database, std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version}));
    const statement = try sqlite.prepare(database, "INSERT INTO store_meta(key,value) VALUES('wire_version','" ++ protocol.wire_version ++ "'),('store_selector',?1)");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, selector);
    try sqlite.expectDone(statement);
    try sqlite.exec(database, "COMMIT");
}

pub fn validateExisting(database: *c.sqlite3, selector: []const u8) !void {
    if (try sqlite.pragmaInt(database, "PRAGMA application_id") != application_id) return error.WrongStoreIdentity;
    if (try sqlite.pragmaInt(database, "PRAGMA user_version") != schema_version) return error.WrongStoreVersion;
    {
        const statement = try sqlite.prepare(
            database,
            "SELECT count(*) FROM sqlite_schema WHERE " ++
                "(type='table' AND name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','sent_rejection','turn','session_stop','model_interruption_command','model_operation','conversation_entry','model_output_item','model_output_part','model_tool_call','action_operation','permission_decision_command')) OR " ++
                "(type='index' AND ((sql IS NULL AND tbl_name NOT IN ('store_meta','content','session','core_command','session_revision','message_admission','sent_rejection','turn','session_stop','model_interruption_command','model_operation','conversation_entry','model_output_item','model_output_part','model_tool_call','action_operation','permission_decision_command')) OR " ++
                "(sql IS NOT NULL AND name NOT IN ('session_workspace_list','message_admission_session_order','message_admission_pending','message_admission_session_pending','message_admission_sent','message_admission_person','message_admission_unpositioned','session_stop_exclusion','session_stop_unpositioned','session_stop_turn','action_operation_session_order','action_operation_sender_handle','action_operation_acceptance','action_operation_executable','action_operation_unresolved_attempt','model_tool_call_rejections','turn_one_active_per_session','turn_tool_continuation','model_operation_retry_due','model_operation_retry_exhausted','model_operation_session_history','model_operation_turn_history','model_operation_context_history','model_operation_compaction_bases','conversation_entry_history','model_output_history','model_output_compaction_anchor','turn_session_latest','turn_unpositioned')))) OR " ++
                "type NOT IN ('table','index')",
        );
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or c.sqlite3_column_int64(statement, 0) != 0) {
            return error.WrongStoreSchema;
        }
    }
    {
        const statement = try sqlite.prepare(database, "SELECT value FROM store_meta WHERE key='wire_version'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreVersion;
        var version: protocol.Bounded(16) = .{};
        try sqlite.readText(statement, 0, &version);
        if (!version.eql(protocol.wire_version)) return error.WrongStoreVersion;
    }
    {
        const statement = try sqlite.prepare(database, "SELECT value FROM store_meta WHERE key='store_selector'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreIdentity;
        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try sqlite.readText(statement, 0, &stored_selector);
        if (!stored_selector.eql(selector)) return error.WrongStoreIdentity;
    }
}
