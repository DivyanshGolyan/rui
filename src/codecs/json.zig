//! A JSON reader a codec feeds one window at a time. It checks a document
//! against RFC 8259 byte by byte, holding only its open containers and the
//! token it is in, so a body of any size reads in the same few hundred
//! bytes. A handler hears where each key and value begins and ends; a
//! string's decoded start stays in the reader for comparing with names and
//! codes, and its range names the rest. A document is one object;
//! whitespace is space, tab, CR and LF.
const std = @import("std");

/// The deepest value a document may hold: the top object's members are at
/// depth 1.
pub const max_depth = 64;

/// How much of a string's decoded start the reader keeps.
pub const max_text_bytes = 64;

pub const Kind = enum { object, array, string, number, literal };

pub const Range = struct { start: u64, length: u64 };

pub const Error = error{InvalidJson};

/// Calls, on a handler `h` passed to `feed`:
///   h.key(reader, depth): a key of the object whose members are at `depth`;
///   h.begin(reader, kind, depth), h.end(reader, kind, depth): a value at
///   `depth` begins or ends.
/// In `key` and in `end` of a string, `text` and `string` describe it; in
/// `end` of a number, `integer`.
pub const Reader = struct {
    /// The offset in the document of the byte being read.
    offset: u64,
    state: State,
    /// How many containers are open.
    depth: u8,
    /// Bit `i` is set when open container `i` is an array.
    arrays: std.bit_set.IntegerBitSet(max_depth + 1),
    in_key: bool,
    string_start: u64,
    decoded: u64,
    /// The first `max_text_bytes` decoded bytes of the current string.
    text_bytes: [max_text_bytes]u8 = undefined,
    /// A UTF-8 sequence in progress.
    sequence: [4]u8 = undefined,
    sequence_length: u3,
    sequence_expected: u3,
    /// A `\u` escape in progress, and the high surrogate before it, if any.
    hex: u21,
    hex_digits: u3,
    high: u21,
    /// Where the rest of the literal being read starts in `literal_tails`.
    literal: u4,
    /// The number being read, while it is a plain nonnegative integer that
    /// fits.
    integer: ?u64,

    /// Each literal after its first byte, ended by a 0.
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
        escape,
        unicode,
        surrogate_backslash,
        surrogate_u,
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

    /// The state before a document's first byte. The decoded text and the
    /// UTF-8 sequence are written before they are read, so they are left.
    pub fn init(self: *Reader) void {
        self.* = .{
            .offset = 0,
            .state = .document,
            .depth = 0,
            .arrays = .empty,
            .in_key = false,
            .string_start = 0,
            .decoded = 0,
            .sequence_length = 0,
            .sequence_expected = 0,
            .hex = 0,
            .hex_digits = 0,
            .high = 0,
            .literal = 0,
            .integer = null,
        };
    }

    pub fn feed(self: *Reader, bytes: []const u8, handler: anytype) Error!void {
        for (bytes) |byte| {
            try self.step(byte, handler);
            self.offset += 1;
        }
    }

    /// Whether the bytes fed so far are one whole document.
    pub fn complete(self: *const Reader) bool {
        return self.state == .done;
    }

    /// The decoded string, when no longer than `max_text_bytes`.
    pub fn text(self: *const Reader) ?[]const u8 {
        return if (self.decoded <= max_text_bytes) self.text_bytes[0..@intCast(self.decoded)] else null;
    }

    /// The contents of the string just read, without its quotes.
    pub fn string(self: *const Reader) Range {
        return .{ .start = self.string_start, .length = self.offset - self.string_start };
    }

    fn step(self: *Reader, byte: u8, handler: anytype) Error!void {
        switch (self.state) {
            .document => if (!space(byte)) {
                if (byte != '{') return error.InvalidJson;
                handler.begin(self, .object, 0);
                self.open(false);
            },
            .key_or_close => if (!space(byte)) switch (byte) {
                '"' => self.startString(true),
                '}' => self.close(handler, false),
                else => return error.InvalidJson,
            },
            .key => if (!space(byte)) {
                if (byte != '"') return error.InvalidJson;
                self.startString(true);
            },
            .colon => if (!space(byte)) {
                if (byte != ':') return error.InvalidJson;
                self.state = .value;
            },
            .value => if (!space(byte)) try self.beginValue(byte, handler),
            .value_or_close => if (!space(byte)) {
                if (byte == ']') return self.close(handler, true);
                try self.beginValue(byte, handler);
            },
            .after_value => try self.afterValue(byte, handler),
            .string => try self.stringByte(byte, handler),
            .escape => {
                self.state = .string;
                switch (byte) {
                    '"', '\\', '/' => self.emit(&.{byte}),
                    'b' => self.emit("\x08"),
                    'f' => self.emit("\x0c"),
                    'n' => self.emit("\n"),
                    'r' => self.emit("\r"),
                    't' => self.emit("\t"),
                    'u' => {
                        self.hex = 0;
                        self.hex_digits = 0;
                        self.state = .unicode;
                    },
                    else => return error.InvalidJson,
                }
            },
            .unicode => {
                const digit = std.fmt.charToDigit(byte, 16) catch return error.InvalidJson;
                self.hex = self.hex * 16 + digit;
                self.hex_digits += 1;
                if (self.hex_digits == 4) try self.escaped();
            },
            .surrogate_backslash => self.state = if (byte == '\\') .surrogate_u else return error.InvalidJson,
            .surrogate_u => {
                if (byte != 'u') return error.InvalidJson;
                self.hex = 0;
                self.hex_digits = 0;
                self.state = .unicode;
            },
            .minus => self.state = switch (byte) {
                '0' => .zero,
                '1'...'9' => .integer_digits,
                else => return error.InvalidJson,
            },
            .zero => switch (byte) {
                '0'...'9' => return error.InvalidJson,
                else => try self.numberTail(byte, handler),
            },
            .integer_digits => switch (byte) {
                '0'...'9' => if (self.integer) |value| {
                    const tens = std.math.mul(u64, value, 10) catch {
                        self.integer = null;
                        return;
                    };
                    self.integer = std.math.add(u64, tens, byte - '0') catch null;
                },
                else => try self.numberTail(byte, handler),
            },
            .fraction_start => self.state = if (std.ascii.isDigit(byte)) .fraction else return error.InvalidJson,
            .fraction => switch (byte) {
                '0'...'9' => {},
                'e', 'E' => self.state = .exponent_start,
                else => try self.endNumber(byte, handler),
            },
            .exponent_start => self.state = switch (byte) {
                '+', '-' => .exponent_sign,
                '0'...'9' => .exponent,
                else => return error.InvalidJson,
            },
            .exponent_sign => self.state = if (std.ascii.isDigit(byte)) .exponent else return error.InvalidJson,
            .exponent => if (!std.ascii.isDigit(byte)) try self.endNumber(byte, handler),
            .literal => {
                if (byte != literal_tails[self.literal]) return error.InvalidJson;
                self.literal += 1;
                if (literal_tails[self.literal] == 0) self.endValue(.literal, handler);
            },
            .done => if (!space(byte)) return error.InvalidJson,
        }
    }

    fn beginValue(self: *Reader, byte: u8, handler: anytype) Error!void {
        if (self.depth > max_depth) return error.InvalidJson;
        const kind: Kind = switch (byte) {
            '{' => .object,
            '[' => .array,
            '"' => .string,
            '-', '0'...'9' => .number,
            't', 'f', 'n' => .literal,
            else => return error.InvalidJson,
        };
        handler.begin(self, kind, self.depth);
        switch (byte) {
            '{' => self.open(false),
            '[' => self.open(true),
            '"' => self.startString(false),
            '-' => {
                self.integer = null;
                self.state = .minus;
            },
            '0'...'9' => {
                self.integer = byte - '0';
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
            '}' => if (array) return error.InvalidJson else self.close(handler, false),
            ']' => if (array) self.close(handler, true) else return error.InvalidJson,
            else => return error.InvalidJson,
        }
    }

    /// A byte that is not a digit after an integer part: a fraction, an
    /// exponent, or the end of the number.
    fn numberTail(self: *Reader, byte: u8, handler: anytype) Error!void {
        switch (byte) {
            '.' => {
                self.integer = null;
                self.state = .fraction_start;
            },
            'e', 'E' => {
                self.integer = null;
                self.state = .exponent_start;
            },
            else => try self.endNumber(byte, handler),
        }
    }

    /// The number ended just before `byte`, which follows it.
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

    fn stringByte(self: *Reader, byte: u8, handler: anytype) Error!void {
        if (self.sequence_length != 0) {
            // Inside a UTF-8 sequence; std's decoder judges it once whole.
            if (byte == '"' or byte == '\\' or byte < 0x20) return error.InvalidJson;
            self.sequence[self.sequence_length] = byte;
            self.sequence_length += 1;
            if (self.sequence_length == self.sequence_expected) {
                const sequence = self.sequence[0..self.sequence_expected];
                _ = std.unicode.utf8Decode(sequence) catch return error.InvalidJson;
                self.emit(sequence);
                self.sequence_length = 0;
            }
            return;
        }
        switch (byte) {
            '"' => if (self.in_key) {
                handler.key(self, self.depth);
                self.state = .colon;
            } else self.endValue(.string, handler),
            '\\' => self.state = .escape,
            0...0x1f => return error.InvalidJson,
            0x80...0xff => {
                self.sequence_expected = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidJson;
                self.sequence[0] = byte;
                self.sequence_length = 1;
            },
            else => self.emit(&.{byte}),
        }
    }

    /// Four hex digits of a `\u` escape are read.
    fn escaped(self: *Reader) Error!void {
        const value = self.hex;
        if (self.high != 0) {
            if (value < 0xdc00 or value > 0xdfff) return error.InvalidJson;
            const scalar = 0x10000 + ((self.high - 0xd800) << 10) + (value - 0xdc00);
            self.high = 0;
            self.emitScalar(scalar);
        } else switch (value) {
            0xd800...0xdbff => {
                self.high = value;
                self.state = .surrogate_backslash;
                return;
            },
            0xdc00...0xdfff => return error.InvalidJson,
            else => self.emitScalar(value),
        }
        self.state = .string;
    }

    fn emitScalar(self: *Reader, scalar: u21) void {
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(scalar, &encoded) catch unreachable;
        self.emit(encoded[0..count]);
    }

    fn emit(self: *Reader, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.decoded < max_text_bytes) self.text_bytes[@intCast(self.decoded)] = byte;
            self.decoded += 1;
        }
    }
};

fn space(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

/// Records what a reader reports, for comparing one way of feeding a
/// document with another.
const Recorder = struct {
    events: std.ArrayList(u8) = .empty,

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
        self.events.print(std.testing.allocator, format, args) catch @panic("out of test memory");
    }
};

fn readForTesting(document: []const u8, window: usize, recorder: *Recorder) bool {
    var reader: Reader = undefined;
    reader.init();
    var offset: usize = 0;
    while (offset < document.len) {
        const end = @min(document.len, offset + window);
        reader.feed(document[offset..end], recorder) catch return false;
        offset = end;
    }
    return reader.complete();
}

fn repeat(comptime text: []const u8, comptime count: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..count) |_| out = out ++ text;
    return out;
}

test "the reader accepts exactly the objects std.json accepts, however the document is cut" {
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
    // Every spelling of up to five number bytes, as a member and in an
    // array.
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

/// The reader accepts `document` exactly when std.json does, and reports the
/// same events however the document is cut.
fn expectReadAsStd(document: []const u8) !void {
    const expected = document.len != 0 and std.mem.trimStart(u8, document, " \t\r\n")[0] == '{' and
        try std.json.validate(std.testing.allocator, document);
    var whole: Recorder = .{};
    defer whole.events.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, readForTesting(document, document.len + 1, &whole));
    for ([_]usize{ 1, 2, 3, 7 }) |window| {
        var cut: Recorder = .{};
        defer cut.events.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected, readForTesting(document, window, &cut));
        try std.testing.expectEqualStrings(whole.events.items, cut.events.items);
    }
}

test "the reader reports keys and values with their depths, ranges and decoded starts" {
    var recorder: Recorder = .{};
    defer recorder.events.deinit(std.testing.allocator);
    try std.testing.expect(readForTesting("{\"co\\u0064e\":\"x\\n\",\"n\":[7,1.5,-1],\"t\":true}", 5, &recorder));
    try std.testing.expectEqualStrings(
        "O0 k1[2,9]code S1 s1[14,3]x\n k1[20,1]n A1 N2 n2=7 N2 n2=null N2 n2=null a1 k1[35,1]t L1 l1 o0 ",
        recorder.events.items,
    );
    // A string past the kept start keeps its range; its text is unknown.
    const long = comptime "{\"" ++ repeat("k", max_text_bytes + 1) ++ "\":\"" ++ repeat("v", max_text_bytes) ++ "\"}";
    recorder.events.clearRetainingCapacity();
    try std.testing.expect(readForTesting(long, 3, &recorder));
    try std.testing.expectEqualStrings(
        "O0 k1[2,65]null S1 s1[70,64]" ++ comptime repeat("v", max_text_bytes) ++ " o0 ",
        recorder.events.items,
    );
}

test "a value nests at most max_depth deep" {
    var buffer: [2 * max_depth + 8]u8 = undefined;
    for ([_]usize{ max_depth - 1, max_depth }) |arrays| {
        // The top object's member is at depth 1 and each array adds one.
        var writer: std.Io.Writer = .fixed(&buffer);
        try writer.writeAll("{\"a\":");
        for (0..arrays) |_| try writer.writeByte('[');
        try writer.writeByte('1');
        for (0..arrays) |_| try writer.writeByte(']');
        try writer.writeByte('}');
        var recorder: Recorder = .{};
        defer recorder.events.deinit(std.testing.allocator);
        try std.testing.expectEqual(arrays + 1 <= max_depth, readForTesting(writer.buffered(), 4096, &recorder));
    }
}
