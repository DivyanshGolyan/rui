const std = @import("std");
const ScreenEmulator = @import("screen.zig").ScreenEmulator;

/// Unit roots compile independently on their own producer, beside the other gates.
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
        // The child build's library rides with the executables, so consumers
        // neither fetch ghostty's packages nor build it again.
        if (collection.screen.child) |child| if (source == &child.step) {
            if (collection.part != .unit)
                collection.destination.dependOn(&b.addInstallBinFile(collection.screen.library, collection.screen.name).step);
            return;
        };
        for (source.dependencies.items) |dependency| collection.collect(dependency);
    }
};

fn ciName(b: *std.Build, compile: *std.Build.Step.Compile) []const u8 {
    // Test roots can use Zig's default executable name; distinguish their
    // source-owned roots without changing normal compilation or cache keys.
    return if (compile.kind == .@"test")
        b.fmt("{s}-{s}", .{ compile.name, std.fs.path.stem(compile.root_module.root_source_file.?.src_path.sub_path) })
    else
        compile.name;
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
