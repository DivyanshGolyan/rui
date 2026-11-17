const std = @import("std");
const session_line = @import("session_line.zig");
const utf8_validation = @import("utf8_validation.zig");
const TerminalText = @import("TerminalText.zig");

pub const Method = session_line.Method;

pub const FooterField = @import("app_input.zig").FooterField;
pub const FooterFocus = @import("app_input.zig").Field;
pub const FooterInput = @import("app_input.zig").FooterInput;
pub const FooterDecision = @import("app_input.zig").FooterDecision;
pub const footerInput = @import("app_input.zig").footerInput;

/// Only the not-yet-applied open effect belongs to the chat's core.
/// Focus belongs to app_input.State; only a visible choice
/// is modal. Read completion itself never goes through this transition.
pub const Footer = struct {
    pending: ?FooterField = null,

    pub fn step(self: *Footer, focus: *@import("app_input.zig").State, has_effort: bool, input: FooterInput) FooterDecision {
        const waiting = self.pending != null;
        var decision = @import("app_input.zig").step(focus, .{}, .{ .footer = .{ .has_effort = has_effort, .input = input } }).footer.?;
        self.pending = decision.open_choice;
        if (waiting and input == .escape) decision.forward = false;
        return decision;
    }
};

pub const ChoiceAction = enum { pick, close };
pub const ChoiceKey = struct { text: []const u8, action: ChoiceAction };
pub const ChoiceKeys = struct { text: []const u8, actions: [2]ChoiceKey };
pub const ChoiceState = enum { closed, pick, retry };

pub fn choiceKeys(has_choice: bool) ChoiceKeys {
    const pick = "enter pick";
    const retry = "enter retry";
    const close = "esc close";
    return .{
        .text = if (has_choice) pick ++ " · " ++ close else retry ++ " · " ++ close,
        .actions = .{
            .{ .text = if (has_choice) pick else retry, .action = .pick },
            .{ .text = close, .action = .close },
        },
    };
}

pub const FooterKeys = struct {
    text: []const u8,
    action: enum { info, pick },
    other_actions: bool,
    choice: ?ChoiceKeys = null,
};

pub fn footerKeys(choice: ChoiceState) FooterKeys {
    if (choice == .closed) return .{ .text = "alt+i info", .action = .info, .other_actions = true };
    const keys = choiceKeys(choice == .pick);
    return .{ .text = keys.actions[0].text, .action = .pick, .other_actions = false, .choice = keys };
}

pub const FooterSpan = struct { text: []const u8, field: ?FooterField = null };
pub const FooterSpans = struct {
    text: []const u8 = "",
    spans: [12]FooterSpan = undefined,
    len: usize = 0,

    fn append(self: *FooterSpans, text: []const u8, field: ?FooterField) void {
        if (text.len == 0) return;
        self.spans[self.len] = .{ .text = text, .field = field };
        self.len += 1;
    }
};

pub const notice_ms = 5_000;

pub const NoticeAnswers = enum { other, panel_copy };

pub fn Notice(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        bytes: [capacity]u8 = undefined,
        len: usize = 0,
        shown_ms: ?u64 = null,
        answers: NoticeAnswers = .other,

        pub fn show(self: *Self, text: []const u8, now_ms: u64) void {
            self.answers = .other;
            const len = utf8_validation.scalarStart(text, @min(text.len, capacity));
            std.mem.copyForwards(u8, self.bytes[0..len], text[0..len]);
            self.len = len;
            self.shown_ms = now_ms;
        }

        pub fn showCopy(self: *Self, now_ms: u64, answers: NoticeAnswers) void {
            self.show("Sent to clipboard", now_ms);
            self.answers = answers;
        }

        pub fn showsPanelCopy(self: *const Self, now_ms: u64) bool {
            return self.answers == .panel_copy and self.current(now_ms) != null;
        }

        pub fn dismiss(self: *Self) void {
            self.shown_ms = null;
        }

        pub fn current(self: *const Self, now_ms: u64) ?[]const u8 {
            const shown = self.shown_ms orelse return null;
            return if (now_ms -| shown < notice_ms) self.bytes[0..self.len] else null;
        }

        pub fn expire(self: *Self, now_ms: u64) bool {
            if (self.shown_ms == null or self.current(now_ms) != null) return false;
            self.shown_ms = null;
            return true;
        }
    };
}

pub fn noticeLine(arena: std.mem.Allocator, notice: []const u8) std.mem.Allocator.Error![]const u8 {
    const capacity = std.math.mul(usize, notice.len, TerminalText.max_bytes_per_byte) catch return error.OutOfMemory;
    var out: std.Io.Writer = .fixed(try arena.alloc(u8, capacity));
    var text: TerminalText = .{ .mode = .label };
    for (notice) |byte| {
        if (byte == '\n' or byte == '\r') {
            text.finish(&out) catch unreachable;
            out.writeByte(' ') catch unreachable;
        } else text.feed(&out, &.{byte}) catch unreachable;
    }
    text.finish(&out) catch unreachable;
    return out.buffered();
}
test "notice text flattens result lines and escapes terminal controls before Footer draws it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Saved. ! warning\\x1b", try noticeLine(arena.allocator(), "Saved.\n! warning\x1b"));
    try std.testing.expectEqualStrings("界e\u{301}", try noticeLine(arena.allocator(), "界e\u{301}"));
}

pub const stop_key = session_line.stop_hint;

pub const Send = struct { needs: ?[]const u8 = null, progress: ?[]const u8 = null };

pub fn send(status: ?[]const u8, in_flight: bool) Send {
    const text = status orelse return .{};
    return if (text.len == 0) .{} else if (in_flight) .{ .progress = text } else .{ .needs = text };
}

test "opening and decision progress share the footer while unresolved decisions retain their state" {
    const same = struct {
        fn text(want: ?[]const u8, got: ?[]const u8) !void {
            try std.testing.expectEqual(want == null, got == null);
            if (want) |expected| try std.testing.expectEqualStrings(expected, got.?);
        }
        fn check(want: Send, got: Send) !void {
            try text(want.needs, got.needs);
            try text(want.progress, got.progress);
        }
    }.check;
    try same(.{ .progress = "Opening…" }, send("Opening…", true));
    try same(.{ .needs = "! Not confirmed · ctrl+r retries original" }, send("! Not confirmed · ctrl+r retries original", false));
    try same(.{}, send("", false));
    for ([_]bool{ false, true }) |in_flight| try same(.{}, send(null, in_flight));
    try std.testing.expectEqualStrings("! Unknown command /x", bar(.{ .progress = "Opening…", .notice = "! Unknown command /x", .width = 80 }).notice.?);
    const opening = bar(.{ .progress = "Opening…", .overview = "! Other Session failed", .width = 80 });
    try std.testing.expectEqualStrings("", opening.left);
    try std.testing.expectEqualStrings("Opening…", opening.notice.?);
    try std.testing.expectEqual(Tone.quiet, opening.tone);
    try std.testing.expectEqualStrings("! x", bar(.{ .needs = "! x", .notice = "Copied 3 lines", .progress = "Opening…", .width = 80 }).left);
}

pub const facts_bytes = @import("protocol.zig").max_workspace_bytes + session_line.capacity + " · ".len + "Stopping and archiving".len;

pub fn factsRow(buffer: *[facts_bytes]u8, facts: ?session_line.Facts, name: []const u8, badge: ?[]const u8, width: usize, method: Method) []const u8 {
    return factsSpans(buffer, facts, name, badge, width, method).text;
}

pub fn factsSpans(buffer: *[facts_bytes]u8, facts: ?session_line.Facts, name: []const u8, badge: ?[]const u8, width: usize, method: Method) FooterSpans {
    var result: FooterSpans = .{};
    const separator = session_line.cells(session_line.separator, method);
    const tail = if (badge) |text| separator + session_line.cells(text, method) else 0;
    const room = width -| tail;
    var percent: [session_line.left_text.len]u8 = undefined;
    var folder_buffer: [@import("protocol.zig").max_workspace_bytes + 1]u8 = undefined;
    const folder: ?[]const u8 = if (facts) |value| if (value.folder) |path| blk: {
        const short = @import("home_path.zig").shortPath(value.home, path);
        break :blk std.fmt.bufPrint(&folder_buffer, "{s}{s}", .{ short.prefix, short.rest }) catch unreachable;
    } else null else null;
    const parts: [6]?[]const u8 = if (facts) |value| .{
        if (folder == null) value.name else null,
        value.model,
        if (value.effort) |effort| @tagName(effort) else null,
        if (if (folder == null) value.left else null) |left| std.fmt.bufPrint(&percent, "{d}% left", .{left}) catch unreachable else null,
        if (folder == null and value.asks) "ask" else null,
        folder,
    } else .{ name[0..@min(name.len, session_line.max_name_bytes)], null, null, null, null, null };
    var kept: [6]?[]const u8 = @splat(null);
    var used: usize = 0;
    var count: usize = 0;
    var model_buffer: [facts_bytes]u8 = undefined;
    var name_buffer: [facts_bytes]u8 = undefined;
    for (if (folder != null) [_]usize{ 2, 1, 5, 4, 3, 0 } else [_]usize{ 4, 2, 1, 3, 0, 5 }) |index| {
        const text = parts[index] orelse continue;
        if (text.len == 0) continue;
        const join = if (count != 0) separator else 0;
        const available = room -| used -| join;
        var shown = text;
        if (session_line.cells(text, method) > available) {
            if (index == 0) {
                var out = std.Io.Writer.fixed(&name_buffer);
                words(&out, text, available, method);
                shown = out.buffered();
            } else if (index == 1) {
                const mark = session_line.cells(session_line.ellipsis, method);
                if (available < mark) continue;
                const prefix = text[0..session_line.fit(text, available - mark, method).len];
                shown = std.fmt.bufPrint(&model_buffer, "{s}{s}", .{ prefix, session_line.ellipsis }) catch unreachable;
            } else continue;
        }
        if (shown.len == 0) continue;
        kept[index] = shown;
        used += join + session_line.cells(shown, method);
        count += 1;
    }
    var out = std.Io.Writer.fixed(buffer);
    for (kept, 0..) |part, index| if (part) |text| {
        if (out.end != 0) {
            const start = out.end;
            out.writeAll(session_line.separator) catch unreachable;
            result.append(buffer[start..out.end], null);
        }
        const start = out.end;
        out.writeAll(text) catch unreachable;
        result.append(buffer[start..out.end], switch (index) {
            1 => .model,
            2 => .effort,
            else => null,
        });
    };
    if (badge) |text| {
        const start = out.end;
        if (out.end != 0) out.writeAll(session_line.separator) catch unreachable;
        out.writeAll(text[0..session_line.fit(text, width -| session_line.cells(out.buffered(), method), method).len]) catch unreachable;
        result.append(buffer[start..out.end], null);
    }
    result.text = out.buffered();
    return result;
}

fn words(out: *std.Io.Writer, text: []const u8, room: usize, method: Method) void {
    if (session_line.cells(text, method) <= room) return out.writeAll(text) catch unreachable;
    const mark = session_line.cells(session_line.ellipsis, method);
    if (room <= mark) return;
    const fits = session_line.fit(text, room - mark, method).len;
    var end = fits;
    if (text[fits] != ' ') end = std.mem.lastIndexOfScalar(u8, text[0..fits], ' ') orelse fits;
    end = std.mem.trimEnd(u8, text[0..end], " ").len;
    if (end == 0) end = fits;
    out.print("{s}{s}", .{ text[0..end], session_line.ellipsis }) catch unreachable;
}

test "the facts row ends with the archive badge, which stays when the row is short" {
    var buffer: [facts_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("k7m2qx", factsRow(&buffer, null, "k7m2qx", null, 78, .unicode));
    try std.testing.expectEqualStrings("k7m2qx · Archived · /unarchive", factsRow(&buffer, null, "k7m2qx", "Archived · /unarchive", 78, .unicode));
    const facts: session_line.Facts = .{ .name = "Fix flaky store test", .model = "gpt-6.1-sol" };
    const wide = factsRow(&buffer, facts, "k7m2qx", "Archived · /unarchive", 78, .unicode);
    try std.testing.expectEqualStrings("Fix flaky store test · gpt-6.1-sol · Archived · /unarchive", wide);
    const short = factsRow(&buffer, facts, "k7m2qx", "Archived · /unarchive", 40, .unicode);
    try std.testing.expect(std.mem.endsWith(u8, short, " · Archived · /unarchive"));
    try std.testing.expect(session_line.cells(short, .unicode) <= 40);
}

test "a short facts row preserves editable words and ask before context and name" {
    var buffer: [facts_bytes]u8 = undefined;
    const facts: session_line.Facts = .{ .name = "Fix retry deadline", .model = "gpt-6.1-sol", .effort = .high, .left = 100, .asks = true };
    try std.testing.expectEqualStrings("Fix retry deadline · gpt-6.1-sol · high · 100% left · ask", factsRow(&buffer, facts, "ref", null, 140, .unicode));
    try std.testing.expectEqualStrings("gpt-6.1-sol · high · 100% left · ask", factsRow(&buffer, facts, "ref", null, 36, .unicode));
    try std.testing.expectEqualStrings("Fix… · gpt-6.1-sol · high · ask", factsRow(&buffer, facts, "ref", null, 34, .unicode));
    try std.testing.expectEqualStrings("gpt-6… · high · ask", factsRow(&buffer, facts, "ref", null, 19, .unicode));
    try std.testing.expectEqualStrings("gpt-6… · high · ask · Archived", factsRow(&buffer, facts, "ref", "Archived", 30, .unicode));
    for (0..141) |width| {
        const fitted = factsSpans(&buffer, facts, "ref", null, width, .unicode);
        try std.testing.expect(session_line.cells(fitted.text, .unicode) <= width);
        if (width >= 19) {
            try std.testing.expect(std.mem.indexOf(u8, fitted.text, "high") != null);
            try std.testing.expect(std.mem.endsWith(u8, fitted.text, "ask"));
            var fields: usize = 0;
            for (fitted.spans[0..fitted.len]) |span| fields += @intFromBool(span.field != null);
            try std.testing.expectEqual(@as(usize, 2), fields);
        }
    }
}

pub fn needsKey(needs: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, needs, " · ") orelse return "";
    return needs[at + " · ".len ..];
}

pub const Tone = enum { quiet, attention };

pub const Bar = struct {
    notice: ?[]const u8 = null,
    left: []const u8 = "",
    tone: Tone = .quiet,
    stop: bool = false,
    stop_column: u16 = 0,
};

pub const Facts = struct {
    needs: ?[]const u8 = null,
    progress: ?[]const u8 = null,
    notice: ?[]const u8 = null,
    overview: ?[]const u8 = null,
    stoppable: bool = false,
    width: u16,
    method: Method = .unicode,
};

pub fn fitsBar(result: []const u8) bool {
    return std.mem.indexOfScalar(u8, result, '\n') == null;
}

test "a result of one line is a notice; one of two lines is a page" {
    try std.testing.expect(fitsBar("Saved."));
    try std.testing.expect(!fitsBar("Saved.\n! Host unavailable"));
}

const gap = 2;

pub fn bar(facts: Facts) Bar {
    var result: Bar = .{ .notice = facts.notice orelse facts.progress };
    if (facts.needs) |needs| {
        result.left = needs;
        result.tone = .attention;
    } else if (if (facts.progress == null) facts.overview else null) |left| {
        result.left = left;
        result.tone = if (std.mem.startsWith(u8, left, "!")) .attention else .quiet;
    }
    if (!facts.stoppable) return result;
    const stop_cells = session_line.cells(stop_key, facts.method);
    const left_cells = session_line.cells(result.left, facts.method);
    const used = if (left_cells == 0) 0 else left_cells + gap;
    if (used + stop_cells + 1 > facts.width) return result;
    result.stop = true;
    result.stop_column = @intCast(facts.width - stop_cells - 1);
    return result;
}

pub fn halfScreen(height: usize) usize {
    return @max(1, height / 2);
}

const newer_mark = @import("marks.zig").marks.get(.newer).unicode;
pub const marker_bytes = newer_mark.len + 1 + 20 + " new".len;

pub fn marker(buffer: *[marker_bytes]u8, new_entries: u64) []const u8 {
    if (new_entries == 0) return newer_mark;
    return std.fmt.bufPrint(buffer, "{s} {d} new", .{ newer_mark, new_entries }) catch unreachable;
}

pub const title_name_bytes = 80;
pub const title_bytes = TerminalText.max_bytes_per_byte * title_name_bytes + session_line.ellipsis.len + " · rui · ".len + 20 + " needs you".len;

pub fn title(buffer: *[title_bytes]u8, session: ?[]const u8, needs_you: u64) []const u8 {
    var out = std.Io.Writer.fixed(buffer);
    if (session) |name| {
        const cut = utf8_validation.scalarStart(name, @min(name.len, title_name_bytes));
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

pub const Title = struct {
    bytes: [title_bytes]u8 = undefined,
    len: ?usize = null,

    pub fn next(self: *Title, session: ?[]const u8, needs_you: u64) ?[]const u8 {
        var buffer: [title_bytes]u8 = undefined;
        const text = title(&buffer, session, needs_you);
        if (self.len) |len| if (std.mem.eql(u8, self.bytes[0..len], text)) return null;
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
        return self.bytes[0..text.len];
    }
};

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
    try std.testing.expect(notice.current(9_000) != null);
    notice.show("! Unknown command /x", 12_000);
    try std.testing.expectEqualStrings("! Unknown command /x", notice.current(16_000).?);
    notice.dismiss();
    try std.testing.expectEqual(@as(?[]const u8, null), notice.current(12_001));
    notice.show(comptime repeat("é", 200), 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(notice.current(0).?));
    try std.testing.expectEqual(@as(usize, 256), notice.current(0).?.len);

    try std.testing.expectEqual(Tone.quiet, bar(.{ .notice = "Copied 12 lines", .width = 80 }).tone);
    try std.testing.expectEqualStrings("! Unknown command /x", bar(.{ .notice = "! Unknown command /x", .width = 80 }).notice.?);
    const unconfirmed = bar(.{ .needs = "! Not confirmed · ctrl+r retries", .notice = "Copied 12 lines", .width = 80 });
    try std.testing.expectEqualStrings("! Not confirmed · ctrl+r retries", unconfirmed.left);
    try std.testing.expectEqual(Tone.attention, unconfirmed.tone);
}

test "the stop key shows on the right while work can be stopped, and drops first when the row is short" {
    const alone = bar(.{ .stoppable = true, .width = 80 });
    try std.testing.expect(alone.stop);
    try std.testing.expectEqual(@as(u16, 80 - 11 - 1), alone.stop_column);
    try std.testing.expectEqualStrings("", alone.left);

    const needs = "! Not confirmed · ctrl+r retries";
    const both = bar(.{ .needs = needs, .stoppable = true, .width = 80 });
    try std.testing.expect(both.stop);
    try std.testing.expectEqualStrings(needs, both.left);
    try std.testing.expect(bar(.{ .needs = needs, .stoppable = true, .width = 46 }).stop);
    const narrow = bar(.{ .needs = needs, .stoppable = true, .width = 45 });
    try std.testing.expect(!narrow.stop);
    try std.testing.expectEqualStrings(needs, narrow.left);
    try std.testing.expect(!bar(.{ .stoppable = true, .width = 11 }).stop);
    try std.testing.expect(bar(.{ .stoppable = true, .width = 12 }).stop);
    try std.testing.expect(!bar(.{ .stoppable = false, .width = 80 }).stop);
}

test "the key that ends what needs the person is the part after its last separator" {
    try std.testing.expectEqualStrings("ctrl+r retries original", needsKey("! Not confirmed · ctrl+r retries original"));
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
    const hostile = title(&buffer, "a\x07b\x1b\\c\x9c", 0);
    for (hostile) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    try std.testing.expect(std.unicode.utf8ValidateSlice(hostile));
    const long = comptime repeat("é", 60);
    const cut = title(&buffer, long, 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings(comptime repeat("é", 40) ++ "… · rui", cut);
    const worst = title(&buffer, &(@as([200]u8, @splat(0x1b))), std.math.maxInt(u64));
    try std.testing.expect(std.mem.endsWith(u8, worst, "… · rui · 18446744073709551615 needs you"));
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

test "footer focus domain routes opening escape text and drawn click identity" {
    const Case = struct { input: FooterInput, want: FooterDecision };
    for ([_]bool{ false, true }) |effort| {
        for (std.enums.values(FooterFocus)) |focus| {
            const cases = [_]Case{
                .{ .input = .escape, .want = .{ .focus = .input, .forward = focus == .input } },
                .{ .input = .text, .want = .{ .focus = .input, .forward = true } },
                .{ .input = .other, .want = .{ .focus = focus, .forward = true } },
                .{ .input = .enter, .want = .{ .focus = .input, .open_choice = switch (focus) {
                    .input => null,
                    .model => .model,
                    .effort => if (effort) .effort else null,
                }, .forward = focus == .input } },
                .{ .input = .{ .click = .model }, .want = .{ .focus = .input, .open_choice = .model } },
                .{ .input = .{ .click = .effort }, .want = .{ .focus = .input, .open_choice = .effort } },
                .{ .input = .{ .click = null }, .want = .{ .focus = .input, .forward = true } },
            };
            for (cases) |case| try std.testing.expectEqualDeep(case.want, footerInput(focus, effort, case.input));
        }
    }
}

test "footer spans identify only whole model and effort words across widths efforts and permissions" {
    for ([_]usize{ 140, 46 }) |width| for ([_]?session_line.ReasoningEffort{ null, .low, .xhigh }) |effort| for ([_]bool{ false, true }) |asks| {
        var buffer: [facts_bytes]u8 = undefined;
        const facts: session_line.Facts = .{ .name = "Chat", .model = "model", .effort = effort, .left = 62, .asks = asks };
        const fitted = factsSpans(&buffer, facts, "ref", null, width, .unicode);
        var expected: [facts_bytes]u8 = undefined;
        const want = try std.fmt.bufPrint(&expected, "Chat · model{s}{s} · 62% left{s}", .{ if (effort != null) " · " else "", if (effort) |value| @tagName(value) else "", if (asks) " · ask" else "" });
        try std.testing.expectEqualStrings(want, fitted.text);
        var offset: usize = 0;
        var model_count: usize = 0;
        var effort_count: usize = 0;
        for (fitted.spans[0..fitted.len]) |span| {
            try std.testing.expectEqualStrings(fitted.text[offset..][0..span.text.len], span.text);
            offset += span.text.len;
            if (span.field) |field| switch (field) {
                .model => {
                    model_count += 1;
                    try std.testing.expectEqualStrings("model", span.text);
                },
                .effort => {
                    effort_count += 1;
                    try std.testing.expectEqualStrings(@tagName(effort.?), span.text);
                },
            };
        }
        try std.testing.expectEqual(fitted.text.len, offset);
        try std.testing.expectEqual(@as(usize, 1), model_count);
        try std.testing.expectEqual(@as(usize, @intFromBool(effort != null)), effort_count);
    };
    for (0..40) |width| {
        var buffer: [facts_bytes]u8 = undefined;
        const fitted = factsSpans(&buffer, .{ .name = "model · low", .model = "model", .effort = .low, .asks = true }, "ref", null, width, .unicode);
        for (fitted.spans[0..fitted.len]) |span| if (span.field) |field| {
            if (field == .effort) try std.testing.expectEqualStrings("low", span.text) else {
                try std.testing.expect(std.mem.eql(u8, span.text, "model") or std.mem.endsWith(u8, span.text, session_line.ellipsis));
            }
        };
        try std.testing.expect(session_line.cells(fitted.text, .unicode) <= width);
    }
}

test "deferred footer effect is superseded by interaction without making invisible content modal" {
    const inputs: []const FooterInput = &.{ .escape, .text, .other, .{ .click = null }, .enter };
    for (std.enums.values(FooterField)) |field| for (inputs) |input| {
        var owner: @import("app_input.zig").State = .{};
        var footer: Footer = .{ .pending = field };
        const decision = footer.step(&owner, true, input);
        try std.testing.expectEqual(@as(?FooterField, null), footer.pending);
        try std.testing.expectEqual(@as(?FooterField, null), decision.open_choice);
        try std.testing.expectEqual(input == .text or input == .other or input == .click or input == .enter, decision.forward);
    };
    var owner: @import("app_input.zig").State = .{};
    var footer: Footer = .{ .pending = .model };
    const decision = footer.step(&owner, true, .{ .click = .effort });
    try std.testing.expectEqual(@as(?FooterField, .effort), footer.pending);
    try std.testing.expectEqual(@as(?FooterField, .effort), decision.open_choice);
}

test "footer standalone actions describe pick retry and close from one owner" {
    for ([_]ChoiceState{ .pick, .retry }) |state| {
        const keys = footerKeys(state);
        try std.testing.expect(!keys.other_actions);
        try std.testing.expectEqual(.pick, keys.action);
        const choice = keys.choice.?;
        try std.testing.expectEqualStrings(if (state == .pick) "enter pick · esc close" else "enter retry · esc close", choice.text);
        try std.testing.expectEqualStrings(if (state == .pick) "enter pick" else "enter retry", choice.actions[0].text);
        try std.testing.expectEqualStrings("esc close", choice.actions[1].text);
        try std.testing.expectEqual(ChoiceAction.pick, choice.actions[0].action);
        try std.testing.expectEqual(ChoiceAction.close, choice.actions[1].action);
    }
    try std.testing.expect(footerKeys(.closed).choice == null);
}

pub const StandaloneCases = struct {
    pub const Screen = enum { new_chat, chat };
    pub const Phase = enum { open, pending, read_failed, save_failed };
    pub const Ending = enum { escape, close_click, navigate, refresh };
    pub const Case = struct { screen: Screen, field: FooterField, phase: Phase, ending: Ending };

    pub const all: [64]Case = blk: {
        var result: [64]Case = undefined;
        var index: usize = 0;
        for (std.enums.values(Screen)) |screen| for (std.enums.values(FooterField)) |field| for (std.enums.values(Phase)) |phase| for (std.enums.values(Ending)) |ending| {
            result[index] = .{ .screen = screen, .field = field, .phase = phase, .ending = ending };
            index += 1;
        };
        break :blk result;
    };
};

test "copy success shares short reply next-key replacement and expiry owner" {
    var notice: Notice(64) = .{};
    notice.showCopy(10, .panel_copy);
    try std.testing.expect(notice.showsPanelCopy(10));
    notice.dismiss();
    try std.testing.expect(!notice.showsPanelCopy(10));
    notice.showCopy(10, .panel_copy);
    notice.show("failure reply", 11);
    try std.testing.expect(!notice.showsPanelCopy(11));
    notice.showCopy(10, .panel_copy);
    notice.showCopy(11, .other);
    try std.testing.expectEqualStrings("Sent to clipboard", notice.current(11).?);
    try std.testing.expect(!notice.showsPanelCopy(11));
    notice.showCopy(10, .panel_copy);
    try std.testing.expect(!notice.showsPanelCopy(10 + notice_ms));
}

test "empty chat facts fit model effort and home folder with semantic fields" {
    const facts: session_line.Facts = .{ .name = "reference", .model = "gpt-6.1-sol", .effort = .low, .folder = "/home/u/code/rui", .home = "/home/u", .left = 100, .asks = true };
    for ([_]usize{ 33, 46, 140 }) |width| {
        var buffer: [facts_bytes]u8 = undefined;
        const shown = factsSpans(&buffer, facts, "ref", null, width, .unicode);
        try std.testing.expectEqualStrings("gpt-6.1-sol · low · ~/code/rui", shown.text);
        var model: usize = 0;
        var effort: usize = 0;
        for (shown.spans[0..shown.len]) |span| if (span.field) |field| {
            switch (field) {
                .model => model += 1,
                .effort => effort += 1,
            }
        };
        try std.testing.expectEqual(@as(usize, 1), model);
        try std.testing.expectEqual(@as(usize, 1), effort);
    }
    for (0..47) |width| {
        var buffer: [facts_bytes]u8 = undefined;
        const shown = factsSpans(&buffer, facts, "ref", null, width, .unicode);
        try std.testing.expect(session_line.cells(shown.text, .unicode) <= width);
        if (std.mem.indexOf(u8, shown.text, "~/") != null) try std.testing.expect(std.mem.endsWith(u8, shown.text, "~/code/rui"));
    }
}
