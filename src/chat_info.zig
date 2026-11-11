//! Standalone chat facts and edits. The host supplies inspection and typed
//! effects; this widget neither owns a Session nor imports its frontend.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Panel = @import("widgets/Panel.zig");
const Footer = @import("widgets/Footer.zig");
const status = @import("status_page.zig");
const catalog = @import("model_catalog.zig");
const capability = @import("model_capability.zig");
const client_defaults = @import("client_defaults.zig");
const tools = @import("built_in_tool.zig");
const picker = @import("model_picker.zig");
const ModelChoice = @import("model_choice.zig");
const Editor = @import("TerminalEditor.zig");
const keymap = @import("keymap.zig");
const TerminalText = @import("TerminalText.zig");
const shortPath = @import("home_path.zig").shortPath;
const view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");
const Self = @This();

pub const SaveState = enum { idle, pending, saved, failed };
/// Configure's semantic values, not command-line fragments. String payloads
/// are borrowed until configure returns; the backend copies them for its job.
pub const Edit = union(enum) {
    effort: ?catalog.ReasoningEffort,
    permission: @FieldType(status.Session, "permission"),
    tools: tools.Selection,
    model: []const u8,
    label: []const u8,
};

/// Borrowed for the widget's lifetime. read fills the same inspection facts as
/// /status. configure submits the existing Session configure request; archive
/// and copy_last_answer delegate to the existing archive and /copy owners.
/// All three effects remain pending until state supplies a definite answer.
pub const Backend = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, *status.Session) anyerror!void,
    configure: *const fn (*anyopaque, Edit) anyerror!void,
    archive: *const fn (*anyopaque) anyerror!void,
    copy_last_answer: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    state: *const fn (*anyopaque) SaveState,
    models: *const fn (*anyopaque) ?*const picker.Menu,
    caps: *const fn (*anyopaque) view.Caps,
};

backend: Backend,
/// The process's HOME, borrowed; only the workspace is shortened with it.
home: []const u8 = "",
narrow: bool = false,
session: status.Session = undefined,
ready: bool = false,
read_failed: bool = false,
panel: Panel = .{ .title = "Chat", .action_gap = 1 },
fields: [6]Panel.Field = undefined,
failures: [9]?[]const u8 = @splat(null),
pending: ?usize = null,
effort_labels: [std.enums.values(catalog.ReasoningEffort).len + 1][]const u8 = undefined,
effort_count: usize = 0,
tool_draft: ?tools.Selection = null,
tool_labels: [std.enums.values(tools.BuiltInTool).len][]const u8 = undefined,
model_choice: ModelChoice = .{},
renaming: bool = false,
rename_bytes: [status.max_label_bytes]u8 = undefined,
rename_editor: Editor = .{ .buffer = &.{} },
pasting: bool = false,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn hasChoice(self: *const Self) bool {
    return self.renaming or self.panel.choice != null or self.model_choice.active;
}

/// Cancel only the topmost edit. The enclosing Layer closes this panel only
/// when hasChoice is false, preserving the chat input and its draft beneath.
pub fn cancelChoice(self: *Self) void {
    if (self.renaming) {
        // Cancel deliberately discards an unfinished paste or refused edit.
        _ = self.rename_editor.blur();
        self.renaming = false;
    } else if (self.model_choice.active) {
        self.model_choice.cancel();
    } else {
        self.panel.closeChoice();
        self.tool_draft = null;
    }
    self.panel.custom_choice = null;
}

pub fn refresh(self: *Self) void {
    self.cancelChoice();
    self.backend.read(self.backend.context, &self.session) catch {
        self.read_failed = true;
        self.ready = false;
        self.failures[0] = " · couldn't read chat";
        return;
    };
    if (self.read_failed) self.failures[0] = null;
    self.read_failed = false;
    self.ready = true;
}

fn title(self: *const Self) []const u8 {
    return if (self.ready and self.session.label.len > 0) self.session.label.slice() else "Chat";
}

fn bind(self: *Self) void {
    self.panel.userdata = self;
    self.panel.on_activate = activate;
    self.panel.on_pick = pick;
    self.panel.title = self.title();
    self.fields = .{
        .{ .label = "Effort", .value = if (!self.ready) "unavailable" else if (self.session.effort_override) if (self.session.effort) |effort| @tagName(effort) else "model default" else "model default", .tail = self.failures[0] },
        .{ .label = "Permissions", .value = if (!self.ready) "unavailable" else if (self.session.permission == .bypass) "run without asking" else "ask first", .tail = self.failures[1] },
        .{ .label = "Tools", .value = "", .tail = self.failures[2] },
        .{ .label = "Folder", .value = if (self.ready) self.session.workspace.slice() else "unavailable", .selectable = false },
        .{ .label = "Model", .value = if (self.ready) self.session.model.slice() else "unavailable", .tail = self.failures[4] },
        .{ .label = "Context", .value = "", .selectable = false },
    };
    if (self.pending) |row| if (row < self.fields.len) {
        self.fields[row].tail = " · saving";
    };
    self.panel.fields = &self.fields;
    self.panel.actions = &.{ "Rename", "Archive", "Copy last answer" };
    const caps = self.backend.caps(self.backend.context);
    self.panel.ground = widget_style.of(caps, .{ .background = .bar });
    self.panel.selection = widget_style.of(caps, .{ .background = .selection });
    self.panel.title_style = widget_style.of(caps, .{ .background = .bar, .colour = .strong, .bold = true });
    self.panel.quiet = widget_style.of(caps, .{ .background = .bar, .colour = .quiet });
    self.panel.rule_style = widget_style.of(caps, .{ .background = .bar, .colour = .rule });
    self.model_choice.ground = self.panel.ground;
    self.model_choice.selection = self.panel.selection;
    self.model_choice.quiet = self.panel.quiet;
    self.panel.title_widget = if (self.renaming) .{ .userdata = self, .drawFn = drawRename } else null;
    self.panel.custom_choice = if (self.model_choice.active) .{ .field = 4, .widget = self.model_choice.widget() } else null;
}

fn activate(raw: *anyopaque, ctx: *vxfw.EventContext, row: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.pending != null) return;
    self.refresh();
    if (self.read_failed) {
        self.failures[row] = " · couldn't read chat";
        ctx.redraw = true;
        return;
    }
    self.failures[row] = null;
    switch (row) {
        0 => {
            self.effort_labels[0] = "model default";
            self.effort_count = 1;
            var current: ?usize = if (!self.session.effort_override or self.session.effort == null) 0 else null;
            for (std.enums.values(catalog.ReasoningEffort)) |effort| {
                if (!capability.supportsReasoningEffort(catalog.shipped, self.session.model.slice(), effort)) continue;
                if (self.session.effort_override and self.session.effort == effort) current = self.effort_count;
                self.effort_labels[self.effort_count] = @tagName(effort);
                self.effort_count += 1;
            }
            self.panel.openChoice(self.effort_labels[0..self.effort_count], current);
        },
        1 => self.panel.openChoice(&.{ "run without asking", "ask first" }, if (self.session.permission == .bypass) 0 else 1),
        2 => {
            self.tool_draft = self.session.tools;
            self.updateTools();
            self.panel.openChoice(&self.tool_labels, null);
        },
        4 => self.openModel(),
        6 => {
            self.rename_editor = .{ .buffer = &self.rename_bytes };
            _ = self.rename_editor.append(self.session.label.slice());
            self.renaming = true;
        },
        7, 8 => {
            const result = if (row == 7) self.backend.archive(self.backend.context) else self.backend.copy_last_answer(self.backend.context, ctx);
            result catch {
                self.failures[row] = if (row == 7) " · couldn't archive" else " · couldn't copy";
                ctx.redraw = true;
                return;
            };
            self.pending = row;
            self.poll();
        },
        else => {},
    }
    ctx.redraw = true;
}

fn openModel(self: *Self) void {
    // The model choice owns its catalog fallback when the backend has no list.
    self.model_choice.open(self.backend.models(self.backend.context), self.session.provider, self.session.model.slice());
    self.model_choice.userdata = self;
    self.model_choice.on_pick = pickModel;
    if (!self.model_choice.active) self.failures[4] = " · models unavailable";
}

fn pickModel(raw: *anyopaque, ctx: *vxfw.EventContext, model: []const u8) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.save(ctx, 4, .{ .model = model });
}

fn updateTools(self: *Self) void {
    inline for (std.enums.values(tools.BuiltInTool), 0..) |tool, at| {
        const name = if (tool == .web_search) "web search" else @tagName(tool);
        self.tool_labels[at] = if (self.tool_draft.?.contains(tool)) "✓ " ++ name else "  " ++ name;
    }
}

fn pick(raw: *anyopaque, ctx: *vxfw.EventContext, row: usize, choice: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (row) {
        0 => try self.save(ctx, row, .{ .effort = if (choice == 0) null else std.meta.stringToEnum(catalog.ReasoningEffort, self.effort_labels[choice]).? }),
        1 => try self.save(ctx, row, .{ .permission = if (choice == 0) .bypass else .ask }),
        2 => {
            self.tool_draft.?.toggle(std.enums.values(tools.BuiltInTool)[choice]);
            self.updateTools();
            self.panel.openChoice(&self.tool_labels, null);
            self.panel.choice.?.selected = choice;
        },
        else => unreachable,
    }
}

fn save(self: *Self, ctx: *vxfw.EventContext, row: usize, edit: Edit) !void {
    self.failures[row] = null;
    self.backend.configure(self.backend.context, edit) catch {
        self.failures[row] = " · couldn't save";
        ctx.redraw = true;
        return;
    };
    self.pending = row;
    self.poll();
    ctx.redraw = true;
}

fn poll(self: *Self) void {
    const row = self.pending orelse return;
    const state = self.backend.state(self.backend.context);
    if (state == .idle or state == .pending) return;
    self.refresh();
    self.failures[row] = if (state == .failed) switch (row) {
        7 => " · couldn't archive",
        8 => " · couldn't copy",
        else => " · couldn't save",
    } else if (self.read_failed) " · couldn't read chat" else null;
    self.pending = null;
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (input == .tick) {
        const was_pending = self.pending != null;
        self.poll();
        if (was_pending) ctx.redraw = true;
        return;
    }
    if (input == .paste_start) self.pasting = true;
    defer if (input == .paste_end) {
        self.pasting = false;
    };
    if (input == .key_press and input.key_press.matches(vaxis.Key.escape, .{}) and self.hasChoice() and !self.pasting) {
        self.cancelChoice();
        ctx.consumeAndRedraw();
        return;
    }
    if (self.pasting and !self.renaming and !self.model_choice.active) {
        // A paste is text, never approval of a field choice or action.
        ctx.consume_event = true;
        return;
    }
    if (self.renaming) {
        const outcome = self.rename_editor.appEvent(keymap.every, input, self.pasting);
        switch (outcome) {
            .submit => {
                const text = self.rename_editor.buffer[0..self.rename_editor.length];
                if (std.mem.indexOfAny(u8, text, "\r\n\t") != null) {
                    self.failures[6] = " · name must be one line";
                } else {
                    try self.save(ctx, 6, .{ .label = text });
                    // A rejected publication retains the editable name.
                    if (self.pending != null or self.failures[6] == null) self.renaming = false;
                }
            },
            .refused => self.failures[6] = " · name couldn't be entered",
            else => {},
        }
        ctx.consumeAndRedraw();
        return;
    }
    if (self.tool_draft) |*draft| {
        if (input == .key_press and input.key_press.matches(' ', .{})) {
            const tool = std.enums.values(tools.BuiltInTool)[self.panel.choice.?.selected];
            draft.toggle(tool);
            self.updateTools();
            ctx.consumeAndRedraw();
            return;
        }
        if (input == .key_press and input.key_press.matches(vaxis.Key.enter, .{})) {
            const selected = draft.*;
            self.cancelChoice();
            try self.save(ctx, 2, .{ .tools = selected });
            ctx.consumeAndRedraw();
            return;
        }
    }
    self.bind();
    try self.panel.widget().handleEvent(ctx, input);
}

fn safe(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var terminal: TerminalText = .{ .mode = .label };
    try terminal.feed(&out.writer, text);
    try terminal.finish(&out.writer);
    return out.written();
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    return drawContents(raw, ctx) catch |err| switch (err) {
        // All writers here allocate from the draw arena; their only I/O
        // failure is allocation. TerminalText's fixed escape scratch fits.
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
    };
}

fn drawContents(raw: *anyopaque, ctx: vxfw.DrawContext) !vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.bind();
    const size = ctx.max.size();
    if (size.width == 0 or size.height == 0) return .empty(self.widget());
    const name = try safe(ctx.arena, self.title());
    self.panel.title = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ name, self.failures[6] orelse if (self.pending == 6) " · saving" else "" });
    var tool_text: std.Io.Writer.Allocating = .init(ctx.arena);
    if (self.ready) {
        var selected = self.session.tools.iterator();
        while (selected.next()) |tool| {
            if (tool_text.written().len > 0) try tool_text.writer.writeAll(", ");
            try tool_text.writer.writeAll(if (tool == .web_search) "web search" else @tagName(tool));
        }
    }
    self.fields[2].value = if (!self.ready) "unavailable" else if (tool_text.written().len == 0) "none" else tool_text.written();
    if (self.ready) {
        const path = shortPath(self.home, self.session.workspace.slice());
        self.fields[3].value = try safe(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ path.prefix, path.rest }));
        self.fields[4].value = try safe(ctx.arena, self.session.model.slice());
        var context: std.Io.Writer.Allocating = .init(ctx.arena);
        if (self.session.context_estimate) |tokens| try status.writeGrouped(&context.writer, tokens) else try context.writer.writeAll("unknown");
        try context.writer.writeAll(" of ");
        try status.writeGrouped(&context.writer, self.session.compaction_trigger orelse client_defaults.compactionTrigger(self.session.provider, self.session.model.slice()));
        self.fields[5].value = context.written();
    } else self.fields[5].value = "unavailable";
    // Keep failure words visible even when a long saved value would fill the
    // narrow row. This affects presentation only, never the inspected value.
    for (&self.fields) |*field| if (field.tail) |tail| {
        const room = size.width -| 19 -| ctx.stringWidth(tail);
        var iter = ctx.graphemeIterator(field.value);
        var end: usize = 0;
        var cells: usize = 0;
        while (iter.next()) |part| {
            const width = ctx.stringWidth(part.bytes(field.value));
            if (cells + width > room) break;
            cells += width;
            end += part.len;
        }
        field.value = field.value[0..end];
    };
    const actions = try ctx.arena.alloc([]const u8, 3);
    for (self.panel.actions, 6..) |label, row| {
        const message = self.failures[row] orelse if (self.pending == row) " · saving" else "";
        actions[row - 6] = if (message.len > 0 and self.panel.selected == row)
            try std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{ if (row == 8) "Copy" else label, message[" · ".len..] })
        else
            label;
    }
    self.panel.actions = actions;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.panel.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - 1 })) };
    const footer = try ctx.arena.create(Footer);
    footer.* = .{
        .left = try std.fmt.allocPrint(ctx.arena, "{s}{s} · info", .{ if (self.narrow) " ‹ " else " ", name }),
        .right = if (self.narrow) "esc close" else if (self.tool_draft != null) "↑↓ · space toggle · enter save · esc close" else "↑↓ · enter change · esc close",
        .style = self.panel.quiet,
    };
    children[1] = .{ .origin = .{ .row = size.height - 1, .col = 0 }, .surface = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) };
    return .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = children };
}

fn drawRename(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const bytes = self.rename_editor.buffer[0..self.rename_editor.length];
    const cursor = self.rename_editor.cursor;
    var start: usize = 0;
    var iter = ctx.graphemeIterator(bytes);
    while (ctx.stringWidth(bytes[start..cursor]) >= ctx.max.width.? and start < cursor) {
        const part = iter.next() orelse break;
        start += part.len;
    }
    const text: vxfw.Text = .{ .text = bytes[start..], .style = self.panel.title_style, .softwrap = false, .width_basis = .parent };
    var surface = try text.widget().draw(ctx);
    surface.widget = .{ .userdata = self, .drawFn = drawRename };
    if (surface.size.width > 0 and surface.size.height > 0) surface.cursor = .{ .row = 0, .col = @intCast(@min(ctx.stringWidth(bytes[start..cursor]), surface.size.width - 1)) };
    return surface;
}

const Fixture = struct {
    session: status.Session = undefined,
    state_value: SaveState = .idle,
    fail_read: bool = false,
    fail_submit: bool = false,
    edit: ?Edit = null,
    text: [status.max_model_bytes]u8 = undefined,
    archives: usize = 0,
    copies: usize = 0,

    fn init(self: *Fixture) void {
        status.sample(&self.session);
        self.session.label.set("Fix retry deadline") catch unreachable;
        self.session.effort_override = true;
        self.session.tools = .initMany(&.{ .bash, .skill, .web_search });
        // Approved mock inputs, not a pin of the catalog's current defaults.
        self.session.model.set("gpt-6.1-sol") catch unreachable;
        self.session.compaction_trigger = 244_800;
        self.session.context_estimate = 18;
    }
    fn backend(self: *Fixture) Backend {
        return .{ .context = self, .read = read, .configure = configure, .archive = archive, .copy_last_answer = copy, .state = state, .models = models, .caps = caps };
    }
    fn read(raw: *anyopaque, out: *status.Session) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail_read) return error.AccessDenied;
        out.* = self.session;
    }
    fn configure(raw: *anyopaque, edit: Edit) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail_submit) return error.AccessDenied;
        self.edit = switch (edit) {
            .label, .model => |text| blk: {
                @memcpy(self.text[0..text.len], text);
                break :blk if (edit == .label) .{ .label = self.text[0..text.len] } else .{ .model = self.text[0..text.len] };
            },
            else => edit,
        };
        self.state_value = .pending;
    }
    fn archive(raw: *anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail_submit) return error.AccessDenied;
        self.archives += 1;
        self.state_value = .pending;
    }
    fn copy(raw: *anyopaque, _: *vxfw.EventContext) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail_submit) return error.AccessDenied;
        self.copies += 1;
        self.state_value = .pending;
    }
    fn state(raw: *anyopaque) SaveState {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return self.state_value;
    }
    fn models(_: *anyopaque) ?*const picker.Menu {
        return null;
    }
    fn caps(_: *anyopaque) view.Caps {
        return .{};
    }
};

fn press(page: *Self, ctx: *vxfw.EventContext, codepoint: u21) !void {
    ctx.consume_event = false;
    try page.widget().handleEvent(ctx, .{ .key_press = .{ .codepoint = codepoint } });
}

fn typeText(page: *Self, ctx: *vxfw.EventContext, text: []const u8) !void {
    try page.widget().handleEvent(ctx, .{ .key_press = .{ .codepoint = 'a', .text = text } });
}

fn dump(page: *Self, arena: std.mem.Allocator, width: u16, height: u16) ![]const u8 {
    const surface = try page.widget().draw(.{ .arena = arena, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
    var screen = try vaxis.Screen.init(arena, .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
    surface.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen }, page.widget());
    var out: std.Io.Writer.Allocating = .init(arena);
    for (0..height) |row| {
        var line: std.Io.Writer.Allocating = .init(arena);
        for (0..width) |col| try line.writer.writeAll(screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
        try out.writer.writeAll(std.mem.trimEnd(u8, line.written(), " "));
        try out.writer.writeByte('\n');
    }
    return out.written();
}

test "Chat info draws standalone ground and facts at 99 and 46 columns" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend(), .home = "/home/d" };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 99, 46 }) |width| {
        page.narrow = width == 46;
        const text = try dump(&page, arena.allocator(), width, 12);
        try std.testing.expect(std.mem.indexOf(u8, text, " Fix retry deadline\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Effort          high\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Permissions     run without asking\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Tools           bash, skill, web search\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Folder          ~/code/rui\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Context         18 of 244,800\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Rename     Archive     Copy last answer\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (page.narrow) " ‹ Fix retry deadline · info" else " Fix retry deadline · info") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "k7m2qx") == null);
        std.debug.print("\nCHAT INFO {d}x12\n{s}END CHAT INFO\n", .{ width, text });
        const drawn = try page.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 12 }, .cell_size = .{} });
        const panel = drawn.children[0].surface;
        try std.testing.expect(panel.readCell(1, 1).style.bold);
        try std.testing.expectEqual(page.panel.selection.bg, panel.readCell(0, 2).style.bg);
        try std.testing.expectEqual(page.panel.ground.bg, panel.readCell(0, 10).style.bg);
    }
    for (0..10) |width| for (0..8) |height| {
        _ = try page.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
    };
}

test "Chat info effort permissions and tools choices pick and cancel typed edits" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    // Every ordinary field opens and cancels without publishing an edit.
    for ([_]usize{ 0, 1, 2, 4 }) |row| {
        page.panel.selected = row;
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.hasChoice());
        try press(&page, &ctx, vaxis.Key.escape);
        try std.testing.expect(ctx.consume_event);
        try std.testing.expect(!page.hasChoice());
        try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
    }
    // Effort choices admit exactly this model's efforts, plus model default.
    page.panel.selected = 0;
    try press(&page, &ctx, vaxis.Key.enter);
    for (std.enums.values(catalog.ReasoningEffort)) |effort| {
        var offered = false;
        for (page.panel.choice.?.labels) |label| if (std.mem.eql(u8, label, @tagName(effort))) {
            offered = true;
        };
        try std.testing.expectEqual(capability.supportsReasoningEffort(catalog.shipped, page.session.model.slice(), effort), offered);
    }
    page.panel.choice.?.selected = 0;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?catalog.ReasoningEffort, null), fixture.edit.?.effort);
    try std.testing.expectEqual(catalog.ReasoningEffort.high, page.session.effort.?);
    fixture.session.effort_override = false;
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    page.panel.selected = 1;
    try press(&page, &ctx, vaxis.Key.enter);
    try press(&page, &ctx, vaxis.Key.down);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(.ask, fixture.edit.?.permission);
    fixture.session.permission = .ask;
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    page.panel.selected = 2;
    try press(&page, &ctx, vaxis.Key.enter);
    try press(&page, &ctx, ' ');
    try std.testing.expect(!page.tool_draft.?.contains(.bash));
    try std.testing.expect(page.session.tools.contains(.bash));
    try press(&page, &ctx, vaxis.Key.escape);
    try std.testing.expect(page.session.tools.contains(.bash));
    try press(&page, &ctx, vaxis.Key.enter);
    try press(&page, &ctx, ' ');
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!fixture.edit.?.tools.contains(.bash));
    try std.testing.expect(fixture.edit.?.tools.contains(.skill));
    try std.testing.expect(fixture.edit.?.tools.contains(.web_search));
}

test "Chat info read-only rows are skipped by arrows and never activated" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const forward = [_]usize{ 1, 2, 4, 6, 7, 8, 8 };
    for (forward) |wanted| {
        try press(&page, &ctx, vaxis.Key.down);
        try std.testing.expectEqual(wanted, page.panel.selected);
    }
    const backward = [_]usize{ 7, 6, 4, 2, 1, 0, 0 };
    for (backward) |wanted| {
        try press(&page, &ctx, vaxis.Key.up);
        try std.testing.expectEqual(wanted, page.panel.selected);
    }
    for ([_]usize{ 3, 5 }) |row| {
        page.panel.selected = row;
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(!page.hasChoice());
        try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
    }
    try press(&page, &ctx, vaxis.Key.escape);
    try std.testing.expect(!ctx.consume_event); // The owner may close this panel.
}

test "Chat info rename edits title saves label and Escape cancels only edit" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    page.panel.selected = 6;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.renaming);
    try typeText(&page, &ctx, " revised");
    try std.testing.expect(std.mem.indexOf(u8, try dump(&page, arena.allocator(), 46, 12), " Fix retry deadline revised\n") != null);
    try press(&page, &ctx, vaxis.Key.escape);
    try std.testing.expect(ctx.consume_event);
    try std.testing.expect(!page.renaming);
    try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
    try std.testing.expectEqualStrings("Fix retry deadline", page.title());
    try press(&page, &ctx, vaxis.Key.enter);
    try typeText(&page, &ctx, " revised");
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings("Fix retry deadline revised", fixture.edit.?.label);
    try std.testing.expect(!page.renaming);
    try std.testing.expectEqualStrings("Fix retry deadline", page.title());
    try fixture.session.label.set(fixture.edit.?.label);
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings("Fix retry deadline revised", page.title());
}

test "Chat info failures remain on their row and recover from backend answers" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]usize{ 0, 1, 2, 6, 7, 8 }) |row| {
        page.panel.selected = row;
        fixture.fail_submit = true;
        try press(&page, &ctx, vaxis.Key.enter);
        if (row < 7) try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.failures[row] != null);
        try std.testing.expectEqual(@as(?usize, null), page.pending);
        for ([_]u16{ 99, 46 }) |width| {
            const text = try dump(&page, arena.allocator(), width, 12);
            try std.testing.expect(std.mem.indexOf(u8, text, if (row == 7) "couldn't archive" else if (row == 8) "couldn't copy" else "couldn't save") != null);
        }
        page.cancelChoice();
        fixture.fail_submit = false;
    }
    // Late rejection comes from the backend result, not an optimistic value.
    page.panel.selected = 1;
    try press(&page, &ctx, vaxis.Key.enter);
    try press(&page, &ctx, vaxis.Key.enter);
    fixture.state_value = .failed;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures[1].?);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures[1].?);
    try press(&page, &ctx, vaxis.Key.enter);
    try press(&page, &ctx, vaxis.Key.enter);
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(?[]const u8, null), page.failures[1]);
    page.panel.selected = 7;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.archives);
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    page.panel.selected = 8;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.copies);
    fixture.fail_read = true;
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(" · couldn't read chat", page.failures[8].?);
    fixture.fail_read = false;
    page.panel.selected = 1;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!page.read_failed);
    try std.testing.expect(page.hasChoice());
}

test "Chat info completion reports every backend outcome and read failure on edited row" {
    for ([_]SaveState{ .saved, .failed }) |state_value| {
        for ([_]bool{ false, true }) |fail_read| {
            var fixture: Fixture = .{};
            fixture.init();
            var page: Self = .{ .backend = fixture.backend() };
            page.refresh();
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            page.panel.selected = 1;
            try press(&page, &ctx, vaxis.Key.enter);
            try press(&page, &ctx, vaxis.Key.enter);
            try std.testing.expectEqual(@as(?usize, 1), page.pending);
            // No second operation can overwrite the pending row association.
            page.panel.selected = 7;
            try press(&page, &ctx, vaxis.Key.enter);
            try std.testing.expectEqual(@as(usize, 0), fixture.archives);
            try std.testing.expectEqual(@as(?usize, 1), page.pending);
            fixture.fail_read = fail_read;
            fixture.state_value = state_value;
            try page.widget().handleEvent(&ctx, .tick);
            try std.testing.expectEqual(@as(?usize, null), page.pending);
            try std.testing.expectEqual(fail_read, page.read_failed);
            const failure: ?[]const u8 = if (state_value == .failed) " · couldn't save" else if (fail_read) " · couldn't read chat" else null;
            if (failure) |message| {
                try std.testing.expectEqualStrings(message, page.failures[1].?);
                const text = try dump(&page, arena.allocator(), 46, 12);
                try std.testing.expect(std.mem.indexOf(u8, text, message) != null);
            } else try std.testing.expectEqual(@as(?[]const u8, null), page.failures[1]);
        }
    }
}

test "Chat info rename rejects oversized multiline input and preserves cancelled name" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    page.panel.selected = 6;
    try press(&page, &ctx, vaxis.Key.enter);
    try typeText(&page, &ctx, &(@as([status.max_label_bytes + 1]u8, @splat('a'))));
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.failures[6] != null);
    try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
    page.cancelChoice();
    try press(&page, &ctx, vaxis.Key.enter);
    try page.widget().handleEvent(&ctx, .paste_start);
    try typeText(&page, &ctx, "\nsecond line");
    try page.widget().handleEvent(&ctx, .paste_end);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.failures[6] != null);
    try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
    page.cancelChoice();
    try std.testing.expectEqualStrings("Fix retry deadline", page.title());
}

test "Chat info model choice is a full-width field and saves a typed model" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    page.panel.selected = 4;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.model_choice.active);
    const surface = try page.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 99, .height = 20 }, .cell_size = .{} });
    const child = surface.children[0].surface.children[0];
    try std.testing.expectEqual(@as(i17, 0), child.origin.col);
    try std.testing.expectEqual(@as(u16, 99), child.surface.size.width);
    try typeText(&page, &ctx, "5.5");
    const id = page.model_choice.menu.entries[page.model_choice.selected.?].id;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings(id, fixture.edit.?.model);
    try std.testing.expect(!page.hasChoice());
    fixture.state_value = .failed;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures[4].?);
}

test "Chat info pasted keys never approve a field choice" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]usize{ 0, 1, 2, 4 }) |row| {
        page.panel.selected = row;
        try press(&page, &ctx, vaxis.Key.enter);
        try page.widget().handleEvent(&ctx, .paste_start);
        try press(&page, &ctx, ' ');
        try press(&page, &ctx, vaxis.Key.enter);
        try page.widget().handleEvent(&ctx, .paste_end);
        try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
        try std.testing.expect(page.hasChoice());
        if (row == 2) try std.testing.expect(page.tool_draft.?.eql(page.session.tools));
        page.cancelChoice();
    }
}
