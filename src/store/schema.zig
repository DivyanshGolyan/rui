//! The Store schema as one value: its tables and indexes, from which each
//! engine's DDL and the open-time allow-list derive. A new database gets the
//! DDL; an existing one is checked against the allow-list when it opens.

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
pub const schema_version: u32 = 45;
/// FNV-1a of the SQLite DDL for schema_version; the build fails when they disagree.
pub const sqlite_schema_digest: u64 = 0x720709f73b39654e;

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
};

pub const ForeignKey = struct {
    columns: []const []const u8,
    references: []const u8,
    referenced: []const []const u8,
    deferred: bool = false,
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

fn deferredReferences(comptime column: []const u8, comptime table: []const u8, comptime referenced: []const []const u8) ForeignKey {
    return .{ .columns = &.{column}, .references = table, .referenced = referenced, .deferred = true };
}

// A label's syntax, not a provider list, so a new provider is no format change.
const provider_column: Column = .{ .name = "provider", .type = .{ .text = .{ .min = 1, .max = 16 } }, .check = "@initial(provider,'a-z') AND @charset(provider,'a-z0-9_-')" };
const tools_mask_column: Column = .{ .name = "tools_mask", .type = .int, .check = std.fmt.comptimePrint("tools_mask BETWEEN 0 AND {d}", .{tool_catalog.toolBit(.bash)}) };
const permission_mode_column: Column = .{ .name = "permission_mode", .type = .int, .check = "permission_mode BETWEEN 0 AND 1" };
const compaction_trigger_column: Column = .{ .name = "compaction_trigger", .type = .int, .nullable = true, .check = "compaction_trigger IS NULL OR compaction_trigger>0" };
const reasoning_effort_column: Column = .{ .name = "reasoning_effort", .type = .{ .tag = &.{ "none", "low", "medium", "high", "xhigh", "max" } }, .nullable = true };
const label_column: Column = .{ .name = "label", .type = .{ .text = .{ .min = 1, .max = 100 } }, .nullable = true };

pub const tables = [_]Table{
    .{
        .name = "store_meta",
        .columns = &.{
            .{ .name = "key", .type = .{ .text = null } },
            .{ .name = "value", .type = .{ .text = null } },
        },
        .primary_key = &.{"key"},
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
    .{
        .name = "session",
        .columns = &.{
            .{ .name = "session_ref", .type = .{ .text = null }, .check = "length(session_ref)=6 AND @octets(session_ref)=6 AND @charset(session_ref,'0123456789abcdefghjkmnpqrstvwxyz')" },
            .{ .name = "workspace", .type = .{ .text = .{ .min = 1, .max = 4096 } } },
            provider_column,
            // The Session's immutable binding: grammar version and its options.
            .{ .name = "codec", .type = .{ .text = .{ .min = 3, .max = 40 } } },
            .{ .name = "codec_options", .type = .{ .bytes = .{ .min = 1, .max = 512 } }, .nullable = true },
            // What the last fully rebuilt history span encoded to (prefix_seal.zig).
            .{ .name = "prefix_seal", .type = .{ .bytes = .{ .min = prefix_seal.encoded_bytes, .max = prefix_seal.encoded_bytes } }, .nullable = true },
            .{ .name = "model", .type = .{ .text = .{ .min = 1, .max = 256 } } },
            .{ .name = "instructions_content_id", .type = .int },
            tools_mask_column,
            permission_mode_column,
            .{ .name = "output_schema_content_id", .type = .int, .nullable = true },
            .{ .name = "revision", .type = .int, .check = "revision>0" },
            compaction_trigger_column,
            .{ .name = "output_reservation", .type = .int, .nullable = true, .check = "output_reservation IS NULL OR output_reservation>=0" },
            reasoning_effort_column,
            label_column,
            .{ .name = "created_at", .type = .int, .check = "created_at>0" },
            .{ .name = "next_position", .type = .int, .check = "next_position>0" },
        },
        .primary_key = &.{"session_ref"},
        .foreign_keys = &.{
            references("instructions_content_id", "content", content_reference),
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
        },
        .primary_key = &.{"command_key"},
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
            tools_mask_column,
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
            deferredReferences("command_key", "core_command", command_reference),
            references("instructions_content_id", "content", content_reference),
            references("output_schema_content_id", "content", content_reference),
        },
        .without_rowid = true,
    },
    .{
        .name = "message_admission",
        .columns = &.{
            .{ .name = "admission_id", .type = .int, .check = "admission_id>0" },
            .{ .name = "session_ref", .type = .{ .text = null } },
            .{ .name = "command_key", .type = .{ .text = null } },
            .{ .name = "content_id", .type = .int },
            .{ .name = "admission_position", .type = .int, .nullable = true, .check = "admission_position>0" },
            .{ .name = "turn_id", .type = .int, .nullable = true },
            .{ .name = "admitted_at", .type = .int, .check = "admitted_at>0" },
            .{ .name = "sender_session_ref", .type = .{ .text = null }, .nullable = true },
            .{ .name = "sender_position", .type = .int, .nullable = true, .check = "sender_position>0" },
        },
        .primary_key = &.{"admission_id"},
        .uniques = &.{&.{"command_key"}},
        .foreign_keys = &.{
            references("session_ref", "session", session_reference),
            deferredReferences("command_key", "core_command", command_reference),
            references("content_id", "content", content_reference),
            deferredReferences("turn_id", "turn", &.{"turn_id"}),
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
            deferredReferences("command_key", "core_command", command_reference),
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
            deferredReferences("first_admission_id", "message_admission", &.{"admission_id"}),
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
            .{ .name = "turn_id", .type = .{ .text = null }, .check = "length(turn_id) BETWEEN 1 AND 20" },
            .{ .name = "operation_id", .type = .{ .text = null }, .check = "length(operation_id) BETWEEN 1 AND 20" },
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
        },
        .primary_key = &.{"operation_id"},
        .uniques = &.{&.{ "operation_id", "session_ref" }},
        .foreign_keys = &.{
            deferredReferences("turn_id", "turn", &.{"turn_id"}),
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
            .{ .name = "item_kind", .type = .int, .check = "item_kind BETWEEN 1 AND 4" },
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
            .{ .name = "sender_handle", .type = .{ .text = null }, .nullable = true, .check = "sender_handle IS NULL OR (length(sender_handle)=32 AND @charset(sender_handle,'0-9a-f'))" },
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
            .{ .name = "action_id", .type = .{ .text = null }, .check = "length(action_id) BETWEEN 1 AND 20" },
            .{ .name = "decision", .type = .{ .tag = &.{ "allow_once", "deny" } } },
        },
        .primary_key = &.{"command_key"},
        .foreign_keys = &.{references("command_key", "core_command", command_reference)},
        .without_rowid = true,
    },
};

pub const indexes = [_]Index{
    .{ .name = "session_workspace_list", .table = "session", .columns = &.{"workspace"} },
    .{ .name = "message_admission_sent", .table = "message_admission", .columns = &.{ "sender_session_ref", "sender_position" }, .unique = true, .where = "sender_session_ref IS NOT NULL" },
    .{ .name = "turn_one_active_per_session", .table = "turn", .columns = &.{"session_ref"}, .unique = true, .where = "outcome_code IS NULL" },
    .{ .name = "turn_tool_continuation", .table = "turn", .columns = &.{"operation_id"}, .where = "outcome_code IS NULL AND continuation_operation_id=operation_id" },
    .{ .name = "message_admission_session_order", .table = "message_admission", .columns = &.{ "session_ref", "turn_id", "admission_id" } },
    .{ .name = "message_admission_pending", .table = "message_admission", .columns = &.{ "admission_id", "session_ref" }, .where = "turn_id IS NULL" },
    .{ .name = "message_admission_session_pending", .table = "message_admission", .columns = &.{ "session_ref", "admission_id" }, .where = "turn_id IS NULL" },
    .{ .name = "message_admission_person", .table = "message_admission", .columns = &.{ "session_ref", "admission_position" }, .where = "sender_session_ref IS NULL" },
    .{ .name = "message_admission_unpositioned", .table = "message_admission", .columns = &.{"session_ref"}, .where = "admission_position IS NULL" },
    .{ .name = "session_stop_exclusion", .table = "session_stop", .columns = &.{ "session_ref", "admission_cutoff", "position" } },
    .{ .name = "session_stop_unpositioned", .table = "session_stop", .columns = &.{"session_ref"}, .where = "position IS NULL" },
    .{ .name = "session_stop_turn", .table = "session_stop", .columns = &.{"selected_turn_id"} },
    .{ .name = "action_operation_session_order", .table = "action_operation", .columns = &.{ "session_ref", "action_id" } },
    .{ .name = "action_operation_sender_handle", .table = "action_operation", .columns = &.{"sender_handle"}, .unique = true, .where = "sender_handle IS NOT NULL" },
    .{ .name = "action_operation_acceptance", .table = "action_operation", .columns = &.{ "session_ref", "acceptance_position" } },
    .{ .name = "action_operation_executable", .table = "action_operation", .columns = &.{"action_id"}, .where = "authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0" },
    .{ .name = "action_operation_unresolved_attempt", .table = "action_operation", .columns = &.{"action_id"}, .where = "resolution_code IS NULL AND attempt_ordinal=1" },
    .{ .name = "model_tool_call_rejections", .table = "model_tool_call", .columns = &.{ "operation_id", "call_ordinal" }, .where = "rejection_code IS NOT NULL" },
    .{ .name = "model_operation_retry_due", .table = "model_operation", .columns = &.{ "retry_due_at_ms", "operation_id" }, .where = "resolution_code IS NULL AND " ++ retry_allowance_open_sql },
    .{ .name = "model_operation_retry_exhausted", .table = "model_operation", .columns = &.{"operation_id"}, .where = retry_exhausted_sql },
    .{ .name = "model_operation_session_history", .table = "model_operation", .columns = &.{ "session_ref", "operation_id" } },
    .{ .name = "model_operation_turn_history", .table = "model_operation", .columns = &.{ "turn_id", "operation_id" } },
    .{ .name = "model_operation_context_history", .table = "model_operation", .columns = &.{ "session_ref", "admission_position" }, .where = oneOf("resolution_code", &accepted_resolutions) },
    .{ .name = "model_operation_compaction_bases", .table = "model_operation", .columns = &.{ "session_ref", "admission_position" }, .where = "purpose=1 AND " ++ resolutionIs("resolution_code", .compacted) },
    .{ .name = "conversation_entry_history", .table = "conversation_entry", .columns = &.{ "session_ref", "session_position" } },
    .{ .name = "model_output_history", .table = "model_output_item", .columns = &.{ "session_ref", "session_position" } },
    .{ .name = "model_output_compaction_anchor", .table = "model_output_item", .columns = &.{ "operation_id", "item_ordinal" }, .where = "item_kind=4" },
    .{ .name = "turn_session_latest", .table = "turn", .columns = &.{ "session_ref", "turn_id DESC" } },
    .{ .name = "turn_unpositioned", .table = "turn", .columns = &.{"session_ref"}, .where = "(outcome_code IS NULL)!=(outcome_position IS NULL)" },
};

/// The DDL that creates every table, then every index.
pub fn ddl(comptime dialect: rsql.Dialect) [:0]const u8 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var text: []const u8 = "";
        for (tables) |table| text = text ++ createTable(dialect, table) ++ ";\n";
        for (indexes) |index| text = text ++ createIndex(dialect, index) ++ ";\n";
        const terminated = text ++ "\x00";
        break :blk terminated[0..text.len :0];
    };
}

pub const ObjectName = struct { kind: enum { table, index }, name: []const u8 };

/// Every table and named index an existing Store may hold.
pub fn objectNames(comptime dialect: rsql.Dialect) []const ObjectName {
    return comptime blk: {
        if (dialect != .sqlite) @compileError("schema: " ++ @tagName(dialect) ++ " has no object names yet");
        var names: []const ObjectName = &.{};
        for (tables) |table| names = names ++ .{ObjectName{ .kind = .table, .name = table.name }};
        for (indexes) |index| names = names ++ .{ObjectName{ .kind = .index, .name = index.name }};
        break :blk names;
    };
}

/// FNV-1a over the rendered DDL, so a DDL change without a new
/// schema_version fails the build. FNV-1a, not SHA-256: it is a fixed
/// algorithm, and SHA-256 of the DDL costs seconds of every compile.
pub fn digest(comptime dialect: rsql.Dialect) u64 {
    return comptime blk: {
        @setEvalBranchQuota(10 * ddl(dialect).len + 1000);
        break :blk std.hash.Fnv1a_64.hash(ddl(dialect));
    };
}

comptime {
    if (digest(.sqlite) != sqlite_schema_digest) @compileError(std.fmt.comptimePrint(
        "the SQLite schema changed: bump schema_version and pin sqlite_schema_digest = 0x{x:0>16}",
        .{digest(.sqlite)},
    ));
}

fn createTable(comptime dialect: rsql.Dialect, comptime table: Table) []const u8 {
    var lines: []const []const u8 = &.{};
    for (table.columns) |column| lines = lines ++ .{columnDefinition(dialect, table, column)};
    if (table.primary_key.len > 1) lines = lines ++ .{" PRIMARY KEY(" ++ list(table.primary_key) ++ ")"};
    for (table.uniques) |unique| {
        if (unique.len > 1) lines = lines ++ .{" UNIQUE(" ++ list(unique) ++ ")"};
    }
    for (table.foreign_keys) |key| {
        if (key.columns.len > 1) lines = lines ++ .{" FOREIGN KEY(" ++ list(key.columns) ++ ") " ++ referenceClause(key)};
    }
    for (table.checks) |check| lines = lines ++ .{" CHECK(" ++ rsql.render(dialect, check) ++ ")"};
    var body: []const u8 = "";
    for (lines, 0..) |line, position| body = body ++ (if (position == 0) "" else ",\n") ++ line;
    checkIdentifier(table.name);
    return "CREATE TABLE " ++ table.name ++ "(\n" ++ body ++ "\n) STRICT" ++ (if (table.without_rowid) ", WITHOUT ROWID" else "");
}

fn columnDefinition(comptime dialect: rsql.Dialect, comptime table: Table, comptime column: Column) []const u8 {
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
    if (!primary and !column.nullable) text = text ++ " NOT NULL";
    if (column.default) |value| text = text ++ " DEFAULT " ++ value;
    for (table.uniques) |unique| {
        if (eqlList(unique, only)) text = text ++ " UNIQUE";
    }
    for (table.foreign_keys) |key| {
        if (eqlList(key.columns, only)) text = text ++ " " ++ referenceClause(key);
    }
    if (columnCheck(column)) |check| text = text ++ " CHECK(" ++ rsql.render(dialect, check) ++ ")";
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
        .tag => |values| tagCheck(name, values),
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

/// An IN list up to two values, else an OR of equalities: SQLite builds a
/// temporary b-tree for an IN list of more than two each time it runs.
fn tagCheck(comptime name: []const u8, comptime values: []const []const u8) []const u8 {
    var text: []const u8 = "";
    if (values.len <= 2) {
        for (values, 0..) |value, position| text = text ++ (if (position == 0) "" else ",") ++ "'" ++ value ++ "'";
        return name ++ " IN (" ++ text ++ ")";
    }
    for (values, 0..) |value, position| text = text ++ (if (position == 0) "" else " OR ") ++ name ++ "='" ++ value ++ "'";
    return "(" ++ text ++ ")";
}

fn referenceClause(comptime key: ForeignKey) []const u8 {
    return "REFERENCES " ++ key.references ++ "(" ++ list(key.referenced) ++ ")" ++ (if (key.deferred) " DEFERRABLE INITIALLY DEFERRED" else "");
}

fn createIndex(comptime dialect: rsql.Dialect, comptime index: Index) []const u8 {
    checkIdentifier(index.name);
    return "CREATE " ++ (if (index.unique) "UNIQUE " else "") ++ "INDEX " ++ index.name ++ " ON " ++ index.table ++ "(" ++ list(index.columns) ++ ")" ++
        (if (index.where) |where| " WHERE " ++ rsql.render(dialect, where) else "");
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
    try sqlite.exec(database, "PRAGMA application_id=1280591409");
    try sqlite.exec(database, std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version}));
    const statement = try sqlite.prepare(database, "INSERT INTO store_meta(key,value) VALUES('wire_version','" ++ protocol.wire_version ++ "'),('store_selector',?1)");
    defer _ = c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, selector);
    try sqlite.expectDone(statement);
    try sqlite.exec(database, "COMMIT");
}

/// Counts every object that is not one of the schema's tables, their
/// automatic indexes, or its named indexes.
const unexpected_objects_sql = blk: {
    var table_names: []const u8 = "";
    var index_names: []const u8 = "";
    for (objectNames(.sqlite)) |object| switch (object.kind) {
        .table => table_names = table_names ++ (if (table_names.len == 0) "'" else ",'") ++ object.name ++ "'",
        .index => index_names = index_names ++ (if (index_names.len == 0) "'" else ",'") ++ object.name ++ "'",
    };
    break :blk "SELECT count(*) FROM sqlite_schema WHERE " ++
        "(type='table' AND name NOT IN (" ++ table_names ++ ")) OR " ++
        "(type='index' AND ((sql IS NULL AND tbl_name NOT IN (" ++ table_names ++ ")) OR " ++
        "(sql IS NOT NULL AND name NOT IN (" ++ index_names ++ ")))) OR " ++
        "type NOT IN ('table','index')";
};

pub fn validateExisting(database: *c.sqlite3, selector: []const u8) !void {
    if (try sqlite.pragmaInt(database, "PRAGMA application_id") != application_id) return error.WrongStoreIdentity;
    if (try sqlite.pragmaInt(database, "PRAGMA user_version") != schema_version) return error.WrongStoreVersion;
    {
        const statement = try sqlite.prepare(database, unexpected_objects_sql);
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
