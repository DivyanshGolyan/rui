//! The rule that makes a word in Message text a skill reference: `/name`
//! at a word boundary, with a skill name's grammar. The Host binds by it,
//! and a composer suggests by it, so both read text the same way.
const std = @import("std");

/// A skill name: 1 to 64 bytes of `a-z`, `0-9` and single inner hyphens.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '-' or name[name.len - 1] == '-') return false;
    var hyphen = false;
    for (name) |byte| {
        if (byte == '-') {
            if (hyphen) return false;
            hyphen = true;
        } else {
            if (!(byte >= 'a' and byte <= 'z') and !(byte >= '0' and byte <= '9')) return false;
            hyphen = false;
        }
    }
    return true;
}

/// Finds `/name` skill references in Message text, one byte at a time, so
/// text of any size streams through it. A reference starts the text or
/// follows whitespace or `(`, and ends at the text's end, whitespace or one
/// of `.,;:!?)`; anything else (`/tmp/etc`, `//name`) is prose. Whether a
/// reference binds is the recipient catalog's decision, not the scanner's.
pub const References = struct {
    state: enum { boundary, slash, name, prose } = .boundary,
    name: [64]u8 = undefined,
    len: usize = 0,

    /// The name this byte ended, borrowed until the next call.
    pub fn feed(self: *References, byte: u8) ?[]const u8 {
        switch (self.state) {
            .boundary => {
                if (byte == '/') self.state = .slash else self.follow(byte);
            },
            .slash => if (nameByte(byte)) {
                self.name[0] = byte;
                self.len = 1;
                self.state = .name;
            } else self.follow(byte),
            .name => if (nameByte(byte)) {
                if (self.len == self.name.len) self.state = .prose else {
                    self.name[self.len] = byte;
                    self.len += 1;
                }
            } else {
                self.follow(byte);
                if (ends(byte) and validName(self.name[0..self.len])) return self.name[0..self.len];
            },
            .prose => self.follow(byte),
        }
        return null;
    }

    /// The name the text's end completes.
    pub fn finish(self: *const References) ?[]const u8 {
        return if (self.state == .name and validName(self.name[0..self.len])) self.name[0..self.len] else null;
    }

    /// Whether `byte` after a name ends it as a reference rather than
    /// making the word prose.
    pub fn ends(byte: u8) bool {
        return std.ascii.isWhitespace(byte) or std.mem.indexOfScalar(u8, ".,;:!?)", byte) != null;
    }

    /// Whether a `/` after `byte` may start a reference.
    pub fn opens(byte: u8) bool {
        return std.ascii.isWhitespace(byte) or byte == '(';
    }

    fn follow(self: *References, byte: u8) void {
        self.state = if (opens(byte)) .boundary else .prose;
    }

    pub fn nameByte(byte: u8) bool {
        return (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-';
    }
};

test "skill references are /name words at word boundaries, in text order" {
    const expectReferences = struct {
        /// Each reference the scanner reports, with a space after it,
        /// against `expected` written the same way.
        fn check(text: []const u8, expected: []const []const u8) !void {
            var found: [256]u8 = undefined;
            var found_len: usize = 0;
            var scanner: References = .{};
            for (text) |byte| if (scanner.feed(byte)) |name| {
                found_len += join(found[found_len..], name);
            };
            if (scanner.finish()) |name| found_len += join(found[found_len..], name);
            var want: [256]u8 = undefined;
            var want_len: usize = 0;
            for (expected) |name| want_len += join(want[want_len..], name);
            try std.testing.expectEqualStrings(want[0..want_len], found[0..found_len]);
        }

        fn join(into: []u8, name: []const u8) usize {
            @memcpy(into[0..name.len], name);
            into[name.len] = ' ';
            return name.len + 1;
        }
    }.check;
    try expectReferences("/review", &.{"review"});
    try expectReferences("look at /review then /tests.", &.{ "review", "tests" });
    try expectReferences("(/a-b) /c, /d; /e: /f! /g? /h\n/i\t/j", &.{ "a-b", "c", "d", "e", "f", "g", "h", "i", "j" });
    // Repeats are reported; binding decides that a skill is bound once.
    try expectReferences("/x /x", &.{ "x", "x" });
    // Paths, escapes, and words glued to other text are prose.
    try expectReferences("/tmp/etc a/b x/review //review /review/ /review_x /Review /review- /a--b /-a", &.{});
    try expectReferences("costs 5 /month", &.{"month"});
    try expectReferences("\"/review\" /review\"", &.{});
    try expectReferences("/ / /雪 é/x", &.{});
    try expectReferences("/" ++ @as([64]u8, @splat('a')) ++ " /" ++ @as([65]u8, @splat('b')), &.{&@as([64]u8, @splat('a'))});
    try expectReferences("", &.{});
}
