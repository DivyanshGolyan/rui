//! The draft: libvaxis's TextArea over a caller's bank, with Rui's meanings.
//! TextArea owns the bytes, the caret, Unicode boundaries, the paste
//! transaction and wrapping. This adapter owns what each key means, Tab's
//! completion, the refusal that withholds a line until Enter, and the count
//! of edits its owners compare. It calls TextArea's actions itself
//! (`bindings = .none`); nothing else edits the draft.
const std = @import("std");
const vaxis = @import("vaxis");
const TextArea = vaxis.vxfw.TextArea;
const keymap = @import("keymap.zig");
const Key = keymap.Key;
const Editor = @This();

area: TextArea,
/// What a typed Tab adds to the draft at its end in place of a tab. Null by
/// default: a screen with commands sets it.
completion: ?Completion = null,
/// Why the line is withheld until Enter, which reports it. It withholds
/// edits, never changes what a key means.
rejected: ?keymap.Refusal = null,
/// Counts changes to the draft's bytes or its rejection. A caret move
/// changes neither.
edits: u32 = 0,
/// The current marked paste began at the draft's end, so its text appends.
paste_appends: bool = false,

/// What an input did before any screen's table: an edit, or, as `action`,
/// a `Key` the editor had no use for. `appEvent` gives that key the
/// screen's meaning.
pub const KeyOutcome = keymap.Outcome(Key);

/// An empty draft in `buffer`, which it borrows for its lifetime.
pub fn init(buffer: []u8) Editor {
    var area: TextArea = .init(buffer);
    area.bindings = .none;
    area.acceptScalar = acceptScalar;
    return .{ .area = area };
}

/// A draft of `bytes` with the caret at byte `caret`, which must be text the
/// draft accepts with the caret on a character's boundary.
pub fn initText(buffer: []u8, bytes: []const u8, caret: usize) Editor {
    var editor: Editor = .init(buffer);
    std.debug.assert(editor.set(bytes, caret) == null);
    return editor;
}

/// Rui's text beyond TextArea's own UTF-8 and control checks: no format
/// character except the zero-width joiner. Where a line feed is text is
/// decided before insertion.
fn acceptScalar(_: ?*anyopaque, point: u21) bool {
    return keymap.textScalar(point, true);
}

/// The draft's bytes, borrowed until it next changes.
pub fn text(self: *const Editor) []const u8 {
    return self.area.text();
}

/// The caret's byte offset, always between characters.
pub fn cursor(self: *const Editor) usize {
    return self.area.byteOffsetToCursor();
}

/// Moves the caret to byte `at`, which must lie between characters.
pub fn setCursor(self: *Editor, at: usize) void {
    std.debug.assert(self.area.setCursor(at).failure == null);
}

/// Replaces the whole draft with `bytes`, the caret at `caret`, keeping the
/// refusal and paste state. Null when it did; otherwise why the draft
/// stays as it was. `bytes` may lie in the draft's own bank.
pub fn set(self: *Editor, bytes: []const u8, caret: usize) ?TextArea.Failure {
    const result = self.area.setText(bytes, caret);
    self.edits +%= @truncate(result.edit_count);
    return result.failure;
}

/// Puts back `bytes` and `caret` that a caller saved before an input it
/// undoes, as a filter that matched nothing does. Inside a paste, the rest of
/// the paste still follows at the caret.
pub fn revert(self: *Editor, bytes: []const u8, caret: usize) void {
    const pasting_now = self.pasting();
    if (pasting_now) _ = self.area.apply(.{ .endPaste = .explicit });
    std.debug.assert(self.set(bytes, caret) == null);
    if (pasting_now) _ = self.beginPaste();
}

/// This editor saw the current marked paste begin. A replacement editor
/// receiving the rest of a paste rejects it rather than adopting it.
pub fn pasting(self: *const Editor) bool {
    return self.area.paste_state != null;
}

/// A screen hiding its composer closes the edit at the bytes already shown.
/// Root still owns the terminal's paste flag: the remaining paste must not
/// reach a new composer or become a permission choice.
pub fn blur(self: *Editor) KeyOutcome {
    if (!self.pasting()) return .none;
    return self.finishPaste(.focus_loss);
}

/// App delivers paste boundaries through Root before the focused screen.
/// Only the editor that received the start may accept pasted text. A screen
/// calls blur before hiding its composer, retaining the prefix shown then.
pub fn appEvent(self: *Editor, comptime keys: anytype, event: vaxis.vxfw.Event, pasting_now: bool) keymap.Outcome(@TypeOf(keys).Action) {
    const outcome: KeyOutcome = switch (event) {
        .focus_out => self.blur(),
        .paste_start => self.beginPaste(),
        .paste_end => if (self.pasting()) self.finishPaste(.marker) else .none,
        .key_press => |pressed| if (pasting_now and !self.pasting()) .none else if (pasting_now) self.paste(pressed) else if (pressed.text != null and !std.unicode.utf8ValidateSlice(pressed.text.?)) blk: {
            // Vaxis decodes whole characters and reports malformed bytes as
            // U+FFFD carrying them; as text they would wait for a character
            // that never comes and swallow every key after.
            self.reject(.invalid);
            break :blk .none;
        } else self.key(pressed),
        else => .none,
    };
    const Outcome = keymap.Outcome(@TypeOf(keys).Action);
    return switch (outcome) {
        .action => |name| if (keys.get(name)) |action| .{ .action = action } else .none,
        inline else => |payload, tag| @unionInit(Outcome, @tagName(tag), payload),
    };
}

/// A paste start inside a paste marks a new start: what came before stays.
fn beginPaste(self: *Editor) KeyOutcome {
    if (self.pasting()) _ = self.area.apply(.{ .endPaste = .marker });
    self.paste_appends = self.cursor() == self.text().len;
    _ = self.area.apply(.beginPaste);
    return .none;
}

fn finishPaste(self: *Editor, reason: TextArea.EndReason) KeyOutcome {
    _ = self.area.apply(.{ .endPaste = reason });
    if (self.rejected == .edit_rejected or self.rejected == .paste_overflow) {
        const why = self.rejected.?;
        self.rejected = null;
        return .{ .refused = why };
    }
    return .none;
}

/// One pasted key: its text, a CR or LF line break, or a tab. Any other
/// key is not text and rejects the line.
fn paste(self: *Editor, value: vaxis.Key) KeyOutcome {
    if (self.rejected != null) return .none;
    // Terminals send a pasted line break as CR; a CRLF clipboard sends
    // both, which TextArea counts as one line break.
    const bytes: []const u8 = if (value.matchExact(vaxis.Key.enter, .{}))
        "\r"
    else if (value.matchExact('j', .{ .ctrl = true }))
        "\n"
    else if (value.matchExact(vaxis.Key.tab, .{}))
        "\t"
    else
        value.text orelse {
            self.reject(.invalid);
            return .none;
        };
    return self.settle(self.area.apply(.{ .feedPaste = bytes }), self.paste_appends);
}

/// Withholds the line until its Enter, which reports it invalid: for a key a
/// screen must let through neither as text nor as an action.
pub fn refuse(self: *Editor) void {
    self.reject(.invalid);
}

/// Drops the refusal that withholds the line and keeps its text, for a field
/// that keeps usable text after Enter reports it.
pub fn release(self: *Editor) void {
    self.rejected = null;
    self.edits +%= 1;
}

fn reject(self: *Editor, reason: keymap.Refusal) void {
    if (self.rejected != null) return;
    self.rejected = reason;
    self.edits +%= 1;
}

/// Counts what TextArea did and maps its failure to Rui's refusal: a typed
/// overflow or invalid text withholds the line; a paste that cannot fit or
/// be drawn was rolled back and is reported at its end; a typed character
/// that cannot be drawn alone is refused at once.
fn settle(self: *Editor, result: TextArea.Result, at_end: bool) KeyOutcome {
    self.edits +%= @truncate(result.edit_count);
    const pasted = result.origin == .paste;
    if (result.failure) |failure| switch (failure) {
        .capacity => self.reject(if (pasted) .paste_overflow else .overflow),
        .unrenderable => if (pasted) self.reject(.edit_rejected) else return .{ .refused = .edit_rejected },
        .invalid_utf8, .invalid_scalar, .invalid_range, .paste_not_started, .paste_active => self.reject(.invalid),
    };
    if (result.edit_count != 0) return if (at_end) .append else .redraw;
    return if (result.cursor_changed) .redraw else .none;
}

fn key(self: *Editor, value: vaxis.Key) KeyOutcome {
    // Root's paste ended without reaching this editor: close its own.
    if (self.pasting()) _ = self.finishPaste(.explicit);
    const press = keymap.classify(value);
    switch (press) {
        .key => |key_name| return self.edit(key_name) orelse .{ .action = key_name },
        .enter => return if (self.rejected) |why| .{ .refused = why } else .submit,
        else => {},
    }
    if (self.rejected != null) return .none;
    return switch (press) {
        .key, .enter => unreachable,
        .edit => |command| switch (command) {
            .tab => self.tab(),
            .newline => self.insert("\n", true),
            .left => self.act(.left),
            .right => self.act(.right),
            .line_start => self.act(.line_start),
            .line_end => self.act(.line_end),
            .delete_next => self.act(.delete_next),
            .delete_previous => self.act(.delete_previous),
            .delete_to_line_start => self.act(.delete_to_line_start),
            .delete_to_line_end => self.act(.delete_to_line_end),
            .delete_word => self.act(.delete_word),
            .delete_word_part => self.act(.delete_word_part),
            .word_left => self.act(.word_left),
            .word_right => self.act(.word_right),
        },
        .chord => .{ .refused = .unbound },
        .control => blk: {
            self.reject(.invalid);
            break :blk .none;
        },
        .text => |typed| self.insert(typed, false),
        .none => .none,
    };
}

/// The one rule for when the editor has a use for a `Key`: the edit it
/// makes, or null when the draft gives it none and the screen's table
/// decides. It reads the draft's shape only, so a rejected line changes no
/// key's meaning; there the edit does nothing, as every edit does.
fn edit(self: *Editor, key_name: Key) ?KeyOutcome {
    const bytes = self.text();
    const at = self.cursor();
    return switch (key_name) {
        .up => if (std.mem.lastIndexOfScalar(u8, bytes[0..at], '\n') == null) null else self.act(.up),
        .down => if (std.mem.indexOfScalarPos(u8, bytes, at, '\n') == null) null else self.act(.down),
        .home => if (bytes.len == 0) null else self.act(.line_start),
        .end => if (bytes.len == 0) null else self.act(.line_end),
        .ctrl_d => if (bytes.len == 0) null else self.act(.delete_next),
        .escape, .ctrl_c, .ctrl_g, .ctrl_n, .ctrl_o, .ctrl_p, .ctrl_r, .ctrl_x, .alt_a, .shift_up, .shift_down, .page_up, .page_down, .ctrl_end => null,
    };
}

fn act(self: *Editor, action: TextArea.Action) KeyOutcome {
    if (self.rejected != null) return .none;
    return self.settle(self.area.apply(action), false);
}

/// Typed or completed text at the caret. A line feed is text only where the
/// draft takes lines (`multiline`); elsewhere it rejects the line after the
/// text before it.
fn insert(self: *Editor, bytes: []const u8, multiline: bool) KeyOutcome {
    if (self.rejected != null) return .none;
    const line = if (multiline) null else std.mem.indexOfScalar(u8, bytes, '\n');
    const at_end = self.cursor() == self.text().len;
    const outcome = self.settle(self.area.apply(.{ .insert = .{ .bytes = bytes[0 .. line orelse bytes.len], .origin = .typed } }), at_end);
    if (line != null and outcome != .refused) self.reject(.invalid);
    return outcome;
}

/// A screen's Tab: the edit it makes to `draft` with the caret at `caret`,
/// or null to add the tab.
pub const Completion = struct {
    context: *const anyopaque,
    add: *const fn (context: *const anyopaque, draft: []const u8, caret: usize) ?Replacement,
};

/// What Tab does to the draft: `text` in place of `draft[start..end]`, the
/// caret after it.
pub const Replacement = struct {
    start: usize,
    end: usize,
    text: []const u8,

    /// `text` added at the end of `draft`, as a command word completes.
    pub fn append(draft: []const u8, text_: []const u8) Replacement {
        return .{ .start = draft.len, .end = draft.len, .text = text_ };
    }
};

/// Completes a clean draft; a partial character or a rejected draft takes
/// the tab as it always did.
fn tab(self: *Editor) KeyOutcome {
    const completion = self.completion orelse return self.insert("\t", false);
    if (self.area.partial_length != 0 or self.rejected != null) return self.insert("\t", false);
    const completed = completion.add(completion.context, self.text(), self.cursor()) orelse return self.insert("\t", false);
    return self.replace(completed);
}

/// Puts `change`'s text in place of its range, the caret after it. A change
/// at the draft's end is an append; one that would overflow the draft is
/// refused whole and leaves the draft as it was, as is a range that would
/// split a character.
pub fn replace(self: *Editor, change: Replacement) KeyOutcome {
    const length = self.text().len;
    std.debug.assert(change.start <= change.end and change.end <= length);
    if (change.start == length) return self.append(change.text);
    if (length - (change.end - change.start) + change.text.len > self.area.buffer.len) return .{ .refused = .overflow };
    if (self.rejected) |why| return .{ .refused = why };
    const line = std.mem.indexOfScalar(u8, change.text, '\n');
    const result = self.area.replace(.{ .start = change.start, .end = change.end }, change.text[0 .. line orelse change.text.len]);
    if (result.failure == .invalid_range) return .{ .refused = .edit_rejected };
    const outcome = self.settle(result, false);
    if (line != null and outcome != .refused) self.reject(.invalid);
    if (self.rejected) |why| return .{ .refused = why };
    return if (outcome == .refused) outcome else .redraw;
}

/// Adds `text` at the draft's end, the caret after it, as Tab's completion
/// does.
pub fn append(self: *Editor, text_: []const u8) KeyOutcome {
    if (text_.len == 0) return .none;
    _ = self.area.apply(.buffer_end);
    const outcome = self.insert(text_, false);
    // A rejected draft, one this text overflowed among them, never runs.
    if (self.rejected) |why| return .{ .refused = why };
    return if (outcome == .append) .redraw else outcome;
}

const AppEvents = @import("testing/app_events.zig").Events;

/// Terminal bytes through vaxis's Parser and `appEvent`, as App delivers
/// them to a lone editor (tests), with Root's paste flag kept across sends.
/// Each key the editor has no use for comes back as itself.
const Typing = struct {
    pasting: bool = false,

    /// The last outcome of `bytes` that is not `.none`.
    fn send(self: *Typing, editor: *Editor, bytes: []const u8) KeyOutcome {
        var events: AppEvents = .init(bytes);
        events.pasting = self.pasting;
        defer self.pasting = events.pasting;
        var last: KeyOutcome = .none;
        while (events.next()) |event| {
            const outcome = editor.appEvent(keymap.every, event, events.pasting);
            if (outcome != .none) last = outcome;
        }
        return last;
    }
};

test "modified kitty text cannot become an ordinary permission choice" {
    var storage: [64]u8 = undefined;
    for ([_]u8{ 3, 9, 17, 33, 57 }) |modifier| {
        for ([_][]const u8{ "", ";97" }) |associated| {
            var sequence: [32]u8 = undefined;
            const input = try std.fmt.bufPrint(&sequence, "\x1b[97;{d}{s}u", .{ modifier, associated });
            var editor: Editor = .init(&storage);
            var stream: Typing = .{};
            var event: KeyOutcome = .none;
            event = stream.send(&editor, input);
            const expected: KeyOutcome = if (modifier == 3) .{ .action = .alt_a } else .{ .refused = .unbound };
            try std.testing.expectEqual(expected, event);
            try std.testing.expectEqual(@as(usize, 0), editor.text().len);
            try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
        }
    }
    for ([_]u8{ 1, 2, 65, 129 }) |modifier| {
        var sequence: [32]u8 = undefined;
        const input = try std.fmt.bufPrint(&sequence, "\x1b[97;{d};97u", .{modifier});
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, input);
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
        try std.testing.expectEqualStrings("a", editor.text());
    }
}

test "unknown terminal sequences add no event and do not reject typed text" {
    var storage: [64]u8 = undefined;
    for ([_][]const u8{ "\x1b[1114112u", "\x1b[27;2;1114112~" }) |sequence| {
        errdefer std.debug.print("sequence={any}\n", .{sequence});
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "one");
        try std.testing.expectEqual(KeyOutcome.none, stream.send(&editor, sequence));
        try std.testing.expectEqual(@as(?keymap.Refusal, null), editor.rejected);
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "two\r"));
        try std.testing.expectEqualStrings("onetwo", editor.text());
    }
}

test "marked paste rejects encoded controls without releasing paste custody" {
    var storage: [64]u8 = undefined;
    for ([_][]const u8{
        "\x1b[123;4~", "\x1b[0;1:3u", "\x1b[97;1;98u",  "\x1b[200~",
        "\x1b[201x",   "\x1b[20~",    "\x1b]title\x07", "\x1bOQ",
        "\x1b_print",  "\x1bx",
    }) |sequence| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "\x1b[200~left");
        _ = stream.send(&editor, sequence);
        _ = stream.send(&editor, "\n");
        _ = stream.send(&editor, "right\x7f\x1b[201~");
        try std.testing.expectEqual(KeyOutcome{ .refused = .invalid }, stream.send(&editor, "\r"));
    }
}

test "renderer declines standalone zero-width edits and rolls back an unrepresentable paste" {
    var storage: [256]u8 = undefined;
    for ([_][]const u8{ "\u{301}", "\u{200d}", "\u{fe0f}" }) |scalar| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "kept\x01");
        var event: KeyOutcome = .none;
        event = stream.send(&editor, scalar);
        try std.testing.expectEqual(KeyOutcome{ .refused = .edit_rejected }, event);
        try std.testing.expectEqualStrings("kept", editor.text());
        try std.testing.expectEqual(@as(usize, 0), editor.cursor());
        // Roll back a whole paste, including accepted text before a newline,
        // while retaining both the pre-paste prefix and suffix.
        _ = stream.send(&editor, "\x1b[200~pasted\n");
        _ = stream.send(&editor, scalar);
        event = stream.send(&editor, "discarded\x1b[201~");
        try std.testing.expectEqual(KeyOutcome{ .refused = .edit_rejected }, event);
        try std.testing.expectEqualStrings("kept", editor.text());
        try std.testing.expectEqual(@as(usize, 0), editor.cursor());
        _ = stream.send(&editor, "é🧑‍🌾");
        try std.testing.expectEqualStrings("é🧑‍🌾kept", editor.text());
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
    }
}

test "App paste cannot follow focus into another composer or resume a hidden edit" {
    const keys: keymap.Keymap(void) = comptime .{ .meanings = .initFill(null) };
    var original_storage: [32]u8 = undefined;
    var original: Editor = .initText(&original_storage, "headTAIL", 4);
    var other_storage: [32]u8 = undefined;
    var other: Editor = .initText(&other_storage, "other", 2);
    _ = original.appEvent(keys, .paste_start, true);
    _ = original.appEvent(keys, .{ .key_press = .{ .codepoint = 0, .text = "12" } }, true);
    _ = original.appEvent(keys, .focus_out, true);
    _ = other.appEvent(keys, .focus_in, true);
    for ([_]*Editor{ &original, &other }) |editor| {
        _ = editor.appEvent(keys, .{ .key_press = .{ .codepoint = 0, .text = "discarded" } }, true);
        _ = editor.appEvent(keys, .paste_end, false);
        try std.testing.expectEqual(.submit, editor.appEvent(keys, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, false));
    }
    try std.testing.expectEqualStrings("head12TAIL", original.text());
    try std.testing.expectEqual(@as(usize, 6), original.cursor());
    try std.testing.expectEqualStrings("other", other.text());
    try std.testing.expectEqual(@as(usize, 2), other.cursor());
}

test "hiding a composer closes its paste before another edit or paste" {
    const keys: keymap.Keymap(void) = comptime .{ .meanings = .initFill(null) };
    for ([_][]const u8{ "12", "123456789" }) |typed| {
        var storage: [16]u8 = undefined;
        var editor: Editor = .initText(&storage, "headTAIL", 4);
        _ = editor.appEvent(keys, .paste_start, true);
        _ = editor.appEvent(keys, .{ .key_press = .{ .codepoint = 0, .text = typed } }, true);
        const outcome = editor.blur();
        if (typed.len == 2) {
            try std.testing.expectEqual(.none, outcome);
            try std.testing.expectEqualStrings("head12TAIL", editor.text());
        } else {
            try std.testing.expectEqual(KeyOutcome{ .refused = .paste_overflow }, outcome);
            try std.testing.expectEqualStrings("headTAIL", editor.text());
        }
        try std.testing.expectEqual(.none, editor.blur());
        _ = editor.appEvent(keys, .paste_start, true);
        _ = editor.appEvent(keys, .{ .key_press = .{ .codepoint = 0, .text = "X" } }, true);
        _ = editor.appEvent(keys, .paste_end, false);
        try std.testing.expectEqualStrings(if (typed.len == 2) "head12XTAIL" else "headXTAIL", editor.text());
        try std.testing.expectEqual(.submit, editor.appEvent(keys, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, false));
    }
}

test "oversized marked paste preserves the draft and caret and accepts the next edit" {
    const keys: keymap.Keymap(void) = comptime .{ .meanings = .initFill(null) };
    for ([_][]const u8{ "1234", "12345", "123🐄" }) |pasted| {
        var storage: [12]u8 = undefined;
        var editor: Editor = .initText(&storage, "headTAIL", 4);
        _ = editor.appEvent(keys, .paste_start, true);
        _ = editor.appEvent(keys, .{ .key_press = .{ .codepoint = 0, .text = pasted } }, true);
        const result = editor.appEvent(keys, .paste_end, false);
        if (pasted.len == 4) {
            try std.testing.expectEqualStrings("head1234TAIL", editor.text());
            try std.testing.expectEqual(@as(usize, 8), editor.cursor());
            try std.testing.expectEqual(.none, result);
        } else {
            try std.testing.expectEqualStrings("headTAIL", editor.text());
            try std.testing.expectEqual(@as(usize, 4), editor.cursor());
            try std.testing.expect(result == .refused and !result.refused.endsLine());
            _ = editor.appEvent(keys, .{ .key_press = .{ .codepoint = 'X', .text = "X" } }, false);
            try std.testing.expectEqualStrings("headXTAIL", editor.text());
        }
        try std.testing.expectEqual(.submit, editor.appEvent(keys, .{ .key_press = .{ .codepoint = vaxis.Key.enter } }, false));
    }
    // A joiner can merge inserted text with the original suffix. Subsequent
    // pasted bytes must still precede that suffix for rollback to preserve it.
    for ([_][]const u8{ "👨‍", "👨‍123456" }) |pasted| {
        var storage: [20]u8 = undefined;
        const original = "L👩TAIL";
        var editor: Editor = .initText(&storage, original, 1);
        _ = editor.appEvent(keys, .paste_start, true);
        _ = editor.appEvent(keys, .{ .key_press = .{ .codepoint = 0, .text = pasted } }, true);
        const result = editor.appEvent(keys, .paste_end, false);
        if (pasted.len == 7) {
            try std.testing.expectEqualStrings("L👨‍👩TAIL", editor.text());
            try std.testing.expectEqual(@as(usize, 12), editor.cursor());
            try std.testing.expectEqual(.none, result);
        } else {
            try std.testing.expectEqualStrings(original, editor.text());
            try std.testing.expectEqual(@as(usize, 1), editor.cursor());
            try std.testing.expectEqual(keymap.Refusal.paste_overflow, result.refused);
        }
    }
}

test "an append that overflows the draft is refused, not cut short" {
    var storage: [8]u8 = undefined;
    var editor: Editor = .init(&storage);
    try std.testing.expectEqual(KeyOutcome.redraw, editor.append("/abc"));
    try std.testing.expectEqual(KeyOutcome{ .refused = .overflow }, editor.append("defgh"));
    try std.testing.expectEqual(KeyOutcome{ .refused = .overflow }, editor.append("x"));
}

test "Tab puts a completion's completed in place of its range, the caret after it, or refuses it whole" {
    const Complete = struct {
        /// Completes the `/re` the caret ends to `/review `.
        fn add(_: *const anyopaque, draft: []const u8, caret: usize) ?Replacement {
            const start = std.mem.lastIndexOfScalar(u8, draft[0..caret], '/') orelse return null;
            return .{ .start = start, .end = caret, .text = "/review " };
        }
        const review: Completion = .{ .context = &{}, .add = add };
    };
    const keys: keymap.Keymap(void) = comptime .{ .meanings = .initFill(null) };
    const press_tab: vaxis.vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.tab } };
    var storage: [24]u8 = undefined;
    var editor: Editor = .initText(&storage, "use /re on it", "use /re".len);
    editor.completion = Complete.review;
    try std.testing.expectEqual(.redraw, editor.appEvent(keys, press_tab, false));
    try std.testing.expectEqualStrings("use /review  on it", editor.text());
    try std.testing.expectEqual("use /review ".len, editor.cursor());
    // Three bytes more than fit: refused whole, the draft and caret unchanged.
    var small: [12]u8 = undefined;
    var full: Editor = .initText(&small, "go /re now", "go /re".len);
    full.completion = Complete.review;
    try std.testing.expectEqual(keymap.Outcome(void){ .refused = .overflow }, full.appEvent(keys, press_tab, false));
    try std.testing.expectEqualStrings("go /re now", full.text());
    try std.testing.expectEqual("go /re".len, full.cursor());
    try std.testing.expectEqual(@as(?keymap.Refusal, null), full.rejected);
}

test "Tab over a partial character or a rejected draft does what it did before completion" {
    const Complete = struct {
        fn add(_: *const anyopaque, draft: []const u8, _: usize) ?Replacement {
            return .append(draft, "atus");
        }
        const status: Completion = .{ .context = &{}, .add = add };
    };
    // A lead byte waiting for the rest of its character, or an invalid byte.
    for ([_][]const u8{ "\xc3", "\xff" }) |state| {
        errdefer std.debug.print("state={any}\n", .{state});
        var storage: [2][64]u8 = undefined;
        var editors = [_]Editor{ .init(&storage[0]), .init(&storage[1]) };
        editors[1].completion = Complete.status;
        for (&editors) |*editor| {
            var stream: Typing = .{};
            _ = stream.send(editor, "/st");
            if (state[0] == 0xff) _ = stream.send(editor, &.{0xff}) else _ = editor.settle(editor.area.apply(.{ .insert = .{ .bytes = state, .origin = .typed } }), false);
            try std.testing.expect(editor.area.partial_length != 0 or editor.rejected != null);
            _ = stream.send(editor, "\t");
        }
        try std.testing.expectEqualStrings(editors[0].text(), editors[1].text());
        try std.testing.expectEqual(editors[0].area.partial_length, editors[1].area.partial_length);
        try std.testing.expectEqual(editors[0].rejected, editors[1].rejected);
    }
}

test "an unbound Alt or Meta chord never inserts its bare character" {
    var storage: [64]u8 = undefined;
    // Legacy ESC prefix (Option as Meta, and tmux's re-encoding of Kitty or
    // modifyOtherKeys chords), Kitty with and without associated text, and
    // Super/Meta bits. Each is dropped, keeping the draft
    // around it, rather than adding ".".
    // Enter with Alt and another modifier is still a dropped chord.
    for ([_][]const u8{ "\x1b\xff", "\x1b.", "\x1b ", "\x1bx", "\x1b[46;3u", "\x1b[46;3;46u", "\x1b[32;3u", "\x1b[46;9u", "\x1b[46;33u", "\x1b[13;4u", "\x1b[13;4;13u", "\x1b[13:13;4u", "\x1b[13;7u", "\x1b[13;9u", "\x1b[1;3A", "\x1b\x00", "\x1b\x01", "\x1b\x12", "\x1b[28;3u", "\x1b[97;7u", "\x1b[27;3;46~", "\x1b[27;3;32~", "\x1b[27;9;46~", "\x1b[27;4;13~" }) |chord| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "o");
        try std.testing.expectEqual(KeyOutcome{ .refused = .unbound }, stream.send(&editor, chord));
        try std.testing.expectEqualStrings("o", editor.text());
        _ = stream.send(&editor, "k");
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
        try std.testing.expectEqualStrings("ok", editor.text());
    }
    // Bound chords, plain text and marked paste keep their meaning.
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    _ = stream.send(&editor, "a. b\x1bb\n\x1b[200~c. d\x1b[201~");
    try std.testing.expectEqualStrings("a. \nc. db", editor.text());
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
}

test "ESC before broken UTF-8 is an ordinary Alt chord and preserves following text" {
    var storage: [64]u8 = undefined;
    for ([_][]const u8{ "\xff", "\xc3", "\xe2\x82" }) |broken| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        var bytes: [32]u8 = undefined;
        const input = try std.fmt.bufPrint(&bytes, "one\x1b{s}two\r", .{broken});
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, input));
        try std.testing.expectEqualStrings("onetwo", editor.text());
        try std.testing.expectEqual(@as(?keymap.Refusal, null), editor.rejected);
    }
}

test "xterm modifyOtherKeys bindings mean what the same Kitty keys mean" {
    var storage: [64]u8 = undefined;
    // Ghostty's legacy table sends Shift-Enter as CSI 27;2;13~ unasked. It
    // adds a line like Kitty's CSI 13;2u; Ctrl-A moves to the line start and Ctrl-J adds a line.
    for ([_][]const u8{ "\x1b[27;2;13~", "\x1b[13;2u", "\x1b[13;2;13u", "\x1b[13:13;2u" }) |shift_enter| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "one");
        try std.testing.expect(stream.send(&editor, shift_enter) != .submit);
        _ = stream.send(&editor, "two");
        try std.testing.expectEqualStrings("one\ntwo", editor.text());
        _ = stream.send(&editor, "\x1b[27;5;97~X");
        try std.testing.expectEqualStrings("one\nXtwo", editor.text());
        try std.testing.expect(stream.send(&editor, "\x1b[27;5;106~") != .submit);
        try std.testing.expectEqualStrings("one\nX\ntwo", editor.text());
    }
}

test "meta-backspace deletes a word without swallowing the next character" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "first second\x1b\x7fZ\r"));
    try std.testing.expectEqualStrings("first Z", editor.text());
}

test "grapheme deletion, distinct word bindings and multiline paste" {
    var storage: [100]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "A中e\u{301}🧑‍🌾\x7f\r"));
    try std.testing.expectEqualStrings("A中e\u{301}", editor.text());

    editor = .init(&storage);
    _ = stream.send(&editor, "ask src/foo-bar\x1b\x7f\r");
    try std.testing.expectEqualStrings("ask src/foo-", editor.text());
    editor = .init(&storage);
    _ = stream.send(&editor, "ask src/foo-bar\x17\r");
    try std.testing.expectEqualStrings("ask ", editor.text());

    editor = .init(&storage);
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\x1b[200~line1\nline2\x1b[201~\r"));
    try std.testing.expectEqualStrings("line1\nline2", editor.text());
    for ([_][]const u8{ "left\tright", "left\x1b[9uright" }) |input| {
        editor = .init(&storage);
        _ = stream.send(&editor, input);
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
        try std.testing.expectEqualStrings("left\tright", editor.text());
    }
    editor = .init(&storage);
    _ = stream.send(&editor, "left\x1b[27uright");
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
    try std.testing.expectEqualStrings("leftright", editor.text());
}

test "exact UTF-8 bound and sticky rejection after backspace" {
    var storage: [65536]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    for (0..65534) |_| _ = stream.send(&editor, "a");
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "é\r"));
    try std.testing.expectEqual(@as(usize, 65536), editor.text().len);
    editor = .init(&storage);
    for (0..65535) |_| _ = stream.send(&editor, "a");
    try std.testing.expectEqual(KeyOutcome{ .refused = .overflow }, stream.send(&editor, "é\x7f\r"));
    try std.testing.expectEqual(@as(usize, 65535), editor.text().len);
}

test "unknown CSI retains following text and malformed UTF-8 still rejects" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\x1b[123;4~Z\r"));
    try std.testing.expectEqualStrings("Z", editor.text());
    editor = .init(&storage);
    try std.testing.expectEqual(KeyOutcome{ .refused = .invalid }, stream.send(&editor, "\xc3(\r"));
    // A Kitty report of a surrogate or a codepoint past Unicode is no key.
    for ([_][]const u8{ "a\x1b[55296u\r", "a\x1b[1114112u\r" }) |input| {
        editor = .init(&storage);
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, input));
        try std.testing.expectEqualStrings("a", editor.text());
    }
    // Alt-A remains a screen action, never the permission choice "a".
    editor = .init(&storage);
    try std.testing.expectEqual(KeyOutcome{ .action = .alt_a }, stream.send(&editor, "\x1ba"));
    try std.testing.expectEqual(@as(usize, 0), editor.text().len);
}

test "inserting a joiner before an emoji leaves the caret at a cluster boundary" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    _ = stream.send(&editor, "🧑🌾\x1b[D\u{200d}");
    try std.testing.expectEqualStrings("🧑‍🌾", editor.text());
    try std.testing.expectEqual(editor.text().len, editor.cursor());
    try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, &.{0x7f}));
    try std.testing.expectEqual(@as(usize, 0), editor.text().len);
}

test "deleting a separator does not leave the caret inside a joined grapheme" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    _ = stream.send(&editor, "\x1b[200~🧑\u{200d}\n🌾\x1b[201~\x01");
    try std.testing.expectEqualStrings("🧑\u{200d}\n🌾", editor.text());
    try std.testing.expectEqual("🧑\u{200d}\n".len, editor.cursor());
    try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, &.{0x7f}));
    try std.testing.expectEqualStrings("🧑‍🌾", editor.text());
    try std.testing.expectEqual(editor.text().len, editor.cursor());
    try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, &.{0x7f}));
    try std.testing.expectEqual(@as(usize, 0), editor.text().len);
}

test "arrows beyond the draft's lines are the screen's keys, not caret moves" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    // Wheel scrolling arrives as arrow keys in the alternate screen.
    var event: KeyOutcome = .none;
    event = stream.send(&editor, "\x1b[A");
    try std.testing.expectEqual(KeyOutcome{ .action = .up }, event);
    _ = stream.send(&editor, "\x1b[200~one\ntwo\x1b[201~");
    event = stream.send(&editor, "\x1b[A");
    try std.testing.expectEqual(KeyOutcome.redraw, event);
    try std.testing.expectEqual(@as(usize, 3), editor.cursor());
    event = stream.send(&editor, "\x1b[A");
    try std.testing.expectEqual(KeyOutcome{ .action = .up }, event);
    event = stream.send(&editor, "\x1b[B");
    try std.testing.expectEqual(KeyOutcome.redraw, event);
    event = stream.send(&editor, "\x1b[B");
    try std.testing.expectEqual(KeyOutcome{ .action = .down }, event);
    for ([_][]const u8{ "\x1b[5~", "\x1b[5;2~" }) |sequence| {
        event = stream.send(&editor, sequence);
        try std.testing.expectEqual(KeyOutcome{ .action = .page_up }, event);
    }
    event = stream.send(&editor, "\x1b[6;2~");
    try std.testing.expectEqual(KeyOutcome{ .action = .page_down }, event);
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
    try std.testing.expectEqualStrings("one\ntwo", editor.text());
}

test "Ctrl-D exits only on an empty draft and otherwise deletes forward" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    try std.testing.expectEqual(KeyOutcome{ .action = .ctrl_d }, stream.send(&editor, &.{4}));
    _ = stream.send(&editor, "ab\x01");
    try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, &.{4}));
    try std.testing.expectEqualStrings("b", editor.text());
    try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, &.{5}));
    try std.testing.expectEqual(KeyOutcome.none, stream.send(&editor, &.{4}));
    try std.testing.expectEqualStrings("b", editor.text());
    try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, &.{0x7f}));
    try std.testing.expectEqual(KeyOutcome{ .action = .ctrl_d }, stream.send(&editor, &.{4}));
}

test "an unbound Ctrl key is dropped and reported, and the draft still sends" {
    var storage: [16]u8 = undefined;
    // Ctrl-T, Ctrl-L, Ctrl-Y, Ctrl-Space (NUL), Ctrl-\ and Kitty's Ctrl-T,
    // NUL and Ctrl-\ forms.
    for ([_][]const u8{ "\x14", "\x0c", "\x19", "\x00", "\x1c", "\x1b[116;5u", "\x1b[0u", "\x1b[28u" }) |key_bytes| {
        errdefer std.debug.print("key={any}\n", .{key_bytes});
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "ok");
        try std.testing.expectEqual(KeyOutcome{ .refused = .unbound }, stream.send(&editor, key_bytes));
        _ = stream.send(&editor, "!");
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
        try std.testing.expectEqualStrings("ok!", editor.text());
    }
}

test "Ctrl-B and Ctrl-F move the caret a character, as readline does" {
    var storage: [16]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    _ = stream.send(&editor, "ab\x02x\x06y");
    try std.testing.expectEqualStrings("axby", editor.text());
    _ = stream.send(&editor, "\x1b[98;5u\x1b[98;5uz\x1b[102;5uw");
    try std.testing.expectEqualStrings("axzbwy", editor.text());
}

test "a key no table binds neither edits nor rejects the line" {
    const nothing = comptime keymap.Keymap(void){ .meanings = .initFill(null) };
    var storage: [16]u8 = undefined;
    for ([_][]const u8{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~", "\x18", "\x1b[120;5u", "\x12", "\x1b[27;5;114~", "\x07", "\x1b[27u", "\x1b[5~", "\x1b[A", "\x1b[1;5F" }) |key_bytes| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "ok");
        var events: AppEvents = .init(key_bytes);
        while (events.next()) |event| try std.testing.expectEqual(keymap.Outcome(void).none, editor.appEvent(nothing, event, events.pasting));
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
        try std.testing.expectEqualStrings("ok", editor.text());
    }
    // A rejected line changes no key's meaning: Ctrl-X still passes.
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    _ = stream.send(&editor, "ok\xc3(");
    try std.testing.expectEqual(KeyOutcome{ .action = .ctrl_x }, stream.send(&editor, &.{0x18}));
    try std.testing.expectEqual(KeyOutcome{ .refused = .invalid }, stream.send(&editor, "\r"));
}

test "flag and variation selector are each deleted as one grapheme" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    _ = stream.send(&editor, "⌚\u{fe0f}🇺🇸");
    try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, &.{0x7f}));
    try std.testing.expectEqualStrings("⌚\u{fe0f}", editor.text());
    try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, &.{0x7f}));
    try std.testing.expectEqual(@as(usize, 0), editor.text().len);
}

test "word movement skips separators and stops at word edges" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    _ = stream.send(&editor, "one two/三");
    try std.testing.expectEqual(KeyOutcome.redraw, editor.act(.word_left));
    try std.testing.expectEqualStrings("三", editor.text()[editor.cursor()..]);
    try std.testing.expectEqual(KeyOutcome.redraw, editor.act(.word_left));
    try std.testing.expectEqualStrings("two/三", editor.text()[editor.cursor()..]);
    try std.testing.expectEqual(KeyOutcome.redraw, editor.act(.word_left));
    try std.testing.expectEqualStrings("one two/三", editor.text()[editor.cursor()..]);
    try std.testing.expectEqual(KeyOutcome.redraw, editor.act(.word_right));
    try std.testing.expectEqualStrings(" two/三", editor.text()[editor.cursor()..]);
    try std.testing.expectEqual(KeyOutcome.redraw, editor.act(.word_right));
    try std.testing.expectEqualStrings("/三", editor.text()[editor.cursor()..]);
}

test "Shift-Enter sent as ESC CR adds a line at the caret, as every Alt-Enter does" {
    var storage: [64]u8 = undefined;
    // ESC CR is Ghostty's Shift-Enter as captured (#538). Kitty and
    // modifyOtherKeys Alt-Enter decode alike.
    for ([_][]const u8{ "\x1b\r", "\x1b[13;3u", "\x1b[13;3;13u", "\x1b[27;3;13~" }) |alt_enter| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "onetwo\x1b[D\x1b[D\x1b[D");
        const event = stream.send(&editor, alt_enter);
        try std.testing.expect(event != .submit and !std.meta.eql(event, KeyOutcome{ .refused = .unbound }));
        try std.testing.expectEqualStrings("one\ntwo", editor.text());
        try std.testing.expectEqual(@as(usize, 4), editor.cursor());
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
    }
}

test "Shift held with a binding's key is never that binding, whatever text the key reports" {
    var storage: [64]u8 = undefined;
    // Kitty may report associated text or a shifted key equal to the base
    // key; neither may hide Shift. Ctrl-Shift-J does not send, Alt-Shift-J
    // and Alt-Shift-Enter add no line, Ctrl-Shift-C does not interrupt.
    for ([_][]const u8{ "\x1b[106;6;106u", "\x1b[106:106;6u", "\x1b[106;4;106u", "\x1b[106:106;4u", "\x1b[13;4;13u", "\x1b[99;6;99u", "\x1b[99:99;6u", "\x1b[13;2;13u" }) |chord| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "ok");
        const event = stream.send(&editor, chord);
        try std.testing.expect(event != .submit and event != .action);
        // Shift-Enter is the one bound Shift chord here: it adds a line.
        const expected: []const u8 = if (std.mem.eql(u8, chord, "\x1b[13;2;13u")) "ok\n" else "ok";
        try std.testing.expectEqualStrings(expected, editor.text());
    }
}
