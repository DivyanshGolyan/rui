//! Decode the pinned compiler's diagnostic ZON, not its private binary cache format.
const std = @import("std");

const Manifest = struct {
    input_hash: []const u8,
    discovered_hash: []const u8,
    files: []const struct {
        size: u64,
        inode: u64,
        mtime: i128,
        digest: []const u8,
        directory: bool = false,
        metadata: bool = false,
        prefix: u8,
        path: []const u8,
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.ExpectedCacheCatFile;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], arena, .limited(64 * 1024 * 1024));
    var start: usize = 0;
    while (start < bytes.len) {
        const end = (std.mem.indexOfPos(u8, bytes, start, "\n}\n") orelse return error.IncompleteCacheCat) + 3;
        const source = try arena.dupeSentinel(u8, bytes[start..end], 0);
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const manifest = try std.zon.parse.fromSlice(Manifest, .{
            .gpa = arena,
            .arena = arena,
            .source = source,
            .diagnostics = &diagnostics,
        });
        const json = try std.json.Stringify.valueAlloc(arena, manifest, .{});
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        start = end;
    }
}
