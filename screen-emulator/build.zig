//! libghostty-vt for the PTY screen observer (tests/integration/terminal_screen.py).
//! It is a package of its own so that installs, which fetch the root
//! manifest's whole graph, never fetch it; the root build runs this one as a
//! child `zig build` for the steps that run the observer. It sits outside
//! src/ and tests/ because Zig keeps its fetched packages in its own zig-pkg,
//! which the checks that scan those trees as sources must not see.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const library = b.dependency("ghostty_vt", .{ .target = target, .optimize = .ReleaseFast }).artifact("ghostty-vt");
    // One unversioned file, without the soname links, so the observer and the
    // CI artifact handoff each name it the same way on every system.
    const name = if (target.result.os.tag.isDarwin()) "libghostty-vt.dylib" else "libghostty-vt.so";
    b.getInstallStep().dependOn(&b.addInstallLibFile(library.getEmittedBin(), name).step);
}
