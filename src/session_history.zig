//! The command that exports one saved conversation row.
const std = @import("std");

/// The command that exports one conversation row's exact bytes.
pub fn writeExport(sink: anytype, store: []const u8, session: []const u8, position: u64, ordinal: u64) !void {
    var buffer: [64]u8 = undefined;
    try sink.feed("Raw export: rui session read-conversation --store-hex ");
    try writeHex(sink, store);
    try sink.feed(" --session ");
    try sink.feed(session);
    try sink.feed(try std.fmt.bufPrint(&buffer, " --position {d} --ordinal {d}", .{ position, ordinal }));
}

fn writeHex(sink: anytype, bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var used: usize = 0;
    for (bytes) |byte| {
        const encoded = std.fmt.bytesToHex([1]u8{byte}, .lower);
        @memcpy(buffer[used..][0..2], &encoded);
        used += 2;
        if (used == buffer.len) {
            try sink.feed(&buffer);
            used = 0;
        }
    }
    if (used != 0) try sink.feed(buffer[0..used]);
}

test "historical export preserves hex Store escaping and canonical Session IDs" {
    const Sink = struct {
        bytes: [2048]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var sink: Sink = .{};
    try writeExport(&sink, "/tmp/a'$(false)\x1b[2J\né\u{202e}", "09azvw", 2, 0);
    // Independent UTF-8 byte-to-hex oracle for Store controls and directional text.
    try std.testing.expectEqualStrings("Raw export: rui session read-conversation --store-hex 2f746d702f6127242866616c7365291b5b324a0ac3a9e280ae --session 09azvw --position 2 --ordinal 0", sink.bytes[0..sink.length]);
    // A Store path longer than one hex window keeps every byte, in order.
    sink = .{};
    const long: [200]u8 = @splat('a');
    try writeExport(&sink, &long, "09azvw", 7, 2);
    const hex: [400]u8 = @bitCast(@as([200][2]u8, @splat("61".*)));
    try std.testing.expectEqualStrings("Raw export: rui session read-conversation --store-hex " ++ hex ++ " --session 09azvw --position 7 --ordinal 2", sink.bytes[0..sink.length]);
}
