//! The Store schema as one value: its tables and indexes, from which each
//! engine's DDL derives. A new database gets the DDL; an existing one's
//! stored DDL is compared with it when it opens.

const std = @import("std");
const protocol = @import("../protocol.zig");
const tool_catalog = @import("../tools.zig");
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
pub const schema_version: u32 = 52;
/// `digest()` of each schema_version, oldest first. A change to what
/// `bootstrap` executes changes the last row's digest: in place while that
/// version is unreleased, so concurrent PRs share it, and as a new row and
/// schema_version once it has shipped. tests/ci/test_store_schema_version.py
/// refuses an edited released row and a second unreleased number.
pub const bootstrap_digests = [_]struct { schema_version: u32, digest: u64 }{
    .{ .schema_version = 45, .digest = 0xcc384bb0b78d3949 },
    .{ .schema_version = 46, .digest = 0xf3129842e4a7d447 },
    .{ .schema_version = 47, .digest = 0x51267b57c44099bc },
    .{ .schema_version = 48, .digest = 0xc82dff5ecb5926eb },
    .{ .schema_version = 49, .digest = 0x7308286ccc227397 },
    .{ .schema_version = 50, .digest = 0x5d687971ecde9643 },
    .{ .schema_version = 51, .digest = 0x645a2e73aee4e799 },
    .{ .schema_version = 52, .digest = 0xa0ecf02ad8b7ca02 },
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
        "the Store's bootstrap changed: set the last row's digest to 0x{x:0>16} if schema_version is unreleased, else bump it and append a row",
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
/// chain grows. Only a step past the released schema_version may change.
pub const migrations = [_]Migration{
    // 52 (T1e): MCP tool records name their server, host_catalog names the
    // Host's catalog set, and a catalog set holds up to
    // max_catalog_records. Every record so far is Rui's or a provider's,
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
/// PR 8's `rui store schema --engine mysql [--from N]` prints them. Rui takes
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
/// a tag, which MySQL can key.
const meta_keys = [_][]const u8{ "wire_version", "store_selector", "format" };

pub const tables = [_]Table{
    .{
        .name = "store_meta",
        .columns = &.{
            .{ .name = "meta_key", .type = .{ .tag = &meta_keys } },
            .{ .name = "meta_value", .type = .{ .text = null } },
        },
        .primary_key = &.{"meta_key"},
    },
    .{
        .name = "content",
        .columns = &.{
            .{ .name = "content_id", .type = .int },
            .{ .name = "digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
            .{ .name = "byte_length", .type = .int, .check = "byte_length>=0 AND byte_length<=1073737728" },
            .{ .name = "private", .type = .flag },
            .{ .name = "payload", .type = .{ .bytes = null }, .check = "length(payload)=byte_length" },
        },
        .primary_key = &.{"content_id"},
        .uniques = &.{&.{ "digest", "byte_length", "private" }},
    },
    // One tool as the model is told about it (D48): its name, who owns it
    // (`rui`; `provider` for a tool the provider runs, whose text the codec
    // writes; `mcp` for an MCP server's, which `server` names), and its
    // description and input schema as content.
    .{
        .name = "tool_record",
        .columns = &.{
            .{ .name = "tool_record_id", .type = .int, .check = "tool_record_id>0" },
            .{ .name = "name", .type = .{ .text = .{ .min = 1, .max = tool_catalog.max_name_bytes } }, .check = "@charset(name,'A-Za-z0-9_-')" },
            .{ .name = "owner", .type = .{ .tag = &.{ "rui", "provider", "mcp" } } },
            .{
                .name = "server",
                .type = .{ .text = .{ .min = 0, .max = tool_catalog.max_server_bytes } },
                .check = "@charset(server,'A-Za-z0-9_-') AND (owner='mcp' AND @octets(server)>0 OR owner<>'mcp' AND @octets(server)=0)",
            },
            .{ .name = "description_content_id", .type = .int },
            .{ .name = "input_schema_content_id", .type = .int },
        },
        .primary_key = &.{"tool_record_id"},
        .uniques = &.{&.{ "name", "owner", "server", "description_content_id", "input_schema_content_id" }},
        .foreign_keys = &.{
            references("description_content_id", "content", content_reference),
            references("input_schema_content_id", "content", content_reference),
        },
    },
    // An ordered set of tool records, saved once: `digest` names its
    // members' content (tools.zig `SetDigest`). A Session's set holds at
    // most max_tools, the wire's bound; the Host's catalog set up to
    // max_catalog_records.
    .{
        .name = "tool_set",
        .columns = &.{
            .{ .name = "tool_set_id", .type = .int, .check = "tool_set_id>0" },
            .{ .name = "digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
            .{ .name = "member_count", .type = .int, .check = std.fmt.comptimePrint("member_count BETWEEN 0 AND {d}", .{tool_catalog.max_catalog_records}) },
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
    // The Host's catalog: the set its last open saved (tools.zig
    // `Catalog`), which the next start reads back. One row.
    .{
        .name = "host_catalog",
        .columns = &.{
            .{ .name = "slot", .type = .int, .check = "slot=1" },
            .{ .name = "tool_set_id", .type = .int },
        },
        .primary_key = &.{"slot"},
        .foreign_keys = &.{
            references("tool_set_id", "tool_set", &.{"tool_set_id"}),
        },
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
        },
        .primary_key = &.{"session_ref"},
        .uniques = &.{&.{"created_seq"}},
        .checks = &.{"workspace_key>0 AND workspace_key<=created_seq"},
        .foreign_keys = &.{
            references("instructions_content_id", "content", content_reference),
            references("tool_set_id", "tool_set", &.{"tool_set_id"}),
            references("output_schema_content_id", "content", content_reference),
        },
    },
    .{
        .name = "core_command",
        .columns = &.{
            .{ .name = "command_key", .type = .{ .text = .{ .max = 128 } } },
            .{ .name = "kind", .type = .int, .check = "kind BETWEEN 1 AND 5" },
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
            permission_mode_column,
            .{ .name = "output_schema_content_id", .type = .int, .nullable = true },
            compaction_trigger_column,
            .{ .name = "output_reservation", .type = .int, .nullable = true, .check = "output_reservation IS NULL OR output_reservation>=0" },
            reasoning_effort_column,
            label_column,
        },
        .primary_key = &.{ "session_ref", "revision" },
        .uniques = &.{&.{"command_key"}},
        .foreign_keys = &.{
            references("session_ref", "session", session_reference),
            references("command_key", "core_command", command_reference),
            references("instructions_content_id", "content", content_reference),
            references("tool_set_id", "tool_set", &.{"tool_set_id"}),
            references("output_schema_content_id", "content", content_reference),
        },
        .without_rowid = true,
    },
    .{
        // The feed's change list (D138, D218): one row per setting a
        // revision changed, written in the revision's own commit and never
        // edited. The revision keeps the current values; a row records
        // when its change was accepted. A revision's rows share one
        // position, one ordinal each.
        .name = "session_change",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "position", .type = .int, .check = "position>0" },
            .{ .name = "ordinal", .type = .int, .check = "ordinal>=0" },
            .{ .name = "revision", .type = .int, .check = "revision>1" },
            .{ .name = "field", .type = .{ .tag = &.{ "provider", "model", "instructions", "tools", "permission_mode", "output_schema", "compaction_trigger", "output_reservation", "reasoning_effort", "label" } } },
            .{ .name = "changed_at", .type = .int, .check = "changed_at>0" },
        },
        .primary_key = &.{ "session_ref", "position", "ordinal" },
        .uniques = &.{&.{ "session_ref", "revision", "field" }},
        .foreign_keys = &.{
            references("session_ref", "session", session_reference),
            .{ .columns = &.{ "session_ref", "revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
        },
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
            .{ .name = "usage_content_id", .type = .int, .nullable = true },
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
        },
        .primary_key = &.{"operation_id"},
        .uniques = &.{&.{ "operation_id", "session_ref" }},
        .foreign_keys = &.{
            references("turn_id", "turn", &.{"turn_id"}),
            references("resolution_content_id", "content", content_reference),
            references("usage_content_id", "content", content_reference),
            references("interrupted_by_command_key", "core_command", command_reference),
            .{ .columns = &.{ "session_ref", "settings_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
        },
        .checks = &.{
            // Usage counts are all present or all absent, and only beside the report.
            "(usage_uncached_tokens IS NULL AND usage_cache_read_tokens IS NULL AND usage_cache_write_tokens IS NULL AND usage_output_tokens IS NULL) OR " ++
                "(usage_uncached_tokens IS NOT NULL AND usage_cache_read_tokens IS NOT NULL AND usage_cache_write_tokens IS NOT NULL AND " ++
                "usage_output_tokens IS NOT NULL AND usage_content_id IS NOT NULL)",
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
        .name = "conversation_entry",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "entry_ordinal", .type = .int, .check = "entry_ordinal>0" },
            .{ .name = "session_position", .type = .int, .check = "session_position>0" },
            .{ .name = "entry_kind", .type = .int, .check = "entry_kind BETWEEN 1 AND 3" },
            .{ .name = "turn_id", .type = .int },
            .{ .name = "source_admission_id", .type = .int, .nullable = true },
            .{ .name = "source_revision", .type = .int, .nullable = true },
            .{ .name = "source_operation_id", .type = .int, .nullable = true },
            .{ .name = "source_item_ordinal", .type = .int, .nullable = true, .check = "source_item_ordinal IS NULL OR source_item_ordinal>=0" },
            .{ .name = "content_id", .type = .int },
            .{ .name = "recorded_at", .type = .int, .check = "recorded_at>0" },
        },
        .primary_key = &.{ "session_ref", "entry_ordinal" },
        .uniques = &.{ &.{"source_admission_id"}, &.{ "session_ref", "session_position" }, &.{ "session_ref", "source_revision" } },
        .foreign_keys = &.{
            references("turn_id", "turn", &.{"turn_id"}),
            references("source_admission_id", "message_admission", &.{"admission_id"}),
            references("source_operation_id", "model_operation", &.{"operation_id"}),
            references("content_id", "content", content_reference),
            .{ .columns = &.{ "session_ref", "source_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
            .{ .columns = &.{ "source_operation_id", "source_item_ordinal" }, .references = "model_output_item", .referenced = &.{ "operation_id", "item_ordinal" } },
        },
        .checks = &.{
            "(entry_kind=3)=(source_item_ordinal IS NOT NULL)",
            "(entry_kind=1 AND source_admission_id IS NOT NULL AND source_revision IS NULL AND source_operation_id IS NULL) OR " ++
                "(entry_kind=2 AND source_admission_id IS NULL AND source_revision IS NOT NULL AND source_operation_id IS NULL) OR " ++
                "(entry_kind=3 AND source_admission_id IS NULL AND source_revision IS NULL AND source_operation_id IS NOT NULL)",
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
            .{ .name = "description", .type = .{ .text = .{ .min = 1, .max = 100 } }, .nullable = true, .check = "(description IS NOT NULL)=(item_kind=5)" },
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
            .{ .name = "description", .type = .{ .text = .{ .min = 1, .max = 100 } }, .nullable = true },
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
            .{ .name = "bash_timeout_ms", .type = .int, .nullable = true, .check = "bash_timeout_ms IS NULL OR bash_timeout_ms>0" },
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
            "(attempt_ordinal=0 AND bash_timeout_ms IS NULL) OR (attempt_ordinal=1 AND bash_timeout_ms IS NOT NULL)",
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
    .{ .name = "action_operation_session_order", .table = "action_operation", .columns = &.{ "session_ref", "action_id" } },
    .{ .name = "action_operation_sender_handle", .table = "action_operation", .columns = &.{"sender_handle"}, .unique = true, .where = "sender_handle IS NOT NULL" },
    .{ .name = "action_operation_acceptance", .table = "action_operation", .columns = &.{ "session_ref", "acceptance_position" } },
    // Results walk it (`report.full_results`): the predicate holds exactly
    // for a resolved Action (action_operation's CHECK).
    .{ .name = "action_operation_session_results", .table = "action_operation", .columns = &.{ "session_ref", "parent_operation_id", "acceptance_position" }, .where = "acceptance_position IS NOT NULL" },
    .{ .name = "action_operation_approval", .table = "action_operation", .columns = &.{ "session_ref", "approval_position" }, .where = "approval_position IS NOT NULL" },
    .{ .name = "action_operation_executable", .table = "action_operation", .columns = &.{"action_id"}, .where = "authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0" },
    .{ .name = "action_operation_unresolved_attempt", .table = "action_operation", .columns = &.{"action_id"}, .where = "resolution_code IS NULL AND attempt_ordinal=1" },
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
    @setEvalBranchQuota(2000);
    return tableCarriesSessions(tables[tablePosition(&tables, table)]);
}

/// The columns that name a Session, in the order `sessionColumns` lists them.
pub const session_column_names = [_][]const u8{ "session_ref", "sender_session_ref" };

fn tableCarriesSessions(comptime table: Table) bool {
    if (std.mem.eql(u8, table.name, "model_interruption_command")) return false;
    for (table.columns) |column| if (contains(&session_column_names, column.name)) return true;
    return false;
}

/// Whether `table` has a column named `column`.
pub fn hasColumn(comptime table: []const u8, comptime column: []const u8) bool {
    comptime {
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
        for (tables) |table| result = result ++ .{Object{ .kind = .table, .name = table.name, .sql = createTable(table) }};
        for (indexes) |index| result = result ++ .{Object{ .kind = .index, .name = index.name, .sql = createIndex(index) }};
        break :blk result;
    };
}

/// What MySQL sessions on a Store set before their first statement: the
/// collation the DDL's keys compare in, and a strict `sql_mode` with
/// ONLY_FULL_GROUP_BY and NO_BACKSLASH_ESCAPES. Nothing in this PR runs
/// it; the live dialect check and PR 8's engine do.
pub const mysql_session = [_][:0]const u8{
    "SET NAMES utf8mb4 COLLATE utf8mb4_0900_bin",
    "SET SESSION sql_mode='ONLY_FULL_GROUP_BY,STRICT_ALL_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION,NO_BACKSLASH_ESCAPES'",
};

const MysqlObjects = union(enum) { refused: []const u8, objects: []const Object };

/// The MySQL 8.4 DDL of `all` and `all_indexes`, or why it has none.
/// Each table is InnoDB in utf8mb4_0900_bin, with each column typed by
/// `mysqlColumnType` and every key, CHECK and foreign key at table level:
/// MySQL ignores a column's inline REFERENCES, and refuses a column CHECK
/// that names another column. A foreign key to a table created later
/// (the turn and admission cycle) is an ALTER TABLE after every table and
/// index. Each index takes its `mysqlIndexForm`.
fn mysqlObjects(comptime all: []const Table, comptime all_indexes: []const Index) MysqlObjects {
    comptime {
        @setEvalBranchQuota(50_000 * (all.len + all_indexes.len));
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
    /// Not unique: the plain index on its columns. Its predicate only
    /// narrowed what SQLite stores, never what it allows.
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

fn createMysqlIndex(comptime all: []const Table, comptime index: Index) []const u8 {
    checkIdentifier(index.name);
    var parts: []const u8 = list(index.columns);
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
/// a wire bump is no schema change.
const store_meta_sql = "INSERT INTO store_meta(meta_key,meta_value) VALUES('" ++ meta_keys[0] ++ "',?1),('" ++ meta_keys[1] ++ "',?2),('" ++ meta_keys[2] ++ "','" ++ format_text ++ "')";
const bootstrap_sql = [_][:0]const u8{ ddl(.sqlite), identity_sql, version_sql, store_meta_sql };

fn createTable(comptime table: Table) []const u8 {
    var lines: []const []const u8 = &.{};
    for (table.columns) |column| lines = lines ++ .{columnDefinition(table, column)};
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
    try sqlite.bindText(statement, 1, protocol.wire_version);
    try sqlite.bindText(statement, 2, selector);
    try sqlite.expectDone(statement);
    try sqlite.exec(database, "COMMIT");
}

/// Opens a Store of this application at schema_version, or moves one at a
/// format from migration_baseline on to it first (`migrate`).
pub fn openExisting(io: std.Io, database: *c.sqlite3, selector: []const u8) !void {
    if (try sqlite.pragmaInt(database, "PRAGMA application_id") != application_id) return error.WrongStoreIdentity;
    const found = try sqlite.pragmaInt(database, "PRAGMA user_version");
    if (found == schema_version) return validateCurrent(database, selector);
    if (found < migration_baseline or found > schema_version) return error.WrongStoreVersion;
    return migrate(io, database, selector, found, migrations[found - migration_baseline ..]);
}

/// First writes `migrationBackup`; a Store whose backup fails is refused
/// with nothing migrated. Then, in one transaction: runs `steps`' SQLite statements on a Store at
/// format `from`, sets its format to schema_version, and commits only if
/// the Store then validates as a fresh bootstrap's would
/// (`validateCurrent`) and every foreign key holds. A Store whose
/// store_meta format is not `from` is a WrongStoreVersion, and any failure
/// leaves the Store as it was.
pub noinline fn migrate(io: std.Io, database: *c.sqlite3, selector: []const u8, from: u32, steps: []const Migration) !void {
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
    try validateCurrent(database, selector);
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
/// network engine keeps no such text: PR 8/9 compare its catalog's tables,
/// columns and indexes by name and type instead, which cannot see a CHECK.
/// Its caller has read user_version as schema_version, or set it.
fn validateCurrent(database: *c.sqlite3, selector: []const u8) !void {
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
        var version: protocol.Bounded(16) = .{};
        try sqlite.readText(statement, 0, &version);
        if (!version.eql(protocol.wire_version)) return error.WrongStoreVersion;
    }
    {
        const statement = try sqlite.prepare(database, "SELECT meta_value FROM store_meta WHERE meta_key='store_selector'");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.WrongStoreIdentity;
        var stored_selector: protocol.Bounded(protocol.max_store_bytes) = .{};
        try sqlite.readText(statement, 0, &stored_selector);
        if (!stored_selector.eql(selector)) return error.WrongStoreIdentity;
    }
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
    try std.testing.expectEqualStrings("CREATE INDEX open ON turn(session_ref)", comptime createMysqlIndex(&tables, .{ .name = "open", .table = "turn", .columns = &.{"session_ref"}, .where = "outcome_code IS NULL" }));
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
