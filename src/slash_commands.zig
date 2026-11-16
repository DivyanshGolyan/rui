const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const cli_args = @import("cli_args.zig");
const skill_suggestions = @import("skill_suggestions.zig");
const model_capability = @import("model_capability.zig");
const TerminalText = @import("TerminalText.zig");
const ReasoningEffort = model_capability.ReasoningEffort;

pub const Argument = union(enum) {
    none,
    optional: []const u8,
    required: []const u8,
    choice: []const Choice,
    effort,
    options: Options,
};

fn requires(argument: Argument) bool {
    return switch (argument) {
        .required, .effort => true,
        .options => |options| !options.alone,
        .none, .optional, .choice => false,
    };
}

pub const Choice = struct { word: []const u8 };

pub const Options = struct {
    grammar: cli_args.Definition,
    entries: []const Entry,
    alone: bool,
    fn of(comptime grammar: cli_args.Definition, comptime names: []const []const u8, comptime alone: bool) Options {
        var entries: [names.len]Entry = undefined;
        for (&entries, names) |*entry, option| {
            const argument = grammar.argumentOf(option) orelse @compileError("no option --" ++ option);
            entry.* = .{ .word = "--" ++ option ++ " ", .shown = "--" ++ option, .runs = argument == null };
        }
        const final = entries;
        return .{ .grammar = grammar, .entries = &final, .alone = alone };
    }
};

pub const Context = struct {
    model: ?[]const u8 = null,
    effort: ?ReasoningEffort = null,
};

pub const Copy = enum { answer, code, file };

pub const Command = struct {
    description: []const u8 = "",
    argument: Argument = .none,
    listed: bool = true,
};

const copy_words = &[_]Choice{
    .{ .word = "code" },
    .{ .word = "file" },
};

comptime {
    for (@typeInfo(Copy).@"enum".field_names[1..], copy_words) |field, choice| std.debug.assert(std.mem.eql(u8, field, choice.word));
}

const setup_options: Options = .of(cli_args.live_setup, &.{ "model", "provider", "reasoning-effort", "notifications", "clear-model", "store" }, true);

const ConversationName = enum {
    archive,
    autogroup,
    clear,
    copy,
    discard,
    effort,
    group,
    @"group-rename",
    model,
    new,
    pin,
    recover,
    @"reload-skills",
    rename,
    requests,
    result,
    setup,
    unarchive,
    ungroup,
    unpin,
};

pub const conversation = Commands(ConversationName, .{
    .archive = .{ .description = "archive this chat" },
    .autogroup = .{ .description = "restore automatic grouping" },
    .clear = .{ .description = "start a new chat" },
    .copy = .{ .description = "copy the last answer", .argument = .{ .choice = copy_words } },
    .discard = .{ .listed = false },
    .effort = .{ .description = "change effort", .argument = .effort },
    .group = .{ .description = "move this chat to a named group", .argument = .{ .required = "NAME" } },
    .@"group-rename" = .{ .description = "rename this chat’s group", .argument = .{ .required = "NAME" } },
    .model = .{ .description = "change model" },
    .new = .{ .description = "start a new chat" },
    .pin = .{ .description = "pin this chat" },
    .recover = .{ .argument = .{ .required = "KEY" }, .listed = false },
    .@"reload-skills" = .{ .description = "reload skills" },
    .rename = .{ .description = "rename this chat", .argument = .{ .required = "NAME" } },
    .requests = .{ .description = "recover a lost request" },
    .result = .{ .description = "show a saved answer", .argument = .{ .required = "KEY" } },
    .setup = .{ .description = "defaults for new chats", .argument = .{ .options = setup_options } },
    .unarchive = .{ .description = "restore this chat" },
    .ungroup = .{ .description = "leave this group and pause automatic grouping" },
    .unpin = .{ .description = "unpin this chat" },
});

fn slashed(text: []const u8) bool {
    return text.len != 0 and text[0] == '/' and !std.mem.startsWith(u8, text, "//");
}

pub fn unknown(buffer: *[unknown_bytes]u8, text: []const u8) []const u8 {
    const name = text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
    var shown = name.len <= max_unknown_name;
    for (name) |byte| shown = shown and byte > ' ' and byte < 0x7f;
    return std.fmt.bufPrint(buffer, "! Unknown command{s}{s}", .{ if (shown) " " else "", if (shown) name else "" }) catch unreachable;
}

const max_unknown_name = 32;
pub const unknown_bytes = "! Unknown command ".len + max_unknown_name;

pub const short_result_bytes = 256;
pub const short_result_lines = 2;
pub const result_notice_bytes = short_result_bytes + short_result_lines * "! ".len;

pub fn resultNotice(buffer: *[result_notice_bytes]u8, output: []const u8) ?[]const u8 {
    if (output.len > short_result_bytes) return null;
    const text = std.mem.trimEnd(u8, output, "\n");
    if (text.len == 0) return no_output;
    if (std.mem.count(u8, text, "\n") >= short_result_lines) return null;
    var writer = std.Io.Writer.fixed(buffer);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (writer.buffered().len != 0) writer.writeByte('\n') catch unreachable;
        if (std.mem.startsWith(u8, line, "Rui: ")) {
            writer.writeAll(line[5..]) catch unreachable;
        } else if (std.mem.startsWith(u8, line, "rui: ")) {
            writer.print("! {s}", .{line[5..]}) catch unreachable;
        } else writer.writeAll(line) catch unreachable;
    }
    return writer.buffered();
}

pub const no_output = "Command finished with no output.";

pub fn named(total: usize, rows: usize) usize {
    return if (total <= rows) total else if (rows >= 2) rows - 1 else rows;
}

pub const more = "+{d} more · type to narrow";

pub fn Commands(comptime N: type, comptime commands: std.enums.EnumFieldStruct(N, Command, null)) type {
    return struct {
        pub const Name = N;
        pub const table = std.enums.EnumArray(Name, Command).init(commands);

        pub const usage = blk: {
            var texts: std.enums.EnumArray(Name, []const u8) = undefined;
            for (std.enums.values(Name)) |name| {
                const text = "/" ++ @tagName(name);
                texts.set(name, switch (table.get(name).argument) {
                    .none => text,
                    .optional => |word| text ++ " [" ++ word ++ "]",
                    .required => |word| text ++ " " ++ word,
                    .choice => |choices| choice: {
                        var joined: []const u8 = text ++ " [";
                        for (choices, 0..) |choice, index| joined = joined ++ (if (index == 0) "" else "|") ++ choice.word;
                        break :choice joined ++ "]";
                    },
                    .effort => text ++ " LEVEL",
                    .options => text ++ " [OPTIONS]",
                });
            }
            break :blk texts;
        };

        const listed_count = blk: {
            var count = 0;
            for (std.enums.values(Name)) |name| if (table.get(name).listed) {
                count += 1;
            };
            break :blk count;
        };

        pub const description_column = blk: {
            var widest = 0;
            for (std.enums.values(Name)) |name| if (table.get(name).listed) {
                widest = @max(widest, 1 + @tagName(name).len);
            };
            break :blk widest + 2;
        };

        const choices_text = blk: {
            var texts: std.enums.EnumArray(Name, []const u8) = undefined;
            for (std.enums.values(Name)) |name| {
                var text: []const u8 = "";
                if (table.get(name).argument == .choice) {
                    for (table.get(name).argument.choice, 0..) |choice, index| text = text ++ (if (index == 0) "" else " · ") ++ choice.word;
                }
                texts.set(name, text);
            }
            break :blk texts;
        };

        pub const Parsed = union(enum) {
            unknown,
            misused: Name,
            command: struct { name: Name, argument: []const u8 },
        };

        pub fn nameOf(word: []const u8) ?Name {
            return std.meta.stringToEnum(Name, word);
        }

        pub const Draft = enum {
            message,
            word,
            command,
        };

        pub fn draftOf(text: []const u8) Draft {
            if (!slashed(text)) return .message;
            const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
            if (nameOf(text[1..end]) != null) return .command;
            return if (std.mem.indexOfAny(u8, text, " \t\n") == null) .word else .message;
        }

        pub fn listed() List {
            var list: List = .{ .typed = "", .column = description_column };
            for (names) |name| {
                const command = table.get(name);
                if (!command.listed) continue;
                list.add(.{ .word = spaced.get(name)[1 .. spaced.get(name).len - @intFromBool(command.argument == .none)], .shown = spaced.get(name)[0 .. spaced.get(name).len - 1], .description = if (command.description.len != 0) command.description else choices_text.get(name), .runs = !requires(command.argument) });
            }
            return list;
        }

        pub fn parse(text: []const u8) Parsed {
            std.debug.assert(text.len != 0 and text[0] == '/');
            const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
            const name = nameOf(text[1..end]) orelse return .unknown;
            const argument = trimmed(text[end..]);
            const admitted = switch (table.get(name).argument) {
                .none => argument.len == 0,
                .optional => true,
                .required, .effort => argument.len != 0,
                .choice => |choices| argument.len == 0 or for (choices) |choice| {
                    if (std.mem.eql(u8, choice.word, argument)) break true;
                } else false,
                .options => true,
            };
            return if (admitted) .{ .command = .{ .name = name, .argument = argument } } else .{ .misused = name };
        }

        fn trimmed(raw: []const u8) []const u8 {
            const argument = std.mem.trimStart(u8, raw, " ");
            var len = std.mem.trimEnd(u8, argument, " ").len;
            var slashes: usize = 0;
            while (slashes < len and argument[len - 1 - slashes] == '\\') slashes += 1;
            if (slashes % 2 == 1 and len < argument.len) len += 1;
            return argument[0..len];
        }

        pub fn suggest(draft: []const u8, context: Context) ?List {
            if (!slashed(draft) or std.mem.indexOfAny(u8, draft, "\t\n") != null) return null;
            const end = std.mem.indexOfScalar(u8, draft, ' ') orelse return .{ .typed = draft[1..] };
            var list: List = .{ .typed = undefined };
            const name = nameOf(draft[1..end]) orelse return null;
            const words = draft[end + 1 ..];
            if (std.mem.indexOfAny(u8, words, "\"'\\") != null) return null;
            const start = if (std.mem.lastIndexOfScalar(u8, words, ' ')) |space| space + 1 else 0;
            list.typed = words[start..];
            const before = std.mem.trimEnd(u8, words[0..start], " ");
            switch (table.get(name).argument) {
                .none, .optional, .required => return null,
                .choice => |choices| {
                    if (before.len != 0) return null;
                    for (choices) |choice| list.offer(choice.word, choice.word);
                },
                .effort => {
                    if (before.len != 0) return null;
                    list.offerEfforts(context);
                },
                .options => |options| {
                    const previous = before[if (std.mem.lastIndexOfScalar(u8, before, ' ')) |space| space + 1 else 0..];
                    if (std.mem.startsWith(u8, previous, "--")) if (options.grammar.argumentOf(previous[2..])) |argument| if (argument) |shape| {
                        list.offerValues(shape);
                        return list;
                    };
                    for (options.entries) |entry| if (std.mem.startsWith(u8, entry.word, list.typed)) list.add(entry);
                },
            }
            return list;
        }

        const names = std.enums.values(Name);

        const spaced = blk: {
            var texts: std.enums.EnumArray(Name, []const u8) = undefined;
            for (names) |name| texts.set(name, "/" ++ @tagName(name) ++ " ");
            break :blk texts;
        };
    };
}

pub const Entry = struct {
    word: []const u8,
    shown: []const u8,
    description: []const u8 = "",
    runs: bool = true,
    /// The part of the row the typed word matched, which the list draws
    /// bold; `skill_completion` sets it.
    matches: MatchSpans = .{},
};

pub const Span = struct { start: usize, len: usize };
pub const MatchSpans = struct { name: ?Span = null, description: ?Span = null };

pub const List = struct {
    typed: []const u8,
    entries: [capacity]Entry = undefined,
    count: usize = 0,
    exact: ?usize = null,
    source_word: ?Span = null,

    column: ?usize = null,

    pub const capacity = conversation.listed_count + skill_suggestions.capacity;

    /// A typed name is known only when this list contains its exact row.
    pub fn exactWord(self: *const List) ?Span {
        _ = self.exact orelse return null;
        return self.source_word;
    }

    fn add(self: *List, entry: Entry) void {
        std.debug.assert(std.mem.startsWith(u8, entry.word, self.typed));
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn offer(self: *List, word: []const u8, text: []const u8) void {
        if (std.mem.startsWith(u8, word, self.typed)) self.add(.{ .word = word, .shown = text });
    }

    fn offerEfforts(self: *List, context: Context) void {
        const model = context.model orelse return;
        for (std.enums.values(ReasoningEffort)) |effort| if (model_capability.supportsReasoningEffort(model_catalog.shipped, model, effort)) {
            self.offer(@tagName(effort), @tagName(effort));
        };
        self.offer("default", "default");
    }

    fn offerValues(self: *List, shape: []const u8) void {
        var values = std.mem.splitScalar(u8, shape, '|');
        while (values.next()) |value| {
            const fixed = value.len != 0 and for (value) |byte| {
                if (!std.ascii.isLower(byte) and byte != '_' and byte != ',') break false;
            } else true;
            if (fixed) self.offer(value, value);
        }
    }

    pub fn shown(self: *const List) []const Entry {
        return self.entries[0..self.count];
    }

    pub fn completion(self: *const List, highlight: usize) []const u8 {
        std.debug.assert(std.mem.startsWith(u8, self.entries[highlight].word, self.typed));
        return self.entries[highlight].word[self.typed.len..];
    }

    pub fn enter(self: *const List, highlight: usize) struct { rest: []const u8, runs: bool } {
        const entry = self.entries[highlight];
        if (!entry.runs) return .{ .rest = self.completion(highlight), .runs = false };
        return .{ .rest = std.mem.trimEnd(u8, entry.word, " ")[self.typed.len..], .runs = true };
    }

    pub fn firstShown(self: *const List, highlight: usize, rows: usize) usize {
        const fit = named(self.count, rows);
        return @min((highlight + 1) -| fit, self.count - fit);
    }

    pub fn descriptionColumn(self: *const List) usize {
        if (self.column) |column| return column;
        var widest: usize = 0;
        for (self.shown()) |entry| widest = @max(widest, entry.shown.len);
        return widest + 2;
    }
};

pub const Shown = struct {
    list: List,
    revision: u64,
    highlight: usize = 0,
    seen: enum { drawn, hidden, closed } = .hidden,
    source: u64 = 0,

    pub fn next(previous: ?Shown, revision: u64, list: ?List) ?Shown {
        return nextOf(previous, revision, 0, list);
    }

    pub fn nextOf(previous: ?Shown, revision: u64, source: u64, list: ?List) ?Shown {
        const built = list orelse return null;
        if (built.count == 0) return null;
        const fresh: Shown = .{ .list = built, .revision = revision, .source = source };
        const kept = previous orelse return fresh;
        if (kept.source != source) return fresh;
        if (kept.revision != revision) return .{ .list = built, .revision = revision, .source = source, .seen = if (kept.seen == .drawn) .drawn else .hidden };
        return .{ .list = built, .revision = revision, .source = source, .highlight = @min(kept.highlight, built.count - 1), .seen = kept.seen };
    }

    pub fn drawnNow(stored: *?Shown, current: ?Shown) ?*Shown {
        stored.* = current orelse return null;
        const kept = &stored.*.?;
        return if (kept.seen == .drawn) kept else null;
    }

    pub const Pick = struct { index: usize, revision: u64, source: u64 };

    pub fn pick(self: *const Shown, index: usize) Pick {
        return .{ .index = index, .revision = self.revision, .source = self.source };
    }

    pub fn pickedNow(stored: *?Shown, current: ?Shown, pressed: Pick) ?*Shown {
        const now = current orelse return null;
        if (now.revision != pressed.revision or now.source != pressed.source) return null;
        const shown = drawnNow(stored, now) orelse return null;
        if (pressed.index >= shown.list.count) return null;
        shown.highlight = pressed.index;
        return shown;
    }

    pub fn rows(self: *const Shown) usize {
        return if (self.seen == .closed) 0 else self.list.count;
    }

    pub fn drew(self: *Shown, drawn: bool) void {
        if (self.seen != .closed) self.seen = if (drawn) .drawn else .hidden;
    }

    pub fn close(self: *Shown) void {
        self.seen = .closed;
    }

    pub fn completion(self: *const Shown) []const u8 {
        return self.list.completion(self.highlight);
    }

    pub fn move(self: *Shown, down: bool) void {
        self.highlight = if (down) @min(self.highlight + 1, self.list.count - 1) else self.highlight -| 1;
    }
};

const recover_command = "/" ++ @tagName(ConversationName.recover);
pub const recover_line_bytes = recover_command.len + " ".len + 36;

pub fn recoverEntry(buffer: *[recover_line_bytes]u8, key: *const [36]u8) Entry {
    const line = std.fmt.bufPrint(buffer, recover_command ++ " {s}", .{key}) catch unreachable;
    return .{ .word = line, .shown = line, .description = "retry this unconfirmed original, as Ctrl-R does" };
}

pub fn Requests(comptime max_key_bytes: usize) type {
    return struct {
        rows: [capacity]Row = undefined,
        count: usize = 0,

        const Self = @This();
        pub const capacity = List.capacity - 1;
        const result_command = "/" ++ @tagName(ConversationName.result);
        const line_bytes = result_command.len + " ".len + max_key_bytes;
        const description = "read this Message's saved answer";
        const description_bytes = "00:00 · ".len + description.len;

        const Row = struct {
            line: [line_bytes]u8,
            line_length: usize,
            description: [description_bytes]u8,
            description_length: usize,
            saved: std.Io.Timestamp,

            fn key(self: *const Row) []const u8 {
                return self.line[result_command.len + 1 .. self.line_length];
            }
        };

        pub fn offer(self: *Self, saved: std.Io.Timestamp, clock: ?[]const u8, key: []const u8) void {
            if (key.len > max_key_bytes) return;
            var row: Row = .{ .line = undefined, .line_length = 0, .description = undefined, .description_length = 0, .saved = saved };
            row.line_length = (std.fmt.bufPrint(&row.line, result_command ++ " {s}", .{key}) catch unreachable).len;
            if (!admits(row.line[0..row.line_length], key)) return;
            const said = if (clock) |time| std.fmt.bufPrint(&row.description, "{s} · " ++ description, .{time}) else std.fmt.bufPrint(&row.description, description, .{});
            row.description_length = (said catch unreachable).len;
            var at = self.count;
            while (at > 0 and newer(&row, &self.rows[at - 1])) at -= 1;
            if (at == capacity) return;
            const kept = @min(self.count, capacity - 1);
            std.mem.copyBackwards(Row, self.rows[at + 1 .. kept + 1], self.rows[at..kept]);
            self.rows[at] = row;
            self.count = kept + 1;
        }

        fn admits(line: []const u8, key: []const u8) bool {
            const parsed = conversation.parse(line);
            if (parsed != .command or !std.mem.eql(u8, parsed.command.argument, key)) return false;
            if (std.mem.indexOfScalar(u8, key, ' ') != null) return false;
            var at: usize = 0;
            while (at < key.len) {
                const length = std.unicode.utf8ByteSequenceLength(key[at]) catch return false;
                if (length > key.len - at) return false;
                const scalar = std.unicode.utf8Decode(key[at..][0..length]) catch return false;
                if (TerminalText.isControl(scalar)) return false;
                at += length;
            }
            return true;
        }

        fn newer(row: *const Row, than: *const Row) bool {
            if (row.saved.nanoseconds != than.saved.nanoseconds) return row.saved.nanoseconds > than.saved.nanoseconds;
            return std.mem.order(u8, row.key(), than.key()) == .lt;
        }

        pub fn list(self: *const Self, lead: ?Entry) ?List {
            var shown: List = .{ .typed = "" };
            const original = if (lead) |entry| entry.word[recover_command.len + 1 ..] else "";
            if (lead) |entry| shown.add(entry);
            for (self.rows[0..self.count]) |*row| {
                if (std.mem.eql(u8, row.key(), original)) continue;
                shown.add(.{ .word = row.line[0..row.line_length], .shown = row.line[0..row.line_length], .description = row.description[0..row.description_length] });
            }
            return if (shown.count == 0) null else shown;
        }
    };
}

test "a /requests list keeps the newest saved Messages, after the original's /recover row" {
    const Saved = Requests(128);
    const key = "01234567-89ab-4cde-8012-0123456789ab";
    var requests: Saved = .{};
    const total = Saved.capacity + 5;
    comptime std.debug.assert(std.math.gcd(11, total) == 1);
    var keys: [total][36]u8 = undefined;
    for (0..total) |index| {
        const order = (index * 11) % total;
        _ = std.fmt.bufPrint(&keys[order], "{x:0>8}-89ab-4cde-8012-0123456789ab", .{order}) catch unreachable;
        requests.offer(.{ .nanoseconds = @as(i96, @intCast(order)) * 60_000_000_000 }, "12:34", &keys[order]);
    }
    requests.offer(.{ .nanoseconds = 1 << 60 }, null, key);
    try std.testing.expectEqual(Saved.capacity, requests.count);
    var recover_line: [recover_line_bytes]u8 = undefined;
    const shown = requests.list(recoverEntry(&recover_line, key)).?;
    try std.testing.expectEqual(Saved.capacity, shown.count);
    try std.testing.expectEqualStrings("/recover " ++ key, shown.entries[0].word);
    try std.testing.expectEqualStrings("retry this unconfirmed original, as Ctrl-R does", shown.entries[0].description);
    try std.testing.expectEqualStrings(key, conversation.parse(shown.entries[0].word).command.argument);
    for (shown.shown()[1..], 1..) |entry, index| {
        const newest = &keys[total - index];
        var expected: [64]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "/result {s}", .{newest}), entry.word);
        try std.testing.expectEqualStrings(entry.word, entry.shown);
        try std.testing.expectEqualStrings("12:34 · read this Message's saved answer", entry.description);
        try std.testing.expectEqualStrings(entry.word, shown.enter(index).rest);
        try std.testing.expect(shown.enter(index).runs);
        try std.testing.expectEqualStrings(newest, conversation.parse(entry.word).command.argument);
    }
    const without = requests.list(null).?;
    try std.testing.expectEqual(Saved.capacity, without.count);
    try std.testing.expectEqualStrings("/result " ++ key, without.entries[0].word);
    try std.testing.expectEqualStrings("read this Message's saved answer", without.entries[0].description);
}

test "rows from elsewhere than the draft that change are a new list, which no key acts on until a frame draws it" {
    var requests: Requests(8) = .{};
    requests.offer(.{ .nanoseconds = 1 }, null, "older");
    requests.offer(.{ .nanoseconds = 2 }, null, "newer");
    var stored = Shown.nextOf(null, 1, 7, requests.list(null));
    stored.?.drew(true);
    Shown.drawnNow(&stored, Shown.nextOf(stored, 1, 7, requests.list(null))).?.move(true);
    try std.testing.expectEqualStrings("/result older", Shown.drawnNow(&stored, Shown.nextOf(stored, 1, 7, requests.list(null))).?.completion());
    try std.testing.expect(Shown.drawnNow(&stored, Shown.nextOf(stored, 1, 8, requests.list(null))) == null);
    try std.testing.expectEqual(@as(usize, 0), stored.?.highlight);
    stored.?.drew(true);
    try std.testing.expectEqualStrings("/result newer", Shown.drawnNow(&stored, Shown.nextOf(stored, 1, 8, requests.list(null))).?.completion());
}

test "a /requests list takes only keys the parser reads back as one word the list can draw" {
    const Saved = Requests(8);
    var requests: Saved = .{};
    try std.testing.expect(requests.list(null) == null);
    for ([_][]const u8{ "", " ab", "ab ", "a b", "a\x1bb", "a\u{202e}b", "a\xffb", "a\xc3", "123456789" }) |key| requests.offer(.zero, null, key);
    try std.testing.expect(requests.list(null) == null);
    for ([_][]const u8{ "café", "a\"b'c\\d", "12345678" }) |key| requests.offer(.zero, null, key);
    const shown = requests.list(null).?;
    try std.testing.expectEqual(@as(usize, 3), shown.count);
    for (shown.shown()) |entry| try std.testing.expectEqualStrings(entry.word["/result ".len..], conversation.parse(entry.word).command.argument);
}

test "a draft is a command line, one unfinished slash word, or a Message, by the whole grammar" {
    const names = [_][]const u8{ "archive", "clear", "copy", "discard", "effort", "model", "new", "pin", "recover", "reload-skills", "rename", "requests", "result", "setup", "unarchive", "unpin" };
    try std.testing.expectEqual(std.enums.values(conversation.Name).len, names.len);
    const Draft = conversation.Draft;
    for (names) |name| {
        var buffer: [80]u8 = undefined;
        for ([_][]const u8{ "", " ", " argument", " two words", " a\nline" }) |rest| {
            const draft = try std.fmt.bufPrint(&buffer, "/{s}{s}", .{ name, rest });
            try std.testing.expectEqual(Draft.command, conversation.draftOf(draft));
            try std.testing.expect(conversation.parse(draft) != .unknown);
        }
        for (0..name.len) |length| {
            if (conversation.nameOf(name[0..length]) != null) continue;
            const word = try std.fmt.bufPrint(&buffer, "/{s}", .{name[0..length]});
            try std.testing.expectEqual(Draft.word, conversation.draftOf(word));
            const text = try std.fmt.bufPrint(&buffer, "/{s} this change", .{name[0..length]});
            try std.testing.expectEqual(Draft.message, conversation.draftOf(text));
        }
        const longer = try std.fmt.bufPrint(&buffer, "/{s}x", .{name});
        try std.testing.expectEqual(Draft.word, conversation.draftOf(longer));
        for ([_][]const u8{ "use /{s}", " /{s}", "//{s}", "//{s} now" }) |shape| {
            var text: [80]u8 = undefined;
            var writer = std.Io.Writer.fixed(&text);
            var parts = std.mem.splitSequence(u8, shape, "{s}");
            try writer.writeAll(parts.next().?);
            try writer.writeAll(name);
            try writer.writeAll(parts.next().?);
            try std.testing.expectEqual(Draft.message, conversation.draftOf(writer.buffered()));
        }
    }
    const cases = [_]struct { []const u8, Draft }{
        .{ "", .message },
        .{ "plain text", .message },
        .{ "/", .word },
        .{ "//", .message },
        .{ "/review", .word },
        .{ "/review this change", .message },
        .{ "/review\tthis", .message },
        .{ "/review\nthis change", .message },
        .{ "/genuinely-unknown", .word },
        .{ "/path/to/file", .word },
        .{ "/path/to/file is broken", .message },
        .{ "/Archive", .word },
        .{ "/archive\n", .message },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], conversation.draftOf(case[0]));
}

test "the grammar leaves a first word's rows to the caret's word" {
    // `skill_completion` matches a first word against commands and skills
    // alike; the grammar only says a list is for it.
    for ([_][]const u8{ "", "a", "re", "rel", "requests", "discard", "zz", "model" }) |typed| {
        var buffer: [80]u8 = undefined;
        const draft = try std.fmt.bufPrint(&buffer, "/{s}", .{typed});
        const list = conversation.suggest(draft, .{}).?;
        try std.testing.expectEqual(@as(usize, 0), list.count);
        try std.testing.expectEqualStrings(typed, list.typed);
    }
}

test "a command admits exactly the arguments its shape names" {
    const cases = .{
        .{ "/copy", conversation.Parsed{ .command = .{ .name = .copy, .argument = "" } } },
        .{ "/copy code", conversation.Parsed{ .command = .{ .name = .copy, .argument = "code" } } },
        .{ "/copy file", conversation.Parsed{ .command = .{ .name = .copy, .argument = "file" } } },
        .{ "/copy all", conversation.Parsed{ .misused = .copy } },
        .{ "/effort", conversation.Parsed{ .misused = .effort } },
        .{ "/effort  high ", conversation.Parsed{ .command = .{ .name = .effort, .argument = "high" } } },
        .{ "/rename", conversation.Parsed{ .misused = .rename } },
        .{ "/rename  ", conversation.Parsed{ .misused = .rename } },
        .{ "/rename lane four", conversation.Parsed{ .command = .{ .name = .rename, .argument = "lane four" } } },
        .{ "/result", conversation.Parsed{ .misused = .result } },
        .{ "/inspect-action", @as(conversation.Parsed, .unknown) },
        .{ "/configurex", @as(conversation.Parsed, .unknown) },
        .{ "/", @as(conversation.Parsed, .unknown) },
        .{ "//status", @as(conversation.Parsed, .unknown) },
    };
    inline for (cases) |case| {
        const parsed = conversation.parse(case[0]);
        try std.testing.expectEqual(std.meta.activeTag(case[1]), std.meta.activeTag(parsed));
        switch (case[1]) {
            .unknown => {},
            .misused => |name| try std.testing.expectEqual(name, parsed.misused),
            .command => |command| {
                try std.testing.expectEqual(command.name, parsed.command.name);
                try std.testing.expectEqualStrings(command.argument, parsed.command.argument);
            },
        }
    }
}

test "a command's list names the choices its word starts, and Tab puts the highlighted one in" {
    const Case = struct { draft: []const u8, shown: ?[]const []const u8, first: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .draft = "/", .shown = &.{} },
        .{ .draft = "/c", .shown = &.{} },
        .{ .draft = "/login", .shown = &.{} },
        .{ .draft = "/copy ", .shown = &.{ "code", "file" }, .first = "code" },
        .{ .draft = "/copy f", .shown = &.{"file"}, .first = "ile" },
        .{ .draft = "/copy file ", .shown = null },
        .{ .draft = "/rename ", .shown = null },
        .{ .draft = "/reload-skills ", .shown = null },
        .{ .draft = "/status ", .shown = null },
        .{ .draft = "/nope ", .shown = null },
        .{ .draft = "/c\n", .shown = null },
        .{ .draft = "/c\t", .shown = null },
        .{ .draft = "c", .shown = null },
        .{ .draft = "", .shown = null },
        .{ .draft = "//", .shown = null },
    };
    for (cases) |case| {
        errdefer std.debug.print("draft={s}\n", .{case.draft});
        const list = conversation.suggest(case.draft, .{}) orelse {
            try std.testing.expect(case.shown == null);
            continue;
        };
        try std.testing.expectEqual(case.shown.?.len, list.count);
        for (case.shown.?, list.shown()) |expected, entry| try std.testing.expectEqualStrings(expected, entry.word);
        if (case.first) |first| try std.testing.expectEqualStrings(first, list.completion(0));
    }
}

test "listed commands are every listed name in order, and reload runs immediately" {
    const listed = conversation.listed();
    const expected = [_][]const u8{ "archive", "clear", "copy ", "effort ", "model", "new", "pin", "reload-skills", "rename ", "requests", "result ", "setup ", "unarchive", "unpin" };
    try std.testing.expectEqual(expected.len, listed.count);
    for (expected, listed.shown()) |word, entry| try std.testing.expectEqualStrings(word, entry.word);
    const reload = listed.shown()[7];
    try std.testing.expectEqualStrings("reload-skills", reload.word);
    try std.testing.expect(reload.runs);
}

test "/effort offers every grammar value for an unlisted model" {
    const list = conversation.suggest("/effort ", .{ .model = "unlisted-model", .effort = .max }).?;
    const expected = [_][]const u8{ "none", "low", "medium", "high", "xhigh", "max", "default" };
    try std.testing.expectEqual(expected.len, list.count);
    for (expected, list.shown()) |word, entry| {
        try std.testing.expectEqualStrings(word, entry.word);
        try std.testing.expectEqualStrings("", entry.description);
    }
}

test "/effort lists only the names of efforts the screen's model offers" {
    const model = "gpt-5.5";
    const list = conversation.suggest("/effort ", .{ .model = model, .effort = .high }).?;
    var expected: usize = 0;
    for (std.enums.values(ReasoningEffort)) |effort| if (model_capability.supportsReasoningEffort(model_catalog.shipped, model, effort)) {
        const entry = list.shown()[expected];
        try std.testing.expectEqualStrings(@tagName(effort), entry.word);
        try std.testing.expectEqualStrings("", entry.description);
        expected += 1;
    };
    try std.testing.expect(expected != 0);
    try std.testing.expectEqual(expected + 1, list.count);
    try std.testing.expectEqualStrings("default", list.shown()[expected].word);
    try std.testing.expectEqualStrings("gh", conversation.suggest("/effort hi", .{ .model = model }).?.completion(0));
    try std.testing.expectEqual(@as(usize, 0), conversation.suggest("/effort ", .{}).?.count);
    try std.testing.expect(conversation.suggest("/effort high ", .{ .model = model }) == null);
}

test "/setup lists its options and every effort for any model" {
    const saved = conversation.suggest("/setup --reasoning-effort ", .{ .model = "gpt-5.5" }).?;
    try std.testing.expectEqual(std.enums.values(ReasoningEffort).len + 1, saved.count);
    const listed = conversation.suggest("/setup ", .{ .model = "gpt-6-luna" }).?;
    try std.testing.expectEqual(setup_options.entries.len, listed.count);
    for (setup_options.entries, listed.shown()) |entry, shown| {
        try std.testing.expectEqualStrings(entry.word, shown.word);
        var draft: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&draft, "/setup {s}", .{entry.word});
        const after = conversation.suggest(line, .{ .model = "gpt-6-luna" }).?;
        if (entry.runs) try std.testing.expectEqual(setup_options.entries.len, after.count);
    }
    try std.testing.expectEqualStrings("--provider ", conversation.suggest("/setup --model gpt-5.5 --p", .{}).?.shown()[0].word);
    try std.testing.expect(conversation.suggest("/setup --model \"a ", .{}) == null);
}

test "a key's list is the draft's own, and counts as drawn when the latest frame drew a list" {
    const c = conversation.suggest("/copy ", .{}).?;
    const co = conversation.suggest("/copy f", .{}).?;
    var stored: ?Shown = Shown.next(null, 1, c);
    stored.?.drew(true);
    Shown.drawnNow(&stored, Shown.next(stored, 1, c)).?.move(true);
    try std.testing.expectEqualStrings(c.completion(1), Shown.next(stored, 1, c).?.completion());
    const changed = Shown.drawnNow(&stored, Shown.next(stored, 2, co)).?;
    try std.testing.expectEqual(@as(usize, 0), changed.highlight);
    try std.testing.expectEqualStrings(co.completion(0), changed.completion());
    changed.close();
    stored = Shown.next(stored, 2, co);
    stored.?.drew(true);
    try std.testing.expectEqual(@as(usize, 0), stored.?.rows());
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 2, co)) == null);
    try std.testing.expectEqualStrings(co.completion(0), Shown.next(stored, 2, co).?.completion());
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 3, c)) == null);
    stored = Shown.next(stored, 3, c);
    stored.?.drew(false);
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 4, c)) == null);
    stored.?.drew(true);
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 4, c)) != null);
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 5, null)) == null);
    try std.testing.expectEqual(@as(u64, 4), stored.?.revision);
}

test "the list order is the names' order and usage retains argument shapes" {
    inline for (.{conversation}) |screen| {
        const names = std.enums.values(screen.Name);
        for (names[1..], 0..) |name, index| try std.testing.expectEqual(.lt, std.mem.order(u8, @tagName(names[index]), @tagName(name)));
    }
    try std.testing.expectEqualStrings("/copy [code|file]", conversation.usage.get(.copy));
    try std.testing.expectEqualStrings("/rename NAME", conversation.usage.get(.rename));
    try std.testing.expectEqualStrings("/effort LEVEL", conversation.usage.get(.effort));
    try std.testing.expectEqualStrings("/reload-skills", conversation.usage.get(.@"reload-skills"));
}

test "/copy takes each Copy's name but the answer's, which it copies alone" {
    for (std.enums.values(Copy)) |copy| {
        var text: [16]u8 = undefined;
        const parsed = conversation.parse(try std.fmt.bufPrint(&text, "/copy {s}", .{@tagName(copy)}));
        if (copy == .answer) try std.testing.expectEqual(conversation.Name.copy, parsed.misused) else try std.testing.expectEqualStrings(@tagName(copy), parsed.command.argument);
    }
}

test "/setup completion preserves the shared option order" {
    const options = conversation.suggest("/setup ", .{}).?;
    try std.testing.expectEqual(setup_options.entries.len, options.count);
    for (setup_options.entries, options.shown()) |entry, shown| try std.testing.expectEqualStrings(entry.word, shown.word);
}

test "an unknown command names itself when it is short printable ASCII" {
    var buffer: [unknown_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("! Unknown command /foo", unknown(&buffer, "/foo bar"));
    try std.testing.expectEqualStrings("! Unknown command", unknown(&buffer, "/\x1b[2J"));
    const long = "/" ++ @as([max_unknown_name]u8, @splat('x'));
    try std.testing.expectEqualStrings("! Unknown command", unknown(&buffer, long));
    try std.testing.expectEqualStrings("! Unknown command " ++ long[0..max_unknown_name] ++ "", unknown(&buffer, long[0..max_unknown_name]));
}

test "a command's short output is a conversation notice, and longer output takes a page" {
    var buffer: [result_notice_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Configured.", resultNotice(&buffer, "Rui: Configured.\n").?);
    try std.testing.expectEqualStrings("Saved.\n! Host unavailable", resultNotice(&buffer, "Saved.\nrui: Host unavailable\n").?);
    try std.testing.expectEqualStrings(no_output, resultNotice(&buffer, "").?);
    try std.testing.expectEqualStrings(no_output, resultNotice(&buffer, "\n").?);
    try std.testing.expect(resultNotice(&buffer, "one\ntwo\nthree\n") == null);
    const long: [short_result_bytes + 1]u8 = @splat('x');
    try std.testing.expect(resultNotice(&buffer, &long) == null);
    try std.testing.expectEqual(@as(usize, short_result_bytes), resultNotice(&buffer, long[0..short_result_bytes]).?.len);
}

test "deleted app commands are unknown in conversation and absent from completion" {
    inline for (.{conversation}) |screen| {
        inline for (.{ "help", "upgrade", "login", "wait", "inspect-action", "exit" }) |name| {
            try std.testing.expect(screen.parse("/" ++ name) == .unknown);
            try std.testing.expect(screen.parse("/" ++ name ++ " now") == .unknown);
            try std.testing.expectEqual(@as(usize, 0), screen.suggest("/" ++ name, .{}).?.count);
        }
    }
}

test "archive commands parse in conversation and reject extra arguments" {
    for ([_][]const u8{ "/archive", "/unarchive", "/pin", "/unpin" }) |line| {
        try std.testing.expect(conversation.parse(line) == .command);
        const extra = try std.fmt.allocPrint(std.testing.allocator, "{s} extra", .{line});
        defer std.testing.allocator.free(extra);
        try std.testing.expect(conversation.parse(extra) == .misused);
    }
    try std.testing.expect(conversation.parse("/sessions archived") == .unknown);
}

test "archive commands retain separate local command identities" {
    inline for (.{conversation}) |screen| {
        inline for (.{ "archive", "unarchive", "pin", "unpin" }) |name| {
            const parsed = screen.parse("/" ++ name);
            try std.testing.expect(parsed == .command);
            try std.testing.expectEqualStrings(name, @tagName(parsed.command.name));
            try std.testing.expectEqualStrings("", parsed.command.argument);
            try std.testing.expect(screen.parse("/" ++ name ++ " other") == .misused);
            const list = screen.listed();
            const row = for (list.shown()) |entry| {
                if (std.mem.eql(u8, entry.word, name)) break entry;
            } else return error.TestUnexpectedResult;
            try std.testing.expect(row.runs);
        }
    }
}

test "older conversation is feed navigation, not a slash command" {
    try std.testing.expect(conversation.parse("/history") == .unknown);
    try std.testing.expectEqual(@as(usize, 0), conversation.suggest("/history", .{}).?.count);
    const list = conversation.suggest("/h", .{}).?;
    try std.testing.expectEqual(@as(usize, 0), list.count);
    try std.testing.expect(conversation.parse("/details") == .unknown);
}

test "status and configure remain absent; model is a Session picker" {
    for ([_][]const u8{ "/status", "/status now", "/configure", "/configure --label chat" }) |line| {
        try std.testing.expect(conversation.parse(line) == .unknown);
        if (conversation.suggest(line, .{})) |list| try std.testing.expectEqual(@as(usize, 0), list.count);
    }
}

test "command choices and options are names only and recovery stays unlisted" {
    try std.testing.expect(@hasField(Command, "description"));
    try std.testing.expect(!@hasField(Choice, "description"));
    try std.testing.expect(!conversation.table.get(.discard).listed);
    try std.testing.expect(!conversation.table.get(.recover).listed);
    inline for (.{.{ conversation, "/setup " }}) |case| {
        const options = case[0].suggest(case[1], .{}).?;
        for (options.shown()) |entry| {
            try std.testing.expectEqualStrings(std.mem.trimEnd(u8, entry.word, " "), entry.shown);
            try std.testing.expectEqualStrings("", entry.description);
        }
    }
    inline for (.{.{ conversation, "/copy " }}) |case| {
        const choices = case[0].suggest(case[1], .{}).?;
        for (choices.shown()) |entry| {
            try std.testing.expectEqualStrings(entry.word, entry.shown);
            try std.testing.expectEqualStrings("", entry.description);
        }
    }
}
