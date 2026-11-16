const std = @import("std");

pub const Bytes = [96]u8;

pub fn format(action_id: u64, bytes: *Bytes) []const u8 {
    std.debug.assert(action_id > 0);
    return std.fmt.bufPrint(bytes, "{{\"action\":\"{d}\",\"execution\":\"background\",\"accepted\":true}}", .{action_id}) catch unreachable;
}

test "background receipt identifies acceptance without claiming a running or final Action" {
    var bytes: Bytes = undefined;
    try std.testing.expectEqualStrings("{\"action\":\"18446744073709551615\",\"execution\":\"background\",\"accepted\":true}", format(std.math.maxInt(u64), &bytes));
}
