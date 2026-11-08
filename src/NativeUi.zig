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

    fn isCurrent(self: ReadKind, destination: ?Id, epoch: u64) bool {
        return switch (self) {
            .list => |started| destination == null and started == epoch,
            .conversation => |started| destination != null and started.epoch == epoch and std.mem.eql(u8, &destination.?, &started.id),
        };
    }
};
const PageResult = struct { page: *NativePagedFeed, row: ?u32, arrival: Arrival };
const ReadResult = union(enum) { list: []observations.Row, page: PageResult, poll: observations.SourceChange };

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
        if (self.new_activity and !self.following) return;
        break :kind .{ .conversation = .{ .id = id, .epoch = self.navigation_epoch, .job = .{ .poll = self.page.? } } };
    } else .{ .list = self.navigation_epoch };
    const arena = try self.init.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(self.init.gpa);
    self.read_arena = arena;
    self.read_result = null;
    self.read_kind = kind;
    start_worker(&self.worker, self.init.io, self, readWork) catch |err| {
        self.freeArena(self.read_arena);
        self.read_arena = null;
        return err;
    };
    if (kind == .conversation and kind.conversation.job == .load) self.pending_page = null;
}

fn readWork(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const alloc = self.read_arena.?.allocator();
    self.read_result = switch (self.read_kind) {
        .list => .{ .list = try observations.list(alloc, task.requests(), self.options.store, self.scratch) },
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
                    const loaded = try NativePagedFeed.load(self.init.gpa, task.requests(), dir, self.options.store, &conversation.id, cursor, job.request.instance, job.width);
                    if (loaded.count != 0 or loaded.page.next == null) break loaded;
                    cursor = loaded.page.next.?;
                    loaded.destroy();
                };
                errdefer page.destroy();
                const row = if (anchor) |value| try page.rowForAnchor(value, task.requests().cancellation) else null;
                if (anchor != null and row == null) return error.HistoryAnchorUnavailable;
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
        if (relevant and !(err == error.Cancelled and self.pending_page != null)) {
            if (self.read_kind == .conversation) {
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
        selected + 1, count, if (source.kind == .user) "You" else "Assistant", source.position, source.ordinal, source.reference.length, &digest, hex, source.reference.length, &digest, &session, source.position, source.ordinal,
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

fn capture(raw: *anyopaque, ctx: *fw.EventContext, value: fw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (value) {
        .paste => |text| if (self.export_open) {
            ctx.alloc.free(text);
            ctx.consumeEvent();
        },
        .paste_start => {
            self.pasting = true;
            if (self.export_open) ctx.consumeAndRedraw();
        },
        .paste_end => {
            self.pasting = false;
            if (self.export_open) ctx.consumeAndRedraw();
        },
        .mouse => |mouse| if (self.export_open) {
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
                    .not_sent => self.notice = "Original not saved; Ctrl-R retry or Ctrl-D discard before quit",
                    .uncertain => self.notice = "Capture uncertain; Ctrl-R retry before quit",
                    else => ctx.quit = true,
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
        .mouse => |mouse| if (self.destination != null and !self.export_open and (mouse.button == .wheel_up or mouse.button == .wheel_down)) {
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
    else if (self.new_activity)
        try std.fmt.allocPrint(ctx.arena, "Session {s}  ·  New activity · Esc follows", .{&id})
    else
        try std.fmt.allocPrint(ctx.arena, "Session {s}  ·  Esc returns", .{&id})) else "Sessions  ·  Alt-↑/↓ select · Alt-Enter open";
    self.status.text = if (self.export_open) "Alt-↑/↓ select from page at opening · Wheel/Page scroll · Esc close" else if (self.notice.len == 0) "Enter send · Alt-E export · Shift-Enter/Ctrl-J newline · Ctrl-Q quit" else self.notice;
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
        if (self.following) self.feed.scroll_view.jumpToEnd();
    }
    const body = if (self.destination == null) try self.list.draw(body_ctx) else if (self.export_open) body: {
        const export_width = width -| @intFromBool(self.export_view.draw_vertical_scrollbar);
        if (self.export_index.width == null or self.export_index.width.? != export_width) {
            try self.export_index.reflow(self.init.gpa, &self.export_text, body_ctx.withConstraints(.{ .width = export_width }, .{ .width = export_width, .height = null }));
            self.export_view.scroll_view.children = .{ .builder = self.export_index.builder() };
            self.export_view.scroll_view.item_count = @intCast(self.export_index.len);
            self.export_view.estimated_content_height = @intCast(self.export_index.len);
        }
        break :body try self.export_view.draw(body_ctx);
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
