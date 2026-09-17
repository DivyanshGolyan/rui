const std = @import("std");
const protocol = @import("protocol.zig");
const ScratchBudget = @import("ScratchBudget.zig");

pub const orchestration_bytes: usize = 64 * 1024;

const State = enum(u8) { free, reserved, retained, evicting, failed };

pub const Entry = struct {
    state: State = .free,
    generation: u64 = 0,
    sequence: u64 = 0,
    name: protocol.Bounded(96) = .{},
    charged: u64 = 0,
};

pub const Token = struct {
    index: usize,
    generation: u64,
};

pub const Pair = struct {
    stdout: Token,
    stderr: Token,
};

pub const Queue = struct {
    io: std.Io,
    scratch_path: []const u8,
    budget: ScratchBudget,
    entries: []Entry,
    mutex: std.Io.Mutex = .init,
    next_sequence: u64 = 1,

    pub fn initialize(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        entries: []Entry,
    ) Queue {
        for (entries) |*entry| entry.* = .{};
        return .{
            .io = io,
            .scratch_path = scratch_path,
            .budget = budget,
            .entries = entries,
        };
    }

    pub fn sharedBudget(self: *Queue) ScratchBudget {
        return .{
            .used = self.budget.used,
            .limit = self.budget.limit,
            .reclaim_context = self,
            .reclaim_fn = reclaimForReservation,
        };
    }

    pub fn retainPair(
        self: *Queue,
        stdout_name: []const u8,
        stdout_charged: u64,
        stderr_name: []const u8,
        stderr_charged: u64,
    ) !bool {
        const pair = (try self.reservePair(stdout_name, stdout_charged, stderr_name, stderr_charged)) orelse return false;
        self.publishPair(pair) catch |err| {
            self.releaseReservation(pair.stdout);
            self.releaseReservation(pair.stderr);
            return err;
        };
        return true;
    }

    pub fn reservePair(
        self: *Queue,
        stdout_name: []const u8,
        stdout_charged: u64,
        stderr_name: []const u8,
        stderr_charged: u64,
    ) !?Pair {
        var names: [2]protocol.Bounded(96) = .{ .{}, .{} };
        try names[0].set(stdout_name);
        try names[1].set(stderr_name);
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const next = std.math.add(u64, self.next_sequence, 2) catch {
                self.mutex.unlock(self.io);
                return error.RetentionSequenceExhausted;
            };
            var free: [2]usize = undefined;
            var count: usize = 0;
            for (self.entries, 0..) |entry, index| {
                if (entry.state != .free) continue;
                free[count] = index;
                count += 1;
                if (count == free.len) break;
            }
            if (count == free.len) {
                var tokens: [2]Token = undefined;
                for (free, 0..) |index, token_index| {
                    const entry = &self.entries[index];
                    entry.generation +%= 1;
                    if (entry.generation == 0) entry.generation = 1;
                    entry.state = .reserved;
                    entry.sequence = self.next_sequence + token_index;
                    entry.name = names[token_index];
                    entry.charged = if (token_index == 0) stdout_charged else stderr_charged;
                    tokens[token_index] = .{ .index = index, .generation = entry.generation };
                }
                self.next_sequence = next;
                self.mutex.unlock(self.io);
                return .{ .stdout = tokens[0], .stderr = tokens[1] };
            }
            self.mutex.unlock(self.io);
            if (!(try self.evictOldest())) return null;
        }
    }

    pub fn reserveGrowth(self: *Queue, amount: u64) !bool {
        while (!self.budget.reserve(amount)) {
            if (!(try self.evictOldest())) return false;
        }
        return true;
    }

    pub fn releaseGrowth(self: *Queue, amount: u64) void {
        self.budget.release(amount);
    }

    pub fn publishPair(self: *Queue, pair: Pair) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stdout_entry = try self.current(pair.stdout);
        const stderr_entry = try self.current(pair.stderr);
        if (stdout_entry == stderr_entry or stdout_entry.state != .reserved or stderr_entry.state != .reserved) {
            return error.InvalidRetentionTransition;
        }
        stdout_entry.state = .retained;
        stderr_entry.state = .retained;
    }

    pub fn releaseReservation(self: *Queue, token: Token) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.current(token) catch return;
        if (entry.state == .reserved) entry.* = .{ .generation = entry.generation };
    }

    pub fn cleanupAll(self: *Queue) void {
        for (self.entries, 0..) |_, index| {
            self.mutex.lockUncancelable(self.io);
            const entry = &self.entries[index];
            if (entry.state != .retained and entry.state != .failed) {
                self.mutex.unlock(self.io);
                continue;
            }
            const generation = entry.generation;
            const name = entry.name;
            const charged = entry.charged;
            entry.state = .evicting;
            self.mutex.unlock(self.io);
            var scratch = std.Io.Dir.cwd().openDir(self.io, self.scratch_path, .{}) catch {
                self.markEvictionFailed(index, generation);
                continue;
            };
            const removed = result: {
                defer scratch.close(self.io);
                scratch.deleteFile(self.io, name.slice()) catch break :result false;
                break :result true;
            };
            self.mutex.lockUncancelable(self.io);
            if (removed) {
                self.entries[index] = .{ .generation = generation };
                self.budget.release(charged);
            } else {
                self.entries[index].state = .failed;
            }
            self.mutex.unlock(self.io);
        }
    }

    pub fn occupied(self: *Queue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.state != .free) count += 1;
        }
        return count;
    }

    fn current(self: *Queue, token: Token) !*Entry {
        if (token.index >= self.entries.len) return error.ForeignRetentionToken;
        const entry = &self.entries[token.index];
        if (entry.generation != token.generation) return error.StaleRetentionToken;
        return entry;
    }

    fn evictOldest(self: *Queue) !bool {
        self.mutex.lockUncancelable(self.io);
        var oldest: ?usize = null;
        for (self.entries, 0..) |entry, index| {
            if (entry.state != .retained) continue;
            if (oldest == null or entry.sequence < self.entries[oldest.?].sequence) oldest = index;
        }
        const index = oldest orelse {
            self.mutex.unlock(self.io);
            return false;
        };
        const entry = &self.entries[index];
        entry.state = .evicting;
        const generation = entry.generation;
        const name = entry.name;
        const charged = entry.charged;
        self.mutex.unlock(self.io);

        var scratch = std.Io.Dir.cwd().openDir(self.io, self.scratch_path, .{}) catch |err| {
            self.markEvictionFailed(index, generation);
            return err;
        };
        const removed = result: {
            defer scratch.close(self.io);
            scratch.deleteFile(self.io, name.slice()) catch break :result false;
            break :result true;
        };
        self.mutex.lockUncancelable(self.io);
        const selected = &self.entries[index];
        std.debug.assert(selected.generation == generation and selected.state == .evicting);
        if (removed) {
            selected.* = .{ .generation = generation };
            self.budget.release(charged);
        } else {
            selected.state = .failed;
        }
        self.mutex.unlock(self.io);
        return true;
    }

    fn reclaimForReservation(context: *anyopaque, amount: u64, limit: u64) bool {
        const self: *Queue = @ptrCast(@alignCast(context));
        var limited = self.budget;
        limited.limit = @min(limited.limit, limit);
        while (!limited.reserveWithoutReclaim(amount)) {
            if (!(self.evictOldest() catch return false)) return false;
        }
        return true;
    }

    fn markEvictionFailed(self: *Queue, index: usize, generation: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = &self.entries[index];
        if (entry.generation == generation and entry.state == .evicting) entry.state = .failed;
    }
};

test "retention entry capacity derives from fixed orchestration memory" {
    try std.testing.expect(@sizeOf(Entry) > 0);
    try std.testing.expect(orchestration_bytes / @sizeOf(Entry) >= 2);
}

test "retention evicts the oldest pair without refunding newer files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 16 };
    var entries: [2]Entry = undefined;
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    defer queue.cleanupAll();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old-out", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old-err", .data = "b" });
    try std.testing.expect(budget.reserve(2));
    try std.testing.expect(try queue.retainPair("old-out", 1, "old-err", 1));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "new-out", .data = "c" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "new-err", .data = "d" });
    try std.testing.expect(budget.reserve(2));
    try std.testing.expect(try queue.retainPair("new-out", 1, "new-err", 1));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "old-out", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "old-err", .{}));
    const new_out = try tmp.dir.openFile(std.testing.io, "new-out", .{});
    new_out.close(std.testing.io);
    const new_err = try tmp.dir.openFile(std.testing.io, "new-err", .{});
    new_err.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
}

test "shared scratch reservations reclaim retained output and fail when none is eligible" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 3 };
    var entries: [2]Entry = undefined;
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stdout", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stderr", .data = "b" });
    try std.testing.expect(budget.reserve(2));
    try std.testing.expect(try queue.retainPair("stdout", 1, "stderr", 1));
    const shared = queue.sharedBudget();
    try std.testing.expect(shared.reserve(3));
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expect(!shared.reserve(1));
    shared.release(3);
}

test "failed retained-file deletion preserves its entry and scratch charge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 2 };
    var entries: [2]Entry = undefined;
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stdout", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stderr", .data = "b" });
    try std.testing.expect(budget.reserve(2));
    try std.testing.expect(try queue.retainPair("stdout", 1, "stderr", 1));
    try tmp.dir.deleteFile(std.testing.io, "stdout");
    try tmp.dir.deleteFile(std.testing.io, "stderr");

    const shared = queue.sharedBudget();
    try std.testing.expect(!shared.reserve(1));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
    try std.testing.expectEqual(State.failed, entries[0].state);
    try std.testing.expectEqual(State.failed, entries[1].state);
}
