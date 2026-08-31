const std = @import("std");

const max_input_bytes = 16 * 1024 * 1024;
const max_groups = 32;
const max_repetitions = 99;

const Header = struct {
    schema: []const u8,
    source_commit: []const u8,
    platform: []const u8,
    repetitions: usize,
    source_dirty: bool,
};

const Timing = struct {
    wall_ns: u64,
    cpu_ns: u64,
    operations_per_second: f64,
};

const Sample = struct {
    resident_bytes: u64,
    physical_footprint_bytes: u64,
    lifetime_peak_physical_footprint_bytes: u64,
    virtual_bytes: u64,
    thread_count: u32,
    running_thread_count: u32,
    user_cpu_ns: u64,
    system_cpu_ns: u64,
    package_idle_wakeups: u64,
    interrupt_wakeups: u64,
    pageins: u64,
    disk_read_bytes: u64,
    disk_written_bytes: u64,
    instructions: u64,
    cycles: u64,
};

const Observations = struct {
    baseline: Sample,
    runtime_open: Sample,
    workload_complete: Sample,
    runtime_closed: Sample,
};

const RuntimeResources = struct {
    harness_owner_bytes: usize,
    live_harnesses_after_workload: usize,
    active_credit_reservation_bytes: usize,
    active_credit_occupied_high_water: usize,
    semantic_validation_reservation_bytes: usize,
    semantic_validation_occupied_high_water_bytes: usize,
    patch_workspace_reservation_bytes: usize,
    patch_workspace_occupied_high_water_bytes: usize,
};

const Record = struct {
    schema: []const u8,
    scenario: []const u8,
    build_mode: []const u8,
    count: usize,
    active_capacity: usize,
    activation_slot_bytes: usize,
    activation_reservation_bytes: usize,
    activation_pool_overhead_bytes: usize,
    activation_occupied_high_water_bytes: usize,
    runtime_resources: RuntimeResources,
    measurement_scope: []const u8,
    timing: Timing,
    durable_bytes: u64,
    observations: Observations,
};

const Scenario = enum { dormant, completion };
const BuildMode = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };

const Datum = struct {
    runtime_open_physical_delta_bytes: u64,
    runtime_open_rss_delta_bytes: u64,
    physical_delta_bytes: u64,
    rss_delta_bytes: u64,
    wall_ns: u64,
    cpu_ns: u64,
    operations_per_second: f64,
    disk_read_delta_bytes: u64,
    disk_written_delta_bytes: u64,
    package_idle_wakeup_delta: u64,
    interrupt_wakeup_delta: u64,
    durable_bytes: u64,
};

const Group = struct {
    scenario: Scenario,
    count: usize,
    active_capacity: usize,
    activation_slot_bytes: usize,
    activation_reservation_bytes: usize,
    activation_pool_overhead_bytes: usize,
    activation_occupied_high_water_bytes: usize,
    runtime_resources: RuntimeResources,
    data: [max_repetitions]Datum = undefined,
    data_count: usize = 0,
};

const IntegerMetric = enum {
    runtime_open_physical_delta_bytes,
    runtime_open_rss_delta_bytes,
    physical_delta_bytes,
    rss_delta_bytes,
    wall_ns,
    cpu_ns,
    disk_read_delta_bytes,
    disk_written_delta_bytes,
    package_idle_wakeup_delta,
    interrupt_wakeup_delta,
    durable_bytes,
};

const IntegerRange = struct { median: u64, min: u64, max: u64 };
const FloatRange = struct { median: f64, min: f64, max: f64 };

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;
    const input = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(max_input_bytes),
    );
    defer allocator.free(input);
    var summary_storage: [128 * 1024]u8 = undefined;
    const summary = try summarize(allocator, input, &summary_storage);
    var output = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .truncate = true });
    defer output.close(init.io);
    try output.writeStreamingAll(init.io, summary);
}

fn summarize(allocator: std.mem.Allocator, input: []const u8, output: []u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, input, '\n');
    const header_line = lines.next() orelse return error.MeasurementHeaderMissing;
    if (header_line.len == 0) return error.MeasurementHeaderMissing;
    var parsed_header = try std.json.parseFromSlice(Header, allocator, header_line, .{});
    defer parsed_header.deinit();
    const header = parsed_header.value;
    if (!std.mem.eql(u8, header.schema, "onepage.runtime-measurement-sweep.v1")) {
        return error.UnsupportedMeasurementSweepSchema;
    }
    if (header.source_commit.len == 0 or header.platform.len == 0 or
        header.repetitions == 0 or header.repetitions > max_repetitions or
        header.repetitions % 2 == 0)
    {
        return error.InvalidMeasurementMetadata;
    }

    var groups: [max_groups]Group = undefined;
    var group_count: usize = 0;
    var build_mode: ?BuildMode = null;
    var measurement_scope: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(Record, allocator, line, .{});
        defer parsed.deinit();
        const record = parsed.value;
        if (!std.mem.eql(u8, record.schema, "onepage.runtime-measurement.v1")) {
            return error.UnsupportedMeasurementSchema;
        }
        const record_scenario = std.meta.stringToEnum(Scenario, record.scenario) orelse
            return error.InvalidMeasurementScenario;
        const record_build_mode = std.meta.stringToEnum(BuildMode, record.build_mode) orelse
            return error.InvalidMeasurementBuildMode;
        if (build_mode) |expected| {
            if (record_build_mode != expected) return error.MixedMeasurementMetadata;
        } else {
            build_mode = record_build_mode;
        }
        if (measurement_scope) |expected| {
            if (!std.mem.eql(u8, record.measurement_scope, expected)) {
                return error.MixedMeasurementMetadata;
            }
        } else {
            measurement_scope = record.measurement_scope;
        }
        const datum = try deriveDatum(record);
        const group = try findOrCreateGroup(
            &groups,
            &group_count,
            record_scenario,
            record,
        );
        if (group.data_count >= header.repetitions) return error.TooManyMeasurementRepetitions;
        group.data[group.data_count] = datum;
        group.data_count += 1;
    }
    if (group_count == 0 or build_mode == null or measurement_scope == null) {
        return error.MeasurementRecordsMissing;
    }
    for (groups[0..group_count]) |group| {
        if (group.data_count != header.repetitions) return error.IncompleteMeasurementPoint;
    }
    sortGroups(groups[0..group_count]);

    var writer = std.Io.Writer.fixed(output);
    try writer.writeAll("{\n  \"schema\": \"onepage.runtime-measurement-summary.v1\",\n  \"source_commit\": ");
    try std.json.Stringify.value(header.source_commit, .{}, &writer);
    try writer.writeAll(",\n  \"platform\": ");
    try std.json.Stringify.value(header.platform, .{}, &writer);
    try writer.print(
        ",\n  \"build_mode\": \"{s}\",\n  \"repetitions\": {d},\n" ++
            "  \"source_dirty\": {s},\n" ++
            "  \"process_conditions\": \"fresh process per point; build artifacts warm; filesystem cache uncontrolled\",\n" ++
            "  \"measurement_scope\": ",
        .{ @tagName(build_mode.?), header.repetitions, if (header.source_dirty) "true" else "false" },
    );
    try std.json.Stringify.value(measurement_scope.?, .{}, &writer);
    try writer.writeAll(",\n  \"points\": [\n");
    for (groups[0..group_count], 0..) |group, index| {
        if (index != 0) try writer.writeAll(",\n");
        try writeGroup(&writer, group);
    }
    try writer.writeAll("\n  ]\n}\n");
    return writer.buffered();
}

fn deriveDatum(record: Record) !Datum {
    const before = record.observations.runtime_open;
    const after = record.observations.workload_complete;
    return .{
        .runtime_open_physical_delta_bytes = try checkedDelta(
            record.observations.runtime_open.physical_footprint_bytes,
            record.observations.baseline.physical_footprint_bytes,
        ),
        .runtime_open_rss_delta_bytes = try checkedDelta(
            record.observations.runtime_open.resident_bytes,
            record.observations.baseline.resident_bytes,
        ),
        .physical_delta_bytes = try checkedDelta(after.physical_footprint_bytes, before.physical_footprint_bytes),
        .rss_delta_bytes = try checkedDelta(after.resident_bytes, before.resident_bytes),
        .wall_ns = record.timing.wall_ns,
        .cpu_ns = record.timing.cpu_ns,
        .operations_per_second = record.timing.operations_per_second,
        .disk_read_delta_bytes = try checkedDelta(after.disk_read_bytes, before.disk_read_bytes),
        .disk_written_delta_bytes = try checkedDelta(after.disk_written_bytes, before.disk_written_bytes),
        .package_idle_wakeup_delta = try checkedDelta(after.package_idle_wakeups, before.package_idle_wakeups),
        .interrupt_wakeup_delta = try checkedDelta(after.interrupt_wakeups, before.interrupt_wakeups),
        .durable_bytes = record.durable_bytes,
    };
}

fn checkedDelta(after: u64, before: u64) !u64 {
    if (after < before) return error.MeasurementCounterRegressed;
    return after - before;
}

fn findOrCreateGroup(
    groups: *[max_groups]Group,
    group_count: *usize,
    scenario: Scenario,
    record: Record,
) !*Group {
    for (groups[0..group_count.*]) |*group| {
        if (group.scenario != scenario or group.count != record.count or
            group.active_capacity != record.active_capacity)
        {
            continue;
        }
        if (group.activation_slot_bytes != record.activation_slot_bytes or
            group.activation_reservation_bytes != record.activation_reservation_bytes or
            group.activation_pool_overhead_bytes != record.activation_pool_overhead_bytes or
            group.activation_occupied_high_water_bytes != record.activation_occupied_high_water_bytes or
            !std.meta.eql(group.runtime_resources, record.runtime_resources))
        {
            return error.MixedMeasurementMetadata;
        }
        return group;
    }
    if (group_count.* == groups.len) return error.TooManyMeasurementPoints;
    const group = &groups[group_count.*];
    group.* = .{
        .scenario = scenario,
        .count = record.count,
        .active_capacity = record.active_capacity,
        .activation_slot_bytes = record.activation_slot_bytes,
        .activation_reservation_bytes = record.activation_reservation_bytes,
        .activation_pool_overhead_bytes = record.activation_pool_overhead_bytes,
        .activation_occupied_high_water_bytes = record.activation_occupied_high_water_bytes,
        .runtime_resources = record.runtime_resources,
    };
    group_count.* += 1;
    return group;
}

fn sortGroups(groups: []Group) void {
    var index: usize = 1;
    while (index < groups.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and groupBefore(groups[cursor], groups[cursor - 1])) : (cursor -= 1) {
            std.mem.swap(Group, &groups[cursor], &groups[cursor - 1]);
        }
    }
}

fn groupBefore(left: Group, right: Group) bool {
    if (@intFromEnum(left.scenario) != @intFromEnum(right.scenario)) {
        return @intFromEnum(left.scenario) < @intFromEnum(right.scenario);
    }
    if (left.count != right.count) return left.count < right.count;
    return left.active_capacity < right.active_capacity;
}

fn writeGroup(writer: *std.Io.Writer, group: Group) !void {
    try writer.print(
        "    {{\"scenario\":\"{s}\",\"count\":{d},\"active_capacity\":{d}," ++
            "\"activation_slot_bytes\":{d},\"activation_reservation_bytes\":{d}," ++
            "\"activation_pool_overhead_bytes\":{d}," ++
            "\"activation_occupied_high_water_bytes\":{d},\n" ++
            "      \"runtime_resources\":{f},\n",
        .{
            @tagName(group.scenario),
            group.count,
            group.active_capacity,
            group.activation_slot_bytes,
            group.activation_reservation_bytes,
            group.activation_pool_overhead_bytes,
            group.activation_occupied_high_water_bytes,
            std.json.fmt(group.runtime_resources, .{}),
        },
    );
    inline for (std.meta.fields(IntegerMetric), 0..) |field, index| {
        const metric: IntegerMetric = @enumFromInt(field.value);
        try writer.print("      \"{s}\":", .{field.name});
        try writeIntegerRange(writer, integerRange(group.data[0..group.data_count], metric));
        try writer.writeAll(",\n");
        _ = index;
    }
    try writer.writeAll("      \"operations_per_second\":");
    try writeFloatRange(writer, floatRange(group.data[0..group.data_count]));
    try writer.writeAll("}");
}

fn integerRange(data: []const Datum, metric: IntegerMetric) IntegerRange {
    var values: [max_repetitions]u64 = undefined;
    for (data, 0..) |datum, index| values[index] = integerValue(datum, metric);
    sortIntegers(values[0..data.len]);
    return .{
        .median = values[data.len / 2],
        .min = values[0],
        .max = values[data.len - 1],
    };
}

fn integerValue(datum: Datum, metric: IntegerMetric) u64 {
    return switch (metric) {
        inline else => |tag| @field(datum, @tagName(tag)),
    };
}

fn floatRange(data: []const Datum) FloatRange {
    var values: [max_repetitions]f64 = undefined;
    for (data, 0..) |datum, index| values[index] = datum.operations_per_second;
    sortFloats(values[0..data.len]);
    return .{
        .median = values[data.len / 2],
        .min = values[0],
        .max = values[data.len - 1],
    };
}

fn sortIntegers(values: []u64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and values[cursor] < values[cursor - 1]) : (cursor -= 1) {
            std.mem.swap(u64, &values[cursor], &values[cursor - 1]);
        }
    }
}

fn sortFloats(values: []f64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and values[cursor] < values[cursor - 1]) : (cursor -= 1) {
            std.mem.swap(f64, &values[cursor], &values[cursor - 1]);
        }
    }
}

fn writeIntegerRange(writer: *std.Io.Writer, range: IntegerRange) !void {
    try writer.print(
        "{{\"median\":{d},\"min\":{d},\"max\":{d}}}",
        .{ range.median, range.min, range.max },
    );
}

fn writeFloatRange(writer: *std.Io.Writer, range: FloatRange) !void {
    try writer.print(
        "{{\"median\":{d:.3},\"min\":{d:.3},\"max\":{d:.3}}}",
        .{ range.median, range.min, range.max },
    );
}

test "summary reports exact odd median and range" {
    const allocator = std.testing.allocator;
    var input_storage: [32 * 1024]u8 = undefined;
    var input = std.Io.Writer.fixed(&input_storage);
    try input.writeAll("{\"schema\":\"onepage.runtime-measurement-sweep.v1\",\"source_commit\":\"abc\",\"platform\":\"test\",\"repetitions\":3,\"source_dirty\":false}\n");
    try writeTestRecord(&input, 30, 20, 300, 100, "ReleaseSafe");
    try input.writeByte('\n');
    try writeTestRecord(&input, 10, 5, 100, 50, "ReleaseSafe");
    try input.writeByte('\n');
    try writeTestRecord(&input, 20, 15, 200, 80, "ReleaseSafe");
    try input.writeByte('\n');
    var output: [16 * 1024]u8 = undefined;
    const summary = try summarize(allocator, input.buffered(), &output);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"physical_delta_bytes\":{\"median\":20,\"min\":10,\"max\":30}") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"disk_written_delta_bytes\":{\"median\":200,\"min\":100,\"max\":300}") != null);
}

test "summary rejects counter regression and mixed metadata" {
    const allocator = std.testing.allocator;
    var output: [16 * 1024]u8 = undefined;
    var regressed_storage: [16 * 1024]u8 = undefined;
    var regressed = std.Io.Writer.fixed(&regressed_storage);
    try regressed.writeAll("{\"schema\":\"onepage.runtime-measurement-sweep.v1\",\"source_commit\":\"abc\",\"platform\":\"test\",\"repetitions\":1,\"source_dirty\":false}\n");
    try writeRecord(&regressed, 2, 1, 2, 1, 2, 1, 1, "ReleaseSafe");
    try regressed.writeByte('\n');
    try std.testing.expectError(
        error.MeasurementCounterRegressed,
        summarize(allocator, regressed.buffered(), &output),
    );
    var mixed_storage: [32 * 1024]u8 = undefined;
    var mixed = std.Io.Writer.fixed(&mixed_storage);
    try mixed.writeAll("{\"schema\":\"onepage.runtime-measurement-sweep.v1\",\"source_commit\":\"abc\",\"platform\":\"test\",\"repetitions\":1,\"source_dirty\":false}\n");
    try writeTestRecord(&mixed, 1, 1, 1, 1, "ReleaseSafe");
    try mixed.writeByte('\n');
    try writeTestRecord(&mixed, 1, 1, 1, 1, "Debug");
    try mixed.writeByte('\n');
    try std.testing.expectError(
        error.MixedMeasurementMetadata,
        summarize(allocator, mixed.buffered(), &output),
    );
}

fn writeTestRecord(
    writer: *std.Io.Writer,
    physical: u64,
    rss: u64,
    written: u64,
    wakeups: u64,
    build_mode: []const u8,
) !void {
    try writeRecord(writer, 0, physical, 0, rss, 0, written, wakeups, build_mode);
}

fn writeRecord(
    writer: *std.Io.Writer,
    physical_before: u64,
    physical_after: u64,
    rss_before: u64,
    rss_after: u64,
    written_before: u64,
    written_after: u64,
    wakeups_after: u64,
    build_mode: []const u8,
) !void {
    const before = testSample(physical_before, rss_before, written_before, 0);
    const after = testSample(physical_after, rss_after, written_after, wakeups_after);
    try std.json.Stringify.value(Record{
        .schema = "onepage.runtime-measurement.v1",
        .scenario = "dormant",
        .build_mode = build_mode,
        .count = 1,
        .active_capacity = 1,
        .activation_slot_bytes = 168,
        .activation_reservation_bytes = 168,
        .activation_pool_overhead_bytes = 40,
        .activation_occupied_high_water_bytes = 168,
        .runtime_resources = .{
            .harness_owner_bytes = 8_112,
            .live_harnesses_after_workload = 0,
            .active_credit_reservation_bytes = 1,
            .active_credit_occupied_high_water = 1,
            .semantic_validation_reservation_bytes = 256_248,
            .semantic_validation_occupied_high_water_bytes = 256_224,
            .patch_workspace_reservation_bytes = 16_408,
            .patch_workspace_occupied_high_water_bytes = 0,
        },
        .measurement_scope = "test",
        .timing = .{ .wall_ns = 100, .cpu_ns = 90, .operations_per_second = 1.0 },
        .durable_bytes = 10,
        .observations = .{
            .baseline = before,
            .runtime_open = before,
            .workload_complete = after,
            .runtime_closed = after,
        },
    }, .{}, writer);
}

fn testSample(physical: u64, rss: u64, written: u64, wakeups: u64) Sample {
    return .{
        .resident_bytes = rss,
        .physical_footprint_bytes = physical,
        .lifetime_peak_physical_footprint_bytes = physical,
        .virtual_bytes = rss,
        .thread_count = 1,
        .running_thread_count = 1,
        .user_cpu_ns = 0,
        .system_cpu_ns = 0,
        .package_idle_wakeups = wakeups,
        .interrupt_wakeups = 0,
        .pageins = 0,
        .disk_read_bytes = 0,
        .disk_written_bytes = written,
        .instructions = 0,
        .cycles = 0,
    };
}
