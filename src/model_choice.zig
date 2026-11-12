//! One model field choice for chat info and application settings. The menu
//! and row rendering belong to the picker. Live lists are version-validated
//! for each event and frame; immutable lists may be borrowed until cancel.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const picker = @import("model_picker.zig");
const picker_view = @import("model_picker_view.zig");
const catalog = @import("model_catalog.zig");
const Editor = @import("TerminalEditor.zig");
const keymap = @import("keymap.zig");
const Self = @This();

/// The owner changes revision whenever it replaces or releases a list. A
/// snapshot is borrowed for this synchronous operation only, never a lease.
pub const Snapshot = struct { menu: ?*const picker.Menu = null, revision: u64 = 0 };
pub const Source = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) Snapshot,
};

const fallback_entries = blk: {
    @setEvalBranchQuota(20000);
    var entries: [catalog.openai_ids.len]picker.Entry = undefined;
    for (catalog.openai_ids, 0..) |id, at| entries[at] = .{ .id = id, .known = true, .catalogued = true, .providers = .full };
    break :blk entries;
};
const fallback: picker.Menu = .{ .entries = &fallback_entries };

active: bool = false,
source: ?Source = null,
revision: u64 = 0,
menu: *const picker.Menu = &fallback,
provider: picker.Provider = .codex,
current: []const u8 = "",
selected: ?usize = null,
scroll: usize = 0,
query_bytes: [catalog.max_model_bytes]u8 = undefined,
editor: Editor = .{ .buffer = &.{} },
pasting: bool = false,
no_match: bool = false,
userdata: ?*anyopaque = null,
on_pick: ?*const fn (*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,
ground: vaxis.Style = .{},
selection: vaxis.Style = .{ .reverse = true },
quiet: vaxis.Style = .{ .dim = true },
/// The most recent frame's model indices, borrowed from its draw arena.
hits: []const usize = &.{},

/// The immutable menu must outlive this choice. Mutable owners use openSource.
pub fn open(self: *Self, menu: ?*const picker.Menu, provider: picker.Provider, current: []const u8) void {
    self.source = null;
    self.menu = menu orelse &fallback;
    self.provider = provider;
    self.current = current;
    self.editor = .{ .buffer = &self.query_bytes };
    self.no_match = false;
    self.pasting = false;
    self.scroll = 0;
    self.selected = null;
    for (self.menu.entries, 0..) |entry, at| if (self.row(entry) != null) {
        if (self.selected == null or std.mem.eql(u8, entry.id, current)) self.selected = at;
    };
    self.active = self.selected != null;
}

pub fn openSource(self: *Self, source: Source, provider: picker.Provider, current: []const u8) void {
    const snapshot = source.read(source.context);
    self.open(snapshot.menu, provider, current);
    self.source = source;
    self.revision = snapshot.revision;
}

/// Validate before dereferencing the stored menu or an old frame's hit list.
/// The source owns invalidation; no menu or selection identity is copied.
pub fn validate(self: *Self) bool {
    if (!self.active) return false;
    if (self.source) |source| {
        const snapshot = source.read(source.context);
        if (snapshot.revision != self.revision or (snapshot.menu orelse &fallback) != self.menu) self.cancel();
    }
    return self.active;
}

/// Named application actions remain the caller's; arrows and text filter.
pub fn takesKey(key: vaxis.Key) bool {
    return Editor.named(key) == null or key.matches(vaxis.Key.up, .{}) or key.matches(vaxis.Key.down, .{});
}

pub fn cancel(self: *Self) void {
    // Cancel intentionally drops an unfinished search paste, not a save.
    _ = self.editor.blur();
    self.active = false;
    self.hits = &.{};
}

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

fn row(self: *const Self, entry: picker.Entry) ?picker.Row {
    if (!entry.providers.contains(self.provider)) return null;
    var constrained = entry;
    constrained.providers = .initOne(self.provider);
    return picker.Query.parse(self.editor.buffer[0..self.editor.length]).row(constrained, .{ .model = self.current, .provider = self.provider });
}

fn move(self: *Self, down: bool) void {
    var at = self.selected orelse return;
    while (if (down) at + 1 < self.menu.entries.len else at > 0) {
        at = if (down) at + 1 else at - 1;
        if (self.row(self.menu.entries[at]) != null) {
            self.selected = at;
            return;
        }
    }
}

fn pick(self: *Self, ctx: *vxfw.EventContext) !void {
    const at = self.selected orelse return;
    const id = self.menu.entries[at].id;
    self.cancel();
    if (self.on_pick) |callback| try callback(self.userdata.?, ctx, id);
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (!self.validate()) {
        ctx.consumeAndRedraw();
        return;
    }
    if (input == .key_press and !self.pasting and !takesKey(input.key_press)) return;
    if (input == .mouse) {
        const mouse = input.mouse;
        switch (mouse.button) {
            .wheel_up => self.move(false),
            .wheel_down => self.move(true),
            .left => {
                if (mouse.type != .press or mouse.row < 1) return;
                const at: usize = @intCast(mouse.row - 1);
                if (at >= self.hits.len) return;
                self.selected = self.hits[at];
                try self.pick(ctx);
            },
            else => return,
        }
        ctx.consumeAndRedraw();
        return;
    }
    if (input == .key_press and !self.pasting) {
        const key = input.key_press;
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
    @memcpy(backup[0..self.editor.length], self.editor.buffer[0..self.editor.length]);
    const length = self.editor.length;
    const cursor = self.editor.cursor;
    if (input == .paste_start) self.pasting = true;
    defer if (input == .paste_end) {
        self.pasting = false;
    };
    const outcome = self.editor.appEvent(keymap.every, input, self.pasting);
    if (outcome == .submit) {
        try self.pick(ctx);
    } else if (outcome == .refused) {
        // Like the other editor owners, start a clean editor when a refused
        // line ends. Keep this field's usable filter and caret, not the
        // rejection or partial-input state. Paste rollback stays the editor's.
        if (outcome.refused.endsLine()) self.editor = .{ .buffer = &self.query_bytes, .length = length, .cursor = cursor };
    } else if (outcome == .append or outcome == .redraw) {
        var first: ?usize = null;
        var kept = false;
        for (self.menu.entries, 0..) |entry, at| if (self.row(entry) != null) {
            if (first == null) first = at;
            if (self.selected == at) kept = true;
        };
        self.no_match = first == null;
        if (first == null) {
            @memcpy(self.editor.buffer[0..length], backup[0..length]);
            self.editor.length = length;
            self.editor.cursor = cursor;
        } else if (!kept) self.selected = first;
    }
    ctx.consumeAndRedraw();
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.ground });
    self.hits = &.{};
    if (!self.validate()) return surface;
    if (size.width == 0 or size.height == 0) return surface;
    const search = try std.fmt.allocPrint(ctx.arena, "  Filter: {s}{s}", .{ self.editor.buffer[0..self.editor.length], if (self.no_match) " · no matches" else "" });
    paint(ctx, surface, search, 0, self.quiet);
    var indices: std.array_list.Managed(usize) = .init(ctx.arena);
    var widest: usize = 0;
    var selected_row: usize = 0;
    for (self.menu.entries, 0..) |entry, at| if (self.row(entry) != null) {
        if (self.selected == at) selected_row = indices.items.len;
        try indices.append(at);
        widest = @max(widest, entry.id.len);
    };
    const height = size.height - 1;
    if (height == 0) return surface;
    if (selected_row < self.scroll) self.scroll = selected_row;
    if (selected_row >= self.scroll + height) self.scroll = selected_row - height + 1;
    self.scroll = @min(self.scroll, indices.items.len -| height);
    const shown = indices.items[self.scroll..@min(self.scroll + height, indices.items.len)];
    self.hits = shown;
    for (shown, 1..) |at, y| {
        const entry = self.menu.entries[at];
        const line = try picker_view.modelLine(ctx.arena, entry, self.row(entry).?, widest, size.width);
        const style = if (self.selected == at) self.selection else self.ground;
        for (0..size.width) |x| surface.writeCell(@intCast(x), @intCast(y), .{ .style = style });
        paint(ctx, surface, line.text, @intCast(y), style);
    }
    return surface;
}

fn paint(ctx: vxfw.DrawContext, surface: vxfw.Surface, text: []const u8, y: u16, style: vaxis.Style) void {
    var x: u16 = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |part| {
        const bytes = part.bytes(text);
        const width = ctx.stringWidth(bytes);
        if (width > surface.size.width - x) break;
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

test "Model choice shares picker rows filters never empty and picks only its provider" {
    const entries = [_]picker.Entry{
        .{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = .initOne(.codex) },
        .{ .id = "gpt-5.5", .known = true, .catalogued = true, .providers = .full },
        .{ .id = "api-only", .known = false, .catalogued = false, .providers = .initOne(.openai) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    var fixture: Fixture = .{};
    var choice: Self = .{ .userdata = &fixture, .on_pick = Fixture.pickModel };
    choice.open(&menu, .codex, "gpt-6.1-sol");
    try std.testing.expect(choice.active);
    try std.testing.expectEqual(@as(?usize, 0), choice.selected);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 99, 46 }) |width| {
        const drawn = try choice.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 8 }, .cell_size = .{} });
        try std.testing.expectEqual(@as(usize, 2), choice.hits.len);
        try std.testing.expectEqualStrings("g", drawn.readCell(3, 1).char.grapheme);
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (drawn.buffer) |cell| try text.writer.writeAll(cell.char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "1M") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "API key") == null);
    }
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = '5', .text = "5.5" } });
    try std.testing.expectEqual(@as(?usize, 1), choice.selected);
    try std.testing.expectEqualStrings("5.5", choice.editor.buffer[0..choice.editor.length]);
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'z', .text = "zzz" } });
    try std.testing.expect(choice.no_match);
    try std.testing.expectEqualStrings("5.5", choice.editor.buffer[0..choice.editor.length]);
    try std.testing.expectEqual(@as(?usize, 1), choice.selected);
    try press(&choice, &ctx, vaxis.Key.down);
    try std.testing.expectEqual(@as(?usize, 1), choice.selected);
    try press(&choice, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings("gpt-5.5", fixture.picked.?);
    try std.testing.expect(!choice.active);
    choice.open(&menu, .openai, "api-only");
    try std.testing.expectEqual(@as(?usize, 2), choice.selected);
    choice.cancel();
    try std.testing.expect(!choice.active);
    try std.testing.expectEqualStrings("gpt-5.5", fixture.picked.?);
    const empty: picker.Menu = .{};
    choice.open(&empty, .codex, "");
    try std.testing.expect(!choice.active);
}

test "Model choice bounds scrolling and mouse picking use the visible list" {
    var fixture: Fixture = .{};
    var choice: Self = .{ .userdata = &fixture, .on_pick = Fixture.pickModel };
    choice.open(null, .codex, "");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for (0..8) |_| try press(&choice, &ctx, vaxis.Key.down);
    const wanted = choice.menu.entries[choice.selected.?].id;
    const drawn = try choice.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 99, .height = 3 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 99), drawn.size.width);
    try std.testing.expect(choice.scroll > 0);
    try choice.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .mods = .{}, .row = 2, .col = 20 } });
    try std.testing.expectEqualStrings(wanted, fixture.picked.?);
    for (0..9) |width| for (0..5) |height| {
        _ = try choice.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
    };
}

test "Model choice invalidates every replaced or released source before keys mouse or drawing" {
    const Live = struct {
        const old = [_]picker.Entry{
            .{ .id = "old-a", .known = false, .catalogued = false, .providers = .full },
            .{ .id = "old-b", .known = false, .catalogued = false, .providers = .full },
        };
        const replacements = [_][]const picker.Entry{
            &.{old[0]}, // shorter
            &.{ old[1], old[0] }, // reordered
            &.{}, // released/empty
            &.{ .{ .id = "new-a", .known = false, .catalogued = false, .providers = .full }, old[0] }, // same length
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
        var choice: Self = .{ .userdata = &fixture, .on_pick = Fixture.pickModel };
        choice.openSource(.{ .context = &live, .read = Live.read }, .codex, "old-b");
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} };
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

const RejectedInput = enum { typed_overflow, invalid_utf8, invalid_key, invalid_scalar, paste_overflow };

fn expectFilterRecovery(failure: RejectedInput) !void {
    const entries = [_]picker.Entry{
        .{ .id = "alpha-one", .known = false, .catalogued = false, .providers = .initOne(.codex) },
        .{ .id = "alpha-two", .known = false, .catalogued = false, .providers = .initOne(.codex) },
    };
    const menu: picker.Menu = .{ .entries = &entries };
    var fixture: Fixture = .{};
    var choice: Self = .{ .userdata = &fixture, .on_pick = Fixture.pickModel };
    choice.open(&menu, .codex, "alpha-one");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'a', .text = "alpha " } });
    try press(&choice, &ctx, vaxis.Key.left); // Recovery must preserve a non-final caret too.
    const spaces = @as([catalog.max_model_bytes + 1]u8, @splat(' '));
    switch (failure) {
        .typed_overflow => try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = ' ', .text = &spaces } }),
        .invalid_utf8 => try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 0xfffd, .text = "\xff" } }),
        .invalid_key => try choice.widget().handleEvent(&ctx, .invalid_key),
        .invalid_scalar => try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'z', .text = "zz\x01" } }),
        .paste_overflow => {
            try choice.widget().handleEvent(&ctx, .paste_start);
            try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = ' ', .text = &spaces } });
            try choice.widget().handleEvent(&ctx, .paste_end);
            try std.testing.expectEqualStrings("alpha ", choice.editor.buffer[0..choice.editor.length]);
        },
    }
    const retained = try arena.allocator().dupe(u8, choice.editor.buffer[0..choice.editor.length]);
    const cursor = choice.editor.cursor;
    if (failure != .paste_overflow) {
        try std.testing.expectEqual(@as(?keymap.Refusal, if (failure == .typed_overflow) .overflow else .invalid), choice.editor.rejected);
        try press(&choice, &ctx, vaxis.Key.enter); // Report the rejected line, never pick it.
    }
    try std.testing.expectEqual(@as(?[]const u8, null), fixture.picked);
    try std.testing.expect(choice.active);
    try std.testing.expectEqualStrings(retained, choice.editor.buffer[0..choice.editor.length]);
    try std.testing.expectEqual(cursor, choice.editor.cursor);
    try std.testing.expectEqual(@as(?keymap.Refusal, null), choice.editor.rejected);
    try press(&choice, &ctx, vaxis.Key.backspace);
    try std.testing.expectEqual(retained.len - 1, choice.editor.length);
    try choice.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = ' ', .text = " " } });
    try std.testing.expectEqual(retained.len, choice.editor.length);
    try std.testing.expect(!choice.no_match);
    _ = try choice.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 8 }, .cell_size = .{} });
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
    for ([_]RejectedInput{ .invalid_utf8, .invalid_key, .invalid_scalar }) |failure| {
        errdefer std.debug.print("model filter rejection={s}\n", .{@tagName(failure)});
        try expectFilterRecovery(failure);
    }
}

test "Model choice preserves paste overflow rollback before editing and picking" {
    try expectFilterRecovery(.paste_overflow);
}
