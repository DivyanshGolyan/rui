//! The deep-modules command. This file is the only one that does I/O: it reads the production
//! sources and the allow file from the current directory, prints the report and sets the exit
//! status. It decides no lint.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sources = @import("Sources.zig");
const Items = @import("Items.zig");
const Lints = @import("Lints.zig");
const Diagnostic = @import("Diagnostic.zig");
const Report = @import("Report.zig");
const Allow = @import("Allow.zig");

const default_root = "src/cli.zig";
const max_file_bytes = 64 * 1024 * 1024;
const usage_line = "usage: deep-modules [--root PATH] [--module NAME=PATH]... [--allow PATH | --update-allow PATH] [--all] [SCOPE]";

/// What one run was asked to do. Absent fields keep their defaults.
pub const Options = struct {
    /// The root file the production walk starts from.
    root: []const u8 = default_root,
    /// Named modules, as `--module name=path`: what `@import(name)` means in the walk.
    modules: []const Sources.NamedModule = &.{},
    /// The allow file that judges the diagnostics.
    allow: ?[]const u8 = null,
    /// Rewrites this file from the current diagnostics, and exits 0. Wins over `allow`.
    update_allow: ?[]const u8 = null,
    /// Also prints the diagnostics the allow file covers.
    all: bool = false,
    /// Reports only what concerns this module display path (and the modules below it).
    scope: ?[]const u8 = null,
};

/// The reason an argument list was refused.
pub const Usage = struct { reason: []const u8 = "" };

pub const ParseError = error{ Usage, OutOfMemory };

/// Parses the arguments after the program name. A refused list sets `usage.reason`.
/// A repeated single-valued option takes its last value, so a `--` argument can override the defaults.
pub fn parseArgs(arena: Allocator, args: []const []const u8, usage: *Usage) ParseError!Options {
    var options: Options = .{};
    var modules: std.ArrayList(Sources.NamedModule) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--all")) {
            options.all = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            options.root = try value(arena, args, &index, usage, arg);
        } else if (std.mem.eql(u8, arg, "--module")) {
            try modules.append(arena, try parseModule(arena, try value(arena, args, &index, usage, arg), usage));
        } else if (std.mem.eql(u8, arg, "--allow")) {
            options.allow = try value(arena, args, &index, usage, arg);
        } else if (std.mem.eql(u8, arg, "--update-allow")) {
            options.update_allow = try value(arena, args, &index, usage, arg);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return refuse(arena, usage, "unknown option {s}", .{arg});
        } else if (options.scope != null) {
            return refuse(arena, usage, "only one scope may be given, not {s} and {s}", .{ options.scope.?, arg });
        } else {
            options.scope = arg;
        }
    }
    options.modules = try modules.toOwnedSlice(arena);
    if (options.update_allow != null and options.scope != null)
        return refuse(arena, usage, "--update-allow rewrites the whole allow file, so it cannot take a scope", .{});
    return options;
}

fn value(arena: Allocator, args: []const []const u8, index: *usize, usage: *Usage, flag: []const u8) ParseError![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return refuse(arena, usage, "{s} needs a value", .{flag});
    return args[index.*];
}

fn parseModule(arena: Allocator, text: []const u8, usage: *Usage) ParseError!Sources.NamedModule {
    const split = std.mem.indexOfScalar(u8, text, '=') orelse
        return refuse(arena, usage, "--module expects NAME=PATH, not {s}", .{text});
    if (split == 0 or split + 1 == text.len)
        return refuse(arena, usage, "--module expects NAME=PATH, not {s}", .{text});
    return .{ .name = text[0..split], .path = text[split + 1 ..] };
}

fn refuse(arena: Allocator, usage: *Usage, comptime format: []const u8, args: anytype) ParseError {
    usage.reason = try std.fmt.allocPrint(arena, format, args);
    return error.Usage;
}

const Error = error{ Fault, OutOfMemory, WriteFailed };

/// The I/O of one run: the io handle the files and git go through, and the message of a fault.
const Run = struct {
    io: std.Io,
    arena: Allocator,
    message: []const u8 = "",

    fn fail(self: *Run, comptime format: []const u8, args: anytype) Error {
        self.message = try std.fmt.allocPrint(self.arena, format, args);
        return error.Fault;
    }

    fn reader(self: *const Run) Sources.Reader {
        return .{ .context = self, .read = readRepoFile };
    }

    fn readRepoFile(context: ?*const anyopaque, arena: Allocator, path: []const u8) anyerror![]const u8 {
        const self: *const Run = @ptrCast(@alignCast(context.?));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(max_file_bytes));
    }

    fn readText(self: *Run, path: []const u8) Error![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(max_file_bytes)) catch |err|
            return self.fail("cannot read {s}: {s}", .{ path, @errorName(err) });
    }
};

fn findNode(sources: *const Sources, display: []const u8) ?Sources.NodeId {
    for (sources.nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.path, display)) return @fromBackingInt(@intCast(index));
    }
    return null;
}

fn isListed(list: []const Diagnostic.Diagnostic, d: Diagnostic.Diagnostic) bool {
    for (list) |item| {
        if (item.lint == d.lint and std.mem.eql(u8, item.key, d.key)) return true;
    }
    return false;
}

/// Runs the lints and judges them, prints, and returns the exit status: 0 clean, 1 new findings or stale entries.
fn check(run: *Run, options: Options, out: *std.Io.Writer) Error!u8 {
    const arena = run.arena;
    var failure: Sources.Failure = .{};
    const sources = Sources.load(arena, run.reader(), options.root, options.modules, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return run.fail("cannot load {s}: {s} ({s})", .{ failure.path, failure.reason, @errorName(err) }),
    };
    const items = try Items.collect(arena, &sources);
    const scope: ?Sources.NodeId = if (options.scope) |display|
        findNode(&sources, display) orelse return run.fail("no module named {s}", .{display})
    else
        null;
    const diagnostics = try Lints.run(arena, &sources, &items, scope);

    if (options.update_allow) |path| {
        const text = try Allow.write(arena, diagnostics);
        std.Io.Dir.cwd().writeFile(run.io, .{ .sub_path = path, .data = text }) catch |err|
            return run.fail("cannot write {s}: {s}", .{ path, @errorName(err) });
        try out.print("deep-modules: wrote {s} from {d} diagnostics\n", .{ path, diagnostics.len });
        return 0;
    }

    var allowed: Allow.AllowList = .{ .entries = &.{} };
    if (options.allow) |path| {
        allowed = switch (try Allow.parse(arena, try run.readText(path))) {
            .entries => |list| list,
            .invalid => |line| return run.fail("{s}:{d}: expected `<lint> <key>`", .{ path, line }),
        };
    }
    const verdict = try Allow.judge(arena, diagnostics, allowed);
    // A scoped run sees only its own diagnostics, so entries for other modules would look stale.
    const stale: []const Allow.Entry = if (scope == null) verdict.stale else &.{};

    var printed: usize = 0;
    for (diagnostics) |d| {
        if (!options.all and !isListed(verdict.new, d)) continue;
        if (printed > 0) try out.writeAll("\n");
        try Report.render(out, d);
        printed += 1;
    }
    if (printed > 0 and stale.len > 0) try out.writeAll("\n");
    for (stale) |entry| try out.print("remove stale allowance: {s} {s}\n", .{ entry.lint.name(), entry.key });
    try Report.summary(out, verdict.new.len, diagnostics.len - verdict.new.len, stale.len);
    const clean = verdict.new.len == 0 and stale.len == 0;
    return if (clean) 0 else 1;
}

fn exitWithFault(io: std.Io, arena: Allocator, message: []const u8) u8 {
    const line = std.fmt.allocPrint(arena, "deep-modules: {s}\n", .{message}) catch "deep-modules: out of memory\n";
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const raw = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw.len - 1);
    for (args, raw[1..]) |*arg, text| arg.* = text;

    var usage: Usage = .{};
    const options = parseArgs(arena, args, &usage) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Usage => {
            const line = std.fmt.allocPrint(arena, "deep-modules: {s}\n{s}\n", .{ usage.reason, usage_line }) catch return 2;
            std.Io.File.stderr().writeStreamingAll(init.io, line) catch {};
            return 2;
        },
    };

    var run: Run = .{ .io = init.io, .arena = arena };
    var output_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    const status = check(&run, options, &stdout.interface) catch |err| switch (err) {
        error.Fault => return exitWithFault(init.io, arena, run.message),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return exitWithFault(init.io, arena, "cannot write the report"),
    };
    try stdout.interface.flush();
    return status;
}

const testing = std.testing;

fn expectOptions(want: Options, got: Options) !void {
    try testing.expectEqualStrings(want.root, got.root);
    try testing.expectEqual(want.modules.len, got.modules.len);
    for (want.modules, got.modules) |expected, actual| {
        try testing.expectEqualStrings(expected.name, actual.name);
        try testing.expectEqualStrings(expected.path, actual.path);
    }
    try expectOptional(want.allow, got.allow);
    try expectOptional(want.update_allow, got.update_allow);
    try testing.expectEqual(want.all, got.all);
    try expectOptional(want.scope, got.scope);
}

fn expectOptional(want: ?[]const u8, got: ?[]const u8) !void {
    if (want) |text| {
        try testing.expectEqualStrings(text, got orelse return error.TestUnexpectedResult);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), got);
    }
}

test "parseArgs: the defaults and each option" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { args: []const []const u8, want: Options }{
        .{ .args = &.{}, .want = .{} },
        .{ .args = &.{ "--all", "store" }, .want = .{ .all = true, .scope = "store" } },
        .{ .args = &.{ "--root", "src/openapi_main.zig" }, .want = .{ .root = "src/openapi_main.zig" } },
        .{ .args = &.{ "--allow", "tests/ci/deep_modules.allow" }, .want = .{ .allow = "tests/ci/deep_modules.allow" } },
        .{
            .args = &.{ "--module", "os=src/os/os.zig", "--module", "tls_client=src/tls_client/tls_client.zig" },
            .want = .{ .modules = &.{ .{ .name = "os", .path = "src/os/os.zig" }, .{ .name = "tls_client", .path = "src/tls_client/tls_client.zig" } } },
        },
        .{ .args = &.{ "--update-allow", "a.allow" }, .want = .{ .update_allow = "a.allow" } },
        .{
            .args = &.{ "--allow", "b.allow", "--update-allow", "a.allow" },
            .want = .{ .allow = "b.allow", .update_allow = "a.allow" },
        },
        .{ .args = &.{ "--allow", "a.allow", "--allow", "b.allow" }, .want = .{ .allow = "b.allow" } },
    };
    for (cases) |case| {
        var usage: Usage = .{};
        const got = try parseArgs(arena, case.args, &usage);
        try expectOptions(case.want, got);
    }
}

test "parseArgs: refused lists say why" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { args: []const []const u8, reason: []const u8 }{
        .{ .args = &.{"--root"}, .reason = "--root needs a value" },
        .{ .args = &.{ "--allow", "a.allow", "--module" }, .reason = "--module needs a value" },
        .{ .args = &.{ "--module", "os" }, .reason = "--module expects NAME=PATH, not os" },
        .{ .args = &.{ "--module", "=src/os/os.zig" }, .reason = "--module expects NAME=PATH, not =src/os/os.zig" },
        .{ .args = &.{ "--module", "os=" }, .reason = "--module expects NAME=PATH, not os=" },
        .{ .args = &.{"--bogus"}, .reason = "unknown option --bogus" },
        .{ .args = &.{ "store", "wire" }, .reason = "only one scope may be given, not store and wire" },
        .{ .args = &.{ "--update-allow", "a.allow", "store" }, .reason = "--update-allow rewrites the whole allow file, so it cannot take a scope" },
    };
    for (cases) |case| {
        var usage: Usage = .{};
        try testing.expectError(error.Usage, parseArgs(arena, case.args, &usage));
        try testing.expectEqualStrings(case.reason, usage.reason);
    }
}

test "parseArgs: a scope is taken once, after any option" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var usage: Usage = .{};
    const got = try parseArgs(arena_state.allocator(), &.{ "--all", "--allow", "a.allow", "store/engine" }, &usage);
    try testing.expectEqualStrings("store/engine", got.scope.?);
    try testing.expectEqualStrings("a.allow", got.allow.?);
}
