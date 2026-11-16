const std = @import("std");
const codec_abi = @import("../codec_abi.zig");

const Range = codec_abi.Range;

pub const max_depth = 64;

pub const max_text_bytes = 64;

pub const Kind = enum { object, array, string, number, literal };

pub const Error = error{
    UnexpectedJsonEnd,
    TrailingJson,
    UnexpectedJsonDelimiter,
    ExpectedJsonString,
    JsonTooDeep,
    InvalidJsonValue,
    InvalidJsonNumber,
    InvalidJsonLiteral,
    InvalidJsonString,
    InvalidJsonEscape,
    InvalidJsonSurrogate,
    InvalidJsonUtf8,
};

pub const Digits = enum { plain, negative, overflow, fractional };

pub const Literal = enum { true_value, false_value, null_value };

pub fn decodeString(bytes: []const u8, start: usize, sink: anytype) Error!usize {
    var at = start;
    while (at < bytes.len) {
        const plain = plainLength(bytes[at..]);
        if (plain != 0) {
            sink.append(bytes[at..][0..plain], null);
            at += plain;
            continue;
        }
        at = switch (bytes[at]) {
            '"' => return at,
            0...0x1f => return error.InvalidJsonString,
            '\\' => try escape(bytes, at + 1, sink),
            else => try sequence(bytes, at, sink),
        };
    }
    return at;
}

fn escape(bytes: []const u8, at: usize, sink: anytype) Error!usize {
    if (at == bytes.len) return error.UnexpectedJsonEnd;
    const value: u8 = switch (bytes[at]) {
        '"', '\\', '/' => bytes[at],
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => return unicodeEscape(bytes, at + 1, sink),
        else => return error.InvalidJsonEscape,
    };
    sink.append(&.{value}, value);
    return at + 1;
}

fn unicodeEscape(bytes: []const u8, at: usize, sink: anytype) Error!usize {
    const value = try hex(bytes, at);
    var end = at + 4;
    const scalar = switch (value) {
        0xdc00...0xdfff => return error.InvalidJsonSurrogate,
        0xd800...0xdbff => pair: {
            for ("\\u", 0..) |expected, index| {
                if (end + index == bytes.len) return error.UnexpectedJsonEnd;
                if (bytes[end + index] != expected) return error.InvalidJsonSurrogate;
            }
            const low = try hex(bytes, end + 2);
            if (low < 0xdc00 or low > 0xdfff) return error.InvalidJsonSurrogate;
            end += 6;
            break :pair 0x10000 + ((value - 0xd800) << 10) + (low - 0xdc00);
        },
        else => value,
    };
    var encoded: [4]u8 = undefined;
    const count = std.unicode.utf8Encode(scalar, &encoded) catch unreachable;
    sink.append(encoded[0..count], scalar);
    return end;
}

fn hex(bytes: []const u8, at: usize) Error!u21 {
    var value: u21 = 0;
    for (at..at + 4) |index| {
        if (index == bytes.len) return error.UnexpectedJsonEnd;
        value = value * 16 + (std.fmt.charToDigit(bytes[index], 16) catch return error.InvalidJsonEscape);
    }
    return value;
}

fn sequence(bytes: []const u8, at: usize, sink: anytype) Error!usize {
    const length = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return error.InvalidJsonUtf8;
    for (at + 1..at + length) |index| {
        if (index == bytes.len) return error.UnexpectedJsonEnd;
        switch (bytes[index]) {
            0...0x1f => return error.InvalidJsonString,
            '"', '\\' => return error.InvalidJsonUtf8,
            else => {},
        }
    }
    const encoded = bytes[at..][0..length];
    sink.append(encoded, std.unicode.utf8Decode(encoded) catch return error.InvalidJsonUtf8);
    return at + length;
}

fn plainLength(bytes: []const u8) usize {
    return for (bytes, 0..) |byte, count| {
        if (byte == '"' or byte == '\\' or byte < 0x20 or byte >= 0x80) break count;
    } else bytes.len;
}

pub const Reader = struct {
    offset: u64,
    state: State,
    depth: u8,
    arrays: std.bit_set.IntegerBitSet(max_depth + 1),
    in_key: bool,
    string_start: u64,
    decoded: u64,
    text_bytes: [max_text_bytes]u8 = undefined,
    literal: u4,
    integer: ?u64,
    digits: Digits,

    const literal_tails = "rue\x00alse\x00ull\x00";

    const State = enum {
        document,
        key_or_close,
        key,
        colon,
        value,
        value_or_close,
        after_value,
        string,
        minus,
        zero,
        integer_digits,
        fraction_start,
        fraction,
        exponent_start,
        exponent_sign,
        exponent,
        literal,
        done,
    };

    pub fn read(self: *Reader, bytes: []const u8, handler: anytype) Error!void {
        self.init();
        while (self.offset < bytes.len) : (self.offset += 1) {
            if (self.state != .string) {
                try self.step(bytes[@intCast(self.offset)], handler);
                continue;
            }
            self.offset = try decodeString(bytes, @intCast(self.offset), self);
            if (self.offset == bytes.len) break;
            if (self.in_key) {
                handler.key(self, self.depth);
                self.state = .colon;
            } else self.endValue(.string, handler);
        }
        if (self.state == .done) return;
        const value_due = self.state == .value or self.state == .value_or_close;
        return if (value_due and self.depth > max_depth) error.JsonTooDeep else error.UnexpectedJsonEnd;
    }

    pub fn readSource(self: *Reader, source: anytype, handler: anytype) !void {
        self.init();
        while (try source.peek()) |byte| {
            _ = try source.take();
            if (self.state != .string) {
                try self.step(byte, handler);
                self.offset += 1;
                continue;
            }
            if (byte == '"') {
                if (self.in_key) {
                    handler.key(self, self.depth);
                    self.state = .colon;
                } else self.endValue(.string, handler);
                self.offset += 1;
                continue;
            }
            var scalar: [12]u8 = undefined;
            scalar[0] = byte;
            var length: usize = 1;
            var needed: usize = if (byte == '\\') 2 else if (byte >= 0x80)
                std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidJsonUtf8
            else
                1;
            while (length < needed) {
                scalar[length] = (try source.peek()) orelse {
                    _ = try decodeString(scalar[0..length], 0, self);
                    return error.UnexpectedJsonEnd;
                };
                _ = try source.take();
                length += 1;
                if (length == 2 and byte == '\\' and scalar[1] == 'u') needed = 6;
                if (length == 6 and needed == 6) {
                    const value = try hex(scalar[0..length], 2);
                    if (value >= 0xd800 and value <= 0xdbff) needed = 12;
                }
            }
            _ = try decodeString(scalar[0..length], 0, self);
            self.offset += length;
        }
        if (self.state != .done) return error.UnexpectedJsonEnd;
    }

    fn init(self: *Reader) void {
        self.* = .{
            .offset = 0,
            .state = .document,
            .depth = 0,
            .arrays = .empty,
            .in_key = false,
            .string_start = 0,
            .decoded = 0,
            .literal = 0,
            .integer = null,
            .digits = .plain,
        };
    }

    pub fn text(self: *const Reader) ?[]const u8 {
        return if (self.decoded <= max_text_bytes) self.text_bytes[0..@intCast(self.decoded)] else null;
    }

    pub fn literalValue(self: *const Reader) Literal {
        return switch (self.literal) {
            3 => .true_value,
            8 => .false_value,
            12 => .null_value,
            else => unreachable,
        };
    }

    pub fn string(self: *const Reader) Range {
        return .{ .start = self.string_start, .length = self.offset - self.string_start };
    }

    fn step(self: *Reader, byte: u8, handler: anytype) Error!void {
        switch (self.state) {
            .document => if (!space(byte)) {
                if (byte != '{') return error.UnexpectedJsonDelimiter;
                handler.begin(self, .object, 0);
                self.open(false);
            },
            .key_or_close => if (!space(byte)) switch (byte) {
                '"' => self.startString(true),
                '}' => self.close(handler, false),
                else => return error.ExpectedJsonString,
            },
            .key => if (!space(byte)) {
                if (byte != '"') return error.ExpectedJsonString;
                self.startString(true);
            },
            .colon => if (!space(byte)) {
                if (byte != ':') return error.UnexpectedJsonDelimiter;
                self.state = .value;
            },
            .value => if (!space(byte)) try self.beginValue(byte, handler),
            .value_or_close => if (!space(byte)) {
                if (byte == ']') return self.close(handler, true);
                try self.beginValue(byte, handler);
            },
            .after_value => try self.afterValue(byte, handler),
            .string => unreachable,
            .minus => self.state = switch (byte) {
                '0' => .zero,
                '1'...'9' => .integer_digits,
                else => return error.InvalidJsonNumber,
            },
            .zero => switch (byte) {
                '0'...'9' => return error.InvalidJsonNumber,
                else => try self.numberTail(byte, handler),
            },
            .integer_digits => switch (byte) {
                '0'...'9' => if (self.integer) |value| {
                    const tens = std.math.mul(u64, value, 10) catch return self.overflow();
                    self.integer = std.math.add(u64, tens, byte - '0') catch return self.overflow();
                },
                else => try self.numberTail(byte, handler),
            },
            .fraction_start => self.state = if (std.ascii.isDigit(byte)) .fraction else return error.InvalidJsonNumber,
            .fraction => switch (byte) {
                '0'...'9' => {},
                'e', 'E' => self.state = .exponent_start,
                else => try self.endNumber(byte, handler),
            },
            .exponent_start => self.state = switch (byte) {
                '+', '-' => .exponent_sign,
                '0'...'9' => .exponent,
                else => return error.InvalidJsonNumber,
            },
            .exponent_sign => self.state = if (std.ascii.isDigit(byte)) .exponent else return error.InvalidJsonNumber,
            .exponent => if (!std.ascii.isDigit(byte)) try self.endNumber(byte, handler),
            .literal => {
                if (byte != literal_tails[self.literal]) return error.InvalidJsonLiteral;
                self.literal += 1;
                if (literal_tails[self.literal] == 0) self.endValue(.literal, handler);
            },
            .done => if (!space(byte)) return error.TrailingJson,
        }
    }

    fn beginValue(self: *Reader, byte: u8, handler: anytype) Error!void {
        if (self.depth > max_depth) return error.JsonTooDeep;
        const kind: Kind = switch (byte) {
            '{' => .object,
            '[' => .array,
            '"' => .string,
            '-', '0'...'9' => .number,
            't', 'f', 'n' => .literal,
            else => return error.InvalidJsonValue,
        };
        handler.begin(self, kind, self.depth);
        switch (byte) {
            '{' => self.open(false),
            '[' => self.open(true),
            '"' => self.startString(false),
            '-' => {
                self.integer = null;
                self.digits = .negative;
                self.state = .minus;
            },
            '0'...'9' => {
                self.integer = byte - '0';
                self.digits = .plain;
                self.state = if (byte == '0') .zero else .integer_digits;
            },
            't' => self.startLiteral("rue"),
            'f' => self.startLiteral("alse"),
            'n' => self.startLiteral("ull"),
            else => unreachable,
        }
    }

    fn open(self: *Reader, array: bool) void {
        self.arrays.setValue(self.depth, array);
        self.depth += 1;
        self.state = if (array) .value_or_close else .key_or_close;
    }

    fn close(self: *Reader, handler: anytype, array: bool) void {
        self.depth -= 1;
        handler.end(self, if (array) .array else .object, self.depth);
        self.state = if (self.depth == 0) .done else .after_value;
    }

    fn endValue(self: *Reader, kind: Kind, handler: anytype) void {
        handler.end(self, kind, self.depth);
        self.state = .after_value;
    }

    fn afterValue(self: *Reader, byte: u8, handler: anytype) Error!void {
        if (space(byte)) return;
        const array = self.arrays.isSet(self.depth - 1);
        switch (byte) {
            ',' => self.state = if (array) .value else .key,
            '}' => if (array) return error.UnexpectedJsonDelimiter else self.close(handler, false),
            ']' => if (array) self.close(handler, true) else return error.UnexpectedJsonDelimiter,
            else => return error.UnexpectedJsonDelimiter,
        }
    }

    fn numberTail(self: *Reader, byte: u8, handler: anytype) Error!void {
        switch (byte) {
            '.' => {
                self.fractional();
                self.state = .fraction_start;
            },
            'e', 'E' => {
                self.fractional();
                self.state = .exponent_start;
            },
            else => try self.endNumber(byte, handler),
        }
    }

    fn fractional(self: *Reader) void {
        self.integer = null;
        if (self.digits == .plain) self.digits = .fractional;
    }

    fn overflow(self: *Reader) void {
        self.integer = null;
        if (self.digits == .plain) self.digits = .overflow;
    }

    fn endNumber(self: *Reader, byte: u8, handler: anytype) Error!void {
        self.endValue(.number, handler);
        try self.afterValue(byte, handler);
    }

    fn startLiteral(self: *Reader, comptime tail: []const u8) void {
        self.literal = comptime std.mem.indexOf(u8, literal_tails, tail ++ "\x00").?;
        self.state = .literal;
    }

    fn startString(self: *Reader, key: bool) void {
        self.in_key = key;
        self.string_start = self.offset + 1;
        self.decoded = 0;
        self.state = .string;
    }

    fn append(self: *Reader, bytes: []const u8, scalar: ?u21) void {
        _ = scalar;
        if (self.decoded < max_text_bytes) {
            const kept = @min(bytes.len, max_text_bytes - @as(usize, @intCast(self.decoded)));
            @memcpy(self.text_bytes[@intCast(self.decoded)..][0..kept], bytes[0..kept]);
        }
        self.decoded += bytes.len;
    }
};

pub const Text = struct {
    bytes: [max_text_bytes]u8 = undefined,
    length: u64,

    pub fn slice(self: *const Text) ?[]const u8 {
        return if (self.length <= max_text_bytes) self.bytes[0..@intCast(self.length)] else null;
    }

    fn append(self: *Text, bytes: []const u8, scalar: ?u21) void {
        _ = scalar;
        if (self.length < max_text_bytes) {
            const kept = @min(bytes.len, max_text_bytes - @as(usize, @intCast(self.length)));
            @memcpy(self.bytes[@intCast(self.length)..][0..kept], bytes[0..kept]);
        }
        self.length += bytes.len;
    }
};

pub fn stringAt(document: []const u8, start: usize) struct { contents: Range, end: usize } {
    std.debug.assert(document[start] == '"');
    var at = start + 1;
    while (true) {
        at = std.mem.indexOfAnyPos(u8, document, at, "\\\"").?;
        if (document[at] == '"') return .{ .contents = .{ .start = start + 1, .length = at - start - 1 }, .end = at + 1 };
        at += 2;
    }
}

pub const Value = struct { end: usize, string: ?Range };

pub fn valueAt(document: []const u8, start: usize) Value {
    if (document[start] != '"') return .{ .end = valueEnd(document, start), .string = null };
    const found = stringAt(document, start);
    return .{ .end = found.end, .string = found.contents };
}

pub fn valueEnd(document: []const u8, start: usize) usize {
    var at = start;
    var depth: usize = 0;
    while (true) {
        switch (document[at]) {
            '"' => at = stringAt(document, at).end,
            '{', '[' => {
                depth += 1;
                at += 1;
            },
            '}', ']' => {
                depth -= 1;
                at += 1;
            },
            else => {
                if (depth != 0) {
                    at += 1;
                    continue;
                }
                while (at < document.len and std.mem.indexOfScalar(u8, ",}] \t\r\n", document[at]) == null) at += 1;
                return at;
            },
        }
        if (depth == 0) return at;
    }
}

pub fn skipSpace(document: []const u8, at: usize) usize {
    var index = at;
    while (space(document[index])) index += 1;
    return index;
}

pub fn decodeContents(contents: []const u8, sink: anytype) void {
    std.debug.assert((decodeString(contents, 0, sink) catch unreachable) == contents.len);
}

pub fn decode(contents: []const u8, out: *Text) void {
    out.length = 0;
    decodeContents(contents, out);
}

pub fn decodedTag(comptime E: type, contents: []const u8) ?E {
    if (std.mem.indexOfScalar(u8, contents, '\\') == null) return std.meta.stringToEnum(E, contents);
    var text: Text = .{ .length = 0 };
    decode(contents, &text);
    return std.meta.stringToEnum(E, text.slice() orelse return null);
}

fn space(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

const Recorder = struct {
    buffer: [4096]u8 = undefined,
    length: usize = 0,

    fn events(self: *const Recorder) []const u8 {
        return self.buffer[0..self.length];
    }

    fn key(self: *Recorder, reader: *const Reader, depth: u8) void {
        self.print("k{d}", .{depth});
        self.string(reader);
        self.print(" ", .{});
    }

    fn begin(self: *Recorder, reader: *const Reader, kind: Kind, depth: u8) void {
        _ = reader;
        self.print("{c}{d} ", .{ "OASNL"[@backingInt(kind)], depth });
    }

    fn end(self: *Recorder, reader: *const Reader, kind: Kind, depth: u8) void {
        self.print("{c}{d}", .{ "oasnl"[@backingInt(kind)], depth });
        if (kind == .string) self.string(reader);
        if (kind == .number) self.print("={?d}", .{reader.integer});
        self.print(" ", .{});
    }

    fn string(self: *Recorder, reader: *const Reader) void {
        const range = reader.string();
        self.print("[{d},{d}]{?s}", .{ range.start, range.length, reader.text() });
    }

    fn print(self: *Recorder, comptime format: []const u8, args: anytype) void {
        self.length += (std.fmt.bufPrint(self.buffer[self.length..], format, args) catch @panic("recorder full")).len;
    }
};

fn readForTesting(document: []const u8, recorder: *Recorder) bool {
    var reader: Reader = undefined;
    reader.read(document, recorder) catch return false;
    return true;
}

fn repeat(comptime text: []const u8, comptime count: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..count) |_| out = out ++ text;
    return out;
}

test "the reader accepts exactly the objects std.json accepts" {
    const documents = [_][]const u8{
        "{}",                                      " \t\r\n{ } \n",                   "{\"a\":1}",
        "{\"a\":[1,-2,3.5e+2,0,true,false,null]}", "{\"a\":{\"b\":{\"c\":[[],{}]}}}", "{\"a\\u0062\":\"\\ud83d\\ude00\\n\\/\"}",
        "{\"é\":\"日本\"}",
        "{\"a\":-0.0E-0}",                         "{\"a\":18446744073709551616}",    "[]",
        "1",                                       "\"a\"",                           "",
        "{",                                       "{\"a\"}",                         "{\"a\":}",
        "{\"a\":1,}",                              "{,}",                             "{\"a\":01}",
        "{\"a\":1.}",                              "{\"a\":.5}",                      "{\"a\":1e}",
        "{\"a\":-}",                               "{\"a\":+1}",                      "{\"a\":tru}",
        "{\"a\":truex}",                           "{\"a\":nul}",                     "{\"a\":\"\x01\"}",
        "{\"a\":\"\\x\"}",                         "{\"a\":\"\\u12\"}",               "{\"a\":\"\\ud800\"}",
        "{\"a\":\"\\ud800\\u0041\"}",              "{\"a\":\"\\udc00\"}",             "{\"a\":\"\xc3\"}",
        "{\"a\":\"\xc0\x80\"}",                    "{\"a\":\"\xed\xa0\x80\"}",        "{\"a\":\"\xf4\x90\x80\x80\"}",
        "{\"a\":\"\xff\"}",                        "{\"a\":\"\xe6\x97\"}",            "{\"a\":1}x",
        "{\"a\":1}{}",                             "{\"a\":[1}",                      "{\"a\":{]}",
        "{1:2}",                                   "{\"a\" 1}",                       "{\"a\":1 \"b\":2}",
        "{\"a\":\"b\"",                            "{\"a\":[1,2",                     "{\"a\":1.2.3}",
        "{\"a\":0.1.2.3}",                         "{\"a\":1.2.3e4}",                 "{\"a\":1e2.3}",
        "{\"a\":1e2e3}",                           "{\"a\":1.5E+2.5}",                "{\"a\":[1.5,2e3,1E+2,-0e-0,0.25]}",
    };
    for (documents) |document| try expectReadAsStd(document);
}

test "the reader accepts exactly the numbers std.json accepts" {
    const alphabet = "01-+.eE";
    var spelling: [5]u8 = undefined;
    var buffer: [16]u8 = undefined;
    for (1..spelling.len + 1) |length| {
        for (0..std.math.pow(usize, alphabet.len, length)) |index| {
            var rest = index;
            for (spelling[0..length]) |*byte| {
                byte.* = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            for ([_][2][]const u8{ .{ "{\"a\":", "}" }, .{ "{\"a\":[", ",1]}" } }) |wrapper| {
                try expectReadAsStd(try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ wrapper[0], spelling[0..length], wrapper[1] }));
            }
        }
    }
}

fn expectReadAsStd(document: []const u8) !void {
    const expected = document.len != 0 and std.mem.trimStart(u8, document, " \t\r\n")[0] == '{' and
        try std.json.validate(std.testing.allocator, document);
    var recorder: Recorder = .{};
    try std.testing.expectEqual(expected, readForTesting(document, &recorder));
    const Source = struct {
        bytes: []const u8,
        position: usize = 0,
        pub fn peek(self: *@This()) !?u8 {
            return if (self.position < self.bytes.len) self.bytes[self.position] else null;
        }
        pub fn take(self: *@This()) !u8 {
            defer self.position += 1;
            return self.bytes[self.position];
        }
    };
    var source: Source = .{ .bytes = document };
    var reader: Reader = undefined;
    var streamed: Recorder = .{};
    const accepted = if (reader.readSource(&source, &streamed)) |_| true else |_| false;
    try std.testing.expectEqual(expected, accepted);
    if (accepted) try std.testing.expectEqualStrings(recorder.events(), streamed.events());
}

test "both readers fail a document that ends inside an escape for its first invalid byte" {
    for ([_]struct { []const u8, Error }{
        .{ "{\"a\":\"\\ud83d\\ude\x92", error.InvalidJsonEscape },
        .{ "{\"a\":\"\\ud83dx", error.InvalidJsonSurrogate },
        .{ "{\"a\":\"\\ud83d\\ud8", error.UnexpectedJsonEnd },
    }) |case| {
        var reader: Reader = undefined;
        var recorder: Recorder = .{};
        try std.testing.expectError(case[1], reader.read(case[0], &recorder));
        var source: struct {
            bytes: []const u8,
            at: usize = 0,
            pub fn peek(self: *@This()) !?u8 {
                return if (self.at < self.bytes.len) self.bytes[self.at] else null;
            }
            pub fn take(self: *@This()) !u8 {
                defer self.at += 1;
                return self.bytes[self.at];
            }
        } = .{ .bytes = case[0] };
        try std.testing.expectError(case[1], reader.readSource(&source, &recorder));
    }
}

test "the reader reports keys and values with their depths, ranges and decoded starts" {
    var recorder: Recorder = .{};
    try std.testing.expect(readForTesting("{\"co\\u0064e\":\"x\\n\",\"n\":[7,1.5,-1],\"t\":true}", &recorder));
    try std.testing.expectEqualStrings(
        "O0 k1[2,9]code S1 s1[14,3]x\n k1[20,1]n A1 N2 n2=7 N2 n2=null N2 n2=null a1 k1[35,1]t L1 l1 o0 ",
        recorder.events(),
    );
    const long = comptime "{\"" ++ repeat("k", max_text_bytes + 1) ++ "\":\"" ++ repeat("v", max_text_bytes) ++ "\"}";
    recorder.length = 0;
    try std.testing.expect(readForTesting(long, &recorder));
    try std.testing.expectEqualStrings(
        "O0 k1[2,65]null S1 s1[70,64]" ++ comptime repeat("v", max_text_bytes) ++ " o0 ",
        recorder.events(),
    );
}

test "a value nests at most max_depth deep" {
    var buffer: [2 * max_depth + 8]u8 = undefined;
    for ([_]usize{ max_depth - 1, max_depth }) |arrays| {
        var writer: std.Io.Writer = .fixed(&buffer);
        try writer.writeAll("{\"a\":");
        for (0..arrays) |_| try writer.writeByte('[');
        try writer.writeByte('1');
        for (0..arrays) |_| try writer.writeByte(']');
        try writer.writeByte('}');
        var recorder: Recorder = .{};
        try std.testing.expectEqual(arrays + 1 <= max_depth, readForTesting(writer.buffered(), &recorder));
    }
}
