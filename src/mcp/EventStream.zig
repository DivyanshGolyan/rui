const std = @import("std");

const EventStream = @This();

const bom = "\xef\xbb\xbf";

pub const Error = error{
    EventTooLarge,
};

const State = enum {
    line_start,
    name,
    value_start,
    value,
    skip,
};

state: State = .line_start,
name: [5]u8 = undefined,
name_len: u8 = 0,
data_field: bool = false,
after_cr: bool = false,
has_data: bool = false,
bom_read: u2 = 0,

pub const Step = struct {
    used: usize,
    dispatched: bool,
};

pub fn next(self: *EventStream, input: []const u8, data: *std.Io.Writer) Error!Step {
    var at: usize = 0;
    while (at < input.len) {
        const byte = input[at];
        at += 1;
        if (self.bom_read != 3) {
            // A stream may start with a byte order mark. Part of one is
            // part of the first line, as the U+FFFD it decodes to would be:
            // it starts a field name no field has.
            if (byte == bom[self.bom_read]) {
                self.bom_read += 1;
                continue;
            }
            if (self.bom_read != 0) {
                self.state = .name;
                self.name_len = 0;
                for (bom[0..self.bom_read]) |mark| self.addName(mark);
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
    try expectEvents("\xefdata: x\n\ndata: y\n\n", "y|");
    try expectEvents("\xef\xbbdata: x\n\n\xef\xbb\xbfdata: y\n\n", "");
    try expectEvents("\xef\xbb\n\ndata: z\n\n", "z|");
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
