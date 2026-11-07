//! One composer's bounded metadata borrower. Painting only borrows its rows.
const std = @import("std");
const client = @import("client.zig");
const ClientTask = @import("ClientTask.zig");
const Bounded = @import("bounded.zig").Bounded;
const completion = @import("skill_completion.zig");
const suggestions = @import("skill_suggestions.zig");
const commands = @import("slash_commands.zig");
const Self = @This();

const Scope = struct {
    kind: enum { session, workspace } = .session,
    text: Bounded(std.Io.Dir.max_path_bytes) = .{},

    fn set(self: *Scope, scope: suggestions.Scope) !void {
        var next: Scope = .{};
        switch (scope) {
            .session => |value| {
                next.kind = .session;
                try next.text.set(value);
            },
            .workspace => |value| {
                next.kind = .workspace;
                try next.text.set(value);
            },
        }
        self.* = next;
    }

    fn same(self: *const Scope, other: *const Scope) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.text.slice(), other.text.slice());
    }

    fn borrowed(self: *const Scope) suggestions.Scope {
        return switch (self.kind) {
            .session => .{ .session = self.text.slice() },
            .workspace => .{ .workspace = self.text.slice() },
        };
    }
};

const Stamp = struct {
    revision: u64,
    cursor: usize,

    fn same(self: Stamp, other: Stamp) bool {
        return self.revision == other.revision and self.cursor == other.cursor;
    }
};
const Query = struct { scope: Scope = .{}, prefix: Bounded(64) = .{}, version: u64 = 0 };

allocator: ?std.mem.Allocator = null,
io: std.Io = undefined,
store: []const u8 = "",
scope: Scope = .{},
task: ClientTask = .{},
active: Query = .{},
wanted: Bounded(64) = .{},
wanted_valid: bool = false,
version: u64 = 0,
attempted: u64 = 0,
forced: bool = false,
suppressed: ?Stamp = null,
page: ?suggestions.Page = null,
/// Only the worker writes this, and only a joined owner takes it.
response: ?suggestions.Page = null,
words: [suggestions.capacity][65]u8 = undefined,
entries: [suggestions.capacity]commands.Entry = undefined,
count: usize = 0,
generation: u64 = 0,
last_error: ?anyerror = null,

pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, store: []const u8, scope: suggestions.Scope) !void {
    self.* = .{ .allocator = allocator, .io = io, .store = store };
    try self.scope.set(scope);
}

pub fn setScope(self: *Self, scope: suggestions.Scope) !bool {
    if (self.allocator == null) return false;
    var next: Scope = .{};
    try next.set(scope);
    if (self.scope.same(&next)) return false;
    self.scope = next;
    self.invalidate();
    return true;
}

pub fn invalidate(self: *Self) void {
    self.forced = true;
    self.task.cancel();
}

pub fn dismiss(self: *Self, revision: u64, cursor: usize) void {
    self.suppressed = .{ .revision = revision, .cursor = cursor };
}

fn dismissed(self: *const Self, revision: u64, cursor: usize) bool {
    return if (self.suppressed) |stamp| stamp.same(.{ .revision = revision, .cursor = cursor }) else false;
}

fn clearPage(self: *Self) void {
    self.count = 0;
    if (self.page) |*page| page.deinit(self.allocator.?);
    self.page = null;
}

/// Call outside a nonpumping frame. A true result invalidates prior row borrows.
/// Obsolete reads are cancelled, never joined unfinished while editing.
pub fn refresh(self: *Self, text: []const u8, cursor: usize, revision: u64) !bool {
    _ = revision;
    if (self.allocator == null) return false;
    var changed = false;
    const token = completion.candidate(text, cursor);
    const valid = token != null and token.?.prefix.len <= 64;
    const prefix = if (valid) token.?.prefix else "";
    if (self.forced or valid != self.wanted_valid or !std.mem.eql(u8, prefix, self.wanted.slice())) {
        self.forced = false;
        self.version +%= 1;
        self.wanted_valid = valid;
        try self.wanted.set(prefix);
        self.last_error = null;
        self.clearPage();
        self.task.cancel();
        self.generation +%= 1;
        changed = true;
    }
    if (self.task.thread != null and self.task.completed()) {
        const current = self.active.version == self.version;
        const outcome = self.task.join();
        if (outcome) |_| {
            if (current and self.wanted_valid) {
                self.install() catch |err| {
                    self.last_error = err;
                };
                changed = true;
            }
        } else |err| if (current and err != error.Cancelled) {
            if (err == error.CanonicalStoreFailure) {
                if (self.response) |*response| response.deinit(self.allocator.?);
                self.response = null;
                return err;
            }
            self.last_error = err;
            changed = true;
        }
        if (self.response) |*response| response.deinit(self.allocator.?);
        self.response = null;
    }
    if (self.task.thread == null and self.wanted_valid and self.attempted != self.version) {
        self.active = .{ .scope = self.scope, .prefix = self.wanted, .version = self.version };
        self.attempted = self.version;
        self.task.start(self.io, self, read) catch |err| {
            self.last_error = err;
            return true;
        };
    }
    return changed;
}

fn install(self: *Self) !void {
    const response = &(self.response orelse return error.MissingSkillSuggestions);
    if (response.entries.len > suggestions.capacity) return error.InvalidSkillSuggestions;
    for (response.entries) |entry| if (entry.name.len == 0 or entry.name.len > 64) return error.InvalidSkillSuggestions;
    self.clearPage();
    self.page = self.response;
    self.response = null;
    for (self.page.?.entries, 0..) |entry, index| {
        const word = std.fmt.bufPrint(&self.words[index], "/{s}", .{entry.name}) catch unreachable;
        self.entries[index] = .{ .kind = .skill, .word = word, .shown = word, .description = entry.description, .runs = false };
    }
    self.count = self.page.?.entries.len;
    self.generation +%= 1;
}

fn read(raw: *anyopaque, task: *ClientTask) !void {
    const self: *Self = @ptrCast(@alignCast(raw));
    self.response = try task.requests().skillSuggestions(self.allocator.?, self.store, self.active.scope.borrowed(), self.active.prefix.slice());
}

/// Borrows rows until refresh or close, without allocation or I/O.
pub fn choices(self: *const Self, text: []const u8, cursor: usize, revision: u64) ?commands.SkillChoices {
    if (self.allocator == null) return null;
    const token = completion.candidate(text, cursor) orelse return null;
    if (token.prefix.len > 64) return null;
    const matching = self.wanted_valid and !self.forced and std.mem.eql(u8, token.prefix, self.wanted.slice());
    return .{
        .entries = if (matching) self.entries[0..self.count] else &.{},
        .generation = self.generation,
        .total = if (matching and self.page != null) self.page.?.total else 0,
        .pending = !matching or self.page == null and self.last_error == null,
        .dismissed = self.dismissed(revision, cursor),
    };
}

pub fn busy(self: *const Self) bool {
    return self.task.thread != null;
}

pub fn failure(self: *const Self) ?anyerror {
    return self.last_error;
}

pub fn cancel(self: *Self) void {
    self.task.cancel();
}

/// After editing ends, cancel and retire the metadata borrower before disposal.
pub fn close(self: *Self) !void {
    const allocator = self.allocator orelse return;
    self.task.cancel();
    const joined = self.task.join();
    defer {
        self.clearPage();
        if (self.response) |*response| response.deinit(allocator);
        self.response = null;
        self.allocator = null;
    }
    joined catch |err| if (err != error.Cancelled) return err;
}

fn testPage(allocator: std.mem.Allocator, name: []const u8) !suggestions.Page {
    const entries = try allocator.alloc(suggestions.Entry, 1);
    errdefer allocator.free(entries);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    entries[0] = .{ .name = owned_name, .description = try allocator.dupe(u8, "test description") };
    return .{ .entries = entries, .revision = 19, .total = 4 };
}

test "skill menu owns bounded rows and dismisses only the current cursor identity" {
    const menu = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(menu);
    try menu.init(std.testing.allocator, std.testing.io, "unused", .{ .session = "k7m2qx" });
    defer menu.close() catch unreachable;
    menu.wanted_valid = true;
    try menu.wanted.set("de");
    menu.response = try testPage(std.testing.allocator, "demo");
    try menu.install();
    const chosen = menu.choices("/de, next", 3, 4).?;
    try std.testing.expectEqual(@as(usize, 1), chosen.entries.len);
    try std.testing.expectEqual(@as(usize, 4), chosen.total);
    try std.testing.expectEqualStrings("/demo", chosen.entries[0].word);
    try std.testing.expectEqual(.skill, chosen.entries[0].kind);
    try std.testing.expect(!chosen.pending);
    try std.testing.expect(!chosen.dismissed);
    menu.dismiss(4, 3);
    try std.testing.expect(menu.choices("/de, next", 3, 4).?.dismissed);
    try std.testing.expect(!menu.choices("/de, next", 2, 4).?.dismissed);
    try std.testing.expect(!menu.choices("/de, next", 3, 5).?.dismissed);
    const stale = menu.choices("/different", 4, 5).?;
    try std.testing.expect(stale.pending);
    try std.testing.expectEqual(@as(usize, 0), stale.entries.len);
    try std.testing.expect(menu.choices("https://demo", 12, 5) == null);
}

test "skill menu retains active scope and rejects malformed replacement atomically" {
    const menu = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(menu);
    var workspace = "/old".*;
    try menu.init(std.testing.allocator, std.testing.io, "unused", .{ .workspace = &workspace });
    defer menu.close() catch unreachable;
    menu.active.scope = menu.scope;
    workspace[1] = 'X';
    try std.testing.expectEqualStrings("/old", menu.scope.borrowed().workspace);
    try std.testing.expect(try menu.setScope(.{ .workspace = "/new" }));
    try std.testing.expectEqualStrings("/old", menu.active.scope.borrowed().workspace);
    try std.testing.expectEqualStrings("/new", menu.scope.borrowed().workspace);
    menu.response = try testPage(std.testing.allocator, "kept");
    try menu.install();
    menu.response = try testPage(std.testing.allocator, &@as([65]u8, @splat('a')));
    try std.testing.expectError(error.InvalidSkillSuggestions, menu.install());
    try std.testing.expectEqualStrings("/kept", menu.entries[0].word);
    try std.testing.expectEqual(@as(usize, 1), menu.count);
}

test "skill menu is inert when disabled and clears metadata without starting on an empty draft" {
    const menu = try std.testing.allocator.create(Self);
    defer std.testing.allocator.destroy(menu);
    menu.* = .{};
    try std.testing.expect(!try menu.refresh("/", 1, 0));
    try std.testing.expect(menu.choices("/", 1, 0) == null);
    try menu.close();
    try menu.init(std.testing.allocator, std.testing.io, "unused", .{ .session = "k7m2qx" });
    defer menu.close() catch unreachable;
    menu.wanted_valid = true;
    try menu.wanted.set("demo");
    menu.response = try testPage(std.testing.allocator, "demo");
    try menu.install();
    try std.testing.expect(try menu.refresh("", 0, 2));
    try std.testing.expect(!menu.busy());
    try std.testing.expectEqual(@as(usize, 0), menu.count);
    try std.testing.expect(menu.page == null);
}
