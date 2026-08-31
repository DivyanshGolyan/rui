const std = @import("std");

pub const slot_ceiling = 32 * 1024;
pub const slot_alignment = 8;
// The private continuation reducer currently needs 184 bytes of aligned
// working storage. Its durable encoding is defined and owned by Session.
pub const slot_size = 184;

/// Host-owned opaque working storage for one Activation. None of its layout is durable.
pub const ActivationSlot = extern struct {
    storage: [slot_size]u8 align(slot_alignment),
};

comptime {
    std.debug.assert(@sizeOf(ActivationSlot) == slot_size);
    std.debug.assert(@alignOf(ActivationSlot) == slot_alignment);
    std.debug.assert(slot_size <= slot_ceiling);
}

pub const SlotLease = struct {
    slot: *ActivationSlot,
    context: *anyopaque,
    index: usize,
    generation: u64,
    release_fn: *const fn (*anyopaque, usize, u64, *ActivationSlot) error{StaleSlotLease}!void,
    borrowed: bool = true,

    pub fn release(self: *SlotLease) error{StaleSlotLease}!void {
        if (!self.borrowed) return;
        try self.release_fn(self.context, self.index, self.generation, self.slot);
        self.borrowed = false;
    }
};

/// Runtime-sized production Slot storage. One Host owns one fixed allocation
/// for its complete lifetime; Session population never changes its capacity.
pub const RuntimeSlotPool = struct {
    const state_mask: u64 = 0b11;
    const state_free: u64 = 0;
    const state_occupied: u64 = 1;
    const state_releasing: u64 = 2;
    const generation_step: u64 = 4;

    const Cell = struct {
        slot: ActivationSlot = undefined,
        /// Low two bits: free=0, occupied=1, releasing=2. Higher bits form a
        /// monotonically increasing generation that fences stale lease copies.
        state: std.atomic.Value(u64) = .init(0),
    };

    cells: []Cell,
    occupied_count: std.atomic.Value(usize) = .init(0),
    occupied_high_water: std.atomic.Value(usize) = .init(0),

    pub fn init(allocator: std.mem.Allocator, slot_capacity: usize) !RuntimeSlotPool {
        if (slot_capacity == 0) return error.InvalidActivationCapacity;
        const cells = try allocator.alloc(Cell, slot_capacity);
        for (cells) |*cell| cell.* = .{};
        return .{ .cells = cells };
    }

    pub fn deinit(self: *RuntimeSlotPool, allocator: std.mem.Allocator) void {
        std.debug.assert(self.occupied_count.load(.acquire) == 0);
        for (self.cells) |*cell| {
            std.debug.assert(cell.state.load(.acquire) & state_mask == state_free);
            scrub(&cell.slot);
        }
        allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn borrow(self: *RuntimeSlotPool) !SlotLease {
        for (self.cells, 0..) |*cell, index| {
            var state = cell.state.load(.acquire);
            while (state & state_mask == state_free) {
                if (state > std.math.maxInt(u64) - generation_step) break;
                const occupied_state = state + state_occupied;
                if (cell.state.cmpxchgWeak(state, occupied_state, .acq_rel, .acquire)) |actual| {
                    state = actual;
                    continue;
                }
                scrub(&cell.slot);
                const occupied = self.occupied_count.fetchAdd(1, .acq_rel) + 1;
                self.raiseHighWater(occupied);
                return .{
                    .slot = &cell.slot,
                    .context = self,
                    .index = index,
                    .generation = occupied_state,
                    .release_fn = releaseLease,
                };
            }
        }
        return error.ActivationCapacityExhausted;
    }

    pub fn capacity(self: *const RuntimeSlotPool) usize {
        return self.cells.len;
    }

    pub fn residentBytes(self: *const RuntimeSlotPool) usize {
        return self.cells.len * @sizeOf(ActivationSlot);
    }

    pub fn occupiedBytes(self: *const RuntimeSlotPool) usize {
        return self.occupied_count.load(.acquire) * @sizeOf(ActivationSlot);
    }

    pub fn occupiedHighWaterBytes(self: *const RuntimeSlotPool) usize {
        return self.occupied_high_water.load(.acquire) * @sizeOf(ActivationSlot);
    }

    pub fn hostOverheadBytes(self: *const RuntimeSlotPool) usize {
        return @sizeOf(RuntimeSlotPool) + self.cells.len * (@sizeOf(Cell) - @sizeOf(ActivationSlot));
    }

    fn raiseHighWater(self: *RuntimeSlotPool, occupied: usize) void {
        var high_water = self.occupied_high_water.load(.acquire);
        while (occupied > high_water) {
            high_water = self.occupied_high_water.cmpxchgWeak(
                high_water,
                occupied,
                .acq_rel,
                .acquire,
            ) orelse return;
        }
    }

    fn releaseLease(
        context: *anyopaque,
        index: usize,
        generation: u64,
        slot: *ActivationSlot,
    ) error{StaleSlotLease}!void {
        const self: *RuntimeSlotPool = @ptrCast(@alignCast(context));
        if (index >= self.cells.len) return error.StaleSlotLease;
        const cell = &self.cells[index];
        if (slot != &cell.slot or generation & state_mask != state_occupied or
            cell.state.cmpxchgStrong(
                generation,
                generation + state_releasing - state_occupied,
                .acq_rel,
                .acquire,
            ) != null)
        {
            return error.StaleSlotLease;
        }
        scrub(slot);
        const previous = self.occupied_count.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        cell.state.store(generation + generation_step - state_occupied, .release);
    }
};

pub fn scrub(slot: *ActivationSlot) void {
    @memset(std.mem.asBytes(slot), 0);
}

comptime {
    std.debug.assert(@sizeOf(ActivationSlot) == slot_size);
    std.debug.assert(@alignOf(ActivationSlot) == slot_alignment);
    assertNoAllocatorParameter(RuntimeSlotPool.borrow);
}

fn assertNoAllocatorParameter(comptime callable: anytype) void {
    const function_info = @typeInfo(@TypeOf(callable)).@"fn";
    for (function_info.params) |parameter| {
        if (parameter.type != null and containsAllocator(parameter.type.?)) {
            @compileError("Core slot lifecycle cannot expose an allocator seam");
        }
    }
}

fn containsAllocator(comptime T: type) bool {
    if (T == std.mem.Allocator) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| containsAllocator(pointer.child),
        .optional => |optional| containsAllocator(optional.child),
        .array => |array| containsAllocator(array.child),
        .vector => |vector| containsAllocator(vector.child),
        .error_union => |error_union| containsAllocator(error_union.payload),
        .@"struct", .@"union" => blk: {
            for (std.meta.fields(T)) |field| {
                if (containsAllocator(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"fn" => |function| blk: {
            for (function.params) |parameter| {
                if (parameter.type != null and containsAllocator(parameter.type.?)) break :blk true;
            }
            if (function.return_type) |return_type| {
                if (containsAllocator(return_type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

test "scrub clears every Activation Slot byte" {
    var slot: ActivationSlot = undefined;
    @memset(std.mem.asBytes(&slot), 0xa5);
    scrub(&slot);
    for (std.mem.asBytes(&slot)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "runtime slot pool returns closed capacity and scrubs before reuse" {
    var pool = try RuntimeSlotPool.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var lease = try pool.borrow();
    @memset(std.mem.asBytes(lease.slot), 0xa5);
    try std.testing.expectError(error.ActivationCapacityExhausted, pool.borrow());
    try lease.release();

    var reused = try pool.borrow();
    defer reused.release() catch unreachable;
    for (std.mem.asBytes(reused.slot)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(slot_size, pool.residentBytes());
}

test "the filler-free Activation Slot reserves one opaque continuation image" {
    try std.testing.expect(@sizeOf(ActivationSlot) <= slot_ceiling);
}

test "stale copied lease cannot release a newly borrowed slot" {
    var pool = try RuntimeSlotPool.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var original = try pool.borrow();
    var stale_copy = original;
    try original.release();

    var current = try pool.borrow();
    defer current.release() catch unreachable;
    current.slot.storage[0] = 99;
    try std.testing.expectError(error.StaleSlotLease, stale_copy.release());

    try std.testing.expectEqual(@as(u8, 99), current.slot.storage[0]);
    try std.testing.expectError(error.ActivationCapacityExhausted, pool.borrow());
}

test "runtime Slot pool admits exactly its capacity under concurrent borrowing" {
    const Worker = struct {
        fn run(
            pool: *RuntimeSlotPool,
            active_mask: *std.atomic.Value(u64),
            ready: *std.atomic.Value(usize),
            release: *const std.atomic.Value(bool),
            failed: *std.atomic.Value(bool),
        ) void {
            var lease = pool.borrow() catch {
                failed.store(true, .release);
                return;
            };
            const bit = @as(u64, 1) << @intCast(lease.index);
            if (active_mask.fetchOr(bit, .acq_rel) & bit != 0) failed.store(true, .release);
            _ = ready.fetchAdd(1, .acq_rel);
            while (!release.load(.acquire)) std.atomic.spinLoopHint();
            _ = active_mask.fetchAnd(~bit, .acq_rel);
            lease.release() catch failed.store(true, .release);
        }
    };

    var pool = try RuntimeSlotPool.init(std.testing.allocator, 4);
    defer pool.deinit(std.testing.allocator);
    var active_mask: std.atomic.Value(u64) = .init(0);
    var ready: std.atomic.Value(usize) = .init(0);
    var release: std.atomic.Value(bool) = .init(false);
    var failed: std.atomic.Value(bool) = .init(false);
    var workers: [4]std.Thread = undefined;
    for (&workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, Worker.run, .{
            &pool,
            &active_mask,
            &ready,
            &release,
            &failed,
        });
    }
    while (ready.load(.acquire) != workers.len and !failed.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    const all_workers_borrowed = !failed.load(.acquire) and ready.load(.acquire) == workers.len;
    const unique_slots = active_mask.load(.acquire) == 0b1111;
    const full_is_closed = if (pool.borrow()) |unexpected| block: {
        var lease = unexpected;
        lease.release() catch failed.store(true, .release);
        break :block false;
    } else |err| err == error.ActivationCapacityExhausted;
    const high_water_is_exact = pool.occupiedHighWaterBytes() == 4 * @sizeOf(ActivationSlot);
    release.store(true, .release);
    for (workers) |worker| worker.join();
    try std.testing.expect(all_workers_borrowed);
    try std.testing.expect(unique_slots);
    try std.testing.expect(full_is_closed);
    try std.testing.expect(high_water_is_exact);
}
