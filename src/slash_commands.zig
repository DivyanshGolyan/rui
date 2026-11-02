//! Each screen's slash commands: one table per screen of each command's
//! name, argument shape and one-line description. The screen's parser, the
//! list typing "/" shows, Tab and /help all read it.
const std = @import("std");

/// What may follow the name, after one space.
pub const Argument = union(enum) {
    none,
    /// Anything, or nothing; the word names it in the list.
    optional: []const u8,
    /// Some text; the word names it in the list.
    required: []const u8,
    /// Nothing, or exactly one of these words.
    choice: []const []const u8,
};

/// What /copy copies: the last answer, or what its one word names.
pub const Copy = enum { answer, code, file };

pub const Command = struct {
    argument: Argument = .none,
    /// Null keeps the command out of the list and /help: it exists only to
    /// say where the thing it names lives.
    description: ?[]const u8,
};

/// /copy's words: every `Copy` but the answer, which /copy alone copies.
const copy_words = blk: {
    const fields = @typeInfo(Copy).@"enum".field_names;
    var words: [fields.len - 1][]const u8 = undefined;
    for (&words, fields[1..]) |*word, field| word.* = field;
    const final = words;
    break :blk &final;
};

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
    .configure = .{ .argument = .{ .optional = "OPTIONS" }, .description = "change this Session's settings" },
    .copy = .{ .argument = .{ .choice = copy_words }, .description = "copy the last answer; code its last block, file saves it here" },
    .details = .{ .description = "saved tool output" },
    .discard = .{ .description = "release rejected input, retaining the draft" },
    .effort = .{ .argument = .{ .optional = "LEVEL" }, .description = "list this model's efforts, or switch" },
    .exit = .{ .description = "detach; Host work continues, unsent draft is lost" },
    .help = .{ .description = "keys and commands" },
    .history = .{ .description = "older conversation" },
    .@"inspect-action" = .{ .description = "exact one-shot diagnostics" },
    .login = .{ .description = null },
    .model = .{ .description = "this Session's model and sign-in" },
    .recover = .{ .argument = .{ .required = "KEY" }, .description = "the original request" },
    .rename = .{ .argument = .{ .required = "NAME" }, .description = "name this Session" },
    .requests = .{ .description = "recovery handles" },
    .result = .{ .argument = .{ .required = "KEY" }, .description = "a saved answer" },
    .setup = .{ .argument = .{ .optional = "OPTIONS" }, .description = "future defaults" },
    .status = .{ .description = "settings and work" },
    .wait = .{ .description = null },
});

/// The overview's commands.
pub const overview = Commands(enum { configure, exit, model }, .{
    .configure = .{ .argument = .{ .optional = "OPTIONS" }, .description = "hold settings for the next Session" },
    .exit = .{ .description = "leave; Host work continues" },
    .model = .{ .description = "choose the model new Sessions use" },
});

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
                    .choice => |words| choice: {
                        var joined: []const u8 = text ++ " [";
                        for (words, 0..) |word, index| joined = joined ++ (if (index == 0) "" else "|") ++ word;
                        break :choice joined ++ "]";
                    },
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
                .required => argument.len != 0,
                .choice => |words| argument.len == 0 or for (words) |word| {
                    if (std.mem.eql(u8, word, argument)) break true;
                } else false,
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

        /// The listed commands a command word starts, in list order.
        pub const Matches = struct {
            prefix: []const u8,
            /// How many commands match, counted once.
            count: usize,
            next_index: usize = 0,

            /// A command word is a one-line draft that starts with one `/` and holds
            /// no space yet: the list shows for it, and Tab completes it. Any other
            /// draft is null.
            pub fn of(draft: []const u8) ?Matches {
                if (draft.len == 0 or draft[0] != '/' or std.mem.startsWith(u8, draft, "//")) return null;
                if (std.mem.indexOfAny(u8, draft, " \t\n") != null) return null;
                var counting: Matches = .{ .prefix = draft[1..], .count = 0 };
                while (counting.next() != null) counting.count += 1;
                return .{ .prefix = counting.prefix, .count = counting.count };
            }

            pub fn next(self: *Matches) ?Name {
                while (self.next_index < names.len) {
                    const name = names[self.next_index];
                    self.next_index += 1;
                    if (table.get(name).description != null and std.mem.startsWith(u8, @tagName(name), self.prefix)) return name;
                }
                return null;
            }

            /// What Tab adds: the rest of the names' common start, and a space
            /// after a whole name that takes an argument.
            pub fn completion(self: Matches) []const u8 {
                var rest = self;
                const first = rest.next() orelse return "";
                var common: []const u8 = @tagName(first);
                var unique = true;
                while (rest.next()) |name| {
                    unique = false;
                    common = common[0 .. std.mem.indexOfDiff(u8, common, @tagName(name)) orelse common.len];
                }
                if (unique and table.get(first).argument != .none) return spaced.get(first)[1 + self.prefix.len ..];
                return common[self.prefix.len..];
            }
        };

        /// The editor's Tab: null leaves a draft that is no command word its tab.
        pub fn complete(draft: []const u8) ?[]const u8 {
            return (Matches.of(draft) orelse return null).completion();
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

test "a command admits exactly the arguments its shape names" {
    const cases = .{
        .{ "/status", conversation.Parsed{ .command = .{ .name = .status, .argument = "" } } },
        .{ "/status ", conversation.Parsed{ .command = .{ .name = .status, .argument = "" } } },
        .{ "/status now", conversation.Parsed{ .misused = .status } },
        .{ "/copy", conversation.Parsed{ .command = .{ .name = .copy, .argument = "" } } },
        .{ "/copy code", conversation.Parsed{ .command = .{ .name = .copy, .argument = "code" } } },
        .{ "/copy file", conversation.Parsed{ .command = .{ .name = .copy, .argument = "file" } } },
        .{ "/copy all", conversation.Parsed{ .misused = .copy } },
        .{ "/effort", conversation.Parsed{ .command = .{ .name = .effort, .argument = "" } } },
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

test "the list names the listed commands a command word starts, and Tab completes their common start" {
    const Case = struct { draft: []const u8, shown: ?[]const conversation.Name, completion: ?[]const u8 };
    const all = [_]conversation.Name{ .configure, .copy, .details, .discard, .effort, .exit, .help, .history, .@"inspect-action", .model, .recover, .rename, .requests, .result, .setup, .status };
    const cases = [_]Case{
        .{ .draft = "/", .shown = &all, .completion = "" },
        .{ .draft = "/c", .shown = &.{ .configure, .copy }, .completion = "o" },
        .{ .draft = "/co", .shown = &.{ .configure, .copy }, .completion = "" },
        .{ .draft = "/cop", .shown = &.{.copy}, .completion = "y " },
        .{ .draft = "/copy", .shown = &.{.copy}, .completion = " " },
        .{ .draft = "/st", .shown = &.{.status}, .completion = "atus" },
        .{ .draft = "/re", .shown = &.{ .recover, .rename, .requests, .result }, .completion = "" },
        .{ .draft = "/ren", .shown = &.{.rename}, .completion = "ame " },
        .{ .draft = "/e", .shown = &.{ .effort, .exit }, .completion = "" },
        .{ .draft = "/w", .shown = &.{}, .completion = "" },
        .{ .draft = "/login", .shown = &.{}, .completion = "" },
        .{ .draft = "/x", .shown = &.{}, .completion = "" },
        .{ .draft = "/copy ", .shown = null, .completion = null },
        .{ .draft = "/c\n", .shown = null, .completion = null },
        .{ .draft = "/c\t", .shown = null, .completion = null },
        .{ .draft = "c", .shown = null, .completion = null },
        .{ .draft = "", .shown = null, .completion = null },
        .{ .draft = "//", .shown = null, .completion = null },
    };
    for (cases) |case| {
        errdefer std.debug.print("draft={s}\n", .{case.draft});
        if (conversation.complete(case.draft)) |added| try std.testing.expectEqualStrings(case.completion.?, added) else try std.testing.expect(case.completion == null);
        var matches = conversation.Matches.of(case.draft) orelse {
            try std.testing.expect(case.shown == null);
            continue;
        };
        try std.testing.expectEqual(case.shown.?.len, matches.count);
        for (case.shown.?) |expected| try std.testing.expectEqual(expected, matches.next().?);
        try std.testing.expectEqual(@as(?conversation.Name, null), matches.next());
    }
}

test "the list order is the names' order and every listed usage fits before the descriptions" {
    for (std.enums.values(conversation.Name)[1..], 0..) |name, index| try std.testing.expect(std.mem.order(u8, @tagName(std.enums.values(conversation.Name)[index]), @tagName(name)) == .lt);
    try std.testing.expectEqualStrings("/copy [code|file]", conversation.usage.get(.copy));
    try std.testing.expectEqualStrings("/rename NAME", conversation.usage.get(.rename));
    try std.testing.expectEqualStrings("/effort [LEVEL]", conversation.usage.get(.effort));
}

test "/copy takes each Copy's name but the answer's, which it copies alone" {
    for (std.enums.values(Copy)) |copy| {
        var text: [16]u8 = undefined;
        const parsed = conversation.parse(try std.fmt.bufPrint(&text, "/copy {s}", .{@tagName(copy)}));
        if (copy == .answer) try std.testing.expectEqual(conversation.Name.copy, parsed.misused) else try std.testing.expectEqualStrings(@tagName(copy), parsed.command.argument);
    }
}
