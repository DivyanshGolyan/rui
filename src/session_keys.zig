//! What a key does in a conversation, decided over values
//! `SessionFrontend` read: the conversation's one key table, which inputs
//! clear the overview's notice, what an input does at an Action's
//! Allow once / Deny choice, what each key is to its row policy
//! (`rowKey`), and which owner each key Root hands the Session goes to
//! (`step`). The shell decodes the key, spends the
//! offer and carries out what these return.
const std = @import("std");
const keymap = @import("keymap.zig");
const ConsentPolicy = @import("session_consent.zig");
const ActionConsent = @import("ActionConsent.zig");
const session_chrome = @import("session_chrome.zig");

/// What a key does in a conversation, beside the draft or an Action's choice.
pub const Action = enum {
    page_up,
    page_down,
    /// Up and Down: the shown list's highlight, else a line of scrolling.
    previous,
    next,
    /// Shift-Up and Shift-Down: the shown list's highlight, else a line of
    /// scrolling.
    scroll_up,
    scroll_down,
    /// On an empty or recalled draft, the Message sent before the one it
    /// shows.
    older,
    /// On a recalled draft, the Message sent after it, or past the newest
    /// an empty draft.
    newer,
    /// The latest view, which is the pending Action if there is one:
    /// End without a draft, Ctrl-End, or a click on the `↓` marker.
    latest,
    /// Out of a Message page, else to the latest view, and from the settled
    /// latest view, once nothing would be lost, to the overview.
    close,
    /// Opens the lowest collapsed Message, or leaves a Message page.
    expand,
    /// Leaves the conversation; Host work continues.
    detach,
    /// Retries the uncertain original.
    recover,
    /// Stops the Session at once.
    stop,
    archive,
};

/// The conversation's one key table.
pub const keys: keymap.Keymap(Action) = .init(.{
    .escape = .close,
    // A lone ESC acts only once it expires; Ctrl-G acts at once.
    .ctrl_g = .close,
    .ctrl_c = .detach,
    .ctrl_d = .detach,
    .ctrl_n = .newer,
    .ctrl_o = .expand,
    .ctrl_p = .older,
    .ctrl_r = .recover,
    .ctrl_x = .stop,
    .alt_a = .archive,
    .up = .previous,
    .down = .next,
    .shift_up = .scroll_up,
    .shift_down = .scroll_down,
    .page_up = .page_up,
    .page_down = .page_down,
    .home = null,
    // The editor takes End while a draft gives it a line to edit.
    .end = .latest,
    .ctrl_end = .latest,
});

/// One input as the conversation's table classifies it.
pub const Selection = keymap.Selection(Action);

/// Modal fields own navigation and editing, never Session-wide custody or work.
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

/// Whether an input clears the overview's notice: every input but Ctrl-X
/// and Alt-A, which step the overview themselves once the Session opens.
/// Until the opening read they do nothing there, so they clear it too.
pub fn clearsOverviewNotice(selected: Selection, opening: bool) bool {
    const steps_overview = selected == .action and (selected.action == .stop or selected.action == .archive);
    return opening or !steps_overview;
}

/// What an input does at the choice. Only the arrows and Enter act on it.
pub const AtChoice = union(enum) {
    nothing,
    say: []const u8,
    perform: Action,
    pick: ConsentPolicy.Choice,
    confirm,
    /// Typing moves to the draft beside the Action, which takes this key.
    draft,
};

/// `command_holds`: a running command holds the choice, so neither a
/// Message nor a command could go.
pub fn atChoice(selected: Selection, command_holds: bool) AtChoice {
    return switch (selected) {
        .none => .nothing,
        .action => |action| switch (action) {
            // While an Action waits there is no original to retry.
            .recover => .{ .say = "! Action needs a decision; nothing to retry." },
            // The draft is not the choice's; its sent Messages wait.
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
    // Before the opening read, Ctrl-X and Alt-A step nothing.
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
    // Every other action is the conversation's own, Ctrl-D leaving it.
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

/// One terminal input as the Session's shell names it. Bindings match
/// exact modifiers, as the line editor's do.
pub const Key = union(enum) {
    /// A key the line editor names, bound in `keys` or not.
    named: keymap.Key,
    enter,
    /// The bare arrows, which move an Action's choice.
    left,
    right,
    tab,
    shift_tab,
    /// `r`, which starts a stopped Host from an empty draft; else text.
    host_start,
    /// Alt-I: the chat's info panel.
    info,
    /// Alt-D: the refused original's details, while there is one.
    details,
    /// Other typed text.
    text,
    /// Any other key: an edit key, a chord or a control.
    other,
    paste_start,
    paste_end,
    /// A malformed key sequence.
    invalid,
};

/// One input Root handed the Session.
pub const Input = struct {
    key: Key,
    /// It arrived inside a bracketed paste: text, never an action.
    pasted: bool = false,

    /// The conversation's action this input names; none for pasted text.
    pub fn action(input: Input) ?Action {
        if (input.pasted) return null;
        return switch (input.key) {
            .named => |name| keys.get(name),
            else => null,
        };
    }

    /// Esc or Ctrl-G, typed.
    pub fn closes(input: Input) bool {
        if (input.pasted) return false;
        return switch (input.key) {
            .named => |name| name == .escape or name == .ctrl_g,
            else => false,
        };
    }
};

/// What the Session's shell read for this input, owned elsewhere.
pub const Facts = struct {
    /// The chat's info panel is open.
    info_open: bool = false,
    /// The panel has its own choice or editor open over its rows.
    info_choice: bool = false,
    /// The footer's model or effort choice.
    choice: Choice = .closed,
    /// The Session's model has efforts, so the footer has an effort field.
    has_effort: bool = false,
    /// A save of the chat's settings waits, so no footer choice opens.
    saving: bool = false,
    /// A refused original's details can be shown.
    details: bool = false,
    draft_empty: bool = true,
    /// The Host is stopped and a start can mend it now.
    host_startable: bool = false,
    /// Enter on this draft takes the highlighted row of the list the
    /// latest frame drew.
    shown_row: bool = false,
    send: Send = .{},

    pub const Choice = enum {
        closed,
        /// An admitted save hides it until it settles; Esc still closes it.
        pending,
        shown,
    };

    /// What holds a Message: one submission at a time.
    pub const Send = struct {
        host_held: bool = false,
        opening: bool = false,
        /// An Action is being prepared for the person's decision.
        preparing: bool = false,
        command_active: bool = false,
        /// A decision or Message is in flight, or an original still held.
        submitting: bool = false,

        pub fn allowed(send: Send) bool {
            return !send.host_held and !send.opening and !send.preparing and !send.command_active and !send.submitting;
        }
    };
};

/// The state `step` moves: the footer's focus and the Action's choice,
/// present only while an Action waits for a decision.
pub const State = struct {
    footer: *session_chrome.Footer,
    consent: ?*ActionConsent = null,
};

/// What the shell does with the input.
pub const Take = union(enum) {
    /// The core took it whole; the shell redraws.
    taken,
    /// Close the footer's choice.
    close_choice,
    /// The open chat info panel, or the footer's shown choice, takes it.
    panel,
    /// Cancel the panel's own choice or editor.
    cancel_panel_choice,
    close_info,
    /// Close the panel, then show the refused original's details.
    panel_details,
    perform: Action,
    /// Open the footer's model or effort choice its focus chose.
    open_choice,
    start_host,
    open_info,
    details,
    /// The Action's choice takes this.
    card: ActionConsent.Input,
    /// Enter at the draft beside the Action: nothing sends before a decision.
    needs_decision,
    /// The draft beside the Action's choice edits with it; nothing sends.
    consent_draft,
    /// Enter takes the shown list's highlighted row into the draft.
    take_row,
    /// The line editor takes it; Enter sends a Message only when `send`.
    edit: struct { send: bool },
};

/// What one input Root handed the Session means, in order: an open panel
/// or footer choice; footer focus; the Host start key; Alt-I and Alt-D;
/// an Action's choice; else the draft, with Enter on a shown list's row.
pub fn step(state: State, facts: Facts, input: Input) Take {
    const action = input.action();
    if (!facts.info_open and facts.choice != .closed and input.closes()) return .close_choice;
    if (facts.info_open or facts.choice == .shown) {
        if (facts.info_open and facts.details and !input.pasted and input.key == .details) return .panel_details;
        // Panels own navigation and editing, never Session-wide custody or work.
        if (action) |name| if (panelAction(.{ .action = name })) |panel| return .{ .perform = panel };
        if (input.closes()) return if (facts.info_choice) .cancel_panel_choice else .close_info;
        return .panel;
    }
    switch (footer(state.footer, .{ .has_effort = facts.has_effort, .opens = !facts.info_open and !facts.saving }, footerKey(input))) {
        .open_choice => return .open_choice,
        .taken => return .taken,
        .forward => {},
    }
    // The empty-draft restart shortcut has no authority over a panel's input.
    if (input.key == .host_start and !input.pasted and facts.draft_empty and facts.host_startable) return .start_host;
    if (!input.pasted and input.key == .info) return .open_info;
    if (!input.pasted and input.key == .details and facts.details) return .details;
    if (state.consent) |consent| return switch (consent.route(rowKey(input))) {
        .screen => .{ .perform = action.? },
        .selector => switch (input.key) {
            .enter => .{ .card = .enter },
            .left => .{ .card = .left },
            .right => .{ .card = .right },
            .paste_end => .{ .card = .cancel },
            .invalid => .{ .card = .invalid },
            else => .taken,
        },
        .blocked => if (input.key == .enter) .needs_decision else .taken,
        .draft => .consent_draft,
    };
    const draft_key: @import("app_input.zig").DraftKey = if (input.closes()) .escape else if (input.key == .left and state.footer.focus == .input) .left else .other;
    if (!input.pasted and @import("app_input.zig").draftKey(facts.draft_empty, draft_key) == .back) return .{ .perform = .close };
    if (input.key == .enter and !input.pasted and facts.shown_row) return .take_row;
    return .{ .edit = .{ .send = facts.send.allowed() } };
}

/// What a key is to the Action's row policy. Pasted input is text, never
/// a choice or an action; the conversation's actions keep their meaning
/// in either row.
pub fn rowKey(input: Input) ActionConsent.RowKey {
    if (input.pasted) return if (input.key == .paste_end) .other else .paste;
    if (input.action()) |action| return if (action == .close) .escape else .screen;
    return switch (input.key) {
        .enter => .enter,
        .left, .right => .arrows,
        .text, .host_start => .printable,
        .paste_start => .paste,
        .named, .tab, .shift_tab, .info, .details, .other, .paste_end, .invalid => .other,
    };
}

/// What footer focus did with an input.
pub const FooterTake = enum {
    /// Its choice opens.
    open_choice,
    /// Focus took it.
    taken,
    /// It goes on to the input.
    forward,
};

pub const FooterFacts = struct {
    has_effort: bool,
    /// A choice may open now: no panel shows and no save waits.
    opens: bool,
};

/// Steps footer focus, for a key or a click: a choice it opens while none
/// may opens nothing.
pub fn footer(focus: *session_chrome.Footer, facts: FooterFacts, input: session_chrome.FooterInput) FooterTake {
    const decision = focus.step(facts.has_effort, input);
    if (decision.open_choice != null) {
        if (facts.opens) return .open_choice;
        focus.pending = null;
    }
    return if (decision.forward) .forward else .taken;
}

/// What a key means to footer focus.
fn footerKey(input: Input) session_chrome.FooterInput {
    if (input.key == .paste_start) return .text;
    if (input.pasted) return .other;
    if (input.closes()) return .escape;
    return switch (input.key) {
        .tab => .{ .tab = false },
        .shift_tab => .{ .tab = true },
        .enter => .enter,
        .text, .host_start => .text,
        else => .other,
    };
}

test "every key Root hands the Session means one thing in each Session state" {
    // Expectations are what SessionFrontend.appEvent, its capture handler
    // and the focused permission card decided in the shell at 625f5a3,
    // before this core took the Session's keys, except that a pasted key
    // at the Action's choice moves to its draft wherever focus was. Each
    // combination matches exactly one row, and every row matches some.
    const Setup = enum { plain, selector, draft_row, footer_focused, choice_shown, choice_pending, info_open, info_choice, host_held, opening, preparing, command_active, submitting, shown_row };
    const Pressed = enum { printable, pasted_printable, enter, pasted_enter, escape, ctrl_g, ctrl_c, ctrl_d, left, right, tab, shift_tab, host_start, info, details, paste_start, paste_end, invalid };
    const Focus = session_chrome.FooterFocus;
    const Row = ConsentPolicy.Row;
    const Expected = struct {
        setups: []const Setup,
        keys: []const Pressed,
        take: Take,
        /// Footer focus after the key; null leaves it as it was.
        focus: ?Focus = null,
        /// The Action's row after the key; null leaves it as it was.
        row: ?Row = null,
    };
    const closing = [_]Pressed{ .escape, .ctrl_g };
    const leaving = [_]Pressed{ .ctrl_c, .ctrl_d };
    // The input's own path: no panel, no Action, footer focus on the input.
    const main = [_]Setup{ .plain, .choice_pending, .host_held, .opening, .preparing, .command_active, .submitting, .shown_row };
    const sends = [_]Setup{ .plain, .choice_pending, .shown_row };
    const held = [_]Setup{ .host_held, .opening, .preparing, .command_active, .submitting };
    const edits = [_]Pressed{ .printable, .pasted_printable, .pasted_enter, .ctrl_c, .ctrl_d, .right, .paste_start, .paste_end, .invalid };
    const send: Take = .{ .edit = .{ .send = true } };
    const hold: Take = .{ .edit = .{ .send = false } };
    const rows = [_]Expected{
        // The draft takes typing; Enter sends only while nothing holds a
        // Message, and on a shown list's row takes that row.
        .{ .setups = &.{ .plain, .choice_pending, .host_held, .opening, .preparing, .command_active, .submitting }, .keys = &.{.left}, .take = .{ .perform = .close } },
        .{ .setups = &.{.shown_row}, .keys = &.{.left}, .take = send },
        .{ .setups = &sends, .keys = &(edits ++ [_]Pressed{ .host_start, .details }), .take = send },
        .{ .setups = &held, .keys = &edits, .take = hold },
        .{ .setups = &.{ .plain, .choice_pending }, .keys = &.{.enter}, .take = send },
        .{ .setups = &.{.shown_row}, .keys = &.{.enter}, .take = .take_row },
        .{ .setups = &held, .keys = &.{.enter}, .take = hold },
        .{ .setups = &.{ .plain, .shown_row }, .keys = &closing, .take = .{ .perform = .close } },
        .{ .setups = &held, .keys = &closing, .take = .{ .perform = .close } },
        // A footer choice hidden while its save is pending still closes on Esc.
        .{ .setups = &.{.choice_pending}, .keys = &closing, .take = .close_choice },
        // `r` on an empty draft starts a stopped Host; Alt-D shows a
        // refused original's details; Alt-I opens chat info.
        .{ .setups = &.{.host_held}, .keys = &.{.host_start}, .take = .start_host },
        .{ .setups = &.{ .opening, .preparing, .command_active, .submitting }, .keys = &.{.host_start}, .take = hold },
        .{ .setups = &.{.submitting}, .keys = &.{.details}, .take = .details },
        .{ .setups = &.{ .host_held, .opening, .preparing, .command_active }, .keys = &.{.details}, .take = hold },
        .{ .setups = &main, .keys = &.{.info}, .take = .open_info },
        // Footer focus takes Tab and Shift-Tab before anything else does.
        .{ .setups = &(main ++ [_]Setup{ .selector, .draft_row }), .keys = &.{.tab}, .take = .taken, .focus = .model },
        .{ .setups = &(main ++ [_]Setup{ .selector, .draft_row }), .keys = &.{.shift_tab}, .take = .taken, .focus = .effort },
        // Focus on the footer's model.
        .{ .setups = &.{.footer_focused}, .keys = &.{ .printable, .host_start, .paste_start }, .take = send, .focus = .input },
        .{ .setups = &.{.footer_focused}, .keys = &.{ .pasted_printable, .pasted_enter, .ctrl_c, .ctrl_d, .left, .right, .details, .paste_end, .invalid }, .take = send },
        .{ .setups = &.{.footer_focused}, .keys = &.{.enter}, .take = .open_choice, .focus = .input },
        .{ .setups = &.{.footer_focused}, .keys = &closing, .take = .taken, .focus = .input },
        .{ .setups = &.{.footer_focused}, .keys = &.{.tab}, .take = .taken, .focus = .effort },
        .{ .setups = &.{.footer_focused}, .keys = &.{.shift_tab}, .take = .taken, .focus = .input },
        .{ .setups = &.{.footer_focused}, .keys = &.{.info}, .take = .open_info },
        // A shown footer choice and the info panel take every key but
        // Esc, which closes the topmost thing, and the Session's own work.
        .{ .setups = &.{ .choice_shown, .info_open, .info_choice }, .keys = &leaving, .take = .{ .perform = .detach } },
        .{ .setups = &.{.choice_shown}, .keys = &closing, .take = .close_choice },
        .{ .setups = &.{.info_open}, .keys = &closing, .take = .close_info },
        .{ .setups = &.{.info_choice}, .keys = &closing, .take = .cancel_panel_choice },
        .{ .setups = &.{.info_open}, .keys = &.{.details}, .take = .panel_details },
        .{ .setups = &.{ .choice_shown, .info_choice }, .keys = &.{.details}, .take = .panel },
        .{ .setups = &.{ .choice_shown, .info_open, .info_choice }, .keys = &.{ .printable, .pasted_printable, .enter, .pasted_enter, .left, .right, .tab, .shift_tab, .host_start, .info, .paste_start, .paste_end, .invalid }, .take = .panel },
        // At the Action's choice the arrows and Enter choose, typing and
        // any paste move to the draft, and the screen's keys act.
        .{ .setups = &.{.selector}, .keys = &.{ .printable, .host_start, .pasted_printable, .pasted_enter, .paste_start }, .take = .consent_draft, .row = .draft },
        .{ .setups = &.{.selector}, .keys = &.{.enter}, .take = .{ .card = .enter } },
        .{ .setups = &.{.selector}, .keys = &.{.left}, .take = .{ .card = .left } },
        .{ .setups = &.{.selector}, .keys = &.{.right}, .take = .{ .card = .right } },
        .{ .setups = &.{.selector}, .keys = &.{.paste_end}, .take = .{ .card = .cancel } },
        .{ .setups = &.{.selector}, .keys = &.{.invalid}, .take = .{ .card = .invalid } },
        .{ .setups = &.{.selector}, .keys = &closing, .take = .{ .perform = .close } },
        .{ .setups = &.{.selector}, .keys = &leaving, .take = .{ .perform = .detach } },
        .{ .setups = &.{.selector}, .keys = &.{.details}, .take = .taken },
        .{ .setups = &.{ .selector, .draft_row }, .keys = &.{.info}, .take = .open_info },
        // At the draft beside it the editor takes every key but Enter,
        // which sends nothing, and Esc, which returns to the choice.
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
                .left => .{ .key = .left },
                .right => .{ .key = .right },
                .tab => .{ .key = .tab },
                .shift_tab => .{ .key = .shift_tab },
                .host_start => .{ .key = .host_start },
                .info => .{ .key = .info },
                .details => .{ .key = .details },
                // Root marks a paste's start pasted and its end not.
                .paste_start => .{ .key = .paste_start, .pasted = true },
                .paste_end => .{ .key = .paste_end },
                .invalid => .{ .key = .invalid },
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

        var footer_state: session_chrome.Footer = .{ .focus = if (setup == .footer_focused) .model else .input };
        const focus = footer_state.focus;
        var consent: ActionConsent = .{};
        consent.adopt(17);
        if (setup == .draft_row) consent.row = .draft;
        const before = consent.row;
        const waits = setup == .selector or setup == .draft_row;
        const take = step(.{ .footer = &footer_state, .consent = if (waits) &consent else null }, Case.facts(setup), Case.input(pressed));
        try std.testing.expectEqual(row.take, take);
        try std.testing.expectEqual(row.focus orelse focus, footer_state.focus);
        try std.testing.expectEqual(row.row orelse before, consent.row);
        // Only the footer's own Enter leaves an opening for its read.
        try std.testing.expectEqual(@as(?session_chrome.FooterField, if (take == .open_choice) .model else null), footer_state.pending);
    };
    for (used) |hit| try std.testing.expect(hit);
}
