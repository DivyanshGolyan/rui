//! Each screen's slash commands: one table per screen of each command's
//! name, argument shape and one-line description. The screen's parser, the
//! list typing "/" shows, Tab and /help all read it.
const std = @import("std");
const cli_args = @import("cli_args.zig");
const model_capability = @import("model_capability.zig");
const ReasoningEffort = model_capability.ReasoningEffort;

/// What may follow the name, after one space.
pub const Argument = union(enum) {
    none,
    /// Anything, or nothing; the word names it in the list.
    optional: []const u8,
    /// Some text; the word names it in the list.
    required: []const u8,
    /// Nothing, or exactly one of these words.
    choice: []const Choice,
    /// One of the efforts the screen's model offers.
    effort,
    /// Options of `grammar`, as a shell spells them; the list offers the
    /// `names` and each one's fixed values.
    options: Options,
};

/// Whether a command needs a word after its name before Enter on it in
/// the list runs it.
fn requires(argument: Argument) bool {
    return switch (argument) {
        .required, .effort => true,
        .options => |options| !options.alone,
        .none, .optional, .choice => false,
    };
}

/// A word an argument may be, and what it does.
pub const Choice = struct { word: []const u8, description: []const u8 };

pub const Options = struct {
    grammar: cli_args.Definition,
    /// The options the list offers, in its order: each spelled with a space
    /// after it, since another word follows, and its argument's shape.
    entries: []const Entry,
    /// Whether the command alone does something; else alone it only says
    /// its usage, so Enter on it in the list waits for an option.
    alone: bool,
    /// Whether its --reasoning-effort is one Session's, so it lists the
    /// efforts that Session's model offers; else it is a default for any
    /// model and lists every effort.
    session: bool,

    fn of(comptime grammar: cli_args.Definition, comptime names: []const []const u8, comptime alone: bool, comptime session: bool) Options {
        var entries: [names.len]Entry = undefined;
        for (&entries, names) |*entry, option| {
            const argument = grammar.argumentOf(option) orelse @compileError("no option --" ++ option);
            // A flag is whole; an option waits for its value.
            entry.* = .{ .word = "--" ++ option ++ " ", .shown = "--" ++ option ++ if (argument) |shape| " " ++ shape else "", .description = "", .runs = argument == null };
        }
        const final = entries;
        return .{ .grammar = grammar, .entries = &final, .alone = alone, .session = session };
    }
};

/// What the screen in front knows that the list offers: the model whose
/// efforts /effort and --reasoning-effort list, and the effort in force.
pub const Context = struct {
    model: ?[]const u8 = null,
    effort: ?ReasoningEffort = null,
};

/// What /copy copies: the last answer, or what its one word names.
pub const Copy = enum { answer, code, file };

pub const Command = struct {
    argument: Argument = .none,
    /// Null keeps the command out of the list and /help: it exists only to
    /// say where the thing it names lives.
    description: ?[]const u8,
    /// False keeps a command /help names out of the list typing "/" shows:
    /// it is for recovery, which /help explains.
    listed: bool = true,
};

/// /copy's words: every `Copy` but the answer, which /copy alone copies.
const copy_words = &[_]Choice{
    .{ .word = "code", .description = "the last answer's last code block" },
    .{ .word = "file", .description = "save the last answer to a file here" },
};

comptime {
    for (@typeInfo(Copy).@"enum".field_names[1..], copy_words) |field, choice| std.debug.assert(std.mem.eql(u8, field, choice.word));
}

/// The settings a live Session changes. Its model and sign-in never change,
/// and its instructions come only from a shell.
const live_options: Options = .of(cli_args.live_configure, &.{ "permission-mode", "tools", "reasoning-effort", "label", "workspace", "compaction-trigger", "output-reservation", "output-schema", "text-output" }, false, true);

/// Future defaults, as /setup saves them; /setup alone shows them.
const setup_options: Options = .of(cli_args.live_setup, &.{ "model", "provider", "reasoning-effort", "notifications", "clear-model", "store" }, true, false);

/// The conversation's commands, declared in the order its list and /help
/// show them.
const ConversationName = enum {
    configure,
    copy,
    details,
    discard,
    effort,
    exit,
    help,
    history,
    @"inspect-action",
    login,
    model,
    recover,
    rename,
    requests,
    result,
    setup,
    status,
    wait,
};

/// A conversation's commands.
pub const conversation = Commands(ConversationName, .{
    .configure = .{ .argument = .{ .options = live_options }, .description = "change this Session's settings" },
    .copy = .{ .argument = .{ .choice = copy_words }, .description = "copy the last answer; code its last block, file saves it here" },
    .details = .{ .description = "saved tool output" },
    .discard = .{ .description = "release rejected input, retaining the draft", .listed = false },
    .effort = .{ .argument = .effort, .description = "this Session's effort, also the default for new ones" },
    .exit = .{ .description = "detach; Host work continues, unsent draft is lost" },
    .help = .{ .description = "keys and commands" },
    .history = .{ .description = "older conversation" },
    .@"inspect-action" = .{ .description = "exact one-shot diagnostics", .listed = false },
    .login = .{ .description = null },
    .model = .{ .description = "this Session's model and sign-in" },
    .recover = .{ .argument = .{ .required = "KEY" }, .description = "the original request", .listed = false },
    .rename = .{ .argument = .{ .required = "NAME" }, .description = "name this Session" },
    .requests = .{ .description = "recovery handles", .listed = false },
    .result = .{ .argument = .{ .required = "KEY" }, .description = "a saved answer", .listed = false },
    .setup = .{ .argument = .{ .options = setup_options }, .description = "future defaults" },
    .status = .{ .description = "settings and work" },
    .wait = .{ .description = null },
});

/// What the overview's /configure holds for the next Session: a fresh
/// Session's settings.
const start_options: Options = .of(cli_args.live_configure, &.{ "permission-mode", "tools", "reasoning-effort", "label", "workspace", "compaction-trigger", "output-reservation", "model", "provider" }, false, true);

/// The overview's commands. /rename and /setup run as a conversation runs
/// them; /rename names the selected Session.
pub const overview = Commands(enum { configure, exit, help, model, rename, setup }, .{
    .configure = .{ .argument = .{ .options = start_options }, .description = "hold settings for the next Session" },
    .exit = .{ .description = "leave; Host work continues" },
    .help = conversation.table.get(.help),
    .model = .{ .description = "choose the model new Sessions use" },
    .rename = .{ .argument = conversation.table.get(.rename).argument, .description = "name the selected Session" },
    .setup = conversation.table.get(.setup),
});

/// What both screens say for a line that names no command: the name typed,
/// when it is short printable ASCII, and where the commands are.
pub fn unknown(buffer: *[unknown_bytes]u8, text: []const u8) []const u8 {
    const name = text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
    var shown = name.len <= max_unknown_name;
    for (name) |byte| shown = shown and byte > ' ' and byte < 0x7f;
    return std.fmt.bufPrint(buffer, "! Unknown command{s}{s} · /help", .{ if (shown) " " else "", if (shown) name else "" }) catch unreachable;
}

const max_unknown_name = 32;
pub const unknown_bytes = "! Unknown command  · /help".len + max_unknown_name;

/// The most a command's output may hold and still show as a notice, on
/// either screen; more opens a page.
pub const short_result_bytes = 256;
/// The most lines a command's output may hold and still show as a notice.
pub const short_result_lines = 2;
/// Room for a short result as a notice says it, a mark on each line.
pub const result_notice_bytes = short_result_bytes + short_result_lines * "! ".len;

/// What both screens say for `output`, a command's complete output, when it
/// is short: each line with the CLI's `Rui: ` dropped and its `rui: `
/// diagnostics marked `!`, or `no_output` for none. Null when the output
/// takes a page.
pub fn resultNotice(buffer: *[result_notice_bytes]u8, output: []const u8) ?[]const u8 {
    if (output.len > short_result_bytes) return null;
    const text = std.mem.trimEnd(u8, output, "\n");
    if (text.len == 0) return no_output;
    if (std.mem.count(u8, text, "\n") >= short_result_lines) return null;
    // A mark replaces a longer prefix, and the buffer has room for one on
    // every line besides, so the writes always fit.
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

/// What a command that printed nothing says.
pub const no_output = "Command finished with no output.";

/// How many commands a list of `rows` rows names when `total` match: all
/// that fit; when more match, the last row counts the rest instead, unless
/// it is the only row.
pub fn named(total: usize, rows: usize) usize {
    return if (total <= rows) total else if (rows >= 2) rows - 1 else rows;
}

/// The row that counts the commands a list leaves out.
pub const more = "+{d} more · type to narrow";

/// One screen's commands, `Name` in list order, and what the screen reads
/// from them.
pub fn Commands(comptime N: type, comptime commands: std.enums.EnumFieldStruct(N, Command, null)) type {
    return struct {
        pub const Name = N;
        pub const table = std.enums.EnumArray(Name, Command).init(commands);

        /// The command as typed with its argument's shape, as in `/copy [code|file]`.
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

        /// Cells from a listed command's start to its description.
        pub const description_column = blk: {
            var widest = 0;
            for (std.enums.values(Name)) |name| if (table.get(name).description != null) {
                widest = @max(widest, usage.get(name).len);
            };
            break :blk widest + 2;
        };

        /// Spaces that pad a usage to `description_column`.
        pub const padding: [description_column]u8 = @splat(' ');

        /// The listed commands, one per line, as /help shows them.
        pub const help = blk: {
            var text: []const u8 = "";
            for (std.enums.values(Name)) |name| if (table.get(name).description) |description| {
                text = text ++ usage.get(name) ++ padding[usage.get(name).len..] ++ description ++ "\n";
            };
            break :blk text;
        };

        pub const Parsed = union(enum) {
            /// Not a command's name.
            unknown,
            /// A command's name with an argument its shape does not admit.
            misused: Name,
            /// Spaces trimmed; empty when none was given.
            command: struct { name: Name, argument: []const u8 },
        };

        /// Reads a draft line that starts with `/`.
        pub fn parse(text: []const u8) Parsed {
            std.debug.assert(text.len != 0 and text[0] == '/');
            const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
            const name = std.meta.stringToEnum(Name, text[1..end]) orelse return .unknown;
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

        /// Drops the spaces around an argument, but keeps a final space a
        /// backslash escapes: the argument's decoder reads it as part of a word.
        fn trimmed(raw: []const u8) []const u8 {
            const argument = std.mem.trimStart(u8, raw, " ");
            var len = std.mem.trimEnd(u8, argument, " ").len;
            var slashes: usize = 0;
            while (slashes < len and argument[len - 1 - slashes] == '\\') slashes += 1;
            if (slashes % 2 == 1 and len < argument.len) len += 1;
            return argument[0..len];
        }

        /// What the list shows for `draft`, read against `context`: the
        /// commands its command word starts, or the choices the word being
        /// typed after a command's name starts. Null for any other draft,
        /// which shows no list and takes Tab as a tab.
        pub fn suggest(draft: []const u8, context: Context) ?List {
            if (draft.len == 0 or draft[0] != '/' or std.mem.startsWith(u8, draft, "//")) return null;
            if (std.mem.indexOfAny(u8, draft, "\t\n") != null) return null;
            var list: List = .{ .typed = undefined };
            const end = std.mem.indexOfScalar(u8, draft, ' ') orelse {
                list.typed = draft[1..];
                list.column = description_column;
                for (names) |name| {
                    const command = table.get(name);
                    if (command.description == null or !command.listed or !std.mem.startsWith(u8, @tagName(name), list.typed)) continue;
                    list.add(.{ .word = spaced.get(name)[1 .. spaced.get(name).len - @intFromBool(command.argument == .none)], .shown = usage.get(name), .description = command.description.?, .runs = !requires(command.argument) });
                }
                return list;
            };
            const name = std.meta.stringToEnum(Name, draft[1..end]) orelse return null;
            const words = draft[end + 1 ..];
            // A quote or an escape starts text the list cannot follow.
            if (std.mem.indexOfAny(u8, words, "\"'\\") != null) return null;
            const start = if (std.mem.lastIndexOfScalar(u8, words, ' ')) |space| space + 1 else 0;
            list.typed = words[start..];
            const before = std.mem.trimEnd(u8, words[0..start], " ");
            switch (table.get(name).argument) {
                .none, .optional, .required => return null,
                .choice => |choices| {
                    if (before.len != 0) return null;
                    for (choices) |choice| list.offer(choice.word, choice.word, choice.description);
                },
                .effort => {
                    if (before.len != 0) return null;
                    list.offerEfforts(context);
                },
                .options => |options| {
                    const previous = before[if (std.mem.lastIndexOfScalar(u8, before, ' ')) |space| space + 1 else 0..];
                    // A word after an option that takes a value is that value.
                    if (std.mem.startsWith(u8, previous, "--")) if (options.grammar.argumentOf(previous[2..])) |argument| if (argument) |shape| {
                        if (options.session and std.mem.eql(u8, previous[2..], "reasoning-effort")) list.offerEfforts(context) else list.offerValues(shape);
                        return list;
                    };
                    for (options.entries) |entry| if (std.mem.startsWith(u8, entry.word, list.typed)) list.add(entry);
                },
            }
            return list;
        }

        const names = std.enums.values(Name);

        /// `/name ` for each command, so a completion borrows static bytes.
        const spaced = blk: {
            var texts: std.enums.EnumArray(Name, []const u8) = undefined;
            for (names) |name| texts.set(name, "/" ++ @tagName(name) ++ " ");
            break :blk texts;
        };
    };
}

/// One row of the list: the whole word the person is typing, as Tab puts
/// it in the draft (with a space when another word may follow), what the
/// row shows, and what the word does.
pub const Entry = struct {
    word: []const u8,
    shown: []const u8,
    description: []const u8,
    /// Whether Enter on the entry runs the command it completes; else
    /// Enter only puts the word in, for the next one.
    runs: bool = true,
};

/// What the list shows for a draft: the words that start what is typed.
pub const List = struct {
    /// The word being typed, which every entry's word starts.
    typed: []const u8,
    entries: [capacity]Entry = undefined,
    count: usize = 0,
    /// Where descriptions start, when the list names one: the screen's
    /// commands keep theirs while typing narrows them.
    column: ?usize = null,

    /// More than any screen's commands or options.
    pub const capacity = 24;

    fn add(self: *List, entry: Entry) void {
        std.debug.assert(std.mem.startsWith(u8, entry.word, self.typed));
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn offer(self: *List, word: []const u8, text: []const u8, description: []const u8) void {
        if (std.mem.startsWith(u8, word, self.typed)) self.add(.{ .word = word, .shown = text, .description = description });
    }

    /// The efforts the context's model offers, the one in force marked, and
    /// `default`, which clears the choice.
    fn offerEfforts(self: *List, context: Context) void {
        const model = context.model orelse return;
        for (std.enums.values(ReasoningEffort)) |effort| if (model_capability.supportsReasoningEffort(model, effort)) {
            self.offer(@tagName(effort), @tagName(effort), if (context.effort == effort) "current" else "");
        };
        self.offer("default", "default", "the model's own");
    }

    /// The fixed words an option's value may be: the lowercase
    /// alternatives its shape names, so `TOKENS|default` offers `default`.
    fn offerValues(self: *List, shape: []const u8) void {
        var values = std.mem.splitScalar(u8, shape, '|');
        while (values.next()) |value| {
            const fixed = value.len != 0 and for (value) |byte| {
                if (!std.ascii.isLower(byte) and byte != '_' and byte != ',') break false;
            } else true;
            if (fixed) self.offer(value, value, "");
        }
    }

    pub fn shown(self: *const List) []const Entry {
        return self.entries[0..self.count];
    }

    /// What Tab or Enter adds to the draft for the highlighted entry: the
    /// rest of its word.
    pub fn completion(self: *const List, highlight: usize) []const u8 {
        return self.entries[highlight].word[self.typed.len..];
    }

    /// What Enter does with the highlighted entry: adds the rest of its
    /// word to the draft, and then, when `runs`, runs the line that makes,
    /// without the space `rest` ends with when another word may follow.
    pub fn enter(self: *const List, highlight: usize) struct { rest: []const u8, runs: bool } {
        const entry = self.entries[highlight];
        if (!entry.runs) return .{ .rest = self.completion(highlight), .runs = false };
        return .{ .rest = std.mem.trimEnd(u8, entry.word, " ")[self.typed.len..], .runs = true };
    }

    /// The first of `rows` rows that keep the highlighted entry in view.
    pub fn firstShown(self: *const List, highlight: usize, rows: usize) usize {
        const fit = named(self.count, rows);
        return @min((highlight + 1) -| fit, self.count - fit);
    }

    /// Cells from a row's start to its description: the widest shown text
    /// and two spaces.
    pub fn descriptionColumn(self: *const List) usize {
        if (self.column) |column| return column;
        var widest: usize = 0;
        for (self.shown()) |entry| widest = @max(widest, entry.shown.len);
        return widest + 2;
    }
};

/// The list built for one draft revision, and what the latest frame did
/// with a list: the one value Enter, Esc, the arrows and Tab act on. A key
/// on a draft changed since the frame first brings it to that draft through
/// `next`, as the next frame would, so its rows are always the draft's.
/// Enter, Esc and the arrows act on it only when the latest frame drew a
/// list; Tab completes from it also after Esc closed it or when the screen
/// had no rows for it.
pub const Shown = struct {
    list: List,
    /// The draft revision the list was built for.
    revision: u64,
    /// The highlighted entry: the first until Up or Down moves it, and the
    /// last when the list narrowed under it (the model changed, say).
    highlight: usize = 0,
    seen: enum { drawn, hidden, closed } = .hidden,

    /// The list, `list`, for the draft at `revision`, after `previous`:
    /// while the draft is the one `previous` was built for, it keeps its
    /// highlight and stays closed once Esc closed it; any edit starts a list
    /// at its first row. It counts as drawn while the latest frame drew a
    /// list, until a frame records its own. Null when nothing matches.
    pub fn next(previous: ?Shown, revision: u64, list: ?List) ?Shown {
        const built = list orelse return null;
        if (built.count == 0) return null;
        const kept = previous orelse return .{ .list = built, .revision = revision };
        if (kept.revision != revision) return .{ .list = built, .revision = revision, .seen = if (kept.seen == .drawn) .drawn else .hidden };
        return .{ .list = built, .revision = revision, .highlight = @min(kept.highlight, built.count - 1), .seen = kept.seen };
    }

    /// The list Enter, Esc and the arrows act on: `stored`, the latest
    /// frame's, becomes `current`, its `next` for the draft as it is now,
    /// when the latest frame drew a list.
    pub fn drawnNow(stored: *?Shown, current: ?Shown) ?*Shown {
        stored.* = current orelse return null;
        const kept = &stored.*.?;
        return if (kept.seen == .drawn) kept else null;
    }

    /// The rows the list asks of the frame: none once Esc closed it.
    pub fn rows(self: *const Shown) usize {
        return if (self.seen == .closed) 0 else self.list.count;
    }

    /// Records whether the frame had rows for the list.
    pub fn drew(self: *Shown, drawn: bool) void {
        if (self.seen != .closed) self.seen = if (drawn) .drawn else .hidden;
    }

    /// Esc: the list stays closed until the draft changes.
    pub fn close(self: *Shown) void {
        self.seen = .closed;
    }

    /// What Tab adds to the draft: the rest of the highlighted entry's word.
    pub fn completion(self: *const Shown) []const u8 {
        return self.list.completion(self.highlight);
    }

    /// Up or Down: the highlight moves, stopping at the list's ends.
    pub fn move(self: *Shown, down: bool) void {
        self.highlight = if (down) @min(self.highlight + 1, self.list.count - 1) else self.highlight -| 1;
    }
};

test "a command admits exactly the arguments its shape names" {
    const cases = .{
        .{ "/status", conversation.Parsed{ .command = .{ .name = .status, .argument = "" } } },
        .{ "/status ", conversation.Parsed{ .command = .{ .name = .status, .argument = "" } } },
        .{ "/status now", conversation.Parsed{ .misused = .status } },
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
        .{ "/inspect-action", conversation.Parsed{ .command = .{ .name = .@"inspect-action", .argument = "" } } },
        .{ "/configure --label \"a b\"", conversation.Parsed{ .command = .{ .name = .configure, .argument = "--label \"a b\"" } } },
        .{ "/configure --label lane\\  ", conversation.Parsed{ .command = .{ .name = .configure, .argument = "--label lane\\ " } } },
        .{ "/configure --label lane\\\\  ", conversation.Parsed{ .command = .{ .name = .configure, .argument = "--label lane\\\\" } } },
        .{ "/configurex", @as(conversation.Parsed, .unknown) },
        .{ "/", @as(conversation.Parsed, .unknown) },
        .{ "//status", @as(conversation.Parsed, .unknown) },
        .{ "/status\tnow", @as(conversation.Parsed, .unknown) },
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

test "the list names the listed commands a command word starts, and Tab puts the highlighted one in" {
    const Case = struct { draft: []const u8, shown: ?[]const []const u8, first: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .draft = "/", .shown = &.{ "configure ", "copy ", "details", "effort ", "exit", "help", "history", "model", "rename ", "setup ", "status" } },
        .{ .draft = "/c", .shown = &.{ "configure ", "copy " }, .first = "onfigure " },
        .{ .draft = "/cop", .shown = &.{"copy "}, .first = "y " },
        .{ .draft = "/st", .shown = &.{"status"}, .first = "atus" },
        .{ .draft = "/re", .shown = &.{"rename "} },
        // Recovery commands work, and /help names them, but the list leaves them out.
        .{ .draft = "/req", .shown = &.{} },
        .{ .draft = "/w", .shown = &.{} },
        .{ .draft = "/login", .shown = &.{} },
        .{ .draft = "/x", .shown = &.{} },
        .{ .draft = "/copy ", .shown = &.{ "code", "file" }, .first = "code" },
        .{ .draft = "/copy f", .shown = &.{"file"}, .first = "ile" },
        .{ .draft = "/copy file ", .shown = null },
        .{ .draft = "/rename ", .shown = null },
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

test "/effort lists the efforts the screen's model offers, the one in force marked" {
    const model = "gpt-5.5";
    const list = conversation.suggest("/effort ", .{ .model = model, .effort = .high }).?;
    var expected: usize = 0;
    for (std.enums.values(ReasoningEffort)) |effort| if (model_capability.supportsReasoningEffort(model, effort)) {
        const entry = list.shown()[expected];
        try std.testing.expectEqualStrings(@tagName(effort), entry.word);
        try std.testing.expectEqualStrings(if (effort == .high) "current" else "", entry.description);
        expected += 1;
    };
    try std.testing.expect(expected != 0);
    try std.testing.expectEqual(expected + 1, list.count);
    try std.testing.expectEqualStrings("default", list.shown()[expected].word);
    try std.testing.expectEqualStrings("gh", conversation.suggest("/effort hi", .{ .model = model }).?.completion(0));
    // Before the Session is read, no model: no levels to offer.
    try std.testing.expectEqual(@as(usize, 0), conversation.suggest("/effort ", .{}).?.count);
    try std.testing.expect(conversation.suggest("/effort high ", .{ .model = model }) == null);
}

test "/configure lists its options, then an option's fixed values" {
    const options = conversation.suggest("/configure ", .{}).?;
    try std.testing.expectEqualStrings("--permission-mode ", options.shown()[0].word);
    try std.testing.expectEqualStrings("--permission-mode bypass|ask", options.shown()[0].shown);
    for (options.shown()) |entry| try std.testing.expect(!std.mem.eql(u8, entry.word, "--model ") and !std.mem.eql(u8, entry.word, "--instructions "));
    const narrowed = conversation.suggest("/configure --label x --p", .{}).?;
    try std.testing.expectEqual(@as(usize, 1), narrowed.count);
    try std.testing.expectEqualStrings("ermission-mode ", narrowed.completion(0));
    const modes = conversation.suggest("/configure --permission-mode ", .{}).?;
    try std.testing.expectEqual(@as(usize, 2), modes.count);
    try std.testing.expectEqualStrings("bypass", modes.shown()[0].word);
    try std.testing.expectEqualStrings("ask", modes.shown()[1].word);
    // A shape with a placeholder offers only its fixed words; free text
    // offers nothing.
    const trigger = conversation.suggest("/configure --compaction-trigger ", .{}).?;
    try std.testing.expectEqual(@as(usize, 1), trigger.count);
    try std.testing.expectEqualStrings("default", trigger.shown()[0].word);
    try std.testing.expectEqual(@as(usize, 0), conversation.suggest("/configure --label ", .{}).?.count);
    const efforts = conversation.suggest("/configure --reasoning-effort ", .{ .model = "gpt-5.5" }).?;
    try std.testing.expectEqualStrings("default", efforts.shown()[efforts.count - 1].word);
    // /setup saves a default for any model, so it lists every effort,
    // whatever this Session's model offers.
    const saved = conversation.suggest("/setup --reasoning-effort ", .{ .model = "gpt-5.5" }).?;
    try std.testing.expectEqual(std.enums.values(ReasoningEffort).len + 1, saved.count);
    // Every option of every list is offered, and one with a value is
    // followed by a list of its fixed words, empty for free text.
    inline for (.{ .{ conversation, "/configure ", live_options }, .{ conversation, "/setup ", setup_options }, .{ overview, "/configure ", start_options } }) |case| {
        const listed = case[0].suggest(case[1], .{ .model = "gpt-6-luna" }).?;
        try std.testing.expectEqual(case[2].entries.len, listed.count);
        for (case[2].entries, listed.shown()) |entry, shown| {
            try std.testing.expectEqualStrings(entry.word, shown.word);
            var draft: [64]u8 = undefined;
            const line = try std.fmt.bufPrint(&draft, "{s}{s}", .{ case[1], entry.word });
            const after = case[0].suggest(line, .{ .model = "gpt-6-luna" }).?;
            if (entry.runs) try std.testing.expectEqual(case[2].entries.len, after.count);
        }
    }
    // A highlight past a list that narrowed takes its last row.
    const narrowed_under = Shown.next(.{ .list = trigger, .revision = 1, .highlight = 5 }, 1, trigger).?;
    try std.testing.expectEqual(@as(usize, 0), narrowed_under.highlight);
    try std.testing.expectEqualStrings("default", trigger.completion(narrowed_under.highlight));
    // After a value, options again.
    try std.testing.expectEqualStrings("--tools ", conversation.suggest("/configure --permission-mode ask --t", .{}).?.shown()[0].word);
    // Quoted text is the shell's to read; the list stops.
    try std.testing.expect(conversation.suggest("/configure --label \"a ", .{}) == null);
    try std.testing.expectEqualStrings("--permission-mode ", overview.suggest("/configure ", .{}).?.shown()[0].word);
}

test "a key's list is the draft's own, and counts as drawn when the latest frame drew a list" {
    const c = conversation.suggest("/c", .{}).?;
    const co = conversation.suggest("/co", .{}).?;
    var stored: ?Shown = Shown.next(null, 1, c);
    stored.?.drew(true);
    Shown.drawnNow(&stored, Shown.next(stored, 1, c)).?.move(true);
    try std.testing.expectEqualStrings(c.completion(1), Shown.next(stored, 1, c).?.completion());
    // A key on a draft changed since the frame takes that draft's list,
    // from its first row, still drawn.
    const changed = Shown.drawnNow(&stored, Shown.next(stored, 2, co)).?;
    try std.testing.expectEqual(@as(usize, 0), changed.highlight);
    try std.testing.expectEqualStrings(co.completion(0), changed.completion());
    // Esc closes it for this draft: Tab still completes, nothing else acts.
    changed.close();
    stored = Shown.next(stored, 2, co);
    stored.?.drew(true);
    try std.testing.expectEqual(@as(usize, 0), stored.?.rows());
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 2, co)) == null);
    try std.testing.expectEqualStrings(co.completion(0), Shown.next(stored, 2, co).?.completion());
    // The frame drew no list, so a key on the next draft finds none drawn
    // until a frame draws it.
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 3, c)) == null);
    stored = Shown.next(stored, 3, c);
    stored.?.drew(false);
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 4, c)) == null);
    stored.?.drew(true);
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 4, c)) != null);
    // A draft no list is for leaves the frame's value as it was.
    try std.testing.expect(Shown.drawnNow(&stored, Shown.next(stored, 5, null)) == null);
    try std.testing.expectEqual(@as(u64, 4), stored.?.revision);
}

test "the list order is the names' order and every listed usage fits before the descriptions" {
    inline for (.{ conversation, overview }) |screen| {
        const names = std.enums.values(screen.Name);
        for (names[1..], 0..) |name, index| try std.testing.expect(std.mem.order(u8, @tagName(names[index]), @tagName(name)) == .lt);
    }
    try std.testing.expectEqualStrings("/copy [code|file]", conversation.usage.get(.copy));
    try std.testing.expectEqualStrings("/rename NAME", conversation.usage.get(.rename));
    try std.testing.expectEqualStrings("/effort LEVEL", conversation.usage.get(.effort));
    try std.testing.expectEqualStrings("/configure [OPTIONS]", conversation.usage.get(.configure));
}

test "/copy takes each Copy's name but the answer's, which it copies alone" {
    for (std.enums.values(Copy)) |copy| {
        var text: [16]u8 = undefined;
        const parsed = conversation.parse(try std.fmt.bufPrint(&text, "/copy {s}", .{@tagName(copy)}));
        if (copy == .answer) try std.testing.expectEqual(conversation.Name.copy, parsed.misused) else try std.testing.expectEqualStrings(@tagName(copy), parsed.command.argument);
    }
}

test "both screens' shared commands take the same arguments and say the same things" {
    inline for (.{ "help", "rename", "setup" }) |name| try std.testing.expectEqualStrings(conversation.usage.get(@field(conversation.Name, name)), overview.usage.get(@field(overview.Name, name)));
    for ([_][]const u8{ "/rename", "/rename lane four", "/setup", "/setup --model gpt-5.5", "/help", "/help me" }) |text| {
        errdefer std.debug.print("line={s}\n", .{text});
        try std.testing.expectEqualStrings(@tagName(conversation.parse(text)), @tagName(overview.parse(text)));
    }
    // /setup's list offers the same options on both screens.
    const options = overview.suggest("/setup ", .{}).?;
    try std.testing.expectEqual(setup_options.entries.len, options.count);
    for (setup_options.entries, options.shown()) |entry, shown| try std.testing.expectEqualStrings(entry.word, shown.word);
}

test "an unknown command names itself when it is short printable ASCII" {
    var buffer: [unknown_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("! Unknown command /foo · /help", unknown(&buffer, "/foo bar"));
    try std.testing.expectEqualStrings("! Unknown command · /help", unknown(&buffer, "/\x1b[2J"));
    const long = "/" ++ @as([max_unknown_name]u8, @splat('x'));
    try std.testing.expectEqualStrings("! Unknown command · /help", unknown(&buffer, long));
    try std.testing.expectEqualStrings("! Unknown command " ++ long[0..max_unknown_name] ++ " · /help", unknown(&buffer, long[0..max_unknown_name]));
}

test "a command's short output is the same notice on both screens, and longer output takes a page" {
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
