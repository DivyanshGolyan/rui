//! The Store schema as one value: its tables and indexes, from which each
//! engine's DDL derives. A new database gets the DDL; an existing one's
//! stored DDL is compared with it when it opens.

const std = @import("std");
const session_settings = @import("../session_settings.zig");
const store_path = @import("../store_path.zig");
const tool_name = @import("../tool_name.zig");
const Bounded = @import("../bounded.zig").Bounded;
const wire_version = @import("../wire_version.zig").wire_version;
const tool_defs = @import("../tool_record.zig");
const prefix_seal = @import("../prefix_seal.zig");
const retry_policy = @import("../retry_policy.zig");
const turn_policy = @import("../turn_policy.zig");
const model_admission_domain = @import("domain/model_admission.zig");
const rsql = @import("rsql.zig");
const sqlite = @import("sqlite.zig");
const c = sqlite.c;
const retry_allowance_open_sql = model_admission_domain.retry_allowance_open_sql;
const retry_exhausted_sql = model_admission_domain.retry_exhausted_sql;

pub const application_id: u32 = 0x4c544631; // LTF1
pub const schema_version: u32 = 74;

pub const IdentityMismatch = struct {
    saved_selector: Bounded(store_path.max_bytes) = .{},
};

/// `digest()` of each schema_version, oldest first. Each format PR appends
/// its own version and forward step (D226); main's digests and steps are
/// immutable even before release. tests/ci/test_store_schema_version.py
/// checks both main's prefix and every released format.
pub const bootstrap_digests = [_]struct { schema_version: u32, digest: u64 }{
    .{ .schema_version = 45, .digest = 0xcc384bb0b78d3949 },
    .{ .schema_version = 46, .digest = 0xf3129842e4a7d447 },
    .{ .schema_version = 47, .digest = 0x51267b57c44099bc },
    .{ .schema_version = 48, .digest = 0xc82dff5ecb5926eb },
    .{ .schema_version = 49, .digest = 0x7308286ccc227397 },
    .{ .schema_version = 50, .digest = 0x5d687971ecde9643 },
    .{ .schema_version = 51, .digest = 0x645a2e73aee4e799 },
    .{ .schema_version = 52, .digest = 0xa0ecf02ad8b7ca02 },
    .{ .schema_version = 53, .digest = 0x80e0a8d969288327 },
    .{ .schema_version = 54, .digest = 0xae916e0373329df9 },
    .{ .schema_version = 55, .digest = 0x4acf921dca365b6e },
    .{ .schema_version = 56, .digest = 0xbdf9ac7b6016b1da },
    .{ .schema_version = 57, .digest = 0x75359f28a14f23a9 },
    .{ .schema_version = 58, .digest = 0x4cd0a6b38d4904ed },
    .{ .schema_version = 59, .digest = 0xa3ebc37622ed945b },
    .{ .schema_version = 60, .digest = 0x6b696b3423202987 },
    .{ .schema_version = 61, .digest = 0xec460e03aa080495 },
    .{ .schema_version = 62, .digest = 0x3d68029b9bcbfdd0 },
    .{ .schema_version = 63, .digest = 0x7a09d94b6ba24eea },
    .{ .schema_version = 64, .digest = 0xba89834313d6181f },
    .{ .schema_version = 65, .digest = 0x78987c40a911dee5 },
    .{ .schema_version = 66, .digest = 0x7eb536169708902e },
    .{ .schema_version = 67, .digest = 0xfe425e8cc64247f5 },
    .{ .schema_version = 68, .digest = 0x7bec7f8f004abc7c },
    .{ .schema_version = 69, .digest = 0x8db67f4a14f18a37 },
    .{ .schema_version = 70, .digest = 0xb60d036b364ad267 },
    .{ .schema_version = 71, .digest = 0xa61e85ed49f9fa8b },
    .{ .schema_version = 72, .digest = 0x93ee71c21e7438ab },
    .{ .schema_version = 73, .digest = 0x515b60c7f5df332d },
    .{ .schema_version = 74, .digest = 0x493062beb46c07ad },
};
comptime {
    for (bootstrap_digests[1..], bootstrap_digests[0 .. bootstrap_digests.len - 1]) |row, previous| {
        if (row.schema_version <= previous.schema_version) @compileError("bootstrap_digests: versions must ascend");
    }
    const current = bootstrap_digests[bootstrap_digests.len - 1];
    if (current.schema_version != schema_version) @compileError(std.fmt.comptimePrint(
        "bootstrap_digests: append .{{ .schema_version = {d}, .digest = 0x{x:0>16} }}",
        .{ schema_version, digest() },
    ));
    if (current.digest != digest()) @compileError(std.fmt.comptimePrint(
        "the Store's bootstrap changed: the new format's digest is 0x{x:0>16}; append a version and step instead of changing main's rows (D226)",
        .{digest()},
    ));
}

/// The oldest format a Store moves forward from (D204). An older Store, or
/// a newer one, is refused with WrongStoreVersion, as before migrations.
pub const migration_baseline: u32 = 51;

/// One forward step of the Store format, from `from` to `from + 1`, as
/// statements per engine. SQLite runs `sqlite` when a Store opens
/// (`openExisting`). Rui runs no DDL on MySQL (D203): the DB team runs
/// `mysql`, which `mysqlMigration` joins. Every statement is one string
/// literal, so the source is the text that runs: a CHECK or predicate is
/// copied from the schema's rendered text (`ddl`), whose source passed
/// `rsql.expressionError`, and the migration tests hold the migrated Store
/// to that text. tests/ci/test_store_schema_version.py refuses an entry
/// that is anything but literals, and compares every step whose `from` is
/// below the released schema_version with its text at the release.
///
/// SQLite keeps each CREATE text as run, and a Store opens only when every
/// object's text equals a fresh bootstrap's. ALTER TABLE ADD COLUMN splices
/// the new column into the stored text, and RENAME quotes the new name, so
/// a step that changes a table rebuilds it: it renames the table aside,
/// creates it with the new text, copies its rows, drops the old table and
/// creates its indexes again. `migrate` runs the steps with foreign keys
/// off and legacy_alter_table on, so other tables' references keep the
/// table's name, and checks every foreign key before it commits.
pub const Migration = struct {
    from: u32,
    sqlite: []const [:0]const u8,
    mysql: []const [:0]const u8,
};

/// Every step from `migration_baseline` to `schema_version`, oldest first.
/// The baseline snapshots (migration_baseline.*.sql) never change; the
/// chain grows; steps already on main or released never change (D226).
pub const migrations = [_]Migration{
    // 52 (T1e): MCP tool records name their server, host_catalog originally named
    // the Host tool set, which holds up to
    // max_host_tool_records. Every record so far is Rui's or a provider's,
    // so its server is empty. MySQL names a table's CHECKs in order, so
    // the third of tool_record and of tool_set is the one replaced.
    .{
        .from = 51,
        .sqlite = &.{
            "ALTER TABLE tool_record RENAME TO tool_record_51",
            "CREATE TABLE tool_record(\n tool_record_id INTEGER PRIMARY KEY NOT NULL CHECK(tool_record_id>0),\n name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 64 AND (name NOT GLOB '*[^A-Za-z0-9_-]*' AND length(name)=length(CAST(name AS BLOB)))),\n owner TEXT NOT NULL CHECK((owner='rui' OR owner='provider' OR owner='mcp')),\n server TEXT NOT NULL CHECK(length(CAST(server AS BLOB))<=64 AND (server NOT GLOB '*[^A-Za-z0-9_-]*' AND length(server)=length(CAST(server AS BLOB))) AND (owner='mcp' AND length(CAST(server AS BLOB))>0 OR owner<>'mcp' AND length(CAST(server AS BLOB))=0)),\n description_content_id INTEGER NOT NULL REFERENCES content(content_id),\n input_schema_content_id INTEGER NOT NULL REFERENCES content(content_id),\n UNIQUE(name,owner,server,description_content_id,input_schema_content_id)\n) STRICT",
            "INSERT INTO tool_record(tool_record_id,name,owner,server,description_content_id,input_schema_content_id) SELECT tool_record_id,name,owner,'',description_content_id,input_schema_content_id FROM tool_record_51",
            "DROP TABLE tool_record_51",
            "ALTER TABLE tool_set RENAME TO tool_set_51",
            "CREATE TABLE tool_set(\n tool_set_id INTEGER PRIMARY KEY NOT NULL CHECK(tool_set_id>0),\n digest BLOB NOT NULL UNIQUE CHECK(length(digest)=32),\n member_count INTEGER NOT NULL CHECK(member_count BETWEEN 0 AND 1024)\n) STRICT",
            "INSERT INTO tool_set(tool_set_id,digest,member_count) SELECT tool_set_id,digest,member_count FROM tool_set_51",
            "DROP TABLE tool_set_51",
            "CREATE TABLE host_catalog(\n slot INTEGER PRIMARY KEY NOT NULL CHECK(slot=1),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id)\n) STRICT",
        },
        .mysql = &.{
            "ALTER TABLE tool_record ADD COLUMN server VARCHAR(64) NOT NULL DEFAULT '' AFTER owner",
            "ALTER TABLE tool_record ALTER COLUMN server DROP DEFAULT",
            "ALTER TABLE tool_record DROP INDEX name, ADD UNIQUE(name,owner,server,description_content_id,input_schema_content_id)",
            "ALTER TABLE tool_record DROP CHECK tool_record_chk_3, ADD CHECK((owner='rui' OR owner='provider' OR owner='mcp')), ADD CHECK(OCTET_LENGTH(server)<=64 AND (NOT REGEXP_LIKE(server,'[^A-Za-z0-9_-]','c')) AND (owner='mcp' AND OCTET_LENGTH(server)>0 OR owner<>'mcp' AND OCTET_LENGTH(server)=0))",
            "ALTER TABLE tool_set DROP CHECK tool_set_chk_3, ADD CHECK(member_count BETWEEN 0 AND 1024)",
            "CREATE TABLE host_catalog(\n slot BIGINT NOT NULL,\n tool_set_id BIGINT NOT NULL,\n PRIMARY KEY(slot),\n FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id),\n CHECK(slot=1)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
        },
    },
    // Schema 53: a Session's parent (D27).
    .{
        .from = 52,
        .sqlite = &.{
            "ALTER TABLE session RENAME TO session_before_53",
            "CREATE TABLE session(\n session_ref TEXT PRIMARY KEY NOT NULL CHECK(length(CAST(session_ref AS BLOB))=6 AND (session_ref NOT GLOB '*[^0123456789abcdefghjkmnpqrstvwxyz]*' AND length(session_ref)=length(CAST(session_ref AS BLOB)))),\n workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),\n provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND (provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))),\n codec TEXT NOT NULL CHECK(length(CAST(codec AS BLOB)) BETWEEN 3 AND 40),\n codec_options BLOB CHECK(codec_options IS NULL OR length(codec_options) BETWEEN 1 AND 512),\n prefix_seal BLOB CHECK(prefix_seal IS NULL OR length(prefix_seal)=56),\n model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),\n instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),\n permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),\n output_schema_content_id INTEGER REFERENCES content(content_id),\n revision INTEGER NOT NULL CHECK(revision>0),\n compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),\n output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),\n reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),\n label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),\n created_at INTEGER NOT NULL CHECK(created_at>0),\n next_position INTEGER NOT NULL CHECK(next_position>0),\n created_seq INTEGER NOT NULL UNIQUE CHECK(created_seq>0),\n workspace_digest BLOB NOT NULL CHECK(length(workspace_digest)=32),\n workspace_key INTEGER NOT NULL,\n parent_ref TEXT REFERENCES session(session_ref),\n CHECK(workspace_key>0 AND workspace_key<=created_seq),\n CHECK(parent_ref IS NULL OR parent_ref<>session_ref)\n) STRICT",
            "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key) SELECT session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key FROM session_before_53",
            "DROP TABLE session_before_53",
            "CREATE INDEX session_workspace_list ON session(workspace_digest,created_seq)",
        },
        .mysql = &.{
            "ALTER TABLE session ADD COLUMN parent_ref VARCHAR(6),ADD FOREIGN KEY(parent_ref) REFERENCES session(session_ref),ADD CHECK(parent_ref IS NULL OR parent_ref<>session_ref)",
        },
    },
    // Schema 54: the stops an attached child owes (D38) and the endings
    // its parent is owed (D39), and independently loaded tools (T4a):
    // NULL loaded_tool_set_id keeps the full configured set.
    // Then (8b): each Store gets a random store_id. On MySQL,
    // store_owner and content_chunk are new; each content's payload moves
    // into chunks of content_chunk_bytes (chunk.i reaches 9999, past the
    // 8192 chunks of the largest content) before the column goes; each
    // leading partial index gets its generated first column; store_meta's
    // one CHECK and content's fourth are the ones replaced. session_parent
    // gets its plain twin first, since parent_ref's foreign key needs an
    // index that leads with it.
    .{
        .from = 53,
        .sqlite = &.{
            "CREATE TABLE session_stop_owed(\n child_ref TEXT NOT NULL REFERENCES session(session_ref),\n cause_ref TEXT NOT NULL REFERENCES session(session_ref),\n cause_position INTEGER NOT NULL CHECK(cause_position>0),\n settled INTEGER NOT NULL CHECK(settled BETWEEN 0 AND 1),\n PRIMARY KEY(child_ref,cause_ref,cause_position)\n) STRICT, WITHOUT ROWID",
            "CREATE INDEX session_stop_open ON session_stop_owed(settled,child_ref)",
            "ALTER TABLE session RENAME TO session_before_54",
            "CREATE TABLE session(\n session_ref TEXT PRIMARY KEY NOT NULL CHECK(length(CAST(session_ref AS BLOB))=6 AND (session_ref NOT GLOB '*[^0123456789abcdefghjkmnpqrstvwxyz]*' AND length(session_ref)=length(CAST(session_ref AS BLOB)))),\n workspace TEXT NOT NULL CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096),\n provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND (provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))),\n codec TEXT NOT NULL CHECK(length(CAST(codec AS BLOB)) BETWEEN 3 AND 40),\n codec_options BLOB CHECK(codec_options IS NULL OR length(codec_options) BETWEEN 1 AND 512),\n prefix_seal BLOB CHECK(prefix_seal IS NULL OR length(prefix_seal)=56),\n model TEXT NOT NULL CHECK(length(CAST(model AS BLOB)) BETWEEN 1 AND 256),\n instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),\n loaded_tool_set_id INTEGER REFERENCES tool_set(tool_set_id),\n permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),\n output_schema_content_id INTEGER REFERENCES content(content_id),\n revision INTEGER NOT NULL CHECK(revision>0),\n compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),\n output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),\n reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),\n label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),\n created_at INTEGER NOT NULL CHECK(created_at>0),\n next_position INTEGER NOT NULL CHECK(next_position>0),\n created_seq INTEGER NOT NULL UNIQUE CHECK(created_seq>0),\n workspace_digest BLOB NOT NULL CHECK(length(workspace_digest)=32),\n workspace_key INTEGER NOT NULL,\n parent_ref TEXT REFERENCES session(session_ref),\n CHECK(workspace_key>0 AND workspace_key<=created_seq),\n CHECK(parent_ref IS NULL OR parent_ref<>session_ref)\n) STRICT",
            "INSERT INTO session(session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key,parent_ref) SELECT session_ref,workspace,provider,codec,codec_options,prefix_seal,model,instructions_content_id,tool_set_id,permission_mode,output_schema_content_id,revision,compaction_trigger,output_reservation,reasoning_effort,label,created_at,next_position,created_seq,workspace_digest,workspace_key,parent_ref FROM session_before_54",
            "DROP TABLE session_before_54",
            "CREATE INDEX session_workspace_list ON session(workspace_digest,created_seq)",
            "CREATE INDEX session_parent ON session(parent_ref) WHERE parent_ref IS NOT NULL",
            "ALTER TABLE session_revision RENAME TO session_revision_before_54",
            "CREATE TABLE session_revision(\n session_ref TEXT NOT NULL REFERENCES session(session_ref),\n revision INTEGER NOT NULL CHECK(revision>0),\n command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key),\n workspace TEXT NOT NULL,\n provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND (provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))),\n model TEXT NOT NULL,\n instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),\n instructions_updated INTEGER NOT NULL CHECK(instructions_updated IN (0,1)),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),\n loaded_tool_set_id INTEGER REFERENCES tool_set(tool_set_id),\n permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),\n output_schema_content_id INTEGER REFERENCES content(content_id),\n compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),\n output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),\n reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),\n label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),\n PRIMARY KEY(session_ref,revision)\n) STRICT, WITHOUT ROWID",
            "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label) SELECT session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label FROM session_revision_before_54",
            "DROP TABLE session_revision_before_54",
            "CREATE INDEX session_revision_instructions ON session_revision(session_ref,instructions_content_id)",
            "CREATE INDEX session_revision_output_schema ON session_revision(session_ref,output_schema_content_id)",
            "ALTER TABLE session_change RENAME TO session_change_before_54",
            "CREATE TABLE session_change(\n session_ref TEXT NOT NULL REFERENCES session(session_ref),\n position INTEGER NOT NULL CHECK(position>0),\n ordinal INTEGER NOT NULL CHECK(ordinal>=0),\n revision INTEGER NOT NULL CHECK(revision>1),\n field TEXT NOT NULL CHECK((field='provider' OR field='model' OR field='instructions' OR field='tools' OR field='loaded_tools' OR field='permission_mode' OR field='output_schema' OR field='compaction_trigger' OR field='output_reservation' OR field='reasoning_effort' OR field='label')),\n changed_at INTEGER NOT NULL CHECK(changed_at>0),\n PRIMARY KEY(session_ref,position,ordinal),\n UNIQUE(session_ref,revision,field),\n FOREIGN KEY(session_ref,revision) REFERENCES session_revision(session_ref,revision)\n) STRICT, WITHOUT ROWID",
            "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at) SELECT session_ref,position,ordinal,revision,field,changed_at FROM session_change_before_54",
            "DROP TABLE session_change_before_54",
            "ALTER TABLE store_meta RENAME TO store_meta_before_54",
            "CREATE TABLE store_meta(\n meta_key TEXT PRIMARY KEY NOT NULL CHECK((meta_key='wire_version' OR meta_key='store_selector' OR meta_key='format' OR meta_key='store_id')),\n meta_value TEXT NOT NULL\n) STRICT",
            "INSERT INTO store_meta(meta_key,meta_value) SELECT meta_key,meta_value FROM store_meta_before_54",
            "DROP TABLE store_meta_before_54",
            "INSERT INTO store_meta(meta_key,meta_value) VALUES('store_id',lower(hex(randomblob(16))))",
            "CREATE TABLE session_ending_owed(\n turn_id INTEGER PRIMARY KEY NOT NULL REFERENCES turn(turn_id) CHECK(turn_id>0),\n delivered INTEGER NOT NULL CHECK(delivered BETWEEN 0 AND 1)\n) STRICT, WITHOUT ROWID",
            "CREATE INDEX session_ending_open ON session_ending_owed(delivered,turn_id)",
            "CREATE TABLE session_forward(\n forward_id INTEGER PRIMARY KEY NOT NULL CHECK(forward_id>0),\n target_ref TEXT NOT NULL REFERENCES session(session_ref),\n child_ref TEXT NOT NULL REFERENCES session(session_ref),\n kind INTEGER NOT NULL CHECK(kind BETWEEN 1 AND 2),\n source_id INTEGER NOT NULL CHECK(source_id>0),\n position INTEGER CHECK(position IS NULL OR position>0),\n ordinal INTEGER NOT NULL CHECK(ordinal=0),\n delivered_at INTEGER CHECK(delivered_at IS NULL OR delivered_at>0),\n UNIQUE(target_ref,kind,source_id),\n CHECK((position IS NULL)=(delivered_at IS NULL)),\n CHECK(target_ref<>child_ref)\n) STRICT",
            "CREATE INDEX session_forward_open ON session_forward(forward_id) WHERE position IS NULL",
            "CREATE INDEX session_forward_feed ON session_forward(target_ref,position)",
        },
        .mysql = &.{
            "CREATE TABLE session_stop_owed(\n child_ref VARCHAR(6) NOT NULL,\n cause_ref VARCHAR(6) NOT NULL,\n cause_position BIGINT NOT NULL,\n settled BIGINT NOT NULL,\n PRIMARY KEY(child_ref,cause_ref,cause_position),\n FOREIGN KEY(child_ref) REFERENCES session(session_ref),\n FOREIGN KEY(cause_ref) REFERENCES session(session_ref),\n CHECK(cause_position>0),\n CHECK(settled BETWEEN 0 AND 1)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "CREATE INDEX session_stop_open ON session_stop_owed(settled,child_ref)",
            "CREATE INDEX session_parent ON session(parent_ref)",
            "ALTER TABLE session ADD COLUMN loaded_tool_set_id BIGINT AFTER tool_set_id,ADD FOREIGN KEY(loaded_tool_set_id) REFERENCES tool_set(tool_set_id)",
            "ALTER TABLE session_revision ADD COLUMN loaded_tool_set_id BIGINT AFTER tool_set_id,ADD FOREIGN KEY(loaded_tool_set_id) REFERENCES tool_set(tool_set_id)",
            "ALTER TABLE session_change DROP CHECK session_change_chk_4,ADD CHECK((field='provider' OR field='model' OR field='instructions' OR field='tools' OR field='loaded_tools' OR field='permission_mode' OR field='output_schema' OR field='compaction_trigger' OR field='output_reservation' OR field='reasoning_effort' OR field='label'))",
            "ALTER TABLE store_meta DROP CHECK store_meta_chk_1, ADD CHECK((meta_key='wire_version' OR meta_key='store_selector' OR meta_key='format' OR meta_key='store_id'))",
            "CREATE TABLE store_owner(\n owner_key BIGINT NOT NULL,\n epoch BIGINT NOT NULL,\n commit_seq BIGINT NOT NULL,\n PRIMARY KEY(owner_key),\n CHECK(owner_key=1),\n CHECK(epoch>=0),\n CHECK(commit_seq>=0)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "CREATE TABLE content_chunk(\n content_id BIGINT NOT NULL,\n chunk_index BIGINT NOT NULL,\n bytes LONGBLOB NOT NULL,\n PRIMARY KEY(content_id,chunk_index),\n FOREIGN KEY(content_id) REFERENCES content(content_id),\n CHECK(chunk_index>=0),\n CHECK(length(bytes) BETWEEN 1 AND 131072)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "INSERT INTO content_chunk(content_id,chunk_index,bytes) WITH digit(d) AS (SELECT 0 UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9), chunk(i) AS (SELECT a.d+10*b.d+100*c.d+1000*e.d FROM digit a CROSS JOIN digit b CROSS JOIN digit c CROSS JOIN digit e) SELECT content.content_id,chunk.i,SUBSTRING(content.payload,chunk.i*131072+1,131072) FROM content JOIN chunk ON chunk.i*131072<content.byte_length",
            "ALTER TABLE content DROP CHECK content_chk_4, DROP COLUMN payload",
            "ALTER TABLE message_admission ADD COLUMN message_admission_pending_lead BIGINT GENERATED ALWAYS AS (CASE WHEN turn_id IS NULL THEN admission_id END) STORED, ADD COLUMN message_admission_session_pending_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN turn_id IS NULL THEN session_ref END) STORED, ADD COLUMN message_admission_person_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN sender_session_ref IS NULL THEN session_ref END) STORED, ADD COLUMN message_admission_unpositioned_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN admission_position IS NULL THEN session_ref END) STORED, DROP INDEX message_admission_pending, ADD INDEX message_admission_pending(message_admission_pending_lead,session_ref), DROP INDEX message_admission_session_pending, ADD INDEX message_admission_session_pending(message_admission_session_pending_lead,admission_id), DROP INDEX message_admission_person, ADD INDEX message_admission_person(message_admission_person_lead,admission_position), DROP INDEX message_admission_unpositioned, ADD INDEX message_admission_unpositioned(message_admission_unpositioned_lead)",
            "ALTER TABLE turn ADD COLUMN turn_tool_continuation_lead BIGINT GENERATED ALWAYS AS (CASE WHEN outcome_code IS NULL AND continuation_operation_id=operation_id THEN operation_id END) STORED, ADD COLUMN turn_unpositioned_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN (outcome_code IS NULL)!=(outcome_position IS NULL) THEN session_ref END) STORED, DROP INDEX turn_tool_continuation, ADD INDEX turn_tool_continuation(turn_tool_continuation_lead), DROP INDEX turn_unpositioned, ADD INDEX turn_unpositioned(turn_unpositioned_lead)",
            "ALTER TABLE session_stop ADD COLUMN session_stop_unpositioned_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN position IS NULL THEN session_ref END) STORED, DROP INDEX session_stop_unpositioned, ADD INDEX session_stop_unpositioned(session_stop_unpositioned_lead)",
            "ALTER TABLE model_operation ADD COLUMN model_operation_retry_due_lead BIGINT GENERATED ALWAYS AS (CASE WHEN resolution_code IS NULL AND attempt_ordinal<4 THEN retry_due_at_ms END) STORED, ADD COLUMN model_operation_retry_exhausted_lead BIGINT GENERATED ALWAYS AS (CASE WHEN resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal=4 THEN operation_id END) STORED, ADD COLUMN model_operation_context_history_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN (resolution_code='answer' OR resolution_code='compacted' OR resolution_code='tool_proposals') THEN session_ref END) STORED, ADD COLUMN model_operation_compaction_bases_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN purpose=1 AND resolution_code='compacted' THEN session_ref END) STORED, DROP INDEX model_operation_retry_due, ADD INDEX model_operation_retry_due(model_operation_retry_due_lead,operation_id), DROP INDEX model_operation_retry_exhausted, ADD INDEX model_operation_retry_exhausted(model_operation_retry_exhausted_lead), DROP INDEX model_operation_context_history, ADD INDEX model_operation_context_history(model_operation_context_history_lead,admission_position), DROP INDEX model_operation_compaction_bases, ADD INDEX model_operation_compaction_bases(model_operation_compaction_bases_lead,admission_position)",
            "ALTER TABLE model_output_item ADD COLUMN model_output_call_history_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN item_kind=3 THEN session_ref END) STORED, ADD COLUMN model_output_hosted_history_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN item_kind=5 THEN session_ref END) STORED, ADD COLUMN model_output_compaction_history_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN item_kind=4 THEN session_ref END) STORED, ADD COLUMN model_output_compaction_anchor_lead BIGINT GENERATED ALWAYS AS (CASE WHEN item_kind=4 THEN operation_id END) STORED, DROP INDEX model_output_call_history, ADD INDEX model_output_call_history(model_output_call_history_lead,session_position), DROP INDEX model_output_hosted_history, ADD INDEX model_output_hosted_history(model_output_hosted_history_lead,session_position), DROP INDEX model_output_compaction_history, ADD INDEX model_output_compaction_history(model_output_compaction_history_lead,session_position), DROP INDEX model_output_compaction_anchor, ADD INDEX model_output_compaction_anchor(model_output_compaction_anchor_lead,item_ordinal)",
            "ALTER TABLE model_tool_call ADD COLUMN model_tool_call_session_results_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN acceptance_position IS NOT NULL THEN session_ref END) STORED, ADD COLUMN model_tool_call_acceptance_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN acceptance_position IS NOT NULL THEN session_ref END) STORED, DROP INDEX model_tool_call_session_results, ADD INDEX model_tool_call_session_results(model_tool_call_session_results_lead,operation_id,acceptance_position), DROP INDEX model_tool_call_acceptance, ADD INDEX model_tool_call_acceptance(model_tool_call_acceptance_lead,acceptance_position)",
            "ALTER TABLE action_operation ADD COLUMN action_operation_session_results_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN acceptance_position IS NOT NULL THEN session_ref END) STORED, ADD COLUMN action_operation_approval_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN approval_position IS NOT NULL THEN session_ref END) STORED, ADD COLUMN action_operation_executable_lead BIGINT GENERATED ALWAYS AS (CASE WHEN authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0 THEN action_id END) STORED, ADD COLUMN action_operation_unresolved_attempt_lead BIGINT GENERATED ALWAYS AS (CASE WHEN resolution_code IS NULL AND attempt_ordinal=1 THEN action_id END) STORED, DROP INDEX action_operation_session_results, ADD INDEX action_operation_session_results(action_operation_session_results_lead,parent_operation_id,acceptance_position), DROP INDEX action_operation_approval, ADD INDEX action_operation_approval(action_operation_approval_lead,approval_position), DROP INDEX action_operation_executable, ADD INDEX action_operation_executable(action_operation_executable_lead), DROP INDEX action_operation_unresolved_attempt, ADD INDEX action_operation_unresolved_attempt(action_operation_unresolved_attempt_lead)",
            "ALTER TABLE session ADD COLUMN session_parent_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN parent_ref IS NOT NULL THEN parent_ref END) STORED, ADD INDEX parent_ref(parent_ref)",
            "ALTER TABLE session DROP INDEX session_parent, ADD INDEX session_parent(session_parent_lead)",
            "CREATE TABLE session_ending_owed(\n turn_id BIGINT NOT NULL,\n delivered BIGINT NOT NULL,\n PRIMARY KEY(turn_id),\n FOREIGN KEY(turn_id) REFERENCES turn(turn_id),\n CHECK(turn_id>0),\n CHECK(delivered BETWEEN 0 AND 1)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "CREATE INDEX session_ending_open ON session_ending_owed(delivered,turn_id)",
            "CREATE TABLE session_forward(\n forward_id BIGINT NOT NULL,\n target_ref VARCHAR(6) NOT NULL,\n child_ref VARCHAR(6) NOT NULL,\n kind BIGINT NOT NULL,\n source_id BIGINT NOT NULL,\n position BIGINT,\n ordinal BIGINT NOT NULL,\n delivered_at BIGINT,\n session_forward_open_lead BIGINT GENERATED ALWAYS AS (CASE WHEN position IS NULL THEN forward_id END) STORED,\n PRIMARY KEY(forward_id),\n UNIQUE(target_ref,kind,source_id),\n FOREIGN KEY(target_ref) REFERENCES session(session_ref),\n FOREIGN KEY(child_ref) REFERENCES session(session_ref),\n CHECK(forward_id>0),\n CHECK(kind BETWEEN 1 AND 2),\n CHECK(source_id>0),\n CHECK(position IS NULL OR position>0),\n CHECK(ordinal=0),\n CHECK(delivered_at IS NULL OR delivered_at>0),\n CHECK((position IS NULL)=(delivered_at IS NULL)),\n CHECK(target_ref<>child_ref)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "CREATE INDEX session_forward_open ON session_forward(session_forward_open_lead)",
            "CREATE INDEX session_forward_feed ON session_forward(target_ref,position)",
        },
    },
    // Schema 55 (C2a, D226): saved model facts and their publication source.
    // Both tables start empty until the first successful catalog refresh.
    .{
        .from = 54,
        .sqlite = &.{
            "CREATE TABLE model_fact(\n model_id TEXT PRIMARY KEY NOT NULL CHECK(length(CAST(model_id AS BLOB)) BETWEEN 1 AND 256),\n context_window INTEGER,\n efforts INTEGER NOT NULL CHECK(efforts BETWEEN 0 AND 63),\n openai_listed INTEGER NOT NULL CHECK(openai_listed IN (0,1)),\n generation INTEGER NOT NULL\n) STRICT",
            "CREATE TABLE model_catalog_source(\n slot INTEGER PRIMARY KEY NOT NULL CHECK(slot=1),\n etag TEXT CHECK(etag IS NULL OR length(CAST(etag AS BLOB))<=512),\n generation INTEGER NOT NULL,\n fetched_at INTEGER NOT NULL\n) STRICT",
        },
        .mysql = &.{
            "CREATE TABLE model_fact(\n model_id VARCHAR(256) NOT NULL,\n context_window BIGINT,\n efforts BIGINT NOT NULL,\n openai_listed TINYINT NOT NULL,\n generation BIGINT NOT NULL,\n PRIMARY KEY(model_id),\n CHECK(OCTET_LENGTH(model_id) BETWEEN 1 AND 256),\n CHECK(efforts BETWEEN 0 AND 63),\n CHECK(openai_listed IN (0,1))\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "CREATE TABLE model_catalog_source(\n slot BIGINT NOT NULL,\n etag TEXT,\n generation BIGINT NOT NULL,\n fetched_at BIGINT NOT NULL,\n PRIMARY KEY(slot),\n CHECK(slot=1),\n CHECK(etag IS NULL OR OCTET_LENGTH(etag)<=512)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
        },
    },
    // Schema 56: bounded outcome-unknown Message recovery and wire 9.
    .{
        .from = 55,
        .sqlite = &.{
            "CREATE INDEX action_operation_indeterminate ON action_operation(session_ref,parent_operation_id,call_ordinal) WHERE resolution_code='indeterminate'",
            "UPDATE store_meta SET meta_value='9' WHERE meta_key='wire_version' AND meta_value='8'",
        },
        .mysql = &.{
            "ALTER TABLE action_operation ADD COLUMN action_operation_indeterminate_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN resolution_code='indeterminate' THEN session_ref END) STORED, ADD INDEX action_operation_indeterminate(action_operation_indeterminate_lead,parent_operation_id,call_ordinal)",
            "UPDATE store_meta SET meta_value='9' WHERE meta_key='wire_version' AND meta_value='8'",
        },
    },
    // Schema 57: archive intent retains its original stop, and Commands
    // retain their requested archive value for replay and observation.
    .{
        .from = 56,
        .sqlite = &.{
            "ALTER TABLE core_command RENAME TO core_command_before_57",
            "CREATE TABLE core_command(\n command_key TEXT NOT NULL UNIQUE CHECK(length(CAST(command_key AS BLOB))<=128),\n kind INTEGER NOT NULL CHECK(kind BETWEEN 1 AND 6),\n target TEXT NOT NULL CHECK(length(CAST(target AS BLOB))<=128),\n input_digest BLOB NOT NULL CHECK(length(input_digest)=32),\n primary_content_id INTEGER REFERENCES content(content_id),\n secondary_content_id INTEGER REFERENCES content(content_id),\n accepted INTEGER NOT NULL CHECK(accepted IN (0,1)),\n code TEXT NOT NULL CHECK(length(CAST(code AS BLOB))<=96),\n revision INTEGER NOT NULL CHECK(revision>=0),\n created INTEGER NOT NULL CHECK(created IN (0,1)),\n command_seq INTEGER PRIMARY KEY NOT NULL CHECK(command_seq>0)\n) STRICT",
            "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) SELECT command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq FROM core_command_before_57",
            "DROP TABLE core_command_before_57",
            "CREATE INDEX core_command_target_order ON core_command(target,kind,command_seq)",
            "ALTER TABLE session_stop RENAME TO session_stop_before_57",
            "CREATE TABLE session_stop(\n command_key TEXT PRIMARY KEY NOT NULL REFERENCES core_command(command_key),\n session_ref TEXT NOT NULL REFERENCES session(session_ref),\n selected_turn_id INTEGER REFERENCES turn(turn_id),\n position INTEGER CHECK(position>0),\n admission_cutoff INTEGER NOT NULL CHECK(admission_cutoff>=0),\n stopped_at INTEGER NOT NULL CHECK(stopped_at>0),\n parent_caused INTEGER NOT NULL DEFAULT 0 CHECK(parent_caused IN (0,1))\n) STRICT, WITHOUT ROWID",
            "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) SELECT command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,CASE WHEN command_key>='rui.core/stop/' AND command_key<'rui.core/stop0' THEN 1 ELSE 0 END FROM session_stop_before_57",
            "DROP TABLE session_stop_before_57",
            "CREATE INDEX session_stop_exclusion ON session_stop(session_ref,admission_cutoff,position)",
            "CREATE INDEX session_stop_unpositioned ON session_stop(session_ref) WHERE position IS NULL",
            "CREATE INDEX session_stop_position ON session_stop(session_ref,position)",
            "CREATE INDEX session_stop_turn ON session_stop(selected_turn_id)",
            "CREATE TABLE session_archive(\n session_ref TEXT PRIMARY KEY NOT NULL REFERENCES session(session_ref),\n command_key TEXT REFERENCES session_stop(command_key)\n) STRICT, WITHOUT ROWID",
            "CREATE TABLE session_archive_command(\n command_key TEXT PRIMARY KEY NOT NULL REFERENCES core_command(command_key),\n archived INTEGER NOT NULL CHECK(archived IN (0,1))\n) STRICT, WITHOUT ROWID",
            "ALTER TABLE session_ending_owed RENAME TO session_ending_owed_before_57",
            "CREATE TABLE session_ending_owed(\n turn_id INTEGER PRIMARY KEY NOT NULL REFERENCES turn(turn_id) CHECK(turn_id>0),\n delivered INTEGER NOT NULL CHECK(delivered BETWEEN 0 AND 1),\n suppress_message INTEGER NOT NULL DEFAULT 0 CHECK(suppress_message IN (0,1))\n) STRICT, WITHOUT ROWID",
            "INSERT INTO session_ending_owed(turn_id,delivered,suppress_message) SELECT turn_id,delivered,0 FROM session_ending_owed_before_57",
            "DROP TABLE session_ending_owed_before_57",
            "CREATE INDEX session_ending_open ON session_ending_owed(delivered,turn_id)",
        },
        .mysql = &.{
            "ALTER TABLE core_command DROP CHECK core_command_chk_2, ADD CHECK(kind BETWEEN 1 AND 6)",
            "CREATE TABLE session_archive(\n session_ref VARCHAR(6) NOT NULL,\n command_key VARCHAR(128),\n PRIMARY KEY(session_ref),\n FOREIGN KEY(session_ref) REFERENCES session(session_ref),\n FOREIGN KEY(command_key) REFERENCES session_stop(command_key)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "CREATE TABLE session_archive_command(\n command_key VARCHAR(128) NOT NULL,\n archived TINYINT NOT NULL,\n PRIMARY KEY(command_key),\n FOREIGN KEY(command_key) REFERENCES core_command(command_key),\n CHECK(archived IN (0,1))\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "ALTER TABLE session_stop ADD COLUMN parent_caused TINYINT NOT NULL DEFAULT 0 AFTER stopped_at, ADD CHECK(parent_caused IN (0,1))",
            "UPDATE session_stop SET parent_caused=1 WHERE command_key>='rui.core/stop/' AND command_key<'rui.core/stop0'",
            "ALTER TABLE session_ending_owed ADD COLUMN suppress_message TINYINT NOT NULL DEFAULT 0, ADD CHECK(suppress_message IN (0,1))",
        },
    },
    // Schema 58: failed-send targets become nullable on wire 10. Saved
    // Commands and sender refusals keep their original identity and position.
    .{
        .from = 57,
        .sqlite = &.{
            "UPDATE store_meta SET meta_value='10' WHERE meta_key='wire_version' AND meta_value='9'",
        },
        .mysql = &.{
            "UPDATE store_meta SET meta_value='10' WHERE meta_key='wire_version' AND meta_value='9'",
        },
    },
    .{
        // Schema 59: append-only skill catalogs on unreleased native wire 10.
        .from = 58,
        .sqlite = &.{
            "CREATE TABLE session_skill_catalog(\n session_ref TEXT NOT NULL REFERENCES session(session_ref),\n position INTEGER NOT NULL CHECK(position>=0),\n catalog_content_id INTEGER NOT NULL REFERENCES content(content_id),\n PRIMARY KEY(session_ref,position)\n) STRICT, WITHOUT ROWID",
            "ALTER TABLE conversation_entry RENAME TO conversation_entry_58",
            "CREATE TABLE conversation_entry(\n session_ref TEXT NOT NULL,\n entry_ordinal INTEGER NOT NULL CHECK(entry_ordinal>0),\n session_position INTEGER NOT NULL CHECK(session_position>0),\n entry_kind INTEGER NOT NULL CHECK(entry_kind BETWEEN 1 AND 3),\n turn_id INTEGER REFERENCES turn(turn_id),\n source_admission_id INTEGER UNIQUE REFERENCES message_admission(admission_id),\n source_revision INTEGER,\n source_catalog_position INTEGER,\n source_operation_id INTEGER REFERENCES model_operation(operation_id),\n source_item_ordinal INTEGER CHECK(source_item_ordinal IS NULL OR source_item_ordinal>=0),\n content_id INTEGER NOT NULL REFERENCES content(content_id),\n recorded_at INTEGER NOT NULL CHECK(recorded_at>0),\n PRIMARY KEY(session_ref,entry_ordinal),\n UNIQUE(session_ref,session_position),\n UNIQUE(session_ref,source_revision),\n UNIQUE(session_ref,source_catalog_position),\n FOREIGN KEY(session_ref,source_revision) REFERENCES session_revision(session_ref,revision),\n FOREIGN KEY(session_ref,source_catalog_position) REFERENCES session_skill_catalog(session_ref,position),\n FOREIGN KEY(source_operation_id,source_item_ordinal) REFERENCES model_output_item(operation_id,item_ordinal),\n CHECK((entry_kind=3)=(source_item_ordinal IS NOT NULL)),\n CHECK((turn_id IS NULL)=(source_catalog_position IS NOT NULL)),\n CHECK(source_catalog_position IS NULL OR source_catalog_position=session_position),\n CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL) OR (entry_kind=2 AND source_admission_id IS NULL AND ((source_revision IS NOT NULL AND source_catalog_position IS NULL) OR (source_revision IS NULL AND source_catalog_position IS NOT NULL)) AND source_operation_id IS NULL) OR (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NOT NULL))\n) STRICT, WITHOUT ROWID",
            "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,source_item_ordinal,content_id,recorded_at) SELECT session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_operation_id,source_item_ordinal,content_id,recorded_at FROM conversation_entry_58",
            "DROP TABLE conversation_entry_58",
            "CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position)",
        },
        .mysql = &.{
            "CREATE TABLE session_skill_catalog(\n session_ref VARCHAR(6) NOT NULL,\n position BIGINT NOT NULL,\n catalog_content_id BIGINT NOT NULL,\n PRIMARY KEY(session_ref,position),\n FOREIGN KEY(session_ref) REFERENCES session(session_ref),\n FOREIGN KEY(catalog_content_id) REFERENCES content(content_id),\n CHECK(position>=0)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "ALTER TABLE conversation_entry MODIFY turn_id BIGINT NULL, ADD COLUMN source_catalog_position BIGINT AFTER source_revision, ADD UNIQUE(session_ref,source_catalog_position), ADD FOREIGN KEY(session_ref,source_catalog_position) REFERENCES session_skill_catalog(session_ref,position), DROP CHECK conversation_entry_chk_7, ADD CHECK((turn_id IS NULL)=(source_catalog_position IS NOT NULL)), ADD CHECK(source_catalog_position IS NULL OR source_catalog_position=session_position), ADD CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL) OR (entry_kind=2 AND source_admission_id IS NULL AND ((source_revision IS NOT NULL AND source_catalog_position IS NULL) OR (source_revision IS NULL AND source_catalog_position IS NOT NULL)) AND source_operation_id IS NULL) OR (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NOT NULL))",
        },
    },
    // Schema 60 (wire 11): a Message's `/name` words bind skills after
    // send. message_skill keeps each bound skill's body, and a skill entry
    // (kind 4) projects it right after its Message's entry. MySQL rebuilds
    // conversation_entry too, in a fresh Store's order, so no CHECK is
    // dropped by a name MySQL generated.
    .{
        .from = 59,
        .sqlite = &.{
            "CREATE TABLE message_skill(\n admission_id INTEGER NOT NULL REFERENCES message_admission(admission_id),\n position INTEGER NOT NULL CHECK(position>0),\n name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 64 AND (name NOT GLOB '*[^a-z0-9-]*' AND length(name)=length(CAST(name AS BLOB)))),\n content_id INTEGER NOT NULL REFERENCES content(content_id),\n PRIMARY KEY(admission_id,position)\n) STRICT, WITHOUT ROWID",
            "ALTER TABLE conversation_entry RENAME TO conversation_entry_59",
            "CREATE TABLE conversation_entry(\n session_ref TEXT NOT NULL,\n entry_ordinal INTEGER NOT NULL CHECK(entry_ordinal>0),\n session_position INTEGER NOT NULL CHECK(session_position>0),\n entry_kind INTEGER NOT NULL CHECK(entry_kind BETWEEN 1 AND 4),\n turn_id INTEGER REFERENCES turn(turn_id),\n source_admission_id INTEGER UNIQUE REFERENCES message_admission(admission_id),\n source_revision INTEGER,\n source_catalog_position INTEGER,\n source_skill_admission_id INTEGER,\n source_skill_position INTEGER,\n source_operation_id INTEGER REFERENCES model_operation(operation_id),\n source_item_ordinal INTEGER CHECK(source_item_ordinal IS NULL OR source_item_ordinal>=0),\n content_id INTEGER NOT NULL REFERENCES content(content_id),\n recorded_at INTEGER NOT NULL CHECK(recorded_at>0),\n PRIMARY KEY(session_ref,entry_ordinal),\n UNIQUE(session_ref,session_position),\n UNIQUE(session_ref,source_revision),\n UNIQUE(session_ref,source_catalog_position),\n UNIQUE(source_skill_admission_id,source_skill_position),\n FOREIGN KEY(session_ref,source_revision) REFERENCES session_revision(session_ref,revision),\n FOREIGN KEY(session_ref,source_catalog_position) REFERENCES session_skill_catalog(session_ref,position),\n FOREIGN KEY(source_skill_admission_id,source_skill_position) REFERENCES message_skill(admission_id,position),\n FOREIGN KEY(source_operation_id,source_item_ordinal) REFERENCES model_output_item(operation_id,item_ordinal),\n CHECK((entry_kind=3)=(source_item_ordinal IS NOT NULL)),\n CHECK((turn_id IS NULL)=(source_catalog_position IS NOT NULL)),\n CHECK(source_catalog_position IS NULL OR source_catalog_position=session_position),\n CHECK((source_skill_admission_id IS NULL)=(source_skill_position IS NULL)),\n CHECK((entry_kind=4)=(source_skill_position IS NOT NULL)),\n CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL) OR (entry_kind=2 AND source_admission_id IS NULL AND ((source_revision IS NOT NULL AND source_catalog_position IS NULL) OR (source_revision IS NULL AND source_catalog_position IS NOT NULL)) AND source_operation_id IS NULL) OR (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NOT NULL) OR (entry_kind=4 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL))\n) STRICT, WITHOUT ROWID",
            "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_operation_id,source_item_ordinal,content_id,recorded_at) SELECT session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_operation_id,source_item_ordinal,content_id,recorded_at FROM conversation_entry_59",
            "DROP TABLE conversation_entry_59",
            "CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position)",
            "UPDATE store_meta SET meta_value='11' WHERE meta_key='wire_version' AND meta_value='10'",
        },
        .mysql = &.{
            "CREATE TABLE message_skill(\n admission_id BIGINT NOT NULL,\n position BIGINT NOT NULL,\n name TEXT NOT NULL,\n content_id BIGINT NOT NULL,\n PRIMARY KEY(admission_id,position),\n FOREIGN KEY(admission_id) REFERENCES message_admission(admission_id),\n FOREIGN KEY(content_id) REFERENCES content(content_id),\n CHECK(position>0),\n CHECK(OCTET_LENGTH(name) BETWEEN 1 AND 64 AND (NOT REGEXP_LIKE(name,'[^a-z0-9-]','c')))\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "CREATE TABLE conversation_entry_60(\n session_ref VARCHAR(6) NOT NULL,\n entry_ordinal BIGINT NOT NULL,\n session_position BIGINT NOT NULL,\n entry_kind BIGINT NOT NULL,\n turn_id BIGINT,\n source_admission_id BIGINT,\n source_revision BIGINT,\n source_catalog_position BIGINT,\n source_skill_admission_id BIGINT,\n source_skill_position BIGINT,\n source_operation_id BIGINT,\n source_item_ordinal BIGINT,\n content_id BIGINT NOT NULL,\n recorded_at BIGINT NOT NULL,\n PRIMARY KEY(session_ref,entry_ordinal),\n UNIQUE(source_admission_id),\n UNIQUE(session_ref,session_position),\n UNIQUE(session_ref,source_revision),\n UNIQUE(session_ref,source_catalog_position),\n UNIQUE(source_skill_admission_id,source_skill_position),\n FOREIGN KEY(turn_id) REFERENCES turn(turn_id),\n FOREIGN KEY(source_admission_id) REFERENCES message_admission(admission_id),\n FOREIGN KEY(source_operation_id) REFERENCES model_operation(operation_id),\n FOREIGN KEY(content_id) REFERENCES content(content_id),\n FOREIGN KEY(session_ref,source_revision) REFERENCES session_revision(session_ref,revision),\n FOREIGN KEY(session_ref,source_catalog_position) REFERENCES session_skill_catalog(session_ref,position),\n FOREIGN KEY(source_skill_admission_id,source_skill_position) REFERENCES message_skill(admission_id,position),\n CHECK(entry_ordinal>0),\n CHECK(session_position>0),\n CHECK(entry_kind BETWEEN 1 AND 4),\n CHECK(source_item_ordinal IS NULL OR source_item_ordinal>=0),\n CHECK(recorded_at>0),\n CHECK((entry_kind=3)=(source_item_ordinal IS NOT NULL)),\n CHECK((turn_id IS NULL)=(source_catalog_position IS NOT NULL)),\n CHECK(source_catalog_position IS NULL OR source_catalog_position=session_position),\n CHECK((source_skill_admission_id IS NULL)=(source_skill_position IS NULL)),\n CHECK((entry_kind=4)=(source_skill_position IS NOT NULL)),\n CHECK((entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL) OR (entry_kind=2 AND source_admission_id IS NULL AND ((source_revision IS NOT NULL AND source_catalog_position IS NULL) OR (source_revision IS NULL AND source_catalog_position IS NOT NULL)) AND source_operation_id IS NULL) OR (entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NOT NULL) OR (entry_kind=4 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL))\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "INSERT INTO conversation_entry_60(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_operation_id,source_item_ordinal,content_id,recorded_at) SELECT session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_operation_id,source_item_ordinal,content_id,recorded_at FROM conversation_entry",
            "DROP TABLE conversation_entry",
            "RENAME TABLE conversation_entry_60 TO conversation_entry",
            "CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position)",
            "ALTER TABLE conversation_entry ADD FOREIGN KEY(source_operation_id,source_item_ordinal) REFERENCES model_output_item(operation_id,item_ordinal)",
            "UPDATE store_meta SET meta_value='11' WHERE meta_key='wire_version' AND meta_value='10'",
        },
    },
    // Schema 61 (D227): call lines retain up to 200 decoded UTF-8 bytes.
    // Existing lines already fit; rebuilding only changes their byte bounds.
    .{
        .from = 60,
        .sqlite = &.{
            "ALTER TABLE model_output_item RENAME TO model_output_item_60",
            "CREATE TABLE model_output_item(\n operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),\n item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),\n session_ref TEXT NOT NULL,\n session_position INTEGER NOT NULL CHECK(session_position>0),\n item_kind INTEGER NOT NULL CHECK(item_kind BETWEEN 1 AND 5),\n message_content_id INTEGER REFERENCES content(content_id) CHECK((message_content_id IS NOT NULL)=(item_kind=2)),\n attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal>0),\n item_id_digest BLOB NOT NULL CHECK(length(item_id_digest)=32),\n replay_omits_reasoning_text INTEGER NOT NULL CHECK(replay_omits_reasoning_text IN (0,1) AND (replay_omits_reasoning_text=0 OR item_kind=1)),\n phase INTEGER NOT NULL DEFAULT 0 CHECK(phase IN (0,1,2) AND (phase=0 OR item_kind=2)),\n extras_content_id INTEGER NOT NULL REFERENCES content(content_id),\n part_count INTEGER NOT NULL CHECK(part_count>=0 AND (part_count=0 OR item_kind IN (1,2))),\n description TEXT CHECK(description IS NULL OR (length(CAST(description AS BLOB)) BETWEEN 1 AND 200 AND (description IS NOT NULL)=(item_kind=5))),\n call_failed INTEGER NOT NULL DEFAULT 0 CHECK(call_failed IN (0,1) AND (call_failed=0 OR item_kind=5)),\n PRIMARY KEY(operation_id,item_ordinal),\n UNIQUE(session_ref,session_position),\n UNIQUE(operation_id,item_id_digest)\n) STRICT, WITHOUT ROWID",
            "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) SELECT operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed FROM model_output_item_60",
            "DROP TABLE model_output_item_60",
            "CREATE INDEX model_output_history ON model_output_item(session_ref,session_position)",
            "CREATE INDEX model_output_call_history ON model_output_item(session_ref,session_position) WHERE item_kind=3",
            "CREATE INDEX model_output_hosted_history ON model_output_item(session_ref,session_position) WHERE item_kind=5",
            "CREATE INDEX model_output_compaction_history ON model_output_item(session_ref,session_position) WHERE item_kind=4",
            "CREATE INDEX model_output_compaction_anchor ON model_output_item(operation_id,item_ordinal) WHERE item_kind=4",
            "ALTER TABLE model_tool_call RENAME TO model_tool_call_60",
            "CREATE TABLE model_tool_call(\n operation_id INTEGER NOT NULL REFERENCES model_operation(operation_id),\n session_ref TEXT NOT NULL,\n call_ordinal INTEGER NOT NULL CHECK(call_ordinal>=0),\n item_ordinal INTEGER NOT NULL CHECK(item_ordinal>=0),\n name_content_id INTEGER NOT NULL REFERENCES content(content_id),\n call_id_content_id INTEGER NOT NULL REFERENCES content(content_id),\n arguments_content_id INTEGER NOT NULL REFERENCES content(content_id),\n description TEXT CHECK(description IS NULL OR length(CAST(description AS BLOB)) BETWEEN 1 AND 200),\n field_metadata BLOB NOT NULL CHECK(length(field_metadata)=120),\n rejection_code TEXT CHECK(rejection_code IS NULL OR rejection_code IN ('unknown_tool','invalid_arguments')),\n rejection_content_id INTEGER REFERENCES content(content_id),\n acceptance_position INTEGER CHECK(acceptance_position IS NULL OR acceptance_position>0),\n action_kind INTEGER CHECK(action_kind IS NULL OR action_kind=1),\n PRIMARY KEY(operation_id,call_ordinal),\n UNIQUE(operation_id,item_ordinal),\n UNIQUE(operation_id,call_id_content_id),\n UNIQUE(operation_id,call_ordinal,action_kind),\n FOREIGN KEY(operation_id,session_ref) REFERENCES model_operation(operation_id,session_ref),\n CHECK((rejection_code IS NULL AND rejection_content_id IS NULL AND acceptance_position IS NULL AND (action_kind IS 1)) OR (rejection_code IS NOT NULL AND rejection_content_id IS NOT NULL AND acceptance_position IS NOT NULL AND action_kind IS NULL))\n) STRICT, WITHOUT ROWID",
            "INSERT INTO model_tool_call(operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,description,field_metadata,rejection_code,rejection_content_id,acceptance_position,action_kind) SELECT operation_id,session_ref,call_ordinal,item_ordinal,name_content_id,call_id_content_id,arguments_content_id,description,field_metadata,rejection_code,rejection_content_id,acceptance_position,action_kind FROM model_tool_call_60",
            "DROP TABLE model_tool_call_60",
            "CREATE INDEX model_tool_call_session_order ON model_tool_call(session_ref,operation_id,call_ordinal)",
            "CREATE INDEX model_tool_call_session_results ON model_tool_call(session_ref,operation_id,acceptance_position) WHERE acceptance_position IS NOT NULL",
            "CREATE INDEX model_tool_call_acceptance ON model_tool_call(session_ref,acceptance_position) WHERE acceptance_position IS NOT NULL",
        },
        .mysql = &.{
            "ALTER TABLE model_output_item DROP CHECK model_output_item_chk_10, ADD CHECK(description IS NULL OR (OCTET_LENGTH(description) BETWEEN 1 AND 200 AND (description IS NOT NULL)=(item_kind=5)))",
            "ALTER TABLE model_tool_call DROP CHECK model_tool_call_chk_3, ADD CHECK(description IS NULL OR OCTET_LENGTH(description) BETWEEN 1 AND 200)",
        },
    },
    // Schema 62 (D184): the frozen MCP ordering hint is record identity.
    // Existing records remain read_only=0 with their original digests.
    // MySQL's original CHECK names run through 5 after the step to 52;
    // append the read_only CHECK as 6, leaving existing names untouched.
    .{
        .from = 61,
        .sqlite = &.{
            "ALTER TABLE tool_record RENAME TO tool_record_61",
            "CREATE TABLE tool_record(\n tool_record_id INTEGER PRIMARY KEY NOT NULL CHECK(tool_record_id>0),\n name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 64 AND (name NOT GLOB '*[^A-Za-z0-9_-]*' AND length(name)=length(CAST(name AS BLOB)))),\n owner TEXT NOT NULL CHECK((owner='rui' OR owner='provider' OR owner='mcp')),\n server TEXT NOT NULL CHECK(length(CAST(server AS BLOB))<=64 AND (server NOT GLOB '*[^A-Za-z0-9_-]*' AND length(server)=length(CAST(server AS BLOB))) AND (owner='mcp' AND length(CAST(server AS BLOB))>0 OR owner<>'mcp' AND length(CAST(server AS BLOB))=0)),\n read_only INTEGER NOT NULL DEFAULT 0 CHECK(read_only IN (0,1) AND (read_only=0 OR owner='mcp')),\n description_content_id INTEGER NOT NULL REFERENCES content(content_id),\n input_schema_content_id INTEGER NOT NULL REFERENCES content(content_id),\n UNIQUE(name,owner,server,read_only,description_content_id,input_schema_content_id)\n) STRICT",
            "INSERT INTO tool_record(tool_record_id,name,owner,server,read_only,description_content_id,input_schema_content_id) SELECT tool_record_id,name,owner,server,0,description_content_id,input_schema_content_id FROM tool_record_61",
            "DROP TABLE tool_record_61",
        },
        .mysql = &.{
            "ALTER TABLE tool_record ADD COLUMN read_only TINYINT NOT NULL DEFAULT 0 AFTER server",
            "ALTER TABLE tool_record DROP INDEX name, ADD UNIQUE(name,owner,server,read_only,description_content_id,input_schema_content_id)",
            "ALTER TABLE tool_record ADD CHECK(read_only IN (0,1) AND (read_only=0 OR owner='mcp'))",
        },
    },
    // Schema 63: the Store keeps the four usage counts, not the provider's
    // raw usage report. Reports no other row shares are deleted with it;
    // the file keeps the freed pages until it is vacuumed. MySQL's
    // usage_content_id foreign key is its third and the counts' CHECK its
    // 28th, as the baseline created them.
    .{
        .from = 62,
        .sqlite = &.{
            "ALTER TABLE model_operation RENAME TO model_operation_62",
            "CREATE TABLE model_operation(\n operation_id INTEGER PRIMARY KEY NOT NULL CHECK(operation_id>0),\n turn_id INTEGER NOT NULL REFERENCES turn(turn_id),\n session_ref TEXT NOT NULL,\n settings_revision INTEGER NOT NULL CHECK(settings_revision>0),\n input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),\n admission_position INTEGER NOT NULL CHECK(admission_position>0),\n purpose INTEGER NOT NULL DEFAULT 0 CHECK(purpose IN (0,1)),\n compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),\n output_reservation INTEGER NOT NULL CHECK(output_reservation>=0),\n reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),\n output_item_count INTEGER CHECK(output_item_count IS NULL OR output_item_count>=0),\n attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal BETWEEN 1 AND 4),\n auth_refresh_claimed INTEGER NOT NULL DEFAULT 0 CHECK(auth_refresh_claimed IN (0,1)),\n retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),\n last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),\n resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),\n resolution_content_id INTEGER REFERENCES content(content_id),\n response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),\n model_evidence BLOB CHECK(model_evidence IS NULL OR length(model_evidence) BETWEEN 7 AND 775),\n request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),\n usage_uncached_tokens INTEGER CHECK(usage_uncached_tokens IS NULL OR usage_uncached_tokens>=0),\n usage_cache_read_tokens INTEGER CHECK(usage_cache_read_tokens IS NULL OR usage_cache_read_tokens>=0),\n usage_cache_write_tokens INTEGER CHECK(usage_cache_write_tokens IS NULL OR usage_cache_write_tokens>=0),\n usage_output_tokens INTEGER CHECK(usage_output_tokens IS NULL OR usage_output_tokens>=0),\n interrupted_by_command_key TEXT REFERENCES core_command(command_key),\n attempt_at INTEGER CHECK(attempt_at IS NULL OR attempt_at>0),\n retry_scheduled_at INTEGER CHECK(retry_scheduled_at IS NULL OR retry_scheduled_at>0),\n resolved_at INTEGER CHECK(resolved_at IS NULL OR resolved_at>0),\n history_floor INTEGER CHECK(history_floor IS NULL OR history_floor>0),\n history_level INTEGER CHECK(history_level IS NULL OR history_level BETWEEN 1 AND 3),\n history_dropped INTEGER CHECK(history_dropped IS NULL OR history_dropped>=0),\n UNIQUE(operation_id,session_ref),\n FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),\n CHECK((usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR (usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND usage_output_tokens IS NOT NULL)),\n CHECK((resolution_code IS NULL AND retry_due_at_ms IS NOT NULL) OR (resolution_code IS NOT NULL AND retry_due_at_ms IS NULL)),\n CHECK((resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at IS NOT NULL AND retry_scheduled_at IS NULL AND resolved_at IS NULL) OR (resolution_code IS NULL AND retry_due_at_ms>0 AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND resolved_at IS NULL) OR (resolution_code IS NOT NULL AND attempt_at IS NULL AND retry_scheduled_at IS NULL AND resolved_at IS NOT NULL)),\n CHECK(((resolution_code IS 'interrupted') AND interrupted_by_command_key IS NOT NULL) OR (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL)),\n CHECK((history_floor IS NULL AND history_level IS NULL AND history_dropped IS NULL) OR (history_floor IS NOT NULL AND purpose=1 AND ((history_level IS NULL AND history_dropped IS NULL) OR (history_level IS NOT NULL AND history_dropped IS NOT NULL))))\n) STRICT",
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped) SELECT operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped FROM model_operation_62",
            "DELETE FROM content WHERE content_id IN (SELECT usage_content_id FROM model_operation_62) AND content_id NOT IN (SELECT description_content_id FROM tool_record WHERE description_content_id IS NOT NULL) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record WHERE input_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT instructions_content_id FROM session WHERE instructions_content_id IS NOT NULL) AND content_id NOT IN (SELECT output_schema_content_id FROM session WHERE output_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT primary_content_id FROM core_command WHERE primary_content_id IS NOT NULL) AND content_id NOT IN (SELECT secondary_content_id FROM core_command WHERE secondary_content_id IS NOT NULL) AND content_id NOT IN (SELECT instructions_content_id FROM session_revision WHERE instructions_content_id IS NOT NULL) AND content_id NOT IN (SELECT output_schema_content_id FROM session_revision WHERE output_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM message_admission WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT outcome_content_id FROM turn WHERE outcome_content_id IS NOT NULL) AND content_id NOT IN (SELECT resolution_content_id FROM model_operation WHERE resolution_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM message_skill WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT catalog_content_id FROM session_skill_catalog WHERE catalog_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM conversation_entry WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT message_content_id FROM model_output_item WHERE message_content_id IS NOT NULL) AND content_id NOT IN (SELECT extras_content_id FROM model_output_item WHERE extras_content_id IS NOT NULL) AND content_id NOT IN (SELECT text_content_id FROM model_output_part WHERE text_content_id IS NOT NULL) AND content_id NOT IN (SELECT extras_content_id FROM model_output_part WHERE extras_content_id IS NOT NULL) AND content_id NOT IN (SELECT name_content_id FROM model_tool_call WHERE name_content_id IS NOT NULL) AND content_id NOT IN (SELECT call_id_content_id FROM model_tool_call WHERE call_id_content_id IS NOT NULL) AND content_id NOT IN (SELECT arguments_content_id FROM model_tool_call WHERE arguments_content_id IS NOT NULL) AND content_id NOT IN (SELECT rejection_content_id FROM model_tool_call WHERE rejection_content_id IS NOT NULL) AND content_id NOT IN (SELECT resolution_content_id FROM action_operation WHERE resolution_content_id IS NOT NULL)",
            "DROP TABLE model_operation_62",
            "CREATE INDEX model_operation_retry_due ON model_operation(retry_due_at_ms,operation_id) WHERE resolution_code IS NULL AND attempt_ordinal<4",
            "CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal=4",
            "CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id)",
            "CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id)",
            "CREATE INDEX model_operation_admission ON model_operation(session_ref,admission_position)",
            "CREATE INDEX model_operation_context_history ON model_operation(session_ref,admission_position) WHERE (resolution_code='answer' OR resolution_code='compacted' OR resolution_code='tool_proposals')",
            "CREATE INDEX model_operation_compaction_bases ON model_operation(session_ref,admission_position) WHERE purpose=1 AND resolution_code='compacted'",
        },
        .mysql = &.{
            "ALTER TABLE model_operation DROP FOREIGN KEY model_operation_ibfk_3, DROP CHECK model_operation_chk_28, ADD CHECK((usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR (usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND usage_output_tokens IS NOT NULL))",
            "DELETE FROM content_chunk WHERE content_id IN (SELECT usage_content_id FROM model_operation) AND content_id NOT IN (SELECT description_content_id FROM tool_record WHERE description_content_id IS NOT NULL) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record WHERE input_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT instructions_content_id FROM session WHERE instructions_content_id IS NOT NULL) AND content_id NOT IN (SELECT output_schema_content_id FROM session WHERE output_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT primary_content_id FROM core_command WHERE primary_content_id IS NOT NULL) AND content_id NOT IN (SELECT secondary_content_id FROM core_command WHERE secondary_content_id IS NOT NULL) AND content_id NOT IN (SELECT instructions_content_id FROM session_revision WHERE instructions_content_id IS NOT NULL) AND content_id NOT IN (SELECT output_schema_content_id FROM session_revision WHERE output_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM message_admission WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT outcome_content_id FROM turn WHERE outcome_content_id IS NOT NULL) AND content_id NOT IN (SELECT resolution_content_id FROM model_operation WHERE resolution_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM message_skill WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT catalog_content_id FROM session_skill_catalog WHERE catalog_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM conversation_entry WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT message_content_id FROM model_output_item WHERE message_content_id IS NOT NULL) AND content_id NOT IN (SELECT extras_content_id FROM model_output_item WHERE extras_content_id IS NOT NULL) AND content_id NOT IN (SELECT text_content_id FROM model_output_part WHERE text_content_id IS NOT NULL) AND content_id NOT IN (SELECT extras_content_id FROM model_output_part WHERE extras_content_id IS NOT NULL) AND content_id NOT IN (SELECT name_content_id FROM model_tool_call WHERE name_content_id IS NOT NULL) AND content_id NOT IN (SELECT call_id_content_id FROM model_tool_call WHERE call_id_content_id IS NOT NULL) AND content_id NOT IN (SELECT arguments_content_id FROM model_tool_call WHERE arguments_content_id IS NOT NULL) AND content_id NOT IN (SELECT rejection_content_id FROM model_tool_call WHERE rejection_content_id IS NOT NULL) AND content_id NOT IN (SELECT resolution_content_id FROM action_operation WHERE resolution_content_id IS NOT NULL)",
            "DELETE FROM content WHERE content_id IN (SELECT usage_content_id FROM model_operation) AND content_id NOT IN (SELECT description_content_id FROM tool_record WHERE description_content_id IS NOT NULL) AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record WHERE input_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT instructions_content_id FROM session WHERE instructions_content_id IS NOT NULL) AND content_id NOT IN (SELECT output_schema_content_id FROM session WHERE output_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT primary_content_id FROM core_command WHERE primary_content_id IS NOT NULL) AND content_id NOT IN (SELECT secondary_content_id FROM core_command WHERE secondary_content_id IS NOT NULL) AND content_id NOT IN (SELECT instructions_content_id FROM session_revision WHERE instructions_content_id IS NOT NULL) AND content_id NOT IN (SELECT output_schema_content_id FROM session_revision WHERE output_schema_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM message_admission WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT outcome_content_id FROM turn WHERE outcome_content_id IS NOT NULL) AND content_id NOT IN (SELECT resolution_content_id FROM model_operation WHERE resolution_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM message_skill WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT catalog_content_id FROM session_skill_catalog WHERE catalog_content_id IS NOT NULL) AND content_id NOT IN (SELECT content_id FROM conversation_entry WHERE content_id IS NOT NULL) AND content_id NOT IN (SELECT message_content_id FROM model_output_item WHERE message_content_id IS NOT NULL) AND content_id NOT IN (SELECT extras_content_id FROM model_output_item WHERE extras_content_id IS NOT NULL) AND content_id NOT IN (SELECT text_content_id FROM model_output_part WHERE text_content_id IS NOT NULL) AND content_id NOT IN (SELECT extras_content_id FROM model_output_part WHERE extras_content_id IS NOT NULL) AND content_id NOT IN (SELECT name_content_id FROM model_tool_call WHERE name_content_id IS NOT NULL) AND content_id NOT IN (SELECT call_id_content_id FROM model_tool_call WHERE call_id_content_id IS NOT NULL) AND content_id NOT IN (SELECT arguments_content_id FROM model_tool_call WHERE arguments_content_id IS NOT NULL) AND content_id NOT IN (SELECT rejection_content_id FROM model_tool_call WHERE rejection_content_id IS NOT NULL) AND content_id NOT IN (SELECT resolution_content_id FROM action_operation WHERE resolution_content_id IS NOT NULL)",
            "ALTER TABLE model_operation DROP COLUMN usage_content_id",
        },
    },
    // Schema 64: name the Host tool set and runner-independent timeout.
    .{
        .from = 63,
        .sqlite = &.{
            "ALTER TABLE host_catalog RENAME TO host_catalog_63",
            "CREATE TABLE host_tool_set(\n slot INTEGER PRIMARY KEY NOT NULL CHECK(slot=1),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id)\n) STRICT",
            "INSERT INTO host_tool_set(slot,tool_set_id) SELECT slot,tool_set_id FROM host_catalog_63",
            "DROP TABLE host_catalog_63",
            "ALTER TABLE action_operation RENAME COLUMN bash_timeout_ms TO attempt_timeout_ms",
        },
        .mysql = &.{
            "RENAME TABLE host_catalog TO host_tool_set",
            "ALTER TABLE action_operation DROP CHECK action_operation_chk_8, DROP CHECK action_operation_chk_17",
            "ALTER TABLE action_operation RENAME COLUMN bash_timeout_ms TO attempt_timeout_ms",
            "ALTER TABLE action_operation ADD CHECK(attempt_timeout_ms IS NULL OR attempt_timeout_ms>0), ADD CHECK((attempt_ordinal=0 AND attempt_timeout_ms IS NULL) OR (attempt_ordinal=1 AND attempt_timeout_ms IS NOT NULL))",
        },
    },
    // Schema 65: Session sets become intent, conservatively retaining current
    // names. Each old Operation keeps the offer of its own settings revision.
    .{
        .from = 64,
        .sqlite = &.{
            "ALTER TABLE model_operation RENAME TO model_operation_64",
            "CREATE TABLE model_operation(\n operation_id INTEGER PRIMARY KEY NOT NULL CHECK(operation_id>0),\n turn_id INTEGER NOT NULL REFERENCES turn(turn_id),\n session_ref TEXT NOT NULL,\n settings_revision INTEGER NOT NULL CHECK(settings_revision>0),\n input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),\n admission_position INTEGER NOT NULL CHECK(admission_position>0),\n purpose INTEGER NOT NULL DEFAULT 0 CHECK(purpose IN (0,1)),\n compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),\n output_reservation INTEGER NOT NULL CHECK(output_reservation>=0),\n reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),\n output_item_count INTEGER CHECK(output_item_count IS NULL OR output_item_count>=0),\n attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal BETWEEN 1 AND 4),\n auth_refresh_claimed INTEGER NOT NULL DEFAULT 0 CHECK(auth_refresh_claimed IN (0,1)),\n retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),\n last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),\n resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),\n resolution_content_id INTEGER REFERENCES content(content_id),\n response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),\n model_evidence BLOB CHECK(model_evidence IS NULL OR length(model_evidence) BETWEEN 7 AND 775),\n request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),\n usage_uncached_tokens INTEGER CHECK(usage_uncached_tokens IS NULL OR usage_uncached_tokens>=0),\n usage_cache_read_tokens INTEGER CHECK(usage_cache_read_tokens IS NULL OR usage_cache_read_tokens>=0),\n usage_cache_write_tokens INTEGER CHECK(usage_cache_write_tokens IS NULL OR usage_cache_write_tokens>=0),\n usage_output_tokens INTEGER CHECK(usage_output_tokens IS NULL OR usage_output_tokens>=0),\n interrupted_by_command_key TEXT REFERENCES core_command(command_key),\n attempt_at INTEGER CHECK(attempt_at IS NULL OR attempt_at>0),\n retry_scheduled_at INTEGER CHECK(retry_scheduled_at IS NULL OR retry_scheduled_at>0),\n resolved_at INTEGER CHECK(resolved_at IS NULL OR resolved_at>0),\n history_floor INTEGER CHECK(history_floor IS NULL OR history_floor>0),\n history_level INTEGER CHECK(history_level IS NULL OR history_level BETWEEN 1 AND 3),\n history_dropped INTEGER CHECK(history_dropped IS NULL OR history_dropped>=0),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),\n UNIQUE(operation_id,session_ref),\n FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),\n CHECK((usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR (usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND usage_output_tokens IS NOT NULL)),\n CHECK((resolution_code IS NULL AND retry_due_at_ms IS NOT NULL) OR (resolution_code IS NOT NULL AND retry_due_at_ms IS NULL)),\n CHECK((resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at IS NOT NULL AND retry_scheduled_at IS NULL AND resolved_at IS NULL) OR (resolution_code IS NULL AND retry_due_at_ms>0 AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND resolved_at IS NULL) OR (resolution_code IS NOT NULL AND attempt_at IS NULL AND retry_scheduled_at IS NULL AND resolved_at IS NOT NULL)),\n CHECK(((resolution_code IS 'interrupted') AND interrupted_by_command_key IS NOT NULL) OR (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL)),\n CHECK((history_floor IS NULL AND history_level IS NULL AND history_dropped IS NULL) OR (history_floor IS NOT NULL AND purpose=1 AND ((history_level IS NULL AND history_dropped IS NULL) OR (history_level IS NOT NULL AND history_dropped IS NOT NULL))))\n) STRICT",
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id) SELECT operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped, (SELECT coalesce(r.loaded_tool_set_id,r.tool_set_id) FROM session_revision r WHERE r.session_ref=model_operation_64.session_ref AND r.revision=model_operation_64.settings_revision) FROM model_operation_64",
            "DROP TABLE model_operation_64",
            "CREATE INDEX model_operation_retry_due ON model_operation(retry_due_at_ms,operation_id) WHERE resolution_code IS NULL AND attempt_ordinal<4",
            "CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal=4",
            "CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id)",
            "CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id)",
            "CREATE INDEX model_operation_admission ON model_operation(session_ref,admission_position)",
            "CREATE INDEX model_operation_context_history ON model_operation(session_ref,admission_position) WHERE (resolution_code='answer' OR resolution_code='compacted' OR resolution_code='tool_proposals')",
            "CREATE INDEX model_operation_compaction_bases ON model_operation(session_ref,admission_position) WHERE purpose=1 AND resolution_code='compacted'",
        },
        .mysql = &.{
            "ALTER TABLE model_operation ADD COLUMN tool_set_id BIGINT AFTER history_dropped",
            "UPDATE model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision SET o.tool_set_id=coalesce(r.loaded_tool_set_id,r.tool_set_id)",
            "ALTER TABLE model_operation MODIFY tool_set_id BIGINT NOT NULL,ADD CHECK(tool_set_id>0),ADD FOREIGN KEY(tool_set_id) REFERENCES tool_set(tool_set_id)",
        },
    },
    // Schema 66 (base 65 + 1): Operation-owned effort emissions/refusals and wire 13.
    .{
        .from = 65,
        .sqlite = &.{
            "CREATE TABLE revision_effort_before_66 AS SELECT r.session_ref,r.revision,(SELECT choice.revision FROM session_revision choice LEFT JOIN session_revision before_choice ON before_choice.session_ref=choice.session_ref AND before_choice.revision=choice.revision-1 WHERE choice.session_ref=r.session_ref AND choice.revision<=r.revision AND (choice.revision=1 OR choice.model<>before_choice.model OR NOT (choice.reasoning_effort IS before_choice.reasoning_effort) OR EXISTS(SELECT 1 FROM session_change changed WHERE changed.session_ref=choice.session_ref AND changed.revision=choice.revision AND changed.field IN ('reasoning_effort','model'))) ORDER BY choice.revision DESC LIMIT 1) AS effort_source_revision FROM session_revision r",
            "ALTER TABLE session_revision RENAME TO session_revision_before_66",
            "CREATE TABLE session_revision(\n session_ref TEXT NOT NULL REFERENCES session(session_ref),\n revision INTEGER NOT NULL CHECK(revision>0),\n command_key TEXT NOT NULL UNIQUE REFERENCES core_command(command_key),\n workspace TEXT NOT NULL,\n provider TEXT NOT NULL CHECK(length(CAST(provider AS BLOB)) BETWEEN 1 AND 16 AND provider GLOB '[a-z]*' AND (provider NOT GLOB '*[^a-z0-9_-]*' AND length(provider)=length(CAST(provider AS BLOB)))),\n model TEXT NOT NULL,\n instructions_content_id INTEGER NOT NULL REFERENCES content(content_id),\n instructions_updated INTEGER NOT NULL CHECK(instructions_updated IN (0,1)),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),\n loaded_tool_set_id INTEGER REFERENCES tool_set(tool_set_id),\n permission_mode INTEGER NOT NULL CHECK(permission_mode BETWEEN 0 AND 1),\n output_schema_content_id INTEGER REFERENCES content(content_id),\n compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),\n output_reservation INTEGER CHECK(output_reservation IS NULL OR output_reservation>=0),\n reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),\n label TEXT CHECK(label IS NULL OR length(CAST(label AS BLOB)) BETWEEN 1 AND 100),\n effort_source_revision INTEGER NOT NULL DEFAULT 1 CHECK(effort_source_revision>0 AND effort_source_revision<=revision),\n PRIMARY KEY(session_ref,revision),\n FOREIGN KEY(session_ref,effort_source_revision) REFERENCES session_revision(session_ref,revision)\n) STRICT, WITHOUT ROWID",
            "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label,effort_source_revision) SELECT r.session_ref,r.revision,r.command_key,r.workspace,r.provider,r.model,r.instructions_content_id,r.instructions_updated,r.tool_set_id,r.loaded_tool_set_id,r.permission_mode,r.output_schema_content_id,r.compaction_trigger,r.output_reservation,r.reasoning_effort,r.label,frozen.effort_source_revision FROM session_revision_before_66 r JOIN revision_effort_before_66 frozen ON frozen.session_ref=r.session_ref AND frozen.revision=r.revision",
            "DROP TABLE session_revision_before_66",
            "CREATE INDEX session_revision_instructions ON session_revision(session_ref,instructions_content_id)",
            "CREATE INDEX session_revision_output_schema ON session_revision(session_ref,output_schema_content_id)",
            "DROP TABLE revision_effort_before_66",
            "CREATE TABLE model_effort_before_66 AS SELECT o.operation_id,r.effort_source_revision AS effort_source_revision,(SELECT prior_effort.reasoning_effort FROM model_operation prior_effort JOIN session_revision prior_model ON prior_model.session_ref=prior_effort.session_ref AND prior_model.revision=prior_effort.settings_revision WHERE prior_effort.session_ref=o.session_ref AND prior_effort.admission_position<o.admission_position AND prior_model.model=r.model ORDER BY prior_effort.admission_position DESC LIMIT 1) AS previous_reasoning_effort,(SELECT earlier_model.reasoning_effort FROM model_operation earlier JOIN session_revision earlier_model ON earlier_model.session_ref=earlier.session_ref AND earlier_model.revision=earlier.settings_revision WHERE earlier.session_ref=o.session_ref AND earlier.admission_position<o.admission_position AND earlier_model.model=r.model ORDER BY earlier.admission_position DESC LIMIT 1) AS previous_effort_override,(s.codec='openai-responses/2' AND o.reasoning_effort IS NOT NULL AND NOT (o.reasoning_effort IS (SELECT CASE WHEN retained.operation_id IS NOT NULL THEN retained.reasoning_effort WHEN first_effort.operation_id IS NOT NULL THEN first_effort.reasoning_effort ELSE o.reasoning_effort END FROM session effort_seed LEFT JOIN model_operation effort_base ON effort_base.operation_id=(SELECT selected.operation_id FROM model_operation selected WHERE selected.session_ref=o.session_ref AND selected.purpose=1 AND selected.resolution_code='compacted' AND selected.admission_position<o.admission_position ORDER BY selected.admission_position DESC LIMIT 1) LEFT JOIN session_revision effort_base_model ON effort_base_model.session_ref=effort_base.session_ref AND effort_base_model.revision=effort_base.settings_revision LEFT JOIN model_operation retained ON retained.operation_id=(SELECT earlier.operation_id FROM model_operation earlier JOIN session_revision earlier_model ON earlier_model.session_ref=earlier.session_ref AND earlier_model.revision=earlier.settings_revision WHERE earlier.session_ref=o.session_ref AND earlier.admission_position<o.admission_position AND earlier_model.model=r.model AND earlier.admission_position>max(coalesce(o.history_floor,0),CASE WHEN effort_base_model.model=r.model THEN coalesce(effort_base.history_floor,0) ELSE 0 END) AND earlier.admission_position>=CASE WHEN effort_base_model.model=r.model THEN coalesce((SELECT min(anchor.session_position) FROM model_output_item anchor WHERE anchor.operation_id=effort_base.operation_id AND anchor.item_kind=4),0) ELSE 0 END ORDER BY earlier.admission_position DESC LIMIT 1) LEFT JOIN model_operation first_effort ON first_effort.operation_id=(SELECT first.operation_id FROM model_operation first JOIN session_revision first_model ON first_model.session_ref=first.session_ref AND first_model.revision=first.settings_revision WHERE first.session_ref=o.session_ref AND first_model.model=r.model AND first.admission_position<o.admission_position ORDER BY first.admission_position LIMIT 1) WHERE effort_seed.session_ref=o.session_ref))) AS effort_update FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision JOIN session s ON s.session_ref=o.session_ref",
            "CREATE UNIQUE INDEX model_effort_before_66_key ON model_effort_before_66(operation_id)",
            "ALTER TABLE model_operation RENAME TO model_operation_before_66",
            "CREATE TABLE model_operation(\n operation_id INTEGER PRIMARY KEY NOT NULL CHECK(operation_id>0),\n turn_id INTEGER NOT NULL REFERENCES turn(turn_id),\n session_ref TEXT NOT NULL,\n settings_revision INTEGER NOT NULL CHECK(settings_revision>0),\n input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),\n admission_position INTEGER NOT NULL CHECK(admission_position>0),\n purpose INTEGER NOT NULL DEFAULT 0 CHECK(purpose IN (0,1)),\n compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),\n output_reservation INTEGER NOT NULL CHECK(output_reservation>=0),\n reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),\n output_item_count INTEGER CHECK(output_item_count IS NULL OR output_item_count>=0),\n attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal BETWEEN 1 AND 4),\n auth_refresh_claimed INTEGER NOT NULL DEFAULT 0 CHECK(auth_refresh_claimed IN (0,1)),\n retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),\n last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),\n resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),\n resolution_content_id INTEGER REFERENCES content(content_id),\n response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),\n model_evidence BLOB CHECK(model_evidence IS NULL OR length(model_evidence) BETWEEN 7 AND 775),\n request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),\n usage_uncached_tokens INTEGER CHECK(usage_uncached_tokens IS NULL OR usage_uncached_tokens>=0),\n usage_cache_read_tokens INTEGER CHECK(usage_cache_read_tokens IS NULL OR usage_cache_read_tokens>=0),\n usage_cache_write_tokens INTEGER CHECK(usage_cache_write_tokens IS NULL OR usage_cache_write_tokens>=0),\n usage_output_tokens INTEGER CHECK(usage_output_tokens IS NULL OR usage_output_tokens>=0),\n interrupted_by_command_key TEXT REFERENCES core_command(command_key),\n attempt_at INTEGER CHECK(attempt_at IS NULL OR attempt_at>0),\n retry_scheduled_at INTEGER CHECK(retry_scheduled_at IS NULL OR retry_scheduled_at>0),\n resolved_at INTEGER CHECK(resolved_at IS NULL OR resolved_at>0),\n history_floor INTEGER CHECK(history_floor IS NULL OR history_floor>0),\n history_level INTEGER CHECK(history_level IS NULL OR history_level BETWEEN 1 AND 3),\n history_dropped INTEGER CHECK(history_dropped IS NULL OR history_dropped>=0),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),\n effort_source_revision INTEGER NOT NULL DEFAULT 1 CHECK(effort_source_revision>0 AND effort_source_revision<=settings_revision),\n previous_reasoning_effort TEXT CHECK(previous_reasoning_effort IS NULL OR (previous_reasoning_effort='none' OR previous_reasoning_effort='low' OR previous_reasoning_effort='medium' OR previous_reasoning_effort='high' OR previous_reasoning_effort='xhigh' OR previous_reasoning_effort='max')),\n effort_update INTEGER NOT NULL DEFAULT 0 CHECK(effort_update IN (0,1) AND (effort_update=0 OR reasoning_effort IS NOT NULL)),\n previous_effort_override TEXT CHECK(previous_effort_override IS NULL OR (previous_effort_override='none' OR previous_effort_override='low' OR previous_effort_override='medium' OR previous_effort_override='high' OR previous_effort_override='xhigh' OR previous_effort_override='max')),\n UNIQUE(operation_id,session_ref),\n FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),\n CHECK((usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR (usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND usage_output_tokens IS NOT NULL)),\n CHECK((resolution_code IS NULL AND retry_due_at_ms IS NOT NULL) OR (resolution_code IS NOT NULL AND retry_due_at_ms IS NULL)),\n CHECK((resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at IS NOT NULL AND retry_scheduled_at IS NULL AND resolved_at IS NULL) OR (resolution_code IS NULL AND retry_due_at_ms>0 AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND resolved_at IS NULL) OR (resolution_code IS NOT NULL AND attempt_at IS NULL AND retry_scheduled_at IS NULL AND resolved_at IS NOT NULL)),\n CHECK(((resolution_code IS 'interrupted') AND interrupted_by_command_key IS NOT NULL) OR (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL)),\n CHECK((history_floor IS NULL AND history_level IS NULL AND history_dropped IS NULL) OR (history_floor IS NOT NULL AND purpose=1 AND ((history_level IS NULL AND history_dropped IS NULL) OR (history_level IS NOT NULL AND history_dropped IS NOT NULL))))\n) STRICT",
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override) SELECT old.operation_id,old.turn_id,old.session_ref,old.settings_revision,old.input_cutoff,old.admission_position,old.purpose,old.compaction_trigger,old.output_reservation,old.reasoning_effort,old.output_item_count,old.attempt_ordinal,old.auth_refresh_claimed,old.retry_due_at_ms,old.last_failure_code,old.resolution_code,old.resolution_content_id,old.response_id,old.model_evidence,old.request_id,old.usage_uncached_tokens,old.usage_cache_read_tokens,old.usage_cache_write_tokens,old.usage_output_tokens,old.interrupted_by_command_key,old.attempt_at,old.retry_scheduled_at,old.resolved_at,old.history_floor,old.history_level,old.history_dropped,old.tool_set_id,frozen.effort_source_revision,frozen.previous_reasoning_effort,frozen.effort_update,frozen.previous_effort_override FROM model_operation_before_66 old JOIN model_effort_before_66 frozen ON frozen.operation_id=old.operation_id",
            "DROP TABLE model_operation_before_66",
            "DROP TABLE model_effort_before_66",
            "CREATE INDEX model_operation_retry_due ON model_operation(retry_due_at_ms,operation_id) WHERE resolution_code IS NULL AND attempt_ordinal<4",
            "CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal=4",
            "CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id)",
            "CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id)",
            "CREATE INDEX model_operation_admission ON model_operation(session_ref,admission_position)",
            "CREATE INDEX model_operation_context_history ON model_operation(session_ref,admission_position) WHERE (resolution_code='answer' OR resolution_code='compacted' OR resolution_code='tool_proposals')",
            "CREATE INDEX model_operation_compaction_bases ON model_operation(session_ref,admission_position) WHERE purpose=1 AND resolution_code='compacted'",
            "CREATE UNIQUE INDEX model_operation_effort_source ON model_operation(operation_id,session_ref,effort_source_revision)",
            "ALTER TABLE session_change RENAME TO session_change_before_66",
            "CREATE TABLE session_change(\n session_ref TEXT NOT NULL REFERENCES session(session_ref),\n position INTEGER NOT NULL CHECK(position>0),\n ordinal INTEGER NOT NULL CHECK(ordinal>=0),\n revision INTEGER NOT NULL CHECK(revision>1),\n field TEXT NOT NULL CHECK((field='provider' OR field='model' OR field='instructions' OR field='tools' OR field='loaded_tools' OR field='permission_mode' OR field='output_schema' OR field='compaction_trigger' OR field='output_reservation' OR field='reasoning_effort' OR field='label' OR field='reasoning_effort_refused')),\n changed_at INTEGER NOT NULL CHECK(changed_at>0),\n provider_text TEXT CHECK(provider_text IS NULL OR length(CAST(provider_text AS BLOB))<=520),\n refused_operation_id INTEGER,\n PRIMARY KEY(session_ref,position,ordinal),\n UNIQUE(session_ref,revision,field),\n FOREIGN KEY(session_ref,revision) REFERENCES session_revision(session_ref,revision),\n FOREIGN KEY(refused_operation_id,session_ref,revision) REFERENCES model_operation(operation_id,session_ref,effort_source_revision),\n CHECK((field='reasoning_effort_refused')=(provider_text IS NOT NULL)),\n CHECK((field='reasoning_effort_refused')=(refused_operation_id IS NOT NULL))\n) STRICT, WITHOUT ROWID",
            "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at) SELECT session_ref,position,ordinal,revision,field,changed_at FROM session_change_before_66",
            "DROP TABLE session_change_before_66",
            "CREATE INDEX session_change_refused_operation ON session_change(refused_operation_id,session_ref,revision)",
            "UPDATE store_meta SET meta_value='13' WHERE meta_key='wire_version' AND meta_value='12'",
        },
        .mysql = &.{
            "CREATE TABLE revision_effort_before_66 AS SELECT r.session_ref,r.revision,(SELECT choice.revision FROM session_revision choice LEFT JOIN session_revision before_choice ON before_choice.session_ref=choice.session_ref AND before_choice.revision=choice.revision-1 WHERE choice.session_ref=r.session_ref AND choice.revision<=r.revision AND (choice.revision=1 OR choice.model<>before_choice.model OR NOT (choice.reasoning_effort<=>before_choice.reasoning_effort) OR EXISTS(SELECT 1 FROM session_change changed WHERE changed.session_ref=choice.session_ref AND changed.revision=choice.revision AND changed.field IN ('reasoning_effort','model'))) ORDER BY choice.revision DESC LIMIT 1) AS effort_source_revision FROM session_revision r",
            "ALTER TABLE session_revision ADD COLUMN effort_source_revision BIGINT NOT NULL DEFAULT 1,ADD CHECK(effort_source_revision>0 AND effort_source_revision<=revision),ADD FOREIGN KEY(session_ref,effort_source_revision) REFERENCES session_revision(session_ref,revision)",
            "UPDATE session_revision r JOIN revision_effort_before_66 frozen ON frozen.session_ref=r.session_ref AND frozen.revision=r.revision SET r.effort_source_revision=frozen.effort_source_revision",
            "DROP TABLE revision_effort_before_66",
            "CREATE TABLE model_effort_before_66 AS SELECT o.operation_id,r.effort_source_revision AS effort_source_revision,(SELECT prior_effort.reasoning_effort FROM model_operation prior_effort JOIN session_revision prior_model ON prior_model.session_ref=prior_effort.session_ref AND prior_model.revision=prior_effort.settings_revision WHERE prior_effort.session_ref=o.session_ref AND prior_effort.admission_position<o.admission_position AND prior_model.model=r.model ORDER BY prior_effort.admission_position DESC LIMIT 1) AS previous_reasoning_effort,(SELECT earlier_model.reasoning_effort FROM model_operation earlier JOIN session_revision earlier_model ON earlier_model.session_ref=earlier.session_ref AND earlier_model.revision=earlier.settings_revision WHERE earlier.session_ref=o.session_ref AND earlier.admission_position<o.admission_position AND earlier_model.model=r.model ORDER BY earlier.admission_position DESC LIMIT 1) AS previous_effort_override,(s.codec='openai-responses/2' AND o.reasoning_effort IS NOT NULL AND NOT (o.reasoning_effort<=>(SELECT CASE WHEN retained.operation_id IS NOT NULL THEN retained.reasoning_effort WHEN first_effort.operation_id IS NOT NULL THEN first_effort.reasoning_effort ELSE o.reasoning_effort END FROM session effort_seed LEFT JOIN model_operation effort_base ON effort_base.operation_id=(SELECT selected.operation_id FROM model_operation selected WHERE selected.session_ref=o.session_ref AND selected.purpose=1 AND selected.resolution_code='compacted' AND selected.admission_position<o.admission_position ORDER BY selected.admission_position DESC LIMIT 1) LEFT JOIN session_revision effort_base_model ON effort_base_model.session_ref=effort_base.session_ref AND effort_base_model.revision=effort_base.settings_revision LEFT JOIN model_operation retained ON retained.operation_id=(SELECT earlier.operation_id FROM model_operation earlier JOIN session_revision earlier_model ON earlier_model.session_ref=earlier.session_ref AND earlier_model.revision=earlier.settings_revision WHERE earlier.session_ref=o.session_ref AND earlier.admission_position<o.admission_position AND earlier_model.model=r.model AND earlier.admission_position>greatest(coalesce(o.history_floor,0),CASE WHEN effort_base_model.model=r.model THEN coalesce(effort_base.history_floor,0) ELSE 0 END) AND earlier.admission_position>=CASE WHEN effort_base_model.model=r.model THEN coalesce((SELECT min(anchor.session_position) FROM model_output_item anchor WHERE anchor.operation_id=effort_base.operation_id AND anchor.item_kind=4),0) ELSE 0 END ORDER BY earlier.admission_position DESC LIMIT 1) LEFT JOIN model_operation first_effort ON first_effort.operation_id=(SELECT first.operation_id FROM model_operation first JOIN session_revision first_model ON first_model.session_ref=first.session_ref AND first_model.revision=first.settings_revision WHERE first.session_ref=o.session_ref AND first_model.model=r.model AND first.admission_position<o.admission_position ORDER BY first.admission_position LIMIT 1) WHERE effort_seed.session_ref=o.session_ref))) AS effort_update FROM model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision JOIN session s ON s.session_ref=o.session_ref",
            "CREATE UNIQUE INDEX model_effort_before_66_key ON model_effort_before_66(operation_id)",
            "ALTER TABLE model_operation ADD COLUMN effort_source_revision BIGINT NOT NULL DEFAULT 1 AFTER tool_set_id,ADD CHECK(effort_source_revision>0 AND effort_source_revision<=settings_revision),ADD COLUMN previous_reasoning_effort VARCHAR(6) AFTER effort_source_revision,ADD CHECK(previous_reasoning_effort IS NULL OR (previous_reasoning_effort='none' OR previous_reasoning_effort='low' OR previous_reasoning_effort='medium' OR previous_reasoning_effort='high' OR previous_reasoning_effort='xhigh' OR previous_reasoning_effort='max')),ADD COLUMN effort_update TINYINT NOT NULL DEFAULT 0 AFTER previous_reasoning_effort,ADD CHECK(effort_update IN (0,1) AND (effort_update=0 OR reasoning_effort IS NOT NULL)),ADD COLUMN previous_effort_override VARCHAR(6) AFTER effort_update,ADD CHECK(previous_effort_override IS NULL OR (previous_effort_override='none' OR previous_effort_override='low' OR previous_effort_override='medium' OR previous_effort_override='high' OR previous_effort_override='xhigh' OR previous_effort_override='max'))",
            "UPDATE model_operation o JOIN model_effort_before_66 frozen ON frozen.operation_id=o.operation_id SET o.effort_source_revision=frozen.effort_source_revision,o.previous_reasoning_effort=frozen.previous_reasoning_effort,o.effort_update=frozen.effort_update,o.previous_effort_override=frozen.previous_effort_override",
            "DROP TABLE model_effort_before_66",
            "CREATE UNIQUE INDEX model_operation_effort_source ON model_operation(operation_id,session_ref,effort_source_revision)",
            "CREATE TABLE session_change_66(\n session_ref VARCHAR(6) NOT NULL,\n position BIGINT NOT NULL,\n ordinal BIGINT NOT NULL,\n revision BIGINT NOT NULL,\n field VARCHAR(24) NOT NULL,\n changed_at BIGINT NOT NULL,\n provider_text TEXT,\n refused_operation_id BIGINT,\n PRIMARY KEY(session_ref,position,ordinal),\n UNIQUE(session_ref,revision,field),\n INDEX session_change_refused_operation(refused_operation_id,session_ref,revision),\n FOREIGN KEY(session_ref) REFERENCES session(session_ref),\n FOREIGN KEY(session_ref,revision) REFERENCES session_revision(session_ref,revision),\n CHECK(position>0),\n CHECK(ordinal>=0),\n CHECK(revision>1),\n CHECK((field='provider' OR field='model' OR field='instructions' OR field='tools' OR field='loaded_tools' OR field='permission_mode' OR field='output_schema' OR field='compaction_trigger' OR field='output_reservation' OR field='reasoning_effort' OR field='label' OR field='reasoning_effort_refused')),\n CHECK(changed_at>0),\n CHECK(provider_text IS NULL OR OCTET_LENGTH(provider_text)<=520),\n FOREIGN KEY(refused_operation_id,session_ref,revision) REFERENCES model_operation(operation_id,session_ref,effort_source_revision),\n CHECK((field='reasoning_effort_refused')=(provider_text IS NOT NULL)),\n CHECK((field='reasoning_effort_refused')=(refused_operation_id IS NOT NULL))\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "INSERT INTO session_change_66(session_ref,position,ordinal,revision,field,changed_at) SELECT session_ref,position,ordinal,revision,field,changed_at FROM session_change",
            "DROP TABLE session_change",
            "RENAME TABLE session_change_66 TO session_change",
            "UPDATE store_meta SET meta_value='13' WHERE meta_key='wire_version' AND meta_value='12'",
        },
    },
    // Schema 67 (D39, D180): the first ending hop is the sole owed fact.
    .{
        .from = 66,
        .sqlite = &.{
            "ALTER TABLE session_forward RENAME TO session_forward_before_67",
            "CREATE TABLE session_forward(\n forward_id INTEGER PRIMARY KEY NOT NULL CHECK(forward_id>0),\n target_ref TEXT NOT NULL REFERENCES session(session_ref),\n child_ref TEXT NOT NULL REFERENCES session(session_ref),\n kind INTEGER NOT NULL CHECK(kind BETWEEN 1 AND 2),\n source_id INTEGER NOT NULL CHECK(source_id>0),\n position INTEGER CHECK(position IS NULL OR position>0),\n ordinal INTEGER NOT NULL CHECK(ordinal=0),\n delivered_at INTEGER CHECK(delivered_at IS NULL OR delivered_at>0),\n message_delivered INTEGER CHECK(message_delivered IS NULL OR message_delivered IN (0,1)),\n suppress_message INTEGER NOT NULL DEFAULT 0 CHECK(suppress_message IN (0,1)),\n UNIQUE(target_ref,kind,source_id),\n CHECK((position IS NULL)=(delivered_at IS NULL)),\n CHECK(target_ref<>child_ref)\n) STRICT",
            "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) SELECT f.forward_id,f.target_ref,f.child_ref,f.kind,f.source_id,f.position,f.ordinal,f.delivered_at,e.delivered,COALESCE(e.suppress_message,0) FROM session_forward_before_67 f JOIN session child ON child.session_ref=f.child_ref LEFT JOIN session_ending_owed e ON f.kind=2 AND e.turn_id=f.source_id AND f.target_ref=child.parent_ref",
            "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) SELECT COALESCE((SELECT max(forward_id) FROM session_forward_before_67),0)+ROW_NUMBER() OVER(ORDER BY e.turn_id),child.parent_ref,t.session_ref,2,e.turn_id,NULL,0,NULL,e.delivered,e.suppress_message FROM session_ending_owed e JOIN turn t ON t.turn_id=e.turn_id JOIN session child ON child.session_ref=t.session_ref WHERE child.parent_ref IS NOT NULL AND NOT EXISTS(SELECT 1 FROM session_forward_before_67 f WHERE f.target_ref=child.parent_ref AND f.kind=2 AND f.source_id=e.turn_id)",
            "DROP TABLE session_forward_before_67",
            "DROP TABLE session_ending_owed",
            "CREATE INDEX session_forward_message ON session_forward(message_delivered,source_id)",
            "CREATE INDEX session_forward_open ON session_forward(forward_id) WHERE position IS NULL",
            "CREATE INDEX session_forward_feed ON session_forward(target_ref,position)",
        },
        .mysql = &.{
            "ALTER TABLE session_forward ADD COLUMN message_delivered TINYINT AFTER delivered_at, ADD COLUMN suppress_message TINYINT NOT NULL DEFAULT 0 AFTER message_delivered",
            "ALTER TABLE session_forward ADD CHECK(message_delivered IS NULL OR message_delivered IN (0,1)), ADD CHECK(suppress_message IN (0,1))",
            "UPDATE session_forward f JOIN session child ON child.session_ref=f.child_ref JOIN session_ending_owed e ON f.kind=2 AND e.turn_id=f.source_id AND f.target_ref=child.parent_ref SET f.message_delivered=e.delivered,f.suppress_message=e.suppress_message",
            "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at,message_delivered,suppress_message) SELECT COALESCE((SELECT max(forward_id) FROM session_forward),0)+ROW_NUMBER() OVER(ORDER BY e.turn_id),child.parent_ref,t.session_ref,2,e.turn_id,NULL,0,NULL,e.delivered,e.suppress_message FROM session_ending_owed e JOIN turn t ON t.turn_id=e.turn_id JOIN session child ON child.session_ref=t.session_ref WHERE child.parent_ref IS NOT NULL AND NOT EXISTS(SELECT 1 FROM session_forward f WHERE f.target_ref=child.parent_ref AND f.kind=2 AND f.source_id=e.turn_id)",
            "DROP TABLE session_ending_owed",
            "CREATE INDEX session_forward_message ON session_forward(message_delivered,source_id)",
        },
    },
    // Schema 68 (D219): final-attempt timings stay absent on old Operations.
    .{
        .from = 67,
        .sqlite = &.{
            "ALTER TABLE model_operation ADD COLUMN latency_ms INTEGER CHECK(latency_ms IS NULL OR latency_ms>=0)",
            "ALTER TABLE model_operation ADD COLUMN first_event_ms INTEGER CHECK(first_event_ms IS NULL OR first_event_ms>=0)",
        },
        .mysql = &.{
            "ALTER TABLE model_operation ADD COLUMN latency_ms BIGINT CHECK(latency_ms IS NULL OR latency_ms>=0) AFTER previous_effort_override, ADD COLUMN first_event_ms BIGINT CHECK(first_event_ms IS NULL OR first_event_ms>=0) AFTER latency_ms",
        },
    },
    // Schema 69 (D238): freeze capacity once per model Operation. This literal
    // mapping is the pre-change shipped snapshot, not a live catalog lookup.
    // Old rows retain legacy escalation policy, not an invented saved window.
    // Chunk the temporary mapping below the Store's SQL-length limit. Default
    // and null windows need no entry: the backfill's literal fallback owns them.
    .{
        .from = 68,
        .sqlite = &.{
            "CREATE TEMP TABLE operation_window_backfill(model_id TEXT PRIMARY KEY NOT NULL,context_window INTEGER NOT NULL) STRICT, WITHOUT ROWID",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('@cf/deepseek-ai/deepseek-r1-distill-qwen-32b',80000),('@cf/deepseek-ai/deepseek-v4-flash-0731',1048576),('@cf/deepseek-ai/deepseek-v4-pro-0813',1048576),('@cf/deepseek-ai/deepseek-v4.1-flash-1017',1048576),('@cf/google/gemma-4-26b-a4b-it',256000),('@cf/ibm-granite/granite-4.0-h-micro',131000),('@cf/meta/llama-3.1-8b-instruct-fp8',32000),('@cf/meta/llama-3.2-1b-instruct',60000),('@cf/meta/llama-3.2-3b-instruct',80000),('@cf/meta/llama-3.3-70b-instruct-fp8-fast',24000),('@cf/meta/llama-4-scout-17b-16e-instruct',131000),('@cf/meta/llama-guard-3-8b',131072),('@cf/moonshotai/kimi-k2.6',262144),('@cf/moonshotai/kimi-k2.7-code',262144),('@cf/nvidia/nemotron-3-120b-a12b',256000),('@cf/qwen/qwen2.5-coder-32b-instruct',32768),('@cf/qwen/qwen3-30b-a3b-fp8',32768),('@cf/qwen/qwen3.8-27b',262144),('@cf/qwen/qwq-32b',24000),('@cf/zai-org/glm-4.7-flash',131072),('@cf/zai-org/glm-5.2',262144),('@cf/zai-org/glm-5.3',1048576),('@cf/zai-org/glm-5.3-flash',1048576),('Agents-A1',262000),('Beam-1.0-501B-A23B',1048576),('ByteDance-Seed/Seed-OSS-36B-Instruct',262000),('ByteDance/Seed-2.0-code',256000),('ByteDance/Seed-2.0-mini',256000),('ByteDance/Seed-2.0-pro',256000),('DeepSeek-V3.1',131072),('DeepSeek-V3.2',32768),('DeepSeek-V4-Flash',1048576),('DeepSeek-V4-Flash-0731',1000000),('DeepSeek-V4-Flash-Vision-Exp',1000000),('DeepSeek-V4-Pro',1000000),('DeepSeek-V4-Pro-0813',1000000),('DeepSeek-V4.1-Flash',1048576),('Doctor-Shotgun/MS3.2-24B-Magnum-Diamond',32768),('EVA-UNIT-01/EVA-LLaMA-3.33-70B-v0.0',32768),('EVA-UNIT-01/EVA-LLaMA-3.33-70B-v0.1',32768),('EVA-UNIT-01/EVA-Qwen2.5-32B-v0.2',16384),('EVA-UNIT-01/EVA-Qwen2.5-72B-v0.2',16384),('Envoid/Llama-3.05-NT-Storybreaker-Ministral-70B',16384),('Envoid/Llama-3.05-Nemotron-Tenyxchat-Storybreaker-70B',16384),('GLM-4.6-Derestricted-v5',131072),('GLM-4.7',204800),('GLM-5',204800),('GLM-5.1',202752),('GLM-5.2',1048576),('GLM-5.3',1000000),('GLM-5.3-Flash',262144),('GalrionSoftworks/MN-LooseCannon-12B-v1',16384),('Gemma-4-26B-A4B-MeroMero',262144),('Gemma-4-26B-A4B-MeroMero:thinking',262144),('Gemma-4-31B-Agares-v1',262144),('Gemma-4-31B-Animus-V14.1',262144),('Gemma-4-31B-AssGuard',262144),('Gemma-4-31B-Claude-4.6-Opus-Reasoning-Distilled',262144),('Gemma-4-31B-Cognitive-Unshackled',262144),('Gemma-4-31B-Dark-Gemistry',262144),('Gemma-4-31B-DarkIdol',262144),('Gemma-4-31B-Fabled',262144),('Gemma-4-31B-GarnetV2',262144),('Gemma-4-31B-Gembrain-X-Core',262144),('Gemma-4-31B-Gembrain-uncensored-heretic',262144),('Gemma-4-31B-IT',262144),('Gemma-4-31B-Isometry-RP',262144),('Gemma-4-31B-K1-v5',262144),('Gemma-4-31B-MeroMero',262144),('Gemma-4-31B-MeroMero-v2',262144),('Gemma-4-31B-MeroMero-v2:thinking',262144),('Gemma-4-31B-Novelist',262144),('Gemma-4-31B-Queen',262144),('Gemma-4-31B-SDFT-Heretic-RP',262144),('Gemma-4-31B-StyleTune',262144),('Gryphe/MythoMax-L2-13b',4096),('Hy3',202752),('Inferact/Qwen3.8-2.4T-A95B-NVFP4',262144),('Intel/Qwen3-Coder-480B-A35B-Instruct-int4-mixed-ar',106000),('KBLab/kb-whisper-large',448),('Kimi-K2.5',262144),('Kimi-K2.6',262144),('Kimi-K2.7-Code',262144),('Kimi-K3',1048576),('Kloker',200000),('Kloker-Integration-Architect',200000),('Kloker-Integration-Developer',200000),('LatitudeGames/Wayfarer-Large-70B-Llama-3.3',32768),('LiquidAI/LFM2-24B-A2B',32768),('LongCat-2.0',1048576),('LongCat-2.5-Preview',1048576),('MarinaraSpaghetti/NemoMix-Unleashed-12B',32768),('Meta-Llama-3.3-70B-Instruct',131072),('Meta-Llama-3_1-8B-Instruct-GGUF',131072),('MiMo-V2.6-Flash',1048576),('MiniCPM-V-4.7-1B',262144),('MiniCPM-V-4.7-35B-A3B',262144),('MiniCPM5-2B',131072),('MiniMax-M1',1000000),('MiniMax-M2',204800)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('MiniMax-M2.1',204800),('MiniMax-M2.5',204800),('MiniMax-M2.5-highspeed',204800),('MiniMax-M2.7',204800),('MiniMax-M2.7-highspeed',204800),('MiniMax-M3',1048576),('MiniMax-M3.1-Flash',1000000),('MiniMax-M3.1-Flash-Preview',1000000),('MiniMax/MiniMax-M2.7',204800),('MiniMaxAI/MiniMax-M1-80k',1000000),('MiniMaxAI/MiniMax-M2',204800),('MiniMaxAI/MiniMax-M2.1',204800),('MiniMaxAI/MiniMax-M2.5',197000),('MiniMaxAI/MiniMax-M2.7',196608),('MiniMaxAI/MiniMax-M3',1048576),('MiniMaxAI/MiniMax-M3.1-Flash',1048576),('NeverSleep/Lumimaid-v0.2-70B',16384),('NousResearch/Hermes-4-405B',131072),('Ornith-1.0-35B-FP8',262000),('PaddlePaddle/PaddleOCR-VL-1.5',16384),('Pro/deepseek-ai/DeepSeek-R1',164000),('Pro/deepseek-ai/DeepSeek-V3',164000),('Pro/deepseek-ai/DeepSeek-V3.1-Terminus',164000),('Pro/deepseek-ai/DeepSeek-V3.2',164000),('Pro/moonshotai/Kimi-K2.5',262000),('Pro/moonshotai/Kimi-K2.6',262000),('Pro/zai-org/GLM-5',205000),('Pro/zai-org/GLM-5.1',205000),('Qwen/QwQ-32B',32768),('Qwen/Qwen2.5-72B-Instruct',33000),('Qwen/Qwen2.5-7B-Instruct',33000),('Qwen/Qwen2.5-7B-Instruct-Turbo',32768),('Qwen/Qwen2.5-Coder-32B-Instruct',131072),('Qwen/Qwen2.5-VL-32B-Instruct',32000),('Qwen/Qwen3-14B',131000),('Qwen/Qwen3-235B-A22B',40960),('Qwen/Qwen3-235B-A22B-Instruct-2507',262144),('Qwen/Qwen3-235B-A22B-Instruct-2507-tput',262144),('Qwen/Qwen3-235B-A22B-Thinking-2507',262144),('Qwen/Qwen3-30B-A3B',40960),('Qwen/Qwen3-30B-A3B-Instruct-2507',262144),('Qwen/Qwen3-30B-A3B-Thinking-2507',262144),('Qwen/Qwen3-32B',131000),('Qwen/Qwen3-8B',131000),('Qwen/Qwen3-Coder-30B-A3B-Instruct',262144),('Qwen/Qwen3-Coder-480B-A35B-Instruct',262000),('Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8',262144),('Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo',262144),('Qwen/Qwen3-Coder-Next',262144),('Qwen/Qwen3-Coder-Next-FP8',262144),('Qwen/Qwen3-Embedding-0.6B',32768),('Qwen/Qwen3-Embedding-4B',32768),('Qwen/Qwen3-Embedding-8B',32768),('Qwen/Qwen3-Max',256000),('Qwen/Qwen3-Next-80B-A3B-Instruct',262144),('Qwen/Qwen3-Reranker-0.6B',40960),('Qwen/Qwen3-Reranker-4B',32000),('Qwen/Qwen3-VL-235B-A22B-Instruct',131072),('Qwen/Qwen3-VL-235B-A22B-Instruct-FP8',218000),('Qwen/Qwen3-VL-235B-A22B-Thinking',131072),('Qwen/Qwen3-VL-30B-A3B-Instruct',16384),('Qwen/Qwen3-VL-30B-A3B-Thinking',262000),('Qwen/Qwen3-VL-32B-Instruct',262000),('Qwen/Qwen3-VL-32B-Thinking',262000),('Qwen/Qwen3-VL-8B-Instruct',262000),('Qwen/Qwen3-VL-Embedding-8B',32000),('Qwen/Qwen3.5-122B-A10B',262144),('Qwen/Qwen3.5-122B-A10B-FP8',200000),('Qwen/Qwen3.5-27B',262144),('Qwen/Qwen3.5-35B-A3B',262144),('Qwen/Qwen3.5-35B-A3B-Base',65536),('Qwen/Qwen3.5-397B-A17B',262144),('Qwen/Qwen3.5-397B-A17B-FP8',200000),('Qwen/Qwen3.5-397B-A17B-TEE',262144),('Qwen/Qwen3.5-397B-A17B:peft:262144',262144),('Qwen/Qwen3.5-4B',65536),('Qwen/Qwen3.5-4B:peft:262144',262144),('Qwen/Qwen3.5-9B',262144),('Qwen/Qwen3.5-9B-Base',65536),('Qwen/Qwen3.5-Plus',1000000),('Qwen/Qwen3.6-27B',262144),('Qwen/Qwen3.6-27B-TEE',262144),('Qwen/Qwen3.6-35B-A3B',262144),('Qwen/Qwen3.6-35B-A3B-FP8',262144),('Qwen/Qwen3.6-35B-A3B:peft:262144',262144),('Qwen/Qwen3.6-Plus',1000000),('Qwen/Qwen3.7-Max',1000000),('Qwen/Qwen3.8-2.4T-A95B',1049000),('Qwen/Qwen3.8-27B',262144),('Qwen/Qwen3.8-27B-FP8',262144),('Qwen/Qwen3.8-27B-TEE',262144),('Qwen/Qwen3.8-27B-abliterated',262144),('Qwen/Qwen3.8-27B:peft:262144',262144),('Qwen/Qwen3.8-Flash',1048575),('Qwen/Qwen3.8-Max',262144),('Qwen/Qwen3.8-Max-0902',1000000),('Qwen/Qwen3.8-Omni-Flash',1000000),('Qwen3-Coder-Next-FP8',256144),('Qwen3-Coder-Next-FP8-no-thinking',260000),('Qwen3-Embedding-8B',32768)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('Qwen3-Next-80B-A3B-Instruct',129024),('Qwen3-Next-80B-A3B-Thinking',262144),('Qwen3-VL-235B-A22B-Instruct',129024),('Qwen3-VL-235B-A22B-Thinking',131072),('Qwen3.5-122B-A10B',262144),('Qwen3.5-27B',262144),('Qwen3.5-27B-Blossom-V6.4-Derestricted',262144),('Qwen3.5-27B-BlueStar-v3-Derestricted',262144),('Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-Derestricted',262144),('Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-Derestricted-Lite',262144),('Qwen3.5-27B-Queen-Derestricted',262144),('Qwen3.5-35B-A3B',262144),('Qwen3.5-397B-A17B',262144),('Qwen3.6-27B-FP8',262144),('Qwen3.6-35B-A3B-FP8',262000),('Qwen3.6-35B-A3B-fp8-no-thinking',262000),('Qwen3.6-Flash',1000000),('Qwen3.8-27B',131072),('Qwen3.8-Flash',1000000),('Qwen3.8-Flash-Next',262144),('Qwen3.8-Max',1000000),('Qwen3_5-9B-MLX-4bit',32768),('Qwen3_5-9B-Q4_K_M',32768),('ReadyArt/MS3.2-The-Omega-Directive-24B-Unslop-v2.0',32768),('Sao10K/L3-8B-Stheno-v3.2',16384),('Sao10K/L3.1-70B-Euryale-v2.2',20480),('Sao10K/L3.1-70B-Hanami-x1',32768),('Sao10K/L3.3-70B-Euryale-v2.3',20480),('Steelskull/L3.3-Cu-Mai-R1-70b',32768),('Steelskull/L3.3-Electra-R1-70b',32768),('Steelskull/L3.3-MS-Nevoria-70b',32768),('Steelskull/L3.3-Nevoria-R1-70b',32768),('TEE/deepseek-v3.2',164000),('TEE/deepseek-v4.1-flash',1048576),('TEE/gemma-4-26b-a4b-uncensored',65536),('TEE/gemma-4-31b-it',262144),('TEE/gemma4-31b',262144),('TEE/gemma4-31b:thinking',262144),('TEE/glm-5.1',202752),('TEE/glm-5.1-thinking',202752),('TEE/glm-5.2',1048576),('TEE/glm-5.2:thinking',1048576),('TEE/glm-5.3',1048576),('TEE/glm-5.3-flash',1048576),('TEE/gpt-oss-120b',131072),('TEE/kimi-k2.6',262144),('TEE/kimi-k3',1048576),('TEE/qwen2.5-vl-72b-instruct',65536),('TEE/qwen3.5-27b',262144),('TEE/qwen3.5-397b-a17b',262144),('TEE/qwen3.6-27b',262144),('TEE/qwen3.6-35b-a3b',262144),('TEE/qwen3.8-27b',262144),('TheDrummer/Anubis-70B-v1',65536),('TheDrummer/Anubis-70B-v1.1',32000),('TheDrummer/Artemis-v1.1',262144),('TheDrummer/Cydonia-24B-v2',32768),('TheDrummer/Cydonia-24B-v4',32768),('TheDrummer/Cydonia-24B-v4.1',131072),('TheDrummer/Cydonia-24B-v4.3',131072),('TheDrummer/Magidonia-24B-v4.3',32768),('TheDrummer/Rocinante-12B-v1.1',16384),('TheDrummer/UnslopNemo-12B-v4.1',8192),('TheDrummer/skyfall-36b-v2',32768),('VongolaChouko/Starcannon-Unleashed-12B-v1.0',16384),('XiaomiMiMo/MiMo-V2-Flash',262144),('XiaomiMiMo/MiMo-V2.5',262144),('XiaomiMiMo/MiMo-V2.5-Pro',1048576),('XiaomiMiMo/MiMo-V2.6-Flash',1048576),('XiaomiMiMo/MiMo-V2.6-Pro',1048576),('ZhipuAI/GLM-4.5',131072),('ZhipuAI/GLM-4.6',202752),('abacusai/Dracarys-72B-Instruct',32768),('abliterated-model',150000),('abliterated-model-large',1000000),('abliterated-model-large-v2',1000000),('abliteration-abliterated-model-large-flash',1000000),('abliteration-abliterated-model-large-v2',1000000),('abliteration-ai/abliterated-model',262144),('abliteration-ai/abliterated-model-large',1000000),('abliteration-ai/abliterated-model-large-flash',1048576),('abliteration-ai/abliterated-model-large-v2',1048576),('accounts/fireworks/models/deepseek-v4p1-flash',1000000),('accounts/fireworks/models/deepseek-v4p1-flash-1017',1000000),('accounts/fireworks/models/ember-1',1048576),('accounts/fireworks/models/glm-5p3',1048573),('accounts/fireworks/models/glm-5p3-flash',1048573),('accounts/fireworks/models/gpt-oss-120b',131072),('accounts/fireworks/models/inkling',1048576),('accounts/fireworks/models/kimi-k3',1048576),('accounts/fireworks/models/minimax-m3',512000),('accounts/fireworks/models/minimax-m3p1-flash',1000000),('accounts/fireworks/models/muse-spark-open',1048576),('accounts/fireworks/models/nemotron-3-ultra-nvfp4',262144),('accounts/fireworks/models/nemotron-lightning-3p5-30b-a3b',262144),('accounts/fireworks/models/qwen3p8-2p4t-a95b',262144),('accounts/fireworks/models/qwen3p8-max',262144),('accounts/fireworks/routers/deepseek-flash-latest',1000000),('accounts/fireworks/routers/deepseek-v4p1-flash-1017-spot',1000000),('accounts/fireworks/routers/deepseek-v4p1-flash-spot',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('accounts/fireworks/routers/glm-5p3-fast',1048572),('accounts/fireworks/routers/glm-5p3-spot',1048573),('accounts/fireworks/routers/glm-fast-latest',1048572),('accounts/fireworks/routers/glm-flash-latest',1048573),('accounts/fireworks/routers/glm-latest',1048573),('accounts/fireworks/routers/kimi-fast-latest',1048576),('accounts/fireworks/routers/kimi-k3-fast',1048576),('accounts/fireworks/routers/kimi-k3-spot',1048576),('accounts/fireworks/routers/kimi-latest',1048576),('accounts/fireworks/routers/minimax-latest',512000),('accounts/fireworks/routers/qwen-max-latest',262144),('agent-max',1000000),('agent-prime',196608),('agnes-2.0-flash',512000),('agnes-2.5-flash',512000),('agnes-2.5-pro-alpha',1000000),('agnes-3.0-flash',512000),('aion-labs-aion-3-5',262144),('aion-labs-aion-3-5-mini',262144),('aion-labs/aion-2.0',131072),('aion-labs/aion-3.0',131072),('aion-labs/aion-3.0-mini',131072),('aion-labs/aion-3.5',262144),('aion-labs/aion-3.5-mini',262144),('aion-labs/aion-rp-llama-3.1-8b',32768),('aisingapore/gemma-sea-lion-v4-27b-it',131072),('aisingapore/qwen-sea-lion-v4-32b-it',131072),('aleph-alpha/kolibri-1',1048576),('alibaba/deepseek-v4-flash',1000000),('alibaba/deepseek-v4-pro',1000000),('alibaba/deepseek-v4.1-flash',1000000),('alibaba/deepseek-v4.1-flash-1017',1000000),('alibaba/glm-5',202752),('alibaba/glm-5.2',1000000),('alibaba/glm-5.3',1048576),('alibaba/kimi-k2.5',262144),('alibaba/kimi-k3',1048576),('alibaba/qwen-3-14b',40960),('alibaba/qwen-3-235b',262144),('alibaba/qwen-3-30b',40960),('alibaba/qwen-flash',1000000),('alibaba/qwen-max',32768),('alibaba/qwen-plus',131072),('alibaba/qwen-plus-latest',1000000),('alibaba/qwen3-coder',262144),('alibaba/qwen3-coder-30b-a3b',262144),('alibaba/qwen3-coder-480b-a35b-instruct',262000),('alibaba/qwen3-coder-flash',997952),('alibaba/qwen3-coder-next',256000),('alibaba/qwen3-embedding-0.6b',32768),('alibaba/qwen3-embedding-4b',32768),('alibaba/qwen3-embedding-8b',32768),('alibaba/qwen3-max',262144),('alibaba/qwen3-max-thinking',256000),('alibaba/qwen3-next-80b-a3b-instruct',262114),('alibaba/qwen3-next-80b-a3b-thinking',262144),('alibaba/qwen3-vl-instruct',262144),('alibaba/qwen3-vl-plus',262144),('alibaba/qwen3.5-122b-a10b',262144),('alibaba/qwen3.5-27b',262144),('alibaba/qwen3.5-35b-a3b',262144),('alibaba/qwen3.5-397b-a17b',262144),('alibaba/qwen3.5-flash',1000000),('alibaba/qwen3.5-plus',1000000),('alibaba/qwen3.6-27b',256000),('alibaba/qwen3.6-35b-a3b',262144),('alibaba/qwen3.6-flash',983616),('alibaba/qwen3.6-plus',983616),('alibaba/qwen3.7-flash',983616),('alibaba/qwen3.7-max',1000000),('alibaba/qwen3.7-plus',1000000),('alibaba/qwen3.8-2.4t-a95b',262144),('alibaba/qwen3.8-27b',1000000),('alibaba/qwen3.8-flash',983616),('alibaba/qwen3.8-max',1000000),('alibaba/qwen3.8-max-0902',991000),('alibaba/qwen3.8-max-prime',1000000),('alibaba/qwen3.8-omni-flash',983616),('alibaba/qwen35-397b-a17b',262144),('alibaba/wan-v2.5-t2v-preview',0),('alibaba/wan-v2.6-i2v',0),('alibaba/wan-v2.6-i2v-flash',0),('alibaba/wan-v2.6-r2v',0),('alibaba/wan-v2.6-r2v-flash',0),('alibaba/wan-v2.6-t2v',0),('alibaba/wan-v2.7-r2v',0),('alibaba/wan-v2.7-t2v',0),('alibaba/wan-v3.0-video',0),('alibaba/wan-v3.0-video-prime',0),('alicloud-deepseek-v4-flash',1000000),('alicloud-deepseek-v4-pro',1000000),('alicloud-glm-5.1',200000),('all-mini-lm-l6-v2',256),('allam-2-7b',4096),('amazon--nova-lite',1000000),('amazon--nova-pro',300000),('amazon--titan-embed-text',8192),('amazon.nova-2-lite-v1:0',1000000),('amazon.nova-lite-v1:0',300000),('amazon.nova-pro-v1:0',300000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('amazon/amazon.nova-lite-v1:0',300000),('amazon/amazon.nova-lite-v1:0@us',300000),('amazon/amazon.nova-pro-v1:0',300000),('amazon/amazon.nova-pro-v1:0@us',300000),('amazon/mistral.voxtral-mini-3b-2507',32768),('amazon/mistral.voxtral-mini-3b-2507@us',32768),('amazon/mistral.voxtral-small-24b-2507',32768),('amazon/mistral.voxtral-small-24b-2507@us',32768),('amazon/moonshot.kimi-k2-thinking',256000),('amazon/moonshotai.kimi-k2.5',262144),('amazon/nova-2-lite',1000000),('amazon/nova-2-lite-v1',1000000),('amazon/nova-lite',300000),('amazon/nova-lite-v1',300000),('amazon/nova-premier-v1',1000000),('amazon/nova-pro',300000),('amazon/nova-pro-v1',300000),('amazon/qwen.qwen3-coder-next',262144),('amazon/titan-embed-text-v2',8192),('amazon/zai.glm-4.7-flash',203000),('amazon/zai.glm-4.7-flash@us',203000),('ambient/large',202752),('ambient/small',101072),('anthracite-org/magnum-v2-72b',16384),('anthracite-org/magnum-v4-72b',32768),('anthropic--claude-3-haiku',200000),('anthropic--claude-4-opus',200000),('anthropic--claude-4-sonnet',200000),('anthropic--claude-4.5-haiku',200000),('anthropic--claude-4.5-opus',200000),('anthropic--claude-4.5-sonnet',200000),('anthropic--claude-4.6-opus',1000000),('anthropic--claude-4.6-sonnet',1000000),('anthropic--claude-4.7-opus',1000000),('anthropic--claude-4.8-opus',1000000),('anthropic-claude-4.5-sonnet',200000),('anthropic-claude-4.6-sonnet',200000),('anthropic-claude-5-sonnet',1000000),('anthropic-claude-5.5-haiku',1000000),('anthropic-claude-fable-5',1000000),('anthropic-claude-fable-5.1',1000000),('anthropic-claude-haiku-4.5',200000),('anthropic-claude-opus-4.5',200000),('anthropic-claude-opus-4.6',200000),('anthropic-claude-opus-4.7',200000),('anthropic-claude-opus-4.8',1000000),('anthropic-claude-opus-5',1000000),('anthropic-claude-opus-5.5',1000000),('anthropic-claude-sonnet-5.5',1000000),('anthropic.claude-fable-5',1000000),('anthropic.claude-fable-5-1',1000000),('anthropic.claude-haiku-4-5-20251001-v1:0',200000),('anthropic.claude-haiku-5-5',1000000),('anthropic.claude-opus-4-1-20250805-v1:0',200000),('anthropic.claude-opus-4-5-20251101-v1:0',200000),('anthropic.claude-opus-4-6-v1',1000000),('anthropic.claude-opus-4-7',1000000),('anthropic.claude-opus-4-8',1000000),('anthropic.claude-opus-5',1000000),('anthropic.claude-opus-5-5',1000000),('anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('anthropic.claude-sonnet-4-6',1000000),('anthropic.claude-sonnet-5',1000000),('anthropic.claude-sonnet-5-5',1000000),('anthropic/claude-fable-5',1000000),('anthropic/claude-fable-5-1',1000000),('anthropic/claude-fable-5.1',1000000),('anthropic/claude-fable-latest',1000000),('anthropic/claude-haiku-3',189096),('anthropic/claude-haiku-3.5',189096),('anthropic/claude-haiku-4-5',200000),('anthropic/claude-haiku-4-5-20251001',200000),('anthropic/claude-haiku-4.5',200000),('anthropic/claude-haiku-4.5:thinking',200000),('anthropic/claude-haiku-5-5',1000000),('anthropic/claude-haiku-5.5',1000000),('anthropic/claude-haiku-latest',1000000),('anthropic/claude-opus-4',192512),('anthropic/claude-opus-4-1-20250805',200000),('anthropic/claude-opus-4-5',200000),('anthropic/claude-opus-4-5-20251101',200000),('anthropic/claude-opus-4-6',200000),('anthropic/claude-opus-4-7',1000000),('anthropic/claude-opus-4-8',1000000),('anthropic/claude-opus-4.1',200000),('anthropic/claude-opus-4.1:thinking',200000),('anthropic/claude-opus-4.1:thinking:1024',200000),('anthropic/claude-opus-4.1:thinking:32768',200000),('anthropic/claude-opus-4.1:thinking:8192',200000),('anthropic/claude-opus-4.5',200000),('anthropic/claude-opus-4.5:thinking',200000),('anthropic/claude-opus-4.6',1000000),('anthropic/claude-opus-4.6:thinking',1000000),('anthropic/claude-opus-4.6:thinking:low',1000000),('anthropic/claude-opus-4.6:thinking:max',1000000),('anthropic/claude-opus-4.6:thinking:medium',1000000),('anthropic/claude-opus-4.7',1000000),('anthropic/claude-opus-4.7:thinking',1000000),('anthropic/claude-opus-4.8',1000000),('anthropic/claude-opus-4.8-fast',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('anthropic/claude-opus-4.8:thinking',1000000),('anthropic/claude-opus-5',1000000),('anthropic/claude-opus-5-5',1000000),('anthropic/claude-opus-5-fast',1000000),('anthropic/claude-opus-5.5',1000000),('anthropic/claude-opus-5.5-fast',1000000),('anthropic/claude-opus-latest',1000000),('anthropic/claude-sonnet-3.5',189096),('anthropic/claude-sonnet-3.5-june',189096),('anthropic/claude-sonnet-3.7',196608),('anthropic/claude-sonnet-4',983040),('anthropic/claude-sonnet-4-5',200000),('anthropic/claude-sonnet-4-5-20250929',200000),('anthropic/claude-sonnet-4-6',200000),('anthropic/claude-sonnet-4.5',1000000),('anthropic/claude-sonnet-4.5:thinking',200000),('anthropic/claude-sonnet-4.6',1000000),('anthropic/claude-sonnet-4.6:thinking',1000000),('anthropic/claude-sonnet-5',1000000),('anthropic/claude-sonnet-5-5',1000000),('anthropic/claude-sonnet-5.5',1000000),('anthropic/claude-sonnet-5.5:thinking',1000000),('anthropic/claude-sonnet-5:thinking',1000000),('anthropic/claude-sonnet-latest',1000000),('apac.amazon.nova-lite-v1:0',300000),('apac.amazon.nova-pro-v1:0',300000),('apac.anthropic.claude-sonnet-4-20250514-v1:0',200000),('apertus-70b',30000),('apodex/apodex-1.1-mini',262144),('arcee-ai/trinity-large-thinking',262144),('arcee_ai/AFM/models/trinity-mini',131072),('arkanecloud/Qwen/Qwen3-235B-A22B-Instruct-2507',262000),('arkanecloud/deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('arkanecloud/deepseek-ai/DeepSeek-V4.1-Flash',1048576),('arkanecloud/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('arkanecloud/meta-llama/Llama-3.1-70B-Instruct',131072),('arkanecloud/meta-llama/Llama-3.1-8B-Instruct',131072),('arkanecloud/ministral-14b',32768),('arkanecloud/nvidia/nemotron-3-super-120b-a12b',256000),('arkanecloud/nvidia/nemotron-3-ultra-550b-a55b',512288),('arkanecloud/openai/gpt-oss-120b',131072),('arkanecloud/openai/gpt-oss-20b',131072),('au.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('au.anthropic.claude-haiku-5-5',1000000),('au.anthropic.claude-opus-4-6-v1',1000000),('au.anthropic.claude-opus-4-7',1000000),('au.anthropic.claude-opus-4-8',1000000),('au.anthropic.claude-opus-5',1000000),('au.anthropic.claude-opus-5-5',1000000),('au.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('au.anthropic.claude-sonnet-4-6',1000000),('au.anthropic.claude-sonnet-5',1000000),('au.anthropic.claude-sonnet-5-5',1000000),('auto',1000000),('auto-model',1000000),('auto-model-basic',1000000),('auto-model-premium',1000000),('auto-model-standard',1000000),('auto/mistralai/ministral-14b-2512',262144),('auto/mistralai/ministral-3b-2512',262144),('auto/mistralai/ministral-8b-2512',262144),('auto/mistralai/mistral-large-2512',262144),('auto/mistralai/mistral-large-4',524288),('auto/mistralai/mistral-medium-3.5',262144),('auto/mistralai/mistral-small-2603',256000),('auto/openai/gpt-4.1',1047576),('auto/openai/gpt-4.1-mini',1047576),('auto/openai/gpt-5',400000),('auto/openai/gpt-5-mini',400000),('auto/openai/gpt-5-nano',400000),('auto/openai/gpt-5.2',400000),('auto/openai/gpt-5.4',1050000),('auto/openai/gpt-5.4-mini',400000),('auto/openai/gpt-5.5',1050000),('auto/openai/gpt-5.6-luna',1050000),('auto/openai/gpt-5.6-sol',1050000),('auto/openai/gpt-5.6-terra',1050000),('auto/openai/gpt-6-astra',1050000),('auto/openai/gpt-6-luna',1050000),('auto/openai/gpt-6-sol',1050000),('auto/openai/gpt-6.1-sol',1050000),('auto/openai/gpt-6.1-terra',1050000),('auto/openai/gpt-oss-120b',131072),('auto/openai/gpt-oss-20b',131072),('auto/openai/gpt-oss-safeguard-120b',131072),('auto/openai/gpt-oss-safeguard-20b',131072),('auto/openai/o3',200000),('aws-bedrock/claude-fable-5',1000000),('aws-bedrock/claude-fable-5-1',1000000),('aws-bedrock/claude-haiku-4-5',200000),('aws-bedrock/claude-haiku-4-5-20251001',200000),('aws-bedrock/claude-haiku-5-5',1000000),('aws-bedrock/claude-opus-4-5-20251101',200000),('aws-bedrock/claude-opus-4-6',1000000),('aws-bedrock/claude-opus-4-7',1000000),('aws-bedrock/claude-opus-4-8',1000000),('aws-bedrock/claude-opus-5',1000000),('aws-bedrock/claude-opus-5-5',1000000),('aws-bedrock/claude-sonnet-4-5',200000),('aws-bedrock/claude-sonnet-4-5-20250929',200000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('aws-bedrock/claude-sonnet-4-6',1000000),('aws-bedrock/claude-sonnet-5',1000000),('aws-bedrock/claude-sonnet-5-5',1000000),('aws-bedrock/grok-4-3',1000000),('aws-bedrock/grok-4-6',500000),('aws-bedrock/grok-4-7',524288),('aws-bedrock/kimi-k3',1048576),('aws-bedrock/llama-4-maverick-17b-instruct',8192),('aws-bedrock/llama-4-scout-17b-instruct',8192),('aws-mantle/gpt-5.6-luna',921600),('aws-mantle/gpt-5.6-sol',921600),('aws-mantle/gpt-5.6-terra',921600),('aws-mantle/gpt-6-astra',1050000),('azure-ai-foundry/grok-4-3',20000),('azure-anthropic/claude-fable-5',1000000),('azure-anthropic/claude-fable-5-1',1000000),('azure-anthropic/claude-opus-4-6',1000000),('azure-anthropic/claude-opus-4-7',1000000),('azure-anthropic/claude-opus-4-8',1000000),('azure-anthropic/claude-opus-5',1000000),('azure-anthropic/claude-opus-5-5',1000000),('azure-anthropic/claude-sonnet-5',1000000),('azure-anthropic/claude-sonnet-5-5',1000000),('azure/gpt-4.1',1000000),('azure/gpt-4.1-mini',1000000),('azure/gpt-4.1-nano',1047576),('azure/gpt-4.1-nano@eu',1047576),('azure/gpt-5',400000),('azure/gpt-5-mini',400000),('azure/gpt-5-nano',400000),('azure/gpt-5-pro',400000),('azure/gpt-5.1',400000),('azure/gpt-5.1-codex',400000),('azure/gpt-5.1-codex-max',272000),('azure/gpt-5.1-codex-mini',400000),('azure/gpt-5.2',400000),('azure/gpt-5.2-codex',400000),('azure/gpt-5.3-codex',400000),('azure/gpt-5.4',1050000),('azure/gpt-5.4-mini',400000),('azure/gpt-5.4-nano',400000),('azure/gpt-5.4-pro',1050000),('azure/gpt-5.5',1050000),('azure/gpt-5.6-luna',1050000),('azure/gpt-5.6-sol',1050000),('azure/gpt-5.6-terra',1050000),('azure/gpt-6-astra',1050000),('azure/gpt-6-luna',1050000),('azure/gpt-6-sol',1050000),('azure/gpt-6.1-sol',1050000),('azure/gpt-6.1-terra',1050000),('azure/gpt-oss-120b',131072),('azure/grok-4-3',200000),('baai/bge-m3',8192),('baai/bge-reranker-v2-m3',8000),('baichuan/baichuan-m2-32b',131072),('baidu/cobuddy',131072),('baidu/deepseek-v4-flash',1048576),('baidu/deepseek-v4-pro',1048576),('baidu/deepseek-v4.1-flash',1048576),('baidu/deepseek-v4.1-flash-1017',1048576),('baidu/ernie-4.5-21B-a3b',120000),('baidu/ernie-4.5-300b-a47b-paddle',123000),('baidu/ernie-4.5-vl-424b-a47b',123000),('baidu/glm-5.1',202752),('baidu/glm-5.2',1048576),('baidu/glm-5.3',1048576),('baidu/glm-5.3-flash',1048576),('baidu/kimi-k3',1048576),('bailian/qwen-flash',1000000),('bailian/qwen-max',32768),('bailian/qwen-plus',1000000),('bailian/qwen-vl-max',131072),('bailian/qwen3-coder-flash',1000000),('bailian/qwen3-coder-next',262144),('bailian/qwen3-coder-plus',1048576),('bailian/qwen3-max',262144),('bailian/qwen3.5-122b-a10b',256000),('bailian/qwen3.5-27b',262144),('bailian/qwen3.5-35b-a3b',262144),('bailian/qwen3.5-397b-a17b',256000),('bailian/qwen3.5-flash',1000000),('bailian/qwen3.5-plus',1000000),('bailian/qwen3.6-27b',256000),('bailian/qwen3.6-flash',1000000),('bailian/qwen3.6-max-preview',262144),('bailian/qwen3.6-plus',1000000),('bailian/qwen3.7-max',1000000),('bailian/qwen3.7-plus',1000000),('bailian/qwen3.8-27b',1131072),('bailian/qwen3.8-flash',1000000),('bailian/qwen3.8-max',1000000),('bailian/qwen3.8-max-0902',1000000),('baseten/Kimi-K2-Instruct-FP4',131072),('beam',1048576),('beam-free',1048576),('bee-brood',262144),('bee-buzz',262144),('bee-cell',131072),('bee-comb',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('bee-hive',262144),('bee-swarm',1000000),('bfl/flux-2-flex',0),('bfl/flux-2-klein-4b',0),('bfl/flux-2-klein-9b',0),('bfl/flux-2-max',67300),('bfl/flux-2-pro',67300),('bfl/flux-3-image',0),('bfl/flux-3-image-klein',0),('bfl/flux-3-video',0),('bfl/flux-kontext-max',512),('bfl/flux-kontext-pro',512),('bfl/flux-pro-1.0-fill',512),('bfl/flux-pro-1.1',512),('bfl/flux-pro-1.1-ultra',512),('bge-m3',8192),('bge-multilingual-gemma2',8191),('bge-reranker-v2-m3',8192),('bge_multilingual_gemma2',8000),('big-pickle',200000),('black-forest-labs/FLUX.2-klein-4B',0),('black-forest-labs/flux.1-dev',0),('black-forest-labs/flux_1-kontext-dev',0),('black-forest-labs/flux_1-schnell',0),('black-forest-labs/flux_2-klein-4b',0),('brick-complexity-pro',100000),('brick-v1-beta',100000),('bytedance-pro-latest',262144),('bytedance-seed/seed-1.6',262144),('bytedance-seed/seed-1.6-flash',262144),('bytedance-seed/seed-2-1-turbo',262144),('bytedance-seed/seed-2.0-code',262144),('bytedance-seed/seed-2.0-lite',262144),('bytedance-seed/seed-2.0-mini',262144),('bytedance/deepseek-v3.2',131072),('bytedance/deepseek-v4-flash',1048576),('bytedance/deepseek-v4-pro',1048576),('bytedance/dola-seed-2.0-code',256000),('bytedance/dola-seed-2.0-code-preview',131072),('bytedance/dola-seed-2.0-lite',256000),('bytedance/dola-seed-2.0-mini',256000),('bytedance/dola-seed-2.0-pro',256000),('bytedance/doubao-seed-1.8',256000),('bytedance/doubao-seed-2.0-code',256000),('bytedance/doubao-seed-2.0-lite',256000),('bytedance/doubao-seed-2.0-mini',256000),('bytedance/doubao-seed-2.0-pro',256000),('bytedance/doubao-seed-2.1-pro',256000),('bytedance/doubao-seed-2.1-turbo',256000),('bytedance/doubao-seed-code',256000),('bytedance/glm-4.7',200000),('bytedance/glm-5.2',1024000),('bytedance/seed-1-6-250615',256000),('bytedance/seed-1-6-250915',256000),('bytedance/seed-1-6-flash-250715',256000),('bytedance/seed-1-8-251228',256000),('bytedance/seed-1.6',256000),('bytedance/seed-1.8',256000),('bytedance/seed-2-0-code-preview-260328',262144),('bytedance/seed-2-0-lite-260428',262144),('bytedance/seed-2-0-mini-260428',262144),('bytedance/seed-2-0-pro-260328',262144),('bytedance/seed-2.1-turbo',262144),('bytedance/seedance-2',4096),('bytedance/seedance-2.0',0),('bytedance/seedance-2.0-fast',0),('bytedance/seedance-2.0-mini',0),('bytedance/seedance-2.5',0),('bytedance/seedance-v1.0-pro',0),('bytedance/seedance-v1.0-pro-fast',0),('bytedance/seedance-v1.5-pro',0),('bytedance/seedream-4.0',0),('bytedance/seedream-4.5',0),('bytedance/seedream-5.0-lite',0),('bytedance/seedream-5.0-pro',0),('c4ai-aya-vision-32b',16000),('ca.amazon.nova-lite-v1:0',300000),('callstack/apex',262144),('canopylabs/orpheus-arabic-saudi',4000),('canopylabs/orpheus-v1-english',4000),('canopywave/deepseek-v4-flash',1000000),('canopywave/deepseek-v4-pro',1000000),('canopywave/glm-5.2',200000),('canopywave/kimi-k2.6',262144),('canopywave/kimi-k3',1048576),('cat-jam-free',1048576),('celeris-1',8192),('cerebras/gpt-oss-120b',131072),('cerebras/llama-3.3-70b-cs',0),('cerebras/qwen-3.8-27b',131072),('cerebras/qwen3-235b-2507-cs',0),('cerebras/qwen3-32b-cs',0),('chatgpt-image-latest',0),('clarifai/main/models/mm-poly-8b',32768),('claude-3-5-haiku',200000),('claude-3-7-sonnet-20250219',200000),('claude-3-haiku-20240307',200000),('claude-3.5-haiku',200000),('claude-3.5-sonnet',200000),('claude-3.5-sonnet-v2',200000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('claude-3.7-sonnet',200000),('claude-4-5-sonnet',200000),('claude-4-6-sonnet',1000000),('claude-4.0-opus',200000),('claude-4.0-sonnet',200000),('claude-4.1-opus',200000),('claude-4.5-haiku',200000),('claude-4.5-opus',200000),('claude-4.5-sonnet',200000),('claude-fable-5',1000000),('claude-fable-5-1',1000000),('claude-fable-5-1@default',1000000),('claude-fable-5.1',1000000),('claude-fable-5.1@eu',1000000),('claude-fable-5@default',1000000),('claude-fable-5@eu',1000000),('claude-haiku-4-5',200000),('claude-haiku-4-5-20251001',200000),('claude-haiku-4-5@20251001',200000),('claude-haiku-4-5@eu',200000),('claude-haiku-4.5',200000),('claude-haiku-5-5',1000000),('claude-haiku-5-5@default',1000000),('claude-haiku-5-5@eu',1000000),('claude-haiku-5.5',1000000),('claude-mythos-5',1000000),('claude-opus-4',200000),('claude-opus-4-1',200000),('claude-opus-4-1-20250805',200000),('claude-opus-4-1-20250805-thinking',200000),('claude-opus-4-1@20250805',200000),('claude-opus-4-20250514',200000),('claude-opus-4-5',200000),('claude-opus-4-5-20251101',200000),('claude-opus-4-5-think',200000),('claude-opus-4-5@20251101',200000),('claude-opus-4-5@eu',200000),('claude-opus-4-6',1000000),('claude-opus-4-6-think',1000000),('claude-opus-4-6@default',1000000),('claude-opus-4-6@eu',1000000),('claude-opus-4-7',1000000),('claude-opus-4-7-think',1000000),('claude-opus-4-7-thinking',1000000),('claude-opus-4-7@default',1000000),('claude-opus-4-7@eu',1000000),('claude-opus-4-8',1000000),('claude-opus-4-8-fast',1000000),('claude-opus-4-8-think',1000000),('claude-opus-4-8@default',1000000),('claude-opus-4-8@eu',1000000),('claude-opus-4.7',200000),('claude-opus-4.8',1000000),('claude-opus-4@20250514',200000),('claude-opus-5',1000000),('claude-opus-5-5',1000000),('claude-opus-5-5-fast',1000000),('claude-opus-5-5@default',1000000),('claude-opus-5-5@eu',1000000),('claude-opus-5-fast',1000000),('claude-opus-5-thinking',1000000),('claude-opus-5.5',1000000),('claude-opus-5@default',1000000),('claude-opus-5@eu',1000000),('claude-opus-latest',1000000),('claude-opus4-5',200000),('claude-opus4-6',1000000),('claude-opus4-7',1000000),('claude-opus4-8',1000000),('claude-sonnet-4',1000000),('claude-sonnet-4-20250514',200000),('claude-sonnet-4-5',200000),('claude-sonnet-4-5-20250929',200000),('claude-sonnet-4-5-20250929-thinking',200000),('claude-sonnet-4-5-think',200000),('claude-sonnet-4-5@20250929',200000),('claude-sonnet-4-5@eu',1000000),('claude-sonnet-4-6',1000000),('claude-sonnet-4-6-think',1000000),('claude-sonnet-4-6-thinking',1000000),('claude-sonnet-4-6@default',1000000),('claude-sonnet-4-6@eu',1000000),('claude-sonnet-4.6',200000),('claude-sonnet-4@20250514',200000),('claude-sonnet-4@eu',1000000),('claude-sonnet-5',1000000),('claude-sonnet-5-5',1000000),('claude-sonnet-5-5@default',1000000),('claude-sonnet-5-5@eu',1000000),('claude-sonnet-5.5',1000000),('claude-sonnet-5@default',1000000),('claude-sonnet-5@eu',1000000),('claudinio',256000),('claudius',256000),('claw-high',1048576),('claw-low',1048576),('claw-medium',1048576),('cline-pass/deepseek-v4-flash',1000000),('cline-pass/deepseek-v4-pro',1000000),('cline-pass/deepseek-v4.1-flash',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('cline-pass/glm-5.2',1000000),('cline-pass/glm-5.3',1000000),('cline-pass/glm-5.3-flash',1000000),('cline-pass/kimi-k2.6',262144),('cline-pass/kimi-k2.7-code',262144),('cline-pass/kimi-k3',1048576),('cline-pass/mimo-v2.5',1048576),('cline-pass/mimo-v2.5-pro',1048576),('cline-pass/mimo-v2.6-flash',1048576),('cline-pass/mimo-v2.6-pro',1048576),('cline-pass/minimax-m3',1048576),('cline-pass/muse-spark-1.3-contributor',1048576),('cline-pass/qwen3.7-max',1000000),('cline-pass/qwen3.7-plus',1000000),('cline-pass/qwen3.8-max',1000000),('cloudflare/@cf/deepseek-ai/deepseek-v4-flash-0731',1048576),('cloudflare/@cf/deepseek-ai/deepseek-v4-pro-0813',1048576),('cloudflare/@cf/deepseek-ai/deepseek-v4.1-flash-1017',1048576),('cloudflare/@cf/meta/llama-3.2-1b-instruct',60000),('cloudflare/@cf/meta/llama-3.2-3b-instruct',80000),('cloudflare/@cf/meta/llama-guard-3-8b',131072),('cloudflare/@cf/qwen/qwen2.5-coder-32b-instruct',32768),('cloudflare/@cf/zai-org/glm-4.7-flash',131072),('cloudflare/deepseek-v4-flash',1048576),('cloudflare/deepseek-v4-pro',1048576),('cloudflare/deepseek-v4.1-flash-1017',1048576),('cloudflare/glm-5.3',1048576),('cloudflare/glm-5.3-flash',1048576),('code-max',1000000),('code-prime',196608),('codestral-2501',256000),('codestral-2508',256000),('codestral-latest',256000),('codex-mini',200000),('coding-glm-5.1',200000),('coding-glm-5.1-free',200000),('coding-glm-5.2-free',1000000),('coding-glm-5.3-flash-free',1000000),('coding-glm-5.3-free',1000000),('coding-minimax-m2.7',204800),('coding-minimax-m2.7-free',204800),('coding-minimax-m2.7-highspeed',204800),('coding-xiaomi-mimo-v2.5',1048576),('coding-xiaomi-mimo-v2.5-pro',1048576),('cohere--command-a-reasoning',256000),('cohere-command-a',131072),('cohere-embed-v3-english',512),('cohere-embed-v3-multilingual',512),('cohere/command-a',256000),('cohere/command-a-03-2025',288000),('cohere/command-a-plus',192000),('cohere/north-mini-code:free',256000),('cohere/rerank-v3.5',4096),('cohere/rerank-v4-fast',32000),('cohere/rerank-v4-pro',32000),('cohere/rerank-v5-fast',32768),('cohere/rerank-v5-pro',32768),('command-a-03-2025',256000),('command-a-reasoning-08-2025',256000),('command-a-translate-08-2025',8000),('consensusprotocol/Qwen3.8-27B',262000),('consensusprotocol/deepseek-v4-flash',1000000),('consensusprotocol/deepseek-v4.1-flash',1048576),('consensusprotocol/gemma-4-31b-it',262144),('consensusprotocol/glm-5.3-flash',1048576),('consensusprotocol/mimo-v2.6-flash',1048576),('consensusprotocol/minimax-m3',1048576),('crouton-alpha-free',1048576),('databricks-claude-haiku-4-5',200000),('databricks-claude-opus-4-1',200000),('databricks-claude-opus-4-5',200000),('databricks-claude-opus-4-6',1000000),('databricks-claude-opus-4-7',1000000),('databricks-claude-sonnet-4',200000),('databricks-claude-sonnet-4-5',200000),('databricks-claude-sonnet-4-6',1000000),('databricks-gemini-2-5-flash',1048576),('databricks-gemini-2-5-pro',1048576),('databricks-gemini-3-1-flash-lite',1048576),('databricks-gemini-3-1-pro',1048576),('databricks-gemini-3-5-flash',1048576),('databricks-gemini-3-flash',1048576),('databricks-gemini-3-pro',1048576),('databricks-glm-5-2',1000000),('databricks-gpt-5',400000),('databricks-gpt-5-1',400000),('databricks-gpt-5-2',400000),('databricks-gpt-5-4',1050000),('databricks-gpt-5-4-mini',400000),('databricks-gpt-5-4-nano',400000),('databricks-gpt-5-5',1050000),('databricks-gpt-5-6-luna',1050000),('databricks-gpt-5-6-sol',1050000),('databricks-gpt-5-6-terra',1050000),('databricks-gpt-5-mini',400000),('databricks-gpt-5-nano',400000),('databricks-gpt-oss-120b',131072),('databricks-gpt-oss-20b',131072),('databricks-kimi-k2-7-code',262144),('databricks/databricks-deepseek-v4-flash-0731',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('databricks/databricks-gpt-oss-120b',131072),('databricks/databricks-gpt-oss-120b@eu',131072),('databricks/databricks-gpt-oss-20b',131072),('databricks/databricks-gpt-oss-20b@eu',131072),('databricks/databricks-qwen3-next-80b-a3b-instruct',262144),('databricks/databricks-qwen3-next-80b-a3b-instruct@eu',262144),('deep-deepseek-v4-flash',1000000),('deep-deepseek-v4-pro',1000000),('deep-research-max-preview-04-2026',131072),('deep-research-preview-04-2026',131072),('deepinfra/ByteDance/Seed-2.0-code',256000),('deepinfra/ByteDance/Seed-2.0-mini',256000),('deepinfra/Gryphe/MythoMax-L2-13b',4096),('deepinfra/NousResearch/Hermes-3-Llama-3.1-405B',131072),('deepinfra/NousResearch/Hermes-3-Llama-3.1-70B',131072),('deepinfra/Qwen/Qwen2.5-7B-Instruct',32768),('deepinfra/Qwen/Qwen3-235B-A22B-Instruct-2507',262144),('deepinfra/Qwen/Qwen3-235B-A22B-Thinking-2507',262144),('deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct',262144),('deepinfra/Qwen/Qwen3-Max',256000),('deepinfra/Qwen/Qwen3-Next-80B-A3B-Instruct',262144),('deepinfra/Qwen/Qwen3-VL-235B-A22B-Instruct',262144),('deepinfra/Qwen/Qwen3-VL-30B-A3B-Instruct',262144),('deepinfra/deepseek-ai/DeepSeek-R1',163840),('deepinfra/deepseek-ai/DeepSeek-R1-0528',163840),('deepinfra/deepseek-ai/DeepSeek-V3',163840),('deepinfra/deepseek-ai/DeepSeek-V3-0324',163840),('deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('deepinfra/deepseek-ai/DeepSeek-V4-Pro-0813',1048576),('deepinfra/deepseek-ai/DeepSeek-V4.1-Flash',1048576),('deepinfra/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('deepinfra/deepseek-v3.2',160000),('deepinfra/deepseek-v4-flash',1000000),('deepinfra/deepseek-v4-pro',1048576),('deepinfra/deepseek-v4.1-flash',1048576),('deepinfra/deepseek-v4.1-flash-1017',1048576),('deepinfra/gemma-4-26b-a4b-it',262144),('deepinfra/gemma-4-31b-it',262144),('deepinfra/google/gemma-3-12b-it',131072),('deepinfra/google/gemma-3-27b-it',131072),('deepinfra/google/gemma-3-4b-it',131072),('deepinfra/granite-4.2-8b',131072),('deepinfra/ibm-granite/granite-4.2-8b',131072),('deepinfra/ling-3.0-flash',262144),('deepinfra/ling-3.0-flash-vl',131072),('deepinfra/meta-llama/Llama-3.2-11B-Vision-Instruct',131072),('deepinfra/meta-llama/Llama-3.2-3B-Instruct',131072),('deepinfra/meta-llama/Llama-3.3-70B-Instruct',131072),('deepinfra/meta-llama/Llama-Guard-3-8B',131072),('deepinfra/meta-llama/Llama-Guard-4-12B',163840),('deepinfra/meta-models/Muse-Glimmer-30B',131072),('deepinfra/microsoft/WizardLM-2-8x22B',65536),('deepinfra/mimo-v2.6-flash',1048576),('deepinfra/mimo-v2.6-pro',1048576),('deepinfra/mistralai/Mistral-Small-24B-Instruct-2501',32768),('deepinfra/mistralai/Mixtral-8x7B-Instruct-v0.1',32768),('deepinfra/moonshotai/Kimi-K2-Instruct',131072),('deepinfra/moonshotai/Kimi-K2.5',262144),('deepinfra/muse-glimmer-30b',131072),('deepinfra/nemotron-3-super-120b-a12b',262144),('deepinfra/nemotron-3-ultra-550b',262144),('deepinfra/nemotron-3-ultra-550b-a55b',262144),('deepinfra/nvidia/Llama-3.1-Nemotron-70B-Instruct',131072),('deepinfra/nvidia/Nemotron-3-Nano-30B-A3B',262144),('deepinfra/openai/gpt-oss-120b',131072),('deepinfra/openai/gpt-oss-20b',131072),('deepinfra/qwen3-vl-235b-a22b-instruct',262144),('deepinfra/qwen3-vl-30b-a3b-instruct',262144),('deepinfra/qwen3.5-9b',262144),('deepinfra/stepfun-ai/Step-3.5-Flash',262144),('deepinfra/stepfun-ai/Step-3.7-Flash',262144),('deepinfra/stepfun-ai/Step-5-Preview',1048576),('deepinfra/tencent/Hy3',262144),('deepinfra/tencent/Hy4-preview',1048576),('deepinfra/thinkingmachines/Inkling',524288),('deepinfra/thinkingmachines/Inkling-Small',524288),('deepinfra/zai-org/GLM-4.7-Flash',202752),('deepseek-3.2',163840),('deepseek-4-flash',1048576),('deepseek-ai/DeepSeek-OCR',8192),('deepseek-ai/DeepSeek-R1',164000),('deepseek-ai/DeepSeek-V3',164000),('deepseek-ai/DeepSeek-V3-0324',163840),('deepseek-ai/DeepSeek-V3-1',131072),('deepseek-ai/DeepSeek-V3.1',164000),('deepseek-ai/DeepSeek-V3.1-Terminus',164000),('deepseek-ai/DeepSeek-V3.2',164000),('deepseek-ai/DeepSeek-V3.2-Exp',164000),('deepseek-ai/DeepSeek-V3.2-TEE',131072),('deepseek-ai/DeepSeek-V4-Flash',1048575),('deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('deepseek-ai/DeepSeek-V4-Flash-0731-TEE',1048576),('deepseek-ai/DeepSeek-V4-Flash-Vision-Exp',1000000),('deepseek-ai/DeepSeek-V4-Pro',1048576),('deepseek-ai/DeepSeek-V4-Pro-0813',1000000),('deepseek-ai/DeepSeek-V4.1-Flash',1048576),('deepseek-ai/DeepSeek-V4.1-Flash-1017',1000000),('deepseek-ai/DeepSeek-V4.1-Flash-1017-Fast',1048576),('deepseek-ai/DeepSeek-V4.1-Flash-1017-abliterated',1048576),('deepseek-ai/DeepSeek-V4.1-Flash-1017:peft:262144',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('deepseek-ai/DeepSeek-V4.1-Flash-Fast',1048576),('deepseek-ai/DeepSeek-V4.1-Flash:peft:262144',262144),('deepseek-ai/deepseek-ocr/models/DeepSeek-OCR',8192),('deepseek-ai/deepseek-v3.1-maas',163840),('deepseek-ai/deepseek-v3.2-exp',163840),('deepseek-ai/deepseek-v3.2-exp-thinking',163840),('deepseek-ai/deepseek-v3.2-maas',163840),('deepseek-ai/deepseek-v4-flash',1048576),('deepseek-ai/deepseek-v4-flash-0731',1000000),('deepseek-ai/deepseek-v4-pro',1048576),('deepseek-ai/deepseek-v4.1-flash',1048576),('deepseek-ai/deepseek-v4.1-flash-1017',1048576),('deepseek-flash',1048576),('deepseek-ocr-2',8192),('deepseek-pro-latest',1000000),('deepseek-r1-distill-llama-8b',32768),('deepseek-r1-distill-qwen-1-5b',32768),('deepseek-r1-distill-qwen-14b',32768),('deepseek-r1-distill-qwen-32b',32768),('deepseek-r1-distill-qwen-7b',32768),('deepseek-tng-r1t2-chimera',130000),('deepseek-v3-1',131072),('deepseek-v3-2-exp',131072),('deepseek-v3.2',163840),('deepseek-v4-1-flash',1000000),('deepseek-v4-1-flash-1017',1000000),('deepseek-v4-1-flash-1017-uncensored',1000000),('deepseek-v4-1-flash-uncensored',1000000),('deepseek-v4-flash',1000000),('deepseek-v4-flash-0731',1048576),('deepseek-v4-flash-0731-fast',1000000),('deepseek-v4-flash-0731@eu',1048576),('deepseek-v4-flash-flex',1048560),('deepseek-v4-flash-free',200000),('deepseek-v4-flash-ga-260731',1000000),('deepseek-v4-flash-speed',1048560),('deepseek-v4-flash-vision-exp',1000000),('deepseek-v4-flash:free',1000000),('deepseek-v4-pro',1000000),('deepseek-v4-pro-0813',1000000),('deepseek-v4-pro-0813@eu',1048576),('deepseek-v4-pro-fast',1048576),('deepseek-v4-pro-ga-260813',1000000),('deepseek-v4-pro:0813',1048576),('deepseek-v4-pro:free',1000000),('deepseek-v4-pro@eu',1048576),('deepseek-v4.1-flash',1000000),('deepseek-v4.1-flash-1017',1050000),('deepseek-v4.1-flash-1017-abliterated',1048576),('deepseek-v4.1-flash-1017@eu',1048576),('deepseek-v4.1-flash-552b',1048576),('deepseek-v4.1-flash-cyber',1040000),('deepseek-v4.1-flash-fast',1048576),('deepseek-v4.1-flash-flex',1048560),('deepseek-v4.1-flash-free',200000),('deepseek-v4.1-flash:1017',1048576),('deepseek-v4.1-flash:fast',1000000),('deepseek-v4.1-flash@eu',1048576),('deepseek.v3-v1:0',163840),('deepseek.v3.2',163840),('deepseek/deepseek-chat',163840),('deepseek/deepseek-chat-v3-0324',163840),('deepseek/deepseek-chat-v3.1',163840),('deepseek/deepseek-flash',1000000),('deepseek/deepseek-latest',1048576),('deepseek/deepseek-math-v2',160000),('deepseek/deepseek-ocr-2',8192),('deepseek/deepseek-r1-0528',163840),('deepseek/deepseek-r1-turbo',64000),('deepseek/deepseek-reasoner',1000000),('deepseek/deepseek-v3',163840),('deepseek/deepseek-v3-0324',163840),('deepseek/deepseek-v3.1-terminus',163840),('deepseek/deepseek-v3.2',163840),('deepseek/deepseek-v3.2-exp',163840),('deepseek/deepseek-v3.2:thinking',163000),('deepseek/deepseek-v4-flash',1048576),('deepseek/deepseek-v4-flash-0423',1000000),('deepseek/deepseek-v4-flash-0423:thinking',1048576),('deepseek/deepseek-v4-flash-0731',1048576),('deepseek/deepseek-v4-flash-0731-fast',1000000),('deepseek/deepseek-v4-flash-0731:thinking',1048576),('deepseek/deepseek-v4-flash-fast',1000000),('deepseek/deepseek-v4-flash-free',1000000),('deepseek/deepseek-v4-flash-latest',1048576),('deepseek/deepseek-v4-flash-vision-exp',1048576),('deepseek/deepseek-v4-flash:thinking',1048576),('deepseek/deepseek-v4-pro',1048576),('deepseek/deepseek-v4-pro-0423',1000000),('deepseek/deepseek-v4-pro-0813',1048576),('deepseek/deepseek-v4-pro-0813:thinking',1048576),('deepseek/deepseek-v4-pro:thinking',1048576),('deepseek/deepseek-v4.1-flash',1048576),('deepseek/deepseek-v4.1-flash-0910-uncensored',524288),('deepseek/deepseek-v4.1-flash-0910-uncensored:thinking',524288),('deepseek/deepseek-v4.1-flash-1017',1048576),('deepseek/deepseek-v4.1-flash-1017-fast',1048576),('deepseek/deepseek-v4.1-flash-1017-uncensored',1048576),('deepseek/deepseek-v4.1-flash-1017-uncensored:thinking',1048576),('deepseek/deepseek-v4.1-flash-1017:thinking',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('deepseek/deepseek-v4.1-flash-fast',1048576),('deepseek/deepseek-v4.1-flash-uncensored',1048576),('deepseek/deepseek-v4.1-flash-uncensored:thinking',1048576),('deepseek/deepseek-v4.1-flash:thinking',1048576),('deepseek/deepseek_v3',64000),('devstral-2-123b-instruct-2512',200000),('devstral-2512',262144),('devstral-latest',256000),('devstral-latest@eu',256000),('devstral-medium-latest',262144),('dots-studio/dots-3-note-preview:free',512000),('doubao-seed-1-6-251015',256000),('doubao-seed-1-6-flash-250828',256000),('doubao-seed-1-6-thinking-250715',256000),('doubao-seed-1-6-vision-250815',256000),('doubao-seed-1-8-251215',224000),('doubao-seed-1-8-251228',256000),('doubao-seed-1.6',256000),('doubao-seed-1.6-flash',256000),('doubao-seed-1.6-thinking',256000),('doubao-seed-2-0-code-preview',256000),('doubao-seed-2-0-code-preview-260215',262144),('doubao-seed-2-0-lite-260215',256000),('doubao-seed-2-0-lite-260428',256000),('doubao-seed-2-0-mini-260215',256000),('doubao-seed-2-0-mini-260428',256000),('doubao-seed-2-0-pro',256000),('doubao-seed-2-0-pro-260215',256000),('doubao-seed-2-1-pro-260628',256000),('doubao-seed-2-1-turbo-260628',256000),('doubao-seed-2.0-code',256000),('doubao-seed-2.0-lite',256000),('doubao-seed-2.0-mini',256000),('doubao-seed-2.0-pro',256000),('doubao-seed-2.1-turbo',256000),('doubao-seed-character-260628',256000),('doubao-seed-evolving',256000),('dsv4',1048576),('duo-chat-fable-5',1000000),('duo-chat-fable-5-1',1000000),('duo-chat-gpt-5-1',400000),('duo-chat-gpt-5-2',400000),('duo-chat-gpt-5-2-codex',400000),('duo-chat-gpt-5-3-codex',400000),('duo-chat-gpt-5-4',1050000),('duo-chat-gpt-5-4-mini',400000),('duo-chat-gpt-5-4-nano',400000),('duo-chat-gpt-5-5',1050000),('duo-chat-gpt-5-6-luna',1050000),('duo-chat-gpt-5-6-sol',1050000),('duo-chat-gpt-5-6-terra',1050000),('duo-chat-gpt-5-codex',400000),('duo-chat-gpt-5-mini',400000),('duo-chat-gpt-6-1-sol',1050000),('duo-chat-gpt-6-astra',1050000),('duo-chat-gpt-6-luna',1050000),('duo-chat-gpt-6-sol',1050000),('duo-chat-haiku-4-5',200000),('duo-chat-haiku-5-5',1000000),('duo-chat-opus-4-5',200000),('duo-chat-opus-4-6',1000000),('duo-chat-opus-4-7',1000000),('duo-chat-opus-4-8',1000000),('duo-chat-opus-5',1000000),('duo-chat-opus-5-5',1000000),('duo-chat-sonnet-4-5',200000),('duo-chat-sonnet-4-6',1000000),('duo-chat-sonnet-5',1000000),('duo-chat-sonnet-5-5',1000000),('e5-large-v2',512),('echo',262144),('elevenlabs/elevenlabs-music',2000),('elorian/glimpse',262144),('empiriolabs/deepseek-v4-flash-el',1000000),('empiriolabs/deepseek-v4-pro-el',1000000),('entrim/deepseek-v4.1-flash-1017',1048576),('entrim/glm-5.3',1048576),('entrim/glm-5.3-flash',1048576),('ernie-5.1',119000),('ernie-5.1:thinking',119000),('essentialai/Rnj-1-Instruct',32768),('eu.amazon.nova-2-lite-v1:0',1000000),('eu.amazon.nova-lite-v1:0',300000),('eu.amazon.nova-pro-v1:0',300000),('eu.anthropic.claude-fable-5',1000000),('eu.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('eu.anthropic.claude-haiku-5-5',1000000),('eu.anthropic.claude-opus-4-5-20251101-v1:0',200000),('eu.anthropic.claude-opus-4-6-v1',1000000),('eu.anthropic.claude-opus-4-7',1000000),('eu.anthropic.claude-opus-4-8',1000000),('eu.anthropic.claude-opus-5',1000000),('eu.anthropic.claude-opus-5-5',1000000),('eu.anthropic.claude-sonnet-4-20250514-v1:0',200000),('eu.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('eu.anthropic.claude-sonnet-4-6',1000000),('eu.anthropic.claude-sonnet-5',1000000),('eu.anthropic.claude-sonnet-5-5',1000000),('evroc/roc',262144),('exo-free',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('failspy/Meta-Llama-3-70B-Instruct-abliterated-v3.5',8192),('fal-ai/elevenlabs/tts/multilingual-v2',0),('fal-ai/fast-sdxl',0),('fal-ai/flux/schnell',0),('fal-ai/stable-audio-25/text-to-audio',0),('faster-whisper-large-v3',448),('fastgpt',32768),('fastino/GLiNER-2.5-Decide',8192),('fastino/gliguard-LLMGuardrails-300M',8192),('fastino/gliguard-PII-multi',8192),('fastino/gliner2-base-v1',2048),('fastino/gliner2-large-v1',8192),('fastino/gliner2-multi-large-v1',8192),('fastino/gliner2-multi-v1',8192),('fastino/gliner2-privacy-filter-PII-multi',8192),('fastino/gliner2.5-base-v1',4096),('fastino/gliner2.5-multi-v1',4096),('featherless-ai/Qwerky-72B',32000),('fireworks-ai/kimi-k2.5-fw',262144),('fireworks/deepseek-v4.1-flash',1048576),('fireworks/ember-1',1048576),('fireworks/glm-5.2',1000000),('fireworks/glm-5.3',1048576),('fireworks/glm-5.3-flash',1048576),('fireworks/gpt-oss-120b',131072),('fireworks/gpt-oss-20b',131072),('fireworks/kimi-k3',1040384),('fireworks/kimi-k3-fast',1040384),('fireworks_ai/accounts/fireworks/models/ember-1',1048576),('fireworks_ai/accounts/fireworks/models/gpt-oss-120b',131072),('fireworks_ai/accounts/fireworks/models/inkling',1048576),('fireworks_ai/accounts/fireworks/models/muse-spark-open',1048576),('fireworks_ai/gpt-oss-120b',131072),('fish-audio/drama-3',0),('fish-audio/s1',0),('fish-audio/s2-pro',0),('fish-audio/s2.1-pro',0),('fish-audio/transcribe-1',0),('fledge-alpha-free',1048576),('flexai/DeepSeek-V4-Flash-0731',1048576),('flexai/DeepSeek-V4-Flash-0731@eu',1048576),('flexai/DeepSeek-V4.1-Flash-1017',1048576),('flexai/Muse-Glimmer-30B',131072),('flexai/Step-3.7-Flash',262144),('flexai/deepseek-v4-flash',1048576),('flexai/deepseek-v4.1-flash-1017',1048576),('flexai/glm-5.2',1048576),('flexai/glm-5.3-flash',1048576),('flexai/gpt-oss-120b',131072),('flexai/gpt-oss-20b',131072),('flint-40b-free',262144),('fugu',1000000),('fugu-max',1000000),('fugu-ultra',1000000),('fugu-ultra-20260615',1000000),('fugu-ultra-v1-0',1000000),('fugu-ultra-v1-1',1000000),('fugu-ultra-v2-0',1000000),('fugu-ultra-v2.0',1000000),('gemini-2-5-flash',1048576),('gemini-2-5-flash-lite',1048576),('gemini-2.0-flash',1048576),('gemini-2.0-flash-lite',1048576),('gemini-2.0-pro-exp-02-05',2097152),('gemini-2.5-flash',1048576),('gemini-2.5-flash-image',32768),('gemini-2.5-flash-lite',1048576),('gemini-2.5-flash-lite-preview-06-17',1048576),('gemini-2.5-flash-lite-preview-09-2025',1000000),('gemini-2.5-flash-lite-preview-09-2025-thinking',1048576),('gemini-2.5-flash-lite@eu',1048576),('gemini-2.5-flash-nothink',1000000),('gemini-2.5-flash-nothinking',1048576),('gemini-2.5-flash-preview-04-17',1048576),('gemini-2.5-flash-preview-04-17:thinking',1048576),('gemini-2.5-flash-preview-05-20',1048576),('gemini-2.5-flash-preview-05-20:thinking',1048000),('gemini-2.5-flash-preview-09-2025',1000000),('gemini-2.5-flash-preview-09-2025-thinking',1048576),('gemini-2.5-flash-preview-tts',8192),('gemini-2.5-flash-tts',32768),('gemini-2.5-flash@eu',1048576),('gemini-2.5-pro',1048576),('gemini-2.5-pro-exp-03-25',1048576),('gemini-2.5-pro-preview-03-25',1048576),('gemini-2.5-pro-preview-05-06',1048576),('gemini-2.5-pro-preview-06-05',1048576),('gemini-2.5-pro-preview-tts',8192),('gemini-2.5-pro-tts',32768),('gemini-2.5-pro@eu',1048576),('gemini-3-1-flash-lite',1048576),('gemini-3-1-flash-tts',8192),('gemini-3-1-pro',1048576),('gemini-3-1-pro-preview',1000000),('gemini-3-5-flash',1048576),('gemini-3-5-flash-lite',1048576),('gemini-3-6-flash',1048576),('gemini-3-7-flash',1048576),('gemini-3-8-flash',1048576),('gemini-3-flash',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('gemini-3-flash-preview',1048576),('gemini-3-pro',1048576),('gemini-3-pro-image',65536),('gemini-3-pro-image-preview',65536),('gemini-3-pro-preview',1000000),('gemini-3.0-flash-preview',1000000),('gemini-3.0-pro-image-preview',32768),('gemini-3.0-pro-preview',1000000),('gemini-3.1-flash-image',1048576),('gemini-3.1-flash-image-preview',1048576),('gemini-3.1-flash-lite',1048576),('gemini-3.1-flash-lite-image',65536),('gemini-3.1-flash-lite-preview',1048576),('gemini-3.1-flash-lite@eu',1048576),('gemini-3.1-flash-live-preview',131072),('gemini-3.1-flash-tts-preview',8192),('gemini-3.1-pro',1048576),('gemini-3.1-pro-preview',1048576),('gemini-3.1-pro-preview-customtools',1048576),('gemini-3.5-flash',200000),('gemini-3.5-flash-lite',1048576),('gemini-3.5-flash-lite@eu',1048576),('gemini-3.5-flash-thinking',1048576),('gemini-3.5-flash@eu',1048576),('gemini-3.5-live-translate-preview',16384),('gemini-3.6-flash',1000000),('gemini-3.7-flash',1000000),('gemini-3.7-flash@eu',1048576),('gemini-3.8-flash',1000000),('gemini-3.8-flash@eu',1048576),('gemini-4-argon',1048576),('gemini-4-argon-contributor',1048576),('gemini-4-argon@eu',1048576),('gemini-embedding',2048),('gemini-embedding-001',2048),('gemini-embedding-2',8192),('gemini-exp-1206',2097152),('gemini-flash-latest',1048576),('gemini-flash-lite-latest',1048576),('gemini-nano-banana-2.1',131072),('gemini-omni-flash-preview',131072),('gemini-pro-latest',1048576),('gemini/gemini-2.5-flash',1048576),('gemini/gemini-2.5-flash-lite',1048576),('gemini/gemini-2.5-pro',1048576),('gemini/gemini-3-flash-preview',1048576),('gemini/gemini-3.1-pro-preview',1048576),('gemini/gemini-3.5-flash',1048576),('gemini/gemini-3.5-flash-lite',1048576),('gemini/gemini-3.6-flash',1048576),('gemini/gemini-3.7-flash',1048576),('gemini/gemini-3.8-flash',1048576),('gemini/gemini-4-argon',1048576),('gemma-3-12b',131072),('gemma-3-12b-it',131072),('gemma-3-27b',131072),('gemma-3-27b-it',40000),('gemma-4',131072),('gemma-4-12b-it',131072),('gemma-4-12b-it-semancer',131072),('gemma-4-12b-it-starry-ocean',131072),('gemma-4-12b-it-station-keeper',131072),('gemma-4-26b-a4b',262144),('gemma-4-26b-a4b-it',262144),('gemma-4-26b-a4b-it-chimerax',262144),('gemma-4-26b-a4b-it-chimeraxheretic',262144),('gemma-4-26b-a4b-it-darksoul',262144),('gemma-4-26b-a4b-it-luminous',262144),('gemma-4-26b-a4b-it-moonlight',262144),('gemma-4-26b-a4b-it-musica',262144),('gemma-4-26b-a4b-it-opusdistill',262144),('gemma-4-26b-a4b-it-shadowsiren',262144),('gemma-4-31B-it',256000),('gemma-4-31B-it-fp8',262144),('gemma-4-31b',262128),('gemma-4-31b-it',262144),('gemma-4-31b-it-darkidol',262144),('gemma-4-31b-it-fabled',262144),('gemma-4-31b-it-garnet',262144),('gemma-4-31b-it-gembrain',262144),('gemma-4-31b-it-gemsicle',262144),('gemma-4-31b-it-isometry',262144),('gemma-4-31b-it-novelist',262144),('gemma-4-31b-it-scarlet',262144),('gemma-4-31b-it:free',262144),('gemma-4-E4B-it-IQ4_XS',32768),('gemma-4-E4B-it-MLX-4bit',32768),('gemma-4-uncensored',256000),('gemma2-9b-it',8192),('gemma4',262144),('gemma4-26b',256000),('gemma4-31b',100000),('gemma4:31b',262144),('glm-4-5-flash',131072),('glm-4-6v-flash',131072),('glm-4-7-flash',202752),('glm-4-7-flash:free',200000),('glm-4-7-flashx',202752),('glm-4-long',1000000),('glm-4.5-flash',131072)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('glm-4.5-flash:free',131072),('glm-4.6',204800),('glm-4.6v',131072),('glm-4.7',204800),('glm-4.7-flash',200000),('glm-4.7-flash-free',200000),('glm-4.7-flashx',200000),('glm-4.7-free',204800),('glm-5',204800),('glm-5-1',202745),('glm-5-2',1000000),('glm-5-2-260617',1000000),('glm-5-3',1048576),('glm-5-3-flash',1048576),('glm-5-3-flash-260828',1000000),('glm-5-free',204800),('glm-5-turbo',200000),('glm-5.1',204800),('glm-5.1@eu',200000),('glm-5.2',1000000),('glm-5.2-caveman',1000000),('glm-5.2-caveman-lite',1000000),('glm-5.2-caveman-ultra',1000000),('glm-5.2-fast',1000000),('glm-5.2-highspeed',1000000),('glm-5.2-honey',1000000),('glm-5.2-honey-lite',1000000),('glm-5.2-honey-ultra',1000000),('glm-5.2-nitro',200000),('glm-5.2-ponytail',1000000),('glm-5.2-ponytail-lite',1000000),('glm-5.2-ponytail-ultra',1000000),('glm-5.2:free',1000000),('glm-5.2@eu',1048576),('glm-5.3',1000000),('glm-5.3-fast',1048576),('glm-5.3-flash',1000000),('glm-5.3-flash-flex',1048560),('glm-5.3-flash-free',200000),('glm-5.3-flash:fast',1000000),('glm-5.3-flash@eu',1000000),('glm-5.3-flashx',1000000),('glm-5.3-flex',1048560),('glm-5.3-highspeed',1000000),('glm-5.3:fast',1000000),('glm-5.3@eu',1048576),('glm-5.x-menthol',202752),('glm-5v-turbo',200000),('glm-flash-latest',1000000),('glm-latest',1000000),('glm5.2',96000),('glm5.2-fast',1048576),('glm5.3',1000000),('glm5.3-754b',524288),('glm5.3-flash',1000000),('global.amazon.nova-2-lite-v1:0',1000000),('global.anthropic.claude-fable-5',1000000),('global.anthropic.claude-fable-5-1',1000000),('global.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('global.anthropic.claude-haiku-5-5',1000000),('global.anthropic.claude-opus-4-5-20251101-v1:0',200000),('global.anthropic.claude-opus-4-6-v1',1000000),('global.anthropic.claude-opus-4-7',1000000),('global.anthropic.claude-opus-4-8',1000000),('global.anthropic.claude-opus-5',1000000),('global.anthropic.claude-opus-5-5',1000000),('global.anthropic.claude-sonnet-4-20250514-v1:0',200000),('global.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('global.anthropic.claude-sonnet-4-6',1000000),('global.anthropic.claude-sonnet-5',1000000),('global.anthropic.claude-sonnet-5-5',1000000),('global.moonshotai.kimi-k3',1048576),('global.openai.gpt-5.6-luna',1050000),('global.openai.gpt-5.6-sol',1050000),('global.openai.gpt-5.6-terra',1050000),('global.openai.gpt-6-astra',1050000),('global.openai.gpt-6-luna',1050000),('global.openai.gpt-6-sol',1050000),('global.openai.gpt-6.1-sol',1050000),('global.openai.gpt-6.1-terra',1050000),('global.xai.grok-4.6',500000),('global.xai.grok-4.7',500000),('global.zai.glm-5.3',1000000),('google-ai-studio/gemini-3-flash-preview',1048576),('google-ai-studio/gemini-3.1-flash-lite',1048576),('google-ai-studio/gemini-3.1-pro-preview',1048576),('google-ai-studio/gemini-3.5-flash-lite',1048576),('google-ai-studio/gemini-3.6-flash',1048576),('google-ai-studio/gemini-3.8-flash',1048576),('google-ai-studio/gemini-4-argon',1048576),('google-ai-studio/gemini-pro-latest',1048576),('google-gemma-3-27b-it',198000),('google-gemma-4-26b-a4b-it',256000),('google-gemma-4-31b-it',256000),('google-vertex/gemini-3-flash-preview',1048576),('google-vertex/gemini-3.1-flash-lite',1048576),('google-vertex/gemini-3.1-pro-preview',1048576),('google-vertex/gemini-3.5-flash',1048576),('google-vertex/gemini-3.5-flash-lite',1048576),('google-vertex/gemini-3.6-flash',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('google-vertex/gemini-3.7-flash',1048576),('google-vertex/gemini-3.8-flash',1048576),('google-vertex/gemini-4-argon',1048576),('google.gemma-3-12b-it',131072),('google.gemma-3-27b-it',131072),('google.gemma-3-4b-it',131072),('google.gemma-4-26b-a4b',262144),('google.gemma-4-31b',262144),('google.gemma-4-e2b',131072),('google/deep-research-max-preview-04-2026',1048576),('google/deep-research-preview-04-2026',1048576),('google/diffusiongemma',262144),('google/diffusiongemma-26b-a4b-it',250000),('google/gemini-2.0-flash',990000),('google/gemini-2.0-flash-lite',990000),('google/gemini-2.5-flash',1048576),('google/gemini-2.5-flash-image',32768),('google/gemini-2.5-flash-lite',1048576),('google/gemini-2.5-pro',1048576),('google/gemini-2.5-pro-preview',1048576),('google/gemini-3-8-flash',1048576),('google/gemini-3-flash',1000000),('google/gemini-3-flash-preview',1048576),('google/gemini-3-flash-preview-thinking',1048576),('google/gemini-3-pro-image',131072),('google/gemini-3-pro-image-preview',65536),('google/gemini-3-pro-preview',1048576),('google/gemini-3.1-flash-image',131072),('google/gemini-3.1-flash-image-preview',65536),('google/gemini-3.1-flash-lite',1048576),('google/gemini-3.1-flash-lite-image',65536),('google/gemini-3.1-flash-lite-preview',1048576),('google/gemini-3.1-pro',1000000),('google/gemini-3.1-pro-preview',1048576),('google/gemini-3.1-pro-preview-customtools',1048576),('google/gemini-3.1-pro-preview-high',1048576),('google/gemini-3.1-pro-preview-low',1048576),('google/gemini-3.5-flash',1048576),('google/gemini-3.5-flash-lite',1048576),('google/gemini-3.5-flash-thinking',1048576),('google/gemini-3.5-transcribe',98304),('google/gemini-3.5-transcribe-live',0),('google/gemini-3.6-flash',1048576),('google/gemini-3.7-flash',1048576),('google/gemini-3.8-flash',1048576),('google/gemini-3.8-flash-lite-tts',8192),('google/gemini-3.8-flash-tts',8192),('google/gemini-3.8-live',131072),('google/gemini-3.8-live-extended-thinking',131072),('google/gemini-4-argon',1048576),('google/gemini-deep-research',1048576),('google/gemini-embedding-001',2048),('google/gemini-embedding-2',8192),('google/gemini-flash-latest',1048576),('google/gemini-flash-lite-latest',1048576),('google/gemini-nano-banana-2.1',65536),('google/gemini-omni-1.1-flash',131072),('google/gemini-omni-flash-preview',1000000),('google/gemini-pro-latest',1048576),('google/gemini-robotics-er-1.6-preview',131072),('google/gemini-robotics-er-2-preview',131072),('google/gemma-2-27b-it',8192),('google/gemma-3',125000),('google/gemma-3-12b-it',131072),('google/gemma-3-27b-it',131072),('google/gemma-3-4b-it',131072),('google/gemma-4-12B-it',262144),('google/gemma-4-26B-A4B-it',262144),('google/gemma-4-26b-a4b-it',262144),('google/gemma-4-26b-a4b-it-cybersecurity',262144),('google/gemma-4-26b-a4b-it-maas',262144),('google/gemma-4-26b-a4b-it:free',262144),('google/gemma-4-26b-a4b-it:thinking',262144),('google/gemma-4-31B-it',262144),('google/gemma-4-31B-turbo-TEE',131072),('google/gemma-4-31b',262144),('google/gemma-4-31b-it',262144),('google/gemma-4-31b-it:free',262144),('google/gemma-4-31b-it:thinking',262144),('google/gemma-4-E4B-it',131072),('google/gemma4-31b-splituntied',262144),('google/imagen-3',480),('google/imagen-3-fast',480),('google/imagen-4',480),('google/imagen-4-fast',480),('google/imagen-4-ultra',480),('google/lyria',0),('google/lyria-3-clip-preview',1048576),('google/lyria-3-pro-preview',1048576),('google/nano-banana',65536),('google/nano-banana-pro',65536),('google/text-embedding-005',8192),('google/text-multilingual-embedding-002',8192),('google/veo-2',480),('google/veo-3',480),('google/veo-3-fast',480),('google/veo-3.0-fast-generate-001',0),('google/veo-3.0-generate-001',0),('google/veo-3.1',480),('google/veo-3.1-fast',480)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('google/veo-3.1-fast-generate-001',0),('google/veo-3.1-generate-001',0),('google/veo-3.1-lite-generate-001',0),('google/veo3.1',400000),('google/veo3.1-fast',400000),('google/veo3.1-lite',400000),('gpt-3.5-turbo',16385),('gpt-3.5-turbo-0125',16384),('gpt-3.5-turbo-1106',16384),('gpt-3.5-turbo-instruct',4096),('gpt-4',8192),('gpt-4.1',1047576),('gpt-4.1-mini',1047576),('gpt-4.1-mini-2025-04-14',1047576),('gpt-4.1-mini@eu',1047576),('gpt-4.1-nano',1047576),('gpt-4.1-nano@eu',1047576),('gpt-4.1@eu',1047576),('gpt-4o-mini-transcribe',16000),('gpt-4o-transcribe',16000),('gpt-5',400000),('gpt-5-1',400000),('gpt-5-2',400000),('gpt-5-3-codex',400000),('gpt-5-4',1050000),('gpt-5-4-mini',400000),('gpt-5-4-nano',400000),('gpt-5-5',1050000),('gpt-5-5-pro',1050000),('gpt-5-6-luna',1050000),('gpt-5-6-sol',1050000),('gpt-5-6-terra',1050000),('gpt-5-chat-latest',400000),('gpt-5-codex',400000),('gpt-5-mini',400000),('gpt-5-mini@eu',200000),('gpt-5-nano',400000),('gpt-5-nano@eu',200000),('gpt-5-pro',400000),('gpt-5-thinking',400000),('gpt-5.1',400000),('gpt-5.1-chat-latest',400000),('gpt-5.1-codex',400000),('gpt-5.1-codex-max',400000),('gpt-5.1-codex-mini',400000),('gpt-5.1@eu',400000),('gpt-5.2',400000),('gpt-5.2-chat-latest',400000),('gpt-5.2-codex',400000),('gpt-5.2-pro',400000),('gpt-5.3-chat-latest',400000),('gpt-5.3-codex',400000),('gpt-5.3-codex-xhigh',400000),('gpt-5.4',1050000),('gpt-5.4-mini',400000),('gpt-5.4-nano',400000),('gpt-5.4-pro',1050000),('gpt-5.4:free',1050000),('gpt-5.4@eu',1050000),('gpt-5.5',1050000),('gpt-5.5-pro',1050000),('gpt-5.5:free',1050000),('gpt-5.5@eu',1050000),('gpt-5.6',1050000),('gpt-5.6-luna',1050000),('gpt-5.6-luna-pro',1050000),('gpt-5.6-luna@eu',1050000),('gpt-5.6-sol',1050000),('gpt-5.6-sol-pro',1050000),('gpt-5.6-sol@eu',1050000),('gpt-5.6-terra',1050000),('gpt-5.6-terra-pro',1050000),('gpt-5.6-terra@eu',1050000),('gpt-5@eu',400000),('gpt-6-1-sol',1050000),('gpt-6-astra',1050000),('gpt-6-luna',1050000),('gpt-6-luna@eu',1050000),('gpt-6-sol',1050000),('gpt-6-sol@eu',1050000),('gpt-6.1-sol',1050000),('gpt-6.1-sol@eu',1050000),('gpt-6.1-terra',1050000),('gpt-6.1-terra@eu',1050000),('gpt-chat-latest',400000),('gpt-daybreak-blue-latest',1050000),('gpt-daybreak-red-latest',400000),('gpt-image-1',0),('gpt-image-1-mini',0),('gpt-image-1.5',0),('gpt-image-2',0),('gpt-image-2.5-flare',0),('gpt-image-2.5-sunburst',0),('gpt-live-transcribe',0),('gpt-oss-120b',131072),('gpt-oss-20b',131072),('gpt-oss:120b',131072),('gpt-oss:20b',131072),('gpt-sol-latest',1000000),('gpt-transcribe',0)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('granite-4.2-8b',131072),('green-r',131072),('green-r-raw',131072),('green-s',0),('green-s-pro',0),('greenference/glm-5.3-flash',1048576),('greenference/gpt-oss-20b',131072),('greenference/qwen3-14b',16384),('greenference/qwen3-30b-a3b',8192),('greenference/qwen3.6-27b',16384),('greenpt/deepseek-v4-flash-0731',1000000),('greenpt/deepseek-v4.1-flash',1000000),('greenpt/qwen3-235b-a22b-instruct-2507',250000),('grok-3',131072),('grok-3-mini',131072),('grok-4',256000),('grok-4-0709',256000),('grok-4-1-fast-non-reasoning',2000000),('grok-4-1-fast-reasoning',2000000),('grok-4-20',2000000),('grok-4-20-beta-0309-non-reasoning',2000000),('grok-4-20-beta-0309-reasoning',2000000),('grok-4-20-multi-agent',2000000),('grok-4-20-non-reasoning',2000000),('grok-4-20-reasoning',2000000),('grok-4-3',1000000),('grok-4-5',500000),('grok-4-6',500000),('grok-4-7',500000),('grok-4-fast-non-reasoning',2000000),('grok-4-fast-reasoning',2000000),('grok-4.1',200000),('grok-4.2-beta',2000000),('grok-4.20-0309-non-reasoning',1000000),('grok-4.20-0309-reasoning',1000000),('grok-4.20-beta-0309-reasoning',2000000),('grok-4.20-multi-agent-0309',1000000),('grok-4.3',1000000),('grok-4.5',500000),('grok-4.6',500000),('grok-4.7',500000),('grok-build-0-1',256000),('grok-build-0.1',256000),('grok-code',256000),('grok-code-fast-1',256000),('grok-imagine-image',16000),('grok-imagine-image-2-0',64000),('grok-imagine-video',1024),('grok-imagine-video-1.5',1024),('grok-imagine-video-1.5-lite',1024),('grok/grok-4.3',1000000),('grok/grok-4.5',500000),('grok/grok-4.6',500000),('groq/allam-2-7b',4096),('groq/gpt-oss-120b',131072),('groq/gpt-oss-20b',131072),('groq/meta-llama/llama-prompt-guard-2-22m',512),('groq/meta-llama/llama-prompt-guard-2-86m',512),('groq/openai/gpt-oss-120b',131072),('groq/openai/gpt-oss-20b',131072),('groq/openai/gpt-oss-safeguard-20b',131072),('groq/qwen/qwen3.8-27b',131042),('gryphe/mythomax-l2-13b',8192),('gte-large-en-v1.5',8192),('happyhorse-1.1-i2v',0),('happyhorse-1.1-r2v',0),('happyhorse-1.1-t2v',0),('heabsy/cyberheabsy',1048576),('heabsy/qwen3.8-27b-uncensored-fast',524288),('hermes-2-pro-llama-3-8b',131072),('hermes-high',1048576),('hermes-low',1048576),('hermes-medium',1048576),('heygen/heygen-video-1',0),('hf:MiniMaxAI/MiniMax-M3',524288),('hf:Qwen/Qwen3.6-27B',262144),('hf:deepseek-ai/DeepSeek-V4.1-Flash',524288),('hf:deepseek-ai/DeepSeek-V4.1-Flash-1017',524288),('hf:moonshotai/Kimi-K2.7-Code',262144),('hf:moonshotai/Kimi-K3',524288),('hf:nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4',262144),('hf:openai/gpt-oss-120b',131072),('hf:zai-org/GLM-4.7-Flash',196608),('hf:zai-org/GLM-5.2',524288),('hf:zai-org/GLM-5.3',524288),('hf:zai-org/GLM-5.3-Flash',524288),('holo2-30b-a3b',22016),('holo3-35b-a3b',65536),('holo3-35b-a3b:thinking',65536),('huihui-ai/DeepSeek-R1-Distill-Llama-70B-abliterated',16384),('huihui-ai/DeepSeek-R1-Distill-Qwen-32B-abliterated',16384),('huihui-ai/Llama-3.3-70B-Instruct-abliterated',32768),('huihui-ai/Qwen2.5-32B-Instruct-abliterated',32768),('hunyuan-2.0-instruct',131072),('hunyuan-2.0-thinking',131072),('hunyuan-t1',131072),('hunyuan-turbos',131072),('hy-mt2-plus',8192),('hy3',256000),('hy3-free',190000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('hy3-preview',256000),('hy3-preview-free',256000),('hy3:free',256000),('hy4',1048576),('hy4-preview',1024000),('ibm-granite/granite-4.2-8b',131072),('ibm/granite-4-h-small',131072),('iceman-contributor-free',262144),('ideogramai/ideogram',150),('ideogramai/ideogram-v2',150),('ideogramai/ideogram-v2a',150),('ideogramai/ideogram-v2a-turbo',150),('in.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('in.anthropic.claude-opus-5',1000000),('in.anthropic.claude-sonnet-5',1000000),('in.openai.gpt-5.6-luna',1050000),('in.openai.gpt-5.6-terra',1050000),('inception/mercury-2.5',260000),('inception/mercury-2.5-preview',260000),('inception/mercury-3',1000000),('inception/mercury-coder-small',32000),('inclusionAI/Ling-flash-2.0',131000),('inclusionai/ling-3.0-flash',262144),('inclusionai/ling-3.0-flash-fin',256000),('inclusionai/ling-3.0-flash-sante',256000),('inclusionai/ling-3.0-flash-vl',131072),('inclusionai/ling-3.0-flash:thinking',262144),('inclusionai/ling-3.1-flash',1000000),('inclusionai/ling-3.1-flash-1019',1000000),('inclusionai/ling-3.1-flash:free',262144),('inclusionai/ring-2.6-1t',262000),('infer/gpt-5.6-sol:official',271999),('infer/gpt-6-astra:official',271999),('inference.net/deepseek-v4.1-flash-1017',262144),('inference.net/deepseek-v4.1-flash-cyber',1040000),('inference.net/glm-5.3',1048576),('inference.net/glm-5.3-flash',1048576),('inference.net/minimax-m3.1-flash',1000000),('inflatebot/MN-12B-Mag-Mell-R1',16384),('infomaniak/mistralai/Ministral-3-14B-Instruct-2512',100000),('inkling',1048576),('inkling-256k',262144),('interfaze/interfaze-beta',1000000),('intfloat/e5-mistral-7b-instruct',4096),('intfloat/multilingual-e5-large-instruct',512),('jamba-large',256000),('jamba-mini',256000),('jp.amazon.nova-2-lite-v1:0',1000000),('jp.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('jp.anthropic.claude-haiku-5-5',1000000),('jp.anthropic.claude-opus-4-7',1000000),('jp.anthropic.claude-opus-4-8',1000000),('jp.anthropic.claude-opus-5',1000000),('jp.anthropic.claude-opus-5-5',1000000),('jp.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('jp.anthropic.claude-sonnet-4-6',1000000),('jp.anthropic.claude-sonnet-5',1000000),('k3',1048576),('k3-256k',262144),('k3.1-pro',1048576),('k3.1-pro-highspeed',1048576),('kat-coder-pro',256000),('kilo-auto/balanced',1000000),('kilo-auto/efficient',1000000),('kilo-auto/free',256000),('kilo-auto/frontier',1000000),('kilo-auto/small',262144),('kimi-for-coding',1048576),('kimi-for-coding-highspeed',262144),('kimi-k2',262144),('kimi-k2-0711',131072),('kimi-k2-0905',262144),('kimi-k2-0905-preview',262144),('kimi-k2-5',256000),('kimi-k2-6',262144),('kimi-k2-6:free',262144),('kimi-k2-7-code',262144),('kimi-k2-7-code-highspeed',262144),('kimi-k2-7-code:free',262144),('kimi-k2-instruct-fast',131072),('kimi-k2-thinking',262144),('kimi-k2-turbo-preview',256000),('kimi-k2.5',262144),('kimi-k2.5-free',262144),('kimi-k2.6',262144),('kimi-k2.6-fast',262144),('kimi-k2.6-nitro',200000),('kimi-k2.6@eu',256000),('kimi-k2.7-code',262144),('kimi-k2.7-code-fast',262128),('kimi-k2.7-code-flex',262128),('kimi-k2.7-code-highspeed',262144),('kimi-k2.7-code-nitro',200000),('kimi-k2.7-code@eu',262144),('kimi-k2.8-preview',1000000),('kimi-k3',1048576),('kimi-k3-1-pro',1000000),('kimi-k3-1-pro-highspeed',1000000),('kimi-k3-fast',1040384),('kimi-k3-fast-api',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('kimi-k3-flex',1048560),('kimi-k3.1-pro',1048576),('kimi-k3.1-pro-highspeed',1048576),('kimi-k3:fast',1048576),('kimi-k3@eu',1048576),('kimi-latest',256000),('kimi/kimi-k2.5',262144),('kimi/kimi-k2.6',262144),('kimi/kimi-k2.7-code',262144),('kimi/kimi-k3',1048576),('kling-v2-6',99999999),('klingai/kling-v2.5-turbo-i2v',0),('klingai/kling-v2.5-turbo-t2v',0),('klingai/kling-v2.6-i2v',0),('klingai/kling-v2.6-motion-control',0),('klingai/kling-v2.6-t2v',0),('klingai/kling-v3.0-i2v',0),('klingai/kling-v3.0-motion-control',0),('klingai/kling-v3.0-t2v',0),('kolibri-1',262144),('labs-devstral-small-2512',256000),('labs-leanstral-1-5-1',262144),('laguna-m.1',32768),('laguna-s-2.1',1048576),('laguna-s-2.1-free',256000),('laguna-xs.2',32768),('leanstral-1-5',262144),('leanstral-1-5@eu',262144),('leonardo-ai/lucid-origin',4096),('leonardo-ai/lucid-realism',4096),('lightonai/LightOnOCR-2-1B',32768),('lightonocr-3-0.8b',262144),('ling-2.6-1t',262144),('ling-2.6-flash',262144),('ling-2.6-flash-free',262100),('ling-3.0-flash',262144),('ling-3.0-flash-fin-free',262144),('ling-3.0-flash-free',262144),('ling-3.0-flash-vl',131072),('ling-3.0-tiny',262144),('ling-3.0-tiny-free',262144),('ling-3.1-flash-free',262144),('liquid.auto',10000000),('liquid/lfm-2.5-2.6b:free',65536),('ll-alpha-free',262144),('llama-3.1-8b-instant',131072),('llama-3.1-8b-instruct',16384),('llama-3.3-70b-instruct',131072),('llama-4-maverick',1000000),('llama-4-maverick-17b-128e-instruct-fp8',1000000),('llama-4-maverick-17b-instruct',1048576),('llama-4-scout',131072),('llama-4-scout-17b-instruct',131072),('llama-guard-4',131072),('llama-prompt-guard-2-22m',512),('llama-prompt-guard-2-86m',512),('llama3-3-70b',131072),('longcat-2.0',1000000),('longcat-2.0-free',1000000),('longcat-2.0:thinking',1000000),('longcat-2.5-preview-free',1000000),('lucidnova-rf1-100b',120000),('lucidquery-agi-01-frontier',300000),('lucidquery-agi-01-swift',300000),('lucidquery-nexus-coder',250000),('lumalabs/ray2',5000),('luminal/deepseek-v4.1-flash',1000000),('lyria-3-clip-preview',1048576),('lyria-3-pro-preview',1048576),('magibu-11b-v8',8192),('magistral-medium-latest',262144),('mai-code-1.1-flash',256000),('mancer/weaver',8000),('medgemma-4b',8192),('meganova-ai/manta-flash-1.0',16384),('meganova-ai/manta-mini-1.0',8192),('meganova-ai/manta-pro-1.0',65536),('meituan-longcat/LongCat-2.0',1049000),('meituan/longcat-2.0',1048756),('meituan/longcat-2.5',1048576),('meituan/longcat-2.5-preview',1000000),('meituan/longcat-flash-chat',131072),('meituan/longcat-flash-lite',256000),('mercury-2-5',260000),('mercury-2.5',260000),('mercury-3',1000000),('mercury-coder-small',32768),('mercury-edit-2',32000),('meta-contributor/muse-spark-1.2-contributor',1048576),('meta-contributor/muse-spark-1.3-contributor',1048576),('meta-llama-3-1-8b-instruct',131072),('meta-llama-3_3-70b-instruct',131072),('meta-llama/Llama-3.1-8B-Instruct',131072),('meta-llama/Llama-3.2-90B-Vision-Instruct',16000),('meta-llama/Llama-3.3-70B-Instruct-Turbo',131072),('meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8',430000),('meta-llama/Llama-4-Scout-17B-16E-Instruct',327680),('meta-llama/Llama-Guard-4-12B',163840),('meta-llama/Meta-Llama-3.3-70B-Instruct',131072),('meta-llama/llama-3-3-70b-instruct',131072)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('meta-llama/llama-3.1-70b-instruct',131072),('meta-llama/llama-3.1-8b-instruct',131072),('meta-llama/llama-3.2-1b-instruct',60000),('meta-llama/llama-3.2-3b-instruct',131072),('meta-llama/llama-3.3-70b-instruct',131072),('meta-llama/llama-4-maverick',524288),('meta-llama/llama-4-maverick-17b-128e-instruct-fp8',1048576),('meta-llama/llama-4-scout',327680),('meta-llama/llama-4-scout-17b-16e-instruct',131072),('meta-llama/llama-guard-4-12b',163840),('meta-llama/llama-prompt-guard-2-22m',512),('meta-llama/llama-prompt-guard-2-86m',512),('meta-models/Muse-Spark-Open-816B-A42B',1048576),('meta-models/muse-spark-open',1048576),('meta.llama-4-maverick-17b-128e-instruct-fp8',512000),('meta.llama-4-scout-17b-16e-instruct',192000),('meta.llama4-maverick-17b-instruct-v1:0',1000000),('meta.llama4-scout-17b-instruct-v1:0',10000000),('meta/llama-3.2-1b-instruct',16000),('meta/llama-3.2-3b-instruct',16000),('meta/llama-3.3-70b-instruct',131072),('meta/llama-4-maverick-17b-128e-instruct-maas',524288),('meta/llama-4-scout-17b-16e-instruct-maas',1310720),('meta/llama-guard-4-12b',163840),('meta/muse-glimmer-30b',131072),('meta/muse-image-1.0',0),('meta/muse-spark-1.1',1048576),('meta/muse-spark-1.2',1048576),('meta/muse-spark-1.2-contributor',1048576),('meta/muse-spark-1.3',1048576),('meta/muse-spark-1.3-contributor',1048576),('meta/muse-spark-open',1048576),('meta/muse-wonder',1048576),('meta/muse-wonder-1.0',1048576),('microsoft/gpt-4',8191),('microsoft/mai-image-2.6',0),('microsoft/mai-image-2.6-flash',0),('microsoft/mai-transcribe-2',0),('microsoft/mai-transcribe-2-streaming',0),('microsoft/mai-voice-2',0),('microsoft/mai-voice-2-flash',0),('microsoft/mai-voice-2.1',0),('microsoft/mai-voice-2.1-flash',0),('microsoft/o3-mini',200000),('microsoft/phi-4',16384),('microsoft/wizardlm-2-8x22b',65535),('mimo-v2-5',1048576),('mimo-v2-5-pro',1048576),('mimo-v2-5:free',1048576),('mimo-v2-6-flash',1048576),('mimo-v2-6-pro',1048576),('mimo-v2-6-pro-ultraspeed',1048576),('mimo-v2-flash',256000),('mimo-v2-flash-free',262144),('mimo-v2-omni-free',262144),('mimo-v2-pro',1048576),('mimo-v2-pro-free',1048576),('mimo-v2.5',1000000),('mimo-v2.5-free',200000),('mimo-v2.5-pro',1048576),('mimo-v2.5-pro-ultraspeed',1048576),('mimo-v2.5-tts',8192),('mimo-v2.5-tts-voiceclone',8192),('mimo-v2.5-tts-voicedesign',8192),('mimo-v2.6-flash',1048576),('mimo-v2.6-flash-free',200000),('mimo-v2.6-flash-rl',1048576),('mimo-v2.6-pro',1048576),('mimo-v2.6-pro-flex',1048560),('mimo-v2.6-pro-rl',1048576),('mimo-v2.6-pro-ultraspeed',1048576),('mimo-v25',1000000),('mimo/mimo-v2.5',1000000),('mimo/mimo-v2.5-pro',1000000),('mindai/macaron-v1-tall',262144),('mindai/macaron-v1-venti',1048576),('mini_lm_l12_v2',128),('minicpm-v-4.5',32000),('minimax-latest',1000000),('minimax-m2',196608),('minimax-m2-5',192000),('minimax-m2-7',204800),('minimax-m2-7-highspeed',204800),('minimax-m2.1',204800),('minimax-m2.1-free',204800),('minimax-m2.1-lightning',196608),('minimax-m2.5',204800),('minimax-m2.5-free',204800),('minimax-m2.5-highspeed',204800),('minimax-m2.7',204800),('minimax-m2.7-highspeed',204800),('minimax-m2.7:free',204800),('minimax-m25',198000),('minimax-m27',198000),('minimax-m3',1000000),('minimax-m3-1-flash',1048576),('minimax-m3-free',200000),('minimax-m3-preview',524288),('minimax-m3.1-flash',1000000),('minimax-m3.1-flash-free',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('minimax-m3.1-flash@eu',1048576),('minimax-m3:fast',1048576),('minimax-m3@eu',1048576),('minimax-text-01',1000000),('minimax.minimax-m2',204608),('minimax.minimax-m2.1',196608),('minimax.minimax-m2.5',196608),('minimax/MiniMax-M2',204800),('minimax/MiniMax-M2.1',204800),('minimax/MiniMax-M2.5',204800),('minimax/MiniMax-M2.7',204800),('minimax/MiniMax-M2.7-highspeed',204800),('minimax/MiniMax-M3',524288),('minimax/MiniMax-M3.1-Flash',1048576),('minimax/m2-her',65536),('minimax/m3.1-flash',1000000),('minimax/minimax-01',1000192),('minimax/minimax-h3',0),('minimax/minimax-h3-max',0),('minimax/minimax-latest',512000),('minimax/minimax-m1',1000000),('minimax/minimax-m2',204800),('minimax/minimax-m2-her',65536),('minimax/minimax-m2.1',204800),('minimax/minimax-m2.1-lightning',196608),('minimax/minimax-m2.5',204800),('minimax/minimax-m2.5-highspeed',204800),('minimax/minimax-m2.5-lightning',204800),('minimax/minimax-m2.7',204800),('minimax/minimax-m2.7-highspeed',204800),('minimax/minimax-m2.7-turbo',204800),('minimax/minimax-m3',1048576),('minimax/minimax-m3.1-flash',1048576),('minimax/minimax-m3:thinking',512000),('minimax/minimax-text-01',1000000),('minimaxai/chat-completion/models/MiniMax-M2_5-high-throughput',204800),('minimaxai/minimax-m1-80k',1000000),('minimaxai/minimax-m3',1048576),('minimaxai/minimax-m3.1-flash',262144),('ministral-14b-2512',262144),('ministral-3b-2512',131072),('ministral-3b-latest',131072),('ministral-8b-2512',262144),('ministral-8b-latest',262144),('mistral-3-14B',262144),('mistral-7b-instruct-v0.2',32000),('mistral-code-agent-latest',262144),('mistral-code-latest',256000),('mistral-embed',8000),('mistral-large-2402',32000),('mistral-large-2512',262144),('mistral-large-3:675b',262144),('mistral-large-4',524288),('mistral-large-4-0',1000000),('mistral-large-4-0-8',1048576),('mistral-large-4@eu',524288),('mistral-large:free',262144),('mistral-medium-2508',262144),('mistral-medium-2604',262144),('mistral-medium-3',131072),('mistral-medium-3-5',262144),('mistral-medium-3-5:free',262144),('mistral-medium-3-5@eu',262144),('mistral-medium-3.5',256000),('mistral-medium-3.5-128b',262144),('mistral-medium-latest',131072),('mistral-medium-latest@eu',131072),('mistral-nemo-instruct-2407',118000),('mistral-small-2603',262144),('mistral-small-2603@eu',256000),('mistral-small-3-2-24b-instruct',256000),('mistral-small-3.2-24b-instruct-2506',131072),('mistral-small-4',262144),('mistral-small-4-119b',256000),('mistral-small-latest',262144),('mistral.devstral-2-123b',262144),('mistral.ministral-3-3b-instruct',256000),('mistral.mistral-large-3-675b-instruct',262144),('mistral.voxtral-mini-3b-2507',32768),('mistral.voxtral-small-24b-2507',32768),('mistral/codestral-2508',256000),('mistral/codestral-2508@eu',256000),('mistral/codestral-embed',8192),('mistral/codestral-latest',256000),('mistral/codestral-latest@eu',256000),('mistral/devstral-2512',262144),('mistral/devstral-2512@eu',262144),('mistral/devstral-medium-latest',262144),('mistral/devstral-medium-latest@eu',262144),('mistral/glm-5.3',1048576),('mistral/magistral-medium-latest',262144),('mistral/magistral-medium-latest@eu',262144),('mistral/ministral-14b',262144),('mistral/ministral-14b-2512',262144),('mistral/ministral-14b-2512@eu',262144),('mistral/ministral-3b',131072),('mistral/ministral-3b-2512',131072),('mistral/ministral-3b-2512@eu',131072),('mistral/ministral-8b',262144),('mistral/ministral-8b-2512',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('mistral/ministral-8b-2512@eu',262144),('mistral/mistral-embed',8000),('mistral/mistral-large-2407',131072),('mistral/mistral-large-2407@eu',131072),('mistral/mistral-large-2512',262144),('mistral/mistral-large-2512@eu',262144),('mistral/mistral-large-3',262144),('mistral/mistral-large-4',1000000),('mistral/mistral-large-4@eu',524288),('mistral/mistral-large-latest@eu',262144),('mistral/mistral-medium-2505',131072),('mistral/mistral-medium-2505@eu',131072),('mistral/mistral-medium-2604',262144),('mistral/mistral-medium-2604@eu',262144),('mistral/mistral-medium-3',262144),('mistral/mistral-medium-3-5',262144),('mistral/mistral-medium-3-5@eu',262144),('mistral/mistral-medium-3.5',262144),('mistral/mistral-medium-3@eu',262144),('mistral/mistral-medium-latest',262144),('mistral/mistral-medium-latest@eu',262144),('mistral/mistral-nemo',131072),('mistral/mistral-nemo-12b-instruct',16000),('mistral/mistral-small',262144),('mistral/mistral-small-2603',262144),('mistral/mistral-small-2603@eu',262144),('mistral/mistral-small-latest',262144),('mistral/mistral-small-latest@eu',262144),('mistral/voxtral-mini-transcribe-3',0),('mistral/voxtral-mini-tts-3',0),('mistral/voxtral-small-latest',32768),('mistral/voxtral-small-latest@eu',32768),('mistral/voxtral-small-transcribe-3',0),('mistral/zai-glm-5-2',1000000),('mistral/zai-glm-5-3',1000000),('mistral4-119b',262144),('mistralai--mistral-medium',262144),('mistralai/Ministral-3-14B-Instruct-2512',100000),('mistralai/Mistral-Medium-3.5-128B',262144),('mistralai/Mistral-Small-24B-Instruct-2501',32768),('mistralai/Mistral-Small-3.2-24B-Instruct-2506',32000),('mistralai/Mistral-Small-4-119B-2603',256000),('mistralai/Voxtral-Small-24B-2507',32000),('mistralai/codestral-2508',256000),('mistralai/completion/models/Ministral-3-14B-Reasoning-2512',262144),('mistralai/completion/models/Ministral-3-3B-Reasoning-2512',262144),('mistralai/devstral-2-123b-instruct-2512',262144),('mistralai/devstral-2512',262144),('mistralai/devstral-small-2505',32768),('mistralai/magistral-small-2506',32768),('mistralai/ministral-14b-2512',262144),('mistralai/ministral-14b-instruct-2512',262144),('mistralai/ministral-3b-2512',131072),('mistralai/ministral-8b-2512',262144),('mistralai/mistral-7b-instruct-v0.3',65536),('mistralai/mistral-large-2407',131072),('mistralai/mistral-large-2512',262144),('mistralai/mistral-large-4',524288),('mistralai/mistral-large-4-0',1048576),('mistralai/mistral-medium-3',131072),('mistralai/mistral-medium-3-5',262144),('mistralai/mistral-medium-3-instruct',131072),('mistralai/mistral-medium-3.1',131072),('mistralai/mistral-medium-3.5',256000),('mistralai/mistral-medium-3.5:thinking',256000),('mistralai/mistral-nemo',131072),('mistralai/mistral-nemo-instruct-2407',16384),('mistralai/mistral-saba',32768),('mistralai/mistral-small-24b-instruct-2501',32768),('mistralai/mistral-small-2603',262144),('mistralai/mistral-small-3-1-24b-instruct-2503',131072),('mistralai/mistral-small-3.2-24b-instruct',256000),('mistralai/mistral-small-4-119b-2603',262144),('mistralai/mistral-small-4-119b-2603:thinking',262144),('mistralai/mixtral-8x22b-instruct',65536),('mistralai/mixtral-8x22b-instruct-v0.1',65536),('mistralai/voxtral-small-24b-2507',32768),('mixedbread/toast-1',131000),('mixtral-8x7B-instruct-v0.1',32000),('mlabonne/NeuralDaredevil-8B-abliterated',8192),('model-router',200000),('moondream/moondream3-preview',32000),('moondream/moondream3.1-9b-a2b',32000),('moonshot-ai/kimi-k2.7-code',262144),('moonshot-ai/kimi-k3',1048576),('moonshot-kimi-k2-instruct',131072),('moonshot.kimi-k2-thinking',262144),('moonshot/kimi-k2.5',262144),('moonshot/kimi-k2.6',262144),('moonshot/kimi-k2.7-code',262144),('moonshot/kimi-k2.7-code-highspeed',262144),('moonshot/kimi-k3',1048576),('moonshot/kimi-k3.1-pro',1048576),('moonshot/kimi-k3.1-pro-highspeed',1048576),('moonshotai.kimi-k2.5',262144),('moonshotai/Kimi-K2-Instruct',131072),('moonshotai/Kimi-K2-Instruct-0905',32768),('moonshotai/Kimi-K2-Thinking',32768),('moonshotai/Kimi-K2.5',262000),('moonshotai/Kimi-K2.6',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('moonshotai/Kimi-K2.6-TEE',262144),('moonshotai/Kimi-K2.6:peft:131072',131072),('moonshotai/Kimi-K2.7-Code',262144),('moonshotai/Kimi-K2.7-Code-Highspeed',262000),('moonshotai/Kimi-K3',1048576),('moonshotai/Kimi-K3-Fast',1000000),('moonshotai/Kimi-K3-TEE',1048576),('moonshotai/Kimi-K3.1-Pro',1000000),('moonshotai/chat-completion/models/Kimi-K2_6',262144),('moonshotai/kimi-k2',131072),('moonshotai/kimi-k2-0905',262144),('moonshotai/kimi-k2-instruct',131072),('moonshotai/kimi-k2-thinking',262144),('moonshotai/kimi-k2-thinking-maas',262144),('moonshotai/kimi-k2.5',262144),('moonshotai/kimi-k2.5:thinking',262144),('moonshotai/kimi-k2.6',262144),('moonshotai/kimi-k2.6:thinking',262144),('moonshotai/kimi-k2.7-code',262144),('moonshotai/kimi-k2.7-code-highspeed',262144),('moonshotai/kimi-k3',1048576),('moonshotai/kimi-k3-fast',1000000),('moonshotai/kimi-k3.1-pro',1048576),('moonshotai/kimi-k3.1-pro-highspeed',1048576),('moonshotai/kimi-latest',1048576),('morph-dsv41flash',1048576),('morph-dsv41flash-1017',1048576),('morph-dsv4flash',1048576),('morph-glm52-744b',1048576),('morph-glm53-744b',1048576),('morph-glm53flash',1048576),('morph-kimik3',1048576),('morph-kimik3-fast',1048576),('morph-v3-fast',262144),('morph-v3-large',262144),('morph/morph-v3-fast',262144),('morph/morph-v3-large',262144),('motif-technologies/motif-3',262144),('multi-qa-mpnet-base-dot-v1',512),('muse-glimmer-30b',131072),('muse-glimmer-30b-tr',131072),('muse-spark-1-1',1048576),('muse-spark-1-2',1048576),('muse-spark-1-3',1048576),('muse-spark-1.1',1048576),('muse-spark-1.2',1048576),('muse-spark-1.2-contributor',1048576),('muse-spark-1.2-contributor-free',1048576),('muse-spark-1.3',1048576),('muse-spark-1.3-contributor',1048576),('muse-spark-1.3-contributor-free',1048576),('muse-spark-open',1048576),('muse-wonder',1048576),('muse-wonder-1.0',1048576),('nano-banana-2',131072),('nano-banana-2-lite',65536),('nano-banana-pro',65536),('nano-gpt-help',6000),('nanogpt/coding-router',1000000),('nanogpt/coding-router:high',1000000),('nanogpt/coding-router:low',1000000),('nanogpt/coding-router:max',1000000),('nanogpt/coding-router:medium',1000000),('nebius/Qwen/Qwen3-235B-A22B-Instruct-2507',262144),('nebius/Qwen/Qwen3-30B-A3B-Instruct-2507',262144),('nebius/deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('nebius/deepseek-ai/DeepSeek-V4-Pro-0813',1048576),('nebius/deepseek-ai/DeepSeek-V4.1-Flash',1048576),('nebius/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('nebius/google/gemma-3-27b-it',110000),('nebius/meta-models/muse-spark-open',1048576),('nebius/minimax-m3.1-flash',1048576),('nebius/nvidia/Nemotron-3-Ultra-550b-a55b',1048576),('nebius/nvidia/nemotron-3-super-120b-a12b',262144),('nebius/openai/gpt-oss-120b',131072),('nemotron-3-nano-30b-a3b',262144),('nemotron-3-nano-omni',65536),('nemotron-3-nano-omni-30b-a3b-reasoning',262144),('nemotron-3-nano-omni-30b-a3b-reasoning-free',256000),('nemotron-3-nano-omni@eu',300000),('nemotron-3-nano:30b',1048576),('nemotron-3-super',262144),('nemotron-3-super-120b-a12b',262144),('nemotron-3-super-120b-a12b-free',262144),('nemotron-3-super-120b-a12b:free',262144),('nemotron-3-super-free',204800),('nemotron-3-ultra',262144),('nemotron-3-ultra-550b',1048576),('nemotron-3-ultra-550b-a55b',1000000),('nemotron-3-ultra-550b-a55b-free',1000000),('nemotron-3-ultra-550b-a55b:free',1000000),('nemotron-3-ultra-free',1000000),('nemotron-3-ultra-nvfp4',262144),('nemotron-3.5-content-safety',131072),('nemotron-3.5-lightning-30b-a3b',1048576),('nemotron-3.5-lightning-free',262144),('nemotron-3.5-super-vl',1048576),('nemotron-3.5-super-vl-free',1048576),('nemotron-lightning-3.5-30b-a3b',262144),('nemotron3-super',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('neosmith.intelligent-basic',1000000),('neosmith.intelligent-maestro',1000000),('neosmith.intelligent-pro',1000000),('neosmith.neolite',512000),('nex-agi/Nex-N2-Pro',262144),('nex-agi/nex-n2.5-mini',262144),('nex-agi/nex-n2.5-pro',262144),('nomic-embed-text',8192),('north-mini-code-1-0',256000),('north-mini-code-free',256000),('north-small-translate-09-2026',32768),('nothingiisreal/L3.1-70B-Celeste-V0.1-BF16',32768),('nousresearch/hermes-2-pro-llama-3-8b',8192),('nousresearch/hermes-3-llama-3.1-405b',131072),('nousresearch/hermes-3-llama-3.1-70b',131072),('nousresearch/hermes-4-405b',131072),('nova-2-lite',1000000),('nova-2-lite-v1',1000000),('nova-2-pro-v1',1000000),('nova-lite-v1',300000),('nova-pro-v1',300000),('novita/deepseek-v4-flash',1050000),('novita/deepseek-v4.1-flash',1048576),('novita/deepseek-v4.1-flash-1017',1048576),('novita/gemma-4-26b-a4b-it',262144),('novita/gemma-4-31b-it',262144),('novita/glm-4.5v',65536),('novita/glm-4.6',204800),('novita/glm-4.6v',131072),('novita/glm-4.7',204800),('novita/glm-4.7-flash',200000),('novita/glm-4.7-n',205000),('novita/glm-5',202800),('novita/glm-5.1',204800),('novita/glm-5.2',1048576),('novita/glm-5.3',1048576),('novita/glm-5.3-flash',1048576),('novita/hy3',262144),('novita/kimi-k2',131072),('novita/kimi-k2-thinking',256000),('novita/kimi-k2.6',262144),('novita/kimi-k2.7-code',262144),('novita/kimi-k3',1048576),('novita/ling-3.0-flash',262144),('novita/llama-3.3-70b-instruct',131072),('novita/llama-4-maverick-17b-instruct',1048576),('novita/llama-4-scout-17b-instruct',131072),('novita/minimax-m2.1',205000),('novita/minimax-m2.5',204800),('novita/minimax-m2.7',204800),('novita/minimax-m3.1-flash',1000000),('novita/qwen3-vl-30b-a3b-instruct',131072),('novita/qwen3.5-122b-a10b',262144),('novita/qwen3.6-35b-a3b',262144),('novita/qwen3.7-max',1000000),('novita/qwen3.8-2.4t-a95b',1000000),('novita/qwen3.8-27b',1000000),('novita/qwen3.8-flash',1000000),('novita/qwen3.8-max',1000000),('novita/qwen35-397b-a17b',262144),('novita/step-3.7-flash',262144),('nvidia--llama-3.2-nv-embedqa-1b',8192),('nvidia--llama-nemotron-embed-1b',8192),('nvidia-nemotron-3-5-super-vl-120b-a12b',262144),('nvidia-nemotron-3-super-120b-a12b',262144),('nvidia-nemotron-3-ultra',262144),('nvidia-nemotron-3-ultra-550b-a55b',256000),('nvidia.nemotron-nano-12b-v2',131072),('nvidia.nemotron-nano-3-30b',262144),('nvidia.nemotron-nano-9b-v2',131072),('nvidia.nemotron-super-3-120b',262144),('nvidia/GLM-5.3-Flash-NVFP4',1000000),('nvidia/Llama-3.1-Nemotron-70B-Instruct-HF',16384),('nvidia/Llama-3.3-Nemotron-Super-49B-v1.5',131072),('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B',262144),('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16',65536),('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8',1000000),('nvidia/NVIDIA-Nemotron-3-Super-120B-A12B',262144),('nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16',65536),('nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16:peft:262144',262144),('nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B',262144),('nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-BF16',65536),('nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-BF16:peft:262144',262144),('nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B',262144),('nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16',65536),('nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16:peft:262144',262144),('nvidia/NVIDIA-Nemotron-3.5-Super-VL',262144),('nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B',1048576),('nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16',65536),('nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16:peft:262144',262144),('nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4',262144),('nvidia/Nemotron-3-Nano-30B-A3B',262144),('nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning',262144),('nvidia/Nemotron-3-Nano-Omni-Reasoning-30B-A3B',256000),('nvidia/Nemotron-3-Ultra-550b-a55b',1048576),('nvidia/Nemotron-3.5-Super-VL',1048576),('nvidia/Nemotron-3_5-Lightning',1048576),('nvidia/Qwen3.8-27B-NVFP4',262144),('nvidia/active-speaker-detection',0),('nvidia/cosmos-reason2-8b',131072)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('nvidia/cosmos-transfer2_5-2b',0),('nvidia/llama-nemotron-embed-vl-1b-v2',8192),('nvidia/llama-nemotron-rerank-vl-1b-v2',10240),('nvidia/magpie-tts-zeroshot',0),('nvidia/nemotron-3-nano-30b-a3b',262144),('nvidia/nemotron-3-nano-omni-30b-a3b-reasoning',256000),('nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',256000),('nvidia/nemotron-3-super-120b-a12b',1048576),('nvidia/nemotron-3-super-120b-a12b:thinking',262144),('nvidia/nemotron-3-ultra-550b-a55b',262144),('nvidia/nemotron-3-ultra-550b-a55b:free',1000000),('nvidia/nemotron-3-ultra-550b-a55b:thinking',1000000),('nvidia/nemotron-3.5-content-safety',131072),('nvidia/nemotron-3.5-lightning',262144),('nvidia/nemotron-3.5-lightning-30b-a3b',1000000),('nvidia/nemotron-3.5-lightning-free',1000000),('nvidia/nemotron-3.5-lightning:free',1000000),('nvidia/nemotron-3.5-lightning:thinking',1000000),('nvidia/nemotron-3.5-super-vl',1048576),('nvidia/nemotron-3.5-super-vl-120b-a12b',1048576),('nvidia/nemotron-3.5-super-vl:free',1000000),('nvidia/nemotron-nano-12b-v2-vl',131072),('nvidia/nemotron-nano-9b-v2',131072),('nvidia/studiovoice',0),('nvidia/synthetic-video-detector',0),('nvidia/usdvalidate',0),('o1',200000),('o1-pro',200000),('o3',200000),('o3-mini',200000),('o3-pro',200000),('o4-mini',200000),('o4-mini@eu',200000),('olafangensan-glm-4.7-flash-heretic',200000),('openai-gpt-4.1',1047576),('openai-gpt-5',400000),('openai-gpt-5-mini',400000),('openai-gpt-5-nano',400000),('openai-gpt-5.1',272000),('openai-gpt-5.2',400000),('openai-gpt-5.2-pro',400000),('openai-gpt-5.3-codex',400000),('openai-gpt-5.4',400000),('openai-gpt-5.4-mini',400000),('openai-gpt-5.4-nano',400000),('openai-gpt-5.4-pro',1050000),('openai-gpt-5.5',1000000),('openai-gpt-5.6-luna',1050000),('openai-gpt-5.6-sol',1050000),('openai-gpt-5.6-terra',1050000),('openai-gpt-52',256000),('openai-gpt-53-codex',400000),('openai-gpt-54',1000000),('openai-gpt-54-mini',400000),('openai-gpt-54-pro',1000000),('openai-gpt-55',1000000),('openai-gpt-55-pro',1000000),('openai-gpt-56-luna',1000000),('openai-gpt-56-luna-pro',1000000),('openai-gpt-56-sol',1000000),('openai-gpt-56-sol-pro',1000000),('openai-gpt-56-terra',1000000),('openai-gpt-56-terra-pro',1000000),('openai-gpt-6-1-sol',1050000),('openai-gpt-6-astra',1050000),('openai-gpt-6-astra-pro',1050000),('openai-gpt-6-luna',1050000),('openai-gpt-6-sol',1050000),('openai-gpt-6.1-terra',1050000),('openai-gpt-61-sol',1050000),('openai-gpt-61-sol-ultrafast',1050000),('openai-gpt-61-terra',1050000),('openai-gpt-image-1',0),('openai-gpt-image-1.5',0),('openai-gpt-image-2',0),('openai-o1',200000),('openai-o3',200000),('openai-o3-mini',200000),('openai.gpt-5.4',1000000),('openai.gpt-5.5',1000000),('openai.gpt-5.6-luna',1050000),('openai.gpt-5.6-sol',1050000),('openai.gpt-5.6-terra',1050000),('openai.gpt-6-astra',1050000),('openai.gpt-6-luna',1050000),('openai.gpt-6-sol',1050000),('openai.gpt-6.1-sol',1050000),('openai.gpt-6.1-terra',1050000),('openai.gpt-oss-120b',131072),('openai.gpt-oss-120b-1:0',131072),('openai.gpt-oss-20b',131072),('openai.gpt-oss-20b-1:0',131072),('openai/chat-completion/models/gpt-oss-120b-high-throughput',131072),('openai/chat-completion/models/gpt-oss-20b',131072),('openai/chat-latest',400000),('openai/dall-e-3',800),('openai/gpt-3.5-turbo',16385),('openai/gpt-3.5-turbo-0613',4095),('openai/gpt-3.5-turbo-16k',16385),('openai/gpt-3.5-turbo-instruct',3500)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('openai/gpt-3.5-turbo-raw',4524),('openai/gpt-4',8191),('openai/gpt-4.1',1047576),('openai/gpt-4.1-fast',1047576),('openai/gpt-4.1-mini',1047576),('openai/gpt-4.1-mini-fast',1047576),('openai/gpt-4.1-nano',1047576),('openai/gpt-4o-mini-transcribe',16000),('openai/gpt-4o-transcribe',16000),('openai/gpt-5',400000),('openai/gpt-5-1',400000),('openai/gpt-5-2',400000),('openai/gpt-5-4',1050000),('openai/gpt-5-5',1050000),('openai/gpt-5-codex',400000),('openai/gpt-5-fast',400000),('openai/gpt-5-image',400000),('openai/gpt-5-image-mini',400000),('openai/gpt-5-mini',400000),('openai/gpt-5-mini-fast',400000),('openai/gpt-5-nano',400000),('openai/gpt-5-pro',400000),('openai/gpt-5-search-api',272000),('openai/gpt-5.1',400000),('openai/gpt-5.1-2025-11-13',400000),('openai/gpt-5.1-codex',400000),('openai/gpt-5.1-codex-max',400000),('openai/gpt-5.1-codex-mini',400000),('openai/gpt-5.1-thinking',400000),('openai/gpt-5.1-thinking-fast',400000),('openai/gpt-5.2',400000),('openai/gpt-5.2-codex',400000),('openai/gpt-5.2-fast',400000),('openai/gpt-5.2-pro',400000),('openai/gpt-5.3-codex',400000),('openai/gpt-5.3-codex-fast',400000),('openai/gpt-5.4',1050000),('openai/gpt-5.4-fast',1050000),('openai/gpt-5.4-image-2',272000),('openai/gpt-5.4-mini',400000),('openai/gpt-5.4-mini-fast',400000),('openai/gpt-5.4-nano',400000),('openai/gpt-5.4-pro',1050000),('openai/gpt-5.5',1050000),('openai/gpt-5.5-fast',1000000),('openai/gpt-5.5-pro',1050000),('openai/gpt-5.6-luna',1050000),('openai/gpt-5.6-luna-fast',1050000),('openai/gpt-5.6-luna-pro',1050000),('openai/gpt-5.6-sol',1050000),('openai/gpt-5.6-sol-fast',1050000),('openai/gpt-5.6-sol-pro',1050000),('openai/gpt-5.6-terra',1050000),('openai/gpt-5.6-terra-fast',1050000),('openai/gpt-5.6-terra-pro',1050000),('openai/gpt-6-astra',1050000),('openai/gpt-6-astra-fast',1050000),('openai/gpt-6-astra-pro',1050000),('openai/gpt-6-luna',1050000),('openai/gpt-6-luna-fast',1050000),('openai/gpt-6-luna-pro',1050000),('openai/gpt-6-sol',1050000),('openai/gpt-6-sol-fast',1050000),('openai/gpt-6-sol-pro',1050000),('openai/gpt-6.1-sol',1050000),('openai/gpt-6.1-sol-fast',1050000),('openai/gpt-6.1-sol-pro',1050000),('openai/gpt-6.1-terra',1050000),('openai/gpt-6.1-terra-fast',1050000),('openai/gpt-6.1-terra-pro',1050000),('openai/gpt-astra-latest',1050000),('openai/gpt-chat-latest',400000),('openai/gpt-image-1-mini',0),('openai/gpt-image-1.5',0),('openai/gpt-image-2.5-flare',0),('openai/gpt-image-2.5-sunburst',0),('openai/gpt-latest',1050000),('openai/gpt-live-1',0),('openai/gpt-live-transcribe',0),('openai/gpt-luna-latest',1050000),('openai/gpt-mini-latest',1050000),('openai/gpt-oss-120b',131072),('openai/gpt-oss-120b-maas',131072),('openai/gpt-oss-120b:peft:131072',131072),('openai/gpt-oss-20b',131072),('openai/gpt-oss-20b-maas',131072),('openai/gpt-oss-safeguard-20b',131072),('openai/gpt-pro-latest',1050000),('openai/gpt-realtime-1.5',32000),('openai/gpt-realtime-mini',32000),('openai/gpt-realtime-whisper',16000),('openai/gpt-sol-latest',1050000),('openai/gpt-terra-latest',1050000),('openai/gpt-transcribe',0),('openai/o1',200000),('openai/o1-pro',200000),('openai/o3',200000),('openai/o3-deep-research',200000),('openai/o3-fast',200000),('openai/o3-mini',200000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('openai/o3-mini-high',200000),('openai/o3-mini-low',200000),('openai/o3-pro',200000),('openai/o3-pro-2025-06-10',200000),('openai/o4-mini',200000),('openai/o4-mini-deep-research',200000),('openai/sora-2',0),('openai/sora-2-pro',0),('openai/text-embedding-3-large',8192),('openai/text-embedding-3-small',8192),('openai/text-embedding-ada-002',8192),('openai/tts-1',0),('openai/tts-1-hd',0),('openai/whisper-1',0),('openai/whisper-large-v3',448),('openai/whisper-large-v3-turbo',448),('openrouter/auto',2000000),('openrouter/free',200000),('openrouter/fusion',1000000),('openrouter/pareto-code',2000000),('orca/orcacyber-minimax-m3.1-flash',261632),('orca/orcacyber-qwen3.8-flash-next',261632),('orca/orcacyber-zero-1.5',999488),('orcarouter/free',65536),('orcarouter/fusion',1000000),('orcarouter/fusion-flash',200000),('orcarouter/fusion-mini',1000000),('ornith-ai/Ornith-1.5-35B-A3B',262144),('ornith-ai/ornith-1.5-122b',262144),('ornith-ai/ornith-1.5-35b-a3b',262144),('ornith-ai/ornith-1.5-35b-a3b:thinking',262144),('osmosis/osmosis-structure-0.6b',4000),('ovhcloud/gpt-oss-120b',131072),('ovhcloud/gpt-oss-20b',131072),('paddlepaddle/paddleocr-vl',16384),('pamanseau/OpenReasoning-Nemotron-32B',32768),('particle-ai/particle-1',1048576),('particle/particle-1',1048576),('perceptron/perceptron-mk1',32768),('perceptron/perceptron-mk1.5',36864),('perplexity/deepseek-v4-pro-0813',1000000),('perplexity/glm-5.3',1000000),('perplexity/glm-5.3-flash',1000000),('perplexity/kimi-k3',1048576),('perplexity/nemotron-3.5-super-120b-a12b',1048576),('perplexity/pplx-embed-v1-0.6b',32000),('perplexity/pplx-embed-v1-4b',32000),('perplexity/sonar',127072),('perplexity/sonar-pro',200000),('perplexity/sonar-pro-search',200000),('perplexityai/sonar',127072),('perplexityai/sonar-pro',200000),('phi-4-reasoning',32000),('phi-4-reasoning-plus',32000),('poetools/claude-code',0),('pokee-isaac',250000),('poolside/laguna-m.1',262144),('poolside/laguna-s-2.1',1000000),('poolside/laguna-xs-2.1',262144),('pqhaz/DeepSeek-V4.1-Flash-1017-heretic',512000),('pqhaz/DeepSeek-V4.1-Flash-1017-heretic:thinking',512000),('prism',1000000),('prism-core',1000000),('prism-ml/ternary-bonsai-2-27b',262144),('prism-ml/ternary-bonsai-2-9b',262144),('public/deepseek-r1',131072),('public/deepseek-v3',131072),('public/minimax-m25',204800),('publicai/apertus-70b-instruct',65536),('publicai/apertus-8b-instruct',65536),('pulse-alpha-free',1048576),('quartz/gemini-3.1-pro-preview',1048576),('quiverai/arrow-2',131072),('quiverai/arrow-2-telos',131072),('qvq-max',131072),('qwen-3-6-plus',1000000),('qwen-3-7-max',1000000),('qwen-3-7-plus',1000000),('qwen-3-8-2-4t-a95b',262144),('qwen-3-8-27b',262144),('qwen-3-8-flash',1000000),('qwen-3-8-max',1000000),('qwen-3.6-plus',1000000),('qwen-3.8-27b',262128),('qwen-3.8-27b-flex',262128),('qwen-deep-research',1000000),('qwen-doc-turbo',131072),('qwen-flash',1000000),('qwen-image',8192),('qwen-image-2.0',8192),('qwen-image-2.0-pro',8192),('qwen-image-2.1',8192),('qwen-long',10000000),('qwen-math-plus',4096),('qwen-math-turbo',4096),('qwen-max',32768),('qwen-mt-plus',16384),('qwen-mt-turbo',16384),('qwen-omni-turbo',32768),('qwen-omni-turbo-realtime',32768)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('qwen-plus',131072),('qwen-plus-character',32768),('qwen-plus-character-ja',8192),('qwen-plus-latest',1000000),('qwen-turbo',1000000),('qwen-vl-max',131072),('qwen-vl-ocr',34096),('qwen-vl-plus',131072),('qwen.qwen3-235b-a22b-2507-v1:0',262144),('qwen.qwen3-32b-v1:0',32768),('qwen.qwen3-coder-30b-a3b-v1:0',262144),('qwen.qwen3-coder-480b-a35b-v1:0',131072),('qwen.qwen3-coder-next',262144),('qwen.qwen3-next-80b-a3b',262144),('qwen.qwen3-vl-235b-a22b',262144),('qwen/deepseek-v4-flash-0731',1000000),('qwen/deepseek-v4-pro-0813',1000000),('qwen/deepseek-v4.1-flash',1000000),('qwen/deepseek-v4.1-flash-1017',1000000),('qwen/qwen-2.5-72b-instruct',32768),('qwen/qwen-2.5-7b-instruct',32768),('qwen/qwen-2.5-7b-vision-instruct',125000),('qwen/qwen-2.5-coder-32b-instruct',32768),('qwen/qwen-flash',1000000),('qwen/qwen-image',0),('qwen/qwen-image-edit',0),('qwen/qwen-max',32768),('qwen/qwen-mt-plus',4096),('qwen/qwen-plus',1000000),('qwen/qwen2.5-coder-32b-instruct',32000),('qwen/qwen3-14b',40960),('qwen/qwen3-235b-a22b',131072),('qwen/qwen3-235b-a22b-2507',262144),('qwen/qwen3-235b-a22b-fp8',40960),('qwen/qwen3-235b-a22b-instruct-2507',131072),('qwen/qwen3-235b-a22b-instruct-2507-maas',262144),('qwen/qwen3-30b-a3b',40960),('qwen/qwen3-30b-a3b-2507',262144),('qwen/qwen3-30b-a3b-fp8',40960),('qwen/qwen3-30b-a3b-instruct-2507',262144),('qwen/qwen3-32b',131072),('qwen/qwen3-32b-fp8',40960),('qwen/qwen3-8b',41000),('qwen/qwen3-coder',262144),('qwen/qwen3-coder-30b',262144),('qwen/qwen3-coder-30b-a3b-instruct',262144),('qwen/qwen3-coder-480b-a35b-instruct',131072),('qwen/qwen3-coder-flash',1000000),('qwen/qwen3-coder-next',262144),('qwen/qwen3-coder-plus',1000000),('qwen/qwen3-embedding-4b',32000),('qwen/qwen3-embedding-8b',32768),('qwen/qwen3-max',256000),('qwen/qwen3-max-preview',256000),('qwen/qwen3-next-80b-a3b-instruct',262144),('qwen/qwen3-next-80b-a3b-thinking',131072),('qwen/qwen3-omni-30b-a3b-thinking',65536),('qwen/qwen3-reranker-8b',32768),('qwen/qwen3-vl-235b-a22b-instruct',262144),('qwen/qwen3-vl-235b-a22b-thinking',131072),('qwen/qwen3-vl-30b-a3b-instruct',262144),('qwen/qwen3-vl-30b-a3b-thinking',262144),('qwen/qwen3-vl-8b-instruct',262144),('qwen/qwen3-vl-flash',262144),('qwen/qwen3-vl-plus',262144),('qwen/qwen3.5-122b-a10b',262144),('qwen/qwen3.5-122b-a10b:thinking',131072),('qwen/qwen3.5-27b',262144),('qwen/qwen3.5-27b:thinking',260096),('qwen/qwen3.5-35b-a3b',262144),('qwen/qwen3.5-35b-a3b:thinking',260096),('qwen/qwen3.5-397b-a17b',262144),('qwen/qwen3.5-397b-a17b:thinking',262144),('qwen/qwen3.5-4b',262144),('qwen/qwen3.5-9b',262144),('qwen/qwen3.5-flash',1000000),('qwen/qwen3.5-flash-02-23',1000000),('qwen/qwen3.5-flash:thinking',991808),('qwen/qwen3.5-omni-flash',49152),('qwen/qwen3.5-omni-plus',983616),('qwen/qwen3.5-plus',1000000),('qwen/qwen3.5-plus-02-15',1000000),('qwen/qwen3.5-plus-20260420',1000000),('qwen/qwen3.5-plus:thinking',983616),('qwen/qwen3.6-27b',262144),('qwen/qwen3.6-27b:thinking',262144),('qwen/qwen3.6-35b-a3b',262144),('qwen/qwen3.6-35b-a3b:thinking',1048576),('qwen/qwen3.6-flash',1000000),('qwen/qwen3.6-max-preview',256000),('qwen/qwen3.6-plus',1000000),('qwen/qwen3.7-flash',1000000),('qwen/qwen3.7-flash:thinking',983616),('qwen/qwen3.7-max',1000000),('qwen/qwen3.7-max:thinking',1000000),('qwen/qwen3.7-plus',1000000),('qwen/qwen3.7-plus:thinking',983616),('qwen/qwen3.8-2.4t-a95b',1048576),('qwen/qwen3.8-27b',1024000),('qwen/qwen3.8-27b-antislop',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('qwen/qwen3.8-27b-cybersecurity',262144),('qwen/qwen3.8-27b-darkidol',262144),('qwen/qwen3.8-27b-fable',524288),('qwen/qwen3.8-27b-fimi',262144),('qwen/qwen3.8-27b-hemmingway',262144),('qwen/qwen3.8-27b-kimiko',262144),('qwen/qwen3.8-27b-kiwen',262144),('qwen/qwen3.8-27b-novelist',262144),('qwen/qwen3.8-27b-queen',524288),('qwen/qwen3.8-27b-swift',262144),('qwen/qwen3.8-27b-synthia',262144),('qwen/qwen3.8-27b-uncensored',1048576),('qwen/qwen3.8-27b-uncensored:thinking',1048576),('qwen/qwen3.8-27b:thinking',1048576),('qwen/qwen3.8-flash',1000000),('qwen/qwen3.8-flash-next',262144),('qwen/qwen3.8-max',1000000),('qwen/qwen3.8-max-0902',1000000),('qwen/qwen3.8-max-preview',1000000),('qwen/qwen3.8-max-prime',1000000),('qwen/qwen3.8-max:thinking',991000),('qwen/qwen3.8-omni-flash',1000000),('qwen/qwenCoder/models/Qwen3-Coder-30B-A3B-Instruct',262144),('qwen/qwenLM/models/Qwen3-30B-A3B-Instruct-2507',262144),('qwen/qwenLM/models/Qwen3-30B-A3B-Thinking-2507',262144),('qwen2-5-omni-7b',32768),('qwen2.5-coder-7b-fast',32000),('qwen2.5-vl-72b-instruct',32768),('qwen3-14b',32768),('qwen3-235b-a22b-instruct-2507',262144),('qwen3-235b-a22b-thinking',262144),('qwen3-235b-a22b-thinking-2507',262144),('qwen3-30b-a3b',32768),('qwen3-30b-a3b-thinking-2507',126000),('qwen3-32b',40960),('qwen3-5-122b-a10b',258048),('qwen3-5-27b',258048),('qwen3-5-35b-a3b',258048),('qwen3-5-397b-a17b',258048),('qwen3-5-4b',262144),('qwen3-5-9b',262144),('qwen3-5-flash',995904),('qwen3-5-plus',983616),('qwen3-6-27b',229376),('qwen3-6-35b',16384),('qwen3-6-35b-a3b',131072),('qwen3-6-flash',983616),('qwen3-6-plus',983616),('qwen3-7-flash',983616),('qwen3-7-max',983616),('qwen3-7-plus',983616),('qwen3-8-27b',262144),('qwen3-8-flash',983616),('qwen3-8-max',983616),('qwen3-8-max-0902',983616),('qwen3-8-omni-flash',1006592),('qwen3-8b',131072),('qwen3-asr-flash',53248),('qwen3-coder',262144),('qwen3-coder-480b-a35b-instruct',262000),('qwen3-coder-480b-a35b-instruct-turbo',256000),('qwen3-coder-flash',997952),('qwen3-coder-next',262144),('qwen3-coder-plus',1000000),('qwen3-coder:30b',262144),('qwen3-embedding-0.6b',8000),('qwen3-embedding-4b',32000),('qwen3-embedding-8b',32768),('qwen3-livetranslate-flash-realtime',53248),('qwen3-max',131072),('qwen3-max-2025-09-23',258048),('qwen3-max-2026-01-23',262144),('qwen3-max-preview',256000),('qwen3-next-80b',256000),('qwen3-next-80b-a3b-instruct',131072),('qwen3-next-80b-a3b-thinking',131072),('qwen3-omni-flash',65536),('qwen3-omni-flash-realtime',65536),('qwen3-reranker-4b',32768),('qwen3-tts-voicedesign',32768),('qwen3-vl-235b-a22b',131072),('qwen3-vl-235b-a22b-instruct',262144),('qwen3-vl-235b-a22b-instruct-original',32768),('qwen3-vl-30b-a3b',131072),('qwen3-vl-30b-a3b-instruct',262144),('qwen3-vl-plus',262144),('qwen3.5-0.8b',32768),('qwen3.5-122b',262144),('qwen3.5-122b-a10b',262144),('qwen3.5-27b',262144),('qwen3.5-2b',32768),('qwen3.5-35b-a3b',262144),('qwen3.5-397b-a17b',262144),('qwen3.5-397b-a17b:free',262144),('qwen3.5-4b',32768),('qwen3.5-9b',262144),('qwen3.5-flash',1000000),('qwen3.5-plus',262144),('qwen3.6',262144),('qwen3.6-27b',16384)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('qwen3.6-35b',256000),('qwen3.6-35b-a3b',262144),('qwen3.6-35b-fast',131056),('qwen3.6-35b-flex',131056),('qwen3.6-flash',983616),('qwen3.6-max-preview',240000),('qwen3.6-plus',262144),('qwen3.6-plus-free',262144),('qwen3.6:27b',262144),('qwen3.7-flash',983616),('qwen3.7-max',1000000),('qwen3.7-max-2026-06-08',1000000),('qwen3.7-plus',1000000),('qwen3.8-2.4T-A95B',262144),('qwen3.8-2.4T-A95B@eu',1000000),('qwen3.8-2.4t-a95b',1010000),('qwen3.8-27b',262144),('qwen3.8-flash',1000000),('qwen3.8-flash-free',1000000),('qwen3.8-flash-next',262144),('qwen3.8-flash-next@eu',262144),('qwen3.8-max',1000000),('qwen3.8-max-free',1000000),('qwen3.8-max-preview',1000000),('qwen3.8-omni-flash',983616),('qwen35-122b-a10b',262144),('qwen35-397b-a17b',262144),('qwen3guard-gen-0.6b',32768),('qwen3guard-gen-8b',32768),('qwq-plus',131072),('ranoai/deepseek-v4-flash',1000000),('recraft/recraft-v2',512),('recraft/recraft-v3',512),('recraft/recraft-v4',0),('recraft/recraft-v4-pro',0),('recraft/recraft-v4.1',0),('recraft/recraft-v4.1-flash',0),('recraft/recraft-v4.1-pro',0),('recraft/recraft-v4.1-utility',0),('recraft/recraft-v4.1-utility-pro',0),('recursive/flint-v1.0:free',262144),('reflection-ai/beam-1.0-501b-a23b',262144),('reflection-beam',1048576),('reflection/Beam-1.0-501B-A23B',1048576),('reflection/beam',1048576),('reflection/beam-1.0',1048576),('reflection/beam-1.0-501b-a23b',1048576),('reflection/beam-free',1048576),('reka-ai/deepseek-v4.1-flash',1048576),('reka-ai/deepseek-v4.1-flash-1017',1048576),('reka-ai/glm-5.3',1048576),('reka-ai/glm-5.3-flash',1048576),('reka-ai/reka-edge-2603',16384),('reka-edge-2603',16384),('reka/reka-edge-2603',16384),('reka/reka-flash-3',65536),('rekaai/reka-edge',16384),('rekaai/reka-flash-3',65536),('relace/relace-apply-3',256000),('relace/relace-search',256000),('ricursiveai/ripple-65b-preview',1048576),('ring-2.6-1t',262144),('ring-2.6-1t-free',262000),('runpod/glm-5.3',262144),('runpod/kimi-k3',1048576),('runpod/kimi-k3.1-pro',1048576),('runpod/kimi-k3.1-pro-highspeed',1048576),('runware/deepseek-v4-flash',1048576),('runware/deepseek-v4-pro',1048576),('runware/deepseek-v4.1-flash',1048576),('runware/deepseek-v4.1-flash-1017',1048576),('runware/gemma-4-31b-it',262144),('runware/glm-5.2',1024000),('runware/glm-5.3',1000000),('runware/glm-5.3-flash',1000000),('runware/kimi-k3',1048576),('runwayml/runway',256),('runwayml/runway-gen-4-turbo',256),('sakana-namazu',262144),('sakana/fugu-max',1000000),('sakana/fugu-ultra',1000000),('sakana/fugu-ultra-v1.1',1000000),('sakana/fugu-ultra-v2',1000000),('sakana/fugu-ultra-v2.0',1000000),('sakana/namazu',256000),('sakana/sakana-namazu',262144),('sao10k/l3-lunaris-8b',8192),('sao10k/l3.1-euryale-70b',131072),('sap-abap-1',32768),('sarvam-105b',131072),('sarvam-30b',65536),('sarvam/sarvam-105b',131072),('scaledown/extract',1000000),('scaledown/scaledown-extract-1',1000000),('scaledown/scaledown-summarize-1',1000000),('scaledown/summarize',1000000),('scaleway/deepseek-v4-flash-0731',256000),('scaleway/deepseek-v4.1-flash',256000),('scaleway/deepseek-v4.1-flash-1017',1000000),('scaleway/gemma-3-27b-it',40000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('scaleway/qwen3-235b-a22b-instruct-2507',250000),('sciforium/deepseek-v4.1-flash-1017',1048576),('scx-ai-gp/deepseek-v4.1-flash',1000000),('scx-ai-gp/glm-5.2',1000000),('scx-ai-gp/glm-5.2-fast',1000000),('scx-ai-gp/glm-5.3',1000000),('scx-ai-gp/glm-5.3-fast',1000000),('scx-ai-gp/glm-5.3-flash',1048576),('scx-ai-gp/kimi-k2.7-code',262144),('scx-ai-gp/kimi-k3',1048576),('scx-ai-gp/qwen3.8-max',1000000),('scx-ai/gpt-oss-120b',131072),('scx-ai/minimax-m2.7',196608),('scx-ai/qwen3-32b',32768),('seed-1-6-250615',256000),('seed-1-6-250915',256000),('seed-1-6-flash-250715',256000),('seed-1-8-251228',256000),('seed-1.8',256000),('seed-2-0-code',229096),('seed-2-0-code-preview-260328',262144),('seed-2-0-lite',229096),('seed-2-0-lite-260428',262144),('seed-2-0-mini',229156),('seed-2-0-mini-260428',262144),('seed-2-0-pro',229096),('seed-2-0-pro-260328',262144),('seed-2-1-turbo',229093),('seed-2.0-code',256000),('seed-2.0-mini',256000),('seed-2.0-pro',256000),('sensenova-6.8-flash-lite',262144),('sference/deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('sference/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('shisa-ai/shisa-v2.1-llama3.3-70b',32768),('sicariussicariistuff/assistant-pepe-32b',40960),('siliconflow/deepseek-r1-0528',163840),('siliconflow/deepseek-v3-0324',163840),('siliconflow/deepseek-v3.1-terminus',163840),('siliconflow/deepseek-v3.2',163840),('solar-mini',32768),('solar-mini4',524288),('solar-pro2',65536),('solar-pro3',131072),('solar-pro4',524288),('sonar',130000),('sonar-pro',200000),('sonar-reasoning',127000),('soob3123/GrayLine-Qwen3-8B',32768),('soob3123/Veiled-Calla-12B',32768),('soob3123/amoral-gemma3-27B-v2',32768),('space-bunny',1048576),('space-bunny-free',1048576),('spacexai/grok-4.20-multi-agent',2000000),('spacexai/grok-4.20-multi-agent-beta',2000000),('spacexai/grok-4.20-non-reasoning',2000000),('spacexai/grok-4.20-non-reasoning-beta',2000000),('spacexai/grok-4.20-reasoning',2000000),('spacexai/grok-4.20-reasoning-beta',2000000),('spacexai/grok-4.3',1000000),('spacexai/grok-4.5',500000),('spacexai/grok-4.6',500000),('spacexai/grok-4.7',500000),('spacexai/grok-build-0.1',256000),('spacexai/grok-imagine-image',16000),('spacexai/grok-imagine-image-2.0',64000),('spacexai/grok-imagine-video',0),('spacexai/grok-imagine-video-1.5',1024),('spacexai/grok-imagine-video-1.5-lite',1024),('spacexai/grok-stt',0),('spacexai/grok-tts',15000),('speakleash/Bielik-11B-v3.0-Instruct',32000),('speakleash/bielik-11b-v3.0-instruct',32768),('stabilityai/stablediffusionxl',200),('stable-diffusion-3.5-large',256),('standardcompute',1000000),('stealth/crouton-alpha',1048576),('stealth/glyph-cluster',256000),('step-3-5-flash',262144),('step-3-5-flash-2603',262144),('step-3-7-flash',262144),('step-3-7-flash:free',256000),('step-3.5-flash',256000),('step-3.5-flash-2603',256000),('step-3.7-flash',262144),('step-3.7-flash:free',256000),('step-5-preview',1000000),('step-5-preview-free',1000000),('step-router-v1',256000),('step-tts-2',0),('stepaudio-2.5-asr',0),('stepaudio-2.5-tts',0),('stepfun-ai/Step-3.5-Flash',262000),('stepfun-ai/Step-3.7-Flash',262144),('stepfun-ai/Step-5-Preview',1048576),('stepfun-ai/gelab-zero-4b-preview',8192),('stepfun-ai/step-3.5-flash',262144),('stepfun-ai/step-3.5-flash-2603',262144),('stepfun-ai/step-5-preview',1048576),('stepfun/Step-3.5-Flash',256000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('stepfun/Step-3.7-Flash',256000),('stepfun/Step-5-Preview',1000000),('stepfun/step-3.5-flash',262144),('stepfun/step-3.7-flash',262144),('stepfun/step-3.7-flash:thinking',262144),('stepfun/step-5-preview',1048576),('subconscious/deepseek-v4.1-flash-marathon',5000000),('subconscious/glm-5.3-marathon',5000000),('swiss-ai/Apertus-v1.5-70B',100000),('synth-2.5-flash',30000),('synth-2.5-pro',30000),('tc-code-latest',131072),('tencent/Hunyuan-A13B-Instruct',131000),('tencent/Hy3',262144),('tencent/Hy4',0),('tencent/Hy4-preview',1000000),('tencent/deepseek-v4-flash',1000000),('tencent/deepseek-v4-pro',1000000),('tencent/deepseek-v4-pro-0813',1000000),('tencent/deepseek-v4.1-flash',1000000),('tencent/deepseek-v4.1-flash-1017',1000000),('tencent/glm-5',200000),('tencent/glm-5-turbo',200000),('tencent/glm-5.1',200000),('tencent/glm-5.2',1000000),('tencent/glm-5.3',1000000),('tencent/glm-5.3-flash',1000000),('tencent/glm-5.3-flashx',1000000),('tencent/glm-5v-turbo',200000),('tencent/hunyuan-a13b-instruct',131072),('tencent/hy-mt2-1.8b',8192),('tencent/hy-mt2-30b-a3b',8192),('tencent/hy-mt2-7b',8192),('tencent/hy-mt2-lite',8000),('tencent/hy-mt2-plus',8192),('tencent/hy-mt2-pro',8000),('tencent/hy3',262144),('tencent/hy3-free',256000),('tencent/hy3-paid',256000),('tencent/hy3-preview',262144),('tencent/hy4',1048576),('tencent/hy4-preview',1048576),('tencent/kimi-k2.6',262144),('tencent/kimi-k2.7-code',262144),('tencent/kimi-k2.7-code-highspeed',262144),('tencent/kimi-k2.8-preview',1000000),('tencent/kimi-k3',1048576),('tencent/mimo-v2.6-flash',1000000),('tencent/mimo-v2.6-pro',1000000),('tencent/minimax-m2.7',200000),('tencent/minimax-m3',1000000),('tencent/step-5-preview',1000000),('tensorx/deepseek/deepseek-r1-0528',164000),('tensorx/deepseek/deepseek-v4-flash-0731',1048576),('tensorx/deepseek/deepseek-v4-pro-0813',1048576),('tensorx/deepseek/deepseek-v4.1-flash',1048576),('tensorx/deepseek/deepseek-v4.1-flash-1017',1048576),('tensorx/moonshotai/kimi-k2.5',262144),('text-embedding-3-large',8191),('text-embedding-3-small',8191),('text-embedding-ada-002',8192),('text-max',1000000),('text-prime',196608),('thedrummer/cydonia-24b-v4.1',131072),('thedrummer/skyfall-36b-v2',32768),('thedrummer/unslopnemo-12b',1024000),('thinkingmachines/Inkling',1048576),('thinkingmachines/Inkling-NVFP4',1048576),('thinkingmachines/Inkling-Small',524288),('thinkingmachines/Inkling-Small:peft:262144',262144),('thinkingmachines/Inkling-Small:peft:262144:sampling-nvfp4',262144),('thinkingmachines/Inkling-Small:thinking',524288),('thinkingmachines/Inkling:peft:262144',262144),('thinkingmachines/Inkling:peft:262144:sampling-nvfp4',262144),('thinkingmachines/inkling',524288),('thinkingmachines/inkling-small',524288),('thinkingmachines/inkling:thinking',1040000),('tiny-aya-earth',8000),('tiny-aya-fire',8000),('tiny-aya-global',8000),('tiny-aya-water',8000),('together-ai/deepseek-v4-pro',1048576),('together-ai/deepseek-v4.1-flash',1048576),('together-ai/deepseek-v4.1-flash-1017',1048576),('together-ai/glm-4.7',202752),('together-ai/glm-5.3',1048576),('together-ai/glm-5.3-flash',1048576),('together-ai/gpt-oss-120b',131072),('together-ai/kimi-k3',1000000),('together-ai/minimax-m3',524288),('together-ai/minimax-m3.1-flash',1048576),('together-ai/muse-glimmer-30b',131072),('together_ai/deepseek-ai/DeepSeek-V4-Pro-0813',1048576),('together_ai/deepseek-ai/DeepSeek-V4.1-Flash',1048576),('together_ai/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('together_ai/meta-models/Muse-Glimmer-30B',131072),('together_ai/openai/gpt-oss-120b',131072),('together_ai/reflection/Beam-1.0-501B-A23B',1048576),('together_ai/thinkingmachines/Inkling',524288),('tongyi-intent-detect-v3',8192)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('topaz/proteus',0),('topaz/starlight-precise-2.6',0),('topaz/wonder-3.5',0),('topazlabs-co/topazlabs',204),('trendyol-asure-12b',40960),('trinity-large-preview-free',131072),('trinity-large-thinking',262144),('trustedrouter/auto',1000000),('trustedrouter/cheap',1000000),('trustedrouter/e2e',1000000),('trustedrouter/fast',1000000),('trustedrouter/synth',1000000),('trustedrouter/synth-code',1000000),('trustedrouter/zdr',1000000),('trytako/tako',2048),('umans-coder',1048576),('umans-deepseek-v4-flash-0731',1048576),('umans-deepseek-v4.1-flash',1048576),('umans-deepseek-v4.1-flash-1017',1048576),('umans-flash',262144),('umans-glm-5.3',1048576),('umans-glm-5.3-flash',1048576),('umans-kimi-k3',1048576),('umans-qwen3.6-35b-a3b',262144),('unbiased/pareto',262144),('unbiased/pareto-26.10',1048576),('unbiased/pareto-26.9',262144),('undi95/remm-slerp-l2-13b',6144),('universal-summarizer',32768),('unsloth/gemma-3-12b-it',131072),('unsloth/qwen3.8-27b-gguf',101072),('upstage/solar-mini4',524288),('upstage/solar-mini4:thinking',524288),('upstage/solar-pro-3',131072),('upstage/solar-pro2',65536),('upstage/solar-pro3',131072),('upstage/solar-pro4',524288),('upstage/solar-pro4:thinking',524288),('us.amazon.nova-2-lite-v1:0',1000000),('us.amazon.nova-lite-v1:0',300000),('us.amazon.nova-premier-v1:0',1000000),('us.amazon.nova-pro-v1:0',300000),('us.anthropic.claude-fable-5',1000000),('us.anthropic.claude-fable-5-1',1000000),('us.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('us.anthropic.claude-haiku-5-5',1000000),('us.anthropic.claude-opus-4-1-20250805-v1:0',200000),('us.anthropic.claude-opus-4-5-20251101-v1:0',200000),('us.anthropic.claude-opus-4-6-v1',1000000),('us.anthropic.claude-opus-4-7',1000000),('us.anthropic.claude-opus-4-8',1000000),('us.anthropic.claude-opus-5',1000000),('us.anthropic.claude-opus-5-5',1000000),('us.anthropic.claude-sonnet-4-20250514-v1:0',200000),('us.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('us.anthropic.claude-sonnet-4-6',1000000),('us.anthropic.claude-sonnet-5',1000000),('us.anthropic.claude-sonnet-5-5',1000000),('us.meta.llama4-maverick-17b-instruct-v1:0',1000000),('us.meta.llama4-scout-17b-instruct-v1:0',10000000),('us.moonshotai.kimi-k3',1048576),('us.openai.gpt-5.6-luna',1050000),('us.openai.gpt-5.6-sol',1050000),('us.openai.gpt-5.6-terra',1050000),('us.openai.gpt-6-astra',1050000),('us.openai.gpt-6-luna',1050000),('us.openai.gpt-6-sol',1050000),('us.openai.gpt-6.1-sol',1050000),('us.openai.gpt-6.1-terra',1050000),('us.writer.palmyra-x4-v1:0',122880),('us.writer.palmyra-x5-v1:0',1040000),('us.xai.grok-4.6',500000),('us.xai.grok-4.7',500000),('us.zai.glm-5.3',1000000),('vertex-anthropic/claude-haiku-4-5',200000),('vertex-anthropic/claude-opus-4-5-20251101',200000),('vertex-anthropic/claude-opus-4-6',1000000),('vertex-anthropic/claude-opus-4-7',1000000),('vertex-anthropic/claude-sonnet-4-5',200000),('vertex-anthropic/claude-sonnet-4-6',1000000),('vertex-anthropic/claude-sonnet-5',1000000),('vertex-openai/grok-4-20-non-reasoning',2000000),('vertex-openai/grok-4-20-reasoning',2000000),('vertex-openai/grok-4-6',500000),('vertex-openai/grok-4-7',524288),('vertex/gemini-2.5-flash-image',32768),('vertex/gemini-3-flash-preview',1048576),('vertex/gemini-3-pro-image',65536),('vertex/gemini-3.1-flash-image',131072),('vertex/gemini-3.1-flash-lite',1048576),('vertex/gemini-3.1-flash-lite-image',65536),('vertex/gemini-3.1-flash-lite@eu',1048576),('vertex/gemini-3.1-flash-lite@us',1048576),('vertex/gemini-3.1-pro-preview',1048576),('vertex/gemini-3.5-flash',1048576),('vertex/gemini-3.5-flash-lite',1048576),('vertex/gemini-3.5-flash-lite@eu',1048576),('vertex/gemini-3.5-flash-lite@us',1048576),('vertex/gemini-3.5-flash@eu',1048576),('vertex/gemini-3.5-flash@us',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('vertex/gemini-3.6-flash',1048576),('vertex/gemini-3.6-flash@eu',1048576),('vertex/gemini-3.6-flash@us',1048576),('vertex/gemini-3.7-flash',1048576),('vertex/gemini-3.7-flash@eu',1048576),('vertex/gemini-3.7-flash@us',1048576),('vertex/gemini-3.8-flash',1048576),('vertex/gemini-3.8-flash@eu',1048576),('vertex/gemini-3.8-flash@us',1048576),('vertex/gemini-4-argon',1048576),('vertex/gemini-4-argon@eu',1048576),('vertex/gemini-4-argon@us',1048576),('vertex/gemini-flash-latest',1048576),('vertex/gemini-nano-banana-2.1',131072),('vertex/gemini-pro-latest',1048576),('vispark/vision-large',1000000),('vispark/vision-medium',1000000),('vispark/vision-small',1000000),('viv-fast',1000000),('volcengine/doubao-seed-1.8',256000),('volcengine/doubao-seed-2.0-code',256000),('volcengine/doubao-seed-2.0-lite',256000),('volcengine/doubao-seed-2.0-mini',256000),('volcengine/doubao-seed-2.0-pro',256000),('volcengine/doubao-seed-2.1-pro',256000),('volcengine/doubao-seed-2.1-turbo',256000),('volcengine/doubao-seed-character',256000),('volcengine/doubao-seed-code',256000),('volcengine/doubao-seed-evolving',256000),('voxtral-mini-3b',32000),('voxtral-mini-latest',0),('voxtral-mini-tts-latest',0),('voxtral-small-24b-2507',32768),('voxtral-small-2507',32000),('voxtral-small-latest',32768),('voyage/rerank-2.5',32000),('voyage/rerank-2.5-lite',32000),('voyage/rerank-3',32000),('voyage/rerank-3-lite',32000),('voyage/voyage-3-large',32000),('voyage/voyage-3.5',32000),('voyage/voyage-3.5-lite',32000),('voyage/voyage-4',32000),('voyage/voyage-4-large',32000),('voyage/voyage-4-lite',32000),('voyage/voyage-code-2',16000),('voyage/voyage-code-3',32000),('voyage/voyage-finance-2',32000),('voyage/voyage-law-2',16000),('wan2-2-t2v-a14b',100),('wan2.7-image',8192),('wan2.7-image-pro',8192),('wanx/wan-v2-6',400000),('whisper-large-v3',448),('whisper-large-v3-turbo',448),('writer.palmyra-x4-v1:0',122880),('writer.palmyra-x5-v1:0',1040000),('writer/palmyra-x5',1040000),('x-ai/grok-4',256000),('x-ai/grok-4-20-0309-non-reasoning',2000000),('x-ai/grok-4-fast',2000000),('x-ai/grok-4-fast-non-reasoning',2000000),('x-ai/grok-4-fast-reasoning',2000000),('x-ai/grok-4.1-fast',2000000),('x-ai/grok-4.1-fast-non-reasoning',2000000),('x-ai/grok-4.1-fast-reasoning',20000000),('x-ai/grok-4.2-fast',2000000),('x-ai/grok-4.2-fast-non-reasoning',2000000),('x-ai/grok-4.20',2000000),('x-ai/grok-4.20-multi-agent',2000000),('x-ai/grok-4.3',1000000),('x-ai/grok-4.5',500000),('x-ai/grok-4.6',500000),('x-ai/grok-4.7',500000),('x-ai/grok-build-0.1',256000),('x-ai/grok-code-fast-1',256000),('x-ai/grok-imagine-image-2.0',66000),('x-ai/grok-latest',500000),('x-ai/grok-voice-stt-1.0',15000),('x-ai/grok-voice-tts-1.0',15000),('x-preview-f-free',1000000),('xai.grok-4.20-non-reasoning',1000000),('xai.grok-4.20-reasoning',1000000),('xai.grok-4.3',1000000),('xai.grok-4.6',500000),('xai/grok-3',131072),('xai/grok-3-mini',131072),('xai/grok-4',256000),('xai/grok-4-1-fast-non-reasoning',2000000),('xai/grok-4-20-beta-0309-non-reasoning',2000000),('xai/grok-4-20-beta-0309-reasoning',2000000),('xai/grok-4-3',1000000),('xai/grok-4-5',500000),('xai/grok-4-6',500000),('xai/grok-4-7',500000),('xai/grok-4-fast-non-reasoning',2000000),('xai/grok-4-fast-reasoning',2000000),('xai/grok-4.20-0309-non-reasoning',2000000),('xai/grok-4.20-0309-reasoning',2000000),('xai/grok-4.20-non-reasoning',2000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('xai/grok-4.20-reasoning',2000000),('xai/grok-4.3',1000000),('xai/grok-4.5',500000),('xai/grok-4.6',500000),('xai/grok-4.7',500000),('xai/grok-build-0-1',256000),('xai/grok-build-0.1',256000),('xai/grok-code-fast-1',256000),('xai/grok-latest',500000),('xiaomi-mimo-v2-5',1000000),('xiaomi-mimo-v2-6-flash',1000000),('xiaomi-mimo-v2.5',1048576),('xiaomi-mimo-v2.5-free',1048576),('xiaomi-mimo-v2.5-pro',1048576),('xiaomi-mimo-v2.5-pro-free',1048576),('xiaomi-mimo/mimo-v2.6-flash',1048576),('xiaomi-mimo/mimo-v2.6-pro',1048576),('xiaomi-mimo/mimo-v2.6-pro-ultraspeed',1048576),('xiaomi/mimo-v2.5',1000000),('xiaomi/mimo-v2.5-pro',1050000),('xiaomi/mimo-v2.5-pro:thinking',1048576),('xiaomi/mimo-v2.5:thinking',1048576),('xiaomi/mimo-v2.6-flash',1050000),('xiaomi/mimo-v2.6-flash-abliterated',1048576),('xiaomi/mimo-v2.6-flash-uncensored',1048576),('xiaomi/mimo-v2.6-flash-uncensored:thinking',1048576),('xiaomi/mimo-v2.6-pro',1050000),('xiaomi/mimo-v2.6-pro-ultraspeed',1048576),('xiaomimimo/mimo-v2-flash',262144),('xiaomimimo/mimo-v2.5',1048576),('xiaomimimo/mimo-v2.5-pro',1048576),('xiaomimimo/mimo-v2.6-flash',1048576),('xiaomimimo/mimo-v2.6-pro',1048576),('xingchen-agi/xing4.0-29b-a4b',262144),('xingchen-agi/xing4.0-29b-a4b:free',262144),('xpersona-frieren-coder',1000000),('xpersona-gpt-5.5',1000000),('z-ai-glm-5-3',1000000),('z-ai-glm-5-3-flash',1048576),('z-ai-glm-5-turbo',200000),('z-ai-glm-5v-turbo',200000),('z-ai/GLM-4.6-turbo',204800),('z-ai/GLM-4.6-turbo:thinking',204800),('z-ai/autoglm-phone-9b',12800),('z-ai/glm-4.5',131072),('z-ai/glm-4.5-air',131072),('z-ai/glm-4.5v',65536),('z-ai/glm-4.5v:thinking',65536),('z-ai/glm-4.6',204800),('z-ai/glm-4.6-original',256000),('z-ai/glm-4.6:thinking',200000),('z-ai/glm-4.6v',131072),('z-ai/glm-4.6v-flash',200000),('z-ai/glm-4.6v-flash-free',200000),('z-ai/glm-4.7',204800),('z-ai/glm-4.7-flash',200000),('z-ai/glm-4.7-flash-free',200000),('z-ai/glm-4.7-flash:thinking',200000),('z-ai/glm-4.7-flashx',200000),('z-ai/glm-4.7-original',200000),('z-ai/glm-4.7-original:thinking',200000),('z-ai/glm-4.7:thinking',200000),('z-ai/glm-5',204800),('z-ai/glm-5-original',200000),('z-ai/glm-5-original:thinking',200000),('z-ai/glm-5-turbo',202752),('z-ai/glm-5.1',204800),('z-ai/glm-5.1:thinking',200000),('z-ai/glm-5.2',1048576),('z-ai/glm-5.2:thinking',1048576),('z-ai/glm-5.3',1048576),('z-ai/glm-5.3-flash',1048576),('z-ai/glm-5.3-flash-apex',1048576),('z-ai/glm-5.3-flash-apex-abliterated',1048576),('z-ai/glm-5.3-flash-cybersecurity',1048576),('z-ai/glm-5.3-flash-free',1000000),('z-ai/glm-5.3-flash-uncensored',1048576),('z-ai/glm-5.3-flashx',1048576),('z-ai/glm-5.3-flashx-legal',1048576),('z-ai/glm-5.3-free',1000000),('z-ai/glm-5.3-prime',1000000),('z-ai/glm-5.3-uncensored',1048576),('z-ai/glm-5.3:thinking',1048576),('z-ai/glm-5:thinking',200000),('z-ai/glm-5v-turbo',202752),('z-ai/glm-5v-turbo:thinking',202800),('z-ai/glm-image',10240),('z-ai/glm-latest',1048576),('zai-glm-5-1',198000),('zai-glm-5-2',1048576),('zai-glm-5-3',1048576),('zai-glm-5-3-flash',1048576),('zai-glm-5.1',200000),('zai-org-glm-4.6',198000),('zai-org-glm-4.7',198000),('zai-org-glm-5',198000),('zai-org-glm-5-1',200000),('zai-org-glm-5-2',1000000),('zai-org/AutoGLM-Phone-9B-Multilingual',65536),('zai-org/GLM-4.5',131072)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('zai-org/GLM-4.5-Air',131000),('zai-org/GLM-4.5-FP8',131072),('zai-org/GLM-4.5V',65536),('zai-org/GLM-4.6',200000),('zai-org/GLM-4.6V-Flash',131072),('zai-org/GLM-4.7',204800),('zai-org/GLM-4.7-Flash',200000),('zai-org/GLM-5',205000),('zai-org/GLM-5-FP8',202752),('zai-org/GLM-5.1',205000),('zai-org/GLM-5.1-FP8',202752),('zai-org/GLM-5.1-TEE',202752),('zai-org/GLM-5.2',1048576),('zai-org/GLM-5.2-FP8',1000000),('zai-org/GLM-5.2-Fast',1000000),('zai-org/GLM-5.2-TEE',1048576),('zai-org/GLM-5.3',1048576),('zai-org/GLM-5.3-Fast',1048576),('zai-org/GLM-5.3-Flash',1048576),('zai-org/GLM-5.3-Flash:peft:262144',262144),('zai-org/GLM-5.3:peft:262144',262144),('zai-org/GLM-5V-Turbo',200000),('zai-org/autoglm-phone-9b-multilingual',65536),('zai-org/glm-4.5',131072),('zai-org/glm-4.5-air',131072),('zai-org/glm-4.5v',65536),('zai-org/glm-4.6',204800),('zai-org/glm-4.6v',131072),('zai-org/glm-4.7',204800),('zai-org/glm-4.7-flash',200000),('zai-org/glm-4.7-maas',200000),('zai-org/glm-5',202800),('zai-org/glm-5-maas',200000),('zai-org/glm-5.1',202000),('zai-org/glm-5.2',1048576),('zai-org/glm-5.2-maas',1000000),('zai-org/glm-5.3',1048576),('zai-org/glm-5.3-flash',1048550),('zai.glm-4.7',202752),('zai.glm-4.7-flash',202752),('zai.glm-5',202752),('zai/GLM-5.1',200000),('zai/GLM-5.2',1000000),('zai/glm-4.5-flash',131072),('zai/glm-4.6',200000),('zai/glm-4.7',200000),('zai/glm-4.7-flash',200000),('zai/glm-4.7-flashx',200000),('zai/glm-5',202800),('zai/glm-5-turbo',202800),('zai/glm-5.1',200000),('zai/glm-5.2',1000000),('zai/glm-5.2-fast',1000000),('zai/glm-5.3',1000000),('zai/glm-5.3-fast',1048576),('zai/glm-5.3-flash',1048576),('zai/glm-5.3-flashx',1000000),('zai/glm-5.3-flashx-legal',1000000),('zai/glm-5v-turbo',200000),('zdev',1000000),('zhipu/glm-5.2',1000000),('zhipu/glm-5.3',1024000),('~anthropic/claude-fable-latest',1000000),('~anthropic/claude-haiku-latest',1000000),('~anthropic/claude-opus-latest',1000000),('~anthropic/claude-sonnet-latest',1000000),('~deepseek/deepseek-flash-latest',1048576),('~deepseek/deepseek-pro-latest',1048576),('~deepseek/deepseek-v4-flash-latest',1048576),('~google/gemini-flash-latest',1048576),('~google/gemini-pro-latest',1048576),('~moonshotai/kimi-latest',1048576),('~openai/gpt-astra-latest',1050000),('~openai/gpt-luna-latest',1050000),('~openai/gpt-mini-latest',400000),('~openai/gpt-sol-latest',1050000),('~openai/gpt-terra-latest',1050000),('~unbiased/pareto-latest',1048576),('~x-ai/grok-latest',500000),('~z-ai/glm-flash-latest',1048576),('~z-ai/glm-latest',1048576)",
            "ALTER TABLE model_operation RENAME TO model_operation_68",
            "CREATE TABLE model_operation(\n operation_id INTEGER PRIMARY KEY NOT NULL CHECK(operation_id>0),\n turn_id INTEGER NOT NULL REFERENCES turn(turn_id),\n session_ref TEXT NOT NULL,\n settings_revision INTEGER NOT NULL CHECK(settings_revision>0),\n input_cutoff INTEGER NOT NULL CHECK(input_cutoff>0),\n admission_position INTEGER NOT NULL CHECK(admission_position>0),\n purpose INTEGER NOT NULL DEFAULT 0 CHECK(purpose IN (0,1)),\n compaction_trigger INTEGER CHECK(compaction_trigger IS NULL OR compaction_trigger>0),\n output_reservation INTEGER NOT NULL CHECK(output_reservation>=0),\n reasoning_effort TEXT CHECK(reasoning_effort IS NULL OR (reasoning_effort='none' OR reasoning_effort='low' OR reasoning_effort='medium' OR reasoning_effort='high' OR reasoning_effort='xhigh' OR reasoning_effort='max')),\n output_item_count INTEGER CHECK(output_item_count IS NULL OR output_item_count>=0),\n attempt_ordinal INTEGER NOT NULL CHECK(attempt_ordinal BETWEEN 1 AND 4),\n auth_refresh_claimed INTEGER NOT NULL DEFAULT 0 CHECK(auth_refresh_claimed IN (0,1)),\n retry_due_at_ms INTEGER CHECK(retry_due_at_ms IS NULL OR retry_due_at_ms>=0),\n last_failure_code TEXT CHECK(last_failure_code IS NULL OR length(CAST(last_failure_code AS BLOB)) BETWEEN 1 AND 96),\n resolution_code TEXT CHECK(resolution_code IS NULL OR length(CAST(resolution_code AS BLOB)) BETWEEN 1 AND 96),\n resolution_content_id INTEGER REFERENCES content(content_id),\n response_id TEXT CHECK(response_id IS NULL OR length(CAST(response_id AS BLOB))<=256),\n model_evidence BLOB CHECK(model_evidence IS NULL OR length(model_evidence) BETWEEN 7 AND 775),\n request_id TEXT CHECK(request_id IS NULL OR length(CAST(request_id AS BLOB))<=256),\n usage_uncached_tokens INTEGER CHECK(usage_uncached_tokens IS NULL OR usage_uncached_tokens>=0),\n usage_cache_read_tokens INTEGER CHECK(usage_cache_read_tokens IS NULL OR usage_cache_read_tokens>=0),\n usage_cache_write_tokens INTEGER CHECK(usage_cache_write_tokens IS NULL OR usage_cache_write_tokens>=0),\n usage_output_tokens INTEGER CHECK(usage_output_tokens IS NULL OR usage_output_tokens>=0),\n interrupted_by_command_key TEXT REFERENCES core_command(command_key),\n attempt_at INTEGER CHECK(attempt_at IS NULL OR attempt_at>0),\n retry_scheduled_at INTEGER CHECK(retry_scheduled_at IS NULL OR retry_scheduled_at>0),\n resolved_at INTEGER CHECK(resolved_at IS NULL OR resolved_at>0),\n history_floor INTEGER CHECK(history_floor IS NULL OR history_floor>0),\n history_level INTEGER CHECK(history_level IS NULL OR history_level BETWEEN 1 AND 3),\n history_dropped INTEGER CHECK(history_dropped IS NULL OR history_dropped>=0),\n tool_set_id INTEGER NOT NULL REFERENCES tool_set(tool_set_id) CHECK(tool_set_id>0),\n effort_source_revision INTEGER NOT NULL DEFAULT 1 CHECK(effort_source_revision>0 AND effort_source_revision<=settings_revision),\n previous_reasoning_effort TEXT CHECK(previous_reasoning_effort IS NULL OR (previous_reasoning_effort='none' OR previous_reasoning_effort='low' OR previous_reasoning_effort='medium' OR previous_reasoning_effort='high' OR previous_reasoning_effort='xhigh' OR previous_reasoning_effort='max')),\n effort_update INTEGER NOT NULL DEFAULT 0 CHECK(effort_update IN (0,1) AND (effort_update=0 OR reasoning_effort IS NOT NULL)),\n previous_effort_override TEXT CHECK(previous_effort_override IS NULL OR (previous_effort_override='none' OR previous_effort_override='low' OR previous_effort_override='medium' OR previous_effort_override='high' OR previous_effort_override='xhigh' OR previous_effort_override='max')), latency_ms INTEGER CHECK(latency_ms IS NULL OR latency_ms>=0), first_event_ms INTEGER CHECK(first_event_ms IS NULL OR first_event_ms>=0),\n context_window INTEGER NOT NULL CHECK(context_window BETWEEN 0 AND 4294967295),\n UNIQUE(operation_id,session_ref),\n FOREIGN KEY(session_ref,settings_revision) REFERENCES session_revision(session_ref,revision),\n CHECK((usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR (usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND usage_output_tokens IS NOT NULL)),\n CHECK((resolution_code IS NULL AND retry_due_at_ms IS NOT NULL) OR (resolution_code IS NOT NULL AND retry_due_at_ms IS NULL)),\n CHECK((resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at IS NOT NULL AND retry_scheduled_at IS NULL AND resolved_at IS NULL) OR (resolution_code IS NULL AND retry_due_at_ms>0 AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND resolved_at IS NULL) OR (resolution_code IS NOT NULL AND attempt_at IS NULL AND retry_scheduled_at IS NULL AND resolved_at IS NOT NULL)),\n CHECK(((resolution_code IS 'interrupted') AND interrupted_by_command_key IS NOT NULL) OR (coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL)),\n CHECK((history_floor IS NULL AND history_level IS NULL AND history_dropped IS NULL) OR (history_floor IS NOT NULL AND purpose=1 AND ((history_level IS NULL AND history_dropped IS NULL) OR (history_level IS NOT NULL AND history_dropped IS NOT NULL))))\n) STRICT",
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,compaction_trigger,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,auth_refresh_claimed,retry_due_at_ms,last_failure_code,resolution_code,resolution_content_id,response_id,model_evidence,request_id,usage_uncached_tokens,usage_cache_read_tokens,usage_cache_write_tokens,usage_output_tokens,interrupted_by_command_key,attempt_at,retry_scheduled_at,resolved_at,history_floor,history_level,history_dropped,tool_set_id,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override,latency_ms,first_event_ms,context_window) SELECT old.operation_id,old.turn_id,old.session_ref,old.settings_revision,old.input_cutoff,old.admission_position,old.purpose,old.compaction_trigger,old.output_reservation,old.reasoning_effort,old.output_item_count,old.attempt_ordinal,old.auth_refresh_claimed,old.retry_due_at_ms,old.last_failure_code,old.resolution_code,old.resolution_content_id,old.response_id,old.model_evidence,old.request_id,old.usage_uncached_tokens,old.usage_cache_read_tokens,old.usage_cache_write_tokens,old.usage_output_tokens,old.interrupted_by_command_key,old.attempt_at,old.retry_scheduled_at,old.resolved_at,old.history_floor,old.history_level,old.history_dropped,old.tool_set_id,old.effort_source_revision,old.previous_reasoning_effort,old.effort_update,old.previous_effort_override,old.latency_ms,old.first_event_ms,coalesce(pinned.context_window,128000) FROM model_operation_68 old JOIN session_revision r ON r.session_ref=old.session_ref AND r.revision=old.settings_revision LEFT JOIN operation_window_backfill pinned ON pinned.model_id=r.model",
            "DROP TABLE model_operation_68",
            "CREATE INDEX model_operation_retry_due ON model_operation(retry_due_at_ms,operation_id) WHERE resolution_code IS NULL AND attempt_ordinal<4",
            "CREATE INDEX model_operation_retry_exhausted ON model_operation(operation_id) WHERE resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal=4",
            "CREATE INDEX model_operation_session_history ON model_operation(session_ref,operation_id)",
            "CREATE INDEX model_operation_turn_history ON model_operation(turn_id,operation_id)",
            "CREATE INDEX model_operation_admission ON model_operation(session_ref,admission_position)",
            "CREATE INDEX model_operation_context_history ON model_operation(session_ref,admission_position) WHERE (resolution_code='answer' OR resolution_code='compacted' OR resolution_code='tool_proposals')",
            "CREATE INDEX model_operation_compaction_bases ON model_operation(session_ref,admission_position) WHERE purpose=1 AND resolution_code='compacted'",
            "CREATE UNIQUE INDEX model_operation_effort_source ON model_operation(operation_id,session_ref,effort_source_revision)",
            "DROP TABLE operation_window_backfill",
        },
        .mysql = &.{
            "CREATE TEMPORARY TABLE operation_window_backfill(model_id VARCHAR(256) NOT NULL PRIMARY KEY,context_window BIGINT NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('@cf/deepseek-ai/deepseek-r1-distill-qwen-32b',80000),('@cf/deepseek-ai/deepseek-v4-flash-0731',1048576),('@cf/deepseek-ai/deepseek-v4-pro-0813',1048576),('@cf/deepseek-ai/deepseek-v4.1-flash-1017',1048576),('@cf/google/gemma-4-26b-a4b-it',256000),('@cf/ibm-granite/granite-4.0-h-micro',131000),('@cf/meta/llama-3.1-8b-instruct-fp8',32000),('@cf/meta/llama-3.2-1b-instruct',60000),('@cf/meta/llama-3.2-3b-instruct',80000),('@cf/meta/llama-3.3-70b-instruct-fp8-fast',24000),('@cf/meta/llama-4-scout-17b-16e-instruct',131000),('@cf/meta/llama-guard-3-8b',131072),('@cf/moonshotai/kimi-k2.6',262144),('@cf/moonshotai/kimi-k2.7-code',262144),('@cf/nvidia/nemotron-3-120b-a12b',256000),('@cf/qwen/qwen2.5-coder-32b-instruct',32768),('@cf/qwen/qwen3-30b-a3b-fp8',32768),('@cf/qwen/qwen3.8-27b',262144),('@cf/qwen/qwq-32b',24000),('@cf/zai-org/glm-4.7-flash',131072),('@cf/zai-org/glm-5.2',262144),('@cf/zai-org/glm-5.3',1048576),('@cf/zai-org/glm-5.3-flash',1048576),('Agents-A1',262000),('Beam-1.0-501B-A23B',1048576),('ByteDance-Seed/Seed-OSS-36B-Instruct',262000),('ByteDance/Seed-2.0-code',256000),('ByteDance/Seed-2.0-mini',256000),('ByteDance/Seed-2.0-pro',256000),('DeepSeek-V3.1',131072),('DeepSeek-V3.2',32768),('DeepSeek-V4-Flash',1048576),('DeepSeek-V4-Flash-0731',1000000),('DeepSeek-V4-Flash-Vision-Exp',1000000),('DeepSeek-V4-Pro',1000000),('DeepSeek-V4-Pro-0813',1000000),('DeepSeek-V4.1-Flash',1048576),('Doctor-Shotgun/MS3.2-24B-Magnum-Diamond',32768),('EVA-UNIT-01/EVA-LLaMA-3.33-70B-v0.0',32768),('EVA-UNIT-01/EVA-LLaMA-3.33-70B-v0.1',32768),('EVA-UNIT-01/EVA-Qwen2.5-32B-v0.2',16384),('EVA-UNIT-01/EVA-Qwen2.5-72B-v0.2',16384),('Envoid/Llama-3.05-NT-Storybreaker-Ministral-70B',16384),('Envoid/Llama-3.05-Nemotron-Tenyxchat-Storybreaker-70B',16384),('GLM-4.6-Derestricted-v5',131072),('GLM-4.7',204800),('GLM-5',204800),('GLM-5.1',202752),('GLM-5.2',1048576),('GLM-5.3',1000000),('GLM-5.3-Flash',262144),('GalrionSoftworks/MN-LooseCannon-12B-v1',16384),('Gemma-4-26B-A4B-MeroMero',262144),('Gemma-4-26B-A4B-MeroMero:thinking',262144),('Gemma-4-31B-Agares-v1',262144),('Gemma-4-31B-Animus-V14.1',262144),('Gemma-4-31B-AssGuard',262144),('Gemma-4-31B-Claude-4.6-Opus-Reasoning-Distilled',262144),('Gemma-4-31B-Cognitive-Unshackled',262144),('Gemma-4-31B-Dark-Gemistry',262144),('Gemma-4-31B-DarkIdol',262144),('Gemma-4-31B-Fabled',262144),('Gemma-4-31B-GarnetV2',262144),('Gemma-4-31B-Gembrain-X-Core',262144),('Gemma-4-31B-Gembrain-uncensored-heretic',262144),('Gemma-4-31B-IT',262144),('Gemma-4-31B-Isometry-RP',262144),('Gemma-4-31B-K1-v5',262144),('Gemma-4-31B-MeroMero',262144),('Gemma-4-31B-MeroMero-v2',262144),('Gemma-4-31B-MeroMero-v2:thinking',262144),('Gemma-4-31B-Novelist',262144),('Gemma-4-31B-Queen',262144),('Gemma-4-31B-SDFT-Heretic-RP',262144),('Gemma-4-31B-StyleTune',262144),('Gryphe/MythoMax-L2-13b',4096),('Hy3',202752),('Inferact/Qwen3.8-2.4T-A95B-NVFP4',262144),('Intel/Qwen3-Coder-480B-A35B-Instruct-int4-mixed-ar',106000),('KBLab/kb-whisper-large',448),('Kimi-K2.5',262144),('Kimi-K2.6',262144),('Kimi-K2.7-Code',262144),('Kimi-K3',1048576),('Kloker',200000),('Kloker-Integration-Architect',200000),('Kloker-Integration-Developer',200000),('LatitudeGames/Wayfarer-Large-70B-Llama-3.3',32768),('LiquidAI/LFM2-24B-A2B',32768),('LongCat-2.0',1048576),('LongCat-2.5-Preview',1048576),('MarinaraSpaghetti/NemoMix-Unleashed-12B',32768),('Meta-Llama-3.3-70B-Instruct',131072),('Meta-Llama-3_1-8B-Instruct-GGUF',131072),('MiMo-V2.6-Flash',1048576),('MiniCPM-V-4.7-1B',262144),('MiniCPM-V-4.7-35B-A3B',262144),('MiniCPM5-2B',131072),('MiniMax-M1',1000000),('MiniMax-M2',204800)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('MiniMax-M2.1',204800),('MiniMax-M2.5',204800),('MiniMax-M2.5-highspeed',204800),('MiniMax-M2.7',204800),('MiniMax-M2.7-highspeed',204800),('MiniMax-M3',1048576),('MiniMax-M3.1-Flash',1000000),('MiniMax-M3.1-Flash-Preview',1000000),('MiniMax/MiniMax-M2.7',204800),('MiniMaxAI/MiniMax-M1-80k',1000000),('MiniMaxAI/MiniMax-M2',204800),('MiniMaxAI/MiniMax-M2.1',204800),('MiniMaxAI/MiniMax-M2.5',197000),('MiniMaxAI/MiniMax-M2.7',196608),('MiniMaxAI/MiniMax-M3',1048576),('MiniMaxAI/MiniMax-M3.1-Flash',1048576),('NeverSleep/Lumimaid-v0.2-70B',16384),('NousResearch/Hermes-4-405B',131072),('Ornith-1.0-35B-FP8',262000),('PaddlePaddle/PaddleOCR-VL-1.5',16384),('Pro/deepseek-ai/DeepSeek-R1',164000),('Pro/deepseek-ai/DeepSeek-V3',164000),('Pro/deepseek-ai/DeepSeek-V3.1-Terminus',164000),('Pro/deepseek-ai/DeepSeek-V3.2',164000),('Pro/moonshotai/Kimi-K2.5',262000),('Pro/moonshotai/Kimi-K2.6',262000),('Pro/zai-org/GLM-5',205000),('Pro/zai-org/GLM-5.1',205000),('Qwen/QwQ-32B',32768),('Qwen/Qwen2.5-72B-Instruct',33000),('Qwen/Qwen2.5-7B-Instruct',33000),('Qwen/Qwen2.5-7B-Instruct-Turbo',32768),('Qwen/Qwen2.5-Coder-32B-Instruct',131072),('Qwen/Qwen2.5-VL-32B-Instruct',32000),('Qwen/Qwen3-14B',131000),('Qwen/Qwen3-235B-A22B',40960),('Qwen/Qwen3-235B-A22B-Instruct-2507',262144),('Qwen/Qwen3-235B-A22B-Instruct-2507-tput',262144),('Qwen/Qwen3-235B-A22B-Thinking-2507',262144),('Qwen/Qwen3-30B-A3B',40960),('Qwen/Qwen3-30B-A3B-Instruct-2507',262144),('Qwen/Qwen3-30B-A3B-Thinking-2507',262144),('Qwen/Qwen3-32B',131000),('Qwen/Qwen3-8B',131000),('Qwen/Qwen3-Coder-30B-A3B-Instruct',262144),('Qwen/Qwen3-Coder-480B-A35B-Instruct',262000),('Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8',262144),('Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo',262144),('Qwen/Qwen3-Coder-Next',262144),('Qwen/Qwen3-Coder-Next-FP8',262144),('Qwen/Qwen3-Embedding-0.6B',32768),('Qwen/Qwen3-Embedding-4B',32768),('Qwen/Qwen3-Embedding-8B',32768),('Qwen/Qwen3-Max',256000),('Qwen/Qwen3-Next-80B-A3B-Instruct',262144),('Qwen/Qwen3-Reranker-0.6B',40960),('Qwen/Qwen3-Reranker-4B',32000),('Qwen/Qwen3-VL-235B-A22B-Instruct',131072),('Qwen/Qwen3-VL-235B-A22B-Instruct-FP8',218000),('Qwen/Qwen3-VL-235B-A22B-Thinking',131072),('Qwen/Qwen3-VL-30B-A3B-Instruct',16384),('Qwen/Qwen3-VL-30B-A3B-Thinking',262000),('Qwen/Qwen3-VL-32B-Instruct',262000),('Qwen/Qwen3-VL-32B-Thinking',262000),('Qwen/Qwen3-VL-8B-Instruct',262000),('Qwen/Qwen3-VL-Embedding-8B',32000),('Qwen/Qwen3.5-122B-A10B',262144),('Qwen/Qwen3.5-122B-A10B-FP8',200000),('Qwen/Qwen3.5-27B',262144),('Qwen/Qwen3.5-35B-A3B',262144),('Qwen/Qwen3.5-35B-A3B-Base',65536),('Qwen/Qwen3.5-397B-A17B',262144),('Qwen/Qwen3.5-397B-A17B-FP8',200000),('Qwen/Qwen3.5-397B-A17B-TEE',262144),('Qwen/Qwen3.5-397B-A17B:peft:262144',262144),('Qwen/Qwen3.5-4B',65536),('Qwen/Qwen3.5-4B:peft:262144',262144),('Qwen/Qwen3.5-9B',262144),('Qwen/Qwen3.5-9B-Base',65536),('Qwen/Qwen3.5-Plus',1000000),('Qwen/Qwen3.6-27B',262144),('Qwen/Qwen3.6-27B-TEE',262144),('Qwen/Qwen3.6-35B-A3B',262144),('Qwen/Qwen3.6-35B-A3B-FP8',262144),('Qwen/Qwen3.6-35B-A3B:peft:262144',262144),('Qwen/Qwen3.6-Plus',1000000),('Qwen/Qwen3.7-Max',1000000),('Qwen/Qwen3.8-2.4T-A95B',1049000),('Qwen/Qwen3.8-27B',262144),('Qwen/Qwen3.8-27B-FP8',262144),('Qwen/Qwen3.8-27B-TEE',262144),('Qwen/Qwen3.8-27B-abliterated',262144),('Qwen/Qwen3.8-27B:peft:262144',262144),('Qwen/Qwen3.8-Flash',1048575),('Qwen/Qwen3.8-Max',262144),('Qwen/Qwen3.8-Max-0902',1000000),('Qwen/Qwen3.8-Omni-Flash',1000000),('Qwen3-Coder-Next-FP8',256144),('Qwen3-Coder-Next-FP8-no-thinking',260000),('Qwen3-Embedding-8B',32768)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('Qwen3-Next-80B-A3B-Instruct',129024),('Qwen3-Next-80B-A3B-Thinking',262144),('Qwen3-VL-235B-A22B-Instruct',129024),('Qwen3-VL-235B-A22B-Thinking',131072),('Qwen3.5-122B-A10B',262144),('Qwen3.5-27B',262144),('Qwen3.5-27B-Blossom-V6.4-Derestricted',262144),('Qwen3.5-27B-BlueStar-v3-Derestricted',262144),('Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-Derestricted',262144),('Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-Derestricted-Lite',262144),('Qwen3.5-27B-Queen-Derestricted',262144),('Qwen3.5-35B-A3B',262144),('Qwen3.5-397B-A17B',262144),('Qwen3.6-27B-FP8',262144),('Qwen3.6-35B-A3B-FP8',262000),('Qwen3.6-35B-A3B-fp8-no-thinking',262000),('Qwen3.6-Flash',1000000),('Qwen3.8-27B',131072),('Qwen3.8-Flash',1000000),('Qwen3.8-Flash-Next',262144),('Qwen3.8-Max',1000000),('Qwen3_5-9B-MLX-4bit',32768),('Qwen3_5-9B-Q4_K_M',32768),('ReadyArt/MS3.2-The-Omega-Directive-24B-Unslop-v2.0',32768),('Sao10K/L3-8B-Stheno-v3.2',16384),('Sao10K/L3.1-70B-Euryale-v2.2',20480),('Sao10K/L3.1-70B-Hanami-x1',32768),('Sao10K/L3.3-70B-Euryale-v2.3',20480),('Steelskull/L3.3-Cu-Mai-R1-70b',32768),('Steelskull/L3.3-Electra-R1-70b',32768),('Steelskull/L3.3-MS-Nevoria-70b',32768),('Steelskull/L3.3-Nevoria-R1-70b',32768),('TEE/deepseek-v3.2',164000),('TEE/deepseek-v4.1-flash',1048576),('TEE/gemma-4-26b-a4b-uncensored',65536),('TEE/gemma-4-31b-it',262144),('TEE/gemma4-31b',262144),('TEE/gemma4-31b:thinking',262144),('TEE/glm-5.1',202752),('TEE/glm-5.1-thinking',202752),('TEE/glm-5.2',1048576),('TEE/glm-5.2:thinking',1048576),('TEE/glm-5.3',1048576),('TEE/glm-5.3-flash',1048576),('TEE/gpt-oss-120b',131072),('TEE/kimi-k2.6',262144),('TEE/kimi-k3',1048576),('TEE/qwen2.5-vl-72b-instruct',65536),('TEE/qwen3.5-27b',262144),('TEE/qwen3.5-397b-a17b',262144),('TEE/qwen3.6-27b',262144),('TEE/qwen3.6-35b-a3b',262144),('TEE/qwen3.8-27b',262144),('TheDrummer/Anubis-70B-v1',65536),('TheDrummer/Anubis-70B-v1.1',32000),('TheDrummer/Artemis-v1.1',262144),('TheDrummer/Cydonia-24B-v2',32768),('TheDrummer/Cydonia-24B-v4',32768),('TheDrummer/Cydonia-24B-v4.1',131072),('TheDrummer/Cydonia-24B-v4.3',131072),('TheDrummer/Magidonia-24B-v4.3',32768),('TheDrummer/Rocinante-12B-v1.1',16384),('TheDrummer/UnslopNemo-12B-v4.1',8192),('TheDrummer/skyfall-36b-v2',32768),('VongolaChouko/Starcannon-Unleashed-12B-v1.0',16384),('XiaomiMiMo/MiMo-V2-Flash',262144),('XiaomiMiMo/MiMo-V2.5',262144),('XiaomiMiMo/MiMo-V2.5-Pro',1048576),('XiaomiMiMo/MiMo-V2.6-Flash',1048576),('XiaomiMiMo/MiMo-V2.6-Pro',1048576),('ZhipuAI/GLM-4.5',131072),('ZhipuAI/GLM-4.6',202752),('abacusai/Dracarys-72B-Instruct',32768),('abliterated-model',150000),('abliterated-model-large',1000000),('abliterated-model-large-v2',1000000),('abliteration-abliterated-model-large-flash',1000000),('abliteration-abliterated-model-large-v2',1000000),('abliteration-ai/abliterated-model',262144),('abliteration-ai/abliterated-model-large',1000000),('abliteration-ai/abliterated-model-large-flash',1048576),('abliteration-ai/abliterated-model-large-v2',1048576),('accounts/fireworks/models/deepseek-v4p1-flash',1000000),('accounts/fireworks/models/deepseek-v4p1-flash-1017',1000000),('accounts/fireworks/models/ember-1',1048576),('accounts/fireworks/models/glm-5p3',1048573),('accounts/fireworks/models/glm-5p3-flash',1048573),('accounts/fireworks/models/gpt-oss-120b',131072),('accounts/fireworks/models/inkling',1048576),('accounts/fireworks/models/kimi-k3',1048576),('accounts/fireworks/models/minimax-m3',512000),('accounts/fireworks/models/minimax-m3p1-flash',1000000),('accounts/fireworks/models/muse-spark-open',1048576),('accounts/fireworks/models/nemotron-3-ultra-nvfp4',262144),('accounts/fireworks/models/nemotron-lightning-3p5-30b-a3b',262144),('accounts/fireworks/models/qwen3p8-2p4t-a95b',262144),('accounts/fireworks/models/qwen3p8-max',262144),('accounts/fireworks/routers/deepseek-flash-latest',1000000),('accounts/fireworks/routers/deepseek-v4p1-flash-1017-spot',1000000),('accounts/fireworks/routers/deepseek-v4p1-flash-spot',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('accounts/fireworks/routers/glm-5p3-fast',1048572),('accounts/fireworks/routers/glm-5p3-spot',1048573),('accounts/fireworks/routers/glm-fast-latest',1048572),('accounts/fireworks/routers/glm-flash-latest',1048573),('accounts/fireworks/routers/glm-latest',1048573),('accounts/fireworks/routers/kimi-fast-latest',1048576),('accounts/fireworks/routers/kimi-k3-fast',1048576),('accounts/fireworks/routers/kimi-k3-spot',1048576),('accounts/fireworks/routers/kimi-latest',1048576),('accounts/fireworks/routers/minimax-latest',512000),('accounts/fireworks/routers/qwen-max-latest',262144),('agent-max',1000000),('agent-prime',196608),('agnes-2.0-flash',512000),('agnes-2.5-flash',512000),('agnes-2.5-pro-alpha',1000000),('agnes-3.0-flash',512000),('aion-labs-aion-3-5',262144),('aion-labs-aion-3-5-mini',262144),('aion-labs/aion-2.0',131072),('aion-labs/aion-3.0',131072),('aion-labs/aion-3.0-mini',131072),('aion-labs/aion-3.5',262144),('aion-labs/aion-3.5-mini',262144),('aion-labs/aion-rp-llama-3.1-8b',32768),('aisingapore/gemma-sea-lion-v4-27b-it',131072),('aisingapore/qwen-sea-lion-v4-32b-it',131072),('aleph-alpha/kolibri-1',1048576),('alibaba/deepseek-v4-flash',1000000),('alibaba/deepseek-v4-pro',1000000),('alibaba/deepseek-v4.1-flash',1000000),('alibaba/deepseek-v4.1-flash-1017',1000000),('alibaba/glm-5',202752),('alibaba/glm-5.2',1000000),('alibaba/glm-5.3',1048576),('alibaba/kimi-k2.5',262144),('alibaba/kimi-k3',1048576),('alibaba/qwen-3-14b',40960),('alibaba/qwen-3-235b',262144),('alibaba/qwen-3-30b',40960),('alibaba/qwen-flash',1000000),('alibaba/qwen-max',32768),('alibaba/qwen-plus',131072),('alibaba/qwen-plus-latest',1000000),('alibaba/qwen3-coder',262144),('alibaba/qwen3-coder-30b-a3b',262144),('alibaba/qwen3-coder-480b-a35b-instruct',262000),('alibaba/qwen3-coder-flash',997952),('alibaba/qwen3-coder-next',256000),('alibaba/qwen3-embedding-0.6b',32768),('alibaba/qwen3-embedding-4b',32768),('alibaba/qwen3-embedding-8b',32768),('alibaba/qwen3-max',262144),('alibaba/qwen3-max-thinking',256000),('alibaba/qwen3-next-80b-a3b-instruct',262114),('alibaba/qwen3-next-80b-a3b-thinking',262144),('alibaba/qwen3-vl-instruct',262144),('alibaba/qwen3-vl-plus',262144),('alibaba/qwen3.5-122b-a10b',262144),('alibaba/qwen3.5-27b',262144),('alibaba/qwen3.5-35b-a3b',262144),('alibaba/qwen3.5-397b-a17b',262144),('alibaba/qwen3.5-flash',1000000),('alibaba/qwen3.5-plus',1000000),('alibaba/qwen3.6-27b',256000),('alibaba/qwen3.6-35b-a3b',262144),('alibaba/qwen3.6-flash',983616),('alibaba/qwen3.6-plus',983616),('alibaba/qwen3.7-flash',983616),('alibaba/qwen3.7-max',1000000),('alibaba/qwen3.7-plus',1000000),('alibaba/qwen3.8-2.4t-a95b',262144),('alibaba/qwen3.8-27b',1000000),('alibaba/qwen3.8-flash',983616),('alibaba/qwen3.8-max',1000000),('alibaba/qwen3.8-max-0902',991000),('alibaba/qwen3.8-max-prime',1000000),('alibaba/qwen3.8-omni-flash',983616),('alibaba/qwen35-397b-a17b',262144),('alibaba/wan-v2.5-t2v-preview',0),('alibaba/wan-v2.6-i2v',0),('alibaba/wan-v2.6-i2v-flash',0),('alibaba/wan-v2.6-r2v',0),('alibaba/wan-v2.6-r2v-flash',0),('alibaba/wan-v2.6-t2v',0),('alibaba/wan-v2.7-r2v',0),('alibaba/wan-v2.7-t2v',0),('alibaba/wan-v3.0-video',0),('alibaba/wan-v3.0-video-prime',0),('alicloud-deepseek-v4-flash',1000000),('alicloud-deepseek-v4-pro',1000000),('alicloud-glm-5.1',200000),('all-mini-lm-l6-v2',256),('allam-2-7b',4096),('amazon--nova-lite',1000000),('amazon--nova-pro',300000),('amazon--titan-embed-text',8192),('amazon.nova-2-lite-v1:0',1000000),('amazon.nova-lite-v1:0',300000),('amazon.nova-pro-v1:0',300000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('amazon/amazon.nova-lite-v1:0',300000),('amazon/amazon.nova-lite-v1:0@us',300000),('amazon/amazon.nova-pro-v1:0',300000),('amazon/amazon.nova-pro-v1:0@us',300000),('amazon/mistral.voxtral-mini-3b-2507',32768),('amazon/mistral.voxtral-mini-3b-2507@us',32768),('amazon/mistral.voxtral-small-24b-2507',32768),('amazon/mistral.voxtral-small-24b-2507@us',32768),('amazon/moonshot.kimi-k2-thinking',256000),('amazon/moonshotai.kimi-k2.5',262144),('amazon/nova-2-lite',1000000),('amazon/nova-2-lite-v1',1000000),('amazon/nova-lite',300000),('amazon/nova-lite-v1',300000),('amazon/nova-premier-v1',1000000),('amazon/nova-pro',300000),('amazon/nova-pro-v1',300000),('amazon/qwen.qwen3-coder-next',262144),('amazon/titan-embed-text-v2',8192),('amazon/zai.glm-4.7-flash',203000),('amazon/zai.glm-4.7-flash@us',203000),('ambient/large',202752),('ambient/small',101072),('anthracite-org/magnum-v2-72b',16384),('anthracite-org/magnum-v4-72b',32768),('anthropic--claude-3-haiku',200000),('anthropic--claude-4-opus',200000),('anthropic--claude-4-sonnet',200000),('anthropic--claude-4.5-haiku',200000),('anthropic--claude-4.5-opus',200000),('anthropic--claude-4.5-sonnet',200000),('anthropic--claude-4.6-opus',1000000),('anthropic--claude-4.6-sonnet',1000000),('anthropic--claude-4.7-opus',1000000),('anthropic--claude-4.8-opus',1000000),('anthropic-claude-4.5-sonnet',200000),('anthropic-claude-4.6-sonnet',200000),('anthropic-claude-5-sonnet',1000000),('anthropic-claude-5.5-haiku',1000000),('anthropic-claude-fable-5',1000000),('anthropic-claude-fable-5.1',1000000),('anthropic-claude-haiku-4.5',200000),('anthropic-claude-opus-4.5',200000),('anthropic-claude-opus-4.6',200000),('anthropic-claude-opus-4.7',200000),('anthropic-claude-opus-4.8',1000000),('anthropic-claude-opus-5',1000000),('anthropic-claude-opus-5.5',1000000),('anthropic-claude-sonnet-5.5',1000000),('anthropic.claude-fable-5',1000000),('anthropic.claude-fable-5-1',1000000),('anthropic.claude-haiku-4-5-20251001-v1:0',200000),('anthropic.claude-haiku-5-5',1000000),('anthropic.claude-opus-4-1-20250805-v1:0',200000),('anthropic.claude-opus-4-5-20251101-v1:0',200000),('anthropic.claude-opus-4-6-v1',1000000),('anthropic.claude-opus-4-7',1000000),('anthropic.claude-opus-4-8',1000000),('anthropic.claude-opus-5',1000000),('anthropic.claude-opus-5-5',1000000),('anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('anthropic.claude-sonnet-4-6',1000000),('anthropic.claude-sonnet-5',1000000),('anthropic.claude-sonnet-5-5',1000000),('anthropic/claude-fable-5',1000000),('anthropic/claude-fable-5-1',1000000),('anthropic/claude-fable-5.1',1000000),('anthropic/claude-fable-latest',1000000),('anthropic/claude-haiku-3',189096),('anthropic/claude-haiku-3.5',189096),('anthropic/claude-haiku-4-5',200000),('anthropic/claude-haiku-4-5-20251001',200000),('anthropic/claude-haiku-4.5',200000),('anthropic/claude-haiku-4.5:thinking',200000),('anthropic/claude-haiku-5-5',1000000),('anthropic/claude-haiku-5.5',1000000),('anthropic/claude-haiku-latest',1000000),('anthropic/claude-opus-4',192512),('anthropic/claude-opus-4-1-20250805',200000),('anthropic/claude-opus-4-5',200000),('anthropic/claude-opus-4-5-20251101',200000),('anthropic/claude-opus-4-6',200000),('anthropic/claude-opus-4-7',1000000),('anthropic/claude-opus-4-8',1000000),('anthropic/claude-opus-4.1',200000),('anthropic/claude-opus-4.1:thinking',200000),('anthropic/claude-opus-4.1:thinking:1024',200000),('anthropic/claude-opus-4.1:thinking:32768',200000),('anthropic/claude-opus-4.1:thinking:8192',200000),('anthropic/claude-opus-4.5',200000),('anthropic/claude-opus-4.5:thinking',200000),('anthropic/claude-opus-4.6',1000000),('anthropic/claude-opus-4.6:thinking',1000000),('anthropic/claude-opus-4.6:thinking:low',1000000),('anthropic/claude-opus-4.6:thinking:max',1000000),('anthropic/claude-opus-4.6:thinking:medium',1000000),('anthropic/claude-opus-4.7',1000000),('anthropic/claude-opus-4.7:thinking',1000000),('anthropic/claude-opus-4.8',1000000),('anthropic/claude-opus-4.8-fast',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('anthropic/claude-opus-4.8:thinking',1000000),('anthropic/claude-opus-5',1000000),('anthropic/claude-opus-5-5',1000000),('anthropic/claude-opus-5-fast',1000000),('anthropic/claude-opus-5.5',1000000),('anthropic/claude-opus-5.5-fast',1000000),('anthropic/claude-opus-latest',1000000),('anthropic/claude-sonnet-3.5',189096),('anthropic/claude-sonnet-3.5-june',189096),('anthropic/claude-sonnet-3.7',196608),('anthropic/claude-sonnet-4',983040),('anthropic/claude-sonnet-4-5',200000),('anthropic/claude-sonnet-4-5-20250929',200000),('anthropic/claude-sonnet-4-6',200000),('anthropic/claude-sonnet-4.5',1000000),('anthropic/claude-sonnet-4.5:thinking',200000),('anthropic/claude-sonnet-4.6',1000000),('anthropic/claude-sonnet-4.6:thinking',1000000),('anthropic/claude-sonnet-5',1000000),('anthropic/claude-sonnet-5-5',1000000),('anthropic/claude-sonnet-5.5',1000000),('anthropic/claude-sonnet-5.5:thinking',1000000),('anthropic/claude-sonnet-5:thinking',1000000),('anthropic/claude-sonnet-latest',1000000),('apac.amazon.nova-lite-v1:0',300000),('apac.amazon.nova-pro-v1:0',300000),('apac.anthropic.claude-sonnet-4-20250514-v1:0',200000),('apertus-70b',30000),('apodex/apodex-1.1-mini',262144),('arcee-ai/trinity-large-thinking',262144),('arcee_ai/AFM/models/trinity-mini',131072),('arkanecloud/Qwen/Qwen3-235B-A22B-Instruct-2507',262000),('arkanecloud/deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('arkanecloud/deepseek-ai/DeepSeek-V4.1-Flash',1048576),('arkanecloud/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('arkanecloud/meta-llama/Llama-3.1-70B-Instruct',131072),('arkanecloud/meta-llama/Llama-3.1-8B-Instruct',131072),('arkanecloud/ministral-14b',32768),('arkanecloud/nvidia/nemotron-3-super-120b-a12b',256000),('arkanecloud/nvidia/nemotron-3-ultra-550b-a55b',512288),('arkanecloud/openai/gpt-oss-120b',131072),('arkanecloud/openai/gpt-oss-20b',131072),('au.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('au.anthropic.claude-haiku-5-5',1000000),('au.anthropic.claude-opus-4-6-v1',1000000),('au.anthropic.claude-opus-4-7',1000000),('au.anthropic.claude-opus-4-8',1000000),('au.anthropic.claude-opus-5',1000000),('au.anthropic.claude-opus-5-5',1000000),('au.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('au.anthropic.claude-sonnet-4-6',1000000),('au.anthropic.claude-sonnet-5',1000000),('au.anthropic.claude-sonnet-5-5',1000000),('auto',1000000),('auto-model',1000000),('auto-model-basic',1000000),('auto-model-premium',1000000),('auto-model-standard',1000000),('auto/mistralai/ministral-14b-2512',262144),('auto/mistralai/ministral-3b-2512',262144),('auto/mistralai/ministral-8b-2512',262144),('auto/mistralai/mistral-large-2512',262144),('auto/mistralai/mistral-large-4',524288),('auto/mistralai/mistral-medium-3.5',262144),('auto/mistralai/mistral-small-2603',256000),('auto/openai/gpt-4.1',1047576),('auto/openai/gpt-4.1-mini',1047576),('auto/openai/gpt-5',400000),('auto/openai/gpt-5-mini',400000),('auto/openai/gpt-5-nano',400000),('auto/openai/gpt-5.2',400000),('auto/openai/gpt-5.4',1050000),('auto/openai/gpt-5.4-mini',400000),('auto/openai/gpt-5.5',1050000),('auto/openai/gpt-5.6-luna',1050000),('auto/openai/gpt-5.6-sol',1050000),('auto/openai/gpt-5.6-terra',1050000),('auto/openai/gpt-6-astra',1050000),('auto/openai/gpt-6-luna',1050000),('auto/openai/gpt-6-sol',1050000),('auto/openai/gpt-6.1-sol',1050000),('auto/openai/gpt-6.1-terra',1050000),('auto/openai/gpt-oss-120b',131072),('auto/openai/gpt-oss-20b',131072),('auto/openai/gpt-oss-safeguard-120b',131072),('auto/openai/gpt-oss-safeguard-20b',131072),('auto/openai/o3',200000),('aws-bedrock/claude-fable-5',1000000),('aws-bedrock/claude-fable-5-1',1000000),('aws-bedrock/claude-haiku-4-5',200000),('aws-bedrock/claude-haiku-4-5-20251001',200000),('aws-bedrock/claude-haiku-5-5',1000000),('aws-bedrock/claude-opus-4-5-20251101',200000),('aws-bedrock/claude-opus-4-6',1000000),('aws-bedrock/claude-opus-4-7',1000000),('aws-bedrock/claude-opus-4-8',1000000),('aws-bedrock/claude-opus-5',1000000),('aws-bedrock/claude-opus-5-5',1000000),('aws-bedrock/claude-sonnet-4-5',200000),('aws-bedrock/claude-sonnet-4-5-20250929',200000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('aws-bedrock/claude-sonnet-4-6',1000000),('aws-bedrock/claude-sonnet-5',1000000),('aws-bedrock/claude-sonnet-5-5',1000000),('aws-bedrock/grok-4-3',1000000),('aws-bedrock/grok-4-6',500000),('aws-bedrock/grok-4-7',524288),('aws-bedrock/kimi-k3',1048576),('aws-bedrock/llama-4-maverick-17b-instruct',8192),('aws-bedrock/llama-4-scout-17b-instruct',8192),('aws-mantle/gpt-5.6-luna',921600),('aws-mantle/gpt-5.6-sol',921600),('aws-mantle/gpt-5.6-terra',921600),('aws-mantle/gpt-6-astra',1050000),('azure-ai-foundry/grok-4-3',20000),('azure-anthropic/claude-fable-5',1000000),('azure-anthropic/claude-fable-5-1',1000000),('azure-anthropic/claude-opus-4-6',1000000),('azure-anthropic/claude-opus-4-7',1000000),('azure-anthropic/claude-opus-4-8',1000000),('azure-anthropic/claude-opus-5',1000000),('azure-anthropic/claude-opus-5-5',1000000),('azure-anthropic/claude-sonnet-5',1000000),('azure-anthropic/claude-sonnet-5-5',1000000),('azure/gpt-4.1',1000000),('azure/gpt-4.1-mini',1000000),('azure/gpt-4.1-nano',1047576),('azure/gpt-4.1-nano@eu',1047576),('azure/gpt-5',400000),('azure/gpt-5-mini',400000),('azure/gpt-5-nano',400000),('azure/gpt-5-pro',400000),('azure/gpt-5.1',400000),('azure/gpt-5.1-codex',400000),('azure/gpt-5.1-codex-max',272000),('azure/gpt-5.1-codex-mini',400000),('azure/gpt-5.2',400000),('azure/gpt-5.2-codex',400000),('azure/gpt-5.3-codex',400000),('azure/gpt-5.4',1050000),('azure/gpt-5.4-mini',400000),('azure/gpt-5.4-nano',400000),('azure/gpt-5.4-pro',1050000),('azure/gpt-5.5',1050000),('azure/gpt-5.6-luna',1050000),('azure/gpt-5.6-sol',1050000),('azure/gpt-5.6-terra',1050000),('azure/gpt-6-astra',1050000),('azure/gpt-6-luna',1050000),('azure/gpt-6-sol',1050000),('azure/gpt-6.1-sol',1050000),('azure/gpt-6.1-terra',1050000),('azure/gpt-oss-120b',131072),('azure/grok-4-3',200000),('baai/bge-m3',8192),('baai/bge-reranker-v2-m3',8000),('baichuan/baichuan-m2-32b',131072),('baidu/cobuddy',131072),('baidu/deepseek-v4-flash',1048576),('baidu/deepseek-v4-pro',1048576),('baidu/deepseek-v4.1-flash',1048576),('baidu/deepseek-v4.1-flash-1017',1048576),('baidu/ernie-4.5-21B-a3b',120000),('baidu/ernie-4.5-300b-a47b-paddle',123000),('baidu/ernie-4.5-vl-424b-a47b',123000),('baidu/glm-5.1',202752),('baidu/glm-5.2',1048576),('baidu/glm-5.3',1048576),('baidu/glm-5.3-flash',1048576),('baidu/kimi-k3',1048576),('bailian/qwen-flash',1000000),('bailian/qwen-max',32768),('bailian/qwen-plus',1000000),('bailian/qwen-vl-max',131072),('bailian/qwen3-coder-flash',1000000),('bailian/qwen3-coder-next',262144),('bailian/qwen3-coder-plus',1048576),('bailian/qwen3-max',262144),('bailian/qwen3.5-122b-a10b',256000),('bailian/qwen3.5-27b',262144),('bailian/qwen3.5-35b-a3b',262144),('bailian/qwen3.5-397b-a17b',256000),('bailian/qwen3.5-flash',1000000),('bailian/qwen3.5-plus',1000000),('bailian/qwen3.6-27b',256000),('bailian/qwen3.6-flash',1000000),('bailian/qwen3.6-max-preview',262144),('bailian/qwen3.6-plus',1000000),('bailian/qwen3.7-max',1000000),('bailian/qwen3.7-plus',1000000),('bailian/qwen3.8-27b',1131072),('bailian/qwen3.8-flash',1000000),('bailian/qwen3.8-max',1000000),('bailian/qwen3.8-max-0902',1000000),('baseten/Kimi-K2-Instruct-FP4',131072),('beam',1048576),('beam-free',1048576),('bee-brood',262144),('bee-buzz',262144),('bee-cell',131072),('bee-comb',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('bee-hive',262144),('bee-swarm',1000000),('bfl/flux-2-flex',0),('bfl/flux-2-klein-4b',0),('bfl/flux-2-klein-9b',0),('bfl/flux-2-max',67300),('bfl/flux-2-pro',67300),('bfl/flux-3-image',0),('bfl/flux-3-image-klein',0),('bfl/flux-3-video',0),('bfl/flux-kontext-max',512),('bfl/flux-kontext-pro',512),('bfl/flux-pro-1.0-fill',512),('bfl/flux-pro-1.1',512),('bfl/flux-pro-1.1-ultra',512),('bge-m3',8192),('bge-multilingual-gemma2',8191),('bge-reranker-v2-m3',8192),('bge_multilingual_gemma2',8000),('big-pickle',200000),('black-forest-labs/FLUX.2-klein-4B',0),('black-forest-labs/flux.1-dev',0),('black-forest-labs/flux_1-kontext-dev',0),('black-forest-labs/flux_1-schnell',0),('black-forest-labs/flux_2-klein-4b',0),('brick-complexity-pro',100000),('brick-v1-beta',100000),('bytedance-pro-latest',262144),('bytedance-seed/seed-1.6',262144),('bytedance-seed/seed-1.6-flash',262144),('bytedance-seed/seed-2-1-turbo',262144),('bytedance-seed/seed-2.0-code',262144),('bytedance-seed/seed-2.0-lite',262144),('bytedance-seed/seed-2.0-mini',262144),('bytedance/deepseek-v3.2',131072),('bytedance/deepseek-v4-flash',1048576),('bytedance/deepseek-v4-pro',1048576),('bytedance/dola-seed-2.0-code',256000),('bytedance/dola-seed-2.0-code-preview',131072),('bytedance/dola-seed-2.0-lite',256000),('bytedance/dola-seed-2.0-mini',256000),('bytedance/dola-seed-2.0-pro',256000),('bytedance/doubao-seed-1.8',256000),('bytedance/doubao-seed-2.0-code',256000),('bytedance/doubao-seed-2.0-lite',256000),('bytedance/doubao-seed-2.0-mini',256000),('bytedance/doubao-seed-2.0-pro',256000),('bytedance/doubao-seed-2.1-pro',256000),('bytedance/doubao-seed-2.1-turbo',256000),('bytedance/doubao-seed-code',256000),('bytedance/glm-4.7',200000),('bytedance/glm-5.2',1024000),('bytedance/seed-1-6-250615',256000),('bytedance/seed-1-6-250915',256000),('bytedance/seed-1-6-flash-250715',256000),('bytedance/seed-1-8-251228',256000),('bytedance/seed-1.6',256000),('bytedance/seed-1.8',256000),('bytedance/seed-2-0-code-preview-260328',262144),('bytedance/seed-2-0-lite-260428',262144),('bytedance/seed-2-0-mini-260428',262144),('bytedance/seed-2-0-pro-260328',262144),('bytedance/seed-2.1-turbo',262144),('bytedance/seedance-2',4096),('bytedance/seedance-2.0',0),('bytedance/seedance-2.0-fast',0),('bytedance/seedance-2.0-mini',0),('bytedance/seedance-2.5',0),('bytedance/seedance-v1.0-pro',0),('bytedance/seedance-v1.0-pro-fast',0),('bytedance/seedance-v1.5-pro',0),('bytedance/seedream-4.0',0),('bytedance/seedream-4.5',0),('bytedance/seedream-5.0-lite',0),('bytedance/seedream-5.0-pro',0),('c4ai-aya-vision-32b',16000),('ca.amazon.nova-lite-v1:0',300000),('callstack/apex',262144),('canopylabs/orpheus-arabic-saudi',4000),('canopylabs/orpheus-v1-english',4000),('canopywave/deepseek-v4-flash',1000000),('canopywave/deepseek-v4-pro',1000000),('canopywave/glm-5.2',200000),('canopywave/kimi-k2.6',262144),('canopywave/kimi-k3',1048576),('cat-jam-free',1048576),('celeris-1',8192),('cerebras/gpt-oss-120b',131072),('cerebras/llama-3.3-70b-cs',0),('cerebras/qwen-3.8-27b',131072),('cerebras/qwen3-235b-2507-cs',0),('cerebras/qwen3-32b-cs',0),('chatgpt-image-latest',0),('clarifai/main/models/mm-poly-8b',32768),('claude-3-5-haiku',200000),('claude-3-7-sonnet-20250219',200000),('claude-3-haiku-20240307',200000),('claude-3.5-haiku',200000),('claude-3.5-sonnet',200000),('claude-3.5-sonnet-v2',200000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('claude-3.7-sonnet',200000),('claude-4-5-sonnet',200000),('claude-4-6-sonnet',1000000),('claude-4.0-opus',200000),('claude-4.0-sonnet',200000),('claude-4.1-opus',200000),('claude-4.5-haiku',200000),('claude-4.5-opus',200000),('claude-4.5-sonnet',200000),('claude-fable-5',1000000),('claude-fable-5-1',1000000),('claude-fable-5-1@default',1000000),('claude-fable-5.1',1000000),('claude-fable-5.1@eu',1000000),('claude-fable-5@default',1000000),('claude-fable-5@eu',1000000),('claude-haiku-4-5',200000),('claude-haiku-4-5-20251001',200000),('claude-haiku-4-5@20251001',200000),('claude-haiku-4-5@eu',200000),('claude-haiku-4.5',200000),('claude-haiku-5-5',1000000),('claude-haiku-5-5@default',1000000),('claude-haiku-5-5@eu',1000000),('claude-haiku-5.5',1000000),('claude-mythos-5',1000000),('claude-opus-4',200000),('claude-opus-4-1',200000),('claude-opus-4-1-20250805',200000),('claude-opus-4-1-20250805-thinking',200000),('claude-opus-4-1@20250805',200000),('claude-opus-4-20250514',200000),('claude-opus-4-5',200000),('claude-opus-4-5-20251101',200000),('claude-opus-4-5-think',200000),('claude-opus-4-5@20251101',200000),('claude-opus-4-5@eu',200000),('claude-opus-4-6',1000000),('claude-opus-4-6-think',1000000),('claude-opus-4-6@default',1000000),('claude-opus-4-6@eu',1000000),('claude-opus-4-7',1000000),('claude-opus-4-7-think',1000000),('claude-opus-4-7-thinking',1000000),('claude-opus-4-7@default',1000000),('claude-opus-4-7@eu',1000000),('claude-opus-4-8',1000000),('claude-opus-4-8-fast',1000000),('claude-opus-4-8-think',1000000),('claude-opus-4-8@default',1000000),('claude-opus-4-8@eu',1000000),('claude-opus-4.7',200000),('claude-opus-4.8',1000000),('claude-opus-4@20250514',200000),('claude-opus-5',1000000),('claude-opus-5-5',1000000),('claude-opus-5-5-fast',1000000),('claude-opus-5-5@default',1000000),('claude-opus-5-5@eu',1000000),('claude-opus-5-fast',1000000),('claude-opus-5-thinking',1000000),('claude-opus-5.5',1000000),('claude-opus-5@default',1000000),('claude-opus-5@eu',1000000),('claude-opus-latest',1000000),('claude-opus4-5',200000),('claude-opus4-6',1000000),('claude-opus4-7',1000000),('claude-opus4-8',1000000),('claude-sonnet-4',1000000),('claude-sonnet-4-20250514',200000),('claude-sonnet-4-5',200000),('claude-sonnet-4-5-20250929',200000),('claude-sonnet-4-5-20250929-thinking',200000),('claude-sonnet-4-5-think',200000),('claude-sonnet-4-5@20250929',200000),('claude-sonnet-4-5@eu',1000000),('claude-sonnet-4-6',1000000),('claude-sonnet-4-6-think',1000000),('claude-sonnet-4-6-thinking',1000000),('claude-sonnet-4-6@default',1000000),('claude-sonnet-4-6@eu',1000000),('claude-sonnet-4.6',200000),('claude-sonnet-4@20250514',200000),('claude-sonnet-4@eu',1000000),('claude-sonnet-5',1000000),('claude-sonnet-5-5',1000000),('claude-sonnet-5-5@default',1000000),('claude-sonnet-5-5@eu',1000000),('claude-sonnet-5.5',1000000),('claude-sonnet-5@default',1000000),('claude-sonnet-5@eu',1000000),('claudinio',256000),('claudius',256000),('claw-high',1048576),('claw-low',1048576),('claw-medium',1048576),('cline-pass/deepseek-v4-flash',1000000),('cline-pass/deepseek-v4-pro',1000000),('cline-pass/deepseek-v4.1-flash',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('cline-pass/glm-5.2',1000000),('cline-pass/glm-5.3',1000000),('cline-pass/glm-5.3-flash',1000000),('cline-pass/kimi-k2.6',262144),('cline-pass/kimi-k2.7-code',262144),('cline-pass/kimi-k3',1048576),('cline-pass/mimo-v2.5',1048576),('cline-pass/mimo-v2.5-pro',1048576),('cline-pass/mimo-v2.6-flash',1048576),('cline-pass/mimo-v2.6-pro',1048576),('cline-pass/minimax-m3',1048576),('cline-pass/muse-spark-1.3-contributor',1048576),('cline-pass/qwen3.7-max',1000000),('cline-pass/qwen3.7-plus',1000000),('cline-pass/qwen3.8-max',1000000),('cloudflare/@cf/deepseek-ai/deepseek-v4-flash-0731',1048576),('cloudflare/@cf/deepseek-ai/deepseek-v4-pro-0813',1048576),('cloudflare/@cf/deepseek-ai/deepseek-v4.1-flash-1017',1048576),('cloudflare/@cf/meta/llama-3.2-1b-instruct',60000),('cloudflare/@cf/meta/llama-3.2-3b-instruct',80000),('cloudflare/@cf/meta/llama-guard-3-8b',131072),('cloudflare/@cf/qwen/qwen2.5-coder-32b-instruct',32768),('cloudflare/@cf/zai-org/glm-4.7-flash',131072),('cloudflare/deepseek-v4-flash',1048576),('cloudflare/deepseek-v4-pro',1048576),('cloudflare/deepseek-v4.1-flash-1017',1048576),('cloudflare/glm-5.3',1048576),('cloudflare/glm-5.3-flash',1048576),('code-max',1000000),('code-prime',196608),('codestral-2501',256000),('codestral-2508',256000),('codestral-latest',256000),('codex-mini',200000),('coding-glm-5.1',200000),('coding-glm-5.1-free',200000),('coding-glm-5.2-free',1000000),('coding-glm-5.3-flash-free',1000000),('coding-glm-5.3-free',1000000),('coding-minimax-m2.7',204800),('coding-minimax-m2.7-free',204800),('coding-minimax-m2.7-highspeed',204800),('coding-xiaomi-mimo-v2.5',1048576),('coding-xiaomi-mimo-v2.5-pro',1048576),('cohere--command-a-reasoning',256000),('cohere-command-a',131072),('cohere-embed-v3-english',512),('cohere-embed-v3-multilingual',512),('cohere/command-a',256000),('cohere/command-a-03-2025',288000),('cohere/command-a-plus',192000),('cohere/north-mini-code:free',256000),('cohere/rerank-v3.5',4096),('cohere/rerank-v4-fast',32000),('cohere/rerank-v4-pro',32000),('cohere/rerank-v5-fast',32768),('cohere/rerank-v5-pro',32768),('command-a-03-2025',256000),('command-a-reasoning-08-2025',256000),('command-a-translate-08-2025',8000),('consensusprotocol/Qwen3.8-27B',262000),('consensusprotocol/deepseek-v4-flash',1000000),('consensusprotocol/deepseek-v4.1-flash',1048576),('consensusprotocol/gemma-4-31b-it',262144),('consensusprotocol/glm-5.3-flash',1048576),('consensusprotocol/mimo-v2.6-flash',1048576),('consensusprotocol/minimax-m3',1048576),('crouton-alpha-free',1048576),('databricks-claude-haiku-4-5',200000),('databricks-claude-opus-4-1',200000),('databricks-claude-opus-4-5',200000),('databricks-claude-opus-4-6',1000000),('databricks-claude-opus-4-7',1000000),('databricks-claude-sonnet-4',200000),('databricks-claude-sonnet-4-5',200000),('databricks-claude-sonnet-4-6',1000000),('databricks-gemini-2-5-flash',1048576),('databricks-gemini-2-5-pro',1048576),('databricks-gemini-3-1-flash-lite',1048576),('databricks-gemini-3-1-pro',1048576),('databricks-gemini-3-5-flash',1048576),('databricks-gemini-3-flash',1048576),('databricks-gemini-3-pro',1048576),('databricks-glm-5-2',1000000),('databricks-gpt-5',400000),('databricks-gpt-5-1',400000),('databricks-gpt-5-2',400000),('databricks-gpt-5-4',1050000),('databricks-gpt-5-4-mini',400000),('databricks-gpt-5-4-nano',400000),('databricks-gpt-5-5',1050000),('databricks-gpt-5-6-luna',1050000),('databricks-gpt-5-6-sol',1050000),('databricks-gpt-5-6-terra',1050000),('databricks-gpt-5-mini',400000),('databricks-gpt-5-nano',400000),('databricks-gpt-oss-120b',131072),('databricks-gpt-oss-20b',131072),('databricks-kimi-k2-7-code',262144),('databricks/databricks-deepseek-v4-flash-0731',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('databricks/databricks-gpt-oss-120b',131072),('databricks/databricks-gpt-oss-120b@eu',131072),('databricks/databricks-gpt-oss-20b',131072),('databricks/databricks-gpt-oss-20b@eu',131072),('databricks/databricks-qwen3-next-80b-a3b-instruct',262144),('databricks/databricks-qwen3-next-80b-a3b-instruct@eu',262144),('deep-deepseek-v4-flash',1000000),('deep-deepseek-v4-pro',1000000),('deep-research-max-preview-04-2026',131072),('deep-research-preview-04-2026',131072),('deepinfra/ByteDance/Seed-2.0-code',256000),('deepinfra/ByteDance/Seed-2.0-mini',256000),('deepinfra/Gryphe/MythoMax-L2-13b',4096),('deepinfra/NousResearch/Hermes-3-Llama-3.1-405B',131072),('deepinfra/NousResearch/Hermes-3-Llama-3.1-70B',131072),('deepinfra/Qwen/Qwen2.5-7B-Instruct',32768),('deepinfra/Qwen/Qwen3-235B-A22B-Instruct-2507',262144),('deepinfra/Qwen/Qwen3-235B-A22B-Thinking-2507',262144),('deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct',262144),('deepinfra/Qwen/Qwen3-Max',256000),('deepinfra/Qwen/Qwen3-Next-80B-A3B-Instruct',262144),('deepinfra/Qwen/Qwen3-VL-235B-A22B-Instruct',262144),('deepinfra/Qwen/Qwen3-VL-30B-A3B-Instruct',262144),('deepinfra/deepseek-ai/DeepSeek-R1',163840),('deepinfra/deepseek-ai/DeepSeek-R1-0528',163840),('deepinfra/deepseek-ai/DeepSeek-V3',163840),('deepinfra/deepseek-ai/DeepSeek-V3-0324',163840),('deepinfra/deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('deepinfra/deepseek-ai/DeepSeek-V4-Pro-0813',1048576),('deepinfra/deepseek-ai/DeepSeek-V4.1-Flash',1048576),('deepinfra/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('deepinfra/deepseek-v3.2',160000),('deepinfra/deepseek-v4-flash',1000000),('deepinfra/deepseek-v4-pro',1048576),('deepinfra/deepseek-v4.1-flash',1048576),('deepinfra/deepseek-v4.1-flash-1017',1048576),('deepinfra/gemma-4-26b-a4b-it',262144),('deepinfra/gemma-4-31b-it',262144),('deepinfra/google/gemma-3-12b-it',131072),('deepinfra/google/gemma-3-27b-it',131072),('deepinfra/google/gemma-3-4b-it',131072),('deepinfra/granite-4.2-8b',131072),('deepinfra/ibm-granite/granite-4.2-8b',131072),('deepinfra/ling-3.0-flash',262144),('deepinfra/ling-3.0-flash-vl',131072),('deepinfra/meta-llama/Llama-3.2-11B-Vision-Instruct',131072),('deepinfra/meta-llama/Llama-3.2-3B-Instruct',131072),('deepinfra/meta-llama/Llama-3.3-70B-Instruct',131072),('deepinfra/meta-llama/Llama-Guard-3-8B',131072),('deepinfra/meta-llama/Llama-Guard-4-12B',163840),('deepinfra/meta-models/Muse-Glimmer-30B',131072),('deepinfra/microsoft/WizardLM-2-8x22B',65536),('deepinfra/mimo-v2.6-flash',1048576),('deepinfra/mimo-v2.6-pro',1048576),('deepinfra/mistralai/Mistral-Small-24B-Instruct-2501',32768),('deepinfra/mistralai/Mixtral-8x7B-Instruct-v0.1',32768),('deepinfra/moonshotai/Kimi-K2-Instruct',131072),('deepinfra/moonshotai/Kimi-K2.5',262144),('deepinfra/muse-glimmer-30b',131072),('deepinfra/nemotron-3-super-120b-a12b',262144),('deepinfra/nemotron-3-ultra-550b',262144),('deepinfra/nemotron-3-ultra-550b-a55b',262144),('deepinfra/nvidia/Llama-3.1-Nemotron-70B-Instruct',131072),('deepinfra/nvidia/Nemotron-3-Nano-30B-A3B',262144),('deepinfra/openai/gpt-oss-120b',131072),('deepinfra/openai/gpt-oss-20b',131072),('deepinfra/qwen3-vl-235b-a22b-instruct',262144),('deepinfra/qwen3-vl-30b-a3b-instruct',262144),('deepinfra/qwen3.5-9b',262144),('deepinfra/stepfun-ai/Step-3.5-Flash',262144),('deepinfra/stepfun-ai/Step-3.7-Flash',262144),('deepinfra/stepfun-ai/Step-5-Preview',1048576),('deepinfra/tencent/Hy3',262144),('deepinfra/tencent/Hy4-preview',1048576),('deepinfra/thinkingmachines/Inkling',524288),('deepinfra/thinkingmachines/Inkling-Small',524288),('deepinfra/zai-org/GLM-4.7-Flash',202752),('deepseek-3.2',163840),('deepseek-4-flash',1048576),('deepseek-ai/DeepSeek-OCR',8192),('deepseek-ai/DeepSeek-R1',164000),('deepseek-ai/DeepSeek-V3',164000),('deepseek-ai/DeepSeek-V3-0324',163840),('deepseek-ai/DeepSeek-V3-1',131072),('deepseek-ai/DeepSeek-V3.1',164000),('deepseek-ai/DeepSeek-V3.1-Terminus',164000),('deepseek-ai/DeepSeek-V3.2',164000),('deepseek-ai/DeepSeek-V3.2-Exp',164000),('deepseek-ai/DeepSeek-V3.2-TEE',131072),('deepseek-ai/DeepSeek-V4-Flash',1048575),('deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('deepseek-ai/DeepSeek-V4-Flash-0731-TEE',1048576),('deepseek-ai/DeepSeek-V4-Flash-Vision-Exp',1000000),('deepseek-ai/DeepSeek-V4-Pro',1048576),('deepseek-ai/DeepSeek-V4-Pro-0813',1000000),('deepseek-ai/DeepSeek-V4.1-Flash',1048576),('deepseek-ai/DeepSeek-V4.1-Flash-1017',1000000),('deepseek-ai/DeepSeek-V4.1-Flash-1017-Fast',1048576),('deepseek-ai/DeepSeek-V4.1-Flash-1017-abliterated',1048576),('deepseek-ai/DeepSeek-V4.1-Flash-1017:peft:262144',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('deepseek-ai/DeepSeek-V4.1-Flash-Fast',1048576),('deepseek-ai/DeepSeek-V4.1-Flash:peft:262144',262144),('deepseek-ai/deepseek-ocr/models/DeepSeek-OCR',8192),('deepseek-ai/deepseek-v3.1-maas',163840),('deepseek-ai/deepseek-v3.2-exp',163840),('deepseek-ai/deepseek-v3.2-exp-thinking',163840),('deepseek-ai/deepseek-v3.2-maas',163840),('deepseek-ai/deepseek-v4-flash',1048576),('deepseek-ai/deepseek-v4-flash-0731',1000000),('deepseek-ai/deepseek-v4-pro',1048576),('deepseek-ai/deepseek-v4.1-flash',1048576),('deepseek-ai/deepseek-v4.1-flash-1017',1048576),('deepseek-flash',1048576),('deepseek-ocr-2',8192),('deepseek-pro-latest',1000000),('deepseek-r1-distill-llama-8b',32768),('deepseek-r1-distill-qwen-1-5b',32768),('deepseek-r1-distill-qwen-14b',32768),('deepseek-r1-distill-qwen-32b',32768),('deepseek-r1-distill-qwen-7b',32768),('deepseek-tng-r1t2-chimera',130000),('deepseek-v3-1',131072),('deepseek-v3-2-exp',131072),('deepseek-v3.2',163840),('deepseek-v4-1-flash',1000000),('deepseek-v4-1-flash-1017',1000000),('deepseek-v4-1-flash-1017-uncensored',1000000),('deepseek-v4-1-flash-uncensored',1000000),('deepseek-v4-flash',1000000),('deepseek-v4-flash-0731',1048576),('deepseek-v4-flash-0731-fast',1000000),('deepseek-v4-flash-0731@eu',1048576),('deepseek-v4-flash-flex',1048560),('deepseek-v4-flash-free',200000),('deepseek-v4-flash-ga-260731',1000000),('deepseek-v4-flash-speed',1048560),('deepseek-v4-flash-vision-exp',1000000),('deepseek-v4-flash:free',1000000),('deepseek-v4-pro',1000000),('deepseek-v4-pro-0813',1000000),('deepseek-v4-pro-0813@eu',1048576),('deepseek-v4-pro-fast',1048576),('deepseek-v4-pro-ga-260813',1000000),('deepseek-v4-pro:0813',1048576),('deepseek-v4-pro:free',1000000),('deepseek-v4-pro@eu',1048576),('deepseek-v4.1-flash',1000000),('deepseek-v4.1-flash-1017',1050000),('deepseek-v4.1-flash-1017-abliterated',1048576),('deepseek-v4.1-flash-1017@eu',1048576),('deepseek-v4.1-flash-552b',1048576),('deepseek-v4.1-flash-cyber',1040000),('deepseek-v4.1-flash-fast',1048576),('deepseek-v4.1-flash-flex',1048560),('deepseek-v4.1-flash-free',200000),('deepseek-v4.1-flash:1017',1048576),('deepseek-v4.1-flash:fast',1000000),('deepseek-v4.1-flash@eu',1048576),('deepseek.v3-v1:0',163840),('deepseek.v3.2',163840),('deepseek/deepseek-chat',163840),('deepseek/deepseek-chat-v3-0324',163840),('deepseek/deepseek-chat-v3.1',163840),('deepseek/deepseek-flash',1000000),('deepseek/deepseek-latest',1048576),('deepseek/deepseek-math-v2',160000),('deepseek/deepseek-ocr-2',8192),('deepseek/deepseek-r1-0528',163840),('deepseek/deepseek-r1-turbo',64000),('deepseek/deepseek-reasoner',1000000),('deepseek/deepseek-v3',163840),('deepseek/deepseek-v3-0324',163840),('deepseek/deepseek-v3.1-terminus',163840),('deepseek/deepseek-v3.2',163840),('deepseek/deepseek-v3.2-exp',163840),('deepseek/deepseek-v3.2:thinking',163000),('deepseek/deepseek-v4-flash',1048576),('deepseek/deepseek-v4-flash-0423',1000000),('deepseek/deepseek-v4-flash-0423:thinking',1048576),('deepseek/deepseek-v4-flash-0731',1048576),('deepseek/deepseek-v4-flash-0731-fast',1000000),('deepseek/deepseek-v4-flash-0731:thinking',1048576),('deepseek/deepseek-v4-flash-fast',1000000),('deepseek/deepseek-v4-flash-free',1000000),('deepseek/deepseek-v4-flash-latest',1048576),('deepseek/deepseek-v4-flash-vision-exp',1048576),('deepseek/deepseek-v4-flash:thinking',1048576),('deepseek/deepseek-v4-pro',1048576),('deepseek/deepseek-v4-pro-0423',1000000),('deepseek/deepseek-v4-pro-0813',1048576),('deepseek/deepseek-v4-pro-0813:thinking',1048576),('deepseek/deepseek-v4-pro:thinking',1048576),('deepseek/deepseek-v4.1-flash',1048576),('deepseek/deepseek-v4.1-flash-0910-uncensored',524288),('deepseek/deepseek-v4.1-flash-0910-uncensored:thinking',524288),('deepseek/deepseek-v4.1-flash-1017',1048576),('deepseek/deepseek-v4.1-flash-1017-fast',1048576),('deepseek/deepseek-v4.1-flash-1017-uncensored',1048576),('deepseek/deepseek-v4.1-flash-1017-uncensored:thinking',1048576),('deepseek/deepseek-v4.1-flash-1017:thinking',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('deepseek/deepseek-v4.1-flash-fast',1048576),('deepseek/deepseek-v4.1-flash-uncensored',1048576),('deepseek/deepseek-v4.1-flash-uncensored:thinking',1048576),('deepseek/deepseek-v4.1-flash:thinking',1048576),('deepseek/deepseek_v3',64000),('devstral-2-123b-instruct-2512',200000),('devstral-2512',262144),('devstral-latest',256000),('devstral-latest@eu',256000),('devstral-medium-latest',262144),('dots-studio/dots-3-note-preview:free',512000),('doubao-seed-1-6-251015',256000),('doubao-seed-1-6-flash-250828',256000),('doubao-seed-1-6-thinking-250715',256000),('doubao-seed-1-6-vision-250815',256000),('doubao-seed-1-8-251215',224000),('doubao-seed-1-8-251228',256000),('doubao-seed-1.6',256000),('doubao-seed-1.6-flash',256000),('doubao-seed-1.6-thinking',256000),('doubao-seed-2-0-code-preview',256000),('doubao-seed-2-0-code-preview-260215',262144),('doubao-seed-2-0-lite-260215',256000),('doubao-seed-2-0-lite-260428',256000),('doubao-seed-2-0-mini-260215',256000),('doubao-seed-2-0-mini-260428',256000),('doubao-seed-2-0-pro',256000),('doubao-seed-2-0-pro-260215',256000),('doubao-seed-2-1-pro-260628',256000),('doubao-seed-2-1-turbo-260628',256000),('doubao-seed-2.0-code',256000),('doubao-seed-2.0-lite',256000),('doubao-seed-2.0-mini',256000),('doubao-seed-2.0-pro',256000),('doubao-seed-2.1-turbo',256000),('doubao-seed-character-260628',256000),('doubao-seed-evolving',256000),('dsv4',1048576),('duo-chat-fable-5',1000000),('duo-chat-fable-5-1',1000000),('duo-chat-gpt-5-1',400000),('duo-chat-gpt-5-2',400000),('duo-chat-gpt-5-2-codex',400000),('duo-chat-gpt-5-3-codex',400000),('duo-chat-gpt-5-4',1050000),('duo-chat-gpt-5-4-mini',400000),('duo-chat-gpt-5-4-nano',400000),('duo-chat-gpt-5-5',1050000),('duo-chat-gpt-5-6-luna',1050000),('duo-chat-gpt-5-6-sol',1050000),('duo-chat-gpt-5-6-terra',1050000),('duo-chat-gpt-5-codex',400000),('duo-chat-gpt-5-mini',400000),('duo-chat-gpt-6-1-sol',1050000),('duo-chat-gpt-6-astra',1050000),('duo-chat-gpt-6-luna',1050000),('duo-chat-gpt-6-sol',1050000),('duo-chat-haiku-4-5',200000),('duo-chat-haiku-5-5',1000000),('duo-chat-opus-4-5',200000),('duo-chat-opus-4-6',1000000),('duo-chat-opus-4-7',1000000),('duo-chat-opus-4-8',1000000),('duo-chat-opus-5',1000000),('duo-chat-opus-5-5',1000000),('duo-chat-sonnet-4-5',200000),('duo-chat-sonnet-4-6',1000000),('duo-chat-sonnet-5',1000000),('duo-chat-sonnet-5-5',1000000),('e5-large-v2',512),('echo',262144),('elevenlabs/elevenlabs-music',2000),('elorian/glimpse',262144),('empiriolabs/deepseek-v4-flash-el',1000000),('empiriolabs/deepseek-v4-pro-el',1000000),('entrim/deepseek-v4.1-flash-1017',1048576),('entrim/glm-5.3',1048576),('entrim/glm-5.3-flash',1048576),('ernie-5.1',119000),('ernie-5.1:thinking',119000),('essentialai/Rnj-1-Instruct',32768),('eu.amazon.nova-2-lite-v1:0',1000000),('eu.amazon.nova-lite-v1:0',300000),('eu.amazon.nova-pro-v1:0',300000),('eu.anthropic.claude-fable-5',1000000),('eu.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('eu.anthropic.claude-haiku-5-5',1000000),('eu.anthropic.claude-opus-4-5-20251101-v1:0',200000),('eu.anthropic.claude-opus-4-6-v1',1000000),('eu.anthropic.claude-opus-4-7',1000000),('eu.anthropic.claude-opus-4-8',1000000),('eu.anthropic.claude-opus-5',1000000),('eu.anthropic.claude-opus-5-5',1000000),('eu.anthropic.claude-sonnet-4-20250514-v1:0',200000),('eu.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('eu.anthropic.claude-sonnet-4-6',1000000),('eu.anthropic.claude-sonnet-5',1000000),('eu.anthropic.claude-sonnet-5-5',1000000),('evroc/roc',262144),('exo-free',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('failspy/Meta-Llama-3-70B-Instruct-abliterated-v3.5',8192),('fal-ai/elevenlabs/tts/multilingual-v2',0),('fal-ai/fast-sdxl',0),('fal-ai/flux/schnell',0),('fal-ai/stable-audio-25/text-to-audio',0),('faster-whisper-large-v3',448),('fastgpt',32768),('fastino/GLiNER-2.5-Decide',8192),('fastino/gliguard-LLMGuardrails-300M',8192),('fastino/gliguard-PII-multi',8192),('fastino/gliner2-base-v1',2048),('fastino/gliner2-large-v1',8192),('fastino/gliner2-multi-large-v1',8192),('fastino/gliner2-multi-v1',8192),('fastino/gliner2-privacy-filter-PII-multi',8192),('fastino/gliner2.5-base-v1',4096),('fastino/gliner2.5-multi-v1',4096),('featherless-ai/Qwerky-72B',32000),('fireworks-ai/kimi-k2.5-fw',262144),('fireworks/deepseek-v4.1-flash',1048576),('fireworks/ember-1',1048576),('fireworks/glm-5.2',1000000),('fireworks/glm-5.3',1048576),('fireworks/glm-5.3-flash',1048576),('fireworks/gpt-oss-120b',131072),('fireworks/gpt-oss-20b',131072),('fireworks/kimi-k3',1040384),('fireworks/kimi-k3-fast',1040384),('fireworks_ai/accounts/fireworks/models/ember-1',1048576),('fireworks_ai/accounts/fireworks/models/gpt-oss-120b',131072),('fireworks_ai/accounts/fireworks/models/inkling',1048576),('fireworks_ai/accounts/fireworks/models/muse-spark-open',1048576),('fireworks_ai/gpt-oss-120b',131072),('fish-audio/drama-3',0),('fish-audio/s1',0),('fish-audio/s2-pro',0),('fish-audio/s2.1-pro',0),('fish-audio/transcribe-1',0),('fledge-alpha-free',1048576),('flexai/DeepSeek-V4-Flash-0731',1048576),('flexai/DeepSeek-V4-Flash-0731@eu',1048576),('flexai/DeepSeek-V4.1-Flash-1017',1048576),('flexai/Muse-Glimmer-30B',131072),('flexai/Step-3.7-Flash',262144),('flexai/deepseek-v4-flash',1048576),('flexai/deepseek-v4.1-flash-1017',1048576),('flexai/glm-5.2',1048576),('flexai/glm-5.3-flash',1048576),('flexai/gpt-oss-120b',131072),('flexai/gpt-oss-20b',131072),('flint-40b-free',262144),('fugu',1000000),('fugu-max',1000000),('fugu-ultra',1000000),('fugu-ultra-20260615',1000000),('fugu-ultra-v1-0',1000000),('fugu-ultra-v1-1',1000000),('fugu-ultra-v2-0',1000000),('fugu-ultra-v2.0',1000000),('gemini-2-5-flash',1048576),('gemini-2-5-flash-lite',1048576),('gemini-2.0-flash',1048576),('gemini-2.0-flash-lite',1048576),('gemini-2.0-pro-exp-02-05',2097152),('gemini-2.5-flash',1048576),('gemini-2.5-flash-image',32768),('gemini-2.5-flash-lite',1048576),('gemini-2.5-flash-lite-preview-06-17',1048576),('gemini-2.5-flash-lite-preview-09-2025',1000000),('gemini-2.5-flash-lite-preview-09-2025-thinking',1048576),('gemini-2.5-flash-lite@eu',1048576),('gemini-2.5-flash-nothink',1000000),('gemini-2.5-flash-nothinking',1048576),('gemini-2.5-flash-preview-04-17',1048576),('gemini-2.5-flash-preview-04-17:thinking',1048576),('gemini-2.5-flash-preview-05-20',1048576),('gemini-2.5-flash-preview-05-20:thinking',1048000),('gemini-2.5-flash-preview-09-2025',1000000),('gemini-2.5-flash-preview-09-2025-thinking',1048576),('gemini-2.5-flash-preview-tts',8192),('gemini-2.5-flash-tts',32768),('gemini-2.5-flash@eu',1048576),('gemini-2.5-pro',1048576),('gemini-2.5-pro-exp-03-25',1048576),('gemini-2.5-pro-preview-03-25',1048576),('gemini-2.5-pro-preview-05-06',1048576),('gemini-2.5-pro-preview-06-05',1048576),('gemini-2.5-pro-preview-tts',8192),('gemini-2.5-pro-tts',32768),('gemini-2.5-pro@eu',1048576),('gemini-3-1-flash-lite',1048576),('gemini-3-1-flash-tts',8192),('gemini-3-1-pro',1048576),('gemini-3-1-pro-preview',1000000),('gemini-3-5-flash',1048576),('gemini-3-5-flash-lite',1048576),('gemini-3-6-flash',1048576),('gemini-3-7-flash',1048576),('gemini-3-8-flash',1048576),('gemini-3-flash',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('gemini-3-flash-preview',1048576),('gemini-3-pro',1048576),('gemini-3-pro-image',65536),('gemini-3-pro-image-preview',65536),('gemini-3-pro-preview',1000000),('gemini-3.0-flash-preview',1000000),('gemini-3.0-pro-image-preview',32768),('gemini-3.0-pro-preview',1000000),('gemini-3.1-flash-image',1048576),('gemini-3.1-flash-image-preview',1048576),('gemini-3.1-flash-lite',1048576),('gemini-3.1-flash-lite-image',65536),('gemini-3.1-flash-lite-preview',1048576),('gemini-3.1-flash-lite@eu',1048576),('gemini-3.1-flash-live-preview',131072),('gemini-3.1-flash-tts-preview',8192),('gemini-3.1-pro',1048576),('gemini-3.1-pro-preview',1048576),('gemini-3.1-pro-preview-customtools',1048576),('gemini-3.5-flash',200000),('gemini-3.5-flash-lite',1048576),('gemini-3.5-flash-lite@eu',1048576),('gemini-3.5-flash-thinking',1048576),('gemini-3.5-flash@eu',1048576),('gemini-3.5-live-translate-preview',16384),('gemini-3.6-flash',1000000),('gemini-3.7-flash',1000000),('gemini-3.7-flash@eu',1048576),('gemini-3.8-flash',1000000),('gemini-3.8-flash@eu',1048576),('gemini-4-argon',1048576),('gemini-4-argon-contributor',1048576),('gemini-4-argon@eu',1048576),('gemini-embedding',2048),('gemini-embedding-001',2048),('gemini-embedding-2',8192),('gemini-exp-1206',2097152),('gemini-flash-latest',1048576),('gemini-flash-lite-latest',1048576),('gemini-nano-banana-2.1',131072),('gemini-omni-flash-preview',131072),('gemini-pro-latest',1048576),('gemini/gemini-2.5-flash',1048576),('gemini/gemini-2.5-flash-lite',1048576),('gemini/gemini-2.5-pro',1048576),('gemini/gemini-3-flash-preview',1048576),('gemini/gemini-3.1-pro-preview',1048576),('gemini/gemini-3.5-flash',1048576),('gemini/gemini-3.5-flash-lite',1048576),('gemini/gemini-3.6-flash',1048576),('gemini/gemini-3.7-flash',1048576),('gemini/gemini-3.8-flash',1048576),('gemini/gemini-4-argon',1048576),('gemma-3-12b',131072),('gemma-3-12b-it',131072),('gemma-3-27b',131072),('gemma-3-27b-it',40000),('gemma-4',131072),('gemma-4-12b-it',131072),('gemma-4-12b-it-semancer',131072),('gemma-4-12b-it-starry-ocean',131072),('gemma-4-12b-it-station-keeper',131072),('gemma-4-26b-a4b',262144),('gemma-4-26b-a4b-it',262144),('gemma-4-26b-a4b-it-chimerax',262144),('gemma-4-26b-a4b-it-chimeraxheretic',262144),('gemma-4-26b-a4b-it-darksoul',262144),('gemma-4-26b-a4b-it-luminous',262144),('gemma-4-26b-a4b-it-moonlight',262144),('gemma-4-26b-a4b-it-musica',262144),('gemma-4-26b-a4b-it-opusdistill',262144),('gemma-4-26b-a4b-it-shadowsiren',262144),('gemma-4-31B-it',256000),('gemma-4-31B-it-fp8',262144),('gemma-4-31b',262128),('gemma-4-31b-it',262144),('gemma-4-31b-it-darkidol',262144),('gemma-4-31b-it-fabled',262144),('gemma-4-31b-it-garnet',262144),('gemma-4-31b-it-gembrain',262144),('gemma-4-31b-it-gemsicle',262144),('gemma-4-31b-it-isometry',262144),('gemma-4-31b-it-novelist',262144),('gemma-4-31b-it-scarlet',262144),('gemma-4-31b-it:free',262144),('gemma-4-E4B-it-IQ4_XS',32768),('gemma-4-E4B-it-MLX-4bit',32768),('gemma-4-uncensored',256000),('gemma2-9b-it',8192),('gemma4',262144),('gemma4-26b',256000),('gemma4-31b',100000),('gemma4:31b',262144),('glm-4-5-flash',131072),('glm-4-6v-flash',131072),('glm-4-7-flash',202752),('glm-4-7-flash:free',200000),('glm-4-7-flashx',202752),('glm-4-long',1000000),('glm-4.5-flash',131072)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('glm-4.5-flash:free',131072),('glm-4.6',204800),('glm-4.6v',131072),('glm-4.7',204800),('glm-4.7-flash',200000),('glm-4.7-flash-free',200000),('glm-4.7-flashx',200000),('glm-4.7-free',204800),('glm-5',204800),('glm-5-1',202745),('glm-5-2',1000000),('glm-5-2-260617',1000000),('glm-5-3',1048576),('glm-5-3-flash',1048576),('glm-5-3-flash-260828',1000000),('glm-5-free',204800),('glm-5-turbo',200000),('glm-5.1',204800),('glm-5.1@eu',200000),('glm-5.2',1000000),('glm-5.2-caveman',1000000),('glm-5.2-caveman-lite',1000000),('glm-5.2-caveman-ultra',1000000),('glm-5.2-fast',1000000),('glm-5.2-highspeed',1000000),('glm-5.2-honey',1000000),('glm-5.2-honey-lite',1000000),('glm-5.2-honey-ultra',1000000),('glm-5.2-nitro',200000),('glm-5.2-ponytail',1000000),('glm-5.2-ponytail-lite',1000000),('glm-5.2-ponytail-ultra',1000000),('glm-5.2:free',1000000),('glm-5.2@eu',1048576),('glm-5.3',1000000),('glm-5.3-fast',1048576),('glm-5.3-flash',1000000),('glm-5.3-flash-flex',1048560),('glm-5.3-flash-free',200000),('glm-5.3-flash:fast',1000000),('glm-5.3-flash@eu',1000000),('glm-5.3-flashx',1000000),('glm-5.3-flex',1048560),('glm-5.3-highspeed',1000000),('glm-5.3:fast',1000000),('glm-5.3@eu',1048576),('glm-5.x-menthol',202752),('glm-5v-turbo',200000),('glm-flash-latest',1000000),('glm-latest',1000000),('glm5.2',96000),('glm5.2-fast',1048576),('glm5.3',1000000),('glm5.3-754b',524288),('glm5.3-flash',1000000),('global.amazon.nova-2-lite-v1:0',1000000),('global.anthropic.claude-fable-5',1000000),('global.anthropic.claude-fable-5-1',1000000),('global.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('global.anthropic.claude-haiku-5-5',1000000),('global.anthropic.claude-opus-4-5-20251101-v1:0',200000),('global.anthropic.claude-opus-4-6-v1',1000000),('global.anthropic.claude-opus-4-7',1000000),('global.anthropic.claude-opus-4-8',1000000),('global.anthropic.claude-opus-5',1000000),('global.anthropic.claude-opus-5-5',1000000),('global.anthropic.claude-sonnet-4-20250514-v1:0',200000),('global.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('global.anthropic.claude-sonnet-4-6',1000000),('global.anthropic.claude-sonnet-5',1000000),('global.anthropic.claude-sonnet-5-5',1000000),('global.moonshotai.kimi-k3',1048576),('global.openai.gpt-5.6-luna',1050000),('global.openai.gpt-5.6-sol',1050000),('global.openai.gpt-5.6-terra',1050000),('global.openai.gpt-6-astra',1050000),('global.openai.gpt-6-luna',1050000),('global.openai.gpt-6-sol',1050000),('global.openai.gpt-6.1-sol',1050000),('global.openai.gpt-6.1-terra',1050000),('global.xai.grok-4.6',500000),('global.xai.grok-4.7',500000),('global.zai.glm-5.3',1000000),('google-ai-studio/gemini-3-flash-preview',1048576),('google-ai-studio/gemini-3.1-flash-lite',1048576),('google-ai-studio/gemini-3.1-pro-preview',1048576),('google-ai-studio/gemini-3.5-flash-lite',1048576),('google-ai-studio/gemini-3.6-flash',1048576),('google-ai-studio/gemini-3.8-flash',1048576),('google-ai-studio/gemini-4-argon',1048576),('google-ai-studio/gemini-pro-latest',1048576),('google-gemma-3-27b-it',198000),('google-gemma-4-26b-a4b-it',256000),('google-gemma-4-31b-it',256000),('google-vertex/gemini-3-flash-preview',1048576),('google-vertex/gemini-3.1-flash-lite',1048576),('google-vertex/gemini-3.1-pro-preview',1048576),('google-vertex/gemini-3.5-flash',1048576),('google-vertex/gemini-3.5-flash-lite',1048576),('google-vertex/gemini-3.6-flash',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('google-vertex/gemini-3.7-flash',1048576),('google-vertex/gemini-3.8-flash',1048576),('google-vertex/gemini-4-argon',1048576),('google.gemma-3-12b-it',131072),('google.gemma-3-27b-it',131072),('google.gemma-3-4b-it',131072),('google.gemma-4-26b-a4b',262144),('google.gemma-4-31b',262144),('google.gemma-4-e2b',131072),('google/deep-research-max-preview-04-2026',1048576),('google/deep-research-preview-04-2026',1048576),('google/diffusiongemma',262144),('google/diffusiongemma-26b-a4b-it',250000),('google/gemini-2.0-flash',990000),('google/gemini-2.0-flash-lite',990000),('google/gemini-2.5-flash',1048576),('google/gemini-2.5-flash-image',32768),('google/gemini-2.5-flash-lite',1048576),('google/gemini-2.5-pro',1048576),('google/gemini-2.5-pro-preview',1048576),('google/gemini-3-8-flash',1048576),('google/gemini-3-flash',1000000),('google/gemini-3-flash-preview',1048576),('google/gemini-3-flash-preview-thinking',1048576),('google/gemini-3-pro-image',131072),('google/gemini-3-pro-image-preview',65536),('google/gemini-3-pro-preview',1048576),('google/gemini-3.1-flash-image',131072),('google/gemini-3.1-flash-image-preview',65536),('google/gemini-3.1-flash-lite',1048576),('google/gemini-3.1-flash-lite-image',65536),('google/gemini-3.1-flash-lite-preview',1048576),('google/gemini-3.1-pro',1000000),('google/gemini-3.1-pro-preview',1048576),('google/gemini-3.1-pro-preview-customtools',1048576),('google/gemini-3.1-pro-preview-high',1048576),('google/gemini-3.1-pro-preview-low',1048576),('google/gemini-3.5-flash',1048576),('google/gemini-3.5-flash-lite',1048576),('google/gemini-3.5-flash-thinking',1048576),('google/gemini-3.5-transcribe',98304),('google/gemini-3.5-transcribe-live',0),('google/gemini-3.6-flash',1048576),('google/gemini-3.7-flash',1048576),('google/gemini-3.8-flash',1048576),('google/gemini-3.8-flash-lite-tts',8192),('google/gemini-3.8-flash-tts',8192),('google/gemini-3.8-live',131072),('google/gemini-3.8-live-extended-thinking',131072),('google/gemini-4-argon',1048576),('google/gemini-deep-research',1048576),('google/gemini-embedding-001',2048),('google/gemini-embedding-2',8192),('google/gemini-flash-latest',1048576),('google/gemini-flash-lite-latest',1048576),('google/gemini-nano-banana-2.1',65536),('google/gemini-omni-1.1-flash',131072),('google/gemini-omni-flash-preview',1000000),('google/gemini-pro-latest',1048576),('google/gemini-robotics-er-1.6-preview',131072),('google/gemini-robotics-er-2-preview',131072),('google/gemma-2-27b-it',8192),('google/gemma-3',125000),('google/gemma-3-12b-it',131072),('google/gemma-3-27b-it',131072),('google/gemma-3-4b-it',131072),('google/gemma-4-12B-it',262144),('google/gemma-4-26B-A4B-it',262144),('google/gemma-4-26b-a4b-it',262144),('google/gemma-4-26b-a4b-it-cybersecurity',262144),('google/gemma-4-26b-a4b-it-maas',262144),('google/gemma-4-26b-a4b-it:free',262144),('google/gemma-4-26b-a4b-it:thinking',262144),('google/gemma-4-31B-it',262144),('google/gemma-4-31B-turbo-TEE',131072),('google/gemma-4-31b',262144),('google/gemma-4-31b-it',262144),('google/gemma-4-31b-it:free',262144),('google/gemma-4-31b-it:thinking',262144),('google/gemma-4-E4B-it',131072),('google/gemma4-31b-splituntied',262144),('google/imagen-3',480),('google/imagen-3-fast',480),('google/imagen-4',480),('google/imagen-4-fast',480),('google/imagen-4-ultra',480),('google/lyria',0),('google/lyria-3-clip-preview',1048576),('google/lyria-3-pro-preview',1048576),('google/nano-banana',65536),('google/nano-banana-pro',65536),('google/text-embedding-005',8192),('google/text-multilingual-embedding-002',8192),('google/veo-2',480),('google/veo-3',480),('google/veo-3-fast',480),('google/veo-3.0-fast-generate-001',0),('google/veo-3.0-generate-001',0),('google/veo-3.1',480),('google/veo-3.1-fast',480)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('google/veo-3.1-fast-generate-001',0),('google/veo-3.1-generate-001',0),('google/veo-3.1-lite-generate-001',0),('google/veo3.1',400000),('google/veo3.1-fast',400000),('google/veo3.1-lite',400000),('gpt-3.5-turbo',16385),('gpt-3.5-turbo-0125',16384),('gpt-3.5-turbo-1106',16384),('gpt-3.5-turbo-instruct',4096),('gpt-4',8192),('gpt-4.1',1047576),('gpt-4.1-mini',1047576),('gpt-4.1-mini-2025-04-14',1047576),('gpt-4.1-mini@eu',1047576),('gpt-4.1-nano',1047576),('gpt-4.1-nano@eu',1047576),('gpt-4.1@eu',1047576),('gpt-4o-mini-transcribe',16000),('gpt-4o-transcribe',16000),('gpt-5',400000),('gpt-5-1',400000),('gpt-5-2',400000),('gpt-5-3-codex',400000),('gpt-5-4',1050000),('gpt-5-4-mini',400000),('gpt-5-4-nano',400000),('gpt-5-5',1050000),('gpt-5-5-pro',1050000),('gpt-5-6-luna',1050000),('gpt-5-6-sol',1050000),('gpt-5-6-terra',1050000),('gpt-5-chat-latest',400000),('gpt-5-codex',400000),('gpt-5-mini',400000),('gpt-5-mini@eu',200000),('gpt-5-nano',400000),('gpt-5-nano@eu',200000),('gpt-5-pro',400000),('gpt-5-thinking',400000),('gpt-5.1',400000),('gpt-5.1-chat-latest',400000),('gpt-5.1-codex',400000),('gpt-5.1-codex-max',400000),('gpt-5.1-codex-mini',400000),('gpt-5.1@eu',400000),('gpt-5.2',400000),('gpt-5.2-chat-latest',400000),('gpt-5.2-codex',400000),('gpt-5.2-pro',400000),('gpt-5.3-chat-latest',400000),('gpt-5.3-codex',400000),('gpt-5.3-codex-xhigh',400000),('gpt-5.4',1050000),('gpt-5.4-mini',400000),('gpt-5.4-nano',400000),('gpt-5.4-pro',1050000),('gpt-5.4:free',1050000),('gpt-5.4@eu',1050000),('gpt-5.5',1050000),('gpt-5.5-pro',1050000),('gpt-5.5:free',1050000),('gpt-5.5@eu',1050000),('gpt-5.6',1050000),('gpt-5.6-luna',1050000),('gpt-5.6-luna-pro',1050000),('gpt-5.6-luna@eu',1050000),('gpt-5.6-sol',1050000),('gpt-5.6-sol-pro',1050000),('gpt-5.6-sol@eu',1050000),('gpt-5.6-terra',1050000),('gpt-5.6-terra-pro',1050000),('gpt-5.6-terra@eu',1050000),('gpt-5@eu',400000),('gpt-6-1-sol',1050000),('gpt-6-astra',1050000),('gpt-6-luna',1050000),('gpt-6-luna@eu',1050000),('gpt-6-sol',1050000),('gpt-6-sol@eu',1050000),('gpt-6.1-sol',1050000),('gpt-6.1-sol@eu',1050000),('gpt-6.1-terra',1050000),('gpt-6.1-terra@eu',1050000),('gpt-chat-latest',400000),('gpt-daybreak-blue-latest',1050000),('gpt-daybreak-red-latest',400000),('gpt-image-1',0),('gpt-image-1-mini',0),('gpt-image-1.5',0),('gpt-image-2',0),('gpt-image-2.5-flare',0),('gpt-image-2.5-sunburst',0),('gpt-live-transcribe',0),('gpt-oss-120b',131072),('gpt-oss-20b',131072),('gpt-oss:120b',131072),('gpt-oss:20b',131072),('gpt-sol-latest',1000000),('gpt-transcribe',0)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('granite-4.2-8b',131072),('green-r',131072),('green-r-raw',131072),('green-s',0),('green-s-pro',0),('greenference/glm-5.3-flash',1048576),('greenference/gpt-oss-20b',131072),('greenference/qwen3-14b',16384),('greenference/qwen3-30b-a3b',8192),('greenference/qwen3.6-27b',16384),('greenpt/deepseek-v4-flash-0731',1000000),('greenpt/deepseek-v4.1-flash',1000000),('greenpt/qwen3-235b-a22b-instruct-2507',250000),('grok-3',131072),('grok-3-mini',131072),('grok-4',256000),('grok-4-0709',256000),('grok-4-1-fast-non-reasoning',2000000),('grok-4-1-fast-reasoning',2000000),('grok-4-20',2000000),('grok-4-20-beta-0309-non-reasoning',2000000),('grok-4-20-beta-0309-reasoning',2000000),('grok-4-20-multi-agent',2000000),('grok-4-20-non-reasoning',2000000),('grok-4-20-reasoning',2000000),('grok-4-3',1000000),('grok-4-5',500000),('grok-4-6',500000),('grok-4-7',500000),('grok-4-fast-non-reasoning',2000000),('grok-4-fast-reasoning',2000000),('grok-4.1',200000),('grok-4.2-beta',2000000),('grok-4.20-0309-non-reasoning',1000000),('grok-4.20-0309-reasoning',1000000),('grok-4.20-beta-0309-reasoning',2000000),('grok-4.20-multi-agent-0309',1000000),('grok-4.3',1000000),('grok-4.5',500000),('grok-4.6',500000),('grok-4.7',500000),('grok-build-0-1',256000),('grok-build-0.1',256000),('grok-code',256000),('grok-code-fast-1',256000),('grok-imagine-image',16000),('grok-imagine-image-2-0',64000),('grok-imagine-video',1024),('grok-imagine-video-1.5',1024),('grok-imagine-video-1.5-lite',1024),('grok/grok-4.3',1000000),('grok/grok-4.5',500000),('grok/grok-4.6',500000),('groq/allam-2-7b',4096),('groq/gpt-oss-120b',131072),('groq/gpt-oss-20b',131072),('groq/meta-llama/llama-prompt-guard-2-22m',512),('groq/meta-llama/llama-prompt-guard-2-86m',512),('groq/openai/gpt-oss-120b',131072),('groq/openai/gpt-oss-20b',131072),('groq/openai/gpt-oss-safeguard-20b',131072),('groq/qwen/qwen3.8-27b',131042),('gryphe/mythomax-l2-13b',8192),('gte-large-en-v1.5',8192),('happyhorse-1.1-i2v',0),('happyhorse-1.1-r2v',0),('happyhorse-1.1-t2v',0),('heabsy/cyberheabsy',1048576),('heabsy/qwen3.8-27b-uncensored-fast',524288),('hermes-2-pro-llama-3-8b',131072),('hermes-high',1048576),('hermes-low',1048576),('hermes-medium',1048576),('heygen/heygen-video-1',0),('hf:MiniMaxAI/MiniMax-M3',524288),('hf:Qwen/Qwen3.6-27B',262144),('hf:deepseek-ai/DeepSeek-V4.1-Flash',524288),('hf:deepseek-ai/DeepSeek-V4.1-Flash-1017',524288),('hf:moonshotai/Kimi-K2.7-Code',262144),('hf:moonshotai/Kimi-K3',524288),('hf:nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4',262144),('hf:openai/gpt-oss-120b',131072),('hf:zai-org/GLM-4.7-Flash',196608),('hf:zai-org/GLM-5.2',524288),('hf:zai-org/GLM-5.3',524288),('hf:zai-org/GLM-5.3-Flash',524288),('holo2-30b-a3b',22016),('holo3-35b-a3b',65536),('holo3-35b-a3b:thinking',65536),('huihui-ai/DeepSeek-R1-Distill-Llama-70B-abliterated',16384),('huihui-ai/DeepSeek-R1-Distill-Qwen-32B-abliterated',16384),('huihui-ai/Llama-3.3-70B-Instruct-abliterated',32768),('huihui-ai/Qwen2.5-32B-Instruct-abliterated',32768),('hunyuan-2.0-instruct',131072),('hunyuan-2.0-thinking',131072),('hunyuan-t1',131072),('hunyuan-turbos',131072),('hy-mt2-plus',8192),('hy3',256000),('hy3-free',190000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('hy3-preview',256000),('hy3-preview-free',256000),('hy3:free',256000),('hy4',1048576),('hy4-preview',1024000),('ibm-granite/granite-4.2-8b',131072),('ibm/granite-4-h-small',131072),('iceman-contributor-free',262144),('ideogramai/ideogram',150),('ideogramai/ideogram-v2',150),('ideogramai/ideogram-v2a',150),('ideogramai/ideogram-v2a-turbo',150),('in.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('in.anthropic.claude-opus-5',1000000),('in.anthropic.claude-sonnet-5',1000000),('in.openai.gpt-5.6-luna',1050000),('in.openai.gpt-5.6-terra',1050000),('inception/mercury-2.5',260000),('inception/mercury-2.5-preview',260000),('inception/mercury-3',1000000),('inception/mercury-coder-small',32000),('inclusionAI/Ling-flash-2.0',131000),('inclusionai/ling-3.0-flash',262144),('inclusionai/ling-3.0-flash-fin',256000),('inclusionai/ling-3.0-flash-sante',256000),('inclusionai/ling-3.0-flash-vl',131072),('inclusionai/ling-3.0-flash:thinking',262144),('inclusionai/ling-3.1-flash',1000000),('inclusionai/ling-3.1-flash-1019',1000000),('inclusionai/ling-3.1-flash:free',262144),('inclusionai/ring-2.6-1t',262000),('infer/gpt-5.6-sol:official',271999),('infer/gpt-6-astra:official',271999),('inference.net/deepseek-v4.1-flash-1017',262144),('inference.net/deepseek-v4.1-flash-cyber',1040000),('inference.net/glm-5.3',1048576),('inference.net/glm-5.3-flash',1048576),('inference.net/minimax-m3.1-flash',1000000),('inflatebot/MN-12B-Mag-Mell-R1',16384),('infomaniak/mistralai/Ministral-3-14B-Instruct-2512',100000),('inkling',1048576),('inkling-256k',262144),('interfaze/interfaze-beta',1000000),('intfloat/e5-mistral-7b-instruct',4096),('intfloat/multilingual-e5-large-instruct',512),('jamba-large',256000),('jamba-mini',256000),('jp.amazon.nova-2-lite-v1:0',1000000),('jp.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('jp.anthropic.claude-haiku-5-5',1000000),('jp.anthropic.claude-opus-4-7',1000000),('jp.anthropic.claude-opus-4-8',1000000),('jp.anthropic.claude-opus-5',1000000),('jp.anthropic.claude-opus-5-5',1000000),('jp.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('jp.anthropic.claude-sonnet-4-6',1000000),('jp.anthropic.claude-sonnet-5',1000000),('k3',1048576),('k3-256k',262144),('k3.1-pro',1048576),('k3.1-pro-highspeed',1048576),('kat-coder-pro',256000),('kilo-auto/balanced',1000000),('kilo-auto/efficient',1000000),('kilo-auto/free',256000),('kilo-auto/frontier',1000000),('kilo-auto/small',262144),('kimi-for-coding',1048576),('kimi-for-coding-highspeed',262144),('kimi-k2',262144),('kimi-k2-0711',131072),('kimi-k2-0905',262144),('kimi-k2-0905-preview',262144),('kimi-k2-5',256000),('kimi-k2-6',262144),('kimi-k2-6:free',262144),('kimi-k2-7-code',262144),('kimi-k2-7-code-highspeed',262144),('kimi-k2-7-code:free',262144),('kimi-k2-instruct-fast',131072),('kimi-k2-thinking',262144),('kimi-k2-turbo-preview',256000),('kimi-k2.5',262144),('kimi-k2.5-free',262144),('kimi-k2.6',262144),('kimi-k2.6-fast',262144),('kimi-k2.6-nitro',200000),('kimi-k2.6@eu',256000),('kimi-k2.7-code',262144),('kimi-k2.7-code-fast',262128),('kimi-k2.7-code-flex',262128),('kimi-k2.7-code-highspeed',262144),('kimi-k2.7-code-nitro',200000),('kimi-k2.7-code@eu',262144),('kimi-k2.8-preview',1000000),('kimi-k3',1048576),('kimi-k3-1-pro',1000000),('kimi-k3-1-pro-highspeed',1000000),('kimi-k3-fast',1040384),('kimi-k3-fast-api',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('kimi-k3-flex',1048560),('kimi-k3.1-pro',1048576),('kimi-k3.1-pro-highspeed',1048576),('kimi-k3:fast',1048576),('kimi-k3@eu',1048576),('kimi-latest',256000),('kimi/kimi-k2.5',262144),('kimi/kimi-k2.6',262144),('kimi/kimi-k2.7-code',262144),('kimi/kimi-k3',1048576),('kling-v2-6',99999999),('klingai/kling-v2.5-turbo-i2v',0),('klingai/kling-v2.5-turbo-t2v',0),('klingai/kling-v2.6-i2v',0),('klingai/kling-v2.6-motion-control',0),('klingai/kling-v2.6-t2v',0),('klingai/kling-v3.0-i2v',0),('klingai/kling-v3.0-motion-control',0),('klingai/kling-v3.0-t2v',0),('kolibri-1',262144),('labs-devstral-small-2512',256000),('labs-leanstral-1-5-1',262144),('laguna-m.1',32768),('laguna-s-2.1',1048576),('laguna-s-2.1-free',256000),('laguna-xs.2',32768),('leanstral-1-5',262144),('leanstral-1-5@eu',262144),('leonardo-ai/lucid-origin',4096),('leonardo-ai/lucid-realism',4096),('lightonai/LightOnOCR-2-1B',32768),('lightonocr-3-0.8b',262144),('ling-2.6-1t',262144),('ling-2.6-flash',262144),('ling-2.6-flash-free',262100),('ling-3.0-flash',262144),('ling-3.0-flash-fin-free',262144),('ling-3.0-flash-free',262144),('ling-3.0-flash-vl',131072),('ling-3.0-tiny',262144),('ling-3.0-tiny-free',262144),('ling-3.1-flash-free',262144),('liquid.auto',10000000),('liquid/lfm-2.5-2.6b:free',65536),('ll-alpha-free',262144),('llama-3.1-8b-instant',131072),('llama-3.1-8b-instruct',16384),('llama-3.3-70b-instruct',131072),('llama-4-maverick',1000000),('llama-4-maverick-17b-128e-instruct-fp8',1000000),('llama-4-maverick-17b-instruct',1048576),('llama-4-scout',131072),('llama-4-scout-17b-instruct',131072),('llama-guard-4',131072),('llama-prompt-guard-2-22m',512),('llama-prompt-guard-2-86m',512),('llama3-3-70b',131072),('longcat-2.0',1000000),('longcat-2.0-free',1000000),('longcat-2.0:thinking',1000000),('longcat-2.5-preview-free',1000000),('lucidnova-rf1-100b',120000),('lucidquery-agi-01-frontier',300000),('lucidquery-agi-01-swift',300000),('lucidquery-nexus-coder',250000),('lumalabs/ray2',5000),('luminal/deepseek-v4.1-flash',1000000),('lyria-3-clip-preview',1048576),('lyria-3-pro-preview',1048576),('magibu-11b-v8',8192),('magistral-medium-latest',262144),('mai-code-1.1-flash',256000),('mancer/weaver',8000),('medgemma-4b',8192),('meganova-ai/manta-flash-1.0',16384),('meganova-ai/manta-mini-1.0',8192),('meganova-ai/manta-pro-1.0',65536),('meituan-longcat/LongCat-2.0',1049000),('meituan/longcat-2.0',1048756),('meituan/longcat-2.5',1048576),('meituan/longcat-2.5-preview',1000000),('meituan/longcat-flash-chat',131072),('meituan/longcat-flash-lite',256000),('mercury-2-5',260000),('mercury-2.5',260000),('mercury-3',1000000),('mercury-coder-small',32768),('mercury-edit-2',32000),('meta-contributor/muse-spark-1.2-contributor',1048576),('meta-contributor/muse-spark-1.3-contributor',1048576),('meta-llama-3-1-8b-instruct',131072),('meta-llama-3_3-70b-instruct',131072),('meta-llama/Llama-3.1-8B-Instruct',131072),('meta-llama/Llama-3.2-90B-Vision-Instruct',16000),('meta-llama/Llama-3.3-70B-Instruct-Turbo',131072),('meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8',430000),('meta-llama/Llama-4-Scout-17B-16E-Instruct',327680),('meta-llama/Llama-Guard-4-12B',163840),('meta-llama/Meta-Llama-3.3-70B-Instruct',131072),('meta-llama/llama-3-3-70b-instruct',131072)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('meta-llama/llama-3.1-70b-instruct',131072),('meta-llama/llama-3.1-8b-instruct',131072),('meta-llama/llama-3.2-1b-instruct',60000),('meta-llama/llama-3.2-3b-instruct',131072),('meta-llama/llama-3.3-70b-instruct',131072),('meta-llama/llama-4-maverick',524288),('meta-llama/llama-4-maverick-17b-128e-instruct-fp8',1048576),('meta-llama/llama-4-scout',327680),('meta-llama/llama-4-scout-17b-16e-instruct',131072),('meta-llama/llama-guard-4-12b',163840),('meta-llama/llama-prompt-guard-2-22m',512),('meta-llama/llama-prompt-guard-2-86m',512),('meta-models/Muse-Spark-Open-816B-A42B',1048576),('meta-models/muse-spark-open',1048576),('meta.llama-4-maverick-17b-128e-instruct-fp8',512000),('meta.llama-4-scout-17b-16e-instruct',192000),('meta.llama4-maverick-17b-instruct-v1:0',1000000),('meta.llama4-scout-17b-instruct-v1:0',10000000),('meta/llama-3.2-1b-instruct',16000),('meta/llama-3.2-3b-instruct',16000),('meta/llama-3.3-70b-instruct',131072),('meta/llama-4-maverick-17b-128e-instruct-maas',524288),('meta/llama-4-scout-17b-16e-instruct-maas',1310720),('meta/llama-guard-4-12b',163840),('meta/muse-glimmer-30b',131072),('meta/muse-image-1.0',0),('meta/muse-spark-1.1',1048576),('meta/muse-spark-1.2',1048576),('meta/muse-spark-1.2-contributor',1048576),('meta/muse-spark-1.3',1048576),('meta/muse-spark-1.3-contributor',1048576),('meta/muse-spark-open',1048576),('meta/muse-wonder',1048576),('meta/muse-wonder-1.0',1048576),('microsoft/gpt-4',8191),('microsoft/mai-image-2.6',0),('microsoft/mai-image-2.6-flash',0),('microsoft/mai-transcribe-2',0),('microsoft/mai-transcribe-2-streaming',0),('microsoft/mai-voice-2',0),('microsoft/mai-voice-2-flash',0),('microsoft/mai-voice-2.1',0),('microsoft/mai-voice-2.1-flash',0),('microsoft/o3-mini',200000),('microsoft/phi-4',16384),('microsoft/wizardlm-2-8x22b',65535),('mimo-v2-5',1048576),('mimo-v2-5-pro',1048576),('mimo-v2-5:free',1048576),('mimo-v2-6-flash',1048576),('mimo-v2-6-pro',1048576),('mimo-v2-6-pro-ultraspeed',1048576),('mimo-v2-flash',256000),('mimo-v2-flash-free',262144),('mimo-v2-omni-free',262144),('mimo-v2-pro',1048576),('mimo-v2-pro-free',1048576),('mimo-v2.5',1000000),('mimo-v2.5-free',200000),('mimo-v2.5-pro',1048576),('mimo-v2.5-pro-ultraspeed',1048576),('mimo-v2.5-tts',8192),('mimo-v2.5-tts-voiceclone',8192),('mimo-v2.5-tts-voicedesign',8192),('mimo-v2.6-flash',1048576),('mimo-v2.6-flash-free',200000),('mimo-v2.6-flash-rl',1048576),('mimo-v2.6-pro',1048576),('mimo-v2.6-pro-flex',1048560),('mimo-v2.6-pro-rl',1048576),('mimo-v2.6-pro-ultraspeed',1048576),('mimo-v25',1000000),('mimo/mimo-v2.5',1000000),('mimo/mimo-v2.5-pro',1000000),('mindai/macaron-v1-tall',262144),('mindai/macaron-v1-venti',1048576),('mini_lm_l12_v2',128),('minicpm-v-4.5',32000),('minimax-latest',1000000),('minimax-m2',196608),('minimax-m2-5',192000),('minimax-m2-7',204800),('minimax-m2-7-highspeed',204800),('minimax-m2.1',204800),('minimax-m2.1-free',204800),('minimax-m2.1-lightning',196608),('minimax-m2.5',204800),('minimax-m2.5-free',204800),('minimax-m2.5-highspeed',204800),('minimax-m2.7',204800),('minimax-m2.7-highspeed',204800),('minimax-m2.7:free',204800),('minimax-m25',198000),('minimax-m27',198000),('minimax-m3',1000000),('minimax-m3-1-flash',1048576),('minimax-m3-free',200000),('minimax-m3-preview',524288),('minimax-m3.1-flash',1000000),('minimax-m3.1-flash-free',1000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('minimax-m3.1-flash@eu',1048576),('minimax-m3:fast',1048576),('minimax-m3@eu',1048576),('minimax-text-01',1000000),('minimax.minimax-m2',204608),('minimax.minimax-m2.1',196608),('minimax.minimax-m2.5',196608),('minimax/MiniMax-M2',204800),('minimax/MiniMax-M2.1',204800),('minimax/MiniMax-M2.5',204800),('minimax/MiniMax-M2.7',204800),('minimax/MiniMax-M2.7-highspeed',204800),('minimax/MiniMax-M3',524288),('minimax/MiniMax-M3.1-Flash',1048576),('minimax/m2-her',65536),('minimax/m3.1-flash',1000000),('minimax/minimax-01',1000192),('minimax/minimax-h3',0),('minimax/minimax-h3-max',0),('minimax/minimax-latest',512000),('minimax/minimax-m1',1000000),('minimax/minimax-m2',204800),('minimax/minimax-m2-her',65536),('minimax/minimax-m2.1',204800),('minimax/minimax-m2.1-lightning',196608),('minimax/minimax-m2.5',204800),('minimax/minimax-m2.5-highspeed',204800),('minimax/minimax-m2.5-lightning',204800),('minimax/minimax-m2.7',204800),('minimax/minimax-m2.7-highspeed',204800),('minimax/minimax-m2.7-turbo',204800),('minimax/minimax-m3',1048576),('minimax/minimax-m3.1-flash',1048576),('minimax/minimax-m3:thinking',512000),('minimax/minimax-text-01',1000000),('minimaxai/chat-completion/models/MiniMax-M2_5-high-throughput',204800),('minimaxai/minimax-m1-80k',1000000),('minimaxai/minimax-m3',1048576),('minimaxai/minimax-m3.1-flash',262144),('ministral-14b-2512',262144),('ministral-3b-2512',131072),('ministral-3b-latest',131072),('ministral-8b-2512',262144),('ministral-8b-latest',262144),('mistral-3-14B',262144),('mistral-7b-instruct-v0.2',32000),('mistral-code-agent-latest',262144),('mistral-code-latest',256000),('mistral-embed',8000),('mistral-large-2402',32000),('mistral-large-2512',262144),('mistral-large-3:675b',262144),('mistral-large-4',524288),('mistral-large-4-0',1000000),('mistral-large-4-0-8',1048576),('mistral-large-4@eu',524288),('mistral-large:free',262144),('mistral-medium-2508',262144),('mistral-medium-2604',262144),('mistral-medium-3',131072),('mistral-medium-3-5',262144),('mistral-medium-3-5:free',262144),('mistral-medium-3-5@eu',262144),('mistral-medium-3.5',256000),('mistral-medium-3.5-128b',262144),('mistral-medium-latest',131072),('mistral-medium-latest@eu',131072),('mistral-nemo-instruct-2407',118000),('mistral-small-2603',262144),('mistral-small-2603@eu',256000),('mistral-small-3-2-24b-instruct',256000),('mistral-small-3.2-24b-instruct-2506',131072),('mistral-small-4',262144),('mistral-small-4-119b',256000),('mistral-small-latest',262144),('mistral.devstral-2-123b',262144),('mistral.ministral-3-3b-instruct',256000),('mistral.mistral-large-3-675b-instruct',262144),('mistral.voxtral-mini-3b-2507',32768),('mistral.voxtral-small-24b-2507',32768),('mistral/codestral-2508',256000),('mistral/codestral-2508@eu',256000),('mistral/codestral-embed',8192),('mistral/codestral-latest',256000),('mistral/codestral-latest@eu',256000),('mistral/devstral-2512',262144),('mistral/devstral-2512@eu',262144),('mistral/devstral-medium-latest',262144),('mistral/devstral-medium-latest@eu',262144),('mistral/glm-5.3',1048576),('mistral/magistral-medium-latest',262144),('mistral/magistral-medium-latest@eu',262144),('mistral/ministral-14b',262144),('mistral/ministral-14b-2512',262144),('mistral/ministral-14b-2512@eu',262144),('mistral/ministral-3b',131072),('mistral/ministral-3b-2512',131072),('mistral/ministral-3b-2512@eu',131072),('mistral/ministral-8b',262144),('mistral/ministral-8b-2512',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('mistral/ministral-8b-2512@eu',262144),('mistral/mistral-embed',8000),('mistral/mistral-large-2407',131072),('mistral/mistral-large-2407@eu',131072),('mistral/mistral-large-2512',262144),('mistral/mistral-large-2512@eu',262144),('mistral/mistral-large-3',262144),('mistral/mistral-large-4',1000000),('mistral/mistral-large-4@eu',524288),('mistral/mistral-large-latest@eu',262144),('mistral/mistral-medium-2505',131072),('mistral/mistral-medium-2505@eu',131072),('mistral/mistral-medium-2604',262144),('mistral/mistral-medium-2604@eu',262144),('mistral/mistral-medium-3',262144),('mistral/mistral-medium-3-5',262144),('mistral/mistral-medium-3-5@eu',262144),('mistral/mistral-medium-3.5',262144),('mistral/mistral-medium-3@eu',262144),('mistral/mistral-medium-latest',262144),('mistral/mistral-medium-latest@eu',262144),('mistral/mistral-nemo',131072),('mistral/mistral-nemo-12b-instruct',16000),('mistral/mistral-small',262144),('mistral/mistral-small-2603',262144),('mistral/mistral-small-2603@eu',262144),('mistral/mistral-small-latest',262144),('mistral/mistral-small-latest@eu',262144),('mistral/voxtral-mini-transcribe-3',0),('mistral/voxtral-mini-tts-3',0),('mistral/voxtral-small-latest',32768),('mistral/voxtral-small-latest@eu',32768),('mistral/voxtral-small-transcribe-3',0),('mistral/zai-glm-5-2',1000000),('mistral/zai-glm-5-3',1000000),('mistral4-119b',262144),('mistralai--mistral-medium',262144),('mistralai/Ministral-3-14B-Instruct-2512',100000),('mistralai/Mistral-Medium-3.5-128B',262144),('mistralai/Mistral-Small-24B-Instruct-2501',32768),('mistralai/Mistral-Small-3.2-24B-Instruct-2506',32000),('mistralai/Mistral-Small-4-119B-2603',256000),('mistralai/Voxtral-Small-24B-2507',32000),('mistralai/codestral-2508',256000),('mistralai/completion/models/Ministral-3-14B-Reasoning-2512',262144),('mistralai/completion/models/Ministral-3-3B-Reasoning-2512',262144),('mistralai/devstral-2-123b-instruct-2512',262144),('mistralai/devstral-2512',262144),('mistralai/devstral-small-2505',32768),('mistralai/magistral-small-2506',32768),('mistralai/ministral-14b-2512',262144),('mistralai/ministral-14b-instruct-2512',262144),('mistralai/ministral-3b-2512',131072),('mistralai/ministral-8b-2512',262144),('mistralai/mistral-7b-instruct-v0.3',65536),('mistralai/mistral-large-2407',131072),('mistralai/mistral-large-2512',262144),('mistralai/mistral-large-4',524288),('mistralai/mistral-large-4-0',1048576),('mistralai/mistral-medium-3',131072),('mistralai/mistral-medium-3-5',262144),('mistralai/mistral-medium-3-instruct',131072),('mistralai/mistral-medium-3.1',131072),('mistralai/mistral-medium-3.5',256000),('mistralai/mistral-medium-3.5:thinking',256000),('mistralai/mistral-nemo',131072),('mistralai/mistral-nemo-instruct-2407',16384),('mistralai/mistral-saba',32768),('mistralai/mistral-small-24b-instruct-2501',32768),('mistralai/mistral-small-2603',262144),('mistralai/mistral-small-3-1-24b-instruct-2503',131072),('mistralai/mistral-small-3.2-24b-instruct',256000),('mistralai/mistral-small-4-119b-2603',262144),('mistralai/mistral-small-4-119b-2603:thinking',262144),('mistralai/mixtral-8x22b-instruct',65536),('mistralai/mixtral-8x22b-instruct-v0.1',65536),('mistralai/voxtral-small-24b-2507',32768),('mixedbread/toast-1',131000),('mixtral-8x7B-instruct-v0.1',32000),('mlabonne/NeuralDaredevil-8B-abliterated',8192),('model-router',200000),('moondream/moondream3-preview',32000),('moondream/moondream3.1-9b-a2b',32000),('moonshot-ai/kimi-k2.7-code',262144),('moonshot-ai/kimi-k3',1048576),('moonshot-kimi-k2-instruct',131072),('moonshot.kimi-k2-thinking',262144),('moonshot/kimi-k2.5',262144),('moonshot/kimi-k2.6',262144),('moonshot/kimi-k2.7-code',262144),('moonshot/kimi-k2.7-code-highspeed',262144),('moonshot/kimi-k3',1048576),('moonshot/kimi-k3.1-pro',1048576),('moonshot/kimi-k3.1-pro-highspeed',1048576),('moonshotai.kimi-k2.5',262144),('moonshotai/Kimi-K2-Instruct',131072),('moonshotai/Kimi-K2-Instruct-0905',32768),('moonshotai/Kimi-K2-Thinking',32768),('moonshotai/Kimi-K2.5',262000),('moonshotai/Kimi-K2.6',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('moonshotai/Kimi-K2.6-TEE',262144),('moonshotai/Kimi-K2.6:peft:131072',131072),('moonshotai/Kimi-K2.7-Code',262144),('moonshotai/Kimi-K2.7-Code-Highspeed',262000),('moonshotai/Kimi-K3',1048576),('moonshotai/Kimi-K3-Fast',1000000),('moonshotai/Kimi-K3-TEE',1048576),('moonshotai/Kimi-K3.1-Pro',1000000),('moonshotai/chat-completion/models/Kimi-K2_6',262144),('moonshotai/kimi-k2',131072),('moonshotai/kimi-k2-0905',262144),('moonshotai/kimi-k2-instruct',131072),('moonshotai/kimi-k2-thinking',262144),('moonshotai/kimi-k2-thinking-maas',262144),('moonshotai/kimi-k2.5',262144),('moonshotai/kimi-k2.5:thinking',262144),('moonshotai/kimi-k2.6',262144),('moonshotai/kimi-k2.6:thinking',262144),('moonshotai/kimi-k2.7-code',262144),('moonshotai/kimi-k2.7-code-highspeed',262144),('moonshotai/kimi-k3',1048576),('moonshotai/kimi-k3-fast',1000000),('moonshotai/kimi-k3.1-pro',1048576),('moonshotai/kimi-k3.1-pro-highspeed',1048576),('moonshotai/kimi-latest',1048576),('morph-dsv41flash',1048576),('morph-dsv41flash-1017',1048576),('morph-dsv4flash',1048576),('morph-glm52-744b',1048576),('morph-glm53-744b',1048576),('morph-glm53flash',1048576),('morph-kimik3',1048576),('morph-kimik3-fast',1048576),('morph-v3-fast',262144),('morph-v3-large',262144),('morph/morph-v3-fast',262144),('morph/morph-v3-large',262144),('motif-technologies/motif-3',262144),('multi-qa-mpnet-base-dot-v1',512),('muse-glimmer-30b',131072),('muse-glimmer-30b-tr',131072),('muse-spark-1-1',1048576),('muse-spark-1-2',1048576),('muse-spark-1-3',1048576),('muse-spark-1.1',1048576),('muse-spark-1.2',1048576),('muse-spark-1.2-contributor',1048576),('muse-spark-1.2-contributor-free',1048576),('muse-spark-1.3',1048576),('muse-spark-1.3-contributor',1048576),('muse-spark-1.3-contributor-free',1048576),('muse-spark-open',1048576),('muse-wonder',1048576),('muse-wonder-1.0',1048576),('nano-banana-2',131072),('nano-banana-2-lite',65536),('nano-banana-pro',65536),('nano-gpt-help',6000),('nanogpt/coding-router',1000000),('nanogpt/coding-router:high',1000000),('nanogpt/coding-router:low',1000000),('nanogpt/coding-router:max',1000000),('nanogpt/coding-router:medium',1000000),('nebius/Qwen/Qwen3-235B-A22B-Instruct-2507',262144),('nebius/Qwen/Qwen3-30B-A3B-Instruct-2507',262144),('nebius/deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('nebius/deepseek-ai/DeepSeek-V4-Pro-0813',1048576),('nebius/deepseek-ai/DeepSeek-V4.1-Flash',1048576),('nebius/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('nebius/google/gemma-3-27b-it',110000),('nebius/meta-models/muse-spark-open',1048576),('nebius/minimax-m3.1-flash',1048576),('nebius/nvidia/Nemotron-3-Ultra-550b-a55b',1048576),('nebius/nvidia/nemotron-3-super-120b-a12b',262144),('nebius/openai/gpt-oss-120b',131072),('nemotron-3-nano-30b-a3b',262144),('nemotron-3-nano-omni',65536),('nemotron-3-nano-omni-30b-a3b-reasoning',262144),('nemotron-3-nano-omni-30b-a3b-reasoning-free',256000),('nemotron-3-nano-omni@eu',300000),('nemotron-3-nano:30b',1048576),('nemotron-3-super',262144),('nemotron-3-super-120b-a12b',262144),('nemotron-3-super-120b-a12b-free',262144),('nemotron-3-super-120b-a12b:free',262144),('nemotron-3-super-free',204800),('nemotron-3-ultra',262144),('nemotron-3-ultra-550b',1048576),('nemotron-3-ultra-550b-a55b',1000000),('nemotron-3-ultra-550b-a55b-free',1000000),('nemotron-3-ultra-550b-a55b:free',1000000),('nemotron-3-ultra-free',1000000),('nemotron-3-ultra-nvfp4',262144),('nemotron-3.5-content-safety',131072),('nemotron-3.5-lightning-30b-a3b',1048576),('nemotron-3.5-lightning-free',262144),('nemotron-3.5-super-vl',1048576),('nemotron-3.5-super-vl-free',1048576),('nemotron-lightning-3.5-30b-a3b',262144),('nemotron3-super',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('neosmith.intelligent-basic',1000000),('neosmith.intelligent-maestro',1000000),('neosmith.intelligent-pro',1000000),('neosmith.neolite',512000),('nex-agi/Nex-N2-Pro',262144),('nex-agi/nex-n2.5-mini',262144),('nex-agi/nex-n2.5-pro',262144),('nomic-embed-text',8192),('north-mini-code-1-0',256000),('north-mini-code-free',256000),('north-small-translate-09-2026',32768),('nothingiisreal/L3.1-70B-Celeste-V0.1-BF16',32768),('nousresearch/hermes-2-pro-llama-3-8b',8192),('nousresearch/hermes-3-llama-3.1-405b',131072),('nousresearch/hermes-3-llama-3.1-70b',131072),('nousresearch/hermes-4-405b',131072),('nova-2-lite',1000000),('nova-2-lite-v1',1000000),('nova-2-pro-v1',1000000),('nova-lite-v1',300000),('nova-pro-v1',300000),('novita/deepseek-v4-flash',1050000),('novita/deepseek-v4.1-flash',1048576),('novita/deepseek-v4.1-flash-1017',1048576),('novita/gemma-4-26b-a4b-it',262144),('novita/gemma-4-31b-it',262144),('novita/glm-4.5v',65536),('novita/glm-4.6',204800),('novita/glm-4.6v',131072),('novita/glm-4.7',204800),('novita/glm-4.7-flash',200000),('novita/glm-4.7-n',205000),('novita/glm-5',202800),('novita/glm-5.1',204800),('novita/glm-5.2',1048576),('novita/glm-5.3',1048576),('novita/glm-5.3-flash',1048576),('novita/hy3',262144),('novita/kimi-k2',131072),('novita/kimi-k2-thinking',256000),('novita/kimi-k2.6',262144),('novita/kimi-k2.7-code',262144),('novita/kimi-k3',1048576),('novita/ling-3.0-flash',262144),('novita/llama-3.3-70b-instruct',131072),('novita/llama-4-maverick-17b-instruct',1048576),('novita/llama-4-scout-17b-instruct',131072),('novita/minimax-m2.1',205000),('novita/minimax-m2.5',204800),('novita/minimax-m2.7',204800),('novita/minimax-m3.1-flash',1000000),('novita/qwen3-vl-30b-a3b-instruct',131072),('novita/qwen3.5-122b-a10b',262144),('novita/qwen3.6-35b-a3b',262144),('novita/qwen3.7-max',1000000),('novita/qwen3.8-2.4t-a95b',1000000),('novita/qwen3.8-27b',1000000),('novita/qwen3.8-flash',1000000),('novita/qwen3.8-max',1000000),('novita/qwen35-397b-a17b',262144),('novita/step-3.7-flash',262144),('nvidia--llama-3.2-nv-embedqa-1b',8192),('nvidia--llama-nemotron-embed-1b',8192),('nvidia-nemotron-3-5-super-vl-120b-a12b',262144),('nvidia-nemotron-3-super-120b-a12b',262144),('nvidia-nemotron-3-ultra',262144),('nvidia-nemotron-3-ultra-550b-a55b',256000),('nvidia.nemotron-nano-12b-v2',131072),('nvidia.nemotron-nano-3-30b',262144),('nvidia.nemotron-nano-9b-v2',131072),('nvidia.nemotron-super-3-120b',262144),('nvidia/GLM-5.3-Flash-NVFP4',1000000),('nvidia/Llama-3.1-Nemotron-70B-Instruct-HF',16384),('nvidia/Llama-3.3-Nemotron-Super-49B-v1.5',131072),('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B',262144),('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16',65536),('nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8',1000000),('nvidia/NVIDIA-Nemotron-3-Super-120B-A12B',262144),('nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16',65536),('nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16:peft:262144',262144),('nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B',262144),('nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-BF16',65536),('nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-BF16:peft:262144',262144),('nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B',262144),('nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16',65536),('nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16:peft:262144',262144),('nvidia/NVIDIA-Nemotron-3.5-Super-VL',262144),('nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B',1048576),('nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16',65536),('nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16:peft:262144',262144),('nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4',262144),('nvidia/Nemotron-3-Nano-30B-A3B',262144),('nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning',262144),('nvidia/Nemotron-3-Nano-Omni-Reasoning-30B-A3B',256000),('nvidia/Nemotron-3-Ultra-550b-a55b',1048576),('nvidia/Nemotron-3.5-Super-VL',1048576),('nvidia/Nemotron-3_5-Lightning',1048576),('nvidia/Qwen3.8-27B-NVFP4',262144),('nvidia/active-speaker-detection',0),('nvidia/cosmos-reason2-8b',131072)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('nvidia/cosmos-transfer2_5-2b',0),('nvidia/llama-nemotron-embed-vl-1b-v2',8192),('nvidia/llama-nemotron-rerank-vl-1b-v2',10240),('nvidia/magpie-tts-zeroshot',0),('nvidia/nemotron-3-nano-30b-a3b',262144),('nvidia/nemotron-3-nano-omni-30b-a3b-reasoning',256000),('nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',256000),('nvidia/nemotron-3-super-120b-a12b',1048576),('nvidia/nemotron-3-super-120b-a12b:thinking',262144),('nvidia/nemotron-3-ultra-550b-a55b',262144),('nvidia/nemotron-3-ultra-550b-a55b:free',1000000),('nvidia/nemotron-3-ultra-550b-a55b:thinking',1000000),('nvidia/nemotron-3.5-content-safety',131072),('nvidia/nemotron-3.5-lightning',262144),('nvidia/nemotron-3.5-lightning-30b-a3b',1000000),('nvidia/nemotron-3.5-lightning-free',1000000),('nvidia/nemotron-3.5-lightning:free',1000000),('nvidia/nemotron-3.5-lightning:thinking',1000000),('nvidia/nemotron-3.5-super-vl',1048576),('nvidia/nemotron-3.5-super-vl-120b-a12b',1048576),('nvidia/nemotron-3.5-super-vl:free',1000000),('nvidia/nemotron-nano-12b-v2-vl',131072),('nvidia/nemotron-nano-9b-v2',131072),('nvidia/studiovoice',0),('nvidia/synthetic-video-detector',0),('nvidia/usdvalidate',0),('o1',200000),('o1-pro',200000),('o3',200000),('o3-mini',200000),('o3-pro',200000),('o4-mini',200000),('o4-mini@eu',200000),('olafangensan-glm-4.7-flash-heretic',200000),('openai-gpt-4.1',1047576),('openai-gpt-5',400000),('openai-gpt-5-mini',400000),('openai-gpt-5-nano',400000),('openai-gpt-5.1',272000),('openai-gpt-5.2',400000),('openai-gpt-5.2-pro',400000),('openai-gpt-5.3-codex',400000),('openai-gpt-5.4',400000),('openai-gpt-5.4-mini',400000),('openai-gpt-5.4-nano',400000),('openai-gpt-5.4-pro',1050000),('openai-gpt-5.5',1000000),('openai-gpt-5.6-luna',1050000),('openai-gpt-5.6-sol',1050000),('openai-gpt-5.6-terra',1050000),('openai-gpt-52',256000),('openai-gpt-53-codex',400000),('openai-gpt-54',1000000),('openai-gpt-54-mini',400000),('openai-gpt-54-pro',1000000),('openai-gpt-55',1000000),('openai-gpt-55-pro',1000000),('openai-gpt-56-luna',1000000),('openai-gpt-56-luna-pro',1000000),('openai-gpt-56-sol',1000000),('openai-gpt-56-sol-pro',1000000),('openai-gpt-56-terra',1000000),('openai-gpt-56-terra-pro',1000000),('openai-gpt-6-1-sol',1050000),('openai-gpt-6-astra',1050000),('openai-gpt-6-astra-pro',1050000),('openai-gpt-6-luna',1050000),('openai-gpt-6-sol',1050000),('openai-gpt-6.1-terra',1050000),('openai-gpt-61-sol',1050000),('openai-gpt-61-sol-ultrafast',1050000),('openai-gpt-61-terra',1050000),('openai-gpt-image-1',0),('openai-gpt-image-1.5',0),('openai-gpt-image-2',0),('openai-o1',200000),('openai-o3',200000),('openai-o3-mini',200000),('openai.gpt-5.4',1000000),('openai.gpt-5.5',1000000),('openai.gpt-5.6-luna',1050000),('openai.gpt-5.6-sol',1050000),('openai.gpt-5.6-terra',1050000),('openai.gpt-6-astra',1050000),('openai.gpt-6-luna',1050000),('openai.gpt-6-sol',1050000),('openai.gpt-6.1-sol',1050000),('openai.gpt-6.1-terra',1050000),('openai.gpt-oss-120b',131072),('openai.gpt-oss-120b-1:0',131072),('openai.gpt-oss-20b',131072),('openai.gpt-oss-20b-1:0',131072),('openai/chat-completion/models/gpt-oss-120b-high-throughput',131072),('openai/chat-completion/models/gpt-oss-20b',131072),('openai/chat-latest',400000),('openai/dall-e-3',800),('openai/gpt-3.5-turbo',16385),('openai/gpt-3.5-turbo-0613',4095),('openai/gpt-3.5-turbo-16k',16385),('openai/gpt-3.5-turbo-instruct',3500)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('openai/gpt-3.5-turbo-raw',4524),('openai/gpt-4',8191),('openai/gpt-4.1',1047576),('openai/gpt-4.1-fast',1047576),('openai/gpt-4.1-mini',1047576),('openai/gpt-4.1-mini-fast',1047576),('openai/gpt-4.1-nano',1047576),('openai/gpt-4o-mini-transcribe',16000),('openai/gpt-4o-transcribe',16000),('openai/gpt-5',400000),('openai/gpt-5-1',400000),('openai/gpt-5-2',400000),('openai/gpt-5-4',1050000),('openai/gpt-5-5',1050000),('openai/gpt-5-codex',400000),('openai/gpt-5-fast',400000),('openai/gpt-5-image',400000),('openai/gpt-5-image-mini',400000),('openai/gpt-5-mini',400000),('openai/gpt-5-mini-fast',400000),('openai/gpt-5-nano',400000),('openai/gpt-5-pro',400000),('openai/gpt-5-search-api',272000),('openai/gpt-5.1',400000),('openai/gpt-5.1-2025-11-13',400000),('openai/gpt-5.1-codex',400000),('openai/gpt-5.1-codex-max',400000),('openai/gpt-5.1-codex-mini',400000),('openai/gpt-5.1-thinking',400000),('openai/gpt-5.1-thinking-fast',400000),('openai/gpt-5.2',400000),('openai/gpt-5.2-codex',400000),('openai/gpt-5.2-fast',400000),('openai/gpt-5.2-pro',400000),('openai/gpt-5.3-codex',400000),('openai/gpt-5.3-codex-fast',400000),('openai/gpt-5.4',1050000),('openai/gpt-5.4-fast',1050000),('openai/gpt-5.4-image-2',272000),('openai/gpt-5.4-mini',400000),('openai/gpt-5.4-mini-fast',400000),('openai/gpt-5.4-nano',400000),('openai/gpt-5.4-pro',1050000),('openai/gpt-5.5',1050000),('openai/gpt-5.5-fast',1000000),('openai/gpt-5.5-pro',1050000),('openai/gpt-5.6-luna',1050000),('openai/gpt-5.6-luna-fast',1050000),('openai/gpt-5.6-luna-pro',1050000),('openai/gpt-5.6-sol',1050000),('openai/gpt-5.6-sol-fast',1050000),('openai/gpt-5.6-sol-pro',1050000),('openai/gpt-5.6-terra',1050000),('openai/gpt-5.6-terra-fast',1050000),('openai/gpt-5.6-terra-pro',1050000),('openai/gpt-6-astra',1050000),('openai/gpt-6-astra-fast',1050000),('openai/gpt-6-astra-pro',1050000),('openai/gpt-6-luna',1050000),('openai/gpt-6-luna-fast',1050000),('openai/gpt-6-luna-pro',1050000),('openai/gpt-6-sol',1050000),('openai/gpt-6-sol-fast',1050000),('openai/gpt-6-sol-pro',1050000),('openai/gpt-6.1-sol',1050000),('openai/gpt-6.1-sol-fast',1050000),('openai/gpt-6.1-sol-pro',1050000),('openai/gpt-6.1-terra',1050000),('openai/gpt-6.1-terra-fast',1050000),('openai/gpt-6.1-terra-pro',1050000),('openai/gpt-astra-latest',1050000),('openai/gpt-chat-latest',400000),('openai/gpt-image-1-mini',0),('openai/gpt-image-1.5',0),('openai/gpt-image-2.5-flare',0),('openai/gpt-image-2.5-sunburst',0),('openai/gpt-latest',1050000),('openai/gpt-live-1',0),('openai/gpt-live-transcribe',0),('openai/gpt-luna-latest',1050000),('openai/gpt-mini-latest',1050000),('openai/gpt-oss-120b',131072),('openai/gpt-oss-120b-maas',131072),('openai/gpt-oss-120b:peft:131072',131072),('openai/gpt-oss-20b',131072),('openai/gpt-oss-20b-maas',131072),('openai/gpt-oss-safeguard-20b',131072),('openai/gpt-pro-latest',1050000),('openai/gpt-realtime-1.5',32000),('openai/gpt-realtime-mini',32000),('openai/gpt-realtime-whisper',16000),('openai/gpt-sol-latest',1050000),('openai/gpt-terra-latest',1050000),('openai/gpt-transcribe',0),('openai/o1',200000),('openai/o1-pro',200000),('openai/o3',200000),('openai/o3-deep-research',200000),('openai/o3-fast',200000),('openai/o3-mini',200000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('openai/o3-mini-high',200000),('openai/o3-mini-low',200000),('openai/o3-pro',200000),('openai/o3-pro-2025-06-10',200000),('openai/o4-mini',200000),('openai/o4-mini-deep-research',200000),('openai/sora-2',0),('openai/sora-2-pro',0),('openai/text-embedding-3-large',8192),('openai/text-embedding-3-small',8192),('openai/text-embedding-ada-002',8192),('openai/tts-1',0),('openai/tts-1-hd',0),('openai/whisper-1',0),('openai/whisper-large-v3',448),('openai/whisper-large-v3-turbo',448),('openrouter/auto',2000000),('openrouter/free',200000),('openrouter/fusion',1000000),('openrouter/pareto-code',2000000),('orca/orcacyber-minimax-m3.1-flash',261632),('orca/orcacyber-qwen3.8-flash-next',261632),('orca/orcacyber-zero-1.5',999488),('orcarouter/free',65536),('orcarouter/fusion',1000000),('orcarouter/fusion-flash',200000),('orcarouter/fusion-mini',1000000),('ornith-ai/Ornith-1.5-35B-A3B',262144),('ornith-ai/ornith-1.5-122b',262144),('ornith-ai/ornith-1.5-35b-a3b',262144),('ornith-ai/ornith-1.5-35b-a3b:thinking',262144),('osmosis/osmosis-structure-0.6b',4000),('ovhcloud/gpt-oss-120b',131072),('ovhcloud/gpt-oss-20b',131072),('paddlepaddle/paddleocr-vl',16384),('pamanseau/OpenReasoning-Nemotron-32B',32768),('particle-ai/particle-1',1048576),('particle/particle-1',1048576),('perceptron/perceptron-mk1',32768),('perceptron/perceptron-mk1.5',36864),('perplexity/deepseek-v4-pro-0813',1000000),('perplexity/glm-5.3',1000000),('perplexity/glm-5.3-flash',1000000),('perplexity/kimi-k3',1048576),('perplexity/nemotron-3.5-super-120b-a12b',1048576),('perplexity/pplx-embed-v1-0.6b',32000),('perplexity/pplx-embed-v1-4b',32000),('perplexity/sonar',127072),('perplexity/sonar-pro',200000),('perplexity/sonar-pro-search',200000),('perplexityai/sonar',127072),('perplexityai/sonar-pro',200000),('phi-4-reasoning',32000),('phi-4-reasoning-plus',32000),('poetools/claude-code',0),('pokee-isaac',250000),('poolside/laguna-m.1',262144),('poolside/laguna-s-2.1',1000000),('poolside/laguna-xs-2.1',262144),('pqhaz/DeepSeek-V4.1-Flash-1017-heretic',512000),('pqhaz/DeepSeek-V4.1-Flash-1017-heretic:thinking',512000),('prism',1000000),('prism-core',1000000),('prism-ml/ternary-bonsai-2-27b',262144),('prism-ml/ternary-bonsai-2-9b',262144),('public/deepseek-r1',131072),('public/deepseek-v3',131072),('public/minimax-m25',204800),('publicai/apertus-70b-instruct',65536),('publicai/apertus-8b-instruct',65536),('pulse-alpha-free',1048576),('quartz/gemini-3.1-pro-preview',1048576),('quiverai/arrow-2',131072),('quiverai/arrow-2-telos',131072),('qvq-max',131072),('qwen-3-6-plus',1000000),('qwen-3-7-max',1000000),('qwen-3-7-plus',1000000),('qwen-3-8-2-4t-a95b',262144),('qwen-3-8-27b',262144),('qwen-3-8-flash',1000000),('qwen-3-8-max',1000000),('qwen-3.6-plus',1000000),('qwen-3.8-27b',262128),('qwen-3.8-27b-flex',262128),('qwen-deep-research',1000000),('qwen-doc-turbo',131072),('qwen-flash',1000000),('qwen-image',8192),('qwen-image-2.0',8192),('qwen-image-2.0-pro',8192),('qwen-image-2.1',8192),('qwen-long',10000000),('qwen-math-plus',4096),('qwen-math-turbo',4096),('qwen-max',32768),('qwen-mt-plus',16384),('qwen-mt-turbo',16384),('qwen-omni-turbo',32768),('qwen-omni-turbo-realtime',32768)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('qwen-plus',131072),('qwen-plus-character',32768),('qwen-plus-character-ja',8192),('qwen-plus-latest',1000000),('qwen-turbo',1000000),('qwen-vl-max',131072),('qwen-vl-ocr',34096),('qwen-vl-plus',131072),('qwen.qwen3-235b-a22b-2507-v1:0',262144),('qwen.qwen3-32b-v1:0',32768),('qwen.qwen3-coder-30b-a3b-v1:0',262144),('qwen.qwen3-coder-480b-a35b-v1:0',131072),('qwen.qwen3-coder-next',262144),('qwen.qwen3-next-80b-a3b',262144),('qwen.qwen3-vl-235b-a22b',262144),('qwen/deepseek-v4-flash-0731',1000000),('qwen/deepseek-v4-pro-0813',1000000),('qwen/deepseek-v4.1-flash',1000000),('qwen/deepseek-v4.1-flash-1017',1000000),('qwen/qwen-2.5-72b-instruct',32768),('qwen/qwen-2.5-7b-instruct',32768),('qwen/qwen-2.5-7b-vision-instruct',125000),('qwen/qwen-2.5-coder-32b-instruct',32768),('qwen/qwen-flash',1000000),('qwen/qwen-image',0),('qwen/qwen-image-edit',0),('qwen/qwen-max',32768),('qwen/qwen-mt-plus',4096),('qwen/qwen-plus',1000000),('qwen/qwen2.5-coder-32b-instruct',32000),('qwen/qwen3-14b',40960),('qwen/qwen3-235b-a22b',131072),('qwen/qwen3-235b-a22b-2507',262144),('qwen/qwen3-235b-a22b-fp8',40960),('qwen/qwen3-235b-a22b-instruct-2507',131072),('qwen/qwen3-235b-a22b-instruct-2507-maas',262144),('qwen/qwen3-30b-a3b',40960),('qwen/qwen3-30b-a3b-2507',262144),('qwen/qwen3-30b-a3b-fp8',40960),('qwen/qwen3-30b-a3b-instruct-2507',262144),('qwen/qwen3-32b',131072),('qwen/qwen3-32b-fp8',40960),('qwen/qwen3-8b',41000),('qwen/qwen3-coder',262144),('qwen/qwen3-coder-30b',262144),('qwen/qwen3-coder-30b-a3b-instruct',262144),('qwen/qwen3-coder-480b-a35b-instruct',131072),('qwen/qwen3-coder-flash',1000000),('qwen/qwen3-coder-next',262144),('qwen/qwen3-coder-plus',1000000),('qwen/qwen3-embedding-4b',32000),('qwen/qwen3-embedding-8b',32768),('qwen/qwen3-max',256000),('qwen/qwen3-max-preview',256000),('qwen/qwen3-next-80b-a3b-instruct',262144),('qwen/qwen3-next-80b-a3b-thinking',131072),('qwen/qwen3-omni-30b-a3b-thinking',65536),('qwen/qwen3-reranker-8b',32768),('qwen/qwen3-vl-235b-a22b-instruct',262144),('qwen/qwen3-vl-235b-a22b-thinking',131072),('qwen/qwen3-vl-30b-a3b-instruct',262144),('qwen/qwen3-vl-30b-a3b-thinking',262144),('qwen/qwen3-vl-8b-instruct',262144),('qwen/qwen3-vl-flash',262144),('qwen/qwen3-vl-plus',262144),('qwen/qwen3.5-122b-a10b',262144),('qwen/qwen3.5-122b-a10b:thinking',131072),('qwen/qwen3.5-27b',262144),('qwen/qwen3.5-27b:thinking',260096),('qwen/qwen3.5-35b-a3b',262144),('qwen/qwen3.5-35b-a3b:thinking',260096),('qwen/qwen3.5-397b-a17b',262144),('qwen/qwen3.5-397b-a17b:thinking',262144),('qwen/qwen3.5-4b',262144),('qwen/qwen3.5-9b',262144),('qwen/qwen3.5-flash',1000000),('qwen/qwen3.5-flash-02-23',1000000),('qwen/qwen3.5-flash:thinking',991808),('qwen/qwen3.5-omni-flash',49152),('qwen/qwen3.5-omni-plus',983616),('qwen/qwen3.5-plus',1000000),('qwen/qwen3.5-plus-02-15',1000000),('qwen/qwen3.5-plus-20260420',1000000),('qwen/qwen3.5-plus:thinking',983616),('qwen/qwen3.6-27b',262144),('qwen/qwen3.6-27b:thinking',262144),('qwen/qwen3.6-35b-a3b',262144),('qwen/qwen3.6-35b-a3b:thinking',1048576),('qwen/qwen3.6-flash',1000000),('qwen/qwen3.6-max-preview',256000),('qwen/qwen3.6-plus',1000000),('qwen/qwen3.7-flash',1000000),('qwen/qwen3.7-flash:thinking',983616),('qwen/qwen3.7-max',1000000),('qwen/qwen3.7-max:thinking',1000000),('qwen/qwen3.7-plus',1000000),('qwen/qwen3.7-plus:thinking',983616),('qwen/qwen3.8-2.4t-a95b',1048576),('qwen/qwen3.8-27b',1024000),('qwen/qwen3.8-27b-antislop',262144)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('qwen/qwen3.8-27b-cybersecurity',262144),('qwen/qwen3.8-27b-darkidol',262144),('qwen/qwen3.8-27b-fable',524288),('qwen/qwen3.8-27b-fimi',262144),('qwen/qwen3.8-27b-hemmingway',262144),('qwen/qwen3.8-27b-kimiko',262144),('qwen/qwen3.8-27b-kiwen',262144),('qwen/qwen3.8-27b-novelist',262144),('qwen/qwen3.8-27b-queen',524288),('qwen/qwen3.8-27b-swift',262144),('qwen/qwen3.8-27b-synthia',262144),('qwen/qwen3.8-27b-uncensored',1048576),('qwen/qwen3.8-27b-uncensored:thinking',1048576),('qwen/qwen3.8-27b:thinking',1048576),('qwen/qwen3.8-flash',1000000),('qwen/qwen3.8-flash-next',262144),('qwen/qwen3.8-max',1000000),('qwen/qwen3.8-max-0902',1000000),('qwen/qwen3.8-max-preview',1000000),('qwen/qwen3.8-max-prime',1000000),('qwen/qwen3.8-max:thinking',991000),('qwen/qwen3.8-omni-flash',1000000),('qwen/qwenCoder/models/Qwen3-Coder-30B-A3B-Instruct',262144),('qwen/qwenLM/models/Qwen3-30B-A3B-Instruct-2507',262144),('qwen/qwenLM/models/Qwen3-30B-A3B-Thinking-2507',262144),('qwen2-5-omni-7b',32768),('qwen2.5-coder-7b-fast',32000),('qwen2.5-vl-72b-instruct',32768),('qwen3-14b',32768),('qwen3-235b-a22b-instruct-2507',262144),('qwen3-235b-a22b-thinking',262144),('qwen3-235b-a22b-thinking-2507',262144),('qwen3-30b-a3b',32768),('qwen3-30b-a3b-thinking-2507',126000),('qwen3-32b',40960),('qwen3-5-122b-a10b',258048),('qwen3-5-27b',258048),('qwen3-5-35b-a3b',258048),('qwen3-5-397b-a17b',258048),('qwen3-5-4b',262144),('qwen3-5-9b',262144),('qwen3-5-flash',995904),('qwen3-5-plus',983616),('qwen3-6-27b',229376),('qwen3-6-35b',16384),('qwen3-6-35b-a3b',131072),('qwen3-6-flash',983616),('qwen3-6-plus',983616),('qwen3-7-flash',983616),('qwen3-7-max',983616),('qwen3-7-plus',983616),('qwen3-8-27b',262144),('qwen3-8-flash',983616),('qwen3-8-max',983616),('qwen3-8-max-0902',983616),('qwen3-8-omni-flash',1006592),('qwen3-8b',131072),('qwen3-asr-flash',53248),('qwen3-coder',262144),('qwen3-coder-480b-a35b-instruct',262000),('qwen3-coder-480b-a35b-instruct-turbo',256000),('qwen3-coder-flash',997952),('qwen3-coder-next',262144),('qwen3-coder-plus',1000000),('qwen3-coder:30b',262144),('qwen3-embedding-0.6b',8000),('qwen3-embedding-4b',32000),('qwen3-embedding-8b',32768),('qwen3-livetranslate-flash-realtime',53248),('qwen3-max',131072),('qwen3-max-2025-09-23',258048),('qwen3-max-2026-01-23',262144),('qwen3-max-preview',256000),('qwen3-next-80b',256000),('qwen3-next-80b-a3b-instruct',131072),('qwen3-next-80b-a3b-thinking',131072),('qwen3-omni-flash',65536),('qwen3-omni-flash-realtime',65536),('qwen3-reranker-4b',32768),('qwen3-tts-voicedesign',32768),('qwen3-vl-235b-a22b',131072),('qwen3-vl-235b-a22b-instruct',262144),('qwen3-vl-235b-a22b-instruct-original',32768),('qwen3-vl-30b-a3b',131072),('qwen3-vl-30b-a3b-instruct',262144),('qwen3-vl-plus',262144),('qwen3.5-0.8b',32768),('qwen3.5-122b',262144),('qwen3.5-122b-a10b',262144),('qwen3.5-27b',262144),('qwen3.5-2b',32768),('qwen3.5-35b-a3b',262144),('qwen3.5-397b-a17b',262144),('qwen3.5-397b-a17b:free',262144),('qwen3.5-4b',32768),('qwen3.5-9b',262144),('qwen3.5-flash',1000000),('qwen3.5-plus',262144),('qwen3.6',262144),('qwen3.6-27b',16384)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('qwen3.6-35b',256000),('qwen3.6-35b-a3b',262144),('qwen3.6-35b-fast',131056),('qwen3.6-35b-flex',131056),('qwen3.6-flash',983616),('qwen3.6-max-preview',240000),('qwen3.6-plus',262144),('qwen3.6-plus-free',262144),('qwen3.6:27b',262144),('qwen3.7-flash',983616),('qwen3.7-max',1000000),('qwen3.7-max-2026-06-08',1000000),('qwen3.7-plus',1000000),('qwen3.8-2.4T-A95B',262144),('qwen3.8-2.4T-A95B@eu',1000000),('qwen3.8-2.4t-a95b',1010000),('qwen3.8-27b',262144),('qwen3.8-flash',1000000),('qwen3.8-flash-free',1000000),('qwen3.8-flash-next',262144),('qwen3.8-flash-next@eu',262144),('qwen3.8-max',1000000),('qwen3.8-max-free',1000000),('qwen3.8-max-preview',1000000),('qwen3.8-omni-flash',983616),('qwen35-122b-a10b',262144),('qwen35-397b-a17b',262144),('qwen3guard-gen-0.6b',32768),('qwen3guard-gen-8b',32768),('qwq-plus',131072),('ranoai/deepseek-v4-flash',1000000),('recraft/recraft-v2',512),('recraft/recraft-v3',512),('recraft/recraft-v4',0),('recraft/recraft-v4-pro',0),('recraft/recraft-v4.1',0),('recraft/recraft-v4.1-flash',0),('recraft/recraft-v4.1-pro',0),('recraft/recraft-v4.1-utility',0),('recraft/recraft-v4.1-utility-pro',0),('recursive/flint-v1.0:free',262144),('reflection-ai/beam-1.0-501b-a23b',262144),('reflection-beam',1048576),('reflection/Beam-1.0-501B-A23B',1048576),('reflection/beam',1048576),('reflection/beam-1.0',1048576),('reflection/beam-1.0-501b-a23b',1048576),('reflection/beam-free',1048576),('reka-ai/deepseek-v4.1-flash',1048576),('reka-ai/deepseek-v4.1-flash-1017',1048576),('reka-ai/glm-5.3',1048576),('reka-ai/glm-5.3-flash',1048576),('reka-ai/reka-edge-2603',16384),('reka-edge-2603',16384),('reka/reka-edge-2603',16384),('reka/reka-flash-3',65536),('rekaai/reka-edge',16384),('rekaai/reka-flash-3',65536),('relace/relace-apply-3',256000),('relace/relace-search',256000),('ricursiveai/ripple-65b-preview',1048576),('ring-2.6-1t',262144),('ring-2.6-1t-free',262000),('runpod/glm-5.3',262144),('runpod/kimi-k3',1048576),('runpod/kimi-k3.1-pro',1048576),('runpod/kimi-k3.1-pro-highspeed',1048576),('runware/deepseek-v4-flash',1048576),('runware/deepseek-v4-pro',1048576),('runware/deepseek-v4.1-flash',1048576),('runware/deepseek-v4.1-flash-1017',1048576),('runware/gemma-4-31b-it',262144),('runware/glm-5.2',1024000),('runware/glm-5.3',1000000),('runware/glm-5.3-flash',1000000),('runware/kimi-k3',1048576),('runwayml/runway',256),('runwayml/runway-gen-4-turbo',256),('sakana-namazu',262144),('sakana/fugu-max',1000000),('sakana/fugu-ultra',1000000),('sakana/fugu-ultra-v1.1',1000000),('sakana/fugu-ultra-v2',1000000),('sakana/fugu-ultra-v2.0',1000000),('sakana/namazu',256000),('sakana/sakana-namazu',262144),('sao10k/l3-lunaris-8b',8192),('sao10k/l3.1-euryale-70b',131072),('sap-abap-1',32768),('sarvam-105b',131072),('sarvam-30b',65536),('sarvam/sarvam-105b',131072),('scaledown/extract',1000000),('scaledown/scaledown-extract-1',1000000),('scaledown/scaledown-summarize-1',1000000),('scaledown/summarize',1000000),('scaleway/deepseek-v4-flash-0731',256000),('scaleway/deepseek-v4.1-flash',256000),('scaleway/deepseek-v4.1-flash-1017',1000000),('scaleway/gemma-3-27b-it',40000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('scaleway/qwen3-235b-a22b-instruct-2507',250000),('sciforium/deepseek-v4.1-flash-1017',1048576),('scx-ai-gp/deepseek-v4.1-flash',1000000),('scx-ai-gp/glm-5.2',1000000),('scx-ai-gp/glm-5.2-fast',1000000),('scx-ai-gp/glm-5.3',1000000),('scx-ai-gp/glm-5.3-fast',1000000),('scx-ai-gp/glm-5.3-flash',1048576),('scx-ai-gp/kimi-k2.7-code',262144),('scx-ai-gp/kimi-k3',1048576),('scx-ai-gp/qwen3.8-max',1000000),('scx-ai/gpt-oss-120b',131072),('scx-ai/minimax-m2.7',196608),('scx-ai/qwen3-32b',32768),('seed-1-6-250615',256000),('seed-1-6-250915',256000),('seed-1-6-flash-250715',256000),('seed-1-8-251228',256000),('seed-1.8',256000),('seed-2-0-code',229096),('seed-2-0-code-preview-260328',262144),('seed-2-0-lite',229096),('seed-2-0-lite-260428',262144),('seed-2-0-mini',229156),('seed-2-0-mini-260428',262144),('seed-2-0-pro',229096),('seed-2-0-pro-260328',262144),('seed-2-1-turbo',229093),('seed-2.0-code',256000),('seed-2.0-mini',256000),('seed-2.0-pro',256000),('sensenova-6.8-flash-lite',262144),('sference/deepseek-ai/DeepSeek-V4-Flash-0731',1048576),('sference/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('shisa-ai/shisa-v2.1-llama3.3-70b',32768),('sicariussicariistuff/assistant-pepe-32b',40960),('siliconflow/deepseek-r1-0528',163840),('siliconflow/deepseek-v3-0324',163840),('siliconflow/deepseek-v3.1-terminus',163840),('siliconflow/deepseek-v3.2',163840),('solar-mini',32768),('solar-mini4',524288),('solar-pro2',65536),('solar-pro3',131072),('solar-pro4',524288),('sonar',130000),('sonar-pro',200000),('sonar-reasoning',127000),('soob3123/GrayLine-Qwen3-8B',32768),('soob3123/Veiled-Calla-12B',32768),('soob3123/amoral-gemma3-27B-v2',32768),('space-bunny',1048576),('space-bunny-free',1048576),('spacexai/grok-4.20-multi-agent',2000000),('spacexai/grok-4.20-multi-agent-beta',2000000),('spacexai/grok-4.20-non-reasoning',2000000),('spacexai/grok-4.20-non-reasoning-beta',2000000),('spacexai/grok-4.20-reasoning',2000000),('spacexai/grok-4.20-reasoning-beta',2000000),('spacexai/grok-4.3',1000000),('spacexai/grok-4.5',500000),('spacexai/grok-4.6',500000),('spacexai/grok-4.7',500000),('spacexai/grok-build-0.1',256000),('spacexai/grok-imagine-image',16000),('spacexai/grok-imagine-image-2.0',64000),('spacexai/grok-imagine-video',0),('spacexai/grok-imagine-video-1.5',1024),('spacexai/grok-imagine-video-1.5-lite',1024),('spacexai/grok-stt',0),('spacexai/grok-tts',15000),('speakleash/Bielik-11B-v3.0-Instruct',32000),('speakleash/bielik-11b-v3.0-instruct',32768),('stabilityai/stablediffusionxl',200),('stable-diffusion-3.5-large',256),('standardcompute',1000000),('stealth/crouton-alpha',1048576),('stealth/glyph-cluster',256000),('step-3-5-flash',262144),('step-3-5-flash-2603',262144),('step-3-7-flash',262144),('step-3-7-flash:free',256000),('step-3.5-flash',256000),('step-3.5-flash-2603',256000),('step-3.7-flash',262144),('step-3.7-flash:free',256000),('step-5-preview',1000000),('step-5-preview-free',1000000),('step-router-v1',256000),('step-tts-2',0),('stepaudio-2.5-asr',0),('stepaudio-2.5-tts',0),('stepfun-ai/Step-3.5-Flash',262000),('stepfun-ai/Step-3.7-Flash',262144),('stepfun-ai/Step-5-Preview',1048576),('stepfun-ai/gelab-zero-4b-preview',8192),('stepfun-ai/step-3.5-flash',262144),('stepfun-ai/step-3.5-flash-2603',262144),('stepfun-ai/step-5-preview',1048576),('stepfun/Step-3.5-Flash',256000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('stepfun/Step-3.7-Flash',256000),('stepfun/Step-5-Preview',1000000),('stepfun/step-3.5-flash',262144),('stepfun/step-3.7-flash',262144),('stepfun/step-3.7-flash:thinking',262144),('stepfun/step-5-preview',1048576),('subconscious/deepseek-v4.1-flash-marathon',5000000),('subconscious/glm-5.3-marathon',5000000),('swiss-ai/Apertus-v1.5-70B',100000),('synth-2.5-flash',30000),('synth-2.5-pro',30000),('tc-code-latest',131072),('tencent/Hunyuan-A13B-Instruct',131000),('tencent/Hy3',262144),('tencent/Hy4',0),('tencent/Hy4-preview',1000000),('tencent/deepseek-v4-flash',1000000),('tencent/deepseek-v4-pro',1000000),('tencent/deepseek-v4-pro-0813',1000000),('tencent/deepseek-v4.1-flash',1000000),('tencent/deepseek-v4.1-flash-1017',1000000),('tencent/glm-5',200000),('tencent/glm-5-turbo',200000),('tencent/glm-5.1',200000),('tencent/glm-5.2',1000000),('tencent/glm-5.3',1000000),('tencent/glm-5.3-flash',1000000),('tencent/glm-5.3-flashx',1000000),('tencent/glm-5v-turbo',200000),('tencent/hunyuan-a13b-instruct',131072),('tencent/hy-mt2-1.8b',8192),('tencent/hy-mt2-30b-a3b',8192),('tencent/hy-mt2-7b',8192),('tencent/hy-mt2-lite',8000),('tencent/hy-mt2-plus',8192),('tencent/hy-mt2-pro',8000),('tencent/hy3',262144),('tencent/hy3-free',256000),('tencent/hy3-paid',256000),('tencent/hy3-preview',262144),('tencent/hy4',1048576),('tencent/hy4-preview',1048576),('tencent/kimi-k2.6',262144),('tencent/kimi-k2.7-code',262144),('tencent/kimi-k2.7-code-highspeed',262144),('tencent/kimi-k2.8-preview',1000000),('tencent/kimi-k3',1048576),('tencent/mimo-v2.6-flash',1000000),('tencent/mimo-v2.6-pro',1000000),('tencent/minimax-m2.7',200000),('tencent/minimax-m3',1000000),('tencent/step-5-preview',1000000),('tensorx/deepseek/deepseek-r1-0528',164000),('tensorx/deepseek/deepseek-v4-flash-0731',1048576),('tensorx/deepseek/deepseek-v4-pro-0813',1048576),('tensorx/deepseek/deepseek-v4.1-flash',1048576),('tensorx/deepseek/deepseek-v4.1-flash-1017',1048576),('tensorx/moonshotai/kimi-k2.5',262144),('text-embedding-3-large',8191),('text-embedding-3-small',8191),('text-embedding-ada-002',8192),('text-max',1000000),('text-prime',196608),('thedrummer/cydonia-24b-v4.1',131072),('thedrummer/skyfall-36b-v2',32768),('thedrummer/unslopnemo-12b',1024000),('thinkingmachines/Inkling',1048576),('thinkingmachines/Inkling-NVFP4',1048576),('thinkingmachines/Inkling-Small',524288),('thinkingmachines/Inkling-Small:peft:262144',262144),('thinkingmachines/Inkling-Small:peft:262144:sampling-nvfp4',262144),('thinkingmachines/Inkling-Small:thinking',524288),('thinkingmachines/Inkling:peft:262144',262144),('thinkingmachines/Inkling:peft:262144:sampling-nvfp4',262144),('thinkingmachines/inkling',524288),('thinkingmachines/inkling-small',524288),('thinkingmachines/inkling:thinking',1040000),('tiny-aya-earth',8000),('tiny-aya-fire',8000),('tiny-aya-global',8000),('tiny-aya-water',8000),('together-ai/deepseek-v4-pro',1048576),('together-ai/deepseek-v4.1-flash',1048576),('together-ai/deepseek-v4.1-flash-1017',1048576),('together-ai/glm-4.7',202752),('together-ai/glm-5.3',1048576),('together-ai/glm-5.3-flash',1048576),('together-ai/gpt-oss-120b',131072),('together-ai/kimi-k3',1000000),('together-ai/minimax-m3',524288),('together-ai/minimax-m3.1-flash',1048576),('together-ai/muse-glimmer-30b',131072),('together_ai/deepseek-ai/DeepSeek-V4-Pro-0813',1048576),('together_ai/deepseek-ai/DeepSeek-V4.1-Flash',1048576),('together_ai/deepseek-ai/DeepSeek-V4.1-Flash-1017',1048576),('together_ai/meta-models/Muse-Glimmer-30B',131072),('together_ai/openai/gpt-oss-120b',131072),('together_ai/reflection/Beam-1.0-501B-A23B',1048576),('together_ai/thinkingmachines/Inkling',524288),('tongyi-intent-detect-v3',8192)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('topaz/proteus',0),('topaz/starlight-precise-2.6',0),('topaz/wonder-3.5',0),('topazlabs-co/topazlabs',204),('trendyol-asure-12b',40960),('trinity-large-preview-free',131072),('trinity-large-thinking',262144),('trustedrouter/auto',1000000),('trustedrouter/cheap',1000000),('trustedrouter/e2e',1000000),('trustedrouter/fast',1000000),('trustedrouter/synth',1000000),('trustedrouter/synth-code',1000000),('trustedrouter/zdr',1000000),('trytako/tako',2048),('umans-coder',1048576),('umans-deepseek-v4-flash-0731',1048576),('umans-deepseek-v4.1-flash',1048576),('umans-deepseek-v4.1-flash-1017',1048576),('umans-flash',262144),('umans-glm-5.3',1048576),('umans-glm-5.3-flash',1048576),('umans-kimi-k3',1048576),('umans-qwen3.6-35b-a3b',262144),('unbiased/pareto',262144),('unbiased/pareto-26.10',1048576),('unbiased/pareto-26.9',262144),('undi95/remm-slerp-l2-13b',6144),('universal-summarizer',32768),('unsloth/gemma-3-12b-it',131072),('unsloth/qwen3.8-27b-gguf',101072),('upstage/solar-mini4',524288),('upstage/solar-mini4:thinking',524288),('upstage/solar-pro-3',131072),('upstage/solar-pro2',65536),('upstage/solar-pro3',131072),('upstage/solar-pro4',524288),('upstage/solar-pro4:thinking',524288),('us.amazon.nova-2-lite-v1:0',1000000),('us.amazon.nova-lite-v1:0',300000),('us.amazon.nova-premier-v1:0',1000000),('us.amazon.nova-pro-v1:0',300000),('us.anthropic.claude-fable-5',1000000),('us.anthropic.claude-fable-5-1',1000000),('us.anthropic.claude-haiku-4-5-20251001-v1:0',200000),('us.anthropic.claude-haiku-5-5',1000000),('us.anthropic.claude-opus-4-1-20250805-v1:0',200000),('us.anthropic.claude-opus-4-5-20251101-v1:0',200000),('us.anthropic.claude-opus-4-6-v1',1000000),('us.anthropic.claude-opus-4-7',1000000),('us.anthropic.claude-opus-4-8',1000000),('us.anthropic.claude-opus-5',1000000),('us.anthropic.claude-opus-5-5',1000000),('us.anthropic.claude-sonnet-4-20250514-v1:0',200000),('us.anthropic.claude-sonnet-4-5-20250929-v1:0',200000),('us.anthropic.claude-sonnet-4-6',1000000),('us.anthropic.claude-sonnet-5',1000000),('us.anthropic.claude-sonnet-5-5',1000000),('us.meta.llama4-maverick-17b-instruct-v1:0',1000000),('us.meta.llama4-scout-17b-instruct-v1:0',10000000),('us.moonshotai.kimi-k3',1048576),('us.openai.gpt-5.6-luna',1050000),('us.openai.gpt-5.6-sol',1050000),('us.openai.gpt-5.6-terra',1050000),('us.openai.gpt-6-astra',1050000),('us.openai.gpt-6-luna',1050000),('us.openai.gpt-6-sol',1050000),('us.openai.gpt-6.1-sol',1050000),('us.openai.gpt-6.1-terra',1050000),('us.writer.palmyra-x4-v1:0',122880),('us.writer.palmyra-x5-v1:0',1040000),('us.xai.grok-4.6',500000),('us.xai.grok-4.7',500000),('us.zai.glm-5.3',1000000),('vertex-anthropic/claude-haiku-4-5',200000),('vertex-anthropic/claude-opus-4-5-20251101',200000),('vertex-anthropic/claude-opus-4-6',1000000),('vertex-anthropic/claude-opus-4-7',1000000),('vertex-anthropic/claude-sonnet-4-5',200000),('vertex-anthropic/claude-sonnet-4-6',1000000),('vertex-anthropic/claude-sonnet-5',1000000),('vertex-openai/grok-4-20-non-reasoning',2000000),('vertex-openai/grok-4-20-reasoning',2000000),('vertex-openai/grok-4-6',500000),('vertex-openai/grok-4-7',524288),('vertex/gemini-2.5-flash-image',32768),('vertex/gemini-3-flash-preview',1048576),('vertex/gemini-3-pro-image',65536),('vertex/gemini-3.1-flash-image',131072),('vertex/gemini-3.1-flash-lite',1048576),('vertex/gemini-3.1-flash-lite-image',65536),('vertex/gemini-3.1-flash-lite@eu',1048576),('vertex/gemini-3.1-flash-lite@us',1048576),('vertex/gemini-3.1-pro-preview',1048576),('vertex/gemini-3.5-flash',1048576),('vertex/gemini-3.5-flash-lite',1048576),('vertex/gemini-3.5-flash-lite@eu',1048576),('vertex/gemini-3.5-flash-lite@us',1048576),('vertex/gemini-3.5-flash@eu',1048576),('vertex/gemini-3.5-flash@us',1048576)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('vertex/gemini-3.6-flash',1048576),('vertex/gemini-3.6-flash@eu',1048576),('vertex/gemini-3.6-flash@us',1048576),('vertex/gemini-3.7-flash',1048576),('vertex/gemini-3.7-flash@eu',1048576),('vertex/gemini-3.7-flash@us',1048576),('vertex/gemini-3.8-flash',1048576),('vertex/gemini-3.8-flash@eu',1048576),('vertex/gemini-3.8-flash@us',1048576),('vertex/gemini-4-argon',1048576),('vertex/gemini-4-argon@eu',1048576),('vertex/gemini-4-argon@us',1048576),('vertex/gemini-flash-latest',1048576),('vertex/gemini-nano-banana-2.1',131072),('vertex/gemini-pro-latest',1048576),('vispark/vision-large',1000000),('vispark/vision-medium',1000000),('vispark/vision-small',1000000),('viv-fast',1000000),('volcengine/doubao-seed-1.8',256000),('volcengine/doubao-seed-2.0-code',256000),('volcengine/doubao-seed-2.0-lite',256000),('volcengine/doubao-seed-2.0-mini',256000),('volcengine/doubao-seed-2.0-pro',256000),('volcengine/doubao-seed-2.1-pro',256000),('volcengine/doubao-seed-2.1-turbo',256000),('volcengine/doubao-seed-character',256000),('volcengine/doubao-seed-code',256000),('volcengine/doubao-seed-evolving',256000),('voxtral-mini-3b',32000),('voxtral-mini-latest',0),('voxtral-mini-tts-latest',0),('voxtral-small-24b-2507',32768),('voxtral-small-2507',32000),('voxtral-small-latest',32768),('voyage/rerank-2.5',32000),('voyage/rerank-2.5-lite',32000),('voyage/rerank-3',32000),('voyage/rerank-3-lite',32000),('voyage/voyage-3-large',32000),('voyage/voyage-3.5',32000),('voyage/voyage-3.5-lite',32000),('voyage/voyage-4',32000),('voyage/voyage-4-large',32000),('voyage/voyage-4-lite',32000),('voyage/voyage-code-2',16000),('voyage/voyage-code-3',32000),('voyage/voyage-finance-2',32000),('voyage/voyage-law-2',16000),('wan2-2-t2v-a14b',100),('wan2.7-image',8192),('wan2.7-image-pro',8192),('wanx/wan-v2-6',400000),('whisper-large-v3',448),('whisper-large-v3-turbo',448),('writer.palmyra-x4-v1:0',122880),('writer.palmyra-x5-v1:0',1040000),('writer/palmyra-x5',1040000),('x-ai/grok-4',256000),('x-ai/grok-4-20-0309-non-reasoning',2000000),('x-ai/grok-4-fast',2000000),('x-ai/grok-4-fast-non-reasoning',2000000),('x-ai/grok-4-fast-reasoning',2000000),('x-ai/grok-4.1-fast',2000000),('x-ai/grok-4.1-fast-non-reasoning',2000000),('x-ai/grok-4.1-fast-reasoning',20000000),('x-ai/grok-4.2-fast',2000000),('x-ai/grok-4.2-fast-non-reasoning',2000000),('x-ai/grok-4.20',2000000),('x-ai/grok-4.20-multi-agent',2000000),('x-ai/grok-4.3',1000000),('x-ai/grok-4.5',500000),('x-ai/grok-4.6',500000),('x-ai/grok-4.7',500000),('x-ai/grok-build-0.1',256000),('x-ai/grok-code-fast-1',256000),('x-ai/grok-imagine-image-2.0',66000),('x-ai/grok-latest',500000),('x-ai/grok-voice-stt-1.0',15000),('x-ai/grok-voice-tts-1.0',15000),('x-preview-f-free',1000000),('xai.grok-4.20-non-reasoning',1000000),('xai.grok-4.20-reasoning',1000000),('xai.grok-4.3',1000000),('xai.grok-4.6',500000),('xai/grok-3',131072),('xai/grok-3-mini',131072),('xai/grok-4',256000),('xai/grok-4-1-fast-non-reasoning',2000000),('xai/grok-4-20-beta-0309-non-reasoning',2000000),('xai/grok-4-20-beta-0309-reasoning',2000000),('xai/grok-4-3',1000000),('xai/grok-4-5',500000),('xai/grok-4-6',500000),('xai/grok-4-7',500000),('xai/grok-4-fast-non-reasoning',2000000),('xai/grok-4-fast-reasoning',2000000),('xai/grok-4.20-0309-non-reasoning',2000000),('xai/grok-4.20-0309-reasoning',2000000),('xai/grok-4.20-non-reasoning',2000000)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('xai/grok-4.20-reasoning',2000000),('xai/grok-4.3',1000000),('xai/grok-4.5',500000),('xai/grok-4.6',500000),('xai/grok-4.7',500000),('xai/grok-build-0-1',256000),('xai/grok-build-0.1',256000),('xai/grok-code-fast-1',256000),('xai/grok-latest',500000),('xiaomi-mimo-v2-5',1000000),('xiaomi-mimo-v2-6-flash',1000000),('xiaomi-mimo-v2.5',1048576),('xiaomi-mimo-v2.5-free',1048576),('xiaomi-mimo-v2.5-pro',1048576),('xiaomi-mimo-v2.5-pro-free',1048576),('xiaomi-mimo/mimo-v2.6-flash',1048576),('xiaomi-mimo/mimo-v2.6-pro',1048576),('xiaomi-mimo/mimo-v2.6-pro-ultraspeed',1048576),('xiaomi/mimo-v2.5',1000000),('xiaomi/mimo-v2.5-pro',1050000),('xiaomi/mimo-v2.5-pro:thinking',1048576),('xiaomi/mimo-v2.5:thinking',1048576),('xiaomi/mimo-v2.6-flash',1050000),('xiaomi/mimo-v2.6-flash-abliterated',1048576),('xiaomi/mimo-v2.6-flash-uncensored',1048576),('xiaomi/mimo-v2.6-flash-uncensored:thinking',1048576),('xiaomi/mimo-v2.6-pro',1050000),('xiaomi/mimo-v2.6-pro-ultraspeed',1048576),('xiaomimimo/mimo-v2-flash',262144),('xiaomimimo/mimo-v2.5',1048576),('xiaomimimo/mimo-v2.5-pro',1048576),('xiaomimimo/mimo-v2.6-flash',1048576),('xiaomimimo/mimo-v2.6-pro',1048576),('xingchen-agi/xing4.0-29b-a4b',262144),('xingchen-agi/xing4.0-29b-a4b:free',262144),('xpersona-frieren-coder',1000000),('xpersona-gpt-5.5',1000000),('z-ai-glm-5-3',1000000),('z-ai-glm-5-3-flash',1048576),('z-ai-glm-5-turbo',200000),('z-ai-glm-5v-turbo',200000),('z-ai/GLM-4.6-turbo',204800),('z-ai/GLM-4.6-turbo:thinking',204800),('z-ai/autoglm-phone-9b',12800),('z-ai/glm-4.5',131072),('z-ai/glm-4.5-air',131072),('z-ai/glm-4.5v',65536),('z-ai/glm-4.5v:thinking',65536),('z-ai/glm-4.6',204800),('z-ai/glm-4.6-original',256000),('z-ai/glm-4.6:thinking',200000),('z-ai/glm-4.6v',131072),('z-ai/glm-4.6v-flash',200000),('z-ai/glm-4.6v-flash-free',200000),('z-ai/glm-4.7',204800),('z-ai/glm-4.7-flash',200000),('z-ai/glm-4.7-flash-free',200000),('z-ai/glm-4.7-flash:thinking',200000),('z-ai/glm-4.7-flashx',200000),('z-ai/glm-4.7-original',200000),('z-ai/glm-4.7-original:thinking',200000),('z-ai/glm-4.7:thinking',200000),('z-ai/glm-5',204800),('z-ai/glm-5-original',200000),('z-ai/glm-5-original:thinking',200000),('z-ai/glm-5-turbo',202752),('z-ai/glm-5.1',204800),('z-ai/glm-5.1:thinking',200000),('z-ai/glm-5.2',1048576),('z-ai/glm-5.2:thinking',1048576),('z-ai/glm-5.3',1048576),('z-ai/glm-5.3-flash',1048576),('z-ai/glm-5.3-flash-apex',1048576),('z-ai/glm-5.3-flash-apex-abliterated',1048576),('z-ai/glm-5.3-flash-cybersecurity',1048576),('z-ai/glm-5.3-flash-free',1000000),('z-ai/glm-5.3-flash-uncensored',1048576),('z-ai/glm-5.3-flashx',1048576),('z-ai/glm-5.3-flashx-legal',1048576),('z-ai/glm-5.3-free',1000000),('z-ai/glm-5.3-prime',1000000),('z-ai/glm-5.3-uncensored',1048576),('z-ai/glm-5.3:thinking',1048576),('z-ai/glm-5:thinking',200000),('z-ai/glm-5v-turbo',202752),('z-ai/glm-5v-turbo:thinking',202800),('z-ai/glm-image',10240),('z-ai/glm-latest',1048576),('zai-glm-5-1',198000),('zai-glm-5-2',1048576),('zai-glm-5-3',1048576),('zai-glm-5-3-flash',1048576),('zai-glm-5.1',200000),('zai-org-glm-4.6',198000),('zai-org-glm-4.7',198000),('zai-org-glm-5',198000),('zai-org-glm-5-1',200000),('zai-org-glm-5-2',1000000),('zai-org/AutoGLM-Phone-9B-Multilingual',65536),('zai-org/GLM-4.5',131072)",
            "INSERT INTO operation_window_backfill(model_id,context_window) VALUES('zai-org/GLM-4.5-Air',131000),('zai-org/GLM-4.5-FP8',131072),('zai-org/GLM-4.5V',65536),('zai-org/GLM-4.6',200000),('zai-org/GLM-4.6V-Flash',131072),('zai-org/GLM-4.7',204800),('zai-org/GLM-4.7-Flash',200000),('zai-org/GLM-5',205000),('zai-org/GLM-5-FP8',202752),('zai-org/GLM-5.1',205000),('zai-org/GLM-5.1-FP8',202752),('zai-org/GLM-5.1-TEE',202752),('zai-org/GLM-5.2',1048576),('zai-org/GLM-5.2-FP8',1000000),('zai-org/GLM-5.2-Fast',1000000),('zai-org/GLM-5.2-TEE',1048576),('zai-org/GLM-5.3',1048576),('zai-org/GLM-5.3-Fast',1048576),('zai-org/GLM-5.3-Flash',1048576),('zai-org/GLM-5.3-Flash:peft:262144',262144),('zai-org/GLM-5.3:peft:262144',262144),('zai-org/GLM-5V-Turbo',200000),('zai-org/autoglm-phone-9b-multilingual',65536),('zai-org/glm-4.5',131072),('zai-org/glm-4.5-air',131072),('zai-org/glm-4.5v',65536),('zai-org/glm-4.6',204800),('zai-org/glm-4.6v',131072),('zai-org/glm-4.7',204800),('zai-org/glm-4.7-flash',200000),('zai-org/glm-4.7-maas',200000),('zai-org/glm-5',202800),('zai-org/glm-5-maas',200000),('zai-org/glm-5.1',202000),('zai-org/glm-5.2',1048576),('zai-org/glm-5.2-maas',1000000),('zai-org/glm-5.3',1048576),('zai-org/glm-5.3-flash',1048550),('zai.glm-4.7',202752),('zai.glm-4.7-flash',202752),('zai.glm-5',202752),('zai/GLM-5.1',200000),('zai/GLM-5.2',1000000),('zai/glm-4.5-flash',131072),('zai/glm-4.6',200000),('zai/glm-4.7',200000),('zai/glm-4.7-flash',200000),('zai/glm-4.7-flashx',200000),('zai/glm-5',202800),('zai/glm-5-turbo',202800),('zai/glm-5.1',200000),('zai/glm-5.2',1000000),('zai/glm-5.2-fast',1000000),('zai/glm-5.3',1000000),('zai/glm-5.3-fast',1048576),('zai/glm-5.3-flash',1048576),('zai/glm-5.3-flashx',1000000),('zai/glm-5.3-flashx-legal',1000000),('zai/glm-5v-turbo',200000),('zdev',1000000),('zhipu/glm-5.2',1000000),('zhipu/glm-5.3',1024000),('~anthropic/claude-fable-latest',1000000),('~anthropic/claude-haiku-latest',1000000),('~anthropic/claude-opus-latest',1000000),('~anthropic/claude-sonnet-latest',1000000),('~deepseek/deepseek-flash-latest',1048576),('~deepseek/deepseek-pro-latest',1048576),('~deepseek/deepseek-v4-flash-latest',1048576),('~google/gemini-flash-latest',1048576),('~google/gemini-pro-latest',1048576),('~moonshotai/kimi-latest',1048576),('~openai/gpt-astra-latest',1050000),('~openai/gpt-luna-latest',1050000),('~openai/gpt-mini-latest',400000),('~openai/gpt-sol-latest',1050000),('~openai/gpt-terra-latest',1050000),('~unbiased/pareto-latest',1048576),('~x-ai/grok-latest',500000),('~z-ai/glm-flash-latest',1048576),('~z-ai/glm-latest',1048576)",
            "ALTER TABLE model_operation ADD COLUMN context_window BIGINT NULL AFTER first_event_ms",
            "UPDATE model_operation o JOIN session_revision r ON r.session_ref=o.session_ref AND r.revision=o.settings_revision LEFT JOIN operation_window_backfill pinned ON pinned.model_id=r.model SET o.context_window=coalesce(pinned.context_window,128000)",
            "ALTER TABLE model_operation MODIFY COLUMN context_window BIGINT NOT NULL, ADD CHECK(context_window BETWEEN 0 AND 4294967295)",
            "DROP TEMPORARY TABLE operation_window_backfill",
        },
    },
    .{
        .from = 69,
        .sqlite = &.{
            "UPDATE store_meta SET meta_value='14' WHERE meta_key='wire_version' AND meta_value='13'",
        },
        .mysql = &.{
            "UPDATE store_meta SET meta_value='14' WHERE meta_key='wire_version' AND meta_value='13'",
        },
    },
    .{
        .from = 70,
        .sqlite = &.{
            "UPDATE store_meta SET meta_value='15' WHERE meta_key='wire_version' AND meta_value='14'",
        },
        .mysql = &.{
            "UPDATE store_meta SET meta_value='15' WHERE meta_key='wire_version' AND meta_value='14'",
        },
    },
    .{
        .from = 71,
        .sqlite = &.{
            "UPDATE store_meta SET meta_value='16' WHERE meta_key='wire_version' AND meta_value='15'",
        },
        .mysql = &.{
            "UPDATE store_meta SET meta_value='16' WHERE meta_key='wire_version' AND meta_value='15'",
        },
    },
    // D239: the nullable fact and its live index are the durable frontier.
    .{
        .from = 72,
        .sqlite = &.{
            "ALTER TABLE session ADD COLUMN obligation_since INTEGER CHECK(obligation_since IS NULL OR obligation_since>0)",
            "CREATE INDEX session_obligation_parent ON session(parent_ref,obligation_since,session_ref) WHERE obligation_since IS NOT NULL",
            "CREATE INDEX session_forward_owed_message ON session_forward(target_ref,message_delivered)",
            "WITH RECURSIVE own_owed(session_ref,since) AS (SELECT t.session_ref,m.admitted_at AS since FROM turn t JOIN message_admission m ON m.admission_id=t.first_admission_id WHERE t.outcome_code IS NULL UNION SELECT m.session_ref,m.admitted_at FROM message_admission m WHERE m.turn_id IS NULL AND m.admission_id>coalesce((SELECT admission_cutoff FROM session_stop WHERE session_ref=m.session_ref ORDER BY admission_cutoff DESC LIMIT 1),0) UNION SELECT f.target_ref,m.admitted_at FROM session_forward f LEFT JOIN action_operation a ON f.kind=1 AND a.action_id=f.source_id LEFT JOIN model_operation op ON op.operation_id=a.parent_operation_id JOIN turn t ON t.turn_id=CASE WHEN f.kind=2 THEN f.source_id ELSE op.turn_id END JOIN message_admission m ON m.admission_id=t.first_admission_id WHERE f.position IS NULL OR f.message_delivered=0),owed(session_ref,since) AS (SELECT session_ref,since FROM own_owed UNION SELECT s.parent_ref,o.since FROM owed o JOIN session s ON s.session_ref=o.session_ref WHERE s.parent_ref IS NOT NULL) UPDATE session SET obligation_since=(SELECT min(o.since) FROM owed o WHERE o.session_ref=session.session_ref)",
        },
        .mysql = &.{
            "ALTER TABLE session ADD COLUMN obligation_since BIGINT CHECK(obligation_since IS NULL OR obligation_since>0) AFTER parent_ref",
            "ALTER TABLE session ADD COLUMN session_obligation_parent_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN obligation_since IS NOT NULL THEN parent_ref END) STORED AFTER obligation_since, ADD INDEX session_obligation_parent(session_obligation_parent_lead,obligation_since,session_ref)",
            "CREATE INDEX session_forward_owed_message ON session_forward(target_ref,message_delivered)",
            "WITH RECURSIVE own_owed(session_ref,since) AS (SELECT t.session_ref,m.admitted_at AS since FROM turn t JOIN message_admission m ON m.admission_id=t.first_admission_id WHERE t.outcome_code IS NULL UNION SELECT m.session_ref,m.admitted_at FROM message_admission m WHERE m.turn_id IS NULL AND m.admission_id>coalesce((SELECT admission_cutoff FROM session_stop WHERE session_ref=m.session_ref ORDER BY admission_cutoff DESC LIMIT 1),0) UNION SELECT f.target_ref,m.admitted_at FROM session_forward f LEFT JOIN action_operation a ON f.kind=1 AND a.action_id=f.source_id LEFT JOIN model_operation op ON op.operation_id=a.parent_operation_id JOIN turn t ON t.turn_id=CASE WHEN f.kind=2 THEN f.source_id ELSE op.turn_id END JOIN message_admission m ON m.admission_id=t.first_admission_id WHERE f.position IS NULL OR f.message_delivered=0),owed(session_ref,since) AS (SELECT session_ref,since FROM own_owed UNION SELECT s.parent_ref,o.since FROM owed o JOIN session s ON s.session_ref=o.session_ref WHERE s.parent_ref IS NOT NULL) UPDATE session s JOIN (SELECT session_ref,min(since) AS since FROM owed GROUP BY session_ref) o ON o.session_ref=s.session_ref SET s.obligation_since=o.since",
        },
    },
    .{
        .from = 73,
        .sqlite = &.{
            "UPDATE store_meta SET meta_value='17' WHERE meta_key='wire_version' AND meta_value='16'",
        },
        .mysql = &.{
            "UPDATE store_meta SET meta_value='17' WHERE meta_key='wire_version' AND meta_value='16'",
        },
    },
};

comptime {
    if (schema_version < migration_baseline) @compileError("schema_version is below migration_baseline");
    for (migrations, 0..) |step, position| {
        const expected = migration_baseline + position;
        if (step.from != expected) @compileError(std.fmt.comptimePrint(
            "migrations: step {d} moves from {d}; the step after {d} must move from {d}",
            .{ position, step.from, expected -| 1, expected },
        ));
        if (step.from >= schema_version) @compileError(std.fmt.comptimePrint(
            "migrations: the step from {d} moves past schema_version {d}: set schema_version to {d} and append its bootstrap_digests row, or drop the step",
            .{ step.from, schema_version, step.from + 1 },
        ));
    }
    if (migrations.len < schema_version - migration_baseline) @compileError(std.fmt.comptimePrint(
        "migrations: schema_version is {d}, and no step moves a Store from {d}: append .{{ .from = {d}, .sqlite = ..., .mysql = ... }}",
        .{ schema_version, migration_baseline + migrations.len, migration_baseline + migrations.len },
    ));
}

/// The statements of the step from `from`, as one text for the DB team to
/// run on a MySQL Store at `from`; `ddl(.mysql)` is a new MySQL Store's.
/// `rui store schema --engine mysql --from N` prints the remaining steps. Rui takes
/// no backup of a MySQL Store: backing it up before applying the text is the
/// DB team's job.
pub fn mysqlMigration(comptime from: u32) [:0]const u8 {
    return comptime blk: {
        if (from < migration_baseline or from - migration_baseline >= migrations.len)
            @compileError(std.fmt.comptimePrint("migrations: no step moves a Store from {d}", .{from}));
        var text: []const u8 = "";
        for (migrations[from - migration_baseline].mysql) |statement| text = text ++ statement ++ ";\n";
        const terminated = text ++ "\x00";
        break :blk terminated[0..text.len :0];
    };
}

/// All forward steps from a runtime-selected format, oldest first, without
/// allocation. After the steps, finalize format and wire metadata once, as
/// opening the migrated Store requires both to match this build. The current
/// format needs no SQL; unsupported formats have no text.
pub fn mysqlMigrationFrom(from: u64) ?[:0]const u8 {
    const texts = comptime blk: {
        var result: [schema_version - migration_baseline + 1][:0]const u8 = undefined;
        result[result.len - 1] = "";
        const metadata = "UPDATE store_meta SET meta_value='" ++ format_text ++ "' WHERE meta_key='format';\n" ++
            "UPDATE store_meta SET meta_value='" ++ wire_version ++ "' WHERE meta_key='wire_version';\n";
        var index = result.len - 1;
        while (index > 0) {
            index -= 1;
            const text = mysqlMigration(migration_baseline + index) ++
                (if (index + 1 == result.len - 1) metadata else result[index + 1]);
            const terminated = text ++ "\x00";
            result[index] = terminated[0..text.len :0];
        }
        break :blk result;
    };
    if (from < migration_baseline or from > schema_version) return null;
    return texts[@intCast(from - migration_baseline)];
}

test "store schema --from prints every remaining MySQL migration then finalizes metadata once" {
    for (migration_baseline..schema_version + 1) |from| {
        var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer expected.deinit();
        inline for (migrations) |step| {
            if (step.from >= from) try expected.writer.writeAll(mysqlMigration(step.from));
        }
        if (from < schema_version) try expected.writer.print(
            "UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format';\nUPDATE store_meta SET meta_value='{s}' WHERE meta_key='wire_version';\n",
            .{ schema_version, wire_version },
        );
        try std.testing.expectEqualStrings(expected.written(), mysqlMigrationFrom(@intCast(from)).?);
    }
    try std.testing.expectEqualStrings("", mysqlMigrationFrom(schema_version).?);
    try std.testing.expect(mysqlMigrationFrom(migration_baseline - 1) == null);
    try std.testing.expect(mysqlMigrationFrom(schema_version + 1) == null);
    try std.testing.expect(mysqlMigrationFrom(std.math.maxInt(u64)) == null);
}

/// SQL membership of `column` in a closed set of enum tags or text literals:
/// IN up to two values, else an OR of equalities, because SQLite builds a
/// temporary b-tree for an IN list of more than two each time the statement
/// runs.
pub inline fn oneOf(comptime column: []const u8, comptime set: anytype) []const u8 {
    return comptime blk: {
        var names: []const []const u8 = &.{};
        for (set) |value| names = names ++ .{if (@TypeOf(value) == []const u8) value else @tagName(value)};
        var sql: []const u8 = "";
        if (names.len <= 2) {
            for (names, 0..) |name, index| sql = sql ++ (if (index == 0) "" else ",") ++ "'" ++ name ++ "'";
            break :blk column ++ " IN (" ++ sql ++ ")";
        }
        for (names, 0..) |name, index| sql = sql ++ (if (index == 0) "" else " OR ") ++ column ++ "='" ++ name ++ "'";
        break :blk "(" ++ sql ++ ")";
    };
}

/// The Resolutions whose output later context reads, as fixed literals: the
/// `model_operation_context_history` predicate and every query that must
/// repeat it term for term share this set, so the Store format never follows
/// `turn_policy.accepted` silently.
pub const accepted_resolutions = [_]turn_policy.Resolution{ .answer, .compacted, .tool_proposals };
comptime {
    if (!std.mem.eql(turn_policy.Resolution, &accepted_resolutions, &turn_policy.accepted))
        @compileError("turn_policy.accepted changed: change accepted_resolutions and bootstrap_digests' last row");
}

pub inline fn resolutionIs(comptime column: []const u8, comptime resolution: turn_policy.Resolution) []const u8 {
    return column ++ "='" ++ @tagName(resolution) ++ "'";
}

/// Byte bounds of a text or bytes column.
pub const Octets = struct { min: u32 = 0, max: u32 };

pub const ColumnType = union(enum) {
    /// 64-bit integer; range checks beyond that are the column's `check`.
    int,
    /// 0 or 1, never a boolean type, so `c=1` reads the same on every engine.
    flag,
    /// UTF-8 text with a CHECK on its bytes, or null for unchecked text.
    text: ?Octets,
    /// Bytes with a CHECK on their length, or null for unchecked bytes.
    bytes: ?Octets,
    /// A closed set of literal text. The format never follows a Zig enum
    /// silently: changing a set changes the format.
    tag: []const []const u8,
};

pub const Column = struct {
    name: []const u8,
    type: ColumnType,
    nullable: bool = false,
    default: ?[]const u8 = null,
    /// Rui SQL, joined to the type's own CHECK with AND.
    check: ?[]const u8 = null,
    /// Which of a row's Sessions read this column, in a table that names
    /// two (`sessionColumns`). Every other table's one Session reads all
    /// of its columns, and leaves this `.recipient`.
    read_by: ReadBy = .recipient,
    engines: Engines = .all,
    /// SQLite ADD COLUMN appends ", " rather than a new line. Keep its
    /// exact stored CREATE text on bootstrap too, so admission still checks
    /// byte-for-byte equality after an additive migration.
    sqlite_added: bool = false,
};

/// The engines a table or column exists on. Each engine's DDL, catalog
/// and rendered INSERTs hold only its own (`on`).
pub const Engines = enum {
    all,
    sqlite,
    mysql,

    pub fn on(engines: Engines, dialect: rsql.Dialect) bool {
        return switch (engines) {
            .all => true,
            .sqlite => dialect == .sqlite,
            .mysql => dialect == .mysql,
        };
    }
};

/// The Sessions whose pages read a column of a table that names two
/// Sessions: `.recipient`, only its `session_ref`'s; `.both`, its
/// `sender_session_ref`'s too. A change to a `.both` column changes the
/// sender's facts, so its writer names the sender (`rsql.sessionError`)
/// and touches it, and the touch oracle records the sender.
pub const ReadBy = enum { recipient, both };

/// Checked when its row is written, on every engine: writers insert a
/// parent before its children.
pub const ForeignKey = struct {
    columns: []const []const u8,
    references: []const u8,
    referenced: []const []const u8,
};

/// A key or reference of one column is written on that column; one of
/// several columns is written after the columns.
pub const Table = struct {
    name: []const u8,
    columns: []const Column,
    primary_key: []const []const u8,
    uniques: []const []const []const u8 = &.{},
    foreign_keys: []const ForeignKey = &.{},
    /// Rui SQL.
    checks: []const []const u8 = &.{},
    without_rowid: bool = false,
    engines: Engines = .all,
};

pub const Index = struct {
    name: []const u8,
    table: []const u8,
    /// Column names, each optionally followed by DESC.
    columns: []const []const u8,
    unique: bool = false,
    /// Rui SQL. Queries that use a partial index repeat its terms, which is
    /// why spliced terms come from the constants those queries share.
    where: ?[]const u8 = null,
};

const content_reference: []const []const u8 = &.{"content_id"};
const session_reference: []const []const u8 = &.{"session_ref"};
const command_reference: []const []const u8 = &.{"command_key"};

fn references(comptime column: []const u8, comptime table: []const u8, comptime referenced: []const []const u8) ForeignKey {
    return .{ .columns = &.{column}, .references = table, .referenced = referenced };
}

// A label's syntax, not a provider list, so a new provider is no format change.
const provider_column: Column = .{ .name = "provider", .type = .{ .text = .{ .min = 1, .max = 16 } }, .check = "@initial(provider,'a-z') AND @charset(provider,'a-z0-9_-')" };
// The tool records a Session's settings offer (D48), saved once by content.
const tool_set_column: Column = .{ .name = "tool_set_id", .type = .int, .check = "tool_set_id>0" };
const permission_mode_column: Column = .{ .name = "permission_mode", .type = .int, .check = "permission_mode BETWEEN 0 AND 1" };
const compaction_trigger_column: Column = .{ .name = "compaction_trigger", .type = .int, .nullable = true, .check = "compaction_trigger IS NULL OR compaction_trigger>0" };
const reasoning_effort_column: Column = .{ .name = "reasoning_effort", .type = .{ .tag = &.{ "none", "low", "medium", "high", "xhigh", "max" } }, .nullable = true };
const label_column: Column = .{ .name = "label", .type = .{ .text = .{ .min = 1, .max = 100 } }, .nullable = true };

/// store_meta's keys, as bootstrap writes them: a closed set, so a key is
/// a tag, which MySQL can key. `store_id` is the Store's own random id,
/// drawn once when it is created and never changed (D204, format 54).
pub const MetaKey = enum { wire_version, store_selector, format, store_id };
const meta_keys = blk: {
    var names: [std.enums.values(MetaKey).len][]const u8 = undefined;
    for (std.enums.values(MetaKey), 0..) |key, index| names[index] = @tagName(key);
    break :blk names;
};
pub const MetaPresence = std.EnumSet(MetaKey);

const MetaSeed = struct {
    key: MetaKey,
    value: union(enum) { binding: u8, literal: []const u8, random_id },
};

/// One seed policy, with engine-owned bindings/randomness. Both engines
/// bind the canonical selector independently of the durable random id.
pub fn metaSeed(comptime dialect: rsql.Dialect) []const MetaSeed {
    return comptime blk: {
        var seed: []const MetaSeed = &.{};
        for (std.enums.values(MetaKey)) |key| {
            const value: @FieldType(MetaSeed, "value") = switch (key) {
                .wire_version => if (dialect == .sqlite) .{ .binding = 1 } else .{ .literal = wire_version },
                .store_selector => .{ .binding = 2 },
                .format => .{ .literal = format_text },
                .store_id => if (dialect == .sqlite) .random_id else .{ .binding = 1 },
            };
            seed = seed ++ .{MetaSeed{ .key = key, .value = value }};
        }
        break :blk seed;
    };
}

/// Draw only when a missing id will be inserted. No additional id cache.
pub fn drawStoreId(io: std.Io) [2 * store_id_bytes]u8 {
    var random: [store_id_bytes]u8 = undefined;
    io.random(&random);
    return std.fmt.bytesToHex(random, .lower);
}

/// MySQL's missing-key repair; transaction and ownership stay with admission.
pub fn writeMissingMeta(w: *std.Io.Writer, seen: MetaPresence, id: *const [2 * store_id_bytes]u8, selector: []const u8) !void {
    for (comptime metaSeed(.mysql)) |entry| {
        if (seen.contains(entry.key)) continue;
        const value = switch (entry.value) {
            .literal => |value| value,
            .binding => |binding| if (binding == 2) selector else id,
            .random_id => unreachable,
        };
        if (entry.key == .store_selector) {
            try w.writeAll("INSERT INTO store_meta(meta_key,meta_value) VALUES('store_selector',_utf8mb4 X'");
            try @import("mysql_literal.zig").writeHex(w, value);
            try w.writeAll("' COLLATE utf8mb4_0900_bin);");
            continue;
        }
        // Other values are schema literals or a lower-case hexadecimal id.
        try w.print("INSERT INTO store_meta(meta_key,meta_value) VALUES('{s}','{s}');", .{ @tagName(entry.key), value });
    }
}

/// The bytes of one MySQL `content_chunk` row; the last of a content's
/// chunks holds the rest. Under 16 MiB, so a chunk is one packet.
pub const content_chunk_bytes = 128 * 1024;

pub const tables = [_]Table{
    .{
        .name = "store_meta",
        .columns = &.{
            .{ .name = "meta_key", .type = .{ .tag = &meta_keys } },
            .{ .name = "meta_value", .type = .{ .text = null } },
        },
        .primary_key = &.{"meta_key"},
    },
    // The Host that owns a MySQL Store (one row): open bumps `epoch`, and
    // each write transaction bumps `commit_seq` only where both still
    // read as this Host left them, so a lost session or a restored backup
    // fences it. SQLite's file lock owns its Store instead.
    .{
        .name = "store_owner",
        .columns = &.{
            .{ .name = "owner_key", .type = .int, .check = "owner_key=1" },
            .{ .name = "epoch", .type = .int, .check = "epoch>=0" },
            .{ .name = "commit_seq", .type = .int, .check = "commit_seq>=0" },
        },
        .primary_key = &.{"owner_key"},
        .engines = .mysql,
    },
    .{
        .name = "content",
        .columns = &.{
            .{ .name = "content_id", .type = .int },
            .{ .name = "digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
            .{ .name = "byte_length", .type = .int, .check = "byte_length>=0 AND byte_length<=1073737728" },
            .{ .name = "private", .type = .flag },
            // MySQL holds the bytes in `content_chunk` instead.
            .{ .name = "payload", .type = .{ .bytes = null }, .check = "length(payload)=byte_length", .engines = .sqlite },
        },
        .primary_key = &.{"content_id"},
        .uniques = &.{&.{ "digest", "byte_length", "private" }},
    },
    // A MySQL content's bytes, `content_chunk_bytes` per row from index
    // 0, so no statement carries more than one chunk; an empty content
    // has none.
    .{
        .name = "content_chunk",
        .columns = &.{
            .{ .name = "content_id", .type = .int },
            .{ .name = "chunk_index", .type = .int, .check = "chunk_index>=0" },
            .{ .name = "bytes", .type = .{ .bytes = .{ .min = 1, .max = content_chunk_bytes } } },
        },
        .primary_key = &.{ "content_id", "chunk_index" },
        .foreign_keys = &.{references("content_id", "content", content_reference)},
        .engines = .mysql,
    },
    // One tool as the model is told about it (D48): its name, who owns it
    // (`rui`; `provider` for a tool the provider runs, whose text the codec
    // writes; `mcp` for an MCP server's, which `server` names), and its
    // description and input schema as content.
    .{
        .name = "tool_record",
        .columns = &.{
            .{ .name = "tool_record_id", .type = .int, .check = "tool_record_id>0" },
            .{ .name = "name", .type = .{ .text = .{ .min = 1, .max = tool_defs.max_name_bytes } }, .check = "@charset(name,'A-Za-z0-9_-')" },
            .{ .name = "owner", .type = .{ .tag = &.{ "rui", "provider", "mcp" } } },
            .{
                .name = "server",
                .type = .{ .text = .{ .min = 0, .max = tool_defs.max_server_bytes } },
                .check = "@charset(server,'A-Za-z0-9_-') AND (owner='mcp' AND @octets(server)>0 OR owner<>'mcp' AND @octets(server)=0)",
            },
            .{ .name = "read_only", .type = .flag, .default = "0", .check = "(read_only=0 OR owner='mcp')" },
            .{ .name = "description_content_id", .type = .int },
            .{ .name = "input_schema_content_id", .type = .int },
        },
        .primary_key = &.{"tool_record_id"},
        .uniques = &.{&.{ "name", "owner", "server", "read_only", "description_content_id", "input_schema_content_id" }},
        .foreign_keys = &.{
            references("description_content_id", "content", content_reference),
            references("input_schema_content_id", "content", content_reference),
        },
    },
    // An ordered set of tool records, saved once: `digest` names its
    // members' content (tool_record.zig `SetDigest`). A Session's set holds at
    // most max_tools, the wire's bound; the Host tool set up to
    // max_host_tool_records.
    .{
        .name = "tool_set",
        .columns = &.{
            .{ .name = "tool_set_id", .type = .int, .check = "tool_set_id>0" },
            .{ .name = "digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
            .{ .name = "member_count", .type = .int, .check = std.fmt.comptimePrint("member_count BETWEEN 0 AND {d}", .{tool_defs.max_host_tool_records}) },
        },
        .primary_key = &.{"tool_set_id"},
        .uniques = &.{&.{"digest"}},
    },
    .{
        .name = "tool_set_member",
        .columns = &.{
            .{ .name = "tool_set_id", .type = .int },
            .{ .name = "ordinal", .type = .int, .check = "ordinal>=0" },
            .{ .name = "tool_record_id", .type = .int },
        },
        .primary_key = &.{ "tool_set_id", "ordinal" },
        .foreign_keys = &.{
            references("tool_set_id", "tool_set", &.{"tool_set_id"}),
            references("tool_record_id", "tool_record", &.{"tool_record_id"}),
        },
        .without_rowid = true,
    },
    // The Host tool set: the set its last open saved (tool_record.zig
    // `HostToolSet`), which the next start reads back. One row.
    .{
        .name = "host_tool_set",
        .columns = &.{
            .{ .name = "slot", .type = .int, .check = "slot=1" },
            .{ .name = "tool_set_id", .type = .int },
        },
        .primary_key = &.{"slot"},
        .foreign_keys = &.{
            references("tool_set_id", "tool_set", &.{"tool_set_id"}),
        },
    },
    // models.dev facts are published with their source generation atomically.
    .{
        .name = "model_fact",
        .columns = &.{
            .{ .name = "model_id", .type = .{ .text = .{ .min = 1, .max = 256 } } },
            .{ .name = "context_window", .type = .int, .nullable = true },
            .{ .name = "efforts", .type = .int, .check = "efforts BETWEEN 0 AND 63" },
            .{ .name = "openai_listed", .type = .flag },
            .{ .name = "generation", .type = .int },
        },
        .primary_key = &.{"model_id"},
    },
    .{
        .name = "model_catalog_source",
        .columns = &.{
            .{ .name = "slot", .type = .int, .check = "slot=1" },
            .{ .name = "etag", .type = .{ .text = .{ .min = 0, .max = 512 } }, .nullable = true },
            .{ .name = "generation", .type = .int },
            .{ .name = "fetched_at", .type = .int },
        },
        .primary_key = &.{"slot"},
    },
    .{
        .name = "session",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = .{ .min = 6, .max = 6 } }, .check = "@charset(session_ref,'0123456789abcdefghjkmnpqrstvwxyz')" },
            .{ .name = "workspace", .type = .{ .text = .{ .min = 1, .max = 4096 } } },
            provider_column,
            // The Session's immutable binding: grammar version and its options.
            .{ .name = "codec", .type = .{ .text = .{ .min = 3, .max = 40 } } },
            .{ .name = "codec_options", .type = .{ .bytes = .{ .min = 1, .max = 512 } }, .nullable = true },
            // What the last fully rebuilt history span encoded to (prefix_seal.zig).
            .{ .name = "prefix_seal", .type = .{ .bytes = .{ .min = prefix_seal.encoded_bytes, .max = prefix_seal.encoded_bytes } }, .nullable = true },
            .{ .name = "model", .type = .{ .text = .{ .min = 1, .max = 256 } } },
            .{ .name = "instructions_content_id", .type = .int },
            tool_set_column,
            .{ .name = "loaded_tool_set_id", .type = .int, .nullable = true },
            permission_mode_column,
            .{ .name = "output_schema_content_id", .type = .int, .nullable = true },
            .{ .name = "revision", .type = .int, .check = "revision>0" },
            compaction_trigger_column,
            .{ .name = "output_reservation", .type = .int, .nullable = true, .check = "output_reservation IS NULL OR output_reservation>=0" },
            reasoning_effort_column,
            label_column,
            .{ .name = "created_at", .type = .int, .check = "created_at>0" },
            .{ .name = "next_position", .type = .int, .check = "next_position>0" },
            // Creation order: list cursors and the Workspace key, allocated
            // by the Host in the creating transaction.
            .{ .name = "created_seq", .type = .int, .check = "created_seq>0" },
            // SHA-256 of `workspace`. Workspace equality compares it, then the
            // text, so a collision never merges two Workspaces.
            .{ .name = "workspace_digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
            // The change ring's key: created_seq of the Workspace's first Session.
            .{ .name = "workspace_key", .type = .int },
            // The Session that started this one as its attached child (D27).
            .{ .name = "parent_ref", .type = .{ .text = null }, .nullable = true },
            .{ .name = "obligation_since", .type = .int, .nullable = true, .sqlite_added = true, .check = "obligation_since IS NULL OR obligation_since>0" },
        },
        .primary_key = &.{"session_ref"},
        .uniques = &.{&.{"created_seq"}},
        .checks = &.{ "workspace_key>0 AND workspace_key<=created_seq", "parent_ref IS NULL OR parent_ref<>session_ref" },
        .foreign_keys = &.{
            references("instructions_content_id", "content", content_reference),
            references("tool_set_id", "tool_set", &.{"tool_set_id"}),
            references("loaded_tool_set_id", "tool_set", &.{"tool_set_id"}),
            references("output_schema_content_id", "content", content_reference),
            references("parent_ref", "session", session_reference),
        },
    },
    .{
        .name = "core_command",
        .columns = &.{
            .{ .name = "command_key", .type = .{ .text = .{ .max = 128 } } },
            .{ .name = "kind", .type = .int, .check = "kind BETWEEN 1 AND 6" },
            .{ .name = "target", .type = .{ .text = .{ .max = 128 } } },
            .{ .name = "input_digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
            .{ .name = "primary_content_id", .type = .int, .nullable = true },
            .{ .name = "secondary_content_id", .type = .int, .nullable = true },
            .{ .name = "accepted", .type = .flag },
            .{ .name = "code", .type = .{ .text = .{ .max = 96 } } },
            .{ .name = "revision", .type = .int, .check = "revision>=0" },
            .{ .name = "created", .type = .flag },
            // Command order, allocated by the Host in the recording
            // transaction: the rowid, so command order costs no index.
            .{ .name = "command_seq", .type = .int, .check = "command_seq>0" },
        },
        .primary_key = &.{"command_seq"},
        .uniques = &.{&.{"command_key"}},
        .foreign_keys = &.{
            references("primary_content_id", "content", content_reference),
            references("secondary_content_id", "content", content_reference),
        },
    },
    .{
        .name = "session_revision",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "revision", .type = .int, .check = "revision>0" },
            .{ .name = "command_key", .type = .{ .text = null } },
            .{ .name = "workspace", .type = .{ .text = null } },
            provider_column,
            .{ .name = "model", .type = .{ .text = null } },
            .{ .name = "instructions_content_id", .type = .int },
            .{ .name = "instructions_updated", .type = .flag },
            tool_set_column,
            .{ .name = "loaded_tool_set_id", .type = .int, .nullable = true },
            permission_mode_column,
            .{ .name = "output_schema_content_id", .type = .int, .nullable = true },
            compaction_trigger_column,
            .{ .name = "output_reservation", .type = .int, .nullable = true, .check = "output_reservation IS NULL OR output_reservation>=0" },
            reasoning_effort_column,
            label_column,
            .{ .name = "effort_source_revision", .type = .int, .default = "1", .check = "effort_source_revision>0 AND effort_source_revision<=revision" },
        },
        .primary_key = &.{ "session_ref", "revision" },
        .uniques = &.{&.{"command_key"}},
        .foreign_keys = &.{
            references("session_ref", "session", session_reference),
            references("command_key", "core_command", command_reference),
            references("instructions_content_id", "content", content_reference),
            references("tool_set_id", "tool_set", &.{"tool_set_id"}),
            references("loaded_tool_set_id", "tool_set", &.{"tool_set_id"}),
            .{ .columns = &.{ "session_ref", "effort_source_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
            references("output_schema_content_id", "content", content_reference),
        },
        .without_rowid = true,
    },
    .{
        // The feed's change list (D138, D218): one row per setting a
        // revision changed, written in the revision's own commit and never
        // edited. The revision keeps the current values; a row records
        // when its change was accepted. A revision's rows share one
        // position, one ordinal each. An effort refusal is appended later,
        // naming that effort revision with the provider's bounded report.
        .name = "session_change",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "position", .type = .int, .check = "position>0" },
            .{ .name = "ordinal", .type = .int, .check = "ordinal>=0" },
            .{ .name = "revision", .type = .int, .check = "revision>1" },
            .{ .name = "field", .type = .{ .tag = session_settings.revision_fields } },
            .{ .name = "changed_at", .type = .int, .check = "changed_at>0" },
            .{ .name = "provider_text", .type = .{ .text = .{ .min = 0, .max = @import("../outcome_code.zig").max_report_bytes } }, .nullable = true },
            .{ .name = "refused_operation_id", .type = .int, .nullable = true },
        },
        .primary_key = &.{ "session_ref", "position", "ordinal" },
        .uniques = &.{&.{ "session_ref", "revision", "field" }},
        .foreign_keys = &.{
            references("session_ref", "session", session_reference),
            .{ .columns = &.{ "session_ref", "revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
            .{ .columns = &.{ "refused_operation_id", "session_ref", "revision" }, .references = "model_operation", .referenced = &.{ "operation_id", "session_ref", "effort_source_revision" } },
        },
        .checks = &.{ "(field='reasoning_effort_refused')=(provider_text IS NOT NULL)", "(field='reasoning_effort_refused')=(refused_operation_id IS NOT NULL)" },
        .without_rowid = true,
    },
    .{
        .name = "message_admission",
        // `.both`: what the sender's activity page reads of a sent Message,
        // by sender_session_ref: its sources (`reads.activitySources`, kind
        // 8: sender_position, admission_id) and its item (`reads.zig`, kind
        // 8: session_ref, content_id, admitted_at, and command_key, which
        // joins the command), keyed by admission_id, sender_session_ref and
        // sender_position.
        .columns = &.{
            .{ .name = "admission_id", .type = .int, .check = "admission_id>0", .read_by = .both },
            .{ .name = "session_ref", .type = .{ .text = null }, .read_by = .both },
            .{ .name = "command_key", .type = .{ .text = null }, .read_by = .both },
            .{ .name = "content_id", .type = .int, .read_by = .both },
            .{ .name = "admission_position", .type = .int, .nullable = true, .check = "admission_position>0" },
            .{ .name = "turn_id", .type = .int, .nullable = true },
            .{ .name = "admitted_at", .type = .int, .check = "admitted_at>0", .read_by = .both },
            .{ .name = "sender_session_ref", .type = .{ .text = null }, .nullable = true, .read_by = .both },
            .{ .name = "sender_position", .type = .int, .nullable = true, .check = "sender_position>0", .read_by = .both },
        },
        .primary_key = &.{"admission_id"},
        .uniques = &.{&.{"command_key"}},
        .foreign_keys = &.{
            references("session_ref", "session", session_reference),
            references("command_key", "core_command", command_reference),
            references("content_id", "content", content_reference),
            // The one reference cycle, with turn.first_admission_id: an
            // Admission is written with turn_id NULL, and set once its Turn exists.
            references("turn_id", "turn", &.{"turn_id"}),
            references("sender_session_ref", "session", session_reference),
        },
        .checks = &.{"(sender_session_ref IS NULL)=(sender_position IS NULL)"},
    },
    .{
        .name = "sent_rejection",
        .columns = &.{
            .{ .name = "command_key", .type = .{ .text = null } },
            .{ .name = "sender_session_ref", .type = .{ .text = null } },
            .{ .name = "sender_position", .type = .int, .check = "sender_position>0" },
            .{ .name = "rejected_at", .type = .int, .check = "rejected_at>0" },
        },
        .primary_key = &.{"command_key"},
        .uniques = &.{&.{ "sender_session_ref", "sender_position" }},
        .foreign_keys = &.{
            references("command_key", "core_command", command_reference),
            references("sender_session_ref", "session", session_reference),
        },
        .without_rowid = true,
    },
    .{
        .name = "turn",
        .columns = &.{
            .{ .name = "turn_id", .type = .int, .check = "turn_id>0" },
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "first_admission_id", .type = .int },
            .{ .name = "input_cutoff", .type = .int, .check = "input_cutoff>=first_admission_id" },
            .{ .name = "operation_id", .type = .int },
            .{ .name = "outcome_code", .type = .{ .text = .{ .min = 1, .max = 96 } }, .nullable = true },
            .{ .name = "outcome_content_id", .type = .int, .nullable = true },
            .{ .name = "outcome_position", .type = .int, .nullable = true, .check = "outcome_position>0" },
            .{ .name = "outcome_at", .type = .int, .nullable = true, .check = "outcome_at IS NULL OR outcome_at>0" },
            .{ .name = "continuation_operation_id", .type = .int, .nullable = true, .check = "continuation_operation_id IS NULL OR continuation_operation_id<=operation_id" },
        },
        .primary_key = &.{"turn_id"},
        .foreign_keys = &.{
            references("session_ref", "session", session_reference),
            references("first_admission_id", "message_admission", &.{"admission_id"}),
            references("outcome_content_id", "content", content_reference),
        },
        .checks = &.{"(outcome_code IS NULL)=(outcome_at IS NULL)"},
    },
    .{
        .name = "session_stop",
        .columns = &.{
            .{ .name = "command_key", .type = .{ .text = null } },
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "selected_turn_id", .type = .int, .nullable = true },
            .{ .name = "position", .type = .int, .nullable = true, .check = "position>0" },
            .{ .name = "admission_cutoff", .type = .int, .check = "admission_cutoff>=0" },
            .{ .name = "stopped_at", .type = .int, .check = "stopped_at>0" },
            // Causal provenance, independent of which Command recorded the stop.
            .{ .name = "parent_caused", .type = .flag, .default = "0" },
        },
        .primary_key = &.{"command_key"},
        .foreign_keys = &.{
            references("command_key", "core_command", command_reference),
            references("session_ref", "session", session_reference),
            references("selected_turn_id", "turn", &.{"turn_id"}),
        },
        .without_rowid = true,
    },
    .{
        // Current archive intent points to the durable stop first recorded
        // for this archive, not a later idempotent archive command. A NULL
        // command_key retains the row after restore without DELETE authority.
        .name = "session_archive",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "command_key", .type = .{ .text = null }, .nullable = true },
        },
        .primary_key = &.{"session_ref"},
        .foreign_keys = &.{
            references("session_ref", "session", session_reference),
            references("command_key", "session_stop", command_reference),
        },
        .without_rowid = true,
    },
    .{
        // The request's desired value never follows mutable archive intent.
        .name = "session_archive_command",
        .columns = &.{
            .{ .name = "command_key", .type = .{ .text = null } },
            .{ .name = "archived", .type = .flag },
        },
        .primary_key = &.{"command_key"},
        .foreign_keys = &.{references("command_key", "core_command", command_reference)},
        .without_rowid = true,
    },
    .{
        // An attached child owes a stop because its parent stopped or ran
        // out of context (D38); the Host runs it as the child's own stop,
        // which settles the row. The first cause names the stop's key. Host
        // work, not a Session's state: no reader of a Session reads it.
        .name = "session_stop_owed",
        .columns = &.{
            .{ .name = "child_ref", .type = .{ .text = null } },
            .{ .name = "cause_ref", .type = .{ .text = null } },
            .{ .name = "cause_position", .type = .int, .check = "cause_position>0" },
            .{ .name = "settled", .type = .int, .check = "settled BETWEEN 0 AND 1" },
        },
        .primary_key = &.{ "child_ref", "cause_ref", "cause_position" },
        .foreign_keys = &.{
            references("child_ref", "session", session_reference),
            references("cause_ref", "session", session_reference),
        },
        .without_rowid = true,
    },
    .{
        // Owed ancestor feed work claims no position until delivery. Like
        // session_stop_owed, enqueueing it does not change a Session head.
        // The first ending hop also owes the parent a Message (D39).
        .name = "session_forward",
        .columns = &.{
            .{ .name = "forward_id", .type = .int, .check = "forward_id>0" },
            .{ .name = "target_ref", .type = .{ .text = null } },
            .{ .name = "child_ref", .type = .{ .text = null } },
            .{ .name = "kind", .type = .int, .check = "kind BETWEEN 1 AND 2" },
            .{ .name = "source_id", .type = .int, .check = "source_id>0" },
            .{ .name = "position", .type = .int, .nullable = true, .check = "position IS NULL OR position>0" },
            .{ .name = "ordinal", .type = .int, .check = "ordinal=0" },
            .{ .name = "delivered_at", .type = .int, .nullable = true, .check = "delivered_at IS NULL OR delivered_at>0" },
            // Null on approvals/later hops, false while owed, true once settled.
            .{ .name = "message_delivered", .type = .flag, .nullable = true },
            // Archive suppression survives restoring the parent.
            .{ .name = "suppress_message", .type = .flag, .default = "0" },
        },
        .primary_key = &.{"forward_id"},
        .uniques = &.{&.{ "target_ref", "kind", "source_id" }},
        .checks = &.{ "(position IS NULL)=(delivered_at IS NULL)", "target_ref<>child_ref" },
        .foreign_keys = &.{
            references("target_ref", "session", session_reference),
            references("child_ref", "session", session_reference),
        },
    },
    .{
        .name = "model_interruption_command",
        .columns = &.{
            .{ .name = "command_key", .type = .{ .text = null } },
            .{ .name = "session_ref", .type = .{ .text = .{ .max = 128 } } },
            // A u64 in decimal: ASCII digits, so bytes and characters agree.
            .{ .name = "turn_id", .type = .{ .text = .{ .min = 1, .max = 20 } }, .check = "@charset(turn_id,'0-9')" },
            .{ .name = "operation_id", .type = .{ .text = .{ .min = 1, .max = 20 } }, .check = "@charset(operation_id,'0-9')" },
        },
        .primary_key = &.{"command_key"},
        .foreign_keys = &.{references("command_key", "core_command", command_reference)},
        .without_rowid = true,
    },
    .{
        .name = "model_operation",
        .columns = &.{
            .{ .name = "operation_id", .type = .int, .check = "operation_id>0" },
            .{ .name = "turn_id", .type = .int },
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "settings_revision", .type = .int, .check = "settings_revision>0" },
            .{ .name = "input_cutoff", .type = .int, .check = "input_cutoff>0" },
            .{ .name = "admission_position", .type = .int, .check = "admission_position>0" },
            .{ .name = "purpose", .type = .flag, .default = "0" },
            compaction_trigger_column,
            .{ .name = "output_reservation", .type = .int, .check = "output_reservation>=0" },
            reasoning_effort_column,
            .{ .name = "output_item_count", .type = .int, .nullable = true, .check = "output_item_count IS NULL OR output_item_count>=0" },
            .{ .name = "attempt_ordinal", .type = .int, .check = std.fmt.comptimePrint("attempt_ordinal BETWEEN 1 AND {d}", .{retry_policy.maximum_attempts}) },
            .{ .name = "auth_refresh_claimed", .type = .flag, .default = "0" },
            .{ .name = "retry_due_at_ms", .type = .int, .nullable = true, .check = "retry_due_at_ms IS NULL OR retry_due_at_ms>=0" },
            .{ .name = "last_failure_code", .type = .{ .text = .{ .min = 1, .max = 96 } }, .nullable = true },
            .{ .name = "resolution_code", .type = .{ .text = .{ .min = 1, .max = 96 } }, .nullable = true },
            .{ .name = "resolution_content_id", .type = .int, .nullable = true },
            .{ .name = "response_id", .type = .{ .text = .{ .max = 256 } }, .nullable = true },
            .{ .name = "model_evidence", .type = .{ .bytes = .{ .min = 7, .max = 775 } }, .nullable = true },
            .{ .name = "request_id", .type = .{ .text = .{ .max = 256 } }, .nullable = true },
            .{ .name = "usage_uncached_tokens", .type = .int, .nullable = true, .check = "usage_uncached_tokens IS NULL OR usage_uncached_tokens>=0" },
            .{ .name = "usage_cache_read_tokens", .type = .int, .nullable = true, .check = "usage_cache_read_tokens IS NULL OR usage_cache_read_tokens>=0" },
            .{ .name = "usage_cache_write_tokens", .type = .int, .nullable = true, .check = "usage_cache_write_tokens IS NULL OR usage_cache_write_tokens>=0" },
            .{ .name = "usage_output_tokens", .type = .int, .nullable = true, .check = "usage_output_tokens IS NULL OR usage_output_tokens>=0" },
            .{ .name = "interrupted_by_command_key", .type = .{ .text = null }, .nullable = true },
            .{ .name = "attempt_at", .type = .int, .nullable = true, .check = "attempt_at IS NULL OR attempt_at>0" },
            .{ .name = "retry_scheduled_at", .type = .int, .nullable = true, .check = "retry_scheduled_at IS NULL OR retry_scheduled_at>0" },
            .{ .name = "resolved_at", .type = .int, .nullable = true, .check = "resolved_at IS NULL OR resolved_at>0" },
            // A compaction that makes room (D217): it and every request on
            // its base omit the drop units that begin at or below the
            // floor, a Session position; the level, 1 to 3, sets how much
            // room it aimed for.
            .{ .name = "history_floor", .type = .int, .nullable = true, .check = "history_floor IS NULL OR history_floor>0" },
            .{ .name = "history_level", .type = .int, .nullable = true, .check = "history_level IS NULL OR history_level BETWEEN 1 AND 3" },
            // The conversation entries the floor dropped beyond its base's
            // or the compaction before it; the feed's `compacted` row shows
            // it, and zero for a compaction without a floor.
            .{ .name = "history_dropped", .type = .int, .nullable = true, .check = "history_dropped IS NULL OR history_dropped>=0" },
            // Effective offer frozen at admission; Session sets are intent.
            tool_set_column,
            // One admission snapshot; later refusals never rewrite it.
            .{ .name = "effort_source_revision", .type = .int, .default = "1", .check = "effort_source_revision>0 AND effort_source_revision<=settings_revision" },
            .{ .name = "previous_reasoning_effort", .type = reasoning_effort_column.type, .nullable = true },
            .{ .name = "effort_update", .type = .flag, .default = "0", .check = "(effort_update=0 OR reasoning_effort IS NOT NULL)" },
            .{ .name = "previous_effort_override", .type = reasoning_effort_column.type, .nullable = true },
            .{ .name = "latency_ms", .type = .int, .nullable = true, .sqlite_added = true, .check = "latency_ms IS NULL OR latency_ms>=0" },
            .{ .name = "first_event_ms", .type = .int, .nullable = true, .sqlite_added = true, .check = "first_event_ms IS NULL OR first_event_ms>=0" },
            // Admission-time capacity, including the effective unknown-model fallback.
            .{ .name = "context_window", .type = .int, .check = "context_window BETWEEN 0 AND 4294967295" },
        },
        .primary_key = &.{"operation_id"},
        .uniques = &.{&.{ "operation_id", "session_ref" }},
        .foreign_keys = &.{
            references("tool_set_id", "tool_set", &.{"tool_set_id"}),
            references("turn_id", "turn", &.{"turn_id"}),
            references("resolution_content_id", "content", content_reference),
            references("interrupted_by_command_key", "core_command", command_reference),
            .{ .columns = &.{ "session_ref", "settings_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
        },
        .checks = &.{
            // Usage counts are all present or all absent.
            "(usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR " ++
                "(usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND " ++
                "usage_output_tokens IS NOT NULL)",
            "(resolution_code IS NULL AND retry_due_at_ms IS NOT NULL) OR (resolution_code IS NOT NULL AND retry_due_at_ms IS NULL)",
            // The second the current state began: exactly the time its state owns.
            "(resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at IS NOT NULL AND retry_scheduled_at IS NULL AND resolved_at IS NULL) OR " ++
                "(resolution_code IS NULL AND retry_due_at_ms>0 AND attempt_at IS NULL AND retry_scheduled_at IS NOT NULL AND resolved_at IS NULL) OR " ++
                "(resolution_code IS NOT NULL AND attempt_at IS NULL AND retry_scheduled_at IS NULL AND resolved_at IS NOT NULL)",
            "(@same(resolution_code,'interrupted') AND interrupted_by_command_key IS NOT NULL) OR " ++
                "(coalesce(resolution_code,'')!='interrupted' AND interrupted_by_command_key IS NULL)",
            // A level and its dropped count are the room a compaction made;
            // one that made none keeps its base's floor.
            "(history_floor IS NULL AND history_level IS NULL AND history_dropped IS NULL) OR (history_floor IS NOT NULL AND purpose=1 AND " ++
                "((history_level IS NULL AND history_dropped IS NULL) OR (history_level IS NOT NULL AND history_dropped IS NOT NULL)))",
        },
    },
    .{
        // A skill a Message's `/name` word bound, in order after the
        // Message: its name and its body as read at send. A Turn that takes
        // the Message projects each as its own entry right after it.
        .name = "message_skill",
        .columns = &.{
            .{ .name = "admission_id", .type = .int },
            .{ .name = "position", .type = .int, .check = "position>0" },
            .{ .name = "name", .type = .{ .text = .{ .min = 1, .max = 64 } }, .check = "@charset(name,'a-z0-9-')" },
            .{ .name = "content_id", .type = .int },
        },
        .primary_key = &.{ "admission_id", "position" },
        .foreign_keys = &.{
            references("admission_id", "message_admission", &.{"admission_id"}),
            references("content_id", "content", content_reference),
        },
        .without_rowid = true,
    },
    .{
        .name = "session_skill_catalog",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "position", .type = .int, .check = "position>=0" },
            .{ .name = "catalog_content_id", .type = .int },
        },
        .primary_key = &.{ "session_ref", "position" },
        .foreign_keys = &.{
            references("session_ref", "session", &.{"session_ref"}),
            references("catalog_content_id", "content", content_reference),
        },
        .without_rowid = true,
    },
    .{
        .name = "conversation_entry",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "entry_ordinal", .type = .int, .check = "entry_ordinal>0" },
            .{ .name = "session_position", .type = .int, .check = "session_position>0" },
            .{ .name = "entry_kind", .type = .int, .check = "entry_kind BETWEEN 1 AND 4" },
            .{ .name = "turn_id", .type = .int, .nullable = true },
            .{ .name = "source_admission_id", .type = .int, .nullable = true },
            .{ .name = "source_revision", .type = .int, .nullable = true },
            .{ .name = "source_catalog_position", .type = .int, .nullable = true },
            .{ .name = "source_skill_admission_id", .type = .int, .nullable = true },
            .{ .name = "source_skill_position", .type = .int, .nullable = true },
            .{ .name = "source_operation_id", .type = .int, .nullable = true },
            .{ .name = "source_item_ordinal", .type = .int, .nullable = true, .check = "source_item_ordinal IS NULL OR source_item_ordinal>=0" },
            .{ .name = "content_id", .type = .int },
            .{ .name = "recorded_at", .type = .int, .check = "recorded_at>0" },
        },
        .primary_key = &.{ "session_ref", "entry_ordinal" },
        .uniques = &.{ &.{"source_admission_id"}, &.{ "session_ref", "session_position" }, &.{ "session_ref", "source_revision" }, &.{ "session_ref", "source_catalog_position" }, &.{ "source_skill_admission_id", "source_skill_position" } },
        .foreign_keys = &.{
            references("turn_id", "turn", &.{"turn_id"}),
            references("source_admission_id", "message_admission", &.{"admission_id"}),
            references("source_operation_id", "model_operation", &.{"operation_id"}),
            references("content_id", "content", content_reference),
            .{ .columns = &.{ "session_ref", "source_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
            .{ .columns = &.{ "session_ref", "source_catalog_position" }, .references = "session_skill_catalog", .referenced = &.{ "session_ref", "position" } },
            .{ .columns = &.{ "source_skill_admission_id", "source_skill_position" }, .references = "message_skill", .referenced = &.{ "admission_id", "position" } },
            .{ .columns = &.{ "source_operation_id", "source_item_ordinal" }, .references = "model_output_item", .referenced = &.{ "operation_id", "item_ordinal" } },
        },
        .checks = &.{
            "(entry_kind=3)=(source_item_ordinal IS NOT NULL)",
            "(turn_id IS NULL)=(source_catalog_position IS NOT NULL)",
            "source_catalog_position IS NULL OR source_catalog_position=session_position",
            "(source_skill_admission_id IS NULL)=(source_skill_position IS NULL)",
            "(entry_kind=4)=(source_skill_position IS NOT NULL)",
            "(entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL) OR " ++
                "(entry_kind=2 AND source_admission_id IS NULL AND ((source_revision IS NOT NULL AND source_catalog_position IS NULL) OR (source_revision IS NULL AND source_catalog_position IS NOT NULL)) AND source_operation_id IS NULL) OR " ++
                "(entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NOT NULL) OR " ++
                "(entry_kind=4 AND source_admission_id IS NULL AND source_revision IS NULL AND source_catalog_position IS NULL AND source_operation_id IS NULL)",
        },
        .without_rowid = true,
    },
    .{
        .name = "model_output_item",
        .columns = &.{
            .{ .name = "operation_id", .type = .int },
            .{ .name = "item_ordinal", .type = .int, .check = "item_ordinal>=0" },
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "session_position", .type = .int, .check = "session_position>0" },
            .{ .name = "item_kind", .type = .int, .check = "item_kind BETWEEN 1 AND 5" },
            // A message's text: its text parts back to back, stored once.
            .{ .name = "message_content_id", .type = .int, .nullable = true, .check = "(message_content_id IS NOT NULL)=(item_kind=2)" },
            .{ .name = "attempt_ordinal", .type = .int, .check = "attempt_ordinal>0" },
            .{ .name = "item_id_digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
            .{ .name = "replay_omits_reasoning_text", .type = .flag, .check = "(replay_omits_reasoning_text=0 OR item_kind=1)" },
            // Rui's own form: the message phase, the parts below, and the
            // provider bag of what that form does not hold.
            .{ .name = "phase", .type = .int, .default = "0", .check = "phase IN (0,1,2) AND (phase=0 OR item_kind=2)" },
            .{ .name = "extras_content_id", .type = .int },
            .{ .name = "part_count", .type = .int, .check = "part_count>=0 AND (part_count=0 OR item_kind IN (1,2))" },
            // A hosted tool call's description and outcome: every tool
            // call is shown by its description.
            .{ .name = "description", .type = .{ .text = .{ .min = 1, .max = 200 } }, .nullable = true, .check = "(description IS NOT NULL)=(item_kind=5)" },
            .{ .name = "call_failed", .type = .flag, .default = "0", .check = "(call_failed=0 OR item_kind=5)" },
        },
        .primary_key = &.{ "operation_id", "item_ordinal" },
        .uniques = &.{ &.{ "session_ref", "session_position" }, &.{ "operation_id", "item_id_digest" } },
        .foreign_keys = &.{
            references("operation_id", "model_operation", &.{"operation_id"}),
            references("message_content_id", "content", content_reference),
            references("extras_content_id", "content", content_reference),
        },
        .without_rowid = true,
    },
    .{
        .name = "model_output_part",
        .columns = &.{
            .{ .name = "operation_id", .type = .int },
            .{ .name = "item_ordinal", .type = .int },
            .{ .name = "part_ordinal", .type = .int, .check = "part_ordinal>=0" },
            .{ .name = "part_array", .type = .int, .check = "part_array IN (1,2)" },
            // output_text and refusal are message content, summary_text a
            // summary, reasoning_text reasoning content; 0 is an opaque block.
            .{ .name = "part_kind", .type = .int, .check = "part_kind=0 OR (part_kind IN (1,2,4) AND part_array=1) OR (part_kind=3 AND part_array=2)" },
            // A message part's text is the next text_length bytes of its
            // item's message text; a reasoning part's text is its own row.
            .{ .name = "text_length", .type = .int, .nullable = true, .check = "text_length IS NULL OR text_length>=0" },
            .{ .name = "text_content_id", .type = .int, .nullable = true },
            .{ .name = "extras_content_id", .type = .int },
        },
        .primary_key = &.{ "operation_id", "item_ordinal", "part_ordinal" },
        .foreign_keys = &.{
            references("text_content_id", "content", content_reference),
            references("extras_content_id", "content", content_reference),
        },
        .checks = &.{"(text_length IS NOT NULL)=(part_kind IN (1,2)) AND (text_content_id IS NOT NULL)=(part_kind IN (3,4))"},
        .without_rowid = true,
    },
    .{
        .name = "model_tool_call",
        .columns = &.{
            .{ .name = "operation_id", .type = .int },
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "call_ordinal", .type = .int, .check = "call_ordinal>=0" },
            .{ .name = "item_ordinal", .type = .int, .check = "item_ordinal>=0" },
            .{ .name = "name_content_id", .type = .int },
            .{ .name = "call_id_content_id", .type = .int },
            .{ .name = "arguments_content_id", .type = .int },
            .{ .name = "description", .type = .{ .text = .{ .min = 1, .max = 200 } }, .nullable = true },
            .{ .name = "field_metadata", .type = .{ .bytes = .{ .min = 120, .max = 120 } } },
            .{ .name = "rejection_code", .type = .{ .tag = &.{ "unknown_tool", "invalid_arguments" } }, .nullable = true },
            .{ .name = "rejection_content_id", .type = .int, .nullable = true },
            .{ .name = "acceptance_position", .type = .int, .nullable = true, .check = "acceptance_position IS NULL OR acceptance_position>0" },
            .{ .name = "action_kind", .type = .int, .nullable = true, .check = "action_kind IS NULL OR action_kind=1" },
        },
        .primary_key = &.{ "operation_id", "call_ordinal" },
        .uniques = &.{ &.{ "operation_id", "item_ordinal" }, &.{ "operation_id", "call_id_content_id" }, &.{ "operation_id", "call_ordinal", "action_kind" } },
        .foreign_keys = &.{
            references("operation_id", "model_operation", &.{"operation_id"}),
            .{ .columns = &.{ "operation_id", "session_ref" }, .references = "model_operation", .referenced = &.{ "operation_id", "session_ref" } },
            references("name_content_id", "content", content_reference),
            references("call_id_content_id", "content", content_reference),
            references("arguments_content_id", "content", content_reference),
            references("rejection_content_id", "content", content_reference),
        },
        .checks = &.{
            "(rejection_code IS NULL AND rejection_content_id IS NULL AND acceptance_position IS NULL AND @same(action_kind,1)) OR " ++
                "(rejection_code IS NOT NULL AND rejection_content_id IS NOT NULL AND acceptance_position IS NOT NULL AND action_kind IS NULL)",
        },
        .without_rowid = true,
    },
    .{
        .name = "action_operation",
        .columns = &.{
            .{ .name = "action_id", .type = .int, .check = "action_id>0" },
            .{ .name = "parent_operation_id", .type = .int },
            .{ .name = "call_ordinal", .type = .int, .check = "call_ordinal>=0" },
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "tool_kind", .type = .int, .check = "tool_kind=1" },
            .{ .name = "permission_revision", .type = .int, .check = "permission_revision>0" },
            // Written only by the insert, under a `bypass` revision, and by an
            // accepted `allow_once` decision. Stored because it keys the
            // admission index, and no partial index can see the revision or grant.
            .{ .name = "authorized", .type = .flag },
            .{ .name = "attempt_ordinal", .type = .int, .default = "0", .check = "attempt_ordinal IN (0,1)" },
            .{ .name = "bash_timeout_override_ms", .type = .int, .nullable = true, .check = "bash_timeout_override_ms IS NULL OR bash_timeout_override_ms>0" },
            .{ .name = "attempt_timeout_ms", .type = .int, .nullable = true, .check = "attempt_timeout_ms IS NULL OR attempt_timeout_ms>0" },
            .{ .name = "sender_handle", .type = .{ .text = .{ .min = 32, .max = 32 } }, .nullable = true, .check = "@charset(sender_handle,'0-9a-f')" },
            .{
                .name = "resolution_code",
                .type = .{ .tag = &.{ "denied", "cancelled", "succeeded", "failed", "timed_out", "indeterminate", "storage_failed", "spawn_failed", "infrastructure_shutdown" } },
                .nullable = true,
            },
            .{ .name = "resolution_content_id", .type = .int, .nullable = true },
            .{ .name = "acceptance_position", .type = .int, .nullable = true, .check = "acceptance_position IS NULL OR acceptance_position>0" },
            .{ .name = "attempt_at", .type = .int, .nullable = true, .check = "attempt_at IS NULL OR attempt_at>0" },
            .{ .name = "decided_at", .type = .int, .nullable = true, .check = "decided_at IS NULL OR decided_at>0" },
            .{ .name = "resolved_at", .type = .int, .nullable = true, .check = "resolved_at IS NULL OR resolved_at>0" },
            // The position of the call that asked a person, written by the
            // insert under an `ask` revision and never changed. Stored
            // because the feed seeks it and no index can see the revision.
            .{ .name = "approval_position", .type = .int, .nullable = true, .check = "approval_position IS NULL OR approval_position>0" },
        },
        .primary_key = &.{"action_id"},
        .uniques = &.{&.{ "parent_operation_id", "call_ordinal" }},
        .foreign_keys = &.{
            references("parent_operation_id", "model_operation", &.{"operation_id"}),
            references("session_ref", "session", session_reference),
            references("resolution_content_id", "content", content_reference),
            .{ .columns = &.{ "parent_operation_id", "session_ref" }, .references = "model_operation", .referenced = &.{ "operation_id", "session_ref" } },
            .{ .columns = &.{ "parent_operation_id", "call_ordinal", "tool_kind" }, .references = "model_tool_call", .referenced = &.{ "operation_id", "call_ordinal", "action_kind" } },
            .{ .columns = &.{ "session_ref", "permission_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
        },
        .checks = &.{
            "@distinct(resolution_code,'denied') OR (authorized=0 AND attempt_ordinal=0)",
            "(attempt_ordinal=0 AND attempt_timeout_ms IS NULL) OR (attempt_ordinal=1 AND attempt_timeout_ms IS NOT NULL)",
            "(resolution_code IS NULL AND resolution_content_id IS NULL AND acceptance_position IS NULL) OR " ++
                "(resolution_code IS NOT NULL AND resolution_content_id IS NOT NULL AND acceptance_position IS NOT NULL)",
            "(attempt_ordinal=1)=(attempt_at IS NOT NULL)",
            "(authorized=1)=(decided_at IS NOT NULL)",
            "(resolution_code IS NULL)=(resolved_at IS NULL)",
        },
    },
    .{
        .name = "permission_decision_command",
        .columns = &.{
            .{ .name = "command_key", .type = .{ .text = null } },
            .{ .name = "action_id", .type = .{ .text = .{ .min = 1, .max = 20 } }, .check = "@charset(action_id,'0-9')" },
            .{ .name = "decision", .type = .{ .tag = &.{ "allow_once", "deny" } } },
        },
        .primary_key = &.{"command_key"},
        .foreign_keys = &.{references("command_key", "core_command", command_reference)},
        .without_rowid = true,
    },
};

pub const indexes = [_]Index{
    .{ .name = "session_obligation_parent", .table = "session", .columns = &.{ "parent_ref", "obligation_since", "session_ref" }, .where = "obligation_since IS NOT NULL" },
    .{ .name = "session_forward_owed_message", .table = "session_forward", .columns = &.{ "target_ref", "message_delivered" } },
    .{ .name = "session_workspace_list", .table = "session", .columns = &.{ "workspace_digest", "created_seq" } },
    .{ .name = "message_admission_sent", .table = "message_admission", .columns = &.{ "sender_session_ref", "sender_position" }, .unique = true, .where = "sender_session_ref IS NOT NULL" },
    .{ .name = "turn_one_active_per_session", .table = "turn", .columns = &.{"session_ref"}, .unique = true, .where = "outcome_code IS NULL" },
    .{ .name = "turn_tool_continuation", .table = "turn", .columns = &.{"operation_id"}, .where = "outcome_code IS NULL AND continuation_operation_id=operation_id" },
    .{ .name = "message_admission_session_order", .table = "message_admission", .columns = &.{ "session_ref", "turn_id", "admission_id" } },
    .{ .name = "message_admission_pending", .table = "message_admission", .columns = &.{ "admission_id", "session_ref" }, .where = "turn_id IS NULL" },
    .{ .name = "message_admission_session_pending", .table = "message_admission", .columns = &.{ "session_ref", "admission_id" }, .where = "turn_id IS NULL" },
    .{ .name = "message_admission_person", .table = "message_admission", .columns = &.{ "session_ref", "admission_position" }, .where = "sender_session_ref IS NULL" },
    .{ .name = "message_admission_unpositioned", .table = "message_admission", .columns = &.{"session_ref"}, .where = "admission_position IS NULL" },
    .{ .name = "message_admission_position", .table = "message_admission", .columns = &.{ "session_ref", "admission_position" } },
    .{ .name = "core_command_target_order", .table = "core_command", .columns = &.{ "target", "kind", "command_seq" } },
    // A content's owner in a Full report (`report.full_revisions`): its
    // first revision, since each key ends in the primary key's revision.
    .{ .name = "session_revision_instructions", .table = "session_revision", .columns = &.{ "session_ref", "instructions_content_id" } },
    .{ .name = "session_revision_output_schema", .table = "session_revision", .columns = &.{ "session_ref", "output_schema_content_id" } },
    .{ .name = "session_stop_exclusion", .table = "session_stop", .columns = &.{ "session_ref", "admission_cutoff", "position" } },
    .{ .name = "session_stop_unpositioned", .table = "session_stop", .columns = &.{"session_ref"}, .where = "position IS NULL" },
    .{ .name = "session_stop_position", .table = "session_stop", .columns = &.{ "session_ref", "position" } },
    .{ .name = "session_stop_turn", .table = "session_stop", .columns = &.{"selected_turn_id"} },
    .{ .name = "session_parent", .table = "session", .columns = &.{"parent_ref"}, .where = "parent_ref IS NOT NULL" },
    // The Host's next owed stop, skipping settled rows.
    .{ .name = "session_stop_open", .table = "session_stop_owed", .columns = &.{ "settled", "child_ref" } },
    // The Host's next owed ending, skipping settled and feed-only rows.
    .{ .name = "session_forward_message", .table = "session_forward", .columns = &.{ "message_delivered", "source_id" } },
    .{ .name = "session_forward_open", .table = "session_forward", .columns = &.{"forward_id"}, .where = "position IS NULL" },
    .{ .name = "session_forward_feed", .table = "session_forward", .columns = &.{ "target_ref", "position" } },
    .{ .name = "action_operation_session_order", .table = "action_operation", .columns = &.{ "session_ref", "action_id" } },
    .{ .name = "action_operation_sender_handle", .table = "action_operation", .columns = &.{"sender_handle"}, .unique = true, .where = "sender_handle IS NOT NULL" },
    .{ .name = "action_operation_acceptance", .table = "action_operation", .columns = &.{ "session_ref", "acceptance_position" } },
    // Results walk it (`report.full_results`): the predicate holds exactly
    // for a resolved Action (action_operation's CHECK).
    .{ .name = "action_operation_session_results", .table = "action_operation", .columns = &.{ "session_ref", "parent_operation_id", "acceptance_position" }, .where = "acceptance_position IS NOT NULL" },
    .{ .name = "action_operation_approval", .table = "action_operation", .columns = &.{ "session_ref", "approval_position" }, .where = "approval_position IS NOT NULL" },
    .{ .name = "action_operation_executable", .table = "action_operation", .columns = &.{"action_id"}, .where = "authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0" },
    .{ .name = "action_operation_unresolved_attempt", .table = "action_operation", .columns = &.{"action_id"}, .where = "resolution_code IS NULL AND attempt_ordinal=1" },
    .{ .name = "action_operation_indeterminate", .table = "action_operation", .columns = &.{ "session_ref", "parent_operation_id", "call_ordinal" }, .where = "resolution_code='indeterminate'" },
    // Calls walk it (`report.full_calls`).
    .{ .name = "model_tool_call_session_order", .table = "model_tool_call", .columns = &.{ "session_ref", "operation_id", "call_ordinal" } },
    // Results walk it: the predicate holds exactly for a rejected call
    // (model_tool_call's CHECK).
    .{ .name = "model_tool_call_session_results", .table = "model_tool_call", .columns = &.{ "session_ref", "operation_id", "acceptance_position" }, .where = "acceptance_position IS NOT NULL" },
    .{ .name = "model_tool_call_acceptance", .table = "model_tool_call", .columns = &.{ "session_ref", "acceptance_position" }, .where = "acceptance_position IS NOT NULL" },
    .{ .name = "model_operation_retry_due", .table = "model_operation", .columns = &.{ "retry_due_at_ms", "operation_id" }, .where = "resolution_code IS NULL AND " ++ retry_allowance_open_sql },
    .{ .name = "model_operation_retry_exhausted", .table = "model_operation", .columns = &.{"operation_id"}, .where = retry_exhausted_sql },
    .{ .name = "model_operation_session_history", .table = "model_operation", .columns = &.{ "session_ref", "operation_id" } },
    .{ .name = "model_operation_turn_history", .table = "model_operation", .columns = &.{ "turn_id", "operation_id" } },
    // Every Operation by admission, whatever its outcome: request history
    // places each earlier Operation's effort boundary (codec /2).
    .{ .name = "session_change_refused_operation", .table = "session_change", .columns = &.{ "refused_operation_id", "session_ref", "revision" } },
    .{ .name = "model_operation_effort_source", .table = "model_operation", .columns = &.{ "operation_id", "session_ref", "effort_source_revision" }, .unique = true },
    .{ .name = "model_operation_admission", .table = "model_operation", .columns = &.{ "session_ref", "admission_position" } },
    .{ .name = "model_operation_context_history", .table = "model_operation", .columns = &.{ "session_ref", "admission_position" }, .where = oneOf("resolution_code", &accepted_resolutions) },
    .{ .name = "model_operation_compaction_bases", .table = "model_operation", .columns = &.{ "session_ref", "admission_position" }, .where = "purpose=1 AND " ++ resolutionIs("resolution_code", .compacted) },
    .{ .name = "conversation_entry_history", .table = "conversation_entry", .columns = &.{ "session_ref", "session_position" } },
    .{ .name = "model_output_history", .table = "model_output_item", .columns = &.{ "session_ref", "session_position" } },
    .{ .name = "model_output_call_history", .table = "model_output_item", .columns = &.{ "session_ref", "session_position" }, .where = "item_kind=3" },
    .{ .name = "model_output_hosted_history", .table = "model_output_item", .columns = &.{ "session_ref", "session_position" }, .where = "item_kind=5" },
    .{ .name = "model_output_compaction_history", .table = "model_output_item", .columns = &.{ "session_ref", "session_position" }, .where = "item_kind=4" },
    .{ .name = "model_output_compaction_anchor", .table = "model_output_item", .columns = &.{ "operation_id", "item_ordinal" }, .where = "item_kind=4" },
    .{ .name = "turn_session_latest", .table = "turn", .columns = &.{ "session_ref", "turn_id DESC" } },
    .{ .name = "turn_unpositioned", .table = "turn", .columns = &.{"session_ref"}, .where = "(outcome_code IS NULL)!=(outcome_position IS NULL)" },
    .{ .name = "turn_outcome_position", .table = "turn", .columns = &.{ "session_ref", "outcome_position" } },
};

/// Whether `table`'s rows belong to Sessions: it has a `session_ref` or a
/// `sender_session_ref`, except the command logs whose `session_ref` is the
/// target text a command named, which need not be a Session (an invalid or
/// unknown target is recorded with its rejection). The tests' touch oracle
/// watches exactly these tables.
pub fn carriesSessions(comptime table: []const u8) bool {
    return comptime session_ownership.get(table) orelse @compileError("schema: no table named " ++ table);
}

// Compute once, rather than rescanning every table for every touch-oracle
// assertion as the schema grows. This map is used only at comptime.
const session_ownership = std.StaticStringMap(bool).initComptime(blk: {
    var entries: [tables.len]struct { []const u8, bool } = undefined;
    for (tables, &entries) |table, *entry| entry.* = .{ table.name, tableCarriesSessions(table) };
    break :blk entries;
});

/// The columns that name a Session, in the order `sessionColumns` lists them.
pub const session_column_names = [_][]const u8{ "session_ref", "sender_session_ref" };

fn tableCarriesSessions(comptime table: Table) bool {
    if (std.mem.eql(u8, table.name, "model_interruption_command")) return false;
    for (table.columns) |column| if (contains(&session_column_names, column.name)) return true;
    return false;
}

/// Whether `table` has `column` only on engines other than `dialect`.
pub fn lacks(comptime dialect: rsql.Dialect, comptime table: []const u8, comptime column: []const u8) bool {
    comptime {
        @setEvalBranchQuota(10_000);
        for (tables) |candidate| if (std.mem.eql(u8, candidate.name, table)) {
            for (candidate.columns) |each| if (std.mem.eql(u8, each.name, column)) return !each.engines.on(dialect);
        };
        return false;
    }
}

/// Whether `table` has a column named `column`.
pub fn hasColumn(comptime table: []const u8, comptime column: []const u8) bool {
    comptime {
        @setEvalBranchQuota(10_000);
        for (tables) |candidate| {
            if (!std.mem.eql(u8, candidate.name, table)) continue;
            for (candidate.columns) |each| if (std.mem.eql(u8, each.name, column)) return true;
            return false;
        }
        @compileError("schema: no table named " ++ table);
    }
}

/// The columns of `table` that name a Session: `session_ref`, then
/// `sender_session_ref`, those it has.
pub fn sessionColumns(comptime table: []const u8) []const []const u8 {
    comptime {
        var columns: []const []const u8 = &.{};
        for (session_column_names) |column| {
            if (hasColumn(table, column)) columns = columns ++ .{column};
        }
        return columns;
    }
}

/// The columns of `table` its second Session reads too (`ReadBy.both`):
/// none unless it names two Sessions.
pub fn readByBoth(comptime table: []const u8) []const []const u8 {
    comptime {
        for (tables) |candidate| {
            if (!std.mem.eql(u8, candidate.name, table)) continue;
            var names: []const []const u8 = &.{};
            for (candidate.columns) |column| if (column.read_by == .both) {
                names = names ++ .{column.name};
            };
            if (names.len != 0 and sessionColumns(table).len != 2) @compileError("schema: only a table that names two Sessions reads a column by both: " ++ table);
            return names;
        }
        @compileError("schema: no table named " ++ table);
    }
}

/// Whether `table`'s column `column` may hold NULL.
pub fn isNullable(comptime table: []const u8, comptime column: []const u8) bool {
    comptime {
        for (tables) |candidate| {
            if (!std.mem.eql(u8, candidate.name, table)) continue;
            for (candidate.columns) |each| if (std.mem.eql(u8, each.name, column)) return each.nullable;
            @compileError("schema: no column " ++ column ++ " in " ++ table);
        }
        @compileError("schema: no table named " ++ table);
    }
}

/// The column sets that identify one row of `table`: its primary key, its
/// unique constraints, and its unique indexes without a WHERE (a partial
/// index identifies rows only under its predicate).
pub fn keys(comptime table: []const u8) []const []const []const u8 {
    comptime {
        for (tables) |candidate| {
            if (!std.mem.eql(u8, candidate.name, table)) continue;
            var found: []const []const []const u8 = &.{candidate.primary_key};
            found = found ++ candidate.uniques;
            for (indexes) |index| {
                if (index.unique and index.where == null and std.mem.eql(u8, index.table, table)) found = found ++ .{index.columns};
            }
            return found;
        }
        @compileError("schema: no table named " ++ table);
    }
}

/// The branches rendering every object takes, which whichever statement
/// first asks `hasIndex` spends, now that each CHECK and predicate is also
/// parsed (`expression`). The unit test binary's build failed at
/// 30,000 per object (measured); this is four times that. A quota
/// only raises the evaluation's limit, so a statement whose own quota is
/// larger adds this to it (`rsql.renderStatement`).
pub const objects_quota = 120_000 * (tables.len + indexes.len);

/// Whether the schema has an index named `name`.
pub fn hasIndex(comptime name: []const u8) bool {
    comptime {
        @setEvalBranchQuota(objects_quota);
        for (objects(.sqlite)) |object| if (object.kind == .index and std.mem.eql(u8, object.name, name)) return true;
        return false;
    }
}

// Cache the DDL's names once; checking every forceable catalog name must
// not regenerate every table's DDL for each index.
const mysql_index_names: []const []const u8 = blk: {
    @setEvalBranchQuota(objects_quota);
    var names: []const []const u8 = &.{};
    for (objects(.mysql)) |object| if (object.kind == .index) {
        names = names ++ .{object.name};
    };
    break :blk names;
};

/// Whether MySQL's DDL has this named index on real columns. A lowered
/// partial index cannot serve a query on its original prefix: forcing it
/// would replace a lookup with a full index scan.
pub fn mysqlCanForceIndex(comptime name: []const u8) bool {
    comptime {
        @setEvalBranchQuota(objects_quota);
        return canForceMysqlIndex(&tables, &indexes, name) and contains(mysql_index_names, name);
    }
}

fn canForceMysqlIndex(comptime every: []const Table, comptime all_indexes: []const Index, comptime name: []const u8) bool {
    for (all_indexes) |index| {
        if (!std.mem.eql(u8, index.name, name)) continue;
        if (mysqlIndexForm(index)) |form| if (form != .plain_unique) return false;
        for (every) |table| {
            if (!std.mem.eql(u8, table.name, index.table)) continue;
            if (!table.engines.on(.mysql)) return false;
            for (index.columns) |part| {
                const column_name = indexColumn(part).name;
                const found = for (table.columns) |column| {
                    if (std.mem.eql(u8, column.name, column_name)) break column.engines.on(.mysql);
                } else false;
                if (!found) return false;
            }
            return index.columns.len != 0;
        }
        return false;
    }
    return false;
}

/// The DDL that creates every table, then every index.
pub fn ddl(comptime dialect: rsql.Dialect) [:0]const u8 {
    return comptime blk: {
        @setEvalBranchQuota(objects_quota);
        var text: []const u8 = "";
        for (objects(dialect)) |object| text = text ++ object.sql ++ ";\n";
        const terminated = text ++ "\x00";
        break :blk terminated[0..text.len :0];
    };
}

/// The tables of `all` on `dialect`, each with only its columns there.
fn onEngine(comptime all: []const Table, comptime dialect: rsql.Dialect) []const Table {
    comptime {
        var result: []const Table = &.{};
        for (all) |table| if (table.engines.on(dialect)) {
            var columns: []const Column = &.{};
            for (table.columns) |column| if (column.engines.on(dialect)) {
                columns = columns ++ .{column};
            };
            var kept = table;
            kept.columns = columns;
            result = result ++ .{kept};
        };
        return result;
    }
}

/// `foreign_key`: only on MySQL (`mysqlObjects`).
pub const Object = struct { kind: enum { table, index, foreign_key }, name: []const u8, sql: []const u8 };

/// Every table and named index, each with the statement that creates it,
/// and on MySQL the foreign keys `mysqlObjects` adds after them.
pub fn objects(comptime dialect: rsql.Dialect) []const Object {
    return comptime blk: {
        @setEvalBranchQuota(objects_quota);
        if (dialect == .mysql) break :blk switch (mysqlObjects(&tables, &indexes)) {
            .refused => |message| @compileError(message),
            .objects => |result| result,
        };
        var result: []const Object = &.{};
        for (onEngine(&tables, .sqlite)) |table| result = result ++ .{Object{ .kind = .table, .name = table.name, .sql = createTable(table) }};
        for (indexes) |index| result = result ++ .{Object{ .kind = .index, .name = index.name, .sql = createIndex(index) }};
        break :blk result;
    };
}

/// What every MySQL message on a Store sets before its statements: the
/// collation the DDL's keys compare in, a strict `sql_mode` with
/// ONLY_FULL_GROUP_BY and NO_BACKSLASH_ESCAPES, and `@list`'s length.
/// The engine prefixes each COM_QUERY with them (`engine/mysql_open.zig`).
pub const mysql_session = [_][:0]const u8{
    "SET NAMES utf8mb4 COLLATE utf8mb4_0900_bin",
    "SET SESSION sql_mode='ONLY_FULL_GROUP_BY,STRICT_ALL_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION,NO_BACKSLASH_ESCAPES'",
    // `@list` of a Session's tool names whole: MySQL's default cuts at 1024.
    std.fmt.comptimePrint("SET SESSION group_concat_max_len={d}", .{tool_name.max_names_bytes}),
    // Reads after a COMMIT in the same message (`Mysql.queueCommit`) run
    // in autocommit, whatever the server's default.
    "SET SESSION autocommit=1",
};

const MysqlObjects = union(enum) { refused: []const u8, objects: []const Object };

/// The MySQL 8.4 DDL of `all` and `all_indexes`, or why it has none.
/// Each table is InnoDB in utf8mb4_0900_bin, with each column typed by
/// `mysqlColumnType` and every key, CHECK and foreign key at table level:
/// MySQL ignores a column's inline REFERENCES, and refuses a column CHECK
/// that names another column. A foreign key to a table created later
/// (the turn and admission cycle) is an ALTER TABLE after every table and
/// index. Each index takes its `mysqlIndexForm`.
fn mysqlObjects(comptime every: []const Table, comptime all_indexes: []const Index) MysqlObjects {
    comptime {
        @setEvalBranchQuota(50_000 * (every.len + all_indexes.len));
        const all = onEngine(every, .mysql);
        var result: []const Object = &.{};
        var later: []const Object = &.{};
        for (all, 0..) |table, position| {
            var lines: []const []const u8 = &.{};
            var checks: []const []const u8 = &.{};
            for (table.columns) |column| {
                const column_type = switch (mysqlColumnType(all, all_indexes, table, column)) {
                    .refused => |message| return .{ .refused = message },
                    .type => |found| found,
                };
                lines = lines ++ .{" " ++ column.name ++ " " ++ column_type.name ++ (if (column.nullable) "" else " NOT NULL") ++
                    (if (column.default) |value| " DEFAULT " ++ value else "")};
                if (columnCheck(column)) |check| checks = checks ++ .{check};
            }
            for (all_indexes) |index| if (std.mem.eql(u8, index.table, table.name) and mysqlIndexForm(index) == .leading) {
                const lead = indexColumn(index.columns[0]).name;
                const lead_type = switch (mysqlColumnType(all, all_indexes, table, columnNamed(table, lead))) {
                    .refused => |message| return .{ .refused = message },
                    .type => |found| found,
                };
                lines = lines ++ .{" " ++ leadingColumn(index) ++ " " ++ lead_type.name ++ " GENERATED ALWAYS AS (" ++ leadingValue(all, index) ++ ") STORED"};
            };
            var keys_of: []const []const []const u8 = &.{table.primary_key};
            keys_of = keys_of ++ table.uniques;
            for (table.foreign_keys) |key| keys_of = keys_of ++ .{key.columns};
            for (all_indexes) |index| if (std.mem.eql(u8, index.table, table.name)) {
                var names: []const []const u8 = &.{};
                for (index.columns) |column| names = names ++ .{indexColumn(column).name};
                keys_of = keys_of ++ .{names};
            };
            for (keys_of) |key| if (mysqlKeyError(all, all_indexes, table, key)) |message| return .{ .refused = message };
            lines = lines ++ .{" PRIMARY KEY(" ++ list(table.primary_key) ++ ")"};
            for (table.uniques) |unique| lines = lines ++ .{" UNIQUE(" ++ list(unique) ++ ")"};
            for (table.foreign_keys) |key| {
                const clause = "FOREIGN KEY(" ++ list(key.columns) ++ ") " ++ referenceClause(key);
                if (tablePosition(all, key.references) <= position) {
                    lines = lines ++ .{" " ++ clause};
                } else later = later ++ .{Object{ .kind = .foreign_key, .name = table.name ++ "(" ++ list(key.columns) ++ ")", .sql = "ALTER TABLE " ++ table.name ++ " ADD " ++ clause }};
            }
            for (checks ++ table.checks) |check| lines = lines ++ .{" CHECK(" ++ expression(.mysql, table, check) ++ ")"};
            result = result ++ .{Object{ .kind = .table, .name = table.name, .sql = "CREATE TABLE " ++ table.name ++ "(\n" ++ joinLines(lines) ++
                "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin" }};
        }
        for (all_indexes) |index| result = result ++ .{Object{ .kind = .index, .name = index.name, .sql = createMysqlIndex(all, index) }};
        return .{ .objects = result ++ later };
    }
}

/// The catalog of a MySQL Store as its open reads it (D203): one line per
/// table, column, index and foreign key, and each table's count of
/// CHECKs, from information_schema for the database `database` names (an
/// SQL expression, such as `DATABASE()`). It holds what the schema value
/// decides and leaves out what MySQL names or spells itself: CHECK and
/// expression texts, which servers normalise differently, and the names
/// of CHECKs, foreign keys and server-generated keys. Forceable indexes
/// include their canonical names: statements depend on those names, not
/// just equivalent definitions. This admission digest is not stored or
/// pinned by Store format; `digest()` covers bootstrap SQL separately.
/// MySQL 8.4 STATISTICS plan domain: TABLE_NAME and forceable INDEX_NAME identify
/// the key; NON_UNIQUE, ordered COLUMN_NAME (SEQ_IN_INDEX), COLLATION,
/// SUB_PART, INDEX_TYPE, PACKED and IS_VISIBLE describe its usable shape.
/// Visibility applies to every index: canonical DDL makes all visible, and
/// hiding even an unhinted key weakens a Store plan. NULLABLE is derived
/// from the checked COLUMNS; functional parts are nullable. EXPRESSION's
/// presence is the `*` part; its server-normalized text is not a forced-plan
/// dependency, since mysqlCanForceIndex excludes every functional key.
/// TABLE_CATALOG is always def; TABLE_SCHEMA/INDEX_SCHEMA only locate the
/// database. Only CARDINALITY (estimates), COMMENT (server status prose)
/// and INDEX_COMMENT (DBA prose) are ignored mutable index metadata: none
/// changes the key's definition or availability to a statement.
/// Each value is cast to binary, so the lines compare as bytes whatever
/// information_schema's collations.
pub fn catalogSql(comptime database: []const u8) [:0]const u8 {
    return comptime blk: {
        @setEvalBranchQuota(objects_quota);
        var forced: []const u8 = "FALSE";
        for (indexes) |index| if (mysqlCanForceIndex(index.name)) {
            forced = forced ++ " OR (" ++ binary("TABLE_NAME") ++ "='" ++ index.table ++ "' AND " ++ binary("INDEX_NAME") ++ "='" ++ index.name ++ "')";
        };
        const in = "information_schema.";
        const text = "SELECT CONCAT('t '," ++ binary("TABLE_NAME") ++ ",' '," ++ binary("ENGINE") ++ ",' '," ++ binary("TABLE_COLLATION") ++ ") FROM " ++ in ++
            "TABLES WHERE TABLE_SCHEMA=" ++ database ++ " AND TABLE_TYPE='BASE TABLE'" ++
            " UNION ALL SELECT CONCAT('c '," ++ binary("TABLE_NAME") ++ ",' '," ++ binary("COLUMN_NAME") ++ ",' '," ++ binary("COLUMN_TYPE") ++ ",' '," ++ binary("IS_NULLABLE") ++
            ",' '," ++ binary("COALESCE(COLLATION_NAME,'-')") ++ ",IF(EXTRA IN ('STORED GENERATED','VIRTUAL GENERATED'),' generated','')) FROM " ++ in ++
            "COLUMNS WHERE TABLE_SCHEMA=" ++ database ++
            " UNION ALL SELECT CONCAT('i '," ++ binary("TABLE_NAME") ++ ",IF(MAX(NON_UNIQUE)=0,' u ',' n '),GROUP_CONCAT(" ++ binary("COALESCE(COLUMN_NAME,'*')") ++
            ",IF(SUB_PART IS NULL,'',CONCAT('(',SUB_PART,')')),CASE COLLATION WHEN 'A' THEN '' WHEN 'D' THEN ' desc' ELSE ' unordered' END," ++
            "IF(PACKED IS NULL,'',CONCAT(' packed='," ++ binary("PACKED") ++ ")) ORDER BY SEQ_IN_INDEX SEPARATOR ','),' '," ++ binary("MAX(INDEX_TYPE)") ++
            ",' '," ++ binary("MAX(IS_VISIBLE)") ++ ",IF(" ++ forced ++ ",CONCAT(' '," ++ binary("INDEX_NAME") ++ "),'')) FROM " ++ in ++ "STATISTICS WHERE TABLE_SCHEMA=" ++ database ++ " GROUP BY TABLE_NAME,INDEX_NAME" ++
            " UNION ALL SELECT CONCAT('f '," ++ binary("TABLE_NAME") ++ ",' ',GROUP_CONCAT(" ++ binary("COLUMN_NAME") ++ " ORDER BY ORDINAL_POSITION SEPARATOR ','),' '," ++
            binary("MAX(REFERENCED_TABLE_NAME)") ++ ",' ',GROUP_CONCAT(" ++ binary("REFERENCED_COLUMN_NAME") ++ " ORDER BY ORDINAL_POSITION SEPARATOR ',')) FROM " ++ in ++
            "KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=" ++ database ++ " AND REFERENCED_TABLE_NAME IS NOT NULL GROUP BY TABLE_NAME,CONSTRAINT_NAME" ++
            " UNION ALL SELECT CONCAT('k '," ++ binary("TABLE_NAME") ++ ",' ',COUNT(*)) FROM " ++ in ++ "TABLE_CONSTRAINTS WHERE CONSTRAINT_SCHEMA=" ++ database ++
            " AND CONSTRAINT_TYPE='CHECK' GROUP BY TABLE_NAME";
        const terminated = text ++ "\x00";
        break :blk terminated[0..text.len :0];
    };
}

fn binary(comptime column: []const u8) []const u8 {
    return "CAST(" ++ column ++ " AS BINARY)";
}

/// One line's share of a catalog digest. A digest is the wrapping sum of
/// its lines' shares, so it does not depend on the order rows arrive in.
pub fn catalogLineDigest(line: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(line);
}

/// The digest of the catalog `catalogSql` reads from a MySQL Store at
/// schema_version, derived from the schema value.
pub fn catalogDigest() u64 {
    return comptime blk: {
        @setEvalBranchQuota(objects_quota);
        var sum: u64 = 0;
        for (catalogLines(&tables, &indexes)) |line| sum +%= catalogLineDigest(line);
        break :blk sum;
    };
}

/// The lines `catalogSql` returns for a database made by
/// `mysqlObjects(every, all_indexes)`, in no particular order. An index
/// part MySQL computes is `*`. InnoDB adds an index for a foreign key
/// that no index leads with (MySQL 8.4 manual, FOREIGN KEY Constraints),
/// and drops it when a later index does.
fn catalogLines(comptime every: []const Table, comptime all_indexes: []const Index) []const []const u8 {
    comptime {
        @setEvalBranchQuota(50_000 * (every.len + all_indexes.len));
        const all = onEngine(every, .mysql);
        const collation = "utf8mb4_0900_bin";
        var lines: []const []const u8 = &.{};
        for (all) |table| {
            lines = lines ++ .{"t " ++ table.name ++ " InnoDB " ++ collation};
            var checks: usize = table.checks.len;
            for (table.columns) |column| {
                const found = mysqlColumnType(all, all_indexes, table, column).type;
                lines = lines ++ .{"c " ++ table.name ++ " " ++ column.name ++ " " ++ catalogType(found.name) ++ (if (column.nullable) " YES " else " NO ") ++ catalogCollation(found.name)};
                if (columnCheck(column) != null) checks += 1;
            }
            if (checks != 0) lines = lines ++ .{std.fmt.comptimePrint("k {s} {d}", .{ table.name, checks })};
            // Each index as its parts: a column, `*`, then ` desc` if descending.
            var parts: []const []const []const u8 = &.{table.primary_key};
            for (table.uniques) |unique| parts = parts ++ .{unique};
            var flags: []const bool = &.{true};
            var forced_names: []const []const u8 = &.{""};
            for (table.uniques) |_| {
                flags = flags ++ .{true};
                forced_names = forced_names ++ .{""};
            }
            for (all_indexes) |index| if (std.mem.eql(u8, index.table, table.name)) {
                var names: []const []const u8 = &.{};
                for (index.columns, 0..) |column, position| {
                    const part = indexColumn(column);
                    const order = if (part.order.len == 0) "" else " desc";
                    names = names ++ .{switch (mysqlIndexForm(index) orelse MysqlIndexForm.plain_unique) {
                        .plain_unique => part.name ++ order,
                        .leading => (if (position == 0) leadingColumn(index) else part.name) ++ order,
                        .unique_when => "*" ++ order,
                    }};
                    if (mysqlIndexForm(index) == .leading and position == 0) {
                        const found = mysqlColumnType(all, all_indexes, table, columnNamed(table, part.name)).type;
                        lines = lines ++ .{"c " ++ table.name ++ " " ++ leadingColumn(index) ++ " " ++ catalogType(found.name) ++ " YES " ++ catalogCollation(found.name) ++ " generated"};
                    }
                }
                parts = parts ++ .{names};
                flags = flags ++ .{index.unique};
                forced_names = forced_names ++ .{if (canForceMysqlIndex(every, all_indexes, index.name)) " " ++ index.name else ""};
            };
            var added: usize = 0;
            for (table.foreign_keys) |key| {
                lines = lines ++ .{"f " ++ table.name ++ " " ++ list(key.columns) ++ " " ++ key.references ++ " " ++ list(key.referenced)};
                const led = for (parts) |index_parts| {
                    if (index_parts.len >= key.columns.len and eqlList(index_parts[0..key.columns.len], key.columns)) break true;
                } else false;
                if (!led) {
                    parts = parts ++ .{key.columns};
                    flags = flags ++ .{false};
                    forced_names = forced_names ++ .{""};
                    added += 1;
                }
            }
            for (parts, flags, forced_names, 0..) |index_parts, unique, forced_name, position| {
                // InnoDB keeps no index it added for a foreign key when a
                // longer one it added for another key leads with it.
                const implicit = parts[parts.len - added ..];
                const covered = position >= parts.len - added and for (implicit) |other| {
                    if (other.len > index_parts.len and eqlList(other[0..index_parts.len], index_parts)) break true;
                } else false;
                if (!covered) lines = lines ++ .{"i " ++ table.name ++ (if (unique) " u " else " n ") ++ list(index_parts) ++ " BTREE YES" ++ forced_name};
            }
        }
        return lines;
    }
}

/// `catalogLines` of the schema, for the live check's report.
pub fn catalogLinesForTesting() []const []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(objects_quota);
        break :blk catalogLines(&tables, &indexes);
    };
}

/// A MySQL type as information_schema's COLUMN_TYPE spells it.
fn catalogType(comptime name: []const u8) []const u8 {
    var lower: [name.len]u8 = undefined;
    for (name, &lower) |byte, *out| out.* = std.ascii.toLower(byte);
    const result = lower;
    return &result;
}

/// The collation information_schema gives a column of MySQL type `name`:
/// the table's for text, none (`-`) for numbers and bytes.
fn catalogCollation(comptime name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "VARCHAR") or std.mem.endsWith(u8, name, "TEXT")) "utf8mb4_0900_bin" else "-";
}

/// The most bytes InnoDB keys in one index, under the DYNAMIC row format
/// MySQL 8.4 defaults to.
const innodb_key_bytes = 3072;

/// Why `key`, columns of `table` that MySQL indexes together, is wider
/// than `innodb_key_bytes`, or null. Each column counts its type's
/// `key_bytes`; a `unique_when` part keys the same value as its column.
fn mysqlKeyError(comptime all: []const Table, comptime all_indexes: []const Index, comptime table: Table, comptime key: []const []const u8) ?[]const u8 {
    var bytes: usize = 0;
    for (key) |name| bytes += switch (mysqlColumnType(all, all_indexes, table, columnNamed(table, name))) {
        .refused => 0,
        .type => |found| found.key_bytes,
    };
    if (bytes <= innodb_key_bytes) return null;
    return std.fmt.comptimePrint("schema: the key {s}({s}) is {d} bytes on MySQL, past InnoDB's {d}", .{ table.name, list(key), bytes, innodb_key_bytes });
}

/// A MySQL column type, and the bytes a key on it takes at most: 8 for
/// BIGINT, 1 for TINYINT, 4 per character for utf8mb4 VARCHAR, n for
/// VARBINARY(n), and 0 for TEXT and BLOB types, which no key holds.
const MysqlType = struct { name: []const u8, key_bytes: usize };
const MysqlColumnType = union(enum) { refused: []const u8, type: MysqlType };

/// `column`'s MySQL type. A column of a foreign key takes the type of the
/// column it references. Otherwise `.int` is BIGINT, `.flag` TINYINT and
/// `.tag` VARCHAR of its longest tag; bounded `.text` and `.bytes` are
/// VARCHAR and VARBINARY of their bound when `mysqlKeyed`, else TEXT and
/// BLOB up to 65,535 bytes and LONGTEXT and LONGBLOB past it. An unbounded
/// Session column (one of `session_column_names` in a table that carries
/// Sessions) takes session.session_ref's type, because rsql's write rules
/// give it only a SessionHead's reference or a copy of one
/// (`rsql.sessionError`). Other unbounded text and bytes are LONGTEXT and
/// LONGBLOB, and refused when keyed: MySQL keys only bounded values.
fn mysqlColumnType(comptime all: []const Table, comptime all_indexes: []const Index, comptime table: Table, comptime column: Column) MysqlColumnType {
    comptime {
        for (table.foreign_keys) |key| for (key.columns, key.referenced) |name, referenced| if (std.mem.eql(u8, name, column.name)) {
            const parent = all[tablePosition(all, key.references)];
            return mysqlColumnType(all, all_indexes, parent, columnNamed(parent, referenced));
        };
        const keyed = mysqlKeyed(all, all_indexes, table, column.name);
        const octets, const text = switch (column.type) {
            .int => return .{ .type = .{ .name = "BIGINT", .key_bytes = 8 } },
            .flag => return .{ .type = .{ .name = "TINYINT", .key_bytes = 1 } },
            .tag => |values| {
                var longest: usize = 0;
                for (values) |value| longest = @max(longest, value.len);
                return .{ .type = .{ .name = std.fmt.comptimePrint("VARCHAR({d})", .{longest}), .key_bytes = 4 * longest } };
            },
            .text => |bound| .{ bound, true },
            .bytes => |bound| .{ bound, false },
        };
        if (octets) |bounds| return .{ .type = if (keyed) .{
            .name = std.fmt.comptimePrint("{s}({d})", .{ if (text) "VARCHAR" else "VARBINARY", bounds.max }),
            .key_bytes = if (text) 4 * bounds.max else bounds.max,
        } else .{
            .name = if (bounds.max <= 65_535) (if (text) "TEXT" else "BLOB") else if (text) "LONGTEXT" else "LONGBLOB",
            .key_bytes = 0,
        } };
        if (contains(&session_column_names, column.name) and tableCarriesSessions(table)) {
            const session = all[tablePosition(all, "session")];
            return mysqlColumnType(all, all_indexes, session, columnNamed(session, "session_ref"));
        }
        if (keyed) return .{ .refused = "schema: " ++ table.name ++ "." ++ column.name ++ " is in a key with no bound; MySQL keys only bounded values: give its type a .max" };
        return .{ .type = .{ .name = if (text) "LONGTEXT" else "LONGBLOB", .key_bytes = 0 } };
    }
}

/// Whether MySQL indexes `table`'s column `name` by its value: it is in
/// the table's primary key, a unique, an index's columns, or the columns
/// another table's foreign key references.
fn mysqlKeyed(comptime all: []const Table, comptime all_indexes: []const Index, comptime table: Table, comptime name: []const u8) bool {
    comptime {
        if (contains(table.primary_key, name)) return true;
        for (table.uniques) |unique| if (contains(unique, name)) return true;
        for (all_indexes) |index| if (std.mem.eql(u8, index.table, table.name)) {
            for (index.columns) |column| if (std.mem.eql(u8, indexColumn(column).name, name)) return true;
        };
        for (all) |other| for (other.foreign_keys) |key| {
            if (std.mem.eql(u8, key.references, table.name) and contains(key.referenced, name)) return true;
        };
        return false;
    }
}

/// How MySQL, which has no partial index, holds a partial one. Each is
/// derived from the index alone.
pub const MysqlIndexForm = enum {
    /// Not unique: an index whose first column is generated
    /// (`leadingColumn`), its first column's value where the predicate
    /// holds and NULL elsewhere, so a walk of one value of it skips the
    /// rows SQLite's index leaves out. Its predicate only narrowed what
    /// SQLite stores, never what it allows.
    leading,
    /// Unique, and its predicate is exactly the text `c IS NOT NULL` for
    /// one of its columns c: a plain unique index, since MySQL never finds
    /// two NULLs equal, so rows the predicate excludes never collide.
    plain_unique,
    /// Any other unique partial index: a unique index on
    /// `(CASE WHEN predicate THEN c END)` for each column c, NULL, and so
    /// never colliding, where the predicate fails.
    unique_when,
};

/// `index`'s MySQL form, or null when it has no predicate.
pub fn mysqlIndexForm(comptime index: Index) ?MysqlIndexForm {
    const where = index.where orelse return null;
    if (!index.unique) return .leading;
    for (index.columns) |column| if (std.mem.eql(u8, where, column ++ " IS NOT NULL")) return .plain_unique;
    return .unique_when;
}

/// A `leading` index's generated column on MySQL, named after the index.
fn leadingColumn(comptime index: Index) []const u8 {
    const name = index.name ++ "_lead";
    checkIdentifier(name);
    if (name.len > 64) @compileError("schema: MySQL names are at most 64 characters: " ++ name);
    return name;
}

/// The value of `leadingColumn(index)`: its first column where its
/// predicate holds, else NULL.
fn leadingValue(comptime all: []const Table, comptime index: Index) []const u8 {
    return "CASE WHEN " ++ expression(.mysql, all[tablePosition(all, index.table)], index.where.?) ++ " THEN " ++ indexColumn(index.columns[0]).name ++ " END";
}

fn createMysqlIndex(comptime all: []const Table, comptime index: Index) []const u8 {
    checkIdentifier(index.name);
    var parts: []const u8 = list(index.columns);
    if (mysqlIndexForm(index) == .leading) parts = leadingColumn(index) ++ indexColumn(index.columns[0]).order ++
        (if (index.columns.len > 1) "," ++ list(index.columns[1..]) else "");
    if (mysqlIndexForm(index) == .unique_when) {
        parts = "";
        for (index.columns, 0..) |column, position| {
            const part = indexColumn(column);
            parts = parts ++ (if (position == 0) "" else ",") ++ "(CASE WHEN " ++ expression(.mysql, all[tablePosition(all, index.table)], index.where.?) ++ " THEN " ++ part.name ++ " END)" ++ part.order;
        }
    }
    return "CREATE " ++ (if (index.unique) "UNIQUE " else "") ++ "INDEX " ++ index.name ++ " ON " ++ index.table ++ "(" ++ parts ++ ")";
}

/// An index column's name, and its order as written after it (" DESC" or "").
fn indexColumn(comptime column: []const u8) struct { name: []const u8, order: []const u8 } {
    const space = std.mem.indexOfScalar(u8, column, ' ') orelse return .{ .name = column, .order = "" };
    return .{ .name = column[0..space], .order = column[space..] };
}

/// `text`, a CHECK or index predicate on `table`, in `dialect`'s spelling,
/// once it meets a typed statement's expression rules
/// (`rsql.expressionError`), which let `length` count `table`'s `.bytes`
/// columns only.
fn expression(comptime dialect: rsql.Dialect, comptime table: Table, comptime text: []const u8) []const u8 {
    var bytes: []const []const u8 = &.{};
    for (table.columns) |column| if (column.type == .bytes) {
        bytes = bytes ++ .{column.name};
    };
    if (rsql.expressionError(text, bytes)) |message| @compileError(message ++ ": " ++ text);
    return rsql.render(dialect, text);
}

fn tablePosition(comptime all: []const Table, comptime name: []const u8) usize {
    for (all, 0..) |table, position| if (std.mem.eql(u8, table.name, name)) return position;
    @compileError("schema: no table named " ++ name);
}

fn columnNamed(comptime table: Table, comptime name: []const u8) Column {
    for (table.columns) |column| if (std.mem.eql(u8, column.name, name)) return column;
    @compileError("schema: no column " ++ name ++ " in " ++ table.name);
}

fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

fn joinLines(comptime lines: []const []const u8) []const u8 {
    var body: []const u8 = "";
    for (lines, 0..) |line, position| body = body ++ (if (position == 0) "" else ",\n") ++ line;
    return body;
}

/// FNV-1a over every statement `bootstrap` executes, in order, so changing
/// any of them without changing bootstrap_digests fails the build. FNV-1a, not
/// SHA-256: it is a fixed algorithm, and SHA-256 costs seconds of every
/// compile.
pub fn digest() u64 {
    return comptime blk: {
        var text: []const u8 = "";
        for (bootstrap_sql) |statement| text = text ++ statement ++ "\x00";
        @setEvalBranchQuota(10 * text.len + 1000);
        break :blk std.hash.Fnv1a_64.hash(text);
    };
}

const identity_sql = std.fmt.comptimePrint("PRAGMA application_id={d}", .{application_id});
const version_sql = std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version});
/// `schema_version` as store_meta's `format` row holds it.
const format_text = std.fmt.comptimePrint("{d}", .{schema_version});
/// The wire version is bound, not spliced: it has its own check on open, so
/// a wire bump still appends a format step to migrate the saved label.
/// The Store id is 16 bytes from SQLite's randomness, which it seeds from
/// the OS, in lower-case hex, as `migrations` writes it too.
pub fn sqliteMetaSeedSql() [:0]const u8 {
    return comptime blk: {
        var sql: []const u8 = "INSERT INTO store_meta(meta_key,meta_value) VALUES";
        for (metaSeed(.sqlite), 0..) |entry, index| {
            sql = sql ++ (if (index == 0) "" else ",") ++ "('" ++ @tagName(entry.key) ++ "',";
            sql = sql ++ switch (entry.value) {
                .binding => |slot| std.fmt.comptimePrint("?{d}", .{slot}),
                .literal => |value| "'" ++ value ++ "'",
                .random_id => std.fmt.comptimePrint("lower(hex(randomblob({d})))", .{store_id_bytes}),
            } ++ ")";
        }
        break :blk sql ++ "";
    };
}
const store_meta_sql = sqliteMetaSeedSql();
/// The bytes of a Store id; store_meta holds them as twice as many hex digits.
pub const store_id_bytes = 16;
const bootstrap_sql = [_][:0]const u8{ ddl(.sqlite), identity_sql, version_sql, store_meta_sql };

fn createTable(comptime table: Table) []const u8 {
    if (!table.engines.on(.sqlite)) @compileError("schema: " ++ table.name ++ " is not on SQLite");
    var lines: []const []const u8 = &.{};
    for (table.columns) |column| {
        if (column.sqlite_added) {
            if (lines.len == 0) @compileError("schema: an added column must follow an existing column");
            lines = lines[0 .. lines.len - 1] ++ .{lines[lines.len - 1] ++ "," ++ columnDefinition(table, column)};
        } else lines = lines ++ .{columnDefinition(table, column)};
    }
    if (table.primary_key.len > 1) lines = lines ++ .{" PRIMARY KEY(" ++ list(table.primary_key) ++ ")"};
    for (table.uniques) |unique| {
        if (unique.len > 1) lines = lines ++ .{" UNIQUE(" ++ list(unique) ++ ")"};
    }
    for (table.foreign_keys) |key| {
        if (key.columns.len > 1) lines = lines ++ .{" FOREIGN KEY(" ++ list(key.columns) ++ ") " ++ referenceClause(key)};
    }
    for (table.checks) |check| lines = lines ++ .{" CHECK(" ++ expression(.sqlite, table, check) ++ ")"};
    const body = joinLines(lines);
    checkIdentifier(table.name);
    return "CREATE TABLE " ++ table.name ++ "(\n" ++ body ++ "\n) STRICT" ++ (if (table.without_rowid) ", WITHOUT ROWID" else "");
}

fn columnDefinition(comptime table: Table, comptime column: Column) []const u8 {
    checkIdentifier(column.name);
    const only = &[_][]const u8{column.name};
    const primary = eqlList(table.primary_key, only);
    if (primary and column.nullable) @compileError("schema: primary key " ++ table.name ++ "." ++ column.name ++ " is nullable");
    var text: []const u8 = " " ++ column.name ++ " " ++ switch (column.type) {
        .int, .flag => "INTEGER",
        .text, .tag => "TEXT",
        .bytes => "BLOB",
    };
    if (primary) text = text ++ " PRIMARY KEY";
    // Also on a key: SQLite lets a rowid table's non-integer key be NULL.
    if (!column.nullable) text = text ++ " NOT NULL";
    if (column.default) |value| text = text ++ " DEFAULT " ++ value;
    for (table.uniques) |unique| {
        if (eqlList(unique, only)) text = text ++ " UNIQUE";
    }
    for (table.foreign_keys) |key| {
        if (eqlList(key.columns, only)) text = text ++ " " ++ referenceClause(key);
    }
    if (columnCheck(column)) |check| text = text ++ " CHECK(" ++ expression(.sqlite, table, check) ++ ")";
    return text;
}

/// The column's CHECK in Rui SQL: its type's bound, then its own check.
fn columnCheck(comptime column: Column) ?[]const u8 {
    const name = column.name;
    const bound: ?[]const u8 = switch (column.type) {
        .int => null,
        .flag => name ++ " IN (0,1)",
        .text => |octets| if (octets) |bounds| lengthBound("@octets(" ++ name ++ ")", bounds) else null,
        .bytes => |octets| if (octets) |bounds| lengthBound("length(" ++ name ++ ")", bounds) else null,
        .tag => |values| oneOf(name, values),
    };
    const type_bound = bound orelse return column.check;
    const body = if (column.check) |check| type_bound ++ " AND " ++ check else type_bound;
    if (!column.nullable) return body;
    return name ++ " IS NULL OR " ++ (if (column.check == null) body else "(" ++ body ++ ")");
}

fn lengthBound(comptime length: []const u8, comptime bounds: Octets) []const u8 {
    if (bounds.min == bounds.max) return std.fmt.comptimePrint("{s}={d}", .{ length, bounds.max });
    if (bounds.min == 0) return std.fmt.comptimePrint("{s}<={d}", .{ length, bounds.max });
    return std.fmt.comptimePrint("{s} BETWEEN {d} AND {d}", .{ length, bounds.min, bounds.max });
}

fn referenceClause(comptime key: ForeignKey) []const u8 {
    return "REFERENCES " ++ key.references ++ "(" ++ list(key.referenced) ++ ")";
}

fn createIndex(comptime index: Index) []const u8 {
    checkIdentifier(index.name);
    return "CREATE " ++ (if (index.unique) "UNIQUE " else "") ++ "INDEX " ++ index.name ++ " ON " ++ index.table ++ "(" ++ list(index.columns) ++ ")" ++
        (if (index.where) |where| " WHERE " ++ expression(.sqlite, tables[tablePosition(&tables, index.table)], where) else "");
}

fn checkIdentifier(comptime name: []const u8) void {
    if (rsql.identifierError(name, rsql.reserved_names_checked)) |message| @compileError(message);
}

fn list(comptime names: []const []const u8) []const u8 {
    var text: []const u8 = "";
    for (names, 0..) |name, position| text = text ++ (if (position == 0) "" else ",") ++ name;
    return text;
}

fn eqlList(comptime a: []const []const u8, comptime b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

pub fn bootstrap(database: *c.sqlite3, selector: []const u8) !void {
    try sqlite.exec(database, "BEGIN EXCLUSIVE");
    errdefer sqlite.rollback(database);
    try sqlite.exec(database, ddl(.sqlite));
    try sqlite.exec(database, identity_sql);
    try sqlite.exec(database, version_sql);
    const statement = try sqlite.prepare(database, store_meta_sql);
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, wire_version);
    try sqlite.bindText(statement, 2, selector);
    try sqlite.expectDone(statement);
    try sqlite.exec(database, "COMMIT");
}

/// Told when `openExisting` begins migrating a Store, with the format it
/// moves from, and when the migration commits. The backup a migration
/// writes first is as large as the Store, so a caller waiting on the open
/// can learn why it takes long.
pub const MigrationNotice = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, event: Event) void,

    pub const Event = union(enum) { begin: u32, end };
};

/// Opens a Store of this application at schema_version, or moves one at a
/// format from migration_baseline on to it first (`migrate`).
pub fn openExisting(io: std.Io, database: *c.sqlite3, selector: []const u8, identity_mismatch: ?*IdentityMismatch, notice: ?MigrationNotice) !void {
    if (try sqlite.pragmaInt(database, "PRAGMA application_id") != application_id) return error.WrongStoreIdentity;
    const found = try sqlite.pragmaInt(database, "PRAGMA user_version");
    if (found == schema_version) return validateCurrent(database, selector, identity_mismatch);
    if (found < migration_baseline or found > schema_version) return error.WrongStoreVersion;
    if (notice) |told| told.notify(told.context, .{ .begin = found });
    try migrate(io, database, selector, found, migrations[found - migration_baseline ..], identity_mismatch);
    if (notice) |told| told.notify(told.context, .end);
}

/// First writes `migrationBackup`; a Store whose backup fails is refused
/// with nothing migrated. Then, in one transaction: runs `steps`' SQLite statements on a Store at
/// format `from`, sets its format to schema_version, and commits only if
/// the Store then validates as a fresh bootstrap's would
/// (`validateCurrent`) and every foreign key holds. A Store whose
/// store_meta format is not `from` is a WrongStoreVersion, and any failure
/// leaves the Store as it was.
pub noinline fn migrate(io: std.Io, database: *c.sqlite3, selector: []const u8, from: u32, steps: []const Migration, identity_mismatch: ?*IdentityMismatch) !void {
    try migrationBackup(io, database);
    // Both outside the transaction, where PRAGMA foreign_keys takes effect.
    try sqlite.exec(database, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
    defer sqlite.exec(database, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF") catch {};
    try sqlite.exec(database, "BEGIN EXCLUSIVE");
    errdefer sqlite.rollback(database);
    var from_text: [10]u8 = undefined;
    if (!try metaEquals(database, "format", std.fmt.bufPrint(&from_text, "{d}", .{from}) catch unreachable)) return error.WrongStoreVersion;
    for (steps) |step| for (step.sqlite) |statement| try sqlite.exec(database, statement);
    {
        const violations = try sqlite.prepare(database, "PRAGMA foreign_key_check");
        defer _ = c.sqlite3_finalize(violations);
        switch (c.sqlite3_step(violations)) {
            c.SQLITE_DONE => {},
            c.SQLITE_ROW => return error.MigrationBrokeForeignKey,
            else => return error.StatementFailed,
        }
    }
    try sqlite.exec(database, version_sql);
    try sqlite.exec(database, "UPDATE store_meta SET meta_value='" ++ format_text ++ "' WHERE meta_key='format'");
    // v0.60 shipped format 60 / wire 11. Format 61 is already a forward
    // migration, so finalize its wire label without rewriting shipped steps
    // or taking another format number. Unknown labels still fail validation.
    try sqlite.exec(database, "UPDATE store_meta SET meta_value='" ++ wire_version ++ "' WHERE meta_key='wire_version' AND meta_value='11'");
    try validateCurrent(database, selector, identity_mismatch);
    try sqlite.exec(database, "COMMIT");
}

/// Before a migration, a copy of the Store at `from` beside its file: for
/// `<name>.sqlite3`, `<name>.backup`, written page by page through SQLite's
/// online backup API, so it holds the last committed state and is as large
/// as the Store. Its path is a byte shorter than the Store's, so it and its
/// journal fit wherever the Store's do. The one name per file means an
/// earlier copy is replaced and nothing else beside the Store is touched;
/// the copy's own user_version says which format it holds. The copy and
/// its directory entry are synced before the migration starts. Every
/// failure is a MigrationBackupFailed.
fn migrationBackup(io: std.Io, database: *c.sqlite3) !void {
    return writeMigrationBackup(io, database) catch |err| switch (err) {
        error.MigrationBackupFailed => err,
        else => {
            std.log.warn("Store migration backup failed: {s}", .{@errorName(err)});
            return error.MigrationBackupFailed;
        },
    };
}

const store_extension = ".sqlite3";
const backup_extension = ".backup";
comptime {
    if (backup_extension.len >= store_extension.len) @compileError("a backup's path must be shorter than its Store's");
}

fn writeMigrationBackup(io: std.Io, database: *c.sqlite3) !void {
    const path = std.mem.span(c.sqlite3_db_filename(database, "main") orelse return error.MigrationBackupFailed);
    if (!std.mem.endsWith(u8, path, store_extension)) return error.MigrationBackupFailed;
    const directory_path = std.fs.path.dirname(path) orelse return error.MigrationBackupFailed;
    // Iterable, so the handle is a real descriptor (not O_PATH) that fsync takes.
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);
    // SQLite's allocator, not a path-sized stack buffer: the Host's stack frame budget.
    const backup_text = c.sqlite3_mprintf("%.*s" ++ backup_extension, @as(c_int, @intCast(path.len - store_extension.len)), path.ptr) orelse return error.MigrationBackupFailed;
    defer c.sqlite3_free(backup_text);
    const backup = std.mem.span(backup_text);
    const backup_name = backup[directory_path.len + 1 ..];
    directory.deleteFile(io, backup_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    // The online backup API, not VACUUM INTO: the build sets
    // SQLITE_MAX_ATTACHED=0, and VACUUM INTO attaches its target.
    {
        var target: ?*c.sqlite3 = null;
        defer _ = c.sqlite3_close(target);
        if (c.sqlite3_open_v2(backup, &target, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, null) != c.SQLITE_OK)
            return error.MigrationBackupFailed;
        const copying = c.sqlite3_backup_init(target, "main", database, "main") orelse return error.MigrationBackupFailed;
        const stepped = c.sqlite3_backup_step(copying, -1);
        if (c.sqlite3_backup_finish(copying) != c.SQLITE_OK or stepped != c.SQLITE_DONE) return error.MigrationBackupFailed;
    }
    var copy = try directory.openFile(io, backup_name, .{});
    defer copy.close(io);
    try copy.sync(io);
    if (std.c.fsync(directory.handle) != 0) return error.MigrationBackupFailed;
}

/// Refuses a Store unless its tables and indexes are exactly the ones
/// bootstrap creates, each with the same CREATE text. SQLite keeps that text
/// as run, and only bootstrap and `migrate` write it, so a dropped CHECK, a
/// changed column, a migration that leaves other text than bootstrap's, or a
/// missing or extra index or trigger is a WrongStoreSchema. A
/// network engine keeps no such text: MySQL's open compares its catalog's
/// structure instead (`catalogDigest`), which sees a CHECK only by count.
/// Its caller has read user_version as schema_version, or set it.
fn validateCurrent(database: *c.sqlite3, selector: []const u8, identity_mismatch: ?*IdentityMismatch) !void {
    {
        const expected = comptime objects(.sqlite);
        const statement = try sqlite.prepare(database, "SELECT type,name,tbl_name,sql FROM sqlite_schema");
        defer _ = c.sqlite3_finalize(statement);
        var matched: usize = 0;
        rows: while (true) {
            switch (c.sqlite3_step(statement)) {
                c.SQLITE_DONE => break,
                c.SQLITE_ROW => {},
                else => return error.StatementFailed,
            }
            const kind = try columnText(statement, 0);
            if (c.sqlite3_column_type(statement, 3) == c.SQLITE_NULL) {
                // An automatic index of a key: its table's text covers it.
                if (!std.mem.eql(u8, kind, "index")) return error.WrongStoreSchema;
                for (expected) |object| {
                    if (object.kind == .table and std.mem.eql(u8, object.name, try columnText(statement, 2))) continue :rows;
                }
                return error.WrongStoreSchema;
            }
            const name = try columnText(statement, 1);
            for (expected) |object| {
                if (!std.mem.eql(u8, object.name, name)) continue;
                if (!std.mem.eql(u8, @tagName(object.kind), kind) or !std.mem.eql(u8, object.sql, try columnText(statement, 3))) return error.WrongStoreSchema;
                matched += 1;
                continue :rows;
            }
            return error.WrongStoreSchema;
        }
        if (matched != expected.len) return error.WrongStoreSchema;
    }
    if (!try metaEquals(database, "format", format_text)) return error.WrongStoreVersion;
    {
        const statement = try sqlite.prepare(database, "SELECT meta_value FROM store_meta WHERE meta_key='wire_version'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreVersion;
        var version: Bounded(16) = .{};
        try sqlite.readText(statement, 0, &version);
        if (!version.eql(wire_version)) return error.WrongStoreVersion;
    }
    {
        const statement = try sqlite.prepare(database, "SELECT meta_value FROM store_meta WHERE meta_key='store_id'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreIdentity;
        if (!isStoreId(try columnText(statement, 0))) return error.WrongStoreIdentity;
    }
    {
        const statement = try sqlite.prepare(database, "SELECT meta_value FROM store_meta WHERE meta_key='store_selector'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreIdentity;
        var stored_selector: Bounded(store_path.max_bytes) = .{};
        try sqlite.readText(statement, 0, &stored_selector);
        if (!stored_selector.eql(selector)) {
            if (identity_mismatch) |out| out.saved_selector = stored_selector;
            return error.StoreIdentityMismatch;
        }
    }
}

/// Whether `text` is a Store id as store_meta holds it.
pub fn isStoreId(text: []const u8) bool {
    return @import("../store_id.zig").valid(text);
}

/// Column `column` of the current row, which is not NULL, as text.
fn columnText(statement: *c.sqlite3_stmt, column: c_int) ![]const u8 {
    const text = c.sqlite3_column_text(statement, column) orelse return error.OutOfMemory;
    return text[0..@intCast(c.sqlite3_column_bytes(statement, column))];
}

/// Whether store_meta holds exactly `expected` under `key`.
fn metaEquals(database: *c.sqlite3, comptime key: []const u8, expected: []const u8) !bool {
    const statement = try sqlite.prepare(database, "SELECT meta_value FROM store_meta WHERE meta_key='" ++ key ++ "'");
    defer _ = c.sqlite3_finalize(statement);
    if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
    if (c.sqlite3_column_type(statement, 0) != c.SQLITE_TEXT) return false;
    const text = c.sqlite3_column_text(statement, 0) orelse return error.OutOfMemory;
    return std.mem.eql(u8, text[0..@intCast(c.sqlite3_column_bytes(statement, 0))], expected);
}

// Two tables whose keys reference each other, for the MySQL DDL test.
const mysql_test_order: Table = .{
    .name = "turn",
    .columns = &.{
        .{ .name = "turn_id", .type = .int },
        .{ .name = "code", .type = .{ .text = null } },
        .{ .name = "live", .type = .flag, .default = "0" },
    },
    .primary_key = &.{"turn_id"},
    .foreign_keys = &.{references("code", "content", &.{"label"})},
};
const mysql_test_label: Table = .{
    .name = "content",
    .columns = &.{
        .{ .name = "label", .type = .{ .text = .{ .min = 1, .max = 8 } } },
        .{ .name = "note", .type = .{ .text = .{ .max = 100 } }, .nullable = true },
        .{ .name = "body", .type = .{ .bytes = null }, .check = "length(body)<10" },
        .{ .name = "first_turn", .type = .int },
    },
    .primary_key = &.{"label"},
    .foreign_keys = &.{references("first_turn", "turn", &.{"turn_id"})},
};

test "MySQL types come from foreign keys, bounds and keys, and a key cycle closes after its tables" {
    const rendered = comptime mysqlObjects(&[_]Table{ mysql_test_order, mysql_test_label }, &.{}).objects;
    try std.testing.expectEqual(3, rendered.len);
    try std.testing.expectEqualStrings(
        "CREATE TABLE turn(\n turn_id BIGINT NOT NULL,\n code VARCHAR(8) NOT NULL,\n live TINYINT NOT NULL DEFAULT 0,\n PRIMARY KEY(turn_id),\n" ++
            " CHECK(live IN (0,1))\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
        rendered[0].sql,
    );
    try std.testing.expectEqualStrings(
        "CREATE TABLE content(\n label VARCHAR(8) NOT NULL,\n note TEXT,\n body LONGBLOB NOT NULL,\n first_turn BIGINT NOT NULL,\n PRIMARY KEY(label),\n" ++
            " FOREIGN KEY(first_turn) REFERENCES turn(turn_id),\n CHECK(OCTET_LENGTH(label) BETWEEN 1 AND 8),\n" ++
            " CHECK(note IS NULL OR OCTET_LENGTH(note)<=100),\n CHECK(length(body)<10)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin",
        rendered[1].sql,
    );
    try std.testing.expectEqualStrings("ALTER TABLE turn ADD FOREIGN KEY(code) REFERENCES content(label)", rendered[2].sql);
    const unbounded = [_]Table{.{ .name = "content", .columns = &.{.{ .name = "label", .type = .{ .text = null } }}, .primary_key = &.{"label"} }};
    try std.testing.expectEqualStrings(
        "schema: content.label is in a key with no bound; MySQL keys only bounded values: give its type a .max",
        comptime mysqlObjects(&unbounded, &.{}).refused,
    );
}

test "each partial index takes its MySQL form" {
    const open: Index = .{ .name = "open", .table = "turn", .columns = &.{ "session_ref", "turn_id DESC" }, .where = "outcome_code IS NULL" };
    try std.testing.expectEqualStrings("CREATE INDEX open ON turn(open_lead,turn_id DESC)", comptime createMysqlIndex(&tables, open));
    try std.testing.expectEqualStrings("CASE WHEN outcome_code IS NULL THEN session_ref END", comptime leadingValue(&tables, open));
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX handle ON action_operation(sender_handle,action_id)",
        comptime createMysqlIndex(&tables, .{ .name = "handle", .table = "action_operation", .columns = &.{ "sender_handle", "action_id" }, .unique = true, .where = "sender_handle IS NOT NULL" }),
    );
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX active ON turn((CASE WHEN outcome_code IS NULL THEN session_ref END),(CASE WHEN outcome_code IS NULL THEN turn_id END) DESC)",
        comptime createMysqlIndex(&tables, .{ .name = "active", .table = "turn", .columns = &.{ "session_ref", "turn_id DESC" }, .unique = true, .where = "outcome_code IS NULL" }),
    );
    try std.testing.expectEqualStrings(
        "CREATE UNIQUE INDEX other ON turn((CASE WHEN outcome_code IS NOT NULL THEN session_ref END))",
        comptime createMysqlIndex(&tables, .{ .name = "other", .table = "turn", .columns = &.{"session_ref"}, .unique = true, .where = "outcome_code IS NOT NULL" }),
    );
}

test "the schema's MySQL DDL keeps each foreign key once and no SQLite spelling" {
    const rendered = comptime objects(.mysql);
    for (rendered) |object| {
        for ([_][]const u8{ "STRICT", "ROWID", "GLOB", "FILTER", "rui_served", "INDEXED", "WHERE" }) |sqlite_only| {
            try std.testing.expect(std.mem.indexOf(u8, object.sql, sqlite_only) == null);
        }
    }
    inline for (tables) |table| {
        inline for (table.foreign_keys) |key| {
            const clause = comptime "FOREIGN KEY(" ++ list(key.columns) ++ ") " ++ referenceClause(key);
            var found: usize = 0;
            for (rendered) |object| {
                const owner = switch (object.kind) {
                    .table => std.mem.eql(u8, object.name, table.name),
                    .foreign_key => std.mem.startsWith(u8, object.sql, "ALTER TABLE " ++ table.name ++ " "),
                    .index => false,
                };
                if (owner) found += std.mem.count(u8, object.sql, clause);
            }
            try std.testing.expectEqual(@as(usize, 1), found);
        }
    }
    const output_items = for (rendered) |object| {
        if (std.mem.eql(u8, object.name, "model_output_item")) break object.sql;
    } else unreachable;
    try std.testing.expect(std.mem.indexOf(u8, output_items, " session_ref VARCHAR(6) NOT NULL,") != null);
}

test "each engine's DDL holds only its own tables and columns" {
    const sqlite_ddl = comptime ddl(.sqlite);
    const mysql_ddl = comptime ddl(.mysql);
    for ([_][]const u8{ "CREATE TABLE store_owner(", "CREATE TABLE content_chunk(" }) |mysql_only| {
        try std.testing.expect(std.mem.indexOf(u8, sqlite_ddl, mysql_only) == null);
        try std.testing.expect(std.mem.indexOf(u8, mysql_ddl, mysql_only) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, sqlite_ddl, " payload BLOB NOT NULL CHECK(length(payload)=byte_length)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_ddl, "payload") == null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_ddl, " bytes LONGBLOB NOT NULL,") != null);
    try std.testing.expect(comptime lacks(.mysql, "content", "payload"));
    try std.testing.expect(!comptime lacks(.sqlite, "content", "payload"));
    try std.testing.expect(!comptime lacks(.mysql, "content", "digest"));
}

test "a leading index's MySQL table computes its first column" {
    const mysql_ddl = comptime ddl(.mysql);
    try std.testing.expect(std.mem.indexOf(u8, mysql_ddl, " session_stop_unpositioned_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN position IS NULL THEN session_ref END) STORED,") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_ddl, "CREATE INDEX session_stop_unpositioned ON session_stop(session_stop_unpositioned_lead);") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_ddl, " action_operation_indeterminate_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN resolution_code='indeterminate' THEN session_ref END) STORED,") != null);
    try std.testing.expect(std.mem.indexOf(u8, mysql_ddl, "CREATE INDEX action_operation_indeterminate ON action_operation(action_operation_indeterminate_lead,parent_operation_id,call_ordinal);") != null);
    try std.testing.expect(std.mem.indexOf(u8, comptime ddl(.sqlite), "CREATE INDEX action_operation_indeterminate ON action_operation(session_ref,parent_operation_id,call_ordinal) WHERE resolution_code='indeterminate';") != null);
    // SQLite keeps its partial index.
    try std.testing.expect(std.mem.indexOf(u8, comptime ddl(.sqlite), "CREATE INDEX session_stop_unpositioned ON session_stop(session_ref) WHERE position IS NULL;") != null);
}

test "a catalog line names each table, column, index, foreign key and CHECK count MySQL keeps" {
    const lines = comptime catalogLines(&[_]Table{ mysql_test_order, mysql_test_label }, &.{
        .{ .name = "open", .table = "turn", .columns = &.{ "code", "turn_id DESC" }, .where = "live=1" },
        .{ .name = "one", .table = "turn", .columns = &.{"code"}, .unique = true, .where = "live=1" },
        .{ .name = "by_live", .table = "turn", .columns = &.{"live"} },
        .{ .name = "by_note", .table = "content", .columns = &.{"label"}, .unique = true },
    });
    const expected = [_][]const u8{
        "t turn InnoDB utf8mb4_0900_bin",
        "c turn turn_id bigint NO -",
        "c turn code varchar(8) NO utf8mb4_0900_bin",
        "c turn live tinyint NO -",
        "k turn 1",
        "c turn open_lead varchar(8) YES utf8mb4_0900_bin generated",
        "f turn code content label",
        "i turn u turn_id BTREE YES",
        "i turn n open_lead,turn_id desc BTREE YES",
        "i turn u * BTREE YES",
        "i turn n live BTREE YES by_live",
        "i turn n code BTREE YES",
        "t content InnoDB utf8mb4_0900_bin",
        "c content label varchar(8) NO utf8mb4_0900_bin",
        "c content note text YES utf8mb4_0900_bin",
        "c content body longblob NO -",
        "c content first_turn bigint NO -",
        "k content 3",
        "f content first_turn turn turn_id",
        "i content u label BTREE YES",
        "i content u label BTREE YES by_note",
        "i content n first_turn BTREE YES",
    };
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, line| try std.testing.expectEqualStrings(want, line);
    try std.testing.expect(catalogLineDigest("t turn") != catalogLineDigest("t content"));
}

test "a MySQL key wider than InnoDB keeps is refused" {
    const wide = [_]Table{.{ .name = "content", .columns = &.{.{ .name = "label", .type = .{ .text = .{ .max = 769 } } }}, .primary_key = &.{"label"} }};
    try std.testing.expectEqualStrings("schema: the key content(label) is 3076 bytes on MySQL, past InnoDB's 3072", comptime mysqlObjects(&wide, &.{}).refused);
    const fits = [_]Table{.{ .name = "content", .columns = &.{.{ .name = "label", .type = .{ .text = .{ .max = 768 } } }}, .primary_key = &.{"label"} }};
    try std.testing.expectEqual(1, comptime mysqlObjects(&fits, &.{}).objects.len);
}

test "MySQL sessions read literals as rsql copies them, and strictly" {
    const prefix = "SET SESSION sql_mode='";
    const mode = for (mysql_session) |statement| {
        if (std.mem.startsWith(u8, statement, prefix)) break statement[prefix.len .. statement.len - 1];
    } else return error.NoSqlMode;
    // Literals: mysqlRendering copies them unchanged. Strict: DIV by zero and overflow in a write fail as the docs say.
    for ([_][]const u8{ "NO_BACKSLASH_ESCAPES", "STRICT_ALL_TABLES", "ERROR_FOR_DIVISION_BY_ZERO", "ONLY_FULL_GROUP_BY" }) |wanted| {
        var names = std.mem.tokenizeScalar(u8, mode, ',');
        const found = while (names.next()) |name| {
            if (std.mem.eql(u8, name, wanted)) break true;
        } else false;
        try std.testing.expect(found);
    }
}

test "schema 74 migration updates only wire metadata on SQLite and MySQL" {
    const step = migrations[73 - migration_baseline];
    try std.testing.expectEqual(@as(u32, 73), step.from);
    inline for (.{ rsql.Dialect.sqlite, rsql.Dialect.mysql }) |dialect| {
        const statements = if (dialect == .sqlite) step.sqlite else step.mysql;
        try std.testing.expectEqual(@as(usize, 1), statements.len);
        for (statements) |statement| try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='17' WHERE meta_key='wire_version' AND meta_value='16'", statement);
    }
    try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='17' WHERE meta_key='wire_version' AND meta_value='16';\n", mysqlMigration(73));
}

test "schema 72 migration updates only wire metadata on SQLite and MySQL" {
    const step = migrations[71 - migration_baseline];
    try std.testing.expectEqual(@as(u32, 71), step.from);
    inline for (.{ rsql.Dialect.sqlite, rsql.Dialect.mysql }) |dialect| {
        const statements = if (dialect == .sqlite) step.sqlite else step.mysql;
        try std.testing.expectEqual(@as(usize, 1), statements.len);
        for (statements) |statement| try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='16' WHERE meta_key='wire_version' AND meta_value='15'", statement);
    }
    try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='16' WHERE meta_key='wire_version' AND meta_value='15';\n", mysqlMigration(71));
}

test "schema 71 migration updates only wire metadata on SQLite and MySQL" {
    const step = migrations[70 - migration_baseline];
    try std.testing.expectEqual(@as(u32, 70), step.from);
    inline for (.{ rsql.Dialect.sqlite, rsql.Dialect.mysql }) |dialect| {
        const statements = if (dialect == .sqlite) step.sqlite else step.mysql;
        try std.testing.expectEqual(@as(usize, 1), statements.len);
        for (statements) |statement| try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='15' WHERE meta_key='wire_version' AND meta_value='14'", statement);
    }
    try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='15' WHERE meta_key='wire_version' AND meta_value='14';\n", mysqlMigration(70));
}

test "schema 70 migration updates only wire metadata on SQLite and MySQL" {
    const step = migrations[69 - migration_baseline];
    try std.testing.expectEqual(@as(u32, 69), step.from);
    inline for (.{ rsql.Dialect.sqlite, rsql.Dialect.mysql }) |dialect| {
        const statements = if (dialect == .sqlite) step.sqlite else step.mysql;
        try std.testing.expectEqual(@as(usize, 1), statements.len);
        for (statements) |statement| try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='14' WHERE meta_key='wire_version' AND meta_value='13'", statement);
    }
    try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='14' WHERE meta_key='wire_version' AND meta_value='13';\n", mysqlMigration(69));
}

test "schema 58 migration updates only wire metadata on SQLite and MySQL" {
    const step = migrations[57 - migration_baseline];
    try std.testing.expectEqual(@as(u32, 57), step.from);
    inline for (.{ rsql.Dialect.sqlite, rsql.Dialect.mysql }) |dialect| {
        const statements = if (dialect == .sqlite) step.sqlite else step.mysql;
        try std.testing.expectEqual(@as(usize, 1), statements.len);
        try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='10' WHERE meta_key='wire_version' AND meta_value='9'", statements[0]);
    }
    try std.testing.expectEqualStrings("UPDATE store_meta SET meta_value='10' WHERE meta_key='wire_version' AND meta_value='9';\n", mysqlMigration(57));
}

test "schema 57 migration creates the canonical archive objects on SQLite and MySQL" {
    const step = migrations[56 - migration_baseline];
    inline for (.{ rsql.Dialect.sqlite, rsql.Dialect.mysql }) |dialect| {
        const expected = comptime objects(dialect);
        const statements = if (dialect == .sqlite) step.sqlite else step.mysql;
        var matched: usize = 0;
        for (statements) |statement| {
            if (!std.mem.startsWith(u8, statement, "CREATE ")) continue;
            for (expected) |object| {
                if (std.mem.eql(u8, object.sql, statement)) {
                    matched += 1;
                    break;
                }
            } else {
                const retired = [_][]const u8{
                    "CREATE TABLE session_ending_owed(\n turn_id INTEGER PRIMARY KEY NOT NULL REFERENCES turn(turn_id) CHECK(turn_id>0),\n delivered INTEGER NOT NULL CHECK(delivered BETWEEN 0 AND 1),\n suppress_message INTEGER NOT NULL DEFAULT 0 CHECK(suppress_message IN (0,1))\n) STRICT, WITHOUT ROWID",
                    "CREATE INDEX session_ending_open ON session_ending_owed(delivered,turn_id)",
                };
                for (retired) |object| {
                    if (dialect == .sqlite and std.mem.eql(u8, object, statement)) {
                        matched += 1;
                        break;
                    }
                } else return error.NoncanonicalMigrationObject;
            }
        }
        try std.testing.expectEqual(@as(usize, if (dialect == .sqlite) 11 else 2), matched);
    }
}

const MigrationRecorder = struct {
    begun: ?u32 = null,
    ended: bool = false,

    fn notice(self: *@This()) MigrationNotice {
        return .{ .context = self, .notify = notify };
    }

    fn notify(context: *anyopaque, event: MigrationNotice.Event) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event) {
            .begin => |from| {
                std.debug.assert(self.begun == null and !self.ended);
                self.begun = from;
            },
            .end => {
                std.debug.assert(self.begun != null and !self.ended);
                self.ended = true;
            },
        }
    }
};

test "schema 57 preserves Commands and stop references while adding nullable archive intent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [store_path.max_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [store_path.max_bytes + 32]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/store.sqlite3", .{root}, 0);
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(path, &raw));
    const database = raw.?;
    try sqlite.exec(database, @embedFile("migration_baseline.sqlite.sql"));
    try sqlite.exec(database, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
    try sqlite.exec(database, @embedFile("migration_baseline_rows.sql"));
    for (migrations) |step| {
        if (step.from >= 56) break;
        for (step.sqlite) |statement| try sqlite.exec(database, statement);
    }
    try sqlite.exec(database, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF;PRAGMA user_version=56");
    try sqlite.exec(database, identity_sql);
    {
        const meta = try sqlite.prepare(database, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','9'),('store_selector',?1),('format','56')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, root);
        try sqlite.expectDone(meta);
    }
    // Exercise both optional content references and every saved field when
    // the referenced Commands table is rebuilt, not just its row count.
    try sqlite.exec(database, "UPDATE core_command SET primary_content_id=1,secondary_content_id=2,revision=17,code='retained' WHERE command_key='fixture-stop'");
    // Historical child stops were identified by this reserved prefix. Keep
    // both its exact bytewise boundaries and unrelated caller stops distinct.
    const legacy_stops = [_]struct { key: []const u8, parent_caused: bool }{
        .{ .key = "rui.core/stop/", .parent_caused = true },
        .{ .key = "rui.core/stop/d8mv7p/rhvzwc/1", .parent_caused = true },
        .{ .key = "rui.core/stop/0", .parent_caused = true },
        .{ .key = "rui.core/stop", .parent_caused = false },
        .{ .key = "rui.core/stop.", .parent_caused = false },
        .{ .key = "rui.core/stop0", .parent_caused = false },
        .{ .key = "rui.core/stop0/next", .parent_caused = false },
        .{ .key = "rui.core/archive/d8mv7p", .parent_caused = false },
    };
    for (legacy_stops, 0..) |each, index| {
        const command = try sqlite.prepare(database, "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) SELECT ?1,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,?2 FROM core_command WHERE command_key='fixture-stop'");
        defer _ = c.sqlite3_finalize(command);
        try sqlite.bindText(command, 1, each.key);
        try sqlite.bindU64(command, 2, 20 + index);
        try sqlite.expectDone(command);
        const ending_stop = try sqlite.prepare(database, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at) VALUES(?1,'d8mv7p',1,?2,?2,?2)");
        defer _ = c.sqlite3_finalize(ending_stop);
        try sqlite.bindText(ending_stop, 1, each.key);
        try sqlite.bindU64(ending_stop, 2, 10 + index);
        try sqlite.expectDone(ending_stop);
    }
    try sqlite.exec(database, "UPDATE session_stop SET position=NULL WHERE command_key='rui.core/stop0'");
    try sqlite.exec(database, "CREATE TEMP TABLE original_stops AS SELECT * FROM session_stop");
    try sqlite.exec(database, "CREATE TEMP TABLE original_commands AS SELECT * FROM core_command");
    try sqlite.exec(database, "UPDATE session SET parent_ref='rhvzwc' WHERE session_ref IN ('d8mv7p','brhkcj')");
    try sqlite.exec(database, "INSERT INTO session_ending_owed(turn_id,delivered) VALUES(1,0),(2,1)");
    try sqlite.exec(database, "CREATE TEMP TABLE original_endings AS SELECT * FROM session_ending_owed");
    try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(database, "UPDATE core_command SET kind=6 WHERE command_key='fixture-stop'"));
    var told: MigrationRecorder = .{};
    try openExisting(std.testing.io, database, root, null, told.notice());
    try std.testing.expectEqual(@as(?u32, 56), told.begun);
    try std.testing.expect(told.ended);
    // A Store already at schema_version opens without a migration to announce.
    var reopened: MigrationRecorder = .{};
    try openExisting(std.testing.io, database, root, null, reopened.notice());
    try std.testing.expectEqual(@as(?u32, null), reopened.begun);
    try std.testing.expect(!reopened.ended);
    try std.testing.expectEqual(schema_version, try sqlite.pragmaInt(database, "PRAGMA user_version"));
    try std.testing.expect(try metaEquals(database, "format", format_text));
    try std.testing.expect(try metaEquals(database, "wire_version", wire_version));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT * FROM original_commands EXCEPT SELECT * FROM core_command)"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT * FROM core_command EXCEPT SELECT * FROM original_commands)"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT * FROM original_stops EXCEPT SELECT command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at FROM session_stop)"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at FROM session_stop EXCEPT SELECT * FROM original_stops)"));
    for (legacy_stops) |each| {
        const provenance = try sqlite.prepare(database, "SELECT parent_caused FROM session_stop WHERE command_key=?1");
        defer _ = c.sqlite3_finalize(provenance);
        try sqlite.bindText(provenance, 1, each.key);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(provenance));
        try std.testing.expectEqual(@as(c_int, @intFromBool(each.parent_caused)), c.sqlite3_column_int(provenance, 0));
    }
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT parent_caused FROM session_stop WHERE command_key='fixture-stop'"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT * FROM original_endings EXCEPT SELECT source_id,message_delivered FROM session_forward WHERE message_delivered IS NOT NULL)"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT source_id,message_delivered FROM session_forward WHERE message_delivered IS NOT NULL EXCEPT SELECT * FROM original_endings)"));
    try std.testing.expectEqual(@as(u32, 2), try sqlite.pragmaInt(database, "SELECT count(*) FROM session_forward WHERE suppress_message=0"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(database, "SELECT count(*) FROM sqlite_schema WHERE name='session_forward_message' AND sql='CREATE INDEX session_forward_message ON session_forward(message_delivered,source_id)'"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM session_archive"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM session_archive_command"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM pragma_foreign_key_check"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(database, "SELECT count(*) FROM sqlite_schema WHERE name='core_command_target_order' AND sql='CREATE INDEX core_command_target_order ON core_command(target,kind,command_seq)'"));
    try sqlite.exec(database, "INSERT INTO core_command(command_key,kind,target,input_digest,primary_content_id,secondary_content_id,accepted,code,revision,created,command_seq) VALUES('archive-request',6,'rhvzwc',zeroblob(32),NULL,NULL,1,'',0,0,10),('restore-request',6,'rhvzwc',zeroblob(32),NULL,NULL,1,'',0,0,11)");
    for ([_][:0]const u8{
        "UPDATE session_stop SET parent_caused=-1 WHERE command_key='fixture-stop'",
        "UPDATE session_stop SET parent_caused=2 WHERE command_key='fixture-stop'",
        "UPDATE session_stop SET parent_caused=NULL WHERE command_key='fixture-stop'",
        "UPDATE session_forward SET suppress_message=-1 WHERE source_id=1",
        "UPDATE session_forward SET suppress_message=2 WHERE source_id=1",
        "UPDATE session_forward SET suppress_message=NULL WHERE source_id=1",
        "UPDATE core_command SET kind=0 WHERE command_key='archive-request'",
        "UPDATE core_command SET kind=7 WHERE command_key='archive-request'",
        "UPDATE core_command SET command_key='fixture-stop' WHERE command_key='archive-request'",
        "INSERT INTO session_archive(session_ref,command_key) VALUES('k7m2qx','fixture-stop')",
        // A Command without a durable stop cannot become archive intent.
        "INSERT INTO session_archive(session_ref,command_key) VALUES('rhvzwc','archive-request')",
        "INSERT INTO session_archive_command(command_key,archived) VALUES('missing-request',1)",
    }) |statement| try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(database, statement));
    // Legacy stop insert callers that omit provenance retain the false default.
    try sqlite.exec(database, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at) VALUES('archive-request','rhvzwc',NULL,NULL,0,1)");
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT parent_caused FROM session_stop WHERE command_key='archive-request'"));
    try sqlite.exec(database, "INSERT INTO session_archive(session_ref,command_key) VALUES('rhvzwc','fixture-stop')");
    try sqlite.exec(database, "INSERT INTO session_archive_command(command_key,archived) VALUES('archive-request',1),('restore-request',0)");
    for ([_][:0]const u8{
        "INSERT INTO session_archive(session_ref,command_key) VALUES('rhvzwc',NULL)",
        "UPDATE session_archive_command SET archived=-1 WHERE command_key='archive-request'",
        "UPDATE session_archive_command SET archived=2 WHERE command_key='archive-request'",
        "UPDATE session_archive_command SET archived=NULL WHERE command_key='archive-request'",
        "INSERT INTO session_archive_command(command_key,archived) VALUES('archive-request',0)",
    }) |statement| try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(database, statement));
    // Causal ending suppression remains durable after restoring the parent.
    try sqlite.exec(database, "UPDATE session_forward SET suppress_message=1 WHERE source_id=1");
    // Restore changes only current intent; each request keeps its own bool.
    try sqlite.exec(database, "UPDATE session_archive SET command_key=NULL WHERE session_ref='rhvzwc'");
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(database, "SELECT count(*) FROM session_archive WHERE session_ref='rhvzwc' AND command_key IS NULL"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(database, "SELECT archived FROM session_archive_command WHERE command_key='archive-request'"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT archived FROM session_archive_command WHERE command_key='restore-request'"));
    try openExisting(std.testing.io, database, root, null, null);
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(database, "SELECT suppress_message FROM session_forward WHERE source_id=1"));
}

test "schema 61 migration preserves saved call rows and accepts 200 UTF-8 bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [store_path.max_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [store_path.max_bytes + 32]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/store.sqlite3", .{root}, 0);
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(path, &raw));
    const database = raw.?;
    try sqlite.exec(database, @embedFile("migration_baseline.sqlite.sql"));
    try sqlite.exec(database, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
    try sqlite.exec(database, @embedFile("migration_baseline_rows.sql"));
    for (migrations) |step| {
        if (step.from >= 60) break;
        for (step.sqlite) |statement| try sqlite.exec(database, statement);
    }
    try sqlite.exec(database, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF;PRAGMA user_version=60");
    try sqlite.exec(database, identity_sql);
    {
        const meta = try sqlite.prepare(database, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','11'),('store_selector',?1),('format','60')");
        defer _ = c.sqlite3_finalize(meta);
        try sqlite.bindText(meta, 1, root);
        try sqlite.expectDone(meta);
    }
    // Preserve a hosted line at the old byte limit, a nullable call line,
    // and the fixture's original accepted line and dependent rows.
    try sqlite.exec(database, "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,message_content_id,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count,description,call_failed) VALUES(2,2,'brhkcj',6,5,NULL,1,zeroblob(32),0,0,7,0,'" ++ @as([100]u8, @splat('h')) ++ "',1)");
    try sqlite.exec(database, "UPDATE model_tool_call SET description=NULL WHERE call_ordinal=1");
    const ascii_line: [200]u8 = @splat('a');
    const ascii_overlong = ascii_line ++ "a";
    const utf8_line: [200]u8 = comptime line: {
        var bytes: [200]u8 = undefined;
        for (0..100) |index| bytes[index * 2 ..][0..2].* = "é".*;
        break :line bytes;
    };
    const utf8_overlong = utf8_line ++ "a";
    const updates = .{
        "UPDATE model_tool_call SET description=?1 WHERE operation_id=2 AND call_ordinal=0",
        "UPDATE model_output_item SET description=?1 WHERE operation_id=2 AND item_ordinal=2",
    };
    inline for (updates) |sql| {
        const statement = try sqlite.prepare(database, sql);
        defer _ = c.sqlite3_finalize(statement);
        try sqlite.bindText(statement, 1, ascii_overlong[0..101]);
        try std.testing.expectEqual(c.SQLITE_CONSTRAINT, c.sqlite3_step(statement));
    }
    inline for (.{ "model_output_item", "model_tool_call", "model_output_part", "action_operation", "conversation_entry" }) |name| {
        try sqlite.exec(database, "CREATE TEMP TABLE original_" ++ name ++ " AS SELECT * FROM " ++ name);
    }
    try openExisting(std.testing.io, database, root, null, null);
    try std.testing.expectEqual(schema_version, try sqlite.pragmaInt(database, "PRAGMA user_version"));
    try std.testing.expect(try metaEquals(database, "format", format_text));
    try std.testing.expect(try metaEquals(database, "wire_version", wire_version));
    inline for (.{ "model_output_item", "model_tool_call", "model_output_part", "action_operation", "conversation_entry" }) |name| {
        try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT * FROM original_" ++ name ++ " EXCEPT SELECT * FROM " ++ name ++ ")"));
        try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT * FROM " ++ name ++ " EXCEPT SELECT * FROM original_" ++ name ++ ")"));
    }
    inline for (updates) |sql| {
        // Both ASCII and multibyte UTF-8 use byte, not character, bounds.
        for ([_][]const u8{ &ascii_line, &utf8_line }) |line| {
            const statement = try sqlite.prepare(database, sql);
            defer _ = c.sqlite3_finalize(statement);
            try sqlite.bindText(statement, 1, line);
            try sqlite.expectDone(statement);
        }
        for ([_][]const u8{ ascii_overlong, utf8_overlong, "" }) |line| {
            const statement = try sqlite.prepare(database, sql);
            defer _ = c.sqlite3_finalize(statement);
            try sqlite.bindText(statement, 1, line);
            try std.testing.expectEqual(c.SQLITE_CONSTRAINT, c.sqlite3_step(statement));
        }
    }
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(database, "SELECT count(*) FROM model_tool_call WHERE operation_id=2 AND call_ordinal=0 AND length(CAST(description AS BLOB))=200 AND description='" ++ utf8_line ++ "'"));
    try std.testing.expectEqual(@as(u32, 1), try sqlite.pragmaInt(database, "SELECT count(*) FROM model_output_item WHERE operation_id=2 AND item_ordinal=2 AND length(CAST(description AS BLOB))=200 AND description='" ++ utf8_line ++ "'"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM pragma_foreign_key_check"));
    // The widened lines and canonical table/index shapes survive reopening.
    try openExisting(std.testing.io, database, root, null, null);
}

test "MySQL index hints require a named real-column index on that engine" {
    const table: Table = .{
        .name = "fixture",
        .columns = &.{ .{ .name = "id", .type = .int }, .{ .name = "value", .type = .int } },
        .primary_key = &.{"id"},
    };
    const index: Index = .{ .name = "by_value", .table = "fixture", .columns = &.{"value DESC"} };
    try std.testing.expect(comptime canForceMysqlIndex(&.{table}, &.{index}, "by_value"));
    const unique = comptime blk: {
        var copy = index;
        copy.unique = true;
        copy.columns = &.{"value"};
        copy.where = "value IS NOT NULL";
        break :blk copy;
    };
    try std.testing.expect(comptime canForceMysqlIndex(&.{table}, &.{unique}, "by_value"));
    const plain_unique = comptime blk: {
        var copy = unique;
        copy.where = null;
        break :blk copy;
    };
    try std.testing.expect(comptime canForceMysqlIndex(&.{table}, &.{plain_unique}, "by_value"));
    const trailing_sqlite_column = comptime blk: {
        var copy = index;
        copy.columns = &.{ "id", "value DESC" };
        break :blk copy;
    };
    const sqlite_table = comptime blk: {
        var copy = table;
        copy.engines = .sqlite;
        break :blk copy;
    };
    try std.testing.expect(!comptime canForceMysqlIndex(&.{sqlite_table}, &.{index}, "by_value"));
    const sqlite_column = comptime blk: {
        var copy = table;
        var columns = table.columns[0..2].*;
        columns[1].engines = .sqlite;
        copy.columns = &columns;
        break :blk copy;
    };
    try std.testing.expect(!comptime canForceMysqlIndex(&.{sqlite_column}, &.{index}, "by_value"));
    try std.testing.expect(!comptime canForceMysqlIndex(&.{sqlite_column}, &.{trailing_sqlite_column}, "by_value"));
    try std.testing.expect(!comptime canForceMysqlIndex(&.{table}, &.{index}, "absent"));
    try std.testing.expect(!comptime canForceMysqlIndex(&.{}, &.{index}, "by_value"));
    const missing_column = comptime blk: {
        var copy = index;
        copy.columns = &.{"absent"};
        break :blk copy;
    };
    try std.testing.expect(!comptime canForceMysqlIndex(&.{table}, &.{missing_column}, "by_value"));
    const functional = comptime blk: {
        var copy = unique;
        copy.where = "value>0";
        break :blk copy;
    };
    try std.testing.expect(!comptime canForceMysqlIndex(&.{table}, &.{functional}, "by_value"));
    const leading = comptime blk: {
        var copy = index;
        copy.where = "value IS NOT NULL";
        break :blk copy;
    };
    try std.testing.expect(!comptime canForceMysqlIndex(&.{table}, &.{leading}, "by_value"));
    const empty = comptime blk: {
        var copy = index;
        copy.columns = &.{};
        break :blk copy;
    };
    try std.testing.expect(!comptime canForceMysqlIndex(&.{table}, &.{empty}, "by_value"));
    try std.testing.expect(!comptime mysqlCanForceIndex("action_operation_executable"));
    try std.testing.expect(!comptime mysqlCanForceIndex("turn_one_active_per_session"));
    try std.testing.expect(!comptime mysqlCanForceIndex("absent"));
    inline for (.{ "session_revision_instructions", "session_revision_output_schema" }) |name| {
        try std.testing.expect(comptime hasIndex(name));
        try std.testing.expect(comptime mysqlCanForceIndex(name));
    }
}

test "model call timing format 68 migration preserves format 67 resolutions with null final attempt timings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [store_path.max_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [store_path.max_bytes + 32]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/store.sqlite3", .{root}, 0);
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(path, &raw));
    const database = raw.?;
    try sqlite.exec(database, @embedFile("migration_baseline.sqlite.sql"));
    try sqlite.exec(database, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
    try sqlite.exec(database, @embedFile("migration_baseline_rows.sql"));
    for (migrations[0 .. 67 - migration_baseline]) |step| {
        for (step.sqlite) |statement| try sqlite.exec(database, statement);
    }
    try sqlite.exec(database, "CREATE TEMP TABLE old_model_resolutions AS SELECT operation_id,attempt_ordinal,resolution_code,resolved_at FROM model_operation");
    try std.testing.expect((try sqlite.pragmaInt(database, "SELECT count(*) FROM old_model_resolutions")) > 0);
    for (migrations[67 - migration_baseline].sqlite) |statement| try sqlite.exec(database, statement);
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM model_operation WHERE latency_ms IS NOT NULL OR first_event_ms IS NOT NULL"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT * FROM old_model_resolutions EXCEPT SELECT operation_id,attempt_ordinal,resolution_code,resolved_at FROM model_operation)"));
    try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, "SELECT count(*) FROM (SELECT operation_id,attempt_ordinal,resolution_code,resolved_at FROM model_operation EXCEPT SELECT * FROM old_model_resolutions)"));
    try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(database, "UPDATE model_operation SET latency_ms=-1"));
    try std.testing.expectError(error.SqliteExecFailed, sqlite.exec(database, "UPDATE model_operation SET first_event_ms=-1"));
}
