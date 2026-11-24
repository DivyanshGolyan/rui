//! The production file set and the module tree (deep-modules U3). `load` reads
//! the files that a root reaches through Imports.targets and builds one node per
//! file and per directory; a directory's own file (`D.zig` beside `D/`, or
//! `D/D.zig` inside it) is that directory's node.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Imports = @import("Imports.zig");

const Sources = @This();

root: []const u8,
files: []const File,
nodes: []const Node,

pub const FileId = enum(u32) { _ };
pub const NodeId = enum(u32) { _ };

pub const NamedModule = Imports.NamedModule;

pub const Reader = Imports.Reader;

pub const Failure = Imports.Failure;

pub const LoadError = Imports.Error || error{ Unreadable, ParseError, AmbiguousOwnFile };

pub const stem = Imports.stem;

/// A literal `@import` outside test declarations, and the file it names.
pub const Import = struct { literal: []const u8, target: FileId };

pub const File = struct {
    path: []const u8,
    ast: Ast,
    node: NodeId,
    imports: []const Import,
    /// The byte offset at which each line starts, the first at 0.
    line_starts: []const u32,
};

/// `path` is the display path: relative to the root's directory, without `.zig`.
/// The root node (index 0) has the empty display path.
pub const Node = struct { name: []const u8, path: []const u8, parent: ?NodeId, own_file: ?FileId };

const Parsed = struct { ast: Ast, imports: []const Imports.Import };

pub const Common = struct { parent: NodeId, a: NodeId, b: NodeId };

pub const top: NodeId = @fromBackingInt(@intCast(0));

pub fn display(self: *const Sources, node: NodeId) []const u8 {
    return self.nodes[@backingInt(node)].path;
}

/// The file that `@import(literal)` names in `file`, or null when that import is
/// external, sits in a test declaration, or was never read.
pub fn importTarget(self: *const Sources, file: FileId, literal: []const u8) ?FileId {
    for (self.files[@backingInt(file)].imports) |import| {
        if (std.mem.eql(u8, import.literal, literal)) return import.target;
    }
    return null;
}

pub fn parent(self: *const Sources, node: NodeId) ?NodeId {
    return self.nodes[@backingInt(node)].parent;
}

/// True when `ancestor` is `node` or one of its ancestors.
pub fn isWithin(self: *const Sources, node: NodeId, ancestor: NodeId) bool {
    var current: ?NodeId = node;
    while (current) |id| : (current = self.parent(id)) {
        if (id == ancestor) return true;
    }
    return false;
}

/// The lowest common ancestor, with the child of it on the way to `a` and the
/// child on the way to `b`. Null when one node contains the other.
pub fn commonParent(self: *const Sources, a: NodeId, b: NodeId) ?Common {
    if (self.isWithin(a, b) or self.isWithin(b, a)) return null;
    var b_child = b;
    var current: ?NodeId = b;
    while (current) |id| : (current = self.parent(id)) {
        if (self.isWithin(a, id)) {
            var a_child = a;
            while (self.parent(a_child).? != id) a_child = self.parent(a_child).?;
            return .{ .parent = id, .a = a_child, .b = b_child };
        }
        b_child = id;
    }
    return null;
}

/// The 1-based line and column of `token` in `file`; the column counts bytes.
pub fn locate(self: *const Sources, file: FileId, token: Ast.TokenIndex) Location {
    const found = &self.files[@backingInt(file)];
    const offset = found.ast.tokenStart(token);
    var low: usize = 0;
    var high: usize = found.line_starts.len;
    while (low + 1 < high) {
        const middle = (low + high) / 2;
        if (found.line_starts[middle] <= offset) low = middle else high = middle;
    }
    return .{ .line = @intCast(low + 1), .column = @intCast(offset - found.line_starts[low] + 1) };
}

pub const Location = struct { line: u32, column: u32 };

pub fn findFile(self: *const Sources, path: []const u8) ?FileId {
    for (self.files, 0..) |file, i| {
        if (std.mem.eql(u8, file.path, path)) return @fromBackingInt(@intCast(i));
    }
    return null;
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Builds the tree nodes, creating directory nodes on demand.
const Builder = struct {
    arena: Allocator,
    root_dir: []const u8,
    owners: std.StringHashMapUnmanaged(FileId),
    nodes: std.ArrayList(Node) = .empty,
    dir_nodes: std.StringHashMapUnmanaged(NodeId) = .empty,

    fn dir(self: *Builder, path: []const u8) Allocator.Error!NodeId {
        if (path.len == 0 or std.mem.eql(u8, path, self.root_dir)) return Sources.top;
        if (self.dir_nodes.get(path)) |id| return id;
        const up = try self.dir(Imports.dirName(path));
        const id: NodeId = @fromBackingInt(@intCast(self.nodes.items.len));
        try self.nodes.append(self.arena, .{
            .name = Imports.baseName(path),
            .path = Imports.relative(self.root_dir, path),
            .parent = up,
            .own_file = self.owners.get(path),
        });
        try self.dir_nodes.put(self.arena, path, id);
        return id;
    }

    fn file(self: *Builder, path: []const u8, id: FileId) Allocator.Error!NodeId {
        const up = try self.dir(Imports.dirName(path));
        const node: NodeId = @fromBackingInt(@intCast(self.nodes.items.len));
        try self.nodes.append(self.arena, .{
            .name = stem(path),
            .path = Imports.relative(self.root_dir, Imports.withoutZig(path)),
            .parent = up,
            .own_file = id,
        });
        return node;
    }
};

/// Reads `root` and every file it reaches, and builds the module tree.
/// `failure` says which file failed when the error is not `OutOfMemory`.
pub fn load(arena: Allocator, reader: Reader, root: []const u8, modules: []const NamedModule, failure: *Failure) LoadError!Sources {
    var parsed: std.StringHashMapUnmanaged(Parsed) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(arena, root);
    while (pending.pop()) |path| {
        if (parsed.contains(path)) continue;
        const text = reader.read(reader.context, arena, path) catch {
            failure.* = .{ .path = path, .reason = "cannot read file" };
            return error.Unreadable;
        };
        const source = try arena.dupeSentinel(u8, text, 0);
        const ast = try Ast.parse(arena, source, .{});
        if (ast.errors.len != 0) {
            failure.* = .{ .path = path, .reason = "syntax error" };
            return error.ParseError;
        }
        const imports = try Imports.targets(arena, &ast, path, root, modules, failure);
        try parsed.put(arena, path, .{ .ast = ast, .imports = imports });
        for (imports) |import| try pending.append(arena, import.path);
    }

    const paths = try arena.alloc([]const u8, parsed.count());
    var keys = parsed.keyIterator();
    for (paths) |*slot| slot.* = keys.next().?.*;
    std.mem.sort([]const u8, paths, {}, lessPath);

    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    for (paths) |path| {
        var dir_path = Imports.dirName(path);
        while (dir_path.len > 0) : (dir_path = Imports.dirName(dir_path)) try dirs.put(arena, dir_path, {});
    }

    // A file owns a directory when it is `D.zig` beside `D` or `D/D.zig` inside it.
    var owners: std.StringHashMapUnmanaged(FileId) = .empty;
    const owned_dirs = try arena.alloc(?[]const u8, paths.len);
    for (paths, owned_dirs, 0..) |path, *owned_dir, i| {
        owned_dir.* = null;
        if (std.mem.endsWith(u8, path, ".zig") and dirs.contains(Imports.withoutZig(path))) owned_dir.* = Imports.withoutZig(path);
        const inner = Imports.dirName(path);
        if (inner.len > 0 and std.mem.eql(u8, stem(path), Imports.baseName(inner)) and dirs.contains(inner)) {
            if (owned_dir.* != null) {
                failure.* = .{ .path = path, .reason = "both D.zig beside D and D/D.zig inside it" };
                return error.AmbiguousOwnFile;
            }
            owned_dir.* = inner;
        }
        if (owned_dir.*) |dir_path| {
            if (owners.contains(dir_path)) {
                failure.* = .{ .path = path, .reason = "two files claim one directory" };
                return error.AmbiguousOwnFile;
            }
            try owners.put(arena, dir_path, @fromBackingInt(@intCast(i)));
        }
    }

    var ids: std.StringHashMapUnmanaged(FileId) = .empty;
    for (paths, 0..) |path, i| try ids.put(arena, path, @fromBackingInt(@intCast(i)));

    const root_dir = Imports.dirName(root);
    var builder: Builder = .{ .arena = arena, .root_dir = root_dir, .owners = owners };
    try builder.nodes.append(arena, .{ .name = Imports.baseName(root_dir), .path = "", .parent = null, .own_file = owners.get(root_dir) });
    const files = try arena.alloc(File, paths.len);
    for (paths, owned_dirs, 0..) |path, owned_dir, i| {
        const id: FileId = @fromBackingInt(@intCast(i));
        const node = if (owned_dir) |dir_path| try builder.dir(dir_path) else try builder.file(path, id);
        const file = parsed.get(path).?;
        const imports = try arena.alloc(Import, file.imports.len);
        for (file.imports, imports) |import, *slot| slot.* = .{ .literal = import.literal, .target = ids.get(import.path).? };
        files[i] = .{ .path = path, .ast = file.ast, .node = node, .imports = imports, .line_starts = try lineStarts(arena, file.ast.source) };
    }
    return .{ .root = root, .files = files, .nodes = try builder.nodes.toOwnedSlice(arena) };
}

/// The byte offset at which each line of `source` starts.
fn lineStarts(arena: Allocator, source: []const u8) Allocator.Error![]const u32 {
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    for (source, 0..) |byte, offset| {
        if (byte == '\n') try starts.append(arena, @intCast(offset + 1));
    }
    return starts.items;
}

pub const Memory = Imports.Memory;

fn nodeOf(s: *const Sources, path: []const u8) NodeId {
    return s.files[@backingInt(s.findFile(path).?)].node;
}

const testing = std.testing;

fn loadWith(arena: Allocator, entries: []const Memory.Entry, root: []const u8, modules: []const NamedModule, failure: *Failure) LoadError!Sources {
    const memory: Memory = .{ .entries = entries };
    return load(arena, memory.reader(), root, modules, failure);
}

test "walk follows literal imports and skips test-only ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    const s = try loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const a = @import(\"a.zig\");\ntest { _ = @import(\"t.zig\"); }\n" },
        .{ .path = "src/a.zig", .text = "const std = @import(\"std\");\nconst root = @import(\"root\");\n" },
        .{ .path = "src/t.zig", .text = "" },
        .{ .path = "src/unused.zig", .text = "" },
    }, "src/cli.zig", &.{}, &failure);
    try testing.expectEqual(@as(usize, 2), s.files.len);
    try testing.expectEqualStrings("src/a.zig", s.files[0].path);
    try testing.expectEqualStrings("src/cli.zig", s.files[1].path);
    try testing.expectEqualStrings("cli", s.display(nodeOf(&s, "src/cli.zig")));
}

test "named modules are followed and merged with their directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    const modules = [_]NamedModule{.{ .name = "os", .path = "src/os/os.zig" }};
    const s = try loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const os = @import(\"os\");\n" },
        .{ .path = "src/os/os.zig", .text = "const f = @import(\"file.zig\");\n" },
        .{ .path = "src/os/file.zig", .text = "" },
        .{ .path = "src/os/other.zig", .text = "" },
    }, "src/cli.zig", &modules, &failure);
    try expectPaths(&.{ "src/cli.zig", "src/os/file.zig", "src/os/os.zig" }, s);
    const os_node = nodeOf(&s, "src/os/os.zig");
    try testing.expectEqualStrings("os", s.display(os_node));
    try testing.expectEqual(@as(usize, 4), s.nodes.len);
    try testing.expectEqual(os_node, s.parent(nodeOf(&s, "src/os/file.zig")).?);
}

fn expectPaths(expected: []const []const u8, s: Sources) !void {
    try testing.expectEqual(expected.len, s.files.len);
    for (expected, s.files) |path, file| try testing.expectEqualStrings(path, file.path);
}

test "store.zig and store/ share one node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    const s = try loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const store = @import(\"store.zig\");\n" },
        .{ .path = "src/store.zig", .text = "const x = @import(\"store/x.zig\");\n" },
        .{ .path = "src/store/x.zig", .text = "" },
    }, "src/cli.zig", &.{}, &failure);
    try expectPaths(&.{ "src/cli.zig", "src/store.zig", "src/store/x.zig" }, s);
    try testing.expectEqual(@as(usize, 4), s.nodes.len);
    const store = nodeOf(&s, "src/store.zig");
    try testing.expectEqual(store, s.parent(nodeOf(&s, "src/store/x.zig")).?);
    try testing.expectEqualStrings("store", s.display(store));
    try testing.expectEqualStrings("store/x", s.display(nodeOf(&s, "src/store/x.zig")));
    try testing.expectEqual(@as(?FileId, s.findFile("src/store.zig")), s.nodes[@backingInt(store)].own_file);
}

test "importTarget maps each literal import to the file it names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    const modules = [_]NamedModule{.{ .name = "os", .path = "src/os/os.zig" }};
    const s = try loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const a = @import(\"a.zig\");\nconst os = @import(\"os\");\nconst r = @import(\"root\");\nconst std = @import(\"std\");\ntest { _ = @import(\"t.zig\"); }\n" },
        .{ .path = "src/a.zig", .text = "" },
        .{ .path = "src/os/os.zig", .text = "" },
        .{ .path = "src/t.zig", .text = "" },
    }, "src/cli.zig", &modules, &failure);
    const cli = s.findFile("src/cli.zig").?;
    try testing.expectEqual(s.findFile("src/a.zig"), s.importTarget(cli, "a.zig"));
    try testing.expectEqual(s.findFile("src/os/os.zig"), s.importTarget(cli, "os"));
    try testing.expectEqual(cli, s.importTarget(cli, "root"));
    try testing.expectEqual(@as(?FileId, null), s.importTarget(cli, "std"));
    try testing.expectEqual(@as(?FileId, null), s.importTarget(cli, "t.zig"));
}

test "h2/h2.zig is the node of directory h2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    const s = try loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const h2 = @import(\"h2/h2.zig\");\n" },
        .{ .path = "src/h2/h2.zig", .text = "const f = @import(\"frame.zig\");\n" },
        .{ .path = "src/h2/frame.zig", .text = "" },
    }, "src/cli.zig", &.{}, &failure);
    try expectPaths(&.{ "src/cli.zig", "src/h2/frame.zig", "src/h2/h2.zig" }, s);
    try testing.expectEqual(@as(usize, 4), s.nodes.len);
    const h2 = nodeOf(&s, "src/h2/h2.zig");
    try testing.expectEqualStrings("h2", s.display(h2));
    try testing.expectEqualStrings("h2/frame", s.display(nodeOf(&s, "src/h2/frame.zig")));
    try testing.expectEqual(h2, s.parent(nodeOf(&s, "src/h2/frame.zig")).?);
}

test "display and commonParent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    const s = try loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const C = @import(\"Composer.zig\");\nconst st = @import(\"store.zig\");\n" },
        .{ .path = "src/Composer.zig", .text = "" },
        .{ .path = "src/store.zig", .text = "const e = @import(\"store/engine/sqlite.zig\");\nconst w = @import(\"store/wire/pg.zig\");\n" },
        .{ .path = "src/store/engine/sqlite.zig", .text = "" },
        .{ .path = "src/store/wire/pg.zig", .text = "" },
    }, "src/cli.zig", &.{}, &failure);
    const composer = nodeOf(&s, "src/Composer.zig");
    const store = nodeOf(&s, "src/store.zig");
    const sqlite = nodeOf(&s, "src/store/engine/sqlite.zig");
    const pg = nodeOf(&s, "src/store/wire/pg.zig");
    const engine = s.parent(sqlite).?;
    const wire = s.parent(pg).?;
    try testing.expectEqualStrings("Composer", s.display(composer));
    try testing.expectEqualStrings("store", s.display(store));
    try testing.expectEqualStrings("store/engine/sqlite", s.display(sqlite));
    try testing.expectEqualStrings("store/engine", s.display(engine));
    try testing.expectEqualStrings("store/wire/pg", s.display(pg));
    try testing.expect(s.isWithin(sqlite, store));
    try testing.expect(!s.isWithin(store, sqlite));

    const siblings = s.commonParent(sqlite, pg).?;
    try testing.expectEqual(store, siblings.parent);
    try testing.expectEqual(engine, siblings.a);
    try testing.expectEqual(wire, siblings.b);

    const across = s.commonParent(sqlite, composer).?;
    try testing.expectEqual(Sources.top, across.parent);
    try testing.expectEqual(store, across.a);
    try testing.expectEqual(composer, across.b);

    try testing.expectEqual(@as(?Common, null), s.commonParent(store, sqlite));
    try testing.expectEqual(@as(?Common, null), s.commonParent(sqlite, sqlite));
}

test "parse errors, ambiguous own files and non-literal imports fail with the path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = .{};
    try testing.expectError(error.ParseError, loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const = ;" },
    }, "src/cli.zig", &.{}, &failure));
    try testing.expectEqualStrings("src/cli.zig", failure.path);

    failure = .{};
    try testing.expectError(error.AmbiguousOwnFile, loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const a = @import(\"a.zig\");\nconst b = @import(\"a/a.zig\");\n" },
        .{ .path = "src/a.zig", .text = "" },
        .{ .path = "src/a/a.zig", .text = "" },
    }, "src/cli.zig", &.{}, &failure));

    failure = .{};
    try testing.expectError(error.NonLiteralImport, loadWith(arena.allocator(), &.{
        .{ .path = "src/cli.zig", .text = "const a = @import(\"a\" ++ \".zig\");\n" },
    }, "src/cli.zig", &.{}, &failure));
    try testing.expectEqualStrings("src/cli.zig", failure.path);
}
