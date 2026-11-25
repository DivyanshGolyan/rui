//! Fixtures that compare what a row says, not how it tags its leading glyph, read it through `visible`.
const std = @import("std");
const Text = @import("../TerminalText.zig");

/// A user line's leading `›` as production tags it, without the decoration that keeps it out of copies.
pub const user_line = Text.leader_on ++ "›" ++ Text.leader_off ++ " ";

var storage: [16 * 1024]u8 = undefined;

/// `bytes` without the leader tags (`Text.leader_on`, `quoted_leader_on`, `leader_off`), valid until the next call.
/// The tags' own invariant (SUI-176) is checked where the producers are, so other fixtures need not repeat them.
pub fn visible(bytes: []const u8) []const u8 {
    var length: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const rest = bytes[at..];
        const tag: ?[]const u8 = for ([_][]const u8{ Text.leader_on, Text.quoted_leader_on, Text.leader_off }) |tag| {
            if (std.mem.startsWith(u8, rest, tag)) break tag;
        } else null;
        if (tag) |found| {
            at += found.len;
            continue;
        }
        storage[length] = bytes[at];
        length += 1;
        at += 1;
    }
    return storage[0..length];
}

test "visible drops only the leader tags" {
    try std.testing.expectEqualStrings("✓ a\x1b[1mb", visible(Text.leader_on ++ "✓" ++ Text.leader_off ++ " a\x1b[1mb"));
    try std.testing.expectEqualStrings("● x", visible(Text.quoted_leader_on ++ "●" ++ Text.leader_off ++ " x"));
}
