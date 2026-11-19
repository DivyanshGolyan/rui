const std = @import("std");
const vaxis = @import("vaxis");
const TextArea = vaxis.vxfw.TextArea;
const keymap = @import("keymap.zig");
const keypress = @import("keypress.zig");
const Key = keymap.Key;
const Editor = @This();

area: TextArea,
rejected: ?keymap.Refusal = null,
edits: u32 = 0,
paste_appends: bool = false,
/// Which refusals lock the draft. Set only through `init`/`initLocked`.
/// `every_refusal` locks on any refusal until the owner releases it.
/// `pastes_only` locks only on a refused paste; a typed refusal is only
/// reported through `.refused`. Enter, or a key that changes the text,
/// acknowledges a pastes_only lock.
/// `line_refusals_release` is `every_refusal` except that a refusal this
/// editor returns as `.refused` with a line-ending reason releases at once.
lock: Lock = .every_refusal,

pub const Lock = enum { every_refusal, pastes_only, line_refusals_release };
pub const KeyOutcome = keymap.Outcome(Key);
pub const TextCheck = TextArea.TextCheck;

pub fn init(buffer: []u8) Editor {
    var area: TextArea = .init(buffer);
    area.bindings = .none;
    area.acceptScalar = acceptScalar;
    return .{ .area = area };
}

/// The lock policy is fixed at construction; the owner never sets `lock` directly.
pub fn initLocked(buffer: []u8, lock: Lock) Editor {
    var editor: Editor = .init(buffer);
    editor.lock = lock;
    return editor;
}

pub fn initText(buffer: []u8, bytes: []const u8, caret: usize) Editor {
    var editor: Editor = .init(buffer);
    std.debug.assert(editor.set(bytes, caret) == null);
    return editor;
}

fn acceptScalar(_: ?*anyopaque, point: u21) bool {
    return keymap.textScalar(point, true);
}

pub fn textCheck() TextCheck {
    return init(&.{}).area.textCheck();
}

pub fn text(self: *const Editor) []const u8 {
    return self.area.text();
}

pub fn cursor(self: *const Editor) usize {
    return self.area.byteOffsetToCursor();
}

pub fn setCursor(self: *Editor, at: usize) void {
    std.debug.assert(self.area.setCursor(at).failure == null);
}

pub fn set(self: *Editor, bytes: []const u8, caret: usize) ?TextArea.Failure {
    const result = self.area.setText(bytes, caret);
    self.edits +%= @truncate(result.edit_count);
    return result.failure;
}

pub fn revert(self: *Editor, bytes: []const u8, caret: usize) void {
    const pasting_now = self.pasting();
    if (pasting_now) _ = self.area.apply(.{ .endPaste = .explicit });
    std.debug.assert(self.set(bytes, caret) == null);
    if (pasting_now) _ = self.beginPaste();
}

pub fn pasting(self: *const Editor) bool {
    return self.area.paste_state != null;
}

pub fn blur(self: *Editor) KeyOutcome {
    if (!self.pasting()) return .none;
    return self.finishPaste(.focus_loss);
}

pub fn appEvent(self: *Editor, comptime keys: anytype, event: vaxis.vxfw.Event, pasting_now: bool) keymap.Outcome(@TypeOf(keys).Action) {
    const outcome: KeyOutcome = switch (event) {
        .focus_out => self.blur(),
        .paste_start => self.beginPaste(),
        .paste_end => if (self.pasting()) self.finishPaste(.marker) else .none,
        .key_press => |pressed| if (pasting_now and !self.pasting()) .none else if (pasting_now) self.paste(pressed) else if (pressed.text != null and !std.unicode.utf8ValidateSlice(pressed.text.?)) blk: {
            // Vaxis decodes whole characters and reports malformed bytes as
            // U+FFFD carrying them; as text they would wait for a character
            // that never comes and swallow every key after.
            self.acknowledgeLock();
            break :blk self.typedRefusal(.invalid);
        } else self.key(pressed),
        else => .none,
    };
    if (self.lock == .line_refusals_release and outcome == .refused and outcome.refused.endsLine()) self.release();
    const Outcome = keymap.Outcome(@TypeOf(keys).Action);
    return switch (outcome) {
        .action => |name| if (keys.get(name)) |action| .{ .action = action } else .none,
        inline else => |payload, tag| @unionInit(Outcome, @tagName(tag), payload),
    };
}

fn beginPaste(self: *Editor) KeyOutcome {
    if (self.pasting()) _ = self.area.apply(.{ .endPaste = .marker });
    self.paste_appends = self.cursor() == self.text().len;
    _ = self.area.apply(.beginPaste);
    return .none;
}

fn finishPaste(self: *Editor, reason: TextArea.EndReason) KeyOutcome {
    _ = self.area.apply(.{ .endPaste = reason });
    if (self.lock == .pastes_only) {
        if (self.rejected) |why| return .{ .refused = why };
        return .none;
    }
    if (self.rejected == .edit_rejected or self.rejected == .paste_overflow) {
        const why = self.rejected.?;
        self.rejected = null;
        return .{ .refused = why };
    }
    return .none;
}

/// A typed refusal under `pastes_only` never locks: it is only reported.
fn typedRefusal(self: *Editor, reason: keymap.Refusal) KeyOutcome {
    if (self.lock == .pastes_only) return .{ .refused = reason };
    self.reject(reason);
    return .none;
}

/// Typed text in a field locked by a refused paste acknowledges it.
fn acknowledgeLock(self: *Editor) void {
    if (self.lock == .pastes_only and self.rejected != null) self.release();
}

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

pub fn release(self: *Editor) void {
    self.rejected = null;
    self.edits +%= 1;
}

fn reject(self: *Editor, reason: keymap.Refusal) void {
    if (self.rejected != null) return;
    self.rejected = reason;
    self.edits +%= 1;
}

fn settle(self: *Editor, result: TextArea.Result, at_end: bool) KeyOutcome {
    self.edits +%= @truncate(result.edit_count);
    const pasted = result.origin == .paste;
    if (result.failure) |failure| {
        const why: keymap.Refusal = switch (failure) {
            .capacity => if (pasted) .paste_overflow else .overflow,
            .unrenderable => .edit_rejected,
            .invalid_utf8, .invalid_scalar, .invalid_range, .paste_not_started, .paste_active => .invalid,
        };
        if (!pasted and failure == .unrenderable) return .{ .refused = why };
        if (!pasted and self.lock == .pastes_only) return .{ .refused = why };
        self.reject(why);
    }
    if (result.edit_count != 0) return if (at_end) .append else .redraw;
    return if (result.cursor_changed) .redraw else .none;
}

fn key(self: *Editor, value: vaxis.Key) KeyOutcome {
    if (self.pasting()) _ = self.finishPaste(.explicit);
    const press = keypress.classify(value);
    if (self.lock == .pastes_only and self.rejected != null and acknowledges(press)) {
        self.release();
        // An acknowledgement always redraws, so the owner drops its transient report.
        if (std.meta.activeTag(press) == .enter) return .redraw;
        const outcome = self.pressKey(press);
        return if (outcome == .none) .redraw else outcome;
    }
    return self.pressKey(press);
}

/// Enter, or a key that changes the text, acknowledges a pastes_only lock. Caret
/// moves do not. An edit that changes nothing (Backspace at the start) still
/// acknowledges, because the person tried to edit.
fn acknowledges(press: keymap.Press) bool {
    return switch (press) {
        .enter, .text, .control => true,
        .edit => |command| changesText(command),
        .key => |key_name| key_name == .ctrl_d,
        .chord, .none => false,
    };
}

fn changesText(command: keymap.Edit) bool {
    return switch (command) {
        .tab, .newline, .delete_next, .delete_previous, .delete_to_line_start, .delete_to_line_end, .delete_word, .delete_word_part => true,
        .left, .right, .line_start, .line_end, .word_left, .word_right => false,
    };
}

fn pressKey(self: *Editor, press: keymap.Press) KeyOutcome {
    switch (press) {
        .key => |key_name| return self.edit(key_name) orelse .{ .action = key_name },
        .enter => return if (self.rejected) |why| .{ .refused = why } else .submit,
        else => {},
    }
    if (self.rejected != null) return .none;
    return switch (press) {
        .key, .enter => unreachable,
        .edit => |command| switch (command) {
            .tab => self.insert("\t", false),
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
        .control => self.typedRefusal(.invalid),
        .text => |typed| self.insert(typed, false),
        .none => .none,
    };
}

fn edit(self: *Editor, key_name: Key) ?KeyOutcome {
    const bytes = self.text();
    const at = self.cursor();
    return switch (key_name) {
        .up => if (std.mem.lastIndexOfScalar(u8, bytes[0..at], '\n') == null) null else self.act(.up),
        .down => if (std.mem.indexOfScalarPos(u8, bytes, at, '\n') == null) null else self.act(.down),
        .home => if (bytes.len == 0) null else self.act(.line_start),
        .end => if (bytes.len == 0) null else self.act(.line_end),
        .ctrl_d => if (bytes.len == 0) null else self.act(.delete_next),
        .left => self.act(.left),
        .right => self.act(.right),
        .escape, .ctrl_c, .ctrl_g, .ctrl_n, .ctrl_o, .ctrl_p, .ctrl_r, .ctrl_x, .alt_a, .alt_up, .alt_down, .tab, .shift_tab, .shift_up, .shift_down, .page_up, .page_down, .ctrl_end => null,
    };
}

fn act(self: *Editor, action: TextArea.Action) KeyOutcome {
    if (self.rejected != null) return .none;
    return self.settle(self.area.apply(action), false);
}

fn insert(self: *Editor, bytes: []const u8, multiline: bool) KeyOutcome {
    if (self.rejected != null) return .none;
    const line = if (multiline) null else std.mem.indexOfScalar(u8, bytes, '\n');
    const at_end = self.cursor() == self.text().len;
    const outcome = self.settle(self.area.apply(.{ .insert = .{ .bytes = bytes[0 .. line orelse bytes.len], .origin = .typed } }), at_end);
    if (line != null and outcome != .refused) {
        if (self.lock == .pastes_only) return .{ .refused = .invalid };
        self.reject(.invalid);
    }
    return outcome;
}

pub fn insertMultiline(self: *Editor, gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!KeyOutcome {
    if (self.rejected) |why| return .{ .refused = why };
    if (self.pasting() or self.area.partial_length != 0) return .{ .refused = .edit_rejected };
    if (bytes.len > self.area.buffer.len - self.text().len) return .{ .refused = .overflow };
    if (bytes.len == 0) return .none;
    const caret = self.cursor();
    const combined = try gpa.alloc(u8, self.text().len + bytes.len);
    defer gpa.free(combined);
    @memcpy(combined[0..caret], self.text()[0..caret]);
    @memcpy(combined[caret..][0..bytes.len], bytes);
    @memcpy(combined[caret + bytes.len ..], self.text()[caret..]);
    if (self.set(combined, caret + bytes.len) != null) return .{ .refused = .edit_rejected };
    return .redraw;
}

pub const Replacement = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

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

pub fn append(self: *Editor, text_: []const u8) KeyOutcome {
    if (text_.len == 0) return .none;
    _ = self.area.apply(.buffer_end);
    const outcome = self.insert(text_, false);
    if (self.rejected) |why| return .{ .refused = why };
    return if (outcome == .append) .redraw else outcome;
}

const AppEvents = @import("testing/app_events.zig").Events;

const Typing = struct {
    pasting: bool = false,

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

test "SUI-12 typed bytes give the draft and caret" {
    const cases = [_]struct { typed: []const u8, text: []const u8, caret: usize }{
        .{ .typed = "first second\x1b\x7fZ", .text = "first Z", .caret = 7 },
        .{ .typed = "A中e\u{301}🧑‍🌾\x7f", .text = "A中e\u{301}", .caret = 7 },
        .{ .typed = "\x1b[200~line1\nline2\x1b[201~", .text = "line1\nline2", .caret = 11 },
        .{ .typed = "\x1b[200~a\n\u{301}\x1b[201~\x01\x7f\x7fZ", .text = "Z", .caret = 1 },
        .{ .typed = "ab\x01\x04\x05\x04", .text = "b", .caret = 1 },
        .{ .typed = "ask src/foo-bar\x17", .text = "ask ", .caret = 4 },
        .{ .typed = "\x1b[123;4~Z", .text = "Z", .caret = 1 },
        .{ .typed = "ok\x1bZ", .text = "ok", .caret = 2 },
        .{ .typed = "abc\x1b[D\x1b[DZ", .text = "aZbc", .caret = 2 },
        .{ .typed = "A中e\u{301}\x1b[DX", .text = "A中Xe\u{301}", .caret = 5 },
        .{ .typed = "\x1b[200~line1\nline2\x1b[201~\x1b[A\x01X", .text = "Xline1\nline2", .caret = 1 },
    };
    for (cases) |case| {
        for (0..case.typed.len + 1) |split| {
            var storage: [128]u8 = undefined;
            var editor: Editor = .init(&storage);
            var safe = split;
            // Keep incomplete UTF-8 and terminal sequences in the input buffer.
            while (safe > 0 and !std.unicode.utf8ValidateSlice(case.typed[0..safe])) safe -= 1;
            if (std.mem.lastIndexOfScalar(u8, case.typed[0..safe], 0x1b)) |esc| {
                if (safe == esc + 1) {
                    safe = esc;
                } else if (case.typed[esc + 1] == '[') {
                    var complete = false;
                    for (case.typed[esc + 2 .. safe]) |byte| {
                        if (byte >= 0x40 and byte <= 0x7e) {
                            complete = true;
                            break;
                        }
                    }
                    if (!complete) safe = esc;
                }
            }
            var events: AppEvents = .init(case.typed[0..safe]);
            while (events.next()) |event| _ = editor.appEvent(keymap.every, event, events.pasting);
            events.bytes = case.typed;
            while (events.next()) |event| _ = editor.appEvent(keymap.every, event, events.pasting);
            try std.testing.expectEqualStrings(case.text, editor.text());
            try std.testing.expectEqual(case.caret, editor.cursor());
            var stream: Typing = .{};
            try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
        }
    }
    var storage: [65536]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    for (0..1000) |_| _ = stream.send(&editor, "a");
    for (0..1000) |_| _ = stream.send(&editor, "\x7f");
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "Z\r"));
    try std.testing.expectEqualStrings("Z", editor.text());
    editor = .init(&storage);
    for (0..500) |_| _ = stream.send(&editor, "e\u{301}");
    for (0..500) |_| _ = stream.send(&editor, "\x7f");
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "Z\r"));
    try std.testing.expectEqualStrings("Z", editor.text());
    editor = .init(&storage);
    for (0..2050) |_| _ = stream.send(&editor, "a");
    for (0..2048) |_| _ = stream.send(&editor, "\x7f");
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
    try std.testing.expectEqualStrings("aa", editor.text());
    for ([_][]const u8{ "\xc3(\r", "\xc3\r" }) |bytes| {
        editor = .init(&storage);
        try std.testing.expectEqual(KeyOutcome{ .refused = .invalid }, stream.send(&editor, bytes));
    }
    editor = .init(&storage);
    for (0..65535) |_| _ = stream.send(&editor, "a");
    try std.testing.expectEqual(@as(usize, 65535), editor.text().len);
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
    _ = stream.send(&editor, "a");
    try std.testing.expectEqual(@as(usize, 65536), editor.text().len);
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
    try std.testing.expectEqual(KeyOutcome{ .refused = .overflow }, stream.send(&editor, "a\x7f\r"));
    try std.testing.expectEqual(@as(usize, 65536), editor.text().len);
    editor = .init(&storage);
    for (0..65534) |_| _ = stream.send(&editor, "a");
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "é\r"));
    try std.testing.expectEqual(@as(usize, 65536), editor.text().len);
    editor = .init(&storage);
    for (0..65535) |_| _ = stream.send(&editor, "a");
    try std.testing.expectEqual(KeyOutcome{ .refused = .overflow }, stream.send(&editor, "é\x7f\r"));
    try std.testing.expectEqual(@as(usize, 65535), editor.text().len);
}

test "SUI-63 DraftEditor lock policy: pastes_only locks only refused pastes; Enter or a text edit acknowledges, a caret move does not" {
    const Fault = enum { typed_invalid_utf8, typed_scalar, typed_overflow, paste_invalid, paste_overflow, paste_edit_rejected };
    const Ack = enum { enter, letter, backspace, backspace_at_start, arrow_left };
    const spaces = @as([33]u8, @splat(' '));
    for ([_]Editor.Lock{ .every_refusal, .pastes_only }) |lock| for (std.enums.values(Fault)) |fault| for (std.enums.values(Ack)) |ack| {
        errdefer std.debug.print("DraftEditor lock={s} fault={s} ack={s}\n", .{ @tagName(lock), @tagName(fault), @tagName(ack) });
        var storage: [32]u8 = undefined;
        var editor: Editor = .initLocked(&storage, lock);
        std.debug.assert(editor.set("keptTAIL", 4) == null);
        const fault_outcome: Editor.KeyOutcome = switch (fault) {
            .typed_invalid_utf8 => editor.appEvent(keymap.every, .{ .key_press = .{ .codepoint = 'x', .text = "\xff" } }, false),
            .typed_scalar => editor.appEvent(keymap.every, .{ .key_press = .{ .codepoint = 'x', .text = "\x01" } }, false),
            .typed_overflow => editor.appEvent(keymap.every, .{ .key_press = .{ .codepoint = 'x', .text = &spaces } }, false),
            .paste_invalid, .paste_overflow, .paste_edit_rejected => blk: {
                const pasted: []const u8 = switch (fault) {
                    .paste_invalid => "\xff",
                    .paste_overflow => &spaces,
                    else => "ok\n\u{301}",
                };
                _ = editor.appEvent(keymap.every, .paste_start, true);
                _ = editor.appEvent(keymap.every, .{ .key_press = .{ .codepoint = 'x', .text = pasted } }, true);
                break :blk editor.appEvent(keymap.every, .paste_end, false);
            },
        };
        const locked = switch (fault) {
            .typed_invalid_utf8, .typed_scalar, .typed_overflow => lock == .every_refusal,
            .paste_invalid => true,
            .paste_overflow, .paste_edit_rejected => lock == .pastes_only,
        };
        const expected_fault: Editor.KeyOutcome = switch (lock) {
            .every_refusal => switch (fault) {
                .paste_overflow => .{ .refused = .paste_overflow },
                .paste_edit_rejected => .{ .refused = .edit_rejected },
                // The bytes that fit are kept, so the edit still reports a redraw.
                .typed_overflow => .redraw,
                else => .none,
            },
            .pastes_only => switch (fault) {
                .typed_invalid_utf8, .typed_scalar, .paste_invalid => .{ .refused = .invalid },
                .typed_overflow => .{ .refused = .overflow },
                .paste_overflow => .{ .refused = .paste_overflow },
                .paste_edit_rejected => .{ .refused = .edit_rejected },
            },
            .line_refusals_release => unreachable,
        };
        try std.testing.expectEqual(expected_fault, fault_outcome);
        try std.testing.expectEqual(locked, editor.rejected != null);
        if (fault != .typed_overflow) try std.testing.expectEqualStrings("keptTAIL", editor.text());

        // The ack is checked against the text as the fault left it: a typed overflow keeps the bytes that fit.
        const retained_len = editor.text().len;
        var retained: [32]u8 = undefined;
        @memcpy(retained[0..retained_len], editor.text());
        if (ack == .backspace_at_start) editor.setCursor(0);
        const caret = editor.cursor();
        const bytes: []const u8 = switch (ack) {
            .enter => "\r",
            .letter => "q",
            .backspace, .backspace_at_start => "\x7f",
            .arrow_left => "\x1b[D",
        };
        var stream: Typing = .{};
        const outcome = stream.send(&editor, bytes);
        // Only pastes_only releases, and only for an acknowledging key; a caret move leaves the lock.
        const acknowledged = locked and lock == .pastes_only and ack != .arrow_left;
        try std.testing.expectEqual(locked and !acknowledged, editor.rejected != null);
        if (acknowledged) switch (ack) {
            .enter => {
                try std.testing.expectEqualStrings(retained[0..retained_len], editor.text());
                try std.testing.expectEqual(caret, editor.cursor());
                try std.testing.expectEqual(Editor.KeyOutcome.redraw, outcome);
            },
            .letter => {
                try std.testing.expectEqual(retained_len + 1, editor.text().len);
                try std.testing.expectEqual(@as(u8, 'q'), editor.text()[caret]);
            },
            .backspace => try std.testing.expectEqual(retained_len - 1, editor.text().len),
            .backspace_at_start => {
                try std.testing.expectEqualStrings(retained[0..retained_len], editor.text());
                try std.testing.expectEqual(Editor.KeyOutcome.redraw, outcome);
            },
            .arrow_left => {},
        } else if (locked) {
            // Nothing else reaches the text or caret while the draft is locked.
            try std.testing.expectEqualStrings(retained[0..retained_len], editor.text());
            try std.testing.expectEqual(caret, editor.cursor());
            if (ack == .enter) try std.testing.expect(outcome == .refused) else try std.testing.expectEqual(Editor.KeyOutcome.none, outcome);
        } else switch (ack) {
            .enter => try std.testing.expectEqual(Editor.KeyOutcome.submit, outcome),
            .letter => if (retained_len < retained.len) {
                try std.testing.expectEqual(retained_len + 1, editor.text().len);
            } else try std.testing.expectEqualStrings(retained[0..retained_len], editor.text()),
            .backspace => if (caret > 0) {
                try std.testing.expectEqual(retained_len - 1, editor.text().len);
            } else try std.testing.expectEqualStrings(retained[0..retained_len], editor.text()),
            .backspace_at_start => try std.testing.expectEqualStrings(retained[0..retained_len], editor.text()),
            .arrow_left => {
                try std.testing.expectEqualStrings(retained[0..retained_len], editor.text());
                try std.testing.expectEqual(caret -| 1, editor.cursor());
            },
        }
    };
}

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

test "replacement puts text in its range, the caret after it, or refuses it whole" {
    var storage: [24]u8 = undefined;
    var editor: Editor = .initText(&storage, "use /re on it", "use /re".len);
    try std.testing.expectEqual(KeyOutcome.redraw, editor.replace(.{ .start = "use ".len, .end = "use /re".len, .text = "/review " }));
    try std.testing.expectEqualStrings("use /review  on it", editor.text());
    try std.testing.expectEqual("use /review ".len, editor.cursor());
    var small: [12]u8 = undefined;
    var full: Editor = .initText(&small, "go /re now", "go /re".len);
    try std.testing.expectEqual(KeyOutcome{ .refused = .overflow }, full.replace(.{ .start = "go ".len, .end = "go /re".len, .text = "/review " }));
    try std.testing.expectEqualStrings("go /re now", full.text());
    try std.testing.expectEqual("go /re".len, full.cursor());
    try std.testing.expectEqual(@as(?keymap.Refusal, null), full.rejected);
}

test "Tab inserts a literal tab at the caret and refuses overflow" {
    for ([_][]const u8{ "\t", "\x1b[9u", "\x1b[9;1u" }) |tab| {
        var storage: [9]u8 = undefined;
        var editor: Editor = .initText(&storage, "aéZ", "aé".len);
        var stream: Typing = .{};
        try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&editor, tab));
        try std.testing.expectEqualStrings("aé\tZ", editor.text());
        try std.testing.expectEqual("aé\t".len, editor.cursor());
        editor.setCursor(editor.text().len);
        try std.testing.expectEqual(KeyOutcome.append, stream.send(&editor, tab));
        try std.testing.expectEqualStrings("aé\tZ\t", editor.text());
        try std.testing.expectEqual(editor.text().len, editor.cursor());

        var small: [4]u8 = undefined;
        var full: Editor = .initText(&small, "aéZ", "aé".len);
        try std.testing.expectEqual(KeyOutcome.none, stream.send(&full, tab));
        try std.testing.expectEqualStrings("aéZ", full.text());
        try std.testing.expectEqual("aé".len, full.cursor());
        try std.testing.expectEqual(@as(?keymap.Refusal, .overflow), full.rejected);
        try std.testing.expectEqual(KeyOutcome{ .refused = .overflow }, stream.send(&full, "\r"));
        full.release();
        try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&full, "\x7f"));
        try std.testing.expectEqual(KeyOutcome.redraw, stream.send(&full, tab));
        try std.testing.expectEqualStrings("a\tZ", full.text());
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&full, "\r"));
    }
}

test "Tab rejects a partial character and preserves a rejected draft" {
    for ([_][]const u8{ "\xc3", "\xff" }) |state| {
        errdefer std.debug.print("state={any}\n", .{state});
        var storage: [64]u8 = undefined;
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "/st");
        if (state[0] == 0xff) _ = stream.send(&editor, state) else _ = editor.settle(editor.area.apply(.{ .insert = .{ .bytes = state, .origin = .typed } }), false);
        try std.testing.expect(editor.area.partial_length != 0 or editor.rejected != null);
        try std.testing.expectEqual(KeyOutcome.none, stream.send(&editor, "\t"));
        try std.testing.expectEqualStrings("/st", editor.text());
        try std.testing.expectEqual(@as(usize, 3), editor.cursor());
        try std.testing.expectEqual(@as(u3, 0), editor.area.partial_length);
        try std.testing.expectEqual(@as(?keymap.Refusal, .invalid), editor.rejected);
        try std.testing.expectEqual(KeyOutcome{ .refused = .invalid }, stream.send(&editor, "\r"));
        editor.release();
        try std.testing.expectEqual(KeyOutcome.append, stream.send(&editor, "\t"));
        try std.testing.expectEqualStrings("/st\t", editor.text());
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
    }
}

test "an unbound Alt or Meta chord never inserts its bare character" {
    var storage: [64]u8 = undefined;
    for ([_][]const u8{ "\x1b\xff", "\x1b.", "\x1b ", "\x1bx", "\x1b[46;3u", "\x1b[46;3;46u", "\x1b[32;3u", "\x1b[46;9u", "\x1b[46;33u", "\x1b[13;4u", "\x1b[13;4;13u", "\x1b[13:13;4u", "\x1b[13;7u", "\x1b[13;9u", "\x1b[1;4A", "\x1b\x00", "\x1b\x01", "\x1b\x12", "\x1b[28;3u", "\x1b[97;7u", "\x1b[27;3;46~", "\x1b[27;3;32~", "\x1b[27;9;46~", "\x1b[27;4;13~" }) |chord| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "o");
        try std.testing.expectEqual(KeyOutcome{ .refused = .unbound }, stream.send(&editor, chord));
        try std.testing.expectEqualStrings("o", editor.text());
        _ = stream.send(&editor, "k");
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\r"));
        try std.testing.expectEqualStrings("ok", editor.text());
    }
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

test "unknown CSI retains following text and malformed UTF-8 still rejects" {
    var storage: [80]u8 = undefined;
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, "\x1b[123;4~Z\r"));
    try std.testing.expectEqualStrings("Z", editor.text());
    editor = .init(&storage);
    try std.testing.expectEqual(KeyOutcome{ .refused = .invalid }, stream.send(&editor, "\xc3(\r"));
    for ([_][]const u8{ "a\x1b[55296u\r", "a\x1b[1114112u\r" }) |input| {
        editor = .init(&storage);
        try std.testing.expectEqual(KeyOutcome.submit, stream.send(&editor, input));
        try std.testing.expectEqualStrings("a", editor.text());
    }
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
    var editor: Editor = .init(&storage);
    var stream: Typing = .{};
    _ = stream.send(&editor, "ok\xc3(");
    try std.testing.expectEqual(KeyOutcome{ .action = .ctrl_x }, stream.send(&editor, &.{0x18}));
    try std.testing.expectEqual(KeyOutcome{ .refused = .invalid }, stream.send(&editor, "\r"));
}

test "a typed or pasted format character other than the joiner rejects the line" {
    var storage: [32]u8 = undefined;
    for ([_][]const u8{ "ok\u{ad}", "\x1b[200~ok\u{feff}x\x1b[201~" }) |input| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, input);
        try std.testing.expectEqualStrings("ok", editor.text());
        try std.testing.expectEqual(KeyOutcome{ .refused = .invalid }, stream.send(&editor, "\r"));
    }
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
    for ([_][]const u8{ "\x1b[106;6;106u", "\x1b[106:106;6u", "\x1b[106;4;106u", "\x1b[106:106;4u", "\x1b[13;4;13u", "\x1b[99;6;99u", "\x1b[99:99;6u", "\x1b[13;2;13u" }) |chord| {
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "ok");
        const event = stream.send(&editor, chord);
        try std.testing.expect(event != .submit and event != .action);
        const expected: []const u8 = if (std.mem.eql(u8, chord, "\x1b[13;2;13u")) "ok\n" else "ok";
        try std.testing.expectEqualStrings(expected, editor.text());
    }
}

test "Option arrows leave a draft intact and return its screen navigation key" {
    for ([_]struct { bytes: []const u8, key: keymap.Key }{
        .{ .bytes = "\x1b[1;3A", .key = .alt_up },
        .{ .bytes = "\x1b[1;3B", .key = .alt_down },
    }) |case| {
        var storage: [64]u8 = undefined;
        var editor: Editor = .init(&storage);
        var stream: Typing = .{};
        _ = stream.send(&editor, "own draft\x1b[D");
        try std.testing.expectEqual(KeyOutcome{ .action = case.key }, stream.send(&editor, case.bytes));
        try std.testing.expectEqualStrings("own draft", editor.text());
        try std.testing.expectEqual(@as(usize, 8), editor.cursor());
    }
}

test "quote insertion is multiline and atomic at an existing caret" {
    var storage: [128]u8 = undefined;
    var editor: Editor = .initText(&storage, "leftRIGHT", 4);
    try std.testing.expectEqual(KeyOutcome.redraw, try editor.insertMultiline(std.testing.allocator, "\n> 雪e\u{301}\n>\n> final\n"));
    try std.testing.expectEqualStrings("left\n> 雪e\u{301}\n>\n> final\nRIGHT", editor.text());
    try std.testing.expectEqual(@as(usize, "left\n> 雪e\u{301}\n>\n> final\n".len), editor.cursor());
    const before = editor.edits;
    const caret = editor.cursor();
    for ([_][]const u8{ "ok\x1bBAD", "ok\xff", "ok\xc3" }) |invalid| {
        try std.testing.expect((try editor.insertMultiline(std.testing.allocator, invalid)) == .refused);
        try std.testing.expectEqualStrings("left\n> 雪e\u{301}\n>\n> final\nRIGHT", editor.text());
        try std.testing.expectEqual(caret, editor.cursor());
        try std.testing.expectEqual(before, editor.edits);
        try std.testing.expectEqual(null, editor.rejected);
    }
    var small: [10]u8 = undefined;
    var full: Editor = .initText(&small, "leftRIGHT", 4);
    try std.testing.expectEqual(KeyOutcome{ .refused = .overflow }, try full.insertMultiline(std.testing.allocator, "\n> a\n"));
    try std.testing.expectEqualStrings("leftRIGHT", full.text());
    try std.testing.expectEqual(@as(usize, 4), full.cursor());
    try std.testing.expectEqual(null, full.rejected);
}

test "quote insertion refuses active paste partial input and rejected drafts without edits" {
    const State = enum { paste, partial, rejected };
    for (std.enums.values(State)) |state| {
        var storage: [64]u8 = undefined;
        var editor: Editor = .initText(&storage, "leftRIGHT", 4);
        switch (state) {
            .paste => {
                _ = editor.appEvent(keymap.every, .paste_start, false);
            },
            .partial => {
                _ = editor.insert("\xc3", true);
            },
            .rejected => {
                _ = editor.insert("\x01", true);
            },
        }
        const before = editor.edits;
        const caret = editor.cursor();
        const refusal = editor.rejected;
        const was_pasting = editor.pasting();
        try std.testing.expect((try editor.insertMultiline(std.testing.allocator, "\n> quote\n")) == .refused);
        try std.testing.expectEqualStrings("leftRIGHT", editor.text());
        try std.testing.expectEqual(caret, editor.cursor());
        try std.testing.expectEqual(before, editor.edits);
        try std.testing.expectEqual(refusal, editor.rejected);
        try std.testing.expectEqual(was_pasting, editor.pasting());
    }
}
