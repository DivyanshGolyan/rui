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
    /// The screen's only on an empty draft; with text, Ctrl-D deletes forward.
    ctrl_d,
    ctrl_g,
    ctrl_o,
    ctrl_r,
    ctrl_x,
    /// The screen's only with no draft line in that direction; otherwise
    /// they move the caret.
    up,
    down,
    shift_up,
    shift_down,
    /// With or without Shift.
    page_up,
    page_down,
    /// The screen's only on an empty draft; otherwise they move the caret.
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
        /// Enter on a line rejected earlier because it held input that is
        /// not text. The caller drops the line.
        invalid,
        /// Enter on a line rejected earlier for its length.
        overflow,
        /// A refused edit; the draft stands as it was.
        edit_rejected,
        /// An Alt, Super, Hyper or Meta chord nothing binds, dropped whole.
        unbound,
        action: A,

        /// Enter ended the line, sent or refused. A screen's own keys end
        /// whatever that screen says they end.
        pub fn endsLine(self: @This()) bool {
            return switch (self) {
                .submit, .invalid, .overflow => true,
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
