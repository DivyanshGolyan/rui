const std = @import("std");
const skill_reference = @import("skill_reference.zig");
const slash_commands = @import("slash_commands.zig");
const skill_suggestions = @import("skill_suggestions.zig");

pub const Word = struct {
    slash: usize,
    end: usize,

    pub fn name(self: Word, draft: []const u8) []const u8 {
        return draft[self.slash + 1 .. self.end];
    }
};

pub fn atCaret(draft: []const u8, caret: usize) ?Word {
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
    if (end < draft.len and !References.ends(draft[end])) return null;
    return .{ .slash = slash, .end = end };
}

pub fn skillWordAt(draft: []const u8, caret: usize) ?Word {
    const kind = slash_commands.conversation.draftOf(draft);
    if (atCaret(draft, caret)) |word| {
        return if (word.slash != 0 and kind == .command) null else word;
    }
    if (kind == .message) return null;
    const whole = atCaret(draft, draft.len) orelse return null;
    return if (whole.slash == 0) whole else null;
}

/// How well a row matches the typed name, best first: its name is the
/// name, starts with it, holds it, or only its description does.
pub const Rank = enum { exact, prefix, inside, description };

/// How a row matches the typed name, and the bytes the list bolds.
pub const Match = struct { rank: Rank, spans: slash_commands.MatchSpans };

/// The one filtering and ranking rule, shared by the Host's bounded skill
/// preview and the composer's combined command/skill rows. Names and
/// descriptions match ASCII case-insensitive substrings.
pub fn match(typed: []const u8, name: []const u8, description: []const u8) ?Match {
    const name_at = std.ascii.findIgnoreCase(name, typed);
    const description_at = std.ascii.findIgnoreCase(description, typed);
    const rank: Rank = if (name_at) |at|
        (if (at != 0) .inside else if (name.len == typed.len) .exact else .prefix)
    else if (description_at != null) .description else return null;
    return .{ .rank = rank, .spans = .{
        .name = if (name_at) |at| .{ .start = 1 + at, .len = typed.len } else null,
        .description = if (description_at) |at| .{ .start = at, .len = typed.len } else null,
    } };
}

/// The shared row order: rank first, then the catalog's byte-lexical name.
/// Incoming preview order may belong to an earlier query and is no tie-breaker.
pub fn order(left_rank: Rank, left_name: []const u8, right_rank: Rank, right_name: []const u8) std.math.Order {
    const ranked = std.math.order(@backingInt(left_rank), @backingInt(right_rank));
    return if (ranked == .eq) std.mem.order(u8, left_name, right_name) else ranked;
}

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

pub const Ask = struct { read: u64, prefix: []const u8 };

pub const Reads = struct {
    last: u64 = 0,
    pending: ?Numbered = null,
    failed: ?Prefix = null,
    held: ?Held = null,

    const Numbered = struct { read: u64, prefix: Prefix };
    pub const Held = struct { read: u64, prefix: Prefix, page: skill_suggestions.Page };

    pub fn ask(self: *Reads, typed: []const u8) ?Ask {
        if (typed.len > max_prefix_bytes or self.pending != null) return null;
        if (self.failed) |*failed| if (std.mem.eql(u8, failed.slice(), typed)) return null;
        if (self.held) |*held| if (std.mem.startsWith(u8, typed, held.prefix.slice()) and
            (typed.len == held.prefix.len or held.page.total == held.page.entries.len)) return null;
        self.last += 1;
        self.pending = .{ .read = self.last, .prefix = .of(typed) };
        return .{ .read = self.last, .prefix = self.pending.?.prefix.slice() };
    }

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

    pub fn fail(self: *Reads, read: u64) void {
        const pending = self.pending orelse return;
        if (pending.read != read) return;
        self.failed = pending.prefix;
        self.pending = null;
    }

    pub fn retry(self: *Reads, read: u64) void {
        const pending = self.pending orelse return;
        if (pending.read == read) self.pending = null;
    }

    pub fn reset(self: *Reads) ?skill_suggestions.Page {
        const held = self.held;
        self.* = .{ .last = self.last };
        return if (held) |kept| kept.page else null;
    }

    pub fn knownWord(self: *const Reads, draft: []const u8, current: ?slash_commands.Shown) ?slash_commands.Span {
        if (current) |built| if (built.list.source_word) |word| {
            if (word.start == 0) return built.list.exactWord();
        };
        var rows: Rows = .{};
        const first = self.shown(&rows, draft, @min(1, draft.len), 0, .{}, null) orelse return null;
        const word = first.list.exactWord() orelse return null;
        return if (word.start == 0) word else null;
    }

    pub fn shown(self: *const Reads, rows: *Rows, draft: []const u8, caret: usize, revision: u64, context: slash_commands.Context, previous: ?slash_commands.Shown) ?slash_commands.Shown {
        const word = skillWordAt(draft, caret) orelse {
            const source = if (context.model) |model| std.hash.Wyhash.hash(0, model) else 0;
            return slash_commands.Shown.nextOf(previous, revision, source, slash_commands.conversation.suggest(draft, context));
        };
        const typed = word.name(draft);
        const held = if (self.held) |*kept| (if (std.mem.startsWith(u8, typed, kept.prefix.slice())) kept else null) else null;
        const none: skill_suggestions.Page = .{};
        const page = if (held) |kept| &kept.page else &none;
        const source = ((if (held) |kept| kept.read else 0) << 32) | (@as(u32, @intCast(word.slash)) + 1);
        const commands = if (word.slash == 0) slash_commands.conversation.listed() else null;
        var listed = rows.list(typed, commands, page) orelse return null;
        listed.source_word = .{ .start = word.slash, .len = word.end - word.slash };
        return slash_commands.Shown.nextOf(previous, revision, source, listed);
    }
};

pub const Rows = struct {
    text: [slash_commands.List.capacity][1 + 64 + 1]u8 = undefined,

    pub fn list(self: *Rows, typed: []const u8, commands: ?slash_commands.List, page: *const skill_suggestions.Page) ?slash_commands.List {
        var rows: slash_commands.List = .{ .typed = typed, .column = if (commands) |listed| listed.column else null };
        for (std.enums.values(Rank)) |rank| {
            if (commands) |listed| for (listed.shown()) |entry| {
                const matched = match(typed, entry.shown[1..], entry.description) orelse continue;
                if (matched.rank != rank) continue;
                if (rows.count == slash_commands.List.capacity) return rows;
                if (rank == .exact and rows.exact == null) rows.exact = rows.count;
                rows.entries[rows.count] = entry;
                rows.entries[rows.count].matches = matched.spans;
                rows.count += 1;
            };
            if (rows.count == slash_commands.List.capacity) return rows;
            const Candidate = struct { entry: *const skill_suggestions.Entry, matched: Match };
            var selected: [slash_commands.List.capacity]Candidate = undefined;
            var count: usize = 0;
            const limit = slash_commands.List.capacity - rows.count;
            for (page.entries) |*entry| {
                if (commands != null and slash_commands.conversation.nameOf(entry.name) != null) continue;
                const matched = match(typed, entry.name, entry.description) orelse continue;
                if (matched.rank != rank) continue;
                var at: usize = 0;
                while (at < count and order(selected[at].matched.rank, selected[at].entry.name, matched.rank, entry.name) != .gt) : (at += 1) {}
                if (at == limit) continue;
                const next = @min(count + 1, limit);
                var move = next - 1;
                while (move > at) : (move -= 1) selected[move] = selected[move - 1];
                selected[at] = .{ .entry = entry, .matched = matched };
                count = next;
            }
            // Format only after ordering. Moving candidates never moves or
            // overwrites the row text that the completed list will borrow.
            for (selected[0..count]) |candidate| {
                const entry = candidate.entry;
                const text = &self.text[rows.count];
                text[0] = '/';
                @memcpy(text[1..][0..entry.name.len], entry.name);
                text[1 + entry.name.len] = ' ';
                if (rank == .exact and rows.exact == null) rows.exact = rows.count;
                rows.entries[rows.count] = .{
                    .word = text[1 .. entry.name.len + 2],
                    .shown = text[0 .. entry.name.len + 1],
                    .description = entry.description,
                    .runs = false,
                    .matches = candidate.matched.spans,
                };
                rows.count += 1;
            }
        }
        return if (rows.count == 0) null else rows;
    }
};

pub const Replacement = struct { start: usize, end: usize, text: []const u8 };

pub fn complete(draft: []const u8, word: Word, entry: slash_commands.Entry) Replacement {
    const text = if (word.end == draft.len) entry.word else std.mem.trimEnd(u8, entry.word, " ");
    return .{ .start = word.slash + 1, .end = word.end, .text = text };
}

pub fn edit(draft: []const u8, caret: usize, shown: *const slash_commands.Shown) Replacement {
    if (skillWordAt(draft, caret)) |word| return complete(draft, word, shown.list.entries[shown.highlight]);
    return .{ .start = draft.len, .end = draft.len, .text = shown.completion() };
}

pub const Taken = union(enum) {
    run: Replacement,
    edit: Replacement,
};

pub fn enter(draft: []const u8, caret: usize, shown: *const slash_commands.Shown) Taken {
    const entry = shown.list.entries[shown.highlight];
    if (skillWordAt(draft, caret)) |word| {
        if (!entry.runs or word.end != draft.len) return .{ .edit = complete(draft, word, entry) };
        return .{ .run = .{ .start = word.slash + 1, .end = word.end, .text = std.mem.trimEnd(u8, entry.word, " ") } };
    }
    const taken = shown.list.enter(shown.highlight);
    if (taken.runs) return .{ .run = .{ .start = draft.len, .end = draft.len, .text = taken.rest } };
    return .{ .edit = edit(draft, caret, shown) };
}

fn expectWord(draft: []const u8, caret: usize, expected: ?[]const u8) !void {
    const word = atCaret(draft, caret);
    if (expected) |name| {
        try std.testing.expectEqualStrings(name, word.?.name(draft));
    } else try std.testing.expectEqual(@as(?Word, null), word);
}

test "skill completion finds the /word the caret is in by the Host's rule" {
    try expectWord("use /re on it", "use /re".len, "re");
    try expectWord("use /re on it", "use /r".len, "re");
    try expectWord("use /re on it", "use /".len, "re");
    try expectWord("hi /", 4, "");
    try expectWord("(/re", 4, "re");
    try expectWord("/st", 3, "st");
    try expectWord("a/re", 4, null);
    try expectWord("/tmp/x", 6, null);
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

test "skill completion lists matching page skills" {
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
    try std.testing.expectEqual(@as(?slash_commands.List, null), rows.list("zz", null, &page));
}

test "skill completion bounds the ranked list, not its candidates" {
    var names: [slash_commands.List.capacity + 2][8]u8 = undefined;
    var entries: [names.len]skill_suggestions.Entry = undefined;
    for (&names, &entries, 0..) |*name, *entry, index| {
        name.* = "skill-00".*;
        name[6] = '0' + @as(u8, @intCast(index / 10));
        name[7] = '0' + @as(u8, @intCast(index % 10));
        entry.* = .{ .name = name, .description = "" };
    }
    entries[entries.len - 1].name = "skill";
    std.mem.reverse(skill_suggestions.Entry, entries[0 .. entries.len - 1]);
    const page: skill_suggestions.Page = .{ .entries = &entries, .total = entries.len };
    var rows: Rows = .{};
    const listed = rows.list("skill", null, &page).?;
    try std.testing.expectEqual(slash_commands.List.capacity, listed.count);
    try std.testing.expectEqualStrings("/skill", listed.entries[0].shown);
    try std.testing.expectEqualStrings("/skill-22", listed.entries[23].shown);
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

test "a /word's list ranks exact, prefix, inside and description matches, commands first in each, and bolds the match" {
    // Expected rows are written out by hand from the rule each case names.
    const skills = [_]skill_suggestions.Entry{
        .{ .name = "triage", .description = "Ask for help sorting issues" },
        .{ .name = "review-help", .description = "Review a pull request" },
        .{ .name = "help-me", .description = "Pair on a task" },
        .{ .name = "help", .description = "Answer questions" },
        .{ .name = "model", .description = "A skill with help a command's name hides" },
        .{ .name = "renew", .description = "Renew a lease" },
        .{ .name = "news", .description = "Read the news" },
        .{ .name = "deploy", .description = "Ship it" },
    };
    const Row = struct { shown: []const u8, bold: []const u8, in_description: bool = false };
    const cases = [_]struct { draft: []const u8, rows: []const Row, known: ?[]const u8 = null }{
        // Exact, then prefix, then inside the name, then only the description.
        .{ .draft = "/help", .known = "/help", .rows = &.{
            .{ .shown = "/help", .bold = "help" },
            .{ .shown = "/help-me", .bold = "help" },
            .{ .shown = "/review-help", .bold = "help" },
            .{ .shown = "/triage", .bold = "help", .in_description = true },
        } },
        // A command and a skill of one rank keep commands first; a
        // description-only command comes after a skill named inside.
        .{ .draft = "/new", .known = "/new", .rows = &.{
            .{ .shown = "/new", .bold = "new" },
            .{ .shown = "/news", .bold = "new" },
            .{ .shown = "/renew", .bold = "new" },
            .{ .shown = "/clear", .bold = "new", .in_description = true },
            .{ .shown = "/setup", .bold = "new", .in_description = true },
        } },
        // Case is ignored in a description.
        .{ .draft = "/ship", .rows = &.{.{ .shown = "/deploy", .bold = "Ship", .in_description = true }} },
        // A command's name hides a same-named skill, which matched too.
        .{ .draft = "/model", .known = "/model", .rows = &.{.{ .shown = "/model", .bold = "model" }} },
        // Later in a Message, the skill is the only owner of its name.
        .{ .draft = "use /model", .rows = &.{.{ .shown = "/model", .bold = "model" }} },
        .{ .draft = "use /hel", .rows = &.{
            .{ .shown = "/help", .bold = "hel" },
            .{ .shown = "/help-me", .bold = "hel" },
            .{ .shown = "/review-help", .bold = "hel" },
            .{ .shown = "/model", .bold = "hel", .in_description = true },
            .{ .shown = "/triage", .bold = "hel", .in_description = true },
        } },
        // Prefix-only matches are not exact known names.
        .{ .draft = "/hel", .rows = &.{
            .{ .shown = "/help", .bold = "hel" },
            .{ .shown = "/help-me", .bold = "hel" },
            .{ .shown = "/review-help", .bold = "hel" },
            .{ .shown = "/triage", .bold = "hel", .in_description = true },
        } },
        // Nothing holds the name.
        .{ .draft = "/zzz", .rows = &.{} },
        .{ .draft = "use /zzz", .rows = &.{} },
    };
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.answer(reads.ask("").?.read, testPage(&skills), "");
    for (cases) |case| {
        errdefer std.debug.print("draft={s}\n", .{case.draft});
        const shown = reads.shown(&rows, case.draft, case.draft.len, 1, .{}, null) orelse {
            try std.testing.expectEqual(@as(usize, 0), case.rows.len);
            try std.testing.expect(case.known == null);
            continue;
        };
        if (case.known) |known| {
            const span = reads.knownWord(case.draft, shown).?;
            try std.testing.expectEqualStrings(known, case.draft[span.start..][0..span.len]);
            try std.testing.expectEqualStrings(known, shown.list.entries[shown.list.exact.?].shown);
        } else try std.testing.expectEqual(@as(?slash_commands.Span, null), reads.knownWord(case.draft, shown));
        try std.testing.expectEqual(case.rows.len, shown.list.count);
        for (case.rows, shown.list.shown()) |expected, entry| {
            try std.testing.expectEqualStrings(expected.shown, entry.shown);
            const bold = (if (expected.in_description) entry.matches.description else entry.matches.name).?;
            const text = if (expected.in_description) entry.description else entry.shown;
            try std.testing.expectEqualStrings(expected.bold, text[bold.start..][0..bold.len]);
        }
    }
    // Name knowledge does not change when arguments or caret movement make
    // the popup show another word. Inline references are not the first name.
    const Colour = struct { draft: []const u8, known: ?[]const u8 = null };
    for ([_]Colour{
        .{ .draft = "/new notes", .known = "/new" },
        .{ .draft = "/help notes", .known = "/help" },
        .{ .draft = "/unknown notes" },
        .{ .draft = "/hel notes" },
        .{ .draft = "/discard" },
        .{ .draft = "use /help" },
    }) |case| for (0..case.draft.len + 1) |caret| {
        const shown = reads.shown(&rows, case.draft, caret, 1, .{}, null);
        if (case.known) |known| {
            const span = reads.knownWord(case.draft, shown).?;
            try std.testing.expectEqualStrings(known, case.draft[span.start..][0..span.len]);
        } else try std.testing.expectEqual(@as(?slash_commands.Span, null), reads.knownWord(case.draft, shown));
    };
}

test "skills do not replace a command argument or invent an argument list" {
    var reads: Reads = .{};
    var rows: Rows = .{};
    for ([_][]const u8{ "/reload-skills ", "/recover " }) |draft| {
        try std.testing.expect(reads.shown(&rows, draft, draft.len, 5, .{}, null) == null);
    }
}

test "leading skill collisions use the complete grammar including hidden commands" {
    const names = [_][]const u8{ "archive", "clear", "copy", "discard", "effort", "model", "new", "pin", "recover", "reload-skills", "rename", "requests", "result", "setup", "unarchive", "unpin" };
    var entries: [names.len]skill_suggestions.Entry = undefined;
    for (names, &entries) |name, *entry| entry.* = .{ .name = name, .description = "Colliding skill" };
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.answer(reads.ask("").?.read, testPage(&entries), "");
    for (names) |name| {
        try std.testing.expect(slash_commands.conversation.nameOf(name) != null);
        for (0..name.len + 1) |length| {
            var buffer: [80]u8 = undefined;
            const draft = try std.fmt.bufPrint(&buffer, "/{s}", .{name[0..length]});
            const shown = reads.shown(&rows, draft, draft.len, 1, .{}, null);
            // The listed commands whose name or description holds the name.
            var expected: usize = 0;
            for (slash_commands.conversation.listed().shown()) |command| {
                if (std.mem.indexOf(u8, command.shown, name[0..length]) != null or std.mem.indexOf(u8, command.description, name[0..length]) != null) expected += 1;
            }
            try std.testing.expectEqual(expected, if (shown) |found| found.list.count else 0);
            if (shown) |found| for (found.list.shown()) |entry| {
                try std.testing.expect(!std.mem.eql(u8, entry.description, "Colliding skill"));
            };
        }
        var buffer: [80]u8 = undefined;
        const inline_draft = try std.fmt.bufPrint(&buffer, "use /{s}", .{name});
        const inline_rows = reads.shown(&rows, inline_draft, inline_draft.len, 1, .{}, null).?.list;
        try std.testing.expectEqualStrings(name, inline_rows.entries[0].shown[1..]);
        for (inline_rows.shown()) |entry| {
            try std.testing.expectEqualStrings("Colliding skill", entry.description);
            try std.testing.expect(!entry.runs);
        }
    }
    const lookalikes = [_]skill_suggestions.Entry{
        .{ .name = "discarded", .description = "Skill" },
        .{ .name = "recovering", .description = "Skill" },
        .{ .name = "model-extra", .description = "Skill" },
    };
    _ = reads.reset();
    _ = reads.answer(reads.ask("").?.read, testPage(&lookalikes), "");
    for (lookalikes) |skill| {
        try std.testing.expect(slash_commands.conversation.nameOf(skill.name) == null);
        var buffer: [80]u8 = undefined;
        const draft = try std.fmt.bufPrint(&buffer, "/{s}", .{skill.name});
        const shown = reads.shown(&rows, draft, draft.len, 1, .{}, null).?.list;
        try std.testing.expectEqual(@as(usize, 1), shown.count);
        try std.testing.expectEqualStrings("Skill", shown.entries[0].description);
        try std.testing.expect(slash_commands.conversation.parse(draft) == .unknown);
    }
}

test "chat table lists all commands with descriptions plus every loaded skill" {
    try std.testing.expect(!@hasDecl(slash_commands, "overview"));
    const names = [_][]const u8{ "archive", "clear", "copy", "effort", "model", "new", "pin", "reload-skills", "rename", "requests", "result", "setup", "unarchive", "unpin" };
    const descriptions = [_][]const u8{ "archive this chat", "start a new chat", "copy the last answer", "change effort", "change model", "start a new chat", "pin this chat", "reload skills", "rename this chat", "recover a lost request", "show a saved answer", "defaults for new chats", "restore this chat", "unpin this chat" };
    var skill_names: [skill_suggestions.capacity][16]u8 = undefined;
    var entries: [skill_suggestions.capacity]skill_suggestions.Entry = undefined;
    for (&entries, &skill_names, 0..) |*entry, *name, index| entry.* = .{
        .name = try std.fmt.bufPrint(name, "skill-{d:0>2}", .{index}),
        .description = "A loaded skill",
    };
    for (0..entries.len + 1) |count| {
        var reads: Reads = .{};
        var rows: Rows = .{};
        _ = reads.ask("").?;
        _ = reads.answer(1, testPage(entries[0..count]), "");
        const listed = reads.shown(&rows, "/", 1, 1, .{}, null).?.list;
        try std.testing.expectEqual(names.len + count, listed.count);
        for (names, descriptions, listed.shown()[0..names.len]) |name, description, entry| {
            try std.testing.expectEqualStrings(name, entry.shown[1..]);
            try std.testing.expectEqualStrings(description, entry.description);
        }
        for (entries[0..count], listed.shown()[names.len..]) |skill, entry| {
            try std.testing.expectEqualStrings(skill.name, std.mem.trimEnd(u8, entry.word, " "));
            try std.testing.expect(!entry.runs);
        }
    }
    inline for (.{ "/discard", "/recover", "/configurex", "/status", "/configure" }) |name| {
        const list = slash_commands.conversation.suggest(name, .{}).?;
        try std.testing.expectEqual(@as(usize, 0), list.count);
    }
    try std.testing.expect(slash_commands.conversation.parse("/configurex") == .unknown);
    inline for (.{ "/new", "/clear", "/model" }) |name| {
        try std.testing.expect(slash_commands.conversation.parse(name) == .command);
        try std.testing.expect(slash_commands.conversation.parse(name ++ " foo") == .misused);
    }
}

test "a caret moved to another /word is another list, which no key takes until drawn" {
    const entries = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "" }, .{ .name = "review", .description = "" } };
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.ask("re").?;
    _ = reads.answer(1, testPage(&entries), "re");
    const draft = "a /re b /re";
    var first = reads.shown(&rows, draft, "a /re".len, 7, .{}, null).?;
    first.highlight = 1;
    first.drew(true);
    const second = reads.shown(&rows, draft, draft.len, 7, .{}, first).?;
    try std.testing.expectEqual(@as(usize, 0), second.highlight);
    try std.testing.expectEqual(.hidden, second.seen);
    const again = reads.shown(&rows, draft, "a /re".len, 7, .{}, first).?;
    try std.testing.expectEqual(@as(usize, 1), again.highlight);
}

test "Tab or Enter on a row replaces the caret's name, or adds a later word's rest at the end" {
    const entries = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "" }, .{ .name = "review", .description = "" } };
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.ask("re").?;
    _ = reads.answer(1, testPage(&entries), "re");
    const draft = "use /re on it";
    var shown = reads.shown(&rows, draft, "use /r".len, 1, .{}, null).?;
    shown.highlight = 1;
    try expectReplacement(.{ .start = "use /".len, .end = "use /re".len, .text = "review" }, edit(draft, "use /r".len, &shown));
    const command = "/rel";
    const listed = reads.shown(&rows, command, command.len, 2, .{}, null).?;
    try expectReplacement(.{ .start = 1, .end = command.len, .text = "reload-skills" }, edit(command, command.len, &listed));
}

test "every list row matches the word the list was built for, at every caret of every draft" {
    const entries = [_]skill_suggestions.Entry{
        .{ .name = "archx", .description = "Skill" },
        .{ .name = "review", .description = "Skill" },
        .{ .name = "effort", .description = "Colliding skill" },
    };
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.answer(reads.ask("").?.read, testPage(&entries), "");
    const drafts = [_][]const u8{ "/", "/arch", "/arch.foo", "/arch foo", "/archive", "/archive now", "/effort hi", "/effort /re", "/review this", "use /re now", "//arch", "/re/view", "/copy code" };
    for (drafts) |draft| {
        for (0..draft.len + 1) |caret| {
            var shown = reads.shown(&rows, draft, caret, 1, .{ .model = "gpt-5.5" }, null) orelse continue;
            for (0..shown.list.count) |row| {
                shown.highlight = row;
                const entry = shown.list.entries[row];
                if (entry.matches.name) |span| {
                    try std.testing.expect(std.ascii.eqlIgnoreCase(shown.list.typed, entry.shown[span.start..][0..span.len]));
                } else if (entry.matches.description) |span| {
                    try std.testing.expect(std.ascii.eqlIgnoreCase(shown.list.typed, entry.description[span.start..][0..span.len]));
                } else try std.testing.expect(std.mem.startsWith(u8, entry.word, shown.list.typed));
                var buffer: [96]u8 = undefined;
                const after = switch (enter(draft, caret, &shown)) {
                    .run, .edit => |change| try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ draft[0..change.start], change.text, draft[change.end..] }),
                };
                switch (enter(draft, caret, &shown)) {
                    .run => {
                        try std.testing.expect(entry.runs);
                        try std.testing.expectEqual(slash_commands.conversation.Draft.command, slash_commands.conversation.draftOf(after));
                        try std.testing.expect(std.mem.endsWith(u8, after, std.mem.trimEnd(u8, entry.word, " ")));
                    },
                    .edit => try std.testing.expect(std.mem.indexOf(u8, after, std.mem.trimEnd(u8, entry.word, " ")) != null),
                }
            }
        }
    }
}

test "a list stays the drawn one only while its rows are the same, across every caret move and preview" {
    const entries = [_]skill_suggestions.Entry{
        .{ .name = "review", .description = "Skill" },
        .{ .name = "setup-report", .description = "Skill" },
    };
    const Preview = enum { absent, pending, failed, held };
    const drafts = [_][]const u8{ "/setup --permission-mode b", "/setup ", "/copy c", "/effort hi", "/re", "/review this /re", "use /re and /se", "/se /se", "/arch.foo" };
    for (std.enums.values(Preview)) |preview| {
        var reads: Reads = .{};
        var rows: Rows = .{};
        var other: Rows = .{};
        switch (preview) {
            .absent => {},
            .pending => _ = reads.ask("").?,
            .failed => reads.fail(reads.ask("").?.read),
            .held => _ = reads.answer(reads.ask("").?.read, testPage(&entries), ""),
        }
        for (drafts) |draft| {
            for (0..draft.len + 1) |from| {
                var drawn = reads.shown(&rows, draft, from, 1, .{ .model = "gpt-5.5" }, null) orelse continue;
                drawn.drew(true);
                for (0..draft.len + 1) |to| {
                    const next = reads.shown(&other, draft, to, 1, .{ .model = "gpt-5.5" }, drawn) orelse continue;
                    if (next.seen != .drawn) continue;
                    try std.testing.expectEqual(drawn.source, next.source);
                    try std.testing.expectEqualStrings(drawn.list.typed, next.list.typed);
                    try std.testing.expectEqual(drawn.list.count, next.list.count);
                    for (drawn.list.shown(), next.list.shown()) |before, after| {
                        try std.testing.expectEqualStrings(before.word, after.word);
                        try std.testing.expectEqual(before.runs, after.runs);
                    }
                    try std.testing.expectEqualDeep(enter(draft, from, &drawn), enter(draft, to, &next));
                }
            }
        }
    }
}

test "Enter runs a row only where its word ends the draft" {
    const entries = [_]skill_suggestions.Entry{.{ .name = "archx", .description = "Skill" }};
    var reads: Reads = .{};
    var rows: Rows = .{};
    _ = reads.answer(reads.ask("").?.read, testPage(&entries), "");
    var lone = reads.shown(&rows, "/arch", 5, 1, .{}, null).?;
    try expectReplacement(.{ .start = 1, .end = 5, .text = "archive" }, enter("/arch", 5, &lone).run);
    lone.highlight = 1;
    try expectReplacement(.{ .start = 1, .end = 5, .text = "archx " }, enter("/arch", 5, &lone).edit);
    lone.highlight = 2;
    try expectReplacement(.{ .start = 1, .end = 5, .text = "unarchive" }, enter("/arch", 5, &lone).run);
    for ([_][]const u8{ "/arch this change", "/arch.foo" }) |draft| {
        var shown = reads.shown(&rows, draft, 5, 1, .{}, null).?;
        try std.testing.expectEqual(@as(usize, 3), shown.list.count);
        try expectReplacement(.{ .start = 1, .end = 5, .text = "archive" }, enter(draft, 5, &shown).edit);
        shown.highlight = 1;
        try expectReplacement(.{ .start = 1, .end = 5, .text = "archx" }, enter(draft, 5, &shown).edit);
    }
    const copy = reads.shown(&rows, "/copy c", 7, 1, .{}, null).?;
    try expectReplacement(.{ .start = 7, .end = 7, .text = "ode" }, enter("/copy c", 7, &copy).run);
}

fn testPage(entries: []const skill_suggestions.Entry) skill_suggestions.Page {
    return .{ .entries = entries, .total = entries.len };
}

test "skill ranking is identical for fresh and reused complete or truncated previews" {
    const Entry = skill_suggestions.Entry;
    // A Host page for re: prefixes first, then name substrings, then descriptions.
    const prior = [_]Entry{
        .{ .name = "re-review", .description = "Prefix becomes a name substring" },
        .{ .name = "recap", .description = "Review captured notes" },
        .{ .name = "rev", .description = "Prefix becomes exact" },
        .{ .name = "reverie", .description = "Prefix stays prefix" },
        .{ .name = "a-review", .description = "First lexical substring" },
        .{ .name = "b-review", .description = "Second lexical substring" },
        .{ .name = "z-task", .description = "Review issues" },
    };
    // Independently authored fresh Host order for rev, not sorted by the test.
    const narrowed = [_]Entry{ prior[2], prior[3], prior[4], prior[5], prior[0], prior[1], prior[6] };
    const old_names = [_][]const u8{ "re-review", "recap", "rev", "reverie", "a-review", "b-review", "z-task" };
    const new_names = [_][]const u8{ "rev", "reverie", "a-review", "b-review", "re-review", "recap", "z-task" };
    const Check = struct {
        fn lists(names: []const []const u8, catalog: []const Entry, draft: []const u8, fresh: slash_commands.Shown, cached: slash_commands.Shown) !void {
            try std.testing.expectEqual(names.len, fresh.list.count);
            try std.testing.expectEqual(names.len, cached.list.count);
            try std.testing.expectEqual(fresh.list.exact, cached.list.exact);
            try std.testing.expectEqualDeep(fresh.list.source_word, cached.list.source_word);
            for (names, fresh.list.shown(), cached.list.shown(), 0..) |name, direct, reused, index| {
                try std.testing.expectEqualStrings(name, direct.shown[1..]);
                try std.testing.expectEqualStrings(name, reused.shown[1..]);
                try std.testing.expectEqualStrings(name, std.mem.trimEnd(u8, reused.word, " "));
                try std.testing.expectEqualStrings(direct.word, reused.word);
                const description = for (catalog) |entry| {
                    if (std.mem.eql(u8, name, entry.name)) break entry.description;
                } else return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings(description, reused.description);
                try std.testing.expectEqualStrings(direct.description, reused.description);
                try std.testing.expectEqualDeep(direct.matches, reused.matches);
                try std.testing.expectEqual(direct.runs, reused.runs);
                var fresh_pick = fresh;
                var cached_pick = cached;
                fresh_pick.highlight = index;
                cached_pick.highlight = index;
                // Tab, Enter and clicks use this owner: every same row makes
                // the same replacement, regardless of which page arrived.
                try expectReplacement(enter(draft, draft.len, &fresh_pick).edit, enter(draft, draft.len, &cached_pick).edit);
            }
        }
    };
    const Case = struct { from: []const u8, query: []const u8, page: []const Entry, names: []const []const u8 };
    const cases = [_]Case{
        .{ .from = "re", .query = "re", .page = &prior, .names = &old_names }, // unchanged query
        .{ .from = "r", .query = "re", .page = &prior, .names = &old_names }, // unchanged ranks
        .{ .from = "re", .query = "rev", .page = &narrowed, .names = &new_names }, // changed and collapsed ranks
    };
    for (cases) |case| for ([_]bool{ true, false }) |complete_page| {
        // Pure ranking ignores every incoming page rotation and reversal.
        for (0..prior.len) |rotation| for ([_]bool{ false, true }) |reverse| {
            errdefer std.debug.print("from={s} query={s} complete={} rotation={} reverse={}\n", .{ case.from, case.query, complete_page, rotation, reverse });
            var incoming: [prior.len]Entry = undefined;
            for (&incoming, 0..) |*entry, index| {
                const source = (rotation + index) % prior.len;
                entry.* = prior[if (reverse) prior.len - 1 - source else source];
            }
            var cached: Reads = .{};
            var cached_rows: Rows = .{};
            const read = cached.ask(case.from).?.read;
            _ = cached.answer(read, .{ .entries = &incoming, .total = incoming.len + @intFromBool(!complete_page) }, case.from);
            const next = cached.ask(case.query);
            const needs_read = !complete_page and !std.mem.eql(u8, case.from, case.query);
            try std.testing.expectEqual(needs_read, next != null);
            var fresh: Reads = .{};
            var fresh_rows: Rows = .{};
            _ = fresh.answer(fresh.ask(case.query).?.read, testPage(case.page), case.query);
            var text: [80]u8 = undefined;
            const draft = try std.fmt.bufPrint(&text, "use /{s}", .{case.query});
            const direct = fresh.shown(&fresh_rows, draft, draft.len, 1, .{}, null).?;
            // For truncated previews this comparison is over the SAME available
            // entries, not the full catalog that the outstanding read may add.
            const reused = cached.shown(&cached_rows, draft, draft.len, 1, .{}, null).?;
            try Check.lists(case.names, &prior, draft, direct, reused);
            if (next) |pending| {
                try std.testing.expect(cached.answer(pending.read, testPage(case.page), case.query) != null);
                const replaced = cached.shown(&cached_rows, draft, draft.len, 1, .{}, null).?;
                try Check.lists(case.names, &prior, draft, direct, replaced);
                try std.testing.expect(cached.ask(case.query) == null);
            }
        };
    };
    // A truncated old page can omit a better new match. Keep its available
    // rows ordered while reading; once replaced, match the full fresh page.
    const short = [_]Entry{ prior[0], prior[4] };
    const full = [_]Entry{ prior[2], prior[4], prior[0] };
    var cached: Reads = .{};
    var cached_rows: Rows = .{};
    _ = cached.answer(cached.ask("re").?.read, .{ .entries = &short, .total = 3 }, "re");
    try std.testing.expect(cached.ask("re") == null);
    const next = cached.ask("rev").?;
    const draft = "use /rev";
    const waiting = cached.shown(&cached_rows, draft, draft.len, 1, .{}, null).?;
    try std.testing.expectEqual(@as(usize, 2), waiting.list.count);
    try std.testing.expectEqualStrings("/a-review", waiting.list.entries[0].shown);
    try std.testing.expectEqualStrings("/re-review", waiting.list.entries[1].shown);
    _ = cached.answer(next.read, testPage(&full), "rev");
    var fresh: Reads = .{};
    var fresh_rows: Rows = .{};
    _ = fresh.answer(fresh.ask("rev").?.read, testPage(&full), "rev");
    try Check.lists(&.{ "rev", "a-review", "re-review" }, &prior, draft, fresh.shown(&fresh_rows, draft, draft.len, 1, .{}, null).?, cached.shown(&cached_rows, draft, draft.len, 1, .{}, null).?);
}

test "skill reads ask once per name, one at a time, and not while the held page answers" {
    const entries = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "Summarise" }, .{ .name = "review", .description = "Review a change" } };
    var reads: Reads = .{};
    const first = reads.ask("re").?;
    try std.testing.expectEqual(@as(u64, 1), first.read);
    try std.testing.expectEqualStrings("re", first.prefix);
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("rev"));
    try std.testing.expectEqual(@as(?skill_suggestions.Page, null), reads.answer(1, testPage(&entries), "rev"));
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("rev"));
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("re"));
    try std.testing.expectEqual(@as(u64, 2), reads.ask("r").?.read);
    const replaced = reads.answer(2, .{ .entries = entries[0..1], .total = 30 }, "r").?;
    try std.testing.expectEqual(@as(usize, 2), replaced.entries.len);
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("r"));
    try std.testing.expectEqual(@as(u64, 3), reads.ask("rev").?.read);
    var fresh: Reads = .{};
    try std.testing.expectEqual(@as(?Ask, null), fresh.ask(&@as([max_prefix_bytes + 1]u8, @splat('a'))));
    try std.testing.expect(fresh.ask(&@as([max_prefix_bytes]u8, @splat('a'))) != null);
}

test "skill reads drop an answer the word moved past, or one a reset left behind" {
    const entries = [_]skill_suggestions.Entry{.{ .name = "review", .description = "" }};
    var reads: Reads = .{};
    _ = reads.ask("re").?;
    const moved = reads.answer(1, testPage(&entries), "x").?;
    try std.testing.expectEqual(@as(usize, 1), moved.entries.len);
    try std.testing.expectEqual(@as(?Reads.Held, null), reads.held);
    try std.testing.expectEqual(@as(u64, 2), reads.ask("x").?.read);
    try std.testing.expect(reads.answer(2, testPage(&entries), null) != null);
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
    reads.fail(1);
    try std.testing.expectEqual(@as(?Ask, null), reads.ask("rev"));
}

test "skill rows are the held page's, numbered by the read that made them" {
    const entries = [_]skill_suggestions.Entry{ .{ .name = "recap", .description = "Summarise" }, .{ .name = "review", .description = "Review a change" } };
    var reads: Reads = .{};
    var rows: Rows = .{};
    const draft = "use /re";
    try std.testing.expectEqual(@as(?slash_commands.Shown, null), reads.shown(&rows, draft, draft.len, 1, .{}, null));
    _ = reads.ask("re").?;
    _ = reads.answer(1, testPage(&entries), "re");
    const shown = reads.shown(&rows, draft, draft.len, 1, .{}, null).?;
    try std.testing.expectEqual(@as(usize, 2), shown.list.count);
    try std.testing.expect(shown.source != 0);
    try std.testing.expectEqual(.hidden, shown.seen);
    try std.testing.expectEqualStrings("/review", shown.list.entries[1].shown);
    try std.testing.expectEqual(@as(?slash_commands.Shown, null), reads.shown(&rows, "use it", 3, 2, .{}, null));
    const start = reads.shown(&rows, "/rel", 4, 3, .{}, null).?;
    try std.testing.expectEqual(@as(usize, 1), start.list.count);
    try std.testing.expectEqualStrings("/reload-skills", start.list.entries[0].shown);
    try std.testing.expect(start.source != 0);
}

test "a transport-interrupted skills read is retryable without discarding the held page" {
    for ([_]bool{ false, true }) |stale| {
        var reads: Reads = .{};
        const old = reads.ask("old").?;
        try std.testing.expect(reads.answer(old.read, .{}, "old") == null);
        const pending = reads.ask("re").?;
        reads.retry(if (stale) old.read else pending.read);
        try std.testing.expectEqual(stale, reads.pending != null);
        try std.testing.expectEqual(old.read, reads.held.?.read);
        try std.testing.expect(reads.failed == null);
        if (stale) reads.retry(pending.read);
        const next = reads.ask("re").?;
        try std.testing.expect(next.read > pending.read);
        reads.fail(next.read);
        try std.testing.expect(reads.ask("re") == null);
    }
}

test "grammar choice picks expire when the model changes without a draft edit" {
    var reads: Reads = .{};
    var rows: Rows = .{};
    const draft = "/effort ";
    for ([_][]const u8{ "unlisted-model", "gpt-5.5", "gpt-4o" }) |before| {
        for ([_][]const u8{ "unlisted-model", "gpt-5.5", "gpt-4o" }) |after| {
            var drawn = reads.shown(&rows, draft, draft.len, 1, .{ .model = before }, null).?;
            drawn.drew(true);
            const pick = drawn.pick(drawn.list.count - 1);
            var stored: ?slash_commands.Shown = drawn;
            const next = reads.shown(&rows, draft, draft.len, 1, .{ .model = after }, drawn);
            if (std.mem.eql(u8, before, after)) {
                try std.testing.expect(slash_commands.Shown.pickedNow(&stored, next, pick) != null);
            } else {
                try std.testing.expect(slash_commands.Shown.pickedNow(&stored, next, pick) == null);
                stored = next;
                stored.?.drew(true);
                const current = stored.?.pick(0);
                try std.testing.expect(slash_commands.Shown.pickedNow(&stored, stored, current) != null);
            }
        }
    }
}
