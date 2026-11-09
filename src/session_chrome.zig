//! The Session screen's chrome, decided over values its shell read: the
//! status bar under the facts row, the marker over a scrolled-back
//! transcript, how far Shift-Up/Down scroll, the terminal title, and the one
//! Keys table that /help and the `?` shortcuts both show. Nothing here
//! reads a clock or the terminal; the shell passes the time and widths.
const std = @import("std");
const session_line = @import("session_line.zig");
const session_work = @import("session_work.zig");
const TerminalText = @import("TerminalText.zig");

pub const Method = session_line.Method;

// --- Notices --------------------------------------------------------------

/// How long a notice about the person's own last action stays without a key.
pub const notice_ms = 5_000;

/// A notice about the person's own last action: `Copied 12 lines`,
/// `! Unknown command /x · /help`. The screen keeps one; a newer notice
/// replaces it, and the next key clears it before the key acts, so a key's
/// own notice survives it. Anything the person must act on is never a
/// notice: it is the status bar's `needs` text, which lasts until resolved.
pub const Notice = struct {
    /// When it was shown, on the shell's clock.
    shown_ms: u64,

    /// Whether it still shows at `now_ms`.
    pub fn fresh(self: Notice, now_ms: u64) bool {
        return now_ms -| self.shown_ms < notice_ms;
    }

    /// How long until it goes by itself, so the shell can wake to clear it.
    pub fn remaining(self: Notice, now_ms: u64) u64 {
        return notice_ms -| (now_ms -| self.shown_ms);
    }
};

// --- Status bar -----------------------------------------------------------

/// The stop key the last row offers while work can be stopped.
pub const stop_key = "ctrl+x stop";

/// Whether Ctrl-X has work to stop: a tool or the model running, a retry
/// counting down, queued work, or an Action waiting. Not while a stop is
/// already settling (the Host's `stopping`, or one the person asked for
/// that the Host has not reported yet), and not once work has ended.
pub fn stoppable(kind: session_work.Kind, stop_requested: bool) bool {
    if (stop_requested) return false;
    return switch (kind) {
        .pending, .working, .retrying, .bash, .approval => true,
        .idle, .stopping, .finished, .failed, .stopped => false,
    };
}

pub const Tone = enum { quiet, attention };

/// What the status bar shows: `left` at column 0, `stop` right-aligned.
pub const Bar = struct {
    left: []const u8 = "",
    tone: Tone = .quiet,
    /// Whether `stop_key` shows at the right edge.
    stop: bool = false,
    /// The column `stop_key` starts at, when it shows.
    stop_column: u16 = 0,
};

/// The facts the status bar is decided over.
pub const Facts = struct {
    /// What needs the person, with its key (`! Not confirmed · ctrl+r
    /// retries`). Persists until resolved; outranks any notice.
    needs: ?[]const u8 = null,
    /// The latest notice and its text, if one is held.
    notice: ?struct { text: []const u8, shown: Notice } = null,
    /// `stoppable` for the Session's work.
    stoppable: bool = false,
    width: u16,
    method: Method = .unicode,
};

/// Cells kept between the left text and the stop key.
const gap = 2;

/// The status bar at `now_ms`. Left: what needs the person, else a fresh
/// notice, else nothing. Right: the stop key while work can be stopped.
/// When both don't fit, the left side wins and the stop key drops (Ctrl-X
/// still works); the shell clips left text that is wider than the row.
pub fn bar(facts: Facts, now_ms: u64) Bar {
    var result: Bar = .{};
    if (facts.needs) |needs| {
        result.left = needs;
        result.tone = .attention;
    } else if (facts.notice) |notice| if (notice.shown.fresh(now_ms)) {
        result.left = notice.text;
        result.tone = if (std.mem.startsWith(u8, notice.text, "!")) .attention else .quiet;
    };
    if (!facts.stoppable) return result;
    const stop_cells = session_line.cells(stop_key, facts.method);
    const left_cells = session_line.cells(result.left, facts.method);
    const used = if (left_cells == 0) 0 else left_cells + gap;
    // One cell of margin at the right edge, as the mocks set it.
    if (used + stop_cells + 1 > facts.width) return result;
    result.stop = true;
    result.stop_column = @intCast(facts.width - stop_cells - 1);
    return result;
}

// --- Scrolling ------------------------------------------------------------

/// Rows Shift-Up/Down (and PgUp/PgDn) move: half the transcript's height,
/// at least one.
pub fn halfScreen(height: usize) usize {
    return @max(1, height / 2);
}

/// Bytes `marker` writes at most.
pub const marker_bytes = "↓ ".len + 20 + " new".len;

/// The chip over a scrolled-back transcript's bottom-right: `↓` when
/// nothing arrived below, `↓ N new` once N new transcript entries did.
/// Clicking it, or Esc, jumps to the latest.
pub fn marker(buffer: *[marker_bytes]u8, new_entries: u64) []const u8 {
    if (new_entries == 0) return "↓";
    return std.fmt.bufPrint(buffer, "↓ {d} new", .{new_entries}) catch unreachable;
}

// --- Terminal title ---------------------------------------------------------

/// Bytes of a Session's name kept in the title, before escaping.
pub const title_name_bytes = 80;
pub const title_bytes = TerminalText.max_bytes_per_byte * title_name_bytes + session_line.ellipsis.len + " · rui · ".len + 20 + " needs you".len;

/// The terminal title: `rui`, plus `· N needs you` while any Session waits
/// on the person; inside a Session it leads with that Session's name. The
/// name is escaped like a label, so no control reaches the terminal's title
/// sequence, and a long one is cut at a character and ends in `…`.
pub fn title(buffer: *[title_bytes]u8, session: ?[]const u8, needs_you: u64) []const u8 {
    var out = std.Io.Writer.fixed(buffer);
    if (session) |name| {
        const cut = cutUtf8(name, title_name_bytes);
        var text: TerminalText = .{ .mode = .label };
        text.feed(&out, name[0..cut]) catch unreachable;
        text.finish(&out) catch unreachable;
        if (cut < name.len) out.writeAll(session_line.ellipsis) catch unreachable;
        out.writeAll(" · ") catch unreachable;
    }
    out.writeAll("rui") catch unreachable;
    if (needs_you != 0) out.print(" · {d} needs you", .{needs_you}) catch unreachable;
    return out.buffered();
}

/// The longest prefix of `bytes` within `limit` that ends on a UTF-8 scalar
/// boundary.
fn cutUtf8(bytes: []const u8, limit: usize) usize {
    if (bytes.len <= limit) return bytes.len;
    var end = limit;
    while (end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

// --- Keys -------------------------------------------------------------------

pub const Binding = struct { key: []const u8, does: []const u8 };

/// The Session's keys, in the order /help lists them and the `?` shortcuts
/// pack them. The full key behaviour lives in `session_keys`; this is how
/// it is said.
pub const keys = [_]Binding{
    .{ .key = "enter", .does = "send" },
    .{ .key = "shift+enter or ctrl+j", .does = "new line" },
    .{ .key = "ctrl+p/n", .does = "recall" },
    .{ .key = "/", .does = "commands" },
    .{ .key = "esc", .does = "overview" },
    .{ .key = "ctrl+x", .does = "stop" },
    .{ .key = "ctrl+o", .does = "open" },
    .{ .key = "ctrl+r", .does = "retry" },
    .{ .key = "shift+↑↓", .does = "scroll" },
    .{ .key = "?", .does = "shortcuts" },
};

/// The column a key's words start at on the /help page.
const key_column = blk: {
    var widest = 0;
    for (keys) |binding| widest = @max(widest, scalars(binding.key));
    break :blk widest + 2;
};

/// Scalars in `text`: a key's cells, since every key is drawn one cell a
/// scalar (checked by a test against the terminal's width).
fn scalars(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| count += @intFromBool(byte & 0xc0 != 0x80);
    return count;
}

/// The marks a Session shows, as /help lists them.
pub const marks =
    \\✓  done                 •  running
    \\!  failed or needs a look
    \\?  an Action waits for Allow or Deny
    \\◌  waiting its turn
    \\
;

/// The /help page's Marks and Keys sections, one key per line. The
/// screen's commands follow them.
pub const help = blk: {
    var text: []const u8 = "Marks\n" ++ marks ++ "\nKeys\n";
    const padding: [key_column]u8 = @splat(' ');
    for (keys) |binding| text = text ++ binding.key ++ padding[scalars(binding.key)..] ++ binding.does ++ "\n";
    break :blk text ++ "\nCommands\n";
};

/// Bytes `shortcuts` writes at most.
pub const shortcuts_bytes = blk: {
    var bytes = 0;
    for (keys) |binding| bytes += binding.key.len + 1 + binding.does.len + " · ".len + 1;
    break :blk bytes;
};

/// The `?` shortcuts: the same keys packed into lines of at most `width`
/// cells, `key does` joined by ` · `. A binding wider than the line takes a
/// line of its own and the shell clips it.
pub fn shortcuts(buffer: *[shortcuts_bytes]u8, width: usize, method: Method) []const u8 {
    var out = std.Io.Writer.fixed(buffer);
    var line: usize = 0;
    for (keys) |binding| {
        const cells = session_line.cells(binding.key, method) + 1 + session_line.cells(binding.does, method);
        if (line != 0 and line + 3 + cells > width) {
            out.writeByte('\n') catch unreachable;
            line = 0;
        }
        if (line != 0) {
            out.writeAll(" · ") catch unreachable;
            line += 3;
        }
        out.print("{s} {s}", .{ binding.key, binding.does }) catch unreachable;
        line += cells;
    }
    return out.buffered();
}

/// What a key does to the `?` shortcuts.
pub const Shortcut = enum {
    /// Show them; the key types nothing.
    open,
    /// Close them, and the key types `?` (`??` starts a Message with one).
    close_and_type,
    /// Close them, then the key acts as usual.
    close_and_act,
    /// Not open: the key acts as usual.
    act,
};

/// `?` on an empty draft shows the shortcuts; the next key closes them and
/// then acts, except a second `?`, which types one. `?` on a draft with
/// text is just a character.
pub fn shortcut(open: bool, draft_empty: bool, question: bool) Shortcut {
    if (open) return if (question) .close_and_type else .close_and_act;
    return if (question and draft_empty) .open else .act;
}

test "? on an empty draft shows the shortcuts; the next key closes them; ?? types one" {
    try std.testing.expectEqual(Shortcut.open, shortcut(false, true, true));
    try std.testing.expectEqual(Shortcut.act, shortcut(false, false, true));
    try std.testing.expectEqual(Shortcut.act, shortcut(false, true, false));
    try std.testing.expectEqual(Shortcut.close_and_type, shortcut(true, true, true));
    try std.testing.expectEqual(Shortcut.close_and_act, shortcut(true, true, false));
}

test "a notice goes after about five seconds; what needs the person stays and outranks it" {
    const notice: Notice = .{ .shown_ms = 10_000 };
    try std.testing.expect(notice.fresh(10_000));
    try std.testing.expect(notice.fresh(14_999));
    try std.testing.expect(!notice.fresh(15_000));
    try std.testing.expectEqual(@as(u64, 1), notice.remaining(14_999));
    try std.testing.expectEqual(@as(u64, 0), notice.remaining(20_000));
    // A clock that reads earlier than the notice still shows it.
    try std.testing.expect(notice.fresh(9_000));

    const copied: Facts = .{ .notice = .{ .text = "Copied 12 lines", .shown = notice }, .width = 80 };
    try std.testing.expectEqualStrings("Copied 12 lines", bar(copied, 12_000).left);
    try std.testing.expectEqual(Tone.quiet, bar(copied, 12_000).tone);
    try std.testing.expectEqualStrings("", bar(copied, 15_000).left);

    var failing = copied;
    failing.notice.?.text = "! Unknown command /x · /help";
    try std.testing.expectEqual(Tone.attention, bar(failing, 12_000).tone);

    var unconfirmed = copied;
    unconfirmed.needs = "! Not confirmed · ctrl+r retries";
    for ([_]u64{ 12_000, 15_000, 1_000_000 }) |now| {
        try std.testing.expectEqualStrings("! Not confirmed · ctrl+r retries", bar(unconfirmed, now).left);
        try std.testing.expectEqual(Tone.attention, bar(unconfirmed, now).tone);
    }
}

test "the stop key shows on the right while work can be stopped, and drops first when the row is short" {
    for (std.enums.values(session_work.Kind)) |kind| {
        const expected = switch (kind) {
            .pending, .working, .retrying, .bash, .approval => true,
            else => false,
        };
        try std.testing.expectEqual(expected, stoppable(kind, false));
        // Once the person asked, Ctrl-X does nothing until the Host reports.
        try std.testing.expect(!stoppable(kind, true));
    }
    const alone = bar(.{ .stoppable = true, .width = 80 }, 0);
    try std.testing.expect(alone.stop);
    try std.testing.expectEqual(@as(u16, 80 - 11 - 1), alone.stop_column);
    try std.testing.expectEqualStrings("", alone.left);

    const needs = "! Not confirmed · ctrl+r retries"; // 32 cells
    const both = bar(.{ .needs = needs, .stoppable = true, .width = 80 }, 0);
    try std.testing.expect(both.stop);
    try std.testing.expectEqualStrings(needs, both.left);
    // 32 + 2 + 11 + 1 cells fit exactly in 46; one fewer drops the stop key.
    try std.testing.expect(bar(.{ .needs = needs, .stoppable = true, .width = 46 }, 0).stop);
    const narrow = bar(.{ .needs = needs, .stoppable = true, .width = 45 }, 0);
    try std.testing.expect(!narrow.stop);
    try std.testing.expectEqualStrings(needs, narrow.left);
    try std.testing.expect(!bar(.{ .stoppable = true, .width = 11 }, 0).stop);
    try std.testing.expect(bar(.{ .stoppable = true, .width = 12 }, 0).stop);
    try std.testing.expect(!bar(.{ .stoppable = false, .width = 80 }, 0).stop);
}

test "Shift-Up/Down move half the transcript, at least a row" {
    try std.testing.expectEqual(@as(usize, 10), halfScreen(20));
    try std.testing.expectEqual(@as(usize, 10), halfScreen(21));
    try std.testing.expectEqual(@as(usize, 1), halfScreen(1));
    try std.testing.expectEqual(@as(usize, 1), halfScreen(0));
}

test "the marker says how many new entries arrived below" {
    var buffer: [marker_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("↓", marker(&buffer, 0));
    try std.testing.expectEqualStrings("↓ 3 new", marker(&buffer, 3));
    try std.testing.expectEqualStrings("↓ 18446744073709551615 new", marker(&buffer, std.math.maxInt(u64)));
}

test "the title leads with the Session, says how many need the person, and never carries a control" {
    var buffer: [title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("rui", title(&buffer, null, 0));
    try std.testing.expectEqualStrings("rui · 2 needs you", title(&buffer, null, 2));
    try std.testing.expectEqualStrings("Fix flaky store test · rui", title(&buffer, "Fix flaky store test", 0));
    try std.testing.expectEqualStrings("Fix flaky store test · rui · 1 needs you", title(&buffer, "Fix flaky store test", 1));
    // A title sequence ends at BEL or ST; neither may come from a name.
    const hostile = title(&buffer, "a\x07b\x1b\\c\x9c", 0);
    for (hostile) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    try std.testing.expect(std.unicode.utf8ValidateSlice(hostile));
    // A long name is cut on a character, never inside one.
    const long = comptime repeat("é", 60); // 120 bytes
    const cut = title(&buffer, long, 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings(comptime repeat("é", 40) ++ "… · rui", cut);
    const worst = title(&buffer, &(@as([200]u8, @splat(0x1b))), std.math.maxInt(u64));
    try std.testing.expect(std.mem.endsWith(u8, worst, "… · rui · 18446744073709551615 needs you"));
}

fn repeat(comptime text: []const u8, comptime count: usize) []const u8 {
    var joined: []const u8 = "";
    for (0..count) |_| joined = joined ++ text;
    return joined;
}

test "/help and the ? shortcuts say the same keys" {
    try std.testing.expect(std.mem.startsWith(u8, help, "Marks\n✓  done"));
    try std.testing.expect(std.mem.indexOf(u8, help, "\nKeys\nenter                  send\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "\nshift+↑↓               scroll\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, help, "\nCommands\n"));
    var buffer: [shortcuts_bytes]u8 = undefined;
    const wide = shortcuts(&buffer, 1_000, .unicode);
    try std.testing.expect(std.mem.indexOfScalar(u8, wide, '\n') == null);
    for (keys) |binding| {
        try std.testing.expectEqual(scalars(binding.key), session_line.cells(binding.key, .unicode));
        var entry: [64]u8 = undefined;
        const said = std.fmt.bufPrint(&entry, "{s} {s}", .{ binding.key, binding.does }) catch unreachable;
        try std.testing.expect(std.mem.indexOf(u8, wide, said) != null);
        try std.testing.expect(std.mem.indexOf(u8, help, binding.does) != null);
    }
    try std.testing.expectEqualStrings(
        \\enter send · shift+enter or ctrl+j new line · ctrl+p/n recall · / commands
        \\esc overview · ctrl+x stop · ctrl+o open · ctrl+r retry · shift+↑↓ scroll
        \\? shortcuts
    , shortcuts(&buffer, 80, .unicode));
    var lines = std.mem.splitScalar(u8, shortcuts(&buffer, 30, .unicode), '\n');
    while (lines.next()) |line| try std.testing.expect(session_line.cells(line, .unicode) <= 30 or std.mem.indexOf(u8, line, " · ") == null);
}
