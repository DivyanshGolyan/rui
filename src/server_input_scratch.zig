const std = @import("std");
const Host = @import("server_host.zig").Host;

/// Numeric names belong to startup scratch recovery until unlink succeeds.
/// No payload or charge is acquired while a name remains visible.
fn scratchFile(host: *Host, action: u64, ordinal: u64) !std.Io.File {
    var name_buffer: [96]u8 = undefined;
    const name = try @import("named_scratch.zig").NumericName.@"image-input".format(&name_buffer, action, ordinal);
    var directory = try std.Io.Dir.openDirAbsolute(host.io, host.retention.scratch_path, .{});
    defer directory.close(host.io);
    const file = try directory.createFile(host.io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    errdefer file.close(host.io);
    try directory.deleteFile(host.io, name);
    return file;
}

/// Open both anonymous scratch files and transfer their ownership to capture.
pub fn init(host: *Host, action: u64, capture: *@import("InputCapture.zig")) !void {
    const spool = try scratchFile(host, action, 1);
    errdefer spool.close(host.io);
    const index = try scratchFile(host, action, 2);
    capture.init(host.io, spool, index, host.retention.sharedBudget());
}
