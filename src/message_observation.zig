//! Values retained for a Message command observation.
const Bounded = @import("bounded.zig").Bounded;
const tool_presentation = @import("tool_presentation.zig");

pub const MessageRequestState = enum { queued, processing, waiting_for_permission, completed, failed, cancelled, rejected };
pub const CommandObservationStatus = enum { absent, accepted, rejected };
pub const message_recovery_limit = 4;

pub const MessageUnknownOutcome = struct {
    action_id: u64,
    operation_id: u64,
    call: u64,
    description: ?Bounded(tool_presentation.max_description_bytes) = null,
    at: u64,
};
