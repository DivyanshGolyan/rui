const std = @import("std");
const TerminalEditor = @import("TerminalEditor.zig");
const TerminalText = @import("TerminalText.zig");
const SessionFrontend = @import("SessionFrontend.zig");
const SessionView = @import("SessionView.zig");
const ClientTask = @import("ClientTask.zig");
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

pub fn main(init: std.process.Init) !u8 {
    dispatch(init) catch |err| {
        if (std.c.isatty(2) != 1) return err;
        const name = @errorName(err);
        const vectors = [_]std.posix.iovec_const{
            .{ .base = "error: ", .len = "error: ".len },
            .{ .base = name.ptr, .len = name.len },
            .{ .base = "\n", .len = 1 },
        };
        TerminalEditor.writeDiagnostic(&vectors);
        return 1;
    };
    return 0;
}

fn dispatch(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or std.mem.startsWith(u8, args[1], "--")) return newSession(init, args[1..]);
    const command = args[1];
    if (std.mem.eql(u8, command, "serve")) {
        try configureHostAllocator(init, args);
        return serve(init, args[2..]);
    }
    if (std.mem.eql(u8, command, "login")) return login(init, args[2..], false, codex_auth.login);
    if (std.mem.eql(u8, command, "host")) return host(init, args[2..]);
    if (std.mem.eql(u8, command, "export-conversation")) return exportConversation(init, args[2..]);
    if (std.mem.eql(u8, command, "setup")) try setup(init, args[2..]) else if (std.mem.eql(u8, command, "sessions")) try sessions(init, args[2..]) else if (std.mem.eql(u8, command, "wait-session")) try waitSession(init, args[2..]) else if (std.mem.eql(u8, command, "configure")) try configure(init, args[2..], false) else if (std.mem.eql(u8, command, "message")) try message(init, args[2..]) else if (std.mem.eql(u8, command, "stop-session")) try stopSession(init, args[2..]) else if (std.mem.eql(u8, command, "interrupt-model")) try interruptModel(init, args[2..]) else if (std.mem.eql(u8, command, "deny-action")) try decideAction(init, args[2..], .deny) else if (std.mem.eql(u8, command, "allow-action")) try decideAction(init, args[2..], .allow_once) else if (std.mem.eql(u8, command, "retry")) try retry(init.io, args[2..]) else if (std.mem.eql(u8, command, "observe-command")) try observe(init, args[2..]) else if (std.mem.eql(u8, command, "read-result")) try readResult(init, args[2..]) else if (std.mem.eql(u8, command, "read-action-call-id")) try readActionContent(init, args[2..], .call_id) else if (std.mem.eql(u8, command, "read-action-arguments")) try readActionArguments(init, args[2..]) else if (std.mem.eql(u8, command, "inspect-session")) try inspect(init, args[2..]) else if (std.mem.eql(u8, command, "requests")) try requests(init, args[2..]) else if (std.mem.eql(u8, command, "recover")) try recover(init, args[2..]) else if (std.mem.eql(u8, command, "follow")) try follow(init, args[2..]) else if (std.mem.eql(u8, command, "result")) try result(init, args[2..]) else if (std.mem.eql(u8, command, "inspect-action")) try inspectAction(init, args[2..], false) else return usage();
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

// One-shot output writes its selected file; persistent commands lend the same
// bounded worker rendezvous. Neither worker ever borrows the terminal itself.
const Output = struct {
    io: std.Io,
    task: ?*ClientTask = null,

    pub fn feed(self: Output, bytes: []const u8) !void {
        if (self.task) |task| return task.feed(bytes);
        try std.Io.File.stdout().writeStreamingAll(self.io, bytes);
    }

    fn field(self: Output, label: []const u8, value: []const u8) !void {
        try self.feed(label);
        try SessionView.text(self, value);
        try self.feed("\n");
    }

    fn diagnostic(self: Output, comptime format: []const u8, args: anytype) void {
        if (self.task == null) return std.debug.print(format, args);
        // Diagnostic values here are bounded error names, never payloads.
        var storage: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&storage, format, args) catch return;
        self.feed(line) catch {}; // Original command failure remains primary.
    }
};

fn setup(init: std.process.Init, args: []const []const u8) !void {
    return setupUsing(init, args, .{ .io = init.io }) catch |err| {
        if (err == error.UnknownArgument) return usage();
        return err;
    };
}

fn setupUsing(init: std.process.Init, args: []const []const u8, output: Output) !void {
    const home = init.environ_map.get("HOME") orelse {
        output.diagnostic("rui: setup needs an absolute HOME; no preferences saved.\n", .{});
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
        } else return error.UnknownArgument;
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
            output.diagnostic("rui: setup save durability unconfirmed; inspect HOME/.config/rui/preferences before another update. No Session changed.\n", .{});
        } else if (err == error.UnsupportedPreferenceProvider) {
            output.diagnostic("rui: setup supports only --provider codex; no preferences saved.\n", .{});
        } else if (err == error.PreferenceProviderRequired) {
            output.diagnostic("rui: setup needs --provider codex with --model; no preferences saved.\n", .{});
        } else if (err == error.UnsupportedPreferenceModel) {
            output.diagnostic("rui: setup model is not supported by the selected adapter; no preferences saved. Existing Sessions are unchanged.\n", .{});
        } else if (err == error.InvalidPreferenceModel) {
            output.diagnostic("rui: setup model must be 1–256 printable non-space ASCII bytes; no preferences saved.\n", .{});
        } else if (err == error.InvalidPreferenceStore or err == error.FileNotFound) {
            output.diagnostic("rui: setup Store must be an existing private, canonicalizable absolute directory; no alternate Store selected.\n", .{});
        } else output.diagnostic("rui: setup {s}: {s}; inspect HOME/.config/rui/preferences and its private directory before retrying. No alternate Store selected.\n", .{ if (changed) "save failed" else "read failed", @errorName(err) });
        return err;
    };
    var fallback_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const prospective_store: ?[]const u8 = if (values.store.len != 0) values.store.slice() else preferences.defaultStore(home, &fallback_buffer) catch null;
    const available_store: ?platform.Paths = if (prospective_store) |path| platform.resolveClientPaths(init.io, path) catch null else null;
    // Preferences are local hints, not Session settings or Host facts.
    try output.feed(if (changed) "Saved defaults for future Sessions. Active Session unchanged.\n" else "Defaults (read only):\n");
    try output.feed("Store: ");
    try SessionView.text(output, prospective_store orelse "unavailable");
    try output.feed(if (values.store.len != 0) " (saved)\n" else " (HOME fallback)\n");
    if (available_store == null) try output.feed("Store unavailable: destination cannot be selected; no alternate Store selected.\n");
    try output.field("Provider: ", if (values.provider.len != 0) values.provider.slice() else "not selected");
    try output.field("Model: ", if (values.model.len != 0) values.model.slice() else "not selected");
    var line_buffer: [std.Io.Dir.max_path_bytes + 512]u8 = undefined;
    const codex = provider_selection.codex(readiness);
    const local_status = switch (readiness) {
        .configured => "Codex credential: configured locally (remote acceptance not checked).\n",
        .renewal_due => "Codex credential: usable locally; renewal due at dispatch (remote acceptance not checked).\n",
        .missing => "Codex credential: missing.\n",
        .refresh_required => "Codex credential: refresh required; a pending refresh may require login.\n",
        .credential_error => "Codex credential: error reading private Rui credential; inspect it before use.\n",
    };
    try output.feed(local_status);
    const selection: ?provider_selection.Selection = provider_selection.resolve(&.{codex}, null, null, if (values.provider.len != 0) values.provider.slice() else null, if (values.model.len != 0) values.model.slice() else null) catch |err| blk: {
        const advice: []const u8 = switch (err) {
            error.UnsupportedSelectionProvider => "Next Session: saved provider is unsupported; no fallback. Repair with `rui setup --provider codex --model gpt-6-luna`.\n",
            error.UnsupportedSelectionModel => "Next Session: saved model is unsupported; no fallback. Repair with `rui setup --provider codex --model gpt-6-luna`.\n",
        };
        try output.feed(advice);
        break :blk null;
    };
    if (selection) |choice| switch (choice) {
        .chooser => try output.feed("Next Session: choose a supported provider; Codex login: `rui login codex`.\n"),
        .selected => |selected| {
            const note: []const u8 = switch (selected.readiness) {
                .configured => "local credential configured; remote acceptance not checked",
                .renewal_due => "local credential usable; renewal due at dispatch; remote acceptance not checked",
                .missing => "credential missing; run `rui login codex`. No fallback",
                .refresh_required => "credential refresh required; login may be required. No fallback",
                .credential_error => "credential error; inspect private Rui credential or log in. No fallback",
            };
            const line = try std.fmt.bufPrint(&line_buffer, "Next Session: {s} / {s} ({s}).\n", .{ selected.provider, selected.model, note });
            try output.feed(line);
        },
    };
    // Host capabilities are startup facts, not credential or Session state.
    const host_details: []const u8 = if (available_store) |paths| switch (client.hostStatus(init.io, paths.store.slice())) {
        .ready => |current| if (current.capabilities.managed_authentication and current.capabilities.model)
            "Host: managed Codex enabled (credentials checked locally, not by status).\n"
        else
            "Host: ready without managed Codex; use `rui serve --codex` for new managed work.\n",
        .unavailable => "Host: unavailable; setup does not start it.\n",
        .owned_unavailable => "Host: owned but unavailable; inspect before submitting work.\n",
        .incompatible => "Host: incompatible; inspect before submitting work.\n",
        .access_failure => "Host: access failure; inspect Store permissions.\n",
    } else "Host: unavailable; Store unavailable; setup does not start it.\n";
    try output.feed(host_details);
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

fn startHost(init: std.process.Init, selected: []const u8, quiet: bool) !void {
    const io = init.io;
    switch (client.hostStatus(io, selected)) {
        .ready => |ready| {
            if (!quiet) {
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
    // Application policy lives here. The synchronous native launcher borrows
    // these terminated strings and pointer framing through exec/error handoff;
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
                if (!quiet) {
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
    // Guided login already owns SIGINT from the choice through publication.
    var interrupt = if (interactive) null else LoginInterrupt.init();
    defer if (interrupt) |*scope| scope.deinit();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try credentialPath(init, &path_buffer, true);
    if (loginInterrupted()) return error.LoginInterrupted;
    // Preflight needs only a safe snapshot, not the refresh owner's lock or
    // generation. Installation rereads under its exclusive lock after winning.
    {
        var existing: codex_credentials.Record = undefined;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&existing));
        _ = try codex_credentials.readSnapshotInto(path, &existing);
    }
    if (loginInterrupted()) return error.LoginInterrupted;
    try provider.initialize();
    defer provider.deinitialize();
    var tokens = if (interactive)
        try exchange(init.io, struct {
            fn display(code: []const u8) !void {
                const io = std.Io.Threaded.global_single_threaded.io();
                try loginOutput(io, "Open https://auth.openai.com/codex/device and enter code: ");
                try loginOutput(io, code);
                try loginOutput(io, "\n");
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
    try loginOutput(init.io, "Rui: Codex credential installed. Remote model acceptance is not established. Current Session unchanged.\n");
    const added = default_outcome catch |err| {
        try loginOutput(init.io, "Rui: Credential installed, but future defaults were not saved or durability is uncertain (");
        try loginOutput(init.io, @errorName(err));
        return loginOutput(init.io, "). Inspect rui setup; active Session unchanged.\n");
    };
    try loginOutput(init.io, if (added)
        "Rui: No provider default existed; Codex selected for future Sessions; model recommendation remains unpinned.\n"
    else
        "Rui: Existing provider default unchanged.\n");
}

// The auth API takes a context-free display callback. This thread-local loan
// exists only in the joined persistent command worker; one-shot login retains
// its original stdout/diagnostic behavior, and auth never owns terminal output.
threadlocal var login_task: ?*ClientTask = null;

fn loginOutput(io: std.Io, bytes: []const u8) !void {
    if (login_task) |task| return task.feed(bytes);
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
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

test "persistent login local cancellation preserves publication winner" {
    defer login_state.store(.cancellable, .release);
    login_state.store(.cancellable, .release);
    onLoginInterrupt(.INT);
    try std.testing.expect(loginInterrupted());
    try std.testing.expectEqual(.cancelled, login_state.load(.acquire));
    login_state.store(.publishing, .release);
    onLoginInterrupt(.INT);
    try std.testing.expect(!loginInterrupted());
    try std.testing.expectEqual(.publishing, login_state.load(.acquire));
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
    var resume_ref: ?[]const u8 = null;
    var resuming = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store") and store == null) {
            store = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--provider") and explicit_provider == null) {
            explicit_provider = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--model") and explicit_model == null) {
            explicit_model = try takeValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--resume") and !resuming) {
            resuming = true;
        } else if (resuming and std.mem.eql(u8, arg, "--") and resume_ref == null) {
            if (index + 1 < args.len) {
                if (index + 2 != args.len) return usage();
                resume_ref = args[index + 1];
            }
            break;
        } else if (resuming and resume_ref == null and !std.mem.startsWith(u8, arg, "--")) {
            resume_ref = arg;
        } else return usage();
    }
    if (resuming) {
        if (explicit_provider != null or explicit_model != null) return usage();
        return enterSession(init, store, resume_ref);
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
    // No read, lock or validation of unused preferences when all selectors
    // are explicit. Partial selection still needs the saved binding hints.
    var defaults: preferences.Values = if (store != null and explicit_provider != null and explicit_model != null) .{} else preferences.load(home) catch |err| {
        std.debug.print("rui: private setup defaults unreadable ({s}); inspect rui setup before creating a Session.\n", .{@errorName(err)});
        return err;
    };
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var selected_store = store orelse (if (defaults.store.len != 0) defaults.store.slice() else try preferences.defaultStore(home, &fallback));
    try preflightNewSession(init.io, selected_store);
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
        std.debug.print("rui: unsupported prospective provider/model ({s}); inspect rui setup or select codex / gpt-6-luna. No Session created.\n", .{@errorName(err)});
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
        try preflightNewSession(init.io, selected_store);
        const after_choice: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds, std.time.ns_per_s));
        const updated = codex_auth.localStatus(credential, after_choice) catch |err| {
            std.debug.print("rui: credential still unreadable ({s}); inspect rui setup. No Session created.\n", .{@errorName(err)});
            return err;
        };
        selection = provider_selection.resolve(&.{provider_selection.codex(switch (updated) {
            .missing => .missing,
            .configured => .configured,
            .renewal_due => .renewal_due,
            .refresh_required => .refresh_required,
        })}, explicit_provider, explicit_model, if (defaults.provider.len == 0) null else defaults.provider.slice(), if (defaults.model.len == 0) null else defaults.model.slice()) catch |err| {
            std.debug.print("rui: unsupported prospective provider/model after login ({s}); inspect rui setup. No Session created.\n", .{@errorName(err)});
            return err;
        };
        if (selection == .chooser or !selection.selected.readiness.usable()) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No new Session created. Use rui setup or rui login codex when ready; existing work is unchanged.\n");
            return;
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
        std.debug.print("rui: selected Host has no model capability; it was not restarted. Inspect rui host status before creating a Session.\n", .{});
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
        try announceCapture(init.io, saved.key.slice());
        try writeSafeField(init.io, "Rui: New Session intent: ", saved.session.slice());
        break :blk client.sendCaptured(init.io, &captured, null, &reply_buffer) catch |err| {
            std.debug.print("rui: configuration not confirmed ({s}); inspect rui requests and recover only a saved original key. Do not replace uncertain work.\n", .{@errorName(err)});
            return err;
        };
    };
    if (!reply.isAccepted()) {
        try writeMutationReply(init.io, reply, null, true);
        return error.SessionConfigurationRejected;
    }
    try enterSession(init, saved.store.slice(), saved.session.slice());
}

fn preflightNewSession(io: std.Io, destination: []const u8) !void {
    try platform.validateStoreDestination(io, destination);
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
    var accepted: ?client.CapturedIdentity = null;
    return configureUsing(init, args, interactive, .{ .io = init.io }, .{ .io = init.io }, &accepted) catch |err| {
        if (err == error.InvalidArguments) return usage();
        return err;
    };
}

fn configureUsing(init: std.process.Init, args: []const []const u8, interactive: bool, output: Output, caller: client.Requests, accepted_original: *?client.CapturedIdentity) !void {
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
    if (input.session.named.len == 0 or (location.record.len == 0) != !key_seen) return error.InvalidArguments;
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
        break :blk try caller.sendCaptured(&captured, drop_reply, &reply_buffer);
    };
    if (reply.isAccepted()) accepted_original.* = saved;
    const accepted = human and interactive and reply.isAccepted();
    if (!interactive or !accepted) {
        if (output.task != null) try frontendMutation(output, reply) else try writeMutationReply(io, reply, if (human and json) saved.key.slice() else null, human);
    }
    if (human and interactive and accepted) try output.feed("Rui: Configured.\n");
    if (human and !json and !interactive) {
        var line: [protocol.max_store_bytes + protocol.max_session_bytes + 64]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "configuration: {s} in {s}\n", .{ saved.session.slice(), saved.store.slice() }));
        if (reply.isAccepted()) try std.Io.File.stdout().writeStreamingAll(io, "next: rui --resume (same Store and Session)\n");
    }
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
    try writeMutationReply(io, reply, if (human and json) saved.key.slice() else null, human);
    if (human and !json) {
        var line: [protocol.max_store_bytes + protocol.max_session_bytes + 64]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "message: {s} in {s}\n", .{ input.session, input.store }));
        if (reply.isAccepted()) try std.Io.File.stdout().writeStreamingAll(io, "next: rui --resume (same Store and Session)\n");
    }
}

const Attention = struct {
    work: Work,
    message: protocol.Bounded(protocol.max_key_bytes),
};

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

fn waitForSession(init: std.process.Init, store: []const u8, session_ref: []const u8, presentation: Presentation, terminal_only: bool) !?Attention {
    const saved = blk: {
        const report = try inspectWork(init, store, session_ref);
        defer report.file.close(init.io);
        const work = report.current;
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
        if (!terminal_only and work.actionable_count > 1) try showActionable(init.io, &report, presentation == .json);
        break :blk try client.MessageAddress.init(store, session_ref, selected);
    };
    if (try followMessage(init, &saved, presentation, if (terminal_only) .terminal_only else .session_blocked)) |attention|
        return .{ .work = attention, .message = saved.key };
    if (presentation != .json) try showResult(init, &saved, presentation);
    return null;
}

fn showSessionStatus(init: std.process.Init, store: []const u8, session_ref: []const u8, brief: bool) !void {
    const report = try inspectWork(init, store, session_ref);
    defer report.file.close(init.io);
    const work = &report.current;
    if (brief) {
        try writeSafeField(init.io, "Session: ", session_ref);
        try writeSafeField(init.io, "Workspace (Bash cwd): ", work.settings.workspace.slice());
        try writeSafeField(init.io, "Provider: ", @tagName(work.settings.provider.value));
        try writeSafeField(init.io, "Model: ", work.settings.model.slice());
        try std.Io.File.stdout().writeStreamingAll(init.io, "Permission: ");
        try writeSafeText(init.io, @tagName(work.settings.permission_mode.value));
        try std.Io.File.stdout().writeStreamingAll(init.io, if (SessionView.bypassWarning(work.settings.tools.bash, work.settings.permission_mode.value == .bypass)) " (Bash runs without approval)\nRui: Bash commands can run without asking you.\n" else "\n");
        if (work.selected_message != null) try writeSafeField(init.io, "Work: ", @tagName(work.work.status.value));
        if (work.actionable_count != 0) try showActionable(init.io, &report, false);
        return;
    }
    try writeSafeField(init.io, "Session: ", session_ref);
    try writeSafeField(init.io, "Store: ", store);
    try writeSafeField(init.io, "Workspace (Bash cwd): ", work.settings.workspace.slice());
    try writeSafeField(init.io, "Permission: ", @tagName(work.settings.permission_mode.value));
    try writeSafeField(init.io, "Work: ", @tagName(work.work.status.value));
    if (work.selected_message) |selected|
        try writeSafeField(init.io, "Current message: ", selected.slice());
    if (work.actionable_count != 0) try showActionable(init.io, &report, false);
    if (work.first_indeterminate) |action| {
        var buffer: [20]u8 = undefined;
        try writeSafeField(init.io, "Indeterminate Action: ", try std.fmt.bufPrint(&buffer, "{d}", .{action}));
        if (work.indeterminate_count > 1) {
            var line: [160]u8 = undefined;
            try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "Rui: {d} indeterminate Actions in this Turn; inspect-session --profile current lists all IDs.\n", .{work.indeterminate_count}));
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

fn reportAcceptedPresentationFailure(key: []const u8, err: anyerror) void {
    std.debug.print("rui: Message accepted, but later observation or presentation failed ({s}). Use rui result {s} to inspect the same Message; do not resubmit it\n", .{ @errorName(err), key });
}

fn sessionMessage(init: std.process.Init, store: []const u8, session_ref: []const u8, text: []const u8) !?Attention {
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const input = client.MessageInput{
        .store = store,
        .session = session_ref,
        .text_path = "",
        .text = text,
    };
    var captured = try client.captureMessage(init.io, input, .{ .generated = try requestDirectory(init, &directory_buffer) });
    const identity = captured.identity().*;
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = blk: {
        defer captured.close(init.io);
        break :blk try client.sendCaptured(init.io, &captured, null, &reply_buffer);
    };
    const saved = try client.MessageAddress.init(identity.store.slice(), identity.session.slice(), identity.key.slice());
    const accepted = reply.isAccepted();
    if (!accepted) try writeMutationReply(init.io, reply, null, true);
    if (!accepted) return null;
    writeSafeField(init.io, "You: ", text) catch |err| {
        reportAcceptedPresentationFailure(saved.key.slice(), err);
        return null;
    };
    const next = followMessage(init, &saved, .interactive, .follow_attention) catch |err| {
        reportAcceptedPresentationFailure(saved.key.slice(), err);
        if (err == error.CanonicalStoreFailure) return err;
        return null;
    };
    if (next) |attention|
        return .{ .work = attention, .message = saved.key };
    showResult(init, &saved, .interactive) catch |err| {
        reportAcceptedPresentationFailure(saved.key.slice(), err);
        if (err == error.CanonicalStoreFailure) return err;
    };
    return null;
}

fn enterSession(init: std.process.Init, store: ?[]const u8, session_ref: ?[]const u8) !void {
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) return error.InteractiveTerminalRequired;
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, store, &fallback);
    try startHost(init, selected, true);
    const paths = try platform.resolveClientPaths(init.io, selected);
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const scratch = try renderScratch(init);
    defer scratch.close(init.io);
    try SessionFrontend.run(init, paths.store.slice(), session_ref, try requestDirectory(init, &directory), scratch, .{ .parse = interactiveTokens, .run = persistentCommand, .pick = pickSession });
}

fn pickSession(owner: *SessionFrontend) !?protocol.Bounded(protocol.max_session_bytes) {
    var directory = try std.Io.Dir.cwd().openDir(owner.init.io, ".", .{});
    defer directory.close(owner.init.io);
    var workspace: [protocol.max_workspace_bytes]u8 = undefined;
    const length = try directory.realPath(owner.init.io, &workspace);
    const Picker = struct {
        scope: ?[]const u8,
        cursor: client.SessionListCursor = .{},
        page: client.SessionListPage = undefined,
        fn read(client_requests: client.Requests, store: []const u8, scope: ?[]const u8, cursor: client.SessionListCursor, scratch: std.Io.File) !client.SessionListPage {
            scratch.setLength(client_requests.io, 0) catch return error.ResumeListingUnavailable;
            const Capture = struct {
                io: std.Io,
                file: std.Io.File,
                offset: u64 = 0,
                pub fn feed(self: *@This(), bytes: []const u8) !void {
                    try self.file.writePositionalAll(self.io, bytes, self.offset);
                    self.offset += bytes.len;
                }
            };
            var capture: Capture = .{ .io = client_requests.io, .file = scratch };
            var buffer: client.ReplyBuffer = .{};
            const reply = client_requests.listSessions(store, scope, cursor, &capture, &buffer) catch |err| {
                if (err == error.CanonicalStoreFailure) return err;
                return error.ResumeListingUnavailable;
            };
            const decoded = client.SessionListReply.decode(client_requests.io, scratch, scope, cursor, reply) catch return error.ResumeListingUnavailable;
            return switch (decoded) {
                .page => |page| page,
                .failure => |failure| return if (failure.err() == error.CanonicalStoreFailure) error.CanonicalStoreFailure else error.ResumeListingUnavailable,
            };
        }
        fn prepare(frontend: *SessionFrontend, self: *@This()) !bool {
            // Only worker read failures become recoverable listing failures;
            // terminal/choice failures from call must remain fatal unchanged.
            self.page = try frontend.call(read, .{ frontend.store.slice(), self.scope, self.cursor, frontend.scratch });
            const Sink = struct {
                owner: *SessionFrontend,
                pub fn feed(s: @This(), bytes: []const u8) !void {
                    try s.owner.write(bytes);
                }
            };
            const sink: Sink = .{ .owner = frontend };
            try frontend.write(if (self.scope == null) "Rui: Resume — all Workspaces.\n" else "Rui: Resume — current Workspace.\n");
            var prefix: [64]u8 = undefined;
            for (self.page.rows[0..self.page.count], 1..) |*row, number| {
                try frontend.write(try std.fmt.bufPrint(&prefix, "[{d}] Session: ", .{number}));
                try SessionView.text(sink, row.reference.slice());
                try frontend.write("\n    Workspace: ");
                try SessionView.text(sink, row.workspace.slice());
                try frontend.write("\n    Provider/model: ");
                try frontend.write(@tagName(row.provider));
                try frontend.write("/");
                try SessionView.text(sink, row.model.slice());
                try frontend.write(try std.fmt.bufPrint(&prefix, "\n    Permission: {s}\n", .{@tagName(row.permission_mode)}));
                if (SessionView.bypassWarning(row.tools.bash, row.permission_mode == .bypass))
                    try frontend.write("    Rui: WARNING — Bash bypasses approval.\n");
            }
            if (self.page.count == 0) try frontend.write("Rui: No configured Sessions in this scope.\n");
            try frontend.write("Resume: choose 1–8, n next page, a all Workspaces, d defer.\n");
            return true;
        }
    };
    // Retained page: 36,128 bytes on Linux x86-64. The joined worker result
    // adds one page while the prior page survives; decode also has fixed
    // page/reply values, a 4-KiB input window and 12-KiB parser storage.
    // Value copies may be elided: these are storage estimates, not stack or
    // physical peaks. Decoder loans end on return, worker storage after join,
    // and the picker page/filter/choice here on selection or deferral. One
    // active picker per Frontend, with no dormant-Session population multiplier.
    var picker: Picker = .{ .scope = workspace[0..length] };
    var input: [16]u8 = undefined;
    while (try owner.choose(&input, Picker.prepare, .{&picker})) |choice| {
        if (std.mem.eql(u8, choice, "d")) return null;
        if (std.mem.eql(u8, choice, "a")) {
            picker.scope = null;
            picker.cursor = .{};
        } else if (std.mem.eql(u8, choice, "n") and picker.page.next != null) {
            picker.cursor = picker.page.next.?;
        } else if (choice.len == 1 and choice[0] >= '1' and choice[0] <= '8' and choice[0] - '1' < picker.page.count) {
            return picker.page.rows[choice[0] - '1'].reference;
        } else try owner.write("Rui: No selection; choose a listed row, next page, all Workspaces or defer.\n");
    }
    return null;
}

fn persistentCommand(owner: *SessionFrontend, args: []const []const u8) !void {
    const init = owner.init;
    const store = owner.store.slice();
    const session_ref = owner.session.slice();
    const name = args[0];
    if (std.mem.eql(u8, name, "/help") and args.len == 1) {
        try owner.write("Rui: /help /status /wait /requests /result KEY /setup [settings] /login /configure [settings] /resume [REF] /recover [KEY] /discard /approve /history /exit\nCtrl-R recovers original captured intent, never a new Message. Ctrl-G deliberately inspects a pending Action; attention never takes your draft. /discard abandons only a definite rejection. /resume offers bounded selection/deferral without REF, then stages metadata before switching. /exit detaches without cancelling Host work. Prefix // to send a leading slash.\n");
    } else if (std.mem.eql(u8, name, "/status") and args.len == 1) {
        const current = try owner.call(SessionView.inspectCurrent, .{ store, session_ref, owner.scratch });
        try frontendField(owner, "Session: ", current.settings.reference.slice());
        try frontendField(owner, "Store: ", store);
        try frontendField(owner, "Workspace (Bash cwd): ", current.settings.workspace.slice());
        try frontendField(owner, "Provider: ", @tagName(current.settings.provider.value));
        try frontendField(owner, "Model: ", current.settings.model.slice());
        try frontendField(owner, "Permission: ", @tagName(current.settings.permission_mode.value));
        if (SessionView.bypassWarning(current.settings.tools.bash, current.settings.permission_mode.value == .bypass))
            try owner.write("Rui: WARNING — Bash bypasses approval.\n");
        try frontendField(owner, "Work: ", @tagName(current.work.status.value));
        if (current.selected_message) |selected| try frontendField(owner, "Current message: ", selected.slice());
        if (current.pending_messages != 0) {
            var number: [20]u8 = undefined;
            try frontendField(owner, "Pending messages: ", try std.fmt.bufPrint(&number, "{d}", .{current.pending_messages}));
        }
        try owner.stream(streamFrontendAttention, .{ &current, owner.scratch });
        if (current.recent_count != 0) try owner.write("Recent messages (use /result KEY for an answer):\n");
        for (current.recent[0..current.recent_count]) |recent| {
            try owner.write("  ");
            try SessionView.text(FrontendSink{ .owner = owner }, recent.message.slice());
            try frontendField(owner, ": ", recent.outcome.slice());
        }
    } else if (std.mem.eql(u8, name, "/requests") and args.len == 1) {
        try owner.stream(runFrontendRequests, .{ init, store, session_ref });
    } else if (std.mem.eql(u8, name, "/wait") and args.len == 1) {
        const current = try owner.call(SessionView.inspectCurrent, .{ store, session_ref, owner.scratch });
        const key = current.selected_message orelse return owner.write("Rui: No work to wait for.\n");
        const saved = try client.MessageAddress.init(store, session_ref, key.slice());
        if (current.actionable_count != 0) try owner.stream(streamFrontendAttention, .{ &current, owner.scratch });
        while (true) {
            const observed = switch (try owner.call(client.Requests.observeMessage, .{&saved})) {
                .observation => |value| value,
                .failure => |failure| return failure.err(),
            };
            if (observed.state().terminal()) break;
            if (FollowPolicy.session_blocked.attention(&observed) != null) {
                try owner.write("Rui: Permission attention; Ctrl-G inspects an exact Action.\n");
                return;
            }
            try owner.pause(250);
        }
        try frontendResult(owner, &saved);
    } else if (std.mem.eql(u8, name, "/result") and args.len == 2) {
        const saved = try client.MessageAddress.init(store, session_ref, args[1]);
        try frontendResult(owner, &saved);
    } else if (std.mem.eql(u8, name, "/recover") and args.len == 2) {
        var recovered: ?client.MutationReply = null;
        const outcome = owner.stream(runFrontendRecover, .{ init, args[1], &recovered });
        if (recovered) |reply| try owner.settleRecovered(reply);
        try outcome;
    } else if (std.mem.eql(u8, name, "/setup")) {
        try owner.stream(runFrontendSetup, .{ init, args[1..] });
    } else if (std.mem.eql(u8, name, "/login") and args.len == 1) {
        var interrupt = LoginInterrupt.init();
        defer interrupt.deinit();
        std.debug.assert(owner.command_cancel == null);
        owner.command_cancel = struct {
            fn cancel() void {
                onLoginInterrupt(.INT);
            }
        }.cancel;
        defer owner.command_cancel = null;
        var choice_buffer: [16]u8 = undefined;
        const choice = (try owner.choose(&choice_buffer, prepareFrontendLogin, .{})) orelse return;
        if (std.mem.eql(u8, choice, "d")) return owner.write("Rui: Login deferred. Inspect saved work with /status or /result.\n");
        if (!std.mem.eql(u8, choice, "c")) return owner.write("Rui: Choose c or d. No login or preference change.\n");
        try owner.write("Rui: Starting Codex device login. The printed code is for the provider page only; waiting for its answer.\n");
        try owner.stream(runFrontendLogin, .{init});
    } else if (std.mem.eql(u8, name, "/configure")) {
        var flags: [28][]const u8 = undefined;
        if (args.len + 3 > flags.len) return error.TooManyArguments;
        for (args[1..], 0..) |flag, i| if ((std.mem.eql(u8, flag, "--instructions") or std.mem.eql(u8, flag, "--output-schema")) and
            i + 2 < args.len and std.mem.eql(u8, args[i + 2], "-")) return error.InteractiveFileInputRequired;
        flags[0..4].* = .{ "--store", store, "--session", session_ref };
        @memcpy(flags[4..][0 .. args.len - 1], args[1..]);
        var accepted: ?client.CapturedIdentity = null;
        defer if (accepted) |original| {
            if (owner.ticket == null) owner.original = .{ .identity = original, .outcome = .accepted };
        };
        try owner.stream(runFrontendConfigure, .{ init, flags[0 .. args.len + 3], &accepted });
    } else if (std.mem.eql(u8, name, "/approve") and args.len == 1) {
        var action: ?u64 = null;
        var choice_buffer: [64]u8 = undefined;
        const choice = (try owner.choose(&choice_buffer, prepareFrontendApproval, .{&action})) orelse return;
        if (std.mem.eql(u8, choice, "a") or std.mem.eql(u8, choice, "d")) {
            var captured = try owner.call(captureFrontendDecision, .{ store, session_ref, action.?, @as(protocol.PermissionDecision, if (choice[0] == 'a') .allow_once else .deny), owner.directory });
            defer captured.close(init.io);
            var reply: client.ReplyBuffer = .{};
            const attempt: anyerror!client.MutationAnswer = blk: {
                const decision = owner.call(client.Requests.sendCaptured, .{ &captured, @as(?[]const u8, null), &reply }) catch |err| break :blk err;
                break :blk decision.answer;
            };
            const answer = attempt catch |err| {
                if (err == error.CanonicalStoreFailure) return err;
                try owner.write("Rui: Decision unconfirmed; /requests lists the original saved handle. Recover only that record, never replacement intent.\n");
                try frontendField(owner, "Original key: ", captured.saved.key.slice());
                return err;
            };
            switch (answer.result) {
                .accepted => {},
                .rejected => |code| try frontendField(owner, "Rui: Decision rejected: ", code.slice()),
                .conflict => try owner.write("Rui: Decision binding conflict; recover only the original record.\n"),
            }
        } else try owner.write("Rui: No decision sent; deliberate fresh a/d/l + Enter required.\n");
    } else {
        try owner.write("Rui: Unknown command or arguments; /help lists real paths.\n");
    }
}

fn prepareFrontendLogin(owner: *SessionFrontend) !bool {
    try owner.write("Rui: Supported integration: Codex. Login stores Rui-owned credentials; defer leaves this Session and Host work unchanged.\nProvider: [c] Codex login, [d] defer > ");
    return true;
}

fn streamFrontendAttention(caller: client.Requests, current: *const client.Current, scratch: std.Io.File, task: *ClientTask) !void {
    const Sink = struct {
        output: Output,
        pub fn visit(self: @This(), row: client.Current.Attention) !void {
            const action: u64 = switch (row) {
                .actionable => |value| value.action.value,
                .resolved => |value| if (std.mem.eql(u8, value.code.slice(), "indeterminate")) value.action.value else return,
                else => return,
            };
            var number: [20]u8 = undefined;
            try self.output.field(if (row == .actionable) "Pending Action: " else "Indeterminate Action (may have run): ", try std.fmt.bufPrint(&number, "{d}", .{action}));
        }
    };
    try current.traverse(caller.io, scratch, Sink{ .output = .{ .io = caller.io, .task = task } });
    if (current.indeterminate_count != 0) try task.feed("Rui: The command may have run; Rui did not replay it. Check its effects before deciding what to do next.\n");
}

fn runFrontendSetup(_: client.Requests, init: std.process.Init, args: []const []const u8, task: *ClientTask) !void {
    setupUsing(init, args, .{ .io = init.io, .task = task }) catch |err| {
        if (err == error.CanonicalStoreFailure or err == error.Cancelled) return err;
        try task.feed("Rui: Setup failed; active Session unchanged.\n");
    };
}

fn runFrontendRequests(_: client.Requests, init: std.process.Init, store: []const u8, session_ref: []const u8, task: *ClientTask) !void {
    sessionRequestsUsing(init, store, session_ref, .{ .io = init.io, .task = task }) catch |err| {
        if (err == error.CanonicalStoreFailure or err == error.Cancelled) return err;
        try task.feed("Rui: Local recovery records unavailable; no work changed.\n");
    };
}

fn runFrontendConfigure(caller: client.Requests, init: std.process.Init, args: []const []const u8, accepted: *?client.CapturedIdentity, task: *ClientTask) !void {
    const output: Output = .{ .io = init.io, .task = task };
    configureUsing(init, args, true, output, caller, accepted) catch |err| {
        if (err == error.CanonicalStoreFailure or err == error.Cancelled) return err;
        if (accepted.* != null) {
            try output.feed("Rui: Original configuration accepted; receipt failed. Inspect the same saved request, never replace intent.\n");
            return;
        }
        try output.feed("Rui: Configuration not confirmed; /requests lists the original saved handle. Recover only that record, never replacement intent.\n");
        try output.field("Invocation error: ", @errorName(err));
    };
}

fn runFrontendRecover(caller: client.Requests, init: std.process.Init, handle: []const u8, recovered: *?client.MutationReply, task: *ClientTask) !void {
    const output: Output = .{ .io = init.io, .task = task };
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &directory_buffer);
    recoverFrontendRecord(caller, directory, handle, recovered, output) catch |err| {
        if (err == error.CanonicalStoreFailure or err == error.Cancelled) return err;
        try output.field("Original key: ", handle);
        try output.field("Rui: Recovery not confirmed: ", @errorName(err));
    };
}

fn recoverFrontendRecord(caller: client.Requests, directory: []const u8, handle: []const u8, recovered: *?client.MutationReply, output: Output) !void {
    var captured = try client.openCaptured(caller.io, directory, handle);
    defer captured.close(caller.io);
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try caller.sendCaptured(&captured, null, &reply_buffer);
    recovered.* = reply;
    try frontendMutation(output, reply);
}

fn frontendMutation(output: Output, reply: client.MutationReply) !void {
    try output.field("Store: ", reply.context.store.slice());
    try output.field("Session: ", reply.context.session.slice());
    try output.field("Original key: ", reply.context.key.slice());
    const answer = reply.answer catch |err| {
        try output.field("Rui: Outcome unconfirmed: ", @errorName(err));
        return err;
    };
    switch (answer.result) {
        .accepted => try output.feed("Rui: Original request accepted.\n"),
        .rejected => |code| try output.field("Rui: Original request rejected: ", code.slice()),
        .conflict => try output.feed("Rui: Original binding conflict; nothing replaced.\n"),
    }
}

fn runFrontendLogin(_: client.Requests, init: std.process.Init, task: *ClientTask) !void {
    std.debug.assert(login_task == null);
    login_task = task;
    defer login_task = null;
    login(init, &.{"codex"}, true, codex_auth.login) catch |err| {
        // Network denial and local publication uncertainty are caller data,
        // not terminal failures. A failed output rendezvous still propagates.
        try task.feed(switch (err) {
            error.LoginInterrupted => "Rui: Login interrupted. Check credentials and future defaults before retrying.\n",
            error.LoginDenied => "Rui: Login denied. No provider preference changed; retry /login if intended.\n",
            error.LoginExpired => "Rui: Login expired. No provider preference changed; retry /login for a fresh code.\n",
            else => "Rui: Login failed or credential save unconfirmed. Inspect rui setup before retrying; no Session binding changed.\n",
        });
    };
}

fn prepareFrontendApproval(owner: *SessionFrontend, action: *?u64) !bool {
    const store = owner.store.slice();
    const session_ref = owner.session.slice();
    const current = try owner.call(SessionView.inspectCurrent, .{ store, session_ref, owner.scratch });
    action.* = current.first_action;
    const target = action.* orelse {
        try owner.write("Rui: No currently actionable permission.\n");
        return false;
    };
    var number: [20]u8 = undefined;
    try frontendField(owner, "Action ", try std.fmt.bufPrint(&number, "{d}", .{target}));
    try owner.write("Bash arguments: \"");
    var reply: client.ReplyBuffer = .{};
    const arguments = try owner.stream(streamFrontendAction, .{ store, session_ref, target, &reply });
    if (arguments == .command) return error.ActionReadFailed;
    try owner.write("\"\nAllow once, deny, or later? [a/d/l] ");
    return true;
}

fn streamFrontendAction(caller: client.Requests, store: []const u8, session_ref: []const u8, action: u64, reply: *client.ReplyBuffer, task: *@import("ClientTask.zig")) !client.ResultReply {
    var escaped: SessionView.Escaped(@TypeOf(task)) = .{ .sink = task, .text = .{ .mode = .line } };
    const arguments = try caller.readActionArguments(store, session_ref, action, &escaped, reply);
    try escaped.finish();
    return arguments;
}

fn captureFrontendDecision(caller: client.Requests, store: []const u8, session_ref: []const u8, action: u64, decision: protocol.PermissionDecision, directory: []const u8) !client.CapturedRecord {
    return client.capturePermissionDecision(caller.io, .{ .store = store, .session = session_ref, .action_id = action, .decision = decision }, .{ .generated = directory });
}

const FrontendSink = struct {
    owner: *SessionFrontend,
    pub fn feed(self: @This(), bytes: []const u8) !void {
        try self.owner.write(bytes);
    }
};

fn frontendField(owner: *SessionFrontend, label: []const u8, value: []const u8) !void {
    try owner.write(label);
    try SessionView.text(FrontendSink{ .owner = owner }, value);
    try owner.write("\n");
}

fn frontendResult(owner: *SessionFrontend, saved: *const client.MessageAddress) !void {
    const observed = switch (try owner.call(client.Requests.observeMessage, .{saved})) {
        .observation => |value| value,
        .failure => |failure| return failure.err(),
    };
    const state = observed.state();
    if (state != .completed) {
        try frontendField(owner, "Rui: Message outcome: ", @tagName(state));
        return;
    }
    try owner.write("\n--- Assistant ---\n");
    var reply: client.ReplyBuffer = .{};
    const answer = try owner.stream(streamFrontendResult, .{ saved.store.slice(), saved.key.slice(), &reply });
    if (answer == .failure) return answer.failure.err();
    try owner.write("\n");
}

fn streamFrontendResult(caller: client.Requests, store: []const u8, key: []const u8, reply: *client.ReplyBuffer, task: *@import("ClientTask.zig")) !client.ResultReadReply {
    var rendered: SessionView.Answer(@TypeOf(task)) = undefined;
    rendered.init(task);
    const answer = try caller.readResultStream(store, key, &rendered, reply);
    if (answer == .failure) return answer;
    try rendered.finish();
    return answer;
}

// Retained for the build-only single-prompt fixture. Production dispatch never
// calls this; it is not another public entry or recovery authority.
pub fn enterSessionLegacy(init: std.process.Init, args: []const []const u8) !void {
    var store: ?[]const u8 = null;
    var session_ref: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--session")) session_ref = try takeValue(args, &index) else return error.UnknownArgument;
    }
    const reference = session_ref orelse return usage();
    if (std.c.isatty(0) != 1 or std.c.isatty(1) != 1) {
        std.debug.print("rui session needs terminal input and output; use one-shot commands for scripts\n", .{});
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
    showSessionStatus(init, destination, reference, true) catch |err| {
        if (err == error.SessionNotConfigured) std.debug.print("rui: configure this Session before entering it\n", .{});
        return err;
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Type a message or /help. /exit detaches without stopping work.\n");
    var input_buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const line = (TerminalEditor.readLine(init.io, &input_buffer, "rui> ", true) catch |err| {
            if (err == error.InteractiveInterrupted) break;
            if (err == error.StreamTooLong) {
                std.debug.print("rui: input too long; nothing sent. Use rui message --text FILE for longer input.\n", .{});
            } else if (err == error.UncertainTerminalCursor) {
                std.debug.print("rui: cannot place the terminal cursor reliably; nothing sent. Use rui message --text FILE for this input.\n", .{});
            } else if (err == error.InvalidTerminalInput) {
                std.debug.print("rui: input rejected ({s}); nothing sent.\n", .{@errorName(err)});
            } else return err;
            continue;
        }) orelse break;
        const text = line;
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "/exit")) break;
        if (std.mem.eql(u8, text, "/help")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: /help  /status  /wait  /requests  /result KEY  /setup [--store PATH] [--provider codex] [--model gpt-6-luna | --clear-model]  /login  /configure [settings]  /exit\n/help shows these commands; /status inspects this Session; /wait follows selected work; /requests lists local recovery handles; /result KEY reads a saved answer. /setup reads local credential/Host status and saves defaults for future Sessions only; /login chooses Codex login or defers; /configure changes this Session; /exit detaches without stopping work.\nMessages are submitted as written. To send a leading /, prefix it with //; use the one-shot --text FILE for longer input.\n");
            continue;
        }
        if (std.mem.eql(u8, text, "/login")) {
            guideProviderLogin(init) catch |err| {
                if (err != error.InteractiveInterrupted) return err;
                try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Login deferred. Inspect saved work with /status or /result.\n");
            };
            continue;
        }
        const attention: ?Attention = if (std.mem.eql(u8, text, "/setup") or std.mem.startsWith(u8, text, "/setup ")) blk: {
            var setup_args: [6][]const u8 = undefined;
            const count = interactiveTokens(input_buffer["/setup".len..text.len], &setup_args) catch {
                try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: /setup [--store PATH] [--provider codex] [--model gpt-6-luna | --clear-model]; no changes saved.\n");
                break :blk null;
            };
            setup(init, setup_args[0..count]) catch |err| std.debug.print("rui: /setup: {s}; active Session unchanged\n", .{@errorName(err)});
            break :blk null;
        } else if (std.mem.eql(u8, text, "/status")) blk: {
            showSessionStatus(init, destination, reference, false) catch |err| {
                if (err == error.CanonicalStoreFailure) return err;
                std.debug.print("rui: status: {s}\n", .{@errorName(err)});
            };
            break :blk null;
        } else if (std.mem.eql(u8, text, "/requests")) blk: {
            sessionRequests(init, destination, reference) catch |err| std.debug.print("rui: requests: {s}\n", .{@errorName(err)});
            break :blk null;
        } else if (std.mem.eql(u8, text, "/wait"))
            waitForSession(init, destination, reference, .interactive, false) catch |err| blk: {
                if (err == error.CanonicalStoreFailure) return err;
                std.debug.print("rui: wait: {s}\n", .{@errorName(err)});
                break :blk null;
            }
        else if (std.mem.startsWith(u8, text, "/result ")) blk: {
            const saved = client.MessageAddress.init(destination, reference, std.mem.trim(u8, text[8..], " ")) catch |err| {
                std.debug.print("rui: result key: {s}\n", .{@errorName(err)});
                break :blk null;
            };
            showResult(init, &saved, .interactive) catch |err| {
                if (err == error.CanonicalStoreFailure) return err;
                std.debug.print("rui: result: {s}\n", .{@errorName(err)});
            };
            break :blk null;
        } else if (std.mem.eql(u8, text, "/configure") or std.mem.startsWith(u8, text, "/configure ")) blk: {
            var config_args: [24][]const u8 = undefined;
            config_args[0..4].* = .{ "--store", destination, "--session", reference };
            var count: usize = 4;
            var arguments: [20][]const u8 = undefined;
            const argument_count = interactiveTokens(input_buffer["/configure".len..text.len], &arguments) catch {
                try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Usage: /configure --model MODEL [--tools bash] [--permission-mode ask|bypass] (settings for this Session only)\n");
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
                        try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Use a file for /configure content; terminal stdin belongs to this Session.\n");
                        break :blk null;
                    }
                    config_args[count] = setting;
                    count += 1;
                }
            }
            if (valid and count > 4) {
                configure(init, config_args[0..count], true) catch |err| {
                    std.debug.print("rui: configure: {s}; check saved requests before retrying\n", .{@errorName(err)});
                    if (err == error.CanonicalStoreFailure) return err;
                };
            } else try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Usage: /configure --model MODEL [--tools bash] [--permission-mode ask|bypass] (settings for this Session only)\n");
            break :blk null;
        } else if (std.mem.startsWith(u8, text, "/") and !std.mem.startsWith(u8, text, "//")) blk: {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Unknown command. Type /help.\n");
            break :blk null;
        } else blk: {
            const message_text = if (std.mem.startsWith(u8, text, "//")) text[1..] else text;
            break :blk sessionMessage(init, destination, reference, message_text) catch |err| {
                if (err == error.CanonicalStoreFailure) return err;
                std.debug.print("rui: message: {s}; admission may be uncertain. Check /requests and recover the original handle before sending new work\n", .{@errorName(err)});
                break :blk null;
            };
        };
        if (attention) |action| interactiveAction(init, destination, reference, action) catch |err| {
            if (err == error.InteractiveInterrupted) break;
            if (err == error.TerminalRestoreFailed or err == error.TerminalCleanupFailed or err == error.TerminalFlushFailed or err == error.IncompleteTerminalInput) return err;
            std.debug.print("rui: Action observation or decision failed: {s}; check /requests and /status\n", .{@errorName(err)});
            if (err == error.CanonicalStoreFailure) return err;
        };
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Detached. Host work continues.\n");
}

fn interactiveAction(init: std.process.Init, store: []const u8, session_ref: []const u8, initial: Attention) !void {
    const saved = try client.MessageAddress.init(store, session_ref, initial.message.slice());
    var pending: ?Work = initial.work;
    while (pending) |work| {
        if (work.action.len == 0) return;
        const id = try std.fmt.parseInt(u64, work.action.slice(), 10);
        try inspectAction(init, &.{ "--store", store, "--session", session_ref, "--action", work.action.slice() }, true);
        var choice_buffer: [64]u8 = undefined;
        const choice = (try TerminalEditor.readLine(init.io, &choice_buffer, "Allow once, deny, or later? [a/d/l] ", false)) orelse return;
        if (std.mem.eql(u8, choice, "l")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: No decision sent; use /wait to revisit.\n");
            return;
        }
        if (!std.mem.eql(u8, choice, "a") and !std.mem.eql(u8, choice, "d")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Choose a, d, or l. No decision sent.\n");
            continue;
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
            break :blk try client.sendCaptured(init.io, &captured, null, &reply_buffer);
        };
        const accepted = reply.isAccepted();
        if (!accepted) try writeMutationReply(init.io, reply, null, true);
        if (!accepted) return;
        pending = try followMessage(init, &saved, .interactive, .follow_attention);
        if (pending == null) try showResult(init, &saved, .interactive);
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
    return sessionRequestsUsing(init, store, session_ref, .{ .io = init.io });
}

fn sessionRequestsUsing(init: std.process.Init, store: []const u8, session_ref: []const u8, output: Output) !void {
    const canonical = try platform.resolveClientPaths(init.io, store);
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &path);
    try output.feed("Rui: Local recovery handles (not Host work status):\n");
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
        try output.feed(try std.fmt.bufPrint(&line, "  {s} ({s})\n", .{ handle, saved.kind.slice() }));
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
    try writeMutationReply(io, reply, null, false);
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
    try writeMutationReply(io, reply, null, false);
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
    try writeMutationReply(io, reply, if (human and json) saved.key.slice() else null, human);
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
    try writeMutationReply(io, reply, null, false);
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
        .failure => |failure| {
            try writeReadFailure(io, failure, target);
            return failure.err();
        },
    }
}

/// Complete raw observation, not terminal presentation or an atomic file save.
/// A failed delivery can leave a prefix on stdout; the exit status remains red.
fn exportConversation(init: std.process.Init, args: []const []const u8) !void {
    var store: ?[]const u8 = null;
    var session: ?[]const u8 = null;
    var session_buffer: [protocol.max_session_bytes]u8 = undefined;
    var position: ?u64 = null;
    var ordinal: ?u64 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--session-hex") or std.mem.eql(u8, arg, "--session")) {
            if (session != null) return error.InvalidArguments;
            const value = try takeValue(args, &index);
            session = if (std.mem.eql(u8, arg, "--session-hex")) try std.fmt.hexToBytes(&session_buffer, value) else value;
        } else if (std.mem.eql(u8, arg, "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--position")) position = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else if (std.mem.eql(u8, arg, "--ordinal")) ordinal = try std.fmt.parseInt(u64, try takeValue(args, &index), 10) else return error.UnknownArgument;
    }
    var selection: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const caller: client.Requests = .{ .io = init.io };
    if (try caller.readConversationContent(try selectedStore(init, store, &selection), session orelse return usage(), position orelse return usage(), ordinal orelse return usage(), null, std.Io.File.stdout())) |failure|
        return failure.err();
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

fn writeMutationReply(io: std.Io, reply: client.MutationReply, json_handle: ?[]const u8, human: bool) !void {
    if (json_handle != null or !human) {
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var output = std.Io.File.stdout().writerStreaming(io, &buffer);
        const writer = &output.interface;
        if (json_handle) |handle| {
            const is_answer = if (reply.answer) |_| true else |_| false;
            try writer.print("{{\"event\":\"{s}\",\"request\":", .{if (is_answer) "admission" else "invocation_error"});
            try std.json.Stringify.value(handle, .{}, writer);
            try writer.print(",\"{s}\":", .{if (is_answer) "admission" else "error"});
        }
        try writeMutationJson(writer, reply);
        if (json_handle != null) try writer.writeByte('}');
        try writer.writeByte('\n');
        try output.flush();
        _ = try reply.answer;
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
    return client.inspectCaptured(init.io, try requestDirectory(init, &directory_buffer), handle);
}

fn sessionPage(init: std.process.Init, store: []const u8, workspace: ?[]const u8, cursor: client.SessionListCursor, presentation: Presentation) !struct { count: usize, next: ?client.SessionListCursor } {
    const file = try renderScratch(init);
    defer file.close(init.io);
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.listSessions(init.io, store, workspace, cursor, file, &buffer);
    const decoded = try client.SessionListReply.decode(init.io, file, workspace, cursor, reply);
    const page = switch (decoded) {
        .page => |*page| page,
        .failure => |failure| {
            var bytes: [256]u8 = undefined;
            var writer = std.Io.File.stderr().writerStreaming(init.io, &bytes);
            try std.json.Stringify.value(.{ .status = failure.status, .type = failure.diagnostic.type.slice(), .code = failure.diagnostic.code.slice() }, .{}, &writer.interface);
            try writer.interface.writeAll("\n");
            try writer.interface.flush();
            return failure.err();
        },
    };
    if (presentation == .json) {
        var bytes: [protocol.content_window_bytes]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(init.io, &bytes);
        try page.writeJson(&writer.interface);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();
    } else if (presentation == .human) {
        for (page.rows[0..page.count]) |*row| {
            try writeSafeField(init.io, "Session: ", row.reference.slice());
            try writeSafeField(init.io, "  Workspace: ", row.workspace.slice());
            try writeSafeField(init.io, "  Provider: ", @tagName(row.provider));
            try writeSafeField(init.io, "  Model: ", row.model.slice());
            try std.Io.File.stdout().writeStreamingAll(init.io, if (row.tools.bash and row.tools.edit) "  Tools: Bash, Edit\n" else if (row.tools.bash) "  Tools: Bash\n" else if (row.tools.edit) "  Tools: Edit\n" else "  Tools: none\n");
            try writeSafeField(init.io, "  Permission: ", @tagName(row.permission_mode));
            if (SessionView.bypassWarning(row.tools.bash, row.permission_mode == .bypass)) try std.Io.File.stdout().writeStreamingAll(init.io, "  Rui: Bash runs without approval.\n");
        }
    }
    return .{ .count = page.count, .next = page.next };
}

fn sessions(init: std.process.Init, args: []const []const u8) !void {
    var explicit: ?[]const u8 = null;
    var all = false;
    var json = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store") and explicit == null) explicit = try takeValue(args, &index) else if (std.mem.eql(u8, args[index], "--all") and !all) all = true else if (std.mem.eql(u8, args[index], "--json") and !json) json = true else return usage();
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
    try writeMutationReply(init.io, reply, null, !json);
}

fn result(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    if (!saved.kind.eql("message")) return error.NotMessageRequest;
    const address = try client.MessageAddress.init(saved.store.slice(), saved.session.slice(), saved.key.slice());
    try showResult(init, &address, if (json) .json else .human);
}

fn showResult(init: std.process.Init, saved: *const client.MessageAddress, presentation: Presentation) !void {
    const json = presentation == .json;
    const observed = try checkedObservation(init.io, try client.observeMessage(init.io, saved), saved.key.slice());
    const state = observed.state();
    if (presentation == .interactive and state != .completed) {
        const notice = switch (state) {
            .queued => "Rui: This saved Message has no answer yet; it remains queued.\n",
            .processing => "Rui: This saved Message is being processed; observe the same request rather than sending it again.\n",
            .rejected => "Rui: This submission was rejected; no work was admitted.\n",
            .cancelled => "Rui: This saved Message was cancelled; no answer was produced.\n",
            .failed => "Rui: This saved Message failed; no answer was produced.\n",
            .completed => unreachable,
        };
        try std.Io.File.stdout().writeStreamingAll(init.io, notice);
        if (observed.failureCode()) |code| {
            try writeSafeField(init.io, "Rui: Code: ", code);
            if (std.mem.eql(u8, code, "indeterminate"))
                try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: The command may have run. Rui did not rerun it; inspect saved work before choosing a next action.\n");
        }
    } else if (!json and presentation != .interactive) {
        var line: [256]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "admitted: {s}\nresult: {s}\n", .{ @tagName(observed.status), @tagName(state) }));
        if (observed.failureCode()) |code|
            try writeSafeField(init.io, "code: ", code);
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
        if (answer == .failure) {
            try writeReadFailure(init.io, answer.failure, saved.key.slice());
            return answer.failure.err();
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"observation\":");
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try observed.writeJson(&writer.interface);
        try writer.flush();
        try std.Io.File.stdout().writeStreamingAll(init.io, ",\"answer\":\"");
        try writeJsonFileAt(init.io, file, 0, answer.answer.bytes, false);
        return std.Io.File.stdout().writeStreamingAll(init.io, "\"}\n");
    }
    if (presentation == .interactive) try std.Io.File.stdout().writeStreamingAll(init.io, "Assistant: ");
    var read_buffer: client.ReplyBuffer = .{};
    const answer = try client.readResult(init.io, saved.store.slice(), saved.key.slice(), std.Io.File.stdout(), &read_buffer);
    switch (answer) {
        .answer => {},
        .failure => |failure| {
            try writeReadFailure(init.io, failure, saved.key.slice());
            return failure.err();
        },
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

const Work = struct {
    status: protocol.Bounded(32) = .{},
    action: protocol.Bounded(32) = .{},
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

const SessionObservation = struct {
    current: client.Current,
    // The complete Current capture remains owned until all its permissions
    // have been displayed; no per-Action resident list is needed.
    file: std.Io.File,
};

fn inspectWork(init: std.process.Init, store: []const u8, session_ref: []const u8) !SessionObservation {
    const file = try renderScratch(init);
    errdefer file.close(init.io);
    var response: client.ReplyBuffer = .{};
    const reply = try client.inspectSession(init.io, store, session_ref, .current, file, &response);
    switch (try client.CurrentReply.decode(init.io, file, session_ref, reply)) {
        .current => |current| return .{ .current = current, .file = file },
        .unconfigured => return error.SessionNotConfigured,
        .failure => |failure| {
            try writeCommandReply(init.io, reply.command);
            return failure.err();
        },
    }
}

fn showActionable(io: std.Io, report: *const SessionObservation, json: bool) !void {
    const Sink = struct {
        io: std.Io,
        json: bool,
        first: bool = true,
        pub fn visit(self: *@This(), row: client.Current.Attention) !void {
            if (row == .actionable) {
                var buffer: [20]u8 = undefined;
                const action = try std.fmt.bufPrint(&buffer, "{d}", .{row.actionable.action.value});
                if (self.json) {
                    if (!self.first) try std.Io.File.stdout().writeStreamingAll(self.io, ",");
                    try std.Io.File.stdout().writeStreamingAll(self.io, "\"");
                    try std.Io.File.stdout().writeStreamingAll(self.io, action);
                    try std.Io.File.stdout().writeStreamingAll(self.io, "\"");
                } else try writeSafeField(self.io, "Action requiring attention: ", action);
                self.first = false;
            }
        }
    };
    var sink: Sink = .{ .io = io, .json = json };
    if (json) try std.Io.File.stdout().writeStreamingAll(io, "{\"event\":\"actionable_permissions\",\"actions\":[");
    try report.current.traverse(io, report.file, &sink);
    if (json) try std.Io.File.stdout().writeStreamingAll(io, "]}\n");
}

fn writeFollowOutcome(init: std.process.Init, observation: *const client.CommandObservation, presentation: Presentation) !void {
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
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "return: outcome\nadmitted: {s}\nstatus: {s}\n", .{ @tagName(observation.status), @tagName(observation.state()) }));
    }
}

fn follow(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    if (!saved.kind.eql("message")) return error.NotMessageRequest;
    const address = try client.MessageAddress.init(saved.store.slice(), saved.session.slice(), saved.key.slice());
    _ = try followMessage(init, &address, if (json) .json else .human, .follow_attention);
}

const FollowPolicy = enum {
    follow_attention,
    session_blocked,
    terminal_only,

    fn attention(self: FollowPolicy, observation: *const client.CommandObservation) ?client.CommandObservation.Progress {
        if (observation.state().terminal()) return null;
        const progress = observation.progress orelse return null;
        if (progress.action == null) return null;
        return switch (self) {
            .follow_attention => progress,
            .session_blocked => if (progress.status == .waiting_for_permission) progress else null,
            .terminal_only => null,
        };
    }
};

fn progressNotice(queue: client.CommandObservation.State, status: @FieldType(client.CommandObservation.Progress, "status"), has_action: bool) ![]const u8 {
    if (queue == .queued) {
        if (status == .waiting_for_permission) return "Rui: Your message is queued behind work needing a decision.\n";
        if (status == .in_flight) return if (has_action)
            "Rui: Your message is queued behind work in flight; an Action also needs a decision.\n"
        else
            "Rui: Your message is queued behind work in flight.\n";
        if (status == .runnable) return "Rui: Your message is queued and ready for execution.\n";
    } else if (queue == .processing) {
        if (status == .waiting_for_permission) return "Rui: Work needs your decision.\n";
        if (status == .in_flight) return if (has_action)
            "Rui: An Action needs your choice while other work remains in flight.\n"
        else
            "Rui: Work is in flight.\n";
        if (status == .runnable) return "Rui: Work is ready to continue.\n";
    }
    return error.InvalidObservation;
}

// null is the selected message's terminal observation; an Action is only a hint
// to inspect and decide against the Host's exact current target.
fn followMessage(init: std.process.Init, saved: *const client.MessageAddress, presentation: Presentation, policy: FollowPolicy) !?Work {
    var last_queue: ?client.CommandObservation.State = null;
    var last_progress: ?@FieldType(client.CommandObservation.Progress, "status") = null;
    var last_action = false;
    var unchanged_polls: u8 = 0;
    while (true) {
        const observed = try checkedObservation(init.io, try client.observeMessage(init.io, saved), saved.key.slice());
        if (observed.state().terminal()) {
            try writeFollowOutcome(init, &observed, presentation);
            return null;
        }
        // Test-only pause after capturing the Message's coherent observation.
        try testGate(init.io, "RUI_TEST_FOLLOW_GATE");
        // Notices describe status and Action presence, not which Action. A
        // replacement ID still targets attention but does not reset reminders.
        const progress_status = if (observed.progress) |progress| progress.status else null;
        const has_action = if (observed.progress) |progress| progress.action != null else false;
        if (presentation == .interactive and (last_queue == null or last_queue.? != observed.state() or last_progress != progress_status or last_action != has_action)) {
            if (observed.progress) |progress|
                try std.Io.File.stdout().writeStreamingAll(init.io, try progressNotice(observed.state(), progress.status, progress.action != null));
            last_queue = observed.state();
            last_progress = progress_status;
            last_action = has_action;
            unchanged_polls = 0;
        } else if (presentation == .interactive and observed.progress != null and observed.progress.?.status == .in_flight) {
            if (unchanged_polls == 99) {
                try std.Io.File.stdout().writeStreamingAll(init.io, if (observed.state() == .queued) "Rui: Still queued behind work in flight.\n" else "Rui: Work is still in flight.\n");
                unchanged_polls = 0;
            } else unchanged_polls += 1;
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
    const file = try renderScratch(init);
    defer file.close(io);
    var buffer: client.ReplyBuffer = .{};
    var call_bytes: u64 = 0;
    if (!interactive) {
        const call = try client.readActionCallId(io, selected, reference, target, file, &buffer);
        if (call == .command) {
            try writeCommandReply(io, call.command);
            return error.ActionReadFailed;
        }
        call_bytes = call.answer.bytes;
    }
    const arguments = try client.readActionArguments(io, selected, reference, target, file, &buffer);
    if (arguments == .command) {
        try writeCommandReply(io, arguments.command);
        return error.ActionReadFailed;
    }
    var line: [96]u8 = undefined;
    if (json) {
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"action\":\"{d}\",\"call_id\":\"", .{target}));
        try writeJsonFileAt(io, file, 0, call_bytes, false);
        try std.Io.File.stdout().writeStreamingAll(io, "\",\"arguments\":\"");
        try writeJsonFileAt(io, file, call_bytes, arguments.answer.bytes, false);
        return std.Io.File.stdout().writeStreamingAll(io, "\"}\n");
    }
    // Quote provider-controlled fields so control and bidi bytes cannot alter the
    // proposal visible next to the human approval prompt.
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "Action {d}\n", .{target}));
    if (!interactive) {
        try std.Io.File.stdout().writeStreamingAll(io, "call ID: \"");
        try writeJsonFileAt(io, file, 0, call_bytes, true);
        try std.Io.File.stdout().writeStreamingAll(io, "\"\n");
    }
    try std.Io.File.stdout().writeStreamingAll(io, "Bash arguments: \"");
    try writeJsonFileAt(io, file, call_bytes, arguments.answer.bytes, true);
    try std.Io.File.stdout().writeStreamingAll(io, "\"\n");
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

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage:
        \\  rui [--store PATH] [--provider codex] [--model gpt-6-luna]
        \\    On a terminal, attach/start a Host and create a fresh Session in the current Workspace.
        \\    Non-TTY calls must use explicit one-shot commands; use rui requests/recover after a lost reply.
        \\  rui login codex
        \\  rui host status [--store PATH]
        \\    Read the selected Store's protected Host readiness, capacity and capabilities without starting it.
        \\  rui host start [--store PATH]
        \\    Attach or detach a capacity-8 managed Host; existing Host settings win.
        \\  rui host stop [--store PATH] [--instance HEX]
        \\    Stop the observed Host, affecting all Store work; retry a lost reply only with the same instance.
        \\  rui setup [--store PATH] [--provider codex] [--model gpt-6-luna | --clear-model]
        \\    Inspect prospective selection, local credential and Host status; save defaults only with flags.
        \\    --clear-model removes only the saved model; prospective recommendation is unchanged.
        \\    Selected Store must exist and pass canonical/private checks.
        \\  rui sessions [--store PATH] [--all] [--json]
        \\    List configured Sessions here or in all Workspaces; --json emits one bounded page per line.
        \\  rui serve [--store PATH] [--active-capacity N] [--codex | --provider-endpoint URL] [--provider-ca-file PATH] [--fault NAME]
        \\  rui configure [--store PATH] --session REF [settings] [--json]
        \\    First configuration requires --workspace PATH --provider codex --model MODEL.
        \\  rui --resume [--store PATH] [--] [REF]
        \\    Resume exact REF or choose a bounded page; -- permits option-looking references.
        \\    All new commands use --store, then saved Store, then HOME/.local/share/rui/store.
        \\    Type /help for in-Session commands (including /setup).
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
        \\  rui export-conversation --store PATH --session REF --position ID --ordinal ID > NEW_FILE
        \\    --session-hex HEX encodes an exact reference that Bash argv cannot represent; replaces --session.
        \\    Complete raw bytes only; failed delivery may leave an incomplete file. Choose a new destination.
        \\  rui read-action-call-id --store PATH --session REF --action ID
        \\  rui read-action-arguments --store PATH --session REF --action ID
        \\  rui inspect-session --store PATH --session REF [--profile current|full]
        \\
    , .{});
    return error.InvalidArguments;
}

test "interactive progress distinguishes queued dependency from selected work" {
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work in flight.\n", try progressNotice(.queued, .in_flight, false));
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work in flight; an Action also needs a decision.\n", try progressNotice(.queued, .in_flight, true));
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work needing a decision.\n", try progressNotice(.queued, .waiting_for_permission, true));
    try std.testing.expectEqualStrings("Rui: Work is in flight.\n", try progressNotice(.processing, .in_flight, false));
    try std.testing.expectEqualStrings("Rui: An Action needs your choice while other work remains in flight.\n", try progressNotice(.processing, .in_flight, true));
    try std.testing.expectEqualStrings("Rui: Work needs your decision.\n", try progressNotice(.processing, .waiting_for_permission, true));
    try std.testing.expectEqualStrings("Rui: Your message is queued and ready for execution.\n", try progressNotice(.queued, .runnable, false));
    try std.testing.expectError(error.InvalidObservation, progressNotice(.failed, .in_flight, false));
}

test "Message follow policies use decoded facts without inventing progress" {
    const address = try client.MessageAddress.init("/store", "original/session", "original-key");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"original-key\",\"observation\":{\"kind\":\"message\",\"target\":\"original/session\",\"status\":\"accepted\",\"input\":{\"type\":\"text\",\"bytes\":\"1\",\"sha256\":\"" ++ "00" ** 32 ++ "\"},\"queue\":{\"status\":\"queued\",\"admission\":\"23\"}";
    // Independent expectations: ordinary follow sees attention alongside a
    // progressing sibling, Session wait sees only blocked progress, terminal
    // wait sees neither. Missing progress grants no attention or runnable fact.
    const cases = .{
        .{ "}}", false, false },
        .{ ",\"progress\":{\"status\":\"runnable\",\"action\":null}}}", false, false },
        .{ ",\"progress\":{\"status\":\"in_flight\",\"action\":null}}}", false, false },
        .{ ",\"progress\":{\"status\":\"in_flight\",\"action\":\"17\"}}}", true, false },
        .{ ",\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"29\"}}}", true, true },
        .{ ",\"processing\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"result\":{\"status\":\"failed\",\"code\":\"original_failure\"},\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"31\"}}}", false, false },
    };
    inline for (cases) |case| {
        const observed = try (try client.CommandObservation.parse(.{ .status = 200, .body = prefix ++ case[0] }, address.key.slice())).forMessage(&address);
        try std.testing.expectEqual(case[1], FollowPolicy.follow_attention.attention(&observed) != null);
        try std.testing.expectEqual(case[2], FollowPolicy.session_blocked.attention(&observed) != null);
        try std.testing.expect(FollowPolicy.terminal_only.attention(&observed) == null);
        if (comptime std.mem.eql(u8, case[0], "}}")) try std.testing.expect(observed.progress == null);
    }
}

test "Message attention retains replacement IDs while notices retain status and presence" {
    const address = try client.MessageAddress.init("/store", "s", "k");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"s\",\"input\":{\"type\":\"text\",\"bytes\":\"1\",\"sha256\":\"" ++ "00" ** 32 ++ "\"},\"queue\":{\"status\":\"processing\",\"admission\":\"23\"},\"processing\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"},\"progress\":{\"status\":\"in_flight\",\"action\":\"";
    inline for (.{ .{ "17", 17 }, .{ "71", 71 } }) |case| {
        const observed = try (try client.CommandObservation.parse(.{ .status = 200, .body = prefix ++ case[0] ++ "\"}}}" }, address.key.slice())).forMessage(&address);
        const attention = FollowPolicy.follow_attention.attention(&observed).?;
        try std.testing.expectEqual(@as(u64, case[1]), attention.action.?);
        try std.testing.expectEqualStrings("Rui: An Action needs your choice while other work remains in flight.\n", try progressNotice(observed.state(), attention.status, attention.action != null));
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
