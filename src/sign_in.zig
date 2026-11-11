//! The sign-in row's transitions. Credentials and defaults remain the login
//! owners' facts; this value describes only an interaction in this terminal.
const std = @import("std");
pub const Provider = @import("provider_name.zig").Provider;
pub const Stage = enum { choice, codex_waiting, failed, key_entry, key_invalid, saving, done };
pub const Failure = enum { expired, denied, login, defaults, host };
pub const Event = union(enum) { left, right, enter, escape, key: bool, failed: Failure, done };
pub const Effect = enum { none, codex, key, cancel, close };
pub const State = struct {
    stage: Stage = .choice,
    selected: Provider = .codex,
    failure: Failure = .login,

    pub fn step(self: *State, event: Event) Effect {
        switch (event) {
            .escape => {
                const previous = self.stage;
                self.stage = .choice;
                return switch (previous) {
                    .choice, .done => .close,
                    .codex_waiting, .saving => .cancel,
                    else => .none,
                };
            },
            .left, .right => if (self.stage == .choice) {
                self.selected = if (event == .left) .codex else .openai;
            },
            .enter => switch (self.stage) {
                .choice, .failed => {
                    self.stage = if (self.selected == .codex) .codex_waiting else .key_entry;
                    return if (self.selected == .codex) .codex else .none;
                },
                else => {},
            },
            .key => |valid| if (self.stage == .key_entry or self.stage == .key_invalid) {
                self.stage = if (valid) .saving else .key_invalid;
                return if (valid) .key else .none;
            },
            .failed => |failure| {
                self.failure = failure;
                self.stage = .failed;
            },
            .done => self.stage = .done,
        }
        return .none;
    }
};

test "Sign-in domain covers choice waiting failure key invalid done and Escape from every state" {
    var state: State = .{};
    try std.testing.expectEqual(Effect.codex, state.step(.enter));
    try std.testing.expectEqual(Stage.codex_waiting, state.stage);
    _ = state.step(.{ .failed = .expired });
    try std.testing.expectEqual(Stage.failed, state.stage);
    try std.testing.expectEqual(Failure.expired, state.failure);
    try std.testing.expectEqual(Effect.codex, state.step(.enter));
    try std.testing.expectEqual(Effect.cancel, state.step(.escape));
    _ = state.step(.right);
    try std.testing.expectEqual(Provider.openai, state.selected);
    _ = state.step(.enter);
    try std.testing.expectEqual(Stage.key_entry, state.stage);
    try std.testing.expectEqual(Effect.none, state.step(.{ .key = false }));
    try std.testing.expectEqual(Stage.key_invalid, state.stage);
    try std.testing.expectEqual(Effect.key, state.step(.{ .key = true }));
    try std.testing.expectEqual(Stage.saving, state.stage);
    _ = state.step(.done);
    try std.testing.expectEqual(Stage.done, state.stage);
    for (std.enums.values(Stage)) |stage| {
        state.stage = stage;
        const effect = state.step(.escape);
        try std.testing.expectEqual(Stage.choice, state.stage);
        try std.testing.expectEqual(switch (stage) {
            .choice, .done => Effect.close,
            .codex_waiting, .saving => Effect.cancel,
            else => Effect.none,
        }, effect);
    }
    for (std.enums.values(Failure)) |failure| {
        _ = state.step(.{ .failed = failure });
        try std.testing.expectEqual(failure, state.failure);
        _ = state.step(.escape);
        try std.testing.expectEqual(Stage.choice, state.stage);
    }
}
