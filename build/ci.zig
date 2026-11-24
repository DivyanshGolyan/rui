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

fn sourceStem(path: std.Build.LazyPath) []const u8 {
    const name = switch (path) {
        .src_path => |source| source.sub_path,
        .dependency => |source| source.sub_path,
        .cwd_relative => |source| source,
        .generated => |source| source.sub_path,
        .relative => |source| source.sub_path,
    };
    return if (name.len == 0) path.getDisplayName() else std.fs.path.stem(name);
}

fn ciName(b: *std.Build, compile: *std.Build.Step.Compile) []const u8 {
    return if (compile.kind == .@"test")
        b.fmt("{s}-{s}", .{ compile.name, sourceStem(compile.root_module.root_source_file.?) })
    else
        compile.name;
}

test "CI artifact names accept source and dependency roots" {
    const source: std.Build.LazyPath = .{ .src_path = .{ .owner = undefined, .sub_path = "src/tests.zig" } };
    const local_c: std.Build.LazyPath = .{ .src_path = .{ .owner = undefined, .sub_path = "src/c_api.zig" } };
    const dependency: std.Build.LazyPath = .{ .dependency = .{ .dependency = undefined, .sub_path = "src/c_api.zig" } };
    try std.testing.expectEqualStrings("tests", sourceStem(source));
    try std.testing.expectEqualStrings("c_api", sourceStem(dependency));
    try std.testing.expectEqualStrings(sourceStem(local_c), sourceStem(dependency));
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
