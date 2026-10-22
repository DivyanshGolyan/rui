const std = @import("std");
const default_intake = @import("product_defaults.zig").intake_capacity;

pub const minimum_intake: usize = 10;

pub fn fitIntake(default_requirement: usize, soft_limit: ?usize) !usize {
    const limit = soft_limit orelse return default_intake;
    if (limit >= default_requirement) return default_intake;
    const reduction = std.math.divCeil(usize, default_requirement - limit, 4) catch unreachable;
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

pub fn calculate(
    inherited: usize,
    active_capacity: usize,
    ordinary_exchanges: usize,
    control_exchanges: usize,
    provider_configured: bool,
    authentication_configured: bool,
    os_tag: std.Target.Os.Tag,
) !Requirement {
    // StoreLease owns its directory and lock (2). SQLite DELETE mode can
    // overlap the database, rollback journal, temp store, and directory-sync
    // handle (4). The listener adds one. These are independent and remain
    // reachable while clients and executions are full.
    const store_lease: usize = 2;
    const sqlite: usize = 4;
    const listener: usize = 1;
    var fixed_host = try add(store_lease, sqlite);
    fixed_host = try add(fixed_host, listener);
    // Rui's pinned curl creates two wakeup objects for one multi handle. Linux
    // implements each with one eventfd; macOS implements each with a pipe.
    const transport_wake: usize = if (!provider_configured)
        0
    else switch (os_tag) {
        .linux => 2,
        .macos => 4,
        else => return error.UnsupportedDescriptorPlatform,
    };
    fixed_host = try add(fixed_host, transport_wake);

    // While sealing the second configure content value, an ordinary
    // connection can retain its socket, the first sealed file, and both the
    // second value's writer and read-only custody handles. Absolute POSIX
    // opens use AT_FDCWD directly and acquire no directory descriptor.
    // Controls retain only their sockets. These are simultaneous populations
    // of the supported workload, not runtime connection quotas. Demand beyond
    // them can fail allocation/open with original request recovery intact.
    const ordinary_client = try add(1, 3);
    const ordinary_clients = try multiply(ordinary_exchanges, ordinary_client);
    const clients = try add(ordinary_clients, control_exchanges);

    // A model slot owns one request file, two response aliases, and at most
    // two Happy Eyeballs transport sockets: five. A running Bash slot owns its
    // two capture files and two parent pipe ends: four. Only
    // one serial preparation/spawn/cleanup transition exists. Its budgeted
    // excess of five covers Bash spawn, which holds only the two child pipe
    // ends in the Host: posix_spawn opens the child's /dev/null itself and
    // reports exec failure directly. Model preparation (two files
    // plus a directory), cleanup (three files plus a directory), transport
    // trust loading, and self-contained native callbacks are smaller and
    // mutually exclusive with that serial excess.
    const execution = (try executionPopulation(active_capacity)).maximum;

    // The Host-wide authentication worker may refresh while the execution
    // owner spawns Bash at its descriptor peak. Its credential parent and lock
    // (2) overlap curl's private wakeups (2 eventfds on Linux, 2 pipes on
    // macOS), two connection sockets and up to two trust-loading handles.
    // Publishing the replacement instead holds at most two additional files.
    const authentication: usize = if (!authentication_configured or active_capacity == 0)
        0
    else switch (os_tag) {
        .linux => 8,
        .macos => 10,
        else => return error.UnsupportedDescriptorPlatform,
    };

    // The intake owner retains both ends of one nonblocking wake socket pair.
    // Workers and the execution fence notify without opening new connections.
    const self_wake: usize = 2;
    var total = try add(inherited, fixed_host);
    total = try add(total, clients);
    total = try add(total, execution);
    total = try add(total, authentication);
    total = try add(total, self_wake);
    return .{
        .inherited = inherited,
        .fixed_host = fixed_host,
        .clients = clients,
        .execution = execution,
        .authentication = authentication,
        .self_wake = self_wake,
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
    const model_slot = try add(1, try add(2, 2));
    const bash_slot = try add(2, 2);
    const occupied_slot = @max(model_slot, bash_slot);
    const other_slots = try multiply(active_capacity - 1, occupied_slot);
    const model_full = try multiply(active_capacity, model_slot);
    const bash_full = try multiply(active_capacity, bash_slot);
    const model_preparation = try add(other_slots, 3);
    const bash_preparation = try add(other_slots, 3);
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
    const linux = try calculate(3, 2, 10, 2, true, false, .linux);
    try std.testing.expectEqual(@as(usize, 3), linux.inherited);
    try std.testing.expectEqual(@as(usize, 9), linux.fixed_host);
    try std.testing.expectEqual(@as(usize, 42), linux.clients);
    try std.testing.expectEqual(@as(usize, 15), linux.execution);
    try std.testing.expectEqual(@as(usize, 0), linux.authentication);
    try std.testing.expectEqual(@as(usize, 2), linux.self_wake);
    try std.testing.expectEqual(@as(usize, 71), linux.total);

    const managed = try calculate(3, 2, 10, 2, true, true, .linux);
    try std.testing.expectEqual(@as(usize, 8), managed.authentication);
    try std.testing.expectEqual(@as(usize, 79), managed.total);

    const without_transport = try calculate(3, 2, 10, 2, false, false, .linux);
    try std.testing.expectEqual(@as(usize, 7), without_transport.fixed_host);
    try std.testing.expectEqual(@as(usize, 69), without_transport.total);

    const macos = try calculate(3, 2, 10, 2, true, true, .macos);
    try std.testing.expectEqual(@as(usize, 11), macos.fixed_host);
    try std.testing.expectEqual(@as(usize, 10), macos.authentication);
    try std.testing.expectEqual(@as(usize, 83), macos.total);
}

test "zero execution capacity has no unreachable preparation or spawn population" {
    const requirement = try calculate(3, 0, 10, 2, false, true, .linux);
    try std.testing.expectEqual(@as(usize, 0), requirement.execution);
    try std.testing.expectEqual(@as(usize, 0), requirement.authentication);
    try std.testing.expectEqual(@as(usize, 54), requirement.total);
}

test "execution population compares exclusive steady and shared transition overlaps" {
    const population = try executionPopulation(2);
    try std.testing.expectEqual(@as(usize, 10), population.model_full);
    try std.testing.expectEqual(@as(usize, 8), population.bash_full);
    try std.testing.expectEqual(@as(usize, 8), population.model_preparation);
    try std.testing.expectEqual(@as(usize, 8), population.bash_preparation);
    try std.testing.expectEqual(@as(usize, 9), population.cleanup);
    try std.testing.expectEqual(@as(usize, 15), population.bash_spawn);
    try std.testing.expectEqual(@as(usize, 15), population.maximum);
}

test "requirement arithmetic rejects overflow" {
    try std.testing.expectError(
        error.DescriptorRequirementOverflow,
        calculate(3, std.math.maxInt(usize), 10, 2, true, true, .linux),
    );
}

test "finite descriptor limits reject below and accept exact or above" {
    try std.testing.expectError(error.DescriptorCapacityInsufficient, validate(70, 69));
    try validate(70, 70);
    try validate(70, 71);
    try validate(70, null);
}

test "intake fits the available limit without sacrificing its minimum" {
    try std.testing.expectEqual(@as(usize, 100), try fitIntake(475, null));
    try std.testing.expectEqual(@as(usize, 100), try fitIntake(475, 475));
    try std.testing.expectEqual(@as(usize, 45), try fitIntake(475, 256));
    try std.testing.expectEqual(@as(usize, 10), try fitIntake(475, 115));
    try std.testing.expectError(error.DescriptorCapacityInsufficient, fitIntake(475, 114));
}
