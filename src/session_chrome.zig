//! The Session screen's chrome, decided over values its shell read: the
//! status bar under the facts row, the marker over a scrolled-back
//! transcript, how far Shift-Up/Down scroll, the terminal title, and the one
//! Keys table that /help and the `?` shortcuts both show. Nothing here
//! reads a clock or the terminal; the shell passes the time and widths.
const std = @import("std");
const session_line = @import("session_line.zig");
const TerminalText = @import("TerminalText.zig");

pub const Method = session_line.Method;

// --- Notices --------------------------------------------------------------

/// How long a notice about the person's own last action stays without a key.
pub const notice_ms = 5_000;

/// The notice about the person's own last action: `Copied 12 lines`,
/// `! Unknown command /x · /help`. One at a time: a newer one replaces it,
/// and the next key dismisses it before the key acts, so a key's own
/// notice survives it. Anything the person must act on is never a notice:
/// it is the status bar's `needs` text, which lasts until resolved.
pub fn Notice(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        bytes: [capacity]u8 = undefined,
        len: usize = 0,
        /// When it was shown, on the shell's clock; null when none is held.
        shown_ms: ?u64 = null,

        /// Holds `text`, shown at `now_ms`, in place of any notice. A longer
        /// text is cut on a character.
        pub fn show(self: *Self, text: []const u8, now_ms: u64) void {
            const len = cutUtf8(text, capacity);
            std.mem.copyForwards(u8, self.bytes[0..len], text[0..len]);
            self.len = len;
            self.shown_ms = now_ms;
        }

        /// The next key: the notice goes.
        pub fn dismiss(self: *Self) void {
            self.shown_ms = null;
        }

        /// The text that shows at `now_ms`, or null once it went.
        pub fn current(self: *const Self, now_ms: u64) ?[]const u8 {
            const shown = self.shown_ms orelse return null;
            return if (now_ms -| shown < notice_ms) self.bytes[0..self.len] else null;
        }

        /// Drops a notice whose time ran out at `now_ms`; true when one
        /// went, so the shell redraws without it.
        pub fn expire(self: *Self, now_ms: u64) bool {
            if (self.shown_ms == null or self.current(now_ms) != null) return false;
            self.shown_ms = null;
            return true;
        }
    };
}

// --- Status bar -----------------------------------------------------------

/// The stop key the last row offers while work can be stopped.
pub const stop_key = "ctrl+x stop";

/// What the status bar says of a send. `status` is the held original's
/// line (`session_notice.status`); while it is opening or in flight it is
/// progress, else it needs the person until resolved. With none held, `Sent`
/// covers an accepted Message until live output or the waiting row shows it.
pub const Send = struct { needs: ?[]const u8 = null, progress: ?[]const u8 = null };

pub fn send(status: ?[]const u8, in_flight: bool, sent: bool) Send {
    // An empty status is a waiting Action, which says how to decide it.
    if (status) |text| return if (text.len == 0) .{} else if (in_flight) .{ .progress = text } else .{ .needs = text };
    return .{ .progress = if (sent) "Sent" else null };
}

test "a send is progress while in flight or just accepted, and needs the person once unresolved" {
    try std.testing.expectEqualDeep(Send{ .progress = "Sending…" }, send("Sending…", true, false));
    try std.testing.expectEqualDeep(Send{ .needs = "! Not confirmed · Ctrl-R retries original" }, send("! Not confirmed · Ctrl-R retries original", false, true));
    try std.testing.expectEqualDeep(Send{ .progress = "Sent" }, send(null, false, true));
    try std.testing.expectEqualDeep(Send{}, send("", false, true));
    try std.testing.expectEqualDeep(Send{}, send(null, false, false));
    // Progress outranks a notice, quietly; what needs the person outranks both.
    const sent = bar(.{ .progress = "Sent", .notice = "! Unknown command /x", .width = 80 });
    try std.testing.expectEqualStrings("Sent", sent.left);
    try std.testing.expectEqual(Tone.quiet, sent.tone);
    try std.testing.expectEqualStrings("! x", bar(.{ .needs = "! x", .progress = "Sent", .width = 80 }).left);
}

/// The key that ends what needs the person, which the status bar makes
/// clickable: the part after its last ` · ` (`! Not confirmed · ctrl+r
/// retries` → `ctrl+r retries`), or nothing when it names none.
pub fn needsKey(needs: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, needs, " · ") orelse return "";
    return needs[at + " · ".len ..];
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
    /// Where a send stands while it is under way (`Sending…`, `Sent`):
    /// quiet, below what needs the person and above a notice, so the frame
    /// that clears the composer already says it.
    progress: ?[]const u8 = null,
    /// The notice that shows now (`Notice.current`), if any.
    notice: ?[]const u8 = null,
    /// `stoppable` for the Session's work.
    stoppable: bool = false,
    width: u16,
    method: Method = .unicode,
};

/// Cells kept between the left text and the stop key.
const gap = 2;

/// The status bar. Left: what needs the person, else the notice, else
/// nothing. Right: the stop key while work can be stopped.
/// When both don't fit, the left side wins and the stop key drops (Ctrl-X
/// still works); the shell clips left text that is wider than the row.
pub fn bar(facts: Facts) Bar {
    var result: Bar = .{};
    if (facts.needs) |needs| {
        result.left = needs;
        result.tone = .attention;
    } else if (facts.progress) |progress| {
        result.left = progress;
    } else if (facts.notice) |notice| {
        result.left = notice;
        result.tone = if (std.mem.startsWith(u8, notice, "!")) .attention else .quiet;
    }
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

/// The title the terminal shows, so the shell sets it only when it changes.
pub const Title = struct {
    bytes: [title_bytes]u8 = undefined,
    len: ?usize = null,

    /// The title to set now, or null when the terminal already shows it.
    pub fn next(self: *Title, session: ?[]const u8, needs_you: u64) ?[]const u8 {
        var buffer: [title_bytes]u8 = undefined;
        const text = title(&buffer, session, needs_you);
        if (self.len) |len| if (std.mem.eql(u8, self.bytes[0..len], text)) return null;
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
        return self.bytes[0..text.len];
    }
};

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

test "a notice goes after about five seconds or at the next key; the newest replaces it; what needs the person stays" {
    var notice: Notice(256) = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), notice.current(0));
    notice.show("Copied 12 lines", 10_000);
    try std.testing.expectEqualStrings("Copied 12 lines", notice.current(10_000).?);
    try std.testing.expectEqualStrings("Copied 12 lines", notice.current(14_999).?);
    try std.testing.expectEqual(@as(?[]const u8, null), notice.current(15_000));
    try std.testing.expect(!notice.expire(14_999));
    try std.testing.expect(notice.expire(15_000));
    try std.testing.expect(!notice.expire(15_001));
    notice.show("Copied 12 lines", 10_000);
    // A clock that reads earlier than the notice still shows it.
    try std.testing.expect(notice.current(9_000) != null);
    notice.show("! Unknown command /x · /help", 12_000);
    try std.testing.expectEqualStrings("! Unknown command /x · /help", notice.current(16_000).?);
    notice.dismiss();
    try std.testing.expectEqual(@as(?[]const u8, null), notice.current(12_001));
    // A long notice is cut on a character.
    notice.show(comptime repeat("é", 200), 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(notice.current(0).?));
    try std.testing.expectEqual(@as(usize, 256), notice.current(0).?.len);

    try std.testing.expectEqual(Tone.quiet, bar(.{ .notice = "Copied 12 lines", .width = 80 }).tone);
    try std.testing.expectEqual(Tone.attention, bar(.{ .notice = "! Unknown command /x · /help", .width = 80 }).tone);
    const unconfirmed = bar(.{ .needs = "! Not confirmed · ctrl+r retries", .notice = "Copied 12 lines", .width = 80 });
    try std.testing.expectEqualStrings("! Not confirmed · ctrl+r retries", unconfirmed.left);
    try std.testing.expectEqual(Tone.attention, unconfirmed.tone);
}

test "the stop key shows on the right while work can be stopped, and drops first when the row is short" {
    const alone = bar(.{ .stoppable = true, .width = 80 });
    try std.testing.expect(alone.stop);
    try std.testing.expectEqual(@as(u16, 80 - 11 - 1), alone.stop_column);
    try std.testing.expectEqualStrings("", alone.left);

    const needs = "! Not confirmed · ctrl+r retries"; // 32 cells
    const both = bar(.{ .needs = needs, .stoppable = true, .width = 80 });
    try std.testing.expect(both.stop);
    try std.testing.expectEqualStrings(needs, both.left);
    // 32 + 2 + 11 + 1 cells fit exactly in 46; one fewer drops the stop key.
    try std.testing.expect(bar(.{ .needs = needs, .stoppable = true, .width = 46 }).stop);
    const narrow = bar(.{ .needs = needs, .stoppable = true, .width = 45 });
    try std.testing.expect(!narrow.stop);
    try std.testing.expectEqualStrings(needs, narrow.left);
    try std.testing.expect(!bar(.{ .stoppable = true, .width = 11 }).stop);
    try std.testing.expect(bar(.{ .stoppable = true, .width = 12 }).stop);
    try std.testing.expect(!bar(.{ .stoppable = false, .width = 80 }).stop);
}

test "the key that ends what needs the person is the part after its last separator" {
    try std.testing.expectEqualStrings("Ctrl-R retries original", needsKey("! Not confirmed · Ctrl-R retries original"));
    try std.testing.expectEqualStrings("/discard", needsKey("Rejected · /discard"));
    try std.testing.expectEqualStrings("", needsKey("Sending…"));
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
    // Set once per change.
    var shown: Title = .{};
    try std.testing.expectEqualStrings("Fix flaky store test · rui", shown.next("Fix flaky store test", 0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), shown.next("Fix flaky store test", 0));
    try std.testing.expectEqualStrings("Fix flaky store test · rui · 1 needs you", shown.next("Fix flaky store test", 1).?);
    try std.testing.expectEqualStrings("rui · 1 needs you", shown.next(null, 1).?);
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
