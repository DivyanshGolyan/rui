//! The per-user runtime directory's name, `/tmp/rui-<uid>`. A leaf: it imports
//! nothing but std, so `platform` (which asks `host_endpoint` about MySQL
//! occupancy) and `host_endpoint` (which censuses the directory) both reach it
//! without a cycle. Who lives inside it is `host_endpoint`'s to say.
const std = @import("std");

const runtime_prefix = "/tmp/rui-";
const max_uid_bytes = "4294967295".len;
pub const max_runtime_directory_bytes = runtime_prefix.len + max_uid_bytes;

pub fn runtimeDirectory(buffer: []u8) ![]const u8 {
    return runtimeDirectoryForUid(buffer, @intCast(std.c.geteuid()));
}

fn runtimeDirectoryForUid(buffer: []u8, uid: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}{d}", .{ runtime_prefix, uid });
}

test "the runtime directory holds the largest uid within its bound" {
    var runtime_buffer: [max_runtime_directory_bytes]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, max_runtime_directory_bytes),
        (try runtimeDirectoryForUid(&runtime_buffer, std.math.maxInt(u32))).len,
    );
}
