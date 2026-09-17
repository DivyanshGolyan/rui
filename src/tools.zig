const std = @import("std");
const protocol = @import("protocol.zig");

pub const bash_definition_json =
    "{\"type\":\"function\",\"name\":\"bash\",\"description\":\"Run Bash\",\"strict\":true," ++
    "\"parameters\":{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}," ++
    "\"timeout_ms\":{\"type\":[\"integer\",\"null\"],\"minimum\":1,\"maximum\":9223372036854775807}}," ++
    "\"required\":[\"cmd\",\"timeout_ms\"],\"additionalProperties\":false}}";

pub const BashArguments = struct {
    timeout_ms: ?u64 = null,
};

pub fn validBashArguments(source: anytype) !bool {
    var discard: Discard = .{};
    return try parseBashArguments(source, &discard) != null;
}

pub fn inspectBashArguments(source: anytype) !?BashArguments {
    var discard: Discard = .{};
    return parseBashArguments(source, &discard);
}

pub fn writeBashCommand(source: anytype, writer: anytype) !bool {
    return try parseBashArguments(source, writer) != null;
}

fn parseBashArguments(source: anytype, writer: anytype) !?BashArguments {
    return parseBashArgumentsStrict(source, writer) catch |err| {
        if (isDescriptorError(err)) return null;
        return err;
    };
}

fn parseBashArgumentsStrict(source: anytype, writer: anytype) !?BashArguments {
    try source.expect('{');
    var result: BashArguments = .{};
    var has_command = false;
    var has_timeout = false;
    while (true) {
        try source.space();
        if (try source.peek() == '}') return null;
        var key: protocol.Bounded(16) = .{};
        try decodeString(source, &key, null);
        try source.expect(':');
        if (key.eql("cmd")) {
            if (has_command) return null;
            try decodeString(source, null, writer);
            has_command = true;
        } else if (key.eql("timeout_ms")) {
            if (has_timeout) return null;
            result.timeout_ms = try parseTimeout(source);
            has_timeout = true;
        } else return null;
        try source.space();
        switch (try source.take()) {
            ',' => {},
            '}' => break,
            else => return null,
        }
    }
    try source.space();
    if (try source.peek() != null or !has_command or !has_timeout) return null;
    return result;
}

fn parseTimeout(source: anytype) !?u64 {
    try source.space();
    if (try source.peek() == 'n') {
        inline for ("null") |expected| if (try source.take() != expected) return error.InvalidDescriptorShape;
        return null;
    }
    var byte = try source.take();
    if (byte < '1' or byte > '9') return error.InvalidDescriptorShape;
    var value: u64 = byte - '0';
    while (try source.peek()) |next| {
        if (next < '0' or next > '9') break;
        byte = try source.take();
        value = std.math.mul(u64, value, 10) catch return error.InvalidDescriptorShape;
        value = std.math.add(u64, value, byte - '0') catch return error.InvalidDescriptorShape;
        if (value > std.math.maxInt(i64)) return error.InvalidDescriptorShape;
    }
    return value;
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
        if (scalar == 0) return error.InvalidDescriptorShape;
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

fn isDescriptorError(err: anyerror) bool {
    return switch (err) {
        error.InvalidDescriptorJson, error.InvalidDescriptorShape, error.InvalidEncodedString => true,
        else => false,
    };
}
