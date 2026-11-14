//! Foreground Host serve options and conflicts.
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

/// The Host flags this grammar retired, never accepted as options. Two
/// readers: a typed flag is refused naming its replacement, and the argv of a
/// Host that a previous release started is read through `currentArguments`.
/// Remove when the oldest supported previous release no longer starts Hosts
/// with these flags.
pub const retired_options = &[_]grammar.RetiredOption{
    grammar.retired("active-capacity", &.{"execution.activeCapacity=VALUE"}, ""),
    grammar.retired("provider", &.{"providers.VALUE={}"}, " (one --set per provider; each adds to the set)"),
    grammar.retired("provider-endpoint", &.{ "providers.codex.endpoint=VALUE", "providers.codex.unauthenticated=true" }, ""),
    grammar.retired("provider-ca-file", &.{"network.caFile=VALUE"}, ""),
    grammar.retired("bash-path", &.{"tools.bash.path=VALUE"}, ""),
    grammar.retired("bash-timeout-ms", &.{"tools.bash.timeoutMs=VALUE"}, ""),
};

/// A running Host's `host serve` arguments in this grammar: each retired
/// flag and its value become the assignments that replace it. An argv with
/// no retired flag is returned as it is. `arena` owns the result.
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
/// Hide the compatibility identity spelling on Host settings/start surfaces.
pub const host_destination = &[_]Option{ value("store", "PATH"), blk: {
    var option = grammar.hex("store-hex", "store", 492);
    option.hidden = true;
    break :blk option;
} };
pub const settings_options = host_destination ++ &[_]Option{
    value("settings", "FILE|-"),
    .{ .name = "set", .argument = "PATH=VALUE", .repeated = true },
};
/// Host fault injection and observation, consumed only by host serve.
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
