//! Bash adapter results when execution custody is lost or a stop wins.
pub const indeterminate = "Bash outcome is indeterminate after Host recovery; the command was not replayed.";
pub const stopped_before_admission = @import("action_text.zig").stopped_before_admission;
pub const stopped = stopped_before_admission;
