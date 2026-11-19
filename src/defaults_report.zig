const std = @import("std");
const protocol = @import("protocol.zig");
const preference_document = @import("preference_document.zig");
const provider_selection = @import("provider_selection.zig");
const model_capability = @import("model_capability.zig");
const TerminalText = @import("TerminalText.zig");

pub const Host = union(enum) {
    store_unavailable,
    ready: @FieldType(protocol.HostInfo, "capabilities"),
    unavailable,
    owned_unavailable,
    incompatible,
    access_failure,
};

pub const Account = struct {
    email: []const u8 = "",
    expiry: ?struct { year: u16, month: u8, day: u8, hour: u8, minute: u8 } = null,
};

pub const Reader = enum { command_line, conversation, overview };

/// The provider table's display names and sign-in commands, read by the shell.
/// An empty login means the provider has no sign-in command in this terminal.
/// This is the only source of provider names and commands in the report.
pub const Names = struct {
    /// Indexed by provider, in the enum's order.
    shown: [provider_count][]const u8,
    login: [provider_count][]const u8,
    /// Every provider's wire name, joined with `|`.
    choices: []const u8,

    pub fn shownFor(self: *const Names, provider: protocol.Provider) []const u8 {
        return self.shown[@backingInt(provider)];
    }

    pub fn loginFor(self: *const Names, provider: protocol.Provider) []const u8 {
        return self.login[@backingInt(provider)];
    }
};

const provider_count = @typeInfo(protocol.Provider).@"enum".field_names.len;

/// Saved-default values the shell reads from product defaults.
pub const Defaults = struct {
    permission_mode: []const u8,
    recommended_model: []const u8,
};

/// Where the Store's Host reads the OpenAI API key from, when a source was found.
pub const KeySource = union(enum) { file: []const u8, env: []const u8 };

/// The Store's Host inspect result for the OpenAI key, as the shell copies it.
pub const Inspected = struct {
    readiness: provider_selection.Readiness,
    unauthenticated: bool = false,
    key_source: ?KeySource = null,
};

/// The OpenAI readiness and key source one Store reads, with the local readiness for every other provider.
pub const Overlay = struct {
    readiness: provider_selection.Readinesses,
    key_source: ?KeySource = null,
};

/// The one rule for the OpenAI key as a Store's Host reads it: the inspect result overrides the local
/// OpenAI readiness only when it names a key source and is not unauthenticated. Otherwise the local
/// readiness stands and no source is reported.
pub fn overlayStore(local: provider_selection.Readinesses, inspected: ?Inspected) Overlay {
    var overlay: Overlay = .{ .readiness = local };
    const info = inspected orelse return overlay;
    const source = info.key_source orelse return overlay;
    if (info.unauthenticated) return overlay;
    overlay.readiness.set(.openai, info.readiness);
    overlay.key_source = source;
    return overlay;
}

pub const Facts = struct {
    changed: bool,
    values: preference_document.Values,
    store: ?[]const u8,
    saved_store: bool,
    store_available: bool,
    readiness: *const provider_selection.Readinesses,
    host: Host,
    account: ?Account = null,
    openai_key: ?KeySource = null,
    reader: Reader = .command_line,
    names: Names,
    defaults: Defaults,
};

/// The command-line form is JSON; every other reader gets text.
pub fn wantsJson(facts: *const Facts) bool {
    return facts.reader == .command_line;
}

pub const NextSession = union(enum) {
    chooser,
    selected: @FieldType(provider_selection.Selection, "selected"),
    unsupported_provider,
    unsupported_model,
};

pub fn nextSession(facts: *const Facts) NextSession {
    const values = &facts.values;
    const provider: ?[]const u8 = if (values.provider.len != 0) values.provider.slice() else null;
    const model: ?[]const u8 = if (values.model.len != 0) values.model.slice() else null;
    const selection = provider_selection.resolve(&model_capability.capabilities(facts.readiness), null, null, provider, model) catch |err| return switch (err) {
        error.UnsupportedSelectionProvider => .unsupported_provider,
        error.UnsupportedSelectionModel => .unsupported_model,
    };
    return switch (selection) {
        .chooser => .chooser,
        .selected => |selected| .{ .selected = selected },
    };
}

pub fn writeJson(writer: *std.Io.Writer, facts: *const Facts) !void {
    const values = &facts.values;
    try writer.print("{{\"version\":\"{s}\",\"type\":\"defaults\",\"changed\":{},\"store\":", .{ protocol.wire_version, facts.changed });
    try std.json.Stringify.value(facts.store, .{}, writer);
    try writer.print(",\"store_source\":\"{s}\",\"store_available\":{},\"provider\":", .{ if (facts.saved_store) "saved" else "home", facts.store_available });
    try std.json.Stringify.value(if (values.provider.len != 0) values.provider.slice() else null, .{}, writer);
    try writer.writeAll(",\"model\":");
    try std.json.Stringify.value(if (values.model.len != 0) values.model.slice() else null, .{}, writer);
    try writer.print(",\"notifications\":{}", .{values.notifications});
    try writer.writeAll(",\"reasoning_effort\":");
    try std.json.Stringify.value(if (values.reasoning_effort) |effort| @tagName(effort) else null, .{}, writer);
    try writer.writeAll(",\"permission_mode\":");
    try std.json.Stringify.value(if (values.permission_mode) |mode| @tagName(mode) else null, .{}, writer);
    try writer.writeAll(",\"local_credentials\":{");
    for (std.enums.values(protocol.Provider), 0..) |provider, index|
        try writer.print("{s}\"{s}\":\"{s}\"", .{ if (index == 0) "" else ",", @tagName(provider), @tagName(facts.readiness.get(provider)) });
    try writer.writeAll("},\"openai_key_source\":");
    if (facts.openai_key) |source| switch (source) {
        .file => |path| {
            try writer.writeAll("{\"file\":");
            try std.json.Stringify.value(path, .{}, writer);
            try writer.writeByte('}');
        },
        .env => |name| {
            try writer.writeAll("{\"env\":");
            try std.json.Stringify.value(name, .{}, writer);
            try writer.writeByte('}');
        },
    } else try writer.writeAll("null");
    try writer.writeAll(",\"next_session\":");
    switch (nextSession(facts)) {
        .chooser => try writer.writeAll("{\"status\":\"choose_provider\"}"),
        .selected => |selected| {
            try writer.print("{{\"status\":\"selected\",\"provider\":\"{s}\",\"model\":", .{selected.provider});
            try std.json.Stringify.value(selected.model, .{}, writer);
            try writer.print(",\"local_credential\":\"{s}\"}}", .{@tagName(selected.readiness)});
        },
        .unsupported_provider => try writer.writeAll("{\"status\":\"unsupported_provider\"}"),
        .unsupported_model => try writer.writeAll("{\"status\":\"unsupported_model\"}"),
    }
    try writer.writeAll(",\"host\":");
    switch (facts.host) {
        .ready => |capabilities| {
            try writer.writeAll("{\"status\":\"ready\",\"capabilities\":");
            try std.json.Stringify.value(capabilities, .{}, writer);
            try writer.writeByte('}');
        },
        else => |status| try writer.print("{{\"status\":\"{s}\"}}", .{@tagName(status)}),
    }
    try writer.writeAll("}\n");
}

fn shownOf(names: *const Names, saved: []const u8) []const u8 {
    const provider = std.meta.stringToEnum(protocol.Provider, saved) orelse return saved;
    return names.shownFor(provider);
}

fn loginOf(names: *const Names, saved: []const u8) []const u8 {
    const provider = std.meta.stringToEnum(protocol.Provider, saved) orelse return "";
    return names.loginFor(provider);
}

fn safeText(out: *std.Io.Writer, value: []const u8) !void {
    var text: TerminalText = .{ .mode = .line };
    try text.feed(out, value);
    try text.finish(out);
}
fn safeField(out: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try out.writeAll(label);
    try safeText(out, value);
    try out.writeByte('\n');
}

pub fn writeStoreNotice(writer: *std.Io.Writer, facts: *const Facts) !void {
    try writer.writeAll("rui: saved ");
    try TerminalText.writeShellWord(writer, facts.values.store.slice());
    try writer.writeAll(" as the global default Store; commands without --store now use it from any directory, and saved requests keep their recorded Store.\n");
}

pub fn writeText(writer: *std.Io.Writer, facts: *const Facts) !void {
    const values = &facts.values;
    const names = &facts.names;
    try writer.writeAll(if (!facts.changed) "Defaults (read only):\n" else if (facts.reader == .conversation) "Saved defaults for future Sessions. Active Session unchanged.\n" else "Saved defaults for future Sessions.\n");
    const selection = nextSession(facts);
    if (facts.reader == .conversation and facts.changed and facts.store_available and selection == .selected and selection.selected.readiness.usable()) return;
    try writer.writeAll("Store: ");
    try safeText(writer, facts.store orelse "unavailable");
    try writer.writeAll(if (facts.saved_store) " (saved)\n" else " (HOME fallback)\n");
    if (!facts.store_available) try writer.writeAll("Store unavailable: destination cannot be selected; no alternate Store selected.\n");
    try safeField(writer, "Provider: ", if (values.provider.len != 0) shownOf(names, values.provider.slice()) else "not selected");
    try safeField(writer, "Model: ", if (values.model.len != 0) values.model.slice() else "not selected");
    try writer.writeAll(if (values.notifications) "Notifications: on\n" else "Notifications: off\n");
    try safeField(writer, "Reasoning effort: ", if (values.reasoning_effort) |effort| @tagName(effort) else "each model's default");
    try safeField(writer, "Permissions: ", if (values.permission_mode) |mode| @tagName(mode) else facts.defaults.permission_mode);
    try writeSignIns(writer, facts.readiness, facts.account, names, facts.openai_key);
    switch (selection) {
        .unsupported_provider => try writer.print("Next Session: saved provider is unsupported; no fallback. Repair with `rui defaults configure --provider {s} --model {s}`.\n", .{ names.choices, facts.defaults.recommended_model }),
        .unsupported_model => try writer.print("Next Session: saved model is unsupported; no fallback. Repair with `rui defaults configure --provider {s} --model {s}`.\n", .{ names.choices, facts.defaults.recommended_model }),
        .chooser => try writer.print("Next Session: choose a provider with `rui defaults configure --provider {s}`; ChatGPT login: `{s}`; OpenAI key: `{s}`.\n", .{ names.choices, names.loginFor(.chatgpt), names.loginFor(.openai) }),
        .selected => |selected| {
            const login = loginOf(names, selected.provider);
            try writer.print("Next Session: {s} / {s} (", .{ shownOf(names, selected.provider), selected.model });
            switch (selected.readiness) {
                .configured => try writer.writeAll("local credential configured; remote acceptance not checked"),
                .renewal_due => try writer.writeAll("local credential usable; renewal due at dispatch; remote acceptance not checked"),
                .missing => if (login.len != 0) try writer.print("credential missing; run `{s}`. No fallback", .{login}) else try writer.writeAll("credential missing. No fallback"),
                .refresh_required => try writer.writeAll("credential refresh required; login may be required. No fallback"),
                .credential_error => try writer.writeAll("credential error; inspect private Rui credential or log in. No fallback"),
            }
            try writer.writeAll(").\n");
        },
    }
    switch (facts.host) {
        .store_unavailable => try writer.writeAll("Host: unavailable; selected Store unavailable.\n"),
        .unavailable => try writer.writeAll("Host: unavailable; setup does not start it.\n"),
        .owned_unavailable => try writer.writeAll("Host: owned but unavailable; inspect before submitting work.\n"),
        .incompatible => try writer.writeAll("Host: incompatible; inspect before submitting work.\n"),
        .access_failure => try writer.writeAll("Host: access failure; inspect Store permissions.\n"),
        .ready => |capabilities| {
            var buffer: [512]u8 = undefined;
            try writer.writeAll(hostProvidersLine(capabilities.providers, names, &buffer));
        },
    }
}

fn chatgptLines(writer: *std.Io.Writer, plan: provider_selection.Readiness, device: provider_selection.Readiness, names: *const Names, account: ?Account) !void {
    switch (plan) {
        .configured, .renewal_due => {
            try writer.writeAll("ChatGPT: signed in");
            if (account) |details| {
                if (details.email.len != 0) try writer.print(" as {s}", .{details.email});
                if (details.expiry) |expiry| try writer.print("; access token expires {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC and renews by itself", .{ expiry.year, expiry.month, expiry.day, expiry.hour, expiry.minute });
            }
            try writer.writeAll(" (remote acceptance not checked).\n");
        },
        .missing => if (device == .missing) try writer.print("ChatGPT: not signed in; sign in with `{s}` (add --device-code to use a code instead of the browser).\n", .{names.loginFor(.chatgpt)}),
        .refresh_required => try writer.print("ChatGPT: a renewal did not finish; sign in again with `{s}`.\n", .{names.loginFor(.chatgpt)}),
        .credential_error => try writer.writeAll("ChatGPT: error reading private Rui credential; inspect it before use.\n"),
    }
    switch (device) {
        .missing => {},
        .configured => try writer.writeAll("ChatGPT (device code): signed in (remote acceptance not checked).\n"),
        .renewal_due => try writer.writeAll("ChatGPT (device code): signed in; renewal due at dispatch (remote acceptance not checked).\n"),
        .refresh_required => try writer.print("ChatGPT (device code): a renewal did not finish; sign in again with `{s}`.\n", .{names.loginFor(.codex)}),
        .credential_error => try writer.writeAll("ChatGPT (device code): error reading private Rui credential; inspect it before use.\n"),
    }
}

fn hostProvidersLine(routes: protocol.Routes, names: *const Names, buffer: []u8) []const u8 {
    if (!protocol.servesModel(routes)) return "Host: ready without a model provider; use `rui host settings --paths` to configure new model work.\n";
    var line = std.Io.Writer.fixed(buffer);
    line.writeAll("Host: serves") catch unreachable;
    var first = true;
    for (std.enums.values(protocol.Provider)) |provider| if (protocol.routeOf(routes, provider) != .unserved) {
        line.print("{s} {s}", .{ if (first) "" else ",", names.shownFor(provider) }) catch unreachable;
        first = false;
    };
    line.writeAll(" (credentials checked locally, not by status)") catch unreachable;
    for (std.enums.values(protocol.Provider)) |provider| if (protocol.routeOf(routes, provider) == .unserved) {
        const login = names.loginFor(provider);
        if (login.len != 0)
            line.print("; to add {s}, stop and restart it after `{s}`", .{ names.shownFor(provider), login }) catch unreachable
        else
            line.print("; {s} needs a sign-in this terminal cannot make yet", .{names.shownFor(provider)}) catch unreachable;
    };
    line.writeAll(".\n") catch unreachable;
    return line.buffered();
}

pub fn writeSignIns(writer: *std.Io.Writer, readiness: *const provider_selection.Readinesses, account: ?Account, names: *const Names, source: ?KeySource) !void {
    try chatgptLines(writer, readiness.get(.chatgpt), readiness.get(.codex), names, account);
    switch (readiness.get(.openai)) {
        .configured, .renewal_due => if (source) |key| switch (key) {
            .file => |path| {
                try writer.writeAll("OpenAI API key: found in file ");
                try safeText(writer, path);
                try writer.writeAll(" (remote acceptance not checked).\n");
            },
            .env => |name| {
                try writer.writeAll("OpenAI API key: found in environment variable ");
                try safeText(writer, name);
                try writer.writeAll(" (remote acceptance not checked).\n");
            },
        } else try writer.writeAll("OpenAI API key: saved locally (remote acceptance not checked).\n"),
        .missing => if (source) |key| switch (key) {
            .file => |path| {
                try writer.writeAll("OpenAI API key: missing from file ");
                try safeText(writer, path);
                try writer.writeAll(".\n");
            },
            .env => |name| {
                try writer.writeAll("OpenAI API key: missing from environment variable ");
                try safeText(writer, name);
                try writer.writeAll(".\n");
            },
        } else try writer.writeAll("OpenAI API key: missing.\n"),
        .refresh_required, .credential_error => if (source) |key| switch (key) {
            .file => |path| {
                try writer.writeAll("OpenAI API key: ");
                try safeText(writer, path);
                try writer.writeAll(" is unreadable, not owner-only or not one key; fix that file.\n");
            },
            .env => |name| {
                try writer.writeAll("OpenAI API key: environment variable ");
                try safeText(writer, name);
                try writer.writeAll(" is not one valid key; fix it.\n");
            },
        } else try writer.print("OpenAI API key: unreadable, not owner-only or not one key; save it again with `{s}`.\n", .{names.loginFor(.openai)}),
    }
}

test "CLI-30 the defaults report is a function of its facts" {
    const names: Names = .{
        .shown = .{ "ChatGPT (device code)", "OpenAI", "ChatGPT" },
        .login = .{ "rui auth login chatgpt --device-code", "rui auth login openai", "rui auth login chatgpt" },
        .choices = "codex|openai|chatgpt",
    };
    const defaults: Defaults = .{ .permission_mode = "bypass", .recommended_model = "gpt-6.1-sol" };
    const Readiness = provider_selection.Readiness;
    const states = std.enums.values(Readiness);

    // Sign-in lines: every ChatGPT plan and device state pair, output compared whole.
    {
        const signed_in = "ChatGPT: signed in (remote acceptance not checked).\n";
        const plan_renew = "ChatGPT: a renewal did not finish; sign in again with `rui auth login chatgpt`.\n";
        const plan_error = "ChatGPT: error reading private Rui credential; inspect it before use.\n";
        const neither = "ChatGPT: not signed in; sign in with `rui auth login chatgpt` (add --device-code to use a code instead of the browser).\n";
        const device_on = "ChatGPT (device code): signed in (remote acceptance not checked).\n";
        const device_due = "ChatGPT (device code): signed in; renewal due at dispatch (remote acceptance not checked).\n";
        const device_renew = "ChatGPT (device code): a renewal did not finish; sign in again with `rui auth login chatgpt --device-code`.\n";
        const device_error = "ChatGPT (device code): error reading private Rui credential; inspect it before use.\n";
        const cases = [_]struct { Readiness, Readiness, ?[]const u8, ?[]const u8 }{
            .{ .configured, .configured, signed_in, device_on },
            .{ .configured, .renewal_due, signed_in, device_due },
            .{ .configured, .missing, signed_in, null },
            .{ .configured, .refresh_required, signed_in, device_renew },
            .{ .configured, .credential_error, signed_in, device_error },
            .{ .renewal_due, .configured, signed_in, device_on },
            .{ .renewal_due, .renewal_due, signed_in, device_due },
            .{ .renewal_due, .missing, signed_in, null },
            .{ .renewal_due, .refresh_required, signed_in, device_renew },
            .{ .renewal_due, .credential_error, signed_in, device_error },
            .{ .missing, .configured, null, device_on },
            .{ .missing, .renewal_due, null, device_due },
            .{ .missing, .missing, neither, null },
            .{ .missing, .refresh_required, null, device_renew },
            .{ .missing, .credential_error, null, device_error },
            .{ .refresh_required, .configured, plan_renew, device_on },
            .{ .refresh_required, .renewal_due, plan_renew, device_due },
            .{ .refresh_required, .missing, plan_renew, null },
            .{ .refresh_required, .refresh_required, plan_renew, device_renew },
            .{ .refresh_required, .credential_error, plan_renew, device_error },
            .{ .credential_error, .configured, plan_error, device_on },
            .{ .credential_error, .renewal_due, plan_error, device_due },
            .{ .credential_error, .missing, plan_error, null },
            .{ .credential_error, .refresh_required, plan_error, device_renew },
            .{ .credential_error, .credential_error, plan_error, device_error },
        };
        try std.testing.expectEqual(states.len * states.len, cases.len);
        for (cases) |case| {
            var output_buffer: [1024]u8 = undefined;
            var output = std.Io.Writer.fixed(&output_buffer);
            try chatgptLines(&output, case[0], case[1], &names, null);
            var expected_buffer: [1024]u8 = undefined;
            var expected = std.Io.Writer.fixed(&expected_buffer);
            if (case[2]) |text| try expected.writeAll(text);
            if (case[3]) |text| try expected.writeAll(text);
            try std.testing.expectEqualStrings(expected.buffered(), output.buffered());
            try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "Codex") == null);
        }
    }

    // Accounts: email, expiry, both or neither show only for a usable plan; an unusable plan ignores the account.
    {
        const accounts = [_]?Account{
            null,
            .{ .email = "person@example.com" },
            .{ .expiry = .{ .year = 2026, .month = 1, .day = 2, .hour = 3, .minute = 4 } },
            .{ .email = "person@example.com", .expiry = .{ .year = 2026, .month = 1, .day = 2, .hour = 3, .minute = 4 } },
        };
        const usable_lines = [_][]const u8{
            "ChatGPT: signed in (remote acceptance not checked).\nOpenAI API key: missing.\n",
            "ChatGPT: signed in as person@example.com (remote acceptance not checked).\nOpenAI API key: missing.\n",
            "ChatGPT: signed in; access token expires 2026-01-02 03:04 UTC and renews by itself (remote acceptance not checked).\nOpenAI API key: missing.\n",
            "ChatGPT: signed in as person@example.com; access token expires 2026-01-02 03:04 UTC and renews by itself (remote acceptance not checked).\nOpenAI API key: missing.\n",
        };
        for ([_]Readiness{ .configured, .renewal_due }) |plan| {
            for (accounts, usable_lines) |account, expected| {
                var readiness = provider_selection.Readinesses.initFill(.missing);
                readiness.set(.chatgpt, plan);
                var output_buffer: [1024]u8 = undefined;
                var output = std.Io.Writer.fixed(&output_buffer);
                try writeSignIns(&output, &readiness, account, &names, null);
                try std.testing.expectEqualStrings(expected, output.buffered());
            }
        }
        const unusable = [_]struct { Readiness, []const u8 }{
            .{ .missing, "ChatGPT: not signed in; sign in with `rui auth login chatgpt` (add --device-code to use a code instead of the browser).\nOpenAI API key: missing.\n" },
            .{ .refresh_required, "ChatGPT: a renewal did not finish; sign in again with `rui auth login chatgpt`.\nOpenAI API key: missing.\n" },
            .{ .credential_error, "ChatGPT: error reading private Rui credential; inspect it before use.\nOpenAI API key: missing.\n" },
        };
        for (unusable) |row| {
            for (accounts) |account| {
                var readiness = provider_selection.Readinesses.initFill(.missing);
                readiness.set(.chatgpt, row[0]);
                var output_buffer: [1024]u8 = undefined;
                var output = std.Io.Writer.fixed(&output_buffer);
                try writeSignIns(&output, &readiness, account, &names, null);
                try std.testing.expectEqualStrings(row[1], output.buffered());
            }
        }
    }

    // OpenAI key line for every readiness state, with the plan and device signed out.
    {
        const lines = [_]struct { Readiness, []const u8 }{
            .{ .configured, "OpenAI API key: saved locally (remote acceptance not checked).\n" },
            .{ .renewal_due, "OpenAI API key: saved locally (remote acceptance not checked).\n" },
            .{ .missing, "OpenAI API key: missing.\n" },
            .{ .refresh_required, "OpenAI API key: unreadable, not owner-only or not one key; save it again with `rui auth login openai`.\n" },
            .{ .credential_error, "OpenAI API key: unreadable, not owner-only or not one key; save it again with `rui auth login openai`.\n" },
        };
        for (lines) |row| {
            var readiness = provider_selection.Readinesses.initFill(.missing);
            readiness.set(.openai, row[0]);
            var output_buffer: [1024]u8 = undefined;
            var output = std.Io.Writer.fixed(&output_buffer);
            try writeSignIns(&output, &readiness, null, &names, null);
            var expected_buffer: [1024]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expected_buffer, "ChatGPT: not signed in; sign in with `rui auth login chatgpt` (add --device-code to use a code instead of the browser).\n{s}", .{row[1]});
            try std.testing.expectEqualStrings(expected, output.buffered());
        }
    }

    // OpenAI key source: the Store's configured or default source is named, with its path or variable name.
    {
        const sourced = [_]struct { Readiness, KeySource, []const u8 }{
            .{ .configured, .{ .file = "/keys/openai.key" }, "OpenAI API key: found in file /keys/openai.key (remote acceptance not checked).\n" },
            .{ .configured, .{ .env = "RUI_OPENAI_KEY" }, "OpenAI API key: found in environment variable RUI_OPENAI_KEY (remote acceptance not checked).\n" },
            .{ .missing, .{ .file = "/keys/absent.key" }, "OpenAI API key: missing from file /keys/absent.key.\n" },
            .{ .missing, .{ .env = "RUI_ABSENT_KEY" }, "OpenAI API key: missing from environment variable RUI_ABSENT_KEY.\n" },
        };
        for (sourced) |row| {
            var readiness = provider_selection.Readinesses.initFill(.missing);
            readiness.set(.openai, row[0]);
            var output_buffer: [1024]u8 = undefined;
            var output = std.Io.Writer.fixed(&output_buffer);
            try writeSignIns(&output, &readiness, null, &names, row[1]);
            try std.testing.expect(std.mem.endsWith(u8, output.buffered(), row[2]));
        }
        // An unreadable key names its source when one is known; without a source it keeps the login sentence.
        const unreadable_rows = [_]struct { Readiness, ?KeySource, []const u8 }{
            .{ .credential_error, .{ .file = "/keys/openai.key" }, "OpenAI API key: /keys/openai.key is unreadable, not owner-only or not one key; fix that file.\n" },
            .{ .refresh_required, .{ .file = "/keys/openai.key" }, "OpenAI API key: /keys/openai.key is unreadable, not owner-only or not one key; fix that file.\n" },
            .{ .credential_error, .{ .env = "RUI_OPENAI_KEY" }, "OpenAI API key: environment variable RUI_OPENAI_KEY is not one valid key; fix it.\n" },
            .{ .refresh_required, .{ .env = "RUI_OPENAI_KEY" }, "OpenAI API key: environment variable RUI_OPENAI_KEY is not one valid key; fix it.\n" },
            .{ .credential_error, null, "OpenAI API key: unreadable, not owner-only or not one key; save it again with `rui auth login openai`.\n" },
        };
        for (unreadable_rows) |row| {
            var readiness = provider_selection.Readinesses.initFill(.missing);
            readiness.set(.openai, row[0]);
            var unreadable_buffer: [1024]u8 = undefined;
            var unreadable_out = std.Io.Writer.fixed(&unreadable_buffer);
            try writeSignIns(&unreadable_out, &readiness, null, &names, row[1]);
            const got = unreadable_out.buffered();
            try std.testing.expect(got.len >= row[2].len);
            try std.testing.expectEqualStrings(row[2], got[got.len - row[2].len ..]);
        }
        // JSON carries the source as an object for file and env, and null when none was found.
        const json_cases = [_]struct { ?KeySource, []const u8 }{
            .{ .{ .file = "/keys/openai.key" }, "\"openai_key_source\":{\"file\":\"/keys/openai.key\"},\"next_session\"" },
            .{ .{ .env = "RUI_OPENAI_KEY" }, "\"openai_key_source\":{\"env\":\"RUI_OPENAI_KEY\"},\"next_session\"" },
            .{ null, "\"openai_key_source\":null,\"next_session\"" },
        };
        for (json_cases) |row| {
            var readiness = provider_selection.Readinesses.initFill(.missing);
            var facts: Facts = .{ .changed = false, .values = .{}, .store = "/s", .saved_store = false, .store_available = true, .readiness = &readiness, .host = .unavailable, .names = names, .defaults = defaults, .openai_key = row[0] };
            var json_buffer: [4096]u8 = undefined;
            var json = std.Io.Writer.fixed(&json_buffer);
            try writeJson(&json, &facts);
            try std.testing.expect(std.mem.indexOf(u8, json.buffered(), row[1]) != null);
        }
    }

    // Host line: every provider served, then each provider unserved in turn, with and without a sign-in command.
    {
        var buffer: [512]u8 = undefined;
        try std.testing.expectEqualStrings("Host: serves ChatGPT (device code), OpenAI, ChatGPT (credentials checked locally, not by status).\n", hostProvidersLine(protocol.routesAll(.endpoint), &names, &buffer));
        const served_one: protocol.Routes = .{ .codex = .chatgpt_device, .openai = .unserved, .chatgpt = .unserved };
        try std.testing.expectEqualStrings("Host: serves ChatGPT (device code) (credentials checked locally, not by status); to add OpenAI, stop and restart it after `rui auth login openai`; to add ChatGPT, stop and restart it after `rui auth login chatgpt`.\n", hostProvidersLine(served_one, &names, &buffer));
        for ([_]bool{ false, true }) |silent| {
            var table = names;
            if (silent) table.login[@backingInt(protocol.Provider.openai)] = "";
            inline for (@typeInfo(protocol.Provider).@"enum".field_names) |name| {
                var routes = protocol.routesAll(.endpoint);
                @field(routes, name) = .unserved;
                const provider = std.meta.stringToEnum(protocol.Provider, name).?;
                const said = hostProvidersLine(routes, &table, &buffer);
                var expected_buffer: [256]u8 = undefined;
                const login = table.loginFor(provider);
                const expected = if (login.len != 0)
                    try std.fmt.bufPrint(&expected_buffer, "; to add {s}, stop and restart it after `{s}`", .{ table.shownFor(provider), login })
                else
                    try std.fmt.bufPrint(&expected_buffer, "; {s} needs a sign-in this terminal cannot make yet", .{table.shownFor(provider)});
                try std.testing.expect(std.mem.indexOf(u8, said, expected) != null);
            }
        }
    }

    // Next Session by readiness: one usable provider is selected with the recommended model; two ask for a choice.
    inline for (@typeInfo(protocol.Provider).@"enum".field_names) |name| {
        const provider = std.meta.stringToEnum(protocol.Provider, name).?;
        var readiness = provider_selection.Readinesses.initFill(.missing);
        readiness.set(provider, .configured);
        var facts: Facts = .{ .changed = false, .values = .{}, .store = "/s", .saved_store = false, .store_available = true, .readiness = &readiness, .host = .unavailable, .names = names, .defaults = defaults };
        var output_buffer: [2048]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        try writeText(&output, &facts);
        var expected_buffer: [256]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "Next Session: {s} / gpt-6.1-sol (local credential configured; remote acceptance not checked).\n", .{names.shownFor(provider)});
        try std.testing.expect(std.mem.indexOf(u8, output.buffered(), expected) != null);
        var json_buffer: [4096]u8 = undefined;
        var json = std.Io.Writer.fixed(&json_buffer);
        try writeJson(&json, &facts);
        var json_expected_buffer: [256]u8 = undefined;
        const json_expected = try std.fmt.bufPrint(&json_expected_buffer, "\"next_session\":{{\"status\":\"selected\",\"provider\":\"{s}\",\"model\":\"gpt-6.1-sol\",\"local_credential\":\"configured\"}}", .{name});
        try std.testing.expect(std.mem.indexOf(u8, json.buffered(), json_expected) != null);
    }
    {
        var readiness = provider_selection.Readinesses.initFill(.missing);
        readiness.set(.codex, .configured);
        readiness.set(.openai, .configured);
        var facts: Facts = .{ .changed = false, .values = .{}, .store = "/s", .saved_store = false, .store_available = true, .readiness = &readiness, .host = .unavailable, .names = names, .defaults = defaults };
        var json_buffer: [4096]u8 = undefined;
        var json = std.Io.Writer.fixed(&json_buffer);
        try writeJson(&json, &facts);
        try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"next_session\":{\"status\":\"choose_provider\"}") != null);
    }

    // Saved selection, Store and availability across every reader: the early return, the Store line and both writers.
    const hostile_store = "/a\"b\n";
    const selections = [_]struct {
        provider: []const u8,
        model: []const u8,
        readiness: Readiness,
        provider_line: []const u8,
        next: []const u8,
        json: []const u8,
    }{
        .{ .provider = "", .model = "", .readiness = .missing, .provider_line = "Provider: not selected\n", .next = "Next Session: choose a provider with `rui defaults configure --provider codex|openai|chatgpt`; ChatGPT login: `rui auth login chatgpt`; OpenAI key: `rui auth login openai`.\n", .json = "\"next_session\":{\"status\":\"choose_provider\"}" },
        .{ .provider = "codex", .model = "gpt-6-luna", .readiness = .configured, .provider_line = "Provider: ChatGPT (device code)\n", .next = "Next Session: ChatGPT (device code) / gpt-6-luna (local credential configured; remote acceptance not checked).\n", .json = "\"next_session\":{\"status\":\"selected\",\"provider\":\"codex\",\"model\":\"gpt-6-luna\",\"local_credential\":\"configured\"}" },
        .{ .provider = "codex", .model = "gpt-6-luna", .readiness = .renewal_due, .provider_line = "Provider: ChatGPT (device code)\n", .next = "Next Session: ChatGPT (device code) / gpt-6-luna (local credential usable; renewal due at dispatch; remote acceptance not checked).\n", .json = "\"next_session\":{\"status\":\"selected\",\"provider\":\"codex\",\"model\":\"gpt-6-luna\",\"local_credential\":\"renewal_due\"}" },
        .{ .provider = "codex", .model = "gpt-6-luna", .readiness = .missing, .provider_line = "Provider: ChatGPT (device code)\n", .next = "Next Session: ChatGPT (device code) / gpt-6-luna (credential missing; run `rui auth login chatgpt --device-code`. No fallback).\n", .json = "\"next_session\":{\"status\":\"selected\",\"provider\":\"codex\",\"model\":\"gpt-6-luna\",\"local_credential\":\"missing\"}" },
        .{ .provider = "codex", .model = "gpt-6-luna", .readiness = .refresh_required, .provider_line = "Provider: ChatGPT (device code)\n", .next = "Next Session: ChatGPT (device code) / gpt-6-luna (credential refresh required; login may be required. No fallback).\n", .json = "\"next_session\":{\"status\":\"selected\",\"provider\":\"codex\",\"model\":\"gpt-6-luna\",\"local_credential\":\"refresh_required\"}" },
        .{ .provider = "codex", .model = "gpt-6-luna", .readiness = .credential_error, .provider_line = "Provider: ChatGPT (device code)\n", .next = "Next Session: ChatGPT (device code) / gpt-6-luna (credential error; inspect private Rui credential or log in. No fallback).\n", .json = "\"next_session\":{\"status\":\"selected\",\"provider\":\"codex\",\"model\":\"gpt-6-luna\",\"local_credential\":\"credential_error\"}" },
        .{ .provider = "retired", .model = "old-model", .readiness = .configured, .provider_line = "Provider: retired\n", .next = "Next Session: saved provider is unsupported; no fallback. Repair with `rui defaults configure --provider codex|openai|chatgpt --model gpt-6.1-sol`.\n", .json = "\"next_session\":{\"status\":\"unsupported_provider\"}" },
        .{ .provider = "codex", .model = "bad model", .readiness = .configured, .provider_line = "Provider: ChatGPT (device code)\n", .next = "Next Session: saved model is unsupported; no fallback. Repair with `rui defaults configure --provider codex|openai|chatgpt --model gpt-6.1-sol`.\n", .json = "\"next_session\":{\"status\":\"unsupported_model\"}" },
    };
    for ([_]Reader{ .command_line, .overview, .conversation }) |reader| for ([_]bool{ false, true }) |changed| for ([_]bool{ false, true }) |saved| for ([_]bool{ false, true }) |available| for ([_]bool{ false, true }) |hostile| for (selections) |selection| {
        var readiness = provider_selection.Readinesses.initFill(.missing);
        readiness.set(.codex, selection.readiness);
        var values: preference_document.Values = .{};
        try values.provider.set(selection.provider);
        try values.model.set(selection.model);
        const store: ?[]const u8 = if (hostile) hostile_store else null;
        const facts: Facts = .{ .changed = changed, .values = values, .store = store, .saved_store = saved, .store_available = available, .readiness = &readiness, .host = .unavailable, .reader = reader, .names = names, .defaults = defaults };
        var json_buffer: [8192]u8 = undefined;
        var json = std.Io.Writer.fixed(&json_buffer);
        try writeJson(&json, &facts);
        const json_text = json.buffered();
        try std.testing.expect(std.mem.indexOf(u8, json_text, if (hostile) "\"store\":\"/a\\\"b\\n\"" else "\"store\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, json_text, if (saved) "\"store_source\":\"saved\"" else "\"store_source\":\"home\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json_text, if (available) "\"store_available\":true" else "\"store_available\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, json_text, if (changed) "\"changed\":true" else "\"changed\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, json_text, selection.json) != null);
        if (reader == .command_line) {
            try std.testing.expect(wantsJson(&facts));
            continue;
        }
        try std.testing.expect(!wantsJson(&facts));
        const header = if (!changed) "Defaults (read only):\n" else if (reader == .conversation) "Saved defaults for future Sessions. Active Session unchanged.\n" else "Saved defaults for future Sessions.\n";
        var text_buffer: [8192]u8 = undefined;
        var text = std.Io.Writer.fixed(&text_buffer);
        try writeText(&text, &facts);
        const text_out = text.buffered();
        const selected_ready = selection.readiness.usable() and std.mem.indexOf(u8, selection.json, "\"status\":\"selected\"") != null;
        if (reader == .conversation and changed and available and selected_ready) {
            try std.testing.expectEqualStrings(header, text_out);
            continue;
        }
        var store_line_buffer: [128]u8 = undefined;
        const store_line = try std.fmt.bufPrint(&store_line_buffer, "Store: {s}{s}\n", .{ if (hostile) "/a\\\"b\\n" else "unavailable", if (saved) " (saved)" else " (HOME fallback)" });
        try std.testing.expect(std.mem.startsWith(u8, text_out, header));
        try std.testing.expect(std.mem.indexOf(u8, text_out, store_line) != null);
        try std.testing.expect((std.mem.indexOf(u8, text_out, "Store unavailable: destination cannot be selected") != null) == !available);
        try std.testing.expect(std.mem.indexOf(u8, text_out, selection.provider_line) != null);
        try std.testing.expect(std.mem.indexOf(u8, text_out, selection.next) != null);
        try std.testing.expect(std.mem.indexOf(u8, text_out, "Host: unavailable; setup does not start it.\n") != null);
    };

    // Values: notifications, reasoning effort and permission mode, each with its default text and JSON when unset.
    const Effort = @typeInfo(@FieldType(preference_document.Values, "reasoning_effort")).optional.child;
    const Permission = @typeInfo(@FieldType(preference_document.Values, "permission_mode")).optional.child;
    const efforts = std.enums.values(Effort);
    const modes = std.enums.values(Permission);
    for ([_]bool{ true, false }) |notifications| for (0..efforts.len + 1) |effort_index| for (0..modes.len + 1) |mode_index| {
        var readiness = provider_selection.Readinesses.initFill(.missing);
        var values: preference_document.Values = .{ .notifications = notifications };
        if (effort_index > 0) values.reasoning_effort = efforts[effort_index - 1];
        if (mode_index > 0) values.permission_mode = modes[mode_index - 1];
        const facts: Facts = .{ .changed = false, .values = values, .store = "/s", .saved_store = true, .store_available = true, .readiness = &readiness, .host = .unavailable, .reader = .overview, .names = names, .defaults = defaults };
        var text_buffer: [8192]u8 = undefined;
        var text = std.Io.Writer.fixed(&text_buffer);
        try writeText(&text, &facts);
        var expected_buffer: [512]u8 = undefined;
        const effort_text = if (effort_index > 0) @tagName(efforts[effort_index - 1]) else "each model's default";
        const mode_text = if (mode_index > 0) @tagName(modes[mode_index - 1]) else defaults.permission_mode;
        const expected = try std.fmt.bufPrint(&expected_buffer, "{s}Reasoning effort: {s}\nPermissions: {s}\n", .{ if (notifications) "Notifications: on\n" else "Notifications: off\n", effort_text, mode_text });
        try std.testing.expect(std.mem.indexOf(u8, text.buffered(), expected) != null);
        var json_buffer: [8192]u8 = undefined;
        var json = std.Io.Writer.fixed(&json_buffer);
        try writeJson(&json, &facts);
        var json_expected_buffer: [256]u8 = undefined;
        const notifications_json = try std.fmt.bufPrint(&json_expected_buffer, ",\"notifications\":{s},", .{if (notifications) "true" else "false"});
        try std.testing.expect(std.mem.indexOf(u8, json.buffered(), notifications_json) != null);
        const effort_json = if (effort_index > 0) try std.fmt.bufPrint(&json_expected_buffer, ",\"reasoning_effort\":\"{s}\",", .{effort_text}) else ",\"reasoning_effort\":null,";
        try std.testing.expect(std.mem.indexOf(u8, json.buffered(), effort_json) != null);
        const mode_json = if (mode_index > 0) try std.fmt.bufPrint(&json_expected_buffer, ",\"permission_mode\":\"{s}\",", .{mode_text}) else ",\"permission_mode\":null,";
        try std.testing.expect(std.mem.indexOf(u8, json.buffered(), mode_json) != null);
    };

    // The wire document itself, with the Host read as unavailable and nothing saved.
    var wire_readiness = provider_selection.Readinesses.initFill(.missing);
    const wire_facts: Facts = .{ .changed = false, .values = .{}, .store = "/home/test/.local/share/rui/store", .saved_store = false, .store_available = false, .readiness = &wire_readiness, .host = .store_unavailable, .names = names, .defaults = defaults };
    var output: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeJson(&writer, &wire_facts);
    try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"defaults\",\"changed\":false,\"store\":\"/home/test/.local/share/rui/store\",\"store_source\":\"home\",\"store_available\":false,\"provider\":null,\"model\":null,\"notifications\":true,\"reasoning_effort\":null,\"permission_mode\":null,\"local_credentials\":{\"codex\":\"missing\",\"openai\":\"missing\",\"chatgpt\":\"missing\"},\"openai_key_source\":null,\"next_session\":{\"status\":\"choose_provider\"},\"host\":{\"status\":\"store_unavailable\"}}\n", writer.buffered());
}

test "Store overlay reports the OpenAI key source only when the Store names one" {
    const Tag = std.meta.Tag(KeySource);
    const tagOf = struct {
        fn of(source: ?KeySource) ?Tag {
            return if (source) |value| std.meta.activeTag(value) else null;
        }
    }.of;
    const Readiness = provider_selection.Readiness;
    var local = provider_selection.Readinesses.initFill(.missing);
    local.set(.openai, .configured);

    // No inspect result (the inspect failed, or there is no Store): the local readiness stands, with no source.
    const none = overlayStore(local, null);
    try std.testing.expectEqual(Readiness.configured, none.readiness.get(.openai));
    try std.testing.expectEqual(@as(?Tag, null), tagOf(none.key_source));

    // A configured file source overrides the local readiness and is reported.
    const configured = overlayStore(local, .{ .readiness = .configured, .key_source = .{ .file = "/keys/configured.key" } });
    try std.testing.expectEqual(Readiness.configured, configured.readiness.get(.openai));
    try std.testing.expectEqual(@as(?Tag, .file), tagOf(configured.key_source));
    try std.testing.expectEqualStrings("/keys/configured.key", configured.key_source.?.file);

    // A missing file source overrides a readable local key: the Store's Host reads no key.
    const absent = overlayStore(local, .{ .readiness = .missing, .key_source = .{ .file = "/keys/absent.key" } });
    try std.testing.expectEqual(Readiness.missing, absent.readiness.get(.openai));
    try std.testing.expectEqual(@as(?Tag, .file), tagOf(absent.key_source));
    try std.testing.expectEqualStrings("/keys/absent.key", absent.key_source.?.file);

    // An unreadable environment source overrides the local readiness and is reported.
    const unreadable = overlayStore(local, .{ .readiness = .credential_error, .key_source = .{ .env = "RUI_OPENAI_KEY" } });
    try std.testing.expectEqual(Readiness.credential_error, unreadable.readiness.get(.openai));
    try std.testing.expectEqual(@as(?Tag, .env), tagOf(unreadable.key_source));
    try std.testing.expectEqualStrings("RUI_OPENAI_KEY", unreadable.key_source.?.env);

    // Explicit providers that omit openai name no source: the local readiness stands.
    const omitted = overlayStore(local, .{ .readiness = .missing, .key_source = null });
    try std.testing.expectEqual(Readiness.configured, omitted.readiness.get(.openai));
    try std.testing.expectEqual(@as(?Tag, null), tagOf(omitted.key_source));

    // Unauthenticated sends no key, so it never overrides the local readiness, whatever source it names.
    const open = overlayStore(local, .{ .readiness = .configured, .unauthenticated = true, .key_source = null });
    try std.testing.expectEqual(Readiness.configured, open.readiness.get(.openai));
    try std.testing.expectEqual(@as(?Tag, null), tagOf(open.key_source));
    const open_with_source = overlayStore(provider_selection.Readinesses.initFill(.missing), .{ .readiness = .configured, .unauthenticated = true, .key_source = .{ .env = "RUI_OPENAI_KEY" } });
    try std.testing.expectEqual(Readiness.missing, open_with_source.readiness.get(.openai));
    try std.testing.expectEqual(@as(?Tag, null), tagOf(open_with_source.key_source));
}
