//! Guided sign-in decisions. Credentials, editors, processes and saved defaults
//! remain their existing owners' facts.
const std = @import("std");
pub const Provider = @import("provider_name.zig").Provider;
pub const Readinesses = @import("provider_selection.zig").Readinesses;
pub const Account = enum { chatgpt, api_key };
pub const Method = enum { browser, device };
pub const Field = enum { base, key, model };
pub const Control = enum { chatgpt, api_key, browser, device, reuse, base, key, model, connect, link, callback, copy_code, open_page, switch_method, back, retry, recheck, pause_command, start_command, close };
pub const Attempt = enum { chatgpt, codex, key, existing, recheck };
pub const Failure = enum {
    expired,
    denied,
    unreachable_service,
    answer,
    plan,
    host_id,
    login,
    defaults,
    host,
    defaults_and_host,
    settings,
    superseded,
    uncertain,
    pub fn saved(self: Failure) bool {
        return switch (self) {
            .defaults, .host, .defaults_and_host, .uncertain => true,
            else => false,
        };
    }
};
pub const Destination = enum { account, method, close };
pub const Page = union(enum) {
    account,
    method,
    api,
    browser,
    device,
    stopping: Destination,
    saving: Attempt,
    failed: struct { failure: Failure, retry: Attempt },
    pending,
    connected,
};
pub const Code = @import("bounded.zig").Bounded(64);
pub const Link = []const u8;
pub const Action = union(enum) {
    choose: Account,
    method: Method,
    reuse: Provider,
    field: Field,
    connect,
    callback,
    copy: Code,
    open: Link,
    command: []const u8,
    switch_method,
    back,
    retry,
    recheck,
    close,
};
pub const Input = union(enum) {
    activate: struct { attempt: u64, page: std.meta.Tag(Page), action: Action },
    move: bool,
    cancelled,
    failed: Failure,
    pending,
    connected,
    invalid: Field,
};
pub const Effect = union(enum) { none, start: Attempt, cancel, close, copy: Code, copy_text: []const u8, open: Link, callback };
pub const State = struct {
    page: Page = .account,
    /// Identifies the joined worker whose controls were drawn, not a wire id.
    attempt: u64 = 0,
    focus: Control = .chatgpt,

    pub fn controls(self: State) []const Control {
        return switch (self.page) {
            .account => &.{ .chatgpt, .api_key, .close },
            .method => &.{ .browser, .device, .reuse, .back },
            .api => &.{ .base, .key, .model, .connect, .back },
            .browser => &.{ .link, .callback, .open_page, .switch_method, .back },
            .device => &.{ .link, .copy_code, .open_page, .switch_method, .back },
            .stopping, .saving => &.{.back},
            .failed => &.{ .retry, .back },
            .pending => &.{ .pause_command, .start_command, .recheck, .back, .close },
            .connected => &.{.close},
        };
    }

    fn show(self: *State, page: Page, focus: Control) void {
        self.page = page;
        self.focus = focus;
    }

    fn start(self: *State, attempt: Attempt) Effect {
        self.attempt +%= 1;
        self.show(switch (attempt) {
            .chatgpt => .browser,
            .codex => .device,
            else => .{ .saving = attempt },
        }, switch (attempt) {
            .chatgpt => .callback,
            .codex => .copy_code,
            else => .back,
        });
        return .{ .start = attempt };
    }

    pub fn step(self: *State, input: Input) Effect {
        switch (input) {
            .move => |forward| {
                const controls_ = self.controls();
                const at = std.mem.indexOfScalar(Control, controls_, self.focus) orelse 0;
                self.focus = controls_[if (forward) (at + 1) % controls_.len else (at + controls_.len - 1) % controls_.len];
                return .none;
            },
            .cancelled => {
                if (self.page == .stopping) switch (self.page.stopping) {
                    .account => self.show(.account, .chatgpt),
                    .method => self.show(.method, .browser),
                    .close => {
                        self.show(.account, .chatgpt);
                        return .close;
                    },
                };
            },
            .failed => |failure| {
                if (self.page == .stopping and !failure.saved()) return self.step(.cancelled);
                const retry: Attempt = if (failure.saved()) .existing else if (failure == .superseded) .key else switch (self.page) {
                    .api => .key,
                    .browser => .chatgpt,
                    .device => .codex,
                    .saving => |attempt| attempt,
                    else => .existing,
                };
                self.show(.{ .failed = .{ .failure = failure, .retry = retry } }, .retry);
            },
            .pending => self.show(.pending, .recheck),
            .connected => self.show(.connected, .close),
            .invalid => |field| self.show(.api, switch (field) {
                .base => .base,
                .key => .key,
                .model => .model,
            }),
            .activate => |drawn| {
                if (drawn.attempt != self.attempt or drawn.page != std.meta.activeTag(self.page)) return .none;
                switch (drawn.action) {
                    .choose => |account| if (self.page == .account) {
                        self.show(if (account == .chatgpt) .method else .api, if (account == .chatgpt) .browser else .key);
                    },
                    .method => |method| if (self.page == .method) return self.start(if (method == .browser) .chatgpt else .codex),
                    .reuse => if (self.page == .method) return self.start(.existing),
                    .field => |field| if (self.page == .api) {
                        self.focus = switch (field) {
                            .base => .base,
                            .key => .key,
                            .model => .model,
                        };
                    },
                    .connect => if (self.page == .api) return self.start(.key),
                    .callback => if (self.page == .browser) return .callback,
                    .copy => |code| if (self.page == .device and code.len != 0) return .{ .copy = code },
                    .open => |link| if ((self.page == .device or self.page == .browser) and link.len != 0) return .{ .open = link },
                    .command => |text| if (self.page == .pending) return .{ .copy_text = text },
                    .switch_method => if (self.page == .browser or self.page == .device) {
                        self.show(.{ .stopping = .method }, .back);
                        return .cancel;
                    },
                    .retry => if (self.page == .failed) {
                        const attempt = self.page.failed.retry;
                        if (attempt == .key) self.show(.api, .key) else return self.start(attempt);
                    },
                    .recheck => if (self.page == .pending) return self.start(.recheck),
                    .back, .close => switch (self.page) {
                        .account, .connected => return .close,
                        .pending => if (drawn.action == .close) return .close else self.show(.account, .chatgpt),
                        .method, .api, .failed => self.show(.account, .chatgpt),
                        .browser, .device, .saving => {
                            const destination: Destination = if (drawn.action == .close) .close else if (self.page == .saving and (self.page.saving == .key or self.page.saving == .recheck)) .account else .method;
                            self.show(.{ .stopping = destination }, .back);
                            return .cancel;
                        },
                        .stopping => {},
                    },
                }
            },
        }
        return .none;
    }
};

fn act(state: *State, action: Action) Effect {
    return state.step(.{ .activate = .{ .attempt = state.attempt, .page = std.meta.activeTag(state.page), .action = action } });
}

test "Sign-in guided account method cancellation publication and stale actions" {
    var state: State = .{};
    try std.testing.expectEqual(Effect.none, act(&state, .{ .choose = .chatgpt }));
    try std.testing.expectEqual(@as(Attempt, .chatgpt), act(&state, .{ .method = .browser }).start);
    const attempt = state.attempt;
    try std.testing.expectEqual(Effect.cancel, act(&state, .switch_method));
    try std.testing.expectEqual(Effect.none, state.step(.{ .failed = .expired }));
    try std.testing.expect(state.page == .method);
    _ = act(&state, .{ .method = .device });
    var code: Code = .{};
    try code.set("OLD-CODE");
    try std.testing.expectEqual(Effect.none, state.step(.{ .activate = .{ .attempt = attempt, .page = .device, .action = .{ .copy = code } } }));
    try std.testing.expectEqualStrings("OLD-CODE", act(&state, .{ .copy = code }).copy.slice());
    _ = act(&state, .back);
    _ = state.step(.connected);
    try std.testing.expect(state.page == .connected);
}

test "Sign-in every page has reachable controls and stale input never starts work" {
    const pages_ = [_]Page{ .account, .method, .api, .browser, .device, .{ .stopping = .method }, .{ .saving = .key }, .{ .failed = .{ .failure = .login, .retry = .chatgpt } }, .pending, .connected };
    for (pages_) |page| {
        var state: State = .{ .page = page };
        state.focus = state.controls()[0];
        const first = state.focus;
        for (0..state.controls().len) |_| _ = state.step(.{ .move = true });
        try std.testing.expectEqual(first, state.focus);
        for (0..state.controls().len) |_| _ = state.step(.{ .move = false });
        try std.testing.expectEqual(first, state.focus);
        for ([_]Action{ .{ .choose = .api_key }, .{ .method = .device }, .connect, .recheck, .retry, .back, .close }) |action| {
            try std.testing.expectEqual(Effect.none, state.step(.{ .activate = .{ .attempt = 99, .page = std.meta.activeTag(page), .action = action } }));
            try std.testing.expectEqual(std.meta.activeTag(page), std.meta.activeTag(state.page));
        }
    }
}

test "Sign-in API setup and superseded connection retries reload the form instead of starting with stale authority" {
    var setup: State = .{ .page = .api, .focus = .key };
    _ = setup.step(.{ .failed = .settings });
    try std.testing.expect(setup.page == .failed and setup.page.failed.retry == .key);
    try std.testing.expectEqual(Effect.none, act(&setup, .retry));
    try std.testing.expect(setup.page == .api and setup.focus == .key);
    for ([_]Attempt{ .key, .recheck }) |attempt| {
        var state: State = .{ .page = .{ .saving = attempt } };
        _ = state.step(.{ .failed = .superseded });
        try std.testing.expect(state.page == .failed and state.page.failed.retry == .key);
        try std.testing.expectEqual(Effect.none, act(&state, .retry));
        try std.testing.expect(state.page == .api and state.focus == .key);
    }
}

test "Sign-in published failures retry existing credentials before either OAuth page" {
    for ([_]Page{ .browser, .device }) |page| for (std.enums.values(Failure)) |failure| {
        var state: State = .{ .page = page, .attempt = 1 };
        _ = state.step(.{ .failed = failure });
        const expected: Attempt = switch (failure) {
            .defaults, .host, .defaults_and_host, .uncertain => .existing,
            .superseded => .key,
            .expired, .denied, .unreachable_service, .answer, .plan, .host_id, .login, .settings => if (page == .browser) .chatgpt else .codex,
        };
        try std.testing.expect(state.page == .failed);
        try std.testing.expectEqual(expected, state.page.failed.retry);
        const retry = act(&state, .retry);
        if (expected == .key) {
            try std.testing.expectEqual(Effect.none, retry);
            try std.testing.expect(state.page == .api);
        } else try std.testing.expectEqual(expected, retry.start);
    };
}
