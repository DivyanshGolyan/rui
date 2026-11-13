//! Sparse saved settings and ordered document/assignment intake. The Host
//! receives only the prepared value; process environment and secret I/O end here.
const std = @import("std");
const hs = @import("host_settings.zig");
const cli_args = @import("cli_args.zig");
const providers = @import("providers.zig");
const protocol = @import("protocol.zig");
const api_key = @import("api_key.zig");
const provider_login = @import("provider_login.zig");
const credentials = @import("codex_credentials.zig");
const core_tools = @import("core_tools.zig");
const wire_request = @import("wire_request.zig");
const platform = @import("platform.zig");
const stderr = @import("stderr.zig");

const secret_value = @import("secret_value.zig");
const codex_auth = @import("codex_auth.zig");
const start_report = @import("start_report.zig");
pub const ShutdownPolicy = hs.Interface.Lifetime;

fn checkPreset(gpa: std.mem.Allocator, spec: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
    const configuration = try gpa.create(wire_request.Configuration);
    defer {
        std.crypto.secureZero(u8, std.mem.asBytes(configuration));
        gpa.destroy(configuration);
    }
    configuration.* = .{};
    return switch (try core_tools.parseAgentSpec(gpa, spec, configuration)) {
        .accepted => null,
        .rejected => |reason| reason,
    };
}

fn assign(settings: *hs.Settings, gpa: std.mem.Allocator, path: []const u8, value: []const u8, failure: *start_report.Failure) !void {
    try hs.assign(settings, gpa, path, value, checkPreset, failure);
}

// Path argv is OS bytes, not JSON, including a leading quote or brace.
fn text(settings: *hs.Settings, gpa: std.mem.Allocator, path: []const u8, value: []const u8, failure: *start_report.Failure) !void {
    for (hs.leaves) |leaf| if (std.mem.eql(u8, leaf.pattern, path) and std.mem.eql(u8, leaf.kind, "path")) return assign(settings, gpa, path, value, failure);
    var wiping: secret_value.WipingAllocator = .{ .backing = gpa };
    const json = try std.json.Stringify.valueAlloc(wiping.allocator(), value, .{});
    defer wiping.allocator().free(json);
    try assign(settings, gpa, path, json, failure);
}

fn parse(gpa: std.mem.Allocator, bytes: []const u8, failure: *start_report.Failure) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return invalid(failure, "settings", "must be a JSON document");
    };
}

fn encoded(gpa: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

fn complete(gpa: std.mem.Allocator, settings: *const hs.Settings, failure: *start_report.Failure) !std.json.Value {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try hs.write(settings, &out.writer);
    return parse(gpa, out.written(), failure);
}

fn lookup(root: std.json.Value, path: []const u8) ?std.json.Value {
    if (path.len == 0) return root;
    if (root != .object) return null;
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const child = root.object.get(path[0 .. dot orelse path.len]) orelse return null;
    return if (dot) |at| lookup(child, path[at + 1 ..]) else child;
}

// This edits syntax only. All path/name/value admission belongs to hs.assign.
fn put(gpa: std.mem.Allocator, root: *std.json.Value, path: []const u8, value: std.json.Value) !void {
    if (root.* != .object) root.* = .{ .object = .{} };
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    if (dot) |at| {
        if (!root.object.contains(head)) try root.object.put(gpa, try gpa.dupe(u8, head), .{ .object = .{} });
        try put(gpa, root.object.getPtr(head).?, path[at + 1 ..], value);
    } else try root.object.put(gpa, try gpa.dupe(u8, head), value);
}

fn remove(root: *std.json.Value, path: []const u8) void {
    if (root.* != .object) return;
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    if (dot) |at| {
        const child = root.object.getPtr(head) orelse return;
        remove(child, path[at + 1 ..]);
    } else _ = root.object.swapRemove(head);
}

fn matches(pattern: []const u8, path: []const u8) bool {
    var a = std.mem.splitScalar(u8, pattern, '.');
    var b = std.mem.splitScalar(u8, path, '.');
    while (a.next()) |part| {
        const concrete = b.next() orelse return false;
        if (!std.mem.eql(u8, part, "*") and !std.mem.eql(u8, part, concrete)) return false;
    }
    return b.next() == null;
}

/// @FILE always supplies JSON, even for a Path whose ordinary argv is raw OS bytes.
fn input(init: std.process.Init, settings: *hs.Settings, path: []const u8, value: []const u8, failure: *start_report.Failure) !void {
    if (!std.mem.startsWith(u8, value, "@")) return assign(settings, init.gpa, path, value, failure);
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, value[1..], gpa, .limited(hs.max_document_bytes)) catch return invalid(failure, "settings", "@FILE must be readable within the document byte bound");
    defer {
        std.crypto.secureZero(u8, bytes);
        gpa.free(bytes);
    }
    const json = try parse(gpa, bytes, failure);
    for (hs.leaves) |leaf| {
        if (std.mem.eql(u8, leaf.kind, "path") and matches(leaf.pattern, path)) {
            // Have assign validate the concrete path and dynamic names. Its raw
            // Path syntax cannot carry JSON, so apply the JSON through its parent.
            try assign(settings, init.gpa, path, leaf.sample_text, failure);
            const dot = std.mem.lastIndexOfScalar(u8, path, '.').?;
            var child: std.json.Value = .{ .object = .{} };
            try child.object.put(gpa, path[dot + 1 ..], json);
            return assign(settings, init.gpa, path[0..dot], try encoded(gpa, child), failure);
        }
    }
    try assign(settings, init.gpa, path, bytes, failure);
}

fn savedPath(init: std.process.Init, gpa: std.mem.Allocator, dir: []const u8) ![]const u8 {
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const host = try platform.canonicalStoreDestination(init.io, dir, &canonical);
    return std.fs.path.join(gpa, &.{ host, "host.json" });
}

fn saved(init: std.process.Init, gpa: std.mem.Allocator, dir: []const u8, settings: *hs.Settings, failure: *start_report.Failure) !std.json.Value {
    const path = try savedPath(init, gpa, dir);
    // Absence is not a private-file admission. Legacy or not-yet-created Host
    // directories need no settings permissions until a document exists.
    _ = std.Io.Dir.cwd().statFile(init.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = .{} },
        else => return invalid(failure, "settings", "host.json must be a readable private file within the document byte bound"),
    };
    const buffer = try gpa.alloc(u8, hs.max_document_bytes + 1);
    defer {
        std.crypto.secureZero(u8, buffer);
        gpa.free(buffer);
    }
    const bytes = credentials.readPrivate(path, buffer) catch return invalid(failure, "settings", "host.json must be a readable private file within the document byte bound");
    if (bytes) |document| {
        try hs.apply(settings, init.gpa, document, .file, checkPreset, failure);
        return parse(gpa, document, failure);
    }
    return .{ .object = .{} };
}

/// Edit the sparse document, never a materialized defaults snapshot. Temporary
/// JSON, including refused literal secrets, lives only in a wiping arena.
pub fn savedEdit(init: std.process.Init, dir: []const u8, path: []const u8, value: ?[]const u8, failure: *start_report.Failure) !void {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var document = try saved(init, gpa, dir, settings, failure);
    if (value) |given| {
        try input(init, settings, path, given, failure);
        const all = try complete(gpa, settings, failure);
        const admitted = lookup(all, path) orelse return invalid(failure, "settings", "assignment did not produce a setting");
        // A Store is one Adapter; selecting another replaces the old arm.
        if (std.mem.startsWith(u8, path, "store.")) {
            const current = lookup(all, "store").?;
            if (document.object.getPtr("store")) |old| {
                if (old.* == .object) {
                    var keys = old.object.iterator();
                    while (keys.next()) |entry| if (!current.object.contains(entry.key_ptr.*)) {
                        _ = old.object.swapRemove(entry.key_ptr.*);
                        break;
                    };
                }
            }
        }
        try put(gpa, &document, path, admitted);
    } else {
        const all = try complete(gpa, settings, failure);
        if (lookup(all, path)) |existing| {
            // assign also diagnoses invalid punctuation and unknown paths with
            // the nearest generated leaf, rather than a shell-owned path table.
            var sample = try encoded(gpa, existing);
            for (hs.leaves) |leaf| if (std.mem.eql(u8, leaf.kind, "path") and matches(leaf.pattern, path)) {
                sample = try gpa.dupe(u8, leaf.sample_text);
                break;
            };
            try assign(settings, init.gpa, path, sample, failure);
        } else {
            var sample: []const u8 = "null";
            for (hs.leaves) |leaf| if (matches(leaf.pattern, path)) {
                sample = leaf.sample_text;
                break;
            };
            try assign(settings, init.gpa, path, sample, failure);
        }
        remove(&document, path);
    }
    const bytes = try encoded(gpa, document);
    if (bytes.len > hs.max_document_bytes) return invalid(failure, "settings", "saved document exceeds the document byte bound");
    settings.deinit();
    try hs.apply(settings, init.gpa, bytes, .file, checkPreset, failure);
    const target = try savedPath(init, gpa, dir);
    const parent = std.fs.path.dirname(target).?;
    var directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, parent, .{ .permissions = .fromMode(0o700) });
    directory.close(init.io);
    credentials.publishPrivate(target, bytes) catch return invalid(failure, "settings", "host.json requires a writable private Host directory");
}

pub fn showSaved(init: std.process.Init, dir: []const u8, out: *std.Io.Writer, failure: *start_report.Failure) !void {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    const document = try saved(init, memory.allocator(), dir, settings, failure);
    if (!document.object.contains("providers")) try defaultProviders(init, settings, failure);
    try hs.write(settings, out);
    try out.writeByte('\n');
}

pub fn listPaths(out: *std.Io.Writer) !void {
    for (hs.leaves) |leaf| try out.print("{s}\t{s}\t{s}\t{s}\n", .{ leaf.pattern, leaf.kind, leaf.default, leaf.doc });
}

/// Defaults are product policy, derived from provider-owned credential and
/// model-list facts: catalog sign-ins serve signed out, live providers need a
/// usable local credential. An invalid API base URL warns and omits that route.
fn defaultProviders(init: std.process.Init, settings: *hs.Settings, failure: *start_report.Failure) !void {
    try assign(settings, init.gpa, "providers", "{}", failure);
    inline for (std.enums.values(protocol.Provider)) |provider| {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const usable = switch (comptime provider.facts().credential) {
            .sign_in => if (comptime provider.facts().model_list == .catalog) true else usable: {
                const path = provider_login.credentialPath(init, provider, &path_buffer, false) catch break :usable false;
                const status = codex_auth.localStatus(path, codex_auth.nowSeconds(init.io)) catch break :usable false;
                break :usable status == .configured or status == .renewal_due;
            },
            .api_key => usable: {
                const path = api_key.path(init.environ_map, &path_buffer) catch break :usable false;
                break :usable api_key.present(path) catch false;
            },
        };
        if (usable) serve: {
            const at = "providers." ++ @tagName(provider);
            if (comptime provider.facts().credential == .api_key) {
                if (init.environ_map.get(providers.openai_base_url_variable)) |base| {
                    const endpoint = providers.endpointUnder(init.gpa, base) catch |err| {
                        if (err != error.InvalidBaseUrl) return err;
                        stderr.diagnostic(@import("host_launch.zig").invalid_base_url ++ "; this Host starts without {s}.\n", .{provider.shown()});
                        break :serve;
                    };
                    defer init.gpa.free(endpoint);
                    try text(settings, init.gpa, at ++ ".endpoint", endpoint, failure);
                    break :serve;
                }
            }
            try assign(settings, init.gpa, at, "{}", failure);
        }
    }
}

pub fn fillAt(init: std.process.Init, parsed: *const cli_args.Parsed, dir: []const u8, settings: *hs.Settings, fixtures: *providers.Fixtures, failure: *start_report.Failure) !void {
    if (parsed.get("test-codex-fixture-endpoint") != null and init.environ_map.get("RUI_CODEX_CREDENTIAL_FILE") == null) return error.FixtureCredentialPathRequired;
    if (parsed.get("test-chatgpt-fixture-endpoint") != null and init.environ_map.get("RUI_CHATGPT_CREDENTIAL_FILE") == null) return error.FixtureCredentialPathRequired;
    if (parsed.get("test-openai-fixture-endpoint") != null and init.environ_map.get(api_key.path_variable) == null) return error.FixtureCredentialPathRequired;
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const document = try saved(init, gpa, dir, settings, failure);
    var explicit_providers = document == .object and document.object.contains("providers");
    if (parsed.get("settings")) |source| explicit_providers = (try readDocumentAt(init, source, settings, failure)) or explicit_providers;
    for (parsed.all("set")) |assignment| {
        const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return invalid(failure, "settings", "--set requires PATH=VALUE");
        const path = assignment[0..equals];
        const selects_providers = std.mem.eql(u8, path, "providers") or std.mem.startsWith(u8, path, "providers.");
        if (selects_providers and !explicit_providers) try assign(settings, init.gpa, "providers", "{}", failure);
        try input(init, settings, path, assignment[equals + 1 ..], failure);
        if (selects_providers) explicit_providers = true;
    }
    if (!explicit_providers) try defaultProviders(init, settings, failure);
    try fixtureInputs(init, parsed, settings, fixtures, failure);
    // --store is an interface anchor for MySQL, never a SQLite Adapter override.
    if (settings.store == .mysql and settings.interface.dir.anchored and parsed.get("store") != null) {
        var canonical: [protocol.max_store_bytes]u8 = undefined;
        try text(settings, init.gpa, "interface.dir", try platform.canonicalStoreDestination(init.io, dir, &canonical), failure);
    }
}

/// A private, empty Host directory: tests must not read the checkout's cwd.
fn testHostDir(tmp: *std.testing.TmpDir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    var host = try tmp.dir.createDirPathOpen(std.testing.io, "host-dir", .{ .permissions = .fromMode(0o700) });
    defer host.close(std.testing.io);
    return buffer[0..try host.realPath(std.testing.io, buffer)];
}

fn fixtureInputs(init: std.process.Init, parsed: *const cli_args.Parsed, settings: *hs.Settings, fixtures: *providers.Fixtures, failure: *start_report.Failure) !void {
    const gpa = init.gpa;
    if (parsed.get("test-openai-fixture-endpoint")) |endpoint| {
        try text(settings, gpa, "providers.openai.endpoint", endpoint, failure);
        try assign(settings, gpa, "providers.openai.unauthenticated", "true", failure);
        fixtures.openai = true;
    }
    if (parsed.get("test-codex-fixture-endpoint")) |endpoint| {
        try text(settings, gpa, "providers.codex.endpoint", endpoint, failure);
        try assign(settings, gpa, "providers.codex.unauthenticated", "true", failure);
        fixtures.codex = true;
    }
    if (parsed.get("test-chatgpt-fixture-endpoint")) |endpoint| {
        const base = providers.responsesBase(endpoint) orelse return error.InvalidArguments;
        try text(settings, gpa, "providers.chatgpt.endpoint", endpoint, failure);
        try assign(settings, gpa, "providers.chatgpt.unauthenticated", "true", failure);
        fixtures.chatgpt_token_endpoint = try std.fmt.allocPrint(init.arena.allocator(), "{s}/oauth/token", .{base});
    }
}

fn invalid(failure: *start_report.Failure, comptime path: []const u8, comptime reason: []const u8) error{SettingsInvalid} {
    failure.* = .init(.settings_invalid, path ++ ": " ++ reason);
    return error.SettingsInvalid;
}

/// A pipe carries a four-byte big-endian length followed by exactly one JSON
/// document. Reading it never chooses the Host's lifetime.
pub noinline fn readDocument(init: std.process.Init, source: []const u8, settings: *hs.Settings, failure: *start_report.Failure) !void {
    _ = try readDocumentAt(init, source, settings, failure);
}

fn readDocumentAt(init: std.process.Init, source: []const u8, settings: *hs.Settings, failure: *start_report.Failure) !bool {
    if (std.mem.eql(u8, source, "-")) return readPipeAt(init, .stdin(), settings, failure);
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const gpa = memory.allocator();
    const buffer = try gpa.alloc(u8, hs.max_document_bytes + 1);
    var cwd: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = if (std.fs.path.isAbsolute(source)) source else try std.fs.path.join(gpa, &.{ cwd[0..try std.Io.Dir.cwd().realPath(init.io, &cwd)], source });
    const bytes = credentials.readPrivate(path, buffer) catch return invalid(failure, "settings", "must be a readable private file within the document byte bound");
    const document = bytes orelse return invalid(failure, "settings", "file does not exist");
    try hs.apply(settings, init.gpa, document, .file, checkPreset, failure);
    const json = try parse(gpa, document, failure);
    return json.object.contains("providers");
}

fn readPipe(init: std.process.Init, file: std.Io.File, settings: *hs.Settings, failure: *start_report.Failure) !void {
    _ = try readPipeAt(init, file, settings, failure);
}

fn readPipeAt(init: std.process.Init, file: std.Io.File, settings: *hs.Settings, failure: *start_report.Failure) !bool {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    var prefix: [4]u8 = undefined;
    readExact(init.io, file, &prefix) catch return invalid(failure, "settings", "stdin closed before the 4-byte document length");
    const length = std.mem.readInt(u32, &prefix, .big);
    if (length == 0 or length > hs.max_document_bytes) return invalid(failure, "settings", "document length must be 1 to 1048576 bytes");
    const bytes = try memory.allocator().alloc(u8, length);
    readExact(init.io, file, bytes) catch return invalid(failure, "settings", "stdin closed before the whole document arrived");
    try hs.apply(settings, init.gpa, bytes, .pipe, checkPreset, failure);
    const json = try parse(memory.allocator(), bytes, failure);
    return json.object.contains("providers");
}

fn readExact(io: std.Io, file: std.Io.File, buffer: []u8) !void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const count = try file.readStreaming(io, &.{buffer[filled..]});
        if (count == 0) return error.EndOfStream;
        filled += count;
    }
}

/// Only the CLI calls this publisher. Both reports are attempted even if the
/// other stream is closed; messages are the bounded, redacted owner values.
pub noinline fn report(io: std.Io, failure: *const start_report.Failure) void {
    var buffer: [start_report.max_line_bytes]u8 = undefined;
    std.Io.File.stdout().writeStreamingAll(io, start_report.line(failure, &buffer)) catch {};
    const sentence = std.fmt.bufPrint(&buffer, "rui: the Host did not start: {f} [{s}]\n", .{ std.zig.fmtString(failure.message.slice()), @tagName(failure.code) }) catch unreachable;
    std.Io.File.stderr().writeStreamingAll(io, sentence) catch {};
}

/// Anchor, resolve each served secret, then issue the proof. No environment map
/// reaches server. Saved sign-ins stay file sources: their Adapter owns leasing.
pub fn prepare(init: std.process.Init, settings: *hs.Settings, fixtures: providers.Fixtures, failure: *start_report.Failure) !hs.Prepared {
    var cwd: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (settings.store == .mysql and settings.interface.dir.anchored) return invalid(failure, "interface.dir", "MySQL requires an explicit private interface directory");
    hs.anchor(settings, cwd[0..try std.Io.Dir.cwd().realPath(init.io, &cwd)]) catch return invalid(failure, "store.sqlite.dir", "Host directory exceeds the path byte bound");
    try resolveProviders(init, settings, fixtures, failure);
    if (settings.store == .mysql) resolve(init, &settings.store.mysql.url) catch |err| return resolutionFailure(failure, "store.mysql.url", err);
    for (settings.tools.mcp.names[0..settings.tools.mcp.len], settings.tools.mcp.values[0..settings.tools.mcp.len]) |*name, *server| {
        resolve(init, &server.bearer_token) catch |err| {
            var path_buffer: [128]u8 = undefined;
            return resolutionFailure(failure, try std.fmt.bufPrint(&path_buffer, "tools.mcp.{s}.bearerToken", .{name.slice()}), err);
        };
    }
    return hs.seal(settings, failure);
}

/// Provider/proxy preflight precedes Store selection just as today's CLI does.
/// prepare reuses this owner after anchoring; resolved bytes/paths are not read twice.
pub fn resolveProviders(init: std.process.Init, settings: *hs.Settings, fixtures: providers.Fixtures, failure: *start_report.Failure) !void {
    inline for (std.enums.values(protocol.Provider)) |provider| {
        if (@field(settings.providers.entries, @tagName(provider))) |*entry| {
            switch (comptime provider.facts().credential) {
                .api_key => if (!entry.unauthenticated.value or fixtures.openai) {
                    if (entry.key.source == .default) {
                        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const path = api_key.path(init.environ_map, &path_buffer) catch |err| return resolutionFailure(failure, "providers." ++ @tagName(provider) ++ ".key", err);
                        entry.key.source = .{ .file = .{} };
                        entry.key.source.file.text.set(path) catch |err| return resolutionFailure(failure, "providers." ++ @tagName(provider) ++ ".key", err);
                    }
                    resolve(init, &entry.key) catch |err| return resolutionFailure(failure, "providers." ++ @tagName(provider) ++ ".key", err);
                },
                .sign_in => if (!entry.unauthenticated.value or (provider == .codex and fixtures.codex) or (provider == .chatgpt and fixtures.chatgpt_token_endpoint != null)) {
                    if (entry.credential_file == null) {
                        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const path = provider_login.credentialPath(init, provider, &path_buffer, false) catch |err| return resolutionFailure(failure, "providers." ++ @tagName(provider) ++ ".credentialFile", err);
                        entry.credential_file = .{};
                        entry.credential_file.?.text.set(path) catch |err| return resolutionFailure(failure, "providers." ++ @tagName(provider) ++ ".credentialFile", err);
                    }
                },
            }
        }
    }
}

fn resolutionFailure(failure: *start_report.Failure, path: []const u8, err: anyerror) anyerror {
    if (err == error.OutOfMemory) return err;
    failure.code = .settings_invalid;
    const message = std.fmt.bufPrint(&failure.message.bytes, "{s}: credential source is missing, unreadable, insecure or invalid", .{path}) catch unreachable;
    failure.message.len = message.len;
    return error.SettingsInvalid;
}

fn resolve(init: std.process.Init, secret: anytype) !void {
    const Secret = @typeInfo(@TypeOf(secret)).pointer.child;
    if (secret.source == .literal) return;
    if (comptime Secret.default_source == .mysql) {
        if (secret.bytes.parsed != null) return;
    } else if (secret.bytes.len != 0) return;
    const buffer = try init.arena.allocator().alloc(u8, if (Secret.default_source == .mysql) hs.max_document_bytes + 2 else api_key.max_key_bytes + 2);
    defer {
        std.crypto.secureZero(u8, buffer);
        init.arena.allocator().free(buffer);
    }
    const bytes = switch (secret.source) {
        .literal => unreachable,
        .default => return error.ApiKeyMissing,
        .env => |*name| init.environ_map.get(name.slice()) orelse return error.ApiKeyMissing,
        .file => |*file| api_key.trimNewline(try credentials.readPrivate(file.slice(), buffer) orelse return error.ApiKeyMissing),
    };
    if (Secret.default_source == .mysql) {
        try secret.bytes.set(init.arena.allocator(), bytes);
    } else {
        if (!api_key.valid(bytes)) return error.InvalidApiKey;
        secret.bytes.wipe();
        @memcpy(secret.bytes.bytes[0..bytes.len], bytes);
        secret.bytes.len = bytes.len;
    }
}

/// The Host directory anchors MySQL's interface without changing its Adapter.
pub noinline fn selectStore(init: std.process.Init, settings: *hs.Settings, selected: []const u8, from_document: bool, failure: *start_report.Failure) !void {
    _ = from_document;
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const value = platform.canonicalStoreDestination(init.io, selected, &canonical) catch |err| switch (err) {
        error.StorePathTooLong, error.NameTooLong => return invalid(failure, "store.sqlite.dir", "canonical path exceeds the Store byte bound"),
        else => return err,
    };
    if (settings.store == .mysql) {
        if (settings.interface.dir.anchored) try text(settings, init.gpa, "interface.dir", value, failure);
    } else try text(settings, init.gpa, "store.sqlite.dir", value, failure);
}

pub fn shutdownPolicy(settings: *const hs.Settings) ShutdownPolicy {
    return settings.interface.lifetime.value;
}

pub fn storeKind(settings: *const hs.Settings) start_report.Store {
    return if (settings.store == .mysql) .mysql else .sqlite;
}

/// Shared --check/serve pipeline. The caller selects the Host directory using
/// platform policy; an explicit document Adapter keeps its own Store location.
pub fn admit(init: std.process.Init, parsed: *const cli_args.Parsed, dir: []const u8, settings: *hs.Settings, fixtures: *providers.Fixtures, failure: *start_report.Failure) !hs.Prepared {
    try fillAt(init, parsed, dir, settings, fixtures, failure);
    try resolveProviders(init, settings, fixtures.*, failure);
    const served = providers.fromSettings(settings, fixtures.*);
    if (try served.proxyRefusal(init.gpa)) |reason| {
        failure.code = .settings_invalid;
        const message = try std.fmt.bufPrint(&failure.message.bytes, "network: https_proxy/HTTPS_PROXY {s}; Rui tunnels only through an http:// proxy", .{reason});
        failure.message.len = message.len;
        return error.UnsupportedProxyScheme;
    }
    if (settings.store == .sqlite) {
        if (settings.store.sqlite.dir.anchored) {
            try selectStore(init, settings, dir, false, failure);
        }
    }
    return prepare(init, settings, fixtures.*, failure);
}

fn parseForTest(gpa: std.mem.Allocator, args: []const []const u8) !cli_args.Parsed {
    var problem: cli_args.Refusal = undefined;
    return cli_args.Command.host_serve.definition().parse(args, gpa, &problem);
}

fn initForTest(arena: *std.heap.ArenaAllocator, env: *std.process.Environ.Map) std.process.Init {
    return .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = env, .preopens = .empty };
}

test "Host start resolves environment private file and saved credential sources" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("HOST_START_TEST_\xff", "env-key");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try hs.apply(settings, gpa, "{\"providers\":{}}", .file, checkPreset, &failure);
    try assign(settings, gpa, "providers.openai.key", "env:HOST_START_TEST_\xff", &failure);
    _ = try prepare(init, settings, .{}, &failure);
    try std.testing.expectEqualStrings("env-key", settings.providers.entries.openai.?.key.value());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(std.testing.io, "private", .{ .permissions = .fromMode(0o700) });
    defer private.close(std.testing.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // APFS rejects malformed UTF-8 filenames, so the created file uses valid UTF-8.
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/private/openai.key", .{root[0..try tmp.dir.realPath(std.testing.io, &root)]});
    try api_key.install(path, "file-key");
    try assign(settings, arena.allocator(), "providers.openai.key", "null", &failure);
    try environment.put(api_key.path_variable, path);
    try environment.put("RUI_CODEX_CREDENTIAL_FILE", "/tmp/./codex-\xff.json");
    try environment.put("RUI_CHATGPT_CREDENTIAL_FILE", "/tmp/./chatgpt-\xff.json");
    try assign(settings, arena.allocator(), "providers.codex", "{}", &failure);
    try assign(settings, arena.allocator(), "providers.chatgpt", "{}", &failure);
    _ = try prepare(init, settings, .{}, &failure);
    try std.testing.expectEqualStrings("file-key", settings.providers.entries.openai.?.key.value());
    try std.testing.expectEqualStrings(path, settings.providers.entries.openai.?.key.source.file.slice());
    try std.testing.expectEqualStrings("/tmp/./codex-\xff.json", settings.providers.entries.codex.?.credential_file.?.slice());
    try std.testing.expectEqualStrings("/tmp/./chatgpt-\xff.json", settings.providers.entries.chatgpt.?.credential_file.?.slice());
    try private.setFilePermissions(std.testing.io, "openai.key", .fromMode(0o644), .{});
    try assign(settings, arena.allocator(), "providers.openai.key", "null", &failure);
    try std.testing.expectError(error.SettingsInvalid, prepare(init, settings, .{}, &failure));
    try std.testing.expect(std.mem.startsWith(u8, failure.message.slice(), "providers.openai.key:"));
}

test "Host start canonical Store leaf accepts a long raw alias" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &env);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var private = try tmp.dir.createDirPathOpen(std.testing.io, "store", .{ .permissions = .fromMode(0o700) });
    defer private.close(std.testing.io);
    const canonical = root[0..try private.realPath(std.testing.io, &root)];
    const alias = try arena.allocator().alloc(u8, canonical.len + 540);
    @memcpy(alias[0..canonical.len], canonical);
    for (0..180) |i| @memcpy(alias[canonical.len + i * 3 ..][0..3], "/./");
    try std.testing.expect(alias.len >= 580);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try selectStore(init, settings, alias, false, &failure);
    try std.testing.expectEqualStrings(canonical, settings.store.sqlite.dir.slice());
    try savedEdit(init, alias, "execution.paused", "true", &failure);
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    try showSaved(init, alias, &shown.writer, &failure);
    const json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expect(lookup(json, "execution.paused").?.bool);
}

test "Host start pipe reads one bounded document without implying lifetime" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    const document = "{\"providers\":{\"openai\":{\"key\":{\"value\":\"pipe-key\"}}},\"tools\":{\"bash\":{\"timeoutMs\":17}}}";
    var bytes: [4 + document.len]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], document.len, .big);
    @memcpy(bytes[4..], document);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    for ([_]usize{ bytes.len, 2, 4, bytes.len - 1 }) |sent| {
        settings.* = .{};
        defer settings.deinit();
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        defer reader.close(init.io);
        const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        try writer.writeStreamingAll(init.io, bytes[0..sent]);
        writer.close(init.io);
        var failure: start_report.Failure = undefined;
        if (sent == bytes.len) {
            try readPipe(init, reader, settings, &failure);
            try std.testing.expectEqualStrings("pipe-key", settings.providers.entries.openai.?.key.value());
            try std.testing.expectEqual(@as(u64, 17), settings.tools.bash.timeout_ms.value);
            try std.testing.expectEqual(hs.Interface.Lifetime.detached, settings.interface.lifetime.value);
        } else {
            try std.testing.expectError(error.SettingsInvalid, readPipe(init, reader, settings, &failure));
            try std.testing.expectEqual(start_report.StartError.settings_invalid, failure.code);
            try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "pipe-key") == null);
        }
    }
    for ([_]u32{ 0, hs.max_document_bytes + 1, std.math.maxInt(u32) }) |length| {
        settings.* = .{};
        defer settings.deinit();
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        defer reader.close(init.io);
        const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        defer writer.close(init.io);
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, length, .big);
        try writer.writeStreamingAll(init.io, &prefix);
        var failure: start_report.Failure = undefined;
        // The writer remains open: an invalid length must not read a body.
        try std.testing.expectError(error.SettingsInvalid, readPipe(init, reader, settings, &failure));
    }
}

test "Host start private file origin refuses literal secrets and assignments override document leaves" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var host_root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var private = try tmp.dir.createDirPathOpen(init.io, "private", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/host.json", .{root[0..try private.realPath(init.io, &root)]});
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try private.writeFile(init.io, .{ .sub_path = "host.json", .data = "{\"providers\":{\"openai\":{\"key\":{\"value\":\"never-print-this\"}}}}" });
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o600), .{});
    try std.testing.expectError(error.SettingsInvalid, readDocument(init, path, settings, &failure));
    try std.testing.expectEqual(start_report.StartError.settings_invalid, failure.code);
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "providers.openai.key") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "never-print-this") == null);
    try private.writeFile(init.io, .{ .sub_path = "host.json", .data = "{\"providers\":{},\"tools\":{\"bash\":{\"timeoutMs\":17}},\"execution\":{\"activeCapacity\":3},\"interface\":{\"lifetime\":\"stdin\"}}" });
    const parsed = try parseForTest(arena.allocator(), &.{ "--settings", path, "--set", "tools.bash.timeoutMs=99", "--set", "execution.activeCapacity=4", "--set", "providers.codex={}" });
    var fixtures: providers.Fixtures = .{};
    try fillAt(init, &parsed, try testHostDir(&tmp, &host_root), settings, &fixtures, &failure);
    try std.testing.expectEqual(@as(u64, 99), settings.tools.bash.timeout_ms.value);
    try std.testing.expectEqual(@as(usize, 4), settings.execution.active_capacity.value);
    try std.testing.expectEqual(hs.Interface.Lifetime.stdin, settings.interface.lifetime.value);
    try std.testing.expect(settings.providers.entries.codex != null);
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o644), .{});
    try std.testing.expectError(error.SettingsInvalid, readDocument(init, path, settings, &failure));
}

test "Host start pipe file and assignment admissions report every code on both streams even if one refuses" {
    const Probe = struct {
        var output: [2][4096]u8 = undefined;
        var used: [2]usize = .{ 0, 0 };
        var refused: ?usize = null;
        var attempted: [2]bool = .{ false, false };
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) {
                const write = operation.file_write_streaming;
                if (write.file.handle == 1 or write.file.handle == 2) {
                    const index: usize = @intCast(write.file.handle - 1);
                    attempted[index] = true;
                    if (refused == index) return .{ .file_write_streaming = error.NoSpaceLeft };
                    var out = std.Io.Writer.fixed(output[index][used[index]..]);
                    out.writeAll(write.header) catch return .{ .file_write_streaming = error.NoSpaceLeft };
                    for (write.data, 0..) |part, i| {
                        const repeats = if (i == write.data.len - 1) write.splat else 1;
                        for (0..repeats) |_| out.writeAll(part) catch return .{ .file_write_streaming = error.NoSpaceLeft };
                    }
                    used[index] += out.buffered().len;
                    return .{ .file_write_streaming = out.buffered().len };
                }
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.operate = Probe.operate;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var host_root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var private = try tmp.dir.createDirPathOpen(init.io, "private", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(init.io);
    const document = "{\"providers\":{},\"tools\":{\"bash\":{\"timeoutMs\":17}}}";
    try private.writeFile(init.io, .{ .sub_path = "host.json", .data = document });
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o600), .{});
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/host.json", .{root[0..try private.realPath(init.io, &root)]});
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    // The publisher has no source discriminator. Exercise each actual intake
    // before the exhaustive failure matrix, rather than a second reporting path.
    for ([_]enum { pipe, file, assignments }{ .pipe, .file, .assignments }) |source| {
        settings.* = .{};
        defer settings.deinit();
        var admission_failure: start_report.Failure = undefined;
        var fixtures: providers.Fixtures = .{};
        switch (source) {
            .pipe => {
                var bytes: [4 + document.len]u8 = undefined;
                std.mem.writeInt(u32, bytes[0..4], document.len, .big);
                @memcpy(bytes[4..], document);
                var fds: [2]std.posix.fd_t = undefined;
                if (std.c.pipe(&fds) != 0) return error.PipeFailed;
                const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
                defer reader.close(init.io);
                const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
                defer writer.close(init.io);
                try writer.writeStreamingAll(init.io, &bytes);
                try readPipe(init, reader, settings, &admission_failure);
            },
            .file => {
                const parsed = try parseForTest(arena.allocator(), &.{ "--settings", path });
                try fillAt(init, &parsed, try testHostDir(&tmp, &host_root), settings, &fixtures, &admission_failure);
            },
            .assignments => {
                const parsed = try parseForTest(arena.allocator(), &.{ "--set", "tools.bash.timeoutMs=17" });
                try fillAt(init, &parsed, try testHostDir(&tmp, &host_root), settings, &fixtures, &admission_failure);
            },
        }
        try std.testing.expectEqual(@as(u64, 17), settings.tools.bash.timeout_ms.value);
        const Message = struct { raw: []const u8, json: []const u8, sentence: []const u8 };
        inline for ([_]Message{
            .{ .raw = "message", .json = "\"message\"", .sentence = "message" },
            .{ .raw = "line\n\r\t\x1b", .json = "\"line\\n\\r\\t\\u001b\"", .sentence = "line\\n\\r\\t\\x1b" },
            .{ .raw = "literal\\n\\x1b\"", .json = "\"literal\\\\n\\\\x1b\\\"\"", .sentence = "literal\\\\n\\\\x1b\\\"" },
            .{ .raw = "\u{0085}\u{2028}\u{2029}\u{feff}", .json = "\"\u{0085}\u{2028}\u{2029}\u{feff}\"", .sentence = "\\xc2\\x85\\xe2\\x80\\xa8\\xe2\\x80\\xa9\\xef\\xbb\\xbf" },
        }) |message| {
            inline for (comptime std.meta.tags(start_report.StartError)) |code| {
                for ([_]?usize{ null, 0, 1 }) |refused| {
                    Probe.used = .{ 0, 0 };
                    Probe.attempted = .{ false, false };
                    Probe.refused = refused;
                    const failure: start_report.Failure = .init(code, message.raw);
                    report(io, &failure);
                    try std.testing.expect(Probe.attempted[0] and Probe.attempted[1]);
                    if (refused != 0) try std.testing.expectEqualStrings("{\"rui_start_error\":{\"code\":\"" ++ @tagName(code) ++ "\",\"message\":" ++ message.json ++ "}}\n", Probe.output[0][0..Probe.used[0]]);
                    if (refused != 1) try std.testing.expectEqualStrings("rui: the Host did not start: " ++ message.sentence ++ " [" ++ @tagName(code) ++ "]\n", Probe.output[1][0..Probe.used[1]]);
                }
            }
        }
        // Unknown keys are diagnostic paths, not trusted terminal text. The
        // JSON line retains the message while stderr remains one safe sentence.
        try std.testing.expectError(error.SettingsInvalid, hs.apply(settings, gpa, "{\"bad\\n\\u001b\":\"never-print-this-value\"}", .pipe, checkPreset, &admission_failure));
        Probe.used = .{ 0, 0 };
        Probe.attempted = .{ false, false };
        Probe.refused = null;
        report(io, &admission_failure);
        try std.testing.expectEqualStrings("{\"rui_start_error\":{\"code\":\"settings_invalid\",\"message\":\"bad\\n\\u001b: unknown setting\"}}\n", Probe.output[0][0..Probe.used[0]]);
        try std.testing.expectEqualStrings("rui: the Host did not start: bad\\n\\x1b: unknown setting [settings_invalid]\n", Probe.output[1][0..Probe.used[1]]);
    }
}

fn concreteLeaf(gpa: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, gpa, pattern, "*", "sample");
}

fn expectJsonEqual(expected: std.json.Value, actual: std.json.Value) !void {
    const a = try encoded(std.testing.allocator, expected);
    defer std.testing.allocator.free(a);
    const b = try encoded(std.testing.allocator, actual);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "Host start every generated leaf saves shows loads and unsets to defaults" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    const effective = try gpa.create(hs.Settings);
    defer gpa.destroy(effective);
    const expected = try gpa.create(hs.Settings);
    defer gpa.destroy(expected);
    var failure: start_report.Failure = undefined;
    const parsed = try parseForTest(arena.allocator(), &.{});
    for (hs.leaves) |leaf| {
        const path = try concreteLeaf(arena.allocator(), leaf.pattern);
        errdefer std.debug.print("saved Host leaf: {s}; {s}\n", .{ path, failure.message.slice() });
        try savedEdit(init, dir, path, leaf.sample_text, &failure);
        try std.testing.expectEqual(@as(u16, 0o600), (try private.statFile(init.io, "host.json", .{})).permissions.toMode() & 0o777);
        var shown: std.Io.Writer.Allocating = .init(gpa);
        defer shown.deinit();
        try showSaved(init, dir, &shown.writer, &failure);
        const json = try parse(arena.allocator(), shown.written(), &failure);
        expected.* = .{};
        defer expected.deinit();
        try assign(expected, gpa, path, leaf.sample_text, &failure);
        const canonical = try complete(arena.allocator(), expected, &failure);
        try expectJsonEqual(lookup(canonical, path).?, lookup(json, path).?);
        effective.* = .{};
        defer effective.deinit();
        var fixtures: providers.Fixtures = .{};
        try fillAt(init, &parsed, dir, effective, &fixtures, &failure);
        const loaded = try complete(arena.allocator(), effective, &failure);
        try expectJsonEqual(lookup(canonical, path).?, lookup(loaded, path).?);
        try savedEdit(init, dir, path, null, &failure);
        shown.clearRetainingCapacity();
        try showSaved(init, dir, &shown.writer, &failure);
        const restored = try parse(arena.allocator(), shown.written(), &failure);
        const default_value: std.json.Value = if (std.mem.eql(u8, leaf.default, "null") or std.mem.eql(u8, leaf.default, "(Host directory)") or (std.mem.eql(u8, leaf.kind, "url") and leaf.default.len == 0)) .null else if (std.mem.eql(u8, leaf.kind, "count") or std.mem.eql(u8, leaf.kind, "flag")) try parse(arena.allocator(), leaf.default, &failure) else .{ .string = leaf.default };
        try expectJsonEqual(default_value, lookup(restored, path) orelse .null);
        const sparse = try private.readFileAlloc(init.io, "host.json", gpa, .limited(hs.max_document_bytes));
        defer gpa.free(sparse);
        try std.testing.expect(lookup(try parse(arena.allocator(), sparse, &failure), path) == null);
        try private.deleteFile(init.io, "host.json");
    }
    var listed: std.Io.Writer.Allocating = .init(gpa);
    defer listed.deinit();
    try listPaths(&listed.writer);
    for (hs.leaves) |leaf| try std.testing.expect(std.mem.indexOf(u8, listed.written(), leaf.pattern) != null);
}

test "Host start saved input is sparse ordered private and JSON files carry OS paths" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700), .open_options = .{ .iterate = true } });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    var failure: start_report.Failure = undefined;
    try savedEdit(init, dir, "tools.bash.timeoutMs", "17", &failure);
    try private.writeFile(init.io, .{ .sub_path = "input.json", .data = "{\"hex\":\"2f746d702fff\"}" });
    const at_file = try std.fmt.allocPrint(arena.allocator(), "@{s}/input.json", .{dir});
    try savedEdit(init, dir, "tools.bash.path", at_file, &failure);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    const document = try std.fmt.allocPrint(arena.allocator(), "{s}/override.json", .{dir});
    try private.writeFile(init.io, .{ .sub_path = "override.json", .data = "{\"tools\":{\"bash\":{\"timeoutMs\":18}}}" });
    try private.setFilePermissions(init.io, "override.json", .fromMode(0o600), .{});
    const parsed = try parseForTest(arena.allocator(), &.{ "--settings", document, "--set", "tools.bash.timeoutMs=19", "--set", "tools.bash.timeoutMs=20" });
    var fixtures: providers.Fixtures = .{};
    try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
    try std.testing.expectEqual(@as(u64, 20), settings.tools.bash.timeout_ms.value);
    try std.testing.expectEqualStrings("/tmp/\xff", settings.tools.bash.path.slice());
    // Ordinary argv paths are never guessed to be JSON.
    try savedEdit(init, dir, "tools.bash.path", "{raw-path", &failure);
    try private.writeFile(init.io, .{ .sub_path = "input.json", .data = "\"{json-path\"" });
    try savedEdit(init, dir, "tools.bash.path", at_file, &failure);
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    try showSaved(init, dir, &shown.writer, &failure);
    const json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expectEqualStrings("{json-path", lookup(json, "tools.bash.path").?.string);
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "tools.bash.timoutMs", "22", &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "tools.bash.timeoutMs") != null);
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "providers.openai.key", "{\"value\":\"never-print-secret\"}", &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "never-print-secret") == null);
    try private.writeFile(init.io, .{ .sub_path = "input.json", .data = "{\"hex\":\"00\"}" });
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "tools.bash.path", at_file, &failure));
    try private.writeFile(init.io, .{ .sub_path = "input.json", .data = "not-json-never-print-secret" });
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "tools.bash.path", at_file, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "never-print-secret") == null);
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o644), .{});
    try std.testing.expectError(error.SettingsInvalid, showSaved(init, dir, &shown.writer, &failure));
}

test "Host start explicit providers replace automatic defaults and MySQL keeps its Adapter" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    try environment.put("HOME", "/nonexistent-host-start-test-home");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700) });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    var failure: start_report.Failure = undefined;
    for ([_][]const []const u8{ &.{}, &.{ "--set", "providers={}" }, &.{ "--set", "providers.openai.unauthenticated=true" } }, 0..) |args, index| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), args);
        var fixtures: providers.Fixtures = .{};
        try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
        inline for (std.enums.values(protocol.Provider)) |provider| {
            const served = @field(settings.providers.entries, @tagName(provider)) != null;
            const wanted = if (index == 0) provider.facts().credential == .sign_in and provider.facts().model_list == .catalog else if (index == 1) false else provider.facts().credential == .api_key;
            try std.testing.expectEqual(wanted, served);
        }
    }
    settings.* = .{};
    defer settings.deinit();
    const parsed = try parseForTest(arena.allocator(), &.{ "--store", dir, "--set", "store.mysql.url=env:MYSQL_TEST_URL" });
    var fixtures: providers.Fixtures = .{};
    try fillAt(init, &parsed, dir, settings, &fixtures, &failure);
    try std.testing.expectEqual(start_report.Store.mysql, storeKind(settings));
    try std.testing.expectEqualStrings(dir, settings.interface.dir.slice());
    try selectStore(init, settings, dir, false, &failure);
    try std.testing.expectEqual(start_report.Store.mysql, storeKind(settings));
}

test "Host start refused JSON input allocations erase secret bytes before release" {
    const Observer = struct {
        child: std.mem.Allocator,
        stale: bool = false,
        frees: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.child.rawAlloc(len, alignment, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale = self.stale or std.mem.indexOf(u8, bytes, "never-release-secret") != null;
            self.frees += 1;
            self.child.rawFree(bytes, alignment, ret);
        }
    };
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var observer: Observer = .{ .child = gpa };
    var init = initForTest(&arena, &environment);
    init.gpa = observer.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700) });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    try private.writeFile(init.io, .{ .sub_path = "value.json", .data = "{\"value\":\"never-release-secret\"}" });
    const value = try std.fmt.allocPrint(arena.allocator(), "@{s}/value.json", .{dir});
    var failure: start_report.Failure = undefined;
    try std.testing.expectError(error.SettingsInvalid, savedEdit(init, dir, "providers.openai.key", value, &failure));
    try std.testing.expect(observer.frees > 0);
    try std.testing.expect(!observer.stale);
}

/// Restart callers replay generic assignments without owning setting names.
pub fn capacityAssignment(value: usize, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, hs.path("execution.activeCapacity") ++ "={d}", .{value});
}

/// Like the former argv checks, this is a pure replay check, not intake of
/// referenced documents. Document and @FILE sources remain the child's input.
pub fn validateRestartOptions(gpa: std.mem.Allocator, parsed: *const cli_args.Parsed) !void {
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    for (parsed.all("set")) |assignment| {
        const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return error.UnsupportedHostConfiguration;
        const value = assignment[equals + 1 ..];
        if (std.mem.startsWith(u8, value, "@")) continue;
        assign(settings, gpa, assignment[0..equals], value, &failure) catch return error.UnsupportedHostConfiguration;
    }
    if (!std.fs.path.isAbsolute(settings.tools.bash.path.slice())) return error.UnsupportedHostConfiguration;
    if (settings.network.ca_file) |*ca| if (!std.fs.path.isAbsolute(ca.slice())) return error.UnsupportedHostConfiguration;
}

test "Host start unset retains exact provider sets and selected Store arms" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try tmp.dir.createDirPathOpen(init.io, "host", .{ .permissions = .fromMode(0o700) });
    defer private.close(init.io);
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = root[0..try private.realPath(init.io, &root)];
    var failure: start_report.Failure = undefined;
    try savedEdit(init, dir, "providers.openai.endpoint", "https://example.test/responses", &failure);
    try savedEdit(init, dir, "providers.openai.endpoint", null, &failure);
    var shown: std.Io.Writer.Allocating = .init(gpa);
    defer shown.deinit();
    try showSaved(init, dir, &shown.writer, &failure);
    var json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expect(lookup(json, "providers.openai") != null);
    try std.testing.expect(lookup(json, "providers.codex") == null);
    try savedEdit(init, dir, "providers.openai", null, &failure);
    shown.clearRetainingCapacity();
    try showSaved(init, dir, &shown.writer, &failure);
    json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expect(lookup(json, "providers") != null);
    inline for (std.enums.values(protocol.Provider)) |provider| try std.testing.expect(lookup(json, "providers." ++ @tagName(provider)) == null);
    try savedEdit(init, dir, "store.mysql.url", "env:MYSQL_TEST_URL", &failure);
    try savedEdit(init, dir, "store.mysql.url", null, &failure);
    shown.clearRetainingCapacity();
    try showSaved(init, dir, &shown.writer, &failure);
    json = try parse(arena.allocator(), shown.written(), &failure);
    try std.testing.expect(lookup(json, "store.mysql") != null);
    try std.testing.expect(lookup(json, "store.sqlite") == null);
}

test "Host start restart projections preserve path refusals and ordered generic overrides" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_][]const u8{ "tools.bash.path", "network.caFile" }) |path| {
        const relative = try std.fmt.allocPrint(arena.allocator(), "{s}=relative/path", .{path});
        const absolute = try std.fmt.allocPrint(arena.allocator(), "{s}=/absolute/path", .{path});
        const refused = try parseForTest(arena.allocator(), &.{ "--set", relative });
        try std.testing.expectError(error.UnsupportedHostConfiguration, validateRestartOptions(gpa, &refused));
        const accepted = try parseForTest(arena.allocator(), &.{ "--set", relative, "--set", absolute });
        try validateRestartOptions(gpa, &accepted);
    }
    var buffer: [128]u8 = undefined;
    const assignment = try capacityAssignment(3, &buffer);
    const parsed = try parseForTest(arena.allocator(), &.{ "--set", assignment });
    try validateRestartOptions(gpa, &parsed);
}

// ---- One detached starter ----------------------------------------------------
const HostLaunchResult = @import("host_launch.zig").Result;
extern "c" fn rui_launch_detached_reported(executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize, startup_read: *c_int, report_read: *c_int) c_int;
pub const Progress = struct { context: *anyopaque, report: *const fn (*anyopaque, []const u8) void };
/// `settings_file` is an absolute FILE; a pipe document cannot reach a detached child.
pub const Spawn = struct { dir: []const u8, settings_file: ?[]const u8 = null, assignments: []const []const u8 = &.{} };
pub const Ops = struct {
    context: ?*anyopaque = null,
    observe: *const fn (?*anyopaque, std.Io, *const platform.Paths, ?i128) @import("protocol_reply.zig").HostStatus = nativeObserve,
    launch: *const fn (?*anyopaque, [*:0]const u8, [*:null]const ?[*:0]const u8, usize, *c_int, *c_int) c_int = nativeLaunch,
    read: *const fn (?*anyopaque, c_int, []u8) isize = nativeRead,
    now: *const fn (?*anyopaque, std.Io) i96 = nativeNow,
    pause: *const fn (?*anyopaque, std.Io, u64) anyerror!void = nativePause,

    fn nativeObserve(_: ?*anyopaque, io: std.Io, paths: *const platform.Paths, until: ?i128) @import("protocol_reply.zig").HostStatus {
        return @import("client.zig").hostStatusAt(io, paths, until);
    }
    fn nativeLaunch(_: ?*anyopaque, executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, argc: usize, startup_read: *c_int, report_read: *c_int) c_int {
        return rui_launch_detached_reported(executable, argv, argc, startup_read, report_read);
    }
    fn nativeRead(_: ?*anyopaque, fd: c_int, bytes: []u8) isize {
        return std.c.read(fd, bytes.ptr, bytes.len);
    }
    fn nativeNow(_: ?*anyopaque, io: std.Io) i96 {
        return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    }
    fn nativePause(_: ?*anyopaque, io: std.Io, ns: u64) !void {
        try std.Io.sleep(io, .fromNanoseconds(ns), .awake);
    }
};

pub fn launchFailure(result: *HostLaunchResult, kind: HostLaunchResult.Cause.Kind, err: anyerror, store: ?[]const u8) void {
    result.outcome = .{ .failed = .{ .cause = .{ .kind = kind, .err = err }, .store = .{ .len = 0 } } };
    // A non-null path came from validated platform.Paths, not user bytes.
    if (store) |canonical| result.outcome.failed.store.set(canonical) catch unreachable;
}

pub fn launchReady(result: *HostLaunchResult, ready: @import("protocol_reply.zig").HostInfoFacts, paths: *const platform.Paths) void {
    result.outcome = .{ .ready = .{ .facts = ready, .diagnostics_directory = .{ .len = 0 } } };
    result.outcome.ready.diagnostics_directory.set(paths.diagnosticsDirectory()) catch unreachable;
}

const moved = "bare rui and rui host start reach only a Host that listens in its Host directory; start this one with rui host serve --store DIR";

/// Read source descriptions only: no secret is resolved and no login made.
/// A Host whose settings listen elsewhere could start but never be reached
/// through `dir`, so the starter refuses it before launching anything.
pub fn checkReachable(init: std.process.Init, dir: []const u8, request: Spawn, failure: *start_report.Failure) !void {
    var wiping: secret_value.WipingAllocator = .{ .backing = init.gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const settings = try init.gpa.create(hs.Settings);
    defer init.gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    _ = try saved(init, memory.allocator(), dir, settings, failure);
    if (request.settings_file) |file| _ = try readDocumentAt(init, file, settings, failure);
    for (request.assignments) |assignment| {
        const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return invalid(failure, "settings", "--set requires PATH=VALUE");
        try input(init, settings, assignment[0..equals], assignment[equals + 1 ..], failure);
    }
    if (settings.store == .mysql) return invalid(failure, "store.mysql", moved);
    if (!settings.interface.dir.anchored) return invalid(failure, "interface.dir", moved);
    if (!settings.store.sqlite.dir.anchored) {
        var host: [protocol.max_store_bytes]u8 = undefined;
        var chosen: [protocol.max_store_bytes]u8 = undefined;
        const a = try platform.canonicalStoreDestination(init.io, dir, &host);
        const b = platform.canonicalStoreDestination(init.io, settings.store.sqlite.dir.slice(), &chosen) catch return invalid(failure, "store.sqlite.dir", moved);
        if (!std.mem.eql(u8, a, b)) return invalid(failure, "store.sqlite.dir", moved);
    }
}

pub noinline fn spawn(init: std.process.Init, request: Spawn, ops: Ops, progress: ?Progress, result: *HostLaunchResult) void {
    const selected = request.dir;
    const io = init.io;
    const selection = platform.resolveClientSelection(selected);
    const resolved: ?platform.Paths = selection.paths(io) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return launchFailure(result, .store_access, error.StoreAccessFailed, null),
    };
    switch (if (resolved) |*paths| ops.observe(ops.context, io, paths, null) else @as(@import("protocol_reply.zig").HostStatus, .unavailable)) {
        .ready => |ready| return launchReady(result, ready, &resolved.?),
        .incompatible => return launchFailure(result, .incompatible, error.IncompatibleHost, null),
        .access_failure => return launchFailure(result, .store_access, error.StoreAccessFailed, null),
        .unavailable, .owned_unavailable => {},
    }
    // Opaque MySQL selections can only attach; they carry no launch login.
    if (selection == .mysql) return launchFailure(result, .mysql_unavailable, error.MysqlHostUnavailable, null);
    var dir = std.Io.Dir.cwd().createDirPathOpen(io, selected, .{ .permissions = .fromMode(0o700) }) catch |err| return launchFailure(result, .setup, err, null);
    dir.close(io);
    const paths = resolved orelse (selection.paths(io) catch |err| return launchFailure(result, .store_access, err, null));
    var reach_failure: start_report.Failure = .init(.settings_invalid, "settings: could not be read");
    checkReachable(init, paths.store.slice(), request, &reach_failure) catch |err| {
        launchFailure(result, .child_refused, if (err == error.SettingsInvalid) error.HostStartupFailed else err, paths.store.slice());
        result.outcome.failed.refusal = reach_failure;
        result.outcome.failed.cause.refusal_code = reach_failure.code;
        return;
    };
    var executable_buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const length = std.process.executablePath(io, &executable_buffer) catch |err| return launchFailure(result, .setup, err, paths.store.slice());
    if (length == executable_buffer.len) return launchFailure(result, .setup, error.ExecutablePathTooLong, paths.store.slice());
    executable_buffer[length] = 0;
    const gpa = std.heap.c_allocator;
    const first: usize = if (request.settings_file == null) 5 else 7;
    const argc = first + 2 * request.assignments.len;
    const argv = gpa.allocSentinel(?[*:0]const u8, argc, null) catch |err| return launchFailure(result, .setup, err, paths.store.slice());
    defer gpa.free(argv);
    argv[0] = @ptrCast(&executable_buffer);
    argv[1] = "host";
    argv[2] = "serve";
    argv[3] = "--store";
    const directory = gpa.dupeSentinel(u8, paths.store.slice(), 0) catch |err| return launchFailure(result, .setup, err, paths.store.slice());
    defer gpa.free(directory);
    argv[4] = directory.ptr;
    const settings_file = if (request.settings_file) |file| gpa.dupeSentinel(u8, file, 0) catch |err| return launchFailure(result, .setup, err, paths.store.slice()) else null;
    defer if (settings_file) |file| gpa.free(file);
    if (settings_file) |file| {
        argv[5] = "--settings";
        argv[6] = file.ptr;
    }
    var owned: usize = 0;
    defer for (0..owned) |index| {
        const value = std.mem.span(argv[first + 1 + index * 2].?);
        std.crypto.secureZero(u8, @constCast(value));
        gpa.free(value[0..value.len :0]);
    };
    for (request.assignments, 0..) |assignment, index| {
        argv[first + index * 2] = "--set";
        const value = gpa.dupeSentinel(u8, assignment, 0) catch |err| return launchFailure(result, .setup, err, paths.store.slice());
        argv[first + 1 + index * 2] = value.ptr;
        owned += 1;
    }
    var startup_read: c_int = -1;
    var report_read: c_int = -1;
    const launched = ops.launch(ops.context, argv[0].?, argv.ptr, argc, &startup_read, &report_read);
    defer if (report_read >= 0) {
        _ = std.c.close(report_read);
    };
    var report_bytes: [HostLaunchResult.max_startup_bytes]u8 = undefined;
    var report_len: usize = 0;
    var refusal: ?start_report.Failure = null;
    defer if (startup_read >= 0) {
        _ = std.c.close(startup_read);
    };
    if (launched != 0) {
        launchFailure(result, .os_launch, error.HostLaunchFailed, paths.store.slice());
        result.outcome.failed.os_error = launched;
        return;
    }
    result.wait = .init(ops.now(ops.context, io));
    while (!result.wait.?.expired(ops.now(ops.context, io))) {
        if (refusal == null and report_len < report_bytes.len) {
            const read = ops.read(ops.context, report_read, report_bytes[report_len..]);
            if (read > 0) report_len += @intCast(read);
            var lines = std.mem.splitScalar(u8, report_bytes[0..report_len], '\n');
            var offset: usize = 0;
            while (lines.next()) |line_bytes| {
                const end = offset + line_bytes.len + 1;
                if (end > report_len) break;
                if (start_report.parseLine(gpa, report_bytes[offset..end]) catch |err| return launchFailure(result, .setup, err, paths.store.slice())) |failure| {
                    refusal = failure;
                    break;
                }
                offset = end;
            }
        }
        const count = ops.read(ops.context, startup_read, result.startup_bytes[result.startup_len..]);
        if (count > 0) result.startup_len += @intCast(count);
        const now = ops.now(ops.context, io);
        result.wait.?.observe(result.startup(), now);
        const until: i128 = result.wait.?.until(now);
        if (progress) |hook| hook.report(hook.context, result.startup());
        if ((refusal != null and refusal.?.code != .store_locked) or count == 0 or result.startup_len == HostLaunchResult.max_startup_bytes or report_len == report_bytes.len) {
            // A candidate's refusal cannot hide another ready owner.
            if (ops.observe(ops.context, io, &paths, until) != .ready) {
                if (refusal) |failure| {
                    launchFailure(result, if (failure.code == .store_schema_behind) .store_format else if (failure.code == .store_fenced) .store_identity else .child_refused, if (failure.code == .store_fenced) error.StoreIdentityMismatch else error.HostStartupFailed, paths.store.slice());
                    result.outcome.failed.refusal = failure;
                    result.outcome.failed.cause.refusal_code = failure.code;
                    return;
                }
                if (result.startup_len == HostLaunchResult.max_startup_bytes or report_len == report_bytes.len) return launchFailure(result, .startup_full, error.HostReadinessUnconfirmed, paths.store.slice());
                // SQLite Store refusals are caller errors, not start-report
                // lines; their stable code ends the child's stderr.
                if (std.mem.endsWith(u8, result.startup(), "[store_identity_mismatch]\n")) return launchFailure(result, .store_identity, error.StoreIdentityMismatch, paths.store.slice());
                if (std.mem.endsWith(u8, result.startup(), "[store_format_unsupported]\n")) return launchFailure(result, .store_format, error.HostStartupFailed, paths.store.slice());
                return launchFailure(result, if (result.startup_len == 0) .child_closed else .child_refused, error.HostStartupFailed, paths.store.slice());
            }
        }
        switch (ops.observe(ops.context, io, &paths, until)) {
            .ready => |ready| {
                // Collect any write racing readiness, without waiting for it.
                const final_count = ops.read(ops.context, startup_read, result.startup_bytes[result.startup_len..]);
                if (final_count > 0) result.startup_len += @intCast(final_count);
                result.wait.?.observe(result.startup(), ops.now(ops.context, io));
                if (refusal != null and refusal.?.code == .store_locked) result.startup_len = 0;
                if (std.mem.indexOf(u8, result.startup(), @import("host_launch.zig").invalid_base_url) != null) result.warning = .invalid_openai_base_url;
                return launchReady(result, ready, &paths);
            },
            .incompatible => return launchFailure(result, .incompatible, error.IncompatibleHost, paths.store.slice()),
            .access_failure => return launchFailure(result, .store_access, error.StoreAccessFailed, paths.store.slice()),
            .unavailable, .owned_unavailable => {},
        }
        const remaining = until - ops.now(ops.context, io);
        if (remaining > 0) ops.pause(ops.context, io, @intCast(@min(remaining, 100 * std.time.ns_per_ms))) catch |err| return launchFailure(result, .interrupted, err, paths.store.slice());
    }
    return launchFailure(result, .readiness_timeout, error.HostReadinessUnconfirmed, paths.store.slice());
}
