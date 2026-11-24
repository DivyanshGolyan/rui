//! The deep-modules lint: `deep-modules` runs the tool over Rui's first-party named modules, and
//! `deep-modules-test` runs the tool's own tests.

const std = @import("std");

const NamedPath = struct { name: []const u8, path: []const u8 };

/// Returns the `deep-modules` step, which `check` runs outside the PR tier.
pub fn add(b: *std.Build, product: *std.Build.Module) *std.Build.Step {
    const modules = firstPartyModules(b, product);

    const tool = b.addExecutable(.{
        .name = "deep-modules",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ci/deep_modules/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // The tool reads the sources and git history, which no build input names.
    const run = b.addRunArtifact(tool);
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    run.addArgs(&.{ "--allow", "tests/ci/deep_modules.allow", "--trusted", "origin/main" });
    for (modules) |module| run.addArgs(&.{ "--module", b.fmt("{s}={s}", .{ module.name, module.path }) });
    run.addPassthruArgs();
    const lint = b.step("deep-modules", "Fail on a deep-modules finding that the allow file does not cover, a stale allowance, or an allowance that grew past origin/main");
    lint.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/ci/deep_modules/tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.step("deep-modules-test", "Run the deep-modules tool's own tests").dependOn(&b.addRunArtifact(tests).step);
    return lint;
}

/// The named modules `product` reaches through its imports whose root file is a source of this
/// repository under src/, sorted by name. A dependency's own src/ files have another owner and are skipped.
fn firstPartyModules(b: *std.Build, product: *std.Build.Module) []const NamedPath {
    var found: std.ArrayList(NamedPath) = .empty;
    var seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    collect(b, product, &found, &seen);
    std.mem.sort(NamedPath, found.items, {}, lessThan);
    return found.items;
}

fn collect(b: *std.Build, module: *std.Build.Module, found: *std.ArrayList(NamedPath), seen: *std.AutoHashMapUnmanaged(*std.Build.Module, void)) void {
    for (module.import_table.keys(), module.import_table.values()) |name, imported| {
        if (firstPartyPath(b, imported)) |path| {
            for (found.items) |known| {
                if (std.mem.eql(u8, known.name, name) and !std.mem.eql(u8, known.path, path))
                    std.debug.panic("module {s} is both {s} and {s}", .{ name, known.path, path });
            }
            if (!containsName(found.items, name)) found.append(b.allocator, .{ .name = name, .path = path }) catch @panic("OOM");
        }
        const entry = seen.getOrPut(b.allocator, imported) catch @panic("OOM");
        if (!entry.found_existing) collect(b, imported, found, seen);
    }
}

fn containsName(items: []const NamedPath, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}

fn firstPartyPath(b: *std.Build, module: *std.Build.Module) ?[]const u8 {
    const root = module.root_source_file orelse return null;
    return switch (root) {
        .src_path => |source| if (source.owner == b and std.mem.startsWith(u8, source.sub_path, "src/")) source.sub_path else null,
        else => null,
    };
}

fn lessThan(_: void, a: NamedPath, b: NamedPath) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
