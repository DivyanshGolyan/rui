//! The /status page: one row per setting, in page order, each one logical
//! line, the draft that changes a row, and the work. Rows of the Session
//! come before the defaults new Sessions start from.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const built_in_tool = @import("built_in_tool.zig");
const command_value = @import("command_value.zig");
const model_capability = @import("model_capability.zig");
const product_defaults = @import("product_defaults.zig");
const Provider = @import("provider_name.zig").Provider;
const TerminalText = @import("TerminalText.zig");
const shortPath = @import("home_path.zig").shortPath;
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
    store,
    instructions,
    default_model,
    default_effort,
    notifications,
    default_store,
};

pub const Group = enum { session, defaults };

/// How a row changes: not from this page, by the command whose list offers
/// its choices, or by editing the current value after the command.
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
    // The list offers `default`; a number is typed, so Enter never turns
    // the model's default into an override of the same number.
    .compact_at = .{ .group = .session, .label = "Compact at", .change = .{ .choice = "/configure --compaction-trigger " } },
    .headroom = .{ .group = .session, .label = "Headroom", .change = .{ .choice = "/configure --output-reservation " } },
    .model = .{ .group = .session, .label = "Model", .change = .fixed },
    .store = .{ .group = .session, .label = "Store", .change = .fixed },
    .instructions = .{ .group = .session, .label = "Instructions", .change = .fixed },
    // A saved model needs a saved provider, so the draft names both.
    .default_model = .{ .group = .defaults, .label = "Model", .change = .{ .typed = "/setup --provider " } },
    .default_effort = .{ .group = .defaults, .label = "Effort", .change = .{ .choice = "/setup --reasoning-effort " } },
    .notifications = .{ .group = .defaults, .label = "Notifications", .change = .{ .choice = "/setup --notifications " } },
    .default_store = .{ .group = .defaults, .label = "Store", .change = .{ .typed = "/setup --store " } },
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
pub const max_key_bytes = 128;
pub const max_outcome_bytes = 96;
pub const max_recent = 10;

/// Rui's provider for a new Session when none is saved.
const rui_provider = std.meta.stringToEnum(Provider, product_defaults.provider).?;

/// What the page reports, borrowed from the owners of each part for one
/// render.
pub const Facts = struct {
    /// The process's HOME, empty without one: paths under it show with `~`.
    home: []const u8,
    /// This Session's Store.
    store: []const u8,
    session: *const Session,
    defaults: *const Defaults,
};

/// What one Current capture says of the Session and its work. Each value
/// is owned, so a read fills one in place while the page shows another.
pub const Session = struct {
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
    tools: built_in_tool.Selection,
    /// The Session was configured with instructions.
    instructions: bool,
    /// Null when the Host sets no automatic threshold.
    compaction_trigger: ?u64,
    compaction_override: bool,
    context_estimate: ?u64,
    output_reservation: u64,
    reservation_override: bool,
    work: Work,

    /// The page shows the same Session and work.
    pub fn eql(self: *const Session, other: *const Session) bool {
        inline for (comptime std.meta.fieldNames(Session)) |name| {
            const a = &@field(self, name);
            const b = &@field(other, name);
            const Field = @TypeOf(a.*);
            const same = if (Field == Work) a.eql(b) else if (comptime @typeInfo(Field) == .@"struct" and @hasDecl(Field, "slice")) b.eql(a.slice()) else std.meta.eql(a.*, b.*);
            if (!same) return false;
        }
        return true;
    }
};

pub const Work = struct {
    state: WorkKind,
    /// Actions awaiting approval, which the page lists one per line after
    /// this part, and a digest of their IDs in Current's order.
    approvals: u64,
    actions: u64,
    current_message: ?Bounded(max_key_bytes),
    /// The first indeterminate Action of the active Turn, and how many there are.
    indeterminate: ?u64,
    indeterminate_count: u64,
    recent: [max_recent]Recent,
    recent_count: usize,

    pub const Recent = struct { message: Bounded(max_key_bytes), outcome: Bounded(max_outcome_bytes) };

    fn eql(self: *const Work, other: *const Work) bool {
        if (self.state != other.state or self.approvals != other.approvals or self.actions != other.actions or
            self.indeterminate != other.indeterminate or self.indeterminate_count != other.indeterminate_count or
            self.recent_count != other.recent_count) return false;
        if ((self.current_message == null) != (other.current_message == null)) return false;
        if (self.current_message) |*message| if (!other.current_message.?.eql(message.slice())) return false;
        for (self.recent[0..self.recent_count], other.recent[0..other.recent_count]) |*a, *b|
            if (!b.message.eql(a.message.slice()) or !b.outcome.eql(a.outcome.slice())) return false;
        return true;
    }
};

/// The defaults new Sessions start from, or why they could not be read.
pub const Defaults = anyerror!Saved;

pub const Saved = struct {
    /// The saved provider, or Rui's when none is saved; an error when the
    /// saved one is not a provider Rui knows.
    provider: anyerror!Provider,
    /// Empty when none is saved, so new Sessions start on Rui's.
    model: Bounded(max_model_bytes),
    effort: ?ReasoningEffort,
    notifications: bool,
    /// The saved Store, or the one the CLI falls back to, or why neither
    /// can be named.
    store: anyerror!Bounded(max_path_bytes),

    /// The provider new Sessions start on with none saved.
    pub const rui = rui_provider;
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

/// The page down to the work's Actions awaiting approval: the title, every
/// row with `›` on `selected`, then the work's state. `writeAction` lists
/// each Action after it and `writeWorkEnd` ends the page.
pub fn render(facts: Facts, selected: Setting, out: *std.Io.Writer) !void {
    const session = facts.session;
    // The ID follows the name: scripts and other Sessions address it.
    try out.writeAll(" Status · ");
    if (session.label.len != 0) {
        try writeText(out, session.label.slice());
        try out.writeAll(" · ");
    }
    try writeText(out, session.session.slice());
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
    const work = &session.work;
    const state = @tagName(work.state);
    try out.print(" Work\n" ++ indent ++ "{c}{s}", .{ std.ascii.toUpper(state[0]), state[1..] });
    if (work.approvals != 0) try out.print(" · {d} approval{s} waiting", .{ work.approvals, if (work.approvals == 1) "" else "s" });
    try out.writeByte('\n');
    if (work.current_message) |*message| {
        try out.writeAll(indent ++ "Current message: ");
        try writeText(out, message.slice());
        try out.writeByte('\n');
    }
}

/// One Action awaiting approval, after `render`.
pub fn writeAction(action: u64, out: *std.Io.Writer) !void {
    try out.print(indent ++ "Action requiring attention: {d}\n", .{action});
}

/// The rest of the work, after its Actions: what may have run, and the
/// recent messages whose answers /result shows.
pub fn writeWorkEnd(work: *const Work, out: *std.Io.Writer) !void {
    if (work.indeterminate) |action| {
        try out.print(indent ++ "Indeterminate Action: {d}\n", .{action});
        if (work.indeterminate_count > 1)
            try out.print(indent ++ "Rui: {d} indeterminate Actions in this Turn; session inspect --profile current lists all IDs.\n", .{work.indeterminate_count});
        try out.writeAll(indent ++ "Rui: The command may have run; Rui did not replay it. Check its effects before deciding what to do next.\n");
    }
    if (work.recent_count == 0) return;
    try out.writeAll(indent ++ "Recent messages (use /result KEY for an answer):\n");
    for (work.recent[0..work.recent_count]) |*recent| {
        try out.writeAll(indent ++ "  ");
        try writeText(out, recent.message.slice());
        try out.writeAll(": ");
        try writeText(out, recent.outcome.slice());
        try out.writeByte('\n');
    }
}

/// Writes the row's value and returns its note.
fn writeValue(setting: Setting, facts: Facts, out: *std.Io.Writer) !?[]const u8 {
    const session = facts.session;
    switch (setting) {
        .effort => {
            const effort = session.effort orelse {
                try out.writeAll("unknown");
                return "no catalog value; reasoning omitted";
            };
            try out.writeAll(@tagName(effort));
            // D111: clients save the catalog effort as the Session's own, so
            // the note compares the value rather than whether one was saved.
            return if (effort == model_capability.defaultReasoningEffort(session.model.slice())) "model default" else "Session override";
        },
        // The bypass default is stated where it is inspected, without alert weight.
        .permissions => try out.writeAll(switch (session.permission) {
            .bypass => "bypass · Bash runs without asking",
            .ask => "ask · Bash asks first",
        }),
        .tools => try writeTools(out, session.tools),
        .name => if (session.label.len != 0) try writeText(out, session.label.slice()) else try out.writeAll("not set"),
        .folder => try writePath(out, facts.home, session.workspace.slice()),
        .compact_at => {
            // Only a Host from before unlisted models had a window sends none.
            const tokens = session.compaction_trigger orelse {
                try out.writeAll("off");
                return "context overflow recovery still applies";
            };
            try writeTokens(out, tokens);
            if (session.context_estimate) |estimate| {
                try out.writeAll(" · now ");
                try writeGrouped(out, estimate);
            }
            // D111: the default a client fills is 90% of the known or assumed window.
            const client_default = model_capability.contextWindow(session.model.slice()) * product_defaults.compaction_trigger_percent / 100;
            return if (session.compaction_override and tokens != client_default) "Session override" else if (model_capability.supportsModel(session.model.slice())) "model default" else "assumed for an unlisted model";
        },
        .headroom => {
            try writeTokens(out, session.output_reservation);
            return if (session.reservation_override) "Session override" else "model default";
        },
        .model => {
            try writeText(out, session.model.slice());
            try out.print(" · {s}", .{session.provider.signIn()});
            return "fixed for this Session";
        },
        .store => {
            try writePath(out, facts.home, facts.store);
            return "fixed for this Session";
        },
        .instructions => try out.writeAll(if (session.instructions) "set from a shell" else "none"),
        .default_model => {
            const saved = facts.defaults.* catch |err| return unreadable(out, err);
            const provider = saved.provider catch |err| return unreadable(out, err);
            try writeText(out, if (saved.model.len != 0) saved.model.slice() else product_defaults.recommended_model);
            try out.print(" · {s}", .{provider.signIn()});
            if (saved.model.len == 0) return "Rui default";
        },
        .default_effort => {
            const saved = facts.defaults.* catch |err| return unreadable(out, err);
            try out.writeAll(if (saved.effort) |effort| @tagName(effort) else "model default");
        },
        .notifications => {
            const saved = facts.defaults.* catch |err| return unreadable(out, err);
            try out.writeAll(if (saved.notifications) "on" else "off");
        },
        .default_store => {
            const saved = facts.defaults.* catch |err| return unreadable(out, err);
            const store = saved.store catch |err| return unreadable(out, err);
            try writePath(out, facts.home, store.slice());
        },
    }
    return null;
}

fn unreadable(out: *std.Io.Writer, err: anyerror) !?[]const u8 {
    try out.print("unreadable · {s}", .{@errorName(err)});
    return null;
}

/// Names `tools` in catalog order, with spaces for underscores, or "none".
fn writeTools(out: *std.Io.Writer, tools: built_in_tool.Selection) !void {
    if (tools.count() == 0) return out.writeAll("none");
    var named = false;
    for (std.enums.values(built_in_tool.BuiltInTool)) |tool| if (tools.contains(tool)) {
        if (named) try out.writeAll(", ");
        named = true;
        for (@tagName(tool)) |byte| try out.writeByte(if (byte == '_') ' ' else byte);
    };
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

/// The longest draft a row starts: a command, and a quoted path with every
/// byte escaped.
pub const max_draft_bytes = 64 + 2 * max_path_bytes + 2;

/// The draft Enter on a row starts, written into `buffer`: a choice row's
/// command, whose list then offers its choices, or a typed row's command
/// with the current value after it. Null for a fixed row. A value the
/// draft cannot hold (a control byte) is left for the person to type.
pub fn draft(setting: Setting, facts: Facts, buffer: *[max_draft_bytes]u8) ?[]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    const prefix = switch (rows.get(setting).change) {
        .fixed => return null,
        .choice => |command| return command,
        .typed => |command| command,
    };
    out.writeAll(prefix) catch unreachable;
    const value: []const u8 = switch (setting) {
        .name => facts.session.label.slice(),
        .folder => facts.session.workspace.slice(),
        .default_model => model: {
            const saved = facts.defaults.* catch break :model "";
            const provider = saved.provider catch break :model "";
            out.print("{s} --model ", .{@tagName(provider)}) catch unreachable;
            break :model if (saved.model.len != 0) saved.model.slice() else product_defaults.recommended_model;
        },
        .default_store => store: {
            const saved = facts.defaults.* catch break :store "";
            const store = saved.store catch break :store "";
            break :store store.slice();
        },
        .effort, .permissions, .tools, .compact_at, .headroom, .model, .store, .instructions, .default_effort, .notifications => unreachable,
    };
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return out.buffered();
    if (value.len != 0) command_value.write(&out, value) catch unreachable;
    return out.buffered();
}

/// Fills `session` as a fresh Session on Rui's defaults would have it,
/// named fix-safari-export, for tests of the page and its shell.
pub fn sample(session: *Session) void {
    session.* = .{
        .session = .{ .len = 0 },
        .label = .{ .len = 0 },
        .workspace = .{ .len = 0 },
        .provider = .codex,
        .model = .{ .len = 0 },
        .effort = .high,
        .effort_override = false,
        .permission = .bypass,
        .tools = .initMany(&.{ .bash, .web_search }),
        .instructions = true,
        .compaction_trigger = 245_000,
        .compaction_override = false,
        .context_estimate = 31_200,
        .output_reservation = 0,
        .reservation_override = false,
        .work = .{ .state = .idle, .approvals = 0, .actions = 0, .current_message = null, .indeterminate = null, .indeterminate_count = 0, .recent = undefined, .recent_count = 0 },
    };
    session.session.set("k7m2qx") catch unreachable;
    session.label.set("fix-safari-export") catch unreachable;
    session.workspace.set("/home/d/code/rui") catch unreachable;
    session.model.set(product_defaults.recommended_model) catch unreachable;
}

/// Rui's defaults with a Store under the sample's HOME.
pub fn sampleDefaults(defaults: *Defaults) void {
    var store: Bounded(max_path_bytes) = .{ .len = 0 };
    store.set("/home/d/.rui/store") catch unreachable;
    defaults.* = .{ .provider = rui_provider, .model = .{ .len = 0 }, .effort = null, .notifications = true, .store = store };
}

/// The page `facts` and `work_end` show with `actions` listed, as the
/// shell writes it.
fn testPage(facts: Facts, selected: Setting, actions: []const u64, out: *std.Io.Writer) !void {
    try render(facts, selected, out);
    for (actions) |action| try writeAction(action, out);
    try writeWorkEnd(&facts.session.work, out);
}

const Sample = struct {
    session: Session,
    defaults: Defaults,

    fn facts(self: *const Sample) Facts {
        return .{ .home = "/home/d", .store = "/home/d/.local/share/rui/store", .session = &self.session, .defaults = &self.defaults };
    }
};

fn testSample() *Sample {
    const static = struct {
        var value: Sample = undefined;
    };
    sample(&static.value.session);
    sampleDefaults(&static.value.defaults);
    return &static.value;
}

test "the page shows the approved rows, `›` on the selected one, then the work" {
    const held = testSample();
    var bytes: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try testPage(held.facts(), .effort, &.{}, &out);
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
            "   Store           ~/.local/share/rui/store" ++ grey ++ "fixed for this Session" ++ end ++
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
        try render(held.facts(), selected, &out);
        var lines = std.mem.splitScalar(u8, out.buffered(), '\n');
        var index: usize = 0;
        while (lines.next()) |text| : (index += 1) for (std.enums.values(Setting)) |setting| if (line(setting) == index) {
            try std.testing.expect(std.mem.startsWith(u8, text, if (setting == selected) " › " else indent));
            try std.testing.expect(std.mem.startsWith(u8, text[indent.len + (if (setting == selected) "›".len - 1 else 0) ..], rows.get(setting).label));
        };
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.buffered(), "›"));
    }
}

test "the work names its state, its current message, every Action awaiting approval, what may have run and recent answers" {
    const held = testSample();
    const work = &held.session.work;
    work.* = .{ .state = .approval, .approvals = 10, .actions = 1, .current_message = .{ .len = 0 }, .indeterminate = 4, .indeterminate_count = 2, .recent = undefined, .recent_count = 2 };
    try work.current_message.?.set("m3");
    try work.recent[0].message.set("m1");
    try work.recent[0].outcome.set("completed");
    try work.recent[1].message.set("m\n2");
    try work.recent[1].outcome.set("failed_saved");
    var bytes: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try testPage(held.facts(), .effort, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, &out);
    const shown = out.buffered()[std.mem.indexOf(u8, out.buffered(), " Work\n").?..];
    try std.testing.expectEqualStrings(
        " Work\n   Approval · 10 approvals waiting\n" ++
            "   Current message: m3\n" ++
            "   Action requiring attention: 1\n   Action requiring attention: 2\n   Action requiring attention: 3\n   Action requiring attention: 4\n" ++
            "   Action requiring attention: 5\n   Action requiring attention: 6\n   Action requiring attention: 7\n   Action requiring attention: 8\n" ++
            "   Action requiring attention: 9\n   Action requiring attention: 10\n" ++
            "   Indeterminate Action: 4\n" ++
            "   Rui: 2 indeterminate Actions in this Turn; session inspect --profile current lists all IDs.\n" ++
            "   Rui: The command may have run; Rui did not replay it. Check its effects before deciding what to do next.\n" ++
            "   Recent messages (use /result KEY for an answer):\n" ++
            "     m1: completed\n" ++
            "     m\\n2: failed_saved\n",
        shown,
    );
    work.* = .{ .state = .finished, .approvals = 1, .actions = 2, .current_message = null, .indeterminate = null, .indeterminate_count = 0, .recent = undefined, .recent_count = 0 };
    out = .fixed(&bytes);
    try testPage(held.facts(), .effort, &.{9}, &out);
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), " Work\n   Finished · 1 approval waiting\n   Action requiring attention: 9\n"));
}

test "each value stays on its row and says where it came from" {
    const held = testSample();
    const session = &held.session;
    try session.label.set("a\nb");
    session.effort = null;
    session.permission = .ask;
    session.tools.remove(.web_search);
    session.instructions = false;
    session.compaction_trigger = 1_234_567;
    session.context_estimate = null;
    session.compaction_override = true;
    session.reservation_override = true;
    session.output_reservation = 999;
    try session.model.set("model-a");
    held.defaults = .{ .provider = .openai, .model = .{ .len = 0 }, .effort = .low, .notifications = false, .store = .{ .len = 0 } };
    const saved = if (held.defaults) |*saved| saved else |_| unreachable;
    try saved.model.set("gpt-x");
    if (saved.store) |*store| try store.set("/srv/store") else |_| unreachable;
    var bytes: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try render(held.facts(), .effort, &out);
    const page = out.buffered();
    try std.testing.expectEqual(@as(usize, line(.default_store) + 3), std.mem.count(u8, page, "\n"));
    for ([_][]const u8{
        " Status · a\\nb · k7m2qx\n",
        "Effort          unknown  \x1b[90mno catalog value; reasoning omitted",
        "Permissions     ask · Bash asks first\n",
        "Tools           bash\n",
        "Compact at      1,234,567 tokens  \x1b[90mSession override",
        "Headroom        999 tokens  \x1b[90mSession override",
        "Model           model-a · ChatGPT",
        "Instructions    none\n",
        "Model           gpt-x · API key\n",
        "Effort          low\n",
        "Notifications   off\n",
        "Store           /srv/store\n",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, page, expected) != null);
    session.compaction_override = false;
    session.compaction_trigger = null;
    out = .fixed(&bytes);
    try render(held.facts(), .effort, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Compact at      off  \x1b[90mcontext overflow recovery still applies") != null);
    session.compaction_trigger = 10;
    out = .fixed(&bytes);
    try render(held.facts(), .effort, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "10 tokens  \x1b[90massumed for an unlisted model") != null);
}

test "defaults that cannot be read say why on their rows, never a blank" {
    const held = testSample();
    var bytes: [4096]u8 = undefined;
    held.defaults = error.AccessDenied;
    var out = std.Io.Writer.fixed(&bytes);
    try render(held.facts(), .effort, &out);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out.buffered(), "unreadable · AccessDenied\n"));
    // A saved provider Rui does not know, and a Store no path names.
    held.defaults = .{ .provider = error.UnsupportedPreferenceProvider, .model = .{ .len = 0 }, .effort = null, .notifications = true, .store = error.InvalidHome };
    out = .fixed(&bytes);
    try render(held.facts(), .effort, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "   Model           unreadable · UnsupportedPreferenceProvider\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "   Store           unreadable · InvalidHome\n") != null);
    var buffer: [max_draft_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/setup --provider ", draft(.default_model, held.facts(), &buffer).?);
    try std.testing.expectEqualStrings("/setup --store ", draft(.default_store, held.facts(), &buffer).?);
}

test "Up and Down step over fixed rows and stop at either end" {
    try std.testing.expectEqual(Setting.effort, step(.effort, false));
    try std.testing.expectEqual(Setting.permissions, step(.effort, true));
    try std.testing.expectEqual(Setting.default_model, step(.headroom, true));
    try std.testing.expectEqual(Setting.headroom, step(.default_model, false));
    try std.testing.expectEqual(Setting.default_store, step(.default_store, true));
    for (std.enums.values(Setting)) |setting| for ([_]bool{ false, true }) |down| {
        try std.testing.expect(rows.get(step(setting, down)).change != .fixed or step(setting, down) == setting);
    };
}

test "a row's draft is its command, with a typed row's value as the command reads it" {
    const held = testSample();
    var buffer: [max_draft_bytes]u8 = undefined;
    for ([_]struct { Setting, ?[]const u8 }{
        .{ .effort, "/configure --reasoning-effort " },
        .{ .permissions, "/configure --permission-mode " },
        .{ .tools, "/configure --tools " },
        .{ .name, "/configure --label fix-safari-export" },
        .{ .folder, "/configure --workspace /home/d/code/rui" },
        // The list offers `default`; a number is typed.
        .{ .compact_at, "/configure --compaction-trigger " },
        .{ .headroom, "/configure --output-reservation " },
        .{ .model, null },
        .{ .store, null },
        .{ .instructions, null },
        .{ .default_model, "/setup --provider codex --model gpt-6.1-sol" },
        .{ .default_effort, "/setup --reasoning-effort " },
        .{ .notifications, "/setup --notifications " },
        .{ .default_store, "/setup --store /home/d/.rui/store" },
    }) |case| {
        const text = draft(case[0], held.facts(), &buffer);
        if (case[1]) |expected| try std.testing.expectEqualStrings(expected, text.?) else try std.testing.expect(text == null);
    }
    try held.session.label.set("lane \"four\\");
    try std.testing.expectEqualStrings("/configure --label \"lane \\\"four\\\\\"", draft(.name, held.facts(), &buffer).?);
    try held.session.workspace.set("/tmp/a\tb");
    try std.testing.expectEqualStrings("/configure --workspace ", draft(.folder, held.facts(), &buffer).?);
    // The provider a new Session gets, whatever this Session's.
    held.session.provider = .openai;
    try std.testing.expectEqualStrings("/setup --provider codex --model gpt-6.1-sol", draft(.default_model, held.facts(), &buffer).?);
    held.defaults = .{ .provider = .openai, .model = .{ .len = 0 }, .effort = null, .notifications = true, .store = .{ .len = 0 } };
    if (held.defaults) |*saved| try saved.model.set("gpt-x") else |_| unreachable;
    try std.testing.expectEqualStrings("/setup --provider openai --model gpt-x", draft(.default_model, held.facts(), &buffer).?);
    // The longest path, every byte escaped, fits.
    @memset(&held.session.workspace.bytes, '"');
    held.session.workspace.len = max_path_bytes;
    try std.testing.expectEqual(@as(usize, "/configure --workspace ".len + 2 * max_path_bytes + 2), draft(.folder, held.facts(), &buffer).?.len);
}

test "the page's Session changes with any fact it shows, its unused bytes aside" {
    const held = testSample();
    var other: Session = undefined;
    sample(&other);
    try std.testing.expect(held.session.eql(&other));
    other.label.bytes[other.label.len] = 'x';
    other.work.recent[3].message = .{ .len = 0 };
    try std.testing.expect(held.session.eql(&other));
    other.work.actions = 1;
    try std.testing.expect(!held.session.eql(&other));
    sample(&other);
    other.work.current_message = .{ .len = 0 };
    try std.testing.expect(!held.session.eql(&other));
    try other.work.current_message.?.set("m");
    try std.testing.expect(!held.session.eql(&other));
}
