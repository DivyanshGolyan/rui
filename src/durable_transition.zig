const std = @import("std");
const harness = @import("harness.zig");
const operation_log = @import("operation_log.zig");

pub const SlotState = enum {
    submitted,
    accepted,
    completed,
};

pub const Slot = struct {
    context: *anyopaque,
    inspect: *const fn (*anyopaque, harness.Completion) anyerror!SlotState,
    apply: *const fn (*anyopaque, harness.Completion) anyerror!void,
};

pub const FaultHook = struct {
    context: *anyopaque,
    after_persist: *const fn (*anyopaque) anyerror!void,
};

/// Connects the fixed-credit owner to one durable operation journal and one
/// restored execution slot. The adapter keeps no per-agent index.
pub const Adapter = struct {
    io: std.Io,
    dir: std.Io.Dir,
    journal_path: []const u8,
    writer: *operation_log.Writer,
    ownership_epoch: u64,
    slot: Slot,
    fault: ?FaultHook = null,

    pub fn transition(self: *Adapter) harness.Transition {
        return .{
            .context = self,
            .classify = classify,
            .persist = persist,
            .apply = apply,
        };
    }

    fn completionFrom(input: harness.Input) !harness.Completion {
        return switch (input) {
            .completion => |completion| completion,
            else => error.UnsupportedInput,
        };
    }

    fn classify(context: *anyopaque, input: harness.Input) anyerror!harness.InputState {
        const self: *Adapter = @ptrCast(@alignCast(context));
        const completion = try completionFrom(input);
        if (completion.ownership_epoch > self.ownership_epoch) return .stale;

        var reader = try operation_log.Reader.openIn(self.dir, self.io, self.journal_path);
        defer reader.close(self.io);
        var accepted = false;
        var durable_result: ?u64 = null;
        while (try reader.next(self.io)) |record| {
            if (record.agent_id != completion.agent_id or
                record.agent_generation != completion.agent_generation or
                record.operation_id != completion.operation_id or
                record.operation_generation != completion.operation_generation or
                record.ownership_epoch != completion.ownership_epoch)
            {
                continue;
            }
            switch (record.kind) {
                .accepted => {
                    if (accepted or durable_result != null) return error.InvalidOperationHistory;
                    accepted = true;
                },
                .completed => {
                    if (!accepted or durable_result != null) return error.InvalidOperationHistory;
                    durable_result = record.result;
                },
            }
        }
        if (!accepted) return .stale;

        const slot_state = try self.slot.inspect(self.slot.context, completion);
        if (durable_result) |result| {
            if (result != completion.result) return error.CompletionResultMismatch;
            return if (slot_state == .completed) .duplicate else .durable;
        }
        if (slot_state == .completed) return error.SlotAheadOfJournal;
        return .applicable;
    }

    fn persist(context: *anyopaque, input: harness.Input) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        const completion = try completionFrom(input);
        try self.writer.appendDurable(self.io, .{
            .kind = .completed,
            .agent_id = completion.agent_id,
            .agent_generation = completion.agent_generation,
            .operation_id = completion.operation_id,
            .operation_generation = completion.operation_generation,
            .ownership_epoch = completion.ownership_epoch,
            .sequence = self.writer.last_sequence + 1,
            .result = completion.result,
        });
        if (self.fault) |fault| try fault.after_persist(fault.context);
    }

    fn apply(context: *anyopaque, input: harness.Input) anyerror!void {
        const self: *Adapter = @ptrCast(@alignCast(context));
        const completion = try completionFrom(input);
        try self.slot.apply(self.slot.context, completion);
    }
};

comptime {
    std.debug.assert(@sizeOf(Adapter) <= 192);
}

const FakeSlot = struct {
    state: SlotState,
    apply_count: u8 = 0,

    fn inspect(context: *anyopaque, _: harness.Completion) anyerror!SlotState {
        const self: *FakeSlot = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn apply(context: *anyopaque, _: harness.Completion) anyerror!void {
        const self: *FakeSlot = @ptrCast(@alignCast(context));
        self.state = .completed;
        self.apply_count += 1;
    }

    fn interface(self: *FakeSlot) Slot {
        return .{ .context = self, .inspect = inspect, .apply = apply };
    }
};

const test_completion: harness.Completion = .{
    .agent_id = 7,
    .agent_generation = 3,
    .operation_id = 19,
    .operation_generation = 2,
    .ownership_epoch = 5,
    .result = 101,
};

fn appendAccepted(writer: *operation_log.Writer, io: std.Io) !void {
    try writer.appendDurable(io, .{
        .kind = .accepted,
        .agent_id = test_completion.agent_id,
        .agent_generation = test_completion.agent_generation,
        .operation_id = test_completion.operation_id,
        .operation_generation = test_completion.operation_generation,
        .ownership_epoch = test_completion.ownership_epoch,
        .sequence = writer.last_sequence + 1,
        .result = 0,
    });
}

fn openHarness(adapter: *Adapter) !harness.Harness {
    return harness.Harness.open(.{
        .input_capacity = 1,
        .drive_quantum = 1,
        .transition = adapter.transition(),
    });
}

test "the adapter persists a real completion record before slot application" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try operation_log.Writer.createIn(tmp.dir, io, "journal");
    defer writer.close(io);
    try appendAccepted(&writer, io);
    var slot: FakeSlot = .{ .state = .accepted };
    var adapter: Adapter = .{
        .io = io,
        .dir = tmp.dir,
        .journal_path = "journal",
        .writer = &writer,
        .ownership_epoch = test_completion.ownership_epoch,
        .slot = slot.interface(),
    };
    var owner = try openHarness(&adapter);
    try std.testing.expectEqual(harness.OfferResult.queued, owner.offer(.{ .completion = test_completion }));
    const progress = try owner.drive();
    try std.testing.expectEqual(@as(u8, 1), progress.applied);
    try std.testing.expectEqual(@as(u8, 1), slot.apply_count);
    try std.testing.expectEqual(@as(u64, operation_log.record_size * 2), writer.offset);
}

test "reconstruction applies a durable completion once without a second append" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var initial = try operation_log.Writer.createIn(tmp.dir, io, "journal");
        defer initial.close(io);
        try appendAccepted(&initial, io);
        try initial.appendDurable(io, .{
            .kind = .completed,
            .agent_id = test_completion.agent_id,
            .agent_generation = test_completion.agent_generation,
            .operation_id = test_completion.operation_id,
            .operation_generation = test_completion.operation_generation,
            .ownership_epoch = test_completion.ownership_epoch,
            .sequence = initial.last_sequence + 1,
            .result = test_completion.result,
        });
    }
    var writer = try operation_log.Writer.openAppendIn(tmp.dir, io, "journal");
    defer writer.close(io);
    var slot: FakeSlot = .{ .state = .accepted };
    var adapter: Adapter = .{
        .io = io,
        .dir = tmp.dir,
        .journal_path = "journal",
        .writer = &writer,
        .ownership_epoch = test_completion.ownership_epoch,
        .slot = slot.interface(),
    };
    var owner = try openHarness(&adapter);
    try std.testing.expectEqual(harness.OfferResult.queued, owner.offer(.{ .completion = test_completion }));
    const recovered = try owner.drive();
    try std.testing.expectEqual(@as(u8, 1), recovered.applied);
    try std.testing.expectEqual(@as(u64, operation_log.record_size * 2), writer.offset);

    try std.testing.expectEqual(harness.OfferResult.queued, owner.offer(.{ .completion = test_completion }));
    const replayed = try owner.drive();
    try std.testing.expectEqual(@as(u8, 1), replayed.duplicate);
    try std.testing.expectEqual(@as(u8, 1), slot.apply_count);
}

test "an unreadable journal fail-stops the owner" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try operation_log.Writer.createIn(tmp.dir, io, "journal");
    defer writer.close(io);
    try appendAccepted(&writer, io);
    try writer.file.writePositionalAll(io, "broken", writer.offset);
    var slot: FakeSlot = .{ .state = .accepted };
    var adapter: Adapter = .{
        .io = io,
        .dir = tmp.dir,
        .journal_path = "journal",
        .writer = &writer,
        .ownership_epoch = test_completion.ownership_epoch,
        .slot = slot.interface(),
    };
    var owner = try openHarness(&adapter);
    try std.testing.expectEqual(harness.OfferResult.queued, owner.offer(.{ .completion = test_completion }));
    try std.testing.expectError(error.TruncatedRecord, owner.drive());
    try std.testing.expectEqual(harness.OfferResult.unavailable, owner.offer(.{ .completion = test_completion }));
}

test "a resumed owner reconciles a late completion from an accepted prior epoch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try operation_log.Writer.createIn(tmp.dir, io, "journal");
    defer writer.close(io);
    try appendAccepted(&writer, io);
    const offset_before = writer.offset;
    var slot: FakeSlot = .{ .state = .accepted };
    var adapter: Adapter = .{
        .io = io,
        .dir = tmp.dir,
        .journal_path = "journal",
        .writer = &writer,
        .ownership_epoch = test_completion.ownership_epoch + 1,
        .slot = slot.interface(),
    };
    var owner = try openHarness(&adapter);
    try std.testing.expectEqual(
        harness.OfferResult.queued,
        owner.offer(.{ .completion = test_completion }),
    );

    const progress = try owner.drive();

    try std.testing.expectEqual(@as(u8, 1), progress.committed);
    try std.testing.expectEqual(@as(u8, 1), progress.applied);
    try std.testing.expectEqual(offset_before + operation_log.record_size, writer.offset);
    try std.testing.expectEqual(@as(u8, 1), slot.apply_count);
}

test "a completion from a future ownership epoch cannot journal or apply" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try operation_log.Writer.createIn(tmp.dir, io, "journal");
    defer writer.close(io);
    try appendAccepted(&writer, io);
    const offset_before = writer.offset;
    var slot: FakeSlot = .{ .state = .accepted };
    var adapter: Adapter = .{
        .io = io,
        .dir = tmp.dir,
        .journal_path = "journal",
        .writer = &writer,
        .ownership_epoch = test_completion.ownership_epoch - 1,
        .slot = slot.interface(),
    };
    var owner = try openHarness(&adapter);
    try std.testing.expectEqual(
        harness.OfferResult.queued,
        owner.offer(.{ .completion = test_completion }),
    );

    const progress = try owner.drive();

    try std.testing.expectEqual(@as(u8, 1), progress.stale);
    try std.testing.expectEqual(offset_before, writer.offset);
    try std.testing.expectEqual(@as(u8, 0), slot.apply_count);
}
