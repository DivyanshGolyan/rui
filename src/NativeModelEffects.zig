//! One joined worker for /model's Host reads and preference saves. The UI
//! owns picker state and the current default; this owns only in-flight work.
const std = @import("std");
const Task = @import("ClientTask.zig");
const models = @import("model_picker.zig");
const replies = @import("protocol_reply.zig");
const preferences = @import("preferences.zig");
const view = @import("overview_view.zig");
const stderr = @import("stderr.zig");
const session_view = @import("session_view.zig");
const protocol = @import("protocol.zig");
const Self = @This();

pub const Session = struct { id: [protocol.session_id_bytes]u8, epoch: u64 };
const Job = union(enum) { list: u64, save: view.Default, session: Session };
pub const Completion = union(enum) {
    list: struct { generation: u64, read: @import("NativeModelPicker.zig").Read, failure: ?anyerror },
    save: struct { binding: view.Default, failure: ?anyerror },
    session: struct { request: Session, binding: ?view.Default, failure: ?anyerror },
};
allocator: std.mem.Allocator,
io: std.Io,
home: []const u8,
store: []const u8,
scratch: ?std.Io.File = null,
task: Task = .{},
active: ?Job = null,
pending_list: ?u64 = null,
pending_save: ?view.Default = null,
pending_session: ?Session = null,
session_binding: ?view.Default = null,
menu: ?models.Menu = null,

pub fn requestList(self: *Self, generation: u64) void { self.pending_list = generation; }
pub fn requestSave(self: *Self, binding: view.Default) void { self.pending_save = binding; }
pub fn requestSession(self: *Self, request: Session) void { self.pending_session = request; }
pub fn cancelSession(self: *Self) void {
    self.pending_session = null;
    if (self.active) |job| if (job == .session) self.task.cancel();
}
pub fn saving(self: *const Self) bool {
    return self.pending_save != null or if (self.active) |job| job == .save else false;
}
pub fn cancelList(self: *Self) void {
    self.pending_list = null;
    if (self.active) |job| if (job == .list) self.task.cancel();
}

pub fn start(self: *Self) !void {
    if (self.task.thread != null) return;
    const job: Job = if (self.pending_save) |binding| .{ .save = binding } else if (self.pending_session) |request| .{ .session = request } else if (self.pending_list) |generation| .{ .list = generation } else return;
    self.active = job;
    try self.task.start(self.io, self, work);
    switch (job) { .save => self.pending_save = null, .session => self.pending_session = null, .list => self.pending_list = null }
}
fn work(raw: *anyopaque, task: *Task) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    switch (self.active.?) {
        .list => {
            const body = try task.requests().modelList(self.store, self.allocator);
            defer self.allocator.free(body);
            self.menu = try models.read(self.allocator, try replies.modelListProviders(body));
        },
        .session => |request| {
            const current = try session_view.current(task.requests(), self.store, &request.id, self.scratch.?);
            self.session_binding = view.Default.of(@tagName(current.settings.provider.value), current.settings.model.slice()) orelse return error.InvalidResponse;
        },
        .save => |binding| {
            const readiness: preferences.Readinesses = .initFill(.configured);
            _ = try preferences.update(self.home, .{ .provider = .{ .set = @tagName(binding.provider) }, .model = .{ .set = binding.model.slice() } }, &readiness);
        },
    }
}
pub fn complete(self: *Self) ?Completion {
    if (self.task.thread == null or !self.task.completed()) return null;
    const job = self.active.?;
    const failure: ?anyerror = if (self.task.join()) |_| null else |err| err;
    self.active = null;
    return switch (job) {
        .list => |generation| .{ .list = .{ .generation = generation, .read = if (failure) |err| (if (err == error.InvalidModelList) .invalid else .unanswered) else .{ .menu = self.takeMenu() }, .failure = failure } },
        .save => |binding| .{ .save = .{ .binding = binding, .failure = failure } },
        .session => |request| blk: {
            const binding = self.session_binding;
            self.session_binding = null;
            break :blk .{ .session = .{ .request = request, .binding = binding, .failure = failure } };
        },
    };
}
fn takeMenu(self: *Self) models.Menu { const menu = self.menu.?; self.menu = null; return menu; }

/// Preference saves are not cancelled: wait for the active write and commit
/// the newest pending pick before returning, even as the UI closes.
pub fn deinit(self: *Self) void {
    if (self.task.thread != null) {
        if (self.active.? != .save) self.task.cancel();
        self.task.join() catch |err| if (self.active.? == .save) {
            reportSaveFailure(err);
        };
    }
    if (self.menu) |*menu| menu.deinit(self.allocator);
    if (self.pending_save) |binding| {
        const readiness: preferences.Readinesses = .initFill(.configured);
        if (preferences.update(self.home, .{ .provider = .{ .set = @tagName(binding.provider) }, .model = .{ .set = binding.model.slice() } }, &readiness)) |_| {} else |err| {
            reportSaveFailure(err);
        }
    }
}

fn reportSaveFailure(err: anyerror) void {
    if (err == error.PreferenceDirectorySyncFailed) {
        stderr.diagnostic("rui: model default publication or durability unconfirmed; inspect defaults before another update.\n", .{});
    } else {
        stderr.diagnostic("rui: model default save failed: {s}\n", .{@errorName(err)});
    }
}

test "model job queue cancels obsolete reads without losing newest save" {
    var effects: Self = .{ .allocator = std.testing.allocator, .io = std.testing.io, .home = "unused", .store = "unused" };
    const first = view.Default.of("codex", "alpha").?;
    const latest = view.Default.of("openai", "beta").?;
    effects.requestList(4);
    effects.requestSave(first);
    effects.requestSave(latest);
    effects.cancelList();
    try std.testing.expect(effects.pending_list == null);
    try std.testing.expect(effects.pending_save.?.eql(&latest));
    effects.requestList(5);
    try std.testing.expectEqual(@as(?u64, 5), effects.pending_list);
    try std.testing.expect(effects.pending_save.?.eql(&latest));
}
