const std = @import("std");
const grammar = @import("cli_grammar.zig");
const settings_handoff = @import("host_settings_handoff.zig");
const retention_capacity = @import("retention_capacity.zig");
const Option = grammar.Option;
const value = grammar.value;
const hiddenValue = grammar.hiddenValue;
const hiddenNumber = grammar.hiddenNumber;
const hiddenFlag = grammar.hiddenFlag;
pub const destination = &[_]Option{ value("store", "PATH"), grammar.hex("store-hex", "store", 492) };

/// A running Host's source spellings. Values borrow argv or `arena`; the
/// assignment slice belongs to `arena`. Callers must wipe that arena because
/// assignments may name private sources or values.
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
    var problem: grammar.Refusal = undefined;
    const parsed = try definition.parseSyntax(argv[3..], arena, &problem);
    var restartable = !parsed.help and parsed.missing() == null and parsed.repeat_count < parsed.repeats.len;
    parsed.validateValues(&problem) catch {
        restartable = false;
    };
    for (definition.options) |option| {
        if (std.mem.eql(u8, option.hex_of orelse option.name, "store")) continue;
        if (std.mem.eql(u8, option.name, settings_handoff.input_option)) continue; // consumed descriptor is provenance, never a replay input
        if (option.hidden and parsed.hasNamed(option.name)) restartable = false;
    }
    return .{
        .dir = parsed.get("store"),
        .settings_file = parsed.get("settings"),
        .assignments = try arena.dupe([]const u8, parsed.all("set")),
        .restartable = restartable,
    };
}

pub const host_destination = &[_]Option{ value("store", "PATH"), blk: {
    var option = grammar.hex("store-hex", "store", 492);
    option.hidden = true;
    break :blk option;
} };
pub const settings_options = host_destination ++ &[_]Option{
    value("settings", "FILE|-"),
    hiddenNumber(settings_handoff.input_option, 0, std.math.maxInt(c_int)),
    .{ .name = "set", .argument = "PATH=VALUE", .repeated = true },
};
const serve_test = &[_]Option{
    .{ .name = "fault", .argument = "VALUE", .hidden = true, .repeated = true },
    hiddenNumber("test-bash-scratch-limit-bytes", 0, std.math.maxInt(u64)),
    hiddenNumber("test-retention-entry-capacity", 2, retention_capacity.entries),
    hiddenFlag("test-retention-removal-failure"),
    hiddenNumber("test-provider-inactivity-seconds", 1, std.math.maxInt(i64) / 1_000_000_000),
    hiddenValue("test-retry-waits-ms"),
    // Integration fixtures order handoff through the model.before_handoff and
    // action.before_handoff pause points; only the model-retry qualification
    // runner, which measures the release product, still separates admission
    // from launch with this delay.
    hiddenNumber("test-before-launch-delay-ms", 0, 10_000),
    // Fixtures hold results at the model.result_ready and action.result_ready
    // pause points; only the model-control qualification runner still uses it.
    hiddenNumber("test-before-result-delay-ms", 0, 10_000),
    hiddenValue("test-retry-recovery-gate-path"),
    hiddenValue("test-inspection-reply-gate-path"),
    hiddenNumber("test-inspection-reply-delay-ms", 0, 60_000),
    hiddenNumber("test-client-send-buffer-bytes", 1, std.math.maxInt(c_int)),
    hiddenFlag("observe-allowance"),
    hiddenFlag("test-phase-trace"),
    hiddenNumber("test-observation-fd", 0, std.math.maxInt(c_int)),
    hiddenNumber("test-observation-state-fd", 0, std.math.maxInt(c_int)),
    hiddenValue("test-observation-plan"),
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
};

pub const definition: grammar.Definition = .{
    .resource = .host,
    .name = "serve",
    .description = "Run a foreground Host. Apply saved Host settings, then --settings FILE|- and repeated --set PATH=VALUE in order. Provider credentials belong to this Host, not its peer callers.",
    .options = settings_options ++ serve_test ++ if (@import("build_options").test_pauses) &[_]Option{hiddenNumber("test-pause-fd", 0, std.math.maxInt(c_int))} else &[_]Option{},
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

test "running Host sources have one syntax owner" {
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
        .{ .argv = &.{ "rui", "host", "serve", "--store", "/host", "--settings", "/document-\xff", "--set", "execution=@/values-\xff", "--" ++ settings_handoff.input_option, "5" }, .dir = "/host", .settings = "/document-\xff", .assignments = &.{"execution=@/values-\xff"} },
        // Syntax keeps source spellings; only admission can decide whether
        // their effective settings reproduce in a detached replacement.
        .{ .argv = &.{ "rui", "host", "serve", "--settings", "-" }, .settings = "-" },
        .{ .argv = &.{ "rui", "host", "serve", "--settings", "relative.json" }, .settings = "relative.json" },
        .{ .argv = &.{ "rui", "host", "serve", "--store", "/host", "--fault", "injected" }, .dir = "/host", .restartable = false },
        .{ .argv = &.{ "rui", "host", "serve", "--observe-allowance" }, .restartable = false },
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
    try std.testing.expectError(error.UnknownArgument, runningSources(arena.allocator(), &.{ "rui", "host", "serve", "--provider" }));
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

test "CM-56 allowance observer flag is explicit and defaults off" {
    var problem: grammar.Refusal = undefined;
    const absent = try definition.parseSyntax(&.{}, std.testing.allocator, &problem);
    try std.testing.expect(!absent.has("observe-allowance"));
    const enabled = try definition.parseSyntax(&.{"--observe-allowance"}, std.testing.allocator, &problem);
    try std.testing.expect(enabled.has("observe-allowance"));
}
