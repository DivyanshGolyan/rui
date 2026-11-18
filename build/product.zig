const std = @import("std");
const Translator = @import("translate_c").Translator;
const darwin = @import("darwin.zig");

pub fn configurePauses(b: *std.Build, compile: *std.Build.Step.Compile, enabled: bool) void {
    const options = b.addOptions();
    options.addOption(bool, "test_pauses", enabled);
    const statements = rsqlTable(b);
    options.addOption([]const u8, "rsql_inputs", statements.inputs);
    options.addOption(bool, "rsql_collect", statements.collect);
    compile.root_module.addOptions("build_options", options);
}

/// The files src/store/rsql.zig's comptime check and render read. Their contents fingerprint the
/// generated statement table (src/store/rsql_table.zig): an edit to any of them makes every entry
/// miss until tests/ci/rsql_table.py regenerates it.
pub const rsql_table_inputs = [_][]const u8{ "src/store/rsql.zig", "src/store/schema.zig", "src/provider_name.zig", "src/change_ring.zig" };

const RsqlTable = struct { inputs: []const u8, collect: bool };
var rsql_table: ?RsqlTable = null;

fn rsqlTable(b: *std.Build) RsqlTable {
    if (rsql_table) |known| return known;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (rsql_table_inputs) |path| {
        const contents = b.root.root_dir.handle.readFileAlloc(b.graph.io, b.pathJoin(&.{ b.root.sub_path, path }), b.allocator, .limited(64 * 1024 * 1024)) catch
            std.debug.panic("cannot read statement table input {s}", .{path});
        hash.update(path);
        hash.update(&.{0});
        hash.update(contents);
        hash.update(&.{0});
    }
    const digest = hash.finalResult();
    rsql_table = .{
        .inputs = b.fmt("{x}", .{digest[0..16]}),
        .collect = b.option(bool, "rsql-collect", "Build Store statements on the comptime path and export them for tests/ci/rsql_table.py") orelse false,
    };
    return rsql_table.?;
}

pub fn configureUnitRoot(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, pinned: ?PinnedTransport) void {
    configurePauses(b, compile, true);
    configureSqlite(b, compile);
    configureYaml(b, compile);
    configureBashPlatform(b, compile);
    configureHostLaunch(b, compile);
    configureTerminalEditor(b, compile);
    configureTransport(b, compile, target, pinned);
    configureOpenApi(b, compile);
}

pub fn sameTransportTarget(a: std.Build.ResolvedTarget, b: std.Build.ResolvedTarget) bool {
    return a.result.cpu.arch == b.result.cpu.arch and
        a.result.os.tag == b.result.os.tag and
        a.result.abi == b.result.abi;
}

pub fn addRui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    pinned_transport: ?PinnedTransport,
) *std.Build.Step.Compile {
    return addRuiWithIdentity(b, target, optimize, name, pinned_transport, buildIdentity(b), false);
}

pub fn addPauseRui(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, pinned_transport: ?PinnedTransport) *std.Build.Step.Compile {
    return addRuiWithIdentity(b, target, optimize, name, pinned_transport, buildIdentity(b), true);
}

/// Integration products share the qualified PR backend; production builds keep Zig's default.
pub fn addIntegrationRui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    pinned_transport: ?PinnedTransport,
    pr_ci: bool,
    identity: BuildIdentity,
) *std.Build.Step.Compile {
    return withPrBackend(addRuiWithIdentity(b, target, .ReleaseSafe, name, pinned_transport, identity, false), pr_ci);
}

/// The pause-enabled integration product, on the same PR backend as the other integration products.
pub fn addPauseIntegrationRui(b: *std.Build, target: std.Build.ResolvedTarget, name: []const u8, pinned_transport: ?PinnedTransport, pr_ci: bool) *std.Build.Step.Compile {
    return withPrBackend(addPauseRui(b, target, .ReleaseSafe, name, pinned_transport), pr_ci);
}

fn withPrBackend(executable: *std.Build.Step.Compile, pr_ci: bool) *std.Build.Step.Compile {
    if (pr_ci) executable.use_llvm = false;
    return executable;
}

const BuildIdentity = struct { version: []const u8, revision: []const u8 };

var identity_memo: ?struct { owner: *std.Build, identity: BuildIdentity } = null;

pub fn buildIdentity(b: *std.Build) BuildIdentity {
    if (identity_memo) |memo| if (memo.owner == b) return memo.identity;
    const identity: BuildIdentity = .{ .version = buildVersion(b), .revision = buildRevision(b) };
    identity_memo = .{ .owner = b, .identity = identity };
    return identity;
}

fn addRuiWithIdentity(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    pinned_transport: ?PinnedTransport,
    identity: BuildIdentity,
    test_pauses: bool,
) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configurePauses(b, executable, test_pauses);
    executable.root_module.link_libc = true;
    configureSqlite(b, executable);
    configureYaml(b, executable);
    configureBashPlatform(b, executable);
    configureHostLaunch(b, executable);
    configureTerminalEditor(b, executable);
    configureTransportWithIdentity(b, executable, target, pinned_transport, identity);
    return executable;
}

pub const PinnedTransport = struct {
    output: std.Build.LazyPath,
};

pub fn addPinnedTransport(b: *std.Build, target: std.Build.ResolvedTarget) PinnedTransport {
    const openssl = b.dependency("openssl", .{});
    const nghttp2 = b.dependency("nghttp2", .{});
    const build_transport = b.addSystemCommand(&.{"sh"});
    build_transport.addFileArg(b.path("src/build_transport.sh"));
    build_transport.addDirectoryArg2(openssl.path("."), .{ .make_absolute = true });
    build_transport.addDirectoryArg2(nghttp2.path("."), .{ .make_absolute = true });
    const target_name = b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    });
    const output = build_transport.addOutputDirectoryArg2(b.fmt("pinned-transport-{s}", .{target_name}), .{ .make_absolute = true });
    build_transport.addArg(target_name);
    build_transport.addArg(b.graph.zig_exe);
    return .{ .output = output };
}

fn buildRevision(b: *std.Build) []const u8 {
    return gitHead(b, &.{ "rev-parse", "HEAD" }) orelse "unknown";
}

fn buildVersion(b: *std.Build) []const u8 {
    const tag = gitHead(b, &.{ "describe", "--tags", "--exact-match", "--match", "v[0-9]*.[0-9]*.[0-9]*", "HEAD" }) orelse
        return "unreleased";
    return tag[1..];
}

fn gitHead(b: *std.Build, query: []const []const u8) ?[]const u8 {
    b.graph.poisonCache();
    _ = b.root.statFile(b.graph.io, ".git") catch return null;
    const root = b.root.toString(b.allocator) catch @panic("OOM");
    const argv = std.mem.concat(b.allocator, []const u8, &.{ &.{ "git", "-C", root }, query }) catch @panic("OOM");
    return switch (b.runFallible(argv, .{ .stderr_behavior = .ignore })) {
        .success => |stdout| std.mem.trim(u8, stdout, "\r\n"),
        else => null,
    };
}

fn configureTransport(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    maybe_pinned: ?PinnedTransport,
) void {
    configureTransportWithIdentity(b, compile, target, maybe_pinned, buildIdentity(b));
}

fn configureTransportWithIdentity(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    maybe_pinned: ?PinnedTransport,
    identity: BuildIdentity,
) void {
    const options = b.addOptions();
    options.addOption(bool, "enabled", transportEnabled(target));
    options.addOption([]const u8, "revision", identity.revision);
    options.addOption([]const u8, "version", identity.version);
    compile.root_module.addOptions("transport_options", options);
    const test_poll = addTestPoll(b);
    compile.root_module.addImport("test_poll", test_poll);
    const optimize = compile.root_module.optimize.?;
    const url = addUrl(b);
    compile.root_module.addImport("url", url);
    const os = useOs(b, compile.root_module);
    const tls_client = addTlsClient(b, target, optimize, maybe_pinned, url, os) orelse return;
    compile.root_module.addImport("tls_client", tls_client);
    compile.root_module.addImport("h2", addH2(b, target, optimize, maybe_pinned, test_poll, tls_client));
}

pub fn addTestPoll(b: *std.Build) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/testing/poll.zig") });
}

pub fn addUrl(b: *std.Build) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/url.zig") });
}

/// The platform owner (`src/os/os.zig`). A file belongs to a single module,
/// so every module of one compile shares one instance.
pub fn addOs(b: *std.Build) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/os/os.zig") });
}

/// `module`'s "os" import, added on first use.
pub fn useOs(b: *std.Build, module: *std.Build.Module) *std.Build.Module {
    if (module.import_table.get("os")) |os| return os;
    const os = addOs(b);
    module.addImport("os", os);
    return os;
}

/// The platform owner as the root of its own test binary.
pub fn addOsRoot(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const module = addOs(b);
    module.resolved_target = target;
    module.optimize = .ReleaseSafe;
    module.link_libc = true;
    return module;
}

pub fn addTlsClient(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    maybe_pinned: ?PinnedTransport,
    url: *std.Build.Module,
    os: *std.Build.Module,
) ?*std.Build.Module {
    if (!transportEnabled(target)) return null;
    const module = b.createModule(.{
        .root_source_file = b.path("src/tls_client/tls_client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("url", url);
    module.addImport("os", os);
    const bindings = addBindings(b, module, "openssl_c",
        \\#include <openssl/ssl.h>
        \\#include <openssl/err.h>
        \\#include <openssl/x509v3.h>
        \\
    );
    const pinned = maybe_pinned orelse {
        bindings.addIncludePath(addTransportHeaders(b, target));
        return module;
    };
    addPinnedPaths(b, target, pinned, module, bindings);
    module.addObjectFile(pinned.output.path(b, "lib/libssl.a"));
    module.addObjectFile(pinned.output.path(b, "lib/libcrypto.a"));
    return module;
}

pub fn addH2(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    maybe_pinned: ?PinnedTransport,
    test_poll: *std.Build.Module,
    tls_client: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/h2/h2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("url", tls_client.import_table.get("url").?);
    module.addImport("os", tls_client.import_table.get("os").?);
    module.addImport("test_poll", test_poll);
    module.addImport("tls_client", tls_client);
    const bindings = addBindings(b, module, "h2_c",
        \\#include <nghttp2/nghttp2.h>
        \\
    );
    const pinned = maybe_pinned orelse {
        bindings.addIncludePath(addTransportHeaders(b, target));
        return module;
    };
    addPinnedPaths(b, target, pinned, module, bindings);
    module.addObjectFile(pinned.output.path(b, "lib/libnghttp2.a"));
    if (target.result.os.tag == .macos) {
        darwin.linkTrust(module);
    }
    return module;
}

fn addPinnedPaths(b: *std.Build, target: std.Build.ResolvedTarget, pinned: PinnedTransport, module: *std.Build.Module, bindings: Translator) void {
    bindings.addIncludePath(pinned.output.path(b, "include"));
    if (target.result.os.tag == .macos) {
        darwin.addSdkPaths(b, module, bindings, pinned.output);
    } else {
        module.linkSystemLibrary("pthread", .{});
        module.linkSystemLibrary("dl", .{});
    }
}

pub fn addPg(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, tls_client: *std.Build.Module) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/store/wire/pg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("tls_client", tls_client);
    return module;
}

fn addTransportHeaders(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const generate = b.addSystemCommand(&.{"sh"});
    generate.addFileArg(b.path("src/build_transport_headers.sh"));
    generate.addDirectoryArg2(b.dependency("openssl", .{}).path("."), .{ .make_absolute = true });
    generate.addDirectoryArg2(b.dependency("nghttp2", .{}).path("."), .{ .make_absolute = true });
    const target_name = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });
    const output = generate.addOutputDirectoryArg2(b.fmt("transport-headers-{s}", .{target_name}), .{ .make_absolute = true });
    generate.addArg(target_name);
    return output.path(b, "include");
}

fn transportEnabled(target: std.Build.ResolvedTarget) bool {
    return (target.result.os.tag == .macos or target.result.os.tag == .linux) and
        (target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .x86_64);
}

pub fn configureYaml(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const module = compile.root_module;
    const yaml = b.dependency("yaml", .{});
    if (module.root_source_file != null) {
        const yaml_bindings = addBindings(b, module, "yaml", "#include <yaml.h>\n");
        yaml_bindings.addIncludePath(yaml.path("include"));
    }
    module.addIncludePath(yaml.path("include"));
    module.addIncludePath(yaml.path("src"));
    module.addCMacro("YAML_VERSION_STRING", "\"0.2.5\"");
    module.addCMacro("YAML_VERSION_MAJOR", "0");
    module.addCMacro("YAML_VERSION_MINOR", "2");
    module.addCMacro("YAML_VERSION_PATCH", "5");
    for ([_][]const u8{ "api.c", "reader.c", "scanner.c", "parser.c", "loader.c", "writer.c", "emitter.c", "dumper.c" }) |source| {
        // api.c uses POSIX strdup; expose its declaration in strict C99 only
        // for these dependency sources, never the consumer's other C files.
        module.addCSourceFile(.{
            .file = yaml.path(b.fmt("src/{s}", .{source})),
            .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L" },
        });
    }
}

fn configureSqlite(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const sqlite = b.dependency("sqlite", .{});
    const module = compile.root_module;
    if (module.root_source_file != null) {
        const bindings = addBindings(b, module, "sqlite", "#include <sqlite3.h>\n");
        bindings.addIncludePath(sqlite.path("."));
    }
    module.link_libc = true;
    module.addIncludePath(sqlite.path("."));
    module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-std=c99", "-fno-strict-aliasing" },
    });
    module.addCMacro("SQLITE_THREADSAFE", "1");
    module.addCMacro("SQLITE_DEFAULT_PAGE_SIZE", "4096");
    module.addCMacro("SQLITE_MAX_DEFAULT_PAGE_SIZE", "4096");
    module.addCMacro("SQLITE_DEFAULT_FOREIGN_KEYS", "1");
    module.addCMacro("SQLITE_DEFAULT_MMAP_SIZE", "0");
    module.addCMacro("SQLITE_MAX_MMAP_SIZE", "0");
    module.addCMacro("SQLITE_DEFAULT_SYNCHRONOUS", "3");
    module.addCMacro("SQLITE_DQS", "0");
    module.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    module.addCMacro("SQLITE_OMIT_SHARED_CACHE", "1");
    module.addCMacro("SQLITE_MAX_ATTACHED", "0");
    module.addCMacro("SQLITE_MAX_LENGTH", "1073741824");
    module.addCMacro("SQLITE_DEFAULT_WORKER_THREADS", "0");
    module.addCMacro("SQLITE_MAX_WORKER_THREADS", "0");
    module.addCMacro("SQLITE_TEMP_STORE", "1");
    module.addCMacro("SQLITE_DEFAULT_PCACHE_INITSZ", "0");
    module.addCMacro("SQLITE_USE_URI", "0");
    module.addCMacro("SQLITE_ENABLE_API_ARMOR", "1");
}

fn configureBashPlatform(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/bash_platform.c"),
        .flags = &.{"-std=c11"},
    });
}

fn configureHostLaunch(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/host_launch.c"),
        .flags = &.{"-std=c11"},
    });
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/host_identity.c"),
        .flags = &.{"-std=c11"},
    });
}

pub fn configureTerminalEditor(b: *std.Build, compile: *std.Build.Step.Compile) void {
    configurePosix(b, compile.root_module);
    configureVaxis(b, compile.root_module);
    compile.root_module.link_libc = true;
}

fn configureVaxis(b: *std.Build, module: *std.Build.Module) void {
    const dependency = b.dependency("vaxis", .{
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
    });
    module.addImport("terminal_unicode", dependency.module("unicode"));
    module.addImport("terminal_width", dependency.module("gwidth"));
    module.addImport("vaxis", dependency.module("vaxis"));
}

fn addBindings(b: *std.Build, module: *std.Build.Module, name: []const u8, header: []const u8) Translator {
    const bindings: Translator = .init(b.dependency("translate_c", .{ .optimize = std.builtin.OptimizeMode.ReleaseFast }), .{
        .name = name,
        .c_source_file = b.addWriteFiles().add(b.fmt("{s}.h", .{name}), header),
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
    });
    module.addImport(name, bindings.mod);
    return bindings;
}

pub fn configurePosix(b: *std.Build, module: *std.Build.Module) void {
    _ = useOs(b, module);
    _ = addBindings(b, module, "posix",
        \\#undef _FORTIFY_SOURCE
        \\#include <unistd.h>
        \\#include <sys/stat.h>
        \\#include <sys/resource.h>
        \\#include <termios.h>
        \\#include <fcntl.h>
        \\#include <sys/mman.h>
        \\#include <sys/wait.h>
        \\#include <signal.h>
        \\#include <stdio.h>
        \\#include <poll.h>
        \\
    );
}

pub fn addSqliteShell(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const sqlite = b.dependency("sqlite", .{});
    const executable = b.addExecutable(.{
        .name = "rui-qualification-sqlite3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    configureSqlite(b, executable);
    executable.root_module.addCSourceFile(.{
        .file = sqlite.path("shell.c"),
        .flags = &.{"-std=gnu99"},
    });
    return executable;
}

fn configureOpenApi(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addAnonymousImport("openapi.json", .{ .root_source_file = b.path("openapi.json") });
}
