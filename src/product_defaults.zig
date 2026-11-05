//! Product defaults: the values Rui supplies when a caller omits a setting.
//! Every surface that fills an omitted value reads this module: bare `rui`,
//! `host start`, `host serve`, `session configure` and `/setup`.
//! Explicit options, saved preferences and saved Session or running Host
//! settings take precedence; a default never rewrites
//! a saved value. Keep this module free of production imports so every owner
//! can use it.

/// Concurrent model/Bash executions of a Host started without
/// `--active-capacity`. A running Host keeps the capacity it started with.
pub const active_capacity: usize = 100;

/// Simultaneous ordinary client exchanges budgeted at Host startup. A finite
/// descriptor limit may reduce intake, never active capacity.
pub const intake_capacity: usize = 100;

/// How long a Host's shutdown may take: a launched Host is ended after this
/// once stdin closes, and rui host pause waits this long for retirement.
pub const host_shutdown_seconds = 10;

/// Tools for a fresh Session, in `--tools` syntax.
pub const tools = "bash,web_search";

/// Permission mode for a fresh Session.
pub const permission_mode = "bypass";

/// Provider for a fresh peer-created Session when no explicit or saved
/// provider applies. Bare `rui` asks instead when several are ready.
pub const provider = "codex";

/// Model for a fresh Session when no explicit or saved model applies. It needs
/// an OpenAI entry in the shipped catalog, checked by its tests.
pub const recommended_model = "gpt-6.1-sol";

/// Effort for a fresh spec unless its listed model excludes it; then its lowest listed effort.
pub const reasoning_effort = "low";

/// D111: CLI/TUI clients choose this share of a known model's context.
pub const compaction_trigger_percent: u64 = 90;

/// Provider-specific client defaults, capped by the usual share of the model
/// window. An unlisted provider uses that share alone. Names keep this a leaf.
pub const provider_compaction_triggers = [_]struct { provider: []const u8, tokens: u64 }{
    .{ .provider = "codex", .tokens = 244800 },
};

/// Client-side context estimate for a model the catalog does not list. Small on
/// purpose: compacting early costs a summary, compacting late costs a request
/// the provider refuses.
pub const unlisted_context_window: u64 = 128000;

/// Extra compaction headroom when a Session sets no output reservation.
pub const output_reservation: u64 = 0;

test "approved product defaults" {
    // Changing a default is a product decision; update this with its approval.
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 100), active_capacity);
    try std.testing.expectEqual(@as(usize, 100), intake_capacity);
    try std.testing.expectEqualStrings("bash,web_search", tools);
    try std.testing.expectEqualStrings("bypass", permission_mode);
    try std.testing.expectEqualStrings("codex", provider);
    try std.testing.expectEqualStrings("gpt-6.1-sol", recommended_model);
    try std.testing.expectEqualStrings("low", reasoning_effort);
    try std.testing.expectEqual(@as(u64, 90), compaction_trigger_percent);
    try std.testing.expectEqual(@as(usize, 1), provider_compaction_triggers.len);
    try std.testing.expectEqualStrings("codex", provider_compaction_triggers[0].provider);
    try std.testing.expectEqual(@as(u64, 244800), provider_compaction_triggers[0].tokens);
    try std.testing.expectEqual(@as(u64, 128000), unlisted_context_window);
    try std.testing.expectEqual(@as(u64, 0), output_reservation);
}
