//! The sign-in row's transitions. Credentials and defaults remain the login
//! owners' facts; this value describes only an interaction in this terminal.
const std = @import("std");
pub const Provider = @import("provider_name.zig").Provider;
pub const Readinesses = @import("provider_selection.zig").Readinesses;
pub const Attempt = enum { codex, key, existing };
pub const Stage = enum { choice, codex_waiting, failed, key_entry, key_invalid, saving, done };
pub const Failure = enum { expired, denied, login, defaults, host, defaults_and_host };
pub const Event = union(enum) { left, right, enter: Readinesses, escape, key: bool, failed: Failure, done };
pub const Effect = enum { none, codex, key, existing, cancel, close };
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
            .enter => |readiness| switch (self.stage) {
                .choice, .failed => {
                    if (readiness.get(self.selected).usable()) {
                        self.stage = .saving;
                        return .existing;
                    }
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
    try std.testing.expectEqual(Effect.codex, state.step(.{ .enter = .initFill(.missing) }));
    try std.testing.expectEqual(Stage.codex_waiting, state.stage);
    _ = state.step(.{ .failed = .expired });
    try std.testing.expectEqual(Stage.failed, state.stage);
    try std.testing.expectEqual(Failure.expired, state.failure);
    try std.testing.expectEqual(Effect.codex, state.step(.{ .enter = .initFill(.missing) }));
    try std.testing.expectEqual(Effect.cancel, state.step(.escape));
    _ = state.step(.right);
    try std.testing.expectEqual(Provider.openai, state.selected);
    _ = state.step(.{ .enter = .initFill(.missing) });
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

test "Sign-in choice reuses either ready provider including both ready without a default" {
    for ([_]bool{ false, true }) |codex_ready| {
        for ([_]bool{ false, true }) |openai_ready| {
            var readiness: Readinesses = .initFill(.missing);
            if (codex_ready) readiness.set(.codex, .configured);
            if (openai_ready) readiness.set(.openai, .configured);
            // The defaultless chooser is also used when both are ready:
            // either explicit choice saves its default, never its credential.
            for ([_]Provider{ .codex, .openai }) |provider| {
                for ([_]Stage{ .choice, .failed }) |stage| {
                    var state: State = .{ .selected = provider, .stage = stage };
                    const ready = if (provider == .codex) codex_ready else openai_ready;
                    const effect = state.step(.{ .enter = readiness });
                    try std.testing.expectEqual(if (ready) Effect.existing else if (provider == .codex) Effect.codex else Effect.none, effect);
                    try std.testing.expectEqual(if (ready) Stage.saving else if (provider == .codex) Stage.codex_waiting else Stage.key_entry, state.stage);
                }
            }
        }
    }
}
