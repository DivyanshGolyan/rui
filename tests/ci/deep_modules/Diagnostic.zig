//! One finding of the deep-modules lints: what it is, its allow key, and what a reader is shown.

const std = @import("std");

/// What a reader can hold in mind at once. Lists and pictures show no more than this.
pub const held_in_mind = 7;

pub const Lint = enum {
    @"module-cycle",
    tangle,
    @"field-leak",
    @"shallow-module",

    /// The name written in reports and in the allow file.
    pub fn name(lint: Lint) []const u8 {
        return @tagName(lint);
    }

    /// The lint with this name, or null for a name no lint has.
    pub fn parse(text: []const u8) ?Lint {
        return std.meta.stringToEnum(Lint, text);
    }
};

/// A place in a file, as an editor links it: `file:line:column`.
pub const Location = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

/// A member of a circle and its tie to the next member.
pub const Step = struct {
    member: []const u8,
    /// Where the tie is first written.
    site: Location,
    /// What the member uses of the next one, as in `listen uses Stream`.
    uses: []const u8,
};

/// A count and the name it belongs to.
pub const Tally = struct {
    count: usize,
    name: []const u8,
};

/// The shape of what a diagnostic found, drawn under its notes.
pub const Picture = union(enum) {
    /// Members that know each other in a circle, from its cheapest tie. `rest` says what the circle leaves out.
    circle: struct {
        steps: []const Step,
        rest: ?[]const u8,
    },
    /// A field of `owner` and the modules whose code works on it, most places first, then its other fields.
    spread: struct {
        owner: []const u8,
        field: []const u8,
        modules: []const Tally,
        others: []const []const u8,
    },
    /// How many functions a module shows and hides, and each list it is learned by.
    lists: struct {
        shown: usize,
        hidden: usize,
        lists: []const Tally,
    },
};

pub const Diagnostic = struct {
    lint: Lint,
    /// Identifies the diagnostic in the allow file: module paths, joined with `,` for a circle.
    key: []const u8,
    message: []const u8,
    location: ?Location,
    notes: []const []const u8,
    picture: Picture,
};

/// Writes `a, b, c`, and `, +N more` after at most `held_in_mind` of the names.
pub fn listed(w: *std.Io.Writer, names: []const []const u8) std.Io.Writer.Error!void {
    for (names[0..@min(names.len, held_in_mind)], 0..) |name, index| {
        if (index > 0) try w.writeAll(", ");
        try w.writeAll(name);
    }
    if (names.len > held_in_mind) try w.print(", +{d} more", .{names.len - held_in_mind});
}

/// Writes `1 module` or `2 modules`: the noun is given singular.
pub fn counted(w: *std.Io.Writer, count: usize, noun: []const u8) std.Io.Writer.Error!void {
    try w.print("{d} {s}", .{ count, noun });
    if (count != 1) try w.writeAll("s");
}

fn allocated(comptime write: anytype, args: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try @call(.auto, write, .{&out.writer} ++ args);
    return out.toOwnedSlice();
}

test "Lint names round trip and unknown names are rejected" {
    for (std.enums.values(Lint)) |lint| {
        try std.testing.expectEqual(lint, Lint.parse(lint.name()).?);
    }
    try std.testing.expectEqualStrings("field-leak", Lint.@"field-leak".name());
    try std.testing.expectEqual(@as(?Lint, null), Lint.parse("wide-directory"));
    try std.testing.expectEqual(@as(?Lint, null), Lint.parse("Tangle"));
    try std.testing.expectEqual(@as(?Lint, null), Lint.parse(""));
}

test "listed shows at most seven names then how many more" {
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    const cases = [_]struct { count: usize, want: []const u8 }{
        .{ .count = 0, .want = "" },
        .{ .count = 1, .want = "a" },
        .{ .count = 3, .want = "a, b, c" },
        .{ .count = 7, .want = "a, b, c, d, e, f, g" },
        .{ .count = 8, .want = "a, b, c, d, e, f, g, +1 more" },
        .{ .count = 9, .want = "a, b, c, d, e, f, g, +2 more" },
    };
    for (cases) |case| {
        const got = try allocated(listed, .{names[0..case.count]});
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "counted pluralizes every count but one" {
    const cases = [_]struct { count: usize, want: []const u8 }{
        .{ .count = 0, .want = "0 modules" },
        .{ .count = 1, .want = "1 module" },
        .{ .count = 2, .want = "2 modules" },
    };
    for (cases) |case| {
        const got = try allocated(counted, .{ case.count, "module" });
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "held_in_mind is seven" {
    try std.testing.expectEqual(@as(usize, 7), held_in_mind);
}
