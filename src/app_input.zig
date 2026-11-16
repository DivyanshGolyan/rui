const std = @import("std");
const keymap = @import("keymap.zig");

pub const Layer = union(enum) {
    main,
    settings,
    sign_in: struct { over: Covered },

    pub const Covered = enum { main, settings };

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
    list_focused: bool = false,
    pasting: bool = false,
};

pub const Facts = struct {
    session_open: bool = false,
    settings: Settings = .{},
    wide: bool = false,

    pub const Settings = struct {
        keys_open: bool = false,
        choice_open: bool = false,
        takes_key: bool = false,
        takes_paste: bool = false,
        upgrade_takes_escape: bool = false,
    };
};

pub const Input = union(enum) {
    key: Key,
    paste_start,
    paste_end,
    mouse: Mouse,
    key_release,
    colors,
    other,
    back_to_list,
    session_closed,
    focus_chat,
    open_settings,
    show_main,
    open_sign_in,
    close_sign_in,
    signed_in,

    pub const Key = struct {
        named: ?keymap.Key,
    };
    pub const Mouse = enum { click, list_click, chat_click, wheel, motion };
};

pub const Effects = struct {
    page: Page = .keep,
    focus: ?Focus = null,
    route: Route = .pass,
    redraw: bool = false,

    pub const Page = enum {
        keep,
        close_keys,
        cancel_choice,
        reset,
    };
    pub const Focus = enum { main, list, settings, sign_in };
    pub const Delivery = struct { under: Layer.Covered, pasted: bool };
    pub const Route = union(enum) {
        pass,
        sign_in,
        overview: Delivery,
        session: Delivery,
        colors,
        swallow,
    };
};

pub const Pane = enum { overview, session, settings, sign_in };

pub fn pane(layer: Layer, session_open: bool) Pane {
    return switch (layer) {
        .main => if (session_open) .session else .overview,
        .settings => .settings,
        .sign_in => .sign_in,
    };
}

pub fn mainPane(state: State, session_open: bool, wide: bool) Pane {
    return pane(state.layer, session_open and (wide or !state.list_focused));
}

fn navigated(layer: Layer, page: Effects.Page) Effects {
    const top: Effects.Focus = switch (layer) {
        .main => .main,
        .settings => .settings,
        .sign_in => .sign_in,
    };
    return .{ .page = page, .focus = top, .redraw = true };
}

pub fn step(state: *State, facts: Facts, input: Input) Effects {
    if (input == .focus_chat and state.layer == .main) return if (facts.session_open) focusChat(state) else .{};
    switch (input) {
        .back_to_list => {
            if (!facts.wide or !facts.session_open or state.layer != .main) return .{};
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
        .show_main, .focus_chat => {
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
    switch (input) {
        .paste_start => state.pasting = true,
        .paste_end => state.pasting = false,
        else => {},
    }
    if (input == .mouse and (input.mouse == .click or input.mouse == .list_click or input.mouse == .chat_click) and state.pasting) return .{ .route = .swallow };
    if (state.layer == .sign_in) return .{ .route = .sign_in };
    if (input == .key and state.layer == .settings) return settingsKey(state, facts.settings, input.key);
    if (state.layer == .main and input == .mouse and facts.session_open and facts.wide) switch (input.mouse) {
        .list_click => {
            state.list_focused = true;
            return .{ .focus = .list, .redraw = true };
        },
        .chat_click => return focusChat(state),
        else => {},
    };
    if (state.layer != .main or input == .mouse) return .{};
    const delivery: Effects.Delivery = .{ .under = .main, .pasted = state.pasting };
    if (!state.pasting and input == .key and (input.key.named == .alt_up or input.key.named == .alt_down))
        return .{ .route = .{ .overview = delivery } };
    if (state.list_focused) return .{ .route = .{ .overview = delivery } };

    return .{ .route = if (facts.session_open) .{ .session = delivery } else .{ .overview = delivery } };
}

fn focusChat(state: *State) Effects {
    state.list_focused = false;
    return .{ .focus = .main, .redraw = true };
}

const app_keys: Effects.Route = .{ .overview = .{ .under = .settings, .pasted = false } };

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
        sessions: []const bool = &.{ false, true },
        pages: []const Page = all_pages,
        events: []const Event,
        effects: Effects,
        layer: ?LayerCase = null,
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
        .{ .events = &.{.key_release}, .effects = .{ .route = .swallow } },
        .{ .events = &.{.colors}, .effects = .{ .route = .colors } },
        .{ .events = &.{.focus_out}, .effects = .{} },
        .{ .events = &.{.pasted_click}, .effects = .{ .route = .swallow } },
        .{ .layers = &signing, .events = &keys, .effects = .{ .route = .sign_in } },
        .{ .layers = &signing, .events = &.{.paste_start}, .effects = .{ .route = .sign_in }, .pasting = true },
        .{ .layers = &signing, .events = &.{.paste_end}, .effects = .{ .route = .sign_in }, .pasting = false },
        .{ .layers = &signing, .events = &.{ .click, .wheel }, .effects = .{ .route = .sign_in } },
        .{ .layers = &.{.settings}, .events = &.{.paste_start}, .effects = .{}, .pasting = true },
        .{ .layers = &.{.settings}, .events = &.{.paste_end}, .effects = .{}, .pasting = false },
        .{ .layers = &shown, .events = &.{ .click, .wheel }, .effects = .{} },
        .{ .layers = &.{.main}, .sessions = &.{true}, .events = &.{.paste_start}, .effects = Main.session(true), .pasting = true },
        .{ .layers = &.{.main}, .sessions = &.{true}, .events = &.{.paste_end}, .effects = Main.session(false), .pasting = false },
        .{ .layers = &.{.main}, .sessions = &.{true}, .events = &.{ .pasted_printable, .pasted_enter }, .effects = Main.session(true) },
        .{ .layers = &.{.main}, .sessions = &.{true}, .events = &.{ .printable, .enter, .escape, .ctrl_g, .ctrl_c }, .effects = Main.session(false) },
        .{ .layers = &.{.main}, .sessions = &.{false}, .events = &.{.paste_start}, .effects = overview(true), .pasting = true },
        .{ .layers = &.{.main}, .sessions = &.{false}, .events = &.{.paste_end}, .effects = overview(false), .pasting = false },
        .{ .layers = &.{.main}, .sessions = &.{false}, .events = &.{ .pasted_printable, .pasted_enter }, .effects = overview(true) },
        .{ .layers = &.{.main}, .sessions = &.{false}, .events = &.{ .printable, .enter, .escape, .ctrl_g, .ctrl_c }, .effects = overview(false) },
        .{ .layers = &.{.settings}, .pages = &.{.model_filter}, .events = &.{ .pasted_printable, .pasted_enter, .printable }, .effects = .{} },
        .{ .layers = &.{.settings}, .pages = &.{ .plain, .keys_open, .choice_open, .upgrade_cancellable }, .events = &.{ .pasted_printable, .pasted_enter }, .effects = .{ .route = .swallow } },
        .{ .layers = &.{.settings}, .pages = &.{ .plain, .keys_open, .choice_open, .upgrade_cancellable }, .events = &.{.printable}, .effects = .{ .route = app_keys, .redraw = true } },
        .{ .layers = &.{.settings}, .events = &.{.enter}, .effects = .{} },
        .{ .layers = &.{.settings}, .events = &.{.ctrl_c}, .effects = .{ .route = app_keys, .redraw = true } },
        .{ .layers = &.{.settings}, .pages = &.{.keys_open}, .events = &closing, .effects = .{ .page = .close_keys, .route = .swallow, .redraw = true } },
        .{ .layers = &.{.settings}, .pages = &.{ .choice_open, .model_filter }, .events = &closing, .effects = .{ .page = .cancel_choice, .route = .swallow, .redraw = true } },
        .{ .layers = &.{.settings}, .pages = &.{.plain}, .events = &closing, .effects = closed, .layer = .main },
        .{ .layers = &.{.settings}, .pages = &.{.upgrade_cancellable}, .events = &closing, .effects = .{ .route = app_keys, .redraw = true } },
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
        fn facts(session: bool, page: Page, event: Event) Facts {
            const filter = page == .model_filter;
            return .{
                .session_open = session,
                .settings = .{
                    .keys_open = page == .keys_open,
                    .choice_open = page == .choice_open or filter,
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
        const pasting = event == .pasted_printable or event == .pasted_enter or event == .pasted_click or event == .paste_end;
        var state: State = .{ .layer = Case.layer(layer), .pasting = pasting };
        const effects = step(&state, Case.facts(session, page, event), Case.input(event));
        const shown_pane: Pane = switch (state.layer) {
            .main => if (session) .session else .overview,
            .settings => .settings,
            .sign_in => .sign_in,
        };
        try std.testing.expectEqual(shown_pane, pane(state.layer, session));
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

pub const DraftKey = enum { left, other };
pub const DraftTake = enum { edit, list };

pub fn draftKey(empty: bool, key: DraftKey) DraftTake {
    return if (empty and key == .left) .list else .edit;
}

test "App input draft list domain distinguishes empty text from a caret at start" {
    for ([_]struct { bytes: []const u8, cursor: usize }{
        .{ .bytes = "", .cursor = 0 },
        .{ .bytes = "draft", .cursor = 5 },
        .{ .bytes = "draft", .cursor = 0 },
    }) |draft| {
        try std.testing.expectEqual(DraftTake.edit, draftKey(draft.bytes.len == 0, .other));
        try std.testing.expectEqual(if (draft.bytes.len == 0) DraftTake.list else .edit, draftKey(draft.bytes.len == 0, .left));
    }
}

test "App input list activation routes unchanged to its semantic owner" {
    for ([_]bool{ false, true }) |wide| {
        var state: State = .{ .list_focused = true };
        const result = step(&state, .{ .session_open = wide, .wide = wide }, .{ .key = .{ .named = null } });
        try std.testing.expectEqual(Effects.Route{ .overview = .{ .under = .main, .pasted = false } }, result.route);
        try std.testing.expect(state.list_focused);
        const resumed = step(&state, .{ .session_open = true, .wide = wide }, .focus_chat);
        try std.testing.expectEqual(@as(?Effects.Focus, .main), resumed.focus);
        try std.testing.expect(!state.list_focused);
    }
}

test "App input list activation and chat-pane click share one focus transition that keeps the chat's presentation" {
    const layers = [_]Layer{ .main, .settings, .{ .sign_in = .{ .over = .main } }, .{ .sign_in = .{ .over = .settings } } };
    for (layers) |layer| for ([_]bool{ false, true }) |wide| for ([_]bool{ false, true }) |session_open| for ([_]bool{ false, true }) |list_focused| {
        const facts: Facts = .{ .session_open = session_open, .wide = wide };
        var activated: State = .{ .layer = layer, .list_focused = list_focused };
        const resume_effects = step(&activated, facts, .focus_chat);
        try std.testing.expectEqual(Effects.Route.pass, resume_effects.route);
        if (layer != .main) {
            var shown: State = .{ .layer = layer, .list_focused = list_focused };
            try std.testing.expectEqualDeep(step(&shown, facts, .show_main), resume_effects);
            try std.testing.expectEqualDeep(shown, activated);
            continue;
        }
        try std.testing.expectEqual(Effects.Page.keep, resume_effects.page);
        try std.testing.expectEqual(Layer.main, activated.layer);
        try std.testing.expectEqual(if (session_open) false else list_focused, activated.list_focused);
        try std.testing.expectEqual(if (session_open) @as(?Effects.Focus, .main) else null, resume_effects.focus);
        if (!session_open or !wide) continue;
        var clicked: State = .{ .layer = layer, .list_focused = list_focused };
        try std.testing.expectEqualDeep(resume_effects, step(&clicked, facts, .{ .mouse = .chat_click }));
        try std.testing.expectEqualDeep(activated, clicked);
    };
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

test "App input paste completion routes to the same owner for every focus and paste shape" {
    for ([_]bool{ false, true }) |wide| for ([_]bool{ false, true }) |session_open| for ([_]bool{ false, true }) |list_focused| for ([_][]const u8{ "", "\n", "text" }) |paste| {
        var state: State = .{ .list_focused = list_focused };
        const facts: Facts = .{ .wide = wide, .session_open = session_open };
        const start = step(&state, facts, .paste_start);
        const overview = list_focused or !session_open;
        try std.testing.expectEqual(overview, start.route == .overview);
        try std.testing.expectEqual(!overview, start.route == .session);
        try std.testing.expect(state.pasting);
        for (paste) |_| {
            const text = step(&state, facts, .{ .key = .{ .named = null } });
            try std.testing.expectEqual(start.route, text.route);
        }
        const end = step(&state, facts, .paste_end);
        try std.testing.expectEqual(std.meta.activeTag(start.route), std.meta.activeTag(end.route));
        const delivery = if (overview) end.route.overview else end.route.session;
        try std.testing.expect(!delivery.pasted and !state.pasting);
        try std.testing.expectEqual(list_focused, state.list_focused);
    };
}

test "Option session navigation routes main chords without taking paste or modal custody" {
    for ([_]keymap.Key{ .alt_up, .alt_down }) |key| for ([_]bool{ false, true }) |wide| for ([_]bool{ false, true }) |open| for ([_]bool{ false, true }) |focused| for ([_]bool{ false, true }) |pasted| for ([_]Layer{ .main, .settings, .{ .sign_in = .{ .over = .main } } }) |layer| {
        var state: State = .{ .layer = layer, .list_focused = focused, .pasting = pasted };
        const effects = step(&state, .{ .wide = wide, .session_open = open }, .{ .key = .{ .named = key } });
        if (layer == .sign_in) {
            try std.testing.expect(effects.route == .sign_in);
        } else if (layer == .settings) {
            if (pasted) try std.testing.expect(effects.route == .swallow) else {
                try std.testing.expect(effects.route == .overview);
                try std.testing.expectEqual(Layer.Covered.settings, effects.route.overview.under);
            }
        } else if (layer == .main) {
            if (!pasted or focused or !open) {
                try std.testing.expect(effects.route == .overview);
                try std.testing.expectEqual(pasted, effects.route.overview.pasted);
            } else try std.testing.expect(effects.route == .session);
        }
        try std.testing.expectEqual(focused, state.list_focused);
        try std.testing.expectEqual(pasted, state.pasting);
        try std.testing.expect(effects.focus == null);
    };
}
