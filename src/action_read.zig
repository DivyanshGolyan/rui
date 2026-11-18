const Bounded = @import("bounded.zig").Bounded;
const session_id = @import("session_id.zig");
const store_path = @import("store_path.zig");
const outcome_code = @import("outcome_code.zig");

pub const window_bytes = @import("conversation_read.zig").content_window_bytes;
pub const Request = struct {
    store: Bounded(store_path.max_bytes) = .{},
    session: Bounded(session_id.max_reference_bytes) = .{},
    action_id: u64 = 0,
    offset: u64 = 0,
};

pub const PendingState = enum { waiting_approval, queued, attempted };
pub const Resolution = struct {
    position: u64,
    code: Bounded(outcome_code.max_bytes),
    content: @import("content_value.zig").Value,
};
pub const Window = struct {
    offset: u64,
    next: u64,
    more: bool,
    text: Bounded(window_bytes),
};
pub const Final = struct { resolution: Resolution, window: Window };
pub const Read = struct {
    session: Bounded(session_id.max_reference_bytes),
    action_id: u64,
    status: union(enum) { pending: PendingState, resolved: Final, resolved_parts: Resolution },
};
