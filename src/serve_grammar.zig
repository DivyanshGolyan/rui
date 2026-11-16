const std = @import("std");
const grammar = @import("cli_grammar.zig");
const provider_name = @import("provider_name.zig");
const retention_capacity = @import("retention_capacity.zig");
const Option = grammar.Option;
const value = grammar.value;
const hiddenValue = grammar.hiddenValue;
const hiddenNumber = grammar.hiddenNumber;
const hiddenFlag = grammar.hiddenFlag;
pub const destination = &[_]Option{ value("store", "PATH"), grammar.hex("store-hex", "store", 492) };

pub const retired_options = &[_]grammar.RetiredOption{
    grammar.retired("active-capacity", &.{"execution.activeCapacity=VALUE"}, ""),
    grammar.retired("provider", &.{"providers.VALUE={}"}, " (one --set per provider; each adds to the set)"),
    grammar.retired("provider-endpoint", &.{ "providers.codex.endpoint=VALUE", "providers.codex.unauthenticated=true" }, ""),
    grammar.retired("provider-ca-file", &.{"network.caFile=VALUE"}, ""),
    grammar.retired("bash-path", &.{"tools.bash.path=VALUE"}, ""),
    grammar.retired("bash-timeout-ms", &.{"tools.bash.timeoutMs=VALUE"}, ""),
};

pub fn currentArguments(arena: std.mem.Allocator, args: []const []const u8) error{ OutOfMemory, InvalidArguments }![]const []const u8 {
    var flagged = false;
    var count = args.len;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) break;
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        if (retiredNamed(arg[2..])) |old| {
            if (index + 1 == args.len) return error.InvalidArguments;
            flagged = true;
            count = count - 2 + 2 * old.assignments.len;
            index += 1;
        } else if (definition.optionNamed(arg[2..])) |option| {
            if (option.argument != null) index += 1;
        }
    }
    if (!flagged) return args;
    const out = try arena.alloc([]const u8, count);
    var at: usize = 0;
    index = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            @memcpy(out[at..][0 .. args.len - index], args[index..]);
            at += args.len - index;
            break;
        }
        const old = if (std.mem.startsWith(u8, arg, "--")) retiredNamed(arg[2..]) else null;
        if (old) |found| {
            index += 1;
            for (found.assignments) |assignment| {
                out[at..][0..2].* = .{ "--set", try std.mem.replaceOwned(u8, arena, assignment, "VALUE", args[index]) };
                at += 2;
            }
            continue;
        }
        out[at] = arg;
        at += 1;
        if (std.mem.startsWith(u8, arg, "--")) if (definition.optionNamed(arg[2..])) |option| if (option.argument != null and index + 1 < args.len) {
            index += 1;
            out[at] = args[index];
            at += 1;
        };
    }
    std.debug.assert(at == out.len);
    return out;
}

/// A running Host's source spellings. Values borrow argv or `arena`; the
/// assignment slice and retired translations belong to `arena`. Callers must
/// wipe that arena because assignments may name private sources or values.
/// No document, path anchoring, provider policy or process authority lives here.
pub const RunningSources = struct {
    dir: ?[]const u8,
    settings_file: ?[]const u8,
    assignments: []const []const u8,
    /// Discovery still needs the directory of a Host whose serve-only flags
    /// make it ineligible for restart. This is syntax eligibility, not start
    /// admission: stdin/relative settings are decided by host_start.
    restartable: bool,
};

/// The single reader of supported releases' running `host serve` argv. Fresh
/// typed argv is still parsed by its command definition, never translated.
pub fn runningSources(arena: std.mem.Allocator, argv: []const []const u8) !RunningSources {
    if (argv.len < 3 or !std.mem.eql(u8, argv[1], "host") or !std.mem.eql(u8, argv[2], "serve")) return error.HostPeerNotServing;
    const arguments = try currentArguments(arena, argv[3..]);
    var problem: grammar.Refusal = undefined;
    const parsed = try definition.parseSyntax(arguments, arena, &problem);
    var restartable = !parsed.help and parsed.missing() == null and parsed.repeat_count < parsed.repeats.len;
    parsed.validateValues(&problem) catch {
        restartable = false;
    };
    for (definition.options) |option| {
        if (std.mem.eql(u8, option.hex_of orelse option.name, "store")) continue;
        if (option.hidden and parsed.hasNamed(option.name)) restartable = false;
    }
    return .{
        .dir = parsed.get("store"),
        .settings_file = parsed.get("settings"),
        .assignments = try arena.dupe([]const u8, parsed.all("set")),
        .restartable = restartable,
    };
}

/// The provider set a previous release served when no layer of its Host's
/// launch named providers, which replay passes first so that an upgrade never
/// changes what a running Host serves: a Host started without --settings
/// served only the providers its flags named, and a --settings document
/// without `providers` served every built-in entry. Null when the document
/// names providers. Part of the retired_options transition, removed with it.
pub fn previousProviders(settings: bool, document_names_providers: bool) ?[]const u8 {
    if (!settings) return "providers={}";
    if (document_names_providers) return null;
    return every_provider;
}

const every_provider = blk: {
    var set: []const u8 = "providers={";
    for (std.meta.fieldNames(provider_name.Provider), 0..) |name, n| set = set ++ (if (n == 0) "" else ",") ++ "\"" ++ name ++ "\":{}";
    break :blk set ++ "}";
};

test "a previous release's provider set when no layer named one" {
    try std.testing.expectEqualStrings("providers={}", previousProviders(false, false).?);
    try std.testing.expectEqualStrings("providers={}", previousProviders(false, true).?);
    try std.testing.expectEqual(@as(?[]const u8, null), previousProviders(true, true));
    try std.testing.expectEqualStrings("providers={\"codex\":{},\"openai\":{},\"chatgpt\":{}}", previousProviders(true, false).?);
}

fn retiredNamed(name: []const u8) ?grammar.RetiredOption {
    for (retired_options) |old| if (std.mem.eql(u8, old.name, name)) return old;
    return null;
}
pub const host_destination = &[_]Option{ value("store", "PATH"), blk: {
    var option = grammar.hex("store-hex", "store", 492);
    option.hidden = true;
    break :blk option;
} };
pub const settings_options = host_destination ++ &[_]Option{
    value("settings", "FILE|-"),
    .{ .name = "set", .argument = "PATH=VALUE", .repeated = true },
};
const serve_test = &[_]Option{
    .{ .name = "fault", .argument = "VALUE", .hidden = true, .repeated = true },
    hiddenValue("test-models-dev-url"),
    hiddenValue("test-codex-fixture-endpoint"),
    hiddenValue("test-openai-fixture-endpoint"),
    hiddenValue("test-chatgpt-fixture-endpoint"),
    hiddenNumber("test-bash-scratch-limit-bytes", 0, std.math.maxInt(u64)),
    hiddenNumber("test-retention-entry-capacity", 2, retention_capacity.entries),
    hiddenFlag("test-retention-removal-failure"),
    hiddenNumber("test-provider-inactivity-seconds", 1, std.math.maxInt(i64) / 1_000_000_000),
    hiddenValue("test-retry-waits-ms"),
    hiddenNumber("test-before-launch-delay-ms", 0, 10_000),
    hiddenNumber("test-before-result-delay-ms", 0, 10_000),
    hiddenValue("test-model-result-gate-path"),
    hiddenValue("test-retry-recovery-gate-path"),
    hiddenValue("test-inspection-reply-gate-path"),
    hiddenNumber("test-inspection-reply-delay-ms", 0, 60_000),
    hiddenNumber("test-client-send-buffer-bytes", 1, std.math.maxInt(c_int)),
    hiddenFlag("test-phase-trace"),
    hiddenNumber("test-observation-fd", 0, std.math.maxInt(c_int)),
    hiddenNumber("test-observation-state-fd", 0, std.math.maxInt(c_int)),
    hiddenValue("test-observation-plan"),
    hiddenValue("test-transition"),
    hiddenValue("test-transition-gate-path"),
    hiddenValue("test-bash-observed-exit-gate-path"),
    hiddenValue("test-shutdown-signalled-gate-path"),
    hiddenValue("test-bash-cleanup-gate-path"),
    hiddenValue("test-control-gate-keys"),
    hiddenValue("test-control-gate-path"),
    hiddenFlag("test-suppress-first-control-hint"),
    hiddenFlag("test-sqlite-diagnostics"),
    hiddenFlag("test-sqlite-cache-spill-off"),
    hiddenNumber("test-sqlite-cache-kib", 1, 4096),
    hiddenNumber("test-request-scratch-limit", 0, std.math.maxInt(u64)),
    hiddenNumber("test-request-preparation-byte-allowance", 1, std.math.maxInt(usize)),
    hiddenNumber("test-request-preparation-item-allowance", 1, std.math.maxInt(usize)),
    hiddenNumber("test-request-preparation-advance-delay-ms", 0, std.math.maxInt(i64)),
};

pub const definition: grammar.Definition = .{
    .resource = .host,
    .name = "serve",
    .description = "Run a foreground Host. Apply saved Host settings, then --settings FILE|- and repeated --set PATH=VALUE in order. Provider credentials belong to this Host, not its peer callers.",
    .options = settings_options ++ serve_test,
    .retired_options = retired_options,
};

comptime {
    @setEvalBranchQuota(10_000);
    var visible: usize = 0;
    for (definition.options) |option| {
        if (option.hidden) continue;
        if (!std.mem.eql(u8, option.name, "store") and !std.mem.eql(u8, option.name, "settings") and !std.mem.eql(u8, option.name, "set")) @compileError("unexpected visible Host serve option");
        visible += 1;
    }
    if (visible != 3) @compileError("Host serve must expose exactly store, settings, set");
    for ([_][]const u8{ "store", "settings", "set" }) |name| {
        var count: usize = 0;
        for (definition.options) |option| {
            if (!option.hidden and std.mem.eql(u8, name, option.name)) count += 1;
        }
        if (count != 1) @compileError("Host serve visible options must each appear once");
    }
}

test "running Host sources have one syntax owner across current and retired argv" {
    const cases = [_]struct {
        argv: []const []const u8,
        dir: ?[]const u8 = null,
        settings: ?[]const u8 = null,
        assignments: []const []const u8 = &.{},
        restartable: bool = true,
    }{
        .{ .argv = &.{ "rui", "host", "serve" } },
        .{ .argv = &.{ "rui", "host", "serve", "--store", "/host" }, .dir = "/host" },
        .{ .argv = &.{ "rui", "host", "serve", "--store-hex", "2f686f7374", "--settings", "/document-\xff" }, .dir = "/host", .settings = "/document-\xff" },
        .{ .argv = &.{ "rui", "host", "serve", "--settings", "/document", "--set", "providers={}", "--set", "execution.activeCapacity=3" }, .settings = "/document", .assignments = &.{ "providers={}", "execution.activeCapacity=3" } },
        .{ .argv = &.{ "rui", "host", "serve", "--provider", "codex", "--provider", "openai", "--active-capacity", "4", "--bash-path", "/bin/bash", "--bash-timeout-ms", "1000", "--provider-ca-file", "/network-ca" }, .assignments = &.{ "providers.codex={}", "providers.openai={}", "execution.activeCapacity=4", "tools.bash.path=/bin/bash", "tools.bash.timeoutMs=1000", "network.caFile=/network-ca" } },
        // Syntax keeps source spellings; only admission can decide whether
        // their effective settings reproduce in a detached replacement.
        .{ .argv = &.{ "rui", "host", "serve", "--settings", "-" }, .settings = "-" },
        .{ .argv = &.{ "rui", "host", "serve", "--settings", "relative.json" }, .settings = "relative.json" },
        .{ .argv = &.{ "rui", "host", "serve", "--store", "/host", "--fault", "injected" }, .dir = "/host", .restartable = false },
        .{ .argv = &.{ "rui", "host", "serve", "--help" }, .restartable = false },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("running source case {d}\n", .{index});
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const sources = runningSources(arena.allocator(), case.argv) catch |err| {
            std.debug.print("source parse error: {s}\n", .{@errorName(err)});
            return err;
        };
        try std.testing.expectEqual(case.restartable, sources.restartable);
        if (case.dir) |dir| try std.testing.expectEqualStrings(dir, sources.dir.?) else try std.testing.expect(sources.dir == null);
        if (case.settings) |file| try std.testing.expectEqualStrings(file, sources.settings_file.?) else try std.testing.expect(sources.settings_file == null);
        try std.testing.expectEqual(case.assignments.len, sources.assignments.len);
        for (case.assignments, sources.assignments) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.HostPeerNotServing, runningSources(arena.allocator(), &.{ "rui", "session", "start" }));
    try std.testing.expectError(error.InvalidArguments, runningSources(arena.allocator(), &.{ "rui", "host", "serve", "--provider" }));
    const limit = @as(grammar.Parsed, undefined).repeats.len;
    var full: [3 + 2 * limit][]const u8 = undefined;
    @memcpy(full[0..3], &[_][]const u8{ "rui", "host", "serve" });
    for (0..limit) |index| {
        full[3 + 2 * index] = "--set";
        full[4 + 2 * index] = "execution.activeCapacity=2";
    }
    try std.testing.expect(!(try runningSources(arena.allocator(), &full)).restartable);
    try std.testing.expect((try runningSources(arena.allocator(), full[0 .. full.len - 2])).restartable);
}
