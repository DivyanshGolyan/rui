//! Root's one input owner: which layer covers the main pane, the bracketed
//! paste in progress, and which pane takes each terminal event. Root reads
//! the facts other owners hold, calls `step`, and applies the `Effects` it
//! returns without deciding anything itself. Navigation between layers is an
//! input to the same `step`, so keys and navigation share one owner, and
//! every navigation focuses the top visible layer.
//! Root hands the main pane's core its keys and pastes with
//! the paste state they arrive in: the overview's with the layer they
//! arrived under, the open Session's while it is the main pane. Each core
//! decides what a key means there. The settings page's own keys `pass`:
//! vxfw's focus path delivers them. No click acts inside a paste.
const std = @import("std");
const keymap = @import("keymap.zig");

/// What covers the main pane. The main pane itself is the open Session, else
/// the overview: `session != null` stays the one fact for that.
pub const Layer = union(enum) {
    main,
    /// The app settings page in the main pane's place.
    settings,
    /// The sign-in page, which closes back to what it covered.
    sign_in: struct { over: Covered },

    pub const Covered = enum { main, settings };

    /// The settings page is open: shown, or under sign-in.
    pub fn settingsOpen(self: Layer) bool {
        return switch (self) {
            .main => false,
            .settings => true,
            .sign_in => |sign_in| sign_in.over == .settings,
        };
    }

    pub fn signInOpen(self: Layer) bool {
        return self == .sign_in;
    }
};

pub const State = struct {
    layer: Layer = .main,
    /// Keyboard navigation is in the list, while a wide chat stays drawn.
    list_focused: bool = false,
    /// Between a bracketed paste's start and end. Keys inside it are pasted
    /// text, never actions.
    pasting: bool = false,
};

/// What the shell read this event, owned elsewhere and passed by value.
pub const Facts = struct {
    /// A Session is open, so the main pane shows it, not the overview.
    session_open: bool = false,
    settings: Settings = .{},
    wide: bool = false,

    pub const Settings = struct {
        /// The Keys reference is open over the page.
        keys_open: bool = false,
        /// A choice (including the Model filter) is open on the page.
        choice_open: bool = false,
        /// The page takes this event's key itself.
        takes_key: bool = false,
        /// Only the Model filter edits text, so only it takes pasted keys.
        takes_paste: bool = false,
        /// An Upgrade can still be cancelled, so Esc is its.
        upgrade_takes_escape: bool = false,
    };
};

/// One terminal event, or a navigation request from the screen's owner.
pub const Input = union(enum) {
    key: Key,
    paste_start,
    paste_end,
    mouse: Mouse,
    key_release,
    /// A terminal colour report or scheme change.
    colors,
    /// Focus changes and every other event Root does not route.
    other,
    back_to_list: bool,
    session_closed,
    open_settings,
    /// Show the main pane: close settings, keeping any sign-in over it.
    show_main,
    open_sign_in,
    /// Close sign-in back to what it covered.
    close_sign_in,
    /// Sign-in finished: close it and any settings under it, showing main.
    signed_in,

    pub const Key = struct {
        /// The editor's name for the key; null for text and Enter.
        named: ?keymap.Key,
    };
    pub const Mouse = enum { click, list_click, chat_click, wheel, motion };
};

/// The whole decision for one input. Root applies it in field order: the
/// settings page change, the focus change, the route, then the redraw.
pub const Effects = struct {
    page: Page = .keep,
    focus: ?Focus = null,
    route: Route = .pass,
    redraw: bool = false,

    pub const Page = enum {
        keep,
        close_keys,
        cancel_choice,
        /// Leaving the page: cancel its choice and close its keys.
        reset,
    };
    /// Always the top visible layer after the input: never a hidden pane.
    pub const Focus = enum { main, list, settings, sign_in };
    /// What a key the overview takes arrived under, and whether it is
    /// pasted text.
    pub const Delivery = struct { under: Layer.Covered, pasted: bool };
    pub const Route = union(enum) {
        /// vxfw's own focus or hit-test path delivers it to the shown pane;
        /// Root leaves the event alone. Navigation requests always pass.
        pass,
        /// Root hands it to the sign-in page and stops it.
        sign_in,
        /// Root hands it to the overview's core and stops it. Under the
        /// settings page only leaving and an Upgrade's Esc are the
        /// overview's, and Root redraws.
        overview: Delivery,
        /// Root hands it to the open Session's core and stops it. It
        /// arrives only under main, while the Session is the main pane.
        session: Delivery,
        /// Root hands it to the overview, which owns the palette, and stops it.
        colors,
        /// Root stops it; nothing takes it.
        swallow,
    };
};

/// The pane drawn in the main pane's place.
pub const Pane = enum { overview, session, settings, sign_in };

pub fn pane(layer: Layer, session_open: bool) Pane {
    return switch (layer) {
        .main => if (session_open) .session else .overview,
        .settings => .settings,
        .sign_in => .sign_in,
    };
}

/// List focus only hides a retained chat when the sidebar cannot fit beside it.
pub fn mainPane(state: State, session_open: bool, wide: bool) Pane {
    return pane(state.layer, session_open and (wide or !state.list_focused));
}

/// A layer change: the page change it makes, focus on the top layer, a redraw.
fn navigated(layer: Layer, page: Effects.Page) Effects {
    const top: Effects.Focus = switch (layer) {
        .main => .main,
        .settings => .settings,
        .sign_in => .sign_in,
    };
    return .{ .page = page, .focus = top, .redraw = true };
}

/// Root reloads the settings page before it sends `open_settings`, so a
/// failed reload never reaches this state.
pub fn step(state: *State, facts: Facts, input: Input) Effects {
    switch (input) {
        .back_to_list => |draft_empty| {
            if (!draft_empty or !facts.wide or !facts.session_open or state.layer != .main) return .{};
            state.list_focused = true;
            return .{ .focus = .list, .redraw = true };
        },
        .session_closed => {
            state.list_focused = true;
            return if (state.layer == .main) .{ .focus = .main, .redraw = true } else .{};
        },
        .open_settings => {
            state.list_focused = false;
            state.layer = switch (state.layer) {
                .main, .settings => .settings,
                .sign_in => .{ .sign_in = .{ .over = .settings } },
            };
            return navigated(state.layer, .close_keys);
        },
        .show_main => {
            state.list_focused = false;
            state.layer = switch (state.layer) {
                .main, .settings => .main,
                .sign_in => .{ .sign_in = .{ .over = .main } },
            };
            return navigated(state.layer, .reset);
        },
        .open_sign_in => {
            state.list_focused = false;
            state.layer = switch (state.layer) {
                .main => .{ .sign_in = .{ .over = .main } },
                .settings => .{ .sign_in = .{ .over = .settings } },
                .sign_in => state.layer,
            };
            return navigated(state.layer, .keep);
        },
        .close_sign_in => {
            state.layer = switch (state.layer) {
                .main, .settings => state.layer,
                .sign_in => |sign_in| switch (sign_in.over) {
                    .main => .main,
                    .settings => .settings,
                },
            };
            return navigated(state.layer, .keep);
        },
        .signed_in => {
            state.list_focused = false;
            state.layer = .main;
            return navigated(state.layer, .reset);
        },
        .key_release => return .{ .route = .swallow },
        .colors => return .{ .route = .colors },
        .other => return .{},
        .key, .paste_start, .paste_end, .mouse => {},
    }
    // A paste is stream state: it spans layers, whoever takes its bytes.
    switch (input) {
        .paste_start => state.pasting = true,
        .paste_end => state.pasting = false,
        else => {},
    }
    // A click inside a paste is pasted bytes, never a press: nothing takes it.
    if (input == .mouse and (input.mouse == .click or input.mouse == .list_click or input.mouse == .chat_click) and state.pasting) return .{ .route = .swallow };
    // The sign-in page owns keys and pastes even over settings or a list
    // that had focus before it opened, and no click navigates behind it.
    if (state.layer == .sign_in) return switch (input) {
        .mouse => .{ .route = .swallow },
        else => .{ .route = .sign_in },
    };
    if (input == .key and state.layer == .settings) return settingsKey(state, facts.settings, input.key);
    if (state.layer == .main and input == .mouse and facts.session_open and facts.wide) switch (input.mouse) {
        .list_click => {
            state.list_focused = true;
            return .{ .focus = .list, .redraw = true };
        },
        .chat_click => {
            state.list_focused = false;
            return .{ .focus = .main, .redraw = true };
        },
        else => {},
    };
    // The main pane's core takes every key and paste mark:
    // the open Session's, else the overview's. A click passes.
    if (state.layer != .main or input == .mouse) return .{};
    const delivery: Effects.Delivery = .{ .under = .main, .pasted = state.pasting };
    if (state.list_focused) return .{ .route = .{ .overview = delivery } };

    return .{ .route = if (facts.session_open) .{ .session = delivery } else .{ .overview = delivery } };
}

/// The overview's keys under the settings page, never pasted.
const app_keys: Effects.Route = .{ .overview = .{ .under = .settings, .pasted = false } };

/// One router for every key while settings is shown. A pasted key goes
/// only to the Model filter, never a choice or action. Esc (or Ctrl-G, as
/// everywhere) closes the topmost thing only: the Keys reference or a
/// choice, else the page, unless an Upgrade can still be cancelled. The
/// page takes its own keys; every other key is the app's.
fn settingsKey(state: *State, page: Facts.Settings, key: Input.Key) Effects {
    if (state.pasting) return if (page.takes_paste) .{} else .{ .route = .swallow };
    const closes = key.named == .escape or key.named == .ctrl_g;
    if (closes and page.keys_open) return .{ .page = .close_keys, .route = .swallow, .redraw = true };
    if (closes and page.choice_open) return .{ .page = .cancel_choice, .route = .swallow, .redraw = true };
    if (closes and !page.upgrade_takes_escape) {
        state.layer = .main;
        var closed = navigated(state.layer, .reset);
        closed.route = .swallow;
        return closed;
    }
    if (!page.takes_key) return .{ .route = app_keys, .redraw = true };
    return .{};
}

test "Root input routing over every layer, main pane, settings state and input" {
    // Expectations are the routing Root.capture, openSettings, showMain and
    // the sign-in open/close made before this owner existed (main 5df5531),
    // except three decisions made with it: a paste spans every layer,
    // navigation focuses the top visible layer, and signing in is one
    // request. The overview's and the open Session's keys come to their
    // cores straight from Root (main 309d639 let them pass to the focused
    // pane, which read the same paste flag), and no click acts inside a
    // paste (main 309d639 let one pass to whatever was under it). Each
    // combination matches exactly one row, and every row matches some.
    const LayerCase = enum { main, settings, sign_in_over_main, sign_in_over_settings };
    const Page = enum { plain, keys_open, choice_open, model_filter, upgrade_cancellable };
    const Event = enum { printable, pasted_printable, enter, pasted_enter, escape, ctrl_g, ctrl_c, paste_start, paste_end, click, pasted_click, wheel, key_release, colors, focus_out, open_settings, show_main, open_sign_in, close_sign_in, signed_in };
    const all_layers = std.enums.values(LayerCase);
    const all_pages = std.enums.values(Page);
    const shown = [_]LayerCase{ .main, .settings };
    const signing = [_]LayerCase{ .sign_in_over_main, .sign_in_over_settings };
    const keys = [_]Event{ .printable, .pasted_printable, .enter, .pasted_enter, .escape, .ctrl_g, .ctrl_c };
    const closing = [_]Event{ .escape, .ctrl_g };
    const Row = struct {
        layers: []const LayerCase = all_layers,
        /// Whether a Session is open behind the layers.
        sessions: []const bool = &.{ false, true },
        pages: []const Page = all_pages,
        events: []const Event,
        effects: Effects,
        /// The layer after the input; null leaves it as it was.
        layer: ?LayerCase = null,
        /// Pasting after the input; null leaves it as it was.
        pasting: ?bool = null,
    };
    const main_shown: Effects = .{ .page = .reset, .focus = .main, .redraw = true };
    const Main = struct {
        fn overview(pasted: bool) Effects {
            return .{ .route = .{ .overview = .{ .under = .main, .pasted = pasted } } };
        }
        fn session(pasted: bool) Effects {
            return .{ .route = .{ .session = .{ .under = .main, .pasted = pasted } } };
        }
    };
    const overview = Main.overview;
    const closed: Effects = .{ .page = .reset, .focus = .main, .route = .swallow, .redraw = true };
    const rows = [_]Row{
        // Every layer.
        .{ .events = &.{.key_release}, .effects = .{ .route = .swallow } },
        .{ .events = &.{.colors}, .effects = .{ .route = .colors } },
        .{ .events = &.{.focus_out}, .effects = .{} },
        // A click inside a paste is pasted bytes: nothing takes it.
        .{ .events = &.{.pasted_click}, .effects = .{ .route = .swallow } },
        // Sign-in takes keys and pastes; the paste is still one.
        .{ .layers = &signing, .events = &keys, .effects = .{ .route = .sign_in } },
        .{ .layers = &signing, .events = &.{.paste_start}, .effects = .{ .route = .sign_in }, .pasting = true },
        .{ .layers = &signing, .events = &.{.paste_end}, .effects = .{ .route = .sign_in }, .pasting = false },
        .{ .layers = &signing, .events = &.{ .click, .wheel }, .effects = .{ .route = .swallow } },
        // Under main and settings, vxfw's path takes the rest.
        .{ .layers = &.{.settings}, .events = &.{.paste_start}, .effects = .{}, .pasting = true },
        .{ .layers = &.{.settings}, .events = &.{.paste_end}, .effects = .{}, .pasting = false },
        .{ .layers = &shown, .events = &.{ .click, .wheel }, .effects = .{} },
        // The open Session's core takes its keys; otherwise the overview's
        // does, with the paste they arrive in.
        .{ .layers = &.{.main}, .sessions = &.{true}, .events = &.{.paste_start}, .effects = Main.session(true), .pasting = true },
        .{ .layers = &.{.main}, .sessions = &.{true}, .events = &.{.paste_end}, .effects = Main.session(false), .pasting = false },
        .{ .layers = &.{.main}, .sessions = &.{true}, .events = &.{ .pasted_printable, .pasted_enter }, .effects = Main.session(true) },
        .{ .layers = &.{.main}, .sessions = &.{true}, .events = &.{ .printable, .enter, .escape, .ctrl_g, .ctrl_c }, .effects = Main.session(false) },
        .{ .layers = &.{.main}, .sessions = &.{false}, .events = &.{.paste_start}, .effects = overview(true), .pasting = true },
        .{ .layers = &.{.main}, .sessions = &.{false}, .events = &.{.paste_end}, .effects = overview(false), .pasting = false },
        .{ .layers = &.{.main}, .sessions = &.{false}, .events = &.{ .pasted_printable, .pasted_enter }, .effects = overview(true) },
        .{ .layers = &.{.main}, .sessions = &.{false}, .events = &.{ .printable, .enter, .escape, .ctrl_g, .ctrl_c }, .effects = overview(false) },
        // Settings keys.
        .{ .layers = &.{.settings}, .pages = &.{.model_filter}, .events = &.{ .pasted_printable, .pasted_enter, .printable }, .effects = .{} },
        .{ .layers = &.{.settings}, .pages = &.{ .plain, .keys_open, .choice_open, .upgrade_cancellable }, .events = &.{ .pasted_printable, .pasted_enter }, .effects = .{ .route = .swallow } },
        .{ .layers = &.{.settings}, .pages = &.{ .plain, .keys_open, .choice_open, .upgrade_cancellable }, .events = &.{.printable}, .effects = .{ .route = app_keys, .redraw = true } },
        .{ .layers = &.{.settings}, .events = &.{.enter}, .effects = .{} },
        .{ .layers = &.{.settings}, .events = &.{.ctrl_c}, .effects = .{ .route = app_keys, .redraw = true } },
        .{ .layers = &.{.settings}, .pages = &.{.keys_open}, .events = &closing, .effects = .{ .page = .close_keys, .route = .swallow, .redraw = true } },
        .{ .layers = &.{.settings}, .pages = &.{ .choice_open, .model_filter }, .events = &closing, .effects = .{ .page = .cancel_choice, .route = .swallow, .redraw = true } },
        .{ .layers = &.{.settings}, .pages = &.{.plain}, .events = &closing, .effects = closed, .layer = .main },
        .{ .layers = &.{.settings}, .pages = &.{.upgrade_cancellable}, .events = &closing, .effects = .{ .route = app_keys, .redraw = true } },
        // Navigation: focus stays on, or moves to, the top visible layer.
        .{ .layers = &.{ .main, .settings }, .events = &.{.open_settings}, .effects = .{ .page = .close_keys, .focus = .settings, .redraw = true }, .layer = .settings },
        .{ .layers = &signing, .events = &.{.open_settings}, .effects = .{ .page = .close_keys, .focus = .sign_in, .redraw = true }, .layer = .sign_in_over_settings },
        .{ .layers = &.{ .main, .settings }, .events = &.{.show_main}, .effects = main_shown, .layer = .main },
        .{ .layers = &signing, .events = &.{.show_main}, .effects = .{ .page = .reset, .focus = .sign_in, .redraw = true }, .layer = .sign_in_over_main },
        .{ .layers = &.{ .main, .sign_in_over_main }, .events = &.{.open_sign_in}, .effects = .{ .focus = .sign_in, .redraw = true }, .layer = .sign_in_over_main },
        .{ .layers = &.{ .settings, .sign_in_over_settings }, .events = &.{.open_sign_in}, .effects = .{ .focus = .sign_in, .redraw = true }, .layer = .sign_in_over_settings },
        .{ .layers = &.{ .main, .sign_in_over_main }, .events = &.{.close_sign_in}, .effects = .{ .focus = .main, .redraw = true }, .layer = .main },
        .{ .layers = &.{ .settings, .sign_in_over_settings }, .events = &.{.close_sign_in}, .effects = .{ .focus = .settings, .redraw = true }, .layer = .settings },
        .{ .events = &.{.signed_in}, .effects = main_shown, .layer = .main },
    };
    const Case = struct {
        fn layer(case: LayerCase) Layer {
            return switch (case) {
                .main => .main,
                .settings => .settings,
                .sign_in_over_main => .{ .sign_in = .{ .over = .main } },
                .sign_in_over_settings => .{ .sign_in = .{ .over = .settings } },
            };
        }
        fn has(comptime T: type, set: []const T, value: T) bool {
            return std.mem.indexOfScalar(T, set, value) != null;
        }
        /// The page's own answers, as AppSettings gives them for these keys.
        fn facts(session: bool, page: Page, event: Event) Facts {
            const filter = page == .model_filter;
            return .{
                .session_open = session,
                .settings = .{
                    .keys_open = page == .keys_open,
                    .choice_open = page == .choice_open or filter,
                    // The panel takes Enter; the Model filter also takes text.
                    .takes_key = switch (event) {
                        .enter, .pasted_enter => true,
                        .printable, .pasted_printable => filter,
                        else => false,
                    },
                    .takes_paste = filter,
                    .upgrade_takes_escape = page == .upgrade_cancellable,
                },
            };
        }
        fn input(event: Event) Input {
            return switch (event) {
                .printable, .pasted_printable, .enter, .pasted_enter => .{ .key = .{ .named = null } },
                .escape => .{ .key = .{ .named = .escape } },
                .ctrl_g => .{ .key = .{ .named = .ctrl_g } },
                .ctrl_c => .{ .key = .{ .named = .ctrl_c } },
                .paste_start => .paste_start,
                .paste_end => .paste_end,
                .click, .pasted_click => .{ .mouse = .click },
                .wheel => .{ .mouse = .wheel },
                .key_release => .key_release,
                .colors => .colors,
                .focus_out => .other,
                .open_settings => .open_settings,
                .show_main => .show_main,
                .open_sign_in => .open_sign_in,
                .close_sign_in => .close_sign_in,
                .signed_in => .signed_in,
            };
        }
    };
    var used: [rows.len]bool = @splat(false);
    for (all_layers) |layer| for ([_]bool{ false, true }) |session| for (all_pages) |page| for (std.enums.values(Event)) |event| {
        errdefer std.debug.print("layer={s} session={} page={s} event={s}\n", .{ @tagName(layer), session, @tagName(page), @tagName(event) });
        var matched: ?usize = null;
        for (rows, 0..) |row, index| {
            if (!Case.has(LayerCase, row.layers, layer) or !Case.has(bool, row.sessions, session) or !Case.has(Page, row.pages, page) or !Case.has(Event, row.events, event)) continue;
            try std.testing.expectEqual(@as(?usize, null), matched);
            matched = index;
        }
        const row = rows[matched.?];
        used[matched.?] = true;
        // A pasted key arrives inside a paste; paste_end closes one.
        const pasting = event == .pasted_printable or event == .pasted_enter or event == .pasted_click or event == .paste_end;
        var state: State = .{ .layer = Case.layer(layer), .pasting = pasting };
        const effects = step(&state, Case.facts(session, page, event), Case.input(event));
        // The main pane shows the Session when one is open, under any layer.
        const shown_pane: Pane = switch (state.layer) {
            .main => if (session) .session else .overview,
            .settings => .settings,
            .sign_in => .sign_in,
        };
        try std.testing.expectEqual(shown_pane, pane(state.layer, session));
        // No effect focuses a hidden pane: focus names the pane now shown.
        if (effects.focus) |focus| try std.testing.expect(switch (focus) {
            .main, .list => shown_pane == .overview or shown_pane == .session,
            .settings => shown_pane == .settings,
            .sign_in => shown_pane == .sign_in,
        });
        try std.testing.expectEqual(row.effects, effects);
        try std.testing.expectEqual(Case.layer(row.layer orelse layer), state.layer);
        try std.testing.expectEqual(row.pasting orelse pasting, state.pasting);
    };
    for (used) |hit| try std.testing.expect(hit);

    // A paste that straddles sign-in opening and closing stays one paste, so
    // a pasted Enter after it closes never chooses on the settings page.
    const Step = struct { input: Input, effects: Effects, layer: LayerCase, pasting: bool };
    const key: Input = .{ .key = .{ .named = null } };
    const straddles = [_]Step{
        .{ .input = .paste_start, .effects = .{}, .layer = .settings, .pasting = true },
        .{ .input = .open_sign_in, .effects = .{ .focus = .sign_in, .redraw = true }, .layer = .sign_in_over_settings, .pasting = true },
        .{ .input = key, .effects = .{ .route = .sign_in }, .layer = .sign_in_over_settings, .pasting = true },
        .{ .input = .paste_end, .effects = .{ .route = .sign_in }, .layer = .sign_in_over_settings, .pasting = false },
        .{ .input = .paste_start, .effects = .{ .route = .sign_in }, .layer = .sign_in_over_settings, .pasting = true },
        .{ .input = .close_sign_in, .effects = .{ .focus = .settings, .redraw = true }, .layer = .settings, .pasting = true },
        .{ .input = key, .effects = .{ .route = .swallow }, .layer = .settings, .pasting = true },
        .{ .input = .paste_end, .effects = .{}, .layer = .settings, .pasting = false },
        .{ .input = key, .effects = .{}, .layer = .settings, .pasting = false },
    };
    var state: State = .{ .layer = .settings };
    for (straddles, 0..) |expected, index| {
        errdefer std.debug.print("straddling paste step {d}\n", .{index});
        // The page's answers for Enter: the panel takes it.
        try std.testing.expectEqual(expected.effects, step(&state, Case.facts(false, .plain, .enter), expected.input));
        try std.testing.expectEqual(Case.layer(expected.layer), state.layer);
        try std.testing.expectEqual(expected.pasting, state.pasting);
    }
}

test "Layer answers settings and sign-in open from the one union" {
    try std.testing.expect(!Layer.settingsOpen(.main) and !Layer.signInOpen(.main));
    try std.testing.expect(Layer.settingsOpen(.settings) and !Layer.signInOpen(.settings));
    const over_main: Layer = .{ .sign_in = .{ .over = .main } };
    const over_settings: Layer = .{ .sign_in = .{ .over = .settings } };
    try std.testing.expect(!over_main.settingsOpen() and over_main.signInOpen());
    try std.testing.expect(over_settings.settingsOpen() and over_settings.signInOpen());
}

pub const DraftKey = enum { left, escape, other };
pub const DraftTake = enum { edit, back };

/// Escape's existing close path also owns Left on an actually empty draft.
/// A caret at column zero is not an empty draft.
pub fn draftKey(empty: bool, key: DraftKey) DraftTake {
    return if (key == .escape or (empty and key == .left)) .back else .edit;
}

test "App input draft back domain distinguishes empty text from a caret at start" {
    for ([_]struct { bytes: []const u8, cursor: usize }{
        .{ .bytes = "", .cursor = 0 },
        .{ .bytes = "draft", .cursor = 5 },
        .{ .bytes = "draft", .cursor = 0 },
    }) |draft| {
        try std.testing.expectEqual(DraftTake.back, draftKey(draft.bytes.len == 0, .escape));
        try std.testing.expectEqual(if (draft.bytes.len == 0) DraftTake.back else .edit, draftKey(draft.bytes.len == 0, .left));
    }
}

test "App input list activation routes unchanged to its semantic owner" {
    for ([_]bool{ false, true }) |wide| {
        var state: State = .{ .list_focused = true };
        const result = step(&state, .{ .session_open = wide, .wide = wide }, .{ .key = .{ .named = null } });
        try std.testing.expectEqual(Effects.Route{ .overview = .{ .under = .main, .pasted = false } }, result.route);
        try std.testing.expect(state.list_focused);
        const resumed = step(&state, .{ .session_open = true, .wide = wide }, .show_main);
        try std.testing.expectEqual(@as(?Effects.Focus, .main), resumed.focus);
        try std.testing.expect(!state.list_focused);
    }
}

test "App input list focus routes every list event to its semantic owner and mouse returns focus" {
    for ([_]bool{ false, true }) |pasting| {
        var state: State = .{ .list_focused = true, .pasting = pasting };
        for ([_]Input{ .{ .key = .{ .named = null } }, .paste_start, .paste_end }) |input| {
            const result = step(&state, .{ .session_open = true, .wide = true }, input);
            try std.testing.expect(result.route == .overview);
        }
    }
    var state: State = .{};
    const facts: Facts = .{ .session_open = true, .wide = true };
    const list = step(&state, facts, .{ .mouse = .list_click });
    try std.testing.expect(state.list_focused);
    try std.testing.expectEqual(@as(?Effects.Focus, .list), list.focus);
    const chat = step(&state, facts, .{ .mouse = .chat_click });
    try std.testing.expect(!state.list_focused);
    try std.testing.expectEqual(@as(?Effects.Focus, .main), chat.focus);
}
