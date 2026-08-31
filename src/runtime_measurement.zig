const std = @import("std");
const builtin = @import("builtin");
const core_image = @import("core_image.zig");
const deterministic_provider = @import("deterministic_provider.zig");
const harness = @import("harness.zig");
const process_metrics = @import("process_metrics.zig");

const schema_version = 1;
const fixture_task = "Measure one durable agent lifecycle.";
const fixture_answer = "Measurement complete.";

const Scenario = enum {
    dormant,
    completion,
};

const Observation = struct {
    baseline: process_metrics.Sample,
    runtime_open: process_metrics.Sample,
    workload_complete: process_metrics.Sample,
    runtime_closed: process_metrics.Sample,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.InvalidArguments;
    const scenario = std.meta.stringToEnum(Scenario, args[1]) orelse return error.InvalidScenario;
    const count = try std.fmt.parseInt(usize, args[2], 10);
    const active_capacity = try std.fmt.parseInt(usize, args[3], 10);
    if (count > 100_000) return error.MeasurementCountTooLarge;

    var layout = try Layout.init(init.io, allocator);
    defer layout.deinit(init.io);
    const baseline = try process_metrics.sample();
    try layout.openRuntime(init.io, active_capacity);
    const runtime_open = try process_metrics.sample();
    const wall_start = try monotonicNanoseconds();
    const cpu_start = try processCpuNanoseconds();

    switch (scenario) {
        .dormant => try createDormantSessions(&layout, count),
        .completion => try completeSessions(&layout, count),
    }

    const wall_end = try monotonicNanoseconds();
    const cpu_end = try processCpuNanoseconds();
    const workload_complete = try process_metrics.sample();
    const durable_bytes = try layout.durableBytes(init.io);
    const runtime = layout.runtime.?;
    const activation: ActivationObservation = .{
        .active_capacity = runtime.activeCapacity(),
        .slot_bytes = @sizeOf(core_image.ActivationSlot),
        .reserved_bytes = runtime.activationReservationBytes(),
        .pool_overhead_bytes = runtime.activationPoolOverheadBytes(),
        .occupied_high_water_bytes = runtime.occupiedActivationHighWaterBytes(),
    };
    layout.closeRuntime();
    const runtime_closed = try process_metrics.sample();
    const observations: Observation = .{
        .baseline = baseline,
        .runtime_open = runtime_open,
        .workload_complete = workload_complete,
        .runtime_closed = runtime_closed,
    };
    var report_buffer: [16 * 1024]u8 = undefined;
    const report = try formatReport(
        &report_buffer,
        scenario,
        count,
        observations,
        @intCast(wall_end - wall_start),
        @intCast(cpu_end - cpu_start),
        durable_bytes,
        activation,
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}

fn createDormantSessions(layout: *Layout, count: usize) !void {
    for (0..count) |_| {
        var fixture: deterministic_provider.Fixture = .{
            .expected_task = fixture_task,
            .final_answer = fixture_answer,
        };
        const owner = try harness.Harness.open(.{
            .runtime = layout.runtime.?,
            .mode = .{ .create = .{
                .workspace_path = layout.workspace_path,
                .model_binding = .{
                    .model = "fixture:measurement-dormant",
                    .provider = fixture.provider(),
                },
                .task = fixture_task,
            } },
        });
        defer owner.close();
        const identity = try owner.drive();
        if (identity.projection_count != 1 or identity.projections[0].kind != .session) {
            return error.SessionIdentityMissing;
        }
    }
}

fn completeSessions(layout: *Layout, count: usize) !void {
    for (0..count) |_| {
        var fixture: deterministic_provider.Fixture = .{
            .expected_task = fixture_task,
            .final_answer = fixture_answer,
        };
        const owner = try harness.Harness.open(.{
            .runtime = layout.runtime.?,
            .mode = .{ .create = .{
                .workspace_path = layout.workspace_path,
                .model_binding = .{
                    .model = "fixture:measurement-completion",
                    .provider = fixture.provider(),
                },
                .task = fixture_task,
            } },
        });
        defer owner.close();
        _ = try owner.drive();
        if (owner.offer(.task) != .accepted) return error.TaskOfferRejected;
        _ = try owner.drive();
        const finished = try owner.drive();
        if (finished.state != .finished or fixture.calls != 1) return error.SessionDidNotFinish;
    }
}

const Layout = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    state_path: []u8,
    workspace_path: []u8,
    runtime: ?*harness.HostRuntime,

    fn init(io: std.Io, allocator: std.mem.Allocator) !Layout {
        var random: [8]u8 = undefined;
        io.random(&random);
        const root_path = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/runtime-measurement-{x}",
            .{random},
        );
        errdefer allocator.free(root_path);
        var root = try std.Io.Dir.cwd().createDirPathOpen(io, root_path, .{});
        defer root.close(io);
        errdefer std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
        try root.createDir(io, "state", .default_dir);
        try root.createDir(io, "workspace", .default_dir);
        const state_path = try std.fs.path.join(allocator, &.{ root_path, "state" });
        errdefer allocator.free(state_path);
        const workspace_path = try std.fs.path.join(allocator, &.{ root_path, "workspace" });
        errdefer allocator.free(workspace_path);
        const initialized = try std.process.run(allocator, io, .{
            .argv = &.{ "git", "init", "--quiet", workspace_path },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        });
        defer allocator.free(initialized.stdout);
        defer allocator.free(initialized.stderr);
        switch (initialized.term) {
            .exited => |code| if (code != 0) return error.GitInitFailed,
            else => return error.GitInitFailed,
        }
        return .{
            .allocator = allocator,
            .root_path = root_path,
            .state_path = state_path,
            .workspace_path = workspace_path,
            .runtime = null,
        };
    }

    fn openRuntime(self: *Layout, io: std.Io, active_capacity: usize) !void {
        if (self.runtime != null) return error.RuntimeAlreadyOpen;
        self.runtime = try harness.HostRuntime.open(io, self.allocator, self.state_path, .{
            .active_capacity = active_capacity,
        });
    }

    fn closeRuntime(self: *Layout) void {
        const runtime = self.runtime orelse return;
        runtime.close() catch unreachable;
        self.runtime = null;
    }

    fn durableBytes(self: *const Layout, io: std.Io) !u64 {
        var state = try std.Io.Dir.cwd().openDir(io, self.state_path, .{ .iterate = true });
        defer state.close(io);
        return directoryBytes(io, state);
    }

    fn deinit(self: *Layout, io: std.Io) void {
        self.closeRuntime();
        std.Io.Dir.cwd().deleteTree(io, self.root_path) catch {};
        self.allocator.free(self.workspace_path);
        self.allocator.free(self.state_path);
        self.allocator.free(self.root_path);
    }
};

fn directoryBytes(io: std.Io, directory: std.Io.Dir) !u64 {
    var total: u64 = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| switch (entry.kind) {
        .file => {
            const file = try directory.openFile(io, entry.name, .{});
            defer file.close(io);
            total += (try file.stat(io)).size;
        },
        .directory => {
            var child = try directory.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            total += try directoryBytes(io, child);
        },
        else => {},
    };
    return total;
}

fn monotonicNanoseconds() !u64 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &time) != 0) return error.ClockUnavailable;
    return @intCast(@as(i128, time.sec) * std.time.ns_per_s + time.nsec);
}

fn processCpuNanoseconds() !u64 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.PROCESS_CPUTIME_ID, &time) != 0) {
        return error.ClockUnavailable;
    }
    return @intCast(@as(i128, time.sec) * std.time.ns_per_s + time.nsec);
}

fn formatReport(
    buffer: []u8,
    scenario: Scenario,
    count: usize,
    observations: Observation,
    wall_time_ns: u64,
    cpu_time_ns: u64,
    durable_bytes: u64,
    activation: ActivationObservation,
) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\{{
        \\  "schema": "onepage.runtime-measurement.v{d}",
        \\  "scenario": "{s}",
        \\  "build_mode": "{s}",
        \\  "count": {d},
        \\  "active_capacity": {d},
        \\  "activation_slot_bytes": {d},
        \\  "activation_reservation_bytes": {d},
        \\  "activation_pool_overhead_bytes": {d},
        \\  "activation_occupied_high_water_bytes": {d},
        \\  "measurement_scope": "whole OnePage process; workload subprocesses excluded",
        \\  "timing": {{"wall_ns": {d}, "cpu_ns": {d}, "operations_per_second": {d:.3}}},
        \\  "durable_bytes": {d},
        \\  "observations": {{
        \\    "baseline": {f},
        \\    "runtime_open": {f},
        \\    "workload_complete": {f},
        \\    "runtime_closed": {f}
        \\  }}
        \\}}
        \\
    , .{
        schema_version,
        @tagName(scenario),
        @tagName(builtin.mode),
        count,
        activation.active_capacity,
        activation.slot_bytes,
        activation.reserved_bytes,
        activation.pool_overhead_bytes,
        activation.occupied_high_water_bytes,
        wall_time_ns,
        cpu_time_ns,
        operationsPerSecond(count, wall_time_ns),
        durable_bytes,
        std.json.fmt(observations.baseline, .{}),
        std.json.fmt(observations.runtime_open, .{}),
        std.json.fmt(observations.workload_complete, .{}),
        std.json.fmt(observations.runtime_closed, .{}),
    });
}

const ActivationObservation = struct {
    active_capacity: usize,
    slot_bytes: usize,
    reserved_bytes: usize,
    pool_overhead_bytes: usize,
    occupied_high_water_bytes: usize,
};

fn operationsPerSecond(count: usize, wall_time_ns: u64) f64 {
    if (wall_time_ns == 0) return 0;
    return @as(f64, @floatFromInt(count)) * @as(f64, std.time.ns_per_s) /
        @as(f64, @floatFromInt(wall_time_ns));
}

test "zero work has zero throughput" {
    try std.testing.expectEqual(@as(f64, 0), operationsPerSecond(0, 1));
}

test "measurement durable bytes exclude fixture Workspace" {
    var layout = try Layout.init(std.testing.io, std.testing.allocator);
    defer layout.deinit(std.testing.io);
    try layout.openRuntime(std.testing.io, 1);
    const before = try layout.durableBytes(std.testing.io);
    var workspace = try std.Io.Dir.cwd().openDir(std.testing.io, layout.workspace_path, .{});
    defer workspace.close(std.testing.io);
    try workspace.writeFile(std.testing.io, .{
        .sub_path = "measurement-noise",
        .data = "this fixture byte is not Host state",
    });
    try std.testing.expectEqual(before, try layout.durableBytes(std.testing.io));
}

test "measurement failure releases the Harness Runtime lease" {
    var layout = try Layout.init(std.testing.io, std.testing.allocator);
    defer layout.deinit(std.testing.io);
    try layout.openRuntime(std.testing.io, 1);
    try std.testing.expectError(error.InjectedMeasurementFailure, failAfterHarnessOpen(&layout));
    layout.closeRuntime();
}

fn failAfterHarnessOpen(layout: *Layout) !void {
    var fixture: deterministic_provider.Fixture = .{
        .expected_task = fixture_task,
        .final_answer = fixture_answer,
    };
    const owner = try harness.Harness.open(.{
        .runtime = layout.runtime.?,
        .mode = .{ .create = .{
            .workspace_path = layout.workspace_path,
            .model_binding = .{
                .model = "fixture:measurement-failure",
                .provider = fixture.provider(),
            },
            .task = fixture_task,
        } },
    });
    defer owner.close();
    return error.InjectedMeasurementFailure;
}
