//! One vxfw runtime owns the interactive terminal. Host jobs return values;
//! their borrowers are joined before any draft or observation is destroyed.
const std = @import("std");
const vaxis = @import("vaxis");
const fw = vaxis.vxfw;
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Overview = @import("Overview.zig");
const observations = @import("NativeObservations.zig");
const Task = @import("ClientTask.zig");
const Submission = @import("SessionSubmission.zig");
const defaults = @import("product_defaults.zig");
const Self = @This();
const Id = [protocol.session_id_bytes]u8;

const Draft = struct {
    field: fw.TextField,
    revision: u64 = 0,

    fn create(allocator: std.mem.Allocator) !*Draft {
        const draft = try allocator.create(Draft);
        draft.* = .{ .field = fw.TextField.init(allocator) };
        draft.field.multiline = true;
        draft.field.userdata = draft;
        draft.field.onChange = changed;
        return draft;
    }

    fn changed(raw: ?*anyopaque, _: *fw.EventContext, _: []const u8) !void {
        const draft: *Draft = @ptrCast(@alignCast(raw.?));
        draft.revision +%= 1;
    }

    fn destroy(self: *Draft, allocator: std.mem.Allocator) void {
        self.field.deinit();
        allocator.destroy(self);
    }
};

const RowWidget = struct {
    owner: *Self,
    row: observations.Row,
    index: usize,

    fn widget(self: *RowWidget) fw.Widget {
        return .{ .userdata = self, .eventHandler = RowWidget.event, .drawFn = RowWidget.draw };
    }
    fn event(raw: *anyopaque, ctx: *fw.EventContext, value: fw.Event) !void {
        const self: *RowWidget = @ptrCast(@alignCast(raw));
        if (value == .mouse and value.mouse.type == .press and value.mouse.button == .left) {
            try self.owner.open(self.row.id, ctx);
            ctx.consumeAndRedraw();
        }
    }
    fn draw(raw: *anyopaque, ctx: fw.DrawContext) std.mem.Allocator.Error!fw.Surface {
        const self: *RowWidget = @ptrCast(@alignCast(raw));
        const glyph: []const u8 = switch (self.row.category) {
            0, 2 => "●",
            4 => "□",
            else => "○",
        };
        const age = if (self.row.updated_at) |when| blk: {
            const now: u64 = @intCast(@max(0, std.Io.Clock.real.now(self.owner.init.io).toSeconds()));
            break :blk try std.fmt.allocPrint(ctx.arena, "{d}s ago", .{now -| when});
        } else "unknown";
        const line = try std.fmt.allocPrint(ctx.arena, "{s} {s}  {s}  {s}", .{ glyph, self.row.name, self.row.directory, age });
        const text: fw.Text = .{ .text = line, .softwrap = false, .width_basis = .parent, .style = .{ .reverse = self.index == self.owner.list.cursor } };
        var surface = try text.draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};

const FeedWidget = struct {
    text: fw.Text,

    fn widget(self: *FeedWidget) fw.Widget {
        return .{ .userdata = self, .drawFn = FeedWidget.draw };
    }

    fn draw(raw: *anyopaque, ctx: fw.DrawContext) std.mem.Allocator.Error!fw.Surface {
        const self: *FeedWidget = @ptrCast(@alignCast(raw));
        return self.text.draw(ctx.withConstraints(ctx.min, .{ .width = ctx.min.width, .height = null }));
    }
};

const ReadKind = union(enum) { list, conversation: Id };
const ReadResult = union(enum) { list: []observations.Row, conversation: []observations.Block };

init: std.process.Init,
options: Overview.Options,
hooks: Overview.Hooks,
scratch: std.Io.File,
overview_draft: *Draft,
drafts: std.AutoHashMap(Id, *Draft),
destination: ?Id = null,
list: fw.ListView = .{ .children = .{ .slice = &.{} }, .item_count = 0, .draw_cursor = false },
rows: []*RowWidget = &.{},
feed: fw.ScrollBars = .{ .scroll_view = .{ .children = .{ .slice = &.{} }, .item_count = 0 }, .draw_horizontal_scrollbar = true },
blocks: []FeedWidget = &.{},
following: bool = true,
header: fw.Text = .{ .text = "" },
status: fw.Text = .{ .text = "" },
border: fw.Border = undefined,
notice: []const u8 = "",
pasting: bool = false,
worker: Task = .{},
read_kind: ReadKind = .list,
read_arena: ?*std.heap.ArenaAllocator = null,
read_result: ?ReadResult = null,
list_arena: ?*std.heap.ArenaAllocator = null,
old_list_arena: ?*std.heap.ArenaAllocator = null,
feed_arena: ?*std.heap.ArenaAllocator = null,
old_feed_arena: ?*std.heap.ArenaAllocator = null,
submission: Submission,
submitted_draft: ?*Draft = null,
submitted_revision: u64 = 0,
submitted_destination: ?Id = null,
submitted_session: Id = @splat(0),
compaction: [20]u8 = undefined,

pub fn run(init: std.process.Init, options: Overview.Options, hooks: Overview.Hooks) !void {
    const self = try init.gpa.create(Self);
    defer init.gpa.destroy(self);
    const scratch = try hooks.scratch(init);
    const draft = Draft.create(init.gpa) catch |err| {
        scratch.close(init.io);
        return err;
    };
    self.* = .{
        .init = init,
        .options = options,
        .hooks = hooks,
        .scratch = scratch,
        .overview_draft = draft,
        .drafts = std.AutoHashMap(Id, *Draft).init(init.gpa),
        .submission = .{ .io = init.io, .store = options.store, .session = "", .directory = options.directory, .environment = .{ .map = init.environ_map } },
    };
    defer self.deinit();
    if (options.open) |id| {
        self.destination = id;
        _ = try self.getDraft(id);
    }
    var tty_buffer: [65536]u8 = undefined;
    var app = try fw.App.init(init.io, init.gpa, init.environ_map, &tty_buffer);
    defer app.deinit();
    try app.run(self.widget(), .{});
}

fn deinit(self: *Self) void {
    self.worker.cancel();
    self.worker.join() catch {};
    self.submission.cancel();
    _ = self.submission.join();
    self.submission.close();
    self.freeArena(self.read_arena);
    self.freeArena(self.list_arena);
    self.freeArena(self.old_list_arena);
    self.freeArena(self.feed_arena);
    self.freeArena(self.old_feed_arena);
    var values = self.drafts.valueIterator();
    while (values.next()) |value| value.*.destroy(self.init.gpa);
    self.drafts.deinit();
    self.overview_draft.destroy(self.init.gpa);
    self.scratch.close(self.init.io);
}

fn freeArena(self: *Self, arena: ?*std.heap.ArenaAllocator) void {
    const value = arena orelse return;
    value.deinit();
    self.init.gpa.destroy(value);
}

fn getDraft(self: *Self, id: Id) !*Draft {
    if (self.drafts.get(id)) |found| return found;
    const made = try Draft.create(self.init.gpa);
    errdefer made.destroy(self.init.gpa);
    try self.drafts.put(id, made);
    return made;
}

fn activeDraft(self: *Self) *Draft {
    return if (self.destination) |id| self.drafts.get(id).? else self.overview_draft;
}

fn widget(self: *Self) fw.Widget {
    return .{ .userdata = self, .captureHandler = capture, .eventHandler = event, .drawFn = draw };
}

fn rowAt(raw: *const anyopaque, index: usize, _: usize) ?fw.Widget {
    const self: *Self = @ptrCast(@alignCast(@constCast(raw)));
    if (index >= self.rows.len) return null;
    return self.rows[index].widget();
}

fn blockAt(raw: *const anyopaque, index: usize, _: usize) ?fw.Widget {
    const self: *Self = @ptrCast(@alignCast(@constCast(raw)));
    if (index >= self.blocks.len) return null;
    return self.blocks[index].widget();
}

fn startRead(self: *Self) !void {
    if (self.worker.thread != null) return;
    const arena = try self.init.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(self.init.gpa);
    self.read_arena = arena;
    self.read_result = null;
    self.read_kind = if (self.destination) |id| .{ .conversation = id } else .list;
    self.worker.start(self.init.io, self, readWork) catch |err| {
        self.freeArena(self.read_arena);
        self.read_arena = null;
        return err;
    };
}

fn readWork(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const alloc = self.read_arena.?.allocator();
    self.read_result = switch (self.read_kind) {
        .list => .{ .list = try observations.list(alloc, task.requests(), self.options.store, self.scratch) },
        .conversation => |id| .{ .conversation = try observations.conversation(alloc, task.requests(), self.options.store, &id) },
    };
}

fn completeRead(self: *Self) !void {
    if (self.worker.thread == null or !self.worker.completed()) return;
    self.worker.join() catch |err| {
        self.notice = @errorName(err);
        self.freeArena(self.read_arena);
        self.read_arena = null;
        return;
    };
    const arena = self.read_arena.?;
    self.read_arena = null;
    errdefer self.freeArena(arena);
    switch (self.read_result.?) {
        .list => |rows| {
            if (self.destination != null) {
                self.freeArena(arena);
                return;
            }
            const selected: ?Id = if (self.list.cursor < self.rows.len) self.rows[self.list.cursor].row.id else null;
            const widgets = try arena.allocator().alloc(*RowWidget, rows.len);
            for (rows, 0..) |row, index| {
                const entry = try arena.allocator().create(RowWidget);
                entry.* = .{ .owner = self, .row = row, .index = index };
                widgets[index] = entry;
            }
            self.freeArena(self.old_list_arena);
            self.old_list_arena = self.list_arena;
            self.list_arena = arena;
            self.rows = widgets;
            self.list.children = .{ .builder = .{ .userdata = self, .buildFn = rowAt } };
            self.list.item_count = @intCast(rows.len);
            if (selected) |id| for (rows, 0..) |row, index| {
                if (std.mem.eql(u8, &row.id, &id)) {
                    self.list.jumpToItem(@intCast(index));
                    break;
                }
            };
            if (self.list.cursor >= rows.len) self.list.jumpToItem(@intCast(rows.len -| 1));
        },
        .conversation => |blocks| {
            const id = self.read_kind.conversation;
            if (self.destination == null or !std.mem.eql(u8, &self.destination.?, &id)) {
                self.freeArena(arena);
                return;
            }
            const widgets = try arena.allocator().alloc(FeedWidget, blocks.len);
            for (blocks, widgets) |block, *item| {
                const prefix = if (block.kind == .user) "You\n" else "Assistant\n";
                item.* = .{ .text = .{ .text = try std.fmt.allocPrint(arena.allocator(), "{s}{s}\n", .{ prefix, block.display }), .softwrap = true, .width_basis = .parent } };
            }
            self.freeArena(self.old_feed_arena);
            self.old_feed_arena = self.feed_arena;
            self.feed_arena = arena;
            self.blocks = widgets;
            self.feed.scroll_view.children = .{ .builder = .{ .userdata = self, .buildFn = blockAt } };
            self.feed.scroll_view.item_count = @intCast(widgets.len);
            if (self.following and widgets.len != 0) {
                self.feed.scroll_view.jumpToEnd();
            }
        },
    }
}

fn open(self: *Self, id: Id, ctx: *fw.EventContext) !void {
    _ = try self.getDraft(id);
    self.destination = id;
    self.following = true;
    self.blocks = &.{};
    self.feed.scroll_view = .{ .children = .{ .slice = &.{} }, .item_count = 0 };
    try ctx.requestFocus(self.activeDraft().field.widget());
    ctx.redraw = true;
}

fn back(self: *Self, ctx: *fw.EventContext) !void {
    self.destination = null;
    try ctx.requestFocus(self.overview_draft.field.widget());
    ctx.redraw = true;
}

fn submit(self: *Self) !void {
    if (self.submission.view() != null) {
        self.notice = "Original pending; draft retained";
        return;
    }
    const current = self.activeDraft();
    const text = try current.field.snapshot();
    defer self.init.gpa.free(text);
    if (text.len == 0) return;
    self.submitted_destination = self.destination;
    self.submitted_draft = current;
    self.submitted_revision = current.revision;
    self.submission.session = if (self.destination) |id| blk: {
        self.submitted_session = id;
        break :blk &self.submitted_session;
    } else "";
    self.submission.configuration = null;
    self.submission.captured_hook = null;
    if (self.destination == null) {
        const provider = self.options.provider orelse defaults.provider;
        const model = self.options.model orelse defaults.recommended_model;
        const compaction = try std.fmt.bufPrint(&self.compaction, "{d}", .{client.defaultCompactionTrigger(std.meta.stringToEnum(protocol.Provider, provider) orelse .codex, model)});
        self.submission.configuration = .{ .store = self.options.store, .session = .create, .require_model = true, .workspace = .{ .present = true, .value = self.options.workspace }, .provider = .{ .present = true, .value = provider }, .model = .{ .present = true, .value = model }, .tools = defaults.tools, .permission_mode = .{ .present = true, .value = defaults.permission_mode }, .compaction_trigger = .{ .present = true, .value = compaction }, .reasoning_effort = client.defaultStartEffort(model, null) };
        self.submission.captured_hook = self.hooks.captured;
    }
    self.submission.begin(.{ .message = text }) catch |err| {
        self.notice = @errorName(err);
        return;
    };
    self.notice = "Sending…";
}

fn finishSubmission(self: *Self, ctx: *fw.EventContext) !void {
    const end = try self.submission.advance();
    switch (end) {
        .absent => {},
        .accepted => |accepted| {
            if (self.submitted_draft) |draft_| if (draft_.revision == self.submitted_revision) {
                draft_.field.clearRetainingCapacity();
                draft_.revision +%= 1;
            };
            self.notice = "Message accepted";
            if (self.submitted_destination == null and self.destination == null) if (accepted.session) |id| try self.open(id, ctx);
            self.submitted_draft = null;
            ctx.redraw = true;
        },
        .rejected => {
            self.notice = "Message refused; draft retained";
            ctx.redraw = true;
        },
        .failed => |failure| {
            self.notice = @errorName(failure.err);
            ctx.redraw = true;
        },
    }
}

fn capture(raw: *anyopaque, ctx: *fw.EventContext, value: fw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (value) {
        .paste_start => self.pasting = true,
        .paste_end => self.pasting = false,
        .mouse => |mouse| if (self.destination != null and (mouse.button == .wheel_up or mouse.button == .wheel_down)) {
            self.following = false;
        },
        .key_press => |key| {
            if (key.matches('q', .{ .ctrl = true })) {
                ctx.quit = true;
                ctx.consumeEvent();
                return;
            }
            if (self.destination == null and key.matches(vaxis.Key.up, .{ .alt = true })) {
                self.list.prevItem(ctx);
                return;
            }
            if (self.destination == null and key.matches(vaxis.Key.down, .{ .alt = true })) {
                self.list.nextItem(ctx);
                return;
            }
            if (self.destination == null and key.matches(vaxis.Key.enter, .{ .alt = true })) {
                if (self.list.cursor < self.rows.len) try self.open(self.rows[self.list.cursor].row.id, ctx);
                ctx.consumeAndRedraw();
                return;
            }
            if (self.destination != null and key.matches(vaxis.Key.escape, .{})) {
                if (!self.following) {
                    self.following = true;
                    if (self.blocks.len != 0) {
                        self.feed.scroll_view.jumpToEnd();
                    }
                } else try self.back(ctx);
                ctx.consumeAndRedraw();
                return;
            }
            if (self.destination != null and (key.matches(vaxis.Key.page_up, .{}) or key.matches(vaxis.Key.page_down, .{}))) {
                self.following = false;
                try self.feed.scroll_view.handleEvent(ctx, .{ .key_press = .{ .codepoint = if (key.matches(vaxis.Key.page_up, .{})) 'u' else 'd', .mods = .{ .ctrl = true } } });
                ctx.consumeAndRedraw();
                return;
            }
            if (!self.pasting and key.matches(vaxis.Key.enter, .{})) {
                try self.submit();
                ctx.consumeAndRedraw();
                return;
            }
        },
        else => {},
    }
}

fn event(raw: *anyopaque, ctx: *fw.EventContext, value: fw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (value) {
        .init => {
            try ctx.requestFocus(self.activeDraft().field.widget());
            try ctx.tick(100, self.widget());
            ctx.redraw = true;
        },
        .tick => {
            try self.completeRead();
            try self.finishSubmission(ctx);
            if (self.worker.thread == null) self.startRead() catch |err| {
                self.notice = @errorName(err);
            };
            try ctx.tick(500, self.widget());
            ctx.redraw = true;
        },
        .mouse => |mouse| if (self.destination != null and (mouse.button == .wheel_up or mouse.button == .wheel_down)) {
            self.following = false;
        },
        else => {},
    }
}

fn draw(raw: *anyopaque, ctx: fw.DrawContext) std.mem.Allocator.Error!fw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;
    if (width == 0 or height == 0) return fw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    self.header.text = if (self.destination) |id| try std.fmt.allocPrint(ctx.arena, "Session {s}  ·  Esc returns", .{&id}) else "Sessions  ·  Alt-↑/↓ select · Alt-Enter open";
    self.status.text = if (self.notice.len == 0) "Enter send · Shift-Enter or Ctrl-J newline · Ctrl-Q quit" else self.notice;
    const header = try self.header.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    const status = try self.status.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    self.border = .{ .child = self.activeDraft().field.widget() };
    const composer_max = height -| 2;
    const composer = if (width >= 2 and composer_max >= 3)
        try self.border.draw(ctx.withConstraints(.{}, .{ .width = width, .height = composer_max }))
    else
        try self.activeDraft().field.draw(ctx.withConstraints(.{}, .{ .width = width, .height = composer_max }));
    const body_height = height -| 2 -| composer.size.height;
    const body_ctx = ctx.withConstraints(.{ .width = width, .height = body_height }, .{ .width = width, .height = body_height });
    const body = if (self.destination == null) try self.list.draw(body_ctx) else try self.feed.draw(body_ctx);
    const children = try ctx.arena.alloc(fw.SubSurface, 4);
    children[0] = .{ .origin = .{ .col = 0, .row = 0 }, .surface = header, .z_index = 0 };
    children[1] = .{ .origin = .{ .col = 0, .row = 1 }, .surface = body, .z_index = 0 };
    children[2] = .{ .origin = .{ .col = 0, .row = @intCast(1 + body_height) }, .surface = composer, .z_index = 0 };
    children[3] = .{ .origin = .{ .col = 0, .row = height - 1 }, .surface = status, .z_index = 0 };
    return fw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, children);
}
