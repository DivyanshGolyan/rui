//! The keys a screen may bind, each screen's one table of what they do
//! there, and the values a terminal key is classified into
//! (`keypress.zig` classifies). Nothing here edits: the draft editor turns
//! a `Key` it has no editing use for into the screen's own action.
const std = @import("std");
const unicode = @import("terminal_unicode");

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
    alt_up,
    alt_down,
    up,
    down,
    /// The bare arrows; the draft moves its caret with them, and a choice
    /// drawn in place of the draft takes any its screen leaves unbound.
    left,
    right,
    /// Tab and Shift-Tab: `app_input.keys` moves focus through the drawn
    /// order with them before any screen sees them.
    tab,
    shift_tab,
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

/// Whether `point` may be text: tab always, a line feed only where a draft
/// takes lines, and no other C0 or C1 control or format character except
/// the zero-width joiner emoji sequences need. A terminal key code past
/// Unicode, such as the one for a several-scalar cluster, has no category.
pub fn textScalar(point: u21, multiline: bool) bool {
    return !((point < 32 and !(point == '\t' or (multiline and point == '\n'))) or
        (point >= 0x7f and point < 0xa0) or
        (point <= 0x10ffff and unicode.generalCategory(point) == .other_format and point != 0x200d));
}

/// An edit the draft makes with a typed key.
pub const Edit = enum { tab, newline, left, right, line_start, line_end, delete_next, delete_previous, delete_to_line_start, delete_to_line_end, delete_word, delete_word_part, word_left, word_right };

/// What one typed (not pasted) key is, before the draft or a choice gives it
/// a use: the one classification both share.
pub const Press = union(enum) {
    /// A named screen key.
    key: Key,
    enter,
    edit: Edit,
    /// An unbound Ctrl, Alt, Super, Hyper or Meta chord or C0 control:
    /// dropped whole and reported.
    chord,
    /// An invalid scalar: never text.
    control,
    text: []const u8,
    none,
};

test "text excludes controls and format characters but keeps the joiner, and a key code past Unicode" {
    for ([_]u21{ 0x00ad, 0x200b, 0x2060, 0xfeff, 0x0600, 0x01, 0x85 }) |point| try std.testing.expect(!textScalar(point, true));
    for ([_]u21{ 0x200d, '\t', 'a', 0x00e9, 0x1f9d1, 0x10ffff + 2 }) |point| try std.testing.expect(textScalar(point, false));
    try std.testing.expect(textScalar('\n', true));
    try std.testing.expect(!textScalar('\n', false));
}

/// Every key as itself, for tests of an editor without a screen.
pub const every: Keymap(Key) = blk: {
    var map: Keymap(Key) = .{ .meanings = .initFill(null) };
    for (std.enums.values(Key)) |key| map.meanings.set(key, key);
    break :blk map;
};

/// Input named by a reference row. Submission, newline editing and the
/// skills trigger are not screen-table keys; naming them here does not
/// change how the editor or command parser classifies them.
pub const ReferenceInput = union(enum) {
    key: Key,
    enter,
    newline,
    slash,
};

/// The app's one reference list, in pairs across a fitting panel. Every row
/// names its inputs, including those handled outside screen keymaps. Screen
/// keys may also be explicitly grouped under a listed key as aliases.
pub const Reference = struct {
    key: []const u8,
    meaning: []const u8,
    keys: []const ReferenceInput = &.{},
    aliases: []const Key = &.{},
};

pub const list = [_]Reference{
    .{ .key = "enter", .meaning = "open / send", .keys = &.{.enter} },
    .{ .key = "esc", .meaning = "back", .keys = &.{ .{ .key = .escape } }, .aliases = &.{.ctrl_g} },
    .{ .key = "⇧enter", .meaning = "new line", .keys = &.{.newline} },
    .{ .key = "tab", .meaning = "next focus", .keys = &.{ .{ .key = .tab } } },
    .{ .key = "⇧tab", .meaning = "previous focus", .keys = &.{ .{ .key = .shift_tab } } },
    .{ .key = "ctrl+x", .meaning = "stop", .keys = &.{ .{ .key = .ctrl_x } } },
    .{ .key = "↑↓", .meaning = "scroll", .keys = &.{ .{ .key = .up }, .{ .key = .down } }, .aliases = &.{ .shift_up, .shift_down, .page_up, .page_down, .home, .end, .ctrl_end } },
    // Left (an empty draft back to the list) and the info panel's actions
    // are handled apart from the screen keymaps, so only Right is checked.
    .{ .key = "←→", .meaning = "list/chat · info actions", .keys = &.{ .{ .key = .right } } },
    .{ .key = "ctrl+o", .meaning = "tool output", .keys = &.{ .{ .key = .ctrl_o } } },
    .{ .key = "ctrl+p", .meaning = "earlier message", .keys = &.{ .{ .key = .ctrl_p } }, .aliases = &.{.ctrl_n} },
    .{ .key = "ctrl+r", .meaning = "retry", .keys = &.{ .{ .key = .ctrl_r } } },
    .{ .key = "/", .meaning = "skills", .keys = &.{.slash} },
    .{ .key = "alt+↑↓", .meaning = "switch chat", .keys = &.{ .{ .key = .alt_up }, .{ .key = .alt_down } } },
    .{ .key = "alt+a", .meaning = "archive", .keys = &.{ .{ .key = .alt_a } } },
    .{ .key = "ctrl+c", .meaning = "leave", .keys = &.{ .{ .key = .ctrl_c } }, .aliases = &.{.ctrl_d} },
};

pub const ListError = enum { empty_row, missing_bound_key, unbound_row, duplicate_key };

/// Check the union: every bound key is listed or explicitly aliased exactly
/// once; neither a row nor an alias can name a key neither screen binds.
/// Every row must name input, even when it is not a screen-table key. The
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
    var other_inputs: std.enums.EnumSet(std.meta.Tag(ReferenceInput)) = .empty;
    for (rows) |row| {
        if (row.keys.len == 0) return .empty_row;
        for (row.keys) |input| switch (input) {
            .key => |key| {
                if (shown.contains(key)) return .duplicate_key;
                if (!bound.contains(key)) return .unbound_row;
                shown.insert(key);
            },
            .enter, .newline, .slash => {
                const tag = std.meta.activeTag(input);
                if (other_inputs.contains(tag)) return .duplicate_key;
                other_inputs.insert(tag);
            },
        };
        for (row.aliases) |key| {
            if (shown.contains(key)) return .duplicate_key;
            if (!bound.contains(key)) return .unbound_row;
            shown.insert(key);
        }
    }
    return if (shown.eql(bound)) null else .missing_bound_key;
}

/// Every key as itself except Left, which no screen's table binds: an
/// empty draft and the info panel take it apart from the tables.
const bindable: Keymap(Key) = blk: {
    var map = every;
    map.meanings.set(.left, null);
    break :blk map;
};

test "keys reference rejects unbound rows and covers every screen key" {
    try std.testing.expectEqual(@as(?ListError, null), listError(.{bindable}));
    var missing = bindable;
    missing.meanings.set(.ctrl_x, null);
    try std.testing.expectEqual(@as(?ListError, .unbound_row), listError(.{missing}));
    try std.testing.expectEqual(@as(?ListError, null), listError(.{ missing, bindable }));
    try std.testing.expectEqual(@as(?ListError, .missing_bound_key), referenceError(list[0 .. list.len - 1], .{bindable}));
    const duplicate = list ++ .{list[list.len - 1]};
    try std.testing.expectEqual(@as(?ListError, .duplicate_key), referenceError(&duplicate, .{bindable}));
}

test "keys reference gives Enter both its list and chat meanings" {
    try std.testing.expectEqualStrings("enter", list[0].key);
    try std.testing.expectEqualStrings("open / send", list[0].meaning);
}

test "keys reference aliases are explicit under their listed rows" {
    try std.testing.expectEqual(@as(usize, 15), list.len);
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
    try std.testing.expectEqual(@as(?ListError, .missing_bound_key), referenceError(&missing_alias, .{bindable}));
    var duplicate = list;
    duplicate[1].aliases = &.{ .ctrl_g, .escape };
    try std.testing.expectEqual(@as(?ListError, .duplicate_key), referenceError(&duplicate, .{bindable}));
    duplicate[1].aliases = &.{ .ctrl_g, .ctrl_g };
    try std.testing.expectEqual(@as(?ListError, .duplicate_key), referenceError(&duplicate, .{bindable}));
    var unbound = bindable;
    unbound.meanings.set(.ctrl_g, null);
    try std.testing.expectEqual(@as(?ListError, .unbound_row), referenceError(&list, .{unbound}));
}


test "every keys reference row names its input including non-table input" {
    for (list, 0..) |row, index| {
        try std.testing.expect(row.keys.len > 0);
        var empty = list;
        empty[index].keys = &.{};
        try std.testing.expectEqual(@as(?ListError, .empty_row), referenceError(&empty, .{bindable}));
    }
    try std.testing.expectEqual(std.meta.Tag(ReferenceInput).enter, std.meta.activeTag(list[0].keys[0]));
    try std.testing.expectEqual(std.meta.Tag(ReferenceInput).newline, std.meta.activeTag(list[2].keys[0]));
    try std.testing.expectEqual(std.meta.Tag(ReferenceInput).slash, std.meta.activeTag(list[11].keys[0]));
    for ([_]usize{ 0, 2, 11 }) |index| {
        const duplicate = list ++ .{list[index]};
        try std.testing.expectEqual(@as(?ListError, .duplicate_key), referenceError(&duplicate, .{bindable}));
    }
}
