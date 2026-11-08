//! Native /model picker. The caller owns the composer, default and effects.
//! Keep this value at a stable address while its widget is mounted.
const std = @import("std");
const vaxis = @import("vaxis");
const fw = vaxis.vxfw;
const models = @import("model_picker.zig");
const capability = @import("model_capability.zig");
const view = @import("overview_view.zig");
const Self = @This();

const Phase = union(enum) { closed, models, sign_in: models.Provider };
pub const Read = union(enum) { menu: models.Menu, unanswered, invalid };
pub const Input = union(enum) {
    open,
    close,
    previous,
    next,
    first,
    last,
    left,
    right,
    enter,
    /// Ordinary typing or paste returns routing to the composer without consuming it.
    edit,
};
pub const Result = union(enum) { none, request_models: u64, selected: view.Default, widen };
pub const ReadStatus = enum { unread, read, unanswered, invalid };

allocator: std.mem.Allocator,
list: fw.ListView = .{ .children = .{ .slice = &.{} }, .item_count = 0, .draw_cursor = false },
menu: models.Menu = .{},
phase: Phase = .closed,
read_status: ReadStatus = .unread,
generation: u64 = 0,
lead: ?usize = null,
row_index: usize = 0,
row_selected: bool = false,

pub fn init(allocator: std.mem.Allocator) Self { return .{ .allocator = allocator }; }
pub fn deinit(self: *Self) void { self.menu.deinit(self.allocator); self.* = undefined; }
pub fn isOpen(self: *const Self) bool { return self.phase != .closed; }
pub fn choice(self: *const Self) ?models.Provider { return switch (self.phase) { .sign_in => |p| p, else => null }; }
pub fn selected(self: *const Self) ?models.Entry {
    if (!self.isOpen() or self.list.cursor >= self.menu.entries.len) return null;
    return self.shown().entry(self.list.cursor);
}
fn shown(self: *const Self) models.Shown { return .{ .menu = &self.menu, .lead = self.lead }; }
fn setLead(self: *Self, default_model: ?[]const u8) void {
    self.lead = if (default_model) |id| self.menu.find(id) else null;
}
fn restore(self: *Self, id: ?[]const u8) void {
    self.list.item_count = @intCast(self.menu.entries.len);
    const found = if (id) |value| self.menu.find(value) else null;
    const row = if (found) |index| self.shown().row(index) else 0;
    if (found == null or self.list.cursor != row) self.list.jumpToItem(@intCast(row));
}

/// Transfer ownership of a menu, including stale responses. `generation` is
/// the token returned by open; replies for a closed/reopened picker are freed.
/// The caller can refresh a live list using the same token while it remains open.
pub fn receive(self: *Self, generation: u64, read: Read, default_model: ?[]const u8) void {
    if (!self.isOpen() or generation != self.generation) {
        switch (read) { .menu => |m| { var owned = m; owned.deinit(self.allocator); }, else => {} }
        return;
    }
    switch (read) {
        .menu => |menu| {
            var buffer: [capability.max_model_bytes]u8 = undefined;
            const id: ?[]const u8 = if (self.selected()) |entry| blk: {
                @memcpy(buffer[0..entry.id.len], entry.id);
                break :blk buffer[0..entry.id.len];
            } else null;
            self.menu.deinit(self.allocator);
            self.menu = menu;
            self.read_status = .read;
            self.setLead(default_model);
            self.restore(id);
            const entry = self.selected();
            if (id == null or self.menu.find(id.?) == null) self.phase = .models else switch (self.phase) {
                .sign_in => |provider| if (entry == null or !entry.?.providers.contains(provider)) { self.phase = .models; },
                else => {},
            };
        },
        .unanswered => self.read_status = .unanswered,
        .invalid => self.read_status = .invalid,
    }
}

/// `default` is the caller's current default, used only for ordering and the
/// initial provider choice. `width` is the actual available picker width.
/// The caller forwards only picker-directed keys; an edit is not consumed.
pub fn input(self: *Self, value: Input, default: ?view.Default, width: u16) Result {
    if (value == .open) {
        if (self.isOpen()) return .none;
        self.generation +%= 1;
        self.phase = .models;
        self.read_status = .unread;
        self.setLead(if (default) |d| d.model.slice() else null);
        self.restore(null);
        return .{ .request_models = self.generation };
    }
    if (!self.isOpen()) return .none;
    switch (value) {
        .open => unreachable,
        .close => switch (self.phase) { .sign_in => self.phase = .models, else => self.reset() },
        .edit => self.reset(),
        .previous, .next, .first, .last => if (self.phase == .models) {
            var ctx: fw.EventContext = .{ .io = undefined, .alloc = self.allocator, .cmds = .empty };
            switch (value) {
                .previous => self.list.prevItem(&ctx),
                .next => self.list.nextItem(&ctx),
                .first => self.list.jumpToItem(0),
                .last => if (self.menu.entries.len != 0) self.list.jumpToItem(@intCast(self.menu.entries.len - 1)),
                else => unreachable,
            }
        },
        .left, .right => if (self.choice()) |current| {
            const entry = self.selected() orelse return .none;
            const providers = std.enums.values(models.Provider);
            const start = for (providers, 0..) |provider, i| { if (provider == current) break i; } else unreachable;
            for (1..providers.len + 1) |offset| {
                const i = if (value == .right) (start + offset) % providers.len else (start + providers.len - offset % providers.len) % providers.len;
                if (entry.providers.contains(providers[i])) { self.phase = .{ .sign_in = providers[i] }; break; }
            }
        },
        .enter => {
            const entry = self.selected() orelse return .none;
            // Match the existing picker's protection against selecting clipped identities.
            if (entry.id.len > width -| 5) return .widen;
            if (entry.providers.count() > 1) {
                var column: usize = 8;
                for (std.enums.values(models.Provider)) |provider| if (entry.providers.contains(provider)) {
                    const end = column + 3 + provider.signIn().len;
                    if (end + 1 > width) return .widen;
                    column = end + 2;
                };
            }
            var iterator = entry.providers.iterator();
            const first = iterator.next() orelse return .none;
            if (self.phase == .models and iterator.next() != null) {
                const preferred = if (default) |d| d.provider else first;
                self.phase = .{ .sign_in = if (entry.providers.contains(preferred)) preferred else first };
                return .none;
            }
            const provider = self.choice() orelse first;
            var selected: view.Default = .{ .provider = provider, .model = .{} };
            selected.model.set(entry.id) catch unreachable;
            self.reset();
            return .{ .selected = selected };
        },
    }
    return .none;
}
fn reset(self: *Self) void {
    self.menu.deinit(self.allocator);
    self.phase = .closed;
    self.lead = null;
    self.list = .{ .children = .{ .slice = &.{} }, .item_count = 0, .draw_cursor = false };
}

/// Model list widget. The caller keeps composer focus and routes keys via input.
/// In sign-in mode the caller displays `selected()` and `choice()` in its
/// composer row; both borrow this owner until the next mutation.
pub fn widget(self: *Self) fw.Widget { return .{ .userdata = self, .drawFn = draw }; }
fn draw(raw: *anyopaque, ctx: fw.DrawContext) std.mem.Allocator.Error!fw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.list.children = .{ .builder = .{ .userdata = self, .buildFn = buildRow } };
    defer self.list.children = .{ .slice = &.{} };
    return self.list.draw(ctx);
}
fn buildRow(raw: *const anyopaque, index: usize, cursor: usize) ?fw.Widget {
    const self: *Self = @ptrCast(@alignCast(@constCast(raw)));
    if (index >= self.menu.entries.len) return null;
    self.row_index = index;
    self.row_selected = index == cursor;
    return .{ .userdata = self, .drawFn = drawRow };
}
fn drawRow(raw: *anyopaque, ctx: fw.DrawContext) std.mem.Allocator.Error!fw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const entry = self.shown().entry(self.row_index);
    const label = try std.fmt.allocPrint(ctx.arena, "{s} {s}{s}", .{ if (self.row_selected) ">" else " ", entry.id, if (entry.known) "" else "  default limits" });
    const text: fw.Text = .{ .text = label, .softwrap = false, .width_basis = .parent, .style = .{ .reverse = self.row_selected } };
    var surface = try text.draw(ctx);
    surface.widget = .{ .userdata = self, .drawFn = drawRow };
    return surface;
}

fn testMenu(codex: []const u8, openai: []const u8) !models.Menu {
    return models.testMenu(&.{
        .{ .provider = .codex, .list = .{ .live = .{ .bytes = codex } } },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = openai } } },
    });
}

test "refresh preserves model identity and rejects stale replies" {
    var picker = Self.init(std.testing.allocator);
    defer picker.deinit();
    const token = picker.input(.open, null, 80).request_models;
    picker.receive(token, .{ .menu = try testMenu("alpha\nbeta\n", "") }, null);
    _ = picker.input(.next, null, 80);
    try std.testing.expectEqualStrings("beta", picker.selected().?.id);
    picker.receive(token, .{ .menu = try testMenu("aardvark\nalpha\nbeta\n", "") }, null);
    try std.testing.expectEqualStrings("beta", picker.selected().?.id);
    _ = picker.input(.edit, null, 80);
    const newer = picker.input(.open, null, 80).request_models;
    picker.receive(token, .{ .menu = try testMenu("stale\n", "") }, null);
    try std.testing.expect(picker.selected() == null);
    picker.receive(newer, .{ .menu = try testMenu("fresh\n", "") }, null);
    try std.testing.expectEqualStrings("fresh", picker.selected().?.id);
}

test "shared model choice uses caller default and returns a bounded binding" {
    var picker = Self.init(std.testing.allocator);
    defer picker.deinit();
    const default = view.Default.of("openai", "shared").?;
    const token = picker.input(.open, default, 80).request_models;
    picker.receive(token, .{ .menu = try testMenu("shared\n", "shared\n") }, default.model.slice());
    try std.testing.expect(picker.input(.enter, default, 12) == .widen);
    try std.testing.expect(picker.input(.enter, default, 80) == .none);
    try std.testing.expectEqual(models.Provider.openai, picker.choice().?);
    _ = picker.input(.left, default, 80);
    const provider = picker.choice().?;
    try std.testing.expect(provider != .openai);
    const result = picker.input(.enter, default, 80);
    try std.testing.expectEqual(provider, result.selected.provider);
    try std.testing.expectEqualStrings("shared", result.selected.model.slice());
    try std.testing.expect(!picker.isOpen());
}

test "refresh invalidates removed provider choice and escape steps back" {
    var picker = Self.init(std.testing.allocator);
    defer picker.deinit();
    const token = picker.input(.open, null, 80).request_models;
    picker.receive(token, .{ .menu = try testMenu("shared\n", "shared\n") }, null);
    _ = picker.input(.enter, null, 80);
    try std.testing.expect(picker.choice() != null);
    _ = picker.input(.close, null, 80);
    try std.testing.expect(picker.isOpen());
    try std.testing.expect(picker.choice() == null);
    _ = picker.input(.enter, null, 80);
    const chosen = picker.choice().?;
    const codex: []const u8 = if (chosen == .codex) "" else "shared\n";
    const openai: []const u8 = if (chosen == .openai) "" else "shared\n";
    picker.receive(token, .{ .menu = try testMenu(codex, openai) }, null);
    try std.testing.expect(picker.choice() == null);
    try std.testing.expectEqualStrings("shared", picker.selected().?.id);
    _ = picker.input(.close, null, 80);
    try std.testing.expect(!picker.isOpen());
}

test "single-provider pick returns the real default value and close ignores late replies" {
    var picker = Self.init(std.testing.allocator);
    defer picker.deinit();
    const token = picker.input(.open, null, 80).request_models;
    picker.receive(token, .{ .menu = try testMenu("single\n", "") }, null);
    const result = picker.input(.enter, null, 80);
    try std.testing.expectEqual(models.Provider.codex, result.selected.provider);
    try std.testing.expectEqualStrings("single", result.selected.model.slice());
    picker.receive(token, .{ .menu = try testMenu("late\n", "") }, null);
    try std.testing.expect(!picker.isOpen());
    try std.testing.expect(picker.selected() == null);
}
