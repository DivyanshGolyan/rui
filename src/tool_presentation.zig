const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const session_id = @import("session_id.zig");

pub const max_description_bytes = @import("mcp/shape.zig").description_max_bytes;

pub const max_label_bytes = 100;

pub const max_session_bytes = session_id.max_reference_bytes;

/// A Session a row points at: its reference as written, and the label the Store holds when the row is read.
/// A writer supplies the reference alone; the label is filled in at read, so a rename shows on every row.
pub const NamedPeer = struct {
    session: Bounded(max_session_bytes),
    label: Bounded(max_label_bytes) = .{},

    pub fn name(self: *const NamedPeer) []const u8 {
        return if (self.label.len == 0) self.session.slice() else self.label.slice();
    }
};

/// What a tool row says: one line of words with at most one typed reference inside it.
///
/// `words` holds the line without the reference's name; `link.at` is where that name belongs, so the
/// words and the reference stay separate facts and every surface decides for itself how to draw a link.
/// A Line that exists is valid: `plain` and `linked` are the only ways to make one, and a read checks
/// the same rules again (`valid`) before it hands the Line to a reader.
pub const Line = struct {
    words: Bounded(max_description_bytes) = .{},
    link: ?Link = null,

    pub const Link = struct { at: usize = 0, peer: NamedPeer };

    pub const Part = union(enum) { words: []const u8, peer: *const NamedPeer };

    pub const Error = error{InvalidLine};

    /// Words alone: a Bash description, "Find tools", an MCP call's description argument.
    pub fn plain(words: []const u8) Error!Line {
        if (!ToolPresentation.validDescription(words)) return error.InvalidLine;
        return .{ .words = Bounded(max_description_bytes).from(words) catch return error.InvalidLine };
    }

    /// Words with one Session named between them: `linked("Messaged ", id, "")`.
    /// `before` and `after` are the tool's own words, so they are never cut to fit; a reference too long
    /// for the line is the caller's error, not a truncation.
    pub fn linked(before: []const u8, session: []const u8, after: []const u8) Error!Line {
        var line: Line = .{ .link = .{ .at = before.len, .peer = .{
            .session = Bounded(max_session_bytes).from(session) catch return error.InvalidLine,
        } } };
        if (before.len + after.len > max_description_bytes) return error.InvalidLine;
        @memcpy(line.words.bytes[0..before.len], before);
        @memcpy(line.words.bytes[before.len..][0..after.len], after);
        line.words.len = before.len + after.len;
        if (!line.valid()) return error.InvalidLine;
        return line;
    }

    /// The Line as a wire or Store read hands it over: words, an optional reference with the label
    /// that read saw, words. The one way a Line enters this process from outside.
    pub fn fromParts(before: []const u8, peer: ?NamedPeer, after: []const u8) Error!Line {
        const named = peer orelse {
            if (after.len != 0) return error.InvalidLine;
            return plain(before);
        };
        var line = try linked(before, named.session.slice(), after);
        if (named.label.len != 0) try line.setLabel(named.label.slice());
        return line;
    }

    /// The label the Store read for this Line's reference. A Line without one keeps its ID.
    pub fn setLabel(self: *Line, label: []const u8) Error!void {
        const link = if (self.link) |*value| value else return error.InvalidLine;
        if (!validLabel(label)) return error.InvalidLine;
        link.peer.label = Bounded(max_label_bytes).from(label) catch return error.InvalidLine;
    }

    /// Every rule a Line obeys, checked again on the way out of the Store.
    pub fn valid(self: *const Line) bool {
        if (self.words.len > max_description_bytes or !std.unicode.utf8ValidateSlice(self.words.slice())) return false;
        if (!oneLine(self.words.slice())) return false;
        const link = if (self.link) |*value| value else return ToolPresentation.validDescription(self.words.slice());
        if (link.at > self.words.len) return false;
        if (link.at != self.words.len and !isBoundary(self.words.bytes[link.at])) return false;
        if (link.peer.session.len == 0 or !ToolPresentation.validDescription(link.peer.session.slice())) return false;
        if (link.peer.label.len != 0 and !validLabel(link.peer.label.slice())) return false;
        return true;
    }

    /// The Line as a plain call description, a reference standing as its name; null when it does not fit.
    pub fn description(self: *const Line) ?Bounded(max_description_bytes) {
        var out: Bounded(max_description_bytes) = .{};
        var walk = self.parts();
        while (walk.next()) |part| {
            const text = switch (part) {
                .words => |words| words,
                .peer => |peer| peer.name(),
            };
            if (out.len + text.len > max_description_bytes) return null;
            @memcpy(out.bytes[out.len..][0..text.len], text);
            out.len += text.len;
        }
        return out;
    }

    /// The Line in display order: words before the reference, the reference, words after it.
    pub fn parts(self: *const Line) Parts {
        return .{ .line = self };
    }

    pub const Parts = struct {
        line: *const Line,
        index: u2 = 0,

        pub fn next(self: *Parts) ?Part {
            const line = self.line;
            const at = if (line.link) |link| link.at else line.words.len;
            while (self.index < 3) {
                const index = self.index;
                self.index += 1;
                switch (index) {
                    0 => if (at != 0) return .{ .words = line.words.bytes[0..at] },
                    1 => if (line.link) |*link| return .{ .peer = &link.peer },
                    else => if (at != line.words.len) return .{ .words = line.words.slice()[at..] },
                }
            }
            return null;
        }
    };

    /// The Line as text, a reference standing as its name: the transcript tool, search, logs, ASCII output.
    pub fn writePlain(self: *const Line, out: *std.Io.Writer) !void {
        var walk = self.parts();
        while (walk.next()) |part| switch (part) {
            .words => |words| try out.writeAll(words),
            .peer => |peer| try out.writeAll(peer.name()),
        };
    }

    fn isBoundary(byte: u8) bool {
        return byte & 0xc0 != 0x80;
    }

    fn oneLine(bytes: []const u8) bool {
        var index: usize = 0;
        while (index < bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return false;
            if (index + length > bytes.len) return false;
            const scalar = std.unicode.utf8Decode(bytes[index..][0..length]) catch return false;
            index += length;
            switch (scalar) {
                '\n', '\r', 0x85, 0x2028, 0x2029 => return false,
                else => {},
            }
        }
        return true;
    }
};

pub const ToolPresentation = struct {
    /// The words of the row. Null only for a call no tool served (`unknown_tool`, `invalid_arguments`).
    line: ?Line,
    code: Code,
    /// The mark this row shows, decided once by `signOf` where the row is read. Every surface maps a
    /// Sign to its own glyph, so none of them repeats that rule.
    sign: Sign = .finished,
    publication_position: ?u64,

    pub const Code = enum { unresolved, pending_permission, background, succeeded, failed, timed_out, indeterminate, storage_failed, spawn_failed, cancelled, infrastructure_shutdown, denied, unknown_tool, invalid_arguments };

    pub const Sign = enum { needs_you, active, finished, sent, failed, stopped };

    /// The one constructor a Store read uses: the line as saved, the code as derived, the finish the tool chose.
    /// A call no tool served has no words, and nothing else may lack them.
    pub fn of(line: ?Line, code: Code, completion: Completion, publication_position: ?u64) error{CorruptStore}!ToolPresentation {
        if (line) |shown| if (!shown.valid()) return error.CorruptStore;
        if (line == null) switch (code) {
            .unknown_tool, .invalid_arguments => {},
            else => return error.CorruptStore,
        };
        return .{ .line = line, .code = code, .sign = signOf(code, completion), .publication_position = publication_position };
    }

    /// True when this row's mark is one its code could have produced: the check an ingress makes.
    pub fn consistent(self: *const ToolPresentation) bool {
        return self.sign == signOf(self.code, .done) or self.sign == signOf(self.code, .sent);
    }

    pub fn validDescription(bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > max_description_bytes or !std.unicode.utf8ValidateSlice(bytes)) return false;
        var nonblank = false;
        var index: usize = 0;
        while (index < bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch unreachable;
            const scalar = std.unicode.utf8Decode(bytes[index..][0..length]) catch unreachable;
            index += length;
            switch (scalar) {
                '\n', '\r', 0x85, 0x2028, 0x2029 => return false,
                ' ', '\t', 0xb, 0xc, 0xa0, 0x1680, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => {},
                else => nonblank = true,
            }
        }
        return nonblank;
    }
};

/// What kind of finish a successful call was. Closed: a new member is a wire change.
/// `sent` means the call handed work to another Session, so the row reads as an arrow, not a tick.
pub const Completion = enum { done, sent };

/// The one rule that turns a resolution and a tool's chosen finish into a mark.
/// A tool's choice refines a successful finish alone; failure, denial and cancellation stay the system's.
pub fn signOf(code: ToolPresentation.Code, completion: Completion) ToolPresentation.Sign {
    return switch (code) {
        .unresolved => .active,
        .pending_permission => .needs_you,
        .background, .succeeded => switch (completion) {
            .done => .finished,
            .sent => .sent,
        },
        .denied, .cancelled => .stopped,
        .failed, .timed_out, .indeterminate, .storage_failed, .spawn_failed, .infrastructure_shutdown, .unknown_tool, .invalid_arguments => .failed,
    };
}

pub fn validLabel(bytes: []const u8) bool {
    return bytes.len <= max_label_bytes and ToolPresentation.validDescription(bytes);
}

test "a Label is one non-blank line of at most 100 bytes" {
    const longest: [max_label_bytes]u8 = @splat('x');
    const overlong: [max_label_bytes + 1]u8 = @splat('x');
    try std.testing.expect(validLabel("Review PR 412") and validLabel(&longest) and validLabel("Café"));
    for ([_][]const u8{ "", " \t", "one\ntwo", "one\u{2028}two", "\xff", &overlong }) |invalid|
        try std.testing.expect(!validLabel(invalid));
}

test "saved call descriptions allow 200 bytes without widening Labels" {
    const longest: [200]u8 = @splat('x');
    const overlong: [201]u8 = @splat('x');
    try std.testing.expect(ToolPresentation.validDescription(&longest));
    try std.testing.expect(!ToolPresentation.validDescription(&overlong));
    try std.testing.expect(!validLabel(&longest));
    for ([_][]const u8{ "", " \t", "one\ntwo", "one\rtwo", "one\u{85}two", "one\u{2028}two", "one\u{2029}two", "\xff" }) |invalid|
        try std.testing.expect(!ToolPresentation.validDescription(invalid));
}

test "TPR-1 a tool row's line keeps its words and its reference apart in display order" {
    const Case = struct {
        line: Line.Error!Line,
        plain: []const u8 = "",
        parts: []const []const u8 = &.{},
    };
    var longest: [max_description_bytes]u8 = @splat('x');
    const widest = try Line.plain(&longest);
    try std.testing.expect(widest.valid());
    const cases = [_]Case{
        .{ .line = Line.plain("Find tools"), .plain = "Find tools", .parts = &.{"w:Find tools"} },
        .{ .line = Line.linked("Messaged ", "k7m2qx", ""), .plain = "Messaged k7m2qx", .parts = &.{ "w:Messaged ", "p:k7m2qx" } },
        .{ .line = Line.linked("Read ", "k7m2qx", "'s transcript"), .plain = "Read k7m2qx's transcript", .parts = &.{ "w:Read ", "p:k7m2qx", "w:'s transcript" } },
        .{ .line = Line.linked("", "k7m2qx", " answered"), .plain = "k7m2qx answered", .parts = &.{ "p:k7m2qx", "w: answered" } },
        // Words may be blank when a reference carries the line, and a café in them stays one scalar wide.
        .{ .line = Line.linked("", "k7m2qx", ""), .plain = "k7m2qx", .parts = &.{"p:k7m2qx"} },
        .{ .line = Line.linked("Café ", "k7m2qx", ""), .plain = "Café k7m2qx", .parts = &.{ "w:Café ", "p:k7m2qx" } },
        // Invalid: blank words with no reference, newlines, overlong words, an empty or unprintable reference.
        .{ .line = Line.plain("") },
        .{ .line = Line.plain(" \t") },
        .{ .line = Line.plain("one\ntwo") },
        .{ .line = Line.plain(longest[0..] ++ "y") },
        .{ .line = Line.linked("Messaged ", "", "") },
        .{ .line = Line.linked("one\n", "k7m2qx", "") },
        .{ .line = Line.linked("Messaged ", "one\ntwo", "") },
        .{ .line = Line.linked(&longest, "k7m2qx", "x") },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("case {d}\n", .{index});
        if (case.parts.len == 0) {
            try std.testing.expectError(error.InvalidLine, case.line);
            continue;
        }
        var line = try case.line;
        try std.testing.expect(line.valid());
        var seen: [3][]const u8 = undefined;
        var count: usize = 0;
        var walk = line.parts();
        var buffer: [4 * (max_description_bytes + 8)]u8 = undefined;
        while (walk.next()) |part| {
            seen[count] = switch (part) {
                .words => |words| try std.fmt.bufPrint(buffer[count * (max_description_bytes + 8) ..], "w:{s}", .{words}),
                .peer => |peer| try std.fmt.bufPrint(buffer[count * (max_description_bytes + 8) ..], "p:{s}", .{peer.name()}),
            };
            count += 1;
        }
        try std.testing.expectEqual(case.parts.len, count);
        for (case.parts, seen[0..count]) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
        var out: [4 * max_description_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        try line.writePlain(&writer);
        try std.testing.expectEqualStrings(case.plain, writer.buffered());
    }
}

test "TPR-1 a reference's label comes from the read and replaces its ID in the words" {
    var line = try Line.linked("Messaged ", "k7m2qx", "");
    try std.testing.expectEqualStrings("k7m2qx", line.link.?.peer.name());
    try line.setLabel("Review the WAL");
    try std.testing.expect(line.valid());
    try std.testing.expectEqualStrings("Review the WAL", line.link.?.peer.name());
    var out: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try line.writePlain(&writer);
    try std.testing.expectEqualStrings("Messaged Review the WAL", writer.buffered());
    const overlong_label: [max_label_bytes + 1]u8 = @splat('x');
    for ([_][]const u8{ "", "one\ntwo", &overlong_label }) |invalid|
        try std.testing.expectError(error.InvalidLine, line.setLabel(invalid));
    var words = try Line.plain("Find tools");
    try std.testing.expectError(error.InvalidLine, words.setLabel("Review the WAL"));
    // A Line read back with a reference inside a scalar, or past its words, is not a Line.
    var split = try Line.linked("Café ", "k7m2qx", "");
    split.link.?.at = 4;
    try std.testing.expect(!split.valid());
    split.link.?.at = split.words.len + 1;
    try std.testing.expect(!split.valid());
}

test "TPR-2 a tool chooses how a success reads and never how a failure reads" {
    const Code = ToolPresentation.Code;
    const Sign = ToolPresentation.Sign;
    const cases = [_]struct { code: Code, done: Sign, sent: Sign }{
        .{ .code = .unresolved, .done = .active, .sent = .active },
        .{ .code = .pending_permission, .done = .needs_you, .sent = .needs_you },
        .{ .code = .background, .done = .finished, .sent = .sent },
        .{ .code = .succeeded, .done = .finished, .sent = .sent },
        .{ .code = .failed, .done = .failed, .sent = .failed },
        .{ .code = .timed_out, .done = .failed, .sent = .failed },
        .{ .code = .indeterminate, .done = .failed, .sent = .failed },
        .{ .code = .storage_failed, .done = .failed, .sent = .failed },
        .{ .code = .spawn_failed, .done = .failed, .sent = .failed },
        .{ .code = .cancelled, .done = .stopped, .sent = .stopped },
        .{ .code = .infrastructure_shutdown, .done = .failed, .sent = .failed },
        .{ .code = .denied, .done = .stopped, .sent = .stopped },
        .{ .code = .unknown_tool, .done = .failed, .sent = .failed },
        .{ .code = .invalid_arguments, .done = .failed, .sent = .failed },
    };
    try std.testing.expectEqual(std.enums.values(Code).len, cases.len);
    var seen: std.enums.EnumSet(Sign) = .empty;
    for (cases) |case| {
        try std.testing.expectEqual(case.done, signOf(case.code, .done));
        try std.testing.expectEqual(case.sent, signOf(case.code, .sent));
        seen.insert(case.done);
        seen.insert(case.sent);
        for ([_]Sign{ case.done, case.sent }) |marked| {
            const row: ToolPresentation = .{ .line = null, .code = case.code, .sign = marked, .publication_position = null };
            try std.testing.expect(row.consistent());
        }
        for (std.enums.values(Sign)) |marked| {
            if (marked == case.done or marked == case.sent) continue;
            const row: ToolPresentation = .{ .line = null, .code = case.code, .sign = marked, .publication_position = null };
            try std.testing.expect(!row.consistent());
        }
    }
    try std.testing.expect(seen.eql(.full));
}
