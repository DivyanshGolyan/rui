//! Fixture setup only: send stdin SQL as the CI server's root user. The
//! Host under test uses its own independent production Store connection.
const std = @import("std");
const wire = @import("mysql_connection");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const connection = try allocator.create(wire.Connection);
    var refusal: std.Io.Writer.Discarding = .init(&.{});
    try connection.open(.{
        .address = .{ .unix_socket = init.environ_map.get("RUI_TEST_MYSQL_SOCKET") orelse return error.MissingServer },
        .user = "root",
        .password = init.environ_map.get("RUI_TEST_MYSQL_ROOT_PASSWORD") orelse return error.MissingPassword,
        .database = "mysql",
    }, &refusal.writer);
    defer connection.close();
    var text: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        // EOF arrives as error.EndOfStream; a zero-byte read is not EOF.
        const count = std.Io.File.stdin().readStreaming(init.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (text.items.len + count > 1024 * 1024) return error.SqlTooLarge;
        try text.appendSlice(allocator, buffer[0..count]);
    }
    try connection.query(text.items);
    var row = false;
    const output = std.Io.File.stdout();
    while (!connection.isReady()) switch (try connection.next()) {
        .err => return error.FixtureSqlRefused,
        .row => {
            if (row) try output.writeStreamingAll(init.io, "\n");
            row = true;
        },
        .bytes => |bytes| try output.writeStreamingAll(init.io, bytes),
        else => {},
    };
    if (row) try output.writeStreamingAll(init.io, "\n");
}
