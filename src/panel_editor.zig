//! Editing policy for text fields in a Panel. Callers paint failure on the
//! field's row; neither a refused line nor a rejected paste closes the field.
const std = @import("std");
const vaxis = @import("vaxis");
const Editor = @import("DraftEditor.zig");
const keymap = @import("keymap.zig");

pub fn event(editor: *Editor, input: vaxis.vxfw.Event, pasting: bool, failure: *?[]const u8) Editor.KeyOutcome {
    const outcome = editor.appEvent(keymap.every, input, pasting);
    switch (outcome) {
        .refused => |why| {
            failure.* = " · text couldn't be entered";
            if (why.endsLine()) {
                // A refused line is withheld until Enter. A Panel field
                // keeps its usable text instead of dropping it and edits on;
                // a rejected paste was already rolled back.
                editor.release();
            }
        },
        .append, .redraw, .submit => failure.* = null,
        else => {},
    }
    return outcome;
}

fn text(editor: *Editor, bytes: []const u8, pasting: bool, failure: *?[]const u8) Editor.KeyOutcome {
    return event(editor, .{ .key_press = .{ .codepoint = 'a', .text = bytes } }, pasting, failure);
}

fn press(editor: *Editor, key: u21, failure: *?[]const u8) Editor.KeyOutcome {
    return event(editor, .{ .key_press = .{ .codepoint = key } }, false, failure);
}

test "Panel editor refusal domain keeps usable text and caret then edits and submits" {
    const Fault = enum { typed_overflow, invalid_utf8, invalid_scalar, invalid_paste, paste_overflow, paste_edit_rejected, edit_rejected, unbound };
    for (std.enums.values(Fault)) |fault| {
        errdefer std.debug.print("Panel editor recovery fault={s}\n", .{@tagName(fault)});
        var storage: [32]u8 = undefined;
        var editor: Editor = .initText(&storage, "keptTAIL", 4);
        var failure: ?[]const u8 = null;
        const spaces = @as([33]u8, @splat(' '));
        var outcome: Editor.KeyOutcome = .none;
        switch (fault) {
            .typed_overflow => outcome = text(&editor, &spaces, false, &failure),
            .invalid_utf8 => outcome = text(&editor, "\xff", false, &failure),
            .invalid_scalar => outcome = text(&editor, "z\x01", false, &failure),
            .invalid_paste, .paste_overflow, .paste_edit_rejected => {
                _ = event(&editor, .paste_start, true, &failure);
                _ = text(&editor, switch (fault) {
                    .invalid_paste => "\xff",
                    .paste_overflow => &spaces,
                    .paste_edit_rejected => "ok\n\u{301}",
                    else => unreachable,
                }, true, &failure);
                outcome = event(&editor, .paste_end, false, &failure);
                if (fault != .invalid_paste) {
                    try std.testing.expectEqualStrings("keptTAIL", editor.text());
                    try std.testing.expectEqual(@as(usize, 4), editor.cursor());
                }
            },
            .edit_rejected => {
                editor.setCursor(0);
                outcome = text(&editor, "\u{301}", false, &failure);
            },
            .unbound => outcome = event(&editor, .{ .key_press = .{ .codepoint = 'u', .mods = .{ .alt = true } } }, false, &failure),
        }
        var retained: [32]u8 = undefined;
        const length = editor.text().len;
        @memcpy(retained[0..length], editor.text()[0..length]);
        const caret = editor.cursor();
        if (outcome != .refused) outcome = press(&editor, vaxis.Key.enter, &failure);
        try std.testing.expectEqual(@as(keymap.Refusal, switch (fault) {
            .typed_overflow => .overflow,
            .invalid_utf8, .invalid_scalar, .invalid_paste => .invalid,
            .paste_overflow => .paste_overflow,
            .edit_rejected, .paste_edit_rejected => .edit_rejected,
            .unbound => .unbound,
        }), outcome.refused);
        try std.testing.expectEqualStrings(" · text couldn't be entered", failure.?);
        try std.testing.expectEqualStrings(retained[0..length], editor.text());
        try std.testing.expectEqual(caret, editor.cursor());
        try std.testing.expectEqual(@as(?keymap.Refusal, null), editor.rejected);
        try std.testing.expectEqual(@as(u3, 0), editor.area.partial_length);
        try std.testing.expect(!editor.pasting());
        if (caret == 0) _ = press(&editor, vaxis.Key.right, &failure);
        _ = press(&editor, vaxis.Key.backspace, &failure);
        try std.testing.expectEqual(length - 1, editor.text().len);
        _ = text(&editor, "X", false, &failure);
        try std.testing.expectEqual(length, editor.text().len);
        retained[if (caret == 0) 0 else caret - 1] = 'X';
        try std.testing.expectEqualStrings(retained[0..length], editor.text());
        try std.testing.expectEqual(@as(?[]const u8, null), failure);
        try std.testing.expectEqual(Editor.KeyOutcome.submit, press(&editor, vaxis.Key.enter, &failure));
    }
}
