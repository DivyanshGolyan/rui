//! TD2: wire vectors are protocol examples, outcomes are hand-written editor
//! contracts, not results obtained from another encoding or decoded key.
//! Sources: https://sw.kovidgoyal.net/kitty/keyboard-protocol/#functional-key-definitions
//! https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Alt-and-Meta-Keys
//! Kitty navigation uses CSI letter/tilde, NOT invented PUA CSI-u values.
//! case27 is modifyOtherKeys (including level 3 unmodified characters).
const std = @import("std");
const Input = @import("TerminalInput.zig");
const Editor = @import("TerminalEditor.zig");
const vaxis = @import("vaxis");

const Unavailable = enum {
    // Prefixing an unmodified/Ctrl key with ESC changes it to an Alt chord.
    adds_alt,
    // C0/DEL has no distinct encoding of this modified or functional key.
    no_raw_code,
    // modifyOtherKeys applies to character keys, not the navigation keypad.
    functional_key,
    // Legacy Shift-Enter collapses to CR: that is Enter, not a newline chord.
    collapses_to_enter,
    modifier_not_in_protocol,
};
const Wire = union(enum) { bytes: []const u8, unavailable: Unavailable };
const Lane = enum { legacy, kitty, case27, raw };
// Two public entry points, not two independent decoders: both use vaxis.
const Route = enum { events, inline_editor };
const Case = struct {
    name: []const u8,
    before: []const u8 = "one two!",
    caret: usize = 5,
    after: []const u8 = "one two!",
    cursor: usize = 5,
    event: Editor.Event,
    wires: [4]Wire,
};

fn bytes(value: []const u8) Wire {
    return .{ .bytes = value };
}
const no_alt: Wire = .{ .unavailable = .adds_alt };
const no_raw: Wire = .{ .unavailable = .no_raw_code };
const no_case27: Wire = .{ .unavailable = .functional_key };

// Legacy means ESC-prefix Alt OR standard CSI/SS3 functional keys. Plain
// controls are in raw, never mislabelled as ESC-prefix equivalents.
const cases = [_]Case{
    .{ .name = "Ctrl-C", .event = .interrupt, .wires = .{ no_alt, bytes("\x1b[99;5u"), bytes("\x1b[27;5;99~"), bytes("\x03") } },
    .{ .name = "Ctrl-D deletes forward", .event = .redraw, .after = "one to!", .wires = .{ no_alt, bytes("\x1b[100;5u"), bytes("\x1b[27;5;100~"), bytes("\x04") } },
    .{ .name = "Ctrl-D empty EOF", .before = "", .caret = 0, .after = "", .cursor = 0, .event = .eof, .wires = .{ no_alt, bytes("\x1b[100;5u"), bytes("\x1b[27;5;100~"), bytes("\x04") } },
    .{ .name = "Enter", .event = .submit, .wires = .{ no_alt, bytes("\x1b[13u"), bytes("\x1b[27;1;13~"), bytes("\r") } },
    .{ .name = "Ctrl-J", .event = .submit, .wires = .{ no_alt, bytes("\x1b[106;5u"), bytes("\x1b[27;5;106~"), bytes("\n") } },
    .{ .name = "Escape", .event = .close_view, .wires = .{ no_alt, bytes("\x1b[27u"), bytes("\x1b[27;1;27~"), bytes("\x1b") } },
    .{ .name = "Alt-Escape", .event = .close_view, .wires = .{ bytes("\x1b\x1b"), bytes("\x1b[27;3u"), bytes("\x1b[27;3;27~"), no_raw } },
    .{ .name = "Tab", .event = .redraw, .after = "one t\two!", .cursor = 6, .wires = .{ no_alt, bytes("\x1b[9u"), bytes("\x1b[27;1;9~"), bytes("\t") } },
    .{ .name = "Shift-Enter", .event = .redraw, .after = "one t\nwo!", .cursor = 6, .wires = .{ .{ .unavailable = .collapses_to_enter }, bytes("\x1b[13;2u"), bytes("\x1b[27;2;13~"), no_raw } },
    .{ .name = "Alt-J", .event = .redraw, .after = "one t\nwo!", .cursor = 6, .wires = .{ bytes("\x1bj"), bytes("\x1b[106;3u"), bytes("\x1b[27;3;106~"), no_raw } },
    .{ .name = "PgUp", .event = .page_up, .wires = .{ bytes("\x1b[5~"), bytes("\x1b[5;1~"), no_case27, no_raw } },
    .{ .name = "Shift-PgUp", .event = .page_up, .wires = .{ bytes("\x1b[5;2~"), bytes("\x1b[5;2~"), no_case27, no_raw } },
    .{ .name = "PgDn", .event = .page_down, .wires = .{ bytes("\x1b[6~"), bytes("\x1b[6;1~"), no_case27, no_raw } },
    .{ .name = "Shift-PgDn", .event = .page_down, .wires = .{ bytes("\x1b[6;2~"), bytes("\x1b[6;2~"), no_case27, no_raw } },
    .{ .name = "Shift-Up", .event = .scroll_up, .wires = .{ bytes("\x1b[1;2A"), bytes("\x1b[1;2A"), no_case27, no_raw } },
    .{ .name = "Shift-Down", .event = .scroll_down, .wires = .{ bytes("\x1b[1;2B"), bytes("\x1b[1;2B"), no_case27, no_raw } },
    .{ .name = "Ctrl-End", .event = .latest, .wires = .{ bytes("\x1b[1;5F"), bytes("\x1b[8;5~"), no_case27, no_raw } },
    .{ .name = "Ctrl-G", .event = .close_view, .wires = .{ no_alt, bytes("\x1b[103;5u"), bytes("\x1b[27;5;103~"), bytes("\x07") } },
    .{ .name = "Ctrl-O", .event = .expand, .wires = .{ no_alt, bytes("\x1b[111;5u"), bytes("\x1b[27;5;111~"), bytes("\x0f") } },
    .{ .name = "Left", .event = .redraw, .cursor = 4, .wires = .{ bytes("\x1bOD"), bytes("\x1b[D"), no_case27, no_raw } },
    .{ .name = "Right", .event = .redraw, .cursor = 6, .wires = .{ bytes("\x1bOC"), bytes("\x1b[C"), no_case27, no_raw } },
    .{ .name = "Up scrolls at first line", .event = .scroll_up, .wires = .{ bytes("\x1bOA"), bytes("\x1b[A"), no_case27, no_raw } },
    .{ .name = "Down scrolls at last line", .event = .scroll_down, .wires = .{ bytes("\x1bOB"), bytes("\x1b[B"), no_case27, no_raw } },
    .{ .name = "Up moves within draft", .before = "abcde\nxy!", .caret = 8, .after = "abcde\nxy!", .cursor = 2, .event = .redraw, .wires = .{ bytes("\x1bOA"), bytes("\x1b[A"), no_case27, no_raw } },
    .{ .name = "Down clamps to shorter line", .before = "abcde\nxy!", .caret = 4, .after = "abcde\nxy!", .cursor = 9, .event = .redraw, .wires = .{ bytes("\x1bOB"), bytes("\x1b[B"), no_case27, no_raw } },
    .{ .name = "Home", .event = .redraw, .cursor = 0, .wires = .{ bytes("\x1bOH"), bytes("\x1b[H"), no_case27, no_raw } },
    .{ .name = "Ctrl-A", .event = .redraw, .cursor = 0, .wires = .{ no_alt, bytes("\x1b[97;5u"), bytes("\x1b[27;5;97~"), bytes("\x01") } },
    .{ .name = "End", .event = .redraw, .cursor = 8, .wires = .{ bytes("\x1bOF"), bytes("\x1b[F"), no_case27, no_raw } },
    .{ .name = "End empty closes view", .before = "", .caret = 0, .after = "", .cursor = 0, .event = .close_view, .wires = .{ bytes("\x1bOF"), bytes("\x1b[F"), no_case27, no_raw } },
    .{ .name = "Ctrl-E", .event = .redraw, .cursor = 8, .wires = .{ no_alt, bytes("\x1b[101;5u"), bytes("\x1b[27;5;101~"), bytes("\x05") } },
    .{ .name = "Delete", .event = .redraw, .after = "one to!", .wires = .{ bytes("\x1b[3~"), bytes("\x1b[3;1~"), no_case27, no_raw } },
    .{ .name = "Backspace DEL", .event = .redraw, .after = "one wo!", .cursor = 4, .wires = .{ no_alt, bytes("\x1b[127u"), bytes("\x1b[27;1;127~"), bytes("\x7f") } },
    .{ .name = "Backspace BS", .event = .redraw, .after = "one wo!", .cursor = 4, .wires = .{ no_alt, bytes("\x1b[127u"), bytes("\x1b[27;1;127~"), bytes("\x08") } },
    .{ .name = "Ctrl-U", .event = .redraw, .after = "wo!", .cursor = 0, .wires = .{ no_alt, bytes("\x1b[117;5u"), bytes("\x1b[27;5;117~"), bytes("\x15") } },
    .{ .name = "Ctrl-K", .event = .redraw, .after = "one t", .wires = .{ no_alt, bytes("\x1b[107;5u"), bytes("\x1b[27;5;107~"), bytes("\x0b") } },
    .{ .name = "Ctrl-W whitespace word", .before = "first foo.bar!", .caret = 14, .after = "first ", .cursor = 6, .event = .redraw, .wires = .{ no_alt, bytes("\x1b[119;5u"), bytes("\x1b[27;5;119~"), bytes("\x17") } },
    .{ .name = "Alt-Backspace Unicode word", .before = "first foo.bar!", .caret = 14, .after = "first foo.", .cursor = 10, .event = .redraw, .wires = .{ bytes("\x1b\x7f"), bytes("\x1b[127;3u"), bytes("\x1b[27;3;127~"), no_raw } },
    .{ .name = "Alt-Backspace BS", .before = "first foo.bar!", .caret = 14, .after = "first foo.", .cursor = 10, .event = .redraw, .wires = .{ bytes("\x1b\x08"), bytes("\x1b[127;3u"), bytes("\x1b[27;3;127~"), no_raw } },
    .{ .name = "Alt-B", .event = .redraw, .cursor = 4, .wires = .{ bytes("\x1bb"), bytes("\x1b[98;3u"), bytes("\x1b[27;3;98~"), no_raw } },
    .{ .name = "Alt-F", .before = "one two three", .after = "one two three", .event = .redraw, .cursor = 7, .wires = .{ bytes("\x1bf"), bytes("\x1b[102;3u"), bytes("\x1b[27;3;102~"), no_raw } },
    .{ .name = "Alt-Left", .event = .redraw, .cursor = 4, .wires = .{ bytes("\x1b[1;3D"), bytes("\x1b[1;3D"), no_case27, no_raw } },
    .{ .name = "Alt-Right", .before = "one two three", .after = "one two three", .event = .redraw, .cursor = 7, .wires = .{ bytes("\x1b[1;3C"), bytes("\x1b[1;3C"), no_case27, no_raw } },
    .{ .name = "Backspace grapheme", .before = "aéZ", .caret = 3, .after = "aZ", .cursor = 1, .event = .redraw, .wires = .{ no_alt, bytes("\x1b[127u"), bytes("\x1b[27;1;127~"), bytes("\x7f") } },
    .{ .name = "Alt-Enter newline", .event = .redraw, .after = "one t\nwo!", .cursor = 6, .wires = .{ bytes("\x1b\r"), bytes("\x1b[13;3u"), bytes("\x1b[27;3;13~"), no_raw } },
    .{ .name = "Alt-period unbound", .event = .unbound, .wires = .{ bytes("\x1b."), bytes("\x1b[46;3u"), bytes("\x1b[27;3;46~"), no_raw } },
    .{ .name = "Alt-Ctrl-R unbound", .event = .unbound, .wires = .{ bytes("\x1b\x12"), bytes("\x1b[114;7u"), bytes("\x1b[27;7;114~"), no_raw } },
    // Ghostty's legacy modifier table names bit 8 Super, matching Kitty.
    // Separate Hyper/Meta exist in Kitty, not in that case27 modifier table.
    .{ .name = "Super-period unbound", .event = .unbound, .wires = .{ .{ .unavailable = .modifier_not_in_protocol }, bytes("\x1b[46;9u"), bytes("\x1b[27;9;46~"), no_raw } },
    .{ .name = "Hyper-period unbound", .event = .unbound, .wires = .{ .{ .unavailable = .modifier_not_in_protocol }, bytes("\x1b[46;17u"), .{ .unavailable = .modifier_not_in_protocol }, no_raw } },
    .{ .name = "Meta-period unbound", .event = .unbound, .wires = .{ .{ .unavailable = .modifier_not_in_protocol }, bytes("\x1b[46;33u"), .{ .unavailable = .modifier_not_in_protocol }, no_raw } },
};

const Outcome = struct {
    text: [128]u8 = undefined,
    length: usize,
    cursor: usize,
    event: Editor.Event,
    submits: usize,
    rejected: ?Editor.Event,
    closes: usize = 0,
};

fn feed(editor: *Editor, input: *Input, data: []const u8, outcome: *Outcome) void {
    for (data) |byte| {
        var decoded = input.feed(byte, 0);
        while (decoded != .none) : (decoded = input.next()) {
            const event = editor.apply(decoded);
            if (event != .none) outcome.event = event;
            if (event == .submit) outcome.submits += 1;
            if (event == .close_view) outcome.closes += 1;
        }
    }
}

fn inlineFeed(editor: *Editor, input: *Input, data: []const u8, outcome: *Outcome) void {
    for (data) |byte| {
        const event = editor.feed(input, byte);
        if (event != .none) outcome.event = event;
        if (event == .submit) outcome.submits += 1;
        if (event == .close_view) outcome.closes += 1;
    }
}

fn run(comptime route: Route, case: Case, wire: []const u8, split: usize, choice: bool) !Outcome {
    const deliver = if (route == .inline_editor) inlineFeed else feed;
    var storage: [128]u8 = undefined;
    @memcpy(storage[0..case.before.len], case.before);
    var editor: Editor = .{ .buffer = &storage, .length = case.before.len, .cursor = case.caret, .allow_paste = !choice };
    var input: Input = .{};
    var result: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
    deliver(&editor, &input, wire[0..split], &result);
    // A read ending at any byte boundary must not commit an incomplete chord.
    // Clock expiry itself is tested separately at the owning deadline seam.
    if (split != 0 and split < wire.len) {
        try std.testing.expectEqual(Editor.Event.none, result.event);
        try std.testing.expectEqualStrings(case.before, storage[0..editor.length]);
        try std.testing.expectEqual(case.caret, editor.cursor);
    }
    deliver(&editor, &input, wire[split..], &result);
    const bare_escape = std.mem.eql(u8, wire, "\x1b") or std.mem.eql(u8, wire, "\x1b\x1b");
    try std.testing.expectEqual(if (bare_escape) Input.Pending.escape else Input.Pending.none, input.pending());
    if (bare_escape) {
        try std.testing.expect(try input.expire());
        // SessionFrontend translates a successful bare-ESC expiry to close_view.
        result.event = .close_view;
    }
    try std.testing.expectEqual(Input.Pending.none, input.pending());
    result.length = editor.length;
    result.cursor = editor.cursor;
    result.rejected = editor.rejected;
    @memcpy(result.text[0..result.length], storage[0..editor.length]);
    if (case.event != .submit and case.event != .interrupt and case.event != .eof) {
        // Observable caret/retained-suffix oracle: a later typed edit and Enter
        // must submit the exact independently specified draft, once.
        var expected: [128]u8 = undefined;
        @memcpy(expected[0..case.cursor], case.after[0..case.cursor]);
        expected[case.cursor] = 'Z';
        @memcpy(expected[case.cursor + 1 ..][0 .. case.after.len - case.cursor], case.after[case.cursor..]);
        var suffix: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
        deliver(&editor, &input, "Z\r", &suffix);
        try std.testing.expectEqual(Editor.Event.submit, suffix.event);
        try std.testing.expectEqual(@as(usize, 1), suffix.submits);
        try std.testing.expectEqualStrings(expected[0 .. case.after.len + 1], storage[0..editor.length]);
    }
    return result;
}

fn check(comptime route: Route, case: Case, lane: Lane, wire: []const u8, split: usize, choice: bool) !void {
    errdefer std.debug.print("TD2 {s} route={s} lane={s} split={d}/{d} choice={}\n", .{ case.name, @tagName(route), @tagName(lane), split, wire.len, choice });
    const actual = try run(route, case, wire, split, choice);
    try std.testing.expectEqualStrings(case.after, actual.text[0..actual.length]);
    try std.testing.expectEqual(case.cursor, actual.cursor);
    try std.testing.expectEqual(case.event, actual.event);
    try std.testing.expectEqual(@as(usize, if (case.event == .submit) 1 else 0), actual.submits);
    try std.testing.expectEqual(@as(?Editor.Event, null), actual.rejected);
}

fn matrix(case27: bool) !void {
    var failures: usize = 0;
    for (cases) |case| {
        for (case.wires, 0..) |wire, index| {
            const lane: Lane = @fromBackingInt(@intCast(index));
            if ((lane == .case27) != case27) continue;
            switch (wire) {
                .unavailable => {}, // Explicit protocol gap, never a passing vector.
                .bytes => |data| for (0..data.len + 1) |split| {
                    for ([_]bool{ false, true }) |choice| {
                        inline for (.{ Route.events, Route.inline_editor }) |route| {
                            check(route, case, lane, data, split, choice) catch {
                                failures += 1;
                            };
                        }
                    }
                },
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "TD2 binding outcomes across raw ESC-prefix and kitty at every fragmentation boundary" {
    try matrix(false);
}

test "TD2 modifyOtherKeys case27 must have identical binding outcomes" {
    // Mandatory regression, not xfail: the pinned parser alone drops 27~.
    try matrix(true);
}

test "TD2 captured Ghostty ESC CR and terminal-translated ESC LF insert newline never submit" {
    // #538 physical capture: ESC CR. ICRNL translates it to ESC LF in Rui's
    // terminal mode. Neither gesture is an ordinary Enter submission.
    const case: Case = .{ .name = "Ghostty captured newline", .event = .redraw, .after = "one t\nwo!", .cursor = 6, .wires = undefined };
    for ([_][]const u8{ "\x1b\r", "\x1b\n" }) |wire| {
        for (0..wire.len + 1) |split| for ([_]bool{ false, true }) |choice| {
            inline for (.{ Route.events, Route.inline_editor }) |route| {
                try check(route, case, .legacy, wire, split, choice);
            }
        };
    }
}

test "TD2 incomplete prefixes expire fatally without modifying or submitting drafts" {
    for (cases) |case| for (case.wires) |wire| switch (wire) {
        .unavailable => {},
        .bytes => |data| for (1..data.len) |split| {
            var storage: [128]u8 = undefined;
            @memcpy(storage[0..case.before.len], case.before);
            var editor: Editor = .{ .buffer = &storage, .length = case.before.len, .cursor = case.caret };
            var input: Input = .{};
            var outcome: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
            const prefix = data[0..split];
            // The fixture, never pending()/expire(), supplies the expectation.
            // A recognized CSI/SS3/kitty/case27 prefix is not a bare Esc key.
            const bare_escape = std.mem.eql(u8, prefix, "\x1b") or std.mem.eql(u8, prefix, "\x1b\x1b");
            feed(&editor, &input, prefix, &outcome);
            try std.testing.expectEqual(if (bare_escape) Input.Pending.escape else Input.Pending.incomplete, input.pending());
            if (bare_escape) {
                try std.testing.expect(try input.expire());
                try std.testing.expectEqual(Input.Pending.none, input.pending());
            } else try std.testing.expectError(error.IncompleteTerminalInput, input.expire());
            try std.testing.expectEqualStrings(case.before, storage[0..editor.length]);
            try std.testing.expectEqual(case.caret, editor.cursor);
            try std.testing.expectEqual(@as(usize, 0), outcome.submits);
        },
    };
}

test "TD2 double ESC retains fragmented paste provenance and the following edit" {
    const data = "\x1b\x1b[200~é\nZ\x1b[201~q";
    for (0..data.len + 1) |split| {
        var storage: [128]u8 = undefined;
        @memcpy(storage[0..8], "headTAIL");
        var editor: Editor = .{ .buffer = &storage, .length = 8, .cursor = 4 };
        var input: Input = .{};
        var outcome: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
        feed(&editor, &input, data[0..split], &outcome);
        feed(&editor, &input, data[split..], &outcome);
        try std.testing.expectEqualStrings("headé\nZqTAIL", storage[0..editor.length]);
        try std.testing.expectEqual(@as(usize, 9), editor.cursor);
        try std.testing.expectEqual(@as(usize, 1), outcome.closes);
        try std.testing.expectEqual(@as(usize, 0), outcome.submits);
        try std.testing.expectEqual(Input.Pending.none, input.pending());
        try std.testing.expect(!input.paste);
        feed(&editor, &input, "\r", &outcome);
        try std.testing.expectEqual(Editor.Event.submit, outcome.event);
        try std.testing.expectEqual(@as(usize, 1), outcome.submits);
    }
    // Encoded Enter/Ctrl-R are never keyboard gestures inside marked paste.
    // In particular they cannot submit or recover, even if framing splits.
    for ([_][]const u8{ "\x1b\r", "\x1b\n", "\x1b[13u", "\x1b[114;5u", "\x1b[27;5;114~", "\x1b[13;2u", "\x1b[27;2;13~", "\x1b[13;5u", "\x1b[27;5;13~" }) |encoded| {
        var storage: [128]u8 = undefined;
        var editor: Editor = .{ .buffer = &storage };
        var input: Input = .{};
        var outcome: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
        feed(&editor, &input, "\x1b[200~kept", &outcome);
        feed(&editor, &input, encoded, &outcome);
        try std.testing.expectEqual(Input.Pending.incomplete, input.pending());
        try std.testing.expectError(error.IncompleteTerminalInput, input.expire());
        feed(&editor, &input, "\x1b[201~\r", &outcome);
        try std.testing.expectEqual(Editor.Event.invalid, outcome.event);
        try std.testing.expectEqual(@as(usize, 0), outcome.submits);
        try std.testing.expectEqualStrings("kept", storage[0..editor.length]);
    }
}

test "TD2 Ghostty modified control chords cannot turn retained choice text into a submission" {
    // Ghostty's legacy function-key table emits case27 even without mode
    // negotiation. Ctrl-Enter/Ctrl-Tab/Shift-Escape retain Kitty's existing
    // draft-invalidating policy, rather than silently submitting an 'a'.
    for ([_][]const u8{ "\x1b[13;5u", "\x1b[27;5;13~", "\x1b[9;5u", "\x1b[27;5;9~", "\x1b[27;2u", "\x1b[27;2;27~" }) |encoded| {
        for (0..encoded.len + 1) |split| for ([_]bool{ false, true }) |choice| {
            var storage: [128]u8 = undefined;
            var editor: Editor = .{ .buffer = &storage, .allow_paste = !choice };
            var input: Input = .{};
            var outcome: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
            feed(&editor, &input, "a", &outcome);
            feed(&editor, &input, encoded[0..split], &outcome);
            feed(&editor, &input, encoded[split..], &outcome);
            try std.testing.expectEqual(@as(usize, 0), outcome.submits);
            try std.testing.expectEqualStrings("a", storage[0..editor.length]);
            feed(&editor, &input, "\r", &outcome);
            try std.testing.expectEqual(Editor.Event.invalid, outcome.event);
            try std.testing.expectEqual(@as(usize, 0), outcome.submits);
            try std.testing.expectEqualStrings("a", storage[0..editor.length]);
        };
    }
}

test "TD2 Ghostty modifier nine is Super distinct from Kitty Hyper and Meta" {
    // Exact Ghostty v1.2.3 legacy Tab vectors and Kitty modifier definitions:
    // https://github.com/ghostty-org/ghostty/blob/6d2dd585a5d87fa745d48188dd096ca6e63014d0/src/input/function_keys.zig#L172-L190
    // https://sw.kovidgoyal.net/kitty/keyboard-protocol/#modifiers
    // Checking only .unbound would accept Super incorrectly decoded as Meta.
    // Kitty Hyper/Meta are protocol vectors; Ghostty's input model does not
    // emit those separate modifiers, so no case27 representation is invented.
    const Vector = struct { data: []const u8, modifiers: u8 };
    for ([_]Vector{
        .{ .data = "\x1b[27;9;9~", .modifiers = 8 },
        .{ .data = "\x1b[9;9u", .modifiers = 8 },
        .{ .data = "\x1b[27;13;9~", .modifiers = 12 },
        .{ .data = "\x1b[9;13u", .modifiers = 12 },
        .{ .data = "\x1b[9;17u", .modifiers = 16 },
        .{ .data = "\x1b[9;33u", .modifiers = 32 },
    }) |vector| for (0..vector.data.len + 1) |split| {
        var input: Input = .{};
        var presses: usize = 0;
        for ([_][]const u8{ vector.data[0..split], vector.data[split..] }) |chunk| for (chunk) |byte| {
            var decoded = input.feed(byte, 0);
            while (decoded != .none) : (decoded = input.next()) {
                try std.testing.expect(decoded == .event);
                try std.testing.expect(!decoded.event.pasted);
                try std.testing.expect(decoded.event.event == .key_press);
                const key = decoded.event.event.key_press;
                try std.testing.expectEqual(@as(u21, 9), key.codepoint);
                try std.testing.expectEqual(vector.modifiers, @as(u8, @bitCast(key.mods)));
                presses += 1;
            }
        };
        try std.testing.expectEqual(@as(usize, 1), presses);
        try std.testing.expectEqual(Input.Pending.none, input.pending());
    };
}

// Literal C0, CSI-u, case27, explicit Kitty press, and Kitty release. Raw
// C0 is already normalized to the same typed Ctrl key by vaxis; there is no
// separate legacyControl helper in this runtime. R has a frontend binding,
// not an editor binding, but must use the same normalization as C/D/J.
const Control = struct { point: u21, wires: [5][]const u8 };
const controls = [_]Control{
    .{ .point = 'c', .wires = .{ "\x03", "\x1b[99;5u", "\x1b[27;5;99~", "\x1b[99;5:1u", "\x1b[99;5:3u" } },
    .{ .point = 'd', .wires = .{ "\x04", "\x1b[100;5u", "\x1b[27;5;100~", "\x1b[100;5:1u", "\x1b[100;5:3u" } },
    .{ .point = 'j', .wires = .{ "\n", "\x1b[106;5u", "\x1b[27;5;106~", "\x1b[106;5:1u", "\x1b[106;5:3u" } },
    .{ .point = 'r', .wires = .{ "\x12", "\x1b[114;5u", "\x1b[27;5;114~", "\x1b[114;5:1u", "\x1b[114;5:3u" } },
};

test "TD2 vaxis normalizes legacy and encoded Ctrl C D J R without a recovery special case" {
    for (controls) |control| for (control.wires, 0..) |wire, index| {
        errdefer std.debug.print("TD2 parser Ctrl codepoint={d} encoding={d}\n", .{ control.point, index });
        var parser: vaxis.Parser = .{};
        const result = try parser.parse(wire, null);
        try std.testing.expectEqual(wire.len, result.n);
        const event = result.event orelse return error.MissingControlEvent;
        const key = if (index == 4) blk: {
            try std.testing.expect(event == .key_release);
            break :blk event.key_release;
        } else blk: {
            try std.testing.expect(event == .key_press);
            break :blk event.key_press;
        };
        try std.testing.expectEqual(control.point, key.codepoint);
        try std.testing.expectEqual(@as(u8, 4), @as(u8, @bitCast(key.mods)));
        try std.testing.expectEqual(@as(?[]const u8, null), key.text);
    };
}

test "TD2 kitty release is not a binding and repeat produces one submission" {
    for ([_][]const u8{ "\x1b[13;1:3u", "\x1b[13;2:3u", "\x1b[13;3:3u", "\x1b[99;5:3u", "\x1b[100;5:3u", "\x1b[106;5:3u", "\x1b[114;5:3u", "\x1b[127;1:3u", "\x1b[106;3:3u", "\x1b[1;2:3A" }) |release| {
        const case: Case = .{ .name = "key release", .event = .none, .wires = undefined };
        for (0..release.len + 1) |split| for ([_]bool{ false, true }) |choice| {
            inline for (.{ Route.events, Route.inline_editor }) |route| {
                try check(route, case, .kitty, release, split, choice);
            }
        };
    }
    const repeat: Case = .{ .name = "Enter repeat", .event = .submit, .wires = undefined };
    inline for (.{ Route.events, Route.inline_editor }) |route| {
        try check(route, repeat, .kitty, "\x1b[13;1:2u", 4, false);
    }
}

test "TD2 explicit Kitty Ctrl press then release acts once through both editor entry points" {
    for (controls[0..3]) |control| {
        const case: Case = switch (control.point) {
            'c' => .{ .name = "Ctrl-C press", .event = .interrupt, .wires = undefined },
            'd' => .{ .name = "Ctrl-D press", .event = .redraw, .after = "one to!", .wires = undefined },
            'j' => .{ .name = "Ctrl-J press", .event = .submit, .wires = undefined },
            else => unreachable,
        };
        for ([_]bool{ false, true }) |choice| inline for (.{ Route.events, Route.inline_editor }) |route| {
            const deliver = if (route == .inline_editor) inlineFeed else feed;
            const release = control.wires[4];
            for (0..release.len + 1) |split| {
                var storage: [128]u8 = undefined;
                @memcpy(storage[0..case.before.len], case.before);
                var editor: Editor = .{ .buffer = &storage, .length = case.before.len, .cursor = case.caret, .allow_paste = !choice };
                var input: Input = .{};
                var pressed: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
                deliver(&editor, &input, control.wires[3], &pressed);
                try std.testing.expectEqual(case.event, pressed.event);
                try std.testing.expectEqual(@as(usize, if (case.event == .submit) 1 else 0), pressed.submits);
                var released: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
                deliver(&editor, &input, release[0..split], &released);
                deliver(&editor, &input, release[split..], &released);
                try std.testing.expectEqual(Editor.Event.none, released.event);
                try std.testing.expectEqual(@as(usize, 0), released.submits);
                try std.testing.expectEqualStrings(case.after, storage[0..editor.length]);
                try std.testing.expectEqual(case.cursor, editor.cursor);
                try std.testing.expectEqual(@as(?Editor.Event, null), editor.rejected);
                try std.testing.expectEqual(Input.Pending.none, input.pending());
            }
        };
    }
}

test "TD2 SessionTerminal expiry boundaries use a controlled clock and retain queued bytes" {
    const Terminal = @import("SessionTerminal.zig");
    const Clock = struct {
        at: i96,
        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return .{ .nanoseconds = self.at };
        }
    };
    var clock: Clock = .{ .at = 1_000_000_000 };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .userdata = &clock, .vtable = &vtable };
    // next owns stdin. Replace it only during this synchronous test and always
    // restore the test runner's descriptor, including assertion failures.
    const saved = std.c.dup(0);
    if (saved < 0) return error.TestDupFailed;
    defer _ = std.c.close(saved);
    defer std.debug.assert(std.c.dup2(saved, 0) == 0);
    for ([_]Input.Pending{ .escape, .incomplete }) |pending| {
        const duration: i96 = if (pending == .escape) 80_000_000 else 2_000_000_000;
        // A byte that leaves the input exactly as pending as before.
        const prefix: []const u8 = if (pending == .escape) "\x1b" else "\x1b[";
        const more: u8 = if (pending == .escape) 0x1b else '1';
        for ([_]i96{ -1, 0, 1 }) |offset| {
            var pipe: [2]c_int = undefined;
            if (std.c.pipe(&pipe) != 0) return error.TestPipeFailed;
            defer _ = std.c.close(pipe[0]);
            defer _ = std.c.close(pipe[1]);
            if (std.c.dup2(pipe[0], 0) != 0) return error.TestDupFailed;
            var terminal: Terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = undefined };
            var input: Input = .{};
            for (prefix) |byte| _ = input.feed(byte, 1_000_000_000);
            try std.testing.expectEqual(pending, input.pending());
            clock.at = 1_000_000_000 + duration + offset;
            try std.testing.expectEqual(@as(isize, 1), std.c.write(pipe[1], &.{more}, 1));
            if (offset < 0) {
                const read = (try terminal.next(io, &input, 0)).?;
                try std.testing.expectEqual(more, read.byte);
                try std.testing.expectEqual(clock.at, read.at);
                try std.testing.expect(input.feed(read.byte, read.at) == .none);
                try std.testing.expectEqual(pending, input.pending());
                // A fed byte, not an empty poll, renews the inactivity clock.
                clock.at += duration - 1;
                try std.testing.expectEqual(@as(?Terminal.Read, null), try terminal.next(io, &input, 0));
                clock.at += 1;
                try std.testing.expectError(error.InputDeadline, terminal.next(io, &input, 0));
            } else {
                try std.testing.expectError(error.InputDeadline, terminal.next(io, &input, 0));
                if (pending == .escape) try std.testing.expect(try input.expire()) else try std.testing.expectError(error.IncompleteTerminalInput, input.expire());
                // Expiry did not consume ready input. It remains for the next
                // read, not swallowed as part of an expired prefix. (Incomplete
                // expiry ends the caller; read as its successor would.)
                const idle: Input = .{};
                try std.testing.expectEqual(more, (try terminal.next(io, if (pending == .escape) &input else &idle, 0)).?.byte);
            }
        }
    }
    // Use the actual reader's deadline before feeding the next byte. Queued
    // CR/LF joins ESC only before expiry; expiry leaves it for ordinary Enter.
    for ([_]u8{ '\r', '\n' }) |enter| for ([_]i96{ 0, 1, -1 }) |offset| {
        var pipe: [2]c_int = undefined;
        if (std.c.pipe(&pipe) != 0) return error.TestPipeFailed;
        defer _ = std.c.close(pipe[0]);
        defer _ = std.c.close(pipe[1]);
        if (std.c.dup2(pipe[0], 0) != 0) return error.TestDupFailed;
        var terminal: Terminal = .{ .original = undefined, .flags = .{ 0, 0 }, .screen = undefined };
        clock.at = 1_000_000_000;
        var storage: [128]u8 = undefined;
        @memcpy(storage[0..8], "headTAIL");
        var editor: Editor = .{ .buffer = &storage, .length = 8, .cursor = 4 };
        var input: Input = .{};
        var outcome: Outcome = .{ .length = 0, .cursor = 0, .event = .none, .submits = 0, .rejected = null };
        try std.testing.expectEqual(@as(isize, 1), std.c.write(pipe[1], "\x1b", 1));
        const escape = (try terminal.next(io, &input, 0)).?;
        feedAt(&editor, &input, escape, &outcome);
        try std.testing.expectEqual(Input.Pending.escape, input.pending());
        try std.testing.expectEqual(@as(isize, 1), std.c.write(pipe[1], &.{enter}, 1));
        clock.at += 80_000_000 + offset;
        if (offset >= 0) {
            try std.testing.expectError(error.InputDeadline, terminal.next(io, &input, 0));
            try std.testing.expect(try input.expire());
            try std.testing.expectEqualStrings("headTAIL", storage[0..editor.length]);
            try std.testing.expectEqual(@as(usize, 4), editor.cursor);
            try std.testing.expectEqual(@as(usize, 0), outcome.submits);
        }
        const read = (try terminal.next(io, &input, 0)).?;
        try std.testing.expectEqual(enter, read.byte);
        feedAt(&editor, &input, read, &outcome);
        try std.testing.expectEqualStrings(if (offset < 0) "head\nTAIL" else "headTAIL", storage[0..editor.length]);
        try std.testing.expectEqual(@as(usize, if (offset < 0) 5 else 4), editor.cursor);
        try std.testing.expectEqual(@as(usize, if (offset < 0) 0 else 1), outcome.submits);
        try std.testing.expectEqual(if (offset < 0) Editor.Event.redraw else Editor.Event.submit, outcome.event);
        try std.testing.expectEqual(Input.Pending.none, input.pending());
    };
}

fn feedAt(editor: *Editor, input: *Input, read: @import("SessionTerminal.zig").Read, outcome: *Outcome) void {
    var decoded = input.feed(read.byte, read.at);
    while (decoded != .none) : (decoded = input.next()) {
        const event = editor.apply(decoded);
        if (event != .none) outcome.event = event;
        if (event == .submit) outcome.submits += 1;
    }
}
