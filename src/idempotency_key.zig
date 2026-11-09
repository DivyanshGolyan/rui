//! A core idempotency key: the caller's value that binds one state-changing
//! command to its original committed answer.

pub const max_bytes = 128;

/// Command keys Rui gives its own commands: a core tool call's Message or
/// agent start, and the stop an attached child owes. A client command
/// with one is refused.
pub const reserved_prefix = "rui.core/";
