const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const library = b.dependency("ghostty_vt", .{ .target = target, .optimize = .ReleaseFast }).artifact("ghostty-vt");
    const name = if (target.result.os.tag.isDarwin()) "libghostty-vt.dylib" else "libghostty-vt.so";
    b.getInstallStep().dependOn(&b.addInstallLibFile(library.getEmittedBin(), name).step);
}
