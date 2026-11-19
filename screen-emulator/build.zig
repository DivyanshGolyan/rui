const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // CI passes -Dcpu=baseline for the native platform; its host tools (ghostty's generators) must build for
    // that CPU too. Locally the target is the host itself, so this changes nothing.
    if (target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch)
        b.graph.host = target;
    const library = b.dependency("ghostty_vt", .{ .target = target, .optimize = .ReleaseFast }).artifact("ghostty-vt");
    const name = if (target.result.os.tag.isDarwin()) "libghostty-vt.dylib" else "libghostty-vt.so";
    b.getInstallStep().dependOn(&b.addInstallLibFile(library.getEmittedBin(), name).step);
}
