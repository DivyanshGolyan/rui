const std = @import("std");
const protocol = @import("protocol.zig");

pub const bash_definition_json =
    "{\"type\":\"function\",\"name\":\"bash\",\"description\":\"Run Bash on the local machine. Each call starts in the Session Workspace; relative paths resolve there, while absolute paths can access outside it. Start filesystem exploration there and broaden searches only as needed.\",\"strict\":true," ++
    "\"parameters\":{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}," ++
    "\"description\":{\"type\":\"string\",\"description\":\"A short human-facing activity label: base verb + concrete target + useful scope, in sentence case with no trailing punctuation. Describe the intended work, not its status, success or safety. Required, nonblank, single-line valid UTF-8, at most 100 decoded UTF-8 bytes. Aim for 40–60 characters; use more only for useful scope. Example: Run parser regression tests\"}," ++
    "\"timeout_ms\":{\"type\":[\"integer\",\"null\"],\"description\":\"Use null for the Host default unless the work needs a different budget. A positive integer replaces it with a total elapsed execution budget in milliseconds from process start; output does not reset it. Allow enough time for searches, builds and tests. Expiry ends the call through process-group termination, not a background handle; partial effects may remain.\",\"minimum\":1,\"maximum\":9223372036854775807}}," ++
    "\"required\":[\"cmd\",\"description\",\"timeout_ms\"],\"additionalProperties\":false}}";

pub const BashArguments = struct {
    timeout_ms: ?u64 = null,
    description: protocol.Bounded(protocol.max_tool_description_bytes) = .{},
};

pub const Tool = @typeInfo(@FieldType(protocol.ToolsField, "values")).array.child;
pub const ToolSet = std.EnumSet(Tool);
pub const CallName = enum { bash, edit, unknown };

/// Admission policy over adapter-certified descriptor facts and frozen tools.
/// Call this under the transaction that publishes the proposal and Action.
pub fn classifyCall(name: CallName, valid_arguments: bool, frozen: ToolSet) ?protocol.ProposalRejection {
    return switch (name) {
        .bash => if (!frozen.contains(.bash)) .unknown_tool else if (!valid_arguments) .invalid_arguments else null,
        .edit => if (frozen.contains(.edit)) .tool_unavailable else .unknown_tool,
        .unknown => .unknown_tool,
    };
}

test "tool classification uses frozen availability before argument validity" {
    const none: ToolSet = .empty;
    const bash_only = ToolSet.initOne(.bash);
    const edit_only = ToolSet.initOne(.edit);
    try std.testing.expectEqual(protocol.ProposalRejection.unknown_tool, classifyCall(.bash, false, none).?);
    try std.testing.expectEqual(protocol.ProposalRejection.unknown_tool, classifyCall(.bash, true, edit_only).?);
    try std.testing.expectEqual(protocol.ProposalRejection.invalid_arguments, classifyCall(.bash, false, bash_only).?);
    try std.testing.expect(classifyCall(.bash, true, bash_only) == null);
    try std.testing.expectEqual(protocol.ProposalRejection.tool_unavailable, classifyCall(.edit, true, edit_only).?);
    try std.testing.expectEqual(protocol.ProposalRejection.unknown_tool, classifyCall(.edit, true, bash_only).?);
    try std.testing.expectEqual(protocol.ProposalRejection.unknown_tool, classifyCall(.unknown, true, .full).?);
}

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
    var parser: BashParser = .{};
    while (true) {
        const progress = parser.advance(source, writer, 4096) catch |err| {
            if (isBashDescriptorError(err)) return null;
            return err;
        };
        switch (progress) {
            .pending => {},
            .invalid => return null,
            .complete => |result| return result,
        }
    }
}

pub const BashParseProgress = union(enum) {
    pending,
    invalid,
    complete: BashArguments,
};

pub const BashParser = struct {
    const Phase = enum {
        object_start,
        key_start,
        string,
        escape,
        unicode,
        surrogate_backslash,
        surrogate_u,
        low_unicode,
        colon,
        value_start,
        timeout_digits,
        timeout_null,
        after_value,
        after_object,
    };
    const StringTarget = enum { key, command, description };
    const ValueTarget = enum { none, command, timeout, description };

    phase: Phase = .object_start,
    string_target: StringTarget = .key,
    value_target: ValueTarget = .none,
    key: protocol.Bounded(16) = .{},
    result: BashArguments = .{},
    has_command: bool = false,
    has_timeout: bool = false,
    has_description: bool = false,
    timeout_value: u64 = 0,
    null_index: u3 = 0,
    unicode_value: u21 = 0,
    unicode_digits: u3 = 0,
    high_surrogate: u21 = 0,

    pub fn advance(self: *BashParser, source: anytype, writer: anytype, maximum_bytes: usize) !BashParseProgress {
        std.debug.assert(maximum_bytes != 0);
        var consumed: usize = 0;
        while (consumed < maximum_bytes) {
            const next = try source.peek() orelse return self.finishAtEof();
            if (self.phase == .timeout_digits and (next < '0' or next > '9')) {
                self.result.timeout_ms = self.timeout_value;
                self.has_timeout = true;
                self.phase = .after_value;
                continue;
            }
            _ = try source.take();
            consumed += 1;
            switch (self.phase) {
                .object_start => {
                    if (isSpace(next)) continue;
                    if (next != '{') return .invalid;
                    self.phase = .key_start;
                },
                .key_start => {
                    if (isSpace(next)) continue;
                    if (next != '"') return .invalid;
                    self.key.len = 0;
                    self.string_target = .key;
                    self.phase = .string;
                },
                .string => {
                    if (next == '"') {
                        switch (self.string_target) {
                            .key => {
                                self.value_target = if (self.key.eql("cmd"))
                                    .command
                                else if (self.key.eql("timeout_ms"))
                                    .timeout
                                else if (self.key.eql("description"))
                                    .description
                                else
                                    return .invalid;
                                self.phase = .colon;
                            },
                            .command => {
                                self.has_command = true;
                                self.phase = .after_value;
                            },
                            .description => {
                                if (!validDescription(self.result.description.slice())) return .invalid;
                                self.has_description = true;
                                self.phase = .after_value;
                            },
                        }
                    } else if (next < 0x20) {
                        return .invalid;
                    } else if (next == '\\') {
                        self.phase = .escape;
                    } else {
                        try self.emitString(writer, &.{next});
                    }
                },
                .escape => {
                    const decoded: ?u8 = switch (next) {
                        '"' => '"',
                        '\\' => '\\',
                        '/' => '/',
                        'b' => 8,
                        'f' => 12,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'u' => null,
                        else => return .invalid,
                    };
                    if (decoded) |byte| {
                        try self.emitString(writer, &.{byte});
                        self.phase = .string;
                    } else {
                        self.unicode_value = 0;
                        self.unicode_digits = 0;
                        self.phase = .unicode;
                    }
                },
                .unicode => {
                    self.unicode_value = self.unicode_value * 16 + (std.fmt.charToDigit(next, 16) catch return .invalid);
                    self.unicode_digits += 1;
                    if (self.unicode_digits == 4) {
                        if (self.unicode_value >= 0xd800 and self.unicode_value <= 0xdbff) {
                            self.high_surrogate = self.unicode_value;
                            self.phase = .surrogate_backslash;
                        } else {
                            if (self.unicode_value >= 0xdc00 and self.unicode_value <= 0xdfff) return .invalid;
                            if (!(try self.emitScalar(writer, self.unicode_value))) return .invalid;
                            self.phase = .string;
                        }
                    }
                },
                .surrogate_backslash => {
                    if (next != '\\') return .invalid;
                    self.phase = .surrogate_u;
                },
                .surrogate_u => {
                    if (next != 'u') return .invalid;
                    self.unicode_value = 0;
                    self.unicode_digits = 0;
                    self.phase = .low_unicode;
                },
                .low_unicode => {
                    self.unicode_value = self.unicode_value * 16 + (std.fmt.charToDigit(next, 16) catch return .invalid);
                    self.unicode_digits += 1;
                    if (self.unicode_digits == 4) {
                        if (self.unicode_value < 0xdc00 or self.unicode_value > 0xdfff) return .invalid;
                        const scalar = 0x10000 + ((self.high_surrogate - 0xd800) << 10) +
                            (self.unicode_value - 0xdc00);
                        if (!(try self.emitScalar(writer, scalar))) return .invalid;
                        self.phase = .string;
                    }
                },
                .colon => {
                    if (isSpace(next)) continue;
                    if (next != ':') return .invalid;
                    self.phase = .value_start;
                },
                .value_start => {
                    if (isSpace(next)) continue;
                    switch (self.value_target) {
                        .none => unreachable,
                        .command => {
                            if (self.has_command or next != '"') return .invalid;
                            self.string_target = .command;
                            self.phase = .string;
                        },
                        .description => {
                            if (self.has_description or next != '"') return .invalid;
                            self.string_target = .description;
                            self.phase = .string;
                        },
                        .timeout => {
                            if (self.has_timeout) return .invalid;
                            if (next == 'n') {
                                self.null_index = 1;
                                self.phase = .timeout_null;
                            } else {
                                if (next < '1' or next > '9') return .invalid;
                                self.timeout_value = next - '0';
                                self.phase = .timeout_digits;
                            }
                        },
                    }
                },
                .timeout_digits => {
                    self.timeout_value = std.math.mul(u64, self.timeout_value, 10) catch return .invalid;
                    self.timeout_value = std.math.add(u64, self.timeout_value, next - '0') catch return .invalid;
                    if (self.timeout_value > std.math.maxInt(i64)) return .invalid;
                },
                .timeout_null => {
                    if (next != "null"[self.null_index]) return .invalid;
                    self.null_index += 1;
                    if (self.null_index == "null".len) {
                        self.result.timeout_ms = null;
                        self.has_timeout = true;
                        self.phase = .after_value;
                    }
                },
                .after_value => {
                    if (isSpace(next)) continue;
                    if (next == ',') {
                        self.phase = .key_start;
                    } else if (next == '}') {
                        self.phase = .after_object;
                    } else return .invalid;
                },
                .after_object => if (!isSpace(next)) return .invalid,
            }
        }
        return .pending;
    }

    fn finishAtEof(self: *const BashParser) BashParseProgress {
        if (self.phase != .after_object or !self.has_command or !self.has_timeout or !self.has_description) return .invalid;
        return .{ .complete = self.result };
    }

    fn emitString(self: *BashParser, writer: anytype, bytes: []const u8) !void {
        switch (self.string_target) {
            .key => try emit(&self.key, null, bytes),
            .command => try emit(null, writer, bytes),
            .description => {
                const label = &self.result.description;
                if (bytes.len > label.bytes.len - label.len) return error.InvalidDescriptorShape;
                @memcpy(label.bytes[label.len..][0..bytes.len], bytes);
                label.len += bytes.len;
            },
        }
    }

    fn emitScalar(self: *BashParser, writer: anytype, scalar: u21) !bool {
        if (scalar == 0) return false;
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(scalar, &encoded) catch return false;
        try self.emitString(writer, encoded[0..count]);
        return true;
    }
};

pub fn validDescription(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > protocol.max_tool_description_bytes or !std.unicode.utf8ValidateSlice(bytes)) return false;
    var scalars = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    var nonblank = false;
    while (scalars.nextCodepoint()) |scalar| {
        switch (scalar) {
            '\n', '\r', 0x85, 0x2028, 0x2029 => return false,
            ' ', '\t', 0xb, 0xc, 0xa0, 0x1680, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => {},
            else => nonblank = true,
        }
    }
    return nonblank;
}

fn isSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

fn emit(destination: ?*protocol.Bounded(16), writer: anytype, bytes: []const u8) !void {
    if (destination) |value| {
        if (value.len + bytes.len > value.bytes.len) return error.InvalidDescriptorShape;
        @memcpy(value.bytes[value.len .. value.len + bytes.len], bytes);
        value.len += bytes.len;
    }
    if (@TypeOf(writer) != @TypeOf(null)) try writer.writeAll(bytes);
}

const Discard = struct {
    fn writeAll(_: *Discard, _: []const u8) !void {}
};

pub fn isBashDescriptorError(err: anyerror) bool {
    return switch (err) {
        error.InvalidDescriptorShape => true,
        else => false,
    };
}

const TestSource = struct {
    bytes: []const u8,
    position: usize = 0,

    fn peek(self: *TestSource) !?u8 {
        return if (self.position == self.bytes.len) null else self.bytes[self.position];
    }

    fn take(self: *TestSource) !u8 {
        const byte = (try self.peek()) orelse return error.ShortCanonicalRead;
        self.position += 1;
        return byte;
    }
};

const TestWriter = struct {
    bytes: [128]u8 = undefined,
    length: usize = 0,

    fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        if (self.length + bytes.len > self.bytes.len) return error.TestWriterFull;
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }

    fn slice(self: *const TestWriter) []const u8 {
        return self.bytes[0..self.length];
    }
};

test "resumable Bash parser preserves state across every byte boundary" {
    var source = TestSource{
        .bytes = " \n{\"description\":\"Read \\u20ac\\ud83d\\ude00\",\"timeout_ms\":123,\"cmd\":\"a\\n\\u20ac\\ud83d\\ude00\\\\z\"}\t",
    };
    var writer: TestWriter = .{};
    var parser: BashParser = .{};
    while (true) switch (try parser.advance(&source, &writer, 1)) {
        .pending => {},
        .invalid => return error.TestUnexpectedInvalidDescriptor,
        .complete => |arguments| {
            try std.testing.expectEqual(@as(?u64, 123), arguments.timeout_ms);
            try std.testing.expectEqualStrings("Read €😀", arguments.description.slice());
            try std.testing.expectEqualStrings("a\n€😀\\z", writer.slice());
            break;
        },
    };
}

test "resumable Bash parser rejects malformed split values" {
    const descriptors = [_][]const u8{
        "{\"description\":\"Run command\",\"cmd\":\"\\ud83dX\",\"timeout_ms\":null}",
        "{\"description\":\"Run command\",\"cmd\":\"ok\",\"timeout_ms\":9223372036854775808}",
        "{\"description\":\"Run command\",\"cmd\":\"ok\",\"timeout_ms\":null,\"cmd\":\"again\"}",
    };
    for (descriptors) |descriptor| {
        var source = TestSource{ .bytes = descriptor };
        var writer: TestWriter = .{};
        var parser: BashParser = .{};
        while (true) switch (try parser.advance(&source, &writer, 1)) {
            .pending => {},
            .invalid => break,
            .complete => return error.TestUnexpectedValidDescriptor,
        };
    }
}

test "Bash descriptions are required and bounded by decoded UTF-8 bytes" {
    var missing = TestSource{ .bytes = "{\"cmd\":\"true\",\"timeout_ms\":null}" };
    try std.testing.expect(!try validBashArguments(&missing));
    const invalid = [_][]const u8{
        "\"\"",        "\"   \"",     "null",      "1", "\"line\\nnext\"", "\"line\\rnext\"",
        "\"\\u2028\"", "\"\\ud800\"", "\"\xc3(\"",
    };
    var buffer: [512]u8 = undefined;
    for (invalid) |description| {
        var source = TestSource{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"cmd\":\"true\",\"timeout_ms\":null,\"description\":{s}}}", .{description}) };
        try std.testing.expect(!try validBashArguments(&source));
    }
    for ([_][]const u8{ @as([98]u8, @splat('a')) ++ "é", &@as([50 * 6]u8, @bitCast(@as([50][6]u8, @splat("\\u00e9".*)))) }) |description| {
        var source = TestSource{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"description\":\"{s}\",\"cmd\":\"printf ok\",\"timeout_ms\":null}}", .{description}) };
        try std.testing.expect(try validBashArguments(&source));
    }
    for ([_][]const u8{ @as([99]u8, @splat('a')) ++ "é", &@as([51 * 6]u8, @bitCast(@as([51][6]u8, @splat("\\u00e9".*)))) }) |description| {
        var source = TestSource{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"cmd\":\"true\",\"description\":\"{s}\",\"timeout_ms\":null}}", .{description}) };
        try std.testing.expect(!try validBashArguments(&source));
    }
    var duplicate = TestSource{ .bytes = "{\"description\":\"Run tests\",\"cmd\":\"true\",\"description\":\"Read files\",\"timeout_ms\":null}" };
    try std.testing.expect(!try validBashArguments(&duplicate));
}
