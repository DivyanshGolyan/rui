const std = @import("std");
const unit_partition = @import("../src/unit_test_partition.zig");
const darwin = @import("darwin.zig");
const product = @import("product.zig");
const CiArtifacts = @import("ci.zig").CiArtifacts;

pub const Units = struct {
    tests: []*std.Build.Step.Compile,
    run_tests: *std.Build.Step.Run,
    run_renderer_allocation: *std.Build.Step.Run,
    signal_stack_probe: *std.Build.Step.Run,
};

pub fn add(b: *std.Build, ci: CiArtifacts, target: std.Build.ResolvedTarget, pinned_transport: ?product.PinnedTransport, test_filters: []const []const u8) Units {
    // Filtered developer/mutation runs retain the single aggregate binary and
    // its filter/global conventions. Unfiltered CI compiles independent roots.
    const tests = b.allocator.alloc(*std.Build.Step.Compile, if (test_filters.len == 0) unit_partition.roots.len else 1) catch @panic("OOM");
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
    const native_step = b.step("test-native", "Run non-Store unit tests");
    const store_step = b.step("test-store", "Run Store unit tests");
    var run_tests: *std.Build.Step.Run = undefined;
    for (tests, 0..) |*entry, index| {
        const root = unit_partition.roots[index];
        const compile = b.addTest(.{
            .name = if (test_filters.len != 0) "test" else b.fmt("unit-{s}", .{@tagName(root)}),
            .max_rss = darwin.unitMaxRss(test_filters.len, target),
            .use_llvm = if (target.result.cpu.arch == .x86_64) false else null,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tests.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
                .strip = darwin.unitStrip(test_filters.len, target),
            }),
            .filters = if (test_filters.len != 0) test_filters else unit_filters[index],
            .test_runner = if (unit_runner) |path| .{ .path = path, .mode = .server } else filtered_runner,
        });
        entry.* = compile;
        if (unit_runner != null) {
            const options = b.addOptions();
            options.addOption(usize, "root", index);
            compile.root_module.addOptions("unit_test_options", options);
            compile.root_module.addImport("unit_test_partition", b.createModule(.{
                .root_source_file = b.path("src/unit_test_partition.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
            }));
        }
        product.configureUnitRoot(b, compile, target, pinned_transport);
        const run = ci.run(compile);
        run.has_side_effects = true;
        run.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "0");
        if (test_filters.len != 0) {
            native_step.dependOn(&run.step);
            store_step.dependOn(&run.step);
        } else {
            const standalone = ci.run(compile);
            standalone.has_side_effects = true;
            standalone.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "0");
            (if (root == .native) native_step else store_step).dependOn(&standalone.step);
        }
        // Compile in parallel, execute serially: the MySQL dialect fixture owns
        // fixed database names. Store runs last and owns the acceptance record
        // (including migrations/conformance); never mask an earlier failure.
        if (index != 0) run.step.dependOn(&run_tests.step);
        run_tests = run;
    }

    const test_step = b.step("test", "Run unit, Store, and protocol tests");
    test_step.dependOn(&run_tests.step);
    // Selection pairs test-full with check or check-full, which already run every
    // other native test, so this binary contains only the real-time witness.
    // Like normal units, the x86_64 witness uses the self-hosted backend;
    // other targets retain LLVM. ReleaseSafe checks stay enabled.
    const deadline_witness = b.addTest(.{
        .use_llvm = if (target.result.cpu.arch == .x86_64) false else null,
        .name = "deadline-witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = if (test_filters.len != 0) test_filters else &.{"Host processing wait does not consume response transfer inactivity"},
        .test_runner = filtered_runner,
    });
    product.configureUnitRoot(b, deadline_witness, target, pinned_transport);
    const run_full_tests = ci.run(deadline_witness);
    run_full_tests.has_side_effects = true;
    run_full_tests.setEnvironmentVariable("RUI_TEST_EXACT_INACTIVITY", "1");
    const full_test_step = b.step("test-full", "Run the real 60-second client deadline witness");
    full_test_step.dependOn(&run_full_tests.step);

    const logic_tests = b.addTest(.{
        .use_llvm = if (target.result.cpu.arch == .x86_64) false else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/logic_tests.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = test_filters,
        .test_runner = filtered_runner,
    });
    product.configureTerminalEditor(b, logic_tests);
    const run_logic_tests = ci.run(logic_tests);
    run_logic_tests.has_side_effects = true;
    const logic_test_step = b.step(
        "test-logic",
        "Run the shared execution turn and portable owner tests without Host, Bash, or transport fixtures",
    );
    logic_test_step.dependOn(&run_logic_tests.step);

    // The fuzz tests of the parsers that read peer bytes. test-logic runs
    // their seeds, with Zig's runner so a filter for another root's test
    // passes here; fuzz-parsers owns filtered runs and builds them with
    // LLVM, whose coverage counters a live campaign (--fuzz) steers by.
    // Their root links no C: --fuzz instruments every object it links, and
    // the stock compiler gives C objects no `__sanitizer_cov_trace_*` hooks.
    const parser_fuzz_step = b.step(
        "fuzz-parsers",
        "Run the peer-byte parser fuzz tests with LLVM coverage; add --fuzz for a live campaign",
    );
    for ([_]struct { []const u8, *std.Build.Step, ?bool, ?std.Build.Step.Compile.TestRunner }{
        .{ "parser-fuzz", logic_test_step, if (target.result.cpu.arch == .x86_64) false else null, null },
        .{ "parser-fuzz-llvm", parser_fuzz_step, true, filtered_runner },
    }) |entry| {
        const name, const step, const use_llvm, const runner = entry;
        const parser_fuzz = b.addTest(.{
            .name = name,
            .use_llvm = use_llvm,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/parser_fuzz_tests.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
            }),
            .filters = test_filters,
            .test_runner = runner,
        });
        const run = ci.run(parser_fuzz);
        run.has_side_effects = true;
        step.dependOn(&run.step);
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

    return .{ .tests = tests, .run_tests = run_tests, .run_renderer_allocation = run_renderer_allocation, .signal_stack_probe = signal_stack_probe };
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
