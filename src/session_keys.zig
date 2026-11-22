const std = @import("std");
const keymap = @import("keymap.zig");
const ConsentPolicy = @import("session_consent.zig");
const ActionConsent = @import("ActionConsent.zig");
const session_chrome = @import("session_chrome.zig");

pub const Action = enum {
    page_up,
    page_down,
    previous,
    next,
    scroll_up,
    scroll_down,
    older,
    newer,
    latest,
    close,
    expand,
    detach,
    recover,
    stop,
    archive,
};

pub const keys: keymap.Keymap(Action) = .init(.{
    .escape = .close,
    .ctrl_g = .close,
    .ctrl_c = .detach,
    .ctrl_d = .detach,
    .ctrl_n = .newer,
    .ctrl_o = .expand,
    .ctrl_p = .older,
    .ctrl_r = .recover,
    .ctrl_x = .stop,
    .alt_a = .archive,
    .alt_question = null,
    .alt_up = null,
    .alt_down = null,
    .up = .previous,
    .down = .next,
    .left = null,
    .right = null,
    // Focus order's keys: `app_input.keys` takes them first, and an open
    // panel moves its own rows with them.
    .tab = null,
    .shift_tab = null,
    .shift_up = .scroll_up,
    .shift_down = .scroll_down,
    .page_up = .page_up,
    .page_down = .page_down,
    .home = null,
    .end = .latest,
    .ctrl_end = .latest,
});

pub const Selection = keymap.Selection(Action);

pub fn panelAction(selected: Selection) ?Action {
    if (selected != .action) return null;
    return switch (selected.action) {
        .detach, .recover, .stop, .archive => selected.action,
        else => null,
    };
}

test "chat info leaves Session-wide actions with the conversation owner" {
    for (std.enums.values(Action)) |action| {
        const expected: ?Action = switch (action) {
            .detach, .recover, .stop, .archive => action,
            else => null,
        };
        try std.testing.expectEqual(expected, panelAction(.{ .action = action }));
    }
    try std.testing.expectEqual(@as(?Action, null), panelAction(.none));
    try std.testing.expectEqual(@as(?Action, null), panelAction(.enter));
}

pub fn clearsOverviewNotice(selected: Selection, opening: bool) bool {
    const steps_overview = selected == .action and (selected.action == .stop or selected.action == .archive);
    return opening or !steps_overview;
}

pub const AtChoice = union(enum) {
    nothing,
    say: []const u8,
    perform: Action,
    pick: ConsentPolicy.Choice,
    confirm,
    draft,
};

pub fn atChoice(selected: Selection, command_holds: bool) AtChoice {
    return switch (selected) {
        .none => .nothing,
        .action => |action| switch (action) {
            .recover => .{ .say = "! Action needs a decision; nothing to retry." },
            .older, .newer => .nothing,
            else => .{ .perform = action },
        },
        .left => .{ .pick = .allow_once },
        .right => .{ .pick = .deny },
        .enter => .confirm,
        .text => if (command_holds) .{ .say = "! Command still running. Input ignored." } else .draft,
        .refused => .{ .say = "! Key combination not recognized; nothing authorized." },
    };
}

test "Ctrl-X and Alt-A keep the overview's notice once the Session opens; every other input clears it" {
    try std.testing.expect(!clearsOverviewNotice(.{ .action = .stop }, false));
    try std.testing.expect(!clearsOverviewNotice(.{ .action = .archive }, false));
    for ([_]Selection{ .enter, .text, .{ .action = .close }, .{ .action = .page_up } }) |selected| {
        try std.testing.expect(clearsOverviewNotice(selected, false));
    }
    try std.testing.expect(clearsOverviewNotice(.{ .action = .stop }, true));
}

test "at the choice only the arrows and Enter act; typing moves to the draft unless a command holds the choice" {
    try std.testing.expectEqual(AtChoice{ .pick = .allow_once }, atChoice(.left, false));
    try std.testing.expectEqual(AtChoice{ .pick = .deny }, atChoice(.right, false));
    try std.testing.expectEqual(AtChoice.confirm, atChoice(.enter, true));
    try std.testing.expectEqual(AtChoice.draft, atChoice(.text, false));
    try std.testing.expectEqualStrings("! Command still running. Input ignored.", atChoice(.text, true).say);
    try std.testing.expectEqualStrings("! Key combination not recognized; nothing authorized.", atChoice(.refused, false).say);
    try std.testing.expectEqualStrings("! Action needs a decision; nothing to retry.", atChoice(.{ .action = .recover }, false).say);
    try std.testing.expectEqual(AtChoice.nothing, atChoice(.none, false));
    try std.testing.expectEqual(AtChoice.nothing, atChoice(.{ .action = .older }, false));
    try std.testing.expectEqual(AtChoice.nothing, atChoice(.{ .action = .newer }, false));
    for ([_]Action{ .stop, .detach, .close, .page_up, .expand }) |action| {
        try std.testing.expectEqual(AtChoice{ .perform = action }, atChoice(.{ .action = action }, false));
    }
}

test "the conversation binds Ctrl-X to stop, Alt-A to archive and Esc and Ctrl-G to close, and leaves Home unbound" {
    try std.testing.expectEqual(@as(?Action, .stop), keys.get(.ctrl_x));
    try std.testing.expectEqual(@as(?Action, .archive), keys.get(.alt_a));
    try std.testing.expectEqual(@as(?Action, .close), keys.get(.escape));
    try std.testing.expectEqual(@as(?Action, .close), keys.get(.ctrl_g));
    try std.testing.expectEqual(@as(?Action, null), keys.get(.home));
    try std.testing.expectEqual(@as(?Action, .latest), keys.get(.end));
    try std.testing.expectEqual(@as(?Action, .latest), keys.get(.ctrl_end));
}

pub const Key = union(enum) {
    named: keymap.Key,
    enter,
    /// `r`, which starts a stopped Host from an empty draft; else text.
    host_start,
    info,
    details,
    text,
    other,
    paste_start,
    paste_end,
};

pub const Input = struct {
    key: Key,
    pasted: bool = false,

    pub fn action(input: Input) ?Action {
        if (input.pasted) return null;
        return switch (input.key) {
            .named => |name| keys.get(name),
            else => null,
        };
    }

    pub fn closes(input: Input) bool {
        if (input.pasted) return false;
        return switch (input.key) {
            .named => |name| name == .escape or name == .ctrl_g,
            else => false,
        };
    }
};

pub const Facts = struct {
    info_open: bool = false,
    info_choice: bool = false,
    choice: Choice = .closed,
    has_effort: bool = false,
    saving: bool = false,
    details: bool = false,
    draft_empty: bool = true,
    host_startable: bool = false,
    /// Whether slash_menu.Menu accepted this key's Enter or drawn-pick intent.
    shown_row: bool = false,
    send: Send = .{},

    pub const Choice = enum {
        closed,
        pending,
        shown,
    };

    pub const Send = struct {
        host_held: bool = false,
        opening: bool = false,
        preparing: bool = false,
        command_active: bool = false,
        submitting: bool = false,

        /// Why Enter sends nothing, most pressing first; the refusal notice
        /// reads this same value, so every refused send names its reason.
        pub const Refusal = enum { command, host, opening, preparing, submitting };

        pub fn refusal(send: Send) ?Refusal {
            if (send.command_active) return .command;
            if (send.host_held) return .host;
            if (send.opening) return .opening;
            if (send.preparing) return .preparing;
            if (send.submitting) return .submitting;
            return null;
        }

        pub fn allowed(send: Send) bool {
            return send.refusal() == null;
        }
    };
};

/// The state `step` routes: app-owned focus and the Action's choice,
/// present only while an Action waits for a decision.
pub const State = struct {
    footer: *session_chrome.Footer,
    focus: *@import("app_input.zig").State,
    consent: ?*ActionConsent = null,
};

pub const Take = union(enum) {
    taken,
    close_choice,
    panel,
    cancel_panel_choice,
    close_info,
    panel_details,
    perform: Action,
    open_choice,
    start_host,
    open_info,
    details,
    card: ActionConsent.Input,
    needs_decision,
    consent_draft,
    take_row,
    back_to_list,
    edit: struct { send: bool },
};

pub fn step(state: State, facts: Facts, input: Input) Take {
    const action = input.action();
    if (!facts.info_open and facts.choice != .closed and input.closes()) return .close_choice;
    if (facts.info_open or facts.choice == .shown) {
        if (facts.info_open and facts.details and !input.pasted and input.key == .details) return .panel_details;
        if (action) |name| if (panelAction(.{ .action = name })) |panel| return .{ .perform = panel };
        if (input.closes()) return if (facts.info_choice) .cancel_panel_choice else .close_info;
        return .panel;
    }
    if (input.key == .named and input.key.named == .tab and !input.pasted and facts.shown_row and !facts.draft_empty and state.focus.field == .input and state.consent == null) return .take_row;
    // Root normally takes traversal. With no drawn target, use that same
    // order owner over the footer fields rather than a second cycle policy.
    if (!input.pasted and input.key == .named) {
        const focus = @import("app_input.zig");
        if (focus.keys.get(input.key.named)) |move| {
            _ = focus.step(state.focus, .{}, .{ .footer_tab = .{ .has_effort = facts.has_effort, .reverse = move == .previous } });
            state.footer.pending = null;
            return .taken;
        }
    }
    switch (footer(state.footer, state.focus, .{ .has_effort = facts.has_effort, .opens = !facts.info_open and !facts.saving }, footerKey(input))) {
        .open_choice => return .open_choice,
        .taken => return .taken,
        .forward => {},
    }
    if (input.key == .host_start and !input.pasted and facts.draft_empty and facts.host_startable) return .start_host;
    if (!input.pasted and input.key == .info) return .open_info;
    if (!input.pasted and input.key == .details and facts.details) return .details;
    if (state.consent) |consent| return switch (consent.route(rowKey(input))) {
        .screen => .{ .perform = action.? },
        .selector => switch (input.key) {
            .enter => .{ .card = .enter },
            .named => |name| switch (name) {
                .left => .{ .card = .left },
                .right => .{ .card = .right },
                else => .taken,
            },
            .paste_end => .{ .card = .cancel },
            else => .taken,
        },
        .blocked => if (input.key == .enter) .needs_decision else .taken,
        .draft => .consent_draft,
    };
    const draft_key: @import("app_input.zig").DraftKey = if (input.key == .named and input.key.named == .left and state.focus.field == .input) .left else .other;
    if (!input.pasted and @import("app_input.zig").draftKey(facts.draft_empty, draft_key) == .list) return .back_to_list;
    if (input.key == .enter and !input.pasted and facts.shown_row) return .take_row;
    return .{ .edit = .{ .send = facts.send.allowed() } };
}

pub fn rowKey(input: Input) ActionConsent.RowKey {
    if (input.pasted) return if (input.key == .paste_end) .other else .paste;
    if (input.action()) |action| return if (action == .close) .escape else .screen;
    return switch (input.key) {
        .enter => .enter,
        .named => |name| if (name == .left or name == .right) .arrows else .other,
        .text, .host_start => .printable,
        .paste_start => .paste,
        .info, .details, .other, .paste_end => .other,
    };
}

pub const FooterTake = enum {
    open_choice,
    taken,
    forward,
};

pub const FooterFacts = struct {
    has_effort: bool,
    opens: bool,
};

/// Steps footer focus, for a key or a click: a choice it opens while none
/// may opens nothing.
pub fn footer(focus: *session_chrome.Footer, owner: *@import("app_input.zig").State, facts: FooterFacts, input: session_chrome.FooterInput) FooterTake {
    const decision = focus.step(owner, facts.has_effort, input);
    if (decision.open_choice != null) {
        if (facts.opens) return .open_choice;
        focus.pending = null;
    }
    return if (decision.forward) .forward else .taken;
}

fn footerKey(input: Input) session_chrome.FooterInput {
    if (input.key == .paste_start) return .text;
    if (input.pasted) return .other;
    if (input.closes()) return .escape;
    return switch (input.key) {
        .enter => .enter,
        .text, .host_start => .text,
        else => .other,
    };
}

test "every key Root hands the Session means one thing in each Session state" {
    const Setup = enum { plain, selector, draft_row, footer_focused, choice_shown, choice_pending, info_open, info_choice, host_held, opening, preparing, command_active, submitting, shown_row };
    const Pressed = enum { printable, pasted_printable, enter, pasted_enter, escape, ctrl_g, ctrl_c, ctrl_d, left, right, tab, shift_tab, host_start, info, details, paste_start, paste_end };
    const Focus = session_chrome.FooterFocus;
    const Row = ConsentPolicy.Row;
    const Expected = struct {
        setups: []const Setup,
        keys: []const Pressed,
        take: Take,
        focus: ?Focus = null,
        row: ?Row = null,
    };
    const closing = [_]Pressed{ .escape, .ctrl_g };
    const leaving = [_]Pressed{ .ctrl_c, .ctrl_d };
    const main = [_]Setup{ .plain, .choice_pending, .host_held, .opening, .preparing, .command_active, .submitting, .shown_row };
    const sends = [_]Setup{ .plain, .choice_pending, .shown_row };
    const held = [_]Setup{ .host_held, .opening, .preparing, .command_active, .submitting };
    const edits = [_]Pressed{ .printable, .pasted_printable, .pasted_enter, .ctrl_c, .ctrl_d, .right, .paste_start, .paste_end };
    const send: Take = .{ .edit = .{ .send = true } };
    const hold: Take = .{ .edit = .{ .send = false } };
    const rows = [_]Expected{
        .{ .setups = &.{ .plain, .choice_pending, .host_held, .opening, .preparing, .command_active, .submitting }, .keys = &.{.left}, .take = .back_to_list },
        .{ .setups = &.{.shown_row}, .keys = &.{.left}, .take = send },
        .{ .setups = &sends, .keys = &(edits ++ [_]Pressed{ .host_start, .details }), .take = send },
        .{ .setups = &held, .keys = &edits, .take = hold },
        .{ .setups = &.{ .plain, .choice_pending }, .keys = &.{.enter}, .take = send },
        .{ .setups = &.{.shown_row}, .keys = &.{ .enter, .tab }, .take = .take_row },
        .{ .setups = &held, .keys = &.{.enter}, .take = hold },
        .{ .setups = &.{ .plain, .shown_row }, .keys = &closing, .take = send },
        .{ .setups = &held, .keys = &closing, .take = hold },
        .{ .setups = &.{.choice_pending}, .keys = &closing, .take = .close_choice },
        .{ .setups = &.{.host_held}, .keys = &.{.host_start}, .take = .start_host },
        .{ .setups = &.{ .opening, .preparing, .command_active, .submitting }, .keys = &.{.host_start}, .take = hold },
        .{ .setups = &.{.submitting}, .keys = &.{.details}, .take = .details },
        .{ .setups = &.{ .host_held, .opening, .preparing, .command_active }, .keys = &.{.details}, .take = hold },
        .{ .setups = &main, .keys = &.{.info}, .take = .open_info },

        // Footer focus takes Tab outside the drawn list, and always Shift-Tab.
        .{ .setups = &.{ .plain, .choice_pending, .host_held, .opening, .preparing, .command_active, .submitting, .selector, .draft_row }, .keys = &.{.tab}, .take = .taken, .focus = .model },
        .{ .setups = &(main ++ [_]Setup{ .selector, .draft_row }), .keys = &.{.shift_tab}, .take = .taken, .focus = .effort },

        .{ .setups = &.{.footer_focused}, .keys = &.{.tab}, .take = .taken, .focus = .effort },
        .{ .setups = &.{.footer_focused}, .keys = &.{.shift_tab}, .take = .taken, .focus = .input },
        // Focus on the footer's model.
        .{ .setups = &.{.footer_focused}, .keys = &.{ .printable, .host_start, .paste_start }, .take = send, .focus = .input },
        .{ .setups = &.{.footer_focused}, .keys = &.{ .pasted_printable, .pasted_enter, .ctrl_c, .ctrl_d, .left, .right, .details, .paste_end }, .take = send },
        .{ .setups = &.{.footer_focused}, .keys = &.{.enter}, .take = .open_choice, .focus = .input },
        .{ .setups = &.{.footer_focused}, .keys = &closing, .take = .taken, .focus = .input },
        .{ .setups = &.{.footer_focused}, .keys = &.{.info}, .take = .open_info },
        .{ .setups = &.{ .choice_shown, .info_open, .info_choice }, .keys = &leaving, .take = .{ .perform = .detach } },
        .{ .setups = &.{.choice_shown}, .keys = &closing, .take = .close_choice },
        .{ .setups = &.{.info_open}, .keys = &closing, .take = .close_info },
        .{ .setups = &.{.info_choice}, .keys = &closing, .take = .cancel_panel_choice },
        .{ .setups = &.{.info_open}, .keys = &.{.details}, .take = .panel_details },
        .{ .setups = &.{ .choice_shown, .info_choice }, .keys = &.{.details}, .take = .panel },
        .{ .setups = &.{ .choice_shown, .info_open, .info_choice }, .keys = &.{ .printable, .pasted_printable, .enter, .pasted_enter, .left, .right, .tab, .shift_tab, .host_start, .info, .paste_start, .paste_end }, .take = .panel },
        .{ .setups = &.{.selector}, .keys = &.{ .printable, .host_start, .pasted_printable, .pasted_enter, .paste_start }, .take = .consent_draft, .row = .draft },
        .{ .setups = &.{.selector}, .keys = &.{.enter}, .take = .{ .card = .enter } },
        .{ .setups = &.{.selector}, .keys = &.{.left}, .take = .{ .card = .left } },
        .{ .setups = &.{.selector}, .keys = &.{.right}, .take = .{ .card = .right } },
        .{ .setups = &.{.selector}, .keys = &.{.paste_end}, .take = .{ .card = .cancel } },
        .{ .setups = &.{.selector}, .keys = &closing, .take = .{ .perform = .close } },
        .{ .setups = &.{.selector}, .keys = &leaving, .take = .{ .perform = .detach } },
        .{ .setups = &.{.selector}, .keys = &.{.details}, .take = .taken },
        .{ .setups = &.{ .selector, .draft_row }, .keys = &.{.info}, .take = .open_info },
        .{ .setups = &.{.draft_row}, .keys = &.{.enter}, .take = .needs_decision },
        .{ .setups = &.{.draft_row}, .keys = &closing, .take = .taken, .row = .selector },
        .{ .setups = &.{.draft_row}, .keys = &(edits ++ [_]Pressed{ .left, .host_start, .details }), .take = .consent_draft },
    };
    const Case = struct {
        fn has(comptime T: type, set: []const T, value: T) bool {
            return std.mem.indexOfScalar(T, set, value) != null;
        }
        fn input(pressed: Pressed) Input {
            return switch (pressed) {
                .printable => .{ .key = .text },
                .pasted_printable => .{ .key = .text, .pasted = true },
                .enter => .{ .key = .enter },
                .pasted_enter => .{ .key = .enter, .pasted = true },
                .escape => .{ .key = .{ .named = .escape } },
                .ctrl_g => .{ .key = .{ .named = .ctrl_g } },
                .ctrl_c => .{ .key = .{ .named = .ctrl_c } },
                .ctrl_d => .{ .key = .{ .named = .ctrl_d } },
                .left => .{ .key = .{ .named = .left } },
                .right => .{ .key = .{ .named = .right } },
                .tab => .{ .key = .{ .named = .tab } },
                .shift_tab => .{ .key = .{ .named = .shift_tab } },
                .host_start => .{ .key = .host_start },
                .info => .{ .key = .info },
                .details => .{ .key = .details },
                .paste_start => .{ .key = .paste_start, .pasted = true },
                .paste_end => .{ .key = .paste_end },
            };
        }
        fn facts(setup: Setup) Facts {
            return .{
                .info_open = setup == .info_open or setup == .info_choice,
                .info_choice = setup == .info_choice,
                .choice = switch (setup) {
                    .choice_shown => .shown,
                    .choice_pending => .pending,
                    else => .closed,
                },
                .has_effort = true,
                .details = setup == .submitting or setup == .info_open,
                .draft_empty = setup != .shown_row,
                .host_startable = setup == .host_held,
                .shown_row = setup == .shown_row,
                .send = .{
                    .host_held = setup == .host_held,
                    .opening = setup == .opening,
                    .preparing = setup == .preparing,
                    .command_active = setup == .command_active,
                    .submitting = setup == .submitting,
                },
            };
        }
    };
    var used: [rows.len]bool = @splat(false);
    for (std.enums.values(Setup)) |setup| for (std.enums.values(Pressed)) |pressed| {
        errdefer std.debug.print("setup={s} key={s}\n", .{ @tagName(setup), @tagName(pressed) });
        var matched: ?usize = null;
        for (rows, 0..) |row, index| {
            if (!Case.has(Setup, row.setups, setup) or !Case.has(Pressed, row.keys, pressed)) continue;
            try std.testing.expectEqual(@as(?usize, null), matched);
            matched = index;
        }
        const row = rows[matched.?];
        used[matched.?] = true;

        var focus_owner: @import("app_input.zig").State = .{ .field = if (setup == .footer_focused) .model else .input };
        var footer_state: session_chrome.Footer = .{};
        const focus = focus_owner.field;
        var consent: ActionConsent = .{};
        consent.adopt(17);
        if (setup == .draft_row) consent.row = .draft;
        const before = consent.row;
        const waits = setup == .selector or setup == .draft_row;
        const take = step(.{ .footer = &footer_state, .focus = &focus_owner, .consent = if (waits) &consent else null }, Case.facts(setup), Case.input(pressed));
        try std.testing.expectEqual(row.take, take);
        try std.testing.expectEqual(row.focus orelse focus, focus_owner.field);
        try std.testing.expectEqual(row.row orelse before, consent.row);
        try std.testing.expectEqual(@as(?session_chrome.FooterField, if (take == .open_choice) .model else null), footer_state.pending);
    };
    for (used) |hit| try std.testing.expect(hit);
}

test "drawn slash Tab acceptance preserves modal consent paste and footer focus owners" {
    const Case = struct {
        focus: session_chrome.FooterFocus = .input,
        info: bool = false,
        empty: bool = false,
        choice: Facts.Choice = .closed,
        consent: ?ConsentPolicy.Row = null,
        key: Key = .{ .named = .tab },
        pasted: bool = false,
        expected: Take,
        after: session_chrome.FooterFocus,
    };
    for ([_]Case{
        .{ .expected = .take_row, .after = .input },
        .{ .empty = true, .expected = .taken, .after = .model },
        .{ .choice = .pending, .expected = .take_row, .after = .input },
        .{ .focus = .model, .expected = .taken, .after = .effort },
        .{ .focus = .effort, .expected = .taken, .after = .input },
        .{ .info = true, .expected = .panel, .after = .input },
        .{ .choice = .shown, .expected = .panel, .after = .input },
        .{ .consent = .selector, .expected = .taken, .after = .model },
        .{ .consent = .draft, .expected = .taken, .after = .model },
        .{ .key = .{ .named = .shift_tab }, .expected = .taken, .after = .effort },
        .{ .pasted = true, .expected = .{ .edit = .{ .send = true } }, .after = .input },
    }) |case| {
        var focus_owner: @import("app_input.zig").State = .{ .field = case.focus };
        var footer_state: session_chrome.Footer = .{};
        var consent: ActionConsent = .{};
        consent.adopt(17);
        consent.row = case.consent orelse .selector;
        try std.testing.expectEqualDeep(case.expected, step(.{ .footer = &footer_state, .focus = &focus_owner, .consent = if (case.consent != null) &consent else null }, .{
            .info_open = case.info,
            .draft_empty = case.empty,
            .choice = case.choice,
            .has_effort = true,
            .shown_row = true,
        }, .{ .key = case.key, .pasted = case.pasted }));
        try std.testing.expectEqual(case.after, focus_owner.field);
    }
}
