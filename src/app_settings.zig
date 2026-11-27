const std = @import("std");
const connection_names = @import("connection_names.zig");
const provider_route = @import("provider_route.zig");
const setting_words = @import("setting_words.zig");
const connection = @import("connection.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Panel = @import("widgets/Panel.zig");
const ModelChoice = @import("model_choice.zig");
const picker = @import("model_picker.zig");
const Footer = @import("widgets/Footer.zig");
const keys_panel = @import("keys_panel.zig");
const connections_panel = @import("connections_panel.zig");
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

pub const Backend = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) anyerror!preferences.Values,
    save: *const fn (*anyopaque, preferences.Edit) anyerror!void,
    save_state: *const fn (*anyopaque) SaveState,
    upgrade: *const fn (*anyopaque) anyerror!void,
    run: *const fn (*anyopaque) ?upgrade_status.Run,
    available: ?*const fn (*anyopaque) ?upgrade_status.Version = null,
    caps: *const fn (*anyopaque) view.Caps,
    memory: ?*const fn (*anyopaque) ?view.Memory = null,
    models: ?*const fn (*anyopaque) ModelChoice.Snapshot = null,
    sign_in: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
    /// The Host's served connections with the usage each last reported, and the Unix second they are read at; null when the Host cannot be read.
    connections: ?*const fn (*anyopaque) ?ConnectionsSnapshot = null,
};

pub const ConnectionsSnapshot = struct { facts: protocol.Connections, now: u64 };

/// The read-only reference a Settings row opens in place of the list: the shared key list over its own rows.
const Reference = enum { keys, connections };

pub const Row = enum { model, effort, permissions, notifications, sign_in, connections, version, memory, keys };
const row_count = std.enums.values(Row).len;

backend: ?Backend = null,
reference_open: bool = false,
reference: Reference = .keys,
connection_rows: connections_panel.Rows = .{},
connection_facts: ?ConnectionsSnapshot = null,
reference_offset: usize = 0,
reference_rows: usize = 0,
reference_height: usize = 0,
values: preferences.Values = .{},
read_failed: bool = false,
panel: Panel = .{ .title = "Rui", .top_rule = false, .natural_height = true },
footer: Footer = .{ .left = "Settings", .right = "esc", .left_inset = 1 },
model_choice: ModelChoice = .{},
fields: [row_count]Panel.Field = undefined,
saving_row: ?Row = null,
failures: std.EnumArray(Row, ?[]const u8) = .initFill(null),
effort_choices: [std.enums.values(catalog.ReasoningEffort).len + 1][]const u8 = undefined,
effort_count: usize = 0,
version: []const u8 = "",
upgrade_buffer: [upgrade_status.max_line_bytes]u8 = undefined,

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn footerWidget(self: *Self) vxfw.Widget {
    self.footer.style = widget_style.of(if (self.backend) |backend| backend.caps(backend.context) else .{}, .{ .colour = .quiet, .background = .raised });
    return self.footer.widget();
}

pub fn hasChoice(self: *const Self) bool {
    return self.panel.choice != null or self.model_choice.active;
}

pub fn cancelChoice(self: *Self) void {
    self.cancelEdit();
}

fn cancelEdit(self: *Self) void {
    self.panel.closeChoice();
    self.model_choice.cancel();
    self.panel.custom_choice = null;
}

pub fn takesKey(self: *const Self, key: vaxis.Key) bool {
    if (@import("keypress.zig").named(key)) |name| {
        if (self.reference_open and (name == .page_up or name == .page_down)) return true;
        if (@import("app_input.zig").keys.get(name) != null) return true;
    }
    return (self.model_choice.active and ModelChoice.takesKey(key)) or Panel.takesKey(key);
}

pub fn takesPaste(self: *const Self) bool {
    return self.model_choice.active;
}

pub fn upgradeTakesEscape(self: *const Self) bool {
    const backend = self.backend orelse return false;
    const run = backend.run(backend.context) orelse return false;
    return run.takesEscape();
}

pub fn select(self: *Self, row: Row) void {
    self.panel.selected = @backingInt(row);
}

const unavailable_rows = [_]Panel.Field{.{ .label = "Connections", .value = "unavailable: the Host cannot be read" }};

pub fn refresh(self: *Self) !void {
    try self.readValues();
}

fn readValues(self: *Self) !void {
    self.cancelEdit();
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

fn provider(self: *const Self) ?connection.Name {
    return connection.Name.parse(if (self.values.provider.len == 0) defaults.provider else self.values.provider.slice());
}

fn model(self: *const Self) []const u8 {
    return if (self.values.model.len == 0) defaults.recommended_model else self.values.model.slice();
}

fn choiceEffort(self: *const Self) ?catalog.ReasoningEffort {
    return self.values.reasoning_effort;
}

fn permissionMode(self: *const Self) protocol.PermissionMode {
    return self.values.permission_mode orelse std.meta.stringToEnum(protocol.PermissionMode, defaults.permission_mode).?;
}

fn value(self: *const Self, row: Row) []const u8 {
    if (row == .keys or row == .memory or row == .connections) return "";
    if (row == .version) return self.version;
    if (self.read_failed) return "unavailable";
    return switch (row) {
        .model => self.model(),
        .effort => setting_words.effort(self.choiceEffort()),
        .permissions => setting_words.permission(self.permissionMode()),
        .notifications => if (self.values.notifications) "on" else "off",
        .sign_in => if (self.provider()) |saved| provider_route.signInOf(saved) orelse "unavailable" else "unavailable",
        .version, .memory, .keys, .connections => unreachable,
    };
}

fn tail(self: *Self, row: Row) ?[]const u8 {
    if (self.saving_row == row) return " · saving";
    if (self.failures.get(row)) |failure| return failure;
    if (row != .version) return null;
    const backend = self.backend orelse return null;
    const available = if (backend.available) |read| read(backend.context) else null;
    return upgrade_status.versionTail(backend.run(backend.context), available, &self.upgrade_buffer);
}

fn bind(self: *Self) void {
    self.panel.userdata = self;
    self.panel.on_activate = activate;
    self.panel.on_pick = pick;
    _ = self.model_choice.validate();
    self.model_choice.userdata = self;
    self.model_choice.on_pick = pickModel;
    self.panel.custom_choice = if (self.model_choice.active) self.model_choice.field(@backingInt(Row.model)) else null;
    for (std.enums.values(Row)) |row| self.fields[@backingInt(row)] = .{
        .label = switch (row) {
            .model => "Model",
            .effort => "Effort",
            .permissions => "Permissions",
            .notifications => "Notifications",
            .sign_in => "Sign-in",
            .connections => "Connections",
            .version => "Version",
            .memory => "Memory",
            .keys => "Keys",
        },
        .value = self.value(row),
        .tail = self.tail(row),
        .selectable = row != .memory,
        .visible = row != .memory,
    };
    self.panel.fields = &self.fields;
    const caps = if (self.backend) |b| b.caps(b.context) else view.Caps{};
    self.panel.unicode = caps.unicode;
    self.model_choice.unicode = caps.unicode;
    // Settings opens as a dialog, so it draws in the dialog's palette.
    const look: @import("Dialog.zig").Look = .of(caps);
    self.panel.ground = look.ground;
    self.panel.selection = look.selection;
    self.panel.hover_style = look.hover;
    self.panel.title_style = look.title;
    self.panel.quiet = look.quiet;
    self.panel.rule = look.stitch(.horizontal);
    self.model_choice.show_more = true;
    self.model_choice.ground = self.panel.ground;
    self.model_choice.selection = self.panel.selection;
    self.model_choice.hover_style = self.panel.hover_style;
    self.model_choice.quiet = self.panel.quiet;
}

fn activate(raw: *anyopaque, ctx: *vxfw.EventContext, index: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const row: Row = @fromBackingInt(@intCast(index));
    if (row == .memory) return;
    if (row == .keys or row == .connections) {
        self.reference = if (row == .keys) .keys else .connections;
        self.connection_facts = null;
        if (row == .connections) if (self.backend) |backend| if (backend.connections) |read| {
            self.connection_facts = read(backend.context);
        };
        self.reference_open = true;
        self.reference_offset = 0;
        ctx.consumeAndRedraw();
        return;
    }
    const backend = self.backend orelse {
        self.failures.set(row, " · settings unavailable");
        return;
    };
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
        .memory, .keys, .connections => unreachable,
        .model, .effort, .permissions, .notifications => {
            try self.readValues();
            if (self.read_failed) {
                self.failures.set(row, " · couldn't read settings");
                return;
            }
        },
    }
    switch (row) {
        .model => {
            const saved_provider = self.provider() orelse {
                self.failures.set(.model, " · sign-in unavailable");
                return;
            };
            if (backend.models) |models|
                self.model_choice.openSource(.{ .context = backend.context, .read = models }, saved_provider, self.model())
            else
                self.model_choice.open(null, saved_provider, self.model());
            if (!self.model_choice.active) self.failures.set(.model, " · models unavailable");
        },
        .effort => {
            self.effort_choices[0] = setting_words.effort_default;
            self.effort_count = 1;
            const shown = self.choiceEffort();
            var current: ?usize = if (shown == null) 0 else null;
            for (std.enums.values(catalog.ReasoningEffort)) |effort| {
                if (!capability.supportsReasoningEffort(catalog.shipped, self.model(), effort)) continue;
                if (shown == effort) current = self.effort_count;
                self.effort_choices[self.effort_count] = setting_words.effort(effort);
                self.effort_count += 1;
            }
            self.panel.openChoice(self.effort_choices[0..self.effort_count], current);
        },
        .permissions => self.panel.openChoice(&setting_words.permission_labels, setting_words.permissionChoice(self.permissionMode())),
        .notifications => try self.save(ctx, row, .{ .notifications = !self.values.notifications }),
        .sign_in, .version, .memory, .keys, .connections => {},
    }
    ctx.redraw = true;
}

fn pick(raw: *anyopaque, ctx: *vxfw.EventContext, field: usize, choice: usize) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const row: Row = @fromBackingInt(@intCast(field));
    try self.save(ctx, row, switch (row) {
        .effort => .{
            .reasoning_effort = if (choice == 0) .clear else .{
                .set = std.meta.stringToEnum(catalog.ReasoningEffort, self.effort_choices[choice]).?,
            },
        },
        .permissions => .{ .permission_mode = .{ .set = setting_words.permissionAt(choice) } },
        .model, .notifications, .sign_in, .version, .memory, .keys, .connections => unreachable,
    });
}

fn pickModel(raw: *anyopaque, ctx: *vxfw.EventContext, id: []const u8) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.panel.custom_choice = null;
    try self.save(ctx, .model, .{
        .provider = .{ .set = self.model_choice.providerName() },
        .model = .{ .set = id },
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
    try self.readValues();
    self.failures.set(row, if (state == .failed) " · couldn't save" else if (self.read_failed) " · couldn't read settings" else null);
    self.saving_row = null;
}

fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.model_choice.active and !self.model_choice.validate()) {
        self.panel.custom_choice = null;
        ctx.consumeAndRedraw();
        return;
    }
    if (input == .tick) {
        const was_saving = self.saving_row != null;
        try self.poll();
        if (was_saving) ctx.redraw = true;
        return;
    }
    if (self.reference_open) {
        if (input == .key_press) {
            const name = @import("keypress.zig").named(input.key_press) orelse return;
            const maximum = self.reference_rows -| self.reference_height;
            const page = @max(self.reference_height, 1);
            switch (name) {
                .up => self.reference_offset -|= 1,
                .down => self.reference_offset = @min(self.reference_offset + 1, maximum),
                .page_up => self.reference_offset -|= page,
                .page_down => self.reference_offset = @min(self.reference_offset + page, maximum),
                else => return,
            }
            ctx.consumeAndRedraw();
        }
        return;
    }
    self.bind();
    if (!self.model_choice.active and input == .key_press) {
        if (@import("keypress.zig").named(input.key_press)) |name| if (@import("app_input.zig").keys.get(name)) |direction| {
            return self.panel.traverse(ctx, direction == .previous, @import("app_input.zig").tabNextValue);
        };
    }
    try self.panel.widget().handleEvent(ctx, input);
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.reference_open) {
        const caps = if (self.backend) |backend| backend.caps(backend.context) else view.Caps{};
        var reference = keys_panel.panel(caps);
        if (self.reference == .connections) reference.fields = if (self.connection_facts) |snapshot|
            connections_panel.build(&self.connection_rows, snapshot.facts.slice(), snapshot.now)
        else
            &unavailable_rows;
        reference.row_offset = self.reference_offset;
        var surface = try reference.widget().draw(ctx);
        self.reference_offset = reference.row_offset;
        self.reference_rows = reference.total_rows;
        self.reference_height = reference.viewport_height;
        surface.widget = self.widget();
        return surface;
    }
    self.bind();
    self.panel.top_rule = false;
    self.panel.natural_height = true;
    const size = ctx.max.size();
    if (size.width == 0 or size.height == 0) return .empty(self.widget());
    const memory = if (self.backend) |backend| (if (backend.memory) |read| read(backend.context) else null) else null;
    const text = try @import("memory_text.zig").fit(ctx.arena, memory, self.panel.unicode, Panel.valueWidth(size.width));
    self.fields[@backingInt(Row.memory)].value = text;
    self.fields[@backingInt(Row.memory)].visible = text.len != 0;
    const surface = try self.panel.widget().draw(ctx);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = surface };
    return .{ .widget = self.widget(), .size = surface.size, .buffer = &.{}, .children = children, .cursor = surface.cursor };
}

const Fixture = struct {
    unicode: bool = true,
    background: ?view.Rgb = null,
    memory_value: ?view.Memory = null,
    read_calls: usize = 0,
    save_calls: usize = 0,
    values: preferences.Values = .{},
    save_status: SaveState = .idle,
    fail_read: bool = false,
    fail_save: bool = false,
    home: ?[]const u8 = null,
    upgrades: usize = 0,
    snapshot: ?ConnectionsSnapshot = null,
    last_edit: ?preferences.Edit = null,
    status: ?upgrade_status.Run = .{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 60, .patch = 0 } }, .outcome = .unchanged } },

    fn backend(self: *Fixture) Backend {
        return .{ .context = self, .read = read, .save = saveEdit, .save_state = saveState, .upgrade = upgrade, .run = run, .caps = caps, .memory = memory, .connections = connections };
    }
    fn connections(raw: *anyopaque) ?ConnectionsSnapshot {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return self.snapshot;
    }
    fn read(raw: *anyopaque) !preferences.Values {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.read_calls += 1;
        if (self.fail_read) return error.AccessDenied;
        return self.values;
    }
    fn saveEdit(raw: *anyopaque, edit: preferences.Edit) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.save_calls += 1;
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
    fn memory(raw: *anyopaque) ?view.Memory {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return self.memory_value;
    }
    fn caps(raw: *anyopaque) view.Caps {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return .{ .unicode = self.unicode, .background = self.background };
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
    try press(&page, &ctx, vaxis.Key.down);
    const chosen_model = page.model_choice.menu.entries[page.model_choice.focus.selected().?].id;
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!page.hasChoice());
    const model_edit = fixture.last_edit.?;
    try std.testing.expectEqualStrings("codex", model_edit.provider.set);
    try std.testing.expectEqualStrings(chosen_model, model_edit.model.set);
    try std.testing.expectEqual(.keep, model_edit.store);
    try std.testing.expectEqual(.keep, model_edit.reasoning_effort);
    try std.testing.expectEqual(@as(?bool, null), model_edit.notifications);
    try std.testing.expectEqual(@as(?Row, .model), page.saving_row);
    page.bind();
    try std.testing.expectEqualStrings(" · saving", page.fields[@backingInt(Row.model)].tail.?);
    try fixture.values.model.set(chosen_model);
    try fixture.values.provider.set("codex");
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqual(@as(?Row, .model), page.saving_row);
    try std.testing.expectEqualStrings(defaults.recommended_model, page.model());
    fixture.save_status = .saved;
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expectEqualStrings(chosen_model, page.model());
    try std.testing.expectEqual(@as(?[]const u8, null), page.failures.get(.model));

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

test "App settings and nested Keys share Composer input lines and preserve the draft" {
    var fixture: Fixture = .{};
    var page: Self = .{ .backend = fixture.backend() };
    try page.refresh();
    var bytes = "retained draft".*;
    var editor: @import("DraftEditor.zig") = .initText(&bytes, &bytes, 4);
    var input: @import("InputArea.zig") = .{
        .composer = .{ .editor = &editor, .caret = false },
        .panel = .{ .full = page.widget() },
        .facts = page.footerWidget(),
        .status = null,
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]vxfw.Size{ .{ .width = 140, .height = 40 }, .{ .width = 46, .height = 30 } }) |size| {
        for ([_]bool{ false, true }) |keys| {
            page.reference_open = keys;
            const shown = try input.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
            const composer = shown.children[0].surface;
            try std.testing.expect(composer.widget.eql(input.composer.widget()));
            try std.testing.expectEqual(@as(i17, 1), composer.children[0].origin.row);
            try std.testing.expect(composer.children[0].surface.widget.eql(page.widget()));
            try std.testing.expectEqualStrings("┄", composer.readCell(0, 0).char.grapheme);
            try std.testing.expectEqualStrings("┄", composer.readCell(0, composer.size.height - 1).char.grapheme);
            try std.testing.expectEqualStrings("r", composer.readCell(3, composer.size.height - 2).char.grapheme);
            try std.testing.expectEqualStrings("S", shown.children[1].surface.readCell(1, 0).char.grapheme);
            try std.testing.expectEqualStrings("retained draft", editor.text());
            try std.testing.expectEqual(@as(usize, 4), editor.cursor());
        }
    }
}

test "App settings footer stays quiet on the dialog ground in both themes and widths" {
    var fixture: Fixture = .{};
    var page: Self = .{ .backend = fixture.backend() };
    try page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]?view.Rgb{ null, .{ 255, 255, 255 } }) |background| for ([_]u16{ 140, 46 }) |width| {
        fixture.background = background;
        const surface = try page.footerWidget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
        const plain = widget_style.of(fixture.backend().caps(&fixture), .{ .colour = .quiet, .background = .raised });
        for (surface.buffer, 0..) |cell, col| {
            try std.testing.expectEqual(plain, cell.style);
            const expected = if (col >= 1 and col < 1 + "Settings".len) "Settings"[col - 1] else if (col >= width - 3) "esc"[col - (width - 3)] else ' ';
            try std.testing.expectEqual(expected, cell.char.grapheme[0]);
        }
    };
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
        const surface = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
        var screen = try vaxis.Screen.init(arena.allocator(), .{ .cols = width, .rows = 20, .x_pixel = 0, .y_pixel = 0 });
        try surface.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 20, .screen = &screen }, page.widget());
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
        try std.testing.expect(std.ascii.findIgnoreCase(text, "codex") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "   Version         0.60.0 · up to date") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Rui") != null);
        const ground = widget_style.of(.{}, .{ .background = .raised });
        try std.testing.expectEqual(ground.bg, screen.readCell(0, surface.size.height - 1).?.style.bg);
        try std.testing.expectEqual(widget_style.of(.{}, .{ .background = .selection }).bg, screen.readCell(0, 1).?.style.bg);
    }
}

test "App settings sign-in and effort choices reflect saved values without assuming a provider" {
    var fixture: Fixture = .{};
    for ([_][2][]const u8{ .{ "codex", "ChatGPT" }, .{ "chatgpt", "ChatGPT" }, .{ "openai", "API key" } }) |case| {
        try fixture.values.provider.set(case[0]);
        var shown: Self = .{ .backend = fixture.backend() };
        try shown.refresh();
        shown.bind();
        try std.testing.expectEqualStrings(case[1], shown.fields[@backingInt(Row.sign_in)].value);
    }
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
    try fixture.values.provider.set("legacy");
    try page.refresh();
    page.bind();
    try std.testing.expectEqualStrings("unavailable", page.fields[@backingInt(Row.sign_in)].value);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(!page.hasChoice());
    try std.testing.expectEqualStrings(" · models unavailable", page.failures.get(.model).?);
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
    try std.testing.expectEqualStrings(setting_words.permission(std.meta.stringToEnum(protocol.PermissionMode, defaults.permission_mode).?), page.fields[@backingInt(Row.permissions)].value);
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

test "App settings Model shares the provider list at full width and preserves matches on filtering" {
    const List = struct {
        const entries = [_]picker.Entry{
            .{ .id = "future-chat", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.codex)}) },
            .{ .id = "api-only", .known = false, .catalogued = false, .providers = connection_names.NameSet.of(&.{provider_route.nameOf(.openai)}) },
            .{ .id = "text-embedding-3-small", .known = true, .catalogued = true, .providers = connection_names.NameSet.of(&provider_route.built_in_names) },
        };
        const menu: picker.Menu = .{ .entries = &entries };
        fn models(_: *anyopaque) ModelChoice.Snapshot {
            return .{ .menu = &menu };
        }
    };
    var fixture: Fixture = .{};
    var backend = fixture.backend();
    backend.models = List.models;
    var page: Self = .{ .backend = backend };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try page.refresh();
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expect(page.hasChoice());
    for ([_]u16{ 99, 46 }) |width| {
        const drawn = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
        const parts = drawn.children[0].surface.children;
        const choice = parts[parts.len - 1];
        try std.testing.expectEqual(@as(i17, 0), choice.origin.col);
        try std.testing.expectEqual(width, choice.surface.size.width);
        try std.testing.expectEqual(@as(u16, 1), choice.surface.size.height);
        try std.testing.expectEqualStrings(" ", choice.surface.readCell(2, 0).char.grapheme);
        try std.testing.expectEqual(@as(usize, 1), page.model_choice.hits.len);
        try std.testing.expectEqual(@as(u16, 19), drawn.cursor.?.col);
        try std.testing.expectEqual(@as(u16, 1), drawn.cursor.?.row);
        try std.testing.expectEqualStrings("E", drawn.children[0].surface.readCell(3, 3).char.grapheme);
        try std.testing.expectEqualStrings(" ", drawn.children[0].surface.readCell(19, 1).char.grapheme);
    }
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'f', .text = "future" } });
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'z', .text = "zzzz" } });
    try std.testing.expect(page.model_choice.no_match);
    try std.testing.expectEqualStrings("future", page.model_choice.editor.text());
    for ([_]u16{ 99, 46 }) |width| {
        const drawn = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
        var screen = try vaxis.Screen.init(arena.allocator(), .{ .cols = width, .rows = 20, .x_pixel = 0, .y_pixel = 0 });
        try drawn.render(.{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 20, .screen = &screen }, page.widget());
        try std.testing.expect(screen.cursor_vis);
        try std.testing.expectEqual(@as(u16, 25), screen.cursor.col);
        try std.testing.expectEqual(@as(u16, 1), screen.cursor.row);
        try std.testing.expectEqualStrings("f", screen.readCell(19, 1).?.char.grapheme);
    }
    page.cancelChoice();
    try std.testing.expectEqual(@as(?preferences.Edit, null), fixture.last_edit);
    try press(&page, &ctx, vaxis.Key.enter);
    try press(&page, &ctx, vaxis.Key.enter);
    try std.testing.expectEqualStrings("future-chat", fixture.last_edit.?.model.set);
}

test "App settings shared ASCII capability reaches the panel model choice tails and footer" {
    const Check = struct {
        fn ascii(surface: vxfw.Surface) !void {
            for (surface.buffer) |cell| for (cell.char.grapheme) |byte| try std.testing.expect(byte < 0x80);
            for (surface.children) |child| try ascii(child.surface);
        }
    };
    var fixture: Fixture = .{ .unicode = false };
    var page: Self = .{ .backend = fixture.backend(), .version = "unreleased" };
    try page.refresh();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 46, 99 }) |width| {
        for (0..4) |state| {
            page.cancelChoice();
            if (state == 1) {
                page.select(.permissions);
                try press(&page, &ctx, vaxis.Key.enter);
            } else if (state >= 2) {
                page.select(.model);
                try press(&page, &ctx, vaxis.Key.enter);
                page.model_choice.no_match = state == 3;
            }
            fixture.status = .checking;
            page.failures.set(.notifications, " · couldn't save");
            const surface = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
            try Check.ascii(surface);
            try std.testing.expect(!page.panel.unicode and !page.model_choice.unicode);
            const footer = try page.footerWidget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 1 }, .cell_size = .{} });
            try Check.ascii(footer);
            try std.testing.expectEqualStrings("S", footer.readCell(1, 0).char.grapheme);
        }
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
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 12 }, .cell_size = .{} };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        try page.refresh();
        _ = try page.widget().draw(draw_ctx);
        try page.widget().handleEvent(&events, .mouse_enter);
        const permissions_row = 1 + @backingInt(Row.permissions);
        var mouse: vaxis.Mouse = .{ .col = 1, .row = permissions_row, .button = .none, .type = .motion, .mods = .{} };
        try page.widget().handleEvent(&events, .{ .mouse = mouse });
        var surface = try page.widget().draw(draw_ctx);
        try std.testing.expectEqual(page.panel.hover_style.bg, surface.children[0].surface.readCell(1, permissions_row).style.bg);
        try std.testing.expectEqual(page.panel.selection.bg, surface.children[0].surface.readCell(1, 1).style.bg);
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
        var page: Self = .{};
        try page.refresh();
        page.bind();
        try std.testing.expectEqualStrings("Keys", page.fields[@backingInt(Row.keys)].label);
        try std.testing.expectEqualStrings("", page.fields[@backingInt(Row.keys)].value);
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        if (click) {
            _ = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
            try page.widget().handleEvent(&ctx, .{ .mouse = .{ .button = .left, .type = .press, .row = @intCast(page.panel.body.top + @as(u16, @backingInt(Row.keys)) - 1), .col = 4, .mods = .{} } });
        } else {
            page.select(.keys);
            try press(&page, &ctx, vaxis.Key.enter);
        }
        try std.testing.expect(page.reference_open);
        try std.testing.expect(ctx.consume_event);
        const drawn = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
        try std.testing.expectEqualStrings("e", drawn.readCell(1, 0).char.grapheme);
        try std.testing.expect(drawn.widget.eql(page.widget()));
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.reference_open);
        try std.testing.expect(page.saving_row == null);
    };
}

test "App settings Memory fits the drawable value width at every boundary" {
    var fixture: Fixture = .{ .memory_value = .{ .rui = 38 * view.mib, .tools = 120 * view.mib } };
    var page: Self = .{ .backend = fixture.backend(), .version = "unreleased" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try page.refresh();
    for ([_]struct { width: u16, expected: ?[]const u8 }{
        .{ .width = 46, .expected = "Memory          rui 38 MB · tools 120 MB" },
        .{ .width = 45, .expected = "Memory          rui 38 MB · tools 120 MB" },
        .{ .width = 44, .expected = "Memory          rui 38 MB" },
        .{ .width = 43, .expected = "Memory          rui 38 MB" },
        .{ .width = 40, .expected = "Memory          rui 38 MB" },
        .{ .width = 30, .expected = "Memory          rui 38 MB" },
        .{ .width = 29, .expected = null },
        .{ .width = 19, .expected = null },
        .{ .width = 1, .expected = null },
    }) |case| {
        const surface = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = case.width, .height = 20 }, .cell_size = .{} });
        const body = surface.children[0].surface;
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (0..body.size.height) |y| {
            for (0..body.size.width) |x| try text.writer.writeAll(body.readCell(@intCast(x), @intCast(y)).char.grapheme);
            try text.writer.writeByte('\n');
        }
        var line: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, text.written(), '\n');
        while (lines.next()) |each| if (std.mem.indexOf(u8, each, "Memory") != null) {
            line = std.mem.trim(u8, each, " ");
        };
        if (case.expected) |expected| try std.testing.expectEqualStrings(expected, line.?) else try std.testing.expectEqual(null, line);
        try std.testing.expectEqual(case.expected != null, page.fields[@backingInt(Row.memory)].visible);
        _ = arena.reset(.retain_capacity);
    }
}

test "App settings live Memory is optional read-only and independent of saved preferences" {
    const Case = struct { memory: ?view.Memory, expected: ?[]const u8 };
    var fixture: Fixture = .{};
    var page: Self = .{ .backend = fixture.backend(), .version = "unreleased" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |unicode| for ([_]bool{ false, true }) |fail_read| for ([_]u16{ 46, 99 }) |width| {
        fixture.unicode = unicode;
        fixture.fail_read = fail_read;
        try page.refresh();
        const reads = fixture.read_calls;
        for ([_]Case{
            .{ .memory = null, .expected = null },
            .{ .memory = .{ .rui = 38 * view.mib, .tools = null }, .expected = "Memory          rui 38 MB" },
            .{ .memory = .{ .rui = 38 * view.mib, .tools = 120 * view.mib }, .expected = if (unicode) "Memory          rui 38 MB · tools 120 MB" else "Memory          rui 38 MB . tools 120 MB" },
            .{ .memory = .{ .rui = 1024 * view.mib, .tools = null }, .expected = "Memory          rui 1.0 GB" },
            .{ .memory = null, .expected = null },
        }) |case| {
            fixture.memory_value = case.memory;
            const surface = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 20 }, .cell_size = .{} });
            const body = surface.children[0].surface;
            var text: std.Io.Writer.Allocating = .init(arena.allocator());
            for (0..body.size.height) |y| {
                for (0..body.size.width) |x| try text.writer.writeAll(body.readCell(@intCast(x), @intCast(y)).char.grapheme);
                try text.writer.writeByte('\n');
            }
            if (case.expected) |expected| {
                try std.testing.expect(std.mem.indexOf(u8, text.written(), expected) != null);
            } else try std.testing.expect(std.mem.indexOf(u8, text.written(), "Memory") == null);
            try std.testing.expectEqual(case.memory != null, page.fields[@backingInt(Row.memory)].visible);
            try std.testing.expect(!page.fields[@backingInt(Row.memory)].selectable);
            try std.testing.expect(std.mem.indexOf(u8, text.written(), "Version         unreleased") != null);
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            page.select(.version);
            try press(&page, &ctx, vaxis.Key.down);
            try std.testing.expectEqual(@as(usize, @backingInt(Row.keys)), page.panel.selected);
            try press(&page, &ctx, vaxis.Key.up);
            try std.testing.expectEqual(@as(usize, @backingInt(Row.version)), page.panel.selected);
            try std.testing.expectEqual(reads, fixture.read_calls);
            try std.testing.expectEqual(@as(usize, 0), fixture.save_calls);
            _ = arena.reset(.retain_capacity);
        }
    };
}

test "Tab wraps only drawn selectable targets and inline choices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    const fields = [_]Panel.Field{
        .{ .label = "one", .value = "1" },
        .{ .label = "hidden", .value = "2", .visible = false },
        .{ .label = "fact", .value = "3", .selectable = false },
        .{ .label = "four", .value = "4" },
    };
    var panel: Panel = .{ .title = "Settings", .fields = &fields, .actions = &.{"Done"} };
    const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 10 }, .cell_size = .{} };
    _ = try panel.widget().draw(draw_ctx);
    try panel.traverse(&ctx, false, @import("app_input.zig").tabNextValue);
    try std.testing.expectEqual(@as(usize, 3), panel.selected);
    try panel.traverse(&ctx, false, @import("app_input.zig").tabNextValue);
    try std.testing.expectEqual(@as(usize, 4), panel.selected);
    try panel.traverse(&ctx, false, @import("app_input.zig").tabNextValue);
    try std.testing.expectEqual(@as(usize, 0), panel.selected);
    try panel.traverse(&ctx, true, @import("app_input.zig").tabNextValue);
    try std.testing.expectEqual(@as(usize, 4), panel.selected);
    panel.selected = 0;
    panel.openChoice(&.{ "yes", "no" }, 0);
    _ = try panel.widget().draw(draw_ctx);
    try panel.traverse(&ctx, true, @import("app_input.zig").tabNextValue);
    try std.testing.expectEqual(@as(usize, 1), panel.choice.?.selected);
    try std.testing.expectEqual(@as(usize, 0), panel.selected);
    _ = try panel.widget().draw(draw_ctx.withConstraints(.{}, .{ .width = 0, .height = 0 }));
    try panel.traverse(&ctx, false, @import("app_input.zig").tabNextValue);
    try std.testing.expectEqual(@as(usize, 1), panel.choice.?.selected);
}

test "Keys scrolls every shortcut within the retained draft viewport" {
    const keymap = @import("keymap.zig");
    for ([_]u16{ 46, 140 }) |width| for ([_]u16{ 12, 20 }) |height| for ([_][]const u8{ "", "one\ntwo\nthree\nfour\nfive\nsix" }) |draft| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var page: Self = .{ .reference_open = true };
        var storage: [128]u8 = undefined;
        var editor: @import("DraftEditor.zig") = .initText(&storage, draft, draft.len);
        var input: @import("InputArea.zig") = .{
            .composer = .{ .editor = &editor, .caret = false },
            .panel = .{ .full = page.widget() },
            .facts = page.footerWidget(),
            .status = null,
        };
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} };
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var seen: [keymap.list.len]bool = undefined;
        @memset(&seen, false);
        while (true) {
            const shown = try input.widget().draw(draw_ctx);
            const surface = shown.children[0].surface.children[0].surface;
            try std.testing.expect(page.reference_height > 0);
            const columns: usize = if (page.reference_rows == keymap.list.len) 1 else 2;
            for (0..page.reference_height) |row| {
                var line: std.Io.Writer.Allocating = .init(arena.allocator());
                for (0..surface.size.width) |col| try line.writer.writeAll(surface.readCell(@intCast(col), @intCast(row)).char.grapheme);
                for (0..columns) |column| {
                    const index = (page.reference_offset + row) * columns + column;
                    if (index >= keymap.list.len) continue;
                    try std.testing.expect(std.mem.indexOf(u8, line.written(), keymap.list[index].key) != null);
                    try std.testing.expect(std.mem.indexOf(u8, line.written(), keymap.list[index].meaning) != null);
                    seen[index] = true;
                }
            }
            try std.testing.expectEqualStrings(draft, editor.text());
            try std.testing.expectEqual(draft.len, editor.cursor());
            if (page.reference_offset == page.reference_rows -| page.reference_height) break;
            try press(&page, &events, vaxis.Key.down);
            try std.testing.expect(events.consume_event);
        }
        for (seen) |visible| try std.testing.expect(visible);
        const bottom = page.reference_offset;
        try press(&page, &events, vaxis.Key.down);
        try std.testing.expectEqual(bottom, page.reference_offset);
        try press(&page, &events, vaxis.Key.page_up);
        try std.testing.expectEqual(bottom -| page.reference_height, page.reference_offset);
        try press(&page, &events, vaxis.Key.page_down);
        try std.testing.expectEqual(bottom, page.reference_offset);
        try press(&page, &events, vaxis.Key.up);
        try std.testing.expectEqual(bottom -| 1, page.reference_offset);
        try press(&page, &events, vaxis.Key.page_up);
        while (page.reference_offset != 0) try press(&page, &events, vaxis.Key.page_up);
        try press(&page, &events, vaxis.Key.up);
        try std.testing.expectEqual(@as(usize, 0), page.reference_offset);
        try std.testing.expectEqualStrings(draft, editor.text());
        try std.testing.expectEqual(draft.len, editor.cursor());
    };
}

test "Keys reclamps on resize and starts at the top when reopened" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var page: Self = .{};
    try page.refresh();
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    page.select(.keys);
    try press(&page, &events, vaxis.Key.enter);
    try std.testing.expect(page.reference_open);
    const narrow: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 46, .height = 4 }, .cell_size = .{} };
    const wide: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 4 }, .cell_size = .{} };
    const tall: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 20 }, .cell_size = .{} };
    _ = try page.widget().draw(narrow);
    while (page.reference_offset < page.reference_rows -| page.reference_height) try press(&page, &events, vaxis.Key.page_down);
    const narrow_bottom = page.reference_offset;
    try std.testing.expect(narrow_bottom > 0);
    _ = try page.widget().draw(wide);
    try std.testing.expect(page.reference_rows -| page.reference_height < narrow_bottom);
    try std.testing.expectEqual(page.reference_rows -| page.reference_height, page.reference_offset);
    _ = try page.widget().draw(tall);
    try std.testing.expectEqual(@as(usize, 0), page.reference_offset);
    _ = try page.widget().draw(narrow);
    try press(&page, &events, vaxis.Key.down);
    try std.testing.expectEqual(@as(usize, 1), page.reference_offset);
    page.reference_open = false;
    page.select(.keys);
    try press(&page, &events, vaxis.Key.enter);
    try std.testing.expect(page.reference_open);
    try std.testing.expectEqual(@as(usize, 0), page.reference_offset);
}

test "SUI-182 App settings Connections opens a read-only reference of each served connection and its usage" {
    const now: u64 = 1_800_000_000;
    var snapshot: ConnectionsSnapshot = .{ .facts = .{}, .now = now };
    snapshot.facts.items[0] = .{ .name = connection.Name.parse("work").?, .label = provider_route.Label.parse("ChatGPT (device code)").?, .route = .chatgpt_device, .usage = .{ .observed_at = now - 120, .primary = .{ .used_percent = 40, .minutes = 10080, .reset_at = now + 86400 }, .secondary = null } };
    snapshot.facts.items[1] = .{ .name = connection.Name.parse("home").?, .label = provider_route.Label.parse("ChatGPT").?, .route = .chatgpt_plan };
    snapshot.facts.len = 2;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]?ConnectionsSnapshot{ snapshot, null }) |read| {
        var fixture: Fixture = .{ .snapshot = read };
        var page: Self = .{ .backend = fixture.backend() };
        try page.refresh();
        page.bind();
        try std.testing.expectEqualStrings("Connections", page.fields[@backingInt(Row.connections)].label);
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        page.select(.connections);
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.reference_open);
        const drawn = try page.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 120, .height = 6 }, .cell_size = .{} });
        var text: std.Io.Writer.Allocating = .init(arena.allocator());
        for (0..2) |row| {
            for (0..drawn.size.width) |col| try text.writer.writeAll(drawn.readCell(@intCast(col), @intCast(row)).char.grapheme);
            try text.writer.writeByte('\n');
        }
        if (read != null) {
            try std.testing.expect(std.mem.indexOf(u8, text.written(), "work") != null);
            try std.testing.expect(std.mem.indexOf(u8, text.written(), "weekly 40% used · resets in 1 d 0 h") != null);
            try std.testing.expect(std.mem.indexOf(u8, text.written(), "usage not shown for browser sign-ins") != null);
        } else try std.testing.expect(std.mem.indexOf(u8, text.written(), "the Host cannot be read") != null);
        // The reference is read-only: Enter changes nothing and Escape-free input keeps it open.
        try press(&page, &ctx, vaxis.Key.enter);
        try std.testing.expect(page.reference_open);
        try std.testing.expectEqual(@as(usize, 0), fixture.save_calls);
    }
}
