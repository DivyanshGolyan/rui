//! A stand-in for a codec's interpret step, built both natively and as a
//! wasm module so the bench compares the same code in both places. It reads
//! a server-sent event stream in windows, decodes every JSON string on its
//! `data:` lines (escapes included) and folds the decoded bytes into a
//! digest, so both builds must agree on the result.
const std = @import("std");

pub const window_bytes = 64 * 1024;

pub const Scan = struct {
    state: State = .line_start,
    matched: u8 = 0,
    escape_digits: u8 = 0,
    escape_value: u21 = 0,
    digest: u64 = 0xcbf29ce484222325,

    const State = enum { line_start, prefix, skip_line, json, string, escape, unicode };
    const prefix = "data:";

    pub fn feed(self: *Scan, bytes: []const u8) void {
        for (bytes) |byte| self.step(byte);
    }

    fn step(self: *Scan, byte: u8) void {
        switch (self.state) {
            .line_start, .prefix => {
                if (byte == '\n') {
                    self.state = .line_start;
                } else if (self.matched < prefix.len and byte == prefix[self.matched]) {
                    self.matched += 1;
                    self.state = if (self.matched == prefix.len) .json else .prefix;
                } else self.state = .skip_line;
                if (self.state != .prefix) self.matched = 0;
            },
            .skip_line => if (byte == '\n') {
                self.state = .line_start;
            },
            .json => switch (byte) {
                '\n' => self.state = .line_start,
                '"' => self.state = .string,
                else => {},
            },
            .string => switch (byte) {
                '"' => self.state = .json,
                '\\' => self.state = .escape,
                else => self.emit(byte),
            },
            .escape => {
                self.state = .string;
                switch (byte) {
                    'n' => self.emit('\n'),
                    't' => self.emit('\t'),
                    'r' => self.emit('\r'),
                    'b' => self.emit(8),
                    'f' => self.emit(12),
                    'u' => {
                        self.state = .unicode;
                        self.escape_digits = 0;
                        self.escape_value = 0;
                    },
                    else => self.emit(byte),
                }
            },
            .unicode => {
                const digit = std.fmt.charToDigit(byte, 16) catch 0;
                self.escape_value = self.escape_value * 16 + digit;
                self.escape_digits += 1;
                if (self.escape_digits == 4) {
                    self.state = .string;
                    var utf8: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(self.escape_value, &utf8) catch return;
                    for (utf8[0..len]) |encoded| self.emit(encoded);
                }
            },
        }
    }

    fn emit(self: *Scan, byte: u8) void {
        self.digest = (self.digest ^ byte) *% 0x100000001b3;
    }
};
