//! Public conversation read requests and their bounds.
const Bounded = @import("bounded.zig").Bounded;
const store_path = @import("store_path.zig");
const session_id = @import("session_id.zig");

pub const content_window_bytes = 4096;
pub const public_conversation_page_items = 16;
pub const ConversationItemKind = enum { user, assistant, tool_result, hosted_call };

pub const ConversationPage = struct {
    store: Bounded(store_path.max_bytes) = .{},
    session: Bounded(session_id.max_reference_bytes) = .{},
    end: u64 = 0,
    before_position: u64 = 0,
    before_ordinal: u64 = 0,
};

pub const ConversationContent = struct {
    store: Bounded(store_path.max_bytes) = .{},
    session: Bounded(session_id.max_reference_bytes) = .{},
    position: u64 = 0,
    ordinal: u64 = 0,
    start: u64 = 0,
    stream: bool = false,
};
