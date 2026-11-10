const std = @import("std");
const product = @import("product.zig");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, pinned_transport: product.PinnedTransport) void {
    const linux_cross_step = b.step(
        "cross-check-linux",
        "Compile Linux x86-64 and experimental Linux ARM64",
    );
    const yaml_linux_step = b.step(
        "yaml-linux-compile",
        "Compile pinned libyaml as strict C99 for Linux x86-64 and ARM64 without running it",
    );
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const yaml_linux = b.addLibrary(.{
            .name = b.fmt("yaml-linux-{s}", .{@tagName(arch)}),
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .gnu }),
                .optimize = .ReleaseSafe,
                .link_libc = true,
            }),
        });
        product.configureYaml(b, yaml_linux);
        yaml_linux_step.dependOn(&yaml_linux.step);
    }
    const macos_cross_step = b.step(
        "cross-check-macos",
        "Compile Apple Silicon macOS and experimental Intel macOS (requires Xcode/Command Line Tools)",
    );
    const cross_step = b.step(
        "cross-check",
        "Compile supported native and experimental Linux/macOS architectures (not runtime qualification)",
    );
    cross_step.dependOn(linux_cross_step);
    cross_step.dependOn(macos_cross_step);
    const macos_types_step = b.step(
        "typecheck-macos",
        "Type-check Rui and its unit tests for Apple Silicon macOS on any host (no SDK, link or run)",
    );
    {
        const apple = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
        macos_types_step.dependOn(&product.addRui(b, apple, .ReleaseSafe, "rui-typecheck-macos", null).step);
        const apple_tests = b.addTest(.{
            .name = "test-typecheck-macos",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tests.zig"),
                .target = apple,
                .optimize = .ReleaseSafe,
            }),
        });
        product.configureUnitRoot(b, apple_tests, apple, null);
        macos_types_step.dependOn(&apple_tests.step);
    }
    const targets = [_]std.Target.Query{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    };
    for (targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const cross_transport = if (product.sameTransportTarget(target, resolved))
            pinned_transport
        else
            product.addPinnedTransport(b, resolved);
        const executable = product.addRui(
            b,
            resolved,
            .ReleaseSmall,
            b.fmt("rui-{s}-{s}", .{
                @tagName(resolved.result.cpu.arch),
                @tagName(resolved.result.os.tag),
            }),
            cross_transport,
        );
        switch (resolved.result.os.tag) {
            .linux => {
                linux_cross_step.dependOn(&executable.step);
            },
            .macos => {
                macos_cross_step.dependOn(&executable.step);
            },
            else => unreachable,
        }
    }
}
