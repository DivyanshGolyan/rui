//! Foreground Host serve options and conflicts.
const std = @import("std");
const grammar = @import("cli_grammar.zig");
const retention_capacity = @import("retention_capacity.zig");
const Option = grammar.Option;
const value = grammar.value;
const hiddenValue = grammar.hiddenValue;
const hiddenNumber = grammar.hiddenNumber;
const hiddenFlag = grammar.hiddenFlag;
pub const destination = &[_]Option{ value("store", "PATH"), grammar.hex("store-hex", "store", 492) };

/// Temporary PR5 migration owner; remove in PR7. Never accepted as options.
pub const retired_options = &[_]grammar.RetiredOption{
    .{ .name = "active-capacity", .replacement = "--set execution.activeCapacity=VALUE" },
    .{ .name = "provider", .replacement = "--set providers.VALUE={} (one --set per provider; each adds to the set)" },
    .{ .name = "provider-endpoint", .replacement = "--set providers.codex.endpoint=VALUE --set providers.codex.unauthenticated=true" },
    .{ .name = "provider-ca-file", .replacement = "--set network.caFile=VALUE" },
    .{ .name = "bash-path", .replacement = "--set tools.bash.path=VALUE" },
    .{ .name = "bash-timeout-ms", .replacement = "--set tools.bash.timeoutMs=VALUE" },
};
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
