const std = @import("std");
const patch_tool = @import("patch_tool.zig");

const patch =
    "diff --git a/note.txt b/note.txt\n" ++
    "--- a/note.txt\n" ++
    "+++ b/note.txt\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;
    _ = patch_tool.prepare(init.io, args[1], patch, .{
        .operation_id = 1,
        .operation_generation = 1,
        .patch_ref = 1,
    }) catch |err| {
        if (err == error.NotTrackedRepositoryFile) return;
        return err;
    };
    return error.HostileGitEnvironmentRedirectedTrackedness;
}
