const std = @import("std");
const TerminalEditor = @import("TerminalEditor.zig");
const TerminalText = @import("TerminalText.zig");
const AnswerRenderer = @import("AnswerRenderer.zig");
const SessionFrontend = @import("SessionFrontend.zig");
const TestObservation = @import("TestObservation.zig");
const cli_args = @import("cli_args.zig");
const json_ascii = @import("json_ascii.zig");
const client = @import("client.zig");
const protocol_reply = @import("protocol_reply.zig");
const codex_auth = @import("codex_auth.zig");
const codex_credentials = @import("codex_credentials.zig");
const model_adapter = @import("model_adapter.zig");
const new_session_selection = @import("new_session_selection.zig");
const platform = @import("platform.zig");
const preferences = @import("preferences.zig");
const model_capability = @import("model_capability.zig");
const provider_selection = @import("provider_selection.zig");
const protocol = @import("protocol.zig");
const retry_policy = @import("retry_policy.zig");
const server = @import("server.zig");
const signal_stack = @import("signal_stack.zig");
const product_defaults = @import("product_defaults.zig");

// Zig otherwise reserves a 256 KiB alternate signal stack as static TLS, and
// glibc zeroes every thread's TLS block, so each thread kept it resident.
// signal_stack.zig gives each Rui thread one in fresh pages instead.
pub const std_options: std.Options = .{
    .signal_stack_size = null,
    .log_scope_levels = &.{.{ .scope = .vaxis, .level = .info }},
};

extern "c" fn rui_launch_detached(executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize) c_int;
extern "c" fn rui_launch_detached_observed(executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize, startup_read: *c_int) c_int;

test "detached launcher reports exec failure before claiming Host readiness" {
    const argv = [_:null]?[*:0]const u8{"/rui-no-such-executable"};
    try std.testing.expectEqual(@as(c_int, 2), rui_launch_detached(argv[0].?, &argv, argv.len));
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        if (err == error.EmptyMessageInput) {
            @import("stderr.zig").print("Standard input was empty; provide Message text. Nothing was sent.\n", .{});
        } else TerminalText.diagnostic("error: {s} (exit status 1)\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    try signal_stack.attachMain();
    const allocator = std.heap.c_allocator;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try allocator.alloc([]const u8, raw_args.len);
    defer allocator.free(args);
    for (raw_args, args) |raw, *arg| arg.* = raw;
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        return std.Io.File.stdout().writeStreamingAll(init.io, usage_text);
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        return std.Io.File.stdout().writeStreamingAll(init.io, version_text);
    }
    if (args.len < 2 or std.mem.startsWith(u8, args[1], "--")) return newSession(init, args[1..]);
    if (cli_args.retired(args[1])) |replacement| {
        const replacement_resource = replacement[0..std.mem.indexOfScalar(u8, replacement, ' ').?];
        TerminalText.diagnostic("rui: `{s}` is now `rui {s}`; see rui {s} --help. Nothing was captured or sent. To start a Session, use rui session start with Message text on stdin.\n", .{ args[1], replacement, replacement_resource });
        return error.InvalidArguments;
    }
    const resource = std.meta.stringToEnum(cli_args.Resource, args[1]) orelse return newSession(init, args[1..]);
    var help_buffer: [4096]u8 = undefined;
    var help_writer = std.Io.File.stdout().writerStreaming(init.io, &help_buffer);
    if (args.len == 2 or (args.len == 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h")))) {
        try cli_args.resourceHelp(resource, &help_writer.interface);
        return help_writer.flush();
    }
    const command = cli_args.find(resource, args[2]) orelse {
        TerminalText.diagnostic("rui: unknown {s} operation; use rui {s} --help.\n", .{ @tagName(resource), @tagName(resource) });
        return error.InvalidArguments;
    };
    const definition = command.definition();
    // The arena outlives this invocation, so decoded identities do too.
    const parsed = definition.parse(args[3..], init.arena.allocator()) catch |err| {
        const problem = switch (err) {
            error.DuplicateArgument => "an option was repeated",
            error.UnknownArgument => "unknown option",
            error.MissingArgumentValue => "an option is missing its value",
            error.ConflictingArguments => "conflicting selectors or input sources",
            error.InvalidArguments => if (command == .session_send or command == .session_start)
                "Message text must come from stdin; positional text is not accepted"
            else
                "unexpected argument",
            error.InvalidInstructionsSource => "use --instructions - to read instructions from stdin",
            error.InvalidHexIdentity => "a hex selector is not even-length UTF-8 hex within its bound",
            error.OutOfMemory => "out of memory",
        };
        TerminalText.diagnostic("rui: {s} {s}: {s}. Nothing was captured or sent. Usage: rui {s} {s} --help\n", .{ @tagName(resource), definition.name, problem, @tagName(resource), definition.name });
        return err;
    };
    if (parsed.help) {
        try definition.help(&help_writer.interface);
        return help_writer.flush();
    }
    if (parsed.missing()) |group| {
        var missing_buffer: [256]u8 = undefined;
        var missing_writer: std.Io.Writer = .fixed(&missing_buffer);
        try definition.writeGroup(&missing_writer, group);
        TerminalText.diagnostic("rui: {s} {s}: missing {s}. Nothing was captured or sent. Usage: rui {s} {s} --help\n", .{ @tagName(resource), definition.name, missing_writer.buffered(), @tagName(resource), definition.name });
        return error.InvalidArguments;
    }
    dispatching = true;
    dispatch(init, command, &parsed, args) catch |err| {
        if (err == error.InvalidArguments) {
            TerminalText.diagnostic("rui: {s} {s}: invalid arguments. Usage: rui {s} {s} --help\n", .{ @tagName(resource), definition.name, @tagName(resource), definition.name });
            return err;
        }
        // Model rejection already names the ID, supported IDs and repair;
        // Pre-admission refusals have one diagnostic, with no recovery handle.
        // A saved rejection or conflict already named its replay.
        if (err == error.UnsupportedModel or err == error.EmptyMessageInput or err == error.MutationNotAccepted) return err;
        TerminalText.diagnostic("rui: {s} {s} failed; syntax and recovery: rui {s} {s} --help\n", .{ @tagName(resource), definition.name, @tagName(resource), definition.name });
        return err;
    };
    try postCommandHold(init);
}

fn dispatch(init: std.process.Init, command: cli_args.Command, parsed: *const cli_args.Parsed, args: []const []const u8) !void {
    if (parsed.get("session")) |id| {
        if (!protocol.validSessionId(id)) {
            TerminalText.diagnostic("rui: Session ID must be exactly six lowercase Crockford characters, for example k7m2qx. Nothing was captured or sent.\n", .{});
            return error.InvalidSession;
        }
    }
    if (command == .session_resume) if (parsed.positional) |id| {
        if (!protocol.validSessionId(id)) return error.InvalidSession;
    };
    switch (command) {
        .session_start => try configure(init, .{ .io = init.io }, parsed, null, true),
        .session_configure => try configure(init, .{ .io = init.io }, parsed, null, false),
        .session_send => try message(init, parsed, null),
        .session_inspect => try inspect(init, parsed),
        .session_list => try sessions(init, parsed),
        .session_stop => try stopSession(init, parsed),
        .session_interrupt_model => try interruptModel(init, parsed),
        .session_read_conversation => try readConversation(init, parsed),
        .session_resume => try resumeSession(init, parsed),
        .request_inspect => try observe(init, parsed),
        .request_recover => try recover(init, parsed),
        .request_read_result => try readResult(init, parsed),
        .request_list => try requests(init),
        .action_inspect => try inspectAction(init, .{ .io = init.io }, parsed.get("store"), parsed.get("session").?, (try parsed.number(u64, "action")).?, false),
        .action_allow => try decideAction(init, parsed, .allow_once),
        .action_deny => try decideAction(init, parsed, .deny),
        .action_read_call_id => try readActionContent(init, parsed, .call_id),
        .action_read_arguments => try readActionContent(init, parsed, .arguments),
        .host_start, .host_stop, .host_status => try host(init, command, parsed),
        .host_serve => {
            try @import("os/process.zig").applyHostMallocDefaults(init, args);
            try serve(init, parsed);
        },
        // Inspection has its own read-only operation; configure's grammar
        // requires an edit.
        .defaults_inspect, .defaults_configure => try setup(init, parsed, false),
        .auth_login => try login(init, &.{parsed.positional.?}, false, codex_auth.login),
    }
}

const post_command_ready_fd_environment = "RUI_TEST_POST_COMMAND_READY_FD";
const post_command_release_fd_environment = "RUI_TEST_POST_COMMAND_RELEASE_FD";

fn postCommandHold(init: std.process.Init) !void {
    const ready_text = init.environ_map.get(post_command_ready_fd_environment);
    const release_text = init.environ_map.get(post_command_release_fd_environment);
    if (ready_text == null and release_text == null) return;
    if (ready_text == null or release_text == null) return error.IncompletePostCommandHold;
    const ready = try std.fmt.parseInt(std.posix.fd_t, ready_text.?, 10);
    const release = try std.fmt.parseInt(std.posix.fd_t, release_text.?, 10);
    try postCommandHoldDescriptors(ready, release);
}

fn postCommandHoldDescriptors(ready: std.posix.fd_t, release: std.posix.fd_t) !void {
    defer closeDescriptor(ready);
    defer closeDescriptor(release);
    const signal = [_]u8{1};
    if (std.c.write(ready, &signal, signal.len) != 1) return error.PostCommandHoldSignalFailed;
    var acknowledgment: [1]u8 = undefined;
    if (std.c.read(release, &acknowledgment, acknowledgment.len) != 1) return error.PostCommandHoldClosed;
}

fn credentialPath(init: std.process.Init, buffer: []u8, create: bool) ![]const u8 {
    if (init.environ_map.get("RUI_CODEX_CREDENTIAL_FILE")) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidCredentialPath;
        return path;
    }
    const home = init.environ_map.get("HOME") orelse return homeRequired("the Codex credential is HOME/.config/rui/codex.json unless RUI_CODEX_CREDENTIAL_FILE names it");
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    if (create) {
        var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory = try std.fmt.bufPrint(&directory_buffer, "{s}/.config/rui", .{home});
        var opened = try std.Io.Dir.cwd().createDirPathOpen(init.io, directory, .{
            .permissions = .fromMode(0o700),
        });
        opened.close(init.io);
    }
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/codex.json", .{home});
}

fn setup(init: std.process.Init, parsed: *const cli_args.Parsed, interactive: bool) !void {
    if (parsed.get("model")) |model| try requireSupportedModel(model);
    const home = init.environ_map.get("HOME") orelse {
        TerminalText.diagnostic("rui: setup needs an absolute HOME; no preferences saved.\n", .{});
        return error.HomeUnavailable;
    };
    var edit: preferences.Edit = .{};
    if (parsed.get("store")) |store| edit.store = .{ .set = store };
    if (parsed.get("provider")) |name| edit.provider = .{ .set = name };
    if (parsed.get("model")) |model| edit.model = .{ .set = model };
    if (parsed.has("clear-model")) edit.model = .clear;
    var credential_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const now = codex_auth.nowSeconds(init.io);
    const readiness: provider_selection.Readiness = blk: {
        const path = credentialPath(init, &credential_buffer, false) catch break :blk .credential_error;
        break :blk if (codex_auth.localStatus(path, now)) |state| switch (state) {
            .missing => .missing,
            .configured => .configured,
            .renewal_due => .renewal_due,
            .refresh_required => .refresh_required,
        } else |_| .credential_error;
    };
    const changed = edit.store != .keep or edit.provider != .keep or edit.model != .keep;
    const values = (if (changed) preferences.update(home, edit, readiness) else preferences.load(home)) catch |err| {
        if (err == error.PreferenceDirectorySyncFailed) {
            TerminalText.diagnostic("rui: setup save durability unconfirmed; inspect HOME/.config/rui/preferences before another update. No Session changed.\n", .{});
        } else if (err == error.UnsupportedPreferenceProvider) {
            TerminalText.diagnostic("rui: setup supports only --provider codex; no preferences saved.\n", .{});
        } else if (err == error.PreferenceProviderRequired) {
            TerminalText.diagnostic("rui: setup needs --provider codex with --model; no preferences saved.\n", .{});
        } else if (err == error.UnsupportedPreferenceModel) {
            TerminalText.diagnostic("rui: setup model is unsupported; no preferences saved.\n" ++ model_capability.model_help, .{});
        } else if (err == error.InvalidPreferenceModel) {
            TerminalText.diagnostic("rui: setup model must be 1–256 printable non-space ASCII bytes; no preferences saved.\n", .{});
        } else if (err == error.InvalidPreferenceStore or err == error.FileNotFound) {
            TerminalText.diagnostic("rui: setup Store must be an existing private, canonicalizable absolute directory; no alternate Store selected.\n", .{});
        } else TerminalText.diagnostic("rui: setup {s}: {s}; inspect HOME/.config/rui/preferences and its private directory before retrying. No alternate Store selected.\n", .{ if (changed) "save failed" else "read failed", @errorName(err) });
        return err;
    };
    var fallback_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const prospective_store: ?[]const u8 = if (values.store.len != 0) values.store.slice() else preferences.defaultStore(home, &fallback_buffer) catch null;
    const available_store: ?platform.Paths = if (prospective_store) |path| platform.resolveClientPaths(init.io, path) catch null else null;
    // Preferences live in HOME, so a saved Store redirects every Workspace.
    if (!interactive and edit.store != .keep) notice: {
        var bytes: [4 * std.Io.Dir.max_path_bytes + 256]u8 = undefined;
        var notice = std.Io.Writer.fixed(&bytes);
        notice.writeAll("rui: saved ") catch break :notice;
        TerminalText.writeShellWord(&notice, values.store.slice()) catch break :notice;
        notice.writeAll(" as the global default Store; commands without --store now use it from any directory, and saved requests keep their recorded Store.\n") catch break :notice;
        TerminalText.diagnostic("{s}", .{notice.buffered()});
    }
    if (!interactive) return writeDefaultsJson(init.io, .{
        .changed = changed,
        .store = prospective_store,
        .saved_store = values.store.len != 0,
        .available_store = if (available_store) |*paths| paths.store.slice() else null,
        .provider = if (values.provider.len != 0) values.provider.slice() else null,
        .model = if (values.model.len != 0) values.model.slice() else null,
        .readiness = readiness,
    });
    // Preferences are local hints, not Session settings or Host facts.
    try std.Io.File.stdout().writeStreamingAll(init.io, if (changed) "Saved defaults for future Sessions. Active Session unchanged.\n" else "Defaults (read only):\n");
    try std.Io.File.stdout().writeStreamingAll(init.io, "Store: ");
    try writeSafeText(init.io, prospective_store orelse "unavailable");
    try std.Io.File.stdout().writeStreamingAll(init.io, if (values.store.len != 0) " (saved)\n" else " (HOME fallback)\n");
    if (available_store == null) try std.Io.File.stdout().writeStreamingAll(init.io, "Store unavailable: destination cannot be selected; no alternate Store selected.\n");
    try writeSafeField(init.io, "Provider: ", if (values.provider.len != 0) values.provider.slice() else "not selected");
    try writeSafeField(init.io, "Model: ", if (values.model.len != 0) values.model.slice() else "not selected");
    var output: [std.Io.Dir.max_path_bytes + 512]u8 = undefined;
    const codex = model_capability.supportedCapability(readiness);
    const local_status = switch (readiness) {
        .configured => "Codex credential: configured locally (remote acceptance not checked).\n",
        .renewal_due => "Codex credential: usable locally; renewal due at dispatch (remote acceptance not checked).\n",
        .missing => "Codex credential: missing.\n",
        .refresh_required => "Codex credential: refresh required; a pending refresh may require login.\n",
        .credential_error => "Codex credential: error reading private Rui credential; inspect it before use.\n",
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, local_status);
    const selection: ?provider_selection.Selection = provider_selection.resolve(&.{codex}, null, null, if (values.provider.len != 0) values.provider.slice() else null, if (values.model.len != 0) values.model.slice() else null) catch |err| blk: {
        const advice: []const u8 = switch (err) {
            error.UnsupportedSelectionProvider => "Next Session: saved provider is unsupported; no fallback. Repair with `rui defaults configure --provider codex --model " ++ product_defaults.recommended_model ++ "`.\n",
            error.UnsupportedSelectionModel => "Next Session: saved model is unsupported; no fallback. Repair with `rui defaults configure --provider codex --model " ++ product_defaults.recommended_model ++ "`.\n",
        };
        try std.Io.File.stdout().writeStreamingAll(init.io, advice);
        break :blk null;
    };
    if (selection) |choice| switch (choice) {
        .chooser => try std.Io.File.stdout().writeStreamingAll(init.io, "Next Session: choose a supported provider; Codex login: `rui auth login codex`.\n"),
        .selected => |selected| {
            const note: []const u8 = switch (selected.readiness) {
                .configured => "local credential configured; remote acceptance not checked",
                .renewal_due => "local credential usable; renewal due at dispatch; remote acceptance not checked",
                .missing => "credential missing; run `rui auth login codex`. No fallback",
                .refresh_required => "credential refresh required; login may be required. No fallback",
                .credential_error => "credential error; inspect private Rui credential or log in. No fallback",
            };
            const line = try std.fmt.bufPrint(&output, "Next Session: {s} / {s} ({s}).\n", .{ selected.provider, selected.model, note });
            try std.Io.File.stdout().writeStreamingAll(init.io, line);
        },
    };
    // Host capabilities are startup facts, not credential or Session state.
    const host_details: []const u8 = if (available_store) |paths| switch (client.hostStatus(init.io, paths.store.slice())) {
        .ready => |current| if (current.capabilities.managed_authentication and current.capabilities.model)
            "Host: managed Codex enabled (credentials checked locally, not by status).\n"
        else
            "Host: ready without managed Codex; use `rui host serve --codex` for new managed work.\n",
        .unavailable => "Host: unavailable; setup does not start it.\n",
        .owned_unavailable => "Host: owned but unavailable; inspect before submitting work.\n",
        .incompatible => "Host: incompatible; inspect before submitting work.\n",
        .access_failure => "Host: access failure; inspect Store permissions.\n",
    } else "Host: unavailable; selected Store unavailable.\n";
    try std.Io.File.stdout().writeStreamingAll(init.io, host_details);
}

const DefaultsFacts = struct {
    changed: bool,
    store: ?[]const u8,
    saved_store: bool,
    available_store: ?[]const u8,
    provider: ?[]const u8,
    model: ?[]const u8,
    readiness: provider_selection.Readiness,
};

// One complete JSON value: saved preferences, the prospective new-Session
// binding and separately observed Host capabilities. No field is a Session fact.
fn writeDefaultsJson(io: std.Io, facts: DefaultsFacts) !void {
    var output: JsonOutput = undefined;
    const writer = output.init(io, .stdout);
    try writer.print("{{\"version\":\"{s}\",\"type\":\"defaults\",\"changed\":{},\"store\":", .{ protocol.wire_version, facts.changed });
    try std.json.Stringify.value(facts.store, .{}, writer);
    try writer.print(",\"store_source\":\"{s}\",\"store_available\":{},\"provider\":", .{ if (facts.saved_store) "saved" else "home", facts.available_store != null });
    try std.json.Stringify.value(facts.provider, .{}, writer);
    try writer.writeAll(",\"model\":");
    try std.json.Stringify.value(facts.model, .{}, writer);
    try writer.print(",\"local_credential\":\"{s}\",\"next_session\":", .{@tagName(facts.readiness)});
    const codex = model_capability.supportedCapability(facts.readiness);
    if (provider_selection.resolve(&.{codex}, null, null, facts.provider, facts.model)) |choice| switch (choice) {
        .chooser => try writer.writeAll("{\"status\":\"choose_provider\"}"),
        .selected => |selected| {
            try writer.print("{{\"status\":\"selected\",\"provider\":\"{s}\",\"model\":", .{selected.provider});
            try std.json.Stringify.value(selected.model, .{}, writer);
            try writer.print(",\"local_credential\":\"{s}\"}}", .{@tagName(selected.readiness)});
        },
    } else |err| try writer.print("{{\"status\":\"{s}\"}}", .{switch (err) {
        error.UnsupportedSelectionProvider => "unsupported_provider",
        error.UnsupportedSelectionModel => "unsupported_model",
    }});
    try writer.writeAll(",\"host\":");
    if (facts.available_store) |store| switch (client.hostStatus(io, store)) {
        .ready => |ready| {
            try writer.writeAll("{\"status\":\"ready\",\"capabilities\":");
            try std.json.Stringify.value(ready.capabilities, .{}, writer);
            try writer.writeByte('}');
        },
        else => |status| try writer.print("{{\"status\":\"{s}\"}}", .{@tagName(status)}),
    } else try writer.writeAll("{\"status\":\"store_unavailable\"}");
    try writer.writeAll("}\n");
    try output.finish();
}

// The caller owns buffer. Explicit destinations never consult preferences;
// omitted destinations use the same saved/HOME rule in every CLI mode.
// Missing HOME is an environment repair, not a Store or request outcome:
// report what needed it before any capture or transmission.
fn homeRequired(comptime need: []const u8) error{HomeUnavailable} {
    TerminalText.diagnostic("rui: HOME is not set; " ++ need ++ ". Set HOME to an absolute directory and retry. Nothing was captured or sent.\n", .{});
    return error.HomeUnavailable;
}

fn selectedStore(init: std.process.Init, explicit: ?[]const u8, buffer: []u8) ![]const u8 {
    if (explicit) |path| {
        if (path.len == 0) return error.InvalidStore;
        return path;
    }
    if (init.environ_map.get("RUI_STORE")) |path| {
        const address = init.environ_map.get("RUI_ADDRESS") orelse return error.InvalidRuiAddress;
        const handle = init.environ_map.get("RUI_SENDER_HANDLE") orelse return error.InvalidRuiAddress;
        if (path.len == 0 or handle.len == 0 or !protocol.validSessionId(address)) return error.InvalidRuiAddress;
        _ = try platform.resolveClientPaths(init.io, path);
        return path;
    }
    if (init.environ_map.get("RUI_ADDRESS") != null or init.environ_map.get("RUI_SENDER_HANDLE") != null) return error.InvalidRuiAddress;
    const home = init.environ_map.get("HOME") orelse return homeRequired("without --store the Store comes from saved defaults or HOME/.local/share/rui/store");
    const defaults = preferences.load(home) catch |err| {
        TerminalText.diagnostic("rui: cannot read private setup defaults ({s}); use rui defaults inspect to inspect them. No Store selected.\n", .{@errorName(err)});
        return err;
    };
    if (defaults.store.len != 0) {
        _ = try platform.resolveClientPaths(init.io, defaults.store.slice());
        @memcpy(buffer[0..defaults.store.len], defaults.store.slice());
        return buffer[0..defaults.store.len];
    }
    return preferences.defaultStore(home, buffer);
}

fn host(init: std.process.Init, command: cli_args.Command, parsed: *const cli_args.Parsed) !void {
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, parsed.get("store"), &fallback);
    if (command == .host_start) return startHost(init, selected, false, try parsed.number(usize, "active-capacity"));
    if (command == .host_stop) return stopHost(init.io, selected, if (parsed.get("instance")) |instance| try protocol.parseInstanceId(instance) else null);
    const status = client.hostStatus(init.io, selected);
    try writeHostStatus(init.io, status);
    switch (status) {
        .incompatible => return error.IncompatibleHost,
        .access_failure => return error.StoreAccessFailed,
        else => {},
    }
}

fn writeHostStatus(io: std.Io, status: protocol_reply.HostStatus) !void {
    var output: JsonOutput = undefined;
    const writer = output.init(io, .stdout);
    try writer.print("{{\"version\":\"{s}\",\"type\":\"host_status\",\"status\":\"{s}\"", .{ protocol.wire_version, @tagName(status) });
    switch (status) {
        .ready => |ready| {
            try writer.writeAll(",\"store\":");
            try std.json.Stringify.value(ready.store.slice(), .{}, writer);
            const instance = std.fmt.bytesToHex(ready.instance, .lower);
            try writer.print(",\"instance\":\"{s}\",\"active_capacity\":\"{d}\",\"intake_capacity\":\"{d}\",\"descriptor_limit\":", .{ &instance, ready.active_capacity, ready.intake_capacity });
            if (ready.descriptor_limit) |limit| try writer.print("\"{d}\"", .{limit}) else try writer.writeAll("null");
            try writer.writeAll(",\"capabilities\":");
            try std.json.Stringify.value(ready.capabilities, .{}, writer);
            var location: [protocol.max_store_bytes + "/diagnostics".len]u8 = undefined;
            try writer.writeAll(",\"diagnostics\":");
            try std.json.Stringify.value(try std.fmt.bufPrint(&location, "{s}/diagnostics", .{ready.store.slice()}), .{}, writer);
        },
        else => {},
    }
    try writer.writeAll("}\n");
    try output.finish();
}

fn stopHost(io: std.Io, selected: []const u8, explicit_instance: ?protocol.InstanceId) !void {
    const target = explicit_instance orelse switch (client.hostStatus(io, selected)) {
        .ready => |ready| ready.instance,
        .unavailable, .owned_unavailable => {
            TerminalText.diagnostic("rui: no ready Host identity to stop. Ownership or completion is unconfirmed; inspect rui host status.\n", .{});
            return error.HostStopUnconfirmed;
        },
        .incompatible => return error.IncompatibleHost,
        .access_failure => return error.StoreAccessFailed,
    };
    const paths = try platform.resolveClientPaths(io, selected);
    const hex = std.fmt.bytesToHex(target, .lower);
    var notice_bytes: [4 * protocol.max_store_bytes + 256]u8 = undefined;
    var notice = std.Io.Writer.fixed(&notice_bytes);
    try notice.writeAll("rui: stop affects all work in this Store. Retry only this exact target: rui host stop --store ");
    try TerminalText.writeShellWord(&notice, paths.store.slice());
    try notice.print(" --instance {s}\n", .{&hex});
    try std.Io.File.stderr().writeStreamingAll(io, notice.buffered());
    var reply: client.ReplyBuffer = .{};
    const outcome = client.stopHost(io, .{ .store = paths.store.slice(), .instance = target }, &reply) catch |err| {
        TerminalText.diagnostic("rui: stop reply unconfirmed ({s}); inspect this Store and retry only the same --instance target. Do not target a replacement implicitly.\n", .{@errorName(err)});
        return err;
    };
    switch (outcome) {
        .acknowledged => {
            var output: JsonOutput = undefined;
            const writer = output.init(io, .stdout);
            try writer.print("{{\"version\":\"{s}\",\"type\":\"host_stop\",\"status\":\"acknowledged\",\"store\":", .{protocol.wire_version});
            try std.json.Stringify.value(paths.store.slice(), .{}, writer);
            try writer.print(",\"instance\":\"{s}\",\"retirement\":\"unconfirmed\"}}\n", .{&hex});
            try output.finish();
        },
        .instance_changed => {
            TerminalText.diagnostic("rui: Host instance changed; replacement was not stopped. Inspect rui host status before any new intent.\n", .{});
            return error.HostInstanceChanged;
        },
        .unavailable => {
            TerminalText.diagnostic("rui: Host stop unavailable; shutdown/completion unconfirmed. Inspect rui host status; do not switch the retry target.\n", .{});
            return error.HostStopUnconfirmed;
        },
    }
}

/// Null capacity leaves a new Host on product_defaults.active_capacity.
fn startHost(init: std.process.Init, selected: []const u8, quiet: bool, capacity: ?usize) !void {
    const io = init.io;
    switch (client.hostStatus(io, selected)) {
        .ready => |ready| return reportStartedHost(io, ready, quiet, capacity),
        .incompatible => return error.IncompatibleHost,
        .access_failure => return error.StoreAccessFailed,
        .unavailable, .owned_unavailable => {},
    }
    // Only the serving Host obtains the exclusive lease; this creates the
    // candidate Store path without claiming an owner or touching SQLite.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, selected, .{ .permissions = .fromMode(0o700) });
    dir.close(io);
    const paths = try platform.resolveClientPaths(io, selected);
    var executable_buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const length = try std.process.executablePath(io, &executable_buffer);
    if (length == executable_buffer.len) return error.ExecutablePathTooLong;
    executable_buffer[length] = 0;
    var store_buffer: [protocol.max_store_bytes + 1]u8 = undefined;
    const store_z = try std.fmt.bufPrintSentinel(&store_buffer, "{s}", .{paths.store.slice()}, 0);
    // Application policy lives here. The synchronous native launcher borrows
    // these terminated strings and pointer framing through exec/error handoff;
    // all storage is prepared before any detach fork. Without a requested
    // capacity the flag is omitted, so product_defaults.active_capacity stays
    // the only default.
    var capacity_buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)}) + 1]u8 = undefined;
    var argv = [_:null]?[*:0]const u8{
        @ptrCast(&executable_buffer), "host", "serve", "--store", store_z.ptr, "--codex", null, null,
    };
    var argc: usize = argv.len - 2;
    if (capacity) |value| {
        argv[argc] = "--active-capacity";
        argv[argc + 1] = (try std.fmt.bufPrintSentinel(&capacity_buffer, "{d}", .{value}, 0)).ptr;
        argc += 2;
    }
    var startup_read: c_int = -1;
    const launched = rui_launch_detached_observed(argv[0].?, &argv, argc, &startup_read);
    defer if (startup_read >= 0) {
        _ = std.c.close(startup_read);
    };
    if (launched != 0) {
        notice: {
            var bytes: [4 * protocol.max_store_bytes + 256]u8 = undefined;
            var notice = std.Io.Writer.fixed(&bytes);
            notice.print("\nrui: detached Host launch reported OS error {d}. Execution and readiness are unconfirmed.\nCheck this Store: rui host status --store ", .{launched}) catch break :notice;
            TerminalText.writeShellWord(&notice, paths.store.slice()) catch break :notice;
            notice.writeByte('\n') catch break :notice;
            _ = @import("stderr.zig").write(notice.buffered());
        }
        return error.HostLaunchFailed;
    }
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_s;
    var startup_bytes: [8192]u8 = undefined;
    var startup_length: usize = 0;
    while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < until) {
        const count = std.c.read(startup_read, startup_bytes[startup_length..].ptr, startup_bytes.len - startup_length);
        if (count > 0) startup_length += @intCast(count);
        const startup = startup_bytes[0..startup_length];
        if ((std.mem.indexOf(u8, startup, "(exit status 1)\n") != null or count == 0 or startup_length == startup_bytes.len) and
            std.mem.indexOf(u8, startup, "error: StoreAlreadyOwned (exit status 1)\n") == null)
        {
            // A competing candidate may have lost the lease to a ready Host.
            if (client.hostStatusUntil(io, paths.store.slice(), until) != .ready) {
                var header_bytes: [4 * protocol.max_store_bytes + 256]u8 = undefined;
                var header = std.Io.Writer.fixed(&header_bytes);
                try header.writeAll("\nrui: detached Host startup failed for Store ");
                var path_text: TerminalText = .{ .mode = .line };
                try path_text.feed(&header, paths.store.slice());
                try path_text.finish(&header);
                try header.writeAll(":\n");
                _ = @import("stderr.zig").write(header.buffered());
                _ = @import("stderr.zig").write(startup);
                if (startup_length == 0) TerminalText.diagnostic("Child closed its startup channel before readiness; exit status unavailable.\n", .{});
                if (startup_length == startup_bytes.len) {
                    TerminalText.diagnostic("Startup output exceeded 8 KiB; readiness and exit status remain unconfirmed.\n", .{});
                    return error.HostReadinessUnconfirmed;
                }
                return error.HostStartupFailed;
            }
        }
        switch (client.hostStatusUntil(io, paths.store.slice(), until)) {
            .ready => |ready| {
                // Startup notices precede readiness. The first read may have
                // raced their write; collect once more after readiness proves
                // that startup passed that point, without waiting for stderr.
                const final_count = std.c.read(startup_read, startup_bytes[startup_length..].ptr, startup_bytes.len - startup_length);
                if (final_count > 0) startup_length += @intCast(final_count);
                const notices = startup_bytes[0..startup_length];
                // A competing launcher lost to this ready owner; its expected
                // lease refusal is not a warning about the running Host.
                if (startup_length != 0 and std.mem.indexOf(u8, notices, "error: StoreAlreadyOwned (exit status 1)\n") == null)
                    _ = @import("stderr.zig").write(notices);
                return reportStartedHost(io, ready, quiet, capacity);
            },
            .incompatible => return error.IncompatibleHost,
            .access_failure => return error.StoreAccessFailed,
            .unavailable, .owned_unavailable => {},
        }
        const remaining = until - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (remaining > 0) try std.Io.sleep(io, .fromNanoseconds(@intCast(@min(remaining, 100 * std.time.ns_per_ms))), .awake);
    }
    if (startup_length != 0) _ = @import("stderr.zig").write(startup_bytes[0..startup_length]);
    TerminalText.diagnostic("rui: Host readiness unconfirmed after 10 seconds. Inspect rui host status and the selected Store's diagnostics/ startup records if present; do not kill or reclaim an uncertain owner.\n", .{});
    return error.HostReadinessUnconfirmed;
}

/// A ready Host keeps the capacity it started with, so a different request
/// is reported rather than dropped; a competing launcher may have won.
fn reportStartedHost(io: std.Io, ready: @FieldType(protocol_reply.HostStatus, "ready"), quiet: bool, capacity: ?usize) !void {
    if (capacity) |requested| if (requested != ready.active_capacity) notice: {
        var bytes: [4 * protocol.max_store_bytes + 512]u8 = undefined;
        var notice = std.Io.Writer.fixed(&bytes);
        notice.print("rui: the running Host keeps active capacity {d}; --active-capacity {d} applies only to a new Host. Changing it means stopping this Host and all its work: rui host stop --store ", .{ ready.active_capacity, requested }) catch break :notice;
        TerminalText.writeShellWord(&notice, ready.store.slice()) catch break :notice;
        notice.writeByte('\n') catch break :notice;
        TerminalText.diagnostic("{s}", .{notice.buffered()});
    };
    if (!quiet) try writeHostStatus(io, .{ .ready = ready });
}

fn login(init: std.process.Init, args: []const []const u8, interactive: bool, comptime exchange: anytype) !void {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "codex")) return usage();
    // Guided login already owns SIGINT from the choice through publication.
    var interrupt = if (interactive) null else LoginInterrupt.init();
    defer if (interrupt) |*scope| scope.deinit();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try credentialPath(init, &path_buffer, true);
    if (loginInterrupted()) return error.LoginInterrupted;
    // Preflight needs only a safe snapshot, not the refresh owner's lock or
    // generation. Installation rereads under its exclusive lock after winning.
    {
        var snapshot: codex_credentials.Record = undefined;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&snapshot));
        _ = try codex_credentials.readSnapshotInto(path, &snapshot);
    }
    if (loginInterrupted()) return error.LoginInterrupted;
    var tokens = if (interactive)
        try exchange(init.io, struct {
            fn display(code: []const u8) !void {
                const output = std.Io.File.stdout();
                const io = std.Io.Threaded.global_single_threaded.io();
                try output.writeStreamingAll(io, "Open https://auth.openai.com/codex/device and enter code: ");
                try output.writeStreamingAll(io, code);
                try output.writeStreamingAll(io, "\n" ++ device_login_guidance);
            }
        }.display, loginInterrupted)
    else
        try exchange(init.io, struct {
            fn display(code: []const u8) !void {
                std.debug.print("Open https://auth.openai.com/codex/device and enter code: {s}\n" ++ device_login_guidance, .{code});
            }
        }.display, loginInterrupted);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&tokens));
    var record: codex_credentials.Record = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try codex_auth.loginRecord(&tokens, codex_auth.nowSeconds(init.io), &record);
    // Publication and SIGINT claim the same gate. Once publication wins,
    // cancellation cannot be reported as if installation were rolled back.
    if (login_state.cmpxchgStrong(.cancellable, .publishing, .acq_rel, .acquire) != null) return error.LoginInterrupted;
    try codex_credentials.install(path, &record, null);
    const home = init.environ_map.get("HOME") orelse "";
    // The preference attempt must run even if the terminal receipt cannot be
    // written. Installation and future defaults have independent outcomes.
    const default_outcome = preferences.fillProviderAfterLogin(home);
    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Codex credential installed. Remote model acceptance is not established. Current Session unchanged.\n");
    const added = default_outcome catch |err| {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Credential installed, but future defaults were not saved or durability is uncertain (");
        try std.Io.File.stdout().writeStreamingAll(init.io, @errorName(err));
        return std.Io.File.stdout().writeStreamingAll(init.io, "). Use rui defaults inspect; active Session unchanged.\n");
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, if (added)
        "Rui: No provider default existed; Codex selected for future Sessions; model recommendation remains unpinned.\n"
    else
        "Rui: Existing provider default unchanged.\n");
}

// OpenAI shows a disabled device-code setting only after sign-in and MFA, so
// say up front where to enable it (https://learn.chatgpt.com/docs/auth).
const device_login_guidance =
    \\The code signs Rui in to your ChatGPT account. Never share it.
    \\If the page says device code login is off, press Ctrl+C here. Turn on device
    \\code authorization for Codex in your ChatGPT security settings, or ask your
    \\workspace admin to allow it. Then run rui auth login codex again.
    \\
;

const LoginState = enum(u8) { cancellable, cancelled, publishing };
var login_state = std.atomic.Value(LoginState).init(.cancellable);

const LoginInterrupt = struct {
    previous: std.posix.Sigaction,

    fn init() LoginInterrupt {
        var blocked = std.posix.sigemptyset();
        std.posix.sigaddset(&blocked, .INT);
        var previous_mask: std.posix.sigset_t = undefined;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, &previous_mask);
        defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
        login_state.store(.cancellable, .release);
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onLoginInterrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
        var scope: LoginInterrupt = undefined;
        std.posix.sigaction(.INT, &action, &scope.previous);
        return scope;
    }

    fn deinit(scope: *LoginInterrupt) void {
        std.posix.sigaction(.INT, &scope.previous, null);
    }
};

fn onLoginInterrupt(_: std.posix.SIG) callconv(.c) void {
    _ = login_state.cmpxchgStrong(.cancellable, .cancelled, .acq_rel, .acquire);
}

fn loginInterrupted() bool {
    return login_state.load(.acquire) == .cancelled;
}

test "login owner preserves interruption, publication and independent defaults" {
    const Case = enum { before_fresh, before_existing, before_guided, after_fresh, after_existing, preference_failure, credential_failure, missing_home, receipt_failure };
    const Fixture = struct {
        var before: bool = false;
        var lock_path: []const u8 = undefined;
        var signal_thread: ?std.Thread = null;
        var signal_failure: ?anyerror = null;

        const Custodian = struct {
            done: std.atomic.Value(bool) = .init(false),
            completed_while_held: bool = false,

            fn hold(self: *@This(), held: std.Io.File) void {
                const io = std.Io.Threaded.global_single_threaded.io();
                defer held.close(io);
                const start = std.Io.Clock.Timestamp.now(io, .awake);
                while (!self.done.load(.acquire)) {
                    if (start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds >= 2 * std.time.ns_per_s) return;
                    std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
                }
                self.completed_while_held = true;
            }
        };

        fn exchange(io: std.Io, display: anytype, cancelled: *const fn () bool) !codex_auth.Tokens {
            _ = display;
            var tokens: codex_auth.Tokens = .{};
            errdefer std.crypto.secureZero(u8, std.mem.asBytes(&tokens));
            try tokens.id_token.set(codex_auth.fixture_id_token);
            try tokens.access_token.set(codex_auth.fixture_access_token);
            try tokens.refresh_token.set("new-synthetic-refresh");
            if (before) {
                try std.posix.raise(.INT);
                try std.testing.expect(cancelled());
                // Return even after SIGINT: the production publication gate,
                // not the synthetic exchange, must suppress installation.
                return tokens;
            }
            const held = try std.Io.Dir.cwd().openFile(io, lock_path, .{ .mode = .read_write, .lock = .exclusive });
            errdefer held.close(io);
            signal_thread = try std.Thread.spawn(.{}, struct {
                fn send(lock: std.Io.File) void {
                    const clock = std.Io.Threaded.global_single_threaded.io();
                    defer lock.close(clock);
                    const start = std.Io.Clock.Timestamp.now(clock, .awake);
                    while (login_state.load(.acquire) != .publishing) {
                        if (start.durationTo(std.Io.Clock.Timestamp.now(clock, .awake)).raw.nanoseconds >= 2 * std.time.ns_per_s) {
                            signal_failure = error.PublicationNotReached;
                            return;
                        }
                        std.Io.sleep(clock, .fromMilliseconds(1), .awake) catch {};
                    }
                    std.posix.raise(.INT) catch |err| {
                        signal_failure = err;
                    };
                }
            }.send, .{held});
            return tokens;
        }
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    // IGN keeps a missing-scope negative control finite rather than killing
    // the test runner. Real login must replace it and restore it on all exits.
    const ignored: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &ignored, &previous);
    defer std.posix.sigaction(.INT, &previous, null);
    var signal_set = std.posix.sigemptyset();
    std.posix.sigaddset(&signal_set, .INT);
    var previous_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &signal_set, &previous_mask);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
    defer login_state.store(.cancellable, .release);

    for (std.meta.tags(Case)) |case| {
        const before = case == .before_fresh or case == .before_existing or case == .before_guided;
        const existing = case == .before_existing or case == .after_existing;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
        var directory = try tmp.dir.createDirPathOpen(io, ".config/rui", .{ .permissions = .fromMode(0o700) });
        defer directory.close(io);
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/.config/rui/codex.json", .{home});
        var lock_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        Fixture.lock_path = try std.fmt.bufPrint(&lock_buffer, "{s}/.config/rui/.codex.json.lock", .{home});
        Fixture.before = before;
        Fixture.signal_thread = null;
        Fixture.signal_failure = null;
        // A previous completed/cancelled exchange cannot leak into a new one.
        login_state.store(.cancelled, .release);
        const lock = try directory.createFile(io, ".codex.json.lock", .{ .read = true, .permissions = .fromMode(0o600) });
        lock.close(io);
        const prior_defaults = "version=1\nstore=\nprovider=legacy\nmodel=legacy-model\n";
        var prior_bytes: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &prior_bytes);
        var prior_auth: []const u8 = &.{};
        if (existing) {
            var record: codex_credentials.Record = .{ .generation = 0, .account_id = .{}, .id_token = .{}, .access_token = .{}, .refresh_token = .{}, .expires_at = 0, .refreshed_at = 100 };
            defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
            try record.account_id.set("prior-account");
            try record.id_token.set("prior-id");
            try record.access_token.set("prior-access");
            try record.refresh_token.set("prior-refresh");
            try codex_credentials.install(path, &record, null);
            prior_auth = try directory.readFile(io, "codex.json", &prior_bytes);
            const file = try directory.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
            defer file.close(io);
            try file.writeStreamingAll(io, prior_defaults);
        }
        if (case == .preference_failure) {
            const file = try directory.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
            defer file.close(io);
            try file.writeStreamingAll(io, "version=9\n");
        }
        if (case == .credential_failure) try directory.createDir(io, ".codex.json.tmp", .fromMode(0o700));
        var custodian: Fixture.Custodian = .{};
        var custodian_thread: ?std.Thread = null;
        if (case == .before_existing) {
            const held = try directory.openFile(io, ".codex.json.lock", .{ .mode = .read_write, .lock = .exclusive });
            custodian_thread = std.Thread.spawn(.{}, Fixture.Custodian.hold, .{ &custodian, held }) catch |err| {
                held.close(io);
                return err;
            };
        }
        defer if (custodian_thread) |thread| {
            custodian.done.store(true, .release);
            thread.join();
        };
        var environment = std.process.Environ.Map.init(std.testing.allocator);
        defer environment.deinit();
        if (case != .missing_home) try environment.put("HOME", home);
        try environment.put("RUI_CODEX_CREDENTIAL_FILE", path);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const argv = [_][*:0]const u8{ "rui", "login", "codex" };
        const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &argv }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = &environment, .preopens = .empty };
        var outcome: anyerror!void = undefined;
        {
            // stdout carries the test runner protocol, so capture receipts.
            const saved_stdout = std.c.dup(1);
            if (saved_stdout < 0) return error.TestDupFailed;
            defer _ = std.c.close(saved_stdout);
            const receipt = try directory.createFile(io, "receipt", .{});
            defer receipt.close(io);
            if (std.c.dup2(receipt.handle, 1) < 0) return error.TestRedirectFailed;
            defer std.debug.assert(std.c.dup2(saved_stdout, 1) == 1);
            if (case == .receipt_failure) {
                // A read-only regular descriptor fails the actual receipt write.
                const readonly = try directory.openFile(io, "receipt", .{});
                defer readonly.close(io);
                if (std.c.dup2(readonly.handle, 1) < 0) return error.TestRedirectFailed;
            }
            if (case == .before_guided) {
                var guided = LoginInterrupt.init();
                defer guided.deinit();
                try std.posix.raise(.INT);
                outcome = login(init, &.{"codex"}, true, Fixture.exchange);
            } else outcome = login(init, &.{"codex"}, false, Fixture.exchange);
        }
        if (Fixture.signal_thread) |thread| thread.join();
        custodian.done.store(true, .release);
        if (custodian_thread) |thread| {
            thread.join();
            custodian_thread = null;
            try std.testing.expect(custodian.completed_while_held);
        }
        if (Fixture.signal_failure) |err| return err;
        var restored: std.posix.Sigaction = undefined;
        std.posix.sigaction(.INT, null, &restored);
        try std.testing.expectEqual(std.posix.SIG.IGN, restored.handler.handler);
        var receipts: [2048]u8 = undefined;
        const receipt_bytes = try directory.readFile(io, "receipt", &receipts);
        if (before or case == .credential_failure) {
            if (before) {
                try std.testing.expectError(error.LoginInterrupted, outcome);
            } else {
                try std.testing.expectEqual(LoginState.publishing, login_state.load(.acquire));
                if (outcome) |_| return error.CredentialFailureNotReported else |err| try std.testing.expect(err != error.LoginInterrupted);
            }
            try std.testing.expectEqual(@as(usize, 0), receipt_bytes.len);
            if (existing) {
                var bytes: [4096]u8 = undefined;
                defer std.crypto.secureZero(u8, &bytes);
                try std.testing.expectEqualStrings(prior_auth, try directory.readFile(io, "codex.json", &bytes));
            } else try std.testing.expectError(error.FileNotFound, codex_credentials.load(path));
        } else {
            if (case == .receipt_failure) {
                if (outcome) |_| return error.ReceiptFailureNotReported else |err| try std.testing.expect(err != error.LoginInterrupted);
            } else try outcome;
            try std.testing.expectEqual(LoginState.publishing, login_state.load(.acquire));
            var record = try codex_credentials.load(path);
            defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
            try std.testing.expectEqualStrings(codex_auth.fixture_account_id, record.account_id.slice());
            try std.testing.expectEqualStrings("new-synthetic-refresh", record.refresh_token.slice());
            try std.testing.expectEqual(@as(u64, if (existing) 2 else 1), record.generation);
            if (case != .receipt_failure) try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, "Codex credential installed") != null);
            if (case == .missing_home or case == .preference_failure) {
                try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, "future defaults were not saved or durability is uncertain") != null);
                try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, if (case == .missing_home) "InvalidHome" else "UnsupportedPreferencesVersion") != null);
            }
        }
        if (existing) {
            var bytes: [1024]u8 = undefined;
            try std.testing.expectEqualStrings(prior_defaults, try directory.readFile(io, "preferences", &bytes));
        } else if (case == .preference_failure) {
            var bytes: [1024]u8 = undefined;
            try std.testing.expectEqualStrings("version=9\n", try directory.readFile(io, "preferences", &bytes));
        } else {
            const defaults = try preferences.load(home);
            try std.testing.expectEqualStrings(if (before or case == .credential_failure or case == .missing_home) "" else "codex", defaults.provider.slice());
            try std.testing.expectEqualStrings("", defaults.model.slice());
        }
        try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, "new-synthetic-refresh") == null);
        try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, codex_auth.fixture_access_token) == null);
    }
}

test "SIGINT and credential publication have one winner" {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onLoginInterrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &previous);
    defer std.posix.sigaction(.INT, &previous, null);
    defer login_state.store(.cancellable, .release);
    login_state.store(.cancellable, .release);
    try std.posix.raise(.INT);
    try std.testing.expect(loginInterrupted());
    try std.testing.expect(login_state.cmpxchgStrong(.cancellable, .publishing, .acq_rel, .acquire) != null);
    login_state.store(.cancellable, .release);
    try std.testing.expect(login_state.cmpxchgStrong(.cancellable, .publishing, .acq_rel, .acquire) == null);
    try std.posix.raise(.INT);
    try std.testing.expect(!loginInterrupted());
    try std.testing.expectEqual(LoginState.publishing, login_state.load(.acquire));
}

/// A fresh terminal choice authorizes login; reading setup status alone does not.
fn guideProviderLogin(init: std.process.Init) !void {
    var interrupt = LoginInterrupt.init();
    defer interrupt.deinit();
    try std.Io.File.stdout().writeStreamingAll(init.io, "Codex login stores Rui-owned credentials.\n");
    var choice_buffer: [16]u8 = undefined;
    const choice = (TerminalEditor.readLine(init.io, &choice_buffer, "Provider: [c] Codex login, [d] defer > ", false) catch |err| switch (err) {
        error.StreamTooLong, error.InvalidTerminalInput => {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Choose c or d. No login or preference change.\n");
            return;
        },
        else => return err,
    }) orelse {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Login deferred.\n");
        return;
    };
    if (std.mem.eql(u8, choice, "d")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Login deferred.\n");
        return;
    }
    if (!std.mem.eql(u8, choice, "c")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Choose c or d. No login or preference change.\n");
        return;
    }
    if (loginInterrupted()) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Login interrupted. No provider preference changed; check credentials before retrying.\n");
        return;
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Starting Codex device login. The printed code is for the provider page only; waiting for its answer.\n");
    const outcome = login(init, &.{"codex"}, true, codex_auth.login);
    outcome catch |err| {
        const advice: []const u8 = switch (err) {
            error.LoginInterrupted => "Rui: Login interrupted. No provider preference changed; check credentials before retrying.\n",
            error.LoginDenied => "Rui: Login denied. No provider preference changed; use rui auth login codex if intended.\n",
            error.LoginExpired => "Rui: Login expired. No provider preference changed; use rui auth login codex for a fresh code.\n",
            else => "Rui: Login failed or credential save unconfirmed. Use rui defaults inspect before retrying; no Session binding changed.\n",
        };
        try std.Io.File.stdout().writeStreamingAll(init.io, advice);
        return;
    };
}

const NewSessionOptions = struct {
    store: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,

    /// Null when the invocation asks for help.
    fn parse(args: []const []const u8) !?NewSessionOptions {
        // The fresh-session grammar has no hex spellings to allocate.
        var nothing = std.heap.FixedBufferAllocator.init(&.{});
        const parsed = cli_args.fresh_session.parse(args, nothing.allocator()) catch return usage();
        if (parsed.help) return null;
        return .{ .store = parsed.get("store"), .provider = parsed.get("provider"), .model = parsed.get("model") };
    }
};

/// Conversations draw cells on the terminal's alternate screen. Refuse before
/// any Host or Session change when that terminal is absent or cannot draw.
fn requireInteractiveTerminal(init: std.process.Init, purpose: []const u8) !void {
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) {
        TerminalText.diagnostic("rui needs terminal input and output {s}; scripts and agents use rui session start or rui session send --to ID, with Message text on stdin. No Host or Session changed.\n", .{purpose});
        return error.InteractiveTerminalRequired;
    }
    if (std.mem.eql(u8, init.environ_map.get("TERM") orelse "", "dumb")) {
        TerminalText.diagnostic("rui needs a terminal that supports cursor addressing {s}; TERM=dumb does not. Set TERM for your terminal or use explicit one-shot commands. No Host or Session changed.\n", .{purpose});
        return error.InteractiveTerminalRequired;
    }
}

fn newSession(init: std.process.Init, args: []const []const u8) !void {
    const options = try NewSessionOptions.parse(args) orelse return std.Io.File.stdout().writeStreamingAll(init.io, usage_text);
    try requireInteractiveTerminal(init, "to create a Session");
    const saved = (try createSession(init, options)) orelse return;
    runSession(init, saved.store.slice(), saved.session.slice(), null) catch |err| {
        // Configuration acceptance and local entry are independent outcomes.
        var bytes: [256]u8 = undefined;
        var notice = std.Io.Writer.fixed(&bytes);
        notice.print("\nrui: Session configuration accepted.\nConfiguration request: {s} (rui request inspect {s})\n", .{ saved.key.slice(), saved.key.slice() }) catch return err;
        _ = @import("stderr.zig").write(notice.buffered());
        return err;
    };
}

fn createSession(init: std.process.Init, options: NewSessionOptions) !?protocol_reply.MutationIdentity {
    if (options.model) |model| try requireSupportedModel(model);
    const intent: new_session_selection.Intent = .{ .store = options.store, .provider = options.provider, .model = options.model };
    var cwd = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
    defer cwd.close(init.io);
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace_length = try cwd.realPath(init.io, &workspace_buffer);
    const workspace = workspace_buffer[0..workspace_length];

    const home = init.environ_map.get("HOME") orelse return homeRequired("a new Session reads saved defaults and request captures under HOME");
    var snapshot: new_session_selection.Snapshot = undefined;
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var credential_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var credential: ?[]const u8 = null;
    var selected_store: []const u8 = undefined;
    var after_choice = false;
    const selected = while (true) {
        // Rebuild in stable storage on every pass; fully explicit intent never
        // reads preferences, even after login's independent default-save failure.
        snapshot = .{ .intent = intent, .defaults = if (intent.needsPreferences()) preferences.load(home) catch |err| {
            if (!after_choice) TerminalText.diagnostic("rui: private setup defaults unreadable ({s}); use rui defaults inspect before creating a Session.\n", .{@errorName(err)});
            return err;
        } else .{} };
        const destination = try snapshot.destination(home, &fallback);
        selected_store = destination.path;
        try preflightNewSession(init.io, selected_store, destination.saved);
        // Check the prospective pin before credential lookup or login. Local
        // identifier syntax and release support are separate policies.
        const prospective = snapshot.resolve(.configured) catch |err| {
            if (after_choice) {
                TerminalText.diagnostic("rui: unsupported prospective provider/model after login ({s}); use rui defaults inspect. No Session created.\n", .{@errorName(err)});
            } else TerminalText.diagnostic("rui: unsupported prospective provider/model ({s}); use rui defaults inspect or select codex / " ++ product_defaults.recommended_model ++ ". No Session created.\n", .{@errorName(err)});
            return err;
        };
        if (prospective) |binding| try requireSupportedModel(binding.model.slice());
        if (credential == null) credential = try credentialPath(init, &credential_buffer, false);
        const now = codex_auth.nowSeconds(init.io);
        const readiness: provider_selection.Readiness = if (codex_auth.localStatus(credential.?, now)) |state| switch (state) {
            .missing => .missing,
            .configured => .configured,
            .renewal_due => .renewal_due,
            .refresh_required => .refresh_required,
        } else |err| blk: {
            if (after_choice) {
                TerminalText.diagnostic("rui: credential still unreadable ({s}); use rui defaults inspect. No Session created.\n", .{@errorName(err)});
                return err;
            }
            break :blk .credential_error;
        };
        const selection = try snapshot.resolve(readiness);
        if (selection) |binding| break binding;
        if (after_choice) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No new Session created. Use rui defaults inspect or rui auth login codex when ready; existing work is unchanged.\n");
            return null;
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No locally ready provider for a new Session. Choose Codex login or defer; saved work remains inspectable.\n");
        try guideProviderLogin(init);
        after_choice = true;
    };
    try startHost(init, selected_store, true, null);
    const paths = try platform.resolveClientPaths(init.io, selected_store);
    const destination = paths.store.slice();
    const ready = switch (client.hostStatus(init.io, destination)) {
        .ready => |current| current,
        else => return error.HostReadinessUnconfirmed,
    };
    if (!ready.capabilities.model) {
        TerminalText.diagnostic("rui: selected Host has no model capability; it was not restarted. Inspect rui host status before creating a Session.\n", .{});
        return error.HostModelUnavailable;
    }
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var captured = try client.captureConfigure(init.io, .{
        .store = destination,
        .session = .create,
        .require_model = true,
        .workspace = .{ .present = true, .value = workspace },
        .provider = .{ .present = true, .value = selected.provider.slice() },
        .model = .{ .present = true, .value = selected.model.slice() },
        .tools = product_defaults.tools,
        .permission_mode = .{ .present = true, .value = product_defaults.permission_mode },
    }, .{ .generated = try requestDirectory(init, &directory_buffer) }).get();
    const saved = captured.identity().*;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(init.io);
        try testGate(init.io, "RUI_TEST_CAPTURE_GATE");
        break :blk (client.Requests{ .io = init.io }).sendCaptured(&captured, &reply_buffer).get() catch |err| {
            TerminalText.diagnostic("rui: configuration not confirmed ({s}); use rui request recover {s}. Do not replace uncertain work.\n", .{ @errorName(err), saved.key.slice() });
            return err;
        };
    };
    if (!reply.isAccepted()) {
        try writeMutationReply(init.io, reply, .human);
        return error.SessionConfigurationRejected;
    }
    var configured = saved;
    configured.session = reply.context.session;
    return configured;
}

fn preflightNewSession(io: std.Io, destination: []const u8, saved: bool) !void {
    if (saved) {
        _ = try platform.resolveClientPaths(io, destination);
    } else try platform.validateStoreDestination(io, destination);
    switch (client.hostStatus(io, destination)) {
        .ready => |ready| if (!ready.capabilities.model) return error.HostModelUnavailable,
        .unavailable => {},
        .owned_unavailable => return error.HostReadinessUnconfirmed,
        .incompatible => return error.IncompatibleHost,
        .access_failure => return error.StoreAccessFailed,
    }
}

fn serve(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    const io = init.io;
    const store_path = parsed.get("store");
    const provider_endpoint = parsed.get("provider-endpoint");
    const provider_ca_file = parsed.get("provider-ca-file");
    const managed = parsed.has("codex");
    const fixture_endpoint = parsed.get("test-codex-fixture-endpoint");
    const bash_path = parsed.get("bash-path") orelse server.default_bash_path;
    if (bash_path.len == 0) return error.InvalidBashPath;
    const bash_timeout_ms = try parsed.number(u64, "bash-timeout-ms") orelse server.default_bash_timeout_ms;
    if (bash_timeout_ms == 0 or bash_timeout_ms > std.math.maxInt(i64)) return error.InvalidBashTimeout;
    const active_capacity = try parsed.number(usize, "active-capacity") orelse product_defaults.active_capacity;
    var limits: server.Limits = .{};
    var hooks: server.Hooks = .{};
    if (try parsed.number(u64, "test-bash-scratch-limit-bytes")) |limit| limits.bash_scratch_limit_bytes = limit;
    if (try parsed.number(usize, "test-retention-entry-capacity")) |capacity| {
        if (capacity < 2 or capacity > server.default_retention_entry_capacity) return error.InvalidRetentionEntryCapacity;
        limits.retention_entry_capacity = capacity;
    }
    if (parsed.has("test-retention-removal-failure")) hooks.retention_removal = true;
    for (parsed.all("fault")) |fault| try hooks.inject(fault);
    if (try parsed.number(i64, "test-provider-inactivity-seconds")) |seconds| {
        if (seconds < 1) return error.InvalidProviderInactivity;
        _ = std.math.mul(i64, seconds, std.time.ns_per_s) catch return error.InvalidProviderInactivity;
        limits.provider_inactivity_seconds = seconds;
    }
    if (parsed.get("test-retry-waits-ms")) |waits| limits.retry_waits_ms = try parseRetryWaits(waits);
    if (try parsed.number(i64, "test-before-launch-delay-ms")) |delay| {
        if (delay < 0 or delay > 10_000) return error.InvalidLaunchDelay;
        hooks.pauses.getPtr(.action_launch).delay_ms = delay;
        hooks.pauses.getPtr(.model_launch).delay_ms = delay;
    }
    if (try parsed.number(i64, "test-before-result-delay-ms")) |delay| {
        if (delay < 0 or delay > 10_000) return error.InvalidResultDelay;
        hooks.pauses.getPtr(.action_result).delay_ms = delay;
        hooks.pauses.getPtr(.model_result).delay_ms = delay;
    }
    hooks.pauses.getPtr(.model_result).gate_path = parsed.get("test-model-result-gate-path");
    hooks.retry_recovery_gate_path = parsed.get("test-retry-recovery-gate-path");
    hooks.inspection_reply.gate_path = parsed.get("test-inspection-reply-gate-path");
    if (try parsed.number(i64, "test-inspection-reply-delay-ms")) |delay| {
        if (delay < 0 or delay > 60_000) return error.InvalidInspectionReplyDelay;
        hooks.inspection_reply.delay_ms = delay;
    }
    if (try parsed.number(u32, "test-client-send-buffer-bytes")) |bytes| {
        if (bytes == 0 or bytes > std.math.maxInt(c_int)) return error.InvalidClientSendBuffer;
        limits.client_send_buffer_bytes = bytes;
    }
    if (parsed.has("test-phase-trace")) hooks.phase_trace = true;
    if (try parsed.number(c_int, "test-observation-fd")) |fd| {
        hooks.observation_fd = fd;
        hooks.phase_trace = true;
    }
    if (try parsed.number(c_int, "test-observation-state-fd")) |fd| hooks.observation_state_fd = fd;
    if (parsed.get("test-observation-plan")) |plan| hooks.observation_plan = std.meta.stringToEnum(TestObservation.Plan, plan) orelse
        return error.InvalidTestObservationPlan;
    const transition: ?server.Hooks.Transition = if (parsed.get("test-transition")) |name|
        server.Hooks.fromOptionName(server.Hooks.Transition, name) orelse return error.UnknownTestTransition
    else
        null;
    const transition_gate_path = parsed.get("test-transition-gate-path");
    hooks.pauses.getPtr(.bash_exit_observed).gate_path = parsed.get("test-bash-observed-exit-gate-path");
    hooks.pauses.getPtr(.shutdown_signalled).gate_path = parsed.get("test-shutdown-signalled-gate-path");
    hooks.bash_reclaim_gate_path = parsed.get("test-bash-cleanup-gate-path");
    const control_gate_keys = parsed.get("test-control-gate-keys");
    const control_gate_path = parsed.get("test-control-gate-path");
    if (parsed.has("test-suppress-first-control-hint")) hooks.suppress_first_control_hint = true;
    if (parsed.has("test-sqlite-diagnostics")) hooks.sqlite_diagnostics = true;
    if (parsed.has("test-sqlite-cache-spill-off")) limits.sqlite_cache_spill = false;
    if (try parsed.number(u32, "test-sqlite-cache-kib")) |kib| {
        if (kib == 0 or kib > 4096) return error.InvalidSqliteCacheSize;
        limits.sqlite_cache_kib = kib;
    }
    if (try parsed.number(u64, "test-request-scratch-limit")) |limit| limits.request_scratch_limit_bytes = limit;
    if (try parsed.number(usize, "test-request-preparation-byte-allowance")) |allowance| {
        if (allowance == 0) return error.InvalidRequestPreparationAllowance;
        limits.request_preparation_byte_allowance = allowance;
    }
    if (try parsed.number(usize, "test-request-preparation-item-allowance")) |allowance| {
        if (allowance == 0) return error.InvalidRequestPreparationAllowance;
        limits.request_preparation_item_allowance = allowance;
    }
    if (try parsed.number(i64, "test-request-preparation-advance-delay-ms")) |delay| {
        if (delay < 0) return error.InvalidRequestPreparationDelay;
        hooks.pauses.getPtr(.preparation_advanced).delay_ms = delay;
    }
    if ((control_gate_keys == null) != (control_gate_path == null)) return error.IncompleteControlGate;
    if ((transition == null) != (transition_gate_path == null)) return error.IncompleteTestTransitionGate;
    if (control_gate_keys) |keys| hooks.control_gate = .{ .keys = keys, .path = control_gate_path.? };
    if (transition) |value| hooks.transition = .{ .transition = value, .path = transition_gate_path.? };
    if (fixture_endpoint != null and init.environ_map.get("RUI_CODEX_CREDENTIAL_FILE") == null)
        return error.FixtureCredentialPathRequired;
    var credential_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const credential_path: ?[]const u8 = if (managed or fixture_endpoint != null) try credentialPath(init, &credential_path_buffer, false) else null;
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return server.serve(
        io,
        std.heap.c_allocator,
        try selectedStore(init, store_path, &selected_buffer),
        active_capacity,
        limits,
        hooks,
        if (managed) model_adapter.managed_endpoint else fixture_endpoint orelse provider_endpoint,
        provider_ca_file,
        if (credential_path) |path| model_adapter.Authentication{ .path = path, .fixture = fixture_endpoint != null } else null,
        bash_path,
        bash_timeout_ms,
        init.environ_map.get("HOME"),
    );
}

fn parseRetryWaits(value: []const u8) !retry_policy.Waits {
    var waits: retry_policy.Waits = undefined;
    var parts = std.mem.splitScalar(u8, value, ',');
    for (&waits) |*wait| {
        const part = parts.next() orelse return error.InvalidRetryWaits;
        wait.* = std.fmt.parseInt(u64, part, 10) catch return error.InvalidRetryWaits;
    }
    if (parts.next() != null) return error.InvalidRetryWaits;
    // The Store rechecks the deadlines against its clock at startup.
    retry_policy.validateWaits(waits, 0) catch return error.InvalidRetryWaits;
    return waits;
}

fn policyArgument(text: []const u8) client.OptionalPolicy {
    return .{ .present = true, .value = if (std.mem.eql(u8, text, "default")) null else text };
}

test "policy arguments reset and preserve spelling" {
    const reset = policyArgument("default");
    try std.testing.expect(reset.present and reset.value == null);
    try std.testing.expectEqualStrings("00042", policyArgument("00042").value.?);
}

/// The live Session addresses its own /configure.
const LiveAddress = struct { store: []const u8, session: []const u8 };

/// A Label obeys the saved Bash description rule; "" is the one spelling
/// that clears it and can never be a Label.
fn labelArgument(text: []const u8) error{InvalidLabel}!client.OptionalPolicy {
    if (text.len == 0) return .{ .present = true, .value = null };
    if (protocol.ToolPresentation.validDescription(text)) return .{ .present = true, .value = text };
    _ = @import("stderr.zig").write("\nrui: --label must be one line of 1-100 bytes that is not blank. Nothing captured or changed.\n" ++ cli_args.label_help);
    return error.InvalidLabel;
}

test "a Label argument sets, clears or refuses before capture" {
    try std.testing.expectEqualStrings("Review PR 412", (try labelArgument("Review PR 412")).value.?);
    const cleared = try labelArgument("");
    try std.testing.expect(cleared.present and cleared.value == null);
    const longest: [100]u8 = @splat('x');
    const too_long: [101]u8 = @splat('x');
    for ([_][]const u8{ "two\nlines", " ", &too_long }) |text| try std.testing.expectError(error.InvalidLabel, labelArgument(text));
    try std.testing.expectEqual(@as(usize, 100), (try labelArgument(&longest)).value.?.len);
}

fn requireSupportedModel(model: []const u8) error{UnsupportedModel}!void {
    if (model_capability.supportsModel(model)) return;
    // Optional diagnostics stay bounded and cannot retain a restored terminal
    // on stderr credit. Spell arbitrary bytes safely, without changing input.
    var bytes: [4 * protocol.max_model_bytes + model_capability.model_help.len + 256]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    out.writeAll("\nrui: unsupported model ") catch unreachable;
    if (model.len <= protocol.max_model_bytes) {
        out.writeByte('"') catch unreachable;
        writeSafeTextTo(&out, model) catch unreachable;
        out.writeByte('"') catch unreachable;
    } else {
        out.print("ID ({d} bytes exceeds the {d}-byte limit)", .{ model.len, protocol.max_model_bytes }) catch unreachable;
    }
    out.writeAll(". Nothing captured or changed.\n" ++ model_capability.model_help ++ "See rui session configure --help.\n") catch unreachable;
    _ = @import("stderr.zig").write(out.buffered());
    return error.UnsupportedModel;
}

fn configure(init: std.process.Init, requester: client.Requests, parsed: *const cli_args.Parsed, live: ?LiveAddress, start: bool) !void {
    const io = init.io;
    const interactive = live != null;
    const named = if (live) |address| address.session else parsed.get("session");
    var input = client.ConfigureInput{
        .store = "",
        .session = if (named) |reference| .{ .named = reference } else .create,
    };
    if (named != null and named.?.len == 0) return usage();
    if (parsed.get("provider")) |name| input.provider = .{ .present = true, .value = name };
    if (parsed.get("model")) |model| {
        try requireSupportedModel(model);
        input.model = .{ .present = true, .value = model };
    }
    if (parsed.get("workspace")) |workspace| input.workspace = .{ .present = true, .value = workspace };
    if (parsed.get("instructions")) |path| input.instructions = .{ .state = .value, .path = path };
    input.tools = parsed.get("tools");
    if (parsed.get("permission-mode")) |mode| input.permission_mode = .{ .present = true, .value = mode };
    if (parsed.get("output-schema")) |path| input.output_schema = .{ .state = .value, .path = path };
    if (parsed.has("text-output")) input.output_schema = .{ .state = .explicit_null };
    if (parsed.get("compaction-trigger")) |text| input.compaction_trigger = policyArgument(text);
    if (parsed.get("output-reservation")) |text| input.output_reservation = policyArgument(text);
    if (parsed.get("reasoning-effort")) |text| input.reasoning_effort = policyArgument(text);
    if (parsed.get("label")) |text| input.label = try labelArgument(text);
    var binding: new_session_selection.Binding = .{};
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    // Only fresh creation resolves defaults, once, into the capture, through
    // the same prospective selection as a new interactive Session. Addressed
    // input remains sparse for updates. Unknown IDs never create Sessions.
    if (input.session == .create) {
        const intent: new_session_selection.Intent = .{
            .provider = if (input.provider.present) input.provider.value else null,
            .model = if (input.model.present) input.model.value else null,
        };
        const snapshot: new_session_selection.Snapshot = .{ .intent = intent, .defaults = if (intent.provider == null or intent.model == null) blk: {
            const home = init.environ_map.get("HOME") orelse return homeRequired("fresh configuration without --provider and --model reads saved defaults");
            break :blk try preferences.load(home);
        } else .{} };
        // Credential readiness belongs to the serving Host, not this peer
        // caller: select as if usable and let the Host answer for credentials.
        binding = (try snapshot.resolve(.configured)).?;
        try requireSupportedModel(binding.model.slice());
        input.provider = .{ .present = true, .value = binding.provider.slice() };
        input.model = .{ .present = true, .value = binding.model.slice() };
        if (!input.workspace.present) {
            var cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer cwd.close(io);
            const length = try cwd.realPath(io, &workspace_buffer);
            input.workspace = .{ .present = true, .value = workspace_buffer[0..length] };
        }
        if (input.tools == null) input.tools = product_defaults.tools;
        if (!input.permission_mode.present) input.permission_mode = .{ .present = true, .value = product_defaults.permission_mode };
    }
    if (start) return message(init, parsed, input);
    var step: ?client.Step = .store;
    errdefer reportFailureStep(step);
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, if (live) |address| address.store else parsed.get("store"), &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = try captureTarget(init, parsed, &directory_buffer);
    const human = target == .generated;
    var sender = requester;
    sender.drop_reply = parsed.get("test-drop-reply");
    var captured = try takeCapture(&step, client.captureConfigure(io, input, target));
    const saved = captured.identity().*;
    var admitted: ?bool = null;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(io);
        if (human and !interactive) try announceCapture(io, saved.key.slice());
        break :blk takeReply(&step, sender.sendCaptured(&captured, &reply_buffer));
    } catch |err| {
        if (human and interactive) reportConfigurationFailure(err, admitted, saved.key.slice());
        return err;
    };
    // Record framed admission before presentation; writeMutationReply owns errors.
    if (human and interactive) admitted = if (reply.answer) |_| reply.isAccepted() else |_| null;
    writeMutationReply(io, reply, if (human and interactive) .interactive_configuration else .{ .json = .of(target) }) catch |err| {
        if (human and interactive) reportConfigurationFailure(err, admitted, saved.key.slice());
        return err;
    };
    if (human and interactive) if (requester.cancellation) |token| if (token.stopped.load(.acquire)) {
        TerminalText.diagnostic("rui: Configuration {s}; use rui request inspect {s} to inspect the same saved admission.\n", .{ if (admitted.?) "accepted; do not resubmit it" else "rejected", saved.key.slice() });
    };
}

fn reportConfigurationFailure(err: anyerror, admitted: ?bool, key: []const u8) void {
    const status = if (admitted) |accepted| if (accepted) "accepted; do not resubmit it" else "rejected" else "not confirmed; do not replace uncertain work";
    if (admitted == null) {
        TerminalText.diagnostic("rui: Configuration {s} ({s}). Inspect with rui request inspect {s}; if still unconfirmed, rui request recover {s} retransmits the same saved request.\n", .{ status, @errorName(err), key, key });
        return;
    }
    TerminalText.diagnostic("rui: Configuration {s} ({s}). Use rui request inspect {s} to inspect the same saved request.\n", .{ status, @errorName(err), key });
}

fn message(init: std.process.Init, parsed: *const cli_args.Parsed, configuration: ?client.ConfigureInput) !void {
    const io = init.io;
    var step: ?client.Step = .input_parse;
    errdefer reportFailureStep(step);
    const destination = if (configuration != null) "" else parsed.get("to").?;
    if (configuration == null and !protocol.validSessionId(destination)) {
        TerminalText.diagnostic("rui: --to needs exactly six lowercase Crockford characters, for example k7m2qx. Nothing was sent.\n", .{});
        return error.InvalidSession;
    }
    var input = client.MessageInput{ .store = "", .session = destination, .text_path = "-", .configuration = configuration };
    // Never let incomplete or malformed peer context fall back to HOME or
    // become an anonymous send. The Host still authenticates the live handle.
    const address = init.environ_map.get("RUI_ADDRESS");
    const sender_store = init.environ_map.get("RUI_STORE");
    input.sender_handle = init.environ_map.get("RUI_SENDER_HANDLE");
    if (address != null or sender_store != null or input.sender_handle != null) {
        if (address == null or sender_store == null or input.sender_handle == null or
            !protocol.validSessionId(address.?) or sender_store.?.len == 0 or input.sender_handle.?.len == 0)
        {
            TerminalText.diagnostic("rui: invalid peer context; nothing was sent.\n", .{});
            return error.InvalidRuiAddress;
        }
        input.sender = .{ .store = sender_store.?, .session = address.? };
    }
    step = .store;
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (sender_store) |trusted| {
        const sender_paths = try platform.resolveClientPaths(io, trusted);
        if (parsed.get("store")) |override| {
            const override_paths = try platform.resolveClientPaths(io, override);
            if (!override_paths.store.eql(sender_paths.store.slice())) {
                TerminalText.diagnostic("rui: peer sends must use the sender's Store; nothing was sent.\n", .{});
                return error.CrossStorePeerSend;
            }
        }
        input.store = trusted;
    } else input.store = try selectedStore(init, parsed.get("store"), &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = try captureTarget(init, parsed, &directory_buffer);
    var captured = try takeCapture(&step, client.captureMessage(io, input, target));
    const sender: client.Requests = .{ .io = io, .drop_reply = parsed.get("test-drop-reply") };
    if (configuration == null) return sendCapturedMutation(sender, &captured, target, &step);
    defer captured.close(io);
    if (target == .generated) try announceCapture(io, captured.identity().key.slice());
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try takeReply(&step, sender.sendCaptured(&captured, &reply_buffer));
    if (!reply.isAccepted()) return writeMutationReply(io, reply, .{ .json = .of(target) });
    // This is the first Message's admission, never execution/completion.
    try std.Io.File.stdout().writeStreamingAll(io, reply.context.session.slice());
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

/// The value of a capture or send, after recording the step a failure
/// stopped in for the command's diagnostic. A failure before any step keeps
/// the step the command already holds.
fn takeStep(step: *?client.Step, stepped: anytype) !@FieldType(@TypeOf(stepped), "done") {
    if (stepped == .failed) if (stepped.failed.step) |failed| {
        step.* = failed;
    };
    return stepped.get();
}

/// A captured record; until a send begins, a later failure is the capture's.
fn takeCapture(step: *?client.Step, stepped: anytype) !client.CapturedRecord {
    const captured = try takeStep(step, stepped);
    step.* = .capture;
    return captured;
}

/// A send's reply. A framed reply leaves nothing to report; an unreadable
/// one leaves admission unknown.
fn takeReply(step: *?client.Step, stepped: anytype) !protocol_reply.MutationReply {
    const reply = try takeStep(step, stepped);
    step.* = if (reply.answer) |_| null else |_| .admission_response;
    return reply;
}

/// Null once the Host's reply was presented.
fn reportFailureStep(held: ?client.Step) void {
    const step = held orelse return;
    TerminalText.diagnostic("rui: failure during {s}; cause follows.\n", .{@tagName(step)});
    if (step.mayHaveReachedHost())
        TerminalText.diagnostic("rui: admission outcome is unconfirmed; inspect or recover the original request, never replace it with a fresh key.\n", .{});
}

/// An explicit --record and --key identity, which the grammar requires
/// together, or a generated capture in the request directory.
fn captureTarget(init: std.process.Init, parsed: *const cli_args.Parsed, directory_buffer: []u8) !client.CaptureTarget {
    if (parsed.get("record")) |record| return .{ .explicit = .{ .record = record, .key = parsed.get("key").? } };
    return .{ .generated = try requestDirectory(init, directory_buffer) };
}

/// Entry only confirms configuration; /status renders inside the Session.
fn confirmSessionConfigured(init: std.process.Init, requester: client.Requests, store: []const u8, session_ref: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    // Keep the primary rendering/inspection error if flushing also fails.
    defer writer.flush() catch {};
    const report = try inspectWorkTo(init, requester, store, session_ref, &writer.interface);
    report.file.close(init.io);
    try writer.flush();
}

/// Everything /status reports, from one Current capture; `file` holds the
/// capture's attention rows.
pub fn writeSessionStatus(io: std.Io, store: []const u8, session_ref: []const u8, work: *const protocol_reply.Current, file: std.Io.File, out: *std.Io.Writer) anyerror!void {
    try writeSafeFieldTo(out, "Session: ", session_ref);
    try writeSafeFieldTo(out, "Store: ", store);
    try writeSafeFieldTo(out, "Workspace (Bash cwd): ", work.settings.workspace.slice());
    try writeSafeFieldTo(out, "Provider: ", @tagName(work.settings.provider.value));
    try writeSafeFieldTo(out, "Model: ", work.settings.model.slice());
    {
        var buffer: [80]u8 = undefined;
        const effort = if (work.settings.reasoning_effort) |value|
            try std.fmt.bufPrint(&buffer, "{s} ({s})", .{ @tagName(value.value), if (work.settings.reasoning_effort_override != null) "Session override" else "catalog default" })
        else
            "unknown (no catalog value; reasoning omitted)";
        try writeSafeFieldTo(out, "Reasoning effort: ", effort);
    }
    // The bypass default is stated where it is inspected, without alert weight.
    try writeSafeFieldTo(out, "Permission: ", switch (work.settings.permission_mode.value) {
        .bypass => "bypass (Bash runs without asking)",
        else => |mode| @tagName(mode),
    });
    {
        const origin = if (work.settings.compaction_trigger_override != null) "Session override" else "model default";
        var buffer: [160]u8 = undefined;
        const policy = if (work.settings.compaction_trigger) |tokens|
            try std.fmt.bufPrint(&buffer, "estimated context pressure threshold: {s} tokens ({s})", .{ tokens.slice(), origin })
        else
            try std.fmt.bufPrint(&buffer, "no automatic threshold ({s})", .{origin});
        try writeSafeFieldTo(out, "Automatic compaction: ", policy);
        if (work.settings.compaction_trigger == null)
            try out.writeAll("Use /configure --compaction-trigger TOKENS to enable a threshold. Provider context-overflow recovery still applies.\n");
    }
    {
        const origin = if (work.settings.output_reservation_override != null) "Session override" else "model default";
        var buffer: [160]u8 = undefined;
        try writeSafeFieldTo(out, "Extra compaction headroom: ", try std.fmt.bufPrint(&buffer, "{s} tokens ({s}); not a guaranteed output budget", .{ work.settings.output_reservation.slice(), origin }));
    }
    try writeSafeFieldTo(out, "Work: ", @tagName(work.work.state.value));
    if (work.selected_message) |selected|
        try writeSafeFieldTo(out, "Current message: ", selected.slice());
    if (work.actionable_count != 0) try renderActionable(io, work, file, out);
    if (work.first_indeterminate) |action| {
        var buffer: [20]u8 = undefined;
        try writeSafeFieldTo(out, "Indeterminate Action: ", try std.fmt.bufPrint(&buffer, "{d}", .{action}));
        if (work.indeterminate_count > 1) {
            var line: [160]u8 = undefined;
            try out.writeAll(try std.fmt.bufPrint(&line, "Rui: {d} indeterminate Actions in this Turn; session inspect --profile current lists all IDs.\n", .{work.indeterminate_count}));
        }
        try out.writeAll("Rui: The command may have run; Rui did not replay it. Check its effects before deciding what to do next.\n");
    }
    if (work.recent_count != 0) {
        try out.writeAll("Recent messages (use /result KEY for an answer):\n");
        for (work.recent[0..work.recent_count]) |recent| {
            try out.writeAll("  ");
            try writeSafeTextTo(out, recent.message.slice());
            try out.writeAll(": ");
            try writeSafeFieldTo(out, "", recent.outcome.slice());
        }
    }
}

fn writeSafeFieldTo(out: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try out.writeAll(label);
    try writeSafeTextTo(out, value);
    try out.writeByte('\n');
}

fn writeSafeTextTo(out: *std.Io.Writer, value: []const u8) !void {
    var text: TerminalText = .{ .mode = .line };
    try text.feed(out, value);
    try text.finish(out);
}

fn writeSafeField(io: std.Io, label: []const u8, value: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, label);
    try writeSafeText(io, value);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn writeSafeText(io: std.Io, value: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writeSafeTextTo(&writer.interface, value);
    try writer.flush();
}

fn runSession(init: std.process.Init, destination: []const u8, reference: []const u8, initial_text: ?[]const u8) anyerror!void {
    // Callers own canonical Store resolution and complete Session selection.
    const outcome: anyerror!void = run: {
        confirmSessionConfigured(init, .{ .io = init.io }, destination, reference) catch |err| {
            if (err == error.SessionNotConfigured) TerminalText.diagnostic("rui: configure this Session before entering it\n", .{});
            break :run err;
        };
        var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory = requestDirectory(init, &directory_buffer) catch |err| break :run err;
        const scratch = renderScratch(init) catch |err| break :run err;
        defer scratch.close(init.io);
        const action = renderScratch(init) catch |err| break :run err;
        defer action.close(init.io);
        const inspection = renderScratch(init) catch |err| break :run err;
        defer inspection.close(init.io);
        const status = renderScratch(init) catch |err| break :run err;
        defer status.close(init.io);
        break :run SessionFrontend.run(init, destination, reference, directory, .{ .scratch = scratch, .action = action, .inspection = inspection, .status = status }, sessionCommand, sessionRequests, writeSessionStatus, initial_text);
    };
    return outcome catch |err| {
        notice: {
            // Four bytes per escaped selector byte, plus labels and hex syntax.
            var bytes: [4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 256]u8 = undefined;
            var notice = std.Io.Writer.fixed(&bytes);
            if (err == error.InvalidTemporaryDirectory)
                notice.writeAll("rui: Fix or unset TMPDIR before resuming.\n") catch break :notice;
            notice.writeAll("\nResume: rui session resume --store ") catch break :notice;
            TerminalText.writeShellWord(&notice, destination) catch break :notice;
            TerminalText.writeShellSession(&notice, reference, true) catch break :notice;
            notice.writeByte('\n') catch break :notice;
            _ = @import("stderr.zig").write(notice.buffered());
        }
        return err;
    };
}

fn resumeSession(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    // The grammar admits exactly one of REF, --session and --last.
    const reference = parsed.positional orelse parsed.get("session");
    try requireInteractiveTerminal(init, "to resume a Session");
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const paths = try platform.resolveClientPaths(init.io, try selectedStore(init, parsed.get("store"), &fallback));
    const destination = paths.store.slice();
    try startHost(init, destination, true, null);
    var selected: protocol.Bounded(protocol.max_session_bytes) = .{};
    if (reference) |value| {
        try selected.set(value);
    } else {
        var directory = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
        defer directory.close(init.io);
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace_length = try directory.realPath(init.io, &workspace_buffer);
        const workspace = workspace_buffer[0..workspace_length];
        const file = try renderScratch(init);
        defer file.close(init.io);
        var cursor: protocol_reply.SessionListCursor = .{};
        while (true) {
            try file.setLength(init.io, 0);
            try init.io.vtable.fileSeekTo(init.io.userdata, file, 0);
            var buffer: client.ReplyBuffer = .{};
            const reply = try client.listSessions(init.io, destination, workspace, cursor, file, &buffer);
            const decoded = try protocol_reply.SessionListReply.decode(init.io, file, workspace, cursor, reply);
            const page = switch (decoded) {
                .page => |*value| value,
                .failure => |failure| return failure.err(),
            };
            if (page.count != 0) selected = page.rows[page.count - 1].reference;
            cursor = page.next orelse break;
        }
        if (selected.len == 0) {
            TerminalText.diagnostic("rui: no Session in this Workspace. Run `rui` to start one, or `rui session list --all` to inspect other Workspaces.\n", .{});
            return error.SessionNotFound;
        }
    }
    return runSession(init, destination, selected.slice(), null);
}

fn sessionCommand(init: std.process.Init, requests_context: client.Requests, destination: []const u8, reference: []const u8, input_buffer: []u8) !void {
    const text = input_buffer;
    if (std.mem.eql(u8, text, "/inspect-action")) {
        const report = try inspectWork(init, requests_context, destination, reference);
        defer report.file.close(init.io);
        if (report.current.first_action) |action| {
            var buffer: [20]u8 = undefined;
            const id = try std.fmt.bufPrint(&buffer, "{d}", .{action});
            try writeSafeField(init.io, "Workspace: ", report.current.settings.workspace.slice());
            try inspectAction(init, requests_context, destination, reference, action, true);
            try std.Io.File.stdout().writeStreamingAll(init.io, "Inspection only; no decision sent.\n");
            inline for (.{ "allow", "deny" }, .{ "Allow once: ", "Deny: " }) |decision, label| {
                try std.Io.File.stdout().writeStreamingAll(init.io, label ++ "rui action " ++ decision ++ " --store ");
                try writeShellWord(init.io, destination);
                var session_buffer: [2 * protocol.max_session_bytes + 32]u8 = undefined;
                var session_writer = std.Io.File.stdout().writerStreaming(init.io, &session_buffer);
                try TerminalText.writeShellSession(&session_writer.interface, reference, false);
                try session_writer.flush();
                try std.Io.File.stdout().writeStreamingAll(init.io, " --action ");
                try std.Io.File.stdout().writeStreamingAll(init.io, id);
                try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
            }
        } else try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No actionable permission in this Current snapshot; no decision sent.\n");
        return;
    }
    if (std.mem.eql(u8, text, "/setup") or std.mem.startsWith(u8, text, "/setup ")) {
        const setup_usage = "Usage: /setup [--store PATH] [--provider codex] [--model ID | --clear-model]; no changes saved. See rui session configure --help for model IDs.\n";
        var setup_args: [6][]const u8 = undefined;
        const count = interactiveTokens(input_buffer["/setup".len..text.len], &setup_args) catch
            return std.Io.File.stdout().writeStreamingAll(init.io, setup_usage);
        var nothing = std.heap.FixedBufferAllocator.init(&.{});
        const parsed = cli_args.live_setup.parse(setup_args[0..count], nothing.allocator()) catch |err| {
            TerminalText.diagnostic("rui: /setup: {s}; active Session unchanged\n", .{@errorName(err)});
            return;
        };
        if (parsed.help) return std.Io.File.stdout().writeStreamingAll(init.io, setup_usage);
        setup(init, &parsed, true) catch |err| {
            if (err != error.UnsupportedModel) TerminalText.diagnostic("rui: /setup: {s}; active Session unchanged\n", .{@errorName(err)});
        };
    } else if (std.mem.startsWith(u8, text, "/result ")) {
        const saved = protocol_reply.MessageAddress.init(destination, reference, std.mem.trim(u8, text[8..], " ")) catch |err| {
            TerminalText.diagnostic("rui: result key: {s}\n", .{@errorName(err)});
            return;
        };
        showResult(init, requests_context, &saved) catch |err| {
            if (err == error.CanonicalStoreFailure) return err;
            TerminalText.diagnostic("rui: result: {s}\n", .{@errorName(err)});
        };
    } else if (std.mem.eql(u8, text, "/configure") or std.mem.startsWith(u8, text, "/configure ")) {
        var arguments: [20][]const u8 = undefined;
        const argument_count = interactiveTokens(input_buffer["/configure".len..text.len], &arguments) catch
            return std.Io.File.stdout().writeStreamingAll(init.io, interactive_configure_usage);
        var nothing = std.heap.FixedBufferAllocator.init(&.{});
        const parsed = cli_args.live_configure.parse(arguments[0..argument_count], nothing.allocator()) catch
            return std.Io.File.stdout().writeStreamingAll(init.io, interactive_configure_usage);
        if (parsed.help or parsed.seen == 0) return std.Io.File.stdout().writeStreamingAll(init.io, interactive_configure_usage);
        for ([_][]const u8{ "instructions", "output-schema" }) |content| if (std.mem.eql(u8, parsed.get(content) orelse "", "-"))
            return std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Terminal stdin belongs to this Session. Set instructions separately with rui session configure --instructions -; redirect schema input from a file.\n");
        configure(init, requests_context, &parsed, .{ .store = destination, .session = reference }, false) catch |err| {
            if (err == error.UnsupportedModel or err == error.InvalidLabel) return; // The pre-capture diagnostic already gives the repair.
            TerminalText.diagnostic("rui: configure: {s}; check saved requests before retrying\n", .{@errorName(err)});
            if (err == error.CanonicalStoreFailure) return err;
        };
    } else return error.UnknownArgument; // The Session frontend admits only the commands above.
}

// Decode command arguments into the editor's borrowed line. Removing quotes
// and escapes only shrinks it, so each returned slice remains valid until the
// next prompt reuses the input buffer. This is not shell expansion.
fn interactiveTokens(input: []u8, tokens: [][]const u8) !usize {
    var read: usize = 0;
    var write: usize = 0;
    var count: usize = 0;
    while (read < input.len) {
        while (read < input.len and input[read] == ' ') : (read += 1) {}
        if (read == input.len) break;
        if (count == tokens.len) return error.TooManyInteractiveArguments;
        const start = write;
        var quoted = false;
        while (read < input.len) {
            const byte = input[read];
            if (!quoted and byte == ' ') break;
            if (byte == '"') {
                quoted = !quoted;
                read += 1;
                continue;
            }
            if (byte == '\\' and read + 1 < input.len and
                (input[read + 1] == '"' or input[read + 1] == '\\' or input[read + 1] == ' ')) read += 1;
            if (input[read] < 0x20 or input[read] == 0x7f) return error.InvalidInteractiveArguments;
            input[write] = input[read];
            write += 1;
            read += 1;
        }
        if (quoted) return error.InvalidInteractiveArguments;
        tokens[count] = input[start..write];
        count += 1;
    }
    return count;
}

pub fn sessionRequests(init: std.process.Init, requester: client.Requests, store: []const u8, session_ref: []const u8, out: *std.Io.Writer) anyerror!void {
    const canonical = try platform.resolveClientPaths(init.io, store);
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &path);
    try out.writeAll("Rui: Local recovery handles (not Host work status):\n");
    var dir = std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(init.io);
    if ((try dir.stat(init.io)).permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (requester.cancellation) |token| if (token.stopped.load(.acquire)) return error.Cancelled;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const handle = entry.name[0 .. entry.name.len - ".json".len];
        const saved = savedRequest(init, handle) catch |err| switch (err) {
            error.Canceled => return err,
            else => continue,
        };
        if (!saved.store.eql(canonical.store.slice())) continue;
        if ((saved.kind == .configure or saved.kind == .message) and saved.session.len == 0) {
            var reply: client.ReplyBuffer = .{};
            const observed = try checkedObservation(init.io, try requester.observeCommand(store, saved.key.slice(), &reply), saved.key.slice());
            if (observed.status != .accepted or saved.kind != observed.kind.? or !observed.target.?.eql(session_ref)) continue;
        } else if (!saved.session.eql(session_ref)) continue;
        try out.writeAll("  ");
        try writeSafeTextTo(out, handle);
        try out.writeAll(" (");
        try writeSafeTextTo(out, @tagName(saved.kind));
        try out.writeAll(")\n");
    }
}

test "local recovery enumeration observes cancellation before skipping invalid records" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store_directory = try tmp.dir.createDirPathOpen(io, "store", .{ .permissions = .fromMode(0o700) });
    defer store_directory.close(io);
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
    var directory = try tmp.dir.createDirPathOpen(io, ".config/rui/requests", .{ .permissions = .fromMode(0o700) });
    defer directory.close(io);
    const file = try directory.createFile(io, "invalid.json", .{ .permissions = .fromMode(0o600) });
    file.close(io);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", home);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = [_][*:0]const u8{"rui"};
    const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &argv }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = io, .environ_map = &environment, .preopens = .empty };
    var store_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = try std.fmt.bufPrint(&store_buffer, "{s}/store", .{home});
    var token: client.Cancellation = .{};
    const requester: client.Requests = .{ .io = io, .cancellation = &token };
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try sessionRequests(init, requester, store, "original/session", &out);
    token.requestStop();
    try std.testing.expectError(error.Cancelled, sessionRequests(init, requester, store, "original/session", &out));
}

fn stopSession(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    const io = init.io;
    var input = client.SessionStopInput{ .store = "", .session = parsed.get("session").? };
    if (input.session.len == 0) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, parsed.get("store"), &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = try captureTarget(init, parsed, &directory_buffer);
    var captured = try client.captureSessionStop(io, input, target);
    try sendCapturedMutation(.{ .io = io, .drop_reply = parsed.get("test-drop-reply") }, &captured, target, null);
}

fn interruptModel(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    const io = init.io;
    var input = client.ModelInterruptionInput{ .store = "", .session = parsed.get("session").?, .turn_id = (try parsed.number(u64, "turn")).?, .operation_id = (try parsed.number(u64, "operation")).? };
    if (input.session.len == 0) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, parsed.get("store"), &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = try captureTarget(init, parsed, &directory_buffer);
    var captured = try client.captureModelInterruption(io, input, target);
    try sendCapturedMutation(.{ .io = io, .drop_reply = parsed.get("test-drop-reply") }, &captured, target, null);
}

// One-shot mutations announce a generated handle on stderr before original
// transmission; failed announcement leaves the durable capture unsent.
fn sendCapturedMutation(sender: client.Requests, captured: *client.CapturedRecord, target: client.CaptureTarget, reported: ?*?client.Step) !void {
    const io = sender.io;
    var unreported: ?client.Step = null;
    const step = reported orelse &unreported;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(io);
        if (target == .generated) try announceCapture(io, captured.identity().key.slice());
        break :blk try takeReply(step, sender.sendCaptured(captured, &reply_buffer));
    };
    try writeMutationReply(io, reply, .{ .json = .of(target) });
}

fn decideAction(init: std.process.Init, parsed: *const cli_args.Parsed, decision: @FieldType(client.PermissionDecisionInput, "decision")) !void {
    const io = init.io;
    var input = client.PermissionDecisionInput{
        .store = "",
        .session = parsed.get("session").?,
        .action_id = (try parsed.number(u64, "action")).?,
        .decision = decision,
    };
    if (input.session.len == 0) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, parsed.get("store"), &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = try captureTarget(init, parsed, &directory_buffer);
    var captured = try client.capturePermissionDecision(io, input, target);
    try sendCapturedMutation(.{ .io = io, .drop_reply = parsed.get("test-drop-reply") }, &captured, target, null);
}

fn observe(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    const io = init.io;
    const identity = try requestIdentity(init, parsed);
    const target = identity.key.slice();
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.observeCommand(io, identity.store.slice(), target, &reply_buffer);
    const observation = try checkedObservation(io, reply, target);
    var output: JsonOutput = undefined;
    const writer = output.init(io, .stdout);
    try writer.writeAll("{\"version\":\"1\",\"type\":\"command_observation\",\"key\":");
    try std.json.Stringify.value(observation.key.slice(), .{}, writer);
    try writer.writeAll(",\"observation\":");
    try observation.writeJson(writer);
    try writer.writeAll("}\n");
    try output.finish();
}

fn inspect(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    const io = init.io;
    if (parsed.get("failed-response")) |part| {
        const selection: protocol.FailedResponseExport = .{
            .part = std.meta.stringToEnum(protocol.FailedResponsePart, part) orelse return error.InvalidArguments,
            .operation = (try parsed.number(u64, "operation")) orelse return error.InvalidArguments,
            .attempt = (try parsed.number(u64, "attempt")) orelse return error.InvalidArguments,
        };
        var store_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var response: client.ReplyBuffer = .{};
        const reply = try (client.Requests{ .io = io }).exportFailedResponse(try selectedStore(init, parsed.get("store"), &store_buffer), parsed.get("session").?, selection, std.Io.File.stdout(), &response);
        if (reply == .command) {
            try writeCommandReply(io, reply.command, .stderr);
            return error.HostInvocationFailed;
        }
        return;
    }
    if (parsed.get("operation") != null or parsed.get("attempt") != null) return error.InvalidArguments;
    const profile: protocol.ReportProfile = if (parsed.get("profile")) |value|
        std.meta.stringToEnum(protocol.ReportProfile, value) orelse return error.UnknownReportProfile
    else
        .current;
    const reference = parsed.get("session").?;
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected_store = try selectedStore(init, parsed.get("store"), &selected_buffer);
    if (profile == .current) {
        const file = try renderScratch(init);
        defer file.close(io);
        var response: client.ReplyBuffer = .{};
        const wire_reply = try client.inspectSession(io, selected_store, reference, .current, file, &response);
        const reply = try protocol_reply.CurrentReply.decode(io, file, reference, wire_reply);
        if (reply == .failure) {
            try writeCommandReply(io, wire_reply.command, .stdout);
            return reply.failure.err();
        }
        var output: JsonOutput = undefined;
        const writer = output.init(io, .stdout);
        try reply.writeJson(io, file, writer);
        try writer.writeAll("\n");
        return output.finish();
    }
    var reply_buffer: client.ReplyBuffer = .{};
    var output: JsonOutput = undefined;
    var sink: JsonOutput.Sink = .{ .writer = output.init(io, .stdout) };
    const reply = try (client.Requests{ .io = io }).inspectSession(selected_store, reference, profile, &sink, &reply_buffer);
    switch (reply) {
        .report => {
            try sink.writer.writeAll("\n");
            try output.finish();
        },
        .command => |command_reply| {
            try writeCommandReply(io, command_reply, .stdout);
            return error.HostInvocationFailed;
        },
    }
}

fn readConversation(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    const reference = parsed.get("session").?;
    const target = (try parsed.number(u64, "position")).?;
    const item = (try parsed.number(u64, "ordinal")).?;
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const requests_: client.Requests = .{ .io = init.io };
    if (try requests_.readConversationContent(try selectedStore(init, parsed.get("store"), &selected_buffer), reference, target, item, null, std.Io.File.stdout())) |failure| {
        try writeReadFailure(init.io, failure, reference, .stderr);
        return failure.err();
    }
}

test "hex selector bounds are the protocol's identity bounds" {
    inline for (comptime std.meta.tags(cli_args.Command)) |command| for (command.definition().options) |option| {
        if (option.hex_of) |named| try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, named, "store")) protocol.max_store_bytes else if (std.mem.eql(u8, named, "session")) protocol.max_session_bytes else protocol.max_key_bytes), option.hex_limit);
    };
}

fn readResult(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    const io = init.io;
    const identity = try requestIdentity(init, parsed);
    const target = identity.key.slice();
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.readResult(
        io,
        identity.store.slice(),
        target,
        std.Io.File.stdout(),
        &reply_buffer,
    );
    switch (reply) {
        .answer => {},
        .failure => |failure| {
            try writeReadFailure(io, failure, target, .stderr);
            return failure.err();
        },
    }
}

fn readActionContent(init: std.process.Init, parsed: *const cli_args.Parsed, field: enum { call_id, arguments }) !void {
    const io = init.io;
    const reference = parsed.get("session").?;
    const target = (try parsed.number(u64, "action")).?;
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, parsed.get("store"), &selected_buffer);
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = switch (field) {
        .call_id => try client.readActionCallId(io, selected, reference, target, std.Io.File.stdout(), &reply_buffer),
        .arguments => try client.readActionArguments(io, selected, reference, target, std.Io.File.stdout(), &reply_buffer),
    };
    switch (reply) {
        .answer => {},
        .command => |command_reply| {
            try writeCommandReply(io, command_reply, .stderr);
            return error.HostInvocationFailed;
        },
    }
}

/// Every JSON value Rui writes for people or callers to read passes here:
/// metadata on stdout, and failure diagnostics of content readers on stderr.
/// Explicit content readers stream raw bytes and never use it.
const JsonOutput = struct {
    file: std.Io.File.Writer,
    escaping: json_ascii.Escaping,
    file_buffer: [protocol.content_window_bytes]u8,
    escape_buffer: [protocol.content_window_bytes]u8,

    const Stream = enum { stdout, stderr };

    /// A synchronous client sink for JSON a Host streams, such as Full reports.
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn feed(self: *Sink, bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };

    fn init(self: *JsonOutput, io: std.Io, stream: Stream) *std.Io.Writer {
        const file = if (stream == .stdout) std.Io.File.stdout() else std.Io.File.stderr();
        self.file = file.writerStreaming(io, &self.file_buffer);
        self.escaping = .init(&self.file.interface, &self.escape_buffer);
        return &self.escaping.writer;
    }

    fn finish(self: *JsonOutput) !void {
        self.escaping.finish() catch |err| return self.failure(err);
    }

    /// The cause behind a writer failure: invalid text or the file's error.
    fn failure(self: *JsonOutput, err: anyerror) anyerror {
        if (self.escaping.invalid) return error.InvalidResponse;
        return self.file.err orelse err;
    }
};

fn writeCommandReply(io: std.Io, reply: protocol_reply.CommandReply, stream: JsonOutput.Stream) !void {
    var output: JsonOutput = undefined;
    const writer = output.init(io, stream);
    writer.writeAll(reply.body) catch |err| return output.failure(err);
    writer.writeAll("\n") catch |err| return output.failure(err);
    try output.finish();
    try protocol_reply.checkCanonicalFailure(reply);
}

fn writeReadFailure(io: std.Io, failure: protocol_reply.ReadFailure, key: []const u8, stream: JsonOutput.Stream) !void {
    var output: JsonOutput = undefined;
    const writer = output.init(io, stream);
    std.json.Stringify.value(.{ .key = key, .@"error" = .{
        .status = failure.status,
        .type = failure.diagnostic.type.slice(),
        .code = failure.diagnostic.code.slice(),
    } }, .{}, writer) catch |err| return output.failure(err);
    writer.writeByte('\n') catch |err| return output.failure(err);
    try output.finish();
}

fn checkedObservation(io: std.Io, reply: protocol_reply.ObservationReply, key: []const u8) !protocol_reply.CommandObservation {
    return switch (reply) {
        .observation => |observation| observation,
        .failure => |failure| {
            try writeReadFailure(io, failure, key, .stdout);
            return failure.err();
        },
    };
}

fn requestDirectory(init: std.process.Init, buffer: []u8) ![]const u8 {
    const home = init.environ_map.get("HOME") orelse return homeRequired("generated request captures live under HOME/.config/rui/requests; mutations can instead use explicit --record FILE --key KEY");
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHome;
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/requests", .{home});
}

fn announceCapture(io: std.Io, handle: []const u8) !void {
    try testGate(io, "RUI_TEST_CAPTURE_GATE");
    // Checked announcement precedes original transmission. Failure retains the
    // durable capture, but cannot submit unannounced work. stdout stays one
    // complete JSON receipt.
    var line: [64 + 3 * protocol.max_key_bytes]u8 = undefined;
    try std.Io.File.stderr().writeStreamingAll(io, try std.fmt.bufPrint(&line, "request: {s} (inspect: rui request inspect {s}; if unconfirmed: rui request recover {s})\n", .{ handle, handle, handle }));
}

fn testGate(io: std.Io, name: [*:0]const u8) !void {
    const gate = std.c.getenv(name) orelse return;
    const path = std.mem.span(gate);
    var ready_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var release_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ready = try std.fmt.bufPrint(&ready_buffer, "{s}.ready", .{path});
    const release = try std.fmt.bufPrint(&release_buffer, "{s}.release", .{path});
    const marker = try std.Io.Dir.cwd().createFile(io, ready, .{ .exclusive = true });
    marker.close(io);
    while (true) {
        if (std.Io.Dir.cwd().statFile(io, release, .{})) |_| break else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}

/// How a caller replays a saved answer: by its generated handle, or by the
/// explicit record it captured to.
const Replay = union(enum) {
    generated,
    explicit: []const u8,

    fn of(target: client.CaptureTarget) Replay {
        return switch (target) {
            .generated => .generated,
            .explicit => |explicit| .{ .explicit = explicit.record },
        };
    }
};

const MutationPresentation = union(enum) {
    json: Replay,
    human,
    interactive_configuration,
};

fn writeMutationReply(io: std.Io, reply: protocol_reply.MutationReply, presentation: MutationPresentation) !void {
    if (reply.answer) |answer| {
        if (answer.result == .rejected and answer.result.rejected.eql("unknown_session"))
            TerminalText.diagnostic("rui: no session {s} in this Store\n", .{reply.context.session.slice()});
    } else |_| {}
    if (presentation == .json) {
        var output: JsonOutput = undefined;
        presentMutationReply(output.init(io, .stdout), reply, presentation) catch |err| {
            const cause = output.failure(err);
            if (cause == error.MutationNotAccepted) reportNotAccepted(reply.context, presentation.json);
            return cause;
        };
        return output.finish();
    }
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
    presentMutationReply(&output.interface, reply, presentation) catch |err| return output.err orelse err;
}

/// Names the replay the caller actually holds: a generated handle, or the
/// explicit record, since repeating its capture refuses the existing --record.
fn reportNotAccepted(context: protocol_reply.MutationIdentity, replay: Replay) void {
    var bytes: [4 * (protocol.max_store_bytes + std.Io.Dir.max_path_bytes) + 512]u8 = undefined;
    var notice = std.Io.Writer.fixed(&bytes);
    writeNotAccepted(&notice, context, replay) catch return;
    TerminalText.diagnostic("{s}", .{notice.buffered()});
}

fn writeNotAccepted(notice: *std.Io.Writer, context: protocol_reply.MutationIdentity, replay: Replay) !void {
    try notice.writeAll("rui: the Host did not accept this request; stdout carries its saved answer and code. Replay returns that same answer and never resubmits: rui request recover ");
    switch (replay) {
        // validRequestHandle admits only shell-inert handle bytes.
        .generated => try notice.writeAll(context.key.slice()),
        .explicit => |record| {
            try notice.writeAll("--store ");
            try TerminalText.writeShellWord(notice, context.store.slice());
            try notice.writeAll(" --record ");
            try TerminalText.writeShellWord(notice, record);
            switch (context.kind) {
                inline else => |kind| try notice.print(" --kind {s}", .{comptime retryName(kind)}),
            }
        },
    }
    try notice.writeByte('\n');
}

fn writeMutationField(writer: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try writer.writeAll(label);
    var text: TerminalText = .{ .mode = .line };
    try text.feed(writer, value);
    try text.finish(writer);
    try writer.writeByte('\n');
}

fn presentMutationReply(writer: *std.Io.Writer, reply: protocol_reply.MutationReply, presentation: MutationPresentation) !void {
    if (presentation == .interactive_configuration and reply.isAccepted()) {
        try writer.writeAll("Rui: Configured.\n");
        return writer.flush();
    }
    if (presentation == .json) {
        try writeMutationJson(writer, reply);
        try writer.writeByte('\n');
        try writer.flush();
        _ = try reply.answer;
        // A complete saved rejection or conflict is delivered, but the
        // mutation was not admitted.
        if (!reply.isAccepted()) return error.MutationNotAccepted;
        return;
    }
    try writeMutationField(writer, "Store: ", reply.context.store.slice());
    try writeMutationField(writer, "Session: ", reply.context.session.slice());
    try writeMutationField(writer, "key: ", reply.context.key.slice());
    switch (reply.target) {
        .model_interruption => |target| try writer.print("target Turn: {d}; Operation: {d}\n", .{ target.turn, target.operation }),
        .permission_decision => |target| try writer.print("target Action: {d}; decision: {s}\n", .{ target.action, @tagName(target.decision) }),
        else => {},
    }
    const answer = reply.answer catch |err| {
        try writer.print("invocation: {s} (HTTP {d}); outcome unconfirmed\n", .{ @errorName(err), reply.status });
        if (reply.diagnostic) |diagnostic| {
            try writeMutationField(writer, "type: ", diagnostic.type.slice());
            try writeMutationField(writer, "code: ", diagnostic.code.slice());
        }
        try writer.flush();
        return err;
    };
    try writer.print("admitted: {s}\n", .{@tagName(answer.result)});
    try writer.writeAll(if (answer.replayed) "replayed: true\n" else "replayed: false\n");
    const code: ?[]const u8 = switch (answer.result) {
        .accepted => null,
        .rejected => |*code| code.slice(),
        .conflict => "idempotency_key_conflict",
    };
    if (code) |value| try writeMutationField(writer, "code: ", value);
    if (answer.result == .accepted) switch (answer.result.accepted) {
        .configure => |value| try writer.print("revision: {d}; created: {}\n", .{ value.revision, value.created }),
        .message => |value| try writer.print("queue admission: {d}\n", .{value.admission}),
        .session_stop => |value| {
            if (value.turn) |turn| try writer.print("selected Turn: {d}\n", .{turn}) else try writeMutationField(writer, "selected Turn: ", "none");
            try writer.print("admission cutoff: {d}; completion: {s}\n", .{ value.admission_cutoff, @tagName(value.completion) });
        },
        .model_interruption, .permission_decision => {},
    };
    try writer.flush();
}

// Presentation of owned facts only: no wire representation or second parser.
fn writeMutationJson(writer: *std.Io.Writer, reply: protocol_reply.MutationReply) !void {
    try writer.writeAll("{\"context\":");
    try std.json.Stringify.value(.{
        .store = reply.context.store.slice(),
        .session = reply.context.session.slice(),
        .key = reply.context.key.slice(),
        .kind = @tagName(reply.context.kind),
    }, .{}, writer);
    switch (reply.target) {
        .model_interruption => |target| try writer.print(",\"request_target\":{{\"turn\":\"{d}\",\"operation\":\"{d}\"}}", .{ target.turn, target.operation }),
        .permission_decision => |target| try writer.print(",\"request_target\":{{\"action\":\"{d}\",\"decision\":\"{s}\"}}", .{ target.action, @tagName(target.decision) }),
        else => {},
    }
    const answer = reply.answer catch |err| {
        try writer.print(",\"error\":{{\"status\":\"{d}\",\"reason\":\"{s}\",\"certainty\":\"unconfirmed\",\"type\":", .{ reply.status, @errorName(err) });
        try std.json.Stringify.value(if (reply.diagnostic) |diagnostic| diagnostic.type.slice() else null, .{}, writer);
        try writer.writeAll(",\"code\":");
        try std.json.Stringify.value(if (reply.diagnostic) |diagnostic| diagnostic.code.slice() else null, .{}, writer);
        try writer.writeAll("}}");
        return;
    };
    try writer.print(",\"answer\":{{\"status\":\"{s}\",\"replayed\":{}", .{ @tagName(answer.result), answer.replayed });
    if (reply.target == .model_interruption) {
        try writer.writeAll(",\"target\":{\"session\":");
        try std.json.Stringify.value(reply.context.session.slice(), .{}, writer);
        try writer.print(",\"turn\":\"{d}\",\"operation\":\"{d}\"}}", .{ reply.target.model_interruption.turn, reply.target.model_interruption.operation });
    } else {
        try writer.writeAll(",\"session\":");
        try std.json.Stringify.value(reply.context.session.slice(), .{}, writer);
    }
    if (reply.target == .permission_decision) try writer.print(",\"action\":\"{d}\",\"decision\":\"{s}\"", .{ reply.target.permission_decision.action, @tagName(reply.target.permission_decision.decision) });
    switch (answer.result) {
        .accepted => |accepted| switch (accepted) {
            .configure => |value| try writer.print(",\"revision\":\"{d}\",\"created\":{}", .{ value.revision, value.created }),
            .message => |value| try writer.print(",\"admission\":\"{d}\"", .{value.admission}),
            .session_stop => |value| {
                try writer.writeAll(",\"selection\":{\"turn\":");
                if (value.turn) |turn| try writer.print("\"{d}\"", .{turn}) else try writer.writeAll("null");
                try writer.print(",\"admission_cutoff\":\"{d}\"}}", .{value.admission_cutoff});
            },
            .model_interruption, .permission_decision => {},
        },
        .rejected => |code| {
            try writer.writeAll(",\"code\":");
            try std.json.Stringify.value(code.slice(), .{}, writer);
        },
        .conflict => try writer.writeAll(",\"code\":\"idempotency_key_conflict\""),
    }
    try writer.writeByte('}');
    if (reply.target == .message and answer.result != .conflict) {
        const input = reply.target.message;
        try writer.print(",\"input\":{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"{s}\"}}", .{ input.bytes, std.fmt.bytesToHex(input.digest, .lower) });
        if (answer.result == .accepted) try writer.print(",\"queue\":{{\"status\":\"queued\",\"admission\":\"{d}\"}}", .{answer.result.accepted.message.admission});
    }
    if (reply.target == .session_stop) try writer.print(",\"completion\":{{\"status\":\"{s}\"}}", .{if (answer.result == .accepted) @tagName(answer.result.accepted.session_stop.completion) else "unavailable"});
    try writer.writeByte('}');
}

test "mutation presentation renders owned diagnostics and context with bounded writer" {
    const wire = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"busy\\u002fµ\",\"wire_only\":true}";
    var bytes: [wire.len]u8 = wire.*;
    var reply = protocol_reply.decodeMutationReply(.{ .status = 409, .body = &bytes }, "original/session", .configure);
    try reply.context.store.set("/store");
    try reply.context.key.set("original\"key");
    reply.context.kind = .configure;
    @memset(&bytes, 'x');
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeMutationJson(&writer, reply);
    try std.testing.expectEqualStrings("{\"context\":{\"store\":\"/store\",\"session\":\"original/session\",\"key\":\"original\\\"key\",\"kind\":\"configure\"},\"error\":{\"status\":\"409\",\"reason\":\"HostInvocationFailed\",\"certainty\":\"unconfirmed\",\"type\":\"invocation_error\",\"code\":\"busy/µ\"}}", writer.buffered());
    var tiny: [1]u8 = undefined;
    var failing = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, writeMutationJson(&failing, reply));
}

test "mutation presentation complete modes preserve escaped original context" {
    const accepted_wire = "{\"version\":\"1\",\"type\":\"configuration_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"revision\":\"7\",\"created\":true},\"execution\":{\"status\":\"unavailable\",\"reason\":\"direct_reply_does_not_wait_for_model_processing\"},\"wire_only\":true}";
    const failed_wire = "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"capacity\\n\\u001b\",\"wire_only\":true}";
    const context = "{\"store\":\"/store\",\"session\":\"k7m2qx\",\"key\":\"key/µ\\\"\\n\\u001b\",\"kind\":\"configure\"}";
    const accepted_json = "{\"context\":" ++ context ++ ",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\",\"revision\":\"7\",\"created\":true}}";
    const failed_json = "{\"context\":" ++ context ++ ",\"error\":{\"status\":\"503\",\"reason\":\"HostInvocationFailed\",\"certainty\":\"unconfirmed\",\"type\":\"busy\",\"code\":\"capacity\\n\\u001b\"}}";
    const human_context = "Store: /store\nSession: k7m2qx\nkey: key/µ\\\"\\n\\x1b\n";
    const failed_human = human_context ++ "invocation: HostInvocationFailed (HTTP 503); outcome unconfirmed\ntype: busy\ncode: capacity\\n\\x1b\n";
    const modes = [_]MutationPresentation{ .{ .json = .generated }, .human, .interactive_configuration };
    const accepted_expected = [_][]const u8{
        accepted_json ++ "\n",
        human_context ++ "admitted: accepted\nreplayed: false\nrevision: 7; created: true\n",
        "Rui: Configured.\n",
    };
    const failed_expected = [_][]const u8{
        failed_json ++ "\n",
        failed_human,
        failed_human,
    };
    for ([_]bool{ false, true }) |failed| {
        var reply = protocol_reply.decodeMutationReply(.{ .status = if (failed) 503 else 200, .body = if (failed) failed_wire else accepted_wire }, "k7m2qx", .configure);
        try reply.context.store.set("/store");
        try reply.context.key.set("key/µ\"\n\x1b");
        reply.context.kind = .configure;
        for (modes, 0..) |mode, index| {
            var buffer: [2048]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            if (failed) try std.testing.expectError(error.HostInvocationFailed, presentMutationReply(&writer, reply, mode)) else try presentMutationReply(&writer, reply, mode);
            try std.testing.expectEqualStrings(if (failed) failed_expected[index] else accepted_expected[index], writer.buffered());
            var tiny: [1]u8 = undefined;
            var failing = std.Io.Writer.fixed(&tiny);
            try std.testing.expectError(error.WriteFailed, presentMutationReply(&failing, reply, mode));
            // All bytes fit: only final delivery fails, before success or the invocation error returns.
            var flush_failure: std.Io.Writer = .{ .buffer = &buffer, .vtable = &.{ .drain = struct {
                fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
                    return error.WriteFailed;
                }
            }.drain } };
            try std.testing.expectError(error.WriteFailed, presentMutationReply(&flush_failure, reply, mode));
            try std.testing.expectEqualStrings(if (failed) failed_expected[index] else accepted_expected[index], flush_failure.buffered());
        }
    }
}

test "mutation presentation wrong binding keeps caller context even interactively" {
    const wire = "{\"version\":\"1\",\"type\":\"configuration_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"foreign\",\"revision\":\"7\",\"created\":true}}";
    var reply = protocol_reply.decodeMutationReply(.{ .status = 200, .body = wire }, "original", .configure);
    try reply.context.store.set("/original-store");
    try reply.context.key.set("original-key");
    reply.context.kind = .configure;
    var buffer: [1024]u8 = undefined;
    for ([_]MutationPresentation{ .human, .interactive_configuration }) |mode| {
        var writer = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.RequestBindingMismatch, presentMutationReply(&writer, reply, mode));
        try std.testing.expectEqualStrings("Store: /original-store\nSession: original\nkey: original-key\ninvocation: RequestBindingMismatch (HTTP 200); outcome unconfirmed\n", writer.buffered());
    }
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.RequestBindingMismatch, presentMutationReply(&writer, reply, .{ .json = .generated }));
    try std.testing.expectEqualStrings("{\"context\":{\"store\":\"/original-store\",\"session\":\"original\",\"key\":\"original-key\",\"kind\":\"configure\"},\"error\":{\"status\":\"200\",\"reason\":\"RequestBindingMismatch\",\"certainty\":\"unconfirmed\",\"type\":null,\"code\":null}}\n", writer.buffered());
}

test "not-accepted guidance names the generated handle or the quoted explicit recover form" {
    var context: protocol_reply.MutationIdentity = .{ .kind = .session_stop };
    try context.store.set("/it's \\store");
    try context.key.set("0f8fad5b-d9cb-469f-a165-70867728950e");
    var buffer: [512]u8 = undefined;
    const prefix = "rui: the Host did not accept this request; stdout carries its saved answer and code. Replay returns that same answer and never resubmits: rui request recover ";
    var generated = std.Io.Writer.fixed(&buffer);
    try writeNotAccepted(&generated, context, .generated);
    try std.testing.expectEqualStrings(prefix ++ "0f8fad5b-d9cb-469f-a165-70867728950e\n", generated.buffered());
    var explicit = std.Io.Writer.fixed(&buffer);
    try writeNotAccepted(&explicit, context, .{ .explicit = "stop\x1b.json" });
    try std.testing.expectEqualStrings(prefix ++ "--store $'/it\\'s \\\\store' --record $'stop\\033.json' --kind session-stop\n", explicit.buffered());
}

const SavedRequest = protocol_reply.MutationIdentity;

fn savedRequest(init: std.process.Init, handle: []const u8) !SavedRequest {
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return client.inspectCaptured(init.io, try requestDirectory(init, &directory_buffer), handle);
}

/// The Store and key a request command names, from a saved handle or flags.
const RequestIdentity = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},
};

fn requestIdentity(init: std.process.Init, parsed: *const cli_args.Parsed) !RequestIdentity {
    if (parsed.positional) |handle| {
        const saved = try savedRequest(init, handle);
        return .{ .store = saved.store, .key = saved.key };
    }
    var identity: RequestIdentity = .{};
    try identity.key.set(parsed.get("key").?);
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try identity.store.set(try selectedStore(init, parsed.get("store"), &selected_buffer));
    return identity;
}

fn sessionPage(init: std.process.Init, store: []const u8, workspace: ?[]const u8, traversal: *protocol_reply.SessionTraversal, first: bool, writer: *std.Io.Writer) !struct { count: usize, more: bool } {
    const file = try renderScratch(init);
    defer file.close(init.io);
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.listSessions(init.io, store, workspace, traversal.cursor, file, &buffer);
    const decoded = try protocol_reply.SessionListReply.decode(init.io, file, workspace, traversal.cursor, reply);
    const page = switch (decoded) {
        .page => |*page| page,
        .failure => |failure| {
            var bytes: [256]u8 = undefined;
            var diagnostic = std.Io.File.stderr().writerStreaming(init.io, &bytes);
            try std.json.Stringify.value(.{ .status = failure.status, .type = failure.diagnostic.type.slice(), .code = failure.diagnostic.code.slice() }, .{}, &diagnostic.interface);
            try diagnostic.interface.writeAll("\n");
            try diagnostic.interface.flush();
            return failure.err();
        },
    };
    if (!first and page.count != 0) try writer.writeByte(',');
    try page.writeRowsJson(writer);
    return .{ .count = page.count, .more = traversal.advance(page) };
}

/// A token from an earlier listing's `since`.
fn sinceArgument(text: []const u8) error{InvalidSince}!protocol.SinceToken {
    return protocol.SinceToken.parse(text) catch {
        _ = @import("stderr.zig").write("rui: --since takes the since value of an earlier rui session list, unchanged.\n");
        return error.InvalidSince;
    };
}

fn sessions(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    const since = if (parsed.get("since")) |text| try sinceArgument(text) else null;
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = try selectedStore(init, parsed.get("store"), &selected_buffer);
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace: ?[]const u8 = if (parsed.has("all")) null else blk: {
        var directory = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
        defer directory.close(init.io);
        const length = try directory.realPath(init.io, &workspace_buffer);
        break :blk workspace_buffer[0..length];
    };
    // Bounded pages stream into one final JSON value; no page population is
    // retained. A failed later page leaves incomplete output and exits nonzero.
    // A changed listing that turns full goes on as that full listing, so a
    // reference may appear twice; the later row replaces the earlier.
    var traversal = protocol_reply.SessionTraversal.init(since);
    var output: JsonOutput = undefined;
    const writer = output.init(init.io, .stdout);
    try writer.writeAll("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[");
    var first = true;
    while (true) {
        const page = try sessionPage(init, store, workspace, &traversal, first, writer);
        if (page.count != 0) first = false;
        if (!page.more) break;
    }
    var token: [protocol.SinceToken.max_bytes]u8 = undefined;
    try writer.print("],\"delta\":\"{t}\",\"since\":\"{s}\",\"next\":null}}\n", .{ traversal.delta, traversal.since.?.format(&token) });
    try output.finish();
}

fn requests(init: std.process.Init) !void {
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &path);
    var dir = std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return std.Io.File.stdout().writeStreamingAll(init.io, "[]\n"),
        else => return err,
    };
    defer dir.close(init.io);
    if ((try dir.stat(init.io)).permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
    var bytes: [protocol.content_window_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &bytes);
    try output.interface.writeByte('[');
    var first = true;
    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const handle = entry.name[0 .. entry.name.len - ".json".len];
        if (!client.validRequestHandle(handle)) continue;
        if (!first) try output.interface.writeByte(',');
        try std.json.Stringify.value(handle, .{}, &output.interface);
        first = false;
    }
    try output.interface.writeAll("]\n");
    try output.flush();
}

fn recover(init: std.process.Init, parsed: *const cli_args.Parsed) !void {
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // The grammar requires --store, --record and --kind together.
    const saved: client.SavedRecord = if (parsed.positional) |handle|
        .{ .generated = .{ .directory = try requestDirectory(init, &directory_buffer), .handle = handle } }
    else blk: {
        const store = parsed.get("store").?;
        const kind = parseRetryName(parsed.get("kind").?) orelse {
            // The Store is resolved before the kind is read, so its failure stays first.
            _ = try platform.resolveClientPaths(init.io, store);
            return error.InvalidRetryKind;
        };
        break :blk .{ .explicit = .{ .store = store, .record = parsed.get("record").?, .kind = kind } };
    };
    var captured = try client.openCaptured(init.io, saved);
    var buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(init.io);
        break :blk try (client.Requests{ .io = init.io }).sendCaptured(&captured, &buffer).get();
    };
    try writeMutationReply(init.io, reply, .{ .json = switch (saved) {
        .generated => .generated,
        .explicit => |explicit| .{ .explicit = explicit.record },
    } });
}

/// A command kind in its `rui request recover --kind` spelling.
fn parseRetryName(name: []const u8) ?protocol.CommandKind {
    inline for (comptime std.enums.values(protocol.CommandKind)) |kind| {
        if (std.mem.eql(u8, name, comptime retryName(kind))) return kind;
    }
    return null;
}

fn retryName(comptime kind: protocol.CommandKind) []const u8 {
    comptime {
        var name = @tagName(kind)[0..@tagName(kind).len].*;
        std.mem.replaceScalar(u8, &name, '_', '-');
        const final = name;
        return &final;
    }
}

test "recover accepts only the hyphenated spelling of each command kind" {
    inline for (comptime std.enums.values(protocol.CommandKind)) |kind|
        try std.testing.expectEqual(@as(?protocol.CommandKind, kind), parseRetryName(comptime retryName(kind)));
    inline for (.{ "session_stop", "model_interruption", "permission_decision", "Message", "", "configure-" }) |name|
        try std.testing.expectEqual(@as(?protocol.CommandKind, null), parseRetryName(name));
}

fn showResult(init: std.process.Init, requester: client.Requests, saved: *const protocol_reply.MessageAddress) !void {
    const observed = try checkedObservation(init.io, try requester.observeMessage(saved), saved.key.slice());
    const state = observed.state();
    var line: [256]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "admitted: {s}\nresult: {s}\n", .{ @tagName(observed.status), @tagName(state) }));
    if (observed.failureCode()) |code| try writeSafeField(init.io, "code: ", code);
    if (state != .completed) return;
    var read_buffer: client.ReplyBuffer = .{};
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var renderer: AnswerRenderer = .{ .out = &output.interface };
    const answer = blk: {
        // Abandon retained text and pending writer bytes on failure. A renderer
        // transition may be buffered, so tracked style cannot prove terminal state.
        // Reset alone, before diagnostics; failed cleanup retains the original error.
        errdefer _ = std.c.write(1, "\x1b[0m", 4);
        const answer = try requester.readResultStream(saved.store.slice(), saved.key.slice(), &renderer, &read_buffer);
        if (answer == .answer) {
            try renderer.finish();
            try output.flush();
        } else _ = std.c.write(1, "\x1b[0m", 4);
        break :blk answer;
    };
    if (answer == .failure) {
        try writeReadFailure(init.io, answer.failure, saved.key.slice(), .stdout);
        return answer.failure.err();
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn renderScratch(init: std.process.Init) !std.Io.File {
    const path = init.environ_map.get("TMPDIR") orelse "/tmp";
    if (!std.fs.path.isAbsolute(path)) return error.InvalidTemporaryDirectory;
    const dir = try std.Io.Dir.cwd().openDir(init.io, path, .{});
    defer dir.close(init.io);
    return createRenderScratch(init.io, dir, false);
}

fn createRenderScratch(io: std.Io, dir: std.Io.Dir, fail_unlink: bool) !std.Io.File {
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "rui-render-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
    const file = try dir.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    // Scratch is descriptor-owned: interrupted clients leave no named payload.
    if (fail_unlink) return error.RenderScratchCleanupFailed;
    dir.deleteFile(io, name) catch return error.RenderScratchCleanupFailed;
    return file;
}

const SessionObservation = struct {
    current: protocol_reply.Current,
    // The complete Current capture remains owned until all its permissions
    // have been displayed; no per-Action resident list is needed.
    file: std.Io.File,
};

fn inspectWork(init: std.process.Init, requester: client.Requests, store: []const u8, session_ref: []const u8) !SessionObservation {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    // A typed inspection failure stays primary if diagnostic flushing fails.
    defer writer.flush() catch {};
    const report = try inspectWorkTo(init, requester, store, session_ref, &writer.interface);
    errdefer report.file.close(init.io);
    try writer.flush();
    return report;
}

fn inspectWorkTo(init: std.process.Init, requester: client.Requests, store: []const u8, session_ref: []const u8, out: *std.Io.Writer) !SessionObservation {
    const file = try renderScratch(init);
    errdefer file.close(init.io);
    var response: client.ReplyBuffer = .{};
    const reply = try requester.inspectSession(store, session_ref, .current, file, &response);
    switch (try protocol_reply.CurrentReply.decode(init.io, file, session_ref, reply)) {
        .current => |current| return .{ .current = current, .file = file },
        .unconfigured => return error.SessionNotConfigured,
        .failure => |failure| {
            if (requester.read_failure != null) return requester.failRead(failure);
            try out.writeAll(reply.command.body);
            try out.writeByte('\n');
            try protocol_reply.checkCanonicalFailure(reply.command);
            return failure.err();
        },
    }
}

fn renderActionable(io: std.Io, current: *const protocol_reply.Current, file: std.Io.File, out: *std.Io.Writer) !void {
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn visit(self: *@This(), row: protocol_reply.Current.Attention) !void {
            if (row == .actionable) {
                var buffer: [20]u8 = undefined;
                try writeSafeFieldTo(self.out, "Action requiring attention: ", try std.fmt.bufPrint(&buffer, "{d}", .{row.actionable.action.value}));
            }
        }
    };
    var sink: Sink = .{ .out = out };
    try current.traverse(io, file, &sink);
}

fn inspectAction(init: std.process.Init, requester: client.Requests, store: ?[]const u8, reference: []const u8, target: u64, interactive: bool) !void {
    const io = init.io;
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, store, &selected_buffer);
    const file = try renderScratch(init);
    defer file.close(io);
    var buffer: client.ReplyBuffer = .{};
    var call_bytes: u64 = 0;
    if (!interactive) {
        const call = try requester.readActionCallId(selected, reference, target, file, &buffer);
        if (call == .command) {
            try writeCommandReply(io, call.command, .stdout);
            return error.ActionReadFailed;
        }
        call_bytes = call.answer.bytes;
    }
    const arguments = try requester.readActionArguments(selected, reference, target, file, &buffer);
    if (arguments == .command) {
        try writeCommandReply(io, arguments.command, .stdout);
        return error.ActionReadFailed;
    }
    var line: [96]u8 = undefined;
    if (!interactive) {
        // People review this before `action allow`; escaping every non-ASCII
        // code point keeps provider-chosen control and bidi characters from
        // disguising the proposal, while JSON still decodes the exact bytes.
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"action\":\"{d}\",\"call_id\":\"", .{target}));
        try writeJsonFileAt(io, file, 0, call_bytes, true);
        try std.Io.File.stdout().writeStreamingAll(io, "\",\"arguments\":\"");
        try writeJsonFileAt(io, file, call_bytes, arguments.answer.bytes, true);
        return std.Io.File.stdout().writeStreamingAll(io, "\"}\n");
    }
    // Quote provider-controlled fields so control and bidi bytes cannot alter the
    // proposal visible next to the human approval prompt.
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "Action {d}\n", .{target}));
    try std.Io.File.stdout().writeStreamingAll(io, "Bash arguments: \"");
    try writeJsonFileAt(io, file, call_bytes, arguments.answer.bytes, true);
    try std.Io.File.stdout().writeStreamingAll(io, "\"\n");
}

// Diagnostics preserve opaque selectors without printable shell ambiguity.
fn writeShellWord(io: std.Io, value: []const u8) !void {
    var storage: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &storage);
    try TerminalText.writeShellWord(&writer.interface, value);
    try writer.flush();
}

fn writeJsonFileAt(io: std.Io, file: std.Io.File, start: u64, length: u64, escape_unicode: bool) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    var chunk: [protocol.content_window_bytes + 3]u8 = undefined;
    var offset: u64 = 0;
    var carry: usize = 0;
    while (offset < length) {
        const n = try file.readPositionalAll(io, chunk[carry..][0..@intCast(@min(length - offset, chunk.len - carry))], start + offset);
        if (n == 0) return error.TruncatedResult;
        offset += n;
        const available = carry + n;
        var complete = available;
        if (escape_unicode and offset < length) {
            var lead = available - 1;
            while (lead != 0 and chunk[lead] & 0xc0 == 0x80) lead -= 1;
            const width = try std.unicode.utf8ByteSequenceLength(chunk[lead]);
            if (lead + width > available) complete = lead;
        }
        try std.json.Stringify.encodeJsonStringChars(chunk[0..complete], .{ .escape_unicode = escape_unicode }, &writer.interface);
        carry = available - complete;
        std.mem.copyForwards(u8, chunk[0..carry], chunk[complete..available]);
    }
    if (carry != 0) return error.TruncatedResult;
    try writer.flush();
}

const compaction_help = cli_args.compaction_policy ++ " Inspect settings with /status or rui session inspect.";

const interactive_configure_usage = "Rui: Usage: /configure [--model MODEL] [--tools bash] [--permission-mode ask|bypass] [--reasoning-effort none|low|medium|high|xhigh|max|default] [--compaction-trigger TOKENS|default] [--output-reservation TOKENS|default] [--label TEXT] (settings for this Session only)\n" ++ cli_args.label_help ++ cli_args.reasoning_help ++ compaction_help ++ "\n";

const usage_text =
    \\usage:
    \\  rui [--store PATH] [--provider codex] [--model MODEL]
    \\    Create a fresh live terminal conversation in the current directory. Bash runs
    \\    without asking by default. Enter Message text in the terminal editor.
    \\    Type /help in the conversation.
    \\  rui RESOURCE --help
    \\    Resources: session, request, action, host, defaults, auth.
    \\  rui RESOURCE COMMAND --help
    \\    Installed operation help owns exact options. Help needs no Host or credentials.
    \\  rui --version
    \\    Print the release version and source revision.
    \\
    \\For agents and scripts, session start creates a Session with its first Message;
    \\session send addresses an existing ID. Both read exact Message text from stdin
    \\and return on admission, not completion. Set instructions separately using
    \\session configure --instructions - with instructions on stdin.
    \\Reads observe once; request read-result streams only the original saved answer.
    \\session start prints its new ID; other metadata is JSON. Diagnostics use stderr.
    \\Non-interactive calls never implicitly start a Host or sign in. Administration is explicit.
    \\After uncertainty, inspect or recover the original handle or record, never a new key.
    \\A nonzero exit can follow acceptance. Inspection never admits work; recovery can.
    \\Store selection: --store, saved defaults, then HOME/.local/share/rui/store.
    \\Generated captures: HOME/.config/rui/requests. Use explicit --record and --key
    \\to retain a pre-known identity even if every notice and receipt is lost.
    \\
;

const version_text = "rui " ++ @import("transport_options").version ++ " (" ++ @import("transport_options").revision ++ ")\n";

/// Set while a resource operation runs; its failure names that operation's
/// help instead of printing the root summary.
var dispatching = false;

fn usage() error{InvalidArguments} {
    if (!dispatching) std.debug.print("{s}", .{usage_text});
    return error.InvalidArguments;
}

test "post-command hold signals only after work and exits on release" {
    const ready = try testPipe();
    defer closeDescriptor(ready[0]);
    const release = try testPipe();
    defer closeDescriptor(release[1]);
    const thread = try std.Thread.spawn(.{}, postCommandHoldDescriptors, .{ ready[1], release[0] });

    var signal: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(ready[0], &signal, signal.len));
    try std.testing.expectEqual(@as(u8, 1), signal[0]);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(release[1], &[_]u8{1}, 1));
    thread.join();
}

test "post-command hold reports release-pipe cleanup" {
    const ready = try testPipe();
    defer closeDescriptor(ready[0]);
    const release = try testPipe();
    closeDescriptor(release[1]);
    try std.testing.expectError(error.PostCommandHoldClosed, postCommandHoldDescriptors(ready[1], release[0]));
}

test "render scratch has no named payload and refuses failed unlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try createRenderScratch(io, tmp.dir, false);
    defer file.close(io);
    try file.writeStreamingAll(io, "private answer");
    var directory = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    try std.testing.expect((try iterator.next(io)) == null);

    try std.testing.expectError(error.RenderScratchCleanupFailed, createRenderScratch(io, tmp.dir, true));
    iterator = directory.iterate();
    const abandoned = (try iterator.next(io)).?;
    try std.testing.expectEqual(@as(u64, 0), (try tmp.dir.statFile(io, abandoned.name, .{})).size);
}

fn testPipe() ![2]std.posix.fd_t {
    var descriptors: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&descriptors) != 0) return error.TestPipeFailed;
    return descriptors;
}

fn closeDescriptor(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}
