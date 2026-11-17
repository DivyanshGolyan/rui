const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn screenLibraryName(host: std.Target.Os.Tag) []const u8 {
    return if (host.isDarwin()) "libghostty-vt.dylib" else "libghostty-vt.so";
}

pub fn unitMaxRss(filter_count: usize, target: std.Build.ResolvedTarget) usize {
    return if (filter_count == 0 and target.result.os.tag == .macos) 3 * 1024 * 1024 * 1024 else 0;
}

pub fn unitStrip(filter_count: usize, target: std.Build.ResolvedTarget) ?bool {
    return if (filter_count == 0 and target.result.os.tag == .macos) true else null;
}

pub fn addSdkPaths(b: *std.Build, module: *std.Build.Module, bindings: Translator, output: std.Build.LazyPath) void {
    module.addSystemFrameworkPath(output.path(b, "sdk/System/Library/Frameworks"));
    module.addSystemIncludePath(output.path(b, "sdk/usr/include"));
    module.addLibraryPath(output.path(b, "sdk/usr/lib"));
    bindings.addSystemFrameworkPath(output.path(b, "sdk/System/Library/Frameworks"));
    bindings.addSystemIncludePath(output.path(b, "sdk/usr/include"));
}

pub fn linkTrust(module: *std.Build.Module) void {
    module.linkFramework("Security", .{});
    module.linkFramework("CoreFoundation", .{});
}

/// Verified native Mac acceptance can buffer output instead of owning the terminal.
pub fn configureAcceptance(b: *std.Build, artifacts: ?[]const u8) void {
    if (artifacts != null and b.graph.host.result.os.tag == .macos)
        @import("ci.zig").concurrentAcceptance(b);
}
