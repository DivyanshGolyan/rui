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

/// Semantic identities in pane-major drawn order. The frame includes only
/// controls that actually occupied cells; no viewport predicates live here.
pub const Target = enum { list, settings_row, input, back, model, effort, info, latest, details, needs, stop };
pub const Field = enum { input, model, effort };
pub const FooterField = enum { model, effort };
pub const FooterFocus = Field;
/// Root and Session core submit field interactions to this owner; no shell
/// retains a second field value.
pub const FooterInput = union(enum) { enter, escape, text, click: ?FooterField, other };
pub const FooterDecision = struct {
    focus: FooterFocus,
    open_choice: ?FooterField = null,
    forward: bool = false,
};

/// Drawn clicks carry their identity even if newer facts removed the field.
pub fn footerInput(focus: FooterFocus, has_effort: bool, input: FooterInput) FooterDecision {
    return switch (input) {
        .click => |field| .{ .focus = .input, .open_choice = field, .forward = field == null },
        .enter => switch (focus) {
            .input => .{ .focus = .input, .forward = true },
            .model => .{ .focus = .input, .open_choice = .model },
            .effort => .{ .focus = .input, .open_choice = if (has_effort) .effort else null },
        },
        .escape => .{ .focus = .input, .forward = focus == .input },
        .text => .{ .focus = .input, .forward = true },
        .other => .{ .focus = focus, .forward = true },
    };
}

pub const Frame = struct {
    items: [std.enums.values(Target).len]Target = undefined,
    len: usize = 0,
    modal: bool = false,

    pub fn append(self: *Frame, target: Target) void {
        if (std.mem.indexOfScalar(Target, self.slice(), target) != null) return;
        self.items[self.len] = target;
        self.len += 1;
    }
    pub fn slice(self: *const Frame) []const Target {
        return self.items[0..self.len];
    }
};

/// Focus moves through the drawn order. Every screen sees the keys bound
/// here only when no drawn order takes them.
pub const Move = enum { next, previous };

/// The app's own key table: Tab and Shift-Tab, decided before any screen.
pub const keys: keymap.Keymap(Move) = .init(.{
    .escape = null,
    .ctrl_c = null,
    .ctrl_d = null,
    .ctrl_g = null,
    .ctrl_n = null,
    .ctrl_o = null,
    .ctrl_p = null,
    .ctrl_r = null,
    .ctrl_x = null,
    .alt_a = null,
    .alt_question = null,
    .alt_up = null,
    .alt_down = null,
    .up = null,
    .down = null,
    .left = null,
    .right = null,
    .tab = .next,
    .shift_tab = .previous,
    .shift_up = null,
    .shift_down = null,
    .page_up = null,
    .page_down = null,
    .home = null,
    .end = null,
    .ctrl_end = null,
});

/// The one wrapping traversal over a drawn order.
pub fn tabNext(order: []const Target, current: Target, reverse: bool) ?Target {
    return tabNextValue(Target, order, current, reverse);
}

/// Panels provide their drawn field identities; the wrapping policy is the
/// same owner used by the app's semantic frame and Session footer fallback.
pub fn tabNextValue(comptime T: type, order: []const T, current: T, reverse: bool) ?T {
    if (order.len == 0) return null;
    const at = std.mem.indexOfScalar(T, order, current) orelse return if (reverse) order[order.len - 1] else order[0];
    return order[(at + (if (reverse) order.len - 1 else @as(usize, 1))) % order.len];
}

/// A modal filter and its drawn results share one focus value. The filter
/// retains its candidate for Enter; there is no second widget focus flag.
pub const ChoiceFocus = union(enum) {
    filter: ?usize,
    row: usize,

    pub fn selected(self: ChoiceFocus) ?usize {
        return switch (self) {
            .filter => |at| at,
            .row => |at| at,
        };
    }
    pub fn select(self: *ChoiceFocus, at: ?usize) void {
        self.* = if (self.* == .filter or at == null) .{ .filter = at } else .{ .row = at.? };
    }
    pub fn edit(self: *ChoiceFocus) void {
        self.* = .{ .filter = self.selected() };
    }
    pub fn browse(self: *ChoiceFocus) void {
        if (self.selected()) |at| self.* = .{ .row = at };
    }
    pub fn tab(self: *ChoiceFocus, hits: []const usize, reverse: bool) void {
        if (hits.len == 0) return;
        const at = if (self.* == .filter) @as(usize, 0) else (std.mem.indexOfScalar(usize, hits, self.row) orelse 0) + 1;
        const count = hits.len + 1;
        const next = (at + (if (reverse) count - 1 else @as(usize, 1))) % count;
        self.* = if (next == 0) .{ .filter = self.selected() } else .{ .row = hits[next - 1] };
    }
};

pub const State = struct {
    layer: Layer = .main,
    /// The sole composer/footer field; shells only project this value.
    field: Field = .input,
    /// Keyboard navigation is in the list, while a wide chat stays drawn.
    area: union(enum) { main, list, settings_row, button: Target } = .main,

    /// Between a bracketed paste's start and end. Keys inside it are pasted
    /// text, never actions.
    pasting: bool = false,

    pub fn listFocused(self: State) bool {
        return self.area == .list;
    }
    pub fn mainFocused(self: State) bool {
        return self.area == .main;
    }
};

pub const Facts = struct {
    session_open: bool = false,
    settings: Settings = .{},
    wide: bool = false,
    frame: Frame = .{},
    /// The drawn slash list owns Tab before focus traversal.
    accepts_tab: bool = false,
    /// Semantic identity hit in the most recently drawn frame.
    mouse_target: ?Target = null,

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
    /// A core requests a footer interaction through this same transition.
    footer: struct { has_effort: bool, input: FooterInput },
    footer_tab: struct { has_effort: bool, reverse: bool },
    paste_start,
    paste_end,
    mouse: Mouse,
    key_release,
    colors,
    other,
    back_to_list,
    session_closed,
    focus_chat,
    /// Return to the composer after a pointer action or consent decision.
    focus_input,
    open_settings,
    show_main,
    open_sign_in,
    close_sign_in,
    signed_in,

    pub const Key = struct {
        named: ?keymap.Key,
        /// Enter as the line editor reads it.
        enter: bool = false,
    };
    pub const Mouse = enum { click, list_click, chat_click, wheel, motion };
};

pub const Effects = struct {
    page: Page = .keep,
    focus: ?Focus = null,
    route: Route = .pass,
    redraw: bool = false,
    field: ?Field = null,
    activate: ?Target = null,
    footer: ?FooterDecision = null,

    pub const Page = enum {
        keep,
        close_keys,
        cancel_choice,
        reset,
    };
    pub const Focus = enum { main, list, settings, sign_in };
    /// What a key the overview takes arrived under, and whether it is
    /// pasted text.
    pub const Delivery = struct { under: Layer.Covered, pasted: bool, wide: bool = false, list_origin: bool = true };
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
    return pane(state.layer, session_open and (wide or switch (state.area) {
        .list, .settings_row => false,
        else => true,
    }));
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
    const effects = stepInner(state, facts, input);
    if (effects.field) |field| state.field = field;
    return effects;
}

fn stepInner(state: *State, facts: Facts, input: Input) Effects {
    // Under main, resuming the chat only moves keys, as a chat-pane click
    // does. A page over main is left first, exactly as showing main leaves it.
    if (input == .focus_chat and state.layer == .main) return if (facts.session_open) focusChat(state) else .{};
    switch (input) {
        .footer => |interaction| {
            const decision = footerInput(state.field, interaction.has_effort, interaction.input);
            state.field = decision.focus;
            if (interaction.input != .other) state.area = .main;
            return .{ .footer = decision };
        },
        .footer_tab => |interaction| {
            const order = [_]Target{ .input, .model, .effort };
            const target = tabNext(order[0..if (interaction.has_effort) @as(usize, 3) else 2], currentFocus(state.*), interaction.reverse).?;
            var effect: Effects = .{};
            chooseFocus(state, target, &effect);
            return effect;
        },
        .focus_input => {
            if (state.layer != .main) return .{};
            state.area = .main;
            return .{ .field = .input, .focus = .main, .redraw = true };
        },
        .back_to_list => {
            if (!facts.wide or !facts.session_open or state.layer != .main) return .{};
            state.area = .list;
            return .{ .focus = .list, .redraw = true };
        },
        .session_closed => {
            state.area = .list;
            return if (state.layer == .main) .{ .focus = .main, .redraw = true } else .{};
        },
        .open_settings => {
            state.area = .main;
            state.layer = switch (state.layer) {
                .main, .settings => .settings,
                .sign_in => .{ .sign_in = .{ .over = .settings } },
            };
            return navigated(state.layer, .close_keys);
        },
        .show_main, .focus_chat => {
            state.area = .main;
            state.layer = switch (state.layer) {
                .main, .settings => .main,
                .sign_in => .{ .sign_in = .{ .over = .main } },
            };
            return navigated(state.layer, .reset);
        },
        .open_sign_in => {
            state.area = .main;
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
            state.area = .main;
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
    if (state.layer == .main and !state.pasting and input == .key and !(facts.frame.modal and facts.session_open) and (input.key.named == .alt_up or input.key.named == .alt_down or input.key.named == .alt_question))
        return .{ .route = .{ .overview = .{ .under = .main, .pasted = false, .wide = facts.wide, .list_origin = state.listFocused() or !facts.session_open } } };
    if (input == .key and !state.pasting and !facts.frame.modal) {
        const move = if (facts.accepts_tab and state.area == .main and state.field == .input and input.key.named == .tab) null else if (input.key.named) |name| keys.get(name) else null;
        if (move) |direction| if (tabNext(facts.frame.slice(), currentFocus(state.*), direction == .previous)) |target| {
            var effect: Effects = .{ .route = .swallow, .redraw = true };
            chooseFocus(state, target, &effect);
            return effect;
        };
        switch (state.area) {
            .settings_row, .button => {
                if (input.key.enter) return .{ .activate = currentFocus(state.*), .route = .swallow, .redraw = true };
                if (input.key.named == .escape or input.key.named == .ctrl_g) {
                    state.area = .main;
                    return .{ .field = .input, .focus = .main, .route = .swallow, .redraw = true };
                }
                state.area = .main;
                return .{ .field = .input, .focus = .main, .route = if (facts.session_open) .{ .session = .{ .under = .main, .pasted = false } } else .{ .overview = .{ .under = .main, .pasted = false } }, .redraw = true };
            },
            else => {},
        }
    }

    if (state.layer == .main and input == .mouse and !facts.frame.modal and facts.mouse_target != null and (input.mouse == .click or input.mouse == .list_click or input.mouse == .chat_click)) {
        var effect: Effects = .{ .redraw = true };
        // A pointer activates the drawn control through its normal widget
        // path. Focus is decided here first, never by the shell callback.
        const target = facts.mouse_target.?;
        chooseFocus(state, if (target == .model or target == .effort) .input else target, &effect);
        return effect;
    }
    if (state.layer == .main and input == .paste_start and !facts.frame.modal and (state.area == .button or state.area == .settings_row)) {
        state.area = .main;
        return .{ .field = .input, .focus = .main, .redraw = true, .route = if (facts.session_open) .{ .session = .{ .under = .main, .pasted = true } } else .{ .overview = .{ .under = .main, .pasted = true } } };
    }
    if (state.layer == .main and input == .mouse and facts.session_open and !facts.frame.modal) switch (input.mouse) {
        .list_click => {
            state.area = .list;
            return .{ .focus = .list, .redraw = true };
        },
        .chat_click => {
            state.area = .main;
            return .{ .field = .input, .focus = .main, .redraw = true };
        },
        else => {},
    };
    if (state.layer != .main or input == .mouse) return .{};
    const delivery: Effects.Delivery = .{ .under = .main, .pasted = state.pasting };
    if (facts.frame.modal and facts.session_open) return .{ .route = .{ .session = delivery } };
    if (state.listFocused()) return .{ .route = .{ .overview = .{ .under = .main, .pasted = state.pasting, .wide = facts.wide } } };
    return .{ .route = if (facts.session_open) .{ .session = delivery } else .{ .overview = .{ .under = .main, .pasted = state.pasting, .wide = facts.wide } } };
}

pub fn currentFocus(state: State) Target {
    return switch (state.area) {
        .list => .list,
        .settings_row => .settings_row,
        .button => |target| target,
        .main => switch (state.field) {
            .input => .input,
            .model => .model,
            .effort => .effort,
        },
    };
}

fn chooseFocus(state: *State, target: Target, effect: *Effects) void {
    switch (target) {
        .list => {
            state.area = .list;
            effect.focus = .list;
        },
        .settings_row => {
            state.area = .settings_row;
            effect.focus = .list;
        },
        .input, .model, .effort => {
            state.area = .main;
            effect.field = switch (target) {
                .input => .input,
                .model => .model,
                .effort => .effort,
                else => unreachable,
            };
            effect.focus = .main;
        },
        else => {
            state.area = .{ .button = target };
            effect.focus = .list;
        },
    }
}

fn focusChat(state: *State) Effects {
    state.area = .main;
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
    const pressed = [_]Event{ .printable, .pasted_printable, .enter, .pasted_enter, .escape, .ctrl_g, .ctrl_c };
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
        // Sign-in takes keys and pastes; the paste is still one.
        .{ .layers = &signing, .events = &pressed, .effects = .{ .route = .sign_in } },
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
        var state: State = .{ .area = .list };
        for ([_]bool{ false, true }) |enter| {
            const result = step(&state, .{ .session_open = wide, .wide = wide }, .{ .key = .{ .named = null, .enter = enter } });
            try std.testing.expectEqual(Effects.Route{ .overview = .{ .under = .main, .pasted = false, .wide = wide } }, result.route);
            try std.testing.expect(state.listFocused());
        }
        const resumed = step(&state, .{ .session_open = true, .wide = wide }, .focus_chat);
        try std.testing.expectEqual(@as(?Effects.Focus, .main), resumed.focus);
        try std.testing.expect(!state.listFocused());
    }
}

test "App input list activation and chat-pane click share one focus transition that keeps the chat's presentation" {
    const layers = [_]Layer{ .main, .settings, .{ .sign_in = .{ .over = .main } }, .{ .sign_in = .{ .over = .settings } } };
    for (layers) |layer| for ([_]bool{ false, true }) |wide| for ([_]bool{ false, true }) |session_open| for ([_]bool{ false, true }) |list_focused| {
        const facts: Facts = .{ .session_open = session_open, .wide = wide };
        var activated: State = .{ .layer = layer, .area = if (list_focused) .list else .main };
        const resume_effects = step(&activated, facts, .focus_chat);
        try std.testing.expectEqual(Effects.Route.pass, resume_effects.route);
        if (layer != .main) {
            // Over a page, activation leaves it as showing main does.
            var shown: State = .{ .layer = layer, .area = if (list_focused) .list else .main };
            try std.testing.expectEqualDeep(step(&shown, facts, .show_main), resume_effects);
            try std.testing.expectEqualDeep(shown, activated);
            continue;
        }
        try std.testing.expectEqual(Effects.Page.keep, resume_effects.page);
        try std.testing.expectEqual(Layer.main, activated.layer);
        try std.testing.expectEqual(if (session_open) false else list_focused, activated.listFocused());
        try std.testing.expectEqual(if (session_open) @as(?Effects.Focus, .main) else null, resume_effects.focus);
        if (!session_open or !wide) continue;
        var clicked: State = .{ .layer = layer, .area = if (list_focused) .list else .main };
        const click_effects = step(&clicked, facts, .{ .mouse = .chat_click });
        // A pointer into chat additionally chooses the composer; resuming
        // by keyboard preserves the existing footer field.
        try std.testing.expectEqual(@as(?Field, .input), click_effects.field);
        try std.testing.expectEqual(resume_effects.focus, click_effects.focus);
        try std.testing.expectEqual(resume_effects.page, click_effects.page);
        try std.testing.expectEqualDeep(activated, clicked);
    };
}

test "App input list focus routes every list event to its semantic owner and mouse returns focus" {
    for ([_]bool{ false, true }) |pasting| {
        var state: State = .{ .area = .list, .pasting = pasting };
        for ([_]Input{ .{ .key = .{ .named = null } }, .paste_start, .paste_end }) |input| {
            const result = step(&state, .{ .session_open = true, .wide = true }, input);
            try std.testing.expect(result.route == .overview);
        }
    }
    var state: State = .{};
    const facts: Facts = .{ .session_open = true, .wide = true };
    const list = step(&state, facts, .{ .mouse = .list_click });
    try std.testing.expect(state.listFocused());
    try std.testing.expectEqual(@as(?Effects.Focus, .list), list.focus);
    const chat = step(&state, facts, .{ .mouse = .chat_click });
    try std.testing.expect(!state.listFocused());
    try std.testing.expectEqual(@as(?Effects.Focus, .main), chat.focus);
}

test "App input Tab order follows each drawn frame at wide and narrow widths and traps panels" {
    for ([_]bool{ false, true }) |wide| for (std.enums.values(enum { overview, chat, info, settings, keys })) |shown| {
        var frame: Frame = .{ .modal = shown == .info };
        const session_open = shown != .overview;
        if (wide or !session_open) {
            frame.append(.list);
            frame.append(.settings_row);
        }
        if (session_open and shown != .settings and shown != .keys) {
            frame.append(.input);
            if (!wide) frame.append(.back);
            frame.append(.model);
            frame.append(.effort);
            frame.append(.info);
        }
        for (frame.slice(), 0..) |target, index| for ([_]bool{ false, true }) |reverse| {
            var state: State = .{ .layer = if (shown == .settings or shown == .keys) .settings else .main };
            var initial: Effects = .{};
            chooseFocus(&state, target, &initial);
            state.field = initial.field orelse .input;
            const facts: Facts = .{ .wide = wide, .session_open = session_open, .frame = frame, .settings = .{ .takes_key = true, .keys_open = shown == .keys } };
            const result = step(&state, facts, .{ .key = .{ .named = if (reverse) .shift_tab else .tab } });
            if (shown == .settings or shown == .keys) {
                // The page owns its fields; the read-only Keys reference has no stops.
                try std.testing.expectEqual(Effects.Route.pass, result.route);
                try std.testing.expect(result.focus == null and result.activate == null);
            } else if (shown == .info) {
                try std.testing.expect(result.route == .session);
                try std.testing.expectEqual(target, currentFocus(state));
            } else {
                const expected = frame.slice()[(index + (if (reverse) frame.len - 1 else @as(usize, 1))) % frame.len];
                try std.testing.expectEqual(expected, currentFocus(state));
                try std.testing.expectEqual(Effects.Route.swallow, result.route);
            }
        };
    };
}

test "App input Tab never activates or edits and paste cannot traverse" {
    var frame: Frame = .{};
    for ([_]Target{ .list, .settings_row, .input, .model, .effort, .info }) |target| frame.append(target);
    var state: State = .{ .area = .list };
    const facts: Facts = .{ .session_open = true, .wide = true, .frame = frame };
    _ = step(&state, facts, .{ .key = .{ .named = .tab } });
    try std.testing.expectEqual(Target.settings_row, currentFocus(state));
    const activate = step(&state, facts, .{ .key = .{ .named = null, .enter = true } });
    try std.testing.expectEqual(@as(?Target, .settings_row), activate.activate);
    state.pasting = true;
    const pasted = step(&state, facts, .{ .key = .{ .named = .tab } });
    try std.testing.expect(pasted.activate == null and pasted.focus == null);
    try std.testing.expectEqual(Target.settings_row, currentFocus(state));
}

test "App input model choice Tab domain retains its candidate in the filter and excludes hidden rows" {
    const hits = [_]usize{ 3, 7, 11 };
    for (0..4) |index| for ([_]bool{ false, true }) |reverse| {
        var focus: ChoiceFocus = if (index == 0) .{ .filter = 99 } else .{ .row = hits[index - 1] };
        focus.tab(&hits, reverse);
        const expected = (index + (if (reverse) @as(usize, 3) else 1)) % 4;
        try std.testing.expectEqual(expected == 0, focus == .filter);
        if (expected != 0) try std.testing.expectEqual(@as(?usize, hits[expected - 1]), focus.selected());
    };
    var focus: ChoiceFocus = .{ .filter = 7 };
    focus.tab(&.{}, false);
    try std.testing.expectEqual(@as(?usize, 7), focus.selected());
    try std.testing.expect(focus == .filter);
}

test "App input paste completion routes to the same owner for every focus and paste shape" {
    for ([_]bool{ false, true }) |wide| for ([_]bool{ false, true }) |session_open| for ([_]bool{ false, true }) |list_focused| for ([_][]const u8{ "", "\n", "text" }) |paste| {
        var state: State = .{ .area = if (list_focused) .list else .main };
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
        try std.testing.expectEqual(list_focused, state.listFocused());
    };
}

test "Option session navigation routes main chords without taking paste or modal custody" {
    for ([_]keymap.Key{ .alt_up, .alt_down, .alt_question }) |key| for ([_]bool{ false, true }) |wide| for ([_]bool{ false, true }) |open| for ([_]bool{ false, true }) |focused| for ([_]bool{ false, true }) |pasted| for ([_]Layer{ .main, .settings, .{ .sign_in = .{ .over = .main } } }) |layer| {
        var state: State = .{ .layer = layer, .area = if (focused) .list else .main, .pasting = pasted };
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
                if (!pasted) try std.testing.expectEqual(focused or !open, effects.route.overview.list_origin);
            } else try std.testing.expect(effects.route == .session);
        }
        try std.testing.expectEqual(focused, state.listFocused());
        try std.testing.expectEqual(pasted, state.pasting);
        try std.testing.expect(effects.focus == null);
    };
}

test "drawn slash acceptance owns Tab but not reverse focus traversal" {
    var frame: Frame = .{};
    frame.append(.input);
    frame.append(.model);
    for ([_]bool{ false, true }) |accepts| {
        var state: State = .{};
        const effect = step(&state, .{ .session_open = true, .frame = frame, .accepts_tab = accepts }, .{ .key = .{ .named = .tab } });
        if (accepts) {
            try std.testing.expect(effect.route == .session);
            try std.testing.expectEqual(@as(?Field, null), effect.field);
        } else {
            try std.testing.expect(effect.route == .swallow);
            try std.testing.expectEqual(@as(?Field, .model), effect.field);
        }
    }
    var state: State = .{};
    const reverse = step(&state, .{ .session_open = true, .frame = frame, .accepts_tab = true }, .{ .key = .{ .named = .shift_tab } });
    try std.testing.expect(reverse.route == .swallow);
    try std.testing.expectEqual(@as(?Field, .model), reverse.field);
}

test "panel identities share wrapping traversal and absent focus recovery" {
    const order = [_]usize{ 2, 5, 9 };
    try std.testing.expectEqual(@as(?usize, 5), tabNextValue(usize, &order, 2, false));
    try std.testing.expectEqual(@as(?usize, 2), tabNextValue(usize, &order, 9, false));
    try std.testing.expectEqual(@as(?usize, 9), tabNextValue(usize, &order, 2, true));
    try std.testing.expectEqual(@as(?usize, 2), tabNextValue(usize, &order, 4, false));
    try std.testing.expectEqual(@as(?usize, 9), tabNextValue(usize, &order, 4, true));
    try std.testing.expectEqual(@as(?usize, null), tabNextValue(usize, &.{}, 2, false));
}

test "drawn slash Tab exemption does not trap sidebar or footer focus" {
    var frame: Frame = .{};
    frame.append(.list);
    frame.append(.input);
    frame.append(.model);
    frame.append(.effort);
    var sidebar: State = .{ .area = .list };
    const into_input = step(&sidebar, .{ .session_open = true, .frame = frame, .accepts_tab = true }, .{ .key = .{ .named = .tab } });
    try std.testing.expect(into_input.route == .swallow);
    try std.testing.expectEqual(@as(?Field, .input), into_input.field);
    try std.testing.expect(sidebar.area == .main);

    var footer: State = .{ .field = .model };
    const into_effort = step(&footer, .{ .session_open = true, .frame = frame, .accepts_tab = true }, .{ .key = .{ .named = .tab } });
    try std.testing.expect(into_effort.route == .swallow);
    try std.testing.expectEqual(@as(?Field, .effort), into_effort.field);
}
