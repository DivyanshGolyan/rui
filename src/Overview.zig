const std = @import("std");
const session_list = @import("session_list.zig");
const model_catalog = @import("model_catalog.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const TerminalApp = @import("TerminalApp.zig");
const Root = @import("Root.zig");
const AppSettings = @import("app_settings.zig");
const SignIn = @import("SignIn.zig");
const AppScreen = @import("AppScreen.zig");
const GroupedList = @import("GroupedList.zig");
const Hover = @import("widgets/Hover.zig");
const host_identity = @import("host_identity.zig");
const platform = @import("platform.zig");
const host_restart = @import("host_restart.zig");
const OverviewLines = @import("OverviewLines.zig");
const client = @import("client.zig");
const configure_input = @import("configure_input.zig");
const process_memory = @import("process_memory.zig");
const product_defaults = @import("product_defaults.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const model_list = @import("model_list.zig");
const model_picker = @import("model_picker.zig");
const stderr = @import("stderr.zig");
const test_poll = @import("test_poll");
const app_events = @import("testing/app_events.zig");
const view = @import("overview_view.zig");
const ClientTask = @import("ClientTask.zig");
const UpgradeJob = @import("UpgradeJob.zig");
const session_upgrade = @import("session_upgrade.zig");
const upgrade_status = @import("upgrade_status.zig");
const session_chrome = @import("session_chrome.zig");
const SessionFrontend = @import("SessionFrontend.zig");
const session_reads = @import("session_reads.zig");
const SessionInput = @import("SessionInput.zig");
const SessionScreen = @import("SessionScreen.zig");
const session_id = @import("session_id.zig");
const Follow = @import("session_follow.zig").Follow;
const TerminalText = @import("TerminalText.zig");
const keymap = @import("keymap.zig");
const keypress = @import("keypress.zig");
const model_capability = @import("model_capability.zig");
const new_session_selection = @import("new_session_selection.zig");
const preferences = @import("preferences.zig");
const marks = @import("marks.zig");
const handoff = @import("relaunch_handoff.zig");

const Self = @This();

pub const Options = struct {
    store: []const u8,
    workspace: []const u8,
    home: []const u8,
    directory: []const u8,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    login_at: ?u64 = null,
    sign_in: bool = false,
    selectors: new_session_selection.Intent = .{},
    open: ?view.Reference = null,
    restoration: ?*const handoff.Payload = null,
};

pub const Relaunch = struct {
    executable: []const u8,
    handoff: []const u8,
    receipt: []const u8,
    open: ?view.Reference,

    pub fn deinit(self: Relaunch, gpa: std.mem.Allocator) void {
        gpa.free(self.executable);
        gpa.free(self.handoff);
        gpa.free(self.receipt);
    }

    pub fn writeFallback(self: Relaunch, store: []const u8) void {
        _ = stderr.writeReceipt(self.receipt);
        TerminalApp.detached(store, if (self.open) |*id| id else null, null);
    }
};

pub const Hooks = struct {
    scratch: *const fn (std.process.Init) anyerror!std.Io.File,
    command: SessionFrontend.Command,
    configure: ?session_reads.Configure = null,
    requests: SessionFrontend.Requests,
    status: SessionFrontend.Status,
    captured: *const fn (std.Io) anyerror!void,
    activate: ?SignIn.Activate = null,
    ready: ?SignIn.Ready = null,
    start_host: *const fn (std.process.Init, []const u8) HostLaunch,
};

pub const HostLaunch = @import("host_launch.zig").Summary;

const HostObservation = union(enum) {
    unread,
    ready: struct { facts: view.Host, paused: bool = false },
    stopped: platform.StoreLease.LastStop,
    unavailable,
    incompatible,
    unreadable,

    fn facts(self: HostObservation) ?view.Host {
        return switch (self) {
            .ready => |ready| ready.facts,
            else => null,
        };
    }

    fn restartSeen(self: HostObservation) host_restart.Seen {
        return switch (self) {
            .unread, .ready => .up,
            .stopped => |stop| .{ .stopped = stop },
            .unavailable, .incompatible, .unreadable => .held,
        };
    }
};

pub const HostRead = struct {
    observation: HostObservation = .unavailable,
    memory: ?view.Memory = null,
};

pub const Operations = struct {
    host: *const fn (*Self) HostRead,
    start_host: *const fn (*Self) HostLaunch,
    list: *const fn (*Self, client.Requests, protocol_reply.SessionListCursor, *protocol_reply.SessionListPage) anyerror!?protocol_reply.ReadFailure,
    first_line: *const fn (*Self, client.Requests, []const u8, u64, []u8) anyerror!protocol_reply.ActivityPrefixReply,
    create: *const fn (*Self, client.Requests, configure_input.ConfigureInput, *Reply) anyerror!void,
    stop: *const fn (*Self, client.Requests, client.SessionStopInput, *Reply) anyerror!void,
    archive: *const fn (*Self, client.Requests, client.SessionArchiveInput, *Reply) anyerror!void,
    pin: *const fn (*Self, client.Requests, client.SessionPinInput, *Reply) anyerror!void,
    models: *const fn (*Self, client.Requests, std.mem.Allocator) anyerror![]u8,
    open: *const fn (*Self, *vxfw.EventContext) anyerror!void,
};

pub const client_operations: Operations = .{ .host = hostFacts, .start_host = startHost, .list = listPage, .first_line = firstLine, .create = createSession, .stop = stopSession, .archive = archiveSession, .pin = pinSession, .models = listModels, .open = openSession };

pub const Left = struct {
    session: view.Reference,
    frontend: ?*SessionFrontend,
    files: ?SessionFrontend.Files,
    ended: anyerror!SessionFrontend.Outcome,
};

pub const Reply = struct {
    outcome: enum { accepted, failed, unconfirmed } = .failed,
    session: view.Reference = undefined,
    archive_pending: bool = false,
    text: protocol.Bounded(@max(protocol.max_code_bytes, client.Environment.too_large_bytes)) = .{},
    handle: protocol.Bounded(protocol.max_key_bytes) = .{},

    fn refused(code: []const u8) Reply {
        var reply: Reply = .{};
        reply.text.set(code[0..@min(code.len, protocol.max_code_bytes)]) catch {};
        return reply;
    }

    fn environmentTooLarge(environment: client.Environment) Reply {
        var reply: Reply = .{};
        var buffer: [client.Environment.too_large_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        environment.describeTooLarge(&writer) catch unreachable;
        reply.text.set(writer.buffered()) catch unreachable;
        return reply;
    }

    fn record(self: *Reply, sent: anytype, handle: []const u8) error{CanonicalStoreFailure}!void {
        const reply = switch (sent) {
            .failed => {
                self.* = unconfirmed(handle);
                return;
            },
            .done => |reply| reply,
        };
        const answer = reply.answer catch |err| {
            self.* = unconfirmed(handle);
            return switch (err) {
                error.CanonicalStoreFailure => |fenced| fenced,
                else => {},
            };
        };
        var result: Reply = switch (answer.result) {
            .accepted => .{ .outcome = .accepted },
            .rejected => |code| refused(code.slice()),
            .conflict => refused("conflict"),
        };
        if (result.outcome == .accepted) {
            const session = reply.context.session.slice();
            const len = @typeInfo(view.Reference).array.len;
            if (session.len == len) result.session = session[0..len].*;
        }
        if (answer.result == .accepted and answer.result.accepted == .session_archive)
            result.archive_pending = answer.result.accepted.session_archive.completion == .pending;
        result.handle.set(handle) catch {};
        self.* = result;
    }

    fn unconfirmed(handle: []const u8) Reply {
        var reply: Reply = .{ .outcome = .unconfirmed };
        reply.text.set(handle) catch {};
        reply.handle.set(handle) catch {};
        return reply;
    }

    fn created(self: *const Reply) view.CreateResult {
        return switch (self.outcome) {
            .accepted => .{ .created = .{ .reference = self.session, .handle = self.handle.slice() } },
            .failed => .{ .failed = self.text.slice() },
            .unconfirmed => .{ .unconfirmed = self.text.slice() },
        };
    }

    fn archive(self: *const Reply, request: view.ArchiveRequest) view.ArchiveResult {
        return .{ .request = request, .outcome = switch (self.outcome) {
            .accepted => .{ .requested = if (self.archive_pending) .pending else .completed },
            .failed => .{ .failed = self.text.slice() },
            .unconfirmed => .{ .unconfirmed = self.text.slice() },
        } };
    }

    fn stop(self: *const Reply) view.StopOutcome {
        return switch (self.outcome) {
            .accepted => .stopped,
            .failed => .{ .failed = self.text.slice() },
            .unconfirmed => .{ .unconfirmed = self.text.slice() },
        };
    }
};

const DefaultsEdit = struct {
    edit: preferences.Edit,
    bytes: []u8,

    fn init(gpa: std.mem.Allocator, edit: preferences.Edit) !DefaultsEdit {
        var length: usize = 0;
        inline for (.{ "store", "provider", "model" }) |field| {
            const change = @field(edit, field);
            if (change == .set) length = std.math.add(usize, length, change.set.len) catch return error.OutOfMemory;
        }
        const bytes = try gpa.alloc(u8, length);
        var owned = edit;
        var offset: usize = 0;
        inline for (.{ "store", "provider", "model" }) |field| {
            const change = @field(edit, field);
            if (change == .set) {
                const text = bytes[offset..][0..change.set.len];
                @memcpy(text, change.set);
                @field(owned, field) = .{ .set = text };
                offset += text.len;
            }
        }
        return .{ .edit = owned, .bytes = bytes };
    }

    fn deinit(self: DefaultsEdit, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }
};

const CreationSettings = struct {
    effort: ?model_capability.ReasoningEffort = null,
    permission: ?protocol.PermissionMode = null,
};

const CreationSnapshot = struct {
    binding: ?view.Default,
    settings: anyerror!CreationSettings,

    fn read(binding: ?view.Default, home: []const u8, inherit_effort: bool, load: *const fn ([]const u8) anyerror!preferences.Values) CreationSnapshot {
        const saved: preferences.Values = if (home.len == 0) .{} else load(home) catch |err| return .{ .binding = binding, .settings = err };
        return .{ .binding = binding, .settings = .{
            .effort = if (inherit_effort and binding != null) saved.reasoning_effort else null,
            .permission = saved.permission_mode,
        } };
    }
};

const Job = union(enum) {
    host,
    start_host,
    list,
    lines: view.Reads,
    create: CreationSnapshot,
    stop: view.Reference,
    archive: view.ArchiveRequest,
    pin: view.PinRequest,
    models,
    defaults: DefaultsEdit,

    const Quiescence = enum { cancel_read, settle_effect };

    fn quiescence(self: Job) Quiescence {
        return switch (self) {
            .host, .list, .lines, .models => .cancel_read,
            .start_host, .create, .stop, .archive, .pin, .defaults => .settle_effect,
        };
    }

    fn deinit(self: Job, gpa: std.mem.Allocator) void {
        switch (self) {
            .defaults => |edit| edit.deinit(gpa),
            else => {},
        }
    }
};

const Answer = union(enum) {
    none,
    host: HostRead,
    start_host: struct { read: HostRead, launch: HostLaunch },
    page: protocol_reply.SessionListPage,
    lines: [view.max_first_line_reads]Line,
    reply: Reply,
    menu: model_picker.Menu,

    fn deinit(self: *Answer, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .menu => |*menu| menu.deinit(gpa),
            else => {},
        }
        self.* = .none;
    }
};

const max_jobs = 10 + view.max_requests;

const background_wait_ms = 200;

const Line = struct { bytes: [view.max_line_read_bytes]u8 = undefined, result: enum { line, refused, unanswered } = .unanswered, len: usize = 0 };

const Signals = struct {
    var cancellation: client.Cancellation = .{};
};

init: std.process.Init,
options: Options,
signed_in_store: protocol.Bounded(protocol.max_store_bytes) = .{},
hooks: Hooks,
ops: Operations,
state: view.State,
defaults_save: AppSettings.SaveState = .idle,
caps: view.Caps,
app: ?*TerminalApp = null,
attention: *TerminalApp.Attention = undefined,
root: Root = undefined,
sign_in: SignIn = .{},
app_screen: AppScreen.Overview = undefined,
app_sessions: GroupedList = .{},
app_new_session: OverviewLines.SessionControls = undefined,
session_drafts: @import("session_drafts.zig").Drafts = .{},
app_settings_line: OverviewLines.Settings = undefined,
app_header: OverviewLines.Header = undefined,
app_redraw_at: ?u64 = null,
app_host_hover: Hover = .{},
session_screen: *SessionScreen = undefined,
app_session: ?Left = null,
follow: Follow = .{},
retired: std.ArrayList(struct { left: Left, frame: u64 }) = .empty,
interrupted: *client.Cancellation,
worker: ClientTask = .{},
upgrade_job: UpgradeJob = .{},
host_process: ?struct { started_at: u64, pid: i32 } = null,
host_observation: HostObservation = .unread,
host_launch: ?HostLaunch = null,
restart_allowance: host_restart.Allowance = .unspent,
upgrade_report: ?std.Io.Writer.Allocating = null,
relaunch_build: ?[]const u8 = null,
upgrade_guidance: bool = false,
relaunch_line: [upgrade_status.max_line_bytes]u8 = undefined,
relaunch_line_len: usize = 0,
title: session_chrome.Title = .{},
initial_list_deadline: ?u64 = null,
jobs: [max_jobs]Job = undefined,
job_count: usize = 0,
job: Job = .list,
answer: Answer = .none,
traversal: protocol_reply.SessionTraversal = .init(null),
traversal_archive: protocol.SessionArchiveFilter = .active,
scratch: ?std.Io.File = null,

opened: view.Reference = undefined,
lent_failed: bool = false,
started: ?view.Reference = null,
screen_fresh: bool = true,
screen_ready: bool = false,

pub fn run(init: std.process.Init, options: Options, hooks: Hooks) !?Relaunch {
    const self = try create(init, options, hooks, client_operations, &Signals.cancellation);
    defer self.destroy();
    _ = try view.step(&self.state, .{ .launch_start = .{ .explicit_session = options.open != null, .restoring = options.restoration != null } });
    try self.restoreRelaunch();
    const screen = try init.gpa.create(SessionScreen);
    defer init.gpa.destroy(screen);
    const prepared: anyerror!void = prepare: {
        self.scratch = hooks.scratch(init) catch |err| break :prepare err;
        self.initScreen(screen) catch |err| break :prepare err;
        self.caps.width = screen.vx.caps.unicode;
    };
    prepared catch |err| return self.failed(err, options.open);
    defer if (self.screen_ready) screen.deinit();
    self.session_screen = screen;
    Signals.cancellation.stopped.store(false, .release);
    var app: TerminalApp = undefined;
    app.init(init.io, init.environ_map) catch |err| return self.failed(err, self.options.open);
    self.app = &app;
    self.attention = &app.attention;
    const ended = startup: {
        _ = self.takeHostRead(self.ops.host(self)) catch |err| break :startup @as(anyerror!void, err);
        break :startup app.run(self.root.widget());
    };
    self.stopApp();
    app.deinit();
    return self.finishApp(ended);
}

fn stopApp(self: *Self) void {
    self.root.closeMainPresentation();
    self.root.settings_page.cancelChoice();
    self.sign_in.cancel();
    if (self.app_session) |left| if (left.frontend) |frontend| frontend.stop();
    self.worker.cancel();
}

fn initScreen(self: *Self, screen: *SessionScreen) !void {
    const no_colour: []const u8 = self.init.environ_map.get("NO_COLOR") orelse "";
    try screen.init(self.init.io, self.init.environ_map, no_colour.len == 0);
    self.screen_ready = true;
}

fn initialListHeld(self: *Self, width: u16, now_ms: u64) bool {
    const deadline = self.initial_list_deadline orelse return false;
    if (width < Root.split_at or self.state.listed_at_ms != null or self.state.list_stale or hostHeld(self) or now_ms >= deadline) {
        self.initial_list_deadline = null;
        return false;
    }
    return true;
}

fn holdInitialPresentation(raw: *anyopaque, width: u16) bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.initialListHeld(width, self.animationMs());
}

fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = appEvent, .drawFn = appDraw };
}

fn listWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = appListDraw };
}

fn paintDivider(self: *Self) void {
    self.root.divider = .{
        .grapheme = if (self.caps.unicode) "│" else "|",
        .style = @import("widget_style.zig").of(self.caps, .{ .colour = .quiet }),
    };
}

fn paintCursor(self: *Self) !void {
    self.paintDivider();
    if (self.caps.depth == .none) return;
    const theme = @import("theme.zig");
    const mode: theme.Mode = if (self.caps.skin() == .day) .light else .dark;
    const colour = theme.text(mode, .direct, .strong, .ground).direct;
    try self.attention.vx.setTerminalCursorColor(self.attention.out, colour);
}

fn paintGround(self: *Self) !void {
    if (self.caps.depth != .direct) return;
    const theme = @import("theme.zig");
    const mode: theme.Mode = if (self.caps.skin() == .day) .light else .dark;
    const colour = theme.background(mode, .direct, .ground).direct;
    try self.attention.vx.setTerminalBackgroundColor(self.attention.out, colour);
}

fn appEvent(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (input) {
        .init => {
            const app = &self.app.?.app;
            self.caps.width = app.vx.caps.unicode;
            try app.vx.queryColor(app.tty.writer(), .bg);
            try self.paintCursor();
            try ctx.requestFocus(self.widget());
            if (self.options.open) |reference| {
                self.initial_list_deadline = self.animationMs() + 150;
                try self.appNext(ctx, try self.event(.{ .open = reference }));
            }
        },
        .focus_in => try ctx.requestFocus(self.widget()),
        .color_report => |report| if (report.kind == .bg) {
            self.caps.background = report.value;
            try self.paintCursor();
            try self.paintGround();
            if (self.app_session) |left| left.frontend.?.app_caps = self.caps;
            ctx.redraw = true;
        },
        .color_scheme => {
            const app = &self.app.?.app;
            try app.tty.writer().writeAll(vaxis.ctlseqs.osc11_reset);
            try app.vx.queryColor(app.tty.writer(), .bg);
        },
        .tick => {
            if (self.signInIsFirstRun()) return;
            try self.appNext(ctx, try self.event(.{ .list_settled = .{ .wide = self.root.size.width >= Root.split_at, .focused = self.root.input.listFocused() and self.root.input.layer == .main } }));
            while (self.retired.items.len != 0 and self.retired.items[0].frame < self.root.frames) {
                self.disposeSession(self.retired.orderedRemove(0).left);
            }
            const revision = self.state.presentation_revision;
            const host_state = self.hostState();
            const host_launch = self.host_launch;
            if (self.root.session != null) {
                if (self.state.upgrading()) try self.appUpgrade(ctx) else {
                    _ = try service(self);
                }
            } else {
                if (self.worker.thread != null and self.worker.completed()) {
                    try self.appNext(ctx, try self.complete());
                }
                const now = self.realMs();
                if (self.state.upgrading()) try self.appUpgrade(ctx) else {
                    if (self.state.wakeAt()) |at| if (now >= at) {
                        try self.appNext(ctx, try self.event(.{ .tick = now }));
                    };
                    try self.dispatch(.all);
                }
            }
            if (self.initial_list_deadline != null and self.root.size.width != 0 and !self.initialListHeld(self.root.size.width, self.animationMs())) ctx.redraw = true;
            if (!self.state.upgrading()) try self.appDiscoverUpgrade(ctx);
            const launch = try self.eventResult(.launch_poll);
            try self.appNext(ctx, launch.next);
            ctx.redraw = ctx.redraw or launch.redraw;
            if (!self.root.input.layer.settingsOpen()) try self.root.settings_page.widget().handleEvent(ctx, .tick);
            if (self.state.presentation_revision != revision or self.hostState() != host_state or !std.meta.eql(self.host_launch, host_launch) or self.wantsFrame()) ctx.redraw = true;
            const open: ?[]const u8 = if (self.app_session) |shown| if (shown.frontend) |frontend| frontend.titleName() else null else null;
            if (self.title.next(open, self.state.summary.counts.needs_you)) |text| try ctx.setTitle(text);
        },
        .key_press, .paste_start, .paste_end => try appKey(self, ctx, input, .{
            .under = if (self.root.input.layer.settingsOpen()) .settings else .main,
            .pasted = self.root.input.pasting,
        }),
        else => {},
    }
}

fn appKey(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event, delivery: @import("app_input.zig").Effects.Delivery) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const selected = keypress.selectEvent(view.keys, input, delivery.pasted);
    const semantic: view.Input = switch (selected) {
        .action => |action| .{ .action = action },
        .enter => .enter,
        .left => .left,
        else => .ignored,
    };
    try self.appNext(ctx, try self.event(.{ .input = .{
        .key = semantic,
        .under = delivery.under == .settings,
        .pasted = delivery.pasted,
        .wide = delivery.wide,
    } }));
    ctx.consumeAndRedraw();
}

fn appClick(raw: *anyopaque, ctx: *vxfw.EventContext, click: view.Click) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const upgrade_admitted = if (self.app_session) |shown| (if (shown.frontend) |frontend| frontend.admitsUpgrade() else true) else true;
    try self.appNext(ctx, try self.event(.{ .clicked = .{ .target = click, .upgrade_admitted = upgrade_admitted } }));
    ctx.redraw = true;
}

fn appNext(self: *Self, ctx: *vxfw.EventContext, next: ?Next) !void {
    switch (next orelse return) {
        .leave => {
            self.root.closeMainPresentation();
            self.root.settings_page.cancelChoice();
            ctx.quit = true;
        },
        .open_settings => try self.root.openSettings(ctx),
        .focus_chat => try self.root.focusChat(ctx),
        .new_session => {
            try self.root.showMain(ctx);
            try self.app_session.?.frontend.?.newSession(ctx);
        },

        .open => |opening| {
            const reference = opening.reference;
            try self.root.showMain(ctx);
            if (self.root.session != null) {
                try self.app_session.?.frontend.?.openPeer(ctx, &reference);
            } else {
                self.opened = reference;
                self.ops.open(self, ctx) catch |err| {
                    if (self.app_session == null) self.app_session = .{ .session = reference, .frontend = null, .files = null, .ended = err };
                    ctx.quit = true;
                };
            }
            if (opening.browse) _ = try self.root.focusList(ctx);
        },
    }
}

fn openSession(self: *Self, ctx: *vxfw.EventContext) !void {
    const reference = self.opened;
    const screen = self.session_screen;
    if (!self.screen_fresh) {
        screen.deinit();
        self.screen_ready = false;
        try self.initScreen(screen);
    }
    self.screen_fresh = false;
    var opened: [6]std.Io.File = undefined;
    var count: usize = 0;
    errdefer for (opened[0..count]) |file| file.close(self.init.io);
    for (&opened) |*file| {
        file.* = try self.hooks.scratch(self.init);
        count += 1;
    }
    const files: SessionFrontend.Files = .{ .scratch = opened[0], .action = opened[1], .inspection = opened[2], .details = opened[3], .actions = opened[4..6].* };
    const frontend = try self.init.gpa.create(SessionFrontend);
    const lender: SessionFrontend.Lender = .{ .context = self, .step = conversed, .service = service, .line = conversationLine, .observed = observed, .upgrade = upgradeValue, .archive_state = archiveState, .models = modelsSnapshot };
    frontend.begin(self.init, self.options.store, &self.opened, self.options.directory, files, self.hooks.command, self.hooks.requests, self.hooks.status, screen, self.interrupted, lender);
    const child = frontend.attach(.{ .configure = self.hooks.configure, .drafts = &self.session_drafts, .root = &self.root, .context = self, .leave = appSessionLeft, .copy = appCopy, .on_open = appSessionFollow, .host = .{ .context = self, .held = hostHeld, .lost = hostLost, .startable = hostStartable, .start = requestHostStart, .notice = hostNotice } }, self.caps);
    self.app_session = .{ .session = reference, .frontend = frontend, .files = files, .ended = .detached };
    count = 0;
    _ = try self.event(.{ .conversation = reference });
    try self.root.openSession(ctx, child, frontend.keyOwner());
}

fn appSessionLeft(raw: *anyopaque, ctx: *vxfw.EventContext, outcome: SessionFrontend.Outcome) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const left = &self.app_session.?;
    const from = left.session;
    left.ended = outcome;
    if (outcome == .returned or outcome == .new_session) switch (left.frontend.?.back(view.canHoldSend(&self.state))) {
        .ended => |ended| left.ended = ended,
        .overview => |recovery| {
            if (recovery != .none) _ = try self.event(.{ .unconfirmed = .{ .reference = left.session, .recovery = recovery } });
            try self.retired.append(self.init.gpa, .{ .left = left.*, .frame = self.root.frames });
            self.app_session = null;
            _ = try self.event(.{ .conversation = null });
            try self.root.closeSession(ctx);
            if (outcome == .new_session) {
                self.follow = .{};
                return self.appNext(ctx, try self.event(.{ .clicked = .{ .target = .new_session } }));
            }
            return self.followNext(ctx, from);
        },
    };
    ctx.quit = true;
}

fn appSessionFollow(raw: *anyopaque, _: *vxfw.EventContext, target: *const [session_id.bytes]u8) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.follow.pending = target.*;
}

fn followNext(self: *Self, ctx: *vxfw.EventContext, from: view.Reference) !void {
    if (self.follow.next(from)) |target| try self.appNext(ctx, try self.event(.{ .open = target }));
}

fn appCopy(raw: *anyopaque, file: std.Io.File, start: u64, length: u64) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    const bytes = try self.init.gpa.alloc(u8, @intCast(length));
    defer self.init.gpa.free(bytes);
    if (try file.readPositionalAll(self.init.io, bytes, start) != bytes.len) return error.TruncatedDisplayScratch;
    const app = &self.app.?.app;
    try app.vx.copyToSystemClipboard(app.tty.writer(), bytes, self.init.gpa);
}

fn appDiscoverUpgrade(self: *Self, ctx: *vxfw.EventContext) !void {
    const job = &self.upgrade_job;
    if (!job.started and !job.discovery_attempted) job.discover(self.init) catch {};
    if (!job.discovering() or !job.started) return;
    if (try job.advance()) {
        const available = job.availability();
        if (!std.meta.eql(available, self.state.upgrade.available)) {
            _ = try self.event(.{ .available_upgrade = available });
            ctx.redraw = true;
        }
    }
}

fn appUpgrade(self: *Self, ctx: *vxfw.EventContext) !void {
    const job = &self.upgrade_job;
    if (job.discovering()) {
        const cancelled = self.state.upgrade.run.? == .cancelling;
        if (!try job.retireDiscovery(cancelled)) return;
        if (cancelled) job.cancel();
        _ = try self.event(.{ .available_upgrade = null });
    }
    if (!job.started and try self.quiesceUpgrade() and self.conversationSettled()) job.begin(self.init, self.options.store) catch {};
    const done = job.started and try job.advance();
    const stands = job.status();
    if (!std.meta.eql(stands, self.state.upgrade.run.?)) {
        try self.appNext(ctx, try self.event(.{ .upgrade = stands }));
        ctx.redraw = true;
    }
    if (done) {
        const installed = job.relaunchBuild() != null;
        try self.keepUpgrade();
        if (installed) self.leaveForUpgrade(ctx, stands.ended.outcome);
    }
}

fn leaveForUpgrade(self: *Self, ctx: *vxfw.EventContext, outcome: session_upgrade.Outcome) void {
    if (self.relaunch_build == null) return;
    if (session_upgrade.relaunch(outcome, self.upgrade_guidance or self.pendingDepartureGuidance())) {
        ctx.quit = true;
    } else {
        self.init.gpa.free(self.relaunch_build.?);
        self.relaunch_build = null;
    }
}

noinline fn pendingDepartureGuidance(self: *const Self) bool {
    var bytes: [view.max_requests * 512]u8 = undefined;
    var text = std.Io.Writer.fixed(&bytes);
    self.departureText(&text);
    if (text.buffered().len != 0) return true;
    if (self.app_session) |left| return if (left.frontend) |frontend| frontend.hasDepartureGuidance() else true;
    return false;
}

fn conversationSettled(self: *const Self) bool {
    const shown = self.app_session orelse return true;
    const frontend = shown.frontend orelse return true;
    return self.root.session == null or frontend.atRest();
}

fn keepUpgrade(self: *Self) !void {
    const job = &self.upgrade_job;
    if (!job.started) return;
    if (job.discovering()) {
        job.deinit();
        return;
    }
    self.upgrade_guidance = self.upgrade_guidance or job.hasGuidance();
    if (self.relaunch_build) |build| self.init.gpa.free(build);
    self.relaunch_build = null;
    if (job.relaunchBuild()) |build| {
        self.relaunch_build = try self.init.gpa.dupe(u8, build);
        const stands = job.status();
        const line = upgrade_status.relaunchLine(stands, &self.relaunch_line, if (self.caps.unicode) .unicode else .ascii);
        self.relaunch_line_len = line.len;
    }
    const detailed = job.failure != null or job.cleanup.any() or job.outcome == .incompatible;
    if (detailed or job.result != null) {
        if (self.upgrade_report == null) self.upgrade_report = .init(self.init.gpa);
        const writer = &self.upgrade_report.?.writer;
        if (detailed) try job.writeReport(writer) else try job.writeReceipt(writer);
    }
    job.deinit();
}

fn disposeSession(self: *Self, left: Left) void {
    if (left.files) |files| {
        inline for (.{ "scratch", "action", "inspection", "details" }) |name| @field(files, name).close(self.init.io);
        for (files.actions) |file| file.close(self.init.io);
    }
    if (left.frontend) |frontend| self.init.gpa.destroy(frontend);
}

fn finishApp(self: *Self, ended: anyerror!void) !?Relaunch {
    const sign_in_ended = self.sign_in.stop();
    defer {
        for (self.retired.items) |retired| self.disposeSession(retired.left);
        self.retired.deinit(self.init.gpa);
    }
    self.upgrade_job.settle();
    const kept = self.keepUpgrade();
    self.worker.cancel();
    const answered: anyerror!?Next = if (self.event(.leave)) |_| self.complete() else |err| err;
    const saved = self.flushSaves();
    var left = self.app_session;
    self.app_session = null;
    defer if (left) |held| self.disposeSession(held);
    var departure: ?SessionFrontend.Departure = null;
    if (left) |*held| {
        ended catch |err| {
            held.ended = err;
        };
        if (answered) |_| {} else |err| {
            held.ended = err;
        }
        saved catch |err| {
            held.ended = err;
        };
        kept catch |err| {
            held.ended = err;
        };
        sign_in_ended catch |err| {
            held.ended = err;
        };
        if (held.frontend) |frontend| departure = frontend.settleDeparture(held.ended, {});
    }
    return self.finishDeparture(ended, answered, saved, kept, sign_in_ended, left, departure);
}

noinline fn finishDeparture(self: *Self, ended: anyerror!void, answered: anyerror!?Next, saved: anyerror!void, kept: anyerror!void, sign_in_ended: anyerror!void, left: ?Left, departure: ?SessionFrontend.Departure) !?Relaunch {
    var bytes: [view.max_requests * 512]u8 = undefined;
    var text = std.Io.Writer.fixed(&bytes);
    self.departureText(&text);
    const has_failure = std.meta.isError(ended) or std.meta.isError(answered) or std.meta.isError(saved) or std.meta.isError(kept) or std.meta.isError(sign_in_ended);
    const guidance = has_failure or self.upgrade_guidance or text.buffered().len != 0 or
        (if (departure) |value| value.has_guidance else left != null);
    const outcome: session_upgrade.Outcome = if (self.state.upgrade.run) |stands| if (stands == .ended) stands.ended.outcome else .unchanged else .unchanged;
    if (session_upgrade.relaunch(outcome, guidance) and self.relaunch_build != null) {
        if (self.makeRelaunch(left)) |request| return request else |_| {}
    }
    if (self.upgrade_report) |*report| _ = stderr.writeReceipt(report.written());
    _ = stderr.write(text.buffered());
    if (left) |held| {
        try self.leaveFinished(held, departure);
        return null;
    }
    try sign_in_ended;
    TerminalApp.detached(self.options.store, null, null);
    try ended;
    _ = try answered;
    try saved;
    try kept;
    return null;
}

fn makeRelaunch(self: *Self, left: ?Left) !Relaunch {
    const gpa = self.init.gpa;
    if (left) |held| if (held.frontend) |frontend| {
        try self.session_drafts.put(gpa, &held.session, frontend.input.snapshot());
    };
    var entries: std.ArrayList(handoff.Entry) = .empty;
    defer entries.deinit(gpa);
    var drafts = self.session_drafts.iterator();
    while (drafts.next()) |entry| try entries.append(gpa, .{ .id = entry.id, .snapshot = entry.snapshot });
    const bytes = try handoff.encode(gpa, .{
        .v = 1,
        .store = self.options.store,
        .open = if (left) |*held| &held.session else null,
        .overview = .{ .bytes = "", .cursor = 0 },
        .drafts = entries.items,
        .line = self.relaunch_line[0..self.relaunch_line_len],
    });
    errdefer gpa.free(bytes);
    const executable = try std.fmt.allocPrint(gpa, "{s}/bin/rui", .{self.relaunch_build.?});
    errdefer gpa.free(executable);
    const receipt = try gpa.dupe(u8, if (self.upgrade_report) |*report| report.written() else "");
    return .{ .executable = executable, .handoff = bytes, .receipt = receipt, .open = if (left) |held| held.session else null };
}

fn restoreRelaunch(self: *Self) !void {
    const value = self.options.restoration orelse return;
    self.options.restoration = null;
    for (value.drafts) |entry| try self.session_drafts.put(self.init.gpa, entry.id, entry.snapshot);
    if (value.open) |id| self.options.open = id[0..session_id.bytes].*;
}

const SessionRows = struct {
    state: *const view.State,
    width: u16,
    caps: view.Caps,
    frame: u64,

    fn count(raw: *const anyopaque, first: u32) u32 {
        const self: *const SessionRows = @ptrCast(@alignCast(raw));
        return @intCast(view.Lines.sessionsFrom(self.state, first));
    }

    fn above(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!@import("widgets/List.zig").List(u32).Line {
        return try arena.dupe(vaxis.Segment, &.{.{ .text = try std.fmt.allocPrint(arena, "↑ {d} more", .{count_}) }});
    }

    fn below(count_: u32, arena: std.mem.Allocator) std.mem.Allocator.Error!@import("widgets/List.zig").List(u32).Line {
        const segments = try arena.alloc(vaxis.Segment, 1);
        segments[0] = .{ .text = try std.fmt.allocPrint(arena, "↓ {d} more", .{count_}) };
        return segments;
    }

    fn row(raw: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!GroupedList.Row {
        const self: *const SessionRows = @ptrCast(@alignCast(raw));
        const built = (try view.Lines.at(arena, self.state, index, self.width, self.caps, self.frame)).?;
        return .{ .segments = built.segments, .heading = built.heading, .target = built.target, .alternate_target = built.alternate };
    }
};

fn rich(ctx: vxfw.DrawContext, caps: view.Caps, segments: []const view.Segment) !vxfw.Widget {
    const spans = try @import("widget_style.zig").segments(ctx.arena, caps, segments, null);
    const text = try ctx.arena.create(vxfw.RichText);
    text.* = .{ .text = spans, .softwrap = false, .width_basis = .parent };
    return text.widget();
}

fn wantsFrame(self: *const Self) bool {
    return self.wantsFrameAt(self.animationMs());
}

fn wantsFrameAt(self: *const Self, awake_ms: u64) bool {
    if (!self.root.listVisible()) return false;
    return if (self.app_redraw_at) |at| awake_ms >= at else false;
}

fn animationMs(self: *const Self) u64 {
    const now = std.Io.Clock.awake.now(self.init.io).nanoseconds;
    return @intCast(@divFloor(@max(now, 0), std.time.ns_per_ms));
}

fn bottomWidget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = drawBottom };
}

fn drawBottom(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const footer = try ctx.arena.create(@import("widgets/Footer.zig"));
    footer.* = .{
        .left = "",
        .right = view.footerRight(&self.state),
        .notice = if (view.footerNotice(&self.state)) |notice| try @import("session_chrome.zig").noticeLine(ctx.arena, notice) else null,
        .style = @import("widget_style.zig").of(self.caps, .{ .colour = .quiet }),
    };
    if (self.state.notice) |notice| footer.right_style = @import("widget_style.zig").of(self.caps, .{ .colour = notice.colour });
    const notice = try view.noticeSegments(ctx.arena, &self.state, ctx.max.width.?, self.caps);
    const Stack = @import("widgets/Stack.zig");
    const children = try ctx.arena.alloc(Stack.Child, @as(usize, 1) + @intFromBool(notice != null));
    if (notice) |text| children[0] = .{ .widget = try rich(ctx, self.caps, text) };
    children[children.len - 1] = .{ .widget = footer.widget() };
    const stack = try ctx.arena.create(Stack);
    stack.* = .{ .children = children };
    var surface = try stack.widget().draw(ctx);
    surface.widget = self.bottomWidget();
    return surface;
}

fn appDraw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.drawPart(ctx, .whole);
}

fn appListDraw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.drawPart(ctx, .list);
}

fn drawPart(self: *Self, ctx: vxfw.DrawContext, part: AppScreen.Overview.Part) std.mem.Allocator.Error!vxfw.Surface {
    const size = ctx.max.size();
    if (part == .whole) _ = try view.step(&self.state, .{ .launch_size = .{ .size = .{ .width = size.width, .height = size.height }, .wide = size.width >= Root.split_at } });
    self.caps.width = self.attention.vx.caps.unicode;
    const normal = @import("widget_style.zig").of(self.caps, .{});
    self.sign_in.style = normal;
    self.sign_in.unicode = self.caps.unicode;
    self.sign_in.selection_style = @import("widget_style.zig").of(self.caps, .{ .background = .selection });
    self.sign_in.quiet = @import("widget_style.zig").of(self.caps, .{ .colour = .quiet });
    self.app_screen.style = normal;
    if (self.signInIsFirstRun() or (part == .whole and self.state.hidesOverview())) {
        const ground = try vxfw.Surface.init(ctx.cell_arena, self.widget(), size);
        @memset(ground.buffer, .{ .style = normal });
        return ground;
    }
    const host = if (part == .list) null else hostNotice(self);
    self.state.host_line = host != null;
    _ = try view.step(&self.state, .{ .resized = .{ .width = size.width, .height = size.height } });
    const awake_ms = self.animationMs();
    const frame = awake_ms / view.spin_interval_ms;
    const rows = try ctx.arena.create(SessionRows);
    rows.* = .{ .state = &self.state, .width = @import("widgets/RowInset.zig").contentWidth(size.width), .caps = self.caps, .frame = frame };
    self.app_sessions.selected = if (view.Lines.highlighted(&self.state, self.root.input.listFocused() or self.root.session == null)) |line| @intCast(line) else null;
    self.app_sessions.selection_background = if (self.root.session != null and !self.root.input.listFocused()) .bar else .selection;
    self.app_sessions.rows = .{ .userdata = rows, .count = @intCast(view.Lines.count(&self.state)), .rowFn = SessionRows.row, .countFromFn = SessionRows.count };
    self.app_sessions.aboveFn = SessionRows.above;
    self.app_sessions.belowFn = SessionRows.below;
    self.app_settings_line.selected = self.root.input.area == .settings_row or (self.root.input.listFocused() and self.state.selected == .settings);
    self.app_settings_line.memory = self.state.memory;
    self.app_settings_line.run = self.state.upgrade.run;
    self.app_settings_line.available = self.state.upgrade.available;
    self.app_settings_line.caps = self.caps;
    self.app_sessions.tail = .{ .widget = self.app_settings_line.widget(), .rows = view.layout(&self.state).settings.len() };
    self.app_sessions.caps = self.caps;
    self.app_header.caps = self.caps;
    self.app_new_session.caps = self.caps;
    const header = try ctx.arena.create(@import("widgets/Stack.zig"));
    header.* = .{ .priority = .top, .children = try ctx.arena.dupe(@import("widgets/Stack.zig").Child, &.{
        .{ .widget = self.app_new_session.widget() },
        .{ .widget = self.app_header.widget() },
    }) };
    self.app_screen.header = header.widget();
    defer {
        self.app_sessions.rows = .none;
        self.app_sessions.tail = null;
        self.app_screen.header = null;
        self.app_screen.host = null;
    }
    self.app_screen.host = host;
    self.app_header.drawn = false;
    var surface = try self.app_screen.drawPart(ctx, part);
    self.app_redraw_at = view.nextRedrawAt(&self.state, .{
        .first = self.app_sessions.shown.first,
        .end = self.app_sessions.shown.end,
        .header = self.app_header.drawn,
    }, self.caps, awake_ms);
    surface.widget = if (part == .list) self.listWidget() else self.widget();
    return surface;
}

const app_empty: vxfw.Text = .{ .text = "" };

fn failed(self: *const Self, err: anyerror, session: ?view.Reference) anyerror {
    return printFailure(err, self.options.store, session, self.started);
}

pub fn printFailure(err: anyerror, store: []const u8, session: ?view.Reference, started: ?view.Reference) anyerror {
    var bytes: [4 * (protocol.max_store_bytes + protocol.max_session_bytes) + 384]u8 = undefined;
    var notice = std.Io.Writer.fixed(&bytes);
    write: {
        if (err == error.InvalidTemporaryDirectory)
            notice.writeAll(if (session == null) "rui: Fix or unset TMPDIR before opening the overview.\n" else "rui: Fix or unset TMPDIR before resuming.\n") catch break :write;
        const reference = session orelse break :write;
        if (started) |start| if (std.mem.eql(u8, &start, &reference)) {
            notice.print("\nrui: Created {s}.\n", .{&reference}) catch break :write;
        };
        notice.writeAll("\nResume: rui session resume --store ") catch break :write;
        TerminalText.writeShellWord(&notice, store) catch break :write;
        TerminalText.writeShellSession(&notice, &reference, true) catch break :write;
        notice.writeByte('\n') catch break :write;
    }
    _ = stderr.write(notice.buffered());
    return err;
}

fn create(init: std.process.Init, options: Options, hooks: Hooks, ops: Operations, interrupted: *client.Cancellation) !*Self {
    const self = try init.gpa.create(Self);
    errdefer init.gpa.destroy(self);
    self.* = .{
        .init = init,
        .options = options,
        .hooks = hooks,
        .ops = ops,
        .state = undefined,
        .caps = .of(.{ .lc_all = init.environ_map.get("LC_ALL"), .lc_ctype = init.environ_map.get("LC_CTYPE"), .lang = init.environ_map.get("LANG"), .no_color = init.environ_map.get("NO_COLOR"), .colorterm = init.environ_map.get("COLORTERM") }),
        .interrupted = interrupted,
    };
    self.root = .{ .settings_control = self.app_settings_line.widget(), .settings_activate = OverviewLines.Settings.activate, .main_presentation = .{ .context = self, .close = closeMainPresentation }, .presentation_hold = .{ .context = self, .held = holdInitialPresentation }, .overview = self.widget(), .overview_keys = .{ .context = self, .take = appKey }, .list = self.listWidget(), .settings_page = .{ .backend = self.settingsBackend(), .version = @import("transport_options").version }, .input = .{ .area = .list, .layer = if (options.sign_in) .{ .sign_in = .{ .over = .main } } else .main } };
    self.sign_in = .{ .init = init, .selectors = options.selectors, .activate = hooks.activate, .ready = hooks.ready, .scratch = hooks.scratch, .userdata = self, .on_done = signedIn, .on_close = closeSignIn };
    try self.sign_in.target.set(options.store);
    self.root.sign_in = self.sign_in.widget();
    self.paintDivider();
    self.app_screen = .{ .content = &self.app_sessions, .input = self.bottomWidget(), .userdata = self, .on_event = appEvent };
    self.app_header = .{ .state = &self.state };
    self.app_new_session = .{ .state = &self.state, .caps = self.caps, .userdata = self, .on_click = appClick };
    self.app_settings_line = .{ .selected = false, .caps = self.caps, .userdata = self, .on_click = appClick };
    self.app_sessions.on_press = .{ .userdata = self, .pressed = appClick };
    try self.state.init(init.gpa, .{ .cwd = options.workspace, .home = options.home, .login_at = options.login_at, .default = .of(options.provider, options.model) });
    errdefer self.state.deinit();
    return self;
}

fn closeMainPresentation(raw: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.app_session) |left| if (left.frontend) |frontend| frontend.closePresentation();
}

fn openSignIn(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.sign_in.task.thread != null) return;
    if (!view.admitsDefaultsEdit(&self.state) or self.defaults_save == .pending) return error.DefaultsUnavailable;
    try self.sign_in.reset();
    self.sign_in.selectors = self.options.selectors;
    self.sign_in.selectors.store = self.options.store;
    try self.sign_in.target.set(self.options.store);
    try self.root.openSignIn(ctx);
}

fn listVisible(raw: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.root.listVisible();
}

/// The first-run screen is the only thing the app can do, so it stays until
/// sign-in gives a default; a screen opened from Settings always returns there.
fn signInIsFirstRun(self: *const Self) bool {
    return self.root.input.layer.signInOpen() and !self.root.input.layer.settingsOpen() and self.state.default == null;
}

fn closeSignIn(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.signInIsFirstRun()) return;
    try self.root.closeSignIn(ctx);
}

fn signedIn(raw: *anyopaque, ctx: *vxfw.EventContext, activation: SignIn.Activation) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (!std.mem.eql(u8, self.options.store, activation.store.slice())) {
        std.debug.assert(self.worker.thread == null);
        self.signed_in_store = activation.store;
        self.options.store = self.signed_in_store.slice();
    }
    const saved = view.Default.of(activation.binding.provider.slice(), activation.binding.model.slice());
    try self.appNext(ctx, try self.event(.{ .defaults_saved = saved }));
    self.state.login_at = self.realMs() / 1000;
    self.state.next_list_ms = 0;
    const warning = if (activation.launch) |*launch| launch.warning else null;
    if (activation.default_failed or warning != null) {
        var notice: view.Notice = .{ .colour = .failure };
        var writer = std.Io.Writer.fixed(&notice.bytes);
        if (warning != null) {
            try @import("host_launch.zig").writeSignIn(&writer, .{ .ready = warning }, activation.default_failed, false);
        } else try writer.writeAll("Sign-in saved; couldn't save default");
        notice.len = writer.buffered().len;
        self.state.notice = notice;
    }
    try self.root.signedIn(ctx);
    if (self.root.session == null) try ctx.requestFocus(self.widget());
}

pub fn saveDefaults(self: *Self, edit: preferences.Edit) !void {
    if (!view.admitsDefaultsEdit(&self.state) or self.defaults_save == .pending or self.job_count == max_jobs) return error.DefaultsUnavailable;
    const owned = try DefaultsEdit.init(self.init.gpa, edit);
    self.queue(.{ .defaults = owned });
    self.defaults_save = .pending;
}

pub fn startUpgrade(self: *Self) !void {
    if (self.state.left) return error.UpgradeUnavailable;
    if (self.app_session) |shown| if (shown.frontend) |frontend| {
        if (!frontend.admitsUpgrade()) return error.UpgradeUnavailable;
    };
    const next = try self.event(.start_upgrade);
    std.debug.assert(next == null);
}

fn settingsBackend(self: *Self) AppSettings.Backend {
    const Callbacks = struct {
        fn owner(raw: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw));
        }
        fn read(raw: *anyopaque) !preferences.Values {
            return preferences.load(owner(raw).options.home);
        }
        fn save(raw: *anyopaque, edit: preferences.Edit) !void {
            return owner(raw).saveDefaults(edit);
        }
        fn saveState(raw: *anyopaque) AppSettings.SaveState {
            return owner(raw).defaults_save;
        }
        fn upgrade(raw: *anyopaque) !void {
            return owner(raw).startUpgrade();
        }
        fn run(raw: *anyopaque) ?upgrade_status.Run {
            return owner(raw).state.upgrade.run;
        }
        fn signIn(raw: *anyopaque, ctx: *vxfw.EventContext) !void {
            try owner(raw).openSignIn(ctx);
        }
        fn caps(raw: *anyopaque) view.Caps {
            return owner(raw).caps;
        }
    };
    return .{ .context = self, .read = Callbacks.read, .save = Callbacks.save, .save_state = Callbacks.saveState, .upgrade = Callbacks.upgrade, .run = Callbacks.run, .caps = Callbacks.caps, .models = modelsSnapshot, .sign_in = Callbacks.signIn, .memory = memoryValue };
}

fn destroy(self: *Self) void {
    self.sign_in.deinit();
    self.session_drafts.deinit(self.init.gpa);
    std.debug.assert(self.worker.thread == null);
    self.upgrade_job.deinit();
    if (self.relaunch_build) |build| self.init.gpa.free(build);
    if (self.upgrade_report) |*report| report.deinit();
    self.job.deinit(self.init.gpa);
    for (self.jobs[0..self.job_count]) |job| job.deinit(self.init.gpa);
    if (self.scratch) |file| file.close(self.init.io);
    self.state.deinit();
    self.answer.deinit(self.init.gpa);
    self.init.gpa.destroy(self);
}

const Ending = union(enum) { overview, conversation: Left };

/// What the core asks of the loop: to leave or present a pane under Root.
const Next = union(enum) { leave, open: struct { reference: view.Reference, browse: bool = false }, open_settings, focus_chat, new_session };

fn event(self: *Self, value: view.Event) error{OutOfMemory}!?Next {
    return (try self.eventResult(value)).next;
}

const EventResult = struct { next: ?Next = null, intent_admission: view.IntentAdmission = .refused, redraw: bool = false };

fn eventResult(self: *Self, value: view.Event) !EventResult {
    const held_host = self.state.holdsHost();
    const effects = try view.step(&self.state, value);
    if (held_host and !self.state.holdsHost()) {
        self.host_observation = .unavailable;
        self.queueHost();
    }
    var next: ?Next = null;
    for (effects.slice()) |effect| switch (effect) {
        .open_settings => next = .open_settings,
        .focus_chat => next = .focus_chat,
        .new_session => next = .new_session,
        .list => |since| {
            self.traversal = .init(since);
            self.traversal_archive = self.state.listing_archive.?;
            if (self.state.listed_at_ms != null) self.queueHost();
            self.queue(.list);
            if (self.state.listed_at_ms == null) self.queueHost();
        },
        .read_first_lines => |reads| self.queue(.{ .lines = reads }),
        .create => |binding| self.queue(.{ .create = self.creationSnapshot(binding) }),
        .stop => |reference| self.queue(.{ .stop = reference }),
        .cancel_upgrade => {
            self.upgrade_job.cancel();
            if (self.upgrade_job.discovering()) _ = try self.event(.{ .upgrade = .cancelling });
        },
        .archive => |request| self.queue(.{ .archive = request }),
        .pin => |request| self.queue(.{ .pin = request }),
        .list_models => self.queue(.models),
        .open => |reference| next = .{ .open = .{ .reference = reference, .browse = effects.browse_open } },
        .exit => return .{ .next = .leave, .intent_admission = effects.intent_admission },
    };
    self.sendStatuses();
    return .{ .next = next, .intent_admission = effects.intent_admission, .redraw = effects.redraw };
}

fn sendStatuses(self: *Self) void {
    if (self.state.left) return;
    const out = self.attention;
    if (self.state.statusesSettled() and !out.statuses_shown) return;
    if (!(preferences.load(self.options.home) catch preferences.Values{}).notifications) {
        out.clear() catch return;
        self.state.statusesCleared();
        return;
    }
    var records = self.state.unsettledStatuses();
    while (records.next()) |record| {
        if (out.report(&record.reference, record.name, record.status) catch return) self.state.statusTaken(record.taken());
    }
}

fn take(self: *Self, index: usize) Job {
    const job = self.jobs[index];
    std.mem.copyForwards(Job, self.jobs[index .. self.job_count - 1], self.jobs[index + 1 .. self.job_count]);
    self.job_count -= 1;
    return job;
}

fn queue(self: *Self, job: Job) void {
    std.debug.assert(self.job_count < max_jobs);
    self.jobs[self.job_count] = job;
    self.job_count += 1;
}

fn dispatch(self: *Self, jobs: enum { all, lent }) !void {
    if (self.worker.thread != null) return;
    const queued = self.jobs[0..self.job_count];
    const at = switch (jobs) {
        .all => if (queued.len == 0) return else 0,
        .lent => for (queued, 0..) |job, index| {
            if (job == .stop) break index;
        } else for (queued, 0..) |job, index| {
            if (job != .create) break index;
        } else return,
    };
    const next = self.take(at);
    self.job.deinit(self.init.gpa);
    self.job = next;
    self.worker.start(self.init.io, self, work) catch |err| {
        if (next != .start_host) return err;
        self.host_launch = .{ .failed = .{ .kind = .worker, .err = err } };
    };
}

fn work(raw: *anyopaque, task: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.runJob(task.readContext());
}

fn runJob(self: *Self, context: client.ReadContext) !void {
    const requests = context.requests();
    std.debug.assert(self.answer == .none);
    switch (self.job) {
        .host => self.answer = .{ .host = self.ops.host(self) },
        .start_host => {
            const launch = self.ops.start_host(self);
            self.answer = .{ .start_host = .{ .launch = launch, .read = self.ops.host(self) } };
        },
        .list => {
            self.answer = .{ .page = undefined };
            if (try self.ops.list(self, requests, self.traversal.cursor, &self.answer.page)) |failure| return failure.err();
        },
        .lines => |reads| {
            self.answer = .{ .lines = @splat(.{}) };
            for (reads.slice(), self.answer.lines[0..reads.len]) |read, *line| switch (try self.ops.first_line(self, requests, &read.reference, read.position, &line.bytes)) {
                .line => |text| {
                    line.result = .line;
                    line.len = text.len;
                },
                .failure => |failure| switch (failure.err()) {
                    error.HostInvocationFailed => line.result = .refused,
                    error.CanonicalStoreFailure => |err| return err,
                },
            };
        },
        .create => |*snapshot| {
            var compaction_buffer: [20]u8 = undefined;
            const input = self.creationInput(snapshot, &compaction_buffer) catch |err| {
                self.answer = .{ .reply = .refused(@errorName(err)) };
                return;
            };
            self.answer = .{ .reply = .refused("create_request_failed") };
            try self.ops.create(self, requests, input, &self.answer.reply);
        },
        .stop => |*reference| {
            self.answer = .{ .reply = .refused("stop_request_failed") };
            try self.ops.stop(self, requests, .{ .store = self.options.store, .session = reference }, &self.answer.reply);
        },
        .pin => |*request| {
            self.answer = .{ .reply = .refused("pin_request_failed") };
            try self.ops.pin(self, requests, .{ .store = self.options.store, .session = &request.reference, .pinned = request.pinned }, &self.answer.reply);
        },
        .archive => |*request| {
            self.answer = .{ .reply = .refused("archive_request_failed") };
            try self.ops.archive(self, requests, .{ .store = self.options.store, .session = &request.reference, .archived = request.archived }, &self.answer.reply);
        },
        .models => {
            const gpa = self.init.gpa;
            const body = try self.ops.models(self, requests, gpa);
            defer gpa.free(body);
            self.answer = .{ .menu = try model_picker.read(gpa, try protocol_reply.modelListProviders(body)) };
        },
        .defaults => |edit| {
            const readiness: preferences.Readinesses = .initFill(.configured);
            _ = try preferences.update(self.options.home, edit.edit, &readiness);
        },
    }
}

fn flushSaves(self: *Self) !void {
    var origin: client.FailureOrigin = .local;
    const requests: client.ReadContext = .{ .io = self.init.io, .origin = &origin };
    var failure: ?anyerror = null;
    while (for (self.jobs[0..self.job_count], 0..) |job, index| {
        if (job == .defaults) break index;
    } else null) |index| {
        self.job.deinit(self.init.gpa);
        self.job = self.take(index);
        _ = self.deliver(self.runJob(requests)) catch |err| {
            if (failure == null) failure = err;
        };
    }
    if (failure) |err| return err;
}

fn complete(self: *Self) !?Next {
    if (self.worker.thread == null) return null;
    const outcome = self.worker.join();
    const next = try self.deliver(outcome);
    outcome catch |err| if (err == error.CanonicalStoreFailure) return err;
    return next;
}

fn deliver(self: *Self, outcome: anyerror!void) !?Next {
    const answer = &self.answer;
    defer answer.deinit(self.init.gpa);
    switch (self.job) {
        .start_host => {
            outcome catch |err| {
                self.host_launch = .{ .failed = .{ .kind = .worker, .err = err } };
                return null;
            };
            const launch = answer.start_host.launch;
            const next = try self.takeHostRead(answer.start_host.read);
            self.host_launch = switch (launch) {
                .ready => |warning| if (warning == null) null else launch,
                .failed => if (self.host_observation == .ready) null else launch,
            };
            return next;
        },
        .host => return self.takeHostRead(answer.host),
        .list => {
            outcome catch return self.event(.{ .list = .failed });
            var rows: [view.max_page_rows]view.Listed = undefined;
            const page: view.Page = .of(&self.traversal, &answer.page, &rows);
            if (page.answer == null) self.queue(.list);
            return self.event(.{ .list = .{ .page = page } });
        },
        .lines => |reads| for (reads.slice(), answer.lines[0..reads.len]) |read, *line| {
            const result: view.FirstLine = .{ .reference = read.reference, .admission = read.admission, .line = if (line.result == .line) line.bytes[0..line.len] else null, .unanswered = line.result == .unanswered };
            if (try self.event(.{ .first_line = result })) |next| return next;
        },
        .create => {
            if (answer.reply.outcome == .accepted) self.started = answer.reply.session;
            return self.event(.{ .created = answer.reply.created() });
        },
        .stop => |reference| return self.event(.{ .stop = .{ .reference = reference, .outcome = answer.reply.stop() } }),
        .pin => |request| return self.event(.{ .pin = .{ .request = request, .outcome = switch (answer.reply.outcome) {
            .accepted => .accepted,
            .failed => .{ .failed = answer.reply.text.slice() },
            .unconfirmed => .{ .unconfirmed = answer.reply.text.slice() },
        } } }),
        .archive => |request| {
            const result = answer.reply.archive(request);
            if (self.app_session) |attached| if (attached.frontend) |frontend| {
                if (std.mem.eql(u8, &result.request.reference, &attached.session)) frontend.archiveAnswered(result);
            };
            return self.event(.{ .archive = result });
        },

        .models => {
            outcome catch |err| return self.event(.{ .models = .failed(err) });
            const menu = answer.menu;
            answer.* = .none;
            return self.event(.{ .models = .{ .menu = menu } });
        },
        .defaults => {
            const written = if (outcome) |_| true else |err| preferences.failure(err).saved;
            const next = if (written) try self.event(.{ .defaults_saved = self.savedDefault() }) else null;
            std.debug.assert(next == null);
            if (outcome) |_| {
                self.defaults_save = .saved;
            } else |err| {
                self.defaults_save = .failed;
                if (self.state.left) return err;
            }
        },
    }
    return null;
}

fn savedDefault(self: *const Self) ?view.Default {
    if (!self.options.selectors.needsPreferences() or self.options.home.len == 0) return null;
    return resolveDefault(&self.state, .{
        .intent = self.options.selectors,
        .defaults = preferences.load(self.options.home) catch return null,
    });
}

fn resolveDefault(state: *const view.State, saved: new_session_selection.Snapshot) ?view.Default {
    if (!saved.intent.needsPreferences()) return null;
    var snapshot = saved;
    snapshot.intent.provider = state.savedProvider(snapshot.intent.provider, if (snapshot.defaults.provider.len != 0) snapshot.defaults.provider.slice() else null);
    const binding = (snapshot.resolve(&.initFill(.configured)) catch return null) orelse return null;
    return view.Default.of(binding.provider.slice(), binding.model.slice());
}

fn creationSnapshot(self: *const Self, binding: ?view.Default) CreationSnapshot {
    return .read(binding, self.options.home, self.options.selectors.needsPreferences(), preferences.load);
}

fn creationInput(self: *const Self, snapshot: *const CreationSnapshot, compaction_buffer: *[20]u8) !configure_input.ConfigureInput {
    const saved = try snapshot.settings;
    const binding = &snapshot.binding;
    var configuration: configure_input.ConfigureInput = .{
        .store = self.options.store,
        .session = .create,
        .require_model = true,
        .workspace = .{ .present = true, .value = self.options.workspace },
        .provider = if (binding.*) |value| .{ .present = true, .value = @tagName(value.provider) } else .{},
        .model = if (binding.*) |*value| .{ .present = true, .value = value.model.slice() } else .{},
    };
    configuration.completeCreation(if (binding.*) |value| value.provider else .codex, if (binding.*) |*value| value.model.slice() else product_defaults.recommended_model, @import("os/read_image_file.zig").available, saved.effort, saved.permission, compaction_buffer);
    return configuration;
}

fn listModels(self: *Self, requests: client.Requests, gpa: std.mem.Allocator) ![]u8 {
    return requests.modelList(self.options.store, gpa);
}

fn realMs(self: *const Self) u64 {
    return @intCast(@max(std.Io.Clock.real.now(self.init.io).toMilliseconds(), 0));
}

fn conversed(raw: *anyopaque, kind: view.Kind, input: view.ConversationInput) !view.IntentAdmission {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    const result = try self.eventResult(.{ .conversed = .{ .reference = self.opened, .work = kind, .input = input } });
    std.debug.assert(result.next == null);
    try self.dispatch(.lent);
    return result.intent_admission;
}

fn observed(raw: *anyopaque, read: session_list.Snapshot, opening: bool) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    const next = try self.event(.{ .observed = .{ .reference = self.opened, .read_version = read.read_version, .work = read.work, .last_line = read.last_line, .opening = opening } });
    std.debug.assert(next == null);
}

fn service(raw: *anyopaque) !bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    errdefer self.lent_failed = true;
    if (self.state.upgrade.after == .blocked) return false;
    const now_ms = self.realMs();
    if (self.state.wakeAt()) |at| if (now_ms >= at) {
        _ = try self.event(.{ .tick = now_ms });
    };
    const answered = self.worker.thread != null and self.worker.completed();
    if (answered) {
        const next = try self.complete();
        std.debug.assert(next == null);
    }
    try self.dispatch(.lent);
    return answered;
}

fn quiesceUpgrade(self: *Self) !bool {
    if (self.worker.thread == null) try self.dispatch(.all);
    if (self.worker.thread != null) {
        switch (self.job.quiescence()) {
            .cancel_read => self.worker.cancel(),
            .settle_effect => {},
        }
        if (self.worker.completed()) {
            if (try self.complete()) |next| switch (next) {
                .leave => return error.InteractiveInterrupted,
                .open => |opening| self.started = opening.reference,
                // Only direct list input asks for settings, never a worker answer.
                .open_settings, .focus_chat, .new_session => unreachable,
            };
        }
    }
    return self.worker.thread == null and self.job_count == 0;
}

fn memoryValue(raw: *anyopaque) ?view.Memory {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.state.memory;
}

fn modelsSnapshot(raw: *anyopaque) @import("model_choice.zig").Snapshot {
    const self: *Self = @ptrCast(@alignCast(raw));
    const state = &self.state;
    return .{ .menu = if (state.menu_read == .read or state.menu.entries.len > 0) &state.menu else null, .revision = state.menu_revision, .ready = state.modelsReady() };
}

fn archiveState(raw: *anyopaque) @import("chat_info.zig").SaveState {
    const self: *Self = @ptrCast(@alignCast(raw));
    var at = self.state.request_count;
    while (at > 0) {
        at -= 1;
        const request = self.state.requests[at];
        if (request.kind != .archive or request.session == null or !std.mem.eql(u8, &request.session.?, &self.opened)) continue;
        return switch (request.status) {
            .pending => .pending,
            .done => .saved,
            .failed, .unknown => .failed,
        };
    }
    return .idle;
}

fn upgradeValue(raw: *anyopaque) session_upgrade.Upgrade {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.state.upgrade;
}

fn conversationLine(raw: *anyopaque, kind: view.Kind) SessionFrontend.Lender.Said {
    const self: *Self = @ptrCast(@alignCast(raw));
    const said = view.conversation(&self.state, self.opened, kind);
    return .{ .text = said.text, .notice = said.notice, .stoppable = said.stoppable };
}

fn departureText(self: *const Self, out: *std.Io.Writer) void {
    view.writeDeparture(&self.state, null, out) catch unreachable;
}

fn leaveFinished(self: *Self, left: Left, settled: ?SessionFrontend.Departure) !void {
    const session = &left.session;
    const store = self.options.store;
    const outcome: anyerror!void = run: {
        const frontend = left.frontend orelse {
            _ = left.ended catch |err| break :run err;
            break :run {};
        };
        const departure = settled.?;
        frontend.writeDeparture(departure);
        const end = departure.end catch |err| {
            if (departure.failure_notice) TerminalApp.detached(store, session, departure.action);
            break :run err;
        };
        switch (end) {
            .detached, .interrupted => TerminalApp.detached(store, session, departure.action),
            .returned, .new_session => unreachable,
        }
    };
    return outcome catch |err| {
        if (self.lent_failed) return err;
        return self.failed(err, left.session);
    };
}

fn takeHostRead(self: *Self, read: HostRead) !?Next {
    const previous = self.host_observation;
    self.host_observation = read.observation;
    if (read.observation == .ready) self.host_launch = null;
    const restart = host_restart.decide(.{
        .previous = previous.restartSeen(),
        .next = read.observation.restartSeen(),
        .allowance = self.restart_allowance,
        .upgrade_holds = self.state.holdsHost(),
        .start_available = !self.hostStarting() and self.launchNext() != null,
    });
    self.restart_allowance = restart.allowance;
    if (restart.start) self.queueHostStart();
    if (read.memory) |memory| _ = try self.event(.{ .memory = memory });
    return self.event(.{ .host = read.observation.facts() });
}

fn hostStarting(self: *const Self) bool {
    if (self.worker.thread != null and self.job == .start_host) return true;
    for (self.jobs[0..self.job_count]) |job| if (job == .start_host) return true;
    return false;
}

const HostState = enum {
    ready,
    stopped,
    paused,
    incompatible,
    unreadable,
    starting,

    fn line(self: HostState) struct { mark: marks.Mark, words: []const u8 } {
        return switch (self) {
            .ready => .{ .mark = .finished, .words = "Host ready" },
            .stopped => .{ .mark = .stopped, .words = "Host stopped" },
            .paused => .{ .mark = .stopped, .words = "Host paused" },
            .incompatible => .{ .mark = .stopped, .words = "Host is a different Rui version" },
            .unreadable => .{ .mark = .stopped, .words = "Host unreachable" },
            .starting => .{ .mark = .active, .words = "Host starting" },
        };
    }
};

fn hostState(self: *const Self) HostState {
    if (self.state.upgrading()) return .paused;
    if (self.hostStarting()) return .starting;
    return switch (self.host_observation) {
        .unread => .ready,
        .ready => |ready| if (ready.paused) .paused else .ready,
        .unavailable => .paused,
        .incompatible => .incompatible,
        .unreadable => .unreadable,
        .stopped => .stopped,
    };
}

fn hostHeld(raw: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    return switch (self.host_observation) {
        .unread, .ready => false,
        .stopped, .unavailable, .incompatible, .unreadable => true,
    };
}

fn hostLost(raw: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (!hostHeld(self)) self.host_observation = .unavailable;
    if (self.state.upgrading()) return;
    if (self.worker.thread != null and self.job == .host) return;
    self.queueHost();
}

fn queueHost(self: *Self) void {
    for (self.jobs[0..self.job_count]) |job| if (job == .host) return;
    self.queue(.host);
}

fn hostNext(self: *const Self) ?HostLaunch.Next {
    if (self.state.holdsHost() or self.hostStarting() or self.host_observation != .stopped) return null;
    return self.launchNext();
}

fn launchNext(self: *const Self) ?HostLaunch.Next {
    return if (self.host_launch) |launch| switch (launch) {
        .failed => |cause| cause.next(),
        .ready => .start,
    } else .start;
}

fn queueHostStart(self: *Self) void {
    self.host_launch = null;
    self.queue(.start_host);
}

fn hostStartable(raw: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    return self.hostNext() != null;
}

fn requestHostStart(raw: *anyopaque, ctx: *vxfw.EventContext) !bool {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.hostNext() == null) return false;
    try self.requestedHostStart(ctx);
    return true;
}

fn requestedHostStart(self: *Self, ctx: *vxfw.EventContext) !void {
    self.queueHostStart();
    try self.dispatch(if (self.root.session == null) .all else .lent);
    ctx.redraw = true;
}

fn hostNotice(raw: *anyopaque) ?vxfw.Widget {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (self.hostState() == .ready and self.host_launch == null) {
        self.app_host_hover.targets = &.{};
        return null;
    }
    return .{ .userdata = self, .drawFn = drawHostNotice, .eventHandler = hostNoticeEvent };
}

fn hostNoticeEvent(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    try self.app_host_hover.handleEvent(ctx, input);
    if (input == .mouse and input.mouse.button == .left and input.mouse.type == .press) {
        for (self.app_host_hover.targets) |target| if (target.contains(input.mouse.col, input.mouse.row)) {
            _ = try requestHostStart(raw, ctx);
            break;
        };
        ctx.consumeEvent();
    }
}

fn drawHostNotice(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const state = self.hostState();
    const line = state.line();
    const detail = if (self.state.holdsHost() or state == .incompatible or state == .unreadable) null else self.host_launch;
    const mark = marks.marks.get(if (detail != null and detail.? == .failed) .failed else line.mark);
    const notice = if (detail) |value| value.words() else "";
    const key = if (self.hostNext()) |next| if (self.root.session != null) next.label() else @tagName(next) else "";
    const text = try std.fmt.allocPrint(ctx.arena, "{s} {s}{s}{s}{s}{s}", .{
        if (self.caps.unicode) mark.unicode else mark.ascii,
        line.words,
        if (notice.len == 0) "" else " · ",
        notice,
        if (key.len == 0) "" else " · ",
        key,
    });
    const label: vxfw.Text = .{ .text = text, .softwrap = false, .style = @import("widget_style.zig").of(self.caps, .{ .colour = switch (mark.tone) {
        .ink => .ink,
        .normal => .normal,
        .quiet => .quiet,
        .attention => .attention,
        .failure => .failure,
    } }) };
    var surface = try label.widget().draw(ctx.withConstraints(.{}, .{ .width = ctx.max.width, .height = @min(1, ctx.max.height.?) }));
    const target: Hover.Rect = .{ .row = 0, .width = surface.size.width, .height = surface.size.height };
    self.app_host_hover.targets = if (self.hostNext() != null and surface.size.width > 0 and surface.size.height > 0) try ctx.arena.dupe(Hover.Rect, &.{target}) else &.{};
    if (self.app_host_hover.targets.len != 0 and self.app_host_hover.contains(target)) {
        const hover = @import("widget_style.zig").of(self.caps, .{ .background = .hover });
        for (surface.buffer) |*cell| cell.style = Hover.look(cell.style, hover);
    }
    surface.widget = hostNotice(self).?;
    return surface;
}

fn startHost(self: *Self) HostLaunch {
    return self.hooks.start_host(self.init, self.options.store);
}

fn hostFacts(self: *Self) HostRead {
    const observation: HostObservation = switch (client.hostStatus(self.init.io, self.options.store)) {
        .ready => |host| .{ .ready = .{
            .facts = .{ .instance = host.instance, .started_at = host.started_at, .slots = host.active_capacity, .slots_in_use = host.custody_occupied },
            .paused = host.paused,
        } },
        .unavailable => .{ .stopped = platform.StoreLease.lastStop(self.init.io, self.options.store) },
        .owned_unavailable => .unavailable,
        .incompatible => .incompatible,
        .access_failure => .unreadable,
    };
    return .{ .observation = observation, .memory = self.liveMemory(if (observation.facts()) |host| host.started_at else null) };
}

fn liveMemory(self: *Self, host_started_at: ?u64) view.Memory {
    if (host_started_at) |started_at| {
        if (self.host_process == null or self.host_process.?.started_at != started_at) {
            self.host_process = if (client.observeHostProcess(self.init.io, self.options.store, null)) |process|
                .{ .started_at = started_at, .pid = process.pid }
            else |_|
                null;
        }
    } else self.host_process = null;
    var processes: host_identity.Processes = .{};
    return process_memory.read(&processes, std.c.getpid(), if (self.host_process) |host| host.pid else null);
}

fn listPage(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
    const Sink = struct {
        io: std.Io,
        file: std.Io.File,
        at: u64 = 0,

        pub fn feed(sink: *@This(), bytes: []const u8) !void {
            try sink.file.writePositionalAll(sink.io, bytes, sink.at);
            sink.at += bytes.len;
        }
    };
    const file = self.scratch.?;
    var sink: Sink = .{ .io = self.init.io, .file = file };
    var buffer: client.ReplyBuffer = .{};
    const reply = try requests.listSessionsFiltered(self.options.store, null, self.traversal_archive, cursor, &sink, &buffer);
    switch (try protocol_reply.SessionListReply.decode(self.init.io, file, null, cursor, reply)) {
        .page => |value| page.* = value,
        .failure => |failure| return failure,
    }
    return null;
}

fn firstLine(self: *Self, requests: client.Requests, session: []const u8, position: u64, buffer: []u8) !protocol_reply.ActivityPrefixReply {
    return requests.readActivityPrefix(self.options.store, session, position, buffer);
}

fn createSession(self: *Self, requests: client.Requests, input: configure_input.ConfigureInput, reply: *Reply) !void {
    const io = self.init.io;
    var captured = client.captureConfigure(io, input, .{ .generated = self.options.directory }).get() catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    self.hooks.captured(io) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    var buffer: client.ReplyBuffer = .{};
    return reply.record(requests.sendCaptured(&captured, .empty, &buffer), captured.identity().key.slice());
}

fn stopSession(self: *Self, requests: client.Requests, input: client.SessionStopInput, reply: *Reply) !void {
    const io = self.init.io;
    var captured = client.captureSessionStop(io, input, .{ .generated = self.options.directory }) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    var buffer: client.ReplyBuffer = .{};
    return reply.record(requests.sendCaptured(&captured, .{ .map = self.init.environ_map }, &buffer), captured.identity().key.slice());
}

fn archiveSession(self: *Self, requests: client.Requests, input: client.SessionArchiveInput, reply: *Reply) !void {
    const io = self.init.io;
    var captured = client.captureSessionArchive(io, input, .{ .generated = self.options.directory }) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    var buffer: client.ReplyBuffer = .{};
    return reply.record(requests.sendCaptured(&captured, .{ .map = self.init.environ_map }, &buffer), captured.identity().key.slice());
}

fn pinSession(self: *Self, requests: client.Requests, input: client.SessionPinInput, reply: *Reply) !void {
    const io = self.init.io;
    var captured = client.captureSessionPin(io, input, .{ .generated = self.options.directory }) catch |err| {
        reply.* = .refused(@errorName(err));
        return;
    };
    defer captured.close(io);
    var buffer: client.ReplyBuffer = .{};
    return reply.record(requests.sendCaptured(&captured, .{ .map = self.init.environ_map }, &buffer), captured.identity().key.slice());
}

const test_now_s: u64 = 1_800_000_000;

const Seen = struct {
    hosts: usize = 0,
    lists: usize = 0,
    since: ?protocol.SinceToken = null,
    line: struct { session: view.Reference = @splat(0), position: u64 = 0 } = .{},
    creates: usize = 0,
    creation: struct {
        require_model: bool = false,
        workspace: protocol.Bounded(64) = .{},
        provider: ?protocol.Bounded(64) = null,
        model: ?protocol.Bounded(64) = null,
        permission_mode: protocol.Bounded(64) = .{},
        tools: ?protocol.Bounded(protocol.max_tool_names_bytes) = null,
        loaded_tools: ?protocol.Bounded(protocol.max_tool_names_bytes) = null,
        label: ?protocol.Bounded(64) = null,
        reasoning_effort: ?protocol.Bounded(64) = null,
    } = .{},
    stops: usize = 0,
    archives: usize = 0,
    archive_session: view.Reference = @splat(0),
    archive_requested: bool = true,
    pins: usize = 0,
    pin_session: view.Reference = @splat(0),
    pin_requested: bool = true,
    archive_filter: protocol.SessionArchiveFilter = .active,
    stopped: view.Reference = @splat(0),
    conversations: usize = 0,
    conversed: view.Reference = @splat(0),
    model_lists: usize = 0,
    listed: usize = 1,
    working: usize = listed_references.len,

    var now: Seen = .{};

    fn bounded(bytes: []const u8) protocol.Bounded(64) {
        return protocol.Bounded(64).from(bytes) catch unreachable;
    }
};

const listed_references = [_][]const u8{ "k7m2qx", "b4n8wd", "p3c6tz", "h5r9vy", "m2j7fs" };

const fake_operations: Operations = .{
    .start_host = struct {
        fn start(_: *Self) HostLaunch {
            return .{ .failed = .{ .kind = .setup, .err = error.TestUnexpectedResult } };
        }
    }.start,
    .host = struct {
        fn host(_: *Self) HostRead {
            Seen.now.hosts += 1;
            return .{ .observation = .{ .ready = .{ .facts = .{ .instance = @splat(1), .started_at = test_now_s - 60, .slots = 4, .slots_in_use = 1 } } } };
        }
    }.host,
    .list = struct {
        fn list(self: *Self, _: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            Seen.now.lists += 1;
            Seen.now.archive_filter = self.traversal_archive;
            Seen.now.since = cursor.since;
            page.* = .{ .count = Seen.now.listed, .delta = .full, .since = .{ .instance = @splat(1), .generation = Seen.now.lists }, .next = null };
            for (page.rows[0..Seen.now.listed], listed_references[0..Seen.now.listed], 0..) |*row, reference, at| {
                const since = test_now_s - 10 - at;
                row.* = .{ .read_version = page.since, .work = .{ .state = if (at < Seen.now.working) .{ .working = .{ .since = since } } else .{ .idle = .{ .since = since } }, .turn = 1, .operation = 1 } };
                row.reference.set(reference) catch unreachable;
                row.workspace.set("/work") catch unreachable;
                row.model.set("gpt-5.5") catch unreachable;
                row.first_message = .{ .position = 1, .admission = 4, .admitted_at = since, .sender = null, .content = .{ .length = 27, .digest = @splat(0) } };
                row.peers.from_person_at = since;
            }
            return null;
        }
    }.list,
    .first_line = struct {
        fn firstLine(_: *Self, _: client.Requests, session: []const u8, position: u64, buffer: []u8) !protocol_reply.ActivityPrefixReply {
            Seen.now.line = .{ .session = session[0..6].*, .position = position };
            const text = "Fix the flaky test\nand more";
            @memcpy(buffer[0..text.len], text);
            return .{ .line = buffer[0..text.len] };
        }
    }.firstLine,
    .create = struct {
        fn create(_: *Self, _: client.Requests, settings: configure_input.ConfigureInput, reply: *Reply) !void {
            Seen.now.creates += 1;
            Seen.now.creation = .{
                .require_model = settings.require_model and settings.session == .create,
                .workspace = Seen.bounded(settings.workspace.value),
                .provider = if (settings.provider.present) Seen.bounded(settings.provider.value) else null,
                .model = if (settings.model.present) Seen.bounded(settings.model.value) else null,
                .permission_mode = Seen.bounded(settings.permission_mode.value),
                .tools = if (settings.tools) |tools| protocol.Bounded(protocol.max_tool_names_bytes).from(tools.cli) catch unreachable else null,
                .loaded_tools = if (settings.loaded_tools) |loaded| protocol.Bounded(protocol.max_tool_names_bytes).from(loaded.cli) catch unreachable else null,
                .label = if (settings.label.value) |label| Seen.bounded(label) else null,
                .reasoning_effort = if (settings.reasoning_effort.present) Seen.bounded(settings.reasoning_effort.value orelse "") else null,
            };
            reply.* = .{ .outcome = .accepted, .session = "n3w5es".* };
            reply.handle.set("create-handle") catch unreachable;
        }
    }.create,
    .stop = struct {
        fn stop(_: *Self, _: client.Requests, input: client.SessionStopInput, reply: *Reply) !void {
            Seen.now.stops += 1;
            Seen.now.stopped = input.session[0..6].*;
            reply.* = .{ .outcome = .accepted };
        }
    }.stop,
    .archive = struct {
        fn archive(_: *Self, _: client.Requests, input: client.SessionArchiveInput, reply: *Reply) !void {
            Seen.now.archives += 1;
            Seen.now.archive_session = input.session[0..6].*;
            Seen.now.archive_requested = input.archived;
            reply.* = .{ .outcome = .accepted, .archive_pending = input.archived };
        }
    }.archive,
    .pin = struct {
        fn pin(_: *Self, _: client.Requests, input: client.SessionPinInput, reply: *Reply) !void {
            Seen.now.pins += 1;
            Seen.now.pin_session = input.session[0..6].*;
            Seen.now.pin_requested = input.pinned;
            reply.* = .{ .outcome = .accepted };
        }
    }.pin,
    .models = struct {
        fn models(_: *Self, _: client.Requests, gpa: std.mem.Allocator) ![]u8 {
            Seen.now.model_lists += 1;
            var reply: std.Io.Writer.Allocating = .init(gpa);
            errdefer reply.deinit();
            try reply.writer.writeAll(protocol.model_list_reply.head);
            try model_list.writeProviders(&reply.writer, model_catalog.shipped, &.{
                .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\n" } } },
                .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\nwhisper-1\n" } } },
            });
            try reply.writer.writeAll(protocol.model_list_reply.tail);
            return reply.toOwnedSlice();
        }
    }.models,
    .open = struct {
        fn open(self: *Self, _: *vxfw.EventContext) !void {
            Seen.now.conversations += 1;
            Seen.now.conversed = self.opened;
        }
    }.open,
};

const Shown = struct {
    arena: std.heap.ArenaAllocator,
    screen: vaxis.Screen,

    fn deinit(self: *Shown) void {
        self.arena.deinit();
    }

    fn line(self: *Shown, row: u16) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var col: u16 = 0;
        while (self.screen.readCell(col, row)) |cell| {
            try out.appendSlice(self.arena.allocator(), cell.char.grapheme);
            col += @max(1, cell.char.width);
        }
        return std.mem.trimEnd(u8, out.items, " ");
    }

    fn text(self: *Shown) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (0..self.screen.height) |row| {
            if (row != 0) try out.append(self.arena.allocator(), '\n');
            try out.appendSlice(self.arena.allocator(), try self.line(@intCast(row)));
        }
        return out.items;
    }

    fn expectLines(self: *Shown, first: u16, expected: []const []const u8) !void {
        for (expected, first..) |want, row| try std.testing.expectEqualStrings(want, try self.line(@intCast(row)));
    }

    fn cursor(self: *const Shown) ?vaxis.Screen.Cursor {
        return if (self.screen.cursor_vis) self.screen.cursor else null;
    }
};

const Rig = struct {
    environ: std.process.Environ.Map,
    init: std.process.Init = undefined,
    screen: *SessionScreen = undefined,
    overview: *Self = undefined,
    out: std.Io.Writer.Allocating = undefined,
    taken: [64 * 1024]u8 = undefined,
    attention: TerminalApp.Attention = undefined,
    last_focus: ?vxfw.Widget = null,

    fn open(options: Options, ops: Operations, interrupted: *client.Cancellation) !*Rig {
        Seen.now = .{};
        const rig = try std.testing.allocator.create(Rig);
        errdefer std.testing.allocator.destroy(rig);
        rig.* = .{ .environ = try std.testing.environ.createMap(std.testing.allocator) };
        errdefer rig.environ.deinit();
        rig.init.gpa = std.testing.allocator;
        rig.init.io = std.testing.io;
        rig.init.environ_map = &rig.environ;
        rig.screen = try std.testing.allocator.create(SessionScreen);
        errdefer std.testing.allocator.destroy(rig.screen);
        try rig.screen.init(std.testing.io, &rig.environ, true);
        errdefer rig.screen.deinit();
        rig.overview = try create(rig.init, options, undefined, ops, interrupted);
        rig.overview.caps = .{ .depth = .none };
        rig.overview.session_screen = rig.screen;
        rig.out = .init(std.testing.allocator);
        rig.attention = .{ .vx = &rig.screen.vx, .out = &rig.out.writer };
        rig.overview.attention = &rig.attention;
        rig.overview.state.read_instance = @splat(1);
        _ = try view.step(&rig.overview.state, .{ .resized = .{ .width = 80, .height = 24 } });
        return rig;
    }

    fn close(rig: *Rig) void {
        rig.overview.worker.cancel();
        if (rig.overview.worker.thread != null) rig.overview.worker.join() catch {};
        rig.overview.destroy();
        rig.out.deinit();
        rig.screen.deinit();
        std.testing.allocator.destroy(rig.screen);
        rig.environ.deinit();
        std.testing.allocator.destroy(rig);
    }

    fn press(rig: *Rig, bytes: []const u8) !?Ending {
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try app_events.send(&ctx, bytes, rig.overview.root.widget(), rig.overview.widget());
        return if (ctx.quit) .overview else null;
    }

    fn click(rig: *Rig, column: u16, row: u16, width: u16, height: u16) !?Ending {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const frame = try rig.overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try app_events.mouse(&ctx, frame, .{ .col = @intCast(column), .row = @intCast(row), .button = .left, .type = .press, .mods = .{} });
        return if (ctx.quit) .overview else null;
    }

    fn signalled(rig: *Rig) []const u8 {
        const written = rig.out.written();
        @memcpy(rig.taken[0..written.len], written);
        rig.out.clearRetainingCapacity();
        return rig.taken[0..written.len];
    }

    fn shown(rig: *Rig, width: u16, height: u16) !Shown {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        errdefer arena.deinit();
        const surface = try rig.overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
        var screen: vaxis.Screen = try .init(arena.allocator(), .{ .rows = height, .cols = width, .x_pixel = 0, .y_pixel = 0 });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = height, .screen = &screen };
        try surface.render(window, rig.overview.root.session orelse rig.overview.widget());
        return .{ .arena = arena, .screen = screen };
    }

    fn hostStart(rig: *Rig) !?Ending {
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        _ = try requestHostStart(rig.overview, &ctx);
        return if (ctx.quit) .overview else null;
    }

    fn context(_: *Rig) vxfw.EventContext {
        return .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    }

    fn next(rig: *Rig, value: ?Next) !?Ending {
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try rig.overview.appNext(&ctx, value);
        for (ctx.cmds.items) |command| if (command == .request_focus) {
            rig.last_focus = command.request_focus;
        };
        return if (ctx.quit) .overview else null;
    }

    fn settle(rig: *Rig) !?Ending {
        const overview = rig.overview;
        while (true) {
            try overview.dispatch(.all);
            if (overview.worker.thread == null) return null;
            try rig.answered();
            if (try rig.next(try overview.complete())) |ending| return ending;
        }
    }

    fn answered(rig: *Rig) !void {
        const Worker = struct {
            fn completed(overview: *Self) !bool {
                return overview.worker.completed();
            }
        };
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), rig.overview, Worker.completed);
    }

    fn lend(rig: *Rig) !void {
        const overview = rig.overview;
        for (0..100) |_| {
            _ = try service(overview);
            const queued = for (overview.jobs[0..overview.job_count]) |job| {
                if (job != .create) break true;
            } else false;
            if (overview.worker.thread == null and !queued) return;
            if (overview.worker.thread != null) try rig.answered();
        }
        return error.TestUnexpectedResult;
    }
};

test "resumed wide presentation waits for the first live list with bounded fallback" {
    const Scenario = enum { early, late, unavailable, empty };
    for ([_]Scenario{ .early, .late, .unavailable, .empty }) |scenario| {
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .open = "k7m2qx".* }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        const chat: vxfw.Text = .{ .text = "Chat witness" };
        overview.root.session = chat.widget();
        overview.initial_list_deadline = 150;
        try std.testing.expect(overview.initialListHeld(140, 149));
        if (scenario == .late) {
            try std.testing.expect(!overview.initialListHeld(140, 150));
        }
        overview.initial_list_deadline = overview.animationMs() + 60_000;
        var held = try rig.shown(140, 30);
        defer held.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try held.text(), "Loading") == null);
        try std.testing.expect(std.mem.indexOf(u8, try held.text(), "Chat witness") == null);
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expectEqual(Job.list, std.meta.activeTag(overview.jobs[0]));
        try std.testing.expectEqual(Job.host, std.meta.activeTag(overview.jobs[1]));
        if (scenario == .late) overview.initial_list_deadline = overview.animationMs();
        if (scenario == .unavailable) overview.host_observation = .unavailable;
        if (scenario == .late or scenario == .unavailable) {
            var fallback = try rig.shown(140, 30);
            defer fallback.deinit();
            try std.testing.expect(std.mem.indexOf(u8, try fallback.text(), "Loading") != null);
            try std.testing.expect(std.mem.indexOf(u8, try fallback.text(), "Chat witness") != null);
        }
        if (scenario == .unavailable) continue;
        if (scenario == .empty) Seen.now.listed = 0;
        try overview.dispatch(.all);
        try rig.answered();
        _ = try overview.complete();
        var live = try rig.shown(140, 30);
        defer live.deinit();
        const text = try live.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "Loading") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Chat witness") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (scenario == .empty) "No unarchived Sessions." else "k7m2qx") != null);
        try std.testing.expect(overview.initial_list_deadline == null);
    }
}

test "App overview paints its ground and plain footer" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    for ([_]struct { caps: view.Caps, ground: vaxis.Color }{
        .{ .caps = .{}, .ground = .{ .rgb = .{ 0x12, 0x19, 0x33 } } },
        .{ .caps = .{ .background = .{ 255, 255, 255 } }, .ground = .{ .rgb = .{ 0xf3, 0xee, 0xe2 } } },
        .{ .caps = .{ .depth = .indexed }, .ground = .{ .index = 234 } },
        .{ .caps = .{ .depth = .none }, .ground = .default },
    }) |case| {
        rig.overview.caps = case.caps;
        var shown = try rig.shown(80, 24);
        defer shown.deinit();
        try std.testing.expectEqual(@import("widget_style.zig").of(case.caps, .{ .background = .selection }).bg, shown.screen.readCell(79, 0).?.style.bg);
        try std.testing.expectEqual(case.ground, shown.screen.readCell(79, 10).?.style.bg);
        try std.testing.expectEqual(case.ground, shown.screen.readCell(79, 22).?.style.bg);
        try std.testing.expectEqual(case.ground, shown.screen.readCell(79, 23).?.style.bg);
    }
}

test "pin separator is ground and inert beside selected controls or Sessions at both widths" {
    const rig = try openListed();
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(overview.state.order.items.len > 1);
    overview.state.rows.items[overview.state.order.items[0]].pin_order = 7;
    overview.caps = .{};
    const ground = @import("widget_style.zig").of(overview.caps, .{}).bg;
    const highlight = @import("widget_style.zig").of(overview.caps, .{ .background = .selection }).bg;
    const first: view.Selection = .{ .session = overview.state.rows.items[overview.state.order.items[0]].reference };
    for ([_]view.Selection{ .new_session, first }) |selection| for ([_]u16{ 46, 140 }) |width| {
        errdefer std.debug.print("selection={s}, width={d}\n", .{ @tagName(selection), width });
        overview.state.selected = selection;
        var shown = try rig.shown(width, 30);
        defer shown.deinit();
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "   + New Session"));
        try std.testing.expect(std.mem.indexOf(u8, try shown.line(1), "Archived") != null);
        try std.testing.expectEqual(selection == .new_session, std.meta.eql(highlight, shown.screen.readCell(1, 0).?.style.bg));
        for (0..30) |col| {
            const cell = shown.screen.readCell(@intCast(col), 3).?;
            try std.testing.expect(std.mem.trim(u8, cell.char.grapheme, " ").len == 0);
            try std.testing.expectEqual(ground, cell.style.bg);
        }
        try std.testing.expect((try shown.line(2)).len != 0);
        const opens = Seen.now.conversations;
        const pins = Seen.now.pins;
        try std.testing.expect(try rig.click(4, 3, width, 30) == null);
        try std.testing.expectEqual(selection, overview.state.selected);
        try std.testing.expectEqual(opens, Seen.now.conversations);
        try std.testing.expectEqual(pins, Seen.now.pins);
    };
}

test "App cursor contrasts with the painted ground after terminal theme reports" {
    const Check = struct {
        const luminance = @import("theme.zig").relativeLuminance;
        fn rgb(colour: vaxis.Color) [3]u8 {
            return switch (colour) {
                .rgb => |value| value,
                .index => |i| @import("theme.zig").xtermRgb(i),
                else => unreachable,
            };
        }
    };
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    for ([_]view.Caps.Depth{ .direct, .indexed }) |depth| {
        for ([_][3]u8{ .{ 255, 255, 255 }, .{ 0, 0, 0 } }) |terminal| {
            rig.overview.caps.depth = depth;
            var ctx = rig.context();
            defer ctx.cmds.deinit(std.testing.allocator);
            try appEvent(rig.overview, &ctx, .{ .color_report = .{ .kind = .bg, .value = terminal } });
            const emitted = rig.signalled();
            const prefix = "\x1b]12;rgb:";
            const start = std.mem.indexOf(u8, emitted, prefix) orelse return error.TestUnexpectedResult;
            const colour = emitted[start + prefix.len ..];
            try std.testing.expect(colour.len >= 14);
            const cursor: [3]u8 = .{
                try std.fmt.parseInt(u8, colour[0..2], 16),
                try std.fmt.parseInt(u8, colour[5..7], 16),
                try std.fmt.parseInt(u8, colour[10..12], 16),
            };
            var shown = try rig.shown(80, 24);
            defer shown.deinit();
            const ground = Check.rgb(shown.screen.readCell(79, 10).?.style.bg);
            const background_prefix = "\x1b]11;rgb:";
            if (depth == .direct) {
                const background_start = std.mem.indexOf(u8, emitted, background_prefix);
                try std.testing.expectEqual(true, background_start != null);
                const background = emitted[background_start.? + background_prefix.len ..];
                try std.testing.expect(background.len >= 14);
                const painted: [3]u8 = .{
                    try std.fmt.parseInt(u8, background[0..2], 16),
                    try std.fmt.parseInt(u8, background[5..7], 16),
                    try std.fmt.parseInt(u8, background[10..12], 16),
                };
                try std.testing.expectEqual(ground, painted);
            } else {
                try std.testing.expect(std.mem.indexOf(u8, emitted, "\x1b]11;") == null);
            }
            const a = Check.luminance(cursor);
            const b = Check.luminance(ground);
            const contrast = (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
            if (contrast < 4.5) std.debug.print("cursor on {s}: {d:.3}\n", .{ @tagName(depth), contrast });
            try std.testing.expect(contrast >= 4.5);
        }
    }
    try rig.screen.vx.resetState(&rig.out.writer);
    const reset = rig.signalled();
    try std.testing.expect(std.mem.indexOf(u8, reset, "\x1b]112\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, reset, "\x1b]111\x1b\\") != null);
    rig.overview.caps.depth = .none;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try appEvent(rig.overview, &ctx, .{ .color_report = .{ .kind = .bg, .value = .{ 255, 255, 255 } } });
    try std.testing.expectEqualStrings("", rig.signalled());
}

test "each effect runs its client operation and each result reaches the core" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.hosts);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.lists);
    try std.testing.expect(Seen.now.since == null);
    try std.testing.expectEqual(@as(u64, 4), overview.state.host.?.slots);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.line.session);
    try std.testing.expectEqual(@as(u64, 1), Seen.now.line.position);
    const row = overview.state.find("k7m2qx".*).?;
    try std.testing.expectEqualStrings("Fix the flaky test", overview.state.lineOf(row).?);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(?u64, 1), if (Seen.now.since) |since| since.generation else null);

    try std.testing.expect(try rig.press("\x1b[H\r") == null);
    try std.testing.expect(try rig.settle() == null);
    const start = &Seen.now.creation;
    try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
    try std.testing.expect(start.require_model);
    try std.testing.expectEqualStrings("/work", start.workspace.slice());
    try std.testing.expectEqualStrings("codex", start.provider.?.slice());
    try std.testing.expectEqualStrings("gpt-5.5", start.model.?.slice());
    try std.testing.expectEqualStrings(product_defaults.permission_mode, start.permission_mode.slice());
    try std.testing.expect(start.label == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("n3w5es", &Seen.now.conversed);

    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.stopped);

    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    const ending = (try rig.press("\x04")).?;
    try std.testing.expect(ending == .overview);
}

test "returning from a Session refreshes saved effort in facts and app settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .low } }, &.initFill(.configured));
    var ops = fake_operations;
    ops.open = openSession;
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    Scratch.dir = tmp.dir;
    Scratch.count = 0;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6-luna" }, ops, &cancellation);
    defer rig.close();
    rig.overview.hooks.scratch = Scratch.scratch;
    try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
    defer {
        for (rig.overview.retired.items) |retired| rig.overview.disposeSession(retired.left);
        rig.overview.retired.deinit(std.testing.allocator);
    }
    _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .high } }, &.initFill(.configured));
    rig.overview.app_session.?.frontend.?.leaving = .returned;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try appSessionLeft(rig.overview, &ctx, .returned);
    const next_creation = rig.overview.creationSnapshot(rig.overview.state.default);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), (try next_creation.settings).effort);
    const values = try rig.overview.root.settings_page.backend.?.read(rig.overview);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), values.reasoning_effort);
}

test "facts omit an unsupported saved effort that the next start will not use" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .max } }, &.initFill(.configured));
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    {
        var shown = try rig.shown(100, 24);
        defer shown.deinit();
        try std.testing.expectEqual(false, std.mem.indexOf(u8, try shown.text(), "· max") != null);
    }
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings(product_defaults.reasoning_effort, Seen.now.creation.reasoning_effort.?.slice());
}

fn pin(home: []const u8, provider: []const u8, model: []const u8) !void {
    const readiness: preferences.Readinesses = .initFill(.configured);
    _ = try preferences.update(home, .{ .provider = .{ .set = provider }, .model = .{ .set = model } }, &readiness);
}

const explicit_selectors: new_session_selection.Intent = .{ .store = "/store", .provider = "codex", .model = "gpt-6-luna" };

test "an overview left without a pick writes no default, pinned or not" {
    for ([_]bool{ false, true }) |pinned| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        if (pinned) try pin(home, "openai", "gpt-6-luna");
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = if (pinned) "openai" else "codex", .model = if (pinned) "gpt-6-luna" else "gpt-5.5" }, fake_operations, &cancellation);
        defer rig.close();
        var buffer: [1024]u8 = undefined;
        const guidance = try finishedGuidance(rig, &buffer);
        try std.testing.expect(std.mem.indexOf(u8, guidance, "New Sessions use") == null);
        const values = try preferences.load(home);
        try std.testing.expectEqualStrings(if (pinned) "openai" else "", values.provider.slice());
        try std.testing.expectEqualStrings(if (pinned) "gpt-6-luna" else "", values.model.slice());
    }
}

test "a default saved elsewhere while the overview is open outlasts its exit without a pick" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    try pin(home, "codex", "gpt-5.5");
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.settle() == null);
    try pin(home, "openai", "gpt-6-luna");
    var buffer: [1024]u8 = undefined;
    _ = try finishedGuidance(rig, &buffer);
    const values = try preferences.load(home);
    try std.testing.expectEqualStrings("openai", values.provider.slice());
    try std.testing.expectEqualStrings("gpt-6-luna", values.model.slice());
}

test "empty creation with no saved binding requires a model without inventing one" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(Seen.now.creation.require_model);
    try std.testing.expect(Seen.now.creation.provider == null and Seen.now.creation.model == null);
    try std.testing.expectEqualStrings(product_defaults.permission_mode, Seen.now.creation.permission_mode.slice());
    try std.testing.expect(Seen.now.creation.label == null);
}

test "empty Session creation reads saved permissions even with explicit selectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    for ([_]?protocol.PermissionMode{ null, .ask, .bypass }) |saved| {
        if (saved) |mode| _ = try preferences.update(home, .{ .permission_mode = .{ .set = mode } }, &.initFill(.configured));
        for ([_]bool{ false, true }) |explicit| {
            var cancellation: client.Cancellation = .{};
            const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna", .selectors = if (explicit) explicit_selectors else .{} }, fake_operations, &cancellation);
            defer rig.close();
            try std.testing.expect(try rig.press("\r") == null);
            try std.testing.expect(try rig.settle() == null);
            try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
            try std.testing.expectEqualStrings(if (saved) |mode| @tagName(mode) else product_defaults.permission_mode, Seen.now.creation.permission_mode.slice());
        }
    }
}

test "empty creation sends the fresh tool profile" {
    const rig = try openOverview();
    defer rig.close();
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings(product_defaults.creationTools(true, @import("os/read_image_file.zig").available).allowed, Seen.now.creation.tools.?.slice());
    try std.testing.expectEqualStrings(product_defaults.creationTools(true, @import("os/read_image_file.zig").available).loaded, Seen.now.creation.loaded_tools.?.slice());
}

test "empty creation takes saved effort only when the launch reads defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    _ = try preferences.update(home, .{ .provider = .{ .set = "codex" }, .model = .{ .set = "gpt-6-luna" }, .reasoning_effort = .{ .set = .high } }, &.initFill(.configured));
    inline for (.{ false, true }) |explicit| {
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna", .selectors = if (explicit) explicit_selectors else .{} }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expect(try rig.settle() == null);
        if (explicit) try std.testing.expectEqualStrings(product_defaults.reasoning_effort, Seen.now.creation.reasoning_effort.?.slice()) else try std.testing.expectEqualStrings("high", Seen.now.creation.reasoning_effort.?.slice());
    }
}

test "the overview opens the resumed Session first, lists on its tick and leaves on Ctrl-D" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .open = "k7m2qx".* }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.next(try rig.overview.event(.{ .open = rig.overview.options.open.? })) == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.hosts);
    try std.testing.expectEqual(@as(?Ending, .overview), try rig.press("\x04"));
}

test "only your working Session's mark spins, at the frame's step, and without colour it holds still" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.caps = .{};
    try std.testing.expect(try overview.event(.{ .tick = (test_now_s - 10) * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var spinning: usize = 0;
    var line: usize = 0;
    while (line < view.Lines.count(&overview.state)) : (line += 1) {
        const at_two = (try view.Lines.at(arena.allocator(), &overview.state, line, 80, overview.caps, 2)).?;
        const at_three = (try view.Lines.at(arena.allocator(), &overview.state, line, 80, overview.caps, 3)).?;
        try std.testing.expectEqual(at_two.segments.len, at_three.segments.len);
        for (at_two.segments, at_three.segments) |two, three| if (!std.mem.eql(u8, two.text, three.text)) {
            try std.testing.expectEqualStrings(view.spinner[2], two.text);
            try std.testing.expectEqualStrings(view.spinner[3], three.text);
            try std.testing.expect(view.Lines.spins(&overview.state, line, overview.caps));
            spinning += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), spinning);
    overview.caps = .{ .depth = .none };
    line = 0;
    while (line < view.Lines.count(&overview.state)) : (line += 1) try std.testing.expect(!view.Lines.spins(&overview.state, line, overview.caps));
}

test "idle overview polls real Host reads without requesting unchanged frames" {
    const rig = try openOverview();
    defer rig.close();
    const overview = rig.overview;
    overview.caps = .{};
    Seen.now.working = 0;
    _ = try overview.event(.{ .tick = overview.realMs() });
    try std.testing.expect(try rig.settle() == null);
    var shown = try rig.shown(80, 24);
    shown.deinit();
    const revision = overview.state.presentation_revision;
    const lists = Seen.now.lists;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for (0..3) |_| {
        overview.state.next_list_ms = overview.realMs();
        while (true) {
            if (overview.worker.thread != null) try rig.answered();
            ctx.redraw = false;
            try overview.root.widget().handleEvent(&ctx, .tick);
            try std.testing.expectEqual(revision, overview.state.presentation_revision);
            try std.testing.expectEqual(overview.wantsFrame(), ctx.redraw);
            if (ctx.redraw) {
                var minute = try rig.shown(80, 24);
                minute.deinit();
            }
            if (overview.worker.thread == null and overview.job_count == 0) break;
        }
    }
    try std.testing.expectEqual(lists + 3, Seen.now.lists);
    _ = try overview.event(.{ .memory = .{ .rui = 38 * view.mib, .tools = null } });
    const memory_revision = overview.state.presentation_revision;
    _ = try overview.event(.{ .memory = .{ .rui = 38 * view.mib, .tools = null } });
    try std.testing.expectEqual(memory_revision, overview.state.presentation_revision);
    Seen.now.working = 1;
    overview.state.next_list_ms = overview.realMs();
    var changed = false;
    while (true) {
        if (overview.worker.thread != null) try rig.answered();
        ctx.redraw = false;
        try overview.root.widget().handleEvent(&ctx, .tick);
        changed = changed or ctx.redraw;
        if (overview.worker.thread == null and overview.job_count == 0) break;
    }
    try std.testing.expect(changed);
    try std.testing.expect(overview.state.presentation_revision != memory_revision);
}

test "overview state ages request one minute frame only while visible" {
    const rig = try openOverview();
    defer rig.close();
    const overview = rig.overview;
    Seen.now.working = 0;
    _ = try overview.event(.{ .tick = test_now_s * 1000 });
    try std.testing.expect(try rig.settle() == null);
    var shown = try rig.shown(80, 24);
    shown.deinit();
    const deadline = overview.app_redraw_at.?;
    try std.testing.expect(!overview.wantsFrameAt(deadline - 1));
    try std.testing.expect(overview.wantsFrameAt(deadline));
    overview.state.now_ms += 50_000;
    var minute = try rig.shown(80, 24);
    minute.deinit();
    try std.testing.expect(!overview.wantsFrameAt(deadline));
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSettings(&ctx);
    try std.testing.expect(!overview.wantsFrameAt(std.math.maxInt(u64)));
}

test "the overview asks for frames only while a spinning mark is on screen" {
    const rig = try openOverview();
    defer rig.close();
    rig.overview.caps = .{};
    Seen.now.listed = listed_references.len;
    Seen.now.working = 1;
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    const Frames = struct {
        fn after(from: *Rig, height: u16) !bool {
            var shown = try from.shown(80, height);
            defer shown.deinit();
            const deadline = from.overview.app_redraw_at orelse return false;
            if (deadline > from.overview.animationMs() + view.spin_interval_ms) return false;
            if (from.overview.wantsFrameAt(deadline - 1)) return error.TestUnexpectedResult;
            return from.overview.wantsFrameAt(deadline);
        }
    };
    try std.testing.expect(try Frames.after(rig, 24));
    _ = try rig.press("\x1b[F\x1b[A");
    try std.testing.expect(!try Frames.after(rig, 9));
    try std.testing.expect(try Frames.after(rig, 24));
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try rig.overview.root.openSettings(&ctx);
    try std.testing.expect(!try Frames.after(rig, 24));
}

fn recorded(sent: anytype, handle: []const u8) Reply {
    var reply: Reply = .{};
    reply.record(sent, handle) catch {};
    return reply;
}

test "a captured request is unconfirmed until the Host answers it" {
    const Sent = client.Stepped(client.MutationSendError, protocol_reply.MutationReply);
    var context: protocol_reply.MutationIdentity = .{ .kind = .configure };
    context.session.set("n3w5es") catch unreachable;
    const target: protocol_reply.MutationTarget = .configure;
    const accepted: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = .{ .result = .{ .accepted = .{ .configure = .{ .revision = 1, .created = true } } }, .replayed = false } } };
    var started: Reply = .{};
    try started.record(accepted, "h1");
    try std.testing.expectEqual(.accepted, started.outcome);
    try std.testing.expectEqualStrings("n3w5es", &started.session);
    try std.testing.expectEqualStrings("h1", started.handle.slice());
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    code.set("model_unsupported") catch unreachable;
    const rejected: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = .{ .result = .{ .rejected = code }, .replayed = false } } };
    try std.testing.expectEqualStrings("model_unsupported", recorded(rejected, "h1").created().failed);
    const unread: Sent = .{ .done = .{ .status = 200, .context = context, .target = target, .answer = error.InvalidResponse } };
    var lost: Reply = .{};
    try lost.record(unread, "h1");
    try std.testing.expectEqualStrings("h1", lost.created().unconfirmed);
    const unsent: Sent = .{ .failed = .{ .step = .connect, .err = error.FileNotFound } };
    try std.testing.expectEqualStrings("h1", recorded(unsent, "h1").created().unconfirmed);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const large = try std.testing.allocator.alloc(u8, 70000);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try environ.put("LARGE_VARIABLE", large);
    const too_large = Reply.environmentTooLarge(.{ .map = &environ }).created().failed;
    try std.testing.expect(std.mem.indexOf(u8, too_large, "nothing was sent") != null);
    try std.testing.expect(std.mem.endsWith(u8, too_large, "Largest variables: LARGE_VARIABLE."));
    const uploaded: Sent = .{ .failed = .{ .step = .upload, .err = error.Cancelled } };
    try std.testing.expectEqualStrings("h1", recorded(uploaded, "h1").created().unconfirmed);
    try std.testing.expectEqualStrings("h1", recorded(uploaded, "h1").stop().unconfirmed);
    try std.testing.expect(recorded(accepted, "h1").stop() == .stopped);
    const fenced: Sent = .{ .done = .{ .status = 500, .context = context, .target = target, .answer = error.CanonicalStoreFailure } };
    var unknown: Reply = .{};
    try std.testing.expectError(error.CanonicalStoreFailure, unknown.record(fenced, "h1"));
    try std.testing.expectEqualStrings("h1", unknown.created().unconfirmed);
}

test "a canonical Store failure ends the overview and names creation recovery" {
    var ops = fake_operations;
    ops.create = struct {
        fn create(_: *Self, _: client.Requests, _: configure_input.ConfigureInput, reply: *Reply) !void {
            reply.* = .unconfirmed("fenced-handle");
            return error.CanonicalStoreFailure;
        }
    }.create;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try view.writeDeparture(&rig.overview.state, null, &departure.writer);
    try std.testing.expect(std.mem.indexOf(u8, departure.written(), "rui request recover fenced-handle") != null);
}

fn readFailure(code: []const u8) protocol_reply.ReadFailure {
    var failure: protocol_reply.ReadFailure = .{ .status = 500, .diagnostic = .{ .type = .{}, .code = .{} } };
    failure.diagnostic.type.set("invocation_error") catch unreachable;
    failure.diagnostic.code.set(code) catch unreachable;
    return failure;
}

test "a canonical Store failure in a listing ends the overview" {
    var ops = fake_operations;
    ops.list = struct {
        fn list(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return readFailure("canonical_store_failure");
        }
    }.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
}

test "a refused first line answers its row, and a canonical Store failure ends the overview" {
    const Refuse = struct {
        var code: []const u8 = "";
        fn firstLine(_: *Self, _: client.Requests, _: []const u8, _: u64, _: []u8) !protocol_reply.ActivityPrefixReply {
            return .{ .failure = readFailure(code) };
        }
    };
    var ops = fake_operations;
    ops.first_line = Refuse.firstLine;
    var cancellation: client.Cancellation = .{};
    for ([_][]const u8{ "session_not_found", "canonical_store_failure" }) |code| {
        Refuse.code = code;
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
        if (std.mem.eql(u8, code, "canonical_store_failure")) {
            try std.testing.expectError(error.CanonicalStoreFailure, rig.settle());
        } else {
            try std.testing.expect(try rig.settle() == null);
            const row = rig.overview.state.find("k7m2qx".*).?;
            try std.testing.expect(rig.overview.state.lineOf(row) == null);
        }
    }
}

test "Ctrl-C ends the overview" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expectEqual(@as(?Ending, .overview), try rig.press("\x03"));
}

test "a stop whose reply was lost names its request on departure" {
    var ops = fake_operations;
    ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, reply: *Reply) !void {
            Seen.now.stops += 1;
            reply.* = .unconfirmed("stop-handle");
        }
    }.stop;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("! k7m2qx stop unsure; details on exit", rig.overview.state.notice.?.text());
    const guidance = "rui: Not sure k7m2qx stopped. Check with: rui request recover stop-handle\n";
    var departure: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer departure.deinit();
    try view.writeDeparture(&rig.overview.state, null, &departure.writer);
    try std.testing.expectEqualStrings(guidance, departure.written());
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    rig.overview.state.notice = null;
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("! k7m2qx stop unsure; details on exit", rig.overview.state.notice.?.text());
    const running = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer running.close();
    try std.testing.expect(try running.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try running.settle() == null);
    try std.testing.expect(try running.press("\x1b[H\x1b[B\x1b[B\x18\x18") == null);
    try running.overview.dispatch(.all);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(running.overview.job));
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(guidance, try finishedGuidance(running, &buffer));
}

fn finishedGuidance(rig: *Rig, buffer: []u8) ![]const u8 {
    const written = try finishedWith(rig, {}, null, buffer);
    const at = std.mem.indexOf(u8, written, "\nDetached. Host work continues.\nOverview: rui --store ") orelse return error.TestExpectedDetached;
    return written[0..at];
}

fn finishedWith(rig: *Rig, ended: anyerror!void, failure: ?anyerror, buffer: []u8) ![]const u8 {
    var pipe: [2]c_int = undefined;
    if (std.c.pipe(&pipe) != 0) return error.SystemResources;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (std.c.fcntl(pipe[0], std.c.F.SETFL, std.c.fcntl(pipe[0], std.c.F.GETFL) | nonblock) < 0) return error.SystemResources;
    defer for (pipe) |fd| {
        _ = std.c.close(fd);
    };
    const saved = std.c.dup(2);
    if (saved < 0 or std.c.dup2(pipe[1], 2) < 0) return error.TestUnexpectedResult;
    const finished = rig.overview.finishApp(ended);
    _ = std.c.dup2(saved, 2);
    _ = std.c.close(saved);
    if (failure) |expected| try std.testing.expectError(expected, finished) else if (try finished) |request| request.deinit(rig.overview.init.gpa);
    const count = std.c.read(pipe[0], buffer.ptr, buffer.len);
    return if (count > 0) buffer[0..@intCast(count)] else "";
}

test "while a conversation holds the terminal its stop goes first, the listing goes on, and a listing's failure stays the overview's" {
    const Lent = struct {
        fn answered(overview: *Self) !bool {
            return service(overview);
        }
    };
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    overview.opened = "k7m2qx".*;
    try overview.dispatch(.lent);
    try std.testing.expectEqual(Job.list, std.meta.activeTag(overview.job));
    _ = try conversed(overview, .working, .stop);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), overview, Lent.answered);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(overview.job));
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), overview, Lent.answered);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqual(Job.host, std.meta.activeTag(overview.job));
    try rig.lend();
    try std.testing.expect(Seen.now.hosts >= 1 and Seen.now.lists >= 1);
    try std.testing.expectEqual(@as(usize, 0), overview.job_count);

    var ops = fake_operations;
    ops.list = struct {
        fn list(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return readFailure("canonical_store_failure");
        }
    }.list;
    const failing = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer failing.close();
    try std.testing.expect(try failing.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try failing.overview.dispatch(.all);
    try std.testing.expectEqual(Job.list, std.meta.activeTag(failing.overview.job));
    failing.overview.opened = "k7m2qx".*;
    try std.testing.expectError(error.CanonicalStoreFailure, test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), failing.overview, Lent.answered));
    var buffer: [1024]u8 = undefined;
    failing.overview.app_session = .{ .session = "k7m2qx".*, .frontend = null, .files = null, .ended = .returned };
    try std.testing.expectEqualStrings("", try finishedWith(failing, error.CanonicalStoreFailure, error.CanonicalStoreFailure, &buffer));
}

test "a terminal that answers the program status probe gets each Session's record, and nothing else" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var finished = false;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (finished) page.rows[0].work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 };
            return null;
        }
    };
    Listing.finished = false;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22cx\x1b[O") == null);
    try std.testing.expect(try rig.press("\x7f") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var written = rig.signalled();
    const working = "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    try std.testing.expect(std.mem.indexOf(u8, written, working) != null);
    Listing.finished = true;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    written = rig.signalled();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .read_version = .{ .instance = @splat(1), .generation = Seen.now.lists + 1 }, .work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 2, .operation = 2 } }, false);
    try std.testing.expectEqualStrings("", rig.signalled());
    try std.testing.expect(try overview.event(.{ .open = "k7m2qx".* }) != null);
    written = rig.signalled();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=idle:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    _ = try preferences.update(home, .{ .notifications = false }, &preferences.Readinesses.initFill(.missing));
    Listing.finished = false;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    written = rig.signalled();
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b]7501;state=clear:id=rui\x1b\\"));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    written = rig.signalled();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;") == null);
    _ = try preferences.update(home, .{ .notifications = true }, &preferences.Readinesses.initFill(.missing));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 240_000 }) == null);
    written = rig.signalled();
    try std.testing.expect(std.mem.startsWith(u8, written, working));
}

test "turning notifications off clears records already sent, with no Session changing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;state=working:id=rui/k7m2qx:") != null);
    _ = try preferences.update(home, .{ .notifications = false }, &preferences.Readinesses.initFill(.missing));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=clear:id=rui\x1b\\"));
}

test "a Session's record takes its new name when only its Label changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var label: ?[]const u8 = null;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (label) |text| {
                page.rows[0].label = .{};
                page.rows[0].label.?.set(text) catch unreachable;
            }
            return null;
        }
    };
    Listing.label = null;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    const by_line = "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), by_line) != null);
    Listing.label = "Lane four";
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=TGFuZSBmb3Vy\x1b\\"));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;") == null);
    Listing.label = null;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), by_line));
}

test "each later finish, and each later wait, is a record again though no listing read the Session at work between" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var read: ?protocol.SessionWork = null;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (read) |listed| page.rows[0].work = listed;
            return null;
        }
    };
    Listing.read = null;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    const done = "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    const blocked = "\x1b]7501;state=blocked:id=rui/k7m2qx:kind=permission:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\";
    const finished = struct {
        fn of(id: u64) protocol.SessionWork {
            return .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = id, .operation = id };
        }
    }.of;
    const waiting = struct {
        fn of(id: u64, action: u64) protocol.SessionWork {
            return .{ .state = .{ .approval = .{ .since = test_now_s } }, .turn = id, .operation = id, .first_action = action };
        }
    }.of;
    for ([_]struct { work: ?protocol.SessionWork, record: ?[]const u8 }{
        .{ .work = null, .record = "\x1b]7501;state=working:id=rui/k7m2qx:" },
        .{ .work = finished(1), .record = done },
        .{ .work = finished(2), .record = done },
        .{ .work = finished(2), .record = null },
        .{ .work = waiting(3, 7), .record = blocked },
        .{ .work = waiting(3, 8), .record = blocked },
        .{ .work = waiting(3, 8), .record = null },
        .{ .work = waiting(4, 2), .record = blocked },
    }, 0..) |listing, at| {
        Listing.read = listing.work;
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + at * 60_000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        const written = rig.signalled();
        if (listing.record) |record|
            try std.testing.expect(std.mem.startsWith(u8, written, record))
        else
            try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;") == null);
    }
}

test "a later Turn's finish the conversation read first is still a record when the next listing shows it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var finished_turn: u64 = 1;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            page.rows[0].work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = finished_turn, .operation = finished_turn };
            return null;
        }
    };
    Listing.finished_turn = 1;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;") == null);
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .read_version = .{ .instance = @splat(1), .generation = Seen.now.lists + 1 }, .work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 2, .operation = 2 } }, false);
    try std.testing.expectEqualStrings("", rig.signalled());
    Listing.finished_turn = 2;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
}

test "a finish the conversation opened on is no done record when a listing reads it later, and a later Turn's is" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    const Listing = struct {
        var finished_turn: ?u64 = null;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            if (finished_turn) |finished| page.rows[0].work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = finished, .operation = finished };
            return null;
        }
    };
    Listing.finished_turn = null;
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b]7501;?\x1b\\\x1b[?62;22c\x1b[O") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;state=working:id=rui/k7m2qx:") != null);
    Listing.finished_turn = 1;
    try std.testing.expect(try overview.event(.{ .open = "k7m2qx".* }) != null);
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .read_version = .{ .instance = @splat(1), .generation = Seen.now.lists + 1 }, .work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 } }, true);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 60_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=idle:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 120_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.indexOf(u8, rig.signalled(), "\x1b]7501;") == null);
    Listing.finished_turn = 2;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 180_000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(std.mem.startsWith(u8, rig.signalled(), "\x1b]7501;state=done:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\"));
}

test "records go out though the terminal never answered the probe, and nothing else does, inside tmux or screen too" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try rig.environ.put("TMUX", "/tmp/tmux-1000/default,1,0");
    try rig.environ.put("STY", "1.pts-0.host");
    const overview = rig.overview;
    rig.overview.options.home = home;
    try std.testing.expect(try rig.press("\x1b[O") == null);
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    const written = rig.signalled();
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b]7501;state=working:id=rui/k7m2qx:app=rui:msg=Rml4IHRoZSBmbGFreSB0ZXN0\x1b\\") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, written, 0x07) == null);
    overview.opened = "k7m2qx".*;
    try observed(overview, .{ .read_version = .{ .instance = @splat(1), .generation = Seen.now.lists + 1 }, .work = .{ .state = .{ .finished = .{ .since = test_now_s } }, .turn = 1, .operation = 1 } }, false);
    try std.testing.expectEqualStrings("", rig.signalled());
}

test "a stop answered under a conversation says so there, and goes before a listing" {
    var ops = fake_operations;
    ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, reply: *Reply) !void {
            Seen.now.stops += 1;
            reply.* = .unconfirmed("stop-handle");
        }
    }.stop;
    const unsure = "! k7m2qx stop unsure; details on exit";
    var cancellation: client.Cancellation = .{};
    const finished = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer finished.close();
    try std.testing.expect(try finished.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try finished.settle() == null);
    try std.testing.expect(try finished.press("\x1b[H\x1b[B\x1b[B\x18\x18") == null);
    try finished.overview.dispatch(.all);
    try finished.answered();
    try std.testing.expect(try finished.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    finished.overview.opened = "k7m2qx".*;
    try finished.lend();
    try std.testing.expectEqual(@as(usize, 2), Seen.now.lists);
    try std.testing.expectEqualStrings(unsure, conversationLine(finished.overview, .working).notice.?);

    const queued = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer queued.close();
    try std.testing.expect(try queued.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try queued.settle() == null);
    try std.testing.expect(try queued.overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try queued.press("\x1b[H\x1b[B\x1b[B\x18\x18") == null);
    queued.overview.opened = "k7m2qx".*;
    _ = try service(queued.overview);
    try std.testing.expectEqual(Job.stop, std.meta.activeTag(queued.overview.job));
    try queued.lend();
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.lists);
    try std.testing.expectEqualStrings(unsure, conversationLine(queued.overview, .working).notice.?);
}

test "a failed terminal restore still prints the departure guidance" {
    var ops = fake_operations;
    ops.create = struct {
        fn create(_: *Self, _: client.Requests, _: configure_input.ConfigureInput, reply: *Reply) !void {
            reply.* = .unconfirmed("lost-handle");
        }
    }.create;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expect(try rig.settle() == null);
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: Not sure the new Session was created. Check with: rui request recover lost-handle\n", try finishedGuidance(rig, &buffer));
}

const HostRecovery = struct {
    const Availability = enum { ready, paused, stopping, stopped, incompatible, unreadable };
    var availability: Availability = .ready;
    var last_stop: platform.StoreLease.LastStop = .asked;
    var starts: usize = 0;
    var fail_start: bool = false;
    var start_warning: ?HostLaunch.Warning = null;
    var forced_start: ?HostLaunch = null;
    var after_start: ?Availability = null;
    var worker_id: ?std.Thread.Id = null;
    var dir: std.Io.Dir = undefined;
    var files: u8 = 0;

    fn operations() Operations {
        availability = .ready;
        last_stop = .asked;
        starts = 0;
        fail_start = false;
        start_warning = null;
        forced_start = null;
        after_start = null;
        worker_id = null;
        files = 0;
        var ops = fake_operations;
        ops.host = host;
        ops.start_host = start;
        ops.open = openSession;
        return ops;
    }
    fn host(_: *Self) HostRead {
        return .{ .observation = switch (availability) {
            .ready, .paused => .{ .ready = .{ .facts = .{ .instance = @splat(1), .started_at = test_now_s, .slots = 4, .slots_in_use = 0 }, .paused = availability == .paused } },
            .stopped => .{ .stopped = last_stop },
            .stopping => .unavailable,
            .incompatible => .incompatible,
            .unreadable => .unreadable,
        } };
    }
    fn start(overview: *Self) HostLaunch {
        std.testing.expectEqualStrings("/store", overview.options.store) catch @panic("wrong launch Store");
        worker_id = std.Thread.getCurrentId();
        starts += 1;
        if (forced_start) |result| {
            if (after_start) |after| availability = after;
            return result;
        }
        if (fail_start) return .{ .failed = .{ .kind = .child_refused, .err = error.HostStartupFailed } };
        availability = .ready;
        return .{ .ready = start_warning };
    }
    fn scratch(init: std.process.Init) !std.Io.File {
        files += 1;
        return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
    }
    fn lost(_: *anyopaque, task: *ClientTask) !void {
        task.result.failure_origin = .host_transport;
        return error.ConnectionRefused;
    }
    fn completed(frontend: *SessionFrontend) !bool {
        return frontend.reader.completed();
    }
};

test "Host line appears once in overview and chat at wide and narrow widths, never from list failure" {
    const UnavailableList = struct {
        fn read(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return error.ConnectionRefused;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (std.enums.values(HostRecovery.Availability)) |availability| for ([_]bool{ false, true }) |open| {
        errdefer std.debug.print("availability={s}, chat={}\n", .{ @tagName(availability), open });
        const ops = HostRecovery.operations();
        HostRecovery.dir = tmp.dir;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        rig.overview.state.launch = .done;
        const overview = rig.overview;
        overview.hooks.scratch = HostRecovery.scratch;
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        defer if (overview.app_session) |left| {
            left.frontend.?.stop();
            overview.disposeSession(left);
            overview.app_session = null;
        };
        if (open) try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
        // A failed listing fades the held rows but says nothing about the
        // Host. Discovery remains the shell Host line's sole observation.
        overview.ops.list = UnavailableList.read;
        HostRecovery.availability = availability;
        overview.state.next_list_ms = 0;
        try std.testing.expect(try overview.event(.{ .tick = (test_now_s + 1) * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(overview.state.list_stale);
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
        for ([_]u16{ 140, 46 }) |width| {
            var shown = try rig.shown(width, 30);
            defer shown.deinit();
            const text = try shown.text();
            const expected: ?[]const u8 = switch (availability) {
                .ready => null,
                .paused, .stopping => "■ Host paused",
                .stopped => "■ Host stopped ·",
                .incompatible => "■ Host is a different Rui version",
                .unreadable => "■ Host unreachable",
            };
            try std.testing.expectEqual(@as(usize, @intFromBool(expected != null)), std.mem.count(u8, text, "Host "));
            if (expected) |line| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, line));
            try std.testing.expectEqual(availability == .stopped, std.mem.indexOf(u8, text, if (open) "· r start" else "· start") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "rui host") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, " ago. Run ") == null);
        }
    };
}

test "Host line and Settings tail show together without overlap at wide and narrow widths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ops = HostRecovery.operations();
    HostRecovery.dir = tmp.dir;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.hooks.scratch = HostRecovery.scratch;
    HostRecovery.availability = .stopped;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    for ([_]u16{ 46, 140 }) |width| for ([_]u16{ 9, 12, 30 }) |height| {
        errdefer std.debug.print("width={d}, height={d}\n", .{ width, height });
        var shown = try rig.shown(width, height);
        defer shown.deinit();
        const at = view.layout(&overview.state);
        const text = try shown.text();
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Host stopped ·"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "     Settings"));
        try std.testing.expectEqual(at.list.end, at.settings.start);
        try std.testing.expectEqual(@as(u16, 3), at.settings.len());
        try std.testing.expectEqual(at.settings.end, at.host.start);
        try std.testing.expectEqual(@as(u16, 1), at.host.len());
        try std.testing.expectEqual(at.host.end, at.input);
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.settings.start), "─"));
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.settings.start + 1), "     Settings"));
        try std.testing.expectEqualStrings(@import("transport_options").version, std.mem.trim(u8, try shown.line(at.settings.start + 2), " "));
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(at.host.start), "■ Host stopped ·"));
        try std.testing.expect(std.mem.indexOf(u8, try shown.line(at.input), "enter open") == null);
        for (at.list.start..at.list.end) |row| {
            const line = try shown.line(@intCast(row));
            try std.testing.expect(std.mem.indexOf(u8, line, "Host") == null);
            try std.testing.expect(std.mem.indexOf(u8, line, "Settings") == null);
        }
    };
    HostRecovery.availability = .ready;
    overview.host_observation = .unread;
    var shown = try rig.shown(46, 12);
    defer shown.deinit();
    const at = view.layout(&overview.state);
    try std.testing.expectEqual(@as(u16, 0), at.host.len());
    try std.testing.expectEqual(at.settings.end, at.input);
}

test "Host recovery keeps the open widget drafts and scroll and starts only on an empty draft r" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ops = HostRecovery.operations();
    HostRecovery.dir = tmp.dir;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.hooks.scratch = HostRecovery.scratch;
    _ = try overview.event(.{ .tick = test_now_s * 1000 });
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("list draft") == null);
    try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
    const frontend = overview.app_session.?.frontend.?;
    defer {
        frontend.stop();
        frontend.reader.join() catch {};
        overview.disposeSession(overview.app_session.?);
        overview.app_session = null;
    }
    const child = overview.root.session.?;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    frontend.reading.opening = false;
    frontend.poll_at = std.math.maxInt(i96);
    try app_events.send(&ctx, "chat draft", overview.root.widget(), child);
    rig.screen.anchor.anchor = .{ .at = .{ .key = .{ .position = 7 }, .line = 1 } };
    const anchor = rig.screen.anchor;
    try frontend.reader.start(std.testing.io, frontend, HostRecovery.lost);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), frontend, HostRecovery.completed);
    HostRecovery.availability = .stopped;
    try child.handleEvent(&ctx, .tick);
    try rig.lend();
    try std.testing.expect(!ctx.quit);
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    for ([_]u16{ 140, 46 }) |width| {
        var shown = try rig.shown(width, 26);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "■ Host stopped ·") != null);
    }
    try std.testing.expect(overview.root.session.?.eql(child));
    try std.testing.expectEqualStrings("chat draft", frontend.input.composition().bytes);
    try std.testing.expectEqualDeep(anchor, rig.screen.anchor);
    try app_events.send(&ctx, "r", overview.root.widget(), child);
    try std.testing.expectEqualStrings("chat draftr", frontend.input.composition().bytes);
    try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    _ = frontend.input.replace(.{ .start = 0, .end = frontend.input.composition().bytes.len, .text = "" });
    try app_events.send(&ctx, "r", overview.root.widget(), child);
    try std.testing.expectEqual(HostState.starting, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    var starting = try rig.shown(46, 26);
    defer starting.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try starting.text(), "Host starting") != null);
    try rig.lend();
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
    try std.testing.expect(HostRecovery.worker_id.? != std.Thread.getCurrentId());
    try std.testing.expect(hostNotice(overview) == null);
    try std.testing.expect(overview.root.session.?.eql(child));
    try std.testing.expectEqualDeep(anchor, rig.screen.anchor);
    try child.handleEvent(&ctx, .tick);
    try std.testing.expect(frontend.reader.thread != null);
    try std.testing.expect(!ctx.quit);
}

test "Host recovery failed start waits for a retry click and the line also accepts a click" {
    const ops = HostRecovery.operations();
    HostRecovery.availability = .stopped;
    HostRecovery.fail_start = true;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    _ = try overview.event(.{ .tick = test_now_s * 1000 });
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.hostStart() == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    _ = try overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms });
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    var shown = try rig.shown(46, 26);
    defer shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "× Host stopped · refused to start · retry") != null);
    try std.testing.expect(try rig.hostStart() == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 2), HostRecovery.starts);
    HostRecovery.fail_start = false;
    var row: u16 = 0;
    while (row < shown.screen.height) : (row += 1) {
        if (std.mem.indexOf(u8, try shown.line(row), "Host stopped") != null) break;
    }
    try std.testing.expect(row < shown.screen.height);
    try std.testing.expect(try rig.click(4, row, 46, 26) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 3), HostRecovery.starts);
    try std.testing.expect(hostNotice(overview) == null);
}

test "Host recovery paused shutting down and upgrading offer no start gesture" {
    for ([_]HostRecovery.Availability{ .paused, .stopping }) |availability| {
        const ops = HostRecovery.operations();
        HostRecovery.availability = availability;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(HostState.paused, overview.hostState());
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try std.testing.expect(!try requestHostStart(overview, &ctx));
        try std.testing.expect(try rig.hostStart() == null);
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
        var shown = try rig.shown(140, 26);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "■ Host paused") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "· start") == null);
        HostRecovery.availability = .ready;
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(hostNotice(overview) == null);
        overview.host_observation = .{ .stopped = .asked };
        overview.state.upgrade.after = .blocked;
        try std.testing.expectEqual(HostState.stopped, overview.hostState());
        try std.testing.expect(!try requestHostStart(overview, &ctx));
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    }
}

test "Host recovery availability is independent of admission pause for the whole Session service" {
    const Inspection = struct {
        fn requests(_: std.process.Init, _: client.ReadContext, _: []const u8, _: []const u8, out: *std.Io.Writer, saved: *session_reads.SavedRequests) !void {
            saved.* = .{};
            try out.writeAll("No requests.\n");
        }
    };
    for ([_]HostRecovery.Availability{ .ready, .paused, .stopping, .stopped }) |availability| {
        errdefer std.debug.print("availability={s}\n", .{@tagName(availability)});
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const ops = HostRecovery.operations();
        HostRecovery.dir = tmp.dir;
        var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory_length = try tmp.dir.realPath(std.testing.io, &directory_buffer);
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = directory_buffer[0..directory_length] }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = HostRecovery.scratch;
        overview.hooks.requests = Inspection.requests;
        try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
        const frontend = overview.app_session.?.frontend.?;
        defer {
            frontend.stop();
            frontend.reader.join() catch {};
            _ = frontend.submission.join();
            overview.disposeSession(overview.app_session.?);
            overview.app_session = null;
        }
        frontend.reading.opening = false;
        frontend.poll_at = std.math.maxInt(i96);
        frontend.live.work = .{ .state = .{ .bash = .{ .since = 1, .call = 0, .description = null, .running = 1, .approvals = 1 } }, .turn = 1, .operation = 2, .first_action = 0xa };
        frontend.live.queued = .{ .count = 1, .oldest_position = 30, .newest_admission = 9, .newest_position = 30 };
        try frontend.files.action.writePositionalAll(std.testing.io, "pending permission\n", 0);
        frontend.reading.prepared_action = 0xa;
        overview.queue(.host);
        try rig.lend();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        const child = overview.root.session.?;
        try child.handleEvent(&ctx, .tick);
        try std.testing.expectEqual(@as(?u64, 0xa), frontend.app_consent.request);
        HostRecovery.availability = availability;
        overview.queue(.host);
        try rig.lend();
        const reachable = availability == .ready or availability == .paused;
        try std.testing.expectEqual(!reachable, hostHeld(overview));
        try child.handleEvent(&ctx, .tick);
        try std.testing.expectEqual(if (reachable) @as(?u64, 0xa) else null, frontend.app_consent.request);
        try std.testing.expectEqual(reachable, frontend.app_input.permission != null);
        try std.testing.expectEqual(@as(u64, 1), frontend.live.queued.count);
        try std.testing.expectEqual(@as(u64, 1), frontend.live.work.state.bash.running);
        frontend.poll_at = 0;
        try child.handleEvent(&ctx, .tick);
        try std.testing.expectEqual(reachable, frontend.reader.thread != null);
        frontend.reader.cancel();
        frontend.reader.join() catch {};
        frontend.input.queueCommand("/requests");
        frontend.poll_at = std.math.maxInt(i96);
        try child.handleEvent(&ctx, .tick);
        try std.testing.expectEqual(reachable, frontend.inspection.command_running);
        try std.testing.expectEqual(!reachable, frontend.input.queuedCommand() != null);
        frontend.reader.cancel();
        frontend.reader.join() catch {};
        frontend.inspection.command_running = false;
        _ = frontend.input.takeCommand();
        frontend.app_consent.withdraw();
        frontend.app_input.permission = null;
        rig.screen.withdrawAction();
        frontend.live.work.first_action = null;
        try app_events.send(&ctx, "another Message\r", overview.root.widget(), child);
        try std.testing.expectEqual(reachable, frontend.submission.intent != null);
        try std.testing.expectEqualStrings(if (reachable) "" else "another Message", frontend.input.composition().bytes);
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    }
}

test "Host recovery waits across upgrade swap and reobservation before offering a start" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, HostRecovery.operations(), &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try std.testing.expect(overview.state.upgrade.start());
    HostRecovery.availability = .stopped;
    try std.testing.expect(try overview.takeHostRead(overview.ops.host(overview)) == null);
    try std.testing.expect(hostHeld(overview));
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    overview.state.upgrade.run = null;
    overview.state.upgrade.after = .reobserving;
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    overview.state.listing = true;
    overview.state.listing_archive = overview.state.archive;
    try std.testing.expect(try overview.event(.{ .list = .{ .page = .{ .rows = &.{}, .answer = .{ .delta = .full, .since = .{ .instance = @splat(1), .generation = 1 } } } } }) == null);
    try std.testing.expect(!overview.state.holdsHost());
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    HostRecovery.availability = .stopping;
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(hostHeld(overview));
    try std.testing.expectEqual(std.meta.Tag(HostObservation).unavailable, std.meta.activeTag(overview.host_observation));
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    HostRecovery.availability = .ready;
    try std.testing.expect(try overview.takeHostRead(overview.ops.host(overview)) == null);
    try std.testing.expect(!hostHeld(overview));
    try std.testing.expect(hostNotice(overview) == null);
    HostRecovery.availability = .stopped;
    try std.testing.expect(try overview.takeHostRead(overview.ops.host(overview)) == null);
    try std.testing.expectEqual(HostState.stopped, overview.hostState());
    try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
}

test "Host recovery derives launch progress from job custody without copying reachability" {
    const Busy = struct {
        fn run(_: *anyopaque, task: *ClientTask) !void {
            while (!task.cancellation.stopped.load(.acquire)) std.Thread.yield() catch {};
            return error.Cancelled;
        }
    };
    const ops = HostRecovery.operations();
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    HostRecovery.availability = .stopped;
    try std.testing.expect(try overview.takeHostRead(overview.ops.host(overview)) == null);
    try overview.worker.start(std.testing.io, overview, Busy.run);
    defer {
        overview.worker.cancel();
        overview.worker.join() catch {};
    }
    try std.testing.expect(try requestHostStart(overview, &ctx));
    try std.testing.expect(overview.hostStarting());
    try std.testing.expectEqual(HostState.starting, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
    for ([_]HostRecovery.Availability{ .paused, .ready }) |availability| {
        HostRecovery.availability = availability;
        const read = overview.ops.host(overview);
        try std.testing.expect(try overview.takeHostRead(read) == null);
        try std.testing.expectEqual(read.observation.facts(), overview.state.host);
        try std.testing.expect(!hostHeld(overview));
        try std.testing.expect(overview.hostStarting());
        try std.testing.expectEqual(HostState.starting, overview.hostState());
        try std.testing.expect(!try requestHostStart(overview, &ctx));
    }
    overview.worker.cancel();
    overview.worker.join() catch {};
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
    try std.testing.expect(!overview.hostStarting());
    try std.testing.expectEqual(HostState.ready, overview.hostState());
    hostLost(overview);
    try std.testing.expect(hostHeld(overview));
    try std.testing.expectEqual(HostState.paused, overview.hostState());
    try std.testing.expect(!try requestHostStart(overview, &ctx));
    try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
}

test "Host recovery renders the launch result cause without confusing failure and reachability" {
    const Case = struct { launch: HostLaunch, words: []const u8, retry: bool = false };
    const cases = [_]Case{
        .{ .launch = .{ .ready = null }, .words = "" },
        .{ .launch = .{ .ready = .invalid_openai_base_url }, .words = "OpenAI URL invalid" },
        .{ .launch = .{ .failed = .{ .kind = .os_launch, .err = error.HostLaunchFailed } }, .words = "could not start", .retry = true },
        .{ .launch = .{ .failed = .{ .kind = .child_refused, .err = error.HostStartupFailed } }, .words = "refused to start", .retry = true },
        .{ .launch = .{ .failed = .{ .kind = .readiness_timeout, .err = error.HostReadinessUnconfirmed } }, .words = "start timed out", .retry = true },
        .{ .launch = .{ .failed = .{ .kind = .store_identity, .err = error.StoreIdentityMismatch } }, .words = "not the same Store" },
        .{ .launch = .{ .failed = .{ .kind = .incompatible, .err = error.IncompatibleHost } }, .words = "different Rui version" },
        .{ .launch = .{ .failed = .{ .kind = .provider_unserved, .err = error.HostModelUnavailable } }, .words = "does not serve this provider" },
        .{ .launch = .{ .failed = .{ .kind = .store_format, .err = error.HostStartupFailed } }, .words = "needs a compatible Rui" },
    };
    for (cases) |case| for ([_]HostRecovery.Availability{ .ready, .stopping, .stopped }) |after| {
        errdefer std.debug.print("after={s} words={s}\n", .{ @tagName(after), case.words });
        var cancellation: client.Cancellation = .{};
        const ops = HostRecovery.operations();
        HostRecovery.availability = .stopped;
        HostRecovery.forced_start = case.launch;
        HostRecovery.after_start = after;
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(try rig.hostStart() == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        try std.testing.expectEqual(after != .ready, hostHeld(overview));
        const failure = case.launch == .failed;
        if (after == .ready) {
            var first = try rig.shown(140, 26);
            defer first.deinit();
            const text = try first.text();
            try std.testing.expectEqual(!failure and case.words.len != 0, std.mem.indexOf(u8, text, "✓ Host ready · ") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "× Host") == null);
        }
        const detail = case.words.len != 0 and after != .ready;
        const next: ?HostLaunch.Next = if (after != .stopped) null else if (failure) (if (case.retry) .retry else null) else .start;
        try std.testing.expectEqual(next, overview.hostNext());
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        for ([_]u16{ 140, 46 }) |width| {
            var shown = try rig.shown(width, 26);
            defer shown.deinit();
            const text = try shown.text();
            if (case.words.len != 0) try std.testing.expectEqual(detail, std.mem.indexOf(u8, text, case.words) != null);
            try std.testing.expectEqual(next == .retry, std.mem.indexOf(u8, text, "· retry") != null);
            try std.testing.expectEqual(next == .start, std.mem.indexOf(u8, text, "· start\n") != null);
            if (after != .ready) try std.testing.expect(std.mem.indexOf(u8, text, if (after == .stopped) "Host stopped" else "Host paused") != null);
            if (failure and after != .ready) try std.testing.expect(std.mem.indexOf(u8, text, "× Host") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "rui host") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "HostStartupFailed") == null);
        }
        overview.state.upgrade.after = .blocked;
        try std.testing.expect(overview.hostNext() == null);
        var held = try rig.shown(140, 26);
        defer held.deinit();
        const text = try held.text();
        try std.testing.expectEqual(after == .stopping, std.mem.indexOf(u8, text, "■ Host paused") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "· retry") == null);
    };
}

fn readHostOnce(rig: *Rig) !void {
    const overview = rig.overview;
    std.debug.assert(overview.job_count == 0 and overview.worker.thread == null);
    overview.queue(.host);
    try overview.dispatch(.all);
    try rig.answered();
    try std.testing.expect(try rig.next(try overview.complete()) == null);
}

test "a Host that stopped unasked starts again once by itself; any other stop waits for a click" {
    const Case = struct { availability: HostRecovery.Availability = .stopped, last_stop: platform.StoreLease.LastStop, upgrading: bool = false, starts: usize };
    const cases = [_]Case{
        .{ .last_stop = .unasked, .starts = 1 },
        .{ .last_stop = .asked, .starts = 0 },
        .{ .last_stop = .unknown, .starts = 0 },
        .{ .last_stop = .unasked, .upgrading = true, .starts = 0 },
        .{ .last_stop = .asked, .upgrading = true, .starts = 0 },
        .{ .last_stop = .unknown, .upgrading = true, .starts = 0 },
        .{ .availability = .stopping, .last_stop = .unasked, .starts = 0 },
        .{ .availability = .incompatible, .last_stop = .unasked, .starts = 0 },
        .{ .availability = .unreadable, .last_stop = .unasked, .starts = 0 },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {any}\n", .{case});
        const ops = HostRecovery.operations();
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expect(hostNotice(overview) == null);
        if (case.upgrading) overview.state.upgrade.after = .blocked;
        HostRecovery.availability = case.availability;
        HostRecovery.last_stop = case.last_stop;
        try readHostOnce(rig);
        if (case.starts == 1) {
            try std.testing.expectEqual(HostState.starting, overview.hostState());
            var starting = try rig.shown(46, 26);
            defer starting.deinit();
            const text = try starting.text();
            try std.testing.expect(std.mem.indexOf(u8, text, "Host starting") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "r start") == null);
        } else {
            const held: HostState = switch (case.availability) {
                .stopped => .stopped,
                .stopping => .paused,
                .incompatible => .incompatible,
                .unreadable => .unreadable,
                .ready, .paused => unreachable,
            };
            try std.testing.expectEqual(held, overview.hostState());
        }
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(case.starts, HostRecovery.starts);
        if (case.starts == 1) {
            try std.testing.expect(HostRecovery.worker_id.? != std.Thread.getCurrentId());
            try std.testing.expect(hostNotice(overview) == null);
        } else if (!case.upgrading and case.availability == .stopped) {
            var shown = try rig.shown(46, 26);
            defer shown.deinit();
            try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "■ Host stopped ·") != null);
        }
    }
}

test "the automatic start is spent once per run: a second crash and a failed start leave retry" {
    {
        const ops = HostRecovery.operations();
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try rig.settle() == null);
        HostRecovery.last_stop = .unasked;
        HostRecovery.availability = .stopped;
        try readHostOnce(rig);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        try std.testing.expect(hostNotice(overview) == null);
        HostRecovery.availability = .stopped;
        try readHostOnce(rig);
        try std.testing.expectEqual(HostState.stopped, overview.hostState());
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        var shown = try rig.shown(46, 26);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "■ Host stopped ·") != null);
        try std.testing.expect(try rig.hostStart() == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 2), HostRecovery.starts);
        try std.testing.expect(hostNotice(overview) == null);
    }
    {
        const ops = HostRecovery.operations();
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try rig.settle() == null);
        HostRecovery.last_stop = .unasked;
        HostRecovery.availability = .stopped;
        HostRecovery.fail_start = true;
        try readHostOnce(rig);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        try std.testing.expectEqual(HostState.stopped, overview.hostState());
        for (0..2) |_| {
            try readHostOnce(rig);
            try std.testing.expect(try rig.settle() == null);
        }
        try std.testing.expectEqual(@as(usize, 1), HostRecovery.starts);
        var shown = try rig.shown(46, 26);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expectEqual(HostLaunch.Failure.Kind.child_refused, overview.host_launch.?.failed.kind);
        try std.testing.expect(std.mem.indexOf(u8, text, "× Host stopped · ") != null and std.mem.indexOf(u8, text, " · retry") != null);
    }
}

test "Host recovery retains a worker failure in the same typed launch result" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, HostRecovery.operations(), &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.host_observation = .{ .stopped = .asked };
    overview.job = .start_host;
    try std.testing.expect(try overview.deliver(error.SystemResources) == null);
    try std.testing.expectEqual(HostLaunch.Failure.Kind.worker, overview.host_launch.?.failed.kind);
    try std.testing.expectEqual(error.SystemResources, overview.host_launch.?.failed.err);
    var shown = try rig.shown(46, 26);
    defer shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Host stopped · could not start · retry") != null);
}

test "before the first Host read the screen says nothing about the Host and holds no Session" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, HostRecovery.operations(), &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.host_observation = .unread;
    try std.testing.expectEqual(HostState.ready, overview.hostState());
    try std.testing.expect(hostNotice(overview) == null);
    try std.testing.expect(!hostHeld(overview));
    try std.testing.expect(overview.hostNext() == null);
    var shown = try rig.shown(46, 26);
    defer shown.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Host") == null);
    hostLost(overview);
    try std.testing.expect(hostHeld(overview));
    try std.testing.expectEqual(HostState.paused, overview.hostState());
}

test "a conversation that fails to open still names unconfirmed creation on departure" {
    var ops = fake_operations;
    ops.create = struct {
        fn create(_: *Self, _: client.Requests, _: configure_input.ConfigureInput, reply: *Reply) !void {
            reply.* = .unconfirmed("lost-handle");
        }
    }.create;
    ops.open = openSession;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    rig.overview.hooks.scratch = struct {
        fn scratch(_: std.process.Init) !std.Io.File {
            return error.AccessDenied;
        }
    }.scratch;
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[H\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(?Ending, .overview), try rig.next(try rig.overview.event(.{ .open = "k7m2qx".* })));
    try std.testing.expect(rig.overview.app_session.?.frontend == null);
    rig.overview.stopApp();
    var buffer: [1024]u8 = undefined;
    const written = try finishedWith(rig, {}, error.AccessDenied, &buffer);
    try std.testing.expectEqualStrings("rui: Not sure the new Session was created. Check with: rui request recover lost-handle\n" ++
        "\nResume: rui session resume --store $'/store' k7m2qx\n", written);
}

test "a listing failure under a conversation ends the overview once the terminal is restored" {
    var ops = fake_operations;
    ops.list = struct {
        fn list(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return readFailure("canonical_store_failure");
        }
    }.list;
    ops.open = openSession;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = root[0..try tmp.dir.realPath(std.testing.io, &root)];
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    Scratch.dir = tmp.dir;
    Scratch.count = 0;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = store, .workspace = "/work", .home = "/home", .directory = store }, ops, &cancellation);
    defer rig.close();
    rig.overview.hooks.scratch = Scratch.scratch;
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try overview.dispatch(.all);
    try std.testing.expectEqual(Job.list, std.meta.activeTag(overview.job));
    try rig.answered();
    // The Session opens over the overview; the overview's next tick under
    // it collects the failure, which ends App.
    try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
    try std.testing.expect(overview.app_session.?.frontend != null);
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try std.testing.expectError(error.CanonicalStoreFailure, appEvent(overview, &ctx, .tick));
    var buffer: [4096]u8 = undefined;
    const written = try finishedWith(rig, error.CanonicalStoreFailure, error.CanonicalStoreFailure, &buffer);
    try std.testing.expectEqualStrings("", written);
}

test "App sets the terminal title once per change, with how many Sessions need the person" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = "codex", .model = "gpt-5.5" }, fake_operations, &cancellation);
    defer rig.close();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try appEvent(rig.overview, &ctx, .tick);
    try appEvent(rig.overview, &ctx, .tick);
    rig.overview.state.summary.counts.needs_you = 2;
    try appEvent(rig.overview, &ctx, .tick);
    var titles: std.ArrayList([]const u8) = .empty;
    for (ctx.cmds.items) |command| if (command == .set_title) try titles.append(arena.allocator(), command.set_title);
    try std.testing.expectEqual(@as(usize, 2), titles.items.len);
    try std.testing.expectEqualStrings("rui", titles.items[0]);
    try std.testing.expectEqualStrings("rui · 2 needs you", titles.items[1]);
}

test "leaving while creation is queued or running says what became of it" {
    var cancellation: client.Cancellation = .{};
    var buffer: [1024]u8 = undefined;
    {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect((try rig.press("\r\x03")).? == .overview);
        try std.testing.expectEqualStrings("rui: The new Session was not created.\n", try finishedGuidance(rig, &buffer));
        try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
    }
    {
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.press("\r") == null);
        try rig.overview.dispatch(.all);
        try std.testing.expectEqualStrings("rui: Created n3w5es.\n", try finishedGuidance(rig, &buffer));
        try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
    }
}

test "a stop captured and then not sent keeps its handle, here and on departure" {
    var ops = fake_operations;
    ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, reply: *Reply) !void {
            const Sent = client.Stepped(client.MutationSendError, protocol_reply.MutationReply);
            return reply.record(Sent{ .failed = .{ .step = .connect, .err = error.FileNotFound } }, "stop-handle");
        }
    }.stop;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqualStrings("! k7m2qx stop unsure; details on exit", rig.overview.state.notice.?.text());
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: Not sure k7m2qx stopped. Check with: rui request recover stop-handle\n", try finishedGuidance(rig, &buffer));
}

test "leaving with a stop still queued says it was not sent" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expect((try rig.press("\x1b[H\x1b[B\x1b[B\x18\x18\x03")).? == .overview);
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("rui: k7m2qx was not stopped.\n", try finishedGuidance(rig, &buffer));
    try std.testing.expectEqual(@as(usize, 0), Seen.now.stops);
}

fn openOverview() !*Rig {
    const Shared = struct {
        var cancellation: client.Cancellation = .{};
    };
    return Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &Shared.cancellation);
}

fn openListed() !*Rig {
    const rig = try openOverview();
    errdefer rig.close();
    Seen.now.listed = listed_references.len;
    try std.testing.expect(try rig.overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(listed_references.len, rig.overview.state.order.items.len);
    rig.overview.state.selected = .{ .session = shownRow(rig, 2) };
    return rig;
}

fn shownRow(rig: *const Rig, at: usize) view.Reference {
    const state = &rig.overview.state;
    return state.rows.items[state.order.items[at]].reference;
}

test "Shift-Up and Shift-Down select the row above and below after ignored input" {
    const rig = try openListed();
    defer rig.close();
    for ([_][]const u8{ "", "two lines", "junk\xff" }) |draft| {
        for ([_]struct { bytes: []const u8, row: usize }{
            .{ .bytes = "\x1b[1;2A", .row = 1 },
            .{ .bytes = "\x1b[1;2:1A", .row = 1 },
            .{ .bytes = "\x1b[1;2B", .row = 3 },
            .{ .bytes = "\x1b[1;2:1B", .row = 3 },
        }) |case| {
            errdefer std.debug.print("draft={s} key={s}\n", .{ draft, case.bytes[1..] });
            try std.testing.expect(try rig.press(draft) == null);
            rig.overview.state.selected = .{ .session = shownRow(rig, 2) };
            try std.testing.expect(try rig.press(case.bytes) == null);
            try std.testing.expectEqualStrings(&shownRow(rig, case.row), &(if (rig.overview.state.selected == .session) rig.overview.state.selected.session else return error.TestExpectedSelection));
        }
    }
}

fn statusRowsShown(shown: *Shown, first: u16, height: u16) ![]const []const u8 {
    const rows = try shown.arena.allocator().alloc([]const u8, height - 1 - first);
    for (rows, first..) |*row, at| row.* = std.mem.trim(u8, try shown.line(@intCast(at)), " ");
    return rows;
}

test "Footer notice domain uses production clipping sanitization and colour" {
    const overflowing = "01234567890123456789012345678901234567890123456789" ++
        "01234567890123456789012345678901234567890123456789" ++
        "01234567890123456789012345678901234567890123456789" ++
        "01234567890123456789012345678901234567890123456789";
    const cases = [_]struct { raw: []const u8, displayed: []const u8 }{
        .{ .raw = "Configured.", .displayed = "Configured." },
        .{ .raw = overflowing, .displayed = overflowing },
        .{ .raw = "Saved.\nNext", .displayed = "Saved. Next" },
        .{ .raw = "Saved.\rNext", .displayed = "Saved. Next" },
        .{ .raw = "First\nSecond\rThird\x1b", .displayed = "First Second Third\\x1b" },
        .{ .raw = "! Not created: model_required", .displayed = "! Not created: model_required" },
        .{ .raw = "Configured.\n! label saved locally only", .displayed = "Configured. ! label saved locally only" },
    };
    const rig = try openListed();
    defer rig.close();
    for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| for ([_]view.Colour{ .quiet, .attention }) |colour| for (cases) |case| for ([_]u16{ 40, 46, 99, 140 }) |width| {
        errdefer std.debug.print("depth={s}, colour={s}, width={d}, notice={s}\n", .{ @tagName(depth), @tagName(colour), width, case.raw });
        rig.overview.caps.depth = depth;
        var notice: view.Notice = .{ .colour = colour, .len = case.raw.len };
        @memcpy(notice.bytes[0..notice.len], case.raw);
        rig.overview.state.notice = notice;
        var shown = try rig.shown(width, 24);
        defer shown.deinit();
        const visible = case.displayed[0..@min(case.displayed.len, width)];
        const footer = try shown.line(23);
        try std.testing.expectEqualStrings(visible, footer[footer.len - @min(footer.len, visible.len) ..]);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, try shown.text(), visible));
        try std.testing.expectEqual(@as(usize, 0), (try statusRowsShown(&shown, view.layout(&rig.overview.state).input, 24)).len);
        try std.testing.expect(std.mem.indexOf(u8, footer, "enter open") == null);
        const style = @import("widget_style.zig").of(rig.overview.caps, .{ .colour = colour });
        for (visible, width - visible.len..width) |byte, col| {
            const cell = shown.screen.readCell(@intCast(col), 23).?;
            try std.testing.expectEqualStrings(&.{byte}, cell.char.grapheme);
            try std.testing.expectEqual(style, cell.style);
        }
    };
}

test "Footer notices fit or truncate on the right without adding rows; persistent recovery keeps its rows" {
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const cases = [_]struct { notice: ?[]const u8, displayed: []const u8 }{
        .{ .notice = "Configured.", .displayed = "Configured." },
        .{ .notice = "Configured.\n! label saved locally only", .displayed = "Configured. ! label saved locally only" },
        .{ .notice = "The selected Session is already being archived; waiting for its work to settle before trying again.", .displayed = "The selected Session is already being archived; waiting for its work to settle before trying again." },
        .{ .notice = null, .displayed = "! Not confirmed · rui request recover " ++ key },
    };
    for (cases) |case| {
        const rig = try openListed();
        defer rig.close();
        if (case.notice) |text| {
            rig.overview.state.notice = .{ .colour = .normal, .len = text.len };
            @memcpy(rig.overview.state.notice.?.bytes[0..text.len], text);
        } else {
            const reference = rig.overview.state.selected.session;
            _ = try view.step(&rig.overview.state, .{ .unconfirmed = .{ .reference = reference, .recovery = .{ .saved = .{ .original = .{ .kind = .message, .key = key }, .rejected = false } } } });
        }
        for ([_]u16{ 46, 80, 140 }) |width| {
            var shown = try rig.shown(width, 24);
            defer shown.deinit();
            const rows = try statusRowsShown(&shown, view.layout(&rig.overview.state).input, 24);
            const footer = try shown.line(23);
            if (case.notice != null) {
                try std.testing.expectEqual(@as(usize, 0), rows.len);
                const visible = case.displayed[0..@min(case.displayed.len, width)];
                try std.testing.expect(std.mem.endsWith(u8, footer, std.mem.trimEnd(u8, visible, " ")));
                try std.testing.expect(std.mem.indexOf(u8, footer, "enter open") == null);
            } else {
                const joined = try std.mem.join(shown.arena.allocator(), " ", rows);
                try std.testing.expectEqualStrings(case.displayed, joined);
                try std.testing.expect(rows.len >= 1);
                try std.testing.expect(std.mem.indexOf(u8, footer, "enter open") == null);
            }
        }
    }
}

test "Settings Keys opens from the overview and Esc returns to settings" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        const overview = rig.overview;
        const selected = overview.state.selected;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        overview.root.settings_page.select(.keys);
        try overview.root.settings_page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(overview.root.settings_page.keys_open);
        var shown = try rig.shown(width, 24);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "ctrl+x") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "stop") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "/help") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Ctrl-X twice") == null);
        try std.testing.expect(try rig.press("\x1b") == null);
        try std.testing.expect(!overview.root.settings_page.keys_open);
        try std.testing.expect(overview.root.input.layer.settingsOpen());
        try std.testing.expect(overview.root.session == null);
        try std.testing.expect(try rig.press("\x1b") == null);
        try std.testing.expect(!overview.root.input.layer.settingsOpen());
        try std.testing.expectEqual(selected, overview.state.selected);
    }
}

test "overview archive effects preserve server filter, pending visibility, and restore intent" {
    const Listing = struct {
        var archive_state: protocol.SessionArchiveState = .active;
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            _ = try fake_operations.list(self, requests, cursor, page);
            for (page.rows[0..page.count]) |*row| {
                row.archive_state = archive_state;
                row.work.state = switch (archive_state) {
                    .active => .{ .working = .{ .since = test_now_s } },
                    .archiving => .{ .stopping = .{ .since = test_now_s } },
                    .archived => .{ .stopped = .{ .since = test_now_s, .cause = .stop } },
                };
            }
            return null;
        }
    };
    var ops = fake_operations;
    ops.list = Listing.list;
    Listing.archive_state = .active;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(protocol.SessionArchiveFilter.active, Seen.now.archive_filter);
    overview.state.selected = .{ .session = "k7m2qx".* };
    try std.testing.expect(try rig.press("\x1ba") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.stops);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.archive_session);
    try std.testing.expect(Seen.now.archive_requested);
    try std.testing.expectEqual(@as(usize, 1), overview.state.rows.items.len);
    try std.testing.expectEqual(view.ArchiveState.active, overview.state.rows.items[0].archive_state);
    Listing.archive_state = .archiving;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(view.ArchiveState.archiving, overview.state.rows.items[0].archive_state);
    Listing.archive_state = .archived;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 2 * view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), overview.state.rows.items.len);
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x1b[C\r") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(protocol.SessionArchiveFilter.archived, Seen.now.archive_filter);
    try std.testing.expectEqual(@as(usize, 1), overview.state.rows.items.len);
    _ = try overview.event(.{ .conversed = .{ .reference = "k7m2qx".*, .work = .stopped, .input = .unarchive } });
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.archives);
    try std.testing.expect(!Seen.now.archive_requested);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
    try std.testing.expectEqual(@as(usize, 1), overview.state.rows.items.len);
    Listing.archive_state = .active;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 + 3 * view.list_interval_ms }) == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), overview.state.rows.items.len);
    try std.testing.expect(try rig.press("\x1b") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(protocol.SessionArchiveFilter.active, Seen.now.archive_filter);
    try std.testing.expectEqual(@as(usize, 1), overview.state.rows.items.len);
}

test "Alt-A overview archives the selected row in every encoding" {
    for ([_][]const u8{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~" }) |chord| {
        const rig = try openListed();
        defer rig.close();
        const target = rig.overview.state.selected.session;
        try std.testing.expect(try rig.press(chord) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
        try std.testing.expectEqualStrings(&target, &Seen.now.archive_session);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
    }
}

test "a stop that ends with no answer reads as failed, whatever the job before it left" {
    const rig = try openListed();
    defer rig.close();
    const overview = rig.overview;
    try std.testing.expect(try rig.press("\x1ba") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
    overview.ops.stop = struct {
        fn stop(_: *Self, _: client.Requests, _: client.SessionStopInput, _: *Reply) !void {
            Seen.now.stops += 1;
            return error.ConnectionRefused;
        }
    }.stop;
    overview.state.notice = null;
    try std.testing.expect(try rig.press("\x1b[H\x1b[B\x1b[B\x18\x18") == null);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.stops);
    try std.testing.expectEqualStrings("! k7m2qx not stopped: stop_request_failed", overview.state.notice.?.text());
}

test "conversation archive and restore use the exact unlisted opened reference through the existing worker" {
    const rig = try openListed();
    defer rig.close();
    rig.overview.opened = "x9y8z7".*;
    const selected = rig.overview.state.selected.session;
    _ = try conversed(rig.overview, .idle, .{ .archive = .active });
    try rig.lend();
    try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
    try std.testing.expectEqualStrings("x9y8z7", &Seen.now.archive_session);
    try std.testing.expect(Seen.now.archive_requested);
    _ = try conversed(rig.overview, .idle, .unarchive);
    try rig.lend();
    try std.testing.expectEqual(@as(usize, 2), Seen.now.archives);
    try std.testing.expect(!Seen.now.archive_requested);
    try std.testing.expectEqualStrings("x9y8z7", &Seen.now.archive_session);
    try std.testing.expectEqualStrings(&selected, &rig.overview.state.selected.session);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
}

test "upgrade quiescence settles accepted queued and running archive mutations before releasing the panel" {
    const Gate = struct {
        var entered: std.atomic.Value(bool) = .init(false);
        var release: std.atomic.Value(bool) = .init(false);
        var observed_cancel: bool = false;
        var calls: usize = 0;

        fn archive(_: *Self, requests: client.Requests, _: client.SessionArchiveInput, reply: *Reply) !void {
            calls += 1;
            entered.store(true, .release);
            try test_poll.waitUntil(requests.io, test_poll.after(requests.io, .fromSeconds(10)), &release, test_poll.isSet);
            observed_cancel = requests.cancellation.?.stopped.load(.acquire);
            reply.* = .unconfirmed("original-archive-handle");
        }

        fn completed(overview: *Self) bool {
            return overview.worker.completed();
        }
    };
    for ([_]bool{ false, true }) |running| for ([_]bool{ false, true }) |archived| {
        var ops = fake_operations;
        ops.archive = Gate.archive;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        Gate.entered.store(false, .release);
        Gate.release.store(false, .release);
        Gate.observed_cancel = false;
        Gate.calls = 0;
        defer Gate.release.store(true, .release);
        const overview = rig.overview;
        _ = try overview.event(.{ .conversed = .{ .reference = "k7m2qx".*, .work = .idle, .input = if (archived) .{ .archive = .active } else .unarchive } });
        try std.testing.expectEqual(@as(usize, 1), overview.job_count);
        if (running) try overview.dispatch(.all);
        try overview.startUpgrade();
        try std.testing.expect(overview.state.upgrading());
        try std.testing.expect(!try overview.quiesceUpgrade());
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &Gate.entered, test_poll.isSet);
        try std.testing.expect(!try overview.quiesceUpgrade());
        try std.testing.expectEqual(@as(usize, 1), overview.state.request_count);
        try std.testing.expectEqual(@as(@FieldType(view.Request, "status"), .pending), overview.state.requests[0].status);
        _ = try overview.event(.{ .conversed = .{ .reference = "b4n8wd".*, .work = .idle, .input = if (archived) .unarchive else .{ .archive = .active } } });
        try std.testing.expectEqual(@as(usize, 1), overview.state.request_count);
        try std.testing.expectEqual(@as(usize, 0), overview.job_count);
        Gate.release.store(true, .release);
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), overview, Gate.completed);
        try std.testing.expect(try overview.quiesceUpgrade());
        try std.testing.expect(!Gate.observed_cancel);
        try std.testing.expectEqual(@as(usize, 1), Gate.calls);
        try std.testing.expectEqual(@as(@FieldType(view.Request, "status"), .unknown), overview.state.requests[0].status);
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try view.writeDeparture(&overview.state, null, &writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "original-archive-handle") != null);
        try std.testing.expect(overview.worker.thread == null);
    };
}

test "Esc while Upgrade waits for a held archive keeps the cancel: nothing checks or installs" {
    const Gate = struct {
        var entered: std.atomic.Value(bool) = .init(false);
        var release: std.atomic.Value(bool) = .init(false);

        fn archive(_: *Self, requests: client.Requests, _: client.SessionArchiveInput, reply: *Reply) !void {
            entered.store(true, .release);
            try test_poll.waitUntil(requests.io, test_poll.after(requests.io, .fromSeconds(10)), &release, test_poll.isSet);
            reply.* = .{ .outcome = .accepted };
        }

        fn completed(overview: *Self) bool {
            return overview.worker.completed();
        }
    };
    var ops = fake_operations;
    ops.archive = Gate.archive;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    Gate.entered.store(false, .release);
    Gate.release.store(false, .release);
    defer Gate.release.store(true, .release);
    const overview = rig.overview;
    _ = try overview.event(.{ .conversed = .{ .reference = "k7m2qx".*, .work = .idle, .input = .{ .archive = .active } } });
    try overview.dispatch(.all);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &Gate.entered, test_poll.isSet);
    try overview.startUpgrade();
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.appUpgrade(&ctx);
    try std.testing.expect(overview.state.upgrading() and !overview.upgrade_job.started);
    try std.testing.expect(try rig.press("\x1b[27u") == null);
    Gate.release.store(true, .release);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), overview, Gate.completed);
    var turns: usize = 0;
    while (overview.state.upgrading()) : (turns += 1) {
        try std.testing.expect(turns < 100);
        try overview.appUpgrade(&ctx);
    }
    try std.testing.expect(overview.state.notice == null);
    var cancellation_line: [upgrade_status.max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Upgrade cancelled; nothing changed", upgrade_status.line(overview.state.upgrade.run.?, &cancellation_line, .unicode).text);
    try std.testing.expect(overview.upgrade_report == null);
}

test "memory counts this TUI alone while no Host runs, at open and after a Host it sampled is gone" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const first = overview.hostFacts();
    try std.testing.expect(first.observation.facts() == null);
    const alone = first.memory orelse return error.TestUnexpectedResult;
    try std.testing.expect(alone.rui > 0 and alone.tools == null);
    overview.host_process = .{ .started_at = 1, .pid = std.c.getpid() };
    const second = overview.hostFacts();
    try std.testing.expect(second.observation.facts() == null);
    try std.testing.expect(overview.host_process == null);
    const after = second.memory orelse return error.TestUnexpectedResult;
    try std.testing.expect(after.rui > 0 and after.tools == null);
}

test "a conversation's Upgrade waits for the conversation's running read, though the overview ticks first" {
    const Worker = struct {
        fn read(_: *anyopaque, task: *ClientTask) !void {
            while (!task.cancellation.stopped.load(.acquire)) std.Thread.yield() catch {};
            return error.Cancelled;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var ops = fake_operations;
    ops.open = openSession;
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    Scratch.dir = tmp.dir;
    Scratch.count = 0;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6-luna" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.hooks.scratch = Scratch.scratch;
    try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
    defer {
        for (overview.retired.items) |retired| overview.disposeSession(retired.left);
        overview.retired.deinit(std.testing.allocator);
    }
    try std.testing.expect(try rig.settle() == null);
    const frontend = overview.app_session.?.frontend.?;
    try std.testing.expect(overview.root.session != null);
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    const backend = overview.settingsBackend();
    for ([_]bool{ false, true }) |typed| for ([_]bool{ false, true }) |queued| for ([_]bool{ false, true }) |running| {
        if (!typed and !queued and !running) continue;
        if (typed) frontend.info_edit = .{ .permission = .ask };
        if (queued) frontend.input.queueCommand("/requests");
        frontend.inspection.command_running = running;
        try std.testing.expectError(error.UpgradeUnavailable, backend.upgrade(backend.context));
        try std.testing.expect(!overview.state.upgrading());
        if (typed) try std.testing.expectEqual(@as(@FieldType(@import("status_page.zig").Session, "permission"), .ask), frontend.info_edit.?.permission);
        if (queued) try std.testing.expectEqualStrings("/requests", frontend.input.takeCommand().?);
        frontend.info_edit = null;
        frontend.inspection.command_running = false;
    };
    try frontend.reader.start(std.testing.io, frontend, Worker.read);
    try overview.startUpgrade();
    try std.testing.expect(overview.state.upgrading());
    for (0..3) |_| try overview.appUpgrade(&ctx);
    try std.testing.expect(overview.state.upgrading() and !overview.upgrade_job.started);
    _ = try conversed(overview, .idle, .cancel_upgrade);
    frontend.reader.cancel();
    frontend.reader.join() catch {};
    var turns: usize = 0;
    while (overview.state.upgrading()) : (turns += 1) {
        try std.testing.expect(turns < 100);
        try overview.appUpgrade(&ctx);
    }
    try std.testing.expect(overview.state.notice == null);
    var cancellation_line: [upgrade_status.max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Upgrade cancelled; nothing changed", upgrade_status.line(overview.state.upgrade.run.?, &cancellation_line, .unicode).text);
    try std.testing.expect(overview.upgrade_report == null);
    frontend.leaving = .returned;
    try appSessionLeft(overview, &ctx, .returned);
}

test "upgrade quiescence cancels read jobs rather than granting them mutation custody" {
    const Read = struct {
        var cancelled: bool = false;

        fn models(_: *Self, requests: client.Requests, _: std.mem.Allocator) ![]u8 {
            try test_poll.waitUntil(requests.io, test_poll.after(requests.io, .fromSeconds(10)), &requests.cancellation.?.stopped, test_poll.isSet);
            cancelled = requests.cancellation.?.stopped.load(.acquire);
            return error.Cancelled;
        }

        fn settled(overview: *Self) !bool {
            return overview.quiesceUpgrade();
        }
    };
    var ops = fake_operations;
    ops.models = Read.models;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    Read.cancelled = false;
    rig.overview.queue(.models);
    try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), rig.overview, Read.settled);
    try std.testing.expect(Read.cancelled);
    try std.testing.expect(rig.overview.worker.thread == null);
    try std.testing.expectEqual(@as(usize, 0), rig.overview.job_count);
}

test "a click on a Session row, as a terminal sends it, opens the row under it after the list scrolls" {
    const rig = try openListed();
    defer rig.close();
    rig.overview.state.selected = .{ .session = shownRow(rig, 4) };
    const target = shownRow(rig, 3);
    for (rig.overview.state.rows.items) |*listed| {
        if (std.mem.eql(u8, &listed.reference, &target)) listed.label = try @import("bounded.zig").Bounded(view.max_label_bytes).from("Click this Session");
    }
    var shown = try rig.shown(60, 13);
    defer shown.deinit();
    const row: u16 = for (0..7) |at| {
        const line = try shown.line(@intCast(at));
        if (std.mem.indexOf(u8, line, "Click this Session") != null) break @intCast(at);
    } else return error.TestExpectedRow;
    const quiet_row = view.layout(&rig.overview.state).settings.start + 2;
    const quiet = try shown.line(quiet_row);
    try std.testing.expectEqualStrings(@import("transport_options").version, std.mem.trim(u8, quiet, " "));
    try std.testing.expect(quiet.len > 10 and quiet[10] == ' ');
    try std.testing.expect(try rig.click(10, quiet_row, 60, 13) == null);
    try std.testing.expect(!rig.overview.root.input.layer.settingsOpen());
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    try std.testing.expect(try rig.click(10, row, 60, 13) == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings(&target, &Seen.now.conversed);
}

test "a click on New Session queues empty creation" {
    const rig = try openListed();
    defer rig.close();
    var shown = try rig.shown(60, 16);
    defer shown.deinit();
    const row: u16 = for (0..16) |at| {
        if (std.mem.indexOf(u8, try shown.line(@intCast(at)), "+ New Session") != null) break @intCast(at);
    } else return error.TestUnexpectedResult;
    try std.testing.expect(try rig.click(3, row, 60, 16) == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    try std.testing.expectEqual(view.Selection.new_session, rig.overview.state.selected);
    try std.testing.expect(rig.overview.state.creating());
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
    try std.testing.expectEqualStrings("n3w5es", &Seen.now.conversed);
}

test "a followed Session link opens the peer, Esc reopens the Session it left, then the overview" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    overview.follow.pending = "m3n4p5".*;
    try overview.followNext(&ctx, "k7m2qx".*);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("m3n4p5", &Seen.now.conversed);
    try overview.followNext(&ctx, "m3n4p5".*);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.conversations);
    try std.testing.expectEqualStrings("k7m2qx", &Seen.now.conversed);
    try overview.followNext(&ctx, "k7m2qx".*);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.conversations);
    try std.testing.expect(!ctx.quit);
}

test "a Session link that no longer opens ends as any failed open, naming that Session" {
    var ops = fake_operations;
    ops.open = struct {
        fn open(_: *Self, _: *vxfw.EventContext) !void {
            return error.SessionNotFound;
        }
    }.open;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    overview.follow.pending = "m3n4p5".*;
    try overview.followNext(&ctx, "k7m2qx".*);
    try std.testing.expect(ctx.quit);
    const unopened = overview.app_session.?;
    try std.testing.expectEqualStrings("m3n4p5", &unopened.session);
    try std.testing.expectError(error.SessionNotFound, unopened.ended);
    try std.testing.expectEqualStrings("k7m2qx", &overview.follow.return_to.?);
    try std.testing.expectEqual(@as(?view.Reference, null), overview.follow.pending);
    overview.app_session = null;
}

test "App overview schedules spinning rows only while Root shows the list" {
    const session: vxfw.Text = .{ .text = "Session" };
    for ([_]bool{ false, true }) |spinning| {
        const rig = try openOverview();
        defer rig.close();
        rig.overview.state.launch = .done;
        const overview = rig.overview;
        overview.caps = .{};
        Seen.now.working = @intFromBool(spinning);
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        overview.state.next_list_ms = std.math.maxInt(u64);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const Layout = struct { width: u16, open: bool, visible: bool };
        for ([_]Layout{
            .{ .width = 140, .open = false, .visible = true },
            .{ .width = 99, .open = false, .visible = true },
            .{ .width = 100, .open = false, .visible = true },
            .{ .width = 46, .open = false, .visible = true },
            .{ .width = 46, .open = true, .visible = false },
            .{ .width = 99, .open = true, .visible = false },
            .{ .width = 100, .open = true, .visible = true },
            .{ .width = 99, .open = true, .visible = false },
            .{ .width = 140, .open = true, .visible = true },
            .{ .width = 46, .open = true, .visible = false },
            .{ .width = 46, .open = false, .visible = true },
        }) |layout| {
            if (layout.open and overview.root.session == null) try overview.root.openSession(&ctx, session.widget(), null);
            if (!layout.open and overview.root.session != null) try overview.root.closeSession(&ctx);
            _ = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = layout.width, .height = 24 }, .cell_size = .{} });
            const drawn: view.Drawn = .{ .first = overview.app_sessions.shown.first, .end = overview.app_sessions.shown.end };
            const awake_ms = overview.animationMs();
            const deadline = view.nextRedrawAt(&overview.state, drawn, overview.caps, awake_ms);
            try std.testing.expectEqual(spinning, if (deadline) |at| at <= awake_ms + view.spin_interval_ms else false);
            const caps = overview.caps;
            overview.caps.depth = .none;
            const quiet = view.nextRedrawAt(&overview.state, drawn, overview.caps, awake_ms);
            try std.testing.expect(if (quiet) |at| at > awake_ms + view.spin_interval_ms else true);
            overview.caps = caps;
            overview.state.list_stale = true;
            const stale = view.nextRedrawAt(&overview.state, drawn, overview.caps, awake_ms);
            try std.testing.expect(if (stale) |at| at > awake_ms + view.spin_interval_ms else true);
            overview.state.list_stale = false;
            const row_state = overview.state.rows.items[0].state;
            overview.state.rows.items[0].state = .{ .idle = .{ .since = test_now_s } };
            const idle = view.nextRedrawAt(&overview.state, drawn, overview.caps, awake_ms);
            try std.testing.expect(if (idle) |at| at > awake_ms + view.spin_interval_ms else true);
            overview.state.rows.items[0].state = row_state;
            for (0..2) |_| {
                overview.app_redraw_at = if (spinning) awake_ms else deadline;
                ctx.redraw = false;
                try overview.root.widget().handleEvent(&ctx, .tick);
                try std.testing.expectEqual(spinning and layout.visible, ctx.redraw);
            }
        }
    }
}

test "App overview prepares full-width list rows and splits only beside a Session" {
    const Find = struct {
        fn count(surface: vxfw.Surface, target: vxfw.Widget) usize {
            var found: usize = @intFromBool(surface.widget.eql(target));
            for (surface.children) |child| found += count(child.surface, target);
            return found;
        }
    };
    const rig = try openListed();
    defer rig.close();
    const overview = rig.overview;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const header = overview.app_header.widget();
    for ([_]u16{ 46, 140 }) |width| {
        const surface = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 40 }, .cell_size = .{} });
        try std.testing.expectEqual(width, overview.state.size.width);
        try std.testing.expectEqual(@as(usize, 1), Find.count(surface, header));
        try std.testing.expectEqual(@as(usize, 1), Find.count(surface, overview.widget()));
    }
    const chat: vxfw.Text = .{ .text = "Chat", .width_basis = .parent };
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSession(&ctx, chat.widget(), null);
    const wide = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
    const panes = wide.children[0].surface.children;
    try std.testing.expectEqual(@as(u16, 40), overview.state.size.width);
    try std.testing.expectEqual(@as(u16, 40), panes[0].surface.size.width);
    try std.testing.expectEqual(@as(u16, 99), panes[2].surface.size.width);
    try std.testing.expectEqual(@as(usize, 1), Find.count(panes[0].surface, header));
    try std.testing.expectEqual(@as(usize, 1), Find.count(panes[2].surface, chat.widget()));
}

test "App overview list stays live beside a focused child and wheels stay in their panes" {
    const Peer = struct {
        wheels: usize = 0,
        fn widget(self: *@This()) vxfw.Widget {
            return .{ .userdata = self, .eventHandler = @This().event, .drawFn = @This().draw };
        }
        fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input == .mouse and (input.mouse.button == .wheel_down or input.mouse.button == .wheel_up)) {
                self.wheels += 1;
                ctx.consumeEvent();
            }
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .widget = self.widget(), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
    };
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    Seen.now.listed = listed_references.len;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    var peer: Peer = .{};
    overview.root.session = peer.widget();
    overview.root.input.area = .main;
    _ = try overview.event(.{ .conversation = "k7m2qx".* });
    overview.state.selected = .{ .session = "b4n8wd".* };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const draw: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 4 }, .cell_size = .{} };
    const frame = try overview.root.widget().draw(draw);
    const selected = overview.app_sessions.selected.?;
    const target = (try view.Lines.at(arena.allocator(), &overview.state, selected, 40, overview.caps, 0)).?.target.?;
    try std.testing.expectEqualStrings("k7m2qx", &target.open);
    try std.testing.expectEqualStrings("b4n8wd", &overview.state.selected.session);
    const before = overview.app_sessions.list.scroll;
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    try app_events.mouse(&ctx, frame, .{ .col = 4, .row = 2, .button = .wheel_down, .type = .press, .mods = .{} });
    try std.testing.expectEqual(@as(usize, 0), peer.wheels);
    try std.testing.expect(!std.meta.eql(before, overview.app_sessions.list.scroll));
    const scrolled = overview.app_sessions.list.scroll;
    try app_events.mouse(&ctx, frame, .{ .col = 45, .row = 2, .button = .wheel_down, .type = .press, .mods = .{} });
    try std.testing.expectEqual(@as(usize, 1), peer.wheels);
    try std.testing.expectEqualDeep(scrolled, overview.app_sessions.list.scroll);
    Seen.now.listed = 2;
    overview.state.next_list_ms = 0;
    const revision = overview.state.presentation_revision;
    _ = try service(overview);
    try rig.answered();
    ctx.redraw = false;
    try appEvent(overview, &ctx, .tick);
    try std.testing.expect(!ctx.redraw);
    try rig.lend();
    try std.testing.expect(overview.state.presentation_revision != revision);
    _ = try overview.root.widget().draw(draw);
    try std.testing.expectEqual(@as(usize, 2), overview.state.rows.items.len);
    try std.testing.expectEqual(@as(u16, 40), overview.state.size.width);
    try std.testing.expect(overview.root.session.?.eql(peer.widget()));
}

test "App overview list press follows only after the open child settles and opens once" {
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    const Find = struct {
        fn origin(surface: vxfw.Surface, target: vxfw.Widget, at: vxfw.RelativePoint) ?vxfw.RelativePoint {
            if (surface.widget.eql(target)) return at;
            for (surface.children) |child| {
                if (@This().origin(child.surface, target, .{ .row = at.row + child.origin.row, .col = at.col + child.origin.col })) |found| return found;
            }
            return null;
        }
        fn row(overview: *Self, id: []const u8) i17 {
            for (overview.app_sessions.shown_at) |span| if (span.target) |target| {
                if (target == .open and std.mem.eql(u8, &target.open, id)) return span.row;
            };
            unreachable;
        }
        fn leave(raw: *anyopaque, ctx: *vxfw.EventContext, outcome: SessionFrontend.Outcome) !void {
            const overview: *Self = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("b4n8wd", &overview.follow.pending.?);
            const frontend = overview.app_session.?.frontend.?;
            try std.testing.expect(frontend.reader.thread == null);
            try std.testing.expect(frontend.skill_task.thread == null);
            try appSessionLeft(raw, ctx, outcome);
        }
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            try std.testing.expect(overview.root.session == null);
            try std.testing.expectEqual(@as(usize, 1), overview.retired.items.len);
            try std.testing.expectEqualStrings("k7m2qx", &overview.follow.return_to.?);
            try std.testing.expectEqualStrings("b4n8wd", &overview.opened);
            Seen.now.conversations += 1;
            Seen.now.conversed = overview.opened;
            try overview.root.openSession(ctx, overview.app_sessions.widget(), null);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Scratch.dir = tmp.dir;
    Scratch.count = 0;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    Seen.now.listed = 2;
    try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
    try std.testing.expect(try rig.settle() == null);
    overview.ops.open = openSession;
    overview.hooks.scratch = Scratch.scratch;
    try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
    defer {
        if (overview.app_session) |left| {
            if (left.frontend) |frontend| frontend.stop();
            overview.disposeSession(left);
            overview.app_session = null;
        }
        for (overview.retired.items) |retired| overview.disposeSession(retired.left);
        overview.retired.deinit(std.testing.allocator);
    }
    overview.app_session.?.frontend.?.app_hooks.leave = Find.leave;
    overview.ops.open = Find.open;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const frame = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
    const origin = Find.origin(frame, overview.app_sessions.widget(), .{ .row = 0, .col = 0 }).?;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    const original = overview.root.session.?;
    try app_events.mouse(&ctx, frame, .{ .col = 4, .row = @intCast(origin.row + Find.row(overview, "k7m2qx")), .button = .left, .type = .press, .mods = .{} });
    try std.testing.expect(overview.root.session.?.eql(original));
    try std.testing.expect(overview.follow.pending == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    try app_events.mouse(&ctx, frame, .{ .col = 4, .row = @intCast(origin.row + Find.row(overview, "b4n8wd")), .button = .left, .type = .press, .mods = .{} });
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqualStrings("b4n8wd", &Seen.now.conversed);
    try std.testing.expect(overview.follow.pending == null);
    try std.testing.expect(!ctx.quit);
}

test "App shell divider follows overview locale across layouts and screen selection" {
    const rig = try openOverview();
    defer rig.close();
    try rig.environ.put("NO_COLOR", "1");
    const session: vxfw.Text = .{ .text = "Session" };
    for ([_]struct { locale: []const u8, glyph: []const u8, unicode: bool }{
        .{ .locale = "C", .glyph = "|", .unicode = false },
        .{ .locale = "en_US.UTF-8", .glyph = "│", .unicode = true },
    }) |case| {
        try rig.environ.put("LC_ALL", case.locale);
        var cancellation: client.Cancellation = .{};
        const overview = try create(rig.init, rig.overview.options, undefined, fake_operations, &cancellation);
        defer overview.destroy();
        overview.attention = &rig.attention;
        try std.testing.expectEqual(case.unicode, overview.caps.unicode);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        for (0..2) |paint| {
            if (paint != 0) try overview.paintCursor();
            for ([_]bool{ false, true }) |open| {
                if (open) try overview.root.openSession(&events, session.widget(), null) else try overview.root.closeSession(&events);
                for ([_]u16{ 46, 99, 100, 140 }) |width| {
                    const surface = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} });
                    const layout = surface.children[0].surface;
                    if (open and width >= Root.split_at) {
                        const divider = layout.children[1].surface;
                        for (divider.buffer) |cell| try std.testing.expectEqualStrings(case.glyph, cell.char.grapheme);
                        try std.testing.expectEqualDeep(@import("widget_style.zig").of(overview.caps, .{ .colour = .quiet }), divider.buffer[0].style);
                    } else try std.testing.expect(layout.widget.eql(if (open) session.widget() else overview.widget()));
                    var screen: vaxis.Screen = try .init(arena.allocator(), .{ .cols = width, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
                    const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 24, .screen = &screen };
                    try surface.render(window, (overview.root.session orelse overview.widget()));
                    if (!case.unicode) for (screen.buf) |cell| {
                        for (cell.char.grapheme) |byte| try std.testing.expect(byte < 0x80);
                    };
                }
            }
        }
    }
}

test "App list clicks validate present and removed targets with open and closed chats" {
    const Click = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn origin(surface: vxfw.Surface, target: vxfw.Widget, at: vxfw.RelativePoint) ?vxfw.RelativePoint {
            if (surface.widget.eql(target)) return at;
            for (surface.children) |child| {
                if (origin(child.surface, target, .{ .row = at.row + child.origin.row, .col = at.col + child.origin.col })) |found| return found;
            }
            return null;
        }
        fn leave(raw: *anyopaque, ctx: *vxfw.EventContext, outcome: SessionFrontend.Outcome) !void {
            const overview: *Self = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("b4n8wd", &overview.follow.pending.?);
            const frontend = overview.app_session.?.frontend.?;
            try std.testing.expect(frontend.reader.thread == null);
            try std.testing.expect(frontend.skill_task.thread == null);
            try appSessionLeft(raw, ctx, outcome);
        }
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            try std.testing.expect(overview.root.session == null);
            Seen.now.conversations += 1;
            Seen.now.conversed = overview.opened;
            try overview.root.openSession(ctx, overview.app_sessions.widget(), null);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Click.dir = tmp.dir;
    for ([_]bool{ false, true }) |open| {
        for ([_]bool{ true, false }) |present| {
            Click.files = 0;
            var cancellation: client.Cancellation = .{};
            const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
            defer rig.close();
            const overview = rig.overview;
            Seen.now.listed = 2;
            try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
            try std.testing.expect(try rig.settle() == null);
            defer {
                if (overview.app_session) |left| {
                    if (left.frontend) |frontend| frontend.stop();
                    overview.disposeSession(left);
                    overview.app_session = null;
                }
                for (overview.retired.items) |retired| overview.disposeSession(retired.left);
                overview.retired.deinit(std.testing.allocator);
            }
            if (open) {
                overview.hooks.scratch = Click.scratch;
                overview.ops.open = openSession;
                try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
                overview.app_session.?.frontend.?.app_hooks.leave = Click.leave;
            }
            overview.ops.open = Click.open;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const frame = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
            const at = Click.origin(frame, overview.app_sessions.widget(), .{ .row = 0, .col = 0 }).?;
            const row = for (overview.app_sessions.shown_at) |span| {
                if (span.target) |target| if (target == .open and std.mem.eql(u8, &target.open, "b4n8wd")) break span.row;
            } else unreachable;
            if (!present) {
                Seen.now.listed = 1;
                overview.state.next_list_ms = 0;
                try std.testing.expect(try overview.event(.{ .tick = (test_now_s + 1) * 1000 }) == null);
                try std.testing.expect(try rig.settle() == null);
                try std.testing.expect(overview.state.find("b4n8wd".*) == null);
            }
            const previous = overview.root.session;
            const selected = overview.state.selected;
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            try app_events.mouse(&ctx, frame, .{ .col = 4, .row = @intCast(at.row + row), .button = .left, .type = .press, .mods = .{} });
            try std.testing.expectEqual(@as(usize, @intFromBool(present)), Seen.now.conversations);
            try std.testing.expect(overview.follow.pending == null);
            try std.testing.expect(!ctx.quit);
            if (present) {
                try std.testing.expectEqualStrings("b4n8wd", &Seen.now.conversed);
                try std.testing.expectEqualStrings("b4n8wd", &overview.state.selected.session);
                try std.testing.expectEqual(@as(usize, @intFromBool(open)), overview.retired.items.len);
            } else {
                try std.testing.expectEqual(selected, overview.state.selected);
                try std.testing.expectEqual(@as(usize, 0), overview.retired.items.len);
                if (previous) |widget_| try std.testing.expect(overview.root.session.?.eql(widget_)) else try std.testing.expect(overview.root.session == null);
            }
        }
    }
}

test "App root navigation shows and focuses the main pane before every Session selection" {
    const Nav = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        var inits: usize = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            try std.testing.expect(overview.root.session == null);
            try std.testing.expect(!overview.root.input.layer.settingsOpen());
            try std.testing.expect((try focus(ctx)).eql(overview.widget()));
            Seen.now.conversations += 1;
            Seen.now.conversed = overview.opened;
            try overview.root.openSession(ctx, @This().widget(overview), null);
        }
        fn widget(overview: *Self) vxfw.Widget {
            return .{ .userdata = overview, .eventHandler = @This().event, .drawFn = @This().draw };
        }
        fn event(_: *anyopaque, _: *vxfw.EventContext, input: vxfw.Event) !void {
            if (input == .init) inits += 1;
        }
        fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            const overview: *Self = @ptrCast(@alignCast(raw));
            return .{ .widget = @This().widget(overview), .size = ctx.max.size(), .buffer = &.{}, .children = &.{} };
        }
        fn contains(surface: vxfw.Surface, target: vxfw.Widget) bool {
            if (surface.widget.eql(target)) return true;
            for (surface.children) |child| if (contains(child.surface, target)) return true;
            return false;
        }
        fn focus(ctx: *vxfw.EventContext) !vxfw.Widget {
            var i = ctx.cmds.items.len;
            while (i > 0) {
                i -= 1;
                if (ctx.cmds.items[i] == .request_focus) return ctx.cmds.items[i].request_focus;
            }
            return error.TestUnexpectedResult;
        }
    };
    const Guard = enum { allowed, pending, action, command };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Nav.dir = tmp.dir;
    for ([_]bool{ true, false }) |settings_open| {
        for ([_]u16{ 140, 46 }) |width| {
            for ([_]bool{ false, true }) |retained| {
                for ([_]view.Reference{ "k7m2qx".*, "b4n8wd".* }) |target| {
                    for (std.enums.values(Guard)) |guard| {
                        if (!retained and guard != .allowed) continue;
                        errdefer std.debug.print("navigation: settings={any}, width={d}, retained={any}, target={s}, guard={s}\n", .{ settings_open, width, retained, target, @tagName(guard) });
                        Nav.files = 0;
                        Nav.inits = 0;
                        var cancellation: client.Cancellation = .{};
                        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
                        defer rig.close();
                        const overview = rig.overview;
                        Seen.now.listed = 2;
                        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
                        try std.testing.expect(try rig.settle() == null);
                        defer {
                            if (overview.app_session) |left| {
                                if (left.frontend) |frontend| frontend.stop();
                                overview.disposeSession(left);
                                overview.app_session = null;
                            }
                            for (overview.retired.items) |retired_session| overview.disposeSession(retired_session.left);
                            overview.retired.deinit(std.testing.allocator);
                        }
                        if (retained) {
                            overview.hooks.scratch = Nav.scratch;
                            overview.ops.open = openSession;
                            try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
                        }
                        overview.ops.open = Nav.open;
                        const original = overview.root.session;
                        const frontend = if (overview.app_session) |left| left.frontend else null;
                        const same = retained and std.mem.eql(u8, &target, "k7m2qx");
                        if (frontend) |held| {
                            held.reading.opening = false;
                            switch (guard) {
                                .allowed => {},
                                .pending => {
                                    held.submission.intent = .{ .message = held.input.submitText("pending message") };
                                    held.submission.state = .submitting;
                                },
                                .action => held.reading.prepared_action = 42,
                                .command => held.inspection.command_running = true,
                            }
                        }
                        var ctx = rig.context();
                        defer ctx.cmds.deinit(std.testing.allocator);
                        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                        defer arena.deinit();
                        const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} };
                        _ = try overview.root.widget().draw(draw_context);
                        if (settings_open) {
                            try overview.root.openSettings(&ctx);
                            const settings = try overview.root.widget().draw(draw_context);
                            try std.testing.expect(Nav.contains(settings, overview.root.settings_page.widget()));
                            try std.testing.expect((try Nav.focus(&ctx)).eql(overview.root.settings_page.widget()));
                        }
                        ctx.cmds.clearRetainingCapacity();
                        ctx.redraw = false;
                        try overview.appNext(&ctx, try overview.event(.{ .clicked = .{ .target = .{ .open = target } } }));
                        try std.testing.expect(!ctx.quit);
                        try std.testing.expect(ctx.redraw);
                        try std.testing.expect(!overview.root.input.layer.settingsOpen());
                        try std.testing.expect(!overview.root.settings_page.hasChoice());
                        try std.testing.expect(overview.follow.pending == null);
                        const kept = retained and (same or guard != .allowed);
                        try std.testing.expectEqual(@as(usize, @intFromBool(!kept)), Seen.now.conversations);
                        try std.testing.expectEqual(@as(usize, @intFromBool(!kept)), Nav.inits);
                        try std.testing.expectEqual(@as(usize, @intFromBool(retained and !kept)), overview.retired.items.len);
                        const notice: ?[]const u8 = if (kept and !same) switch (guard) {
                            .allowed => unreachable,
                            .pending => "Esc returns to the overview once the original is confirmed.",
                            .action => "Links open once the Action is decided.",
                            .command => "Links open once the command ends.",
                        } else null;
                        if (kept) {
                            if (notice) |reason| {
                                try std.testing.expectEqualStrings(reason, frontend.?.notice orelse return error.TestUnexpectedResult);
                            } else try std.testing.expect(frontend.?.notice == null);
                        }
                        const requested = try Nav.focus(&ctx);
                        try std.testing.expect(requested.eql(overview.root.session.?));
                        try requested.handleEvent(&ctx, .focus_in);
                        const selected = try overview.root.widget().draw(draw_context);
                        try std.testing.expect(Nav.contains(selected, overview.root.session.?));
                        try std.testing.expect(!Nav.contains(selected, overview.root.settings_page.widget()));
                        const focused = try Nav.focus(&ctx);
                        try std.testing.expect(focused.eventHandler != null);
                        try std.testing.expect(Nav.contains(selected, focused));
                        try std.testing.expectEqual(width >= Root.split_at, overview.root.listVisible());
                        if (kept) {
                            const held = frontend.?;
                            try std.testing.expect(overview.root.session.?.eql(original.?));
                            try std.testing.expect(overview.app_session.?.frontend.? == held);
                            try std.testing.expect(focused.eql(held.app_input.composer.widget()));
                            switch (guard) {
                                .allowed => {},
                                .pending => {
                                    try std.testing.expectEqual(.submitting, held.submission.state);
                                    try std.testing.expectEqualStrings("pending message", try held.input.message(held.submission.intent.?.message));
                                },
                                .action => try std.testing.expectEqual(@as(?u64, 42), held.reading.prepared_action),
                                .command => try std.testing.expect(held.inspection.command_running),
                            }
                            if (notice) |reason| {
                                var shown = try rig.shown(width, 24);
                                defer shown.deinit();
                                try std.testing.expect(std.mem.indexOf(u8, try shown.text(), reason[0..31]) != null);
                            }
                        } else try std.testing.expectEqualStrings(&target, &Seen.now.conversed);
                    }
                }
            }
        }
    }
}

test "App settings Enter reaches Root at both widths with and without a retained Session" {
    const Settings = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn origin(surface: vxfw.Surface, target: vxfw.Widget, at: vxfw.RelativePoint) ?vxfw.RelativePoint {
            if (surface.widget.eql(target)) return at;
            for (surface.children) |child| {
                if (origin(child.surface, target, .{ .row = at.row + child.origin.row, .col = at.col + child.origin.col })) |found| return found;
            }
            return null;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Settings.dir = tmp.dir;
    for ([_]u16{ 46, 140 }) |width| {
        for ([_]bool{ false, true }) |retained| {
            errdefer std.debug.print("Settings row: width={d}, retained={any}\n", .{ width, retained });
            Settings.files = 0;
            var cancellation: client.Cancellation = .{};
            const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
            defer rig.close();
            const overview = rig.overview;
            Seen.now.listed = 2;
            try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
            try std.testing.expect(try rig.settle() == null);
            defer {
                if (overview.app_session) |left| {
                    if (left.frontend) |frontend| frontend.stop();
                    overview.disposeSession(left);
                    overview.app_session = null;
                }
                overview.retired.deinit(std.testing.allocator);
            }
            if (retained) {
                overview.hooks.scratch = Settings.scratch;
                overview.ops.open = openSession;
                try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
                _ = overview.app_session.?.frontend.?.input.append("retained draft");
            }
            const previous = overview.root.session;
            const frontend = if (overview.app_session) |left| left.frontend else null;
            var ctx = rig.context();
            defer ctx.cmds.deinit(std.testing.allocator);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const draw_context: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} };
            _ = try overview.root.widget().draw(draw_context);
            if (retained) {
                try appClick(overview, &ctx, .settings);
            } else {
                try app_events.send(&ctx, "\x1b[F", overview.root.widget(), overview.widget());
                try std.testing.expect(overview.state.selected == .settings);
                try std.testing.expect(!overview.root.input.layer.settingsOpen());
                try app_events.send(&ctx, "\r", overview.root.widget(), overview.widget());
            }
            try std.testing.expect(overview.root.input.layer.settingsOpen());
            try std.testing.expect(overview.state.selected == .settings);
            try std.testing.expect(!ctx.quit);
            try std.testing.expect(ctx.redraw);
            const focus = ctx.cmds.items[ctx.cmds.items.len - 1].request_focus;
            try std.testing.expect(focus.eql(overview.root.settings_page.widget()));
            try focus.handleEvent(&ctx, .focus_in);
            const opened = try overview.root.widget().draw(draw_context);
            try std.testing.expect(Settings.origin(opened, focus, .{ .row = 0, .col = 0 }) != null);
            try std.testing.expectEqual(width < Root.split_at, overview.root.settings_page.narrow);
            try std.testing.expectEqual(width >= Root.split_at, overview.root.listVisible());
            var shown = try rig.shown(width, 24);
            defer shown.deinit();
            try std.testing.expect(std.mem.indexOf(u8, try shown.line(1), "Rui") != null);
            try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Notifications") != null);
            if (previous) |widget_| {
                try std.testing.expect(overview.root.session.?.eql(widget_));
                try std.testing.expect(overview.app_session.?.frontend.? == frontend.?);
                try std.testing.expectEqualStrings("retained draft", frontend.?.input.composition().bytes);
                try std.testing.expect(Settings.origin(opened, widget_, .{ .row = 0, .col = 0 }) == null);
            } else try std.testing.expect(overview.root.session == null);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
            try std.testing.expectEqual(@as(usize, 0), overview.retired.items.len);
        }
    }
}

test "App settings receives the build version from its Overview owner" {
    const rig = try openOverview();
    defer rig.close();
    try std.testing.expectEqualStrings(@import("transport_options").version, rig.overview.root.settings_page.version);
}

test "App settings typed saves own their strings and settle through the Overview worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    const backend = overview.root.settings_page.backend.?;
    try std.testing.expectEqual(AppSettings.SaveState.idle, backend.save_state(backend.context));
    try std.testing.expect(try rig.press("kept draft") == null);
    var provider = "codex".*;
    var model = "gpt-5.5".*;
    try overview.saveDefaults(.{ .provider = .{ .set = &provider }, .model = .{ .set = &model }, .reasoning_effort = .{ .set = .low }, .notifications = false, .permission_mode = .{ .set = .ask } });
    @memset(&provider, 'x');
    @memset(&model, 'x');
    try std.testing.expectEqual(AppSettings.SaveState.pending, backend.save_state(backend.context));
    try std.testing.expect((try preferences.load(home)).notifications);
    try std.testing.expectError(error.DefaultsUnavailable, overview.saveDefaults(.{ .notifications = true }));
    try std.testing.expect(try rig.settle() == null);
    const saved = try preferences.load(home);
    try std.testing.expectEqualStrings("codex", saved.provider.slice());
    try std.testing.expectEqualStrings("gpt-5.5", saved.model.slice());
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .low), saved.reasoning_effort);
    try std.testing.expect(!saved.notifications);
    try std.testing.expectEqual(@as(?protocol.PermissionMode, .ask), saved.permission_mode);
    try std.testing.expectEqual(AppSettings.SaveState.saved, backend.save_state(backend.context));
    try std.testing.expectEqualStrings("gpt-5.5", overview.state.default.?.model.slice());

    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSettings(&ctx);
    const page = &overview.root.settings_page;
    page.select(.notifications);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(AppSettings.SaveState.pending, backend.save_state(backend.context));
    try std.testing.expect(!page.values.notifications);
    try std.testing.expect(try rig.settle() == null);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(page.values.notifications);
    try std.testing.expect(page.failures.get(.notifications) == null);

    page.select(.permissions);
    for ([_]protocol.PermissionMode{ .bypass, .ask }) |mode| {
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(page.hasChoice());
        page.panel.choice.?.selected = if (mode == .bypass) 0 else 1;
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expectEqual(AppSettings.SaveState.pending, backend.save_state(backend.context));
        try std.testing.expectEqual(@as(?AppSettings.Row, .permissions), page.saving_row);
        try std.testing.expect(try rig.settle() == null);
        try page.widget().handleEvent(&ctx, .tick);
        try std.testing.expectEqual(mode, (try preferences.load(home)).permission_mode.?);
        try std.testing.expectEqual(@as(?protocol.PermissionMode, mode), page.values.permission_mode);
        try std.testing.expectEqual(@as(?AppSettings.Row, null), page.saving_row);
        try std.testing.expectEqualStrings("gpt-5.5", overview.state.default.?.model.slice());
    }
}

test "App settings typed worker failure reaches its row and a later save recovers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSettings(&ctx);
    const page = &overview.root.settings_page;
    page.select(.notifications);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    const obstruction = try tmp.dir.createFile(std.testing.io, ".config", .{});
    obstruction.close(std.testing.io);
    try std.testing.expect(try rig.settle() == null);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(overview.defaults_save == .failed);
    try std.testing.expectEqualStrings(" · couldn't save", page.failures.get(.notifications).?);
    try std.testing.expect(!overview.state.left);
    try tmp.dir.deleteFile(std.testing.io, ".config");
    try std.testing.expect((try preferences.load(home)).notifications);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expect(try rig.settle() == null);
    try page.widget().handleEvent(&ctx, .tick);
    try std.testing.expect(!page.values.notifications);
    try std.testing.expect(page.failures.get(.notifications) == null);
    try std.testing.expect(overview.defaults_save == .saved);
}

test "App settings typed admission and Upgrade stay within the Overview owner" {
    const rig = try openOverview();
    defer rig.close();
    const overview = rig.overview;
    const backend = overview.root.settings_page.backend.?;
    const gpa = overview.init.gpa;
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    overview.init.gpa = failing.allocator();
    const refused = overview.saveDefaults(.{ .model = .{ .set = "example-chat" } });
    overview.init.gpa = gpa;
    try std.testing.expectError(error.OutOfMemory, refused);
    try std.testing.expectEqual(@as(usize, 0), overview.job_count);
    try std.testing.expectEqual(AppSettings.SaveState.idle, backend.save_state(backend.context));
    @memset(&overview.jobs, .host);
    overview.job_count = overview.jobs.len;
    try std.testing.expectError(error.DefaultsUnavailable, overview.saveDefaults(.{ .notifications = false }));
    overview.job_count = 0;
    try overview.startUpgrade();
    try std.testing.expectEqual(@as(?upgrade_status.Run, .checking), backend.run(backend.context));
    try std.testing.expect(!overview.upgrade_job.started);
    try std.testing.expectEqual(@as(usize, 0), overview.job_count);
    try std.testing.expectError(error.DefaultsUnavailable, overview.saveDefaults(.{ .notifications = false }));
    try overview.startUpgrade();
    try std.testing.expectEqual(@as(?upgrade_status.Run, .checking), backend.run(backend.context));
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSettings(&ctx);
    ctx.phase = .capturing;
    try overview.root.widget().captureEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(overview.upgrade_job.cancelling);
    try std.testing.expect(overview.root.input.layer.settingsOpen());
    const page = overview.root.settings_page.widget();
    const selected = overview.state.selected;
    try app_events.send(&ctx, "x\x1b[H\x18", overview.root.widget(), page);
    try std.testing.expectEqual(selected, overview.state.selected);
    try std.testing.expect(!ctx.quit and overview.root.input.layer.settingsOpen());
    try app_events.send(&ctx, "\x03", overview.root.widget(), page);
    try std.testing.expect(ctx.quit);
    ctx.quit = false;
    _ = try overview.event(.leave);
    try std.testing.expectError(error.UpgradeUnavailable, overview.startUpgrade());
    try std.testing.expectError(error.DefaultsUnavailable, overview.saveDefaults(.{ .notifications = false }));
}

test "App settings typed queued saves settle on departure and retain failures" {
    for ([_]bool{ false, true }) |fail| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        if (fail) try overview.saveDefaults(.{ .provider = .{ .set = "not-a-provider" } }) else try overview.saveDefaults(.{ .notifications = false });
        _ = try overview.event(.leave);
        if (fail) {
            try std.testing.expectError(error.UnsupportedPreferenceProvider, overview.flushSaves());
            try std.testing.expect(overview.defaults_save == .failed);
        } else {
            try overview.flushSaves();
            try std.testing.expect(!(try preferences.load(home)).notifications);
            try std.testing.expect(overview.defaults_save == .saved);
        }
        try std.testing.expectEqual(@as(usize, 0), overview.job_count);
    }
}

test "pinned New Session remains above the end marker and responds to clicks and Enter" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        _ = try rig.press("\x1b[F\x1b[A");
        const selected = rig.overview.state.selected.session;
        for (0..2) |_| {
            var shown = try rig.shown(width, 9);
            defer shown.deinit();
            try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "   + New Session"));
            try std.testing.expect(std.mem.indexOf(u8, try shown.line(1), "Archived") != null);
            try std.testing.expect(std.mem.indexOf(u8, try shown.line(2), "↑") != null);
            const span = for (rig.overview.app_sessions.shown_at) |span| {
                if (span.target) |target| if (target == .open and std.mem.eql(u8, &target.open, &selected)) break span;
            } else return error.SelectedSessionMissing;
            try std.testing.expectEqual(@as(u16, 1), span.height);
        }
        try std.testing.expect(try rig.click(3, 0, width, 9) == null);
        try std.testing.expectEqual(view.Selection.new_session, rig.overview.state.selected);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
        try std.testing.expect(try rig.click(3, 0, width, 9) == null);
        try std.testing.expect(rig.overview.state.creating());
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
        try std.testing.expectEqualStrings("n3w5es", &Seen.now.conversed);
    }
}

test "chat sidebar and overview share pinned New Session and Archived controls" {
    const Chat = struct {
        const child: vxfw.Text = .{ .text = "Chat transcript" };
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            _ = try overview.event(.{ .conversation = overview.opened });
            try overview.root.openSession(ctx, child.widget(), null);
        }
    };
    const rig = try openListed();
    defer rig.close();
    rig.overview.ops.open = Chat.open;
    _ = try rig.press("\x1b[F\x1b[A");
    var before = try rig.shown(140, 11);
    defer before.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try before.text(), "+ New Session") != null);
    const selected = rig.overview.state.selected.session;
    _ = try rig.press("\r");
    for ([_]u16{ 140, 46, 140, 46 }) |width| {
        var shown = try rig.shown(width, 20);
        defer shown.deinit();
        const text = try shown.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "Chat transcript") != null);
        try std.testing.expectEqual(width == 140, std.mem.indexOf(u8, text, "+ New Session") != null);
        try std.testing.expectEqual(width == 140, std.mem.indexOf(u8, text, "Archived") != null);
        if (width == 140) {
            const line = rig.overview.app_sessions.selected.?;
            const target = (try view.Lines.at(shown.arena.allocator(), &rig.overview.state, line, 40, rig.overview.caps, 0)).?.target.?;
            try std.testing.expectEqualStrings(&selected, &target.open);
        }
    }
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    _ = try rig.overview.event(.{ .conversation = null });
    try rig.overview.root.closeSession(&ctx);
    for ([_]u16{ 46, 140 }) |width| {
        var shown = try rig.shown(width, 20);
        defer shown.deinit();
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "   + New Session"));
        try std.testing.expect(std.mem.indexOf(u8, try shown.line(1), "Archived") != null);
    }
}

test "chat pinned controls preserve late-listed Sessions and the physical last-row footer" {
    const Chat = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Chat.dir = tmp.dir;
    Chat.files = 0;
    const rig = try openOverview();
    defer rig.close();
    const overview = rig.overview;
    overview.hooks.scratch = Chat.scratch;
    overview.ops.open = openSession;
    try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
    defer {
        if (overview.app_session) |left| {
            if (left.frontend) |frontend| frontend.stop();
            overview.disposeSession(left);
            overview.app_session = null;
        }
        overview.retired.deinit(std.testing.allocator);
    }
    overview.app_session.?.frontend.?.reading.opening = false;
    for ([_]bool{ false, true }) |listed| {
        if (listed) {
            Seen.now.listed = listed_references.len;
            try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
            try std.testing.expect(try rig.settle() == null);
        }
        for ([_]vxfw.Size{ .{ .width = 140, .height = 40 }, .{ .width = 46, .height = 30 }, .{ .width = 140, .height = 30 } }) |size| {
            var shown = try rig.shown(size.width, size.height);
            defer shown.deinit();
            try std.testing.expectEqual(size.width == 140, std.mem.indexOf(u8, try shown.text(), "+ New Session") != null);
            try std.testing.expect(std.mem.indexOf(u8, try shown.line(size.height - 1), "alt+i info") == null);
            if (size.width == 140) {
                try std.testing.expectEqual(if (listed) listed_references.len else 1, overview.app_sessions.shown_at.len);
                if (listed) {
                    try std.testing.expect(std.mem.indexOf(u8, try shown.line(2), "Fix the flaky test") != null);
                    for (overview.app_sessions.shown_at, 0..) |span, index| {
                        try std.testing.expectEqual(@as(i17, @intCast(index)), span.row);
                        try std.testing.expectEqual(@as(u16, 1), span.height);
                    }
                }
            }
        }
    }
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    _ = try overview.event(.{ .conversation = null });
    try overview.root.closeSession(&ctx);
    for ([_]u16{ 140, 46 }) |width| {
        var shown = try rig.shown(width, 30);
        defer shown.deinit();
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "   + New Session"));
        try std.testing.expect(std.mem.indexOf(u8, try shown.line(1), "Archived") != null);
        try std.testing.expect(std.mem.indexOf(u8, try shown.line(2), "Fix the flaky test") != null);
    }
}

test "pinned New Session wins the last header row over a provider band" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        const state = &rig.overview.state;
        const row = &state.rows.items[state.order.items[0]];
        row.state = .{ .failed = .{ .since = test_now_s, .code = .{}, .resets_at = null } };
        try row.state.failed.code.set("provider_http_401");
        try std.testing.expect(view.band(state) != null);
        var shown = try rig.shown(width, 2);
        defer shown.deinit();
        try std.testing.expect(std.mem.startsWith(u8, try shown.line(0), "   + New Session"));
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Archived") == null);
    }
}

test "relaunch departure matrix preserves every screen and all unsent drafts" {
    const gpa = std.testing.allocator;
    for (std.enums.values(session_upgrade.Outcome)) |outcome| {
        for ([_]bool{ false, true }) |conversation| {
            for ([_]bool{ false, true }) |guidance| {
                for ([_]bool{ false, true }) |drafted| {
                    var cancellation: client.Cancellation = .{};
                    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "", .directory = "/requests" }, fake_operations, &cancellation);
                    defer rig.close();
                    const overview = rig.overview;
                    var arena: std.heap.ArenaAllocator = .init(gpa);
                    defer arena.deinit();
                    const a = arena.allocator();
                    const receipt: @import("Installation.zig").Receipt = .{
                        .operation_build = try a.dupe(u8, "/published/build"),
                        .selected_after = try a.dupe(u8, "/published/build"),
                        .selected_version = .{ .schema = 60, .patch = 0 },
                    };
                    overview.upgrade_job = .{
                        .allocator = a,
                        .started = true,
                        .finished = true,
                        .operation = .install,
                        .outcome = outcome,
                        .failure = if (guidance) error.ConnectionRefused else null,
                        .checked = .{
                            .candidate = .{
                                .version = .{ .schema = 60, .patch = 0 },
                                .tag = try a.dupe(u8, "v0.60.0"),
                                .archive_name = try a.dupe(u8, "fixture"),
                                .archive_url = try a.dupe(u8, "fixture"),
                                .checksum_url = try a.dupe(u8, "fixture"),
                                .sha256 = @splat(0),
                            },
                            .selected = .absent,
                            .hosts = .{},
                            .home = try a.dupe(u8, "/home"),
                            .store = try a.dupe(u8, "/store"),
                            .running_executable = try a.dupeSentinel(u8, "/old/rui", 0),
                            .path = .{ .state = .selected },
                        },
                        .result = .{
                            .installation = if (outcome == .unchanged) .{ .unchanged = receipt } else .{ .installed = receipt },
                            .hosts = .{ .version = .{ .schema = 1, .patch = 2 }, .entries = try a.dupe(@import("host_restart_all.zig").Entry, &.{.{ .socket = try a.dupe(u8, ""), .store = try a.dupe(u8, "/store"), .state = .{ .outcome = switch (outcome) {
                                .unchanged => .not_needed,
                                .compatible => .{ .ready = .{ .instance = @splat(1), .pid = 42 } },
                                .incompatible => .{ .client_incompatible = 42 },
                            } } }}) },
                            .store = try a.dupe(u8, "/store"),
                        },
                    };
                    overview.state.upgrade.run = overview.upgrade_job.status();
                    try overview.keepUpgrade();
                    try std.testing.expectEqual(guidance, overview.upgrade_guidance);
                    var ending_buffer: [upgrade_status.max_line_bytes]u8 = undefined;
                    const ending = upgrade_status.relaunchLine(overview.state.upgrade.run.?, &ending_buffer, .unicode);
                    if (outcome == .incompatible) {
                        const report = overview.upgrade_report.?.written();
                        try std.testing.expect(std.mem.indexOf(u8, report, "This client cannot safely resume Host requests") != null);
                        try std.testing.expect(std.mem.indexOf(u8, report, "Next: inspect") == null);
                        try std.testing.expect(std.mem.indexOf(u8, ending, "restart rui") == null);
                    }
                    if (drafted) {
                        try overview.session_drafts.put(gpa, "aaaaaa", .{ .bytes = "inactive α", .cursor = 2, .anchor = .{ .position = 7, .end = 9 } });
                        try overview.session_drafts.put(gpa, "bbbbbb", .{ .bytes = "another", .cursor = 0, .rejected = .invalid });
                    }
                    if (conversation) {
                        overview.opened = "cccccc".*;
                        const frontend = try gpa.create(SessionFrontend);
                        frontend.begin(rig.init, "/store", &overview.opened, "/requests", undefined, undefined, undefined, undefined, rig.screen, &cancellation, undefined);
                        if (drafted) frontend.input.restore(.{ .bytes = "open α", .cursor = 2, .anchor = .{ .position = 11, .end = 13 } });
                        overview.app_session = .{ .session = overview.opened, .frontend = frontend, .files = null, .ended = .detached };
                        _ = try overview.event(.{ .conversation = overview.opened });
                    }
                    var ctx = rig.context();
                    defer ctx.cmds.deinit(gpa);
                    overview.leaveForUpgrade(&ctx, outcome);
                    try std.testing.expectEqual(outcome != .unchanged and !guidance, ctx.quit);
                    const request = try overview.finishApp({});
                    try std.testing.expectEqual(outcome != .unchanged and !guidance, request != null);
                    if (request) |value| {
                        defer value.deinit(gpa);
                        try std.testing.expectEqualStrings("/published/build/bin/rui", value.executable);
                        if (outcome == .incompatible) try std.testing.expect(std.mem.indexOf(u8, value.receipt, "This client cannot safely resume Host requests") != null);
                        try std.testing.expectEqual(conversation, value.open != null);
                        var parsed = try handoff.decode(gpa, value.handoff, "/store");
                        defer parsed.deinit();
                        try std.testing.expectEqual(conversation, parsed.value.open != null);
                        if (conversation) try std.testing.expectEqualStrings("cccccc", parsed.value.open.?);
                        try std.testing.expectEqualStrings("", parsed.value.overview.bytes);
                        try std.testing.expectEqual(@as(usize, 0), parsed.value.overview.cursor);
                        try std.testing.expectEqual(@as(usize, if (drafted) (if (conversation) 3 else 2) else 0), parsed.value.drafts.len);
                        for (parsed.value.drafts) |entry| {
                            if (std.mem.eql(u8, entry.id, "aaaaaa")) {
                                try std.testing.expectEqualStrings("inactive α", entry.snapshot.bytes);
                                try std.testing.expectEqual(@as(usize, 2), entry.snapshot.cursor);
                                try std.testing.expectEqual(SessionInput.Recalled{ .position = 7, .end = 9 }, entry.snapshot.anchor.?);
                            } else if (std.mem.eql(u8, entry.id, "bbbbbb")) {
                                try std.testing.expectEqualStrings("another", entry.snapshot.bytes);
                                try std.testing.expectEqual(.invalid, entry.snapshot.rejected.?);
                            } else {
                                try std.testing.expectEqualStrings("cccccc", entry.id);
                                try std.testing.expectEqualStrings("open α", entry.snapshot.bytes);
                                try std.testing.expectEqual(SessionInput.Recalled{ .position = 11, .end = 13 }, entry.snapshot.anchor.?);
                            }
                        }
                        try std.testing.expectEqualStrings(ending, parsed.value.line);
                    }
                }
            }
        }
    }
}

test "relaunch startup restores chat drafts and open conversation without upgrade notices" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    const overview_draft: SessionInput.Snapshot = .{ .bytes = "overview α", .cursor = 3, .rejected = .overflow };
    const chat: SessionInput.Snapshot = .{ .bytes = "chat β", .cursor = 2, .anchor = .{ .position = 7, .end = 9 }, .rejected = .invalid };
    const line = "Upgraded to 0.60.0 · Host restarted";
    const bytes = try handoff.encode(gpa, .{
        .v = 1,
        .store = "/store",
        .open = "bbbbbb",
        .overview = overview_draft,
        .drafts = &.{ .{ .id = "aaaaaa", .snapshot = chat }, .{ .id = "bbbbbb", .snapshot = .{ .bytes = "open draft", .cursor = 1 } } },
        .line = line,
    });
    defer gpa.free(bytes);
    const parsed = try handoff.decode(gpa, bytes, "/store");
    rig.overview.options.restoration = &parsed.value;
    try rig.overview.restoreRelaunch();
    parsed.deinit();
    try std.testing.expectEqualStrings("bbbbbb", &rig.overview.options.open.?);
    try std.testing.expect(view.footerNotice(&rig.overview.state) == null);
    var status: view.StatusBuffer = undefined;
    try std.testing.expect(view.statusLine(&rig.overview.state, rig.overview.caps, &status) == null);
    for ([_][]const u8{ "aaaaaa", "bbbbbb" }) |id| {
        const draft = rig.overview.session_drafts.take(gpa, id).?;
        defer draft.deinit(gpa);
        if (std.mem.eql(u8, id, "aaaaaa")) {
            try std.testing.expectEqualStrings(chat.bytes, draft.snapshot.bytes);
            try std.testing.expectEqual(chat.cursor, draft.snapshot.cursor);
            try std.testing.expectEqual(chat.anchor, draft.snapshot.anchor);
            try std.testing.expectEqual(chat.rejected, draft.snapshot.rejected);
        } else try std.testing.expectEqualStrings("open draft", draft.snapshot.bytes);
    }
    try rig.overview.restoreRelaunch();
    try std.testing.expect(rig.overview.session_drafts.first == null);
    try std.testing.expect(rig.overview.options.restoration == null);
}

test "App settings Model borrow ends on every Overview menu replacement or release" {
    for ([_]bool{ false, true }) |release| {
        const rig = try openOverview();
        defer rig.close();
        const overview = rig.overview;
        try std.testing.expect(try overview.event(.{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "future-chat\ngpt-5.5\n" } } }}) } }) == null);
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        const page = &overview.root.settings_page;
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(page.model_choice.active);
        try std.testing.expectEqual(&overview.state.menu, page.model_choice.menu);
        try std.testing.expect(try overview.event(.{ .models = .unanswered }) == null);
        try std.testing.expect(page.model_choice.active);
        if (release) {
            try std.testing.expect(try overview.event(.leave) == null);
        } else {
            try std.testing.expect(try overview.event(.{ .models = .{ .menu = try model_picker.testMenu(&.{.{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-5.5\n" } } }}) } }) == null);
        }
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(!page.hasChoice());
        try std.testing.expectEqual(AppSettings.SaveState.idle, overview.defaults_save);
        try std.testing.expect(overview.root.input.layer.settingsOpen());
    }
}

test "bare CSI and SS3 arrows move between view tabs through the existing key table" {
    for ([_][]const u8{ "\x1b[C", "\x1bOC" }) |right| for ([_][]const u8{ "\x1b[D", "\x1bOD" }) |left| {
        const rig = try openOverview();
        defer rig.close();
        rig.overview.state.selected = .sessions;
        _ = try rig.press(right);
        try std.testing.expectEqual(view.Selection.archived, rig.overview.state.selected);
        _ = try rig.press(left);
        try std.testing.expectEqual(view.Selection.sessions, rig.overview.state.selected);
        _ = try rig.press("\x1b[1;5C");
        _ = try rig.press("\x1b[1;3C");
        try std.testing.expectEqual(view.Selection.sessions, rig.overview.state.selected);
    };
}

test "App settings Model keeps every named app binding live while filter text stays local" {
    for (std.enums.values(keymap.Key)) |key| for (key_encodings.get(key)) |bytes| {
        if (std.mem.eql(u8, bytes, "\x1b")) continue;
        errdefer std.debug.print("settings Model key={s} bytes={x}\n", .{ @tagName(key), bytes });
        const rig = try openOverview();
        defer rig.close();
        const overview = rig.overview;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        const page = &overview.root.settings_page;
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(page.hasChoice());
        const selected = overview.state.selected;
        try app_events.send(&ctx, bytes, overview.root.widget(), page.widget());
        const action = view.keys.get(key);
        try std.testing.expectEqual(action == .exit, ctx.quit);
        try std.testing.expectEqual(selected, overview.state.selected);
        try std.testing.expect(overview.root.input.layer.settingsOpen());
        try std.testing.expectEqual(action != .exit and key != .escape and key != .ctrl_g, page.hasChoice());
    };
}

test "App settings Model filters live choices and saves the next Session at both widths" {
    for ([_]u16{ 140, 46 }) |width| for ([_][]const u8{ "codex", "openai" }) |provider| for ([_][]const u8{ "gpt-6-luna", "future-chat" }) |id| {
        errdefer std.debug.print("Model width={d} provider={s} id={s}\n", .{ width, provider, id });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        try pin(home, provider, "gpt-5.5");
        _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .high }, .permission_mode = .{ .set = .ask } }, &.initFill(.configured));
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = provider, .model = "gpt-5.5" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        try std.testing.expect((try overview.event(.{ .clicked = .{ .target = .settings } })).? == .open_settings);
        const initial = modelsSnapshot(overview);
        try std.testing.expect(initial.menu == null);
        _ = modelsSnapshot(overview);
        try std.testing.expect((try overview.event(.{ .clicked = .{ .target = .settings } })).? == .open_settings);
        try std.testing.expectEqual(@as(usize, 1), overview.job_count);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.model_lists);
        _ = try overview.event(.{ .input = .{ .key = .{ .action = .first } } });
        try std.testing.expect(try overview.event(.{ .models = .{ .menu = try model_picker.testMenu(&.{
            .{ .provider = .codex, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\nfuture-chat\n" } } },
            .{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-5.5\ngpt-6-luna\nfuture-chat\n" } } },
        }) } }) == null);
        try std.testing.expect(try rig.press("kept draft") == null);
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        const page = &overview.root.settings_page;
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expect(page.model_choice.active);
        try std.testing.expectEqual(&overview.state.menu, page.model_choice.menu);
        try app_events.send(&ctx, id, overview.root.widget(), page.widget());
        var filtered = try rig.shown(width, 24);
        defer filtered.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try filtered.text(), id) != null);
        try app_events.send(&ctx, "\r", overview.root.widget(), page.widget());
        try std.testing.expect(!page.hasChoice());
        try std.testing.expectEqual(AppSettings.SaveState.pending, overview.defaults_save);
        try std.testing.expect(try rig.settle() == null);
        try page.widget().handleEvent(&ctx, .tick);
        const saved = try preferences.load(home);
        try std.testing.expectEqualStrings(id, saved.model.slice());
        try std.testing.expectEqualStrings(provider, saved.provider.slice());
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), saved.reasoning_effort);
        try std.testing.expectEqual(@as(?protocol.PermissionMode, .ask), saved.permission_mode);
        try std.testing.expectEqualStrings(id, overview.state.default.?.model.slice());
        try app_events.send(&ctx, "\x1b", overview.root.widget(), page.widget());
        try std.testing.expect(!overview.root.input.layer.settingsOpen());
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqualStrings(id, Seen.now.creation.model.?.slice());
        try std.testing.expectEqualStrings(provider, Seen.now.creation.provider.?.slice());
    };
}

test "chat info archive status projects only the latest exact Session ledger request" {
    const rig = try openOverview();
    defer rig.close();
    const overview = rig.overview;
    overview.opened = "k7m2qx".*;
    try std.testing.expectEqual(@import("chat_info.zig").SaveState.idle, archiveState(overview));
    overview.state.requests[0] = .{ .kind = .archive, .session = overview.opened, .status = .done };
    overview.state.requests[1] = .{ .kind = .archive, .session = "b4n8wd".*, .status = .pending };
    overview.state.requests[2] = .{ .kind = .stop, .session = overview.opened, .status = .pending };
    overview.state.requests[3] = .{ .kind = .unarchive, .session = overview.opened, .status = .pending };
    overview.state.request_count = 4;
    try std.testing.expectEqual(@import("chat_info.zig").SaveState.saved, archiveState(overview));
    for ([_]@FieldType(view.Request, "status"){ .pending, .done, .failed, .unknown }) |status| {
        overview.state.requests[4] = .{ .kind = .archive, .session = overview.opened, .status = status };
        overview.state.request_count = 5;
        const expected: @import("chat_info.zig").SaveState = switch (status) {
            .pending => .pending,
            .done => .saved,
            .failed, .unknown => .failed,
        };
        try std.testing.expectEqual(expected, archiveState(overview));
    }
}

test "chat info Archive receives its worker answer after the ordinary ledger entry retires" {
    const Archive = struct {
        const Outcome = enum { completed, pending, failed, unknown };
        var outcome: Outcome = .completed;
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn archive(_: *Self, _: client.Requests, _: client.SessionArchiveInput, reply: *Reply) !void {
            reply.* = switch (outcome) {
                .completed => .{ .outcome = .accepted },
                .pending => .{ .outcome = .accepted, .archive_pending = true },
                .failed => .refused("archive_refused"),
                .unknown => .unconfirmed("archive-handle"),
            };
        }
    };
    for (std.enums.values(Archive.Outcome)) |outcome| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        Archive.dir = tmp.dir;
        Archive.files = 0;
        Archive.outcome = outcome;
        var ops = fake_operations;
        ops.open = openSession;
        ops.archive = Archive.archive;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-5.5" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = Archive.scratch;
        try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
        defer {
            if (overview.app_session) |left| {
                left.frontend.?.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
        }
        try std.testing.expect(try rig.settle() == null);
        const frontend = overview.app_session.?.frontend.?;
        frontend.reading.opening = false;
        const backend = frontend.app_info.backend;
        _ = try backend.archive(backend.context);
        try std.testing.expectEqual(@import("chat_info.zig").SaveState.pending, backend.state(backend.context));
        try std.testing.expect(try rig.settle() == null);
        const accepted = outcome == .completed or outcome == .pending;
        try std.testing.expectEqual(if (accepted) @import("chat_info.zig").SaveState.saved else .failed, backend.state(backend.context));
        try std.testing.expectEqual(@as(usize, @intFromBool(outcome == .unknown)), overview.state.request_count);
    }
}

test "chat info Archive backend forwards exact core ledger admission through the real Overview lender" {
    const Files = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    const Held = enum { none, pending, unknown };
    for ([_]bool{ false, true }) |full| for (std.enums.values(Held)) |held| for ([_]view.ArchiveState{ .active, .archiving, .archived }) |archive| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        Files.dir = tmp.dir;
        Files.count = 0;
        var ops = fake_operations;
        ops.open = openSession;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-5.5" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = Files.scratch;
        try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
        defer {
            if (overview.app_session) |left| {
                left.frontend.?.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
        }
        try std.testing.expect(try rig.settle() == null);
        const frontend = overview.app_session.?.frontend.?;
        frontend.reading.opening = false;
        frontend.line.archive_state = archive;
        if (held != .none) {
            overview.state.requests[0] = .{ .kind = .archive, .session = overview.opened, .status = if (held == .pending) .pending else .unknown };
            overview.state.request_count = 1;
        }
        if (full) while (overview.state.request_count < view.max_requests) {
            overview.state.requests[overview.state.request_count] = .{ .kind = .stop, .session = "other0".*, .status = .unknown };
            overview.state.request_count += 1;
        };
        const before = overview.state.request_count;
        const retained = overview.state.requests;
        const backend = frontend.app_info.backend;
        if (full or held != .none or archive != .active) {
            try std.testing.expectEqual(view.IntentAdmission.refused, try backend.archive(backend.context));
            try std.testing.expectEqual(@import("chat_info.zig").SaveState.idle, backend.state(backend.context));
            try std.testing.expectEqual(before, overview.state.request_count);
            try std.testing.expectEqualDeep(retained[0..before], overview.state.requests[0..before]);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.archives);
            try std.testing.expectEqual(@as(usize, 0), overview.job_count);
        } else {
            try std.testing.expectEqual(view.IntentAdmission.admitted, try backend.archive(backend.context));
            try std.testing.expectEqual(@import("chat_info.zig").SaveState.pending, backend.state(backend.context));
            try std.testing.expect(try rig.settle() == null);
            try std.testing.expectEqual(@as(usize, 1), Seen.now.archives);
            try std.testing.expectEqual(@import("chat_info.zig").SaveState.saved, backend.state(backend.context));
        }
    };
}

test "Overview mouse Settings hover persists across frames and never changes selection or focus" {
    const rig = try openListed();
    defer rig.close();
    var plain = try rig.shown(80, 24);
    defer plain.deinit();
    const row: u16 = for (0..24) |y| {
        if (std.mem.startsWith(u8, try plain.line(@intCast(y)), "     Settings")) break @intCast(y);
    } else return error.TestExpectedSettingsRow;
    const selection = rig.overview.state.selected;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try rig.overview.app_settings_line.widget().handleEvent(&ctx, .mouse_enter);
    try rig.overview.app_settings_line.widget().handleEvent(&ctx, .{ .mouse = .{ .col = 4, .row = 1, .button = .none, .type = .motion, .mods = .{} } });
    var hovered = try rig.shown(80, 24);
    defer hovered.deinit();
    try std.testing.expectEqual(@import("widget_style.zig").of(rig.overview.caps, .{ .background = .hover }).bg, hovered.screen.readCell(4, row).?.style.bg);
    try std.testing.expectEqual(@import("widget_style.zig").of(rig.overview.caps, .{ .background = .hover }).reverse, hovered.screen.readCell(4, row).?.style.reverse);
    try std.testing.expectEqual(selection, rig.overview.state.selected);
    for (ctx.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
    try rig.overview.app_settings_line.widget().handleEvent(&ctx, .mouse_leave);
    var left = try rig.shown(80, 24);
    defer left.deinit();
    try std.testing.expectEqual(plain.screen.readCell(4, row).?.style, left.screen.readCell(4, row).?.style);
    try std.testing.expect(try rig.click(4, row, 80, 24) == null);
    try std.testing.expect(rig.overview.root.input.layer.settingsOpen());
}

test "Overview mouse Host start and retry hover preserve foreground selection and focus and click invokes the action" {
    for ([_]bool{ false, true }) |retry| for ([_]view.Caps.Depth{ .none, .direct }) |depth| {
        const ops = HostRecovery.operations();
        HostRecovery.availability = .stopped;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.caps.depth = depth;
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        if (retry) {
            HostRecovery.fail_start = true;
            try std.testing.expect(try rig.hostStart() == null);
            try std.testing.expect(try rig.settle() == null);
            HostRecovery.fail_start = false;
        }
        const starts = HostRecovery.starts;
        try std.testing.expectEqual(@as(?HostLaunch.Next, if (retry) .retry else .start), overview.hostNext());
        const host_widget = hostNotice(overview).?;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 1 }, .cell_size = .{} };
        const plain = try host_widget.draw(draw_ctx);
        const selected = overview.state.selected;
        var events = rig.context();
        defer events.cmds.deinit(std.testing.allocator);
        try host_widget.handleEvent(&events, .mouse_enter);
        try host_widget.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 0, .button = .none, .type = .motion, .mods = .{} } });
        const hovered = try host_widget.draw(draw_ctx);
        const hover = @import("widget_style.zig").of(overview.caps, .{ .background = .hover });
        for (hovered.buffer, plain.buffer) |cell, before| {
            try std.testing.expectEqual(hover.bg, cell.style.bg);
            try std.testing.expectEqual(hover.ul_style, cell.style.ul_style);
            try std.testing.expectEqual(before.style.fg, cell.style.fg);
        }
        try std.testing.expect(overview.app_host_hover.pointing);
        try std.testing.expectEqual(selected, overview.state.selected);
        try std.testing.expectEqual(starts, HostRecovery.starts);
        for (events.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
        try host_widget.handleEvent(&events, .mouse_leave);
        const left = try host_widget.draw(draw_ctx);
        try std.testing.expectEqual(plain.readCell(2, 0).style, left.readCell(2, 0).style);
        for ([_]vxfw.Size{ .{ .width = 0, .height = 1 }, .{ .width = 60, .height = 0 } }) |size| {
            _ = try host_widget.draw(draw_ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
            try std.testing.expectEqual(@as(usize, 0), overview.app_host_hover.targets.len);
            try host_widget.handleEvent(&events, .{ .mouse = .{ .col = 0, .row = 0, .button = .left, .type = .press, .mods = .{} } });
            try std.testing.expectEqual(starts, HostRecovery.starts);
        }
        var frame = try rig.shown(80, 24);
        defer frame.deinit();
        const row: u16 = for (0..24) |y| {
            if (std.mem.indexOf(u8, try frame.line(@intCast(y)), "Host stopped") != null) break @intCast(y);
        } else return error.TestExpectedHostLine;
        try std.testing.expect(try rig.click(2, row, 80, 24) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(starts + 1, HostRecovery.starts);
        try std.testing.expect(hostNotice(overview) == null);
        try std.testing.expectEqual(@as(usize, 0), overview.app_host_hover.targets.len);
    };
}

test "Overview mouse Host line without a start or retry has no hover or click action" {
    const Case = enum { paused, stopping, upgrading, starting, incompatible, store_identity, ready_warning };
    for (std.enums.values(Case)) |case| {
        const ops = HostRecovery.operations();
        HostRecovery.availability = switch (case) {
            .paused => .paused,
            .stopping => .stopping,
            .ready_warning => .ready,
            else => .stopped,
        };
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.queue(.host);
        try std.testing.expect(try rig.settle() == null);
        switch (case) {
            .upgrading => overview.state.upgrade.after = .blocked,
            .starting => overview.queue(.start_host),
            .incompatible => overview.host_launch = .{ .failed = .{ .kind = .incompatible, .err = error.IncompatibleHost } },
            .store_identity => overview.host_launch = .{ .failed = .{ .kind = .store_identity, .err = error.StoreIdentityMismatch } },
            .ready_warning => overview.host_launch = .{ .ready = .invalid_openai_base_url },
            else => {},
        }
        try std.testing.expectEqual(null, overview.hostNext());
        const host_widget = hostNotice(overview).?;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const draw_ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 60, .height = 1 }, .cell_size = .{} };
        const plain = try host_widget.draw(draw_ctx);
        var events = rig.context();
        defer events.cmds.deinit(std.testing.allocator);
        try host_widget.handleEvent(&events, .mouse_enter);
        try host_widget.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 0, .button = .none, .type = .motion, .mods = .{} } });
        const hovered = try host_widget.draw(draw_ctx);
        try std.testing.expectEqual(plain.readCell(2, 0).style, hovered.readCell(2, 0).style);
        try std.testing.expect(!overview.app_host_hover.pointing);
        try std.testing.expectEqual(@as(usize, 0), overview.app_host_hover.targets.len);
        try host_widget.handleEvent(&events, .mouse_leave);
        try host_widget.handleEvent(&events, .{ .mouse = .{ .col = 2, .row = 0, .button = .left, .type = .press, .mods = .{} } });
        try std.testing.expectEqual(@as(usize, 0), HostRecovery.starts);
        for (events.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
    }
}

test "Overview pinned New Session hover survives unchanged frames without selecting or focusing" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        _ = try rig.press("\x1b[B");
        const selected = rig.overview.state.selected;
        try std.testing.expect(selected == .session);
        var plain = try rig.shown(width, 30);
        defer plain.deinit();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        const pinned = rig.overview.app_new_session.widget();
        const motion: vxfw.Event = .{ .mouse = .{ .col = 4, .row = 0, .button = .none, .type = .motion, .mods = .{} } };
        try pinned.handleEvent(&ctx, .mouse_enter);
        try pinned.handleEvent(&ctx, motion);
        for (0..2) |_| {
            var hovered = try rig.shown(width, 30);
            defer hovered.deinit();
            const style = @import("widget_style.zig").of(rig.overview.caps, .{ .background = .hover });
            try std.testing.expectEqual(style.bg, hovered.screen.readCell(4, 0).?.style.bg);
            try std.testing.expectEqual(style.reverse, hovered.screen.readCell(4, 0).?.style.reverse);
            try std.testing.expect(rig.overview.app_new_session.row.inner.hover.pointing);
            try std.testing.expectEqual(selected, rig.overview.state.selected);
            for (ctx.cmds.items) |cmd| try std.testing.expect(cmd != .request_focus);
            ctx.cmds.clearRetainingCapacity();
            ctx.redraw = false;
            try pinned.handleEvent(&ctx, motion);
            try std.testing.expect(!ctx.redraw);
            try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        }
        try pinned.handleEvent(&ctx, .mouse_leave);
        var left = try rig.shown(width, 30);
        defer left.deinit();
        try std.testing.expectEqual(plain.screen.readCell(4, 0).?.style, left.screen.readCell(4, 0).?.style);
        try std.testing.expect(!rig.overview.app_new_session.row.inner.hover.pointing);
    }
}
test "App settings Sign-in Enter and click use the Overview owner and return to settings" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |click| for ([_]bool{ false, true }) |busy| {
        errdefer std.debug.print("settings sign-in width={d} click={} busy={}\n", .{ width, click, busy });
        const rig = try openOverview();
        defer rig.close();
        const overview = rig.overview;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        const page = &overview.root.settings_page;
        try std.testing.expect(page.backend.?.models != null);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        _ = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} });
        if (busy) overview.defaults_save = .pending;
        ctx.cmds.clearRetainingCapacity();
        if (click) {
            try page.widget().handleEvent(&ctx, .{ .mouse = .{ .col = 3, .row = 2 + @backingInt(AppSettings.Row.sign_in), .button = .left, .type = .press, .mods = .{} } });
        } else {
            page.select(.sign_in);
            try app_events.send(&ctx, "\r", overview.root.widget(), page.widget());
        }
        try std.testing.expectEqual(!busy, overview.root.input.layer.signInOpen());
        try std.testing.expect(overview.root.input.layer.settingsOpen());
        try std.testing.expect(!page.hasChoice());
        if (busy) {
            try std.testing.expectEqualStrings(" · settings busy", page.failures.get(.sign_in).?);
            for (ctx.cmds.items) |command| try std.testing.expect(command != .request_focus);
            continue;
        }
        try std.testing.expect(overview.root.sign_in.?.eql(overview.sign_in.widget()));
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(overview.sign_in.widget()));
        try std.testing.expect(!overview.signInIsFirstRun());
        try app_events.send(&ctx, "\x1b", overview.root.widget(), overview.sign_in.widget());
        try std.testing.expect(!overview.root.input.layer.signInOpen());
        try std.testing.expect(overview.root.input.layer.settingsOpen() and !ctx.quit);
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(page.widget()));
    };
}

test "Sign-in completion applies the core default and restores only a visible focus target" {
    for ([_]bool{ false, true }) |session_open| for ([_]bool{ false, true }) |warning| for ([_]bool{ false, true }) |default_failed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .low } }, &.initFill(.configured));
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        const session: vxfw.Text = .{ .text = "Retained Session" };
        if (session_open) overview.root.session = session.widget();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        try overview.root.openSignIn(&ctx);
        ctx.cmds.clearRetainingCapacity();
        var activation: SignIn.Activation = .{ .binding = .{}, .store = .{} };
        try activation.binding.provider.set("openai");
        try activation.binding.model.set(@import("product_defaults.zig").recommended_model);
        try activation.store.set("/store");
        activation.default_failed = default_failed;
        if (warning) activation.launch = .{ .outcome = .{ .ready = .{ .facts = .{ .store = activation.store, .instance = @splat(1), .active_capacity = 4, .started_at = 1, .custody_occupied = 0, .paused = false, .capabilities = .{ .bash = true, .providers = .{ .codex = .chatgpt_device, .openai = .unserved, .chatgpt = .unserved } } } } }, .warning = .invalid_openai_base_url };
        try signedIn(overview, &ctx, activation);
        if (warning or default_failed) {
            try std.testing.expectEqual(true, overview.state.notice != null);
            const text = overview.state.notice.?.text();
            try std.testing.expectEqual(warning, std.mem.indexOf(u8, text, "OpenAI URL invalid") != null);
            try std.testing.expectEqual(default_failed, std.mem.indexOf(u8, text, if (warning) "default not saved" else "couldn't save default") != null);
            try std.testing.expect(std.mem.indexOfAny(u8, text, "\r\n\x1b") == null);
        }
        try std.testing.expectEqual(protocol.Provider.openai, overview.state.default.?.provider);
        try std.testing.expectEqualStrings(activation.binding.model.slice(), overview.state.default.?.model.slice());
        const next_creation = overview.creationSnapshot(overview.state.default);
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .low), (try next_creation.settings).effort);
        try std.testing.expect(overview.state.login_at != null);
        try std.testing.expect(!overview.root.input.layer.signInOpen() and !overview.root.input.layer.settingsOpen());
        const expected = if (session_open) session.widget() else (overview.root.session orelse overview.widget());
        try std.testing.expect(ctx.cmds.items[ctx.cmds.items.len - 1].request_focus.eql(expected));
        if (session_open) {
            for (ctx.cmds.items) |command| if (command == .request_focus) {
                try std.testing.expect(command.request_focus.eql(session.widget()));
            };
        }
    };
}

test "Sign-in admission waits for every pending default writer and Host upgrade" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "", .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    const Busy = enum { defaults_pending, departed, upgrade_checking, upgrade_reobserving, upgrade_blocked };
    for (std.enums.values(Busy)) |busy| {
        switch (busy) {
            .defaults_pending => overview.defaults_save = .pending,
            .departed => overview.state.left = true,
            .upgrade_checking => overview.state.upgrade = .{ .run = .checking },
            .upgrade_reobserving => overview.state.upgrade = .{ .after = .reobserving },
            .upgrade_blocked => overview.state.upgrade = .{ .after = .blocked },
        }
        try std.testing.expectError(error.DefaultsUnavailable, overview.openSignIn(&ctx));
        try std.testing.expect(!overview.root.input.layer.signInOpen());
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        overview.defaults_save = .idle;
        overview.state.left = false;
        overview.state.upgrade = .{};
    }
    try overview.openSignIn(&ctx);
    try std.testing.expect(overview.root.input.layer.signInOpen());
}

test "Sign-in captures outside clicks above Settings and retains the current Session" {
    for ([_]bool{ false, true }) |retained| {
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "", .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        const session: vxfw.Text = .{ .text = "Retained Session" };
        if (retained) overview.root.session = session.widget();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.root.openSettings(&ctx);
        try overview.openSignIn(&ctx);
        const before = overview.root.session;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const frame = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
        for ([_]vaxis.Mouse.Type{ .press, .release }) |kind| try app_events.mouse(&ctx, frame, .{ .col = 1, .row = 39, .button = .left, .type = kind, .mods = .{} });
        try std.testing.expect(overview.root.input.layer.signInOpen());
        try std.testing.expect(overview.root.input.layer.settingsOpen());
        try std.testing.expectEqual(before, overview.root.session);
        try closeSignIn(overview, &ctx);
        try std.testing.expect(!overview.root.input.layer.signInOpen());
        try std.testing.expect(overview.root.input.layer.settingsOpen());
    }
}

test "Sign-in Esc at the choice leaves unless the first-run screen has no default, and only that screen holds the overview's tick" {
    const Origin = enum { first_run, settings };
    const Nav = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn focus(ctx: *vxfw.EventContext) ?vxfw.Widget {
            var i = ctx.cmds.items.len;
            while (i > 0) {
                i -= 1;
                if (ctx.cmds.items[i] == .request_focus) return ctx.cmds.items[i].request_focus;
            }
            return null;
        }
        fn titled(ctx: *vxfw.EventContext) bool {
            for (ctx.cmds.items) |command| if (command == .set_title) return true;
            return false;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    Nav.dir = tmp.dir;
    for (std.enums.values(Origin)) |from| for ([_]bool{ false, true }) |default| for ([_]bool{ false, true }) |retained| {
        errdefer std.debug.print("sign-in escape: from={s} default={} retained={}\n", .{ @tagName(from), default, retained });
        Nav.files = 0;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .provider = if (default) "codex" else null, .model = if (default) "gpt-6-luna" else null, .sign_in = from == .first_run }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        try std.testing.expectEqual(default, overview.state.default != null);
        Seen.now.listed = 2;
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        defer {
            if (overview.app_session) |left| {
                if (left.frontend) |frontend| frontend.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
            for (overview.retired.items) |retired_session| overview.disposeSession(retired_session.left);
            overview.retired.deinit(std.testing.allocator);
        }
        if (retained) {
            overview.hooks.scratch = Nav.scratch;
            overview.ops.open = openSession;
            try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
            overview.app_session.?.frontend.?.reading.opening = false;
        }
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        const page = &overview.sign_in;
        page.activate = null;
        page.ready = null;
        if (from == .settings) {
            try overview.root.openSettings(&ctx);
            try overview.openSignIn(&ctx);
        }
        try std.testing.expect(overview.root.input.layer.signInOpen());
        try std.testing.expect(page.state.page == .account);
        try std.testing.expectEqual(@import("sign_in.zig").Control.chatgpt, page.state.focus);
        const stays = from == .first_run and !default;
        ctx.cmds.clearRetainingCapacity();
        try appEvent(overview, &ctx, .tick);
        try std.testing.expectEqual(!stays, Nav.titled(&ctx));
        ctx.cmds.clearRetainingCapacity();
        try app_events.send(&ctx, "\x1b", overview.root.widget(), page.widget());
        try std.testing.expect(!ctx.quit);
        try std.testing.expectEqual(stays, overview.root.input.layer.signInOpen());
        try std.testing.expectEqual(from == .settings, overview.root.input.layer.settingsOpen());
        if (stays) {
            try std.testing.expect(Nav.focus(&ctx) == null);
            continue;
        }
        const back = if (from == .settings) overview.root.settings_page.widget() else overview.root.session orelse overview.widget();
        try std.testing.expect(Nav.focus(&ctx).?.eql(back));
        try std.testing.expectEqual(retained, overview.root.session != null);
    };
}

test "overview ignores printable ASCII Unicode unknown keys x r and bracketed paste at both widths" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        var before = try rig.shown(width, 24);
        defer before.deinit();
        const selected = rig.overview.state.selected;
        const count = rig.overview.state.order.items.len;
        const jobs = rig.overview.job_count;
        for ([_][]const u8{
            " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~",
            "α你好🙂",
            "x",
            "r",
            "\x1b[999~",
            "\x1b[57399u",
            "\x1b[200~hello\r\n/configure --model other\r\x18\x1ba\x1b[A\x1b[201~",
        }) |bytes| {
            try std.testing.expect(try rig.press(bytes) == null);
            try std.testing.expectEqualDeep(selected, rig.overview.state.selected);
            try std.testing.expectEqual(count, rig.overview.state.order.items.len);
            try std.testing.expectEqual(jobs, rig.overview.job_count);
            try std.testing.expect(!rig.overview.state.creating());
            try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.stops);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.archives);
        }
        var after = try rig.shown(width, 24);
        defer after.deinit();
        try std.testing.expectEqualStrings(try before.text(), try after.text());
        try std.testing.expect(after.cursor() == null);
        try std.testing.expect(std.mem.indexOf(u8, try after.text(), "Type a task") == null);
    }
}

test "New Session Enter and clicks cannot duplicate queued or answered creation" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |click_first| {
        const rig = try openListed();
        defer rig.close();
        if (click_first) {
            try std.testing.expect(try rig.click(3, 0, width, 24) == null);
        } else {
            try std.testing.expect(try rig.press("\x1b[H\r") == null);
        }
        try std.testing.expect(rig.overview.state.creating());
        try std.testing.expectEqual(@as(usize, 1), rig.overview.job_count);
        try std.testing.expect(try rig.press("\r\r") == null);
        try std.testing.expect(try rig.click(3, 0, width, 24) == null);
        try std.testing.expectEqual(@as(usize, 1), rig.overview.job_count);
        try rig.overview.dispatch(.all);
        try rig.answered();
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expect(try rig.click(3, 0, width, 24) == null);
        try std.testing.expectEqual(@as(usize, 0), rig.overview.job_count);
        try std.testing.expect(try rig.next(try rig.overview.complete()) == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
        try std.testing.expectEqualStrings("n3w5es", &Seen.now.conversed);
        try std.testing.expect(!rig.overview.state.creating());
    };
}

test "creation rejection and uncertainty retain the Configure ledger result and recovery key" {
    const CreationAnswer = struct {
        var uncertain: bool = false;
        fn create(_: *Self, _: client.Requests, _: configure_input.ConfigureInput, reply: *Reply) !void {
            Seen.now.creates += 1;
            reply.* = if (uncertain) .unconfirmed("create-lost") else .refused("model_required");
        }
    };
    for ([_]bool{ false, true }) |uncertain| {
        CreationAnswer.uncertain = uncertain;
        var ops = fake_operations;
        ops.create = CreationAnswer.create;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        try std.testing.expect(try rig.press("\r") == null);
        if (!uncertain) _ = try rig.overview.event(.leave);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
        try std.testing.expectEqual(uncertain, rig.overview.state.creating());
        if (uncertain) {
            try std.testing.expect(try rig.press("\r\r") == null);
            try std.testing.expect(try rig.click(3, 0, 80, 24) == null);
            try std.testing.expectEqual(@as(usize, 0), rig.overview.job_count);
        }
        try std.testing.expectEqual(@as(usize, 1), rig.overview.state.request_count);
        const request = rig.overview.state.requests[0];
        try std.testing.expect(request.kind == .create);
        try std.testing.expectEqual(@as(@TypeOf(request.status), if (uncertain) .unknown else .failed), request.status);
        try std.testing.expectEqualStrings(if (uncertain) "create-lost" else "model_required", request.text.slice());
        var guidance: [1024]u8 = undefined;
        const text = try finishedGuidance(rig, &guidance);
        try std.testing.expect(std.mem.indexOf(u8, text, if (uncertain) "rui request recover create-lost" else "model_required") != null);
    }
}

test "accepted empty creation opens the returned Session with blank focused chat and no Message intent" {
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
    };
    for ([_]u16{ 46, 140 }) |width| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        try pin(home, "codex", "gpt-6-luna");
        _ = try preferences.update(home, .{ .permission_mode = .{ .set = .ask }, .reasoning_effort = .{ .set = .high } }, &.initFill(.configured));
        Scratch.dir = tmp.dir;
        Scratch.files = 0;
        var ops = fake_operations;
        ops.open = openSession;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6-luna" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = Scratch.scratch;
        defer {
            if (overview.app_session) |left| {
                left.frontend.?.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
            for (overview.retired.items) |retired| overview.disposeSession(retired.left);
            overview.retired.deinit(std.testing.allocator);
        }
        Seen.now.listed = listed_references.len;
        try std.testing.expect(try overview.event(.{ .tick = test_now_s * 1000 }) == null);
        try std.testing.expect(try rig.settle() == null);
        _ = try rig.press("\x1b[F\x1b[A");
        try std.testing.expect(try rig.click(3, 0, width, 11) == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
        try std.testing.expectEqualStrings("n3w5es", &overview.opened);
        try std.testing.expectEqualStrings("n3w5es", &overview.app_session.?.session);
        const frontend = overview.app_session.?.frontend.?;
        try std.testing.expect(overview.root.session.?.eql(frontend.widget()));
        try std.testing.expectEqualStrings("", frontend.input.composition().bytes);
        try std.testing.expect(frontend.submission.intent == null);
        try std.testing.expectEqualStrings("/work", Seen.now.creation.workspace.slice());
        try std.testing.expectEqualStrings("codex", Seen.now.creation.provider.?.slice());
        try std.testing.expectEqualStrings("gpt-6-luna", Seen.now.creation.model.?.slice());
        try std.testing.expectEqualStrings("ask", Seen.now.creation.permission_mode.slice());
        try std.testing.expectEqualStrings("high", Seen.now.creation.reasoning_effort.?.slice());
        try std.testing.expectEqualStrings(product_defaults.creationTools(true, @import("os/read_image_file.zig").available).allowed, Seen.now.creation.tools.?.slice());
        try std.testing.expectEqualStrings(product_defaults.creationTools(true, @import("os/read_image_file.zig").available).loaded, Seen.now.creation.loaded_tools.?.slice());
        try std.testing.expect(Seen.now.creation.label == null);
        try std.testing.expect(frontend.reader.thread == null);
        const focused = rig.last_focus orelse return error.ExpectedChatFocus;
        try std.testing.expect(focused.eql(frontend.app_input.composer.widget()));
        var shown = try rig.shown(width, 24);
        defer shown.deinit();
        const frame = try overview.root.widget().draw(.{ .arena = shown.arena.allocator(), .cell_arena = shown.arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 24 }, .cell_size = .{} });
        const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = width, .height = 24, .screen = &shown.screen };
        try frame.render(window, focused);
        try std.testing.expect(shown.cursor() != null);
    }
}

const key_encodings = std.enums.EnumArray(keymap.Key, []const []const u8).init(.{
    .escape = &.{ "\x1b", "\x1b[27u", "\x1b[27;3u", "\x1b[27;1;27~" },
    .ctrl_c = &.{ "\x03", "\x1b[99;5u", "\x1b[27;5;99~" },
    .ctrl_d = &.{ "\x04", "\x1b[100;5u", "\x1b[27;5;100~" },
    .ctrl_g = &.{ "\x07", "\x1b[103;5u", "\x1b[27;5;103~" },
    .ctrl_n = &.{ "\x0e", "\x1b[110;5u", "\x1b[27;5;110~" },
    .ctrl_o = &.{ "\x0f", "\x1b[111;5u", "\x1b[27;5;111~" },
    .ctrl_p = &.{ "\x10", "\x1b[112;5u", "\x1b[27;5;112~" },
    .ctrl_r = &.{ "\x12", "\x1b[114;5u", "\x1b[27;5;114~" },
    .ctrl_x = &.{ "\x18", "\x1b[120;5u", "\x1b[27;5;120~" },
    .alt_a = &.{ "\x1ba", "\x1b[97;3u", "\x1b[27;3;97~" },
    .alt_up = &.{ "\x1b[1;3A", "\x1b[1;3:1A" },
    .alt_down = &.{ "\x1b[1;3B", "\x1b[1;3:1B" },
    .up = &.{ "\x1b[A", "\x1bOA", "\x1b[1;1A" },
    .down = &.{ "\x1b[B", "\x1bOB", "\x1b[1;1B" },
    .left = &.{ "\x1b[D", "\x1bOD", "\x1b[1;1D" },
    .right = &.{ "\x1b[C", "\x1bOC", "\x1b[1;1C" },
    .tab = &.{ "\t", "\x1b[9u" },
    .shift_tab = &.{ "\x1b[Z", "\x1b[9;2u" },
    .shift_up = &.{ "\x1b[1;2A", "\x1b[1;2:1A" },
    .shift_down = &.{ "\x1b[1;2B", "\x1b[1;2:1B" },
    .page_up = &.{ "\x1b[5~", "\x1b[5;1~", "\x1b[5;2~" },
    .page_down = &.{ "\x1b[6~", "\x1b[6;1~", "\x1b[6;2~" },
    .home = &.{ "\x1b[H", "\x1bOH", "\x1b[1~", "\x1b[7~", "\x1b[1;1H" },
    .end = &.{ "\x1b[F", "\x1bOF", "\x1b[4~", "\x1b[8~", "\x1b[1;1F" },
    .ctrl_end = &.{ "\x1b[1;5F", "\x1b[4;5~" },
});
test "empty creation captures fresh effort and permission at admitted Enter or click before its worker runs" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |click| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
        try pin(home, "codex", "gpt-6-luna");
        _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .low }, .permission_mode = .{ .set = .ask } }, &.initFill(.configured));
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
        defer rig.close();
        _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .high }, .permission_mode = .{ .set = .bypass } }, &.initFill(.configured));
        if (click) try std.testing.expect(try rig.click(3, 0, width, 24) == null) else try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expect(rig.overview.state.creating());
        try std.testing.expectEqual(@as(usize, 1), rig.overview.job_count);
        const queued = &rig.overview.jobs[0].create;
        try std.testing.expectEqualStrings("gpt-6-luna", queued.binding.?.model.slice());
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), (try queued.settings).effort);
        try std.testing.expectEqual(@as(?protocol.PermissionMode, .bypass), (try queued.settings).permission);
        _ = try preferences.update(home, .{ .reasoning_effort = .{ .set = .xhigh }, .permission_mode = .{ .set = .ask } }, &.initFill(.configured));
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expect(try rig.click(3, 0, width, 24) == null);
        try std.testing.expectEqual(@as(usize, 1), rig.overview.job_count);
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), (try queued.settings).effort);
        try std.testing.expectEqual(@as(?protocol.PermissionMode, .bypass), (try queued.settings).permission);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
        try std.testing.expectEqualStrings("high", Seen.now.creation.reasoning_effort.?.slice());
        try std.testing.expectEqualStrings("bypass", Seen.now.creation.permission_mode.slice());
        try std.testing.expectEqualStrings("n3w5es", &Seen.now.conversed);
        const after = try preferences.load(home);
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .xhigh), after.reasoning_effort);
        try std.testing.expectEqual(@as(?protocol.PermissionMode, .ask), after.permission_mode);
    };
}

test "new and clear retire the old chat through the real lender and open empty Configure creations" {
    const Files = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    for ([_][]const u8{ "/new\r", "/clear\r" }) |keys| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
        Files.dir = tmp.dir;
        Files.count = 0;
        var ops = fake_operations;
        ops.open = openSession;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-5.5" }, ops, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        overview.hooks.scratch = Files.scratch;
        try std.testing.expect(try rig.next(.{ .open = .{ .reference = "k7m2qx".* } }) == null);
        defer {
            if (overview.app_session) |left| {
                left.frontend.?.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
            for (overview.retired.items) |retired| overview.disposeSession(retired.left);
            overview.retired.deinit(std.testing.allocator);
        }
        try std.testing.expect(try rig.settle() == null);
        const frontend = overview.app_session.?.frontend.?;
        frontend.reading.opening = false;
        frontend.poll_at = std.math.maxInt(i96);
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try app_events.send(&ctx, keys, overview.root.widget(), frontend.widget());
        try std.testing.expect(!ctx.quit);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqualStrings("n3w5es", &overview.opened);
        try std.testing.expectEqualStrings("n3w5es", overview.app_session.?.frontend.?.session);
        try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
        try std.testing.expect(overview.app_session.?.frontend.?.submission.intent == null);
    }
}

const EmptySessionOwner = struct {
    rig: *Rig = undefined,
    tmp: std.testing.TmpDir,
    path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    cancellation: client.Cancellation = .{},

    const references = [_]view.Reference{ "e2m4pt".*, "f3n5qw".* };
    const message = "Name the admitted empty chat";
    var rows: [references.len]protocol.SessionRow = undefined;
    var efforts: [references.len]?model_capability.ReasoningEffort = @splat(.high);
    var count: usize = 0;
    var generation: u64 = 0;
    var configurations: usize = 0;
    var scratch_dir: std.Io.Dir = undefined;
    var scratch_count: usize = 0;

    fn create() !*EmptySessionOwner {
        const fixture = try std.testing.allocator.create(EmptySessionOwner);
        errdefer std.testing.allocator.destroy(fixture);
        const tmp = std.testing.tmpDir(.{ .iterate = true });
        fixture.* = .{ .tmp = tmp };
        errdefer fixture.tmp.cleanup();
        try fixture.tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
        fixture.path_len = try fixture.tmp.dir.realPath(std.testing.io, &fixture.path);
        try pin(fixture.home(), "codex", "gpt-6-luna");
        count = 0;
        efforts = @splat(.high);
        generation = 0;
        configurations = 0;
        scratch_count = 0;
        scratch_dir = fixture.tmp.dir;
        try fixture.mount(null);
        errdefer fixture.closeRig();
        _ = try fixture.rig.overview.event(.{ .tick = test_now_s * 1000 });
        try std.testing.expect(try fixture.rig.settle() == null);
        return fixture;
    }

    fn home(self: *EmptySessionOwner) []const u8 {
        return self.path[0..self.path_len];
    }

    fn mount(self: *EmptySessionOwner, restoration: ?*const handoff.Payload) !void {
        var ops = fake_operations;
        ops.create = configureEmpty;
        ops.list = list;
        ops.first_line = firstMessageLine;
        ops.open = openSession;
        self.rig = try Rig.open(.{ .store = self.home(), .workspace = "/work", .home = self.home(), .directory = self.home(), .provider = "codex", .model = "gpt-6-luna", .restoration = restoration }, ops, &self.cancellation);
        self.rig.overview.hooks.scratch = scratch;
        self.rig.overview.hooks.configure = configure;
        try self.rig.overview.restoreRelaunch();
    }

    fn closeRig(self: *EmptySessionOwner) void {
        const overview = self.rig.overview;
        if (overview.app_session) |left| {
            left.frontend.?.stop();
            _ = left.frontend.?.settleDeparture(.detached, {});
            overview.disposeSession(left);
            overview.app_session = null;
        }
        for (overview.retired.items) |retired| overview.disposeSession(retired.left);
        overview.retired.deinit(std.testing.allocator);
        overview.retired = .empty;
        self.rig.close();
    }

    fn destroy(self: *EmptySessionOwner) void {
        self.closeRig();
        self.tmp.cleanup();
        std.testing.allocator.destroy(self);
    }

    fn scratch(init: std.process.Init) !std.Io.File {
        scratch_count += 1;
        var buffer: [32]u8 = undefined;
        return scratch_dir.createFile(init.io, try std.fmt.bufPrint(&buffer, "chat-scratch-{d}", .{scratch_count}), .{ .read = true });
    }

    fn configureEmpty(overview: *Self, requests: client.Requests, settings: configure_input.ConfigureInput, reply: *Reply) !void {
        try fake_operations.create(overview, requests, settings, reply);
        try std.testing.expect(count < rows.len);
        const row = &rows[count];
        row.* = .{ .created_at = test_now_s, .revision = 1, .work = .{ .state = .{ .idle = .{ .since = test_now_s } } } };
        try row.reference.set(&references[count]);
        try row.workspace.set(settings.workspace.value);
        try row.model.set(settings.model.value);
        reply.session = references[count];
        count += 1;
    }

    fn list(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
        generation += 1;
        page.* = .{ .count = count, .delta = .full, .since = .{ .instance = @splat(1), .generation = generation } };
        for (rows[0..count], page.rows[0..count]) |row, *listed| {
            listed.* = row;
            listed.read_version = page.since;
        }
        return null;
    }

    fn firstMessageLine(_: *Self, _: client.Requests, reference: []const u8, position: u64, buffer: []u8) !protocol_reply.ActivityPrefixReply {
        const row = canonical(reference);
        try std.testing.expectEqual(row.first_message.?.position, position);
        @memcpy(buffer[0..message.len], message);
        return .{ .line = buffer[0..message.len] };
    }

    fn canonical(reference: []const u8) *protocol.SessionRow {
        for (rows[0..count]) |*row| if (row.reference.eql(reference)) return row;
        unreachable;
    }

    fn configure(_: std.process.Init, _: client.ReadContext, _: []const u8, reference: []const u8, edit: @import("chat_info.zig").Edit) !bool {
        const row = canonical(reference);
        switch (edit) {
            .model => |model| try row.model.set(model),
            .effort => |effort| for (rows[0..count], 0..) |*candidate, at| {
                if (candidate == row) {
                    efforts[at] = effort;
                    break;
                }
            },
            else => return error.TestUnexpectedResult,
        }
        row.revision += 1;
        configurations += 1;
        return true;
    }

    fn frontend(self: *EmptySessionOwner) *SessionFrontend {
        return self.rig.overview.app_session.?.frontend.?;
    }

    fn tick(self: *EmptySessionOwner) !void {
        var ctx = self.rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try self.frontend().widget().handleEvent(&ctx, .tick);
    }

    fn completed(task: *ClientTask) bool {
        return task.completed();
    }

    fn wait(task: *ClientTask) !void {
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), task, completed);
    }

    fn answer(_: *anyopaque, _: *ClientTask) !void {}

    fn joinRead(self: *EmptySessionOwner) !void {
        try wait(&self.frontend().reader);
        const overview = self.rig.overview;
        const observation = overview.host_observation;
        overview.host_observation = .unavailable;
        defer overview.host_observation = observation;
        try self.tick();
        try std.testing.expect(self.frontend().reader.thread == null);
        self.frontend().poll_at = std.math.maxInt(i96);
    }

    fn readCurrent(self: *EmptySessionOwner) !void {
        const chat = self.frontend();
        const row = canonical(chat.session);
        try std.testing.expect(chat.reader.thread == null);
        const session = &chat.inspection.sessions[if (chat.inspection.status) |shown| ~shown else 0];
        @import("status_page.zig").sample(session);
        try session.session.set(row.reference.slice());
        try session.label.set("");
        try session.workspace.set(row.workspace.slice());
        try session.model.set(row.model.slice());
        var effort: ?model_capability.ReasoningEffort = null;
        for (rows[0..count], 0..) |*candidate, at| if (candidate == row) {
            effort = efforts[at];
        };
        session.effort = effort;
        session.instructions = false;
        session.archive_state = row.archive_state;
        const FeedPolicy = @import("feed_reads.zig").Policy(@import("feed_window.zig").Key);
        chat.job = .{
            .phase = .activity,
            .feed_page = FeedPolicy.request(.scan, .{ .opening = false, .now_ns = 0, .scan_due_ns = std.math.maxInt(i96), .at_end = true }),
            .open_status = true,
            .status_taken = session,
            .result = .{
                .status = true,
                .work = .{ .read_version = .{ .instance = @splat(1), .generation = generation }, .work = row.work.core() },
                .line = .{ .read = .{ .revision = row.revision, .end = row.end }, .model = row.model, .provider = .codex, .folder = row.workspace, .effort = effort },
                .hint = .absent,
                .cursor = .{ .position = row.end },
                .at_start = true,
                .at_end = true,
            },
        };
        chat.reading.phase = .activity;
        chat.reading.feed_read = .scan;
        chat.reading.opening = false;
        chat.screen.feed.at_start = true;
        chat.screen.feed.at_end = true;
        try chat.reader.start(std.testing.io, &chat.job, answer);
        try self.joinRead();
        chat.app_info.refresh();
    }

    fn refresh(self: *EmptySessionOwner) !void {
        const state = &self.rig.overview.state;
        _ = try self.rig.overview.event(.{ .tick = @max(state.now_ms + 1, state.next_list_ms) });
        try std.testing.expect(try self.rig.settle() == null);
    }

    fn openNew(self: *EmptySessionOwner) !view.Reference {
        try std.testing.expect(try self.rig.press("\x1b[H\r") == null);
        try std.testing.expect(try self.rig.settle() == null);
        const reference = self.rig.overview.app_session.?.session;
        try std.testing.expect(canonical(&reference).first_message == null);
        try self.expectVisible(&.{});
        try self.readCurrent();
        try self.expectVisible(&.{});
        try self.refresh();
        try std.testing.expect(self.rig.overview.root.session.?.eql(self.frontend().widget()));
        try std.testing.expectEqualStrings("", self.frontend().input.composition().bytes);
        try std.testing.expect(self.frontend().submission.intent == null);
        try self.expectSelectedName(reference, "New Session");
        return reference;
    }

    fn chooseModel(self: *EmptySessionOwner) !void {
        try self.chooseModelFrom("\t\r");
    }

    fn chooseModelFrom(self: *EmptySessionOwner, gesture: []const u8) !void {
        try std.testing.expect(try self.rig.press(gesture) == null);
        try std.testing.expect(self.frontend().app_info.model_choice.active);
        try std.testing.expect(try self.rig.press("gpt-5.5") == null);
        const choice = &self.frontend().app_info.model_choice;
        try std.testing.expectEqualStrings("gpt-5.5", choice.editor.text());
        var shown = try self.rig.shown(140, 40);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "gpt-5.5") != null);
        try std.testing.expect(try self.rig.press("\r") == null);
        try std.testing.expect(self.frontend().info_edit != null);
        try std.testing.expectEqualStrings("gpt-5.5", self.frontend().info_edit.?.model);
        self.frontend().poll_at = std.math.maxInt(i96);
        try self.tick();
        try self.joinRead();
        try std.testing.expectEqualStrings("gpt-5.5", canonical(self.frontend().session).model.slice());
        try self.readCurrent();
        try std.testing.expectEqualStrings("gpt-5.5", self.frontend().line.model.slice());
        try self.expectSelectedName(self.rig.overview.app_session.?.session, "New Session");
    }

    fn chooseEffort(self: *EmptySessionOwner) !void {
        try std.testing.expect(try self.rig.press("\t\t\r") == null);
        try std.testing.expect(self.frontend().app_info.standaloneField() == .effort);
        try std.testing.expect(self.frontend().app_info.panel.choice != null);
        try std.testing.expect(try self.rig.press("\x1b[A\r") == null);
        try std.testing.expectEqual(@import("chat_info.zig").Edit{ .effort = .medium }, self.frontend().info_edit.?);
        self.frontend().poll_at = std.math.maxInt(i96);
        try self.tick();
        try self.joinRead();
        try self.readCurrent();
        try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .medium), self.frontend().line.effort);
        try self.expectSelectedName(self.rig.overview.app_session.?.session, "New Session");
    }

    fn expectSelectedName(self: *EmptySessionOwner, reference: view.Reference, name: []const u8) !void {
        const overview = self.rig.overview;
        try self.expectVisible(&.{reference});
        try std.testing.expectEqual(reference, overview.state.conversing.?);
        try std.testing.expectEqual(@as(?usize, 0), view.Lines.named(&overview.state));
        for ([_]u16{ 46, 140 }) |width| {
            var shown = try self.rig.shown(width, 24);
            defer shown.deinit();
            const columns: u16 = if (width >= Root.split_at) Root.list_width else width;
            if (width < Root.split_at) {
                const frame = try overview.listWidget().draw(.{ .arena = shown.arena.allocator(), .cell_arena = shown.arena.allocator(), .min = .{}, .max = .{ .width = columns, .height = 24 }, .cell_size = .{} });
                const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = columns, .height = 24, .screen = &shown.screen };
                try frame.render(window, overview.widget());
            }
            var text: std.Io.Writer.Allocating = .init(shown.arena.allocator());
            for (0..24) |row| {
                for (0..columns) |col| try text.writer.writeAll(shown.screen.readCell(@intCast(col), @intCast(row)).?.char.grapheme);
                try text.writer.writeByte('\n');
            }
            try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, name, "New Session")) 2 else 1), std.mem.count(u8, text.written(), name));
            try std.testing.expect(std.mem.indexOf(u8, text.written(), &reference) == null);
            try std.testing.expectEqual(@as(?u32, 0), overview.app_sessions.selected);
            var bold_name = false;
            for ((try view.Lines.at(shown.arena.allocator(), &overview.state, 0, columns, overview.caps, 0)).?.segments) |segment| {
                if (std.mem.indexOf(u8, segment.text, name) != null) bold_name = segment.style.bold;
            }
            try std.testing.expect(bold_name);
        }
    }

    fn leave(self: *EmptySessionOwner) !void {
        // These canonical-row tests need actual retirement, not the wide
        // Esc-to-sidebar navigation tested by the input owner matrix.
        var narrow = try self.rig.shown(46, 24);
        defer narrow.deinit();
        try std.testing.expect(try self.rig.press("\x1b") == null);
        try std.testing.expect(self.rig.overview.app_session == null);
        try std.testing.expect(self.rig.overview.root.session == null);
        try std.testing.expect(self.rig.overview.state.conversing == null);
    }

    fn expectVisible(self: *EmptySessionOwner, expected: []const view.Reference) !void {
        const state = &self.rig.overview.state;
        try std.testing.expectEqual(expected.len, state.order.items.len);
        for (expected) |reference| {
            var found: usize = 0;
            for (state.order.items) |at| if (std.mem.eql(u8, &reference, &state.rows.items[at].reference)) {
                found += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), found);
        }
    }
};

test "sidebar New Session retires safely or refuses with focused usable chat" {
    const Held = enum { safe, unsafe_draft, submitting, not_started };
    for ([_]u16{ 100, 140 }) |width| for ([_]bool{ false, true }) |pointer| for (std.enums.values(Held)) |held| {
        const fixture = try EmptySessionOwner.create();
        defer fixture.destroy();
        const first = try fixture.openNew();
        const overview = fixture.rig.overview;
        const frontend = fixture.frontend();
        _ = frontend.input.append("Retained draft");
        if (held == .unsafe_draft) frontend.app_hooks.drafts = null;
        if (held == .submitting or held == .not_started) {
            frontend.submission.intent = .{ .message = frontend.input.submitText("pending message") };
            frontend.submission.state = if (held == .submitting) .submitting else .not_started;
        }
        {
            var shown = try fixture.rig.shown(width, 30);
            shown.deinit();
        }
        var ctx = fixture.rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try std.testing.expect(try overview.root.focusList(&ctx));
        if (pointer) {
            try std.testing.expect(try fixture.rig.click(4, 0, width, 30) == null);
        } else {
            try std.testing.expect(try fixture.rig.press("\x1b[H\r") == null);
        }
        if (held == .safe) {
            try std.testing.expect(overview.app_session == null);
            try std.testing.expect(try fixture.rig.settle() == null);
            try std.testing.expect(!overview.root.input.listFocused());
            try std.testing.expectEqual(@as(usize, 2), Seen.now.creates);
            try std.testing.expect(!std.mem.eql(u8, &first, fixture.frontend().session));
            try std.testing.expectEqualStrings("", fixture.frontend().input.composition().bytes);
            const draft = overview.session_drafts.take(std.testing.allocator, &first).?;
            defer draft.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("Retained draft", draft.snapshot.bytes);
        } else {
            try std.testing.expect(!overview.root.input.listFocused());
            try std.testing.expectEqualStrings(&first, fixture.frontend().session);
            try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
            try std.testing.expect(!overview.state.creating());
            var shown = try fixture.rig.shown(width, 30);
            defer shown.deinit();
            try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Esc returns") != null);
            if (held == .unsafe_draft) {
                try std.testing.expect(try fixture.rig.press("X") == null);
                try std.testing.expectEqualStrings("Retained draftX", fixture.frontend().input.composition().bytes);
            } else {
                try std.testing.expect(frontend.submission.intent != null);
                try std.testing.expectEqualStrings("pending message", try frontend.input.message(frontend.submission.intent.?.message));
            }
        }
    };
}

test "empty New Session owner opens blank then hides on leave without deleting its canonical row" {
    const fixture = try EmptySessionOwner.create();
    defer fixture.destroy();
    const reference = try fixture.openNew();
    try fixture.expectVisible(&.{reference});
    const empty = EmptySessionOwner.canonical(&reference);
    empty.label = .{};
    try empty.label.?.set("Renamed but still empty");
    try fixture.refresh();
    try fixture.expectSelectedName(reference, "New Session");
    try fixture.leave();
    try fixture.expectVisible(&.{});
    try fixture.refresh();
    try fixture.expectVisible(&.{});
    try std.testing.expectEqual(@as(usize, 1), EmptySessionOwner.count);
    try std.testing.expect(EmptySessionOwner.canonical(&reference).first_message == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.rig.overview.state.rows.items.len);
    for ([_]u16{ 46, 140 }) |width| {
        var shown = try fixture.rig.shown(width, 24);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), &reference) == null);
    }
}

test "empty New Session owner saves a real model choice then still hides on leave" {
    const fixture = try EmptySessionOwner.create();
    defer fixture.destroy();
    const reference = try fixture.openNew();
    try fixture.chooseModel();
    try std.testing.expectEqual(@as(usize, 1), EmptySessionOwner.configurations);
    try std.testing.expect(EmptySessionOwner.canonical(&reference).first_message == null);
    try fixture.leave();
    try fixture.refresh();
    try fixture.expectVisible(&.{});
    try std.testing.expectEqual(@as(usize, 1), EmptySessionOwner.count);
    try std.testing.expectEqualStrings("gpt-5.5", EmptySessionOwner.canonical(&reference).model.slice());
}

test "empty New Session owner saves a real effort choice without renaming its selected sidebar entry" {
    const fixture = try EmptySessionOwner.create();
    defer fixture.destroy();
    const reference = try fixture.openNew();
    try fixture.chooseEffort();
    try std.testing.expectEqual(@as(usize, 1), EmptySessionOwner.configurations);
    try std.testing.expect(EmptySessionOwner.canonical(&reference).first_message == null);
    try fixture.leave();
    try fixture.refresh();
    try fixture.expectVisible(&.{});
    try std.testing.expectEqual(@as(usize, 1), EmptySessionOwner.count);
}

test "empty New Session owner promotes the same row only after a canonical first Message admission" {
    const fixture = try EmptySessionOwner.create();
    defer fixture.destroy();
    const reference = try fixture.openNew();
    try std.testing.expect(try fixture.rig.press(EmptySessionOwner.message ++ "\r") == null);
    const chat = fixture.frontend();
    try std.testing.expect(chat.submission.intent != null);
    try std.testing.expectEqualStrings(EmptySessionOwner.message, try chat.input.message(chat.submission.intent.?.message));
    try std.testing.expect(EmptySessionOwner.canonical(&reference).first_message == null);
    try fixture.expectSelectedName(reference, "New Session");
    try EmptySessionOwner.wait(&chat.submission.task);
    try std.testing.expect(chat.submission.join() == .failed);
    try std.testing.expect(chat.submission.captured != null);
    chat.submission.reply = .{
        .status = 200,
        .context = .{ .kind = .message },
        .target = .{ .message = .{ .bytes = EmptySessionOwner.message.len, .digest = protocol.contentDigest(EmptySessionOwner.message) } },
        .answer = .{ .replayed = false, .result = .{ .accepted = .{ .message = .{ .admission = 37 } } } },
    };
    try chat.submission.task.start(std.testing.io, &chat.submission, EmptySessionOwner.answer);
    try EmptySessionOwner.wait(&chat.submission.task);
    const observation = fixture.rig.overview.host_observation;
    fixture.rig.overview.host_observation = .unavailable;
    try fixture.tick();
    fixture.rig.overview.host_observation = observation;
    chat.poll_at = std.math.maxInt(i96);
    try std.testing.expect(chat.submission.intent == null);
    try fixture.refresh();
    try std.testing.expect(fixture.rig.overview.state.rows.items[0].first == null);
    try fixture.expectSelectedName(reference, "New Session");
    const row = EmptySessionOwner.canonical(&reference);
    row.first_message = .{ .position = 2, .admission = 37, .admitted_at = test_now_s, .sender = null, .content = .{ .length = EmptySessionOwner.message.len, .digest = protocol.contentDigest(EmptySessionOwner.message) } };
    row.end = 2;
    row.revision += 1;
    row.peers.from_person_at = test_now_s;
    try fixture.refresh();
    try fixture.expectSelectedName(reference, EmptySessionOwner.message);
    try fixture.leave();
    try fixture.expectVisible(&.{reference});
    try std.testing.expectEqual(@as(usize, 1), EmptySessionOwner.count);
    try std.testing.expectEqual(@as(u64, 37), fixture.rig.overview.state.rows.items[0].first.?.admission);
    for ([_]u16{ 46, 140 }) |width| {
        var shown = try fixture.rig.shown(width, 24);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), EmptySessionOwner.message) != null);
    }
}

test "empty New Session owner keeps two distinct configured rows but neither abandoned row in overview" {
    const fixture = try EmptySessionOwner.create();
    defer fixture.destroy();
    const first = try fixture.openNew();
    try fixture.leave();
    try fixture.expectVisible(&.{});
    const second = try fixture.openNew();
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    try fixture.expectVisible(&.{second});
    try fixture.leave();
    try fixture.refresh();
    try fixture.expectVisible(&.{});
    try std.testing.expectEqual(@as(usize, 2), EmptySessionOwner.count);
    try std.testing.expectEqual(@as(usize, 2), fixture.rig.overview.state.rows.items.len);
    try std.testing.expectEqual(@as(usize, 2), Seen.now.creates);
    try std.testing.expect(EmptySessionOwner.canonical(&first).first_message == null);
    try std.testing.expect(EmptySessionOwner.canonical(&second).first_message == null);
}

test "empty New Session owner upgrade handoff preserves model draft and caret then hides on leave" {
    const fixture = try EmptySessionOwner.create();
    defer fixture.destroy();
    const reference = try fixture.openNew();
    try fixture.chooseModel();
    try std.testing.expect(try fixture.rig.press("Unsent café\x1b[D\x1b[D") == null);
    const cursor = fixture.frontend().input.composition().cursor;
    fixture.rig.overview.relaunch_build = try std.testing.allocator.dupe(u8, "/published/build");
    const request = try fixture.rig.overview.makeRelaunch(fixture.rig.overview.app_session);
    defer request.deinit(std.testing.allocator);
    var parsed = try handoff.decode(std.testing.allocator, request.handoff, fixture.home());
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&reference, parsed.value.open.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.drafts.len);
    try std.testing.expectEqualStrings("Unsent café", parsed.value.drafts[0].snapshot.bytes);
    try std.testing.expectEqual(cursor, parsed.value.drafts[0].snapshot.cursor);
    fixture.closeRig();
    try fixture.mount(&parsed.value);
    try std.testing.expect(try fixture.rig.next(.{ .open = .{ .reference = fixture.rig.overview.options.open.? } }) == null);
    try fixture.readCurrent();
    try fixture.refresh();
    try fixture.expectVisible(&.{reference});
    try std.testing.expectEqualStrings("gpt-5.5", fixture.frontend().line.model.slice());
    try std.testing.expectEqualStrings("Unsent café", fixture.frontend().input.composition().bytes);
    try std.testing.expectEqual(cursor, fixture.frontend().input.composition().cursor);
    try std.testing.expect(fixture.frontend().submission.intent == null);
    try std.testing.expect(EmptySessionOwner.canonical(&reference).first_message == null);
    try std.testing.expect(try fixture.rig.press("\x05\x15") == null);
    try std.testing.expectEqualStrings("", fixture.frontend().input.composition().bytes);
    try fixture.leave();
    try fixture.refresh();
    try fixture.expectVisible(&.{});
    try std.testing.expectEqual(@as(usize, 1), EmptySessionOwner.count);
}

test "Overview forwards captured covered pane and paste without rereading newer Root state" {
    const rig = try openOverview();
    defer rig.close();
    const overview = rig.overview;
    const text = "Keep this notice";
    overview.state.notice = .{ .colour = .normal, .len = text.len };
    @memcpy(overview.state.notice.?.bytes[0..text.len], text);
    const enter: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.enter } };
    const exit: vxfw.Event = .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } };
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);

    overview.root.input.layer = .main;
    try appKey(overview, &ctx, enter, .{ .under = .settings, .pasted = false });
    try std.testing.expectEqual(@as(usize, 0), overview.job_count);
    try std.testing.expectEqual(@as(usize, 0), overview.state.request_count);
    try std.testing.expectEqualStrings(text, overview.state.notice.?.bytes[0..overview.state.notice.?.len]);

    overview.root.input.pasting = false;
    for ([_]vxfw.Event{ enter, exit }) |input| {
        try appKey(overview, &ctx, input, .{ .under = .main, .pasted = true });
        try std.testing.expect(!ctx.quit);
        try std.testing.expectEqual(@as(usize, 0), overview.job_count);
        try std.testing.expectEqualStrings(text, overview.state.notice.?.bytes[0..overview.state.notice.?.len]);
    }

    overview.root.input.layer = .settings;
    overview.root.input.pasting = true;
    try appKey(overview, &ctx, enter, .{ .under = .main, .pasted = false });
    try std.testing.expect(overview.state.creating());
    try std.testing.expectEqual(@as(usize, 1), overview.job_count);
    try std.testing.expect(overview.root.input.layer.settingsOpen());

    overview.root.input.layer = .main;
    try appKey(overview, &ctx, exit, .{ .under = .settings, .pasted = false });
    try std.testing.expect(ctx.quit);
    try std.testing.expect(overview.state.creating());
    try std.testing.expectEqual(@as(usize, 1), overview.job_count);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
}

test "typed model and footer picker configure the same Session owner and show Current in the footer" {
    const Skills = struct {
        fn read(_: client.ReadContext, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !@import("skill_suggestions.zig").Page {
            return .{ .entries = &.{}, .total = 0 };
        }
    };
    for ([_][]const u8{ "/model\r", "\t\r" }) |gesture| {
        const fixture = try EmptySessionOwner.create();
        defer fixture.destroy();
        const reference = try fixture.openNew();
        fixture.frontend().skill_read = Skills.read;
        try fixture.chooseModelFrom(gesture);
        try std.testing.expect(try fixture.rig.press("x\x7f") == null);
        try std.testing.expectEqual(@as(usize, 1), EmptySessionOwner.configurations);
        try std.testing.expectEqual(reference, fixture.rig.overview.app_session.?.session);
        try std.testing.expect(fixture.frontend().submission.intent == null);
        for ([_]u16{ 46, 140 }) |width| {
            var shown = try fixture.rig.shown(width, 30);
            defer shown.deinit();
            const text = try shown.text();
            const footer = text[std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n').? + 1 ..];
            try std.testing.expect(std.mem.indexOf(u8, footer, "gpt-5.5") != null);
        }
    }
}

// Upstream #1396 drops unknown terminal sequences rather than synthesizing an
// invalid-key event. Overview has no draft to recover: those bytes authorize
// nothing, and the next ordinary New Session still opens the real blank chat.
test "unknown terminal sequences leave noinput overview available to create an empty Session" {
    for ([_][]const u8{ "\x1b[1114112u", "\x1b[27;3;1114112~" }) |sequence| {
        const fixture = try EmptySessionOwner.create();
        defer fixture.destroy();
        var bytes: [64]u8 = undefined;
        try std.testing.expect(try fixture.rig.press(try std.fmt.bufPrint(&bytes, "one{s}two", .{sequence})) == null);
        try std.testing.expect(!fixture.rig.overview.state.creating());
        try std.testing.expectEqual(@as(usize, 0), fixture.rig.overview.state.request_count);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
        try std.testing.expect(fixture.rig.overview.state.notice == null);
        const reference = try fixture.openNew();
        try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
        try std.testing.expectEqualStrings("", fixture.frontend().input.composition().bytes);
        try std.testing.expect(fixture.frontend().submission.intent == null);
        try std.testing.expect(EmptySessionOwner.canonical(&reference).first_message == null);
        try fixture.leave();
        try fixture.expectVisible(&.{});
    }
}

test "App list selection consumes the core projection through arrivals covered Settings peer switches and departure" {
    const Check = struct {
        fn draw(rig: *Rig) !void {
            const overview = rig.overview;
            for ([_]u16{ 46, 140 }) |width| {
                var shown = try rig.shown(width, 24);
                defer shown.deinit();
                if (!overview.root.listVisible()) _ = try overview.listWidget().draw(.{ .arena = shown.arena.allocator(), .cell_arena = shown.arena.allocator(), .min = .{}, .max = .{ .width = Root.list_width, .height = 24 }, .cell_size = .{} });
                const expected: ?u32 = if (view.Lines.highlighted(&overview.state, overview.root.input.listFocused() or overview.root.session == null)) |line| @intCast(line) else null;
                try std.testing.expectEqual(expected, overview.app_sessions.selected);
            }
        }
    };
    const fixture = try EmptySessionOwner.create();
    defer fixture.destroy();
    const rig = fixture.rig;
    const overview = rig.overview;
    try Check.draw(rig);

    try std.testing.expect(try rig.press("\x1b[H\r") == null);
    try std.testing.expect(try rig.settle() == null);
    const first = overview.app_session.?.session;
    try std.testing.expect(view.Lines.named(&overview.state) == null);
    try Check.draw(rig);
    try fixture.readCurrent();
    try Check.draw(rig);
    try fixture.refresh();
    try Check.draw(rig);
    try fixture.leave();
    try Check.draw(rig);

    const second = try fixture.openNew();
    for (EmptySessionOwner.rows[0..EmptySessionOwner.count]) |*row| {
        row.first_message = .{ .position = 1, .admission = 37, .admitted_at = test_now_s, .sender = null, .content = .{ .length = EmptySessionOwner.message.len, .digest = protocol.contentDigest(EmptySessionOwner.message) } };
        row.end = 1;
        row.revision += 1;
        row.peers.from_person_at = test_now_s;
    }
    try fixture.refresh();
    try Check.draw(rig);
    try std.testing.expect(try rig.next(.{ .open = .{ .reference = first } }) == null);
    try std.testing.expectEqual(first, overview.state.conversing.?);
    try fixture.readCurrent();
    try Check.draw(rig);

    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try overview.root.openSettings(&ctx);
    try std.testing.expect(overview.root.input.layer.settingsOpen());
    try Check.draw(rig);
    try std.testing.expect(try rig.next(.{ .open = .{ .reference = second } }) == null);
    try std.testing.expectEqual(second, overview.state.conversing.?);
    try std.testing.expect(!overview.root.input.layer.settingsOpen());
    try fixture.readCurrent();
    try Check.draw(rig);

    // A followed peer returns once to its origin, then to the overview.
    var narrow = try rig.shown(46, 24);
    defer narrow.deinit();
    try std.testing.expect(try rig.press("\x1b") == null);
    try std.testing.expectEqual(first, overview.state.conversing.?);
    try fixture.readCurrent();
    try Check.draw(rig);
    try fixture.leave();
    try std.testing.expect(overview.state.conversing == null);
    try Check.draw(rig);
}

test "creation snapshot reads one owned preference pair with explicit null binding absent home and errors" {
    const Load = struct {
        var calls: usize = 0;
        var fail: bool = false;
        var values: preferences.Values = .{ .reasoning_effort = .high, .permission_mode = .bypass };
        fn read(home: []const u8) !preferences.Values {
            calls += 1;
            try std.testing.expectEqualStrings("/snapshot-home", home);
            if (fail) return error.CreationPreferencesUnavailable;
            return values;
        }
    };
    Load.calls = 0;
    Load.fail = false;
    Load.values = .{ .reasoning_effort = .high, .permission_mode = .bypass };
    const binding = view.Default.of("codex", "gpt-6-luna").?;
    const captured = CreationSnapshot.read(binding, "/snapshot-home", true, Load.read);
    try std.testing.expectEqual(@as(usize, 1), Load.calls);
    Load.values = .{ .reasoning_effort = .low, .permission_mode = .ask };
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), (try captured.settings).effort);
    try std.testing.expectEqual(@as(?protocol.PermissionMode, .bypass), (try captured.settings).permission);

    const explicit = CreationSnapshot.read(binding, "/snapshot-home", false, Load.read);
    try std.testing.expectEqual(@as(usize, 2), Load.calls);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, null), (try explicit.settings).effort);
    try std.testing.expectEqual(@as(?protocol.PermissionMode, .ask), (try explicit.settings).permission);
    const unbound = CreationSnapshot.read(null, "/snapshot-home", true, Load.read);
    try std.testing.expectEqual(@as(usize, 3), Load.calls);
    try std.testing.expect(unbound.binding == null);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, null), (try unbound.settings).effort);
    try std.testing.expectEqual(@as(?protocol.PermissionMode, .ask), (try unbound.settings).permission);

    const absent = CreationSnapshot.read(binding, "", true, Load.read);
    try std.testing.expectEqual(@as(usize, 3), Load.calls);
    try std.testing.expectEqual(CreationSettings{}, try absent.settings);
    Load.fail = true;
    const failed_snapshot = CreationSnapshot.read(binding, "/snapshot-home", true, Load.read);
    try std.testing.expectEqual(@as(usize, 4), Load.calls);
    try std.testing.expectError(error.CreationPreferencesUnavailable, failed_snapshot.settings);
    const explicit_failed = CreationSnapshot.read(binding, "/snapshot-home", false, Load.read);
    try std.testing.expectEqual(@as(usize, 5), Load.calls);
    try std.testing.expectError(error.CreationPreferencesUnavailable, explicit_failed.settings);

    const rig = try openOverview();
    defer rig.close();
    var buffer: [20]u8 = undefined;
    const input = try rig.overview.creationInput(&unbound, &buffer);
    try std.testing.expect(input.require_model);
    try std.testing.expect(!input.provider.present and !input.model.present);
    try std.testing.expectEqualStrings("ask", input.permission_mode.value);
    const defaults = try rig.overview.creationInput(&absent, &buffer);
    try std.testing.expectEqualStrings(product_defaults.permission_mode, defaults.permission_mode.value);
    try std.testing.expectError(error.CreationPreferencesUnavailable, rig.overview.creationInput(&failed_snapshot, &buffer));
    try std.testing.expectEqual(@as(usize, 5), Load.calls);
}

test "creation preference read failure is retained through repair and ordinary refusal then retry" {
    const File = struct {
        fn write(dir: std.Io.Dir, bytes: []const u8) !void {
            const file = try dir.createFile(std.testing.io, ".config/rui/preferences", .{ .permissions = .fromMode(0o600) });
            defer file.close(std.testing.io);
            try file.writePositionalAll(std.testing.io, bytes, 0);
        }
        const valid = "version=4\nstore=\nprovider=codex\nmodel=gpt-6-luna\nnotifications=on\nreasoning_effort=high\npermission_mode=bypass\n";
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    try pin(home, "codex", "gpt-6-luna");
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = home, .directory = "/requests", .provider = "codex", .model = "gpt-6-luna" }, fake_operations, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    try File.write(tmp.dir, "version=unreadable\n");
    try std.testing.expect(try rig.next(try overview.event(.{ .open = "k7m2qx".* })) == null);
    try std.testing.expect(try rig.press("unknown\x1b[1114112u") == null);
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    const enter: vxfw.Event = .{ .key_press = .{ .codepoint = vaxis.Key.enter } };
    try appKey(overview, &ctx, enter, .{ .under = .settings, .pasted = false });
    try appKey(overview, &ctx, enter, .{ .under = .main, .pasted = true });
    for (overview.jobs[0..overview.job_count]) |job| try std.testing.expect(job != .create);
    try std.testing.expectEqual(@as(usize, 0), overview.state.request_count);
    try std.testing.expect(try rig.settle() == null);
    const opened = Seen.now.conversations;

    try std.testing.expect(try rig.press("\x1b[H\r") == null);
    try std.testing.expectEqual(@as(usize, 1), overview.job_count);
    try std.testing.expectError(error.UnsupportedPreferencesVersion, overview.jobs[0].create.settings);
    try File.write(tmp.dir, File.valid);
    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expect(try rig.click(3, 0, 140, 24) == null);
    try std.testing.expectEqual(@as(usize, 1), overview.job_count);
    try std.testing.expectError(error.UnsupportedPreferencesVersion, overview.jobs[0].create.settings);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
    try std.testing.expectEqual(opened, Seen.now.conversations);
    try std.testing.expect(!overview.state.creating());
    try std.testing.expectEqual(@as(usize, 0), overview.state.request_count);
    try std.testing.expect(std.mem.indexOf(u8, overview.state.notice.?.text(), "Not created") != null);
    try std.testing.expect(std.mem.indexOf(u8, overview.state.notice.?.text(), "UnsupportedPreferencesVersion") != null);

    try std.testing.expect(try rig.press("\r") == null);
    try std.testing.expectEqual(@as(?model_capability.ReasoningEffort, .high), (try overview.jobs[0].create.settings).effort);
    try std.testing.expectEqual(@as(?protocol.PermissionMode, .bypass), (try overview.jobs[0].create.settings).permission);
    try std.testing.expect(try rig.settle() == null);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
    try std.testing.expectEqualStrings("high", Seen.now.creation.reasoning_effort.?.slice());
    try std.testing.expectEqualStrings("bypass", Seen.now.creation.permission_mode.slice());
}

test "App overview Tab projection is list then Settings and Settings Enter uses the drawn identity" {
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        rig.overview.state.launch = .done;
        var shown = try rig.shown(width, 30);
        defer shown.deinit();
        try std.testing.expectEqualSlices(@import("app_input.zig").Target, &.{ .list, .settings_row }, rig.overview.root.focus_frame.slice());
        try std.testing.expect(try rig.press("\t") == null);
        try std.testing.expectEqual(@import("app_input.zig").Target.settings_row, @import("app_input.zig").currentFocus(rig.overview.root.input));
        try std.testing.expect(try rig.press("\x1b[Z") == null);
        try std.testing.expect(rig.overview.root.input.listFocused());
        try std.testing.expect(try rig.press("\t\r") == null);
        try std.testing.expect(rig.overview.root.input.layer.settingsOpen());
        _ = try rig.overview.root.widget().draw(.{ .arena = shown.arena.allocator(), .cell_arena = shown.arena.allocator(), .min = .{}, .max = .{ .width = width, .height = 30 }, .cell_size = .{} });
        const selected = rig.overview.root.settings_page.panel.selected;
        try std.testing.expect(try rig.press("\t") == null);
        // This harness's focused widget is the overview; Root passing panel keys
        // is separately connected through the page's native handler below.
        var events = rig.context();
        defer events.cmds.deinit(std.testing.allocator);
        try rig.overview.root.settings_page.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.tab } });
        try std.testing.expect(selected != rig.overview.root.settings_page.panel.selected);
    }
}

test "App overview browse coalesces a rapid batch to one feed-open boundary and keeps wide list focus" {
    const Read = struct {
        const chat: vxfw.Text = .{ .text = "Selected chat feed" };
        fn open(overview: *Self, ctx: *vxfw.EventContext) !void {
            // This is the existing production open/feed-read boundary. No
            // skipped selection may reach it; no per-selection feeds are cached.
            Seen.now.conversations += 1;
            Seen.now.conversed = overview.opened;
            try overview.root.openSession(ctx, chat.widget(), null);
        }
    };
    for ([_]u16{ 46, 140 }) |width| {
        const rig = try openListed();
        defer rig.close();
        const overview = rig.overview;
        overview.ops.open = Read.open;
        overview.state.selected = .{ .session = overview.state.rows.items[overview.state.order.items[0]].reference };
        var shown = try rig.shown(width, 30);
        defer shown.deinit();
        Seen.now.conversations = 0;
        try std.testing.expect(try rig.press("\x1b[B\x1b[B\x1b[B") == null);
        const last = overview.state.selected.session;
        try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
        var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = shown.arena.allocator(), .cmds = .empty };
        try overview.root.widget().handleEvent(&events, .tick);
        try std.testing.expectEqual(@as(usize, @intFromBool(width == 140)), Seen.now.conversations);
        if (width == 140) {
            try std.testing.expectEqualStrings(&last, &Seen.now.conversed);
            try std.testing.expect(overview.root.input.listFocused());
            try std.testing.expect(overview.root.session.?.eql(Read.chat.widget()));
        } else try std.testing.expect(overview.root.session == null);
        // A repeated tick with no new move never reopens/re-reads.
        try overview.root.widget().handleEvent(&events, .tick);
        try std.testing.expectEqual(@as(usize, @intFromBool(width == 140)), Seen.now.conversations);
    }
}

test "App overview paste shapes after chat close cannot create or retain an editor paste" {
    for ([_]u16{ 46, 140 }) |width| for ([_]bool{ false, true }) |list_focused| for ([_][]const u8{ "", "\n", "text" }) |paste| {
        const rig = try openOverview();
        defer rig.close();
        var events = rig.context();
        defer events.cmds.deinit(std.testing.allocator);
        try rig.overview.root.closeSession(&events);
        try std.testing.expect(rig.overview.root.input.listFocused());
        rig.overview.root.input.area = if (list_focused) .list else .main;
        var shown = try rig.shown(width, 30);
        defer shown.deinit();
        const creates = Seen.now.creates;
        const opens = Seen.now.conversations;
        try std.testing.expect(try rig.press("\x1b[200~") == null);
        try std.testing.expect(try rig.press(paste) == null);
        try std.testing.expect(try rig.press("\x1b[201~") == null);
        try std.testing.expect(!rig.overview.root.input.pasting);
        try std.testing.expect(try rig.press("\x1b[DX") == null);
        try std.testing.expectEqual(creates, Seen.now.creates);
        try std.testing.expectEqual(opens, Seen.now.conversations);
        try std.testing.expect(!rig.overview.state.creating());
        try std.testing.expect(rig.overview.root.session == null);
        try std.testing.expect(try rig.press("\r") == null);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(creates + 1, Seen.now.creates);
    };
}

test "App overview list activation resumes the open chat without closing its presentation" {
    const Presentation = struct {
        var closes: usize = 0;
        fn close(_: *anyopaque) void {
            closes += 1;
        }
    };
    for ([_][]const u8{ "\r", "\x1b[C" }) |key| {
        const rig = try openListed();
        defer rig.close();
        const reference = shownRow(rig, 2);
        const chat: vxfw.Text = .{ .text = "Chat" };
        rig.overview.root.session = chat.widget();
        defer rig.overview.root.session = null;
        rig.overview.root.size = .{ .width = 140, .height = 40 };
        _ = try rig.overview.event(.{ .conversation = reference });
        rig.overview.root.main_presentation = .{ .context = rig, .close = Presentation.close };
        Presentation.closes = 0;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try std.testing.expect(try rig.overview.root.focusList(&ctx));
        const opens = Seen.now.conversations;
        try std.testing.expect(try rig.press(key) == null);
        try std.testing.expect(!rig.overview.root.input.listFocused());
        try std.testing.expectEqual(@as(usize, 0), Presentation.closes);
        try std.testing.expectEqual(opens, Seen.now.conversations);
    }
}

test "Overview Settings live memory frame uses quiet role in day and night" {
    const rig = try openListed();
    defer rig.close();
    for ([_]view.Caps{ .{}, .{ .background = .{ 255, 255, 255 } } }) |caps| {
        rig.overview.caps = caps;
        var before = try rig.shown(80, 24);
        defer before.deinit();
        if (rig.overview.state.memory == null) try std.testing.expect(std.mem.indexOf(u8, try before.text(), "38 MB") == null);
        _ = try rig.overview.event(.{ .memory = .{ .rui = 38 * view.mib, .tools = 120 * view.mib } });
        var shown = try rig.shown(80, 24);
        defer shown.deinit();
        const row: u16 = for (0..24) |y| {
            if (std.mem.startsWith(u8, try shown.line(@intCast(y)), "     Settings")) break @intCast(y);
        } else return error.TestExpectedSettingsRow;
        const text = try shown.line(row + 1);
        const memory = std.mem.indexOf(u8, text, "38 MB") orelse return error.TestExpectedMemory;
        const expected = @import("widget_style.zig").of(caps, .{ .colour = .quiet });
        for (memory..memory + "38 MB".len) |column| try std.testing.expectEqual(expected, shown.screen.readCell(@intCast(column), row + 1).?.style);
        try std.testing.expectEqual(rig.overview.state.memory, memoryValue(rig.overview));
    }
}

test "App settings live memory follows Overview readings while chat info stays chat-only" {
    const rig = try openListed();
    defer rig.close();
    const overview = rig.overview;
    var ctx = rig.context();
    defer ctx.cmds.deinit(std.testing.allocator);
    try appClick(overview, &ctx, .settings);
    try std.testing.expect(overview.root.input.layer.settingsOpen());
    const backend = overview.root.settings_page.backend.?;
    const read_memory = backend.memory orelse return error.TestExpectedMemoryReader;
    try std.testing.expectEqual(@as(?view.Memory, null), read_memory(backend.context));
    var before = try rig.shown(140, 24);
    defer before.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try before.text(), "Memory") == null);
    const Case = struct { memory: view.Memory, text: []const u8 };
    for ([_]Case{
        .{ .memory = .{ .rui = 38 * view.mib, .tools = 120 * view.mib }, .text = "Memory          rui 38 MB · tools 120 MB" },
        .{ .memory = .{ .rui = 1024 * view.mib, .tools = null }, .text = "Memory          rui 1.0 GB" },
    }) |case| {
        _ = try overview.event(.{ .memory = case.memory });
        try std.testing.expectEqual(@as(?view.Memory, case.memory), read_memory(backend.context));
        var shown = try rig.shown(140, 24);
        defer shown.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try shown.text(), case.text) != null);
    }
    try std.testing.expect(!@hasField(@import("chat_info.zig").Backend, "memory"));
    try std.testing.expect(!@hasField(SessionFrontend.Lender, "memory"));
}

test "Option session navigation switches immediately and restores each sessions draft and input focus" {
    const Files = struct {
        var dir: std.Io.Dir = undefined;
        var count: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            count += 1;
            return dir.createFile(init.io, &.{'a' + count}, .{ .read = true });
        }
    };
    for ([_]u16{ 46, 140 }) |width| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        Files.dir = tmp.dir;
        Files.count = 0;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
        defer rig.close();
        const overview = rig.overview;
        Seen.now.listed = 2;
        _ = try overview.event(.{ .tick = test_now_s * 1000 });
        _ = try rig.settle();
        overview.ops.open = openSession;
        overview.hooks.scratch = Files.scratch;
        const first = overview.state.rows.items[overview.state.order.items[0]].reference;
        const second = overview.state.rows.items[overview.state.order.items[1]].reference;
        _ = try rig.next(.{ .open = .{ .reference = first } });
        defer {
            if (overview.app_session) |left| {
                left.frontend.?.stop();
                overview.disposeSession(left);
                overview.app_session = null;
            }
            for (overview.retired.items) |retired| overview.disposeSession(retired.left);
            overview.retired.deinit(std.testing.allocator);
        }
        overview.root.size = .{ .width = width, .height = 30 };
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        for ([_]struct { text: []const u8, chord: []const u8, destination: view.Reference, restored: []const u8, cursor: usize }{
            .{ .text = "first α\x1b[D", .chord = "\x1b[1;3B", .destination = second, .restored = "", .cursor = 0 },
            .{ .text = "second\x1b[D", .chord = "\x1b[1;3A", .destination = first, .restored = "first α", .cursor = 6 },
            .{ .text = "", .chord = "\x1b[1;3B", .destination = second, .restored = "second", .cursor = 5 },
        }) |case| {
            const frontend = overview.app_session.?.frontend.?;
            frontend.reading.opening = false;
            frontend.poll_at = std.math.maxInt(i96);
            try app_events.send(&ctx, case.text, overview.root.widget(), frontend.widget());
            ctx.cmds.clearRetainingCapacity();
            try app_events.send(&ctx, case.chord, overview.root.widget(), frontend.widget());
            const destination = overview.app_session.?.frontend.?;
            try std.testing.expectEqualStrings(&case.destination, destination.session);
            try std.testing.expectEqualStrings(case.restored, destination.input.composition().bytes);
            try std.testing.expectEqual(case.cursor, destination.input.composition().cursor);
            try std.testing.expect(!overview.root.input.listFocused());
            var focused = false;
            for (ctx.cmds.items) |command| if (command == .request_focus and command.request_focus.eql(destination.widget())) {
                focused = true;
            };
            try std.testing.expect(focused);
            try std.testing.expect(!ctx.quit);
            try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
        }
    }
}

test "Session pin worker retains captured target and settles organization without opening it" {
    const rig = try openListed();
    defer rig.close();
    const overview = rig.overview;
    const selected = overview.state.selected;
    const opens = Seen.now.conversations;
    for ([_]bool{ true, false }) |pinned| {
        const request: view.PinRequest = .{ .reference = "b4n8wd".*, .pinned = pinned };
        const result = try overview.eventResult(.{ .clicked = .{ .target = .{ .pin = request } } });
        try std.testing.expectEqual(view.IntentAdmission.admitted, result.intent_admission);
        try std.testing.expectEqual(@as(?Next, null), result.next);
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqualStrings(&request.reference, &Seen.now.pin_session);
        try std.testing.expectEqual(pinned, Seen.now.pin_requested);
        try std.testing.expectEqual(selected, overview.state.selected);
        try std.testing.expectEqual(opens, Seen.now.conversations);
        try std.testing.expect(overview.state.find(request.reference).?.pin_order == null);
    }
    try std.testing.expectEqual(@as(usize, 2), Seen.now.pins);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.archives);
}

test "Session pin drawn Root gestures preserve composer focus draft and caret across session and controls" {
    const Find = struct {
        fn origin(surface: vxfw.Surface, target: vxfw.Widget, at: vxfw.RelativePoint) ?vxfw.RelativePoint {
            if (surface.widget.eql(target)) return at;
            for (surface.children) |child| {
                if (origin(child.surface, target, .{ .row = at.row + child.origin.row, .col = at.col + child.origin.col })) |found| return found;
            }
            return null;
        }
    };
    for ([_]bool{ false, true }) |alt| {
        const fixture = try EmptySessionOwner.create();
        defer fixture.destroy();
        const reference = try fixture.openNew();
        try fixture.chooseModel();
        const rig = fixture.rig;
        const overview = rig.overview;
        const frontend = fixture.frontend();
        try std.testing.expect(try rig.press("Unsent café\x1b[D\x1b[D") == null);
        const cursor = frontend.input.composition().cursor;
        const composer = frontend.app_input.composer.widget();
        try std.testing.expect(rig.last_focus.?.eql(composer));
        const selection = overview.state.selected;
        const conversations = Seen.now.conversations;
        const creations = Seen.now.creates;
        const Target = enum { settings, session };
        for ([_]Target{ .settings, .session }) |target| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const frame = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
            var point = Find.origin(frame, switch (target) {
                .settings => overview.app_settings_line.widget(),
                .session => overview.app_sessions.widget(),
            }, .{ .row = 0, .col = 0 }) orelse return error.TestExpectedDrawnTarget;
            point.col += 4;
            switch (target) {
                .settings => point.row += 1,
                .session => {
                    point.row += for (overview.app_sessions.shown_at) |span| {
                        if (span.target) |meaning| {
                            if (meaning == .open and std.mem.eql(u8, &meaning.open, &reference)) break span.row;
                        }
                    } else return error.TestExpectedDrawnSession;
                },
            }
            var ctx = rig.context();
            defer ctx.cmds.deinit(ctx.alloc);
            const pins = Seen.now.pins;
            var mouse: vaxis.Mouse = .{ .col = @intCast(point.col), .row = @intCast(point.row), .button = if (alt) .left else .right, .type = .press, .mods = .{ .alt = alt } };
            try app_events.mouse(&ctx, frame, mouse);
            mouse.type = .release;
            try app_events.mouse(&ctx, frame, mouse);
            for (ctx.cmds.items) |cmd| switch (cmd) {
                .set_mouse_shape => {},
                else => return error.TestUnexpectedCommand,
            };
            try std.testing.expect(!ctx.quit);
            try std.testing.expect(!overview.root.input.listFocused());
            try std.testing.expect(!overview.root.input.layer.settingsOpen());
            try std.testing.expect(overview.root.session.?.eql(frontend.widget()));
            try std.testing.expectEqual(selection, overview.state.selected);
            try std.testing.expectEqualStrings("Unsent café", frontend.input.composition().bytes);
            try std.testing.expectEqual(cursor, frontend.input.composition().cursor);
            try std.testing.expect(frontend.submission.intent == null);
            try std.testing.expect(try rig.settle() == null);
            try std.testing.expect(rig.last_focus.?.eql(composer));
            try std.testing.expectEqual(conversations, Seen.now.conversations);
            try std.testing.expectEqual(creations, Seen.now.creates);
            try std.testing.expectEqual(pins + @as(usize, @intFromBool(target == .session)), Seen.now.pins);
            if (target == .session) {
                try std.testing.expectEqualStrings(&reference, &Seen.now.pin_session);
                try std.testing.expect(Seen.now.pin_requested);
            }
            try std.testing.expectEqualStrings("Unsent café", frontend.input.composition().bytes);
            try std.testing.expectEqual(cursor, frontend.input.composition().cursor);
            try std.testing.expect(!overview.root.input.listFocused());
            try std.testing.expectEqual(reference, overview.state.conversing.?);
        }
    }

    for ([_]bool{ false, true }) |alt| {
        const rig = try openListed();
        defer rig.close();
        const overview = rig.overview;
        const selection = overview.state.selected;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const frame = try overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = 140, .height = 40 }, .cell_size = .{} });
        const point = Find.origin(frame, overview.app_new_session.widget(), .{ .row = 0, .col = 0 }) orelse return error.TestExpectedDrawnNewSession;
        var ctx = rig.context();
        defer ctx.cmds.deinit(ctx.alloc);
        var mouse: vaxis.Mouse = .{ .col = @intCast(point.col + 4), .row = @intCast(point.row), .button = if (alt) .left else .right, .type = .press, .mods = .{ .alt = alt } };
        try app_events.mouse(&ctx, frame, mouse);
        mouse.type = .release;
        try app_events.mouse(&ctx, frame, mouse);
        for (ctx.cmds.items) |cmd| switch (cmd) {
            .set_mouse_shape => {},
            else => return error.TestUnexpectedCommand,
        };
        try std.testing.expect(try rig.settle() == null);
        try std.testing.expectEqual(selection, overview.state.selected);
        try std.testing.expect(overview.root.session == null);
        try std.testing.expect(!overview.root.input.layer.settingsOpen());
        try std.testing.expectEqual(@as(usize, 0), Seen.now.pins);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
        try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
        try std.testing.expect(!ctx.quit);
    }
}

test "overview redraw deadline includes quota header with failed row off screen" {
    const Listing = struct {
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            const failure = try fake_operations.list(self, requests, cursor, page);
            const row = &page.rows[page.count - 1];
            row.work.state = .{ .failed = .{ .since = test_now_s, .code = .{}, .resets_at = test_now_s + 200 } };
            try row.work.state.failed.code.set("provider_quota");
            row.provider = .codex;
            return failure;
        }
    };
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    Seen.now.listed = listed_references.len;
    Seen.now.working = Seen.now.listed;
    _ = try overview.event(.{ .tick = test_now_s * 1000 });
    try std.testing.expect(try rig.settle() == null);
    const reference = listed_references[listed_references.len - 1][0..6].*;
    overview.caps.unicode = false;
    overview.state.selected = .{ .session = listed_references[0][0..6].* };
    const before = overview.animationMs();
    var shown = try rig.shown(140, 8);
    defer shown.deinit();
    const after = overview.animationMs();
    try std.testing.expect(overview.app_header.drawn);
    try std.testing.expect(std.mem.indexOf(u8, try shown.text(), "Quota used up. Resets in 3m.") != null);
    for (overview.app_sessions.shown.first..overview.app_sessions.shown.end) |at| {
        const row = &overview.state.rows.items[overview.state.order.items[at]];
        try std.testing.expect(!std.mem.eql(u8, &reference, &row.reference));
        try std.testing.expectEqual(view.Kind.working, std.meta.activeTag(row.state));
    }
    const deadline = overview.app_redraw_at.?;
    try std.testing.expect(deadline >= before + 21_000 and deadline <= after + 21_000);
    try std.testing.expect(!overview.wantsFrameAt(deadline - 1));
    try std.testing.expect(overview.wantsFrameAt(deadline));
    overview.state.now_ms += 21_000;
    var changed = try rig.shown(140, 8);
    defer changed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try changed.text(), "Quota used up. Resets in 2m.") != null);
}

test "background discovery reaches the production version widget without requesting an upgrade" {
    for (0..3) |case| {
        const discovery_failed = case == 1;
        const running_version = @import("release_candidate.zig").Version.parse(@import("transport_options").version) catch null;
        const newer_candidate = if (running_version) |running| running.schema < 999 or (running.schema == 999 and running.patch < 2) else false;
        const offers_update = !discovery_failed and newer_candidate;
        const rig = try openOverview();
        defer rig.close();
        const overview = rig.overview;
        const job = &overview.upgrade_job;
        job.* = .{ .init = rig.init, .allocator = std.testing.allocator, .started = true, .discovery_attempted = true, .operation = .discover };
        const Worker = struct {
            var release: std.atomic.Value(bool) = .init(true);
            fn run(raw: *anyopaque, _: *ClientTask) !void {
                const owner: *UpgradeJob = @ptrCast(@alignCast(raw));
                try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &release, test_poll.isSet);
                owner.candidate = try @import("release_candidate.zig").fromEffectiveUrl(owner.allocator, "https://fixture/releases/tag/v0.999.2", "https://fixture", "https://fixture", "linux-x86_64");
            }
        };
        Worker.release.store(case != 2, .release);
        defer Worker.release.store(true, .release);
        try job.task.start(rig.init.io, job, Worker.run);
        if (case == 2) {
            var waiting_ctx = rig.context();
            defer waiting_ctx.cmds.deinit(std.testing.allocator);
            try overview.startUpgrade();
            _ = try overview.event(.{ .conversed = .{ .reference = "k7m2qx".*, .work = .idle, .input = .cancel_upgrade } });
            try overview.appUpgrade(&waiting_ctx);
            try std.testing.expect(job.discovering() and job.task.thread != null);
            try std.testing.expectEqual(upgrade_status.Run.cancelling, overview.state.upgrade.run.?);
            Worker.release.store(true, .release);
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &job.task, ClientTask.completed);
            try overview.appUpgrade(&waiting_ctx);
            try std.testing.expectEqual(upgrade_status.Ended.cancelled, overview.state.upgrade.run.?.ended.how);
            try std.testing.expect(job.discovery_attempted and !job.started and !job.cancelling and !job.discovering());
            continue;
        }
        try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &job.task, ClientTask.completed);
        if (discovery_failed) job.failure = error.ConnectionRefused;
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try overview.appDiscoverUpgrade(&ctx);
        try std.testing.expect(!overview.state.upgrading());
        try std.testing.expect(overview.state.upgrade.run == null);
        try std.testing.expectEqual(offers_update, overview.state.upgrade.available != null);
        try std.testing.expect(job.finished and job.task.thread == null and job.result == null and job.checked == null);
        var shown = try rig.shown(80, 24);
        defer shown.deinit();
        try std.testing.expectEqualDeep(overview.state.upgrade.available, overview.app_settings_line.available);
        const settings_row: u16 = for (0..24) |row| {
            if (std.mem.startsWith(u8, try shown.line(@intCast(row)), "     Settings")) break @intCast(row);
        } else return error.TestExpectedSettingsRow;
        const bottom = try shown.line(settings_row + 1);
        try std.testing.expectEqual(offers_update, std.mem.indexOf(u8, bottom, "Update to 0.999.2") != null);
        if (!offers_update) try std.testing.expect(std.mem.indexOf(u8, bottom, @import("transport_options").version) != null);
        try std.testing.expect(std.mem.indexOf(u8, bottom, "Update failed") == null);
        try overview.appDiscoverUpgrade(&ctx);
        try std.testing.expect(job.task.thread == null);
        try overview.startUpgrade();
        _ = try overview.event(.{ .conversed = .{ .reference = "k7m2qx".*, .work = .idle, .input = .cancel_upgrade } });
        try std.testing.expectEqual(upgrade_status.Run.cancelling, overview.state.upgrade.run.?);
        try overview.appUpgrade(&ctx);
        try std.testing.expectEqual(upgrade_status.Ended.cancelled, overview.state.upgrade.run.?.ended.how);
        try std.testing.expect(job.discovery_attempted and !job.started and !job.cancelling and !job.discovering());
        try overview.appDiscoverUpgrade(&ctx);
        try std.testing.expect(!job.started);
    }
}

test "upgrade attempt presentation domain ends synthetic pause and publishing without lifting recovery holds" {
    const found: upgrade_status.Found = .{ .host = .none };
    const target: upgrade_status.Version = .{ .schema = 61, .patch = 2 };
    const runs = [_]upgrade_status.Run{
        .checking,
        .{ .installing = .{ .found = found } },
        .{ .installing = .{ .found = found, .step = .publishing } },
        .{ .installing = .{ .found = found, .step = .restarting } },
        .cancelling,
        .{ .ended = .{ .how = .{ .up_to_date = target }, .outcome = .unchanged } },
        .{ .ended = .{ .how = .{ .superseded = target }, .outcome = .compatible } },
        .{ .ended = .{ .how = .{ .refused = .source_build }, .outcome = .unchanged } },
        .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } },
        .{ .ended = .{ .how = .{ .failed = .download }, .outcome = .unchanged } },
        .{ .ended = .{ .how = .{ .failed = .release }, .outcome = .unchanged } },
        .{ .ended = .{ .how = .{ .failed = .other }, .outcome = .unchanged } },
        .{ .ended = .{ .how = .{ .upgraded = .{ .version = target, .restarted = true } }, .outcome = .compatible } },
        .{ .ended = .{ .how = .{ .incompatible = target }, .outcome = .incompatible } },
    };
    const rig = try openOverview();
    defer rig.close();
    const overview = rig.overview;
    for (runs) |attempt| for (std.enums.values(session_upgrade.After)) |after| for ([_]bool{ false, true }) |observed_paused| {
        overview.state.upgrade = .{ .run = attempt, .after = after };
        overview.host_observation = .{ .ready = .{ .facts = .{ .started_at = 1, .slots = 4, .slots_in_use = 0 }, .paused = observed_paused } };
        const paused = attempt.going() or observed_paused;
        try std.testing.expectEqual(paused, overview.hostState() == .paused);
        try std.testing.expectEqual(attempt.going() or after != .open, overview.state.holdsHost());
        try std.testing.expectEqual(paused, hostNotice(overview) != null);
        for ([_]u16{ 140, 46 }) |width| {
            var shown = try rig.shown(width, 30);
            defer shown.deinit();
            const text = try shown.text();
            try std.testing.expectEqual(paused, std.mem.indexOf(u8, text, "■ Host paused") != null);
            try std.testing.expectEqual(attempt == .installing and attempt.installing.step == .publishing, std.mem.indexOf(u8, text, "Publishing; cancelling no longer rolls back") != null);
            if (attempt == .ended and attempt.ended.how == .incompatible) {
                try std.testing.expect(std.mem.indexOf(u8, text, "restart rui") != null);
            }
        }
    };
}

test "wide launch waits for listing and opens the newest empty Session without creation" {
    const Listing = struct {
        fn list(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            page.* = .{ .count = 5, .delta = .full, .since = .{ .instance = @splat(1), .generation = 1 }, .next = null };
            for (page.rows[0..5], 0..) |*row, i| {
                row.* = .{ .created_at = @intCast(10 + i), .read_version = page.since, .work = .{ .state = .{ .idle = .{ .since = test_now_s } } } };
                row.reference.set(listed_references[i]) catch unreachable;
                row.workspace.set("/work") catch unreachable;
                row.model.set("gpt-5.5") catch unreachable;
            }
            page.rows[2].archive_state = .archived;
            for (page.rows[3..5]) |*row| row.first_message = .{ .position = 1, .admission = 4, .admitted_at = test_now_s, .sender = null, .content = .{ .length = 1, .digest = @splat(0) } };
            return null;
        }
    };
    var ops = fake_operations;
    ops.list = Listing.list;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
    defer rig.close();
    _ = try view.step(&rig.overview.state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
    var shown = try rig.shown(140, 40);
    defer shown.deinit();
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, try shown.text(), "+ New Session"));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, try shown.text(), "enter open"));
    var ctx = rig.context();
    defer {
        for (ctx.cmds.items) |command| if (command == .set_title) std.testing.allocator.free(command.set_title);
        ctx.cmds.deinit(std.testing.allocator);
    }
    try rig.overview.appNext(&ctx, try rig.overview.event(.launch_poll));
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    _ = try rig.overview.event(.{ .tick = test_now_s * 1000 });
    _ = try rig.settle();
    try appEvent(rig.overview, &ctx, .tick);
    try std.testing.expectEqualStrings("b4n8wd", &Seen.now.conversed);
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
    try rig.overview.appNext(&ctx, try rig.overview.event(.launch_poll));
    try std.testing.expectEqual(@as(usize, 1), Seen.now.conversations);
}

test "narrow launch and later widening do not open a chat" {
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, fake_operations, &cancellation);
    defer rig.close();
    _ = try view.step(&rig.overview.state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
    var narrow = try rig.shown(46, 30);
    defer narrow.deinit();
    _ = try rig.overview.event(.{ .tick = test_now_s * 1000 });
    _ = try rig.settle();
    var wide = try rig.shown(140, 40);
    defer wide.deinit();
    var ctx = rig.context();
    defer {
        for (ctx.cmds.items) |command| if (command == .set_title) std.testing.allocator.free(command.set_title);
        ctx.cmds.deinit(std.testing.allocator);
    }
    try appEvent(rig.overview, &ctx, .tick);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.conversations);
    try std.testing.expectEqual(@as(usize, 0), Seen.now.creates);
    try std.testing.expectEqual(false, rig.overview.state.creating());
    try std.testing.expectEqual(true, rig.overview.root.session == null);
}

test "wide launch creates a focused empty chat and Escape returns to overview" {
    const Scratch = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    Scratch.dir = tmp.dir;
    Scratch.files = 0;
    var ops = fake_operations;
    ops.open = openSession;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6-luna" }, ops, &cancellation);
    defer rig.close();
    _ = try view.step(&rig.overview.state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
    const overview = rig.overview;
    overview.hooks.scratch = Scratch.scratch;
    defer {
        if (overview.app_session) |left| {
            left.frontend.?.stop();
            overview.disposeSession(left);
            overview.app_session = null;
        }
        for (overview.retired.items) |retired| overview.disposeSession(retired.left);
        overview.retired.deinit(std.testing.allocator);
    }
    var shown = try rig.shown(140, 40);
    defer shown.deinit();
    _ = try overview.event(.{ .tick = test_now_s * 1000 });
    _ = try rig.settle();
    var ctx = rig.context();
    defer {
        for (ctx.cmds.items) |command| if (command == .set_title) std.testing.allocator.free(command.set_title);
        ctx.cmds.deinit(std.testing.allocator);
    }
    try appEvent(overview, &ctx, .tick);
    try std.testing.expect(overview.state.launch == .creating);
    var pending = try rig.shown(140, 40);
    defer pending.deinit();
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, try pending.text(), "+ New Session"));
    _ = try rig.settle();
    try std.testing.expectEqual(@as(usize, 1), Seen.now.creates);
    const frontend = overview.app_session.?.frontend.?;
    try std.testing.expect(overview.root.session.?.eql(frontend.widget()));
    try std.testing.expectEqual(true, rig.last_focus.?.eql(frontend.app_input.composer.widget()));
    try std.testing.expectEqualStrings("", frontend.input.composition().bytes);
    try std.testing.expect(overview.root.listVisible());
    var split = try rig.shown(140, 40);
    defer split.deinit();
    const divider = split.screen.readCell(Root.list_width, 0).?.char.grapheme;
    try std.testing.expect(std.mem.eql(u8, divider, "│") or std.mem.eql(u8, divider, "|"));
    try std.testing.expect(std.mem.indexOf(u8, try split.text(), "enter open") == null);
    try std.testing.expect(try rig.press("\x1b[D") == null);
    try std.testing.expect(overview.root.input.listFocused());
    try overview.root.focusChat(&ctx);
    try std.testing.expectEqual(true, try rig.press("\x1b") == null);
    try std.testing.expectEqual(true, overview.root.session == null);
    try std.testing.expect(overview.root.listVisible());
    try overview.appNext(&ctx, try overview.event(.launch_poll));
    try std.testing.expectEqual(true, overview.root.session == null);
}

test "launch threshold follows split width and explicit resume never starts a new chat" {
    for ([_]u16{ 46, Root.split_at - 1, Root.split_at, 140 }) |width| for ([_]bool{ false, true }) |is_resume| {
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests", .open = if (is_resume) "k7m2qx".* else null }, fake_operations, &cancellation);
        defer rig.close();
        _ = try view.step(&rig.overview.state, .{ .launch_start = .{ .explicit_session = is_resume, .restoring = false } });
        var shown = try rig.shown(width, 30);
        defer shown.deinit();
        try std.testing.expectEqual(!is_resume and width >= Root.split_at, rig.overview.state.launch == .waiting);
    };
}

test "wide launch refused and unconfirmed creation restore the overview" {
    const Creation = struct {
        var uncertain = false;
        fn create(_: *Self, _: client.Requests, _: configure_input.ConfigureInput, reply: *Reply) !void {
            reply.* = if (uncertain) .unconfirmed("lost-create") else .refused("model_required");
        }
    };
    for ([_]bool{ false, true }) |uncertain| {
        Creation.uncertain = uncertain;
        var ops = fake_operations;
        ops.create = Creation.create;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        _ = try view.step(&rig.overview.state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
        var shown = try rig.shown(140, 40);
        defer shown.deinit();
        _ = try rig.overview.event(.{ .tick = test_now_s * 1000 });
        _ = try rig.settle();
        var ctx = rig.context();
        defer ctx.cmds.deinit(std.testing.allocator);
        try rig.overview.appNext(&ctx, try rig.overview.event(.launch_poll));
        try std.testing.expect(rig.overview.state.creating());
        _ = try rig.settle();
        try std.testing.expectEqual(.done, rig.overview.state.launch);
        var refused = try rig.shown(140, 40);
        defer refused.deinit();
        const text = try refused.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "+ New Session") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (uncertain) "Creation unsure; details on exit" else "Not created") != null);
        try std.testing.expectEqual(uncertain, rig.overview.state.creating());
    }
}

test "wide launch shows stopped Host recovery and failed listing" {
    const Listing = struct {
        fn read(_: *Self, _: client.Requests, _: protocol_reply.SessionListCursor, _: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            return error.ConnectionRefused;
        }
    };
    for ([_]HostRecovery.Availability{ .stopped, .unreadable }) |availability| {
        var ops = HostRecovery.operations();
        ops.list = Listing.read;
        HostRecovery.availability = availability;
        var cancellation: client.Cancellation = .{};
        const rig = try Rig.open(.{ .store = "/store", .workspace = "/work", .home = "/home", .directory = "/requests" }, ops, &cancellation);
        defer rig.close();
        _ = try view.step(&rig.overview.state, .{ .launch_start = .{ .explicit_session = false, .restoring = false } });
        var shown = try rig.shown(140, 40);
        defer shown.deinit();
        try std.testing.expect(rig.overview.state.hidesOverview());
        _ = try rig.overview.event(.{ .tick = test_now_s * 1000 });
        _ = try rig.settle();
        var recovered = try rig.shown(140, 40);
        defer recovered.deinit();
        const text = try recovered.text();
        try std.testing.expect(std.mem.indexOf(u8, text, "+ New Session") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, if (availability == .stopped) "Host stopped" else "Host unreachable") != null);
        if (availability == .stopped) try std.testing.expect(std.mem.indexOf(u8, text, "start") != null);
        try std.testing.expectEqual(.done, rig.overview.state.launch);
    }
}

test "narrow empty chat exit retains every list row through spinner repaints and resize" {
    var stage: []const u8 = "setup";
    errdefer std.debug.print("repaint stage: {s}\n", .{stage});
    const Frames = struct {
        var dir: std.Io.Dir = undefined;
        var files: u8 = 0;
        const labels = [_][]const u8{ "Working row", "Finished row", "Waiting on you row", "Failed row" };
        fn due(overview: *Self) bool {
            return overview.wantsFrame();
        }
        fn scratch(init: std.process.Init) !std.Io.File {
            files += 1;
            return dir.createFile(init.io, &.{'a' + files}, .{ .read = true });
        }
        fn list(self: *Self, requests: client.Requests, cursor: protocol_reply.SessionListCursor, page: *protocol_reply.SessionListPage) !?protocol_reply.ReadFailure {
            const failure = try fake_operations.list(self, requests, cursor, page);
            for (page.rows[0..4], labels, 0..) |*row, label, at| {
                row.label = try protocol.Bounded(100).from(label);
                const since = test_now_s - 10;
                row.work.state = switch (at) {
                    0 => .{ .working = .{ .since = since } },
                    1 => .{ .finished = .{ .since = since } },
                    2 => .{ .approval = .{ .since = since } },
                    else => .{ .failed = .{ .since = since, .code = .{}, .resets_at = null } },
                };
            }
            return failure;
        }
        fn paint(rig: *Rig, vx: *vaxis.Vaxis, output: *std.Io.Writer, size: vxfw.Size) !void {
            if (vx.screen.width != size.width or vx.screen.height != size.height) try vx.resize(std.testing.allocator, output, .{ .cols = size.width, .rows = size.height, .x_pixel = 0, .y_pixel = 0 });
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const surface = try rig.overview.root.widget().draw(.{ .arena = arena.allocator(), .cell_arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} });
            vx.window().clear();
            try surface.render(vx.window(), rig.overview.root.overview);
            try vx.render(output);
            var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer text.deinit();
            for (0..size.height) |row| {
                for (0..size.width) |col| {
                    const last = vx.screen_last.readCell(@intCast(col), @intCast(row)).?;
                    const cell = vx.screen.readCell(@intCast(col), @intCast(row)).?;
                    try std.testing.expectEqualStrings(cell.char.grapheme, last.char.grapheme);
                    try text.writer.writeAll(last.char.grapheme);
                }
                try text.writer.writeByte('\n');
            }
            errdefer std.debug.print("paint cells: {s}\n", .{text.written()});
            for (labels) |label| try std.testing.expect(std.mem.indexOf(u8, text.written(), label) != null);
            try std.testing.expect(std.mem.indexOf(u8, text.written(), "+ New Session") != null);
            try std.testing.expect(std.mem.indexOf(u8, text.written(), "Settings") != null);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = home_buffer[0..try tmp.dir.realPath(std.testing.io, &home_buffer)];
    Frames.dir = tmp.dir;
    Frames.files = 0;
    var ops = fake_operations;
    ops.list = Frames.list;
    ops.open = openSession;
    var cancellation: client.Cancellation = .{};
    const rig = try Rig.open(.{ .store = home, .workspace = "/work", .home = home, .directory = home, .provider = "codex", .model = "gpt-6-luna" }, ops, &cancellation);
    defer rig.close();
    const overview = rig.overview;
    overview.hooks.scratch = Frames.scratch;
    defer {
        if (overview.app_session) |left| {
            left.frontend.?.stop();
            overview.disposeSession(left);
            overview.app_session = null;
        }
        for (overview.retired.items) |retired| overview.disposeSession(retired.left);
        overview.retired.deinit(std.testing.allocator);
    }
    Seen.now.listed = 4;
    _ = try overview.event(.{ .tick = test_now_s * 1000 });
    try std.testing.expect(try rig.settle() == null);
    overview.caps = .{};
    stage = "open";
    try std.testing.expect(try rig.press("\x1b[H\r") == null);
    try std.testing.expect(try rig.settle() == null);
    const frontend = overview.app_session.?.frontend.?;
    frontend.reading.opening = false;
    frontend.poll_at = std.math.maxInt(i96);
    frontend.line.read = .{ .revision = 1, .end = 0 };
    frontend.line.folder = .{};
    try frontend.line.folder.?.set("/work");
    stage = "chat";
    var chat = try rig.shown(46, 30);
    defer chat.deinit();
    try std.testing.expect(std.mem.indexOf(u8, try chat.text(), "Type a task") != null);
    stage = "escape";
    try std.testing.expect(try rig.press("\x1b") == null);
    try std.testing.expect(overview.root.session == null);
    try std.testing.expect(overview.app_session == null);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var vx = try vaxis.init(std.testing.io, std.testing.allocator, &rig.environ, .{});
    defer vx.deinit(std.testing.allocator, &output.writer);
    vx.state.alt_screen = true;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    defer ctx.cmds.deinit(arena.allocator());
    for ([_]vxfw.Size{ .{ .width = 46, .height = 30 }, .{ .width = 140, .height = 40 }, .{ .width = 46, .height = 30 } }) |size| {
        stage = "paint";
        try Frames.paint(rig, &vx, &output.writer, size);
        var previous: protocol.Bounded(8) = .{};
        var changed = false;
        for (0..10) |_| {
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(2)), overview, Frames.due);
            ctx.redraw = false;
            try overview.root.widget().handleEvent(&ctx, .tick);
            stage = "tick";
            try std.testing.expect(ctx.redraw);
            stage = "spinner paint";
            try Frames.paint(rig, &vx, &output.writer, size);
            const glyph = vx.screen_last.readCell(3, 3).?.char.grapheme;
            if (previous.len != 0 and !std.mem.eql(u8, previous.slice(), glyph)) changed = true;
            try previous.set(glyph);
        }
        try std.testing.expect(changed);
    }
}
