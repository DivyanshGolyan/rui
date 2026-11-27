const std = @import("std");
const connection_names = @import("connection_names.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Panel = @import("widgets/Panel.zig");
const provider_route = @import("provider_route.zig");
const Footer = @import("widgets/Footer.zig");
const status = @import("status_page.zig");
const catalog = @import("model_catalog.zig");
const capability = @import("model_capability.zig");
const tools = @import("built_in_tool.zig");
const session_line = @import("session_line.zig");
const setting_words = @import("setting_words.zig");
const ModelChoice = @import("model_choice.zig");
const keymap = @import("keymap.zig");
const keypress = @import("keypress.zig");
const Editor = @import("DraftEditor.zig");
const panel_editor = @import("panel_editor.zig");
const TerminalText = @import("TerminalText.zig");
const shortPath = @import("home_path.zig").shortPath;
const view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");
const Self = @This();
const focus = @import("chat_info_focus.zig");
const connection = @import("connection.zig");

/// Row indices of the Chat panel: its fields, then its actions.
const effort_row = @backingInt(focus.Focus.effort);
const permissions_row = @backingInt(focus.Focus.permissions);
const tools_row = @backingInt(focus.Focus.tools);
const model_row = @backingInt(focus.Focus.model);
const account_row = @backingInt(focus.Focus.account);
const rename_row = @backingInt(focus.Focus.rename);
const archive_row = @backingInt(focus.Focus.archive);
const copy_row = @backingInt(focus.Focus.copy);
const context_row = account_row + 1;
const row_count = copy_row + 1;

pub const SaveState = enum { idle, pending, saved, failed, unconfirmed };
pub const Edit = union(enum) {
    effort: ?catalog.ReasoningEffort,
    permission: @FieldType(status.Session, "permission"),
    tools: @import("configuration_admission.zig").ToolEdit,
    model: []const u8,
    connection: []const u8,
    label: []const u8,

    /// The edit with its text copied into `buffer`, so it outlives the caller's bytes.
    pub fn copiedInto(self: Edit, buffer: []u8) error{ValueTooLong}!Edit {
        switch (self) {
            inline .label, .model, .connection => |text, tag| {
                if (text.len > buffer.len) return error.ValueTooLong;
                @memcpy(buffer[0..text.len], text);
                return @unionInit(Edit, @tagName(tag), buffer[0..text.len]);
            },
            else => return self,
        }
    }
};

pub const Backend = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, *status.Session) anyerror!void,
    configure: *const fn (*anyopaque, Edit) anyerror!void,
    archive: *const fn (*anyopaque) anyerror!view.IntentAdmission,
    copy_last_answer: *const fn (*anyopaque, *vxfw.EventContext) anyerror!void,
    state: *const fn (*anyopaque) SaveState,
    unconfirmed_key: ?*const fn (*anyopaque) ?@import("configure_outcome.zig").Original = null,
    models: *const fn (*anyopaque) ModelChoice.Snapshot,
    caps: *const fn (*anyopaque) view.Caps,
    copied: *const fn (*anyopaque) bool,
};

pub const Row = enum { model, effort };

const Phase = enum { open, pending, failed, unconfirmed };
const Standalone = struct { row: Row, phase: Phase = .open };

standalone: ?Standalone = null,
backend: Backend,
home: []const u8 = "",
narrow: bool = false,
session: status.Session = undefined,
ready: bool = false,
read_failed: bool = false,
panel: Panel = .{ .title = "Chat", .action_gap = 1, .natural_height = true, .top_rule = false },
fields: [rename_row]Panel.Field = undefined,
actions: [3][]const u8 = undefined,
failures: [row_count]?[]const u8 = @splat(null),
unconfirmed_keys: [row_count]?@import("configure_outcome.zig").Original = @splat(null),
pending: ?usize = null,
effort_labels: [std.enums.values(catalog.ReasoningEffort).len + 1][]const u8 = undefined,
effort_count: usize = 0,
tool_draft: ?tools.Selection = null,
tool_labels: [std.enums.values(tools.BuiltInTool).len][]const u8 = undefined,
model_choice: ModelChoice = .{},
/// The connections of this Host's model menu other than the chat's own: where an Account choice may go.
accounts: connection_names.NameSet = .{},
account_choices: connection_names.NameSet = .{},
account_labels: [connection.max_served][]const u8 = undefined,
renaming: bool = false,
rename_bytes: [status.max_label_bytes]u8 = undefined,
rename_editor: Editor = .initLocked(&.{}, .line_refusals_release),
pasting: bool = false,

pub fn clearUnconfirmed(self: *Self, original: @import("configure_outcome.zig").Original) void {
    for (&self.unconfirmed_keys, &self.failures) |*saved, *failure| {
        if (saved.*) |value| if (std.mem.eql(u8, &value.key, &original.key) and value.store.eql(original.store.slice())) {
            saved.* = null;
            failure.* = null;
        };
    }
}

fn clearUnconfirmedPresentation(self: *Self) void {
    for (&self.unconfirmed_keys, &self.failures) |*saved, *failure| {
        if (saved.* != null) {
            saved.* = null;
            failure.* = null;
        }
    }
}

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn bodyWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = drawBody };
}

pub fn footerWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = drawFooter };
}

pub fn openStandaloneChoice(self: *Self, ctx: *vxfw.EventContext, row: Row) !void {
    if (self.pending != null) return;
    self.closeStandaloneChoice();
    self.standalone = .{ .row = row };
    const index: usize = if (row == .model) model_row else effort_row;
    self.bind();
    self.panel.selected = index;
    try activate(self, ctx, index);
}

pub fn standaloneOpen(self: *const Self) bool {
    return if (self.standalone) |shown| shown.phase != .pending else false;
}

pub fn standaloneField(self: *const Self) ?Row {
    return if (self.standalone) |shown| shown.row else null;
}

pub fn standaloneUnconfirmed(self: *const Self) bool {
    return if (self.standalone) |shown| shown.phase == .unconfirmed else false;
}

pub fn closeStandaloneChoice(self: *Self) void {
    self.standalone = null;
    self.cancelEdit();
    self.clearUnconfirmedPresentation();
}

pub fn standaloneWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = standaloneEvent, .drawFn = drawStandalone };
}

fn drawStandalone(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.bind();
    if (!self.standaloneOpen()) return .empty(self.standaloneWidget());
    var surface = try self.panel.drawChoice(ctx, if (self.standalone.?.row == .model) model_row else effort_row);
    surface.widget = self.standaloneWidget();
    return surface;
}

pub fn hasChoice(self: *const Self) bool {
    return self.renaming or self.panel.choice != null or self.model_choice.active;
}

pub fn cancelChoice(self: *Self) void {
    if (self.standalone != null) {
        self.closeStandaloneChoice();
        return;
    }
    if (self.renaming) {
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

fn cancelEdit(self: *Self) void {
    if (self.renaming) _ = self.rename_editor.blur();
    self.renaming = false;
    self.panel.closeChoice();
    self.model_choice.cancel();
    self.panel.custom_choice = null;
    self.tool_draft = null;
    self.pasting = false;
}

pub fn refresh(self: *Self) void {
    self.closeStandaloneChoice();
    self.readSession();
}

fn readSession(self: *Self) void {
    self.cancelEdit();
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
    const model_was_active = self.model_choice.active;
    if (!self.model_choice.validate() and model_was_active and self.standalone != null) self.closeStandaloneChoice();
    self.collectAccounts();
    self.panel.userdata = self;
    self.panel.on_activate = activate;
    self.panel.on_pick = pick;
    self.panel.title = self.title();
    self.fields = .{
        .{ .label = "Effort", .value = if (!self.ready) "unavailable" else setting_words.effort(if (self.session.effort_override) self.session.effort else null), .tail = self.failures[0] },
        .{ .label = "Permissions", .value = if (!self.ready) "unavailable" else setting_words.permission(self.session.permission), .tail = self.failures[1] },
        .{ .label = "Allowed tools", .value = "", .tail = self.failures[2] },
        .{ .label = "Folder", .value = if (self.ready) self.session.workspace.slice() else "unavailable", .selectable = false },
        .{ .label = "Model", .value = if (self.ready) self.session.model.slice() else "unavailable", .tail = self.failures[model_row] },
        .{ .label = "Account", .value = if (self.ready) self.session.provider.slice() else "unavailable", .tail = self.failures[account_row], .visible = self.accounts.len > 0 },
        .{ .label = "Context", .value = "", .selectable = false, .visible = self.ready and self.contextReading() != null },
    };
    if (self.pending) |row| if (row < self.fields.len) {
        self.fields[row].tail = " · saving";
    };
    self.panel.fields = &self.fields;
    self.actions = .{ "Rename", "Archive", if (self.backend.copied(self.backend.context)) "Copied          " else "Copy last answer" };
    self.panel.actions = &self.actions;
    const caps = self.backend.caps(self.backend.context);
    self.panel.unicode = caps.unicode;
    self.model_choice.unicode = caps.unicode;
    self.panel.ground = widget_style.of(caps, .{});
    self.panel.selection = widget_style.of(caps, .{ .background = .selection });
    self.panel.hover_style = widget_style.of(caps, .{ .background = .hover });
    self.panel.title_style = widget_style.of(caps, .{ .colour = .strong, .bold = true });
    self.panel.quiet = widget_style.of(caps, .{ .colour = .quiet });
    self.panel.rule = widget_style.line(caps, .horizontal);
    self.model_choice.show_more = self.standalone == null;
    self.model_choice.ground = self.panel.ground;
    self.model_choice.selection = self.panel.selection;
    self.model_choice.hover_style = self.panel.hover_style;
    self.model_choice.quiet = self.panel.quiet;
    self.panel.title_widget = .{ .userdata = self, .drawFn = drawTitle };
    self.panel.custom_choice = if (self.model_choice.active) self.model_choice.field(model_row) else null;
}

fn activate(raw: *anyopaque, ctx: *vxfw.EventContext, row: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.pending != null) return;
    defer if (self.standalone) |*shown| {
        if (self.pending == null) shown.phase = if (self.failures[row] != null) .failed else .open;
    };
    self.readSession();
    if (self.read_failed) {
        self.failures[row] = " · couldn't read chat";
        ctx.redraw = true;
        return;
    }
    self.failures[row] = null;
    self.unconfirmed_keys[row] = null;
    switch (row) {
        0 => {
            self.effort_labels[0] = setting_words.effort_default;
            self.effort_count = 1;
            const shown = if (self.standalone != null or self.session.effort_override) self.session.effort else null;
            var current: ?usize = if (shown == null) 0 else null;
            for (std.enums.values(catalog.ReasoningEffort)) |effort| {
                if (!capability.supportsReasoningEffort(catalog.shipped, self.session.model.slice(), effort)) continue;
                if (shown == effort) current = self.effort_count;
                self.effort_labels[self.effort_count] = setting_words.effort(effort);
                self.effort_count += 1;
            }
            self.panel.openChoice(self.effort_labels[0..self.effort_count], current);
        },
        1 => self.panel.openChoice(&setting_words.permission_labels, setting_words.permissionChoice(self.session.permission)),
        2 => {
            self.tool_draft = self.session.builtInTools();
            self.updateTools();
            self.panel.openChoice(&self.tool_labels, null);
        },
        model_row => self.openModel(),
        account_row => self.openAccounts(),
        rename_row => {
            self.rename_editor = .initLocked(&self.rename_bytes, .line_refusals_release);
            _ = self.rename_editor.append(self.session.label.slice());
            self.renaming = true;
        },
        archive_row, copy_row => {
            if (row == archive_row) {
                if (try self.backend.archive(self.backend.context) == .refused) {
                    self.failures[row] = " · couldn't archive";
                    ctx.redraw = true;
                    return;
                }
            } else self.backend.copy_last_answer(self.backend.context, ctx) catch {
                self.failures[row] = " · couldn't copy";
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
    self.model_choice.openSource(.{ .context = self.backend.context, .read = self.backend.models }, self.session.provider, self.session.model.slice());
    self.model_choice.userdata = self;
    self.model_choice.on_pick = pickModel;
    if (!self.model_choice.active) self.failures[model_row] = " · models unavailable";
}

fn openAccounts(self: *Self) void {
    self.account_choices = .{};
    self.account_choices.insert(self.session.provider) catch unreachable;
    self.account_choices.unionWith(&self.accounts) catch {};
    for (self.account_choices.slice(), 0..) |*name, at| self.account_labels[at] = name.slice();
    self.panel.openChoice(self.account_labels[0..self.account_choices.len], 0);
}

/// The model menu names every connection the Host serves; the chat's own is not a place to move to.
fn collectAccounts(self: *Self) void {
    self.accounts = .{};
    if (!self.ready) return;
    const menu = self.backend.models(self.backend.context).menu orelse return;
    for (menu.entries) |entry| for (entry.providers.slice()) |name| {
        if (name.eql(self.session.provider)) continue;
        self.accounts.insert(name) catch return;
    };
}

fn pickModel(raw: *anyopaque, ctx: *vxfw.EventContext, model: []const u8) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.save(ctx, model_row, .{ .model = model });
}

fn contextReading(self: *const Self) ?session_line.Context {
    return session_line.Context.of(self.session.context_estimate, self.session.compaction_trigger);
}

fn updateTools(self: *Self) void {
    inline for (std.enums.values(tools.BuiltInTool), 0..) |tool, at| {
        const name = comptime tools.shown(tool);
        self.tool_labels[at] = if (self.tool_draft.?.contains(tool)) "✓ " ++ name else "  " ++ name;
    }
}

fn pick(raw: *anyopaque, ctx: *vxfw.EventContext, row: usize, choice: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (row) {
        0 => try self.save(ctx, row, .{ .effort = if (choice == 0) null else std.meta.stringToEnum(catalog.ReasoningEffort, self.effort_labels[choice]).? }),
        1 => try self.save(ctx, row, .{ .permission = setting_words.permissionAt(choice) }),
        account_row => if (choice != 0) try self.save(ctx, row, .{ .connection = self.account_choices.slice()[choice].slice() }),
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
    self.unconfirmed_keys[row] = null;
    self.backend.configure(self.backend.context, edit) catch {
        self.failures[row] = " · couldn't save";
        if (self.standalone) |*shown| shown.phase = .failed;
        ctx.redraw = true;
        return;
    };
    self.pending = row;
    if (self.standalone) |*shown| shown.phase = .pending;
    self.poll();
    ctx.redraw = true;
}

fn poll(self: *Self) void {
    const row = self.pending orelse return;
    const state = self.backend.state(self.backend.context);
    if (state == .idle or state == .pending) return;
    self.readSession();
    if (state == .failed or state == .unconfirmed or self.read_failed) {
        if (self.standalone) |*shown| shown.phase = if (state == .unconfirmed) .unconfirmed else .failed;
    } else {
        self.closeStandaloneChoice();
    }
    if (state == .unconfirmed) if (self.backend.unconfirmed_key) |read| {
        self.unconfirmed_keys[row] = read(self.backend.context);
    };
    self.failures[row] = if (state == .unconfirmed) " · not confirmed · /requests" else if (state == .failed) switch (row) {
        archive_row => " · couldn't archive",
        copy_row => " · couldn't copy",
        else => " · couldn't save",
    } else if (self.read_failed) " · couldn't read chat" else null;
    self.pending = null;
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.model_choice.active and !self.model_choice.validate()) {
        if (self.standalone != null) self.closeStandaloneChoice();
        self.panel.custom_choice = null;
        ctx.consumeAndRedraw();
        return;
    }
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
    if (input == .key_press and (keypress.named(input.key_press) == .escape or keypress.named(input.key_press) == .ctrl_g) and (self.hasChoice() or self.standalone != null) and !self.pasting) {
        if (self.standalone != null) self.closeStandaloneChoice() else self.cancelChoice();
        ctx.consumeAndRedraw();
        return;
    }
    if (self.pasting and !self.renaming and !self.model_choice.active) {
        ctx.consume_event = true;
        return;
    }
    if (self.renaming) {
        const outcome = panel_editor.event(&self.rename_editor, input, self.pasting, &self.failures[rename_row]);
        switch (outcome) {
            .submit => {
                const text = self.rename_editor.text();
                if (std.mem.indexOfAny(u8, text, "\r\n\t") != null) {
                    self.failures[rename_row] = " · name must be one line";
                } else {
                    try self.save(ctx, rename_row, .{ .label = text });
                    if (self.pending != null or self.failures[rename_row] == null) self.renaming = false;
                }
            },
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
            var edit: @import("configuration_admission.zig").ToolEdit = .{};
            edit.replaceBuiltIns(&self.session.tools, &self.session.loaded_tools, selected) catch |err| {
                self.failures[tools_row] = if (err == error.LoadedToolsNotAllowed) " · loaded tools aren't allowed" else " · too many tool names";
                ctx.consumeAndRedraw();
                return;
            };
            try self.save(ctx, tools_row, .{ .tools = edit });
            ctx.consumeAndRedraw();
            return;
        }
    }
    self.bind();
    if (!self.pasting and !self.model_choice.active and input == .key_press) {
        if (keypress.named(input.key_press)) |name| if (@import("app_input.zig").keys.get(name)) |direction| {
            if (self.standalone == null or self.standalone.?.phase != .pending)
                return self.panel.traverse(ctx, direction == .previous, @import("app_input.zig").tabNextValue);
        };
    }
    if (self.standalone) |shown| {
        if (shown.phase == .pending) return;
        try self.panel.choiceEvent(ctx, input, if (shown.row == .model) model_row else effort_row);
    } else {
        if (!self.hasChoice() and input == .key_press) {
            if (focusMove(input.key_press)) |move| {
                const current: focus.Focus = @fromBackingInt(@intCast(self.panel.selected));
                const next = focus.step(if (self.panel.stacked_actions) .stacked else .horizontal, self.accounts.len > 0, current, move);
                self.panel.selected = @backingInt(next);
                ctx.consumeAndRedraw();
                return;
            }
        }
        try self.panel.widget().handleEvent(ctx, input);
    }
}

fn focusMove(key: vaxis.Key) ?focus.Move {
    if (key.matches(vaxis.Key.up, .{})) return .up;
    if (key.matches(vaxis.Key.down, .{})) return .down;
    if (key.matches(vaxis.Key.left, .{})) return .left;
    if (key.matches(vaxis.Key.right, .{})) return .right;
    return null;
}

fn standaloneEvent(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (input == .tick or self.standaloneOpen()) try event(raw, ctx, input);
}

fn safe(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var terminal: TerminalText = .{ .mode = .label };
    try terminal.feed(&out.writer, text);
    try terminal.finish(&out.writer);
    return out.written();
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    if (size.width == 0 or size.height == 0) return .empty(self.widget());
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try drawBodyMode(self, ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - 1 }), true) };
    children[1] = .{ .origin = .{ .row = children[0].surface.size.height, .col = 0 }, .surface = try self.footerWidget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) };
    return .{ .widget = self.widget(), .size = .{ .width = size.width, .height = children[0].surface.size.height + 1 }, .buffer = &.{}, .children = children, .cursor = children[0].surface.cursor };
}

fn drawBody(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    return drawBodyMode(self, ctx, false);
}

fn drawBodyMode(self: *Self, ctx: vxfw.DrawContext, show_title: bool) std.mem.Allocator.Error!vxfw.Surface {
    return drawBodyContents(self, ctx, show_title) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
    };
}

fn folderValue(self: *const Self, ctx: vxfw.DrawContext, room: u16) ![]const u8 {
    const path = shortPath(self.home, self.session.workspace.slice());
    const shortened = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ path.prefix, path.rest });
    const text = try Panel.displayText(ctx.arena, try safe(ctx.arena, shortened), self.panel.unicode);
    if (ctx.stringWidth(text) <= room) return text;
    const ellipsis = if (self.panel.unicode) "…" else "...";
    const mark_width = ctx.stringWidth(ellipsis);
    if (mark_width > room) return "";
    for (text, 0..) |byte, at| {
        if (byte != '/' or at + 1 == text.len) continue;
        const tail = text[at..];
        if (mark_width + ctx.stringWidth(tail) <= room) return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ ellipsis, tail });
    }
    const basename = text[if (std.mem.lastIndexOfScalar(u8, text, '/')) |at| at + 1 else 0..];
    var start: usize = 0;
    var cells = ctx.stringWidth(basename);
    var iter = ctx.graphemeIterator(basename);
    while (cells > room - mark_width) {
        const part = iter.next() orelse break;
        const grapheme = part.bytes(basename);
        start += grapheme.len;
        cells -= ctx.stringWidth(grapheme);
    }
    return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ ellipsis, basename[start..] });
}

fn drawBodyContents(self: *Self, ctx: vxfw.DrawContext, show_title: bool) !vxfw.Surface {
    self.bind();
    const size = ctx.max.size();
    if (size.width == 0 or size.height == 0) return .empty(self.bodyWidget());
    const name = try safe(ctx.arena, self.title());
    self.panel.title = if (show_title) name else "";
    self.panel.show_title = show_title or self.renaming or self.failures[rename_row] != null or self.pending == rename_row;
    var tool_text: std.Io.Writer.Allocating = .init(ctx.arena);
    if (self.ready) {
        var selected = self.session.tools.iterator();
        while (selected.next()) |tool_name| {
            if (tool_text.written().len > 0) try tool_text.writer.writeAll(", ");
            try tool_text.writer.writeAll(tools.shownName(tool_name));
        }
    }
    self.fields[2].value = if (!self.ready) "unavailable" else if (tool_text.written().len == 0) "no tools" else tool_text.written();
    const tail = try Panel.displayText(ctx.arena, self.fields[2].tail orelse "", self.panel.unicode);
    const tool_room = Panel.valueWidth(size.width) -| @as(u16, @intCast(@min(ctx.stringWidth(tail), std.math.maxInt(u16))));
    self.fields[2].value = (try view.fitted(ctx.arena, self.backend.caps(self.backend.context), self.fields[2].value, tool_room, .head)).bytes;
    if (self.ready) {
        self.fields[3].value = try self.folderValue(ctx, Panel.valueWidth(size.width));
        self.fields[model_row].value = try safe(ctx.arena, self.session.model.slice());
        // Without a trigger (a codec that does not compact) the context row is omitted.
        if (self.contextReading()) |reading| {
            var context: std.Io.Writer.Allocating = .init(ctx.arena);
            try status.writeGrouped(&context.writer, reading.estimate);
            try context.writer.writeAll(" of ");
            try status.writeGrouped(&context.writer, reading.trigger);
            self.fields[context_row].value = context.written();
        }
    }
    const actions = try ctx.arena.alloc([]const u8, 3);
    var action_width: usize = 3 + 2 * 5;
    for (self.panel.actions, rename_row..) |label, row| {
        const message = if (row == rename_row) "" else self.failures[row] orelse if (self.pending == row) " · saving" else "";
        actions[row - rename_row] = if (message.len > 0)
            try std.fmt.allocPrint(ctx.arena, "{s}: {s}", .{ if (row == copy_row) "Copy" else label, message[" · ".len..] })
        else
            label;
        action_width += ctx.stringWidth(actions[row - rename_row]);
    }
    self.panel.actions = actions;
    self.panel.stacked_actions = action_width > size.width;
    self.panel.action_gap = 1;
    var surface = try self.panel.widget().draw(ctx);
    surface.widget = self.bodyWidget();
    return surface;
}

fn drawFooter(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    return drawFooterContents(raw, ctx) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
    };
}

fn drawFooterContents(raw: *anyopaque, ctx: vxfw.DrawContext) !vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const caps = self.backend.caps(self.backend.context);
    const name = try safe(ctx.arena, self.title());
    const footer: Footer = .{
        .left = try Panel.displayText(ctx.arena, name, caps.unicode),
        .right = "esc",
        .left_inset = 1,
        .style = widget_style.of(caps, .{ .colour = .quiet }),
    };
    var surface = try footer.widget().draw(ctx);
    surface.widget = self.footerWidget();
    return surface;
}

fn drawTitle(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    var surface = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
    @memset(surface.buffer, .{ .style = self.panel.ground });
    if (size.width == 0 or size.height == 0) return surface;
    const failure = try Panel.displayText(ctx.arena, self.failures[rename_row] orelse if (self.pending == rename_row) " · saving" else "", self.panel.unicode);
    const tail_width: u16 = @intCast(@min(ctx.stringWidth(failure), size.width));
    const edit_width = size.width - tail_width;
    const original = if (self.renaming) self.rename_editor.text() else self.panel.title;
    const bytes = try Panel.displayText(ctx.arena, original, self.panel.unicode);
    const cursor = if (self.renaming) (try Panel.displayText(ctx.arena, original[0..self.rename_editor.cursor()], self.panel.unicode)).len else 0;
    var start: usize = 0;
    var iter = ctx.graphemeIterator(bytes);
    while (ctx.stringWidth(bytes[start..cursor]) >= edit_width and start < cursor) {
        const part = iter.next() orelse break;
        start += part.len;
    }
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    const text: vxfw.Text = .{ .text = bytes[start..], .style = self.panel.title_style, .softwrap = false, .width_basis = .parent };
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try text.widget().draw(ctx.withConstraints(.{}, .{ .width = edit_width, .height = 1 })) };
    children[0].surface.widget = self.widget();
    const tail: vxfw.Text = .{ .text = failure, .style = self.panel.quiet, .softwrap = false, .width_basis = .parent };
    children[1] = .{ .origin = .{ .row = 0, .col = edit_width }, .surface = try tail.widget().draw(ctx.withConstraints(.{}, .{ .width = tail_width, .height = 1 })) };
    children[1].surface.widget = self.widget();
    surface.children = children;
    if (self.renaming and edit_width > 0) surface.cursor = .{ .row = 0, .col = @intCast(@min(ctx.stringWidth(bytes[start..cursor]), edit_width - 1)) };
    return surface;
}

const Fixture = struct {
    unicode: bool = true,
    background: ?view.Rgb = null,
    read_calls: usize = 0,
    save_calls: usize = 0,
    session: status.Session = undefined,
    state_value: SaveState = .idle,
    fail_read: bool = false,
    fail_submit: bool = false,
    edit: ?Edit = null,
    text: [status.max_model_bytes]u8 = undefined,
    archives: usize = 0,
    copies: usize = 0,
    copy_notice: @import("session_chrome.zig").Notice(64) = .{},
    menu: ?*const @import("model_picker.zig").Menu = null,

    fn init(self: *Fixture) void {
        status.sample(&self.session);
        self.session.label.set("Fix retry deadline") catch unreachable;
        self.session.effort_override = true;
        self.session.tools = @import("command_input.zig").ToolsField.of(&.{ "bash", "skill", "web_search" }) catch unreachable;
        self.session.model.set("gpt-6.1-sol") catch unreachable;
        self.session.compaction_trigger = 244_800;
        self.session.context_estimate = 18;
    }
    fn backend(self: *Fixture) Backend {
        return .{ .context = self, .read = read, .configure = configure, .archive = archive, .copy_last_answer = copy, .state = state, .models = models, .caps = caps, .copied = copied };
    }
    fn read(raw: *anyopaque, out: *status.Session) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.read_calls += 1;
        if (self.fail_read) return error.AccessDenied;
        out.* = self.session;
    }
    fn configure(raw: *anyopaque, edit: Edit) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.save_calls += 1;
        if (self.fail_submit) return error.AccessDenied;
        self.edit = try edit.copiedInto(&self.text);
        self.state_value = .pending;
    }
    fn archive(raw: *anyopaque) !view.IntentAdmission {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail_submit) return .refused;
        self.archives += 1;
        self.state_value = .pending;
        return .admitted;
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
    fn models(raw: *anyopaque) ModelChoice.Snapshot {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return .{ .menu = self.menu };
    }
    fn copied(raw: *anyopaque) bool {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return self.copy_notice.showsPanelCopy(0);
    }
    fn caps(raw: *anyopaque) view.Caps {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return .{ .unicode = self.unicode, .background = self.background };
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
    return dumpWidget(page.widget(), arena, width, height);
}

fn dumpWidget(widget_: vxfw.Widget, arena: std.mem.Allocator, width: u16, height: u16) ![]const u8 {
    const surface = try widget_.draw(.{ .arena = arena, .cell_arena = arena, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
    var screen = try vaxis.Screen.init(arena, .{ .cols = width, .rows = height, .x_pixel = 0, .y_pixel = 0 });
    try surface.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen }, widget_);
    var out: std.Io.Writer.Allocating = .init(arena);
    for (0..surface.size.height) |row| {
        var line: std.Io.Writer.Allocating = .init(arena);
        var col: u16 = 0;
        while (col < width) {
            const cell = screen.readCell(col, @intCast(row)).?;
            try line.writer.writeAll(cell.char.grapheme);
            col += @max(1, cell.char.width);
        }
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
        try std.testing.expect(std.mem.indexOf(u8, text, "   Allowed tools   bash, skill, web search\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Folder          ~/code/rui\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Context         18 of 244,800\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Rename     Archive     Copy last answer\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Fix retry deadline") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "k7m2qx") == null);
        std.debug.print("\nCHAT INFO {d}x12\n{s}END CHAT INFO\n", .{ width, text });
        const drawn = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 12 }, .cell_size = .{} });
        const panel = drawn.children[0].surface;
        try std.testing.expect(panel.readCell(1, 0).style.bold);
        try std.testing.expectEqual(page.panel.selection.bg, panel.readCell(0, 1).style.bg);
        try std.testing.expectEqual(page.panel.ground.bg, panel.readCell(0, 9).style.bg);
    }
    for (0..10) |width| for (0..8) |height| {
        _ = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
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
    for ([_]usize{ 0, 1, 2, 4 }) |row| {
        page.panel.selected = row;
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.hasChoice());
        try press(&page, &ctx, vaxis.Key.escape);
        try std.testing.expect(ctx.consume_event);
        try std.testing.expect(!page.hasChoice());
        try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
    }
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
    for (page.panel.choice.?.labels) |label| try std.testing.expect(std.mem.indexOf(u8, label, "web_search") == null);
    var offers_web_search = false;
    for (page.panel.choice.?.labels) |label| offers_web_search = offers_web_search or std.mem.indexOf(u8, label, "web search") != null;
    try std.testing.expect(offers_web_search);
    try press(&page, &ctx, ' ');
    try std.testing.expect(!page.tool_draft.?.contains(.bash));
    try std.testing.expect(page.session.tools.contains("bash"));
    try press(&page, &ctx, vaxis.Key.escape);
    try std.testing.expect(page.session.tools.contains("bash"));
    try press(&page, &ctx, vaxis.Key.enter);
    try press(&page, &ctx, ' ');
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!fixture.edit.?.tools.allowed.contains("bash"));
    try std.testing.expect(fixture.edit.?.tools.allowed.contains("skill"));
    try std.testing.expect(fixture.edit.?.tools.allowed.contains("web_search"));
}

test "Chat info read-only rows are skipped by arrows and never activated" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const forward = [_]usize{ 1, 2, 4, 7, 7 };
    for (forward) |wanted| {
        try press(&page, &ctx, vaxis.Key.down);
        try std.testing.expectEqual(wanted, page.panel.selected);
    }
    const backward = [_]usize{ 4, 2, 1, 0, 0 };
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
    page.panel.selected = 7;
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
    for ([_]usize{ 0, 1, 2, 7, 8, 9 }) |row| {
        page.panel.selected = row;
        fixture.fail_submit = true;
        try press(&page, &ctx, vaxis.Key.enter);
        if (row < archive_row) try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.failures[row] != null);
        try std.testing.expectEqual(@as(?usize, null), page.pending);
        for ([_]u16{ 99, 46 }) |width| {
            const text = try dump(&page, arena.allocator(), width, 12);
            try std.testing.expect(std.mem.indexOf(u8, text, if (row == archive_row) "couldn't archive" else if (row == copy_row) "couldn't copy" else "couldn't save") != null);
        }
        page.cancelChoice();
        fixture.fail_submit = false;
    }
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
    page.panel.selected = 8;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.archives);
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    page.panel.selected = 9;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.copies);
    fixture.fail_read = true;
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(" · couldn't read chat", page.failures[9].?);
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
            page.panel.selected = 8;
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
    page.panel.selected = 7;
    try press(&page, &ctx, vaxis.Key.enter);
    try typeText(&page, &ctx, &(@as([status.max_label_bytes + 1]u8, @splat('a'))));
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.failures[rename_row] != null);
    try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
    page.cancelChoice();
    try press(&page, &ctx, vaxis.Key.enter);
    try page.widget().handleEvent(&ctx, .paste_start);
    try typeText(&page, &ctx, "\nsecond line");
    try page.widget().handleEvent(&ctx, .paste_end);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.failures[rename_row] != null);
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
    for ([_]u16{ 99, 46 }) |width| {
        const surface = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
        const parts = surface.children[0].surface.children;
        const child = parts[parts.len - 1];
        try std.testing.expectEqual(@as(i17, 0), child.origin.col);
        try std.testing.expectEqual(width, child.surface.size.width);
        try std.testing.expectEqual(@as(u16, 19), surface.cursor.?.col);
        try std.testing.expectEqual(@as(u16, 5), surface.cursor.?.row);
        try std.testing.expectEqualStrings("C", surface.children[0].surface.readCell(3, 6 + page.panel.custom_height).char.grapheme);
        try std.testing.expect(std.mem.indexOf(u8, try dump(&page, arena.allocator(), width, 20), "Filter:") == null);
    }
    try typeText(&page, &ctx, "5.5");
    for ([_]u16{ 99, 46 }) |width| {
        const surface = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
        var screen = try vaxis.Screen.init(arena.allocator(), .{ .cols = width, .rows = 20, .x_pixel = 0, .y_pixel = 0 });
        try surface.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 20, .screen = &screen }, page.widget());
        try std.testing.expect(screen.cursor_vis);
        try std.testing.expectEqual(@as(u16, 22), screen.cursor.col);
        try std.testing.expectEqual(@as(u16, 5), screen.cursor.row);
        try std.testing.expectEqualStrings("5", screen.readCell(19, 5).?.char.grapheme);
        try std.testing.expectEqualStrings("C", screen.readCell(3, 6 + page.panel.custom_height).?.char.grapheme);
    }
    const id = page.model_choice.menu.entries[page.model_choice.focus.selected().?].id;
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
        if (row == 2) try std.testing.expect(page.tool_draft.?.eql(page.session.builtInTools()));
        page.cancelChoice();
    }
}

test "Chat info rename failure words remain visible beside long editable names" {
    for (0..3) |failure| {
        var fixture: Fixture = .{};
        fixture.init();
        try fixture.session.label.set(&(@as([70]u8, @splat('n'))));
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        page.panel.selected = 7;
        try press(&page, &ctx, vaxis.Key.enter);
        switch (failure) {
            0 => fixture.fail_submit = true,
            1 => try typeText(&page, &ctx, &(@as([status.max_label_bytes + 1]u8, @splat('x')))),
            2 => {
                try page.widget().handleEvent(&ctx, .paste_start);
                try typeText(&page, &ctx, "\nsecond");
                try page.widget().handleEvent(&ctx, .paste_end);
            },
            else => unreachable,
        }
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.renaming);
        const words = switch (failure) {
            0 => "couldn't save",
            1 => "text couldn't be entered",
            2 => "name must be one line",
            else => unreachable,
        };
        for ([_]u16{ 99, 46 }) |width| {
            const text = try dump(&page, arena.allocator(), width, 12);
            try std.testing.expect(std.mem.indexOf(u8, text, words) != null);
        }
        try press(&page, &ctx, vaxis.Key.escape);
        try std.testing.expect(!page.renaming);
        fixture.fail_submit = false;
        try press(&page, &ctx, vaxis.Key.enter);
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqualStrings(fixture.session.label.slice(), fixture.edit.?.label);
    }
}

test "Chat info action failures persist after navigation and fit narrow rows together" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]usize{ archive_row, copy_row }) |row| {
        page.panel.selected = row;
        try press(&page, &ctx, vaxis.Key.enter);
        for (0..9) |_| try press(&page, &ctx, vaxis.Key.up);
        try std.testing.expectEqual(@as(usize, 0), page.panel.selected);
        fixture.state_value = .failed;
        try page.widget().handleEvent(&ctx, .tick);
        for ([_]u16{ 99, 46 }) |width| {
            const text = try dump(&page, arena.allocator(), width, 14);
            try std.testing.expect(std.mem.indexOf(u8, text, if (row == archive_row) "Archive: couldn't archive" else "Copy: couldn't copy") != null);
        }
    }
    const text = try dump(&page, arena.allocator(), 46, 14);
    try std.testing.expect(std.mem.indexOf(u8, text, "Archive: couldn't archive") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Copy: couldn't copy") != null);
}

test "Chat info static title keeps late and cancelled rename failures visible for long Unicode names" {
    for ([_][]const u8{ &(@as([70]u8, @splat('n'))), "界界界界界界界界界界界界界界界界界界界界界界" }) |name| for (0..3) |outcome| {
        var fixture: Fixture = .{};
        fixture.init();
        try fixture.session.label.set(name);
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        page.panel.selected = 7;
        try press(&page, &ctx, vaxis.Key.enter);
        fixture.fail_submit = outcome == 2;
        try press(&page, &ctx, vaxis.Key.enter);
        if (outcome == 2) {
            try press(&page, &ctx, vaxis.Key.escape);
        } else {
            try std.testing.expect(!page.renaming);
            for ([_]u16{ 99, 46 }) |width| try std.testing.expect(std.mem.indexOf(u8, try dump(&page, arena.allocator(), width, 12), "saving") != null);
            fixture.fail_read = outcome == 1;
            fixture.state_value = if (outcome == 1) .saved else .failed;
            try page.widget().handleEvent(&ctx, .tick);
        }
        try std.testing.expect(!page.renaming);
        for ([_]u16{ 99, 46 }) |width| {
            const text = try dump(&page, arena.allocator(), width, 12);
            try std.testing.expect(std.mem.indexOf(u8, text, if (outcome == 1) "couldn't read chat" else "couldn't save") != null);
        }
    };
}

test "Chat info shared ASCII capability reaches tools model rename failures and footer" {
    var fixture: Fixture = .{ .unicode = false };
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 46, 99 }) |width| {
        page.narrow = width == 46;
        for (0..5) |state| {
            page.cancelChoice();
            page.failures[1] = " · couldn't save";
            page.failures[rename_row] = " · name couldn't be entered";
            if (state > 0) {
                page.panel.selected = switch (state) {
                    1 => 0,
                    2 => 2,
                    else => 4,
                };
                try press(&page, &ctx, vaxis.Key.enter);
                if (state == 4) page.model_choice.no_match = true;
            }
            const text = try dump(&page, arena.allocator(), width, 20);
            for (text) |byte| try std.testing.expect(byte < 0x80);
            try std.testing.expect(!page.panel.unicode and !page.model_choice.unicode);
            try std.testing.expect(std.mem.indexOf(u8, text, "Fix retry deadline") != null);
            if (state == 2) try std.testing.expect(std.mem.indexOf(u8, text, "+ bash") != null);
            if (state >= 3) {
                try std.testing.expect(std.mem.indexOf(u8, text, "Filter:") == null);
                if (state == 4) try std.testing.expect(std.mem.indexOf(u8, text, ". no matches") != null);
            }
        }
    }
}

test "Chat info footer stays plain in both themes and widths" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]?view.Rgb{ null, .{ 255, 255, 255 } }) |background| for ([_]u16{ 140, 46 }) |width| {
        fixture.background = background;
        const surface = try page.footerWidget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        const plain = widget_style.of(fixture.backend().caps(&fixture), .{ .colour = .quiet });
        for (surface.buffer, 0..) |cell, col| {
            try std.testing.expectEqual(plain, cell.style);
            const expected = if (col > 0 and col <= page.title().len) page.title()[col - 1] else if (col >= width - 3) "esc"[col - (width - 3)] else ' ';
            try std.testing.expectEqual(expected, cell.char.grapheme[0]);
        }
    };
}

test "Chat info hosted idle has no title row but rename and errors retain one" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 140, 46 }) |width| {
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 40 }, .cell_size = .{} };
        const idle = try page.bodyWidget().draw(ctx);
        const idle_height = idle.size.height;
        try std.testing.expectEqual(@as(u16, 0), page.panel.body.top);
        try std.testing.expectEqual(@as(?u16, 0), page.panel.fieldRow(0));
        try std.testing.expectEqualStrings("E", idle.readCell(3, 0).char.grapheme);
        const standalone = try page.widget().draw(ctx);
        try std.testing.expectEqual(idle_height + 2, standalone.size.height);
        try std.testing.expectEqual(@as(u16, 1), page.panel.body.top);
        page.failures[rename_row] = " · couldn't save";
        const failed = try page.bodyWidget().draw(ctx);
        try std.testing.expectEqual(idle_height + 1, failed.size.height);
        try std.testing.expectEqual(@as(?u16, 1), page.panel.fieldRow(0));
        page.failures[rename_row] = null;
        page.renaming = true;
        const editing = try page.bodyWidget().draw(ctx);
        try std.testing.expectEqual(idle_height + 1, editing.size.height);
        try std.testing.expectEqual(@as(?u16, 1), page.panel.fieldRow(0));
        page.renaming = false;
    }
}

test "Chat info hosted tools advertise clipping at wide and narrow widths" {
    var fixture: Fixture = .{};
    fixture.init();
    fixture.session.tools = try .of(&.{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    });
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ true, false }) |unicode| for ([_]u16{ 140, 46 }) |width| {
        fixture.unicode = unicode;
        const body = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 16);
        const mark = if (unicode) "…" else ".";
        try std.testing.expect(std.mem.endsWith(u8, page.fields[2].value, mark));
        try std.testing.expect(std.mem.indexOf(u8, body, page.fields[2].value) != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "Fix retry deadline") == null);
        try std.testing.expectEqual(@as(usize, Panel.valueWidth(width)), page.fields[2].value.len - mark.len + (if (unicode) @as(usize, 1) else mark.len));
        const footer = try dumpWidget(page.footerWidget(), arena.allocator(), width, 1);
        try std.testing.expect(std.mem.indexOf(u8, footer, "Fix retry deadline") != null);
        try std.testing.expect(std.mem.endsWith(u8, footer, "esc\n"));
        page.failures[2] = " · couldn't save";
        const failed = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 16);
        try std.testing.expect(std.mem.endsWith(u8, page.fields[2].value, mark));
        try std.testing.expect(std.mem.indexOf(u8, failed, "couldn't save") != null);
        page.failures[2] = null;
    };
}

test "Chat info hosted body excludes its independent single-row footer" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend(), .home = "/home/d" };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ true, false }) |unicode| for ([_]u16{ 46, 99 }) |width| {
        fixture.unicode = unicode;
        page.narrow = width == 46;
        const body = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 14);
        const footer = try dumpWidget(page.footerWidget(), arena.allocator(), width, 1);
        const complete = try dump(&page, arena.allocator(), width, 15);
        try std.testing.expect(std.mem.indexOf(u8, body, "Context") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "Rename") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, " info") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "esc close") == null);
        try std.testing.expect(std.mem.indexOf(u8, footer, "Fix retry deadline") != null);
        try std.testing.expect(std.mem.indexOf(u8, footer, "info") == null);
        try std.testing.expect(std.mem.indexOf(u8, footer, "esc close") == null);
        try std.testing.expect(std.mem.endsWith(u8, footer, "esc\n"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, footer, "\n"));
        try std.testing.expect(std.mem.indexOf(u8, body, "Fix retry deadline") == null);
        try std.testing.expect(std.mem.indexOf(u8, complete, "Fix retry deadline") != null);
        if (!unicode) for (body) |byte| try std.testing.expect(byte < 0x80);
        if (!unicode) for (footer) |byte| try std.testing.expect(byte < 0x80);
    };
}

test "Chat info Context appears only for measured estimates regardless of work or history" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (std.enums.values(@FieldType(status.Work, "state"))) |work| for ([_]bool{ false, true }) |history| for ([_]?u64{ null, 0, 18, 31_200 }) |estimate| {
        fixture.session.work.state = work;
        fixture.session.work.recent_count = @intFromBool(history);
        fixture.session.work.recent[0] = .{ .message = .{}, .outcome = .{} };
        fixture.session.context_estimate = estimate;
        page.refresh();
        const text = try dumpWidget(page.bodyWidget(), arena.allocator(), 99, 14);
        try std.testing.expectEqual(estimate != null, page.fields[context_row].visible);
        try std.testing.expectEqual(estimate != null, std.mem.indexOf(u8, text, "Context") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "unknown") == null);
        if (estimate) |tokens| {
            try std.testing.expect(std.mem.indexOf(u8, text, switch (tokens) {
                0 => "Context         0 of 244,800",
                18 => "Context         18 of 244,800",
                else => "Context         31,200 of 244,800",
            }) != null);
        } else try std.testing.expect(std.mem.indexOf(u8, text, "Model           gpt-6.1-sol\n\n   Rename") != null);
        _ = arena.reset(.retain_capacity);
    };
    fixture.fail_read = true;
    page.refresh();
    const unavailable = try dumpWidget(page.bodyWidget(), arena.allocator(), 99, 14);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "Context") == null);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "unknown") == null);
}

test "SUI-171 Chat info Context shows the Host reported threshold" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { estimate: ?u64, trigger: ?u64, value: ?[]const u8 }{
        .{ .estimate = null, .trigger = null, .value = null },
        .{ .estimate = null, .trigger = 244_800, .value = null },
        .{ .estimate = 18, .trigger = null, .value = null },
        .{ .estimate = 18, .trigger = 0, .value = null },
        .{ .estimate = 0, .trigger = 115_200, .value = "0 of 115,200" },
        .{ .estimate = 18, .trigger = 244_800, .value = "18 of 244,800" },
        .{ .estimate = 31_200, .trigger = 12_345, .value = "31,200 of 12,345" },
    };
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |unicode| for (cases) |case| {
        fixture.session.context_estimate = case.estimate;
        fixture.session.compaction_trigger = case.trigger;
        fixture.unicode = unicode;
        page.refresh();
        const text = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 14);
        try std.testing.expectEqual(case.value != null, page.fields[context_row].visible);
        if (case.value) |value| {
            try std.testing.expectEqualStrings(value, page.fields[context_row].value);
            try std.testing.expect(std.mem.indexOf(u8, text, value) != null);
        } else try std.testing.expect(std.mem.indexOf(u8, text, "Context") == null);
        _ = arena.reset(.retain_capacity);
    };
}

test "Chat info hidden Context preserves action IDs failures and the blank action separator" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]?u64{ null, 18 }) |estimate| for ([_]u16{ 46, 99 }) |width| {
        fixture.session.context_estimate = estimate;
        page.refresh();
        _ = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 15);
        page.panel.selected = 4;
        for ([_]usize{ 7, 8, 9 }) |selected| {
            try press(&page, &ctx, if (selected == 7) vaxis.Key.down else vaxis.Key.right);
            try std.testing.expectEqual(selected, page.panel.selected);
        }
        for ([_]usize{ 8, 7, 4 }) |selected| {
            try press(&page, &ctx, if (selected == 4) vaxis.Key.up else vaxis.Key.left);
            try std.testing.expectEqual(selected, page.panel.selected);
        }
        page.failures[archive_row] = " · couldn't archive";
        page.pending = 9;
        fixture.state_value = .pending;
        const text = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 15);
        try std.testing.expectEqual(@as(usize, 7), page.panel.fields.len);
        try std.testing.expectEqual(@as(?usize, 9), page.pending);
        try std.testing.expectEqual(@as(u16, 1), page.panel.action_gap);
        try std.testing.expect(std.mem.indexOf(u8, text, "\n\n   Rename") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Archive: couldn't archive") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Copy: saving") != null);
        if (width == 46) {
            try std.testing.expect(page.panel.stacked_actions);
            try std.testing.expect(std.mem.indexOf(u8, text, "\n   Archive: couldn't archive\n   Copy: saving\n") != null);
        }
        fixture.session.context_estimate = if (estimate == null) 18 else null;
        fixture.state_value = .failed;
        try page.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqual(@as(?usize, null), page.pending);
        try std.testing.expectEqualStrings(" · couldn't copy", page.failures[copy_row].?);
        try std.testing.expectEqualStrings(" · couldn't archive", page.failures[archive_row].?);
        page.failures[archive_row] = null;
        page.failures[copy_row] = null;
    };
}

test "Chat info Folder prefers whole components then a grapheme-aligned basename suffix" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { home: []const u8 = "/home/d", path: []const u8, room: u16, unicode: bool = true, expected: []const u8 }{
        .{ .path = "/home/d", .room = 1, .expected = "~" },
        .{ .path = "/home/d/code/rui", .room = 10, .expected = "~/code/rui" },
        .{ .path = "/home/d/code/rui", .room = 9, .expected = "…/rui" },
        .{ .path = "/home/d/code/rui", .room = 5, .expected = "…/rui" },
        .{ .path = "/home/d/code/rui", .room = 4, .expected = "…rui" },
        .{ .path = "/home/d/code/rui", .room = 1, .expected = "…" },
        .{ .path = "/home/d/code/rui", .room = 0, .expected = "" },
        .{ .path = "/home/dx/code/rui", .room = 17, .expected = "/home/dx/code/rui" },
        .{ .path = "/home/dx/code/rui", .room = 10, .expected = "…/code/rui" },
        .{ .home = "/", .path = "/code/rui", .room = 9, .expected = "/code/rui" },
        .{ .home = "", .path = "code/rui", .room = 8, .expected = "code/rui" },
        .{ .home = "", .path = "code/rui", .room = 7, .expected = "…/rui" },
        .{ .path = "/home/d/code/rui", .room = 7, .unicode = false, .expected = ".../rui" },
        .{ .path = "/home/d/code/rui", .room = 6, .unicode = false, .expected = "...rui" },
        .{ .path = "/home/d/code/rui", .room = 2, .unicode = false, .expected = "" },
        .{ .path = "/home/d/code/界界", .room = 6, .expected = "…/界界" },
        .{ .path = "/home/d/code/界界", .room = 6, .unicode = false, .expected = ".../??" },
        .{ .path = "/home/d/code/界界", .room = 4, .expected = "…界" },
        .{ .path = "/home/d/code/界界", .room = 2, .expected = "…" },
        .{ .path = "/home/d/code/界界", .room = 4, .unicode = false, .expected = "...?" },
        .{ .path = "/home/d/code/abce\u{301}界", .room = 4, .expected = "…e\u{301}界" },
        .{ .path = "/home/d/code/abce\u{301}界", .room = 3, .expected = "…界" },
        .{ .path = "/home/d/code/abce\u{301}界", .room = 2, .expected = "…" },
        .{ .path = "/home/d/code/abce\u{301}界", .room = 5, .unicode = false, .expected = "...??" },
        .{ .path = "/home/d/very-long-parent/full-basename", .room = 15, .expected = "…/full-basename" },
        .{ .path = "/home/d/full-basename", .room = 12, .expected = "…ll-basename" },
        .{ .home = "", .path = "full-basename", .room = 13, .expected = "full-basename" },
        .{ .home = "", .path = "full-basename", .room = 12, .expected = "…ll-basename" },
    };
    for (cases) |case| {
        errdefer std.debug.print("Folder path={s} room={d} unicode={}\n", .{ case.path, case.room, case.unicode });
        fixture.unicode = case.unicode;
        fixture.session.workspace.set(case.path) catch unreachable;
        page.home = case.home;
        page.refresh();
        page.bind();
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = case.room + 21, .height = 14 }, .cell_size = .{} };
        const value = try page.folderValue(ctx, case.room);
        try std.testing.expectEqualStrings(case.expected, value);
        try std.testing.expect(ctx.stringWidth(value) <= case.room);
        _ = try page.bodyWidget().draw(ctx);
        try std.testing.expectEqualStrings(case.expected, page.fields[3].value);
        const text = try dumpWidget(page.bodyWidget(), arena.allocator(), case.room + 21, 14);
        if (case.expected.len > 0) try std.testing.expect(std.mem.indexOf(u8, text, case.expected) != null);
        if (!case.unicode) for (text) |byte| try std.testing.expect(byte < 0x80);
        _ = arena.reset(.retain_capacity);
    }
    const basename = "a-basename-too-long-for-this-view";
    try fixture.session.workspace.set("/home/d/parent/" ++ basename);
    page.home = "/home/d";
    fixture.unicode = true;
    page.refresh();
    page.bind();
    for (0..basename.len + 2) |room| {
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(room + 19), .height = 14 }, .cell_size = .{} };
        const expected = if (room == 0) "" else try std.fmt.allocPrint(arena.allocator(), "…{s}", .{basename[basename.len - (room - 1) ..]});
        try std.testing.expectEqualStrings(expected, try page.folderValue(ctx, @intCast(room)));
    }
}

fn expectSurfaceBounds(surface: vxfw.Surface) !void {
    for (surface.children) |child| {
        try std.testing.expect(child.origin.row + child.surface.size.height <= surface.size.height);
        try std.testing.expect(child.origin.col + child.surface.size.width <= surface.size.width);
        try expectSurfaceBounds(child.surface);
    }
}

test "Chat info hosted parts and standalone wrapper respect finite zero and small bounds" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ true, false }) |unicode| for ([_]bool{ false, true }) |failed| for (0..65) |width| for (0..15) |height| {
        fixture.unicode = unicode;
        page.failures[1] = if (failed) " · couldn't save" else null;
        page.failures[rename_row] = if (failed) " · name couldn't be entered" else null;
        page.failures[archive_row] = if (failed) " · couldn't archive" else null;
        page.failures[copy_row] = if (failed) " · couldn't copy" else null;
        for ([_]vxfw.Widget{ page.bodyWidget(), page.footerWidget(), page.widget() }, 0..) |part, index| {
            const surface = try part.draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = @intCast(width), .height = @intCast(height) }, .cell_size = .{} });
            try std.testing.expect(surface.size.width <= width);
            try std.testing.expect(surface.size.height <= height);
            if (index == 1) try std.testing.expectEqual(@as(u16, if (height == 0) 0 else 1), surface.size.height);
            try expectSurfaceBounds(surface);
            _ = arena.reset(.retain_capacity);
        }
    };
}

test "Chat info Rename recovers refused input without reopening its field" {
    const Fault = enum { typed_overflow, invalid_utf8, invalid_scalar, paste_overflow, invalid_paste, edit_rejected, paste_edit_rejected, unbound };
    for (std.enums.values(Fault)) |fault| {
        errdefer std.debug.print("Rename recovery fault={s}\n", .{@tagName(fault)});
        var fixture: Fixture = .{};
        fixture.init();
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        page.panel.selected = 7;
        try press(&page, &ctx, vaxis.Key.enter);
        try press(&page, &ctx, vaxis.Key.left);
        const spaces = @as([status.max_label_bytes + 1]u8, @splat(' '));
        switch (fault) {
            .typed_overflow => try typeText(&page, &ctx, &spaces),
            .invalid_utf8 => try typeText(&page, &ctx, "\xff"),
            .invalid_scalar => try typeText(&page, &ctx, "z\x01"),
            .edit_rejected => {
                page.rename_editor.setCursor(0);
                try typeText(&page, &ctx, "\u{301}");
            },
            .unbound => try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'u', .mods = .{ .alt = true } } }),
            .paste_overflow, .invalid_paste, .paste_edit_rejected => {
                try page.widget().handleEvent(&ctx, .paste_start);
                try typeText(&page, &ctx, switch (fault) {
                    .paste_overflow => &spaces,
                    .invalid_paste => "\xff",
                    .paste_edit_rejected => "ok\n\u{301}",
                    else => unreachable,
                });
                try page.widget().handleEvent(&ctx, .paste_end);
                if (fault == .paste_overflow) try std.testing.expectEqualStrings(page.title(), page.rename_editor.text());
            },
        }
        const retained = try arena.allocator().dupe(u8, page.rename_editor.text());
        const caret = page.rename_editor.cursor();
        if (page.rename_editor.rejected != null) try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.renaming);
        try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
        try std.testing.expectEqualStrings(retained, page.rename_editor.text());
        try std.testing.expectEqual(caret, page.rename_editor.cursor());
        try std.testing.expect(page.rename_editor.rejected == null);
        try std.testing.expectEqual(@as(u3, 0), page.rename_editor.area.partial_length);
        try std.testing.expect(!page.rename_editor.pasting());
        for ([_]u16{ 99, 46 }) |width| {
            try std.testing.expect(std.mem.indexOf(u8, try dump(&page, arena.allocator(), width, 12), "couldn't be entered") != null);
        }
        if (caret == 0) try press(&page, &ctx, vaxis.Key.right);
        try press(&page, &ctx, vaxis.Key.backspace);
        try std.testing.expectEqual(retained.len - 1, page.rename_editor.text().len);
        try typeText(&page, &ctx, "X");
        const corrected = try arena.allocator().dupe(u8, page.rename_editor.text());
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(!page.renaming);
        try std.testing.expectEqualStrings(corrected, fixture.edit.?.label);
        try std.testing.expectEqual(@as(?[]const u8, null), page.failures[rename_row]);
    }
}

test "Chat info natural body matches the mock grows by actual Model rows and shrinks on filtering or cancel" {
    const picker = @import("model_picker.zig");
    const entries = comptime blk: {
        var result: [10]picker.Entry = undefined;
        for (&result, 0..) |*entry, index| entry.* = .{ .id = std.fmt.comptimePrint("model-{d}", .{index}), .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) };
        break :blk result;
    };
    const menu: picker.Menu = .{ .entries = &entries };
    for ([_]bool{ false, true }) |context| for ([_]bool{ false, true }) |unicode| for ([_]u16{ 46, 99 }) |width| {
        var fixture: Fixture = .{ .unicode = unicode };
        fixture.init();
        if (!context) fixture.session.context_estimate = null;
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 40 }, .cell_size = .{} };
        const base_height: u16 = if (context) 9 else 8;
        const body = try page.bodyWidget().draw(ctx);
        try std.testing.expectEqual(base_height, body.size.height);
        const complete = try page.widget().draw(ctx);
        try std.testing.expectEqual(base_height + 2, complete.size.height);
        try std.testing.expectEqual(@as(i17, base_height + 1), complete.children[1].origin.row);
        const text = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 40);
        try std.testing.expect(std.mem.endsWith(u8, text, "   Rename     Archive     Copy last answer\n\n"));
        page.panel.selected = 4;
        page.model_choice.open(&menu, provider_route.nameOf(.codex), "model-0");
        const all = try page.bodyWidget().draw(ctx);
        try std.testing.expectEqual(base_height + 8, all.size.height);
        try std.testing.expectEqual(@as(u16, 8), page.panel.custom_height);
        try std.testing.expectEqual(@as(u16, 4), all.cursor.?.row);
        try std.testing.expectEqual(@as(usize, 7), page.model_choice.hits.len);
        try typeText(&page, &events, "9");
        const narrowed = try page.bodyWidget().draw(ctx);
        try std.testing.expectEqual(base_height + 1, narrowed.size.height);
        try std.testing.expectEqual(@as(u16, 1), page.panel.custom_height);
        try std.testing.expectEqual(@as(usize, 1), page.model_choice.hits.len);
        try std.testing.expectEqual(@as(u16, 4), narrowed.cursor.?.row);
        try std.testing.expectEqual(@as(u16, 20), narrowed.cursor.?.col);
        const narrowed_text = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 40);
        try std.testing.expect(std.mem.indexOf(u8, narrowed_text, "model-9") != null);
        try std.testing.expect(std.mem.indexOf(u8, narrowed_text, "Filter:") == null);
        try press(&page, &events, vaxis.Key.escape);
        try std.testing.expectEqual(base_height, (try page.bodyWidget().draw(ctx)).size.height);
        page.failures[archive_row] = " · couldn't archive";
        page.failures[copy_row] = " · couldn't copy";
        const failed = try page.bodyWidget().draw(ctx);
        try std.testing.expectEqual(base_height + @as(u16, if (width == 46) 2 else 0), failed.size.height);
        try std.testing.expectEqual(width == 46, page.panel.stacked_actions);
    };
}

test "Chat info hover follows editable fields and action click regions without changing selection" {
    for ([_]u16{ 46, 99 }) |width| {
        var fixture: Fixture = .{};
        fixture.init();
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 12 }, .cell_size = .{} };
        _ = try page.widget().draw(draw_ctx);
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        try page.widget().handleEvent(&events, .mouse_enter);
        var shown: usize = 0;
        for (0..page.fields.len) |index| {
            if (!page.fields[index].visible) continue;
            defer shown += 1;
            const selectable = index != 3 and index != context_row;
            const mouse: vaxis.Mouse = .{ .col = @intCast(width - 1), .row = @intCast(1 + shown), .button = .none, .type = .motion, .mods = .{} };
            try page.widget().handleEvent(&events, .{ .mouse = mouse });
            const drawn = try page.widget().draw(draw_ctx);
            try std.testing.expectEqual(selectable, page.panel.hover.pointing);
            try std.testing.expectEqual(if (index == 0) page.panel.selection else if (selectable) page.panel.hover_style else page.panel.ground, drawn.children[0].surface.readCell(width - 1, @intCast(1 + shown)).style);
            try std.testing.expectEqual(@as(usize, 0), page.panel.selected);
            try std.testing.expectEqual(@as(?Edit, null), fixture.edit);
        }
        for ([_]u16{ 3, 14, 26 }) |col| {
            try page.widget().handleEvent(&events, .{ .mouse = .{ .col = @intCast(col), .row = 8, .button = .none, .type = .motion, .mods = .{} } });
            const drawn = try page.widget().draw(draw_ctx);
            try std.testing.expectEqual(page.panel.hover_style, drawn.children[0].surface.readCell(col, 8).style);
            try std.testing.expect(page.panel.hover.pointing);
            try std.testing.expectEqual(@as(usize, 0), page.panel.selected);
        }
        try page.widget().handleEvent(&events, .mouse_leave);
        try std.testing.expect(!page.panel.hover.pointing);
        for (events.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
        try page.widget().handleEvent(&events, .{ .mouse = .{ .col = @intCast(width - 1), .row = 2, .button = .left, .type = .press, .mods = .{} } });
        try std.testing.expectEqual(@as(usize, 1), page.panel.choice.?.field);
        _ = try page.widget().draw(draw_ctx);
        try page.widget().handleEvent(&events, .{ .mouse = .{ .col = @intCast(width - 1), .row = 3, .button = .left, .type = .press, .mods = .{} } });
        try std.testing.expectEqual(@as(@FieldType(status.Session, "permission"), .bypass), fixture.edit.?.permission);
    }
}

test "Chat info standalone choices reuse edits hide pending preserve failures and close success" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.openStandaloneChoice(&ctx, .effort);
    try std.testing.expect(page.standaloneOpen());
    try std.testing.expectEqual(Row.effort, page.standalone.?.row);
    const drawn = try page.standaloneWidget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 30 }, .cell_size = .{} });
    try std.testing.expectEqualStrings("E", drawn.readCell(1, 0).char.grapheme);
    try std.testing.expectEqual(@as(u16, @intCast(1 + page.effort_count)), drawn.size.height);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expect(!page.hasChoice());
    try std.testing.expect(!page.standaloneOpen());
    try std.testing.expectEqual(@as(?usize, 0), page.pending);
    try page.openStandaloneChoice(&ctx, .model);
    try std.testing.expectEqual(Row.effort, page.standalone.?.row);
    fixture.state_value = .failed;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(page.standaloneOpen());
    try std.testing.expectEqualStrings(" · couldn't save", page.failures[0].?);
    page.closeStandaloneChoice();
    try std.testing.expect(!page.standaloneOpen());
    try page.openStandaloneChoice(&ctx, .model);
    try std.testing.expect(page.model_choice.active);
    for ([_]u16{ 0, 1, 2, 46, 140 }) |width| for (0..12) |height| {
        const model_surface = try page.standaloneWidget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = @intCast(height) }, .cell_size = .{} });
        try std.testing.expect(model_surface.size.height <= height);
        for (model_surface.children) |child| {
            try std.testing.expect(child.origin.row + child.surface.size.height <= model_surface.size.height);
            try std.testing.expect(child.origin.col + child.surface.size.width <= model_surface.size.width);
        }
    };
    try std.testing.expect(!page.model_choice.show_more);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(!page.standaloneOpen());
    try std.testing.expect(page.standalone == null);
    try page.openStandaloneChoice(&ctx, .effort);
    page.refresh();
    try std.testing.expect(!page.standaloneOpen());
    page.bind();
    try std.testing.expect(page.model_choice.show_more);
}

test "Chat info standalone draw invalidation never falls through to enclosing page" {
    const Live = struct {
        fn read(raw: *anyopaque) ModelChoice.Snapshot {
            const revision: *u64 = @ptrCast(@alignCast(raw));
            return .{ .revision = revision.* };
        }
    };
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 30 }, .cell_size = .{} };
    try page.openStandaloneChoice(&events, .model);
    var revision: u64 = 0;
    page.model_choice.source = .{ .context = &revision, .read = Live.read };
    page.model_choice.revision = revision;
    _ = try page.standaloneWidget().draw(ctx);
    revision += 1;
    const closed = try page.standaloneWidget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 0), closed.size.height);
    try std.testing.expectEqual(@as(usize, 0), closed.buffer.len);
    try std.testing.expectEqual(@as(usize, 0), closed.children.len);
    try std.testing.expect(!page.standaloneOpen());
    try page.openStandaloneChoice(&events, .effort);
    try page.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    const pending = try page.standaloneWidget().draw(ctx);
    try std.testing.expectEqual(@as(u16, 0), pending.size.height);
}

test "Chat info standalone effort checks the actual Session effort without changing full-page override semantics" {
    for ([_]bool{ false, true }) |explicit| for ([_]?catalog.ReasoningEffort{ .high, .low, null }) |effort| {
        var fixture: Fixture = .{};
        fixture.init();
        try fixture.session.model.set("azure/gpt-5-pro");
        fixture.session.effort = effort;
        fixture.session.effort_override = explicit;
        var page: Self = .{ .backend = fixture.backend() };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        page.refresh();
        try press(&page, &ctx, vaxis.Key.enter);
        const actual: ?usize = if (effort == null) 0 else if (effort == .high) 1 else null;
        try std.testing.expectEqual(if (!explicit) @as(?usize, 0) else actual, page.panel.choice.?.current);
        page.cancelChoice();
        try page.openStandaloneChoice(&ctx, .effort);
        try std.testing.expectEqual(@as(usize, 2), page.effort_count);
        try std.testing.expectEqualStrings("model default", page.effort_labels[0]);
        try std.testing.expectEqualStrings("high", page.effort_labels[1]);
        try std.testing.expectEqual(actual, page.panel.choice.?.current);
        for ([_]u16{ 46, 140 }) |width| {
            const drawn = try page.standaloneWidget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
            for (0..page.effort_count) |row| try std.testing.expectEqualStrings(if (actual == row) "✓" else " ", drawn.readCell(3, @intCast(row + 1)).char.grapheme);
        }
    };
}

test "SUI-136 an unconfirmed choice opens a new edit instead of retrying" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.openStandaloneChoice(&ctx, .effort);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.save_calls);
    fixture.state_value = .unconfirmed;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(page.standaloneUnconfirmed() and !page.hasChoice());
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.hasChoice());
    try std.testing.expectEqual(@as(usize, 1), fixture.save_calls);
}

test "SUI-136 field notices clear only for the observed Configure key" {
    const a: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const b: [36]u8 = "01234567-89ab-4cde-8012-0123456789ac".*;
    const store = try @import("bounded.zig").Bounded(@import("store_path.zig").max_bytes).from("/store-a");
    const original_a: @import("configure_outcome.zig").Original = .{ .key = a, .store = store };
    const original_b: @import("configure_outcome.zig").Original = .{ .key = b, .store = store };
    const other_store = try @import("bounded.zig").Bounded(@import("store_path.zig").max_bytes).from("/store-b");
    const same_key_other_store: @import("configure_outcome.zig").Original = .{ .key = a, .store = other_store };
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.unconfirmed_keys[0] = original_a;
    page.unconfirmed_keys[1] = original_b;
    page.unconfirmed_keys[2] = same_key_other_store;
    page.failures[2] = " · not confirmed · /requests";
    page.failures[0] = " · not confirmed · /requests";
    page.failures[1] = " · not confirmed · /requests";
    page.clearUnconfirmed(original_a);
    try std.testing.expect(page.failures[0] == null and page.unconfirmed_keys[0] == null);
    try std.testing.expectEqual(b, page.unconfirmed_keys[1].?.key);
    try std.testing.expectEqualStrings(" · not confirmed · /requests", page.failures[1].?);
    try std.testing.expectEqual(a, page.unconfirmed_keys[2].?.key);
    try std.testing.expect(page.unconfirmed_keys[2].?.store.eql("/store-b"));
}

test "Chat info standalone failure retry preserves field-only presentation and the actual effort check" {
    var fixture: Fixture = .{};
    fixture.init();
    try fixture.session.model.set("azure/gpt-5-pro");
    fixture.session.effort = .high;
    fixture.session.effort_override = false;
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.openStandaloneChoice(&ctx, .effort);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(Edit{ .effort = .high }, fixture.edit.?);
    fixture.state_value = .failed;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(page.standaloneOpen());
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(Row.effort, page.standalone.?.row);
    try std.testing.expectEqual(Row.effort, page.standalone.?.row);
    try std.testing.expectEqual(@as(?usize, 1), page.panel.choice.?.current);
    try press(&page, &ctx, vaxis.Key.enter);
    fixture.state_value = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(!page.standaloneOpen() and page.standalone == null);
    try page.openStandaloneChoice(&ctx, .effort);
    page.refresh();
    try std.testing.expect(!page.standaloneOpen());
}

test "Chat info standalone Model and Effort retry read and save failures by drawn click or Enter" {
    const Failure = enum { read, save, publication };
    for ([_]Row{ .model, .effort }) |field| for (std.enums.values(Failure)) |failure| for ([_]bool{ false, true }) |pointer| for ([_]u16{ 46, 140 }) |width| {
        errdefer std.debug.print("Chat standalone field={s} failure={s} pointer={} width={d}\n", .{ @tagName(field), @tagName(failure), pointer, width });
        var fixture: Fixture = .{ .fail_read = failure == .read };
        fixture.init();
        fixture.session.effort_override = false;
        var page: Self = .{ .backend = fixture.backend() };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} };
        const click: vaxis.Mouse = .{ .col = 1, .row = 1, .button = .left, .type = .press, .mods = .{} };
        const index: usize = if (field == .model) 4 else 0;
        try page.openStandaloneChoice(&ctx, field);
        if (failure != .read) {
            fixture.fail_submit = failure == .publication;
            try press(&page, &ctx, vaxis.Key.enter);
            fixture.fail_submit = false;
            if (failure == .save) {
                try std.testing.expect(!page.standaloneOpen());
                try std.testing.expectEqual(Phase.pending, page.standalone.?.phase);
                const pending = try page.standaloneWidget().draw(draw_ctx);
                try std.testing.expectEqual(@as(u16, 0), pending.size.height);
                const reads = fixture.read_calls;
                const saves = fixture.save_calls;
                try @import("testing/app_events.zig").mouse(&ctx, pending, click);
                try press(&page, &ctx, vaxis.Key.enter);
                try std.testing.expectEqual(reads, fixture.read_calls);
                try std.testing.expectEqual(saves, fixture.save_calls);
                fixture.state_value = .failed;
                try page.widget().handleEvent(&ctx, .tick);
            }
        }
        try std.testing.expect(page.standaloneOpen() and !page.hasChoice());
        try std.testing.expectEqual(Phase.failed, page.standalone.?.phase);
        try std.testing.expectEqualStrings(if (failure == .read) " · couldn't read chat" else " · couldn't save", page.failures[index].?);
        const retained = try page.standaloneWidget().draw(draw_ctx);
        try std.testing.expectEqual(@as(u16, 2), retained.size.height);
        try std.testing.expect(!std.mem.eql(u8, " ", retained.readCell(3, 1).char.grapheme));
        fixture.fail_read = false;
        const before_read = fixture.read_calls;
        const before_save = fixture.save_calls;
        if (pointer) try @import("testing/app_events.zig").mouse(&ctx, retained, click) else try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqual(before_read + 1, fixture.read_calls);
        try std.testing.expectEqual(before_save, fixture.save_calls);
        try std.testing.expect(page.standaloneOpen() and page.hasChoice());
        try std.testing.expectEqual(field, page.standalone.?.row);
        try std.testing.expect(page.failures[index] == null);
        if (field == .model) {
            try std.testing.expect(page.model_choice.active);
            try std.testing.expect(page.model_choice.provider.eql(fixture.session.provider));
            try std.testing.expectEqualStrings(fixture.session.model.slice(), page.model_choice.current);
        } else {
            const choice = page.panel.choice.?;
            try std.testing.expectEqualStrings("high", choice.labels[choice.current.?]);
        }
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqual(before_save + 1, fixture.save_calls);
        if (field == .model) try std.testing.expectEqualStrings(fixture.session.model.slice(), fixture.edit.?.model) else try std.testing.expectEqual(Edit{ .effort = .high }, fixture.edit.?);
        fixture.state_value = .saved;
        try page.widget().handleEvent(&ctx, .tick);
        const saved = try page.standaloneWidget().draw(draw_ctx);
        try std.testing.expectEqual(@as(u16, 0), saved.size.height);
        const saves = fixture.save_calls;
        try @import("testing/app_events.zig").mouse(&ctx, saved, click);
        try std.testing.expectEqual(saves, fixture.save_calls);
        try std.testing.expect(!page.standaloneOpen());
    };
}

test "Chat info standalone lifetime domain closes every phase without cancelling admitted work or reopening late" {
    const Cases = @import("session_chrome.zig").StandaloneCases;
    const Outcome = enum { saved, failed, unread };
    for (Cases.all) |case| {
        if (case.screen != .chat) continue;
        for (std.enums.values(Outcome)) |outcome| {
            var fixture: Fixture = .{ .fail_read = case.phase == .read_failed };
            fixture.init();
            var page: Self = .{ .backend = fixture.backend() };
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            const row: Row = if (case.field == .model) .model else .effort;
            const index: usize = if (row == .model) 4 else 0;
            try page.openStandaloneChoice(&ctx, row);
            if (case.phase == .pending or case.phase == .save_failed) {
                try press(&page, &ctx, vaxis.Key.enter);
                if (case.phase == .save_failed) {
                    fixture.state_value = .failed;
                    try page.widget().handleEvent(&ctx, .tick);
                }
            }
            const phase: Phase = switch (case.phase) {
                .open => .open,
                .pending => .pending,
                .read_failed, .save_failed => .failed,
            };
            try std.testing.expectEqual(@as(?Row, row), page.standaloneField());
            try std.testing.expectEqual(phase, page.standalone.?.phase);
            try std.testing.expectEqual(case.phase != .pending, page.standaloneOpen());
            const admitted = page.pending;
            switch (case.ending) {
                .refresh => page.refresh(),
                .escape, .close_click, .navigate => page.closeStandaloneChoice(),
            }
            try std.testing.expect(!page.standaloneOpen());
            try std.testing.expect(page.standaloneField() == null);
            try std.testing.expect(page.standalone == null);
            try std.testing.expectEqual(admitted, page.pending);
            try std.testing.expect(!page.hasChoice());
            if (admitted != null) {
                fixture.fail_read = outcome == .unread;
                fixture.state_value = if (outcome == .failed) .failed else .saved;
                const reads = fixture.read_calls;
                try page.standaloneWidget().handleEvent(&ctx, .tick);
                try std.testing.expectEqual(reads + 1, fixture.read_calls);
                try std.testing.expect(page.pending == null);
                if (outcome != .saved) try std.testing.expect(page.failures[index] != null);
            }
            try std.testing.expect(page.standaloneField() == null);
            try std.testing.expect(!page.standaloneOpen());
            const surface = try page.standaloneWidget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 20 }, .cell_size = .{} });
            try std.testing.expectEqual(@as(u16, 0), surface.size.height);
            try std.testing.expectEqual(@as(usize, 0), surface.buffer.len);
            try std.testing.expectEqual(@as(usize, 0), surface.children.len);
            const reads = fixture.read_calls;
            const saves = fixture.save_calls;
            try page.standaloneWidget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
            try page.standaloneWidget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'x', .text = "x" } });
            try page.standaloneWidget().handleEvent(&ctx, .{ .mouse = .{ .col = 1, .row = 1, .button = .left, .type = .press, .mods = .{} } });
            try std.testing.expectEqual(reads, fixture.read_calls);
            try std.testing.expectEqual(saves, fixture.save_calls);
            try std.testing.expect(page.standaloneField() == null);
            page.bind();
            try std.testing.expect(page.model_choice.show_more);
        }
    }
}

test "Chat info copy label follows successful short reply dismissal replacement and failure" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 140, 46 }) |width| {
        page.panel.selected = 9;
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqual(@as(?usize, 9), page.pending);
        try std.testing.expect(std.mem.indexOf(u8, try dump(&page, arena.allocator(), width, 15), "Copied") == null);
        fixture.copy_notice.showCopy(0, .panel_copy);
        fixture.state_value = .saved;
        try page.widget().handleEvent(&ctx, .tick);
        const copied = try dump(&page, arena.allocator(), width, 15);
        try std.testing.expect(std.mem.indexOf(u8, copied, "Rename     Archive     Copied") != null);
        try std.testing.expect(std.mem.indexOf(u8, copied, "Copy last answer") == null);
        try std.testing.expect(!page.panel.stacked_actions);
        try std.testing.expectEqual(@as(usize, "Copy last answer".len), page.panel.actions[2].len);
        fixture.copy_notice.dismiss();
        try press(&page, &ctx, vaxis.Key.left);
        try std.testing.expect(std.mem.indexOf(u8, try dump(&page, arena.allocator(), width, 15), "Copy last answer") != null);
        fixture.copy_notice.showCopy(0, .panel_copy);
        fixture.copy_notice.show(@import("marks.zig").Say.quiet("another reply"), 0);
        try std.testing.expect(std.mem.indexOf(u8, try dump(&page, arena.allocator(), width, 15), "Copied") == null);
        page.panel.selected = 9;
        try press(&page, &ctx, vaxis.Key.enter);
        fixture.state_value = .failed;
        try page.widget().handleEvent(&ctx, .tick);
        const failed = try dump(&page, arena.allocator(), width, 15);
        try std.testing.expect(std.mem.indexOf(u8, failed, "Copy: couldn't copy") != null);
        try std.testing.expect(std.mem.indexOf(u8, failed, "Copied") == null);
        fixture.fail_submit = true;
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(std.mem.indexOf(u8, try dump(&page, arena.allocator(), width, 15), "Copied") == null);
        fixture.fail_submit = false;
    }
}

test "Chat info routes horizontal and forward reverse Tab without opening choices" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    page.panel.selected = 4;
    try press(&page, &ctx, vaxis.Key.down);
    try press(&page, &ctx, vaxis.Key.right);
    try std.testing.expectEqual(@as(usize, 8), page.panel.selected);
    // Tab is defined only over the controls actually drawn this frame.
    _ = try dumpWidget(page.bodyWidget(), arena.allocator(), 99, 20);
    try press(&page, &ctx, vaxis.Key.tab);
    try std.testing.expectEqual(@as(usize, 9), page.panel.selected);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } } });
    try std.testing.expectEqual(@as(usize, 8), page.panel.selected);
    try std.testing.expect(!page.hasChoice());
}

test "Chat info focus consumes drawn action layout across pending failures and Context visibility" {
    for ([_]?u64{ null, 18 }) |context| for ([_]u16{ 46, 99 }) |width| for ([_]bool{ false, true }) |archive_failed| for ([_]bool{ false, true }) |copy_pending| {
        var fixture: Fixture = .{};
        fixture.init();
        fixture.session.context_estimate = context;
        fixture.state_value = .pending;
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        page.failures[archive_row] = if (archive_failed) " · couldn't archive" else null;
        page.pending = if (copy_pending) 9 else null;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        _ = try dumpWidget(page.bodyWidget(), arena.allocator(), width, 20);
        const stacked = page.panel.stacked_actions;
        try std.testing.expectEqual(width == 46 and archive_failed, stacked);
        page.panel.selected = 7;
        try press(&page, &ctx, vaxis.Key.down);
        try std.testing.expectEqual(@as(usize, if (stacked) 8 else 7), page.panel.selected);
        page.panel.selected = 7;
        try press(&page, &ctx, vaxis.Key.right);
        try std.testing.expectEqual(@as(usize, if (stacked) 7 else 8), page.panel.selected);
        page.panel.selected = 9;
        try press(&page, &ctx, vaxis.Key.up);
        try std.testing.expectEqual(@as(usize, if (stacked) 8 else 4), page.panel.selected);
        page.panel.selected = 4;
        try press(&page, &ctx, vaxis.Key.tab);
        try std.testing.expectEqual(@as(usize, 7), page.panel.selected);
    };
}

test "Chat info contains only chat settings and never an app Memory row" {
    var fixture: Fixture = .{};
    fixture.init();
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]?u64{ null, 18 }) |context| for ([_]u16{ 46, 99 }) |width| {
        fixture.session.context_estimate = context;
        page.refresh();
        const text = try dump(&page, arena.allocator(), width, 20);
        try std.testing.expect(std.mem.indexOf(u8, text, "Memory") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Permissions") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Copy last answer") != null);
        try std.testing.expectEqual(@as(usize, 7), page.fields.len);
        _ = arena.reset(.retain_capacity);
    };
}

test "Chat info allowed picker retains MCP names on no-op cancellation and built-in edits" {
    for ([_]u16{ 140, 46 }) |width| for ([_]enum { noop, cancel, remove_bash, add_message_agent }{ .noop, .cancel, .remove_bash, .add_message_agent }) |mode| {
        var fixture: Fixture = .{};
        fixture.init();
        fixture.session.tools = try .of(&.{ "bash", "find_tools", "lookup", "none" });
        fixture.session.loaded_tools = try .of(&.{ "find_tools", "none" });
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        _ = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 30 }, .cell_size = .{} });
        try std.testing.expectEqualStrings("Allowed tools", page.fields[2].label);
        try std.testing.expectEqualStrings(if (width == 140) "bash, find_tools, lookup, none" else "bash, find_tools, lookup…", page.fields[2].value);
        page.panel.selected = 2;
        try press(&page, &ctx, vaxis.Key.enter);
        if (mode == .add_message_agent) {
            try press(&page, &ctx, vaxis.Key.down);
            try press(&page, &ctx, vaxis.Key.down);
        }
        if (mode != .noop) try press(&page, &ctx, ' ');
        try press(&page, &ctx, if (mode == .cancel) vaxis.Key.escape else vaxis.Key.enter);
        try std.testing.expectEqualStrings("bash find_tools lookup none", page.session.tools.names.slice());
        try std.testing.expectEqualStrings("find_tools none", page.session.loaded_tools.names.slice());
        if (mode == .cancel) {
            try std.testing.expect(fixture.edit == null);
        } else {
            const expected = switch (mode) {
                .noop => "bash find_tools lookup none",
                .remove_bash => "find_tools lookup none",
                .add_message_agent => "bash find_tools lookup message_agent none",
                .cancel => unreachable,
            };
            try std.testing.expectEqualStrings(expected, fixture.edit.?.tools.allowed.names.slice());
            try std.testing.expectEqualStrings("find_tools none", fixture.edit.?.tools.loaded.names.slice());
        }
    };
}

test "Chat info distinguishes empty allowed intent from an MCP tool named none" {
    for ([_]bool{ false, true }) |singleton| {
        var fixture: Fixture = .{};
        fixture.init();
        fixture.session.tools = try .of(if (singleton) &.{"none"} else &.{});
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        _ = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 30 }, .cell_size = .{} });
        try std.testing.expectEqualStrings(if (singleton) "none" else "no tools", page.fields[2].value);
    }
}

test "Chat info explains invalid loaded membership on the allowed tools row" {
    var fixture: Fixture = .{};
    fixture.init();
    fixture.session.tools = try .of(&.{"bash"});
    fixture.session.loaded_tools = try .of(&.{"web_search"});
    var page: Self = .{ .backend = fixture.backend() };
    page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    page.panel.selected = 2;
    try press(&page, &ctx, vaxis.Key.enter);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings(" · loaded tools aren't allowed", page.failures[2].?);
    try std.testing.expect(fixture.edit == null);
}

test "SUI-4 Chat info tools rejection reopens saved intent and accepts retry at both widths" {
    const cases = [_]struct {
        allowed: []const []const u8,
        loaded: []const []const u8,
        down: usize,
        rejected_allowed: []const u8,
        rejected_loaded: []const u8,
        saved_allowed: []const u8,
        saved_loaded: []const u8,
    }{
        .{ .allowed = &.{ "bash", "find_tools", "lookup" }, .loaded = &.{ "bash", "find_tools" }, .down = 1, .rejected_allowed = "bash lookup", .rejected_loaded = "bash", .saved_allowed = "bash find_tools lookup", .saved_loaded = "bash find_tools" },
        .{ .allowed = &.{"bash"}, .loaded = &.{"bash"}, .down = 2, .rejected_allowed = "bash message_agent", .rejected_loaded = "bash", .saved_allowed = "bash", .saved_loaded = "bash" },
        .{ .allowed = &.{}, .loaded = &.{}, .down = 0, .rejected_allowed = "bash", .rejected_loaded = "", .saved_allowed = "", .saved_loaded = "" },
    };
    for ([_]u16{ 140, 46 }) |width| for (cases) |case| {
        var fixture: Fixture = .{};
        fixture.init();
        fixture.session.tools = try .of(case.allowed);
        fixture.session.loaded_tools = try .of(case.loaded);
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        _ = try dump(&page, arena.allocator(), width, 30);
        page.panel.selected = 2;
        try press(&page, &ctx, vaxis.Key.enter);
        for (0..case.down) |_| try press(&page, &ctx, vaxis.Key.down);
        try press(&page, &ctx, ' ');
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqual(@as(usize, 1), fixture.save_calls);
        try std.testing.expectEqualStrings(case.rejected_allowed, fixture.edit.?.tools.allowed.names.slice());
        try std.testing.expectEqualStrings(case.rejected_loaded, fixture.edit.?.tools.loaded.names.slice());
        try std.testing.expectEqual(@as(?usize, 2), page.pending);
        fixture.state_value = .failed;
        try page.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqual(@as(?usize, null), page.pending);
        try std.testing.expectEqual(@as(usize, 2), page.panel.selected);
        try std.testing.expectEqualStrings(" · couldn't save", page.failures[2].?);
        const failed = try dump(&page, arena.allocator(), width, 30);
        try std.testing.expect(std.mem.indexOf(u8, failed, "couldn't save") != null);
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.hasChoice());
        try std.testing.expectEqualStrings(case.saved_allowed, page.session.tools.names.slice());
        try std.testing.expectEqualStrings(case.saved_loaded, page.session.loaded_tools.names.slice());
        const saved_selection = fixture.session.builtInTools();
        for (std.enums.values(tools.BuiltInTool)) |tool| {
            try std.testing.expectEqual(saved_selection.contains(tool), page.tool_draft.?.contains(tool));
        }
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqual(@as(usize, 2), fixture.save_calls);
        try std.testing.expectEqualStrings(case.saved_allowed, fixture.edit.?.tools.allowed.names.slice());
        try std.testing.expectEqualStrings(case.saved_loaded, fixture.edit.?.tools.loaded.names.slice());
        fixture.state_value = .saved;
        try page.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqual(@as(?usize, null), page.pending);
        try std.testing.expectEqual(@as(?[]const u8, null), page.failures[2]);
    };
}

test "SUI-4 Chat info saves explicit empty restricted and singleton MCP tools" {
    const cases = [_]struct { allowed: []const []const u8, loaded: []const []const u8, remove_bash: bool, expected: []const u8 }{
        .{ .allowed = &.{}, .loaded = &.{}, .remove_bash = false, .expected = "" },
        .{ .allowed = &.{"bash"}, .loaded = &.{"bash"}, .remove_bash = false, .expected = "bash" },
        .{ .allowed = &.{ "bash", "none" }, .loaded = &.{ "bash", "none" }, .remove_bash = true, .expected = "none" },
    };
    for ([_]u16{ 140, 46 }) |width| for (cases) |case| {
        var fixture: Fixture = .{};
        fixture.init();
        fixture.session.tools = try .of(case.allowed);
        fixture.session.loaded_tools = try .of(case.loaded);
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        _ = try dump(&page, arena.allocator(), width, 30);
        page.panel.selected = 2;
        try press(&page, &ctx, vaxis.Key.enter);
        if (case.remove_bash) try press(&page, &ctx, ' ');
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqual(@as(usize, 1), fixture.save_calls);
        try std.testing.expectEqualStrings(case.expected, fixture.edit.?.tools.allowed.names.slice());
        try std.testing.expectEqualStrings(case.expected, fixture.edit.?.tools.loaded.names.slice());
    };
}

test "SUI-4 Chat info permission wording follows mode across tool sets" {
    const sets = [_][]const []const u8{ &.{}, &.{"bash"}, &.{"web_search"}, &.{ "bash", "web_search" } };
    for ([_]u16{ 140, 46 }) |width| for ([_]@FieldType(status.Session, "permission"){ .ask, .bypass }) |mode| for (sets) |set| {
        var fixture: Fixture = .{};
        fixture.init();
        fixture.session.permission = mode;
        fixture.session.tools = try .of(set);
        fixture.session.loaded_tools = try .of(set);
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const text = try dump(&page, arena.allocator(), width, 30);
        try std.testing.expectEqualStrings(if (mode == .ask) "ask first" else "run without asking", page.fields[1].value);
        try std.testing.expect(std.mem.indexOf(u8, text, "Permissions") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (mode == .ask) "ask first" else "run without asking") != null);
        if (mode == .ask) try std.testing.expect(std.mem.indexOf(u8, text, "without asking") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Bash runs without") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Bash commands can run without asking you") == null);
    };
}

test "SUI-181 Chat info shows the Account row only with a second account and switches by choice" {
    const picker = @import("model_picker.zig");
    const codex = connection.Name.parse("codex").?;
    const work = connection.Name.parse("work").?;
    const alone: picker.Menu = .{ .entries = &.{.{ .id = "m", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{codex}) }} };
    const two: picker.Menu = .{ .entries = &.{.{ .id = "m", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&.{ codex, work }) }} };
    for ([_]?*const picker.Menu{ null, &alone, &two }, 0..) |menu, case| {
        var fixture: Fixture = .{};
        fixture.init();
        fixture.menu = menu;
        var page: Self = .{ .backend = fixture.backend() };
        page.refresh();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const text = try dump(&page, arena.allocator(), 99, 20);
        try std.testing.expectEqual(case == 2, std.mem.indexOf(u8, text, "Account") != null);
        try std.testing.expectEqual(case == 2, page.fields[account_row].visible);
        // A hidden row cannot be opened.
        page.panel.selected = account_row;
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqual(case == 2, page.hasChoice());
        if (case != 2) continue;
        try std.testing.expectEqualStrings("codex", page.fields[account_row].value);
        try std.testing.expectEqual(@as(usize, 2), page.panel.choice.?.labels.len);
        try std.testing.expectEqualStrings("codex", page.panel.choice.?.labels[0]);
        try std.testing.expectEqualStrings("work", page.panel.choice.?.labels[1]);
        // Choosing the chat's own connection saves nothing.
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqual(@as(usize, 0), fixture.save_calls);
        try std.testing.expect(page.pending == null);
        page.panel.selected = account_row;
        try press(&page, &ctx, vaxis.Key.enter);
        try press(&page, &ctx, vaxis.Key.down);
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expectEqualStrings("work", fixture.edit.?.connection);
        try std.testing.expectEqual(@as(?usize, account_row), page.pending);
        // A refusal from the Host stays on the row.
        fixture.state_value = .failed;
        try page.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqualStrings(" · couldn't save", page.failures[account_row].?);
        // Focus keys pass through the row between Model and the actions.
        page.panel.selected = model_row;
        try press(&page, &ctx, vaxis.Key.down);
        try std.testing.expectEqual(account_row, page.panel.selected);
        try press(&page, &ctx, vaxis.Key.down);
        try std.testing.expectEqual(rename_row, page.panel.selected);
    }
}
