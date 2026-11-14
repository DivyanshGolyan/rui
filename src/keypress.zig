//! The one classification of a terminal key, shared by the draft and every
//! choice drawn in its place: the one place a vaxis key meets a `Key`, an
//! edit, text or a refusal. `keymap.zig` owns the values, as a functional
//! core; this shell owns their terminal encodings.
const std = @import("std");
const vaxis = @import("vaxis");
const keymap = @import("keymap.zig");
const Key = keymap.Key;
const Press = keymap.Press;
const Selection = keymap.Selection;
const textScalar = keymap.textScalar;

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
    .left = &.{.{ .code = vaxis.Key.left }},
    .right = &.{.{ .code = vaxis.Key.right }},
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
    // The bare arrows are named keys above; these are their Emacs aliases.
    if (value.matchExact('b', .{ .ctrl = true })) return .{ .edit = .left };
    if (value.matchExact('f', .{ .ctrl = true })) return .{ .edit = .right };
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
        // The bare arrows the screen leaves unbound move the choice.
        .key => |key_name| if (keys.get(key_name)) |action| .{ .action = action } else switch (key_name) {
            .left => .left,
            .right => .right,
            else => .none,
        },
        .enter => .enter,
        // Ctrl-B and Ctrl-F move the draft's caret alone. The draft's other
        // edit keys have no use at a choice; a Ctrl or Alt chord among them
        // is refused like any other.
        .edit => if (pressed.mods.ctrl or pressed.mods.alt or pressed.mods.super or pressed.mods.hyper or pressed.mods.meta) .refused else .none,
        .chord, .control => .refused,
        .text => |text| if (text.len != 0) .text else .none,
        .none => .none,
    };
}

test "a choice takes its arrows and Enter, the screen's keys and typing, and refuses chords" {
    const Name = Key;
    // A screen that leaves the arrows unbound, as the conversation does.
    const keys = comptime blk: {
        var map = keymap.every;
        map.meanings.set(.left, null);
        map.meanings.set(.right, null);
        break :blk map;
    };
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
            const selection = selectEvent(keys, event, events.pasting);
            if (selection != .none) last = selection;
        }
        try std.testing.expectEqual(case.expected, last);
    }
    // An arrow the screen binds is the screen's action, as the list's Right is.
    try std.testing.expectEqual(Selection(Name){ .action = .right }, selectKey(keymap.every, .{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(Selection(Name){ .action = .left }, selectKey(keymap.every, .{ .codepoint = vaxis.Key.left }));
}
