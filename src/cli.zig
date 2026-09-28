const std = @import("std");
const TerminalEditor = @import("TerminalEditor.zig");
const client = @import("client.zig");
const codex_auth = @import("codex_auth.zig");
const codex_credentials = @import("codex_credentials.zig");
const model_adapter = @import("model_adapter.zig");
const platform = @import("platform.zig");
const preferences = @import("preferences.zig");
const provider = @import("provider.zig");
const protocol = @import("protocol.zig");
const server = @import("server.zig");

// Zig otherwise reserves an alternate signal stack on every thread even when
// the release build has no default crash handler to use it.
pub const std_options: std.Options = .{
    .signal_stack_size = if (std.debug.default_enable_segfault_handler) 1 << 18 else null,
};

extern "c" fn rui_launch_detached(executable: [*:0]const u8, store: [*:0]const u8) c_int;

test "detached launcher reports exec failure before claiming Host readiness" {
    try std.testing.expectEqual(@as(c_int, 2), rui_launch_detached("/rui-no-such-executable", "/rui-no-such-store"));
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return usage();
    const command = args[1];
    if (std.mem.eql(u8, command, "serve")) {
        try configureHostAllocator(init, args);
        return serve(init, args[2..]);
    }
    if (std.mem.eql(u8, command, "login")) return login(init, args[2..]);
    if (std.mem.eql(u8, command, "host")) return host(init, args[2..]);
    if (std.mem.eql(u8, command, "setup")) try setup(init, args[2..]) else if (std.mem.eql(u8, command, "session")) try enterSession(init, args[2..]) else if (std.mem.eql(u8, command, "wait-session")) try waitSession(init, args[2..]) else if (std.mem.eql(u8, command, "configure")) try configure(init, args[2..], false) else if (std.mem.eql(u8, command, "message")) try message(init, args[2..]) else if (std.mem.eql(u8, command, "stop-session")) try stopSession(init, args[2..]) else if (std.mem.eql(u8, command, "interrupt-model")) try interruptModel(init, args[2..]) else if (std.mem.eql(u8, command, "deny-action")) try decideAction(init, args[2..], .deny) else if (std.mem.eql(u8, command, "allow-action")) try decideAction(init, args[2..], .allow_once) else if (std.mem.eql(u8, command, "retry")) try retry(init.io, args[2..]) else if (std.mem.eql(u8, command, "observe-command")) try observe(init, args[2..]) else if (std.mem.eql(u8, command, "read-result")) try readResult(init, args[2..]) else if (std.mem.eql(u8, command, "read-action-call-id")) try readActionContent(init, args[2..], .call_id) else if (std.mem.eql(u8, command, "read-action-arguments")) try readActionArguments(init, args[2..]) else if (std.mem.eql(u8, command, "inspect-session")) try inspect(init, args[2..]) else if (std.mem.eql(u8, command, "requests")) try requests(init, args[2..]) else if (std.mem.eql(u8, command, "recover")) try recover(init, args[2..]) else if (std.mem.eql(u8, command, "follow")) try follow(init, args[2..]) else if (std.mem.eql(u8, command, "result")) try result(init, args[2..]) else if (std.mem.eql(u8, command, "inspect-action")) try inspectAction(init, args[2..], false) else return usage();
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

fn setup(init: std.process.Init, args: []const []const u8) !void {
    const home = init.environ_map.get("HOME") orelse {
        std.debug.print("rui: setup needs an absolute HOME; no preferences saved.\n", .{});
        return error.HomeUnavailable;
    };
    var store: ?[]const u8 = null;
    var selected_provider: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--store")) store = try takeValue(args, &index) else if (std.mem.eql(u8, flag, "--provider")) selected_provider = try takeValue(args, &index) else if (std.mem.eql(u8, flag, "--model")) model = try takeValue(args, &index) else return usage();
    }
    const changed = store != null or selected_provider != null or model != null;
    const values = (if (changed) preferences.update(home, store, selected_provider, model) else preferences.load(home)) catch |err| {
        if (err == error.PreferenceDirectorySyncFailed) {
            std.debug.print("rui: setup save durability unconfirmed; inspect HOME/.config/rui/preferences before another update. No Session changed.\n", .{});
        } else if (err == error.UnsupportedPreferenceProvider or err == error.PreferenceProviderRequired) {
            std.debug.print("rui: setup needs --provider codex with a model; no preferences saved.\n", .{});
        } else if (err == error.InvalidPreferenceModel) {
            std.debug.print("rui: setup model must be 1–256 printable non-space ASCII bytes; no preferences saved.\n", .{});
        } else if (err == error.InvalidPreferenceStore or err == error.FileNotFound) {
            std.debug.print("rui: setup Store must be an existing private, canonicalizable absolute directory; no alternate Store selected.\n", .{});
        } else std.debug.print("rui: setup {s}: {s}; inspect HOME/.config/rui/preferences and its private directory before retrying. No alternate Store selected.\n", .{ if (changed) "save failed" else "read failed", @errorName(err) });
        return err;
    };
    var fallback_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected_store = if (values.store.len != 0) values.store.slice() else try preferences.defaultStore(home, &fallback_buffer);
    // Preferences are local hints, not Session settings or Host facts.
    try std.Io.File.stdout().writeStreamingAll(init.io, if (changed) "Saved defaults for future Sessions. Active Session unchanged.\n" else "Defaults (read only):\n");
    try std.Io.File.stdout().writeStreamingAll(init.io, "Store: ");
    try writeSafeText(init.io, selected_store);
    try std.Io.File.stdout().writeStreamingAll(init.io, if (values.store.len != 0) " (saved)\n" else " (HOME fallback)\n");
    try writeSafeField(init.io, "Provider: ", if (values.provider.len != 0) values.provider.slice() else "not selected");
    try writeSafeField(init.io, "Model: ", if (values.model.len != 0) values.model.slice() else "not selected");
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
    if (!start and !std.mem.eql(u8, args[0], "status")) return usage();
    var explicit: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--store") and explicit == null) {
            explicit = try takeValue(args, &index);
        } else return usage();
    }
    var fallback: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const selected = try selectedStore(init, explicit, &fallback);
    if (start) return startHost(init, selected);
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

fn startHost(init: std.process.Init, selected: []const u8) !void {
    const io = init.io;
    switch (client.hostStatus(io, selected)) {
        .ready => |ready| {
            try std.Io.File.stdout().writeStreamingAll(io, "Rui: Attached to the ready Host; its existing capacity and capabilities win.\n");
            try writeHostDiagnostics(io, ready.store.slice());
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
    const launched = rui_launch_detached(@ptrCast(&executable_buffer), store_z.ptr);
    if (launched != 0) {
        std.debug.print("rui: detached Host could not execute (OS error {d}); Store ownership was not inferred.\n", .{launched});
        return error.HostLaunchFailed;
    }
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_s;
    while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < until) {
        switch (client.hostStatusUntil(io, paths.store.slice(), until)) {
            .ready => |ready| {
                var line: [100]u8 = undefined;
                try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "Rui: Host ready (active capacity {d}); existing settings win.\n", .{ready.active_capacity}));
                try writeHostDiagnostics(io, ready.store.slice());
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

fn login(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "codex")) return usage();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try credentialPath(init, &path_buffer, true);
    {
        var existing = codex_credentials.load(path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |*value| std.crypto.secureZero(u8, std.mem.asBytes(value));
    }
    try provider.initialize();
    defer provider.deinitialize();
    var tokens = try codex_auth.login(init.io, struct {
        fn display(code: []const u8) !void {
            std.debug.print("Open https://auth.openai.com/codex/device and enter code: {s}\n", .{code});
        }
    }.display);
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
    try codex_credentials.install(path, &record, null);
    try std.Io.File.stdout().writeStreamingAll(init.io, "Codex login installed.\n");
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
    const io = init.io;
    var json = false;
    var input = client.ConfigureInput{
        .store = "",
        .record = "",
        .key = "",
        .session = "",
    };
    var explicit_store: ?[]const u8 = null;
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            input.provider = .{ .present = true, .value = try takeValue(args, &index) };
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--workspace")) input.workspace = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--model")) input.model = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--instructions")) input.instructions = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--tools")) input.tools = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--permission-mode")) input.permission_mode = .{ .present = true, .value = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--output-schema")) input.output_schema = .{ .state = .value, .path = try takeValue(args, &index) } else if (std.mem.eql(u8, arg, "--text-output")) input.output_schema = .{ .state = .explicit_null } else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.session.len == 0 or (input.record.len == 0) != !key_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const human = !key_seen;
    if (human) {
        input.record = try newRequest(init, &record_buffer, &key_buffer);
        input.key = &key_buffer;
        input.captured = if (interactive) null else if (json) announceCaptureJson else announceCapture;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.configure(io, input, &reply_buffer);
    const accepted = if (human and interactive) try acceptedReply(reply) else false;
    if (human and (!interactive or !accepted)) try writeAdmission(io, reply, if (json) input.record else null) else if (!human) try writeCommandReply(io, reply);
    if (human and interactive and accepted) try std.Io.File.stdout().writeStreamingAll(io, "Rui: Configured.\n");
    if (human and !json and !interactive) {
        var line: [protocol.max_store_bytes + protocol.max_session_bytes + 64]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "configuration: {s} in {s}\n", .{ input.session, input.store }));
        if (try acceptedReply(reply)) try std.Io.File.stdout().writeStreamingAll(io, "next: rui session (same Store and Session)\n");
    }
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn message(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    var json = false;
    var input = client.MessageInput{ .store = "", .record = "", .key = "", .session = "", .text_path = "" };
    var explicit_store: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    var key_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--text")) input.text_path = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else if (positional == null and (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-"))) positional = arg else return error.UnknownArgument;
        index += 1;
    }
    if (positional) |value| {
        if (key_seen or input.text_path.len != 0) return usage();
        if (std.mem.eql(u8, value, "-")) input.text_path = "-" else input.text = value;
    }
    if (input.session.len == 0 or (input.text_path.len == 0 and input.text == null) or (input.record.len == 0) != !key_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const human = !key_seen;
    if (human) {
        input.record = try newRequest(init, &record_buffer, &key_buffer);
        input.key = &key_buffer;
        input.captured = if (json) announceCaptureJson else announceCapture;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.message(io, input, &reply_buffer);
    if (human) try writeAdmission(io, reply, if (json) input.record else null) else try writeCommandReply(io, reply);
    if (human and !json) {
        var line: [protocol.max_store_bytes + protocol.max_session_bytes + 64]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "message: {s} in {s}\n", .{ input.session, input.store }));
        if (try acceptedReply(reply)) try std.Io.File.stdout().writeStreamingAll(io, "next: rui session (same Store and Session)\n");
    }
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn selectedRequest(store: []const u8, session_ref: []const u8, key: []const u8) !SavedRequest {
    var saved: SavedRequest = .{};
    try saved.store.set(store);
    try saved.session.set(session_ref);
    try saved.key.set(key);
    try saved.kind.set("message");
    return saved;
}

fn acceptedReply(reply: client.CommandReply) !bool {
    if (reply.status != 200) return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    return std.mem.eql(u8, try stringField(try objectField(parsed.value, "answer"), "status"), "accepted");
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
        if (!terminal_only and work.action_count > 1) try showActionable(init.io, report.file, presentation == .json);
        break :blk try selectedRequest(store, session_ref, selected);
    };
    if (try followMessage(init, &saved, presentation, true, terminal_only)) |attention|
        return .{ .work = attention, .message = saved.key };
    if (presentation != .json) try showResult(init, &saved, presentation);
    return null;
}

fn showSessionStatus(init: std.process.Init, store: []const u8, session_ref: []const u8, brief: bool) !void {
    const report = try inspectWork(init, store, session_ref);
    defer report.file.close(init.io);
    const work = report.work;
    if (work.workspace.len == 0) return error.SessionNotConfigured;
    if (brief) {
        try writeSafeField(init.io, "Session: ", session_ref);
        try writeSafeField(init.io, "Workspace (Bash cwd): ", work.workspace.slice());
        try writeSafeField(init.io, "Provider: ", work.provider.slice());
        try writeSafeField(init.io, "Model: ", work.model.slice());
        try std.Io.File.stdout().writeStreamingAll(init.io, "Permission: ");
        try writeSafeText(init.io, work.permission_mode.slice());
        try std.Io.File.stdout().writeStreamingAll(init.io, if (work.permission_mode.eql("bypass")) " (Bash runs without approval)\nRui: Bash commands can run without asking you.\n" else "\n");
        if (work.selected_message != null) try writeSafeField(init.io, "Work: ", work.status.slice());
        if (work.action_count != 0) try showActionable(init.io, report.file, false);
        return;
    }
    try writeSafeField(init.io, "Session: ", session_ref);
    try writeSafeField(init.io, "Store: ", store);
    try writeSafeField(init.io, "Workspace (Bash cwd): ", work.workspace.slice());
    try writeSafeField(init.io, "Permission: ", work.permission_mode.slice());
    try writeSafeField(init.io, "Work: ", work.status.slice());
    if (work.selected_message) |selected|
        try writeSafeField(init.io, "Current message: ", selected.slice());
    if (work.action_count != 0) try showActionable(init.io, report.file, false);
    if (work.indeterminate_action) |action| {
        try writeSafeField(init.io, "Indeterminate Action: ", action.slice());
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
            try writeSafeText(init.io, recent.key.slice());
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
    try std.json.Stringify.encodeJsonStringChars(value, .{ .escape_unicode = true }, &writer.interface);
    try writer.flush();
}

fn reportAcceptedPresentationFailure(key: []const u8, err: anyerror) void {
    std.debug.print("rui: Message accepted, but later observation or presentation failed ({s}). Use rui result {s} to inspect the same Message; do not resubmit it\n", .{ @errorName(err), key });
}

fn sessionMessage(init: std.process.Init, store: []const u8, session_ref: []const u8, text: []const u8) !?Attention {
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const record = try newRequest(init, &record_buffer, &key_buffer);
    const input = client.MessageInput{
        .store = store,
        .session = session_ref,
        .record = record,
        .key = &key_buffer,
        .text_path = "",
        .text = text,
        .captured = null,
    };
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.message(init.io, input, &reply_buffer);
    const accepted = try acceptedReply(reply);
    if (!accepted) try writeAdmission(init.io, reply, null);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
    if (!accepted) return null;
    writeSafeField(init.io, "You: ", text) catch |err| {
        reportAcceptedPresentationFailure(&key_buffer, err);
        return null;
    };
    const saved = selectedRequest(store, session_ref, &key_buffer) catch |err| {
        reportAcceptedPresentationFailure(&key_buffer, err);
        return null;
    };
    const next = followMessage(init, &saved, .interactive, false, false) catch |err| {
        reportAcceptedPresentationFailure(&key_buffer, err);
        return null;
    };
    if (next) |attention|
        return .{ .work = attention, .message = saved.key };
    showResult(init, &saved, .interactive) catch |err| {
        reportAcceptedPresentationFailure(&key_buffer, err);
    };
    return null;
}

fn enterSession(init: std.process.Init, args: []const []const u8) !void {
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
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: /help  /status  /wait  /requests  /result KEY  /setup [--store PATH] [--provider codex] [--model MODEL]  /configure [settings]  /exit\n/help shows these commands; /status inspects this Session; /wait follows selected work; /requests lists local recovery handles; /result KEY reads a saved answer. /setup saves defaults for future Sessions only; /configure changes this Session; /exit detaches without stopping work.\nMessages are submitted as written. To send a leading /, prefix it with //; use the one-shot --text FILE for longer input.\n");
            continue;
        }
        const attention: ?Attention = if (std.mem.eql(u8, text, "/setup") or std.mem.startsWith(u8, text, "/setup ")) blk: {
            var setup_args: [6][]const u8 = undefined;
            const count = interactiveTokens(input_buffer["/setup".len..text.len], &setup_args) catch {
                try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: /setup [--store PATH] [--provider codex] [--model MODEL]; no changes saved.\n");
                break :blk null;
            };
            if (count % 2 != 0) {
                try std.Io.File.stdout().writeStreamingAll(init.io, "Usage: /setup [--store PATH] [--provider codex] [--model MODEL]; no changes saved.\n");
            } else setup(init, setup_args[0..count]) catch |err| std.debug.print("rui: /setup: {s}; active Session unchanged\n", .{@errorName(err)});
            break :blk null;
        } else if (std.mem.eql(u8, text, "/status")) blk: {
            showSessionStatus(init, destination, reference, false) catch |err| std.debug.print("rui: status: {s}\n", .{@errorName(err)});
            break :blk null;
        } else if (std.mem.eql(u8, text, "/requests")) blk: {
            sessionRequests(init, destination, reference) catch |err| std.debug.print("rui: requests: {s}\n", .{@errorName(err)});
            break :blk null;
        } else if (std.mem.eql(u8, text, "/wait"))
            waitForSession(init, destination, reference, .interactive, false) catch |err| blk: {
                std.debug.print("rui: wait: {s}\n", .{@errorName(err)});
                break :blk null;
            }
        else if (std.mem.startsWith(u8, text, "/result ")) blk: {
            const saved = selectedRequest(destination, reference, std.mem.trim(u8, text[8..], " ")) catch |err| {
                std.debug.print("rui: result key: {s}\n", .{@errorName(err)});
                break :blk null;
            };
            showResult(init, &saved, .interactive) catch |err| std.debug.print("rui: result: {s}\n", .{@errorName(err)});
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
                configure(init, config_args[0..count], true) catch |err| std.debug.print("rui: configure: {s}; check /requests before retrying\n", .{@errorName(err)});
            } else try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Usage: /configure --model MODEL [--tools bash] [--permission-mode ask|bypass] (settings for this Session only)\n");
            break :blk null;
        } else if (std.mem.startsWith(u8, text, "/") and !std.mem.startsWith(u8, text, "//")) blk: {
            try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Unknown command. Type /help.\n");
            break :blk null;
        } else blk: {
            const message_text = if (std.mem.startsWith(u8, text, "//")) text[1..] else text;
            break :blk sessionMessage(init, destination, reference, message_text) catch |err| {
                std.debug.print("rui: message: {s}; admission may be uncertain. Check /requests and recover the original handle before sending new work\n", .{@errorName(err)});
                break :blk null;
            };
        };
        if (attention) |action| interactiveAction(init, destination, reference, action) catch |err| {
            if (err == error.InteractiveInterrupted) break;
            if (err == error.TerminalRestoreFailed or err == error.TerminalCleanupFailed or err == error.TerminalFlushFailed or err == error.IncompleteTerminalInput) return err;
            std.debug.print("rui: Action observation or decision failed: {s}; check /requests and /status\n", .{@errorName(err)});
        };
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: Detached. Host work continues.\n");
}

fn interactiveAction(init: std.process.Init, store: []const u8, session_ref: []const u8, initial: Attention) !void {
    const saved = try selectedRequest(store, session_ref, initial.message.slice());
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
        var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var key_buffer: [36]u8 = undefined;
        const record = try newRequest(init, &record_buffer, &key_buffer);
        var reply_buffer: client.ReplyBuffer = .{};
        const reply = try client.denyPermission(init.io, .{
            .store = store,
            .session = session_ref,
            .record = record,
            .key = &key_buffer,
            .action_id = id,
            .decision = decision,
            .captured = null,
        }, &reply_buffer);
        const accepted = try acceptedReply(reply);
        if (!accepted) try writeAdmission(init.io, reply, null);
        if (reply.status != 200) return;
        if (!accepted) return;
        pending = try followMessage(init, &saved, .interactive, false, false);
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
        .record = "",
        .key = "",
        .session = "",
        .action_id = 0,
        .decision = decision,
    };
    var explicit_store: ?[]const u8 = null;
    var key_seen = false;
    var action_seen = false;
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) explicit_store = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--record")) input.record = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--key")) {
            input.key = try takeValue(args, &index);
            key_seen = true;
        } else if (std.mem.eql(u8, arg, "--session")) input.session = try takeValue(args, &index) else if (std.mem.eql(u8, arg, "--action")) {
            input.action_id = try std.fmt.parseInt(u64, try takeValue(args, &index), 10);
            action_seen = true;
        } else if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--test-drop-reply")) input.drop_reply = try takeValue(args, &index) else return error.UnknownArgument;
        index += 1;
    }
    if (input.session.len == 0 or !action_seen or (input.record.len == 0) != !key_seen) return usage();
    var selected_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    input.store = try selectedStore(init, explicit_store, &selected_buffer);
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const human = !key_seen;
    if (human) {
        input.record = try newRequest(init, &record_buffer, &key_buffer);
        input.key = &key_buffer;
        input.captured = if (json) announceCaptureJson else announceCapture;
    }
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.denyPermission(io, input, &reply_buffer);
    if (human) try writeAdmission(io, reply, if (json) input.record else null) else try writeCommandReply(io, reply);
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

fn newRequest(init: std.process.Init, path: []u8, key: *[36]u8) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try std.Io.randomSecure(init.io, &bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const id = try std.fmt.bufPrint(key, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        std.mem.readInt(u32, bytes[0..4], .big),
        std.mem.readInt(u16, bytes[4..6], .big),
        std.mem.readInt(u16, bytes[6..8], .big),
        std.mem.readInt(u16, bytes[8..10], .big),
        std.mem.readInt(u48, bytes[10..16], .big),
    });
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &directory_buffer);
    return std.fmt.bufPrint(path, "{s}/{s}.json", .{ directory, id });
}

fn announceCapture(io: std.Io, record: []const u8) !void {
    try testGate(io, "RUI_TEST_CAPTURE_GATE");
    const name = std.fs.path.basename(record);
    try std.Io.File.stdout().writeStreamingAll(io, "request: ");
    try std.Io.File.stdout().writeStreamingAll(io, name[0 .. name.len - ".json".len]);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn announceCaptureJson(io: std.Io, record: []const u8) !void {
    try testGate(io, "RUI_TEST_CAPTURE_GATE");
    const name = std.fs.path.basename(record);
    var line: [96]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"event\":\"captured\",\"request\":\"{s}\"}}\n", .{name[0 .. name.len - ".json".len]}));
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

fn writeAdmission(io: std.Io, reply: client.CommandReply, json_record: ?[]const u8) !void {
    if (json_record) |record| {
        const name = std.fs.path.basename(record);
        var line: [112]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "{{\"event\":\"admission\",\"request\":\"{s}\",\"admission\":", .{name[0 .. name.len - ".json".len]}));
        try std.Io.File.stdout().writeStreamingAll(io, reply.body);
        return std.Io.File.stdout().writeStreamingAll(io, "}\n");
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    defer parsed.deinit();
    const answer = try objectField(parsed.value, "answer");
    const status = try stringField(answer, "status");
    var line: [128]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&line, "admitted: {s}\n", .{status}));
    const replayed = try objectField(answer, "replayed");
    if (replayed != .bool) return error.InvalidObservation;
    try std.Io.File.stdout().writeStreamingAll(io, if (replayed.bool) "replayed: true\n" else "replayed: false\n");
    if (answer.object.get("code")) |code| {
        if (code != .string) return error.InvalidObservation;
        try std.Io.File.stdout().writeStreamingAll(io, "code: ");
        try std.Io.File.stdout().writeStreamingAll(io, code.string);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
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

const SavedMessageObservation = struct {
    parsed: std.json.Parsed(std.json.Value),
    // Borrowed from parsed; valid until parsed.deinit().
    value: std.json.Value,
    state: State,

    const State = enum {
        accepted,
        queued,
        processing,
        rejected,
        completed,
        failed,
        cancelled,

        fn terminal(self: State) bool {
            return switch (self) {
                .rejected, .completed, .failed, .cancelled => true,
                else => false,
            };
        }
    };
};

fn readSavedMessage(init: std.process.Init, saved: *const SavedRequest) !SavedMessageObservation {
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.observeCommand(init.io, saved.store.slice(), saved.key.slice(), &buffer);
    return parseSavedMessage(reply, saved);
}

fn parseSavedMessage(reply: client.CommandReply, saved: *const SavedRequest) !SavedMessageObservation {
    if (reply.status != 200) return error.ObservationFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, reply.body, .{});
    errdefer parsed.deinit();
    const observation = try objectField(parsed.value, "observation");
    const status = try stringField(observation, "status");
    if (std.mem.eql(u8, status, "absent")) return error.RequestNotAdmitted;
    if (!std.mem.eql(u8, try stringField(observation, "kind"), "message") or
        !std.mem.eql(u8, try stringField(observation, "target"), saved.session.slice())) return error.RequestBindingMismatch;

    const state: SavedMessageObservation.State = if (std.mem.eql(u8, status, "rejected")) .rejected else if (std.mem.eql(u8, status, "accepted")) blk: {
        if (observation.object.get("result")) |terminal_result| {
            const outcome = try stringField(terminal_result, "status");
            if (std.mem.eql(u8, outcome, "completed")) break :blk .completed;
            if (std.mem.eql(u8, outcome, "failed")) break :blk .failed;
            if (std.mem.eql(u8, outcome, "cancelled")) break :blk .cancelled;
            return error.InvalidObservation;
        }
        if (observation.object.get("queue")) |queue| {
            const queued = try stringField(queue, "status");
            if (std.mem.eql(u8, queued, "queued")) break :blk .queued;
            if (std.mem.eql(u8, queued, "processing")) break :blk .processing;
            return error.InvalidObservation;
        }
        break :blk .accepted;
    } else return error.InvalidObservation;
    return .{ .parsed = parsed, .value = observation, .state = state };
}

fn requestPath(init: std.process.Init, handle: []const u8, buffer: []u8) ![]const u8 {
    if (handle.len != 36) return error.InvalidRequestHandle;
    for (handle, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return error.InvalidRequestHandle;
        } else if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidRequestHandle;
    }
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = try requestDirectory(init, &directory_buffer);
    return std.fmt.bufPrint(buffer, "{s}/{s}.json", .{ directory, handle });
}

fn savedRequest(init: std.process.Init, handle: []const u8) !SavedRequest {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(init, handle, &path_buffer);
    const value = try client.readCapturedIdentity(init.io, path, handle);
    if (!value.kind.eql("configure") and !value.kind.eql("message") and
        !value.kind.eql("permission_decision")) return error.InvalidRequestRecord;
    return value;
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
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        _ = requestPath(init, handle, &path_buffer) catch continue;
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
    const saved = try savedRequest(init, args[0]);
    const kind = if (saved.kind.eql("permission_decision")) "permission-decision" else saved.kind.slice();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(init, args[0], &path_buffer);
    var buffer: client.ReplyBuffer = .{};
    const reply = try client.retry(init.io, saved.store.slice(), path, kind, &buffer);
    if (json) try writeCommandReply(init.io, reply) else try writeAdmission(init.io, reply, null);
    if (reply.status != 200 and reply.status != 409) return error.HostInvocationFailed;
}

fn result(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    if (!saved.kind.eql("message")) return error.NotMessageRequest;
    try showResult(init, &saved, if (json) .json else .human);
}

fn showResult(init: std.process.Init, saved: *const SavedRequest, presentation: Presentation) !void {
    const json = presentation == .json;
    var observed = try readSavedMessage(init, saved);
    defer observed.parsed.deinit();
    const observation = observed.value;
    const state = observed.state;
    const observation_json = if (json) try std.json.Stringify.valueAlloc(std.heap.c_allocator, observation, .{}) else "";
    defer if (json) std.heap.c_allocator.free(observation_json);
    const result_value = observation.object.get("result");
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
        try std.Io.File.stdout().writeStreamingAll(init.io, notice);
        const details = if (state == .rejected) observation else result_value;
        if (details) |value| {
            if (value.object.get("code")) |code| {
                if (code != .string) return error.InvalidObservation;
                try writeSafeField(init.io, "Rui: Code: ", code.string);
                if (std.mem.eql(u8, code.string, "indeterminate"))
                    try std.Io.File.stdout().writeStreamingAll(init.io, "Rui: The command may have run. Rui did not rerun it; inspect saved work before choosing a next action.\n");
            }
        }
    } else if (!json and presentation != .interactive) {
        var line: [256]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "result: {s}\n", .{@tagName(state)}));
        const details = if (state == .rejected) observation else result_value;
        if (details) |value| {
            if (value.object.get("code")) |code| {
                if (code != .string) return error.InvalidObservation;
                try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "code: {s}\n", .{code.string}));
            }
        }
    }
    if (state != .completed) {
        if (json) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "{\"observation\":");
            try std.Io.File.stdout().writeStreamingAll(init.io, observation_json);
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
        try std.Io.File.stdout().writeStreamingAll(init.io, observation_json);
        try std.Io.File.stdout().writeStreamingAll(init.io, ",\"answer\":\"");
        try writeJsonFileAt(init.io, file, 0, answer.answer.bytes, false);
        return std.Io.File.stdout().writeStreamingAll(init.io, "\"}\n");
    }
    if (presentation == .interactive) try std.Io.File.stdout().writeStreamingAll(init.io, "Assistant: ");
    var read_buffer: client.ReplyBuffer = .{};
    const answer = try client.readResult(init.io, saved.store.slice(), saved.key.slice(), std.Io.File.stdout(), &read_buffer);
    switch (answer) {
        .answer => {},
        .command => return error.ResultReadFailed,
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
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
    selected_message: ?protocol.Bounded(protocol.max_key_bytes) = null,
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
    if (work.status.len == 0 or (try reader.next()) != .end_of_document) return error.InvalidObservation;
    return work;
}

const SessionObservation = struct {
    work: Work,
    // The complete Current capture remains owned until all its permissions
    // have been displayed; no per-Action resident list is needed.
    file: std.Io.File,
};

fn inspectWork(init: std.process.Init, store: []const u8, session_ref: []const u8) !SessionObservation {
    const file = try renderScratch(init);
    errdefer file.close(init.io);
    var response: client.ReplyBuffer = .{};
    const reply = try client.inspectSession(init.io, store, session_ref, .current, file, &response);
    switch (reply) {
        .report => {},
        .command => return error.ObservationFailed,
    }
    var input_buffer: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.reader(init.io, &input_buffer);
    var json_reader = std.json.Reader.init(std.heap.c_allocator, &file_reader.interface);
    defer json_reader.deinit();
    return .{ .work = try readWork(&json_reader), .file = file };
}

fn showActionable(io: std.Io, file: std.Io.File, json: bool) !void {
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
        if (json) try std.Io.File.stdout().writeStreamingAll(io, "{\"event\":\"actionable_permissions\",\"actions\":[");
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
                if (!first) try std.Io.File.stdout().writeStreamingAll(io, ",");
                try std.Io.File.stdout().writeStreamingAll(io, "\"");
                try std.Io.File.stdout().writeStreamingAll(io, action.slice());
                try std.Io.File.stdout().writeStreamingAll(io, "\"");
            } else try writeSafeField(io, "Action requiring attention: ", action.slice());
            first = false;
        }
        if (json) try std.Io.File.stdout().writeStreamingAll(io, "]}\n");
        return;
    }
}

fn writeFollowOutcome(init: std.process.Init, observation: std.json.Value, state: SavedMessageObservation.State, presentation: Presentation) !void {
    if (presentation == .interactive) return;
    if (presentation == .json) {
        const observation_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, observation, .{});
        defer std.heap.c_allocator.free(observation_json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "{\"return\":\"outcome\",\"observation\":");
        try std.Io.File.stdout().writeStreamingAll(init.io, observation_json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "}\n");
    } else {
        var line: [128]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&line, "return: outcome\nstatus: {s}\n", .{@tagName(state)}));
    }
}

fn follow(init: std.process.Init, args: []const []const u8) !void {
    const json = args.len == 2 and std.mem.eql(u8, args[1], "--json");
    if (args.len != 1 and !json) return usage();
    const saved = try savedRequest(init, args[0]);
    if (!saved.kind.eql("message")) return error.NotMessageRequest;
    _ = try followMessage(init, &saved, if (json) .json else .human, false, false);
}

fn progressNotice(queue: SavedMessageObservation.State, status: []const u8, has_action: bool) ![]const u8 {
    if (queue == .queued) {
        if (std.mem.eql(u8, status, "waiting_for_permission")) return "Rui: Your message is queued behind work needing a decision.\n";
        if (std.mem.eql(u8, status, "in_flight")) return if (has_action)
            "Rui: Your message is queued behind work in flight; an Action also needs a decision.\n"
        else
            "Rui: Your message is queued behind work in flight.\n";
        if (std.mem.eql(u8, status, "runnable")) return "Rui: Your message is queued and ready for execution.\n";
    } else if (queue == .processing) {
        if (std.mem.eql(u8, status, "waiting_for_permission")) return "Rui: Work needs your decision.\n";
        if (std.mem.eql(u8, status, "in_flight")) return if (has_action)
            "Rui: An Action needs your choice while other work remains in flight.\n"
        else
            "Rui: Work is in flight.\n";
        if (std.mem.eql(u8, status, "runnable")) return "Rui: Work is ready to continue.\n";
    }
    return error.InvalidObservation;
}

// null is the selected message's terminal observation; an Action is only a hint
// to inspect and decide against the Host's exact current target.
fn followMessage(init: std.process.Init, saved: *const SavedRequest, presentation: Presentation, session_wait: bool, terminal_only: bool) !?Work {
    var last_queue: ?SavedMessageObservation.State = null;
    var last_progress: protocol.Bounded(32) = .{};
    var last_action = false;
    var unchanged_polls: u8 = 0;
    while (true) {
        var observed = try readSavedMessage(init, saved);
        defer observed.parsed.deinit();
        if (observed.state.terminal()) {
            try writeFollowOutcome(init, observed.value, observed.state, presentation);
            return null;
        }
        const progress = try objectField(observed.value, "progress");
        const state = try stringField(progress, "status");
        const action = try objectField(progress, "action");
        // Test-only pause after capturing the Message's coherent observation.
        try testGate(init.io, "RUI_TEST_FOLLOW_GATE");
        if (presentation == .interactive and (last_queue == null or last_queue.? != observed.state or !last_progress.eql(state) or last_action != (action == .string))) {
            try std.Io.File.stdout().writeStreamingAll(init.io, try progressNotice(observed.state, state, action == .string));
            last_queue = observed.state;
            try last_progress.set(state);
            last_action = action == .string;
            unchanged_polls = 0;
        } else if (presentation == .interactive and std.mem.eql(u8, state, "in_flight")) {
            if (unchanged_polls == 99) {
                try std.Io.File.stdout().writeStreamingAll(init.io, if (observed.state == .queued) "Rui: Still queued behind work in flight.\n" else "Rui: Work is still in flight.\n");
                unchanged_polls = 0;
            } else unchanged_polls += 1;
        }
        if (!terminal_only and action == .string and (!session_wait or std.mem.eql(u8, state, "waiting_for_permission"))) {
            var work: Work = .{};
            try work.status.set(state);
            try work.action.set(action.string);
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
        if (call != .answer) return error.ActionReadFailed;
        call_bytes = call.answer.bytes;
    }
    const arguments = try client.readActionArguments(io, selected, reference, target, file, &buffer);
    if (arguments != .answer) return error.ActionReadFailed;
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
        \\  rui login codex
        \\  rui host status [--store PATH]
        \\    Read the selected Store's protected Host readiness, capacity and capabilities without starting it.
        \\  rui host start [--store PATH]
        \\    Attach or detach a capacity-8 managed Host; existing Host settings win.
        \\  rui setup [--store PATH] [--provider codex] [--model MODEL]
        \\    Inspect without arguments; save private defaults for future interactive Sessions.
        \\    Selected Store must exist and pass canonical/private checks.
        \\  rui serve [--store PATH] [--active-capacity N] [--codex | --provider-endpoint URL] [--provider-ca-file PATH] [--fault NAME]
        \\  rui configure [--store PATH] --session REF [settings] [--json]
        \\    First configuration requires --workspace PATH --provider codex --model MODEL.
        \\  rui session [--store PATH] --session REF
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
        \\    Handles are saved under HOME/.config/rui/requests; Host startup is explicit.
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
    return error.InvalidArguments;
}

test "interactive progress distinguishes queued dependency from selected work" {
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work in flight.\n", try progressNotice(.queued, "in_flight", false));
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work in flight; an Action also needs a decision.\n", try progressNotice(.queued, "in_flight", true));
    try std.testing.expectEqualStrings("Rui: Your message is queued behind work needing a decision.\n", try progressNotice(.queued, "waiting_for_permission", true));
    try std.testing.expectEqualStrings("Rui: Work is in flight.\n", try progressNotice(.processing, "in_flight", false));
    try std.testing.expectEqualStrings("Rui: An Action needs your choice while other work remains in flight.\n", try progressNotice(.processing, "in_flight", true));
    try std.testing.expectEqualStrings("Rui: Work needs your decision.\n", try progressNotice(.processing, "waiting_for_permission", true));
    try std.testing.expectEqualStrings("Rui: Your message is queued and ready for execution.\n", try progressNotice(.queued, "runnable", false));
    try std.testing.expectError(error.InvalidObservation, progressNotice(.failed, "in_flight", false));
}

test "saved Message classification retains original binding and terminal outcomes" {
    var saved: SavedRequest = .{};
    try saved.session.set("original/session");
    const prefix = "{\"observation\":{\"kind\":\"message\",\"target\":\"original/session\",";
    const cases = .{
        .{ "\"status\":\"accepted\"}}", SavedMessageObservation.State.accepted },
        .{ "\"status\":\"accepted\",\"queue\":{\"status\":\"queued\"},\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"7\"}}}", SavedMessageObservation.State.queued },
        .{ "\"status\":\"accepted\",\"queue\":{\"status\":\"processing\"}}}", SavedMessageObservation.State.processing },
        .{ "\"status\":\"rejected\",\"code\":\"unknown_session\"}}", SavedMessageObservation.State.rejected },
        .{ "\"status\":\"accepted\",\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"}}}", SavedMessageObservation.State.failed },
        .{ "\"status\":\"accepted\",\"queue\":{\"status\":\"excluded\"},\"result\":{\"status\":\"cancelled\"}}}", SavedMessageObservation.State.cancelled },
        .{ "\"status\":\"accepted\",\"result\":{\"status\":\"completed\"}}}", SavedMessageObservation.State.completed },
    };
    inline for (cases) |case| {
        var observed = try parseSavedMessage(.{ .status = 200, .body = prefix ++ case[0] }, &saved);
        defer observed.parsed.deinit();
        try std.testing.expectEqual(case[1], observed.state);
        try std.testing.expectEqualStrings("original/session", try stringField(observed.value, "target"));
    }
    try std.testing.expectError(error.ObservationFailed, parseSavedMessage(.{ .status = 503, .body = "" }, &saved));
    try std.testing.expectError(error.RequestNotAdmitted, parseSavedMessage(.{ .status = 200, .body = "{\"observation\":{\"status\":\"absent\"}}" }, &saved));
    try std.testing.expectError(error.RequestBindingMismatch, parseSavedMessage(.{ .status = 200, .body = "{\"observation\":{\"status\":\"accepted\",\"kind\":\"configure\",\"target\":\"original/session\"}}" }, &saved));
    try std.testing.expectError(error.RequestBindingMismatch, parseSavedMessage(.{ .status = 200, .body = "{\"observation\":{\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"later/session\",\"result\":{\"status\":\"completed\"}}}" }, &saved));
    try std.testing.expectError(error.InvalidObservation, parseSavedMessage(.{ .status = 200, .body = prefix ++ "\"status\":\"accepted\",\"result\":{\"status\":\"mystery\"}}}" }, &saved));
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
