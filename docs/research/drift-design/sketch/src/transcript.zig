//! The Transcript hub (sketch, U10). A versioned, foreign-neutral description of one
//! linear conversation that Rui did not run. Readers (spokes) produce it, one per foreign
//! format version; the importer (store/domain/history_import.zig) is its only consumer.
//!
//! Wire form: `transcript/1`, NDJSON items inside ImportAppend chunks. The parser below is
//! the boundary: past it, every item is a validated domain value. A new hub version adds
//! a parser arm that lowers into these same types, or a new type with its own importer
//! arm; old spokes keep producing v1.

const std = @import("std");

pub const Version = enum(u8) { v1 = 1 };

/// Who the history came from. `id` is stable per foreign conversation and keys the import,
/// so the lazy and eager paths converge on one Session.
pub const Source = struct {
    system: []const u8, // "pi-durable"
    system_version: []const u8, // "1.4.0"
    id: []const u8, // "<namespace>/<conversationId>", ≤ 256 bytes
};

pub const Part = union(enum) {
    text: []const u8,
    image: struct { media_type: []const u8, bytes_content_id: u64 },
};

pub const AssistantItem = union(enum) {
    text: []const u8,
    /// Opaque provider bag (for OpenAI Responses: the reasoning item). Kept only when the
    /// target Session's codec accepts `family`; otherwise dropped and counted.
    reasoning: struct { family: []const u8, bag: []const u8 },
    tool_call: struct { call_id: []const u8, name: []const u8, arguments_json: []const u8 },
};

pub const Item = union(enum) {
    user: []const Part,
    assistant: struct {
        family: []const u8, // provider family, e.g. "openai-responses"
        model: []const u8,
        items: []const AssistantItem,
        input_tokens: ?u64 = null,
        output_tokens: ?u64 = null,
    },
    tool_result: struct { call_id: []const u8, parts: []const Part, is_error: bool },
    /// A prompt change (pi.system). Becomes an instruction entry (kind 2).
    instructions: []const u8,
    /// pi.reset (head = own ordinal) or pi.compaction (head = ordinal of first kept item).
    /// By ordinal, never by foreign id, so the Host keeps no id map.
    head: struct { head_ordinal: u64, text: ?[]const u8 },
};

/// Boundary parser for one NDJSON line. Rejects unknown members, oversize values and
/// a head_ordinal greater than its own ordinal.
pub fn parseItem(version: Version, ordinal: u64, json: []const u8, scratch: anytype) error{InvalidTranscriptItem}!Item {
    _ = version;
    _ = ordinal;
    _ = json;
    _ = scratch;
    @panic("not implemented");
}

/// Pure: group a run of items into imported Turns. A Turn starts at each user item
/// (consecutive user items share one Turn) and holds the assistant, tool_result,
/// instructions and head items up to the next user item. Items before the first user
/// item join the first Turn. Outcome: `answered` when the last assistant item has no tool
/// call, else `incomplete`.
pub const TurnCut = struct {
    pub const Outcome = enum { answered, incomplete };
    pub fn next(items: []const Item) struct { len: usize, outcome: Outcome } {
        _ = items;
        @panic("not implemented");
    }
};
