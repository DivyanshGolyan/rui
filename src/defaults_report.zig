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

/// Sign-in commands as the provider table spells them. The shell fills these
/// from the table; this core only places them in sentences.
pub const Logins = struct {
    chatgpt: []const u8,
    codex: []const u8,
    openai: []const u8,
};

/// Saved-default facts the shell reads from product defaults.
pub const Defaults = struct {
    permission_mode: []const u8,
    recommended_model: []const u8,
};

pub const Facts = struct {
    changed: bool,
    values: preference_document.Values,
    store: ?[]const u8,
    saved_store: bool,
    store_available: bool,
    readiness: *const provider_selection.Readinesses,
    host: Host,
    account: ?Account = null,
    reader: Reader = .command_line,
    logins: Logins,
    defaults: Defaults,
};

const provider_choices = choices: {
    var text: []const u8 = "";
    for (@typeInfo(protocol.Provider).@"enum".field_names, 0..) |name, index| text = text ++ (if (index == 0) "" else "|") ++ name;
    break :choices text;
};

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
    try writer.writeAll("},\"next_session\":");
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

fn providerShown(saved: []const u8) []const u8 {
    const provider = std.meta.stringToEnum(protocol.Provider, saved) orelse return saved;
    return provider.shown();
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
    try writer.writeAll(if (!facts.changed) "Defaults (read only):\n" else if (facts.reader == .conversation) "Saved defaults for future Sessions. Active Session unchanged.\n" else "Saved defaults for future Sessions.\n");
    const selection = nextSession(facts);
    if (facts.reader == .conversation and facts.changed and facts.store_available and selection == .selected and selection.selected.readiness.usable()) return;
    try writer.writeAll("Store: ");
    try safeText(writer, facts.store orelse "unavailable");
    try writer.writeAll(if (facts.saved_store) " (saved)\n" else " (HOME fallback)\n");
    if (!facts.store_available) try writer.writeAll("Store unavailable: destination cannot be selected; no alternate Store selected.\n");
    try safeField(writer, "Provider: ", if (values.provider.len != 0) providerShown(values.provider.slice()) else "not selected");
    try safeField(writer, "Model: ", if (values.model.len != 0) values.model.slice() else "not selected");
    try writer.writeAll(if (values.notifications) "Notifications: on\n" else "Notifications: off\n");
    try safeField(writer, "Reasoning effort: ", if (values.reasoning_effort) |effort| @tagName(effort) else "each model's default");
    try safeField(writer, "Permissions: ", if (values.permission_mode) |mode| @tagName(mode) else facts.defaults.permission_mode);
    try writeSignIns(writer, facts.readiness, facts.account, facts.logins);
    switch (selection) {
        .unsupported_provider => try writer.print("Next Session: saved provider is unsupported; no fallback. Repair with `rui defaults configure --provider {s} --model {s}`.\n", .{ provider_choices, facts.defaults.recommended_model }),
        .unsupported_model => try writer.print("Next Session: saved model is unsupported; no fallback. Repair with `rui defaults configure --provider {s} --model {s}`.\n", .{ provider_choices, facts.defaults.recommended_model }),
        .chooser => try writer.print("Next Session: choose a provider with `rui defaults configure --provider {s}`; ChatGPT login: `{s}`; OpenAI key: `{s}`.\n", .{ provider_choices, facts.logins.chatgpt, facts.logins.openai }),
        .selected => |selected| {
            const login_command = if (std.meta.stringToEnum(protocol.Provider, selected.provider)) |provider| provider.login() else null;
            try writer.print("Next Session: {s} / {s} (", .{ providerShown(selected.provider), selected.model });
            switch (selected.readiness) {
                .configured => try writer.writeAll("local credential configured; remote acceptance not checked"),
                .renewal_due => try writer.writeAll("local credential usable; renewal due at dispatch; remote acceptance not checked"),
                .missing => if (login_command) |command| try writer.print("credential missing; run `{s}`. No fallback", .{command}) else try writer.writeAll("credential missing. No fallback"),
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
        .ready => |capabilities| try writeHostProviders(writer, capabilities.providers),
    }
}

fn hostProvidersLine(routes: protocol.Routes, buffer: []u8) []const u8 {
    if (!protocol.servesModel(routes)) return "Host: ready without a model provider; use `rui host settings --paths` to configure new model work.\n";
    var line = std.Io.Writer.fixed(buffer);
    line.writeAll("Host: serves") catch unreachable;
    var first = true;
    for (std.enums.values(protocol.Provider)) |provider| if (protocol.routeOf(routes, provider) != .unserved) {
        line.print("{s} {s}", .{ if (first) "" else ",", provider.shown() }) catch unreachable;
        first = false;
    };
    line.writeAll(" (credentials checked locally, not by status)") catch unreachable;
    for (std.enums.values(protocol.Provider)) |provider| if (protocol.routeOf(routes, provider) == .unserved) {
        if (provider.login()) |command|
            line.print("; to add {s}, stop and restart it after `{s}`", .{ provider.shown(), command }) catch unreachable
        else
            line.print("; {s} needs a sign-in this terminal cannot make yet", .{provider.shown()}) catch unreachable;
    };
    line.writeAll(".\n") catch unreachable;
    return line.buffered();
}

fn writeHostProviders(writer: *std.Io.Writer, routes: protocol.Routes) !void {
    var buffer: [512]u8 = undefined;
    try writer.writeAll(hostProvidersLine(routes, &buffer));
}

fn writeChatgptLines(writer: *std.Io.Writer, plan: provider_selection.Readiness, device: provider_selection.Readiness, logins: Logins, account: ?Account) !void {
    switch (plan) {
        .configured, .renewal_due => {
            try writer.writeAll("ChatGPT: signed in");
            if (account) |details| {
                if (details.email.len != 0) try writer.print(" as {s}", .{details.email});
                if (details.expiry) |expiry| try writer.print("; access token expires {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC and renews by itself", .{ expiry.year, expiry.month, expiry.day, expiry.hour, expiry.minute });
            }
            try writer.writeAll(" (remote acceptance not checked).\n");
        },
        .missing => if (device == .missing) try writer.print("ChatGPT: not signed in; sign in with `{s}` (add --device-code to use a code instead of the browser).\n", .{logins.chatgpt}),
        .refresh_required => try writer.print("ChatGPT: a renewal did not finish; sign in again with `{s}`.\n", .{logins.chatgpt}),
        .credential_error => try writer.writeAll("ChatGPT: error reading private Rui credential; inspect it before use.\n"),
    }
    switch (device) {
        .missing => {},
        .configured => try writer.writeAll("ChatGPT (device code): signed in (remote acceptance not checked).\n"),
        .renewal_due => try writer.writeAll("ChatGPT (device code): signed in; renewal due at dispatch (remote acceptance not checked).\n"),
        .refresh_required => try writer.print("ChatGPT (device code): a renewal did not finish; sign in again with `{s}`.\n", .{logins.codex}),
        .credential_error => try writer.writeAll("ChatGPT (device code): error reading private Rui credential; inspect it before use.\n"),
    }
}

pub fn writeSignIns(writer: *std.Io.Writer, readiness: *const provider_selection.Readinesses, account: ?Account, logins: Logins) !void {
    try writeChatgptLines(writer, readiness.get(.chatgpt), readiness.get(.codex), logins, account);
    switch (readiness.get(.openai)) {
        .configured, .renewal_due => try writer.writeAll("OpenAI API key: saved locally (remote acceptance not checked).\n"),
        .missing => try writer.writeAll("OpenAI API key: missing.\n"),
        .refresh_required, .credential_error => try writer.print("OpenAI API key: unreadable, not owner-only or not one key; save it again with `{s}`.\n", .{logins.openai}),
    }
}

test "CLI-24 the defaults report is a function of its facts" {
    const logins: Logins = .{ .chatgpt = "rui auth login chatgpt", .codex = "rui auth login chatgpt --device-code", .openai = "rui auth login openai" };
    const defaults: Defaults = .{ .permission_mode = "bypass", .recommended_model = "gpt-6.1-sol" };
    {
        // Sign-in lines: every plan and device state pair, with the account line the plan says.
        const Readiness = provider_selection.Readiness;
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
        try std.testing.expectEqual(std.enums.values(Readiness).len * std.enums.values(Readiness).len, cases.len);
        for (cases) |case| {
            var output_buffer: [1024]u8 = undefined;
            var output = std.Io.Writer.fixed(&output_buffer);
            try writeChatgptLines(&output, case[0], case[1], logins, null);
            var expected_buffer: [1024]u8 = undefined;
            var expected = std.Io.Writer.fixed(&expected_buffer);
            if (case[2]) |text| try expected.writeAll(text);
            if (case[3]) |text| try expected.writeAll(text);
            try std.testing.expectEqualStrings(expected.buffered(), output.buffered());
            try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "Codex") == null);
        }
    }
    {
        // The Host line names a login only for an unserved provider that has one.
        var buffer: [512]u8 = undefined;
        const served_one: protocol.Routes = .{ .codex = .chatgpt_device, .openai = .unserved, .chatgpt = .unserved };
        try std.testing.expectEqualStrings("Host: serves ChatGPT (device code) (credentials checked locally, not by status); to add OpenAI, stop and restart it after `rui auth login openai`; to add ChatGPT, stop and restart it after `rui auth login chatgpt`.\n", hostProvidersLine(served_one, &buffer));
        inline for (comptime std.enums.values(protocol.Provider)) |unserved| {
            var routes = protocol.routesAll(.endpoint);
            switch (unserved) {
                .codex => routes.codex = .unserved,
                .openai => routes.openai = .unserved,
                .chatgpt => routes.chatgpt = .unserved,
            }
            const said = hostProvidersLine(routes, &buffer);
            if (unserved.login()) |command|
                try std.testing.expect(std.mem.indexOf(u8, said, command) != null)
            else
                try std.testing.expect(std.mem.indexOf(u8, said, "rui auth login") == null and std.mem.indexOf(u8, said, "cannot make yet") != null);
        }
    }
    const expectations = [_]struct { provider: []const u8, model: []const u8, json: []const u8, text: []const u8 }{
        .{ .provider = "", .model = "", .json = "\"status\":\"choose_provider\"", .text = "Next Session: choose a provider" },
        .{ .provider = "codex", .model = "gpt-6-luna", .json = "\"status\":\"selected\",\"provider\":\"codex\",\"model\":\"gpt-6-luna\"", .text = "Next Session: ChatGPT (device code) / gpt-6-luna" },
        .{ .provider = "retired", .model = "old-model", .json = "\"status\":\"unsupported_provider\"", .text = "Next Session: saved provider is unsupported; no fallback" },
        .{ .provider = "codex", .model = "bad model", .json = "\"status\":\"unsupported_model\"", .text = "Next Session: saved model is unsupported; no fallback" },
    };
    const host_rows = [_]struct { host: Host, json: []const u8, text: []const u8 }{
        .{ .host = .store_unavailable, .json = "\"host\":{\"status\":\"store_unavailable\"}", .text = "Host: unavailable; selected Store unavailable.\n" },
        .{ .host = .unavailable, .json = "\"host\":{\"status\":\"unavailable\"}", .text = "Host: unavailable; setup does not start it.\n" },
        .{ .host = .owned_unavailable, .json = "\"host\":{\"status\":\"owned_unavailable\"}", .text = "Host: owned but unavailable; inspect before submitting work.\n" },
        .{ .host = .incompatible, .json = "\"host\":{\"status\":\"incompatible\"}", .text = "Host: incompatible; inspect before submitting work.\n" },
        .{ .host = .access_failure, .json = "\"host\":{\"status\":\"access_failure\"}", .text = "Host: access failure; inspect Store permissions.\n" },
        .{ .host = .{ .ready = .{ .bash = false, .providers = protocol.routesAll(.unserved) } }, .json = "\"host\":{\"status\":\"ready\",\"capabilities\":", .text = "Host: ready without a model provider; use `rui host settings --paths` to configure new model work.\n" },
    };
    const states = [_]struct { state: provider_selection.Readiness, json: []const u8, selected: []const u8 }{
        .{ .state = .configured, .json = "\"codex\":\"configured\"", .selected = "local credential configured; remote acceptance not checked" },
        .{ .state = .renewal_due, .json = "\"codex\":\"renewal_due\"", .selected = "local credential usable; renewal due at dispatch; remote acceptance not checked" },
        .{ .state = .missing, .json = "\"codex\":\"missing\"", .selected = "credential missing; run `rui auth login chatgpt --device-code`. No fallback" },
        .{ .state = .refresh_required, .json = "\"codex\":\"refresh_required\"", .selected = "credential refresh required; login may be required. No fallback" },
        .{ .state = .credential_error, .json = "\"codex\":\"credential_error\"", .selected = "credential error; inspect private Rui credential or log in. No fallback" },
    };
    for ([_]bool{ false, true }) |saved| for ([_]bool{ false, true }) |available| for (expectations, 0..) |row, index| for (states) |state| for (host_rows) |host_row| for ([_]bool{ false, true }) |changed| {
        var values: preference_document.Values = .{};
        try values.provider.set(row.provider);
        try values.model.set(row.model);
        var readiness = provider_selection.Readinesses.initFill(.missing);
        // With no saved provider a usable sole Codex credential selects it.
        // Leave it missing for the chooser case; the other rows cover every state.
        readiness.set(.codex, if (index == 0) .missing else state.state);
        const facts: Facts = .{ .changed = changed, .values = values, .store = "/a\"b\n", .saved_store = saved, .store_available = available, .readiness = &readiness, .host = host_row.host, .reader = .overview, .logins = logins, .defaults = defaults };
        var json_buffer: [8192]u8 = undefined;
        var json = std.Io.Writer.fixed(&json_buffer);
        try writeJson(&json, &facts);
        const actual = json.buffered();
        try std.testing.expect(std.mem.indexOf(u8, actual, "\"store\":\"/a\\\"b\\n\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, actual, if (saved) "\"store_source\":\"saved\"" else "\"store_source\":\"home\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, actual, if (available) "\"store_available\":true" else "\"store_available\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, actual, if (changed) "\"changed\":true" else "\"changed\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, actual, row.json) != null);
        try std.testing.expect(std.mem.indexOf(u8, actual, host_row.json) != null);
        if (index != 0) try std.testing.expect(std.mem.indexOf(u8, actual, state.json) != null);
        var text_buffer: [8192]u8 = undefined;
        var text = std.Io.Writer.fixed(&text_buffer);
        try writeText(&text, &facts);
        try std.testing.expect(std.mem.indexOf(u8, text.buffered(), row.text) != null);
        try std.testing.expect(std.mem.indexOf(u8, text.buffered(), host_row.text) != null);
        if (index == 1) try std.testing.expect(std.mem.indexOf(u8, text.buffered(), state.selected) != null);
    };
    var readiness = provider_selection.Readinesses.initFill(.missing);
    var facts: Facts = .{ .changed = false, .values = .{}, .store = "/home/test/.local/share/rui/store", .saved_store = false, .store_available = false, .readiness = &readiness, .host = .store_unavailable, .logins = logins, .defaults = defaults };
    var output: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeJson(&writer, &facts);
    try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"defaults\",\"changed\":false,\"store\":\"/home/test/.local/share/rui/store\",\"store_source\":\"home\",\"store_available\":false,\"provider\":null,\"model\":null,\"notifications\":true,\"reasoning_effort\":null,\"permission_mode\":null,\"local_credentials\":{\"codex\":\"missing\",\"openai\":\"missing\",\"chatgpt\":\"missing\"},\"next_session\":{\"status\":\"choose_provider\"},\"host\":{\"status\":\"store_unavailable\"}}\n", writer.buffered());
    try facts.values.provider.set("codex");
    readiness.set(.codex, .configured);
    facts.changed = true;
    facts.store_available = true;
    facts.reader = .conversation;
    writer = std.Io.Writer.fixed(&output);
    try writeText(&writer, &facts);
    try std.testing.expectEqualStrings("Saved defaults for future Sessions. Active Session unchanged.\n", writer.buffered());
    var account_output: [1024]u8 = undefined;
    var account_writer = std.Io.Writer.fixed(&account_output);
    readiness.set(.chatgpt, .configured);
    try writeSignIns(&account_writer, &readiness, .{ .email = "person@example.com", .expiry = .{ .year = 2026, .month = 1, .day = 2, .hour = 3, .minute = 4 } }, logins);
    try std.testing.expect(std.mem.indexOf(u8, account_writer.buffered(), "ChatGPT: signed in as person@example.com; access token expires 2026-01-02 03:04 UTC and renews by itself (remote acceptance not checked).\n") != null);
}
