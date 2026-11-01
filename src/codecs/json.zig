//! A JSON reader a codec runs over a whole document. It checks the document
//! against RFC 8259 byte by byte, taking each string's contents at once and
//! holding only its open containers and the token it is in, so a body of
//! any size reads in the same few hundred bytes. A handler hears where each
//! key and value begins and ends; a string's decoded start stays in the
//! reader for comparing with names and codes, and its range names the rest.
//! A document is one object; whitespace is space, tab, CR and LF.
const std = @import("std");
const codec_abi = @import("../codec_abi.zig");

const Range = codec_abi.Range;

/// The deepest value a document may hold: the top object's members are at
/// depth 1.
pub const max_depth = 64;

/// How much of a string's decoded start the reader keeps.
pub const max_text_bytes = 64;

pub const Kind = enum { object, array, string, number, literal };

/// Why bytes are not one JSON object, named as the Host's validation of
/// provider output has always named it, so a rejection's saved detail does
/// not depend on which reader found it.
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

/// How a number differs from a plain nonnegative integer that fits a u64,
/// as a reader of its digits meets it: a sign first, then too many digits,
/// then a fraction or exponent.
pub const Digits = enum { plain, negative, overflow, fractional };

pub const Literal = enum { true_value, false_value, null_value };

/// Decodes JSON string contents from `bytes[start..]` up to the first
/// unescaped quote or the end of `bytes`, checking every escape and UTF-8
/// sequence, and gives each scalar to `sink.append(bytes, scalar)` and each
/// run of plain ASCII whole with a null scalar. Returns where it stopped:
/// the quote's index, or `bytes.len`. The reader runs it over each string
/// it reads and the shell over each range a codec names, so both decode
/// alike.
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

/// The escape whose backslash is just before `at`; returns where it ends.
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

/// A `\u` escape whose hex digits start at `at`, with its low surrogate
/// when it is a high one.
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

/// The UTF-8 sequence that starts at `at`; std's decoder judges it once
/// whole.
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

/// How many leading bytes are string contents that need no check: no quote,
/// backslash, control or UTF-8.
fn plainLength(bytes: []const u8) usize {
    return for (bytes, 0..) |byte, count| {
        if (byte == '"' or byte == '\\' or byte < 0x20 or byte >= 0x80) break count;
    } else bytes.len;
}

/// Calls, on a handler `h` passed to `read`:
///   h.key(reader, depth): a key of the object whose members are at `depth`;
///   h.begin(reader, kind, depth), h.end(reader, kind, depth): a value at
///   `depth` begins or ends.
/// In `key` and in `end` of a string, `text` and `string` describe it; in
/// `end` of a number, `integer` and `digits`; in `end` of a literal,
/// `literalValue`.
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
    /// Where the rest of the literal being read starts in `literal_tails`.
    literal: u4,
    /// The number being read, while it is a plain nonnegative integer that
    /// fits.
    integer: ?u64,
    /// How the number being read differs from such an integer.
    digits: Digits,

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

    /// Reads `bytes` as one whole document, telling `handler` what it finds.
    /// A document that is invalid or ends early fails for the first reason
    /// its bytes give.
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
        // A value deeper than any document may hold was due, or more bytes
        // were.
        const value_due = self.state == .value or self.state == .value_or_close;
        return if (value_due and self.depth > max_depth) error.JsonTooDeep else error.UnexpectedJsonEnd;
    }

    /// The state before a document's first byte. The decoded text is written
    /// before it is read, so it is left.
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

    /// The decoded string, when no longer than `max_text_bytes`.
    pub fn text(self: *const Reader) ?[]const u8 {
        return if (self.decoded <= max_text_bytes) self.text_bytes[0..@intCast(self.decoded)] else null;
    }

    /// The literal just read, in `end` of a literal.
    pub fn literalValue(self: *const Reader) Literal {
        // `literal` stops at the terminator after the literal's tail.
        return switch (self.literal) {
            3 => .true_value,
            8 => .false_value,
            12 => .null_value,
            else => unreachable,
        };
    }

    /// The contents of the string just read, without its quotes.
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

    /// A byte that is not a digit after an integer part: a fraction, an
    /// exponent, or the end of the number.
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

    /// The string decoder's sink: keep the decoded start and count the rest.
    fn append(self: *Reader, bytes: []const u8, scalar: ?u21) void {
        _ = scalar;
        if (self.decoded < max_text_bytes) {
            const kept = @min(bytes.len, max_text_bytes - @as(usize, @intCast(self.decoded)));
            @memcpy(self.text_bytes[@intCast(self.decoded)..][0..kept], bytes[0..kept]);
        }
        self.decoded += bytes.len;
    }
};

/// A string's decoded start and decoded length, as the reader keeps them.
pub const Text = struct {
    bytes: [max_text_bytes]u8 = undefined,
    length: u64,

    /// The decoded string, when no longer than `max_text_bytes`.
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

// A document `Reader.read` accepted is walked again by these, which trust
// its syntax.

/// The contents of the string whose opening quote is at `start`, and where
/// it ends, one past its closing quote.
pub fn stringAt(document: []const u8, start: usize) struct { contents: Range, end: usize } {
    std.debug.assert(document[start] == '"');
    var at = start + 1;
    while (true) {
        at = std.mem.indexOfAnyPos(u8, document, at, "\\\"").?;
        if (document[at] == '"') return .{ .contents = .{ .start = start + 1, .length = at - start - 1 }, .end = at + 1 };
        at += 2;
    }
}

/// A value the reader accepted: one past its last byte, and a string's
/// contents.
pub const Value = struct { end: usize, string: ?Range };

pub fn valueAt(document: []const u8, start: usize) Value {
    if (document[start] != '"') return .{ .end = valueEnd(document, start), .string = null };
    const found = stringAt(document, start);
    return .{ .end = found.end, .string = found.contents };
}

/// Where the value that starts at `start` ends, one past its last byte.
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
                // A number or literal ends at the first byte that is not
                // its own.
                while (at < document.len and std.mem.indexOfScalar(u8, ",}] \t\r\n", document[at]) == null) at += 1;
                return at;
            },
        }
        if (depth == 0) return at;
    }
}

/// The first byte at or after `at` that is not whitespace.
pub fn skipSpace(document: []const u8, at: usize) usize {
    var index = at;
    while (space(document[index])) index += 1;
    return index;
}

/// Decodes `contents`, which the reader accepted as a string's, giving
/// each scalar to `sink` as `decodeString` does.
pub fn decodeContents(contents: []const u8, sink: anytype) void {
    std.debug.assert((decodeString(contents, 0, sink) catch unreachable) == contents.len);
}

/// Decodes `contents`, which the reader accepted as a string's, into `out`.
pub fn decode(contents: []const u8, out: *Text) void {
    out.length = 0;
    decodeContents(contents, out);
}

/// The tag of `E` that `contents`, a string's the reader accepted, decode
/// to: compared as they stand unless they hold an escape.
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

/// Records what a reader reports.
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

/// The reader accepts `document` exactly when std.json does.
fn expectReadAsStd(document: []const u8) !void {
    const expected = document.len != 0 and std.mem.trimStart(u8, document, " \t\r\n")[0] == '{' and
        try std.json.validate(std.testing.allocator, document);
    var recorder: Recorder = .{};
    try std.testing.expectEqual(expected, readForTesting(document, &recorder));
}

test "the reader reports keys and values with their depths, ranges and decoded starts" {
    var recorder: Recorder = .{};
    try std.testing.expect(readForTesting("{\"co\\u0064e\":\"x\\n\",\"n\":[7,1.5,-1],\"t\":true}", &recorder));
    try std.testing.expectEqualStrings(
        "O0 k1[2,9]code S1 s1[14,3]x\n k1[20,1]n A1 N2 n2=7 N2 n2=null N2 n2=null a1 k1[35,1]t L1 l1 o0 ",
        recorder.events(),
    );
    // A string past the kept start keeps its range; its text is unknown.
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
        // The top object's member is at depth 1 and each array adds one.
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
