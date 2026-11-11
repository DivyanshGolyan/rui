//! MCP adapter results when execution custody is lost or a stop wins.
pub const stopped_before_admission = @import("../action_text.zig").stopped_before_admission;
pub const stop_not_sent = "Cancelled by Session stop. Failed, not run: the MCP request was not sent.";
pub const stop_unknown = "Outcome unknown: Session stop closed the connection after the MCP request was sent. The call may or may not have run; it was not retried.";
pub const indeterminate = "Outcome unknown: the Host stopped while this MCP call was running; it was not retried.";
