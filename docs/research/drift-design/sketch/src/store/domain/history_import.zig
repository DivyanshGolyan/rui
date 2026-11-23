//! History import: one importer from the Transcript hub into the current Store (sketch, U10).
//!
//! Contract (docs/contracts/admission.md:75 changes): history transfer happens only by a
//! sealed import into a fresh Session. Imported history is the Session's own history,
//! built from the same records a run Turn has, with provenance at the root:
//!
//!   turn.import_id            NOT NULL for imported Turns, FK history_import
//!   message_admission         source_kind 7 `imported`, key rui.core/import/<id>/<ordinal>
//!   model_operation.purpose   2 `imported`: resolved, no provider Attempt, nullable provider
//!                             bag, frozen offer of owner=`imported` records
//!   model_tool_call           as today, against that frozen offer
//!   action_operation          resolved at once, resolution_code `imported`, attempt_ordinal 0
//!   conversation_entry        kinds 1, 2, 3, 5 as today (kind 5 = context_head)
//!
//! Because every reader (history replay, feed, read_transcript, search, reports) walks
//! Turn -> Operation -> output -> call -> Action -> Resolution, none of them learns about
//! imports. Only CHECKs that demand executed facts gain an `OR purpose = 2` arm.

const std = @import("std");
const transcript = @import("../../transcript.zig");

// history_import(
//   import_id INTEGER PRIMARY KEY,
//   session_ref NOT NULL UNIQUE,      -- the fresh Session it fills
//   source_system, source_version, source_id  -- UNIQUE(source_system, source_id)
//   transcript_version INTEGER NOT NULL,
//   next_ordinal INTEGER NOT NULL,    -- items landed so far; ImportAppend's guard
//   dropped_reasoning INTEGER NOT NULL DEFAULT 0,
//   items_digest BLOB NOT NULL,       -- running SHA-256 over landed item bytes
//   sealed_at INTEGER NULL
// )
// conversation_entry gains import_ordinal NULL (head resolution by ordinal; indexed with session).
// session: an unsealed import makes the Session refuse every input with `session_importing`.

pub const Begin = struct {
    /// Creates the Session from `spec` (the ordinary configure validation) and the import
    /// row, in one transaction. Keyed by `source`; a repeat returns the same Session and
    /// its `next_ordinal`, so a crashed import resumes.
    pub const Answer = union(enum) {
        started: struct { session: [6]u8, import_id: u64, next_ordinal: u64 },
        already_sealed: struct { session: [6]u8 },
    };
    pub fn run(a: anytype, source: transcript.Source, version: transcript.Version, spec: anytype) !Answer {
        _ = a;
        _ = source;
        _ = version;
        _ = spec;
        @panic("not implemented");
    }
};

/// One chunk (≤ 8 MiB, ≤ 4,096 items), one transaction, one round budget.
/// Guard: chunk.first_ordinal == next_ordinal, else `skipped` (already landed) or
/// `gap` (refused). Each item is lowered by `lower` and written in order at fresh positions.
/// Each assistant item is encoded by the Session provider's pinned codec and decoded back
/// before it is written; a mismatch refuses the chunk naming the ordinal.
pub const Append = struct {
    pub const Answer = union(enum) {
        landed: struct { next_ordinal: u64 },
        skipped: struct { next_ordinal: u64 },
        gap: struct { next_ordinal: u64 },
        refused: struct { ordinal: u64, reason: Refusal },
    };
    pub const Refusal = enum { codec_round_trip, unknown_call_id, head_out_of_range, too_large };

    pub fn run(a: anytype, import_id: u64, first_ordinal: u64, items: []const transcript.Item) !Answer {
        _ = a;
        _ = import_id;
        _ = first_ordinal;
        _ = items;
        @panic("not implemented");
    }
};

/// Pure: what rows one item becomes, given the open imported Turn (if any).
pub const Lowered = union(enum) {
    open_turn: struct { admission_ordinal: u64 },
    user_message,
    operation: struct { dropped_reasoning: u32 },
    tool_result: struct { call_id: []const u8 },
    instruction,
    head: struct { head_ordinal: u64 },
};
pub fn lower(item: transcript.Item, open_turn: bool, accepts_family: bool) Lowered {
    _ = item;
    _ = open_turn;
    _ = accepts_family;
    @panic("not implemented");
}

/// Closes the last imported Turn, writes `sealed_at`, and opens the Session to input.
/// Guard: not sealed. After this the Session runs like any other; its next Turn's request
/// replays the imported history through the ordinary recipe (heads included).
pub const Seal = struct {
    pub fn run(a: anytype, import_id: u64, expected_items: u64, digest: [32]u8) !void {
        _ = a;
        _ = import_id;
        _ = expected_items;
        _ = digest;
        @panic("not implemented");
    }
};
