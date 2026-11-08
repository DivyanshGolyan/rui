//! One vxfw runtime owns the interactive terminal. Host jobs return values;
//! their borrowers are joined before any draft or observation is destroyed.
const std = @import("std");
const vaxis = @import("vaxis");
const fw = vaxis.vxfw;
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Overview = @import("Overview.zig");
const observations = @import("NativeObservations.zig");
const NativeFeed = @import("NativeFeed.zig");
const Task = @import("ClientTask.zig");
const Submission = @import("SessionSubmission.zig");
const defaults = @import("product_defaults.zig");
const stderr = @import("stderr.zig");
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

const ReadKind = union(enum) { list, conversation: struct {
    id: Id,
    epoch: u64,
    since: ?@import("protocol_reply.zig").SessionToken,
    after: ?@import("protocol_reply.zig").ActivityCursor,
    instance: ?protocol.InstanceId,
    refresh: bool,
} };
const ReadResult = union(enum) { list: []observations.Row, conversation: ?observations.Conversation };

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
content: NativeFeed = .{},
feed_index: fw.Text.LineIndex = .{},
feed_index_dirty: bool = true,
feed_token: ?@import("protocol_reply.zig").SessionToken = null,
feed_cursor: ?@import("protocol_reply.zig").ActivityCursor = null,
feed_instance: ?protocol.InstanceId = null,
feed_force_refresh: bool = false,
feed_stale: bool = false,
feed_epoch: u64 = 0,
following: bool = true,
body_width: u16 = 0,
body_bottom: u16 = 0,
header: fw.Text = .{ .text = "" },
status: fw.Text = .{ .text = "" },
border: fw.Border = undefined,
notice: []const u8 = "",
notice_buffer: [256]u8 = undefined,
pasting: bool = false,
worker: Task = .{},
read_kind: ReadKind = .list,
read_arena: ?*std.heap.ArenaAllocator = null,
read_result: ?ReadResult = null,
read_refreshing: std.atomic.Value(bool) = .init(false),
list_arena: ?*std.heap.ArenaAllocator = null,
old_list_arena: ?*std.heap.ArenaAllocator = null,
feed_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
old_feed_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
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
    const was_pending = self.submission.view() != null;
    self.submission.cancel();
    _ = self.submission.join();
    if (was_pending) self.recoveryGuide();
    self.submission.close();
    self.freeArena(self.read_arena);
    self.freeArena(self.list_arena);
    self.freeArena(self.old_list_arena);
    self.feed_index.deinit(self.init.gpa);
    self.freeFeedArenas(&self.feed_arenas);
    self.freeFeedArenas(&self.old_feed_arenas);
    self.content.deinit(self.init.gpa);
    var values = self.drafts.valueIterator();
    while (values.next()) |value| value.*.destroy(self.init.gpa);
    self.drafts.deinit();
    self.overview_draft.destroy(self.init.gpa);
    self.scratch.close(self.init.io);
}

fn recoveryGuide(self: *Self) void {
    switch (self.submission.recovery()) {
        .none => {},
        .not_sent => stderr.diagnostic("rui: Message was not sent; no recovery record was published.\n", .{}),
        .uncertain => |key| stderr.diagnostic("rui: Capture not confirmed. Inspect rui request list for reserved key {s}; recover only that original, never replacement input.\n", .{key}),
        .saved => |saved| if (saved.rejected) {
            stderr.diagnostic("rui: Original request rejected. Use rui request inspect {s}.\n", .{saved.original.key});
        } else {
            stderr.diagnostic("rui: Message not confirmed. Use rui request recover {s}; do not resubmit it.\n", .{saved.original.key});
        },
        .accepted => |accepted| stderr.diagnostic("rui: Message accepted; do not resubmit it. Use rui request read-result {s}.\n", .{accepted.key}),
    }
}

fn freeArena(self: *Self, arena: ?*std.heap.ArenaAllocator) void {
    const value = arena orelse return;
    value.deinit();
    self.init.gpa.destroy(value);
}

fn freeFeedArenas(self: *Self, arenas: *std.ArrayList(*std.heap.ArenaAllocator)) void {
    for (arenas.items) |arena| self.freeArena(arena);
    arenas.deinit(self.init.gpa);
    arenas.* = .empty;
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

fn startRead(self: *Self) !void {
    if (self.worker.thread != null) return;
    const arena = try self.init.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(self.init.gpa);
    self.read_arena = arena;
    self.read_result = null;
    self.read_refreshing.store(false, .release);
    self.read_kind = if (self.destination) |id| .{ .conversation = .{ .id = id, .epoch = self.feed_epoch, .since = self.feed_token, .after = self.feed_cursor, .instance = self.feed_instance, .refresh = self.feed_force_refresh } } else .list;
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
        .conversation => |conversation| .{ .conversation = try observations.conversation(alloc, task.requests(), self.options.store, &conversation.id, if (conversation.refresh) null else conversation.since, if (conversation.refresh) null else conversation.after, conversation.instance, conversation.refresh, &self.read_refreshing) },
    };
}

fn completeRead(self: *Self, ctx: *fw.EventContext) !void {
    if (self.worker.thread == null or !self.worker.completed()) return;
    self.worker.join() catch |err| {
        const relevant = switch (self.read_kind) {
            .list => self.destination == null,
            .conversation => |conversation| self.destination != null and conversation.epoch == self.feed_epoch and std.mem.eql(u8, &self.destination.?, &conversation.id),
        };
        if (relevant) {
            if (self.read_kind == .conversation) {
                self.feed_stale = true;
                self.feed_force_refresh = true;
            } else self.notice = @errorName(err);
            ctx.redraw = true;
        }
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
            ctx.redraw = true;
            if (selected) |id| for (rows, 0..) |row, index| {
                if (std.mem.eql(u8, &row.id, &id)) {
                    self.list.jumpToItem(@intCast(index));
                    break;
                }
            };
            if (self.list.cursor >= rows.len) self.list.jumpToItem(@intCast(rows.len -| 1));
        },
        .conversation => |maybe_conversation| {
            const id = self.read_kind.conversation.id;
            if (self.destination == null or self.read_kind.conversation.epoch != self.feed_epoch or !std.mem.eql(u8, &self.destination.?, &id)) {
                self.freeArena(arena);
                return;
            }
            const conversation = maybe_conversation orelse {
                self.freeArena(arena);
                return;
            };
            const blocks = conversation.blocks;
            if (conversation.refresh) {
                var fresh: NativeFeed = .{};
                errdefer fresh.deinit(self.init.gpa);
                try fresh.append(self.init.gpa, arena.allocator(), blocks);
                var arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty;
                errdefer arenas.deinit(self.init.gpa);
                if (blocks.len != 0) try arenas.append(self.init.gpa, arena);
                self.freeFeedArenas(&self.old_feed_arenas);
                self.old_feed_arenas = self.feed_arenas;
                self.feed_arenas = arenas;
                self.content.deinit(self.init.gpa);
                self.content = fresh;
                if (blocks.len == 0) self.freeArena(arena);
                self.feed_index_dirty = true;
                ctx.redraw = true;
            } else if (blocks.len != 0) {
                try self.feed_arenas.ensureUnusedCapacity(self.init.gpa, 1);
                try self.content.append(self.init.gpa, arena.allocator(), blocks);
                self.feed_arenas.appendAssumeCapacity(arena);
                self.feed_index_dirty = true;
                ctx.redraw = true;
            } else self.freeArena(arena);
            self.feed_cursor = conversation.cursor;
            self.feed_token = conversation.token;
            self.feed_instance = conversation.instance;
            self.feed_force_refresh = false;
            if (self.feed_stale) {
                self.feed_stale = false;
                ctx.redraw = true;
            }
        },
    }
}

fn open(self: *Self, id: Id, ctx: *fw.EventContext) !void {
    _ = try self.getDraft(id);
    self.destination = id;
    self.feed_epoch +%= 1;
    self.following = true;
    self.content.clearRetainingCapacity();
    self.freeFeedArenas(&self.old_feed_arenas);
    self.old_feed_arenas = self.feed_arenas;
    self.feed_arenas = .empty;
    self.feed_index_dirty = true;
    self.feed_token = null;
    self.feed_cursor = null;
    self.feed_instance = null;
    self.feed_force_refresh = false;
    self.feed_stale = false;
    self.feed.scroll_view = .{ .children = .{ .slice = &.{} }, .item_count = 0 };
    try ctx.requestFocus(self.activeDraft().field.widget());
    ctx.redraw = true;
}

fn back(self: *Self, ctx: *fw.EventContext) !void {
    self.destination = null;
    self.feed_epoch +%= 1;
    try ctx.requestFocus(self.overview_draft.field.widget());
    ctx.redraw = true;
}

fn showOriginal(self: *Self) void {
    const original = self.submission.view() orelse return;
    if (!self.submission.target_reserved) {
        self.notice = "Original not sent · Ctrl-R retry · Ctrl-D discard";
        return;
    }
    const action = switch (original.state) {
        .rejected => "refused · Ctrl-D discard",
        .not_started => "not sent · Ctrl-R retry · Ctrl-D discard",
        .submitting => "sending · draft retained",
        .unconfirmed => "unconfirmed · Ctrl-R retry",
    };
    self.notice = std.fmt.bufPrint(&self.notice_buffer, "{s} {s}", .{ original.key, action }) catch unreachable;
}

fn submit(self: *Self) !void {
    if (self.submission.view() != null) {
        self.showOriginal();
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
        if (self.submission.view() != null) self.showOriginal() else self.notice = @errorName(err);
        return;
    };
    self.notice = "Sending…";
}

fn finishSubmission(self: *Self, ctx: *fw.EventContext) !void {
    const end = self.submission.advance() catch {
        self.showOriginal();
        ctx.redraw = true;
        return;
    };
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
            self.showOriginal();
            ctx.redraw = true;
        },
        .failed => {
            self.showOriginal();
            ctx.redraw = true;
        },
    }
}

fn capture(raw: *anyopaque, ctx: *fw.EventContext, value: fw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (value) {
        .paste_start => self.pasting = true,
        .paste_end => self.pasting = false,
        .mouse => |mouse| if (self.destination != null) {
            const wheel = mouse.button == .wheel_up or mouse.button == .wheel_down;
            const scrollbar = self.body_width != 0 and mouse.col == self.body_width - 1 and mouse.row > 0 and mouse.row < self.body_bottom and (mouse.type == .press or mouse.type == .drag);
            if (wheel or scrollbar) self.following = false;
        },
        .key_press => |key| {
            if (!self.pasting and key.matches('r', .{ .ctrl = true })) {
                if (self.submission.view()) |original| {
                    if (original.state != .rejected) {
                        try self.submission.requestRecovery(null);
                        self.notice = "Retrying original; draft retained";
                    } else self.showOriginal();
                }
                ctx.consumeAndRedraw();
                return;
            }
            if (!self.pasting and key.matches('d', .{ .ctrl = true })) {
                if (self.submission.view()) |original| {
                    if (original.state == .rejected or original.state == .not_started) {
                        try self.submission.discardUnsentOrRejected();
                        self.submitted_draft = null;
                        self.notice = "Original released; draft retained";
                        ctx.consumeAndRedraw();
                        return;
                    }
                }
            }
            if (!self.pasting and key.matches('q', .{ .ctrl = true })) {
                if (self.submission.task.thread != null) {
                    self.submission.cancel();
                    self.notice = "Cancelling local wait; original may already be admitted";
                } else switch (self.submission.recovery()) {
                    .not_sent => self.notice = "Original not saved; Ctrl-R retry or Ctrl-D discard before quit",
                    .uncertain => self.notice = "Capture uncertain; Ctrl-R retry before quit",
                    else => ctx.quit = true,
                }
                ctx.consumeAndRedraw();
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
            if (self.destination != null and key.matches(vaxis.Key.home, .{ .ctrl = true })) {
                self.following = false;
                self.feed.scroll_view.cursor = 0;
                self.feed.scroll_view.ensureScroll();
                ctx.consumeAndRedraw();
                return;
            }
            if (self.destination != null and key.matches(vaxis.Key.escape, .{})) {
                if (!self.following) {
                    self.following = true;
                    if (self.content.widgets.items.len != 0) {
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
            if (self.worker.thread != null and self.read_refreshing.load(.acquire)) switch (self.read_kind) {
                .conversation => |conversation| if (self.destination != null and conversation.epoch == self.feed_epoch and std.mem.eql(u8, &self.destination.?, &conversation.id) and !self.feed_stale) {
                    self.feed_stale = true;
                    ctx.redraw = true;
                },
                .list => {},
            };
            try self.completeRead(ctx);
            try self.finishSubmission(ctx);
            if (self.worker.thread == null) self.startRead() catch |err| {
                self.notice = @errorName(err);
            };
            try ctx.tick(500, self.widget());
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
    self.header.text = if (self.destination) |id| (if (self.feed_stale)
        try std.fmt.allocPrint(ctx.arena, "Session {s}  ·  History may be stale · Esc returns", .{&id})
    else
        try std.fmt.allocPrint(ctx.arena, "Session {s}  ·  Esc returns", .{&id})) else "Sessions  ·  Alt-↑/↓ select · Alt-Enter open";
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
    self.body_width = width;
    self.body_bottom = 1 + body_height;
    const body_ctx = ctx.withConstraints(.{ .width = width, .height = body_height }, .{ .width = width, .height = body_height });
    if (self.destination != null and body_height != 0) {
        const content_width = width -| @intFromBool(self.feed.draw_vertical_scrollbar);
        if (self.feed_index_dirty or self.feed_index.width == null or self.feed_index.width.? != content_width) {
            try self.feed_index.reflow(self.init.gpa, self.content.widgets.items, body_ctx.withConstraints(.{ .width = content_width }, .{ .width = content_width, .height = null }));
            self.feed_index_dirty = false;
            self.feed.scroll_view.children = .{ .builder = self.feed_index.builder() };
            self.feed.scroll_view.item_count = @intCast(self.feed_index.lines.items.len);
            self.feed.estimated_content_height = @intCast(self.feed_index.lines.items.len);
        }
        if (self.following) self.feed.scroll_view.jumpToEnd();
    }
    const body = if (self.destination == null) try self.list.draw(body_ctx) else try self.feed.draw(body_ctx);
    const children = try ctx.arena.alloc(fw.SubSurface, 4);
    children[0] = .{ .origin = .{ .col = 0, .row = 0 }, .surface = header, .z_index = 0 };
    children[1] = .{ .origin = .{ .col = 0, .row = 1 }, .surface = body, .z_index = 0 };
    children[2] = .{ .origin = .{ .col = 0, .row = @intCast(1 + body_height) }, .surface = composer, .z_index = 0 };
    children[3] = .{ .origin = .{ .col = 0, .row = height - 1 }, .surface = status, .z_index = 0 };
    return fw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, children);
}
