//! Compatibility shell for today's serve flags and launch frame. The Host
//! receives only the prepared value; process environment and secret I/O end here.
const std = @import("std");
const hs = @import("host_settings.zig");
const cli_args = @import("cli_args.zig");
const launch_frame = @import("launch_frame.zig");
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
// owned by the argv grammar; launch-frame is a source switch, not a value leaf.
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

/// Fill caller storage without filesystem effects. Frame-backed presets borrow
/// the frame, which the CLI retains through serving. Inline credentials are
/// copied into Settings and both owners wipe their own copy on disposal.
pub fn fill(init: std.process.Init, parsed: *const cli_args.Parsed, frame: ?*const launch_frame.Frame, settings: *hs.Settings, fixtures: *providers.Fixtures, failure: *start_report.Failure) !void {
    const gpa = init.arena.allocator();
    try checkFlags(parsed);
    try hs.apply(settings, gpa, "{\"providers\":{}}", .file, checkPreset, failure);
    const bash_path = parsed.get("bash-path") orelse hs.default_bash_path;
    if (bash_path.len == 0) return error.InvalidBashPath;
    const timeout = try parsed.number(u64, "bash-timeout-ms") orelse hs.default_bash_timeout_ms;
    if (timeout == 0 or timeout > std.math.maxInt(i64)) return error.InvalidBashTimeout;
    inline for (flag_leaves) |entry| if (entry.direct) {
        if (parsed.get(entry.flag)) |value| try text(settings, gpa, entry.leaf.pattern, value, failure);
    };
    var number: [32]u8 = undefined;
    try assign(settings, gpa, flagPath("bash-timeout-ms"), try std.fmt.bufPrint(&number, "{d}", .{timeout}), failure);
    const capacity = (if (frame) |value| value.active_capacity else try parsed.number(usize, "active-capacity"));
    if (capacity) |value| try assign(settings, gpa, flagPath("active-capacity"), try std.fmt.bufPrint(&number, "{d}", .{value}), failure);

    for (parsed.all("provider")) |label| {
        const provider = std.meta.stringToEnum(protocol.Provider, label) orelse {
            const printable = label.len <= protocol.max_provider_bytes and for (label) |byte| {
                if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_' and byte != '-') break false;
            } else true;
            stderr.diagnostic("rui: --provider {s} is not a built-in provider; they are " ++ provider_labels ++ ".\n", .{if (printable) label else "(unprintable)"});
            return error.UnsupportedProvider;
        };
        inline for (std.enums.values(protocol.Provider)) |named| if (provider == named) {
            const at = "providers." ++ @tagName(named);
            if (@field(settings.providers.entries, @tagName(named)) != null) return error.DuplicateArgument;
            try assign(settings, gpa, at, "{}", failure);
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
    if (frame) |value| try fillFrame(gpa, value, settings, failure);

    if (parsed.get("test-openai-fixture-endpoint")) |endpoint| {
        if (settings.providers.entries.openai != null) return error.ConflictingArguments;
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
        if (settings.providers.entries.chatgpt != null) return error.ConflictingArguments;
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
        try settings.providers.entries.codex.?.endpoint.?.text.set(endpoint);
        try assign(settings, gpa, "providers.codex.unauthenticated", "true", failure);
    }
}

const provider_labels = blk: {
    var labels: []const u8 = "";
    for (std.enums.values(protocol.Provider), 0..) |provider, i| labels = labels ++ (if (i == 0) "" else ", ") ++ @tagName(provider);
    break :blk labels;
};

fn fillFrame(gpa: std.mem.Allocator, frame: *const launch_frame.Frame, settings: *hs.Settings, failure: *start_report.Failure) !void {
    switch (frame.store) {
        .sqlite_dir => {}, // selectedStore retains the CLI's spelling/selection policy.
        .mysql_url => |url| {
            try assign(settings, gpa, "store.mysql.url", "null", failure);
            const Value = @typeInfo(@typeInfo(@FieldType(hs.MysqlBytes, "parsed")).optional.child).pointer.child;
            const value = try gpa.create(Value);
            // Reuse the frame's admitted parsed fields, not a second URL encoder.
            value.* = .{ .user = url.user, .password = url.password, .host = url.host, .socket = url.socket, .database = url.database, .ca_file = url.ca_file, .port = url.port };
            settings.store.mysql.url.bytes = .{ .allocator = gpa, .parsed = value };
            settings.store.mysql.url.source = .literal;
        },
    }
    const endpoint = providers.endpointUnder(gpa, frame.base_url.slice()) catch |err| {
        if (err == error.InvalidBaseUrl) failure.* = .init(.launch_frame_invalid, "provider.baseUrl must be an https URL with a host and no query");
        return err;
    };
    try text(settings, gpa, "providers.openai.endpoint", endpoint, failure);
    settings.providers.entries.openai.?.key.bytes = frame.key;
    settings.providers.entries.openai.?.key.source = .literal;
    if (frame.ca_file.len != 0) try text(settings, gpa, hs.path("network.caFile"), frame.ca_file.slice(), failure);
    try text(settings, gpa, hs.path("interface.dir"), frame.runtime_dir.slice(), failure);
    try assign(settings, gpa, hs.path("interface.lifetime"), "stdin", failure);
    try assign(settings, gpa, hs.path("execution.paused"), if (frame.paused) "true" else "false", failure);
    for (frame.mcpServerSlice(), 0..) |*server, i| {
        // The parser has admitted names, endpoints, timeouts and tokens already.
        try settings.tools.mcp.names[i].set(server.name.slice());
        const dest = &settings.tools.mcp.values[i];
        try dest.url.text.set(server.url.slice());
        dest.bearer_token.bytes = server.bearer_token;
        dest.bearer_token.source = .literal;
        dest.call_timeout_ms.value = server.call_timeout_ms;
        settings.tools.mcp.len = i + 1;
    }
    settings.presets.specs = frame.presets;
}

/// Anchor, resolve each served secret, then issue the proof. No environment map
/// reaches server. Saved sign-ins stay file sources: their Adapter owns leasing.
pub fn prepare(init: std.process.Init, settings: *hs.Settings, fixtures: providers.Fixtures, failure: *start_report.Failure) !hs.Prepared {
    var cwd: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try hs.anchor(settings, cwd[0..try std.Io.Dir.cwd().realPath(init.io, &cwd)]);
    try resolveProviders(init, settings, fixtures);
    if (settings.store == .mysql) try resolve(init, &settings.store.mysql.url);
    for (settings.tools.mcp.values[0..settings.tools.mcp.len]) |*server| try resolve(init, &server.bearer_token);
    return hs.seal(settings, failure);
}

/// Provider/proxy preflight precedes Store selection just as today's CLI does.
/// prepare reuses this owner after anchoring; resolved bytes/paths are not read twice.
pub fn resolveProviders(init: std.process.Init, settings: *hs.Settings, fixtures: providers.Fixtures) !void {
    inline for (std.enums.values(protocol.Provider)) |provider| {
        if (@field(settings.providers.entries, @tagName(provider))) |*entry| {
            switch (comptime provider.facts().credential) {
                .api_key => if (!entry.unauthenticated.value or fixtures.openai) {
                    if (entry.key.source == .default) {
                        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                        const path = api_key.path(init.environ_map, &path_buffer) catch |err| return if (err == error.HomeRequired) error.HomeUnavailable else err;
                        entry.key.source = .{ .file = .{} };
                        try entry.key.source.file.text.set(path);
                    }
                    resolve(init, &entry.key) catch |err| {
                        if (err == error.ApiKeyMissing) stderr.diagnostic("rui: no OpenAI API key; save one with `" ++ comptime protocol.Provider.openai.login().? ++ "`, then start the Host again.\n", .{});
                        return err;
                    };
                },
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
pub noinline fn selectStore(init: std.process.Init, settings: *hs.Settings, selected: []const u8, from_frame: bool, failure: *start_report.Failure) !void {
    var canonical: [protocol.max_store_bytes]u8 = undefined;
    const value = platform.canonicalStoreDestination(init.io, selected, &canonical) catch |err| switch (err) {
        error.StorePathTooLong, error.NameTooLong => {
            if (from_frame) {
                failure.* = .init(.launch_frame_invalid, "store is too long");
                return error.LaunchFrameInvalid;
            }
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
        try fill(init, &parsed, null, settings, &fixtures, &failure);
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
        try fill(init, &parsed, null, settings, &fixtures, &failure);
        inline for (std.enums.values(protocol.Provider)) |other| try std.testing.expectEqual(provider == other, @field(settings.providers.entries, @tagName(other)) != null);
        if (provider == .openai) try std.testing.expectEqualStrings("https://proxy.example/v1/responses", settings.providers.entries.openai.?.endpoint.?.slice());
    }
    const endpoint = "http://127.0.0.1:9/responses";
    for ([_][]const u8{ "--provider-endpoint", "--test-codex-fixture-endpoint", "--test-openai-fixture-endpoint", "--test-chatgpt-fixture-endpoint" }, 0..) |flag, i| {
        settings.* = .{};
        defer settings.deinit();
        const parsed = try parseForTest(arena.allocator(), &.{ flag, endpoint });
        var fixtures: providers.Fixtures = .{};
        try fill(init, &parsed, null, settings, &fixtures, &failure);
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

test "Host start fill preserves every launch frame field on SQLite and MySQL" {
    const gpa = std.testing.allocator;
    var environment: std.process.Environ.Map = .init(gpa);
    defer environment.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init = initForTest(&arena, &environment);
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    const frame = try gpa.create(launch_frame.Frame);
    defer gpa.destroy(frame);
    for ([_][]const u8{ "relative/store", "mysql://user:password@localhost/db" }, 0..) |store, i| {
        settings.* = .{};
        defer settings.deinit();
        frame.* = .{};
        defer frame.deinit();
        var failure: start_report.Failure = undefined;
        const json = try std.fmt.allocPrint(gpa, "{{\"v\":1,\"store\":\"{s}\",\"provider\":{{\"kind\":\"openai_key\",\"baseUrl\":\"https://proxy.example/v1///\",\"key\":\"frame-key\",\"caFile\":\"relative/ca.pem\"}},\"runtimeDir\":\"/tmp/r///\",\"activeCapacity\":3,\"paused\":true,\"mcpServers\":[{{\"name\":\"docs\",\"url\":\"http://127.0.0.1:9/mcp\",\"bearerToken\":\"mcp-key\",\"callTimeoutMs\":17}}],\"presets\":{{\"reader\":{{\"workspace\":\"/tmp/workspace\",\"provider\":\"openai\",\"model\":\"model-a\",\"effort\":null,\"compactAt\":1000,\"permissionMode\":\"ask\",\"instructions\":\"Read carefully\",\"tools\":[\"bash\"]}}}}}}", .{store});
        defer {
            std.crypto.secureZero(u8, json);
            gpa.free(json);
        }
        launch_frame.parse(gpa, json, frame, &failure) catch |err| {
            std.debug.print("frame parity refusal: {s}\n", .{failure.message.slice()});
            return err;
        };
        const parsed = try parseForTest(arena.allocator(), &.{ "--launch-frame", "--bash-path", "/custom/bash", "--bash-timeout-ms", "99" });
        var fixtures: providers.Fixtures = .{};
        try fill(init, &parsed, frame, settings, &fixtures, &failure);
        if (i == 0) try selectStore(init, settings, frame.store.sqlite_dir.slice(), true, &failure);
        _ = try prepare(init, settings, fixtures, &failure);
        try std.testing.expectEqual(i == 1, settings.store == .mysql);
        if (i == 0) {
            var canonical: [protocol.max_store_bytes]u8 = undefined;
            const expected = try platform.canonicalStoreDestination(init.io, store, &canonical);
            try std.testing.expectEqualStrings(expected, settings.store.sqlite.dir.slice());
        } else {
            try std.testing.expectEqualStrings("user", settings.store.mysql.url.bytes.parsed.?.user.slice());
            try std.testing.expectEqualStrings("password", settings.store.mysql.url.bytes.parsed.?.password.slice());
            try std.testing.expectEqualStrings("localhost", settings.store.mysql.url.bytes.parsed.?.host.slice());
            try std.testing.expectEqualStrings("db", settings.store.mysql.url.bytes.parsed.?.database.slice());
        }
        try std.testing.expectEqualStrings("https://proxy.example/v1/responses", settings.providers.entries.openai.?.endpoint.?.slice());
        try std.testing.expectEqualStrings("frame-key", settings.providers.entries.openai.?.key.value());
        try std.testing.expectEqualStrings("relative/ca.pem", settings.network.ca_file.?.slice());
        try std.testing.expectEqualStrings("/tmp/r", settings.interface.dir.slice());
        try std.testing.expect(!settings.interface.dir.anchored);
        try std.testing.expectEqual(hs.Interface.Lifetime.stdin, settings.interface.lifetime.value);
        try std.testing.expectEqual(@as(usize, 3), settings.execution.active_capacity.value);
        try std.testing.expect(settings.execution.paused.value);
        try std.testing.expectEqualStrings("/custom/bash", settings.tools.bash.path.slice());
        try std.testing.expectEqual(@as(u64, 99), settings.tools.bash.timeout_ms.value);
        try std.testing.expectEqual(@as(usize, 1), settings.tools.mcp.len);
        try std.testing.expectEqualStrings("docs", settings.tools.mcp.names[0].slice());
        try std.testing.expectEqualStrings("http://127.0.0.1:9/mcp", settings.tools.mcp.values[0].url.slice());
        try std.testing.expectEqualStrings("mcp-key", settings.tools.mcp.values[0].bearer_token.value());
        try std.testing.expectEqual(@as(u32, 17), settings.tools.mcp.values[0].call_timeout_ms.value);
        try std.testing.expectEqualStrings("reader", settings.presets.specs[0].name);
        try std.testing.expectEqualStrings("Read carefully", settings.presets.specs[0].spec.get("instructions").?.string);
    }
}

test "Host start keeps frame plus flags refusal and error code unchanged" {
    var problem: cli_args.Refusal = undefined;
    try std.testing.expectError(error.ConflictingArguments, cli_args.Command.host_serve.definition().parse(&.{ "--launch-frame", "--provider", "openai" }, std.testing.allocator, &problem));
    try std.testing.expectEqual(@import("caller_error.zig").Code.launch_frame_excludes_provider, problem.code);
    try std.testing.expectEqualStrings("launch-frame", problem.token);
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
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/private/key-\xff", .{root[0..try tmp.dir.realPath(std.testing.io, &root)]});
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
    try private.setFilePermissions(std.testing.io, "key-\xff", .fromMode(0o644), .{});
    try assign(settings, arena.allocator(), "providers.openai.key", "null", &failure);
    try std.testing.expectError(error.InsecureCredentialFile, prepare(init, settings, .{}, &failure));
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
    try fill(init, &parsed, null, settings, &fixtures, &failure);
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
            try std.testing.expectError(error.InvalidInvocation, fill(initForTest(&arena, &env), &parsed, null, settings, &fixtures, &failure));
        }
    }
}
