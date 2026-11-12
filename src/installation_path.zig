const std = @import("std");
const TerminalText = @import("TerminalText.zig");

pub const Observation = struct {
    state: enum { selected, shadowed, missing, unavailable },
    other: ?[]const u8 = null,

    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        if (self.other) |other| allocator.free(other);
        self.* = .{ .state = .unavailable };
    }
};

pub fn inspect(allocator: std.mem.Allocator, io: std.Io, home: []const u8, search_path: []const u8) !Observation {
    const bin = try std.fmt.allocPrint(allocator, "{s}/.local/bin", .{home});
    defer allocator.free(bin);
    const ours = std.Io.Dir.cwd().realPathFileAlloc(io, bin, allocator) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => null,
        else => return err,
    };
    defer if (ours) |physical| allocator.free(physical);
    var result: Observation = .{ .state = .missing };
    errdefer result.deinit(allocator);
    var entries = std.mem.splitScalar(u8, search_path, ':');
    while (entries.next()) |entry| {
        const directory = if (entry.len == 0) "." else entry;
        const candidate = try std.fs.path.join(allocator, &.{ directory, "rui" });
        defer allocator.free(candidate);
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind != .file) continue;
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        const physical = std.Io.Dir.cwd().realPathFileAlloc(io, directory, allocator) catch continue;
        defer allocator.free(physical);
        if (ours != null and std.mem.eql(u8, physical, ours.?)) {
            result.state = if (result.other == null) .selected else .shadowed;
            return result;
        }
        if (result.other == null) result.other = try allocator.dupe(u8, candidate);
    }
    return result;
}

fn field(writer: *std.Io.Writer, value: []const u8) !void {
    var text: TerminalText = .{ .mode = .line };
    try text.feed(writer, value);
    try text.finish(writer);
}

pub fn write(writer: *std.Io.Writer, observation: *const Observation, home: []const u8) !void {
    switch (observation.state) {
        .selected => {},
        .unavailable => try writer.writeAll("Could not establish PATH selection. Use the installation destination explicitly; bundled/custom application binaries are not changed.\n"),
        .shadowed => {
            try writer.writeAll("Your PATH finds another rui first, at ");
            try field(writer, observation.other.?);
            try writer.writeAll(". Put ");
            try field(writer, home);
            try writer.writeAll("/.local/bin before it in your PATH, then run hash -r (Bash) or rehash (Zsh).\n");
        },
        .missing => {
            try field(writer, home);
            try writer.writeAll("/.local/bin is not on your PATH");
            if (observation.other) |other| {
                try writer.writeAll(", which finds another rui at ");
                try field(writer, other);
            }
            try writer.writeAll(". Add the installation directory to your shell profile, then open a new terminal:\n  export PATH=");
            var scratch: [std.fs.max_path_bytes]u8 = undefined;
            const bin = try std.fmt.bufPrint(&scratch, "{s}/.local/bin", .{home});
            try TerminalText.writeShellWord(writer, bin);
            try writer.writeAll(":\"$PATH\"\n");
        },
    }
}

test "installation PATH observes physical directories, first executable and missing selection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(io, ".local/bin");
    try tmp.dir.createDirPath(io, "other");
    try tmp.dir.writeFile(io, .{ .sub_path = ".local/bin/rui", .data = "fixture", .flags = .{ .permissions = .fromMode(0o700) } });
    try tmp.dir.writeFile(io, .{ .sub_path = "other/rui", .data = "fixture", .flags = .{ .permissions = .fromMode(0o700) } });
    try tmp.dir.symLink(io, ".local/bin", "alias", .{ .is_directory = true });
    for ([_]struct { suffix: []const u8, expected: @FieldType(Observation, "state") }{
        .{ .suffix = "/alias", .expected = .selected },
        .{ .suffix = "/.local/bin/../bin", .expected = .selected },
        .{ .suffix = "/other", .expected = .missing },
    }) |case| {
        const search = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, case.suffix });
        defer allocator.free(search);
        var observed = try inspect(allocator, io, home, search);
        defer observed.deinit(allocator);
        try std.testing.expectEqual(case.expected, observed.state);
    }
    const shadowed = try std.fmt.allocPrint(allocator, "{s}/other:{s}/alias:{s}/.local/bin", .{ home, home, home });
    defer allocator.free(shadowed);
    var observation = try inspect(allocator, io, home, shadowed);
    defer observation.deinit(allocator);
    try std.testing.expectEqual(.shadowed, observation.state);
    var bytes: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write(&writer, &observation, home);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "hash -r") != null);
}

test "installation PATH advice sanitizes other executable and quotes destination" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    const observation: Observation = .{ .state = .missing, .other = "/other/\x1b[31mrui\nnext" };
    try write(&writer.writer, &observation, "/home/synthetic ' quoted");
    try std.testing.expect(std.mem.indexOfScalar(u8, writer.written(), 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "export PATH=$'/home/synthetic \\' quoted/.local/bin':\"$PATH\"") != null);
}
