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
    const word = atCaret(draft, caret) orelse return null;
    if (word.slash != 0 and slash_commands.conversation.draftOf(draft) == .command) return null;
    return word;
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
        const skills = rows.list(typed, page);
        if (word.slash != 0) return slash_commands.Shown.nextOf(previous, revision, source, skills);
        var listed = slash_commands.conversation.starting(typed);
        if (skills) |found| for (found.shown()) |entry| {
            if (slash_commands.conversation.nameOf(std.mem.trimEnd(u8, entry.word, " ")) != null) continue;
            if (listed.count == slash_commands.List.capacity) break;
            listed.entries[listed.count] = entry;
            listed.count += 1;
        };
        return slash_commands.Shown.nextOf(previous, revision, source, listed);
    }
};

pub const Rows = struct {
    text: [slash_commands.List.capacity][1 + 64 + 1]u8 = undefined,

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
    run: []const u8,
    edit: Replacement,
};

pub fn enter(draft: []const u8, caret: usize, shown: *const slash_commands.Shown) Taken {
    const taken = shown.list.enter(shown.highlight);
    const ends = if (skillWordAt(draft, caret)) |word| word.end == draft.len else true;
    if (taken.runs and ends) return .{ .run = taken.rest };
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
            var expected: usize = 0;
            for (names) |command| {
                if (std.mem.eql(u8, command, "discard") or std.mem.eql(u8, command, "recover")) continue;
                if (std.mem.startsWith(u8, command, name[0..length])) expected += 1;
            }
            try std.testing.expectEqual(expected, if (shown) |found| found.list.count else 0);
            if (shown) |found| for (found.list.shown()) |entry| {
                try std.testing.expect(!std.mem.eql(u8, entry.description, "Colliding skill"));
            };
        }
        var buffer: [80]u8 = undefined;
        const inline_draft = try std.fmt.bufPrint(&buffer, "use /{s}", .{name});
        const inline_rows = reads.shown(&rows, inline_draft, inline_draft.len, 1, .{}, null).?.list;
        try std.testing.expectEqual(@as(usize, 1), inline_rows.count);
        try std.testing.expectEqualStrings("Colliding skill", inline_rows.entries[0].description);
        try std.testing.expect(!inline_rows.entries[0].runs);
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

test "every list row starts the word the list was built for, at every caret of every draft" {
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
                try std.testing.expect(std.mem.startsWith(u8, entry.word, shown.list.typed));
                var buffer: [96]u8 = undefined;
                const after = switch (enter(draft, caret, &shown)) {
                    .run => |rest| try std.fmt.bufPrint(&buffer, "{s}{s}", .{ draft, rest }),
                    .edit => |change| try std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ draft[0..change.start], change.text, draft[change.end..] }),
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
    try std.testing.expectEqualStrings("ive", enter("/arch", 5, &lone).run);
    lone.highlight = 1;
    try expectReplacement(.{ .start = 1, .end = 5, .text = "archx " }, enter("/arch", 5, &lone).edit);
    for ([_][]const u8{ "/arch this change", "/arch.foo" }) |draft| {
        var shown = reads.shown(&rows, draft, 5, 1, .{}, null).?;
        try std.testing.expectEqual(@as(usize, 2), shown.list.count);
        try expectReplacement(.{ .start = 1, .end = 5, .text = "archive" }, enter(draft, 5, &shown).edit);
        shown.highlight = 1;
        try expectReplacement(.{ .start = 1, .end = 5, .text = "archx" }, enter(draft, 5, &shown).edit);
    }
    const copy = reads.shown(&rows, "/copy c", 7, 1, .{}, null).?;
    try std.testing.expectEqualStrings("ode", enter("/copy c", 7, &copy).run);
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
    const commands = slash_commands.conversation.suggest("/rel", .{}).?;
    const start = reads.shown(&rows, "/rel", 4, 3, .{}, null).?;
    try std.testing.expectEqual(commands.count, start.list.count);
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
