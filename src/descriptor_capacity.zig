const std = @import("std");

pub const Requirement = struct {
    inherited: usize,
    fixed_host: usize,
    clients: usize,
    execution: usize,
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
    ordinary_client_capacity: usize,
    control_client_capacity: usize,
    provider_configured: bool,
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
    // Control places retain only their sockets. The server supplies both
    // capacities.
    const ordinary_client = try add(1, 3);
    const ordinary_clients = try multiply(ordinary_client_capacity, ordinary_client);
    const clients = try add(ordinary_clients, control_client_capacity);

    // A model slot owns one request file, two response aliases, and at most
    // two Happy Eyeballs transport sockets. A running Bash slot owns its
    // script/two capture files and two parent pipe ends: both are five. Only
    // one serial preparation/spawn/cleanup transition exists. Its largest
    // excess is Bash spawn: two child pipe ends, the two-end exec-error pipe,
    // and Threaded.Io's lazily opened /dev/null. Model preparation (two files
    // plus a directory), cleanup (three files plus a directory), transport
    // trust loading, and self-contained native callbacks are smaller and
    // mutually exclusive with that serial excess.
    const execution = (try executionPopulation(active_capacity)).maximum;

    // A dispatch fence connects to its own still-open listener. This must be
    // possible while all admitted client places remain occupied.
    const self_wake: usize = 1;
    var total = try add(inherited, fixed_host);
    total = try add(total, clients);
    total = try add(total, execution);
    total = try add(total, self_wake);
    return .{
        .inherited = inherited,
        .fixed_host = fixed_host,
        .clients = clients,
        .execution = execution,
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
    const bash_slot = try add(3, 2);
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
    const linux = try calculate(3, 2, 10, 2, true, .linux);
    try std.testing.expectEqual(@as(usize, 3), linux.inherited);
    try std.testing.expectEqual(@as(usize, 9), linux.fixed_host);
    try std.testing.expectEqual(@as(usize, 42), linux.clients);
    try std.testing.expectEqual(@as(usize, 15), linux.execution);
    try std.testing.expectEqual(@as(usize, 1), linux.self_wake);
    try std.testing.expectEqual(@as(usize, 70), linux.total);

    const without_transport = try calculate(3, 2, 10, 2, false, .linux);
    try std.testing.expectEqual(@as(usize, 7), without_transport.fixed_host);
    try std.testing.expectEqual(@as(usize, 68), without_transport.total);

    const macos = try calculate(3, 2, 10, 2, true, .macos);
    try std.testing.expectEqual(@as(usize, 11), macos.fixed_host);
    try std.testing.expectEqual(@as(usize, 72), macos.total);
}

test "zero execution capacity has no unreachable preparation or spawn population" {
    const requirement = try calculate(3, 0, 10, 2, false, .linux);
    try std.testing.expectEqual(@as(usize, 0), requirement.execution);
    try std.testing.expectEqual(@as(usize, 53), requirement.total);
}

test "execution population compares exclusive steady and shared transition overlaps" {
    const population = try executionPopulation(2);
    try std.testing.expectEqual(@as(usize, 10), population.model_full);
    try std.testing.expectEqual(@as(usize, 10), population.bash_full);
    try std.testing.expectEqual(@as(usize, 8), population.model_preparation);
    try std.testing.expectEqual(@as(usize, 8), population.bash_preparation);
    try std.testing.expectEqual(@as(usize, 9), population.cleanup);
    try std.testing.expectEqual(@as(usize, 15), population.bash_spawn);
    try std.testing.expectEqual(@as(usize, 15), population.maximum);
}

test "requirement arithmetic rejects overflow" {
    try std.testing.expectError(
        error.DescriptorRequirementOverflow,
        calculate(3, std.math.maxInt(usize), 10, 2, true, .linux),
    );
}

test "finite descriptor limits reject below and accept exact or above" {
    try std.testing.expectError(error.DescriptorCapacityInsufficient, validate(70, 69));
    try validate(70, 70);
    try validate(70, 71);
    try validate(70, null);
}
