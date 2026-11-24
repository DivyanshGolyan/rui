const std = @import("std");
const ScreenEmulator = @import("screen.zig").ScreenEmulator;

pub const CiPart = enum { all, unit, rest };

pub const CiCollection = struct {
    b: *std.Build,
    destination: *std.Build.Step,
    part: CiPart,
    unit: []const *std.Build.Step.Compile,
    screen: ScreenEmulator,
    visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty,
    reached_unit: bool = false,

    pub fn collect(collection: *CiCollection, source: *std.Build.Step) void {
        const b = collection.b;
        const entry = collection.visited.getOrPut(b.allocator, source) catch @panic("OOM");
        if (entry.found_existing) return;
        if (source.cast(std.Build.Step.Compile)) |compile| {
            const unit = std.mem.indexOfScalar(*std.Build.Step.Compile, collection.unit, compile) != null;
            collection.reached_unit = collection.reached_unit or unit;
            const emit = switch (collection.part) {
                .all => true,
                .unit => unit,
                .rest => !unit,
            };
            if (emit) collection.destination.dependOn(&b.addInstallBinFile(compile.getEmittedBin(), ciName(b, compile)).step);
            return;
        }
        if (collection.screen.child) |child| if (source == &child.step) {
            if (collection.part != .unit)
                collection.destination.dependOn(&b.addInstallBinFile(collection.screen.library, collection.screen.name).step);
            return;
        };
        for (source.dependencies.items) |dependency| collection.collect(dependency);
    }
};

pub fn testArtifactName(allocator: std.mem.Allocator, name: []const u8, root: std.Build.LazyPath) (std.mem.Allocator.Error || error{UnsupportedTestRoot})![]u8 {
    const path = switch (root) {
        .src_path => |source| source.sub_path,
        .dependency => |source| source.sub_path,
        else => return error.UnsupportedTestRoot,
    };
    if (path.len == 0) return error.UnsupportedTestRoot;
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, std.fs.path.stem(path) });
}

fn ciName(b: *std.Build, compile: *std.Build.Step.Compile) []const u8 {
    return if (compile.kind == .@"test")
        testArtifactName(b.allocator, compile.name, compile.root_module.root_source_file.?) catch @panic("Unsupported CI test root or out of memory")
    else
        compile.name;
}

test "CI-101 CI artifact names preserve root identity" {
    const cases = [_]std.Build.LazyPath{
        .{ .src_path = .{ .owner = undefined, .sub_path = "src/c_api.zig" } },
        .{ .dependency = .{ .dependency = undefined, .sub_path = "src/c_api.zig" } },
    };
    for (cases) |root| {
        const actual = try testArtifactName(std.testing.allocator, "reader", root);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("reader-c_api", actual);
    }
    for ([_]std.Build.LazyPath{
        .{ .src_path = .{ .owner = undefined, .sub_path = "" } },
        .{ .dependency = .{ .dependency = undefined, .sub_path = "" } },
        .{ .cwd_relative = "tmp/tests.zig" },
        .{ .generated = .{ .index = @fromBackingInt(@intCast(0)) } },
        .{ .relative = .{ .base = .local_cache, .sub_path = "tmp/output.zig" } },
    }) |root| try std.testing.expectError(error.UnsupportedTestRoot, testArtifactName(std.testing.allocator, "reader", root));
}

pub const CiArtifacts = struct {
    b: *std.Build,
    directory: ?[]const u8,

    pub fn path(ci: CiArtifacts, compile: *std.Build.Step.Compile) std.Build.LazyPath {
        return if (ci.directory) |directory|
            .{ .cwd_relative = ci.b.pathJoin(&.{ directory, ciName(ci.b, compile) }) }
        else
            compile.getEmittedBin();
    }

    pub fn run(ci: CiArtifacts, compile: *std.Build.Step.Compile) *std.Build.Step.Run {
        if (ci.directory == null) return ci.b.addRunArtifact(compile);
        const command = ci.b.addRunFile(ci.path(compile));
        if (compile.kind == .@"test") command.enableTestRunnerMode();
        return command;
    }
};

pub fn nameTests(b: *std.Build, ci: CiArtifacts, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const tests = b.addTest(.{
        .name = "test-ci-artifact-names",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/ci.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"CI artifact names"},
    });
    return &ci.run(tests).step;
}

/// Keep acceptance fresh while allowing Zig to overlap independent commands.
/// Inherited stdio holds Zig's global stderr lock for the command's lifetime.
/// Checked stderr is buffered and reported on success and failure; route stdout
/// there as well so fixture diagnostics and quarantine signatures remain visible.
pub fn concurrentAcceptance(b: *std.Build) void {
    var visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    for (b.top_level_steps.values()) |root| concurrentStep(b, &root.step, &visited);
}

fn concurrentStep(b: *std.Build, step: *std.Build.Step, visited: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    const entry = visited.getOrPut(b.allocator, step) catch @panic("OOM");
    if (entry.found_existing or step.cast(std.Build.Step.Compile) != null) return;
    if (step.cast(std.Build.Step.Run)) |run| {
        // Generators, explicit I/O checks and Zig's test protocol own their I/O.
        if (run.stdio != .infer_from_args or run.captured_stdout != null or run.captured_stderr != null) return;
        for (run.argv.items) |arg| switch (arg) {
            .output_file, .output_file_dep, .output_directory => return,
            else => {},
        };
        run.argv.insertSlice(b.allocator, 0, &.{
            .{ .bytes = "sh" },              .{ .bytes = "-c" },
            .{ .bytes = "exec \"$@\" >&2" }, .{ .bytes = "rui-acceptance" },
        }) catch @panic("OOM");
        run.expectExitCode(0);
        run.has_side_effects = true;
    }
    for (step.dependencies.items) |dependency| concurrentStep(b, dependency, visited);
}
