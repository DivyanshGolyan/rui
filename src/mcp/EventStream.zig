//! A `text/event-stream` body read as it arrives, as values (the WHATWG
//! HTML "event stream interpretation"). Each event's data goes to the
//! caller's writer, its `data` lines joined by LF, and `next` says when an
//! event is complete; the caller reads the data as one JSON-RPC message and
//! starts the next event with an empty writer. Comments, `event`, `id`,
//! `retry` and unknown fields carry nothing an MCP client needs here: the
//! 2026-07-28 transport has no resumption, and every event's data is a
//! message.
//!
//! An event still open when the body ends is dropped, as the standard asks.
const std = @import("std");

const EventStream = @This();

const bom = "\xef\xbb\xbf";

pub const Error = error{
    /// An event's data outgrew the caller's writer.
    EventTooLarge,
};

const State = enum {
    /// At the first byte of a line.
    line_start,
    /// Reading a field name; `name` holds its start.
    name,
    /// Just after a field's colon: one space here is not part of the value.
    value_start,
    value,
    /// The rest of a comment or of a field nobody reads.
    skip,
};

state: State = .line_start,
/// Enough of a field name to tell `data` from every other name.
name: [5]u8 = undefined,
name_len: u8 = 0,
/// The field being read is `data`.
data_field: bool = false,
/// A CR ended the last line, so an LF right after it ends nothing.
after_cr: bool = false,
/// The current event has a data line: a blank line then dispatches it.
has_data: bool = false,
/// How much of a leading UTF-8 byte order mark has been read; 3 once the
/// stream is past where one may be.
bom_read: u2 = 0,

pub const Step = struct {
    used: usize,
    /// An event is complete and its data is all in the writer.
    dispatched: bool,
};

/// Reads `input` up to and including the end of the next event, writing
/// its data to `data`.
pub fn next(self: *EventStream, input: []const u8, data: *std.Io.Writer) Error!Step {
    var at: usize = 0;
    while (at < input.len) {
        const byte = input[at];
        at += 1;
        if (self.bom_read != 3) {
            // A stream may start with a byte order mark. No stream starts
            // with these bytes otherwise: they are not a field's start.
            if (byte == bom[self.bom_read]) {
                self.bom_read += 1;
                continue;
            }
            self.bom_read = 3;
        }
        if (self.after_cr) {
            self.after_cr = false;
            if (byte == '\n') continue;
        }
        if (byte == '\r' or byte == '\n') {
            self.after_cr = byte == '\r';
            if (try self.endLine(data)) return .{ .used = at, .dispatched = true };
            continue;
        }
        switch (self.state) {
            .line_start => switch (byte) {
                ':' => self.state = .skip,
                else => {
                    self.state = .name;
                    self.name_len = 0;
                    self.addName(byte);
                },
            },
            .name => if (byte == ':') {
                self.startValue(data) catch return error.EventTooLarge;
                if (self.data_field) self.state = .value_start;
            } else self.addName(byte),
            .value_start => {
                self.state = .value;
                if (byte != ' ') try self.addValue(data, byte);
            },
            .value => try self.addValue(data, byte),
            .skip => {},
        }
    }
    return .{ .used = at, .dispatched = false };
}

fn addName(self: *EventStream, byte: u8) void {
    if (self.name_len < self.name.len) self.name[self.name_len] = byte;
    self.name_len +|= 1;
}

fn isData(self: *const EventStream) bool {
    return self.name_len == 4 and std.mem.eql(u8, self.name[0..4], "data");
}

/// The field's name is complete: a data field after an earlier data line
/// first gets the LF that joins them.
fn startValue(self: *EventStream, data: *std.Io.Writer) std.Io.Writer.Error!void {
    self.data_field = self.isData();
    if (!self.data_field) {
        self.state = .skip;
        return;
    }
    if (self.has_data) try data.writeByte('\n');
    self.has_data = true;
}

fn addValue(self: *EventStream, data: *std.Io.Writer, byte: u8) Error!void {
    if (!self.data_field) return;
    data.writeByte(byte) catch return error.EventTooLarge;
}

/// Ends a line; returns whether it was the blank line that dispatches an
/// event.
fn endLine(self: *EventStream, data: *std.Io.Writer) Error!bool {
    defer self.state = .line_start;
    switch (self.state) {
        .line_start => {
            if (!self.has_data) return false;
            self.has_data = false;
            return true;
        },
        // A name with no colon is a field with an empty value.
        .name => {
            self.startValue(data) catch return error.EventTooLarge;
            if (self.state == .skip) self.state = .line_start;
        },
        .value_start, .value, .skip => {},
    }
    self.data_field = false;
    return false;
}

/// The events of `body` read in reads split at `split`; each event's data
/// is appended to `out` followed by `|`.
fn collect(body: []const u8, split: usize, out: *std.Io.Writer) !void {
    var stream: EventStream = .{};
    var data_buffer: [64]u8 = undefined;
    var data: std.Io.Writer = .fixed(&data_buffer);
    for ([_][]const u8{ body[0..split], body[split..] }) |read| {
        var rest = read;
        while (true) {
            const step = try stream.next(rest, &data);
            rest = rest[step.used..];
            if (!step.dispatched) break;
            try out.print("{s}|", .{data.buffered()});
            data = .fixed(&data_buffer);
        }
    }
}

fn expectEvents(body: []const u8, expected: []const u8) !void {
    for (0..body.len + 1) |split| {
        var buffer: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try collect(body, split, &out);
        try std.testing.expectEqualStrings(expected, out.buffered());
    }
}

test "events are dispatched by blank lines, data lines joined by LF" {
    try expectEvents("data: {\"a\":1}\n\n", "{\"a\":1}|");
    try expectEvents("event: message\r\nid: 7\r\ndata: one\r\ndata:two\r\n\r\ndata: three\n\n", "one\ntwo|three|");
    try expectEvents("data:  two spaces\r\r", " two spaces|");
    try expectEvents("\xef\xbb\xbfdata: bom\n\n", "bom|");
}

test "comments, unknown fields and empty events carry nothing" {
    try expectEvents(": keep-alive\n\n:\r\n\r\nretry: 10\n\nfoo: data: no\n\ndata: yes\n\n", "yes|");
    try expectEvents("data\n\n", "|");
    try expectEvents("datum: x\ndata2: y\ndata: z\n\n", "z|");
}

test "an event the body ends inside is dropped" {
    try expectEvents("data: whole\n\ndata: cut", "whole|");
    try expectEvents("data: cut\n", "");
}

test "an event larger than the writer is refused" {
    var stream: EventStream = .{};
    var buffer: [4]u8 = undefined;
    var data: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.EventTooLarge, stream.next("data: 12345\n\n", &data));
    stream = .{};
    data = .fixed(&buffer);
    try std.testing.expectError(error.EventTooLarge, stream.next("data: 1234\ndata\n\n", &data));
}
