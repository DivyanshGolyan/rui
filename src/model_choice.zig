const std = @import("std");
const connection_names = @import("connection_names.zig");
const provider_route = @import("provider_route.zig");
const connection = @import("connection.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const picker = @import("model_picker.zig");
const picker_view = @import("model_picker_view.zig");
const catalog = @import("model_catalog.zig");
const Editor = @import("DraftEditor.zig");
const keymap = @import("keymap.zig");
const keypress = @import("keypress.zig");
const panel_editor = @import("panel_editor.zig");
const Panel = @import("widgets/Panel.zig");
const Hover = @import("widgets/Hover.zig");
const Self = @This();
const RowInset = @import("widgets/RowInset.zig");

pub const Snapshot = struct {
    menu: ?*const picker.Menu = null,
    revision: u64 = 0,
    ready: bool = true,
    /// The connections at a usage limit now: their rows say so and name another connection that serves the model.
    limited: connection_names.NameSet = .{},
};
pub const Source = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) Snapshot,
};

/// What the caller decides before each draw: the look, whether the list shows its overflow, and what a pick calls.
pub const Props = struct {
    unicode: bool = true,
    show_more: bool = true,
    userdata: ?*anyopaque = null,
    on_pick: ?*const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
    ground: vaxis.Style = .{},
    selection: vaxis.Style = .{ .reverse = true },
    hover_style: vaxis.Style = .{ .ul_style = .single },
    quiet: vaxis.Style = .{ .dim = true },
};

const fallback_entries = blk: {
    @setEvalBranchQuota(20000);
    var entries: [catalog.openai_ids.len]picker.Entry = undefined;
    for (catalog.openai_ids, 0..) |id, at| entries[at] = .{ .id = id, .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&provider_route.built_in_names) };
    break :blk entries;
};
const fallback: picker.Menu = .{ .entries = &fallback_entries };

props: Props = .{},
active: bool = false,
source: ?Source = null,
revision: u64 = 0,
menu: *const picker.Menu = &fallback,
provider: connection.Name = provider_route.nameOf(.codex),
current: []const u8 = "",
focus: @import("app_input.zig").ChoiceFocus = .{ .filter = null },
filter_drawn: bool = false,
scroll: usize = 0,
query_bytes: [catalog.max_model_bytes]u8 = undefined,
editor: Editor = .initLocked(&.{}, .line_refusals_release),
pasting: bool = false,
no_match: bool = false,
failure: ?[]const u8 = null,
hits: []const usize = &.{},
hover: Hover = .{},

pub fn present(self: *Self, props: Props) void {
    self.props = props;
}

pub fn open(self: *Self, menu: ?*const picker.Menu, provider: connection.Name, current: []const u8) void {
    self.source = null;
    self.menu = menu orelse &fallback;
    self.provider = provider;
    self.current = current;
    self.editor = .initLocked(&self.query_bytes, .line_refusals_release);
    self.no_match = false;
    self.failure = null;
    self.pasting = false;
    self.scroll = 0;
    self.focus = .{ .filter = null };
    for (self.menu.entries, 0..) |entry, at| if (self.row(entry) != null) {
        if (self.focus.selected() == null or std.mem.eql(u8, entry.id, current)) self.focus.select(at);
    };
    self.active = self.focus.selected() != null;
}

pub fn openSource(self: *Self, source: Source, provider: connection.Name, current: []const u8) void {
    const snapshot = source.read(source.context);
    self.open(snapshot.menu, provider, current);
    self.source = source;
    self.revision = snapshot.revision;
}

pub fn validate(self: *Self) bool {
    if (!self.active) return false;
    if (self.source) |source| {
        const snapshot = source.read(source.context);
        if (snapshot.revision != self.revision or (snapshot.menu orelse &fallback) != self.menu) self.cancel();
    }
    return self.active;
}

pub fn takesKey(key: vaxis.Key) bool {
    if (keypress.named(key)) |name| if (@import("app_input.zig").keys.get(name) != null) return true;
    return keypress.named(key) == null or key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.right, .{});
}

pub fn cancel(self: *Self) void {
    _ = self.editor.blur();
    self.active = false;
    self.hits = &.{};
    self.hover.targets = &.{};
}

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn field(self: *Self, index: usize) Panel.CustomChoice {
    return .{ .field = index, .widget = self.widget(), .value_widget = .{ .userdata = self, .drawFn = drawInput }, .reset_draw = resetDraw };
}

fn resetDraw(raw: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.filter_drawn = false;
    self.hits = &.{};
    self.hover.targets = &.{};
}

fn drawInput(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.props.ground });
    if (!self.validate() or size.width == 0 or size.height == 0) return surface;
    const original = self.editor.text();
    const bytes = try Panel.displayText(ctx.arena, original, self.props.unicode);
    const cursor = (try Panel.displayText(ctx.arena, original[0..self.editor.cursor()], self.props.unicode)).len;
    const tail = try Panel.displayText(ctx.arena, self.failure orelse if (self.no_match) " · no matches" else "", self.props.unicode);
    const tail_width: u16 = @intCast(@min(ctx.stringWidth(tail), size.width));
    const edit_width = size.width - tail_width;
    var start: usize = 0;
    var iter = ctx.graphemeIterator(bytes);
    while (ctx.stringWidth(bytes[start..cursor]) >= edit_width and start < cursor) {
        start += (iter.next() orelse break).len;
    }
    paint(ctx, surface, bytes[start..], 0, 0, edit_width, self.props.ground);
    paint(ctx, surface, tail, 0, edit_width, size.width, self.props.quiet);
    self.filter_drawn = edit_width > 0;
    if (edit_width > 0 and self.focus == .filter) surface.cursor = .{ .row = 0, .col = @intCast(ctx.stringWidth(bytes[start..cursor])) };
    return surface;
}

/// The connection name the open choice picks for.
pub fn providerName(self: *const Self) []const u8 {
    return self.provider.slice();
}

fn row(self: *const Self, entry: picker.Entry) ?picker.Row {
    if (!entry.providers.contains(self.provider)) return null;
    var constrained = entry;
    constrained.providers = .of(&.{self.provider});
    return picker.Query.parse(self.editor.text()).row(constrained, .{ .model = self.current, .provider = self.provider });
}

fn move(self: *Self, down: bool) void {
    self.focus.browse();
    var at = self.focus.selected() orelse return;
    while (if (down) at + 1 < self.menu.entries.len else at > 0) {
        at = if (down) at + 1 else at - 1;
        if (self.row(self.menu.entries[at]) != null) {
            self.focus.select(at);
            return;
        }
    }
}

fn pick(self: *Self, ctx: *vxfw.EventContext) !void {
    const at = self.focus.selected() orelse return;
    const id = self.menu.entries[at].id;
    self.cancel();
    if (self.props.on_pick) |callback| try callback(self.props.userdata.?, ctx, id);
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (!self.validate()) {
        try self.hover.handleEvent(ctx, .mouse_leave);
        ctx.consumeAndRedraw();
        return;
    }
    try self.hover.handleEvent(ctx, input);
    if (input == .key_press and !self.pasting and !takesKey(input.key_press)) return;
    if (input == .mouse) {
        const mouse = input.mouse;
        switch (mouse.button) {
            .wheel_up => self.move(false),
            .wheel_down => self.move(true),
            .left => {
                if (mouse.type != .press or mouse.row < 0) return;
                const at: usize = @intCast(mouse.row);
                if (at >= self.hits.len or !self.hover.targets[at].contains(mouse.col, mouse.row)) return;
                self.focus = .{ .row = self.hits[at] };
                try self.pick(ctx);
            },
            else => return,
        }
        ctx.consumeAndRedraw();
        return;
    }
    if (input == .key_press and !self.pasting) {
        const key = input.key_press;
        if (@import("keypress.zig").named(key)) |name| if (@import("app_input.zig").keys.get(name)) |direction| {
            if (self.filter_drawn) {
                self.focus.tab(self.hits, direction == .previous);
            } else if (self.focus.selected()) |current| {
                if (@import("app_input.zig").tabNextValue(usize, self.hits, current, direction == .previous)) |next| self.focus = .{ .row = next };
            }
            ctx.consumeAndRedraw();
            return;
        };
        if (key.matches(vaxis.Key.escape, .{})) return;
        if (key.matches(vaxis.Key.up, .{})) {
            self.move(false);
            ctx.consumeAndRedraw();
            return;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.move(true);
            ctx.consumeAndRedraw();
            return;
        }
    }
    var backup: [catalog.max_model_bytes]u8 = undefined;
    @memcpy(backup[0..self.editor.text().len], self.editor.text());
    const length = self.editor.text().len;
    const cursor = self.editor.cursor();
    if (input == .paste_start) self.pasting = true;
    defer if (input == .paste_end) {
        self.pasting = false;
    };
    self.focus.edit();
    const outcome = panel_editor.event(&self.editor, input, self.pasting, &self.failure);
    if (outcome == .submit) {
        try self.pick(ctx);
    } else if (outcome == .append or outcome == .redraw) {
        var first: ?usize = null;
        var kept = false;
        for (self.menu.entries, 0..) |entry, at| if (self.row(entry) != null) {
            if (first == null) first = at;
            if (self.focus.selected() == at) kept = true;
        };
        self.no_match = first == null;
        if (first == null) {
            self.editor.revert(backup[0..length], cursor);
        } else if (!kept) self.focus.select(first);
    }
    ctx.consumeAndRedraw();
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.hits = &.{};
    self.hover.targets = &.{};
    const limit = ctx.max.size();
    if (!self.validate()) return vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = limit.width, .height = 0 });
    var indices: std.array_list.Managed(usize) = .init(ctx.arena);
    var selected_row: usize = 0;
    for (self.menu.entries, 0..) |entry, at| if (self.row(entry) != null) {
        if (self.focus.selected() == at) selected_row = indices.items.len;
        try indices.append(at);
    };
    const size: vxfw.Size = .{ .width = limit.width, .height = @intCast(@min(limit.height, indices.items.len)) };
    var surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.props.ground });
    if (size.width == 0 or size.height == 0) return surface;
    var capacity = size.height - @intFromBool(self.props.show_more and indices.items.len > size.height and size.height > 1);
    if (selected_row < self.scroll) self.scroll = selected_row;
    if (selected_row >= self.scroll + capacity) self.scroll = selected_row - capacity + 1;
    self.scroll = @min(self.scroll, indices.items.len -| capacity);
    var end = @min(self.scroll + capacity, indices.items.len);
    if (end == indices.items.len and capacity < size.height) {
        capacity = size.height;
        self.scroll = @min(self.scroll, indices.items.len - capacity);
        end = indices.items.len;
    }
    const shown = indices.items[self.scroll..end];
    var widest: usize = 0;
    for (shown) |at| widest = @max(widest, self.menu.entries[at].id.len);
    self.hits = shown;
    const targets = try ctx.arena.alloc(Hover.Rect, shown.len);
    for (targets, 0..) |*target, y| target.* = .{ .row = @intCast(y), .width = size.width };
    self.hover.targets = targets;
    const limited = if (self.source) |source| source.read(source.context).limited else connection_names.NameSet{};
    for (shown, 0..) |at, y| {
        const entry = self.menu.entries[at];
        const line = try picker_view.modelLine(ctx.arena, entry, self.row(entry).?, widest, RowInset.bounds(size.width).end -| 3, self.props.unicode);
        const style = if (self.focus == .row and self.focus.row == at) self.props.selection else if (self.hover.contains(targets[y])) self.props.hover_style else self.props.ground;
        for (0..size.width) |x| surface.writeCell(@intCast(x), @intCast(y), .{ .style = style });
        const inset = RowInset.bounds(size.width);
        paint(ctx, surface, line.text, @intCast(y), @min(3, inset.end), inset.end, style);
        // The drawn cells point at their bytes, so the note lives in the frame's arena.
        const note_bytes = try ctx.arena.alloc(u8, picker.max_limit_note);
        if (picker.limitNote(note_bytes[0..picker.max_limit_note], entry.providers, self.provider, limited)) |note| {
            var dim = style;
            dim.dim = true;
            const gap = 2;
            const start = @min(3, inset.end) + ctx.stringWidth(line.text) + gap;
            if (start < inset.end) paint(ctx, surface, note, @intCast(y), @intCast(start), inset.end, dim);
        }
    }
    if (self.props.show_more and end < indices.items.len and size.height > 1) {
        const more = try std.fmt.allocPrint(ctx.arena, "{s} {d} more", .{ if (self.props.unicode) "↓" else "v", indices.items.len - end });
        paint(ctx, surface, more, size.height - 1, @min(3, size.width), size.width, self.props.quiet);
    }
    return surface;
}

fn paint(ctx: vxfw.DrawContext, surface: vxfw.Surface, text: []const u8, y: u16, start: u16, end: u16, style: vaxis.Style) void {
    var x = start;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |part| {
        const bytes = part.bytes(text);
        const width = ctx.stringWidth(bytes);
        if (width > end - x) break;
        if (width == 0) continue;
        surface.writeCell(x, y, .{ .char = .{ .grapheme = bytes, .width = @intCast(width) }, .style = style });
        x += @intCast(width);
    }
}

const Fixture = struct {
    picked: ?[]const u8 = null,
    fn pickModel(raw: *anyopaque, _: *vxfw.EventContext, id: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.picked = id;
    }
};

fn press(choice: *Self, ctx: *vxfw.EventContext, key: u21) !void {
    try choice.widget().handleEvent(ctx, .{ .key_press = .{ .codepoint = key } });
}

/// How many of the two rows above the overflow line, or of three without it, are drawn in `style` at column 5.
fn styledRows(surface: vxfw.Surface, style: vaxis.Style) usize {
    var count: usize = 0;
    for (0..surface.size.height) |at_row| {
        if (std.meta.eql(surface.readCell(5, @intCast(at_row)).style, style)) count += 1;
    }
    return count;
}

const Second = struct {
    picked: ?[]const u8 = null,
    fn pickModel(raw: *anyopaque, _: *vxfw.EventContext, id: []const u8) !void {
        const self: *Second = @ptrCast(@alignCast(raw));
        self.picked = id;
    }
};

test "SUI-185 a model choice uses the inputs it was last given, all of them at once" {
    const ids = [_][]const u8{ "gpt-5.1", "gpt-5.2", "gpt-5.3", "gpt-5.4", "gpt-5.5" };
    var entries: [ids.len]picker.Entry = undefined;
    for (ids, &entries) |id, *entry| entry.* = .{ .id = id, .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&provider_route.built_in_names) };
    const menu: picker.Menu = .{ .entries = &entries };
    var first: Fixture = .{};
    var second: Second = .{};
    var choice: Self = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 3 }, .cell_size = .{} };
    const ground: vaxis.Style = .{ .bg = .{ .index = 1 } };
    const selection: vaxis.Style = .{ .bg = .{ .index = 2 } };
    const quiet: vaxis.Style = .{ .bg = .{ .index = 4 } };

    // Presented with a look, ASCII and overflow: the focused row, the other rows and the overflow line are drawn with it.
    choice.present(.{ .unicode = false, .show_more = true, .userdata = &first, .on_pick = Fixture.pickModel, .ground = ground, .selection = selection, .quiet = quiet });
    choice.open(&menu, provider_route.nameOf(.codex), "gpt-5.5");
    try press(&choice, &ctx, vaxis.Key.up);
    var drawn = try choice.widget().draw(draw_ctx);
    try std.testing.expectEqual(@as(usize, 1), styledRows(drawn, selection));
    try std.testing.expectEqual(@as(usize, 1), styledRows(drawn, ground));
    try std.testing.expectEqualStrings("v", drawn.readCell(3, 2).char.grapheme);
    try std.testing.expectEqual(quiet, drawn.readCell(3, 2).style);

    // A pick calls the callback and userdata it was last presented with, and presenting another replaces both.
    const picked_first = menu.entries[choice.focus.selected().?].id;
    try press(&choice, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings(picked_first, first.picked.?);
    choice.present(.{ .userdata = &second, .on_pick = Second.pickModel });
    choice.open(&menu, provider_route.nameOf(.codex), "gpt-5.2");
    try press(&choice, &ctx, vaxis.Key.up);
    const picked_second = menu.entries[choice.focus.selected().?].id;
    try press(&choice, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings(picked_second, second.picked.?);
    try std.testing.expectEqualStrings(picked_first, first.picked.?);

    // Inputs the latest present leaves out are back at their defaults: Unicode overflow arrow, the default look.
    choice.open(&menu, provider_route.nameOf(.codex), "gpt-5.5");
    try press(&choice, &ctx, vaxis.Key.up);
    drawn = try choice.widget().draw(draw_ctx);
    try std.testing.expectEqualStrings("↓", drawn.readCell(3, 2).char.grapheme);
    try std.testing.expectEqual((Props{}).quiet, drawn.readCell(3, 2).style);
    try std.testing.expectEqual(@as(usize, 1), styledRows(drawn, (Props{}).selection));

    // Without the overflow setting the last row is a row, not the overflow line.
    choice.present(.{ .show_more = false, .userdata = &second, .on_pick = Second.pickModel });
    drawn = try choice.widget().draw(draw_ctx);
    try std.testing.expect(!std.mem.eql(u8, "↓", drawn.readCell(3, 2).char.grapheme));
    try std.testing.expectEqual(@as(usize, 2), styledRows(drawn, (Props{}).ground));
}

test "Model choice shares picker rows filters never empty and picks only its provider" {
    const entries = [_]picker.Entry{
        .{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
        .{ .id = "gpt-5.5", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&provider_route.built_in_names) },
        .{ .id = "api-only", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.openai)}) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    var fixture: Fixture = .{};
    var choice: Self = .{ .props = .{ .userdata = &fixture, .on_pick = Fixture.pickModel } };
    choice.open(&menu, provider_route.nameOf(.codex), "gpt-6.1-sol");
    try std.testing.expect(choice.active);
    try std.testing.expectEqual(@as(?usize, 0), choice.focus.selected());
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 99, 46 }) |width| {
        const drawn = try choice.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 8 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(usize, 2), choice.hits.len);
        try std.testing.expectEqualStrings("g", drawn.readCell(5, 0).char.grapheme);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (drawn.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "1M") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "API key") == null);
    }
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '5', .text = "5.5" } });
    try std.testing.expectEqual(@as(?usize, 1), choice.focus.selected());
    try std.testing.expectEqualStrings("5.5", choice.editor.text());
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'z', .text = "zzz" } });
    try std.testing.expect(choice.no_match);
    try std.testing.expectEqualStrings("5.5", choice.editor.text());
    try std.testing.expectEqual(@as(?usize, 1), choice.focus.selected());
    try press(&choice, &ctx, vaxis.Key.down);
    try std.testing.expectEqual(@as(?usize, 1), choice.focus.selected());
    try press(&choice, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings("gpt-5.5", fixture.picked.?);
    try std.testing.expect(!choice.active);
    choice.open(&menu, provider_route.nameOf(.openai), "api-only");
    try std.testing.expectEqual(@as(?usize, 2), choice.focus.selected());
    choice.cancel();
    try std.testing.expect(!choice.active);
    try std.testing.expectEqualStrings("gpt-5.5", fixture.picked.?);
    const empty: picker.Menu = .{};
    choice.open(&empty, provider_route.nameOf(.codex), "");
    try std.testing.expect(!choice.active);
}

test "Model choice keeps a chat on its own way into ChatGPT, and either ChatGPT word finds it" {
    const entries = [_]picker.Entry{
        .{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&provider_route.built_in_names) },
        .{ .id = "browser-only", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.chatgpt)}) },
        .{ .id = "device-only", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
        .{ .id = "key-only", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.openai)}) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    const Case = struct { provider: connection.Name, own: []const u8, found: [3]bool };
    const words = [3][]const u8{ "chatgpt", "codex", "api" };
    for ([_]Case{
        .{ .provider = provider_route.nameOf(.codex), .own = "device-only", .found = .{ true, true, false } },
        .{ .provider = provider_route.nameOf(.chatgpt), .own = "browser-only", .found = .{ true, true, false } },
        .{ .provider = provider_route.nameOf(.openai), .own = "key-only", .found = .{ false, false, true } },
    }) |case| {
        var fixture: Fixture = .{};
        var choice: Self = .{ .props = .{ .userdata = &fixture, .on_pick = Fixture.pickModel } };
        choice.open(&menu, case.provider, case.own);
        try std.testing.expect(choice.active);
        try std.testing.expectEqualStrings(case.own, entries[choice.focus.selected().?].id);
        for (entries) |entry| {
            const offered = std.mem.eql(u8, entry.id, "gpt-6.1-sol") or std.mem.eql(u8, entry.id, case.own);
            try std.testing.expectEqual(offered, choice.row(entry) != null);
        }
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        for (words, case.found) |word, found| {
            choice.open(&menu, case.provider, case.own);
            try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = word[0], .text = word } });
            try std.testing.expectEqual(!found, choice.no_match);
            try std.testing.expectEqualStrings(case.own, entries[choice.focus.selected().?].id);
        }
    }
}

test "Model choice bounds scrolling and mouse picking use the visible list" {
    var fixture: Fixture = .{};
    var choice: Self = .{ .props = .{ .userdata = &fixture, .on_pick = Fixture.pickModel } };
    choice.open(null, provider_route.nameOf(.codex), "");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for (0..8) |_| try press(&choice, &ctx, vaxis.Key.down);
    const wanted = choice.menu.entries[choice.focus.selected().?].id;
    const drawn = try choice.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 99, .height = 3 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 99), drawn.size.width);
    try std.testing.expect(choice.scroll > 0);
    try choice.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 2, .col = 20 } });
    try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
    try choice.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = @intCast(choice.hits.len - 1), .col = 20 } });
    try std.testing.expectEqualStrings(wanted, fixture.picked.?);
    for (0..9) |width| for (0..5) |height| {
        _ = try choice.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
    };
}

test "Model choice invalidates every replaced or released source before keys mouse or drawing" {
    const Live = struct {
        const old = [_]picker.Entry{
            .{ .id = "old-a", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&provider_route.built_in_names) },
            .{ .id = "old-b", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&provider_route.built_in_names) },
        };
        const replacements = [_][]const picker.Entry{
            &.{old[0]},
            &.{ old[1], old[0] },
            &.{},
            &.{ .{ .id = "new-a", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&provider_route.built_in_names) }, old[0] }, // same length
        };
        menu: picker.Menu = .{ .entries = &old },
        revision: u64 = 0,
        fn read(raw: *anyopaque) Snapshot {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .menu = &self.menu, .revision = self.revision };
        }
    };
    for (Live.replacements) |entries| for (0..3) |operation| {
        var live: Live = .{};
        var fixture: Fixture = .{};
        var choice: Self = .{ .props = .{ .userdata = &fixture, .on_pick = Fixture.pickModel } };
        choice.openSource(.{ .context = &live, .read = Live.read }, provider_route.nameOf(.codex), "old-b");
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} };
        _ = try choice.widget().draw(draw_ctx);
        try std.testing.expectEqual(@as(usize, 2), choice.hits.len);
        live.revision += 1;
        live.menu.entries = entries;
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        switch (operation) {
            0 => _ = try choice.widget().draw(draw_ctx),
            1 => try choice.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 2, .col = 4 } }),
            2 => try press(&choice, &ctx, vaxis.Key.enter),
            else => unreachable,
        }
        try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
        try std.testing.expect(!choice.active);
        try std.testing.expectEqual(@as(usize, 0), choice.hits.len);
    };
}

const RejectedInput = enum { typed_overflow, invalid_utf8, invalid_scalar, paste_overflow };

fn expectFilterRecovery(failure: RejectedInput) !void {
    const entries = [_]picker.Entry{
        .{ .id = "alpha-one", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
        .{ .id = "alpha-two", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    var fixture: Fixture = .{};
    var choice: Self = .{ .props = .{ .userdata = &fixture, .on_pick = Fixture.pickModel } };
    choice.open(&menu, provider_route.nameOf(.codex), "alpha-one");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'a', .text = "alpha " } });
    try press(&choice, &ctx, vaxis.Key.left);
    const spaces = @as([catalog.max_model_bytes + 1]u8, @splat(' '));
    switch (failure) {
        .typed_overflow => try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = ' ', .text = &spaces } }),
        .invalid_utf8 => try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 0xfffd, .text = "\xff" } }),
        .invalid_scalar => try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'z', .text = "zz\x01" } }),
        .paste_overflow => {
            try choice.widget().handleEvent(&ctx, .paste_start);
            try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = ' ', .text = &spaces } });
            try choice.widget().handleEvent(&ctx, .paste_end);
            try std.testing.expectEqualStrings("alpha ", choice.editor.text());
        },
    }
    const retained = try arena.allocator().dupe(u8, choice.editor.text());
    const cursor = choice.editor.cursor();
    if (failure != .paste_overflow) {
        try std.testing.expectEqual(@as(?keymap.Refusal, if (failure == .typed_overflow) .overflow else .invalid), choice.editor.rejected);
        try press(&choice, &ctx, vaxis.Key.enter);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
    try std.testing.expect(choice.active);
    try std.testing.expectEqualStrings(retained, choice.editor.text());
    try std.testing.expectEqual(cursor, choice.editor.cursor());
    try std.testing.expectEqual(@as(?keymap.Refusal, null), choice.editor.rejected);
    for ([_]u16{ 99, 46 }) |width| {
        const shown = try choice.field(0).value_widget.?.draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        var line: std.Io.Writer.Allocating = .init(arena.allocator());
        for (shown.buffer[0..width]) |cell| try line.writer.writeAll(cell.char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, line.written(), "text couldn't be entered") != null);
    }
    try press(&choice, &ctx, vaxis.Key.backspace);
    try std.testing.expectEqual(retained.len - 1, choice.editor.text().len);
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = ' ', .text = " " } });
    try std.testing.expectEqual(retained.len, choice.editor.text().len);
    try std.testing.expectEqual(@as(?[]const u8, null), choice.failure);
    try std.testing.expect(!choice.no_match);
    _ = try choice.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(usize, 2), choice.hits.len);
    try press(&choice, &ctx, vaxis.Key.down);
    try press(&choice, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings("alpha-two", fixture.picked.?);
    try std.testing.expect(!choice.active);
}

test "Model choice recovers from typed overflow with its usable filter and caret" {
    try expectFilterRecovery(.typed_overflow);
}

test "Model choice recovers from malformed input before editing and picking" {
    for ([_]RejectedInput{ .invalid_utf8, .invalid_scalar }) |failure| {
        errdefer std.debug.print("model filter rejection={s}\n", .{@tagName(failure)});
        try expectFilterRecovery(failure);
    }
}

test "Model choice preserves paste overflow rollback before editing and picking" {
    try expectFilterRecovery(.paste_overflow);
}

test "Model choice Panel field keeps its input visible and compacts indented matches with quiet overflow" {
    const entries = blk: {
        var all: [10]picker.Entry = undefined;
        inline for (0..10) |i| all[i] = .{ .id = std.fmt.comptimePrint("model-{d}", .{i}), .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) };
        break :blk all;
    };
    const widths = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 46, 99 };
    for (widths) |width| for ([_]u16{ 0, 1, 2, 3, 4, 5, 6, 20 }) |height| for ([_]usize{ 0, 1, 8, 10 }) |count| for ([_]bool{ false, true }) |last| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const menu: picker.Menu = .{ .entries = entries[0..count] };
        var fixture: Fixture = .{};
        var choice: Self = .{ .props = .{ .userdata = &fixture, .on_pick = Fixture.pickModel } };
        choice.open(&menu, provider_route.nameOf(.codex), if (count == 0) "" else entries[if (last) count - 1 else 0].id);
        const fields = [_]Panel.Field{ .{ .label = "One", .value = "1" }, .{ .label = "Two", .value = "2" }, .{ .label = "Three", .value = "3" }, .{ .label = "Four", .value = "4" }, .{ .label = "Model", .value = "saved model" }, .{ .label = "After", .value = "next" } };
        var panel: Panel = .{ .props = .{ .title = "Title", .fields = &fields, .custom_choice = if (choice.active) choice.field(4) else null }, .selected = 4 };
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
        const drawn = try panel.widget().draw(draw_ctx);
        for (drawn.children) |child| {
            try std.testing.expect(child.origin.row >= 0 and child.origin.col >= 0);
            try std.testing.expect(child.origin.row + child.surface.size.height <= height);
            try std.testing.expect(child.origin.col + child.surface.size.width <= width);
        }
        if (count > 0 and width > 21 and height >= 3) try std.testing.expect(drawn.cursor != null);
        if (count > 0 and width > 0 and height >= 4) try std.testing.expect(std.mem.indexOfScalar(usize, choice.hits, choice.focus.selected().?) != null);
        if (drawn.cursor) |cursor| {
            try std.testing.expect(cursor.row < height and cursor.col < width);
            try std.testing.expectEqual(@as(u16, 19), cursor.col);
        }
        if (count == 0 or width <= 21 or height != 20) continue;
        var screen = try vaxis.Screen.init(arena.allocator(), .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
        try drawn.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen }, panel.widget());
        try std.testing.expect(screen.cursor_vis);
        try std.testing.expectEqual(@as(u16, 6), screen.cursor.row);
        try std.testing.expectEqual(@as(u16, 19), screen.cursor.col);
        try std.testing.expectEqualStrings(" ", screen.readCell(19, 6).?.char.grapheme); // No saved value or filter label.
        try std.testing.expectEqualStrings("M", screen.readCell(3, 6).?.char.grapheme);
        try std.testing.expectEqual(@as(u16, @intCast(@min(count, 8))), panel.custom_height);
        try std.testing.expectEqualStrings("A", screen.readCell(3, 7 + panel.custom_height).?.char.grapheme);
        for (choice.hits, 0..) |index, y| {
            try std.testing.expectEqualStrings(" ", screen.readCell(0, @intCast(7 + y)).?.char.grapheme);
            try std.testing.expectEqualStrings(if (std.mem.eql(u8, entries[index].id, choice.current)) "✓" else " ", screen.readCell(3, @intCast(7 + y)).?.char.grapheme);
            try std.testing.expectEqualStrings("m", screen.readCell(5, @intCast(7 + y)).?.char.grapheme);
        }
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        if (count > 8) {
            try std.testing.expectEqual(@as(usize, if (last) 8 else 7), choice.hits.len);
            if (!last) {
                try std.testing.expectEqualStrings("↓", screen.readCell(3, 7 + panel.custom_height - 1).?.char.grapheme);
                try std.testing.expectEqualStrings("3", screen.readCell(5, 7 + panel.custom_height - 1).?.char.grapheme);
                try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = @intCast(7 + panel.custom_height - 1), .col = 10 } });
                try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
            }
            try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '9', .text = "9" } });
            _ = try panel.widget().draw(draw_ctx);
            try std.testing.expectEqual(@as(u16, 1), panel.custom_height);
            try std.testing.expectEqual(@as(usize, 1), choice.hits.len);
            try std.testing.expectEqual(@as(u16, 20), (try panel.widget().draw(draw_ctx)).cursor.?.col);
            try press(&choice, &ctx, vaxis.Key.backspace);
            _ = try panel.widget().draw(draw_ctx);
            try std.testing.expectEqual(@as(u16, 8), panel.custom_height);
            try std.testing.expectEqual(@as(usize, 8), choice.hits.len);
        }
        _ = try panel.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = width, .height = 0 }));
        try panel.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 0, .col = 10 } });
        try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
        choice.cancel();
        var closed_props = panel.props;
        closed_props.custom_choice = null;
        panel.present(closed_props);
        try std.testing.expect((try panel.widget().draw(draw_ctx)).cursor == null);
    };
}

test "Model choice input scrolls by grapheme and reserves refusal without a label" {
    var choice: Self = .{};
    choice.open(null, provider_route.nameOf(.codex), "");
    const query = "sol e\u{301} 🧑‍🌾";
    _ = choice.editor.append(query);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]?[]const u8{ null, " · text couldn't be entered" }) |failure| for ([_]usize{ 0, 4, 7, 8, query.len }) |caret| for (0..51) |width| {
        choice.failure = failure;
        choice.editor.setCursor(caret);
        const drawn = try choice.field(0).value_widget.?.draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = 1 }, .cell_size = .{} });
        errdefer std.debug.print("input width={d} caret={d} failure={any} cursor={any}\n", .{ width, caret, failure != null, drawn.cursor });
        const tail_width = @min(width, if (failure != null) 27 else @as(usize, 0));
        if (width > tail_width) {
            try std.testing.expect(drawn.cursor != null);
            try std.testing.expect(drawn.cursor.?.col < width - tail_width);
        } else try std.testing.expect(drawn.cursor == null);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (drawn.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text.written()));
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "Filter:") == null);
        if (width >= 27 and failure != null) try std.testing.expect(std.mem.indexOf(u8, text.written(), "text couldn't be entered") != null);
    };
}

test "Model choice size column follows only the longest shown name across widths and filters" {
    const entries = [_]picker.Entry{
        .{ .id = "a-very-long-hidden-chat-model-before", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
        .{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
        .{ .id = "gpt-6.1-terra", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
        .{ .id = "gpt-6-sol", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
        .{ .id = "another-even-longer-hidden-chat-model-after", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    for (30..141) |width| for ([_]u16{ 1, 2, 3 }) |height| for ([_]bool{ false, true }) |filtered| {
        errdefer std.debug.print("size column width={d} height={d} filtered={any}\n", .{ width, height, filtered });
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var choice: Self = .{};
        choice.open(&menu, provider_route.nameOf(.codex), "gpt-6.1-terra");
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        if (filtered) try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 's', .text = "sol" } });
        const drawn = try choice.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = height }, .cell_size = .{} });
        const column: u16 = if (filtered) 18 else 20;
        try std.testing.expectEqual(@as(usize, if (height == 1 or (!filtered and height == 2)) 1 else 2), choice.hits.len);
        for (choice.hits, 0..) |index, y| {
            try std.testing.expect(entries[index].known);
            for (5 + entries[index].id.len..column) |x| try std.testing.expectEqualStrings(" ", drawn.readCell(@intCast(x), @intCast(y)).char.grapheme);
            try std.testing.expectEqualStrings("1", drawn.readCell(column, @intCast(y)).char.grapheme);
            try std.testing.expectEqualStrings("M", drawn.readCell(column + 1, @intCast(y)).char.grapheme);
        }
    };
}

test "Model choice shared ASCII inline input and compact matches preserve PR4 geometry" {
    const entries = [_]picker.Entry{.{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) }};
    const menu: picker.Menu = .{ .entries = &entries };
    var choice: Self = .{ .props = .{ .unicode = false } };
    choice.open(&menu, provider_route.nameOf(.codex), entries[0].id);
    choice.no_match = true;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 46, 99 }) |width| {
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 8 }, .cell_size = .{} };
        const drawn = try choice.widget().draw(ctx);
        try std.testing.expectEqual(@as(u16, 1), drawn.size.height);
        for (drawn.buffer) |cell| for (cell.char.grapheme) |byte| try std.testing.expect(byte < 0x80);
        try std.testing.expectEqualStrings("+", drawn.readCell(3, 0).char.grapheme);
        try std.testing.expectEqualStrings("g", drawn.readCell(5, 0).char.grapheme);
        const input_surface = try choice.field(0).value_widget.?.draw(ctx.withConstraints(.{}, .{ .width = width, .height = 1 }));
        var out: std.Io.Writer.Allocating = .init(arena.allocator());
        for (input_surface.buffer) |cell| try out.writer.writeAll(cell.char.grapheme);
        for (out.written()) |byte| try std.testing.expect(byte < 0x80);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), ". no matches") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "Filter:") == null);
        try std.testing.expect(input_surface.cursor != null);
    }
    choice.open(null, provider_route.nameOf(.codex), "");
    const overflow = try choice.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 3 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("v", overflow.readCell(3, 2).char.grapheme);
    for (overflow.buffer) |cell| for (cell.char.grapheme) |byte| try std.testing.expect(byte < 0x80);
}

test "Model choice ASCII cursor projection stays bounded across Unicode prefixes and reserved tails" {
    const cases = [_]struct { query: []const u8, caret: usize, projected: usize }{
        .{ .query = "界after", .caret = 0, .projected = 0 },
        .{ .query = "界after", .caret = "界".len, .projected = 1 },
        .{ .query = "界after", .caret = "界a".len, .projected = 2 },
        .{ .query = "界after", .caret = "界after".len, .projected = 6 },
        .{ .query = "é beforeASCII", .caret = "é be".len, .projected = 4 },
        .{ .query = "e\u{301} more", .caret = "e\u{301} ".len, .projected = 3 },
        .{ .query = "🧑‍🌾 after", .caret = "🧑‍🌾 ".len, .projected = 4 },
    };
    const State = enum { plain, no_match, refusal, both };
    for (cases) |case| for (std.enums.values(State)) |state| {
        var choice: Self = .{ .props = .{ .unicode = false } };
        choice.open(null, provider_route.nameOf(.codex), "");
        _ = choice.editor.append(case.query);
        choice.editor.setCursor(case.caret);
        choice.no_match = state == .no_match or state == .both;
        choice.failure = if (state == .refusal or state == .both) " · text couldn't be entered" else null;
        const expected_tail = switch (state) {
            .plain => "",
            .no_match => " . no matches",
            .refusal, .both => " . text couldn't be entered",
        };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        for (0..40) |width| {
            errdefer std.debug.print("ASCII cursor query={s} caret={d} projected={d} state={s} width={d}\n", .{ case.query, case.caret, case.projected, @tagName(state), width });
            const drawn = try choice.field(0).value_widget.?.draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = 1 }, .cell_size = .{} });
            const edit_width = width -| expected_tail.len;
            if (edit_width == 0) {
                try std.testing.expect(drawn.cursor == null);
            } else {
                try std.testing.expect(drawn.cursor != null);
                try std.testing.expectEqual(@as(u16, @intCast(@min(case.projected, edit_width - 1))), drawn.cursor.?.col);
            }
            var out: std.Io.Writer.Allocating = .init(arena.allocator());
            for (drawn.buffer) |cell| {
                for (cell.char.grapheme) |byte| try std.testing.expect(byte < 0x80);
                try out.writer.writeAll(cell.char.grapheme);
            }
            if (width >= expected_tail.len) try std.testing.expect(std.mem.endsWith(u8, out.written(), expected_tail));
            try std.testing.expectEqualStrings(case.query, choice.editor.text());
            try std.testing.expectEqual(case.caret, choice.editor.cursor());
        }
    };
}

test "Model choice hover and click follow full-width Panel matches without selecting overflow" {
    const entries = blk: {
        var all: [10]picker.Entry = undefined;
        inline for (0..10) |i| all[i] = .{ .id = std.fmt.comptimePrint("model-{d}", .{i}), .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) };
        break :blk all;
    };
    const menu: picker.Menu = .{ .entries = &entries };
    for ([_]u16{ 46, 140 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var fixture: Fixture = .{};
        var choice: Self = .{ .props = .{ .userdata = &fixture, .on_pick = Fixture.pickModel, .ground = .{ .bg = .{ .index = 1 } }, .selection = .{ .bg = .{ .index = 2 } }, .hover_style = .{ .bg = .{ .index = 3 } } } };
        choice.open(&menu, provider_route.nameOf(.codex), "model-0");
        var panel: Panel = .{ .props = .{ .title = "Title", .fields = &.{.{ .label = "Model", .value = "model-0" }} } };
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 8 }, .cell_size = .{} };
        _ = try panel.widget().draw(draw_ctx);
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        try panel.widget().handleEvent(&events, .mouse_enter);
        try panel.widget().handleEvent(&events, .{ .mouse = .{ .col = 1, .row = 2, .button = .none, .type = .motion, .mods = .{} } });
        try std.testing.expect(panel.hover.pointing);
        var custom_props = panel.props;
        custom_props.custom_choice = choice.field(0);
        panel.present(custom_props);
        _ = try panel.widget().draw(draw_ctx);
        var mouse: vaxis.Mouse = .{ .col = @intCast(width - 1), .row = @intCast(panel.custom_origin + 1), .button = .none, .type = .motion, .mods = .{} };
        for (0..2) |_| {
            try panel.widget().handleEvent(&events, .{ .mouse = mouse });
            const surface = try panel.widget().draw(draw_ctx);
            const child = surface.children[surface.children.len - 1].surface;
            try std.testing.expectEqual(choice.props.hover_style, child.readCell(width - 1, 1).style);
            try std.testing.expectEqual(@as(?usize, 0), choice.focus.selected());
            try std.testing.expectEqual(@as(usize, 0), panel.selected);
            try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
            try std.testing.expect(choice.hover.pointing);
            try std.testing.expect(!panel.hover.pointing);
        }
        try panel.widget().handleEvent(&events, .mouse_leave);
        const left = try panel.widget().draw(draw_ctx);
        try std.testing.expectEqual(choice.props.ground, left.children[left.children.len - 1].surface.readCell(width - 1, 1).style);
        try std.testing.expect(!choice.hover.pointing);
        mouse.row = @intCast(panel.custom_origin + panel.custom_height - 1);
        try panel.widget().handleEvent(&events, .{ .mouse = mouse });
        try std.testing.expect(!choice.hover.pointing);
        mouse.button = .left;
        mouse.type = .press;
        try panel.widget().handleEvent(&events, .{ .mouse = mouse });
        try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
        mouse.row = @intCast(panel.custom_origin + 1);
        mouse.col = @intCast(width);
        try panel.widget().handleEvent(&events, .{ .mouse = mouse });
        try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
        mouse.col -= 1;
        try panel.widget().handleEvent(&events, .{ .mouse = mouse });
        try std.testing.expectEqualStrings("model-1", fixture.picked.?);
        for (events.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
    }
}

test "Model choice standalone rows use all bounded space without viewport hints" {
    const entries = [_]picker.Entry{
        .{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&provider_route.built_in_names) },
        .{ .id = "gpt-5.5", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&provider_route.built_in_names) },
        .{ .id = "gpt-5.4", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&provider_route.built_in_names) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    var choice: Self = .{};
    choice.open(&menu, provider_route.nameOf(.codex), "gpt-6.1-sol");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 2 }, .cell_size = .{} };
    _ = try choice.widget().draw(ctx);
    try std.testing.expectEqual(@as(usize, 1), choice.hits.len);
    choice.props.show_more = false;
    for ([_]u16{ 0, 1, 2, 46, 140 }) |width| for (0..5) |height| {
        const drawn = try choice.widget().draw(ctx.withConstraints(.{}, .{ .width = width, .height = @intCast(height) }));
        try std.testing.expect(drawn.size.height <= height);
        if (width > 0 and height > 0) try std.testing.expectEqual(@min(height, entries.len), choice.hits.len);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (drawn.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "more") == null);
    };
}

test "Model Tab includes its drawn filter and excludes clipped results" {
    const entries = [_]picker.Entry{
        .{ .id = "one", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
        .{ .id = "two", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    var choice: Self = .{};
    choice.open(&menu, provider_route.nameOf(.codex), "one");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 1 }, .cell_size = .{} };
    _ = try choice.widget().draw(draw_ctx);
    _ = try drawInput(&choice, draw_ctx);
    try std.testing.expectEqual(@as(usize, 1), choice.hits.len);
    const tab: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.tab } };
    try choice.widget().handleEvent(&ctx, tab);
    try std.testing.expect(choice.focus == .row);
    try std.testing.expectEqual(choice.hits[0], choice.focus.row);
    try choice.widget().handleEvent(&ctx, tab);
    try std.testing.expect(choice.focus == .filter);
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } } });
    try std.testing.expect(choice.focus == .row);
    try std.testing.expectEqual(choice.hits[0], choice.focus.row);
    resetDraw(&choice);
    try choice.widget().handleEvent(&ctx, tab);
    try std.testing.expectEqual(@as(usize, 0), choice.hits.len);
}

const Limits = struct {
    menu: *const picker.Menu,
    limited: connection_names.NameSet,
    fn read(raw: *anyopaque) Snapshot {
        const self: *Limits = @ptrCast(@alignCast(raw));
        return .{ .menu = self.menu, .limited = self.limited };
    }
};

test "SUI-186 a model on a limited connection says so and names another connection that serves it" {
    const work = connection.Name.parse("work").?;
    const home = connection.Name.parse("home").?;
    const entries = [_]picker.Entry{
        .{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{ work, home }) },
        .{ .id = "gpt-5.5", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{work}) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |is_limited| {
        var limits: Limits = .{ .menu = &menu, .limited = if (is_limited) connection_names.NameSet.of(&.{work}) else .{} };
        var choice: Self = .{};
        choice.openSource(.{ .context = &limits, .read = Limits.read }, work, "gpt-6.1-sol");
        const drawn = try choice.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 4 }, .cell_size = .{} });
        var rows: [2][]const u8 = undefined;
        for (&rows, 0..) |*row_text, y| {
            var text: std.Io.Writer.Allocating = .init(arena.allocator());
            for (0..drawn.size.width) |x| try text.writer.writeAll(drawn.readCell(@intCast(x), @intCast(y)).char.grapheme);
            row_text.* = text.written();
        }
        try std.testing.expectEqual(is_limited, std.mem.indexOf(u8, rows[0], "limit reached on work · try home") != null);
        try std.testing.expectEqual(is_limited, std.mem.indexOf(u8, rows[1], "limit reached on work") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows[1], "try") == null);
    }
}
