const std = @import("std");

pub const note = "The final result reaches you as new input when this Action finishes. Do not poll for it; end your turn if nothing else is left to do.";

pub const Bytes = [256]u8;

pub fn format(action_id: u64, bytes: *Bytes) []const u8 {
    std.debug.assert(action_id > 0);
    return std.fmt.bufPrint(bytes, "{{\"action\":\"{d}\",\"execution\":\"background\",\"accepted\":true,\"note\":\"{s}\"}}", .{ action_id, note }) catch unreachable;
}

test "background receipt identifies acceptance without claiming a running or final Action" {
    var bytes: Bytes = undefined;
    try std.testing.expectEqualStrings("{\"action\":\"18446744073709551615\",\"execution\":\"background\",\"accepted\":true,\"note\":\"" ++ note ++ "\"}", format(std.math.maxInt(u64), &bytes));
}
