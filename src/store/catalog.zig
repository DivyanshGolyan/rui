//! The Store's tables, columns and indexes as values, and the rule text that partial indexes carry.
//! It imports no Store file (only `std` and the policy files that bound its values), so rule values and the schema's
//! renderers can read it without a circle; `schema.zig` re-exports it and owns how each engine spells it.
const std = @import("std");
const session_settings = @import("../session_settings.zig");
const session_id = @import("../session_id.zig");
const store_path = @import("../store_path.zig");
const validStoreId = @import("../store_id.zig").valid;
const tool_name = @import("../tool_name.zig");
const Bounded = @import("../bounded.zig").Bounded;
const tool_defs = @import("../tool_record.zig");
const prefix_seal = @import("../prefix_seal.zig");
const retry_policy = @import("../retry_policy.zig");
const turn_policy = @import("../turn_policy.zig");
const r = @import("rules/rule.zig");

pub const Dialect = enum { sqlite, mysql };

pub const retry_allowance_open_sql = std.fmt.comptimePrint("attempt_ordinal<{d}", .{retry_policy.maximum_attempts});
pub const retry_exhausted_sql = std.fmt.comptimePrint("resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_ordinal={d}", .{retry_policy.maximum_attempts});

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

pub const accepted_resolutions = [_]turn_policy.Resolution{ .answer, .compacted, .tool_proposals };
comptime {
    if (!std.mem.eql(turn_policy.Resolution, &accepted_resolutions, &turn_policy.accepted))
        @compileError("turn_policy.accepted changed: change accepted_resolutions and bootstrap_digests' last row");
}

pub inline fn resolutionIs(comptime column: []const u8, comptime resolution: turn_policy.Resolution) []const u8 {
    return column ++ "='" ++ @tagName(resolution) ++ "'";
}

pub const Octets = struct { min: u32 = 0, max: u32 };

/// Inclusive integer bounds of an `.int` column; an absent `max` is unbounded above.
pub const Range = struct { min: i64, max: ?i64 = null };

pub const ColumnType = union(enum) {
    int,
    flag,
    text: ?Octets,
    bytes: ?Octets,
    tag: []const []const u8,
};

pub const Column = struct {
    name: []const u8,
    type: ColumnType,
    nullable: bool = false,
    default: ?[]const u8 = null,
    /// The column's own value rules, rendered into its CHECK and held by the Host when a value is bound (`column_rules.zig`).
    range: ?Range = null,
    initial: ?[]const u8 = null,
    charset: ?[]const u8 = null,
    /// What no column value expresses: a rule over this column and others.
    check: ?r.Expr = null,
    read_by: ReadBy = .recipient,
    engines: Engines = .all,
    sqlite_added: bool = false,
    holds: enum { bytes, value } = .bytes,
};

pub const Engines = enum {
    all,
    sqlite,
    mysql,

    pub fn on(engines: Engines, dialect: Dialect) bool {
        return switch (engines) {
            .all => true,
            .sqlite => dialect == .sqlite,
            .mysql => dialect == .mysql,
        };
    }
};

pub const ReadBy = enum { recipient, both };

pub const ForeignKey = struct {
    columns: []const []const u8,
    references: []const u8,
    referenced: []const []const u8,
};

pub const Table = struct {
    name: []const u8,
    columns: []const Column,
    primary_key: []const []const u8,
    uniques: []const []const []const u8 = &.{},
    foreign_keys: []const ForeignKey = &.{},
    checks: []const r.Expr = &.{},
    without_rowid: bool = false,
    engines: Engines = .all,
};

pub const Index = struct {
    name: []const u8,
    table: []const u8,
    columns: []const []const u8,
    unique: bool = false,
    where: ?[]const u8 = null,
};

const content_reference: []const []const u8 = &.{"content_id"};
const session_reference: []const []const u8 = &.{"session_ref"};
const command_reference: []const []const u8 = &.{"command_key"};

pub fn references(comptime column: []const u8, comptime table: []const u8, comptime referenced: []const []const u8) ForeignKey {
    return .{ .columns = &.{column}, .references = table, .referenced = referenced };
}

const provider_column: Column = .{ .name = "provider", .type = .{ .text = .{ .min = 1, .max = 16 } }, .check = r.all(&.{ r.call(.initial, &.{ r.field("provider"), r.literal("a-z") }), r.call(.charset, &.{ r.field("provider"), r.literal("a-z0-9_-") }) }) };
/// The wire grammar a revision's bags were written by (codec_abi.Dialect's codecs); each revision freezes its own.
const codec_column: Column = .{ .name = "codec", .type = .{ .text = .{ .min = 3, .max = 40 } } };
const codec_options_column: Column = .{ .name = "codec_options", .type = .{ .bytes = .{ .min = 1, .max = 512 } }, .nullable = true };
const tool_set_column: Column = .{ .name = "tool_set_id", .type = .int, .range = .{ .min = 1 } };
const permission_mode_column: Column = .{ .name = "permission_mode", .type = .int, .range = .{ .min = 0, .max = 1 } };
const compaction_trigger_column: Column = .{ .name = "compaction_trigger", .type = .int, .nullable = true, .range = .{ .min = 1 } };
const reasoning_effort_column: Column = .{ .name = "reasoning_effort", .type = .{ .tag = &.{ "none", "low", "medium", "high", "xhigh", "max" } }, .nullable = true };
const label_column: Column = .{ .name = "label", .type = .{ .text = .{ .min = 1, .max = 100 } }, .nullable = true };

pub const MetaKey = enum { store_selector, format, store_id };
const meta_keys = blk: {
    var names: [1 + std.enums.values(MetaKey).len][]const u8 = undefined;
    names[0] = "wire_version";
    for (std.enums.values(MetaKey), 1..) |key, index| names[index] = @tagName(key);
    break :blk names;
};
pub const content_chunk_bytes = 128 * 1024;

/// Every rule value below is built by comptime calls, so the table asks for the budget they need.
pub const tables = blk: {
    @setEvalBranchQuota(200_000);
    break :blk [_]Table{
        .{
            .name = "store_meta",
            .columns = &.{
                .{ .name = "meta_key", .type = .{ .tag = &meta_keys } },
                .{ .name = "meta_value", .type = .{ .text = null } },
            },
            .primary_key = &.{"meta_key"},
        },
        .{
            .name = "store_owner",
            .columns = &.{
                .{ .name = "owner_key", .type = .int, .range = .{ .min = 1, .max = 1 } },
                .{ .name = "epoch", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "commit_seq", .type = .int, .range = .{ .min = 0 } },
            },
            .primary_key = &.{"owner_key"},
            .engines = .mysql,
        },
        .{
            .name = "content",
            .columns = &.{
                .{ .name = "content_id", .type = .int },
                .{ .name = "digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
                .{ .name = "byte_length", .type = .int, .check = r.all(&.{ r.compare(.ge, r.field("byte_length"), r.literal(0)), r.compare(.le, r.field("byte_length"), r.literal(1073737728)) }) },
                .{ .name = "private", .type = .flag },
                .{ .name = "payload", .type = .{ .bytes = null }, .check = r.compare(.eq, r.call(.length, &.{r.field("payload")}), r.field("byte_length")), .engines = .sqlite },
                .{ .name = "form", .type = .int, .default = "0", .check = r.all(&.{ r.inList(r.field("form"), &.{ r.literal(0), r.literal(1) }), r.any(&.{ r.compare(.eq, r.field("form"), r.literal(0)), r.compare(.eq, r.field("private"), r.literal(0)) }) }), .sqlite_added = true },
            },
            .primary_key = &.{"content_id"},
            .uniques = &.{&.{ "digest", "byte_length", "private" }},
        },
        .{
            .name = "content_chunk",
            .columns = &.{
                .{ .name = "content_id", .type = .int },
                .{ .name = "chunk_index", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "bytes", .type = .{ .bytes = .{ .min = 1, .max = content_chunk_bytes } } },
            },
            .primary_key = &.{ "content_id", "chunk_index" },
            .foreign_keys = &.{references("content_id", "content", content_reference)},
            .engines = .mysql,
        },
        .{
            .name = "content_part",
            .columns = &.{
                .{ .name = "content_id", .type = .int },
                .{ .name = "ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "part_content_id", .type = .int },
            },
            .primary_key = &.{ "content_id", "ordinal" },
            .foreign_keys = &.{ references("content_id", "content", content_reference), references("part_content_id", "content", content_reference) },
            .checks = &.{
                r.compare(.ne, r.field("part_content_id"), r.field("content_id")),
            },
            .without_rowid = true,
        },
        .{
            .name = "tool_record",
            .columns = &.{
                .{ .name = "tool_record_id", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "name", .type = .{ .text = .{ .min = 1, .max = tool_defs.max_name_bytes } }, .charset = "A-Za-z0-9_-" },
                .{ .name = "remote_name", .type = .{ .text = .{ .min = 0, .max = tool_defs.max_name_bytes } }, .charset = "A-Za-z0-9_-" },
                .{ .name = "owner", .type = .{ .tag = &.{ "rui", "provider", "mcp", "app" } } },
                .{
                    .name = "server",
                    .type = .{ .text = .{ .min = 0, .max = tool_defs.max_server_bytes } },
                    .check = r.all(&.{ r.call(.charset, &.{ r.field("server"), r.literal("A-Za-z0-9_-") }), r.any(&.{ r.all(&.{ r.compare(.eq, r.field("owner"), r.literal("mcp")), r.compare(.gt, r.call(.octets, &.{r.field("server")}), r.literal(0)) }), r.all(&.{ r.compare(.ne, r.field("owner"), r.literal("mcp")), r.compare(.eq, r.call(.octets, &.{r.field("server")}), r.literal(0)) }) }) }),
                },
                // App policy: the zero policy ('' and 0) on every other owner, so their rows and digests are unchanged.
                .{
                    .name = "replay",
                    .type = .{ .text = .{ .min = 0, .max = 6 } },
                    .check = r.all(&.{ r.inList(r.field("replay"), &.{ r.literal(""), r.literal("unsafe"), r.literal("safe") }), r.any(&.{ r.all(&.{ r.compare(.eq, r.field("owner"), r.literal("app")), r.compare(.ne, r.field("replay"), r.literal("")) }), r.all(&.{ r.compare(.ne, r.field("owner"), r.literal("app")), r.compare(.eq, r.field("replay"), r.literal("")) }) }) }),
                },
                .{
                    .name = "restart_limit",
                    .type = .int,
                    .check = r.group(r.any(&.{ r.all(&.{ r.compare(.eq, r.field("owner"), r.literal("app")), r.between(r.field("restart_limit"), r.literal(0), r.literal(tool_defs.max_app_restart_limit)) }), r.all(&.{ r.compare(.ne, r.field("owner"), r.literal("app")), r.compare(.eq, r.field("restart_limit"), r.literal(0)) }) })),
                },
                .{
                    .name = "wait_ms",
                    .type = .int,
                    .check = r.group(r.any(&.{ r.all(&.{ r.compare(.eq, r.field("owner"), r.literal("app")), r.between(r.field("wait_ms"), r.literal(tool_defs.min_app_wait_ms), r.literal(tool_defs.max_app_wait_ms)) }), r.all(&.{ r.compare(.ne, r.field("owner"), r.literal("app")), r.compare(.eq, r.field("wait_ms"), r.literal(0)) }) })),
                },
                .{ .name = "description_content_id", .type = .int },
                .{ .name = "input_schema_content_id", .type = .int },
            },
            .checks = &.{
                r.any(&.{ r.compare(.ne, r.field("replay"), r.literal("unsafe")), r.compare(.eq, r.field("restart_limit"), r.literal(0)) }),
            },
            .primary_key = &.{"tool_record_id"},
            .uniques = &.{&.{ "name", "remote_name", "owner", "server", "replay", "restart_limit", "wait_ms", "description_content_id", "input_schema_content_id" }},
            .foreign_keys = &.{
                references("description_content_id", "content", content_reference),
                references("input_schema_content_id", "content", content_reference),
            },
        },
        .{
            .name = "tool_set",
            .columns = &.{
                .{ .name = "tool_set_id", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
                .{ .name = "member_count", .type = .int, .check = r.between(r.field("member_count"), r.literal(0), r.literal(tool_defs.max_host_tool_records)) },
            },
            .primary_key = &.{"tool_set_id"},
            .uniques = &.{&.{"digest"}},
        },
        .{
            .name = "tool_set_member",
            .columns = &.{
                .{ .name = "tool_set_id", .type = .int },
                .{ .name = "ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "tool_record_id", .type = .int },
            },
            .primary_key = &.{ "tool_set_id", "ordinal" },
            .foreign_keys = &.{
                references("tool_set_id", "tool_set", &.{"tool_set_id"}),
                references("tool_record_id", "tool_record", &.{"tool_record_id"}),
            },
            .without_rowid = true,
        },
        .{
            .name = "host_tool_set",
            .columns = &.{
                .{ .name = "slot", .type = .int, .range = .{ .min = 1, .max = 1 } },
                .{ .name = "tool_set_id", .type = .int },
            },
            .primary_key = &.{"slot"},
            .foreign_keys = &.{
                references("tool_set_id", "tool_set", &.{"tool_set_id"}),
            },
        },
        .{
            .name = "model_fact",
            .columns = &.{
                .{ .name = "model_id", .type = .{ .text = .{ .min = 1, .max = 256 } } },
                .{ .name = "context_window", .type = .int, .nullable = true },
                .{ .name = "efforts", .type = .int, .range = .{ .min = 0, .max = 63 } },
                .{ .name = "openai_listed", .type = .flag },
                .{ .name = "generation", .type = .int },
                .{ .name = "output_limit", .type = .int, .nullable = true, .range = .{ .min = 0, .max = 4294967295 } },
            },
            .primary_key = &.{"model_id"},
        },
        .{
            .name = "model_catalog_source",
            .columns = &.{
                .{ .name = "slot", .type = .int, .range = .{ .min = 1, .max = 1 } },
                .{ .name = "etag", .type = .{ .text = .{ .min = 0, .max = 512 } }, .nullable = true },
                .{ .name = "generation", .type = .int },
                .{ .name = "fetched_at", .type = .int },
            },
            .primary_key = &.{"slot"},
        },
        .{
            .name = "session",
            .columns = &.{
                .{ .name = "session_ref", .type = .{ .text = .{ .min = 6, .max = 6 } }, .charset = "0123456789abcdefghjkmnpqrstvwxyz" },
                .{ .name = "workspace", .type = .{ .text = .{ .min = 1, .max = 4096 } } },
                provider_column,
                .{ .name = "prefix_seal", .type = .{ .bytes = .{ .min = prefix_seal.encoded_bytes, .max = prefix_seal.encoded_bytes } }, .nullable = true },
                .{ .name = "model", .type = .{ .text = .{ .min = 1, .max = 256 } } },
                .{ .name = "instructions_content_id", .type = .int },
                tool_set_column,
                .{ .name = "loaded_tool_set_id", .type = .int, .nullable = true },
                permission_mode_column,
                .{ .name = "output_schema_content_id", .type = .int, .nullable = true },
                .{ .name = "revision", .type = .int, .range = .{ .min = 1 } },
                compaction_trigger_column,
                .{ .name = "output_reservation", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                reasoning_effort_column,
                label_column,
                .{ .name = "created_at", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "next_position", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "created_seq", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "workspace_digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
                .{ .name = "workspace_key", .type = .int },
                .{ .name = "parent_ref", .type = .{ .text = null }, .nullable = true },
                .{ .name = "obligation_since", .type = .int, .nullable = true, .sqlite_added = true, .range = .{ .min = 1 } },
                .{ .name = "creator_ref", .type = .{ .text = null }, .nullable = true, .sqlite_added = true, .check = r.any(&.{ r.isNull(r.field("creator_ref")), r.compare(.ne, r.field("creator_ref"), r.field("session_ref")) }) },
                .{ .name = "archive_seq", .type = .int, .nullable = true, .sqlite_added = true, .range = .{ .min = 1 } },
                .{ .name = "app_tool_set_id", .type = .int, .nullable = true, .sqlite_added = true, .range = .{ .min = 1 } },
                .{ .name = "app_lane", .type = .{ .text = null }, .nullable = true, .sqlite_added = true, .check = r.any(&.{ r.isNull(r.field("app_lane")), r.compare(.eq, r.call(.octets, &.{r.field("app_lane")}), r.literal(6)) }) },
            },
            .primary_key = &.{"session_ref"},
            .uniques = &.{&.{"created_seq"}},
            .checks = &.{
                r.all(&.{ r.compare(.gt, r.field("workspace_key"), r.literal(0)), r.compare(.le, r.field("workspace_key"), r.field("created_seq")) }),
                r.any(&.{ r.isNull(r.field("parent_ref")), r.compare(.ne, r.field("parent_ref"), r.field("session_ref")) }),
            },
            .foreign_keys = &.{
                references("instructions_content_id", "content", content_reference),
                references("tool_set_id", "tool_set", &.{"tool_set_id"}),
                references("loaded_tool_set_id", "tool_set", &.{"tool_set_id"}),
                references("output_schema_content_id", "content", content_reference),
                references("parent_ref", "session", session_reference),
                references("creator_ref", "session", session_reference),
                references("archive_seq", "core_command", &.{"command_seq"}),
                references("app_tool_set_id", "tool_set", &.{"tool_set_id"}),
                references("app_lane", "session", session_reference),
            },
        },
        .{
            .name = "core_command",
            .columns = &.{
                .{ .name = "command_key", .type = .{ .text = .{ .max = 128 } } },
                .{ .name = "kind", .type = .int, .range = .{ .min = 1, .max = 9 } },
                .{ .name = "target", .type = .{ .text = .{ .max = 128 } } },
                .{ .name = "input_digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
                .{ .name = "primary_content_id", .type = .int, .nullable = true, .holds = .value },
                .{ .name = "secondary_content_id", .type = .int, .nullable = true },
                .{ .name = "accepted", .type = .flag },
                .{ .name = "code", .type = .{ .text = .{ .max = 96 } } },
                .{ .name = "revision", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "created", .type = .flag },
                .{ .name = "command_seq", .type = .int, .range = .{ .min = 1 } },
                // Bits of required_settings.Setting: set exactly with a missing_settings rejection.
                .{ .name = "missing_settings", .type = .int, .nullable = true, .check = r.any(&.{ r.all(&.{ r.isNull(r.field("missing_settings")), r.compare(.ne, r.field("code"), r.literal("missing_settings")) }), r.all(&.{ r.isNotNull(r.field("missing_settings")), r.compare(.eq, r.field("code"), r.literal("missing_settings")), r.between(r.field("missing_settings"), r.literal(1), r.literal(7)) }) }) },
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
                .{ .name = "revision", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "command_key", .type = .{ .text = null } },
                .{ .name = "workspace", .type = .{ .text = null } },
                provider_column,
                codec_column,
                codec_options_column,
                .{ .name = "model", .type = .{ .text = null } },
                .{ .name = "instructions_content_id", .type = .int },
                .{ .name = "instructions_updated", .type = .flag },
                tool_set_column,
                .{ .name = "loaded_tool_set_id", .type = .int, .nullable = true },
                permission_mode_column,
                .{ .name = "output_schema_content_id", .type = .int, .nullable = true },
                compaction_trigger_column,
                .{ .name = "output_reservation", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                reasoning_effort_column,
                label_column,
                .{ .name = "effort_source_revision", .type = .int, .default = "1", .check = r.all(&.{ r.compare(.gt, r.field("effort_source_revision"), r.literal(0)), r.compare(.le, r.field("effort_source_revision"), r.field("revision")) }) },
                .{ .name = "app_tool_set_id", .type = .int, .nullable = true, .sqlite_added = true, .range = .{ .min = 1 } },
            },
            .primary_key = &.{ "session_ref", "revision" },
            .uniques = &.{&.{"command_key"}},
            .foreign_keys = &.{
                references("session_ref", "session", session_reference),
                references("command_key", "core_command", command_reference),
                references("instructions_content_id", "content", content_reference),
                references("tool_set_id", "tool_set", &.{"tool_set_id"}),
                references("loaded_tool_set_id", "tool_set", &.{"tool_set_id"}),
                references("app_tool_set_id", "tool_set", &.{"tool_set_id"}),
                .{ .columns = &.{ "session_ref", "effort_source_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
                references("output_schema_content_id", "content", content_reference),
            },
            .without_rowid = true,
        },
        .{
            .name = "session_change",
            .columns = &.{
                .{ .name = "session_ref", .type = .{ .text = null } },
                .{ .name = "position", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "revision", .type = .int, .check = r.compare(.gt, r.field("revision"), r.literal(1)) },
                .{ .name = "field", .type = .{ .tag = session_settings.revision_fields } },
                .{ .name = "changed_at", .type = .int, .range = .{ .min = 1 } },
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
            .checks = &.{
                r.compare(.eq, r.compare(.eq, r.field("field"), r.literal("reasoning_effort_refused")), r.isNotNull(r.field("provider_text"))),
                r.compare(.eq, r.compare(.eq, r.field("field"), r.literal("reasoning_effort_refused")), r.isNotNull(r.field("refused_operation_id"))),
            },
            .without_rowid = true,
        },
        .{
            .name = "message_admission",
            .columns = &.{
                .{ .name = "admission_id", .type = .int, .range = .{ .min = 1 }, .read_by = .both },
                .{ .name = "session_ref", .type = .{ .text = null }, .read_by = .both },
                .{ .name = "command_key", .type = .{ .text = null }, .read_by = .both },
                .{ .name = "content_id", .type = .int, .read_by = .both, .holds = .value },
                .{ .name = "admission_position", .type = .int, .nullable = true, .check = r.compare(.gt, r.field("admission_position"), r.literal(0)) },
                .{ .name = "turn_id", .type = .int, .nullable = true },
                .{ .name = "admitted_at", .type = .int, .range = .{ .min = 1 }, .read_by = .both },
                .{ .name = "sender_session_ref", .type = .{ .text = null }, .nullable = true, .read_by = .both },
                .{ .name = "source_action_id", .type = .int, .nullable = true },
                .{ .name = "source_kind", .type = .int, .range = .{ .min = 1, .max = 5 } },
            },
            .primary_key = &.{"admission_id"},
            .uniques = &.{ &.{"command_key"}, &.{"source_action_id"}, &.{ "admission_id", "source_kind" } },
            .foreign_keys = &.{
                references("session_ref", "session", session_reference),
                references("command_key", "core_command", command_reference),
                references("content_id", "content", content_reference),
                references("turn_id", "turn", &.{"turn_id"}),
                references("sender_session_ref", "session", session_reference),
                references("source_action_id", "action_operation", &.{"action_id"}),
            },
            .checks = &.{
                r.any(&.{ r.isNull(r.field("source_action_id")), r.isNull(r.field("sender_session_ref")) }),
                r.any(&.{ r.group(r.all(&.{ r.compare(.eq, r.field("source_kind"), r.literal(1)), r.isNull(r.field("sender_session_ref")), r.isNull(r.field("source_action_id")) })), r.group(r.all(&.{ r.compare(.eq, r.field("source_kind"), r.literal(2)), r.isNotNull(r.field("sender_session_ref")) })), r.group(r.all(&.{ r.compare(.eq, r.field("source_kind"), r.literal(3)), r.isNotNull(r.field("source_action_id")) })), r.group(r.all(&.{ r.inList(r.field("source_kind"), &.{ r.literal(4), r.literal(5) }), r.isNull(r.field("sender_session_ref")) })) }),
            },
        },
        .{
            .name = "action_value",
            .columns = &.{
                .{ .name = "action_id", .type = .int },
                .{ .name = "ordinal", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "handle", .type = .{ .text = .{ .min = 32, .max = 32 } }, .charset = "0-9a-f" },
                .{ .name = "publication_key", .type = .{ .text = .{ .min = 1, .max = 128 } } },
                .{ .name = "content_id", .type = .int },
                .{ .name = "admission_id", .type = .int, .nullable = true },
                .{ .name = "published_at", .type = .int, .range = .{ .min = 1 } },
            },
            .primary_key = &.{ "action_id", "ordinal" },
            .uniques = &.{ &.{ "handle", "publication_key" }, &.{"admission_id"} },
            .foreign_keys = &.{ references("action_id", "action_operation", &.{"action_id"}), references("content_id", "content", content_reference), references("admission_id", "message_admission", &.{"admission_id"}) },
            .without_rowid = true,
        },
        .{
            .name = "turn",
            .columns = &.{
                .{ .name = "turn_id", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "session_ref", .type = .{ .text = null } },
                .{ .name = "first_admission_id", .type = .int },
                .{ .name = "input_cutoff", .type = .int, .check = r.compare(.ge, r.field("input_cutoff"), r.field("first_admission_id")) },
                .{ .name = "operation_id", .type = .int },
                .{ .name = "outcome_code", .type = .{ .text = .{ .min = 1, .max = 96 } }, .nullable = true },
                .{ .name = "outcome_content_id", .type = .int, .nullable = true },
                .{ .name = "outcome_position", .type = .int, .nullable = true, .check = r.compare(.gt, r.field("outcome_position"), r.literal(0)) },
                .{ .name = "outcome_at", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "continuation_operation_id", .type = .int, .nullable = true, .check = r.any(&.{ r.isNull(r.field("continuation_operation_id")), r.compare(.le, r.field("continuation_operation_id"), r.field("operation_id")) }) },
            },
            .primary_key = &.{"turn_id"},
            .foreign_keys = &.{
                references("session_ref", "session", session_reference),
                references("first_admission_id", "message_admission", &.{"admission_id"}),
                references("outcome_content_id", "content", content_reference),
            },
            .checks = &.{
                r.compare(.eq, r.isNull(r.field("outcome_code")), r.isNull(r.field("outcome_at"))),
            },
        },
        .{
            .name = "session_stop",
            .columns = &.{
                .{ .name = "command_key", .type = .{ .text = null } },
                .{ .name = "session_ref", .type = .{ .text = null } },
                .{ .name = "selected_turn_id", .type = .int, .nullable = true },
                .{ .name = "position", .type = .int, .nullable = true, .check = r.compare(.gt, r.field("position"), r.literal(0)) },
                .{ .name = "admission_cutoff", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "stopped_at", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "parent_caused", .type = .flag, .default = "0" },
                .{ .name = "action_cutoff", .type = .int, .default = "0", .range = .{ .min = 0 }, .sqlite_added = true },
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
            .name = "session_pin",
            .columns = &.{
                .{ .name = "session_ref", .type = .{ .text = null } },
                .{ .name = "command_key", .type = .{ .text = null }, .nullable = true },
            },
            .primary_key = &.{"session_ref"},
            .uniques = &.{&.{"command_key"}},
            .foreign_keys = &.{
                references("session_ref", "session", session_reference),
                references("command_key", "core_command", command_reference),
            },
            .without_rowid = true,
        },
        .{
            .name = "session_pin_command",
            .columns = &.{
                .{ .name = "command_key", .type = .{ .text = null } },
                .{ .name = "pinned", .type = .flag },
            },
            .primary_key = &.{"command_key"},
            .foreign_keys = &.{references("command_key", "core_command", command_reference)},
            .without_rowid = true,
        },
        .{
            .name = "session_stop_owed",
            .columns = &.{
                .{ .name = "child_ref", .type = .{ .text = null } },
                .{ .name = "cause_ref", .type = .{ .text = null } },
                .{ .name = "cause_position", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "settled", .type = .int, .range = .{ .min = 0, .max = 1 } },
            },
            .primary_key = &.{ "child_ref", "cause_ref", "cause_position" },
            .foreign_keys = &.{
                references("child_ref", "session", session_reference),
                references("cause_ref", "session", session_reference),
            },
            .without_rowid = true,
        },
        .{
            .name = "session_forward",
            .columns = &.{
                .{ .name = "forward_id", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "target_ref", .type = .{ .text = null } },
                .{ .name = "child_ref", .type = .{ .text = null } },
                .{ .name = "kind", .type = .int, .range = .{ .min = 1, .max = 2 } },
                .{ .name = "source_id", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "position", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "ordinal", .type = .int, .range = .{ .min = 0, .max = 0 } },
                .{ .name = "delivered_at", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "message_delivered", .type = .flag, .nullable = true },
                .{ .name = "suppress_message", .type = .flag, .default = "0" },
            },
            .primary_key = &.{"forward_id"},
            .uniques = &.{&.{ "target_ref", "kind", "source_id" }},
            .checks = &.{
                r.compare(.eq, r.isNull(r.field("position")), r.isNull(r.field("delivered_at"))),
                r.compare(.ne, r.field("target_ref"), r.field("child_ref")),
            },
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
                .{ .name = "turn_id", .type = .{ .text = .{ .min = 1, .max = 20 } }, .charset = "0-9" },
                .{ .name = "operation_id", .type = .{ .text = .{ .min = 1, .max = 20 } }, .charset = "0-9" },
            },
            .primary_key = &.{"command_key"},
            .foreign_keys = &.{references("command_key", "core_command", command_reference)},
            .without_rowid = true,
        },
        .{
            .name = "model_operation",
            .columns = &.{
                .{ .name = "operation_id", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "turn_id", .type = .int },
                .{ .name = "session_ref", .type = .{ .text = null } },
                .{ .name = "settings_revision", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "input_cutoff", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "admission_position", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "purpose", .type = .flag, .default = "0" },
                compaction_trigger_column,
                .{ .name = "output_reservation", .type = .int, .range = .{ .min = 0 } },
                reasoning_effort_column,
                .{ .name = "output_item_count", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                .{ .name = "attempt_ordinal", .type = .int, .check = r.between(r.field("attempt_ordinal"), r.literal(1), r.literal(retry_policy.maximum_attempts)) },
                .{ .name = "auth_refresh_claimed", .type = .flag, .default = "0" },
                .{ .name = "retry_due_at_ms", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                .{ .name = "last_failure_code", .type = .{ .text = .{ .min = 1, .max = 96 } }, .nullable = true },
                .{ .name = "resolution_code", .type = .{ .text = .{ .min = 1, .max = 96 } }, .nullable = true },
                .{ .name = "resolution_content_id", .type = .int, .nullable = true },
                .{ .name = "response_id", .type = .{ .text = .{ .max = 256 } }, .nullable = true },
                .{ .name = "model_evidence", .type = .{ .bytes = .{ .min = 7, .max = 775 } }, .nullable = true },
                .{ .name = "request_id", .type = .{ .text = .{ .max = 256 } }, .nullable = true },
                .{ .name = "usage_uncached_tokens", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                .{ .name = "usage_cache_read_tokens", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                .{ .name = "usage_cache_write_tokens", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                .{ .name = "usage_output_tokens", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                .{ .name = "interrupted_by_command_key", .type = .{ .text = null }, .nullable = true },
                .{ .name = "attempt_at", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "retry_scheduled_at", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "resolved_at", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "history_floor", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "history_level", .type = .int, .nullable = true, .range = .{ .min = 1, .max = 3 } },
                .{ .name = "history_dropped", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                tool_set_column,
                .{ .name = "effort_source_revision", .type = .int, .default = "1", .check = r.all(&.{ r.compare(.gt, r.field("effort_source_revision"), r.literal(0)), r.compare(.le, r.field("effort_source_revision"), r.field("settings_revision")) }) },
                .{ .name = "previous_reasoning_effort", .type = reasoning_effort_column.type, .nullable = true },
                .{ .name = "effort_update", .type = .flag, .default = "0", .check = r.group(r.any(&.{ r.compare(.eq, r.field("effort_update"), r.literal(0)), r.isNotNull(r.field("reasoning_effort")) })) },
                .{ .name = "previous_effort_override", .type = reasoning_effort_column.type, .nullable = true },
                .{ .name = "latency_ms", .type = .int, .nullable = true, .sqlite_added = true, .range = .{ .min = 0 } },
                .{ .name = "first_event_ms", .type = .int, .nullable = true, .sqlite_added = true, .range = .{ .min = 0 } },
                .{ .name = "context_window", .type = .int, .range = .{ .min = 0, .max = 4294967295 } },
                .{ .name = "output_limit", .type = .int, .default = "32000", .sqlite_added = true, .range = .{ .min = 0, .max = 4294967295 } },
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
                r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("usage_uncached_tokens")), r.isNull(r.field("usage_cache_read_tokens")), r.isNull(r.field("usage_cache_write_tokens")), r.isNull(r.field("usage_output_tokens")) })), r.group(r.all(&.{ r.isNotNull(r.field("usage_uncached_tokens")), r.isNotNull(r.field("usage_cache_read_tokens")), r.isNotNull(r.field("usage_cache_write_tokens")), r.isNotNull(r.field("usage_output_tokens")) })) }),
                r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("resolution_code")), r.isNotNull(r.field("retry_due_at_ms")) })), r.group(r.all(&.{ r.isNotNull(r.field("resolution_code")), r.isNull(r.field("retry_due_at_ms")) })) }),
                r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("resolution_code")), r.compare(.eq, r.field("retry_due_at_ms"), r.literal(0)), r.isNotNull(r.field("attempt_at")), r.isNull(r.field("retry_scheduled_at")), r.isNull(r.field("resolved_at")) })), r.group(r.all(&.{ r.isNull(r.field("resolution_code")), r.compare(.gt, r.field("retry_due_at_ms"), r.literal(0)), r.isNull(r.field("attempt_at")), r.isNotNull(r.field("retry_scheduled_at")), r.isNull(r.field("resolved_at")) })), r.group(r.all(&.{ r.isNotNull(r.field("resolution_code")), r.isNull(r.field("attempt_at")), r.isNull(r.field("retry_scheduled_at")), r.isNotNull(r.field("resolved_at")) })) }),
                r.any(&.{ r.group(r.all(&.{ r.call(.same, &.{ r.field("resolution_code"), r.literal("interrupted") }), r.isNotNull(r.field("interrupted_by_command_key")) })), r.group(r.all(&.{ r.compare(.bang_ne, r.coalesce(&.{ r.field("resolution_code"), r.literal("") }), r.literal("interrupted")), r.isNull(r.field("interrupted_by_command_key")) })) }),
                r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("history_floor")), r.isNull(r.field("history_level")), r.isNull(r.field("history_dropped")) })), r.group(r.all(&.{ r.isNotNull(r.field("history_floor")), r.compare(.eq, r.field("purpose"), r.literal(1)), r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("history_level")), r.isNull(r.field("history_dropped")) })), r.group(r.all(&.{ r.isNotNull(r.field("history_level")), r.isNotNull(r.field("history_dropped")) })) }) })) }),
            },
        },
        .{
            .name = "message_skill",
            .columns = &.{
                .{ .name = "admission_id", .type = .int },
                .{ .name = "position", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "name", .type = .{ .text = .{ .min = 1, .max = 64 } }, .charset = "a-z0-9-" },
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
                .{ .name = "position", .type = .int, .range = .{ .min = 0 } },
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
                .{ .name = "entry_ordinal", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "session_position", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "entry_kind", .type = .int, .range = .{ .min = 1, .max = 4 } },
                .{ .name = "turn_id", .type = .int, .nullable = true },
                .{ .name = "source_admission_id", .type = .int, .nullable = true },
                .{ .name = "source_kind", .type = .int, .nullable = true },
                .{ .name = "source_revision", .type = .int, .nullable = true },
                .{ .name = "source_catalog_position", .type = .int, .nullable = true },
                .{ .name = "source_skill_admission_id", .type = .int, .nullable = true },
                .{ .name = "source_skill_position", .type = .int, .nullable = true },
                .{ .name = "source_operation_id", .type = .int, .nullable = true },
                .{ .name = "source_item_ordinal", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                .{ .name = "content_id", .type = .int, .holds = .value },
                .{ .name = "recorded_at", .type = .int, .range = .{ .min = 1 } },
            },
            .primary_key = &.{ "session_ref", "entry_ordinal" },
            .uniques = &.{ &.{"source_admission_id"}, &.{ "session_ref", "session_position" }, &.{ "session_ref", "source_revision" }, &.{ "session_ref", "source_catalog_position" }, &.{ "source_skill_admission_id", "source_skill_position" } },
            .foreign_keys = &.{
                references("turn_id", "turn", &.{"turn_id"}),
                references("source_admission_id", "message_admission", &.{"admission_id"}),
                .{ .columns = &.{ "source_admission_id", "source_kind" }, .references = "message_admission", .referenced = &.{ "admission_id", "source_kind" } },
                references("source_operation_id", "model_operation", &.{"operation_id"}),
                references("content_id", "content", content_reference),
                .{ .columns = &.{ "session_ref", "source_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
                .{ .columns = &.{ "session_ref", "source_catalog_position" }, .references = "session_skill_catalog", .referenced = &.{ "session_ref", "position" } },
                .{ .columns = &.{ "source_skill_admission_id", "source_skill_position" }, .references = "message_skill", .referenced = &.{ "admission_id", "position" } },
                .{ .columns = &.{ "source_operation_id", "source_item_ordinal" }, .references = "model_output_item", .referenced = &.{ "operation_id", "item_ordinal" } },
            },
            .checks = &.{
                r.compare(.eq, r.compare(.eq, r.field("entry_kind"), r.literal(1)), r.isNotNull(r.field("source_kind"))),
                r.compare(.eq, r.compare(.eq, r.field("entry_kind"), r.literal(3)), r.isNotNull(r.field("source_item_ordinal"))),
                r.compare(.eq, r.isNull(r.field("turn_id")), r.isNotNull(r.field("source_catalog_position"))),
                r.any(&.{ r.isNull(r.field("source_catalog_position")), r.compare(.eq, r.field("source_catalog_position"), r.field("session_position")) }),
                r.compare(.eq, r.isNull(r.field("source_skill_admission_id")), r.isNull(r.field("source_skill_position"))),
                r.compare(.eq, r.compare(.eq, r.field("entry_kind"), r.literal(4)), r.isNotNull(r.field("source_skill_position"))),
                r.any(&.{ r.group(r.all(&.{ r.compare(.eq, r.field("entry_kind"), r.literal(1)), r.isNotNull(r.field("source_admission_id")), r.isNull(r.field("source_revision")), r.isNull(r.field("source_catalog_position")), r.isNull(r.field("source_operation_id")) })), r.group(r.all(&.{ r.compare(.eq, r.field("entry_kind"), r.literal(2)), r.isNull(r.field("source_admission_id")), r.any(&.{ r.group(r.all(&.{ r.isNotNull(r.field("source_revision")), r.isNull(r.field("source_catalog_position")) })), r.group(r.all(&.{ r.isNull(r.field("source_revision")), r.isNotNull(r.field("source_catalog_position")) })) }), r.isNull(r.field("source_operation_id")) })), r.group(r.all(&.{ r.compare(.eq, r.field("entry_kind"), r.literal(3)), r.isNull(r.field("source_admission_id")), r.isNull(r.field("source_revision")), r.isNull(r.field("source_catalog_position")), r.isNotNull(r.field("source_operation_id")) })), r.group(r.all(&.{ r.compare(.eq, r.field("entry_kind"), r.literal(4)), r.isNull(r.field("source_admission_id")), r.isNull(r.field("source_revision")), r.isNull(r.field("source_catalog_position")), r.isNull(r.field("source_operation_id")) })) }),
            },
            .without_rowid = true,
        },
        .{
            .name = "model_output_item",
            .columns = &.{
                .{ .name = "operation_id", .type = .int },
                .{ .name = "item_ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "session_ref", .type = .{ .text = null } },
                .{ .name = "session_position", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "item_kind", .type = .int, .range = .{ .min = 1, .max = 5 } },
                .{ .name = "message_content_id", .type = .int, .nullable = true, .check = r.compare(.eq, r.isNotNull(r.field("message_content_id")), r.compare(.eq, r.field("item_kind"), r.literal(2))) },
                .{ .name = "attempt_ordinal", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "item_id_digest", .type = .{ .bytes = .{ .min = 32, .max = 32 } } },
                .{ .name = "replay_omits_reasoning_text", .type = .flag, .check = r.group(r.any(&.{ r.compare(.eq, r.field("replay_omits_reasoning_text"), r.literal(0)), r.compare(.eq, r.field("item_kind"), r.literal(1)) })) },
                .{ .name = "phase", .type = .int, .default = "0", .check = r.all(&.{ r.inList(r.field("phase"), &.{ r.literal(0), r.literal(1), r.literal(2) }), r.any(&.{ r.compare(.eq, r.field("phase"), r.literal(0)), r.compare(.eq, r.field("item_kind"), r.literal(2)) }) }) },
                .{ .name = "extras_content_id", .type = .int },
                .{ .name = "part_count", .type = .int, .check = r.all(&.{ r.compare(.ge, r.field("part_count"), r.literal(0)), r.any(&.{ r.compare(.eq, r.field("part_count"), r.literal(0)), r.inList(r.field("item_kind"), &.{ r.literal(1), r.literal(2) }) }) }) },
                .{ .name = "hosted_action", .type = .int, .nullable = true, .check = r.all(&.{ r.inList(r.field("hosted_action"), &.{ r.literal(0), r.literal(1), r.literal(2), r.literal(3) }), r.compare(.eq, r.isNotNull(r.field("hosted_action")), r.compare(.eq, r.field("item_kind"), r.literal(5))) }) },
                .{ .name = "hosted_pattern_content_id", .type = .int, .nullable = true, .check = r.any(&.{ r.isNull(r.field("hosted_pattern_content_id")), r.compare(.eq, r.field("item_kind"), r.literal(5)) }) },
                .{ .name = "call_failed", .type = .flag, .default = "0", .check = r.group(r.any(&.{ r.compare(.eq, r.field("call_failed"), r.literal(0)), r.compare(.eq, r.field("item_kind"), r.literal(5)) })) },
            },
            .primary_key = &.{ "operation_id", "item_ordinal" },
            .uniques = &.{ &.{ "session_ref", "session_position" }, &.{ "operation_id", "item_id_digest" } },
            .foreign_keys = &.{
                references("operation_id", "model_operation", &.{"operation_id"}),
                references("message_content_id", "content", content_reference),
                references("extras_content_id", "content", content_reference),
                references("hosted_pattern_content_id", "content", content_reference),
            },
            .without_rowid = true,
        },
        // One string a hosted call named, in provider order: a search's query, each of its `queries`, or the url of an open or find.
        // The strings are public content; the line a reader shows is derived from them and never stored.
        .{
            .name = "hosted_target",
            .columns = &.{
                .{ .name = "operation_id", .type = .int },
                .{ .name = "item_ordinal", .type = .int },
                .{ .name = "target_ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "content_id", .type = .int },
            },
            .primary_key = &.{ "operation_id", "item_ordinal", "target_ordinal" },
            .foreign_keys = &.{
                .{ .columns = &.{ "operation_id", "item_ordinal" }, .references = "model_output_item", .referenced = &.{ "operation_id", "item_ordinal" } },
                references("content_id", "content", content_reference),
            },
            .without_rowid = true,
        },
        .{
            .name = "model_output_part",
            .columns = &.{
                .{ .name = "operation_id", .type = .int },
                .{ .name = "item_ordinal", .type = .int },
                .{ .name = "part_ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "part_array", .type = .int, .check = r.inList(r.field("part_array"), &.{ r.literal(1), r.literal(2) }) },
                .{ .name = "part_kind", .type = .int, .check = r.any(&.{ r.compare(.eq, r.field("part_kind"), r.literal(0)), r.group(r.all(&.{ r.inList(r.field("part_kind"), &.{ r.literal(1), r.literal(2), r.literal(4) }), r.compare(.eq, r.field("part_array"), r.literal(1)) })), r.group(r.all(&.{ r.compare(.eq, r.field("part_kind"), r.literal(3)), r.compare(.eq, r.field("part_array"), r.literal(2)) })) }) },
                .{ .name = "text_length", .type = .int, .nullable = true, .range = .{ .min = 0 } },
                .{ .name = "text_content_id", .type = .int, .nullable = true },
                .{ .name = "extras_content_id", .type = .int },
            },
            .primary_key = &.{ "operation_id", "item_ordinal", "part_ordinal" },
            .foreign_keys = &.{
                references("text_content_id", "content", content_reference),
                references("extras_content_id", "content", content_reference),
            },
            .checks = &.{
                r.all(&.{ r.compare(.eq, r.isNotNull(r.field("text_length")), r.group(r.inList(r.field("part_kind"), &.{ r.literal(1), r.literal(2) }))), r.compare(.eq, r.isNotNull(r.field("text_content_id")), r.group(r.inList(r.field("part_kind"), &.{ r.literal(3), r.literal(4) }))) }),
            },
            .without_rowid = true,
        },
        .{
            .name = "model_tool_call",
            .columns = &.{
                .{ .name = "operation_id", .type = .int },
                .{ .name = "session_ref", .type = .{ .text = null } },
                .{ .name = "call_ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "item_ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "name_content_id", .type = .int },
                .{ .name = "call_id_content_id", .type = .int },
                .{ .name = "arguments_content_id", .type = .int },
                .{ .name = "label", .type = .{ .text = .{ .min = 1, .max = 200 } }, .nullable = true },
                .{ .name = "subject", .type = .{ .text = .{ .min = 1, .max = 6 } }, .nullable = true },
                .{ .name = "field_metadata", .type = .{ .bytes = .{ .min = 120, .max = 120 } } },
                .{ .name = "rejection_code", .type = .{ .tag = &.{ "unknown_tool", "invalid_arguments" } }, .nullable = true },
                .{ .name = "rejection_content_id", .type = .int, .nullable = true },
                .{ .name = "acceptance_position", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "action_kind", .type = .int, .nullable = true, .range = .{ .min = 1, .max = 1 } },
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
                r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("rejection_code")), r.isNull(r.field("rejection_content_id")), r.isNull(r.field("acceptance_position")), r.call(.same, &.{ r.field("action_kind"), r.literal(1) }) })), r.group(r.all(&.{ r.isNotNull(r.field("rejection_code")), r.isNotNull(r.field("rejection_content_id")), r.isNotNull(r.field("acceptance_position")), r.isNull(r.field("action_kind")) })) }),
            },
            .without_rowid = true,
        },
        .{
            .name = "action_operation",
            .columns = &.{
                .{ .name = "action_id", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "parent_operation_id", .type = .int },
                .{ .name = "call_ordinal", .type = .int, .range = .{ .min = 0 } },
                .{ .name = "session_ref", .type = .{ .text = null } },
                .{ .name = "tool_kind", .type = .int, .range = .{ .min = 1, .max = 1 } },
                .{ .name = "permission_revision", .type = .int, .range = .{ .min = 1 } },
                .{ .name = "authorized", .type = .flag },
                .{ .name = "attempt_ordinal", .type = .int, .default = "0", .check = r.inList(r.field("attempt_ordinal"), &.{ r.literal(0), r.literal(1) }) },
                .{ .name = "bash_timeout_override_ms", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "attempt_timeout_ms", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "sender_handle", .type = .{ .text = .{ .min = 32, .max = 32 } }, .nullable = true, .charset = "0-9a-f" },
                .{
                    .name = "resolution_code",
                    .type = .{ .tag = &.{ "denied", "cancelled", "succeeded", "failed", "timed_out", "indeterminate", "storage_failed", "spawn_failed", "infrastructure_shutdown" } },
                    .nullable = true,
                },
                .{ .name = "resolution_content_id", .type = .int, .nullable = true, .holds = .value },
                .{ .name = "acceptance_position", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "attempt_at", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "decided_at", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "resolved_at", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "approval_position", .type = .int, .nullable = true, .range = .{ .min = 1 } },
                .{ .name = "background_content_id", .type = .int, .nullable = true, .sqlite_added = true, .holds = .value },
                .{ .name = "background_position", .type = .int, .nullable = true, .check = r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("background_content_id")), r.isNull(r.field("background_position")) })), r.group(r.all(&.{ r.isNotNull(r.field("background_content_id")), r.isNotNull(r.field("background_position")), r.compare(.gt, r.field("background_position"), r.literal(0)), r.any(&.{ r.isNull(r.field("acceptance_position")), r.compare(.lt, r.field("background_position"), r.field("acceptance_position")) }) })) }), .sqlite_added = true },
                .{ .name = "background_at", .type = .int, .nullable = true, .check = r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("background_position")), r.isNull(r.field("background_at")) })), r.group(r.all(&.{ r.isNotNull(r.field("background_position")), r.isNotNull(r.field("background_at")), r.compare(.gt, r.field("background_at"), r.literal(0)) })) }), .sqlite_added = true },
                // What a tool said about itself when it resolved the call: the words of its row around one Session it
                // names (NULL: the row keeps its call line), where in the words that Session belongs, and whether the
                // call handed work on (1) or just finished (0). No foreign key: the line is a record of what the call said.
                .{ .name = "outcome_text", .type = .{ .text = .{ .min = 0, .max = 200 } }, .nullable = true, .sqlite_added = true },
                .{ .name = "outcome_link_at", .type = .int, .nullable = true, .sqlite_added = true, .range = .{ .min = 0 } },
                .{ .name = "outcome_link_session", .type = .{ .text = .{ .min = 1, .max = 128 } }, .nullable = true, .sqlite_added = true },
                .{
                    .name = "outcome_completion",
                    .type = .int,
                    .nullable = true,
                    .sqlite_added = true,
                    .check = r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("outcome_text")), r.isNull(r.field("outcome_link_at")), r.isNull(r.field("outcome_link_session")), r.isNull(r.field("outcome_completion")) })), r.group(r.all(&.{ r.isNotNull(r.field("resolution_code")), r.isNotNull(r.field("outcome_text")), r.isNotNull(r.field("outcome_completion")), r.inList(r.field("outcome_completion"), &.{ r.literal(0), r.literal(1) }), r.compare(.eq, r.isNull(r.field("outcome_link_at")), r.isNull(r.field("outcome_link_session"))) })) }),
                },
            },
            .primary_key = &.{"action_id"},
            .uniques = &.{&.{ "parent_operation_id", "call_ordinal" }},
            .foreign_keys = &.{
                references("parent_operation_id", "model_operation", &.{"operation_id"}),
                references("session_ref", "session", session_reference),
                references("resolution_content_id", "content", content_reference),
                references("background_content_id", "content", content_reference),
                .{ .columns = &.{ "parent_operation_id", "session_ref" }, .references = "model_operation", .referenced = &.{ "operation_id", "session_ref" } },
                .{ .columns = &.{ "parent_operation_id", "call_ordinal", "tool_kind" }, .references = "model_tool_call", .referenced = &.{ "operation_id", "call_ordinal", "action_kind" } },
                .{ .columns = &.{ "session_ref", "permission_revision" }, .references = "session_revision", .referenced = &.{ "session_ref", "revision" } },
            },
            .checks = &.{
                r.any(&.{ r.call(.distinct, &.{ r.field("resolution_code"), r.literal("denied") }), r.group(r.all(&.{ r.compare(.eq, r.field("authorized"), r.literal(0)), r.compare(.eq, r.field("attempt_ordinal"), r.literal(0)) })) }),
                r.any(&.{ r.group(r.all(&.{ r.compare(.eq, r.field("attempt_ordinal"), r.literal(0)), r.isNull(r.field("attempt_timeout_ms")) })), r.group(r.all(&.{ r.compare(.eq, r.field("attempt_ordinal"), r.literal(1)), r.isNotNull(r.field("attempt_timeout_ms")) })) }),
                r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("resolution_code")), r.isNull(r.field("resolution_content_id")), r.isNull(r.field("acceptance_position")) })), r.group(r.all(&.{ r.isNotNull(r.field("resolution_code")), r.isNotNull(r.field("resolution_content_id")), r.isNotNull(r.field("acceptance_position")) })) }),
                r.compare(.eq, r.compare(.eq, r.field("attempt_ordinal"), r.literal(1)), r.isNotNull(r.field("attempt_at"))),
                r.compare(.eq, r.compare(.eq, r.field("authorized"), r.literal(1)), r.isNotNull(r.field("decided_at"))),
                r.compare(.eq, r.isNull(r.field("resolution_code")), r.isNull(r.field("resolved_at"))),
            },
        },
        .{
            .name = "permission_decision_command",
            .columns = &.{
                .{ .name = "command_key", .type = .{ .text = null } },
                .{ .name = "action_id", .type = .{ .text = .{ .min = 1, .max = 20 } }, .charset = "0-9" },
                .{ .name = "decision", .type = .{ .tag = &.{ "allow_once", "deny" } } },
            },
            .primary_key = &.{"command_key"},
            .foreign_keys = &.{references("command_key", "core_command", command_reference)},
            .without_rowid = true,
        },
        .{
            .name = "action_stop",
            .columns = &.{
                .{ .name = "stop_key", .type = .{ .text = .{ .max = 130 } } },
                .{ .name = "source_action_id", .type = .int, .nullable = true },
                .{ .name = "source_command_key", .type = .{ .text = null }, .nullable = true },
                .{ .name = "target_action_id", .type = .int },
            },
            .primary_key = &.{"stop_key"},
            .uniques = &.{ &.{"source_action_id"}, &.{"source_command_key"} },
            .foreign_keys = &.{
                references("source_action_id", "action_operation", &.{"action_id"}),
                references("source_command_key", "core_command", command_reference),
                references("target_action_id", "action_operation", &.{"action_id"}),
            },
            .checks = &.{
                r.compare(.ne, r.field("source_action_id"), r.field("target_action_id")),
                r.compare(.ne, r.isNull(r.field("source_action_id")), r.isNull(r.field("source_command_key"))),
            },
            .without_rowid = true,
        },
        .{
            .name = "action_stop_command",
            .columns = &.{
                .{ .name = "command_key", .type = .{ .text = null } },
                .{ .name = "action_id", .type = .{ .text = .{ .min = 1, .max = 20 } }, .charset = "0-9" },
                .{ .name = "resolution_position", .type = .int, .nullable = true, .check = r.compare(.gt, r.field("resolution_position"), r.literal(0)) },
            },
            .primary_key = &.{"command_key"},
            .foreign_keys = &.{references("command_key", "core_command", command_reference)},
            .without_rowid = true,
        },
        .{
            .name = "action_control_command",
            .columns = &.{
                .{ .name = "command_key", .type = .{ .text = null } },
                .{ .name = "action_id", .type = .{ .text = .{ .min = 1, .max = 20 } }, .charset = "0-9" },
                .{ .name = "selected_action_id", .type = .int, .nullable = true },
                .{ .name = "selection", .type = .{ .tag = &.{ "background", "final" } }, .nullable = true },
                .{ .name = "selection_position", .type = .int, .nullable = true, .check = r.compare(.gt, r.field("selection_position"), r.literal(0)) },
            },
            .primary_key = &.{"command_key"},
            .foreign_keys = &.{
                references("command_key", "core_command", command_reference),
                references("selected_action_id", "action_operation", &.{"action_id"}),
            },
            .checks = &.{
                r.any(&.{ r.group(r.all(&.{ r.isNull(r.field("selected_action_id")), r.isNull(r.field("selection")), r.isNull(r.field("selection_position")) })), r.group(r.all(&.{ r.isNotNull(r.field("selected_action_id")), r.isNotNull(r.field("selection")), r.isNotNull(r.field("selection_position")) })) }),
            },
            .without_rowid = true,
        },
    };
};

pub const indexes = [_]Index{
    .{ .name = "message_admission_activity", .table = "message_admission", .columns = &.{ "session_ref", "source_kind", "admission_position" } },
    .{ .name = "conversation_entry_activity_user", .table = "conversation_entry", .columns = &.{ "session_ref", "entry_kind", "source_kind", "session_position" } },
    .{ .name = "conversation_entry_activity_assistant", .table = "conversation_entry", .columns = &.{ "session_ref", "entry_kind", "session_position" } },
    .{ .name = "action_stop_target", .table = "action_stop", .columns = &.{"target_action_id"} },
    .{ .name = "content_part_by_part", .table = "content_part", .columns = &.{"part_content_id"} },
    .{ .name = "session_obligation_parent", .table = "session", .columns = &.{ "parent_ref", "obligation_since", "session_ref" }, .where = "obligation_since IS NOT NULL" },
    .{ .name = "session_forward_owed_message", .table = "session_forward", .columns = &.{ "target_ref", "message_delivered" } },
    .{ .name = "session_workspace_list", .table = "session", .columns = &.{ "workspace_digest", "created_seq" } },
    .{ .name = "session_creator", .table = "session", .columns = &.{ "creator_ref", "session_ref" } },
    .{ .name = "session_tab", .table = "session", .columns = &.{ "archive_seq", "created_seq" } },
    .{ .name = "turn_one_active_per_session", .table = "turn", .columns = &.{"session_ref"}, .unique = true, .where = "outcome_code IS NULL" },
    .{ .name = "turn_tool_continuation", .table = "turn", .columns = &.{"operation_id"}, .where = "outcome_code IS NULL AND continuation_operation_id=operation_id" },
    .{ .name = "message_admission_session_order", .table = "message_admission", .columns = &.{ "session_ref", "turn_id", "admission_id" } },
    .{ .name = "message_admission_pending", .table = "message_admission", .columns = &.{ "admission_id", "session_ref" }, .where = "turn_id IS NULL" },
    .{ .name = "message_admission_session_pending", .table = "message_admission", .columns = &.{ "session_ref", "admission_id" }, .where = "turn_id IS NULL" },
    .{ .name = "message_admission_person", .table = "message_admission", .columns = &.{ "session_ref", "admission_position" }, .where = "source_kind=1" },
    .{ .name = "message_admission_unpositioned", .table = "message_admission", .columns = &.{"session_ref"}, .where = "admission_position IS NULL" },
    .{ .name = "message_admission_position", .table = "message_admission", .columns = &.{ "session_ref", "admission_position" } },
    .{ .name = "core_command_target_order", .table = "core_command", .columns = &.{ "target", "kind", "command_seq" } },
    .{ .name = "session_revision_instructions", .table = "session_revision", .columns = &.{ "session_ref", "instructions_content_id" } },
    .{ .name = "session_revision_output_schema", .table = "session_revision", .columns = &.{ "session_ref", "output_schema_content_id" } },
    .{ .name = "session_stop_exclusion", .table = "session_stop", .columns = &.{ "session_ref", "admission_cutoff", "position" } },
    .{ .name = "session_stop_unpositioned", .table = "session_stop", .columns = &.{"session_ref"}, .where = "position IS NULL" },
    .{ .name = "session_stop_position", .table = "session_stop", .columns = &.{ "session_ref", "position" } },
    .{ .name = "session_stop_turn", .table = "session_stop", .columns = &.{"selected_turn_id"} },
    .{ .name = "session_parent", .table = "session", .columns = &.{"parent_ref"}, .where = "parent_ref IS NOT NULL" },
    .{ .name = "session_stop_open", .table = "session_stop_owed", .columns = &.{ "settled", "child_ref" } },
    .{ .name = "session_forward_message", .table = "session_forward", .columns = &.{ "message_delivered", "source_id" } },
    .{ .name = "session_forward_open", .table = "session_forward", .columns = &.{"forward_id"}, .where = "position IS NULL" },
    .{ .name = "session_forward_feed", .table = "session_forward", .columns = &.{ "target_ref", "position" } },
    .{ .name = "action_operation_session_order", .table = "action_operation", .columns = &.{ "session_ref", "action_id" } },
    .{ .name = "action_operation_sender_handle", .table = "action_operation", .columns = &.{"sender_handle"}, .unique = true, .where = "sender_handle IS NOT NULL" },
    .{ .name = "action_operation_acceptance", .table = "action_operation", .columns = &.{ "session_ref", "acceptance_position" } },
    .{ .name = "action_operation_session_results", .table = "action_operation", .columns = &.{ "session_ref", "parent_operation_id", "acceptance_position" }, .where = "acceptance_position IS NOT NULL AND background_position IS NULL" },
    .{ .name = "action_operation_approval", .table = "action_operation", .columns = &.{ "session_ref", "approval_position" }, .where = "approval_position IS NOT NULL" },
    .{ .name = "action_operation_unaccepted", .table = "action_operation", .columns = &.{"session_ref"}, .where = "acceptance_position IS NULL" },
    .{ .name = "action_operation_executable", .table = "action_operation", .columns = &.{"action_id"}, .where = "authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0" },
    .{ .name = "action_operation_unresolved_attempt", .table = "action_operation", .columns = &.{"action_id"}, .where = "resolution_code IS NULL AND attempt_ordinal=1" },
    .{ .name = "action_operation_indeterminate", .table = "action_operation", .columns = &.{ "session_ref", "parent_operation_id", "call_ordinal" }, .where = "resolution_code='indeterminate'" },
    .{ .name = "model_tool_call_session_order", .table = "model_tool_call", .columns = &.{ "session_ref", "operation_id", "call_ordinal" } },
    .{ .name = "model_tool_call_session_results", .table = "model_tool_call", .columns = &.{ "session_ref", "operation_id", "acceptance_position" }, .where = "acceptance_position IS NOT NULL" },
    .{ .name = "model_tool_call_acceptance", .table = "model_tool_call", .columns = &.{ "session_ref", "acceptance_position" }, .where = "acceptance_position IS NOT NULL" },
    .{ .name = "model_operation_retry_due", .table = "model_operation", .columns = &.{ "retry_due_at_ms", "operation_id" }, .where = "resolution_code IS NULL AND " ++ retry_allowance_open_sql },
    .{ .name = "model_operation_retry_exhausted", .table = "model_operation", .columns = &.{"operation_id"}, .where = retry_exhausted_sql },
    .{ .name = "model_operation_session_history", .table = "model_operation", .columns = &.{ "session_ref", "operation_id" } },
    .{ .name = "action_operation_background", .table = "action_operation", .columns = &.{ "session_ref", "background_position" } },
    .{ .name = "action_operation_background_results", .table = "action_operation", .columns = &.{ "session_ref", "parent_operation_id", "background_position" }, .where = "background_position IS NOT NULL" },
    .{ .name = "action_operation_background_ready", .table = "action_operation", .columns = &.{ "parent_operation_id", "action_id" }, .where = "background_position IS NOT NULL AND authorized=1 AND resolution_code IS NULL AND attempt_ordinal=0" },
    .{ .name = "action_operation_awaiting", .table = "action_operation", .columns = &.{ "session_ref", "action_id" }, .where = "authorized=0 AND resolution_code IS NULL" },
    .{ .name = "model_operation_turn_history", .table = "model_operation", .columns = &.{ "turn_id", "operation_id" } },
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
    .{ .name = "turn_outcome_unpositioned", .table = "turn", .columns = &.{"session_ref"}, .where = "outcome_position IS NULL" },
    .{ .name = "turn_outcome_position", .table = "turn", .columns = &.{ "session_ref", "outcome_position" } },
};
