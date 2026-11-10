const std = @import("std");
const darwin = @import("darwin.zig");
const CiArtifacts = @import("ci.zig").CiArtifacts;

pub const ScreenEmulator = struct {
    library: std.Build.LazyPath,
    name: []const u8,
    /// The child build; null in a CI consumer, whose producer ran it.
    child: ?*std.Build.Step.Run,
};

/// libghostty-vt's shared library for the PTY screen observer, which a child
/// `zig build` of screen-emulator builds from its pinned release tarball.
/// A CI producer builds it for the baseline CPU, as its executables are.
pub fn addScreenEmulator(b: *std.Build, ci: CiArtifacts, baseline: bool) ScreenEmulator {
    const name = darwin.screenLibraryName(b.graph.host.result.os.tag);
    if (ci.directory) |directory|
        return .{ .library = .{ .cwd_relative = b.pathJoin(&.{ directory, name }) }, .name = name, .child = null };
    const child = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "install", "--summary", "none", "--build-file" });
    child.addFileArg(b.path("screen-emulator/build.zig"));
    child.addFileInput(b.path("screen-emulator/build.zig.zon"));
    if (baseline) child.addArg("-Dcpu=baseline");
    child.addArg("--cache-dir");
    child.addDirectoryArg(std.Build.LazyPath.cache_root);
    child.addArg("--prefix");
    const prefix = child.addOutputDirectoryArg("screen");
    // Zig refuses ghostty's path dependencies from a package directory
    // outside screen-emulator, so the child keeps its own screen-emulator/zig-pkg.
    child.removeEnvironmentVariable("ZIG_LOCAL_PKG_DIR");
    return .{ .library = prefix.path(b, b.pathJoin(&.{ "lib", name })), .name = name, .child = child };
}

/// A fixture command whose environment names the screen observer's library.
pub fn screenCommand(b: *std.Build, screen: std.Build.LazyPath, argv: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"env"});
    run.addPrefixedFileArg("RUI_TEST_GHOSTTY_VT=", screen);
    run.addArgs(argv);
    return run;
}

/// Runs a direct-PTY harness against the build-owned ReleaseSafe Rui; callers
/// pass the harness's own options, including a fresh --output, after `--`.
pub fn addPtyHarness(b: *std.Build, screen: std.Build.LazyPath, harness: []const u8, rui: std.Build.LazyPath) *std.Build.Step.Run {
    const run = screenCommand(b, screen, &.{"python3"});
    run.addFileArg(b.path(harness));
    run.addFileArg(rui);
    run.addPassthruArgs();
    run.has_side_effects = true;
    return run;
}
