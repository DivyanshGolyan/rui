const std = @import("std");
const unit_partition = @import("../src/unit_test_partition.zig");
const darwin = @import("darwin.zig");
const product = @import("product.zig");
const CiArtifacts = @import("ci.zig").CiArtifacts;

/// Test executable identities and their filtered runnable owners. Both the build
/// and tests/ci/build_files.py consume these literal rows; keep each row whole.
pub const UnitRoot = struct {
    id: Id,
    name: []const u8,
    source: []const u8,
    target: []const u8,
    partition: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    filtered_only: bool = false,

    pub const Id = enum { native, store, filtered, deadline, logic, parser_seed, parser_llvm, h2, pg, mysql, native_pair };
};

pub const roots = [_]UnitRoot{
    .{ .id = .native, .name = "unit-native", .source = "src/tests.zig", .target = "test-native", .partition = "native" },
    .{ .id = .store, .name = "unit-store", .source = "src/tests.zig", .target = "test-store", .partition = "store" },
    .{ .id = .filtered, .name = "test", .source = "src/tests.zig", .target = "test", .filtered_only = true },
    .{ .id = .deadline, .name = "deadline-witness", .source = "src/tests.zig", .target = "test-full", .filter = "Host processing wait does not consume response transfer inactivity" },
    .{ .id = .logic, .name = "test", .source = "src/logic_tests.zig", .target = "test-logic-only" },
    .{ .id = .parser_seed, .name = "parser-fuzz", .source = "src/parser_fuzz_tests.zig", .target = "fuzz-parsers" },
    .{ .id = .parser_llvm, .name = "parser-fuzz-llvm", .source = "src/parser_fuzz_tests.zig", .target = "fuzz-parsers" },
    .{ .id = .h2, .name = "test", .source = "src/h2/h2.zig", .target = "test-h2" },
    .{ .id = .pg, .name = "test", .source = "src/store/wire/pg.zig", .target = "test-pg" },
    .{ .id = .mysql, .name = "rui-mysql-wire-test", .source = "tests/integration/mysql_wire_test.zig", .target = "mysql-wire-integration" },
};

/// A group owns its serial chain and its shell binary order as one item.
pub const UnitGroup = struct { id: UnitRoot.Id, roots: []const UnitRoot.Id, filtered: UnitRoot.Id };
pub const groups = [_]UnitGroup{
    .{ .id = .native_pair, .roots = &.{ .native, .store }, .filtered = .filtered },
};

pub const Part = enum { all, execution, callers };
pub const Composition = struct { gate: []const u8, items: []const UnitRoot.Id, parts: []const Part };
pub const compositions = [_]Composition{
    .{ .gate = "test-native", .items = &.{ .native, .filtered }, .parts = &.{.all} },
    .{ .gate = "test-store", .items = &.{ .store, .filtered }, .parts = &.{.all} },
    .{ .gate = "test", .items = &.{.native_pair}, .parts = &.{.all} },
    .{ .gate = "test-full", .items = &.{.deadline}, .parts = &.{.all} },
    .{ .gate = "test-logic", .items = &.{ .logic, .parser_seed }, .parts = &.{.all} },
    .{ .gate = "test-logic-only", .items = &.{.logic}, .parts = &.{.all} },
    .{ .gate = "fuzz-parsers", .items = &.{.parser_llvm}, .parts = &.{.all} },
    .{ .gate = "test-h2", .items = &.{.h2}, .parts = &.{.all} },
    .{ .gate = "test-pg", .items = &.{.pg}, .parts = &.{.all} },
    .{ .gate = "mysql-wire-integration", .items = &.{.mysql}, .parts = &.{.all} },
    .{ .gate = "check", .items = &.{ .native_pair, .h2, .pg }, .parts = &.{.all} },
    .{ .gate = "check-full", .items = &.{ .native_pair, .h2, .pg }, .parts = &.{ .all, .execution } },
};

pub fn root(id: UnitRoot.Id) UnitRoot {
    for (roots) |entry| if (entry.id == id) return entry;
    @panic("Unregistered unit root");
}

fn partitionRoot(partition: unit_partition.Root) UnitRoot {
    for (roots) |entry| {
        if (entry.partition) |name| if (std.mem.eql(u8, name, @tagName(partition))) return entry;
    }
    @panic("Unregistered unit partition");
}

pub fn group(id: UnitRoot.Id) UnitGroup {
    for (groups) |entry| if (entry.id == id) return entry;
    @panic("Unregistered unit group");
}

pub fn members(gate: []const u8, part: Part) []const UnitRoot.Id {
    for (compositions) |entry| {
        if (!std.mem.eql(u8, entry.gate, gate)) continue;
        for (entry.parts) |allowed| if (part == allowed) return entry.items;
        return &.{};
    }
    @panic("Unregistered unit composition");
}

pub fn includes(gate: []const u8, part: Part, id: UnitRoot.Id) bool {
    return std.mem.indexOfScalar(UnitRoot.Id, members(gate, part), id) != null;
}

pub const Runs = std.EnumArray(UnitRoot.Id, ?*std.Build.Step);
pub const Placement = enum { runs, shell };

/// Shell placement hands the grouped native binaries to check.sh instead of
/// launching their Run steps again. All other dependencies use the same table.
pub fn attach(gate: []const u8, part: Part, destination: *std.Build.Step, runs: *const Runs, placement: Placement) void {
    for (members(gate, part)) |id| {
        if (placement == .shell and id == .native_pair) continue;
        if (runs.get(id)) |step| destination.dependOn(step);
    }
}

pub const NativeGroup = struct { binaries: []*std.Build.Step.Compile, final: *std.Build.Step.Run };

/// Standalone roots never inherit siblings. The group's declaration alone
/// determines its serial dependencies and the binary order handed to the shell.
pub fn nativeGroup(b: *std.Build, ci: CiArtifacts, identities: []const UnitRoot.Id, tests: []const *std.Build.Step.Compile, filtered: bool) NativeGroup {
    const definition = group(.native_pair);
    const grouped = if (!filtered) definition.roots else &.{definition.filtered};
    if (grouped.len == 0) @panic("Native group must contain a unit root");
    const binaries = b.allocator.alloc(*std.Build.Step.Compile, grouped.len) catch @panic("OOM");
    var previous: ?*std.Build.Step.Run = null;
    for (grouped, binaries) |identity, *binary| {
        const index = std.mem.indexOfScalar(UnitRoot.Id, identities, identity) orelse @panic("Uncompiled native group member");
        binary.* = tests[index];
        const run = ci.run(tests[index]);
        run.has_side_effects = true;
        run.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "0");
        if (previous) |prior| run.step.dependOn(&prior.step);
        previous = run;
    }
    return .{ .binaries = binaries, .final = previous.? };
}

pub const Units = struct {
    tests: []*std.Build.Step.Compile,
    native_binaries: []*std.Build.Step.Compile,
    runs: Runs,
    run_renderer_allocation: *std.Build.Step.Run,
    signal_stack_probe: *std.Build.Step.Run,
};

pub fn add(b: *std.Build, ci: CiArtifacts, target: std.Build.ResolvedTarget, pinned_transport: ?product.PinnedTransport, test_filters: []const []const u8) Units {
    // Filtered developer/mutation runs retain the single aggregate binary and
    // its filter/global conventions. Unfiltered CI compiles independent roots.
    const native_group = group(.native_pair);
    if (native_group.roots.len == 0) @panic("Native group must contain a unit root");
    const identities = b.allocator.alloc(UnitRoot.Id, if (test_filters.len == 0) unit_partition.roots.len else 1) catch @panic("OOM");
    for (identities, 0..) |*identity, index| identity.* = if (test_filters.len == 0) partitionRoot(unit_partition.roots[index]).id else native_group.filtered;
    const tests = b.allocator.alloc(*std.Build.Step.Compile, identities.len) catch @panic("OOM");
    var runs: Runs = .initFill(null);
    const unit_filters = if (test_filters.len == 0) unitFilters(b) else undefined;
    const unit_runner: ?std.Build.LazyPath = if (test_filters.len == 0) runner: {
        const generate = b.addSystemCommand(&.{ "python3", "-B" });
        generate.addFileArg(b.path("tests/ci/unit_test_runner.py"));
        generate.addFileArg(std.Build.LazyPath.zig_lib.path(b, "compiler/test_runner.zig"));
        break :runner generate.addOutputFileArg("unit_test_runner.zig");
    } else null;
    // A filter that names no test in a unit step fails instead of passing empty.
    const filtered_runner: ?std.Build.Step.Compile.TestRunner = if (test_filters.len != 0) runner: {
        const generate = b.addSystemCommand(&.{ "python3", "-B" });
        generate.addFileArg(b.path("tests/ci/unit_test_runner.py"));
        generate.addArg("--filtered");
        generate.addFileArg(std.Build.LazyPath.zig_lib.path(b, "compiler/test_runner.zig"));
        break :runner .{ .path = generate.addOutputFileArg("filtered_test_runner.zig"), .mode = .server };
    } else null;
    const native_step = b.step(root(.native).target, "Run non-Store unit tests");
    const store_step = b.step(root(.store).target, "Run Store unit tests");
    for (tests, identities) |*entry, identity| {
        const definition = root(identity);
        const partition = if (definition.filtered_only) unit_partition.roots[0] else std.meta.stringToEnum(unit_partition.Root, definition.partition.?) orelse @panic("Unknown unit registry partition");
        const compile = b.addTest(.{
            .name = definition.name,
            .max_rss = darwin.unitMaxRss(test_filters.len, target),
            .use_llvm = if (target.result.cpu.arch == .x86_64) false else null,
            .root_module = b.createModule(.{
                .root_source_file = b.path(definition.source),
                .target = target,
                .optimize = .ReleaseSafe,
                .strip = darwin.unitStrip(test_filters.len, target),
            }),
            .filters = if (definition.filtered_only) test_filters else unit_filters[@backingInt(partition)],
            .test_runner = if (unit_runner) |path| .{ .path = path, .mode = .server } else filtered_runner,
        });
        entry.* = compile;
        if (unit_runner != null) {
            const options = b.addOptions();
            options.addOption(usize, "root", @backingInt(partition));
            compile.root_module.addOptions("unit_test_options", options);
            compile.root_module.addImport("unit_test_partition", b.createModule(.{
                .root_source_file = b.path("src/unit_test_partition.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
            }));
        }
        product.configureUnitRoot(b, compile, target, pinned_transport);
        if (!definition.filtered_only) {
            const standalone = ci.run(compile);
            standalone.has_side_effects = true;
            standalone.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "0");
            runs.set(identity, &standalone.step);
        }
    }
    const native = nativeGroup(b, ci, identities, tests, test_filters.len != 0);
    runs.set(.native_pair, &native.final.step);
    if (test_filters.len != 0) runs.set(native_group.filtered, &native.final.step);
    const test_step = b.step(root(.filtered).target, "Run unit, Store, and protocol tests");
    // Selection pairs test-full with check or check-full, which already run every
    // other native test, so this binary contains only the real-time witness.
    // Like normal units, the x86_64 witness uses the self-hosted backend;
    // other targets retain LLVM. ReleaseSafe checks stay enabled.
    const deadline_witness = b.addTest(.{
        .use_llvm = if (target.result.cpu.arch == .x86_64) false else null,
        .name = root(.deadline).name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root(.deadline).source),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = if (test_filters.len != 0) test_filters else &.{root(.deadline).filter.?},
        .test_runner = filtered_runner,
    });
    product.configureUnitRoot(b, deadline_witness, target, pinned_transport);
    const run_full_tests = ci.run(deadline_witness);
    run_full_tests.has_side_effects = true;
    run_full_tests.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "1");
    const full_test_step = b.step(root(.deadline).target, "Run the real 60-second client deadline witness");
    runs.set(.deadline, &run_full_tests.step);

    const logic_tests = b.addTest(.{
        .name = root(.logic).name,
        .use_llvm = if (target.result.cpu.arch == .x86_64) false else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root(.logic).source),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = test_filters,
        .test_runner = filtered_runner,
    });
    product.configureTerminalEditor(b, logic_tests);
    logic_tests.root_module.addImport("url", product.addUrl(b));
    const run_logic_tests = ci.run(logic_tests);
    run_logic_tests.has_side_effects = true;
    const logic_test_step = b.step(
        "test-logic",
        "Run the shared execution turn and portable owner tests without Host, Bash, or transport fixtures",
    );
    runs.set(.logic, &run_logic_tests.step);
    const logic_only_step = b.step(root(.logic).target, "Run the logic test binary without auxiliary executables");

    // The fuzz tests of the parsers that read peer bytes. test-logic runs
    // their seeds, with Zig's runner so a filter for another root's test
    // passes here; fuzz-parsers owns filtered runs and builds them with
    // LLVM, whose coverage counters a live campaign (--fuzz) steers by.
    // Their root links no C: --fuzz instruments every object it links, and
    // the stock compiler gives C objects no `__sanitizer_cov_trace_*` hooks.
    const parser_fuzz_step = b.step(
        root(.parser_llvm).target,
        "Run the peer-byte parser fuzz tests with LLVM coverage; add --fuzz for a live campaign",
    );
    for ([_]struct { UnitRoot, ?bool, ?std.Build.Step.Compile.TestRunner }{
        .{ root(.parser_seed), if (target.result.cpu.arch == .x86_64) false else null, null },
        .{ root(.parser_llvm), true, filtered_runner },
    }) |entry| {
        const definition, const use_llvm, const runner = entry;
        const parser_fuzz = b.addTest(.{
            .name = definition.name,
            .use_llvm = use_llvm,
            .root_module = b.createModule(.{
                .root_source_file = b.path(definition.source),
                .target = target,
                .optimize = .ReleaseSafe,
            }),
            .filters = test_filters,
            .test_runner = runner,
        });
        parser_fuzz.root_module.addImport("url", product.addUrl(b));
        const run = ci.run(parser_fuzz);
        run.has_side_effects = true;
        runs.set(definition.id, &run.step);
    }

    const test_actor_llvm: ?bool = if (target.result.cpu.arch == .x86_64) false else null;
    const renderer_allocation = b.addExecutable(.{
        .name = "rui-answer-renderer-allocation-test",
        .use_llvm = test_actor_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/answer_renderer_allocation.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const answer_renderer = b.createModule(.{
        .root_source_file = b.path("src/AnswerRenderer.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const terminal = b.dependency("vaxis", .{ .target = target, .optimize = std.builtin.OptimizeMode.ReleaseSafe });
    answer_renderer.addImport("terminal_width", terminal.module("gwidth"));
    answer_renderer.addImport("terminal_unicode", terminal.module("unicode"));
    renderer_allocation.root_module.addImport("AnswerRenderer", answer_renderer);
    const run_renderer_allocation = ci.run(renderer_allocation);
    logic_test_step.dependOn(&run_renderer_allocation.step);
    test_step.dependOn(&run_renderer_allocation.step);
    native_step.dependOn(&run_renderer_allocation.step);

    const signal_stack_probe = ci.run(b.addExecutable(.{
        .name = "rui-signal-stack-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/signal_stack_probe.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    }));
    signal_stack_probe.has_side_effects = true;
    test_step.dependOn(&signal_stack_probe.step);
    native_step.dependOn(&signal_stack_probe.step);

    for ([_]struct { []const u8, *std.Build.Step }{
        .{ root(.native).target, native_step },
        .{ root(.store).target, store_step },
        .{ root(.filtered).target, test_step },
        .{ root(.deadline).target, full_test_step },
        .{ "test-logic", logic_test_step },
        .{ root(.logic).target, logic_only_step },
        .{ root(.parser_llvm).target, parser_fuzz_step },
    }) |entry| attach(entry[0], .all, entry[1], &runs, .runs);
    return .{ .tests = tests, .native_binaries = native.binaries, .runs = runs, .run_renderer_allocation = run_renderer_allocation, .signal_stack_probe = signal_stack_probe };
}

// Compiler filters are a superset of exact runner ownership. Module-only
// substrings are too broad: "tests." also matches "store.tests." and recompiles
// most of the suite. Tokenize declarations so new tests need no second manifest.
// Compiler filters avoid analyzing/code-generating other roots' named tests.
// Use module.test. rather than module.: "tests." also matches Store's tests!
// Anonymous tests bypass Zig filters; the generated runner partitions those.
// Keep discovery imports in tests.zig eager (not hidden inside a named test).
fn unitFilters(b: *std.Build) [unit_partition.roots.len][]const []const u8 {
    const io = b.graph.io;
    var lists: [unit_partition.roots.len]std.ArrayList([]const u8) = @splat(.empty);
    var directory = b.root.openDir(io, "src", .{ .iterate = true }) catch @panic("Cannot open unit sources");
    defer directory.close(io);
    b.dependOnDirectoryContents(b.path("src"));
    var walker = directory.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch @panic("Cannot enumerate unit sources")) |entry| {
        if (entry.kind == .directory) b.dependOnDirectoryContents(b.path(b.fmt("src/{s}", .{entry.path})));
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const prefix = b.fmt("{s}.", .{entry.path[0 .. entry.path.len - 4]});
        std.mem.replaceScalar(u8, prefix, std.fs.path.sep, '.');
        const index = @backingInt(unit_partition.owner(prefix));
        b.dependOnFileContents(b.path(b.fmt("src/{s}", .{entry.path})));
        const source = entry.dir.readFileAllocOptions(io, entry.basename, b.allocator, .limited(16 * 1024 * 1024), .of(u8), 0) catch @panic("Cannot read unit source");
        var tokenizer = std.zig.Tokenizer.init(source);
        var depth: usize = 0;
        var top_level_added = false;
        while (true) {
            const token = tokenizer.next();
            switch (token.tag) {
                .eof => break,
                .l_brace => depth += 1,
                .r_brace => depth -= 1,
                .keyword_test => {
                    const name = tokenizer.next();
                    if (name.tag == .l_brace) {
                        depth += 1; // Anonymous discovery tests bypass compiler filters.
                        continue;
                    }
                    if (depth == 0 and !std.mem.eql(u8, entry.path, "tests.zig")) {
                        if (!top_level_added) lists[index].append(b.allocator, b.fmt("{s}test.", .{prefix})) catch @panic("OOM");
                        top_level_added = true;
                        continue;
                    }
                    const spelling = source[name.loc.start..name.loc.end];
                    const text = switch (name.tag) {
                        .string_literal => std.zig.string_literal.parseAlloc(b.allocator, spelling) catch @panic("Invalid test name"),
                        .identifier => if (std.mem.startsWith(u8, spelling, "@\""))
                            std.zig.string_literal.parseAlloc(b.allocator, spelling[1..]) catch @panic("Invalid test name")
                        else
                            spelling,
                        else => @panic("Invalid test declaration"),
                    };
                    // Nested container names are compiler-owned. Use a literal
                    // fragment for these rare cases; runner ownership resolves
                    // overlap. Avoid quotes/backslashes in Zig response files.
                    var fragments = std.mem.tokenizeAny(u8, text, "'\"\\\n\r\t");
                    var fragment: []const u8 = "";
                    while (fragments.next()) |part| if (part.len > fragment.len) {
                        fragment = part;
                    };
                    lists[index].append(b.allocator, if (fragment.len != 0) fragment else ".test.") catch @panic("OOM");
                },
                else => {},
            }
        }
    }
    var filters: [unit_partition.roots.len][]const []const u8 = undefined;
    for (&lists, &filters) |*list, *result| {
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, c: []const u8) bool {
                return std.mem.lessThan(u8, a, c);
            }
        }.lessThan);
        result.* = list.toOwnedSlice(b.allocator) catch @panic("OOM");
    }
    return filters;
}
