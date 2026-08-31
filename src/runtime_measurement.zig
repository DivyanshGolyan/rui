const std = @import("std");
const builtin = @import("builtin");
const core_image = @import("core_image.zig");
const deterministic_provider = @import("deterministic_provider.zig");
const harness = @import("harness.zig");
const host_store = @import("host_store.zig");
const process_metrics = @import("process_metrics.zig");
const schema = @import("runtime_measurement_schema.zig");
const summary = @import("runtime_measurement_summary.zig");

const c = @cImport({
    @cInclude("sys/stat.h");
});

const fixture_task = "Measure one durable agent lifecycle.";
const fixture_answer = "Measurement complete.";

const Scenario = enum {
    dormant,
    completion,
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
    const runtime = layout.runtime.?;
    const sqlite_pager_before = try runtime.sqlitePagerAccounting();
    const sqlite_memory_before = try runtime.sqliteMemoryAccounting(false);
    // SQLite heap high-water is process-wide. Reset it after runtime startup so
    // the reported high-water is the workload interval, not a workload delta.
    _ = try runtime.sqliteMemoryAccounting(true);
    const wall_start = try monotonicNanoseconds();
    const cpu_start = try processCpuNanoseconds();

    switch (scenario) {
        .dormant => try createDormantSessions(&layout, count),
        .completion => try completeSessions(&layout, count),
    }

    const wall_end = try monotonicNanoseconds();
    const cpu_end = try processCpuNanoseconds();
    const sqlite_after = try postWorkloadSqliteAccounting(runtime);
    const workload_complete = try process_metrics.sample();
    const storage = try layout.storageFootprint(init.io);
    const activation: ActivationObservation = .{
        .active_capacity = runtime.activeCapacity(),
        .slot_bytes = @sizeOf(core_image.ActivationSlot),
        .reserved_bytes = runtime.reservedActivationBytes(),
        .pool_overhead_bytes = runtime.activationPoolOverheadBytes(),
        .occupied_high_water_bytes = runtime.occupiedActivationHighWaterBytes(),
    };
    layout.closeRuntime();
    const runtime_closed = try process_metrics.sample();
    var report_buffer: [16 * 1024]u8 = undefined;
    const report = try formatReport(
        &report_buffer,
        .{
            .schema = schema.record_schema,
            .scenario = @tagName(scenario),
            .build_mode = @tagName(builtin.mode),
            .count = try wireU64(count),
            .active_capacity = try wireU64(activation.active_capacity),
            .activation_slot_bytes = try wireU64(activation.slot_bytes),
            .activation_reservation_bytes = try wireU64(activation.reserved_bytes),
            .activation_pool_overhead_bytes = try wireU64(activation.pool_overhead_bytes),
            .activation_occupied_high_water_bytes = try wireU64(activation.occupied_high_water_bytes),
            .measurement_scope = "whole OnePage process; workload subprocesses excluded",
            .timing = .{
                .wall_ns = @intCast(wall_end - wall_start),
                .cpu_ns = @intCast(cpu_end - cpu_start),
                .operations_per_second = operationsPerSecond(count, wall_end - wall_start),
            },
            .durable_storage = storage,
            .sqlite_pager = .{
                .before = wireSqlitePagerAccounting(sqlite_pager_before),
                .after = wireSqlitePagerAccounting(sqlite_after.pager),
            },
            .sqlite_memory = sqliteMemoryObservation(sqlite_memory_before, sqlite_after.memory),
            .observations = .{
                .baseline = wireProcessSample(baseline),
                .runtime_open = wireProcessSample(runtime_open),
                .workload_complete = wireProcessSample(workload_complete),
                .runtime_closed = wireProcessSample(runtime_closed),
            },
        },
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

    fn storageFootprint(self: *const Layout, io: std.Io) !StorageFootprint {
        var state = try std.Io.Dir.cwd().openDir(io, self.state_path, .{ .iterate = true });
        defer state.close(io);
        return measureStorage(io, state);
    }

    fn deinit(self: *Layout, io: std.Io) void {
        self.closeRuntime();
        std.Io.Dir.cwd().deleteTree(io, self.root_path) catch {};
        self.allocator.free(self.workspace_path);
        self.allocator.free(self.state_path);
        self.allocator.free(self.root_path);
    }
};

const ByteFootprint = schema.ByteFootprint;
const StorageFootprint = schema.DurableStorage;

fn addFootprint(total: *ByteFootprint, addition: ByteFootprint) void {
    total.logical_file_bytes += addition.logical_file_bytes;
    total.allocated_file_bytes += addition.allocated_file_bytes;
}

fn measureStorage(io: std.Io, directory: std.Io.Dir) !StorageFootprint {
    var result: StorageFootprint = .{};
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| switch (entry.kind) {
        .file => {
            const footprint = try measureFile(io, directory, entry.name);
            if (std.mem.eql(u8, entry.name, "host.sqlite3") or
                std.mem.startsWith(u8, entry.name, "host.sqlite3-"))
            {
                addFootprint(&result.sqlite, footprint);
            } else {
                addFootprint(&result.other, footprint);
            }
        },
        .directory => {
            var child = try directory.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            const footprint = try directoryFootprint(io, child);
            if (std.mem.eql(u8, entry.name, "sessions")) {
                addFootprint(&result.sessions, footprint);
            } else {
                addFootprint(&result.other, footprint);
            }
        },
        else => {},
    };
    return result;
}

fn directoryFootprint(io: std.Io, directory: std.Io.Dir) !ByteFootprint {
    var total: ByteFootprint = .{};
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| switch (entry.kind) {
        .file => addFootprint(&total, try measureFile(io, directory, entry.name)),
        .directory => {
            var child = try directory.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            addFootprint(&total, try directoryFootprint(io, child));
        },
        else => {},
    };
    return total;
}

fn measureFile(io: std.Io, directory: std.Io.Dir, name: []const u8) !ByteFootprint {
    const file = try directory.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var native_stat: c.struct_stat = undefined;
    if (c.fstat(file.handle, &native_stat) != 0 or native_stat.st_blocks < 0) {
        return error.FileAllocationUnavailable;
    }
    return .{
        .logical_file_bytes = stat.size,
        // POSIX defines st_blocks in 512-byte units, independent of st_blksize.
        .allocated_file_bytes = @as(u64, @intCast(native_stat.st_blocks)) * 512,
    };
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

pub fn formatReport(buffer: []u8, record: schema.Record) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\{{
        \\  "schema": "{s}",
        \\  "scenario": "{s}",
        \\  "build_mode": "{s}",
        \\  "count": {d},
        \\  "active_capacity": {d},
        \\  "activation_slot_bytes": {d},
        \\  "activation_reservation_bytes": {d},
        \\  "activation_pool_overhead_bytes": {d},
        \\  "activation_occupied_high_water_bytes": {d},
        \\  "measurement_scope": "{s}",
        \\  "timing": {{"wall_ns": {d}, "cpu_ns": {d}, "operations_per_second": {d:.3}}},
        \\  "durable_storage": {f},
        \\  "sqlite_pager": {f},
        \\  "sqlite_memory": {f},
        \\  "observations": {{
        \\    "baseline": {f},
        \\    "runtime_open": {f},
        \\    "workload_complete": {f},
        \\    "runtime_closed": {f}
        \\  }}
        \\}}
        \\
    , .{
        record.schema,
        record.scenario,
        record.build_mode,
        record.count,
        record.active_capacity,
        record.activation_slot_bytes,
        record.activation_reservation_bytes,
        record.activation_pool_overhead_bytes,
        record.activation_occupied_high_water_bytes,
        record.measurement_scope,
        record.timing.wall_ns,
        record.timing.cpu_ns,
        record.timing.operations_per_second,
        std.json.fmt(record.durable_storage, .{}),
        std.json.fmt(record.sqlite_pager, .{}),
        std.json.fmt(record.sqlite_memory, .{}),
        std.json.fmt(record.observations.baseline, .{}),
        std.json.fmt(record.observations.runtime_open, .{}),
        std.json.fmt(record.observations.workload_complete, .{}),
        std.json.fmt(record.observations.runtime_closed, .{}),
    });
}

const ActivationObservation = struct {
    active_capacity: usize,
    slot_bytes: usize,
    reserved_bytes: usize,
    pool_overhead_bytes: usize,
    occupied_high_water_bytes: usize,
};

/// Runtime sizes remain native-width, but every persisted measurement value is
/// explicitly represented as u64.
fn wireU64(value: usize) !u64 {
    return std.math.cast(u64, value) orelse error.MeasurementValueTooLarge;
}

fn sqliteMemoryObservation(
    before: host_store.MemoryAccounting,
    after: host_store.MemoryAccounting,
) schema.SqliteMemoryObservation {
    return .{
        .before = .{
            .heap_bytes = before.heap_current_bytes,
            .page_cache_bytes = before.page_cache_current_bytes,
            .lookaside_slots = before.lookaside_current_slots,
            .statements_bytes = before.statements_current_bytes,
        },
        .after = .{
            .heap_bytes = after.heap_current_bytes,
            .page_cache_bytes = after.page_cache_current_bytes,
            .lookaside_slots = after.lookaside_current_slots,
            .statements_bytes = after.statements_current_bytes,
        },
        .workload_highwater = .{
            .heap_bytes = after.heap_highwater_bytes,
            .lookaside_slots = after.lookaside_highwater_slots,
        },
    };
}

fn wireSqlitePagerAccounting(
    accounting: host_store.SqlitePagerAccounting,
) schema.SqlitePagerAccounting {
    return .{
        .page_count = accounting.page_count,
        .freelist_pages = accounting.freelist_pages,
        .cache_pages_written = accounting.cache_pages_written,
        .cache_spill_events = accounting.cache_spill_events,
    };
}

const PostWorkloadSqliteAccounting = struct {
    memory: host_store.MemoryAccounting,
    pager: host_store.SqlitePagerAccounting,
};

/// The heap high-water is sampled before pager diagnostics, whose PRAGMA reads
/// may allocate SQLite bookkeeping memory of their own.
fn postWorkloadSqliteAccounting(runtime: *harness.HostRuntime) !PostWorkloadSqliteAccounting {
    const memory = try runtime.sqliteMemoryAccounting(false);
    const pager = try runtime.sqlitePagerAccounting();
    return .{ .memory = memory, .pager = pager };
}

fn wireProcessSample(sample: process_metrics.Sample) schema.ProcessSample {
    return .{
        .resident_bytes = sample.resident_bytes,
        .physical_footprint_bytes = sample.physical_footprint_bytes,
        .lifetime_peak_physical_footprint_bytes = sample.lifetime_peak_physical_footprint_bytes,
        .virtual_bytes = sample.virtual_bytes,
        .thread_count = sample.thread_count,
        .running_thread_count = sample.running_thread_count,
        .user_cpu_ns = sample.user_cpu_ns,
        .system_cpu_ns = sample.system_cpu_ns,
        .package_idle_wakeups = sample.package_idle_wakeups,
        .interrupt_wakeups = sample.interrupt_wakeups,
        .pageins = sample.pageins,
        .disk_read_bytes = sample.disk_read_bytes,
        .disk_written_bytes = sample.disk_written_bytes,
        .instructions = sample.instructions,
        .cycles = sample.cycles,
    };
}

fn operationsPerSecond(count: usize, wall_time_ns: u64) f64 {
    if (wall_time_ns == 0) return 0;
    return @as(f64, @floatFromInt(count)) * @as(f64, std.time.ns_per_s) /
        @as(f64, @floatFromInt(wall_time_ns));
}

test "zero work has zero throughput" {
    try std.testing.expectEqual(@as(f64, 0), operationsPerSecond(0, 1));
}

test "measurement wire sizes convert from native widths" {
    try std.testing.expectEqual(@as(u64, 1), try wireU64(1));
    if (@bitSizeOf(usize) > @bitSizeOf(u64)) {
        try std.testing.expectError(error.MeasurementValueTooLarge, wireU64(std.math.maxInt(usize)));
    }
}

test "producer v2 JSON round-trips through the summary" {
    const empty_sample: schema.ProcessSample = .{
        .resident_bytes = 0,
        .physical_footprint_bytes = 0,
        .lifetime_peak_physical_footprint_bytes = 0,
        .virtual_bytes = 0,
        .thread_count = 1,
        .running_thread_count = 1,
        .user_cpu_ns = 0,
        .system_cpu_ns = 0,
        .package_idle_wakeups = 0,
        .interrupt_wakeups = 0,
        .pageins = 0,
        .disk_read_bytes = 0,
        .disk_written_bytes = 0,
        .instructions = 0,
        .cycles = 0,
    };
    const record: schema.Record = .{
        .schema = schema.record_schema,
        .scenario = "dormant",
        .build_mode = "ReleaseSafe",
        .count = 1,
        .active_capacity = 1,
        .activation_slot_bytes = 168,
        .activation_reservation_bytes = 168,
        .activation_pool_overhead_bytes = 40,
        .activation_occupied_high_water_bytes = 0,
        .measurement_scope = "test",
        .timing = .{ .wall_ns = 1, .cpu_ns = 1, .operations_per_second = 1 },
        .durable_storage = .{},
        .sqlite_pager = .{
            .before = .{ .page_count = 1, .freelist_pages = 0, .cache_pages_written = 0, .cache_spill_events = 0 },
            .after = .{ .page_count = 1, .freelist_pages = 0, .cache_pages_written = 0, .cache_spill_events = 0 },
        },
        .sqlite_memory = .{
            .before = .{ .heap_bytes = 1, .page_cache_bytes = 0, .lookaside_slots = 0, .statements_bytes = 0 },
            .after = .{ .heap_bytes = 1, .page_cache_bytes = 0, .lookaside_slots = 0, .statements_bytes = 0 },
            .workload_highwater = .{ .heap_bytes = 1, .lookaside_slots = 0 },
        },
        .observations = .{
            .baseline = empty_sample,
            .runtime_open = empty_sample,
            .workload_complete = empty_sample,
            .runtime_closed = empty_sample,
        },
    };
    var report_storage: [16 * 1024]u8 = undefined;
    const report = try formatReport(&report_storage, record);
    var input_storage: [32 * 1024]u8 = undefined;
    var input = std.Io.Writer.fixed(&input_storage);
    try input.writeAll("{\"schema\":\"onepage.runtime-measurement-sweep.v2\",\"source_commit\":\"abc\",\"platform\":\"test\",\"repetitions\":1,\"source_provenance\":\"clean-published\"}\n");
    for (report) |byte| if (byte != '\n') try input.writeByte(byte);
    try input.writeByte('\n');
    var summary_storage: [16 * 1024]u8 = undefined;
    const output = try summary.summarize(std.testing.allocator, input.buffered(), &summary_storage);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"sqlite_page_count\"") != null);
}

test "measurement durable storage excludes fixture Workspace" {
    var layout = try Layout.init(std.testing.io, std.testing.allocator);
    defer layout.deinit(std.testing.io);
    try layout.openRuntime(std.testing.io, 1);
    const before = try layout.storageFootprint(std.testing.io);
    var workspace = try std.Io.Dir.cwd().openDir(std.testing.io, layout.workspace_path, .{});
    defer workspace.close(std.testing.io);
    try workspace.writeFile(std.testing.io, .{
        .sub_path = "measurement-noise",
        .data = "this fixture byte is not Host state",
    });
    try std.testing.expectEqualDeep(before, try layout.storageFootprint(std.testing.io));
}

test "measurement storage buckets retain every Host-state category" {
    var layout = try Layout.init(std.testing.io, std.testing.allocator);
    defer layout.deinit(std.testing.io);
    try layout.openRuntime(std.testing.io, 1);
    const before = try layout.storageFootprint(std.testing.io);
    var state = try std.Io.Dir.cwd().openDir(std.testing.io, layout.state_path, .{});
    defer state.close(std.testing.io);
    try state.writeFile(std.testing.io, .{
        .sub_path = "measurement-other",
        .data = "other",
    });
    const after = try layout.storageFootprint(std.testing.io);
    try std.testing.expectEqualDeep(before.sqlite, after.sqlite);
    try std.testing.expectEqualDeep(before.sessions, after.sessions);
    try std.testing.expectEqual(before.other.logical_file_bytes + 5, after.other.logical_file_bytes);
}

test "workload SQLite heap snapshot precedes pager diagnostics" {
    var layout = try Layout.init(std.testing.io, std.testing.allocator);
    defer layout.deinit(std.testing.io);
    try layout.openRuntime(std.testing.io, 1);
    const runtime = layout.runtime.?;
    _ = try runtime.sqliteMemoryAccounting(true);
    try createDormantSessions(&layout, 1);
    const after = try postWorkloadSqliteAccounting(runtime);
    try std.testing.expect(after.memory.heap_highwater_bytes >= after.memory.heap_current_bytes);
    try std.testing.expect(after.pager.page_count > 0);
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
