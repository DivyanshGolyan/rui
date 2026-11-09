//! Skill rows for the composer's list: the `/word` the caret is in, read by
//! the rule the Host binds Message text with, the catalog's skills that
//! word's name starts, and the edit Tab or Enter makes for a row. The text
//! is the truth: a skill binds because its `/name` is in the sent text, so
//! nothing here is kept beside the draft.
const std = @import("std");
const skill_reference = @import("skill_reference.zig");
const slash_commands = @import("slash_commands.zig");
const skill_suggestions = @import("skill_suggestions.zig");

/// The `/word` the caret is in or ends: `draft[slash]` is its `/`, and
/// `draft[slash + 1 .. end]` its name bytes, none while only `/` is typed.
pub const Word = struct {
    slash: usize,
    end: usize,

    pub fn name(self: Word, draft: []const u8) []const u8 {
        return draft[self.slash + 1 .. self.end];
    }
};

/// The `/word` around `caret`: a `/` where the Host's rule starts a
/// reference, then name bytes up to the caret, through any name bytes after
/// it. Null when the caret is in no such word.
pub fn atCaret(draft: []const u8, caret: usize) ?Word {
    var scanner: skill_reference.References = .{};
    var slash: usize = 0;
    for (draft[0..caret], 0..) |byte, index| {
        _ = scanner.feed(byte);
        if (scanner.state == .slash) slash = index;
    }
    if (scanner.state != .slash and scanner.state != .name) return null;
    var end = caret;
    while (end < draft.len) : (end += 1) {
        _ = scanner.feed(draft[end]);
        if (scanner.state != .name) break;
    }
    return .{ .slash = slash, .end = end };
}

/// A suggestion page, the name prefix it was read for, and which read it
/// answered: the shell numbers each read, so another page is another list,
/// which no key acts on until a frame draws it.
pub const Held = struct {
    prefix: []const u8,
    page: *const skill_suggestions.Page,
    read: u64,
};

/// Whether `typed` needs a read: no page is held, or the held one is for a
/// prefix `typed` does not start with, or it left matches out.
pub fn wants(typed: []const u8, held: ?Held) bool {
    const kept = held orelse return true;
    if (!std.mem.startsWith(u8, typed, kept.prefix)) return true;
    return kept.page.total != kept.page.entries.len;
}

/// Each skill row's text, `/name `: a row shows `/name` and completes
/// `name `. Held here, at one address, so a list can borrow it.
pub const Rows = struct {
    text: [slash_commands.List.capacity][1 + 64 + 1]u8 = undefined,

    /// The rows for a word whose name is `typed`: `commands` first, when
    /// the word starts the draft, then the held page's skills `typed`
    /// starts, as many as the list holds. Null when nothing matches.
    pub fn list(self: *Rows, typed: []const u8, commands: ?slash_commands.List, page: *const skill_suggestions.Page) ?slash_commands.List {
        var rows: slash_commands.List = commands orelse .{ .typed = typed };
        std.debug.assert(std.mem.eql(u8, rows.typed, typed));
        for (page.entries) |entry| {
            if (rows.count == slash_commands.List.capacity) break;
            if (!std.mem.startsWith(u8, entry.name, typed)) continue;
            const text = &self.text[rows.count];
            text[0] = '/';
            @memcpy(text[1..][0..entry.name.len], entry.name);
            text[1 + entry.name.len] = ' ';
            rows.entries[rows.count] = .{
                .word = text[1 .. entry.name.len + 2],
                .shown = text[0 .. entry.name.len + 1],
                .description = entry.description,
                .runs = false,
            };
            rows.count += 1;
        }
        return if (rows.count == 0) null else rows;
    }
};

/// What Tab or Enter does to the draft.
pub const Replacement = struct { start: usize, end: usize, text: []const u8 };

/// `entry`'s word in place of the name in the caret's word, with the space
/// after it only at the draft's end, where typing goes on.
pub fn complete(draft: []const u8, word: Word, entry: slash_commands.Entry) Replacement {
    const text = if (word.end == draft.len) entry.word else std.mem.trimEnd(u8, entry.word, " ");
    return .{ .start = word.slash + 1, .end = word.end, .text = text };
}

fn expectWord(draft: []const u8, caret: usize, expected: ?[]const u8) !void {
    const word = atCaret(draft, caret);
    if (expected) |name| {
        try std.testing.expectEqualStrings(name, word.?.name(draft));
    } else try std.testing.expectEqual(@as(?Word, null), word);
}

test "skill completion finds the /word the caret is in by the Host's rule" {
    try expectWord("use /re on it", "use /re".len, "re");
    // Mid-word, the whole name counts, not only the bytes before the caret.
    try expectWord("use /re on it", "use /r".len, "re");
    try expectWord("use /re on it", "use /".len, "re");
    try expectWord("hi /", 4, "");
    try expectWord("(/re", 4, "re");
    try expectWord("/st", 3, "st");
    // Glued to other text, a path, a doubled slash, or before the slash.
    try expectWord("a/re", 4, null);
    try expectWord("/tmp/x", 6, null);
    try expectWord("//c", 3, null);
    try expectWord("x /re", "x ".len, null);
    try expectWord("/Re", 3, null);
    try expectWord("", 0, null);
}

test "skill completion agrees with the Host on every name the Host binds" {
    // Every draft over these bytes up to five long: where the Host's
    // scanner reports a name, the caret at that name's end finds it.
    const alphabet = "/a- (.x";
    var draft: [5]u8 = undefined;
    for (1..draft.len + 1) |len| {
        var counter: usize = 0;
        while (counter < std.math.pow(usize, alphabet.len, len)) : (counter += 1) {
            var rest = counter;
            for (draft[0..len]) |*byte| {
                byte.* = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            const text = draft[0..len];
            var scanner: skill_reference.References = .{};
            for (text, 0..) |byte, index| if (scanner.feed(byte)) |name| try expectWord(text, index, name);
            if (scanner.finish()) |name| try expectWord(text, len, name);
        }
    }
}

test "skill completion lists commands first, then the page's skills the name starts" {
    const entries = [_]skill_suggestions.Entry{
        .{ .name = "recap", .description = "Summarise" },
        .{ .name = "review", .description = "Review a change" },
        .{ .name = "triage", .description = "Sort issues" },
    };
    const page: skill_suggestions.Page = .{ .entries = &entries, .revision = 3, .total = entries.len };
    var rows: Rows = .{};
    const mid = rows.list("re", null, &page).?;
    try std.testing.expectEqual(@as(usize, 2), mid.count);
    try std.testing.expectEqualStrings("/recap", mid.entries[0].shown);
    try std.testing.expectEqualStrings("recap ", mid.entries[0].word);
    try std.testing.expectEqualStrings("/review", mid.entries[1].shown);
    try std.testing.expectEqualStrings("Review a change", mid.entries[1].description);
    try std.testing.expect(!mid.entries[1].runs);
    // At the draft's start the conversation's commands come first.
    const commands = slash_commands.conversation.suggest("/re", .{}).?;
    const start = rows.list("re", commands, &page).?;
    try std.testing.expectEqual(commands.count + 2, start.count);
    for (commands.shown(), start.entries[0..commands.count]) |command, row| try std.testing.expectEqualStrings(command.shown, row.shown);
    try std.testing.expectEqualStrings("/review", start.entries[commands.count + 1].shown);
    try std.testing.expectEqual(@as(?slash_commands.List, null), rows.list("zz", null, &page));
}

test "skill completion stops at the list's capacity" {
    var names: [slash_commands.List.capacity + 2][8]u8 = undefined;
    var entries: [names.len]skill_suggestions.Entry = undefined;
    for (&names, &entries, 0..) |*name, *entry, index| {
        name.* = "skill-00".*;
        name[6] = '0' + @as(u8, @intCast(index / 10));
        name[7] = '0' + @as(u8, @intCast(index % 10));
        entry.* = .{ .name = name, .description = "" };
    }
    const page: skill_suggestions.Page = .{ .entries = &entries, .total = entries.len };
    var rows: Rows = .{};
    const listed = rows.list("", null, &page).?;
    try std.testing.expectEqual(slash_commands.List.capacity, listed.count);
    try std.testing.expectEqualStrings("/skill-23", listed.entries[23].shown);
}

fn expectReplacement(expected: Replacement, actual: Replacement) !void {
    try std.testing.expectEqual(expected.start, actual.start);
    try std.testing.expectEqual(expected.end, actual.end);
    try std.testing.expectEqualStrings(expected.text, actual.text);
}

test "skill completion replaces the caret's name, spacing only at the draft's end" {
    const entry: slash_commands.Entry = .{ .word = "review ", .shown = "/review", .description = "", .runs = false };
    const middle = "use /re on it";
    const inner = complete(middle, atCaret(middle, "use /r".len).?, entry);
    try expectReplacement(.{ .start = "use /".len, .end = "use /re".len, .text = "review" }, inner);
    const last = "use /re";
    try expectReplacement(.{ .start = "use /".len, .end = last.len, .text = "review " }, complete(last, atCaret(last, last.len).?, entry));
    // A command row at the draft's end makes the bytes Tab always made.
    const draft = "/st";
    const commands = slash_commands.conversation.suggest(draft, .{}).?;
    var rows: Rows = .{};
    const empty: skill_suggestions.Page = .{};
    const listed = rows.list("st", commands, &empty).?;
    const replacement = complete(draft, atCaret(draft, 1).?, listed.entries[0]);
    var made: [32]u8 = undefined;
    const after = try std.fmt.bufPrint(&made, "{s}{s}{s}", .{ draft[0..replacement.start], replacement.text, draft[replacement.end..] });
    var before: [32]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&before, "{s}{s}", .{ draft, commands.completion(0) }), after);
}

test "skill completion reads again only when the held page cannot answer" {
    const entries = [_]skill_suggestions.Entry{.{ .name = "review", .description = "" }};
    const whole: skill_suggestions.Page = .{ .entries = &entries, .total = 1 };
    const partial: skill_suggestions.Page = .{ .entries = &entries, .total = 30 };
    try std.testing.expect(wants("re", null));
    try std.testing.expect(!wants("rev", .{ .prefix = "re", .page = &whole, .read = 1 }));
    try std.testing.expect(!wants("re", .{ .prefix = "re", .page = &whole, .read = 1 }));
    try std.testing.expect(wants("rev", .{ .prefix = "re", .page = &partial, .read = 1 }));
    try std.testing.expect(wants("r", .{ .prefix = "re", .page = &whole, .read = 1 }));
}
