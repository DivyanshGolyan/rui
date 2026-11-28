const std = @import("std");
const named_scratch = @import("named_scratch.zig");
const protocol = @import("protocol.zig");
const ScratchBudget = @import("ScratchBudget.zig");

const capacity = @import("retention_capacity.zig");
pub const orchestration_bytes = capacity.orchestration_bytes;
const State = capacity.State;
pub const Entry = capacity.Entry;

pub const Token = struct {
    index: usize,
    generation: u64,
};

pub const Queue = struct {
    io: std.Io,
    scratch_path: []const u8,
    budget: ScratchBudget,
    entries: []Entry,
    removal: named_scratch.Removal,
    mutex: std.Io.Mutex = .init,
    next_sequence: u64 = 1,

    pub fn initialize(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        entries: []Entry,
    ) Queue {
        return initializeWithRemoval(io, scratch_path, budget, entries, .native);
    }

    pub fn initializeWithRemoval(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        entries: []Entry,
        removal: named_scratch.Removal,
    ) Queue {
        for (entries) |entry| std.debug.assert(entry.state == .free);
        return .{
            .io = io,
            .scratch_path = scratch_path,
            .budget = budget,
            .entries = entries,
            .removal = removal,
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

    fn reserveEntries(self: *Queue, comptime count: usize, file_names: [count][]const u8, charges: [count]u64) !?[count]Token {
        var names: [count]protocol.Bounded(96) = @splat(.{});
        for (&names, file_names) |*name, value| try name.set(value);
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const next = std.math.add(u64, self.next_sequence, count) catch {
                self.mutex.unlock(self.io);
                return error.RetentionSequenceExhausted;
            };
            var free: [count]usize = undefined;
            var found: usize = 0;
            for (self.entries, 0..) |entry, index| {
                if (entry.state != .free) continue;
                free[found] = index;
                found += 1;
                if (found == free.len) break;
            }
            if (found == free.len) {
                var tokens: [count]Token = undefined;
                for (free, 0..) |index, token_index| {
                    const entry = &self.entries[index];
                    entry.generation +%= 1;
                    if (entry.generation == 0) entry.generation = 1;
                    entry.state = .reserved;
                    entry.sequence = self.next_sequence + token_index;
                    entry.name = names[token_index];
                    entry.charged = charges[token_index];
                    tokens[token_index] = .{ .index = index, .generation = entry.generation };
                }
                self.next_sequence = next;
                self.mutex.unlock(self.io);
                return tokens;
            }
            self.mutex.unlock(self.io);
            if (!self.evictOldest()) return null;
        }
    }

    fn releaseReservation(self: *Queue, token: Token) void {
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
            _ = named_scratch.removeNameWith(self.io, self.scratch_path, name.slice(), self.removal) catch {
                self.markEvictionFailed(index, generation);
                continue;
            };
            self.mutex.lockUncancelable(self.io);
            self.entries[index] = .{ .generation = generation };
            self.budget.release(charged);
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

    fn evictOldest(self: *Queue) bool {
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

        _ = named_scratch.removeNameWith(self.io, self.scratch_path, name.slice(), self.removal) catch {
            self.markEvictionFailed(index, generation);
            return false;
        };
        self.mutex.lockUncancelable(self.io);
        const selected = &self.entries[index];
        std.debug.assert(selected.generation == generation and selected.state == .evicting);
        selected.* = .{ .generation = generation };
        self.budget.release(charged);
        self.mutex.unlock(self.io);
        return true;
    }

    fn reclaimForReservation(context: *anyopaque, amount: u64, limit: u64) bool {
        const self: *Queue = @ptrCast(@alignCast(context));
        const limited = self.budget.narrowed(limit);
        while (!limited.charge(amount)) {
            if (!self.evictOldest()) return false;
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

/// Optional full output. The caller opens this only once output must be retained.
/// Until publication the reserved entry cannot be evicted, and this object owns
/// the live charge. The caller must serialize operations on each Spill.
pub const Spill = struct {
    queue: *Queue,
    token: Token,
    file: ?std.Io.File,
    charged: u64 = 0,
    state: Phase = .writing,
    kept: bool = false,

    const Phase = enum { writing, closed, yielded, published };
    const Transition = enum { close, keep, yield };

    /// The one decision table for a spill's state. A pair not listed stays put:
    /// a closed spill does not close again, and a yielded or published spill
    /// takes no further transition.
    fn next(state: Phase, transition: Transition) Phase {
        return switch (state) {
            .writing => switch (transition) {
                .close => .closed,
                .yield => .yielded,
                .keep => .writing,
            },
            .closed => switch (transition) {
                .keep => .published,
                .yield => .yielded,
                .close => .closed,
            },
            .yielded, .published => state,
        };
    }

    /// Store the next state, running the effect that state needs first.
    fn advance(self: *Spill, transition: Transition) void {
        const next_state = next(self.state, transition);
        if (next_state == self.state) return;
        if (next_state == .published) self.publishEntry();
        self.state = next_state;
    }

    pub fn open(queue: *Queue, output_name: []const u8) ?Spill {
        const tokens = (queue.reserveEntries(1, .{output_name}, .{0}) catch return null) orelse return null;
        const token = tokens[0];
        var directory = std.Io.Dir.cwd().openDir(queue.io, queue.scratch_path, .{}) catch {
            queue.releaseReservation(token);
            return null;
        };
        defer directory.close(queue.io);
        const file = directory.createFile(queue.io, output_name, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch {
            queue.releaseReservation(token);
            return null;
        };
        return .{ .queue = queue, .token = token, .file = file };
    }

    /// Adopt a closed capture file and its existing scratch charge. On failure,
    /// the caller retains ownership of both; no descriptor is transferred.
    pub fn adopt(queue: *Queue, output_name: []const u8, charged: u64) ?Spill {
        const tokens = (queue.reserveEntries(1, .{output_name}, .{0}) catch return null) orelse return null;
        return .{ .queue = queue, .token = tokens[0], .file = null, .charged = charged, .state = .closed };
    }

    pub fn write(self: *Spill, bytes: []const u8) void {
        self.writeWith(bytes, struct {
            fn writeSome(file: std.Io.File, io: std.Io, data: []const u8) !usize {
                return file.writeStreaming(io, &.{}, &.{data}, 1);
            }
        }.writeSome);
    }

    fn writeWith(self: *Spill, bytes: []const u8, writeSome: anytype) void {
        if (self.state != .writing or bytes.len == 0) return;
        const amount: u64 = @intCast(bytes.len);
        if (!self.queue.sharedBudget().allocate(amount)) {
            _ = self.yield();
            return;
        }
        // A failed write may have persisted an unknown portion of its input.
        // Keep the entire submitted charge until removal is confirmed.
        self.charged += amount;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = writeSome(self.file.?, self.queue.io, bytes[offset..]) catch {
                _ = self.yield();
                return;
            };
            if (n == 0) {
                _ = self.yield();
                return;
            }
            offset += n;
        }
    }

    /// Remove optional output to give required capture first claim on its budget.
    /// Failed removals transfer the charge to a retryable queue entry.
    pub fn yield(self: *Spill) u64 {
        if (next(self.state, .yield) == self.state) return 0;
        if (self.file) |file| file.close(self.queue.io);
        self.file = null;
        const queue = self.queue;
        queue.mutex.lockUncancelable(queue.io);
        const entry = queue.current(self.token) catch unreachable;
        std.debug.assert(entry.state == .reserved);
        const file_name = entry.name;
        entry.charged = self.charged;
        entry.state = .evicting;
        queue.mutex.unlock(queue.io);
        const removed = named_scratch.removeNameWith(queue.io, queue.scratch_path, file_name.slice(), queue.removal);
        queue.mutex.lockUncancelable(queue.io);
        const current = queue.current(self.token) catch unreachable;
        std.debug.assert(current.state == .evicting);
        const charged = self.charged;
        if (removed) |_| {
            current.* = .{ .generation = current.generation };
            queue.budget.release(charged);
        } else |_| {
            current.state = .failed;
        }
        queue.mutex.unlock(queue.io);
        self.charged = 0;
        self.advance(.yield);
        return if (removed) |_| charged else |_| 0;
    }

    pub fn close(self: *Spill) void {
        if (next(self.state, .close) == self.state) return;
        self.file.?.close(self.queue.io);
        self.file = null;
        self.advance(.close);
        if (self.kept) self.advance(.keep);
    }

    pub fn keep(self: *Spill) void {
        self.kept = true;
        self.advance(.keep);
    }

    pub fn release(self: *Spill) void {
        _ = self.yield();
    }

    pub fn alive(self: *const Spill) bool {
        return self.state != .yielded;
    }

    /// Valid while the spill is alive and has not been published or released.
    pub fn name(self: *const Spill) []const u8 {
        std.debug.assert(self.state == .writing or self.state == .closed);
        return self.queue.entries[self.token.index].name.slice();
    }

    /// Hand the live charge to the reserved queue entry; the spill's state is
    /// set by `advance` once this returns.
    fn publishEntry(self: *Spill) void {
        const queue = self.queue;
        queue.mutex.lockUncancelable(queue.io);
        defer queue.mutex.unlock(queue.io);
        const entry = queue.current(self.token) catch unreachable;
        std.debug.assert(entry.state == .reserved);
        entry.charged = self.charged;
        entry.state = .retained;
        self.charged = 0;
    }
};

fn adoptForTest(queue: *Queue, name: []const u8, charged: u64) !void {
    var spill = Spill.adopt(queue, name, charged) orelse return error.TestUnexpectedResult;
    spill.keep();
}

test "EXR-107 a spill moves through every state x transition as its rules say" {
    const Row = struct { from: Spill.Phase, transition: Spill.Transition, want: Spill.Phase };
    const rows = [_]Row{
        .{ .from = .writing, .transition = .close, .want = .closed },
        .{ .from = .writing, .transition = .keep, .want = .writing },
        .{ .from = .writing, .transition = .yield, .want = .yielded },
        .{ .from = .closed, .transition = .close, .want = .closed },
        .{ .from = .closed, .transition = .keep, .want = .published },
        .{ .from = .closed, .transition = .yield, .want = .yielded },
        .{ .from = .yielded, .transition = .close, .want = .yielded },
        .{ .from = .yielded, .transition = .keep, .want = .yielded },
        .{ .from = .yielded, .transition = .yield, .want = .yielded },
        .{ .from = .published, .transition = .close, .want = .published },
        .{ .from = .published, .transition = .keep, .want = .published },
        .{ .from = .published, .transition = .yield, .want = .published },
    };
    for (rows) |row| {
        try std.testing.expectEqual(row.want, Spill.next(row.from, row.transition));
    }
}

test "retention entry capacity derives from fixed orchestration memory" {
    try std.testing.expect(@sizeOf(Entry) > 0);
    try std.testing.expect(orchestration_bytes / @sizeOf(Entry) >= 2);
}

test "retention evicts the oldest files without refunding newer files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 16 };
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    defer queue.cleanupAll();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old-out", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "old-err", .data = "b" });
    try std.testing.expect(budget.charge(2));
    try adoptForTest(&queue, "old-out", 1);
    try adoptForTest(&queue, "old-err", 1);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "new-out", .data = "c" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "new-err", .data = "d" });
    try std.testing.expect(budget.charge(2));
    try adoptForTest(&queue, "new-out", 1);
    try adoptForTest(&queue, "new-err", 1);
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
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stdout", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stderr", .data = "b" });
    try std.testing.expect(budget.charge(2));
    try adoptForTest(&queue, "stdout", 1);
    try adoptForTest(&queue, "stderr", 1);
    const shared = queue.sharedBudget();
    try std.testing.expect(!shared.charge(3));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
    try std.testing.expect(shared.allocate(3));
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expect(!shared.allocate(1));
    shared.release(3);
}

test "already absent retained files release their entries and scratch charge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 2 };
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stdout", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stderr", .data = "b" });
    try std.testing.expect(budget.charge(2));
    try adoptForTest(&queue, "stdout", 1);
    try adoptForTest(&queue, "stderr", 1);
    try tmp.dir.deleteFile(std.testing.io, "stdout");
    try tmp.dir.deleteFile(std.testing.io, "stderr");

    const shared = queue.sharedBudget();
    try std.testing.expect(shared.allocate(2));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    shared.release(2);
}

test "unconfirmed retained-file deletion preserves its entry and scratch charge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var missing_buffer: [protocol.max_store_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buffer, "{s}/missing", .{root});
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 2 };
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, missing, budget, &entries);

    try std.testing.expect(budget.charge(2));
    try adoptForTest(&queue, "stdout", 1);
    try adoptForTest(&queue, "stderr", 1);

    try std.testing.expect(Spill.open(&queue, "new-output") == null);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
    try std.testing.expectEqual(State.failed, entries[0].state);
    try std.testing.expectEqual(State.retained, entries[1].state);
    const shared = queue.sharedBudget();
    try std.testing.expect(!shared.allocate(1));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
    try std.testing.expectEqual(State.failed, entries[0].state);
    try std.testing.expectEqual(State.failed, entries[1].state);
}

test "reserved spills are not evictable before close and publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 2 };
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    defer queue.cleanupAll();

    var stdout = Spill.open(&queue, "stdout") orelse return error.TestUnexpectedResult;
    var stderr = Spill.open(&queue, "stderr") orelse return error.TestUnexpectedResult;
    stdout.write("a");
    stderr.write("b");

    const Reservation = struct {
        queue: *Queue,
        result: *std.atomic.Value(bool),

        fn run(context: @This()) void {
            context.result.store(context.queue.sharedBudget().allocate(1), .release);
        }
    };
    var reclaimed: std.atomic.Value(bool) = .init(true);
    var thread = try std.Thread.spawn(.{}, Reservation.run, .{Reservation{
        .queue = &queue,
        .result = &reclaimed,
    }});
    thread.join();
    try std.testing.expect(!reclaimed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());

    stdout.close();
    stderr.close();
    stdout.keep();
    stderr.keep();
    reclaimed.store(false, .release);
    thread = try std.Thread.spawn(.{}, Reservation.run, .{Reservation{
        .queue = &queue,
        .result = &reclaimed,
    }});
    thread.join();
    try std.testing.expect(reclaimed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), queue.occupied());
    queue.sharedBudget().release(1);
}

test "releasing reserved spills removes files and refunds their charges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(41);
    const budget = ScratchBudget{ .used = &used, .limit = 50 };
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    var stdout = Spill.open(&queue, "stdout") orelse return error.TestUnexpectedResult;
    var stderr = Spill.open(&queue, "stderr") orelse return error.TestUnexpectedResult;
    stdout.write("a");
    stderr.write("b");
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
    try std.testing.expectEqual(@as(u64, 43), used.load(.acquire));
    stdout.release();
    stderr.release();
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "stdout", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "stderr", .{}));
}

test "zero-byte retained files occupy entries without occupying scratch bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 2 };
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    defer queue.cleanupAll();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty-out", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty-err", .data = "" });
    try adoptForTest(&queue, "empty-out", 0);
    try adoptForTest(&queue, "empty-err", 0);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
    try std.testing.expect(budget.charge(2));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    const shared = queue.sharedBudget();
    try std.testing.expect(!shared.allocate(1));
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    shared.release(2);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "entry capacity evicts zero-byte output while byte capacity remains spare" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 10 };
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    defer queue.cleanupAll();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty-out", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty-err", .data = "" });
    try adoptForTest(&queue, "empty-out", 0);
    try adoptForTest(&queue, "empty-err", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));

    var new_out = Spill.open(&queue, "new-out") orelse return error.TestUnexpectedResult;
    var new_err = Spill.open(&queue, "new-err") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "empty-out", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "empty-err", .{}));
    new_out.release();
    new_err.release();
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "failed eviction retains its charge until the same queue retries successfully" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 4 };
    var entries: [2]Entry = @splat(.{});
    var gate: std.atomic.Value(bool) = .init(true);
    var queue = Queue.initializeWithRemoval(std.testing.io, root, budget, &entries, .{ .gated = &gate });
    defer queue.cleanupAll();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stdout", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stderr", .data = "b" });
    try std.testing.expect(budget.charge(2));
    try adoptForTest(&queue, "stdout", 1);
    try adoptForTest(&queue, "stderr", 1);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));

    try std.testing.expect(Spill.open(&queue, "new-output") == null);
    try std.testing.expectEqual(@as(u64, 2), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), queue.occupied());

    gate.store(false, .release);
    queue.cleanupAll();
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "partial retained cleanup keeps only the exact residual owner and charge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const baseline: u64 = 41;
    const blocked_charge: u64 = 3;
    const removable_charge: u64 = 5;
    var used = std.atomic.Value(u64).init(baseline);
    const budget = ScratchBudget{ .used = &used, .limit = 64 };
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    defer queue.cleanupAll();

    try tmp.dir.createDir(std.testing.io, "blocked", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "removable", .data = "value" });
    try std.testing.expect(budget.charge(blocked_charge + removable_charge));
    try adoptForTest(&queue, "blocked", blocked_charge);
    try adoptForTest(&queue, "removable", removable_charge);
    try std.testing.expectEqual(
        baseline + blocked_charge + removable_charge,
        used.load(.acquire),
    );

    queue.cleanupAll();
    try std.testing.expectEqual(@as(usize, 1), queue.occupied());
    try std.testing.expectEqual(baseline + blocked_charge, used.load(.acquire));
    try std.testing.expectEqual(State.failed, entries[0].state);
    try std.testing.expectEqualStrings("blocked", entries[0].name.slice());
    try std.testing.expectEqual(blocked_charge, entries[0].charged);
    try std.testing.expectEqual(State.free, entries[1].state);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "removable", .{}),
    );

    try tmp.dir.deleteDir(std.testing.io, "blocked");
    queue.cleanupAll();
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectEqual(baseline, used.load(.acquire));
    queue.cleanupAll();
    try std.testing.expectEqual(baseline, used.load(.acquire));
}

test "spill unknown write failure retains submitted charge through removal retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(41);
    var entries: [1]Entry = @splat(.{});
    var queue = Queue.initializeWithRemoval(std.testing.io, root, .{ .used = &used, .limit = 48 }, &entries, .injected_failure);
    const Write = struct {
        fn fail(file: std.Io.File, io: std.Io, bytes: []const u8) !usize {
            try file.writeStreamingAll(io, bytes[0..3]);
            return error.InjectedOutputWriteFailure;
        }
    };
    var spill = Spill.open(&queue, "partial") orelse return error.TestUnexpectedResult;
    spill.writeWith("partial", Write.fail);
    try std.testing.expect(!spill.alive());
    try std.testing.expectEqual(@as(u64, 48), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 7), entries[spill.token.index].charged);
    var bytes: [7]u8 = undefined;
    try std.testing.expectEqualStrings("par", try tmp.dir.readFile(std.testing.io, "partial", &bytes));
    queue.cleanupAll();
    try std.testing.expectEqual(@as(u64, 48), used.load(.acquire));
    queue.removal = .native;
    queue.cleanupAll();
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "partial", .{}));
}

test "spill reservation protects writers and failed creation preserves existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(41);
    var entries: [1]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 48 }, &entries);
    defer queue.cleanupAll();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "collision", .data = "original" });
    try std.testing.expect(Spill.open(&queue, "collision") == null);
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualStrings("original", try tmp.dir.readFile(std.testing.io, "collision", &bytes));
    var spill = Spill.open(&queue, "written") orelse return error.TestUnexpectedResult;
    spill.write("success");
    try std.testing.expectEqual(@as(u64, 48), used.load(.acquire));
    try std.testing.expect(!queue.sharedBudget().allocate(1));
    try std.testing.expectEqual(@as(usize, 1), queue.occupied());
    spill.close();
    spill.keep();
    queue.cleanupAll();
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
}

test "spill handoff waits for close and keep in either order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    var entries: [2]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 20 }, &entries);
    defer queue.cleanupAll();

    var first = Spill.open(&queue, "first") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("first", first.name());
    first.write("abc");
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), entries[first.token.index].charged);
    first.keep();
    try std.testing.expectEqual(State.reserved, entries[first.token.index].state);
    first.close();
    first.close();
    first.keep();
    first.release();
    try std.testing.expectEqual(State.retained, entries[first.token.index].state);
    try std.testing.expectEqual(@as(u64, 3), entries[first.token.index].charged);

    var second = Spill.open(&queue, "second") orelse return error.TestUnexpectedResult;
    second.write("de");
    second.close();
    try std.testing.expectEqual(State.reserved, entries[second.token.index].state);
    second.keep();
    try std.testing.expectEqual(State.retained, entries[second.token.index].state);
    var data: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", try tmp.dir.readFile(std.testing.io, "first", &data));
    queue.cleanupAll();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "spill yields its live charge for required capture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    var entries: [1]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 4 }, &entries);
    var spill = Spill.open(&queue, "output") orelse return error.TestUnexpectedResult;
    spill.write("abcd");
    try std.testing.expect(!queue.sharedBudget().allocate(4));
    try std.testing.expectEqual(@as(u64, 4), spill.yield());
    try std.testing.expect(!spill.alive());
    try std.testing.expectEqual(@as(u64, 0), spill.yield());
    try std.testing.expect(queue.sharedBudget().allocate(4));
    queue.budget.release(4);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "output", .{}));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
}

test "spill failed removal preserves charge for retry and quota failure yields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    var entries: [1]Entry = @splat(.{});
    var queue = Queue.initializeWithRemoval(std.testing.io, root, .{ .used = &used, .limit = 4 }, &entries, .injected_failure);
    var spill = Spill.open(&queue, "output") orelse return error.TestUnexpectedResult;
    spill.write("abc");
    spill.write("de");
    try std.testing.expect(!spill.alive());
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    try std.testing.expectEqual(State.failed, entries[spill.token.index].state);
    try std.testing.expectEqual(@as(u64, 3), entries[spill.token.index].charged);
    queue.cleanupAll();
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    queue.removal = .native;
    queue.cleanupAll();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
}

test "spill open and write refusals leave no unowned reservation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used = std.atomic.Value(u64).init(0);
    var entries: [1]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 0 }, &entries);
    var spill = Spill.open(&queue, "zero-budget") orelse return error.TestUnexpectedResult;
    spill.write("x");
    try std.testing.expect(!spill.alive());
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "zero-budget", .{}));

    var empty: [0]Entry = .{};
    var full = Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 0 }, &empty);
    try std.testing.expect(Spill.open(&full, "no-entry") == null);
    queue.next_sequence = std.math.maxInt(u64);
    try std.testing.expect(Spill.open(&queue, "sequence") == null);
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    queue.next_sequence = 1;

    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    try std.testing.expect(Spill.open(&queue, "directory") == null);
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    var missing_buffer: [protocol.max_store_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buffer, "{s}/absent", .{root});
    var unavailable = Queue.initialize(std.testing.io, missing, .{ .used = &used, .limit = 0 }, &entries);
    try std.testing.expect(Spill.open(&unavailable, "output") == null);
    try std.testing.expectEqual(@as(usize, 0), unavailable.occupied());
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "spill adoption transfers existing charge through publication and cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(41);
    const budget = ScratchBudget{ .used = &used, .limit = 48 };
    var entries: [1]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "capture", .data = "capture" });
    try std.testing.expect(budget.charge(7));
    var spill = Spill.adopt(&queue, "capture", 7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("capture", spill.name());
    try std.testing.expectEqual(@as(u64, 48), used.load(.acquire));
    try std.testing.expect(!queue.sharedBudget().allocate(1));
    spill.close();
    spill.keep();
    try std.testing.expectEqual(State.retained, entries[0].state);
    try std.testing.expectEqual(@as(u64, 7), entries[0].charged);
    queue.cleanupAll();
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "capture", .{}));
}

test "spill adoption failure preserves capture ownership and charge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 7 };
    var entries: [1]Entry = @splat(.{});
    var queue = Queue.initialize(std.testing.io, root, budget, &entries);
    var occupied = Spill.open(&queue, "occupied") orelse return error.TestUnexpectedResult;
    defer occupied.release();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "capture", .data = "capture" });
    try std.testing.expect(budget.charge(7));
    try std.testing.expect(Spill.adopt(&queue, "capture", 7) == null);
    try std.testing.expectEqual(@as(u64, 7), used.load(.acquire));
    var bytes: [7]u8 = undefined;
    try std.testing.expectEqualStrings("capture", try tmp.dir.readFile(std.testing.io, "capture", &bytes));
    try tmp.dir.deleteFile(std.testing.io, "capture");
    budget.release(7);
}

test "adopted spill release preserves charge until failed removal is retried" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 7 };
    var entries: [1]Entry = @splat(.{});
    var queue = Queue.initializeWithRemoval(std.testing.io, root, budget, &entries, .injected_failure);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "capture", .data = "capture" });
    try std.testing.expect(budget.charge(7));
    var spill = Spill.adopt(&queue, "capture", 7) orelse return error.TestUnexpectedResult;
    spill.release();
    try std.testing.expectEqual(State.failed, entries[0].state);
    try std.testing.expectEqual(@as(u64, 7), used.load(.acquire));
    queue.removal = .native;
    queue.cleanupAll();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "capture", .{}));
}
