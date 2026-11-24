const std = @import("std");
const default_intake = @import("product_defaults.zig").intake_capacity;
const line = @import("line.zig");

pub const minimum_intake: usize = 10;
pub const ordinary_exchange_descriptors: usize = @import("protocol.zig").max_request_contents + 2;

pub fn fitIntake(default_requirement: usize, soft_limit: ?usize) !usize {
    const limit = soft_limit orelse return default_intake;
    if (limit >= default_requirement) return default_intake;
    const reduction = std.math.divCeil(usize, default_requirement - limit, ordinary_exchange_descriptors) catch unreachable;
    if (reduction > default_intake - minimum_intake) return error.DescriptorCapacityInsufficient;
    return default_intake - reduction;
}

pub const Requirement = struct {
    inherited: usize,
    fixed_host: usize,
    clients: usize,
    execution: usize,
    authentication: usize,
    self_wake: usize,
    /// Open lines are served on intake outside its exchange population.
    lines: usize,
    total: usize,
};

const ExecutionPopulation = struct {
    model_full: usize,
    bash_full: usize,
    model_preparation: usize,
    bash_preparation: usize,
    cleanup: usize,
    bash_spawn: usize,
    maximum: usize,
};

pub const Transport = union(enum) {
    none,
    requests,
    requests_and_model_list,
    listings: usize,
};

pub fn calculate(
    inherited: usize,
    active_capacity: usize,
    ordinary_exchanges: usize,
    control_exchanges: usize,
    transport: Transport,
    authentication_configured: bool,
    os_tag: std.Target.Os.Tag,
) !Requirement {
    const store_lease: usize = 2;
    const sqlite: usize = 4;
    const listener: usize = 1;
    var fixed_host = try add(store_lease, sqlite);
    fixed_host = try add(fixed_host, listener);
    const transport_wake: usize = if (transport == .none)
        0
    else switch (os_tag) {
        .linux => 1,
        .macos => 2,
        else => return error.UnsupportedDescriptorPlatform,
    };
    fixed_host = try add(fixed_host, transport_wake);
    const model_list: usize = switch (transport) {
        .none, .requests => 0,
        .requests_and_model_list => @intFromBool(active_capacity != 0),
        .listings => |lists| try add(1, lists),
    };
    fixed_host = try add(fixed_host, model_list);

    const ordinary_clients = try multiply(ordinary_exchanges, ordinary_exchange_descriptors);
    const clients = try add(ordinary_clients, control_exchanges);

    const execution = (try executionPopulation(active_capacity)).maximum;

    const authentication: usize = if (!authentication_configured or active_capacity == 0)
        0
    else switch (os_tag) {
        .linux => 6,
        .macos => 7,
        else => return error.UnsupportedDescriptorPlatform,
    };

    const self_wake: usize = 2;
    const lines: usize = line.capacity;
    var total = try add(inherited, fixed_host);
    total = try add(total, clients);
    total = try add(total, execution);
    total = try add(total, authentication);
    total = try add(total, self_wake);
    total = try add(total, lines);
    return .{
        .inherited = inherited,
        .fixed_host = fixed_host,
        .clients = clients,
        .execution = execution,
        .authentication = authentication,
        .self_wake = self_wake,
        .lines = lines,
        .total = total,
    };
}

fn executionPopulation(active_capacity: usize) !ExecutionPopulation {
    if (active_capacity == 0) return .{
        .model_full = 0,
        .bash_full = 0,
        .model_preparation = 0,
        .bash_preparation = 0,
        .cleanup = 0,
        .bash_spawn = 0,
        .maximum = 0,
    };
    const model_slot = try add(1, try add(2, 1));
    const bash_slot = try add(2, 3);
    const occupied_slot = @max(model_slot, bash_slot);
    const other_slots = try multiply(active_capacity - 1, occupied_slot);
    const model_full = try multiply(active_capacity, model_slot);
    const bash_full = try multiply(active_capacity, bash_slot);
    const model_preparation = try add(other_slots, 3);
    const bash_preparation = try add(other_slots, 6);
    const cleanup = try add(other_slots, 4);
    const bash_spawn = try add(other_slots, 10);
    return .{
        .model_full = model_full,
        .bash_full = bash_full,
        .model_preparation = model_preparation,
        .bash_preparation = bash_preparation,
        .cleanup = cleanup,
        .bash_spawn = bash_spawn,
        .maximum = @max(
            @max(model_full, bash_full),
            @max(@max(model_preparation, bash_preparation), @max(cleanup, bash_spawn)),
        ),
    };
}

pub fn validate(requirement: usize, soft_limit: ?usize) !void {
    if (soft_limit) |limit| {
        if (requirement > limit) return error.DescriptorCapacityInsufficient;
    }
}

fn add(left: usize, right: usize) !usize {
    return std.math.add(usize, left, right) catch error.DescriptorRequirementOverflow;
}

fn multiply(left: usize, right: usize) !usize {
    return std.math.mul(usize, left, right) catch error.DescriptorRequirementOverflow;
}

test "requirement uses simultaneous owner populations rather than summing exclusive maxima" {
    const linux = try calculate(3, 2, 10, 2, .requests, false, .linux);
    try std.testing.expectEqual(@as(usize, 3), linux.inherited);
    try std.testing.expectEqual(@as(usize, 8), linux.fixed_host);
    try std.testing.expectEqual(@as(usize, 62), linux.clients);
    try std.testing.expectEqual(@as(usize, 15), linux.execution);
    try std.testing.expectEqual(@as(usize, 0), linux.authentication);
    try std.testing.expectEqual(@as(usize, 2), linux.self_wake);
    try std.testing.expectEqual(@as(usize, 16), linux.lines);
    try std.testing.expectEqual(@as(usize, 106), linux.total);

    const managed = try calculate(3, 2, 10, 2, .requests, true, .linux);
    try std.testing.expectEqual(@as(usize, 6), managed.authentication);
    try std.testing.expectEqual(@as(usize, 112), managed.total);

    const listing = try calculate(3, 2, 10, 2, .requests_and_model_list, false, .linux);
    try std.testing.expectEqual(@as(usize, 9), listing.fixed_host);
    try std.testing.expectEqual(@as(usize, 107), listing.total);

    const without_transport = try calculate(3, 2, 10, 2, .none, false, .linux);
    try std.testing.expectEqual(@as(usize, 7), without_transport.fixed_host);
    try std.testing.expectEqual(@as(usize, 105), without_transport.total);

    const macos = try calculate(3, 2, 10, 2, .requests, true, .macos);
    try std.testing.expectEqual(@as(usize, 9), macos.fixed_host);
    try std.testing.expectEqual(@as(usize, 7), macos.authentication);
    try std.testing.expectEqual(@as(usize, 114), macos.total);
}

test "zero execution capacity has no unreachable preparation or spawn population" {
    const requirement = try calculate(3, 0, 10, 2, .none, true, .linux);
    try std.testing.expectEqual(@as(usize, 0), requirement.execution);
    try std.testing.expectEqual(@as(usize, 0), requirement.authentication);
    try std.testing.expectEqual(@as(usize, 90), requirement.total);
    const listing = try calculate(3, 0, 10, 2, .requests_and_model_list, true, .linux);
    try std.testing.expectEqual((try calculate(3, 0, 10, 2, .requests, true, .linux)).fixed_host, listing.fixed_host);
}

test "execution population compares exclusive steady and shared transition overlaps" {
    const population = try executionPopulation(2);
    try std.testing.expectEqual(@as(usize, 8), population.model_full);
    try std.testing.expectEqual(@as(usize, 10), population.bash_full);
    try std.testing.expectEqual(@as(usize, 8), population.model_preparation);
    try std.testing.expectEqual(@as(usize, 11), population.bash_preparation);
    try std.testing.expectEqual(@as(usize, 9), population.cleanup);
    try std.testing.expectEqual(@as(usize, 15), population.bash_spawn);
    try std.testing.expectEqual(@as(usize, 15), population.maximum);
}

test "requirement arithmetic rejects overflow" {
    try std.testing.expectError(
        error.DescriptorRequirementOverflow,
        calculate(3, std.math.maxInt(usize), 10, 2, .requests, true, .linux),
    );
}

test "finite descriptor limits reject below and accept exact or above" {
    try std.testing.expectError(error.DescriptorCapacityInsufficient, validate(70, 69));
    try validate(70, 70);
    try validate(70, 71);
    try validate(70, null);
}

test "intake fits the available limit without sacrificing its minimum" {
    try std.testing.expectEqual(@as(usize, 100), try fitIntake(575, null));
    try std.testing.expectEqual(@as(usize, 100), try fitIntake(575, 575));
    try std.testing.expectEqual(@as(usize, 46), try fitIntake(575, 256));
    try std.testing.expectEqual(@as(usize, 10), try fitIntake(575, 35));
    try std.testing.expectError(error.DescriptorCapacityInsufficient, fitIntake(575, 34));
}

test "catalog discovery reserves its sockets beyond model capacity including zero" {
    for ([_]usize{ 0, 1, 100 }) |capacity| {
        for ([_]std.Target.Os.Tag{ .linux, .macos }) |os_tag| {
            const requests = try calculate(3, capacity, 10, 2, .requests, false, os_tag);
            const catalog = try calculate(3, capacity, 10, 2, .{ .listings = 0 }, false, os_tag);
            try std.testing.expectEqual(requests.fixed_host + 1, catalog.fixed_host);
            for ([_]usize{ 1, 2 }) |lists| {
                const listings = try calculate(3, capacity, 10, 2, .{ .listings = lists }, false, os_tag);
                try std.testing.expectEqual(requests.fixed_host + 1 + lists, listings.fixed_host);
                try std.testing.expectEqual(requests.execution, listings.execution);
            }
        }
    }
}

test "default managed Host budgets all creating-Message contents at a typical Linux limit" {
    const requirement = try calculate(3, 100, 100, 3, .{ .listings = 0 }, true, .linux);
    try std.testing.expectEqual(@as(usize, 1144), requirement.total);
    try std.testing.expectEqual(@as(usize, 80), try fitIntake(requirement.total, 1024));
}
