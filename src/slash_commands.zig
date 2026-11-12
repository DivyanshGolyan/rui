//! Each screen's slash commands: one table per screen of each command's
//! name and argument shape. The screen's parser, the
//! list typing "/" shows, and Tab all read it.
const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const session_settings = @import("session_settings.zig");
const cli_args = @import("cli_args.zig");
const model_capability = @import("model_capability.zig");
const TerminalText = @import("TerminalText.zig");
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

/// A word an argument may be.
pub const Choice = struct { word: []const u8 };

pub const Options = struct {
    grammar: cli_args.Definition,
    /// The options the list offers, in its order: each spelled with a space
    /// after it, since another word follows.
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
            entry.* = .{ .word = "--" ++ option ++ " ", .shown = "--" ++ option, .runs = argument == null };
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
    /// A short name for a long choice list in usage; completion still
    /// offers each admitted word.
    choice_name: ?[]const u8 = null,
    argument: Argument = .none,
    /// Whether typing `/` lists the command.
    listed: bool = true,
};

/// /copy's words: every `Copy` but the answer, which /copy alone copies.
const copy_words = &[_]Choice{
    .{ .word = "code" },
    .{ .word = "file" },
};

comptime {
    for (@typeInfo(Copy).@"enum".field_names[1..], copy_words) |field, choice| std.debug.assert(std.mem.eql(u8, field, choice.word));
}

/// Completion has its own presentation order, independent of protocol and
/// help order. Membership and spellings still come from the setting table.
fn settingNames(comptime on_start: bool) []const []const u8 {
    @setEvalBranchQuota(20_000);
    var names: []const []const u8 = &.{};
    for (0..session_settings.entries.len) |rank| {
        for (session_settings.entries) |entry| {
            const cli = entry.cli orelse continue;
            if (std.mem.eql(u8, entry.field, "instructions")) continue;
            if (on_start) {
                if (!cli.on_start) continue;
            } else if (cli.group == .binding) continue;
            if (completionRank(entry.field) != rank) continue;
            names = names ++ .{cli.name};
            if (std.mem.eql(u8, entry.field, "output_schema")) names = names ++ .{"text-output"};
        }
    }
    return names;
}

fn completionRank(comptime field: []const u8) usize {
    // Presentation only: changing this order must not change CLI membership.
    const order = .{ "permission_mode", "tools", "loaded_tools", "reasoning_effort", "label", "workspace", "compaction_trigger", "output_reservation", "output_schema", "model", "provider", "instructions" };
    inline for (order, 0..) |name, rank| if (std.mem.eql(u8, field, name)) return rank;
    @compileError("choose a completion presentation order for " ++ field);
}

/// Future defaults, as /setup saves them; /setup alone shows them.
const setup_options: Options = .of(cli_args.live_setup, &.{ "model", "provider", "reasoning-effort", "notifications", "clear-model", "store" }, true, false);

/// The conversation's commands, declared in list order.
const ConversationName = enum {
    archive,
    copy,
    discard,
    effort,
    recover,
    @"reload-skills",
    rename,
    requests,
    result,
    setup,
    unarchive,
};

/// A conversation's commands.
pub const conversation = Commands(ConversationName, .{
    .archive = .{},
    .copy = .{ .argument = .{ .choice = copy_words } },
    .discard = .{ .listed = false },
    .effort = .{ .argument = .effort },
    .recover = .{ .argument = .{ .required = "KEY" }, .listed = false },
    .@"reload-skills" = .{},
    .rename = .{ .argument = .{ .required = "NAME" } },
    .requests = .{ .listed = false },
    .result = .{ .argument = .{ .required = "KEY" }, .listed = false },
    .setup = .{ .argument = .{ .options = setup_options } },
    .unarchive = .{},
});

/// What the overview's /configure holds for the next Session: a fresh
/// Session's settings.
const start_options: Options = .of(cli_args.live_configure, settingNames(true), false, true);

/// The overview's commands. /rename and /setup run as a conversation runs
/// them; /rename names the selected Session.
const session_views = &[_]Choice{
    .{ .word = "unarchived" },
    .{ .word = "archived" },
    .{ .word = "all" },
};

pub const overview = Commands(enum { archive, configure, rename, sessions, setup, unarchive }, .{
    .archive = .{},
    .configure = .{ .argument = .{ .options = start_options } },
    .rename = .{ .argument = conversation.table.get(.rename).argument },
    .sessions = .{ .choice_name = "VIEW", .argument = .{ .choice = session_views } },
    .setup = conversation.table.get(.setup),
    .unarchive = .{},
});

/// What both screens say for a line that names no command: the name typed,
/// when it is short printable ASCII, and where the commands are.
pub fn unknown(buffer: *[unknown_bytes]u8, text: []const u8) []const u8 {
    const name = text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
    var shown = name.len <= max_unknown_name;
    for (name) |byte| shown = shown and byte > ' ' and byte < 0x7f;
    return std.fmt.bufPrint(buffer, "! Unknown command{s}{s}", .{ if (shown) " " else "", if (shown) name else "" }) catch unreachable;
}

const max_unknown_name = 32;
pub const unknown_bytes = "! Unknown command ".len + max_unknown_name;

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
                        if (table.get(name).choice_name) |shape| break :choice text ++ " [" ++ shape ++ "]";
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

        /// Align fixed choice words after the widest listed command name.
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
                    if (!command.listed or !std.mem.startsWith(u8, @tagName(name), list.typed)) continue;
                    list.add(.{ .word = spaced.get(name)[1 .. spaced.get(name).len - @intFromBool(command.argument == .none)], .shown = spaced.get(name)[0 .. spaced.get(name).len - 1], .description = choices_text.get(name), .runs = !requires(command.argument) });
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
                    for (choices) |choice| list.offer(choice.word, choice.word);
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
/// row shows, and optional quiet metadata for choices, skills or requests.
pub const Entry = struct {
    word: []const u8,
    shown: []const u8,
    description: []const u8 = "",
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

    fn offer(self: *List, word: []const u8, text: []const u8) void {
        if (std.mem.startsWith(u8, word, self.typed)) self.add(.{ .word = word, .shown = text });
    }

    /// The efforts the context's model offers, and
    /// `default`, which clears the choice.
    fn offerEfforts(self: *List, context: Context) void {
        const model = context.model orelse return;
        for (std.enums.values(ReasoningEffort)) |effort| if (model_capability.supportsReasoningEffort(model_catalog.shipped, model, effort)) {
            self.offer(@tagName(effort), @tagName(effort));
        };
        self.offer("default", "default");
    }

    /// The fixed words an option's value may be: the lowercase
    /// alternatives its shape names, so `TOKENS|default` offers `default`.
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
    /// What the rows came from, when not the draft alone (see `nextOf`).
    source: u64 = 0,

    /// The list, `list`, for the draft at `revision`, after `previous`:
    /// while the draft is the one `previous` was built for, it keeps its
    /// highlight and stays closed once Esc closed it; any edit starts a list
    /// at its first row. It counts as drawn while the latest frame drew a
    /// list, until a frame records its own. Null when nothing matches.
    pub fn next(previous: ?Shown, revision: u64, list: ?List) ?Shown {
        return nextOf(previous, revision, 0, list);
    }

    /// As `next`, for a list whose rows come from elsewhere than the
    /// draft, named by `source`: rows from another source are a new list, at its first row
    /// and not drawn until a frame draws it, so no key acts on a row the
    /// person did not see.
    pub fn nextOf(previous: ?Shown, revision: u64, source: u64, list: ?List) ?Shown {
        const built = list orelse return null;
        if (built.count == 0) return null;
        const fresh: Shown = .{ .list = built, .revision = revision, .source = source };
        const kept = previous orelse return fresh;
        if (kept.source != source) return fresh;
        if (kept.revision != revision) return .{ .list = built, .revision = revision, .source = source, .seen = if (kept.seen == .drawn) .drawn else .hidden };
        return .{ .list = built, .revision = revision, .source = source, .highlight = @min(kept.highlight, built.count - 1), .seen = kept.seen };
    }

    /// The list Enter, Esc and the arrows act on: `stored`, the latest
    /// frame's, becomes `current`, its `next` for the draft as it is now,
    /// when the latest frame drew a list.
    pub fn drawnNow(stored: *?Shown, current: ?Shown) ?*Shown {
        stored.* = current orelse return null;
        const kept = &stored.*.?;
        return if (kept.seen == .drawn) kept else null;
    }

    /// A pointer press on a row a frame drew: the row's index and the
    /// identity of the list that frame drew it in, captured at draw time.
    pub const Pick = struct { index: usize, revision: u64, source: u64 };

    /// The pick of the row at `index` in this list, as a frame draws it.
    pub fn pick(self: *const Shown, index: usize) Pick {
        return .{ .index = index, .revision = self.revision, .source = self.source };
    }

    /// The list a pointer press acts on: `drawnNow`'s, with the pressed row
    /// highlighted as the arrows would leave it, only while it is still the
    /// list `pressed` names (the same draft revision and row source the
    /// frame drew). Null, changing nothing, for an edited draft, replaced
    /// rows, a closed or undrawn list, or a row the list no longer has.
    pub fn pickedNow(stored: *?Shown, current: ?Shown, pressed: Pick) ?*Shown {
        const now = current orelse return null;
        if (now.revision != pressed.revision or now.source != pressed.source) return null;
        const shown = drawnNow(stored, now) orelse return null;
        if (pressed.index >= shown.list.count) return null;
        shown.highlight = pressed.index;
        return shown;
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

const recover_command = "/" ++ @tagName(ConversationName.recover);
/// The /recover line's room: the conversation's own key is a UUID.
pub const recover_line_bytes = recover_command.len + " ".len + 36;

/// The row a conversation's /requests page shows for its own unconfirmed
/// original: the `/recover KEY` line that retries it, as Ctrl-R does. The
/// caller decides that the original can be retried now, and owns `buffer`.
pub fn recoverEntry(buffer: *[recover_line_bytes]u8, key: *const [36]u8) Entry {
    const line = std.fmt.bufPrint(buffer, recover_command ++ " {s}", .{key}) catch unreachable;
    return .{ .word = line, .shown = line, .description = "retry this unconfirmed original, as Ctrl-R does" };
}

/// A conversation's /requests rows for its saved Messages, newest saved
/// first: each the `/result KEY` line that reads its answer, so a pick does
/// what typing it does. `max_key_bytes` is the Store's bound on a key.
pub fn Requests(comptime max_key_bytes: usize) type {
    return struct {
        rows: [capacity]Row = undefined,
        count: usize = 0,

        const Self = @This();
        /// The list's rows, less one for the original's /recover row.
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
            /// When the request was saved; newer rows come first.
            saved: std.Io.Timestamp,

            fn key(self: *const Row) []const u8 {
                return self.line[result_command.len + 1 .. self.line_length];
            }
        };

        /// A saved Message, saved at `saved` and shown at `clock`, its local
        /// `HH:MM`; the shell passes null when the C library cannot give
        /// one, and the row then says no time. Only the newest fit.
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

        /// A key the parser reads back from `line` as its one word, and
        /// one the list can draw: no control or direction character.
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

        /// Newest first; the key orders saves of the same moment.
        fn newer(row: *const Row, than: *const Row) bool {
            if (row.saved.nanoseconds != than.saved.nanoseconds) return row.saved.nanoseconds > than.saved.nanoseconds;
            return std.mem.order(u8, row.key(), than.key()) == .lt;
        }

        /// The rows as the list an empty draft shows, after `lead`, the
        /// original's /recover row when it can be retried now; a saved
        /// Message that is that original has only that row. Null when
        /// there is no row.
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
    // More Messages than fit, offered out of order, and the original among them.
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
    // The original, the newest saved, shows only as its /recover row.
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
        // Enter runs the whole line, which parses back to the key.
        try std.testing.expectEqualStrings(entry.word, shown.enter(index).rest);
        try std.testing.expect(shown.enter(index).runs);
        try std.testing.expectEqualStrings(newest, conversation.parse(entry.word).command.argument);
    }
    // Without the /recover row, the original is a saved Message like any
    // other, and the newest.
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
    // The same draft over other rows: nothing to act on, and the first row
    // once a frame draws them.
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

test "the list names the listed commands a command word starts, and Tab puts the highlighted one in" {
    const Case = struct { draft: []const u8, shown: ?[]const []const u8, first: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .draft = "/", .shown = &.{ "archive", "copy ", "effort ", "reload-skills", "rename ", "setup ", "unarchive" } },
        .{ .draft = "/c", .shown = &.{"copy "}, .first = "opy " },
        .{ .draft = "/cop", .shown = &.{"copy "}, .first = "y " },
        .{ .draft = "/st", .shown = &.{} },
        .{ .draft = "/re", .shown = &.{ "reload-skills", "rename " } },
        .{ .draft = "/rel", .shown = &.{"reload-skills"}, .first = "oad-skills" },
        .{ .draft = "/s", .shown = &.{"setup "}, .first = "etup " },
        // Recovery commands work, but the list leaves them out.
        .{ .draft = "/req", .shown = &.{} },
        .{ .draft = "/w", .shown = &.{} },
        .{ .draft = "/login", .shown = &.{} },
        .{ .draft = "/x", .shown = &.{} },
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

test "skills completion runs reload immediately" {
    const reload = conversation.suggest("/reload", .{}).?.shown()[0];
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
    // Before the Session is read, no model: no levels to offer.
    try std.testing.expectEqual(@as(usize, 0), conversation.suggest("/effort ", .{}).?.count);
    try std.testing.expect(conversation.suggest("/effort high ", .{ .model = model }) == null);
}

test "/configure lists its options, then an option's fixed values" {
    const options = overview.suggest("/configure ", .{}).?;
    try std.testing.expectEqualStrings("--permission-mode ", options.shown()[0].word);
    try std.testing.expectEqualStrings("--permission-mode", options.shown()[0].shown);
    for (options.shown()) |entry| try std.testing.expect(!std.mem.eql(u8, entry.word, "--instructions "));
    const narrowed = overview.suggest("/configure --label x --p", .{}).?;
    try std.testing.expectEqual(@as(usize, 2), narrowed.count);
    try std.testing.expectEqualStrings("ermission-mode ", narrowed.completion(0));
    const modes = overview.suggest("/configure --permission-mode ", .{}).?;
    try std.testing.expectEqual(@as(usize, 2), modes.count);
    try std.testing.expectEqualStrings("ask", modes.shown()[0].word);
    try std.testing.expectEqualStrings("bypass", modes.shown()[1].word);
    // A shape with a placeholder offers only its fixed words; free text
    // offers nothing.
    const trigger = overview.suggest("/configure --compaction-trigger ", .{}).?;
    try std.testing.expectEqual(@as(usize, 1), trigger.count);
    try std.testing.expectEqualStrings("default", trigger.shown()[0].word);
    try std.testing.expectEqual(@as(usize, 0), overview.suggest("/configure --label ", .{}).?.count);
    const efforts = overview.suggest("/configure --reasoning-effort ", .{ .model = "gpt-5.5" }).?;
    try std.testing.expectEqualStrings("default", efforts.shown()[efforts.count - 1].word);
    // /setup saves a default for any model, so it lists every effort,
    // whatever this Session's model offers.
    const saved = conversation.suggest("/setup --reasoning-effort ", .{ .model = "gpt-5.5" }).?;
    try std.testing.expectEqual(std.enums.values(ReasoningEffort).len + 1, saved.count);
    // Every option of every list is offered, and one with a value is
    // followed by a list of its fixed words, empty for free text.
    inline for (.{ .{ conversation, "/setup ", setup_options }, .{ overview, "/configure ", start_options } }) |case| {
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
    try std.testing.expectEqualStrings("--tools ", overview.suggest("/configure --permission-mode ask --t", .{}).?.shown()[0].word);
    // Quoted text is the shell's to read; the list stops.
    try std.testing.expect(overview.suggest("/configure --label \"a ", .{}) == null);
    try std.testing.expectEqualStrings("--permission-mode ", overview.suggest("/configure ", .{}).?.shown()[0].word);
}

test "a key's list is the draft's own, and counts as drawn when the latest frame drew a list" {
    const c = conversation.suggest("/re", .{}).?;
    const co = conversation.suggest("/rel", .{}).?;
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

test "the list order is the names' order and usage retains argument shapes" {
    inline for (.{ conversation, overview }) |screen| {
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

test "both screens' shared commands take the same arguments and say the same things" {
    inline for (.{ "rename", "setup" }) |name| try std.testing.expectEqualStrings(conversation.usage.get(@field(conversation.Name, name)), overview.usage.get(@field(overview.Name, name)));
    for ([_][]const u8{ "/rename", "/rename lane four", "/setup", "/setup --model gpt-5.5" }) |text| {
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
    try std.testing.expectEqualStrings("! Unknown command /foo", unknown(&buffer, "/foo bar"));
    try std.testing.expectEqualStrings("! Unknown command", unknown(&buffer, "/\x1b[2J"));
    const long = "/" ++ @as([max_unknown_name]u8, @splat('x'));
    try std.testing.expectEqualStrings("! Unknown command", unknown(&buffer, long));
    try std.testing.expectEqualStrings("! Unknown command " ++ long[0..max_unknown_name] ++ "", unknown(&buffer, long[0..max_unknown_name]));
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

test "deleted app commands are unknown on both screens and absent from completion" {
    inline for (.{ conversation, overview }) |screen| {
        inline for (.{ "help", "upgrade", "login", "wait", "inspect-action", "exit" }) |name| {
            try std.testing.expect(screen.parse("/" ++ name) == .unknown);
            try std.testing.expect(screen.parse("/" ++ name ++ " now") == .unknown);
            try std.testing.expectEqual(@as(usize, 0), screen.suggest("/" ++ name, .{}).?.count);
        }
    }
}

test "archive commands and server archive view choices parse on their owning screens" {
    for ([_][]const u8{ "/archive", "/unarchive" }) |line| {
        try std.testing.expect(conversation.parse(line) == .command);
        try std.testing.expect(overview.parse(line) == .command);
        const extra = try std.fmt.allocPrint(std.testing.allocator, "{s} extra", .{line});
        defer std.testing.allocator.free(extra);
        try std.testing.expect(conversation.parse(extra) == .misused);
        try std.testing.expect(overview.parse(extra) == .misused);
    }
    for ([_][]const u8{ "unarchived", "archived", "all" }) |view| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "/sessions {s}", .{view});
        defer std.testing.allocator.free(line);
        const parsed = overview.parse(line);
        try std.testing.expectEqual(.sessions, parsed.command.name);
        try std.testing.expectEqualStrings(view, parsed.command.argument);
    }
    try std.testing.expect(overview.parse("/sessions") == .command);
    try std.testing.expect(overview.parse("/sessions active") == .misused);
    try std.testing.expect(overview.parse("/undo") == .unknown);
    try std.testing.expect(conversation.parse("/sessions archived") == .unknown);
}

test "archive commands retain separate local command identities" {
    inline for (.{ conversation, overview }) |screen| {
        inline for (.{ "archive", "unarchive" }) |name| {
            const parsed = screen.parse("/" ++ name);
            try std.testing.expect(parsed == .command);
            try std.testing.expectEqualStrings(name, @tagName(parsed.command.name));
            try std.testing.expectEqualStrings("", parsed.command.argument);
            try std.testing.expect(screen.parse("/" ++ name ++ " other") == .misused);
            const list = screen.suggest("/" ++ name, .{}).?;
            try std.testing.expectEqual(@as(usize, 1), list.count);
            try std.testing.expectEqualStrings(name, list.shown()[0].word);
            try std.testing.expect(list.enter(0).runs);
        }
    }
}

test "overview start settings slash options retain membership and order" {
    inline for (.{
        .{ start_options, &[_][]const u8{ "--permission-mode ", "--tools ", "--loaded-tools ", "--reasoning-effort ", "--label ", "--workspace ", "--compaction-trigger ", "--output-reservation ", "--model ", "--provider " } },
    }) |case| {
        try std.testing.expectEqual(case[1].len, case[0].entries.len);
        for (case[0].entries, 0..) |entry, index| try std.testing.expectEqualStrings(case[1][index], entry.word);
    }
}

test "older conversation is feed navigation, not a slash command" {
    try std.testing.expect(conversation.parse("/history") == .unknown);
    try std.testing.expectEqual(@as(usize, 0), conversation.suggest("/history", .{}).?.count);
    const list = conversation.suggest("/h", .{}).?;
    try std.testing.expectEqual(@as(usize, 0), list.count);
    try std.testing.expect(conversation.parse("/details") == .unknown);
}

test "chat info replaces conversation settings commands and overview model has no slash path" {
    for ([_][]const u8{ "/status", "/status now", "/configure", "/configure --label chat", "/model", "/model gpt-5.5" }) |line| {
        try std.testing.expect(conversation.parse(line) == .unknown);
        if (conversation.suggest(line, .{})) |list| try std.testing.expectEqual(@as(usize, 0), list.count);
    }
    for ([_][]const u8{ "/model", "/model gpt-5.5" }) |line| {
        try std.testing.expect(overview.parse(line) == .unknown);
        if (overview.suggest(line, .{})) |list| try std.testing.expectEqual(@as(usize, 0), list.count);
    }
    try std.testing.expect(overview.parse("/configure --label next") == .command);
}

test "command choices and options are names only and recovery stays unlisted" {
    try std.testing.expect(!@hasField(Command, "description"));
    try std.testing.expect(!@hasField(Choice, "description"));
    try std.testing.expect(!conversation.table.get(.discard).listed);
    try std.testing.expect(!conversation.table.get(.recover).listed);
    inline for (.{ .{ conversation, "/setup " }, .{ overview, "/setup " }, .{ overview, "/configure " } }) |case| {
        const options = case[0].suggest(case[1], .{}).?;
        for (options.shown()) |entry| {
            try std.testing.expectEqualStrings(std.mem.trimEnd(u8, entry.word, " "), entry.shown);
            try std.testing.expectEqualStrings("", entry.description);
        }
    }
    inline for (.{ .{ conversation, "/copy " }, .{ overview, "/sessions " } }) |case| {
        const choices = case[0].suggest(case[1], .{}).?;
        for (choices.shown()) |entry| {
            try std.testing.expectEqualStrings(entry.word, entry.shown);
            try std.testing.expectEqualStrings("", entry.description);
        }
    }
}

test "overview configure preserves quoted and escaped argument tails" {
    const cases = .{
        .{ "/configure --label \"a b\"", "--label \"a b\"" },
        .{ "/configure --label lane\\  ", "--label lane\\ " },
        .{ "/configure --label lane\\\\  ", "--label lane\\\\" },
    };
    inline for (cases) |case| {
        const parsed = overview.parse(case[0]);
        try std.testing.expectEqual(.configure, parsed.command.name);
        try std.testing.expectEqualStrings(case[1], parsed.command.argument);
    }
}
