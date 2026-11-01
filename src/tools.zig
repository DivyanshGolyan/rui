const std = @import("std");
const protocol = @import("protocol.zig");
const codec_abi = @import("codec_abi.zig");

/// Bash receives the command as one `-c` argument. Linux rejects an
/// argument of 128 KiB including its NUL (MAX_ARG_STRLEN with 4 KiB pages),
/// and with a small stack rlimit the whole argv+environment shares a 128 KiB
/// floor; 8 KiB stays for the shell path, environment and pointers.
pub const bash_max_command_bytes: usize = 120 * 1024;
/// Reuse the command ceiling for optional decoded stdin in charged scratch.
pub const bash_max_stdin_bytes: usize = bash_max_command_bytes;

pub const bash_definition: codec_abi.ToolDefinition = .{
    .name = "bash",
    .description = "Run Bash on the local machine. Each call starts in the Session Workspace; relative paths resolve there, while absolute paths can access outside it. Start filesystem exploration there and broaden searches only as needed. Put text payloads in stdin, never inside cmd. Bash has no terminal: no one can type into a running call, so password prompts (such as sudo) and interactive programs fail. Give a command that needs one to the user to run in their own terminal, up front when you can tell, otherwise after its first such failure, and do not retry it here.",
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}," ++
        std.fmt.comptimePrint("\"stdin\":{{\"type\":[\"string\",\"null\"],\"description\":\"Stdin is empty unless set. Supply literal UTF-8 text, at most {d} decoded bytes, read exactly then EOF. Missing or null uses /dev/null.\"}},", .{bash_max_stdin_bytes}) ++
        "\"description\":{\"type\":\"string\",\"description\":\"A short human-facing activity label: base verb + concrete target + useful scope, in sentence case with no trailing punctuation. Describe the intended work, not its status, success or safety. Required, nonblank, single-line valid UTF-8, at most 100 decoded UTF-8 bytes. Aim for 40–60 characters; use more only for useful scope. Example: Run parser regression tests\"}," ++
        "\"timeout_ms\":{\"type\":[\"integer\",\"null\"],\"description\":\"Use null for the Host default unless the work needs a different budget. A positive integer replaces it with a total elapsed execution budget in milliseconds from process start; output does not reset it. Allow enough time for searches, builds and tests. Expiry ends the call through process-group termination, not a background handle; partial effects may remain.\",\"minimum\":1,\"maximum\":9223372036854775807}}," ++
        "\"required\":[\"cmd\",\"stdin\",\"description\",\"timeout_ms\"],\"additionalProperties\":false}",
};

pub fn definition(tool: Tool) *const codec_abi.ToolDefinition {
    return switch (tool) {
        .bash => &bash_definition,
    };
}

pub const BashArguments = struct {
    timeout_ms: ?u64 = null,
    description: protocol.Bounded(protocol.max_tool_description_bytes) = .{},
    stdin_present: bool = false,
};

pub const Tool = @typeInfo(@FieldType(protocol.ToolsField, "values")).array.child;
pub const ToolSet = std.EnumSet(Tool);
pub const CallName = enum { bash, unknown };

/// Persisted tools_mask bit shared by Store encoding and model preparation.
pub fn toolBit(tool: Tool) u8 {
    return switch (tool) {
        .bash => 1,
    };
}

pub const CallFacts = struct {
    name: CallName,
    bash_arguments: ?BashArguments,
};

/// Inspect certified decoded sources; the caller retains their storage and
/// owns admission against the frozen catalog in its publication transaction.
pub fn inspectCall(name_source: anytype, name_length: u64, arguments: anytype) !CallFacts {
    var name: [4]u8 = undefined;
    var length: usize = 0;
    if (name_length == name.len) {
        while (length < name.len) : (length += 1) name[length] = (try name_source.next()) orelse break;
    }
    const kind: CallName = if (length == name.len and try name_source.next() == null)
        if (std.mem.eql(u8, &name, "bash")) .bash else .unknown
    else
        .unknown;
    return .{ .name = kind, .bash_arguments = if (kind == .bash) try inspectBashArguments(arguments) else null };
}

pub fn rejectionResult(code: protocol.ProposalRejection, name: anytype, name_length: u64, name_digest: [32]u8, buffer: *[192]u8) ![]const u8 {
    switch (code) {
        .invalid_arguments => return "Invalid arguments for tool 'bash'.",
        .unknown_tool => {
            var prefix: [32]u8 = undefined;
            var prefix_length: usize = 0;
            while (prefix_length < prefix.len) {
                prefix[prefix_length] = (try name.next()) orelse break;
                prefix_length += 1;
            }
            while (!std.unicode.utf8ValidateSlice(prefix[0..prefix_length])) prefix_length -= 1;
            if (name_length <= prefix.len) return std.fmt.bufPrint(buffer, "Unknown tool: {s}.", .{prefix[0..prefix_length]});
            const digest_hex = std.fmt.bytesToHex(name_digest, .lower);
            return std.fmt.bufPrint(buffer, "Unknown tool: {s}… (name continues; Rui content digest {s}).", .{ prefix[0..prefix_length], &digest_hex });
        },
    }
}

/// Admission policy over adapter-certified descriptor facts and frozen tools.
/// Call this under the transaction that publishes the proposal and Action.
pub fn classifyCall(name: CallName, valid_arguments: bool, frozen: ToolSet) ?protocol.ProposalRejection {
    return switch (name) {
        .bash => if (!frozen.contains(.bash)) .unknown_tool else if (!valid_arguments) .invalid_arguments else null,
        .unknown => .unknown_tool,
    };
}

test "tool classification uses frozen availability before argument validity" {
    const none: ToolSet = .empty;
    const bash_only = ToolSet.initOne(.bash);
    try std.testing.expectEqual(protocol.ProposalRejection.unknown_tool, classifyCall(.bash, false, none).?);
    try std.testing.expectEqual(protocol.ProposalRejection.unknown_tool, classifyCall(.bash, true, none).?);
    try std.testing.expectEqual(protocol.ProposalRejection.invalid_arguments, classifyCall(.bash, false, bash_only).?);
    try std.testing.expect(classifyCall(.bash, true, bash_only) == null);
    try std.testing.expectEqual(protocol.ProposalRejection.unknown_tool, classifyCall(.unknown, true, .full).?);
}

pub fn validBashArguments(source: anytype) !bool {
    var discard: Discard = .{};
    return try parseBashArguments(source, &discard, &discard) != null;
}

pub fn inspectBashArguments(source: anytype) !?BashArguments {
    var discard: Discard = .{};
    return parseBashArguments(source, &discard, &discard);
}

pub fn writeBashCommand(source: anytype, writer: anytype) !bool {
    var discard: Discard = .{};
    return try parseBashArguments(source, writer, &discard) != null;
}

pub fn writeBashStdin(source: anytype, writer: anytype) !bool {
    var discard: Discard = .{};
    return try parseBashArguments(source, &discard, writer) != null;
}

fn parseBashArguments(source: anytype, writer: anytype, input: anytype) !?BashArguments {
    var parser: BashParser = .{};
    while (true) {
        const progress = parser.advance(source, writer, input, 4096) catch |err| {
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
    const StringTarget = enum { key, command, description, stdin };
    const ValueTarget = enum { none, command, timeout, description, stdin };

    phase: Phase = .object_start,
    string_target: StringTarget = .key,
    value_target: ValueTarget = .none,
    key: protocol.Bounded(16) = .{},
    result: BashArguments = .{},
    has_command: bool = false,
    has_timeout: bool = false,
    has_description: bool = false,
    has_stdin: bool = false,
    timeout_value: u64 = 0,
    null_index: u3 = 0,
    unicode_value: u21 = 0,
    unicode_digits: u3 = 0,
    high_surrogate: u21 = 0,
    stdin_utf8: protocol.Utf8State = .{},

    pub fn advance(self: *BashParser, source: anytype, writer: anytype, input: anytype, maximum_bytes: usize) !BashParseProgress {
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
                                else if (self.key.eql("stdin"))
                                    .stdin
                                else
                                    return .invalid;
                                self.phase = .colon;
                            },
                            .command => {
                                self.has_command = true;
                                self.phase = .after_value;
                            },
                            .stdin => {
                                if (!self.stdin_utf8.complete()) return .invalid;
                                self.has_stdin = true;
                                self.result.stdin_present = true;
                                self.phase = .after_value;
                            },
                            .description => {
                                if (!protocol.ToolPresentation.validDescription(self.result.description.slice())) return .invalid;
                                self.has_description = true;
                                self.phase = .after_value;
                            },
                        }
                    } else if (next < 0x20) {
                        return .invalid;
                    } else if (next == '\\') {
                        self.phase = .escape;
                    } else {
                        try self.emitString(writer, input, &.{next});
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
                        try self.emitString(writer, input, &.{byte});
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
                            if (!(try self.emitScalar(writer, input, self.unicode_value))) return .invalid;
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
                        if (!(try self.emitScalar(writer, input, scalar))) return .invalid;
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
                        .stdin => {
                            if (self.has_stdin) return .invalid;
                            if (next == '"') {
                                self.string_target = .stdin;
                                self.phase = .string;
                            } else if (next == 'n') {
                                self.null_index = 1;
                                self.phase = .timeout_null;
                            } else return .invalid;
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
                        if (self.value_target == .stdin) {
                            self.has_stdin = true;
                        } else {
                            self.result.timeout_ms = null;
                            self.has_timeout = true;
                        }
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

    fn emitString(self: *BashParser, writer: anytype, input: anytype, bytes: []const u8) !void {
        switch (self.string_target) {
            .key => try emit(&self.key, null, bytes),
            .command => try emit(null, writer, bytes),
            .stdin => {
                try self.stdin_utf8.feed(bytes);
                try input.writeAll(bytes);
            },
            .description => {
                const label = &self.result.description;
                if (bytes.len > label.bytes.len - label.len) return error.InvalidDescriptorShape;
                @memcpy(label.bytes[label.len..][0..bytes.len], bytes);
                label.len += bytes.len;
            },
        }
    }

    fn emitScalar(self: *BashParser, writer: anytype, input: anytype, scalar: u21) !bool {
        if (scalar == 0 and self.string_target != .stdin) return false;
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(scalar, &encoded) catch return false;
        try self.emitString(writer, input, encoded[0..count]);
        return true;
    }
};

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
        error.InvalidDescriptorShape, error.InvalidUtf8 => true,
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
    var input: TestWriter = .{};
    var parser: BashParser = .{};
    while (true) switch (try parser.advance(&source, &writer, &input, 1)) {
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
        "{\"description\":\"Run command\",\"cmd\":\"ok\",\"timeout_ms\":null,\"stdin\":null,\"stdin\":\"again\"}",
        "{\"description\":\"Run command\",\"cmd\":\"ok\",\"timeout_ms\":null,\"stdin\":42}",
    };
    for (descriptors) |descriptor| {
        var source = TestSource{ .bytes = descriptor };
        var writer: TestWriter = .{};
        var input: TestWriter = .{};
        var parser: BashParser = .{};
        while (true) switch (try parser.advance(&source, &writer, &input, 1)) {
            .pending => {},
            .invalid => break,
            .complete => return error.TestUnexpectedValidDescriptor,
        };
    }
}

test "Bash stdin stays distinct from command across every decoded byte" {
    const cases = [_]struct { field: []const u8, present: bool, expected: []const u8 }{
        .{ .field = "", .present = false, .expected = "" },
        .{ .field = ",\"stdin\":null", .present = false, .expected = "" },
        .{ .field = ",\"stdin\":\"\"", .present = true, .expected = "" },
        .{ .field = ",\"stdin\":\"`x` $(y) 'z' \\\"q\\\"\\n\\u0000\\u20ac\\ud83d\\ude00\"", .present = true, .expected = "`x` $(y) 'z' \"q\"\n\x00€😀" },
    };
    var buffer: [512]u8 = undefined;
    for (cases) |case| {
        var source: TestSource = .{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"description\":\"Read input\",\"cmd\":\"cat\",\"timeout_ms\":null{s}}}", .{case.field}) };
        var command: TestWriter = .{};
        var input: TestWriter = .{};
        var parser: BashParser = .{};
        while (true) switch (try parser.advance(&source, &command, &input, 1)) {
            .pending => {},
            .invalid => return error.TestUnexpectedInvalidDescriptor,
            .complete => |arguments| {
                try std.testing.expectEqualStrings("cat", command.slice());
                try std.testing.expectEqual(case.present, arguments.stdin_present);
                try std.testing.expectEqualStrings(case.expected, input.slice());
                break;
            },
        };
    }
}

test "Bash stdin rejects invalid UTF-8 without coercion" {
    for ([_][]const u8{ "\xff", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82", "\x80", "\\ud800" }) |invalid| {
        var buffer: [256]u8 = undefined;
        var source = TestSource{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"description\":\"Read input\",\"cmd\":\"cat\",\"stdin\":\"{s}\",\"timeout_ms\":null}}", .{invalid}) };
        try std.testing.expect(!try validBashArguments(&source));
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
