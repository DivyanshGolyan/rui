const std = @import("std");

pub fn add(b: *std.Build, dependency: *std.Build.Dependency) *std.Build.Module {
    const overlay_name = "rui-vaxis-overlay";
    const source = b.named_lazy_paths.get(overlay_name) orelse blk: {
        // Leave the package cache intact. Zig tracks the pinned source, patch,
        // and generated tree as inputs and output of this one build step.
        const apply = b.addSystemCommand(&.{
            "sh",         "-ec",
            \\mkdir -p "$3"
            \\cp -R "$1/." "$3"
            \\LC_ALL=C patch -f -s -F 0 -d "$3" -p1 -i "$2"
            ,
            overlay_name,
        });
        apply.addDirectoryArg2(dependency.path("src"), .{ .make_absolute = true });
        apply.addFileArg2(b.path("build/vaxis_overlay.patch"), .{ .make_absolute = true });
        const generated = apply.addOutputDirectoryArg2(overlay_name, .{ .make_absolute = true });
        b.addNamedLazyPath(overlay_name, generated);
        break :blk generated;
    };
    const upstream = dependency.module("vaxis");
    const module = b.createModule(.{
        .root_source_file = source.path(b, "main.zig"),
        .target = upstream.resolved_target,
        .optimize = upstream.optimize,
    });
    for (upstream.import_table.keys(), upstream.import_table.values()) |name, imported| {
        module.addImport(name, imported);
    }

    const test_name = "test-vaxis-overlay";
    if (!b.top_level_steps.contains(test_name)) {
        const tests = b.addTest(.{
            .name = test_name,
            .root_module = module,
            // The dependency loads its nested test modules via refAllDecls.
            .filters = &.{ "test.refAllDecls", "OSC 5522 transport" },
        });
        b.step(test_name, "Test Vaxis OSC 5522 transport").dependOn(&b.addRunArtifact(tests).step);
    }
    return module;
}
