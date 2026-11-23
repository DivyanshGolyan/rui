//! Store format steps (sketch). Appended to `migrations` in src/store/schema.zig, with the
//! live table definitions edited to match, bootstrap digests appended and
//! `tests/ci/schema_number.py --check` run. Numbers are relative to format 89 and are
//! renumbered at landing. MySQL steps are printed by `rui store schema --engine mysql`
//! and applied by the DB team; Drift runs only MySQL.
//!
//! Closed value sets are literals, so each new value below is a format change
//! (docs/contracts/store.md:82). Steps already on main are never edited (D226).

pub const Migration = struct { from: u32, sqlite: []const u8, mysql: []const u8 };

pub const steps = [_]Migration{
    // U5: reset. source_kind 6; entry kind 5 with head_position.
    .{
        .from = 89,
        .sqlite =
        \\-- message_admission: rebuild with source_kind CHECK IN (1,2,3,4,5,6,7)
        \\--   (6 reset: sender NULL, source_action_id NULL; content_id NULL allowed only for 6)
        \\-- conversation_entry: rebuild with entry_kind CHECK IN (1,2,3,4,5),
        \\--   ADD head_position INTEGER NULL, CHECK ((entry_kind=5) = (head_position IS NOT NULL)),
        \\--   CHECK (head_position IS NULL OR head_position <= session_position)
        \\-- index conversation_entry_head(session_ref, entry_kind, session_position) WHERE entry_kind=5
        ,
        .mysql =
        \\-- ALTER TABLE message_admission DROP CHECK ..., ADD CHECK (source_kind IN (1,2,3,4,5,6,7)) ...
        \\-- ALTER TABLE conversation_entry ADD COLUMN head_position BIGINT UNSIGNED NULL, ... CHECKs as SQLite
        ,
    },
    // U6: app tools. owner 'app' with policy columns; Session app set and lane; app_call.
    .{
        .from = 90,
        .sqlite =
        \\-- tool_record: rebuild with owner CHECK IN ('rui','provider','mcp','app','imported'),
        \\--   ADD app_replay INTEGER NULL, app_restart_limit INTEGER NULL, app_wait_ms INTEGER NULL,
        \\--   CHECK ((owner='app') = (app_wait_ms IS NOT NULL)), CHECK app_replay IN (0,1),
        \\--   CHECK app_restart_limit BETWEEN 1 AND 64; server-emptiness CHECK unchanged for 'app'
        \\-- session: ADD app_tool_set_id INTEGER NULL REFERENCES tool_set,
        \\--   ADD app_lane_ref NULL (self for a root that declares; the parent's lane for a child)
        \\-- configuration revision: ADD app_tool_set_id (so a re-declare is a revision)
        \\-- CREATE TABLE app_call(...) see store/domain/app_call.zig; indexes app_call_offered, app_call_due
        \\-- app_call.change_seq: assigned (SELECT coalesce(max(change_seq),0)+1 FROM app_call) under the
        \\--   single Store writer; indexed
        ,
        .mysql =
        \\-- same shape; ENUM-free (CHECKs), BIGINT UNSIGNED ids, utf8mb4_bin names
        ,
    },
    // U10: import. history_import; provenance columns; purpose 2; resolution 'imported'.
    .{
        .from = 91,
        .sqlite =
        \\-- CREATE TABLE history_import(...) see store/domain/history_import.zig
        \\-- turn: ADD import_id NULL REFERENCES history_import
        \\-- model_operation: purpose CHECK IN (0,1,2); provider-bag and timing CHECKs gain OR purpose=2;
        \\--   history_floor CHECK unchanged (floor only with purpose=1)
        \\-- model_output_item: provider bag nullable when its Operation has purpose=2
        \\-- action_operation: resolution_code gains 'imported'; CHECK imported => attempt_ordinal=0
        \\-- message_admission: source_kind 7 rows require a Turn with import_id
        \\-- conversation_entry: ADD import_ordinal NULL; index (session_ref, import_ordinal)
        \\-- session: ADD importing INTEGER NOT NULL DEFAULT 0
        ,
        .mysql =
        \\-- same shape
        ,
    },
};
