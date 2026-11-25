const std = @import("std");

/// The largest SKILL.md the model is given.
pub const max_skill_bytes = 1024 * 1024;

/// The longest skill name; the Store column `message_skill.name` holds the same bound.
pub const max_name_bytes = 64;

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or name[0] == '-' or name[name.len - 1] == '-') return false;
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

pub const References = struct {
    state: enum { boundary, slash, name, prose } = .boundary,
    name: [64]u8 = undefined,
    len: usize = 0,

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

    pub fn finish(self: *const References) ?[]const u8 {
        return if (self.state == .name and validName(self.name[0..self.len])) self.name[0..self.len] else null;
    }

    pub fn ends(byte: u8) bool {
        return std.ascii.isWhitespace(byte) or std.mem.indexOfScalar(u8, ".,;:!?)", byte) != null;
    }

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
    try expectReferences("/x /x", &.{ "x", "x" });
    try expectReferences("/tmp/etc a/b x/review //review /review/ /review_x /Review /review- /a--b /-a", &.{});
    try expectReferences("costs 5 /month", &.{"month"});
    try expectReferences("\"/review\" /review\"", &.{});
    try expectReferences("/ / /雪 é/x", &.{});
    try expectReferences("/" ++ @as([64]u8, @splat('a')) ++ " /" ++ @as([65]u8, @splat('b')), &.{&@as([64]u8, @splat('a'))});
    try expectReferences("", &.{});
}
