const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const core = @import("sign_in.zig");
const ClientTask = @import("ClientTask.zig");
const api_key = @import("api_key.zig");
const host_start = @import("host_start.zig");
const codex_auth = @import("codex_auth.zig");
const provider_login = @import("provider_login.zig");
const plan_login = @import("chatgpt_plan_login.zig");
const plan_wire = @import("chatgpt_plan_wire.zig");
const pages = @import("os/pages.zig");
const preferences = @import("preferences.zig");
const selection = @import("new_session_selection.zig");
const Panel = @import("widgets/Panel.zig");
const Dialog = @import("Dialog.zig");
const line = @import("widgets/cell_line.zig");
const Editor = @import("DraftEditor.zig");
const protocol = @import("protocol.zig");
const Self = @This();
const host_launch = @import("host_launch.zig");

pub const Activation = struct {
    binding: selection.Binding,
    store: protocol.Bounded(protocol.max_store_bytes),
    default_failed: bool = false,
    launch: ?host_launch.Result = null,
    pending: bool = false,
};
pub const Activate = *const fn (std.process.Init, selection.Intent, ?*const host_start.Connection) anyerror!Activation;
pub const Ready = *const fn (std.process.Init, []const u8) core.Readinesses;
const Published = struct { defaults: anyerror!void, activation: anyerror!Activation, connection: ?host_start.ConnectionSave = null };
const Outcome = union(enum) { cancelled, failed: struct { cause: anyerror, shown: ?core.Failure = null }, published: Published };
const Presentation = union(enum) { screen: *vxfw.EventContext, departure: *std.Io.Writer, native_departure };
const max_receipt_bytes = @max(host_launch.max_report_bytes + 512, 4 * @import("host_settings.zig").max_path_bytes + 1024);
const max_deferred_bytes = 16 * max_receipt_bytes;
const Receipts = struct { file: std.Io.File, committed_end: u64 = 0, reported: u64 = 0, first_failure: ?anyerror = null };
const ReceiptFailure = union(enum) {
    unavailable: anyerror,
    internal: anyerror,
    fn cause(self: @This()) anyerror {
        return switch (self) {
            inline else => |cause_| cause_,
        };
    }
};
pub const Edit = union(enum) { append: []const u8, erase, confirm, clear };

pub const Browser = struct {
    link: @import("bounded.zig").Bounded(plan_login.max_link_bytes),
    entry: [plan_wire.max_request_line_bytes]u8,
    len: usize,
    confirmed: usize,
    overflow: bool,
    stray: bool,
    checking: bool,
    failure: ?core.Failure,

    pub fn init(self: *Browser) void {
        self.link.len = 0;
        self.len = 0;
        self.confirmed = 0;
        self.overflow = false;
        self.stray = false;
        self.checking = false;
        self.failure = null;
    }

    fn take(browser: *Browser, buffer: []u8) ?usize {
        const moved = @min(browser.confirmed, buffer.len);
        if (moved == 0) return null;
        @memcpy(buffer[0..moved], browser.entry[0..moved]);
        const rest = browser.len - moved;
        std.mem.copyForwards(u8, browser.entry[0..rest], browser.entry[moved..browser.len]);
        std.crypto.secureZero(u8, browser.entry[rest..browser.len]);
        browser.len = rest;
        browser.confirmed -= moved;
        return moved;
    }

    pub fn edit(browser: *Browser, change: Edit) void {
        switch (change) {
            .append => |text| {
                browser.stray = false;
                browser.checking = false;
                if (browser.overflow or text.len >= browser.entry.len - browser.len) {
                    browser.overflow = true;
                    return;
                }
                @memcpy(browser.entry[browser.len..][0..text.len], text);
                browser.len += text.len;
            },
            .erase => {
                if (browser.overflow) return browser.discard();
                if (browser.len == browser.confirmed) return;
                browser.len -= 1;
                browser.entry[browser.len] = 0;
            },
            .confirm => {
                if (browser.overflow) {
                    browser.discard();
                    browser.stray = true;
                    return;
                }
                if (browser.len == browser.confirmed) return;
                browser.entry[browser.len] = '\n';
                browser.len += 1;
                browser.confirmed = browser.len;
                browser.checking = true;
            },
            .clear => {
                std.crypto.secureZero(u8, browser.entry[0..browser.len]);
                browser.len = 0;
                browser.confirmed = 0;
                browser.overflow = false;
                browser.stray = false;
                browser.checking = false;
            },
        }
    }

    fn discard(browser: *Browser) void {
        std.crypto.secureZero(u8, browser.entry[browser.confirmed..browser.len]);
        browser.len = browser.confirmed;
        browser.overflow = false;
    }
};

const Form = struct {
    base_bank: [@import("endpoint_value.zig").max_endpoint_bytes]u8,
    key_bank: [api_key.max_key_bytes]u8,
    model_bank: [protocol.max_model_bytes]u8,
    base: Editor,
    key: Editor,
    model: Editor,
    original: host_start.ConnectionInfo,
    initial_base: protocol.Bounded(@import("endpoint_value.zig").max_endpoint_bytes),

    fn init(self: *Form, original: host_start.ConnectionInfo, model: ?[]const u8) void {
        self.original = original;
        self.base = .initLocked(&self.base_bank, .pastes_only);
        self.key = .initLocked(&self.key_bank, .pastes_only);
        self.model = .initLocked(&self.model_bank, .pastes_only);
        self.initial_base = .{};
        const endpoint = original.endpoint.slice();
        const base = if (std.mem.endsWith(u8, endpoint, "/responses")) endpoint[0 .. endpoint.len - "/responses".len] else endpoint;
        self.initial_base.set(base) catch unreachable;
        _ = self.base.set(base, base.len);
        if (model) |chosen| _ = self.model.set(chosen, chosen.len);
    }
    fn editor(self: *Form, field: core.Field) *Editor {
        return switch (field) {
            .base => &self.base,
            .key => &self.key,
            .model => &self.model,
        };
    }
    /// The first field a refused paste locked; Connect stays blocked until it is acknowledged.
    fn refusedField(self: *Form) ?core.Field {
        for (std.enums.values(core.Field)) |field| if (self.editor(field).rejected != null) return field;
        return null;
    }
    fn label(self: *Form, field: core.Field) []const u8 {
        return switch (field) {
            .base => if (self.endpointEdit() == .unchanged and !std.mem.endsWith(u8, self.original.endpoint.slice(), "/responses")) "Endpoint (kept)" else "Base URL",
            .key => "API key",
            .model => "Model ID",
        };
    }
    fn wipeKey(self: *Form) void {
        std.crypto.secureZero(u8, &self.key_bank);
        self.key = .initLocked(&self.key_bank, .pastes_only);
    }
    fn endpointEdit(self: *Form) host_start.EndpointEdit {
        return if (std.mem.eql(u8, self.initial_base.slice(), self.base.text()))
            .{ .unchanged = self.original.endpoint.slice() }
        else
            .{ .base = self.base.text() };
    }
};
const Frozen = struct { intent: selection.Intent, provider: core.Provider, model: []const u8, key: host_start.ConnectionKey, endpoint: host_start.EndpointEdit };
const Paste = union(enum) { none, ignore, field: core.Field, callback };
const Hit = struct { row: u16, start: u16, end: u16, action: core.Action };
const Drawn = struct {
    attempt: u64 = 0,
    page: std.meta.Tag(core.Page) = .account,
    focused: ?struct { control: core.Control, action: core.Action } = null,
    copy: ?core.Code = null,
    hits: []const Hit = &.{},
};

state: core.State = .{},
init: ?std.process.Init = null,
selectors: selection.Intent = .{},
target: protocol.Bounded(protocol.max_store_bytes) = .{},
activate: ?Activate = null,
ready: ?Ready = null,
scratch: ?*const fn (std.process.Init) anyerror!std.Io.File = null,
receipts: ?Receipts = null,
reported_current: usize = 0,
retention_failure: ?ReceiptFailure = null,
reporting_failure: ?anyerror = null,
userdata: ?*anyopaque = null,
on_done: ?*const fn (*anyopaque, *vxfw.EventContext, Activation) anyerror!void = null,
on_close: ?*const fn (*anyopaque, *vxfw.EventContext) anyerror!void = null,
unicode: bool = true,
/// The app's capabilities, read where they live so the card and the scrim Root draws beneath
/// it always share one skin.
caps: *const @import("overview_view.zig").Caps = &default_caps,
form: ?pages.Mapped(Form) = null,
issue: ?[]const u8 = null,
paste: Paste = .none,
drawn: Drawn = .{},
scroll: usize = 0,
task: ClientTask = .{},
gate: std.atomic.Value(enum(u8) { cancellable, cancelled, publishing }) = .init(.cancellable),
code: core.Code = .{},
shown_pending: bool = false,
browser: ?pages.Mapped(Browser) = null,
attempt: core.Attempt = .existing,
frozen: ?Frozen = null,
saved: ?host_start.ConnectionSave = null,
outcome: ?Outcome = null,
threadlocal var current: *Self = undefined;

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
}

pub fn reset(self: *Self) !void {
    std.debug.assert(self.task.thread == null and self.browser == null);
    self.closeForm();
    self.code.len = 0;
    self.shown_pending = false;
    self.state = .{};
    self.saved = null;
    self.frozen = null;
    self.issue = null;
    self.paste = .none;
    self.drawn = .{};
    self.scroll = 0;
    if (self.selectors.store) |store| try self.target.set(store);
}

fn ensureForm(self: *Self) !*Form {
    return self.ensureFormWithFault(null);
}
const FormFault = enum { inspect, map };
fn ensureFormWithFault(self: *Self, fault: ?FormFault) !*Form {
    if (self.form) |mapped| return mapped.value;
    if (fault == .inspect) return error.InjectedConnectionInspectFailure;
    var original: host_start.ConnectionInfo = .{};
    try original.endpoint.set(host_start.openai_endpoint);
    if (self.init) |init_| if (self.target.len != 0) {
        original = try host_start.inspectConnection(init_, self.target.slice());
    };
    if (fault == .map) return error.InjectedFormMapFailure;
    const mapped = try pages.Mapped(Form).map();
    mapped.value.init(original, self.selectors.model);
    self.form = mapped;
    return mapped.value;
}
fn closeForm(self: *Self) void {
    const mapped = self.form orelse return;
    std.crypto.secureZero(u8, std.mem.asBytes(mapped.value));
    mapped.unmap();
    self.form = null;
}

pub fn cancel(self: *Self) void {
    _ = self.gate.cmpxchgStrong(.cancellable, .cancelled, .acq_rel, .acquire);
}
pub fn stop(self: *Self) !void {
    self.cancel();
    defer self.closeForm();
    try self.settle(.native_departure);
}
fn stopTo(self: *Self, writer: *std.Io.Writer) !void {
    self.cancel();
    defer self.closeForm();
    try self.settle(.{ .departure = writer });
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.task.thread == null);
    self.closeForm();
    if (self.receipts) |receipt| receipt.file.close(self.init.?.io);
    self.receipts = null;
    self.outcome = null;
    self.saved = null;
    self.frozen = null;
    self.reported_current = 0;
    self.retention_failure = null;
    self.reporting_failure = null;
}

const ReceiptFault = struct { after: usize, cause: anyerror };
noinline fn stageReceipt(self: *Self, fault: ?ReceiptFault) !void {
    if (self.outcome == null) return;
    if (self.reported_current != 0) return self.retainFailure(.{ .internal = error.SignInReceiptPartlyReported });
    var bytes: [max_receipt_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const failure = self.writeOutcome(&writer) catch |err| return self.retainFailure(.{ .internal = err });
    const receipt = writer.buffered();
    if (receipt.len == 0) {
        self.outcome = null;
        return;
    }
    const end = if (self.receipts) |kept| kept.committed_end else 0;
    if (receipt.len > max_deferred_bytes - end) return self.retainFailure(.{ .unavailable = error.SignInReceiptLimit });
    const init_ = self.init orelse return self.retainFailure(.{ .internal = error.SignInReceiptUnavailable });
    if (self.receipts == null) {
        const open = self.scratch orelse return self.retainFailure(.{ .internal = error.SignInReceiptUnavailable });
        const file = open(init_) catch |err| return self.retainFailure(.{ .unavailable = err });
        self.receipts = .{ .file = file };
    }
    const kept = &self.receipts.?;
    if (fault) |cut| {
        kept.file.writePositionalAll(init_.io, receipt[0..@min(cut.after, receipt.len)], end) catch |err| return self.retainFailure(.{ .unavailable = err });
        return self.retainFailure(.{ .unavailable = cut.cause });
    }
    kept.file.writePositionalAll(init_.io, receipt, end) catch |err| return self.retainFailure(.{ .unavailable = err });
    kept.committed_end += receipt.len;
    if (kept.first_failure == null) kept.first_failure = failure;
    self.retention_failure = null;
    self.outcome = null;
}
fn retainFailure(self: *Self, failure: ReceiptFailure) anyerror {
    self.retention_failure = failure;
    return failure.cause();
}
fn receiptIoFailure(self: *Self, presentation: Presentation, cause: anyerror) anyerror {
    if (self.reporting_failure == null) self.reporting_failure = cause;
    return if (presentation == .native_departure) error.SignInReportingUnavailable else cause;
}
fn drainReceipts(self: *Self, presentation: Presentation) !void {
    if (self.receipts) |*kept| {
        const io = self.init.?.io;
        switch (presentation) {
            .native_departure => try @import("stderr.zig").writeReceiptFile(io, kept.file, kept.committed_end, &kept.reported),
            .departure => |writer| {
                var buffer: [4096]u8 = undefined;
                while (kept.reported < kept.committed_end) {
                    const wanted: usize = @intCast(@min(buffer.len, kept.committed_end - kept.reported));
                    const count = try kept.file.readPositional(io, &.{buffer[0..wanted]}, kept.reported);
                    if (count == 0) return error.SignInReceiptReadFailed;
                    var at: usize = 0;
                    while (at < count) {
                        const written = try writer.write(buffer[at..count]);
                        if (written == 0) return error.WriteFailed;
                        kept.reported += written;
                        at += written;
                    }
                }
            },
            .screen => unreachable,
        }
    }
}

noinline fn finishReceipts(self: *Self, presentation: Presentation) !void {
    self.drainReceipts(presentation) catch |err| return self.receiptIoFailure(presentation, err);
    var bytes: [max_receipt_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const current_failure = try self.writeOutcome(&writer);
    const receipt = writer.buffered();
    switch (presentation) {
        .native_departure => @import("stderr.zig").writeReceiptBytes(receipt, &self.reported_current) catch |err| return self.receiptIoFailure(presentation, err),
        .departure => |output| while (self.reported_current < receipt.len) {
            const count = output.write(receipt[self.reported_current..]) catch |err| return self.receiptIoFailure(presentation, err);
            if (count == 0) return self.receiptIoFailure(presentation, error.WriteFailed);
            self.reported_current += count;
        },
        .screen => unreachable,
    }
    var failure: ?anyerror = current_failure;
    if (self.receipts) |kept| if (kept.first_failure != null) {
        failure = kept.first_failure;
    };
    if (failure == null) if (self.retention_failure) |retained| {
        if (retained == .internal) failure = retained.cause();
    };
    self.outcome = null;
    self.reported_current = 0;
    self.retention_failure = null;
    self.reporting_failure = null;
    if (self.receipts) |kept| kept.file.close(self.init.?.io);
    self.receipts = null;
    if (failure) |err| return err;
}

fn cancelled() bool {
    return current.gate.load(.acquire) == .cancelled;
}
fn publish() bool {
    return current.gate.cmpxchgStrong(.cancellable, .publishing, .acq_rel, .acquire) == null;
}
fn display(code: []const u8) !void {
    const self = current;
    self.task.mutex.lockUncancelable(self.init.?.io);
    defer self.task.mutex.unlock(self.init.?.io);
    try self.code.set(code);
    self.shown_pending = true;
}
fn show(shown: plan_login.Shown) !void {
    const self = current;
    self.task.mutex.lockUncancelable(self.init.?.io);
    defer self.task.mutex.unlock(self.init.?.io);
    const browser_ = self.browser.?.value;
    switch (shown) {
        .link => |link_| try browser_.link.set(link_),
        .stray_paste => {
            browser_.stray = true;
            browser_.checking = false;
        },
        .failed => |failure| browser_.failure = browserFailure(failure),
    }
    self.shown_pending = true;
}
fn pasted(buffer: []u8) ?usize {
    const self = current;
    self.task.mutex.lockUncancelable(self.init.?.io);
    defer self.task.mutex.unlock(self.init.?.io);
    return self.browser.?.value.take(buffer);
}
fn browserFailure(failure: plan_login.Failure) core.Failure {
    return switch (failure) {
        .invalid_host_id => .host_id,
        .refused => .denied,
        .timed_out => .expired,
        .no_answer_source => .login,
        .callback => .answer,
        .unreachable_service => .unreachable_service,
        .exchange => |cause| switch (cause) {
            .plan_scope_missing => .plan,
            .code_refused => .denied,
            .not_for_this_sign_in, .unreadable => .answer,
        },
    };
}
fn work(raw: *anyopaque, _: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    current = self;
    self.outcome = if (self.runAttempt()) |published| .{ .published = published } else |err| if (err == error.LoginInterrupted and cancelled()) .cancelled else .{ .failed = .{ .cause = err } };
}
fn launchSummary(self: *const Self) ?host_launch.Summary {
    const outcome = self.outcome orelse return null;
    if (outcome != .published) return null;
    const activation = outcome.published.activation catch |err| return .{ .failed = host_launch.failureOf(err) };
    return if (activation.launch) |*launch| launch.summary() else null;
}
fn savedConnection(self: *Self) ?*const host_start.Connection {
    if (self.saved) |*saved_| return switch (saved_.*) {
        .saved => &saved_.saved,
        .uncertain => &saved_.uncertain.connection,
        .failed => null,
    };
    return null;
}
fn runAttempt(self: *Self) !Published {
    const init_ = self.init.?;
    const frozen = self.frozen.?;
    const fixture = std.mem.eql(u8, init_.environ_map.get("RUI_TEST_LOGIN") orelse "", "waiting");
    var connection: ?host_start.ConnectionSave = null;
    switch (self.attempt) {
        .browser => try provider_login.chatgpt(init_, if (fixture) .{ .fixture = "http://127.0.0.1:1" } else .openai, show, .{ .read = pasted }, cancelled, publish),
        .device => {
            if (fixture) {
                try display("BDL9-KI88H");
                while (!cancelled()) try init_.io.sleep(.fromMilliseconds(20), .awake);
                return error.LoginInterrupted;
            }
            try provider_login.codex(init_, codex_auth.login, display, cancelled, publish);
        },
        .key => {
            connection = try host_start.saveConnection(init_, self.target.slice(), frozen.endpoint, frozen.key, frozen.model, publish);
        },
        .existing => if (!publish()) return error.LoginInterrupted,
        .recheck => {
            if (!publish()) return error.LoginInterrupted;
            const saved_ = self.savedConnection() orelse return error.ConnectionNotActive;
            connection = try host_start.confirmConnection(init_, self.target.slice(), saved_);
        },
    }
    return self.activatePublished(connection);
}
fn activatePublished(self: *Self, connection: ?host_start.ConnectionSave) Published {
    const init_ = self.init.?;
    const frozen = self.frozen.?;
    if (connection) |saved_| switch (saved_) {
        .uncertain, .failed => return .{ .defaults = {}, .activation = error.ConnectionNotActive, .connection = connection },
        .saved => {},
    };
    const defaults: anyerror!void = if (frozen.provider == .openai) {} else preferences.saveProviderAfterLogin(init_.environ_map.get("HOME") orelse "", frozen.provider);
    const intended = if (connection) |*value| &value.saved else if (frozen.provider == .openai) self.savedConnection() else null;
    return .{ .defaults = defaults, .activation = self.activate.?(init_, frozen.intent, intended), .connection = connection };
}
fn closeBrowser(self: *Self) ?core.Failure {
    std.debug.assert(self.task.thread == null);
    const mapped = self.browser orelse return null;
    self.browser = null;
    const failure = mapped.value.failure;
    std.crypto.secureZero(u8, std.mem.asBytes(mapped.value));
    mapped.unmap();
    return failure;
}
fn begin(self: *Self, ctx: *vxfw.EventContext, attempt: core.Attempt) !void {
    return self.beginWithFault(ctx, attempt, null);
}
const SetupFault = enum { browser_map, worker_start };
fn beginWithFault(self: *Self, ctx: *vxfw.EventContext, attempt: core.Attempt, fault: ?SetupFault) !void {
    self.attempt = attempt;
    self.code.len = 0;
    self.shown_pending = false;
    std.debug.assert(self.outcome == null);
    if (attempt == .key or self.frozen == null or self.frozen.?.provider != .openai) self.saved = null;
    self.gate.store(.cancellable, .release);
    if (self.init == null) return;
    if (attempt == .browser) {
        if (fault == .browser_map) return self.setupFailed(ctx, error.InjectedBrowserMapFailure);
        const mapped = pages.Mapped(Browser).map() catch |err| return self.setupFailed(ctx, err);
        mapped.value.init();
        self.browser = mapped;
    }
    if (fault == .worker_start) {
        _ = self.closeBrowser();
        return self.setupFailed(ctx, error.InjectedWorkerStartFailure);
    }
    self.task.start(self.init.?.io, self, work) catch |err| {
        _ = self.closeBrowser();
        if (self.form) |mapped| mapped.value.wipeKey();
        return self.setupFailed(ctx, err);
    };
    ctx.redraw = true;
}
fn setupFailed(self: *Self, ctx: *vxfw.EventContext, cause: anyerror) !void {
    if (self.form) |mapped| mapped.value.wipeKey();
    self.outcome = .{ .failed = .{ .cause = cause } };
    self.issue = "Couldn't begin sign-in. Try again.";
    try self.settle(.{ .screen = ctx });
}
fn advance(self: *Self, ctx: *vxfw.EventContext) !void {
    if (self.task.thread == null) return;
    self.task.mutex.lockUncancelable(self.init.?.io);
    const pending = self.shown_pending;
    self.shown_pending = false;
    self.task.mutex.unlock(self.init.?.io);
    ctx.redraw = ctx.redraw or pending;
    if (self.task.completed()) try self.settle(.{ .screen = ctx });
}

fn failedKind(self: *const Self, failure: @FieldType(Outcome, "failed")) core.Failure {
    return switch (failure.cause) {
        error.Reported => failure.shown orelse .login,
        error.LoginExpired => .expired,
        error.LoginDenied => .denied,
        error.ConnectionSuperseded => .superseded,
        else => if (self.attempt == .key or self.attempt == .recheck) .settings else .login,
    };
}

fn writeOutcome(self: *const Self, writer: *std.Io.Writer) !?anyerror {
    if (self.retention_failure) |failure| try writer.print("Replacement sign-in was not started: previous report could not be retained ({s}).\n", .{@errorName(failure.cause())});
    const outcome = self.outcome orelse return null;
    switch (outcome) {
        .cancelled => return null,
        .failed => |failure| {
            try writer.print("{s} ({s})\n", .{ failureText(self.failedKind(failure)), @errorName(failure.cause) });
            return @as(?anyerror, failure.cause);
        },
        .published => |published| {
            if (published.connection) |connection| switch (connection) {
                .saved => {},
                .uncertain => |uncertain| {
                    try writer.print("Connection settings publication unconfirmed ({s}). Retained private key ", .{@errorName(uncertain.cause)});
                    try @import("TerminalText.zig").writeShellWord(writer, uncertain.connection.key_file.slice());
                    try writer.writeAll(". Reopen Sign-in to recheck.\n");
                    return @as(?anyerror, uncertain.cause);
                },
                .failed => |failure| {
                    try writer.print("Connection not saved ({s})", .{@errorName(failure.cause)});
                    if (failure.cleanup) |cleanup| {
                        try writer.print("; private key cleanup unconfirmed ({s}). Remove the unreferenced staged key with: rm -f -- ", .{@errorName(cleanup.cause)});
                        try @import("TerminalText.zig").writeShellWord(writer, cleanup.key_file.slice());
                    }
                    try writer.writeByte('\n');
                    return @as(?anyerror, failure.cause);
                },
            };
            const default_error: ?anyerror = if (published.defaults) |_| null else |err| err;
            if (default_error) |err| try writer.print("Default not saved ({s}).\n", .{@errorName(err)});
            const activation = published.activation catch |err| {
                try writer.print("Host activation failed ({s}).\n", .{@errorName(err)});
                try writer.print("{s}\n", .{failureText(if (default_error != null) .defaults_and_host else .host)});
                return @as(?anyerror, default_error orelse err);
            };
            if (activation.launch) |*launch| {
                try host_launch.writeDiagnostics(launch, writer, 0);
                if (launch.outcome == .failed) {
                    try writer.print("{s}\n", .{failureText(if (default_error != null) .defaults_and_host else .host)});
                    return @as(?anyerror, default_error orelse launch.outcome.failed.cause.err);
                }
            }
            if (activation.pending) {
                try writer.writeAll("Connection saved, not active in the serving Host. Reopen Sign-in for pause/start instructions.\n");
                return @as(?anyerror, default_error orelse error.ConnectionNotActive);
            }
            if (default_error != null) try writer.print("{s}\n", .{failureText(.defaults)});
            return default_error;
        },
    }
}
fn settle(self: *Self, presentation: Presentation) anyerror!void {
    if (self.task.thread != null) {
        const joined = self.task.join();
        const shown = self.closeBrowser();
        defer if (self.form) |mapped| mapped.value.wipeKey();
        try joined;
        if (self.outcome) |*outcome| {
            if (outcome.* == .failed) outcome.failed.shown = shown;
        }
    }
    if (presentation != .screen) return self.finishReceipts(presentation);
    const ctx = presentation.screen;
    const outcome = self.outcome orelse return;
    switch (outcome) {
        .cancelled => try self.apply(ctx, self.state.step(.cancelled)),
        .failed => |failure| {
            if (failure.cause == error.ConnectionSuperseded) {
                self.closeForm();
                self.frozen = null;
                self.saved = null;
                self.issue = "Connection settings changed. Retry to reload them before connecting.";
            }
            _ = self.state.step(.{ .failed = self.failedKind(failure) });
        },
        .published => |published| {
            if (published.connection) |connection| switch (connection) {
                .saved => self.saved = connection,
                .uncertain => {
                    self.saved = connection;
                    self.issue = "Settings publication unconfirmed. Recheck before using this connection.";
                    _ = self.state.step(.pending);
                    ctx.redraw = true;
                    return;
                },
                .failed => |failure| {
                    self.issue = if (failure.cleanup != null) "Connection not saved. Private key cleanup unconfirmed; exiting Rui prints its path." else "Connection not saved. Edit the fields and retry.";
                    _ = self.state.step(.{ .failed = .settings });
                    ctx.redraw = true;
                    return;
                },
            };
            const default_error: ?anyerror = if (published.defaults) |_| null else |err| err;
            var activation = published.activation catch {
                _ = self.state.step(if (self.saved != null) .pending else .{ .failed = if (default_error != null) .defaults_and_host else .host });
                ctx.redraw = true;
                return;
            };
            if (activation.launch) |launch| if (launch.outcome == .failed) {
                _ = self.state.step(if (self.saved != null) .pending else .{ .failed = if (default_error != null) .defaults_and_host else .host });
                ctx.redraw = true;
                return;
            };
            if (activation.pending) {
                _ = self.state.step(.pending);
            } else {
                activation.default_failed = default_error != null;
                _ = self.state.step(.connected);
                if (self.on_done) |done| try done(self.userdata.?, ctx, activation);
            }
        },
    }
    ctx.redraw = true;
}

fn failureText(failure: core.Failure) []const u8 {
    return switch (failure) {
        .expired => "ChatGPT sign-in expired. Retry or choose another method.",
        .denied => "ChatGPT sign-in denied.",
        .unreachable_service => "Couldn't reach ChatGPT.",
        .answer => "Sign-in answer not valid.",
        .plan => "Plan use not allowed.",
        .host_id => "Unusable ~/.config/rui/host-id.",
        .login => "Sign-in failed.",
        .defaults => "Sign-in saved; couldn't save default.",
        .host => "Sign-in saved; Host didn't start.",
        .defaults_and_host => "Sign-in saved; default not saved; Host didn't start.",
        .settings => "Connection not saved.",
        .superseded => "Connection settings changed. Retry to reload the API form.",
        .uncertain => "Settings publication unconfirmed.",
    };
}

fn formEditable(self: *const Self) bool {
    return self.state.page == .api and self.task.thread == null and self.drawn.page == .api and self.drawn.attempt == self.state.attempt;
}

fn focusedAction(self: *const Self) ?core.Action {
    if (self.drawn.attempt != self.state.attempt or self.drawn.page != std.meta.activeTag(self.state.page)) return null;
    const focused = self.drawn.focused orelse return null;
    return if (focused.control == self.state.focus) focused.action else null;
}
fn activeField(self: *const Self) ?core.Field {
    if (!self.formEditable()) return null;
    const action = self.focusedAction() orelse return null;
    return if (action == .field) action.field else null;
}

fn freeze(self: *Self, attempt: core.Attempt, action: core.Action) !bool {
    if (attempt == .recheck or (attempt == .existing and action != .reuse and self.savedConnection() != null)) {
        if (self.frozen == null or self.frozen.?.provider != .openai or self.savedConnection() == null) return false;
        self.frozen.?.key = .{ .provided = "" };
        return true;
    }
    var intent = self.selectors;
    var provider: core.Provider = switch (attempt) {
        .browser => .chatgpt,
        .device => .codex,
        .key => .openai,
        else => if (self.frozen) |frozen| frozen.provider else .chatgpt,
    };
    if (action == .reuse) provider = action.reuse;
    if (attempt == .key) {
        const form = try self.ensureForm();
        if (form.refusedField()) |field| {
            _ = self.state.step(.{ .invalid = field });
            return false;
        }
        const endpoint_edit = form.endpointEdit();
        const endpoint = switch (endpoint_edit) {
            .unchanged => |value| value,
            .base => |base| @import("endpoint_value.zig").endpointUnder(self.initAllocator(), base, "/responses") catch {
                self.issue = "Use an HTTPS base URL without credentials, query or fragment.";
                _ = self.state.step(.{ .invalid = .base });
                return false;
            },
        };
        defer if (endpoint_edit == .base) self.initAllocator().free(endpoint);
        const using_saved = form.key.text().len == 0 and endpoint_edit == .unchanged and form.original.reusable();
        if (!using_saved and !api_key.valid(form.key.text())) {
            self.issue = "Enter one API key without spaces. Pasted keys stay masked.";
            _ = self.state.step(.{ .invalid = .key });
            return false;
        }
        const custom = !std.mem.eql(u8, endpoint, host_start.openai_endpoint);
        const model = if (form.model.text().len != 0) form.model.text() else if (!custom) @import("product_defaults.zig").recommended_model else "";
        if (!@import("model_capability.zig").validModelSyntax(model)) {
            self.issue = "Enter the model ID served by this custom Responses API.";
            _ = self.state.step(.{ .invalid = .model });
            return false;
        }
        if (self.target.len != 0) intent.store = self.target.slice();
        intent.provider = "openai";
        intent.model = model;
        self.frozen = .{ .intent = intent, .provider = .openai, .model = model, .key = if (using_saved) .{ .existing = &form.original } else .{ .provided = form.key.text() }, .endpoint = endpoint_edit };
    } else {
        intent.provider = intent.provider orelse @tagName(provider);
        self.frozen = .{ .intent = intent, .provider = provider, .model = intent.model orelse @import("product_defaults.zig").recommended_model, .key = .{ .provided = "" }, .endpoint = .{ .unchanged = host_start.openai_endpoint } };
    }
    self.issue = null;
    return true;
}
fn initAllocator(self: *Self) std.mem.Allocator {
    return if (self.init) |init_| init_.gpa else std.heap.c_allocator;
}

fn activateDrawn(self: *Self, ctx: *vxfw.EventContext, action: core.Action) !void {
    return self.activateDrawnWithFault(ctx, action, null);
}
fn activateDrawnWithFault(self: *Self, ctx: *vxfw.EventContext, action: core.Action, form_fault: ?FormFault) !void {
    if (self.drawn.attempt != self.state.attempt or self.drawn.page != std.meta.activeTag(self.state.page)) return;
    var next = self.state;
    const effect = next.step(.{ .activate = .{ .attempt = self.drawn.attempt, .page = self.drawn.page, .action = action } });
    if (effect == .cancel and self.task.thread != null and self.gate.load(.acquire) == .publishing) {
        self.issue = "Finishing publication. Its saved result cannot be cancelled.";
        ctx.redraw = true;
        return;
    }
    const needs_form = next.page == .api and self.form == null;
    if (effect == .start or needs_form) {
        self.stageReceipt(null) catch {
            self.issue = "Previous sign-in details could not be retained. Exit Rui to report them before retrying.";
            ctx.redraw = true;
            return;
        };
    }
    if (effect == .start) {
        if (!try self.freeze(effect.start, action)) {
            ctx.redraw = true;
            return;
        }
    }
    const previous = self.state.page;
    self.state = next;
    if (previous == .api and self.state.page != .api and effect != .start) if (self.form) |mapped| mapped.value.wipeKey();
    if (needs_form) {
        _ = self.ensureFormWithFault(form_fault) catch |err| {
            self.attempt = .key;
            self.frozen = null;
            self.saved = null;
            return self.setupFailed(ctx, err);
        };
        self.issue = null;
    }
    try self.apply(ctx, effect);
    ctx.consumeAndRedraw();
}

fn apply(self: *Self, ctx: *vxfw.EventContext, effect: core.Effect) !void {
    switch (effect) {
        .none => {},
        .start => |attempt| try self.begin(ctx, attempt),
        .cancel => {
            self.cancel();
            if (self.task.thread == null) _ = self.state.step(.cancelled);
        },
        .close => {
            if (self.form) |mapped| mapped.value.wipeKey();
            if (self.on_close) |close| try close(self.userdata.?, ctx);
        },
        .callback => self.editAddress(.confirm),
        .copy => |code| try self.copyClipboard(ctx, code.slice()),
        .copy_text => |text| try self.copyClipboard(ctx, text),
        .open => |link_| {
            const init_ = self.init orelse return;
            const opener = @import("os").linkOpener(init_.environ_map) orelse {
                self.issue = if (self.state.page == .browser) "No browser opener is available. Copy URL to open it manually." else "No browser opener is available. Open the displayed URL manually.";
                return;
            };
            opener.open(init_.io, link_) catch {
                self.issue = if (self.state.page == .browser) "Couldn't open a browser. Copy URL to open it manually." else "Couldn't open a browser. Open the displayed URL manually.";
                return;
            };
            self.issue = null;
        },
    }
}
fn copyClipboard(self: *Self, ctx: *vxfw.EventContext, text: []const u8) !void {
    const bytes = try ctx.alloc.dupe(u8, text);
    errdefer ctx.alloc.free(bytes);
    try ctx.addCmd(.{ .copy_to_clipboard = bytes });
    self.issue = "Sent to clipboard";
}

fn editAddress(self: *Self, change: Edit) void {
    const mapped = self.browser orelse return;
    const locked = self.task.thread != null;
    if (locked) self.task.mutex.lockUncancelable(self.init.?.io);
    defer if (locked) self.task.mutex.unlock(self.init.?.io);
    mapped.value.edit(change);
}
fn formEvent(self: *Self, field: core.Field, input: vxfw.Event, pasting: bool) !void {
    if (!self.formEditable()) return;
    const form = try self.ensureForm();
    const editor = form.editor(field);
    _ = @import("panel_editor.zig").event(editor, input, pasting, &self.issue);
    if (input == .paste_end) {
        const text = editor.text();
        const trimmed = api_key.trimNewline(text);
        if (trimmed.len != text.len) {
            _ = editor.set(trimmed, @min(editor.cursor(), trimmed.len));
            const bank: []u8 = switch (field) {
                .base => &form.base_bank,
                .key => &form.key_bank,
                .model => &form.model_bank,
            };
            std.crypto.secureZero(u8, bank[trimmed.len..]);
        }
    }
}
fn event(raw: *anyopaque, ctx: *vxfw.EventContext, input: vxfw.Event) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    if (input == .tick) return self.advance(ctx);
    defer ctx.consumeEvent();
    const focused_action = self.focusedAction();
    if (input == .focus_out and self.paste != .none) {
        if (self.paste == .field) try self.formEvent(self.paste.field, input, false);
        self.paste = .ignore;
        ctx.redraw = true;
        return;
    }
    if (input == .paste_start) {
        self.paste = if (self.activeField()) |field| .{ .field = field } else if (focused_action != null and focused_action.? == .callback) .callback else .ignore;
        if (self.paste == .field) try self.formEvent(self.paste.field, input, true);
        return;
    }
    if (input == .paste_end) {
        if (self.paste == .field) try self.formEvent(self.paste.field, input, false);
        self.paste = .none;
        ctx.redraw = true;
        return;
    }
    if (self.paste != .none) {
        if (input == .key_press) switch (self.paste) {
            .field => |field| try self.formEvent(field, input, true),
            .callback => if (focused_action != null and focused_action.? == .callback) {
                if (input.key_press.text) |text| self.editAddress(.{ .append = text });
            },
            else => {},
        };
        ctx.redraw = true;
        return;
    }
    if (input == .mouse) {
        const mouse = input.mouse;
        if (mouse.type == .press and mouse.button == .left) for (self.drawn.hits) |hit| {
            if (mouse.row == hit.row and mouse.col >= hit.start and mouse.col < hit.end) return self.activateDrawn(ctx, hit.action);
        };
        return;
    }
    if (input != .key_press) return;
    const key = input.key_press;
    if (key.matchExact('c', .{ .ctrl = true })) {
        ctx.quit = true;
        return;
    }
    if (key.matchExact(vaxis.Key.escape, .{})) return self.activateDrawn(ctx, .back);
    if (key.matchExact(vaxis.Key.tab, .{}) or key.matchExact(vaxis.Key.tab, .{ .shift = true })) {
        _ = self.state.step(.{ .move = !key.mods.shift });
        ctx.redraw = true;
        return;
    }
    if (self.activeField()) |field| {
        if (key.matchExact(vaxis.Key.enter, .{})) {
            const editor = (try self.ensureForm()).editor(field);
            if (@import("panel_editor.zig").event(editor, input, false, &self.issue) == .submit) _ = self.state.step(.{ .move = true });
            ctx.redraw = true;
        } else try self.formEvent(field, input, false);
        ctx.redraw = true;
        return;
    }
    if (focused_action != null and focused_action.? == .callback) {
        if (key.matchExact(vaxis.Key.enter, .{})) self.editAddress(.confirm) else if (key.matchExact(vaxis.Key.backspace, .{})) self.editAddress(.erase) else if (key.text) |text| self.editAddress(.{ .append = text });
        ctx.redraw = true;
        return;
    }
    if (key.matchExact(vaxis.Key.up, .{}) or key.matchExact(vaxis.Key.down, .{}) or key.matchExact(vaxis.Key.left, .{}) or key.matchExact(vaxis.Key.right, .{})) {
        _ = self.state.step(.{ .move = key.matchExact(vaxis.Key.down, .{}) or key.matchExact(vaxis.Key.right, .{}) });
        ctx.redraw = true;
    } else if (key.matchExact(vaxis.Key.enter, .{})) {
        if (focused_action) |action| try self.activateDrawn(ctx, action);
    } else if (key.matchExact('c', .{}) and self.drawn.copy != null) {
        try self.activateDrawn(ctx, .{ .copy = self.drawn.copy.? });
    }
}

const Button = struct { label: []const u8, control: core.Control, action: ?core.Action };
fn button(buttons: *std.ArrayList(Button), alloc: std.mem.Allocator, label: []const u8, control: core.Control, action: ?core.Action) !void {
    try buttons.append(alloc, .{ .label = if (std.mem.eql(u8, label, "Close")) try alloc.dupe(u8, label) else try std.fmt.allocPrint(alloc, "[ {s} ]", .{label}), .control = control, .action = action });
}
const Row = struct { label: []const u8, value: []const u8 = "", control: ?core.Control = null, action: ?core.Action = null, caret: ?u16 = null };
fn append(rows: *std.ArrayList(Row), alloc: std.mem.Allocator, label: []const u8, value: []const u8, control: ?core.Control, action: ?core.Action) !void {
    try rows.append(alloc, .{ .label = label, .value = value, .control = control, .action = action });
}
const EditView = struct { text: []const u8, caret: u16 = 0 };
fn editView(ctx: vxfw.DrawContext, editor: *const Editor, masked: bool, width: u16) !EditView {
    if (width == 0) return .{ .text = "" };
    if (masked) {
        const start = editor.cursor() -| (width - 1);
        const text = try ctx.arena.alloc(u8, @min(editor.text().len - start, width));
        @memset(text, '*');
        return .{ .text = text, .caret = @intCast(@min(editor.cursor() - start, width - 1)) };
    }
    const text = editor.text();
    var start: usize = 0;
    while (start < editor.cursor() and ctx.stringWidth(text[start..editor.cursor()]) >= width) start += std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
    return .{ .text = text[start..], .caret = @intCast(@min(ctx.stringWidth(text[start..editor.cursor()]), width - 1)) };
}
fn appendEditor(rows: *std.ArrayList(Row), ctx: vxfw.DrawContext, label: []const u8, editor: *const Editor, field: core.Field, width: u16, placeholder: []const u8) !void {
    const view = try editView(ctx, editor, field == .key, width);
    try append(rows, ctx.arena, label, if (editor.text().len == 0) placeholder else view.text, switch (field) {
        .base => .base,
        .key => .key,
        .model => .model,
    }, .{ .field = field });
    rows.items[rows.items.len - 1].caret = view.caret;
}

fn hostCommand(alloc: std.mem.Allocator, operation: []const u8, store: []const u8) std.mem.Allocator.Error![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    writer.writer.print("rui host {s} --store ", .{operation}) catch return error.OutOfMemory;
    @import("TerminalText.zig").writeShellWord(&writer.writer, store) catch return error.OutOfMemory;
    return writer.written();
}
fn appendWrapped(rows: *std.ArrayList(Row), ctx: vxfw.DrawContext, label: []const u8, text: []const u8, control: core.Control, action: core.Action, width: u16) !void {
    try appendLines(rows, ctx, label, text, control, action, width, .cells);
}
/// Prose (Status) breaks at spaces so a sentence never clips; links and commands fill each line.
fn appendProse(rows: *std.ArrayList(Row), ctx: vxfw.DrawContext, label: []const u8, text: []const u8, width: u16) !void {
    try appendLines(rows, ctx, label, text, null, null, width, .words);
}
fn appendLines(rows: *std.ArrayList(Row), ctx: vxfw.DrawContext, label: []const u8, text: []const u8, control: ?core.Control, action: ?core.Action, width: u16, breaks: enum { cells, words }) !void {
    const value_width = Panel.valueWidth(width);
    var at: usize = 0;
    var first = true;
    while (first or (at < text.len and value_width > 0)) {
        var part = if (value_width > 0) line.fit(ctx, text[at..], value_width).text else "";
        if (breaks == .words and at + part.len < text.len and text[at + part.len] != ' ') {
            if (std.mem.lastIndexOfScalar(u8, part, ' ')) |space| part = part[0 .. space + 1];
        }
        if (!first and part.len == 0) break;
        const shown = if (breaks == .words) std.mem.trimEnd(u8, part, " ") else part;
        if (first) try append(rows, ctx.arena, label, shown, control, action) else try append(rows, ctx.arena, "", shown, null, if (action) |act| if (act == .open) act else null else null);
        at += part.len;
        if (breaks == .words) while (at < text.len and text[at] == ' ') : (at += 1) {};
        first = false;
    }
}

/// Derived each draw from the editors' locks, so the message cannot outlive the lock.
fn pasteStatus(self: *const Self, a: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
    if (self.state.page != .api) return null;
    const mapped = self.form orelse return null;
    const field = mapped.value.refusedField() orelse return null;
    return try std.fmt.allocPrint(a, "Paste refused in {s}. Press Enter or edit it to continue.", .{mapped.value.label(field)});
}
fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    self.drawn = .{ .attempt = self.state.attempt, .page = std.meta.activeTag(self.state.page) };
    if (size.width == 0 or size.height == 0) return .{ .size = size, .widget = self.widget(), .buffer = &.{}, .children = &.{} };
    // With room, the dialog is a card (Dialog owns its geometry and palette).
    const look = self.palette();
    const fit = Dialog.bound(size);
    const width = fit.width;
    var rows: std.ArrayList(Row) = .empty;
    var buttons: std.ArrayList(Button) = .empty;
    var code_field: ?usize = null;
    const a = ctx.arena;
    const title: []const u8 = switch (self.state.page) {
        .account => "Welcome to Rui",
        .method => "ChatGPT account",
        .api => "Connect with an API key",
        .browser => "Continue in your browser",
        .device => "Use a device code",
        .stopping => "Stopping sign-in",
        .saving => "Connecting",
        .failed => "Sign-in needs attention",
        .pending => "Saved, not active",
        .connected => "Connected",
    };
    var code: core.Code = .{};
    var browser_link: []const u8 = "";
    var browser_typed: usize = 0;
    var browser_checking = false;
    var browser_stray = false;
    {
        const locked = self.task.thread != null;
        if (locked) self.task.mutex.lockUncancelable(self.init.?.io);
        defer if (locked) self.task.mutex.unlock(self.init.?.io);
        code = self.code;
        if (self.browser) |mapped| {
            browser_link = try a.dupe(u8, mapped.value.link.slice());
            browser_typed = mapped.value.len - mapped.value.confirmed;
            browser_checking = mapped.value.checking;
            browser_stray = mapped.value.stray;
        }
    }
    const device_link = "https://auth.openai.com/codex/device";
    switch (self.state.page) {
        .account => {
            try append(&rows, a, "ChatGPT", "Use your subscription", .chatgpt, .{ .choose = .chatgpt });
            try append(&rows, a, "API key", "OpenAI or a custom Responses API", .api_key, .{ .choose = .api_key });
            try button(&buttons, a, "Close", .close, .close);
        },
        .method => {
            try append(&rows, a, "Browser", "Recommended. Paste callback if needed.", .browser, .{ .method = .browser });
            try append(&rows, a, "Device code", "Copy a code and approve in a browser.", .device, .{ .method = .device });
            const readiness = if (self.init != null and self.ready != null) self.ready.?(self.init.?, self.target.slice()) else core.Readinesses.initFill(.missing);
            const usable: ?core.Provider = if (readiness.get(.chatgpt).usable()) .chatgpt else if (readiness.get(.codex).usable()) .codex else null;
            try append(&rows, a, "Use saved login", if (usable != null) "Reuse this account's local sign-in" else "No usable saved ChatGPT sign-in", .reuse, if (usable) |provider| .{ .reuse = provider } else null);
            try button(&buttons, a, "Back", .back, .back);
        },
        .api => {
            if (self.form) |mapped| {
                const form = mapped.value;
                const field_width = Panel.valueWidth(width) -| 1;
                try appendEditor(&rows, ctx, form.label(.base), &form.base, .base, field_width, "HTTPS base URL");
                try appendEditor(&rows, ctx, form.label(.key), &form.key, .key, field_width, if (form.original.reusable()) "Existing source (type to replace)" else "Paste your API key");
                try appendEditor(&rows, ctx, form.label(.model), &form.model, .model, field_width, "Required for custom services");
                try button(&buttons, a, "Connect", .connect, .connect);
                try button(&buttons, a, "Back", .back, .back);
            }
        },
        .browser => {
            const value_width = Panel.valueWidth(width);
            const visible = line.fit(ctx, browser_link, value_width).text;
            const link_label = if (visible.len < browser_link.len and value_width > 3)
                try std.fmt.allocPrint(a, "{s}...", .{line.fit(ctx, browser_link, value_width - 3).text})
            else
                visible;
            try append(&rows, a, "Sign-in URL", if (browser_link.len != 0) link_label else "Connecting to ChatGPT...", .link, if (browser_link.len != 0) .{ .open = browser_link } else null);
            const mask = try a.alloc(u8, @min(browser_typed, Panel.valueWidth(width) -| 1));
            @memset(mask, '*');
            try append(&rows, a, "Paste callback", if (browser_typed != 0) mask else if (browser_stray) "Not the sign-in address. Paste again." else if (browser_checking) "Checking address..." else "Paste final browser address, then Enter", .callback, .callback);
            try button(&buttons, a, "Open browser", .open_page, if (browser_link.len != 0) .{ .open = browser_link } else null);
            try button(&buttons, a, "Copy URL", .copy_url, if (browser_link.len != 0) .{ .copy_url = browser_link } else null);
            try button(&buttons, a, "Change method", .switch_method, .switch_method);
            try button(&buttons, a, "Back", .back, .back);
        },
        .device => {
            try appendWrapped(&rows, ctx, "Open URL", device_link, .link, .{ .open = device_link }, width);
            code_field = rows.items.len;
            try append(&rows, a, "Code", if (code.len != 0) try a.dupe(u8, code.slice()) else "Waiting for code...", null, null);
            try button(&buttons, a, "Copy code", .copy_code, if (code.len != 0) .{ .copy = code } else null);
            try button(&buttons, a, "Open browser", .open_page, .{ .open = device_link });
            try button(&buttons, a, "Change method", .switch_method, .switch_method);
            try button(&buttons, a, "Back", .back, .back);
        },
        .stopping => try append(&rows, a, "Please wait", "Ending the sign-in...", null, null),
        .saving => {
            try append(&rows, a, "Please wait", "Saving your sign-in...", null, null);
            try button(&buttons, a, "Back", .back, .back);
        },
        .failed => |failure| {
            try append(&rows, a, "Result", failureText(failure.failure), null, null);
            if (self.launchSummary()) |report| try append(&rows, a, "Host", report.words(), null, null);
            try button(&buttons, a, "Retry", .retry, .retry);
            try button(&buttons, a, "Back", .back, .back);
        },
        .pending => {
            try append(&rows, a, "Saved", "The serving Host may still use old settings.", null, null);
            try append(&rows, a, "Warning", "Pause interrupts ALL chats on this Store.", null, null);
            const pause_command = try hostCommand(a, "pause", self.target.slice());
            const start_command = try hostCommand(a, "start", self.target.slice());
            try appendWrapped(&rows, ctx, "Copy pause cmd", pause_command, .pause_command, .{ .command = pause_command }, width);
            try appendWrapped(&rows, ctx, "Copy start cmd", start_command, .start_command, .{ .command = start_command }, width);
            if (self.launchSummary()) |report| try append(&rows, a, "Host", report.words(), null, null);
            try button(&buttons, a, "Recheck", .recheck, .recheck);
            try button(&buttons, a, "Back", .back, .back);
            try button(&buttons, a, "Return", .close, .close);
        },
        .connected => {
            try append(&rows, a, "Connected", "New chats use this sign-in.", null, null);
            try button(&buttons, a, "Close", .close, .close);
        },
    }
    if (try self.pasteStatus(a)) |message| {
        try appendProse(&rows, ctx, "Status", message, width);
    } else if (self.issue) |issue| try appendProse(&rows, ctx, "Status", issue, width);
    const fields = try a.alloc(Panel.Field, rows.items.len);
    const labels = try a.alloc([]const u8, buttons.items.len);
    var selected: usize = 0;
    for (rows.items, fields, 0..) |row, *field, i| {
        field.* = .{ .label = row.label, .value = row.value, .selectable = row.control != null or row.action != null };
        if (row.control == self.state.focus) {
            selected = i;
            self.drawn.focused = if (row.action) |action| .{ .control = row.control.?, .action = action } else null;
        }
    }
    var button_width: usize = 3;
    for (buttons.items, labels, 0..) |entry, *label, i| {
        label.* = entry.label;
        button_width += @as(usize, ctx.stringWidth(entry.label)) + if (i == 0) @as(usize, 0) else 5;
        if (entry.control == self.state.focus) {
            selected = rows.items.len + i;
            self.drawn.focused = if (entry.action) |action| .{ .control = entry.control, .action = action } else null;
        }
    }
    var footer_surface: ?vxfw.Surface = null;
    if (width > 6 and self.state.page == .device) {
        const footer = try a.create(vxfw.Text);
        footer.* = .{ .text = "C copies code. Esc back.", .style = look.quiet, .width_basis = .parent };
        const natural = try footer.draw(ctx.withConstraints(.{}, .{ .width = width - 6 }));
        if (natural.size.height + 3 + size.height - fit.height <= size.height) footer_surface = natural;
    }
    const footer_height = if (footer_surface) |surface| surface.size.height else @as(u16, 0);
    var panel: Panel = .{
        .title = title,
        .subtitle = if (self.state.page == .account) "Sign in to begin. Your sign-in never enters a chat." else null,
        .unicode = self.unicode,
        .fields = fields,
        .actions = labels,
        .action_gap = 1,
        .stacked_actions = button_width > width,
        .natural_height = true,
        .top_rule = !Dialog.framed(size),
        .centered_heading = true,
        .selected = selected,
        .ground = look.ground,
        .selection = look.selection,
        .quiet = look.quiet,
        .title_style = look.title,
        .rule = look.stitch(.horizontal),
        .scroll = self.scroll,
    };
    const panel_surface = try panel.widget().draw(ctx.withConstraints(.{}, .{ .width = width, .height = fit.height - footer_height }));
    const height = panel_surface.size.height + footer_height;
    const origin = Dialog.origin(size, .{ .width = width, .height = height });
    var child = try vxfw.Surface.init(ctx.cell_arena, self.widget(), .{ .width = width, .height = height });
    @memset(child.buffer, .{ .style = look.ground });
    @memcpy(child.buffer[0..panel_surface.buffer.len], panel_surface.buffer);
    child.cursor = panel_surface.cursor;
    const extra: usize = @intFromBool(footer_surface != null);
    const parts = try a.alloc(vxfw.SubSurface, panel_surface.children.len + extra);
    @memcpy(parts[0..panel_surface.children.len], panel_surface.children);
    if (footer_surface) |surface| parts[parts.len - 1] = .{ .origin = .{ .row = @intCast(panel_surface.size.height), .col = 3 }, .surface = surface };
    child.children = parts;
    self.scroll = panel.scroll;
    if (code_field) |index| if (panel.fieldRow(index) != null and code.len != 0 and ctx.stringWidth(code.slice()) <= Panel.valueWidth(width)) {
        self.drawn.copy = code;
    };
    var hits: std.ArrayList(Hit) = .empty;
    var focused_visible = false;
    for (panel.targets) |target_| {
        const field = target_.index < rows.items.len;
        const action_ = if (field) rows.items[target_.index].action else buttons.items[target_.index - rows.items.len].action;
        if (field) if (rows.items[target_.index].caret) |caret| {
            if (target_.index == selected and Panel.valueWidth(width) > 0) child.cursor = .{ .row = target_.row, .col = @min(Panel.valueEnd(width) - 1, Panel.value_column + caret) };
        };
        if (action_) |action| {
            if (action == .copy and self.drawn.copy == null) continue;
            if (target_.index == selected) focused_visible = true;
            if (action == .open and field) {
                const linked = @import("ConversationViewport.zig").linkedSegment(rows.items[target_.index].value, look.ground, action.open);
                for (@min(Panel.value_column, Panel.valueEnd(width))..Panel.valueEnd(width)) |col| child.buffer[@as(usize, target_.row) * width + col].link = linked.link;
            }
            try hits.append(a, .{ .row = @intCast(origin.row + target_.row), .start = @intCast(origin.col + target_.start), .end = @intCast(origin.col + target_.end), .action = action });
        }
    }
    if (height <= 2) {
        @memset(child.buffer, .{ .style = look.ground });
        const selected_action = if (selected < rows.items.len) rows.items[selected].action else buttons.items[selected - rows.items.len].action;
        const selected_label = if (selected < rows.items.len) rows.items[selected].label else buttons.items[selected - rows.items.len].label;
        if (selected_action != null and selected_action.? == .copy and selected_action.?.copy.len <= width) {
            self.drawn.copy = selected_action.?.copy;
            _ = line.paint(ctx, child, try a.dupe(u8, selected_action.?.copy.slice()), 0, 0, look.selection, width);
        } else if (selected_action != null and selected_action.? == .field and self.form != null) {
            const field = selected_action.?.field;
            const view = try editView(ctx, self.form.?.value.editor(field), field == .key, width);
            _ = line.paint(ctx, child, view.text, 0, 0, look.selection, width);
            child.cursor = .{ .row = 0, .col = view.caret };
        } else {
            if (self.state.page == .device) self.drawn.copy = null;
            _ = line.paint(ctx, child, selected_label, 0, 0, look.selection, width);
        }
        if (selected_action) |action| {
            if (action != .copy or self.drawn.copy != null) {
                try hits.append(a, .{ .row = @intCast(origin.row), .start = @intCast(origin.col), .end = @intCast(origin.col + width), .action = action });
                focused_visible = true;
            }
        }
    }
    self.drawn.hits = hits.items;
    if (!focused_visible) self.drawn.focused = null;
    return Dialog.lay(ctx, self.widget(), look, child, size);
}

fn palette(self: *const Self) Dialog.Look {
    var caps = self.caps.*;
    caps.unicode = self.unicode;
    return .of(caps);
}

const default_caps: @import("overview_view.zig").Caps = .{};

test "Sign-in paste source moves confirmed lines across reads, keeps typing, and wipes what it moved" {
    const mapped = try pages.Mapped(Browser).map();
    defer mapped.unmap();
    const browser = mapped.value;
    browser.init();
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), browser.take(&buffer));
    browser.edit(.{ .append = "not it" });
    try std.testing.expectEqual(@as(?usize, null), browser.take(&buffer));
    browser.edit(.confirm);
    browser.edit(.{ .append = "http://127.0.0.1:1455/" });
    browser.edit(.{ .append = "auth/callback?code=c" });
    browser.edit(.confirm);
    browser.edit(.{ .append = "still typing" });
    var moved: std.ArrayList(u8) = .empty;
    defer moved.deinit(std.testing.allocator);
    var reads: usize = 0;
    while (browser.take(&buffer)) |count| {
        try std.testing.expect(count != 0);
        try moved.appendSlice(std.testing.allocator, buffer[0..count]);
        reads += 1;
    }
    try std.testing.expect(reads > 1);
    try std.testing.expectEqualStrings("not it\nhttp://127.0.0.1:1455/auth/callback?code=c\n", moved.items);
    try std.testing.expectEqualStrings("still typing", browser.entry[0..browser.len]);
    for (browser.entry[browser.len..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    browser.edit(.erase);
    try std.testing.expectEqualStrings("still typin", browser.entry[0..browser.len]);
    for (0..browser.entry.len / 64 + 1) |_| browser.edit(.{ .append = &@as([64]u8, @splat('x')) });
    try std.testing.expect(browser.overflow);
    browser.edit(.confirm);
    try std.testing.expect(browser.stray and !browser.overflow);
    try std.testing.expectEqual(@as(usize, 0), browser.len);
    try std.testing.expectEqual(@as(?usize, null), browser.take(&buffer));
    for (browser.entry) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    browser.edit(.{ .append = "abc" });
    browser.edit(.confirm);
    try std.testing.expect(!browser.stray and browser.checking);
    browser.edit(.{ .append = "def" });
    browser.edit(.clear);
    try std.testing.expectEqual(@as(usize, 0), browser.len);
    try std.testing.expectEqual(@as(?usize, null), browser.take(&buffer));
    for (browser.entry) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

const BrowserRig = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    argv: [1][*:0]const u8 = .{"rui"},
    page: Self = .{},
    ctx: vxfw.EventContext = undefined,

    fn open(self: *BrowserRig) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var home_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const home = home_bytes[0..try self.tmp.dir.realPath(std.testing.io, &home_bytes)];
        self.env = .init(std.testing.allocator);
        errdefer self.env.deinit();
        try self.env.put("HOME", home);
        try self.env.put("RUI_TEST_LOGIN", "waiting");
        self.arena = .init(std.testing.allocator);
        const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &self.argv }, .environ = .empty }, .arena = &self.arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = &self.env, .preopens = .empty };
        self.page = .{ .init = init, .ready = missing, .scratch = testingScratch };
        self.ctx = .{ .io = std.testing.io, .alloc = self.arena.allocator(), .cmds = .empty };
    }

    fn close(self: *BrowserRig) void {
        self.page.stop() catch @panic("browser attempt escaped its test");
        std.debug.assert(self.page.browser == null);
        self.arena.deinit();
        self.env.deinit();
        self.tmp.cleanup();
    }

    fn missing(_: std.process.Init, _: []const u8) core.Readinesses {
        return .initFill(.missing);
    }

    fn send(self: *BrowserRig, bytes: []const u8) !void {
        var events: @import("testing/app_events.zig").Events = .init(bytes);
        while (events.next()) |input| {
            _ = try testingDraw(&self.page, self.arena.allocator(), 90, 28);
            try self.page.widget().handleEvent(&self.ctx, input);
        }
    }

    fn wait(self: *BrowserRig, comptime condition: fn (*Self) bool) !void {
        const poll = @import("test_poll");
        try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(10)), &self.page, condition);
    }

    fn browserField(page: *Self, comptime field: []const u8) bool {
        page.task.mutex.lockUncancelable(page.init.?.io);
        defer page.task.mutex.unlock(page.init.?.io);
        const browser = (page.browser orelse return false).value;
        return if (comptime std.mem.eql(u8, field, "link")) browser.link.len != 0 else @field(browser, field);
    }

    fn linked(page: *Self) bool {
        return browserField(page, "link");
    }

    fn strayed(page: *Self) bool {
        return browserField(page, "stray");
    }

    fn deviceCode(page: *Self) bool {
        page.task.mutex.lockUncancelable(page.init.?.io);
        defer page.task.mutex.unlock(page.init.?.io);
        return page.code.len != 0;
    }

    fn port(self: *BrowserRig) ![]const u8 {
        const link = self.page.browser.?.value.link.slice();
        const at = (std.mem.indexOf(u8, link, "127.0.0.1%3A") orelse return error.TestUnexpectedResult) + "127.0.0.1%3A".len;
        var end = at;
        while (end < link.len and std.ascii.isDigit(link[end])) end += 1;
        return try self.arena.allocator().dupe(u8, link[at..end]);
    }
};

fn testingDraw(page: *Self, alloc: std.mem.Allocator, width: u16, height: u16) !vxfw.Surface {
    return page.widget().draw(.{ .arena = alloc, .cell_arena = alloc, .min = .{}, .max = .{ .width = width, .height = height }, .cell_size = .{} });
}
fn testingSend(page: *Self, ctx: *vxfw.EventContext, bytes: []const u8, width: u16, height: u16) !void {
    var events: @import("testing/app_events.zig").Events = .init(bytes);
    while (events.next()) |input| {
        _ = try testingDraw(page, ctx.alloc, width, height);
        try page.widget().handleEvent(ctx, input);
    }
}
fn testingText(surface: vxfw.Surface, alloc: std.mem.Allocator) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (surface.buffer) |cell| try text.appendSlice(alloc, cell.char.grapheme);
    for (surface.children) |child| try text.appendSlice(alloc, try testingText(child.surface, alloc));
    return text.items;
}
fn testingActivation(init_: std.process.Init) !Activation {
    var answer: Activation = .{ .binding = .{}, .store = .{} };
    try answer.binding.provider.set("openai");
    try answer.binding.model.set(@import("product_defaults.zig").recommended_model);
    try answer.store.set(init_.environ_map.get("HOME").?);
    return answer;
}
fn testingCompleted(page: *Self) bool {
    return page.task.completed();
}

test "SUI-134 Sign-in departure keeps a handover's unconfirmed certainty" {
    const activation = @import("host_activation.zig");
    const cause = try @import("protocol.zig").Bounded(64).from("OutOfMemory");
    const Case = struct { selected: activation.Selected, expected: anyerror };
    const cases = [_]Case{
        .{ .selected = .{ .outcome = .{ .unconfirmed = .verifying } }, .expected = error.HostRestartUnconfirmed },
        .{ .selected = .{ .outcome = .{ .faulted = .{ .effect = .stop, .cause = cause } } }, .expected = error.HostRestartUnconfirmed },
        .{ .selected = .{ .outcome = .{ .faulted = .{ .effect = .resolve_target, .cause = cause } } }, .expected = error.HostRestartFailed },
        .{ .selected = .{ .outcome = .{ .failed = .stopping } }, .expected = error.HostRestartFailed },
        .{ .selected = .{ .failed = .of(.observation, error.OutOfMemory) }, .expected = error.HostRestartFailed },
        .{ .selected = .{ .failed = .of(.selection, error.NoVerifiedRelease) }, .expected = error.HostRestartFailed },
    };
    for (cases) |row| {
        var launch: host_launch.Result = .failed(.setup, error.HostRestartFailed);
        host_start.handoverFailed(&launch, row.selected);
        var page: Self = .{
            .state = .{ .page = .{ .saving = .existing } },
            .outcome = .{ .published = .{ .defaults = {}, .activation = .{ .binding = .{}, .store = .{}, .launch = launch } } },
        };
        var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer report.deinit();
        try std.testing.expectError(row.expected, page.stopTo(&report.writer));
    }
}

test "Sign-in guided fields keep edits focus caret masking and paste authority" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    var page: Self = .{};
    defer page.closeForm();
    try testingSend(&page, &ctx, "\x1b[B\r", 90, 28);
    try std.testing.expect(page.state.page == .api and page.state.focus == .key);
    try testingSend(&page, &ctx, "\x1b[200~sk-private-key\n\x1b[201~", 90, 28);
    try std.testing.expect(page.task.thread == null and page.state.page == .api);
    const form = page.form.?.value;
    try std.testing.expectEqualStrings("sk-private-key", form.key.text());
    var surface = try testingDraw(&page, ctx.alloc, 90, 28);
    var text = try testingText(surface, ctx.alloc);
    try std.testing.expect(std.mem.indexOf(u8, text, "sk-private-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "**************") != null);
    try std.testing.expect(surface.children[0].surface.cursor != null);
    try testingSend(&page, &ctx, "\x1b[D\x7fX", 90, 28);
    try std.testing.expectEqualStrings("sk-private-kXy", form.key.text());
    try testingSend(&page, &ctx, "\x1b[Z", 90, 28);
    try std.testing.expectEqual(core.Control.base, page.state.focus);
    _ = form.base.set("https://custom.invalid/v1", "https://custom.invalid/v1".len);
    try testingSend(&page, &ctx, "\t\t", 90, 28);
    try std.testing.expectEqual(core.Control.model, page.state.focus);
    try testingSend(&page, &ctx, "\x1b[200~c\t\r\x1b[201~", 90, 28);
    try std.testing.expectEqual(core.Control.model, page.state.focus);
    try std.testing.expect(page.task.thread == null and page.state.page == .api);
    _ = form.model.set("service-model", "service-model".len);
    form.model.release();
    try std.testing.expect(try page.freeze(.key, .connect));
    try std.testing.expectEqualStrings("service-model", page.frozen.?.intent.model.?);
    try std.testing.expectEqualStrings("openai", page.frozen.?.intent.provider.?);
    @memset(&form.key_bank, 'q');
    form.wipeKey();
    for (form.key_bank) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    _ = form.key.set("secret", 3);
    page.state.focus = .key;
    for ([_]u16{ 1, 2 }) |height| {
        surface = try testingDraw(&page, ctx.alloc, 8, height);
        text = try testingText(surface, ctx.alloc);
        try std.testing.expect(std.mem.indexOf(u8, text, "secret") == null);
        try std.testing.expect(surface.children[0].surface.cursor != null);
    }
}

test "Sign-in keyboard activation and editing require the committed focused control" {
    const Input = struct {
        fn send(page: *Self, ctx: *vxfw.EventContext, bytes: []const u8) !void {
            var events: @import("testing/app_events.zig").Events = .init(bytes);
            while (events.next()) |input| try page.widget().handleEvent(ctx, input);
        }
    };
    for ([_]core.State{ .{}, .{ .page = .method, .focus = .browser } }) |initial| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var page: Self = .{ .state = initial };
        defer page.closeForm();
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try Input.send(&page, &ctx, "\t\r");
        try std.testing.expectEqual(std.meta.activeTag(initial.page), std.meta.activeTag(page.state.page));
        try std.testing.expectEqual(@as(u64, 0), page.state.attempt);
        try std.testing.expect(page.task.thread == null);
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try Input.send(&page, &ctx, "\r");
        try std.testing.expectEqual(@as(std.meta.Tag(core.Page), if (initial.page == .account) .api else .device), std.meta.activeTag(page.state.page));
    }
    for (std.enums.values(core.Field)) |field| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var page: Self = .{ .state = .{ .page = .api, .focus = switch (field) {
            .base => .base,
            .key => .key,
            .model => .model,
        } } };
        defer page.closeForm();
        const form = try page.ensureForm();
        _ = form.key.set("sk-before", "sk-before".len);
        _ = form.base.set("https://before.example/v1", "https://before.example/v1".len);
        _ = form.model.set("model-before", "model-before".len);
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try Input.send(&page, &ctx, "\t\rchanged\x1b[200~pasted\x1b[201~");
        try std.testing.expect(page.state.page == .api and page.state.attempt == 0 and page.frozen == null);
        try std.testing.expectEqualStrings("sk-before", form.key.text());
        try std.testing.expectEqualStrings("https://before.example/v1", form.base.text());
        try std.testing.expectEqualStrings("model-before", form.model.text());
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try Input.send(&page, &ctx, if (field == .model) "\r" else "Z");
        switch (field) {
            .base => try std.testing.expectEqualStrings("sk-beforeZ", form.key.text()),
            .key => try std.testing.expectEqualStrings("model-beforeZ", form.model.text()),
            .model => try std.testing.expect(page.state.page == .saving and page.frozen != null),
        }
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    var page: Self = .{ .state = .{ .page = .browser, .focus = .callback } };
    page.browser = try pages.Mapped(Browser).map();
    defer _ = page.closeBrowser();
    const browser = page.browser.?.value;
    browser.init();
    browser.edit(.{ .append = "before" });
    _ = try testingDraw(&page, ctx.alloc, 90, 28);
    try Input.send(&page, &ctx, "\t\rchanged\x1b[200~pasted\x1b[201~");
    try std.testing.expectEqualStrings("before", browser.entry[0..browser.len]);
    try std.testing.expectEqual(@as(usize, 0), browser.confirmed);
    page.state.focus = .callback;
    _ = try testingDraw(&page, ctx.alloc, 90, 28);
    try Input.send(&page, &ctx, "\x1b[200~");
    page.state.focus = .open_page;
    try Input.send(&page, &ctx, "pasted\x1b[201~");
    try std.testing.expectEqualStrings("before", browser.entry[0..browser.len]);
    page.state.focus = .callback;
    _ = try testingDraw(&page, ctx.alloc, 90, 28);
    try Input.send(&page, &ctx, "Z\r");
    try std.testing.expectEqualStrings("beforeZ\n", browser.entry[0..browser.len]);
    try std.testing.expectEqual(browser.len, browser.confirmed);
}

test "Sign-in queued edits cannot change frozen fields before redraw or worker join" {
    const Gate = struct {
        page: *Self,
        entered: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        key: core.Code = .{},
        base: core.Code = .{},
        model: core.Code = .{},

        fn ready(gate: *@This()) bool {
            return gate.entered.isSet();
        }
        fn run(raw: *anyopaque, task: *ClientTask) !void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            gate.entered.set(task.io);
            gate.released.waitUncancelable(task.io);
            const frozen = gate.page.frozen.?;
            try gate.key.set(frozen.key.provided);
            try gate.base.set(frozen.endpoint.base);
            try gate.model.set(frozen.model);
        }
    };
    for (std.enums.values(core.Field)) |field| for ([_][]const u8{ "changed", "\x1b[200~changed\x1b[201~" }) |bytes| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var page: Self = .{ .state = .{ .page = .api, .focus = switch (field) {
            .base => .base,
            .key => .key,
            .model => .model,
        } } };
        defer page.closeForm();
        const form = try page.ensureForm();
        _ = form.key.set("sk-before", "sk-before".len);
        _ = form.base.set("https://before.example/v1", "https://before.example/v1".len);
        _ = form.model.set("model-before", "model-before".len);
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        var clicked = false;
        for (page.drawn.hits) |hit| if (hit.action == .connect) {
            try page.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(hit.row), .col = @intCast(hit.start), .button = .left, .type = .press, .mods = .{} } });
            clicked = true;
            break;
        };
        try std.testing.expect(clicked and page.state.page == .saving and page.frozen != null);
        var gate: Gate = .{ .page = &page };
        try page.task.start(std.testing.io, &gate, Gate.run);
        defer {
            gate.released.set(std.testing.io);
            page.task.join() catch @panic("frozen form borrower failed");
        }
        const poll = @import("test_poll");
        try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(10)), &gate, Gate.ready);
        var events: @import("testing/app_events.zig").Events = .init(bytes);
        while (events.next()) |input| try page.widget().handleEvent(&ctx, input);
        try std.testing.expectEqualStrings("sk-before", form.key.text());
        try std.testing.expectEqualStrings("https://before.example/v1", form.base.text());
        try std.testing.expectEqualStrings("model-before", form.model.text());
        gate.released.set(std.testing.io);
        try page.task.join();
        try std.testing.expectEqualStrings("sk-before", gate.key.slice());
        try std.testing.expectEqualStrings("https://before.example/v1", gate.base.slice());
        try std.testing.expectEqualStrings("model-before", gate.model.slice());
        page.state.page = .api;
        page.state.focus = switch (field) {
            .base => .base,
            .key => .key,
            .model => .model,
        };
        events = .init(bytes);
        while (events.next()) |input| try page.widget().handleEvent(&ctx, input);
        try std.testing.expectEqualStrings("sk-before", form.key.text());
        try std.testing.expectEqualStrings("https://before.example/v1", form.base.text());
        try std.testing.expectEqualStrings("model-before", form.model.text());
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'x', .text = "x" } });
        try std.testing.expect(std.mem.endsWith(u8, form.editor(field).text(), "x"));
    };
}

fn testingClickConnect(page: *Self, ctx: *vxfw.EventContext) !void {
    for (page.drawn.hits) |hit| if (hit.action == .connect) {
        try page.widget().handleEvent(ctx, .{ .mouse = .{ .row = @intCast(hit.row), .col = @intCast(hit.start), .button = .left, .type = .press, .mods = .{} } });
        return;
    };
    return error.TestConnectNotDrawn;
}

fn testingStatusFor(page: *Self, ctx: *vxfw.EventContext) ![]const u8 {
    return testingText(try testingDraw(page, ctx.alloc, 90, 28), ctx.alloc);
}

test "SUI-63 Sign-in paste refusals block Connect until acknowledged in their field; typed refusals only report" {
    const Fault = enum { unbound, typed_overflow, typed_invalid_utf8, typed_invalid_scalar, paste_invalid, paste_overflow };
    const Ack = enum { enter, letter, backspace_at_start, arrow };
    for (std.enums.values(core.Field)) |field| for (std.enums.values(Fault)) |fault| for (std.enums.values(Ack)) |ack| {
        const paste = fault == .paste_invalid or fault == .paste_overflow;
        // A typed refusal never locks, so the acknowledgement keys only vary for pastes.
        if (!paste and ack != .enter) continue;
        errdefer std.debug.print("Sign-in refusal field={s} fault={s} ack={s}\n", .{ @tagName(field), @tagName(fault), @tagName(ack) });
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var page: Self = .{ .state = .{ .page = .api, .focus = .key } };
        defer page.closeForm();
        const form = try page.ensureForm();
        _ = form.base.set("https://custom.invalid/v1", "https://custom.invalid/v1".len);
        _ = form.key.set("sk-valid", 8);
        _ = form.model.set("service-model", 13);
        page.state.focus = switch (field) {
            .base => .base,
            .key => .key,
            .model => .model,
        };
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        const editor = form.editor(field);
        const label = switch (field) {
            .base => "Base URL",
            .key => "API key",
            .model => "Model ID",
        };
        const overflow = try arena.allocator().alloc(u8, editor.area.buffer.len + 1);
        @memset(overflow, 'x');
        const valid = try arena.allocator().dupe(u8, editor.text());
        // Sending a whole field's worth of bytes draws once per event, too slow for CI's per-test limit; start one byte short of full.
        if (fault == .typed_overflow or fault == .paste_overflow) try std.testing.expect(editor.set(overflow[0 .. overflow.len - 2], overflow.len - 2) == null);
        const before = try arena.allocator().dupe(u8, editor.text());
        // Every fault reaches the field as the person's keys, through the drawn view.
        switch (fault) {
            .unbound => try testingSend(&page, &ctx, "\x1bx", 90, 28),
            .typed_overflow => try testingSend(&page, &ctx, "xx", 90, 28),
            .typed_invalid_utf8 => try testingSend(&page, &ctx, "\xff", 90, 28),
            .typed_invalid_scalar => try testingSend(&page, &ctx, "\u{200b}", 90, 28),
            .paste_invalid => try testingSend(&page, &ctx, "\x1b[200~\xff\x1b[201~", 90, 28),
            .paste_overflow => try testingSend(&page, &ctx, "\x1b[200~xx\x1b[201~", 90, 28),
        }
        const status = try testingStatusFor(&page, &ctx);
        // A typed overflow keeps the bytes that fit before refusing, as the editor always has.
        if (fault != .typed_overflow) try std.testing.expectEqualStrings(before, editor.text());
        if (!paste) {
            // A typed refusal is reported, locks nothing and does not block Connect.
            try std.testing.expectEqual(@as(?core.Field, null), form.refusedField());
            try std.testing.expect(std.mem.indexOf(u8, status, " · text couldn't be entered") != null);
            try std.testing.expect(std.mem.indexOf(u8, status, "Paste refused") == null);
            // The person deletes what overflowed, so the field's own validation is not the thing under test.
            const extra = editor.text().len - before.len;
            const deletes = try arena.allocator().alloc(u8, extra);
            @memset(deletes, 0x7f);
            try testingSend(&page, &ctx, deletes, 90, 28);
            try std.testing.expectEqualStrings(before, editor.text());
            if (fault == .typed_overflow) try std.testing.expect(editor.set(valid, valid.len) == null);
            try std.testing.expect(try page.freeze(.key, .connect));
        } else {
            // The Status row wraps, so match the field-naming prefix; the full sentence is in pasteStatus.
            const message = try std.fmt.allocPrint(arena.allocator(), "Paste refused in {s}.", .{label});
            try std.testing.expect(std.mem.indexOf(u8, status, message) != null);
            try testingClickConnect(&page, &ctx);
            try std.testing.expect(page.state.page == .api and page.task.thread == null and page.frozen == null);
            try std.testing.expectEqual(switch (field) {
                .base => core.Control.base,
                .key => .key,
                .model => .model,
            }, page.state.focus);
            switch (ack) {
                .enter => try testingSend(&page, &ctx, "\r", 90, 28),
                .letter => try testingSend(&page, &ctx, "q", 90, 28),
                .backspace_at_start => {
                    editor.setCursor(0);
                    try testingSend(&page, &ctx, "\x7f", 90, 28);
                },
                // A caret move is not an acknowledgement: the lock and its Status stay.
                .arrow => try testingSend(&page, &ctx, "\x1b[D", 90, 28),
            }
            const after = try testingStatusFor(&page, &ctx);
            if (ack == .arrow) {
                try std.testing.expect(editor.rejected != null);
                try std.testing.expect(std.mem.indexOf(u8, after, message) != null);
                try testingClickConnect(&page, &ctx);
                try std.testing.expect(page.task.thread == null and page.frozen == null);
            } else {
                // The acknowledgement clears the lock and the stale transient, so Connect proceeds.
                try std.testing.expect(editor.rejected == null);
                try std.testing.expect(std.mem.indexOf(u8, after, "Paste refused") == null);
                try std.testing.expect(std.mem.indexOf(u8, after, "couldn't be entered") == null);
                if (fault == .paste_overflow) try std.testing.expect(editor.set(valid, valid.len) == null);
                try std.testing.expect(try page.freeze(.key, .connect));
            }
        }
    };
}

test "SUI-63 Sign-in Status shows the whole refusal at every width, breaking only between words" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]u16{ 46, 90, 140 }) |width| {
        errdefer std.debug.print("width={d}\n", .{width});
        var page: Self = .{ .state = .{ .page = .api, .focus = .key } };
        defer page.closeForm();
        _ = try page.ensureForm();
        _ = try testingDraw(&page, ctx.alloc, width, 30);
        try testingSend(&page, &ctx, "\x1b[200~\xff\x1b[201~", width, 30);
        const text = try testingText(try testingDraw(&page, ctx.alloc, width, 30), ctx.alloc);
        var words = std.mem.tokenizeScalar(u8, (try page.pasteStatus(ctx.alloc)).?, ' ');
        while (words.next()) |word| try std.testing.expect(std.mem.indexOf(u8, text, word) != null);
    }
}

test "SUI-63 Sign-in cross-field paste refusals name the locked field and only Enter or an edit in it releases" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };

    // Paste refused in Key, then Tab and type in Model: Status still names Key and Connect stays blocked.
    errdefer std.debug.print("cross-field block 1\n", .{});
    {
        var page: Self = .{ .state = .{ .page = .api, .focus = .key } };
        defer page.closeForm();
        const form = try page.ensureForm();
        _ = form.base.set("https://custom.invalid/v1", "https://custom.invalid/v1".len);
        _ = form.key.set("sk-valid", 8);
        _ = form.model.set("service-model", 13);
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try testingSend(&page, &ctx, "\x1b[200~\xff\x1b[201~", 90, 28);
        try testingSend(&page, &ctx, "\t", 90, 28);
        try testingSend(&page, &ctx, "q", 90, 28);
        try std.testing.expectEqual(core.Control.model, page.state.focus);
        try std.testing.expect(std.mem.indexOfScalar(u8, form.model.text(), 'q') != null);
        const status = try testingStatusFor(&page, &ctx);
        try std.testing.expect(std.mem.indexOf(u8, status, "Paste refused in API key.") != null);
        try testingClickConnect(&page, &ctx);
        try std.testing.expect(page.task.thread == null and page.frozen == null);
        try std.testing.expectEqual(core.Control.key, page.state.focus);
    }

    // Paste refused in Key and in Model: acknowledging Key leaves Status naming Model.
    errdefer std.debug.print("cross-field block 2\n", .{});
    {
        var page: Self = .{ .state = .{ .page = .api, .focus = .key } };
        defer page.closeForm();
        const form = try page.ensureForm();
        _ = form.base.set("https://custom.invalid/v1", "https://custom.invalid/v1".len);
        _ = form.key.set("sk-valid", 8);
        _ = form.model.set("service-model", 13);
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try testingSend(&page, &ctx, "\x1b[200~\xff\x1b[201~", 90, 28);
        try testingSend(&page, &ctx, "\t\x1b[200~\xff\x1b[201~", 90, 28);
        try testingSend(&page, &ctx, "\x1b[Z", 90, 28);
        try std.testing.expectEqual(core.Control.key, page.state.focus);
        try testingSend(&page, &ctx, "\r", 90, 28);
        try std.testing.expect(form.key.rejected == null and form.model.rejected != null);
        const status = try testingStatusFor(&page, &ctx);
        try std.testing.expect(std.mem.indexOf(u8, status, "Paste refused in Model ID.") != null);
        // The blocked Connect moves focus to the refused Model field, so Enter there acknowledges it.
        try std.testing.expect(!try page.freeze(.key, .connect));
        try std.testing.expectEqual(core.Control.model, page.state.focus);
        try testingSend(&page, &ctx, "\r", 90, 28);
        try std.testing.expect(form.model.rejected == null);
        try std.testing.expect(std.mem.indexOf(u8, try testingStatusFor(&page, &ctx), "Paste refused") == null);
        try std.testing.expect(try page.freeze(.key, .connect));
    }

    // A second paste into an already locked field is ignored and keeps the lock.
    errdefer std.debug.print("cross-field block 3\n", .{});
    {
        var page: Self = .{ .state = .{ .page = .api, .focus = .key } };
        defer page.closeForm();
        const form = try page.ensureForm();
        _ = form.key.set("sk-valid", 8);
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try testingSend(&page, &ctx, "\x1b[200~\xff\x1b[201~", 90, 28);
        try testingSend(&page, &ctx, "\x1b[200~zz\x1b[201~", 90, 28);
        try std.testing.expectEqualStrings("sk-valid", form.key.text());
        try std.testing.expect(form.key.rejected != null);
        try std.testing.expect(std.mem.indexOf(u8, try testingStatusFor(&page, &ctx), "Paste refused in API key.") != null);
        try std.testing.expect(!try page.freeze(.key, .connect));
    }
}

test "Sign-in choices subtitle footer and action buttons keep separate drawn keyboard and mouse authority" {
    const Owner = struct {
        closed: usize = 0,
        fn close(raw: *anyopaque, _: *vxfw.EventContext) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.closed += 1;
        }
    };
    for ([_]u16{ 46, 140 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var owner: Owner = .{};
        var page: Self = .{ .userdata = &owner, .on_close = Owner.close };
        defer page.closeForm();
        _ = try page.ensureForm();
        try page.code.set("ABCD-1234");
        try page.target.set("/synthetic store");
        const account = try testingDraw(&page, ctx.alloc, width, 30);
        const text = try testingText(account, ctx.alloc);
        try std.testing.expectEqual(@as(usize, 3), page.drawn.hits.len);
        try std.testing.expect(std.mem.indexOf(u8, text, "Choose account") == null and std.mem.indexOf(u8, text, "Navigation") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Sign in to begin.") != null and std.mem.indexOf(u8, text, "Tab / Shift-Tab") == null);
        try std.testing.expectEqual(@as(usize, 1), account.children[0].surface.children.len);
        const button_hit = page.drawn.hits[2];
        try std.testing.expect(button_hit.action == .close and button_hit.row > page.drawn.hits[1].row + 1);
        try std.testing.expectEqualStrings("C", account.children[0].surface.readCell(@intCast(button_hit.start - account.children[0].origin.col), @intCast(button_hit.row - account.children[0].origin.row)).char.grapheme);
        try testingSend(&page, &ctx, "\t\t\r", width, 30);
        try std.testing.expectEqual(@as(usize, 1), owner.closed);
        _ = try testingDraw(&page, ctx.alloc, width, 30);
        for (page.drawn.hits) |hit| if (hit.action == .close) {
            try page.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(hit.row), .col = @intCast(hit.start), .button = .left, .type = .press, .mods = .{} } });
            break;
        };
        try std.testing.expectEqual(@as(usize, 2), owner.closed);
        const Case = struct { page: core.Page, labels: []const []const u8, controls: []const core.Control };
        const cases = [_]Case{
            .{ .page = .method, .labels = &.{"[ Back ]"}, .controls = &.{.back} },
            .{ .page = .api, .labels = &.{ "[ Connect ]", "[ Back ]" }, .controls = &.{ .connect, .back } },
            .{ .page = .browser, .labels = &.{ "[ Open browser ]", "[ Change method ]", "[ Back ]" }, .controls = &.{ .open_page, .switch_method, .back } },
            .{ .page = .device, .labels = &.{ "[ Copy code ]", "[ Open browser ]", "[ Change method ]", "[ Back ]" }, .controls = &.{ .copy_code, .open_page, .switch_method, .back } },
            .{ .page = .{ .saving = .key }, .labels = &.{"[ Back ]"}, .controls = &.{.back} },
            .{ .page = .{ .failed = .{ .failure = .expired, .retry = .device } }, .labels = &.{ "[ Retry ]", "[ Back ]" }, .controls = &.{ .retry, .back } },
            .{ .page = .pending, .labels = &.{ "[ Recheck ]", "[ Back ]", "[ Return ]" }, .controls = &.{ .recheck, .back, .close } },
            .{ .page = .connected, .labels = &.{"Close"}, .controls = &.{.close} },
        };
        for (cases) |case| {
            page.state.page = case.page;
            for (case.controls, case.labels) |control, label| {
                page.state.focus = control;
                const frame = try testingDraw(&page, ctx.alloc, width, 30);
                try std.testing.expect(std.mem.indexOf(u8, try testingText(frame, ctx.alloc), label) != null);
                if (case.page == .browser and control == .open_page) {
                    try std.testing.expect(page.drawn.focused == null);
                    continue;
                }
                try std.testing.expectEqual(control, page.drawn.focused.?.control);
                var visible = false;
                for (page.drawn.hits) |hit| {
                    try std.testing.expect(hit.row < 30 and hit.start < hit.end and hit.end <= width);
                    if (std.meta.activeTag(hit.action) == std.meta.activeTag(page.drawn.focused.?.action)) visible = true;
                }
                try std.testing.expect(visible);
                const controls = page.state.controls();
                const at = std.mem.indexOfScalar(core.Control, controls, control).?;
                try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.tab } });
                try std.testing.expectEqual(controls[(at + 1) % controls.len], page.state.focus);
                if (page.state.focus != control) {
                    try std.testing.expect(page.focusedAction() == null);
                } else switch (control) {
                    .close => try std.testing.expect(page.focusedAction().? == .close),
                    .back => try std.testing.expect(page.focusedAction().? == .back),
                    else => return error.UnexpectedSingleControl,
                }
            }
        }
        for ([_]core.Page{ .method, .api, .browser, .device, .{ .failed = .{ .failure = .expired, .retry = .device } }, .pending }) |from| {
            page.state = .{ .page = from, .focus = .back };
            _ = try testingDraw(&page, ctx.alloc, width, 30);
            var clicked = false;
            for (page.drawn.hits) |hit| if (hit.action == .back) {
                try page.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(hit.row), .col = @intCast(hit.start), .button = .left, .type = .press, .mods = .{} } });
                clicked = true;
                break;
            };
            try std.testing.expect(clicked);
            try std.testing.expectEqual(if (from == .browser or from == .device) @as(std.meta.Tag(core.Page), .method) else .account, std.meta.activeTag(page.state.page));
        }
    }
}

test "SUI-7 Sign-in copy preserves drawn browser and device values across input and layout domains" {
    {
        const url = "https://example.invalid/authorize?client_id=synthetic&state=synthetic&scope=example";
        const status = "Couldn't open a browser. Copy URL to open it manually.";
        for ([_]u16{ 46, 140 }) |width| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            var page: Self = .{ .state = .{ .page = .browser, .focus = .callback }, .issue = status };
            page.browser = try pages.Mapped(Browser).map();
            defer _ = page.closeBrowser();
            page.browser.?.value.init();
            try page.browser.?.value.link.set(url);
            const frame = try testingDraw(&page, ctx.alloc, width, 30);
            const text = try testingText(frame, ctx.alloc);
            try std.testing.expect(std.mem.indexOf(u8, text, "[ Copy URL ]") != null);
            var compact: std.ArrayList(u8) = .empty;
            for (text) |byte| if (!std.ascii.isWhitespace(byte)) try compact.append(ctx.alloc, byte);
            try std.testing.expect(std.mem.indexOf(u8, compact.items, "Couldn'topenabrowser.CopyURLtoopenitmanually.") != null);
            try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
            try testingSend(&page, &ctx, "\t\t\r", width, 30);
            try std.testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
            try std.testing.expectEqualStrings(url, ctx.cmds.items[0].copy_to_clipboard);
        }
    }
    {
        const url = "https://auth.openai.com/codex/device";
        for ([_]u16{ 46, 140 }) |width| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
            var page: Self = .{ .state = .{ .page = .device, .focus = .copy_code } };
            try page.code.set("ABCD-1234");
            const frame = try testingDraw(&page, ctx.alloc, width, 30);
            var readable: std.ArrayList(u8) = .empty;
            const dialog = frame.children[0].surface;
            var url_rows: usize = 0;
            for (0..dialog.size.height) |row| {
                var linked = false;
                for (0..dialog.size.width) |col| {
                    const cell = dialog.readCell(@intCast(col), @intCast(row));
                    if (cell.link.uri.len == 0) continue;
                    try std.testing.expectEqualStrings(url, cell.link.uri);
                    if (std.mem.eql(u8, cell.char.grapheme, " ")) continue;
                    try readable.appendSlice(ctx.alloc, cell.char.grapheme);
                    linked = true;
                }
                url_rows += @intFromBool(linked);
            }
            try std.testing.expectEqualStrings(url, readable.items);
            try std.testing.expectEqual(@as(usize, if (width == 46) 2 else 1), url_rows);
            try std.testing.expectEqualStrings("ABCD-1234", page.drawn.copy.?.slice());
            try std.testing.expect(std.mem.indexOf(u8, try testingText(frame, ctx.alloc), "C copies code. Esc back.") != null);
            try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
            var copied = false;
            for (page.drawn.hits) |hit| if (hit.action == .copy) {
                try page.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(hit.row), .col = @intCast(hit.start), .button = .left, .type = .press, .mods = .{} } });
                copied = true;
                break;
            };
            try std.testing.expect(copied);
            try std.testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
            try std.testing.expectEqualStrings("ABCD-1234", ctx.cmds.items[0].copy_to_clipboard);
        }
    }
    {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var page: Self = .{ .state = .{ .page = .device, .focus = .copy_code } };
        try page.code.set("ABCD-1234");
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        try std.testing.expectEqualStrings("ABCD-1234", page.drawn.copy.?.slice());
        try testingSend(&page, &ctx, "\x1b[200~c\r\x1b[201~", 90, 28);
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        try testingSend(&page, &ctx, "c", 90, 28);
        try std.testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
        try std.testing.expectEqualStrings("ABCD-1234", ctx.cmds.items[0].copy_to_clipboard);
        page.state.focus = .open_page;
        const tiny = try testingDraw(&page, ctx.alloc, 72, 3);
        try std.testing.expect(page.drawn.copy == null);
        try std.testing.expect(std.mem.indexOf(u8, try testingText(tiny, ctx.alloc), "ABCD-1234") == null);
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'c', .text = "c" } });
        try std.testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
        for ([_]u16{ 0, 1, 2, 3 }) |height| for ([_]u16{ 0, 1, 8, 9, 28, 72 }) |width| {
            page.state.focus = .copy_code;
            const frame = try testingDraw(&page, ctx.alloc, width, height);
            if (page.drawn.copy != null) try std.testing.expect(std.mem.indexOf(u8, try testingText(frame, ctx.alloc), "ABCD-1234") != null);
        };
        for ([_]u16{ 27, 28, 29, 30, 31 }) |width| {
            page.state.focus = .copy_code;
            const frame = try testingDraw(&page, ctx.alloc, width, 30);
            try std.testing.expectEqual(width >= 30, page.drawn.copy != null);
            if (page.drawn.copy != null) try std.testing.expect(std.mem.indexOf(u8, try testingText(frame, ctx.alloc), "ABCD-1234") != null);
        }
        _ = try testingDraw(&page, ctx.alloc, 90, 28);
        const old = page.drawn.copy.?;
        page.state.attempt += 1;
        try page.activateDrawn(&ctx, .{ .copy = old });
        try std.testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
    }

    for ([_]bool{ false, true }) |browser_method| for ([_]u16{ 46, 140 }) |width| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var page: Self = .{ .state = .{ .page = if (browser_method) .browser else .device, .focus = if (browser_method) .copy_url else .copy_code } };
        try page.code.set("ABCD-1234");
        if (browser_method) {
            page.browser = try pages.Mapped(Browser).map();
            page.browser.?.value.init();
            try page.browser.?.value.link.set("https://example.invalid/?a=1&b=2");
        }
        defer _ = page.closeBrowser();
        _ = try testingDraw(&page, ctx.alloc, width, 30);
        try testingSend(&page, &ctx, "\x1b[200~c\r\x1b[201~", width, 30);
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        _ = try testingDraw(&page, ctx.alloc, width, 30);
        const action = page.drawn.focused.?.action;
        page.state.attempt += 1;
        try page.activateDrawn(&ctx, action);
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        _ = try testingDraw(&page, ctx.alloc, width, 30);
        page.state.page = .method;
        try page.activateDrawn(&ctx, action);
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        page.state.page = if (browser_method) .browser else .device;
        _ = try testingDraw(&page, ctx.alloc, width, 30);
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.tab } });
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        page.state.focus = if (browser_method) .copy_url else .copy_code;
        _ = try testingDraw(&page, ctx.alloc, 0, 0);
        try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
        try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
        _ = try testingDraw(&page, ctx.alloc, width, 30);
        const copy_tag: std.meta.Tag(core.Action) = if (browser_method) .copy_url else .copy;
        for (page.drawn.hits) |hit| if (std.meta.activeTag(hit.action) == copy_tag) {
            try page.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(hit.row), .col = @intCast(hit.start), .button = .left, .type = .press, .mods = .{} } });
            break;
        };
        try std.testing.expectEqual(@as(usize, 1), ctx.cmds.items.len);
        try std.testing.expectEqualStrings(if (browser_method) "https://example.invalid/?a=1&b=2" else "ABCD-1234", ctx.cmds.items[0].copy_to_clipboard);
    };
}

test "Sign-in browser shows URL rejects stray long callback and switches only after cancellation joins" {
    var rig: BrowserRig = undefined;
    try rig.open();
    defer rig.close();
    try rig.send("\r\r");
    try rig.wait(BrowserRig.linked);
    const link = rig.page.browser.?.value.link.slice();
    try std.testing.expect(std.mem.startsWith(u8, link, "http://127.0.0.1:1/"));
    try std.testing.expectEqual(@as(usize, 0), rig.ctx.cmds.items.len);
    rig.page.state.focus = .callback;
    try rig.send("\x1b[200~not an address\x1b[201~");
    try std.testing.expectEqual(@as(usize, 0), rig.page.browser.?.value.confirmed);
    try rig.send("\r");
    try rig.wait(BrowserRig.strayed);
    rig.page.editAddress(.clear);
    const port_ = try rig.port();
    const wrong = try std.fmt.allocPrint(rig.arena.allocator(), "http://127.0.0.1:{s}/auth/callback?code=wrong&state=not-this-login", .{port_});
    rig.page.editAddress(.{ .append = wrong });
    rig.page.editAddress(.confirm);
    try rig.wait(testingCompleted);
    {
        rig.page.task.mutex.lockUncancelable(rig.page.init.?.io);
        defer rig.page.task.mutex.unlock(rig.page.init.?.io);
        try std.testing.expect(rig.page.task.thread != null and rig.page.browser != null);
        try std.testing.expect(rig.page.browser.?.value.failure == .answer);
    }
    _ = try testingDraw(&rig.page, rig.ctx.alloc, 90, 28);
    try rig.page.activateDrawn(&rig.ctx, .switch_method);
    try std.testing.expect(rig.page.state.page == .stopping);
    try rig.wait(testingCompleted);
    try rig.page.advance(&rig.ctx);
    try std.testing.expect(rig.page.task.thread == null and rig.page.browser == null and rig.page.state.page == .method);
    try std.testing.expect(rig.page.outcome != null and rig.page.outcome.? == .failed and rig.page.outcome.?.failed.cause == error.Reported and rig.page.outcome.?.failed.shown == .answer);
    try rig.send("\x1b[B\r");
    try std.testing.expect(rig.page.state.page == .device);
    try std.testing.expect(rig.page.task.thread != null and !rig.page.task.completed());
    rig.page.cancel();
    try rig.wait(testingCompleted);
    try rig.page.advance(&rig.ctx);
    try std.testing.expect(rig.page.task.thread == null);
    try std.testing.expect(rig.page.outcome != null and rig.page.outcome.? == .cancelled);
    var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
    try std.testing.expectError(error.Reported, rig.page.stopTo(&report.writer));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "Sign-in answer not valid. (Reported)"));
    try std.testing.expect(rig.page.task.thread == null and rig.page.browser == null and rig.page.receipts == null and rig.page.outcome == null);
    try std.testing.expect(rig.page.reported_current == 0 and rig.page.retention_failure == null and rig.page.reporting_failure == null);
    const reported = report.written().len;
    try rig.page.stopTo(&report.writer);
    try std.testing.expectEqual(reported, report.written().len);
}

test "SUI-7 Sign-in Escape cancels waiting browser and device journeys and returns to the method frame" {
    for ([_]core.Method{ .browser, .device }) |method| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        try rig.send("\r");
        if (method == .device) try rig.send("\t");
        try rig.send("\r");
        if (method == .browser) {
            try rig.wait(BrowserRig.linked);
            try rig.send("\x1b[200~not-the-address\x1b[201~\r");
            try rig.wait(BrowserRig.strayed);
            const frame = try testingDraw(&rig.page, rig.ctx.alloc, 90, 28);
            const text = try testingText(frame, rig.ctx.alloc);
            try std.testing.expect(std.mem.indexOf(u8, text, "Not the sign-in address. Paste again.") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "not-the-address") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "[ Change method ]") != null);
        } else {
            try rig.wait(BrowserRig.deviceCode);
            const frame = try testingDraw(&rig.page, rig.ctx.alloc, 90, 28);
            const text = try testingText(frame, rig.ctx.alloc);
            try std.testing.expect(std.mem.indexOf(u8, text, "BDL9-KI88H") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "auth.openai.com/codex/device") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "[ Copy code ]") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "C copies code") != null);
        }
        try rig.page.widget().handleEvent(&rig.ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
        try std.testing.expect(rig.page.state.page == .stopping);
        try rig.wait(testingCompleted);
        try rig.page.advance(&rig.ctx);
        try std.testing.expect(rig.page.task.thread == null and rig.page.state.page == .method);
        const returned = try testingDraw(&rig.page, rig.ctx.alloc, 90, 28);
        try std.testing.expect(std.mem.indexOf(u8, try testingText(returned, rig.ctx.alloc), "ChatGPT account") != null);
        for ([_][]const u8{ ".config/rui/preferences", ".config/rui/codex.json", ".config/rui/chatgpt.json", ".config/rui/requests" }) |path|
            try std.testing.expectError(error.FileNotFound, rig.tmp.dir.access(std.testing.io, path, .{}));
    }
}

test "SUI-6 Sign-in ignores account typing and Escape returns from API key to welcome" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    var page: Self = .{};
    defer page.closeForm();
    try testingSend(&page, &ctx, "hello", 90, 28);
    try std.testing.expect(page.state.page == .account and page.state.focus == .chatgpt and page.task.thread == null);
    try testingSend(&page, &ctx, "\x1b[C", 90, 28);
    try std.testing.expectEqual(core.Control.api_key, page.state.focus);
    try testingSend(&page, &ctx, "\r", 90, 28);
    try std.testing.expect(page.state.page == .api);
    const api = try testingDraw(&page, ctx.alloc, 90, 28);
    try std.testing.expect(std.mem.indexOf(u8, try testingText(api, ctx.alloc), "Connect with an API key") != null);
    try page.widget().handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.escape } });
    try std.testing.expect(page.state.page == .account and page.task.thread == null);
    const welcome = try testingDraw(&page, ctx.alloc, 90, 28);
    const text = try testingText(welcome, ctx.alloc);
    try std.testing.expect(std.mem.indexOf(u8, text, "Welcome to Rui") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") == null);
}

test "Sign-in both OAuth methods retry published Host failures without authenticating again" {
    for ([_]core.Method{ .browser, .device }) |method| for ([_]bool{ false, true }) |activation_error| for ([_]bool{ false, true }) |defaults_failed| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var activation: Activation = .{ .binding = .{}, .store = .{}, .launch = host_launch.Result.failed(.child_refused, error.HostStartupFailed) };
        try activation.store.set("/synthetic-store");
        activation.launch.?.outcome.failed.store = activation.store;
        var page: Self = .{
            .state = .{ .page = if (method == .browser) .browser else .device, .attempt = 1 },
            .attempt = if (method == .browser) .browser else .device,
            .outcome = .{ .published = .{
                .defaults = if (defaults_failed) error.UnsupportedPreferencesVersion else {},
                .activation = if (activation_error) error.HostReadinessUnconfirmed else activation,
            } },
        };
        try page.settle(.{ .screen = &ctx });
        try std.testing.expect(page.state.page == .failed);
        try std.testing.expectEqual(if (defaults_failed) core.Failure.defaults_and_host else .host, page.state.page.failed.failure);
        const retry = page.state.step(.{ .activate = .{ .attempt = page.state.attempt, .page = .failed, .action = .retry } });
        try std.testing.expectEqual(core.Attempt.existing, retry.start);
        try std.testing.expect(page.state.page == .saving);
        var report: std.Io.Writer.Allocating = .init(arena.allocator());
        const original: anyerror = if (defaults_failed) error.UnsupportedPreferencesVersion else if (activation_error) error.HostReadinessUnconfirmed else error.HostStartupFailed;
        try std.testing.expectError(original, page.stopTo(&report.writer));
        const count = report.written().len;
        try page.stopTo(&report.writer);
        try std.testing.expectEqual(count, report.written().len);
    };
}

test "Sign-in whole joined receipt survives screen settlement and departure reports exactly once" {
    const Case = enum { refused, os_launch, timeout, success, pending, activation_error };
    const Worker = struct {
        fn finish(_: *anyopaque, _: *ClientTask) !void {}
    };
    for (std.enums.values(Case)) |case| for ([_]bool{ false, true }) |screen_first| for ([_]bool{ false, true }) |defaults_failed| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try env.put("HOME", "/synthetic-home");
        const init_: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = &env, .preopens = .empty };
        var answer = try testingActivation(init_);
        answer.launch = switch (case) {
            .refused => .failed(.child_refused, error.HostStartupFailed),
            .os_launch => .failed(.os_launch, error.HostLaunchFailed),
            .timeout => .failed(.readiness_timeout, error.HostReadinessUnconfirmed),
            .activation_error => null,
            .success, .pending => .{ .outcome = .{ .ready = .{ .facts = .{ .store = answer.store, .instance = @splat(1), .active_capacity = 4, .started_at = 1, .custody_occupied = 0, .paused = false, .capabilities = .{ .bash = true, .connections = protocol.connectionsOfRoutes(.{ .codex = .unserved, .openai = .key_file, .chatgpt = .unserved }) } }, .adopted = case == .pending } } },
        };
        answer.pending = case == .pending;
        if (answer.launch) |*launch| {
            if (launch.outcome == .failed) {
                launch.outcome.failed.store = answer.store;
                if (case == .os_launch) launch.outcome.failed.os_error = 13;
                if (case == .refused) launch.outcome.failed.detail = .{ .refusal = @import("start_report.zig").Failure.init(.settings_invalid, "retained refusal body") };
            }
            const marker = "retained child transcript\n";
            @memcpy(launch.startup_bytes[0..marker.len], marker);
            launch.startup_len = marker.len;
        }
        var page: Self = .{ .init = init_, .state = .{ .page = .{ .saving = .existing } }, .outcome = .{ .published = .{ .defaults = if (defaults_failed) error.UnsupportedPreferencesVersion else {}, .activation = if (case == .activation_error) error.HostReadinessUnconfirmed else answer } } };
        const form = try page.ensureForm();
        @memset(&form.key_bank, 's');
        try page.task.start(init_.io, &page, Worker.finish);
        page.gate.store(.publishing, .release);
        page.cancel();
        try std.testing.expectEqual(.publishing, page.gate.load(.acquire));
        var ctx: vxfw.EventContext = .{ .io = init_.io, .alloc = arena.allocator(), .cmds = .empty };
        page.state.focus = .back;
        _ = try testingDraw(&page, ctx.alloc, 46, 30);
        var back_clicked = false;
        for (page.drawn.hits) |hit| if (hit.action == .back) {
            try page.widget().handleEvent(&ctx, .{ .mouse = .{ .row = @intCast(hit.row), .col = @intCast(hit.start), .button = .left, .type = .press, .mods = .{} } });
            back_clicked = true;
            break;
        };
        try std.testing.expect(back_clicked and page.state.page == .saving and page.task.thread != null);
        try testingSend(&page, &ctx, "\r", 46, 30);
        try std.testing.expect(page.state.page == .saving and page.gate.load(.acquire) == .publishing and page.task.thread != null);
        try std.testing.expect(std.mem.indexOf(u8, page.issue.?, "cannot be cancelled") != null);
        if (screen_first) {
            try page.settle(.{ .screen = &ctx });
            try std.testing.expect(page.task.thread == null and page.outcome.? == .published);
            for (form.key_bank) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            if (answer.launch) |launch| try std.testing.expectEqualStrings(launch.startup(), (try page.outcome.?.published.activation).launch.?.startup());
        }
        var report: std.Io.Writer.Allocating = .init(arena.allocator());
        const ended = page.stopTo(&report.writer);
        const expected: ?anyerror = if (defaults_failed) error.UnsupportedPreferencesVersion else switch (case) {
            .refused => error.HostStartupFailed,
            .os_launch => error.HostLaunchFailed,
            .timeout, .activation_error => error.HostReadinessUnconfirmed,
            .pending => error.ConnectionNotActive,
            .success => null,
        };
        if (expected) |err| try std.testing.expectError(err, ended) else try ended;
        const text = report.written();
        try std.testing.expectEqual(defaults_failed, std.mem.indexOf(u8, text, "UnsupportedPreferencesVersion") != null);
        switch (case) {
            .refused, .timeout, .success, .pending => try std.testing.expect(std.mem.indexOf(u8, text, "retained child transcript") != null),
            .os_launch => try std.testing.expect(std.mem.indexOf(u8, text, "OS error 13") != null),
            .activation_error => try std.testing.expect(std.mem.indexOf(u8, text, "HostReadinessUnconfirmed") != null),
        }
        try std.testing.expect(page.task.thread == null and page.form == null and page.outcome == null);
        const count = text.len;
        try page.stopTo(&report.writer);
        try std.testing.expectEqual(count, report.written().len);
    };
}

test "Sign-in cleanup failure retains original error resource identity and departure recovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var path: protocol.Bounded(@import("host_settings.zig").max_path_bytes) = .{};
    try path.set("/synthetic path/.openai-owned.key");
    var page: Self = .{ .outcome = .{ .published = .{ .defaults = {}, .activation = error.ConnectionNotActive, .connection = .{ .failed = .{ .cause = error.DirectorySyncFailed, .cleanup = .{ .cause = error.AccessDenied, .key_file = path } } } } } };
    var report: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.testing.expectError(error.DirectorySyncFailed, page.stopTo(&report.writer));
    for ([_][]const u8{ "DirectorySyncFailed", "AccessDenied", "rm -f -- $'/synthetic path/.openai-owned.key'" }) |needle| try std.testing.expect(std.mem.indexOf(u8, report.written(), needle) != null);
    const count = report.written().len;
    try page.stopTo(&report.writer);
    try std.testing.expectEqual(count, report.written().len);
}

test "Sign-in API pending receipt never authorizes either later ChatGPT method" {
    for ([_]core.Attempt{ .browser, .device }) |attempt_| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
        var page: Self = .{ .saved = .{ .saved = .{} } };
        try std.testing.expect(try page.freeze(attempt_, .{ .method = if (attempt_ == .browser) .browser else .device }));
        try page.begin(&ctx, attempt_);
        try std.testing.expect(page.saved == null);
        page.outcome = .{ .published = .{ .defaults = error.UnsupportedPreferencesVersion, .activation = error.HostReadinessUnconfirmed } };
        var report: std.Io.Writer.Allocating = .init(arena.allocator());
        try std.testing.expectError(error.UnsupportedPreferencesVersion, page.stopTo(&report.writer));
        try std.testing.expect(std.mem.indexOf(u8, report.written(), "UnsupportedPreferencesVersion") != null);
        try std.testing.expect(std.mem.indexOf(u8, report.written(), "HostReadinessUnconfirmed") != null);
        try std.testing.expect(std.mem.indexOf(u8, report.written(), "not active") == null);
    }
}

test "Sign-in browser failure vocabulary covers expiry denial scope and malformed answers" {
    try std.testing.expectEqual(core.Failure.expired, browserFailure(.timed_out));
    try std.testing.expectEqual(core.Failure.denied, browserFailure(.{ .refused = "access_denied" }));
    try std.testing.expectEqual(core.Failure.plan, browserFailure(.{ .exchange = .plan_scope_missing }));
    try std.testing.expectEqual(core.Failure.answer, browserFailure(.{ .exchange = .not_for_this_sign_in }));
    for (std.enums.values(core.Failure)) |failure| try std.testing.expect(std.mem.indexOfAny(u8, failureText(failure), "\r\n\x1b") == null);
}

test "Sign-in scoped retry keeps admitted model Store and pair instead of old selectors" {
    var connection: host_start.Connection = .{};
    try connection.endpoint.set("https://custom.invalid/service");
    try connection.key_file.set("/synthetic-host/.openai-owned.key");
    var page: Self = .{
        .selectors = .{ .store = "/old-store", .provider = "codex", .model = "old-model" },
        .frozen = .{ .intent = .{ .store = "/selected-store", .provider = "openai", .model = "custom-model" }, .provider = .openai, .model = "custom-model", .key = .{ .provided = "no-longer-borrowed" }, .endpoint = .{ .unchanged = connection.endpoint.slice() } },
        .saved = .{ .saved = connection },
    };
    for ([_]core.Attempt{ .existing, .recheck }) |attempt_| {
        try std.testing.expect(try page.freeze(attempt_, .retry));
        try std.testing.expectEqualStrings("/selected-store", page.frozen.?.intent.store.?);
        try std.testing.expectEqualStrings("openai", page.frozen.?.intent.provider.?);
        try std.testing.expectEqualStrings("custom-model", page.frozen.?.intent.model.?);
        try std.testing.expectEqualStrings("", page.frozen.?.key.provided);
        try std.testing.expectEqualStrings(connection.key_file.slice(), page.savedConnection().?.key_file.slice());
    }
    try std.testing.expect(try page.freeze(.existing, .{ .reuse = .codex }));
    try std.testing.expectEqual(core.Provider.codex, page.frozen.?.provider);
}

test "Sign-in focus loss closes paste editor but orphaned paste cannot edit or act" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var ctx: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    var page: Self = .{ .state = .{ .page = .api, .focus = .key } };
    defer page.closeForm();
    _ = try page.ensureForm();
    try testingSend(&page, &ctx, "\x1b[200~sk-prefix", 90, 28);
    try std.testing.expect(page.form.?.value.key.pasting());
    try page.widget().handleEvent(&ctx, .focus_out);
    try std.testing.expect(!page.form.?.value.key.pasting());
    try std.testing.expect(page.paste == .ignore);
    try testingSend(&page, &ctx, "discarded\t\r\x1b[201~", 90, 28);
    try std.testing.expect(page.paste == .none);
    try std.testing.expectEqualStrings("sk-prefix", page.form.?.value.key.text());
    try std.testing.expect(page.state.page == .api and page.task.thread == null);
    try testingSend(&page, &ctx, "X", 90, 28);
    try std.testing.expectEqualStrings("sk-prefixX", page.form.?.value.key.text());
    try std.testing.expectEqual(@as(usize, 0), ctx.cmds.items.len);
}

fn testingScratch(init_: std.process.Init) !std.Io.File {
    var directory = try std.Io.Dir.cwd().openDir(init_.io, init_.environ_map.get("HOME").?, .{});
    defer directory.close(init_.io);
    const file = try directory.createFile(init_.io, ".sign-in-receipts", .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    errdefer file.close(init_.io);
    try directory.deleteFile(init_.io, ".sign-in-receipts");
    return file;
}

test "Sign-in replacement retains whole prior launch and cleanup receipts across retry reset and later outcome" {
    const Later = enum { success, failed, cancelled };
    const Hooks = struct {
        fn ready(_: std.process.Init, _: []const u8) core.Readinesses {
            var result: core.Readinesses = .initFill(.missing);
            result.set(.codex, .configured);
            return result;
        }
        fn activate(init_: std.process.Init, _: selection.Intent, _: ?*const host_start.Connection) !Activation {
            if (std.mem.eql(u8, init_.environ_map.get("LATER").?, "failed")) return error.HostReadinessUnconfirmed;
            return testingActivation(init_);
        }
    };
    for (std.enums.values(Later)) |later| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        page.activate = Hooks.activate;
        page.ready = Hooks.ready;
        try rig.env.put("LATER", @tagName(later));
        var answer = try testingActivation(page.init.?);
        answer.launch = .failed(.child_refused, error.HostStartupFailed);
        const marker = "first attempt diagnostic marker\n";
        @memcpy(answer.launch.?.startup_bytes[0..marker.len], marker);
        answer.launch.?.startup_len = marker.len;
        answer.launch.?.outcome.failed.store = answer.store;
        page.attempt = .existing;
        page.state = .{ .page = .{ .saving = .existing } };
        page.outcome = .{ .published = .{ .defaults = error.UnsupportedPreferencesVersion, .activation = answer } };
        try page.settle(.{ .screen = &rig.ctx });
        try std.testing.expect(page.state.page == .failed);
        try rig.send("\r");
        try rig.wait(testingCompleted);
        try page.advance(&rig.ctx);
        try std.testing.expect(page.receipts != null);
        try page.stageReceipt(null);
        var key_file: protocol.Bounded(@import("host_settings.zig").max_path_bytes) = .{};
        try key_file.set("/synthetic owned/.openai-retained.key");
        page.state = .{ .page = .{ .saving = .key } };
        page.outcome = .{ .published = .{ .defaults = {}, .activation = error.ConnectionNotActive, .connection = .{ .failed = .{ .cause = error.InjectedCredentialWriteFailure, .cleanup = .{ .cause = error.AccessDenied, .key_file = key_file } } } } };
        try page.settle(.{ .screen = &rig.ctx });
        try std.testing.expect(page.state.page == .failed);
        const committed = page.receipts.?.committed_end;
        try page.reset();
        try std.testing.expect(page.outcome != null and page.receipts.?.committed_end == committed);
        try rig.send("\r");
        if (later == .cancelled) {
            try rig.send("\r");
            try rig.wait(BrowserRig.linked);
            try rig.send("\x1b");
        } else try rig.send("\t\t\r");
        try rig.wait(testingCompleted);
        try page.advance(&rig.ctx);
        const fd = page.receipts.?.file.handle;
        var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        try std.testing.expectError(error.UnsupportedPreferencesVersion, page.stopTo(&report.writer));
        const text = report.written();
        for ([_][]const u8{ marker, "UnsupportedPreferencesVersion", "/synthetic owned/.openai-retained.key", "InjectedCredentialWriteFailure", "AccessDenied" }) |needle| {
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, needle));
        }
        try std.testing.expect(page.receipts == null and page.outcome == null);
        try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) < 0);
        const count = text.len;
        try page.stopTo(&report.writer);
        try std.testing.expectEqual(count, report.written().len);
    }
}

test "Sign-in receipt admission retains old metadata on quota create and append failure" {
    const Hooks = struct {
        fn unavailable(_: std.process.Init) !std.Io.File {
            return error.DiskQuota;
        }
    };
    var rig: BrowserRig = undefined;
    try rig.open();
    defer rig.close();
    const page = &rig.page;
    page.state = .{ .page = .method, .attempt = 7, .focus = .browser };
    page.attempt = .key;
    page.frozen = .{ .intent = .{ .store = "/old-store", .provider = "openai", .model = "old-model" }, .provider = .openai, .model = "old-model", .key = .{ .provided = "" }, .endpoint = .{ .unchanged = host_start.openai_endpoint } };
    page.saved = .{ .saved = .{} };
    page.outcome = .{ .failed = .{ .cause = error.LoginDenied } };
    page.scratch = Hooks.unavailable;
    try rig.send("\r");
    try std.testing.expect(page.retention_failure.?.unavailable == error.DiskQuota);
    try std.testing.expect(page.receipts == null);
    try std.testing.expectEqual(@as(u64, 7), page.state.attempt);
    try std.testing.expect(page.state.page == .method and page.attempt == .key and page.task.thread == null);
    try std.testing.expectEqualStrings("old-model", page.frozen.?.model);
    try std.testing.expect(page.saved != null and page.outcome.?.failed.cause == error.LoginDenied);
    page.scratch = testingScratch;
    for ([_]ReceiptFault{ .{ .after = 0, .cause = error.NoSpaceLeft }, .{ .after = 7, .cause = error.DiskQuota } }) |fault| {
        try std.testing.expectError(fault.cause, page.stageReceipt(fault));
        try std.testing.expectEqual(@as(u64, 0), page.receipts.?.committed_end);
        try std.testing.expect(page.outcome.?.failed.cause == error.LoginDenied);
    }
    try page.stageReceipt(null);
    const committed = page.receipts.?.committed_end;
    page.outcome = .{ .failed = .{ .cause = error.LoginExpired } };
    page.receipts.?.committed_end = max_deferred_bytes;
    try std.testing.expectError(error.SignInReceiptLimit, page.stageReceipt(null));
    try std.testing.expect(page.outcome.?.failed.cause == error.LoginExpired);
    page.receipts.?.committed_end = committed;
    var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
    try std.testing.expectError(error.LoginDenied, page.stopTo(&report.writer));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "LoginDenied"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "LoginExpired"));
}

test "Sign-in native departure fully acknowledged successful launch remains successful after create cap or append refusal" {
    const Refusal = enum { create, cap, append };
    const Hooks = struct {
        fn unavailable(_: std.process.Init) !std.Io.File {
            return error.DiskQuota;
        }
    };
    const marker = "successful operation diagnostic marker\n";
    for (std.enums.values(Refusal)) |refusal| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        defer page.deinit();
        var answer = try testingActivation(page.init.?);
        answer.launch = .{ .outcome = .{ .ready = .{ .facts = .{ .store = answer.store, .instance = @splat(1), .active_capacity = 4, .started_at = 1, .custody_occupied = 0, .paused = false, .capabilities = .{ .bash = true, .connections = protocol.connectionsOfRoutes(.{ .codex = .unserved, .openai = .key_file, .chatgpt = .unserved }) } } } } };
        @memcpy(answer.launch.?.startup_bytes[0..marker.len], marker);
        answer.launch.?.startup_len = marker.len;
        const outcome: Outcome = .{ .published = .{ .defaults = {}, .activation = answer } };
        page.outcome = outcome;
        var committed: usize = 0;
        const cause = switch (refusal) {
            .create => error.DiskQuota,
            .cap => error.SignInReceiptLimit,
            .append => error.NoSpaceLeft,
        };
        switch (refusal) {
            .create => {
                page.scratch = Hooks.unavailable;
                try std.testing.expectError(cause, page.stageReceipt(null));
                try std.testing.expect(page.receipts == null);
            },
            .cap => while (true) {
                page.stageReceipt(null) catch |err| {
                    try std.testing.expectEqual(cause, err);
                    break;
                };
                committed += 1;
                try std.testing.expect(committed <= max_deferred_bytes / marker.len);
                page.outcome = outcome;
            },
            .append => {
                try page.stageReceipt(null);
                committed = 1;
                page.outcome = outcome;
                try std.testing.expectError(cause, page.stageReceipt(.{ .after = 7, .cause = cause }));
            },
        }
        try std.testing.expect(page.outcome != null);
        try std.testing.expectEqual(cause, page.retention_failure.?.unavailable);
        try std.testing.expect(page.reporting_failure == null);
        const fd: ?std.posix.fd_t = if (page.receipts) |kept| kept.file.handle else null;
        if (page.receipts) |kept| try std.testing.expect(kept.first_failure == null and kept.reported == 0);
        var expected: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        for (0..committed) |_| try expected.writer.writeAll(marker);
        try expected.writer.print("Replacement sign-in was not started: previous report could not be retained ({s}).\n", .{@errorName(cause)});
        try expected.writer.writeAll(marker);
        const output = try rig.tmp.dir.createFile(page.init.?.io, "native-departure", .{ .read = true });
        defer output.close(page.init.?.io);
        const saved_stderr = std.c.dup(2);
        if (saved_stderr < 0) return error.TestRedirectFailed;
        defer _ = std.c.close(saved_stderr);
        if (std.c.dup2(output.handle, 2) != 2) return error.TestRedirectFailed;
        defer std.debug.assert(std.c.dup2(saved_stderr, 2) == 2);
        try page.stop();
        const bytes = try rig.arena.allocator().alloc(u8, expected.written().len + 1);
        const report = bytes[0..try output.readPositionalAll(page.init.?.io, bytes, 0)];
        try std.testing.expectEqualStrings(expected.written(), report);
        try std.testing.expectEqual(committed + 1, std.mem.count(u8, report, marker));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report, "Replacement sign-in was not started"));
        try std.testing.expect(page.receipts == null and page.outcome == null and page.retention_failure == null and page.reporting_failure == null);
        if (fd) |handle| try std.testing.expect(std.c.fcntl(handle, std.c.F.GETFD) < 0);
        try page.stop();
        try std.testing.expectEqual(@as(u64, report.len), (try output.stat(page.init.?.io)).size);
    }
}

test "Sign-in committed prefix excludes failed dirty tail and shorter overwrite while final exit needs no disk" {
    var rig: BrowserRig = undefined;
    try rig.open();
    defer rig.close();
    const page = &rig.page;
    page.outcome = .{ .failed = .{ .cause = error.FirstCommittedMarker } };
    try page.stageReceipt(null);
    const prefix = page.receipts.?.committed_end;
    var large = try testingActivation(page.init.?);
    large.launch = .failed(.child_refused, error.HostStartupFailed);
    @memset(&large.launch.?.startup_bytes, 'x');
    const dirty = "LongUncommittedTailMustNotAppear";
    @memcpy(large.launch.?.startup_bytes[512..][0..dirty.len], dirty);
    large.launch.?.startup_len = large.launch.?.startup_bytes.len;
    page.outcome = .{ .published = .{ .defaults = {}, .activation = large } };
    try std.testing.expectError(error.NoSpaceLeft, page.stageReceipt(.{ .after = max_receipt_bytes, .cause = error.NoSpaceLeft }));
    try std.testing.expectEqual(prefix, page.receipts.?.committed_end);
    page.outcome = .{ .failed = .{ .cause = error.X } };
    try page.stageReceipt(null);
    try std.testing.expect((try page.receipts.?.file.stat(page.init.?.io)).size > page.receipts.?.committed_end);
    page.outcome = .{ .failed = .{ .cause = error.FinalInMemoryMarker } };
    var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
    try std.testing.expectError(error.FirstCommittedMarker, page.stopTo(&report.writer));
    const text = report.written();
    for ([_][]const u8{ "FirstCommittedMarker", "(X)", "FinalInMemoryMarker" }) |needle| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, needle));
    try std.testing.expect(std.mem.indexOf(u8, text, "LongUncommittedTailMustNotAppear") == null);
}

test "Sign-in setup map and worker start failures retain cause and permit recovery handoff" {
    for (std.enums.values(SetupFault)) |fault| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        page.frozen = .{ .intent = .{}, .provider = .chatgpt, .model = "fixture-model", .key = .{ .provided = "" }, .endpoint = .{ .unchanged = host_start.openai_endpoint } };
        page.state = .{ .page = .browser };
        try page.beginWithFault(&rig.ctx, .browser, fault);
        const expected = if (fault == .browser_map) error.InjectedBrowserMapFailure else error.InjectedWorkerStartFailure;
        try std.testing.expectEqual(expected, page.outcome.?.failed.cause);
        try std.testing.expect(page.task.thread == null and page.browser == null and page.state.page == .failed);
        try page.stageReceipt(null);
        page.outcome = .cancelled;
        var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        try std.testing.expectError(expected, page.stopTo(&report.writer));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), @errorName(expected)));
    }
}

test "Sign-in deferred read failure retains custody and teardown closes the single descriptor" {
    var rig: BrowserRig = undefined;
    try rig.open();
    defer rig.close();
    const page = &rig.page;
    page.outcome = .{ .failed = .{ .cause = error.RetainedOperationFailure } };
    try page.stageReceipt(null);
    const fd = page.receipts.?.file.handle;
    try page.receipts.?.file.setLength(page.init.?.io, 0);
    var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
    try std.testing.expectError(error.SignInReceiptReadFailed, page.stopTo(&report.writer));
    try std.testing.expect(page.receipts != null and page.receipts.?.reported == 0);
    try std.testing.expect(page.receipts.?.first_failure.? == error.RetainedOperationFailure);
    try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) >= 0);
    page.deinit();
    try std.testing.expect(page.receipts == null and page.outcome == null);
    try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) < 0);
    page.deinit();
}

test "Sign-in receipt budget admits full escaped cleanup identity and refuses cumulative overflow without loss" {
    var rig: BrowserRig = undefined;
    try rig.open();
    defer rig.close();
    const page = &rig.page;
    var path: protocol.Bounded(@import("host_settings.zig").max_path_bytes) = .{};
    var native_path: [@import("host_settings.zig").max_path_bytes]u8 = @splat(1);
    native_path[0] = '/';
    try path.set(&native_path);
    const retained: Outcome = .{ .published = .{ .defaults = {}, .activation = error.ConnectionNotActive, .connection = .{ .failed = .{ .cause = error.RetainedSaveCause, .cleanup = .{ .cause = error.RetainedCleanupCause, .key_file = path } } } } };
    var accepted: usize = 0;
    while (true) {
        page.outcome = retained;
        page.stageReceipt(null) catch |err| {
            try std.testing.expectEqual(error.SignInReceiptLimit, err);
            try std.testing.expect(page.retention_failure.?.unavailable == err);
            break;
        };
        accepted += 1;
        try std.testing.expect(accepted < 256);
    }
    try std.testing.expect(accepted >= 16);
    try std.testing.expect(page.outcome != null);
    const kept = page.receipts.?;
    try std.testing.expect(kept.committed_end <= max_deferred_bytes);
    try std.testing.expect((try kept.file.stat(page.init.?.io)).size <= max_deferred_bytes);
    var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
    try std.testing.expectError(error.RetainedSaveCause, page.stopTo(&report.writer));
    try std.testing.expectEqual(accepted + 1, std.mem.count(u8, report.written(), "RetainedSaveCause"));
    try std.testing.expectEqual(accepted + 1, std.mem.count(u8, report.written(), "RetainedCleanupCause"));
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "SignInReceiptLimit") != null);
    try std.testing.expect(page.receipts == null and page.outcome == null);
    try std.testing.expect(std.c.fcntl(kept.file.handle, std.c.F.GETFD) < 0);
}

test "Sign-in departure resumes only acknowledged bytes after deferred or current output failure" {
    const Sink = struct {
        writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        bytes: []u8,
        count: usize = 0,
        limit: usize,

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", writer));
            std.debug.assert(data.len == 1 and splat == 1);
            if (self.count == self.limit) return error.WriteFailed;
            const count = @min(data[0].len, self.limit - self.count);
            @memcpy(self.bytes[self.count..][0..count], data[0][0..count]);
            self.count += count;
            return count;
        }
    };
    for ([_]bool{ false, true }) |fail_in_current| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        page.outcome = .{ .failed = .{ .cause = error.FirstOperationCause } };
        var expected: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        _ = try page.writeOutcome(&expected.writer);
        const first_length = expected.written().len;
        try page.stageReceipt(null);
        page.outcome = .{ .failed = .{ .cause = error.LastOperationCause } };
        _ = try page.writeOutcome(&expected.writer);
        const bytes = try rig.arena.allocator().alloc(u8, expected.written().len);
        var sink: Sink = .{ .bytes = bytes, .limit = if (fail_in_current) first_length + 7 else 7 };
        const fd = page.receipts.?.file.handle;
        try std.testing.expectError(error.WriteFailed, page.stopTo(&sink.writer));
        try std.testing.expect(page.receipts != null and page.outcome != null);
        try std.testing.expectEqual(@as(u64, if (fail_in_current) first_length else 7), page.receipts.?.reported);
        try std.testing.expectEqual(@as(usize, if (fail_in_current) 7 else 0), page.reported_current);
        try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) >= 0);
        sink.limit = bytes.len;
        try std.testing.expectError(error.FirstOperationCause, page.stopTo(&sink.writer));
        try std.testing.expectEqualStrings(expected.written(), bytes[0..sink.count]);
        try std.testing.expect(page.receipts == null and page.outcome == null);
        try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) < 0);
        try page.stopTo(&sink.writer);
        try std.testing.expectEqual(bytes.len, sink.count);
    }
}

test "Sign-in native departure contextualizes deferred read and current output failure then resumes exactly once" {
    const Failure = enum { deferred_read, current_output };
    for (std.enums.values(Failure)) |failure| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        defer page.deinit();
        const io = page.init.?.io;
        page.outcome = .{ .failed = .{ .cause = error.FirstOperationCause } };
        var expected: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        _ = try page.writeOutcome(&expected.writer);
        const first_length = expected.written().len;
        try page.stageReceipt(null);
        page.outcome = .{ .failed = .{ .cause = error.LastOperationCause } };
        _ = try page.writeOutcome(&expected.writer);
        const retained_fd = page.receipts.?.file.handle;
        const output = try rig.tmp.dir.createFile(io, "native-departure", .{ .read = true });
        defer output.close(io);
        const readonly = try rig.tmp.dir.openFile(io, "native-departure", .{});
        defer readonly.close(io);
        const saved_stderr = std.c.dup(2);
        if (saved_stderr < 0) return error.TestRedirectFailed;
        defer _ = std.c.close(saved_stderr);
        if (std.c.dup2(output.handle, 2) != 2) return error.TestRedirectFailed;
        defer std.debug.assert(std.c.dup2(saved_stderr, 2) == 2);
        switch (failure) {
            .deferred_read => try page.receipts.?.file.setLength(io, 7),
            .current_output => {
                try page.drainReceipts(.native_departure);
                try std.testing.expectEqual(@as(u64, first_length), page.receipts.?.reported);
                if (std.c.dup2(readonly.handle, 2) != 2) return error.TestRedirectFailed;
            },
        }
        try std.testing.expectError(error.SignInReportingUnavailable, page.stop());
        const cause = if (failure == .deferred_read) error.ReceiptReadFailed else error.ReceiptWriteFailed;
        try std.testing.expectEqual(cause, page.reporting_failure.?);
        try std.testing.expect(page.receipts != null and page.outcome != null);
        try std.testing.expect(page.retention_failure == null);
        try std.testing.expectEqual(error.FirstOperationCause, page.receipts.?.first_failure.?);
        try std.testing.expectEqual(error.LastOperationCause, page.outcome.?.failed.cause);
        const acknowledged = if (failure == .deferred_read) 7 else first_length;
        try std.testing.expectEqual(@as(u64, acknowledged), page.receipts.?.reported);
        try std.testing.expectEqual(@as(usize, 0), page.reported_current);
        try std.testing.expect(std.c.fcntl(retained_fd, std.c.F.GETFD) >= 0);
        const bytes = try rig.arena.allocator().alloc(u8, expected.written().len + 1);
        const partial = bytes[0..try output.readPositionalAll(io, bytes, 0)];
        try std.testing.expectEqualStrings(expected.written()[0..acknowledged], partial);
        if (failure == .deferred_read) try page.receipts.?.file.writePositionalAll(io, expected.written()[0..first_length], 0);
        if (std.c.dup2(output.handle, 2) != 2) return error.TestRedirectFailed;
        try std.testing.expectError(error.FirstOperationCause, page.stop());
        const report = bytes[0..try output.readPositionalAll(io, bytes, 0)];
        try std.testing.expectEqualStrings(expected.written(), report);
        for ([_][]const u8{ "FirstOperationCause", "LastOperationCause" }) |name| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report, name));
        try std.testing.expect(page.receipts == null and page.outcome == null and page.reporting_failure == null);
        try std.testing.expectEqual(@as(usize, 0), page.reported_current);
        try std.testing.expect(std.c.fcntl(retained_fd, std.c.F.GETFD) < 0);
        try page.stop();
        try std.testing.expectEqual(@as(u64, report.len), (try output.stat(io)).size);
    }
}

test "Sign-in every guided page and focused control stays bounded and masked over resize" {
    const Check = struct {
        fn surface(value: vxfw.Surface, unicode: bool) !void {
            if (value.cursor) |cursor| {
                try std.testing.expect(cursor.row < value.size.height and cursor.col < value.size.width);
            }
            for (value.buffer) |cell| if (!unicode) for (cell.char.grapheme) |byte| try std.testing.expect(byte < 128);
            for (value.children) |child| {
                try std.testing.expect(child.origin.row >= 0 and child.origin.col >= 0);
                try std.testing.expect(child.origin.row + child.surface.size.height <= value.size.height);
                try std.testing.expect(child.origin.col + child.surface.size.width <= value.size.width);
                try surface(child.surface, unicode);
            }
        }
    };
    var page: Self = .{};
    defer page.closeForm();
    const form = try page.ensureForm();
    _ = form.key.set("never-render-this-key", "never-render-this-key".len);
    try page.code.set("DRAWN-1234");
    try page.target.set("/synthetic store");
    const pages_ = [_]core.Page{ .account, .method, .api, .browser, .device, .{ .stopping = .method }, .{ .saving = .key }, .{ .failed = .{ .failure = .expired, .retry = .browser } }, .pending, .connected };
    const widths = [_]u16{ 0, 1, 2, 3, 14, 19, 20, 39, 40, 71, 72, 80 };
    const heights = [_]u16{ 0, 1, 2, 3, 4, 7, 12, 24 };
    for ([_]bool{ false, true }) |unicode| for (pages_) |page_| {
        page.state.page = page_;
        page.unicode = unicode;
        for (page.state.controls()) |focus| {
            page.state.focus = focus;
            for (widths) |width| for (heights) |height| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const value = try testingDraw(&page, arena.allocator(), width, height);
                try Check.surface(value, unicode);
                const text = try testingText(value, arena.allocator());
                try std.testing.expect(std.mem.indexOf(u8, text, "never-render-this-key") == null);
            };
        }
    };
    try std.testing.expectEqualStrings("never-render-this-key", form.key.text());
}

test "Sign-in lays every cell of its dialog on its own ground on every page, focus and size" {
    // The dialog is a raised surface above a dimmed screen; one cell left on the terminal's
    // ground (a rule, a title, a hovered row, a stitch) would be a hole in the card.
    var page: Self = .{};
    defer page.closeForm();
    const form = try page.ensureForm();
    _ = form.key.set("key", 3);
    try page.code.set("DRAWN-1234");
    try page.target.set("/synthetic store");
    const pages_ = [_]core.Page{ .account, .method, .api, .browser, .device, .{ .stopping = .method }, .{ .saving = .key }, .{ .failed = .{ .failure = .expired, .retry = .browser } }, .pending, .connected };
    const sizes = [_]vxfw.Size{ .{ .width = 140, .height = 40 }, .{ .width = 80, .height = 24 }, .{ .width = 46, .height = 30 }, .{ .width = 40, .height = 10 }, .{ .width = 39, .height = 24 }, .{ .width = 80, .height = 9 } };
    for ([_]bool{ false, true }) |unicode| for (pages_) |page_| {
        page.state.page = page_;
        page.unicode = unicode;
        for (page.state.controls()) |focus| {
            page.state.focus = focus;
            for (sizes) |size| {
                var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const drawn = try testingDraw(&page, a, size.width, size.height);
                var screen = try vaxis.Screen.init(a, .{ .cols = size.width, .rows = size.height, .x_pixel = 0, .y_pixel = 0 });
                const window: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = size.width, .height = size.height, .screen = &screen };
                try drawn.render(window, page.widget());
                // Framed, the dialog is the card's rectangle; unframed, it is the whole screen.
                const framed = drawn.buffer.len == 0;
                const laid = drawn.children[drawn.children.len - 1];
                const left: usize = if (framed) @intCast(laid.origin.col) else 0;
                const top: usize = if (framed) @intCast(laid.origin.row) else 0;
                const width: usize = if (framed) laid.surface.size.width else size.width;
                const height: usize = if (framed) laid.surface.size.height else size.height;
                for (top..top + height) |row| for (left..left + width) |col| {
                    const bg = screen.buf[row * size.width + col].style.bg;
                    try std.testing.expect(bg.eql(page.palette().ground.bg) or bg.eql(page.palette().selection.bg));
                };
            }
        }
    };
}

test "Sign-in draws its card in the app's current skin and depth, as the scrim beneath it does" {
    var caps: @import("overview_view.zig").Caps = .{};
    var page: Self = .{ .caps = &caps };
    for ([_]?@import("overview_view.zig").Rgb{ null, .{ 0xf4, 0xef, 0xe2 } }) |background| for ([_]@import("overview_view.zig").Caps.Depth{ .direct, .indexed }) |depth| {
        // The app learns its skin after Sign-in exists; the card follows without being told.
        caps.background = background;
        caps.depth = depth;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const drawn = try testingDraw(&page, arena.allocator(), 80, 24);
        const laid = drawn.children[1].surface;
        const raised = @import("widget_style.zig").of(caps, .{ .background = .raised });
        try std.testing.expect(laid.readCell(0, 0).style.bg.eql(raised.bg));
        try std.testing.expect(!raised.bg.eql(@import("widget_style.zig").backdrop(caps).bg));
    };
}

test "Sign-in pending and uncertain API receipts survive replacement by either ChatGPT method without lending authority" {
    for ([_]bool{ false, true }) |uncertain| for ([_]core.Attempt{ .browser, .device }) |next| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        var connection: host_start.Connection = .{};
        try connection.endpoint.set("https://custom.example/responses");
        try connection.key_file.set("/synthetic retained/.private.key");
        var activation = try testingActivation(page.init.?);
        activation.pending = true;
        page.attempt = .key;
        page.state = .{ .page = .{ .saving = .key } };
        page.outcome = .{ .published = .{ .defaults = {}, .activation = activation, .connection = if (uncertain) .{ .uncertain = .{ .connection = connection, .cause = error.DirectorySyncFailed } } else .{ .saved = connection } } };
        try page.settle(.{ .screen = &rig.ctx });
        try std.testing.expect(page.state.page == .pending and page.saved != null);
        try page.stageReceipt(null);
        try std.testing.expect(try page.freeze(next, .{ .method = if (next == .browser) .browser else .device }));
        page.state.page = if (next == .browser) .browser else .device;
        try page.beginWithFault(&rig.ctx, next, .worker_start);
        try std.testing.expect(page.saved == null and page.state.page == .failed);
        var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        try std.testing.expectError(if (uncertain) error.DirectorySyncFailed else error.ConnectionNotActive, page.stopTo(&report.writer));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "InjectedWorkerStartFailure"));
        if (uncertain) {
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), connection.key_file.slice()));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "DirectorySyncFailed"));
        } else try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "Connection saved, not active"));
    };
}

test "Sign-in API form setup retains inspect and map causes across recovery without replacing prior receipts" {
    for (std.enums.values(FormFault)) |fault| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        page.outcome = .{ .failed = .{ .cause = error.PriorOperationCause } };
        _ = try testingDraw(page, rig.ctx.alloc, 90, 28);
        try page.activateDrawnWithFault(&rig.ctx, .{ .choose = .api_key }, fault);
        const cause = if (fault == .inspect) error.InjectedConnectionInspectFailure else error.InjectedFormMapFailure;
        try std.testing.expect(page.state.page == .failed and page.state.page.failed.retry == .key);
        try std.testing.expect(page.form == null and page.task.thread == null and page.outcome.?.failed.cause == cause);
        try rig.send("\r");
        try std.testing.expect(page.state.page == .api and page.form != null and page.task.thread == null);
        var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        try std.testing.expectError(error.PriorOperationCause, page.stopTo(&report.writer));
        for ([_][]const u8{ "PriorOperationCause", @errorName(cause) }) |name| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), name));
    }
}

test "Sign-in stale blank key cannot activate endpoint-only or source-only supersession and retry reloads after join" {
    const Hooks = struct {
        var activations: std.atomic.Value(u32) = .init(0);
        fn yes() bool {
            return true;
        }
        fn activate(init_: std.process.Init, _: selection.Intent, _: ?*const host_start.Connection) !Activation {
            _ = activations.fetchAdd(1, .monotonic);
            return testingActivation(init_);
        }
    };
    const Change = enum { endpoint, source };
    for (std.enums.values(Change)) |change| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        Hooks.activations.store(0, .monotonic);
        page.activate = Hooks.activate;
        page.selectors.model = "custom-model";
        const store = try std.fs.path.join(rig.arena.allocator(), &.{ rig.env.get("HOME").?, "selected" });
        try page.target.set(store);
        const first = try host_start.saveConnection(page.init.?, store, .{ .base = "https://first.example/v1" }, .{ .provided = "first-key" }, "custom-model", Hooks.yes);
        try std.testing.expect(first == .saved);
        const assignment = try host_start.connectionAssignment(page.init.?, rig.arena.allocator(), &first.saved);
        try std.testing.expect(std.mem.indexOf(u8, assignment, "first-key") == null);
        try rig.send("\t\r");
        try std.testing.expect(page.state.page == .api and page.form.?.value.original.reusable());
        const endpoint = if (change == .endpoint) "https://second.example/v2/responses" else first.saved.endpoint.slice();
        if (change == .endpoint) {
            var failure: @import("start_report.zig").Failure = undefined;
            try host_start.savedEdit(page.init.?, store, "providers.openai.endpoint", endpoint, &failure);
            try std.Io.Dir.cwd().deleteFile(page.init.?.io, first.saved.key_file.slice());
        } else {
            const other = try host_start.saveConnection(page.init.?, store, .{ .unchanged = endpoint }, .{ .provided = "second-key" }, "custom-model", Hooks.yes);
            try std.Io.Dir.cwd().deleteFile(page.init.?.io, other.saved.key_file.slice());
        }
        page.state.focus = .connect;
        try rig.send("\r");
        try rig.wait(testingCompleted);
        try page.advance(&rig.ctx);
        try std.testing.expect(page.task.thread == null and page.form == null and page.frozen == null and page.saved == null);
        try std.testing.expect(page.state.page == .failed and page.state.page.failed.failure == .superseded and page.state.page.failed.retry == .key);
        try std.testing.expectEqual(@as(u32, 0), Hooks.activations.load(.monotonic));
        try rig.send("\r");
        try std.testing.expect(page.state.page == .api and page.form != null);
        try std.testing.expectEqualStrings(endpoint, page.form.?.value.original.endpoint.slice());
        try std.testing.expect(!page.form.?.value.original.reusable());
        var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        try std.testing.expectError(error.ConnectionSuperseded, page.stopTo(&report.writer));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "ConnectionSuperseded"));
        try std.testing.expectEqual(@as(u32, 0), Hooks.activations.load(.monotonic));
    }
}

test "Sign-in required receipt context retains original I/O causes without changing current serialized bytes" {
    for ([_]anyerror{ error.NoSpaceLeft, error.WriteFailed, error.AccessDenied, error.ReceiptReadFailed }) |cause| {
        var page: Self = .{ .outcome = .{ .failed = .{ .cause = error.OriginalOperationFailure } } };
        var before_bytes: [max_receipt_bytes]u8 = undefined;
        var before: std.Io.Writer = .fixed(&before_bytes);
        _ = try page.writeOutcome(&before);
        try std.testing.expectEqual(error.SignInReportingUnavailable, page.receiptIoFailure(.native_departure, cause));
        try std.testing.expectEqual(cause, page.reporting_failure.?);
        try std.testing.expect(page.outcome.?.failed.cause == error.OriginalOperationFailure);
        var after_bytes: [max_receipt_bytes]u8 = undefined;
        var after: std.Io.Writer = .fixed(&after_bytes);
        _ = try page.writeOutcome(&after);
        try std.testing.expectEqualStrings(before.buffered(), after.buffered());
        try std.testing.expectEqual(cause, page.receiptIoFailure(.{ .departure = &after }, cause));
        page.deinit();
    }
    var internal: Self = .{};
    try std.testing.expectEqual(error.SignInReceiptPartlyReported, internal.retainFailure(.{ .internal = error.SignInReceiptPartlyReported }));
    try std.testing.expect(internal.retention_failure.? == .internal);
    try std.testing.expectEqual(error.SignInReceiptPartlyReported, internal.retention_failure.?.cause());
}

test "Sign-in matching recheck keeps original uncertainty authority and never activates before confirmed durability" {
    const Hooks = struct {
        var activations: usize = 0;
        fn activate(init_: std.process.Init, _: selection.Intent, _: ?*const host_start.Connection) !Activation {
            activations += 1;
            return testingActivation(init_);
        }
    };
    for ([_]bool{ false, true }) |renamed| {
        var rig: BrowserRig = undefined;
        try rig.open();
        defer rig.close();
        const page = &rig.page;
        Hooks.activations = 0;
        page.activate = Hooks.activate;
        var connection: host_start.Connection = .{};
        try connection.endpoint.set("https://custom.example/responses");
        try connection.key_file.set("/synthetic retained/.private.key");
        const form = try page.ensureForm();
        _ = form.model.set("custom-model", "custom-model".len);
        page.frozen = .{ .intent = .{ .store = "/selected-store", .provider = "openai", .model = form.model.text() }, .provider = .openai, .model = form.model.text(), .key = .{ .provided = "" }, .endpoint = .{ .unchanged = connection.endpoint.slice() } };
        page.state.page = .{ .saving = .key };
        page.outcome = .{ .published = page.activatePublished(.{ .uncertain = .{ .connection = connection, .cause = error.DirectorySyncFailed } }) };
        try page.settle(.{ .screen = &rig.ctx });
        try std.testing.expect(page.state.page == .pending);
        try page.stageReceipt(null);
        try std.testing.expect(try page.freeze(.recheck, .recheck));
        page.attempt = .recheck;
        page.state.page = .{ .saving = .recheck };
        const cause = if (renamed) error.InjectedCredentialDirectorySyncFailure else error.InjectedCredentialRenameFailure;
        page.outcome = if (renamed)
            .{ .published = page.activatePublished(.{ .uncertain = .{ .connection = connection, .cause = cause } }) }
        else
            .{ .failed = .{ .cause = cause } };
        try page.settle(.{ .screen = &rig.ctx });
        try std.testing.expectEqual(@as(usize, 0), Hooks.activations);
        try std.testing.expect(page.form.?.value == form and page.savedConnection() != null);
        try std.testing.expectEqualStrings(connection.key_file.slice(), page.savedConnection().?.key_file.slice());
        try std.testing.expectEqualStrings("custom-model", page.frozen.?.model);
        if (renamed) {
            try std.testing.expect(page.state.page == .pending);
            try std.testing.expectEqual(cause, page.saved.?.uncertain.cause);
        } else {
            try std.testing.expect(page.state.page == .failed);
            try std.testing.expectEqual(core.Attempt.recheck, page.state.page.failed.retry);
        }
        try std.testing.expect(try page.freeze(.recheck, .retry));
        var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
        try std.testing.expectError(error.DirectorySyncFailed, page.stopTo(&report.writer));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "(DirectorySyncFailed)"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), @errorName(cause)));
        try std.testing.expectEqual(@as(usize, if (renamed) 2 else 1), std.mem.count(u8, report.written(), connection.key_file.slice()));
        const count = report.written().len;
        try page.stopTo(&report.writer);
        try std.testing.expectEqual(count, report.written().len);
    }
}

test "Sign-in unknown API settings reach typed form failure instead of a guessed binding" {
    var rig: BrowserRig = undefined;
    try rig.open();
    defer rig.close();
    const page = &rig.page;
    const store = try std.fs.path.join(rig.arena.allocator(), &.{ rig.env.get("HOME").?, "store" });
    var directory = try std.Io.Dir.cwd().createDirPathOpen(page.init.?.io, store, .{ .permissions = .fromMode(0o700) });
    defer directory.close(page.init.?.io);
    const file = try directory.createFile(page.init.?.io, "host.json", .{ .permissions = .fromMode(0o600) });
    defer file.close(page.init.?.io);
    try file.writeStreamingAll(page.init.?.io, "{");
    try page.target.set(store);
    try rig.send("\t\r");
    try std.testing.expect(page.state.page == .failed and page.state.page.failed.retry == .key);
    try std.testing.expect(page.outcome.?.failed.cause == error.SettingsInvalid);
    try std.testing.expect(page.form == null and page.task.thread == null);
    var report: std.Io.Writer.Allocating = .init(rig.arena.allocator());
    try std.testing.expectError(error.SettingsInvalid, page.stopTo(&report.writer));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.written(), "SettingsInvalid"));
}
