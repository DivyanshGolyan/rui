//! The sign-in row's transitions. Credentials and defaults remain the login
//! owners' facts; this value describes only an interaction in this terminal.
//!
//! The row offers ChatGPT and an API key. ChatGPT signs in through the
//! browser (`chatgpt`) unless a sign-in to it is already usable, and Tab
//! while the browser waits, or after it failed, uses a device code instead
//! (`codex`). Divyansh chose this on 2026-11-13.
const std = @import("std");
pub const Provider = @import("provider_name.zig").Provider;
pub const Readinesses = @import("provider_selection.zig").Readinesses;
pub const Attempt = enum { chatgpt, codex, key, existing };
/// `switching` is a browser sign-in cancelled for a device code: the device
/// login begins once that attempt has settled.
pub const Stage = enum { choice, browser_waiting, switching, codex_waiting, failed, key_entry, key_invalid, saving, done };
pub const Failure = enum {
    expired,
    denied,
    /// ChatGPT's sign-in service could not be reached.
    unreachable_service,
    /// The answer that arrived was not this sign-in's.
    answer,
    /// The person signed in but did not let Rui use their plan.
    plan,
    /// The host id file holds no host id Rui wrote.
    host_id,
    login,
    defaults,
    host,
    defaults_and_host,

    /// Whether the sign-in was saved before this failure.
    pub fn saved(self: Failure) bool {
        return switch (self) {
            .defaults, .host, .defaults_and_host => true,
            else => false,
        };
    }
};
/// `device_code` is Tab. `cancelled` is a cancelled attempt that settled.
pub const Event = union(enum) { left, right, enter: Readinesses, escape, device_code, key: bool, failed: Failure, cancelled, done };
pub const Effect = enum { none, chatgpt, codex, key, existing, cancel, close };
pub const State = struct {
    stage: Stage = .choice,
    /// `codex` only once the device code is chosen or reused; the choice
    /// row shows it as ChatGPT.
    selected: Provider = .chatgpt,
    failure: Failure = .login,

    pub fn step(self: *State, event: Event) Effect {
        switch (event) {
            .escape => {
                const previous = self.stage;
                self.stage = .choice;
                // The choice row's ChatGPT begins in the browser again.
                if (self.selected == .codex) self.selected = .chatgpt;
                return switch (previous) {
                    .choice, .done => .close,
                    .browser_waiting, .switching, .codex_waiting, .saving => .cancel,
                    else => .none,
                };
            },
            .left, .right => if (self.stage == .choice) {
                self.selected = if (event == .left) .chatgpt else .openai;
            },
            .enter => |readiness| switch (self.stage) {
                .choice, .failed => {
                    // A usable browser sign-in first, else a usable device
                    // code, before signing in again.
                    if (self.selected == .chatgpt and !readiness.get(.chatgpt).usable() and readiness.get(.codex).usable()) self.selected = .codex;
                    if (readiness.get(self.selected).usable()) {
                        self.stage = .saving;
                        return .existing;
                    }
                    switch (self.selected) {
                        .chatgpt => {
                            self.stage = .browser_waiting;
                            return .chatgpt;
                        },
                        .codex => {
                            self.stage = .codex_waiting;
                            return .codex;
                        },
                        .openai => self.stage = .key_entry,
                    }
                },
                else => {},
            },
            .device_code => if (self.offersDeviceCode()) {
                self.selected = .codex;
                if (self.stage == .browser_waiting) {
                    self.stage = .switching;
                    return .cancel;
                }
                self.stage = .codex_waiting;
                return .codex;
            },
            .key => |valid| if (self.stage == .key_entry or self.stage == .key_invalid) {
                self.stage = if (valid) .saving else .key_invalid;
                return if (valid) .key else .none;
            },
            .failed => |failure| {
                // The browser attempt Tab cancelled ended its own way; the
                // device code it was cancelled for still begins.
                if (self.stage == .switching and !failure.saved()) {
                    self.stage = .codex_waiting;
                    return .codex;
                }
                self.failure = failure;
                self.stage = .failed;
            },
            .cancelled => if (self.stage == .switching) {
                self.stage = .codex_waiting;
                return .codex;
            },
            .done => self.stage = .done,
        }
        return .none;
    }

    /// Whether Tab uses a device code instead: while the browser waits, or
    /// after a browser sign-in ended with nothing saved.
    pub fn offersDeviceCode(self: State) bool {
        return switch (self.stage) {
            .browser_waiting => true,
            .failed => self.selected == .chatgpt and !self.failure.saved(),
            else => false,
        };
    }
};

test "Sign-in transitions over every stage and event, written out by hand" {
    const none: Readinesses = .initFill(.missing);
    var browser: Readinesses = .initFill(.missing);
    browser.set(.chatgpt, .configured);
    var device: Readinesses = .initFill(.missing);
    device.set(.codex, .renewal_due);
    var both: Readinesses = .initFill(.missing);
    both.set(.chatgpt, .configured);
    both.set(.codex, .configured);
    var key: Readinesses = .initFill(.missing);
    key.set(.openai, .configured);
    const Row = struct { Stage, Provider, Event, Stage, Provider, Effect };
    // Each stage with the selection it holds there, under every event;
    // `failed` holds the sign-in failure `.login` unless the event says.
    const rows = [_]Row{
        // choice, ChatGPT selected
        .{ .choice, .chatgpt, .left, .choice, .chatgpt, .none },
        .{ .choice, .chatgpt, .right, .choice, .openai, .none },
        .{ .choice, .chatgpt, .{ .enter = none }, .browser_waiting, .chatgpt, .chatgpt },
        .{ .choice, .chatgpt, .{ .enter = browser }, .saving, .chatgpt, .existing },
        .{ .choice, .chatgpt, .{ .enter = device }, .saving, .codex, .existing },
        .{ .choice, .chatgpt, .{ .enter = both }, .saving, .chatgpt, .existing },
        .{ .choice, .chatgpt, .{ .enter = key }, .browser_waiting, .chatgpt, .chatgpt },
        .{ .choice, .chatgpt, .escape, .choice, .chatgpt, .close },
        .{ .choice, .chatgpt, .device_code, .choice, .chatgpt, .none },
        .{ .choice, .chatgpt, .{ .key = true }, .choice, .chatgpt, .none },
        .{ .choice, .chatgpt, .{ .key = false }, .choice, .chatgpt, .none },
        .{ .choice, .chatgpt, .{ .failed = .expired }, .failed, .chatgpt, .none },
        .{ .choice, .chatgpt, .cancelled, .choice, .chatgpt, .none },
        .{ .choice, .chatgpt, .done, .done, .chatgpt, .none },
        // choice, API key selected
        .{ .choice, .openai, .left, .choice, .chatgpt, .none },
        .{ .choice, .openai, .right, .choice, .openai, .none },
        .{ .choice, .openai, .{ .enter = none }, .key_entry, .openai, .none },
        .{ .choice, .openai, .{ .enter = both }, .key_entry, .openai, .none },
        .{ .choice, .openai, .{ .enter = key }, .saving, .openai, .existing },
        .{ .choice, .openai, .device_code, .choice, .openai, .none },
        // browser_waiting
        .{ .browser_waiting, .chatgpt, .left, .browser_waiting, .chatgpt, .none },
        .{ .browser_waiting, .chatgpt, .right, .browser_waiting, .chatgpt, .none },
        .{ .browser_waiting, .chatgpt, .{ .enter = none }, .browser_waiting, .chatgpt, .none },
        .{ .browser_waiting, .chatgpt, .{ .enter = device }, .browser_waiting, .chatgpt, .none },
        .{ .browser_waiting, .chatgpt, .escape, .choice, .chatgpt, .cancel },
        .{ .browser_waiting, .chatgpt, .device_code, .switching, .codex, .cancel },
        .{ .browser_waiting, .chatgpt, .{ .key = true }, .browser_waiting, .chatgpt, .none },
        .{ .browser_waiting, .chatgpt, .{ .failed = .answer }, .failed, .chatgpt, .none },
        .{ .browser_waiting, .chatgpt, .cancelled, .browser_waiting, .chatgpt, .none },
        .{ .browser_waiting, .chatgpt, .done, .done, .chatgpt, .none },
        // switching: the cancelled browser attempt has not settled yet
        .{ .switching, .codex, .left, .switching, .codex, .none },
        .{ .switching, .codex, .right, .switching, .codex, .none },
        .{ .switching, .codex, .{ .enter = none }, .switching, .codex, .none },
        .{ .switching, .codex, .escape, .choice, .chatgpt, .cancel },
        .{ .switching, .codex, .device_code, .switching, .codex, .none },
        .{ .switching, .codex, .{ .key = true }, .switching, .codex, .none },
        .{ .switching, .codex, .{ .failed = .unreachable_service }, .codex_waiting, .codex, .codex },
        .{ .switching, .codex, .{ .failed = .expired }, .codex_waiting, .codex, .codex },
        .{ .switching, .codex, .{ .failed = .host }, .failed, .codex, .none },
        .{ .switching, .codex, .cancelled, .codex_waiting, .codex, .codex },
        .{ .switching, .codex, .done, .done, .codex, .none },
        // codex_waiting
        .{ .codex_waiting, .codex, .left, .codex_waiting, .codex, .none },
        .{ .codex_waiting, .codex, .right, .codex_waiting, .codex, .none },
        .{ .codex_waiting, .codex, .{ .enter = none }, .codex_waiting, .codex, .none },
        .{ .codex_waiting, .codex, .escape, .choice, .chatgpt, .cancel },
        .{ .codex_waiting, .codex, .device_code, .codex_waiting, .codex, .none },
        .{ .codex_waiting, .codex, .{ .key = false }, .codex_waiting, .codex, .none },
        .{ .codex_waiting, .codex, .{ .failed = .denied }, .failed, .codex, .none },
        .{ .codex_waiting, .codex, .cancelled, .codex_waiting, .codex, .none },
        .{ .codex_waiting, .codex, .done, .done, .codex, .none },
        // failed after the browser
        .{ .failed, .chatgpt, .left, .failed, .chatgpt, .none },
        .{ .failed, .chatgpt, .right, .failed, .chatgpt, .none },
        .{ .failed, .chatgpt, .{ .enter = none }, .browser_waiting, .chatgpt, .chatgpt },
        .{ .failed, .chatgpt, .{ .enter = browser }, .saving, .chatgpt, .existing },
        .{ .failed, .chatgpt, .{ .enter = device }, .saving, .codex, .existing },
        .{ .failed, .chatgpt, .escape, .choice, .chatgpt, .none },
        .{ .failed, .chatgpt, .device_code, .codex_waiting, .codex, .codex },
        .{ .failed, .chatgpt, .{ .key = true }, .failed, .chatgpt, .none },
        .{ .failed, .chatgpt, .{ .failed = .plan }, .failed, .chatgpt, .none },
        .{ .failed, .chatgpt, .cancelled, .failed, .chatgpt, .none },
        .{ .failed, .chatgpt, .done, .done, .chatgpt, .none },
        // failed after the device code, and after a saved sign-in
        .{ .failed, .codex, .{ .enter = none }, .codex_waiting, .codex, .codex },
        .{ .failed, .codex, .{ .enter = device }, .saving, .codex, .existing },
        .{ .failed, .codex, .device_code, .failed, .codex, .none },
        .{ .failed, .codex, .escape, .choice, .chatgpt, .none },
        .{ .failed, .openai, .{ .enter = none }, .key_entry, .openai, .none },
        .{ .failed, .openai, .device_code, .failed, .openai, .none },
        // key_entry and key_invalid
        .{ .key_entry, .openai, .left, .key_entry, .openai, .none },
        .{ .key_entry, .openai, .right, .key_entry, .openai, .none },
        .{ .key_entry, .openai, .{ .enter = key }, .key_entry, .openai, .none },
        .{ .key_entry, .openai, .escape, .choice, .openai, .none },
        .{ .key_entry, .openai, .device_code, .key_entry, .openai, .none },
        .{ .key_entry, .openai, .{ .key = true }, .saving, .openai, .key },
        .{ .key_entry, .openai, .{ .key = false }, .key_invalid, .openai, .none },
        .{ .key_entry, .openai, .{ .failed = .login }, .failed, .openai, .none },
        .{ .key_entry, .openai, .cancelled, .key_entry, .openai, .none },
        .{ .key_entry, .openai, .done, .done, .openai, .none },
        .{ .key_invalid, .openai, .left, .key_invalid, .openai, .none },
        .{ .key_invalid, .openai, .{ .enter = none }, .key_invalid, .openai, .none },
        .{ .key_invalid, .openai, .escape, .choice, .openai, .none },
        .{ .key_invalid, .openai, .device_code, .key_invalid, .openai, .none },
        .{ .key_invalid, .openai, .{ .key = true }, .saving, .openai, .key },
        .{ .key_invalid, .openai, .{ .key = false }, .key_invalid, .openai, .none },
        .{ .key_invalid, .openai, .cancelled, .key_invalid, .openai, .none },
        // saving
        .{ .saving, .chatgpt, .left, .saving, .chatgpt, .none },
        .{ .saving, .chatgpt, .{ .enter = none }, .saving, .chatgpt, .none },
        .{ .saving, .chatgpt, .escape, .choice, .chatgpt, .cancel },
        .{ .saving, .codex, .escape, .choice, .chatgpt, .cancel },
        .{ .saving, .chatgpt, .device_code, .saving, .chatgpt, .none },
        .{ .saving, .openai, .{ .key = true }, .saving, .openai, .none },
        .{ .saving, .chatgpt, .{ .failed = .host }, .failed, .chatgpt, .none },
        .{ .saving, .chatgpt, .cancelled, .saving, .chatgpt, .none },
        .{ .saving, .chatgpt, .done, .done, .chatgpt, .none },
        // done
        .{ .done, .chatgpt, .left, .done, .chatgpt, .none },
        .{ .done, .chatgpt, .{ .enter = none }, .done, .chatgpt, .none },
        .{ .done, .chatgpt, .escape, .choice, .chatgpt, .close },
        .{ .done, .chatgpt, .device_code, .done, .chatgpt, .none },
        .{ .done, .chatgpt, .{ .key = true }, .done, .chatgpt, .none },
        .{ .done, .chatgpt, .{ .failed = .login }, .failed, .chatgpt, .none },
        .{ .done, .chatgpt, .cancelled, .done, .chatgpt, .none },
        .{ .done, .chatgpt, .done, .done, .chatgpt, .none },
    };
    // Every stage and every event appears at least once above.
    var stages: std.EnumSet(Stage) = .empty;
    var events: std.EnumSet(std.meta.Tag(Event)) = .empty;
    for (rows) |row| {
        var state: State = .{ .stage = row[0], .selected = row[1] };
        // A saved-sign-in failure offers no device code.
        if (row[0] == .failed and row[1] == .codex) state.failure = .expired;
        const effect = state.step(row[2]);
        errdefer std.debug.print("from {t} with {t} on {t}: got {t} with {t}, {t}\n", .{ row[0], row[1], row[2], state.stage, state.selected, effect });
        try std.testing.expectEqual(row[3], state.stage);
        try std.testing.expectEqual(row[4], state.selected);
        try std.testing.expectEqual(row[5], effect);
        stages.insert(row[0]);
        events.insert(row[2]);
    }
    try std.testing.expectEqual(std.enums.values(Stage).len, stages.count());
    try std.testing.expectEqual(std.enums.values(std.meta.Tag(Event)).len, events.count());
}

test "Sign-in failure records its kind, a saved one offers no device code, and Escape returns from each" {
    for (std.enums.values(Failure)) |failure| {
        var state: State = .{ .stage = .browser_waiting };
        _ = state.step(.{ .failed = failure });
        try std.testing.expectEqual(Stage.failed, state.stage);
        try std.testing.expectEqual(failure, state.failure);
        try std.testing.expectEqual(!failure.saved(), state.offersDeviceCode());
        const tab = state.step(.device_code);
        try std.testing.expectEqual(if (failure.saved()) Effect.none else Effect.codex, tab);
        _ = state.step(.escape);
        try std.testing.expectEqual(Stage.choice, state.stage);
        try std.testing.expectEqual(Provider.chatgpt, state.selected);
    }
    // Only these three follow a saved sign-in.
    for (std.enums.values(Failure)) |failure| try std.testing.expectEqual(failure == .defaults or failure == .host or failure == .defaults_and_host, failure.saved());
}

test "Sign-in choice reuses a ready sign-in for the selected choice, ChatGPT's browser before its device code" {
    for (std.enums.values(@import("provider_selection.zig").Readiness)) |chatgpt| for (std.enums.values(@import("provider_selection.zig").Readiness)) |codex| for ([_]bool{ false, true }) |openai_ready| {
        var readiness: Readinesses = .initFill(.missing);
        readiness.set(.chatgpt, chatgpt);
        readiness.set(.codex, codex);
        if (openai_ready) readiness.set(.openai, .configured);
        const chatgpt_ready = chatgpt == .configured or chatgpt == .renewal_due;
        const codex_ready = codex == .configured or codex == .renewal_due;
        for ([_]Stage{ .choice, .failed }) |stage| {
            // ChatGPT: browser sign-in if usable, else device code if usable, else the browser.
            var state: State = .{ .selected = .chatgpt, .stage = stage };
            const effect = state.step(.{ .enter = readiness });
            try std.testing.expectEqual(if (chatgpt_ready or codex_ready) Effect.existing else Effect.chatgpt, effect);
            try std.testing.expectEqual(if (chatgpt_ready or codex_ready) Stage.saving else Stage.browser_waiting, state.stage);
            try std.testing.expectEqual(if (!chatgpt_ready and codex_ready) Provider.codex else Provider.chatgpt, state.selected);
            // API key: its own readiness only, whatever ChatGPT's.
            var key: State = .{ .selected = .openai, .stage = stage };
            try std.testing.expectEqual(if (openai_ready) Effect.existing else Effect.none, key.step(.{ .enter = readiness }));
            try std.testing.expectEqual(if (openai_ready) Stage.saving else Stage.key_entry, key.stage);
        }
    };
}
