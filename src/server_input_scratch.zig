const std = @import("std");
const output_retention = @import("output_retention.zig");

/// Numeric names belong to startup scratch recovery until unlink succeeds.
/// No payload or charge is acquired while a name remains visible.
fn scratchFile(io: std.Io, retention: *output_retention.Queue, action: u64, ordinal: u64) !std.Io.File {
    var name_buffer: [96]u8 = undefined;
    const name = try @import("named_scratch.zig").NumericName.@"image-input".format(&name_buffer, action, ordinal);
    var directory = try std.Io.Dir.openDirAbsolute(io, retention.scratch_path, .{});
    defer directory.close(io);
    const file = try directory.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    try directory.deleteFile(io, name);
    return file;
}

/// Open both anonymous scratch files and transfer their ownership to capture.
pub fn init(io: std.Io, retention: *output_retention.Queue, action: u64, capture: *@import("InputCapture.zig"), budget: @import("ScratchBudget.zig")) !void {
    const spool = try scratchFile(io, retention, action, 1);
    errdefer spool.close(io);
    const index = try scratchFile(io, retention, action, 2);
    capture.init(io, spool, index, budget);
}
