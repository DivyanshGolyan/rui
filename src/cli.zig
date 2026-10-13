const std = @import("std");
const TerminalEditor = @import("TerminalEditor.zig");
const TerminalText = @import("TerminalText.zig");
const AnswerRenderer = @import("AnswerRenderer.zig");
const SessionFrontend = @import("SessionFrontend.zig");
const TestObservation = @import("TestObservation.zig");
const cli_args = @import("cli_args.zig");
const client = @import("client.zig");
const codex_auth = @import("codex_auth.zig");
const codex_credentials = @import("codex_credentials.zig");
const model_adapter = @import("model_adapter.zig");
const platform = @import("platform.zig");
const preferences = @import("preferences.zig");
const provider = @import("provider.zig");
const provider_selection = @import("provider_selection.zig");
const protocol = @import("protocol.zig");
const server = @import("server.zig");

// Zig otherwise reserves an alternate signal stack on every thread even when
// the release build has no default crash handler to use it.
pub const std_options: std.Options = .{
    .signal_stack_size = if (std.debug.default_enable_segfault_handler) 1 << 18 else null,
};

extern "c" fn rui_launch_detached(executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize) c_int;

test "detached launcher reports exec failure before claiming Host readiness" {
    const argv = [_:null]?[*:0]const u8{"/rui-no-such-executable"};
    try std.testing.expectEqual(@as(c_int, 2), rui_launch_detached(argv[0].?, &argv, argv.len));
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        TerminalText.diagnostic("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try allocator.alloc([]const u8, raw_args.len);
    defer allocator.free(args);
    for (raw_args, args) |raw, *arg| arg.* = raw;
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        return std.Io.File.stdout().writeStreamingAll(init.io, usage_text);
    }
    if (args.len < 2 or std.mem.startsWith(u8, args[1], "--")) return newSession(init, args[1..]);
    const resource = std.meta.stringToEnum(cli_args.Resource, args[1]) orelse return newSession(init, args[1..]);
    var help_buffer: [4096]u8 = undefined;
    var help_writer = std.Io.File.stdout().writerStreaming(init.io, &help_buffer);
    if (args.len == 2 or (args.len == 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h")))) {
        try cli_args.resourceHelp(resource, &help_writer.interface);
        return help_writer.flush();
    }
    const command = cli_args.find(resource, args[2]) orelse {
        TerminalText.diagnostic("rui: unknown operation; use rui {s} --help.\n", .{@tagName(resource)});
        return error.InvalidArguments;
    };
    const definition = command.definition();
    errdefer TerminalText.diagnostic("rui: command failed; syntax and recovery: rui {s} {s} --help.\n", .{ @tagName(resource), definition.name });
    if (try definition.validate(args[3..])) {
        try definition.help(&help_writer.interface);
        return help_writer.flush();
    }
    // Decode only selector arguments, never an option-looking value or literal
    // message. Handlers consume the same bounded identities regardless of their
    // shell-safe spelling; the arena outlives this invocation.
    var selector_index: usize = 3;
    while (selector_index < args.len) : (selector_index += 1) {
        if (std.mem.eql(u8, args[selector_index], "--")) break;
        for (definition.options) |option| {
            const arg = args[selector_index];
            if (!std.mem.startsWith(u8, arg, "--") or !std.mem.eql(u8, arg[2..], option.name)) continue;
            if (option.argument != null) {
                inline for (.{ .{ "store-hex", "--store", protocol.max_store_bytes }, .{ "session-hex", "--session", protocol.max_session_bytes }, .{ "key-hex", "--key", protocol.max_key_bytes } }) |selector| {
                    if (std.mem.eql(u8, option.name, selector[0])) {
                        const storage = try init.arena.allocator().alloc(u8, selector[2]);
                        args[selector_index + 1] = try decodeHexIdentity(args[selector_index + 1], storage);
                        args[selector_index] = selector[1];
                    }
                }
                selector_index += 1;
            }
            break;
        }
    }
    switch (command) {
        .session_configure => try configure(init, .{ .io = init.io }, args[3..], false),
        .session_send => try message(init, args[3..]),
        .session_inspect => try inspect(init, args[3..]),
        .session_list => try sessions(init, args[3..]),
        .session_stop => try stopSession(init, args[3..]),
        .session_interrupt_model => try interruptModel(init, args[3..]),
        .session_read_conversation => try readConversation(init, args[3..]),
        .session_resume => try resumeSession(init, args[3..]),
        .request_inspect => try observe(init, args[3..]),
        .request_recover => try recover(init, args[3..]),
        .request_read_result => try readResult(init, args[3..]),
        .request_list => try requests(init, args[3..]),
        .action_inspect => try inspectAction(init, .{ .io = init.io }, args[3..], false),
        .action_allow => try decideAction(init, args[3..], .allow_once),
        .action_deny => try decideAction(init, args[3..], .deny),
        .action_read_call_id => try readActionContent(init, args[3..], .call_id),
        .action_read_arguments => try readActionContent(init, args[3..], .arguments),
        .host_start, .host_stop, .host_status => try host(init, args[2..]),
        .host_serve => {
            try configureHostAllocator(init, args);
            try serve(init, args[3..]);
        },
        .defaults_inspect, .defaults_configure => try setup(init, args[3..], false),
        .auth_login => try login(init, args[3..], false, codex_auth.login),
    }
    try postCommandHold(init);
}

fn configureHostAllocator(init: std.process.Init, args: []const []const u8) !void {
    if (@import("builtin").os.tag != .macos) return;
    if (std.mem.eql(u8, init.environ_map.get("RUI_HOST_MALLOC_DEFAULTS") orelse "", "0")) return;
    var changed = false;
    for ([_][]const u8{ "MallocMaxMagazines", "MallocSpaceEfficient" }) |key| {
        if (init.environ_map.get(key) != null) continue;
        try init.environ_map.put(key, "1");
        changed = true;
    }
    if (!changed) return;

    // libmalloc reads these at process startup, before main. Replace this
    // image before acquiring Store custody; key presence prevents another exec.
    // Explicit caller values (including empty values) always take precedence.
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try std.process.executablePath(init.io, &path_buffer);
    const argv = try init.arena.allocator().dupe([]const u8, args);
    argv[0] = path_buffer[0..path_len];
    return std.process.replace(init.io, .{ .argv = argv, .environ_map = init.environ_map });
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
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
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

fn setup(init: std.process.Init, args: []const []const u8, interactive: bool) !void {
    const home = init.environ_map.get("HOME") orelse {
        TerminalText.diagnostic("rui: setup needs an absolute HOME; no preferences saved.\n", .{});
        return error.HomeUnavailable;
    };
    var edit: preferences.Edit = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--store")) {
            edit.store = .{ .set = try takeValue(args, &index) };
        } else if (std.mem.eql(u8, flag, "--provider")) {
            edit.provider = .{ .set = try takeValue(args, &index) };
        } else if (std.mem.eql(u8, flag, "--model")) {
            if (edit.model == .clear) return error.ConflictingPreferenceModelEdit;
            edit.model = .{ .set = try takeValue(args, &index) };
        } else if (std.mem.eql(u8, flag, "--clear-model")) {
            if (edit.model == .set) return error.ConflictingPreferenceModelEdit;
            edit.model = .clear;
        } else return usage();
    }
    var credential_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const now: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds, std.time.ns_per_s));
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
            TerminalText.diagnostic("rui: setup supports only exact model gpt-6-luna for Codex; no preferences saved. Existing Sessions are unchanged.\n", .{});
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
    if (!interactive) {
        var bytes: [protocol.content_window_bytes]u8 = undefined;
        var output = std.Io.File.stdout().writerStreaming(init.io, &bytes);
        try std.json.Stringify.value(.{
            .version = protocol.wire_version,
            .type = "defaults",
            .changed = changed,
            .store = prospective_store,
            .store_source = if (values.store.len != 0) "saved" else "home",
            .store_available = available_store != null,
            .provider = if (values.provider.len != 0) values.provider.slice() else null,
            .model = if (values.model.len != 0) values.model.slice() else null,
            .local_credential = @tagName(readiness),
        }, .{}, &output.interface);
        try output.interface.writeByte('\n');
        return output.flush();
    }
    // Preferences are local hints, not Session settings or Host facts.
    try std.Io.File.stdout().writeStreamingAll(init.io, if (changed) "Saved defaults for future Sessions. Active Session unchanged.\n" else "Defaults (read only):\n");
    try std.Io.File.stdout().writeStreamingAll(init.io, "Store: ");
    try writeSafeText(init.io, prospective_store orelse "unavailable");
    try std.Io.File.stdout().writeStreamingAll(init.io, if (values.store.len != 0) " (saved)\n" else " (HOME fallback)\n");
    if (available_store == null) try std.Io.File.stdout().writeStreamingAll(init.io, "Store unavailable: destination cannot be selected; no alternate Store selected.\n");
    try writeSafeField(init.io, "Provider: ", if (values.provider.len != 0) values.provider.slice() else "not selected");
    try writeSafeField(init.io, "Model: ", if (values.model.len != 0) values.model.slice() else "not selected");
    var output: [std.Io.Dir.max_path_bytes + 512]u8 = undefined;
    const codex = provider_selection.codex(readiness);
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
            error.UnsupportedSelectionProvider => "Next Session: saved provider is unsupported; no fallback. Repair with `rui defaults configure --provider codex --model gpt-6-luna`.\n",
            error.UnsupportedSelectionModel => "Next Session: saved model is unsupported; no fallback. Repair with `rui defaults configure --provider codex --model gpt-6-luna`.\n",
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

// The caller owns buffer. Explicit destinations never consult preferences;
// omitted destinations use the same saved/HOME rule in every CLI mode.
fn selectedStore(init: std.process.Init, explicit: ?[]const u8, buffer: []u8) ![]const u8 {
    if (explicit) |path| {
        if (path.len == 0) return error.InvalidStore;
        return path;
    }
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
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

fn host(init: std.process.Init, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const start = std.mem.eql(u8, args[0], "start");
    const stop = std.mem.eql(u8, args[0], "stop");
    if (!start and !stop and !std.mem.eql(u8, args[0], "status")) return usage();
    var explicit: ?[]const u8 = null;
    var target: ?protocol.InstanceId = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store") and explicit == null) {
            explicit = try takeValue(args, &index);
        } else if (stop and std.mem.eql(u8, args[index], "--instance") and target == null) {
            target = try protocol.parseInstanceId(try takeValue(args, &index));
        } else return usage();
    }
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, explicit, &fallback);
    if (start) return startHost(init, selected, false);
    if (stop) return stopHost(init.io, selected, target);
    const status = client.hostStatus(init.io, selected);
    try writeHostStatus(init.io, status);
    switch (status) {
        .incompatible => return error.IncompatibleHost,
        .access_failure => return error.StoreAccessFailed,
        else => {},
    }
}

fn writeHostStatus(io: std.Io, status: client.HostStatus) !void {
    var bytes: [protocol.content_window_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &bytes);
    try output.interface.print("{{\"version\":\"{s}\",\"type\":\"host_status\",\"status\":\"{s}\"", .{ protocol.wire_version, @tagName(status) });
    switch (status) {
        .ready => |ready| {
            try output.interface.writeAll(",\"store\":");
            try std.json.Stringify.value(ready.store.slice(), .{}, &output.interface);
            const instance = std.fmt.bytesToHex(ready.instance, .lower);
            try output.interface.print(",\"active_capacity\":\"{d}\",\"instance\":\"{s}\",\"capabilities\":", .{ ready.active_capacity, instance });
            try std.json.Stringify.value(ready.capabilities, .{}, &output.interface);
            var location: [protocol.max_store_bytes + "/diagnostics".len]u8 = undefined;
            try output.interface.writeAll(",\"diagnostics\":");
            try std.json.Stringify.value(try std.fmt.bufPrint(&location, "{s}/diagnostics", .{ready.store.slice()}), .{}, &output.interface);
        },
        else => {},
    }
    try output.interface.writeAll("}\n");
    try output.flush();
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
    try notice.print(" --instance {s}\n", .{hex});
    try std.Io.File.stderr().writeStreamingAll(io, notice.buffered());
    var reply: client.ReplyBuffer = .{};
    const outcome = client.stopHost(io, .{ .store = paths.store.slice(), .instance = target }, &reply) catch |err| {
        TerminalText.diagnostic("rui: stop reply unconfirmed ({s}); inspect this Store and retry only the same --instance target. Do not target a replacement implicitly.\n", .{@errorName(err)});
        return err;
    };
    switch (outcome) {
        .acknowledged => {
            var bytes: [protocol.content_window_bytes]u8 = undefined;
            var output = std.Io.File.stdout().writerStreaming(io, &bytes);
            try std.json.Stringify.value(.{ .version = protocol.wire_version, .type = "host_stop", .status = "acknowledged", .store = paths.store.slice(), .instance = hex[0..], .retirement = "unconfirmed" }, .{}, &output.interface);
            try output.interface.writeByte('\n');
            try output.flush();
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

fn startHost(init: std.process.Init, selected: []const u8, quiet: bool) !void {
    const io = init.io;
    switch (client.hostStatus(io, selected)) {
        .ready => |ready| {
            if (!quiet) try writeHostStatus(io, .{ .ready = ready });
            return;
        },
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
    const store_z = try std.fmt.bufPrintZ(&store_buffer, "{s}", .{paths.store.slice()});
    // Application policy lives here. The synchronous native launcher borrows
    // these terminated strings and pointer framing through exec/error handoff;
    // all storage is prepared before any detach fork.
    const argv = [_:null]?[*:0]const u8{
        @ptrCast(&executable_buffer), "host", "serve",   "--store", store_z.ptr,
        "--active-capacity",          "8",    "--codex",
    };
    const launched = rui_launch_detached(argv[0].?, &argv, argv.len);
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
    while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < until) {
        switch (client.hostStatusUntil(io, paths.store.slice(), until)) {
            .ready => |ready| {
                if (!quiet) try writeHostStatus(io, .{ .ready = ready });
                return;
            },
            .incompatible => return error.IncompatibleHost,
            .access_failure => return error.StoreAccessFailed,
            .unavailable, .owned_unavailable => {},
        }
        const remaining = until - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (remaining > 0) try std.Io.sleep(io, .fromNanoseconds(@intCast(@min(remaining, 100 * std.time.ns_per_ms))), .awake);
    }
    TerminalText.diagnostic("rui: Host readiness unconfirmed after 10 seconds. Inspect rui host status and the selected Store's diagnostics/ startup records if present; do not kill or reclaim an uncertain owner.\n", .{});
    return error.HostReadinessUnconfirmed;
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
    try provider.initialize();
    defer provider.deinitialize();
    var tokens = if (interactive)
        try exchange(init.io, struct {
            fn display(code: []const u8) !void {
                const output = std.Io.File.stdout();
                const io = std.Io.Threaded.global_single_threaded.io();
                try output.writeStreamingAll(io, "Open https://auth.openai.com/codex/device and enter code: ");
                try output.writeStreamingAll(io, code);
                try output.writeStreamingAll(io, "\n");
            }
        }.display, loginInterrupted)
    else
        try exchange(init.io, struct {
            fn display(code: []const u8) !void {
                std.debug.print("Open https://auth.openai.com/codex/device and enter code: {s}\n", .{code});
            }
        }.display, loginInterrupted);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&tokens));
    var record: codex_credentials.Record = .{
        .generation = 0,
        .account_id = .{},
        .fedramp = (try codex_auth.parseAccount(tokens.id_token.slice())).fedramp,
        .id_token = .{},
        .access_token = .{},
        .refresh_token = .{},
        .expires_at = (try codex_auth.parseExpiry(tokens.access_token.slice())) orelse 0,
        .refreshed_at = @intCast(@divFloor(std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds, std.time.ns_per_s)),
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
    try record.account_id.set(tokens.account_id.slice());
    try record.id_token.set(tokens.id_token.slice());
    try record.access_token.set(tokens.access_token.slice());
    try record.refresh_token.set(tokens.refresh_token.slice());
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
        return std.Io.File.stdout().writeStreamingAll(init.io, "). Inspect rui defaults inspect; active Session unchanged.\n");
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, if (added)
        "Rui: No provider default existed; Codex selected for future Sessions; model recommendation remains unpinned.\n"
    else
        "Rui: Existing provider default unchanged.\n");
}

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
            try tokens.account_id.set(codex_auth.fixture_account_id);
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
    prompt: ?[]const u8 = null,

    fn parse(args: []const []const u8) !NewSessionOptions {
        var options: NewSessionOptions = .{};
        var persistent = false;
        var literal = false;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (!literal and std.mem.eql(u8, arg, "--store") and options.store == null) options.store = try takeValue(args, &index) else if (!literal and std.mem.eql(u8, arg, "--provider") and options.provider == null) options.provider = try takeValue(args, &index) else if (!literal and std.mem.eql(u8, arg, "--model") and options.model == null) options.model = try takeValue(args, &index) else if (!literal and std.mem.eql(u8, arg, "--persistent") and !persistent) persistent = true else if (!literal and std.mem.eql(u8, arg, "--")) literal = true else if (options.prompt == null and (literal or !std.mem.startsWith(u8, arg, "-"))) options.prompt = arg else return usage();
        }
        if (options.prompt) |prompt| {
            if (prompt.len == 0) return error.EmptyPrompt;
            if (prompt.len > @import("SessionInput.zig").capacity) return error.StreamTooLong;
            try TerminalEditor.validateText(prompt);
        }
        return options;
    }
};

fn newSession(init: std.process.Init, args: []const []const u8) !void {
    const options = try NewSessionOptions.parse(args);
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) {
        TerminalText.diagnostic("rui needs terminal input and output to create a Session; use explicit one-shot commands for scripts. No Host or Session changed.\n", .{});
        return error.InteractiveTerminalRequired;
    }
    const saved = (try createSession(init, options)) orelse return;
    runSession(init, saved.store.slice(), saved.session.slice(), options.prompt) catch |err| {
        // Configuration acceptance and local entry are independent outcomes.
        var bytes: [256]u8 = undefined;
        var notice = std.Io.Writer.fixed(&bytes);
        notice.print("\nrui: Session configuration accepted.\nConfiguration request: {s} (rui request inspect {s})\n", .{ saved.key.slice(), saved.key.slice() }) catch return err;
        _ = @import("stderr.zig").write(notice.buffered());
        return err;
    };
}

fn createSession(init: std.process.Init, options: NewSessionOptions) !?client.CapturedIdentity {
    const store = options.store;
    const explicit_provider = options.provider;
    const explicit_model = options.model;
    var cwd = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
    defer cwd.close(init.io);
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace_length = try cwd.realPath(init.io, &workspace_buffer);
    const workspace = workspace_buffer[0..workspace_length];

    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    // Fully explicit selection never reads or locks unused preferences.
    var defaults: preferences.Values = if (store != null and explicit_provider != null and explicit_model != null) .{} else preferences.load(home) catch |err| {
        TerminalText.diagnostic("rui: private setup defaults unreadable ({s}); use rui defaults inspect before creating a Session.\n", .{@errorName(err)});
        return err;
    };
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var selected_store = store orelse (if (defaults.store.len != 0) defaults.store.slice() else try preferences.defaultStore(home, &fallback));
    try preflightNewSession(init.io, selected_store, store == null and defaults.store.len != 0);
    var credential_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const credential = try credentialPath(init, &credential_buffer, false);
    const now: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds, std.time.ns_per_s));
    const readiness: provider_selection.Readiness = if (codex_auth.localStatus(credential, now)) |state| switch (state) {
        .missing => .missing,
        .configured => .configured,
        .renewal_due => .renewal_due,
        .refresh_required => .refresh_required,
    } else |_| .credential_error;
    var selection = provider_selection.resolve(&.{provider_selection.codex(readiness)}, explicit_provider, explicit_model, if (defaults.provider.len == 0) null else defaults.provider.slice(), if (defaults.model.len == 0) null else defaults.model.slice()) catch |err| {
        TerminalText.diagnostic("rui: unsupported prospective provider/model ({s}); use rui defaults inspect or select codex / gpt-6-luna. No Session created.\n", .{@errorName(err)});
        return err;
    };
    if (selection == .chooser or !selection.selected.readiness.usable()) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No locally ready provider for a new Session. Choose Codex login or defer; saved work remains inspectable.\n");
        try guideProviderLogin(init);
        // Explicit destination and binding never depend on the preference file,
        // including after a login whose future-default save failed.
        if (store == null or explicit_provider == null or explicit_model == null)
            defaults = try preferences.load(home);
        selected_store = store orelse (if (defaults.store.len != 0) defaults.store.slice() else try preferences.defaultStore(home, &fallback));
        try preflightNewSession(init.io, selected_store, store == null and defaults.store.len != 0);
        const after_choice: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds, std.time.ns_per_s));
        const updated = codex_auth.localStatus(credential, after_choice) catch |err| {
            TerminalText.diagnostic("rui: credential still unreadable ({s}); use rui defaults inspect. No Session created.\n", .{@errorName(err)});
            return err;
        };
        selection = provider_selection.resolve(&.{provider_selection.codex(switch (updated) {
            .missing => .missing,
            .configured => .configured,
            .renewal_due => .renewal_due,
            .refresh_required => .refresh_required,
        })}, explicit_provider, explicit_model, if (defaults.provider.len == 0) null else defaults.provider.slice(), if (defaults.model.len == 0) null else defaults.model.slice()) catch |err| {
            TerminalText.diagnostic("rui: unsupported prospective provider/model after login ({s}); use rui defaults inspect. No Session created.\n", .{@errorName(err)});
            return err;
        };
        if (selection == .chooser or !selection.selected.readiness.usable()) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No new Session created. Use rui defaults inspect or rui auth login codex when ready; existing work is unchanged.\n");
            return null;
        }
    }
    const selected = selection.selected;
    try startHost(init, selected_store, true);
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
        .session = .from_capture_key,
        .require_model = true,
        .workspace = .{ .present = true, .value = workspace },
        .provider = .{ .present = true, .value = selected.provider },
        .model = .{ .present = true, .value = selected.model },
        .tools = "bash",
        .permission_mode = .{ .present = true, .value = "bypass" },
    }, .{ .generated = try requestDirectory(init, &directory_buffer) });
    const saved = captured.identity().*;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(init.io);
        try testGate(init.io, "RUI_TEST_CAPTURE_GATE");
        break :blk client.sendCaptured(init.io, &captured, null, &reply_buffer) catch |err| {
            TerminalText.diagnostic("rui: configuration not confirmed ({s}); use rui request recover {s}. Do not replace uncertain work.\n", .{ @errorName(err), saved.key.slice() });
            return err;
        };
    };
    if (!reply.isAccepted()) {
        try writeMutationReply(init.io, reply, .human);
        return error.SessionConfigurationRejected;
    }
    return saved;
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

fn serve(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var store_path: ?[]const u8 = null;
    var provider_endpoint: ?[]const u8 = null;
    var provider_ca_file: ?[]const u8 = null;
    var managed = false;
    var fixture_endpoint: ?[]const u8 = null;
    var bash_path: []const u8 = server.default_bash_path;
    var bash_timeout_ms: u64 = server.default_bash_timeout_ms;
    var active_capacity: usize = server.default_active_capacity;
    var faults: server.Faults = .{};
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) {
            store_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--codex")) {
            managed = true;
        } else if (std.mem.eql(u8, arg, "--test-codex-fixture-endpoint")) {
            fixture_endpoint = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--provider-endpoint")) {
            provider_endpoint = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--provider-ca-file")) {
            provider_ca_file = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--bash-path")) {
            bash_path = try takeValue(args, &index);
            if (bash_path.len == 0) return error.InvalidBashPath;
        } else if (std.mem.eql(u8, arg, "--bash-timeout-ms")) {
            bash_timeout_ms = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            if (bash_timeout_ms == 0 or bash_timeout_ms > std.math.maxInt(i64)) return error.InvalidBashTimeout;
        } else if (std.mem.eql(u8, arg, "--test-bash-scratch-limit-bytes")) {
            faults.bash_scratch_limit_bytes = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--test-retention-entry-capacity")) {
            faults.retention_entry_capacity = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
            if (faults.retention_entry_capacity.? < 2 or
                faults.retention_entry_capacity.? > server.default_retention_entry_capacity)
            {
                return error.InvalidRetentionEntryCapacity;
            }
        } else if (std.mem.eql(u8, arg, "--test-retention-removal-failure")) {
            faults.retention_removal = true;
        } else if (std.mem.eql(u8, arg, "--active-capacity")) {
            active_capacity = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--fault")) {
            const fault = try takeValue(args, &index);
            if (std.mem.eql(u8, fault, "content-acquire")) faults.content_acquire = true else if (std.mem.eql(u8, fault, "content-write")) faults.content_write = true else if (std.mem.eql(u8, fault, "content-seal")) faults.content_seal = true else if (std.mem.eql(u8, fault, "content-read")) faults.content_read = true else if (std.mem.eql(u8, fault, "content-import")) faults.content_import = true else if (std.mem.eql(u8, fault, "before-commit")) faults.before_commit = true else if (std.mem.eql(u8, fault, "startup-cleanup")) faults.startup_cleanup = true else if (std.mem.eql(u8, fault, "shutdown-after-accept")) faults.shutdown_after_accept = true else if (std.mem.eql(u8, fault, "attempt-before-commit")) faults.attempt_before_commit = true else if (std.mem.eql(u8, fault, "result-before-commit")) faults.result_before_commit = true else if (std.mem.eql(u8, fault, "request-first-step")) faults.request_first_step = true else if (std.mem.eql(u8, fault, "request-write")) faults.request_write = true else if (std.mem.eql(u8, fault, "request-seal")) faults.request_seal = true else if (std.mem.eql(u8, fault, "request-scratch-acquire")) faults.request_scratch_acquire = true else if (std.mem.eql(u8, fault, "request-read")) faults.request_read = true else if (std.mem.eql(u8, fault, "request-unlink")) faults.request_unlink = true else if (std.mem.eql(u8, fault, "provider-prepare")) faults.provider_prepare = true else if (std.mem.eql(u8, fault, "completion-private-missing")) faults.completion_identity_fault = .missing else if (std.mem.eql(u8, fault, "completion-private-foreign")) faults.completion_identity_fault = .foreign else if (std.mem.eql(u8, fault, "completion-private-mismatch")) faults.completion_identity_fault = .mismatched else if (std.mem.eql(u8, fault, "response-acquire")) faults.response_acquire = true else if (std.mem.eql(u8, fault, "response-unlink")) faults.response_unlink = true else if (std.mem.eql(u8, fault, "response-write")) faults.response_write = true else if (std.mem.eql(u8, fault, "response-write-on-resume")) faults.response_write_on_resume = true else if (std.mem.eql(u8, fault, "response-seal")) faults.response_seal = true else if (std.mem.eql(u8, fault, "response-metadata")) faults.response_metadata = true else if (std.mem.eql(u8, fault, "response-metadata-unlink")) faults.response_metadata_unlink = true else if (std.mem.eql(u8, fault, "response-read")) faults.response_read = true else if (std.mem.eql(u8, fault, "response-import")) faults.response_import = true else if (std.mem.eql(u8, fault, "response-commit")) faults.response_commit = true else if (std.mem.eql(u8, fault, "bash-preparation")) faults.bash_preparation = true else if (std.mem.eql(u8, fault, "bash-preparation-after-script")) faults.bash_preparation_after_script = true else if (std.mem.eql(u8, fault, "bash-spawn")) faults.bash_spawn = true else if (std.mem.eql(u8, fault, "bash-service")) faults.bash_service = true else if (std.mem.eql(u8, fault, "bash-capture-read")) faults.bash_capture_read = true else if (std.mem.eql(u8, fault, "bash-capture-write")) faults.bash_capture_write = true else if (std.mem.eql(u8, fault, "bash-seal")) faults.bash_seal = true else if (std.mem.eql(u8, fault, "bash-cleanup")) faults.bash_cleanup = true else if (std.mem.eql(u8, fault, "bash-observe")) faults.bash_lifecycle_fault = .observe else if (std.mem.eql(u8, fault, "bash-reap")) faults.bash_lifecycle_fault = .reap else if (std.mem.eql(u8, fault, "bash-reap-watchdog")) faults.bash_lifecycle_fault = .reap_watchdog else if (std.mem.eql(u8, fault, "bash-group-probe")) faults.bash_lifecycle_fault = .group_probe else if (std.mem.eql(u8, fault, "bash-tail-snapshot")) faults.bash_lifecycle_fault = .tail_snapshot else if (std.mem.eql(u8, fault, "bash-signal")) faults.bash_lifecycle_fault = .signal else if (std.mem.eql(u8, fault, "bash-cleanup-watchdog")) faults.bash_lifecycle_fault = .cleanup_watchdog else if (std.mem.eql(u8, fault, "bash-fault-gated")) faults.bash_fault_gated = true else if (std.mem.eql(u8, fault, "report-unlink")) faults.report_unlink = true else return error.UnknownFault;
        } else if (std.mem.eql(u8, arg, "--test-cleanup-delay-ms")) {
            faults.cleanup_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.cleanup_delay_ms < 0 or faults.cleanup_delay_ms > 60_000) return error.InvalidCleanupDelay;
        } else if (std.mem.eql(u8, arg, "--test-provider-inactivity-seconds")) {
            faults.provider_inactivity_seconds = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.provider_inactivity_seconds < 1) return error.InvalidProviderInactivity;
            _ = std.math.mul(i64, faults.provider_inactivity_seconds, std.time.ns_per_s) catch
                return error.InvalidProviderInactivity;
        } else if (std.mem.eql(u8, arg, "--test-retry-waits-ms")) {
            faults.retry_waits_ms = try parseRetryWaits(try takeValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--test-before-launch-delay-ms")) {
            faults.before_launch_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.before_launch_delay_ms < 0 or faults.before_launch_delay_ms > 10_000) return error.InvalidLaunchDelay;
        } else if (std.mem.eql(u8, arg, "--test-before-result-delay-ms")) {
            faults.before_result_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.before_result_delay_ms < 0 or faults.before_result_delay_ms > 10_000) return error.InvalidResultDelay;
        } else if (std.mem.eql(u8, arg, "--test-model-result-gate-path")) {
            faults.model_result_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-inspection-reply-gate-path")) {
            faults.inspection_reply_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-inspection-reply-delay-ms")) {
            faults.inspection_reply_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.inspection_reply_delay_ms < 0 or faults.inspection_reply_delay_ms > 60_000) return error.InvalidInspectionReplyDelay;
        } else if (std.mem.eql(u8, arg, "--test-client-send-buffer-bytes")) {
            faults.client_send_buffer_bytes = try std.fmt.parseInt(u32, try takeValue(args, &index), 10);
            if (faults.client_send_buffer_bytes.? == 0 or faults.client_send_buffer_bytes.? > std.math.maxInt(c_int)) return error.InvalidClientSendBuffer;
        } else if (std.mem.eql(u8, arg, "--test-phase-trace")) {
            faults.test_phase_trace = true;
        } else if (std.mem.eql(u8, arg, "--test-observation-fd")) {
            faults.test_observation_fd = try std.fmt.parseInt(c_int, try takeValue(args, &index), 10);
            faults.test_phase_trace = true;
        } else if (std.mem.eql(u8, arg, "--test-observation-state-fd")) {
            faults.test_observation_state_fd = try std.fmt.parseInt(c_int, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--test-observation-plan")) {
            faults.test_observation_plan = std.meta.stringToEnum(TestObservation.Plan, try takeValue(args, &index)) orelse
                return error.InvalidTestObservationPlan;
        } else if (std.mem.eql(u8, arg, "--test-transition")) {
            const transition = try takeValue(args, &index);
            if (std.mem.eql(u8, transition, "action-attempt-admitted")) faults.test_transition = .action_attempt_admitted else if (std.mem.eql(u8, transition, "prepared-before-handoff")) faults.test_transition = .prepared_before_handoff else if (std.mem.eql(u8, transition, "action-result-ready")) faults.test_transition = .action_result_ready else if (std.mem.eql(u8, transition, "action-result-committed")) faults.test_transition = .action_result_committed else return error.UnknownTestTransition;
        } else if (std.mem.eql(u8, arg, "--test-transition-gate-path")) {
            faults.test_transition_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-model-cleanup-gate-path")) {
            faults.model_cleanup_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-response-capture-gate-path")) {
            faults.response_capture_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-response-capture-gate-min-written-bytes")) {
            faults.response_capture_gate_min_written_bytes = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--test-bash-observed-exit-gate-path")) {
            faults.bash_observed_exit_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-bash-cleanup-gate-path")) {
            faults.bash_cleanup_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-control-gate-keys")) {
            faults.control_gate_keys = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-control-gate-path")) {
            faults.control_gate_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--test-suppress-first-control-hint")) {
            faults.suppress_first_control_hint = true;
        } else if (std.mem.eql(u8, arg, "--test-sqlite-diagnostics")) {
            faults.sqlite_diagnostics = true;
        } else if (std.mem.eql(u8, arg, "--test-sqlite-cache-spill-off")) {
            faults.sqlite_cache_spill = false;
        } else if (std.mem.eql(u8, arg, "--test-sqlite-cache-kib")) {
            faults.sqlite_cache_kib = try std.fmt.parseInt(u32, try takeValue(args, &index), 10);
            if (faults.sqlite_cache_kib == 0 or faults.sqlite_cache_kib > 4096) return error.InvalidSqliteCacheSize;
        } else if (std.mem.eql(u8, arg, "--test-request-scratch-limit")) {
            faults.request_scratch_limit_bytes = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
        } else if (std.mem.eql(u8, arg, "--test-request-preparation-byte-allowance")) {
            faults.request_preparation_byte_allowance = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
            if (faults.request_preparation_byte_allowance == 0) return error.InvalidRequestPreparationAllowance;
        } else if (std.mem.eql(u8, arg, "--test-request-preparation-item-allowance")) {
            faults.request_preparation_item_allowance = try std.fmt.parseInt(usize, try takeValue(args, &index), 10);
            if (faults.request_preparation_item_allowance == 0) return error.InvalidRequestPreparationAllowance;
        } else if (std.mem.eql(u8, arg, "--test-request-preparation-advance-delay-ms")) {
            faults.request_preparation_advance_delay_ms = try std.fmt.parseInt(i64, try takeValue(args, &index), 10);
            if (faults.request_preparation_advance_delay_ms < 0) return error.InvalidRequestPreparationDelay;
        } else return error.UnknownArgument;
        index += 1;
    }
    if ((faults.control_gate_keys == null) != (faults.control_gate_path == null)) return error.IncompleteControlGate;
    if ((faults.test_transition == null) != (faults.test_transition_gate_path == null)) return error.IncompleteTestTransitionGate;
    if ((managed and (provider_endpoint != null or provider_ca_file != null or fixture_endpoint != null)) or
        (fixture_endpoint != null and provider_endpoint != null)) return error.ManagedDevelopmentEndpointConflict;
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
        faults,
        if (managed) model_adapter.managed_endpoint else fixture_endpoint orelse provider_endpoint,
        provider_ca_file,
        if (credential_path) |path| model_adapter.Authentication{ .path = path, .fixture = fixture_endpoint != null } else null,
        bash_path,
        bash_timeout_ms,
        init.environ_map.get("HOME"),
    );
}

fn parseRetryWaits(value: []const u8) ![3]u64 {
    var waits: [3]u64 = undefined;
    var parts = std.mem.splitScalar(u8, value, ',');
    for (&waits) |*wait| {
        const part = parts.next() orelse return error.InvalidRetryWaits;
        wait.* = std.fmt.parseInt(u64, part, 10) catch return error.InvalidRetryWaits;
        if (wait.* == 0 or wait.* > std.math.maxInt(i64)) return error.InvalidRetryWaits;
    }
    if (parts.next() != null) return error.InvalidRetryWaits;
    return waits;
}

fn configure(init: std.process.Init, requester: client.Requests, args: []const []const u8, interactive: bool) !void {
    const io = init.io;
    var input = client.ConfigureInput{
        .store = "",
        .session = .from_capture_key,
    };
    var location: @FieldType(client.CaptureTarget, "explicit") = .{ .record = "", .key = "" };
    var drop_reply: ?[]const u8 = null;
    var explicit_store: ?[]const u8 = null;
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) location.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            location.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            input.provider = .{ .present = true, .value = try takeValue(args, &index) };
        } else if (std.mem.eql(u8, arg, "--session")) input.session = .{ .named = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--workspace")) input.workspace = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--model")) input.model = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--instructions")) input.instructions = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--tools")) input.tools = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--permission-mode")) input.permission_mode = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--output-schema")) input.output_schema = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--text-output")) input.output_schema = .{ .state = .explicit_null } else if (std.mem.eql(u8, arg, "--test-drop-reply")) drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if ((location.record.len == 0) != !key_seen) return usage();
    var defaults: preferences.Values = .{};
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    // Only fresh creation resolves defaults. Addressed input remains sparse and
    // goes straight to the canonical create-or-update owner without a probe.
    if (input.session == .from_capture_key) {
        if (!input.provider.present or !input.model.present) {
            const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
            defaults = try preferences.load(home);
        }
        if (!input.provider.present) input.provider = .{ .present = true, .value = if (defaults.provider.len != 0) defaults.provider.slice() else model_adapter.provider_label };
        if (!input.model.present) input.model = .{ .present = true, .value = if (defaults.model.len != 0 and defaults.provider.eql(input.provider.value)) defaults.model.slice() else model_adapter.recommended_model };
        if (!input.workspace.present) {
            var cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer cwd.close(io);
            const length = try cwd.realPath(io, &workspace_buffer);
            input.workspace = .{ .present = true, .value = workspace_buffer[0..length] };
        }
        if (input.tools == null) input.tools = "bash";
        if (!input.permission_mode.present) input.permission_mode = .{ .present = true, .value = "bypass" };
    }
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const human = !key_seen;
    const target: client.CaptureTarget = if (human) .{ .generated = try requestDirectory(init, &directory_buffer) } else .{ .explicit = location };
    var captured = try client.captureConfigure(io, input, target);
    const saved = captured.identity().*;
    var admitted: ?bool = null;
    errdefer |err| if (human and interactive) {
        const status = if (admitted) |accepted| if (accepted) "accepted; do not resubmit it" else "rejected" else "not confirmed; do not replace uncertain work";
        TerminalText.diagnostic("rui: Configuration {s} ({s}). Use rui request inspect {s} to inspect the same saved request. Recover only its original intent if unconfirmed.\n", .{ status, @errorName(err), saved.key.slice() });
    };
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(io);
        if (human and !interactive) try announceCapture(io, saved.key.slice());
        break :blk try requester.sendCaptured(&captured, drop_reply, &reply_buffer);
    };
    // Record framed admission before presentation; writeMutationReply owns errors.
    if (human and interactive) admitted = if (reply.answer) |_| reply.isAccepted() else |_| null;
    try writeMutationReply(io, reply, if (human and interactive) .interactive_configuration else .json);
    if (human and interactive) if (requester.cancellation) |token| if (token.stopped.load(.acquire)) {
        TerminalText.diagnostic("rui: Configuration {s}; use rui request inspect {s} to inspect the same saved admission.\n", .{ if (admitted.?) "accepted; do not resubmit it" else "rejected", saved.key.slice() });
    };
}

fn message(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var input = client.MessageInput{ .store = "", .session = "", .text_path = "" };
    var location: @FieldType(client.CaptureTarget, "explicit") = .{ .record = "", .key = "" };
    var drop_reply: ?[]const u8 = null;
    var explicit_store: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    var literal = false;
    var positional_literal = false;
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (literal) {
            if (positional != null) return error.InvalidArguments;
            positional = arg;
            positional_literal = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            literal = true;
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) location.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            location.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--text")) input.text_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--test-drop-reply")) drop_reply = try takeValue(args, &index) else if (positional == null and (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-"))) positional = arg else return error.UnknownArgument;
        index += 1;
    }
    if (positional) |value| {
        if (input.text_path.len != 0) return usage();
        if (!positional_literal and std.mem.eql(u8, value, "-")) input.text_path = "-" else input.text = value;
    }
    if (input.session.len == 0 or (input.text_path.len == 0 and input.text == null) or (location.record.len == 0) != !key_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const human = !key_seen;
    const target: client.CaptureTarget = if (human) .{ .generated = try requestDirectory(init, &directory_buffer) } else .{ .explicit = location };
    var captured = try client.captureMessage(io, input, target);
    const saved = captured.identity().*;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(io);
        if (human) try announceCapture(io, saved.key.slice());
        break :blk try client.sendCaptured(io, &captured, drop_reply, &reply_buffer);
    };
    try writeMutationReply(io, reply, .json);
}

fn showSessionStatus(init: std.process.Init, requester: client.Requests, store: []const u8, session_ref: []const u8, view: enum { opening, full }) !void {
    const report = try inspectWork(init, requester, store, session_ref);
    defer report.file.close(init.io);
    const work = &report.current;
    if (view == .opening) {
        if (work.settings.tools.bash and work.settings.permission_mode.value == .bypass)
            try std.Io.File.stdout().writeStreamingAll(init.io, "Bash runs without approval.\n");
        return;
    }
    try writeSafeField(init.io, "Session: ", session_ref);
    try writeSafeField(init.io, "Store: ", store);
    try writeSafeField(init.io, "Workspace (Bash cwd): ", work.settings.workspace.slice());
    try writeSafeField(init.io, "Provider: ", @tagName(work.settings.provider.value));
    try writeSafeField(init.io, "Model: ", work.settings.model.slice());
    try writeSafeField(init.io, "Permission: ", @tagName(work.settings.permission_mode.value));
    try writeSafeField(init.io, "Work: ", @tagName(work.work.status.value));
    if (work.selected_message) |selected|
        try writeSafeField(init.io, "Current message: ", selected.slice());
    if (work.actionable_count != 0) try showActionable(init.io, &report);
    if (work.first_indeterminate) |action| {
        var buffer: [20]u8 = undefined;
        try writeSafeField(init.io, "Indeterminate Action: ", try std.fmt.bufPrint(&buffer, "{d}", .{action}));
        if (work.indeterminate_count > 1) {
            var line: [160]u8 = undefined;
            try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "Rui: {d} indeterminate Actions in this Turn; session inspect --profile current lists all IDs.\n", .{work.indeterminate_count}));
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: The command may have run; Rui did not replay it. Check its effects before deciding what to do next.\n");
    }
    if (work.recent_count != 0) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Recent messages (use /result KEY for an answer):\n");
        for (work.recent[0..work.recent_count]) |recent| {
            try std.Io.File.stdout().writeStreamingAll(init.io, "  ");
            try writeSafeText(init.io, recent.message.slice());
            try std.Io.File.stdout().writeStreamingAll(init.io, ": ");
            try writeSafeField(init.io, "", recent.outcome.slice());
        }
    }
}

fn writeSafeField(io: std.Io, label: []const u8, value: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, label);
    try writeSafeText(io, value);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn writeSafeText(io: std.Io, value: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    var text: TerminalText = .{ .mode = .line };
    try text.feed(&writer.interface, value);
    try text.finish(&writer.interface);
    try writer.flush();
}

fn runSession(init: std.process.Init, destination: []const u8, reference: []const u8, initial_text: ?[]const u8) anyerror!void {
    // Callers own canonical Store resolution and complete Session selection.
    errdefer |err| notice: {
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
    showSessionStatus(init, .{ .io = init.io }, destination, reference, .opening) catch |err| {
        if (err == error.SessionNotConfigured) TerminalText.diagnostic("rui: configure this Session before entering it\n", .{});
        return @as(anyerror!void, err);
    };
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &directory_buffer);
    const scratch = try renderScratch(init);
    defer scratch.close(init.io);
    return SessionFrontend.run(init, destination, reference, directory, scratch, sessionCommand, initial_text);
}

fn resumeSession(init: std.process.Init, args: []const []const u8) !void {
    var store: ?[]const u8 = null;
    var reference: ?[]const u8 = null;
    var session_hex: [protocol.max_session_bytes]u8 = undefined;
    var last = false;
    var literal = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!literal and std.mem.eql(u8, arg, "--store") and store == null) store = try takeValue(args, &index) else if (!literal and std.mem.eql(u8, arg, "--session") and reference == null) reference = try takeValue(args, &index) else if (!literal and std.mem.eql(u8, arg, "--session-hex") and reference == null) reference = try decodeHexIdentity(try takeValue(args, &index), &session_hex) else if (!literal and std.mem.eql(u8, arg, "--last") and !last) last = true else if (!literal and std.mem.eql(u8, arg, "--")) literal = true else if (reference == null and (literal or !std.mem.startsWith(u8, arg, "-"))) reference = arg else return usage();
    }
    if (last == (reference != null)) return usage();
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) return error.InteractiveTerminalRequired;
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const paths = try platform.resolveClientPaths(init.io, try selectedStore(init, store, &fallback));
    const destination = paths.store.slice();
    try startHost(init, destination, true);
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
        var cursor: client.SessionListCursor = .{};
        while (true) {
            try file.setLength(init.io, 0);
            try init.io.vtable.fileSeekTo(init.io.userdata, file, 0);
            var buffer: client.ReplyBuffer = .{};
            const reply = try client.listSessions(init.io, destination, workspace, cursor, file, &buffer);
            const decoded = try client.SessionListReply.decode(init.io, file, workspace, cursor, reply);
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
            try inspectAction(init, requests_context, &.{ "--store", destination, "--session", reference, "--action", id }, true);
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
        var setup_args: [6][]const u8 = undefined;
        const count = interactiveTokens(input_buffer["/setup".len..text.len], &setup_args) catch {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: /setup [--store PATH] [--provider codex] [--model gpt-6-luna | --clear-model]; no changes saved.\n");
            return;
        };
        setup(init, setup_args[0..count], true) catch |err| TerminalText.diagnostic("rui: /setup: {s}; active Session unchanged\n", .{@errorName(err)});
    } else if (std.mem.eql(u8, text, "/status")) {
        showSessionStatus(init, requests_context, destination, reference, .full) catch |err| {
            if (err == error.CanonicalStoreFailure) return err;
            TerminalText.diagnostic("rui: status: {s}\n", .{@errorName(err)});
        };
    } else if (std.mem.eql(u8, text, "/requests")) {
        sessionRequests(init, destination, reference) catch |err| TerminalText.diagnostic("rui: requests: {s}\n", .{@errorName(err)});
    } else if (std.mem.startsWith(u8, text, "/result ")) {
        const saved = client.MessageAddress.init(destination, reference, std.mem.trim(u8, text[8..], " ")) catch |err| {
            TerminalText.diagnostic("rui: result key: {s}\n", .{@errorName(err)});
            return;
        };
        showResult(init, requests_context, &saved) catch |err| {
            if (err == error.CanonicalStoreFailure) return err;
            TerminalText.diagnostic("rui: result: {s}\n", .{@errorName(err)});
        };
    } else if (std.mem.eql(u8, text, "/configure") or std.mem.startsWith(u8, text, "/configure ")) {
        var config_args: [24][]const u8 = undefined;
        config_args[0..4].* = .{ "--store", destination, "--session", reference };
        var count: usize = 4;
        var arguments: [20][]const u8 = undefined;
        const argument_count = interactiveTokens(input_buffer["/configure".len..text.len], &arguments) catch {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Usage: /configure --model MODEL [--tools bash] [--permission-mode ask|bypass] (settings for this Session only)\n");
            return;
        };
        var next: usize = 0;
        var valid = true;
        while (next < argument_count) {
            const flag = arguments[next];
            next += 1;
            const takes_value = std.mem.eql(u8, flag, "--workspace") or std.mem.eql(u8, flag, "--provider") or
                std.mem.eql(u8, flag, "--model") or std.mem.eql(u8, flag, "--instructions") or
                std.mem.eql(u8, flag, "--tools") or std.mem.eql(u8, flag, "--permission-mode") or
                std.mem.eql(u8, flag, "--output-schema");
            if (!takes_value and !std.mem.eql(u8, flag, "--text-output")) {
                valid = false;
                break;
            }
            const value = if (takes_value and next < argument_count) arguments[next] else null;
            if (takes_value and value != null) next += 1;
            if ((takes_value and value == null) or count + (if (takes_value) @as(usize, 2) else 1) > config_args.len) {
                valid = false;
                break;
            }
            config_args[count] = flag;
            count += 1;
            if (value) |setting| {
                if (std.mem.eql(u8, setting, "-") and
                    (std.mem.eql(u8, flag, "--instructions") or std.mem.eql(u8, flag, "--output-schema")))
                {
                    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Use a file for /configure content; terminal stdin belongs to this Session.\n");
                    return;
                }
                config_args[count] = setting;
                count += 1;
            }
        }
        if (valid and count > 4) {
            configure(init, requests_context, config_args[0..count], true) catch |err| {
                TerminalText.diagnostic("rui: configure: {s}; check saved requests before retrying\n", .{@errorName(err)});
                if (err == error.CanonicalStoreFailure) return err;
            };
        } else try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Usage: /configure --model MODEL [--tools bash] [--permission-mode ask|bypass] (settings for this Session only)\n");
    } else {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Unknown command. Type /help.\n");
    }
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

fn sessionRequests(init: std.process.Init, store: []const u8, session_ref: []const u8) !void {
    const canonical = try platform.resolveClientPaths(init.io, store);
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &path);
    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Local recovery handles (not Host work status):\n");
    var dir = std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(init.io);
    if ((try dir.stat(init.io)).permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const handle = entry.name[0 .. entry.name.len - ".json".len];
        const saved = savedRequest(init, handle) catch continue;
        if (!saved.store.eql(canonical.store.slice()) or !saved.session.eql(session_ref)) continue;
        var line: [100]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "  {s} ({s})\n", .{ handle, saved.kind.slice() }));
    }
}

fn stopSession(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var input = client.SessionStopInput{ .store = "", .session = "" };
    var location: @FieldType(client.CaptureTarget, "explicit") = .{ .record = "", .key = "" };
    var drop_reply: ?[]const u8 = null;
    var explicit_store: ?[]const u8 = null;
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) location.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            location.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--test-drop-reply")) drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.session.len == 0 or (location.record.len == 0) != !key_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target: client.CaptureTarget = if (key_seen) .{ .explicit = location } else .{ .generated = try requestDirectory(init, &directory_buffer) };
    var captured = try client.captureSessionStop(io, input, target);
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(io);
        if (!key_seen) try announceCapture(io, captured.identity().key.slice());
        break :blk try client.sendCaptured(io, &captured, drop_reply, &reply_buffer);
    };
    try writeMutationReply(io, reply, .json);
}

fn interruptModel(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var input = client.ModelInterruptionInput{
        .store = "",
        .session = "",
        .turn_id = 0,
        .operation_id = 0,
    };
    var location: @FieldType(client.CaptureTarget, "explicit") = .{ .record = "", .key = "" };
    var drop_reply: ?[]const u8 = null;
    var explicit_store: ?[]const u8 = null;
    var key_seen = false;
    var turn_seen = false;
    var operation_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) location.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            location.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--turn")) {
            input.turn_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            turn_seen = true;
        } else if (std.mem.eql(u8, arg, "--operation")) {
            input.operation_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            operation_seen = true;
        } else if (std.mem.eql(u8, arg, "--test-drop-reply")) drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.session.len == 0 or (location.record.len == 0) != !key_seen or
        !turn_seen or !operation_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target: client.CaptureTarget = if (key_seen) .{ .explicit = location } else .{ .generated = try requestDirectory(init, &directory_buffer) };
    var captured = try client.captureModelInterruption(io, input, target);
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(io);
        if (!key_seen) try announceCapture(io, captured.identity().key.slice());
        break :blk try client.sendCaptured(io, &captured, drop_reply, &reply_buffer);
    };
    try writeMutationReply(io, reply, .json);
}

fn decideAction(init: std.process.Init, args: []const []const u8, decision: @FieldType(client.PermissionDecisionInput, "decision")) !void {
    const io = init.io;
    var input = client.PermissionDecisionInput{
        .store = "",
        .session = "",
        .action_id = 0,
        .decision = decision,
    };
    var location: @FieldType(client.CaptureTarget, "explicit") = .{ .record = "", .key = "" };
    var drop_reply: ?[]const u8 = null;
    var explicit_store: ?[]const u8 = null;
    var key_seen = false;
    var action_seen = false;
    var session: ?[]const u8 = null;
    var session_hex: [protocol.max_session_bytes]u8 = undefined;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) location.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            location.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session") or std.mem.eql(u8, arg, "--session-hex")) {
            if (session != null) return error.DuplicateArgument;
            const value = try takeValue(args, &index);
            session = if (std.mem.eql(u8, arg, "--session-hex")) try decodeHexIdentity(value, &session_hex) else value;
        } else if (std.mem.eql(u8, arg, "--action")) {
            if (action_seen) return error.DuplicateArgument;
            input.action_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            action_seen = true;
        } else if (std.mem.eql(u8, arg, "--test-drop-reply")) drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    input.session = session orelse return usage();
    if (input.session.len == 0 or !action_seen or (location.record.len == 0) != !key_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const human = !key_seen;
    const target: client.CaptureTarget = if (human) .{ .generated = try requestDirectory(init, &directory_buffer) } else .{ .explicit = location };
    var captured = try client.capturePermissionDecision(io, input, target);
    const saved = captured.identity().*;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(io);
        if (human) try announceCapture(io, saved.key.slice());
        break :blk try client.sendCaptured(io, &captured, drop_reply, &reply_buffer);
    };
    try writeMutationReply(io, reply, .json);
}

fn retry(io: std.Io, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var record: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--kind")) kind = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.retry(io, store_path orelse return usage(), record orelse return usage(), kind orelse return usage(), &reply_buffer);
    try writeMutationReply(io, reply, .json);
}

fn observe(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const identity = try requestIdentity(init, args);
    var reply_buffer: client.ReplyBuffer = .{};
    const target = identity.key.slice();
    const reply = try client.observeCommand(io, identity.store.slice(), target, &reply_buffer);
    const observation = try checkedObservation(io, reply, target);
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writer.interface.writeAll("{\"version\":\"1\",\"type\":\"command_observation\",\"key\":");
    try std.json.Stringify.value(observation.key.slice(), .{}, &writer.interface);
    try writer.interface.writeAll(",\"observation\":");
    try observation.writeJson(&writer.interface);
    try writer.interface.writeAll("}\n");
    try writer.flush();
}

fn inspect(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var store_path: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var profile: protocol.ReportProfile = .current;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) {
            store_path = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--session")) {
            session = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--profile")) {
            const value = try takeValue(args, &index);
            profile = if (std.mem.eql(u8, value, "current"))
                .current
            else if (std.mem.eql(u8, value, "full"))
                .full
            else
                return error.UnknownReportProfile;
        } else return error.UnknownArgument;
        index += 1;
    }
    const reference = session orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected_store = try selectedStore(init, store_path, &selected_buffer);
    if (profile == .current) {
        const file = try renderScratch(init);
        defer file.close(io);
        var response: client.ReplyBuffer = .{};
        const wire_reply = try client.inspectSession(io, selected_store, reference, .current, file, &response);
        const reply = try client.CurrentReply.decode(io, file, reference, wire_reply);
        if (reply == .failure) {
            try writeCommandReply(io, wire_reply.command);
            return reply.failure.err();
        }
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
        try reply.writeJson(io, file, &writer.interface);
        try writer.interface.writeAll("\n");
        return writer.flush();
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.inspectSession(
        io,
        selected_store,
        reference,
        profile,
        std.Io.File.stdout(),
        &reply_buffer,
    );
    switch (reply) {
        .report => try std.Io.File.stdout().writeStreamingAll(io, "\n"),
        .command => |command_reply| {
            try writeCommandReply(io, command_reply);
            return error.HostInvocationFailed;
        },
    }
}

fn readConversation(init: std.process.Init, args: []const []const u8) !void {
    var store_path: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var store_hex: [protocol.max_store_bytes]u8 = undefined;
    var session_hex: [protocol.max_session_bytes]u8 = undefined;
    var position: ?u64 = null;
    var ordinal: ?u64 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store") or std.mem.eql(u8, arg, "--store-hex")) {
            if (store_path != null) return error.DuplicateArgument;
            const value = try takeValue(args, &index);
            store_path = if (std.mem.eql(u8, arg, "--store-hex")) try decodeHexIdentity(value, &store_hex) else value;
        } else if (std.mem.eql(u8, arg, "--session") or std.mem.eql(u8, arg, "--session-hex")) {
            if (session != null) return error.DuplicateArgument;
            const value = try takeValue(args, &index);
            session = if (std.mem.eql(u8, arg, "--session-hex")) try decodeHexIdentity(value, &session_hex) else value;
        } else if (std.mem.eql(u8, arg, "--position")) position = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else if (std.mem.eql(u8, arg, "--ordinal")) ordinal = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else return error.UnknownArgument;
        index += 1;
    }
    const reference = session orelse return usage();
    const target = position orelse return usage();
    const item = ordinal orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const requests_: client.Requests = .{ .io = init.io };
    if (try requests_.readConversationContent(try selectedStore(init, store_path, &selected_buffer), reference, target, item, null, std.Io.File.stdout())) |failure| {
        try writeReadFailure(init.io, failure, reference);
        return failure.err();
    }
}

fn decodeHexIdentity(encoded: []const u8, buffer: []u8) ![]const u8 {
    if (encoded.len == 0 or encoded.len % 2 != 0 or encoded.len / 2 > buffer.len) return error.InvalidHexIdentity;
    const value = std.fmt.hexToBytes(buffer[0 .. encoded.len / 2], encoded) catch return error.InvalidHexIdentity;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidHexIdentity;
    return value;
}

fn readResult(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const identity = try requestIdentity(init, args);
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
            try writeReadFailure(io, failure, target);
            return failure.err();
        },
    }
}

fn readActionContent(init: std.process.Init, args: []const []const u8, field: enum { call_id, arguments }) !void {
    const io = init.io;
    var store_path: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var action: ?u64 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--session")) session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--action")) action = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else return error.UnknownArgument;
        index += 1;
    }
    const reference = session orelse return usage();
    const target = action orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, store_path, &selected_buffer);
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = switch (field) {
        .call_id => try client.readActionCallId(io, selected, reference, target, std.Io.File.stdout(), &reply_buffer),
        .arguments => try client.readActionArguments(io, selected, reference, target, std.Io.File.stdout(), &reply_buffer),
    };
    switch (reply) {
        .answer => {},
        .command => |command_reply| {
            try writeCommandReply(io, command_reply);
            return error.HostInvocationFailed;
        },
    }
}

fn writeCommandReply(io: std.Io, reply: client.CommandReply) !void {
    try std.Io.File.stdout().writeStreamingAll(io, reply.body);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    try client.checkCanonicalFailure(reply);
}

fn writeReadFailure(io: std.Io, failure: client.ReadFailure, key: []const u8) !void {
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(.{ .key = key, .@"error" = .{
        .status = failure.status,
        .type = failure.diagnostic.type.slice(),
        .code = failure.diagnostic.code.slice(),
    } }, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.flush();
}

fn checkedObservation(io: std.Io, reply: client.ObservationReply, key: []const u8) !client.CommandObservation {
    return switch (reply) {
        .observation => |observation| observation,
        .failure => |failure| {
            try writeReadFailure(io, failure, key);
            return failure.err();
        },
    };
}

fn requestDirectory(init: std.process.Init, buffer: []u8) ![]const u8 {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHome;
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/requests", .{home});
}

fn announceCapture(io: std.Io, handle: []const u8) !void {
    try testGate(io, "RUI_TEST_CAPTURE_GATE");
    // Checked announcement precedes original transmission. Failure retains the
    // durable capture, but cannot accidentally submit unannounced work.
    var line: [160]u8 = undefined;
    try std.Io.File.stderr().writeStreamingAll(io, try std.fmt.bufPrint(&line, "request: {s} (rui request recover {s})\n", .{ handle, handle }));
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

const MutationPresentation = enum {
    json,
    human,
    interactive_configuration,
};

fn writeMutationReply(io: std.Io, reply: client.MutationReply, presentation: MutationPresentation) !void {
    if (presentation == .interactive_configuration and reply.isAccepted())
        return std.Io.File.stdout().writeStreamingAll(io, "Rui: Configured.\n");
    if (presentation == .json) {
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var output = std.Io.File.stdout().writerStreaming(io, &buffer);
        const writer = &output.interface;
        try writeMutationJson(writer, reply);
        try writer.writeByte('\n');
        try output.flush();
        _ = try reply.answer;
        if (!reply.isAccepted()) return error.MutationNotAccepted;
        return;
    }
    try writeSafeField(io, "Store: ", reply.context.store.slice());
    try writeSafeField(io, "Session: ", reply.context.session.slice());
    try writeSafeField(io, "key: ", reply.context.key.slice());
    var target_line: [128]u8 = undefined;
    switch (reply.target) {
        .model_interruption => |target| try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&target_line, "target Turn: {d}; Operation: {d}\n", .{ target.turn, target.operation })),
        .permission_decision => |target| try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&target_line, "target Action: {d}; decision: {s}\n", .{ target.action, @tagName(target.decision) })),
        else => {},
    }
    const answer = reply.answer catch |err| {
        var line: [128]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "invocation: {s} (HTTP {d}); outcome unconfirmed\n", .{ @errorName(err), reply.status }));
        if (reply.diagnostic) |diagnostic| {
            try writeSafeField(io, "type: ", diagnostic.type.slice());
            try writeSafeField(io, "code: ", diagnostic.code.slice());
        }
        return err;
    };
    var line: [128]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "admitted: {s}\n", .{@tagName(answer.result)}));
    try std.Io.File.stdout().writeStreamingAll(io, if (answer.replayed) "replayed: true\n" else "replayed: false\n");
    const code: ?[]const u8 = switch (answer.result) {
        .accepted => null,
        .rejected => |*code| code.slice(),
        .conflict => "idempotency_key_conflict",
    };
    if (code) |value| try writeSafeField(io, "code: ", value);
    if (answer.result == .accepted) switch (answer.result.accepted) {
        .configure => |value| try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "revision: {d}; created: {}\n", .{ value.revision, value.created })),
        .message => |value| try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "queue admission: {d}\n", .{value.admission})),
        .session_stop => |value| {
            if (value.turn) |turn| try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "selected Turn: {d}\n", .{turn})) else try writeSafeField(io, "selected Turn: ", "none");
            try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "admission cutoff: {d}; completion: {s}\n", .{ value.admission_cutoff, @tagName(value.completion) }));
        },
        .model_interruption, .permission_decision => {},
    };
}

// Presentation of owned facts only: no wire representation or second parser.
fn writeMutationJson(writer: *std.Io.Writer, reply: client.MutationReply) !void {
    try writer.writeAll("{\"context\":");
    try std.json.Stringify.value(.{
        .store = reply.context.store.slice(),
        .session = reply.context.session.slice(),
        .key = reply.context.key.slice(),
        .kind = reply.context.kind.slice(),
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

test "mutation JSON renders owned diagnostics and context with bounded writer" {
    const wire = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"busy\\u002fµ\",\"wire_only\":true}";
    var bytes: [wire.len]u8 = wire.*;
    var reply = client.decodeMutationReply(.{ .status = 409, .body = &bytes }, "original/session", .configure);
    try reply.context.store.set("/store");
    try reply.context.key.set("original\"key");
    try reply.context.kind.set("configure");
    @memset(&bytes, 'x');
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeMutationJson(&writer, reply);
    try std.testing.expectEqualStrings("{\"context\":{\"store\":\"/store\",\"session\":\"original/session\",\"key\":\"original\\\"key\",\"kind\":\"configure\"},\"error\":{\"status\":\"409\",\"reason\":\"HostInvocationFailed\",\"certainty\":\"unconfirmed\",\"type\":\"invocation_error\",\"code\":\"busy/µ\"}}", writer.buffered());
    var tiny: [1]u8 = undefined;
    var failing = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, writeMutationJson(&failing, reply));
}

const SavedRequest = client.CapturedIdentity;

fn savedRequest(init: std.process.Init, handle: []const u8) !SavedRequest {
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return client.inspectCaptured(init.io, try requestDirectory(init, &directory_buffer), handle);
}

fn requestIdentity(init: std.process.Init, args: []const []const u8) !SavedRequest {
    if (args.len == 1 and !std.mem.startsWith(u8, args[0], "-")) return savedRequest(init, args[0]);
    if (args.len == 2 and std.mem.eql(u8, args[0], "--")) return savedRequest(init, args[1]);
    var store: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--key")) key = try takeValue(args, &index) else return error.UnknownArgument;
    }
    var identity: SavedRequest = .{};
    try identity.key.set(key orelse return usage());
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try identity.store.set(try selectedStore(init, store, &selected_buffer));
    return identity;
}

fn sessionPage(init: std.process.Init, store: []const u8, workspace: ?[]const u8, cursor: client.SessionListCursor, writer: *std.Io.Writer) !?client.SessionListCursor {
    const file = try renderScratch(init);
    defer file.close(init.io);
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.listSessions(init.io, store, workspace, cursor, file, &buffer);
    const decoded = try client.SessionListReply.decode(init.io, file, workspace, cursor, reply);
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
    if (cursor.after != 0 and page.count != 0) try writer.writeByte(',');
    try page.writeRowsJson(writer);
    return page.next;
}

fn sessions(init: std.process.Init, args: []const []const u8) !void {
    var explicit: ?[]const u8 = null;
    var all = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store") and explicit == null) explicit = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--all") and !all) all = true else return usage();
    }
    var saved: preferences.Values = .{};
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = if (explicit) |value| value else blk: {
        const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
        saved = try preferences.load(home);
        break :blk if (saved.store.len != 0) saved.store.slice() else try preferences.defaultStore(home, &fallback);
    };
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace: ?[]const u8 = if (all) null else blk: {
        var directory = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
        defer directory.close(init.io);
        const length = try directory.realPath(init.io, &workspace_buffer);
        break :blk workspace_buffer[0..length];
    };
    var cursor: client.SessionListCursor = .{};
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try output.interface.writeAll("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[");
    while (true) {
        cursor = (try sessionPage(init, store, workspace, cursor, &output.interface)) orelse break;
    }
    try output.interface.writeAll("],\"next\":null}\n");
    try output.flush();
}

fn requests(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 0) return usage();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &path);
    var dir = std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return std.Io.File.stdout().writeStreamingAll(init.io, "[]\n"),
        else => return err,
    };
    defer dir.close(init.io);
    if ((try dir.stat(init.io)).permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
    try std.Io.File.stdout().writeStreamingAll(init.io, "[");
    var first = true;
    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const handle = entry.name[0 .. entry.name.len - ".json".len];
        if (!client.validRequestHandle(handle)) continue;
        if (!first) try std.Io.File.stdout().writeStreamingAll(init.io, ",");
        var line: [64]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "\"{s}\"", .{handle}));
        first = false;
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "]\n");
}

fn recover(init: std.process.Init, args: []const []const u8) !void {
    const handle = if (args.len == 1) args[0] else if (args.len == 2 and std.mem.eql(u8, args[0], "--")) args[1] else return retry(init.io, args);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var captured = try client.openCaptured(init.io, try requestDirectory(init, &directory_buffer), handle);
    var buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(init.io);
        break :blk try client.sendCaptured(init.io, &captured, null, &buffer);
    };
    try writeMutationReply(init.io, reply, .json);
}

fn showResult(init: std.process.Init, requester: client.Requests, saved: *const client.MessageAddress) !void {
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
        try writeReadFailure(init.io, answer.failure, saved.key.slice());
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

fn tokenString(token: std.json.Token) ![]const u8 {
    return switch (token) {
        .string => |s| s,
        .allocated_string => |s| s,
        else => error.InvalidObservation,
    };
}

fn freeToken(token: std.json.Token) void {
    if (token == .allocated_string) std.heap.c_allocator.free(token.allocated_string);
}

const SessionObservation = struct {
    current: client.Current,
    // The complete Current capture remains owned until all its permissions
    // have been displayed; no per-Action resident list is needed.
    file: std.Io.File,
};

fn inspectWork(init: std.process.Init, requester: client.Requests, store: []const u8, session_ref: []const u8) !SessionObservation {
    const file = try renderScratch(init);
    errdefer file.close(init.io);
    var response: client.ReplyBuffer = .{};
    const reply = try requester.inspectSession(store, session_ref, .current, file, &response);
    switch (try client.CurrentReply.decode(init.io, file, session_ref, reply)) {
        .current => |current| return .{ .current = current, .file = file },
        .unconfigured => return error.SessionNotConfigured,
        .failure => |failure| {
            try writeCommandReply(init.io, reply.command);
            return failure.err();
        },
    }
}

fn showActionable(io: std.Io, report: *const SessionObservation) !void {
    const Sink = struct {
        io: std.Io,
        pub fn visit(self: *@This(), row: client.Current.Attention) !void {
            if (row == .actionable) {
                var buffer: [20]u8 = undefined;
                const action = try std.fmt.bufPrint(&buffer, "{d}", .{row.actionable.action.value});
                try writeSafeField(self.io, "Action requiring attention: ", action);
            }
        }
    };
    var sink: Sink = .{ .io = io };
    try report.current.traverse(io, report.file, &sink);
}

fn inspectAction(init: std.process.Init, requester: client.Requests, args: []const []const u8, interactive: bool) !void {
    const io = init.io;
    var store: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var action: ?u64 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session")) session = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--action")) action = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else return error.UnknownArgument;
    }
    const target = action orelse return usage();
    const reference = session orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, store, &selected_buffer);
    const file = try renderScratch(init);
    defer file.close(io);
    var buffer: client.ReplyBuffer = .{};
    var call_bytes: u64 = 0;
    if (!interactive) {
        const call = try requester.readActionCallId(selected, reference, target, file, &buffer);
        if (call == .command) {
            try writeCommandReply(io, call.command);
            return error.ActionReadFailed;
        }
        call_bytes = call.answer.bytes;
    }
    const arguments = try requester.readActionArguments(selected, reference, target, file, &buffer);
    if (arguments == .command) {
        try writeCommandReply(io, arguments.command);
        return error.ActionReadFailed;
    }
    var line: [96]u8 = undefined;
    if (!interactive) {
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"action\":\"{d}\",\"call_id\":\"", .{target}));
        try writeJsonFileAt(io, file, 0, call_bytes, false);
        try std.Io.File.stdout().writeStreamingAll(io, "\",\"arguments\":\"");
        try writeJsonFileAt(io, file, call_bytes, arguments.answer.bytes, false);
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

fn takeValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingArgumentValue;
    return args[index.*];
}

const usage_text =
    \\usage:
    \\  rui --help | -h
    \\  rui [PROMPT] [--store PATH] [--provider codex] [--model gpt-6-luna]
    \\    Create a fresh live terminal conversation. Bash runs without approval by default.
    \\    Use -- before a prompt equal to a resource name. Type /help in the conversation.
    \\  rui RESOURCE --help
    \\    Resources: session, request, action, host, defaults, auth.
    \\  rui RESOURCE COMMAND --help
    \\    Installed operation help owns exact options. Help needs no Host or credentials.
    \\
    \\For agents and scripts, session configure and session send are separate admission-only
    \\calls. Reads observe once; request read-result streams the original saved answer.
    \\Metadata is one JSON value on stdout; diagnostics and recovery notices use stderr.
    \\Ordinary calls never start a Host or sign in. Administration is explicit.
    \\Use request recover with the original handle or record after uncertainty, not a new key.
    \\A nonzero exit can follow acceptance. Inspection never admits work; recovery can.
    \\Store selection: --store, saved defaults, then HOME/.local/share/rui/store.
    \\Generated captures: HOME/.config/rui/requests. Use explicit --record and --key
    \\to retain a pre-known identity even if every notice and receipt is lost.
    \\
;

fn usage() error{InvalidArguments} {
    std.debug.print("{s}", .{usage_text});
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
