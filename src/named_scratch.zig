const std = @import("std");
const protocol = @import("protocol.zig");

pub const Reclamation = enum { removed, already_absent };
pub const Removal = union(enum) {
    native,
    injected_failure,
    gated: *const std.atomic.Value(bool),

    fn blocked(self: Removal) bool {
        return switch (self) {
            .native => false,
            .injected_failure => true,
            .gated => |gate| gate.load(.acquire),
        };
    }
};

pub const Owner = struct {
    io: std.Io,
    resources: ?Resources,
    budget: protocol.ScratchBudget,

    const Resources = struct {
        primary: std.Io.File,
        secondary: ?std.Io.File,
        name: protocol.Bounded(96),
        charged: u64,
        removal: Removal,
    };

    pub fn init(
        io: std.Io,
        primary: std.Io.File,
        secondary: ?std.Io.File,
        name: []const u8,
        budget: protocol.ScratchBudget,
        charged: u64,
        removal: Removal,
    ) Owner {
        var resources = Resources{
            .primary = primary,
            .secondary = secondary,
            .name = .{},
            .charged = charged,
            .removal = removal,
        };
        resources.name.set(name) catch unreachable;
        return .{ .io = io, .resources = resources, .budget = budget };
    }

    pub fn reclaim(self: *Owner, scratch_path: []const u8) !Reclamation {
        const resources = &(self.resources orelse unreachable);
        if (resources.removal.blocked()) return error.InjectedScratchRemovalFailure;
        const result = try removeName(self.io, scratch_path, resources.name.slice());
        resources.primary.close(self.io);
        if (resources.secondary) |secondary| secondary.close(self.io);
        self.budget.release(resources.charged);
        self.resources = null;
        return result;
    }
};

pub fn removeName(io: std.Io, scratch_path: []const u8, name: []const u8) !Reclamation {
    var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
    defer scratch.close(io);
    scratch.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => return .already_absent,
        else => return err,
    };
    return .removed;
}

test "owner retains every resource after retryable removal failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const primary = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    const secondary = try tmp.dir.openFile(std.testing.io, "owned", .{});
    var used: std.atomic.Value(u64) = .init(7);
    var owner = Owner.init(
        std.testing.io,
        primary,
        secondary,
        "owned",
        .{ .used = &used, .limit = 7 },
        7,
        .native,
    );
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var missing_buffer: [protocol.max_store_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(
        &missing_buffer,
        "{s}/missing",
        .{root_buffer[0..root_length]},
    );

    try std.testing.expectError(error.FileNotFound, owner.reclaim(missing));
    try std.testing.expectEqual(@as(u64, 7), used.load(.acquire));
    try std.testing.expectEqual(Reclamation.removed, try owner.reclaim(root_buffer[0..root_length]));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "owned", .{}));
}

test "an already absent name reclaims handles and accounting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const primary = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    const secondary = try tmp.dir.openFile(std.testing.io, "owned", .{});
    try tmp.dir.deleteFile(std.testing.io, "owned");
    var used: std.atomic.Value(u64) = .init(11);
    var owner = Owner.init(
        std.testing.io,
        primary,
        secondary,
        "owned",
        .{ .used = &used, .limit = 11 },
        11,
        .native,
    );
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);

    try std.testing.expectEqual(
        Reclamation.already_absent,
        try owner.reclaim(root_buffer[0..root_length]),
    );
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "injected removal failure retains ownership until the same owner can retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const primary = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    var used: std.atomic.Value(u64) = .init(5);
    var gate: std.atomic.Value(bool) = .init(true);
    var owner = Owner.init(
        std.testing.io,
        primary,
        null,
        "owned",
        .{ .used = &used, .limit = 5 },
        5,
        .{ .gated = &gate },
    );
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);

    try std.testing.expectError(
        error.InjectedScratchRemovalFailure,
        owner.reclaim(root_buffer[0..root_length]),
    );
    try std.testing.expectEqual(@as(u64, 5), used.load(.acquire));
    gate.store(false, .release);
    try std.testing.expectEqual(Reclamation.removed, try owner.reclaim(root_buffer[0..root_length]));
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}
