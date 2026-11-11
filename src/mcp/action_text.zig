//! MCP adapter results when execution custody is lost or a stop wins.
pub const stopped_before_admission = @import("../action_text.zig").stopped_before_admission;
pub const stop_not_sent = "Cancelled by Session stop. Failed, not run: the MCP request was not sent.";
pub const stop_unknown = "Cancelled by Session stop. Outcome unknown: the MCP request was sent; it may still be running.";
pub const indeterminate = "Outcome unknown: the Host stopped while this MCP call was running; it was not retried.";

pub fn stopped(code: anytype, result: []const u8) []const u8 {
    return if (code == .cancelled) result else if (code == .spawn_failed) stop_not_sent else stop_unknown;
}
