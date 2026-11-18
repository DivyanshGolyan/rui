const std = @import("std");
const commands = @import("slash_commands.zig");
const skills = @import("skill_completion.zig");

pub const Pick = commands.Shown.Pick;
pub const Source = union(enum) {
    none,
    draft: struct {
        bytes: []const u8,
        caret: usize,
        revision: u64,
        context: commands.Context = .{},
        skills: *const skills.Reads,
    },
    requests: struct { revision: u64, source: u64, list: commands.List },
};
pub const How = union(enum) { enter, pick: Pick };

/// A synchronous acceptance decision. Consume it with the same Source before
/// changing that source. It carries no text borrowed from preview scratch.
pub const Accepted = struct { pick: Pick };

pub const Menu = struct {
    shown: ?commands.Shown = null,
    rows: skills.Rows = .{},
    drawn_pick: ?Pick = null,
    closed_draft_revision: ?u64 = null,

    pub fn frame(self: *Menu, source: Source) ?*commands.Shown {
        self.shown = build(&self.rows, self.shown, source);
        self.keepClosed(source);
        if (self.shown == null) self.drawn_pick = null;
        return if (self.shown) |*shown| shown else null;
    }

    pub fn drew(self: *Menu, visible: bool, pick: Pick) void {
        const shown = if (self.shown) |*shown| shown else {
            self.drawn_pick = null;
            return;
        };
        shown.drew(visible);
        self.drawn_pick = if (shown.seen == .drawn) pick else null;
    }

    /// Enter and navigation follow the current draft, retaining the previous
    /// frame's visibility. A source change hides new rows until they are drawn.
    pub fn current(self: *Menu, source: Source) ?*commands.Shown {
        const next = build(&self.rows, self.shown, source) orelse return null;
        self.shown = next;
        self.keepClosed(source);
        return if (self.shown.?.seen == .drawn) &self.shown.? else null;
    }

    pub fn closeIfDrawn(self: *Menu, source: Source) bool {
        const drawn = if (self.drawn_pick) |pick| switch (source) {
            .draft => |draft| pick.revision == draft.revision,
            else => false,
        } else false;
        const current_list = self.current(source);
        const shown = current_list orelse if (drawn) (if (self.shown) |*list| list else null) else null;
        const list = shown orelse return false;
        list.close();
        self.drawn_pick = null;
        if (source == .draft) self.closed_draft_revision = source.draft.revision;
        return true;
    }

    fn keepClosed(self: *Menu, source: Source) void {
        if (source == .draft and self.closed_draft_revision == source.draft.revision) {
            if (self.shown) |*shown| shown.close();
        }
    }

    /// Preview without changing the shown list, its strings, or drawn authority.
    /// Skill row text is temporary here, so only the selected identity escapes.
    pub fn accepting(self: *const Menu, source: Source, how: How) ?Accepted {
        var rows: skills.Rows = .{};
        const next = build(&rows, self.shown, source) orelse return null;
        if (next.seen != .drawn) return null;
        const pick = switch (how) {
            .enter => next.pick(next.highlight),
            .pick => |pressed| blk: {
                if (next.revision != pressed.revision or next.source != pressed.source) return null;
                if (pressed.index >= next.list.count) return null;
                break :blk pressed;
            },
        };
        return .{ .pick = pick };
    }

    /// Materialize the accepted list in the owner's stable row storage, before
    /// the shell applies editor/command effects that can invalidate the Source.
    pub fn accept(self: *Menu, source: Source, taken: Accepted) *commands.Shown {
        self.shown = build(&self.rows, self.shown, source).?;
        const shown = &self.shown.?;
        std.debug.assert(shown.seen == .drawn);
        std.debug.assert(shown.revision == taken.pick.revision and shown.source == taken.pick.source);
        std.debug.assert(taken.pick.index < shown.list.count);
        shown.highlight = taken.pick.index;
        return shown;
    }

    pub fn reset(self: *Menu) void {
        self.shown = null;
        self.drawn_pick = null;
        self.closed_draft_revision = null;
    }
};

fn build(rows: *skills.Rows, previous: ?commands.Shown, source: Source) ?commands.Shown {
    return switch (source) {
        .none => null,
        .draft => |draft| draft.skills.shown(rows, draft.bytes, draft.caret, draft.revision, draft.context, previous),
        .requests => |requests| commands.Shown.nextOf(previous, requests.revision, requests.source, requests.list),
    };
}

// Expectations below come from the base Shown/skill_completion lifecycle
// tests and SessionFrontend acceptance tests. The runtime sequence table also
// uses the independent base-5039d9d5 HeldFrontend capture documented below.
const MenuTest = struct {
    const Start = enum { none, hidden, drawn, closed };
    const entries = [_]@import("skill_suggestions.zig").Entry{
        .{ .name = "recap", .description = "Summarise" },
        .{ .name = "review", .description = "Review a change" },
    };

    menu: Menu = .{},
    reads: skills.Reads = .{},
    source: Source = .none,
    first_pick: Pick = undefined,

    fn init(self: *MenuTest, start: Start) void {
        self.* = .{};
        // Define even unused text so the purity check can compare the whole bank.
        @memset(std.mem.asBytes(&self.menu.rows), 0);
        self.load(&entries);
        self.source = self.draft("use /re and /re", "use /re".len, 7);
        const shown = self.menu.frame(self.source).?;
        self.first_pick = shown.pick(0);
        switch (start) {
            .none => self.menu.reset(),
            .hidden => self.menu.drew(false, self.first_pick),
            .drawn => self.menu.drew(true, self.first_pick),
            .closed => {
                self.menu.drew(true, self.first_pick);
                shown.close();
            },
        }
    }

    fn load(self: *MenuTest, entries_: []const @import("skill_suggestions.zig").Entry) void {
        _ = self.reads.reset();
        const asked = self.reads.ask("").?;
        const unheld = self.reads.answer(asked.read, .{ .entries = entries_, .total = entries_.len }, "");
        std.debug.assert(unheld == null);
    }

    fn draft(self: *const MenuTest, bytes: []const u8, caret: usize, revision: u64) Source {
        return .{ .draft = .{ .bytes = bytes, .caret = caret, .revision = revision, .skills = &self.reads } };
    }

    fn draw(self: *MenuTest, visible: bool) void {
        if (self.menu.frame(self.source)) |shown| self.menu.drew(visible, shown.pick(shown.highlight));
    }

    fn requests(revision: u64, source: u64, reversed: bool) Source {
        var list: commands.List = .{ .typed = "", .count = 2 };
        const first: commands.Entry = .{ .word = "/result first", .shown = "/result first", .description = "09:00 · saved answer" };
        const second: commands.Entry = .{ .word = "/result second", .shown = "/result second", .description = "09:05 · saved answer" };
        list.entries[0] = if (reversed) second else first;
        list.entries[1] = if (reversed) first else second;
        return .{ .requests = .{ .revision = revision, .source = source, .list = list } };
    }
};

test "slash_menu sequence domain crosses every starting visibility with menu events" {
    const Event = enum {
        frame_fits,
        frame_hidden,
        edit,
        caret,
        skill_source,
        model_source,
        requests_source,
        previous,
        next,
        wheel_up,
        wheel_down,
        close,
        enter,
        pick,
        outside_pick,
        older_revision,
        older_source,
        reset,
    };
    const Case = struct { event: Event, accepted: [4]?usize };
    // Columns are none, hidden, drawn, closed. Edits inherit drawn eligibility
    // only from a drawn list; replacing its source never does.
    const cases = [_]Case{
        .{ .event = .frame_fits, .accepted = .{ 0, 0, 0, null } },
        .{ .event = .frame_hidden, .accepted = .{ null, null, null, null } },
        .{ .event = .edit, .accepted = .{ null, null, 0, null } },
        .{ .event = .caret, .accepted = .{ null, null, null, null } },
        .{ .event = .skill_source, .accepted = .{ null, null, null, null } },
        .{ .event = .model_source, .accepted = .{ null, null, null, null } },
        .{ .event = .requests_source, .accepted = .{ null, null, null, null } },
        .{ .event = .previous, .accepted = .{ null, null, 0, null } },
        .{ .event = .next, .accepted = .{ null, null, 1, null } },
        .{ .event = .wheel_up, .accepted = .{ null, null, 0, null } },
        .{ .event = .wheel_down, .accepted = .{ null, null, 1, null } },
        .{ .event = .close, .accepted = .{ null, null, null, null } },
        .{ .event = .enter, .accepted = .{ null, null, 0, null } },
        .{ .event = .pick, .accepted = .{ null, null, 1, null } },
        .{ .event = .outside_pick, .accepted = .{ null, null, null, null } },
        .{ .event = .older_revision, .accepted = .{ null, null, null, null } },
        .{ .event = .older_source, .accepted = .{ null, null, null, null } },
        .{ .event = .reset, .accepted = .{ null, null, null, null } },
    };
    for (std.enums.values(MenuTest.Start), 0..) |start, column| {
        for (cases) |case| {
            errdefer std.debug.print("slash_menu start={s} event={s}\n", .{ @tagName(start), @tagName(case.event) });
            var held: MenuTest = undefined;
            held.init(start);
            var how: How = .enter;
            switch (case.event) {
                .frame_fits => held.draw(true),
                .frame_hidden => held.draw(false),
                .edit => held.source = held.draft("use /rev and /re", "use /rev".len, 8),
                .caret => held.source.draft.caret = held.source.draft.bytes.len,
                .skill_source => held.load(&.{.{ .name = "renew", .description = "New source" }}),
                .model_source => {
                    held.source = held.draft("/effort ", "/effort ".len, 7);
                    held.source.draft.context.model = "gpt-4o";
                },
                .requests_source => held.source = MenuTest.requests(7, 91, false),
                .previous, .next, .wheel_up, .wheel_down => {
                    if (held.menu.current(held.source)) |shown| shown.move(case.event == .next or case.event == .wheel_down);
                },
                .close => {
                    if (held.menu.current(held.source)) |shown| shown.close();
                },
                .enter => {},
                .pick, .outside_pick, .older_revision, .older_source => {
                    var pressed = held.first_pick;
                    switch (case.event) {
                        .pick => pressed.index = 1,
                        .outside_pick => pressed.index = 2,
                        .older_revision => pressed.revision -= 1,
                        .older_source => pressed.source ^= 1,
                        else => unreachable,
                    }
                    how = .{ .pick = pressed };
                },
                .reset => held.menu.reset(),
            }
            const accepted = held.menu.accepting(held.source, how);
            try std.testing.expectEqual(case.accepted[column], if (accepted) |taken| taken.pick.index else null);
            if (accepted) |taken| {
                const shown = held.menu.accept(held.source, taken);
                try std.testing.expectEqual(case.accepted[column].?, shown.highlight);
                try std.testing.expectEqual(.drawn, shown.seen);
            }
            if (case.event == .reset) {
                try std.testing.expect(held.menu.shown == null);
                try std.testing.expect(held.menu.drawn_pick == null);
            }
        }
    }
}

test "slash_menu Enter follows edits and pending arrows while Tab keeps the last drawn index" {
    for ([_]bool{ false, true }) |wheel| {
        var held: MenuTest = undefined;
        held.init(.drawn);
        const drawn = held.menu.drawn_pick.?;
        // Palette wheel and keyboard navigation have the same selection effect.
        if (wheel) held.menu.shown.?.move(true) else held.menu.current(held.source).?.move(true);
        const enter = held.menu.accepting(held.source, .enter).?;
        const tab = held.menu.accepting(held.source, .{ .pick = drawn }).?;
        try std.testing.expectEqual(@as(usize, 1), enter.pick.index);
        try std.testing.expectEqual(@as(usize, 0), tab.pick.index);
        try std.testing.expectEqual(drawn, held.menu.drawn_pick.?);
        const selected = held.menu.accept(held.source, enter);
        try std.testing.expectEqualStrings("/review", selected.list.entries[selected.highlight].shown);
        // An edit before repaint resets Enter to the new list's first row and
        // invalidates the previous drawing's revision for Tab and clicks.
        held.source = held.draft("use /rev and /re", "use /rev".len, 8);
        try std.testing.expect(held.menu.accepting(held.source, .{ .pick = drawn }) == null);
        const edited = held.menu.accepting(held.source, .enter).?;
        try std.testing.expectEqual(@as(usize, 0), edited.pick.index);
        const current = held.menu.accept(held.source, edited);
        try std.testing.expectEqualStrings("/review", current.list.entries[0].shown);
        held.draw(true);
        try std.testing.expect(held.menu.accepting(held.source, .{ .pick = held.menu.drawn_pick.? }) != null);
    }
}

test "slash_menu acceptance is pure and materializes an edited winner absent from the drawn list" {
    var held: MenuTest = undefined;
    held.init(.drawn);
    held.source = held.draft("use /rec", "use /rec".len, 8);
    held.draw(true);
    try std.testing.expectEqual(@as(usize, 1), held.menu.shown.?.list.count);
    try std.testing.expectEqualStrings("/recap", held.menu.shown.?.list.entries[0].shown);
    const before = held.menu.shown.?;
    const before_text = held.menu.rows.text;
    const before_pick = held.menu.drawn_pick;
    held.source = held.draft("use /rev", "use /rev".len, 9);
    var decision: ?Accepted = null;
    for (0..3) |_| {
        decision = held.menu.accepting(held.source, .enter);
        try std.testing.expectEqual(@as(usize, 0), decision.?.pick.index);
        try std.testing.expect(held.menu.accepting(held.source, .{ .pick = before_pick.? }) == null);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before_text), std.mem.asBytes(&held.menu.rows.text));
        try std.testing.expectEqualDeep(before_pick, held.menu.drawn_pick);
        const after = held.menu.shown.?;
        try std.testing.expectEqual(before.revision, after.revision);
        try std.testing.expectEqual(before.source, after.source);
        try std.testing.expectEqual(before.highlight, after.highlight);
        try std.testing.expectEqual(before.seen, after.seen);
        try std.testing.expectEqual(before.list.count, after.list.count);
        try std.testing.expectEqualStrings(before.list.typed, after.list.typed);
        for (before.list.shown(), after.list.shown()) |old, current| try std.testing.expectEqualDeep(old, current);
    }
    // Only a scalar token escaped accepting's temporary stack; accept builds
    // /review, which did not have a row in the previous drawing, in Menu.rows.
    const accepted = held.menu.accept(held.source, decision.?);
    const entry = accepted.list.entries[accepted.highlight];
    try std.testing.expectEqualStrings("/review", entry.shown);
    try std.testing.expectEqualStrings("review ", entry.word);
    const row_begin = @intFromPtr(&held.menu.rows.text);
    const row_end = row_begin + @sizeOf(@TypeOf(held.menu.rows.text));
    try std.testing.expect(@intFromPtr(entry.word.ptr) >= row_begin);
    try std.testing.expect(@intFromPtr(entry.word.ptr) + entry.word.len <= row_end);
    const change = skills.enter(held.source.draft.bytes, held.source.draft.caret, accepted);
    try std.testing.expect(change == .edit);
    try std.testing.expectEqualStrings("review ", change.edit.text);
    try std.testing.expectEqual(@as(usize, "use /".len), change.edit.start);
    try std.testing.expectEqual(@as(usize, "use /rev".len), change.edit.end);
}

test "slash_menu close persists until edit and reopens hidden before a frame draws it" {
    for (std.enums.values(MenuTest.Start)) |start| {
        var held: MenuTest = undefined;
        held.init(start);
        if (held.menu.current(held.source)) |shown| shown.close();
        if (start == .drawn or start == .closed) {
            held.draw(true);
            try std.testing.expectEqual(.closed, held.menu.shown.?.seen);
            try std.testing.expectEqual(@as(usize, 0), held.menu.shown.?.rows());
            try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
            held.source = held.draft("use /rev and /re", "use /rev".len, 8);
            try std.testing.expect(held.menu.current(held.source) == null);
            try std.testing.expectEqual(.hidden, held.menu.shown.?.seen);
            try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
            held.draw(true);
            try std.testing.expect(held.menu.accepting(held.source, .enter) != null);
        }
        held.menu.reset();
        try std.testing.expect(held.menu.current(held.source) == null);
        try std.testing.expect(held.menu.accepting(held.source, .{ .pick = held.first_pick }) == null);
        held.draw(false);
        try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
        held.draw(true);
        try std.testing.expect(held.menu.accepting(held.source, .enter) != null);
    }
}

test "slash_menu close authority survives refresh navigation and repaint in every order" {
    const Event = enum { refresh, navigation, close, repaint };
    const events = std.enums.values(Event);
    for (events) |a| for (events) |b| for (events) |c| for (events) |d| {
        if (a == b or a == c or a == d or b == c or b == d or c == d) continue;
        const sequence = [_]Event{ a, b, c, d };
        errdefer std.debug.print("menu sequence {any}\n", .{sequence});
        var held: MenuTest = undefined;
        held.init(.drawn);
        const old_pick = held.menu.drawn_pick.?;
        var refreshed = false;
        var closed = false;
        for (sequence) |event| {
            switch (event) {
                .refresh => {
                    held.load(&.{.{ .name = "renew", .description = "New rows" }});
                    refreshed = true;
                },
                .navigation => if (held.menu.current(held.source)) |shown| shown.move(true),
                .close => {
                    try std.testing.expect(held.menu.closeIfDrawn(held.source));
                    closed = true;
                    try std.testing.expect(!held.menu.closeIfDrawn(held.source));
                },
                .repaint => held.draw(true),
            }
            if (refreshed) try std.testing.expect(held.menu.accepting(held.source, .{ .pick = old_pick }) == null);
            if (closed) try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
        }
        held.draw(true);
        try std.testing.expect(!held.menu.closeIfDrawn(held.source));
        try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
        held.source = held.draft("use /ren and /re", "use /ren".len, 8);
        held.draw(true);
        try std.testing.expect(held.menu.accepting(held.source, .enter) != null);
    };
}

test "slash_menu close refuses an undrawn or edited replacement after refresh" {
    var held: MenuTest = undefined;
    held.init(.drawn);
    const old_pick = held.menu.drawn_pick.?;
    held.load(&.{.{ .name = "renew", .description = "New rows" }});
    held.source = held.draft("use /ren and /re", "use /ren".len, 8);
    try std.testing.expect(held.menu.current(held.source) == null);
    try std.testing.expect(!held.menu.closeIfDrawn(held.source));
    try std.testing.expect(held.menu.accepting(held.source, .{ .pick = old_pick }) == null);
    held.draw(false);
    try std.testing.expect(!held.menu.closeIfDrawn(held.source));
    held.draw(true);
    try std.testing.expect(held.menu.closeIfDrawn(held.source));
    try std.testing.expect(!held.menu.closeIfDrawn(held.source));
}

test "slash_menu changed skill rows refuse every acceptance until repaint including with an edit" {
    for ([_]bool{ false, true }) |edit| {
        var held: MenuTest = undefined;
        held.init(.drawn);
        const drawn = held.menu.drawn_pick.?;
        held.load(&.{.{ .name = "renew", .description = "Replacement source" }});
        if (edit) held.source = held.draft("use /ren and /re", "use /ren".len, 8);
        try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
        try std.testing.expect(held.menu.accepting(held.source, .{ .pick = drawn }) == null);
        try std.testing.expect(held.menu.current(held.source) == null);
        held.draw(false);
        try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
        held.draw(true);
        const taken = held.menu.accepting(held.source, .enter).?;
        const shown = held.menu.accept(held.source, taken);
        try std.testing.expectEqualStrings("/renew", shown.list.entries[shown.highlight].shown);
        try std.testing.expect(held.menu.accepting(held.source, .{ .pick = drawn }) == null);
    }
}

test "slash_menu caret moves retain only the same word's drawn authority" {
    var held: MenuTest = undefined;
    held.init(.drawn);
    const draft = "a /re b /re";
    held.source = held.draft(draft, "a /re".len, 8);
    held.draw(true);
    held.menu.current(held.source).?.move(true);
    held.draw(true);
    const drawn = held.menu.drawn_pick.?;
    for ("a /".len.."a /re".len + 1) |caret| {
        held.source.draft.caret = caret;
        const accepted = held.menu.accepting(held.source, .{ .pick = drawn }).?;
        try std.testing.expectEqual(@as(usize, 1), accepted.pick.index);
    }
    held.source.draft.caret = draft.len;
    try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
    try std.testing.expect(held.menu.accepting(held.source, .{ .pick = drawn }) == null);
    held.draw(true);
    const second = held.menu.drawn_pick.?;
    try std.testing.expect(second.source != drawn.source);
    try std.testing.expectEqual(@as(usize, 0), second.index);
    try std.testing.expect(held.menu.accepting(held.source, .{ .pick = second }) != null);
    held.source.draft.caret = 0;
    try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
}

test "slash_menu effort model changes are new hidden lists until drawn" {
    const models = [_][]const u8{ "unlisted-model", "gpt-5.5", "gpt-4o" };
    for (models) |before| for (models) |after| {
        var held: MenuTest = undefined;
        held.init(.none);
        held.source = held.draft("/effort ", "/effort ".len, 7);
        held.source.draft.context.model = before;
        held.draw(true);
        held.menu.shown.?.highlight = held.menu.shown.?.list.count - 1;
        held.draw(true);
        const drawn = held.menu.drawn_pick.?;
        try std.testing.expectEqualStrings("default", held.menu.shown.?.list.entries[drawn.index].word);
        held.source.draft.context.model = after;
        const same = std.mem.eql(u8, before, after);
        try std.testing.expectEqual(same, held.menu.accepting(held.source, .enter) != null);
        try std.testing.expectEqual(same, held.menu.accepting(held.source, .{ .pick = drawn }) != null);
        _ = held.menu.current(held.source);
        held.draw(true);
        const fresh = held.menu.accepting(held.source, .enter).?;
        if (same) {
            try std.testing.expectEqual(drawn.index, fresh.pick.index);
        } else {
            try std.testing.expectEqual(@as(usize, 0), fresh.pick.index);
            try std.testing.expect(held.menu.accepting(held.source, .{ .pick = drawn }) == null);
        }
        const shown = held.menu.accept(held.source, fresh);
        if (std.mem.eql(u8, after, "gpt-4o")) {
            try std.testing.expectEqual(@as(usize, 1), shown.list.count);
            try std.testing.expectEqualStrings("default", shown.list.entries[0].word);
        }
        if (std.mem.eql(u8, after, "unlisted-model")) try std.testing.expectEqual(@as(usize, 7), shown.list.count);
    };
}

test "slash_menu empty draft requests preserve pending selection and reject replaced rows" {
    var held: MenuTest = undefined;
    held.init(.none);
    held.source = MenuTest.requests(7, 90, false);
    try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
    held.draw(true);
    const drawn = held.menu.drawn_pick.?;
    held.menu.current(held.source).?.move(true);
    const taken = held.menu.accepting(held.source, .enter).?;
    try std.testing.expectEqual(@as(usize, 1), taken.pick.index);
    try std.testing.expectEqual(@as(usize, 0), held.menu.accepting(held.source, .{ .pick = drawn }).?.pick.index);
    const shown = held.menu.accept(held.source, taken);
    const change = skills.enter("", 0, shown);
    try std.testing.expect(change == .run);
    try std.testing.expectEqualStrings("/result second", change.run.text);
    held.source = MenuTest.requests(7, 91, true);
    try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
    try std.testing.expect(held.menu.accepting(held.source, .{ .pick = drawn }) == null);
    held.draw(true);
    const fresh = held.menu.accepting(held.source, .enter).?;
    try std.testing.expectEqual(@as(usize, 0), fresh.pick.index);
    const changed = held.menu.accept(held.source, fresh);
    try std.testing.expectEqualStrings("/result second", changed.list.entries[0].word);
    changed.close();
    held.draw(true);
    try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
    held.source = MenuTest.requests(8, 91, true);
    try std.testing.expect(held.menu.current(held.source) == null);
    held.draw(true);
    try std.testing.expect(held.menu.accepting(held.source, .enter) != null);
    held.menu.reset();
    try std.testing.expect(held.menu.shown == null);
    try std.testing.expect(held.menu.drawn_pick == null);
}

test "slash_menu exact first ranking and name and description match spans survive acceptance" {
    var held: MenuTest = undefined;
    held.init(.none);
    const entries = [_]@import("skill_suggestions.zig").Entry{
        .{ .name = "triage", .description = "Ask for help sorting issues" },
        .{ .name = "review-help", .description = "Review a pull request" },
        .{ .name = "help-me", .description = "Pair on a task" },
        .{ .name = "help", .description = "Answer questions" },
    };
    held.load(&entries);
    held.source = held.draft("/help", "/help".len, 7);
    held.draw(true);
    const names = [_][]const u8{ "/help", "/help-me", "/review-help", "/triage" };
    const marks = [_]commands.MatchSpans{
        .{ .name = .{ .start = 1, .len = 4 } },
        .{ .name = .{ .start = 1, .len = 4 } },
        .{ .name = .{ .start = 8, .len = 4 } },
        .{ .description = .{ .start = 8, .len = 4 } },
    };
    try std.testing.expectEqual(@as(usize, 4), held.menu.shown.?.list.count);
    try std.testing.expectEqual(@as(?usize, 0), held.menu.shown.?.list.exact);
    try std.testing.expectEqualDeep(@as(?commands.Span, .{ .start = 0, .len = 5 }), held.menu.shown.?.list.exactWord());
    for (names, marks, 0..) |name, mark, index| {
        try std.testing.expectEqualStrings(name, held.menu.shown.?.list.entries[index].shown);
        try std.testing.expectEqualDeep(mark, held.menu.shown.?.list.entries[index].matches);
        var pressed = held.menu.drawn_pick.?;
        pressed.index = index;
        const accepted = held.menu.accepting(held.source, .{ .pick = pressed }).?;
        const shown = held.menu.accept(held.source, accepted);
        try std.testing.expectEqualStrings(name, shown.list.entries[shown.highlight].shown);
        try std.testing.expectEqualDeep(mark, shown.list.entries[shown.highlight].matches);
    }
}

test "slash_menu every caret and skill preview preserves rows whenever drawn authority survives" {
    // Migrates the base skill_completion all-caret lifecycle property through
    // Menu: equal drawn authority must describe the same rows and replacement.
    const Preview = enum { absent, pending, failed, held };
    const drafts = [_][]const u8{
        "/setup --permission-mode b", "/setup ",         "/copy c", "/effort hi", "/re",
        "/review this /re",           "use /re and /se", "/se /se", "/arch.foo",
    };
    const entries = [_]@import("skill_suggestions.zig").Entry{
        .{ .name = "review", .description = "Skill" },
        .{ .name = "setup-report", .description = "Skill" },
    };
    for (std.enums.values(Preview)) |preview| {
        for (drafts) |draft| {
            for (0..draft.len + 1) |from| {
                var held: MenuTest = undefined;
                held.init(.none);
                _ = held.reads.reset();
                switch (preview) {
                    .absent => {},
                    .pending => _ = held.reads.ask(""),
                    .failed => held.reads.fail(held.reads.ask("").?.read),
                    .held => held.load(&entries),
                }
                held.source = held.draft(draft, from, 7);
                held.source.draft.context.model = "gpt-5.5";
                const before = held.menu.frame(held.source) orelse continue;
                before.highlight = before.list.count - 1;
                held.menu.drew(true, before.pick(before.highlight));
                for (0..draft.len + 1) |to| {
                    errdefer std.debug.print("slash_menu caret preview={s} draft={s} from={d} to={d}\n", .{ @tagName(preview), draft, from, to });
                    held.source.draft.caret = to;
                    const token = held.menu.accepting(held.source, .enter) orelse continue;
                    // Build the other view in separate stable storage: the
                    // original row strings remain intact for the comparison.
                    var other: Menu = .{};
                    const after = other.frame(held.source).?;
                    after.highlight = token.pick.index;
                    try std.testing.expectEqual(before.source, token.pick.source);
                    try std.testing.expectEqual(before.highlight, token.pick.index);
                    try std.testing.expectEqualStrings(before.list.typed, after.list.typed);
                    try std.testing.expectEqual(before.list.count, after.list.count);
                    for (before.list.shown(), after.list.shown()) |old, current| {
                        try std.testing.expectEqualStrings(old.word, current.word);
                        try std.testing.expectEqualStrings(old.shown, current.shown);
                        try std.testing.expectEqualStrings(old.description, current.description);
                        try std.testing.expectEqual(old.runs, current.runs);
                        try std.testing.expectEqualDeep(old.matches, current.matches);
                    }
                    try std.testing.expectEqualDeep(skills.enter(draft, from, before), skills.enter(draft, to, after));
                }
            }
        }
    }
}

test "slash_menu current no match retains lifecycle until frame replaces or clears it" {
    var held: MenuTest = undefined;
    held.init(.drawn);
    held.menu.current(held.source).?.move(true);
    const kept_revision = held.menu.shown.?.revision;
    held.source = held.draft("ordinary message", "ordinary message".len, 8);
    try std.testing.expect(held.menu.current(held.source) == null);
    try std.testing.expectEqual(kept_revision, held.menu.shown.?.revision);
    try std.testing.expectEqual(@as(usize, 1), held.menu.shown.?.highlight);
    try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
    try std.testing.expect(held.menu.frame(held.source) == null);
    try std.testing.expect(held.menu.shown == null);
    held.source = held.draft("use /re", "use /re".len, 9);
    try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
    held.draw(true);
    try std.testing.expectEqual(@as(usize, 0), held.menu.accepting(held.source, .enter).?.pick.index);
    try std.testing.expect(held.menu.frame(.none) == null);
    try std.testing.expect(held.menu.accepting(held.source, .enter) == null);
}

test "slash_menu runtime baseline sequences preserve exact first rows and drawn versus current picks" {
    // Captured by the independent HeldFrontend fixture on base 5039d9d5:
    // /tmp/slash-baseline.log, ORACLE {none,hidden,drawn,closed}/{event}.
    // The menu's null decision corresponds to the fixture's ordinary Enter
    // submission or Tab footer navigation; those effects stay integration tests.
    const Event = enum {
        enter,
        tab,
        edit_enter,
        edit_tab,
        arrow_enter,
        arrow_tab,
        wheel_enter,
        wheel_tab,
        caret_enter,
        caret_tab,
        pick,
        edit_pick,
        caret_pick,
        close_edit,
        arrival_enter,
    };
    const Case = struct { event: Event, drawn_word: ?[]const u8 };
    const cases = [_]Case{
        .{ .event = .enter, .drawn_word = "re " },
        .{ .event = .tab, .drawn_word = "re " },
        .{ .event = .edit_enter, .drawn_word = "review " },
        .{ .event = .edit_tab, .drawn_word = null },
        .{ .event = .arrow_enter, .drawn_word = "recap " },
        .{ .event = .arrow_tab, .drawn_word = "re " },
        .{ .event = .wheel_enter, .drawn_word = "recap " },
        .{ .event = .wheel_tab, .drawn_word = "re " },
        .{ .event = .caret_enter, .drawn_word = "re " },
        .{ .event = .caret_tab, .drawn_word = "re " },
        .{ .event = .pick, .drawn_word = "re " },
        .{ .event = .edit_pick, .drawn_word = null },
        .{ .event = .caret_pick, .drawn_word = "re " },
        .{ .event = .close_edit, .drawn_word = "review " },
        .{ .event = .arrival_enter, .drawn_word = null },
    };
    const entries = [_]@import("skill_suggestions.zig").Entry{
        .{ .name = "other", .description = "Review by description" },
        .{ .name = "review", .description = "Review a change" },
        .{ .name = "recap", .description = "Summarise" },
        .{ .name = "re", .description = "Exact" },
    };
    for (std.enums.values(MenuTest.Start)) |start| {
        for (cases) |case| {
            errdefer std.debug.print("slash_menu runtime oracle start={s} event={s}\n", .{ @tagName(start), @tagName(case.event) });
            var held: MenuTest = undefined;
            held.init(.none);
            held.load(&entries);
            held.source = held.draft("Use /re", "Use /re".len, 1);
            const shown = held.menu.frame(held.source).?;
            const drawn = shown.pick(0);
            switch (start) {
                .none => held.menu.reset(),
                .hidden => held.menu.drew(false, drawn),
                .drawn => held.menu.drew(true, drawn),
                .closed => {
                    held.menu.drew(true, drawn);
                    shown.close();
                },
            }
            var how: How = .enter;
            switch (case.event) {
                .enter, .tab, .pick => {},
                .edit_enter, .edit_tab, .edit_pick => held.source = held.draft("Use /rev", "Use /rev".len, 2),
                .arrow_enter, .arrow_tab => {
                    if (held.menu.current(held.source)) |current| current.move(true);
                },
                .wheel_enter, .wheel_tab => {
                    if (held.menu.shown) |*current| if (current.seen == .drawn) current.move(true);
                },
                .caret_enter, .caret_tab, .caret_pick => held.source.draft.caret -= 1,
                .close_edit => {
                    if (held.menu.current(held.source)) |current| current.close();
                    held.source = held.draft("Use /rev", "Use /rev".len, 2);
                    held.draw(true);
                },
                .arrival_enter => held.load(&.{.{ .name = "remote", .description = "New page" }}),
            }
            switch (case.event) {
                .tab, .edit_tab, .arrow_tab, .wheel_tab, .caret_tab => how = .{ .pick = drawn },
                .pick, .edit_pick, .caret_pick => {
                    how = .{ .pick = drawn };
                },
                else => {},
            }
            const expected = if (start == .drawn or case.event == .close_edit) case.drawn_word else null;
            const token = held.menu.accepting(held.source, how);
            try std.testing.expectEqual(expected != null, token != null);
            if (token) |accepted| {
                const current = held.menu.accept(held.source, accepted);
                const change = skills.enter(held.source.draft.bytes, held.source.draft.caret, current);
                try std.testing.expect(change == .edit);
                try std.testing.expectEqualStrings(expected.?, change.edit.text);
            }
        }
    }
}
