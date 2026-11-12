//! The keys a screen may bind, and each screen's one table of what they do
//! there. Value-only, so the pure overview core names them without the line
//! editor: the editor turns terminal input into a `Key` and hands back the
//! screen's own action for every key it has no editing use for.
const std = @import("std");

/// A key that is a key, not text. It names the key, never a meaning: each
/// screen's `Keymap` says what it does there. Adding one fails the build at
/// every screen's table until that screen decides.
pub const Key = enum {
    /// Esc and Alt-Esc in every encoding, and a lone ESC once it expires.
    escape,
    ctrl_c,
    ctrl_d,
    ctrl_g,
    ctrl_n,
    ctrl_o,
    ctrl_p,
    ctrl_r,
    ctrl_x,
    alt_a,
    up,
    down,
    shift_up,
    shift_down,
    /// With or without Shift.
    page_up,
    page_down,
    home,
    end,
    ctrl_end,
};

/// One screen's meaning for every `Key`: one of its actions, or null when
/// the key does nothing there. `init` takes every key, so no screen forgets one.
pub fn Keymap(comptime A: type) type {
    return struct {
        pub const Action = A;
        meanings: std.enums.EnumArray(Key, ?A),

        pub fn init(meanings: std.enums.EnumFieldStruct(Key, ?A, null)) @This() {
            return .{ .meanings = .init(meanings) };
        }

        pub fn get(self: @This(), key: Key) ?A {
            return self.meanings.get(key);
        }
    };
}

/// What one input means at a choice drawn in place of the draft, through the
/// draft's own classification: a typed `Key` means what the screen's keymap
/// says, the arrows and Enter are the choice's own, typed text and a marked
/// paste begin typing, a chord, control or malformed input is refused, and
/// the draft's other unmodified edit keys do nothing. Nothing here edits.
pub fn Selection(comptime A: type) type {
    return union(enum) { none, action: A, left, right, enter, text, refused };
}

/// Why the editor refused input.
pub const Refusal = enum {
    /// Enter on a line rejected earlier because it held input that is not
    /// text. The caller drops the line.
    invalid,
    /// Enter on a line rejected earlier for its length.
    overflow,
    /// A whole marked paste exceeded the limit; the prior draft stays.
    paste_overflow,
    /// A refused edit; the draft stands as it was.
    edit_rejected,
    /// An Alt, Super, Hyper or Meta chord nothing binds, dropped whole.
    unbound,

    pub fn endsLine(self: Refusal) bool {
        return self == .invalid or self == .overflow;
    }
};

/// What one input did on a screen whose keys mean `A`s: an edit of the
/// draft, or the screen's action for a key the editor had no use for.
pub fn Outcome(comptime A: type) type {
    return union(enum) {
        /// Nothing visible changed, or a key this screen binds to nothing.
        none,
        /// Text was added at the end of the draft.
        append,
        /// The draft or caret changed elsewhere.
        redraw,
        /// Enter: the draft is a line.
        submit,
        refused: Refusal,
        action: A,

        /// Enter ended the line, sent or refused. A screen's own keys end
        /// whatever that screen says they end.
        pub fn endsLine(self: @This()) bool {
            return switch (self) {
                .submit => true,
                .refused => |why| why.endsLine(),
                else => false,
            };
        }
    };
}

/// Every key as itself, for tests of an editor without a screen.
pub const every: Keymap(Key) = blk: {
    var map: Keymap(Key) = .{ .meanings = .initFill(null) };
    for (std.enums.values(Key)) |key| map.meanings.set(key, key);
    break :blk map;
};

/// The app's one reference list, in pairs across a fitting panel. Each
/// screen key is represented directly or explicitly grouped under a listed
/// key as an alias. Empty `keys` name draft operations, not screen actions.
pub const Reference = struct {
    key: []const u8,
    meaning: []const u8,
    keys: []const Key = &.{},
    aliases: []const Key = &.{},
};

pub const list = [_]Reference{
    .{ .key = "enter", .meaning = "send" },
    .{ .key = "esc", .meaning = "back", .keys = &.{.escape}, .aliases = &.{.ctrl_g} },
    .{ .key = "⇧enter", .meaning = "new line" },
    .{ .key = "tab", .meaning = "next footer field" },
    .{ .key = "⇧tab", .meaning = "previous footer field" },
    .{ .key = "ctrl+x", .meaning = "stop", .keys = &.{.ctrl_x} },
    .{ .key = "↑↓", .meaning = "scroll", .keys = &.{ .up, .down }, .aliases = &.{ .shift_up, .shift_down, .page_up, .page_down, .home, .end, .ctrl_end } },
    .{ .key = "ctrl+o", .meaning = "tool output", .keys = &.{.ctrl_o} },
    .{ .key = "ctrl+p", .meaning = "earlier message", .keys = &.{.ctrl_p}, .aliases = &.{.ctrl_n} },
    .{ .key = "ctrl+r", .meaning = "retry", .keys = &.{.ctrl_r} },
    .{ .key = "/", .meaning = "skills" },
    .{ .key = "alt+a", .meaning = "archive", .keys = &.{.alt_a} },
    .{ .key = "ctrl+c", .meaning = "leave", .keys = &.{.ctrl_c}, .aliases = &.{.ctrl_d} },
};

pub const ListError = enum { missing_bound_key, unbound_row, duplicate_key };

/// Check the union: every bound key is listed or explicitly aliased exactly
/// once; neither a row nor an alias can name a key neither screen binds. The
/// caller supplies actual maps, keeping this value-only owner independent.
pub fn listError(maps: anytype) ?ListError {
    return referenceError(&list, maps);
}

fn referenceError(rows: []const Reference, maps: anytype) ?ListError {
    var bound: std.enums.EnumSet(Key) = .empty;
    inline for (maps) |map| {
        for (std.enums.values(Key)) |key| if (map.get(key) != null) {
            bound.insert(key);
        };
    }
    var shown: std.enums.EnumSet(Key) = .empty;
    for (rows) |row| for ([_][]const Key{ row.keys, row.aliases }) |keys| for (keys) |key| {
        if (shown.contains(key)) return .duplicate_key;
        if (!bound.contains(key)) return .unbound_row;
        shown.insert(key);
    };
    return if (shown.eql(bound)) null else .missing_bound_key;
}

test "keys reference rejects unbound rows and covers every screen key" {
    try std.testing.expectEqual(@as(?ListError, null), listError(.{every}));
    var missing = every;
    missing.meanings.set(.ctrl_x, null);
    try std.testing.expectEqual(@as(?ListError, .unbound_row), listError(.{missing}));
    try std.testing.expectEqual(@as(?ListError, null), listError(.{ missing, every }));
    try std.testing.expectEqual(@as(?ListError, .missing_bound_key), referenceError(list[0 .. list.len - 1], .{every}));
    const duplicate = list ++ .{list[list.len - 1]};
    try std.testing.expectEqual(@as(?ListError, .duplicate_key), referenceError(&duplicate, .{every}));
}

test "keys reference aliases are explicit under their listed rows" {
    try std.testing.expectEqual(@as(usize, 13), list.len);
    for ([_]struct { key: Key, row: []const u8 }{
        .{ .key = .ctrl_g, .row = "esc" },
        .{ .key = .ctrl_d, .row = "ctrl+c" },
        .{ .key = .ctrl_n, .row = "ctrl+p" },
        .{ .key = .shift_up, .row = "↑↓" },
        .{ .key = .shift_down, .row = "↑↓" },
        .{ .key = .page_up, .row = "↑↓" },
        .{ .key = .page_down, .row = "↑↓" },
        .{ .key = .home, .row = "↑↓" },
        .{ .key = .end, .row = "↑↓" },
        .{ .key = .ctrl_end, .row = "↑↓" },
    }) |expected| {
        var found = false;
        for (list) |row| for (row.aliases) |key| if (key == expected.key) {
            try std.testing.expectEqualStrings(expected.row, row.key);
            found = true;
        };
        try std.testing.expect(found);
    }
    var missing_alias = list;
    missing_alias[1].aliases = &.{};
    try std.testing.expectEqual(@as(?ListError, .missing_bound_key), referenceError(&missing_alias, .{every}));
    var duplicate = list;
    duplicate[1].aliases = &.{ .ctrl_g, .escape };
    try std.testing.expectEqual(@as(?ListError, .duplicate_key), referenceError(&duplicate, .{every}));
    duplicate[1].aliases = &.{ .ctrl_g, .ctrl_g };
    try std.testing.expectEqual(@as(?ListError, .duplicate_key), referenceError(&duplicate, .{every}));
    var unbound = every;
    unbound.meanings.set(.ctrl_g, null);
    try std.testing.expectEqual(@as(?ListError, .unbound_row), referenceError(&list, .{unbound}));
}
