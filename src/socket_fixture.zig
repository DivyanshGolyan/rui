//! Test-only ownership of a private directory for real pathname Unix sockets.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!builtin.is_test) @compileError("socket_fixture is test infrastructure only");
}

// Zig 0.16's UnixAddress limit is not the native sockaddr_un storage limit on
// Darwin. Reserve the pathname terminator as well; do not change product limits.
pub const max_path_bytes = @min(std.Io.net.UnixAddress.max_len, @sizeOf(@FieldType(std.posix.sockaddr.un, "path")) - 1);

pub const Directory = struct {
    dir: std.Io.Dir,
    parent: std.Io.Dir,
    name: [33]u8,
    root: [max_path_bytes]u8,
    root_len: usize,

    pub fn init() !Directory {
        const io = std.testing.io;
        const parent = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
        errdefer parent.close(io);
        var random: [12]u8 = undefined;
        io.random(&random);
        const name = "rui-test-".* ++ std.fmt.bytesToHex(random, .lower);
        // Exclusive creation: an existing name is never adopted or removed.
        try parent.createDir(io, &name, .fromMode(0o700));
        errdefer parent.deleteTree(io, &name) catch @panic("socket fixture setup cleanup failed");
        const dir = try parent.openDir(io, &name, .{ .iterate = true });
        errdefer dir.close(io);
        var root: [max_path_bytes]u8 = undefined;
        const root_len = dir.realPath(io, &root) catch |err| switch (err) {
            error.NameTooLong => return error.SocketFixturePathTooLong,
            else => return err,
        };
        if (root_len + 1 >= max_path_bytes) return error.SocketFixturePathTooLong;
        return .{ .dir = dir, .parent = parent, .name = name, .root = root, .root_len = root_len };
    }

    /// The returned address borrows buffer until its last use. Keep this owner
    /// alive and do not overwrite buffer while using the address.
    pub fn address(self: *const Directory, name: []const u8, buffer: []u8) !std.Io.net.UnixAddress {
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
            std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidSocketFixtureName;
        if (name.len > max_path_bytes - self.root_len - 1) return error.SocketFixturePathTooLong;
        const path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.root[0..self.root_len], name });
        return std.Io.net.UnixAddress.init(path);
    }

    /// Close sockets and borrowed directory handles before cleanup. A teardown
    /// failure is a test failure, not a silently leaked temporary directory.
    pub fn cleanup(self: *Directory) void {
        self.dir.close(std.testing.io);
        self.parent.deleteTree(std.testing.io, &self.name) catch @panic("socket fixture cleanup failed");
        self.parent.close(std.testing.io);
        self.* = undefined;
    }
};

test "socket fixture survives the historical deep checkout and owns cleanup" {
    const io = std.testing.io;
    var checkout = try Directory.init();
    defer checkout.cleanup();
    // Construct a canonical cwd of 84 bytes: tmpDir adds 32 bytes, producing
    // the recorded 133-byte response and 127-byte stale socket paths.
    var padding: [84]u8 = @splat('d');
    const nested_name = padding[0 .. 84 - checkout.root_len - 1];
    try checkout.dir.createDir(io, nested_name, .fromMode(0o700));
    const nested = try checkout.dir.openDir(io, nested_name, .{});
    defer nested.close(io);
    const previous = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer previous.close(io);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchdir(nested.handle));
    defer if (std.c.fchdir(previous.handle) != 0) @panic("unable to restore fixture cwd");

    var old = std.testing.tmpDir(.{});
    defer old.cleanup();
    var old_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const old_root = old_root_buffer[0..try old.dir.realPath(io, &old_root_buffer)];
    var old_path_buffer: [256]u8 = undefined;
    inline for (.{ "response-1-1.tmp", "stale.sock" }, .{ 133, 127 }) |name, length| {
        const path = try std.fmt.bufPrint(&old_path_buffer, "{s}/{s}", .{ old_root, name });
        try std.testing.expectEqual(@as(usize, length), path.len);
        try std.testing.expectError(error.NameTooLong, std.Io.net.UnixAddress.init(path));
    }

    var fixture = try Directory.init();
    var cleaned = false;
    defer if (!cleaned) fixture.cleanup();
    try std.testing.expectEqual(@as(u32, 0o700), (try fixture.dir.stat(io)).permissions.toMode() & 0o777);
    var root_copy: [max_path_bytes]u8 = undefined;
    @memcpy(root_copy[0..fixture.root_len], fixture.root[0..fixture.root_len]);
    const root = root_copy[0..fixture.root_len];
    var buffer: [max_path_bytes]u8 = undefined;
    const address = try fixture.address("response-1-1.tmp", &buffer);
    {
        var listener = try address.listen(io, .{});
        defer listener.deinit(io);
        const peer = try address.connect(io);
        defer peer.close(io);
        try std.testing.expectEqual(std.Io.File.Kind.unix_domain_socket, (try fixture.dir.statFile(io, "response-1-1.tmp", .{})).kind);
    }
    fixture.cleanup();
    cleaned = true;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, root, .{}));
}

test "socket fixture validates complete native byte paths without truncation" {
    var fixture = try Directory.init();
    defer fixture.cleanup();
    var buffer: [max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".", "..", "a/b", "a\x00b" }) |name| {
        try std.testing.expectError(error.InvalidSocketFixtureName, fixture.address(name, &buffer));
    }
    try std.testing.expectError(error.NoSpaceLeft, fixture.address("stale.sock", buffer[0..1]));
    var name: [max_path_bytes]u8 = @splat('a');
    const available = max_path_bytes - fixture.root_len - 1;
    // Include a multibyte scalar: the boundary counts bytes, not characters.
    @memcpy(name[0..2], "é");
    const address = try fixture.address(name[0..available], &buffer);
    try std.testing.expectEqual(max_path_bytes, address.path.len);
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    try std.testing.expectError(error.SocketFixturePathTooLong, fixture.address(name[0 .. available + 1], &buffer));
}

// Deliberately narrow: catch the demonstrated direct tmpDir -> dir.realPath ->
// UnixAddress.init pattern in the native fixture owners, not arbitrary aliases
// or delegated path computation. AST tokens exclude comments and string text.
fn unsafeSocketTest(source: [:0]const u8) !?[]const u8 {
    var tree = try std.zig.Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);
    if (tree.errors.len != 0) return error.InvalidFixtureSource;
    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) != .test_decl) continue;
        const first = tree.firstToken(decl);
        const last = tree.lastToken(decl);
        if (hasTokens(tree, first, last, &.{ "std", ".", "testing", ".", "tmpDir", "(" }) and
            hasTokens(tree, first, last, &.{ ".", "dir", ".", "realPath", "(" }) and
            hasUnmanagedAddress(tree, first, last))
        {
            return tree.tokenSlice(first + 1);
        }
    }
    return null;
}

fn hasTokens(tree: std.zig.Ast, first: u32, last: u32, pattern: []const []const u8) bool {
    var start = first;
    while (start + pattern.len <= last + 1) : (start += 1) {
        for (pattern, 0..) |token, offset| {
            if (!std.mem.eql(u8, token, tree.tokenSlice(start + @as(u32, @intCast(offset))))) break;
        } else return true;
    }
    return false;
}

fn hasUnmanagedAddress(tree: std.zig.Ast, first: u32, last: u32) bool {
    const constructor = &.{ "std", ".", "Io", ".", "net", ".", "UnixAddress", ".", "init", "(" };
    const length: u32 = @intCast(constructor.len);
    var start = first;
    while (start + length <= last + 1) : (start += 1) {
        if (!hasTokens(tree, start, start + length - 1, constructor)) continue;
        const argument = start + length;
        // StoreLease's production-derived paths.socket.slice() is already
        // checkout-independent; a Store tmpDir is not its socket directory.
        if (argument + 7 <= last and std.mem.eql(u8, tree.tokenSlice(argument), "paths") and
            hasTokens(tree, argument + 1, argument + 7, &.{ ".", "socket", ".", "slice", "(", ")", ")" })) continue;
        return true;
    }
    return false;
}

test "socket fixture lint rejects checkout-rooted Unix socket construction" {
    const historical =
        \\test "unsafe" {
        \\    var tmp = std.testing.tmpDir(.{});
        \\    const root = try tmp.dir.realPath(io, &root_buffer);
        \\    const address = try std.Io.net.UnixAddress.init(path);
        \\}
    ;
    try std.testing.expectEqualStrings("\"unsafe\"", (try unsafeSocketTest(historical)).?);
    try std.testing.expectEqualStrings("\"unsafe receiver\"", (try unsafeSocketTest(
        \\test "unsafe receiver" {
        \\    var tmp = std.testing.tmpDir(.{});
        \\    const root = try tmp.dir.realPath(io, &buffer);
        \\    const address = try std.Io.net.UnixAddress.init(local.socket.slice());
        \\}
    )).?);
    try std.testing.expectEqual(null, try unsafeSocketTest(
        \\test "Store with production endpoint" {
        \\    var tmp = std.testing.tmpDir(.{});
        \\    const root = try tmp.dir.realPath(io, &buffer);
        \\    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
        \\}
        \\test "filesystem" {
        \\    var tmp = std.testing.tmpDir(.{});
        \\    const root = try tmp.dir.realPath(io, &buffer);
        \\    // std.Io.net.UnixAddress.init(path)
        \\    const text = "std.Io.net.UnixAddress.init(path)";
        \\}
        \\test "independent production endpoint" {
        \\    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
        \\}
    ));
    inline for (.{ "platform.zig", "client.zig" }) |file| {
        if (try unsafeSocketTest(@embedFile(file))) |name| {
            std.debug.print("{s}: {s}: checkout-rooted Unix socket; use socket_fixture.Directory.address instead\n", .{ file, name });
            return error.UnsafeSocketFixture;
        }
    }
}
