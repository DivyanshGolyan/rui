//! Document intake and compatibility shell for today's serve flags. The Host
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
const caller_error = @import("caller_error.zig");
const stderr = @import("stderr.zig");

// Only bounded flag values are listed here. Provider labels are a closed enum
// owned by the argv grammar; settings is a source switch, not a value leaf.
const FlagLeaf = struct { flag: []const u8, leaf: hs.Leaf, normalized: bool = false, direct: bool = false };
fn flagLeaf(comptime name: []const u8, comptime path: []const u8, comptime normalized: bool, comptime direct: bool) FlagLeaf {
    for (hs.leaves) |leaf| if (std.mem.eql(u8, path, leaf.pattern)) return .{ .flag = name, .leaf = leaf, .normalized = normalized, .direct = direct };
    @compileError("flag must name a derived settings leaf");
}
pub const flag_leaves = .{
    flagLeaf("store", "store.sqlite.dir", true, false),
    flagLeaf("store-hex", "store.sqlite.dir", true, false),
    flagLeaf("bash-path", "tools.bash.path", false, true),
    flagLeaf("provider-ca-file", "network.caFile", false, true),
    flagLeaf("bash-timeout-ms", "tools.bash.timeoutMs", false, false),
    flagLeaf("active-capacity", "execution.activeCapacity", false, false),
    flagLeaf("provider-endpoint", "providers.codex.endpoint", false, false),
    flagLeaf("test-codex-fixture-endpoint", "providers.codex.endpoint", false, false),
    flagLeaf("test-openai-fixture-endpoint", "providers.openai.endpoint", false, false),
    flagLeaf("test-chatgpt-fixture-endpoint", "providers.chatgpt.endpoint", false, false),
};
fn flagPath(comptime name: []const u8) []const u8 {
    inline for (flag_leaves) |entry| if (comptime std.mem.eql(u8, name, entry.flag)) return entry.leaf.pattern;
    @compileError("unknown leaf flag");
}

/// One classification/rendering owner. Only the static flag and derived bound
/// enter the caller error; never argv bytes, even when they contain secrets.
fn flagProblem(entry: FlagLeaf, value: []const u8, reason: *[128]u8) ?cli_args.Refusal {
    const schema = entry.leaf.json_schema;
    const message = if (schema.max_bytes) |limit| blk: {
        if (value.len <= limit) return null;
        break :blk std.fmt.bufPrint(reason, "not longer than {d} bytes", .{limit}) catch unreachable;
    } else blk: {
        const number = std.fmt.parseInt(u64, value, 10) catch break :blk std.fmt.bufPrint(reason, "an integer from {d} through {d}", .{ schema.min.?, schema.max.? }) catch unreachable;
        if (number >= schema.min.? and number <= schema.max.?) return null;
        break :blk std.fmt.bufPrint(reason, "an integer from {d} through {d}", .{ schema.min.?, schema.max.? }) catch unreachable;
    };
    return .{ .code = .invocation_invalid, .token = entry.flag, .accepted = .{ .grammar = message } };
}
fn rejectFlag(problem: cli_args.Refusal) error{InvalidInvocation} {
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    caller_error.writeLine(&out, problem.code, problem.held("host", "serve")) catch unreachable;
    stderr.diagnosticBytes(out.buffered());
    return error.InvalidInvocation;
}
fn checkFlag(entry: FlagLeaf, value: []const u8) error{InvalidInvocation}!void {
    var reason: [128]u8 = undefined;
    if (flagProblem(entry, value, &reason)) |problem| return rejectFlag(problem);
}
pub fn checkFlags(parsed: *const cli_args.Parsed) !void {
    inline for (flag_leaves) |entry| {
        if (!entry.normalized) if (parsed.get(entry.flag)) |value| try checkFlag(entry, value);
    }
}

fn checkPreset(gpa: std.mem.Allocator, spec: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
    const configuration = try gpa.create(wire_request.Configuration);
    defer gpa.destroy(configuration);
    configuration.* = .{};
    return switch (try core_tools.parseAgentSpec(gpa, spec, configuration)) {
        .accepted => null,
        .rejected => |reason| reason,
    };
}

fn assign(settings: *hs.Settings, gpa: std.mem.Allocator, path: []const u8, value: []const u8, failure: *start_report.Failure) !void {
    try hs.assign(settings, gpa, path, value, checkPreset, failure);
}
const start_report = @import("start_report.zig");

// Quote text explicitly: a path beginning with '{', '[' or '"' is not JSON.
fn text(settings: *hs.Settings, gpa: std.mem.Allocator, path: []const u8, value: []const u8, failure: *start_report.Failure) !void {
    for (hs.leaves) |leaf| if (std.mem.eql(u8, leaf.pattern, path) and std.mem.eql(u8, leaf.kind, "path")) return assign(settings, gpa, path, value, failure);
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(json);
    try assign(settings, gpa, path, json, failure);
}

/// Read one document, then apply the compatibility flags. Settings owns every
/// admitted value; source bytes are wiped before returning on every path.
pub fn fill(init: std.process.Init, parsed: *const cli_args.Parsed, settings: *hs.Settings, fixtures: *providers.Fixtures, failure: *start_report.Failure) !void {
    const gpa = init.arena.allocator();
    try checkFlags(parsed);
    if (parsed.get("settings")) |source| {
        try readDocument(init, source, settings, failure);
    } else {
        // Preserve today's flag-only provider selection. A document instead
        // gets the settings owner's defaults when its providers key is absent.
        try hs.apply(settings, gpa, "{\"providers\":{}}", .file, checkPreset, failure);
    }
    inline for (flag_leaves) |entry| if (entry.direct) {
        if (parsed.get(entry.flag)) |value| try text(settings, gpa, entry.leaf.pattern, value, failure);
    };
    var number: [32]u8 = undefined;
    if (try parsed.number(u64, "bash-timeout-ms")) |timeout|
        try assign(settings, gpa, flagPath("bash-timeout-ms"), try std.fmt.bufPrint(&number, "{d}", .{timeout}), failure);
    if (try parsed.number(usize, "active-capacity")) |capacity|
        try assign(settings, gpa, flagPath("active-capacity"), try std.fmt.bufPrint(&number, "{d}", .{capacity}), failure);

    for (parsed.all("provider"), 0..) |label, index| {
        for (parsed.all("provider")[0..index]) |previous| if (std.mem.eql(u8, label, previous)) return error.DuplicateArgument;
        const provider = std.meta.stringToEnum(protocol.Provider, label) orelse {
            const printable = label.len <= protocol.max_provider_bytes and for (label) |byte| {
                if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_' and byte != '-') break false;
            } else true;
            stderr.diagnostic("rui: --provider {s} is not a built-in provider; they are " ++ provider_labels ++ ".\n", .{if (printable) label else "(unprintable)"});
            return error.UnsupportedProvider;
        };
        inline for (std.enums.values(protocol.Provider)) |named| if (provider == named) {
            const at = "providers." ++ @tagName(named);
            if (@field(settings.providers.entries, @tagName(named)) == null) try assign(settings, gpa, at, "{}", failure);
            if (comptime named.facts().credential == .api_key) {
                if (init.environ_map.get(providers.openai_base_url_variable)) |base| {
                    const endpoint = providers.endpointUnder(gpa, base) catch |err| {
                        if (err == error.InvalidBaseUrl) stderr.diagnostic(@import("host_launch.zig").invalid_base_url ++ "; the Host did not start.\n", .{});
                        return err;
                    };
                    try text(settings, gpa, at ++ ".endpoint", endpoint, failure);
                }
            }
        };
    }

    if (parsed.get("test-openai-fixture-endpoint")) |endpoint| {
        for (parsed.all("provider")) |label| if (std.mem.eql(u8, label, "openai")) return error.ConflictingArguments;
        try text(settings, gpa, flagPath("test-openai-fixture-endpoint"), endpoint, failure);
        try assign(settings, gpa, "providers.openai.unauthenticated", "true", failure);
        fixtures.openai = true;
    }
    if (parsed.get("test-codex-fixture-endpoint")) |endpoint| {
        try text(settings, gpa, flagPath("test-codex-fixture-endpoint"), endpoint, failure);
        try assign(settings, gpa, "providers.codex.unauthenticated", "true", failure);
        fixtures.codex = true;
    }
    if (parsed.get("test-chatgpt-fixture-endpoint")) |endpoint| {
        for (parsed.all("provider")) |label| if (std.mem.eql(u8, label, "chatgpt")) return error.ConflictingArguments;
        const base = providers.responsesBase(endpoint) orelse return error.InvalidArguments;
        try text(settings, gpa, flagPath("test-chatgpt-fixture-endpoint"), endpoint, failure);
        try assign(settings, gpa, "providers.chatgpt.unauthenticated", "true", failure);
        fixtures.chatgpt_token_endpoint = try std.fmt.allocPrint(gpa, "{s}/oauth/token", .{base});
    }
    if (parsed.get("provider-endpoint")) |endpoint| {
        // This development flag was checked by transport after Store selection.
        // Stage its bounded spelling here; seal remains the admission authority.
        // Rejecting URL syntax during fill would lose the Store diagnostic.
        if (settings.providers.entries.codex == null) try assign(settings, gpa, "providers.codex", "{}", failure);
        settings.providers.entries.codex.?.endpoint = .{};
        settings.providers.entries.codex.?.endpoint.?.text.set(endpoint) catch return invalid(failure, "providers.codex.endpoint", "must be UTF-8 text without NUL bytes");
        try assign(settings, gpa, "providers.codex.unauthenticated", "true", failure);
    }
}

const provider_labels = blk: {
    var labels: []const u8 = "";
    for (std.enums.values(protocol.Provider), 0..) |provider, i| labels = labels ++ (if (i == 0) "" else ", ") ++ @tagName(provider);
    break :blk labels;
};

fn invalid(failure: *start_report.Failure, comptime path: []const u8, comptime reason: []const u8) error{SettingsInvalid} {
    failure.* = .init(.settings_invalid, path ++ ": " ++ reason);
    return error.SettingsInvalid;
}

/// A pipe carries a four-byte big-endian length followed by exactly one JSON
/// document. Reading it never chooses the Host's lifetime.
pub noinline fn readDocument(init: std.process.Init, source: []const u8, settings: *hs.Settings, failure: *start_report.Failure) !void {
    const gpa = std.heap.c_allocator;
    if (std.mem.eql(u8, source, "-")) return readPipe(init, .stdin(), settings, failure);
    const buffer = try gpa.alloc(u8, hs.max_document_bytes + 1);
    defer {
        std.crypto.secureZero(u8, buffer);
        gpa.free(buffer);
    }
    var cwd: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = if (std.fs.path.isAbsolute(source)) source else try std.fs.path.join(init.arena.allocator(), &.{ cwd[0..try std.Io.Dir.cwd().realPath(init.io, &cwd)], source });
    const bytes = credentials.readPrivate(path, buffer) catch return invalid(failure, "settings", "must be a readable private file within the document byte bound");
    return hs.apply(settings, init.arena.allocator(), bytes orelse return invalid(failure, "settings", "file does not exist"), .file, checkPreset, failure);
}

fn readPipe(init: std.process.Init, file: std.Io.File, settings: *hs.Settings, failure: *start_report.Failure) !void {
    const gpa = std.heap.c_allocator;
    var prefix: [4]u8 = undefined;
    readExact(init.io, file, &prefix) catch return invalid(failure, "settings", "stdin closed before the 4-byte document length");
    const length = std.mem.readInt(u32, &prefix, .big);
    if (length == 0 or length > hs.max_document_bytes) return invalid(failure, "settings", "document length must be 1 to 1048576 bytes");
    const bytes = try gpa.alloc(u8, length);
    defer {
        std.crypto.secureZero(u8, bytes);
        gpa.free(bytes);
    }
    readExact(init.io, file, bytes) catch return invalid(failure, "settings", "stdin closed before the whole document arrived");
    return hs.apply(settings, init.arena.allocator(), bytes, .pipe, checkPreset, failure);
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
                    // A source the document names is a document refusal. The
                    // saved default is the flag Host's environment, so it keeps
                    // that Host's existing diagnostics, causes and exits.
                    if (entry.key.source == .default) {
                        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const path = api_key.path(init.environ_map, &path_buffer) catch |err| return if (err == error.HomeRequired) error.HomeUnavailable else err;
                        entry.key.source = .{ .file = .{} };
                        try entry.key.source.file.text.set(path);
                        resolve(init, &entry.key) catch |err| {
                            if (err == error.ApiKeyMissing) stderr.diagnostic("rui: no OpenAI API key; save one with `" ++ comptime protocol.Provider.openai.login().? ++ "`, then start the Host again.\n", .{});
                            return err;
                        };
                    } else resolve(init, &entry.key) catch |err| return resolutionFailure(failure, "providers." ++ @tagName(provider) ++ ".key", err);
                },
                // Only the saved default is resolved here, as before documents.
                .sign_in => if (!entry.unauthenticated.value or (provider == .codex and fixtures.codex) or (provider == .chatgpt and fixtures.chatgpt_token_endpoint != null)) {
                    if (entry.credential_file == null) {
                        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const path = provider_login.credentialPath(init, provider, &path_buffer, false) catch |err| return if (err == error.HomeRequired) error.HomeUnavailable else err;
                        entry.credential_file = .{};
                        try entry.credential_file.?.text.set(path);
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

/// Keep selection/remembered-default policy in the CLI, but fill its leaf here.
pub noinline fn selectStore(init: std.process.Init, settings: *hs.Settings, selected: []const u8, from_document: bool, failure: *start_report.Failure) !void {
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const value = platform.canonicalStoreDestination(init.io, selected, &canonical) catch |err| switch (err) {
        error.StorePathTooLong, error.NameTooLong => {
            if (from_document) return invalid(failure, "store.sqlite.dir", "canonical path exceeds the Store byte bound");
            // The platform owner bounds the canonical identity, not aliases.
            const entry = flag_leaves[0];
            var reason: [128]u8 = undefined;
            const message = try std.fmt.bufPrint(&reason, "a canonical Store path not longer than {d} bytes and platform-sized components", .{protocol.max_store_bytes});
            return rejectFlag(.{ .code = .invocation_invalid, .token = entry.flag, .accepted = .{ .grammar = message } });
        },
        else => return err,
    };
    try text(settings, init.arena.allocator(), flagPath("store"), value, failure);
}

fn parseForTest(gpa: std.mem.Allocator, args: []const []const u8) !cli_args.Parsed {
    var problem: cli_args.Refusal = undefined;
    return cli_args.Command.host_serve.definition().parse(args, gpa, &problem);
}

fn initForTest(arena: *std.heap.ArenaAllocator, env: *std.process.Environ.Map) std.process.Init {
    return .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = env, .preopens = .empty };
}

test "Host start fill maps every ordinary serve flag and fixture fact to its owner" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    var failure: start_report.Failure = undefined;
    const Case = struct { args: []const []const u8, leaf: []const u8, expected: []const u8 };
    // Expectations are today's flag meanings, not generated from the fill table.
    for ([_]Case{
        .{ .args = &.{ "--bash-path", "relative/bash" }, .leaf = "tools.bash.path", .expected = "relative/bash" },
        .{ .args = &.{ "--bash-timeout-ms", "17" }, .leaf = "tools.bash.timeoutMs", .expected = "17" },
        .{ .args = &.{ "--active-capacity", "0" }, .leaf = "execution.activeCapacity", .expected = "0" },
        .{ .args = &.{ "--provider-ca-file", "relative/ca.pem" }, .leaf = "network.caFile", .expected = "relative/ca.pem" },
        .{ .args = &.{ "--bash-path", "/tmp/bash-\xff" }, .leaf = "tools.bash.path", .expected = "/tmp/bash-\xff" },
        .{ .args = &.{ "--provider-ca-file", "/tmp/ca-\xff" }, .leaf = "network.caFile", .expected = "/tmp/ca-\xff" },
    }) |case| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), case.args);
        var fixtures: providers.Fixtures = .{};
        try fill(init, &parsed, settings, &fixtures, &failure);
        if (std.mem.eql(u8, case.leaf, "tools.bash.path")) try std.testing.expectEqualStrings(case.expected, settings.tools.bash.path.slice());
        if (std.mem.eql(u8, case.leaf, "network.caFile")) try std.testing.expectEqualStrings(case.expected, settings.network.ca_file.?.slice());
        if (std.mem.eql(u8, case.leaf, "tools.bash.timeoutMs")) try std.testing.expectEqual(@as(u64, 17), settings.tools.bash.timeout_ms.value);
        if (std.mem.eql(u8, case.leaf, "execution.activeCapacity")) try std.testing.expectEqual(@as(usize, 0), settings.execution.active_capacity.value);
    }
    for ([_][]const []const u8{ &.{ "--store", "relative/store" }, &.{ "--store-hex", "72656c61746976652f73746f7265" } }) |args| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), args);
        try selectStore(init, settings, parsed.get("store").?, false, &failure);
        var canonical: [protocol.max_store_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(try platform.canonicalStoreDestination(init.io, "relative/store", &canonical), settings.store.sqlite.dir.slice());
    }
    try environment.put(providers.openai_base_url_variable, "https://proxy.example/v1///");
    inline for (std.enums.values(protocol.Provider)) |provider| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), &.{ "--provider", @tagName(provider) });
        var fixtures: providers.Fixtures = .{};
        try fill(init, &parsed, settings, &fixtures, &failure);
        inline for (std.enums.values(protocol.Provider)) |other| try std.testing.expectEqual(provider == other, @field(settings.providers.entries, @tagName(other)) != null);
        if (provider == .openai) try std.testing.expectEqualStrings("https://proxy.example/v1/responses", settings.providers.entries.openai.?.endpoint.?.slice());
    }
    const endpoint = "http://127.0.0.1:9/responses";
    for ([_][]const u8{ "--provider-endpoint", "--test-codex-fixture-endpoint", "--test-openai-fixture-endpoint", "--test-chatgpt-fixture-endpoint" }, 0..) |flag, i| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), &.{ flag, endpoint });
        var fixtures: providers.Fixtures = .{};
        try fill(init, &parsed, settings, &fixtures, &failure);
        switch (i) {
            0, 1 => try std.testing.expectEqualStrings(endpoint, settings.providers.entries.codex.?.endpoint.?.slice()),
            2 => try std.testing.expectEqualStrings(endpoint, settings.providers.entries.openai.?.endpoint.?.slice()),
            3 => try std.testing.expectEqualStrings(endpoint, settings.providers.entries.chatgpt.?.endpoint.?.slice()),
            else => unreachable,
        }
        try std.testing.expectEqual(i == 1, fixtures.codex);
        try std.testing.expectEqual(i == 2, fixtures.openai);
        try std.testing.expectEqual(i == 3, fixtures.chatgpt_token_endpoint != null);
        if (i == 3) try std.testing.expectEqualStrings("http://127.0.0.1:9/oauth/token", fixtures.chatgpt_token_endpoint.?);
    }
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
    // The saved default keeps the flag Host's own cause; only a source the
    // document names is a leaf-scoped document refusal.
    try assign(settings, arena.allocator(), "providers.openai.key", "null", &failure);
    try std.testing.expectError(error.InsecureCredentialFile, prepare(init, settings, .{}, &failure));
    try assign(settings, arena.allocator(), "providers.openai.key", try std.fmt.allocPrint(arena.allocator(), "file:{s}", .{path}), &failure);
    try std.testing.expectError(error.SettingsInvalid, prepare(init, settings, .{}, &failure));
    try std.testing.expect(std.mem.startsWith(u8, failure.message.slice(), "providers.openai.key:"));
}

test "Host start retains development endpoint validation until sealing" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    var fixtures: providers.Fixtures = .{};
    const parsed = try parseForTest(arena.allocator(), &.{ "--provider-endpoint", "http://remote.example/responses" });
    try fill(init, &parsed, settings, &fixtures, &failure);
    try std.testing.expectEqualStrings("http://remote.example/responses", settings.providers.entries.codex.?.endpoint.?.slice());
    try selectStore(init, settings, "/tmp/store", false, &failure);
    try std.testing.expectError(error.SettingsInvalid, prepare(init, settings, fixtures, &failure));
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
}

test "Host start every derived flag leaf refuses over-bound input as a redacted usage error" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    inline for (flag_leaves) |entry| {
        const limit = entry.leaf.json_schema.max_bytes;
        const value = if (limit) |max| try arena.allocator().alloc(u8, max + 1) else try arena.allocator().dupe(u8, "184467440737095516160");
        if (limit != null) @memset(value, 'x');
        var reason: [128]u8 = undefined;
        const problem = flagProblem(entry, value, &reason).?;
        try std.testing.expectEqual(caller_error.Code.invocation_invalid, problem.code);
        try std.testing.expectEqualStrings(entry.flag, problem.token);
        try std.testing.expect(problem.value == null);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try caller_error.writeLine(&out.writer, problem.code, problem.held("host", "serve"));
        try std.testing.expect(std.mem.indexOf(u8, out.written(), entry.flag) != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), value) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "internal_unexpected") == null);
        try std.testing.expectEqual(@import("caller_exit.zig").Status.invalid, @import("caller_exit.zig").forCode(.not_sent, problem.code));
        try std.testing.expectError(error.InvalidInvocation, checkFlag(entry, value));
        if (!entry.normalized) {
            // Numeric argv values are already bounded by the grammar. Exercise
            // this owner independently with a post-parse invalid leaf value.
            var parsed = try parseForTest(arena.allocator(), &.{ "--" ++ entry.flag, if (limit != null) value else "1" });
            parsed.values[parsed.definition.indexOf(entry.flag).?] = value;
            const settings = try gpa.create(hs.Settings);
            defer gpa.destroy(settings);
            settings.* = .{};
            defer settings.deinit();
            var failure: start_report.Failure = undefined;
            var fixtures: providers.Fixtures = .{};
            try std.testing.expectError(error.InvalidInvocation, fill(initForTest(&arena, &env), &parsed, settings, &fixtures, &failure));
        }
    }
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

test "Host start private file origin refuses literal secrets and flags override document leaves" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
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
    const parsed = try parseForTest(arena.allocator(), &.{ "--settings", path, "--bash-timeout-ms", "99", "--active-capacity", "4", "--provider", "codex" });
    var fixtures: providers.Fixtures = .{};
    try fill(init, &parsed, settings, &fixtures, &failure);
    try std.testing.expectEqual(@as(u64, 99), settings.tools.bash.timeout_ms.value);
    try std.testing.expectEqual(@as(usize, 4), settings.execution.active_capacity.value);
    try std.testing.expectEqual(hs.Interface.Lifetime.stdin, settings.interface.lifetime.value);
    try std.testing.expect(settings.providers.entries.codex != null);
    try private.setFilePermissions(init.io, "host.json", .fromMode(0o644), .{});
    try std.testing.expectError(error.SettingsInvalid, readDocument(init, path, settings, &failure));
}

test "Host start pipe file and flag admissions report every code on both streams even if one refuses" {
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
    for ([_]enum { pipe, file, flags }{ .pipe, .file, .flags }) |source| {
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
                try fill(init, &parsed, settings, &fixtures, &admission_failure);
            },
            .flags => {
                const parsed = try parseForTest(arena.allocator(), &.{ "--bash-timeout-ms", "17" });
                try fill(init, &parsed, settings, &fixtures, &admission_failure);
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

test "Host start delayed endpoint staging always owns its byte refusal" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    for ([_][]const u8{ "https://invalid-\xff/responses", "https://invalid-\x00/responses" }) |endpoint| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), &.{ "--provider-endpoint", endpoint });
        var failure: start_report.Failure = undefined;
        var fixtures: providers.Fixtures = .{};
        try std.testing.expectError(error.SettingsInvalid, fill(initForTest(&arena, &environment), &parsed, settings, &fixtures, &failure));
        try std.testing.expectEqual(start_report.StartError.settings_invalid, failure.code);
        try std.testing.expectEqualStrings("providers.codex.endpoint: must be UTF-8 text without NUL bytes", failure.message.slice());
        try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), endpoint) == null);
    }
}
