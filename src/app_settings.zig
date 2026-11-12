//! App defaults presented as fields behind a borrowed, typed backend.
//! No preference writer or Upgrade worker lives here.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Panel = @import("widgets/Panel.zig");
const Footer = @import("widgets/Footer.zig");
const keys_panel = @import("keys_panel.zig");
const preferences = @import("preferences.zig");
const catalog = @import("model_catalog.zig");
const capability = @import("model_capability.zig");
const protocol = @import("protocol.zig");
const defaults = @import("product_defaults.zig");
const view = @import("overview_view.zig");
const widget_style = @import("widget_style.zig");
const upgrade_status = @import("upgrade_status.zig");
const Self = @This();

pub const SaveState = enum { idle, pending, saved, failed };

/// Borrowed for the page's lifetime. The backend owns save outcomes; pending
/// includes queued work, not just a currently running worker.
pub const Backend = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) anyerror!preferences.Values,
    save: *const fn (*anyopaque, preferences.Edit) anyerror!void,
    save_state: *const fn (*anyopaque) SaveState,
    upgrade: *const fn (*anyopaque) anyerror!void,
    run: *const fn (*anyopaque) ?upgrade_status.Run,
    caps: *const fn (*anyopaque) view.Caps,
    sign_in: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
};

/// The page's rows, in drawn order: the Panel's field index of each.
pub const Row = enum { model, effort, permissions, notifications, sign_in, version, keys };
const row_count = std.enums.values(Row).len;

backend: ?Backend = null,
narrow: bool = false,
keys_open: bool = false,
values: preferences.Values = .{},
read_failed: bool = false,
panel: Panel = .{ .title = "Rui" },
fields: [row_count]Panel.Field = undefined,
/// The row awaiting the backend's answer. Displayed values always come from
/// the saved file, including uncertain saves.
saving_row: ?Row = null,
failures: std.EnumArray(Row, ?[]const u8) = .initFill(null),
effort_choices: [std.enums.values(catalog.ReasoningEffort).len + 1][]const u8 = undefined,
effort_count: usize = 0,
/// Supplied by the application owner, not a dependency of UI-only roots.
version: []const u8 = "",
upgrade_buffer: [upgrade_status.max_line_bytes]u8 = undefined,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn hasChoice(self: *const Self) bool {
    return self.panel.choice != null;
}

pub fn cancelChoice(self: *Self) void {
    self.panel.closeChoice();
}

/// The page takes its panel's keys; every other key is the app's.
pub const takesKey = Panel.takesKey;

/// Esc is the Upgrade's while it can still change nothing, as on the
/// overview and in a conversation.
pub fn upgradeTakesEscape(self: *const Self) bool {
    const backend = self.backend orelse return false;
    const run = backend.run(backend.context) orelse return false;
    return run.takesEscape();
}

pub fn select(self: *Self, row: Row) void {
    self.panel.selected = @backingInt(row);
}

pub fn refresh(self: *Self) !void {
    // A choice is tied to the saved provider/model snapshot it opened on.
    // Refreshing (including failure) invalidates that choice, never its owner.
    self.cancelChoice();
    const backend = self.backend orelse {
        self.read_failed = true;
        self.failures.set(.model, " · settings unavailable");
        return;
    };
    const was_failed = self.read_failed;
    self.values = backend.read(backend.context) catch {
        self.read_failed = true;
        self.failures.set(.model, " · couldn't read settings");
        return;
    };
    self.read_failed = false;
    if (was_failed) self.failures.set(.model, null);
}

fn provider(self: *const Self) ?protocol.Provider {
    return std.meta.stringToEnum(protocol.Provider, if (self.values.provider.len == 0) defaults.provider else self.values.provider.slice());
}

fn model(self: *const Self) []const u8 {
    return if (self.values.model.len == 0) defaults.recommended_model else self.values.model.slice();
}

fn permissionMode(self: *const Self) protocol.PermissionMode {
    return self.values.permission_mode orelse std.meta.stringToEnum(protocol.PermissionMode, defaults.permission_mode).?;
}

fn permissionText(mode: protocol.PermissionMode) []const u8 {
    return switch (mode) {
        .bypass => "run without asking",
        .ask => "ask first",
    };
}

fn value(self: *const Self, row: Row) []const u8 {
    if (row == .keys) return "";
    if (row == .version) return self.version;
    if (self.read_failed) return "unavailable";
    return switch (row) {
        .model => self.model(),
        .effort => if (self.values.reasoning_effort) |effort| @tagName(effort) else "model default",
        .permissions => permissionText(self.permissionMode()),
        .notifications => if (self.values.notifications) "on" else "off",
        .sign_in => if (self.provider()) |saved| saved.signIn() else "unavailable",
        .version, .keys => unreachable,
    };
}

fn tail(self: *Self, row: Row) ?[]const u8 {
    if (self.saving_row == row) return " · saving";
    if (self.failures.get(row)) |failure| return failure;
    if (row != .version) return null;
    const backend = self.backend orelse return null;
    const run = backend.run(backend.context) orelse return null;
    return upgrade_status.fieldTail(run, &self.upgrade_buffer);
}

fn bind(self: *Self) void {
    self.panel.userdata = self;
    self.panel.on_activate = activate;
    self.panel.on_pick = pick;
    for (std.enums.values(Row)) |row| self.fields[@backingInt(row)] = .{
        .label = switch (row) {
            .model => "Model",
            .effort => "Effort",
            .permissions => "Permissions",
            .notifications => "Notifications",
            .sign_in => "Sign-in",
            .version => "Version",
            .keys => "Keys",
        },
        .value = self.value(row),
        .tail = self.tail(row),
    };
    self.panel.fields = &self.fields;
    const caps = if (self.backend) |b| b.caps(b.context) else view.Caps{};
    self.panel.ground = widget_style.of(caps, .{ .background = .bar });
    self.panel.selection = widget_style.of(caps, .{ .background = .selection });
    self.panel.hover_style = widget_style.of(caps, .{ .background = .hover });
    self.panel.title_style = widget_style.of(caps, .{ .background = .bar, .colour = .strong, .bold = true });
    self.panel.quiet = widget_style.of(caps, .{ .background = .bar, .colour = .quiet });
    self.panel.rule_style = widget_style.of(caps, .{ .background = .bar, .colour = .rule });
}

fn activate(raw: *anyopaque, ctx: *vxfw.EventContext, index: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const row: Row = @fromBackingInt(@intCast(index));
    if (row == .keys) {
        self.keys_open = true;
        ctx.consumeAndRedraw();
        return;
    }
    const backend = self.backend orelse return;
    if (self.saving_row != null) return;
    self.failures.set(row, null);
    switch (row) {
        .version => backend.upgrade(backend.context) catch {
            self.failures.set(.version, " · couldn't start upgrade");
        },
        .sign_in => {
            if (backend.sign_in) |open| open(backend.context, ctx) catch |err| {
                if (err != error.DefaultsUnavailable) return err;
                self.failures.set(.sign_in, " · settings busy");
            };
            return;
        },
        .keys => unreachable,
        .model, .effort, .permissions, .notifications => {
            try self.refresh();
            if (self.read_failed) return;
        },
    }
    switch (row) {
        .model => {
            if (self.provider() == null) {
                self.failures.set(.model, " · sign-in unavailable");
                return;
            }
            // Both supported sign-ins use the catalog's OpenAI chat models.
            // Account-specific Host discovery remains the overview picker's job.
            var current: ?usize = null;
            for (catalog.openai_ids, 0..) |id, at| if (std.mem.eql(u8, id, self.model())) {
                current = at;
                break;
            };
            self.panel.openChoice(&catalog.openai_ids, current);
        },
        .effort => {
            self.effort_choices[0] = "model default";
            self.effort_count = 1;
            var current: ?usize = if (self.values.reasoning_effort == null) 0 else null;
            for (std.enums.values(catalog.ReasoningEffort)) |effort| {
                if (!capability.supportsReasoningEffort(catalog.shipped, self.model(), effort)) continue;
                if (self.values.reasoning_effort == effort) current = self.effort_count;
                self.effort_choices[self.effort_count] = @tagName(effort);
                self.effort_count += 1;
            }
            self.panel.openChoice(self.effort_choices[0..self.effort_count], current);
        },
        .permissions => self.panel.openChoice(&.{ "run without asking", "ask first" }, if (self.permissionMode() == .bypass) 0 else 1),
        .notifications => try self.save(ctx, row, .{ .notifications = !self.values.notifications }),
        .sign_in, .version, .keys => {},
    }
    ctx.redraw = true;
}

fn pick(raw: *anyopaque, ctx: *vxfw.EventContext, field: usize, choice: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const row: Row = @fromBackingInt(@intCast(field));
    try self.save(ctx, row, switch (row) {
        .model => .{
            .provider = .{ .set = @tagName(self.provider().?) },
            .model = .{ .set = catalog.openai_ids[choice] },
        },
        .effort => .{
            .reasoning_effort = if (choice == 0) .clear else .{
                .set = std.meta.stringToEnum(catalog.ReasoningEffort, self.effort_choices[choice]).?,
            },
        },
        .permissions => .{ .permission_mode = .{ .set = if (choice == 0) .bypass else .ask } },
        // Only Model, Effort and Permissions open a choice.
        .notifications, .sign_in, .version, .keys => unreachable,
    });
}

fn save(self: *Self, ctx: *vxfw.EventContext, row: Row, edit: preferences.Edit) !void {
    const backend = self.backend.?;
    backend.save(backend.context, edit) catch {
        self.failures.set(row, " · couldn't save");
        ctx.redraw = true;
        return;
    };
    self.saving_row = row;
    try self.poll();
    ctx.redraw = true;
}

fn poll(self: *Self) !void {
    const backend = self.backend orelse return;
    const row = self.saving_row orelse return;
    const state = backend.save_state(backend.context);
    switch (state) {
        .idle, .pending => return,
        .saved, .failed => {},
    }
    try self.refresh();
    self.failures.set(row, if (state == .failed) " · couldn't save" else if (self.read_failed) " · couldn't read settings" else null);
    self.saving_row = null;
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (input == .tick) {
        const was_saving = self.saving_row != null;
        try self.poll();
        if (was_saving) ctx.redraw = true;
        return;
    }
    if (self.keys_open) return;
    self.bind();
    try self.panel.widget().handleEvent(ctx, input);
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.keys_open) {
        var reference = keys_panel.panel(if (self.backend) |backend| backend.caps(backend.context) else .{});
        var surface = try reference.widget().draw(ctx);
        // Settings retains focus and input ownership while the reference is drawn.
        surface.widget = self.widget();
        return surface;
    }
    self.bind();
    const size = ctx.max.size();
    if (size.width == 0 or size.height == 0) return .empty(self.widget());
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.panel.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - 1 })) };
    const footer = try ctx.arena.create(Footer);
    footer.* = .{
        .left = if (self.narrow) " ‹ Rui · settings" else " Rui · settings",
        .right = if (self.narrow) "esc close" else "↑↓ · enter change · esc close",
        .style = self.panel.quiet,
    };
    children[1] = .{ .origin = .{ .row = size.height - 1, .col = 0 }, .surface = try footer.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })) };
    return .{ .widget = self.widget(), .size = size, .buffer = &.{}, .children = children };
}

const Fixture = struct {
    values: preferences.Values = .{},
    save_status: SaveState = .idle,
    fail_read: bool = false,
    fail_save: bool = false,
    home: ?[]const u8 = null,
    upgrades: usize = 0,
    last_edit: ?preferences.Edit = null,
    status: ?upgrade_status.Run = .{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 60, .patch = 0 } }, .outcome = .unchanged } },

    fn backend(self: *Fixture) Backend {
        return .{ .context = self, .read = read, .save = saveEdit, .save_state = saveState, .upgrade = upgrade, .run = run, .caps = caps };
    }
    fn read(raw: *anyopaque) !preferences.Values {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail_read) return error.AccessDenied;
        return self.values;
    }
    fn saveEdit(raw: *anyopaque, edit: preferences.Edit) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.fail_save) return error.AccessDenied;
        self.last_edit = edit;
        if (self.home) |home| {
            self.values = try preferences.update(home, edit, &.initFill(.configured));
            self.save_status = .saved;
        } else self.save_status = .pending;
    }
    fn saveState(raw: *anyopaque) SaveState {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return self.save_status;
    }
    fn upgrade(raw: *anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.upgrades += 1;
        self.status = .checking;
    }
    fn run(raw: *anyopaque) ?upgrade_status.Run {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return self.status;
    }
    fn caps(_: *anyopaque) view.Caps {
        return .{};
    }
};

fn press(page: *Self, ctx: *vxfw.EventContext, codepoint: u21) !void {
    try page.widget().handleEvent(ctx, .{ .key_press = .{ .codepoint = codepoint } });
}

test "App settings choices submit typed edits and show saved values after the backend answers" {
    var fixture: Fixture = .{};
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.refresh();
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.hasChoice());
    const next = (page.panel.choice.?.selected + 1) % catalog.openai_ids.len;
    page.panel.choice.?.selected = next;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!page.hasChoice());
    const model_edit = fixture.last_edit.?;
    try std.testing.expectEqualStrings("codex", model_edit.provider.set);
    try std.testing.expectEqualStrings(catalog.openai_ids[next], model_edit.model.set);
    try std.testing.expectEqual(.keep, model_edit.store);
    try std.testing.expectEqual(.keep, model_edit.reasoning_effort);
    try std.testing.expectEqual(@as(?bool, null), model_edit.notifications);
    try std.testing.expectEqual(@as(?Row, .model), page.saving_row);
    page.bind();
    try std.testing.expectEqualStrings(" · saving", page.fields[@backingInt(Row.model)].tail.?);
    try fixture.values.model.set(catalog.openai_ids[next]);
    try fixture.values.provider.set("codex");
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(?Row, .model), page.saving_row);
    try std.testing.expectEqualStrings(defaults.recommended_model, page.model());
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(catalog.openai_ids[next], page.model());
    try std.testing.expectEqual(@as(?[]const u8, null), page.failures.get(.model));

    // Effort choices are the selected model's supported efforts, plus clearing.
    page.select(.effort);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings("model default", page.effort_choices[0]);
    for (page.effort_choices[1..page.effort_count]) |text| try std.testing.expect(capability.supportsReasoningEffort(catalog.shipped, page.model(), std.meta.stringToEnum(catalog.ReasoningEffort, text).?));
    try std.testing.expect(page.effort_count > 1);
    const chosen_effort = std.meta.stringToEnum(catalog.ReasoningEffort, page.effort_choices[1]).?;
    page.panel.choice.?.selected = 1;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(chosen_effort, fixture.last_edit.?.reasoning_effort.set);
    try std.testing.expectEqual(@as(?catalog.ReasoningEffort, null), page.values.reasoning_effort);
    fixture.values.reasoning_effort = chosen_effort;
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(chosen_effort, page.values.reasoning_effort.?);
    try press(&page, &ctx, vaxis.Key.enter);
    page.panel.choice.?.selected = 0;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(.clear, fixture.last_edit.?.reasoning_effort);
    try std.testing.expectEqual(.keep, fixture.last_edit.?.provider);
    try std.testing.expectEqual(.keep, fixture.last_edit.?.model);
    fixture.values.reasoning_effort = null;
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);

    page.select(.notifications);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?bool, false), fixture.last_edit.?.notifications);
    try std.testing.expect(page.values.notifications);
    fixture.values.notifications = false;
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(!page.values.notifications);

    // Read-only sign-in doesn't submit, while Version delegates to Upgrade.
    page.select(.sign_in);
    fixture.last_edit = null;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?preferences.Edit, null), fixture.last_edit);
    page.select(.version);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.upgrades);
    try std.testing.expectEqualStrings(upgrade_status.fieldTail(.checking, &page.upgrade_buffer), page.tail(.version).?);
}

test "App settings failures stay on the field and can recover" {
    var fixture: Fixture = .{};
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.refresh();
    page.select(.notifications);
    fixture.fail_save = true;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures.get(.notifications).?);
    try std.testing.expect(page.values.notifications);
    fixture.fail_save = false;
    try press(&page, &ctx, vaxis.Key.enter);
    // A failed backend answer is a row failure even if publication succeeded.
    fixture.values.notifications = false;
    fixture.save_status = .failed;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(page.failures.get(.notifications) != null);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures.get(.notifications).?);
    try std.testing.expect(!page.values.notifications);
    try std.testing.expectEqual(@as(?Row, null), page.saving_row);
    page.bind();
    try std.testing.expectEqualStrings(" · couldn't save", page.fields[@backingInt(Row.notifications)].tail.?);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures.get(.notifications).?);
    try press(&page, &ctx, vaxis.Key.enter);
    fixture.values.notifications = true;
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(?[]const u8, null), page.failures.get(.notifications));
    fixture.fail_read = true;
    try page.refresh();
    try std.testing.expect(page.read_failed);
    fixture.fail_read = false;
    try page.refresh();
    try std.testing.expect(!page.read_failed);
}

test "App settings completion uses the backend outcome and reports read failures on the edited row" {
    for ([_]SaveState{ .saved, .failed }) |state| {
        for ([_]bool{ false, true }) |fail_read| {
            var fixture: Fixture = .{};
            var page: Self = .{ .backend = fixture.backend() };
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            try page.refresh();
            page.select(.notifications);
            try press(&page, &ctx, vaxis.Key.enter);
            try std.testing.expectEqual(@as(?Row, .notifications), page.saving_row);
            fixture.save_status = state;
            fixture.fail_read = fail_read;
            // The saved file is authoritative for displayed values; the
            // backend's outcome, not a value comparison, decides success.
            try page.widget().handleEvent(&ctx, .tick);
            try std.testing.expectEqual(@as(?Row, null), page.saving_row);
            try std.testing.expectEqual(fail_read, page.read_failed);
            try std.testing.expect(page.values.notifications);
            const failure: ?[]const u8 = if (state == .failed) " · couldn't save" else if (fail_read) " · couldn't read settings" else null;
            if (failure) |text| {
                try std.testing.expectEqualStrings(text, page.failures.get(.notifications).?);
                page.bind();
                try std.testing.expectEqualStrings(text, page.fields[@backingInt(Row.notifications)].tail.?);
            } else {
                try std.testing.expectEqual(@as(?[]const u8, null), page.failures.get(.notifications));
            }
        }
    }
}

test "App settings page text and ground at 99x20 and 46x20" {
    var fixture: Fixture = .{};
    fixture.values.reasoning_effort = .low;
    const release_version = "0.60.0";
    var page: Self = .{ .backend = fixture.backend(), .version = release_version };
    try page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 99, 46 }) |width| {
        page.narrow = width == 46;
        const surface = try page.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
        var screen = try vaxis.Screen.init(arena.allocator(), .{ .cols = width, .rows = 20, .x_pixel = 0, .y_pixel = 0 });
        surface.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 20, .screen = &screen }, page.widget());
        var dump: std.Io.Writer.Allocating = .init(arena.allocator());
        for (0..20) |row| {
            var line: std.Io.Writer.Allocating = .init(arena.allocator());
            for (0..width) |col| try line.writer.writeAll(screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
            try dump.writer.writeAll(std.mem.trimEnd(u8, line.written(), " "));
            try dump.writer.writeByte('\n');
        }
        const text = dump.written();
        const model_row = try std.fmt.allocPrint(arena.allocator(), "   Model           {s}", .{defaults.recommended_model});
        try std.testing.expect(std.mem.indexOf(u8, text, model_row) != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Effort          low") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Permissions     run without asking") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Notifications   on") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Sign-in         ChatGPT") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Version         0.60.0 · up to date") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (page.narrow) " ‹ Rui · settings" else " Rui · settings") != null);
        const ground = widget_style.of(.{}, .{ .background = .bar });
        try std.testing.expectEqual(ground.bg, screen.readCell(0, 15).?.style.bg);
        try std.testing.expectEqual(widget_style.of(.{}, .{ .background = .selection }).bg, screen.readCell(0, 2).?.style.bg);
    }
}

test "App settings sign-in and effort choices reflect saved values without assuming a provider" {
    var fixture: Fixture = .{};
    try fixture.values.provider.set("openai");
    var page: Self = .{ .backend = fixture.backend() };
    try page.refresh();
    page.bind();
    try std.testing.expectEqualStrings("API key", page.fields[@backingInt(Row.sign_in)].value);
    try std.testing.expectEqualStrings("model default", page.fields[@backingInt(Row.effort)].value);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    page.select(.model);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.hasChoice());
    page.cancelChoice();
    // A formerly supported sign-in remains readable in preferences. It must
    // not become a different sign-in or a forced-unwrapped enum in this page.
    try fixture.values.provider.set("legacy");
    try page.refresh();
    page.bind();
    try std.testing.expectEqualStrings("unavailable", page.fields[@backingInt(Row.sign_in)].value);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!page.hasChoice());
    try std.testing.expectEqualStrings(" · sign-in unavailable", page.failures.get(.model).?);
    // A saved effort excluded by this model doesn't mark "model default" as
    // current: the page must not claim that an unsaved clearing already holds.
    for (catalog.shipped) |entry| if (entry.openai_listed and !entry.efforts.contains(.max)) {
        try fixture.values.model.set(entry.id);
        break;
    };
    fixture.values.reasoning_effort = .max;
    page.select(.effort);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?usize, null), page.panel.choice.?.current);
    page.cancelChoice();
}

test "App settings refresh invalidates choices tied to the old saved snapshot" {
    var fixture: Fixture = .{};
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.refresh();
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.hasChoice());
    try fixture.values.provider.set("legacy");
    try page.refresh();
    try std.testing.expect(!page.hasChoice());
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!page.hasChoice());
    try fixture.values.provider.set("codex");
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.hasChoice());
    fixture.fail_read = true;
    try page.refresh();
    try std.testing.expect(!page.hasChoice());
    try std.testing.expect(page.read_failed);
    try std.testing.expectEqual(@as(?preferences.Edit, null), fixture.last_edit);
}

test "App settings Permissions choices save both modes and display the saved words" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var fixture: Fixture = .{ .home = home };
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.refresh();
    page.bind();
    try std.testing.expectEqualStrings("Permissions", page.fields[@backingInt(Row.permissions)].label);
    try std.testing.expectEqualStrings(permissionText(std.meta.stringToEnum(protocol.PermissionMode, defaults.permission_mode).?), page.fields[@backingInt(Row.permissions)].value);
    page.select(.permissions);
    for ([_]protocol.PermissionMode{ .ask, .bypass }) |mode| {
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.hasChoice());
        try std.testing.expectEqual(@as(?usize, if (page.permissionMode() == .bypass) 0 else 1), page.panel.choice.?.current);
        try std.testing.expectEqualStrings("run without asking", page.panel.choice.?.labels[0]);
        try std.testing.expectEqualStrings("ask first", page.panel.choice.?.labels[1]);
        page.panel.choice.?.selected = if (mode == .bypass) 0 else 1;
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(!page.hasChoice());
        try std.testing.expectEqual(mode, fixture.last_edit.?.permission_mode.set);
        try std.testing.expectEqual(.keep, fixture.last_edit.?.model);
        try std.testing.expectEqual(.keep, fixture.last_edit.?.reasoning_effort);
        try std.testing.expectEqual(mode, (try preferences.load(home)).permission_mode.?);
        page.bind();
        try std.testing.expectEqualStrings(if (mode == .bypass) "run without asking" else "ask first", page.fields[@backingInt(Row.permissions)].value);
        try std.testing.expectEqual(@as(?Row, null), page.saving_row);
    }
}

test "App settings Sign-in row opens the shared sign-in screen on Enter" {
    const SignIn = struct {
        opens: usize = 0,
        busy: bool = false,
        fn open(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.busy) return error.DefaultsUnavailable;
            self.opens += 1;
        }
    };
    var owner: SignIn = .{};
    var fixture: Fixture = .{};
    var backend = fixture.backend();
    var page: Self = .{ .backend = backend };
    try page.refresh();
    // Other backend operations are not used by this row.
    backend.context = &owner;
    backend.sign_in = SignIn.open;
    page.backend = backend;
    page.select(.sign_in);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), owner.opens);
    try std.testing.expect(!page.hasChoice());
    owner.busy = true;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), owner.opens);
    try std.testing.expectEqualStrings(" · settings busy", page.failures.get(.sign_in).?);
}

test "App settings mouse hover and click use the same field choices as Enter" {
    for ([_]protocol.PermissionMode{ .ask, .bypass }) |initial| {
        var fixture: Fixture = .{ .values = .{ .permission_mode = initial } };
        var page: Self = .{ .backend = fixture.backend() };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 12 }, .cell_size = .{} };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        try page.refresh();
        _ = try page.widget().draw(draw_ctx);
        try page.widget().handleEvent(&events, .mouse_enter);
        const permissions_row = 2 + @backingInt(Row.permissions);
        var mouse: vaxis.Mouse = .{ .col = 1, .row = permissions_row, .button = .none, .type = .motion, .mods = .{} };
        try page.widget().handleEvent(&events, .{ .mouse = mouse });
        var surface = try page.widget().draw(draw_ctx);
        try std.testing.expectEqual(page.panel.hover_style.bg, surface.children[0].surface.readCell(1, permissions_row).style.bg);
        try std.testing.expectEqual(page.panel.selection.bg, surface.children[0].surface.readCell(1, 2).style.bg);
        try std.testing.expectEqual(@as(usize, 0), page.panel.selected);
        try std.testing.expectEqual(@as(?preferences.Edit, null), fixture.last_edit);
        try page.widget().handleEvent(&events, .mouse_leave);
        surface = try page.widget().draw(draw_ctx);
        try std.testing.expectEqual(page.panel.ground.bg, surface.children[0].surface.readCell(1, permissions_row).style.bg);
        mouse.button = .left;
        mouse.type = .press;
        try page.widget().handleEvent(&events, .{ .mouse = mouse });
        try std.testing.expectEqual(@as(usize, @backingInt(Row.permissions)), page.panel.choice.?.field);
        const selected = page.panel.choice.?.selected;
        const next: protocol.PermissionMode = if (initial == .ask) .bypass else .ask;
        const choice_row: u16 = permissions_row + 1 + @as(u16, if (next == .bypass) 0 else 1);
        _ = try page.widget().draw(draw_ctx);
        mouse.row = @intCast(choice_row);
        mouse.button = .none;
        mouse.type = .motion;
        try page.widget().handleEvent(&events, .mouse_enter);
        try page.widget().handleEvent(&events, .{ .mouse = mouse });
        surface = try page.widget().draw(draw_ctx);
        try std.testing.expectEqual(page.panel.hover_style.bg, surface.children[0].surface.readCell(1, choice_row).style.bg);
        try std.testing.expectEqual(selected, page.panel.choice.?.selected);
        mouse.button = .left;
        mouse.type = .press;
        try page.widget().handleEvent(&events, .{ .mouse = mouse });
        try std.testing.expectEqual(next, fixture.last_edit.?.permission_mode.set);
        try std.testing.expect(!page.hasChoice());
        try page.widget().handleEvent(&events, .mouse_leave);
    }
}

test "App settings Keys is last and opens by Enter or click without a backend" {
    try std.testing.expectEqual(row_count - 1, @as(usize, @backingInt(Row.keys)));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]u16{ 140, 46 }) |width| for ([_]bool{ false, true }) |click| {
        // The reference remains available when preferences cannot be read.
        var page: Self = .{};
        try page.refresh();
        page.bind();
        try std.testing.expectEqualStrings("Keys", page.fields[@backingInt(Row.keys)].label);
        try std.testing.expectEqualStrings("", page.fields[@backingInt(Row.keys)].value);
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        if (click) {
            _ = try page.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
            try page.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .row = 2 + @as(u16, @backingInt(Row.keys)), .col = 4, .mods = .{} } });
        } else {
            page.select(.keys);
            try press(&page, &ctx, vaxis.Key.enter);
        }
        try std.testing.expect(page.keys_open);
        try std.testing.expect(ctx.consume_event);
        const drawn = try page.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
        try std.testing.expectEqualStrings("e", drawn.readCell(1, 0).char.grapheme);
        try std.testing.expect(drawn.widget.eql(page.widget()));
        // Enter on a reference is inert, not a hidden settings edit.
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.keys_open);
        try std.testing.expect(page.saving_row == null);
    };
}
