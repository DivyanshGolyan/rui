//! Audit evidence only: use the pinned compiler's tokenizer, not a regex over source.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.ExpectedSourcePath;
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .unlimited);
    const terminated = try allocator.allocSentinel(u8, source.len, 0);
    @memcpy(terminated, source);
    var ast = try std.zig.Ast.parse(allocator, terminated, .{});
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) return error.InvalidZigSource;
    var buffer: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    var tokenizer = std.zig.Tokenizer.init(terminated);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try out.interface.print("{s}\t{d}\t{d}\n", .{ @tagName(token.tag), token.loc.start, token.loc.end });
    }
    try out.flush();
}
