//! One vxfw runtime owns the interactive terminal. Host jobs return values;
//! their borrowers are joined before any draft or observation is destroyed.
const std = @import("std");
const vaxis = @import("vaxis");
const fw = vaxis.vxfw;
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Overview = @import("Overview.zig");
const observations = @import("NativeObservations.zig");
const NativePagedFeed = @import("NativePagedFeed.zig");
const replies = @import("protocol_reply.zig");
const Task = @import("ClientTask.zig");
const Submission = @import("SessionSubmission.zig");
const NativeAction = @import("NativeAction.zig");
const TerminalText = @import("TerminalText.zig");
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

const Arrival = enum { tail, older, newer, reflow };
const PageRequest = struct {
    cursor: replies.ActivityCursor,
    instance: ?protocol.InstanceId,
    arrival: Arrival,
};
const PageJob = union(enum) {
    load: struct {
        request: PageRequest,
        width: u16,
        anchor: ?NativePagedFeed.AnchorInput,
    },
    poll: *NativePagedFeed,
};
const ReadKind = union(enum) {
    list: u64,
    conversation: struct { id: Id, epoch: u64, job: PageJob },
    action: struct { ticket: NativeAction.Ticket, epoch: u64 },

    fn isCurrent(self: ReadKind, destination: ?Id, epoch: u64) bool {
        return switch (self) {
            .list => |started| destination == null and started == epoch,
            .conversation => |started| destination != null and started.epoch == epoch and std.mem.eql(u8, &destination.?, &started.id),
            .action => |started| destination != null and started.epoch == epoch and std.mem.eql(u8, &destination.?, &started.ticket.session),
        };
    }
};
const PageResult = struct { page: *NativePagedFeed, row: ?u32, arrival: Arrival };
const ActionPreview = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,

    pub fn feed(self: *ActionPreview, bytes: []const u8) !void {
        const n = @min(bytes.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..n], bytes[0..n]);
        self.len += n;
        self.truncated = self.truncated or n != bytes.len;
    }

    fn finish(self: *ActionPreview) void {
        while (self.len != 0 and !std.unicode.utf8ValidateSlice(self.bytes[0..self.len])) {
            self.len -= 1;
            self.truncated = true;
        }
    }

    fn slice(self: *const ActionPreview) []const u8 {
        return self.bytes[0..self.len];
    }
};
const ActionRead = struct { observation: NativeAction.Observation, preview: ActionPreview };
const ActionFrame = struct { ticket: NativeAction.Ticket, action: u64, choice: ?protocol.PermissionDecision };
const ReadResult = union(enum) { list: []observations.Row, page: PageResult, poll: observations.SourceChange, action: ActionRead };

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
page: ?*NativePagedFeed = null,
old_page: ?*NativePagedFeed = null,
pending_page: ?PageRequest = null,
new_activity: bool = false,
no_older: bool = false,
no_newer: bool = false,
feed_stale: bool = false,
export_open: bool = false,
action_details_open: bool = false,
action: NativeAction = .{},
action_preview: ActionPreview = .{},
action_frame: ?ActionFrame = null,
action_next: bool = true,
export_session: Id = undefined,
export_sources: [protocol.ActivityPage.items]observations.SourcePage.Item = undefined,
export_count: usize = 0,
export_selected: usize = 0,
export_command: ?[]u8 = null,
export_old_command: ?[]u8 = null,
export_text: [1]fw.Text = .{.{ .text = "" }},
export_index: fw.Text.LineIndex = .{},
export_view: fw.ScrollBars = .{ .scroll_view = .{ .children = .{ .slice = &.{} }, .item_count = 0 } },
navigation_epoch: u64 = 0,
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
read_kind: ReadKind = .{ .list = 0 },
read_arena: ?*std.heap.ArenaAllocator = null,
read_result: ?ReadResult = null,
list_arena: ?*std.heap.ArenaAllocator = null,
old_list_arena: ?*std.heap.ArenaAllocator = null,
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
        self.action.navigate(id);
        _ = try self.getDraft(id);
    }
    var tty_buffer: [65536]u8 = undefined;
    var app = try fw.App.init(init.io, init.gpa, init.environ_map, &tty_buffer);
    const result = app.run(self.widget(), .{});
    app.deinit();
    result catch |err| {
        stderr.diagnostic("rui: Native terminal stopped: {s}. Unsent drafts are not saved.\n", .{@errorName(err)});
        return err;
    };
}

fn deinit(self: *Self) void {
    self.worker.cancel();
    self.worker.join() catch {};
    const was_pending = self.submission.view() != null;
    const pending_reason: ?u64 = if (self.submission.intent) |intent| switch (intent) {
        .message_then_deny => |reason| reason.action,
        else => null,
    } else null;
    self.submission.cancel();
    const end = self.submission.join();
    if (was_pending) self.recoveryGuide(end, pending_reason);
    self.submission.close();
    if (self.export_command) |command| self.init.gpa.free(command);
    if (self.export_old_command) |command| self.init.gpa.free(command);
    self.export_index.deinit(self.init.gpa);
    self.freeArena(self.read_arena);
    self.freeArena(self.list_arena);
    self.freeArena(self.old_list_arena);
    self.dropReadResult();
    if (self.page) |page| page.destroy();
    if (self.old_page) |page| page.destroy();
    var values = self.drafts.valueIterator();
    while (values.next()) |value| value.*.destroy(self.init.gpa);
    self.drafts.deinit();
    self.overview_draft.destroy(self.init.gpa);
    self.scratch.close(self.init.io);
}

const ShutdownReceipt = struct {
    recovery: Submission.Recovery,
    end: Submission.End,
    reason_action: ?u64,
    captured: bool,
    reserved: bool,
    key: [36]u8,
    session: []const u8,
};

fn writeRecoveryGuide(out: *std.Io.Writer, receipt: ShutdownReceipt) !void {
    if (receipt.end == .accepted) {
        const accepted = receipt.end.accepted;
        if (accepted.denies) |action| {
            try out.print("rui: Reason accepted (request {s}); denial for Action {d} in Session {s} was not started during shutdown. Inspect the current Action and Host before deciding; do not resend the reason.\n", .{ receipt.key, action, receipt.session });
            return;
        }
    }
    switch (receipt.recovery) {
        .none => {},
        .not_sent => |kind| {
            if (receipt.captured) {
                try out.print("rui: Original {s} was not transmitted; request {s} was captured. Inspect it; do not automatically resend it.\n", .{ @tagName(kind), receipt.key });
            } else if (receipt.reserved) {
                try out.print("rui: Original {s} was not transmitted; capture of reserved request {s} is not confirmed. Its in-memory intent is not retained after exit.\n", .{ @tagName(kind), receipt.key });
            } else {
                try out.print("rui: Original {s} was not transmitted or reserved. Its in-memory intent is not retained after exit.\n", .{@tagName(kind)});
            }
        },
        .uncertain => |key| try out.print("rui: Capture or transmission of request {s} is not confirmed. Inspect the request; do not submit replacement input.\n", .{key}),
        .saved => |saved| {
            if (saved.rejected) {
                try out.print("rui: Original {s} was rejected. Inspect request {s}.\n", .{ @tagName(saved.original.kind), saved.original.key });
            } else if (saved.original.kind == .decision or receipt.reason_action != null) {
                try out.print("rui: Original {s} is not confirmed. Inspect request {s}; do not automatically resend it.\n", .{ @tagName(saved.original.kind), saved.original.key });
            } else {
                try out.print("rui: Message not confirmed. Use rui request recover {s}; do not resubmit it.\n", .{saved.original.key});
            }
        },
        .accepted => |accepted| try out.print("rui: {s} accepted; do not resubmit it. Use rui request read-result {s}.\n", .{ if (accepted.kind == .decision) "Action decision" else "Message", accepted.key }),
    }
    if (receipt.reason_action) |action| {
        try out.print("rui: This request is a reason followed by a denial for Action {d} in Session {s}; no denial was started during shutdown. Inspect the request, current Action and Host before deciding.\n", .{ action, receipt.session });
    }
}

fn recoveryGuide(self: *Self, end: Submission.End, reason_action: ?u64) void {
    var storage: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&storage);
    writeRecoveryGuide(&out, .{
        .recovery = self.submission.recovery(),
        .end = end,
        .reason_action = reason_action,
        .captured = self.submission.captured != null,
        .reserved = self.submission.target_reserved,
        .key = self.submission.key,
        .session = self.submission.session,
    }) catch {
        stderr.diagnosticBytes("rui: Could not format the original request's shutdown guidance.\n");
        return;
    };
    stderr.diagnosticBytes(out.buffered());
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

const page_items = 4;

fn tailRequest() PageRequest {
    return .{ .cursor = .{ .direction = .backward, .limit = page_items }, .instance = null, .arrival = .tail };
}

fn queuePage(self: *Self, request: PageRequest) void {
    self.pending_page = request;
    if (self.worker.thread != null) self.worker.cancel();
}

fn startRead(self: *Self) !void {
    return self.startReadUsing(Task.start);
}

fn startReadUsing(self: *Self, start_worker: anytype) !void {
    if (self.worker.thread != null) return;
    const kind: ReadKind = if (self.destination) |id| kind: {
        if (self.body_width <= @intFromBool(self.feed.draw_vertical_scrollbar)) return;
        const width = self.body_width - @intFromBool(self.feed.draw_vertical_scrollbar);
        const request: ?PageRequest = if (self.pending_page) |pending| pending else if (self.page == null) tailRequest() else null;
        if (request) |value| {
            const anchor = if (value.arrival == .reflow and self.page != null)
                try self.page.?.prepareAnchor(self.feed.scroll_view.firstVisibleIndex())
            else
                null;
            break :kind .{ .conversation = .{ .id = id, .epoch = self.navigation_epoch, .job = .{ .load = .{ .request = value, .width = width, .anchor = anchor } } } };
        }
        if (self.action_next or (self.new_activity and !self.following))
            break :kind .{ .action = .{ .ticket = self.action.ticket() orelse return, .epoch = self.navigation_epoch } };
        break :kind .{ .conversation = .{ .id = id, .epoch = self.navigation_epoch, .job = .{ .poll = self.page.? } } };
    } else .{ .list = self.navigation_epoch };
    const arena = try self.init.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(self.init.gpa);
    self.read_arena = arena;
    self.read_result = null;
    self.read_kind = kind;
    start_worker(&self.worker, self.init.io, self, readWork) catch |err| {
        if (kind == .action) {
            self.action.readFailed(kind.action.ticket);
            self.action_frame = null;
            self.action_details_open = false;
        }
        self.freeArena(self.read_arena);
        self.read_arena = null;
        return err;
    };
    if (kind == .conversation and kind.conversation.job == .load) self.pending_page = null;
    if (kind == .action) self.action_next = false else if (kind == .conversation) self.action_next = true;
}

fn readWork(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const alloc = self.read_arena.?.allocator();
    self.read_result = switch (self.read_kind) {
        .list => .{ .list = try observations.list(alloc, task.requests(), self.options.store, self.scratch) },
        .action => |job| action: {
            var preview: ActionPreview = .{};
            const observation = try NativeAction.read(task.requests(), self.options.store, job.ticket, self.scratch, &preview, false);
            preview.finish();
            break :action .{ .action = .{ .observation = observation, .preview = preview } };
        },
        .conversation => |conversation| switch (conversation.job) {
            .poll => |page| .{ .poll = try observations.sourceChanged(task.requests(), self.options.store, &page.page) },
            .load => |job| load: {
                const anchor = if (job.anchor) |value| try value.resolve(task.requests().cancellation) else null;
                const path = self.init.environ_map.get("TMPDIR") orelse "/tmp";
                if (!std.fs.path.isAbsolute(path)) return error.InvalidTemporaryDirectory;
                var dir = try std.Io.Dir.cwd().openDir(self.init.io, path, .{});
                defer dir.close(self.init.io);
                var cursor = job.request.cursor;
                const page = while (true) {
                    const loaded = try NativePagedFeed.load(self.init.gpa, task.requests(), dir, self.options.store, &conversation.id, cursor, job.request.instance, job.width, if (self.init.environ_map.get("NO_COLOR")) |value| value.len == 0 else true);
                    if (loaded.count != 0 or loaded.page.next == null) break loaded;
                    cursor = loaded.page.next.?;
                    loaded.destroy();
                };
                errdefer page.destroy();
                const row = if (anchor) |value| try page.rowForAnchor(value, task.requests().cancellation) else null;
                if (anchor != null and row == null) return error.HistoryAnchorUnavailable;
                try page.prepareForPublication(task.requests().cancellation);
                break :load .{ .page = .{ .page = page, .row = row, .arrival = job.request.arrival } };
            },
        },
    };
}

fn dropReadResult(self: *Self) void {
    if (self.read_result) |result| switch (result) {
        .page => |value| value.page.destroy(),
        else => {},
    };
    self.read_result = null;
}

fn completeRead(self: *Self, ctx: *fw.EventContext) !void {
    if (self.worker.thread == null or !self.worker.completed()) return;
    const relevant = self.read_kind.isCurrent(self.destination, self.navigation_epoch);
    self.worker.join() catch |err| {
        if (relevant) {
            if (self.read_kind == .action) {
                const ticket = self.read_kind.action.ticket;
                if (self.action.ticket()) |current| if (sameActionTicket(ticket, current)) {
                    self.action.readFailed(ticket);
                    self.action_frame = null;
                    self.action_details_open = false;
                    self.notice = @errorName(err);
                };
            } else if (err == error.Cancelled and self.pending_page != null) {
                // A superseded history read is not an Action failure.
            } else if (self.read_kind == .conversation) {
                self.feed_stale = true;
                self.notice = @errorName(err);
                if (err == error.HostInstanceChanged) self.pending_page = tailRequest();
            } else self.notice = @errorName(err);
            ctx.redraw = true;
        }
        self.dropReadResult();
        self.freeArena(self.read_arena);
        self.read_arena = null;
        return;
    };
    const arena = self.read_arena.?;
    self.read_arena = null;
    if (!relevant or (self.read_kind == .conversation and self.pending_page != null)) {
        self.dropReadResult();
        self.freeArena(arena);
        return;
    }
    errdefer self.freeArena(arena);
    switch (self.read_result.?) {
        .action => |result| {
            const previous = self.action.ticket();
            if (self.action.install(result.observation)) {
                self.action_preview = result.preview;
                const current = self.action.ticket();
                if (previous == null or current == null or previous.?.generation != current.?.generation) {
                    self.action_frame = null;
                    self.action_details_open = false;
                }
                ctx.redraw = true;
            }
            self.freeArena(arena);
        },
        .list => |rows| {
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
        .poll => |result| {
            self.freeArena(arena);
            self.page.?.page.token = result.token;
            if (result.changed) {
                if (self.following) self.pending_page = tailRequest() else self.new_activity = true;
                ctx.redraw = true;
            }
        },
        .page => |result| {
            self.freeArena(arena);
            if (result.page.count == 0 and self.page != null and (result.arrival == .older or result.arrival == .newer)) {
                if (result.arrival == .older) self.no_older = true else self.no_newer = true;
                result.page.destroy();
            } else {
                if (self.old_page) |old| old.destroy();
                self.old_page = self.page;
                self.page = result.page;
                if (result.arrival == .tail or result.arrival == .older) result.page.window.end();
                self.feed.scroll_view = .{ .children = .{ .builder = result.page.builder() }, .item_count = result.page.window.count() };
                self.feed.estimated_content_height = result.page.window.count();
                self.no_older = result.page.page.before == null or (result.page.request.direction == .backward and result.page.page.next == null);
                self.no_newer = result.page.page.after == null or (result.page.request.direction == .forward and result.page.page.next == null) or result.arrival == .tail;
                switch (result.arrival) {
                    .tail => {
                        self.new_activity = false;
                        self.feed.scroll_view.jumpToEnd();
                    },
                    .older => self.feed.scroll_view.jumpToEnd(),
                    .newer => self.feed.scroll_view.jumpToItem(0),
                    .reflow => if (result.row) |row| {
                        self.feed.scroll_view.jumpToItem(row);
                    },
                }
                self.feed_stale = false;
            }
            ctx.redraw = true;
        },
    }
    self.read_result = null;
}

fn retirePage(self: *Self) void {
    if (self.page) |page| {
        if (self.old_page) |old| old.destroy();
        self.old_page = page;
        self.page = null;
    }
    self.feed.scroll_view = .{ .children = .{ .slice = &.{} }, .item_count = 0 };
}

fn open(self: *Self, id: Id, ctx: *fw.EventContext) !void {
    _ = try self.getDraft(id);
    self.worker.cancel();
    self.retirePage();
    self.destination = id;
    self.action.navigate(id);
    self.action_frame = null;
    self.action_details_open = false;
    self.action_next = true;
    self.navigation_epoch +%= 1;
    self.following = true;
    self.pending_page = tailRequest();
    self.new_activity = false;
    self.no_older = false;
    self.no_newer = false;
    self.feed_stale = false;
    try ctx.requestFocus(self.activeDraft().field.widget());
    ctx.redraw = true;
}

fn back(self: *Self, ctx: *fw.EventContext) !void {
    self.worker.cancel();
    self.retirePage();
    self.pending_page = null;
    self.destination = null;
    self.action.navigate(null);
    self.action_frame = null;
    self.action_details_open = false;
    self.navigation_epoch +%= 1;
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

fn invalidateAction(self: *Self) void {
    self.action.navigate(self.destination);
    self.action_frame = null;
    self.action_details_open = false;
    self.action_next = true;
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
    self.invalidateAction();
    self.submission.begin(.{ .message = text }) catch |err| {
        if (self.submission.view() != null) self.showOriginal() else self.notice = @errorName(err);
        return;
    };
    self.notice = "Sending…";
}

fn submitDenialReason(self: *Self, offer: NativeAction.Offer) !void {
    if (self.submission.view() != null or self.submission.task.thread != null) {
        self.showOriginal();
        return;
    }
    const destination = self.destination orelse return;
    if (!std.mem.eql(u8, &destination, &offer.ticket.session)) return;
    const draft = self.activeDraft();
    const text = try draft.field.snapshot();
    defer self.init.gpa.free(text);
    if (text.len == 0) {
        self.notice = "Type a reason, or Alt-Y to deny without one";
        return;
    }
    if (text.len > self.submission.message_bytes.len) {
        self.notice = "Reason too long; draft retained";
        return;
    }
    self.submitted_session = destination;
    self.submission.session = &self.submitted_session;
    self.submitted_destination = destination;
    self.submitted_draft = draft;
    self.submitted_revision = draft.revision;
    self.submission.configuration = null;
    self.submission.captured_hook = null;
    if (self.action.choice == null and !self.action.choose(offer.ticket, offer.action, .deny, false)) return;
    const decision = self.action.confirm(offer.ticket, offer.action, false) orelse return;
    std.debug.assert(decision.decision == .deny);
    self.submission.beginObservedDenialReason(text, decision.action, decision.observed_instance) catch |err| {
        if (self.submission.view() != null) self.showOriginal() else self.notice = @errorName(err);
        return;
    };
    self.action_frame = null;
    self.action_next = true;
    self.notice = "Sending reason before denial…";
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
            self.notice = if (accepted.kind == .decision) "Action decision accepted" else "Message accepted";
            self.invalidateAction();
            if (self.submitted_destination == null and accepted.kind == .message and self.destination == null) if (accepted.session) |id| try self.open(id, ctx);
            self.submitted_draft = null;
            if (accepted.denies) |action| {
                const instance = accepted.observed_instance orelse return error.MissingActionHostInstance;
                self.submission.beginObservedDecision(.{ .action = action, .decision = .deny, .observed_instance = instance }) catch |err| {
                    if (self.submission.view() != null) self.showOriginal() else self.notice = @errorName(err);
                    ctx.redraw = true;
                    return;
                };
                self.notice = "Reason sent; sending denial…";
            }
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

fn makeExportCommand(allocator: std.mem.Allocator, store: []const u8, session: Id, source: observations.SourcePage.Item, selected: usize, count: usize) ![]u8 {
    const hex = try allocator.alloc(u8, try std.math.mul(usize, store.len, 2));
    defer allocator.free(hex);
    const digits = "0123456789abcdef";
    for (store, 0..) |byte, i| {
        hex[2 * i] = digits[byte >> 4];
        hex[2 * i + 1] = digits[byte & 15];
    }
    const digest = std.fmt.bytesToHex(source.reference.digest, .lower);
    return std.fmt.allocPrint(allocator, "Item {d} of {d} from page at opening · {s}\nposition {d}, ordinal {d} · {d} bytes\nRui content digest v1: {s}\nVerified export: rui session export-activity --store-hex {s} --content-bytes {d} --content-digest {s} --session {s} --position {d} --ordinal {d}\nAppend --output PATH for a new file. Source may contain terminal controls.", .{
        selected + 1,            count,
        if (source.queued) "Queued" else switch (source.kind) {
            .user => "You",
            .assistant => "Assistant",
            .tool => "Tool result",
        },
        source.position,         source.ordinal,
        source.reference.length, &digest,
        hex,                     source.reference.length,
        &digest,                 &session,
        source.position,         source.ordinal,
    });
}

fn updateExport(self: *Self) !void {
    const command = try makeExportCommand(self.init.gpa, self.options.store, self.export_session, self.export_sources[self.export_selected], self.export_selected, self.export_count);
    if (self.export_old_command) |old| self.init.gpa.free(old);
    self.export_old_command = self.export_command;
    self.export_command = command;
    self.export_text[0] = .{ .text = command };
    self.export_index.width = null;
    self.export_view.scroll_view = .{ .children = .{ .slice = &.{} }, .item_count = 0 };
}

fn openExport(self: *Self) !void {
    const page = self.page orelse return;
    self.export_count = page.sources(&self.export_sources);
    if (self.export_count == 0) return;
    self.export_selected = page.sourceIndexAt(self.feed.scroll_view.cursor) orelse 0;
    self.export_session = page.page.session;
    try self.updateExport();
    self.export_open = true;
}

/// Later navigation owns the viewport: cancel a reflow holding an older
/// anchor and recapture after the input has been applied and drawn.
fn supersedeReflow(self: *Self) void {
    if (self.pending_page) |pending| if (pending.arrival != .reflow) return;
    if (self.worker.thread == null or self.read_kind != .conversation) return;
    const job = self.read_kind.conversation.job;
    if (job != .load or job.load.request.arrival != .reflow) return;
    self.queuePage(job.load.request);
}

/// Move within the authenticated source before fetching another Activity page.
/// A running page load retains authority over its old-frame anchor until join.
fn navigateEdge(self: *Self, backward: bool, ctx: *fw.EventContext) !bool {
    const page = self.page orelse return false;
    if (if (backward) !self.feed.scroll_view.atStart() else !self.feed.scroll_view.atEnd()) return false;
    if (self.pending_page) |pending| if (pending.arrival != .reflow) {
        ctx.consumeEvent();
        return true;
    };
    if (self.worker.thread != null and self.read_kind == .conversation and self.read_kind.conversation.job == .load and self.read_kind.conversation.job.load.request.arrival != .reflow) {
        self.notice = "History loading; scroll again when ready";
        ctx.consumeAndRedraw();
        return true;
    }
    if (if (backward) page.window.previous() else page.window.next()) {
        self.feed.scroll_view = .{ .children = .{ .builder = page.builder() }, .item_count = page.window.count() };
        self.feed.estimated_content_height = page.window.count();
        if (backward) self.feed.scroll_view.jumpToEnd() else self.feed.scroll_view.jumpToItem(0);
        ctx.consumeAndRedraw();
        return true;
    }
    if (backward and !self.no_older) {
        if (page.page.before) |cursor| {
            self.queuePage(.{ .cursor = cursor, .instance = page.page.instance, .arrival = .older });
            ctx.consumeAndRedraw();
            return true;
        }
    }
    if (!backward and (!self.no_newer or self.new_activity)) {
        if (page.page.after) |boundary| {
            var cursor = boundary;
            if (self.new_activity) cursor.end = null;
            self.queuePage(.{ .cursor = cursor, .instance = page.page.instance, .arrival = .newer });
            ctx.consumeAndRedraw();
            return true;
        }
    }
    return false;
}

fn sameActionTicket(a: NativeAction.Ticket, b: NativeAction.Ticket) bool {
    return a.generation == b.generation and std.mem.eql(u8, &a.session, &b.session);
}

fn actionGesture(self: *Self, ctx: *const fw.EventContext) ?NativeAction.Offer {
    if (self.submission.view() != null or self.submission.task.thread != null or self.pasting or self.export_open or self.action_details_open or ctx.input_sequence == 0 or ctx.input_sequence <= ctx.frame_input_watermark) return null;
    const offer = self.action.offer orelse return null;
    const frame = self.action_frame orelse return null;
    const destination = self.destination orelse return null;
    if (!std.mem.eql(u8, &destination, &offer.ticket.session) or !sameActionTicket(frame.ticket, offer.ticket) or frame.action != offer.action or frame.choice != self.action.choice) return null;
    return offer;
}

fn confirmAction(self: *Self, offer: NativeAction.Offer) void {
    if (self.submission.view() != null or self.submission.task.thread != null) {
        self.showOriginal();
        return;
    }
    const destination = self.destination orelse return;
    if (!std.mem.eql(u8, &destination, &offer.ticket.session)) return;
    // Bind the stable Session and original custody before consuming the offer.
    self.submitted_session = destination;
    self.submission.session = &self.submitted_session;
    self.submitted_destination = destination;
    self.submitted_draft = null;
    self.submission.configuration = null;
    self.submission.captured_hook = null;
    const decision = self.action.confirm(offer.ticket, offer.action, false) orelse return;
    self.submission.beginObservedDecision(.{ .action = decision.action, .decision = decision.decision, .observed_instance = decision.observed_instance }) catch |err| {
        if (self.submission.view() != null) self.showOriginal() else self.notice = @errorName(err);
        return;
    };
    self.action_frame = null;
    self.action_next = true;
    self.notice = "Sending Action decision…";
}

fn openActionDetails(self: *Self, offer: NativeAction.Offer) !void {
    var output: std.Io.Writer.Allocating = .init(self.init.gpa);
    defer output.deinit();
    const out = &output.writer;
    try out.print("Action {d} · bounded preview; full details are optional\n", .{offer.action});
    try out.writeAll(self.action_preview.slice());
    if (self.action_preview.truncated) try out.writeAll("\n[Preview truncated]\n");
    try out.writeAll("\nInspect current Action: rui action inspect --store ");
    try TerminalText.writeShellWord(out, self.options.store);
    try TerminalText.writeShellSession(out, &offer.ticket.session, false);
    try out.print(" --action {d}\n", .{offer.action});
    const text = try self.init.gpa.dupe(u8, output.written());
    if (self.export_old_command) |old| self.init.gpa.free(old);
    self.export_old_command = self.export_command;
    self.export_command = text;
    self.export_text[0] = .{ .text = text };
    self.export_index.width = null;
    self.export_view.scroll_view = .{ .children = .{ .slice = &.{} }, .item_count = 0 };
    self.action_details_open = true;
    self.action_frame = null;
}

fn capture(raw: *anyopaque, ctx: *fw.EventContext, value: fw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (value) {
        .paste => |text| if (self.export_open or self.action_details_open) {
            ctx.alloc.free(text);
            ctx.consumeEvent();
        },
        .paste_start => {
            self.pasting = true;
            if (self.export_open or self.action_details_open) ctx.consumeAndRedraw();
        },
        .paste_end => {
            self.pasting = false;
            if (self.export_open or self.action_details_open) ctx.consumeAndRedraw();
        },
        .mouse => |mouse| if (self.export_open or self.action_details_open) {
            if (mouse.row == 0 or mouse.row >= self.body_bottom) ctx.consumeAndRedraw();
        } else if (self.destination != null) {
            const wheel = mouse.button == .wheel_up or mouse.button == .wheel_down;
            const scrollbar = self.body_width != 0 and mouse.col == self.body_width - 1 and mouse.row > 0 and mouse.row < self.body_bottom and (mouse.type == .press or mouse.type == .drag);
            if (wheel or scrollbar) {
                self.following = false;
                self.supersedeReflow();
            }
            if (wheel and try self.navigateEdge(mouse.button == .wheel_up, ctx)) return;
        },
        .key_press => |key| {
            if (!self.pasting and key.matches('q', .{ .ctrl = true })) {
                if (self.submission.task.thread != null) {
                    self.submission.cancel();
                    self.notice = "Cancelling local wait; original may already be admitted";
                } else switch (self.submission.recovery()) {
                    .not_sent => self.notice = "Original not sent; Ctrl-R retry or Ctrl-D discard before quit",
                    .uncertain => self.notice = "Capture uncertain; Ctrl-R retry before quit",
                    else => ctx.quit = true,
                }
                ctx.consumeAndRedraw();
                return;
            }
            if (self.action_details_open) {
                if (!self.pasting and (key.matches(vaxis.Key.escape, .{}) or key.matches('i', .{ .alt = true }))) {
                    self.action_details_open = false;
                } else if (!self.pasting and (key.matches(vaxis.Key.page_up, .{}) or key.matches(vaxis.Key.page_down, .{}))) {
                    try self.export_view.scroll_view.handleEvent(ctx, .{ .key_press = .{ .codepoint = if (key.matches(vaxis.Key.page_up, .{})) 'u' else 'd', .mods = .{ .ctrl = true } } });
                }
                ctx.consumeAndRedraw();
                return;
            }
            if (!self.pasting and self.destination != null and key.matches('e', .{ .alt = true })) {
                if (self.export_open) self.export_open = false else try self.openExport();
                ctx.consumeAndRedraw();
                return;
            }
            if (self.export_open) {
                if (self.pasting) {
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.export_open = false;
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches(vaxis.Key.up, .{ .alt = true }) or key.matches(vaxis.Key.down, .{ .alt = true })) {
                    if (key.matches(vaxis.Key.up, .{ .alt = true })) self.export_selected -|= 1 else self.export_selected = @min(self.export_selected + 1, self.export_count - 1);
                    try self.updateExport();
                    ctx.consumeAndRedraw();
                    return;
                }
                if (key.matches(vaxis.Key.page_up, .{}) or key.matches(vaxis.Key.page_down, .{})) {
                    try self.export_view.scroll_view.handleEvent(ctx, .{ .key_press = .{ .codepoint = if (key.matches(vaxis.Key.page_up, .{})) 'u' else 'd', .mods = .{ .ctrl = true } } });
                    ctx.consumeAndRedraw();
                    return;
                }
                ctx.consumeAndRedraw();
                return;
            }
            if (!self.pasting and (key.matches('a', .{ .alt = true }) or key.matches('d', .{ .alt = true }) or key.matches('y', .{ .alt = true }) or key.matches('i', .{ .alt = true }))) {
                if (self.submission.view() != null or self.submission.task.thread != null) {
                    self.showOriginal();
                } else if (ctx.frame_input_watermark == std.math.maxInt(u64)) {
                    self.notice = "Action unavailable: input freshness could not be verified";
                } else if (self.actionGesture(ctx)) |offer| {
                    if (key.matches('i', .{ .alt = true })) {
                        try self.openActionDetails(offer);
                    } else if (key.matches('y', .{ .alt = true })) {
                        if (self.action_frame.?.choice != null) self.confirmAction(offer);
                    } else {
                        const choice: protocol.PermissionDecision = if (key.matches('a', .{ .alt = true })) .allow_once else .deny;
                        _ = self.action.choose(offer.ticket, offer.action, choice, false);
                    }
                }
                ctx.consumeAndRedraw();
                return;
            }
            if (!self.pasting and key.matches('r', .{ .ctrl = true })) {
                if (self.submission.view()) |original| {
                    if (original.state != .rejected) {
                        self.submission.requestRecovery(null) catch |err| {
                            self.notice = if (err == error.SubmissionInFlight) "Wait for the original result before retrying" else @errorName(err);
                            ctx.consumeAndRedraw();
                            return;
                        };
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
                        self.invalidateAction();
                        self.submitted_draft = null;
                        self.notice = "Original released; draft retained";
                        ctx.consumeAndRedraw();
                        return;
                    }
                }
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
                if (self.page) |page| self.queuePage(.{ .cursor = .{ .direction = .forward, .limit = page_items }, .instance = page.page.instance, .arrival = .newer });
                ctx.consumeAndRedraw();
                return;
            }
            if (self.destination != null and key.matches(vaxis.Key.escape, .{})) {
                if (!self.following) {
                    self.following = true;
                    self.queuePage(tailRequest());
                } else try self.back(ctx);
                ctx.consumeAndRedraw();
                return;
            }
            if (self.destination != null and (key.matches(vaxis.Key.page_up, .{}) or key.matches(vaxis.Key.page_down, .{}))) {
                self.following = false;
                self.supersedeReflow();
                if (try self.navigateEdge(key.matches(vaxis.Key.page_up, .{}), ctx)) return;
                try self.feed.scroll_view.handleEvent(ctx, .{ .key_press = .{ .codepoint = if (key.matches(vaxis.Key.page_up, .{})) 'u' else 'd', .mods = .{ .ctrl = true } } });
                ctx.consumeAndRedraw();
                return;
            }
            if (!self.pasting and key.matches(vaxis.Key.enter, .{})) {
                if (self.action.offer != null) {
                    if (self.action.choice == .allow_once) {
                        self.notice = "Alt-Y confirms; draft retained";
                    } else if (self.actionGesture(ctx)) |offer| {
                        try self.submitDenialReason(offer);
                    } else self.notice = if (ctx.frame_input_watermark == std.math.maxInt(u64)) "Action unavailable: input freshness could not be verified" else "Action pending; draft retained";
                } else try self.submit();
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
            try self.completeRead(ctx);
            try self.finishSubmission(ctx);
            if (self.page) |page| {
                const width = self.body_width -| @intFromBool(self.feed.draw_vertical_scrollbar);
                if (width != 0 and width != page.width and self.pending_page == null) {
                    var cursor = page.request;
                    cursor.end = page.page.end;
                    self.queuePage(.{ .cursor = cursor, .instance = page.page.instance, .arrival = .reflow });
                }
            }
            if (self.worker.thread == null) self.startRead() catch |err| {
                self.notice = @errorName(err);
            };
            try ctx.tick(500, self.widget());
        },
        .mouse => |mouse| if (self.destination != null and !self.export_open and !self.action_details_open and (mouse.button == .wheel_up or mouse.button == .wheel_down)) {
            self.following = false;
        },
        else => {},
    }
}

fn draw(raw: *anyopaque, ctx: fw.DrawContext) std.mem.Allocator.Error!fw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const width = ctx.max.width orelse 0;
    const height = ctx.max.height orelse 0;
    self.action_frame = null;
    if (width == 0 or height == 0) return fw.Surface.init(ctx.arena, self.widget(), .{ .width = width, .height = height });
    self.header.text = if (self.destination) |id| (if (self.feed_stale)
        try std.fmt.allocPrint(ctx.arena, "Session {s}  ·  History may be stale · Esc returns", .{&id})
    else if (self.new_activity)
        try std.fmt.allocPrint(ctx.arena, "Session {s}  ·  New activity · Esc follows", .{&id})
    else
        try std.fmt.allocPrint(ctx.arena, "Session {s}  ·  Esc returns", .{&id})) else "Sessions  ·  Alt-↑/↓ select · Alt-Enter open";
    const header = try self.header.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    self.border = .{ .child = self.activeDraft().field.widget() };
    const composer_max = height -| 2;
    const composer = if (width >= 2 and composer_max >= 3)
        try self.border.draw(ctx.withConstraints(.{}, .{ .width = width, .height = composer_max }))
    else
        try self.activeDraft().field.draw(ctx.withConstraints(.{}, .{ .width = width, .height = composer_max }));
    const body_height = height -| 2 -| composer.size.height;
    self.status.text = if (self.action_details_open) "Action preview · Page scroll · Esc close" else if (self.export_open) "Alt-↑/↓ select from page at opening · Wheel/Page scroll · Esc close" else if (self.notice.len != 0) self.notice else if (self.action.offer != null and self.destination != null) (if (width < 28 or body_height < 5) "Action pending · enlarge window" else "Preview may be clipped · Alt-I details · Ctrl-Q quit") else "Enter send · Alt-E export · Shift-Enter/Ctrl-J newline · Ctrl-Q quit";
    const status = try self.status.draw(ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 }));
    self.body_width = width;
    self.body_bottom = 1 + body_height;
    const body_ctx = ctx.withConstraints(.{ .width = width, .height = body_height }, .{ .width = width, .height = body_height });
    if (self.destination != null and body_height != 0) {
        if (self.following) self.feed.scroll_view.jumpToEnd();
    }
    const body = if (self.destination == null) try self.list.draw(body_ctx) else if (self.export_open or self.action_details_open) body: {
        const export_width = width -| @intFromBool(self.export_view.draw_vertical_scrollbar);
        if (self.export_index.width == null or self.export_index.width.? != export_width) {
            try self.export_index.reflow(self.init.gpa, &self.export_text, body_ctx.withConstraints(.{ .width = export_width }, .{ .width = export_width, .height = null }));
            self.export_view.scroll_view.children = .{ .builder = self.export_index.builder() };
            self.export_view.scroll_view.item_count = @intCast(self.export_index.len);
            self.export_view.estimated_content_height = @intCast(self.export_index.len);
        }
        break :body try self.export_view.draw(body_ctx);
    } else if (self.action.offer != null and width >= 28 and body_height >= 5) body: {
        const offer = self.action.offer.?;
        const title = try std.fmt.allocPrint(ctx.arena, "Action {d}", .{offer.action});
        const controls = if (self.action.choice) |choice|
            (if (choice == .allow_once) "ALLOW: Alt-Y confirm" else "DENY: Enter reason Alt-Y")
        else
            "Alt-A allow  Alt-D deny";
        const enter_action = if (self.action.choice == .allow_once) "Enter keeps draft" else "Enter sends reason + denies";
        var title_widget: fw.Text = .{ .text = title, .softwrap = false };
        var controls_widget: fw.Text = .{ .text = controls, .softwrap = false };
        var enter_widget: fw.Text = .{ .text = enter_action, .softwrap = false };
        const preview = try std.fmt.allocPrint(ctx.arena, "Preview: {s}", .{std.mem.trimStart(u8, self.action_preview.slice(), "\n")});
        var preview_widget: fw.Text = .{ .text = preview, .softwrap = false };
        const row_ctx = body_ctx.withConstraints(.{ .width = width, .height = 1 }, .{ .width = width, .height = 1 });
        var title_surface = try title_widget.draw(row_ctx);
        var controls_surface = try controls_widget.draw(row_ctx);
        var preview_surface = try preview_widget.draw(row_ctx);
        var enter_surface = try enter_widget.draw(row_ctx);
        title_surface.widget = self.widget();
        controls_surface.widget = self.widget();
        preview_surface.widget = self.widget();
        enter_surface.widget = self.widget();
        const feed_height = body_height - 4;
        const feed_surface = try self.feed.draw(body_ctx.withConstraints(.{ .width = width, .height = feed_height }, .{ .width = width, .height = feed_height }));
        const content = try ctx.arena.alloc(fw.SubSurface, 5);
        content[0] = .{ .origin = .{ .col = 0, .row = 0 }, .surface = title_surface, .z_index = 0 };
        content[1] = .{ .origin = .{ .col = 0, .row = 1 }, .surface = controls_surface, .z_index = 0 };
        content[2] = .{ .origin = .{ .col = 0, .row = 2 }, .surface = enter_surface, .z_index = 0 };
        content[3] = .{ .origin = .{ .col = 0, .row = 3 }, .surface = preview_surface, .z_index = 0 };
        content[4] = .{ .origin = .{ .col = 0, .row = 4 }, .surface = feed_surface, .z_index = 0 };
        self.action_frame = .{ .ticket = offer.ticket, .action = offer.action, .choice = self.action.choice };
        break :body try fw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = body_height }, content);
    } else try self.feed.draw(body_ctx);
    if (self.page) |page| if (page.fault()) |err| {
        self.feed_stale = true;
        self.notice = @errorName(err);
    };
    const children = try ctx.arena.alloc(fw.SubSurface, 4);
    children[0] = .{ .origin = .{ .col = 0, .row = 0 }, .surface = header, .z_index = 0 };
    children[1] = .{ .origin = .{ .col = 0, .row = 1 }, .surface = body, .z_index = 0 };
    children[2] = .{ .origin = .{ .col = 0, .row = @intCast(1 + body_height) }, .surface = composer, .z_index = 0 };
    children[3] = .{ .origin = .{ .col = 0, .row = height - 1 }, .surface = status, .z_index = 0 };
    return fw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = width, .height = height }, children);
}

test "navigation epoch rejects stale overview and session reads" {
    const id: Id = "abc123".*;
    const other: Id = "abc124".*;
    const list: ReadKind = .{ .list = 3 };
    try std.testing.expect(list.isCurrent(null, 3));
    try std.testing.expect(!list.isCurrent(null, 5));
    try std.testing.expect(!list.isCurrent(id, 3));
    const conversation: ReadKind = .{ .conversation = .{ .id = id, .epoch = 4, .job = .{ .load = .{ .request = tailRequest(), .width = 80, .anchor = null } } } };
    try std.testing.expect(conversation.isCurrent(id, 4));
    try std.testing.expect(!conversation.isCurrent(id, 6));
    try std.testing.expect(!conversation.isCurrent(other, 4));
    try std.testing.expect(!conversation.isCurrent(null, 4));
}

test "native exact export command uses source identity and shell-safe store bytes" {
    const item: observations.SourcePage.Item = .{ .kind = .assistant, .position = 42, .ordinal = 3, .reference = .{ .length = 4, .digest = @splat(0xab) } };
    const command = try makeExportCommand(std.testing.allocator, "store with ' \x1b", "abc123".*, item, 0, 1);
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, "--session abc123 --position 42 --ordinal 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "--store-hex 73746f726520776974682027201b --content-bytes 4 --content-digest abababab") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "Rui content digest v1: abababab") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, command, 0x1b) == null);
}

test "native export overlay consumes and frees paste before it reaches draft" {
    var self: Self = undefined;
    self.export_open = true;
    var ctx: fw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    const text = try std.testing.allocator.dupe(u8, "must not reach the draft");
    try capture(&self, &ctx, .{ .paste = text });
    try std.testing.expect(ctx.consume_event);
}

test "native pending navigation survives worker start failure" {
    const Failure = struct {
        fn start(_: *Task, _: std.Io, _: *anyopaque, _: Task.Run) !void {
            return error.WitnessSpawnFailure;
        }
    };
    var self: Self = undefined;
    self.init = undefined;
    self.init.gpa = std.testing.allocator;
    self.init.io = std.testing.io;
    self.worker = .{};
    self.destination = "abc123".*;
    self.navigation_epoch = 1;
    self.body_width = 80;
    self.feed = .{ .scroll_view = .{ .children = .{ .slice = &.{} }, .item_count = 0 } };
    self.page = null;
    self.pending_page = tailRequest();
    self.read_arena = null;
    self.read_result = null;
    const original = self.pending_page.?;
    try std.testing.expectError(error.WitnessSpawnFailure, self.startReadUsing(Failure.start));
    try std.testing.expect(self.pending_page != null and std.meta.eql(original, self.pending_page.?));
    try std.testing.expect(self.read_arena == null and self.worker.thread == null);
}

test "native Action gesture requires matching shown choice and newer input" {
    var self: Self = undefined;
    self.destination = "abc123".*;
    self.submission = .{ .io = std.testing.io, .store = "unused", .session = "abc123", .directory = "unused", .environment = .empty };
    self.action = .{};
    self.action.navigate(self.destination);
    const ticket = self.action.ticket().?;
    const instance: protocol.InstanceId = @splat(2);
    try std.testing.expect(self.action.install(.{ .ticket = ticket, .instance = instance, .offer = .{ .ticket = ticket, .instance = instance, .action = 19, .summary = .{} } }));
    const offer = self.action.offer.?;
    self.export_open = false;
    self.action_details_open = false;
    self.pasting = false;
    self.action_frame = .{ .ticket = offer.ticket, .action = offer.action, .choice = null };
    var ctx: fw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty, .input_sequence = 8, .frame_input_watermark = 8 };
    try std.testing.expect(self.actionGesture(&ctx) == null);
    ctx.input_sequence = 9;
    try std.testing.expect(self.actionGesture(&ctx) != null);
    try std.testing.expect(self.action.choose(offer.ticket, offer.action, .allow_once, false));
    // The choice needs its own delivered frame, even for input from the same batch.
    try std.testing.expect(self.actionGesture(&ctx) == null);
    self.action_frame.?.choice = .allow_once;
    ctx.frame_input_watermark = 12;
    ctx.input_sequence = 12;
    try std.testing.expect(self.actionGesture(&ctx) == null);
    ctx.input_sequence = 13;
    try std.testing.expect(self.actionGesture(&ctx) != null);
    self.pasting = true;
    try std.testing.expect(self.actionGesture(&ctx) == null);
    self.pasting = false;
    self.destination = "abc124".*;
    try std.testing.expect(self.actionGesture(&ctx) == null);
    self.destination = "abc123".*;
    self.action.readFailed(offer.ticket);
    try std.testing.expect(self.actionGesture(&ctx) == null);
}

test "native Action preview remains bounded and ends at UTF-8 boundary" {
    var preview: ActionPreview = .{};
    try preview.feed(&@as([4095]u8, @splat('x')));
    try preview.feed("🌍!");
    preview.finish();
    try std.testing.expect(preview.truncated);
    try std.testing.expectEqual(@as(usize, 4095), preview.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview.slice()));
}

test "native Action capture rejects pasted and pre-frame choices" {
    var self: Self = undefined;
    self.destination = "abc123".*;
    self.submission = .{ .io = std.testing.io, .store = "unused", .session = "abc123", .directory = "unused", .environment = .empty };
    self.action = .{};
    self.action.navigate(self.destination);
    const ticket = self.action.ticket().?;
    const instance: protocol.InstanceId = @splat(3);
    try std.testing.expect(self.action.install(.{ .ticket = ticket, .instance = instance, .offer = .{ .ticket = ticket, .instance = instance, .action = 19, .summary = .{} } }));
    const offer = self.action.offer.?;
    self.export_open = false;
    self.action_details_open = false;
    self.pasting = false;
    self.action_frame = .{ .ticket = offer.ticket, .action = offer.action, .choice = null };
    var ctx: fw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty, .input_sequence = 4, .frame_input_watermark = 4 };
    const allow: fw.Event = .{ .key_press = .{ .codepoint = 'a', .mods = .{ .alt = true } } };
    try capture(&self, &ctx, allow);
    try std.testing.expect(self.action.choice == null);
    try capture(&self, &ctx, .paste_start);
    ctx.input_sequence = 5;
    try capture(&self, &ctx, allow);
    try std.testing.expect(self.action.choice == null);
    try capture(&self, &ctx, .paste_end);
    try capture(&self, &ctx, allow);
    try std.testing.expectEqual(protocol.PermissionDecision.allow_once, self.action.choice.?);
    // A confirmation queued with the choice cannot use its old frame.
    ctx.input_sequence = 6;
    try capture(&self, &ctx, .{ .key_press = .{ .codepoint = 'y', .mods = .{ .alt = true } } });
    try std.testing.expect(self.action.offer != null);
}

test "native Action choice is blocked while original custody is occupied" {
    var self: Self = undefined;
    self.destination = "abc123".*;
    self.action = .{};
    self.action.navigate(self.destination);
    const ticket = self.action.ticket().?;
    const instance: protocol.InstanceId = @splat(4);
    try std.testing.expect(self.action.install(.{ .ticket = ticket, .instance = instance, .offer = .{ .ticket = ticket, .instance = instance, .action = 19, .summary = .{} } }));
    const offer = self.action.offer.?;
    self.export_open = false;
    self.action_details_open = false;
    self.pasting = false;
    self.action_next = false;
    self.action_frame = .{ .ticket = offer.ticket, .action = offer.action, .choice = null };
    self.submission = .{ .io = std.testing.io, .store = "unused", .session = "abc123", .directory = "unused", .environment = .empty };
    self.submission.intent = .{ .decision = .{ .action = 19, .decision = .allow_once } };
    var ctx: fw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty, .input_sequence = 3, .frame_input_watermark = 2 };
    try std.testing.expect(self.actionGesture(&ctx) == null);
    self.submission.intent = null;
    self.invalidateAction();
    try std.testing.expect(self.actionGesture(&ctx) == null);
    try std.testing.expect(self.action.offer == null and self.action.choice == null);
}

test "native scroll cancellation revokes matching in-flight Action read" {
    const Worker = struct {
        fn run(_: *anyopaque, task: *Task) !void {
            const deadline = std.Io.Clock.awake.now(task.io).nanoseconds + 5_000_000_000;
            while (!task.cancellation.stopped.load(.acquire)) {
                if (std.Io.Clock.awake.now(task.io).nanoseconds >= deadline) return error.TestCompletionDeadline;
                std.Thread.yield() catch {};
            }
            return error.Cancelled;
        }
    };
    var self: Self = undefined;
    self.init = undefined;
    self.init.gpa = std.testing.allocator;
    self.init.io = std.testing.io;
    self.destination = "abc123".*;
    self.navigation_epoch = 1;
    self.action = .{};
    self.action.navigate(self.destination);
    const initial = self.action.ticket().?;
    const instance: protocol.InstanceId = @splat(5);
    try std.testing.expect(self.action.install(.{ .ticket = initial, .instance = instance, .offer = .{ .ticket = initial, .instance = instance, .action = 19, .summary = .{} } }));
    const offer = self.action.offer.?;
    try std.testing.expect(self.action.choose(offer.ticket, offer.action, .deny, false));
    self.action_frame = .{ .ticket = offer.ticket, .action = offer.action, .choice = .deny };
    self.action_details_open = false;
    self.worker = .{};
    self.read_kind = .{ .action = .{ .ticket = offer.ticket, .epoch = 1 } };
    self.read_result = null;
    self.read_arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    self.read_arena.?.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    self.pending_page = null;
    self.notice = "";
    try self.worker.start(std.testing.io, &self, Worker.run);
    defer {
        self.worker.cancel();
        self.worker.join() catch {};
    }
    self.queuePage(tailRequest());
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5_000_000_000;
    while (!self.worker.completed()) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds >= deadline) return error.TestCompletionDeadline;
        std.Thread.yield() catch {};
    }
    var ctx: fw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    try self.completeRead(&ctx);
    try std.testing.expect(self.action.offer == null and self.action.choice == null and self.action_frame == null);
    try std.testing.expect(self.pending_page != null and self.worker.thread == null and self.read_arena == null);
}

test "native shutdown guidance distinguishes custody and compound continuation" {
    const key: [36]u8 = @splat('a');
    const accepted_message: Submission.Accepted = .{ .kind = .message, .key = key };
    const accepted_decision: Submission.Accepted = .{ .kind = .decision, .key = key };
    const cases = [_]struct { receipt: ShutdownReceipt, expected: []const u8, forbidden: []const u8 }{
        .{ .receipt = .{ .recovery = .{ .not_sent = .message }, .end = .absent, .reason_action = 19, .captured = false, .reserved = false, .key = key, .session = "abc123" }, .expected = "not transmitted or reserved", .forbidden = "request recover" },
        .{ .receipt = .{ .recovery = .{ .not_sent = .decision }, .end = .absent, .reason_action = null, .captured = true, .reserved = true, .key = key, .session = "abc123" }, .expected = "decision was not transmitted", .forbidden = "request recover" },
        .{ .receipt = .{ .recovery = .{ .not_sent = .message }, .end = .absent, .reason_action = null, .captured = false, .reserved = true, .key = key, .session = "abc123" }, .expected = "capture of reserved request", .forbidden = "request recover" },
        .{ .receipt = .{ .recovery = .{ .saved = .{ .original = accepted_message, .rejected = false } }, .end = .absent, .reason_action = 19, .captured = true, .reserved = true, .key = key, .session = "abc123" }, .expected = "reason followed by a denial", .forbidden = "request recover" },
        .{ .receipt = .{ .recovery = .{ .uncertain = key }, .end = .absent, .reason_action = 19, .captured = false, .reserved = true, .key = key, .session = "abc123" }, .expected = "not confirmed", .forbidden = "request recover" },
        .{ .receipt = .{ .recovery = .{ .accepted = accepted_message }, .end = .{ .accepted = .{ .kind = .message, .confirmed = false, .denies = 19 } }, .reason_action = 19, .captured = false, .reserved = true, .key = key, .session = "abc123" }, .expected = "denial for Action 19 in Session abc123 was not started", .forbidden = "request recover" },
        .{ .receipt = .{ .recovery = .{ .accepted = accepted_decision }, .end = .{ .accepted = .{ .kind = .decision, .confirmed = false } }, .reason_action = null, .captured = false, .reserved = true, .key = key, .session = "abc123" }, .expected = "Action decision accepted", .forbidden = "Message accepted" },
        .{ .receipt = .{ .recovery = .{ .saved = .{ .original = accepted_decision, .rejected = false } }, .end = .absent, .reason_action = null, .captured = true, .reserved = true, .key = key, .session = "abc123" }, .expected = "Original decision is not confirmed", .forbidden = "request recover" },
    };
    for (cases) |case| {
        var storage: [2048]u8 = undefined;
        var out: std.Io.Writer = .fixed(&storage);
        try writeRecoveryGuide(&out, case.receipt);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), case.expected) != null);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), case.forbidden) == null);
    }
}
