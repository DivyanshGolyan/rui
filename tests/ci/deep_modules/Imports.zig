//! Import paths and the literal @import walk (deep-modules U3). `targets` lists
//! the files one parsed file imports outside its test declarations, as
//! tests/ci/import_architecture.py `scoped_imports` does, with named modules.
//! `Memory` is the in-memory Reader that the tests use.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// Reads one repo-relative file. Tests pass a `Memory`.
pub const Reader = struct {
    context: ?*const anyopaque,
    read: *const fn (context: ?*const anyopaque, arena: Allocator, path: []const u8) anyerror![]const u8,
};

/// Set when a load fails: the file at fault and the reason.
pub const Failure = struct { path: []const u8 = "", reason: []const u8 = "" };

/// `name` is what `@import(name)` says; `path` is the repo-relative file it names.
pub const NamedModule = struct { name: []const u8, path: []const u8 };

pub const Error = Allocator.Error || error{NonLiteralImport};

/// One literal `@import` that names a repo-relative file: `literal` is the text between the quotes.
pub const Import = struct { literal: []const u8, path: []const u8 };

/// The file name without directories or `.zig`.
pub fn stem(path: []const u8) []const u8 {
    return withoutZig(baseName(path));
}

pub fn withoutZig(path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path;
}

pub fn baseName(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

pub fn dirName(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..i] else "";
}

/// `path` without the root directory and its slash, when it is inside it.
pub fn relative(root_dir: []const u8, path: []const u8) []const u8 {
    if (root_dir.len == 0) return path;
    if (path.len > root_dir.len and std.mem.startsWith(u8, path, root_dir) and path[root_dir.len] == '/') {
        return path[root_dir.len + 1 ..];
    }
    return path;
}

/// Joins `rel` onto the directory `dir`, resolving `.` and `..`.
pub fn joinPath(arena: Allocator, dir: []const u8, rel: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ dir, rel }) |chunk| {
        var it = std.mem.splitScalar(u8, chunk, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            const last_is_up = parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..");
            if (std.mem.eql(u8, part, "..") and last_is_up) {
                _ = parts.pop();
                continue;
            }
            try parts.append(arena, part);
        }
    }
    return std.mem.join(arena, "/", parts.items);
}

/// The repo-relative file a literal import names, or null for an external one.
pub fn resolve(arena: Allocator, from: []const u8, imported: []const u8, root: []const u8, modules: []const NamedModule) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, imported, "root")) return root;
    if (std.mem.endsWith(u8, imported, ".zig")) return try joinPath(arena, dirName(from), imported);
    for (modules) |module| {
        if (std.mem.eql(u8, module.name, imported)) return module.path;
    }
    return null;
}

const TokenSpan = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

/// The literal imports of `ast` that name a file, outside its test declarations.
pub fn targets(arena: Allocator, ast: *const Ast, path: []const u8, root: []const u8, modules: []const NamedModule, failure: *Failure) Error![]const Import {
    var tests: std.ArrayList(TokenSpan) = .empty;
    for (0..ast.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (ast.nodeTag(node) == .test_decl) {
            try tests.append(arena, .{ .first = ast.firstToken(node), .last = ast.lastToken(node) });
        }
    }
    var found: std.ArrayList(Import) = .empty;
    for (0..ast.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (ast.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        const token = ast.nodeMainToken(node);
        if (!std.mem.eql(u8, ast.tokenSlice(token), "@import")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = ast.builtinCallParams(&buffer, node) orelse continue;
        if (args.len != 1 or ast.nodeTag(args[0]) != .string_literal) {
            failure.* = .{ .path = path, .reason = "@import needs one string literal" };
            return error.NonLiteralImport;
        }
        const literal = ast.tokenSlice(ast.nodeMainToken(args[0]));
        if (inTest(tests.items, token)) continue;
        const name = literal[1 .. literal.len - 1];
        if (try resolve(arena, path, name, root, modules)) |target| {
            try found.append(arena, .{ .literal = name, .path = target });
        }
    }
    return found.items;
}

fn inTest(spans: []const TokenSpan, token: Ast.TokenIndex) bool {
    for (spans) |span| {
        if (token >= span.first and token <= span.last) return true;
    }
    return false;
}

/// Fixture files for tests: paths and their text, read from memory.
pub const Memory = struct {
    entries: []const Entry,

    pub const Entry = struct { path: []const u8, text: []const u8 };

    pub fn reader(self: *const Memory) Reader {
        return .{ .context = self, .read = read };
    }

    fn read(context: ?*const anyopaque, arena: Allocator, path: []const u8) anyerror![]const u8 {
        _ = arena;
        const self: *const Memory = @ptrCast(@alignCast(context.?));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.text;
        }
        return error.FileNotFound;
    }
};

test "joinPath resolves . and .." {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("src/b.zig", try joinPath(arena.allocator(), "src", "./x/../b.zig"));
    try std.testing.expectEqualStrings("src/cli.zig", try joinPath(arena.allocator(), "src/h2", "../cli.zig"));
    try std.testing.expectEqualStrings("cli.zig", try joinPath(arena.allocator(), "", "cli.zig"));
}
