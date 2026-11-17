const std = @import("std");
pub const Path = @import("bounded.zig").Bounded(@import("workspace_path.zig").max_bytes);
pub const max_argument_bytes = 32 * 1024;
const max_path_bytes = @import("workspace_path.zig").max_bytes;

pub fn valid(source: anytype) !bool {
    return parseInto(source, null);
}

/// Validates the same typed boundary used when the authorized Action runs.
/// The optional destination belongs to the caller; validation alone retains
/// only byte counts and UTF-8 state, never a second path or complete JSON.
pub fn parse(source: anytype, out: *Path) !bool {
    return parseInto(source, out);
}

fn parseInto(source: anytype, out: ?*Path) !bool {
    var memory: [256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    var scanner: std.json.Scanner = .initStreaming(fixed.allocator());
    defer scanner.deinit();
    var chunk: [256]u8 = undefined;
    var total: usize = 0;
    var ended = false;
    var state: enum { root, key, path, close, document } = .root;
    var key: [4]u8 = undefined;
    var key_length: usize = 0;
    var path_length: usize = 0;
    var url_prefix: u2 = 0;
    var utf8: @import("utf8_validation.zig").State = .{};
    if (out) |path| path.len = 0;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => {
                if (ended) return false;
                var length: usize = 0;
                while (length < chunk.len and total < max_argument_bytes and try source.peek() != null) {
                    chunk[length] = try source.take();
                    length += 1;
                    total += 1;
                }
                if (length == 0) {
                    if (try source.peek() != null) return false;
                    ended = true;
                    scanner.endInput();
                } else scanner.feedInput(chunk[0..length]);
                continue;
            },
            error.SyntaxError, error.UnexpectedEndOfInput, error.OutOfMemory => return false,
        };
        const piece: ?[]const u8 = switch (token) {
            .partial_string, .string => |bytes| bytes,
            .partial_string_escaped_1 => |*bytes| bytes,
            .partial_string_escaped_2 => |*bytes| bytes,
            .partial_string_escaped_3 => |*bytes| bytes,
            .partial_string_escaped_4 => |*bytes| bytes,
            else => null,
        };
        if (piece) |bytes| {
            switch (state) {
                .key => {
                    if (bytes.len > key.len - key_length) return false;
                    @memcpy(key[key_length..][0..bytes.len], bytes);
                    key_length += bytes.len;
                    if (token == .string) {
                        if (key_length != key.len or !std.mem.eql(u8, &key, "path")) return false;
                        state = .path;
                    }
                },
                .path => {
                    if (bytes.len > max_path_bytes - path_length) return false;
                    utf8.feed(bytes) catch return false;
                    for (bytes) |byte| {
                        if (byte == 0) return false;
                        url_prefix = if (byte == ':') 1 else if (byte == '/' and url_prefix != 0) url_prefix + 1 else 0;
                        if (url_prefix == 3) return false;
                    }
                    if (out) |path| @memcpy(path.bytes[path_length..][0..bytes.len], bytes);
                    path_length += bytes.len;
                    if (token == .string) {
                        if (path_length == 0 or !utf8.complete()) return false;
                        state = .close;
                    }
                },
                else => return false,
            }
            continue;
        }
        switch (token) {
            .object_begin => if (state == .root) {
                state = .key;
            } else return false,
            .object_end => if (state == .close) {
                state = .document;
            } else return false,
            .end_of_document => {
                if (state != .document) return false;
                if (out) |path| path.len = path_length;
                return true;
            },
            else => return false,
        }
    }
}

test "read_image typed arguments accept only one bounded local path string" {
    const Source = struct {
        bytes: []const u8,
        at: usize = 0,
        pub fn peek(self: *@This()) !?u8 {
            return if (self.at == self.bytes.len) null else self.bytes[self.at];
        }
        pub fn take(self: *@This()) !u8 {
            const byte = self.bytes[self.at];
            self.at += 1;
            return byte;
        }
    };
    var path: Path = .{};
    for ([_][]const u8{ "{\"path\":\"pixel.png\"}", "{\"path\":\"/tmp/caf\\u00e9.jpg\"}" }) |bytes| {
        var source: Source = .{ .bytes = bytes };
        try std.testing.expect(try parse(&source, &path));
    }
    try std.testing.expectEqualStrings("/tmp/café.jpg", path.slice());
    for ([_][]const u8{
        "{}",                              "null",                            "[]",                                       "{\"path\":1}",             "{\"path\":null}",           "{\"path\":\"\"}",
        "{\"path\":\"a\",\"other\":true}", "{\"path\":\"a\",\"path\":\"b\"}", "{\"path\":\"https://example.com/a.png\"}", "{\"path\":\"a\\u0000b\"}", "{\"path\":\"a\"} trailing", "{\"path\":\"\xff\"}",
    }) |bytes| {
        var source: Source = .{ .bytes = bytes };
        try std.testing.expect(!try parse(&source, &path));
    }
    var boundary: [4096 + 11]u8 = undefined;
    @memcpy(boundary[0..9], "{\"path\":\"");
    @memset(boundary[9..][0..4096], 'p');
    @memcpy(boundary[9 + 4096 ..], "\"}");
    var maximum: Source = .{ .bytes = &boundary };
    try std.testing.expect(try parse(&maximum, &path));
    try std.testing.expectEqual(@as(usize, 4096), path.slice().len);
    var excessive: [4096 + 12]u8 = undefined;
    @memcpy(excessive[0..9], "{\"path\":\"");
    @memset(excessive[9..][0..4097], 'p');
    @memcpy(excessive[9 + 4097 ..], "\"}");
    var oversized: Source = .{ .bytes = &excessive };
    try std.testing.expect(!try parse(&oversized, &path));
    // Put a raw UTF-8 scalar and JSON escape at a scanner window boundary.
    for ([_][]const u8{ "é.png", "\\u00e9.png", "\\u0000.png", "://image.png" }) |suffix| {
        var bytes: [512]u8 = undefined;
        @memcpy(bytes[0..9], "{\"path\":\"");
        @memset(bytes[9..255], 'p');
        @memcpy(bytes[255..][0..suffix.len], suffix);
        @memcpy(bytes[255 + suffix.len ..][0..2], "\"}");
        var source: Source = .{ .bytes = bytes[0 .. 257 + suffix.len] };
        const accepted = !std.mem.eql(u8, suffix, "\\u0000.png") and !std.mem.eql(u8, suffix, "://image.png");
        try std.testing.expectEqual(accepted, try parse(&source, &path));
    }
}
