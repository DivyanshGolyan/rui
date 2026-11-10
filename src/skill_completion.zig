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
    // The rule reads only a word's own bytes and the byte before its `/`,
    // so the caret's word is found near it, at any draft length.
    const References = skill_reference.References;
    const longest = @typeInfo(@FieldType(References, "name")).array.len;
    var start = caret;
    while (start > 0 and References.nameByte(draft[start - 1])) : (start -= 1) {
        if (caret - start == longest) return null;
    }
    if (start == 0 or draft[start - 1] != '/') return null;
    const slash = start - 1;
    if (slash != 0 and !References.opens(draft[slash - 1])) return null;
    var end = caret;
    while (end < draft.len and References.nameByte(draft[end])) : (end += 1) {
        if (end - start == longest) return null;
    }
    // A name the Host would read as prose, as in `/re/file`, is no word.
    if (end < draft.len and !References.ends(draft[end])) return null;
    return .{ .slash = slash, .end = end };
}

/// The `/word` at `caret` a skill can fill: any but the draft's first,
/// which makes the draft a command line that Enter runs, not a Message.
pub fn skillWordAt(draft: []const u8, caret: usize) ?Word {
    const word = atCaret(draft, caret) orelse return null;
    return if (word.slash == 0) null else word;
}

/// The longest name prefix the Host reads suggestions for.
pub const max_prefix_bytes = 64;

const Prefix = struct {
    bytes: [max_prefix_bytes]u8 = undefined,
    len: u8 = 0,

    fn of(typed: []const u8) Prefix {
        var prefix: Prefix = .{ .len = @intCast(typed.len) };
        @memcpy(prefix.bytes[0..typed.len], typed);
        return prefix;
    }

    fn slice(self: *const Prefix) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A read for the shell's worker: the Host's `skill_suggestions` for
/// `prefix`, in the screen's scope (its Session, or the overview's
/// workspace). Its page or failure comes back numbered `read`. `prefix`
/// borrows the `Reads` that asked.
pub const Ask = struct { read: u64, prefix: []const u8 };

/// The composer's suggestion reads: at most one in flight, and the page
/// the latest useful answer held. Each read is numbered, so rows from
/// another page are another list (`Shown.nextOf`'s source), which no key
/// acts on until a frame draws it. Pages are the caller's allocation;
/// every call that lets one go returns it to be freed.
pub const Reads = struct {
    last: u64 = 0,
    pending: ?Numbered = null,
    /// A name whose read failed: not asked again until the name changes.
    failed: ?Prefix = null,
    held: ?Held = null,

    const Numbered = struct { read: u64, prefix: Prefix };
    pub const Held = struct { read: u64, prefix: Prefix, page: skill_suggestions.Page };

    /// The read `typed`, the caret word's name, needs, if any: none while
    /// one runs, for a name the Host would refuse, after that name failed,
    /// or while the held page answers `typed`: its own name, cut off or
    /// not, or a longer one when it holds every skill its name matches.
    pub fn ask(self: *Reads, typed: []const u8) ?Ask {
        if (typed.len > max_prefix_bytes or self.pending != null) return null;
        if (self.failed) |*failed| if (std.mem.eql(u8, failed.slice(), typed)) return null;
        if (self.held) |*held| if (std.mem.startsWith(u8, typed, held.prefix.slice()) and
            (typed.len == held.prefix.len or held.page.total == held.page.entries.len)) return null;
        self.last += 1;
        self.pending = .{ .read = self.last, .prefix = .of(typed) };
        return .{ .read = self.last, .prefix = self.pending.?.prefix.slice() };
    }

    /// Read `read`'s page, for the caret word's name now, `typed` (null when
    /// the caret is in no `/word`). It is held when it is the read in flight
    /// and `typed` still starts with what it asked for; returns the page to
    /// free: this one when stale, else the one it replaced.
    pub fn answer(self: *Reads, read: u64, page: skill_suggestions.Page, typed: ?[]const u8) ?skill_suggestions.Page {
        const pending = self.pending orelse return page;
        if (pending.read != read) return page;
        self.pending = null;
        self.failed = null;
        const now = typed orelse return page;
        if (!std.mem.startsWith(u8, now, pending.prefix.slice())) return page;
        const replaced = if (self.held) |held| held.page else null;
        self.held = .{ .read = read, .prefix = pending.prefix, .page = page };
        return replaced;
    }

    /// Read `read` failed; the held page stays.
    pub fn fail(self: *Reads, read: u64) void {
        const pending = self.pending orelse return;
        if (pending.read != read) return;
        self.failed = pending.prefix;
        self.pending = null;
    }

    /// Another scope: nothing held or in flight counts. Returns the held
    /// page to free.
    pub fn reset(self: *Reads) ?skill_suggestions.Page {
        const held = self.held;
        self.* = .{ .last = self.last };
        return if (held) |kept| kept.page else null;
    }

    /// The Palette's rows for the draft at `revision`, with the caret at
    /// `caret`, after `previous`. In a `/word`: `commands` (the draft's own
    /// command list) when the word starts the draft, then the held page's
    /// skills the word's name starts, a new list for each page and each
    /// word. Anywhere else, `commands` alone, as a command's later words
    /// list. Null when nothing matches.
    pub fn shown(self: *const Reads, rows: *Rows, draft: []const u8, caret: usize, revision: u64, commands: ?slash_commands.List, previous: ?slash_commands.Shown) ?slash_commands.Shown {
        const word = skillWordAt(draft, caret) orelse return slash_commands.Shown.next(previous, revision, commands);
        const typed = word.name(draft);
        const held = if (self.held) |*kept| (if (std.mem.startsWith(u8, typed, kept.prefix.slice())) kept else null) else null;
        const none: skill_suggestions.Page = .{};
        const page = if (held) |kept| &kept.page else &none;
        // The read in the high half, the word's `/` in the low: a draft
        // holds far fewer than 2^32 bytes, and reads count from 1.
        const source = if (held) |kept| (kept.read << 32) | @as(u32, @intCast(word.slash)) else 0;
        return slash_commands.Shown.nextOf(previous, revision, source, rows.list(typed, page));
    }
};

/// Each skill row's text, `/name `: a row shows `/name` and completes
/// `name `. Held here, at one address, so a list can borrow it.
pub const Rows = struct {
    text: [slash_commands.List.capacity][1 + 64 + 1]u8 = undefined,

    /// The rows for a word whose name is `typed`: the held page's skills
    /// `typed` starts, as many as the list holds. Null when nothing matches.
    pub fn list(self: *Rows, typed: []const u8, page: *const skill_suggestions.Page) ?slash_commands.List {
        var rows: slash_commands.List = .{ .typed = typed };
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

/// What Tab, or Enter on a row that runs nothing, does with `shown`'s
/// highlighted row, built for `draft` with the caret at `caret`: the row's
/// word in place of the caret's `/word` name, else, for a command's later
/// word, the rest of the row's word at the draft's end.
pub fn edit(draft: []const u8, caret: usize, shown: *const slash_commands.Shown) Replacement {
    if (skillWordAt(draft, caret)) |word| return complete(draft, word, shown.list.entries[shown.highlight]);
    return .{ .start = draft.len, .end = draft.len, .text = shown.completion() };
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
    // A name followed by a byte the Host does not end a reference with is
    // prose, wherever the caret is in it.
    try expectWord("use /re/file", "use /re".len, null);
    try expectWord("use /re/file", "use /r".len, null);
    try expectWord("use /re_name", "use /re".len, null);
    try expectWord("use /re). ok", "use /re".len, "re");
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

test "skill completion lists the page's skills the name starts" {
    const entries = [_]skill_suggestions.Entry{
        .{ .name = "recap", .description = "Summarise" },
        .{ .name = "review", .description = "Review a change" },
        .{ .name = "triage", .description = "Sort issues" },
    };
    const page: skill_suggestions.Page = .{ .entries = &entries, .revision = 3, .total = entries.len };
    var rows: Rows = .{};
    const mid = rows.list("re", &page).?;
    try std.testing.expectEqual(@as(usize, 2), mid.count);
    try std.testing.expectEqualStrings("/recap", mid.entries[0].shown);
    try std.testing.expectEqualStrings("recap ", mid.entries[0].word);
    try std.testing.expectEqualStrings("/review", mid.entries[1].shown);
    try std.testing.expectEqualStrings("Review a change", mid.entries[1].description);
    try std.testing.expect(!mid.entries[1].runs);
    try std.testing.expectEqual(@as(?slash_commands.List, null), rows.list("zz", &page));
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
    const listed = rows.list("", &page).?;
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
}

test "skill rows give way to the command's own list where the caret is in no /word" {
    var reads: Reads = .{};
    var rows: Rows = .{};
    // After a command word, its next word's choices list as they always did.
    const draft = "/configure ";
    const listed = slash_commands.conversation.suggest(draft, .{});
    const shown = reads.shown(&rows, draft, draft.len, 5, listed, null).?;
    const plain = slash_commands.Shown.next(null, 5, listed).?;
    try std.testing.expectEqual(plain.list.count, shown.list.count);
    try std.testing.expectEqual(plain.source, shown.source);
    try std.testing.expectEqualStrings(plain.list.entries[0].word, shown.list.entries[0].word);
}

test "a draft's first /word is the command's: it lists commands, never skills" {
    const entries = [_]skill_suggestions.Entry{.{ .name = "status-report", .description = "" }};
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.ask("sta").?;
    _ = reads.answer(1, testPage(&entries), "sta");
    // Enter runs a draft that starts with `/` as a command, so a skill
    // chosen there would never be sent: the word lists its commands alone.
    const draft = "/sta";
    const commands = slash_commands.conversation.suggest(draft, .{});
    const shown = reads.shown(&rows, draft, draft.len, 1, commands, null).?;
    try std.testing.expectEqual(slash_commands.Shown.next(null, 1, commands).?.list.count, shown.list.count);
    for (shown.list.shown()) |entry| try std.testing.expect(!std.mem.eql(u8, entry.shown, "/status-report"));
    // A later word lists the skill.
    try std.testing.expectEqualStrings("/status-report", reads.shown(&rows, "x /sta", "x /sta".len, 2, null, null).?.list.entries[0].shown);
}

test "a caret moved to another /word is another list, which no key takes until drawn" {
    const entries = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "" }, .{ .name = "review", .description = "" } };
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.ask("re").?;
    _ = reads.answer(1, testPage(&entries), "re");
    const draft = "a /re b /re";
    var first = reads.shown(&rows, draft, "a /re".len, 7, null, null).?;
    first.highlight = 1;
    first.drew(true);
    // Same draft, same revision: only the caret moved.
    const second = reads.shown(&rows, draft, draft.len, 7, null, first).?;
    try std.testing.expectEqual(@as(usize, 0), second.highlight);
    try std.testing.expectEqual(.hidden, second.seen);
    const again = reads.shown(&rows, draft, "a /re".len, 7, null, first).?;
    try std.testing.expectEqual(@as(usize, 1), again.highlight);
}

test "Tab or Enter on a row replaces the caret's name, or adds a later word's rest at the end" {
    const entries = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "" }, .{ .name = "review", .description = "" } };
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.ask("re").?;
    _ = reads.answer(1, testPage(&entries), "re");
    const draft = "use /re on it";
    var shown = reads.shown(&rows, draft, "use /r".len, 1, null, null).?;
    shown.highlight = 1;
    try expectReplacement(.{ .start = "use /".len, .end = "use /re".len, .text = "review" }, edit(draft, "use /r".len, &shown));
    const command = "/configure ";
    const listed = reads.shown(&rows, command, command.len, 2, slash_commands.conversation.suggest(command, .{}), null).?;
    try expectReplacement(.{ .start = command.len, .end = command.len, .text = listed.completion() }, edit(command, command.len, &listed));
}

fn testPage(entries: []const skill_suggestions.Entry) skill_suggestions.Page {
    return .{ .entries = entries, .total = entries.len };
}

test "skill reads ask once per name, one at a time, and not while the held page answers" {
    const entries = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "Summarise" }, .{ .name = "review", .description = "Review a change" } };
    var reads: Reads = .{};
    const first = reads.ask("re").?;
    try std.testing.expectEqual(@as(u64, 1), first.read);
    try std.testing.expectEqualStrings("re", first.prefix);
    // One read at a time: typing on waits for its answer.
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("rev"));
    try std.testing.expectEqual(@as(?skill_suggestions.Page, null), reads.answer(1, testPage(&entries), "rev"));
    // The whole catalog under `re` is held, so narrowing reads nothing.
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("rev"));
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("re"));
    // A shorter name, or a page that left matches out, reads again.
    try std.testing.expectEqual(@as(u64, 2), reads.ask("r").?.read);
    const replaced = reads.answer(2, .{ .entries = entries[0..1], .total = 30 }, "r").?;
    try std.testing.expectEqual(@as(usize, 2), replaced.entries.len);
    // Cut off at the Host's row limit, it still answers its own name: a
    // caret resting on `/r` reads nothing more.
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("r"));
    // It may leave out skills a longer name matches: `/rev` reads again.
    try std.testing.expectEqual(@as(u64, 3), reads.ask("rev").?.read);
    // A name longer than the Host reads asks nothing.
    var fresh: Reads = .{};
    try std.testing.expectEqual(@as(?Ask, null), fresh.ask(&@as([max_prefix_bytes + 1]u8, @splat('a'))));
    try std.testing.expect(fresh.ask(&@as([max_prefix_bytes]u8, @splat('a'))) != null);
}

test "skill reads drop an answer the word moved past, or one a reset left behind" {
    const entries = [_]skill_suggestions.Entry{.{ .name = "review", .description = "" }};
    var reads: Reads = .{};
    _ = reads.ask("re").?;
    // The person typed another word while the read ran: its page answers
    // nothing now, so it comes back to be freed and the new word reads.
    const moved = reads.answer(1, testPage(&entries), "x").?;
    try std.testing.expectEqual(@as(usize, 1), moved.entries.len);
    try std.testing.expectEqual(@as(?Reads.Held, null), reads.held);
    try std.testing.expectEqual(@as(u64, 2), reads.ask("x").?.read);
    // The caret left every `/word`: nothing to answer.
    try std.testing.expect(reads.answer(2, testPage(&entries), null) != null);
    // Another scope (a Session switched) resets; the earlier scope's
    // answer, arriving while the new scope's read runs, is dropped.
    _ = reads.ask("re").?;
    try std.testing.expectEqual(@as(?skill_suggestions.Page, null), reads.reset());
    try std.testing.expectEqual(@as(u64, 4), reads.ask("re").?.read);
    try std.testing.expect(reads.answer(3, testPage(&entries), "re") != null);
    try std.testing.expectEqual(@as(?Reads.Held, null), reads.held);
    try std.testing.expectEqual(@as(?skill_suggestions.Page, null), reads.answer(4, testPage(&entries), "re"));
    try std.testing.expectEqual(@as(usize, 1), reads.reset().?.entries.len);
}

test "a failed skill read is not asked again for the same name" {
    var reads: Reads = .{};
    _ = reads.ask("re").?;
    reads.fail(1);
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("re"));
    try std.testing.expectEqual(@as(u64, 2), reads.ask("rev").?.read);
    // A failure of a read no longer asked for changes nothing.
    reads.fail(1);
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("rev"));
}

test "skill rows are the held page's, numbered by the read that made them" {
    const entries = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "Summarise" }, .{ .name = "review", .description = "Review a change" } };
    var reads: Reads = .{};
    var rows: Rows = .{};
    const draft = "use /re";
    // No page yet, and a word past the draft's start lists no commands.
    try std.testing.expectEqual(@as(?slash_commands.Shown, null), reads.shown(&rows, draft, draft.len, 1, slash_commands.conversation.suggest("/re", .{}), null));
    _ = reads.ask("re").?;
    _ = reads.answer(1, testPage(&entries), "re");
    const shown = reads.shown(&rows, draft, draft.len, 1, null, null).?;
    try std.testing.expectEqual(@as(usize, 2), shown.list.count);
    try std.testing.expect(shown.source != 0);
    try std.testing.expectEqual(.hidden, shown.seen);
    try std.testing.expectEqualStrings("/review", shown.list.entries[1].shown);
    // The caret in no `/word` shows nothing; the draft's first word lists
    // only its commands.
    try std.testing.expectEqual(@as(?slash_commands.Shown, null), reads.shown(&rows, "use it", 3, 2, null, null));
    const commands = slash_commands.conversation.suggest("/st", .{}).?;
    const start = reads.shown(&rows, "/st", 3, 3, commands, null).?;
    try std.testing.expectEqual(commands.count, start.list.count);
    try std.testing.expectEqual(@as(u64, 0), start.source);
}
