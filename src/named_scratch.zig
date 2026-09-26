const std = @import("std");
const protocol = @import("protocol.zig");

/// Format private evaluator scratch and recognize exactly the names startup
/// may reclaim after a crash between creation and removal.
pub const EvaluatorName = struct {
    pub const Kind = enum { output, index };

    pub fn format(buffer: []u8, id: u64, kind: Kind) ![]const u8 {
        const suffix: []const u8 = switch (kind) {
            .output => ".tmp",
            .index => ".index",
        };
        return std.fmt.bufPrint(buffer, "evaluator-{x}{s}", .{ id, suffix });
    }

    pub fn isOwned(name: []const u8) bool {
        const prefix = "evaluator-";
        const suffix = if (std.mem.endsWith(u8, name, ".tmp"))
            ".tmp"
        else if (std.mem.endsWith(u8, name, ".index"))
            ".index"
        else
            return false;
        if (!std.mem.startsWith(u8, name, prefix)) return false;
        const value = name[prefix.len .. name.len - suffix.len];
        if (value.len == 0 or value.len > 16 or (value.len > 1 and value[0] == '0')) return false;
        for (value) |byte| {
            if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
        }
        _ = std.fmt.parseInt(u64, value, 16) catch return false;
        return true;
    }
};

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
        const result = try removeNameWith(
            self.io,
            scratch_path,
            resources.name.slice(),
            resources.removal,
        );
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

pub fn removeNameWith(
    io: std.Io,
    scratch_path: []const u8,
    name: []const u8,
    removal: Removal,
) !Reclamation {
    if (removal.blocked()) return error.InjectedScratchRemovalFailure;
    return removeName(io, scratch_path, name);
}

test "owner retains every resource after retryable removal failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const primary = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    const secondary = try tmp.dir.openFile(std.testing.io, "owned", .{});
    const baseline: u64 = 41;
    const charge: u64 = 7;
    var used: std.atomic.Value(u64) = .init(baseline + charge);
    var owner = Owner.init(
        std.testing.io,
        primary,
        secondary,
        "owned",
        .{ .used = &used, .limit = baseline + charge },
        charge,
        .native,
    );
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var missing_buffer: [protocol.max_store_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(
        &missing_buffer,
        "{s}/missing",
        .{root},
    );
    var reclaimed = false;
    errdefer if (!reclaimed) {
        _ = owner.reclaim(root) catch {};
    };

    try std.testing.expectError(error.FileNotFound, owner.reclaim(missing));
    try std.testing.expect(owner.resources != null);
    try std.testing.expect(owner.resources.?.secondary != null);
    try std.testing.expectEqualStrings("owned", owner.resources.?.name.slice());
    try std.testing.expectEqual(baseline + charge, used.load(.acquire));
    const removed = try owner.reclaim(root);
    reclaimed = true;
    try std.testing.expectEqual(Reclamation.removed, removed);
    try std.testing.expect(owner.resources == null);
    try std.testing.expectEqual(baseline, used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "owned", .{}));
}

test "an already absent name reclaims handles and accounting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const primary = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    const secondary = try tmp.dir.openFile(std.testing.io, "owned", .{});
    try tmp.dir.deleteFile(std.testing.io, "owned");
    const baseline: u64 = 41;
    const charge: u64 = 11;
    var used: std.atomic.Value(u64) = .init(baseline + charge);
    var owner = Owner.init(
        std.testing.io,
        primary,
        secondary,
        "owned",
        .{ .used = &used, .limit = baseline + charge },
        charge,
        .native,
    );
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var reclaimed = false;
    errdefer if (!reclaimed) {
        _ = owner.reclaim(root) catch {};
    };

    // Path absence alone is not completed cleanup: reclaim must still
    // close both owned aliases and release the reservation exactly once.
    const absent = try owner.reclaim(root);
    reclaimed = true;
    try std.testing.expectEqual(Reclamation.already_absent, absent);
    try std.testing.expect(owner.resources == null);
    try std.testing.expectEqual(baseline, used.load(.acquire));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "owned", .{}));
}

test "injected removal failure retains ownership until the same owner can retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const primary = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    const baseline: u64 = 41;
    const charge: u64 = 5;
    var used: std.atomic.Value(u64) = .init(baseline + charge);
    var gate: std.atomic.Value(bool) = .init(true);
    var owner = Owner.init(
        std.testing.io,
        primary,
        null,
        "owned",
        .{ .used = &used, .limit = baseline + charge },
        charge,
        .{ .gated = &gate },
    );
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var reclaimed = false;
    errdefer if (!reclaimed) {
        gate.store(false, .release);
        _ = owner.reclaim(root) catch {};
    };

    try std.testing.expectError(
        error.InjectedScratchRemovalFailure,
        owner.reclaim(root),
    );
    // The same owner retains its resources and full outstanding charge.
    try std.testing.expect(owner.resources != null);
    try std.testing.expectEqualStrings("owned", owner.resources.?.name.slice());
    try std.testing.expectEqual(baseline + charge, used.load(.acquire));
    gate.store(false, .release);
    const retried = try owner.reclaim(root);
    reclaimed = true;
    try std.testing.expectEqual(Reclamation.removed, retried);
    try std.testing.expect(owner.resources == null);
    try std.testing.expectEqual(baseline, used.load(.acquire));
}
