//! App defaults presented as fields behind a borrowed, typed backend.
//! No preference writer or Upgrade worker lives here.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Panel = @import("widgets/Panel.zig");
const ModelChoice = @import("model_choice.zig");
const picker = @import("model_picker.zig");
const Footer = @import("widgets/Footer.zig");
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
    models: ?*const fn (*anyopaque) ?*const picker.Menu = null,
};

backend: ?Backend = null,
narrow: bool = false,
values: preferences.Values = .{},
read_failed: bool = false,
panel: Panel = .{ .title = "Rui" },
model_choice: ModelChoice = .{},
fields: [5]Panel.Field = undefined,
/// The row awaiting the backend's answer. Displayed values always come from
/// the saved file, including uncertain saves.
saving_row: ?usize = null,
failures: [5]?[]const u8 = @splat(null),
effort_choices: [std.enums.values(catalog.ReasoningEffort).len + 1][]const u8 = undefined,
effort_count: usize = 0,
/// Supplied by the application owner, not a dependency of UI-only roots.
version: []const u8 = "",
upgrade_buffer: [upgrade_status.max_line_bytes]u8 = undefined,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn hasChoice(self: *const Self) bool {
    return self.panel.choice != null or self.model_choice.active;
}

pub fn cancelChoice(self: *Self) void {
    self.panel.closeChoice();
    self.model_choice.cancel();
    self.panel.custom_choice = null;
}

pub fn refresh(self: *Self) !void {
    // A choice is tied to the saved provider/model snapshot it opened on.
    // Refreshing (including failure) invalidates that choice, never its owner.
    self.cancelChoice();
    const backend = self.backend orelse {
        self.read_failed = true;
        self.failures[0] = " · settings unavailable";
        return;
    };
    const was_failed = self.read_failed;
    self.values = backend.read(backend.context) catch {
        self.read_failed = true;
        self.failures[0] = " · couldn't read settings";
        return;
    };
    self.read_failed = false;
    if (was_failed) self.failures[0] = null;
}

fn provider(self: *const Self) ?protocol.Provider {
    return std.meta.stringToEnum(protocol.Provider, if (self.values.provider.len == 0) defaults.provider else self.values.provider.slice());
}

fn model(self: *const Self) []const u8 {
    return if (self.values.model.len == 0) defaults.recommended_model else self.values.model.slice();
}

fn bind(self: *Self) void {
    self.panel.userdata = self;
    self.panel.on_activate = activate;
    self.panel.on_pick = pick;
    self.model_choice.userdata = self;
    self.model_choice.on_pick = pickModel;
    self.panel.custom_choice = if (self.model_choice.active) .{ .field = 0, .widget = self.model_choice.widget() } else null;
    self.fields = .{
        .{ .label = "Model", .value = if (self.read_failed) "unavailable" else self.model(), .tail = self.failures[0] },
        .{ .label = "Effort", .value = if (self.read_failed) "unavailable" else if (self.values.reasoning_effort) |effort| @tagName(effort) else "model default", .tail = self.failures[1] },
        .{ .label = "Notifications", .value = if (self.read_failed) "unavailable" else if (self.values.notifications) "on" else "off", .tail = self.failures[2] },
        .{ .label = "Sign-in", .value = if (self.read_failed) "unavailable" else if (self.provider()) |saved| saved.signIn() else "unavailable", .tail = self.failures[3] },
        .{ .label = "Version", .value = self.version, .tail = self.versionTail() },
    };
    if (self.saving_row) |row| self.fields[row].tail = " · saving";
    self.panel.fields = &self.fields;
    const caps = if (self.backend) |b| b.caps(b.context) else view.Caps{};
    self.panel.ground = widget_style.of(caps, .{ .background = .bar });
    self.panel.selection = widget_style.of(caps, .{ .background = .selection });
    self.panel.title_style = widget_style.of(caps, .{ .background = .bar, .colour = .strong, .bold = true });
    self.panel.quiet = widget_style.of(caps, .{ .background = .bar, .colour = .quiet });
    self.panel.rule_style = widget_style.of(caps, .{ .background = .bar, .colour = .rule });
    self.model_choice.ground = self.panel.ground;
    self.model_choice.selection = self.panel.selection;
    self.model_choice.quiet = self.panel.quiet;
}

fn versionTail(self: *Self) ?[]const u8 {
    if (self.failures[4]) |failure| return failure;
    const backend = self.backend orelse return null;
    const run = backend.run(backend.context) orelse return null;
    return upgrade_status.fieldTail(run, &self.upgrade_buffer);
}

fn activate(raw: *anyopaque, ctx: *vxfw.EventContext, index: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const backend = self.backend orelse return;
    if (self.saving_row != null) return;
    self.failures[index] = null;
    if (index == 4) {
        backend.upgrade(backend.context) catch {
            self.failures[4] = " · couldn't start upgrade";
        };
        ctx.redraw = true;
        return;
    }
    if (index == 3) return; // Sign-in stays selectable until its screen exists.
    try self.refresh();
    if (self.read_failed) return;
    switch (index) {
        0 => {
            if (self.provider() == null) {
                self.failures[0] = " · sign-in unavailable";
                return;
            }
            const menu = if (backend.models) |read_models| read_models(backend.context) else null;
            self.model_choice.open(menu, self.provider().?, self.model());
            if (!self.model_choice.active) self.failures[0] = " · models unavailable";
        },
        1 => {
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
        2 => {
            const enabled = !self.values.notifications;
            try self.save(ctx, index, .{ .notifications = enabled });
        },
        else => unreachable,
    }
    ctx.redraw = true;
}

fn pickModel(raw: *anyopaque, ctx: *vxfw.EventContext, model_id: []const u8) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.save(ctx, 0, .{ .provider = .{ .set = @tagName(self.provider().?) }, .model = .{ .set = model_id } });
}

fn pick(raw: *anyopaque, ctx: *vxfw.EventContext, field: usize, choice: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const edit: preferences.Edit = switch (field) {
        1 => .{
            .reasoning_effort = if (choice == 0) .clear else .{
                .set = std.meta.stringToEnum(catalog.ReasoningEffort, self.effort_choices[choice]).?,
            },
        },
        else => unreachable,
    };
    try self.save(ctx, field, edit);
}

fn save(self: *Self, ctx: *vxfw.EventContext, row: usize, edit: preferences.Edit) !void {
    const backend = self.backend.?;
    backend.save(backend.context, edit) catch {
        self.failures[row] = " · couldn't save";
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
    self.failures[row] = if (state == .failed) " · couldn't save" else if (self.read_failed) " · couldn't read settings" else null;
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
    self.bind();
    try self.panel.widget().handleEvent(ctx, input);
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
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
        self.save_status = .pending;
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
    const next = (page.model_choice.selected.? + 1) % catalog.openai_ids.len;
    page.model_choice.selected = next;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!page.hasChoice());
    const model_edit = fixture.last_edit.?;
    try std.testing.expectEqualStrings("codex", model_edit.provider.set);
    try std.testing.expectEqualStrings(catalog.openai_ids[next], model_edit.model.set);
    try std.testing.expectEqual(.keep, model_edit.store);
    try std.testing.expectEqual(.keep, model_edit.reasoning_effort);
    try std.testing.expectEqual(@as(?bool, null), model_edit.notifications);
    try std.testing.expectEqual(@as(?usize, 0), page.saving_row);
    page.bind();
    try std.testing.expectEqualStrings(" · saving", page.fields[0].tail.?);
    try fixture.values.model.set(catalog.openai_ids[next]);
    try fixture.values.provider.set("codex");
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(?usize, 0), page.saving_row);
    try std.testing.expectEqualStrings(defaults.recommended_model, page.model());
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(catalog.openai_ids[next], page.model());
    try std.testing.expectEqual(@as(?[]const u8, null), page.failures[0]);

    // Effort choices are the selected model's supported efforts, plus clearing.
    page.panel.selected = 1;
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

    page.panel.selected = 2;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?bool, false), fixture.last_edit.?.notifications);
    try std.testing.expect(page.values.notifications);
    fixture.values.notifications = false;
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(!page.values.notifications);

    // Read-only sign-in doesn't submit, while Version delegates to Upgrade.
    page.panel.selected = 3;
    fixture.last_edit = null;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(?preferences.Edit, null), fixture.last_edit);
    page.panel.selected = 4;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.upgrades);
    try std.testing.expectEqualStrings(upgrade_status.fieldTail(.checking, &page.upgrade_buffer), page.versionTail().?);
}

test "App settings failures stay on the field and can recover" {
    var fixture: Fixture = .{};
    var page: Self = .{ .backend = fixture.backend() };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.refresh();
    page.panel.selected = 2;
    fixture.fail_save = true;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures[2].?);
    try std.testing.expect(page.values.notifications);
    fixture.fail_save = false;
    try press(&page, &ctx, vaxis.Key.enter);
    // A failed backend answer is a row failure even if publication succeeded.
    fixture.values.notifications = false;
    fixture.save_status = .failed;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(page.failures[2] != null);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures[2].?);
    try std.testing.expect(!page.values.notifications);
    try std.testing.expectEqual(@as(?usize, null), page.saving_row);
    page.bind();
    try std.testing.expectEqualStrings(" · couldn't save", page.fields[2].tail.?);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures[2].?);
    try press(&page, &ctx, vaxis.Key.enter);
    fixture.values.notifications = true;
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(?[]const u8, null), page.failures[2]);
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
            page.panel.selected = 2;
            try press(&page, &ctx, vaxis.Key.enter);
            try std.testing.expectEqual(@as(?usize, 2), page.saving_row);
            fixture.save_status = state;
            fixture.fail_read = fail_read;
            // The saved file is authoritative for displayed values; the
            // backend's outcome, not a value comparison, decides success.
            try page.widget().handleEvent(&ctx, .tick);
            try std.testing.expectEqual(@as(?usize, null), page.saving_row);
            try std.testing.expectEqual(fail_read, page.read_failed);
            try std.testing.expect(page.values.notifications);
            const failure: ?[]const u8 = if (state == .failed) " · couldn't save" else if (fail_read) " · couldn't read settings" else null;
            if (failure) |text| {
                try std.testing.expectEqualStrings(text, page.failures[2].?);
                page.bind();
                try std.testing.expectEqualStrings(text, page.fields[2].tail.?);
            } else {
                try std.testing.expectEqual(@as(?[]const u8, null), page.failures[2]);
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
        try std.testing.expect(std.mem.indexOf(u8, text, "   Notifications   on") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Sign-in         ChatGPT") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Version         0.60.0 · up to date") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (page.narrow) " ‹ Rui · settings" else " Rui · settings") != null);
        const ground = widget_style.of(.{}, .{ .background = .bar });
        try std.testing.expectEqual(ground.bg, screen.readCell(0, 15).?.style.bg);
        try std.testing.expectEqual(widget_style.of(.{}, .{ .background = .selection }).bg, screen.readCell(0, 2).?.style.bg);
        std.debug.print("\nAPP SETTINGS {d}x20\n{s}END APP SETTINGS\n", .{ width, text });
    }
}

test "App settings sign-in and effort choices reflect saved values without assuming a provider" {
    var fixture: Fixture = .{};
    try fixture.values.provider.set("openai");
    var page: Self = .{ .backend = fixture.backend() };
    try page.refresh();
    page.bind();
    try std.testing.expectEqualStrings("API key", page.fields[3].value);
    try std.testing.expectEqualStrings("model default", page.fields[1].value);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    page.panel.selected = 0;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.hasChoice());
    page.cancelChoice();
    // A formerly supported sign-in remains readable in preferences. It must
    // not become a different sign-in or a forced-unwrapped enum in this page.
    try fixture.values.provider.set("legacy");
    try page.refresh();
    page.bind();
    try std.testing.expectEqualStrings("unavailable", page.fields[3].value);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!page.hasChoice());
    try std.testing.expectEqualStrings(" · sign-in unavailable", page.failures[0].?);
    // A saved effort excluded by this model doesn't mark "model default" as
    // current: the page must not claim that an unsaved clearing already holds.
    for (catalog.shipped) |entry| if (entry.openai_listed and !entry.efforts.contains(.max)) {
        try fixture.values.model.set(entry.id);
        break;
    };
    fixture.values.reasoning_effort = .max;
    page.panel.selected = 1;
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
