//! The build graph's package links: for each top-level build step, the dependency packages (the names in
//! build.zig.zon) that its artifacts compile or link. The walk reads the graph at configure time, so a
//! package reached through a generated file, a translated header or a transitive dependency still counts.
//! `zig build link-table` rewrites build/link_table.json; `zig build check` fails while the checked-in
//! table differs from the walk. tests/ci/select_tests.py reads the table to select every target a changed
//! dependency reaches.
const std = @import("std");
const Step = std.Build.Step;
const Module = std.Build.Module;
const LazyPath = std.Build.LazyPath;

pub const table_path = "build/link_table.json";

/// The files whose contents fingerprint the table. tests/ci/link_table.py recomputes the same digest, so
/// `fingerprint` (a cheap policy check) fails when the build changed and the table was not regenerated.
fn inputsDigest(b: *std.Build) []const u8 {
    const io = b.graph.io;
    var names: std.ArrayList([]const u8) = .empty;
    names.appendSlice(b.allocator, &.{ "build.zig", "build.zig.zon" }) catch @panic("OOM");
    var directory = b.root.openDir(io, "build", .{ .iterate = true }) catch @panic("Cannot open build/");
    defer directory.close(io);
    var walker = directory.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch @panic("Cannot enumerate build/")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        names.append(b.allocator, b.fmt("build/{s}", .{entry.path})) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (names.items) |name| {
        const contents = b.root.root_dir.handle.readFileAlloc(io, b.pathJoin(&.{ b.root.sub_path, name }), b.allocator, .limited(64 * 1024 * 1024)) catch
            std.debug.panic("cannot read link table input {s}", .{name});
        hash.update(name);
        hash.update(&.{0});
        hash.update(contents);
        hash.update(&.{0});
    }
    const digest = hash.finalResult();
    return b.fmt("{x}", .{digest[0..16]});
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Collects the packages reached from one step. Each walk has its own visited sets.
const Walk = struct {
    b: *std.Build,
    steps: std.AutoHashMapUnmanaged(*Step, void) = .empty,
    modules: std.AutoHashMapUnmanaged(*Module, void) = .empty,
    packages: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn lazy(walk: *Walk, path: LazyPath) void {
        switch (path) {
            .src_path => |source| walk.owner(source.owner),
            .dependency => |dependency| walk.owner(dependency.dependency.builder),
            .generated => |generated| walk.step(walk.b.graph.generated_files.items[@backingInt(generated.index)]),
            .relative, .cwd_relative => {},
        }
    }

    /// A builder's `dep_prefix` names its dependency path ("vaxis." or "vaxis.uucode.") and is empty for
    /// the root. The first name is the direct dependency in build.zig.zon, so a transitive package counts
    /// toward the dependency that brought it in.
    fn owner(walk: *Walk, builder: *std.Build) void {
        const prefix = builder.dep_prefix;
        if (prefix.len == 0) return;
        const end = std.mem.indexOfScalar(u8, prefix, '.') orelse prefix.len;
        walk.packages.put(walk.b.allocator, prefix[0..end], {}) catch @panic("OOM");
    }

    fn step(walk: *Walk, reached: *Step) void {
        if (walk.steps.contains(reached)) return;
        walk.steps.put(walk.b.allocator, reached, {}) catch @panic("OOM");
        walk.owner(reached.owner);
        if (reached.cast(Step.Compile)) |compile| walk.module(compile.root_module);
        if (reached.cast(Step.Run)) |run| for (run.argv.items) |arg| switch (arg) {
            .artifact => |decorated| walk.step(&decorated.artifact.step),
            .lazy_path, .decorated_directory => |decorated| walk.lazy(decorated.lazy_path),
            .file_content => |decorated| walk.lazy(decorated.lazy_path),
            else => {},
        };
        for (reached.dependencies.items) |dependency| walk.step(dependency);
    }

    fn module(walk: *Walk, reached: *Module) void {
        if (walk.modules.contains(reached)) return;
        walk.modules.put(walk.b.allocator, reached, {}) catch @panic("OOM");
        if (reached.root_source_file) |path| walk.lazy(path);
        for (reached.link_objects.items) |object| switch (object) {
            .static_path, .assembly_file => |path| walk.lazy(path),
            .other_step => |compile| walk.step(&compile.step),
            .c_source_file => |source| walk.lazy(source.file),
            .c_source_files => |sources| walk.lazy(sources.root),
            .system_lib, .win32_resource_file => {},
        };
        for (reached.include_dirs.items) |directory| switch (directory) {
            .path, .path_system, .path_after, .framework_path, .framework_path_system, .embed_path => |path| walk.lazy(path),
            .other_step => |compile| walk.step(&compile.step),
            .config_header_step => |header| walk.step(&header.step),
        };
        for (reached.import_table.values()) |imported| walk.module(imported);
    }
};

fn packagesOf(b: *std.Build, reached: *Step) []const []const u8 {
    var walk: Walk = .{ .b = b };
    walk.step(reached);
    const names = walk.packages.keys();
    const sorted = b.allocator.dupe([]const u8, names) catch @panic("OOM");
    std.mem.sort([]const u8, sorted, {}, lessThan);
    return sorted;
}

/// The table's JSON text: the input digest and, for each top-level step that links a package, its
/// packages. Names are build target names and build.zig.zon keys, so they need no escaping.
fn render(b: *std.Build) []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (b.top_level_steps.keys()) |name| names.append(b.allocator, name) catch @panic("OOM");
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var entries: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        const packages = packagesOf(b, &b.top_level_steps.get(name).?.step);
        if (packages.len == 0) continue;
        for (packages) |package| {
            for (package) |char| if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '_')
                std.debug.panic("dependency name {s} is not a plain identifier", .{package});
        }
        const quoted = std.mem.join(b.allocator, ", ", quotedAll(b, packages)) catch @panic("OOM");
        entries.append(b.allocator, b.fmt("    \"{s}\": [{s}]", .{ name, quoted })) catch @panic("OOM");
    }
    const body = std.mem.join(b.allocator, ",\n", entries.items) catch @panic("OOM");
    return b.fmt("{{\n  \"inputs\": \"{s}\",\n  \"targets\": {{\n{s}\n  }}\n}}\n", .{ inputsDigest(b), body });
}

fn quotedAll(b: *std.Build, names: []const []const u8) [][]const u8 {
    const quoted = b.allocator.alloc([]const u8, names.len) catch @panic("OOM");
    for (names, quoted) |name, *out| out.* = b.fmt("\"{s}\"", .{name});
    return quoted;
}

/// Adds `zig build link-table`, which rewrites build/link_table.json, and (on Linux, outside PR CI) the
/// check that fails while the checked-in table differs from a fresh walk. Call after every step is defined.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, check_step: *Step, pr_ci: bool) void {
    const generated = b.addWriteFiles().add("link_table.json", render(b));
    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(generated, table_path);
    b.step("link-table", "Write build/link_table.json: the dependency packages each build target links").dependOn(&update.step);

    if (target.result.os.tag != .linux or pr_ci) return;
    const check = b.addSystemCommand(&.{ "python3", "-B" });
    check.addFileArg(b.path("tests/ci/link_table.py"));
    check.addArg("check");
    check.addFileArg(generated);
    check.has_side_effects = true;
    check_step.dependOn(&check.step);
}
