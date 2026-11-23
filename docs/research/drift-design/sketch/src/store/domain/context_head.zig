//! Context head: reset, and imported pi-durable compaction summaries (sketch, U5).
//!
//! One concept, pi-durable's own: an entry that says where the model's context starts.
//! The model sees the head's text (if any) as the first user message, then every entry
//! with position >= head_position, up to the request frontier. History is never edited:
//! the head is one more immutable entry, kind 5.
//!
//! Reset:                 head_position = its own position, text = optional handoff.
//! Imported compaction:   head_position = the first kept entry, text = the summary.
//! Rui's own compaction is unchanged (provider-native bases) and composes with a head.

const std = @import("std");
const sourced_input = @import("sourced_input.zig");

// conversation_entry.entry_kind CHECK gains 5.
// Kind 5 columns: head_position NOT NULL (<= session_position), content_id NULL (text).
// Provenance: source_admission_id (a source_kind 6 admission) for a reset, or
// turn.import_id via its imported Turn for an imported head. CHECK exactly one.
pub const entry_kind: u8 = 5;

/// sourced_input.Source gains (shown here; the real change is in sourced_input.zig):
///   reset:    struct { key: []const u8, handoff_content_id: ?u64 }    -> source_kind 6
///   imported: struct { key: []const u8, import_id: u64, ordinal: u64 } -> source_kind 7
/// `queue` stays the single writer of message_admission. Keys for imported rows are
/// `rui.core/import/<import_id>/<ordinal>`; a reset uses the client's key.
pub const SourceAdditions = struct {};

/// Selection rule change in model_admission.runnable_selection (pure statement):
/// - A queued reset never makes a Session runnable by itself.
/// - When a Turn binds a prefix, every queued reset in that prefix is placed first,
///   in admission order, each projecting one kind-5 entry at a fresh position; then
///   the Messages are projected after them. So input queued behind a reset lands in
///   the new context, and outputs of the Turn that was running stay before it.
/// - A reset cannot join an already active Turn (`active Operation can take input`
///   excludes prefixes holding a reset); it waits for that Turn to end.
pub const Placement = struct {
    /// Pure: split a Session's eligible queue into what one AdmitModel binds.
    pub fn bind(queue: []const Queued, turn_active: bool) Bind {
        _ = queue;
        _ = turn_active;
        @panic("not implemented");
    }

    pub const Queued = struct { admission_id: u64, kind: sourced_input.SourceKind };
    pub const Bind = struct {
        /// Resets to place, in order, before `messages`.
        resets: []const u64,
        messages: []const u64,
        /// False when only resets are queued: nothing runs, nothing is bound.
        runnable: bool,
    };
};

/// Change to src/replay_recipe.zig: the context selection gains `head`.
/// `head` is the newest kind-5 entry's head_position at or before the frontier, or 0.
pub const Recipe = struct {
    head: u64 = 0,
    frontier: u64 = 0,
    floor: u64 = 0,
    /// The head entry whose text leads the request, if any.
    head_entry: ?u64 = null,

    /// A compaction base is selectable only when its anchor >= head.
    /// The first-Message pin becomes "the first Message with position >= head".
    /// The memo key includes head (docs/contracts/model-io.md:418 changes).
    pub fn select(model: []const u8, candidate: anytype, own_floor: u64, newest_head: ?Head) Recipe {
        _ = model;
        _ = candidate;
        _ = own_floor;
        _ = newest_head;
        @panic("not implemented");
    }

    pub const Head = struct { entry_position: u64, head_position: u64 };

    pub fn measuredBy(recipe: Recipe, measured: Recipe) bool {
        return recipe.head == measured.head and recipe.frontier == measured.frontier and recipe.floor == measured.floor;
    }
};

/// `POST /v1/reset {session, key, handoff?}` -> command.SubmitInput with Source.reset.
/// Same decide/admit path as a Message (fresh, conflict, rejected, accepted); one
/// Session position; no Turn. Feed rows: `admission` while queued, `reset` once placed.
pub const ResetRequest = struct {
    session: [6]u8,
    key: []const u8,
    handoff: ?[]const u8,
};
