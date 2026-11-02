//! The settings part of the /status page: one row per setting, in page
//! order, each one logical line, and the draft that changes it. Rows of
//! the Session come before the defaults new Sessions start from.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const model_capability = @import("model_capability.zig");
const product_defaults = @import("product_defaults.zig");
const Provider = @import("provider_name.zig").Provider;
const TerminalText = @import("TerminalText.zig");
const shortPath = @import("overview_view.zig").shortPath;
const ReasoningEffort = model_capability.ReasoningEffort;
const WorkKind = @import("session_work.zig").Kind;

pub const Setting = enum {
    effort,
    permissions,
    tools,
    name,
    folder,
    compact_at,
    headroom,
    model,
    instructions,
    default_model,
    default_effort,
    notifications,
    store,
};

pub const Group = enum { session, defaults };

/// How a row changes: not from this page, by picking one of the command's
/// fixed choices, or by editing the current value after the command.
pub const Change = union(enum) {
    fixed,
    choice: []const u8,
    typed: []const u8,
};

pub const Row = struct { group: Group, label: []const u8, change: Change };

pub const rows = std.enums.EnumArray(Setting, Row).init(.{
    .effort = .{ .group = .session, .label = "Effort", .change = .{ .choice = "/configure --reasoning-effort " } },
    .permissions = .{ .group = .session, .label = "Permissions", .change = .{ .choice = "/configure --permission-mode " } },
    .tools = .{ .group = .session, .label = "Tools", .change = .{ .choice = "/configure --tools " } },
    .name = .{ .group = .session, .label = "Name", .change = .{ .typed = "/configure --label " } },
    .folder = .{ .group = .session, .label = "Folder", .change = .{ .typed = "/configure --workspace " } },
    .compact_at = .{ .group = .session, .label = "Compact at", .change = .{ .typed = "/configure --compaction-trigger " } },
    .headroom = .{ .group = .session, .label = "Headroom", .change = .{ .typed = "/configure --output-reservation " } },
    .model = .{ .group = .session, .label = "Model", .change = .fixed },
    .instructions = .{ .group = .session, .label = "Instructions", .change = .fixed },
    // A saved model needs a saved provider, so the draft names both.
    .default_model = .{ .group = .defaults, .label = "Model", .change = .{ .typed = "/setup --provider " } },
    .default_effort = .{ .group = .defaults, .label = "Effort", .change = .{ .choice = "/setup --reasoning-effort " } },
    .notifications = .{ .group = .defaults, .label = "Notifications", .change = .{ .choice = "/setup --notifications " } },
    .store = .{ .group = .defaults, .label = "Store", .change = .{ .typed = "/setup --store " } },
});

const headings = std.enums.EnumArray(Group, []const u8).init(.{ .session = "This Session", .defaults = "New Sessions" });

/// Cells from a row's start to its value.
const value_column = 19;
const indent = "   ";

comptime {
    for (std.enums.values(Setting)[1..], 1..) |setting, index| {
        // Each group's rows are contiguous, so it has one heading.
        std.debug.assert(@backingInt(rows.get(setting).group) >= @backingInt(rows.get(std.enums.values(Setting)[index - 1]).group));
        std.debug.assert(indent.len + rows.get(setting).label.len < value_column);
    }
}

pub const max_session_bytes = 128;
pub const max_label_bytes = 100;
pub const max_path_bytes = 4096;
pub const max_model_bytes = model_capability.max_model_bytes;

/// What the page reports, as its reader found it in one Current capture
/// and the saved defaults. `home` is the process's HOME, borrowed for the
/// process's life; the rest is owned, so the screen keeps the facts its
/// page shows and renders it again for each selection. Fill a value field
/// by field.
pub const Facts = struct {
    home: []const u8,
    session: Bounded(max_session_bytes),
    /// Empty when the Session has no name.
    label: Bounded(max_label_bytes),
    workspace: Bounded(max_path_bytes),
    provider: Provider,
    model: Bounded(max_model_bytes),
    /// Null when the model has no catalog effort, so none is sent.
    effort: ?ReasoningEffort,
    effort_override: bool,
    permission: enum { ask, bypass },
    bash: bool,
    web_search: bool,
    /// Null when the Host sets no automatic threshold.
    compaction_trigger: ?u64,
    compaction_override: bool,
    context_estimate: ?u64,
    output_reservation: u64,
    reservation_override: bool,
    /// False when the saved defaults could not be read; `defaults` is then unset.
    defaults_read: bool,
    defaults: Defaults,
    work: Work,
};

/// The most Actions awaiting approval the page names; it counts the rest.
pub const max_listed_actions = 8;

pub const Work = struct {
    state: WorkKind,
    /// Actions awaiting approval, and the first of them in Current's order.
    approvals: u64,
    actions: [max_listed_actions]u64,
    /// The first indeterminate Action of the active Turn, and how many there are.
    indeterminate: ?u64,
    indeterminate_count: u64,

    pub fn listed(self: *const Work) []const u64 {
        return self.actions[0..@min(self.approvals, max_listed_actions)];
    }
};

pub const Defaults = struct {
    /// Null until one is saved.
    provider: ?Provider,
    /// Empty when none is saved, so new Sessions start on Rui's.
    model: Bounded(max_model_bytes),
    effort: ?ReasoningEffort,
    notifications: bool,
    /// The saved Store, or the one the CLI falls back to; empty when
    /// neither can be named.
    store: Bounded(max_path_bytes),
};

/// The page line a setting's row is on: the title, then each group's
/// heading and rows.
pub fn line(setting: Setting) usize {
    return comptime_lines.get(setting);
}

const comptime_lines = blk: {
    var lines: std.enums.EnumArray(Setting, usize) = undefined;
    var at: usize = 1;
    var group: ?Group = null;
    for (std.enums.values(Setting)) |setting| {
        if (group != rows.get(setting).group) at += 1;
        group = rows.get(setting).group;
        lines.set(setting, at);
        at += 1;
    }
    break :blk lines;
};

/// The row Up and Down start from on each /status.
pub const first: Setting = .effort;

/// The changeable row after (or before) `from`, or `from` at either end.
pub fn step(from: Setting, down: bool) Setting {
    var at: usize = @backingInt(from);
    while (if (down) at + 1 < rows.values.len else at > 0) {
        at = if (down) at + 1 else at - 1;
        const setting: Setting = @fromBackingInt(@intCast(at));
        if (rows.get(setting).change != .fixed) return setting;
    }
    return from;
}

/// The whole page: the title, every row with `›` on `selected`, then the
/// work. Null selects no row.
pub fn render(facts: *const Facts, selected: ?Setting, out: *std.Io.Writer) !void {
    // The ID follows the name: scripts and other Sessions address it.
    try out.writeAll(" Status · ");
    if (facts.label.len != 0) {
        try writeText(out, facts.label.slice());
        try out.writeAll(" · ");
    }
    try writeText(out, facts.session.slice());
    try out.writeByte('\n');
    var group: ?Group = null;
    for (std.enums.values(Setting)) |setting| {
        const row = rows.get(setting);
        if (group != row.group) try out.print(" {s}\n", .{headings.get(row.group)});
        group = row.group;
        try out.print("{s}{s}", .{ if (selected == setting) " › " else indent, row.label });
        try out.splatByteAll(' ', value_column - indent.len - row.label.len);
        if (try writeValue(setting, facts, out)) |note| try out.print("  \x1b[90m{s}\x1b[39m", .{note});
        try out.writeByte('\n');
    }
    try writeWork(&facts.work, out);
}

fn writeWork(work: *const Work, out: *std.Io.Writer) !void {
    const state = @tagName(work.state);
    try out.print(" Work\n" ++ indent ++ "{c}{s}", .{ std.ascii.toUpper(state[0]), state[1..] });
    if (work.approvals != 0) try out.print(" · {d} approval{s} waiting", .{ work.approvals, if (work.approvals == 1) "" else "s" });
    try out.writeByte('\n');
    for (work.listed()) |action| try out.print(indent ++ "Action requiring attention: {d}\n", .{action});
    if (work.approvals > max_listed_actions)
        try out.print(indent ++ "+{d} more · session inspect --profile current lists all IDs\n", .{work.approvals - max_listed_actions});
    if (work.indeterminate) |action| {
        try out.print(indent ++ "Indeterminate Action: {d}\n", .{action});
        if (work.indeterminate_count > 1)
            try out.print(indent ++ "Rui: {d} indeterminate Actions in this Turn; session inspect --profile current lists all IDs.\n", .{work.indeterminate_count});
        try out.writeAll(indent ++ "Rui: The command may have run; Rui did not replay it. Check its effects before deciding what to do next.\n");
    }
}

/// Writes the row's value and returns its note.
fn writeValue(setting: Setting, facts: *const Facts, out: *std.Io.Writer) !?[]const u8 {
    const defaults: ?*const Defaults = if (facts.defaults_read) &facts.defaults else null;
    switch (setting) {
        .effort => {
            const effort = facts.effort orelse {
                try out.writeAll("unknown");
                return "no catalog value; reasoning omitted";
            };
            try out.writeAll(@tagName(effort));
            return if (facts.effort_override) "Session override" else "model default";
        },
        // The bypass default is stated where it is inspected, without alert weight.
        .permissions => try out.writeAll(switch (facts.permission) {
            .bypass => "bypass · Bash runs without asking",
            .ask => "ask · Bash asks first",
        }),
        .tools => try out.writeAll(if (facts.bash and facts.web_search) "bash, web search" else if (facts.bash) "bash" else if (facts.web_search) "web search" else "none"),
        .name => if (facts.label.len != 0) try writeText(out, facts.label.slice()) else try out.writeAll("not set"),
        .folder => try writePath(out, facts.home, facts.workspace.slice()),
        .compact_at => {
            // Only a Host from before unlisted models had a window sends none.
            const tokens = facts.compaction_trigger orelse {
                try out.writeAll("off");
                return "context overflow recovery still applies";
            };
            try writeTokens(out, tokens);
            if (facts.context_estimate) |estimate| {
                try out.writeAll(" · now ");
                try writeGrouped(out, estimate);
            }
            return if (facts.compaction_override) "Session override" else if (model_capability.supportsModel(facts.model.slice())) "model default" else "assumed for an unlisted model";
        },
        .headroom => {
            try writeTokens(out, facts.output_reservation);
            return if (facts.reservation_override) "Session override" else "model default";
        },
        .model => {
            try writeText(out, facts.model.slice());
            try out.print(" · {s}", .{facts.provider.signIn()});
            return "fixed for this Session";
        },
        .instructions => try out.writeAll("set from a shell"),
        .default_model => {
            const saved = defaults orelse return unavailable(out);
            try writeText(out, if (saved.model.len != 0) saved.model.slice() else product_defaults.recommended_model);
            if (saved.provider) |provider| try out.print(" · {s}", .{provider.signIn()});
            if (saved.model.len == 0) return "Rui default";
        },
        .default_effort => {
            const saved = defaults orelse return unavailable(out);
            try out.writeAll(if (saved.effort) |effort| @tagName(effort) else "model default");
        },
        .notifications => {
            const saved = defaults orelse return unavailable(out);
            try out.writeAll(if (saved.notifications) "on" else "off");
        },
        .store => {
            const saved = defaults orelse return unavailable(out);
            if (saved.store.len == 0) return unavailable(out);
            try writePath(out, facts.home, saved.store.slice());
        },
    }
    return null;
}

fn unavailable(out: *std.Io.Writer) !?[]const u8 {
    try out.writeAll("unavailable");
    return null;
}

fn writeText(out: *std.Io.Writer, value: []const u8) !void {
    var text: TerminalText = .{ .mode = .line };
    try text.feed(out, value);
    try text.finish(out);
}

fn writePath(out: *std.Io.Writer, home: []const u8, path: []const u8) !void {
    const short = shortPath(home, path);
    try out.writeAll(short.prefix);
    try writeText(out, short.rest);
}

fn writeTokens(out: *std.Io.Writer, tokens: u64) !void {
    try writeGrouped(out, tokens);
    try out.writeAll(" tokens");
}

/// `value` with a comma between each group of three digits.
fn writeGrouped(out: *std.Io.Writer, value: u64) !void {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
    for (text, 0..) |digit, index| {
        if (index != 0 and (text.len - index) % 3 == 0) try out.writeByte(',');
        try out.writeByte(digit);
    }
}

/// The longest draft a row starts: a command, and a path with every byte
/// escaped.
pub const max_draft_bytes = 64 + 2 * max_path_bytes;

/// The draft Enter on a row starts, written into `buffer`: a choice row's
/// command, whose list then offers its choices, or a typed row's command
/// with the current value after it. Null for a fixed row. A value the
/// draft cannot hold (a control byte) is left for the person to type.
pub fn draft(setting: Setting, facts: *const Facts, buffer: *[max_draft_bytes]u8) ?[]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    writeDraft(setting, facts, &out) catch unreachable;
    return if (rows.get(setting).change == .fixed) null else out.buffered();
}

fn writeDraft(setting: Setting, facts: *const Facts, out: *std.Io.Writer) !void {
    const prefix = switch (rows.get(setting).change) {
        .fixed => return,
        .choice => |command| return out.writeAll(command),
        .typed => |command| command,
    };
    try out.writeAll(prefix);
    var number: [20]u8 = undefined;
    const defaults: ?*const Defaults = if (facts.defaults_read) &facts.defaults else null;
    const value: []const u8 = switch (setting) {
        .name => facts.label.slice(),
        .folder => facts.workspace.slice(),
        .compact_at => if (facts.compaction_trigger) |tokens| std.fmt.bufPrint(&number, "{d}", .{tokens}) catch unreachable else "",
        .headroom => std.fmt.bufPrint(&number, "{d}", .{facts.output_reservation}) catch unreachable,
        .default_model => model: {
            const saved = defaults orelse break :model "";
            try out.print("{s} --model ", .{@tagName(saved.provider orelse facts.provider)});
            break :model if (saved.model.len != 0) saved.model.slice() else product_defaults.recommended_model;
        },
        .store => if (defaults) |saved| saved.store.slice() else "",
        else => unreachable,
    };
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return;
    // /configure and /setup read `\` before a space, `"` or `\` as that byte.
    for (value) |byte| {
        if (byte == ' ' or byte == '"' or byte == '\\') try out.writeByte('\\');
        try out.writeByte(byte);
    }
}

/// A Session's facts as a fresh one on Rui's defaults would have them,
/// named fix-safari-export, for tests of the page and its shell.
pub fn sample() Facts {
    var facts: Facts = .{
        .home = "/home/d",
        .session = .{ .len = 0 },
        .label = .{ .len = 0 },
        .workspace = .{ .len = 0 },
        .provider = .codex,
        .model = .{ .len = 0 },
        .effort = .high,
        .effort_override = false,
        .permission = .bypass,
        .bash = true,
        .web_search = true,
        .compaction_trigger = 245_000,
        .compaction_override = false,
        .context_estimate = 31_200,
        .output_reservation = 0,
        .reservation_override = false,
        .defaults_read = true,
        .defaults = .{ .provider = .codex, .model = .{ .len = 0 }, .effort = null, .notifications = true, .store = .{ .len = 0 } },
        .work = .{ .state = .idle, .approvals = 0, .actions = undefined, .indeterminate = null, .indeterminate_count = 0 },
    };
    facts.session.set("k7m2qx") catch unreachable;
    facts.label.set("fix-safari-export") catch unreachable;
    facts.workspace.set("/home/d/code/rui") catch unreachable;
    facts.model.set(product_defaults.recommended_model) catch unreachable;
    facts.defaults.store.set("/home/d/.rui/store") catch unreachable;
    return facts;
}

test "the page shows the approved rows, `›` on the selected one, then the work" {
    const facts = sample();
    var bytes: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try render(&facts, .effort, &out);
    const grey = "  \x1b[90m";
    const end = "\x1b[39m\n";
    try std.testing.expectEqualStrings(
        " Status · fix-safari-export · k7m2qx\n" ++
            " This Session\n" ++
            " › Effort          high" ++ grey ++ "model default" ++ end ++
            "   Permissions     bypass · Bash runs without asking\n" ++
            "   Tools           bash, web search\n" ++
            "   Name            fix-safari-export\n" ++
            "   Folder          ~/code/rui\n" ++
            "   Compact at      245,000 tokens · now 31,200" ++ grey ++ "model default" ++ end ++
            "   Headroom        0 tokens" ++ grey ++ "model default" ++ end ++
            "   Model           gpt-6.1-sol · ChatGPT" ++ grey ++ "fixed for this Session" ++ end ++
            "   Instructions    set from a shell\n" ++
            " New Sessions\n" ++
            "   Model           gpt-6.1-sol · ChatGPT" ++ grey ++ "Rui default" ++ end ++
            "   Effort          model default\n" ++
            "   Notifications   on\n" ++
            "   Store           ~/.rui/store\n" ++
            " Work\n" ++
            "   Idle\n",
        out.buffered(),
    );
    // Each row's line is the one `line` names, `›` on it alone when selected.
    for (std.enums.values(Setting)) |selected| {
        out = .fixed(&bytes);
        try render(&facts, selected, &out);
        var lines = std.mem.splitScalar(u8, out.buffered(), '\n');
        var index: usize = 0;
        while (lines.next()) |text| : (index += 1) for (std.enums.values(Setting)) |setting| if (line(setting) == index) {
            try std.testing.expect(std.mem.startsWith(u8, text, if (setting == selected) " › " else indent));
            try std.testing.expect(std.mem.startsWith(u8, text[indent.len + (if (setting == selected) "›".len - 1 else 0) ..], rows.get(setting).label));
        };
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.buffered(), "›"));
    }
}

test "the work names its state, each Action awaiting approval up to a count, and what may have run" {
    var facts = sample();
    facts.work = .{ .state = .approval, .approvals = 10, .actions = .{ 1, 2, 3, 4, 5, 6, 7, 8 }, .indeterminate = 4, .indeterminate_count = 2 };
    var bytes: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try render(&facts, null, &out);
    const work = out.buffered()[std.mem.indexOf(u8, out.buffered(), " Work\n").?..];
    try std.testing.expectEqualStrings(
        " Work\n   Approval · 10 approvals waiting\n" ++
            "   Action requiring attention: 1\n   Action requiring attention: 2\n   Action requiring attention: 3\n   Action requiring attention: 4\n" ++
            "   Action requiring attention: 5\n   Action requiring attention: 6\n   Action requiring attention: 7\n   Action requiring attention: 8\n" ++
            "   +2 more · session inspect --profile current lists all IDs\n" ++
            "   Indeterminate Action: 4\n" ++
            "   Rui: 2 indeterminate Actions in this Turn; session inspect --profile current lists all IDs.\n" ++
            "   Rui: The command may have run; Rui did not replay it. Check its effects before deciding what to do next.\n",
        work,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "›") == null);
    facts.work = .{ .state = .finished, .approvals = 1, .actions = .{ 9, 0, 0, 0, 0, 0, 0, 0 }, .indeterminate = null, .indeterminate_count = 0 };
    out = .fixed(&bytes);
    try render(&facts, null, &out);
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), " Work\n   Finished · 1 approval waiting\n   Action requiring attention: 9\n"));
}

test "each value stays on its row and says where it came from" {
    var facts = sample();
    try facts.label.set("a\nb");
    facts.effort = null;
    facts.permission = .ask;
    facts.web_search = false;
    facts.compaction_trigger = 1_234_567;
    facts.context_estimate = null;
    facts.compaction_override = true;
    facts.reservation_override = true;
    facts.output_reservation = 999;
    try facts.model.set("model-a");
    facts.defaults = .{ .provider = .openai, .model = .{ .len = 0 }, .effort = .low, .notifications = false, .store = .{ .len = 0 } };
    try facts.defaults.model.set("gpt-x");
    try facts.defaults.store.set("/srv/store");
    var bytes: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try render(&facts, null, &out);
    const page = out.buffered();
    try std.testing.expectEqual(@as(usize, line(.store) + 3), std.mem.count(u8, page, "\n"));
    for ([_][]const u8{
        " Status · a\\nb · k7m2qx\n",
        "Effort          unknown  \x1b[90mno catalog value; reasoning omitted",
        "Permissions     ask · Bash asks first\n",
        "Tools           bash\n",
        "Compact at      1,234,567 tokens  \x1b[90mSession override",
        "Headroom        999 tokens  \x1b[90mSession override",
        "Model           model-a · ChatGPT",
        "Model           gpt-x · API key\n",
        "Effort          low\n",
        "Notifications   off\n",
        "Store           /srv/store\n",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, page, expected) != null);
    facts.compaction_override = false;
    facts.compaction_trigger = null;
    facts.defaults_read = false;
    out = .fixed(&bytes);
    try render(&facts, null, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Compact at      off  \x1b[90mcontext overflow recovery still applies") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out.buffered(), "unavailable\n"));
    facts.compaction_trigger = 10;
    out = .fixed(&bytes);
    try render(&facts, null, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "10 tokens  \x1b[90massumed for an unlisted model") != null);
}

test "Up and Down step over fixed rows and stop at either end" {
    try std.testing.expectEqual(Setting.effort, step(.effort, false));
    try std.testing.expectEqual(Setting.permissions, step(.effort, true));
    try std.testing.expectEqual(Setting.default_model, step(.headroom, true));
    try std.testing.expectEqual(Setting.headroom, step(.default_model, false));
    try std.testing.expectEqual(Setting.store, step(.store, true));
    for (std.enums.values(Setting)) |setting| for ([_]bool{ false, true }) |down| {
        try std.testing.expect(rows.get(step(setting, down)).change != .fixed or step(setting, down) == setting);
    };
}

test "a row's draft is its command, with a typed row's value escaped as the command reads it" {
    var facts = sample();
    var buffer: [max_draft_bytes]u8 = undefined;
    for ([_]struct { Setting, ?[]const u8 }{
        .{ .effort, "/configure --reasoning-effort " },
        .{ .permissions, "/configure --permission-mode " },
        .{ .tools, "/configure --tools " },
        .{ .name, "/configure --label fix-safari-export" },
        .{ .folder, "/configure --workspace /home/d/code/rui" },
        .{ .compact_at, "/configure --compaction-trigger 245000" },
        .{ .headroom, "/configure --output-reservation 0" },
        .{ .model, null },
        .{ .instructions, null },
        .{ .default_model, "/setup --provider codex --model gpt-6.1-sol" },
        .{ .default_effort, "/setup --reasoning-effort " },
        .{ .notifications, "/setup --notifications " },
        .{ .store, "/setup --store /home/d/.rui/store" },
    }) |case| {
        const text = draft(case[0], &facts, &buffer);
        if (case[1]) |expected| try std.testing.expectEqualStrings(expected, text.?) else try std.testing.expect(text == null);
    }
    try facts.label.set("lane \"four\\");
    try std.testing.expectEqualStrings("/configure --label lane\\ \\\"four\\\\", draft(.name, &facts, &buffer).?);
    try facts.workspace.set("/tmp/a\tb");
    try std.testing.expectEqualStrings("/configure --workspace ", draft(.folder, &facts, &buffer).?);
    facts.compaction_trigger = null;
    try std.testing.expectEqualStrings("/configure --compaction-trigger ", draft(.compact_at, &facts, &buffer).?);
    facts.defaults.provider = null;
    facts.provider = .openai;
    try facts.defaults.model.set("gpt-x");
    try std.testing.expectEqualStrings("/setup --provider openai --model gpt-x", draft(.default_model, &facts, &buffer).?);
    facts.defaults_read = false;
    try std.testing.expectEqualStrings("/setup --provider ", draft(.default_model, &facts, &buffer).?);
    // The longest path, every byte escaped, fits.
    @memset(&facts.workspace.bytes, ' ');
    facts.workspace.len = max_path_bytes;
    try std.testing.expectEqual(@as(usize, "/configure --workspace ".len + 2 * max_path_bytes), draft(.folder, &facts, &buffer).?.len);
}
