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
    after: u64 = 0,
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
pub const page_items = 16;
pub const page_bytes = @import("action_value_limits.zig").max_value_bytes;
pub const Value = struct { ordinal: u64, key: Bounded(128), start: usize, length: usize };
pub const Values = struct {
    items: [page_items]Value = undefined,
    count: usize = 0,
    bytes: [page_bytes]u8 = undefined,
    length: usize = 0,
    next: u64 = 0,
    more: bool = false,
};
pub const Read = struct {
    values: Values = .{},
    session: Bounded(session_id.max_reference_bytes),
    action_id: u64,
    status: union(enum) { pending: PendingState, resolved: Final, resolved_parts: Resolution },
};
