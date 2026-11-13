//! The keys a screen may bind, each screen's one table of what they do
//! there, and the one classification of a terminal key that the draft and
//! every choice share. Nothing here edits: the draft editor turns a `Key`
//! it has no editing use for into the screen's own action.
const std = @import("std");
const vaxis = @import("vaxis");

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

// Classification: the one place a terminal key meets a `Key`, an edit,
// text or a refusal, shared by the draft and every choice drawn in its
// place.

/// Whether `point` may be text: tab always, a line feed only where a draft
/// takes lines, and no other C0 or C1 control or format character except
/// the zero-width joiner emoji sequences need. A vaxis key code past
/// Unicode, such as the one for a several-scalar cluster, has no category.
pub fn textScalar(point: u21, multiline: bool) bool {
    return !((point < 32 and !(point == '\t' or (multiline and point == '\n'))) or
        (point >= 0x7f and point < 0xa0) or
        (point <= 0x10ffff and vaxis.unicode.generalCategory(point) == .other_format and point != 0x200d));
}

/// Every encoding of every `Key`: the one place a key's name meets the
/// terminal's report of it. Each matches exact modifiers.
const chords = std.enums.EnumArray(Key, []const Chord).init(.{
    // A CSI-u report (Kitty or tmux extended keys) can name Alt-Escape;
    // it still means Esc. Legacy ESC ESC already decodes as Esc.
    .escape = &.{ .{ .code = vaxis.Key.escape }, .{ .code = vaxis.Key.escape, .mods = .{ .alt = true } } },
    .ctrl_c = &.{.{ .code = 'c', .mods = .{ .ctrl = true } }},
    .ctrl_d = &.{.{ .code = 'd', .mods = .{ .ctrl = true } }},
    .ctrl_g = &.{.{ .code = 'g', .mods = .{ .ctrl = true } }},
    .ctrl_n = &.{.{ .code = 'n', .mods = .{ .ctrl = true } }},
    .ctrl_o = &.{.{ .code = 'o', .mods = .{ .ctrl = true } }},
    .ctrl_p = &.{.{ .code = 'p', .mods = .{ .ctrl = true } }},
    .ctrl_r = &.{.{ .code = 'r', .mods = .{ .ctrl = true } }},
    .ctrl_x = &.{.{ .code = 'x', .mods = .{ .ctrl = true } }},
    .alt_a = &.{.{ .code = 'a', .mods = .{ .alt = true } }},
    // Terminals in the alternate screen also deliver mouse wheel and
    // trackpad scrolling as these arrow keys.
    .up = &.{.{ .code = vaxis.Key.up }},
    .down = &.{.{ .code = vaxis.Key.down }},
    .shift_up = &.{.{ .code = vaxis.Key.up, .mods = .{ .shift = true } }},
    .shift_down = &.{.{ .code = vaxis.Key.down, .mods = .{ .shift = true } }},
    .page_up = &.{ .{ .code = vaxis.Key.page_up }, .{ .code = vaxis.Key.page_up, .mods = .{ .shift = true } } },
    .page_down = &.{ .{ .code = vaxis.Key.page_down }, .{ .code = vaxis.Key.page_down, .mods = .{ .shift = true } } },
    .home = &.{.{ .code = vaxis.Key.home }},
    .end = &.{.{ .code = vaxis.Key.end }},
    .ctrl_end = &.{.{ .code = vaxis.Key.end, .mods = .{ .ctrl = true } }},
});
const Chord = struct { code: u21, mods: vaxis.Key.Modifiers = .{} };

pub fn named(value: vaxis.Key) ?Key {
    for (std.enums.values(Key)) |candidate| {
        for (chords.get(candidate)) |chord| if (value.matchExact(chord.code, chord.mods)) return candidate;
    }
    return null;
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

pub fn isEnter(value: vaxis.Key) bool {
    return value.matchExact(vaxis.Key.enter, .{});
}

pub fn classify(value: vaxis.Key) Press {
    // Every binding matches exact modifiers. Vaxis's looser match accepts a
    // key's associated text or shifted key and drops Shift, so Ctrl-Shift-J
    // with text j would send and Shift-Enter with text CR would too.
    if (named(value)) |key_name| return .{ .key = key_name };
    if (isEnter(value)) return .enter;
    if (value.matchExact(vaxis.Key.tab, .{})) return .{ .edit = .tab };
    // Alt-Enter adds a line in every form: Ghostty and other terminals send
    // Shift-Enter as ESC CR, which decodes exactly as Kitty's Alt-Enter.
    if (value.matchExact(vaxis.Key.enter, .{ .shift = true }) or value.matchExact(vaxis.Key.enter, .{ .alt = true }) or value.matchExact('j', .{ .ctrl = true })) return .{ .edit = .newline };
    if (value.matchExact(vaxis.Key.left, .{}) or value.matchExact('b', .{ .ctrl = true })) return .{ .edit = .left };
    if (value.matchExact(vaxis.Key.right, .{}) or value.matchExact('f', .{ .ctrl = true })) return .{ .edit = .right };
    if (value.matchExact('a', .{ .ctrl = true })) return .{ .edit = .line_start };
    if (value.matchExact('e', .{ .ctrl = true })) return .{ .edit = .line_end };
    if (value.matchExact(vaxis.Key.delete, .{})) return .{ .edit = .delete_next };
    if (value.matchExact(vaxis.Key.backspace, .{})) return .{ .edit = .delete_previous };
    if (value.matchExact('u', .{ .ctrl = true })) return .{ .edit = .delete_to_line_start };
    if (value.matchExact('k', .{ .ctrl = true })) return .{ .edit = .delete_to_line_end };
    if (value.matchExact('w', .{ .ctrl = true })) return .{ .edit = .delete_word };
    if (value.matchExact(vaxis.Key.backspace, .{ .alt = true }) or value.matchExact(127, .{ .alt = true })) return .{ .edit = .delete_word_part };
    if (value.matchExact('b', .{ .alt = true }) or value.matchExact(vaxis.Key.left, .{ .alt = true })) return .{ .edit = .word_left };
    if (value.matchExact('f', .{ .alt = true }) or value.matchExact(vaxis.Key.right, .{ .alt = true })) return .{ .edit = .word_right };
    // Any Alt, Super, Hyper or Meta chord the bindings above do not consume,
    // on a character, a control or a named key such as Enter, is dropped
    // whole and reported. Its bare key (ESC . as ".", ESC ^A as Ctrl-A) was
    // never typed, and the draft around it was: an Esc pressed just before
    // a key arrives as one chord.
    if (value.mods.alt or value.mods.super or value.mods.hyper or value.mods.meta) return .chord;
    // An unbound Ctrl key is dropped and reported the same way, the draft
    // kept: vaxis represents C0 controls as Ctrl keys or textless Kitty
    // codepoints, and a typed one is a key, never text.
    const control = value.codepoint < 0x20 and value.codepoint != vaxis.Key.enter and value.codepoint != vaxis.Key.tab and value.codepoint != vaxis.Key.escape;
    if (value.mods.ctrl or control) return .chord;
    if (!textScalar(value.codepoint, false)) return .control;
    if (value.text) |text| return .{ .text = text };
    return .none;
}

/// What an App event does at a choice, with Root's paste flag: paste
/// boundaries and pasted text go to the composer.
pub fn selectEvent(comptime keys: anytype, event: vaxis.vxfw.Event, pasting: bool) Selection(@TypeOf(keys).Action) {
    return switch (event) {
        .paste_start => .text,
        .paste_end => .refused,
        .key_press => |pressed| if (pasting) .text else selectKey(keys, pressed),
        else => .none,
    };
}

pub fn selectKey(comptime keys: anytype, pressed: vaxis.Key) Selection(@TypeOf(keys).Action) {
    return switch (classify(pressed)) {
        .key => |key_name| if (keys.get(key_name)) |action| .{ .action = action } else .none,
        .enter => .enter,
        // Only the bare arrows move a choice: Ctrl-B and Ctrl-F move the
        // draft's caret alone. The draft's other edit keys have no use at a
        // choice; a Ctrl or Alt chord among them is refused like any other.
        .edit => |command| if (pressed.mods.ctrl or pressed.mods.alt or pressed.mods.super or pressed.mods.hyper or pressed.mods.meta) .refused else switch (command) {
            .left => .left,
            .right => .right,
            else => .none,
        },
        .chord, .control => .refused,
        .text => |text| if (text.len != 0) .text else .none,
        .none => .none,
    };
}

test "a choice takes its arrows and Enter, the screen's keys and typing, and refuses chords" {
    const Name = Key;
    const AppEvents = @import("testing/app_events.zig").Events;
    const Case = struct { bytes: []const u8, expected: Selection(Name) };
    for ([_]Case{
        .{ .bytes = "\x1b[D", .expected = .left },
        .{ .bytes = "\x1b[C", .expected = .right },
        .{ .bytes = "\r", .expected = .enter },
        .{ .bytes = "\x1b[A", .expected = .{ .action = .up } },
        .{ .bytes = "\x1b[6~", .expected = .{ .action = .page_down } },
        .{ .bytes = "\x07", .expected = .{ .action = .ctrl_g } },
        .{ .bytes = "\x12", .expected = .{ .action = .ctrl_r } },
        .{ .bytes = "a", .expected = .text },
        .{ .bytes = "/", .expected = .text },
        .{ .bytes = "\xc3\xa9", .expected = .text },
        .{ .bytes = "\x1b[200~", .expected = .text },
        .{ .bytes = "\x1ba", .expected = .{ .action = .alt_a } },
        .{ .bytes = "\x1b[97;3u", .expected = .{ .action = .alt_a } },
        .{ .bytes = "\x1b[27;3;97~", .expected = .{ .action = .alt_a } },
        .{ .bytes = "\x1bu", .expected = .refused },
        .{ .bytes = "\x1c", .expected = .refused },
        .{ .bytes = "\x1b[113;5u", .expected = .refused },
        // The draft's other edit keys have no use at a choice; a chord
        // among them is refused.
        .{ .bytes = "\x01", .expected = .refused },
        .{ .bytes = "\x1b[1;3D", .expected = .refused },
        // Ctrl-B and Ctrl-F move the draft's caret, never the choice, in
        // raw, Kitty and modifyOtherKeys form.
        .{ .bytes = "\x02", .expected = .refused },
        .{ .bytes = "\x06", .expected = .refused },
        .{ .bytes = "\x1b[98;5u", .expected = .refused },
        .{ .bytes = "\x1b[102;5u", .expected = .refused },
        .{ .bytes = "\x1b[27;5;98~", .expected = .refused },
        .{ .bytes = "\x1b[27;5;102~", .expected = .refused },
        .{ .bytes = "\x1b\x7f", .expected = .refused },
        .{ .bytes = "\x7f", .expected = .none },
        .{ .bytes = "\t", .expected = .none },
    }) |case| {
        errdefer std.debug.print("bytes={any}\n", .{case.bytes});
        var events: AppEvents = .init(case.bytes);
        var last: Selection(Name) = .none;
        while (events.next()) |event| {
            const selection = selectEvent(every, event, events.pasting);
            if (selection != .none) last = selection;
        }
        try std.testing.expectEqual(case.expected, last);
    }
}

/// Every key as itself, for tests of an editor without a screen.
pub const every: Keymap(Key) = blk: {
    var map: Keymap(Key) = .{ .meanings = .initFill(null) };
    for (std.enums.values(Key)) |key| map.meanings.set(key, key);
    break :blk map;
};

/// The app's one reference list, in pairs across a fitting panel. Each
/// screen key is represented directly or explicitly grouped under a listed
/// key as an alias. Empty `keys` name input handled separately from `Key`.
pub const Reference = struct {
    key: []const u8,
    meaning: []const u8,
    keys: []const Key = &.{},
    aliases: []const Key = &.{},
};

pub const list = [_]Reference{
    .{ .key = "enter", .meaning = "open / send" },
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

test "keys reference gives Enter both its list and chat meanings" {
    try std.testing.expectEqualStrings("enter", list[0].key);
    try std.testing.expectEqualStrings("open / send", list[0].meaning);
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
