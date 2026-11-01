//! The conversation's slash commands: one table of each command's name,
//! argument shape and one-line description. The draft's parser, the CLI's
//! command runner, the list typing "/" shows and /help all read it.
const std = @import("std");

/// Declared in the order the list and /help show them.
pub const Name = enum {
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
    recover,
    rename,
    requests,
    result,
    setup,
    status,
    wait,
};

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

pub const Command = struct {
    argument: Argument = .none,
    /// Null keeps the command out of the list and /help: it exists only to
    /// say where the thing it names lives.
    description: ?[]const u8,
};

pub const table = std.enums.EnumArray(Name, Command).init(.{
    .configure = .{ .argument = .{ .optional = "OPTIONS" }, .description = "change this Session's settings" },
    .copy = .{ .argument = .{ .choice = &.{ "code", "file" } }, .description = "copy the last answer; code its last block, file saves it here" },
    .details = .{ .description = "saved tool output" },
    .discard = .{ .description = "release rejected input, retaining the draft" },
    .effort = .{ .argument = .{ .optional = "LEVEL" }, .description = "list this model's efforts, or switch" },
    .exit = .{ .description = "detach; Host work continues, unsent draft is lost" },
    .help = .{ .description = "keys and commands" },
    .history = .{ .description = "older conversation" },
    .@"inspect-action" = .{ .description = "exact one-shot diagnostics" },
    .login = .{ .description = null },
    .recover = .{ .argument = .{ .required = "KEY" }, .description = "the original request" },
    .rename = .{ .argument = .{ .required = "NAME" }, .description = "name this Session" },
    .requests = .{ .description = "recovery handles" },
    .result = .{ .argument = .{ .required = "KEY" }, .description = "a saved answer" },
    .setup = .{ .argument = .{ .optional = "OPTIONS" }, .description = "future defaults" },
    .status = .{ .description = "settings and work" },
    .wait = .{ .description = null },
});

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
    const argument = std.mem.trim(u8, text[end..], " ");
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
        if (unique and table.get(first).argument != .none) return named.get(first)[1 + self.prefix.len ..];
        return common[self.prefix.len..];
    }
};

/// The editor's Tab: null leaves a draft that is no command word its tab.
pub fn complete(draft: []const u8) ?[]const u8 {
    return (Matches.of(draft) orelse return null).completion();
}

const names = std.enums.values(Name);

/// `/name ` for each command, so a completion borrows static bytes.
const named = blk: {
    var texts: std.enums.EnumArray(Name, []const u8) = undefined;
    for (names) |name| texts.set(name, "/" ++ @tagName(name) ++ " ");
    break :blk texts;
};

test "a command admits exactly the arguments its shape names" {
    const cases = .{
        .{ "/status", Parsed{ .command = .{ .name = .status, .argument = "" } } },
        .{ "/status ", Parsed{ .command = .{ .name = .status, .argument = "" } } },
        .{ "/status now", Parsed{ .misused = .status } },
        .{ "/copy", Parsed{ .command = .{ .name = .copy, .argument = "" } } },
        .{ "/copy code", Parsed{ .command = .{ .name = .copy, .argument = "code" } } },
        .{ "/copy file", Parsed{ .command = .{ .name = .copy, .argument = "file" } } },
        .{ "/copy all", Parsed{ .misused = .copy } },
        .{ "/effort", Parsed{ .command = .{ .name = .effort, .argument = "" } } },
        .{ "/effort  high ", Parsed{ .command = .{ .name = .effort, .argument = "high" } } },
        .{ "/rename", Parsed{ .misused = .rename } },
        .{ "/rename  ", Parsed{ .misused = .rename } },
        .{ "/rename lane four", Parsed{ .command = .{ .name = .rename, .argument = "lane four" } } },
        .{ "/result", Parsed{ .misused = .result } },
        .{ "/inspect-action", Parsed{ .command = .{ .name = .@"inspect-action", .argument = "" } } },
        .{ "/configure --label \"a b\"", Parsed{ .command = .{ .name = .configure, .argument = "--label \"a b\"" } } },
        .{ "/configurex", @as(Parsed, .unknown) },
        .{ "/", @as(Parsed, .unknown) },
        .{ "//status", @as(Parsed, .unknown) },
        .{ "/status\tnow", @as(Parsed, .unknown) },
    };
    inline for (cases) |case| {
        const parsed = parse(case[0]);
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
    const Case = struct { draft: []const u8, shown: ?[]const Name, completion: ?[]const u8 };
    const all = [_]Name{ .configure, .copy, .details, .discard, .effort, .exit, .help, .history, .@"inspect-action", .recover, .rename, .requests, .result, .setup, .status };
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
        if (complete(case.draft)) |added| try std.testing.expectEqualStrings(case.completion.?, added) else try std.testing.expect(case.completion == null);
        var matches = Matches.of(case.draft) orelse {
            try std.testing.expect(case.shown == null);
            continue;
        };
        try std.testing.expectEqual(case.shown.?.len, matches.count);
        for (case.shown.?) |expected| try std.testing.expectEqual(expected, matches.next().?);
        try std.testing.expectEqual(@as(?Name, null), matches.next());
    }
}

test "the list order is the names' order and every listed usage fits before the descriptions" {
    for (names[1..], 0..) |name, index| try std.testing.expect(std.mem.order(u8, @tagName(names[index]), @tagName(name)) == .lt);
    try std.testing.expectEqualStrings("/copy [code|file]", usage.get(.copy));
    try std.testing.expectEqualStrings("/rename NAME", usage.get(.rename));
    try std.testing.expectEqualStrings("/effort [LEVEL]", usage.get(.effort));
}
