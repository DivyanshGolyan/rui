const std = @import("std");
const protocol = @import("protocol.zig");

pub const bash_definition_json =
    "{\"type\":\"function\",\"name\":\"bash\",\"description\":\"Run Bash\",\"strict\":true," ++
    "\"parameters\":{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}}," ++
    "\"required\":[\"cmd\"],\"additionalProperties\":false}}";

pub fn validBashArguments(source: anytype) !bool {
    var discard: Discard = .{};
    return parseBashArguments(source, &discard);
}

pub fn writeBashCommand(source: anytype, writer: anytype) !bool {
    return parseBashArguments(source, writer);
}

fn parseBashArguments(source: anytype, writer: anytype) !bool {
    source.expect('{') catch |err| return descriptorSyntax(err);
    var key: protocol.Bounded(16) = .{};
    decodeString(source, &key, null) catch |err| return descriptorSyntax(err);
    if (!key.eql("cmd")) return false;
    source.expect(':') catch |err| return descriptorSyntax(err);
    decodeString(source, null, writer) catch |err| return descriptorSyntax(err);
    try source.space();
    const close = source.take() catch |err| return descriptorSyntax(err);
    if (close != '}') return false;
    try source.space();
    return try source.peek() == null;
}

fn decodeString(source: anytype, destination: ?*protocol.Bounded(16), writer: anytype) !void {
    try source.space();
    if (try source.take() != '"') return error.InvalidDescriptorJson;
    if (destination) |value| value.len = 0;
    while (true) {
        const byte = try source.take();
        if (byte == '"') return;
        if (byte < 0x20) return error.InvalidDescriptorJson;
        if (byte != '\\') {
            try emit(destination, writer, &.{byte});
            continue;
        }
        const escape = try source.take();
        const simple: ?u8 = switch (escape) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 8,
            'f' => 12,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => null,
            else => return error.InvalidDescriptorJson,
        };
        if (simple) |decoded| {
            try emit(destination, writer, &.{decoded});
            continue;
        }
        var scalar = try hexScalar(source);
        if (scalar >= 0xd800 and scalar <= 0xdbff) {
            if (try source.take() != '\\' or try source.take() != 'u') return error.InvalidDescriptorJson;
            const low = try hexScalar(source);
            if (low < 0xdc00 or low > 0xdfff) return error.InvalidDescriptorJson;
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00);
        } else if (scalar >= 0xdc00 and scalar <= 0xdfff) return error.InvalidDescriptorJson;
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(scalar, &encoded) catch return error.InvalidDescriptorJson;
        try emit(destination, writer, encoded[0..count]);
    }
}

fn emit(destination: ?*protocol.Bounded(16), writer: anytype, bytes: []const u8) !void {
    if (destination) |value| {
        if (value.len + bytes.len > value.bytes.len) return error.InvalidDescriptorShape;
        @memcpy(value.bytes[value.len .. value.len + bytes.len], bytes);
        value.len += bytes.len;
    }
    if (@TypeOf(writer) != @TypeOf(null)) try writer.writeAll(bytes);
}

fn hexScalar(source: anytype) !u21 {
    var value: u21 = 0;
    for (0..4) |_| {
        const byte = try source.take();
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return error.InvalidDescriptorJson,
        };
        value = value * 16 + digit;
    }
    return value;
}

const Discard = struct {
    fn writeAll(_: *Discard, _: []const u8) !void {}
};

fn descriptorSyntax(err: anyerror) anyerror!bool {
    return switch (err) {
        error.InvalidDescriptorJson, error.InvalidDescriptorShape, error.InvalidEncodedString => false,
        else => err,
    };
}
