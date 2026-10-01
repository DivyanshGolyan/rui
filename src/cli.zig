const std = @import("std");
const AnswerRenderer = @import("AnswerRenderer.zig");
const TerminalEditor = @import("TerminalEditor.zig");
const SessionTerminal = @import("SessionTerminal.zig");
const FrontendRead = @import("FrontendRead.zig");
const session_view = @import("session_view.zig");
const TerminalText = @import("TerminalText.zig");
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
const tools = @import("tools.zig");

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

pub fn main(init: std.process.Init) !u8 {
    dispatch(init, codex_auth.login) catch |err| {
        if (std.c.isatty(2) != 1) return err;
        reportTerminalFailure(err);
        return 1;
    };
    return 0;
}

// Escaping failures have already unwound terminal custody. The restored TTY
// may still be flow-stopped, so final diagnostics cannot require drainage.
fn reportTerminalFailure(err: anyerror) void {
    const flags = std.c.fcntl(2, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const nonblocking: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const changed = flags & nonblocking == 0;
    if (changed and std.c.fcntl(2, std.c.F.SETFL, flags | nonblocking) < 0) return;
    const name = @errorName(err);
    const vectors = [_]std.posix.iovec_const{
        .{ .base = "error: ", .len = "error: ".len },
        .{ .base = name.ptr, .len = name.len },
        .{ .base = "\n", .len = 1 },
    };
    // Partial output or failure is intentionally not retried. These flags can
    // belong to the same open-file description as stdin/stdout or a parent FD.
    _ = std.c.writev(2, &vectors, vectors.len);
    if (changed and std.c.fcntl(2, std.c.F.SETFL, flags) < 0) {
        // This is already a fatal, terminating path. Do not reopen blocking
        // reporting or claim restoration after an unconfirmed native failure.
        return;
    }
}

fn dispatch(init: std.process.Init, comptime login_exchange: anytype) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) return printUsage();
    if (args.len > 1 and std.mem.eql(u8, args[1], "--resume")) return resumeSession(init, args[2..]);
    if (args.len < 2 or std.mem.startsWith(u8, args[1], "--")) return newSession(init, args[1..]);
    const command = args[1];
    if (std.mem.eql(u8, command, "serve")) {
        try configureHostAllocator(init, args);
        return serve(init, args[2..]);
    }
    if (std.mem.eql(u8, command, "login")) return login(init, args[2..], false, login_exchange);
    if (std.mem.eql(u8, command, "host")) return host(init, args[2..]);
    if (std.mem.eql(u8, command, "setup")) try setup(init, args[2..]) else if (std.mem.eql(u8, command, "sessions")) try sessions(init, args[2..]) else if (std.mem.eql(u8, command, "conversation-content")) try saveConversationContent(init, args[2..]) else if (std.mem.eql(u8, command, "wait-session")) try waitSession(init, args[2..]) else if (std.mem.eql(u8, command, "configure")) try configure(init, args[2..], false) else if (std.mem.eql(u8, command, "message")) try message(init, args[2..]) else if (std.mem.eql(u8, command, "stop-session")) try stopSession(init, args[2..]) else if (std.mem.eql(u8, command, "interrupt-model")) try interruptModel(init, args[2..]) else if (std.mem.eql(u8, command, "deny-action")) try decideAction(init, args[2..], .deny) else if (std.mem.eql(u8, command, "allow-action")) try decideAction(init, args[2..], .allow_once) else if (std.mem.eql(u8, command, "retry")) try retry(init.io, args[2..]) else if (std.mem.eql(u8, command, "observe-command")) try observe(init, args[2..]) else if (std.mem.eql(u8, command, "read-result")) try readResult(init, args[2..]) else if (std.mem.eql(u8, command, "read-action-call-id")) try readActionContent(init, args[2..], .call_id) else if (std.mem.eql(u8, command, "read-action-arguments")) try readActionArguments(init, args[2..]) else if (std.mem.eql(u8, command, "inspect-session")) try inspect(init, args[2..]) else if (std.mem.eql(u8, command, "requests")) try requests(init, args[2..]) else if (std.mem.eql(u8, command, "recover")) try recover(init, args[2..]) else if (std.mem.eql(u8, command, "follow")) try follow(init, args[2..]) else if (std.mem.eql(u8, command, "result")) try result(init, args[2..]) else if (std.mem.eql(u8, command, "inspect-action")) try inspectAction(init, args[2..], false) else return usage();
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

const Presentation = enum { human, json, interactive };
const action_choice_prompt = "Allow once, deny, or later? [a/d/l] ";
const answer_divider = "\n────────\n";

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

fn setup(init: std.process.Init, args: []const []const u8) !void {
    const home = init.environ_map.get("HOME") orelse {
        std.debug.print("rui: setup needs an absolute HOME; no preferences saved.\n", .{});
        return error.HomeUnavailable;
    };
    var store: ?[]const u8 = null;
    var selected_provider: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var clear_model = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, flag, "--provider")) selected_provider = try takeValue(args, &index) else if (std.mem.eql(u8, flag, "--model")) model = try takeValue(args, &index) else if (std.mem.eql(u8, flag, "--clear-model") and !clear_model) clear_model = true else return usage();
    }
    if (clear_model and model != null) return usage();
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
    const changed = store != null or selected_provider != null or model != null or clear_model;
    const values = (if (changed) preferences.update(home, .{ .store = store, .provider = selected_provider, .model = if (model) |value| .{ .set = value } else if (clear_model) .clear else .keep }, readiness) else preferences.load(home)) catch |err| {
        if (err == error.PreferenceDirectorySyncFailed) {
            std.debug.print("rui: setup save durability unconfirmed; inspect HOME/.config/rui/preferences before another update. No Session changed.\n", .{});
        } else if (err == error.UnsupportedPreferenceProvider) {
            std.debug.print("rui: setup supports only --provider codex; no preferences saved.\n", .{});
        } else if (err == error.PreferenceProviderRequired) {
            std.debug.print("rui: setup needs --provider codex with --model; no preferences saved.\n", .{});
        } else if (err == error.InvalidPreferenceModel) {
            std.debug.print("rui: setup model must be 1–256 printable non-space ASCII bytes; no preferences saved.\n", .{});
        } else if (err == error.InvalidPreferenceStore or err == error.FileNotFound) {
            std.debug.print("rui: setup Store must be an existing private, canonicalizable absolute directory; no alternate Store selected.\n", .{});
        } else std.debug.print("rui: setup {s}: {s}; inspect HOME/.config/rui/preferences and its private directory before retrying. No alternate Store selected.\n", .{ if (changed) "save failed" else "read failed", @errorName(err) });
        return err;
    };
    var fallback_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected_store: ?[]const u8 = if (values.store.len != 0) values.store.slice() else preferences.defaultStore(home, &fallback_buffer) catch null;
    // Preferences are local hints, not Session settings or Host facts.
    try std.Io.File.stdout().writeStreamingAll(init.io, if (changed) "Saved defaults for future Sessions. Active Session unchanged.\n" else "Defaults (read only):\n");
    try std.Io.File.stdout().writeStreamingAll(init.io, "Store: ");
    try writeSafeText(init.io, selected_store orelse "unavailable (HOME destination path too long)");
    try std.Io.File.stdout().writeStreamingAll(init.io, if (values.store.len != 0) " (saved)\n" else " (HOME fallback)\n");
    try writeSafeField(init.io, "Provider: ", if (values.provider.len != 0) values.provider.slice() else "not selected");
    try writeSafeField(init.io, "Model: ", if (values.model.len != 0) values.model.slice() else "provider recommendation (not pinned)");
    var output: [std.Io.Dir.max_path_bytes + 512]u8 = undefined;
    const codex = model_adapter.capability(readiness);
    const local_status = switch (readiness) {
        .configured => "Codex credential: configured locally (remote acceptance not checked).\n",
        .renewal_due => "Codex credential: renewal due; locally usable, runtime renews at dispatch (remote acceptance not checked).\n",
        .missing => "Codex credential: missing.\n",
        .refresh_required => "Codex credential: refresh required; a pending refresh may require login.\n",
        .credential_error => "Codex credential: error reading private Rui credential; inspect it before use.\n",
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, local_status);
    const selection: ?provider_selection.Selection = provider_selection.resolve(&.{codex}, null, null, if (values.provider.len != 0) values.provider.slice() else null, if (values.model.len != 0) values.model.slice() else null) catch |err| blk: {
        const advice: []const u8 = switch (err) {
            error.UnsupportedSelectionProvider => "Next Session: saved provider is unsupported; no fallback. Repair with `rui setup --provider codex --model gpt-6-luna`.\n",
            error.UnsupportedSelectionModel => "Next Session: saved model is unsupported; no fallback. Repair with `rui setup --provider codex --model gpt-6-luna`.\n",
        };
        try std.Io.File.stdout().writeStreamingAll(init.io, advice);
        break :blk null;
    };
    if (selection) |choice| switch (choice) {
        .chooser => try std.Io.File.stdout().writeStreamingAll(init.io, "Next Session: choose a supported provider; Codex login: `rui login codex`.\n"),
        .selected => |selected| {
            const note: []const u8 = switch (selected.readiness) {
                .configured => "local credential configured; remote acceptance not checked",
                .renewal_due => "local credential renewal due; runtime renews at dispatch",
                .missing => "credential missing; run `rui login codex`. No fallback",
                .refresh_required => "credential refresh required; login may be required. No fallback",
                .credential_error => "credential error; inspect private Rui credential or log in. No fallback",
            };
            const line = try std.fmt.bufPrint(&output, "Next Session: {s} / {s} ({s}).\n", .{ selected.provider, selected.model, note });
            try std.Io.File.stdout().writeStreamingAll(init.io, line);
        },
    };
    // Host capabilities are startup facts, not credential or Session state.
    const host_details: []const u8 = if (selected_store) |destination| switch (client.hostStatus(init.io, destination)) {
        .ready => |current| if (current.capabilities.managed_authentication and current.capabilities.model)
            "Host: managed Codex enabled (credentials checked locally, not by status).\n"
        else
            "Host: ready without managed Codex; use `rui serve --codex` for new managed work.\n",
        .unavailable => "Host: unavailable; setup does not start it.\n",
        .owned_unavailable => "Host: owned but unavailable; inspect before submitting work.\n",
        .incompatible => "Host: incompatible; inspect before submitting work.\n",
        .access_failure => "Host: access failure; inspect Store permissions.\n",
    } else "Host: selected Store unavailable; setup does not start it.\n";
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
        std.debug.print("rui: cannot read private setup defaults ({s}); use rui setup to inspect or repair them. No Store selected.\n", .{@errorName(err)});
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
    if (start) return startHost(init, selected, true);
    if (stop) return stopHost(init.io, selected, target);
    switch (client.hostStatus(init.io, selected)) {
        .ready => |ready| {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Host: ready\n");
            try writeSafeField(init.io, "Store: ", ready.store.slice());
            var line: [160]u8 = undefined;
            const instance = std.fmt.bytesToHex(ready.instance, .lower);
            try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "Wire: {s}\nActive capacity: {d}\nBash: {s}\nModel: {s}\nManaged authentication: {s}\nInstance: {s}\n", .{ protocol.wire_version, ready.active_capacity, if (ready.capabilities.bash) "enabled" else "disabled", if (ready.capabilities.model) "enabled" else "disabled", if (ready.capabilities.managed_authentication) "enabled" else "disabled", &instance }));
        },
        .unavailable => try std.Io.File.stdout().writeStreamingAll(init.io, "Host: unavailable (no current Store owner established)\n"),
        .owned_unavailable => try std.Io.File.stdout().writeStreamingAll(init.io, "Host: owned but unavailable (starting or draining; completion unconfirmed)\n"),
        .incompatible => try std.Io.File.stdout().writeStreamingAll(init.io, "Host: incompatible (protected reply or wire version)\n"),
        .access_failure => try std.Io.File.stdout().writeStreamingAll(init.io, "Host: access failure (selected Store or protected Host endpoint)\n"),
    }
}

fn stopHost(io: std.Io, selected: []const u8, explicit_instance: ?protocol.InstanceId) !void {
    const target = explicit_instance orelse switch (client.hostStatus(io, selected)) {
        .ready => |ready| ready.instance,
        .unavailable, .owned_unavailable => {
            std.debug.print("rui: no ready Host identity to stop. Ownership or completion is unconfirmed; inspect rui host status.\n", .{});
            return error.HostStopUnconfirmed;
        },
        .incompatible => return error.IncompatibleHost,
        .access_failure => return error.StoreAccessFailed,
    };
    const paths = try platform.resolveClientPaths(io, selected);
    const hex = std.fmt.bytesToHex(target, .lower);
    try std.Io.File.stdout().writeStreamingAll(io, "Rui: Stop affects all work in this Store. Retain this exact target if the reply is lost.\n");
    try writeSafeField(io, "Store: ", paths.store.slice());
    var target_line: [128]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&target_line, "Host instance: {s} (retry with --instance {s})\n", .{ &hex, &hex }));
    var reply: client.ReplyBuffer = .{};
    const outcome = client.stopHost(io, .{ .store = paths.store.slice(), .instance = target }, &reply) catch |err| {
        std.debug.print("rui: stop reply unconfirmed ({s}); inspect this Store and retry only the same --instance target. Do not target a replacement implicitly.\n", .{@errorName(err)});
        return err;
    };
    switch (outcome) {
        .acknowledged => try std.Io.File.stdout().writeStreamingAll(io, "Rui: Stop acknowledged; completion and lease release are not confirmed. Inspect rui host status.\n"),
        .instance_changed => {
            std.debug.print("rui: Host instance changed; replacement was not stopped. Inspect rui host status before any new intent.\n", .{});
            return error.HostInstanceChanged;
        },
        .unavailable => {
            std.debug.print("rui: Host stop unavailable; shutdown/completion unconfirmed. Inspect rui host status; do not switch the retry target.\n", .{});
            return error.HostStopUnconfirmed;
        },
    }
}

fn startHost(init: std.process.Init, selected: []const u8, announce: bool) !void {
    const io = init.io;
    switch (client.hostStatus(io, selected)) {
        .ready => |ready| {
            if (announce) {
                try std.Io.File.stdout().writeStreamingAll(io, "Rui: Attached to the ready Host; its existing capacity and capabilities win.\n");
                try writeHostDiagnostics(io, ready.store.slice());
            }
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
    // Application policy lives here. The synchronous launcher borrows these
    // terminated strings and pointer framing through final exec/error handoff;
    // all storage is prepared before any detach fork.
    const argv = [_:null]?[*:0]const u8{
        @ptrCast(&executable_buffer), "serve", "--store", store_z.ptr,
        "--active-capacity",          "8",     "--codex",
    };
    const launched = rui_launch_detached(argv[0].?, &argv, argv.len);
    if (launched != 0) {
        std.debug.print("rui: detached Host could not execute (OS error {d}); Store ownership was not inferred.\n", .{launched});
        return error.HostLaunchFailed;
    }
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_s;
    while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < until) {
        switch (client.hostStatusUntil(io, paths.store.slice(), until)) {
            .ready => |ready| {
                if (announce) {
                    var line: [100]u8 = undefined;
                    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "Rui: Host ready (active capacity {d}); existing settings win.\n", .{ready.active_capacity}));
                    try writeHostDiagnostics(io, ready.store.slice());
                }
                return;
            },
            .incompatible => return error.IncompatibleHost,
            .access_failure => return error.StoreAccessFailed,
            .unavailable, .owned_unavailable => {},
        }
        const remaining = until - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (remaining > 0) try std.Io.sleep(io, .fromNanoseconds(@intCast(@min(remaining, 100 * std.time.ns_per_ms))), .awake);
    }
    std.debug.print("rui: Host readiness unconfirmed after 10 seconds. Inspect rui host status and the selected Store's diagnostics/ startup records if present; do not kill or reclaim an uncertain owner.\n", .{});
    return error.HostReadinessUnconfirmed;
}

fn writeHostDiagnostics(io: std.Io, store: []const u8) !void {
    var location: [protocol.max_store_bytes + "/diagnostics".len]u8 = undefined;
    try writeSafeField(io, "Diagnostics: ", try std.fmt.bufPrint(&location, "{s}/diagnostics", .{store}));
}

fn login(init: std.process.Init, args: []const []const u8, interactive: bool, comptime exchange: anytype) !void {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "codex")) return usage();
    // Guided login already owns the scope through its provider chooser.
    var interrupt = if (interactive) null else LoginInterrupt.init();
    defer if (interrupt) |*scope| scope.deinit();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try credentialPath(init, &path_buffer, true);
    {
        var existing: codex_credentials.Record = undefined;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&existing));
        // Preflight uses no old generation/account to authorize publication.
        // Installation rereads under the exclusive lock after its gate wins.
        if (loginInterrupted()) return error.LoginInterrupted;
        _ = try codex_credentials.readSnapshotInto(path, &existing);
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
        return std.Io.File.stdout().writeStreamingAll(init.io, "). Inspect rui setup; active Session unchanged.\n");
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, if (added)
        "Rui: No provider default existed; Codex selected for future Sessions (gpt-6-luna).\n"
    else
        "Rui: Existing provider default unchanged.\n");
}

const LoginState = enum(u8) { cancellable, cancelled, publishing };
var login_state = std.atomic.Value(LoginState).init(.cancellable);

const LoginInterrupt = struct {
    previous: std.posix.Sigaction,

    fn init() LoginInterrupt {
        // Borrowers that survive into login inherit blocked SIGINT. The
        // terminal thread owns delivery; pending interruption sees initialized
        // state and the new handler only after this handoff is complete.
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

test "one-shot login interruption preserves publication and independent defaults" {
    const Fixture = struct {
        var before: bool = false;
        var lock_path: []const u8 = undefined;
        var signal_thread: ?std.Thread = null;

        fn exchange(io: std.Io, callback: anytype, cancelled: *const fn () bool) !codex_auth.Tokens {
            _ = callback;
            if (before) {
                try std.posix.raise(.INT);
                if (cancelled()) return error.LoginInterrupted;
                return error.TestCancellationLost;
            }
            // The real credential owner must wait after winning publication.
            const lock = try std.Io.Dir.cwd().openFile(io, lock_path, .{ .mode = .read_write, .lock = .exclusive });
            signal_thread = try std.Thread.spawn(.{}, struct {
                fn send(held: std.Io.File) void {
                    defer held.close(std.Io.Threaded.global_single_threaded.io());
                    const clock = std.Io.Threaded.global_single_threaded.io();
                    const limit = std.Io.Clock.Timestamp.now(clock, .awake).raw.nanoseconds + std.time.ns_per_s;
                    while (login_state.load(.acquire) != .publishing) {
                        if (std.Io.Clock.Timestamp.now(clock, .awake).raw.nanoseconds > limit) std.c._exit(20);
                        std.Thread.yield() catch {};
                    }
                    std.posix.raise(.INT) catch std.c._exit(21);
                }
            }.send, .{lock});
            var tokens: codex_auth.Tokens = .{};
            try tokens.id_token.set(codex_auth.fixture_id_token);
            try tokens.access_token.set(codex_auth.fixture_access_token);
            try tokens.refresh_token.set("synthetic-refresh");
            try tokens.account_id.set(codex_auth.fixture_account_id);
            return tokens;
        }
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    inline for (.{ .{ true, false, false }, .{ false, false, false }, .{ false, true, false }, .{ true, false, true } }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(io, &home_buffer)];
        var directory = try tmp.dir.createDirPathOpen(io, ".config/rui", .{ .permissions = .fromMode(0o700) });
        defer directory.close(io);
        const lock = try directory.createFile(io, ".codex.json.lock", .{ .read = true, .permissions = .fromMode(0o600) });
        lock.close(io);
        if (case[1]) {
            const file = try directory.createFile(io, "preferences", .{ .permissions = .fromMode(0o600) });
            defer file.close(io);
            try file.writeStreamingAll(io, "version=9\n");
        }
        var lock_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        Fixture.lock_path = try std.fmt.bufPrint(&lock_buffer, "{s}/.config/rui/.codex.json.lock", .{home});
        Fixture.before = case[0];
        var held: ?std.Io.File = if (case[2]) try directory.openFile(io, ".codex.json.lock", .{ .mode = .read_write, .lock = .exclusive }) else null;
        defer if (held) |file| file.close(io);
        const child = std.c.fork();
        if (child < 0) return error.TestForkFailed;
        if (child == 0) {
            // The test runner owns stdout's wire protocol; capture CLI receipts.
            const receipt = directory.createFile(io, "receipt", .{}) catch std.c._exit(27);
            if (std.c.dup2(receipt.handle, 1) < 0) std.c._exit(28);
            receipt.close(io);
            const previous: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(.INT, &previous, null);
            var environment = std.process.Environ.Map.init(std.heap.c_allocator);
            environment.put("HOME", home) catch std.c._exit(22);
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            const args = [_][*:0]const u8{ "rui", "login", "codex" };
            const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &args }, .environ = .empty }, .arena = &arena, .gpa = std.heap.c_allocator, .io = io, .environ_map = &environment, .preopens = .empty };
            const outcome = dispatch(init, Fixture.exchange);
            if (Fixture.signal_thread) |thread| thread.join();
            if (case[0]) {
                if (outcome) |_| std.c._exit(23) else |err| if (err != error.LoginInterrupted) std.c._exit(24);
            } else outcome catch std.c._exit(25);
            var restored: std.posix.Sigaction = undefined;
            std.posix.sigaction(.INT, null, &restored);
            if (restored.handler.handler != std.posix.SIG.DFL) std.c._exit(26);
            std.c._exit(0);
        }
        var status: c_int = undefined;
        if (case[2]) {
            const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 5 * std.time.ns_per_s;
            while (std.c.waitpid(child, &status, std.c.W.NOHANG) == 0) {
                if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= until) {
                    std.posix.kill(child, .KILL) catch {};
                    _ = std.c.waitpid(child, &status, 0);
                    return error.PrepublicationWaitedForCredentialLock;
                }
                try std.Io.sleep(io, .fromMilliseconds(10), .awake);
            }
            held.?.close(io);
            held = null;
        } else try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/.config/rui/codex.json", .{home});
        if (case[0]) {
            try std.testing.expectError(error.FileNotFound, codex_credentials.load(path));
            try std.testing.expect((try preferences.load(home)).provider.len == 0);
        } else {
            var record = try codex_credentials.load(path);
            defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
            try std.testing.expectEqualStrings(codex_auth.fixture_account_id, record.account_id.slice());
            try std.testing.expectEqual(@as(u64, 1), record.generation);
            if (case[1]) try std.testing.expectError(error.UnsupportedPreferencesVersion, preferences.load(home)) else {
                const defaults = try preferences.load(home);
                try std.testing.expectEqualStrings("codex", defaults.provider.slice());
                try std.testing.expectEqual(@as(usize, 0), defaults.model.len);
            }
        }
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
    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Supported integration: Codex. Login stores Rui-owned credentials; defer leaves this Session and Host work unchanged.\n");
    var choice_buffer: [16]u8 = undefined;
    const choice = (TerminalEditor.readLine(init.io, &choice_buffer, "Provider: [c] Codex login, [d] defer > ", false) catch |err| switch (err) {
        error.StreamTooLong, error.InvalidTerminalInput => {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Choose c or d. No login or preference change.\n");
            return;
        },
        else => return err,
    }) orelse {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Login deferred. Inspect saved work with /status or /result.\n");
        return;
    };
    if (std.mem.eql(u8, choice, "d")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Login deferred. Inspect saved work with /status or /result.\n");
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
            error.LoginDenied => "Rui: Login denied. No provider preference changed; retry /login if intended.\n",
            error.LoginExpired => "Rui: Login expired. No provider preference changed; retry /login for a fresh code.\n",
            else => "Rui: Login failed or credential save unconfirmed. Inspect rui setup before retrying; no Session binding changed.\n",
        };
        try std.Io.File.stdout().writeStreamingAll(init.io, advice);
        return;
    };
}

fn newSession(init: std.process.Init, args: []const []const u8) !void {
    var store: ?[]const u8 = null;
    var explicit_provider: ?[]const u8 = null;
    var explicit_model: ?[]const u8 = null;
    var drop_reply: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store") and store == null) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--provider") and explicit_provider == null) explicit_provider = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--model") and explicit_model == null) explicit_model = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--test-drop-reply") and drop_reply == null) drop_reply = try takeValue(args, &index) else return usage();
    }
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) {
        std.debug.print("rui needs terminal input and output to create a Session; use explicit one-shot commands for scripts. No Host or Session changed.\n", .{});
        return error.InteractiveTerminalRequired;
    }
    var cwd = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
    defer cwd.close(init.io);
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace_length = try cwd.realPath(init.io, &workspace_buffer);
    const workspace = workspace_buffer[0..workspace_length];

    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    var defaults: preferences.Values = .{};
    var credential_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const credential = try credentialPath(init, &credential_buffer, false);
    var selection: provider_selection.Selection = undefined;
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var selected_store: []const u8 = undefined;
    var prompted = false;
    while (true) {
        // All needed selectors explicit means no read at all, including after
        // login. Otherwise decode safe fields, then check selected resources.
        if (store == null or explicit_provider == null or explicit_model == null)
            defaults = try preferences.load(home);
        const now: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds, std.time.ns_per_s));
        const readiness: provider_selection.Readiness = if (codex_auth.localStatus(credential, now)) |state| switch (state) {
            .missing => .missing,
            .configured => .configured,
            .renewal_due => .renewal_due,
            .refresh_required => .refresh_required,
        } else |_| .credential_error;
        selection = provider_selection.resolve(&.{model_adapter.capability(readiness)}, explicit_provider, explicit_model, if (defaults.provider.len == 0) null else defaults.provider.slice(), if (defaults.model.len == 0) null else defaults.model.slice()) catch |err| {
            std.debug.print("rui: unsupported prospective provider/model ({s}); inspect rui setup. No Session created.\n", .{@errorName(err)});
            return err;
        };
        selected_store = store orelse (if (defaults.store.len != 0) defaults.store.slice() else try preferences.defaultStore(home, &fallback));
        if (store == null and defaults.store.len != 0) {
            // A saved destination is an existing resource, never a candidate
            // for recreation. Preserve this distinction after reselection.
            _ = try platform.resolveClientPaths(init.io, selected_store);
        } else try platform.validateStoreDestination(init.io, selected_store);
        switch (client.hostStatus(init.io, selected_store)) {
            .ready => |ready| if (!ready.capabilities.model) {
                std.debug.print("rui: selected Host has no model capability; no credentials repaired or Session created. It was not restarted.\n", .{});
                return error.HostModelUnavailable;
            },
            .access_failure => return error.StoreAccessFailed,
            .incompatible => return error.IncompatibleHost,
            .unavailable, .owned_unavailable => {},
        }
        if (selection == .selected and selection.selected.readiness.usable()) break;
        if (prompted) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No new Session created. Use rui setup or rui login codex when ready; existing work is unchanged.\n");
            return;
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No locally ready provider for a new Session. Choose Codex login or defer; saved work remains inspectable.\n");
        try guideProviderLogin(init);
        prompted = true;
    }
    const selected = selection.selected;
    try startHost(init, selected_store, false);
    const paths = try platform.resolveClientPaths(init.io, selected_store);
    const destination = paths.store.slice();
    const ready = switch (client.hostStatus(init.io, destination)) {
        .ready => |current| current,
        else => return error.HostReadinessUnconfirmed,
    };
    if (!ready.capabilities.model) {
        std.debug.print("rui: selected Host has no model capability; it was not restarted. Inspect rui host status before creating a Session.\n", .{});
        return error.HostModelUnavailable;
    }
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var saved: client.CapturedIdentity = undefined;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        errdefer |err| std.debug.print("rui: configuration not confirmed ({s}); inspect rui requests and recover only a saved original key. Do not replace uncertain work.\n", .{@errorName(err)});
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
        defer captured.close(init.io);
        saved = captured.identity().*;
        try announceCapture(init.io, saved.key.slice());
        try writeSafeField(init.io, "Rui: New Session intent: ", saved.session.slice());
        break :blk try client.sendCaptured(init.io, &captured, drop_reply, &reply_buffer);
    };
    if (!try acceptedReply(reply)) {
        try writeAdmission(init.io, reply, null);
        return error.SessionConfigurationRejected;
    }
    try enterSessionWithHistory(init, &.{ "--store", saved.store.slice(), "--session", saved.session.slice() }, false);
}

fn resumeSession(init: std.process.Init, args: []const []const u8) !void {
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) {
        std.debug.print("rui --resume needs a terminal; use rui sessions and explicit one-shot inspection in scripts. No Session changed.\n", .{});
        return error.InteractiveTerminalRequired;
    }
    var explicit_store: ?[]const u8 = null;
    var reference: ?[]const u8 = null;
    var positional_only = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (!positional_only and std.mem.eql(u8, args[index], "--")) {
            positional_only = true;
        } else if (!positional_only and std.mem.eql(u8, args[index], "--store") and explicit_store == null) {
            explicit_store = try takeValue(args, &index);
        } else if (reference == null and (positional_only or !std.mem.startsWith(u8, args[index], "--"))) {
            reference = args[index];
        } else return usage();
    }
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = try selectedStore(init, explicit_store, &fallback);
    try startHost(init, store, false);
    const paths = try platform.resolveClientPaths(init.io, store);
    const destination = paths.store.slice();
    const chosen = (try chooseResumeSession(init, destination, reference)) orelse return;
    // Missing credentials never change this Session's bound provider/model;
    // saved history remains available without a login or fallback selection.
    try enterSessionWithHistory(init, &.{ "--store", destination, "--session", chosen.slice() }, true);
}

fn chooseResumeSession(init: std.process.Init, destination: []const u8, reference: ?[]const u8) !?protocol.Bounded(protocol.max_session_bytes) {
    var chosen: protocol.Bounded(protocol.max_session_bytes) = .{};
    if (reference) |direct| {
        try chosen.set(direct);
    } else {
        var cwd = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
        defer cwd.close(init.io);
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const length = try cwd.realPath(init.io, &workspace_buffer);
        var all = false;
        var cursor: client.SessionListCursor = .{};
        while (true) {
            const page = try sessionPage(init, destination, if (all) null else workspace_buffer[0..length], cursor, .interactive);
            if (page.count == 0) std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No Sessions in this scope. Use a to show all Workspaces, or l to defer.\n") catch return error.SessionSelectionDisplayFailed;
            for (page.references[0..page.count], 0..) |entry, i| {
                var label: [32]u8 = undefined;
                writeSafeField(init.io, try std.fmt.bufPrint(&label, "  {d}. ", .{i + 1}), entry.slice()) catch return error.SessionSelectionDisplayFailed;
            }
            std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Choose a number, n for next page, a for all Workspaces, or l to leave: ") catch return error.SessionSelectionDisplayFailed;
            var choice_buffer: [32]u8 = undefined;
            const choice = (TerminalEditor.readLine(init.io, &choice_buffer, "> ", false) catch |err| {
                if (err == error.InteractiveInterrupted) return null;
                return error.SessionSelectionTerminalFailed;
            }) orelse return null;
            if (std.mem.eql(u8, choice, "l")) return null;
            if (std.mem.eql(u8, choice, "a")) {
                all = true;
                cursor = .{};
                continue;
            }
            if (std.mem.eql(u8, choice, "n") and page.next != null) {
                cursor = page.next.?;
                continue;
            }
            const number = std.fmt.parseInt(usize, choice, 10) catch 0;
            if (number != 0 and number <= page.count) {
                chosen = page.references[number - 1];
                break;
            }
            std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No Session selected; choose a listed number or defer.\n") catch return error.SessionSelectionDisplayFailed;
        }
    }
    return chosen;
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
        } else if (std.mem.eql(u8, arg, "--test-transition")) {
            const transition = try takeValue(args, &index);
            if (std.mem.eql(u8, transition, "action-attempt-admitted")) faults.test_transition = .action_attempt_admitted else if (std.mem.eql(u8, transition, "action-result-ready")) faults.test_transition = .action_result_ready else if (std.mem.eql(u8, transition, "action-result-committed")) faults.test_transition = .action_result_committed else return error.UnknownTestTransition;
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

fn configure(init: std.process.Init, args: []const []const u8, interactive: bool) !void {
    return configureEntered(init, args, interactive, null);
}

fn configureEntered(init: std.process.Init, args: []const []const u8, interactive: bool, frontend: ?*Frontend) !void {
    const io = init.io;
    var json = false;
    var input = client.ConfigureInput{
        .store = "",
        .session = .{ .named = "" },
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
        } else if (std.mem.eql(u8, arg, "--session")) input.session = .{ .named = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--workspace")) input.workspace = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--model")) input.model = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--instructions")) input.instructions = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--tools")) input.tools = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--permission-mode")) input.permission_mode = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--output-schema")) input.output_schema = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--text-output")) input.output_schema = .{ .state = .explicit_null } else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.session.named.len == 0 or (location.record.len == 0) != !key_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const human = !key_seen;
    const target: client.CaptureTarget = if (human) .{ .generated = try requestDirectory(init, &directory_buffer) } else .{ .explicit = location };
    var captured = try client.captureConfigure(io, input, target);
    const saved = captured.identity().*;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(io);
        if (human and !interactive) {
            if (json) try announceCaptureJson(io, saved.key.slice()) else try announceCapture(io, saved.key.slice());
        }
        break :blk try readRequest(frontend, io, client.sendCaptured, .{ &captured, drop_reply, &reply_buffer });
    };
    if (interactive) try client.checkCanonicalFailure(reply);
    const accepted = if (human and interactive) try acceptedReply(reply) else false;
    if (human and (!interactive or !accepted)) {
        if (frontend) |owner| try writeAdmissionTo(owner.terminal.writer(), reply, if (json) saved.key.slice() else null) else try writeAdmission(io, reply, if (json) saved.key.slice() else null);
    } else if (!human) try writeCommandReply(io, reply);
    if (human and interactive and accepted) {
        if (frontend) |owner| try owner.terminal.write("Rui: Configured.\n") else try std.Io.File.stdout().writeStreamingAll(io, "Rui: Configured.\n");
    }
    if (human and !json and !interactive) {
        var line: [protocol.max_store_bytes + protocol.max_session_bytes + 64]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "configuration: {s} in {s}\n", .{ saved.session.slice(), saved.store.slice() }));
        if (try acceptedReply(reply)) try std.Io.File.stdout().writeStreamingAll(io, "next: rui --resume REF [--store PATH]\n");
    }
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn message(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var json = false;
    var input = client.MessageInput{ .store = "", .session = "", .text_path = "" };
    var location: @FieldType(client.CaptureTarget, "explicit") = .{ .record = "", .key = "" };
    var drop_reply: ?[]const u8 = null;
    var explicit_store: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) location.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            location.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--text")) input.text_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) drop_reply = try takeValue(args, &index) else if (positional == null and (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-"))) positional = arg else return error.UnknownArgument;
        index += 1;
    }
    if (positional) |value| {
        if (key_seen or input.text_path.len != 0) return usage();
        if (std.mem.eql(u8, value, "-")) input.text_path = "-" else input.text = value;
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
        if (human) {
            if (json) try announceCaptureJson(io, saved.key.slice()) else try announceCapture(io, saved.key.slice());
        }
        break :blk try client.sendCaptured(io, &captured, drop_reply, &reply_buffer);
    };
    if (human) try writeAdmission(io, reply, if (json) saved.key.slice() else null) else try writeCommandReply(io, reply);
    if (human and !json) {
        var line: [protocol.max_store_bytes + protocol.max_session_bytes + 64]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "message: {s} in {s}\n", .{ input.session, input.store }));
        if (try acceptedReply(reply)) try std.Io.File.stdout().writeStreamingAll(io, "next: rui --resume REF [--store PATH]\n");
    }
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn acceptedReply(reply: client.CommandReply) !bool {
    if (reply.status != 200) return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    return std.mem.eql(u8, try stringField(try objectField(parsed.value, "answer"), "status"), "accepted");
}

fn waitSession(init: std.process.Init, args: []const []const u8) !void {
    var store: ?[]const u8 = null;
    var session_ref: ?[]const u8 = null;
    var json = false;
    var terminal_only = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session")) session_ref = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--terminal")) terminal_only = true else if (std.mem.eql(u8, args[index], "--json")) json = true else return error.UnknownArgument;
    }
    const reference = session_ref orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = waitForSession(init, try selectedStore(init, store, &selected_buffer), reference, if (json) .json else .human, terminal_only) catch |err| {
        if (err == error.SessionNotConfigured) std.debug.print("rui: configure this Session before waiting for it\n", .{});
        return err;
    };
}

fn waitForSession(init: std.process.Init, store: []const u8, session_ref: []const u8, presentation: Presentation, terminal_only: bool) !?Work {
    var narration = if (presentation == .interactive) try CallNarration.capture(init, store, session_ref) else CallNarration{};
    const saved = blk: {
        const report = try inspectWork(init, store, session_ref, null);
        defer report.file.close(init.io);
        const work = report.work;
        if (work.workspace.len == 0) return error.SessionNotConfigured;
        const selected = if (work.selected_message) |key| key.slice() else {
            if (presentation == .json) {
                try std.Io.File.stdout().writeStreamingAll(init.io, "{\"return\":\"idle\"}\n");
            } else try std.Io.File.stdout().writeStreamingAll(init.io, if (presentation == .interactive) "Rui: No work to wait for.\n" else "return: idle (no active or queued message)\n");
            return null;
        };
        if (presentation == .json) {
            const selection = try std.json.Stringify.valueAlloc(std.heap.c_allocator, .{
                .event = "selection",
                .session = session_ref,
                .message = selected,
            }, .{});
            defer std.heap.c_allocator.free(selection);
            try std.Io.File.stdout().writeStreamingAll(init.io, selection);
            try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        } else if (presentation == .human) {
            try writeSafeField(init.io, "selected message: ", selected);
        }
        if (!terminal_only and work.action_count > 1) try showActionable(init.io, report.file, presentation == .json, null);
        break :blk try client.MessageAddress.init(store, session_ref, selected);
    };
    if (try followMessage(init, &saved, presentation, if (terminal_only) .terminal_only else .session_blocked, &narration)) |attention|
        return attention;
    if (presentation != .json) try showResult(init, &saved, presentation, null);
    return null;
}

fn showSessionStatus(init: std.process.Init, store: []const u8, session_ref: []const u8, brief: bool, frontend: *Frontend) !void {
    const report = try inspectWork(init, store, session_ref, frontend);
    defer report.file.close(init.io);
    try renderSessionStatus(init, store, session_ref, &report, brief, frontend.terminal.writer());
}

/// Explicit terminal/read ownership. Scripted entry points pass null and retain
/// their ordinary client behavior; workers never receive a terminal writer.
const Frontend = struct {
    init: std.process.Init,
    terminal: *SessionTerminal,
    admission: *Admission,
    lane: FrontendRead = .{},
    store: []const u8 = "",
    session: []const u8 = "",
    accepting: bool = false,

    fn fatal(self: *const Frontend, err: anyerror) bool {
        // A service failure ends terminal custody before joining the reader.
        // Only worker request failures with an active terminal may recover.
        return !self.terminal.active or fatalPresentation(err);
    }

    fn cancel(self: *Frontend) void {
        self.lane.stop();
        self.admission.cancellation.requestStop();
        if (self.terminal.active) self.terminal.close() catch @panic("terminal restoration failed");
    }

    fn service(self: *Frontend) !void {
        // /wait also services input without an active reader wait scope.
        errdefer self.cancel();
        try self.terminal.service(10);
        if (!self.terminal.output) try self.terminal.repaint();
        if (self.accepting and !self.admission.held) {
            if (self.terminal.readyDraft()) |text| {
                if (text.len != 0) try self.submit(text);
            }
        }
    }

    fn submit(self: *Frontend, text: []const u8) !void {
        const message_text = if (std.mem.startsWith(u8, text, "//")) text[1..] else text;
        var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
        self.admission.captured = client.captureMessage(self.init.io, .{ .store = self.store, .session = self.session, .text_path = "", .text = message_text }, .{ .generated = try requestDirectory(self.init, &directory) }) catch |err| {
            self.terminal.ready = false;
            const restored = self.terminal.rejectSubmission();
            if (!self.terminal.output) try self.terminal.beginOutput();
            try self.terminal.writer().print("rui: capture failed ({s}); nothing sent. {s}\n", .{ @errorName(err), if (restored) "Original draft restored." else "Original draft retained; /discard releases it without sending." });
            return;
        };
        self.admission.held = true;
        self.admission.reply = null;
        self.admission.failure = null;
        self.terminal.captureReady();
        try self.admission.start();
    }

    fn wait(self: *Frontend, sink: anytype) !void {
        errdefer {
            // Do this before join, even when the producer is withholding the
            // first byte or waiting for this terminal's content rendezvous.
            self.cancel();
            self.lane.join();
        }
        while (!self.lane.done.load(.acquire)) {
            if (self.lane.borrow()) |bytes| {
                defer self.lane.release();
                if (@TypeOf(sink) != @TypeOf(null)) try sink.feed(bytes) else unreachable;
            }
            try self.service();
        }
        self.lane.join();
    }

    fn call(self: *Frontend, comptime function: anytype, args: anytype) anyerror!@typeInfo(@TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ args))).error_union.payload {
        var job: FrontendRead.Job(function, @TypeOf(args)) = .{ .args = args };
        try self.lane.start(&job);
        try self.wait(null);
        return job.result;
    }

    fn stream(self: *Frontend, comptime function: anytype, prefix: anytype, sink: anytype, reply: *client.ReplyBuffer) anyerror!@typeInfo(@TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ prefix ++ .{ &self.lane, reply }))).error_union.payload {
        const args = prefix ++ .{ &self.lane, reply };
        var job: FrontendRead.Job(function, @TypeOf(args)) = .{ .args = args };
        try self.lane.start(&job);
        try self.wait(sink);
        return job.result;
    }
};

fn readRequest(frontend: ?*Frontend, io: std.Io, comptime function: anytype, args: anytype) anyerror!@typeInfo(@TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ args))).error_union.payload {
    if (frontend) |owner| return owner.call(function, args);
    return @call(.auto, function, .{client.Requests{ .io = io }} ++ args);
}

fn streamRequest(frontend: ?*Frontend, io: std.Io, comptime function: anytype, prefix: anytype, sink: anytype, reply: *client.ReplyBuffer) anyerror!@typeInfo(@TypeOf(@call(.auto, function, .{@as(client.Requests, undefined)} ++ prefix ++ .{ sink, reply }))).error_union.payload {
    if (frontend) |owner| return owner.stream(function, prefix, sink, reply);
    return @call(.auto, function, .{client.Requests{ .io = io }} ++ prefix ++ .{ sink, reply });
}

const PreparedOpening = struct {
    report: SessionObservation,
    view: session_view.Page,
    display: std.Io.File,
    displayed_result_turn: u64,

    fn close(self: *const PreparedOpening, io: std.Io) void {
        self.report.file.close(io);
        self.display.close(io);
    }
};

fn prepareOpening(init: std.process.Init, store: []const u8, session: []const u8, replay: bool, frontend: ?*Frontend) !PreparedOpening {
    const report = try inspectWork(init, store, session, frontend);
    errdefer report.file.close(init.io);
    if (report.work.workspace.len == 0) return error.SessionNotConfigured;
    if (replay and report.work.history_end == null) return error.InvalidObservation;
    var reply: client.ReplyBuffer = .{};
    const view = try readRequest(frontend, init.io, client.sessionView, .{ store, session, session_view.Cursor{ .recent = true }, &reply });
    const display = try renderScratch(init);
    errdefer display.close(init.io);
    var displayed_result_turn: u64 = 0;
    var buffer: [4096]u8 = undefined;
    var writer = display.writerStreaming(init.io, &buffer);
    try renderSessionView(init.io, store, session, &view, true, &writer.interface, &displayed_result_turn, frontend);
    try writer.flush();
    if (replay) try testGate(init.io, "RUI_TEST_RESUME_GATE");
    return .{ .report = report, .view = view, .display = display, .displayed_result_turn = displayed_result_turn };
}

fn renderSessionStatus(init: std.process.Init, store: []const u8, session_ref: []const u8, report: *const SessionObservation, brief: bool, out: *std.Io.Writer) !void {
    const work = report.work;
    if (work.workspace.len == 0) return error.SessionNotConfigured;
    if (brief) {
        try writeField(out, "Session: ", session_ref);
        try writeField(out, "Workspace (Bash cwd): ", work.workspace.slice());
        try writeField(out, "Provider: ", work.provider.slice());
        try writeField(out, "Model: ", work.model.slice());
        try out.writeAll("Permission: ");
        var text: TerminalText = .{ .mode = .line };
        try text.feed(out, work.permission_mode.slice());
        try text.finish(out);
        try out.writeAll(if (work.bash and work.permission_mode.eql("bypass")) " (Bash runs without approval)\n" else "\n");
    } else {
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const aligned = std.c.ioctl(1, @intCast(std.c.T.IOCGWINSZ), &size) == 0 and size.col >= 60;
        try writeStatusField(out, "Session: ", session_ref, aligned);
        try writeStatusField(out, "Store: ", store, aligned);
        try writeStatusField(out, "Workspace (Bash cwd): ", work.workspace.slice(), aligned);
        try writeStatusField(out, "Provider: ", work.provider.slice(), aligned);
        try writeStatusField(out, "Model: ", work.model.slice(), aligned);
        try writeStatusField(out, "Permission: ", work.permission_mode.slice(), aligned);
        if (work.bash and work.permission_mode.eql("bypass")) try out.writeAll("Rui: Bash commands can run without asking you.\n");
        try writeStatusField(out, "Work: ", work.status.slice(), aligned);
        if (work.selected_message) |selected|
            try writeStatusField(out, "Current message: ", selected.slice(), aligned);
        if (work.action_count != 0) try showActionable(init.io, report.file, false, out);
    }
    if (work.indeterminate_action) |action| {
        try writeField(out, "Indeterminate Action: ", action.slice());
        if (work.indeterminate_count > 1) {
            try out.print("Rui: {d} indeterminate Actions in this Turn; inspect-session --profile current lists all IDs.\n", .{work.indeterminate_count});
        }
        try out.writeAll("Rui: The command may have run; Rui did not replay it. Check its effects before deciding what to do next.\n");
    }
    if (!brief and work.recent_count != 0) {
        try out.writeAll("Recent messages (use /result KEY for an answer):\n");
        for (work.recent[0..work.recent_count]) |recent| {
            try out.writeAll("  ");
            var text: TerminalText = .{ .mode = .line };
            try text.feed(out, recent.key.slice());
            try text.finish(out);
            try writeField(out, ": ", recent.outcome.slice());
        }
    }
}

fn writeSafeField(io: std.Io, label: []const u8, value: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writeField(&writer.interface, label, value);
    try writer.flush();
}

fn writeField(out: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try out.writeAll(label);
    var text: TerminalText = .{ .mode = .line };
    try text.feed(out, value);
    try text.finish(out);
    try out.writeAll("\n");
}

fn writeStatusField(out: *std.Io.Writer, label: []const u8, value: []const u8, aligned: bool) !void {
    try out.writeAll(label);
    if (aligned) {
        const spaces = [_]u8{' '} ** 22;
        try out.writeAll(spaces[0 .. 22 - label.len]);
    }
    try writeField(out, "", value);
}

fn writeSafeText(io: std.Io, value: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    var text: TerminalText = .{ .mode = .line };
    try text.feed(&writer.interface, value);
    try text.finish(&writer.interface);
    try writer.flush();
}

fn writeSafePreview(io: std.Io, value: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    var text: TerminalText = .{ .mode = .preview };
    try text.feed(&writer.interface, value);
    try text.finish(&writer.interface);
    try writer.flush();
}

// One final-storage exchange, no events or duplicate request registry. The
// worker only sends the immutable pinned capture; the terminal owns all output.
const Admission = struct {
    captured: client.CapturedRecord = undefined,
    buffer: client.ReplyBuffer = .{},
    reply: ?client.CommandReply = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    held: bool = false,
    cancellation: client.Cancellation = .{},

    fn start(self: *Admission) !void {
        std.debug.assert(self.thread == null);
        // This borrower may outlive the terminal's /login handoff. Inherit
        // blocked SIGINT from birth; only the terminal owns its delivery.
        var set = std.posix.sigemptyset();
        std.posix.sigaddset(&set, .INT);
        var previous: std.posix.sigset_t = undefined;
        if (std.c.pthread_sigmask(@intCast(std.posix.SIG.BLOCK), &set, &previous) != 0) return error.AdmissionSignalMaskFailed;
        defer if (std.c.pthread_sigmask(@intCast(std.posix.SIG.SETMASK), &previous, &set) != 0) @panic("terminal signal mask restoration failed");
        self.done.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, Admission.run, .{self});
    }

    fn run(self: *Admission) void {
        const exchange: client.Requests = .{ .io = std.Io.Threaded.global_single_threaded.io(), .cancellation = &self.cancellation };
        self.reply = exchange.sendCaptured(&self.captured, null, &self.buffer) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        if (self.reply) |reply| {
            client.checkCanonicalFailure(reply) catch |err| {
                self.reply = null;
                self.failure = err;
                self.done.store(true, .release);
                return;
            };
            if (reply.status != 200 and reply.status != 409) {
                self.reply = null;
                self.failure = error.HostInvocationFailed;
            }
        }
        self.done.store(true, .release);
    }

    fn recover(self: *Admission) !void {
        if (self.failure == null or self.thread != null) return;
        const failure = self.failure.?;
        self.failure = null;
        errdefer self.failure = failure;
        try self.start();
    }

    fn close(self: *Admission, io: std.Io) void {
        if (self.thread) |thread| {
            self.cancellation.requestStop();
            thread.join();
            self.thread = null;
        }
        // No borrower remains. A subsequent explicit recovery/admission gets
        // a fresh capability, never an implicitly retried exchange.
        self.cancellation = .{};
        if (self.held) self.captured.close(io);
        self.held = false;
    }
};

const SessionContentSink = struct {
    out: *std.Io.Writer,
    renderer: ?*AnswerRenderer = null,
    text: TerminalText = .{ .mode = .multiline },

    pub fn feed(self: *SessionContentSink, bytes: []const u8) !void {
        if (self.renderer) |renderer| try renderer.feed(bytes) else try self.text.feed(self.out, bytes);
    }

    fn finish(self: *SessionContentSink) !void {
        if (self.renderer) |renderer| try renderer.finish() else try self.text.finish(self.out);
    }
};

fn renderSessionView(io: std.Io, store: []const u8, session: []const u8, page: *const session_view.Page, historical: bool, out: *std.Io.Writer, displayed_result_turn: *u64, frontend: ?*Frontend) !void {
    var reply: client.ReplyBuffer = .{};
    for (page.items[0..page.count]) |item| {
        // Acceptance is pending footer state, not a second transcript bubble.
        if (item.kind == .admission) continue;
        // Presentation remembers only the most recent visible result's Turn,
        // across page boundaries. It neither selects nor tracks runtime work.
        if (item.kind == .outcome and std.mem.eql(u8, item.codeText(), "completed") and displayed_result_turn.* == item.turn) continue;
        try out.writeAll(switch (item.kind) {
            .user => "\nYou: ",
            .assistant => answer_divider,
            .call => if (item.code_len == 0) "\nProposed tool: " else "\nRejected proposal: ",
            .tool_result => "\nTool result:\n",
            .outcome => if (std.mem.eql(u8, item.codeText(), "completed")) "\nWork completed.\n" else if (std.mem.eql(u8, item.codeText(), "cancelled")) "\nWork cancelled.\n" else "\nWork failed: ",
            .stop => "\nSession stop accepted.\n",
            .admission => unreachable,
        });
        if (item.code_len != 0 and item.kind != .stop and
            !(item.kind == .outcome and (std.mem.eql(u8, item.codeText(), "completed") or std.mem.eql(u8, item.codeText(), "cancelled"))))
        {
            var text: TerminalText = .{ .mode = .multiline };
            try text.feed(out, item.codeText());
            try text.finish(out);
            try out.writeAll("\n");
        }
        if (item.kind == .call and item.code_len != 0) try out.writeAll("Proposed tool: ");
        // Conversation exports do not resolve proposal fields. Stream complete
        // names/arguments on replay too, rather than advertise an invalid read.
        if (historical and item.kind != .call and item.bytes > 8192) {
            try writeContentOmission(out, store, session, item.position, item.ordinal, item.bytes);
            try out.flush();
            continue;
        }
        var renderer: AnswerRenderer = .{ .out = out };
        var sink: SessionContentSink = .{ .out = out, .renderer = if (item.kind == .assistant) &renderer else null };
        switch (item.kind) {
            .user => _ = try streamRequest(frontend, io, client.messageContentStream, .{ store, session, item.message }, &sink, &reply),
            .assistant, .tool_result => {
                _ = try streamRequest(frontend, io, client.conversationContentStream, .{ store, session, item.position, item.ordinal }, &sink, &reply);
            },
            .call => {
                for ([_]protocol.SessionCallContent.Field{ .name, .arguments }) |field| {
                    _ = try streamRequest(frontend, io, client.sessionCallContentStream, .{ store, session, item.position, field }, &sink, &reply);
                    try sink.finish();
                    sink.text = .{ .mode = .multiline };
                    try out.writeAll("\n");
                }
            },
            .outcome, .stop => {},
            .admission => unreachable,
        }
        try sink.finish();
        try out.writeAll("\n");
        try out.flush();
        if ((item.kind == .assistant or item.kind == .tool_result) and item.bytes != 0) displayed_result_turn.* = item.turn;
    }
}

fn writeContentOmission(out: *std.Io.Writer, store: []const u8, session: []const u8, position: u64, ordinal: u64, bytes: u64) !void {
    try out.print("[content omitted: {d} bytes; save exact content with]\nrui conversation-content --store ", .{bytes});
    try writeShellArgument(out, store);
    try out.writeAll(" --session ");
    try writeShellArgument(out, session);
    try out.print(" --position {d} --ordinal {d} --output NEW_FILE\n", .{ position, ordinal });
}

// Bash ANSI-C quoting makes this exceptional export command both terminal-safe
// and exact, including quotes, controls and non-ASCII selector bytes.
fn writeShellArgument(out: *std.Io.Writer, value: []const u8) !void {
    try out.writeAll("$'");
    for (value) |byte| {
        if (byte < 32 or byte >= 127 or byte == '\'' or byte == '\\') {
            try out.print("\\x{x:0>2}", .{byte});
        } else try out.writeByte(byte);
    }
    try out.writeByte('\'');
}

test "Session presentation completion depends on this Turn's displayed result, not later success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "display", .{ .read = true });
    defer file.close(io);
    var page: session_view.Page = .{ .end = 20, .count = 4 };
    const codes = [_][]const u8{ "completed", "completed", "provider_http_422", "session_stopped" };
    for (codes, 0..) |code, i| {
        page.items[i] = .{ .position = 10 + i, .kind = if (i == 3) .stop else .outcome, .turn = if (i == 1) 8 else 7, .code_len = code.len };
        @memcpy(page.items[i].code[0..code.len], code);
    }
    // A prior page already showed Turn 7's result. Suppress only its normal
    // completion: Turn 8's unseen completion and Turn 7's failure remain.
    var displayed_result_turn: u64 = 7;
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try renderSessionView(io, "/unused", "unused", &page, false, &writer.interface, &displayed_result_turn, null);
    try writer.flush();
    var bytes: [256]u8 = undefined;
    const count = try file.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("\nWork completed.\n\n\nWork failed: provider_http_422\n\n\nSession stop accepted.\n\n", bytes[0..count]);
    try std.testing.expectEqual(@as(u64, 7), displayed_result_turn);
}

fn enterSessionWithHistory(init: std.process.Init, args: []const []const u8, replay: bool) !void {
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) return error.InteractiveTerminalRequired;
    var draft_buffers: [2][65536]u8 = undefined;
    var terminal = try SessionTerminal.init(init.io, &draft_buffers);
    var admission: Admission = .{};
    var frontend: Frontend = .{ .init = init, .terminal = &terminal, .admission = &admission };
    defer {
        admission.cancellation.requestStop();
        frontend.lane.stop();
        // Terminal custody ends before joining any transport borrower. Stop
        // only detaches this caller; the immutable durable capture survives.
        if (terminal.active) terminal.close() catch @panic("terminal restoration failed");
        frontend.lane.join();
        admission.close(init.io);
    }
    var next: ?SwitchSession = null;
    var first = true;
    while (true) {
        const switched = (if (first)
            enterSessionOnce(init, args, replay, null, &terminal, &admission, &frontend)
        else
            enterSessionOnce(init, &.{ "--store", next.?.store.slice(), "--session", next.?.session.slice() }, true, next.?.opening, &terminal, &admission, &frontend)) catch |err| {
            if (err == error.InteractiveInterrupted or (terminal.failure != null and terminal.failure.? == error.InteractiveInterrupted)) return;
            return err;
        };
        if (switched == null) return;
        next = switched;
        first = false;
    }
}

const SwitchSession = struct {
    store: protocol.Bounded(protocol.max_store_bytes),
    session: protocol.Bounded(protocol.max_session_bytes),
    opening: PreparedOpening,
};

fn enterSessionOnce(init: std.process.Init, args: []const []const u8, replay: bool, prepared: ?PreparedOpening, terminal: *SessionTerminal, admission: *Admission, frontend: *Frontend) !?SwitchSession {
    // Transferred opening custody also survives argument/path validation errors.
    var pending_opening = prepared;
    defer if (pending_opening) |opening| opening.close(init.io);
    var store: ?[]const u8 = null;
    var session_ref: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session")) session_ref = try takeValue(args, &index) else return error.UnknownArgument;
    }
    const reference = session_ref orelse return usage();
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) {
        std.debug.print("rui --resume needs terminal input and output; use one-shot commands for scripts\n", .{});
        return error.InteractiveTerminalRequired;
    }
    var fallback_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const chosen = try selectedStore(init, store, &fallback_buffer);
    // Resolve aliases and enforce the Store's existing private/canonical selector
    // before any Session request. Explicit --store does not read preferences.
    const paths = platform.resolveClientPaths(init.io, chosen) catch |err| {
        std.debug.print("rui: selected Store unavailable ({s}); check --store or rui setup; no alternate Store selected.\n", .{@errorName(err)});
        return err;
    };
    const destination = paths.store.slice();
    frontend.store = destination;
    frontend.session = reference;
    frontend.accepting = false;
    defer frontend.accepting = false;
    const out = terminal.writer();
    var older: ?client.ConversationCursor = null;
    var cursor: session_view.Cursor = .{};
    var current: session_view.Page = undefined;
    var displayed_result_turn: u64 = 0;
    {
        const opening = prepared orelse (prepareOpening(init, destination, reference, replay, frontend) catch |err| {
            if (err == error.SessionNotConfigured) std.debug.print("rui: configure this Session before entering it\n", .{});
            return err;
        });
        pending_opening = null;
        defer opening.close(init.io);
        current = opening.view;
        // No target opening output occurs until its complete first page is staged.
        try renderSessionStatus(init, destination, reference, &opening.report, true, out);
        if (replay) {
            var credential_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const credential = credentialPath(init, &credential_buffer, false) catch null;
            const now: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds, std.time.ns_per_s));
            const local = if (credential) |path| codex_auth.localStatus(path, now) catch null else null;
            if (local == null or !local.?.usable()) {
                try out.writeAll("Rui: Local Codex credential is unavailable or needs repair. Saved history remains inspectable; /login is optional and does not rebind this Session.\n");
            }
        }
        _ = try (PreparedConversationPage{ .file = opening.display, .next = null }).display(init, out);
        displayed_result_turn = opening.displayed_result_turn;
        cursor = current.continuation(.{});
        if (current.end != 0) {
            older = .{ .end = current.end };
            for (current.items[0..current.count]) |item| {
                if (item.kind == .user or item.kind == .assistant or item.kind == .tool_result) {
                    older = .{ .end = current.end, .before_position = item.position, .before_ordinal = item.ordinal };
                    break;
                }
            }
        }
    }
    try out.writeAll("/help for commands; /exit detaches without stopping work.\n");
    frontend.accepting = true;
    while (true) {
        if (admission.thread != null and admission.done.load(.acquire)) {
            if (!terminal.output) try terminal.beginOutput();
            if (admission.reply) |reply| {
                if (try acceptedReply(reply)) {
                    terminal.releaseSubmitted();
                    admission.close(init.io);
                } else {
                    try writeAdmissionTo(out, reply, null);
                    admission.thread.?.join();
                    admission.thread = null;
                    if (terminal.rejectSubmission()) admission.close(init.io) else try out.writeAll("Rui: Rejected draft retained alongside new composition. /discard releases the rejected draft; its capture remains saved.\n");
                }
            } else {
                if (admission.failure) |err| {
                    if (err == error.CanonicalStoreFailure) return err;
                }
                var label: [160]u8 = undefined;
                try writeField(out, try std.fmt.bufPrint(&label, "Submission unconfirmed ({s}); recover original request: ", .{@errorName(admission.failure.?)}), admission.captured.saved.key.slice());
                // Leave the pinned immutable capture available for /recover.
                admission.thread.?.join();
                admission.thread = null;
            }
        }
        var reply_buffer: client.ReplyBuffer = .{};
        const next_page = try readRequest(frontend, init.io, client.sessionView, .{ destination, reference, cursor, &reply_buffer });
        if (next_page.count != 0 or next_page.pending_total != current.pending_total or next_page.action != current.action or !std.meta.eql(next_page.work, current.work)) {
            if (!terminal.output) try terminal.beginOutput();
            try renderSessionView(init.io, destination, reference, &next_page, false, out, &displayed_result_turn, frontend);
        }
        current = next_page;
        cursor = current.continuation(cursor);
        var status: protocol.FixedJsonBuffer(256) = .{};
        if (admission.thread != null) {
            try status.append("Sending...");
        } else if (admission.held) {
            try status.append(if (admission.reply != null) "/discard: rejected original" else "Ctrl-R: submission unconfirmed");
        } else {
            // Put actionable keys first: even a narrow clipped footer must
            // retain the route to exact inspection/recovery, not an ID.
            if (current.action != 0) try status.append("Ctrl-G: inspect approval");
            if (current.work.status == .runnable or current.work.status == .in_flight) {
                if (status.len != 0) try status.append(" | ");
                try status.append("Working...");
            }
            if (current.pending_total != 0) {
                if (status.len != 0) try status.append(" | ");
                try status.appendFmt("{d} message{s} queued", .{ current.pending_total, if (current.pending_total == 1) "" else "s" });
            }
        }
        if (terminal.output) try terminal.endOutput(status.slice());
        const event = try terminal.poll(if (current.more) 0 else 100);
        if (event == .none) continue;
        const ready_event = event == .submit and terminal.ready;
        defer if (ready_event) terminal.finishReady();
        defer if (event == .command) terminal.finishCommand();
        const was_accepting = frontend.accepting;
        frontend.accepting = false;
        defer frontend.accepting = was_accepting;
        try terminal.beginOutput();
        const text = switch (event) {
            .none => continue,
            .recover => {
                try admission.recover();
                continue;
            },
            .approve => {
                const detach = approveSessionAction(init, destination, reference, current.action, terminal, frontend) catch |err| blk: {
                    if (frontend.fatal(err) or err == error.RenderScratchCleanupFailed) return err;
                    try out.print("rui: Action unavailable or decision uncertain ({s}); check /requests before retrying\n", .{@errorName(err)});
                    break :blk false;
                };
                if (detach) break;
                continue;
            },
            .eof, .interrupt => break,
            .busy => {
                try out.writeAll("Rui: Original admission is unresolved. /recover retransmits its immutable capture; no new message sent.\n");
                continue;
            },
            .invalid, .overflow => {
                terminal.clearDraft();
                try out.writeAll("Rui: Input rejected; nothing sent.\n");
                continue;
            },
            .submit, .command => |bytes| bytes,
        };
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "/exit")) break;
        if (std.mem.eql(u8, text, "/approve")) {
            const detach = approveSessionAction(init, destination, reference, current.action, terminal, frontend) catch |err| blk: {
                if (frontend.fatal(err) or err == error.RenderScratchCleanupFailed) return err;
                try out.print("rui: Action unavailable or decision uncertain ({s}); check /requests before retrying\n", .{@errorName(err)});
                break :blk false;
            };
            if (detach) break;
            continue;
        }
        if (std.mem.eql(u8, text, "/recover")) {
            try admission.recover();
            continue;
        }
        if (std.mem.eql(u8, text, "/discard")) {
            if (admission.held and admission.reply != null and admission.thread == null) {
                terminal.releaseSubmitted();
                admission.close(init.io);
            } else if (!admission.held and terminal.submitted != null and !terminal.ready) {
                terminal.releaseSubmitted();
            }
            continue;
        }
        if (std.mem.eql(u8, text, "/help")) {
            try out.writeAll("Rui: Ctrl-G inspects the current Action and Ctrl-R recovers the unresolved immutable capture, both preserving composition. /approve and /recover also work from an empty command line; /discard releases a definitely rejected draft, never an uncertain admission.\n");
            try out.writeAll("Rui: /help  /status  /history  /resume [REF]  /wait  /requests  /result KEY  /setup [--store PATH] [--provider codex] [--model MODEL | --clear-model]  /login  /configure [settings]  /exit\n/help shows these commands; /status inspects this Session; /history reads an older public page; /resume switches to a saved Session without submitting; /wait follows selected work; /requests lists local recovery handles; /result KEY reads a saved answer. /setup reads local credential/Host status and saves defaults for future Sessions only; --clear-model restores recommendation inheritance; /login chooses Codex login or defers; /configure changes this Session; /exit detaches without stopping work.\nMessages are submitted as written. To send a leading /, prefix it with //; use the one-shot --text FILE for longer input.\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/history")) {
            if (older) |history_cursor| {
                older = showConversationPage(init, destination, reference, history_cursor, frontend) catch |err| blk: {
                    if (err == error.HistoryDisplayFailed or frontend.fatal(err)) return err;
                    try out.print("rui: history unavailable ({s}); use /status or retry the same page\n", .{@errorName(err)});
                    break :blk history_cursor;
                };
                if (older == null) try out.writeAll("Rui: End of saved public history.\n");
            } else try out.writeAll("Rui: No older page in this traversal. Re-enter to inspect a fresh recent page.\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/resume") or std.mem.startsWith(u8, text, "/resume ")) {
            const target = if (text.len == "/resume".len) "" else text["/resume ".len..];
            const next = blk: {
                try terminal.@"suspend"();
                defer terminal.@"resume"() catch @panic("terminal resume failed");
                break :blk (chooseResumeSession(init, destination, if (target.len == 0) null else target) catch |err| {
                    if (fatalPresentation(err) or err == error.RenderScratchCleanupFailed or err == error.SessionSelectionDisplayFailed or err == error.SessionSelectionTerminalFailed) return err;
                    std.debug.print("rui: resume unavailable ({s}); active Session unchanged\n", .{@errorName(err)});
                    continue;
                }) orelse continue;
            };
            var selected_store: protocol.Bounded(protocol.max_store_bytes) = .{};
            try selected_store.set(destination);
            const next_opening = prepareOpening(init, destination, next.slice(), true, frontend) catch |err| {
                if (frontend.fatal(err) or err == error.RenderScratchCleanupFailed) return err;
                std.debug.print("rui: resume unavailable ({s}); active Session unchanged\n", .{@errorName(err)});
                continue;
            };
            return .{ .store = selected_store, .session = next, .opening = next_opening };
        }
        if (std.mem.eql(u8, text, "/login")) {
            try terminal.@"suspend"();
            defer terminal.@"resume"() catch @panic("terminal resume failed");
            guideProviderLogin(init) catch |err| {
                if (err != error.InteractiveInterrupted) return err;
                try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Login deferred. Inspect saved work with /status or /result.\n");
            };
            continue;
        }
        const attention: ?Work = if (std.mem.eql(u8, text, "/setup") or std.mem.startsWith(u8, text, "/setup ")) blk: {
            try terminal.@"suspend"();
            defer terminal.@"resume"() catch @panic("terminal resume failed");
            var setup_args: [7][]const u8 = undefined;
            const count = interactiveTokens(text["/setup".len..], &setup_args) catch {
                try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: /setup [--store PATH] [--provider codex] [--model MODEL | --clear-model]; no changes saved.\n");
                break :blk null;
            };
            setup(init, setup_args[0..count]) catch |err| {
                if (fatalPresentation(err)) return err;
                std.debug.print("rui: /setup: {s}; active Session unchanged\n", .{@errorName(err)});
            };
            break :blk null;
        } else if (std.mem.eql(u8, text, "/status")) blk: {
            showSessionStatus(init, destination, reference, false, frontend) catch |err| {
                if (frontend.fatal(err)) return err;
                try out.print("rui: status: {s}\n", .{@errorName(err)});
            };
            break :blk null;
        } else if (std.mem.eql(u8, text, "/requests")) blk: {
            sessionRequests(init, destination, reference, out) catch |err| {
                if (fatalPresentation(err)) return err;
                try out.print("rui: requests: {s}\n", .{@errorName(err)});
            };
            break :blk null;
        } else if (std.mem.eql(u8, text, "/wait"))
            waitEnteredSession(frontend) catch |err| blk: {
                if (frontend.fatal(err)) return err;
                try out.print("rui: wait: {s}\n", .{@errorName(err)});
                break :blk null;
            }
        else if (std.mem.startsWith(u8, text, "/result ")) blk: {
            const saved = client.MessageAddress.init(destination, reference, std.mem.trim(u8, text[8..], " ")) catch |err| {
                try out.print("rui: result key: {s}\n", .{@errorName(err)});
                break :blk null;
            };
            showResult(init, &saved, .interactive, frontend) catch |err| {
                if (frontend.fatal(err)) return err;
                try out.print("rui: result: {s}\n", .{@errorName(err)});
            };
            break :blk null;
        } else if (std.mem.eql(u8, text, "/configure") or std.mem.startsWith(u8, text, "/configure ")) blk: {
            var config_args: [24][]const u8 = undefined;
            config_args[0..4].* = .{ "--store", destination, "--session", reference };
            var count: usize = 4;
            var arguments: [20][]const u8 = undefined;
            const argument_count = interactiveTokens(text["/configure".len..], &arguments) catch {
                try out.writeAll("Rui: Usage: /configure --model MODEL [--tools bash] [--permission-mode ask|bypass] (settings for this Session only)\n");
                break :blk null;
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
                        try out.writeAll("Rui: Use a file for /configure content; terminal stdin belongs to this Session.\n");
                        break :blk null;
                    }
                    config_args[count] = setting;
                    count += 1;
                }
            }
            if (valid and count > 4) {
                configureEntered(init, config_args[0..count], true, frontend) catch |err| {
                    if (frontend.fatal(err)) return err;
                    try out.print("rui: configure: {s}; check /requests before retrying\n", .{@errorName(err)});
                };
            } else try out.writeAll("Rui: Usage: /configure --model MODEL [--tools bash] [--permission-mode ask|bypass] (settings for this Session only)\n");
            break :blk null;
        } else if (std.mem.startsWith(u8, text, "/") and !std.mem.startsWith(u8, text, "//")) blk: {
            try out.writeAll("Rui: Unknown command. Type /help.\n");
            break :blk null;
        } else blk: {
            if (admission.held) {
                try out.writeAll("Rui: Original admission is unresolved. /recover retransmits its immutable capture; no new message sent.\n");
                break :blk null;
            }
            frontend.submit(text) catch |err| {
                if (frontend.fatal(err)) return err;
                try out.print("rui: capture failed ({s}); nothing sent\n", .{@errorName(err)});
                break :blk null;
            };
            break :blk null;
        };
        // An explicit wait explains its return; it never opens approval.
        if (attention != null) try out.writeAll("Rui: Approval is needed. Ctrl-G to inspect.\n");
    }
    if (terminal.active) terminal.writeAvailable(SessionTerminal.detach_notice);
    return null;
}

/// True detaches without constructing a Permission Decision capture.
fn approveSessionAction(init: std.process.Init, store: []const u8, session_ref: []const u8, id: u64, terminal: *SessionTerminal, frontend: *Frontend) !bool {
    const out = terminal.writer();
    terminal.beginApproval();
    defer terminal.finishApproval();
    if (id == 0) {
        try out.writeAll("Rui: No Action requires attention.\n");
        return false;
    }
    var id_buffer: [20]u8 = undefined;
    const action = try std.fmt.bufPrint(&id_buffer, "{d}", .{id});
    inspectEnteredAction(init, &.{ "--store", store, "--session", session_ref, "--action", action }, true, frontend) catch |err| {
        if (err == error.TerminalTooNarrow and !frontend.fatal(err)) {
            try out.writeAll("Rui: Widen the terminal to inspect this permission request; no decision sent. Use /wait after resizing.\n");
            return false;
        }
        return err;
    };
    const choice = (terminal.readChoice(action_choice_prompt) catch |err| {
        if (err == error.InteractiveInterrupted) return true;
        if (err == error.InvalidTerminalInput) {
            try out.writeAll("Rui: No decision sent.\n");
            return false;
        }
        return err;
    }) orelse return true;
    if (std.mem.eql(u8, choice, "l")) {
        try out.writeAll("Rui: No decision sent; use /wait to revisit.\n");
        return false;
    }
    if (!std.mem.eql(u8, choice, "a") and !std.mem.eql(u8, choice, "d")) {
        try out.writeAll("Rui: Choose a, d, or l. No decision sent.\n");
        return false;
    }
    const decision: protocol.PermissionDecision = if (choice[0] == 'a') .allow_once else .deny;
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var reply_buffer: client.ReplyBuffer = .{};
    var captured = try client.capturePermissionDecision(init.io, .{
        .store = store,
        .session = session_ref,
        .action_id = id,
        .decision = decision,
    }, .{ .generated = try requestDirectory(init, &directory_buffer) });
    const reply = blk: {
        defer captured.close(init.io);
        break :blk try readRequest(frontend, init.io, client.sendCaptured, .{ &captured, @as(?[]const u8, null), &reply_buffer });
    };
    try client.checkCanonicalFailure(reply);
    const accepted = try acceptedReply(reply);
    if (!accepted) try writeAdmissionTo(terminal.writer(), reply, null);
    return false;
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

fn sessionRequests(init: std.process.Init, store: []const u8, session_ref: []const u8, out: *std.Io.Writer) !void {
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
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const handle = entry.name[0 .. entry.name.len - ".json".len];
        const saved = savedRequest(init, handle) catch continue;
        if (!saved.store.eql(canonical.store.slice()) or !saved.session.eql(session_ref)) continue;
        try out.print("  {s} ({s})\n", .{ handle, saved.kind.slice() });
    }
}

fn stopSession(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var input = client.SessionStopInput{ .store = "", .record = "", .key = "", .session = "" };
    var explicit_store: ?[]const u8 = null;
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.record.len == 0 or input.session.len == 0 or !key_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.stopSession(io, input, &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn interruptModel(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var input = client.ModelInterruptionInput{
        .store = "",
        .record = "",
        .key = "",
        .session = "",
        .turn_id = 0,
        .operation_id = 0,
    };
    var explicit_store: ?[]const u8 = null;
    var key_seen = false;
    var turn_seen = false;
    var operation_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--turn")) {
            input.turn_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            turn_seen = true;
        } else if (std.mem.eql(u8, arg, "--operation")) {
            input.operation_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            operation_seen = true;
        } else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.record.len == 0 or input.session.len == 0 or
        !key_seen or !turn_seen or !operation_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.interruptModel(io, input, &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn decideAction(init: std.process.Init, args: []const []const u8, decision: @FieldType(client.PermissionDecisionInput, "decision")) !void {
    const io = init.io;
    var json = false;
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
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) location.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            location.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--action")) {
            input.action_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            action_seen = true;
        } else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
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
        if (human) {
            if (json) try announceCaptureJson(io, saved.key.slice()) else try announceCapture(io, saved.key.slice());
        }
        break :blk try client.sendCaptured(io, &captured, drop_reply, &reply_buffer);
    };
    if (human) try writeAdmission(io, reply, if (json) saved.key.slice() else null) else try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
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
    try writeCommandReply(io, reply);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn observe(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var store_path: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) key = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const target = key orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const reply = try client.observeCommand(io, try selectedStore(init, store_path, &selected_buffer), target, &reply_buffer);
    try writeCommandReply(io, reply);
    if (reply.status != 200) return error.HostInvocationFailed;
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
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.inspectSession(
        io,
        try selectedStore(init, store_path, &selected_buffer),
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

fn readResult(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var store_path: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) store_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) key = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    const target = key orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.readResult(
        io,
        try selectedStore(init, store_path, &selected_buffer),
        target,
        std.Io.File.stdout(),
        &reply_buffer,
    );
    switch (reply) {
        .answer => {},
        .command => |command_reply| {
            try writeCommandReply(io, command_reply);
            return error.HostInvocationFailed;
        },
    }
}

fn readActionArguments(init: std.process.Init, args: []const []const u8) !void {
    return readActionContent(init, args, .arguments);
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
}

fn requestDirectory(init: std.process.Init, buffer: []u8) ![]const u8 {
    const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHome;
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/requests", .{home});
}

fn announceCapture(io: std.Io, handle: []const u8) !void {
    try testGate(io, "RUI_TEST_CAPTURE_GATE");
    try std.Io.File.stdout().writeStreamingAll(io, "request: ");
    try std.Io.File.stdout().writeStreamingAll(io, handle);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn announceCaptureJson(io: std.Io, handle: []const u8) !void {
    try testGate(io, "RUI_TEST_CAPTURE_GATE");
    var line: [96]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"event\":\"captured\",\"request\":\"{s}\"}}\n", .{handle}));
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

fn writeAdmission(io: std.Io, reply: client.CommandReply, json_handle: ?[]const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try writeAdmissionTo(&writer.interface, reply, json_handle);
    try writer.flush();
}

fn writeAdmissionTo(out: *std.Io.Writer, reply: client.CommandReply, json_handle: ?[]const u8) !void {
    if (json_handle) |handle| {
        try out.print("{{\"event\":\"admission\",\"request\":\"{s}\",\"admission\":", .{handle});
        try out.writeAll(reply.body);
        return out.writeAll("}\n");
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    const answer = try objectField(parsed.value, "answer");
    const status = try stringField(answer, "status");
    try out.print("admitted: {s}\n", .{status});
    const replayed = try objectField(answer, "replayed");
    if (replayed != .bool) return error.InvalidObservation;
    try out.writeAll(if (replayed.bool) "replayed: true\n" else "replayed: false\n");
    if (answer.object.get("code")) |code| {
        if (code != .string) return error.InvalidObservation;
        try writeField(out, "code: ", code.string);
    }
}

fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidObservation;
    return value.object.get(name) orelse error.InvalidObservation;
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    const field = try objectField(value, name);
    if (field != .string) return error.InvalidObservation;
    return field.string;
}

const SavedRequest = client.CapturedIdentity;

fn savedRequest(init: std.process.Init, handle: []const u8) !SavedRequest {
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var captured = try client.openCaptured(init.io, try requestDirectory(init, &directory_buffer), handle);
    defer captured.close(init.io);
    return captured.identity().*;
}

const SessionPage = struct {
    references: [protocol.session_list_page_size]protocol.Bounded(protocol.max_session_bytes) = [_]protocol.Bounded(protocol.max_session_bytes){.{}} ** protocol.session_list_page_size,
    count: usize = 0,
    next: ?client.SessionListCursor = null,
};

fn parseSessionPage(init: std.process.Init, file: std.Io.File, show: bool) !SessionPage {
    var input_buffer: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var reader = std.json.Reader.init(std.heap.c_allocator, &file_reader.interface);
    defer reader.deinit();
    if ((try reader.next()) != .object_begin) return error.InvalidSessionPage;
    var page: SessionPage = .{};
    var valid_type = false;
    var found_sessions = false;
    while (true) {
        const field = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
        defer freeToken(field);
        if (field == .object_end) break;
        const name = try tokenString(field);
        if (std.mem.eql(u8, name, "type")) {
            const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 32);
            defer freeToken(value);
            valid_type = std.mem.eql(u8, try tokenString(value), "session_list");
        } else if (std.mem.eql(u8, name, "sessions")) {
            if ((try reader.next()) != .array_begin) return error.InvalidSessionPage;
            found_sessions = true;
            while (true) {
                const item = try reader.next();
                if (item == .array_end) break;
                if (item != .object_begin or page.count == page.references.len) return error.InvalidSessionPage;
                var reference: protocol.Bounded(protocol.max_session_bytes) = .{};
                var workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{};
                var provider_name: protocol.Bounded(32) = .{};
                var model: protocol.Bounded(protocol.max_model_bytes) = .{};
                var permission: protocol.Bounded(16) = .{};
                var bash = false;
                var edit = false;
                while (true) {
                    const item_field = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                    defer freeToken(item_field);
                    if (item_field == .object_end) break;
                    const item_name = try tokenString(item_field);
                    if (std.mem.eql(u8, item_name, "reference") or std.mem.eql(u8, item_name, "workspace") or
                        std.mem.eql(u8, item_name, "provider") or std.mem.eql(u8, item_name, "model") or
                        std.mem.eql(u8, item_name, "permission_mode"))
                    {
                        const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, protocol.max_workspace_bytes);
                        defer freeToken(value);
                        const text = try tokenString(value);
                        if (std.mem.eql(u8, item_name, "reference")) try reference.set(text) else if (std.mem.eql(u8, item_name, "workspace")) try workspace.set(text) else if (std.mem.eql(u8, item_name, "provider")) try provider_name.set(text) else if (std.mem.eql(u8, item_name, "model")) try model.set(text) else try permission.set(text);
                    } else if (std.mem.eql(u8, item_name, "tools")) {
                        if ((try reader.next()) != .array_begin) return error.InvalidSessionPage;
                        while (true) {
                            const tool = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 16);
                            defer freeToken(tool);
                            if (tool == .array_end) break;
                            const name_text = try tokenString(tool);
                            if (std.mem.eql(u8, name_text, "bash")) bash = true else if (std.mem.eql(u8, name_text, "edit")) edit = true else return error.InvalidSessionPage;
                        }
                    } else try reader.skipValue();
                }
                if (reference.len == 0 or workspace.len == 0 or provider_name.len == 0 or model.len == 0 or permission.len == 0) return error.InvalidSessionPage;
                page.references[page.count] = reference;
                page.count += 1;
                if (show) {
                    try writeSafeField(init.io, "Session: ", reference.slice());
                    try writeSafeField(init.io, "  Workspace: ", workspace.slice());
                    try writeSafeField(init.io, "  Provider: ", provider_name.slice());
                    try writeSafeField(init.io, "  Model: ", model.slice());
                    try std.Io.File.stdout().writeStreamingAll(init.io, if (bash and edit) "  Tools: Bash, Edit\n" else if (bash) "  Tools: Bash\n" else if (edit) "  Tools: Edit\n" else "  Tools: none\n");
                    try writeSafeField(init.io, "  Permission: ", permission.slice());
                    if (bash and permission.eql("bypass")) try std.Io.File.stdout().writeStreamingAll(init.io, "  Rui: Bash runs without approval.\n");
                }
            }
        } else if (std.mem.eql(u8, name, "next")) {
            const next = try reader.next();
            if (next == .null) continue;
            if (next != .object_begin) return error.InvalidSessionPage;
            var cursor: client.SessionListCursor = .{};
            while (true) {
                const cursor_field = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                defer freeToken(cursor_field);
                if (cursor_field == .object_end) break;
                const cursor_name = try tokenString(cursor_field);
                if (std.mem.eql(u8, cursor_name, "after") or std.mem.eql(u8, cursor_name, "ceiling")) {
                    const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 20);
                    defer freeToken(value);
                    const number = try std.fmt.parseInt(u64, try tokenString(value), 10);
                    if (std.mem.eql(u8, cursor_name, "after")) cursor.after = number else cursor.ceiling = number;
                } else try reader.skipValue();
            }
            if (cursor.after == 0 or cursor.ceiling < cursor.after) return error.InvalidSessionPage;
            page.next = cursor;
        } else try reader.skipValue();
    }
    if (!valid_type or !found_sessions or (try reader.next()) != .end_of_document or
        (page.next != null and page.count == 0)) return error.InvalidSessionPage;
    return page;
}

fn sessionPage(init: std.process.Init, store: []const u8, workspace: ?[]const u8, cursor: client.SessionListCursor, presentation: Presentation) !SessionPage {
    const file = try renderScratch(init);
    defer file.close(init.io);
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.listSessions(init.io, store, workspace, cursor, file, &buffer);
    if (reply == .command) try client.checkCanonicalFailure(reply.command);
    if (reply != .report) return error.SessionListUnavailable;
    const page = try parseSessionPage(init, file, false);
    if (presentation == .json) {
        var bytes: [protocol.content_window_bytes]u8 = undefined;
        var offset: u64 = 0;
        while (offset < reply.report.bytes) {
            const count = try file.readPositionalAll(init.io, bytes[0..@intCast(@min(reply.report.bytes - offset, bytes.len))], offset);
            if (count == 0) return error.TruncatedSessionPage;
            try std.Io.File.stdout().writeStreamingAll(init.io, bytes[0..count]);
            offset += count;
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    } else if (presentation == .human) {
        _ = try parseSessionPage(init, file, true);
    }
    return page;
}

const HistoryItem = struct {
    position: []const u8,
    ordinal: []const u8,
    kind: []const u8,
    content: struct { bytes: []const u8, sha256: []const u8, display: []const u8 },
};

const HistoryPage = struct {
    version: []const u8,
    type: []const u8,
    direction: []const u8,
    end: []const u8,
    items: []const HistoryItem,
    more: bool,
    before_position: ?[]const u8 = null,
    before_ordinal: ?[]const u8 = null,
};

fn showConversationPage(init: std.process.Init, store: []const u8, session: []const u8, cursor: client.ConversationCursor, frontend: *Frontend) !?client.ConversationCursor {
    const prepared = try prepareConversationPage(init, store, session, cursor, frontend);
    defer prepared.file.close(init.io);
    return prepared.display(init, frontend.terminal.writer());
}

const PreparedConversationPage = struct {
    file: std.Io.File,
    next: ?client.ConversationCursor,

    fn display(self: PreparedConversationPage, init: std.process.Init, out: *std.Io.Writer) !?client.ConversationCursor {
        const display_length = self.file.length(init.io) catch return error.HistoryDisplayFailed;
        var output: [protocol.content_window_bytes]u8 = undefined;
        var offset: u64 = 0;
        while (offset < display_length) {
            const count = self.file.readPositionalAll(init.io, output[0..@intCast(@min(display_length - offset, output.len))], offset) catch return error.HistoryDisplayFailed;
            if (count == 0) return error.HistoryDisplayFailed;
            out.writeAll(output[0..count]) catch return error.HistoryDisplayFailed;
            offset += count;
        }
        return self.next;
    }
};

fn prepareConversationPage(init: std.process.Init, store: []const u8, session: []const u8, cursor: client.ConversationCursor, frontend: *Frontend) !PreparedConversationPage {
    const page_file = try renderScratch(init);
    defer page_file.close(init.io);
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try readRequest(frontend, init.io, client.conversationPage, .{ store, session, cursor, page_file, &reply_buffer });
    if (reply == .command) try client.checkCanonicalFailure(reply.command);
    if (reply != .report or reply.report.bytes > protocol.max_conversation_page_response_bytes) return error.ConversationUnavailable;
    var page_bytes: [protocol.max_conversation_page_response_bytes]u8 = undefined;
    const length: usize = @intCast(reply.report.bytes);
    if (try page_file.readPositionalAll(init.io, page_bytes[0..length], 0) != length) return error.TruncatedConversationPage;
    var arena_bytes: [32 * 1024]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&arena_bytes);
    const page = (try std.json.parseFromSliceLeaky(HistoryPage, arena.allocator(), page_bytes[0..length], .{ .ignore_unknown_fields = false }));
    if (!std.mem.eql(u8, page.version, "1") or !std.mem.eql(u8, page.type, "conversation_page") or
        !std.mem.eql(u8, page.direction, "newest_first") or page.items.len > protocol.public_conversation_page_items) return error.InvalidConversationPage;
    const end = try std.fmt.parseInt(u64, page.end, 10);
    if (cursor.end != 0 and end != cursor.end) return error.InvalidConversationPage;
    const next: ?client.ConversationCursor = if (!page.more) null else blk: {
        if (page.items.len == 0) return error.InvalidConversationPage;
        break :blk .{
            .end = end,
            .before_position = try std.fmt.parseInt(u64, page.before_position orelse return error.InvalidConversationPage, 10),
            .before_ordinal = try std.fmt.parseInt(u64, page.before_ordinal orelse return error.InvalidConversationPage, 10),
        };
    };
    // Stage this entire bounded page before showing any of it. A later content
    // read can fail; a per-item retry would repeat already displayed items.
    const prepared = try renderScratch(init);
    errdefer prepared.close(init.io);
    for (0..page.items.len) |i| {
        const item = page.items[page.items.len - 1 - i];
        const position = try std.fmt.parseInt(u64, item.position, 10);
        const ordinal = try std.fmt.parseInt(u64, item.ordinal, 10);
        const bytes = try std.fmt.parseInt(u64, item.content.bytes, 10);
        if (position == 0 or position > end or !std.mem.eql(u8, item.content.display, "omitted") or item.content.sha256.len != 64) return error.InvalidConversationPage;
        const assistant = std.mem.eql(u8, item.kind, "assistant");
        const label = if (std.mem.eql(u8, item.kind, "user")) "You: " else if (assistant) "" else if (std.mem.eql(u8, item.kind, "tool_result")) "Tool result: " else return error.InvalidConversationPage;
        if (assistant) try prepared.writeStreamingAll(init.io, answer_divider);
        try prepared.writeStreamingAll(init.io, label);
        if (bytes > 8 * 1024) {
            var output_buffer: [4096]u8 = undefined;
            var writer = prepared.writerStreaming(init.io, &output_buffer);
            try writeContentOmission(&writer.interface, store, session, position, ordinal, bytes);
            try writer.flush();
            continue;
        }
        {
            const content_file = try renderScratch(init);
            defer content_file.close(init.io);
            var offset: u64 = 0;
            while (true) {
                const range = try readRequest(frontend, init.io, client.conversationContent, .{ store, session, position, ordinal, offset, content_file, &reply_buffer });
                if (range.total != bytes or range.next < offset or (range.next == offset and offset != bytes)) return error.InvalidConversationContent;
                offset = range.next;
                if (offset == bytes) break;
            }
            if (assistant) {
                var output_buffer: [4096]u8 = undefined;
                var writer = prepared.writerStreaming(init.io, &output_buffer);
                var renderer: AnswerRenderer = .{ .out = &writer.interface };
                var input_buffer: [4096]u8 = undefined;
                var read_offset: u64 = 0;
                while (read_offset < bytes) {
                    const count = try content_file.readPositionalAll(init.io, input_buffer[0..@intCast(@min(bytes - read_offset, input_buffer.len))], read_offset);
                    if (count == 0) return error.TruncatedConversationContent;
                    try renderer.feed(input_buffer[0..count]);
                    read_offset += count;
                }
                try renderer.finish();
                try writer.flush();
            } else try writeSafeFileAt(init.io, content_file, prepared, 0, bytes);
            try prepared.writeStreamingAll(init.io, "\n");
        }
    }
    return .{ .file = prepared, .next = next };
}

fn saveConversationContent(init: std.process.Init, args: []const []const u8) !void {
    var store: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var position: ?u64 = null;
    var ordinal: ?u64 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store") and store == null) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session") and session == null) session = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--position") and position == null) position = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else if (std.mem.eql(u8, args[index], "--ordinal") and ordinal == null) ordinal = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else if (std.mem.eql(u8, args[index], "--output") and output == null) output = try takeValue(args, &index) else return usage();
    }
    const selected_session = session orelse return usage();
    const selected_position = position orelse return usage();
    const selected_ordinal = ordinal orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected_store = try selectedStore(init, store, &selected_buffer);
    const file = try std.Io.Dir.cwd().createFile(init.io, output orelse return usage(), .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(init.io);
    errdefer std.debug.print("rui: content output may be incomplete; do not treat it as the saved item\n", .{});
    var reply_buffer: client.ReplyBuffer = .{};
    _ = try client.conversationContentStream(init.io, selected_store, selected_session, selected_position, selected_ordinal, file, &reply_buffer);
}

fn sessions(init: std.process.Init, args: []const []const u8) !void {
    var explicit: ?[]const u8 = null;
    var all = false;
    var json = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store") and explicit == null) explicit = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--all") and !all) all = true else if (std.mem.eql(u8, args[index], "--json") and !json) json = true else return usage();
    }
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = try selectedStore(init, explicit, &fallback);
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace: ?[]const u8 = if (all) null else blk: {
        var directory = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
        defer directory.close(init.io);
        const length = try directory.realPath(init.io, &workspace_buffer);
        break :blk workspace_buffer[0..length];
    };
    var cursor: client.SessionListCursor = .{};
    var found = false;
    while (true) {
        const page = try sessionPage(init, store, workspace, cursor, if (json) .json else .human);
        found = found or page.count != 0;
        cursor = page.next orelse break;
    }
    if (!found and !json) try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No configured Sessions in this scope. Use rui to start a new one, or --all to inspect every Workspace.\n");
}

fn requests(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 1 and std.mem.eql(u8, args[0], "--json");
    if (args.len != 0 and !json) return usage();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &path);
    var dir = std.Io.Dir.cwd().openDir(init.io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return if (json) std.Io.File.stdout().writeStreamingAll(init.io, "[]\n") else {},
        else => return err,
    };
    defer dir.close(init.io);
    if ((try dir.stat(init.io)).permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
    if (json) try std.Io.File.stdout().writeStreamingAll(init.io, "[");
    var first = true;
    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const handle = entry.name[0 .. entry.name.len - ".json".len];
        if (!client.validRequestHandle(handle)) continue;
        if (json) {
            if (!first) try std.Io.File.stdout().writeStreamingAll(init.io, ",");
            var line: [64]u8 = undefined;
            try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "\"{s}\"", .{handle}));
        } else {
            try std.Io.File.stdout().writeStreamingAll(init.io, handle);
            try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        }
        first = false;
    }
    if (json) try std.Io.File.stdout().writeStreamingAll(init.io, "]\n");
}

fn recover(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var captured = try client.openCaptured(init.io, try requestDirectory(init, &directory_buffer), args[0]);
    var buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(init.io);
        break :blk try client.sendCaptured(init.io, &captured, null, &buffer);
    };
    if (json) try writeCommandReply(init.io, reply) else try writeAdmission(init.io, reply, null);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn result(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    if (!saved.kind.eql("message")) return error.NotMessageRequest;
    const address = try client.MessageAddress.init(saved.store.slice(), saved.session.slice(), saved.key.slice());
    try showResult(init, &address, if (json) .json else .human, null);
}

fn showResult(init: std.process.Init, saved: *const client.MessageAddress, presentation: Presentation, frontend: ?*Frontend) !void {
    const json = presentation == .json;
    var observed = try readRequest(frontend, init.io, client.observeMessage, .{ std.heap.c_allocator, saved });
    defer observed.deinit();
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const out = if (frontend) |owner| owner.terminal.writer() else &output_writer.interface;
    const state = observed.state;
    if (presentation == .interactive and state != .completed) {
        const notice = switch (state) {
            .accepted => "Rui: This Message was accepted; observe its original request for the result.\n",
            .queued => "Rui: This saved Message has no answer yet; it remains queued.\n",
            .processing => "Rui: This saved Message is being processed; observe the same request rather than sending it again.\n",
            .rejected => "Rui: This submission was rejected; no work was admitted.\n",
            .cancelled => "Rui: This saved Message was cancelled; no answer was produced.\n",
            .failed => "Rui: This saved Message failed; no answer was produced.\n",
            .completed => unreachable,
        };
        out.writeAll(notice) catch return error.AnswerDisplayFailed;
        if (observed.code) |code| {
            writeField(out, "Rui: Code: ", code) catch return error.AnswerDisplayFailed;
            if (std.mem.eql(u8, code, "indeterminate"))
                out.writeAll("Rui: The command may have run. Rui did not rerun it; inspect saved work before choosing a next action.\n") catch return error.AnswerDisplayFailed;
        }
        try out.flush();
    } else if (!json and presentation != .interactive) {
        var line: [256]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "result: {s}\n", .{@tagName(state)}));
        if (observed.code) |code|
            try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "code: {s}\n", .{code}));
    }
    if (state != .completed) {
        if (json) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "{\"observation\":");
            var buffer: [protocol.content_window_bytes]u8 = undefined;
            var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
            try observed.writeJson(&writer.interface);
            try writer.flush();
            try std.Io.File.stdout().writeStreamingAll(init.io, ",\"answer\":null}\n");
        }
        return;
    }
    if (json) {
        const file = try renderScratch(init);
        defer file.close(init.io);
        var read_buffer: client.ReplyBuffer = .{};
        const answer = try client.readResult(init.io, saved.store.slice(), saved.key.slice(), file, &read_buffer);
        if (answer != .answer) return error.ResultReadFailed;
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"observation\":");
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try observed.writeJson(&writer.interface);
        try writer.flush();
        try std.Io.File.stdout().writeStreamingAll(init.io, ",\"answer\":\"");
        try writeJsonFileAt(init.io, file, 0, answer.answer.bytes);
        return std.Io.File.stdout().writeStreamingAll(init.io, "\"}\n");
    }
    if (presentation == .interactive) {
        return showInteractiveAnswer(init, saved, frontend, out) catch |err| {
            if (frontend) |owner| {
                if (owner.fatal(err)) return err;
            }
            if (err == error.CanonicalStoreFailure or err == error.InteractiveInterrupted) return err;
            return error.AnswerDisplayFailed;
        };
    }
    var read_buffer: client.ReplyBuffer = .{};
    const answer = try client.readResult(init.io, saved.store.slice(), saved.key.slice(), std.Io.File.stdout(), &read_buffer);
    switch (answer) {
        .answer => {},
        .command => return error.ResultReadFailed,
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

// Once the divider is attempted, no outer Session catch may offer another
// prompt: both transport and terminal failures can leave a partial answer.
fn showInteractiveAnswer(init: std.process.Init, saved: *const client.MessageAddress, frontend: ?*Frontend, out: *std.Io.Writer) !void {
    try out.writeAll(answer_divider);
    var renderer: AnswerRenderer = .{ .out = out };
    var read_buffer: client.ReplyBuffer = .{};
    const answer = try streamRequest(frontend, init.io, client.readResultStream, .{ saved.store.slice(), saved.key.slice() }, &renderer, &read_buffer);
    if (answer != .answer) return error.ResultReadFailed;
    try renderer.finish();
    try out.writeAll("\n");
    try out.flush();
}

fn waitEnteredSession(frontend: *Frontend) !?Work {
    const report = try inspectWork(frontend.init, frontend.store, frontend.session, frontend);
    defer report.file.close(frontend.init.io);
    const selected = report.work.selected_message orelse {
        try frontend.terminal.write("Rui: No work to wait for.\n");
        return null;
    };
    // Selection is one immutable Message address, not the Session's changing
    // current Turn; a successor never delays the originally selected answer.
    const address = try client.MessageAddress.init(frontend.store, frontend.session, selected.slice());
    while (true) {
        var observed = try readRequest(frontend, frontend.init.io, client.observeMessage, .{ std.heap.c_allocator, &address });
        defer observed.deinit();
        if (observed.state.terminal()) {
            try showResult(frontend.init, &address, .interactive, frontend);
            return null;
        }
        if (observed.progress) |progress| {
            if (progress.action != null and progress.status == .waiting_for_permission) return report.work;
        }
        try frontend.service();
        try std.Io.sleep(frontend.init.io, .fromMilliseconds(100), .awake);
    }
}

const Work = struct {
    const Recent = struct {
        key: protocol.Bounded(protocol.max_key_bytes) = .{},
        outcome: protocol.Bounded(96) = .{},
    };

    status: protocol.Bounded(32) = .{},
    turn: protocol.Bounded(32) = .{},
    action: protocol.Bounded(32) = .{},
    action_count: usize = 0,
    indeterminate_action: ?protocol.Bounded(32) = null,
    indeterminate_count: usize = 0,
    workspace: protocol.Bounded(protocol.max_workspace_bytes) = .{},
    provider: protocol.Bounded(32) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    permission_mode: protocol.Bounded(16) = .{},
    bash: bool = false,
    selected_message: ?protocol.Bounded(protocol.max_key_bytes) = null,
    history_end: ?u64 = null,
    recent: [10]Recent = [_]Recent{.{}} ** 10,
    recent_count: usize = 0,
};

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

fn readWork(reader: *std.json.Reader) !Work {
    var work: Work = .{};
    if ((try reader.next()) != .object_begin) return error.InvalidObservation;
    while (true) {
        const name = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
        defer freeToken(name);
        if (name == .object_end) break;
        const field = try tokenString(name);
        if (std.mem.eql(u8, field, "session")) {
            if ((try reader.peekNextTokenType()) == .null) {
                _ = try reader.next();
                continue;
            }
            if ((try reader.next()) != .object_begin) return error.InvalidObservation;
            while (true) {
                const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                defer freeToken(inner);
                if (inner == .object_end) break;
                const key = try tokenString(inner);
                if (std.mem.eql(u8, key, "workspace") or std.mem.eql(u8, key, "permission_mode") or
                    std.mem.eql(u8, key, "provider") or std.mem.eql(u8, key, "model"))
                {
                    const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, protocol.max_workspace_bytes);
                    defer freeToken(value);
                    if (std.mem.eql(u8, key, "workspace")) {
                        try work.workspace.set(try tokenString(value));
                    } else if (std.mem.eql(u8, key, "provider")) {
                        try work.provider.set(try tokenString(value));
                    } else if (std.mem.eql(u8, key, "model")) {
                        try work.model.set(try tokenString(value));
                    } else try work.permission_mode.set(try tokenString(value));
                } else if (std.mem.eql(u8, key, "tools")) {
                    if ((try reader.next()) != .array_begin) return error.InvalidObservation;
                    while (true) {
                        const tool = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 16);
                        defer freeToken(tool);
                        if (tool == .array_end) break;
                        const tool_name = try tokenString(tool);
                        if (std.mem.eql(u8, tool_name, "bash")) work.bash = true else if (!std.mem.eql(u8, tool_name, "edit")) return error.InvalidObservation;
                    }
                } else try reader.skipValue();
            }
        } else if (std.mem.eql(u8, field, "selected_message")) {
            const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, protocol.max_key_bytes);
            defer freeToken(value);
            if (value != .null) {
                var selected: protocol.Bounded(protocol.max_key_bytes) = .{};
                try selected.set(try tokenString(value));
                work.selected_message = selected;
            }
        } else if (std.mem.eql(u8, field, "history_end")) {
            if (work.history_end != null) return error.InvalidObservation;
            const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 20);
            defer freeToken(value);
            work.history_end = try std.fmt.parseInt(u64, try tokenString(value), 10);
            if (work.history_end.? > std.math.maxInt(i64)) return error.InvalidObservation;
        } else if (std.mem.eql(u8, field, "recent_messages")) {
            if ((try reader.next()) != .array_begin) return error.InvalidObservation;
            while (true) {
                const item = try reader.next();
                if (item == .array_end) break;
                if (item != .object_begin or work.recent_count == work.recent.len) return error.InvalidObservation;
                const recent = &work.recent[work.recent_count];
                var has_message = false;
                while (true) {
                    const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                    defer freeToken(inner);
                    if (inner == .object_end) break;
                    const key = try tokenString(inner);
                    if (std.mem.eql(u8, key, "message") or std.mem.eql(u8, key, "outcome")) {
                        const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, protocol.max_key_bytes);
                        defer freeToken(value);
                        if (std.mem.eql(u8, key, "message")) {
                            try recent.key.set(try tokenString(value));
                            has_message = true;
                        } else try recent.outcome.set(try tokenString(value));
                    } else try reader.skipValue();
                }
                if (!has_message or recent.outcome.len == 0) return error.InvalidObservation;
                work.recent_count += 1;
            }
        } else if (std.mem.eql(u8, field, "work")) {
            if ((try reader.next()) != .object_begin) return error.InvalidObservation;
            while (true) {
                const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                defer freeToken(inner);
                if (inner == .object_end) break;
                const key = try tokenString(inner);
                if (std.mem.eql(u8, key, "status") or std.mem.eql(u8, key, "turn")) {
                    const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 32);
                    defer freeToken(value);
                    if (std.mem.eql(u8, key, "status")) try work.status.set(try tokenString(value)) else try work.turn.set(try tokenString(value));
                } else try reader.skipValue();
            }
        } else if (std.mem.eql(u8, field, "actions")) {
            if ((try reader.next()) != .object_begin) return error.InvalidObservation;
            while (true) {
                const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                defer freeToken(inner);
                if (inner == .object_end) break;
                if (!std.mem.eql(u8, try tokenString(inner), "resolved")) {
                    try reader.skipValue();
                    continue;
                }
                if ((try reader.next()) != .array_begin) return error.InvalidObservation;
                while (true) {
                    const item = try reader.next();
                    if (item == .array_end) break;
                    if (item != .object_begin) return error.InvalidObservation;
                    var action: protocol.Bounded(32) = .{};
                    var indeterminate = false;
                    while (true) {
                        const key = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                        defer freeToken(key);
                        if (key == .object_end) break;
                        const action_field = try tokenString(key);
                        if (std.mem.eql(u8, action_field, "action") or std.mem.eql(u8, action_field, "code")) {
                            const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 32);
                            defer freeToken(value);
                            if (std.mem.eql(u8, action_field, "action")) try action.set(try tokenString(value)) else indeterminate = std.mem.eql(u8, try tokenString(value), "indeterminate");
                        } else try reader.skipValue();
                    }
                    if (indeterminate) {
                        if (action.len == 0) return error.InvalidObservation;
                        if (work.indeterminate_action == null) work.indeterminate_action = action;
                        work.indeterminate_count += 1;
                    }
                }
            }
        } else if (std.mem.eql(u8, field, "actionable_permissions")) {
            if ((try reader.next()) != .array_begin) return error.InvalidObservation;
            while (true) {
                const item = try reader.next();
                if (item == .array_end) break;
                if (item != .object_begin) return error.InvalidObservation;
                while (true) {
                    const inner = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                    defer freeToken(inner);
                    if (inner == .object_end) break;
                    if (std.mem.eql(u8, try tokenString(inner), "action")) {
                        const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 32);
                        defer freeToken(value);
                        if (work.action.len == 0) try work.action.set(try tokenString(value));
                        work.action_count += 1;
                    } else try reader.skipValue();
                }
            }
        } else try reader.skipValue();
    }
    if ((work.workspace.len != 0 and work.status.len == 0) or (try reader.next()) != .end_of_document) return error.InvalidObservation;
    return work;
}

test "Current keeps an optional history watermark for resume without rejecting ordinary inspection" {
    inline for (.{
        .{ .json = "{\"session\":null,\"execution\":{\"status\":\"unavailable\"}}", .expected = @as(?u64, null), .valid = true },
        .{ .json = "{\"session\":{\"workspace\":\"/tmp\"},\"work\":{\"status\":\"idle\"}}", .expected = @as(?u64, null), .valid = true },
        .{ .json = "{\"session\":{\"workspace\":\"/tmp\"},\"history_end\":\"0\",\"work\":{\"status\":\"idle\"}}", .expected = @as(?u64, 0), .valid = true },
        .{ .json = "{\"session\":{\"workspace\":\"/tmp\"},\"history_end\":\"7\",\"work\":{\"status\":\"idle\"}}", .expected = @as(?u64, 7), .valid = true },
        .{ .json = "{\"session\":{\"workspace\":\"/tmp\"},\"history_end\":\"1\",\"history_end\":\"2\",\"work\":{\"status\":\"idle\"}}", .expected = @as(?u64, null), .valid = false },
    }) |case| {
        var source = std.Io.Reader.fixed(case.json);
        var reader = std.json.Reader.init(std.testing.allocator, &source);
        defer reader.deinit();
        if (case.valid) {
            try std.testing.expectEqual(case.expected, (try readWork(&reader)).history_end);
        } else try std.testing.expectError(error.InvalidObservation, readWork(&reader));
    }
}

const SessionObservation = struct {
    work: Work,
    // The complete Current capture remains owned until all its permissions
    // have been displayed; no per-Action resident list is needed.
    file: std.Io.File,
};

fn inspectWork(init: std.process.Init, store: []const u8, session_ref: []const u8, frontend: ?*Frontend) !SessionObservation {
    const file = try renderScratch(init);
    errdefer file.close(init.io);
    var response: client.ReplyBuffer = .{};
    const reply = try readRequest(frontend, init.io, client.inspectSession, .{ store, session_ref, protocol.ReportProfile.current, file, &response });
    switch (reply) {
        .report => {},
        .command => |command| {
            try client.checkCanonicalFailure(command);
            return error.ObservationFailed;
        },
    }
    var input_buffer: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var json_reader = std.json.Reader.init(std.heap.c_allocator, &file_reader.interface);
    defer json_reader.deinit();
    return .{ .work = try readWork(&json_reader), .file = file };
}

fn showActionable(io: std.Io, file: std.Io.File, json: bool, output: ?*std.Io.Writer) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = output orelse &writer.interface;
    var input_buffer: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.reader(io, &input_buffer);
    var reader = std.json.Reader.init(std.heap.c_allocator, &file_reader.interface);
    defer reader.deinit();
    if ((try reader.next()) != .object_begin) return error.InvalidObservation;
    while (true) {
        const name = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
        defer freeToken(name);
        if (name == .object_end) return error.InvalidObservation;
        if (!std.mem.eql(u8, try tokenString(name), "actionable_permissions")) {
            try reader.skipValue();
            continue;
        }
        if ((try reader.next()) != .array_begin) return error.InvalidObservation;
        if (json) try out.writeAll("{\"event\":\"actionable_permissions\",\"actions\":[");
        var first = true;
        while (true) {
            const item = try reader.next();
            if (item == .array_end) break;
            if (item != .object_begin) return error.InvalidObservation;
            var action: protocol.Bounded(32) = .{};
            while (true) {
                const field = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 64);
                defer freeToken(field);
                if (field == .object_end) break;
                if (std.mem.eql(u8, try tokenString(field), "action")) {
                    const value = try reader.nextAllocMax(std.heap.c_allocator, .alloc_if_needed, 32);
                    defer freeToken(value);
                    try action.set(try tokenString(value));
                } else try reader.skipValue();
            }
            if (action.len == 0) return error.InvalidObservation;
            _ = std.fmt.parseInt(u64, action.slice(), 10) catch return error.InvalidObservation;
            if (json) {
                if (!first) try out.writeAll(",");
                try out.print("\"{s}\"", .{action.slice()});
            } else try writeField(out, "Action requiring attention: ", action.slice());
            first = false;
        }
        if (json) try out.writeAll("]}\n");
        try out.flush();
        return;
    }
}

fn writeFollowOutcome(init: std.process.Init, observation: *const client.MessageObservation, presentation: Presentation) !void {
    if (presentation == .interactive) return;
    if (presentation == .json) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"return\":\"outcome\",\"observation\":");
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try observation.writeJson(&writer.interface);
        try writer.flush();
        try std.Io.File.stdout().writeStreamingAll(init.io, "}\n");
    } else {
        var line: [128]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "return: outcome\nstatus: {s}\n", .{@tagName(observation.state)}));
    }
}

fn follow(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    if (!saved.kind.eql("message")) return error.NotMessageRequest;
    const address = try client.MessageAddress.init(saved.store.slice(), saved.session.slice(), saved.key.slice());
    var narration: CallNarration = .{};
    _ = try followMessage(init, &address, if (json) .json else .human, .follow_attention, &narration);
}

const FollowPolicy = enum {
    follow_attention,
    session_blocked,
    terminal_only,

    fn attention(self: FollowPolicy, observation: *const client.MessageObservation) ?client.MessageObservation.Progress {
        if (observation.state.terminal()) return null;
        const progress = observation.progress orelse return null;
        if (progress.action == null) return null;
        return switch (self) {
            .follow_attention => progress,
            .session_blocked => if (progress.status == .waiting_for_permission) progress else null,
            .terminal_only => null,
        };
    }
};

fn progressNotice(queue: client.MessageObservation.State, status: @FieldType(client.MessageObservation.Progress, "status"), has_action: bool) ![]const u8 {
    if (queue == .queued) {
        if (status == .waiting_for_permission) return "Rui: Your message is queued behind work needing a decision.\n";
        if (status == .in_flight) return if (has_action)
            "Rui: Your message is queued behind work in flight; an Action also needs a decision.\n"
        else
            "Rui: Your message is queued behind work in flight.\n";
        if (status == .runnable) return "Rui: Your message is queued and ready for execution.\n";
    } else if (queue == .processing and has_action and status == .in_flight) {
        return "Rui: An Action needs your choice while other work remains in flight.\n";
    }
    return error.InvalidObservation;
}

fn sessionCallHead(init: std.process.Init, store: []const u8, session: []const u8) !u64 {
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.sessionCalls(init.io, store, session, null, &buffer);
    if (reply.status == 409) return error.SessionNotConfigured;
    if (reply.status != 200) return error.CallFeedReadFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, try stringField(parsed.value, "type"), "session_calls") or
        (try objectField(parsed.value, "call")) != .null) return error.InvalidObservation;
    return std.fmt.parseInt(u64, try stringField(parsed.value, "position"), 10) catch error.InvalidObservation;
}

// Explicit keyed follow/wait retain their bounded notices. The automatic
// terminal transcript instead follows Session view facts and public content.
const CallNarration = struct {
    cursor: ?u64 = null,
    terminal_end: ?u64 = null,

    fn capture(init: std.process.Init, store: []const u8, session: []const u8) !CallNarration {
        var self: CallNarration = .{ .cursor = sessionCallHead(init, store, session) catch |err| blk: {
            if (err == error.CanonicalStoreFailure or err == error.RenderScratchCleanupFailed) return err;
            break :blk null;
        } };
        if (self.cursor == null) try self.unavailable(init.io, error.ActivityUnavailable);
        return self;
    }

    fn unavailable(self: *CallNarration, io: std.Io, err: anyerror) !void {
        if (err == error.CanonicalStoreFailure) return err;
        self.cursor = null;
        std.Io.File.stdout().writeStreamingAll(io, "Rui: Activity notices unavailable or incomplete; following the original Message independently.\n") catch return error.CallDisplayFailed;
    }

    fn drain(self: *CallNarration, init: std.process.Init, saved: *const client.MessageAddress, turn: u64, terminal: bool) !void {
        if (self.cursor == null) return;
        if (terminal and self.terminal_end == null) {
            self.terminal_end = sessionCallHead(init, saved.store.slice(), saved.session.slice()) catch |err| {
                return self.unavailable(init.io, err);
            };
            if (self.terminal_end.? < self.cursor.?) return self.unavailable(init.io, error.InvalidObservation);
        }
        var count: usize = 0;
        while (if (self.terminal_end) |end| self.cursor.? < end else count < 16) : (count += 1) {
            const requested = self.cursor.?;
            const notice = readCallNotice(init, saved, requested, turn, self.terminal_end) catch |err| {
                return self.unavailable(init.io, err);
            };
            self.cursor = notice.position;
            // Printing is deliberately outside the auxiliary boundary. After
            // any output failure, the caller exits rather than replaying it.
            if (notice.visible) notice.print(init.io) catch return error.CallDisplayFailed;
            if (notice.position == requested) return;
        }
    }
};

const CallNotice = struct {
    position: u64,
    visible: bool = false,
    name: protocol.Bounded(128) = .{},
    arguments: protocol.Bounded(256) = .{},
    name_length: u64 = 0,
    arguments_length: u64 = 0,
    rejection: ?protocol.Bounded(32) = null,

    fn print(self: *const CallNotice, io: std.Io) !void {
        const out = std.Io.File.stdout();
        if (self.rejection != null) try out.writeStreamingAll(io, "Rejected proposal · ");
        try writeSafePreview(io, self.name.slice());
        if (self.name_length > self.name.len) try out.writeStreamingAll(io, "…");
        try out.writeStreamingAll(io, " · ");
        try writeSafePreview(io, self.arguments.slice());
        if (self.arguments_length > self.arguments.len) try out.writeStreamingAll(io, "…");
        if (self.rejection) |code| {
            try out.writeStreamingAll(io, " · ");
            try writeSafePreview(io, code.slice());
        }
        try out.writeStreamingAll(io, "\n");
    }
};

// Complete retrieval and validation before printing even the name. One index
// exchange plus at most two bounded ranges, never a full argument download.
fn readCallNotice(init: std.process.Init, saved: *const client.MessageAddress, cursor: u64, selected_turn: u64, end: ?u64) !CallNotice {
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.sessionCalls(init.io, saved.store.slice(), saved.session.slice(), cursor, &buffer);
    if (reply.status != 200) return error.CallFeedReadFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    const position = std.fmt.parseInt(u64, try stringField(parsed.value, "position"), 10) catch return error.InvalidObservation;
    if (position < cursor) return error.InvalidObservation;
    var notice: CallNotice = .{ .position = if (end) |fixed| @min(position, fixed) else position };
    const value = try objectField(parsed.value, "call");
    if (value == .null) return notice;
    if (position == cursor) return error.InvalidObservation;
    if (end != null and position > end.?) return notice;
    const turn = std.fmt.parseInt(u64, try stringField(value, "turn"), 10) catch return error.InvalidObservation;
    _ = std.fmt.parseInt(u64, try stringField(value, "operation"), 10) catch return error.InvalidObservation;
    _ = std.fmt.parseInt(u64, try stringField(value, "ordinal"), 10) catch return error.InvalidObservation;
    if (turn != selected_turn) return notice;
    const classification = try stringField(value, "classification");
    if (std.mem.eql(u8, classification, "ask")) return notice;
    if (std.mem.eql(u8, classification, "rejected")) {
        notice.rejection = .{};
        try notice.rejection.?.set(try stringField(value, "rejection"));
    } else if (!std.mem.eql(u8, classification, "bypass")) return error.InvalidObservation;
    notice.name_length = try readCallPrefix(init, saved, position, .name, try objectField(value, "name"), &notice.name, &buffer);
    notice.arguments_length = try readCallPrefix(init, saved, position, .arguments, try objectField(value, "arguments"), &notice.arguments, &buffer);
    notice.visible = true;
    return notice;
}

fn readCallPrefix(init: std.process.Init, saved: *const client.MessageAddress, position: u64, field: protocol.SessionCallContent.Field, metadata: std.json.Value, destination: anytype, buffer: *client.ReplyBuffer) !u64 {
    const length = std.fmt.parseInt(u64, try stringField(metadata, "bytes"), 10) catch return error.InvalidObservation;
    var digest: [32]u8 = undefined;
    const encoded = try stringField(metadata, "sha256");
    if (encoded.len != 64) return error.InvalidObservation;
    _ = std.fmt.hexToBytes(&digest, encoded) catch return error.InvalidObservation;
    if (length == 0) return length;
    const range = try client.sessionCallContent(init.io, saved.store.slice(), saved.session.slice(), position, field, 0, &destination.bytes, buffer);
    if (range.total != length or range.next != @min(length, destination.bytes.len)) return error.InvalidObservation;
    destination.len = @intCast(range.next);
    if (length == destination.len) {
        const actual = protocol.contentDigest(destination.slice());
        if (!std.mem.eql(u8, &digest, &actual)) return error.InvalidObservation;
    }
    // At most three trailing bytes can belong to an incomplete scalar.
    var trimmed: usize = 0;
    while (!std.unicode.utf8ValidateSlice(destination.slice())) : (trimmed += 1) {
        if (length == range.next or trimmed == 3 or destination.len == 0) return error.InvalidObservation;
        destination.len -= 1;
    }
    return length;
}

fn fatalPresentation(err: anyerror) bool {
    return err == error.InteractiveInterrupted or err == error.CanonicalStoreFailure or err == error.CallDisplayFailed or err == error.AnswerDisplayFailed or err == error.ActionDisplayFailed or
        err == error.WriteFailed or err == error.BrokenPipe or err == error.InputOutput or err == error.NoSpaceLeft or
        err == error.DiskQuota or err == error.FileTooBig or err == error.TerminalRestoreFailed or err == error.TerminalCleanupFailed or
        err == error.TerminalFlushFailed or err == error.IncompleteTerminalInput or err == error.IncompleteTerminalLine;
}

test "Frontend terminal custody distinguishes service failure from request outage" {
    var terminal: SessionTerminal = .{ .io = std.testing.io, .editor = .{ .buffer = &.{} }, .spare = &.{}, .original = undefined, .raw = undefined, .size = undefined };
    const frontend: Frontend = .{ .init = undefined, .terminal = &terminal, .admission = undefined };
    try std.testing.expect(!frontend.fatal(error.HostUnavailable));
    try std.testing.expect(frontend.fatal(error.IncompleteTerminalInput));
    try std.testing.expect(frontend.fatal(error.IncompleteTerminalLine));
    terminal.active = false;
    // Classifying names alone cannot cover every OS/service failure. Losing
    // custody is decisive even for an error normally recoverable from a worker.
    try std.testing.expect(frontend.fatal(error.HostUnavailable));
}

// null is the selected message's terminal observation; an Action is only a hint
// to inspect and decide against the Host's exact current target.
fn followMessage(init: std.process.Init, saved: *const client.MessageAddress, presentation: Presentation, policy: FollowPolicy, narration: *CallNarration) !?Work {
    var last_queue: ?client.MessageObservation.State = null;
    var last_progress: ?@FieldType(client.MessageObservation.Progress, "status") = null;
    var last_action = false;
    var unchanged_polls: u8 = 0;
    var announced = false;
    while (true) {
        var observed = try client.observeMessage(init.io, std.heap.c_allocator, saved);
        defer observed.deinit();
        const selected_turn = if (presentation == .interactive) observed.processing_turn else null;
        if (observed.state.terminal()) {
            // The selected Turn has settled. Drain only through a fixed
            // committed head; a busy successor cannot delay this answer.
            if (selected_turn) |turn| try narration.drain(init, saved, turn, true);
            try writeFollowOutcome(init, &observed, presentation);
            return null;
        }
        if (selected_turn) |turn| try narration.drain(init, saved, turn, false);
        // Test-only pause after capturing the Message's coherent observation.
        try testGate(init.io, "RUI_TEST_FOLLOW_GATE");
        // Notices describe status and Action presence, not which Action. A
        // replacement ID still targets attention but does not reset reminders.
        const progress_status = if (observed.progress) |progress| progress.status else null;
        const has_action = if (observed.progress) |progress| progress.action != null else false;
        if (presentation == .interactive and (last_queue == null or last_queue.? != observed.state or last_progress != progress_status or last_action != has_action)) {
            // The permission block supplies the immediate attention cue.
            announced = has_action;
            if (policy != .follow_attention and has_action and progress_status == .in_flight)
                std.Io.File.stdout().writeStreamingAll(init.io, try progressNotice(observed.state, progress_status.?, true)) catch return error.CallDisplayFailed;
            last_queue = observed.state;
            last_progress = progress_status;
            last_action = has_action;
            unchanged_polls = 0;
        } else if (presentation == .interactive and observed.progress != null) {
            if (observed.state == .queued and !announced and unchanged_polls == 9) {
                std.Io.File.stdout().writeStreamingAll(init.io, try progressNotice(observed.state, progress_status.?, false)) catch return error.CallDisplayFailed;
                announced = true;
            } else if (unchanged_polls < 10) unchanged_polls += 1;
        }
        if (policy.attention(&observed)) |progress| {
            var work: Work = .{};
            try work.status.set(@tagName(progress.status));
            var action_buffer: [20]u8 = undefined;
            try work.action.set(try std.fmt.bufPrint(&action_buffer, "{d}", .{progress.action.?}));
            if (presentation == .json) {
                var line: [160]u8 = undefined;
                try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "{{\"return\":\"attention\",\"status\":\"{s}\",\"action\":\"{s}\"}}\n", .{ work.status.slice(), work.action.slice() }));
            } else if (presentation == .human) {
                var line: [160]u8 = undefined;
                try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "return: attention\nstatus: {s}\naction: {s}\n", .{ work.status.slice(), work.action.slice() }));
            }
            return work;
        }
        try std.Io.sleep(init.io, .fromMilliseconds(100), .awake);
    }
}

fn inspectAction(init: std.process.Init, args: []const []const u8, interactive: bool) !void {
    return inspectEnteredAction(init, args, interactive, null);
}

fn inspectEnteredAction(init: std.process.Init, args: []const []const u8, interactive: bool, frontend: ?*Frontend) !void {
    const io = init.io;
    var store: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var action: ?u64 = null;
    var json = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session")) session = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--action")) action = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else if (std.mem.eql(u8, args[index], "--json")) json = true else return error.UnknownArgument;
    }
    const target = action orelse return usage();
    const reference = session orelse return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, store, &selected_buffer);
    if (interactive) {
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        if (std.c.ioctl(1, @intCast(std.c.T.IOCGWINSZ), &size) == 0 and size.col > 0) {
            if (size.col <= action_choice_prompt.len + 1) return error.TerminalTooNarrow;
        }
    }
    const file = try renderScratch(init);
    defer file.close(io);
    var buffer: client.ReplyBuffer = .{};
    var call_bytes: u64 = 0;
    if (!interactive) {
        const call = try client.readActionCallId(io, selected, reference, target, file, &buffer);
        if (call != .answer) return error.ActionReadFailed;
        call_bytes = call.answer.bytes;
    }
    const arguments = try readRequest(frontend, io, client.readActionArguments, .{ selected, reference, target, file, &buffer });
    if (arguments != .answer) {
        try client.checkCanonicalFailure(arguments.command);
        return error.ActionReadFailed;
    }
    var source: ActionSource = .{ .io = io, .file = file, .start = call_bytes, .length = arguments.answer.bytes };
    const descriptor = (try tools.inspectBashArguments(&source)) orelse return error.InvalidActionArguments;
    source.position = 0;
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    const out = if (frontend) |owner| owner.terminal.writer() else &writer.interface;
    writeActionInspection(io, target, &source, descriptor, json, interactive, out) catch |err| {
        if (interactive) return error.ActionDisplayFailed;
        return err;
    };
    try out.flush();
}

// Retrieval and exact descriptor validation finish before any authority-bearing
// output. Failure after rendering begins is fatal to the interactive session.
fn writeActionInspection(io: std.Io, target: u64, source: *ActionSource, descriptor: tools.BashArguments, json: bool, interactive: bool, out: *std.Io.Writer) !void {
    var line: [96]u8 = undefined;
    if (json) {
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"action\":\"{d}\",\"call_id\":\"", .{target}));
        try writeJsonFileAt(io, source.file, 0, source.start);
        try std.Io.File.stdout().writeStreamingAll(io, "\",\"arguments\":\"");
        try writeJsonFileAt(io, source.file, source.start, source.length);
        return std.Io.File.stdout().writeStreamingAll(io, "\"}\n");
    }
    // Quote provider-controlled fields so control and bidi bytes cannot alter the
    // proposal visible next to the human approval prompt.
    if (interactive) try out.writeAll("\n────────\nPermission required · Bash\n") else try out.print("Action {d}\n", .{target});
    try out.flush();
    if (!interactive) {
        try std.Io.File.stdout().writeStreamingAll(io, "call ID: \"");
        try writeSafeFileAt(io, source.file, std.Io.File.stdout(), 0, source.start);
        try std.Io.File.stdout().writeStreamingAll(io, "\"\n");
    }
    try out.writeAll(if (interactive) "Command: \"" else "Bash command: \"");
    var terminal_text: TerminalText = .{ .mode = .line };
    const CommandDisplay = struct {
        output: *std.Io.Writer,
        text: *TerminalText,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.text.feed(self.output, bytes);
        }
    };
    var display: CommandDisplay = .{ .output = out, .text = &terminal_text };
    if (!try tools.writeBashCommand(source, &display)) return error.InvalidActionArguments;
    try terminal_text.finish(out);
    try out.writeAll("\"\n");
    if (descriptor.timeout_ms) |timeout| {
        try out.print("Timeout: {d} ms\n", .{timeout});
    } else try out.writeAll("Timeout: Host default\n");
}

const ActionSource = struct {
    io: std.Io,
    file: std.Io.File,
    start: u64,
    length: u64,
    position: u64 = 0,
    buffer_start: u64 = 0,
    buffer_length: usize = 0,
    buffer: [protocol.content_window_bytes]u8 = undefined,

    pub fn peek(self: *ActionSource) !?u8 {
        if (self.position == self.length) return null;
        if (self.position < self.buffer_start or self.position >= self.buffer_start + self.buffer_length) {
            self.buffer_start = self.position;
            const wanted: usize = @intCast(@min(self.length - self.position, self.buffer.len));
            self.buffer_length = try self.file.readPositionalAll(self.io, self.buffer[0..wanted], self.start + self.position);
            if (self.buffer_length != wanted) return error.TruncatedResult;
        }
        return self.buffer[@intCast(self.position - self.buffer_start)];
    }

    pub fn take(self: *ActionSource) !u8 {
        const byte = try self.peek() orelse return error.InvalidActionArguments;
        self.position += 1;
        return byte;
    }
};

fn writeSafeFileAt(io: std.Io, file: std.Io.File, destination: std.Io.File, start: u64, length: u64) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var writer = destination.writerStreaming(io, &output_buffer);
    var text: TerminalText = .{ .mode = .line };
    var chunk: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const wanted: usize = @intCast(@min(length - offset, chunk.len));
        if (try file.readPositionalAll(io, chunk[0..wanted], start + offset) != wanted) return error.TruncatedResult;
        try text.feed(&writer.interface, chunk[0..wanted]);
        offset += wanted;
    }
    try text.finish(&writer.interface);
    try writer.flush();
}

fn writeJsonFileAt(io: std.Io, file: std.Io.File, start: u64, length: u64) !void {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    var chunk: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const wanted: usize = @intCast(@min(length - offset, chunk.len));
        if (try file.readPositionalAll(io, chunk[0..wanted], start + offset) != wanted) return error.TruncatedResult;
        try std.json.Stringify.encodeJsonStringChars(chunk[0..wanted], .{ .escape_unicode = false }, &writer.interface);
        offset += wanted;
    }
    try writer.flush();
}

fn takeValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingArgumentValue;
    return args[index.*];
}

fn usage() error{InvalidArguments} {
    printUsage();
    return error.InvalidArguments;
}

fn printUsage() void {
    std.debug.print(
        \\usage:
        \\  rui [--store PATH] [--provider codex] [--model MODEL]
        \\    On a terminal, attach/start a Host and create a fresh Session in the current Workspace.
        \\    Non-TTY calls must use explicit one-shot commands; use rui requests/recover after a lost reply.
        \\  rui --resume [--store PATH] [--] [REF]
        \\    Enter an existing Session by exact reference or choose from Host-owned pages in this Workspace.
        \\    All new commands use --store, then saved Store, then HOME/.local/share/rui/store.
        \\  rui login codex
        \\  rui host status [--store PATH]
        \\    Read the selected Store's protected Host readiness, capacity and capabilities without starting it.
        \\  rui host start [--store PATH]
        \\    Attach or detach a capacity-8 managed Host; existing Host settings win.
        \\  rui host stop [--store PATH] [--instance HEX]
        \\    Stop the observed Host, affecting all Store work; retry a lost reply only with the same instance.
        \\  rui setup [--store PATH] [--provider codex] [--model MODEL | --clear-model]
        \\    Inspect prospective selection, local credential and Host status; save defaults only with flags.
        \\    A supplied Store must exist and pass canonical/private checks. --clear-model inherits the recommendation.
        \\  rui sessions [--store PATH] [--all] [--json]
        \\    List configured Sessions here or in all Workspaces; --json emits one bounded page per line.
        \\  rui conversation-content [--store PATH] --session REF --position N --ordinal N --output FILE
        \\    Save exact public content to a new file; an interrupted transfer leaves incomplete output.
        \\  rui serve [--store PATH] [--active-capacity N] [--codex | --provider-endpoint URL] [--provider-ca-file PATH] [--fault NAME]
        \\  rui configure [--store PATH] --session REF [settings] [--json]
        \\    First configuration requires --workspace PATH --provider codex --model MODEL.
        \\  One-shot commands (never prompt or change meaning on redirection):
        \\  rui message [--store PATH] --session REF TEXT|- [--json]
        \\    --text FILE|- also captures a file or stdin before sending.
        \\  rui wait-session [--store PATH] --session REF [--terminal] [--json]
        \\    Select active/oldest queued work once; return idle if neither exists.
        \\  rui inspect-action --store PATH --session REF --action ID [--json]
        \\  rui allow-action --store PATH --session REF --action ID [--json]
        \\  rui deny-action --store PATH --session REF --action ID [--json]
        \\  rui requests [--json]
        \\  rui recover HANDLE [--json]
        \\  rui follow HANDLE [--json]
        \\    Follow this saved Message, not whatever the Session does next.
        \\  rui result HANDLE [--json]
        \\    Handles are saved under HOME/.config/rui/requests; scripted Host startup is explicit.
        \\  Low-level explicit-key commands:
        \\  rui configure --store PATH --record FILE --key KEY --session REF [settings]
        \\  rui message --store PATH --record FILE --key KEY --session REF --text FILE|-
        \\  rui stop-session --store PATH --record FILE --key KEY --session REF
        \\  rui interrupt-model --store PATH --record FILE --key KEY --session REF --turn ID --operation ID
        \\  rui allow-action --store PATH --record FILE --key KEY --session REF --action ID
        \\  rui deny-action --store PATH --record FILE --key KEY --session REF --action ID
        \\  rui retry --store PATH --record FILE --kind configure|message|session-stop|model-interruption|permission-decision
        \\  rui observe-command --store PATH --key KEY
        \\  rui read-result --store PATH --key KEY
        \\  rui read-action-call-id --store PATH --session REF --action ID
        \\  rui read-action-arguments --store PATH --session REF --action ID
        \\  rui inspect-session --store PATH --session REF [--profile current|full]
        \\
    , .{});
}

test "interactive progress distinguishes queued dependency from selected work" {
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work in flight.\n", try progressNotice(.queued, .in_flight, false));
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work in flight; an Action also needs a decision.\n", try progressNotice(.queued, .in_flight, true));
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work needing a decision.\n", try progressNotice(.queued, .waiting_for_permission, true));
    try std.testing.expectEqualStrings("Rui: An Action needs your choice while other work remains in flight.\n", try progressNotice(.processing, .in_flight, true));
    try std.testing.expectEqualStrings("Rui: Your message is queued and ready for execution.\n", try progressNotice(.queued, .runnable, false));
    try std.testing.expectError(error.InvalidObservation, progressNotice(.processing, .in_flight, false));
    try std.testing.expectError(error.InvalidObservation, progressNotice(.failed, .in_flight, false));
}

test "Message follow policies use decoded facts without inventing progress" {
    const address = try client.MessageAddress.init("/store", "original/session", "original-key");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"original-key\",\"observation\":{\"kind\":\"message\",\"target\":\"original/session\",\"status\":\"accepted\",\"queue\":{\"status\":\"queued\"}";
    // Independent expectations: ordinary follow sees attention alongside a
    // progressing sibling, Session wait sees only blocked progress, terminal
    // wait sees neither. Missing progress grants no attention or runnable fact.
    const cases = .{
        .{ "}}", false, false },
        .{ ",\"progress\":{\"status\":\"runnable\",\"action\":null}}}", false, false },
        .{ ",\"progress\":{\"status\":\"in_flight\",\"action\":null}}}", false, false },
        .{ ",\"progress\":{\"status\":\"in_flight\",\"action\":\"17\"}}}", true, false },
        .{ ",\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"29\"}}}", true, true },
        .{ ",\"result\":{\"status\":\"failed\",\"code\":\"original_failure\"},\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"31\"}}}", false, false },
    };
    inline for (cases) |case| {
        var observed = try client.MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = prefix ++ case[0] }, &address);
        defer observed.deinit();
        try std.testing.expectEqual(case[1], FollowPolicy.follow_attention.attention(&observed) != null);
        try std.testing.expectEqual(case[2], FollowPolicy.session_blocked.attention(&observed) != null);
        try std.testing.expect(FollowPolicy.terminal_only.attention(&observed) == null);
        if (comptime std.mem.eql(u8, case[0], "}}")) try std.testing.expect(observed.progress == null);
    }
}

test "Message attention retains replacement IDs while notices retain status and presence" {
    const address = try client.MessageAddress.init("/store", "s", "k");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"s\",\"queue\":{\"status\":\"processing\"},\"progress\":{\"status\":\"in_flight\",\"action\":\"";
    inline for (.{ .{ "17", 17 }, .{ "71", 71 } }) |case| {
        var observed = try client.MessageObservation.parse(std.testing.allocator, .{ .status = 200, .body = prefix ++ case[0] ++ "\"}}}" }, &address);
        defer observed.deinit();
        const attention = FollowPolicy.follow_attention.attention(&observed).?;
        try std.testing.expectEqual(@as(u64, case[1]), attention.action.?);
        try std.testing.expectEqualStrings("Rui: An Action needs your choice while other work remains in flight.\n", try progressNotice(observed.state, attention.status, attention.action != null));
        try std.testing.expect(FollowPolicy.session_blocked.attention(&observed) == null);
    }
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
